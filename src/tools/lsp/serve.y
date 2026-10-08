// serve.y -- the diagnostics server: JSON-RPC dispatch over stdio.
//
// Structure, and why (LSP.md §4):
//
//   The parent process does framing and NOTHING else. Every request is handled
//   in a forked child, which inherits stdout and writes its own response, then
//   exit_group(0). This is not decoration. The compiler is written to run to
//   completion and exit: lexer.tokenize calls exit(1) on an unterminated string
//   (two sites), native.native_resolve_x calls exit(1) on an unreadable import,
//   and a run never frees. A server that called those in its own address space
//   would die on the first `"` the user typed. A child that dies takes only its
//   own reply with it, and the parent -- which has touched no mutable compiler
//   state -- carries on. That containment is the whole reason this is a fork
//   server and not an in-process one (LSP.md §4.2).
//
//   fork{} returns the child's pid to the parent and the child inherits fd 1,
//   so a child writes its reply straight to stdout. That is why there is no
//   pipe here and no plumbing in the main loop: nothing needs to come back
//   except the exit status, which wait_pid gives the parent.
//
// Ordering: one child at a time, replies in arrival order. LSP allows
// out-of-order replies, but a checker walk is cheap at this size and a serial
// server cannot interleave two half-written frames onto one stdout.
//
// NAMESPACE. This module imports the compiler by path, which FLATTENS those
// modules into this one namespace -- so every name here is checked against the
// whole compiler's vocabulary, and `dir_of` had to be renamed for exactly that
// reason. json and fs are imported BY NAME, which keeps their namespace; their
// types are then spelled `json.Val` and `fs.read_some`, never bare.

import json;

// fs comes in by name through diag.y -> native.y. This module deliberately does
// NOT `import fs;` itself. native.norm_path drops "." from a path but never
// collapses "..", so native.y -- reached as "../../y/native.y" -- resolves its
// own `import fs;` to src/tools/lsp/../../y/std/fs.y, while a top-level one
// resolves to src/y/std/fs.y. Two spellings of one file, so the splicer's dedupe
// misses and every fs.y def is reported as a duplicate definition. That is a
// compiler bug (BUGS.md); the workaround is to name fs once, from the module
// that pulls in native.y.

import rpc from "./rpc.y";
import diag from "./diag.y";
import pos from "./pos.y";
import fmt from "./fmt.y";
import sym from "./sym.y";
// scan and index for the M4 handlers: the spans and the declarations they
// resolve against. nav is the lookup itself, kept separate so it can be tested
// without a request or a JSON object in the way.
import scan from "./scan.y";
import scope from "./scope.y";
import nav from "./nav.y";
import strm from "./strm.y";
import xref from "./xref.y";

// ── the open documents ──────────────────────────────────────────────────

// A document the editor has open: its text and the last version it sent. The
// server never re-reads the file from disk -- an editor's buffer is the truth,
// and the two differ the moment there is an unsaved edit (LSP.md R1.1).
type Doc = { uri: str, path: str, text: str, version: long };

// The open set, as a map plus the list of its keys. Removing a key means
// rebuilding the map rather than storing `none`: the map's value type is pinned
// by its first entry, and a Doc map cannot hold a none without widening to
// `Doc?` everywhere it is read.
type State = {
    docs: { str => Doc },
    open: [str],
    // The cross-file index per document, keyed by uri. `xc` holds the CURRENT
    // version's answer and `xc_none` the uris that have none, because a map
    // cannot hold a `Prepared?` without every read widening (the same trap
    // `docs` documents below) -- and a document with no cross-file index is a
    // normal state, not an error: a buffer that imports nothing, or one that
    // does not lex.
    xc: { str => Prepared },
    xc_none: [str],
    xc_ver: { str => long },
    root: str,          // the workspace root, for a document with no path
    pack: str,          // the std pack, or "" to compile the std units from source
    wlevel: long,       // 0 or 1, as `ycc -W`
    shutting: bool,     // a `shutdown` request has been answered
    exiting: bool,      // an `exit` notification has arrived
    initialized: bool,  // `initialize` has been answered
    // R1.8's `y.lsp.checkOnChange`, default ON. Off means "do not run the checker
    // and the linter on every keystroke"; it does NOT mean "ignore the change",
    // because every other feature reads this buffer and a stale one is worse than
    // a slow check. See on_did_change.
    check_on_change: bool,
    // Per-request timing lines to the client's log. OFF by default: they cost
    // the extension host an appendLine each, two per request, and this extension
    // was reported making a cold open freeze the editor. A diagnostic that is on by
    // default is a diagnostic that can be the cause of what it is diagnosing.
    timing: bool
};

def server_state(root: str, pack: str, wlevel: long) -> State {
    let m: { str => Doc } = {};
    let e: { str => Prepared } = {};
    let v: { str => long } = {};
    let s: State = { docs: m, open: [], xc: e, xc_none: [], xc_ver: v, root: root, pack: pack, wlevel: wlevel, shutting: false, exiting: false, initialized: false, check_on_change: true, timing: false };
    s
}

// The cross-file index for a document, or none. CACHED PER VERSION, because
// building it resolves the imports, parses and renames -- the same work
// `publish_for` does for diagnostics, and at the same cost. A completion
// followed by a hover on an unedited buffer is the common shape, and without the
// cache that is the work done twice for one keystroke.
def xref_of(st: State, d: Doc) -> Prepared? {
    if (is_some(st.xc_ver[d.uri])) {
        if (st.xc_ver[d.uri] ! == d.version) {
            if (is_some(st.xc[d.uri])) { return st.xc[d.uri]; } else { return none; };
        };
    };
    let got = diag.xref_for(d.text, doc_dir(st, d.path), d.path, st.pack);
    st.xc_ver[d.uri] = d.version;
    if is_some(got) {
        let pr: Prepared = got !;
        st.xc[d.uri] = pr;
        st.xc_none = drop(st.xc_none, d.uri);
        return some(pr);
    };
    st.xc_none += d.uri;
    none
}

def drop(xs: [str], w: str) -> [str] {
    let out: [str] = [];
    let i = 0;
    while (i < len(xs)) {
        if (xs[i] != w) { out += xs[i]; };
        i = i + 1;
    };
    out
}

// The JSON-RPC error codes this server returns.
const E_PARSE = -32700;
const E_INVALID_REQUEST = -32600;
const E_METHOD_NOT_FOUND = -32601;
const E_INVALID_PARAMS = -32602;
const E_INTERNAL = -32603;
const E_NOT_INITIALIZED = -32002;
const E_REQUEST_CANCELLED = -32800;

// ── message builders ────────────────────────────────────────────────────

def result_msg(id: json.Val, result: json.Val) -> str {
    let m = json.obj();
    m["jsonrpc"] = json.str("2.0");
    m["id"] = id;
    m["result"] = result;
    json.stringify(m)
}

def error_msg(id: json.Val, code: long, message: str) -> str {
    let e = json.obj();
    e["code"] = json.num(code);
    e["message"] = json.str(message);
    let m = json.obj();
    m["jsonrpc"] = json.str("2.0");
    m["id"] = id;
    m["error"] = json.jobj(e);
    json.stringify(m)
}

// A notification carries no id and gets no reply.
def notify_msg(method: str, params: json.Val) -> str {
    let m = json.obj();
    m["jsonrpc"] = json.str("2.0");
    m["method"] = json.str(method);
    m["params"] = params;
    json.stringify(m)
}

// ── the document table ──────────────────────────────────────────────────

def doc_get(st: State, uri: str) -> Doc? {
    let d: Doc? = st.docs[uri];
    d
}

def doc_has(st: State, uri: str) -> bool {
    let hit = false;
    foreach (u in st.open) { if (u == uri) { hit = true; } }
    hit
}

def doc_put(st: State, uri: str, path: str, text: str, version: long) {
    let d: Doc = { uri: uri, path: path, text: text, version: version };
    if (!doc_has(st, uri)) { st.open += uri; }
    st.docs[uri] = d
}

def doc_drop(st: State, uri: str) {
    let keep: [str] = [];
    foreach (u in st.open) { if (u != uri) { keep += u; } }
    st.open = keep;
    // The map cannot hold `none`, so it is rebuilt without the key. An entry
    // left behind would keep a document's text alive forever and would still be
    // found by doc_get.
    let m: { str => Doc } = {};
    foreach (u in st.open) {
        let d = doc_get(st, u);
        if is_some(d) { m[u] = d !; }
    };
    st.docs = m
}

// file:///abs/path -> /abs/path, and %XX -> that byte. The editor sends URIs;
// the compiler wants a path. Percent-escaping is the only encoding in play
// (LSP.md §7.1) and decoding it is a few lines.
def uri_path(uri: str) -> str {
    let s = uri;
    if (s[:7] == "file://") { s = s[7:]; }
    let out: [byte] = [];
    let i = 0;
    while (i < len(s)) {
        let c = byte_at(s, i);
        if (c == 37 && i + 2 < len(s)) {          // '%'
            let h = json.hexval(s[i + 1]);
            let l = json.hexval(s[i + 2]);
            if (h >= 0 && l >= 0) {
                out += bytes(chr(h * 16 + l));
                i = i + 3;
            } else {
                out += bytes(chr(c));
                i = i + 1;
            }
        } else {
            out += bytes(chr(c));
            i = i + 1;
        }
    }
    from_bytes(out)
}

// The directory a document's imports resolve against: its own directory, or the
// workspace root for a document that has no path yet. fs has no dirname and
// native.y's dir_of is private, so this is four lines rather than a fix to the
// compiler. It strips the LAST separator only, which is the whole job.
def doc_dir(st: State, p: str) -> str {
    let cut = last_index_of(p, "/");
    if (cut < 0) { st.root } else { p[0:cut] }
}

