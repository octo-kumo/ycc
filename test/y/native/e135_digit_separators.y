// expect-error: 6:9: error: unexpected '_5' (expected ',' or ')')
// expect-error: 7:8: error: unexpected 'e_5' (expected ',' or ')')
// A `_` digit separator must follow a digit of its own part: right after
// the dot or the `e` it ends the literal, and what is left lexes as an
// identifier (`1.` is a float, `1` an integer).
print(1._5);
print(1e_5);
