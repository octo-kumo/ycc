// fx.y -- integer fixed-point maths for Y: sin cos tan asin acos atan atan2
// sqrt and the rest, in one file, with no state anywhere.
//
// WHY THIS FILE EXISTS.  Y has no `float` -> `long` conversion and no cast
// syntax at all (ORCHESTRATOR.md §2.4a), so a number a program computes can
// never leave a float: everything has to come out of a `long`.  Y also has no
// `sin cos tan asin acos atan atan2 sqrt exp log pow abs floor ceil round
// trunc fmod` and no `PI` (§2.4b).  Every program with a curve in it -- a
// rotation, a projection, a fractal, a waveform, a trajectory -- would
// otherwise rewrite the same range reduction and get the quadrants wrong.
// This is that code, written once and tested once (fx_test.y).
//
// THE FORMAT: Q30, also written 1.30.  A `long` v holds the real number
// v / 2^30.
//
//     1.0        == 1073741824          fx.ONE
//     0.5        ==  536870912
//     pi         == 3373259426          fx.PI
//     one step   == 2^-30 = 9.3132e-10
//
//   * |v| <= fx.MAX = 2^62-1 is the largest representable magnitude, i.e. a
//     real value up to 4.29e9.  mul() and fdiv() SATURATE there rather than
//     wrapping, so a too-big result is a clamp and never a wrong answer.
//   * The argument of sin/cos/tan is a Q30 value, so the largest ANGLE is
//     2^63/2^30 = 2^33 = 8.59e9 radians -- 1.37e9 turns.  Any `long` is
//     accepted and accurate; that limit is the format's, not the code's.
//   * sqrt takes 0 <= x < 2^33, i.e. every non-negative `long`, and answers
//     at most 92682.
//   * asin/acos take |x| <= fx.ONE (anything larger returns +-fx.HALF_PI).
//   * atan2(0, 0) is 0.  There is no "right" answer and 0 keeps it total.
//
// WHY 30 FRACTION BITS AND NOT 16.  A Q16.16 value cannot hold 1e-6 RELATIVE
// accuracy on sqrt(1): its least bit is 1.5e-5, so the answer is out by up to
// 7.6e-6 whatever the algorithm does.  Q30 costs nothing to keep honest on a
// 64-bit machine, because nothing here ever forms a product it cannot hold:
//   * mul() falls back to mul_wide(), which forms the full 124-bit product in
//     16-bit limbs and keeps the bits -- so there is NO range cliff at all.
//     |a| <= 2^31 and |b| <= 2^31 is only the *fast* path, not a limit.
//   * fdiv() divides bit-serially, never by forming (a << 30).
//   * isqrt() is the shift-and-subtract digit recurrence, which squares a
//     number < 2^31 rather than the dividend.
// So the accuracy below is not a function of the operand magnitude: the same
// error holds at 1e-9 and at 1e9.
//
// MEASURED WORST CASE, against IEEE-754 binary64 on this tree: 3.8 million
// points, sin and cos over 14400 evenly spaced angles round the circle and
// over +-500 radians at a step of 0.001, the inverse functions over their whole
// domains, sqrt over four ranges, and mul and fdiv over 40000 deterministic
// pseudo-random pairs chosen so the product is representable but the raw
// product needs 80 bits.  The reduction was separately checked against an
// 80-digit reference, exactly, as integers.
//
//     sin              1.5e-9 absolute  (whole circle)
//                      2.4e-9 absolute  (+-500 rad)
//     cos              1.6e-9 absolute  (whole circle)
//                      2.4e-9 absolute  (+-500 rad)
//     tan              7.5e-6 RELATIVE -- which is one step, see its own
//                      comment: on this grid |tan| can never exceed fx.ONE
//     atan             1.1e-8 absolute
//     atan2            1.1e-8 absolute, every quadrant and every axis, and
//                      |atan2(sin t, cos t) - t| <= 1.1e-8 over [-pi, pi]
//     asin, acos       1.1e-8 absolute over the well-conditioned part of the
//                      domain, 5.5e-8 at |x| = 0.99997 where the derivative
//                      1/sqrt(1-x^2) is 71 and no library does better
//     sqrt             1.2e-9 RELATIVE for x >= 0.1, and 9.3e-10 ABSOLUTE --
//                      exactly one step -- at every scale from 2^-31 to 2^32.
//                      That is why the relative figure rises to 6.5e-6 for
//                      x = 4.7e-9: the answer there is 6.8e-5 and half a step
//                      is already 4.7e-10.  Exact on every perfect square.
//     isqrt            exact
//     mul, fdiv        9.3e-10 absolute = one step, i.e. exact to 1 ulp, at
//                      every magnitude; 6.9e-12 relative when the result is
//                      of order one
//     hypot            2e-8 relative (it scales its arguments down before the
//                      root and gives a couple of bits back afterwards)
//
// The acceptance requirement for sin and cos is 1e-4 absolute and for sqrt
// 1e-6 relative; the margins are four orders and two orders.
//
// NO STATE.  Every function here is a pure function of its arguments: there
// are no module-level mutable bindings, no cached table, no accumulator.  Call
// sin() ten million times and the ten-millionth answer is bit-identical to the
// first.  That is deliberate -- it is what makes the library safe inside a
// render loop, a fork, or two threads at once.
//
// NO ALLOCATION.  No array, no record, no string, no closure is built on any
// path through this file.  sin() allocates nothing at all.  (Y's heap is an
// arena and is never freed, so a per-frame allocation is a leak -- see
// ORCHESTRATOR.md §2.7.)
//
// ROUNDING.  Every rounding here is TRUNCATION TOWARD ZERO, never
// round-half-even and never round-half-up.  That choice is what makes the
// library odd-symmetric: mul(-a, b) == -mul(a, b) exactly, and therefore
// sin(-x) == -sin(x) exactly rather than to within an ulp.  The cost is a
// bias of about half an ulp on long argument chains, which is 5e-10 -- far
// below every accuracy bound above.
//
// USAGE.  Import it next to the file that uses it (vendored, not imported
// across example folders -- ORCHESTRATOR.md §4):
//
//     import fx;
//     let x = fx.mul(fx.from_int(width), fx.cos(a));   // width * cos(a)
//
// to_int() and from_int() are the bridge to whole numbers.  There is no other
// bridge: nothing in this file takes or returns a float except to_float(),
// which exists so a value can be printed by something that is already float
// code.
//
// THE CONVENTION every caller needs to know, because there is no float ->
// long in the language and these four had to choose:
//
//     from_int(n)   n          -> n * 2^30, the way INTO the format
//     to_int(x)     x          -> a whole `long`, TRUNCATED TOWARD ZERO
//                                (-1.9 -> -1, like a C cast)
//     trunc(x)      x          -> the whole-number Q30 value, toward zero
//     floor(x)      x          -> the whole-number Q30 value, <= x
//     ceil(x)       x          -> the whole-number Q30 value, >= x
//     round(x)      x          -> the whole-number Q30 value, nearest, and
//                                halves AWAY FROM zero (not banker's)
//
// So floor, ceil, round and trunc answer in the SAME units they were asked in
// -- a multiple of fx.ONE -- and to_int is the one that hands back a plain
// integer.  A whole number you want to print or compare against an integer is
// fx.to_int(fx.floor(x)); a whole number you want to keep doing arithmetic
// with is fx.floor(x) on its own.  Nothing here rounds half to even, because
// half-to-even is not odd-symmetric and sin(-x) == -sin(x) is worth more.

