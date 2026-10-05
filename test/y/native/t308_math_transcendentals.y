// The transcendentals, and the identities that hold across them. The ulps are
// checked by test/math/ulp_check.y against a table of IEEE-754 bit patterns --
// this fixture is the readable companion: the shapes, the special values, and
// the identities whose failure means a kernel has gone wrong.
import math;

// ── the shapes ────────────────────────────────────────────────────────────
let xs: [float] = [0.0, 0.5, 1.0, -1.0, 2.0, 3.5, 10.0, -10.0, 100.0, -0.001];
let i = 0;
while (i < len(xs)) {
    let x = xs[i];
    print(f"x={x:10.4f} exp={math.exp(x):14.9e} log={math.log(x + 1.0):14.9e}"
        + f" sin={math.sin(x):14.9e} cos={math.cos(x):14.9e} atan={math.atan(x):14.9e}");
    i = i + 1;
};

// ── the identities ────────────────────────────────────────────────────────
//
// math.abs is the integer one (std/math.y has no float absolute value yet), so
// this fixture brings its own.
def absf(x: float) -> float {
    if (x < 0.0) { 0.0 - x } else { x }
};
//
// Each is checked to a tolerance rather than printed, because the point is not
// the digits but whether the functions still agree with each other. The
// tolerance is in ulps of the answer, so a kernel that loses a few digits shows
// up here too.
def close(a: float, b: float, ulps: float) -> bool {
    let d = absf(a - b);
    let scale = if (absf(b) < 1.0e-300) { 1.0e-300 } else { absf(b) };
    d <= ulps * scale * 2.2204460492503131e-16
};

def check(name: str, ok: bool, a: float, b: float) -> long {
    // the numbers go in the failure line: an identity that fails is a bug in
    // one of the functions, and which value and which gap is the whole report
    if (!ok) {
        print(name + ": FAIL " + f"{a:.17e}" + " vs " + f"{b:.17e}");
        1
    } else {
        0
    }
};

let bad: long = 0;
let ys: [float] = [0.25, 1.0, 2.0, 7.5, 0.70710678118654752440, 1.0e-8, 1234.5];
i = 0;
while (i < len(ys)) {
    let y = ys[i];
    let small = absf(y);
    let half = y < 1.0 ? y : 0.5;
    let t = math.tanh(y);
    if (y > 0.0) {
        // each identity is checked to a tolerance in ulps of its own right-hand
        // side, so a kernel that loses a few digits shows up here as well as in
        // the table; the tolerances are as tight as the arithmetic allows, which
        // for a round trip through two functions is a few and for a cancellation
        // like cosh^2 - sinh^2 is thousands
        let e1 = math.exp(math.log(y));
        bad += check("exp/log round trip", close(e1, y, 16.0), e1, y);
        let e2 = math.log2(y * 2.0);
        let w2 = math.log2(y) + 1.0;
        bad += check("log2 doubling", close(e2, w2, 4.0), e2, w2);
        let e3 = math.log10(y * 10.0);
        let w3 = math.log10(y) + 1.0;
        bad += check("log10 decades", close(e3, w3, 4.0), e3, w3);
        // pow against the textbook formula, which is what pow itself computes
        // when the exponent is an integer -- and which drifts from it as the
        // exponent grows, because the logarithm's own error is multiplied by the
        // exponent. That is why the tolerance here is 32 ulps and not 4, and
        // why the check is left out for a tiny base, where the exponent is a
        // large number of thousands and the drift is tens of ulps.
        if (y >= 0.25) {
            let e4 = math.pow(y, 3.5);
            let w4 = math.exp2(3.5 * math.log2(y));
            bad += check("pow/log", close(e4, w4, 32.0), e4, w4);
        };
        let e5 = math.sin(math.asin(half));
        bad += check("asin/sin", close(e5, half, 4.0), e5, half);
        let e6 = math.sin(y) * math.sin(y) + math.cos(y) * math.cos(y);
        bad += check("sin^2+cos^2", close(e6, 1.0, 4.0), e6, 1.0);
        let e7 = math.tan(y);
        let w7 = math.sin(y) / math.cos(y);
        bad += check("tan = sin/cos", close(e7, w7, 8.0), e7, w7);
        let e8 = math.tanh(2.0 * y);
        let w8 = 2.0 * t / (1.0 + t * t);
        bad += check("tanh double angle", close(e8, w8, 8.0), e8, w8);
        let e9 = math.expm1(math.log1p(y));
        bad += check("expm1/log1p", close(e9, y, 4.0), e9, y);
        let e10 = math.atan2(y, -1.0);
        let w10 = math.pi - math.atan(y);
        bad += check("atan2 quadrant", close(e10, w10, 8.0), e10, w10);
        // cosh^2 - sinh^2 asks a subtraction to cancel, so it only says anything
        // where the two agree to more than the sixteen digits a double holds
        if (small <= 0.5) {
            let e11 = math.cosh(y) * math.cosh(y) - math.sinh(y) * math.sinh(y);
            bad += check("cosh^2 - sinh^2", close(e11, 1.0, 4096.0), e11, 1.0);
        };
    };
    let c = math.cbrt(y);
    let e12 = c * c * c;
    bad += check("cbrt cube", close(e12, y, 32.0), e12, y);
    i = i + 1;
};
print(if (bad == 0) { "identities: all ok" } else { f"identities: {bad} failures" });

