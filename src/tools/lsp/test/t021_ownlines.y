// xref.own_lines: the buffer-line -> spliced-line map, built from the origin map.
//
// It used to be a constant shift -- spliced_lines - buffer_lines added to every
// line from the first non-import line on -- which is only right when the imports
// are the file's VERY FIRST lines. A header comment before them makes "first
// non-import line" line 1, and then every line after the imports maps to the wrong
// spliced line, so expr_type answers about a line 82 too high and hover returns
// whatever expression lives there.
//
// This fixture is the shape that breaks it: a comment header, then an import, then
// a record parameter used as a member's object. src/y/asm.y is the real instance
// (16 lines of header, six imports, 1888 lines), and there hover on `it.fix`
// answered with STRING METHODS -- the type of some unrelated expression.
//
// The columns are computed from SRC by `past`, never written by hand: a
// hand-written column that lands one word early answers about a different
// identifier and the assertion passes for the wrong reason, which is the mistake
// this file exists to make impossible.

import json;
import serve from "../serve.y";
import dispatch from "../dispatch.y";
import diag from "../diag.y";
import xref from "../xref.y";

const WS = "/tmp/ylsp/t021ws";
const URI = "file:///tmp/ylsp/t021ws/main.y";
const MOD_URI = "file:///tmp/ylsp/t021ws/helper.y";

// The header is the point of the fixture, so it is asserted rather than assumed:
// three comment lines, THEN the import. One line of header already breaks the old
// shift; three makes the failure impossible to mistake for a boundary effect.
const LINES: [str] = [
    "// A header comment, the way every real file opens.",
    "//",
    "// It sits above the import, and that is the whole test.",
    "import helper from \"./helper.y\";",     // 3
    "",                                      // 4
    "type Item = { sec: long, fix: [long] };",// 5
    "",                                      // 6
    "def use(it: Item, n: long) -> long {",   // 7
    "    let fx = it.fix;",                  // 8
    "    let q = helper.add(n, 1);",          // 9
    "    fx[0] + q",                         // 10
    "};",                                    // 11
    "",                                      // 12
    "print(use({ sec: 3, fix: [4] }, 5));"   // 13
];
const SRC = join(LINES, "\n");
const MOD = [
    "def add(a: long, b: long) -> long {",
    "    a + b",
    "};",
    "export { add };"
];

def is_null(v: json.Val) -> bool {
    if let json.Null _ = v { true } else { false }
}

def m0() -> { str => json.Val } {
    let m: { str => json.Val } = {};
    m
}

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

