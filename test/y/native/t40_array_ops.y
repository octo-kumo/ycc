// Array operator semantics. `+` always makes a NEW array (the operands
// are untouched), `+=` and `*=` mutate IN PLACE (every alias sees the
// change), `=` aliases. Arrays are homogeneous: the element types must
// match.

let p = [1, 2];
let q = [3, 4];

// arr + arr2 -> a new third array
let r = p + q;
print(len(r));
print(r[0]);
print(r[3]);
print(len(p));
print(len(q));

// arr + elem / elem + arr -> new arrays with one element added
let e1 = p + 9;
print(len(e1));
print(e1[2]);
let e2 = 8 + p;
print(e2[0]);
print(e2[2]);

// arr = arr2 aliases: one array, two names
let m1 = [1, 2];
let m2 = m1;
m1 += 3;
print(len(m2));
print(m2[2]);

// arr += elem -> in-place push
p += 5;
print(len(p));
print(p[2]);

// arr += arr2 -> in-place append of arr2's elements
p += q;
print(len(p));
print(p[4]);
print(len(q));

// a += a appends a snapshot of its own elements
let s2 = [1, 2];
s2 += s2;
print(len(s2));
print(s2[2]);
print(s2[3]);

// arr *= elem -> in-place prepend of one item
p *= 0;
print(len(p));
print(p[0]);
print(p[1]);

// nested arrays: the element type is the inner array
let grid = [[1, 2], [3, 4]];
grid[0] += 10;
print(len(grid[0]));
print(grid[0][2]);
grid[0] *= 0;
print(grid[0][0]);
print(len(grid[0]));

// an array VALUE under += appends its elements — so `rows += [[3]]`
// appends the single row [3]
let rows = [[1], [2]];
rows += [[3]];
print(len(rows));
print(rows[2][0]);
rows *= [0];
print(len(rows));
print(rows[0][0]);
print(rows[1][0]);
