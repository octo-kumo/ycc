// expect-error: 8:7: error: hex literal '0x' has no digits
// expect-error: 9:9: error: hex literal '0X_' has no digits
// expect-error: 10:9: error: binary literal '0b2' has no digits
// expect-error: 11:9: error: binary literal '0b_z_1' has no digits
// A radix prefix needs a digit of its radix after it. The bad literal
// runs to the end of the word, so `0b2` is one error, not a `0b` and a
// `2`.
print(0x);
let a = 0X_;
let b = 0b2;
let c = 0b_z_1;