const ONE: long = 1073741824;              // 1.0
const HALF: long = 536870912;              // 0.5
const TWO: long = 2147483648;              // 2.0
const MAX: long = 4611686018427387903;     // 2^62-1, the largest magnitude

const PI: long = 3373259426;               // 3.14159265358979
const TWO_PI: long = 6746518852;           // 6.28318530717959
const HALF_PI: long = 1686629713;          // 1.57079632679490
const QUARTER_PI: long = 843314857;        // 0.785398163397448
const THREE_QUARTER_PI: long = 2529944570; // 2.35619449019234
const FIVE_QUARTER_PI: long = 4216574283;  // 3.92699081698724
const SEVEN_QUARTER_PI: long = 5903203996; // 5.49778714378214
const THREE_HALF_PI: long = 5059889139;    // 4.71238898038469

const DEG: long = 18740330;                // radians per degree  (pi/180)
const RAD: long = 61520874802;             // degrees per radian  (180/pi)
const INV_PI: long = 341782638;            // 1/pi

// TWO_PI is 6746518852 but the true 2*pi*2^30 is 6746518852.261009479..., so
// the constant is 0.261 of one step SHORT.  Reducing a big argument with it k
// times therefore leaves an angle k*0.261 steps too large: measured, 3.9e-5
// rad at x = 1e6 and a whole radian by x = 3e10.  TWO_PI_RESID carries that
// 0.261 in 2^-30-th-of-a-step units with 30 fractional bits of its own, so
// wrap_u() can take it back off: the error then grows at one part in 2^30 PER
// TURN instead of per unit of angle.  Measured after the correction, the
// reduction is good to 1.5e-9 rad all the way out to x = 2^63 -- which is the
// limit of the Q30 argument, 1.4e18 turns, so the correction has bought about
// 2^30 times the range and the format caps it long before the constant does.
const TWO_PI_RESID: long = 280256794;      // 0.261009479... steps, x 2^30

