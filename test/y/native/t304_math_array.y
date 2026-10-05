// whole-array work over [float]
import math;

let a: [float] = [1.0, 2.0, 3.0, 4.0];
let b: [float] = [2.0, 2.0, 2.0, 2.0];
print(math.fsum(a));
print(math.fsum_kahan(a));
print(math.fdot(a, b));
print(math.fmin_of(a));
print(math.fmax_of(a));
print(math.fmean(a));
print(f"{math.fvariance(a):.17f}");           // sample variance of 1,2,3,4 = 5/3

// one element, and the empty array
let one: [float] = [7.5];
print(math.fsum(one));
print(math.fmean(one));
print(math.fmin_of(one));
print(math.fmax_of(one));
let none: [float] = [];
print(math.fsum(none));
print(math.fsum_kahan(none));
print(math.fdot(none, none));
print(math.is_nan(math.fmean(none)));
print(math.is_nan(math.fmin_of(none)));
print(math.is_nan(math.fmax_of(none)));
print(math.is_nan(math.fvariance(none)));
print(math.is_nan(math.fvariance(one)));      // one element has no spread

// in place: fscale and faxpy
let c: [float] = [1.0, 2.0, 3.0];
math.fscale(c, 2.0);
print(c[0]);
print(c[1]);
print(c[2]);
let d: [float] = [1.0, 1.0, 1.0];
let e: [float] = [10.0, 20.0, 30.0];
math.faxpy(d, 0.5, e);
print(d[0]);
print(d[1]);
print(d[2]);

// fsum_kahan earns its keep: at 1e16 the ulp is 2, so a plain running sum throws
// away every +1 it is handed, and the compensated one keeps them. (At 1e17 the
// ulp is 16, so a +1 is not representable at all and both sums agree there —
// which is correct, not a missing feature.)
let big: [float] = [10000000000000000.0];
let k = 0;
while (k < 10) { big += 1.0; k = k + 1; };
print(math.fsum(big));
print(math.fsum_kahan(big));

// properties over a spread of values
let xs: [float] = [];
let j = 0;
while (j < 50) { xs += (j - 25.0) * 0.5; j = j + 1; };
let mean = math.fmean(xs);
let variance_ok = true;
if (math.fvariance(xs) < 0.0) { variance_ok = false; };
if (math.fmin_of(xs) >= math.fmax_of(xs)) { variance_ok = false; };
if (math.fsum(xs) != mean * len(xs)) { variance_ok = false; };
print(variance_ok);