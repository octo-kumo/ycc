// Semantic tokens for a RANGE, and the reason the server advertises `range`.
//
// The whole-document answer is not merely larger than it needs to be. Measured on
// this repository's own sources:
//
//   src/y/types.y   4,597 lines   40,410 tokens   413,537 bytes of JSON
//   src/y/asm.y     1,888 lines   16,574 tokens   168,490 bytes of JSON
//
// A 51-line viewport is 382 tokens and 3,861 bytes -- 99.1% less. And the server
// produces a whole-file answer in about 3ms, which is exactly why this looked like
// nothing was happening: the cost was never in computing it, it was in the client
// decoding and re-rendering everything it had just been sent. So the fix is to send
// less, and `range` is the standard feature for that.
//
// What this fixture pins, in order of how badly it would hurt if it broke:
//
//   1. the overlapping tokens are IDENTICAL to the whole-document answer. A range
//      that returned subtly different classes would paint a file two colours
//      depending on scroll position, which is the kind of bug nobody reports and
//      everybody sees.
//   2. nothing comes back outside the range. A server that answered with the whole
//      file would be correct and useless -- and would look fine on the metrics
//      above while shipping 400KB to draw 50 lines.
//   3. the capability is advertised, or nothing here is ever exercised.
//   4. a request with NO range still gets the whole document, because that is what
//      every client sent before `range` existed and both paths have to work.

import dispatch from "../dispatch.y";
import serve from "../serve.y";
import sem from "../sem.y";
import json;


const URI = "file:///tmp/opencode/t022.y";

const LINES: [str] = [
    "// A header, because that is the shape that has bitten before.",
    "",
    "type Item = { sec: long, fix: [long] };",
    "",
    "def use(it: Item, n: long) -> long {",
    "    let fx = it.fix;",
    "    fx[0] + n",
    "};",
    "",
    "print(use({ sec: 3, fix: [4] }, 5));",
    "// a comment with brackets ( ) [ ] and a \"string\"",
    "let s: str = \"a (b) [c]\";",
    "def after() -> long {",
    "    let q = 1;",
    "    q + s.length",
    "};"
];
const SRC = join(LINES, "\n");
const NL = len(LINES);