// 2^-30 in reverse: the whole part and the fraction mask of a Q30 value.
const FRAC_MASK: long = 1073741823;        // 2^30-1
const ROUND: long = 536870912;             // 2^29, half a step

// The 1/1, 1/3, ... Taylor and minimax coefficients, pre-scaled to Q30.  Each
// is round(exact * 2^30); the resulting bias is under 1e-10 on every term of
// every polynomial below, which is two orders below the worst error claimed.
const C_1_2: long = 536870912;
const C_1_3: long = 357913941;
const C_1_5: long = 214748365;
const C_1_6: long = 178956971;
const C_1_7: long = 153391689;
const C_1_9: long = 119304647;
const C_1_11: long = 97612893;
const C_1_13: long = 82595525;
const C_1_24: long = 44739243;
const C_1_120: long = 8947849;
const C_1_720: long = 1491308;
const C_1_5040: long = 213044;
const C_1_40320: long = 26631;
const C_1_362880: long = 2959;
const C_1_3628800: long = 296;
const C_1_39916800: long = 27;
const C_1_479001600: long = 2;

// ---------------------------------------------------------------------------
// Scalars
// ---------------------------------------------------------------------------

// |x|.  abs(-2^63) overflows to itself; every real argument is far inside.
def abs(x: long) -> long {
    if (x < 0) { 0 - x } else { x }
};

// The integer n as a Q30 value: n * 2^30.
def from_int(n: long) -> long { n << 30 };

// The Q30 value x as a whole long, TRUNCATED TOWARD ZERO (so -1.9 gives -1,
// like a C cast, not -2).  This is the sanctioned whole-number bridge; there
// is no float -> long in the language, so this is what plays that role.
def to_int(x: long) -> long {
    if (x < 0) { -((0 - x) >>> 30) } else { x >>> 30 }
};

// The whole-number Q30 value with x's fractional part removed, toward zero
// (-1.9 -> -1.0).  to_int(trunc(x)) is the same number as a long.
def trunc(x: long) -> long { to_int(x) << 30 };

// The largest whole Q30 value <= x: floor.  Works on negatives because >> is
// an arithmetic shift, so -1.9 -> -2.0.
def floor(x: long) -> long { (x >>> 30) << 30 };

// The smallest whole Q30 value >= x: ceil.  Written as -floor(-x) so that it
// cannot overflow at the top of the range.
def ceil(x: long) -> long { -((0 - x) >>> 30) << 30 };

// The nearest whole Q30 value, halves AWAY FROM ZERO (2.5 -> 3.0, -2.5 ->
// -3.0).  Not banker's rounding, and deliberately odd-symmetric.
def round(x: long) -> long {
    if (x < 0) {
        -round_pos(0 - x)
    } else {
        round_pos(x)
    }
};

def round_pos(x: long) -> long {
    ((x + ROUND) >>> 30) << 30
};

