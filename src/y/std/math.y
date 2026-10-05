// std/math.y — numbers, in plain Y.
//
//     import math;
//     print(math.gcd(462, 1071));      // 21
//
// WHAT IS HERE, and what is not. Y has no `float` -> `long` conversion and no
// way to read a float's bits, so there is no seed for a Newton iteration and no
// way to pull an exponent out of a double. That makes sqrt, exp, log, pow, sin
// and the rest UNWRITABLE in Y today, not merely unimplemented — they need
// three or four machine primitives this module cannot reach yet. So this file
// is the half that needs none of them:
//
//   - integers and bits: min max abs clamp sign gcd lcm isqrt popcount ctz clz
//     next_pow2, and mul_mod / pow_mod / inv_mod (modulus up to 2^31, where a
//     reduced product cannot overflow a long — see mul_mod);
//   - floats: fmin fmax fabs fsign lerp is_nan is_inf is_finite, the constants,
//     and nan / inf;
//   - random numbers: SplitMix64 and xoshiro256** / xoshiro256+ over a `[long]`
//     the caller owns, so a stream is reproducible from its seed;
//   - whole-array work over `[float]`: fsum fsum_kahan fdot fmin_of fmax_of
//     fscale faxpy fmean fvariance.
//
// NO OVERLOADING. Y is monomorphic, so min/max/abs/clamp/sign are `long` and
// the float versions carry an `f`: math.min takes two longs, math.fmin two
// floats. Same reason there is no `sqrt` here yet — it would be a name with no
// body.
//
// Nothing in this file allocates unless it says so: the array walks are
// index-by-index over the caller's own array, and the only heap use is the
// `[long]` a caller passes in for the generators.

// ── integers ────────────────────────────────────────────────────────────────

def min(a: long, b: long) -> long {
    if (a < b) { a } else { b }
};

def max(a: long, b: long) -> long {
    if (a > b) { a } else { b }
};

// |x|. NOTE: abs of the most negative long wraps back to itself (there is no
// larger long), exactly as in C.
def abs(x: long) -> long {
    if (x < 0) { 0 - x } else { x }
};

def clamp(x: long, lo: long, hi: long) -> long {
    if (x < lo) { lo } else if (x > hi) { hi } else { x }
};

// -1, 0 or 1.
def sign(x: long) -> long {
    if (x > 0) { 1 } else if (x < 0) { 0 - 1 } else { 0 }
};

// The greatest common divisor, always >= 0; gcd(0, 0) is 0.
def gcd(a: long, b: long) -> long {
    let x = abs(a);
    let y = abs(b);
    while (y != 0) {
        let t = x % y;
        x = y;
        y = t;
    };
    x
};

// The least common multiple, always >= 0; lcm(0, x) is 0. Dividing first
// keeps the product from overflowing a long more often than it must.
def lcm(a: long, b: long) -> long {
    let x = abs(a);
    let y = abs(b);
    if (x == 0 || y == 0) {
        0
    } else {
        (x / gcd(x, y)) * y
    }
};

// floor(sqrt(n)) for n >= 0, 0 for a negative n. A binary search over the
// answer, comparing `mid <= n / mid` so the square never has to be formed and
// cannot overflow; 32 steps, and isqrt is not on any hot path.
def isqrt(n: long) -> long {
    if (n < 2) {
        if (n < 0) { 0 } else { n }
    } else {
        let lo = 0;
        let hi = 3037000499;          // floor(sqrt(2^63 - 1))
        while (lo < hi) {
            // the upper midpoint, so the loop always shrinks
            let mid = lo + (hi - lo + 1) / 2;
            if (mid <= n / mid) { lo = mid; } else { hi = mid - 1; };
        };
        lo
    }
};

