// bigf.y -- binary floating point of any precision, for the math audits'
// references (atan2 and hypot to far more bits than a double holds).
//
// A Big is a natural number in base 2^30 limbs, least significant first and
// no high zero limb ([] is zero); 2^30 keeps a limb product plus a carry well
// inside a signed long. A BF is (-1)^neg * m * 2^e with a long exponent, so
// 1e600 (a ratio of two doubles) is an ordinary value. Results are rounded to
// PREC bits, to nearest, ties to even; to_double rounds once more, to the
// double (or subnormal) nearest, so a reference is off only when its PREC-bit
// value sits within 2^-PREC of a double's midpoint.
import math;

let PREC = 320;
let LB = 30;
let LMASK = 1073741823;

type BF = { neg: bool, m: [long], e: long };

// ── naturals ─────────────────────────────────────────────────────────────

def bn_norm(a: [long]) -> [long] {
    let n = a.length;
    while (n > 0 && a[n - 1] == 0) { n -= 1; };
    if (n == a.length) { a } else { a[0:n] }
};

def bn_from(v: long) -> [long] {
    let r: [long] = [];
    let x = v;
    while (x > 0) {
        r += x & LMASK;
        x = x >> LB;
    };
    r
};

def bn_bits(a: [long]) -> long {
    if (a.length == 0) { return 0; };
    let top = a[a.length - 1];
    let b = 0;
    while (top > 0) {
        b += 1;
        top = top >> 1;
    };
    (a.length - 1) * LB + b
};

def bn_cmp(a: [long], b: [long]) -> long {
    if (a.length != b.length) { return if (a.length < b.length) { -1 } else { 1 }; };
    let i = a.length - 1;
    while (i >= 0) {
        if (a[i] != b[i]) { return if (a[i] < b[i]) { -1 } else { 1 }; };
        i -= 1;
    };
    0
};

def bn_add(a: [long], b: [long]) -> [long] {
    let n = if (a.length > b.length) { a.length } else { b.length };
    let r: [long] = [];
    let c = 0;
    for i in 0..n {
        let s = c + (if (i < a.length) { a[i] } else { 0 }) + (if (i < b.length) { b[i] } else { 0 });
        r += s & LMASK;
        c = s >> LB;
    };
    if (c > 0) { r += c; };
    r
};

// a - b, a >= b
def bn_sub(a: [long], b: [long]) -> [long] {
    let r: [long] = [];
    let br = 0;
    for i in 0..a.length {
        let s = a[i] - br - (if (i < b.length) { b[i] } else { 0 });
        if (s < 0) {
            s += LMASK + 1;
            br = 1;
        } else {
            br = 0;
        };
        r += s;
    };
    bn_norm(r)
};

def bn_shl(a: [long], k: long) -> [long] {
    if (a.length == 0 || k == 0) { return a; };
    let limbs = k / LB;
    let bits = k % LB;
    let r: [long] = [];
    for i in 0..limbs { r += 0; };
    if (bits == 0) {
        r += a;
    } else {
        let c = 0;
        foreach (x in a) {
            let v = (x << bits) | c;
            r += v & LMASK;
            c = v >> LB;
        };
        if (c > 0) { r += c; };
    };
    r
};

def bn_shr(a: [long], k: long) -> [long] {
    let limbs = k / LB;
    let bits = k % LB;
    if (limbs >= a.length) { return []; };
    let r: [long] = [];
    let i = limbs;
    while (i < a.length) {
        let lo = a[i] >> bits;
        let hi = if (bits > 0 && i + 1 < a.length) { (a[i + 1] << (LB - bits)) & LMASK } else { 0 };
        r += lo | hi;
        i += 1;
    };
    bn_norm(r)
};

// Is any of the low k bits of a set?
def bn_low_any(a: [long], k: long) -> bool {
    let limbs = k / LB;
    let bits = k % LB;
    let i = 0;
    while (i < limbs && i < a.length) {
        if (a[i] != 0) { return true; };
        i += 1;
    };
    limbs < a.length && bits > 0 && (a[limbs] & ((1 << bits) - 1)) != 0
};

def bn_bit(a: [long], k: long) -> bool {
    let l = k / LB;
    l < a.length && ((a[l] >> (k % LB)) & 1) == 1
};

def bn_mul(a: [long], b: [long]) -> [long] {
    if (a.length == 0 || b.length == 0) { return []; };
    let r: [long] = [];
    for i in 0..a.length + b.length { r += 0; };
    for i in 0..a.length {
        let c = 0;
        let ai = a[i];
        for j in 0..b.length {
            let t = r[i + j] + ai * b[j] + c;
            r[i + j] = t & LMASK;
            c = t >> LB;
        };
        let k = i + b.length;
        while (c > 0) {
            let t = r[k] + c;
            r[k] = t & LMASK;
            c = t >> LB;
            k += 1;
        };
    };
    bn_norm(r)
};

