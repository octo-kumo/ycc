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
//     fscale faxpy fmean fvariance. The loops are the six kernels in
//     src/y/arch/math.s (`sum_asm` and friends), each bit-identical to the Y
//     loop kept next to it as `*_y`; `bench/y/fmath.y` measures them at 0.37
//     ns an element against 1.26 for the Y loop.
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
// fmin(NaN, 2.0) is 2.0.
//
// Which of -0.0 and 0.0 wins used to be "not specified", and the strict `<`
// made it DEPEND ON THE ORDER: fmin(+0.0, -0.0) was -0.0 and fmin(-0.0, +0.0) was
// +0.0. C99 does allow either, so the table said nothing -- and a table case
// then said the opposite of what the module did. On a tie the negative-signed
// operand wins, which is IEEE 754-2019's minNum and what this platform's libm
// does: 1.0/fmin(-0.0, 0.0) has to be -inf.
def fmin(a: float, b: float) -> float {
    if (a != a) {
        b
    } else if (b != b) {
        a
    } else if (a < b) {
        a
    } else if (b < a) {
        b
    } else {
        // a == b, so the only thing left undecided is the two zeros' signs --
        // and for every other tie the two are the same number anyway.
        if (fbits(a) < 0) { a } else if (fbits(b) < 0) { b } else { a }
    }
};

// The same, the other way round: on a tie the POSITIVE-signed operand wins, so
// fmax(0.0, -0.0) is 0.0. The strict `>` it used to have returned -0.0 here,
// which is not a defensible answer from a maximum: 1.0/fmax(0.0, -0.0) came
// out -inf.
def fmax(a: float, b: float) -> float {
    if (a != a) {
        b
    } else if (b != b) {
        a
    } else if (a > b) {
        a
    } else if (b > a) {
        b
    } else {
        if (fbits(a) < 0) { b } else { a }
    }
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
// -0.0, which no literal spells (Y writes -1.0 as a unary minus, and
// 0.0 - 0.0 is +0.0 by IEEE). Declared HERE rather than beside fmin/fmax,
// which is where it was, because atan2's both-zeros arm needs it and Y's
// names are not hoisted: a binding declared later is an undefined variable
// where it is written.
let neg_zero: float = 0.0 * (0.0 - 1.0);

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

// The six bulk kernels over `[float]` (src/y/arch/math.s). Each takes the
// array's DATA POINTER and its length, not the array: the header is four words
// and the elements live elsewhere (NATIVE.md, "Arrays"), so the caller hands
// over `a.ptr` and `len(a)`. Each is bit-identical to the Y loop it replaces --
// the wrappers below keep those in `*_y` form, and t310 checks the two agree
// over a corpus -- which is what makes the asm a drop-in rather than a second
// opinion.
native def sum_asm(p: *float, n: long) -> float = "y_sum";
native def dot_asm(p: *float, q: *float, n: long) -> float = "y_dot";
native def scale_asm(p: *float, n: long, k: float) -> void = "y_scale";
native def axpy_asm(y: *float, n: long, k: float, x: *float) -> void = "y_axpy";
native def min_of_asm(p: *float, n: long) -> float = "y_min_of";
native def max_of_asm(p: *float, n: long) -> float = "y_max_of";

// exp, in assembly (src/y/arch/math.s). Bit-identical to the Y `exp_y` below --
// the same multiplies and subtracts in the same order, the same split kernel,
// the same ldexp -- and t311 checks that over 10,420 arguments. The routine is
// GENERATED by test/math/gen_exp.py, which reads this module's constants: the
// table cannot be retyped without anything noticing, and a retyped table is
// exactly how the two would stop agreeing.
native def exp_asm(x: float) -> float = "y_exp";

// log, in assembly, the same way (src/y/arch/math.s, generated by
// test/math/gen_log.py). Bit-identical to the Y `log_y` below; t312 checks that
// over 10k arguments.
native def log_asm(x: float) -> float = "y_log";

// sin and cos, in assembly (src/y/arch/math.s), one routine for both: it
// computes both halves of sin_cos_k and picks by the quadrant, which is what the Y
// does with the pair it returns. Bit-identical to the Y `sin_y`/`cos_y` below;
// t313 checks that over 10k arguments each. The routine is GENERATED by
// test/math/gen_sin.py.
native def sin_asm(x: float) -> float = "y_sin";
native def cos_asm(x: float) -> float = "y_cos";
// pow takes two arguments, so with the convention that pushes them in source
// order the LAST is the one at 8(%rsp) and the base is at 16(%rsp).
native def pow_asm(x: float, y: float) -> float = "y_pow";

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
        while (k >= up) { r = r * 4.49423283715578977e307; k = k - up; };
        while (k <= down) { r = r * 2.2250738585072014e-308; k = k - down; };
        // A big step can have already carried r out of the range -- to an
        // infinity on the way up, to zero on the way down -- and then there is
        // nothing left to do exactly. It has to be CHECKED for, because the
        // shift below adds k to the exponent FIELD, and on an infinity that
        // field is already 2047: the sum overflows a signed long, wraps, and
        // comes back as a NEGATIVE NaN. ldexp(1.0, 2046) answered
        // -nan where the answer is +inf, through exactly that.
        if (r == 0.0 || is_inf(r)) {
            r
        } else {
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
        } else if (f + k >= 2047) {
            // Field 2047 is inf/NaN, so the answer has left the range: an
            // infinity carrying r's sign. This arm exists for the same reason as
            // the check above, and for the case that one does not cover -- r can
            // still be finite here while the answer is not, which is exactly
            // ldexp(2.47, 1024): the big step leaves 1.11e308, the field is
            // 2046, and adding k = 2 carries it to 2047. Shifted as bits that
            // is a long overflow, which wraps and comes back as a NEGATIVE
            // NaN. Only k > 0 reaches here, since f is at most 2046.
            //
            // Assigned rather than returned: this chain's arms all write `r` and
            // the block's value is thrown away, which the compiler says so --
            // "the result of '-' is not used" -- and it was right.
            r = if (r < 0.0) { 0.0 - inf } else { inf };
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
// 2^(r/3) for the three values of r the exponent split produces: the cube roots
// of 1, 2 and 4, each correctly rounded.
let cbrt_pow3: [float] = [1.0, 1.2599210498948732, 1.5874010519681994];

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
        // e = 3q + r with r one of 0, 1, 2 -- and integer division truncates
        // toward zero, so a negative exponent comes out with r = -1 and the
        // index below is out of range
        let q = e / 3;
        let r = e - 3 * q;
        if (r < 0) {
            q = q - 1;
            r = r + 3;
        };
        // the mantissa back to [1, 2), in bits: there is no float-to-long cast
        let m = bitsf((fbits(b) & 4503599627370495) | 4607182418800017408);
        let s = ldexp(m, r);
        // The seed has to be within reach of Newton, and a cube root's iteration
        // is only locally convergent: from a relative error e it takes about
        // log(1.5/e) steps to arrive, and from the 60% that seeding on s itself
        // gives (s is as large as 8) it never does -- cbrt(7.5) came out 1e-12
        // out, and the ulp table had no argument that showed it. So the seed is
        // cbrt(m) -- one Newton step from 1, and 3% out because m is in [1, 2) --
        // times 2^(r/3), which puts it inside 4% whatever the argument is.
        let y = (1.0 + (m - 1.0) / 3.0) * cbrt_pow3[r];
        let i = 0;
        while (i < 4) {
            y = (2.0 * y + s / (y * y)) / 3.0;
            i = i + 1;
        };
        // The last step, and the only one that has to be RIGHT rather than close.
        // Four plain Newton steps converge to about 4e-19 of relative error --
        // far below an ulp -- but each of them is three roundings that do not
        // cancel, so what they converge TO is a value a couple of ulps out, and
        // they stay there: measured over 2000 arguments, cbrt was exact on half,
        // one ulp out on 46% and TWO on 3.5%.
        //
        // The correction step fixes that, and it has to be done in
        // double-double. y^3 - s cancels completely -- y^3 is within an ulp of s
        // by the time we get here -- so the subtraction returns a residual with
        // an ulp of ABSOLUTE error in it, and dividing that by 3y^2 turns the
        // absolute error into 0.7 ulp of y. The correction is therefore wrong
        // by about an ulp of its own, which is the 2.
        //
        // So the residual is assembled from the parts: prod_err gives back what
        // each product lost, and two_sum subtracts without losing anything.
        // What is left of the residual is then good to about 2^-104 of it, the
        // correction to well under an ulp, and the final subtraction rounds
        // once -- which is as close to correctly rounded as a double can be
        // stated to be.
        let y2 = y * y;
        let y3 = y2 * y;
        let y3_err = (prod_err(y, y, y2) * y) + prod_err(y2, y, y3);
        let r_hi = two_sum(y3, 0.0 - s);
        let r_lo = (y3 - r_hi) - s;
        y = y - ((r_hi + (r_lo + y3_err)) / (3.0 * y2));
        let out = ldexp(y, q);
        if (neg) { 0.0 - out } else { out }
    }
};

// hypot(x, y): sqrt(x^2 + y^2) without the overflow. Scaling by the larger
// magnitude first keeps both squares inside the double range (a square overflows
// from 1.3e154), and dividing it back is exact.
// C99 7.12.7.3 and IEEE 754-2019 both give hypot(+-inf, NaN) = +inf, and glibc
// agrees: an infinity is the larger of the two and the other operand cannot
// matter. `m` is the larger magnitude and a NaN never wins that comparison, so
// the check for an infinity has to come BEFORE the NaN arm rather than beside it
// -- hypot(inf, nan) answered nan where the answer is inf.
def hypot(x: float, y: float) -> float {
    let a = fabs(x);
    let b = fabs(y);
    // The infinity has to be found by looking for one, not by taking the larger
    // of the two: every comparison against a NaN is false, so `if (a > b) a else
    // b` hands back the NaN whenever one operand is one, and the infinity it was
    // supposed to be dominated is never seen. That is why hypot(inf, nan) came
    // out nan -- and why the check below had nothing to find.
    if (is_inf(a) || is_inf(b)) {
        inf
    } else if (a != a || b != b) {
        nan
    } else if (a > b) {
        // Scaling by the larger magnitude is what keeps this from overflowing
        // where a plain sqrt(x*x + y*y) would, so the comparison has to be a real
        // one -- which it is, the NaN having been ruled out two arms above.
        hypot_scaled(a, b)
    } else {
        hypot_scaled(b, a)
    }
};

// The body of hypot, with the larger magnitude named `m` and the other `s`.
//
// Two arguments and not three, deliberately: my first attempt passed the
// maximum in as well, to keep a branch from needing it -- and then took the
// maximum from the WRONG place in one of the two calls, so hypot(3.5, 0)
// answered 0.0 where the answer is 3.5. A name that is passed in separately from
// the one it is derived from can disagree with it; one that is not cannot.
def hypot_scaled(m: float, s: float) -> float {
    if (m == 0.0) {
        // both operands are zeros, and the answer is +0: hypot is never
        // negative, so hypot(0.0, -0.0) is +0 whichever zero came second.
        0.0
    } else {
        let p = s / m;
        // BOTH squares, not 1.0 + p*p. The one-square form is the same identity
        // and a different number: with m = 3 and s = 2, p = 2/3 and 1 + p*p
        // rounds once BEFORE the sqrt, so the two forms differ by up to an ulp
        // and disagree on which side.
        //
        // This is worth being exact about, because I "simplified" it to
        // 1.0 + p*p, checked the two Pythagorean triples that are exact (3,4,5
        // and 5,12,13), saw them pass, and almost committed it. hypot(2.0, 3.0)
        // is not one of those: p = 2/3 does not square-and-add back to 1
        // exactly, so the 1.0 form rounds it. Both forms give the same answer for
        // 3,4 and for 1,1 -- which is what a form that is only SOMETIMES wrong
        // looks like, and is why the check has to be on an argument where the two
        // forms disagree.
        //
        // Neither form is correctly rounded in general: hypot(2.0, 3.0) is one
        // ulp above the correctly rounded sqrt(13) in both, and so it was before
        // any of this. That is a known limit of the scaled form rather than a
        // defect of it -- the table pins what hypot does, and making it correctly
        // rounded would mean a second-pass correction, which is a different piece
        // of work from the two corner cases here. Recorded in t325.
        let q = m / m;
        m * sqrt(p * p + q * q)
    }
};