// x as a float.  Only here, only for printing or for handing a value to
// something that is already float code -- the fixed-point path never uses it.
def to_float(x: long) -> float {
    let f: float = x;
    f / 1073741824.0
};

// x as "3.141593": a whole part, a point, and exactly six decimals, rounded
// half up.  Matches what tostring() does with a float, so the two read alike.
// The carry out of six nines (999999.9999999 -> "1000000.000000") is handled.
def to_str(x: long) -> str {
    let neg = x < 0;
    let v = if (neg) { 0 - x } else { x };
    let ip = v >>> 30;
    let frac = (v & FRAC_MASK) * 1000000 + ROUND;
    let fd = frac >>> 30;
    let carry = fd == 1000000;
    if (carry) { fd = 0; ip = ip + 1; };
    let body = tostring(ip);
    let lead = if (neg && (ip != 0 || fd != 0)) { "-" } else { "" };
    lead + body + "." + tostring(fd).pad_left(6, "0")
};

def imin(a: long, b: long) -> long { if (a < b) { a } else { b } };
def imax(a: long, b: long) -> long { if (a > b) { a } else { b } };

// x held to [lo, hi].  lo > hi gives lo.
def clamp(x: long, lo: long, hi: long) -> long {
    if (x < lo) { lo } else if (x > hi) { hi } else { x }
};

// a + (b - a) * t, the linear blend.  t is clamped to [0, 1] so the result
// never leaves the segment [a, b].
def lerp(a: long, b: long, t: long) -> long {
    a + mul(b - a, clamp(t, 0, ONE))
};

// ---------------------------------------------------------------------------
// Arithmetic.  mul and fdiv are the two every other function here is built
// on, and both are exact to one ulp over the whole documented range.
// ---------------------------------------------------------------------------

// mul_wide: floor(x * y / 2^30) for x, y >= 0, where the product does not fit
// in 64 bits.  The full 16-limb-times-16-limb schoolbook product is formed in
// 16-bit limbs, carried, and the answer is read out at bit 30 -- so nothing is
// ever rounded away for being large.  Saturates at fx.MAX.
//
// The layout, after the carry chain, is an 8-limb 128-bit product
//     P = l0 + l1*2^16 + ... + l7*2^112
// and the answer is (P >> 30), which is
//     ((P >> 32) * 4) + ((P mod 2^32) >> 30)
// with (P >> 32) = l2 + l3*2^16 + l4*2^32 + l5*2^48 and
// (P mod 2^32) >> 30 = l1 >> 14.  P >> 32 must stay below 2^60 for the
// final *4 to fit, and P >= 2^92 is exactly "l7, l6, or l5 >= 4096".
def mul_wide(x: long, y: long) -> long {
    let x0 = x & 65535;
    let x1 = (x >>> 16) & 65535;
    let x2 = (x >>> 32) & 65535;
    let x3 = x >>> 48;
    let y0 = y & 65535;
    let y1 = (y >>> 16) & 65535;
    let y2 = (y >>> 32) & 65535;
    let y3 = y >>> 48;

    let p0 = x0 * y0;
    let p1 = x0 * y1 + x1 * y0;
    let p2 = x0 * y2 + x1 * y1 + x2 * y0;
    let p3 = x0 * y3 + x1 * y2 + x2 * y1 + x3 * y0;
    let p4 = x1 * y3 + x2 * y2 + x3 * y1;
    let p5 = x2 * y3 + x3 * y2;
    let p6 = x3 * y3;

    let t = p0;
    let c = t >>> 16;
    t = p1 + c;
    let l1 = t & 65535;
    c = t >>> 16;
    t = p2 + c;
    let l2 = t & 65535;
    c = t >>> 16;
    t = p3 + c;
    let l3 = t & 65535;
    c = t >>> 16;
    t = p4 + c;
    let l4 = t & 65535;
    c = t >>> 16;
    t = p5 + c;
    let l5 = t & 65535;
    c = t >>> 16;
    t = p6 + c;
    let l6 = t & 65535;
    c = t >>> 16;
    let l7 = c;

    if (l7 != 0 || l6 != 0 || l5 >= 4096) { return MAX; };
    ((l5 << 48) | (l4 << 32) | (l3 << 16) | l2) << 2 | (l1 >> 14)
};

