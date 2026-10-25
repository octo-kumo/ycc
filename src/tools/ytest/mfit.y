// mfit.y -- polynomial kernels for std/math.y, in the form the module
// evaluates them (`ytest math-fit`).
//
// A polynomial evaluated in plain double arithmetic is not accurate to an ulp:
// Horner's rule accumulates a rounding a term. The fix the good libraries use
// is to split every coefficient in two and carry the low parts in a second
// accumulator (poly_split):
//
//     p = c_n_hi;  q = c_n_lo
//     for i in n-1 .. 0:  p = p * w + c_i_hi;  q = q * w + c_i_lo
//     answer = p + q
//
// and every kernel is the CORRECTION to a term already in hand:
//
//     2^r   = 1 + r * (1 + r * P(r))             exp
//     log m = z * (2 + w * P(w)), w = z^2        log, z = (m-1)/(m+1)
//     sin x = x * (1 + w * P(w)), w = x^2        sin, atan, tanh, sinh
//     cos x = 1 - w * P(w)                       cos
//     asin  = pi/2 - 2 sqrt(z) (1 + z P(z))      asin's upper half
//
// This fits each P at Chebyshev nodes (equally spaced nodes would interpolate
// a nearly constant kernel with enormous coefficients) by solving the
// Vandermonde system in binary floating point of 512 bits (bigf.y), where the
// Python version solved it in exact rationals: the system's conditioning costs
// about 2^n, far inside the margin. Each kernel's exact function is its own
// series, so nothing cancels. asin's coefficients need no fit: they are the
// series' own, C(2k,k)/(4^k (2k+1)).
//
//   ytest math-fit          check that math.y's eight tables are the fit, hi and lo
//   ytest math-fit report   the coefficients as Y literals, each kernel's worst
//                           error in ulps of the FINAL ANSWER over 4001 points
import math;
import yt;
import mgen;
import mstatic;
import bigf;
import mref;

let WORK = 512;

type Kernel = { name: str, hi_tab: str, lo_tab: str, deg: long, kind: str };

def bfl(v: long) -> bigf.BF { bigf.from_long(v) };

def frac(a: long, b: long) -> bigf.BF { bigf.div(bfl(a), bfl(b)) };

def tiny(t: bigf.BF, total: bigf.BF) -> bool { bigf.is_zero(t) || bigf.top(t) < bigf.top(total) - bigf.PREC - 8 };

// sum over k >= 0 of c_k w^k, c_k = num(k)/den(k) with alternating signs if asked
def series(w: bigf.BF, first: bigf.BF, kind: str) -> bigf.BF {
    let total = first;
    let p = bfl(1);
    let k = 1;
    let go = true;
    while (go) {
        p = bigf.mul(p, w);
        let t = coef_term(kind, k, p);
        if (tiny(t, total) || k > 400) { go = false; } else { total = bigf.add(total, t); k += 1; };
    };
    total
};

// k! as a BF (k < 200)
def fact(k: long) -> bigf.BF {
    let f = bfl(1);
    for i in 2..k + 1 { f = bigf.mul(f, bfl(i)); };
    f
};

// the k-th term of each kernel's series, given w^k
def coef_term(kind: str, k: long, wk: bigf.BF) -> bigf.BF {
    if (kind == "exp") { return bigf.div(wk, fact(k + 2)); };
    if (kind == "log") { return bigf.div_small(bigf.ldexp(wk, 1), 2 * k + 3); };
    if (kind == "sin") { let t = bigf.div(wk, fact(2 * k + 3)); return if (k % 2 == 0) { bigf.neg(t) } else { t }; };
    if (kind == "cos") { let t = bigf.div(wk, fact(2 * k + 2)); return if (k % 2 == 0) { t } else { bigf.neg(t) }; };
    if (kind == "sinh") { return bigf.div(wk, fact(2 * k + 3)); };
    if (kind == "atan") { let t = bigf.div_small(wk, 2 * k + 3); return if (k % 2 == 0) { bigf.neg(t) } else { t }; };
    // asin: C(2(k+1), k+1) / (4^(k+1) (2k+3))
    bigf.mul(asin_coef(k), wk)
};

def binom(n: long, k: long) -> bigf.BF {
    let r = bfl(1);
    for i in 0..k { r = bigf.div_small(bigf.mul(r, bfl(n - i)), i + 1); };
    r
};

