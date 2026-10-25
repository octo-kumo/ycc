// maudit.y -- three audits of std/math.y, run by hand: what they find goes
// into a fixture. Each builds a driver with the BUILT compiler (YCC), runs it,
// and checks every answer against a reference that shares no code with the
// module.
//
//   ytest math-exact [N]   the exact tier (integer helpers, modular arithmetic,
//                          bit tricks) over N arguments (4041) against exact
//                          integer arithmetic
//   ytest math-float [N]   the rounding tier over N arguments uniform IN THE
//                          DECADES (20000) against mref.y's correctly rounded
//                          references, at tolerance 1
//   ytest math-edges       every float -> float function at the same 50 edges
//                          (both zeros, both infinities, a NaN, the subnormal
//                          band, the range ends, where a reduction changes
//                          shape) against mref.y
//
// WHY A SPREAD AND WHY THE EDGES. ulp_table.txt is a gate against REGRESSION
// and exactly as good as its list; the defects it missed were in classes
// nobody listed: an intermediate leaving the range while the answer did not
// (fvariance's mean, ldexp's field, fsum_kahan's compensation, sinh(710) and
// expm1(709.5) answering inf), an answer differing only in its SIGN, and a hole
// where the list was thin (a decade-uniform spread found log2 and log10 2 ulps
// out). So: sweep, do not sample.
//
// THINGS THE PYTHON VERSIONS GOT WRONG FIRST, each a confident failing report
// about correct code: the arguments are SIGNED longs (2^64-1 arrives as -1); the
// driver and the checker must agree on which argument goes where; the modular
// functions are signed (Python's % on signed ints); clamp's precondition is
// lo <= hi, so an ill-formed call is skipped, not checked; fbits is SIGNED, so a
// gap is taken through the monotone key, never abs(bits_a - bits_b); and a
// reference is code, so it is checked before anything depends on it.
//
// WHAT math-float LEAVES OUT, AND WHY. sin, cos and tan: their reduction has no
// sharp limit (t320 measures it). sinh and cosh past their own exponential
// (t319). math-edges reports both rather than failing on them.
import fs;
import math;
import yt;
import yc;
import mref;
import mstatic;

// ── shared ───────────────────────────────────────────────────────────────

let SEED = 20261005;

// A deterministic stream (xorshift64*), so a run replays.
def next_rand(st: [long]) -> long {
    let x = st[0];
    x = x ^ (x >>> 12);
    x = x ^ (x << 25);
    x = x ^ (x >>> 27);
    st[0] = x;
    x * 2685821657736338717
};

def below(st: [long], n: long) -> long {
    let v = next_rand(st) >>> 1;
    v % n
};

def unit(st: [long]) -> float {
    let v: float = next_rand(st) >>> 11;
    v / 9007199254740992.0
};

/** Build a driver with YCC and run it: its stdout lines, or [] after saying why. */
def drive(name: str, src: str) -> [str] {
    let d = yt.tmp_dir(name);
    yt.write(d + "/" + name + ".y", src);
    let c = yc.compile(yc.YCC, [], d + "/" + name + ".y", d + "/" + name, 600);
    if (c.code != 0) {
        eputs("cannot build the audit driver:\n" + c.out);
        return [];
    };
    let r = yc.run_bin(d + "/" + name, [], "", 3600);
    fs.remove_all(d);
    if (r.code != 0) {
        eputs("the audit driver died (exit " + tostring(r.code) + "): " + yt.clip(r.out, 300) + "\n");
        return [];
    };
    let ls = yt.lines(r.out);
    while (ls.length > 0 && ls[ls.length - 1] == "") { ls = ls[:ls.length - 1]; };
    ls
};

/** A double as a Y expression that is exactly it. */
def ylit(x: float) -> str { "math.bitsf(" + tostring(math.fbits(x)) + ")" };

// ── math-exact ───────────────────────────────────────────────────────────

