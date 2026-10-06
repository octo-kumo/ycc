// Recursive meta, the first acceptance case: a block inside a block.
//
// The inner block's text is SPLICED into the source of the block around it, and
// the enclosing source is then compiled and run -- so `let a = #{ "1+1" }#`
// becomes `let a = 1+1`, `a` binds 2, and the enclosing block's own text is the
// rendering of `a`: `2`.
//
// That is also why the pass writes each block's value through `tostring(...)`
// (meta.y mg_helpers): a nested block's text lands where an expression stood, so
// a block whose value is a `long` is the ordinary case here, not a corner.
def lit(s: str) -> str { return "\"" + s + "\"" };
// a `str` value is spliced in as TEXT, so it has to be quoted by the block
let lit1 = #{ lit("1+1") }#;
// and the case itself
let nested = #{ let a = #{ "1+1" }#; a }#;
// two deep, to show it is not a special case for one level
let deep = #{ let b = #{ let a = #{ "2*3" }#; a + 1 }#; b }#;
// a nested block that sees the top level, like any other
let scale = 10;
let withtop = #{ let n = #{ scale + 1 }#; tostring(n) }#;
// The four prints are top-level statements, so each is one of the warnings the
// pass's own rule names -- a `let` cannot print.
print(lit1); // expect-warning: a top-level statement runs once in the meta generator and once in the program, so with a meta block in the file it must be a declaration (a def, type, const or let) -- keep a top-level let initializer pure
print(nested); // expect-warning: a top-level statement runs once in the meta generator and once in the program, so with a meta block in the file it must be a declaration (a def, type, const or let) -- keep a top-level let initializer pure
print(deep); // expect-warning: a top-level statement runs once in the meta generator and once in the program, so with a meta block in the file it must be a declaration (a def, type, const or let) -- keep a top-level let initializer pure
print(withtop); // expect-warning: a top-level statement runs once in the meta generator and once in the program, so with a meta block in the file it must be a declaration (a def, type, const or let) -- keep a top-level let initializer pure
