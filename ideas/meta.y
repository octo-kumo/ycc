// meta.y — a target sketch for compile-time code generation, `#{ … }#`.
//
// It is the worked example `ideas/meta.md` refers to, and every
// `// resolves to` below is **measured** — the generator code is the same code,
// compiled and run as an ordinary program (see the note at the foot of this
// file). It compiles and runs with `./ynew` (the branch's build of this
// compiler); `refs/ycc.ref` predates the feature and cannot build it.
//
// v1 is one construct. There is no `#if` and no `#meta`; a block is the top
// level, or inside another block, and it may not be inside a function body.
//
// Rules it leans on, all verified against refs/ycc.ref:
//   - `for … in` takes a RANGE only (`for i in 0..n`); arrays use
//     `foreach (x in xs) { … }`.
//   - `let` rebinds; there is no `mut`.
//   - a block's value is its last statement without a trailing `;`.
//   - `\"` inside a string yields a `"`, which is how a generator emits one.


// ---------------------------------------------------------------------------
// A generator is an ordinary top-level def taking ordinary parameters. It is
// visible to every block in this file, because a block sees the whole top level.
// ---------------------------------------------------------------------------

def quoted(s: str) -> str {
    return "\"" + s + "\"";
}

// `quoted` for text that goes where a whole LITERAL must go: it escapes the
// three bytes that would otherwise end the literal or read as an escape.
def lit(s: str) -> str {
    let out = "\"";
    let i = 0;
    while (i < s.length) {
        let c = byte_at(s, i);
        if (c == 34) { out += "\\\""; }
        else if (c == 92) { out += "\\\\"; }
        else if (c == 10) { out += "\\n"; }
        else { out += s[i:i + 1]; };
        i = i + 1;
    };
    return out + "\"";
}

def repeat(n: long, body: str) -> str {
    // an expression, so no `return` is needed — but `return` also works
    let out = "";
    for i in 0..n { out += body; }
    out
}

def emit_table(names: [str], scale: long) -> str {
    let out = "let scaled: [long] = [];\n";
    foreach (nm in names) {
        // `quoted(nm)`, not `nm` — a generator emits TEXT, so a value has to
        // become a literal. Getting this wrong compiles fine and then reports
        // `undefined variable 'a'` at the block's line.
        out += "scaled += " + quoted(nm) + ".length * " + scale + ";\n";
    }
    return out;
}

def emit_body(names: [str], scale: long) -> str {
    return emit_table(names, scale)
        + "foreach (v in scaled) { print(v, \" \"); }\n"
        + "print(\"done\\n\");\n";
}

// The CALL SITE of the mid-token def below, generated as text for the same
// reason the def's name is: the generator program holds the def under the
// SHORT name (`gen`), so the source may not mention the full one.
def emit_call(frag: str) -> str {
    return "print(\"mid-token \", gen" + frag + "(), \"\\n\");\n";
}

def emit_names(names: [str]) -> str {
    let parts: [str] = [];
    foreach (nm in names) { parts += quoted(nm); }
    return "let names = ["
        + ", ".join(parts)
        + "];\nprint(names.length, \" names\\n\");\n";
}


// ---------------------------------------------------------------------------
// The program's data. A top-level `let`/`const` is initialised in the generator
// too, so a block can read it — which is why the rule is: keep these pure.
// ---------------------------------------------------------------------------

const SCALE = 10;
const NAMES = ["a", "bb", "ccc"];
// The fragment spliced into a NAME, and the only such fragment in this file.
const FRAG = "assembled";


// ---------------------------------------------------------------------------
// The blocks. One block emits the program's whole body; there is nothing else
// at this top level, because with blocks present every other top-level
// statement would run twice (a warning, naming its line).
// ---------------------------------------------------------------------------

#{
    // statement position: the text lands here as the program's body
    emit_body(NAMES, SCALE) + emit_names(NAMES) + emit_call(FRAG)
}#
// resolves to:
//     let scaled: [long] = [];
//     scaled += "a".length * 10;
//     scaled += "bb".length * 10;
//     scaled += "ccc".length * 10;
//     foreach (v in scaled) { print(v, " "); }
//     print("done\n");
//     let names = ["a", "bb", "ccc"];
//     print(names.length, " names\n");
//     print("mid-token ", genassembled(), "\n");