// The number of set bits. Counted a word at a time rather than a bit at a time:
// about ten operations instead of sixty-four. The masks are the classic
// SWAR constants, and the final multiply cannot overflow because every byte of
// `v` is at most 8 by then.
def popcount(x: long) -> long {
    let v = x;
    v = v - ((v >> 1) & 6148914691236517205);        // 0x5555...: pairs
    v = (v & 3689348814741910323) + ((v >> 2) & 3689348814741910323);   // 0x3333...
    v = (v + (v >> 4)) & 1085102592571150095;        // 0x0f0f...: nibbles
    (v * 72340172838076673) >> 56                    // 0x0101...: sum them
};

// Trailing zeros: 64 for 0 (there is no other answer). Counted on the
// two's-complement form, so a negative x is counted like its unsigned
// counterpart — which is why the shift is ARITHMETIC here: it keeps the sign
// bit, and a logical shift would bring in zeros from the left and count the
// wrong end.
def ctz(x: long) -> long {
    if (x == 0) {
        64
    } else {
        let n = 0;
        let v = x;
        while ((v & 1) == 0) {
            n = n + 1;
            v = v >> 1;
        };
        n
    }
};

// Leading zeros in the 64-bit word: 63 for 1, 0 for a negative x, 64 for 0.
// Shifting left until the sign bit appears counts them.
def clz(x: long) -> long {
    if (x == 0) {
        64
    } else {
        let n = 0;
        let v = x;
        while (v >= 0) {
            n = n + 1;
            v = v << 1;
        };
        n
    }
};

// The smallest power of two that is >= x: 1 for x <= 1. There is no power of
// two above 2^62 in the long range, so an x past that gives 0.
def next_pow2(x: long) -> long {
    if (x <= 1) {
        1
    } else {
        let v = x - 1;
        v = v | (v >> 1);
        v = v | (v >> 2);
        v = v | (v >> 4);
        v = v | (v >> 8);
        v = v | (v >> 16);
        v = v | (v >> 32);
        let r = v + 1;
        if (r <= 0) { 0 } else { r }  // wrapped: past 2^62
    }
};

// (a * b) mod m, for 0 < m <= 2147483647 (2^31-1).
//
// Why the modulus is bounded: a and b are first reduced into [0, m), so the
// product is below (2^31)^2 = 2^62 and cannot overflow a long — which is why
// this is three lines and not a 128-bit multiplication. Past 2^31 the product
// would overflow and the answer would be silently wrong; the caller is
// expected to stay inside the bound (std/crypto.y keeps its bignum limbs to 30
// bits for the same reason). A modulus of 0 or less gives 0.
def mul_mod(a: long, b: long, m: long) -> long {
    if (m <= 0) {
        0
    } else {
        let x = a % m;
        let y = b % m;
        // Y's % follows the dividend's sign, so fold the negatives up
        let xr = if (x < 0) { x + m } else { x };
        let yr = if (y < 0) { y + m } else { y };
        (xr * yr) % m
    }
};

// b^e mod m, for 0 < m <= 2147483647, by repeated squaring through mul_mod.
// A negative exponent gives 0: inverting the base is inv_mod's job, not this
// function's.
def pow_mod(b: long, e: long, m: long) -> long {
    if (m <= 0 || e < 0) {
        0
    } else {
        let base = b % m;
        let b0 = if (base < 0) { base + m } else { base };
        let acc = 1 % m;
        let k = e;
        while (k > 0) {
            if ((k & 1) == 1) { acc = mul_mod(acc, b0, m); };
            b0 = mul_mod(b0, b0, m);
            k = k >> 1;
        };
        acc
    }
};

// The inverse of a modulo m, for 0 < m <= 2147483647 and gcd(a, m) = 1, by
// the extended Euclidean algorithm; 0 when there is no inverse. The Bezout
// coefficient stays inside [-m, m], so the running products fit a long.
def inv_mod(a: long, m: long) -> long {
    if (m <= 0) {
        0
    } else {
        let r0 = a % m;
        let r1 = m;
        let s0 = 1;
        let s1 = 0;
        let r0a = if (r0 < 0) { r0 + m } else { r0 };
        let go = true;
        while (go) {
            if (r1 == 0) {
                go = false;
            } else {
                let q = r0a / r1;
                let t = r0a - q * r1;
                r0a = r1;
                r1 = t;
                let u = s0 - q * s1;
                s0 = s1;
                s1 = u;
            };
        };
        if (r0a != 1) {
            0
        } else {
            let s = s0 % m;
            if (s < 0) { s + m } else { s }
        }
    }
};

