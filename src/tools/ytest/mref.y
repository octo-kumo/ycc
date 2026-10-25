// mref.y -- correctly rounded references for std/math.y's functions, in
// binary floating point of any precision (bigf.y).
//
// Every reference works at PREC (320) bits or more and rounds ONCE, to the
// double, at the end, so it is wrong only when the exact answer sits within
// 2^-320 of a midpoint between two doubles. Python's Decimal and the platform
// libm used to be the references; libm cannot be one (its cbrt is 3 ulps out on
// a third of ordinary arguments and its tanh 2 ulps out on some), and a
// reference that shares a shape with the code under test certifies the shape.
// So nothing here calls std/math.y for anything but a starting guess.
//
// The precision is the argument's business where it must be:
//   * sin/cos/tan reduce by pi/2 at 320 bits PLUS the argument's own exponent,
//     so 1e308's quadrant is exact;
//   * expm1 and log1p never form 1 + x for a small x (the sum is 1 and the
//     answer is gone): they sum their own series, which needs no cancellation.
//
// The conventions std/math.y documents are applied where the module promises
// them rather than C (sin/cos/tan answer nan past the quadrant's reach, fsign
// answers 0 for a NaN); `ytest math-table` checks ulp_table.txt against these.
import math;
import bigf;

let BASE = 320;

/** The positive quiet NaN, as libm writes it (0.0 / 0.0 has the sign bit set). */
def nan() -> float { math.bitsf(9221120237041090560) };

def is_neg(x: float) -> bool { math.fbits(x) < 0 };

def neg0() -> float { 0.0 * -1.0 };

// -v, a zero included (0.0 - 0.0 is +0.0)
def fneg(v: float) -> float { v * -1.0 };

def copysign(v: float, s: float) -> float { if (is_neg(s) != is_neg(v)) { v * -1.0 } else { v } };

// ── the ulp gap ──────────────────────────────────────────────────────────

/** The monotone key of a double: +0.0 is 0, -0.0 is -1, order-preserving. */
def key(x: float) -> long {
    let b = math.fbits(x);
    if (b < 0) { 0 - 1 - (b & 9223372036854775807) } else { b }
};

/** Doubles between two answers; two NaNs agree, a NaN against a number is the worst gap. */
def gap(got: float, want: float) -> long {
    let gn = math.is_nan(got);
    let wn = math.is_nan(want);
    if (gn || wn) { return if (gn && wn) { 0 } else { 4611686018427387904 }; };
    let d = key(got) - key(want);
    if (d < 0) { 0 - d } else { d }
};

// ── bigf helpers ─────────────────────────────────────────────────────────

def one() -> bigf.BF { bigf.from_long(1) };

def tiny(term: bigf.BF, total: bigf.BF) -> bool {
    bigf.is_zero(term) || bigf.top(term) < bigf.top(total) - bigf.PREC - 8
};

// The nearest long to a (|a| well inside 2^62).
def lround(a: bigf.BF) -> long { math.to_int(math.floor(bigf.to_double(a) + 0.5)) };

/** atanh(z) = z + z^3/3 + z^5/5 + ..., |z| <= 1/3. */
def atanh_series(z: bigf.BF) -> bigf.BF {
    if (bigf.is_zero(z)) { return z; };
    let z2 = bigf.mul(z, z);
    let p = z;
    let total = z;
    let k = 1;
    let go = true;
    while (go) {
        p = bigf.mul(p, z2);
        let t = bigf.div_small(p, 2 * k + 1);
        if (tiny(t, total)) { go = false; } else { total = bigf.add(total, t); k += 1; };
    };
    total
};

let LN2_: [bigf.BF] = [];
let LN2_PREC = 0;

/** ln 2 = 2 atanh(1/3), at the current precision. */
def ln2() -> bigf.BF {
    if (LN2_PREC != bigf.PREC) {
        LN2_ = [bigf.ldexp(atanh_series(bigf.div_small(one(), 3)), 1)];
        LN2_PREC = bigf.PREC;
    };
    LN2_[0]
};