// ── diagnostics ─────────────────────────────────────────────────────────

// One diagnostic in the protocol's shape. The position is the compiler's own
// 1-based line and BYTE column converted through the document text, because the
// byte column means nothing to a client without it (pos.y).
def diag_json(d: Finding, text: str) -> json.Val {
    let p = pos.to_lsp(text, d.line, d.col);
    let lp = json.obj();
    lp["line"] = json.num(p.line);
    lp["character"] = json.num(p.character);
    let le = json.obj();
    le["line"] = json.num(p.line);
    le["character"] = json.num(p.character + 1);
    let rng = json.obj();
    rng["start"] = json.jobj(lp);
    rng["end"] = json.jobj(le);

    let o = json.obj();
    o["range"] = json.jobj(rng);
    // DiagnosticSeverity: 1 = Error, 2 = Warning. Finding.kind is the same pair.
    o["severity"] = json.num(d.kind);
    o["message"] = json.str(d.msg);
    // source is what an editor shows as the origin, and it is how a user tells
    // the checker's word from the linter's.
    let src = "ycc";
    if (d.kind == 2) { src = "ycc (lint)"; }
    o["source"] = json.str(src);
    if (d.kind == 2) {
        // DiagnosticTag.Unnecessary = 1: the linter's findings are advice about
        // code that works, which is what a tag is for.
        let tg = json.obj();
        tg["value"] = json.num(1);
        o["tags"] = json.jarr([json.jobj(tg)]);
    }
    json.jobj(o)
}

// One publishDiagnostics params value: the diagnostics, under `uri`.
//
// `version` is the document's own version, or NO_VERSION when we are publishing
// for a file this server was not told about. The spec says an omitted version
// means "whatever the editor's buffer is", which is the truth for an import the
// editor never opened; sending 0 instead would be a claim, and a client that
// believed it would discard diagnostics as stale.
const NO_VERSION = -1;

def publish_params(uri: str, version: long, items: [json.Val]) -> json.Val {
    let di = json.obj();
    di["uri"] = json.str(uri);
    if (version >= 0) { di["version"] = json.num(version); }
    di["diagnostics"] = json.jarr(items);
    json.jobj(di)
}

// The notifications for one document -- ONE PER FILE, which the protocol
// requires and which the first implementation got wrong.
//
// publishDiagnostics is keyed by URI, so a diagnostic found in an IMPORTED file
// has to be published in a notification for THAT file's URI. Publishing it in
// the main document's notification looks right and is not: the client stores it
// against main.y, and the squiggle lands on main.y's line 1 instead of on
// helper.y's line 2. The compiler does report per-file (diag.check maps every
// finding through origin_at), so the information is there and only the grouping
// was missing.
//
// The document's own findings use `d.uri` verbatim -- the editor may have sent
// a URI with percent escapes, or an `untitled:` one, and echoing back exactly
// what we were given is the only way to be sure it matches. Any other file is a
// real path on disk, so it gets a file:// URI built here.
def publish_for(st: State, d: Doc) -> [str] {
    let out: [str] = [];
    let found = diag.diagnose(d.text, doc_dir(st, d.path), d.path, st.pack, st.wlevel);

    // Group the RAW findings by file first, then convert. The conversion needs
    // the text of the file the finding is in -- a byte column is only an offset
    // once you know the line's bytes -- so doing it per group means reading each
    // file once instead of once per finding.
    let mine: [Finding] = [];
    let order: [str] = [];
    let theirs: { str => [Finding] } = {};
    foreach (f in found) {
        if (f.file == d.path) {
            mine += f;
        } else {
            let list = theirs[f.file];
            if (is_some(list)) {
                let grown: [Finding] = list !;
                grown += f;
                theirs[f.file] = grown;
            } else {
                let first: [Finding] = [f];
                theirs[f.file] = first;
                order += f.file;
            }
        }
    }

    // The document's own findings first, under the URI the editor sent: an
    // editor showing one file at a time should show the right thing at once.
    let own: [json.Val] = [];
    foreach (f in mine) { own += diag_json(f, d.text); }
    out += notify_msg("textDocument/publishDiagnostics", publish_params(d.uri, d.version, own));

    foreach (f in order) {
        let list = theirs[f];
        if is_some(list) {
            let items: [json.Val] = [];
            let text = other_text(st, f);
            foreach (x in list !) { items += diag_json(x, text); }
            out += notify_msg("textDocument/publishDiagnostics", publish_params(path_uri(f), NO_VERSION, items));
        }
    }
    out
}

// The text a finding in another file should be measured against: the editor's
// buffer if that file is open here (its unsaved edits are what the user is
// looking at), else what is on disk, else "" -- and with "" every column lands
// at 0, which is wrong but visible, where a wrong non-zero column is not.
def other_text(st: State, f: str) -> str {
    let out = "";
    let u = path_uri(f);
    if (doc_has(st, u)) {
        let got = doc_get(st, u);
        if is_some(got) { out = got !.text; }
    } else {
        let read = fs.read_file(f);
        if is_some(read) { out = read !; }
    }
    out
}

// A path to a file:// URI, percent-encoding what needs it. The inverse of
// uri_path. Only the characters that actually break a URI are escaped -- a
// space, a '#' and a '?' -- because a client that receives an over-escaped path
// may fail to open it, and the alternative (escaping everything) makes the URIs
// in a log unreadable.
def path_uri(p: str) -> str {
    let out = "file://";
    let i = 0;
    while (i < len(p)) {
        let c = byte_at(p, i);
        if (c == 32 || c == 35 || c == 63 || c == 37) {
            let hexd = "0123456789ABCDEF";
            out += "%" + hexd[c / 16] + hexd[c % 16];
        } else {
            out += chr(c);
        }
        i = i + 1;
    }
    out
}

// Re-check a document and return the notifications to send, one per file that
// has a finding. Empty when the document is no longer open -- an editor that
// closed the file mid-request wants no diagnostics for it, and stale ones are
// worse than none.
//
// A file that had findings last time and has none now gets an EMPTY list rather
// than no notification: publishing nothing leaves the previous squiggles on
// screen forever, which is the single most complained-about bug in this area.
def refresh(st: State, uri: str) -> [str] {
    let out: [str] = [];
    let got = doc_get(st, uri);
    if is_some(got) { out = publish_for(st, got !); }
    out
}

// ── the document lifecycle ──
//
// Two halves, and WHICH PROCESS RUNS THEM is the whole point:
//
//   note_*    mutate the document table. Run in the PARENT, before the fork.
//   on_*      build the reply. Run in the CHILD, after it.
//
// The split is forced by the fork. fork{} gives the child a COPY: every write
// the child makes is thrown away when it exits, so a store kept only in the
// child would be empty again for the next message. The parent therefore owns the
// documents, updates them itself, and then forks a child that can SEE them --
// inherited at the moment of the fork. That is also what keeps the containment
// intact: the parent touches no compiler code, only json.parse (which is
// tolerant and never exits) and these few assignments.

// textDocument/didOpen, state only.
def note_open(st: State, p: { str => json.Val }) {
    let td = field_of(p, "textDocument");
    let uri = str_field(td, "uri");
    let text = str_field(td, "text");
    let version = long_field(td, "version");
    if (uri != "" && text != "") {
        doc_put(st, uri, uri_path(uri), text, version);
    }
}

// textDocument/didChange, state only. The whole document again -- full sync --
// and the LAST entry of contentChanges, because a client that batched several
// keystrokes into one notification has already collapsed them.
def note_change(st: State, p: { str => json.Val }) {
    let td = field_of(p, "textDocument");
    let uri = str_field(td, "uri");
    let version = long_field(td, "version");
    let ch = field_of(p, "contentChanges");
    let n = change_count(ch);
    if (uri != "" && n > 0) {
        let text = str_field(change_at(ch, n - 1), "text");
        doc_put(st, uri, uri_path(uri), text, version);
    }
}

// The `exit` notification. It arrives with no id and gets no reply: it is the
// client saying it is finished, and answering it would be a frame the client is
// not reading. Only the flag matters, and only the parent sets it -- the parent
// is what decides to stop the loop.
def on_exit(st: State) {
    st.exiting = true;
}

// textDocument/didClose, state only.
def note_close(st: State, p: { str => json.Val }) {
    let uri = str_field(field_of(p, "textDocument"), "uri");
    if (uri != "") { doc_drop(st, uri); }
}

// textDocument/didOpen, reply only.
def on_did_open(st: State, p: { str => json.Val }) -> [str] {
    let uri = str_field(field_of(p, "textDocument"), "uri");
    let out: [str] = [];
    if (doc_has(st, uri)) { out = refresh(st, uri); }
    out
}

// textDocument/didChange, reply only.
//
// The document has ALREADY been updated by `note_change` before this runs --
// `doc_notification` does the state and this does the reply -- so with R1.8 off
// this publishes nothing and the buffer stays current. That split is the whole
// point: the other reading of the setting ("ignore changes") would leave hover,
// completion and formatting answering about text the user has
// already replaced, which is worse than the slow check the switch exists for.
def on_did_change(st: State, p: { str => json.Val }) -> [str] {
    let out: [str] = [];
    if (st.check_on_change) {
        let uri = str_field(field_of(p, "textDocument"), "uri");
        if (doc_has(st, uri)) { out = refresh(st, uri); }
    };
    out
}

// textDocument/didSave, reply only. The buffer is the truth, not the file:
// re-checking the text on disk would report on a version the editor has already
// moved past. So this only re-publishes what is in memory.
def on_did_save(st: State, p: { str => json.Val }) -> [str] {
    let uri = str_field(field_of(p, "textDocument"), "uri");
    let out: [str] = [];
    if (doc_has(st, uri)) { out = refresh(st, uri); }
    out
}

