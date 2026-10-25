// t016_types.y -- the checker's TYPES in the server (LSP.md §6 R4.1, R6.1; §9.2
// A1, A2, A5).
//
// t013_m4 pins the hover's SHAPE and t015_xref pins cross-file navigation. This
// pins WHAT the hover says now: the type the checker computed, read out of the
// compiler's own table (types.expr_type) rather than derived here. The server
// never infers a type, so every line below with no type is a case where it must
// say nothing, and those are the lines worth having.
//
// Every column is FOUND in the line's text. A first version of the sibling
// fixtures wrote them by hand and was wrong on most, which made each
// "not a string method" / "no type here" assertion pass for the wrong reason --
// the request was landing on whitespace. `col_of` cannot be wrong that way, and a
// column the buffer does not have is a visible failure rather than a silent pass.

import json;
import serve from "../serve.y";
import dispatch from "../dispatch.y";

const URI = "file:///tmp/ylsp/t016.y";

const LINES: [str] = [
    "type P = { a: long, b: str };",          // 0
    "",                                          // 1
    "def mk(a: long, b: str) -> P {",           // 2
    "    { a: a, b: b }",                       // 3
    "};",                                        // 4
    "",                                          // 5
    "let p: P = mk(1, \"x\");",                 // 6
    "let n: long = p.a + 1;",                  // 7
    "let s: str = p.b;",                       // 8
    "let t = 1 + 2;",                          // 9
    "let u = p;",                              // 10
    "let g = \"a,b\".split(\",\");",            // 11
    "print(n);",                               // 12
    "let m = g.length;"                        // 13  an ARRAY's member, which is not a field
];
const SRC = join(LINES, "\n");

def is_null(v: json.Val) -> bool {
    if let json.Null _ = v { true } else { false }
}

// The 0-based character column of the `at`-th occurrence of `needle` in
// `LINES[line]`, or -1 if it is not there.
def col_of(line: long, needle: str, at: long) -> long {
    let text = LINES[line];
    let i = 0;
    let seen = 0;
    let got = 0 - 1;
    let start = 0;
    while (i + len(needle) <= len(text)) {
        if (i >= start && text[i:i + len(needle)] == needle) {
            if (seen == at) { got = i; i = len(text); }
            else { seen = seen + 1; start = i + 1; i = i + 1; }
        } else { i = i + 1; }
    };
    got
}

def fresh() -> State { serve.server_state("/tmp/ylsp", "", 0) }

def did_open() -> { str => json.Val } {
    let td = json.obj();
    td["uri"] = json.str(URI);
    td["languageId"] = json.str("y");
    td["version"] = json.num(1);
    td["text"] = json.str(SRC);
    let p = json.obj();
    p["textDocument"] = json.jobj(td);
    p
}

def at(line: long, ch: long) -> json.Val {
    let posn = json.obj();
    posn["line"] = json.num(line);
    posn["character"] = json.num(ch);
    let td = json.obj();
    td["uri"] = json.str(URI);
    let p = json.obj();
    p["textDocument"] = json.jobj(td);
    p["position"] = json.jobj(posn);
    json.jobj(p)
}

def ask(st: State, id: long, method: str, p: json.Val) -> json.Val {
    let raw = dispatch.doc_request(st, json.num(id), method, serve.params_of(p));
    let got = json.parse(raw);
    let out = json.nul();
    if is_some(got) { out = json.jobj(got!); };
    serve.field_of(serve.members_of(out), "result")
}

def hover_value(v: json.Val) -> str {
    let out = "";
    if !is_null(v) {
        let got = json.as_str(serve.field_of(serve.members_of(
            serve.field_of(serve.members_of(v), "contents")), "value"));
        if is_some(got) { out = got!; };
    };
    out
}

// The hover with its fences and blank lines collapsed, so a line of expectation
// reads as one line of output.
def hover1(st: State, id: long, line: long, col: long) -> str {
    hover_value(ask(st, id, "textDocument/hover", at(line, col))).replace("\n", "|")
}

def items_of(v: json.Val) -> [json.Val] {
    let out: [json.Val] = [];
    if let json.Arr a = v { out = a.items; };
    out
}

def label_of(item: json.Val) -> str {
    let out = "";
    let got = json.as_str(serve.field_of(serve.members_of(item), "label"));
    if is_some(got) { out = got!; };
    out
}

def detail_of(item: json.Val) -> str {
    let out = "";
    let got = json.as_str(serve.field_of(serve.members_of(item), "detail"));
    if is_some(got) { out = got!; };
    out
}

