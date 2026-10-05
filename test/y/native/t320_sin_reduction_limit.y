// sin/cos/tan where the argument reduction stops being trustworthy.
//
// Known and documented, not fixed: these are pinned so the limit is VISIBLE
// rather than silent, and so that raising the limit is a diff here.
//
// The reduction is n = round(x * 2/pi) in one double, then x - n*(pi/2) with the
// product compensated in double-double (rem_pio2, which is correct). The
// compensation handles n exactly; what is not exact is n ITSELF. The quotient
// is computed as floor(x*two_over_pi + 0.5) in one double, and that product
// needs about 106 bits, so it rounds -- harmlessly while the rounding cannot
// carry the quotient across the 0.5 boundary, which is to say while the
// quotient is small, and then not harmlessly at all. The same limit is stated
// in docs/src/09-builtins.tex, so the two cannot drift apart unnoticed.
//
// The measured behaviour, against this platform's libm (the second column is
// the gap in ulp):
//
//   x = 1e15   exact
//   x = 1e16   33 ulp
//   x = 1e17   2.4e10 ulp
//   x = 1e18   wrong by an unbounded amount, and the sign of the quotient's
//              error shows: a reduction off by one whole quadrant
//   x >= 1e100 inf, because floor(x*2/pi) has left the range of a long
//
// The cutoff is not a neat power of two and cannot be made one: whether the
// rounded quotient is right depends on how close x*2/pi happens to fall to a
// half-integer, which is a property of x and not a bound on it. fdlibm handles
// the whole range with a multi-precision reduction (__ieee754_rem_pio2's
// do_pi2 stages, a three-word quotient), and that is what would be needed
// here. Until then the promise is: |x| <= 2^53 * (pi/2) = 1.41e16, and the
// answers past it are the ones printed below, which are not to be relied on.
//
// This is why the numbers below are recorded as bit patterns rather than
// compared against libm: a test that asserted libm's answers would fail, and a
// test that asserted these would be claiming they are right. What it claims is
// only that they do not change silently.
import math;

let xs: [float] = [1.0e15, 1.0e16, 1.0e17, 1.0e18, 1.0e19, 2.0e19, 1.0e20,
                   1.0e100, 1.0e300];

let i = 0;
while (i < len(xs)) {
    print("sin ", math.fbits(math.sin(xs[i])), " at index ", i);
    print("cos ", math.fbits(math.cos(xs[i])), " at index ", i);
    i = i + 1
}