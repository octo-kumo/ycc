// to_int stops the program on the three inputs that have no answer: a NaN, an
// infinity, and a magnitude past the largest long. The machine cast cannot
// report them -- cvttsd2si answers all three with the "integer indefinite"
// value, which is a perfectly ordinary long and would sail on as one -- so the
// Y layer checks and traps (src/y/arch/math.s's y_int_trap).
import math;

let which = 1;
print("before");

if (which == 1) {
    print(math.to_int(1.0 / 0.0));           // +inf
} else if (which == 2) {
    print(math.to_int(0.0 / 0.0));           // NaN
} else {
    print(math.to_int(1.0e300));             // far past 2^63
};