def at(line: long, ch: long) -> json.Val {
    let td = json.obj();
    td["uri"] = json.str(URI);
    let p = json.obj();
    p["textDocument"] = json.jobj(td);
    let posn = json.obj();
    posn["line"] = json.num(line);
    posn["character"] = json.num(ch);
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

def str_at(item: json.Val, key: str) -> str {
    let got = json.as_str(serve.field_of(serve.members_of(item), key));
    let out = "<none>";
    if is_some(got) { out = got!; };
    out
}

def field(v: json.Val, k: str) -> json.Val {
    serve.field_of(serve.members_of(v), k)
}

def str_of(v: json.Val) -> str {
    let got = json.as_str(v);
    let out = "";
    if is_some(got) { out = got!; };
    out
}

// A hover is { contents: { kind, value } }, so the text is one level down -- read
// the wrong level and every assertion sees "<none>" and passes for the wrong
// reason, which is worse than no assertion.
def hover_str(v: json.Val) -> str {
    if (is_null(v)) { return "null"; };
    str_of(field(field(v, "contents"), "value")).replace("\n", "|")
}

def items_of(v: json.Val) -> [json.Val] {
    let out: [json.Val] = [];
    if let json.Arr a = v { out = a.items; };
    out
}

// The 0-based column of `needle` on 0-based `line`, or -1. Written out rather
// than hand-counted, for the reason in this file's header.
def past(line: long, needle: str) -> long {
    let lb = LINES[line];
    index_of(lb, needle)
}

// ── the map itself, from the origin map ──────────────────────────────────
//
// Checked directly as well as through the editor, because the editor's symptom is
// indirect: a wrong map shows up as a wrong TYPE, and a test that only reads types
// cannot tell a bad map from a bad type table.
fs.make_dirs(WS);
fs.write_file(WS + "/helper.y", join(MOD, "\n"));
let st = serve.server_state(WS, "", 0);
// The document is opened FIRST, before the direct xref_for below. note_open is
// what puts the buffer into the server's state; asking the state first and asking
// about the document afterwards answered null for every request, which looks
// exactly like the map being wrong.
serve.note_open(st, did_open(URI, SRC, 1));

let pr = diag.xref_for(SRC, WS, WS + "/main.y", "");
if is_some(pr) {
    let p = pr!;
    // Every buffer line that survived the splice has a spliced line, and it is a
    // DIFFERENT number from the buffer's: the import line is replaced by the
    // module's four lines, so everything below it moves down by three.
    let l8 = p.mine[9];
    print("line 9 (it.fix) -> spliced " + tostring(l8) + " (want 11: helper.y's 4 lines replace line 4's 1)");
    // The import line itself has no spliced line -- the resolver consumed it.
    print("line 4 (the import) -> spliced " + tostring(p.mine[4]) + " (want 0)");
    // And the header lines are their own spliced lines: they are above the import.
    print("line 1 (a comment) -> spliced " + tostring(p.mine[1]) + " (want 1)");
    print("line 2 (a comment) -> spliced " + tostring(p.mine[2]) + " (want 2)");
    // Index 0 is the map's own sentinel (`out[0]` is never a line), so there is one
    // entry per buffer line PLUS one. Stated rather than folded into the comparison
    // so a reader does not have to re-derive it.
    print("one entry per buffer line, plus the sentinel: "
        + tostring(len(p.mine) == xref.nlines(SRC) + 1));
} else {
    print("xref_for: NONE");
}

// ── and through the editor, which is how a user meets it ──────────────────
// `it` as the object of a Dot: the type is only knowable from the checker's index,
// which is indexed at the SPLICED line. That is the whole dependency.
let it_col = past(8, "it.fix");
let h1 = ask(st, 1, "textDocument/hover", at(8, it_col));
let h1s = hover_str(h1);
print("hover on it -> " + (if index_of(h1s, "sec: long") >= 0 && index_of(h1s, "fix: [long]") >= 0
                           && index_of(h1s, "split(") < 0 { "Item's fields" }
                           else { "WRONG: " + h1s }));
print("hover on it is not a string: " + tostring(index_of(h1s, "split(") < 0));

// `it.` completion: the record's fields, not the whole scope and not a string's
// methods. The string-methods answer is the specific wrong one worth pinning.
// +3, not +2: the cursor must be AFTER the dot, and `past` gave the column
// of `i`. Two characters on is the dot itself, which is a different request.
let c1 = ask(st, 2, "textDocument/completion", at(8, it_col + 3));
let labels: [str] = [];
// `items` is INSIDE the result object, so the array has to be fetched before
// items_of can see it. (Passing the result itself yields zero items, which reads
// as "the server offered nothing" rather than as a mistake here.)
foreach (it in items_of(field(c1, "items"))) { labels += str_at(it, "label"); };
print("it. offers " + tostring(len(labels)) + ": " + join(labels, ","));
print("it. offers exactly Item's fields: "
    + tostring(labels == ["sec", "fix"]));

// A line the shift got RIGHT would hide the bug, so the fixture also asks about a
// line whose correct spliced line is far from its own: the last one.
let last = past(13, "use({");
let h2 = ask(st, 3, "textDocument/hover", at(13, last));
print("hover on the call's `use` is a signature: "
    + tostring(index_of(hover_str(h2), "use(it: Item, n: long) -> long") >= 0));