let LMIN = -9223372036854775807 - 1;

def edges() -> [long] {
    let xs = [0, 1, 2, 3, 4, 5, 6, 7, 8, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128, 255, 256, 257, 1023, 1024, 1025,
        4095, 4096, 65535, 65536, 2147483647, 2147483648, 4294967295, 4294967296, 9007199254740992, 9007199254740993,
        4611686018427387904, 9223372036854775807];
    // 2^64-1, 2^64-2, 2^64-3 as the longs they arrive as
    xs + [-1, -2, -3]
};

def primes() -> [long] {
    let out: [long] = [];
    let p = 3;
    while (p < 1000) {
        let d = 2;
        let prime = true;
        while (d * d <= p) {
            if (p % d == 0) { prime = false; };
            d += 1;
        };
        if (prime) { out += p; };
        p += 1;
    };
    out
};

// a seeded spread over every width from 4 to 64 bits
def exact_args(n: long) -> [long] {
    let st = [SEED];
    let xs = edges();
    let widths = [4, 8, 16, 32, 63, 64];
    while (xs.length < n) {
        let w = widths[below(st, widths.length)];
        let v = next_rand(st);
        xs += if (w == 64) { v } else { v & ((1 << w) - 1) };
    };
    xs
};

def exact_source(xs: [long], mods: [long]) -> str {
    let n = tostring(xs.length);
    let p = tostring(mods.length);
    let o = ["import math;", "let xs: [long] = [" + join(xs.map((v: long) => if (v == LMIN) { "-9223372036854775807 - 1" } else { tostring(v) }), ", ") + "];",
        "let mods: [long] = [" + join(mods.map((v: long) => tostring(v)), ", ") + "];", "let i = 0;", "while (i < " + n + ") {"];
    foreach (f in ["isqrt", "popcount", "ctz", "clz", "next_pow2", "sign", "abs"]) {
        o += "    print(\"" + f + "\", math." + f + "(xs[i]));";
    };
    foreach (f in ["gcd", "lcm", "min", "max"]) {
        o += "    print(\"" + f + "\", math." + f + "(xs[i], xs[(i * 7 + 3) % " + n + "]));";
    };
    // rotl's count is reduced: the count's range has its own fixture (t321)
    o += "    print(\"rotl\", math.rotl(xs[i], xs[(i * 7 + 3) % " + n + "] & 63));";
    o += "    print(\"clamp3\", math.clamp(xs[i], xs[(i * 7 + 3) % " + n + "], xs[(i * 11 + 1) % " + n + "]));";
    o += "    print(\"mul_mod\", math.mul_mod(xs[i], xs[(i * 7 + 3) % " + n + "], mods[i % " + p + "]));";
    o += "    i = i + 1";
    o += "};";
    o += "let j = 0;";
    o += "while (j < " + n + ") {";
    o += "    print(\"mul_mod\", math.mul_mod(xs[j], xs[(j * 11 + 5) % " + n + "], mods[j % " + p + "]));";
    o += "    print(\"pow_mod\", math.pow_mod(xs[j], xs[(j * 13 + 2) % " + n + "], mods[j % " + p + "]));";
    o += "    print(\"inv_mod\", math.inv_mod(xs[j], mods[j % " + p + "]));";
    o += "    j = j + 1";
    o += "};";
    join(o, "\n") + "\n"
};

// the references: plain long arithmetic, nothing from the module
def r_isqrt(x: long) -> long {
    if (x <= 0) { return 0; };
    let r = math.to_int(math.sqrt(x + 0.0));
    while (r > 0 && r > x / r) { r -= 1; };
    while (r + 1 <= x / (r + 1)) { r += 1; };
    r
};

def r_popcount(x: long) -> long {
    let c = 0;
    for i in 0..64 { if (((x >>> i) & 1) == 1) { c += 1; }; };
    c
};

