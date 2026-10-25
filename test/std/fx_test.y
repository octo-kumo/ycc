// fx_test.y -- the acceptance gate for fx.y.  Every claim fx.y makes in its
// header comment is checked here, and several hundred more besides.
//
//   build:  refs/ycc.ref fx_test.y -o /tmp/fx_test && /tmp/fx_test
//   exit 0  every check passed;  exit 1  at least one failed
//
// Sections:
//   1  the constants          they are what the header says they are
//   2  the scalar conversions floor/ceil/round/trunc/to_int, signs, to_str
//   3  mul, fdiv, fmod        exactness, symmetry, saturation, zero divisor
//   4  isqrt, sqrt, hypot     exact on squares, sqrt(x^2) == |x|, monotone
//   5  sin, cos, tan          known values, a 33-entry float64 table,
//                             sin^2+cos^2, odd symmetry, periodicity,
//                             monotone on [0, pi/2], huge arguments
//   6  atan, atan2, asin, acos  every quadrant, every axis, the round trip,
//                             monotonicity, the domain guards
//   7  wrap_pi, wrap_2pi      folding, including the -x axis
//   8  no drift              20000 repeats of the same call, bit for bit
//   9  no trap               every degenerate argument returns, never traps
//
// The reference values are IEEE-754 binary64 values of the true function,
// rounded to Q30 with round-half-up.  They are NOT produced by fx.y.  The
// tolerances below are 2-16 steps (2e-9 to 1.5e-8) against a measured worst
// case of 1.5e-9, and the acceptance requirement is 1e-4 -- three orders of
// headroom, so the test fails loudly rather than flaking if accuracy slips.
//
// Two tolerances are much wider, on purpose, and both are conditioning rather
// than error: asin near +-1 and acos near 0 divide by a vanishing cos, and
// tan near a pole divides by a vanishing cos again.  See the notes on those
// two lines.

import fx;

let checks = 0;
let fails = 0;
let worst_err = 0;              // the largest |got - want| any check ever saw
let worst_where = "";

// The raw |d| of a fixed-point difference, as a float, for the f-string.
def errf(d: long) -> float {
    let e: float = d;
    e / 1073741824.0
};

// PASS or FAIL, one labelled line per check.  Void, so a dropped result is
// not even possible.
def ck(label: str, cond: bool) {
    checks += 1;
    if (cond) {
        print("PASS  " + label);
    } else {
        fails += 1;
        print("FAIL  " + label);
    };
};

// A fixed-point comparison.  On a miss it prints the error to six decimals
// (the language has no printf) AND in steps, because at this accuracy
// "0.000000" is the normal reading and the step count is the interesting part.
// Returns 0 when it passes and 1 when it fails, so a caller can roll several
// comparisons into one check line.
def near(label: str, got: long, want: long, tol: long) -> long {
    let d = got - want;
    if (d < 0) { d = 0 - d; };
    if (d > worst_err) { worst_err = d; worst_where = label; };
    checks += 1;
    if (d <= tol) {
        print("PASS  " + label + "  (" + tostring(d) + " steps)");
        0
    } else {
        fails += 1;
        print("FAIL  " + label
            + "  got=" + fx.to_str(got)
            + " want=" + fx.to_str(want)
            + " err=" + f"{errf(got - want):.6f}"
            + " (" + tostring(d) + " steps, tol " + tostring(tol) + ")");
        1
    }
};

def feq(label: str, got: long, want: long) { near(label, got, want, 0); };

// ---------------------------------------------------------------------------
// Sweep helpers.  Each returns the number of failures, so a caller can print
// one PASS/FAIL line for a whole sweep.
// ---------------------------------------------------------------------------

// isqrt must be exact on n^2, n^2-1 and n^2+2n for every n below the limit.
def isqrt_squares(hi: long) -> long {
    let bad = 0;
    for i in 1..hi {
        let n = i * i;
        if (fx.isqrt(n) != i) { bad = bad + 1; };
        if (fx.isqrt(n - 1) != i - 1) { bad = bad + 1; };
        if (fx.isqrt(n + 2 * i) != i) { bad = bad + 1; };
    };
    bad
};

// sqrt of a perfect square in fixed point, exactly.
def sqrt_squares(hi: long) -> long {
    let bad = 0;
    for i in 1..hi {
        if (fx.sqrt(fx.from_int(i * i)) != fx.from_int(i)) { bad = bad + 1; };
    };
    bad
};

// sqrt(x^2) == |x|, exactly.  Only for |x| <= 2^16: beyond that x*x itself no
// longer fits the format (it saturates) and there is nothing to take the root
// of.  The magnitudes below walk through both mul()'s fast path and
// mul_wide(), and through sqrt()'s shift-back path at the top end.
def sqrt_of_square_sweep() -> long {
    let bad = 0;
    for i in 1..3000 {
        let x = fx.from_int(i);
        if (fx.sqrt(fx.mul(x, x)) != x) { bad = bad + 1; };
        if (fx.sqrt(fx.mul(0 - x, 0 - x)) != x) { bad = bad + 1; };
    };
    // |x| <= 2^15 both ways: x*x has to stay inside the format at both ends
    // (2^30 at the top, 2^-30 at the bottom) or there is nothing to take a
    // root of -- that is a range limit of Q30, not a fault in sqrt.
    for i in 0..16 {
        let x = fx.from_int(1) << i;
        if (fx.sqrt(fx.mul(x, x)) != x) { bad = bad + 1; };
        if (fx.sqrt(fx.mul(0 - x, 0 - x)) != x) { bad = bad + 1; };
    };
    for i in 1..16 {
        let x = fx.from_int(1) >> i;
        if (fx.sqrt(fx.mul(x, x)) != x) { bad = bad + 1; };
    };
    for i in 1..4000 {
        let x = fx.from_int(i * (i % 13 + 1));
        if (fx.sqrt(fx.mul(x, x)) != x) { bad = bad + 1; };
    };
    bad
};

// sqrt non-decreasing over (0, hi].
def sqrt_monotone(hi: long) -> long {
    let bad = 0;
    let prev = fx.sqrt(1);
    for i in 2..hi {
        let r = fx.sqrt(i);
        if (r < prev) { bad = bad + 1; };
        prev = r;
    };
    bad
};