def bn_mul_small(a: [long], s: long) -> [long] { bn_mul(a, bn_from(s)) };

// floor(a / s) for 0 < s < 2^30, and whether the division was inexact.
def bn_div_small(a: [long], s: long, inexact: [bool]) -> [long] {
    let r: [long] = [];
    for i in 0..a.length { r += 0; };
    let rem = 0;
    let i = a.length - 1;
    while (i >= 0) {
        let cur = (rem << LB) | a[i];
        r[i] = cur / s;
        rem = cur % s;
        i -= 1;
    };
    inexact[0] = rem != 0;
    bn_norm(r)
};

// ── floats ───────────────────────────────────────────────────────────────

def bf_zero() -> BF { { neg: false, m: [], e: 0 } };

def is_zero(a: BF) -> bool { a.m.length == 0 };

// m * 2^e rounded to `prec` bits, nearest-even; `sticky` says bits below m were
// already dropped (a lower part that is not zero).
def round_to(neg: bool, m: [long], e: long, prec: long, sticky: bool) -> BF {
    let b = bn_bits(m);
    if (b <= prec) { return { neg: neg, m: m, e: e }; };
    let k = b - prec;
    let q = bn_shr(m, k);
    let half = bn_bit(m, k - 1);
    let rest = sticky || bn_low_any(m, k - 1);
    if (half && (rest || bn_bit(q, 0))) { q = bn_add(q, [1]); };
    if (bn_bits(q) > prec) {
        q = bn_shr(q, 1);
        k += 1;
    };
    { neg: neg, m: q, e: e + k }
};

def bf(neg: bool, m: [long], e: long) -> BF { round_to(neg, bn_norm(m), e, PREC, false) };

def from_long(v: long) -> BF {
    if (v < 0) { { neg: true, m: bn_from(0 - v), e: 0 } } else { { neg: false, m: bn_from(v), e: 0 } }
};

/** The double x, exactly. */
def from_double(x: float) -> BF {
    let b = math.fbits(x);
    let neg = b < 0;
    let ex = (b >>> 52) & 2047;
    let mant = b & 4503599627370495;
    if (ex == 0) { { neg: neg, m: bn_from(mant), e: -1074 } } else { { neg: neg, m: bn_from(mant | 4503599627370496), e: ex - 1075 } }
};

/** The double nearest a (ties to even), subnormals and infinities included. */
def to_double(a: BF) -> float {
    if (is_zero(a)) { return if (a.neg) { 0.0 * -1.0 } else { 0.0 }; };
    let b = bn_bits(a.m);
    let top = a.e + b - 1;
    let lsb = top - 52;
    if (lsb < -1074) { lsb = -1074; };
    let sh = lsb - a.e;
    let q: [long] = [];
    if (sh <= 0) {
        q = bn_shl(a.m, 0 - sh);
    } else {
        q = bn_shr(a.m, sh);
        if (bn_bit(a.m, sh - 1) && (bn_low_any(a.m, sh - 1) || bn_bit(q, 0))) { q = bn_add(q, [1]); };
    };
    if (bn_bits(q) > 53) {
        q = bn_shr(q, 1);
        lsb += 1;
    };
    let v = 0;
    foreach (i in [2, 1, 0]) {
        v = v * (LMASK + 1) + (if (i < q.length) { q[i] } else { 0 });
    };
    let bits = 0;
    if (v >= 4503599627370496) {
        if (lsb + 52 > 1023) { return if (a.neg) { 0.0 - math.inf } else { math.inf }; };
        bits = ((lsb + 52 + 1023) << 52) | (v - 4503599627370496);
    } else {
        bits = v;
    };
    if (a.neg) { bits = bits | (1 << 63); };
    math.bitsf(bits)
};

def neg(a: BF) -> BF { { neg: !a.neg, m: a.m, e: a.e } };

def abs(a: BF) -> BF { { neg: false, m: a.m, e: a.e } };

// The exponent of the top bit (a.e + bits - 1); a very small number for zero.
def top(a: BF) -> long { if (is_zero(a)) { -9223372036854775807 } else { a.e + bn_bits(a.m) - 1 } };

def add(a: BF, b: BF) -> BF {
    if (is_zero(a)) { return b; };
    if (is_zero(b)) { return a; };
    // far apart: the smaller is below every kept bit, so it only nudges a tie
    if (top(a) - top(b) > PREC + 64) { return round_to(a.neg, a.m, a.e, PREC, true); };
    if (top(b) - top(a) > PREC + 64) { return round_to(b.neg, b.m, b.e, PREC, true); };
    let e = if (a.e < b.e) { a.e } else { b.e };
    let am = bn_shl(a.m, a.e - e);
    let bm = bn_shl(b.m, b.e - e);
    if (a.neg == b.neg) { return bf(a.neg, bn_add(am, bm), e); };
    let c = bn_cmp(am, bm);
    if (c == 0) { bf_zero() } else if (c > 0) { bf(a.neg, bn_sub(am, bm), e) } else { bf(b.neg, bn_sub(bm, am), e) }
};