// textDocument/didClose, reply only: an empty diagnostics list, so the editor
// does not keep showing squiggles for a file the user has closed.
def on_did_close(st: State, p: { str => json.Val }) -> [str] {
    let uri = str_field(field_of(p, "textDocument"), "uri");
    let out: [str] = [];
    if (uri != "") {
        let items: [json.Val] = [];
        out += notify_msg("textDocument/publishDiagnostics", publish_params(uri, NO_VERSION, items));
    }
    out
}

// ── requests ────────────────────────────────────────────────────────────

// initialize: what this server can do. The flags are load-bearing, not
// decoration -- an editor reads them and changes how it calls us, so claiming a
// capability and not honouring it corrupts the client's own state.
// R1.8: `initializationOptions.checkOnChange`, absent or not a bool meaning ON.
//
// The DEFAULT is on, which is the behaviour this server has always had, so a
// client that sends nothing gets what it got before the setting existed. A
// malformed value is also "on" rather than an error: this is a performance switch,
// and refusing to start over it would be a worse outcome than checking when the
// user asked not to.
// `initializationOptions.timing`: whether to write the per-request timing lines.
// Read in the PARENT, for the same reason read_check_on_change is (dispatch.y
// apply_state) -- a flag set in do_initialize lives in the child that read it.
def read_timing(p: { str => json.Val }) -> bool {
    let out = false;
    let io = members_of(field_of(p, "initializationOptions"));
    let got = field_of(io, "timing");
    if let json.Bool b = got { out = b.b; };
    out
}

def read_check_on_change(p: { str => json.Val }) -> bool {
    let out = true;
    // `members_of` because `initializationOptions` is a `json.Val` -- a value
    // that may not be an object at all -- and `field_of` wants a map.
    let io = members_of(field_of(p, "initializationOptions"));
    let got = field_of(io, "checkOnChange");
    if let json.Bool b = got { out = b.b; };
    out
}

// NOTE: `initialize` PARAMS are not an argument here, and R1.8's
// `checkOnChange` is not read here. This runs in the CHILD, which dies with the
// request; a setting recorded here would forget itself on the next keystroke,
// which is exactly what happened when it was read here first time.
// `dispatch.apply_state` reads it, in the parent, which is the only side of the
// fork that survives (LSP.md section 4.2).
def do_initialize(st: State, id: json.Val) -> str {
    st.initialized = true;
    let sync = json.obj();
    sync["openClose"] = json.boolean(true);
    // 1 = Full. The server re-checks the whole text on every change anyway, so
    // incremental edits would be a second code path through pos.y and no win.
    sync["change"] = json.num(1);

    // Formatting on demand. Not a range formatter: fmt.fmt is whole-file, and a
    // range format would have to survive the client's own indentation.
    let caps = json.obj();
    caps["textDocumentSync"] = json.jobj(sync);
    caps["documentFormattingProvider"] = json.boolean(true);

    // The outline. documentSymbolProvider with `true` means "hierarchical", which
    // is what this server returns (a DocumentSymbol[] with children), so the
    // flag is not merely advertising: it selects the response shape.
    caps["documentSymbolProvider"] = json.boolean(true);

    // Navigation (M4). Three flags, all `true` because all three are answered
    // from this file's own declarations -- see nav.y's header for what that
    // does and does not cover. Advertising only what is answered is the same
    // rule as the diagnosticProvider note below: a client reads a capability as
    // a promise and changes what it offers the user because of it.
    caps["definitionProvider"] = json.boolean(true);
    caps["hoverProvider"] = json.boolean(true);
    // The trigger characters are what a client uses to ask WITHOUT the user
    // pressing anything. "." is the one that matters (a member name) and "_" is
    // there because Y names are underscore-separated and typing one usually
    // means the user is part-way through a name.
    let cp = json.obj();
    let trg: [json.Val] = [];
    trg += json.str(".");
    trg += json.str("_");
    cp["triggerCharacters"] = json.jarr(trg);
    caps["completionProvider"] = json.jobj(cp);

    // NOTE: no `diagnosticProvider` here, on purpose.
    //
    // That capability means PULL diagnostics -- the client asks, via
    // textDocument/diagnostic, and expects a DocumentDiagnosticReport. This
    // server PUSHES them: textDocument/publishDiagnostics, which needs no
    // capability at all. Advertising the pull model while implementing only the
    // push one is not a harmless extra: VS Code switches to pulling, gets
    // -32601 for every document, and -- having switched -- IGNORES the
    // notifications still being pushed. The first version of this advertised it,
    // and the result was a server that looked fine in a hand-written test and
    // showed no diagnostics at all in a real editor. (`client-check.js` now
    // behaves like the editor here: if the capability appears, it pulls.)
    //
    // Implementing the pull model properly is the alternative, and it is worth
    // doing eventually -- a pull report is version-tagged, so a client can
    // discard a stale one instead of showing it. Until then, do not claim it.

    let r = json.obj();
    r["capabilities"] = json.jobj(caps);
    let info = json.obj();
    info["name"] = json.str("yserve");
    info["version"] = json.str("1");
    r["serverInfo"] = json.jobj(info);
    result_msg(id, json.jobj(r))
}

// shutdown: say nothing, and wait for exit. A server that answers shutdown and
// keeps serving is one an editor cannot restart without killing the process.
def do_shutdown(id: json.Val) -> str {
    result_msg(id, json.nul())
}

// textDocument/formatting: the whole document, formatted (LSP.md §11).
//
// The edit replaces the whole document, because a formatter that rewrites line
// breaks cannot describe its result as a small range. fmt.fmt returns none for a
// buffer that does not lex (R3.4), and the answer then is NO edits -- which
// leaves the user's broken buffer as they typed it rather than half-rewritten.
def do_formatting(st: State, id: json.Val, p: { str => json.Val }) -> str {
    let uri = str_field(field_of(p, "textDocument"), "uri");
    let edits: [json.Val] = [];
    let got = doc_get(st, uri);
    if is_some(got) {
        let d: Doc = got !;
        let body = fmt.fmt(d.text);
        if is_some(body) {
            let text2 = body !;
            // Already formatted? Then no edits at all: an editor may treat an
            // empty edit list as a reason to re-derive its undo history, and
            // losing undo for a no-op format is worse than doing nothing.
            if (text2 != d.text) {
                let e0 = json.obj();
                e0["line"] = json.num(0);
                e0["character"] = json.num(0);
                let rng = json.obj();
                rng["start"] = json.jobj(e0);
                rng["end"] = end_position(d.text);
                let ed = json.obj();
                ed["range"] = json.jobj(rng);
                ed["newText"] = json.str(text2);
                edits += json.jobj(ed);
            }
        }
    }
    let r = json.obj();
    r["edits"] = json.jarr(edits);
    result_msg(id, json.jobj(r))
}

// textDocument/documentSymbol: the outline, hierarchical.
def do_document_symbols(st: State, id: json.Val, p: { str => json.Val }) -> str {
    let uri = str_field(field_of(p, "textDocument"), "uri");
    let items: [json.Val] = [];
    let got = doc_get(st, uri);
    if is_some(got) {
        let d: Doc = got !;
        items = symbols_json(sym.symbols(pos.doc_of(d.text)));
    }
    let r = json.obj();
    r["documentSymbol"] = json.jarr(items);
    result_msg(id, json.jobj(r))
}

// ── navigation (M4) ──────────────────────────────────────────────────────
//
// Three requests over one lookup. All three find the word at the cursor the
// same way (nav.ident_at) and all three answer from scope.index_src, rebuilt
// per request exactly as sem and sym rebuild their own -- the index of an
// open buffer is cheap next to the scan both need anyway, and caching it means
// a second place to invalidate on every didChange.
//
// The index is a function of the buffer, so a request against a document the
// editor has not opened (or has closed) has no text to index and answers
// empty. That is deliberate: reading the file from disk would answer about a
// version of the file the user is not looking at (LSP.md R1.1).

// The request's position, as a 0-based (line, utf16 character) pair. A missing
// or malformed position is (-1, -1), which resolves to no word -- the handlers
// below share this, so a client that omits the field gets an empty answer
// rather than one handler being stricter than another.
def request_position(p: { str => json.Val }) -> Pos {
    let out: Pos = { line: -1, character: -1 };
    let m = members_of(field_of(p, "position"));
    // Both fields must be there. A position of line 0 / character 0 is a real
    // one (the top-left corner), so "absent" cannot be 0 -- hence -1, and hence
    // checking for the fields rather than defaulting them.
    let ln = field_of(m, "line");
    let gotl = json.as_long(ln);
    if is_some(gotl) {
        let ch = field_of(m, "character");
        let gotc = json.as_long(ch);
        if is_some(gotc) { out = { line: gotl !, character: gotc ! }; };
    };
    out
}

// The word at the request's position, and the text it is in. A record rather
// than a pair because Y has no tuples (TODO.md 6), and an option FIELD rather
// than a `Hit?` whole because "no word" and "no document" are different
// answers that happen to coincide for these callers.
type Under = { hit: Hit?, text: str };

// The word at the request's position, or nothing. `text` is "" when the
// document is not open, which the callers read as "no word" as well -- see the
// note above about not reading the file from disk.
def word_under(st: State, p: { str => json.Val }) -> Under {
    let uri = str_field(field_of(p, "textDocument"), "uri");
    let got = doc_get(st, uri);
    let nothing: Under = { hit: none, text: "" };
    if is_some(got) {
        let d: Doc = got !;
        let at = request_position(p);
        if (at.line >= 0) {
            let sps = scan.scan_full(d.text).spans;
            let col = pos.from_lsp(d.text, at.line, at.character);
            let off = scan.off_at(d.text, pos.src_line(at.line), col);
            if (off >= 0) {
                return { hit: nav.ident_at(sps, d.text, off), text: d.text };
            };
        };
    };
    nothing
}