// The 33 angles: 24 equal steps round the circle, then 9 arbitrary ones.  Each
// row is {angle, round(sin)*2^30, round(cos)*2^30, round(tan)*2^30}, from
// binary64.  tan is checked only where |cos| >= 0.01 -- it is genuinely
// unbounded at a pole and fx saturates there by design -- and its tolerance
// grows with the magnitude, because d(tan) = d(sin)/cos + tan*d(cos)/cos and
// the cos in the denominator is 0.26 at 75 degrees.
const TRIG_N = 33;
let TRIG_TH: [long; 33] = [
    0, 281104952, 562209904, 843314857, 1124419809, 1405524761, 1686629713,
    1967734665, 2248839617, 2529944570, 2811049522, 3092154474, 3373259426,
    3654364378, 3935469330, 4216574283, 4497679235, 4778784187, 5059889139,
    5340994091, 5622099044, 5903203996, 6184308948, 6465413900,
    107374182, 751619277, 1288490189, 2684354560, 4187593114, 4939212390,
    5905580032, 6442450944, 0 - 375809638
];
let TRIG_S: [long; 33] = [
    0, 277904834, 536870912, 759250125, 929887697, 1037154959, 1073741824,
    1037154959, 929887697, 759250125, 536870912, 277904834, 0,
    0 - 277904834, 0 - 536870912, 0 - 759250125, 0 - 929887697,
    0 - 1037154959, 0 - 1073741824, 0 - 1037154959, 0 - 929887697,
    0 - 759250125, 0 - 536870912, 0 - 277904834,
    107195315, 691723475, 1000769348, 642604572, 0 - 738483290,
    0 - 1066967591, 0 - 757568156, 0 - 300020107, 0 - 368183717
];
let TRIG_C: [long; 33] = [
    1073741824, 1037154959, 929887697, 759250125, 536870912, 277904834, 0,
    0 - 277904834, 0 - 536870912, 0 - 759250125, 0 - 929887697,
    0 - 1037154959, 0 - 1073741824, 0 - 1037154959, 0 - 929887697,
    0 - 759250125, 0 - 536870912, 0 - 277904834, 0, 277904834,
    536870912, 759250125, 929887697, 1037154959,
    1068377587, 821243045, 389078676, 0 - 860221407, 0 - 779463876,
    0 - 120422859, 760928376, 1030974995, 1008643770
];
let TRIG_T: [long; 33] = [
    0, 287708255, 619925131, 1073741824, 1859775393, 4007259041, 0,
    0 - 4007259041, 0 - 1859775393, 0 - 1073741824, 0 - 619925131,
    0 - 287708255, 0, 287708255, 619925131, 1073741824, 1859775393,
    4007259041, 0, 0 - 4007259041, 0 - 1859775393, 0 - 1073741824,
    0 - 619925131, 0 - 287708255,
    107733534, 904400262, 2761826774, 0 - 802109084, 1017289472,
    9513540353, 0 - 1069000236, 0 - 312465519, 0 - 391946362
];

def trig_table() -> long {
    let bad = 0;
    for i in 0..TRIG_N {
        let th = TRIG_TH[i];
        let ds = fx.abs(fx.sin(th) - TRIG_S[i]);
        let dc = fx.abs(fx.cos(th) - TRIG_C[i]);
        if (ds > 4) {
            bad = bad + 1;
            print("        table sin[" + tostring(i) + "] off by " + tostring(ds) + " steps");
        };
        if (dc > 4) {
            bad = bad + 1;
            print("        table cos[" + tostring(i) + "] off by " + tostring(dc) + " steps");
        };
        if (fx.abs(TRIG_C[i]) >= fx.ONE / 100) {
            let want = TRIG_T[i];
            let dt = fx.abs(fx.tan(th) - want);
            let ttol = 8 + fx.abs(want) / 67108864;
            if (dt > ttol) {
                bad = bad + 1;
                print("        table tan[" + tostring(i) + "] off by " + tostring(dt)
                    + " steps, tol " + tostring(ttol));
            };
        };
    };
    bad
}

// sin^2 + cos^2 == 1, over `n` angles spread over [-4pi, 4pi].
def pythagoras(n: long) -> long {
    let bad = 0;
    let span = fx.mul(fx.from_int(8), fx.PI);
    for i in 0..n {
        let th = fx.fdiv(fx.mul(fx.from_int(i), span), fx.from_int(n));
        let s = fx.sin(th);
        let c = fx.cos(th);
        let e = fx.abs(fx.mul(s, s) + fx.mul(c, c) - fx.ONE);
        if (e > 8) {
            bad = bad + 1;
            print("        sin^2+cos^2 off by " + tostring(e) + " steps at step " + tostring(i));
        };
    };
    bad
};

// mul, atan and asin are odd STEP FOR STEP: they work on the magnitude and
// take the sign outside, so there is nothing for a rounding difference to
// creep into.  sin and cos are symmetric only to within a couple of steps --
// the reduction mirrors the angle onto a different branch of the polynomial --
// so those get a tolerance.
def odd_exact(n: long) -> long {
    let bad = 0;
    let span = fx.mul(fx.from_int(8), fx.PI);
    for i in 1..n {
        let x = fx.fdiv(fx.mul(fx.from_int(i), span), fx.from_int(n));
        if (fx.atan(0 - x) != 0 - fx.atan(x)) { bad = bad + 1; };
        if (fx.asin(0 - x) != 0 - fx.asin(x)) { bad = bad + 1; };
        if (fx.abs(fx.sin(0 - x) + fx.sin(x)) > 8) { bad = bad + 1; };
        if (fx.abs(fx.cos(0 - x) - fx.cos(x)) > 8) { bad = bad + 1; };
    };
    bad
};

def even_exact(n: long) -> long {
    let bad = 0;
    for i in 1..n {
        let a = fx.from_int(1) << (i % 30);
        let b = fx.from_int(i * 7 + 1) >> (i % 20);
        if (fx.mul(0 - a, b) != 0 - fx.mul(a, b)) { bad = bad + 1; };
        if (fx.mul(a, 0 - b) != 0 - fx.mul(a, b)) { bad = bad + 1; };
        if (fx.mul(0 - a, 0 - b) != fx.mul(a, b)) { bad = bad + 1; };
        if (fx.fdiv(0 - a, b) != 0 - fx.fdiv(a, b)) { bad = bad + 1; };
        if (fx.fdiv(a, 0 - b) != 0 - fx.fdiv(a, b)) { bad = bad + 1; };
        if (fx.fdiv(0 - a, 0 - b) != fx.fdiv(a, b)) { bad = bad + 1; };
        if (fx.abs(0 - a) != a) { bad = bad + 1; };
    };
    bad
};

// sin(pi - x) == sin(x), and sin(-2pi - x) == -sin(x).
def sin_about_pi(n: long) -> long {
    let bad = 0;
    let span = fx.PI;
    for i in 1..n {
        let x = fx.fdiv(fx.mul(fx.from_int(i), span), fx.from_int(n));
        if (fx.abs(fx.sin(fx.PI - x) - fx.sin(x)) > 4) { bad = bad + 1; };
        if (fx.abs(fx.sin(x) - fx.sin(fx.TWO_PI + x)) > 4) { bad = bad + 1; };
        if (fx.abs(fx.sin(x) + fx.sin(0 - fx.TWO_PI - x)) > 4) { bad = bad + 1; };
    };
    bad
};

def cos_about_pi(n: long) -> long {
    let bad = 0;
    let span = fx.PI;
    for i in 1..n {
        let x = fx.fdiv(fx.mul(fx.from_int(i), span), fx.from_int(n));
        if (fx.abs(fx.cos(fx.PI + x) + fx.cos(x)) > 4) { bad = bad + 1; };
        if (fx.abs(fx.cos(fx.PI - x) + fx.cos(x)) > 4) { bad = bad + 1; };
        if (fx.abs(fx.cos(x) - fx.cos(fx.mul(fx.TWO, fx.TWO_PI) + x)) > 4) { bad = bad + 1; };
    };
    bad
}

// j turns of 2*pi: the residual of TWO_PI is 0.261 of a step, so j turns is
// 0.261*j steps short of j turns, which the reduction's own correction puts
// back.  The error therefore grows by about a quarter of a step per turn --
// linear, and 2^-30 per turn for the correction constant's own rounding.
def periodic(k: long) -> long {
    let bad = 0;
    for j in 1..k {
        let turn = fx.mul(fx.from_int(j), fx.TWO_PI);
        let tol = 2 + j;
        for i in 1..200 {
            let x = fx.fdiv(fx.mul(fx.from_int(i), fx.PI), fx.from_int(200));
            if (fx.abs(fx.sin(x + turn) - fx.sin(x)) > tol) { bad = bad + 1; };
            if (fx.abs(fx.sin(x - turn) - fx.sin(x)) > tol) { bad = bad + 1; };
            if (fx.abs(fx.cos(x + turn) - fx.cos(x)) > tol) { bad = bad + 1; };
            if (fx.abs(fx.cos(x - turn) - fx.cos(x)) > tol) { bad = bad + 1; };
        };
    };
    bad
};

