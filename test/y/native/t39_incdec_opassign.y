// ++/-- and the compound-assignment family (+= -= *= /= %=).
// The target's subexpressions are evaluated EXACTLY ONCE: a[f()] runs
// f() one time however the place is used. Postfix yields the old value,
// prefix the new one.

// numbers: both forms, both directions
let x = 10;
x++;
++x;
x--;
--x;
print(x);
let y = x++;
print(y);
print(x);
let z = ++x;
print(z);
print(x);

// the op= family
let n = 100;
n += 5;
n -= 3;
n *= 2;
n /= 4;
n %= 7;
print(n);

// strings concatenate (value semantics: the binding moves)
let s = "ab";
s += "cd";
print(s);

// exactly once: the index of a place runs ONE time
let calls = 0;
def idx() -> long {
    calls = calls + 1;
    2
};
let a = [0, 0, 0, 0, 0];
a[idx()] += 7;
print(a[2]);
print(calls);
a[idx()]++;
print(a[2]);
print(calls);

// nested places: base and index each run once
let calls2 = 0;
def f2() -> long {
    calls2 = calls2 + 1;
    0
};
let g2c = 0;
def g2f() -> long {
    g2c = g2c + 1;
    1
};
let mm = [[0, 0], [0, 0]];
mm[f2()][g2f()] += 5;
print(mm[0][1]);
print(calls2);
print(g2c);
mm[f2()][g2f()]++;
print(mm[0][1]);
print(calls2);
print(g2c);

// through record fields and nested records
let rec = { v: [7], n: 1 };
rec.n += 2;
print(rec.n);
rec.v[0] += 1;
print(rec.v[0]);
let deep = { a: { b: 5 } };
deep.a.b++;
print(deep.a.b);
--deep.a.b;
print(deep.a.b);