// A one-line position object, for a Location's range.
def lsp_pos(line: long, character: long) -> json.Val {
    let o = json.obj();
    o["line"] = json.num(line);
    o["character"] = json.num(character);
    json.jobj(o)
}

// textDocument/definition: where the name under the cursor is declared.
//
// `null` -- not an empty array -- when there is nothing to point at. The
// protocol says a Location | Location[] | LocationLink[] | null, and null is
// the "no definition here" answer; an empty array claims the question was
// asked and found nothing, which is the same thing said worse. An editor
// treats them alike, so this is for the reader, not the client.
def do_definition(st: State, id: json.Val, p: { str => json.Val }) -> str {
    let u = word_under(st, p);
    let h: Hit? = u.hit;
    let answer = json.nul();
    if (h != none && u.text != "") {
        let w: Hit = h !;
        let got = doc_get(st, str_field(field_of(p, "textDocument"), "uri"));
        if is_some(got) {
            let d: Doc = got !;
            // Where it is DECLARED, which is the buffer's own index first and
            // then the spliced program's -- so an imported name answers, and the
            // answer can name a file the client does not have open (LSP.md 11.4).
            let at = request_position(p);
            let member = after_dot(u.text, w.off);
            let found = resolve_name(st, d, w.name, member, at.line, at.character,
                member_object_name(d.text, scan.scan_full(d.text).spans, w.off));
            if (is_some(found)) {
                let wh: Where = found !;
                let r = json.obj();
                r["start"] = lsp_pos(wh.line, wh.ch);
                r["end"] = lsp_pos(wh.line, wh.ch + len(w.name));
                let loc = json.obj();
                // The TARGET's uri. For the buffer's own declaration that is the
                // document's own uri verbatim -- the editor may have sent one with
                // percent escapes, or an `untitled:` one, and echoing back
                // exactly what we were given is the only way to be sure it
                // matches. A file that is not this document is a real path on
                // disk, so it gets a file:// URI built here.
                loc["uri"] = json.str(if (wh.cross) { file_uri(wh.path) } else { d.uri });
                loc["range"] = json.jobj(r);
                answer = json.jobj(loc);
            };
        };
    };
    result_msg(id, answer)
}

// The type the CHECKER inferred for the expression at the word under the cursor,
// or "" when it indexed nothing there.
//
// This is types.expr_type read out of the compiler's own table (9.2 A2), over the
// spliced program's own coordinates -- which is why it needs `mine`, the buffer
// line to spliced line map. The server never infers a type, never re-derives one,
// and never prints one the checker did not produce: an empty answer here becomes
// no type in the hover, not a guess.
//
// `ch` is a 0-based LSP character. The compiler's columns are 1-based BYTES, so
// this converts twice and says so, because getting either wrong is a type that is
// merely plausible.
// `tunk()`, not `tnone()`, for "the checker has no answer here". `tnone` is a type
// a program can write, so returning it made "no answer" indistinguishable from "the
// checker says none" -- and a caller testing for it never fired. That is the same
// rule types.expr_type follows, and for the same reason.
def type_at(st: State, d: Doc, line: long, ch: long) -> Type {
    let out: Type = expr_type(0, 0);
    let x = xref_of(st, d);
    if is_some(x) {
        let pr: Prepared = x !;
        // line + 1, and the "+ 1" is the whole bug this had for an hour: an LSP
        // position is 0-based and `mine` is indexed by the compiler's 1-based
        // lines. Every request was asking about the line ABOVE the one under the
        // cursor, which returns nothing rather than something wrong -- the
        // failure mode LSP.md calls out for scope_start, and the same trap.
        let sl = xref.indexed_line(pr.mine, line + 1);
        if (sl > 0) {
            let bcol = pos.from_lsp(d.text, line, ch);
            let t = expr_type(sl, bcol);
            if (t.k != K.tunk) { out = t; };
        };
    };
    out
}

// A type the server holds but must not answer with: `none_type()` is the
// checker's own "this expression has no type" (`tnone`), and every caller below
// tests `k` before printing, so nothing here can reach a hover or a completion
// item as a type. It exists only so a caller has a Type to hold.
def none_type() -> Type { type_node({ k: K.tnone }) }

def inferred_at(st: State, d: Doc, line: long, ch: long) -> str {
    let out = "";
    let x = xref_of(st, d);
    if is_some(x) {
        let pr: Prepared = x !;
        let sl = xref.indexed_line(pr.mine, line + 1);
        if (sl > 0) {
            // from_lsp ALREADY returns a 1-based byte column -- that is its
            // documented contract, the same one tline/tcol give -- so there is no
            // +1 here. There was one, and it made every request ask about the
            // character after the one under the cursor.
            let bcol = pos.from_lsp(d.text, line, ch);
            let t = expr_type(sl, bcol);
            if (t.k == K.tunk) {
                // A member NAME. `a.b` records the FIELD's type under the dot
                // rather than under the name, because that is where the Dot node
                // sits; so a request about the name asks about the character
                // before it.
                //
                // Asked at the NAME first and only then at the dot, so a name
                // that does have its own entry -- a local, a parameter -- is
                // answered from that entry and never from a neighbour's. Asking
                // the dot first would answer `x.y`'s `y` with whatever `x`'s
                // type happens to be.
                let dcol = before_dot_col(d.text, line, ch);
                if (dcol >= 0) {
                    let t2 = expr_type(sl, pos.from_lsp(d.text, line, dcol));
                    if (t2.k != K.tunk) { t = t2; };
                };
            };
            // tunk is types.expr_type's "nothing here" sentinel. It renders as
            // `<error>`, which in a hover would read as a diagnostic about the
            // user's code, so it is tested for rather than printed.
            if (t.k != K.tunk) { out = tstr(t); };
        };
    };
    out
}

// The 0-based character column of the `.` immediately before the word starting
// at `ch` on `line`, or -1 when there is none.
//
// One byte back is enough for `x.y`, and `x . y` is not code anyone writes. The
// limit is stated rather than papered over: a chain like `a.b.c` asks about the
// dot before `c`, which is `b`'s -- the OBJECT of that dot -- and the table holds
// the whole `a.b` under it, so the answer is the object's type rather than `c`'s.
// That is the same class of thing the string methods do (a `.` with no type to go
// on answers from a fixed table), and it is why the completion side refuses a
// member whose object is not a single identifier.
def before_dot_col(text: str, line: long, ch: long) -> long {
    let out = -1;
    if (ch > 0) {
        let lb = pos.line_bytes(text, pos.src_line(line));
        // ch is a 0-based CHARACTER; every byte before an ASCII identifier is
        // ASCII, so one byte back is the right byte for the case that matters.
        if (ch < len(lb)) {
            if (byte_at(lb, ch - 1) == 46) { out = ch - 1; };
        };
    };
    out
}

// A real path on disk as the file:// URI the protocol uses. The buffer's OWN uri
// is never passed through this: it came from the client and is echoed verbatim
// instead (see do_definition), because only the client's own spelling is
// guaranteed to match what it sent.
def file_uri(path: str) -> str { "file://" + path }

// Where a name is DECLARED, across files. none when nothing declares it.
//
// Two steps, and the second is the whole of the cross-file case:
//
//   1. the spliced program's own top-level index (`xref`), which is where an
//      imported module's declarations are -- a splice inlines it at top level,
//      and the renamer gave each binding a name shared by its definition and its
//      uses (LSP.md 11.4);
//   2. the target file's OWN span index, for the exact position of the name --
//      the AST's is the keyword, not the name, and the positions have always come
//      from `scope`.
//
// Returns the target file's path, a 0-based LSP line and character, and the
// target's IdxDecl, so hover can reuse it. `own` is the buffer's own path, for
// telling "the answer is in this file" from "it is in another".
type Where = { path: str, line: long, ch: long, dcl: IdxDecl, cross: bool };

