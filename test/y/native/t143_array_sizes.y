// The size in `[v; n]` and `[T; n]`: an integer literal from 0 to
// 2^31 - 1, decimal or radix, `_` separators and all.
let a = [0; 0x10];
let b = ['x'; 0b11];
let c = [0; 2_0];
let d: [long; 0x3] = [1, 2, 3];
let e = [0; 0];
let f: [byte; 0B1_0] = ['h', 'i'];
print(len(a));
print(len(b));
print(len(c));
print(len(d));
print(len(e));
print(len(f));