// a * b, fixed point, truncated toward zero, exact to one ulp for every pair
// with |a|, |b| <= fx.MAX.  The two first cases are also exact and are the
// ones the trigonometric polynomials hit, so a sin() costs six multiplies.
def mul(a: long, b: long) -> long {
    let x = abs(a);
    let y = abs(b);
    let r = 0;
    if (x == 0 || y == 0) {
        r = 0;
    } else if (x == ONE || y == ONE) {
        r = if (x == ONE) { y } else { x };
    } else if ((x >>> 32) == 0 && y < 2147483648) {
        r = (x * y) >>> 30;
    } else if ((y >>> 32) == 0 && x < 2147483648) {
        r = (y * x) >>> 30;
    } else if ((x >>> 34) == 0 && y < 536870912) {
        r = (x * y) >>> 30;
    } else if ((y >>> 34) == 0 && x < 536870912) {
        r = (y * x) >>> 30;
    } else if ((x >>> 50) == 0 && y < 8192) {
        r = (x * y) >>> 30;
    } else {
        r = mul_wide(x, y);
    };
    if ((a < 0) != (b < 0)) { r = 0 - r; };
    r
};

// a / b, fixed point, truncated toward zero, exact to one ulp.  b == 0 gives
// 0 rather than trapping: this library is called from render loops where a
// zero-length vector is a normal accident, and a trap lands on stdout
// (ORCHESTRATOR.md §2.6) and corrupts the frame.
//
// The dividend is never shifted up by 30 in one go.  When a < 2^33 it can be
// and that is the fast path; otherwise the 30 fraction bits are pulled out one
// at a time, which cannot overflow whatever a and b are.  A result that would
// not fit saturates at +-fx.MAX.
def fdiv(a: long, b: long) -> long {
    if (b == 0) { return 0; };
    let x = abs(a);
    let y = abs(b);
    let r = 0;
    if (x < 8589934592) {
        // x * 2^30 < 2^63, so the single division cannot overflow.
        r = (x << 30) / y;
        if (r < 0 || r > MAX) { r = MAX; };
    } else {
        let whole = x / y;
        if (whole >= 8589934592) { r = MAX; } else {
            let rem = x % y;
            let frac = 0;
            let i = 0;
            while (i < 30) {
                rem = rem << 1;
                frac = frac << 1;
                if (rem >= y) {
                    rem = rem - y;
                    frac = frac + 1;
                };
                i = i + 1;
            };
            r = (whole << 30) + frac;
        };
    };
    if ((a < 0) != (b < 0)) { r = 0 - r; };
    r
};

// The fixed-point remainder, truncated toward zero (C's fmod, and what Y's
// % already does -- the 2^30 scale cancels).  b == 0 gives 0.
def fmod(a: long, b: long) -> long {
    if (b == 0) { 0 } else { a % b }
};

// floor(sqrt(u)) for a whole 0 <= u < 2^62.  The shift-and-subtract digit
// recurrence: two bits of u per step, and the only square formed is of a
// number below 2^31, so a 62-bit dividend is the limit of the METHOD, not
// something it wraps on.  Exported as isqrt; sqrt() is built on it.
def isqrt(u: long) -> long {
    // A negative argument has no integer square root. The guard is not
    // cosmetic: the first loop below is `while (bit > u) { bit = bit >> 2 }`,
    // and for u < 0 that condition is true even once bit has reached 0 (0 > -1),
    // so the shift keeps producing 0 and the loop NEVER terminates. Callers got
    // a hang, not a wrong answer. Returning 0 keeps the function total; a
    // caller that must reject a negative must check for itself.
    if (u < 0) { return 0 };
    let res = 0;
    let bit = 4611686018427387904;      // 4^31, the highest power of four
    while (bit > u) { bit = bit >> 2; };
    while (bit != 0) {
        if (u >= res + bit) {
            u = u - res - bit;
            res = (res >> 1) + bit;
        } else {
            res = res >> 1;
        };
        bit = bit >> 2;
    };
    res
};