// `mod_of` is the name of the object when the cursor is on a member -- `bn` in
// `bn.NLIMB` -- and "" otherwise. It is what makes a MODULE member navigable.
def resolve_name(st: State, d: Doc, name: str, member: bool, line: long, ch: long, mod_of: str) -> Where? {
    let out: Where? = none;
    // The buffer first: a local is a better answer than an import of the same
    // name, and the single-file index already knows the scope rules.
    //
    // UNLESS the name is after a `.`, in which case the buffer's own top-level
    // bindings are not candidates at all -- `helper.helper` names a member of
    // the module `helper`, and answering with the buffer's own `import helper`
    // line sends the user to the import instead of the definition, which is the
    // one place go-to-definition must not go wrong. (That import binding is named
    // after the module, so it collides with every member lookup.)
    let own = scope.index_src(d.text, d.path);
    let here: IdxDecl? = none;
    if (!member) { here = nav.find_decl(own, name, line, ch); };
    if (is_some(here)) {
        let dc: IdxDecl = here !;
        out = some({ path: d.path, line: dc.line, ch: dc.ch, dcl: dc, cross: false });
    } else {
        let x = xref_of(st, d);
        if is_some(x) {
            let pr: Prepared = x !;
            // The spliced index spells a member EITHER WAY, and which one exists is
            // what says which kind of import this was:
            //
            //   `bn.NLIMB`   a module imported BY NAME keeps its namespace, so the
            //                spliced top level holds `bn.NLIMB`. This is the shape
            //                `examples/bignum` uses -- `bn` is not a std unit, it is
            //                the file next to it, so std_resolve finds it and
            //                rename keeps the qualifier.
            //   `NLIMB`      a module imported BY PATH is flattened by strip_ns, so
            //                the spliced top level holds the bare name. That is the
            //                shape t015_xref pins.
            //
            // Only the first spelling was looked up, so `bn.NLIMB` found nothing:
            // no go-to-definition, and a hover with no declaration under the type.
            // Both are tried, qualified first because a module member is the case
            // that was broken.
            let key = name;
            if (member && mod_of != "" && key != mod_of + "." + name) { key = mod_of + "." + name; };
            let ln = pr.lines[key];
            if (!is_some(ln) && key != name) {
                key = name;
                ln = pr.lines[name];
            };
            if is_some(ln) {
                let tg = pr.files[key];
                let target = tg !;
                let got = fs.read_file(target);
                if is_some(got) {
                    let ttext = got !;
                    let tidx = scope.index_src(ttext, target);
                    let hit = nav.find_decl_named(tidx, name);
                    if (is_some(hit)) {
                        let hd: IdxDecl = hit !;
                        out = some({ path: target, line: hd.line, ch: hd.ch, dcl: hd, cross: true });
                    };
                };
            };
        };
    };
    // 3. a member of a std LIBRARY unit (`math.exp`): the unit is linked from
    //    the std pack, not spliced, so neither index above holds it and the pack
    //    carries types but no source. Its source file, when one is on disk (a
    //    checkout, or std/ beside the server: native.std_lib_path), gives the
    //    position, the signature as written and the doc comment. With none, hover
    //    still shows the checker's type for the expression.
    if (!is_some(out) && member && mod_of != "" && name_in_list(std_unit_names(), mod_of)) {
        let target = std_lib_path(mod_of);
        if (target != "") {
            let got = fs.read_file(target);
            if is_some(got) {
                let ttext = got !;
                let tidx = scope.index_src(ttext, target);
                let hit = nav.find_decl_named(tidx, name);
                if (is_some(hit)) {
                    let hd: IdxDecl = hit !;
                    out = some({ path: target, line: hd.line, ch: hd.ch, dcl: hd, cross: true });
                };
            };
        };
    };
    out
}

def name_in_list(xs: [str], n: str) -> bool {
    let found = false;
    foreach (x in xs) { if (x == n) { found = true; } };
    found
}

// What hover shows for a declaration: its signature as written, then the
// comment above it. Markdown, because that is what the protocol asks for and
// what an editor renders -- a fenced code block for the signature so the
// parentheses and the colon survive, and the doc comment as prose beneath.
def hover_text(dcl: IdxDecl) -> str {
    let sig = dcl.name;
    if (dcl.detail != "") { sig = sig + dcl.detail; };
    let md = "```y\n" + sig + "\n```";
    if (dcl.doc != "") { md = md + "\n\n" + dcl.doc; };
    md
}

// A hover for something that is not a declaration: the same shape, over a
// signature string.
def hover_msg(id: json.Val, w: Hit, md: str) -> str {
    let contents = json.obj();
    contents["kind"] = json.str("markdown");
    contents["value"] = json.str(md);
    let r = json.obj();
    r["contents"] = json.jobj(contents);
    let wr = json.obj();
    wr["start"] = lsp_pos(w.line, w.ch);
    wr["end"] = lsp_pos(w.line, w.ch + len(w.name));
    r["range"] = json.jobj(wr);
    result_msg(id, json.jobj(r))
}

// Is `off` (a byte offset) sitting just after a `.`?
//
// The signal a member position gives without a type checker: `s.split` and
// `x.len` are the same shape. It cannot say WHICH members belong -- a record's
// fields and a string's methods are indistinguishable from the text -- so the
// callers use it only to offer the members they CAN answer for, and both say in
// their result what the answer is. Spaces and tabs are skipped so `s . trim`
// works; a newline stops the walk, because `.` at the end of one line and a
// name at the start of the next is not a member access in any language anyone
// writes.
// Is `off` the member position -- the character just after a `.`, or the `.`
// itself?
//
// Both, because `off` is where the word being typed STARTS, and with nothing typed
// after the dot that is the dot's own offset. Looking only one character back then
// finds the `z` of `z.` and answers "not a member position", so the request fell
// through to the NAME list and `z.` offered every name in the file. The two cases
// are the same position; a cursor on the dot and a cursor after it differ by one
// keystroke of nothing.
def after_dot(text: str, off: long) -> bool {
    let out = false;
    if (off >= 0 && off < len(text) && byte_at(text, off) == 46) { out = true; };
    if (!out) {
        let i = off;
        while (i > 0) {
            let c = byte_at(text, i - 1);
            if (c == 32 || c == 9) { i = i - 1; }
            else {
                if (c == 46) { out = true; };
                i = 0;
            };
        };
    };
    out
}

// textDocument/hover: the declaration under the cursor, as text.
//
// `null` when the cursor is not on a name this file declares. Stage A does not
// resolve through imports or into std, so hovering a name from another file
// honestly shows nothing rather than showing this file's same-named local.
def do_hover(st: State, id: json.Val, p: { str => json.Val }) -> str {
    let u = word_under(st, p);
    let h: Hit? = u.hit;
    let answer = json.nul();
    // R4.1 asks for the type of the EXPRESSION under the cursor, and an
    // expression is not always a name: a literal, an operator, a call's `(`. The
    // word-at-the-cursor lookup only finds identifiers, so a hover on `1 + 2`'s
    // `1` found nothing and answered null -- which is the one case where a person
    // most wants the type.
    //
    // So with no word, the type is asked for at the REQUESTED position instead.
    // The answer carries no `range`, which the protocol allows: there is no word
    // to underline.
    if (h == none) {
        let gd0 = doc_get(st, str_field(field_of(p, "textDocument"), "uri"));
        if is_some(gd0) {
            let at0 = request_position(p);
            let ty0 = inferred_at(st, gd0 !, at0.line, at0.character);
            if (ty0 != "") {
                let c0 = json.obj();
                c0["kind"] = json.str("markdown");
                c0["value"] = json.str("```y\n" + ty0 + "\n```");
                let r0 = json.obj();
                r0["contents"] = json.jobj(c0);
                return result_msg(id, json.jobj(r0));
            };
        };
        return result_msg(id, json.nul());
    };
    if (u.text != "") {
        let w: Hit = h !;
        // A string method is answered FIRST, and returns: `"a,b".split` is
        // answered from the compiler's own table (strm.y), which knows the
        // signature, whereas the fallback below knows only what THIS file
        // declares -- and a name after a dot is rarely one of those. Without
        // this the hover on `"x".split` was empty, which reads as "no such
        // method" rather than "the index cannot see it".
        //
        // It has to be first rather than a tie-break, because a file may well
        // declare its own `split`, and here the member position means the
        // receiver's method.
        if (after_dot(u.text, w.off) && strm.is_method(w.name)) {
            return hover_msg(id, w, "```y\n" + strm.sig(w.name) + "\n```\n\nstring method");
        };
        let gd = doc_get(st, str_field(field_of(p, "textDocument"), "uri"));
        let found: Where? = none;
        if (is_some(gd)) {
            let at2 = request_position(p);
            found = resolve_name(st, gd !, w.name, after_dot(u.text, w.off), at2.line,
                at2.character,
                member_object_name(u.text, scan.scan_full(u.text).spans, w.off));
        };
        // The TYPE first, because that is what R4.1 asks for and what a person
        // hovering an expression wants -- and because a type is an answer on its
        // own. A record's FIELD has a type and no binding at all (a field is not
        // a name the program binds, so there is nothing for the index to find),
        // and the first version of this only asked inside `if (is_some(found))`,
        // so hovering `p.a` showed nothing at all even though the checker had the
        // answer. The declaration, when there is one, goes underneath.
        let ty = "";
        if (is_some(gd)) { ty = inferred_at(st, gd !, w.line, w.ch); };
        if (ty != "" || is_some(found)) {
            let body = ty;
            if (is_some(found)) {
                let wh: Where = found !;
                let sig = hover_text(wh.dcl);
                // The type line is for what the declaration does NOT already say: a
                // `let` has no annotation, a record field has no declaration at all,
                // a literal has neither. A def or a parameter's declaration IS its
                // signature, so printing the type above it says the same thing twice
                // -- and when they were read together it was worse than twice, because
                // `mk` showed the record its CALL returns.
                let says_type = index_of(sig, "->") >= 0;
                if (body == "" || says_type) { body = sig; }
                else { body = "```y\n" + body + "\n```\n\n" + sig; };
            };
            let contents = json.obj();
            contents["kind"] = json.str("markdown");
            contents["value"] = json.str(body);
            let r = json.obj();
            r["contents"] = json.jobj(contents);
            // The range of the WORD, not of the declaration it resolves to: the
            // client underlines what the mouse is on. The end is the name's
            // length in UTF-16 units, which for an identifier is its byte
            // length -- a Y identifier is ASCII by the grammar (word characters
            // are letters, digits and _), so the two cannot differ here.
            let wr = json.obj();
            wr["start"] = lsp_pos(w.line, w.ch);
            wr["end"] = lsp_pos(w.line, w.ch + len(w.name));
            r["range"] = json.jobj(wr);
            answer = json.jobj(r);
        };
    };
    result_msg(id, answer)
}