/** e^a for |a| < 1000: a = k ln2 + r, r scaled down by 2^12, the series, 12 squarings. */
def bexp(a: bigf.BF) -> bigf.BF {
    if (bigf.is_zero(a)) { return one(); };
    let k = lround(bigf.div(a, ln2()));
    let r = bigf.ldexp(bigf.sub(a, bigf.mul(ln2(), bigf.from_long(k))), -12);
    let term = one();
    let total = one();
    let n = 1;
    let go = true;
    while (go) {
        term = bigf.div_small(bigf.mul(term, r), n);
        if (tiny(term, total)) { go = false; } else { total = bigf.add(total, term); n += 1; };
    };
    for i in 0..12 { total = bigf.mul(total, total); };
    bigf.ldexp(total, k)
};

/** e^a - 1 by its own series, for |a| < 1/2 (no 1 to cancel). */
def bexpm1_small(a: bigf.BF) -> bigf.BF {
    let term = a;
    let total = a;
    let n = 2;
    let go = !bigf.is_zero(a);
    while (go) {
        term = bigf.div_small(bigf.mul(term, a), n);
        if (tiny(term, total)) { go = false; } else { total = bigf.add(total, term); n += 1; };
    };
    total
};

/** ln a for a > 0: a = u 2^t, u in [1/sqrt2, sqrt2), ln u = 2 atanh((u-1)/(u+1)). */
def bln(a: bigf.BF) -> bigf.BF {
    let t = bigf.top(a);
    let u = bigf.unit(a);
    if (bigf.to_double(u) > 1.4142135623730951) {
        u = bigf.ldexp(u, -1);
        t += 1;
    };
    let z = bigf.div(bigf.sub(u, one()), bigf.add(u, one()));
    bigf.add(bigf.ldexp(atanh_series(z), 1), bigf.mul(ln2(), bigf.from_long(t)))
};

// a rounded toward minus infinity, to an integer
def bfloor(a: bigf.BF) -> bigf.BF {
    if (bigf.is_zero(a) || a.e >= 0) { return a; };
    let q: bigf.BF = { neg: false, m: bigf.bn_shr(a.m, 0 - a.e), e: 0 };
    let exact = !bigf.bn_low_any(a.m, 0 - a.e);
    if (!a.neg) { return q; };
    let nq = bigf.neg(q);
    if (exact) { nq } else { bigf.sub(nq, one()) }
};

// the integer n's residue mod 4, 0..3
def mod4(n: bigf.BF) -> long {
    if (bigf.is_zero(n) || n.e >= 2) { return 0; };
    let low = (n.m[0] << n.e) & 3;
    if (n.neg) { (4 - low) & 3 } else { low }
};

/** [sin x, cos x], x finite, reduced by pi/2 at 320 bits plus x's own exponent. */
def sincos(x: float) -> [float] {
    let a = bigf.from_double(x);
    let tp = bigf.top(a);
    bigf.set_prec(BASE + 64 + (if (tp > 0) { tp } else { 0 }));
    let hp = bigf.ldexp(bigf.pi(), -1);
    let n = bfloor(bigf.add(bigf.div(a, hp), bigf.ldexp(one(), -1)));
    let r = bigf.sub(a, bigf.mul(n, hp));
    let q = mod4(n);
    let r2 = bigf.mul(r, r);
    // sin r and cos r by their series; |r| <= pi/4
    let s = r;
    let st = r;
    let c = one();
    let ct = one();
    let k = 1;
    let go = !bigf.is_zero(r);
    while (go) {
        st = bigf.neg(bigf.div_small(bigf.mul(st, r2), (2 * k) * (2 * k + 1)));
        ct = bigf.neg(bigf.div_small(bigf.mul(ct, r2), (2 * k - 1) * (2 * k)));
        if (tiny(st, s) && tiny(ct, c)) { go = false; } else {
            s = bigf.add(s, st);
            c = bigf.add(c, ct);
            k += 1;
        };
    };
    let sv = [s, c, bigf.neg(s), bigf.neg(c)];
    let out = [bigf.to_double(sv[q]), bigf.to_double(sv[(q + 1) & 3])];
    bigf.set_prec(BASE);
    out
};

