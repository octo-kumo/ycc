// t013_m4.y -- the three navigation requests, as JSON (LSP.md §6 R4/R5/R6, M4).
//
// t009_proto pins the framing and the lifecycle; this pins what the three M4
// requests ANSWER. It goes through serve.do_* with a real request object, so
// what is checked is the wire shape -- the field names, the null-vs-empty
// choice, the range that is the word rather than the declaration -- and not the
// lookup itself, which t012_scope checks directly.
//
// The capability flags are checked here too, and for the reason LSP.md keeps
// repeating: a capability is a promise the client changes its behaviour on, so
// a flag that is set but unanswerable is worse than a missing one.

import json;
import serve from "../serve.y";
import dispatch from "../dispatch.y";
import native from "../../../y/native.y";
import scope from "../scope.y";

const URI = "file:///tmp/ylsp/t013.y";

// The buffer under test. Line numbers in the comments are 0-based, as an LSP
// position is.
let LINES: [str] = [
    "// doubles a number",
    "def twice(x: long) -> long { x * 2 };",
    "",
    "let base = 21;",
    "",
    "def use() -> long {",
    "    let local = 1;",
    "    base + local",
    "};",
    "",
    "print(twice(base));"
];
const SRC = join(LINES, "\n");

def fresh() -> State { serve.server_state(".", "", 0) }

def open_buf(st: State) {
    serve.note_open(st, did_open(URI, SRC, 1));
}

// didOpen's PARAMS, as the {str => Val} map a notification handler takes --
// not a wrapped Val, which is the shape a REQUEST carries.
def did_open(uri: str, text: str, version: long) -> { str => json.Val } {
    let td = json.obj();
    td["uri"] = json.str(uri);
    td["languageId"] = json.str("y");
    td["version"] = json.num(version);
    td["text"] = json.str(text);
    let p = json.obj();
    p["textDocument"] = json.jobj(td);
    p
}

// A request's params at a position in THIS document, and the same for another
// uri (for the not-open case). Built as the {str => Val} map a handler takes,
// not as a wrapped Val.
def at_uri(uri: str, line: long, character: long) -> { str => json.Val } {
    let posn = json.obj();
    posn["line"] = json.num(line);
    posn["character"] = json.num(character);
    let td = json.obj();
    td["uri"] = json.str(uri);
    let p = json.obj();
    p["textDocument"] = json.jobj(td);
    p["position"] = json.jobj(posn);
    p
}

def at(line: long, character: long) -> json.Val { json.jobj(at_uri(URI, line, character)) }

// `initialize` goes through dispatch.lifecycle, not doc_request: it is a
// lifecycle request and is answered before any document exists.
def init_caps() -> json.Val {
    let raw = dispatch.lifecycle(fresh(), json.num(1), "initialize");
    let out = json.nul();
    if is_some(raw) {
        let got = json.parse(raw!);
        if is_some(got) { out = json.jobj(got!); };
    };
    field(field(out, "result"), "capabilities")
}

// Ask through the dispatcher, so the method NAME is part of what is tested --
// a handler wired up but not reachable is a capability the client was told
// about and cannot use.
// The RESULT of a request, not the whole reply: the envelope is
// {jsonrpc, id, result}, and everything below is reading what the request
// returned rather than the JSON-RPC wrapper around it.
def ask(st: State, id: long, method: str, p: json.Val) -> json.Val {
    let raw = dispatch.doc_request(st, json.num(id), method, serve.params_of(p));
    let got = json.parse(raw);
    let out = json.nul();
    if is_some(got) { out = json.jobj(got!); };
    field(out, "result")
}

def field(v: json.Val, k: str) -> json.Val {
    serve.field_of(serve.members_of(v), k)
}

def bfield(v: json.Val, k: str) -> bool { json.as_bool(field(v, k))! }

def at_line(v: json.Val, k: str) -> long {
    let r = field(v, k);
    let l = serve.field_of(serve.members_of(r), "line");
    let got = json.as_long(l);
    let out = 0;
    if is_some(got) { out = got!; };
    out
}

def at_char(v: json.Val, k: str) -> long {
    let r = field(v, k);
    let c = serve.field_of(serve.members_of(r), "character");
    let got = json.as_long(c);
    let out = 0;
    if is_some(got) { out = got!; };
    out
}

// The n-th string of an array field, or "" -- for triggerCharacters.
def str_at(v: json.Val, k: str, n: long) -> str {
    let out = "";
    let a = items_of(field(v, k));
    if n < len(a) {
        let got = json.as_str(a[n]);
        if is_some(got) { out = got!; };
    };
    out
}

def items_of(v: json.Val) -> [json.Val] {
    let out: [json.Val] = [];
    if let json.Arr a = v { out = a.items; };
    out
}

// A Location's start as "line:char", or "null". Printing the two numbers
// separately made a miss indistinguishable from a hit on line 0.
def loc_of(v: json.Val) -> str {
    if is_null(v) { "null" } else {
        let r = field(v, "range");
        tostring(at_line(r, "start")) + ":" + tostring(at_char(r, "start"))
    }
}