// ── the transcendentals ────────────────────────────────────────────────────
//
// Every kernel below is written in the shape that makes an ulp reachable:
//
//     2^r   = 1 + r*(1 + r*Q(r))          exp
//     log m = z*(2 + z^2*P(z^2))          log, z = (m-1)/(m+1)
//     sin x = x*(1 + x^2*P(x^2))          sin, atan
//     cos x = 1 - x^2*P(x^2)              cos
//
// so the polynomial is only ever the CORRECTION to a term already in hand, and
// its error reaches the answer multiplied by the argument's square or cube
// rather than standing on its own. That is half the accuracy. The other half
// is that every coefficient is split in two and the low parts are carried in a
// second accumulator: plain Horner rounds once a term, so a degree-n kernel
// sits n ulps out and stays there, while p + q with q tracking what p lost is
// the sum to a small fraction of an ulp. The split costs one multiply and one
// add a term and nothing at all in the constants.
//
// test/math/gen_kernel.py fits the coefficients, prints them as the literals
// below, and reports the error of the split evaluation in ulps of the answer
// (about one ulp of the kernel for each, which the factorisation is what turns
// into a fraction of an ulp here).

def poly_split(co: [float], clo: [float], w: float) -> float {
    let n = len(co) - 1;
    let p = co[n];
    let q = clo[n];
    let i = n - 1;
    while (i >= 0) {
        p = p * w + co[i];
        q = q * w + clo[i];
        i = i - 1;
    };
    p + q
};

// exp's kernel, in r, for |r| <= ln2/2: the Taylor values 1/(n+2)!
let exp_k: [float] = [0.5, 0.16666666666666666, 0.041666666666666664,
    0.008333333333333333, 0.0013888888888888978, 0.00019841269841252215,
    2.4801587303802537e-05, 2.755731903759997e-06, 2.755732994359045e-07,
    2.5051685923955133e-08, 2.0887964071930685e-09, 1.5868300911899847e-10,
    1.3336404122592556e-11];
let exp_kl: [float] = [2.731824807595654e-26, 9.251831897791138e-18,
    2.317267918780335e-18, -1.5735622740938769e-19, 5.097412265283907e-20,
    1.3140192523087737e-20, 8.921709691222807e-22, -6.87290497175393e-23,
    -1.12468925587968e-23, 1.1649605174557337e-24, -1.2128533042289473e-25,
    3.918194843020948e-27, 2.939928092011524e-28];

// log's kernel, in w = z^2, for |z| <= sqrt(2)-1: the series 2/(2k+3)
let log_k: [float] = [0.6666666666666666, 0.4, 0.2857142857142857,
    0.22222222222221846, 0.1818181818192055, 0.15384615368426527,
    0.13333334927545218, 0.11764605236538342, 0.10530385543195436,
    0.0942220876984394, 0.1010869079759298];
let log_kl: [float] = [3.700743479264591e-17, -2.220970871676104e-17,
    2.298767463628977e-17, -1.3705113992684887e-17, -8.334567856350977e-18,
    -1.3094359941278366e-17, 2.4799585998467566e-18, -5.575584781284454e-18,
    -1.2444148727046784e-18, 9.130001461195338e-19, 2.779086897805733e-18];

// sin's kernel, in w = x^2, for |x| <= pi/4: -1/6 + x^2/120 - ...
let sin_k: [float] = [-0.16666666666666666, 0.008333333333330948,
    -0.00019841269836758574, 2.755731610255244e-06, -2.5051131845003624e-08,
    1.5918129294866608e-10];
let sin_kl: [float] = [1.1179358334940806e-17, 5.126396701520949e-19,
    -7.318524662312664e-21, 1.2526205035687516e-22, -1.632387720195767e-25,
    7.64860958890575e-27];

// cos's kernel, in w = x^2, for |x| <= pi/4: 1/2 - x^2/24 + ...
let cos_k: [float] = [0.5, -0.041666666666666664, 0.0013888888888888883,
    -2.4801587301578204e-05, 2.755731921819105e-07, -2.0876754983065435e-09,
    1.1470361263661415e-11, -4.74108669850752e-14];
let cos_kl: [float] = [-9.927204987228577e-23, -2.2923648485442405e-18,
    -1.0382692687352548e-19, -2.1862916859764185e-22, 3.4594728796697634e-25,
    -1.3403058423097282e-25, -6.070140715638571e-28, -1.3300480612299751e-30];

// sinh's kernel, in w = x^2, for |x| <= 0.5: sinh x = x*(1 + w*P(w)).
// expm1 is the exp kernel on its own, and sinh is (expm1(x) - expm1(-x))/2,
// which is this shape with the even terms halved -- so the coefficients are the
// Taylor values 1/(2k+3)!.
let sinh_k: [float] = [0.16666666666666666, 0.008333333333333333,
    0.0001984126984126984, 2.7557319223985943e-06, 2.5052108385358744e-08,
    1.6059043907616352e-10, 7.647130272730548e-13, 2.8196895216099014e-15];
let sinh_kl: [float] = [9.251858534705814e-18, 1.1565019634686237e-19,
    7.071825259067978e-24, 1.2480102547401166e-23, 1.5339941984694534e-24,
    1.1738184850031472e-26, -2.7025335984982047e-29, 1.7918268050249534e-31];

// ── the same three kernels, unrolled ──────────────────────────────────────────
//
// poly_split above is the general form, and it is what every other kernel in
// this module uses. These three are the ones a PROGRAM runs -- expm1, exp2,
// log1p, pow, and sinh and cosh past 709 -- so they are written out.
//
// The reason is the cost of an array read in this compiler: TWELVE
// instructions, of which four are loop-invariant. It reloads the array record
// from the frame, reloads its length, bounds-checks the index against it,
// reloads the data pointer, and only then loads the element. Two accesses an
// iteration is twenty-four instructions to do two multiply-adds. Measured with
// callgrind, poly_split is 890 instructions a call and 56% of expm1's total;
// the arithmetic it performs is two multiply-adds and an add, which is about
// 160.
//
// There is no cheaper way to write the loop: Y has no pointer arithmetic (a
// *T can be dereferenced but not indexed) and no unrolling, so an indexed
// access costs twelve however the loop is written. The only way out is to have
// no index.
//
// Generated by test/math/gen_split_unroll.py, which READS the arrays above
// rather than restating them -- a coefficient's low half lives in its
// sixteenth digit, and a second copy of these numbers is a second thing to
// keep in step. t321_split_unrolled.y is the gate: it asks both forms the same
// question over a spread and requires the same bits, so the two cannot drift.

// exp_k -- used by expm1, exp2_corr, exp_half.
// exp_k's kernel, UNROLLED. Generated by test/math/gen_split_unroll.py
// from the arrays in this file; do not retype it. See that script for why, and
// t321_split_unrolled.y for the gate that says the two forms agree to the bit.
//
// The order is the loop's, exactly: p starts at the highest coefficient and
// works down, which is Horner's rule and the only order that gives the split
// evaluation its accuracy. Same operations, same sequence, no array.
def poly_exp(w: float) -> float {
    let p = 1.3336404122592556e-11;
    let q = 2.939928092011524e-28;
    p = p * w + 1.5868300911899847e-10;
    q = q * w + 3.918194843020948e-27;
    p = p * w + 2.0887964071930685e-09;
    q = q * w - 1.2128533042289473e-25;
    p = p * w + 2.5051685923955133e-08;
    q = q * w + 1.1649605174557337e-24;
    p = p * w + 2.755732994359045e-07;
    q = q * w - 1.12468925587968e-23;
    p = p * w + 2.755731903759997e-06;
    q = q * w - 6.87290497175393e-23;
    p = p * w + 2.4801587303802537e-05;
    q = q * w + 8.921709691222807e-22;
    p = p * w + 0.00019841269841252215;
    q = q * w + 1.3140192523087737e-20;
    p = p * w + 0.0013888888888888978;
    q = q * w + 5.097412265283907e-20;
    p = p * w + 0.008333333333333333;
    q = q * w - 1.5735622740938769e-19;
    p = p * w + 0.041666666666666664;
    q = q * w + 2.317267918780335e-18;
    p = p * w + 0.16666666666666666;
    q = q * w + 9.251831897791138e-18;
    p = p * w + 0.5;
    q = q * w + 2.731824807595654e-26;
    p + q
};

// log_k -- used by log1p, log2_dd.
// log_k's kernel, UNROLLED. Generated by test/math/gen_split_unroll.py
// from the arrays in this file; do not retype it. See that script for why, and
// t321_split_unrolled.y for the gate that says the two forms agree to the bit.
//
// The order is the loop's, exactly: p starts at the highest coefficient and
// works down, which is Horner's rule and the only order that gives the split
// evaluation its accuracy. Same operations, same sequence, no array.
def poly_log(w: float) -> float {
    let p = 0.1010869079759298;
    let q = 2.779086897805733e-18;
    p = p * w + 0.0942220876984394;
    q = q * w + 9.130001461195338e-19;
    p = p * w + 0.10530385543195436;
    q = q * w - 1.2444148727046784e-18;
    p = p * w + 0.11764605236538342;
    q = q * w - 5.575584781284454e-18;
    p = p * w + 0.13333334927545218;
    q = q * w + 2.4799585998467566e-18;
    p = p * w + 0.15384615368426527;
    q = q * w - 1.3094359941278366e-17;
    p = p * w + 0.1818181818192055;
    q = q * w - 8.334567856350977e-18;
    p = p * w + 0.22222222222221846;
    q = q * w - 1.3705113992684887e-17;
    p = p * w + 0.2857142857142857;
    q = q * w + 2.298767463628977e-17;
    p = p * w + 0.4;
    q = q * w - 2.220970871676104e-17;
    p = p * w + 0.6666666666666666;
    q = q * w + 3.700743479264591e-17;
    p + q
};

// sinh_k -- used by sinh_small.
// sinh_k's kernel, UNROLLED. Generated by test/math/gen_split_unroll.py
// from the arrays in this file; do not retype it. See that script for why, and
// t321_split_unrolled.y for the gate that says the two forms agree to the bit.
//
// The order is the loop's, exactly: p starts at the highest coefficient and
// works down, which is Horner's rule and the only order that gives the split
// evaluation its accuracy. Same operations, same sequence, no array.
def poly_sinh(w: float) -> float {
    let p = 2.8196895216099014e-15;
    let q = 1.7918268050249534e-31;
    p = p * w + 7.647130272730548e-13;
    q = q * w - 2.7025335984982047e-29;
    p = p * w + 1.6059043907616352e-10;
    q = q * w + 1.1738184850031472e-26;
    p = p * w + 2.5052108385358744e-08;
    q = q * w + 1.5339941984694534e-24;
    p = p * w + 2.7557319223985943e-06;
    q = q * w + 1.2480102547401166e-23;
    p = p * w + 0.0001984126984126984;
    q = q * w + 7.071825259067978e-24;
    p = p * w + 0.008333333333333333;
    q = q * w + 1.1565019634686237e-19;
    p = p * w + 0.16666666666666666;
    q = q * w + 9.251858534705814e-18;
    p + q
};

// asin's kernel, in z = s^2 where s = sqrt((1-|x|)/2), for |x| >= 1/2:
//   asin(s) = s * (1 + z*P(z)),  s <= 1/2,  z <= 1/4
// The coefficients are the Taylor values C(2k,k)/(4^k(2k+1)) -- the same
// rationals as sinh_k's, one step further out the same series -- so there is
// nothing to fit: `test/math/gen_kernel.py`'s asinexact is the same function
// and this is where its answer went.
//
// TWENTY-FOUR terms, and that many is the price of the branch: the series in z
// converges at the rate z itself, which is a quarter at the wide end, so each
// pair of terms buys sixteen and the kernel's own error has to be under an ulp
// of pi/2. Measured over the branch, 20 terms leave the answer eight ulps out,
// 22 bring it to one, and 24 leave the same one with room for arguments the
// sweep did not land on -- which is why this is 24 and not 22.
let asin_k: [float] = [0.16666666666666666, 0.075, 0.044642857142857144,
    0.030381944444444444, 0.022372159090909092, 0.017352764423076924,
    0.01396484375, 0.011551800896139705, 0.009761609529194078,
    0.008390335809616815, 0.0073125258735988454, 0.006447210311889649,
    0.005740037670841924, 0.005153309682319905, 0.004660143486915096,
    0.004240907093679363, 0.003880964558837669, 0.0035692053938259347,
    0.003297059503473485, 0.0030578216492580306, 0.002846178401108942,
    0.00265787063820729, 0.0024894486782468836, 0.002338091892111975];
