// expect-error: expected a name after 'let', got 'native'
// expect-error: expected a parameter name, got 'native'
// expect-error: 'f' takes 0 args, got 1
// expect-error: expected an expression, got 'native'
// `native` is a KEYWORD, so it is not a name in any position a name is wanted.
// That is the whole of "reserved", and nothing else in the suite would notice
// if it stopped being true: every other e3* fixture spells `native def`
// correctly, so a lexer that made it a SOFT keyword -- an identifier unless a
// `native def` happened to be in sight -- would compile all of them unchanged,
// and the word would be reserved only in the one place that needed it to be.
//
// The messages are ones the suite already pins (e38_decl_name.y has the first
// with a number in place of the keyword, and the third is what the second
// causes: the parameter never happened, so the def has none). What is new here
// is only that the token is a keyword -- the point of a reserved word being
// that nothing may take its name.
let native = 1;
def f(native: long) -> long { native };
print(f(native));
print(1 + native);