def r_ctz(x: long) -> long {
    if (x == 0) { return 64; };
    let k = 0;
    while (((x >>> k) & 1) == 0) { k += 1; };
    k
};

def r_clz(x: long) -> long {
    if (x == 0) { return 64; };
    let k = 0;
    while (((x >>> (63 - k)) & 1) == 0) { k += 1; };
    k
};

// 1 for x <= 1, and 0 past 2^62: there is no larger power of two in a long
def r_next_pow2(x: long) -> long {
    if (x <= 1) { return 1; };
    let bl = 64 - r_clz(x - 1);
    if (bl > 62) { 0 } else { 1 << bl }
};

def r_abs(x: long) -> long { if (x < 0) { 0 - x } else { x } };

def r_gcd(a0: long, b0: long) -> long {
    let a = r_abs(a0);
    let b = r_abs(b0);
    while (b != 0) {
        let t = a % b;
        a = b;
        b = t;
    };
    a
};

// wraps, by the module's own comment
def r_lcm(a: long, b: long) -> long {
    if (a == 0 || b == 0) { 0 } else { (r_abs(a) / r_gcd(a, b)) * r_abs(b) }
};

def r_rotl(x: long, k: long) -> long { if (k == 0) { x } else { (x << k) | (x >>> (64 - k)) } };

// Python's floor modulo, which is what the modular functions are
def pmod(a: long, m: long) -> long {
    let r = a % m;
    if (r < 0) { r + m } else { r }
};

def r_pow_mod(a: long, e: long, m: long) -> long {
    let r = 1 % m;
    let b = pmod(a, m);
    let k = e;
    while (k > 0) {
        if (k % 2 == 1) { r = r * b % m; };
        b = b * b % m;
        k = k / 2;
    };
    r
};

def r_inv_mod(a: long, m: long) -> long {
    let t = 0;
    let nt = 1;
    let r = m;
    let nr = pmod(a, m);
    while (nr != 0) {
        let q = r / nr;
        let tt = t - q * nt;
        t = nt;
        nt = tt;
        let rr = r - q * nr;
        r = nr;
        nr = rr;
    };
    pmod(t, m)
};

def panic_desync(ln: str, label: str) {
    eputs("walk desynchronised at '" + yt.clip(ln, 24) + "' (wanted '" + label + "')\n");
    exit(2);
};

