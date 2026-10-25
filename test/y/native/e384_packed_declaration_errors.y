// expect-error: 6:26: error: duplicate field 'n' in a packed record
// expect-error: 6:33: error: expected an expression, got '}'
// expect-error: 7:26: error: the bits overflow the 8-bit backing integer
// expect-error: 7:31: error: expected an expression, got '}'
// Packed and bits declarations: a duplicate field, bits that overflow the backing integer.
type B = packed { n: u8, n: u16 };
type D = bits u8 { a: 5, b: 5 };
