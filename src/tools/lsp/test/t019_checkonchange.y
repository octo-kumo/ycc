// t019_checkonchange.y -- R1.8's `y.lsp.checkOnChange`, end to end.
//
// This fixture exists because the requirement claimed a setting that was not
// there. `yserve` dropped `initialize`'s PARAMS on the floor -- `dispatch.
// lifecycle` took `(st, id, method)` and nothing else -- so there was nowhere for
// the client to put it and nothing for the server to read, and the requirement's
// text had been true of nothing for as long as it had been written. `y.lsp.
// rootPath`, the setting next to it in the README, does reach the server: it goes
// on argv as `--root`. The difference is worth a fixture, because "the README
// documents four settings" is not the same claim as "four settings work".
//
// What is pinned is the SHAPE of the promise, which is not "ignore changes":
//
//   ON  (the default)  didChange publishes diagnostics, as it always has.
//   OFF               didChange publishes NOTHING -- and the buffer is still
//                     updated, because hover, completion, semantic tokens and
//                     formatting all read it and answering about text the user has
//                     already replaced is worse than the slow check the switch
//                     exists for.
//   either            didOpen and didSave publish, so an OFF user still gets
//                     errors when it matters.
//
// And the two defaults, which have to agree or the setting is a trap:
// `serve.read_check_on_change` answers true for an absent key, a null and a
// non-bool, and the client's own default is true. An OFF client therefore has to
// have said so.

import json;
import serve from "../serve.y";
import dispatch from "../dispatch.y";

const URI = "file:///tmp/opencode/t019.y";

// A buffer with one error in it, so a publish is visible as a non-empty list and
// as the buffer changing. The `nosuchfn` call is the error; the second line is
// there so the two versions differ in more than one character, which is what a
// stale-buffer test needs.
const V1 = "let a = nosuchfn(1);\n";
const V2 = "let a = nosuchfn(2);\nprint(a);\n";

// An empty map of the right type. A bare `{}` is not `{ str => json.Val }` -- a
// map literal with nothing in it has no key type to infer from -- which is why
// the `read_check_on_change` cases below all go through here or through a map
// literal that has a key.
def m0() -> { str => json.Val } {
    let m: { str => json.Val } = {};
    m
}

// One `{ "<name>": <val> }` map. The idiom is unavoidable and worth a name: the
// thing under test is a map of `json.Val`, and `json.jobj` wants a map rather
// than a `Val`, so building the map first is not a convenience.
def m1(k: str, v: json.Val) -> { str => json.Val } {
    let m: { str => json.Val } = {};
    m[k] = v;
    m
}

def td_for(text: str, version: long) -> { str => json.Val } {
    let td = json.obj();
    td["uri"] = json.str(URI);
    td["languageId"] = json.str("y");
    td["version"] = json.num(version);
    td["text"] = json.str(text);
    td
}

def did_open(text: str, version: long) -> { str => json.Val } {
    let p = json.obj();
    p["textDocument"] = json.jobj(td_for(text, version));
    p
}

def did_change(text: str, version: long) -> { str => json.Val } {
    let p = json.obj();
    p["textDocument"] = json.jobj(td_for(text, version));
    let ch = json.obj();
    ch["text"] = json.str(text);
    let cs = json.jarr([json.jobj(ch)]);
    p["contentChanges"] = cs;
    p
}

// One `initialize` frame, delivered the way the PARENT gets it: as raw JSON on a
// line, through `dispatch.apply_state`.
//
// This is not `dispatch.lifecycle`, and getting that wrong is the bug this
// fixture was written for. `yserve` forks per request: the parent records what
// must survive in `apply_state` and the child answers from a COPY and dies
// (LSP.md section 4.2). So a flag read in the child is forgotten by the next
// keystroke -- and reading it there is what the first version did, and the
// symptom was a client that sent `false` and still got a publish on every
// change. Only the parent can remember, so only the parent is asked here.
//
// `t013_m4` pins what the capability answer looks like; this pins where the
// option is READ.
def init_with(check: json.Val) -> State {
    let opts: { str => json.Val } = {};
    opts["checkOnChange"] = check;
    let p = m1("initializationOptions", json.jobj(opts));
    let msg = json.obj();
    msg["jsonrpc"] = json.str("2.0");
    msg["id"] = json.num(1);
    msg["method"] = json.str("initialize");
    msg["params"] = json.jobj(p);
    let raw = json.stringify(msg) + "\n";
    let st = serve.server_state("/tmp/opencode", "", 0);
    dispatch.apply_state(st, raw);
    st
}

// Every `publishDiagnostics` frame in a notification's reply, as the count of
// frames and the count of DIAGNOSTICS in the first one. A frame with an empty
// list is still a frame, which is why they are counted separately: `on_did_close`
// publishes an empty list deliberately, and "nothing was published" and "an empty
// list was published" are different answers.
def published(frames: [str]) -> str {
    let out = "no frames";
    let i = 0;
    while (i < len(frames)) {
        if (where(frames[i], "publishDiagnostics") >= 0) {
            let n = count_of(frames[i], "\"message\"");
            if (out == "no frames") { out = "1 frame, " + tostring(n) + " diagnostics" }
            else { out = out + ", then " + tostring(n) };
        };
        i = i + 1;
    };
    out
}