// ── floats ──────────────────────────────────────────────────────────────────

// The smaller of two, with C's rule that a NaN loses to the other operand:
// fmin(NaN, 2.0) is 2.0. (Which of -0.0 and 0.0 wins is not specified;
// IEEE says either is correct.)
def fmin(a: float, b: float) -> float {
    if (a != a) { b } else if (b != b) { a } else if (a < b) { a } else { b }
};

def fmax(a: float, b: float) -> float {
    if (a != a) { b } else if (b != b) { a } else if (a > b) { a } else { b }
};

// |x| as a float. Written so that -0.0 comes back as +0.0 (0.0 - (-0.0) is
// +0.0), which a sign-bit test would also do; a NaN passes through.
def fabs(x: float) -> float {
    if (x <= 0.0) { 0.0 - x } else { x }
};

// -1.0, 0.0 or 1.0. A NaN gives 0.0.
def fsign(x: float) -> float {
    if (x > 0.0) { 1.0 } else if (x < 0.0) { 0.0 - 1.0 } else { 0.0 }
};

// The linear blend a + (b - a) * t: 0.0 gives a, 1.0 gives b.
def lerp(a: float, b: float, t: float) -> float {
    a + (b - a) * t
};

// True only for a NaN. Written as the self-inequality, which is the one test
// that is true for NaN and nothing else.
def is_nan(x: float) -> bool {
    x != x
};

// True for a finite x (neither an infinity nor a NaN). x - x is 0.0 for every
// finite x and a NaN for an infinity, so one comparison settles both.
def is_finite(x: float) -> bool {
    x - x == 0.0
};

// True for either infinity, and false for a NaN.
def is_inf(x: float) -> bool {
    if (is_nan(x)) { false } else { !is_finite(x) }
};

// The constants. Each is the double nearest the mathematical value, written as
// the shortest decimal that round-trips, so a program prints what C prints.
let pi: float = 3.141592653589793;
let e: float = 2.718281828459045;
let tau: float = 6.283185307179586;
let ln2: float = 0.6931471805599453;
let ln10: float = 2.302585092994046;
let sqrt2: float = 1.4142135623730951;
let phi: float = 1.618033988749895;

// NaN and infinity, made the only way Y can make them: IEEE arithmetic on zero
// is quiet, so no trap and no builtin. (Integer division by zero DOES trap.)
let nan: float = 0.0 / 0.0;
let inf: float = 1.0 / 0.0;

// ── the machine primitives, and the exact layer built on them ────────────────
//
// Everything below this point needs a float's bits or a double-to-long cast,
// which Y has no spelling for: `native def` names the assembly that does it
// (src/y/arch/math.s, the four functions) and the rest is ordinary Y. A
// `native def` is a promise about a label that nothing here can check, so
// these four are the whole trust boundary -- the shapes below are exact.

native def sqrt(x: float) -> float = "y_sqrt";
native def raw_to_int(x: float) -> long = "y_to_int";
native def fbits(x: float) -> long = "y_fbits";
native def bitsf(b: long) -> float = "y_bitsf";
// The trap the checked cast stops at (a message and an exit; the machine cast
// itself cannot report the case, it answers with LONG_MIN).
native def int_trap() -> long = "y_int_trap";

// 2^63, the smallest double no long holds: the boundary every truncating cast
// below checks against. It cannot be written as a literal -- its integer part
// does not fit a long, and Y builds a float literal from one -- so it is the
// product that is exact anyway.
let two63: float = 4611686018427387904.0 * 2.0;

