// t020_sorttext.y -- R6.3's `sortText`, on every completion item kind.
//
// R6.3 says each item carries `sortText`, `detail` and `documentation`. `detail`
// and `documentation` were there; `sortText` was set by NONE of the five item
// builders, so a requirement had been half-implemented for as long as it had been
// written. It is on all five now, through one `serve.sort_text` so a kind added
// later cannot forget it.
//
// The point of this fixture is the SHAPE, not the value: five kinds, one of which
// (`module_item`) was written after R6.3 and would have been the one to miss it,
// and one of which (`builtin_item`) deliberately has no `detail`. So the checks are
// per kind and assert the two things separately -- `sortText` present and equal to
// the label, `detail` present-or-absent per the kind's own rule -- because "every
// item carries a sortText" and "every item carries a detail" are different claims
// and only the first is true.
//
// The buffer is the smallest one that produces all five kinds: a `let`, a `def`, a
// `param`, a record field after a `.`, a string method after a `.`, a builtin, and a
// module member after an import's `.`.

import json;
import serve from "../serve.y";
import dispatch from "../dispatch.y";

// The workspace, and TWO modules, because a module member reaches its `detail` by
// one of two routes that answer differently -- which is why both are here:
//
//   `helper.` a sibling file, spliced in. There is no linked `Unit` for it, so the
//         member list is the buffer's own top level filtered by origin file, and
//         there is no type to print. Its items carry NO detail, on purpose.
//   `math.`  a std unit NAMED rather than pathed, so there is no import target to
//         match and the members are found by the file's BASENAME (`math` ->
//         `math.y`). Same no-detail answer, and for the same reason: the unit was
//         never LINKED, so its `exports` were never compiled and there is no `Sym`
//         to read a type out of.
//
// Both therefore print `<none>`, which is the reachable answer and is pinned as
// such. The other route -- a genuinely linked unit, whose `[Sym]`s DO carry types
// and become the `detail` -- is not reachable from a workspace: `std_units` links
// only the always-on units there, `str` and `rt`, and neither can be written `x.`.
// The code for that route is there and correct; what is pinned here is the
// behaviour a user actually gets.
//
// A module member is also the one item kind written after R6.3, and therefore the
// one most likely to have missed `sortText`.
const WS = "/tmp/opencode/t020ws";
const URI = "file:///tmp/opencode/t020ws/main.y";

const LINES: [str] = [
    "import helper from \"./helper.y\";",              // 0
    "import math;",                                   // 1
    "type P = { a: long, b: str };",                  // 2
    "def g(p: P, q: long) -> long {",                  // 3
    "    let local = p.a;",                           // 4
    "    let s = \"x,y\";",                           // 5
    "    let m = s.split(\",\");",                     // 6
    "    helper.thing(1);",                           // 7
    "    math.exp(1.0);",                             // 8
    "    local + q",                                  // 9
    "};",                                             // 10
    "print(m.length)"                                 // 11
];
const SRC = join(LINES, "\n");

def is_null(v: json.Val) -> bool {
    if let json.Null _ = v { true } else { false }
}

