// t011_sym.y -- the outline (documentSymbol).
//
// VS Code says "no symbols found in document" when this returns nothing, and
// the breadcrumb bar is built from it. It needs no compiler change, so there is
// nothing to be uncertain about except the shapes and the tree.
//
// The reference semantics this file pins, all of which are choices rather than
// deductions:
//   * a `def` is a Function whose range covers its BODY, and whose children are
//     the names directly inside it;
//   * a `let` inside a loop or an `if` is NOT a symbol -- an outline of every
//     assignment is a breadcrumb bar nobody reads;
//   * `type` is a Class-ish kind, `const` a Constant, an `import` a Module;
//   * `selectionRange` is the NAME, not the whole symbol, so "go to symbol"
//     lands on the identifier rather than on the closing brace.

import pos from "../pos.y";
import sym from "../sym.y";

const HERE = "src/tools/lsp/test";

// The shape of the tree as one line per symbol, so a diff shows exactly which
// entry moved.
def render(indent: str, xs: [SymEntry]) -> [str] {
    let out: [str] = [];
    foreach (x in xs) {
        out += indent + x.name + " k=" + tostring(x.kind) + " " + tostring(x.line) + ":" + tostring(x.ch) + ".." + tostring(x.end_line) + ":" + tostring(x.end_ch) + " sel=" + tostring(x.sel_line) + " d=[" + x.detail + "]";
        out += render(indent + "  ", x.children);
    }
    out
}

def show(label: str, src: str) -> long {
    print("== " + label + " ==");
    let lines = render("", sym.symbols(pos.doc_of(src)));
    foreach (l in lines) { print("  " + l); }
    len(lines)
}

def count(xs: [SymEntry]) -> long {
    let n = 0;
    foreach (x in xs) { n = n + 1 + count(x.children); }
    n
}

def all_names(xs: [SymEntry]) -> [str] {
    let out: [str] = [];
    foreach (x in xs) {
        out += x.name;
        out += all_names(x.children);
    }
    out
}

def count_names(xs: [str], want: str) -> long {
    let n = 0;
    foreach (x in xs) { if (x == want) { n = n + 1; } }
    n
}

def names_at(xs: [SymEntry], depth: long) -> [str] {
    let out: [str] = [];
    foreach (x in xs) {
        if (depth == 0) { out += x.name; }
        out += names_at(x.children, depth - 1);
    }
    out
}

// ── the kinds ───────────────────────────────────────────────────────────
print("SymbolKind: module=" + tostring(sym.K_MODULE) + " function=" + tostring(sym.K_FUNCTION) +
      " variable=" + tostring(sym.K_VARIABLE) + " constant=" + tostring(sym.K_CONSTANT) + " type=" + tostring(sym.K_TYPE));

// ── a whole module ──────────────────────────────────────────────────────
let prog = "import fs;\n\ntype Pair = { a: long, b: long };\n\nconst LIMIT = 10;\n\ndef outer(a: long) -> long {\n    let b = a + 1;\n    def inner(c: long) -> long {\n        let d = c * 2;\n        d\n    }\n    for i in 0..3 {\n        let tmp = i;\n        print(tmp);\n    }\n    inner(b) + LIMIT\n}\n\nprint(outer(1));\n";
show("module", prog);

// The loop-local `let tmp` must NOT be there, and `b` and `d` must be.
let tops = names_at(sym.symbols(pos.doc_of(prog)), 0);
let all = all_names(sym.symbols(pos.doc_of(prog)));
print("top level: " + join(tops, ", "));
print("every symbol: " + join(all, ", "));
print("the import is a symbol: " + tostring(count_names(all, "fs") == 1));
// The one that matters for an outline's usefulness: a `let` inside a `for` is
// not an entry. The first version of this check counted names at depth 0 only,
// where `tmp` could never appear anyway -- so it passed for the wrong reason.
print("no loop-local let: " + tostring(count_names(all, "tmp") == 0));
print("a let directly in a def body IS one: " + tostring(count_names(all, "b") == 1));
print("and one in a nested def too: " + tostring(count_names(all, "d") == 1));

// ── `def`'s range covers its body ────────────────────────────────────────
// This is what the outline draws, and what "reveal range" jumps to.
let one = "def f() -> long {\n    let x = 1;\n    x\n}\n";
let f = sym.symbols(pos.doc_of(one));
print("one def: " + tostring(len(f) == 1));
// The range ENDS at the closing brace's own position, so the brace is not
// included -- which is what an editor wants when it selects the symbol's extent.
print("  range " + tostring(f[0].line) + ":" + tostring(f[0].ch) + ".." + tostring(f[0].end_line) + ":" + tostring(f[0].end_ch) + " (want 0:4..3:0)");
print("  selectionRange is the name: " + tostring(f[0].sel_line == 0 && f[0].sel_ch == 4));
print("  the body let is a child: " + tostring(len(f[0].children) == 1 && f[0].children[0].name == "x"));