def items(v: json.Val) -> [json.Val] {
    let out: [json.Val] = [];
    if let json.Arr a = field(v, "items") { out = a.items; };
    out
}

def labels(v: json.Val) -> str {
    let out: [str] = [];
    foreach (i in items(v)) {
        let l = serve.field_of(serve.members_of(i), "label");
        let got = json.as_str(l);
        if is_some(got) { out += got!; };
    };
    ",".join(out)
}

def is_null(v: json.Val) -> bool {
    if let json.Null _ = v { true } else { false }
}

// ── the capabilities, and that each is one this file answers ──
print("-- capabilities");
let caps = init_caps();
print("definitionProvider " + tostring(bfield(caps, "definitionProvider")));
print("hoverProvider " + tostring(bfield(caps, "hoverProvider")));
let cp = field(caps, "completionProvider");
print("completionProvider is an object: " + tostring(len(serve.members_of(cp)) > 0));
print("  triggerCharacters " + str_at(cp, "triggerCharacters", 0) + " " + str_at(cp, "triggerCharacters", 1));

// ── definition ──
print("-- definition");
let st = fresh();
open_buf(st);
// `twice` used on line 10, declared on line 1.
let d1 = ask(st, 2, "textDocument/definition", at(10, 7));
print("twice at 10:7 -> " + loc_of(d1));
// `base` used on line 10, declared on line 3.
let d2 = ask(st, 3, "textDocument/definition", at(10, 13));
print("base at 10:13 -> " + loc_of(d2));
// `local` used on line 7, declared on line 6 -- and NOT the top-level `base`.
// `local` starts at column 11 on line 7; 12 is inside it.
let d3 = ask(st, 4, "textDocument/definition", at(7, 12));
print("local at 7:12 -> " + loc_of(d3));
// The uri is the document's own.
let u = json.as_str(field(d1, "uri"));
print("uri echoed: " + tostring(is_some(u) && u! == URI));
// The range covers the NAME, not the whole declaration: a jump must not land on
// the closing brace of a long def.
print("range end char " + tostring(at_char(field(d1, "range"), "end")) + " (name is 5 long, starts at 4)");

print("-- definition with nothing to point at");
print("on `print` (a builtin, not a declaration here): " + tostring(is_null(ask(st, 5, "textDocument/definition", at(10, 2)))));
print("on whitespace: " + tostring(is_null(ask(st, 6, "textDocument/definition", at(2, 0)))));
print("on a line past the end: " + tostring(is_null(ask(st, 7, "textDocument/definition", at(999, 0)))));
// A different uri: the server must not answer about a document nobody opened,
// and must NOT go and read that path off disk (R1.1).
let d4 = ask(st, 8, "textDocument/definition",
             json.jobj(at_uri("file:///tmp/ylsp/not-open.y", 1, 5)));
print("a document that is not open: " + tostring(is_null(d4)));

// ── hover ──
print("-- hover");
let h1 = ask(st, 9, "textDocument/hover", at(10, 7));
let c1 = field(field(h1, "contents"), "value");
print("kind " + json.as_str(field(field(h1, "contents"), "kind"))!);
print("value " + json.as_str(c1)!);
// The range is the WORD under the mouse, not the declaration it resolves to.
print("range start line " + tostring(at_line(field(h1, "range"), "start")) + " char " + tostring(at_char(field(h1, "range"), "start")));
print("range end char " + tostring(at_char(field(h1, "range"), "end")));
// The signature carries the RETURN TYPE, not just the parameters. It did not,
// for a whole spell of the server's life: the span range that collects the type
// was tested one token too far, so `def f() -> long {` -- a single-word return
// type, which is most defs -- showed `f()` and read as though Y had no return
// types. Pinned here because the bug looks like a missing feature.
print("return type present: " + tostring(index_of(json.as_str(c1)!, ") -> long") > 0));

// A `let` with no annotation has no signature to show, so the hover shows the
// name -- and, since the checker's type index (LSP.md 9.2 A2), the type the
// checker INFERRED for the binding above it.
//
// The comment this replaces said the hover "says just the name rather than
// inventing a type", and the not-inventing half is still the point and still the
// test: `long` here is `types.expr_type` read out of the compiler's own table, not
// anything this server worked out. It was absent because the server had no types at
// all, which was a missing capability rather than a piece of honesty. The
// declaration is still shown underneath, so a reader can tell the two apart.
let h2 = ask(st, 10, "textDocument/hover", at(10, 13));
print("base, no annotation: " + json.as_str(field(field(h2, "contents"), "value"))!);
print("hover on nothing: " + tostring(is_null(ask(st, 11, "textDocument/hover", at(2, 0)))));