def sub(a: BF, b: BF) -> BF { add(a, neg(b)) };

def mul(a: BF, b: BF) -> BF { bf(a.neg != b.neg, bn_mul(a.m, b.m), a.e + b.e) };

def mul_long(a: BF, s: long) -> BF { mul(a, from_long(s)) };

// a / s for 0 < s < 2^30
def div_small(a: BF, s: long) -> BF {
    if (is_zero(a)) { return a; };
    let sh = PREC + 40 - bn_bits(a.m);
    if (sh < 0) { sh = 0; };
    let inexact = [false];
    let q = bn_div_small(bn_shl(a.m, sh), s, inexact);
    round_to(a.neg, q, a.e - sh, PREC, inexact[0])
};

// a * 2^k
def ldexp(a: BF, k: long) -> BF { { neg: a.neg, m: a.m, e: a.e + k } };

// a scaled into [1, 2): the scale is a's top exponent
def unit(a: BF) -> BF { { neg: a.neg, m: a.m, e: 0 - (bn_bits(a.m) - 1) } };

def recip(b: BF) -> BF {
    let t = top(b);
    let u = abs(unit(b));
    let x = from_double(1.0 / to_double(u));
    let two = from_long(2);
    for i in 0..4 { x = mul(x, sub(two, mul(u, x))); };
    let r = ldexp(x, 0 - t);
    if (b.neg) { neg(r) } else { r }
};

def div(a: BF, b: BF) -> BF { mul(a, recip(b)) };

/** The square root of s >= 0. */
def sqrt(s: BF) -> BF {
    if (is_zero(s)) { return s; };
    let t = top(s);
    let k = if (t >= 0) { t / 2 } else { 0 - ((1 - t) / 2) };
    let u = ldexp(s, 0 - 2 * k);
    let y = from_double(1.0 / math.sqrt(to_double(u)));
    let three = from_long(3);
    for i in 0..4 { y = div_small(mul(y, sub(three, mul(u, mul(y, y)))), 2); };
    ldexp(mul(u, y), k)
};

def cmp(a: BF, b: BF) -> long {
    let d = sub(a, b);
    if (is_zero(d)) { 0 } else if (d.neg) { -1 } else { 1 }
};

// ── constants and arctangent ─────────────────────────────────────────────

// atan(1/n) by its series, every step a division by a small integer.
def atan_inv(n: long) -> BF {
    let term = div_small(from_long(1), n);
    let total = term;
    let k = 1;
    let go = true;
    while (go) {
        term = div_small(term, n * n);
        let add_ = div_small(term, 2 * k + 1);
        if (is_zero(add_) || top(add_) < top(total) - PREC - 8) {
            go = false;
        } else {
            total = if (k % 2 == 1) { sub(total, add_) } else { add(total, add_) };
            k += 1;
        };
    };
    total
};

let PI_: [BF] = [];
let TAN_PI_8: [BF] = [];

/** pi, by Machin: 16 atan(1/5) - 4 atan(1/239). */
def pi() -> BF {
    if (PI_.length == 0) {
        PI_ += sub(mul_long(atan_inv(5), 16), mul_long(atan_inv(239), 4));
        TAN_PI_8 += sub(sqrt(from_long(2)), from_long(1));
    };
    PI_[0]
};

/** arctangent, by two exact identities and the alternating series:
atan(t) = pi/2 - atan(1/t) for |t| > 1, pi/4 + atan((t-1)/(t+1)) for
tan(pi/8) < t <= 1, so the series only sees |t| <= tan(pi/8). */
def atan(t: BF) -> BF {
    let p = pi();
    let a = abs(t);
    let one = from_long(1);
    let r = bf_zero();
    if (cmp(a, one) > 0) {
        r = sub(ldexp(p, -1), atan(recip(a)));
    } else if (cmp(a, TAN_PI_8[0]) > 0) {
        r = add(ldexp(p, -2), atan(div(sub(a, one), add(a, one))));
    } else {
        let a2 = mul(a, a);
        let term = a;
        let total = a;
        let k = 1;
        let go = !is_zero(a);
        while (go) {
            term = neg(mul(term, a2));
            let add_ = div_small(term, 2 * k + 1);
            if (is_zero(add_) || top(add_) < top(total) - PREC - 8) {
                go = false;
            } else {
                total = add(total, add_);
                k += 1;
            };
        };
        r = total;
    };
    if (t.neg) { neg(r) } else { r }
};

export { BF, PREC, from_double, to_double, from_long, add, sub, mul, div, div_small, recip, sqrt, atan, pi, neg, abs,
    cmp, is_zero, ldexp };