let asin_kl: [float] = [9.25185853854297e-18, 2.7755575615628915e-18,
    -9.912705577010326e-19, 3.854941057726238e-19, -9.462128050782583e-19,
    -8.006416042969879e-19, -6.938893903907229e-19, 8.163404592832033e-19,
    5.478074134663601e-19, 4.130293990420969e-19, -3.394024192128536e-19,
    -3.1225022567582527e-19, -1.2849803525754126e-19,
    -3.888173308223878e-19, -2.7979410902851727e-20,
    -1.5770213417970974e-19, 1.858632295689436e-19, -1.992587776459846e-19,
    -1.3344026738283132e-19, 2.1155164341180575e-20, 1.1094161764967953e-19,
    -1.4456028966473392e-19, -8.304527278612374e-20, 1.4161007967157608e-19];

// atan's kernel, in w = x^2, for |x| <= tan(pi/16): -1/3 + x^2/5 - ...
let atan_k: [float] = [-0.3333333333333333, 0.19999999999999993,
    -0.14285714285711518, 0.11111111110754729, -0.0909090906700999,
    0.07692306736000173, -0.06666642020055166, 0.058819252531928636,
    -0.05258041554297779, 0.04719395030027433, -0.04104436265755082,
    0.030635704112969498, -0.01391822929102443];
let atan_kl: [float] = [-1.8460804868732022e-17, -1.2412890980869873e-17,
    -9.117255197712884e-18, 5.543908691009074e-18, 3.2367055693560028e-18,
    2.0770998309350174e-19, 1.1005125683727358e-18, 7.262660180568933e-20,
    -3.3012079965004468e-18, -1.6495772479263127e-18, 3.9114739913559e-19,
    -9.585660105097796e-19, 8.107241888605798e-19];

// tanh's kernel, in w = x^2, for |x| <= 1/2: tanh(x) = x * (1 + w*P(w)). Its
// Taylor values are -1/3, 2/15, -17/315 ... and gen_kernel.py fits degree 11
// over the branch, reporting 0.000 ulp on it -- so this is the generator's own
// answer, taken rather than retyped, and the low halves are in its sixteenth
// digits.
//
// It was generated all along and never wired up: tanh computed its whole range
// through expm1, which is 921 instructions a call, for a function whose answer
// never leaves [-1, 1]. Below half a turn the exponential is 12 terms of x, and
// the polynomial is what this is. Above half a turn the answer saturates and
// expm1 is the right tool.
let tanh_k: [float] = [    -0.3333333333333333, 0.1333333333333333, -0.05396825396824835, 0.02186948853573452,
    -0.0088632355135931, 0.0035921276627198383, -0.0014558289383351634, 0.0005899749383754306,
    -0.00023878930525840224, 9.544524503270839e-05, -3.514809431531453e-05, 8.859223816010494e-06];
let tanh_kl: [float] = [    -1.8478204982087523e-17, 2.0567422250775412e-19, -2.3526628565235765e-18, 7.693071686990699e-20,
    -3.2466436398817353e-19, 7.850248823563098e-20, 8.262874090553728e-20, -2.952117193543854e-20,
    1.1908734347773113e-20, -2.7056059682285524e-21, -3.1405714554962816e-21, 5.515287351054736e-22];

// tanh_k -- used by tanh_small.
// tanh_k's kernel, UNROLLED. Generated by test/math/gen_split_unroll.py
// from the arrays in this file; do not retype it. See that script for why, and
// t321_split_unrolled.y for the gate that says the two forms agree to the bit.
//
// The order is the loop's, exactly: p starts at the highest coefficient and
// works down, which is Horner's rule and the only order that gives the split
// evaluation its accuracy. Same operations, same sequence, no array.
def poly_tanh(w: float) -> float {
    let p = 8.859223816010494e-06;
    let q = 5.515287351054736e-22;
    p = p * w + -3.514809431531453e-05;
    q = q * w - 3.1405714554962816e-21;
    p = p * w + 9.544524503270839e-05;
    q = q * w - 2.7056059682285524e-21;
    p = p * w + -0.00023878930525840224;
    q = q * w + 1.1908734347773113e-20;
    p = p * w + 0.0005899749383754306;
    q = q * w - 2.952117193543854e-20;
    p = p * w + -0.0014558289383351634;
    q = q * w + 8.262874090553728e-20;
    p = p * w + 0.0035921276627198383;
    q = q * w + 7.850248823563098e-20;
    p = p * w + -0.0088632355135931;
    q = q * w - 3.2466436398817353e-19;
    p = p * w + 0.02186948853573452;
    q = q * w + 7.693071686990699e-20;
    p = p * w + -0.05396825396824835;
    q = q * w - 2.3526628565235765e-18;
    p = p * w + 0.1333333333333333;
    q = q * w + 2.0567422250775412e-19;
    p = p * w + -0.3333333333333333;
    q = q * w - 1.8478204982087523e-17;
    p + q
};

// log2(e), and ln2 in two pieces. ln2_hi's low 21 bits are zero, so k*ln2_hi
// is exact for every k a reduction produces and x - k*ln2_hi is exact too (the
// difference is about 0.35 of x, which fits in the bits x has): that is what
// Cody-Waite reduction is, and without it the answer would be off by half an ulp
// a unit in the exponent.
let log2e: float = 1.4426950408889634073599246810018921374266459541529859;
let ln2_hi: float = 6.93147180369123816490e-01;
let ln2_lo: float = 1.90821492927058770002e-10;

// 2/pi, and pi/2 in FOUR pieces, for the same reason as ln2 (see the note on
// ln2_hi): each piece has its low bits zeroed, in turn 21 and then 32, so
// multiplying one by an integer keeps the bits the next piece holds. Together
// they are pi/2 to about fifty digits -- which is what sin(pi) needs, since the
// double nearest pi is 1.2e-16 away from it and the answer there is that
// 1.2e-16, so a reduction good to 1e-26 is already a hundred-thousand ulps
// out.
let two_over_pi: float = 6.36619772367581382433e-01;
let pio2_1: float = 1.57079632673412561417e+00;
let pio2_1t: float = 6.07710050650619224932e-11;
let pio2_2: float = 3.521558281080194e-27;
let pio2_2t: float = 1.5841030061604075e-33;

// log10's two constants and 1/log(2) for the two bases.
let log10e: float = 0.43429448190325182765112891891660508229439700580366656;
let log10_2: float = 0.30102999566398119521373889472449302676818988146210854;
let inv_ln2: float = 1.4426950408889634073599246810018921374266459541529859;
// 1/ln2 as two parts, and the second one is not decoration: pow's exponent is
// the logarithm times this, so the 1.4e-17 that the rounded constant is off by
// becomes 7e-15 of an exponent of 500 -- which is 60 ulps of the answer, for
// nothing more than rounding a constant.
let inv_ln2_lo: float = 2.0355273740931033e-17;

// The exact error of the product a*b, given p = a*b. Dekker's split: break
// both factors at bit 26, recombine, and what is left is the rounding the
// product lost. It needs no fused multiply-add, which this machine has no
// instruction for, and it is exact for every magnitude here (all well below
// 2^996, so no scaling).
def prod_err(a: float, b: float, p: float) -> float {
    let ca = 134217729.0 * a;
    let ah = ca - (ca - a);
    let al = a - ah;
    let cb = 134217729.0 * b;
    let bh = cb - (cb - b);
    let bl = b - bh;
    ((ah * bh - p) + ah * bl + al * bh) + al * bl
};

// n mod 4, as 0, 1, 2 or 3. C's % keeps the sign of the dividend, so a
// negative quadrant count comes out negative and the table below has to be
// written for that; normalising it here is one comparison instead of four.
def quadrant(n: long) -> long {
    let q = n % 4;
    if (q < 0) { q + 4 } else { q }
};

// x - n*pi/2, with n = round(x*2/pi), reduced to [-pi/4, pi/4].
//
// Two things make this exact rather than nearly so. pio2_1 has its low 21 bits
// zero, so n*pio2_1 is an exact product and x - n*pio2_1 is an exact
// difference -- the argument minus n whole half-turns, with every bit below
// 2^-21 of it intact. And n*pio2_1t is not exact, so its rounding error is
// taken out with prod_err and subtracted last: a last subtraction of a much
// smaller number rounds to the answer's own ulp, which is the best a reduction
// can do. Without that last step, sin(pi) is off by 300000 ulps -- the
// argument pi leaves a remainder of 1.2e-16, and two pieces of pi/2 leave an
// error of 7e-27 in it, which is a hundred-thousandth of the answer.
def rem_pio2(x: float, n: long) -> float {
    let nf: float = n;
    let p1 = nf * pio2_1;
    let p1t = nf * pio2_1t;
    let p2 = nf * pio2_2;
    let p2t = nf * pio2_2t;
    // Two of the four products can round, and both are compensated: n*pio2_1
    // needs more than 53 bits once n passes 2^21, and n*pio2_1t once n passes
    // 2^10. The other two are 3.5e-27 and below, where the rounding is some
    // twenty orders of magnitude under the answer's last bit however large n
    // grows -- which is why there are two prod_err calls here and not four.
    let err = prod_err(nf, pio2_1, p1) + prod_err(nf, pio2_1t, p1t);
    ((((x - p1) - p1t) - p2) - p2t) - err
};

// Where exp overflows and where it flushes to zero: exp(709.78) is the last
// finite double below 2^1024, and exp(-745.14) the smallest above 2^-1075.
let exp_hi: float = 709.782712893383996093;
let exp_lo: float = -745.133219101941074020;

// 1/sqrt(2): log's fraction is brought into [1/sqrt2, sqrt2) so the kernel's
// |z| stays at sqrt(2)-1.
let inv_sqrt2: float = 0.70710678118654752440;

// exp2's reduction multiplies the fractional part by ln2, which is the
// constant in the public list above -- the same double, so the two-part
// `ln2_hi`/`ln2_lo` split is for the *whole* multiples of it only, and
// declaring ln2 again here would silently shadow the public one.

// Where sin, cos and tan stop having an answer at all: the quadrant must fit a
// long, and past 9.9999999999995904e18 it does not, so the reduction cannot be
// performed. That number is not 2^63*(pi/2) = 1.4488038916154245e19 as one would
// guess, because the reduction computes floor(x*2/pi + 0.5) and the +0.5
// carries the quotient over the edge a third of the way sooner. Hence a
// function rather than a constant, below: it asks on the expression itself, so
// it cannot be off by however much the arithmetic turns out to be.
//
// It is NOT the boundary of accuracy, and the difference is worth being exact
// about, because an earlier version of this note claimed 2^53*(pi/2) = 1.41e16
// and that was wrong by a factor of a thousand. Measured over 3000 arguments
// per decade, the gap to libm grows with the argument and there is no sharp
// edge: at |x| <= 1e8 sin and cos are within 1 ulp of every one of 3000, at
// 1e10 three are not, at 1e12 four are, at 1e14 eleven are, at 1e13 a cos is 11
// ulps out. The reason there is no edge is that the quotient round(x*2/pi) is
// one rounded product, and whether that rounding carries it across the
// half-integer boundary depends on where x*2/pi happens to fall for that
// particular x -- a property of the argument, not a bound on it. sin(1e15) is
// exact; sin(1e18) is -3.7e18 where the truth is -0.993.
//
// So the honest description is: within 1 ulp for the arguments small enough
// that the quotient is exact, degrading gradually above that, and NaN past this
// constant. Closing the gap needs libm's multi-precision reduction (a
// three-word quotient), which is a piece of work in its own right and not a
// patch. t320 measures the degradation and pins the NaN region.
// And the test itself, on the very expression to_int will be handed, so the two
// cannot be off by one double relative to each other. A constant boundary was
// tried first and was wrong: at 1.4488038916154243e19 -- one ulp BELOW the
// constant, and the largest argument whose quadrant does fit -- the product
// x*two_over_pi rounds UP to exactly 2^63, the +0.5 carries it past, and to_int
// traps. Asking the question the same way to_int asks it is the only version
// that cannot drift.
def pio2_fits(x: float) -> bool {
    let q = x * two_over_pi + 0.5;
    q < 9223372036854775807.0 && q > 0.0 - 9223372036854775807.0
};