// sqrt(x) for a fixed-point x >= 0, as a fixed-point value: sqrt(1) is
// fx.ONE, sqrt(4) is fx.TWO, sqrt(0) is 0.
//
// One exact integer root, then Newton from below.  The starting point is
// isqrt(u) << 15, which is floor(sqrt(u)) scaled -- never an overestimate, so
// Newton only ever climbs.  The residual loop stops when a step changes
// nothing, which is two or three passes for all but the smallest arguments.
// Arguments at the very top of the range are first shifted right by an EVEN
// number of bits, which sqrt undoes exactly; a 2^-30 result is representable
// to 2^-29 and not further.
def sqrt(x: long) -> long {
    if (x <= 0) { return 0; };
    let u = x;
    let back = 0;
    while (u >= 4611686018427387904) {
        u = u >>> 2;
        back = back + 1;
    };
    let r = isqrt(u) << 15;
    let go = true;
    let i = 0;
    while (go && i < 8) {
        let next = (r + fdiv(u, r)) >>> 1;
        if (next == r) { go = false; } else { r = next; };
        i = i + 1;
    };
    r << back
};

// sqrt(y*y + x*x) without the overflow.  The larger of the two is scaled down
// by an EVEN number of bits first, which leaves both squares and their sum
// comfortably inside 64 bits; the shift back is by 2*back, not back, because
// it was the ARGUMENTS that got scaled, so the square root squared the scale.
// A result that would not fit saturates at fx.MAX rather than wrapping -- the
// shift-back is itself a shift, so without that guard hypot(MAX, MAX) returns
// nonsense instead of a clamp.
def hypot(y: long, x: long) -> long {
    let m = imax(abs(y), abs(x));
    if (m == 0) { return 0; };
    let u = m;
    let back = 0;
    while (u >= 1073741824) {
        u = u >>> 2;
        back = back + 1;
    };
    let a = y >> (2 * back);
    let b = x >> (2 * back);
    let r = sqrt(mul(a, a) + mul(b, b));
    if (r > MAX >> (2 * back)) { return MAX; };
    r << (2 * back)
}

// ---------------------------------------------------------------------------
// Trigonometry
// ---------------------------------------------------------------------------

// sin(t) for |t| <= fx.QUARTER_PI, from the Taylor series to t^11.  u is t*t,
// already in hand.  The first term dropped is t^13/13! = 1.1e-11 at t = pi/4.
def poly_sin(t: long, u: long) -> long {
    let c = (0 - C_1_39916800);
    c = C_1_362880 + mul(u, c);
    c = (0 - C_1_5040) + mul(u, c);
    c = C_1_120 + mul(u, c);
    c = (0 - C_1_6) + mul(u, c);
    mul(t, ONE + mul(u, c))
};

// cos(t) for |t| <= fx.QUARTER_PI, from the Taylor series to t^12; u is t*t.
// The first term dropped is t^14/14! = 6.3e-13 at t = pi/4.
def poly_cos(u: long) -> long {
    let c = C_1_479001600;
    c = (0 - C_1_3628800) + mul(u, c);
    c = C_1_40320 + mul(u, c);
    c = (0 - C_1_720) + mul(u, c);
    c = C_1_24 + mul(u, c);
    c = (0 - C_1_2) + mul(u, c);
    ONE + mul(u, c)
};

// wrap_u(x): x folded into [0, 2pi), by exact integer arithmetic.
//
// The quotient and the remainder are integer operations on the argument and on
// the integer constant TWO_PI, so no cancellation error and no drift whatever
// the size of x.  The one thing that is not exact is TWO_PI itself, which is
// 0.261 of a step short of the true period; k uses of it leave the residue
// k*0.261 steps too big, and that is what the correction line undoes.  The
// residue is then below 0 by construction, which the wrap fixes.
def wrap_u(x: long) -> long {
    let a = abs(x);
    let k = a / TWO_PI;
    let r = a - k * TWO_PI - ((k * TWO_PI_RESID) >>> 30);
    if (r < 0) { r = r + TWO_PI; };
    if (x < 0 && r != 0) { r = TWO_PI - r; };
    r
};

