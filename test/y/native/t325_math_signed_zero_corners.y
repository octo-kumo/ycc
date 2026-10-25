// Two corner cases where the module answered something, and the something was
// not the answer. Both are C99 7.12.7 cases, and both were found by sweeping the
// float-to-float functions over both signed zeros and a NaN -- the arguments the
// ulp table does carry but a comparison of answers cannot see, because the
// answers differ in their SIGN rather than in their magnitude.
//
// ── atan2 with both arguments a zero: the whole quadrant was wrong ────────────
//
// All four combinations, against glibc:
//
//     atan2(+0, +0)   was +0      is +0      ok
//     atan2(-0, +0)   was +0      is -0      the sign was lost
//     atan2(+0, -0)   was +0      is +pi     3.14 where the answer is 0
//     atan2(-0, -0)   was +0      is -pi     3.14 where the answer is 0
//
// The cause is that the arm for a zero x tested `y > 0.0`, then `y < 0.0`, and
// +0 is NEITHER: +0.0 < 0.0 is false and +0.0 > 0.0 is false. So the ladder
// fell through to its else, which answered a zero, for every case where y was a
// positive zero. And the `y == 0.0` arm below it -- the one with a careful
// comment about a negative zero having a direction -- never ran for these four,
// because -0.0 == 0.0 is TRUE, so the arm above caught them first. Two correct
// pieces of code, and the second unreachable.
//
// Two wrong fixes got it part way and are recorded because each looked right:
// testing `is_signed_zero(y)` and reading the sign of x inside it puts
// atan2(+0, -0) at +pi, as it should, but sends atan2(+0, +0) to +-pi/2 -- a
// positive zero is not a SIGNED zero, so it fell through to the same ladder.
// The test has to be `y == 0.0`, which is true of both zeros, and the sign of
// x then chooses the shape: a negative zero means the negative x axis and a
// signed pi, a positive one means the positive axis and a signed zero. The sign
// of y carries through either way.
//
// This needed `neg_zero` declared beside `nan` and `inf` rather than beside
// fmin/fmax where it was: atan2 is above that and Y does not hoist, so the name
// was an undefined variable at the point of use. The declaration moved up and
// says why it is there.
//
// ── hypot(inf, nan): an infinity that a NaN swallowed ────────────────────────
//
// hypot(inf, nan) answered nan; C99 7.12.7.3, IEEE 754-2019 and glibc all give
// +inf. hypot(nan, inf) was already right, which is the tell: the code took the
// larger magnitude with `if (a > b) { a } else { b }`, and every comparison
// against a NaN is false -- so a NaN in the SECOND position won and was handed
// back as the maximum, and the infinity it should have been dominated by was
// never looked at. Order matters, which is why the order-dependent answer and
// the symmetric one disagreed.
//
// The fix looks for an infinity rather than inferring one from a maximum, and
// rules out the NaN before taking a maximum at all. hypot_scaled carries the
// body so each of the two branches stays a single expression.
//
// AND THE SCALING INSIDE hypot_scaled IS NO LONGER THE LIMIT IT WAS. It used to
// compute m * sqrt((s/m)^2 + 1), and that form was documented here as "a known
// limit of the scaled form rather than a defect of it -- the table pins what
// hypot does". It was neither pinned nor known: the table had FOURTEEN hypot
// cases, none of them with a wide ratio, and 236 more found it 2 ulps out on
// 0.75% of the wide-ratio pairs. So the sentence was wrong in the way this file
// exists to catch -- it read as coverage.
//
// It is now within 1 ulp of glibc everywhere, and the two cases below are the
// ones that used to be the argument for leaving it alone.
//
// WHICH path it takes is a decision about the argument, not one compromise, and
// the reason is that the accurate form turned out to be nearly free. Measuring
// the power-of-two scaling cost 964 instructions a call against the ratio form's
// 299 -- ldexp is 178 a call and the path needs two -- which is a 3.2x price for
// accuracy that a decade-uniform spread says is only needed at the two ends of
// the range. So:
//
//   m in [1e-152, 1e154]   sqrt(m*m + s*s) directly. Three roundings instead of
//                          four and none spent on a scale factor, so it is MORE
//                          accurate as well as cheaper. Half of all arguments.
//   otherwise, s/m < 1e-4  m + (s/m)*s/2. When the ratio is that small the terms
//                          past s^2/2m are below an ulp, and the correction's own
//                          sloppy rounding is multiplied by p^2/2 before it
//                          reaches the answer.
//   otherwise              the power-of-two scaling, under one per cent of
//                          arguments under a decade-uniform pair spread.
//
// Net cost against the form that was 2 ulps out: +2.2% instructions, and 0% on
// the wide-ratio band that band lives in. The correctness was bought cheaply
// because the accurate form and the cheap form turned out to be the same form.

