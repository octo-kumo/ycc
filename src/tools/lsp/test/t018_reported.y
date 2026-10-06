// t018_reported.y -- the defects a user reported, each pinned where it belongs.
//
// Every fixture before this one pinned a FEATURE. This one pins six things that
// did not work, each of which had the same shape: the server answered, and the
// answer was wrong or missing, and nothing said so. Two rules run through all six.
//
//   A wrong type is worse than none. The user cannot tell it from a real one, so
//   every answer below is the checker's own -- read out of `types.expr_type` or
//   from `scope`'s declaration kinds -- and where the checker has nothing the
//   server says nothing. That is why the block at the end pins NON-answers as
//   firmly as the rest.
//
//   A position is not a type. Most of these were one bug in different clothes:
//   something was recorded at one column of a line and asked about at another. A
//   `Decl` sits at its KEYWORD, a parameter is a bare string in `Func.params` with
//   no node at all, and a call's callee is matched by name and never visited -- so
//   `let b`, `def g(p: P)` and `clock_us()` each had no entry where a reader puts
//   the cursor, while the same name one line away answered perfectly. The compiler
//   fixes are `Decl.nline`/`ncol` (§9.2 A5), `Func.ppos`, and the two notes in
//   `typeof_call`. The server change is none, which is the point of reading the
//   table the compiler wrote rather than building a second one.
//
// The buffer is the user's own `best`/`show` code, unedited except for the two
// bare `math.` and `z.` lines at the end. Those are not incidental: they are what
// the file looked like while the completion request was made, and neither parses.
// That is the case `serve.type_of_object`'s fall-back to the DECLARATION exists
// for -- without it a half-typed line answers nothing at all, and the string
// methods are offered for whatever happened to be before the dot.

import fs;
import json;
import sem from "../sem.y";
import pos from "../pos.y";
import scan from "../scan.y";
import serve from "../serve.y";
import dispatch from "../dispatch.y";

const URI = "file:///tmp/opencode/t018.y";
const GRAMMAR = "src/tools/lsp/vscode-y-lang/syntaxes/y.tmLanguage.json";

const LINES: [str] = [
    "import math;",                                                      // 0
    "type P = { a: long, b: str };",                                     // 1
    "def best(f: () -> long) -> long {",                                 // 2
    "    let b = 1000000000;",                                            // 3
    "    let r = 0;",                                                     // 4
    "    while (r < 10) {",                                               // 5
    "        let t = clock_us();",                                        // 6
    "        f();",                                                       // 7
    "        let d = clock_us() - t;",                                    // 8
    "        if (d < b) { b = d; };",                                     // 9
    "        r = r + 1;",                                                 // 10
    "    };",                                                             // 11
    "    b",                                                              // 12
    "};",                                                                 // 13
    "def show(name: str, us: float, n: long) {",                          // 14
    "    print(f\"{name:<14}: {us * 1000.0 / (n * 1.0):7.2f} ns/call\");", // 15
    "    let ln = len(name);",                                            // 16
    "};",                                                                 // 17
    "// a comment with [brackets] and (parens) inside",                    // 18
    "let not_a_comment = \"// still a string\";",                         // 19
    "let tl = \"a,b\".split(\",\");",                                     // 20
    "def g(p: P) -> long {",                                              // 21
    "    let a = { a: 2 };",                                              // 22
    "    let e = math.exp(0.0);",                                         // 23
    "    a.a;",                                                           // 24
    "    p.a;",                                                           // 25
    "};",                                                                 // 26
    "let long = 1;",                                                      // 27
    "let z = { z: 1 };",                                                  // 28
    "math.",                                                              // 29
    "z."                                                                   // 30
];
const SRC = join(LINES, "\n");

def is_null(v: json.Val) -> bool {
    if let json.Null _ = v { true } else { false }
}

// The 0-based character column of the `at`-th occurrence of `needle` in
// `LINES[line]`, or -1 if it is not there. See t016_types for why no column in a
// fixture is written out by hand.
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

// Where `needle` first appears in `text`, or -1. The grammar check below needs it
// and the std has `index_of` under other names (`pos.index_of_char`, and a
// `str.index_of` string method), so it is five lines here rather than a guess at
// which one is meant.
def where(text: str, needle: str) -> long {
    let out = 0 - 1;
    let i = 0;
    while (i + len(needle) <= len(text) && out < 0) {
        if (text[i:i + len(needle)] == needle) { out = i; } else { i = i + 1; };
    };
    out
}

