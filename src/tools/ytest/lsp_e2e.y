// lsp_e2e.y -- `ytest lsp-e2e`: the language server as a PROCESS (LSP.md §4.2).
//
// t009_proto pins the answers; this pins what only a real process can show:
// that a handler which dies takes nothing with it. The compiler the server
// drives is built to run once and exit -- lexer.tokenize exits on an
// unterminated string or block comment, native_resolve_x on an import it
// cannot open, a run never frees its heap -- and each is an ordinary editor
// event. yserve forks per message, so the parent only ever holds a read buffer
// and a cursor. So these send the server things that kill a handler, and check
// it still answers; plus the document store across messages, one
// publishDiagnostics per file, and the framing. Then, when node and the
// extension's node_modules are there, the real LSP client library
// (client-check.js) and the extension's own activate() (activation-check.js).
import fs;
import json;
import yt;
import yc;

let BIN = "";
let NFAIL = 0;
let NPASS = 0;

def check(name: str, ok: bool, detail: str) {
    if (ok) {
        print("ok       " + name);
        NPASS += 1;
    } else {
        print("FAIL     " + name + (if (detail != "") { "   [" + detail + "]" } else { "" }));
        NFAIL += 1;
    };
};

def frame(body: str) -> str { "Content-Length: " + tostring(body.length) + "\r\n\r\n" + body };

def q(s: str) -> str { "\"" + json.escape(s) + "\"" };

let INIT = "{\"jsonrpc\": \"2.0\", \"id\": 1, \"method\": \"initialize\", \"params\": {\"rootUri\": \"file://.\", \"capabilities\": {}}}";

def open_doc(uri: str, text: str) -> str {
    "{\"jsonrpc\": \"2.0\", \"method\": \"textDocument/didOpen\", \"params\": {\"textDocument\": {\"uri\": " + q(uri)
        + ", \"languageId\": \"y\", \"version\": 1, \"text\": " + q(text) + "}}}"
};

def fmt_req(id: long, uri: str) -> str {
    "{\"jsonrpc\": \"2.0\", \"id\": " + tostring(id) + ", \"method\": \"textDocument/formatting\", \"params\": "
        + "{\"textDocument\": {\"uri\": " + q(uri) + "}, \"options\": {\"tabSize\": 4, \"insertSpaces\": true}}}"
};

def req(id: long, method: str) -> str {
    "{\"jsonrpc\": \"2.0\", \"id\": " + tostring(id) + ", \"method\": " + q(method) + "}"
};

def note(method: str) -> str { "{\"jsonrpc\": \"2.0\", \"method\": " + q(method) + ", \"params\": {}}" };

/** One run: the exit code and the replies (none for a frame that did not parse). */
type Run = { code: long, replies: [json.Val?], err: str };

def run(msgs: [str], cwd: str) -> Run {
    let input = "";
    foreach (m in msgs) { input += frame(m); };
    let c = yt.cmd([BIN, "--root", cwd]);
    c.input = input;
    c.cwd = cwd;
    c.timeout = 180;
    let r = yt.run(c);
    let out = r.out;
    let replies: [json.Val?] = [];
    let i = 0;
    let go = true;
    while (go) {
        let j = out.index_of("\r\n\r\n", i);
        if (j < 0) {
            go = false;
        } else {
            let n = -1;
            foreach (h in out[i:j].split("\r\n")) {
                if (h.lower().starts_with("content-length")) { n = yt.num(h[h.index_of(":") + 1:].trim(), -1); };
            };
            if (n < 0) {
                go = false;
            } else {
                replies += json.parse_val(out[j + 4:j + 4 + n]);
                i = j + 4 + n;
            };
        };
    };
    { code: r.code, replies: replies, err: r.err }
};

def get(v: json.Val?, k: str) -> json.Val? {
    if (v == none) { none } else { json.field(v!, k) }
};

def str_of(v: json.Val?) -> str {
    if (v == none) { return ""; };
    let s = json.as_str(v!);
    if (s == none) { "" } else { s! }
};

def long_of(v: json.Val?) -> long {
    if (v == none) { return -1; };
    let n = json.as_long(v!);
    if (n == none) { -1 } else { n! }
};