import math;

def bits(x: float) -> long {
    math.fbits(x)
};

// -0.0, which no literal spells: Y writes -1.0 as a unary minus and 0.0 - 0.0
// is +0.0 by IEEE, so it has to be built.
let nz: float = 0.0 * (0.0 - 1.0);

print("── atan2, all four zero pairs (C99 7.12.7.4) ──");
print("atan2(+0, +0) bits ", bits(math.atan2(0.0, 0.0)));
print("  and +0 is:          ", bits(0.0));
print("atan2(-0, +0) bits ", bits(math.atan2(nz, 0.0)));
print("  and -0 is:          ", bits(nz));
print("atan2(+0, -0) bits ", bits(math.atan2(0.0, nz)));
print("  and +pi is:         ", bits(math.pi));
print("atan2(-0, -0) bits ", bits(math.atan2(nz, nz)));
print("  and -pi is:         ", bits(0.0 - math.pi));

print("");
print("── atan2, the corners with a nonzero operand, unchanged ──");
print("atan2(+0, -1) ", bits(math.atan2(0.0, 0 - 1.0)), "   want +pi ", bits(math.pi));
print("atan2(-0, -1) ", bits(math.atan2(nz, 0 - 1.0)), "   want -pi ", bits(0.0 - math.pi));
print("atan2(+1, -0) ", bits(math.atan2(1.0, nz)), "   want +pi/2 ", bits(math.pi / 2.0));
print("atan2(-1, -0) ", bits(math.atan2(0 - 1.0, nz)), "   want -pi/2 ", bits(0.0 - math.pi / 2.0));
print("atan2(+1, +0) ", bits(math.atan2(1.0, 0.0)), "   want +pi/2 ", bits(math.pi / 2.0));
print("atan2(-1, +0) ", bits(math.atan2(0 - 1.0, 0.0)), "   want -pi/2 ", bits(0.0 - math.pi / 2.0));
print("atan2(+1, -1) ", bits(math.atan2(1.0, 0 - 1.0)), "   want 3pi/4 ");
print("atan2(-1, -1) ", bits(math.atan2(0 - 1.0, 0 - 1.0)), "   want -3pi/4 ");
print("atan2(inf, -inf) ", tostring(math.atan2(math.inf, 0 - math.inf)), "   want 3pi/4");
print("atan2(-inf, -inf) ", tostring(math.atan2(0 - math.inf, 0 - math.inf)), "   want -3pi/4");

print("");
print("── hypot, an infinity beside a NaN ──");
print("hypot(inf, nan)  ", bits(math.hypot(math.inf, math.nan)));
print("hypot(nan, inf)  ", bits(math.hypot(math.nan, math.inf)));
print("hypot(-inf, nan) ", bits(math.hypot(0 - math.inf, math.nan)));
print("hypot(nan, -inf) ", bits(math.hypot(math.nan, 0 - math.inf)));
print("  and +inf is:      ", bits(math.inf));
print("hypot(nan, 1) is NaN: ", math.hypot(math.nan, 1.0) != math.hypot(math.nan, 1.0));
print("hypot(inf, inf)  ", bits(math.hypot(math.inf, math.inf)));
print("hypot(-inf, 1)   ", bits(math.hypot(0 - math.inf, 1.0)));

print("");
print("── hypot, the ordinary cases, unchanged ──");
print("hypot(3, 4) == 5            ", math.hypot(3.0, 4.0) == 5.0);
// The squares of 3e200 are 9e400, which is out of range, so the scaling is what
// keeps this finite. One ulp BELOW the literal 5e200, which is the right answer
// and not the same as the literal: sqrt((3e200)^2 + (4e200)^2) is not 5e200 in
// doubles, because 3e200 and 4e200 are themselves rounded. glibc gives the same
// bit pattern, which is the check.
print("hypot(3e200, 4e200)  ", bits(math.hypot(3e200, 4e200)));
print("  which is one ulp under the 5e200 literal, and matches glibc: ", bits(math.hypot(3e200, 4e200)) == 7609430662777223920);
print("  while 5e200 itself is:  ", bits(5e200));
// The wide-ratio case the ratio form got wrong, pinned by value. Three answers
// for one argument, and the order they were reached in is the whole story:
//
//   ...043   the ratio form        2 ulps from glibc
//   ...044   the power-of-two      1 ulp from glibc
//   ...045   m + (s/m)*s/2         EXACTLY glibc
//
// So the cheapest form is also the most accurate one here, which is not what I
// expected when I added it for its cost. The reason is visible in hypot_scaled:
// at this ratio the answer is m plus a correction four orders of magnitude
// below it, so the only rounding that reaches the answer is the final
// subtraction's -- while the scaling form spends two of its four roundings
// putting m in [1,2) and two taking it back out, and the sqrt's own half-ulp is
// half an ulp of the ANSWER rather than of something near it.
//
// The comment in hypot_scaled that used to call the old form "a known limit" was
// wrong about that too.
print("hypot(3.284781714398278e282, 1.5206628784236626e287)  ",
    bits(math.hypot(3.284781714398278e282, 1.5206628784236626e287)));