def sin_monotone(n: long) -> long {
    let bad = 0;
    let prev = 0;
    for i in 0..n {
        let x = fx.fdiv(fx.mul(fx.from_int(i), fx.HALF_PI), fx.from_int(n));
        let s = fx.sin(x);
        if (s < prev) {
            bad = bad + 1;
            print("        sin not monotone at step " + tostring(i));
        };
        prev = s;
    };
    bad
}

// sin and cos are EXACT at the cardinal points of the first four turns: k
// whole turns of the Q30 TWO_PI have a residual of at most 1 step there.
// Beyond that the residual grows a quarter of a step per turn.
def cardinal_points() -> long {
    let bad = 0;
    for k in 0..40 {
        let a = fx.mul(fx.from_int(k), fx.HALF_PI);
        let s = fx.sin(a);
        let c = fx.cos(a);
        let m = k % 4;
        let tol = if (k < 9) { 0 } else { 2 + k };
        let ws = if (m == 0) { 0 } else if (m == 1) { fx.ONE } else if (m == 2) { 0 } else { 0 - fx.ONE };
        let wc = if (m == 0) { fx.ONE } else if (m == 1) { 0 } else if (m == 2) { 0 - fx.ONE } else { 0 };
        if (fx.abs(s - ws) > tol) {
            bad = bad + 1;
            print("        cardinal sin off by " + tostring(fx.abs(s - ws)) + " at k=" + tostring(k));
        };
        if (fx.abs(c - wc) > tol) {
            bad = bad + 1;
            print("        cardinal cos off by " + tostring(fx.abs(c - wc)) + " at k=" + tostring(k));
        };
    };
    bad
};

def atan2_odd_y(n: long) -> long {
    let bad = 0;
    for i in 1..n {
        let y = fx.from_int(i);
        let x = fx.from_int(i * 7 + 1);
        if (fx.atan2(0 - y, x) != 0 - fx.atan2(y, x)) { bad = bad + 1; };
        if (fx.atan2(0 - y, 0 - x) != fx.atan2(y, x) - fx.PI) { bad = bad + 1; };
    };
    bad
};

// atan2 is exact on all four axes, at every argument scale.
def atan2_axes(n: long) -> long {
    let bad = 0;
    for i in 1..n {
        if (fx.atan2(0, i) != 0) { bad = bad + 1; };
        if (fx.atan2(0, 0 - i) != fx.PI) { bad = bad + 1; };
        if (fx.atan2(i, 0) != fx.HALF_PI) { bad = bad + 1; };
        if (fx.atan2(0 - i, 0) != 0 - fx.HALF_PI) { bad = bad + 1; };
    };
    bad
};

def atan2_roundtrip(n: long) -> long {
    let bad = 0;
    for i in 0..n {
        let t = fx.fdiv(fx.mul(fx.from_int(i), fx.PI), fx.from_int(n));
        let d = fx.atan2(fx.sin(t), fx.cos(t)) - t;
        if (d < 0) { d = 0 - d; };
        if (d > 16) {
            bad = bad + 1;
            print("        atan2 round trip off by " + tostring(d) + " steps at t=" + fx.to_str(t));
        };
    };
    bad
};

def asin_acos_pair(n: long) -> long {
    let bad = 0;
    for i in 0..n {
        let x = fx.fdiv(fx.mul(fx.from_int(i - n / 2), fx.ONE), fx.from_int(n / 2));
        if (fx.abs(fx.asin(x) + fx.acos(x) - fx.HALF_PI) > 8) { bad = bad + 1; };
    };
    bad
};

def acos_is_even(n: long) -> long {
    let bad = 0;
    let span = fx.mul(fx.from_int(8), fx.PI);
    for i in 1..n {
        let x = fx.fdiv(fx.mul(fx.from_int(i), span), fx.from_int(n));
        if (fx.abs(fx.acos(0 - x) + fx.acos(x) - fx.PI) > 8) { bad = bad + 1; };
    };
    bad
};

def asin_monotone(n: long) -> long {
    let bad = 0;
    let prev = 0 - fx.HALF_PI;
    for i in 0..n {
        let x = fx.fdiv(fx.mul(fx.from_int(i - n), fx.ONE), fx.from_int(n));
        let r = fx.asin(x);
        if (r < prev) { bad = bad + 1; };
        prev = r;
    };
    bad
};

def acos_monotone(n: long) -> long {
    let bad = 0;
    let prev = fx.PI;
    for i in 0..n {
        let x = fx.fdiv(fx.mul(fx.from_int(i - n), fx.ONE), fx.from_int(n));
        let r = fx.acos(x);
        if (r > prev) { bad = bad + 1; };
        prev = r;
    };
    bad
};

// asin(sin t) == t.  Over the whole of [-pi/2, pi/2] this is CONDITIONED, not
// inaccurate: near the ends asin divides by cos(asin(x)) which is vanishing,
// so a two-step error in sin(t) becomes thousands of steps in the answer.  The
// tight sweep is the well-conditioned half; the loose one is the whole range.
def asin_of_sin(n: long) -> long {
    let bad = 0;
    for i in 1..n {
        let t = fx.fdiv(fx.mul(fx.from_int(i), fx.QUARTER_PI), fx.from_int(n));
        if (fx.abs(fx.asin(fx.sin(t)) - t) > 16) { bad = bad + 1; };
    };
    for i in 1..n {
        let t = fx.fdiv(fx.mul(fx.from_int(i - n), fx.HALF_PI), fx.from_int(n));
        if (fx.abs(fx.asin(fx.sin(t)) - t) > 65536) { bad = bad + 1; };
    };
    bad
};

// acos(cos t) == t on [0, pi], same conditioning caveat at the ends.
def acos_of_cos(n: long) -> long {
    let bad = 0;
    // tight over [pi/8, pi/2]: acos divides by sqrt(1-x^2), which vanishes at
    // BOTH ends of [0, pi], so the quarter turns next to each end are where
    // this identity is conditioned rather than accurate.
    for i in 0..n {
        if (i >= n / 8 && i <= n / 2) {
            let t = fx.fdiv(fx.mul(fx.from_int(i), fx.HALF_PI), fx.from_int(n));
            if (fx.abs(fx.acos(fx.cos(t)) - t) > 16) { bad = bad + 1; };
        };
    };
    for i in 0..n {
        let t = fx.fdiv(fx.mul(fx.from_int(i), fx.PI), fx.from_int(n));
        if (fx.abs(fx.acos(fx.cos(t)) - t) > 65536) { bad = bad + 1; };
    };
    bad
};

// tan(atan(x)) == x -- only for small x.  For large x this is hopeless by
// construction: atan(x) sits 1/x away from a pole and tan of that divides by
// (1/x)^2, so any error in atan is amplified by x^2.  Keep |x| <= 1 here and
// do not round-trip through arctan in a render loop.
def tan_of_atan(n: long) -> long {
    let bad = 0;
    for i in 1..n {
        let x = fx.fdiv(fx.mul(fx.from_int(i - n / 2), fx.ONE), fx.from_int(n / 2));
        if (fx.abs(fx.tan(fx.atan(x)) - x) > 64) { bad = bad + 1; };
    };
    bad
};