// ── the references ───────────────────────────────────────────────────────

def to_d(a: bigf.BF) -> float { bigf.to_double(a) };

def exp(x: float) -> float {
    if (math.is_nan(x)) { return nan(); };
    if (x > 710.0) { return math.inf; };
    if (x < -746.0) { return 0.0; };
    to_d(bexp(bigf.from_double(x)))
};

def expm1(x: float) -> float {
    if (math.is_nan(x) || x == 0.0) { return x; };
    if (x > 710.0) { return math.inf; };
    if (x < -746.0) { return -1.0; };
    let a = bigf.from_double(x);
    if (math.fabs(x) < 0.5) { to_d(bexpm1_small(a)) } else { to_d(bigf.sub(bexp(a), one())) }
};

def exp2(x: float) -> float {
    if (math.is_nan(x)) { return nan(); };
    if (x >= 1024.0) { return math.inf; };
    if (x < -1080.0) { return 0.0; };
    let a = bigf.from_double(x);
    // an integer exponent is a power of two, exactly
    if (math.floor(x) == x) { return to_d(bigf.ldexp(one(), math.to_int(x))); };
    to_d(bexp(bigf.mul(a, ln2())))
};

// the log family's special cases: "" when x is an ordinary positive number
def log_special(x: float) -> [float] {
    if (math.is_nan(x) || x < 0.0) { return [nan()]; };
    if (x == 0.0) { return [0.0 - math.inf]; };
    if (math.is_inf(x)) { return [math.inf]; };
    if (x == 1.0) { return [0.0]; };
    []
};

def log(x: float) -> float {
    let s = log_special(x);
    if (s.length > 0) { s[0] } else { to_d(bln(bigf.from_double(x))) }
};

def log2(x: float) -> float {
    let s = log_special(x);
    if (s.length > 0) { return s[0]; };
    to_d(bigf.div(bln(bigf.from_double(x)), ln2()))
};

def log10(x: float) -> float {
    let s = log_special(x);
    if (s.length > 0) { return s[0]; };
    to_d(bigf.div(bln(bigf.from_double(x)), bln(bigf.from_long(10))))
};

def log1p(x: float) -> float {
    if (math.is_nan(x) || x < -1.0) { return nan(); };
    if (x == -1.0) { return 0.0 - math.inf; };
    if (x == 0.0 || math.is_inf(x)) { return x; };
    let a = bigf.from_double(x);
    if (math.fabs(x) < 0.5) {
        // ln(1 + x) = 2 atanh(x / (2 + x)), and x / (2 + x) has nothing to cancel
        let z = bigf.div(a, bigf.add(bigf.from_long(2), a));
        return to_d(bigf.ldexp(atanh_series(z), 1));
    };
    to_d(bln(bigf.add(one(), a)))
};

// The quadrant's reach, tested as the module tests it: on the product to_int
// is handed (a constant boundary is off by one double).
def pio2_ok(x: float) -> bool {
    let q = x * 6.36619772367581382433e-01 + 0.5;
    q < 9223372036854775807.0 && q > 0.0 - 9223372036854775807.0
};

def sin(x: float) -> float {
    if (math.is_nan(x) || math.is_inf(x) || !pio2_ok(x)) { return nan(); };
    if (x == 0.0) { return x; };
    sincos(x)[0]
};

def cos(x: float) -> float {
    if (math.is_nan(x) || math.is_inf(x) || !pio2_ok(x)) { return nan(); };
    if (x == 0.0) { return 1.0; };
    sincos(x)[1]
};