def asin_coef(i: long) -> bigf.BF {
    let k = i + 1;
    bigf.div_small(bigf.ldexp(binom(2 * k, k), 0 - 2 * k), 2 * k + 1)
};

/** The kernel's exact value at w. */
def exact(kind: str, w: bigf.BF) -> bigf.BF {
    if (kind == "exp") { return series(w, frac(1, 2), kind); };
    if (kind == "log") { return series(w, frac(2, 3), kind); };
    if (kind == "sin") { return series(w, bigf.neg(frac(1, 6)), kind); };
    if (kind == "cos") { return series(w, frac(1, 2), kind); };
    if (kind == "sinh") { return series(w, frac(1, 6), kind); };
    if (kind == "atan") { return series(w, bigf.neg(frac(1, 3)), kind); };
    if (kind == "asin") { return series(w, asin_coef(0), kind); };
    // tanh: (tanh r - r) / (r w), r = sqrt(w), tanh r = em / (em + 2), em = e^(2r) - 1
    if (bigf.is_zero(w)) { return bigf.neg(frac(1, 3)); };
    let r = bigf.sqrt(w);
    let em = mref.bexpm1_small(bigf.ldexp(r, 1));
    let th = bigf.div(em, bigf.add(em, bfl(2)));
    bigf.div(bigf.sub(th, r), bigf.mul(r, w))
};

/** The fit's range: P is fitted on [0, range]. */
def range_of(kind: str) -> bigf.BF {
    if (kind == "exp") { return bigf.div_small(dec_bf("0.693147180369123816490"), 2); };
    let s2 = bigf.sqrt(bfl(2));
    if (kind == "log") {
        let z = bigf.div(bigf.sub(s2, bfl(1)), bigf.add(s2, bfl(1)));
        return bigf.mul(z, z);
    };
    if (kind == "sin" || kind == "cos") {
        let q = bigf.ldexp(bigf.pi(), -2);
        return bigf.mul(q, q);
    };
    if (kind == "atan") {
        let t = bigf.sub(s2, bfl(1));
        return bigf.mul(t, t);
    };
    // tanh, sinh: |x| <= 1/2; asin: z in (0, 1/4]
    frac(1, 4)
};

// a decimal literal as a BF, at the working precision
def dec_bf(s: str) -> bigf.BF {
    let i = s.index_of(".");
    let digits = s[:i] + s[i + 1:];
    let m = bfl(0);
    for j in 0..digits.length { m = bigf.add(bigf.mul(m, bfl(10)), bfl(digits.byte_at(j) - 48)); };
    for j in 0..(s.length - i - 1) { m = bigf.div_small(m, 10); };
    m
};

// cos(x) by its series, |x| <= pi
def bcos(x: bigf.BF) -> bigf.BF {
    let x2 = bigf.mul(x, x);
    let t = bfl(1);
    let total = t;
    let k = 1;
    let go = true;
    while (go) {
        t = bigf.neg(bigf.div_small(bigf.mul(t, x2), (2 * k - 1) * (2 * k)));
        if (tiny(t, total)) { go = false; } else { total = bigf.add(total, t); k += 1; };
    };
    total
};

/** Coefficients of P, ascending, fitted at n Chebyshev nodes on [0, h]. */
def fit(kind: str, deg: long) -> [bigf.BF] {
    let n = deg + 1;
    let h = range_of(kind);
    if (kind == "asin") {
        let cs: [bigf.BF] = [];
        for i in 0..n { cs += asin_coef(i); };
        return cs;
    };
    let rows: [[bigf.BF]] = [];
    for i in 0..n {
        let t = bcos(bigf.div_small(bigf.mul(bfl(2 * i + 1), bigf.pi()), 2 * n));
        let x = bigf.ldexp(bigf.mul(h, bigf.sub(bfl(1), t)), -1);
        let row: [bigf.BF] = [];
        let p = bfl(1);
        for j in 0..n {
            row += p;
            p = bigf.mul(p, x);
        };
        row += exact(kind, x);
        rows += row;
    };
    // Gauss-Jordan, the first non-zero pivot (as the rational version did)
    for col in 0..n {
        let piv = col;
        while (bigf.is_zero(rows[piv][col])) { piv += 1; };
        let tmp = rows[col];
        rows[col] = rows[piv];
        rows[piv] = tmp;
        let pv = bigf.recip(rows[col][col]);
        let rc: [bigf.BF] = [];
        foreach (v in rows[col]) { rc += bigf.mul(v, pv); };
        rows[col] = rc;
        for r in 0..n {
            if (r != col && !bigf.is_zero(rows[r][col])) {
                let f = rows[r][col];
                let nr: [bigf.BF] = [];
                for c in 0..n + 1 { nr += bigf.sub(rows[r][c], bigf.mul(f, rc[c])); };
                rows[r] = nr;
            };
        };
    };
    let out: [bigf.BF] = [];
    for i in 0..n { out += rows[i][n]; };
    out
};