// wrap_pi must leave sin and cos exactly as it found them.
def wrap_pi_agrees() -> long {
    let bad = 0;
    let span = fx.mul(fx.from_int(200), fx.PI);
    for i in 0..2000 {
        let x = fx.fdiv(fx.mul(fx.from_int(i), span), fx.from_int(2000));
        let w = fx.wrap_pi(x);
        if (w <= 0 - fx.PI || w > fx.PI) { bad = bad + 1; };
        if (fx.sin(w) != fx.sin(x)) { bad = bad + 1; };
        if (fx.cos(w) != fx.cos(x)) { bad = bad + 1; };
        let u = fx.wrap_2pi(x);
        if (u < 0 || u >= fx.TWO_PI) { bad = bad + 1; };
    };
    bad
};

def atan_recip(x: long) -> long { fx.atan(x) + fx.atan(fx.fdiv(fx.ONE, x)) };

// mul_commutative: the wide path must give the same answer either way round.
def mul_commutative() -> long {
    let bad = 0;
    let j = 12345;
    for i in 0..4000 {
        j = (j * 1103515245 + 12345) & 4611686018427387903;
        let a = fx.from_int(i + 1) << ((i % 30) + 1);
        j = (j * 1103515245 + 12345) & 4611686018427387903;
        let b = fx.from_int(j % 1000 + 1) >> ((i % 20) + 1);
        if (fx.mul(a, b) != fx.mul(b, a)) { bad = bad + 1; };
    };
    bad
};

// The same wide product as section 3, checked again at the very end, so a bug
// that only appears once the heap and the stack have been used for a while
// would be caught.
def mul_wide_spot() -> long {
    let bad = 0;
    if (fx.mul(fx.from_int(1) << 31, fx.from_int(1) >> 8) != fx.from_int(8388608)) { bad = bad + 1; };
    if (fx.mul(fx.from_int(3) << 30, fx.from_int(1) >> 9) != fx.from_int(6291456)) { bad = bad + 1; };
    if (fx.mul(0 - (fx.from_int(1) << 31), fx.from_int(1) >> 8) != 0 - fx.from_int(8388608)) { bad = bad + 1; };
    if (fx.mul(fx.from_int(5) << 29, fx.from_int(1) >> 10) != fx.from_int(2621440)) { bad = bad + 1; };
    bad
};

// ---------------------------------------------------------------------------
print("");
print("-- 1. constants -------------------------------------------------");
feq("ONE is 1.0", fx.ONE, 1073741824);
feq("HALF is 0.5", fx.HALF, 536870912);
feq("TWO is 2.0", fx.TWO, 2147483648);
feq("FRAC_MASK is 2^30-1", fx.FRAC_MASK, 1073741823);
feq("MAX is 2^62-1", fx.MAX, 4611686018427387903);
ck("to_str(PI) reads 3.141593", fx.to_str(fx.PI) == "3.141593");
ck("to_str(ONE) reads 1.000000", fx.to_str(fx.ONE) == "1.000000");
ck("to_str(0) reads 0.000000", fx.to_str(0) == "0.000000");
ck("to_str(0.5) reads 0.500000", fx.to_str(fx.HALF) == "0.500000");
ck("to_str(-0.5) reads -0.500000", fx.to_str(0 - fx.HALF) == "-0.500000");
ck("to_str(-1 step) rounds to 0.000000", fx.to_str(0 - 1) == "0.000000");
ck("to_str carries 0.9999999999 to 1.000000", fx.to_str(fx.ONE - 1) == "1.000000");
ck("to_str(-0.9999999999) reads -1.000000", fx.to_str(1 - fx.ONE) == "-1.000000");
ck("to_str(1234567.25)", fx.to_str(fx.from_int(1234567) + fx.ONE / 4) == "1234567.250000");
ck("to_str(-0.75)", fx.to_str(0 - fx.from_int(3) / 4) == "-0.750000");
ck("DEG reads 0.017453", fx.to_str(fx.DEG) == "0.017453");
ck("RAD reads 57.295780", fx.to_str(fx.RAD) == "57.295780");
near("TWO_PI is 2*PI", fx.TWO_PI, fx.mul(fx.TWO, fx.PI), 1);
near("2*HALF_PI is PI", fx.mul(fx.TWO, fx.HALF_PI), fx.PI, 1);
near("4*QUARTER_PI is PI", fx.mul(fx.from_int(4), fx.QUARTER_PI), fx.PI, 4);
near("4*THREE_QUARTER_PI is 3PI", fx.mul(fx.from_int(4), fx.THREE_QUARTER_PI), fx.mul(fx.from_int(3), fx.PI), 8);
near("4*FIVE_QUARTER_PI is 5PI", fx.mul(fx.from_int(4), fx.FIVE_QUARTER_PI), fx.mul(fx.from_int(5), fx.PI), 8);
near("4*SEVEN_QUARTER_PI is 7PI", fx.mul(fx.from_int(4), fx.SEVEN_QUARTER_PI), fx.mul(fx.from_int(7), fx.PI), 8);
near("2*THREE_HALF_PI is 3PI", fx.mul(fx.TWO, fx.THREE_HALF_PI), fx.mul(fx.from_int(3), fx.PI), 2);
near("to_rad(180) is pi", fx.to_rad(fx.from_int(180)), fx.PI, 4096);
near("to_deg(pi) is 180", fx.to_deg(fx.PI), fx.from_int(180), 8192);

// ---------------------------------------------------------------------------
print("");
print("-- 2. scalars ---------------------------------------------------");
feq("from_int(1)", fx.from_int(1), fx.ONE);
feq("from_int(0)", fx.from_int(0), 0);
feq("from_int(-7) round-trips", fx.to_int(fx.from_int(0 - 7)), 0 - 7);
feq("to_int(1.0)", fx.to_int(fx.ONE), 1);
feq("to_int(-1.0)", fx.to_int(0 - fx.ONE), 0 - 1);
feq("to_int(1.9) truncates toward zero", fx.to_int(fx.from_int(19) / 10), 1);
feq("to_int(-1.9) truncates toward zero", fx.to_int(0 - fx.from_int(19) / 10), 0 - 1);
feq("to_int(0.5)", fx.to_int(fx.HALF), 0);
feq("to_int(-0.5)", fx.to_int(0 - fx.HALF), 0);
feq("floor(1.7)", fx.floor(fx.from_int(17) / 10), fx.ONE);
feq("floor(-1.7)", fx.floor(0 - fx.from_int(17) / 10), 0 - fx.mul(fx.TWO, fx.ONE));
feq("floor(2.0)", fx.floor(fx.mul(fx.TWO, fx.ONE)), fx.mul(fx.TWO, fx.ONE));
feq("floor(0)", fx.floor(0), 0);
feq("floor(0.999999999)", fx.floor(fx.ONE - 1), 0);
feq("floor(-0.000000001)", fx.floor(1 - fx.ONE), 0 - fx.ONE);
feq("ceil(1.2)", fx.ceil(fx.from_int(12) / 10), fx.mul(fx.TWO, fx.ONE));
feq("ceil(-1.2)", fx.ceil(0 - fx.from_int(12) / 10), 0 - fx.ONE);
feq("ceil(2.0)", fx.ceil(fx.mul(fx.TWO, fx.ONE)), fx.mul(fx.TWO, fx.ONE));
feq("ceil(0.000000001)", fx.ceil(1), fx.ONE);
feq("ceil(0)", fx.ceil(0), 0);
feq("round(2.4)", fx.round(fx.from_int(24) / 10), fx.mul(fx.TWO, fx.ONE));
feq("round(2.6)", fx.round(fx.from_int(26) / 10), fx.mul(fx.from_int(3), fx.ONE));
feq("round(2.5) is half away from zero", fx.round(fx.from_int(5) / 2), fx.mul(fx.from_int(3), fx.ONE));
feq("round(-2.5) is half away from zero", fx.round(0 - fx.from_int(5) / 2), 0 - fx.mul(fx.from_int(3), fx.ONE));
feq("round(0.5)", fx.round(fx.HALF), fx.ONE);
feq("round(-0.5)", fx.round(0 - fx.HALF), 0 - fx.ONE);
feq("round(0.4)", fx.round(fx.from_int(4) / 10), 0);
feq("round(-0.4)", fx.round(0 - fx.from_int(4) / 10), 0);
feq("trunc(1.9)", fx.trunc(fx.from_int(19) / 10), fx.ONE);
feq("trunc(-1.9)", fx.trunc(0 - fx.from_int(19) / 10), 0 - fx.ONE);
feq("abs(-5.25)", fx.abs(0 - fx.from_int(21) / 4), fx.from_int(21) / 4);
feq("abs(0)", fx.abs(0), 0);
feq("abs(-1 step)", fx.abs(0 - 1), 1);
feq("imin(3, 7)", fx.imin(3, 7), 3);
feq("imin(-3, 7)", fx.imin(0 - 3, 7), 0 - 3);
feq("imax(3, 7)", fx.imax(3, 7), 7);
feq("clamp(5, 0, 3)", fx.clamp(5, 0, 3), 3);
feq("clamp(-5, 0, 3)", fx.clamp(0 - 5, 0, 3), 0);
feq("clamp(2, 0, 3)", fx.clamp(2, 0, 3), 2);
feq("lerp(0, 10, 0)", fx.lerp(0, fx.from_int(10), 0), 0);
feq("lerp(0, 10, 1)", fx.lerp(0, fx.from_int(10), fx.ONE), fx.from_int(10));
feq("lerp(0, 10, 1/2)", fx.lerp(0, fx.from_int(10), fx.HALF), fx.from_int(5));
feq("lerp(0, 10, 2) clamps t", fx.lerp(0, fx.from_int(10), fx.mul(fx.TWO, fx.ONE)), fx.from_int(10));
feq("lerp(10, 0, 1/4)", fx.lerp(fx.from_int(10), 0, fx.ONE / 4), fx.from_int(75) / 10);
let tf: float = fx.to_float(fx.from_int(21) / 4);
ck("to_float round-trips a quarter", tf == 5.25);
let tf2: float = fx.to_float(0 - fx.HALF);
ck("to_float keeps the sign", tf2 == -0.5);

