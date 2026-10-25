// expect-error: 11:7: error: hex literal '0x' has no digits
// expect-error: 12:9: error: hex literal '0X_' has no digits
// expect-error: 13:9: error: binary literal '0b2' has no digits
// expect-error: 14:9: error: binary literal '0b_z_1' has no digits
// expect-error: 15:9: error: octal literal '0o8' has no digits
// expect-error: 16:9: error: octal literal '0o_' has no digits
// A radix prefix needs a digit of its radix after it. The bad literal
// runs to the end of the word, so `0b2` is one error, not a `0b` and a
// `2`. Octal joined the list when it became a literal: `0o8` is not an
// octal digit at all, and `0o_` is a separator with nothing to separate.
print(0x);
let a = 0X_;
let b = 0b2;
let c = 0b_z_1;
let d = 0o8;
let e = 0o_;
