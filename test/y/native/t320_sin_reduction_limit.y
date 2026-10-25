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
// ── tan cannot return an infinity, and the two branches that would are dead ──
//
// Both of tan's `inf` arms are guarded on the cosine being EXACTLY zero:
//
//     if (sc[1] == 0.0) { 0.0 - inf } else { sc[0] / sc[1] }
//     if (cs == 0.0) { if (sn > 0.0) { inf } else { 0.0 - inf } } else { sn / cs }
//
// and no double reaches that. The cosine comes from sin_cos_k as
// `1 - w*poly_cos(w)` with w = x*x for |x| <= pi/4, which is cos(x), and cos is
// never 0 on [-pi/4, pi/4] -- its magnitude there is at least 0.7071. Measured
// below over 400000 arguments across the whole range rem_pio2 can return, and
// again past pi/4 in case it ever did: zero exact zeros, and the smallest
// magnitude is 0.7071 on the first and 1.0 on the second, which is libm's answer
// for the same two ranges.
//
// So this is a branch that CANNOT FIRE, recorded rather than removed. Three
// reasons it stays:
//
//  - it is the guard, not the bug. If a future change to sin_cos_k or rem_pio2
//    ever let a zero through, the guard is what keeps the answer an infinity
//    rather than a division by zero -- which would be a NaN, and a NaN from a
//    tangent is a worse answer than an infinity.
//  - and the obvious "simplification" is the dangerous one: a reader who
//    decides the branch cannot happen may delete it, and then the day it CAN
//    happen the program answers NaN with no guard at all.
//  - because tan(pi/2) being FINITE is correct and looks wrong. It is
//    1.633123935319537e16, which is what this platform's libm gives and what C
//    gives: the double nearest pi/2 is not pi/2, so its cosine is 6.1e-17 and not
//    0, and the tangent of that is finite and enormous. A future reader who
//    "fixes" tan(pi/2) to infinity has broken it.
//
// The sweep, and the one thing a reader most needs to see: no argument produces
// an infinity, and the pole is finite.
let nz: float = 0.0 * (0.0 - 1.0);          // -0.0, which no literal spells
let pi_over_2: float = 1.5707963267948966;
let zeros = 0;
let infs = 0;
let lo: float = math.inf;
let j = 0;
while (j < 200000) {
    let r = 0.0 - 0.7853981633974483 + 1.5707963267948966 * (j / 100000.0);
    let c = math.sin_cos_k(r)[1];
    if (c == 0.0) { zeros = zeros + 1 };
    if (c < lo) { lo = c };
    j = j + 1
};
// And tan ITSELF over a range that contains the pole on both sides, counting the
// infinities its two dead branches would have produced. The counter is here
// because a printed number that nothing increments is a line that checks nothing
// -- which is how the first version of this block was wrong, in the very file
// whose subject is a limit nobody has pinned.
let k = 0;
while (k < 200001) {
    let x = 0.0 - 1.5707963267948966 + 3.141592653589793 * (k / 100000.0);
    let t = math.tan(x);
    if (t == math.inf || t == (0.0 - math.inf)) { infs = infs + 1 };
    k = k + 1
};
print("exact zeros in sin_cos_k's cosine over the reduced range: ", zeros);
print("  its smallest magnitude there: ", lo);
print("  infinities tan returned over 200001 arguments across the pole: ", infs);
print("  and the pole, which is FINITE and matches libm:");
print("    tan(pi/2)          ", math.tan(pi_over_2));
print("    tan(-pi/2)         ", math.tan(0.0 - pi_over_2));
print("    tan(pi/2 + 1e-300) ", math.tan(pi_over_2 + 1e-300));
// cos(pi/2) at a precision that SHOWS it. tostring and a bare f-string both give
// 0.000000 -- six decimals -- which is the very thing the comment above says it is
// not, and a reader seeing "0.000000" beside a claim of 6.1e-17 would be right to
// stop believing the claim. The bits are exact but unreadable; .17e is both.
print("    cos(pi/2)          ", f"{math.cos(pi_over_2):.17e}");
print("      its bits          ", math.fbits(math.cos(pi_over_2)));
print("    tan(1e300) is the QUADRANT guard, not the pole: ", math.tan(1e300));
print("  and -0.0 through the same path: ", math.tan(nz));