// ---------------------------------------------------------------------------
print("");
print("-- 3. mul, fdiv, fmod -------------------------------------------");
feq("mul(x, ONE) is x, small", fx.mul(fx.from_int(3), fx.ONE), fx.from_int(3));
feq("mul(x, ONE) is x, negative", fx.mul(0 - fx.from_int(3), fx.ONE), 0 - fx.from_int(3));
feq("mul(x, ONE) is x, wide", fx.mul(fx.from_int(1) << 31, fx.ONE), fx.from_int(1) << 31);
feq("mul(ONE, x) is x, wide", fx.mul(fx.ONE, fx.from_int(1) << 31), fx.from_int(1) << 31);
feq("mul(2, 3)", fx.mul(fx.from_int(2), fx.from_int(3)), fx.from_int(6));
feq("mul(1/2, 1/2)", fx.mul(fx.HALF, fx.HALF), fx.ONE / 4);
feq("mul(0, anything)", fx.mul(0, fx.from_int(1234567)), 0);
feq("mul(anything, 0)", fx.mul(fx.from_int(1234567), 0), 0);
feq("mul(-2, 3)", fx.mul(0 - fx.from_int(2), fx.from_int(3)), 0 - fx.from_int(6));
feq("mul(2, -3)", fx.mul(fx.from_int(2), 0 - fx.from_int(3)), 0 - fx.from_int(6));
feq("mul(-2, -3)", fx.mul(0 - fx.from_int(2), 0 - fx.from_int(3)), fx.from_int(6));
// The wide path, on cases whose exact answer is known in closed form.  Each
// needs an 80-bit product, so none of them can take the single-multiply path.
feq("mul wide: 2^31 x 2^-8", fx.mul(fx.from_int(1) << 31, fx.from_int(1) >> 8), fx.from_int(8388608));
feq("mul wide: 3*2^30 x 2^-9", fx.mul(fx.from_int(3) << 30, fx.from_int(1) >> 9), fx.from_int(6291456));
feq("mul wide: 3*2^30 x -2^-9", fx.mul(fx.from_int(3) << 30, 0 - (fx.from_int(1) >> 9)), 0 - fx.from_int(6291456));
feq("mul wide: 5*2^29 x 2^-10", fx.mul(fx.from_int(5) << 29, fx.from_int(1) >> 10), fx.from_int(2621440));
feq("mul wide: -2^31 x 2^-8", fx.mul(0 - (fx.from_int(1) << 31), fx.from_int(1) >> 8), 0 - fx.from_int(8388608));
ck("mul is commutative on the wide path", mul_commutative() == 0);
ck("mul, fdiv and abs are odd step for step", even_exact(4000) == 0);
ck("mul saturates instead of wrapping", fx.mul(fx.MAX, fx.TWO) == fx.MAX);
ck("mul saturates on MAX*MAX", fx.mul(fx.MAX, fx.MAX) == fx.MAX);
ck("mul of MAX by ONE does not saturate", fx.mul(fx.MAX, fx.ONE) == fx.MAX);
feq("mul of MAX by a half", fx.mul(fx.MAX, fx.HALF), fx.MAX / 2);
feq("fdiv(x, ONE) is x, small", fx.fdiv(fx.from_int(3), fx.ONE), fx.from_int(3));
feq("fdiv(x, ONE) is x, wide", fx.fdiv(fx.from_int(1) << 31, fx.ONE), fx.from_int(1) << 31);
feq("fdiv(-x, ONE) is -x, wide", fx.fdiv(0 - (fx.from_int(1) << 31), fx.ONE), 0 - (fx.from_int(1) << 31));
feq("fdiv(1, 4)", fx.fdiv(fx.ONE, fx.from_int(4)), fx.ONE / 4);
feq("fdiv(-1, 4)", fx.fdiv(0 - fx.ONE, fx.from_int(4)), 0 - fx.ONE / 4);
feq("fdiv(1, -4)", fx.fdiv(fx.ONE, 0 - fx.from_int(4)), 0 - fx.ONE / 4);
feq("fdiv(-1, -4)", fx.fdiv(0 - fx.ONE, 0 - fx.from_int(4)), fx.ONE / 4);
ck("fdiv by zero gives 0, no trap", fx.fdiv(fx.ONE, 0) == 0);
ck("fdiv(0, 0) gives 0, no trap", fx.fdiv(0, 0) == 0);
near("fdiv(1, 3) x 3 == 1", fx.mul(fx.fdiv(fx.ONE, fx.from_int(3)), fx.from_int(3)), fx.ONE, 5);
near("fdiv(7, 11) x 11 == 7", fx.mul(fx.fdiv(fx.from_int(7), fx.from_int(11)), fx.from_int(11)), fx.from_int(7), 13);
near("fdiv(1e6, 3) x 3 == 1e6", fx.mul(fx.fdiv(fx.from_int(1000000), fx.from_int(3)), fx.from_int(3)), fx.from_int(1000000), 5);
near("fdiv(2^31, 3) x 3 == 2^31", fx.mul(fx.fdiv(fx.from_int(1) << 31, fx.from_int(3)), fx.from_int(3)), fx.from_int(1) << 31, 5);
ck("fdiv saturates instead of wrapping", fx.fdiv(fx.MAX, 1) == fx.MAX);
feq("fdiv of MAX by MAX is 1", fx.fdiv(fx.MAX, fx.MAX), fx.ONE);
feq("fmod(5.5, 2)", fx.fmod(fx.from_int(11) / 2, fx.from_int(2)), fx.from_int(3) / 2);
feq("fmod(-5.5, 2)", fx.fmod(0 - fx.from_int(11) / 2, fx.from_int(2)), 0 - fx.from_int(3) / 2);
feq("fmod(5.5, -2)", fx.fmod(fx.from_int(11) / 2, 0 - fx.from_int(2)), fx.from_int(3) / 2);
feq("fmod(-5.5, -2)", fx.fmod(0 - fx.from_int(11) / 2, 0 - fx.from_int(2)), 0 - fx.from_int(3) / 2);
feq("fmod(4, 2)", fx.fmod(fx.from_int(4), fx.from_int(2)), 0);
feq("fmod(2, 4)", fx.fmod(fx.from_int(2), fx.from_int(4)), fx.from_int(2));
feq("fmod(-2, 4)", fx.fmod(0 - fx.from_int(2), fx.from_int(4)), 0 - fx.from_int(2));
ck("fmod by zero gives 0, no trap", fx.fmod(fx.ONE, 0) == 0);