// textDocument/completion: the names visible at the cursor, plus the builtins.
//
// triggerCharacters "." and "_" so an editor asks without the user pressing
// anything, and `isIncomplete: true` because Stage A's list is genuinely
// partial -- it has no imported module's members and no string methods. That
// flag is the protocol's way of saying "ask me again as the user types", which
// is exactly right here, and it is also why the client keeps calling us
// instead of filtering its own copy once and stopping.
def do_completion(st: State, id: json.Val, p: { str => json.Val }) -> str {
    let uri = str_field(field_of(p, "textDocument"), "uri");
    let got = doc_get(st, uri);
    let items: [json.Val] = [];
    if is_some(got) {
        let d: Doc = got !;
        let at = request_position(p);
        let sps = scan.scan_full(d.text).spans;
        let col = pos.from_lsp(d.text, at.line, at.character);
        let off = scan.off_at(d.text, pos.src_line(at.line), col);
        let prefix = "";
        let word_start = off;
        if (off >= 0) {
            // The word being typed, so the list can be filtered by what is
            // already there. Read from the BUFFER rather than from the word
            // under the cursor: the cursor is at the END of what has been
            // typed, and nav.ident_at is inclusive of that end, so the half
            // finished identifier is the thing to filter on.
            let w = nav.ident_at(sps, d.text, off);
            if (w != none) {
                let h: Hit = w !;
                word_start = h.off;
                if (off >= h.off) { prefix = d.text[h.off:off]; };
            };
        };
        // After a `.` the answer is MEMBERS, not names, and the two lists are not
        // mixed: a completion list that offers `print` after a dot is worse than
        // one that offers nothing, because the user reads it as "these are the
        // things you can put here".
        //
        // Which members depends on the type of the expression before the dot, and
        // with 9.2 A2 that type is the CHECKER's, not a guess: a record offers its
        // own fields, and only a `str` offers the string methods (strm.matching,
        // also the compiler's table). Anything else -- a number, an array, a
        // type the checker could not resolve -- offers nothing, which is the honest
        // answer and what `isIncomplete` then covers.
        // `after_member` and not a bare `if`, because the member list and the NAME
        // list are alternatives and must not both run. An earlier version of this
        // had the member branch set a flag and let the name branch test it, which
        // meant a STRING (whose fields are none, so the flag stayed false) got the
        // string methods AND every name in scope -- 77 items where there are 26,
        // and `print` after a dot, which is the thing this comment above exists to
        // prevent.
        let after_member = after_dot(d.text, word_start);
        let members_done = false;
        if (after_member) {
            // The object's byte offset -- `word_start` IS the member position, and
            // `object_col` already knows to step back over the dot from it -- and the
            // object's character, which is what the type table is keyed by. Both, in
            // one place, because the two consumers want different ones.
            let ooff = word_start;
            let ocol = object_col(d.text, sps, ooff);
            // The object's own type, via type_at rather than inferred_at: the
            // latter falls back to the dot before the column when it finds nothing,
            // which is right for a FIELD's hover and wrong here -- this position is
            // already the object's own start, so a fallback would reach past it.
            let obj = type_of_object(st, d, at.line, ocol, ooff);
            let otype = obj.k;
            if (otype == K.trec) {
                let flds = record_fields(obj);
                if (len(flds) > 0) {
                    foreach (f in flds) {
                        let nm = field_name(f);
                        if (prefix == "" || (len(nm) >= len(prefix) && nm[:len(prefix)] == prefix)) {
                            items += field_item(nm, field_type(f));
                        };
                    };
                    members_done = true;
                };
            };
            // The string-method list is offered for a `str` and for NOTHING ELSE
            // except the case the checker could not type at all.
            //
            // Offering it for a `long` or an array would be a list of things that
            // cannot go there, and a completion list is read as "these are the
            // things you can put here" -- so a wrong entry is worse than an empty
            // one. A record that came back with no fields at all falls through to
            // here too, which is also wrong; `members_done` below is what stops it,
            // and the two conditions are deliberately different questions: "is this
            // receiver a string?" decides the list, and "did the member branch
            // answer?" decides whether the name branch runs at all.
            //
            // With NO type at all (`otype` is tnone from none_type(), which is also
            // what an object_col that refused gives) the string methods are the
            // Stage A answer, and t014_strm pins that list at 26. That is honest
            // because the server does not know the receiver -- it is not claiming
            // the receiver IS a string, only that this is what it can offer.
            // A MODULE offers its own members, which is the case the string-method
            // fallback used to swallow: `math.` offered `byte_at, bytes, center`.
            // Two sources, in order, because the compiler knows both and a partial
            // list is worse than none:
            //
            //   1. the linked unit's `exports` -- every name it binds, with its
            //      label and type. Complete for a std unit and for a path import.
            //   2. the buffer's own spliced top level, filtered to the names whose
            //      origin file is the module's -- which is what a module that is
            //      not a linked unit (a sibling file) can offer.
            if (!members_done) {
                let mods = module_members(st, d, ooff);
                let obj_name = member_object_name(d.text, sps, ooff);
                if (len(mods) > 0) {
                    let mi = 0;
                    while (mi < len(mods)) {
                        // NOT named `sym`: this module imports `./sym.y` AS `sym`,
                        // and a field read on a name the checker resolves to the
                        // module rather than to the local gives "undefined variable
                        // 'name'" rather than anything mentioning the collision.
                        let one: Sym = mods[mi];
                        let nm = module_label(one.name, obj_name);
                        if (nm != "" && (prefix == "" || (len(nm) >= len(prefix) && nm[:len(prefix)] == prefix))) {
                            let det = "";
                            if (one.typ.k != K.tunk) { det = tstr(one.typ); };
                            items += module_item(nm, det);
                        };
                        mi = mi + 1;
                    };
                    members_done = true;
                };
            };
            if (!members_done && (otype == K.tstr || otype == K.tnone)) {
                foreach (m in strm.matching(prefix)) { items += str_method_item(m); };
            };
        } else {
            let idx = scope.index_src(d.text, "");
            let here = nav.with_prefix(nav.visible(idx, at.line, at.character), prefix);
            foreach (dcl in here) { items += completion_item(dcl); };
            // The builtins come from the compiler's own list (native.intrinsic_names),
            // not from a copy here, so a builtin added to the compiler appears here
            // without anything being updated on this side.
            let bnames = intrinsic_names();
            foreach (b in bnames) {
                // Three of the list's entries are the compiler's own halves rather
                // than names a person writes: `opt$test`/`opt$val` back the option
                // operators and `#fmt` backs the f-string builtin. A `$` cannot
                // appear in an identifier and `#` starts a comment, so offering them
                // would put three un-typable entries in a completion list, sorted
                // among the real ones. They stay in native.intrinsic_names -- the
                // compiler needs them to test a name -- and are dropped here, where
                // the question is what a user can type.
                let typable = index_of(b, "$") < 0 && b[:1] != "#";
                if (typable && (prefix == "" || (len(b) >= len(prefix) && b[:len(prefix)] == prefix))) {
                    items += builtin_item(b);
                };
            };
        };
    };
    let r = json.obj();
    r["isIncomplete"] = json.boolean(true);
    r["items"] = json.jarr(items);
    result_msg(id, json.jobj(r))
}

// The type of the object of a member access, by the object NAME.
//
// Two places to ask, and the second is the one that matters while a line is being
// typed. `z.` on a line of its own does not parse -- there is no name after the dot
// -- so nothing is indexed at that position and the first question answers "nothing
// here". The DECLARATION is not mid-edit, though: `let z = { z: 1 };` typechecks,
// and its type is recorded at the name's own position (Decl.nline/ncol, §9.2 A5).
//
// So: ask at the use, and if the checker has nothing, resolve the name through the
// scope index and ask at the declaration. Both answers come from the checker; the
// second is a position, not a re-derivation.
//
// `off` is the object's byte offset (from `object_col`) and `ocol` its character,
// because the two functions need different ones and a caller that has to convert
// between them is a caller that will eventually forget.
def type_of_object(st: State, d: Doc, line: long, ocol: long, off: long) -> Type {
    let out: Type = none_type();
    if (ocol >= 0) {
        out = type_at(st, d, line, ocol);
        if (out.k == K.tunk) { out = type_at_decl(st, d, off); };
        if (out.k == K.tunk) { out = none_type(); };
    };
    out
}

def type_at_decl(st: State, d: Doc, off: long) -> Type {
    let out: Type = none_type();
    let idx = scope.index_src(d.text, d.path);
    let w = object_hit(d.text, scan.scan_full(d.text).spans, off);
    if (is_some(w)) {
        let hit: Hit = w !;
        let found = nav.resolve_decl(nav.by_name(idx), idx, hit.name, hit.line, hit.ch);
        if (is_some(found)) {
            let dc: IdxDecl = found !;
            let x = xref_of(st, d);
            if (is_some(x)) {
                let pr: Prepared = x !;
                let sl = xref.indexed_line(pr.mine, dc.line + 1);
                if (sl > 0) {
                    let t = expr_type(sl, pos.from_lsp(d.text, dc.line, dc.ch));
                    if (t.k != K.tunk) { out = t; };
                };
            };
        };
    };
    out
}

// The names a MODULE at (line, col) offers, or an empty list when it is not a
// module -- which is the answer that has to be right, because the alternative is
// offering a `str`'s methods for something that is not a `str`.
// `off` is the object's BYTE OFFSET, the same one `object_col` was handed.
def module_members(st: State, d: Doc, off: long) -> [Sym] {
    let out: [Sym] = [];
    if (off > 0) {
        let idx = scope.index_src(d.text, d.path);
        let w = object_hit(d.text, scan.scan_full(d.text).spans, off);
        if is_some(w) {
            let hit: Hit = w !;
            // `resolve_decl`, not `decl_at`: the object of `helper.` is a USE of
            // the import binding, not the import statement itself, so asking "is
            // this token some declaration's own name" cannot match. Asking what the
            // name resolves to HERE is the question, and the import is visible at
            // the point of use.
            let found = nav.resolve_decl(nav.by_name(idx), idx, hit.name, hit.line, hit.ch);
            if (is_some(found)) {
                let dc: IdxDecl = found !;
                if (dc.kind == scope.D_IMPORT) {
                    out = module_exports(st, d, hit.name, dc);
                };
            };
        };
    };
    out
}

