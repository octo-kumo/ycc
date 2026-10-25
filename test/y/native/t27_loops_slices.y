// Counted loops, slicing, array equality and range() in the native backend
// — the features that let test/y/examples run natively.
let xs = [10, 20, 30, 40, 50];

// slicing: half-open, clamped, always a NEW array
let mid = xs[1:3];
print(len(mid));
print(mid[0]);
let head2 = xs[:2];
print(head2[1]);
print(len(xs[3:]));
print(len(xs[:]));
print(len(xs[3:1]));
print(len(xs));

// structural array equality (so `arr == []` is an emptiness test)
let a = [1, 2];
let b = [1, 2];
print(a == b);
print(a == [1, 3]);
print(a == []);
print([] == []);

// for (init; cond; step)
let sum = 0;
for (let i = 0; i < 5; i = i + 1) {
    sum = sum + i;
};
print(sum);

// for x in lo..hi — half-open
let r = 0;
for j in 0..4 {
    r = r + j;
};
print(r);

// foreach over an array, and over range()
let total = 0;
foreach (v in xs) {
    total = total + v;
};
print(total);

let c = 0;
foreach (k in range(4)) {
    c = c + k;
};
print(c);

// a recursive fold: slicing + an array-emptiness guard + a closure argument
def fold(arr: [long], acc: long, f: (long, long) -> long) -> long {
    if (arr == []) { acc } else { self(arr[1:], f(acc, arr[0]), f) }
};
print(fold(xs, 0, def(acc: long, x: long) -> long { acc + x }));
