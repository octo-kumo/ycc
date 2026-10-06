// The oldest entry in BUGS.md, recorded eight times over as "a field of an
// `if let`-narrowed binding loses its map/array type". It does not. The `[]`
// on the line after the `if let` -- here the function's own value -- is an
// INDEX of the `if`, because expressions continue across newlines, and the
// checker names the fix. `t336_iflet_value_semicolon.y` is the same program
// with that `;` and it compiles and runs; `e175_index_valueless_if.y` is the
// rest of the same shape, and docs 03-grammar says "Statements are separated
// by `;`".
type TA = { n: long };
type TC = { v: { str => long } };
type U = TA | TC;

def bad(u: U) -> [str] {
    if let TC c = u { return keys(c.v); }
    []
} // expect-error: 15:5: error: cannot index this 'block', which has no value: add a ';' after it to make it a statement
