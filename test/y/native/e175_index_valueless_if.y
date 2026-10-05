// An `if` in expression position with nothing to give, indexed because a
// `[` follows it: `if (c) { A }["x"]` is `A["x"]`, and A's arms are
// statements -- or disagree, so the `if` is void. A `;` after the block is
// what makes the `if` a statement, and it is the whole of the fix.
//
// The diagnostic said `cannot index void (only arrays and maps)`, at the
// `[`. That names neither the base nor the fix, and nothing near it in the
// source shows an index of an `if`: the `[` reads as an array literal, which
// is how this shape reached the bug ledger seven times over, each time
// diagnosed as the narrowed binding's field type being lost.
//
// An `if` that does give a value is indexed as whatever it gave: a
// `["y"]`/`["z"]` pair indexed at 0 is a `str`, and that is the ordinary
// message ("cannot index str" / a body-type mismatch), unchanged.
def a(c: bool) -> [str] { if (c) { print("x"); } ["y"] } // expect-error: 15:50: error: cannot index this 'if', which has no value: add a ';' after it to make it a statement

def b() -> long { { print("x"); }[0] } // expect-error: 17:34: error: cannot index this 'block', which has no value: add a ';' after it to make it a statement

def d(c: bool) -> [str] { if (c) { let ys: [str] = ["y"]; }["z"] } // expect-error: 19:60: error: cannot index this 'if', which has no value: add a ';' after it to make it a statement

// an `if` whose arms disagree is void too, and the same `;` resolves it
def e(c: bool) -> [str] { if (c) { ["y"] } else { print("x"); }[0] } // expect-error: 22:64: error: cannot index this 'if', which has no value: add a ';' after it to make it a statement