// pi/4 and pi/2: below pi/4 an argument needs no reduction at all, and atan
// of an infinity is pi/2.
let pi_over_4: float = 0.78539816339744830961;
let pi_over_2: float = 1.57079632679489661923;

// tan(pi/8) and pi/8: atan's reduction takes |x| down to the first of these,
// and the pi/8 it adds back is the identity's own constant.
let tan_pi_8: float = 0.41421356237309504880;
let atan_max: float = 0.41421356237309504880;
let pi_over_8: float = 0.39269908169872415481;

// ── exp ────────────────────────────────────────────────────────────────────

// exp(x): e^x. The argument is split as k*ln2 + r, the kernel computes e^r in
// [0.707, 1.414), and 2^k goes back on by adding to the exponent field -- which
// is exact, so the whole answer is as accurate as the kernel and the reduction.
def exp(x: float) -> float {
    exp_asm(x)
};

// exp_half(a) = e^a / 2, for the strip where e^a itself is out of range.
//
// cosh(a) = e^a/2 + e^-a/2 and sinh(a) = e^a/2 - e^-a/2, so both are e^a/2 up
// to a term that is 0.0 to a double past a = 709. That makes their whole
// upper strip the same problem, and the same fix: exp's argument split is
// a = k*ln2 + r, and the answer is ldexp(e^r, k). cosh needs k one LARGER than
// exp would give it -- because cosh's answer is a factor of two smaller than
// exp's -- and ldexp applies the scale without ever forming 2^k, so k = 1024
// is fine where exp(a) was inf.
//
// This is exp's own n > 1023 arm (see exp_y) run one step further, with the
// factor of two moved out of f2 and into the exponent, which is the same
// operation stated differently and the reason the two agree everywhere exp can
// reach. NOT exp(a/2) squared: that squares exp's own 1-ulp error and lands 2
// ulp out at the top, which is the bug this replaces.
//
// Not exported: only sinh and cosh have a use for it.
def exp_half(x: float) -> float {
    // The bound FIRST, before the reduction. It has to be: the reduction ends
    // in to_int(floor(x*log2e + 0.5)), and at x = 1e300 that is a float with no
    // integer part a long holds -- a trap, where the answer is plainly inf.
    // Testing the bound after reducing means every overflowing argument traps
    // instead of answering, which is the bug in a second costume.
    //
    // Tested on x and not on n, because n = round(x*log2e) steps at 1025 and
    // 1026 -- far too coarse to place an edge that falls inside one of its
    // steps: at x = 710.5 the answer is inf and n is still 1025. ldexp cannot
    // be left to find the edge either, being exact on a kernel below 2, so it
    // rounds the overflow into an answer instead of overflowing.
    //
    // So the edge is x itself. The exact value of e^x/2 = DBL_MAX is at
    // x = ln(2*DBL_MAX) = 710.475860073943863..., and the answer SURVIVES one
    // double past that, because it has to survive being rounded: the largest
    // finite argument is 710.47586007394386 (libm answers
    // 1.7976931348621744e+308 there, one ulp under DBL_MAX) and the first
    // argument with no answer at all is 710.47586007394398. Hence the test is
    // at the second of those two.
    //
    // Getting this wrong by one double is not a rounding curiosity: it is the
    // difference between sinh answering the largest double there is and
    // answering inf for an argument where an answer exists.
    if (x >= 710.47586007394398) {
        inf
    } else {
        let n: long = to_int(floor(x * log2e + 0.5));
        let nf: float = n;
        // r as two halves of ln2, exactly as exp does it, so the reduction keeps
        // every bit of a large x -- the alternative, exp(x - ln2), throws away
        // the low bits of 710 and lands about 250 ulp out.
        //
        // The kernel is evaluated at r and the answer scaled by n - 1, so a
        // factor of two stays INSIDE, which is the whole of it: e^a/2 =
        // 2^(n-1) * e^r, and ldexp applies the scale without ever forming 2^n,
        // so the intermediate that overflows in exp is never formed here. Same
        // kernel, same reduction, one step down -- which is why the two agree to
        // the bit on every argument exp can also answer.
        let r = (x - nf * ln2_hi) - nf * ln2_lo;
        ldexp(1.0 + r * (1.0 + r * poly_exp(r)), n - 1)
    }
};

// The Y exp, as `exp_asm` computes it: the oracle for the kernel, and the shape
// to read to know what the assembly is doing. Not exported.
def exp_y(x: float) -> float {
    if (x != x) {
        x
    } else if (x > exp_hi) {
        inf
    } else if (x < exp_lo) {
        0.0
    } else {
        let n: long = to_int(floor(x * log2e + 0.5));
        let nf: float = n;
        let r = (x - nf * ln2_hi) - nf * ln2_lo;
        // The top of the range: 2^1024 is an overflow, and round(x*log2e)
        // reaches 1024 for every x above 709.4. So the last whole ln2 stays in
        // r -- which keeps r inside the kernel's range, the way the reduction
        // meant it to -- and its factor of two goes in by hand.
        let k: long = n;
        let f2 = 1.0;
        if (n > 1023) { k = n - 1; f2 = 2.0; };
        ldexp(f2 * (1.0 + r * (1.0 + r * poly_split(exp_k, exp_kl, r))), k)
    }
};

// exp2(x): 2^x. exp(x*ln2) would be one multiply and a lost ulp -- the product
// rounds before exp sees it -- so the exponent is split in whole units here and
// only the fraction goes through ln2: 2^x = 2^k * e^((x-k)*ln2), with the kernel
// still seeing |r| <= ln2/2 and the one multiply costing a fortieth of an ulp.
def exp2(x: float) -> float {
    if (x != x) {
        x
    } else if (x > 1024.0) {
        inf
    } else if (x < -1075.0) {
        0.0
    } else {
        let n = floor(x + 0.5);
        let r = (x - n) * 0.6931471805599453094172321214581765680755001343602553;
        // as exp: 2^1024 is an overflow, so the last unit's factor is in by hand
        let k = to_int(n);
        let f2 = 1.0;
        if (n > 1023.0) { k = k - 1; f2 = 2.0; };
        ldexp(f2 * (1.0 + r * (1.0 + r * poly_exp(r))), k)
    }
};

// ── log ────────────────────────────────────────────────────────────────────

// The cell two_sum leaves its exact residual in. It is declared HERE rather than
// beside two_sum because the first thing that reads it is asin's, and a `let`
// has to be in hand before the text that names it: a `def` may be called before
// its body is checked, a cell may not.
let ts_lo: float = 0.0;

// z = (m-1)/(m+1) with m in [1/sqrt2, sqrt2), and the low part of the quotient
// left in z_lo. m-1 is exact (Sterbenz) and the division rounds once, but m+1
// rounds too and its error is half an ulp of 2 -- a whole ulp of z, which would
// be the whole budget. two_sum gives the denominator's residual and one more
// divide turns it into z's.
let z_lo: float = 0.0;

def log_z(m: float) -> float {
    let num = m - 1.0;
    let den = m + 1.0;
    let bb = den - m;
    let derr = (m - (den - bb)) + (1.0 - bb);
    let z = num / den;
    z_lo = 0.0 - (z * derr) / den;
    z
};

// log(x), x > 0. frexp splits x = f*2^e with f in [0.5, 1); f is doubled into
// [1/sqrt2, sqrt2) when it is below 1/sqrt2, which keeps |z| at sqrt(2)-1 and
// the kernel short. The two halves of the answer -- the small z part and the
// large e*ln2 -- are each computed to their own scale and added last.
def log(x: float) -> float {
    log_asm(x)
};

// The Y log, as `log_asm` computes it: the oracle for the kernel, and the shape
// to read to know what the assembly is doing. Not exported.
def log_y(x: float) -> float {
    if (x != x || x < 0.0) {
        nan
    } else if (x == 0.0) {
        0.0 - inf
    } else if (is_inf(x)) {
        inf
    } else {
        let p = frexp(x);
        let m = bitsf(p[0]);
        let e: long = p[1];
        if (m < inv_sqrt2) {
            m = m * 2.0;
            e = e - 1;
        };
        let z = log_z(m) + z_lo;
        let w = z * z;
        let ef: float = e;
        (z * (2.0 + w * poly_split(log_k, log_kl, w))) + (ef * ln2_hi) + (ef * ln2_lo)
    }
};

// 1/ln2 and 1/ln10, each in two pieces. A single double for a reciprocal this
// size is short by up to half an ulp, so log(x) * that constant rounds twice and
// the answer can be 2 ulps out before log's own error is counted. The table found
// it: log2(7.8166428423182364) came out 2 ulps from the true value where libm is
// exact, on an ordinary argument, in a function the one-ulp promise names by
// name. log2 had NINE pinned cases and log10 had NINE MORE -- the thinnest
// coverage in the table -- and a spread uniform in the DECADES found it in a
// minute, which is the argument for a spread stated four times now.
//
// The split carries about 150 bits, against the 106 a double-double holds.
// GENERATED as hi/lo pairs from a 90-digit computation, because typing them is
// how the first attempt got one of them wrong: a hand-written log10(2) tail
// was off by a factor of EIGHT, and every test that followed it was an exact
// power of ten, where the tail does not show at all. Same lesson as the
// polynomial kernels' low halves, and the same reason gen_kernel.py exists.
let log2e_hi: float = 1.4426950408889634;
let log2e_lo: float = 2.0355273740931033e-17;
// TWO constants, and confusing them is a bug that was made here: log10's answer
// is built from two terms with two different scalings.
//
//     log10(x) = e * log10(2)  +  ln(m) * log10(e)
//
// The first term's e is the BASE 2 exponent (the reduction splits x = m*2^e), so
// it is scaled by log10(2). The second term is a NATURAL logarithm -- the z
// series gives ln(m) -- so it is scaled by log10(e) = 1/ln10. Scaling both by
// log10(2) answers a different function: it gave log10(0.75) as 0.1307 instead
// of -0.1249, which is 2.8e15 ulps out and would have been caught by any
// ordinary case.
let log10e_hi: float = 0.4342944819032518;
let log10e_lo: float = 1.098319650216765e-17;
let log10_2_hi: float = 0.3010299956639812;
let log10_2_lo: float = -2.8037281277851704e-18;

// log2(x) = e + log2(m), for x = m * 2^e with m in [1/sqrt2, sqrt2). The
// integer e is EXACT and is not multiplied by anything, so the kernel's error
// lands on the answer instead of being amplified by 1.4427.
//
// That is the whole fix, and getting to it took one wrong turn worth recording.
// The functions used to be `log(x) * (1/ln2)`, which is what C's do, and the
// table reported them 2 ulps out on ordinary arguments with libm exact on all
// of them. The first thing blamed was the constant -- a single rounded double
// for a reciprocal is short by half an ulp, so the product rounds twice -- and
// splitting it into hi and lo with prod_err and two_sum recovering the error was
// correct, necessary, and changed NOTHING. Because log itself is 1 ulp out on
// 6 of 9 arguments tried (within its own promise, and 0 ulp for libm on all 9),
// and multiplying a 1-ulp error by 1.4427 makes it up to 2. Compensating a
// multiply cannot repair an operand that is already wrong; that is worth knowing
// before reaching for it.
//
// What is left uncounted below is the rounding of L*clo alone, which is about
// 2^-106 of L because clo is 2^-53 of chi. The final ef + small rounds once, at
// the size of the ANSWER, so the whole thing is correctly rounded except in a
// near-tie.
// x = m * 2^e with m in [0.5, 1), for x > 0 finite: frexp without frexp.
//
// frexp returns a two-element ARRAY, and a call that allocates is 146
// instructions where this is about forty -- a program calling log2 in a loop
// pays that on every call, and the allocation is most of what costs, not the
// arithmetic. A subnormal still normalises first, exactly as frexp does, because
// it has no implicit leading bit to read an exponent from.
//
// x > 0 and finite is a precondition here, so the sign dance frexp needs does
// not apply: both callers have already answered NaN below zero and for the
// infinities. The exponent comes back in split_e because Y has no tuples --
// which is why frexp returns an array in the first place.
let split_e: long = 0;

