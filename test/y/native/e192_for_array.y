// Walking an array with `for ... in` -- the obvious spelling, and the one
// that does not compile. It used to say `expected '..', got '{'`: accurate
// about what the parser wanted, silent about the form that walks a sequence.
// The message now names the form that does.
let xs = [1, 2, 3];
for x in xs { print(x); }; // expect-error: 6:13: error: 'for ... in' walks an integer range (for x in lo..hi); to walk an array, a str or keys(m), use 'foreach (x in expr)'
let m = {"a": 1};
for k in keys(m) { print(k); }; // expect-error: 8:18: error: 'for ... in' walks an integer range (for x in lo..hi); to walk an array, a str or keys(m), use 'foreach (x in expr)'
