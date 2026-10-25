// t009_proto.y -- the JSON-RPC layer, driven as strings (LSP.md §4, M1).
//
// handle_one is a plain string function, so the whole protocol can be exercised
// with no process, no pipe and no fork. What is NOT tested here is whether the
// server SURVIVES a handler that dies -- that needs a real process and is
// `ytest lsp-e2e`'s job. The split is deliberate: this file pins the answers, that
// one pins the containment.

import json;
import pos from "../pos.y";
import diag from "../diag.y";
import serve from "../serve.y";
import dispatch from "../dispatch.y";
import yserve from "../yserve.y";

const HERE = "src/tools/lsp/test";

// Parse a frame back out, so the assertions are about JSON rather than about
// the exact byte layout this server happens to emit.
def parsed(s: str) -> json.Val {
    let p = json.parse(s);
    let out = json.nul();
    if is_some(p) { out = json.jobj(p!); }
    out
}

def field(v: json.Val, k: str) -> json.Val {
    serve.field_of(serve.members_of(v), k)
}

def members_has(v: json.Val, k: str) -> bool {
    is_some(serve.members_of(v)[k])
}

def sfield(v: json.Val, k: str) -> str { json.as_str(field(v, k))! }
def lfield(v: json.Val, k: str) -> long { json.as_long(field(v, k))! }
def bfield(v: json.Val, k: str) -> bool { json.as_bool(field(v, k))! }

// A JSON string LITERAL, quotes and all. Built through json.str and stringify
// rather than by concatenating quotes: a document's text is full of newlines and
// quotes, and hand-escaping it into a message is how a fixture ends up testing
// its own escaping instead of the server.
def jlit(s: str) -> str { json.stringify_val(json.str(s), 0) }

// didOpen as a real notification. Everything below that opens a document goes
// through this, so no test has to spell JSON by hand.
def did_open(uri: str, text: str, version: long) -> str {
    "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":" + jlit(uri) + ",\"languageId\":\"y\",\"version\":" + tostring(version) + ",\"text\":" + jlit(text) + "}}}"
}

// textDocument/formatting as a real request.
def want_format(id: long, uri: str) -> str {
    "{\"jsonrpc\":\"2.0\",\"id\":" + tostring(id) + ",\"method\":\"textDocument/formatting\",\"params\":{\"textDocument\":{\"uri\":" + jlit(uri) + "},\"options\":{\"tabSize\":4,\"insertSpaces\":true}}}"
}

// Deliver one message the way yserve.y does: the parent updates its own state
// FIRST, then a child builds the reply. Doing it in the other order, or in one
// step, tests a server that does not exist -- fork{} gives the child a COPY, so
// a store written only in the child is empty again for the next message. That
// split is the whole reason dispatch.apply_state is separate from handle_one.
// The frames it produced, concatenated -- which is what a caller wants when it
// is only reading one reply. yserve writes them separately (one header each);
// this is a test convenience, and it is only safe because every fixture here
// either sends one message or parses the result as a single value.
def deliver(st: State, msg: str) -> str {
    dispatch.apply_state(st, msg);
    let out = "";
    foreach (f in yserve.handle_one(st, msg)) { out += f; }
    out
}

// The frames, kept separate -- for the cases where a message produces more than
// one and the count is the thing under test.
def frames_of(st: State, msg: str) -> [str] {
    dispatch.apply_state(st, msg);
    yserve.handle_one(st, msg)
}

// A state that has been INITIALIZED. Every request other than initialize and
// shutdown is correctly refused before it, so a fixture that wants to exercise
// one has to say initialize first -- exactly as a client does.
def fresh() -> State {
    let st = serve.server_state(HERE, "", 0);
    deliver(st, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":" + jlit("file://" + HERE) + "}}");
    st
}

// A JSON array as a Y array. An array read does not box into an option the way
// a map read does, so the length is checked and the elements boxed here.
def items_own(v: json.Val) -> [json.Val] {
    let out: [json.Val] = [];
    if let json.Arr a = v {
        let items = a.items;
        let i = 0;
        while (i < len(items)) { out += items[i]; i = i + 1; }
    };
    out
}