def arr_of(v: json.Val?) -> [json.Val] {
    if (v == none) { return []; };
    let a = json.as_arr(v!);
    if (a == none) { [] } else { a! }
};

def find(rs: [json.Val?], id: long) -> json.Val? {
    foreach (r in rs) {
        if (r != none && get(r, "id") != none && long_of(get(r, "id")) == id) { return r; };
    };
    none
};

def method_of(r: json.Val?) -> str { str_of(get(r, "method")) };

// Every diagnostic of every publishDiagnostics notification.
def diags(rs: [json.Val?]) -> [json.Val] {
    let out: [json.Val] = [];
    foreach (r in rs) {
        if (method_of(r) == "textDocument/publishDiagnostics") { out += arr_of(get(get(r, "params"), "diagnostics")); };
    };
    out
};

def edits(r: json.Val?) -> [json.Val]? {
    let e = get(get(r, "result"), "edits");
    if (e == none) { none } else { json.as_arr(e!) }
};

def ec(r: Run) -> str { "exit " + tostring(r.code) };

def sessions() {
    // 1. a normal session
    let r = run([INIT, note("initialized"), open_doc("file:///t/a.y", "def f() -> long {\n    let unused = 1;\n    2 + \"s\"\n}\n"),
                 fmt_req(2, "file:///t/a.y"), req(3, "shutdown"), note("exit")], ".");
    check("normal: clean exit", r.code == 0, ec(r) + " " + yt.clip(r.err, 200));
    check("normal: initialize answered", find(r.replies, 1) != none, "");
    let caps = get(get(find(r.replies, 1), "result"), "capabilities");
    check("normal: sync declared", get(caps, "textDocumentSync") != none, "");
    let fp = get(caps, "documentFormattingProvider");
    check("normal: formatting declared", fp != none && json.as_bool(fp!) == some(true), "");
    let d = diags(r.replies);
    let errs = 0;
    let warns = 0;
    foreach (x in d) {
        let sev = long_of(json.field(x, "severity"));
        if (sev == 1) { errs += 1; };
        if (sev == 2) { warns += 1; };
    };
    check("normal: error found", errs >= 1, "");
    check("normal: warning found too", warns >= 1, "the whole point: ycc prints one or the other, never both");
    check("normal: shutdown answered", find(r.replies, 3) != none, "");
    // 2. an unterminated string: exit(1) inside lexer.tokenize
    r = run([INIT, open_doc("file:///t/b.y", "let s = \"oops\nlet t = 1;\n"), fmt_req(2, "file:///t/b.y"),
             open_doc("file:///t/c.y", "let x = 1;\nprint(x);\n"), req(9, "shutdown")], ".");
    check("unterminated string: server survives", r.code == 0, ec(r));
    check("unterminated string: reported", diags(r.replies).length >= 1, "");
    check("unterminated string: next request answered", find(r.replies, 9) != none, "the handler died and the parent kept going");
    // 3. an unterminated block comment: the other exit(1) in the lexer
    r = run([INIT, open_doc("file:///t/d.y", "/* never closed\nlet x = 1;\n"), open_doc("file:///t/e.y", "let y = 1;\nprint(y);\n"),
             req(9, "shutdown")], ".");
    check("unterminated comment: server survives", r.code == 0, ec(r));
    check("unterminated comment: reported", diags(r.replies).length >= 1, "");
    check("unterminated comment: next request answered", find(r.replies, 9) != none, "");
    // 4. an import that does not exist: exit(1) in native_resolve_x
    r = run([INIT, open_doc("file:///t/f.y", "import nope from \"./does_not_exist.y\";\nprint(1);\n"), req(9, "shutdown")], ".");
    check("missing import: server survives", r.code == 0, ec(r));
    check("missing import: next request answered", find(r.replies, 9) != none, "native_resolve_x called exit(1) in the child");
    // 5. a large file, and a deeply nested one
    let big = "";
    for i in 0..4000 { big += "let v" + tostring(i) + " = " + tostring(i) + ";\n"; };
    let deep = "let x = " + "(".repeat(200) + "1" + ")".repeat(200) + ";\n";
    r = run([INIT, open_doc("file:///t/g.y", big), open_doc("file:///t/h.y", deep), req(9, "shutdown")], ".");
    check("large and deep: server survives", r.code == 0, ec(r));
    check("large and deep: next request answered", find(r.replies, 9) != none, "");
    // 6. junk that is not a message: no id to answer, and the next one works
    r = run([INIT, open_doc("file:///t/i.y", "let x = 1;\n"), "{\"jsonrpc\": \"2.0\", \"id\": 4}", req(5, "no/such/method"),
             req(9, "shutdown")], ".");
    check("junk: server survives", r.code == 0, ec(r));
    check("junk: no-method answered", find(r.replies, 4) != none, "");
    check("junk: unknown method is an error", get(find(r.replies, 5), "error") != none, "");
    check("junk: shutdown still answered", find(r.replies, 9) != none, "");
    // 7. a request naming a document that was never opened
    r = run([INIT, fmt_req(2, "file:///t/never-opened.y"), open_doc("file:///t/j.y", "let x = 1;\n"), req(9, "shutdown")], ".");
    check("unknown document: answered, not a crash", find(r.replies, 2) != none, "");
    let e = edits(find(r.replies, 2));
    check("unknown document: empty edits", e != none && e!.length == 0, "");
    check("unknown document: server survives", r.code == 0, ec(r));
    // 8. THE STATE SPLIT: a document opened in one message survives into the
    // next. fork gives the child a COPY, so a child-local store would answer
    // the second format with no edits -- which looks like "already formatted".
    r = run([INIT, open_doc("file:///t/p.y", "let a  =  1;\n"), fmt_req(2, "file:///t/p.y"), fmt_req(3, "file:///t/p.y"),
             req(9, "shutdown")], ".");
    let e2 = edits(find(r.replies, 2));
    let e3 = edits(find(r.replies, 3));
    let both = e2 != none && e3 != none && e2!.length == 1 && e3!.length == 1;
    check("store: the document is still open in the next message", both, "");
    check("store: the document really was still formatted the same way",
        both && str_of(json.field(e2![0], "newText")) == str_of(json.field(e3![0], "newText")), "");
    // and after didClose it is GONE: formatting does not resurrect it
    r = run([INIT, open_doc("file:///t/q.y", "let a  =  1;\n"),
             "{\"jsonrpc\": \"2.0\", \"method\": \"textDocument/didClose\", \"params\": {\"textDocument\": {\"uri\": \"file:///t/q.y\"}}}",
             fmt_req(4, "file:///t/q.y")], ".");
    let e4 = edits(find(r.replies, 4));
    check("store: a closed document is forgotten", e4 != none && e4!.length == 0, "");
    per_file();
    // 9. stdin closing mid-session: a clean stop, not an error
    r = run([INIT, open_doc("file:///t/k.y", "let x = 1;\n")], ".");
    check("stdin closed: exit 0", r.code == 0, ec(r));
    // 10. every frame is well formed: the client's framing never desyncs
    r = run([INIT, open_doc("file:///t/l.y", "def f() -> long {\n    let u = 1;\n    2 + \"s\"\n}\n"),
             open_doc("file:///t/m.y", "let z: str = 1;\n"), fmt_req(2, "file:///t/l.y"), req(3, "shutdown"), note("exit")], ".");
    let unparsed = 0;
    let shaped = true;
    let noid = true;
    foreach (x in r.replies) {
        if (x == none) {
            unparsed += 1;
        } else {
            if (get(x, "id") == none && get(x, "method") == none) { shaped = false; };
            if (get(x, "method") != none && get(x, "id") != none) { noid = false; };
        };
    };
    check("framing: no unparsed frame", unparsed == 0, tostring(unparsed) + " unparsed");
    check("framing: every reply has an id or a method", shaped, "");
    check("framing: notifications carry no id", noid, "");
    check("framing: exit stops the loop", r.code == 0, ec(r));
};