// The sign bit of a double's bit pattern, as a long: 2^63, which is one past
// the largest long and so cannot be spelled. The minimum long added to a
// pattern does not have it carries into the top bit, which SETS the sign;
// clearing it again is a subtraction, so the two helpers below are one each and
// nothing depends on writing 2^63.
def sign_bit() -> long {
    0 - 9223372036854775807 - 1
};

// The sign bit CLEARED: a pattern that has it comes back to its magnitude.
def without_sign(b: long) -> long {
    if (b < 0) { b + sign_bit() } else { b }
};

// 2^52: adding k of these to a double's bits adds k to its exponent FIELD.
// This is the whole of ldexp and one step of exp's range reduction, and it has
// to be a long, because a float times a long is a float and there is no way
// back.
//
// The field carries a BIAS of 1023, so adding k to it scales by 2^k exactly --
// 1.0's pattern 0x3FF0000000000000 + 2^52 is 0x4000000000000000, which is 2.0.
let two52: long = 4503599627370496;

// The 11-bit exponent field of a double, as a long.
def exp_field(x: float) -> long {
    (fbits(x) >>> 52) & 2047
};

// C's (float) -> long: the integer part, truncated toward zero. A NaN, an
// infinity, or a magnitude past the largest long has no answer, and the cast
// cannot say so -- it gives back LONG_MIN for all three, which is a perfectly
// good number and would sail on as one. So they are checked here and stop the
// program with a message that says what happened.
def to_int(x: float) -> long {
    if (x != x) {
        int_trap()
    } else if (x >= two63 || x < 0.0 - two63) {
        int_trap()
    } else {
        raw_to_int(x)
    }
};

// floor(x): the greatest integer <= x. to_int truncates, so a negative x is one
// too high exactly when it had a fractional part; the zero case returns x
// itself so that floor(-0.0) is -0.0 and not +0.0 (C preserves the sign).
def floor(x: float) -> float {
    if (x != x || x >= two63 || x < 0.0 - two63) {
        x
    } else if (x == 0.0) {
        x
    } else {
        // a long widens to a float implicitly (one cvtsi2sd), which is the
        // conversion bitsf is NOT: that one reinterprets the bits
        let t: float = raw_to_int(x);
        if (t > x) { t - 1.0 } else { t }
    }
};

// ceil(x): the least integer >= x, with the same zero rule.
def ceil(x: float) -> float {
    if (x != x || x >= two63 || x < 0.0 - two63) {
        x
    } else if (x == 0.0) {
        x
    } else {
        let t: float = raw_to_int(x);
        if (t < x) { t + 1.0 } else { t }
    }
};

// trunc(x): the integer part with the fractional part dropped -- what to_int
// gives, as a float, keeping the sign of a zero.
def trunc(x: float) -> float {
    if (x != x || x >= two63 || x < 0.0 - two63) {
        x
    } else if (x == 0.0) {
        x
    } else {
        let t: float = raw_to_int(x);
        t
    }
};

// round(x): the nearest integer, halves away from zero (C's round, not the
// current rounding mode and not rint).
def round(x: float) -> float {
    let t = trunc(x);
    if (x != x || x >= two63 || x < 0.0 - two63) {
        x
    } else {
        let d = x - t;
        if (d >= 0.5) { t + 1.0 } else if (d <= -0.5) { t - 1.0 } else { t }
    }
};

// fract(x): the fractional part, with x's sign (C's fract).
def fract(x: float) -> float {
    x - trunc(x)
};

// is_signed_zero(x): true for -0.0, which no comparison can see.
def is_signed_zero(x: float) -> bool {
    x == 0.0 && (fbits(x) >>> 63) == 1
};