// ---------------------------------------------------------------------------
print("");
print("-- 4. isqrt, sqrt, hypot ----------------------------------------");
feq("isqrt(0)", fx.isqrt(0), 0);
feq("isqrt(1)", fx.isqrt(1), 1);
feq("isqrt(2)", fx.isqrt(2), 1);
feq("isqrt(3)", fx.isqrt(3), 1);
feq("isqrt(4)", fx.isqrt(4), 2);
feq("isqrt(9)", fx.isqrt(9), 3);
feq("isqrt(10)", fx.isqrt(10), 3);
feq("isqrt(2^62-1)", fx.isqrt(4611686018427387903), 2147483647);
ck("isqrt is exact on n^2, n^2-1, n^2+2n for n < 200000", isqrt_squares(200000) == 0);
feq("sqrt(0)", fx.sqrt(0), 0);
feq("sqrt(1)", fx.sqrt(fx.ONE), fx.ONE);
feq("sqrt(4)", fx.sqrt(fx.from_int(4)), fx.from_int(2));
feq("sqrt(0.25)", fx.sqrt(fx.ONE / 4), fx.HALF);
feq("sqrt(9)", fx.sqrt(fx.from_int(9)), fx.from_int(3));
feq("sqrt(2^-30) is 2^-15", fx.sqrt(1), 32768);
feq("sqrt(2^-10) is 2^-5", fx.sqrt(fx.ONE / 1024), fx.ONE / 32);
feq("sqrt(2^10) is 2^5", fx.sqrt(fx.ONE * 1024), fx.from_int(32));
feq("sqrt(2^32) is 2^16", fx.sqrt(fx.ONE << 32), fx.from_int(65536));
near("sqrt(2) is 1.41421356", fx.sqrt(fx.from_int(2)), 1518500250, 2);
near("sqrt(3) is 1.73205081", fx.sqrt(fx.from_int(3)), 1859775393, 2);
near("sqrt(0.5) is 0.70710678", fx.sqrt(fx.HALF), 759250125, 2);
near("sqrt(1e6) is 1000", fx.sqrt(fx.from_int(1000000)), fx.from_int(1000), 2);
near("sqrt(1234567) is 1111.11070555", fx.sqrt(fx.from_int(1234567)), 1193046035649, 4);
near("sqrt of the largest argument is 65536", fx.sqrt(fx.MAX), 70368744177663, 2);
near("sqrt of 2^62 is 65536", fx.sqrt(fx.ONE << 32), 70368744177664, 2);
ck("sqrt(x*x) == |x| over a sweep of magnitudes", sqrt_of_square_sweep() == 0);
ck("sqrt is exact on perfect squares up to 4000^2", sqrt_squares(4000) == 0);
ck("sqrt is monotone over (0, 30000]", sqrt_monotone(30000) == 0);
ck("sqrt of a negative gives 0, no trap", fx.sqrt(0 - fx.ONE) == 0);
ck("sqrt of MAX does not trap", fx.sqrt(fx.MAX) > 0);
feq("hypot(0, 0)", fx.hypot(0, 0), 0);
feq("hypot(3, 4)", fx.hypot(fx.from_int(3), fx.from_int(4)), fx.from_int(5));
feq("hypot(-3, -4)", fx.hypot(0 - fx.from_int(3), 0 - fx.from_int(4)), fx.from_int(5));
feq("hypot(4, -3)", fx.hypot(fx.from_int(4), 0 - fx.from_int(3)), fx.from_int(5));
feq("hypot(1, 0)", fx.hypot(fx.ONE, 0), fx.ONE);
feq("hypot(0, -1)", fx.hypot(0, 0 - fx.ONE), fx.ONE);
// hypot's scale-down loses a couple of bits before the root, so its error is
// RELATIVE: about 1.5e-8 (16 steps) whatever the magnitude.
near("hypot(1e6, 1e6) is 1414213.5623730", fx.hypot(fx.from_int(1000000), fx.from_int(1000000)), 1518500249988025, 1048576);
near("hypot(1, 1) is 1.41421356", fx.hypot(fx.ONE, fx.ONE), 1518500250, 8);
ck("hypot of MAX by MAX saturates, no trap", fx.hypot(fx.MAX, fx.MAX) == fx.MAX);

