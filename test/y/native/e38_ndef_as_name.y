// expect-error: expected a name after 'let', got 'ndef'
// expect-error: expected a parameter name, got 'ndef'
// expect-error: 'f' takes 0 args, got 1
// expect-error: expected an expression, got 'ndef'
// `ndef` is a KEYWORD, so it is not a name in any position a name is wanted.
// That is the whole of "reserved", and nothing else in the suite would notice
// if it stopped being true: every other e3* fixture spells `ndef`
// correctly, so a lexer that made it a SOFT keyword -- an identifier unless a
// `ndef` happened to be in sight -- would compile all of them unchanged,
// and the word would be reserved only in the one place that needed it to be.
//
// This fixture used to spell that word `native`, back when the declaration
// was two words and `native` was the keyword. The rename made `native` an
// ORDINARY IDENTIFIER -- native/t340_native_is_a_name.y is the positive half
// of that, and this is the negative half for the word that took its place.
//
// The messages are ones the suite already pins (e38_decl_name.y has the first
// with a number in place of the keyword, and the third is what the second
// causes: the parameter never happened, so the def has none).
let ndef = 1;
def f(ndef: long) -> long { ndef };
print(f(ndef));
print(1 + ndef);