// One module's member names.
//
// Three sources, and the order matters: the most complete answer wins, and a
// partial list is worse than none because a completion list is read as "these are
// the things you can put here".
//
//  1. the linked unit's `exports` -- every name it binds, with its label and type.
//     Complete, and the compiler's own answer, when the unit was linked at all.
//  2. the spliced top level, filtered to the names whose ORIGIN FILE is the
//     module's. `Prepared.files` maps each spliced name to the file it came from,
//     so this is exact rather than a guess -- but it needs the module's file.
//
// Getting that file is the part `import math;` makes awkward: a std unit is named,
// not pathed, so the import statement carries no path to resolve. And a std unit
// resolved from a BUFFER's directory is often not linked at all -- `nr.std` for a
// buffer outside the compiler tree comes back as just `str,rt` -- which is why
// `math.` had nothing to offer and fell through to the string methods.
//
// So the file is found by its BASENAME: a module is named after its file, which is
// the same rule `ytest check-names` polices because `strip_ns` rewrites any
// `name.field` as a module reference. `math` -> `math.y`, `helper` -> `helper.y`.
// It is a text match on a real path, and when two modules share a basename in one
// buffer the first is taken -- which is stated rather than pretended away, and is
// the only case here that is not exact.
def module_exports(st: State, d: Doc, modname: str, dc: IdxDecl) -> [Sym] {
    let out: [Sym] = [];
    let x = xref_of(st, d);
    if is_some(x) {
        let pr: Prepared = x !;
        let us = pr.units;
        let ui = 0;
        while (ui < len(us) && len(out) == 0) {
            let u = us[ui];
            if (u.name == modname) {
                let es = u.exports;
                let ei = 0;
                while (ei < len(es)) { out += es[ei]; ei = ei + 1; };
            };
            ui = ui + 1;
        };
        if (len(out) == 0) {
            // A path import states its own target, which is better than a basename
            // match and is used when there is one.
            let want = "";
            if (dc.detail != "") { want = resolve_import_path(d, dc.detail); };
            // A PATH import's target identifies the file outright (`helper` ->
            // `.../helper.y`), and a NAMED one identifies it by its basename
            // (`math` -> `math.y`), so both are set and pass 2 can use the second.
            let want_base = "";
            if (want != "") { want_base = basename_of(want); }
            else { want_base = modname + ".y"; };
            // Every name is collected, not the first match: the loop condition used
            // to test `len(out) == 0` as well, so it stopped after ONE member and
            // `helper.` offered `twice` and not `TOP` -- which reads as "this module
            // has one member" rather than as the bug it is.
            //
            // Three passes, and WHICH ONE runs is the whole of it.
            //
            // Pass 1, when the import stated its own target: an exact file match and
            // nothing else. A buffer with two imports used to mix them -- `helper.`
            // offered `thing`, `CONST` AND `math.min`, `math.max`, ... -- because
            // the old test was "any file that is not the buffer's own", which is
            // true for every imported module at once. Offering another module's
            // members is the specific thing this branch exists to prevent, and it
            // was doing it.
            //
            // Pass 2, when it did not -- a std unit is NAMED, not pathed, so there is
            // no target to match. Its file's BASENAME is then the identifier, because
            // a module is named after its file: `math` -> `math.y`. That is exact
            // too, and it is what keeps a buffer's two modules apart.
            //
            // Pass 3, the guess, only when the first two found nothing: every name
            // from a file that is not the buffer's own. Reached only when nothing
            // matched by name, and it can return another module's members -- so it is
            // the last resort rather than the first, which is the whole difference
            // between "usually right" and "right unless you have two imports".
            let pass = 0;
            let got = 0;
            while (pass < 3 && got == 0) {
                let i = 0;
                while (i < len(pr.names)) {
                    let nm = pr.names[i];
                    let f = pr.files[nm];
                    if (is_some(f)) {
                        let fp = f !;
                        let mine = pr.self_path;
                        let take = false;
                        if (pass == 0) { take = want != "" && fp == want; }
                        else if (pass == 1) { take = want_base != "" && basename_of(fp) == want_base; }
                        else { take = fp != mine; };
                        if (take) {
                            // A NAME with no TYPE, deliberately: this is the path
                            // taken when the module was never linked as a unit, so
                            // there is no `Sym` and no type to print. A `tunk`
                            // rendered as "<missing annotation>" would be a type the
                            // compiler never gave us, and the item simply has no
                            // `detail` instead.
                            out += { name: nm, label: "", typ: t_unk() };
                            got = got + 1;
                        };
                    };
                    i = i + 1;
                };
                pass = pass + 1;
            };
        };
    };
    out
}

// A path's file name, with no directory: `helper.y` from `/tmp/ws/helper.y`.
def basename_of(p: str) -> str {
    let cut = last_index_of(p, "/");
    let out = p;
    if (cut >= 0) { out = p[cut + 1:len(p)]; };
    out
}

// A path's directory, with no State: the import's own path is all this needs, and
// threading the server state through to answer "what is next to this file" would
// be a dependency this does not have.
def dir_of_path(p: str) -> str {
    let cut = last_index_of(p, "/");
    if (cut < 0) { "" } else { p[0:cut] }
}

// An `import`'s target, resolved against the importing file's directory.
def resolve_import_path(d: Doc, target: str) -> str {
    let out = target;
    if (len(target) > 0 && target[0:1] == ".") {
        out = norm_path(dir_of_path(d.path) + "/" + target);
    };
    out
}

// What the user types after a `.` for a member the spliced index spells QUALIFIED.
//
// A std unit's declarations keep their `math.` prefix through the splice -- which
// is the compiler's own naming and not something to argue with -- so offering the
// index's spelling verbatim would insert `math.min` after `math.`, giving
// `math.math.min`. Strip the module's own prefix and nothing else: a PATH import's
// members are already bare (`twice`, not `helper.twice`), and stripping a prefix
// that is not there is a no-op.
def module_label(nm: str, modname: str) -> str {
    let out = nm;
    let cut = modname + ".";
    if (modname != "" && len(nm) > len(cut) && nm[:len(cut)] == cut) { out = nm[len(cut):len(nm)]; };
    out
}

// The object's own name at a member position, or "" -- which is what makes
// `module_label` strip the right prefix.
def member_object_name(text: str, sps: [Span], off: long) -> str {
    let out = "";
    let h = object_hit(text, sps, off);
    if (is_some(h)) { let hit: Hit = h !; out = hit.name; };
    out
}

// A module member as a completion item: kind 3, Function, because every export of
// a linked unit is callable or a constant and the protocol has no better single
// answer. The label is the name, which is what the user types.
def module_item(name: str, detail: str) -> json.Val {
    let o = json.obj();
    o["label"] = json.str(name);
    o["sortText"] = json.str(sort_text(name));
    o["kind"] = json.num(3);
    // An empty `detail` is OMITTED rather than sent blank, the same rule the
    // builtins follow: a member whose type the compiler did not give us carries no
    // type rather than an empty one.
    if (detail != "") { o["detail"] = json.str(detail); };
    let te = json.obj();
    te["newText"] = json.str(name);
    o["textEdit"] = json.jobj(te);
    json.jobj(o)
}

// The 0-based character column at which the object of a member access begins, or
// -1 when the object is not something this can type.
//
// ONE identifier, and nothing else. `p.a` is answerable -- the object's type is
// the checker's, and a record's fields come out of it. `a.b.c` is not, because the
// object of the last dot is `a.b`, whose type the position table holds under
// `a`'s own start together with `a`'s; there is no position that means "the
// object of THIS dot", and answering with `a`'s type would be a wrong answer
// presented as a right one.
//
// So the rule is a text one and it refuses rather than approximates: the token
// before the dot must be an identifier, and the token before THAT must not be a
// `.` -- which is what makes it a chain rather than a bare name.
// The 0-based CHARACTER column at which the object of a member access begins, or
// -1 when there is none.
//
// `off` is the BYTE OFFSET of the member position (where the word being typed
// starts), which is what `nav.ident_at` takes and what the caller's `word_start`
// already is. An intermediate version of this took the LINE and a CHARACTER and
// converted them back to an offset -- and passed the byte offset through as the
// character, so on line 8 of a nine-line fixture it asked about byte 124 of line 8,
// which does not exist, found nothing, and answered -1. A record's fields then went
// nowhere and `p.a` offered the string methods that match the prefix. The rule is
// the same one as everywhere else here: bytes go to the scanner, characters come
// back out of it, and the two are converted exactly once, in `ident_at`.
// The identifier immediately before the member position at `off`, or none.
//
// This is the ONE place that steps back over the dot, and everything that needs
// "what is the object of this member access" comes through here -- the type
// lookup, the record fields, the module check. It is one place because a second
// one got it wrong: the type lookup and the module check each asked
// `ident_at(sps, text, off)` at the member position itself, which with nothing
// typed after the dot is the DOT, and a dot is not an identifier. So both
// silently found nothing and `z.` and `math.` fell through to the string methods.
def object_hit(text: str, sps: [Span], off: long) -> Hit? {
    let out: Hit? = none;
    if (off > 0) {
        // Step back over the dot itself and over any space before it, so `x . y`
        // works as well as `x.y` and a cursor sitting ON the dot works too.
        let k = off - 1;
        while (k > 0 && is_blank_at(text[k])) { k = k - 1; };
        out = nav.ident_at(sps, text, k);
    };
    out
}

def object_col(text: str, sps: [Span], off: long) -> long {
    let out = -1;
    let h = object_hit(text, sps, off);
    if (is_some(h)) {
        let hit: Hit = h !;
        let ob = before_dot_col(text, hit.line, hit.ch);
        if (ob < 0) { out = hit.ch; };
    };
    out
}

def is_blank_at(c: long) -> bool { c == 32 || c == 9 }