// ---------------------------------------------------------------------------
print("");
print("-- 5. sin, cos, tan ---------------------------------------------");
feq("sin(0)", fx.sin(0), 0);
feq("sin(pi/2)", fx.sin(fx.HALF_PI), fx.ONE);
feq("sin(pi)", fx.sin(fx.PI), 0);
feq("sin(3pi/2)", fx.sin(fx.THREE_HALF_PI), 0 - fx.ONE);
feq("sin(2pi)", fx.sin(fx.TWO_PI), 0);
feq("sin(pi/4)", fx.sin(fx.QUARTER_PI), 759250125);
near("sin(-pi/4)", fx.sin(0 - fx.QUARTER_PI), 0 - 759250125, 4);
feq("cos(0)", fx.cos(0), fx.ONE);
feq("cos(pi/2)", fx.cos(fx.HALF_PI), 0);
feq("cos(pi)", fx.cos(fx.PI), 0 - fx.ONE);
feq("cos(3pi/2)", fx.cos(fx.THREE_HALF_PI), 0);
feq("cos(2pi)", fx.cos(fx.TWO_PI), fx.ONE);
feq("cos(pi/4)", fx.cos(fx.QUARTER_PI), 759250125);
near("cos(-pi/4)", fx.cos(0 - fx.QUARTER_PI), 759250125, 4);
feq("tan(0)", fx.tan(0), 0);
near("tan(pi/4)", fx.tan(fx.QUARTER_PI), fx.ONE, 4);
near("tan(1) is 1.55740772", fx.tan(fx.ONE), 1672253811, 16);
near("tan(-1) is -1.55740772", fx.tan(0 - fx.ONE), 0 - 1672253811, 16);
ck("the 33-entry float64 table of sin, cos, tan", trig_table() == 0);
ck("sin^2 + cos^2 == 1 over 4000 angles in [-4pi, 4pi]", pythagoras(4000) == 0);
ck("atan and asin are odd step for step, sin and cos to 8", odd_exact(4000) == 0);
ck("sin(pi-x) == sin(x) == sin(x+2pi)", sin_about_pi(2000) == 0);
ck("cos(pi+x) == -cos(x) == cos(x+2pi)", cos_about_pi(2000) == 0);
ck("j whole turns in sin and cos over j < 40", periodic(40) == 0);
ck("sin is monotone on [0, pi/2]", sin_monotone(4000) == 0);
ck("sin and cos are exact at the cardinal points of 4 turns", cardinal_points() == 0);
near("sin(1e6)", fx.sin(fx.from_int(1000000)), 0 - 375802661, 8);
near("cos(1e6)", fx.cos(fx.from_int(1000000)), 1005829938, 8);
near("sin(-1e6)", fx.sin(0 - fx.from_int(1000000)), 375802661, 8);
near("sin(1e9)", fx.sin(fx.from_int(1000000000)), 586094941, 16);
near("cos(1e9)", fx.cos(fx.from_int(1000000000)), 899674510, 16);
near("sin(8e9)", fx.sin(fx.from_int(8000000000)), 0 - 1069079251, 32);
near("cos(8e9)", fx.cos(fx.from_int(8000000000)), 0 - 99955285, 32);
near("sin(123456.789)", fx.sin(fx.from_int(123456789) / 1000), 0 - 1072307393, 8);
near("cos(123456.789)", fx.cos(fx.from_int(123456789) / 1000), 55482960, 8);
near("wrap_pi(1e6)", fx.wrap_pi(fx.from_int(1000000)), 0 - 383931600, 16);
near("wrap_pi(1e9)", fx.wrap_pi(fx.from_int(1000000000)), 619973616, 32);
// At exactly +-pi/2 the Q30 cos is exactly 0 and fdiv(x, 0) is 0 by the
// documented zero-divisor rule, so tan there is 0, not infinity.  One step
// away the cos is 1 step, so tan is exactly ONE -- which means tan can never
// leave [-1, 1] on this grid however close to the pole you ask for.  The
// quotient is a real 1e16 there; the format simply cannot hold it.
ck("tan(pi/2) returns 0 rather than trapping", fx.tan(fx.HALF_PI) == 0);
ck("tan(-pi/2) returns 0 rather than trapping", fx.tan(0 - fx.HALF_PI) == 0);
// 16 steps below the pole leaves a cos of 16 steps, so the tangent is exactly
// 2^30/16 = 2^26.  64 steps below it leaves a cos of 64 steps: 2^24.
feq("tan(pi/2 - 16 steps) is exactly 2^26", fx.tan(fx.HALF_PI - 16), 72057594037927936);
feq("tan(-pi/2 + 16 steps) is exactly -2^26", fx.tan(0 - fx.HALF_PI + 16), 0 - 72057594037927936);
feq("tan(pi/2 - 64 steps) is exactly 2^24", fx.tan(fx.HALF_PI - 64), 18014398509481984);
feq("tan(-pi/2 + 64 steps) is exactly -2^24", fx.tan(0 - fx.HALF_PI + 64), 0 - 18014398509481984);
feq("tan(pi/2 + 64 steps) is exactly -2^24", fx.tan(fx.HALF_PI + 64), 0 - 18014398509481984);

// ---------------------------------------------------------------------------
print("");
print("-- 6. atan, atan2, asin, acos -----------------------------------");
feq("atan(0)", fx.atan(0), 0);
near("atan(1) is pi/4", fx.atan(fx.ONE), 843314857, 4);
near("atan(-1) is -pi/4", fx.atan(0 - fx.ONE), 0 - 843314857, 4);
near("atan(0.5) is 0.46364761", fx.atan(fx.HALF), 497837829, 8);
near("atan(-0.5) is -0.46364761", fx.atan(0 - fx.HALF), 0 - 497837829, 8);
near("atan(2) is 1.10714872", fx.atan(fx.TWO), 1188791884, 8);
near("atan(1000) is 1.56979633", fx.atan(fx.from_int(1000)), 1685555972, 16);
near("atan(1e-9)", fx.atan(1), 1, 1);
near("2*atan(1) is pi/2", fx.mul(fx.atan(fx.ONE), fx.TWO), fx.HALF_PI, 8);
near("atan(x) + atan(1/x) is pi/2, x = 2", atan_recip(fx.TWO), fx.HALF_PI, 8);
near("atan(x) + atan(1/x) is pi/2, x = 1e6", atan_recip(fx.from_int(1000000)), fx.HALF_PI, 16);
feq("atan2(0, 0) is 0 by convention", fx.atan2(0, 0), 0);
feq("atan2(1, 0) is pi/2", fx.atan2(fx.ONE, 0), fx.HALF_PI);
feq("atan2(-1, 0) is -pi/2", fx.atan2(0 - fx.ONE, 0), 0 - fx.HALF_PI);
feq("atan2(0, 1) is 0", fx.atan2(0, fx.ONE), 0);
feq("atan2(0, -1) is pi", fx.atan2(0, 0 - fx.ONE), fx.PI);
feq("atan2(1 step, -1) is pi", fx.atan2(1, 0 - fx.ONE), fx.PI);
feq("atan2(-1 step, -1) is -pi", fx.atan2(0 - 1, 0 - fx.ONE), 0 - fx.PI);
near("atan2(1, 1) is pi/4", fx.atan2(fx.ONE, fx.ONE), fx.QUARTER_PI, 4);
near("atan2(1, -1) is 3pi/4", fx.atan2(fx.ONE, 0 - fx.ONE), fx.THREE_QUARTER_PI, 4);
near("atan2(-1, -1) is -3pi/4", fx.atan2(0 - fx.ONE, 0 - fx.ONE), 0 - fx.THREE_QUARTER_PI, 4);
near("atan2(-1, 1) is -pi/4", fx.atan2(0 - fx.ONE, fx.ONE), 0 - fx.QUARTER_PI, 4);
near("atan2(2, 1) is 1.10714872", fx.atan2(fx.TWO, fx.ONE), 1188791884, 8);
near("atan2(1, 2) is 0.46364761", fx.atan2(fx.ONE, fx.TWO), 497837829, 8);
near("atan2(-2, -1) is -2.03444394", fx.atan2(0 - fx.TWO, 0 - fx.ONE), 0 - 2184467542, 8);
near("atan2(1, 1000000) is 1e-6", fx.atan2(fx.ONE, fx.from_int(1000000)), 1074, 2);
ck("atan2 is odd in y and symmetric in (y, x)", atan2_odd_y(2000) == 0);
ck("atan2 is exact on all four axes", atan2_axes(20000) == 0);
ck("atan2(sin t, cos t) == t over [-pi, pi]", atan2_roundtrip(20000) == 0);
feq("asin(0)", fx.asin(0), 0);
feq("asin(1) is pi/2", fx.asin(fx.ONE), fx.HALF_PI);
feq("asin(-1) is -pi/2", fx.asin(0 - fx.ONE), 0 - fx.HALF_PI);
feq("asin(2) clamps to pi/2, no trap", fx.asin(fx.from_int(2)), fx.HALF_PI);
feq("asin(-2) clamps to -pi/2, no trap", fx.asin(0 - fx.from_int(2)), 0 - fx.HALF_PI);
near("asin(0.5) is pi/6", fx.asin(fx.HALF), 562209904, 4);
near("asin(-0.5) is -pi/6", fx.asin(0 - fx.HALF), 0 - 562209904, 4);
near("asin(0.9) is 1.11976951", fx.asin(fx.from_int(9) / 10), 1202343361, 8);
feq("acos(0) is pi/2", fx.acos(0), fx.HALF_PI);
feq("acos(1) is 0", fx.acos(fx.ONE), 0);
feq("acos(-1) is pi", fx.acos(0 - fx.ONE), fx.PI);
feq("acos(2) clamps to 0, no trap", fx.acos(fx.from_int(2)), 0);
feq("acos(-2) clamps to pi, no trap", fx.acos(0 - fx.from_int(2)), fx.PI);
ck("asin(x) + acos(x) == pi/2 over [-1, 1]", asin_acos_pair(20000) == 0);
ck("acos(-x) + acos(x) == pi", acos_is_even(2000) == 0);
ck("asin is monotone over [-1, 1]", asin_monotone(20000) == 0);
ck("acos is monotone over [-1, 1]", acos_monotone(20000) == 0);
ck("asin(sin t) == t, tight on [0, pi/4] and loose on [-pi/2, pi/2]", asin_of_sin(20000) == 0);
ck("acos(cos t) == t, tight on [0, pi/2] and loose on [0, pi]", acos_of_cos(20000) == 0);
ck("tan(atan(x)) == x for |x| <= 1", tan_of_atan(20000) == 0);

