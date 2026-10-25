// Octal literals: `0o` / `0O`, with `_` grouping, and the radix literals it
// now shares one prefix test with (`radix_of` in lexer.y, which retired the
// copies in parser, types, native and lint).
//
// The value is the octal reading, not a decimal one: 0o644 is 420 and 0o755 is
// 493, which is what std/fs.y's mode arguments have been spelling the long way
// round. A leading zero with no `o` stays decimal -- `017` is 17 -- so no
// existing program changes meaning.
print(0o644);
print(0o755);
print(0o7_5_5);
print(0O17);
print(0o0);
print(0o777);
// the radix literals it shares the prefix test with
print(0x1f);
print(0b101);
// and a leading-zero decimal, unchanged
print(017);
// in arithmetic and as a fixed-array size, the two other readers of a literal
print(0o10 + 0o10);
let a: [long; 0o4] = [1, 2, 3, 4];
print(len(a));
// the formatter's own output reads back: {420:o} is 644
print(f"{0o644:o}");
print(f"{0o755:#o}");
