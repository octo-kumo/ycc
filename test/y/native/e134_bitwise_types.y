// expect-error: 11:13: error: '&' left operand: expected long, got float
// expect-error: 12:11: error: '<<' right operand: expected long, got str
// expect-error: 13:9: error: unary '~': expected long, got bool
// expect-error: 14:14: error: '^' left operand: expected long, got bool
// expect-error: 15:13: error: '>>' left operand: expected long, got [long]
// expect-error: 16:11: error: '>>>' right operand: expected long, got float
// expect-error: 18:3: error: '&=' needs an integer target, got float
// expect-error: 20:3: error: '|=' value: expected long, got float
// expect-error: 22:3: error: '>>>=' needs an integer target, got str
// expect-error: 24:6: error: '<<=' value: expected long, got str
let a = 1.5 & 1;
let b = 1 << "2";
let c = ~true;
let d = true ^ 1;
let e = [1] >> 1;
let g = 1 >>> 2.0;
let f = 2.5;
f &= 1;
let n = 1;
n |= 0.5;
let s = "x";
s >>>= 1;
let bits: byte = 1;
bits <<= "x";