def tan(x: float) -> float {
    if (math.is_nan(x) || math.is_inf(x) || !pio2_ok(x)) { return nan(); };
    if (x == 0.0) { return x; };
    // tan in one rounding: sin/cos at the reduction's precision
    let a = bigf.from_double(x);
    let tp = bigf.top(a);
    bigf.set_prec(BASE + 64 + (if (tp > 0) { tp } else { 0 }));
    let hp = bigf.ldexp(bigf.pi(), -1);
    let n = bfloor(bigf.add(bigf.div(a, hp), bigf.ldexp(one(), -1)));
    let r = bigf.sub(a, bigf.mul(n, hp));
    let r2 = bigf.mul(r, r);
    let s = r;
    let st = r;
    let c = one();
    let ct = one();
    let k = 1;
    let go = !bigf.is_zero(r);
    while (go) {
        st = bigf.neg(bigf.div_small(bigf.mul(st, r2), (2 * k) * (2 * k + 1)));
        ct = bigf.neg(bigf.div_small(bigf.mul(ct, r2), (2 * k - 1) * (2 * k)));
        if (tiny(st, s) && tiny(ct, c)) { go = false; } else {
            s = bigf.add(s, st);
            c = bigf.add(c, ct);
            k += 1;
        };
    };
    // tan(r + n pi/2) is tan r for an even n and -cot r for an odd one
    let v = if ((mod4(n) & 1) == 0) { bigf.div(s, c) } else { bigf.neg(bigf.div(c, s)) };
    let out = to_d(v);
    bigf.set_prec(BASE);
    out
};

def atan(x: float) -> float {
    if (math.is_nan(x)) { return nan(); };
    if (x == 0.0) { return x; };
    if (math.is_inf(x)) {
        let h = to_d(bigf.ldexp(bigf.pi(), -1));
        return if (x < 0.0) { 0.0 - h } else { h };
    };
    to_d(bigf.atan(bigf.from_double(x)))
};

def asin(x: float) -> float {
    if (math.is_nan(x) || math.fabs(x) > 1.0) { return nan(); };
    if (x == 0.0) { return x; };
    let a = bigf.from_double(x);
    if (math.fabs(x) == 1.0) {
        let h = bigf.ldexp(bigf.pi(), -1);
        return to_d(if (x < 0.0) { bigf.neg(h) } else { h });
    };
    to_d(bigf.atan(bigf.div(a, bigf.sqrt(bigf.sub(one(), bigf.mul(a, a))))))
};

def acos(x: float) -> float {
    if (math.is_nan(x) || math.fabs(x) > 1.0) { return nan(); };
    if (x == 1.0) { return 0.0; };
    if (x == -1.0) { return to_d(bigf.pi()); };
    // 2 atan(sqrt((1-x)/(1+x))): nothing to cancel near either end
    let a = bigf.from_double(x);
    to_d(bigf.ldexp(bigf.atan(bigf.sqrt(bigf.div(bigf.sub(one(), a), bigf.add(one(), a)))), 1))
};

def sinh(x: float) -> float {
    if (math.is_nan(x) || x == 0.0 || math.is_inf(x)) { return x; };
    if (math.fabs(x) > 711.0) { return copysign(math.inf, x); };
    let a = bigf.from_double(x);
    if (math.fabs(x) < 0.5) {
        let a2 = bigf.mul(a, a);
        let term = a;
        let total = a;
        let k = 1;
        let go = true;
        while (go) {
            term = bigf.div_small(bigf.mul(term, a2), (2 * k) * (2 * k + 1));
            if (tiny(term, total)) { go = false; } else { total = bigf.add(total, term); k += 1; };
        };
        return to_d(total);
    };
    to_d(bigf.ldexp(bigf.sub(bexp(a), bexp(bigf.neg(a))), -1))
};