def split_mantissa(x: float) -> float {
    let r = x;
    let ef = exp_field(r);
    // The doublings have to come OFF the exponent. A subnormal has no implicit
    // leading bit, so normalising it doubles it until it has one -- and then
    // r is 2^guard larger than x, so the exponent read off r is guard too
    // large. frexp subtracts them (`e - 1022 - guard`) and this did not, which
    // made log2(5e-324) answer -1022 where the answer is -1074: the argument
    // 2^-1074 is the one argument in four hundred where this shows, and the
    // table's log2 spread is log-uniform, so it found the amplified form of the
    // same error immediately.
    let guard = 0;
    while (ef == 0) {
        r = r * 2.0;
        ef = exp_field(r);
        guard = guard + 1;
    };
    split_e = ef - 1022 - guard;
    bitsf((fbits(r) & 4503599627370495) | 4602678819172646912)
};

def log_base(x: float, chi: float, clo: float) -> float {
    if (x != x || x < 0.0) {
        nan
    } else if (x == 0.0) {
        0.0 - inf
    } else if (x > 1.7976931348623157e308) {
        // +inf, and only +inf: a negative argument has already been answered
        // NaN above (which is what C's log(-inf) is), and the only double larger
        // than DBL_MAX is +inf. is_inf() would say the same thing in 32
        // instructions, all of them call overhead for a comparison.
        inf
    } else {
        let m = split_mantissa(x);
        let e: long = split_e;
        if (m < inv_sqrt2) {
            m = m * 2.0;
            e = e - 1;
        };
        let z = log_z(m) + z_lo;
        let w = z * z;
        // log(m), the same shape log_y uses, at the size log_y uses it
        // poly_log, not poly_split: these two are on a runtime path and the
        // loop form is 890 instructions a call for what is twelve multiply-adds.
        // gen_split_unroll.py checks the two agree bit for bit.
        let l = z * (2.0 + w * poly_log(w));
        let p = l * chi;
        let pe = prod_err(l, chi, p);
        let s = two_sum(p, l * clo);
        let ef: float = e;
        ef + (s + (ts_lo + pe))
    }
};

def log2(x: float) -> float {
    log_base(x, log2e_hi, log2e_lo)
};

// log10 goes THROUGH log2, not through its own reduction, and that is a
// deliberate choice with a wrong turn behind it.
//
// The reduction above splits x = m*2^e, so the exact integer e is only the
// integer part of a BASE 2 logarithm. Handing the same e to log10 gives
// log10(100) = 6.8928, and that is not a rounding error -- it is a different
// function. The decimal exponent has to come from a decimal split, and x/10^k
// is not exact, so the compensated z series has nothing exact to work on.
//
// log2(x) * log10(2) has no such problem: log2(x) is now within half an ulp
// RELATIVE of the truth, and multiplying by a constant keeps a relative error
// relative -- it does not turn 0.5 ulp into 2. What the multiply does add is its
// own rounding, and compensating it with the constant split leaves log10 within
// the one-ulp promise. That the amplification used to be real is the finding:
// log(x) * (1/ln10) put log's 1 ulp through a factor of 1.4427, or 3.32 for the
// other base, and the table measured 2 ulps out on ordinary arguments.
// Two wrong turns are recorded here because both were made, both compiled, and
// both were caught only by the spread rather than by a test.
//
// The first was scaling the reciprocal: log10(x) as log(x)*(1/ln10), with the
// constant split hi/lo and prod_err recovering the product's own rounding. That
// is correct arithmetic and it changed NOTHING, because the error was in log's
// answer, not in the multiply. Compensating a multiply cannot repair an operand
// that is already wrong.
//
// The second was log10(x) = log2(x)*log10(2) with the same compensation, which
// is the same mistake one level down: log2(x) has been ROUNDED, so the
// computation was faithfully evaluating rounded-b times exact-c instead of
// exact-log2 times exact-c. It measured 1 ulp on 787 of 12026 arguments where
// the UNCOMPENSATED product was right on most of them -- making it worse, which
// is what a compensation applied to the wrong target looks like.
//
// So the integer part is scaled, and it is scaled while it is still an exact
// integer. log2's reduction splits x = m*2^e with m in [1/sqrt2, sqrt2), and e
// is exact; log10(x) = e*log10(2) + log2(m)*log10(2), so both terms are products
// of an EXACT quantity with a split constant, and the only rounding left is the
// final addition -- 0.5 ulp, at the size of the answer.
def log10(x: float) -> float {
    if (x != x || x < 0.0) {
        nan
    } else if (x == 0.0) {
        0.0 - inf
    } else if (x > 1.7976931348623157e308) {
        // +inf, and only +inf: a negative argument has already been answered
        // NaN above (which is what C's log(-inf) is), and the only double larger
        // than DBL_MAX is +inf. is_inf() would say the same thing in 32
        // instructions, all of them call overhead for a comparison.
        inf
    } else {
        let m = split_mantissa(x);
        let e: long = split_e;
        if (m < inv_sqrt2) {
            m = m * 2.0;
            e = e - 1;
        };
        let z = log_z(m) + z_lo;
        let w = z * z;
        // poly_log, not poly_split: these two are on a runtime path and the
        // loop form is 890 instructions a call for what is twelve multiply-adds.
        // gen_split_unroll.py checks the two agree bit for bit.
        let l = z * (2.0 + w * poly_log(w));
        let ef: float = e;
        let a = ef * log10_2_hi;
        let ae = prod_err(ef, log10_2_hi, a);
        // ln(m) scaled by log10(e), NOT by log10(2) -- see the two constants
        let bq = l * log10e_hi;
        let be = prod_err(l, log10e_hi, bq);
        let s = two_sum(a, bq);
        s + (ts_lo + (ae + be) + l * log10e_lo)
    }
};

// ── sin and cos ────────────────────────────────────────────────────────────

// The quadrant n = round(x*2/pi) and the reduced argument r = x - n*pi/2, one
// piece of pi/2 at a time. The [float] is [sin, cos]: Y has no tuples, and a
// two-element array is the smallest thing that carries both.
def sin_cos_k(x: float) -> [float] {
    let s = x * (1.0 + x * x * poly_split(sin_k, sin_kl, x * x));
    let w = x * x;
    [s, 1.0 - w * poly_split(cos_k, cos_kl, w)]
};

// sin(x). A NaN or an infinity is a NaN, as C's is.
//
// THE RANGE, because the reduction behind this is the limit of all three of
// sin, cos and tan and it is not obvious from the code: the quadrant is
// n = round(x*2/pi) computed in ONE double, and that product wants about 106
// bits and so rounds. The subtraction of n*(pi/2) that follows is compensated
// in double-double and is exact for any n a long holds; the quotient is not.
// Measured against this platform's libm:
//
//     x = 1e15    exact
//     x = 1e16    33 ulp out
//     x = 1e17    2.4e10 ulp out
//     x = 1e18    the quadrant is wrong by one, so the answer is unrelated
//     x >= 1e100  floor(x*2/pi) has left the range of a long, so this is inf
//
// So the promise is |x| <= 2^53 * (pi/2) = 1.41e16, and past it the answers are
// not to be relied on. The cutoff cannot be rounded to a power of two, because
// whether the rounded quotient is right depends on how near x*2/pi happens to
// fall to a half-integer -- a property of x, not a bound on it. Closing the
// gap needs libm's multi-precision reduction (a three-word quotient, the
// do_pi2 stages), which is a piece of work in its own right and not a patch.
// t320_sin_reduction_limit.y pins the present behaviour so that raising the
// limit is a visible diff.
def sin(x: float) -> float {
    // Past pio2_max there is no reduction left to do; see the note on the
    // constant. sin and cos go through the assembly kernels, so without this
    // they answered inf out there -- a number that reads as an answer.
    if (!pio2_fits(x)) { nan } else { sin_asm(x) }
};

// The Y sin, as `sin_asm` computes it: the oracle for the kernel. Not exported.
def sin_y(x: float) -> float {
    if (x != x || is_inf(x)) {
        nan
    } else if (x >= -pi_over_4 && x <= pi_over_4) {
        sin_cos_k(x)[0]
    } else {
        let n = to_int(floor(x * two_over_pi + 0.5));
        let sc = sin_cos_k(rem_pio2(x, n));
        let q = quadrant(n);
        if (q == 0) { sc[0] } else if (q == 1) { sc[1] }
        else if (q == 2) { 0.0 - sc[0] } else { 0.0 - sc[1] }
    }
};

// cos(x), same reduction and same limit as sin.
def cos(x: float) -> float {
    if (!pio2_fits(x)) { nan } else { cos_asm(x) }
};

// The Y cos, as `cos_asm` computes it. Not exported.
def cos_y(x: float) -> float {
    if (x != x || is_inf(x)) {
        nan
    } else if (x >= -pi_over_4 && x <= pi_over_4) {
        sin_cos_k(x)[1]
    } else {
        let n = to_int(floor(x * two_over_pi + 0.5));
        let sc = sin_cos_k(rem_pio2(x, n));
        let q = quadrant(n);
        if (q == 0) { sc[1] } else if (q == 1) { 0.0 - sc[0] }
        else if (q == 2) { 0.0 - sc[1] } else { sc[0] }
    }
};

// tan(x): the two kernels divided, with C's infinities where C has them (a
// pole, and cos(x) == 0 is a pole).
def tan(x: float) -> float {
    if (x != x || is_inf(x)) {
        nan
    } else if (!pio2_fits(x)) {
        // NaN, for the reason on pio2_max. It is worth saying what this cost
        // before it was here: to_int does not return a wrong quadrant past its
        // own limit, it TRAPS, and a trap ends the program -- so tan(1e30) used
        // to kill whatever asked.
        nan
    } else if (x >= -pi_over_4 && x <= pi_over_4) {
        let sc = sin_cos_k(x);
        if (sc[1] == 0.0) { 0.0 - inf } else { sc[0] / sc[1] }
    } else {
        let n = to_int(floor(x * two_over_pi + 0.5));
        let sc = sin_cos_k(rem_pio2(x, n));
        let q = quadrant(n);
        let sn = if (q == 0) { sc[0] } else if (q == 1) { sc[1] }
            else if (q == 2) { 0.0 - sc[0] } else { 0.0 - sc[1] };
        let cs = if (q == 0) { sc[1] } else if (q == 1) { 0.0 - sc[0] }
            else if (q == 2) { 0.0 - sc[1] } else { sc[0] };
        if (cs == 0.0) { if (sn > 0.0) { inf } else { 0.0 - inf } } else { sn / cs }
    }
};

// ── atan ───────────────────────────────────────────────────────────────────

// atan(x), x >= 0. Beyond tan(pi/16) the argument is folded: atan(x) =
// atan(1/x) - pi/2 or atan(x) - pi/4 for x above 2.414, which keeps every
// kernel argument inside the range it was fitted for.
def atan(x: float) -> float {
    if (x != x) {
        x
    } else if (is_inf(x)) {
        // an infinity is +-pi/2, and C keeps the sign
        if (x < 0.0) { 0.0 - pi_over_2 } else { pi_over_2 }
    } else {
        let neg = x < 0.0;
        let a = if (neg) { 0.0 - x } else { x };
        // Fold until the argument is inside the kernel's range, with the
        // constant each fold earns added back at the end. Reciprocal first
        // (atan(1/a) = pi/2 - atan(a), and it turns anything above 1 into
        // something below 1), then the tangent addition at pi/8. Both are exact
        // identities, not approximations, which is what keeps the fold from
        // costing an ulp of its own.
        let t = a;
        let recip = t > 1.0;
        if (recip) { t = 1.0 / t; };
        let folded = t > atan_max;
        let core = if (folded) {
            atan_kernel((t - tan_pi_8) / (1.0 + t * tan_pi_8)) + pi_over_8
        } else {
            atan_kernel(t)
        };
        // the reciprocal fold's constant comes OFF, the tangent addition's goes
        // on: atan(1/a) = pi/2 - atan(a)
        let out = if (recip) { pi_over_2 - core } else { core };
        if (neg) { 0.0 - out } else { out }
    }
};