/** A coefficient as its two doubles: hi rounds it, lo the rest. */
def split(c: bigf.BF) -> [float] {
    let hi = bigf.to_double(c);
    [hi, bigf.to_double(bigf.sub(c, bigf.from_double(hi)))]
};

// ── the shortest repr, as Python writes a float ──────────────────────────

// x's decimal digits rounded to p significant digits, and the exponent of the first
def digits(x: float, p: long) -> [str] {
    let a = bigf.abs(bigf.from_double(x));
    let e = math.to_int(math.floor(math.log10(math.fabs(x))));
    let out: [str] = [];
    let tries = 0;
    while (out.length == 0 && tries < 3) {
        let sh = p - 1 - e;
        let v = a;
        if (sh > 0) { for i in 0..sh { v = bigf.mul(v, bfl(10)); }; } else { for i in 0..(0 - sh) { v = bigf.div_small(v, 10); }; };
        let s = bigf.decimal(bigf.round_int(v));
        if (s.length > p) { e += 1; } else if (s.length < p) { e -= 1; } else { out = [s, tostring(e)]; };
        tries += 1;
    };
    out
};

def repr(x: float) -> str {
    if (x == 0.0) { return if (mref.is_neg(x)) { "-0.0" } else { "0.0" }; };
    let sign = if (x < 0.0) { "-" } else { "" };
    let saved = bigf.PREC;
    bigf.set_prec(2400);
    let d: [str] = [];
    let p = 1;
    while (d.length == 0) {
        let t = digits(x, p);
        let back = mstatic.parse_float(t[0] + "e" + tostring(yt.num(t[1], 0) - p + 1));
        if (back == math.fabs(x)) { d = t; } else { p += 1; };
    };
    bigf.set_prec(saved);
    let s = d[0];
    let e = yt.num(d[1], 0);
    while (s.length > 1 && s.ends_with("0")) { s = s[:s.length - 1]; };
    if (e >= -4 && e < 16) {
        if (e >= 0) {
            let ip = if (s.length > e + 1) { s[:e + 1] } else { s + "0".repeat(e + 1 - s.length) };
            let fp = if (s.length > e + 1) { s[e + 1:] } else { "0" };
            return sign + ip + "." + fp;
        };
        return sign + "0." + "0".repeat(0 - e - 1) + s;
    };
    let es = tostring(if (e < 0) { 0 - e } else { e });
    sign + s[:1] + (if (s.length > 1) { "." + s[1:] } else { "" }) + "e" + (if (e < 0) { "-" } else { "+" })
        + (if (es.length < 2) { "0" + es } else { es })
};

// ── the kernels ──────────────────────────────────────────────────────────

let KERNELS: [Kernel] = [
    { name: "exp kernel in r", hi_tab: "exp_k", lo_tab: "exp_kl", deg: 12, kind: "exp" },
    { name: "log kernel", hi_tab: "log_k", lo_tab: "log_kl", deg: 10, kind: "log" },
    { name: "sin kernel", hi_tab: "sin_k", lo_tab: "sin_kl", deg: 5, kind: "sin" },
    { name: "cos kernel", hi_tab: "cos_k", lo_tab: "cos_kl", deg: 7, kind: "cos" },
    { name: "tanh kernel in w=x^2, tanh(x) = x*(1 + w*P(w)), |x| <= 1/2", hi_tab: "tanh_k", lo_tab: "tanh_kl", deg: 11, kind: "tanh" },
    { name: "sinh kernel", hi_tab: "sinh_k", lo_tab: "sinh_kl", deg: 7, kind: "sinh" },
    { name: "atan kernel", hi_tab: "atan_k", lo_tab: "atan_kl", deg: 12, kind: "atan" },
    { name: "asin kernel", hi_tab: "asin_k", lo_tab: "asin_kl", deg: 23, kind: "asin" }];

