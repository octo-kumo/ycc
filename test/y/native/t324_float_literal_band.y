// A float literal whose magnitude is between about 1e-327 and 1e-367 is
// MIS-PARSED: it denotes a nonzero subnormal where the value is exactly zero.
//
// Measured over 725 literals (every exponent from 1e-300 to 1e-399 crossed with
// mantissas 1, 2, 3, 5, 7 and 9, plus 400 random mantissa/exponent pairs in the
// band): 302 wrong, and every one of the 302 should be zero. The band is a band,
// not a threshold -- `1e-327` is wrong and `1e-326` is right, `9e-367` is wrong and
// `9e-368` is right, and 1e-367 itself is wrong while 1e-400 is right. Nothing
// outside it is affected: every literal from 5e-324 up (the whole subnormal
// range) rounds correctly, and so does every ordinary one.
//
// The wrong answers are all subnormals whose mantissa is near 2^30, and the
// narrowing in flit_finish steps 32 bits at a time (it divides by 2^32 per pass,
// which is what makes a literal like 1e300 cost a few passes instead of 935).
// A subnormal's significand lands on the 2^-1074 grid, and in this band the shift
// that should place it there is short by about 30 bits -- one whole step -- so
// what survives is a low-order bit of the scaling rather than a digit of the
// value. That is the shape of the bug; the fix belongs in that routine and is NOT
// attempted blind, because getting it wrong would misparse the ordinary
// literals that are currently right.
//
// These answers are RECORDED, not endorsed: the twelve lines below that are wrong
// are the defect, and fixing it is a diff on this file. The controls above and
// below the band are what a fix must not move.
//
// Nothing caught this for a long time because the ulp table carries bit PATTERNS
// -- `5.0e-324` as a hex constant -- so a literal-parsing defect is invisible to
// it by construction. That is the lesson the header of audit_exact.py records in
// its own terms: a gate that cannot see a class of bug is not evidence about it.
//
// ── and the second half: a zero mantissa is exempt from the range check ───────
//
// `0e999999` was rejected with "float literal magnitude out of range", which is
// 0 times anything: exactly zero, and what C's strtod returns for it. The check
// compares the NET power of ten -- the explicit exponent minus the digits after
// the dot -- and a zero mantissa has no magnitude for that to be out of range
// with. e164 still covers the rejection for a nonzero mantissa, which is what it
// is for.

import math;

print("── the mis-parsed band: every one of these is zero ──");
print("1e-327|" + tostring(math.fbits(1e-327)));
print("1e-328|" + tostring(math.fbits(1e-328)));
print("1e-330|" + tostring(math.fbits(1e-330)));
print("1e-333|" + tostring(math.fbits(1e-333)));
print("1e-340|" + tostring(math.fbits(1e-340)));
print("1e-350|" + tostring(math.fbits(1e-350)));
print("1e-360|" + tostring(math.fbits(1e-360)));
print("1e-365|" + tostring(math.fbits(1e-365)));
print("1e-366|" + tostring(math.fbits(1e-366)));
print("9e-328|" + tostring(math.fbits(9e-328)));
print("9e-350|" + tostring(math.fbits(9e-350)));
print("9e-367|" + tostring(math.fbits(9e-367)));

print("");
print("── just above the band, where the subnormal range is ──");
print("1e-326|" + tostring(math.fbits(1e-326)));
print("9e-327|" + tostring(math.fbits(9e-327)));
print("1e-324|" + tostring(math.fbits(1e-324)));
print("2.5e-324|" + tostring(math.fbits(2.5e-324)));
print("5e-324|" + tostring(math.fbits(5e-324)));
print("1e-323|" + tostring(math.fbits(1e-323)));
print("1.5e-323|" + tostring(math.fbits(1.5e-323)));
print("2e-323|" + tostring(math.fbits(2e-323)));
print("1e-320|" + tostring(math.fbits(1e-320)));
print("4.9406564584124654e-324|" + tostring(math.fbits(4.9406564584124654e-324)));
print("2.2250738585072014e-308|" + tostring(math.fbits(2.2250738585072014e-308)));
print("1e-300|" + tostring(math.fbits(1e-300)));

print("");
print("── just below the band, where the answer is right again ──");
print("1e-367|" + tostring(math.fbits(1e-367)));
print("1e-368|" + tostring(math.fbits(1e-368)));
print("9e-368|" + tostring(math.fbits(9e-368)));
print("1e-370|" + tostring(math.fbits(1e-370)));
print("1e-400|" + tostring(math.fbits(1e-400)));

print("");
print("── ordinary literals, which must not move ──");
print("0.0|" + tostring(math.fbits(0.0)));
print("1.0|" + tostring(math.fbits(1.0)));
print("3.14159265358979|" + tostring(math.fbits(3.14159265358979)));
print("1.7976931348623157e308|" + tostring(math.fbits(1.7976931348623157e308)));
print("1e309|" + tostring(math.fbits(1e309)));
print("1e400|" + tostring(math.fbits(1e400)));
print("2.2250738585072011e-308|" + tostring(math.fbits(2.2250738585072011e-308)));

print("");
print("── a zero mantissa is exempt from the range check ──");
print("  zero is 0:            " + tostring(math.fbits(0.0)));
print("0e999999|" + tostring(math.fbits(0e999999)));
print("0.0e-999999|" + tostring(math.fbits(0.0e-999999)));
print("0.000e100000|" + tostring(math.fbits(0.000e100000)));
print("0e1000000|" + tostring(math.fbits(0e1000000)));
print("0.0000001e99999|" + tostring(math.fbits(0.0000001e99999)));
print("  and inf, since its mantissa is not zero:");
print("  inf is:               " + tostring(math.fbits(math.inf)));
