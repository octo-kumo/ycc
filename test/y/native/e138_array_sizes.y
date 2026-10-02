// expect-error: 11:13: error: expected an array size (an integer literal from 0 to 2147483647), got '1e3'
// expect-error: 12:13: error: expected an array size (an integer literal from 0 to 2147483647), got '2147483648'
// expect-error: 13:13: error: expected an array size (an integer literal from 0 to 2147483647), got '0x8000_0000'
// expect-error: 14:13: error: expected an array size (an integer literal from 0 to 2147483647), got 'n'
// expect-error: 15:15: error: expected an array size (an integer literal from 0 to 2147483647) in a type, got '2.5'
// expect-error: 16:15: error: expected an array size (an integer literal from 0 to 2147483647) in a type, got '-'
// The size in `[v; n]` and `[T; n]` is an integer literal, decimal or
// radix, from 0 to 2^31 - 1: a float, a larger number (one that would wrap
// included), a negative one or a variable is reported at the size.
let n = 3;
let a = [0; 1e3];
let b = [0; 2147483648];
let c = [0; 0x8000_0000];
let d = [0; n];
let e: [long; 2.5] = [1, 2];
let f: [long; -1] = [];
