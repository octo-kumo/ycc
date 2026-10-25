// Top-level number consts are read as their literal (native.y fold_consts), so
// `n == L.x` compares against an immediate. What must not fold: a record const
// read whole (it may be aliased and written through, as k2 and f do here), a
// const whose address is taken, and an annotated const whose literal is not the
// value's type (`F` is 2.0, not 2). A float literal folds to its bits.
const K = { a: 1, b: 2 };
const L = { x: 3, y: 40, s: "s" };
const A = 7;
const P = 5;
const F: float = 2;
const H = 0.5;
const BIG = 0x7FFF_FFFF_FFFF_FFFF;
def f(r: { a: long, b: long }) { r.a = 9; };
let k2 = K;
k2.b = 5;
f(K);
print(K.a);
print(K.b);
let n = 3;
if (n == L.x) { print(L.y + A); };
print(n << A);
print(L.s);
let p = &P;
print(*p + P);
print(F / 4.0);
print(H * 3.0);
print(BIG - 1);
def g(x: long) -> long {
    let A = x * 2;
    A + L.y
};
print(g(A));