// 8b. ONE publishDiagnostics PER FILE: keyed by URI, so a finding in an
// IMPORTED file is published under that file's URI; in the main document's
// notification the squiggle lands on the wrong line of the wrong file.
def per_file() -> void {
    let ws = yt.tmp_dir("lspws");
    yt.write(ws + "/mod.y", "// café\ndef f() -> long {\n    let spare = 1;\n    7\n}\n");
    let r = run([INIT, open_doc("file://" + ws + "/main.y", "import helper from \"./mod.y\";\nprint(helper.f());\n"), req(9, "shutdown")], ws);
    let main_uri = "file://" + ws + "/main.y";
    let mod_uri = "file://" + ws + "/mod.y";
    let uris: [str] = [];
    let mod_d: [json.Val] = [];
    let main_d: [json.Val] = [];
    let mod_version = false;
    foreach (x in r.replies) {
        if (method_of(x) == "textDocument/publishDiagnostics") {
            let p = get(x, "params");
            let u = str_of(get(p, "uri"));
            uris += u;
            if (u == mod_uri) {
                mod_d = arr_of(get(p, "diagnostics"));
                if (get(p, "version") != none) { mod_version = true; };
            };
            if (u == main_uri) { main_d = arr_of(get(p, "diagnostics")); };
        };
    };
    let seen = join(uris, ", ");
    check("per-file: the document gets its own notification", main_uri in uris, "got [" + seen + "]");
    check("per-file: the import gets its own notification", mod_uri in uris, "got [" + seen + "]");
    let one = mod_d.length == 1;
    check("per-file: the import's finding is under the import", one && str_of(json.field(mod_d[0], "message")).contains("spare"), "");
    let leak = false;
    foreach (x in main_d) {
        if (str_of(json.field(x, "message")).contains("spare")) { leak = true; };
    };
    check("per-file: the document's notification is not carrying it", !leak, "");
    check("per-file: the column is measured in the IMPORTED file",
        one && long_of(get(get(json.field(mod_d[0], "range"), "start"), "line")) == 2, "");
    check("per-file: no version claimed for a file we were not told about", !mod_version, "");
    fs.remove_all(ws);
};