def main_exact(av: [str]) -> long {
    let n = if (av.length > 0) { yt.num(av[0], 4041) } else { 4041 };
    let xs = exact_args(n);
    let mods = primes();
    let p = mods.length;
    let lines = drive("exact", exact_source(xs, mods));
    let want_lines = n * 17;
    if (lines.length != want_lines) {
        eputs("the driver printed " + tostring(lines.length) + " lines, expected " + tostring(want_lines)
            + " -- the walk order and the driver disagree\n");
        return 2;
    };
    let at = [0];
    let checked = [0];
    let bad: {str => long} = {};
    let first: {str => str} = {};
    def take(label: str) -> long {
        let ln = lines[at[0]];
        at[0] += 1;
        checked[0] += 1;
        if (!ln.starts_with(label)) { panic_desync(ln, label); };
        yt.num(ln[label.length:], 0)
    };
    def note(f: str, args: str, got: long, want: long) {
        if (got != want) {
            bad[f] = (if (f in bad) { bad[f]! } else { 0 }) + 1;
            if (!(f in first)) { first[f] = "args=" + args + " got=" + tostring(got) + " want=" + tostring(want); };
        };
    };
    for i in 0..n {
        let x = xs[i];
        let y = xs[(i * 7 + 3) % n];
        let z = xs[(i * 11 + 1) % n];
        let m = mods[i % p];
        let sx = tostring(x);
        let sxy = "(" + sx + ", " + tostring(y) + ")";
        note("isqrt", sx, take("isqrt"), r_isqrt(x));
        note("popcount", sx, take("popcount"), r_popcount(x));
        note("ctz", sx, take("ctz"), r_ctz(x));
        note("clz", sx, take("clz"), r_clz(x));
        note("next_pow2", sx, take("next_pow2"), r_next_pow2(x));
        note("sign", sx, take("sign"), if (x == 0) { 0 } else if (x > 0) { 1 } else { -1 });
        note("abs", sx, take("abs"), r_abs(x));
        let g = take("gcd");
        let l = take("lcm");
        // |LONG_MIN| has no long: the exact reference has no answer to compare
        if (x != LMIN && y != LMIN) {
            note("gcd", sxy, g, r_gcd(x, y));
            note("lcm", sxy, l, r_lcm(x, y));
        };
        note("min", sxy, take("min"), if (x < y) { x } else { y });
        note("max", sxy, take("max"), if (x > y) { x } else { y });
        note("rotl", sxy, take("rotl"), r_rotl(x, y & 63));
        let c = take("clamp3");
        // clamp's precondition is lo <= hi; an ill-formed call is not a finding
        if (y <= z) { note("clamp", sxy, c, if (x < y) { y } else if (x > z) { z } else { x }); };
        note("mul_mod", sxy, take("mul_mod"), pmod(x, m) * pmod(y, m) % m);
    };
    for j in 0..n {
        let a = xs[j];
        let b = xs[(j * 11 + 5) % n];
        let e = xs[(j * 13 + 2) % n];
        let m = mods[j % p];
        note("mul_mod", tostring(a), take("mul_mod"), pmod(a, m) * pmod(b, m) % m);
        let g = take("pow_mod");
        if (e >= 0 && e < 1048576) { note("pow_mod", tostring(a) + "^" + tostring(e), g, r_pow_mod(a, e, m)); };
        let iv = take("inv_mod");
        // no inverse when a is a multiple of m
        if (pmod(a, m) != 0) { note("inv_mod", tostring(a), iv, r_inv_mod(a, m)); };
    };
    print("  " + tostring(checked[0]) + " answers over " + tostring(n) + " arguments, 14 functions, against exact integers");
    if (keys(first).length == 0) {
        print("  NOTHING WRONG");
        return 0;
    };
    print("  FAILURES:");
    foreach (f in keys(first)) { print("    " + f.pad_right(10) + tostring(bad[f]!).pad_left(6) + " failing; first: " + first[f]!); };
    1
};

// ── math-float ───────────────────────────────────────────────────────────

let FLOAT_FNS = ["exp", "expm1", "log", "log10", "log1p", "log2"];

def spread(n: long) -> [float] {
    let out = [0.0, 0.0 * -1.0, 1.0, -1.0, 5e-324, -5e-324, 1e-320, 2.2250738585072014e-308, -2.2250738585072014e-308,
        1e-300, 1e-8, 1.0e8, 1e300, 1e15, 1e-15, 1.7976931348623157e308, -1.7976931348623157e308, math.inf,
        0.0 - math.inf, mref.nan()];
    // 10^d for every decade, each the double nearest it
    let p10: [float] = [];
    for d in -323..309 { p10 += mstatic.parse_float("1e" + tostring(d)); };
    let st = [SEED + 7];
    while (out.length < n) {
        let d = below(st, 632);
        let v = (1.0 + 9.0 * unit(st)) * p10[d];
        if (!math.is_nan(v) && !math.is_inf(v)) { out += if (unit(st) < 0.5) { v } else { 0.0 - v }; };
    };
    out
};

def ref_float(name: str, x: float) -> float { mref.one_arg(name, x)[0] };

