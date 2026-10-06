// The bulk kernels' length guards: empty arrays, and the arrays too short to mean.
//
// fsum, fdot, fmin_of, fmax_of, fmean and fvariance each open with a test on
// len(a), and every one of those tests was UNGATED except the ones t310 already
// reached by passing an empty array to fdot, fmin_of and fmax_of. fsum, fmean and
// fvariance had no case at all on any of their length guards -- not the empty
// array and not, for fvariance, the single-element one.
//
// That is the last item on a list this work built by asking which comparisons in
// std/math.y are made against something OTHER than a bare parameter -- a length,
// an array element, a field. audit_thresholds.py deliberately skips those,
// because "is there an argument near this threshold" is the wrong question for a
// derived value, and a gate that answers a question nobody asked is worse than no
// gate. Enumerating what it skips is the other half of the answer, and this is
// most of what came back: nine length guards, of which six are covered by t310,
// t329 and t330, and these three were not.
//
// THE ANSWERS, all of which are what the manual says:
//
//   fsum of nothing is +0.0        the identity, not a NaN: there is nothing to
//                                   be inaccurate about, and fsum_kahan agrees
//   fmean of nothing is NaN        0/0, so it is not 0
//   fvariance of fewer than two    NaN, and a ONE-element array is in that class
//                                   as much as an empty one -- a sample variance
//                                   dividing by n-1 has no value at n = 1
//
// THE THREE ONE-ELEMENT ANSWERS ARE PINNED BESIDE THE EMPTY ONES on purpose. A
// guard written `len(a) < 2` and a guard written `len(a) == 0` are the same guard
// in two of the three cases, and the third -- fsum -- is `== 0` for a reason: an
// empty sum is an identity and a one-element sum is itself, and neither has an
// accuracy problem. Pinning only the empty array would let a change from `< 2` to
// `== 0` on fmean through, since an empty array is < 2 either way.
//
// AND THE NaN THIS PRODUCES HAS ITS SIGN BIT SET, which looks like a bug and is
// not one. math.nan, fmean of nothing and 0.0/0.0 are all 0xfff8000000000000
// where C's NAN and Python's float("nan") are 0x7ff8000000000000. IEEE 754
// leaves the sign of a GENERATED quiet NaN unspecified -- it is not an error
// condition with a sign, and nothing reads it.
//
// It is recorded because the bits differ from every other runtime's, and because
// I wrote a comment here claiming it "prints -nan where Python prints nan" and
// the fixture's own output contradicted it on the first run: BOTH print "nan",
// with no sign, for a NaN whose sign bit is set. Checked on this platform's
// Python for a NaN built with the sign set. So there is no visible difference
// anywhere -- and 1.0/nan is a NaN rather than an infinity, so the sign does not
// escape into a comparison either. Two ways to confirm nothing is wrong with the
// world, and the second one came from reading the output instead of the comment.

import math;

def bits(v: float) -> long {
    math.fbits(v)
};

let empty: [float] = [];
let one: [float] = [2.5];
let two: [float] = [2.5, 3.5];

print("── the empty array ──");
print("fsum(empty)        ", bits(math.fsum(empty)));
print("fsum_kahan(empty)  ", bits(math.fsum_kahan(empty)));
print("fdot(empty,empty)  ", bits(math.fdot(empty, empty)));
print("fmean(empty)       ", bits(math.fmean(empty)));
print("fvariance(empty)   ", bits(math.fvariance(empty)));
print("fmin_of(empty)     ", bits(math.fmin_of(empty)));
print("fmax_of(empty)     ", bits(math.fmax_of(empty)));

print("── one element: the case a `len < 2` guard and a `len == 0` guard differ on ──");
print("fsum(one)          ", bits(math.fsum(one)));
print("fmean(one)         ", bits(math.fmean(one)));
print("fvariance(one)     ", bits(math.fvariance(one)));
print("  and the values themselves, so the bits above can be read:");
print("    fsum(one)      ", f"{math.fsum(one):.17e}");
print("    fmean(one)     ", f"{math.fmean(one):.17e}");
print("    fvariance(two) ", f"{math.fvariance(two):.17e}");

print("── a single-element array is a sum of itself, and its mean is itself ──");
print("  fsum(one)  == 2.5   ", math.fsum(one) == 2.5);
print("  fmean(one) == 2.5   ", math.fmean(one) == 2.5);
print("  fsum(two)  == 6.0   ", math.fsum(two) == 6.0);
print("  fmean(two) == 3.0   ", math.fmean(two) == 3.0);

print("── the NaN these produce carries its sign bit, and it does not matter ──");
print("  math.nan          ", f"{math.nan:.6f}");
print("  its bits          ", bits(math.nan));
print("  fmean(empty)      ", f"{math.fmean(empty):.6f}");
print("  0.0 / 0.0         ", f"{0.0 / 0.0:.6f}");
print("  all three the same NaN: ",
    bits(math.nan) == bits(math.fmean(empty)) && bits(math.nan) == bits(0.0 / 0.0));
print("  and the sign never escapes: 1/nan is a NaN, not an infinity: ",
    math.is_nan(1.0 / math.nan));

print("── in place, where there is no sum to get wrong ──");
let dst: [float] = [1.0, 2.0];
let src: [float] = [10.0, 20.0];
math.fscale(dst, 3.0);
math.faxpy(dst, 2.0, src);
print("  after fscale and faxpy: ", tostring(dst[0]), " ", tostring(dst[1]));
let e2: [float] = [];
let s2: [float] = [];
math.fscale(e2, 5.0);
math.faxpy(e2, 5.0, s2);
print("  and both on an empty pair leave it empty: ", len(e2));