def cosh(x: float) -> float {
    if (math.is_nan(x)) { return x; };
    if (math.is_inf(x) || math.fabs(x) > 711.0) { return math.inf; };
    let a = bigf.from_double(x);
    to_d(bigf.ldexp(bigf.add(bexp(a), bexp(bigf.neg(a))), -1))
};

def tanh(x: float) -> float {
    if (math.is_nan(x) || x == 0.0) { return x; };
    if (math.fabs(x) > 40.0) { return copysign(1.0, x); };
    let a = bigf.abs(bigf.from_double(x));
    // tanh |x| = em / (em + 2), em = e^(2|x|) - 1: nothing to cancel at either size
    let a2 = bigf.ldexp(a, 1);
    let em = if (math.fabs(x) < 0.25) { bexpm1_small(a2) } else { bigf.sub(bexp(a2), one()) };
    let v = to_d(bigf.div(em, bigf.add(em, bigf.from_long(2))));
    copysign(v, x)
};

def sqrt(x: float) -> float {
    if (math.is_nan(x) || x < 0.0) { return nan(); };
    if (x == 0.0 || math.is_inf(x)) { return x; };
    to_d(bigf.sqrt(bigf.from_double(x)))
};

def cbrt(x: float) -> float {
    if (math.is_nan(x) || x == 0.0 || math.is_inf(x)) { return x; };
    let a = bigf.abs(bigf.from_double(x));
    // the double's estimate, then Newton: y = (2y + a/y^2) / 3, 53 -> 400 bits
    let y = bigf.from_double(math.exp(math.log(math.fabs(x)) / 3.0));
    for i in 0..4 { y = bigf.div_small(bigf.add(bigf.ldexp(y, 1), bigf.div(a, bigf.mul(y, y))), 3); };
    copysign(to_d(y), x)
};

// ── the exact functions ──────────────────────────────────────────────────

def trunc(x: float) -> float {
    if (math.is_nan(x) || math.is_inf(x) || math.fabs(x) >= 4503599627370496.0) { return x; };
    let t: float = math.to_int(x);
    copysign(t, x)
};

def floor(x: float) -> float {
    let t = trunc(x);
    if (x < 0.0 && t != x) { t - 1.0 } else { t }
};

def ceil(x: float) -> float {
    let t = trunc(x);
    if (x > 0.0 && t != x) { t + 1.0 } else { t }
};

/** Half away from zero, decided on the exact remainder (floor(v + 0.5) is not it). */
def round(x: float) -> float {
    let t = trunc(x);
    if (math.fabs(x - t) >= 0.5) { copysign(math.fabs(t) + 1.0, x) } else { t }
};

def fract(x: float) -> float {
    if (math.is_nan(x)) { return x; };
    if (math.is_inf(x)) { return nan(); };
    if (x == 0.0) { return x - x; };
    x - trunc(x)
};

def fabs(x: float) -> float { math.bitsf(math.fbits(x) & 9223372036854775807) };

/** 1, -1 or 0 -- and 0 for a NaN, the module's convention. */
def fsign(x: float) -> float { if (x > 0.0) { 1.0 } else if (x < 0.0) { -1.0 } else { 0.0 } };

def to_int(x: float) -> float {
    if (x >= -9223372036854775808.0 && x < 9223372036854775808.0) { trunc(x) } else { nan() }
};

/** IEEE 754-2019 minNum: a NaN loses, and -0.0 is below +0.0. */
def fmin(a: float, b: float) -> float {
    if (math.is_nan(a)) { return b; };
    if (math.is_nan(b)) { return a; };
    if (a == 0.0 && b == 0.0) { return if (is_neg(a) || is_neg(b)) { neg0() } else { 0.0 }; };
    if (a < b) { a } else { b }
};

