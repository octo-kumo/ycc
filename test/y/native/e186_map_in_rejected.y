// TODO.md item 14 gave `in` a second position: `"k" in m` asks a map for a key.
// The right operand must be a MAP for that question, and the left must be
// that map's key type, since it is the key the scan looks for.
//
// A str or an array on the right is a DIFFERENT question and stays what it
// was -- `"a" in "text"`, `1 in [1, 2]` -- with its own diagnostics pinned by
// e372_in_errors.y. So only the right operands that are neither a map nor one
// of those are rejected here.
let m: { str => long } = { "a": 1 };

// expect-error: 12:11: error: 'in' needs a str, an array or a map on the right, got long
print("a" in 5);
// expect-error: 14:9: error: 'in' left operand: expected str, got long
print(1 in m);

// a read is not a map either, and neither is a dot read: both are values
print("a" in m["k"]); // expect-error: 17:11: error: 'in' needs a str, an array or a map on the right, got long?
print("a" in m.a); // expect-error: 18:11: error: 'in' needs a str, an array or a map on the right, got long
