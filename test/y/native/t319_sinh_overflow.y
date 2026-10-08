// sinh and cosh where their own exponential has already overflowed.
//
// Both are (e^x -+ e^-x)/2, so past x = 709.78 -- where e^x is inf -- the
// obvious form answers inf for arguments whose answer is a perfectly good
// double: cosh(710) is 1.1169973830808557e+308, sinh(-710) its negation. The
// halving in the definition buys back a full exponent, so the real edge is a
// whole ln2 further out.
//
// This walks the strip rather than the single value that broke it, and both
// signs, because sinh is odd and cosh is even: a fault carried by the sign
// would not show on the positive half. -0.0 is here for the same reason -- it
// is the one argument whose sign the odd function must lose.
//
// The expectations are bit patterns, and this file is a BYTE-EQUALITY gate, so
// note what it does and does not claim. It pins the strip against drift: any
// change to these 58 answers, in either direction, is a diff here. It does NOT
// certify them against libm, because a byte gate cannot hold a function whose
// promise is 1 ulp -- 36 of the 58 are bit-identical to libm and 22 are one
// ulp away, which is within the promise and fatal to a diff.
//
// That certification is src/tools/ytest/su_math.y's job, with the tolerance it
// enforces: test/math/ulp_table.txt carries sinh and cosh at 709.78, 709.9,
// 710.0, 710.4, 710.47, 710.4758 and the edge, against libm, failing above
// 1 ulp. The two gates together are why this file can hold its own output
// honestly: the table says the answers are RIGHT, and this says they do not
// MOVE.
//
// Bit patterns rather than decimals for the same reason as above: inf at 710.4
// and 1.1169973830808557e+308 have to be distinguishable at a glance.
import math;

let xs: [float] = [-710.6, -710.47586007394398, -710.47586007394386,
                   -710.4758, -710.4, -710.0, -709.9, -709.78, -709.0,
                   -100.0, -1.0, -0.5, -0.0, 0.0, 0.5, 1.0, 100.0, 709.0,
                   709.78, 709.9, 710.0, 710.4, 710.47, 710.4758,
                   710.47586007394386, 710.47586007394398, 710.6, 711.0,
                   1000.0];

// The two boundaries worth naming, since both were got wrong first:
//
//   710.47586007394386  the largest argument with an answer. It has one
//                       because the answer has to survive being ROUNDED: the
//                       exact e^x/2 is one ulp under DBL_MAX there, so the
//                       rounded value is a double and not an infinity. A
//                       guard placed at ln(2*DBL_MAX) refuses this argument
//                       and is wrong by exactly one double.
//   710.47586007394398  the first argument with no answer at all.
//
// math.fbits is the point of the exercise: an answer of inf and an answer of
// 1.1169973830808557e+308 have to be told apart, and only the bits can.

let i = 0;
while (i < len(xs)) {
    print("sinh ", math.fbits(math.sinh(xs[i])), " at index ", i);
    print("cosh ", math.fbits(math.cosh(xs[i])), " at index ", i);
    i = i + 1
}