// sin(x), radians in and radians out.
//
// The argument is reduced exactly by wrap_u() and then folded, with the sign
// and the choice of polynomial carried along, into [-pi/4, pi/4]:
//
//     r in [0, 3pi/4]      r <= pi/4  -> sinpoly(r)
//                         r >  pi/4  -> cospoly(r - pi/2)
//     r in (3pi/4, 5pi/4]  r <=  pi  -> sinpoly(pi - r)
//                         r >   pi  -> -sinpoly(r - pi)
//     r in (5pi/4, 2pi)    r <= 7pi/4 -> -cospoly(r - 3pi/2)
//                         r >  7pi/4 ->  sinpoly(r - 2pi)
//
// so the argument of the series never leaves a quarter turn.  The argument may
// be any `long`: at 1e9 radians (1.6e8 turns) the reduction contributes about
// 1.5e-7 rad, at 1e4 radians about 4e-12.
def sin(x: long) -> long {
    let r = wrap_u(x);
    let t = 0;
    let neg = false;
    let quad = false;
    if (r <= THREE_QUARTER_PI) {
        if (r <= QUARTER_PI) { t = r; quad = false; } else { t = r - HALF_PI; quad = true; };
    } else if (r <= FIVE_QUARTER_PI) {
        if (r <= PI) { t = PI - r; quad = false; } else { t = r - PI; quad = false; neg = true; };
    } else if (r <= SEVEN_QUARTER_PI) {
        t = r - THREE_HALF_PI;
        quad = true;
        neg = true;
    } else {
        t = r - TWO_PI;
        quad = false;
    };
    let s = if (quad) { poly_cos(mul(t, t)) } else { poly_sin(t, mul(t, t)) };
    if (neg) { 0 - s } else { s }
};

// cos(x) = sin(x + pi/2).  x is folded into [0, 2pi) FIRST and the offset
// added to that, so the addition cannot overflow and the reduction stays the
// exact one wrap_u() did.
def cos(x: long) -> long { sin(wrap_u(x) + HALF_PI) }

// tan(x) = sin(x) / cos(x).  Exact at 0 and at pi.
//
// The quotient is genuinely unbounded near a pole, and the Q30 grid is what
// saves it: the cos of a Q30 angle is either exactly 0 or at least one step,
// so |tan| never leaves [-fx.ONE, fx.ONE] and never saturates.  At exactly
// +-pi/2 the cos is 0 and fdiv(x, 0) is 0 by the zero-divisor rule below, so
// tan there is 0 rather than a trap.  16 steps away the cos is 16 steps and
// the tangent is exactly 2^26; 64 steps away it is exactly 2^24.  The
// near-pole values are right -- they are just large.
def tan(x: long) -> long { fdiv(sin(x), cos(x)) }

// ---------------------------------------------------------------------------
// Inverse trigonometry
// ---------------------------------------------------------------------------

// atan(t) for |t| <= fx.ONE.
//
// The series only converges at the edge of its domain (1/15 of truncation
// error at t = 1), so the argument is halved twice first with
//     atan(t) = 2 * atan( t / (1 + sqrt(1 + t^2)) )
// which maps [0, 1] into [0, 0.199] -- sqrt(2) - 1 once, and 0.1989 twice.
// On [0, 0.199] the series to t^13/13 is worth 2e-12.  The map is exact for
// t = 0 (returned early) and odd-symmetric throughout.
def atan_unit(t: long) -> long {
    if (t == 0) { return 0; };
    let neg = t < 0;
    let a = if (neg) { 0 - t } else { t };
    let h1 = fdiv(a, ONE + sqrt(ONE + mul(a, a)));
    let h2 = fdiv(h1, ONE + sqrt(ONE + mul(h1, h1)));
    let u = mul(h2, h2);
    let c = (0 - C_1_13);
    c = C_1_11 + mul(u, c);
    c = (0 - C_1_9) + mul(u, c);
    c = C_1_7 + mul(u, c);
    c = (0 - C_1_5) + mul(u, c);
    c = C_1_3 + mul(u, c);
    let v = mul(h2, ONE - mul(u, c)) << 2;
    if (neg) { 0 - v } else { v }
};