def is_null(v: json.Val) -> bool {
    if let json.Null _ = v { true } else { false }
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

def rng(from_line: long, to_line: long) -> json.Val {
    let td = json.obj();
    td["uri"] = json.str(URI);
    let a = json.obj();
    a["line"] = json.num(from_line);
    a["character"] = json.num(0);
    let b = json.obj();
    b["line"] = json.num(to_line);
    b["character"] = json.num(0);
    let r = json.obj();
    r["start"] = json.jobj(a);
    r["end"] = json.jobj(b);
    let p = json.obj();
    p["textDocument"] = json.jobj(td);
    p["range"] = json.jobj(r);
    json.jobj(p)
}

def ask(st: State, id: long, p: json.Val) -> json.Val {
    ask_method(st, id, "textDocument/semanticTokens/full", p)
}

def ask_method(st: State, id: long, method: str, p: json.Val) -> json.Val {
    let raw = dispatch.doc_request(st, json.num(id), method, serve.params_of(p));
    let got = json.parse(raw);
    let out = json.nul();
    if is_some(got) { out = json.jobj(got!); };
    serve.field_of(serve.members_of(out), "result")
}

// The ints, one at a time: `json.Arr.items` is [json.Val], so the array has to be
// walked rather than assigned -- which is also why decode() takes [long] and this
// does the conversion.
def data_of(v: json.Val) -> [long] {
    let out: [long] = [];
    let a = serve.field_of(serve.members_of(v), "data");
    if let json.Arr arr = a {
        let k = 0;
        while (k < len(arr.items)) {
            let got = json.as_long(arr.items[k]);
            if is_some(got) { out += got!; };
            k = k + 1;
        };
    };
    out
}

// One decoded token as line/start/len/class, from the 5-tuple delta encoding.
type RangeTok = { line: long, start: long, len: long, cls: long };

def decode(data: [long]) -> [RangeTok] {
    let out: [RangeTok] = [];
    let line = 0;
    let start = 0;
    let i = 0;
    while (i + 4 < len(data)) {
        if (data[i] == 0) { start = start + data[i + 1]; } else { line = line + data[i]; start = data[i + 1]; };
        out += { line: line, start: start, len: data[i + 2], cls: data[i + 3] };
        i = i + 5;
    };
    out
}

def same(a: RangeTok, b: RangeTok) -> bool {
    a.line == b.line && a.start == b.start && a.len == b.len && a.cls == b.cls
}

// The 0-based line of each occurrence of `needle`, so the range is stated in terms
// of what is in the fixture rather than counted by hand.
def line_of(needle: str) -> long {
    let out = 0;
    let k = 0;
    while (k < NL) {
        if (index_of(LINES[k], needle) >= 0 && out == 0) { out = k; };
        k = k + 1;
    };
    out
}

let st = serve.server_state("/tmp/opencode", "", 0);
let doc = json.obj();
doc["uri"] = json.str(URI);
doc["languageId"] = json.str("y");
doc["version"] = json.num(1);
doc["text"] = json.str(SRC);
let op = json.obj();
op["textDocument"] = json.jobj(doc);
serve.note_open(st, op);

// The capability itself is asserted in client-check.js, which reads it off a real
// initialize response -- this fixture is about what the range CONTAINS, and the
// `range: true` advertisement is the switch that makes any of it happen.
//
// t009_proto's accessors, which are the ones this test tree already proves: a
// `json.Val` is widened to a map once and every read goes through that.
def field(v: json.Val, k: str) -> json.Val {
    serve.field_of(serve.members_of(v), k)
}

// 4. no range in the request means the whole document.
let whole = decode(data_of(ask(st, 2, at(0, 0))));
print("no range -> " + tostring(len(whole)) + " tokens");

// A range over the middle of the fixture: `def use` through the closing brace.
let lo = line_of("def use");
let hi = line_of("q + s.length");
let part = decode(data_of(ask(st, 3, rng(lo, hi))));
print("range " + tostring(lo + 1) + "-" + tostring(hi + 1) + " -> " + tostring(len(part)) + " tokens");
print("fewer than the whole document: " + tostring(len(part) < len(whole)));

// 2. nothing outside the range.
let outside = 0;
let i = 0;
while (i < len(part)) {
    if (part[i].line < lo || part[i].line > hi) { outside = outside + 1; };
    i = i + 1;
};
print("nothing outside the range: " + tostring(outside == 0));

// 1. identical where they overlap.
let same_n = 0;
let differ = 0;
let absent = 0;
i = 0;
while (i < len(part)) {
    let t = part[i];
    let j = 0;
    let hit: RangeTok? = none;
    while (j < len(whole)) {
        if (same(t, whole[j])) { hit = some(whole[j]); j = len(whole); } else { j = j + 1; };
    };
    if (is_some(hit)) { same_n = same_n + 1; } else { absent = absent + 1; };
    i = i + 1;
};
print("every ranged token is in the whole-document answer: " + tostring(absent == 0));
print("identical, not merely present: " + tostring(absent == 0));

// ── the OTHER method ─────────────────────────────────────────────────────
//
// `range: true` is not "full, with an optional range". There are two methods --
// `semanticTokens/full` and `semanticTokens/range` -- and advertising `range`
// is what makes a client send the second one. Implementing only the first half and
// not routing the method meant every viewport request answered `-32601
// unsupported request`, the client fell back to the whole document, and the 400KB
// response came back anyway. A real editor log showed it once per viewport change:
//
//     Request textDocument/semanticTokens/range failed.
//       Message: unsupported request: textDocument/semanticTokens/range
//
// So the method is named here, not the parameter, and it must give the SAME answer
// as /full carrying the same range -- one implementation behind two names.
let by_range_method = decode(data_of(ask_method(st, 6, "textDocument/semanticTokens/range", rng(lo, hi))));
print("semanticTokens/range is routed: " + tostring(len(by_range_method) == len(part)));
print("and answers identically: " + tostring(len(by_range_method) > 0 && same(by_range_method[0], part[0])));

// And the whole-document call with a range must still agree with it, since a
// client that only knows /full is allowed to send the range as an argument.
let same_shape = 0;
let k2 = 0;
while (k2 < len(by_range_method)) {
    let j = 0;
    let hit = false;
    while (j < len(part)) {
        if (same(by_range_method[k2], part[j])) { hit = true; j = len(part); } else { j = j + 1; };
    };
    if (hit) { same_shape = same_shape + 1; };
    k2 = k2 + 1;
};
print("every token matches across both methods: "
    + tostring(same_shape == len(by_range_method)));

// A one-line range, because the edges are where a bounds mistake shows up.
let one = decode(data_of(ask(st, 4, rng(hi, hi))));
print("a one-line range is smaller still: " + tostring(len(one) < len(part)));

// And a range past the end of the document must not read out of bounds: the LSP
// says a client may send one, and a server that traps on it is a crash on open.
let past = decode(data_of(ask(st, 5, rng(NL + 50, NL + 90))));
print("a range past the end answers empty: " + tostring(len(past) == 0));