// frexp(x) -> [long]: x as a pair, the fraction's BITS and the exponent, with
// the fraction in [0.5, 1) (and 0 for a zero or a subnormal input, so the pair
// always satisfies ldexp(bitsf(frexp(x)[0]), frexp(x)[1]) == x exactly). Bits
// rather than a float because the fraction is a dyadic rational: this is the
// one conversion with no rounding in it at all.
def frexp(x: float) -> [long] {
    if (x != x || x == 0.0 || is_inf(x)) {
        [fbits(x), 0]
    } else {
        // a subnormal has no implicit leading bit, so it needs normalizing
        // before the exponent field can be read off
        let r = x;
        let guard = 0;
        while (guard < 60 && exp_field(r) == 0 && r != 0.0) {
            r = r * 2.0;
            guard = guard + 1;
        };
        let e = exp_field(r);
        if (e == 0) {
            [fbits(0.0), 0]
        } else {
            // The fraction in [0.5, 1) is this mantissa at exponent 1022 --
            // in bits, because there is no float-to-long conversion here. The
            // SIGN COMES OFF as well and goes back on as the exponent's sign:
            // the field is an 11-bit magnitude, so a negative x's bit pattern
            // would otherwise put a 1 in the top of it and answer with a
            // positive fraction. (C's frexp keeps the sign on the fraction.)
            let frac = ((fbits(r) & 4503599627370495) | 4602678819172646912);
            // the sign bit set: 2^63, which is not a long, so it is the
            // minimum long added to a pattern that does not have it -- which
            // carries into the top bit
            let signed = frac;
            if (x < 0.0) { signed = frac + sign_bit(); };
            [signed, e - 1022 - guard]
        }
    }
};

// ldexp(x, e): x scaled by 2^e, exactly. Scaling by a power of two is exact
// while the result stays normal, and then the exponent field can simply be
// added to; a result that would land in the subnormal range is scaled by halves
// instead, so its mantissa shifts and the answer is the correctly-rounded one.
def ldexp(x: float, e: long) -> float {
    if (x != x || x == 0.0 || is_inf(x)) {
        x
    } else {
        // r is x moved by whole steps, k what is left
        let r = x;
        let k = e;
        // The big steps first, since after them the answer may already be 0 or
        // an infinity and there is nothing left to do exactly. 2^1022 rather
        // than 2^1023: one more step than the range needs, so a step never
        // overflows on its own.
        let up = 1022;
        let down = 0 - 1022;
        while (k >= up) { r = r * 8.98846567431158e307; k = k - up; };
        while (k <= down) { r = r * 2.2250738585072014e-308; k = k - down; };
        // What is left fits the exponent field as long as the answer stays
        // NORMAL; otherwise the mantissa has to shift too, and one doubling at a
        // time is how that is exact (this is also the subnormal-input case: a
        // subnormal has field 0, so every step of it is a doubling).
        let f = exp_field(r);
        if (f == 0 || f + k < 1) {
            let step = if (k < 0) { 0 - 1 } else { 1 };
            let rest = k;
            while (rest != 0) {
                r = r * if (step < 0) { 0.5 } else { 2.0 };
                rest = rest - step;
            }
        } else if (k != 0) {
            // k * 2^52 added to the bits is k added to the exponent FIELD, so
            // the sign comes off first (a negative pattern would put a 1 at the
            // top of the field and scale the wrong way) and goes back on after.
            let b = fbits(r);
            let neg = b < 0;
            let u = without_sign(b);
            let shifted = u + k * 4503599627370496;
            r = bitsf(if (neg) { shifted + sign_bit() } else { shifted });
        };
        r
    }
};

