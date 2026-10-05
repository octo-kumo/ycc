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
import sem from "./sem.y";
import sym from "./sym.y";
// scan and index for the M4 handlers: the spans and the declarations they
// resolve against. nav is the lookup itself, kept separate so it can be tested
// without a request or a JSON object in the way.
import scan from "./scan.y";
import scope from "./scope.y";
import nav from "./nav.y";

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
    root: str,          // the workspace root, for a document with no path
    pack: str,          // the std pack, or "" to compile the std units from source
    wlevel: long,       // 0 or 1, as `ycc -W`
    shutting: bool,     // a `shutdown` request has been answered
    exiting: bool,      // an `exit` notification has arrived
    initialized: bool   // `initialize` has been answered
};

def server_state(root: str, pack: str, wlevel: long) -> State {
    let m: { str => Doc } = {};
    let s: State = { docs: m, open: [], root: root, pack: pack, wlevel: wlevel, shutting: false, exiting: false, initialized: false };
    s
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
        if is_some(d) { m[u] = d!; }
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
                let grown: [Finding] = list!;
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
            foreach (x in list!) { items += diag_json(x, text); }
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
        if is_some(got) { out = got!.text; }
    } else {
        let read = fs.read_file(f);
        if is_some(read) { out = read!; }
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
    if is_some(got) { out = publish_for(st, got!); }
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
def on_did_change(st: State, p: { str => json.Val }) -> [str] {
    let uri = str_field(field_of(p, "textDocument"), "uri");
    let out: [str] = [];
    if (doc_has(st, uri)) { out = refresh(st, uri); }
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

    // Semantic tokens (M2). The legend's tokenTypes list IS the wire format --
    // the client sends the same names back and uses the INDICES -- so it is built
    // from sem.token_types() rather than written out here, where the two could
    // drift apart silently and every token after the first difference would be
    // painted as the wrong kind.
    let legend = json.obj();
    let types: [json.Val] = [];
    foreach (t in sem.token_types()) { types += json.str(t); }
    legend["tokenTypes"] = json.jarr(types);
    legend["tokenModifiers"] = json.jarr([]);
    let stp = json.obj();
    stp["legend"] = json.jobj(legend);
    stp["full"] = json.boolean(true);
    caps["semanticTokensProvider"] = json.jobj(stp);

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
        let d: Doc = got!;
        let body = fmt.fmt(d.text);
        if is_some(body) {
            let text2 = body!;
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

// textDocument/semanticTokens/full: the whole buffer, delta encoded (M2, R2).
//
// `full: true` in the capabilities, so no `previousResultId` and no delta against
// a cached result -- the client asks for everything and gets it. R2.4's round
// trip is checked by t010_sem.
def do_semantic_tokens(st: State, id: json.Val, p: { str => json.Val }) -> str {
    let uri = str_field(field_of(p, "textDocument"), "uri");
    let got = doc_get(st, uri);
    let data: [long] = [];
    if is_some(got) {
        let d: Doc = got!;
        data = sem.sem_full_in(pos.doc_of(d.text)).data;
    }
    let r = json.obj();
    r["data"] = json.jarr(numbers(data));
    result_msg(id, json.jobj(r))
}

// textDocument/documentSymbol: the outline, hierarchical.
def do_document_symbols(st: State, id: json.Val, p: { str => json.Val }) -> str {
    let uri = str_field(field_of(p, "textDocument"), "uri");
    let items: [json.Val] = [];
    let got = doc_get(st, uri);
    if is_some(got) {
        let d: Doc = got!;
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
    let out: Pos = { line: 0 - 1, character: 0 - 1 };
    let m = members_of(field_of(p, "position"));
    // Both fields must be there. A position of line 0 / character 0 is a real
    // one (the top-left corner), so "absent" cannot be 0 -- hence -1, and hence
    // checking for the fields rather than defaulting them.
    let ln = field_of(m, "line");
    let gotl = json.as_long(ln);
    if is_some(gotl) {
        let ch = field_of(m, "character");
        let gotc = json.as_long(ch);
        if is_some(gotc) { out = { line: gotl!, character: gotc! }; };
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
        let d: Doc = got!;
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
        let w: Hit = h!;
        let at = request_position(p);
        let found = nav.find_decl(scope.index_src(u.text, ""), w.name, at.line, at.character);
        if (found != none) {
            let dcl: IdxDecl = found!;
            let r = json.obj();
            r["start"] = lsp_pos(dcl.line, dcl.ch);
            r["end"] = lsp_pos(dcl.line, dcl.ch + len(dcl.name));
            let loc = json.obj();
            // The document's OWN uri, not the one from the request: they are the
            // same document by construction (the index is built from this
            // buffer), and reading it back from the request is one more field
            // that could be missing.
            loc["uri"] = json.str(str_field(field_of(p, "textDocument"), "uri"));
            loc["range"] = json.jobj(r);
            answer = json.jobj(loc);
        };
    };
    result_msg(id, answer)
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

// textDocument/hover: the declaration under the cursor, as text.
//
// `null` when the cursor is not on a name this file declares. Stage A does not
// resolve through imports or into std, so hovering a name from another file
// honestly shows nothing rather than showing this file's same-named local.
def do_hover(st: State, id: json.Val, p: { str => json.Val }) -> str {
    let u = word_under(st, p);
    let h: Hit? = u.hit;
    let answer = json.nul();
    if (h != none && u.text != "") {
        let w: Hit = h!;
        let at = request_position(p);
        let found = nav.find_decl(scope.index_src(u.text, ""), w.name, at.line, at.character);
        if (found != none) {
            let dcl: IdxDecl = found!;
            let contents = json.obj();
            contents["kind"] = json.str("markdown");
            contents["value"] = json.str(hover_text(dcl));
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
        let d: Doc = got!;
        let at = request_position(p);
        let sps = scan.scan_full(d.text).spans;
        let col = pos.from_lsp(d.text, at.line, at.character);
        let off = scan.off_at(d.text, pos.src_line(at.line), col);
        let prefix = "";
        if (off >= 0) {
            // The word being typed, so the list can be filtered by what is
            // already there. Read from the BUFFER rather than from the word
            // under the cursor: the cursor is at the END of what has been
            // typed, and nav.ident_at is inclusive of that end, so the half
            // finished identifier is the thing to filter on.
            let w = nav.ident_at(sps, d.text, off);
            if (w != none) {
                let h: Hit = w!;
                if (off >= h.off) { prefix = d.text[h.off:off]; };
            };
        };
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
    let r = json.obj();
    r["isIncomplete"] = json.boolean(true);
    r["items"] = json.jarr(items);
    result_msg(id, json.jobj(r))
}

// A declared name as a completion item.
def completion_item(dcl: IdxDecl) -> json.Val {
    let o = json.obj();
    o["label"] = json.str(dcl.name);
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

// A builtin as a completion item. No detail: Stage A does not know a builtin's
// signature (that is types.Binding, Stage B), and a wrong one is worse than
// none -- the manual has it.
def builtin_item(name: str) -> json.Val {
    let o = json.obj();
    o["label"] = json.str(name);
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

// A [long] as a JSON array of numbers. JSON has no integer type and `tonum`
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
    if is_some(v) { out = v!; }
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
        let t = json.as_str(f!);
        if is_some(t) { s = t!; }
    };
    s
}

def long_field(v: json.Val, k: str) -> long {
    let n = 0;
    let m = members_of(v);
    let f = m[k];
    if is_some(f) {
        let t = json.as_long(f!);
        if is_some(t) { n = t!; }
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
  note_open, note_change, note_close,
  on_did_open, on_did_change, on_did_save, on_did_close, on_exit,
  do_initialize, do_shutdown, do_formatting,
  do_semantic_tokens, do_document_symbols, numbers, symbols_json,
  end_position, count_lines,
  field_of, members_of, str_field, long_field, params_of,
  change_count, change_at
};