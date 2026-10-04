// A float literal whose magnitude is far past anything a double can hold. The
// conversion used to build the value by emitting a multiply or a divide per
// factor of ten, so 1e10000000 asked for ten million of them: a 19-byte source
// reached 402 MB of compiler and a 1 MB binary, and past some exponent the
// compiler ran out of memory instead of finishing.
//
// A literal merely past the range is not an error -- 1e400 and 1e40000 are
// inf, as IEEE says (t171) -- so the checker rejects only what is plainly
// nobody's magnitude. What it compares is the NET power of ten, the explicit
// exponent minus the digits after the dot, not the exponent as written: the
// three below all write 1e100001, 1e100001 and 1e1000002.
// expect-error: 13:9: error: float literal magnitude out of range (a double holds 10^-308 to 10^308)
let a = 1e10000000;
// expect-error: 15:9: error: float literal magnitude out of range (a double holds 10^-308 to 10^308)
let b = 1e-10000000;
// expect-error: 17:9: error: float literal magnitude out of range (a double holds 10^-308 to 10^308)
let c = 0.5e1000001;
let d = 1.0000000000000000000000001e1000000;
// expect-error: 20:11: error: float literal magnitude out of range (a double holds 10^-308 to 10^308)
let big = 1e100001;
// expect-error: 22:13: error: float literal magnitude out of range (a double holds 10^-308 to 10^308)
let small = 1e-100001;
// expect-error: 24:12: error: float literal magnitude out of range (a double holds 10^-308 to 10^308)
let frac = 1.5e999999999999;
// expect-error: 26:12: error: float literal magnitude out of range (a double holds 10^-308 to 10^308)
let neg = -1e10000000;
// expect-error: 28:16: error: float literal magnitude out of range (a double holds 10^-308 to 10^308)
let two_five = 2.5e100002;
print(a, b, c, d, big, small, frac, neg, two_five);