// nextafter(x, y): the next double from x toward y (C's nextafter, which is
// also nexttoward with y as the direction). Equal inputs give y; a NaN gives a
// NaN. The step is one unit in the last place in whichever direction the bits
// move, and the sign is where it crosses zero -- which is why the zero case
// needs the signed-zero test: from +0.0 toward -1.0 the answer is the most
// negative subnormal, not +0.0's neighbour the other way.
def nextafter(x: float, y: float) -> float {
    if (x != x || y != y) {
        nan
    } else if (x == y) {
        y
    } else if (x == 0.0) {
        // from a zero the step is out of the subnormal range: 1 ulp is the
        // smallest double there is, one side or the other
        if (y > x) { bitsf(1) } else { bitsf(0 - 9223372036854775807) }
    } else {
        // One unit in the last place, toward y -- and the direction flips with
        // the sign, because the patterns run the other way for a negative
        // double: -1.0 is 0xBFF0...000 and the next double TOWARD ZERO is
        // 0xBFEFFFFFFFFFFFFF, one SMALLER. So a step toward a larger value is
        // +1 when x is positive and -1 when x is negative.
        let bx = fbits(x);
        let step = 0 - 1;
        if ((bx > 0) == (y > x)) { step = 1; };
        bitsf(bx + step)
    }
};

// cbrt(x): the cube root, by Newton's method on x = y^3 -- three multiplies
// and a divide a step, quadratic convergence, so a seed within a factor of two
// reaches the last bit in a handful of steps.
//
// The reduction is what makes such a seed possible. Newton's iteration on a
// cube root is only locally convergent: from a relative error R it takes
// roughly log2(R) steps to get near, so a seed off by a factor of a^(1/12)
// (the fourth root, which is all sqrt(sqrt(a)) gives) is hopeless for a
// subnormal, where that is 1e27. So the exponent is split into threes first:
// a = m * 2^e with m in [1,2), e = 3q + r, and cbrt(a) = 2^q * cbrt(m * 2^r)
// with the part that needs the iteration inside [1, 8) -- within 17% of the
// answer, which is inside the basin.
def cbrt(x: float) -> float {
    if (x != x || x == 0.0 || is_inf(x)) {
        x
    } else {
        let neg = x < 0.0;
        let a = if (neg) { 0.0 - x } else { x };
        // a subnormal carries no exponent of its own, and 2^54 normalizes even
        // the smallest (2^-1074 * 2^54 = 2^-1020)
        let b = a;
        let sh: long = 0;
        while (exp_field(b) == 0) {
            b = b * 18014398509481984.0;
            sh = sh + 54;
        };
        let e = exp_field(b) - 1023 - sh;
        let q = e / 3;
        let r = e - 3 * q;
        // the mantissa back to [1, 2), in bits: there is no float-to-long cast
        let m = bitsf((fbits(b) & 4503599627370495) | 4607182418800017408);
        let s = ldexp(m, r);
        let y = 1.0 + (s - 1.0) / 3.0;
        let i = 0;
        while (i < 4) {
            y = (2.0 * y + s / (y * y)) / 3.0;
            i = i + 1;
        };
        // The last step in its residual form. A Newton step rebuilds the whole
        // iterate -- three roundings, which do not cancel -- and after four of
        // them the answer sits a few ulps out and stays there. This one
        // corrects the value already in hand by the error the residual
        // measures, and the correction is ~1 ulp, so its own rounding is
        // negligible: the answer lands within an ulp of the true root.
        let y2 = y * y;
        y = y - ((y2 * y - s) / (3.0 * y2));
        let out = ldexp(y, q);
        if (neg) { 0.0 - out } else { out }
    }
};

// hypot(x, y): sqrt(x^2 + y^2) without the overflow. Scaling by the larger
// magnitude first keeps both squares inside the double range (a square overflows
// from 1.3e154), and dividing it back is exact.
def hypot(x: float, y: float) -> float {
    let a = fabs(x);
    let b = fabs(y);
    let m = if (a > b) { a } else { b };
    if (m == 0.0 || m != m || is_inf(m)) {
        if (is_inf(m)) { inf } else { m }
    } else {
        let p = x / m;
        let q = y / m;
        m * sqrt(p * p + q * q)
    }
};

