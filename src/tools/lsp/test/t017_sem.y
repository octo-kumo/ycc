// t017_sem.y -- what a name DENOTES: R2.3's semantic classes (LSP.md §9.2, B3).
//
// t010_sem pins the ENCODING -- the delta decoding, the legend's length and order,
// the one-token-per-line rule -- over every `.y` file in the tree. This pins the
// CLASSES: that an identifier is painted as a parameter, a function, a property, a
// type or a builtin according to what it resolves to, and that a name which
// resolves to nothing stays `variable`.
//
// Every class is the server's own resolution plus the compiler's own lists, never
// a guess: `builtin` is `native.intrinsic_names()`, `parameter`/`function`/`type`
// are `scope`'s declaration kinds, and `property` is a fact about the text (a name
// after a `.`). The block at the end is the part worth having -- the names that
// must stay `variable`, because a class a name has not earned is worse than no
// class at all, and an editor paints both.
//
// Every column is FOUND in the line's text, not written out: the sibling fixtures
// that hard-coded columns were wrong on most of them, which made their
// "must not be a method" / "no type here" assertions pass for the wrong reason --
// the request landed on whitespace. See t016_types.
//
// It goes through `serve.classify_text` and `sem.tokens_in` rather than a
// `semanticTokens/full` request, which is the same path the request handler takes
// (serve.do_semantic_tokens calls exactly these two) and needs no JSON.

import sem from "../sem.y";
import pos from "../pos.y";
import serve from "../serve.y";

const LINES: [str] = [
    "type Pair = { a: long, b: long };",                      // 0
    "",                                                          // 1
    "def twice(n: long) -> long {",                             // 2
    "    let inner = n * 2;",                                   // 3
    "    inner",                                                // 4
    "}",                                                        // 5
    "",                                                          // 6
    "let mul = def (a: long, b: long) -> long { a * b };",      // 7
    "let total = twice(2) + mul(3, 4);",                        // 8
    "let p: Pair = { a: 1, b: 2 };",                            // 9
    "let q = p.a;",                                             // 10
    "let r = twice;",                                           // 11
    "",                                                          // 12
    "let s = nosuchthing;",                                     // 13
    "let t = later;",                                           // 14
    "let later = 1;",                                           // 15
    "print(total);"                                             // 16
];
const SRC = join(LINES, "\n");

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

let legend = sem.token_types();
let toks = sem.tokens_in(pos.doc_of(SRC), serve.classify_text(SRC, ""));

// The class of the token covering (line, ch), by the legend's NAME. A name and
// not a number: a number would let a legend reordering pass unnoticed, which is
// the one thing t010_sem exists to catch.
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

def cls(line: long, needle: str, at: long) -> str {
    let c = col_of(line, needle, at);
    if (c < 0) { "NO-SUCH-COLUMN" } else { class_at(line, c) }
}

print("-- the legend, in index order");
print("legend: " + tostring(len(legend)) + " types: " + join(legend, ", "));

print("-- the five semantic classes");
print("Pair, a type alias: " + cls(0, "Pair", 0));
print("twice, a def: " + cls(2, "twice", 0));
print("n, a parameter: " + cls(2, "n:", 0));
print("a, a closure parameter: " + cls(7, "a:", 0));
print("mul, a let bound to a signature: " + cls(7, "mul", 0));
print("print, a builtin: " + cls(16, "print", 0));
print("a of p.a, a property: " + cls(10, "a;", 0));
// A record LITERAL's field name is not a property by this rule, and is pinned as
// such. `a` in `{ a: 1 }` is followed by `:` exactly like `x` in `let x: T = 1`,
// so the text cannot tell the two apart, and the thing that can -- that the brace
// opens a record rather than a block -- is not something a span knows. Guessing it
// would paint every `let`'s name as a property, which is a worse wrong answer
// than the plain one.
print("a of a record literal, still variable: " + cls(9, "a:", 0));

print("-- and what stays `variable`");
print("inner, a let: " + cls(4, "inner", 0));
print("p, an ordinary variable: " + cls(10, "p.", 0));
print("a name nothing declares: " + cls(13, "nosuchthing", 0));
print("a name used before its own line: " + cls(14, "later", 0));

print("-- and the syntactic classes are untouched");
print("the `type` keyword: " + class_at(0, 0));
print("a number: " + class_at(9, col_of(9, "1,", 0)));

print("-- every identifier in the buffer got a class from the legend");
let unknown = 0;
let i = 0;
while (i < len(toks)) {
    let t = toks[i];
    if (t.typ < 0 || t.typ >= len(legend)) { unknown = unknown + 1; };
    i = i + 1;
};
print("tokens outside the legend: " + tostring(unknown) + " of " + tostring(len(toks)));

print("done");