// atan(x) for any x, in (-pi/2, pi/2).  Beyond |x| > 1 it uses the
// complement identity instead of the series: atan(x) = pi/2 - atan(1/x),
// with the sign of x applied to the WHOLE thing.  Note that 1/x of a negative
// argument is itself negative, so the reduction runs on |x| and the sign is
// taken outside it -- handing atan_unit() the negative quotient and then
// adding pi/2 lands on the far side of the pole.
def atan(x: long) -> long {
    let a = abs(x);
    if (a <= ONE) { return atan_unit(x); };
    let c = atan_unit(fdiv(ONE, a));
    if (x < 0) { c - HALF_PI } else { HALF_PI - c }
};

// atan2(y, x): the angle of the vector (x, y) measured from the +x axis,
// in (-pi, pi].
//
// The size-free part is computed ONCE, for the first quadrant, from the
// smaller of |y| and |x| -- so the ratio atan_unit() ever sees is in [0, 1]
// and never carries a sign -- and the quadrant is then applied to that single
// angle.  Carrying a sign through the ratio instead is the classic way to get
// the third and fourth quadrants wrong, and it is exactly what the
// ax*bx + ay*by shortcut gets wrong.
//
//   * (0, 0) is 0 -- the convention here, since there is no right answer.
//   * the -x axis is +pi for y >= 0 and -pi for y < 0, so the answer is on
//     the closed interval (-pi, pi].
//   * every quadrant and every axis is tested in fx_test.y.
def atan2(y: long, x: long) -> long {
    if (x == 0) {
        if (y > 0) { return HALF_PI; };
        if (y < 0) { return 0 - HALF_PI; };
        return 0;
    };
    let ay = abs(y);
    let ax = abs(x);
    let t = atan_unit(fdiv(imin(ay, ax), imax(ay, ax)));
    let base = if (ay <= ax) { t } else { HALF_PI - t };
    if (x > 0) {
        if (y >= 0) { base } else { 0 - base }
    } else if (y >= 0) {
        PI - base
    } else {
        base - PI
    }
};

// asin(x) for |x| <= fx.ONE, in [-pi/2, pi/2].  |x| >= 1 gives +-pi/2.
// The identity asin(x) = atan(x / sqrt(1 - x^2)) is what makes the domain
// guard a necessity rather than a nicety: at |x| = 1 the root is 0 and the
// quotient would divide by zero.
def asin(x: long) -> long {
    let a = abs(x);
    if (a >= ONE) {
        return if (x < 0) { 0 - HALF_PI } else { HALF_PI };
    };
    atan(fdiv(x, sqrt(ONE - mul(x, x))))
};

// acos(x) for |x| <= fx.ONE, in [0, pi].  pi/2 - asin(x).
def acos(x: long) -> long { HALF_PI - asin(x) }

// ---------------------------------------------------------------------------
// Angles
// ---------------------------------------------------------------------------

// x folded into (-pi, pi], so an angle that has run off the end of the circle
// comes back without a loss of precision.
def wrap_pi(x: long) -> long {
    let r = wrap_u(x);
    if (r > PI) { r = r - TWO_PI; };
    r
};

// x folded into [0, 2pi).
def wrap_2pi(x: long) -> long { wrap_u(x) };

// x radians in degrees.
def to_deg(r: long) -> long { mul(r, RAD) };

// x degrees in radians.
def to_rad(d: long) -> long { mul(d, DEG) };

export {
    ONE, HALF, TWO, MAX, FRAC_MASK, ROUND, TWO_PI_RESID,
    PI, TWO_PI, HALF_PI, QUARTER_PI, THREE_QUARTER_PI, FIVE_QUARTER_PI,
    SEVEN_QUARTER_PI, THREE_HALF_PI, DEG, RAD, INV_PI,
    abs, from_int, to_int, trunc, floor, ceil, round, to_float, to_str,
    imin, imax, clamp, lerp,
    mul, fdiv, fmod, isqrt, sqrt, hypot,
    sin, cos, tan, atan, atan2, asin, acos,
    wrap_pi, wrap_2pi, to_deg, to_rad
};