// ── random numbers ──────────────────────────────────────────────────────────
//
// The state is a `[long]` the CALLER owns, so two streams cannot collide by
// accident and a stream is reproducible from its seed: keep the array, replay
// the seed. xoshiro256** and xoshiro256+ want four elements; SplitMix64 one.
// Reading past the end traps, so size the array for the generator you call.
//
// The generators' constants exceed 2^63, so they appear as their negatives —
// the same bits, written so no literal has to be out of range. Every multiply
// below is meant to wrap: that is how these generators mix.

// SplitMix64 (Steele, Lea, Flood 2014): the seeding generator, and a fine one
// to use on its own.
//
// The reference implementation is three statements, and in each one the shift
// is on the value the PREVIOUS line produced — after a multiply, that is the
// product, so both products need a name here:
//
//   z = (x += 0x9e3779b97f4a7c15);
//   z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9;
//   z = (z ^ (z >> 27)) * 0x94d049bb133111eb;
//   return z ^ (z >> 31);
//
// Getting that wrong is quiet: shift the pre-multiply value instead and the
// output still looks like noise, just not SplitMix64's. The shifts are LOGICAL
// (>>>), since the algorithm is defined on unsigned 64-bit values.
//
// The constants are written as `X * (0 - c)` rather than as hex literals: all
// three exceed 2^63 and their signed values are what a long holds, and
// multiplying by the signed value gives the same bits. The multiplies are meant
// to wrap; that is the mixing.
def splitmix64(state: [long]) -> long {
    let z = state[0] + (0 - 7046029254386353131);       // 0x9E3779B97F4A7C15
    state[0] = z;
    let a = z ^ (z >>> 30);
    let m1 = a * (0 - 4658895280553007687);             // 0xBF58476D1CE4E5B9
    let b = m1 ^ (m1 >>> 27);
    let m = b * (0 - 7723592293110705685);              // 0x94D049BB133111EB
    m ^ (m >>> 31)
};

// x <<< k | x >>> (64 - k), for 1 <= k <= 63.
def rotl(x: long, k: long) -> long {
    (x << k) | (x >>> (64 - k))
};

// Fill a four-element state from one seed with SplitMix64, the standard way: all
// four words are genuine outputs, so the state is never all zeros (which xoshiro
// could never leave). Returns the first word of the new state.
def seed_xoshiro256(state: [long], seed: long) -> long {
    let st: [long] = [seed];
    state[0] = splitmix64(st);
    state[1] = splitmix64(st);
    state[2] = splitmix64(st);
    state[3] = splitmix64(st);
    state[0]
};

// xoshiro256** 1.0 (Blackman, Vigna): the all-rounder.
def xoshiro256pp(state: [long]) -> long {
    let s1 = state[1];
    let result = rotl(s1 * 5, 7) * 9;
    let t = s1 << 17;
    state[2] = state[2] ^ state[0];
    state[3] = state[3] ^ s1;
    state[1] = s1 ^ state[2];
    state[0] = state[0] ^ state[3];
    state[2] = state[2] ^ t;
    state[3] = rotl(state[3], 45);
    result
};

// xoshiro256+ 1.0: the faster of the two, for callers that take the tiny
// correlation between the raw output and the state.
def xoshiro256ss(state: [long]) -> long {
    let s1 = state[1];
    let result = state[0] + state[3];
    let t = s1 << 17;
    state[2] = state[2] ^ state[0];
    state[3] = state[3] ^ s1;
    state[1] = s1 ^ state[2];
    state[0] = state[0] ^ state[3];
    state[2] = state[2] ^ t;
    state[3] = rotl(state[3], 45);
    result
};

// A double in [0, 1) from 53 random bits: the top 53 bits scaled by 2^-53,
// which is exact in a double, so every value is a multiple of 2^-53 and 1.0
// is never produced.
def rand_unit(state: [long]) -> float {
    (xoshiro256pp(state) >>> 11) * 1.1102230246251565e-16      // 2^-53
};