/** `ytest lsp-e2e`: build yserve with YCC, drive it, then the node checks. */
def main(av: [str]) -> long {
    let out = yt.tmp_dir("lsp-e2e");
    BIN = out + "/yserve";
    let bare = out + "/yserve0";
    let b = yc.compile(yc.YCC, [], yc.ROOT + "/src/tools/lsp/yserve.y", bare, 600);
    if (b.code != 0) {
        print("FAIL     yserve does not build");
        print(yt.clip(b.out, 600));
        return 1;
    };
    // with its std pack attached, as `make yserve` builds it: a bare server finds
    // no std source from a workspace outside the tree
    let p = yt.exe2([bare, "--std-pack", out + "/yserve.pack"]);
    if (p.code != 0 || !yt.concat(BIN, [bare, out + "/yserve.pack"])) {
        print("FAIL     yserve --std-pack: " + yt.clip(p.out, 300));
        return 1;
    };
    fs.set_mode(BIN, 0o755);
    // the server is held to the compiler's own bar: no warning
    check("yserve compiles without a warning", !b.out.contains(": warning: "), yt.clip(b.out, 300));
    sessions();
    print("");
    print("passed " + tostring(NPASS) + ", failed " + tostring(NFAIL));
    // the same server driven by the REAL LSP client library, and the
    // extension's own activate() against a stub of the vscode module (the one
    // check that catches a runtime dependency filed under devDependencies)
    let ext = yc.ROOT + "/src/tools/lsp/vscode-y-lang";
    if (yt.have("node") && fs.is_dir(ext + "/node_modules")) {
        foreach (argv in [["node", yc.ROOT + "/src/tools/lsp/test/client-check.js", BIN],
                          ["node", yc.ROOT + "/src/tools/lsp/test/activation-check.js", ext, BIN]]) {
            let c = yt.cmd(argv);
            c.merge = true;
            c.timeout = 300;
            let r = yt.run(c);
            puts(r.out);
            if (r.code != 0) { NFAIL += 1; };
        };
    } else {
        print("skipped: the two Node checks need 'npm install' in src/tools/lsp/vscode-y-lang");
    };
    if (NFAIL == 0) { 0 } else { 1 }
};

export { main };
