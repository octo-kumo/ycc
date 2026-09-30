// expect-error: appended elements
// Arrays are homogeneous: `rows += [3]` would splice longs into a
// [[long]] — under += an array VALUE appends its elements, so the
// element types must match. Wrap it to add a whole row instead.
let rows = [[1], [2]];
rows += [3];
print(len(rows));
