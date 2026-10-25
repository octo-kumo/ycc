// Empty source fragments beside generated text must not make it user text.
// In particular, a piece need not end with a newline to avoid the top-level
// runs-twice warning. Keep the pure generated lines free of source comments.
def piece(n: long) -> str { "print(" + tostring(n) + ");" }
def lines() -> str { "print(2);\nprint(3);" }
#{ piece(1) }#
#{ lines() }#
#{ piece(4) }#
#{ piece(5) }#
#{ "" }#
// Nonempty source fragments still contribute provenance on mixed lines.
// Use generated declarations so only the real source statements warn.
print(6);#{ "let generated_a = 7;" }#; // expect-warning: a top-level statement runs once in the meta generator and once in the program, so with a meta block in the file it must be a declaration (a def, type, const or let) -- keep a top-level let initializer pure
#{ "let generated_b = 8;" }#;print(9); // expect-warning: a top-level statement runs once in the meta generator and once in the program, so with a meta block in the file it must be a declaration (a def, type, const or let) -- keep a top-level let initializer pure
#{ "print(10);\n" }#
print(15); // expect-warning: a top-level statement runs once in the meta generator and once in the program, so with a meta block in the file it must be a declaration (a def, type, const or let) -- keep a top-level let initializer pure
