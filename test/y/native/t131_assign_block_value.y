// An assignment ending a block gives the block its value: the value
// stored (Section "Assignment").
let x = 0;
let y = { x = 5 };
print(x);
print(y);
let s = "a";
let t = { s = s + "b" };
print(t);
def f(n: long) -> long { x = n * 2 };
print(f(4));
print(x);
let q = { x += 2 };
print(q);
print(x++ + 10);
print(x);
