// Radix integer literals in the native backend: 0x/0X hex, 0b/0B binary,
// with `_` separators. The emitter normalizes them to decimal immediates
// (the assembler only understands plain decimal).
print(0xff);
print(0xFFAB);
print(0XFF);
print(0b101);
print(0B1111);
print(0x10 + 0b10);
print(0xdead_beef);
let mask = 0xF0;
let bits = 0b1010;
print(mask + bits);
print(42);
