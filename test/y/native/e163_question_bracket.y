// `x?[i]` is the option-propagation operator `?.[` with its dot left out, and
// as written it is not a conditional at all: `?` directly against `[` starts
// no `c ? a : b`, so the parser says which spelling was meant instead of
// blaming the token after the array literal ("expected ':' in conditional
// expression"). The space is what separates the two: `x ? [0] : [1]` is a
// conditional whose arm is an array literal (t48).
def nums() -> [long]? { some([1, 2, 3]) }
def rows() -> [[long]]? { some([[1]]) }
let a = nums();
// expect-error: 11:18: error: '?[' is not a conditional: write '?.[' to propagate into a subscript (x?.[i])
let bad_index = a?[0];
// expect-error: 13:18: error: '?[' is not a conditional: write '?.[' to propagate into a subscript (x?.[i])
let bad_slice = a?[0:2];
// expect-error: 15:18: error: '?[' is not a conditional: write '?.[' to propagate into a subscript (x?.[i])
let bad_chain = a?[0].f;
let bad_row = rows()?.[0][0];
// expect-error: 18:20: error: '?[' is not a conditional: write '?.[' to propagate into a subscript (x?.[i])
let also_bad = a?.f?[1];
print(bad_index, bad_slice, bad_chain, bad_row, also_bad);