// atan's kernel proper, for |x| <= tan(pi/8).
def atan_kernel(x: float) -> float {
    let w = x * x;
    x * (1.0 + w * poly_split(atan_k, atan_kl, w))
};

// ── the hyperbolic functions ────────────────────────────────────────────────
//
// cosh and tanh are one formula each, and both come out of expm1:
//
//     cosh x = 1 + (expm1(x) + expm1(-x))/2
//     tanh x = expm1(2x) / (expm1(2x) + 2)
//
// The plain forms -- (e^x + e^-x)/2 and sinh/cosh -- are a rounding or two
// worse, because each of their terms is computed to its own last bit and then
// added: (e^x + e^-x)/2 for x = 2.5 is two ulps out. These have one division
// and no cancellation, and expm1 is the function that can compute e^2x - 1 to
// the ulp. tanh's own polynomial is gone: at |x| = 1 its series in x^2 needs a
// degree near forty, and near one its answer has a small ulp, so the shape that
// wins everywhere else does not win here.
def cosh(x: float) -> float {
    if (x != x) {
        x
    } else if (is_inf(x)) {
        inf
    } else {
        let a = if (x < 0.0) { 0.0 - x } else { x };
        if (a < 0.5) {
            // the sum, not the difference: the two expm1 terms cancel their
            // leading parts and leave a^2, and what is left is what cosh is.
            // Below half the two are small and near each other, so the absolute
            // error of their sum is a fraction of an ulp of the answer.
            1.0 + ((expm1(a) + expm1(0.0 - a)) * 0.5)
        } else {
            // HALF ON EACH TERM, not on the sum. e^a + e^-a is rounded at the
            // size of e^a, which for a >= 0.5 is twice the size of cosh, so
            // halving afterwards leaves an error of a whole ulp of the answer;
            // halving each term first is exact and the sum is then rounded once
            // at the size of the answer. One line, and cosh(-1.88) stopped
            // being two ulps out.
            // ONE exp and its reciprocal, not two exps: e^-a is 1.2% of the
            // answer at a >= 0.5, so its own rounding is a hundredth of an ulp
            // of the answer, while a second exp() call would bring its whole
            // error along -- and exp is a ulp out at some arguments, which is
            // what had cosh(-1.88) sitting two ulps away.
            //
            // Past 709 cosh has the same problem sinh had, and for the same
            // reason with the SAME answer: cosh(a) = e^a/2 + e^-a/2 and e^a is
            // inf from 709.78, yet cosh(710) is 1.1169973830808557e+308 -- the
            // halving buys back the exponent, so cosh overflows at 710.4758,
            // the same bound as sinh and for the same algebraic reason. The
            // halved-argument square fixes both, and below 709 the form is
            // kept because it is the more accurate of the two there: squaring
            // doubles the relative error of exp, whereas t*0.5 + 0.5/t rounds
            // once at the size of the answer.
            if (a > 709.0) {
                exp_half(a)
            } else {
                let t = exp(a);
                t * 0.5 + 0.5 / t
            }
        }
    }
};

// tanh for |x| <= 1/2, from tanh's kernel -- the same shape as sinh_small
// beside it, and the same reason: tanh's answer never leaves [-1, 1], so
// reaching for a full-range exponential to produce it is paying for reach one
// does not need. Measured at 10000 calls with |x| <= 1/2, this is 168
// instructions a call against the exponential form's 1049 -- and the two agree
// with an exact 50-digit tanh on 3999 of 4000 arguments each, which is to say
// they are the same function.
def tanh_small(x: float) -> float {
    let w = x * x;
    x * (1.0 + w * poly_tanh(w))
};

def tanh(x: float) -> float {
    if (x != x) {
        x
    } else if (is_inf(x)) {
        if (x < 0.0) { 0.0 - 1.0 } else { 1.0 }
    } else if (x >= 20.0 || x <= -20.0) {
        // 1 - 2/(e^(2x) + 1) is 1 - 4e-2x here at worst, which is 6.8e-18
        // against an answer of 1 -- so the answer IS 1 to its last bit, and
        // 2^-53 is the only distance there is between them.
        if (x < 0.0) { 0.0 - 1.0 } else { 1.0 }
    } else if (x >= -0.5 && x <= 0.5) {
        tanh_small(x)
    } else {
        let a = if (x < 0.0) { 0.0 - x } else { x };
        let u = expm1(2.0 * a);
        let t = u / (u + 2.0);
        if (x < 0.0) { 0.0 - t } else { t }
    }
};

// sinh(x) for |x| <= 0.5, from sinh's kernel -- the same small range expm1 and
// log1p need, and for the same reason: above 0.5 the exponential form is
// better, because the two terms differ enough there to keep.
def sinh_small(x: float) -> float {
    let w = x * x;
    x * (1.0 + w * poly_sinh(w))
};

// sinh(x) = (e^x - e^-x)/2 for the rest of the range. Above |x| = 0.5 the two
// terms are far enough apart for the subtraction to keep everything, and below
// it they are nearly equal -- which is what sinh_small is for.
def sinh(x: float) -> float {
    if (x != x || is_inf(x)) {
        x
    } else if (x >= -0.5 && x <= 0.5) {
        sinh_small(x)
    } else if (x > 709.0 || x < -709.0) {
        // The argument has outrun its own exponential. e^x is inf from 709.78
        // on, so (e^x - e^-x)/2 is inf there -- yet sinh(710) is
        // 1.1169973830808557e+308, a perfectly good double: the halving buys
        // back a full exponent, so sinh overflows at 710.48, a third further
        // out. This is the "rounded at the wrong SIZE" family of bug in its
        // purest form -- the subtraction is fine, the thing being subtracted is
        // simply not there.
        //
        // The fix is exp_half, not a square and not exp(x - ln2): e^a/2 asked for
        // directly, by moving cosh's halving INTO exp's exponent rather than
        // applying it to an infinity. Both rejected routes are recorded at
        // exp_half; the short reason is that each of them multiplies an error
        // that is already there (the square, by two) or invents one (the
        // subtraction, by discarding the low bits of a large argument).
        //
        // The SIGN is carried out here rather than left inside: sinh is odd, so
        // the negative half is computed from |x| and negated.
        let a = if (x < 0.0) { 0.0 - x } else { x };
        let v = exp_half(a);
        if (x < 0.0) { 0.0 - v } else { v }
    } else {
        (exp(x) - exp(0.0 - x)) * 0.5
    }
};

// ── expm1 and log1p ────────────────────────────────────────────────────────

// expm1(x) = e^x - 1. Written as x*(1 + x*Q(x)) with the exp kernel -- the same
// coefficients, the same shape, without the leading 1 -- so nothing is
// subtracted from anything: for x = 1e-17 the naive e^x - 1 is 0, and this is
// the argument back again.
def expm1(x: float) -> float {
    if (x != x) {
        x
    } else if (x > exp_hi) {
        inf
    } else if (x < exp_lo) {
        0.0 - 1.0
    } else {
        let n: long = to_int(floor(x * log2e + 0.5));
        let nf: float = n;
        let r = (x - nf * ln2_hi) - nf * ln2_lo;
        // The kernel's own shape: r*(1 + r*P(r)) is e^r - 1, NOT e^r. That is
        // deliberate and it is why exp's form is 1 + r*(1 + r*P(r)): this value
        // is the whole point of expm1, the part that is small when r is, and
        // hoisting it here makes the three branches below three ways of
        // assembling the same answer rather than three separate expressions
        // that can each be wrong in their own way. (The first version of the
        // n > 1023 branch read 1 + r*P(r) as e^r and was out by a factor of
        // 1/r.)
        let kern = r * (1.0 + r * poly_exp(r));
        // 2^n*e^r - 1, which is not the subtraction it looks like: the -1 is
        // split into 2^n*(e^r - 1) and (2^n - 1), and the second of those is
        // EXACT (2^n - 1 needs at most 53 bits). So nothing is ever subtracted
        // from something nearly equal to it -- which is the whole difficulty
        // with e^x - 1: it is 0.0 for x = 1e-300, and at x = -9 it is
        // 1.23e-4 - 1 with the answer's last bits gone (18 ulps).
        if (n > 1023) {
            // The one branch where 2^n DOES NOT EXIST. n = 1024 over
            // x in [709.436, 709.783] (the only such x under exp_hi), and
            // 2^1024 is one ulp past DBL_MAX, so it cannot be formed -- and
            // with it goes the whole 2^n - 1 term, which would be inf and take
            // the answer with it. That is not a rounding question: it is where
            // expm1(709.5) came back as inf instead of 1.3549863193146328e+308.
            //
            // The -1 does not need carrying here, and that is why the branch is
            // not merely a workaround. x >= 709.436 here, so e^x >= 1.06e308,
            // and an ulp of THAT is 2e292: the 1 is far below the answer's last
            // bit and e^x - 1 IS e^x as a double. So the answer is one scaled
            // kernel with the factor of two inside the scale (k = n-1, where
            // 2^k is representable) -- the move exp_half makes, for the same
            // reason.
            ldexp(2.0 * (1.0 + kern), n - 1)
        } else if (n == 0) {
            // The second term is +0.0, and -0.0 + 0.0 is +0.0, so the signed
            // zero of expm1(-0.0) has to be the first term alone.
            kern
        } else {
            // ONE ldexp, not two: p is 2^n, and the small term is p times a
            // kernel value under 0.72, so the product is exact whenever it is
            // normal. It lands in the subnormals only where the term is already
            // a correction far under the answer's last bit (at n = -1075, p
            // itself is subnormal and the product rounds -- to an absolute error
            // of 2^-1075, against an answer of order 1). So the rounding ldexp
            // exists to avoid is bounded there by the smallest number there is,
            // and the second ldexp was 200 instructions of nothing.
            let p = ldexp(1.0, n);
            (kern * p) + (p - 1.0)
        }
    }
};

// log1p(x) = log(1 + x), through log's own kernel with m = 1 + x. The
// argument z = x/(2 + x) is what keeps it honest: it tends to x/2 as x tends to
// zero, so a tiny x comes out as itself instead of as log(1.0) - 0.
def log1p(x: float) -> float {
    if (x != x || x < -1.0) {
        nan
    } else if (x == -1.0) {
        0.0 - inf
    } else if (x <= -0.5) {
        log(1.0 + x)
    } else {
        // log's kernel assumes a fraction in [1/sqrt2, sqrt2), which 1 + x may
        // not be; outside that it goes the long way round through log, which
        // does its own frexp
        let m = 1.0 + x;
        if (m < inv_sqrt2 || m > 1.41421356237309504880) {
            log(m)
        } else {
            let z = x / (2.0 + x);
            let w = z * z;
            z * (2.0 + w * poly_log(w))
        }
    }
};

// ── asin, acos, atan2 ──────────────────────────────────────────────────────

// 2*asin(sqrt((1-a)/2)) for 0.5 < a < 1, in TWO parts: the answer is
// asin_half_hi and everything below it is asin_half_lo. It has to be two parts
// because asin subtracts this from pi/2, and the subtraction's own rounding
// would swallow the low half -- which is most of what makes asin an ulp
// accurate rather than two.
//
// acos wants the same quantity and gets it whole, which is the whole reason it
// is here rather than left inside asin: acos cannot go the other way round.
// pi/2 - asin(x) cancels, because near x = 1 the answer is 3e-8 against a pi/2
// and eight digits are gone before the answer is formed. acos(1 - 4e-17) came
// out FORTY ulps out that way, and the reference table is what found it -- with
// only eight arguments of its own inside [-1, 1] it had taken densifying the
// spread to say so.
let asin_half_hi: float = 0.0;
let asin_half_lo: float = 0.0;

