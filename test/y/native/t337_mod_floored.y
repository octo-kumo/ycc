// mod(a, b): the FLOORED remainder, whose sign follows the divisor. `%` is
// C's truncating one, and these are the cases
// where the two disagree plus the whole-long-range edges.
print(mod(-949, 100));
print(mod(949, 100));
print(mod(-7, 100));
print(mod(7, 100));
print(mod(0, 100));
print(mod(949, -100));
print(mod(-949, -100));
print(mod(-100, 100));
print(mod(100, 100));

// the wrap-around use the ledger wanted it for: a circular index that must
// land in 0..n-1 for every input, negative included
def wrap(i: long, n: long) -> long { mod(i, n) };
let is = [-7, -1, 0, 1, 7, 100, 101];
foreach (i in is) { print(tostring(i) + "->" + tostring(wrap(i, 5))); };

// the whole long range: LONG_MIN / -1 would raise #DE under idiv, so both
// `%` and mod compile that divisor as a constant zero
let lo = -9223372036854775807 - 1;
print(mod(lo, 3));
print(mod(lo, -1));
print(mod(lo, 2));
print(mod(lo + 1, 3));