def m0() -> { str => json.Val } {
    let m: { str => json.Val } = {};
    m
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

def items_of(v: json.Val) -> [json.Val] {
    let out: [json.Val] = [];
    if let json.Arr a = v { out = a.items; };
    out
}

def str_at(item: json.Val, key: str) -> str {
    let got = json.as_str(serve.field_of(serve.members_of(item), key));
    let out = "<none>";
    if is_some(got) { out = got!; };
    out
}

def has(item: json.Val, key: str) -> bool {
    !is_null(serve.field_of(serve.members_of(item), key))
}

// Every item the server returned, as `label/sortText/detail`, one per line. The
// whole list, because "every kind carries it" is the claim and a fixture that
// prints one item per kind proves nothing about the rest.
def listing(st: State, id: long, line: long, ch: long) -> str {
    let out = "";
    let ix = items_of(serve.field_of(serve.members_of(
        ask(st, id, "textDocument/completion", at(line, ch))), "items"));
    let i = 0;
    while (i < len(ix)) {
        if (i > 0) { out = out + ", "; };
        out = out + str_at(ix[i], "label") + "/" + str_at(ix[i], "sortText") + "/" + str_at(ix[i], "detail");
        i = i + 1;
    };
    out
}

// The count of items whose sortText is missing or is not their own label, over a
// whole list. Zero is the property; the names are printed too so a failure says
// WHICH item rather than just how many.
def bad_sort_texts(st: State, id: long, line: long, ch: long) -> str {
    let out = "";
    let n = 0;
    let ix = items_of(serve.field_of(serve.members_of(
        ask(st, id, "textDocument/completion", at(line, ch))), "items"));
    let i = 0;
    while (i < len(ix)) {
        let lab = str_at(ix[i], "label");
        if (!has(ix[i], "sortText") || str_at(ix[i], "sortText") != lab) {
            n = n + 1;
            if (out != "") { out = out + ","; };
            out = out + lab;
        };
        i = i + 1;
    };
    tostring(n) + ": " + out
}

// The 0-based character column just PAST `needle` on `line`, or -1. Every
// position this file asks about is one of these: a hand-written column is how a
// fixture ends up asking about whitespace and passing for the wrong reason, which
// is the mistake t016_types documents at length.
def past(line: long, needle: str) -> long {
    let i = 0;
    let got = 0 - 1;
    while (i + len(needle) <= len(LINES[line])) {
        if (LINES[line][i:i + len(needle)] == needle) { got = i + len(needle); i = len(LINES[line]); }
        else { i = i + 1; };
    };
    got
}

print("-- the columns this file asks about, so a wrong one is visible");
print("after `p.` on line 4: " + tostring(past(4, "p.")));
print("after `s.` on line 6: " + tostring(past(6, "s.")));
print("after `helper.` on line 7: " + tostring(past(7, "helper.")));
print("after `math.` on line 8: " + tostring(past(8, "math.")));
print("a name on line 9: " + tostring(past(9, "local +")));

// The workspace is MADE here, not assumed. The buffer below imports
// `./helper.y`, and completion on `helper.` makes the resolver look for that
// file on disk; it used to exist in /tmp only because someone had created it by
// hand, so the fixture passed on the machine where it already did and failed on
// a fresh one. t021 makes its own for the same reason.
fs.make_dirs(WS);
fs.write_file(WS + "/helper.y", "def thing(n: long) -> long { n }\nlet CONST: long = 3;\n");

let st = serve.server_state(WS, "", 0);
let td = json.obj();
td["uri"] = json.str(URI);
td["languageId"] = json.str("y");
td["version"] = json.num(1);
td["text"] = json.str(SRC);
let dop = json.obj();
dop["textDocument"] = json.jobj(td);
serve.note_open(st, dop);

print("-- every item kind carries sortText, and it is the label");
print("names (let/def/param/builtin): " + bad_sort_texts(st, 1, 7, 0));
print("a record's fields: " + bad_sort_texts(st, 2, 4, past(4, "p.")));
print("the string methods: " + bad_sort_texts(st, 3, 6, past(6, "s.")));
print("a SIBLING file's members: " + bad_sort_texts(st, 4, 7, past(7, "helper.")));
print("a NAMED std unit: " + bad_sort_texts(st, 5, 8, past(8, "math.")));

print("-- and detail is per kind, which is a DIFFERENT claim");
// The builtins have no detail on purpose: Stage A does not know a builtin's
// signature, and a wrong one is worse than none. So "every item carries a detail"
// is FALSE and the fixture says so, rather than passing on a rule that does not
// hold.
print("the methods' listing: " + listing(st, 6, 6, past(6, "s.")));
print("a record field's listing: " + listing(st, 7, 4, past(4, "p.")));
print("a SIBLING file: " + listing(st, 8, 7, past(7, "helper.")));
print("a NAMED std unit: " + listing(st, 10, 8, past(8, "math.")));
print("a name's listing: " + listing(st, 9, 9, past(9, "local +")));

print("done");