def asin_half(a: float) -> float {
    // 0.5 < a < 1 here, so z is in (0, 1/4] and s = sqrt(z) is never 0. `1 - a`
    // is exact -- Sterbenz -- and halving is exact, so z is exact however close
    // a is to 1: nothing is lost that a cleverer argument for the square root
    // would have kept.
    let z = (1.0 - a) * 0.5;
    if (z == 0.0) {
        // a == 1.0: the answer is 0, and the square root's residual below would
        // be 0/0. asin never arrives here (it answers +-1 before this), but acos
        // does -- acos(1.0) is 0, and it used to come back NaN.
        asin_half_lo = 0.0;
        asin_half_hi = 0.0;
        0.0
    } else {
        let s = sqrt(z);
        let p = poly_split(asin_k, asin_kl, z);
        // two = 2*asin(s) = 2s + (2s)*z*P(z). The kernel is exact enough that
        // the only rounding left in it is the one two_sum holds.
        let hi = two_sum(2.0 * s, (2.0 * s) * z * p);
        // The square root's own half-ulp, which (z - s*s)/(2s) is exactly: z -
        // s*s is exact by Sterbenz again, and the first-order form is wrong by a
        // relative 5e-17 of a number that is itself a fraction of an ulp -- so
        // this is the sqrt put back, not an estimate of it.
        asin_half_lo = ts_lo + 2.0 * ((z - s * s) / (2.0 * s)) * (1.0 + z * p);
        asin_half_hi = hi;
        hi
    }
};

// asin(x) for |x| <= 0.5, as atan(x/sqrt(1-x*x)). The half-angle step below
// handles the rest, and this range is where the division is well behaved.
def asin_small(x: float) -> float {
    atan(x / sqrt(1.0 - x * x))
};

// asin(x), |x| <= 1. Above 0.5 the half-angle identity brings the argument
// back inside: asin(x) = pi/2 - 2*asin(sqrt((1-|x|)/2)), one step. That inner
// asin is computed from its own kernel rather than by recursing into
// asin_small, because asin_small goes through atan and atan's own ulp lands
// inside the answer whole -- which is what used to leave asin two ulps out at
// -0.719 while nothing else in the module was more than one.
def asin(x: float) -> float {
    if (x != x || x > 1.0 || x < -1.0) {
        nan
    } else if (x == 1.0) {
        pi_over_2
    } else if (x == -1.0) {
        0.0 - pi_over_2
    } else {
        let neg = x < 0.0;
        let a = if (neg) { 0.0 - x } else { x };
        let r = if (a <= 0.5) {
            asin_small(a)
        } else {
            let two_hi = asin_half(a);
            let two_lo = asin_half_lo;
            // pi/2 - two, with `two` still in two parts: the two_sum answers
            // pi/2 - two_hi exactly, and both corrections are then subtracted
            // from the RESULT, which is where a few 1e-17s do not cancel
            // against an 0.8 and leave nothing. One rounding finishes it.
            let d = two_sum(pi_over_2, 0.0 - two_hi);
            let f = ts_lo - two_lo;
            d + f
        };
        if (neg) { 0.0 - r } else { r }
    }
};

// acos(x) = pi/2 - asin(x), which is what C's is.
def acos(x: float) -> float {
    if (x != x || x > 1.0 || x < -1.0) {
        nan
    } else {
        let neg = x < 0.0;
        let a = if (neg) { 0.0 - x } else { x };
        let r = if (a > 0.5) {
            // acos(a) = 2*asin(sqrt((1-a)/2)), which is the half-angle quantity
            // asin_half already computes -- taken whole, and formed directly.
            // NOT pi/2 - asin(a): near a = 1 that answer is 3e-8 against a
            // pi/2, so eight digits cancel and acos(1 - 4e-17) lands forty ulps
            // out. One addition of the two parts, which are of very different
            // sizes, so the rounding is the answer's own half-ulp.
            //
            // `hi` is bound before the cell is read: asin_half fills that cell
            // as a side effect, and reading it inside the same expression would
            // leave the order the two operands are evaluated in deciding the
            // answer. Fifteen of the 2076 cases were that, before the binding.
            let hi = asin_half(a);
            hi + asin_half_lo
        } else {
            // Below the half there is nothing to cancel: the answer is between
            // pi/3 and pi/2, and asin(a) is small, so the subtraction is
            // corrected the same way asin's own is.
            let s = asin_small(a);
            let d = pi_over_2 - s;
            d + ((pi_over_2 - d) - s)
        };
        // acos(-x) = pi - acos(x), and THAT is not a cancellation either way:
        // the answer is in [pi/2, pi] whether r is 3e-8 or pi/2, so the
        // subtraction costs its own half-ulp and nothing else. (Getting here
        // wrong is cheap to do and the table catches it immediately: 130 of the
        // 2076 cases were this one missing sign, answering acos(-0.461) with
        // the value for +0.461.)
        if (neg) { pi - r } else { r }
    }
};

// atan2(y, x): the quadrant of (y, x), with atan(|y/x|) in the middle.
def atan2(y: float, x: float) -> float {
    if (y != y || x != x) {
        nan
    } else if (x == 0.0) {
        // Both zeros at once is the whole of the interesting case, and neither
        // comparison can see it: -0.0 < 0.0 is false and +0.0 < 0.0 is also
        // false, so a `y > 0.0` / `y < 0.0` / else ladder answers +0 for all four
        // combinations and puts atan2(+0, -0) at 0 where the answer is +pi.
        // It answers +0 for atan2(+0, -0) because -0.0 == 0.0 is TRUE, so the arm
        // above was never even reached -- and the `y == 0.0` arm's care about the
        // sign of the zero was dead code for the same reason.
        //
        // So the order is the sign of x first, and only then y: on the y axis
        // (x is a zero, whatever its sign) atan2 is +-pi/2 by the sign of y, and
        // +-pi when y is a zero too, by the sign of y again.
        if (y == 0.0) {
            // BOTH are zeros, and here the SIGN OF X is what decides the shape:
            // a negative zero means the point is on the negative x axis, so the
            // answer is +-pi, and a positive zero means it is on the positive
            // one, so the answer is a zero. The sign of y then carries through
            // either way -- which is the whole of C99 7.12.7.4's four cases for
            // this corner, and the reason a `y > 0.0` / `y < 0.0` / else ladder
            // cannot express it: both comparisons are false for +0.
            //
            // My first attempt tested is_signed_zero(y) and read the sign of x
            // inside it, which answers +pi for atan2(+0, -0) but +-pi_over_2
            // for atan2(+0, +0) -- because +0 is not a signed zero and so fell
            // through to the sign-of-y ladder, where +0 is neither > 0 nor < 0.
            // The test has to be `y == 0.0`, which is true of both zeros.
            if (is_signed_zero(x)) {
                if (is_signed_zero(y)) { 0.0 - pi } else { pi }
            } else {
                if (is_signed_zero(y)) { neg_zero } else { 0.0 }
            }
        } else if (y > 0.0) {
            pi_over_2
        } else {
            0.0 - pi_over_2
        }
    } else if (y == 0.0) {
        // atan2(+-0, x < 0) is +-pi, and the sign is the sign OF THE ZERO: a
        // negative zero has a direction, and that is the whole difference
        if (x > 0.0) {
            0.0
        } else if (is_signed_zero(y)) {
            0.0 - pi
        } else {
            pi
        }
    } else if (is_inf(x)) {
        if (is_inf(y)) {
            // both infinite: the quadrant, not y/x, which is a NaN here
            let third = 2.35619449019234492885;      // 3pi/4
            if (y > 0.0) {
                if (x > 0.0) { pi_over_4 } else { third }
            } else {
                if (x > 0.0) { 0.0 - pi_over_4 } else { 0.0 - third }
            }
        } else if (x > 0.0) { 0.0 } else { pi }
    } else if (is_inf(y)) {
        if (y > 0.0) { pi_over_2 } else { 0.0 - pi_over_2 }
    } else if (x > 0.0) {
        atan(y / x)
    } else if (y > 0.0) {
        atan(y / x) + pi
    } else {
        atan(y / x) - pi
    }
};

// ── pow ────────────────────────────────────────────────────────────────────

// -0.0. Multiplied into being rather than subtracted: 0.0 - 0.0 is +0.0 in
// IEEE, which is exactly why a signed zero needs its own spelling.

// ── pow's logarithm, in two parts ───────────────────────────────────────────
//
// Everything else here takes its log's answer at face value, which is where the
// ulp fits. pow cannot: it multiplies the log by the exponent, and an exponent
// of 500 turns the log's half-ulp into 5e-14 of the answer -- 250000 ulps of it.
// So pow's log is computed in two parts and the exponent multiplies both, and
// the answer is exp2 of a *reduced* argument that carries the second part into
// the kernel where it is worth something.

// two_sum(a, b) = a + b, with the exact rounding error left in ts_lo. The
// three-operation form needs the operands ordered; this is the six-operation
// one, which does not.
let log2_hi: float = 0.0;
let log2_lo: float = 0.0;

def two_sum(a: float, b: float) -> float {
    let s = a + b;
    let bb = s - a;
    ts_lo = (a - (s - bb)) + (b - bb);
    s
};

// log(x), returning the main part and leaving the part the summation lost in
// log2_lo. Same reduction and kernel as log; only the bookkeeping differs. The
// answer is the NATURAL log: the 1/ln2 belongs to pow's exponent multiply,
// which has to be compensated as well, and a factor folded in here could not be.
def log2_dd(x: float) -> float {
    if (x != x || x < 0.0) {
        log2_lo = 0.0;
        nan
    } else if (x == 0.0) {
        log2_lo = 0.0;
        0.0 - inf
    } else if (is_inf(x)) {
        log2_lo = 0.0;
        inf
    } else {
        let p = frexp(x);
        let m = bitsf(p[0]);
        let e: long = p[1];
        if (m < inv_sqrt2) {
            m = m * 2.0;
            e = e - 1;
        };
        let z = log_z(m) + z_lo;
        let w = z * z;
        let ef: float = e;
        // the two terms are of very different sizes -- the small one is the
        // kernel's, the big one is e*ln2 -- and the rounding that matters is
        // the big one's, so that is the one two_sum keeps track of
        //
        // `a` is two_sum(2.0 * z, (z * w) * P) and NOT z * (2.0 + w * P). They
        // are the same function, but the brackets in the second one round at
        // the SIZE OF 2.0 -- a whole ulp of the logarithm -- and pow multiplies
        // this logarithm by the exponent, so that one rounding was three ulps
        // of pow(23.85, 5.6) and nothing else was. Scaling by two is exact and
        // (z*w)*P is two orders smaller, so the two_sum carries it instead.
        let a = two_sum(2.0 * z, (z * w) * poly_log(w));
        let a_lo = ts_lo;
        let b = two_sum(ef * ln2_hi, ef * ln2_lo);
        let bc_lo = ts_lo;
        let t = two_sum(a, b);
        log2_hi = t;
        log2_lo = ts_lo + a_lo + bc_lo;
        t
    }
};

// exp2 of p + q, where q is what the exponent's own rounding left over.
//
// It has to be added AFTER the reduction -- an exponent error is an absolute
// error in the reduced argument, and before the reduction it would be
// multiplied by the whole exponent -- and it has to SURVIVE the reduction too,
// which is the part that is easy to miss. One ulp of an exponent of 500 is
// 5.7e-14 of the answer, 360 ulps of it; so the reduced argument is kept in two
// parts as well, and the answer is e^t_hi plus e^t_hi times the second part.
// pow(1e300, 0.5) is the case that shows it: its exact exponent sits between
// two doubles, and rounding it first is 49 ulps of the answer.
def exp2_corr(p: float, q: float) -> float {
    if (p != p) {
        p
    } else if (p > 1024.0) {
        inf
    } else if (p < -1075.0) {
        0.0
    } else {
        let n = floor(p + 0.5);
        let s = (p - n) + q;
        let t = s * ln2;
        let k = to_int(n);
        let f2 = 1.0;
        if (n > 1023.0) { k = k - 1; f2 = 2.0; };
        let hi = f2 * (1.0 + t * (1.0 + t * poly_exp(t)));
        // e^(t + t_lo) = e^t * e^t_lo = e^t + e^t * t_lo for a t_lo of 1e-17
        let lo = hi * prod_err(s, ln2, t);
        ldexp(hi, k) + ldexp(lo, k)
    }
};