def main_float(av: [str]) -> long {
    let n = if (av.length > 0) { yt.num(av[0], 20000) } else { 20000 };
    let xs = spread(n);
    let o = ["import math;", "let xs: [long] = [" + join(xs.map((x: float) => tostring(math.fbits(x))), ", ") + "];",
        "foreach (b in xs) {", "    let x = math.bitsf(b);"];
    foreach (f in FLOAT_FNS) { o += "    print(math.fbits(math." + f + "(x)));"; };
    o += "};";
    let lines = drive("float", join(o, "\n") + "\n");
    if (lines.length != xs.length * FLOAT_FNS.length) {
        eputs("the driver printed " + tostring(lines.length) + " lines, expected "
            + tostring(xs.length * FLOAT_FNS.length) + "\n");
        return 2;
    };
    let over = FLOAT_FNS.map((f: str) => 0);
    let worst = FLOAT_FNS.map((f: str) => 0);
    let at: [str] = FLOAT_FNS.map((f: str) => "");
    let k = 0;
    foreach (x in xs) {
        let i = 0;
        while (i < FLOAT_FNS.length) {
            let got = math.bitsf(yt.num(lines[k], 0));
            let want = ref_float(FLOAT_FNS[i], x);
            let g = mref.gap(got, want);
            if (g > worst[i]) {
                worst[i] = g;
                at[i] = "x=" + tostring(math.fbits(x)) + ": got " + tostring(math.fbits(got)) + ", want " + tostring(math.fbits(want));
            };
            if (g > 1) { over[i] += 1; };
            k += 1;
            i += 1;
        };
    };
    print("  " + tostring(xs.length) + " arguments x " + tostring(FLOAT_FNS.length)
        + " functions, uniform in the decades, against mref.y (correctly rounded)");
    print("  function    over 1   worst ulp");
    let bad = false;
    let i = 0;
    while (i < FLOAT_FNS.length) {
        print("  " + FLOAT_FNS[i].pad_right(8) + tostring(over[i]).pad_left(10) + tostring(worst[i]).pad_left(12));
        if (over[i] > 0) { bad = true; };
        i += 1;
    };
    print("  sin, cos, tan: skipped, the reduction has no sharp limit (t320); sinh, cosh: past their exponential (t319)");
    if (!bad) {
        print("\n  NOTHING OVER 1 ULP");
        return 0;
    };
    print("\n  WORST PER FUNCTION:");
    i = 0;
    while (i < FLOAT_FNS.length) {
        if (over[i] > 0) { print("    " + FLOAT_FNS[i] + " " + tostring(worst[i]) + " ulp at " + at[i]); };
        i += 1;
    };
    1
};

// ── math-edges ───────────────────────────────────────────────────────────

let EDGE_FNS = ["fabs", "fsign", "floor", "ceil", "trunc", "round", "fract", "cbrt", "exp", "exp2", "expm1", "log",
    "log2", "log10", "log1p", "sin", "cos", "tan", "asin", "acos", "atan", "sinh", "cosh", "tanh", "sqrt"];

