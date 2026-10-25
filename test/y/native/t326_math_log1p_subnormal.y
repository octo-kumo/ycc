// log1p of the smallest subnormal answered 0.0 where the answer is 5e-324.
//
// The identity log1p uses is z = x/(2 + x), ln(1+x) = z(2 + w*P(w)) with
// w = z^2. That is a HALVING for small x, and halving the smallest subnormal
// leaves the 2^-1074 grid entirely: 5e-324 / 2.0 rounds to zero (a tie to even on
// the smallest subnormal), so z was 0 and the answer was 0. glibc gives 5e-324.
//
// It is ONE value, not a range, and that is what makes it worth recording: every
// other subnormal survives, because 2^-1073 halved is 2^-1074 and still on the
// grid. So the band is a single point at the bottom of the subnormal range --
// which is why the ulp table, whose log1p cases are ordinary arguments, never
// saw it, and why a sweep is what found it.
//
// The fix is the arm log(1+x) = x rounded exactly, which holds for |x| < 2^-52:
// the series' first correction is x^2/2 and that is below half an ulp of x for
// every x under 2^-52. At exactly 2^-52 the answer is NOT x, so the comparison
// is strict and 2^-52 itself goes the long way.

import math;

def bits(x: float) -> long {
    math.fbits(x)
};

print("── the value that was wrong ──");
print("log1p(5e-324)  ", bits(math.log1p(5e-324)));
print("  and x is:      ", bits(5e-324));
print("log1p(-5e-324) ", bits(math.log1p(0 - 5e-324)));
print("  and -x is:     ", bits(0 - 5e-324));
print("  (a negative subnormal is not writable as a literal, so it is the unary");
print("   minus of the positive one; -0.0 times it would be -0.0 and not this)");

print("");
print("── the neighbours, which were already right and must stay right ──");
print("log1p(1e-323)  ", bits(math.log1p(1e-323)), "   2^-1073");
print("log1p(1e-322)  ", bits(math.log1p(1e-322)), "   2^-1072");
print("log1p(1e-320)  ", bits(math.log1p(1e-320)), "   = x");
print("log1p(1e-310)  ", bits(math.log1p(1e-310)), "   = x");
print("log1p(1e-100)  ", bits(math.log1p(1e-100)), "   = x");
print("log1p(1e-60)   ", bits(math.log1p(1e-60)), "   = x");
print("log1p(1e-40)   ", bits(math.log1p(1e-40)), "   = x");

print("");
print("── the boundary of the new arm, which is 2^-52 ──");
// The series' first correction is x^2/2, and the doubles in [2^-52, 2^-51) are
// 2^-104 apart -- so x^2/2 at x = 2^-52 is 2^-105, exactly HALF an ulp. That is
// where the arm stops: below it the correction is under half an ulp and the
// answer is x, at it the correction is exactly half and the rounding is a tie.
//
// The tie happens to go to x anyway, so the arm could have been inclusive and
// nothing would have changed for 2^-52. It is left exclusive because "the answer
// is the argument" and "the answer is the argument because a tie resolved in its
// favour" are different claims, and only the first is worth making.
let half = math.ldexp(1.0, 0 - 52);
print("log1p(2^-52)   ", bits(math.log1p(half)));
print("  and 2^-52 is:  ", bits(half));
print("  the tie goes to the argument, which is why this line agrees either way: ",
    math.log1p(half) == half);
print("log1p(2^-53)   ", bits(math.log1p(math.ldexp(1.0, 0 - 53))));
print("  and 2^-53 is:  ", bits(math.ldexp(1.0, 0 - 53)));
print("  so here it is:  ", math.log1p(math.ldexp(1.0, 0 - 53)) == math.ldexp(1.0, 0 - 53));
print("log1p(-2^-53)  ", bits(math.log1p(0 - math.ldexp(1.0, 0 - 53))));
print("  and it is the negative of it: ",
    math.log1p(0 - math.ldexp(1.0, 0 - 53)) == 0 - math.ldexp(1.0, 0 - 53));

print("");
print("── the signed zeros, which the arm must not flatten ──");
print("log1p(+0.0) is +0.0: ", bits(math.log1p(0.0)) == 0);
print("log1p(-0.0) is -0.0: ", bits(math.log1p(0.0 * (0.0 - 1.0))) == bits(0.0 * (0.0 - 1.0)));
print("expm1(-0.0) is -0.0: ", bits(math.expm1(0.0 * (0.0 - 1.0))) == bits(0.0 * (0.0 - 1.0)));

print("");
print("── the rest of the function, unchanged ──");
print("log1p(-1.0) is -inf  ", math.log1p(0 - 1.0) == 0.0 - math.inf);
print("log1p(-2.0) is NaN   ", math.log1p(0 - 2.0) != math.log1p(0 - 2.0));
print("log1p(-0.75)        ", bits(math.log1p(0 - 0.75)), "   ln(0.25) = -1.3862943611198906");
print("  and -2*ln(2):      ", bits(0.0 - 2.0 * math.ln2));
print("log1p(-0.5)         ", bits(math.log1p(0 - 0.5)), "   ln(0.5)");
print("log1p(0.0)          ", bits(math.log1p(0.0)));
print("log1p(1.0) is ln(2) ", bits(math.log1p(1.0)) == bits(math.ln2));
print("log1p(2.0) is ln(3)  ", bits(math.log1p(2.0)), "   ", bits(math.log(3.0)));
print("log1p(-1.5) is ln(-0.5)? no, NaN ", math.log1p(0 - 1.5) != math.log1p(0 - 1.5));
print("log1p(1e10)         ", bits(math.log1p(1e10)), "   ln(1e10 + 1)");
print("log1p(-1e10)        ", bits(math.log1p(0 - 1e10)), "   ln(1 - 1e10)");
print("log1p(inf) is inf   ", math.log1p(math.inf) == math.inf);