def fresh() -> State { serve.server_state("/tmp/opencode", "", 0) }

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

// With its fences and blank lines collapsed, so one line of expectation reads as
// one line of output. `""` is what a hover answers when it has no range.
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

// The string methods, by the compiler's own table. Used as a NEGATIVE: a
// completion list that contains one of these when the receiver is a module or a
// record is wrong, and listing them here is how that shows without hard-coding 26
// names in the fixture.
const METHODS = ["split", "join", "trim", "starts_with", "byte_at", "pad_left"];

// Which of the string methods appear in a completion list, comma-joined, or
// "none". Named rather than reduced to a bool, so a failure says WHICH one leaked
// instead of leaving the reader to re-run it and find out.
//
// A WHOLE-LABEL match, not a substring: `index_of` is one of the string methods,
// so a substring test would report `math.int_trap` as containing one.
def string_methods_in(csv: str) -> str {
    let parts = split_commas(csv);
    let out = "";
    let i = 0;
    while (i < len(METHODS)) {
        let j = 0;
        while (j < len(parts)) {
            if (parts[j] == METHODS[i]) {
                if (out != "") { out = out + ","; };
                out = out + METHODS[i];
            };
            j = j + 1;
        };
        i = i + 1;
    };
    if (out == "") { "none" } else { out }
}

// "160 items: min,max,abs,clamp,..." -- a count, then the first few. See the note
// where it is used for why a fixture must not spell a std unit out in full.
def count_first(csv: str) -> str {
    let parts = split_commas(csv);
    let head = "";
    let i = 0;
    while (i < len(parts) && i < 6) {
        if (i > 0) { head = head + ","; };
        head = head + parts[i];
        i = i + 1;
    };
    tostring(len(parts)) + " items: " + head
}

def split_commas(csv: str) -> [str] {
    let out: [str] = [];
    let cur = "";
    let i = 0;
    while (i < len(csv)) {
        if (csv[i:i + 1] == ",") {
            out += cur;
            cur = "";
        } else { cur = cur + csv[i:i + 1]; };
        i = i + 1;
    };
    out += cur;
    out
}

let st = fresh();
serve.note_open(st, did_open());

let legend = sem.token_types();
let toks = sem.tokens_in(pos.doc_of(SRC), serve.semantic_overrides(SRC, ""));

// The legend's NAME, never its number: a number would let a reordering pass
// unnoticed, which is what t010_sem is for.
def class_at(line: long, ch: long) -> str {
    let out = "none";
    let i = 0;
    while (i < len(toks)) {
        let t = toks[i];
        if (t.line == line && ch >= t.ch && ch < t.ch + t.len) {
            if (t.typ >= 0 && t.typ < len(legend)) { out = legend[t.typ]; } else { out = "type" + tostring(t.typ); };
        };
        i = i + 1;
    };
    out
}

// How many tokens carry a class that is not in the legend. Zero is the point:
// an index the client cannot resolve paints nothing at all, and it looks like the
// server not answering rather than like a numbering that moved.
def outside_legend() -> long {
    let out = 0;
    let i = 0;
    while (i < len(toks)) {
        if (toks[i].typ < 0 || toks[i].typ >= len(legend)) { out = out + 1; };
        i = i + 1;
    };
    out
}

def cls(line: long, needle: str, at: long) -> str {
    let c = col_of(line, needle, at);
    if (c < 0) { "NO-SUCH-COLUMN" } else { class_at(line, c) }
}

let spans = scan.scan_full(SRC).spans;

// How many scanner spans and how many semantic tokens line `line` carries. The two
// differ exactly when a span was sub-tokenized, which is the only reason to ask:
// "the whole f-string is one string token" was the report.
def counts(line: long) -> str {
    let ns = 0;
    let i = 0;
    while (i < len(spans)) {
        if (spans[i].line == line + 1) { ns = ns + 1; };
        i = i + 1;
    };
    let nt = 0;
    let j = 0;
    while (j < len(toks)) {
        if (toks[j].line == line) { nt = nt + 1; };
        j = j + 1;
    };
    tostring(ns) + " spans, " + tostring(nt) + " tokens"
}

