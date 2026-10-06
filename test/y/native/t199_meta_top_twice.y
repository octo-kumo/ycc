// With a meta block in the file the top level IS the generator's program, so
// every top-level statement runs twice: once to build the generator, once in
// the program. A declaration is fine (a def hoists, a let a block reads should
// be pure); anything else is a warning naming it. The generated text a block
// produced is NOT warned about -- the program runs it once, and the generator
// never ran it at all.
def gen() -> str { "print(\"gen\\n\");\n" };
print("statement"); // expect-warning: a top-level statement runs once in the meta generator and once in the program, so with a meta block in the file it must be a declaration (a def, type, const or let) -- keep a top-level let initializer pure
let pure = 40 + 2;
#{ gen() }#
print("program", pure); // expect-warning: a top-level statement runs once in the meta generator and once in the program, so with a meta block in the file it must be a declaration (a def, type, const or let) -- keep a top-level let initializer pure
