// sin/cos/tan's argument reduction, and the limit of it.
//
// The reduction is n = round(x*2/pi) in ONE double. The subtraction of n*(pi/2)
// that follows is compensated in double-double and is exact for any n a long
// holds; the QUOTIENT is not. That product wants about 106 bits and rounds --
// harmlessly while the rounding cannot carry it across the half-integer
// boundary, and not harmlessly afterwards.
//
// Measured against this platform's libm, over 3000 arguments per decade:
//
//     |x| <= 1e8     sin and cos within 1 ulp of every one of 3000
//     |x| <= 1e10    three of 3000 are not
//     |x| <= 1e12    four are not
//     |x| <= 1e14    eleven are not, the worst 8 ulp
//     x = 1e16       33 ulp
//     x = 1e18       the quadrant is wrong by one and the answer is unrelated:
//                    this module answers -3.7e18 where the truth is -0.993
//     x >= 1e100     inf, before the guard was added
//
// There is NO sharp edge, and that is the finding rather than a missing one.
// Whether the rounded quotient is right depends on how near x*2/pi happens to
// fall to a half-integer, which is a property of that x and not a bound on it:
// sin(1e15) is exact and sin(1e16) is 33 ulp out. So no constant can be the
// accuracy limit, and an earlier version of this file claimed that
// 2^53*(pi/2) = 1.41e16 was one. It was wrong by a factor of a thousand, and
// asserting a limit like that is worse than admitting there is none.
//
// What IS a boundary is where the reduction cannot be performed at all: the
// quadrant stops fitting a long at 9.9999999999995904e18, and sin, cos and tan
// answer NaN from there. All three agree on it, and they ask the question on
// the expression to_int is handed rather than against a constant, so the guard
// cannot be out by a double. (The constant one would guess is
// 2^63*(pi/2) = 1.4488038916154245e19, but the reduction computes
// floor(x*2/pi + 0.5) and the +0.5 moves the edge a third of the way sooner --
// which is exactly why a named constant was tried first, and was wrong.)
//
// Closing the accuracy gap needs libm's multi-precision reduction, a three-word
// quotient, which is a piece of work in its own right and not a patch. Until
// then this is the promise: within 1 ulp while the quotient is exact,
// degrading gradually above that, NaN past the constant.
//
// The answers below are RECORDED rather than trusted, so that changing any of
// this is a diff and not a silence. They are bit patterns because inf, NaN and
// 1.1169973830808557e+308 have to be distinguishable at a glance, and the NaN
// region is the point of the file: tan(1e30) used to KILL THE PROGRAM, because
// to_int traps rather than returning a wrong number.

import math;

let xs: [float] = [1.0e15, 1.0e16, 1.0e17, 1.0e18, 1.0e19, 2.0e19, 1.0e20,
                   1.0e100, 1.0e300];

let i = 0;
while (i < len(xs)) {
    print("sin ", math.fbits(math.sin(xs[i])), " at index ", i);
    print("cos ", math.fbits(math.cos(xs[i])), " at index ", i);
    i = i + 1
}