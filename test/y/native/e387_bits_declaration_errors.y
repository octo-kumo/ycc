// expect-error: 6:23: error: duplicate bit 'x'
// expect-error: 6:25: error: expected an expression, got '}'
// expect-error: 7:25: error: a bit width from 1 to 64
// expect-error: 8:27: error: a bit width from 1 to 64
// Bitmaps: a name twice, and a width that is zero or past 64.
type A = bits u8 { x, x };
type B = bits u8 { y: 0 };
type C = bits u64 { z: 65 };
