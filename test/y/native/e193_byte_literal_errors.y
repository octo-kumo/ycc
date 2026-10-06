// The byte literal's three ways to be wrong, and the spelling that is gone.
// A `b` suffix makes the literal a byte -- a value in 0..255 -- so a value
// past that, a float, and a hex literal (where `b` is a DIGIT, so `0x1Fb` is
// the hex number 507) each have something to say. `c'a'` was a character
// literal before; it is `'a'` now.
let a = 256b;   // expect-error: 6:9: error: byte literal '256b' does not fit in a byte
let b = 3.14b;  // expect-error: 7:9: error: byte literal '3.14b' is a float; a byte is a whole number
let c = 1e3b;   // expect-error: 8:9: error: byte literal '1e3b' is a float; a byte is a whole number
let d = c'a';   // expect-error: 9:9: error: a character literal is written 'a'; the c'a' form is gone