// ── completion ──
print("-- completion");
let c3 = ask(st, 12, "textDocument/completion", at(9, 0));
print("isIncomplete " + tostring(bfield(c3, "isIncomplete")));
print("every label: " + labels(c3));
// A prefix filters. `tw` must offer `twice` and nothing else from the
// declarations.
let c4 = ask(st, 13, "textDocument/completion", at(1, 6));
print("prefix `tw`: " + labels(c4));
// Inside `use`'s body the local is offered. Line 7, col 4: line 8 is the
// closing `}`, and asking there must NOT offer `local` -- the scope has closed.
let c5 = ask(st, 14, "textDocument/completion", at(7, 4));
print("inside use(): " + labels(c5));
let c7 = ask(st, 18, "textDocument/completion", at(8, 1));
print("at use()'s closing brace: " + labels(c7));
let c6 = ask(st, 15, "textDocument/completion", at(10, 0));
print("at top level: " + labels(c6));

print("-- completion items carry the declaration's own detail");
let found = 0;
foreach (i in items(c5)) {
    let l = json.as_str(serve.field_of(serve.members_of(i), "label"));
    if is_some(l) {
        if (l! == "twice") {
            let d = json.as_str(serve.field_of(serve.members_of(i), "detail"));
            print("  twice detail: " + d!);
            print("  twice detail has the return type too: " + tostring(index_of(d!, ") -> long") > 0));
            print("  twice documentation: " + json.as_str(serve.field_of(serve.members_of(field(i, "documentation")), "value"))!);
            // textEdit inserts the NAME only: Y has no argument completion, and
            // inserting a signature would put a `(` where none was asked for.
            print("  twice textEdit: " + json.as_str(serve.field_of(serve.members_of(field(i, "textEdit")), "newText"))!);
            found = found + 1;
        };
    };
};
print("  found: " + tostring(found));

print("-- the builtins come from the compiler's own list");
// Every offered builtin must be one native.is_intrinsic_name accepts, and every
// typable one must be offered. The list is read from the compiler rather than
// kept here, so this cannot drift by construction -- the assertion is that the
// filter did not drop something typable.
let bnames = intrinsic_names();
let bad = 0;
let typable = 0;
foreach (b in bnames) {
    if index_of(b, "$") < 0 && b[:1] != "#" {
        typable = typable + 1;
        let offered = false;
        foreach (l in labels(c3).split(",")) {
            if (l == b) { offered = true; };
        };
        if (!offered) { bad = bad + 1; print("  MISSING " + b); };
    };
};
print("typable builtins " + tostring(typable) + ", missing from the list " + tostring(bad));
// And the ones that cannot be typed are NOT offered.
print("no `opt$test` in the list: " + tostring(index_of(labels(c3), "opt$test") < 0));
print("no `#fmt` in the list: " + tostring(index_of(labels(c3), "#fmt") < 0));

print("-- and the PREDICATE agrees with the list");
// The check above walks the list. This walks the other way, against the
// predicate the objective names, because the two are separate exports and only
// share a definition TODAY: is_intrinsic_name is `name_in(INTRINSICS, n)` and
// intrinsic_names is the bare INTRINSICS. If that ever stops being true -- a
// second list, a copy made for speed, a hashed INTRINSICS whose equality differs
// from name_in's -- the server would be completing from one set of names while
// the compiler answered for another, and the failure would be a builtin that
// silently does not type.
let agree = 0;
let disagree = 0;
foreach (b in bnames) {
    if (is_intrinsic_name(b)) { agree = agree + 1; } else {
        disagree = disagree + 1;
        print("  IN LIST BUT NOT A PREDICATE: " + b);
    };
};
print("names " + tostring(len(bnames)) + ", accepted by is_intrinsic_name " +
      tostring(agree) + ", disagreed " + tostring(disagree));
// And the predicate must be a predicate: names no program can bind must be
// rejected, or `x` would shadow a builtin in the checker's eyes and not in the
// server's.
// `split` is deliberately NOT in this list, and that it is absent is the point:
// it is both a builtin (`split(s, sep)` -- the method form is builtin-backed,
// types.y's str_method) and a string method, so it is legitimately accepted here
// AND offered after a dot. An earlier version of this line listed it as a
// must-be-rejected name and the test correctly failed on it.
let not_builtins = 0;
foreach (n in ["", "printt", "not_a_builtin", "Printf", "len2", "PRINT"]) {
    if (is_intrinsic_name(n)) { not_builtins = not_builtins + 1; print("  WRONGLY ACCEPTED " + n); };
};
print("non-builtins wrongly accepted: " + tostring(not_builtins));

print("-- the index the requests agree on");
// definition, hover and completion are three views of ONE lookup. If they
// disagreed, an editor would show a jump to a place the completion list did not
// describe. Checked by asking all three about the same name.
let dd = ask(st, 16, "textDocument/definition", at(10, 7));
let hh = ask(st, 17, "textDocument/hover", at(10, 7));
let hv = json.as_str(field(field(hh, "contents"), "value"));
let hover_text_ok = false;
if is_some(hv) { hover_text_ok = hv!.starts_with("```y\ntwice(x: long)"); };
print("definition and hover agree: " + tostring(loc_of(dd) == "1:4" && hover_text_ok));
print("done");