def fmax(a: float, b: float) -> float {
    if (math.is_nan(a)) { return b; };
    if (math.is_nan(b)) { return a; };
    if (a == 0.0 && b == 0.0) { return if (!is_neg(a) || !is_neg(b)) { 0.0 } else { neg0() }; };
    if (a > b) { a } else { b }
};

def nextafter(x: float, y: float) -> float {
    if (math.is_nan(x) || math.is_nan(y)) { return nan(); };
    if (x == y) { return y; };
    if (x == 0.0) { return if (y > 0.0) { math.bitsf(1) } else { math.bitsf(1 | (1 << 63)) }; };
    let b = math.fbits(x);
    // away from zero is one up in the pattern, toward it one down, either sign
    if ((y > x) == (x > 0.0)) { math.bitsf(b + 1) } else { math.bitsf(b - 1) }
};

def hypot(x: float, y: float) -> float {
    // the infinity FIRST: C99, IEEE 754 and glibc give +inf for hypot(inf, nan)
    if (math.is_inf(x) || math.is_inf(y)) { return math.inf; };
    if (math.is_nan(x) || math.is_nan(y)) { return nan(); };
    let a = bigf.from_double(x);
    let b = bigf.from_double(y);
    to_d(bigf.sqrt(bigf.add(bigf.mul(a, a), bigf.mul(b, b))))
};

def pi_part(num: long, den: long, negative: bool) -> float {
    let v = bigf.div_small(bigf.mul(bigf.pi(), bigf.from_long(num)), den);
    to_d(if (negative) { bigf.neg(v) } else { v })
};

/** C's atan2: the quadrant applied to atan(y/x), every zero and infinity spelled out
(-0.0 is neither above nor below zero, so a `y > 0` ladder answers alike for all four zero pairs). */
def atan2(y: float, x: float) -> float {
    if (math.is_nan(x) || math.is_nan(y)) { return nan(); };
    let yneg = is_neg(y);
    let xneg = is_neg(x);
    let dpi = 3.141592653589793;
    if (math.is_inf(x) && math.is_inf(y)) {
        return if (!xneg) { pi_part(1, 4, yneg) } else { pi_part(3, 4, yneg) };
    };
    if (math.is_inf(x) || y == 0.0) {
        if (xneg) { return if (yneg) { 0.0 - dpi } else { dpi }; };
        return if (yneg) { neg0() } else { 0.0 };
    };
    if (math.is_inf(y) || x == 0.0) { return pi_part(1, 2, yneg); };
    let a = bigf.atan(bigf.div(bigf.from_double(y), bigf.from_double(x)));
    if (xneg) { a = if (!yneg) { bigf.add(a, bigf.pi()) } else { bigf.sub(a, bigf.pi()) }; };
    to_d(a)
};

def is_int(y: float) -> bool { !math.is_inf(y) && floor(y) == y };

def odd_int(y: float) -> bool { is_int(y) && math.fabs(y) < 9007199254740992.0 && math.to_int(y) % 2 != 0 };

/** C's pow, the special cases first (C99 F.9.4.4), then exp(y ln |x|) in one rounding. */
def pow(x: float, y: float) -> float {
    if (y == 0.0) { return 1.0; };
    if (math.is_nan(x) || math.is_nan(y)) { return nan(); };
    let odd = odd_int(y);
    // the module's convention for +-1 (the table's): -1 only for -1 to an odd power
    if (x == 1.0 || x == -1.0) { return if (x == -1.0 && odd) { -1.0 } else { 1.0 }; };
    if (x == 0.0) {
        // +inf for either zero: the module's convention (and the table's), where C
        // gives -inf for -0.0 to an odd negative power
        if (y < 0.0) { return math.inf; };
        return if (odd) { x } else { 0.0 };
    };
    if (math.is_inf(y)) {
        let big = math.fabs(x) > 1.0;
        return if ((y > 0.0) == big) { math.inf } else { 0.0 };
    };
    if (math.is_inf(x)) {
        if (y < 0.0) { return if (odd && x < 0.0) { neg0() } else { 0.0 }; };
        return if (odd && x < 0.0) { 0.0 - math.inf } else { math.inf };
    };
    if (x < 0.0 && !is_int(y)) { return nan(); };
    let l = bln(bigf.abs(bigf.from_double(x)));
    let p = bigf.mul(l, bigf.from_double(y));
    let pd = to_d(p);
    let v = if (pd > 710.0) { math.inf } else if (pd < -746.0) { 0.0 } else { to_d(bexp(p)) };
    if (x < 0.0 && odd) { fneg(v) } else { v }
};