// A long in [0, n), for 0 < n <= 2^62, with no modulo bias: draws 62 bits and
// rejects the tail above the largest multiple of n, so all n values are
// equally likely. n <= 0, or an n too large to divide into, gives 0.
def rand_range(state: [long], n: long) -> long {
    if (n <= 0 || n > 4611686018427387904) {
        0
    } else {
        let cut = (4611686018427387904 / n) * n;   // largest multiple of n that fits
        let r = 0;
        let go = true;
        while (go) {
            r = xoshiro256pp(state) >>> 2;         // 62 bits, always >= 0
            if (r < cut) { go = false; };
        };
        r % n
    }
};

// ── whole arrays of floats ──────────────────────────────────────────────────
//
// These walk the caller's array in place, so they cost no allocation and the
// bounds check on every read is the language's, not theirs. A length mismatch
// between two arrays traps rather than quietly reading the shorter one.

// The plain sum, in order. Fine for well-conditioned data; see fsum_kahan.
def fsum(a: [float]) -> float {
    let s = 0.0;
    let i = 0;
    let n = len(a);
    while (i < n) {
        s = s + a[i];
        i = i + 1;
    };
    s
};

// The sum with Neumaier compensation: the running total carries a correction
// for the bits that fell off the end, so the error stays near one ulp of the
// total however long the array is. About four times the work of fsum; worth it
// for money, and for any sum of many terms.
def fsum_kahan(a: [float]) -> float {
    let s = 0.0;
    let c = 0.0;
    let i = 0;
    let n = len(a);
    while (i < n) {
        let x = a[i];
        let t = s + x;
        if (fabs(s) >= fabs(x)) {
            c = c + ((s - t) + x);
        } else {
            c = c + ((x - t) + s);
        };
        s = t;
        i = i + 1;
    };
    s + c
};

// The dot product of two equal-length arrays.
def fdot(a: [float], b: [float]) -> float {
    let s = 0.0;
    let i = 0;
    let n = len(a);
    while (i < n) {
        s = s + a[i] * b[i];
        i = i + 1;
    };
    s
};

// The smallest element, or NaN for an empty array.
def fmin_of(a: [float]) -> float {
    if (len(a) == 0) {
        nan
    } else {
        let m = a[0];
        let i = 1;
        while (i < len(a)) {
            if (a[i] < m) { m = a[i]; };
            i = i + 1;
        };
        m
    }
};

// The largest element, or NaN for an empty array.
def fmax_of(a: [float]) -> float {
    if (len(a) == 0) {
        nan
    } else {
        let m = a[0];
        let i = 1;
        while (i < len(a)) {
            if (a[i] > m) { m = a[i]; };
            i = i + 1;
        };
        m
    }
};

// a *= k, in place.
def fscale(a: [float], k: float) -> void {
    let i = 0;
    while (i < len(a)) {
        a[i] = a[i] * k;
        i = i + 1;
    }
};

// y += k * x, in place, over equal-length arrays: the axpy of numerical
// linear algebra, which is how a vector is accumulated without allocating.
def faxpy(y: [float], k: float, x: [float]) -> void {
    let i = 0;
    while (i < len(y)) {
        y[i] = y[i] + k * x[i];
        i = i + 1;
    }
};

// The arithmetic mean, or NaN for an empty array.
def fmean(a: [float]) -> float {
    if (len(a) == 0) {
        nan
    } else {
        fsum(a) / len(a)
    }
};

// The sample variance (dividing by n - 1), by the two-pass method: the mean
// first, then the mean squared deviation from it. The one-pass form would need
// a correction this module has no way to express (a compensated sum of squares
// is a few more lines — fsum_kahan again). NaN for fewer than two elements.
def fvariance(a: [float]) -> float {
    if (len(a) < 2) {
        nan
    } else {
        let m = fmean(a);
        let s = 0.0;
        let i = 0;
        while (i < len(a)) {
            let d = a[i] - m;
            s = s + d * d;
            i = i + 1;
        };
        s / (len(a) - 1)
    }
};