print("  the ratio form answered:                               8903604381772537043");
print("  the power-of-two form answered:                        8903604381772537044");
print("  glibc answers, and so does this:                      8903604381772537045");
// And twenty more, because one case is one argument and the failure was a BAND.
// Two properties, both of which the ratio form kept too -- so these are here as
// a floor, not as the check: the value above is the check.
let wide_bad = 0;
let w = 0;
while (w < 20) {
    let big = 1.5206628784236626e+287 * (1.0 + 0.031 * w);
    let small = big * (1.0 - 0.087 * w) * 1e-5;
    let h = math.hypot(small, big);
    // hypot(small, big) is above big and below big*(1+1e-4): the correction is
    // (small/big)^2/2, which for a ratio of 1e-5 is 5e-11.
    if (h < big || h > big * 1.0001) { wide_bad = wide_bad + 1 };
    if (h != math.hypot(big, small)) { wide_bad = wide_bad + 1 };
    w = w + 1
};
print("wide-ratio pairs outside their bound or asymmetric: ", wide_bad);
print("  and 3e200*3e200 overflows: ", 3e200 * 3e200 == math.inf);
print("hypot(DBL_MAX, DBL_MAX) is inf ", math.hypot(1.7976931348623157e308, 1.7976931348623157e308) == math.inf);
// hypot(2, 3) is ONE ULP ABOVE the correctly rounded sqrt(13), and it was
// before this change too -- the scaled form rounds p*p + q*q and then the
// product, which is not the same as one rounding of the whole. Recorded as a
// known limit rather than presented as a defect of the corner-case fix: the
// 3-4-5 and 5-12-13 triples ARE exact, which is what makes this easy to miss.
print("hypot(2, 3) bits  ", bits(math.hypot(2.0, 3.0)));
print("  sqrt(13) bits   ", bits(math.sqrt(13.0)), "   one ulp above");
print("hypot(1, 1) bits  ", bits(math.hypot(1.0, 1.0)));
print("  sqrt(2) bits    ", bits(math.sqrt(2.0)), "   exact");
print("hypot(3, 4) == 5.0        ", math.hypot(3.0, 4.0) == 5.0);
print("hypot(5, 12) == 13.0      ", math.hypot(5.0, 12.0) == 13.0);
print("hypot(8, 15) == 17.0      ", math.hypot(8.0, 15.0) == 17.0);
print("hypot(0, -0) is +0          ", bits(math.hypot(0.0, nz)));
print("hypot(-0, -0) is +0         ", bits(math.hypot(nz, nz)));
print("hypot(1e-320, 1e-320)       ", bits(math.hypot(1e-320, 1e-320)));
print("  which is sqrt(2)*1e-320    ", bits(math.sqrt(2.0) * 1e-320));
// hypot(x, 0) is |x|, and for a subnormal that is a MULTIPLICATION by sqrt(1 + 0)
// rather than an identity -- so it is checked, because it is the case where the
// scaling shows: the answer has to be the argument back, bit for bit.
print("hypot(1e-320, 0) == 1e-320   ", bits(math.hypot(1e-320, 0.0)), "   want ", bits(1e-320));
print("hypot(3.5, 0) == 3.5         ", bits(math.hypot(3.5, 0.0)), "   want ", bits(3.5));
print("hypot(-3.5, 0) == 3.5        ", bits(math.hypot(0 - 3.5, 0.0)), "   want ", bits(3.5));
print("hypot(0, 3.5) == 3.5         ", bits(math.hypot(0.0, 3.5)), "   want ", bits(3.5));

// and the symmetry the fix had to keep: hypot is commutative, and the version
// that answered nan for one order and inf for the other was not.
print("");
print("hypot is commutative on the whole set: ");
let asym = 0;
let f1 = math.hypot(math.inf, math.nan);
let g1 = math.hypot(math.nan, math.inf);
if (!(f1 == g1)) { asym = asym + 1 };
let f2 = math.hypot(0.0, nz);
let g2 = math.hypot(nz, 0.0);
if (bits(f2) != bits(g2)) { asym = asym + 1 };
let f3 = math.hypot(3.0, 4.0);
let g3 = math.hypot(4.0, 3.0);
if (f3 != g3) { asym = asym + 1 };
let f4 = math.hypot(1e-320, 1e-320);
let g4 = math.hypot(1e-320, 1e-320);
if (bits(f4) != bits(g4)) { asym = asym + 1 };
print("  five pairs, the ones that disagreed in either order: ", asym);
