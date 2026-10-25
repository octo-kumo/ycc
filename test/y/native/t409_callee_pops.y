// A Y def pops its own arguments (`ret $8n`); a runtime y_ def leaves them to
// its caller. A y_ def used as a function value is called the first way, so
// its value is a thunk that pops for it (native.y pop_thunk). Every call
// shape is here: direct, self, a capturing closure, a closure value, a lambda
// an array method calls directly, and the thunk.
def y_twice(a: long, b: long) -> long { a * 2 + b };
def apply(f: (long, long) -> long, x: long) -> long { f(x, 1) };
print(apply(y_twice, 20));
print(y_twice(4, 1));
let xs = [3, 1, 2];
print(xs.map((v) => v * 10));
def mk(k: long) -> (long) -> long { (v: long) => v + k };
let g = mk(5);
print(g(1));
def fact(n: long) -> long { if (n < 2) { 1 } else { n * self(n - 1) } };
print(fact(10));
def walk(n: long, acc: long) -> long { if (n == 0) { acc } else { walk(n - 1, acc + n) } };
print(walk(100000, 0));
def outer(m: long) -> long {
    def inner(i: long) -> long { if (i == 0) { m } else { inner(i - 1) + 1 } };
    inner(3)
};
print(outer(10));
let fs = [y_twice, apply2];
def apply2(a: long, b: long) -> long { a - b };
let t = 0;
foreach (f in fs) { t += f(7, 2); };
print(t);
