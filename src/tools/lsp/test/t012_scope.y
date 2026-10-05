// t012_scope.y -- nav.y: which declaration a name resolves to, and which names
// are visible where.
//
// The lookup is the whole of M4's Stage A, and every rule in it is a decision
// that could have gone the other way:
//
//   - a `let` is NOT visible before its own line (Y has no hoisting for one);
//     a `def` IS (that is what makes mutual recursion work). So the same name
//     used above its `let` must resolve to something else, or to nothing.
//   - the innermost of several visible declarations wins, not the first or the
//     last in source order.
//   - at ONE depth the later declaration wins, because that is what the
//     compiler does with a repeated top-level `def` (BUGS.md 3).
//   - a name declared inside a block is not visible before that block opens.
//
// Each case below prints the line:column it resolved to, or "none", so a
// regression names itself.

import scan from "../scan.y";
import scope from "../scope.y";
import nav from "../nav.y";
import pos from "../pos.y";

// The source under test. Line numbers in the comments are 0-based, as an LSP
// position is.
// The source under test, as one string per line and joined, rather than one
// long literal: a `\`-at-end-of-line continuation in a Y string keeps the
// newline AND the `\n` before it contributes another, so the written form
// silently double-spaced every line and every line number below was off by one.
let LINES: [str] = [
    "def target() -> long { 1 };",
    "let shared = 1;",
    "def dup() -> long { 1 };",
    "def dup() -> long { 2 };",
    "def shadow() -> long {",
    "    let shared = 2;",
    "    shared",
    "};",
    "def uses_before_let() -> long {",
    "    print(shared);",
    "    let shared = 3;",
    "    shared",
    "};",
    "def uses_before_def() -> long {",
    "    later()",
    "};",
    "def later() -> long { 9 };",
    "print(target());"
];
const SRC = join(LINES, "\n");

let IDX = scope.index_src(SRC, "t012.y");
let SPS = scan.scan_full(SRC).spans;

// "name at (line, char)" -> the line:character it resolved to, or "none".
def at(name: str, line: long, ch: long) -> str {
    let got = nav.find_decl(IDX, name, line, ch);
    if (got == none) { "none" } else {
        let d: IdxDecl = got!;
        tostring(d.line) + ":" + tostring(d.ch)
    }
}

// The offset of an LSP position, so the fixture can go through the SAME
// conversion a request does rather than a convenient one. (Named for what it
// does here; scan.off_at takes a line and a byte column, not a position.)
def here_off(line: long, ch: long) -> long {
    let col = pos.from_lsp(SRC, line, ch);
    scan.off_at(SRC, pos.src_line(line), col)
}

// ── the word under the cursor ──
// `target` at line 0, columns 4..9. Column 9 is one past the `t`, which is
// where a caret sits after typing the name: it must still find `target`.
def word_at_col(ch: long) -> str {
    let h = nav.ident_at(SPS, SRC, here_off(0, ch));
    if (h == none) { "none" } else { (h!).name }
}

print("-- the word under the cursor");
print("col 4 " + word_at_col(4));
print("col 9 (just past the last letter) " + word_at_col(9));
print("col 10 (past the word) " + word_at_col(10));
// A keyword is not a name to resolve, even though it is a word.
let kw = nav.ident_at(SPS, SRC, here_off(0, 0));
print("on the `def` keyword " + (if (kw == none) { "none" } else { (kw!).name }));

// Line numbers below are the ones LINES above gives: 9 is `print(shared);`,
// 10 its `let shared`, 11 the `shared` after it, 14 `later()`, 17 the top-level
// `print(target());`.
print("-- plain resolution");
print("target used at top level (17:7) -> " + at("target", 17, 7));
print("shared inside shadow (6:5) -> " + at("shared", 6, 5));
print("shared ABOVE its own let (9:11) -> " + at("shared", 9, 11));
print("shared BELOW its own let (11:5) -> " + at("shared", 11, 5));
print("later above its own def (14:5) -> " + at("later", 14, 5));

print("-- shadowing: innermost wins");
print("dup from top level (17:7) -> " + at("dup", 17, 7));
// Asked AT the first of two same-depth declarations and answered with the
// second: that is the compiler's own rule for a repeated top-level def
// (BUGS.md 3), so a jump must land on the one that survived.
print("dup asked at the FIRST dup (3:4) -> " + at("dup", 3, 4));

print("-- a name from inside a block is not visible before the block");
print("inner `shared`, asked from line 0 (before shadow opens) -> " + at("shared", 0, 0));
print("`later`, asked from inside uses_before_def (13:5) -> " + at("later", 13, 5));
print("zzz, never declared -> " + at("zzz", 0, 0));

print("-- what completion offers");
// Names visible inside shadow() at line 6: the two top-level defs it can see,
// `shared` (once, not twice), and nothing from uses_before_let, which has not
// been entered yet.
let here = nav.visible(IDX, 6, 5);
let names: [str] = [];
foreach (d in here) { names += d.name; };
print("inside shadow(): " + ", ".join(names));
// The prefix filter.
let pre = nav.with_prefix(here, "sh");
let pnames: [str] = [];
foreach (d in pre) { pnames += d.name; };
print("  with prefix sh: " + ", ".join(pnames));
// Inside uses_before_let at line 11, its own `shared` has been declared, so the
// representative kept for the name is that one rather than the top-level `let`.
let there = nav.visible(IDX, 11, 5);
let tnames: [str] = [];
foreach (d in there) { tnames += d.name; };
print("inside uses_before_let(): " + ", ".join(tnames));

// WHICH declaration stands for a name matters as much as the name being in the
// list: the detail and the doc shown beside a completion item come from the
// representative, so picking the outer one would advertise the wrong signature.
def repr_at(ds: [IdxDecl], name: str) -> str {
    let out = "none";
    let i = 0;
    while (i < len(ds)) {
        if (ds[i].name == name) {
            out = tostring(ds[i].line) + ":" + tostring(ds[i].ch);
        };
        i = i + 1;
    };
    out
}
print("  `shared` inside shadow() -> " + repr_at(here, "shared") + " (its own)");
print("  `shared` at 9:11, above the inner let -> " + repr_at(nav.visible(IDX, 9, 11), "shared") + " (the top-level one)");
print("  `shared` at 11:5, below the inner let -> " + repr_at(nav.visible(IDX, 11, 5), "shared") + " (the inner one)");

print("-- every visible name resolves back to itself");
// The round trip that matters for completion: a name offered at a point must be
// the name a jump from that point lands on. One that is not would mean the list
// and the lookup disagree.
let bad = 0;
foreach (d in here) {
    let got = nav.find_decl(IDX, d.name, 6, 5);
    if (got == none) { bad = bad + 1; }
    else {
        let g: IdxDecl = got!;
        if (g.line != d.line || g.ch != d.ch) { bad = bad + 1; print("  MISMATCH " + d.name); };
    };
};
print("round trip: " + tostring(bad) + " mismatches");

print("done");
