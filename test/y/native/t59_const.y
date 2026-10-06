// const: the name cannot be rebound (=, op=, ++/--) and the value behind it
// cannot be modified either -- element, field and map stores, the in-place
// array forms and whole-slice writes are all refused when the name they
// reach the value through is a const. Reads are unaffected, and a `let`
// binding of the same shape is fully mutable.
const N = 10;
const S = "abc";
const A: [long] = [1, 2];
const R = {x: 1};
const M = {"k": 1};
let L: [long] = [1, 2];
L += 3;
L[0] = 7;
L *= 0;
L[1]++;
L[2] += 5;
let R2 = {x: 1};
R2.x = 3;
let M2 = {"k": 1};
M2["k"] = 5;
print(N);
print(S);
print(A[0] + A[1]);
print(R.x);
print(M["k"]);
print(L);
print(R2.x);
print(M2["k"]);
def f() -> long { const K = 5; K * N };
print(f());