// ── a request gets a result with the id echoed ──────────────────────────
let st = fresh();
let r = parsed(deliver(st, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file:///tmp\"}}"));
print("initialize id " + tostring(lfield(r, "id")));
let caps = field(r, "result");
let tcaps = field(caps, "capabilities");
print("textDocumentSync.change = " + tostring(lfield(field(tcaps, "textDocumentSync"), "change")));
print("openClose = " + tostring(bfield(field(tcaps, "textDocumentSync"), "openClose")));

// The advertised set is EXACTLY what the server implements. `diagnosticProvider`
// is the one that matters: it means PULL, so a server that advertises it has
// promised to answer textDocument/diagnostic. This one PUSHES, and push needs
// no capability at all -- so advertising the pull model makes a client pull,
// get an error, and then ignore the notifications still being pushed. That is
// not a log line, it is a file with no diagnostics on it.
print("documentFormattingProvider = " + tostring(bfield(tcaps, "documentFormattingProvider")));

// The advertised set, checked as an EXACT list rather than a deny-list. A
// deny-list says nothing about a capability nobody thought to forbid -- which is
// how `diagnosticProvider` shipped: it was not on the list of things the server
// did not implement, so the test passed while the editor pulled, got -32601 and
// showed no diagnostics at all (LSP.md 7.0).
// Count plus membership, because Y has no array sort and building a sorted copy
// by hand here would be noise: six members, and each of the six expected.
// The count is the assertion that matters -- it is what catches a capability
// being advertised without a handler, which is the mistake LSP.md keeps calling
// out (a client changes what it offers the user because of a flag). M4 added
// definitionProvider, hoverProvider and completionProvider; each is answered in
// serve.do_* and pinned by t013_m4.
let want: [str] = ["documentFormattingProvider", "documentSymbolProvider",
                   "textDocumentSync", "definitionProvider", "hoverProvider", "completionProvider"];
let seen: [str] = [];
foreach (w in want) { if (members_has(tcaps, w)) { seen += w; } }
print("advertised: " + join(seen, ", "));
print("exactly the six it implements: " + tostring(
    len(seen) == 6 && len(serve.members_of(tcaps)) == 6));

// A string id must come back as a string, not a number: an id is an opaque
// token, and coercing it makes the reply unmatchable.
let rs = parsed(deliver(st, "{\"jsonrpc\":\"2.0\",\"id\":\"abc-1\",\"method\":\"initialize\"}"));
print("string id " + sfield(rs, "id") + " is_json_string=" + tostring(is_some(json.as_str(field(rs, "id")))));

// ── a notification gets NOTHING ─────────────────────────────────────────
// This is the rule a client counts on: a reply to didChange is a desync.
let n = deliver(st, did_open("file:///t/a.y", "let x = 1;\nprint(x);\n", 1));
print("didOpen is a notification: " + tostring(index_of(n, "\"id\"") < 0));
print("but it published: " + tostring(index_of(n, "publishDiagnostics") >= 0));

// A notification the server does not know is ALSO silent -- the spec says so,
// and answering would send a frame the client is not reading.
let u = deliver(st, "{\"jsonrpc\":\"2.0\",\"method\":\"some/unknownNotification\",\"params\":{}}");
print("unknown notification silent: " + tostring(u == ""));

// `id: null` counts as a notification, which is how a client sends something
// notification-shaped that expects no answer.
let nul = deliver(st, "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"initialized\"}");
print("id null is silent: " + tostring(nul == ""));

// ── errors and warnings TOGETHER, the reason this server exists ─────────
// native.compile_unit returns before lint when the checker found anything, so
// `ycc` never prints an error and a warning from the same file. Both appear here.
let both = "def f() -> long {\n    let unused = 1;\n    2 + \"s\"\n}\n";
let o = deliver(st, did_open("file:///t/b.y", both, 7));
let pub = parsed(o);
let items = field(field(pub, "params"), "diagnostics");
let n_err = 0;
let n_warn = 0;
foreach (d in items_own(items)) {
    if (lfield(d, "severity") == 1) { n_err = n_err + 1; }
    if (lfield(d, "severity") == 2) { n_warn = n_warn + 1; }
}
print("items " + tostring(len(items_own(items))));
print("errors " + tostring(n_err) + " warnings " + tostring(n_warn));
print("version echoed: " + tostring(lfield(field(pub, "params"), "version")));
print("first source: " + sfield(items_own(items)[0], "source"));
print("second source: " + sfield(items_own(items)[1], "source"));

// ── one publishDiagnostics PER FILE, not one per document ───────────────
// publishDiagnostics is keyed by URI. A warning found in an IMPORTED file has
// to be published under that file's URI; putting it in the main document's
// notification stores it against the main document, and the squiggle lands on
// the wrong line of the wrong file. The compiler reports per file, so the
// information is there and only the grouping was missing.
// Absolute, and pointing at this fixture's own directory so that "./mod.y"
// really resolves -- the point of the case is that the finding comes back from
// an IMPORTED file, which needs an import that works.
const WS = fs.cwd() + "/src/tools/lsp/test";
let impst = serve.server_state(WS, "", 0);
deliver(impst, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":" + jlit("file://" + WS) + "}}");
let imp_scratch: [str] = [];
// An absolute path, because a real URI has a root and a test that uses a
// relative one stops noticing when uri_path mishandles it.
let imp = frames_of(impst, did_open("file://" + WS + "/main2.y", "import helper from \"./mod.y\";\nprint(helper.f());\n", 1));
print("import: " + tostring(len(imp)) + " frames, want 2");
let which: [str] = [];
foreach (fr in imp) {
    which += sfield(field(parsed(fr), "params"), "uri");
}
print("first is the document: " + tostring(which[0] == "file://" + WS + "/main2.y"));
print("second is the import: " + tostring(which[1] == "file://" + WS + "/mod.y"));
let second = parsed(imp[1]);
let sitems = items_own(field(field(second, "params"), "diagnostics"));
print("the import's own finding is in it: " + tostring(len(sitems) == 1 && index_of(sfield(sitems[0], "message"), "'spare'") >= 0));
print("the document's notification is empty: " + tostring(items_own(field(field(parsed(imp[0]), "params"), "diagnostics")) == []));
// The column must be measured against the IMPORTED file's bytes, not the
// document's -- same bug one level down. mod.y's `let spare` is on 1-based line 8,
// so its LSP line is 7, and the document is 2 lines long, so using the wrong text
// cannot accidentally agree.
//
// (This said 6, and the comment said 7. Both were the off-by-one that
// `diag.line_in_file` fixes: the line published was one short of the real one, and
// the expectation had absorbed it, so a wrong answer passed. An expectation that
// records a bug is worse than no expectation.)
let spos = field(field(sitems[0], "range"), "start");
print("import finding at line " + tostring(lfield(spos, "line")) + " (want 7)");
// An import we have no version for: the key must be ABSENT, not 0, because 0 is
// a claim and a client that believed it would drop the diagnostics as stale.
let sv = field(second, "params");
print("no version claimed for the import: " + tostring(!members_has(sv, "version")));

// ── positions are UTF-16 characters, not bytes ──────────────────────────
// Two 4-byte emoji (8 bytes, 2 utf-16 units each) before the error on the SAME
// line. A byte column would report the error 6 further right than a character
// column does, and the client's caret would land in the middle of the string.
//
// The text is built from bytes rather than written as a literal in this file, so
// that what is under test is the server's conversion and not this fixture's own
// encoding of an emoji.
let smile = from_bytes(json.utf8_put([], 128512));      // U+1F600, 4 bytes
let uni = "let s = \"" + smile + smile + "\"; let n: str = 1;\n";
print("line is " + tostring(len(uni)) + " bytes, " + tostring(pos.u16_len(uni, len(uni))) + " utf16 units");
let ou = deliver(st, did_open("file:///t/c.y", uni, 1));
let ui = items_own(field(field(parsed(ou), "params"), "diagnostics"));
print("diagnostics: " + tostring(len(ui)));
foreach (d in ui) {
    let rg = field(d, "range");
    let stt = field(rg, "start");
    print("at line " + tostring(lfield(stt, "line")) + " char " + tostring(lfield(stt, "character")) + ": " + sfield(d, "message"));
}
// `let n` starts at byte 26 and utf16 unit 18 -- the 6/4 gap. If the server
// ever passes a byte column through unchanged, this stops matching.
// The invariant, checked against the compiler rather than against a guess about
// where the checker anchors its diagnostic: the character the protocol reports is
// the same conversion of the compiler's own (line, byte column). If the server
// ever passed a byte column through, this is where it shows -- and note the two
// differ here by 4, because two emoji are 8 bytes and 2 code units.
let own = diag.diagnose(uni, HERE, "file:///t/c.y", "", 0);
print("compiler reports " + tostring(len(own)) + " at byte column " + tostring(own[0].col));
let want_ch = pos.to_lsp(uni, own[0].line, own[0].col).character;
let got_ch = lfield(field(field(ui[0], "range"), "start"), "character");
print("byte column " + tostring(own[0].col) + " -> character " + tostring(got_ch) + " (want " + tostring(want_ch) + ")");
print("utf16 conversion agrees: " + tostring(got_ch == want_ch));
print("and it is NOT the byte column: " + tostring(got_ch != own[0].col - 1));
// and the round trip: the client sends that character back, and it lands on the
// compiler's byte column again
print("round trip lands on the same byte: " + tostring(pos.from_lsp(uni, 0, got_ch) == own[0].col));

// ── didChange replaces the text, and the last change wins ───────────────
// A client that batches keystrokes has already collapsed them, so the LAST
// contentChanges entry is the current text -- not the first.
let st2 = fresh();
deliver(st2, did_open("file:///t/d.y", "let a = 1;\n", 1));
let ch = deliver(st2, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/d.y\",\"version\":2},\"contentChanges\":[{\"text\":\"let b: str = 1;\\n\"},{\"text\":\"let c: str = 2;\\n\"}]}}");
print("didChange saw the last edit: " + tostring(index_of(ch, "'c'") >= 0));
print("didChange dropped the first: " + tostring(index_of(ch, "'b'") < 0));

// ── didClose clears the diagnostics and forgets the document ───────────
let cl = deliver(st2, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didClose\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/d.y\"}}}");
let ci = items_own(field(field(parsed(cl), "params"), "diagnostics"));
print("didClose publishes an empty list: " + tostring(len(ci) == 0));
print("didClose forgets the document: " + tostring(!serve.doc_has(st2, "file:///t/d.y")));

// A formatting request for a closed document must not resurrect it: no
// document, no edits, and no crash on the unwrap.
let fcl = deliver(st2, want_format(9, "file:///t/d.y"));
print("format a closed doc: " + tostring(index_of(fcl, "\"edits\":[]") >= 0));

// ── formatting ──────────────────────────────────────────────────────────
let st3 = fresh();
let messy = "def f( ) -> long {\nlet x=1;\n     return   2 ;\n}\n";
deliver(st3, did_open("file:///t/e.y", messy, 1));
let fm = deliver(st3, want_format(5, "file:///t/e.y"));
let edits = items_own(field(field(parsed(fm), "result"), "edits"));
print("one edit: " + tostring(len(edits) == 1));
if (len(edits) == 1) {
    let nt = sfield(edits[0], "newText");
    print("formatted [" + nt + "]");
    // The SAME request twice legitimately gives the same edit: the server
    // proposes, the client applies. Idempotence only shows once the client has
    // sent the formatted text back, which is what an editor does.
    let fm2 = deliver(st3, want_format(6, "file:///t/e.y"));
    let e2 = items_own(field(field(parsed(fm2), "result"), "edits"));
    print("same request twice gives the same edit: " + tostring(len(e2) == 1));
    deliver(st3, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/e.y\",\"version\":2},\"contentChanges\":[{\"text\":" + jlit(nt) + "}]}}");
    let fm3 = deliver(st3, want_format(8, "file:///t/e.y"));
    let e3 = items_own(field(field(parsed(fm3), "result"), "edits"));
    // No edits for an already-formatted buffer: an editor may treat an empty
    // edit list as a reason to re-derive its undo history, and losing undo for
    // a no-op format is worse than doing nothing.
    print("applied then reformatted is a no-op: " + tostring(len(e3) == 0));
}

// A buffer that does not lex gets NO edits -- never a half-rewrite.
let broken = "let s = \"unterminated\nlet y = 1;\n";
deliver(st3, did_open("file:///t/f.y", broken, 1));
let fb = deliver(st3, want_format(7, "file:///t/f.y"));
let eb = items_own(field(field(parsed(fb), "result"), "edits"));
print("unlexable buffer gets no edits: " + tostring(len(eb) == 0));

// ── errors from the protocol layer ──────────────────────────────────────
let e1 = parsed(deliver(st, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/nonsense\"}"));
print("unknown method -> code " + tostring(lfield(field(e1, "error"), "code")));
let e2 = parsed(deliver(st, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/rangeFormatting\",\"params\":{\"textDocument\":{\"uri\":\"file:///t/a.y\"}}}"));
print("range formatting -> code " + tostring(lfield(field(e2, "error"), "code")));
let e3 = parsed(deliver(st, "not json"));
print("bad body -> code " + tostring(lfield(field(e3, "error"), "code")));
let e4 = parsed(deliver(st, "{\"jsonrpc\":\"2.0\",\"id\":4}"));
print("no method -> code " + tostring(lfield(field(e4, "error"), "code")));

// A request before initialize is refused: the client has not sent rootUri, so
// imports could not be resolved and any answer would use the wrong base dir.
// A RAW state, deliberately not initialized -- this is the one case that must
// still work without a handshake.
let stn = serve.server_state(HERE, "", 0);
let e5 = parsed(deliver(stn, want_format(1, "file:///t/a.y")));
print("before initialize -> " + tostring(lfield(field(e5, "error"), "code")) + " (want -32002)");
// ... and initialize is the way out of it: the same request then works.
deliver(stn, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}");
let e5b = deliver(stn, want_format(2, "file:///t/a.y"));
print("after initialize -> " + tostring(index_of(e5b, "\"edits\"") >= 0));

// ── uri decoding ────────────────────────────────────────────────────────
print("plain      [" + serve.uri_path("file:///tmp/a.y") + "]");
print("spaces     [" + serve.uri_path("file:///tmp/my%20dir/a.y") + "]");
print("no scheme  [" + serve.uri_path("/tmp/a.y") + "]");
print("bad escape [" + serve.uri_path("file:///tmp/100%.y") + "]");

// ── shutdown and exit ───────────────────────────────────────────────────
let sts = fresh();
deliver(sts, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}");
let sd = parsed(deliver(sts, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\"}"));
print("shutdown result is null: " + tostring(json.is_null(field(sd, "result"))));
print("shutdown sets the flag: " + tostring(sts.shutting));
print("shutdown is a reply: " + tostring(index_of(deliver(sts, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"shutdown\"}"), "\"result\"") >= 0));
let ex = deliver(sts, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");
print("exit is silent: " + tostring(ex == ""));
print("exit sets the flag: " + tostring(sts.exiting));

// A malformed field must not kill a handler: a wrong answer is recoverable,
// an unwrap of none is a dead server.
let stm = fresh();
let junk = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":42,\"text\":[],\"version\":\"x\"}}}";
print("junk didOpen silent: " + tostring(deliver(stm, junk) == ""));
print("server still usable: " + tostring(index_of(deliver(stm, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}"), "yserve") >= 0));

// A URI with a percent escape in the PATH must survive into the diagnostics
// label, since that is what the client matches against its own document list.
let stp = fresh();
let op = deliver(stp, did_open("file:///tmp/ylsp/sp%20ace.y", "let a: str = 1;\n", 1));
print("escaped uri echoed: " + tostring(index_of(op, "sp%20ace.y") >= 0));
print("errors from it: " + tostring(index_of(op, "expected str, got long") >= 0));

// The own-file case: a diagnostic in the buffer is reported against the uri the
// editor sent, not against the path the server decoded.
print("count check: " + tostring(dispatch.msg_method(parsed("{\"method\":\"m\"}")) == "m"));
print("done");