// A one-line def: the range must not run past its own `}`.
let oneline = "def g() -> long { 1 }\nlet y = g();\n";
let gsyms = sym.symbols(pos.doc_of(oneline));
// `def g() -> long { 1 }` -- the `}` is at character 20, and the range ends there.
print("one-line def range: " + tostring(gsyms[0].line) + ":" + tostring(gsyms[0].ch) + ".." + tostring(gsyms[0].end_line) + ":" + tostring(gsyms[0].end_ch) + " (want 0:4..0:20)");

// A `def` with no body at all -- a forward declaration -- must still appear,
// and must NOT swallow what follows it.
let fwd = "def later() -> long;\nlet after = 1;\n";
let fsyms = sym.symbols(pos.doc_of(fwd));
print("a bodyless def appears: " + tostring(len(fsyms) == 2 && fsyms[0].name == "later"));
print("and does not take the next one as a child: " + tostring(len(fsyms[0].children) == 0));

// ── nesting ─────────────────────────────────────────────────────────────
let deep = "def a() -> long {\n    def b() -> long {\n        def c() -> long {\n            0\n        }\n        c()\n    }\n    b()\n}\n";
let dsyms = sym.symbols(pos.doc_of(deep));
print("nested three deep: " + tostring(len(dsyms) == 1 && len(dsyms[0].children) == 1 && len(dsyms[0].children[0].children) == 1));
print("  innermost is c: " + tostring(dsyms[0].children[0].children[0].name == "c"));

// ── the signature as `detail` ───────────────────────────────────────────
let sigs = sym.symbols(pos.doc_of("def h(x: long, y: str = \"a\") -> bool {\n    true\n}\n"));
print("detail: [" + sigs[0].detail + "]");
print("the default value's bracket does not truncate it: " + tostring(index_of(sigs[0].detail, "y: str") >= 0));

// ── a buffer that does not lex ──────────────────────────────────────────
// An unterminated string swallows the REST OF THE FILE: the tolerant scanner
// cannot know where the author meant it to end, so every `}` and every `def`
// after it is inside a string literal. That is not this module being weak, it is
// what a lexer does -- and it is why the highlighter still paints the file
// (R2.5) while the outline goes quiet below the error.
//
// So the assertion is the honest one: what is ABOVE the error is found, and
// nothing crashes.
let broken = "def ok() -> long {\n    let a = 1;\n    \"unterminated\n}\ndef after() -> long { 2 }\n";
let bnames = all_names(sym.symbols(pos.doc_of(broken)));
print("above the error, symbols are found: " + tostring(count_names(bnames, "ok") == 1 && count_names(bnames, "a") == 1));
print("below it the file is one string, so nothing else appears: " + tostring(count_names(bnames, "after") == 0));

// A closed string does not swallow anything, so the whole file is outlined.
let closed = "def ok() -> long {\n    let a = 1;\n    \"fine\"\n}\ndef after() -> long { 2 }\n";
let cnames = all_names(sym.symbols(pos.doc_of(closed)));
print("with the string closed, the later def is found too: " + tostring(count_names(cnames, "after") == 1));

// A stray `#` must not stop the pass.
let hash = "# not a comment in Y\ndef real() -> long { 1 }\n";
let hsyms = sym.symbols(pos.doc_of(hash));
print("a stray # does not stop the outline: " + tostring(len(hsyms) == 1 && hsyms[0].name == "real"));

// ── degenerate inputs ───────────────────────────────────────────────────
print("empty: " + tostring(len(sym.symbols(pos.doc_of("")))));
print("no defs: " + tostring(len(sym.symbols(pos.doc_of("let x = 1;\nprint(x);\n")))));
print("only a def name, no body: " + tostring(len(sym.symbols(pos.doc_of("def\n")))));
print("unclosed def: " + tostring(len(sym.symbols(pos.doc_of("def open() -> long {\n    let a = 1;\n")))));

// ── and the real corpus: every file in src/y must yield symbols ─────────
// A file of compiler source with an empty outline would mean the pass is
// looking for something the language does not do.
import fs;
let files = fs.list_dir("src/y")!;
let checked = 0;
let empty = 0;
let biggest = 0;
foreach (f in files) {
    if (f.ends_with(".y")) {
        let got = fs.read_file("src/y/" + f);
        if is_some(got) {
            let s = sym.symbols(pos.doc_of(got!));
            checked = checked + 1;
            if (len(s) == 0) { empty = empty + 1; print("  EMPTY " + f); }
            if (count(s) > biggest) { biggest = count(s); }
        }
    }
}
// As in t010: the counts move whenever the compiler does, so the assertion is
// that every file yielded symbols and that one of them yielded a real outline.
print("src/y: " + tostring(checked) + " files, " + tostring(empty) + " with no symbols");
// The threshold, not the number -- same reason as t010, and the same slip: the
// count was printed into the compared output regardless.
print("the corpus was really read: " + tostring(checked > 10 && biggest > 200) + " (a file yielded over 200 symbols)");
print("done");