// Is a float's value an integer? The difference between a negative base with an
// integer exponent and one with a fractional exponent is the difference
// between a number and a NaN, so pow asks.
def is_int(y: float) -> bool {
    y == trunc(y)
};

// pow_int: x^n by repeated squaring, which is exact while the powers are
// (so every integer exponent below 1024 comes out exactly), and where it is
// not, the overflow or underflow is IEEE's.
def pow_int(x: float, n: long) -> float {
    // Repeated squaring over the BITS of the exponent: b is x^(2^i) at step i
    // and is multiplied in when bit i is set. Exact, so an integer exponent
    // below 1024 comes out exactly -- which is why C's integer cases are the
    // ones worth having.
    let neg = n < 0;
    let k = if (neg) { 0 - n } else { n };
    let r = 1.0;
    let b = x;
    let kk = k;
    while (kk > 0) {
        if (kk % 2 == 1) { r = r * b; };
        b = b * b;
        kk = kk / 2;
    };
    if (neg) { 1.0 / r } else { r }
};

// pow(x, y) = x^y, with C's cases. Three of them are what a power needs and a
// formula does not: an integer exponent (exact, and the only way a negative
// base is defined at all), the zeros, and the infinities.
// pow_pos(x, y) for x > 0: the logarithm in two parts, the exponent in two
// parts, and the reduced argument in two parts. pow is the one function here
// that cannot take its log's answer at face value, because it multiplies it by
// the exponent and an exponent of 500 turns the log's half-ulp into 5e-14 of
// the answer. So everything on the way to the answer carries what it rounded
// off -- see log2_dd and exp2_corr, which is where the work is.
def pow_pos(x: float, y: float) -> float {
    let l = log2_dd(x);
    let u = y * inv_ln2;
    let p = u * l;
    let q = prod_err(u, l, p) + u * log2_lo
        + l * (prod_err(y, inv_ln2, u) + y * inv_ln2_lo);
    exp2_corr(p, q)
};

// The Y pow, exactly as `pow_asm` computes it: the oracle the kernel is checked
// against, and kept for the same reason exp_y and sin_y are -- bit-identity is a
// promise about a specific sequence of roundings, and the only way to keep it is
// to keep the thing being reproduced. t315 checks 15,137 pairs of the two,
// every arm of this dispatch and then the general path.
def pow_y(x: float, y: float) -> float {
    if (y == 0.0) {
        1.0
    } else if (x != x || y != y) {
        nan
    } else if (x == 1.0 || x == -1.0) {
        // (-1)^anything is +-1, and (-1)^0.5 is 1 -- which is the case a
        // "negative base, fractional exponent" rule gets wrong, and the one
        // IEC 60559 calls out by name
        if (x == -1.0 && is_int(y) && trunc(y / 2.0) * 2.0 != y) { -1.0 } else { 1.0 }
    } else if (y == 1.0) {
        x
    } else if (x == 0.0) {
        // (+-0)^positive is +-0 (the sign follows the exponent's parity) and
        // (+-0)^negative is +inf
        if (y < 0.0) {
            inf
        } else if (is_int(y) && trunc(y / 2.0) * 2.0 != y) {
            neg_zero
        } else {
            0.0
        }
    } else if (is_inf(x)) {
        // the parity sign belongs to the BASE being negative: a positive one
        // raised to any power is positive, so pow(inf, 3) is +inf
        if (y < 0.0) {
            0.0
        } else if (x < 0.0 && is_int(y) && trunc(y / 2.0) * 2.0 != y) {
            0.0 - inf
        } else {
            inf
        }
    } else if (x < 0.0) {
        // A negative base needs an integer exponent, and past 1024 there are
        // too many squarings to do: the logarithm carries it instead, with the
        // sign back on afterwards.
        if (!is_int(y)) {
            nan
        } else if (y >= -1024.0 && y <= 1024.0) {
            pow_int(x, to_int(y))
        } else {
            let v = pow_pos(0.0 - x, y);
            if (trunc(y / 2.0) * 2.0 != y) { 0.0 - v } else { v }
        }
    } else if (is_int(y) && y >= -1024.0 && y <= 1024.0) {
        pow_int(x, to_int(y))
    } else {
        pow_pos(x, y)
    }
};

// pow(x, y) = x^y. The routine is in src/y/arch/math.s, generated by
// test/math/gen_pow.py from the bodies below (`pow_int` and `pow_pos`, and the
// cases in `pow_y` beside it), and is bit-identical to the oracle.
def pow(x: float, y: float) -> float {
    pow_asm(x, y)
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

// Rotate left by k bits. The count is taken mod 64, so a multiple of 64 is the
// identity and no argument kills the program.
//
// It was `x << k | x >>> (64 - k)` under a comment saying "for 1 <= k <= 63",
// and that comment was wrong in a way worth recording. k = 0 and k = 64 both
// HAPPEN to be right -- (x << 0) | (x >>> 64) is x | 0, and (x << 64) |
// (x >>> 0) is 0 | x -- so the function behaved as if it took 0, while 65
// killed the program, because 64 - 65 is -1 and a negative shift count traps.
// A gate that walked the count would have found this in a moment; rotl had no
// gate at all, which is the other half of it.
//
// Masking is what the instruction does -- ROL masks its count to six bits -- and
// it turns rotl(x, 64) == x from a coincidence into a fact. Every other count
// out there in this module merely zeroes; a rotate was the one that died.
def rotl(x: long, k: long) -> long {
    let r = k & 63;
    if (r == 0) { x } else { (x << r) | (x >>> (64 - r)) }
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
// These walk the caller's array in place, so they cost no allocation. The two
// that take two arrays stop on a length mismatch rather than quietly reading the
// shorter one. The loops themselves are the six kernels in src/y/arch/math.s
// (`sum_asm` and friends above), each bit-identical to the Y loop kept beside it
// as `*_y`; the wrapper is what decides the empty case and checks the lengths.

// The plain sum, in order. Fine for well-conditioned data; see fsum_kahan.
//
// This is `sum_asm` -- the same additions in the same order, which is what makes
// the result the same double. `fsum_y` is that loop, kept as the oracle
// t310 checks the kernel against (and as the shape to read if you want to know
// what the assembly is doing).
def fsum(a: [float]) -> float {
    if (len(a) == 0) { 0.0 } else { sum_asm(a.ptr, len(a)) }
};

// The Y loop fsum is: in order, from +0.0. It is not exported.
def fsum_y(a: [float]) -> float {
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
    // An infinity in the running total has to be returned as it is. The
    // compensation cannot rescue it and computing with it destroys it: on the
    // way to inf the step computes (s - t) + x, which is (1e308 - inf) + 1e308,
    // and inf - inf is a NaN -- so fsum_kahan([1e308, 1e308]) answered NaN where
    // the answer is +inf, and so does every array whose total leaves the range.
    // The exact sum of two 1e308 is 2e308, which is out of range, so +inf is the
    // right answer and not a limitation of this method.
    if (is_inf(s)) { s } else { s + c }
};

// The dot product of two equal-length arrays: `dot_asm`, the same
// multiplications and additions in the same order.
def fdot(a: [float], b: [float]) -> float {
    if (len(a) != len(b)) { len_mismatch("fdot") };
    if (len(a) == 0) { 0.0 } else { dot_asm(a.ptr, b.ptr, len(a)) }
};

// The Y loop fdot is. Not exported.
def fdot_y(a: [float], b: [float]) -> float {
    let s = 0.0;
    let i = 0;
    let n = len(a);
    while (i < n) {
        s = s + a[i] * b[i];
        i = i + 1;
    };
    s
};

// The equal-length rule. A mismatch is a mistake in the caller, and reading the
// shorter array would answer with a plausible wrong number, so it stops. The
// message is the same shape as every other runtime error (the traps in rt.y).
def len_mismatch(who: str) -> void {
    eputs("runtime error: " + who + " needs two arrays of the same length\n");
    len_mismatch_stop()
};

// The exit itself, kept apart so `len_mismatch` has one return path.
native def len_mismatch_stop() -> void = "y_len_stop";

// The smallest element, or NaN for an empty array.
//
// The kernel reads n >= 1, so the empty case stays here where `nan` is. A NaN
// among the elements never becomes the answer unless it is the FIRST one, and
// that is `a[i] < m` being false rather than a rule of its own: Y's loop does
// the same, and so does the assembly (NATIVE.md would call it "unordered").
def fmin_of(a: [float]) -> float {
    if (len(a) == 0) { nan } else { min_of_asm(a.ptr, len(a)) }
};

// The Y loop fmin_of is. Not exported.
def fmin_of_y(a: [float]) -> float {
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

// The largest element, or NaN for an empty array -- `max_of_asm`, and the same
// NaN rule as fmin_of.
def fmax_of(a: [float]) -> float {
    if (len(a) == 0) { nan } else { max_of_asm(a.ptr, len(a)) }
};

// The Y loop fmax_of is. Not exported.
def fmax_of_y(a: [float]) -> float {
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

// a *= k, in place: `scale_asm`, the same product per element.
def fscale(a: [float], k: float) -> void {
    scale_asm(a.ptr, len(a), k)
};

// The Y loop fscale is. Not exported.
def fscale_y(a: [float], k: float) -> void {
    let i = 0;
    while (i < len(a)) {
        a[i] = a[i] * k;
        i = i + 1;
    }
};

// y += k * x, in place, over equal-length arrays: the axpy of numerical
// linear algebra, which is how a vector is accumulated without allocating.
def faxpy(y: [float], k: float, x: [float]) -> void {
    if (len(y) != len(x)) { len_mismatch("faxpy") };
    axpy_asm(y.ptr, len(y), k, x.ptr)
};

// The Y loop faxpy is. Not exported.
def faxpy_y(y: [float], k: float, x: [float]) -> void {
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
// Scaled before the two passes, unscaled after. The two-pass method takes the
// MEAN first, and the mean of two equal 1e308 values is inf -- so
// fvariance([1e308, 1e308]) answered inf where the answer is 0, and
// fvariance([1e300, 1e300]) the same. A variance of two equal numbers is zero
// however large they are, and a method that cannot see that is measuring the
// wrong thing: it is the SIZE of the mean, not the spread, that overflowed.
//
// Scaling by a power of two is exact, cannot change a comparison or a
// subtraction's sign, and cannot make a normal number subnormal (the scale is
// chosen from the largest magnitude present, so everything lands within a
// factor of two of 1). The variance is quadratic in the scale, so the factor
// comes back squared through ldexp -- which is exact to the last bit or the
// answer overflows, which is the honest answer for a spread that big.
//
// A NaN among the elements needs no case: `v > m` is false for it, so the scale
// is set by the others, and the NaN reaches the mean and then the answer. An
// infinity sets e = 1024, the scaled elements stay infinite, and inf - inf is
// the NaN it should be.
def fvariance(a: [float]) -> float {
    if (len(a) < 2) {
        nan
    } else {
        let n = len(a);
        let big = 0.0;
        let i = 0;
        while (i < n) {
            let v = fabs(a[i]);
            if (v > big) { big = v };
            i = i + 1;
        };
        // big is 0 for an all-zero array and inf for one holding an infinity;
        // both flow through the arithmetic below to the right answer (0, and a
        // NaN from inf - inf) without a branch of their own.
        let e = exp_field(big) - 1023;
        let sc = ldexp(1.0, 0 - e);
        let m = 0.0;
        i = 0;
        while (i < n) {
            m = m + a[i] * sc;
            i = i + 1;
        };
        m = m / n;
        let s = 0.0;
        i = 0;
        while (i < n) {
            let d = a[i] * sc - m;
            s = s + d * d;
            i = i + 1;
        };
        ldexp(s / (n - 1), 2 * e)
    }
};