def eval_split(cs: [[float]], w: float) -> float {
    let n = cs.length - 1;
    let p = cs[n][0];
    let q = cs[n][1];
    let i = n - 1;
    while (i >= 0) {
        p = p * w + cs[i][0];
        q = q * w + cs[i][1];
        i -= 1;
    };
    p + q
};

def two_sum(a: float, b: float) -> [float] {
    let s = a + b;
    let bb = s - a;
    [s, (a - (s - bb)) + (b - bb)]
};

// What the module's large asin branch does with the kernel's value k.
def asin_big(k: float, z: float) -> float {
    let s = math.sqrt(z);
    let t = two_sum(2.0 * s, (2.0 * s) * z * k);
    let lo = t[1];
    if (s > 0.0) { lo = lo + 2.0 * ((z - s * s) / (2.0 * s)) * (1.0 + z * k); };
    let d = two_sum(1.57079632679489661923, 0.0 - t[0]);
    d[0] + (d[1] - lo)
};

/** What the function returns, from the kernel's value k at u. */
def compose(kind: str, k: float, u: float) -> float {
    if (kind == "exp") { return 1.0 + u * (1.0 + u * k); };
    if (kind == "log") { return math.sqrt(u) * (2.0 + u * k); };
    if (kind == "cos") { return 1.0 - u * k; };
    if (kind == "asin") { return asin_big(k, u); };
    math.sqrt(u) * (1.0 + u * k)
};

def ulp(x: float) -> float {
    let a = math.fabs(x);
    math.bitsf(math.fbits(a) + 1) - a
};

def report(kr: Kernel, cs: [[float]]) {
    let h = bigf.to_double(range_of(kr.kind));
    let worst = 0.0;
    let at = 0.0;
    let n = 4001;
    for i in 0..n {
        let ui: float = i;
        let u = h * ui / 4000.0;
        let got = compose(kr.kind, eval_split(cs, u), u);
        let want = compose(kr.kind, bigf.to_double(exact(kr.kind, bigf.from_double(u))), u);
        if (want != 0.0 && !math.is_inf(want) && !math.is_nan(want)) {
            let e = math.fabs(got - want) / ulp(want);
            if (e > worst) {
                worst = e;
                at = u;
            };
        };
    };
    print("### " + kr.name + ", u in [0, " + repr(h) + "], degree " + tostring(kr.deg) + ": worst "
        + repr(math.floor(worst * 1000.0 + 0.5) / 1000.0) + " ulp (at u=" + repr(at) + ")");
    for i in 0..cs.length { print("    // c" + tostring(i) + "  hi " + repr(cs[i][0]) + "   lo " + repr(cs[i][1])); };
    print("");
};

def main(av: [str]) -> long {
    let rep = av.length > 0 && av[0] == "report";
    let src = mgen.src();
    let bad: [str] = [];
    foreach (kr in KERNELS) {
        bigf.set_prec(WORK);
        let cs: [[float]] = [];
        foreach (c in fit(kr.kind, kr.deg)) { cs += split(c); };
        bigf.set_prec(320);
        if (rep) { report(kr, cs); };
        let his = mgen.let_floats(src, kr.hi_tab);
        let los = mgen.let_floats(src, kr.lo_tab);
        let same = his.length == cs.length && los.length == cs.length;
        for i in 0..cs.length {
            if (same && (math.fbits(his[i]) != math.fbits(cs[i][0]) || math.fbits(los[i]) != math.fbits(cs[i][1]))) {
                same = false;
                bad += kr.hi_tab + "[" + tostring(i) + "]: math.y has " + repr(his[i]) + " / " + repr(los[i]) + ", the fit "
                    + repr(cs[i][0]) + " / " + repr(cs[i][1]);
            };
        };
        if (!same && (his.length != cs.length || los.length != cs.length)) { bad += kr.hi_tab + ": a different degree"; };
    };
    if (bad.length == 0) {
        print("  math.y's 8 kernel tables are the fit, hi and lo, to the bit");
        return 0;
    };
    print("math.y's kernel tables differ from the fit (ytest math-fit report prints it):");
    foreach (b in bad) { print("  " + b); };
    1
};

export { main, repr };