def lerp(a: float, b: float, t: float) -> float { a + (b - a) * t };

let ONE_ARG = ["exp", "expm1", "exp2", "log", "log2", "log10", "log1p", "sin", "cos", "tan", "atan", "asin", "acos",
    "sinh", "cosh", "tanh", "sqrt", "cbrt", "floor", "ceil", "trunc", "round", "fract", "fabs", "fsign", "to_int",
    "is_nan", "is_inf", "is_finite", "is_signed_zero", "frexp"];

/** The reference for a function of the table by name: [answer], or [] for none. */
def one_arg(name: str, x: float) -> [float] {
    if (!(name in ONE_ARG)) { return []; };
    let r = if (name == "exp") { exp(x) } else if (name == "expm1") { expm1(x) } else if (name == "exp2") { exp2(x) }
        else if (name == "log") { log(x) } else if (name == "log2") { log2(x) } else if (name == "log10") { log10(x) }
        else if (name == "log1p") { log1p(x) } else if (name == "sin") { sin(x) } else if (name == "cos") { cos(x) }
        else if (name == "tan") { tan(x) } else if (name == "atan") { atan(x) } else if (name == "asin") { asin(x) }
        else if (name == "acos") { acos(x) } else if (name == "sinh") { sinh(x) } else if (name == "cosh") { cosh(x) }
        else if (name == "tanh") { tanh(x) } else if (name == "sqrt") { sqrt(x) } else if (name == "cbrt") { cbrt(x) }
        else if (name == "floor") { floor(x) } else if (name == "ceil") { ceil(x) } else if (name == "trunc") { trunc(x) }
        else if (name == "round") { round(x) } else if (name == "fract") { fract(x) } else if (name == "fabs") { fabs(x) }
        else if (name == "fsign") { fsign(x) } else if (name == "to_int") { to_int(x) }
        else if (name == "is_nan") { if (math.is_nan(x)) { 1.0 } else { 0.0 } }
        else if (name == "is_inf") { if (math.is_inf(x)) { 1.0 } else { 0.0 } }
        else if (name == "is_finite") { if (math.is_nan(x) || math.is_inf(x)) { 0.0 } else { 1.0 } }
        else if (name == "is_signed_zero") { if (x == 0.0 && is_neg(x)) { 1.0 } else { 0.0 } }
        // frexp is exact: the table carries x itself, the identity the harness checks
        else { x };
    [r]
};

def two_arg(name: str, x: float, y: float) -> [float] {
    if (!(name in ["pow", "atan2", "hypot", "fmin", "fmax", "nextafter"])) { return []; };
    let r = if (name == "pow") { pow(x, y) } else if (name == "atan2") { atan2(x, y) } else if (name == "hypot") { hypot(x, y) }
        else if (name == "fmin") { fmin(x, y) } else if (name == "fmax") { fmax(x, y) }
        else { nextafter(x, y) };
    [r]
};

export { bexp, bexpm1_small, bln, atanh_series, nan, is_neg, key, gap, exp, expm1, exp2, log, log2, log10, log1p, sin, cos, tan, atan, asin, acos, sinh, cosh,
    tanh, sqrt, cbrt, trunc, floor, ceil, round, fract, fabs, fsign, to_int, fmin, fmax, nextafter, hypot, atan2, pow,
    lerp, one_arg, two_arg };