print("-- 1. a DECLARATION's own name answers, not only a use of it");
print("b, at `let b`: " + hover1(st, 1, 3, col_of(3, "b =", 0)));
print("b, at its use on line 12: " + hover1(st, 2, 12, col_of(12, "b", 0)));
print("r, at `let r`: " + hover1(st, 3, 4, col_of(4, "r =", 0)));
print("t, at `let t`: " + hover1(st, 4, 6, col_of(6, "t =", 0)));
print("d, at `let d`: " + hover1(st, 5, 8, col_of(8, "d =", 0)));
// A PARAMETER is the same gap with nothing behind it: `Func.params` is a list of
// bare strings, so a parameter has no node, no line and no column, and nothing
// could ever be recorded at its name. `Func.ppos` is what fixes it -- one packed
// position per name, parallel to `params`.
print("p, at its own parameter declaration: " + hover1(st, 6, 21, col_of(21, "p:", 0)));
print("p, at its use: " + hover1(st, 7, 25, col_of(25, "p.", 0)));
print("name, a parameter of show: " + hover1(st, 8, 14, col_of(14, "name:", 0)));
print("f, a parameter typed as a FUNCTION: " + hover1(st, 9, 2, col_of(2, "f:", 0)));

print("-- 2. a BUILTIN answers");
// `clock_us` is matched BY NAME inside `typeof_call`, so its callee identifier is
// never an expression and `typeof_expr` never visits it -- there was nothing to
// show at all. What is shown is the call's own return type, which is the whole of
// what the checker knows about an intrinsic: it has no signature object, so
// `()` -> long would be the manual's invention rather than the compiler's answer.
print("clock_us: " + hover1(st, 10, 6, col_of(6, "clock_us()", 0)));
print("clock_us, in the subtraction: " + hover1(st, 11, 8, col_of(8, "clock_us()", 0)));
print("len: " + hover1(st, 12, 16, col_of(16, "len(", 0)));
print("print: " + hover1(st, 13, 15, col_of(15, "print(", 0)));
print("clock_us, painted as a builtin: " + cls(6, "clock_us()", 0));
print("len, painted as a builtin: " + cls(16, "len(", 0));

print("-- 3. an f-string is sub-tokenized, not one blob");
// `scan` emits an f-string as ONE span, so before this the whole of
// `f"{name:<14}: ..."` was a single `string` token and every name inside it was
// part of one blob -- worse than not highlighting the interpolation at all,
// because the interpolation is the part a reader is looking at. The interior is
// now scanned as CODE by the same scanner over the same text, which is why the
// classes below are the same ones the same code gets outside a string.
print("line 15: " + counts(15));
print("name inside the interpolation: " + cls(15, "name:<", 0));
print("its format spec `:`, `<`: " + cls(15, ":<", 0) + "/" + cls(15, ":<", 1));
print("its width `14`: " + cls(15, "14", 0));
print("us, the second interpolation: " + cls(15, "us *", 0));
print("the literal ` ns/call` stays a string: " + cls(15, " ns/call", 0));
print("the opening f\": " + cls(15, "f\"", 0));
print("a brace: " + cls(15, "{name", 0) + "/" + cls(15, "name:<14}", 11));
print("print, outside the string: " + cls(15, "print(", 0));
// A plain string is still ONE token: the sub-tokenization is for interpolations
// only, and a multi-line f-string is one token per line the same way a plain one
// is (t010_sem pins the rule).
print("line 20, a plain string: " + counts(20));
print("line 18, a comment: " + counts(18));

print("-- 4. the language's TYPE NAMES are painted as types");
// These are not declarations and were painted as ordinary variables, so every type
// in the language looked like a name. The list is `parser.type_word_names()` --
// the one the parser parses with. A mirrored copy here would drift the first time
// a primitive is added, which is the argument `native.intrinsic_names()` makes for
// the builtins above.
print("long, a return type: " + cls(2, "long {", 0));
print("str, a parameter type: " + cls(14, "str,", 0));
print("float, a parameter type: " + cls(14, "float,", 0));
print("P, an alias: " + cls(1, "P =", 0));
// The rule has two halves and only one is obvious: a user name that HAPPENS to be
// a type name is a variable. Pinned because the other direction is wrong too.
print("a `long` that is a variable: " + cls(27, "long =", 0));
// A record TYPE's field name is not a binding and not a property: it is the only
// name in the language that is both, and it stays plain.
print("a field of a record type: " + cls(1, "a: long", 0));