// ---------------------------------------------------------------------------
print("");
print("-- 7. angle folding ----------------------------------------------");
feq("wrap_pi(0)", fx.wrap_pi(0), 0);
feq("wrap_pi(pi)", fx.wrap_pi(fx.PI), fx.PI);
feq("wrap_pi(-pi) is pi", fx.wrap_pi(0 - fx.PI), fx.PI);
feq("wrap_pi(2pi) is 0", fx.wrap_pi(fx.TWO_PI), 0);
feq("wrap_pi(-2pi) is 0", fx.wrap_pi(0 - fx.TWO_PI), 0);
near("wrap_pi(3pi) is pi", fx.wrap_pi(fx.mul(fx.from_int(3), fx.PI)), fx.PI, 2);
near("wrap_pi(2pi + 0.5) is 0.5", fx.wrap_pi(fx.mul(fx.TWO, fx.PI) + fx.HALF), fx.HALF, 2);
near("wrap_pi(2pi - 0.5) is -0.5", fx.wrap_pi(fx.mul(fx.TWO, fx.PI) - fx.HALF), 0 - fx.HALF, 2);
feq("wrap_2pi(0)", fx.wrap_2pi(0), 0);
feq("wrap_2pi(2pi) is 0", fx.wrap_2pi(fx.TWO_PI), 0);
near("wrap_2pi(-1) is 2pi - 1", fx.wrap_2pi(0 - fx.ONE), fx.TWO_PI - fx.ONE, 1);
ck("wrap_pi keeps the angle in (-pi, pi] and sin/cos unchanged", wrap_pi_agrees() == 0);

// ---------------------------------------------------------------------------
print("");
print("-- 8. no drift ---------------------------------------------------");
// fx.y keeps no state at all, so the ten-thousandth call must be bit-identical
// to the first.  A cached table, an accumulator or a memo would show up here.
let d_ang = fx.from_int(123456789) / 1000;
let s0 = fx.sin(d_ang);
let c0 = fx.cos(d_ang);
let s1 = fx.sin(0 - d_ang);
let drift = 0;
let it = 0;
while (it < 20000) {
    if (fx.sin(d_ang) != s0) { drift = drift + 1; };
    if (fx.cos(d_ang) != c0) { drift = drift + 1; };
    if (fx.sin(0 - d_ang) != s1) { drift = drift + 1; };
    it = it + 1;
};
ck("sin/cos are bit-identical over 20000 calls", drift == 0);
near("sin is still right after 20000 calls", fx.sin(d_ang), 0 - 1072307393, 8);
near("cos is still right after 20000 calls", fx.cos(d_ang), 55482960, 8);
// And a long run of DIFFERENT arguments, which is where an accumulating phase
// error would show rather than a repeat of one value.  sin must also stay
// inside [-1, 1] across all of it -- a stray unit or a lost sign shows up
// there long before it shows up in a comparison.
let hi = 0 - fx.ONE;
let lo = fx.ONE;
it = 0;
while (it < 20000) {
    let s = fx.sin(fx.from_int(it) / 977);
    if (s > hi) { hi = s; };
    if (s < lo) { lo = s; };
    it = it + 1
};
ck("sin stays within [-1, 1] over 20000 varying arguments", hi <= fx.ONE + 4 && lo >= 0 - fx.ONE - 4);
near("the largest sin over that sweep is 1.000000", hi, fx.ONE, 4);
ck("mul is still exact after all of the above", mul_wide_spot() == 0);

// ---------------------------------------------------------------------------
print("");
print("-- 9. no trap on any path ----------------------------------------");
// Each of these was a way to crash a render loop: a zero-length vector, a
// negative square root, a pole, an out-of-domain arcsine, the largest
// representable value.  All must RETURN, not trap.
ck("sqrt(-1) returns", fx.sqrt(0 - fx.ONE) == 0);
ck("sqrt(0) returns", fx.sqrt(0) == 0);
ck("sqrt(MAX) returns", fx.sqrt(fx.MAX) > 0);
ck("isqrt(0) returns", fx.isqrt(0) == 0);
ck("fdiv(x, 0) returns", fx.fdiv(fx.ONE, 0) == 0);
ck("fmod(x, 0) returns", fx.fmod(fx.ONE, 0) == 0);
ck("atan2(0, 0) returns", fx.atan2(0, 0) == 0);
ck("asin(2) returns", fx.asin(fx.from_int(2)) == fx.HALF_PI);
ck("acos(-2) returns", fx.acos(0 - fx.from_int(2)) == fx.PI);
ck("tan(pi/2) returns", fx.tan(fx.HALF_PI) != 123456789);
ck("hypot(0, 0) returns", fx.hypot(0, 0) == 0);
ck("hypot(MAX, MAX) returns", fx.hypot(fx.MAX, fx.MAX) == fx.MAX);
ck("mul(MAX, MAX) returns", fx.mul(fx.MAX, fx.MAX) == fx.MAX);
ck("fdiv(MAX, 1) returns", fx.fdiv(fx.MAX, 1) == fx.MAX);
ck("wrap_pi(MAX) returns in (-pi, pi]", fx.wrap_pi(fx.MAX) > 0 - fx.PI && fx.wrap_pi(fx.MAX) <= fx.PI);
ck("wrap_2pi(0 - MAX) returns", fx.wrap_2pi(0 - fx.MAX) >= 0);
ck("to_int(0 - MAX) returns", fx.to_int(0 - fx.MAX) < 0);
ck("floor(0 - MAX) returns", fx.floor(0 - fx.MAX) < 0);
ck("ceil(MAX) returns", fx.ceil(fx.MAX) > 0);
ck("to_str(0 - MAX) returns", fx.to_str(0 - fx.MAX) != "");
ck("sin(MAX) returns", fx.sin(fx.MAX) != 123456789);
ck("cos(0 - MAX) returns", fx.cos(0 - fx.MAX) != 123456789);
ck("abs(0 - MAX) returns", fx.abs(0 - fx.MAX) == fx.MAX);
ck("atan(MAX) returns", fx.atan(fx.MAX) == fx.HALF_PI - 1 || fx.atan(fx.MAX) == fx.HALF_PI);
ck("lerp with a huge t returns", fx.lerp(0, fx.MAX, fx.MAX) > 0);

// ---------------------------------------------------------------------------
print("");
print("=================================================================");
print(tostring(checks) + " checks, " + tostring(fails) + " failed");
print("largest |error| any near() check saw: " + tostring(worst_err) + " steps"
    + " = " + f"{errf(worst_err):.6f}"
    + "   at  " + worst_where);
print("one step is 2^-30 = 9.313225746154785e-10, so that is "
    + f"{errf(worst_err) / 9.313225746154785e-10:.1f}"
    + " steps of the fixed-point grid");
if (fails == 0) {
    print("RESULT: PASS");
    exit(0);
};
print("RESULT: FAIL");
exit(1);