def where(text: str, needle: str) -> long {
    let out = 0 - 1;
    let i = 0;
    while (i + len(needle) <= len(text) && out < 0) {
        if (text[i:i + len(needle)] == needle) { out = i; } else { i = i + 1; };
    };
    out
}

def count_of(text: str, needle: str) -> long {
    let out = 0;
    let i = 0;
    while (i + len(needle) <= len(text)) {
        if (text[i:i + len(needle)] == needle) { out = out + 1 };
        i = i + 1;
    };
    out
}

// What the server HOLDS for the document, which is the half of the promise the
// flag does not touch. Read through the buffer's own text rather than through a
// diagnostic, because the point is that it moved while nothing was published.
def held_text(st: State) -> str {
    let got = serve.doc_get(st, URI);
    let out = "<no document>";
    if is_some(got) {
        let d: Doc = got!;
        out = "v" + tostring(d.version) + ", " + tostring(len(d.text)) + " bytes";
    };
    out
}

print("-- the setting is READ, not ignored");
print("no options at all means on: " + tostring(serve.read_check_on_change(m0())));
print("an empty options object means on: " + tostring(serve.read_check_on_change(m1("initializationOptions", json.jobj(m0())))));
print("null means on: " + tostring(serve.read_check_on_change(m1("initializationOptions", json.jobj(m1("checkOnChange", json.nul()))))));
print("a string means on: " + tostring(serve.read_check_on_change(m1("initializationOptions", json.jobj(m1("checkOnChange", json.str("no")))))));
print("false means off: " + tostring(serve.read_check_on_change(m1("initializationOptions", json.jobj(m1("checkOnChange", json.boolean(false)))))));

// One notification, the way the server actually delivers one: the PARENT records
// the state (`serve.note_open` / `serve.note_change`) and the CHILD answers
// (`dispatch.doc_notification`). Those are two calls on purpose -- it is the
// fork-per-request split, and the parent is the only side that survives (LSP.md
// section 4.2). Calling only the second would leave no document at all and every
// line below would read "no frames" for the wrong reason, which is exactly what a
// first version of this fixture did.
def deliver_open(st: State, text: str, version: long) -> str {
    let p = did_open(text, version);
    serve.note_open(st, p);
    published(dispatch.doc_notification(st, "textDocument/didOpen", p))
}

def deliver_change(st: State, text: str, version: long) -> str {
    let p = did_change(text, version);
    serve.note_change(st, p);
    published(dispatch.doc_notification(st, "textDocument/didChange", p))
}

def deliver_save(st: State, text: str, version: long) -> str {
    // didSave carries no text: the buffer is the truth, not the file.
    let p = did_open(text, version);
    published(dispatch.doc_notification(st, "textDocument/didSave", p))
}

print("-- ON, which is the default and the old behaviour");
let on_st = init_with(json.boolean(true));
print("  the flag: " + tostring(on_st.check_on_change));
print("  didOpen: " + deliver_open(on_st, V1, 1));
print("  didChange: " + deliver_change(on_st, V2, 2));
print("  and the buffer moved: " + held_text(on_st));
print("  didSave: " + deliver_save(on_st, V2, 2));

print("-- OFF: nothing published on a change, and the buffer STILL moves");
let off_st = init_with(json.boolean(false));
print("  the flag: " + tostring(off_st.check_on_change));
print("  didOpen: " + deliver_open(off_st, V1, 1));
print("  didChange: " + deliver_change(off_st, V2, 2));
print("  and the buffer moved anyway: " + held_text(off_st));
print("  didSave, which still checks: " + deliver_save(off_st, V2, 2));

print("-- and the other features are not a keystroke behind, which is the half");
// A hover on the OFF server, at line 2, where V1 has NOTHING and V2 has `print`.
// That is the observable form of "the buffer is the truth": the change that
// published no diagnostics still moved the text every other feature reads.
//
// A semantic-tokens request would be the obvious choice here and is useless: its
// reply is a list of INDICES, so there is no text in it to look for. The hover's
// answer is `void`, because `print` is a builtin -- which also makes this double
// as a check that the type table is consulted.
let hreq: { str => json.Val } = {};
hreq["textDocument"] = json.jobj(td_for(V1, 1));
let hpos: { str => json.Val } = {};
hpos["line"] = json.num(1);
hpos["character"] = json.num(0);
hreq["position"] = json.jobj(hpos);
print("  a hover at line 2, which only V2 has: " + tostring(where(dispatch.doc_request(off_st, json.num(9), "textDocument/hover", hreq), "void") >= 0));

print("done");