// ── the special values ────────────────────────────────────────────────────
//
// Every one of these is C's behaviour, and each one is a place where the
// obvious implementation gives a number instead.
print(f"exp(0) = {math.exp(0.0)}, exp(-0.0) = {math.exp(-0.0)}");
print(f"log(1) = {math.log(1.0)}, log(0) = {math.log(0.0)}, log(-1) = {math.log(-1.0)}");
print(f"log1p(0) = {math.log1p(0.0)}, log1p(-1) = {math.log1p(-1.0)}");
print(f"expm1(0) = {math.expm1(0.0)}, expm1(-0.0) = {math.expm1(-0.0)}");
print(f"exp(710) = {math.exp(710.0)}, exp(-746) = {math.exp(-746.0)}");
print(f"exp2(1024) = {math.exp2(1024.0)}, exp2(-1075) = {math.exp2(-1075.0)}");
print(f"sinh(1e300) = {math.sinh(1.0e300)}, cosh(1e300) = {math.cosh(1.0e300)}");
print(f"tanh(1e300) = {math.tanh(1.0e300)}, tanh(-1e300) = {math.tanh(-1.0e300)}");
print(f"asin(1) = {math.asin(1.0)}, acos(-1) = {math.acos(-1.0)}");
print(f"asin(2) = {math.asin(2.0)}, acos(2) = {math.acos(2.0)}");
print(f"atan(-inf) = {math.atan(-1.0 / 0.0)}, atan2(0, -1) = {math.atan2(0.0, -1.0)}");
print(f"atan2(-0.0, -1) = {math.atan2(-0.0, -1.0)}, atan2(0, -1) = {math.atan2(0.0, -1.0)}");
print(f"pow(2, 10) = {math.pow(2.0, 10.0)}, pow(2, 0.5) = {math.pow(2.0, 0.5)}");
print(f"pow(-2, 3) = {math.pow(-2.0, 3.0)}, pow(-2, -3) = {math.pow(-2.0, -3.0)}");
print(f"pow(-2, 0.5) = {math.pow(-2.0, 0.5)}, pow(-1, 0.5) = {math.pow(-1.0, 0.5)}");
print(f"pow(-1, 3) = {math.pow(-1.0, 3.0)}, pow(-1, 0) = {math.pow(-1.0, 0.0)}");
print(f"pow(0, -1) = {math.pow(0.0, -1.0)}, pow(0, 0) = {math.pow(0.0, 0.0)}");
print(f"pow(-0.0, 3) signed zero: {math.is_signed_zero(math.pow(-0.0, 3.0))}");
print(f"pow(-0.0, 2) signed zero: {math.is_signed_zero(math.pow(-0.0, 2.0))}");
print(f"pow(inf, 3) = {math.pow(1.0 / 0.0, 3.0)}, pow(-inf, 3) = {math.pow(-1.0 / 0.0, 3.0)}");
print(f"pow(inf, 2) = {math.pow(1.0 / 0.0, 2.0)}, pow(2, inf) = {math.pow(2.0, 1.0 / 0.0)}");
print(f"pow(nan, 0) = {math.pow(0.0 / 0.0, 0.0)}, pow(2, nan) = {math.pow(2.0, 0.0 / 0.0)}");
print(f"pow(1e300, 2) = {math.pow(1.0e300, 2.0)}");
print(f"sin(inf) = {math.sin(1.0 / 0.0)}, cos(inf) = {math.cos(1.0 / 0.0)}");
print(f"tan(pi/2) = {math.tan(math.pi / 2.0)}, tan(-pi/2) = {math.tan(-math.pi / 2.0)}");
print(f"hypot(3, 4) = {math.hypot(3.0, 4.0)}, cbrt(27) = {math.cbrt(27.0)}");
print(f"ldexp(1, -1074) = {math.ldexp(1.0, -1074)}, ldexp(1, 1023) = {math.ldexp(1.0, 1023)}");
print(f"nextafter(1, 2) = {math.nextafter(1.0, 2.0)}");
print(f"nextafter(-1, -2) = {math.nextafter(-1.0, -2.0)}");
print(f"to_int(-2.9) = {math.to_int(-2.9)}, to_int(2.5) = {math.to_int(2.5)}");
print(f"is_signed_zero(-0.0) = {math.is_signed_zero(-0.0)}");
print(f"frexp(-8) = {math.bitsf(math.frexp(-8.0)[0])} {math.frexp(-8.0)[1]}");