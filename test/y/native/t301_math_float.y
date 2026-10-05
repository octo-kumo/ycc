// floats: the basics that need no machine primitive
import math;

// the constants, printed to the digits a double really holds
print(f"{math.pi:.17f}");
print(f"{math.e:.17f}");
print(f"{math.tau:.17f}");
print(f"{math.ln2:.17f}");
print(f"{math.ln10:.17f}");
print(f"{math.sqrt2:.17f}");
print(f"{math.phi:.17f}");

print(math.nan);
print(math.inf);
print(math.is_nan(math.nan));
print(math.is_nan(math.inf));
print(math.is_inf(math.inf));
print(math.is_inf(math.nan));
print(math.is_finite(math.nan));
print(math.is_finite(math.inf));
print(math.is_finite(1.5));

print(math.fmin(1.5, 2.5));
print(math.fmin(2.5, 1.5));
print(math.fmin(math.nan, 2.5));
print(math.fmin(2.5, math.nan));
print(math.fmax(1.5, 2.5));
print(math.fmax(math.nan, 2.5));

// fabs must turn -0.0 into +0.0, which a sign-bit test would also do. Printing
// cannot tell the two zeroes apart, so divide by it: 1.0 / -0.0 is -inf.
let nz = 0.0 - 0.0;
print(math.fabs(0.0 - 2.5));
print(math.fabs(2.5));
print(math.fabs(nz));
print(1.0 / math.fabs(nz));        // inf, so fabs(nz) is +0.0
print(1.0 / nz);                  // -inf, so nz really was -0.0
print(math.fsign(0.0 - 3.0));
print(math.fsign(0.0));
print(math.fsign(3.0));

print(math.lerp(10.0, 20.0, 0.0));
print(math.lerp(10.0, 20.0, 1.0));
print(math.lerp(10.0, 20.0, 0.25));
print(f"{math.lerp(0.0, 1.0, 0.1):.17f}");    // 0.1 is not exact; so is this not

// properties
let ok = true;
let xs: [float] = [0.0 - 2.0, 0.0, 1.0, 2.0, 2.0 - 1.0, 2.0 - 2.0];
let k = 0;
while (k < len(xs)) {
    let x = xs[k];
    if (x != x) { ok = false; };
    if (math.fabs(x) < 0.0) { ok = false; };          // |x| is never negative
    if (math.fmin(x, x) != x) { ok = false; };
    if (math.fmax(x, x) != x) { ok = false; };
    if (math.lerp(x, x, 0.5) != x) { ok = false; };
    k = k + 1;
};
print(ok);