// The completion labels, comma-joined, in the order the server returned them.
//
// The RESULT is an object with an `items` array and an `isIncomplete` flag, not a
// bare array, so `items_of(field(v, "items"))` is the whole of it -- the same two
// steps t014_strm takes.
def labels(st: State, id: long, line: long, col: long) -> str {
    let out = "";
    let ix = items_of(serve.field_of(serve.members_of(
        ask(st, id, "textDocument/completion", at(line, col))), "items"));
    let i = 0;
    while (i < len(ix)) {
        if (i > 0) { out = out + ","; };
        out = out + label_of(ix[i]);
        i = i + 1;
    };
    out
}

let st = fresh();
serve.note_open(st, did_open());

print("-- the columns this file asks about, so a wrong one is visible");
print("p on line 10: " + tostring(col_of(10, "p", 0)));
print("p.a on line 7: " + tostring(col_of(7, "p.a", 0)) + ", the `a`: " + tostring(col_of(7, ".a", 0) + 1));
print("p.b on line 8: " + tostring(col_of(8, "p.b", 0)) + ", the `b`: " + tostring(col_of(8, ".b", 0) + 1));
print("1 on line 9: " + tostring(col_of(9, "1 + 2", 0)));
print("after p. on line 7: " + tostring(col_of(7, ".a", 0) + 2));
print("split on line 11: " + tostring(col_of(11, "split", 0)));
print("a needle the buffer does not have: " + tostring(col_of(12, "zzz", 0)));

// READ and BOUND are the SAME name at two positions, and both answer. That is the
// point of the pair: a `Decl` node sits at the KEYWORD, so the name's own position
// (`Decl.nline`/`ncol`, §9.2 A5) is a second place the type has to be recorded, and
// a server that records only the node's own line gives the same name two different
// answers depending on where the cursor is -- `long` at the use and nothing at all
// at the declaration, which is what this used to do.
print("-- a hover shows the type the checker inferred");
print("p, where it is READ: " + hover1(st, 1, 10, col_of(10, "p", 0)));
print("p, where it is BOUND: " + hover1(st, 2, 6, col_of(6, "p", 0)));
// `mk` is a FUNCTION, and its declaration already IS its signature, so the hover
// shows the signature once and not the type above it. Recording the call's RETURN
// type at the callee's position instead made this read
// `{ a: long, b: str }`, which is the record `mk(1, "x")` produces -- an answer that
// is not wrong about anything and wrong about what `mk` is.
print("mk: " + hover1(st, 3, 6, col_of(6, "mk", 0)));

print("-- an expression that is not a name still has a type");
print("the 1 of 1 + 2: " + hover1(st, 4, 9, col_of(9, "1 + 2", 0)));

print("-- a record's own fields, which are types and are NOT bindings");
print("the `a` of p.a: " + hover1(st, 5, 7, col_of(7, ".a", 0) + 1));
print("the `b` of p.b: " + hover1(st, 6, 8, col_of(8, ".b", 0) + 1));

print("-- what a hover answers with no range, because there is no word");
print("a bare string literal: " + hover1(st, 7, 11, col_of(11, "\"a,b\"", 0)));

print("-- and what it refuses");
print("whitespace: " + tostring(is_null(ask(st, 8, "textDocument/hover", at(1, 0)))));
print("past the end: " + tostring(is_null(ask(st, 9, "textDocument/hover", at(999, 0)))));

print("-- completion after a `.` is the object's OWN members");
// There is no case here for a record's fields UNFILTERED, and that is not an
// oversight: a member access has to be followed by a name for the line to
// typecheck, so a buffer that has one always has a prefix, and the prefix filters
// the list. The unfiltered record list is therefore unreachable, which is worth
// saying here because its absence would otherwise look like a bug. (An UNTERMINATED
// `p.` does not typecheck either, so it does not get there: no Dot node, no
// type, and the Stage A string-method fallback -- which t014_strm pins at 26.)
print("p. with `a` typed offers: " + labels(st, 20, 7, col_of(7, ".a", 0) + 2));
print("p. with `b` typed offers: " + labels(st, 21, 8, col_of(8, ".b", 0) + 2));
print("a str offers the methods: " + labels(st, 22, 11, col_of(11, "split", 0)));
// `g` is a `[str]`, and an array's member is not a field of a record: the answer
// is NOTHING, and specifically not the 26 string methods. This is the line that
// keeps the fallback honest -- a wrong entry in a completion list reads as a fact
// about the language.
print("an array offers not the string methods: " + labels(st, 23, 13, col_of(13, ".length", 0) + 7));
print("the string methods would have been: " + labels(st, 24, 11, col_of(11, "split", 0)));

print("done");