print("-- 5. a comment is ONE token, so nothing inside it is highlighted");
print("the comment's span: " + cls(18, "//", 0));
print("a bracket inside it: " + cls(18, "[", 0));
print("its closing bracket agrees: " + cls(18, "]", 0));
print("a paren inside it agrees too: " + cls(18, "(", 0) + "/" + cls(18, ")", 0));
// The grammar half, which is the part that WAS wrong. TextMate takes the match
// that starts EARLIEST, so the order of the top-level `patterns` is the semantics
// rather than a preference: with `#comments` first, the `//` inside the string
// literal on line 19 starts before the string's own quote and wins, and half a
// string is painted as a comment. Asserted on the file's text because the property
// is the ORDER, and the order is two numbers -- reparsing the JSON would only make
// the same comparison harder to read.
let gtext = fs.read_file(GRAMMAR);
if (is_some(gtext)) {
    let gi = where(gtext!, "\"#strings\"");
    let gc = where(gtext!, "\"#comments\"");
    print("#strings comes before #comments: " + tostring(gi >= 0 && gc >= 0 && gi < gc));
    print("at " + tostring(gi) + " and " + tostring(gc));
} else {
    print("grammar not readable at " + GRAMMAR + " -- run from the repo root");
};
print("the `//` in line 19's string scans as a string: " + cls(19, "\"// still", 0));

print("-- 6. an IMPORTED name answers");
// `diag.xref_for`, the path that builds the type index, linked NO std units: it
// passed `externs_none()` while `diag.diagnose` had always passed the real
// `externs_for(std_units(nr.std, pack))`. So every std name was undefined, every
// expression using one came back `tunk`, and the editor had nothing to show. The
// constant `math.pi` still answered -- a constant needs no extern -- which is why
// this read as "imports are not typed" rather than as a checker never asked.
print("exp of math.exp, at the call: " + hover1(st, 14, 23, col_of(23, ".exp", 0) + 1));
print("e, bound from an import: " + hover1(st, 15, 23, col_of(23, "e =", 0)));
print("math itself: " + hover1(st, 16, 23, col_of(23, "math.exp", 0)));
print("the import statement's own name: " + hover1(st, 17, 0, col_of(0, "math;", 0)));

print("-- 7. completion after a `.` is the object's OWN members");
// `math.` used to offer `byte_at, bytes, center` -- the string methods -- because
// the string-method fallback fired whenever the record branch produced nothing,
// and a module is not a record. Two distinct fixes, both pinned here: a module
// offers its own members, and a record LITERAL offers its fields.
//
// The two long lists are given as a COUNT and their first few names rather than in
// full. A fixture that spells out all 160 of `std/math.y`'s exports fails the day
// that file gains a function, and the failure says nothing about the thing being
// pinned. What is pinned is the property: the receiver's own members, in the
// receiver's own spelling, with the string methods absent.
print("math. offers " + count_first(labels(st, 20, 29, col_of(29, "math.", 0) + 5)));
print("  string methods wrongly among them: " + string_methods_in(labels(st, 26, 29, col_of(29, "math.", 0) + 5)));
print("z. (a record literal) offers: " + labels(st, 21, 30, col_of(30, "z.", 0) + 2));
print("a. (a record variable) offers: " + labels(st, 22, 24, col_of(24, "a.a;", 0) + 2));
print("p. (a parameter) offers: " + labels(st, 23, 25, col_of(25, "p.a;", 0) + 2));
print("and a str offers " + count_first(labels(st, 24, 20, col_of(20, ".split", 0) + 1)) + ", all of them its own");

print("-- and the NON-answers, which are the other half of the rule");
// No type at all is better than a plausible one, so these are pinned as firmly as
// the answers: positions where the checker has nothing, and the server must not
// invent something for them.
print("hovering inside a string literal: \"" + hover1(st, 30, 19, col_of(19, "still a string", 0)) + "\"");
print("hovering a line that is not there: " + tostring(is_null(ask(st, 31, "textDocument/hover", at(999, 0)))));
print("hovering an import's own name: \"" + hover1(st, 32, 0, col_of(0, "import math;", 0)) + "\"");
print("tokens outside the legend: " + tostring(outside_legend()) + " of " + tostring(len(toks)));

print("done");
