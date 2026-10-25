// Two overflow defects, both found by sweeping the bulk kernels against exact
// rational arithmetic, and both of the same shape: the SIZE of something
// intermediate overflowed while the answer itself did not.

// ── fvariance([1e308, 1e308]) answered inf where the answer is 0 ──────────────
//
// The two-pass method takes the mean first, and the mean of two equal 1e308
// values is inf. Every deviation was then inf - inf, so the sum of squares was
// inf and the answer inf -- for an array whose spread is exactly zero, and whose
// variance is zero however large the numbers are. That is the SIZE of the mean
// overflowing, not the spread, and a method that cannot see it is measuring the
// wrong thing.
//
// The fix scales by a power of two chosen from the largest magnitude present,
// so the mean is a number near 1 and cannot overflow, and multiplies the result
// back by the square. Scaling by a power of two is exact, cannot change a
// comparison or a subtraction's sign, and cannot push a normal number into the
// subnormals.
//
// Note that [1e308, -1e308] is still inf, and must be: that variance is 4e616,
// which has no double. The fix moves the boundary to where it belongs rather than
// pushing it away.
//
// ── ldexp(x, 1024) answered a NaN where the answer is an infinity ─────────────
//
// After ldexp's big steps the answer can already be out of range, and the
// exponent-field shift that follows then ADDS k to a field that is already 2047.
// That overflows the signed long, wraps, and comes back as a NaN with the sign
// bit set. Two separate places needed it:
//
//   ldexp(1.0, 2046)   the big step itself overflows r to +inf
//   ldexp(2.47, 1024)  r stays finite at 1.11e308 and the field reaches 2047
//
// Both now answer an infinity carrying x's sign, and the underflow end (r
// reaching 0) is checked for the same reason.
//
// The answers are RECORDED bit patterns, so changing any of this is a diff.
// Recorded rather than trusted is the point: ldexp's overflow was invisible to a
// gate built on frexp's identity, because frexp only ever calls ldexp with an
// exponent that brings a normal answer back into range.

import math;

def bits(x: float) -> long {
    math.fbits(x)
};

// ── fvariance: the scaling ───────────────────────────────────────────────────
print("variance([1e308, 1e308])      ", bits(math.fvariance([1e308, 1e308])));
print("  and the answer is zero:      ", bits(0.0));
print("variance([1e300, 1e300])      ", bits(math.fvariance([1e300, 1e300])));
print("variance([1e16, 1e16])        ", bits(math.fvariance([1e16, 1e16])));
print("variance([1e-300, 2e-300])    ", bits(math.fvariance([1e-300, 2e-300])));
print("variance([5e-324, 5e-324])    ", bits(math.fvariance([5e-324, 5e-324])));
print("variance([0, 0, 0])           ", bits(math.fvariance([0.0, 0.0, 0.0])));

// where the boundary belongs: a spread that genuinely overflows stays inf
print("variance([1e308, -1e308])     ", bits(math.fvariance([1e308, 0 - 1e308])));
print("  and +inf is:                 ", bits(math.inf));
print("variance([DBL_MAX, DBL_MAX])  ", bits(math.fvariance([1.7976931348623157e308, 1.7976931348623157e308])));

// the textbook cases, which must not have moved
print("variance([1,2,3,4])           ", bits(math.fvariance([1.0, 2.0, 3.0, 4.0])));
print("  which is 5/3:                ", bits(5.0 / 3.0));
print("variance([2,4,4,4,5,5,7,9])   ", bits(math.fvariance([2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0])));
print("  which is 32/7:               ", bits(32.0 / 7.0));

// a single element and an empty array have no variance
print("variance([1.0]) is NaN        ", math.fvariance([1.0]) != math.fvariance([1.0]));
print("variance([]) is NaN           ", math.fvariance([]) != math.fvariance([]));

// ── fsum_kahan([1e308, 1e308]) answered NaN where the answer is +inf ─────────
//
// The same shape once more, and this time inside the compensation itself. On the
// way to an infinity the Neumaier step computes (s - t) + x, which is
// (1e308 - inf) + 1e308 -- and inf - inf is a NaN, which then poisons the final
// s + c. So the ACCURATE sum returned NaN where the fast one returned +inf, and
// every array whose total leaves the range was a NaN.
//
// It is worth recording which direction that fails in: the method that exists to
// be right about rounding was the one that could not answer at all.
print("fsum_kahan([1e308, 1e308])  ", bits(math.fsum_kahan([1e308, 1e308])));
print("  and +inf is:                 ", bits(math.inf));
print("fsum([1e308, 1e308])       ", bits(math.fsum([1e308, 1e308])));
print("fsum_kahan([1e308, -1e308]) ", bits(math.fsum_kahan([1e308, 0 - 1e308])));
print("  which is 0:                  ", bits(0.0));
print("fsum_kahan([1e16, 1, -1e16])", bits(math.fsum_kahan([1e16, 1.0, 0 - 1e16])));
print("  which is 1:                  ", bits(1.0));

// ── ldexp: the two overflow shapes, and the underflow end ────────────────────
print("ldexp(1.0, 2046)              ", bits(math.ldexp(1.0, 2046)));
print("ldexp(2.47, 1024)             ", bits(math.ldexp(2.47, 1024)));
print("ldexp(1.0, 1024)              ", bits(math.ldexp(1.0, 1024)));
print("  and +inf is:                 ", bits(math.inf));
print("ldexp(-1.0, 2046)             ", bits(math.ldexp(-1.0, 2046)));
print("  and -inf is:                 ", bits(0.0 - math.inf));
print("ldexp(-2.47, 1024)            ", bits(math.ldexp(-2.47, 1024)));

// the field boundary itself: 1023 is the largest exponent that stays normal
print("ldexp(1.0, 1023)              ", bits(math.ldexp(1.0, 1023)));
print("  which is 2^1023:             ", bits(8.98846567431158e307));
print("ldexp(1.0, 1022)              ", bits(math.ldexp(1.0, 1022)));
print("  which is 2^1022:             ", bits(4.49423283715578977e307));

// the underflow end, which the same check now short-circuits
print("ldexp(1.0, -1074)             ", bits(math.ldexp(1.0, 0 - 1074)));
print("  which is the smallest:       ", bits(5e-324));
print("ldexp(1.0, -1075)             ", bits(math.ldexp(1.0, 0 - 1075)));
print("ldexp(1.0, -2000)             ", bits(math.ldexp(1.0, 0 - 2000)));
print("ldexp(DBL_MAX, 1)             ", bits(math.ldexp(1.7976931348623157e308, 1)));

// and the ordinary cases, which must not have moved
print("ldexp(3.0, 5)                 ", bits(math.ldexp(3.0, 5)));
print("  which is 96:                 ", bits(96.0));
print("ldexp(1.5, -1)                ", bits(math.ldexp(1.5, 0 - 1)));
print("  which is 0.75:               ", bits(0.75));
print("ldexp(5e-324, 60)             ", bits(math.ldexp(5e-324, 60)));
print("  which is 2^-1014:            ", bits(math.ldexp(1.0, 0 - 1014)));

// ── frexp/ldexp still round-trip, which is the gate that missed this ────────
let trip = true;
let xs: [float] = [1.0, 0.5, 1e-300, 1e300, 5e-324, 1.7976931348623157e308, 3.0];
let i = 0;
while (i < len(xs)) {
    let p = math.frexp(xs[i]);
    let back = math.ldexp(math.bitsf(p[0]), p[1]);
    if (back != xs[i]) { trip = false };
    i = i + 1
};
print("frexp/ldexp round-trip        ", trip);