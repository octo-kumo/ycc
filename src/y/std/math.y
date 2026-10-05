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