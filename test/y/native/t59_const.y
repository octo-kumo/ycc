// const: the name cannot be rebound (=, op=, ++/--) but what it refers to
// stays mutable -- in-place array ops, element and field stores all work.
const N = 10;
const S = "abc";
const A: [long] = [1, 2];
A += 3;
A[0] = 7;
A *= 0;
A[1]++;
A[2] += 5;
const R = {x: 1};
R.x = 3;
print(N);
print(S);
print(A);
print(R.x);
def f() -> long { const K = 5; K * N };
print(f());