def edge_args() -> [[str]] {
    let pi = 3.141592653589793;
    let ln2 = 0.6931471805599453;
    let a = [["+0.0", "0.0"], ["-0.0", "-0.0"], ["1.0", "1.0"], ["-1.0", "-1.0"], ["0.5", "0.5"], ["-0.5", "-0.5"],
        ["2.0", "2.0"], ["-2.0", "-2.0"], ["0.25", "0.25"], ["0.75", "0.75"], ["1e-300", "1e-300"],
        ["-1e-300", "-1e-300"], ["1e-16", "1e-16"], ["1e16", "1e16"], ["-1e16", "-1e16"], ["subnormal", "5e-324"],
        ["-subnormal", "-5e-324"], ["min normal", "2.2250738585072014e-308"],
        ["-min normal", "-2.2250738585072014e-308"], ["1e-30", "1e-30"], ["1e30", "1e30"], ["709.0", "709.0"],
        ["709.4", "709.4"], ["709.78", "709.782712893384"], ["710.0", "710.0"], ["710.4", "710.4"],
        ["710.47", "710.47"], ["-700.0", "-700.0"], ["-745.0", "-745.0"], ["-745.13", "-745.1332191019411"],
        ["-746.0", "-746.0"], ["-1000.0", "-1000.0"], ["1e308", "1e308"], ["-1e308", "-1e308"], ["1e300", "1e300"],
        ["asin's edge 1-2^-27", "0.9999999925494194"], ["asin's edge -1+2^-27", "-0.9999999925494194"]];
    let out: [[str]] = [];
    foreach (p in a) {
        out += [p[0], tostring(math.fbits(if (p[1] == "-0.0") { 0.0 * -1.0 } else { mstatic.parse_float(p[1]) }))];
    };
    let names = ["ln2", "-ln2", "ln2/2", "-ln2/2", "pi/4", "-pi/4", "pi/2", "-pi/2", "pi", "-pi", "+inf", "-inf", "nan"];
    let vals = [ln2, 0.0 - ln2, ln2 / 2.0, 0.0 - ln2 / 2.0, pi / 4.0, 0.0 - pi / 4.0, pi / 2.0, 0.0 - pi / 2.0, pi,
        0.0 - pi, math.inf, 0.0 - math.inf, mref.nan()];
    for i in 0..names.length { out += [names[i], tostring(math.fbits(vals[i]))]; };
    out
};

def main_edges(av: [str]) -> long {
    let args = edge_args();
    let o = ["import math;", "let args: [long] = [" + join(args.map((p: [str]) => p[1]), ", ") + "];",
        "def apply(k: long, x: float) -> float {"];
    let k = 0;
    foreach (f in EDGE_FNS) {
        o += "    " + (if (k > 0) { "else " } else { "" }) + "if (k == " + tostring(k) + ") { math." + f + "(x) }";
        k += 1;
    };
    o += "    else { x }";
    o += "};";
    o += "for k in 0.." + tostring(EDGE_FNS.length) + " { foreach (b in args) { print(math.fbits(apply(k, math.bitsf(b)))); }; };";
    let lines = drive("edges", join(o, "\n") + "\n");
    if (lines.length != EDGE_FNS.length * args.length) {
        eputs("the sweep printed " + tostring(lines.length) + " lines, expected " + tostring(EDGE_FNS.length * args.length) + "\n");
        return 2;
    };
    print("fn          worst  at argument");
    print("-".repeat(60));
    let findings: [str] = [];
    let at = 0;
    foreach (f in EDGE_FNS) {
        let worst = 0;
        let wname = "-";
        let degraded = 0;
        let degraded_over = 0;
        foreach (p in args) {
            let x = math.bitsf(yt.num(p[1], 0));
            let got = math.bitsf(yt.num(lines[at], 0));
            at += 1;
            let g = mref.gap(got, mref.one_arg(f, x)[0]);
            // sin/cos/tan past 1e8: the reduction degrades by design (t320); counted, not failed
            if ((f == "sin" || f == "cos" || f == "tan") && math.fabs(x) > 1.0e8 && !math.is_inf(x)) {
                degraded += 1;
                if (g > 1) { degraded_over += 1; };
            } else if (g > worst) {
                worst = g;
                wname = p[0];
            };
        };
        let extra = if (degraded > 0) { "   (" + tostring(degraded_over) + "/" + tostring(degraded) + " arguments past 1e8 over 1 ulp)" } else { "" };
        let ws = if (worst >= 4611686018427387904) { "inf" } else { tostring(worst) };
        print(f.pad_right(8) + ws.pad_left(9) + "  " + wname + extra);
        if (worst > 1) { findings += f + " " + ws + " ulp at " + wname; };
    };
    print("-".repeat(60));
    if (findings.length == 0) {
        print("every function within 1 ulp of the correctly rounded answer at every edge");
        return 0;
    };
    print("OVER 1 ULP:");
    foreach (s in findings) { print("  " + s); };
    1
};

export { main_exact, main_float, main_edges };