// which compiles and runs as (measured, ./ynew -- `print` ends every call with
// a newline, so the "\n" inside two of them leaves a blank line):
//     10 
//     20 
//     30 
//     done
//     
//     3 names
//     
//     mid-token 99
//     

// A block's value is a `str`, and it is spliced in as TEXT -- so a string
// value has to be a LITERAL before it lands, or it lands as bare code and the
// program's own parser sees `let count = let names = …`. `lit` is that step
// (one level up from the bug in emit_table), and it has to escape: `quoted`
// alone wraps the quotes and leaves the inner ones and the newlines to be
// parsed as code, which reports `expected ';', got 'a'`. And a block whose
// value is not a `str` at all is refused by the existing checker, not by the
// pass: `#{ 1 + 1 }#` gives "'ycc_meta_expr' arg 1: expected str, got long".
let count = #{ lit(emit_names(NAMES)) }#;
// resolves to: let count = "…the 65 characters emit_names generates, escaped…";


// ---------------------------------------------------------------------------
// Nesting is DATA, not splicing: the inner block's text becomes a `str` the
// outer block uses. It does not inject code into the outer block.
// ---------------------------------------------------------------------------

// The outer block is a top-level `let`, so this is legal; note that putting the
// same two blocks inside a `def` would not be (see NOT AVAILABLE below).
let thrice = #{ lit(repeat(3, #{ lit(emit_names(["x"])) }# + "print(\\\"tick\\\\n\\\");\\n")) }#;
// resolves to: let thrice = "…";   (a literal: lit escapes the inner one too)
//
// and `thrice`, if the program printed it, would be:
//     let names = ["x"];
//     print(names.length, " names\n");
//     print("tick\n");
//     … × 3


// ---------------------------------------------------------------------------
// A MID-TOKEN block -- one with no operand position at its own byte offset --
// generates a NAME. Its bytes are dropped from the generator program, and its
// call is emitted as a statement immediately before the top-level statement the
// block is in; that is legal because dropping an adjunct between two adjacent
// tokens leaves them adjacent (`def gen()` from `def gen#{FRAG}#()`).
//
// Note the piece is BARE text, not a literal: `FRAG` splices as `assembled`,
// where `lit(FRAG)` would splice as `"assembled"` and leave `gen"assembled"`.
// ---------------------------------------------------------------------------

def gen#{FRAG}#() -> long { 99 };
// resolves to: def genassembled() -> long { 99 };
//
// and in the generator program, the block's call is hoisted one statement up:
//     ycc_meta_stmt(<slot>, { FRAG });
//     def gen() -> long { 99 };
//
// The full name appears in NO source line: the generator's own copy of the def
// is `gen`, so a source call to `genassembled()` would not resolve there. The
// call site is generated instead (emit_call), which is the shape that makes this
// usable at all. A block at the START of a name is a diagnostic, not a case --
// nothing ends a token there, and dropping its bytes would leave `def ()`.


// ---------------------------------------------------------------------------
// `import` inside a block is hoisted to the top of the generator program, so
// cycle detection and namespacing are the existing splicer's. A bare import
// keeps the module's namespace; a path import is flattened and can collide.
//
//   #{ import gen; gen.emit_all(NAMES) }#
//
// Not written out here: there is no `gen.y` to import, and a module imported
// into the generator may not itself contain a block.
//
// ---------------------------------------------------------------------------


// ---------------------------------------------------------------------------
// NOT AVAILABLE in v1, and each is a diagnostic rather than a silent surprise:
//
//   def f(n: long) -> long { #{ n }# }        a block inside a function body
//   def #{n}#() -> long { … }                 a header block that is not part of
//                                              a name -- see the mid-token section
//   #{ … }#  emitting  #{ … }#                a block emitting a block
//   #if os == "windows"                       no directives at all
//
// ---------------------------------------------------------------------------


// ---------------------------------------------------------------------------
// Every `// resolves to` above was produced by compiling this file's generator
// code as an ordinary program — same defs, same constants, blocks already
// evaluated — and running it under ./ynew. One of the comments records a
// bug that check caught: interpolating a value where a literal was needed
// (`a.length` instead of `"a".length`). A second was caught by the compiler
// itself: `let count` wanted the number 65 and got 65 as the *length* of the
// text `emit_names(NAMES)` generates, so the block now yields the text.
// ---------------------------------------------------------------------------