// The fields of a record type, as the checker's own Field records.
def record_fields(trec: Type) -> [Field] {
    let out: [Field] = [];
    if (trec.k == K.trec) {
        // The cast copies (TRec's layout is the union's shared `k` plus `fields`,
        // so nothing is lost) and is needed: `fields` is not a member of Type,
        // and reading it through the union is a type error rather than a
        // convenient default.
        let r: TRec = trec;
        out = r.fields;
    };
    out
}

def field_name(f: Field) -> str { f.name }
def field_type(f: Field) -> str { tstr(f.typ) }

// `sortText` on every completion item, which R6.3 requires and which was set by
// none of the five builders.
//
// It is the LABEL, and that is the whole of it rather than a stub. `sortText`
// exists to override the editor's sort key, and the only override this language
// would want is a rule that puts `_`-prefixed names first -- the convention in
// every language that has them, and the reason people reach for the field at all.
// No Y name can trigger it: no `src/y/std` unit declares a top-level name starting
// with `_`, and `y_` is the reserved prefix for generated labels, emitted under
// their bare name precisely so they never appear as declarations. So the rule would
// be untestable and the field would be decoration.
//
// Every builder below calls this rather than setting the key itself, so an item
// kind added later cannot forget. `t020_sorttext` asserts all five kinds carry it.
def sort_text(label: str) -> str { label }

// A record field as a completion item: kind 5, Field. `detail` is the field's type
// from the checker, so the list is readable without taking an item, and it is the
// same answer a hover on the field would give (see inferred_at).
def field_item(name: str, detail: str) -> json.Val {
    let o = json.obj();
    o["label"] = json.str(name);
    o["sortText"] = json.str(sort_text(name));
    o["kind"] = json.num(5);
    o["detail"] = json.str(detail);
    let te = json.obj();
    te["newText"] = json.str(name);
    o["textEdit"] = json.jobj(te);
    json.jobj(o)
}

// A declared name as a completion item.
def completion_item(dcl: IdxDecl) -> json.Val {
    let o = json.obj();
    o["label"] = json.str(dcl.name);
    o["sortText"] = json.str(sort_text(dcl.name));
    o["kind"] = json.num(completion_kind(dcl.kind));
    if (dcl.detail != "") { o["detail"] = json.str(dcl.detail); };
    if (dcl.doc != "") {
        let dm = json.obj();
        dm["kind"] = json.str("markdown");
        dm["value"] = json.str(dcl.doc);
        o["documentation"] = json.jobj(dm);
    };
    // The text to insert is the name alone: Y has no argument completion, so
    // inserting a signature would put a `(` in the buffer at a position the
    // user did not ask for one.
    let te = json.obj();
    te["newText"] = json.str(dcl.name);
    o["textEdit"] = json.jobj(te);
    json.jobj(o)
}

// A string method as a completion item: kind 2, Method, which is what an editor
// draws the little `f`-in-a-circle icon for -- the same icon a record's field
// would get, since the two are indistinguishable here. `detail` is the
// signature, so the list is readable without the user taking the item.
//
// This is the one completion kind that DOES have a signature: the builtins below
// do not (Stage A has no types.Binding), and a string method's is the compiler's
// own answer rather than a guess.
def str_method_item(name: str) -> json.Val {
    let o = json.obj();
    o["label"] = json.str(name);
    o["sortText"] = json.str(sort_text(name));
    o["kind"] = json.num(2);
    o["detail"] = json.str(strm.sig(name));
    let te = json.obj();
    te["newText"] = json.str(name);
    o["textEdit"] = json.jobj(te);
    json.jobj(o)
}

// A builtin as a completion item. No detail: Stage A does not know a builtin's
// signature (that is types.Binding, Stage B), and a wrong one is worse than
// none -- the manual has it.
def builtin_item(name: str) -> json.Val {
    let o = json.obj();
    o["label"] = json.str(name);
    o["sortText"] = json.str(sort_text(name));
    o["kind"] = json.num(1);
    let te = json.obj();
    te["newText"] = json.str(name);
    o["textEdit"] = json.jobj(te);
    json.jobj(o)
}

// LSP CompletionItemKind for each kind of declaration index.y records. The
// numbers are the protocol's, and they are what an editor's icon list is
// indexed by: Function 3, Method 2, Variable 6, Constant 21, Class 7 (a `type`
// alias is a class-shaped thing), Module 9 (an `import`).
def completion_kind(kind: long) -> long {
    let k = 6;
    if (kind == scope.D_DEF) { k = 3; }
    else if (kind == scope.D_PARAM) { k = 6; }
    else if (kind == scope.D_CONST) { k = 21; }
    else if (kind == scope.D_TYPE) { k = 7; }
    else if (kind == scope.D_IMPORT) { k = 9; }
    else if (kind == scope.D_SELF) { k = 6; };
    k
}

// A [long] as a JSON array of numbers. JSON has no integer type and `tolong`
// covers every value a position or a length can take.
def numbers(xs: [long]) -> [json.Val] {
    let out: [json.Val] = [];
    foreach (x in xs) { out += json.num(x); }
    out
}

// One symbol, and its children, as the protocol's shape. `range` is what the
// outline uses to draw the extent; `selectionRange` is where "go to symbol" goes,
// which is the NAME -- sending the whole range there is the classic mistake, and
// it makes F2 land on the closing brace of a long function.
def symbols_json(xs: [SymEntry]) -> [json.Val] {
    let out: [json.Val] = [];
    foreach (x in xs) {
        let o = json.obj();
        o["name"] = json.str(x.name);
        if (x.detail != "") { o["detail"] = json.str(x.detail); }
        o["kind"] = json.num(x.kind);
        let rg = json.obj();
        let a = json.obj();
        a["line"] = json.num(x.line);
        a["character"] = json.num(x.ch);
        let b = json.obj();
        b["line"] = json.num(x.end_line);
        b["character"] = json.num(x.end_ch);
        rg["start"] = json.jobj(a);
        rg["end"] = json.jobj(b);
        o["range"] = json.jobj(rg);
        let sr = json.obj();
        let sa = json.obj();
        sa["line"] = json.num(x.sel_line);
        sa["character"] = json.num(x.sel_ch);
        let sb = json.obj();
        sb["line"] = json.num(x.sel_line);
        sb["character"] = json.num(x.sel_ch + len(x.name));
        sr["start"] = json.jobj(sa);
        sr["end"] = json.jobj(sb);
        o["selectionRange"] = json.jobj(sr);
        o["children"] = json.jarr(symbols_json(x.children));
        out += json.jobj(o);
    }
    out
}

// A whole-document edit's end: the last line, and the utf-16 units on it.
def end_position(text: str) -> json.Val {
    let lines = count_lines(text);
    let lbp = pos.line_bytes(text, lines);
    let e = json.obj();
    e["line"] = json.num(lines - 1);
    e["character"] = json.num(pos.u16_len(lbp, len(lbp)));
    json.jobj(e)
}

def count_lines(text: str) -> long {
    let n = 1;
    let i = 0;
    while (i < len(text)) {
        if (byte_at(text, i) == 10) { n = n + 1; }
        i = i + 1;
    }
    n
}

// ── small field readers ─────────────────────────────────────────────────
//
// Every accessor returns a zero value instead of none, because a malformed
// request must not crash the handler that reads it: a client that sends a field
// of the wrong type gets a wrong answer, which is recoverable, where an unwrap
// of none is a dead server.

def field_of(m: { str => json.Val }, k: str) -> json.Val {
    let v = m[k];
    let out = json.nul();
    if is_some(v) { out = v !; }
    out
}

// The members of a value that is an object, or an empty map.
def members_of(v: json.Val) -> { str => json.Val } {
    let m: { str => json.Val } = {};
    if let json.JObj j = v {
        let got = j.members;
        m = got;
    };
    m
}

def str_field(v: json.Val, k: str) -> str {
    let s = "";
    let m = members_of(v);
    let f = m[k];
    if is_some(f) {
        let t = json.as_str(f !);
        if is_some(t) { s = t !; }
    };
    s
}

def long_field(v: json.Val, k: str) -> long {
    let n = 0;
    let m = members_of(v);
    let f = m[k];
    if is_some(f) {
        let t = json.as_long(f !);
        if is_some(t) { n = t !; }
    };
    n
}

// The parameter object of a request. A missing `params` is an empty object
// rather than an error: shutdown legitimately sends none.
def params_of(p: json.Val) -> { str => json.Val } {
    members_of(p)
}

def change_count(ch: json.Val) -> long {
    let n = 0;
    if let json.Arr a = ch {
        let items = a.items;
        n = len(items);
    };
    n
}

def change_at(ch: json.Val, i: long) -> json.Val {
    let out = json.nul();
    if let json.Arr a = ch {
        let items = a.items;
        if (i >= 0 && i < len(items)) { out = items[i]; }
    };
    out
}

export {
    Doc, State, server_state, NO_VERSION,
    E_PARSE, E_INVALID_REQUEST, E_METHOD_NOT_FOUND, E_INVALID_PARAMS,
    E_INTERNAL, E_NOT_INITIALIZED, E_REQUEST_CANCELLED,
    result_msg, error_msg, notify_msg,
    doc_get, doc_has, doc_put, doc_drop, uri_path, doc_dir,
    diag_json, publish_params, publish_for, path_uri, refresh,
    sort_text,
    note_open, note_change, note_close,
    on_did_open, on_did_change, on_did_save, on_did_close, on_exit,
    do_initialize, read_check_on_change, read_timing, do_shutdown, do_formatting,
    do_document_symbols, numbers, symbols_json,
    end_position, count_lines,
    field_of, members_of, str_field, long_field, params_of,
    change_count, change_at, inferred_at, type_at, none_type, before_dot_col, object_col, record_fields, field_item, field_name, field_type
};
