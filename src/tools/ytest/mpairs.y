// mpairs.y -- the two-argument math functions (hypot, atan2) against an
// independent high-precision reference, over pairs of arguments.
//
// WHY. A one-argument sweep has a reference in every library; hypot and atan2
// need one written here, and their difficulty is the RATIO of the two
// arguments, which a handful of table cases cannot cover: hypot was 2 ulps from
// libm on 0.75% of the pairs with |s/m| in 1e-8..1e-1, and atan2 dropped the
// sign of y at an infinite x, with fourteen and thirty-five table cases each.
//
// THE REFERENCES (bigf.y, PREC bits). hypot is sqrt(x^2 + y^2) with nothing to
// cancel and no exponent range to leave; atan2 applies the quadrant to
// atan(y/x), the ratio formed exactly so y/x never overflows or flushes, and
// spells out every zero and infinity (-0.0 is neither above nor below zero, so
// a `y > 0` ladder answers the same for all four zero pairs). A hand-written
// reference is what must not be trusted on its own, so before any sweep both
// are checked against libm on every two-argument case in ulp_table.txt, and a
// disagreement stops the run as a bug HERE.
//
// THE PAIRS, and why three families. The edges crossed with themselves (the
// zeros, subnormals, infinities and the NaN, where the sign-of-zero defects
// live); a CORRELATED family -- every second decade, the two arguments in a
// small ratio (equal, twice, half, 3-4-5, 1e-8) -- because independent draws
// make s ~ m rare, and hypot once answered +inf for every m in
// (9.4808e153, 1e154) with s comparable to m (20000 independent draws: 0.11
// expected hits); and the thresholds the code tests (1e-152, 1e153) with their
// neighbours. Then independent decade-uniform draws to fill.
//
// The sweep runs under the BUILT compiler: a driver of the pairs as bit
// patterns is compiled with YCC and its answers are measured in ulps.
//
//   ytest math-pairs [N]       N pairs (default 20000; the suite uses 4000)
import fs;
import math;
import yt;
import yc;
import bigf;

let TOL = 1;

// the positive quiet NaN, as libm writes it (0.0 / 0.0 has the sign bit set)
def nan() -> float { math.bitsf(9221120237041090560) };

def is_neg(x: float) -> bool { math.fbits(x) < 0 };

// ulp_check.y's key, transcribed: +0.0 is 0, -0.0 is 2^63 - 1.
def key(x: float) -> long {
    let b = math.fbits(x);
    if (b < 0) { 0 - 1 - b } else { b }
};

def gap(got: float, want: float) -> long {
    let gn = math.is_nan(got);
    let wn = math.is_nan(want);
    if (gn || wn) { return if (gn && wn) { 0 } else { 4611686018427387904 }; };
    let d = key(got) - key(want);
    if (d < 0) { 0 - d } else { d }
};

def ref_hypot(x: float, y: float) -> float {
    // the infinity FIRST: C99, IEEE 754 and glibc give +inf for hypot(inf, nan)
    if (math.is_inf(x) || math.is_inf(y)) { return math.inf; };
    if (math.is_nan(x) || math.is_nan(y)) { return nan(); };
    let a = bigf.from_double(x);
    let b = bigf.from_double(y);
    bigf.to_double(bigf.sqrt(bigf.add(bigf.mul(a, a), bigf.mul(b, b))))
};

def pi_part(num: long, den: long, negative: bool) -> float {
    let v = bigf.div_small(bigf.mul(bigf.pi(), bigf.from_long(num)), den);
    bigf.to_double(if (negative) { bigf.neg(v) } else { v })
};

def ref_atan2(y: float, x: float) -> float {
    if (math.is_nan(x) || math.is_nan(y)) { return nan(); };
    let yneg = is_neg(y);
    let xneg = is_neg(x);
    let dpi = 3.141592653589793;
    if (math.is_inf(x) && math.is_inf(y)) {
        // |y/x| is 1: pi/4 on the positive x side, 3pi/4 on the negative, y the sign
        return if (!xneg) { pi_part(1, 4, yneg) } else { pi_part(3, 4, yneg) };
    };
    if (math.is_inf(x)) {
        if (xneg) { return if (yneg) { 0.0 - dpi } else { dpi }; };
        return if (yneg) { 0.0 * -1.0 } else { 0.0 };
    };
    if (math.is_inf(y)) { return pi_part(1, 2, yneg); };
    if (x == 0.0 && y == 0.0) {
        if (xneg) { return if (yneg) { 0.0 - dpi } else { dpi }; };
        return if (yneg) { 0.0 * -1.0 } else { 0.0 };
    };
    if (x == 0.0) { return pi_part(1, 2, yneg); };
    if (y == 0.0) {
        if (xneg) { return if (yneg) { 0.0 - dpi } else { dpi }; };
        return if (yneg) { 0.0 * -1.0 } else { 0.0 };
    };
    let a = bigf.atan(bigf.div(bigf.from_double(y), bigf.from_double(x)));
    if (xneg) {
        a = if (!yneg) { bigf.add(a, bigf.pi()) } else { bigf.sub(a, bigf.pi()) };
    };
    bigf.to_double(a)
};

// Every two-argument case of ulp_table.txt against the references: "" when all
// agree with libm, else the report.
def check_references(table: str, n: [long]) -> str {
    let bad: [str] = [];
    let count = 0;
    foreach (l in yt.lines(yt.read(table))) {
        let f = yt.words(l);
        if (f.length == 4 && (f[0] == "hypot" || f[0] == "atan2")) {
            count += 1;
            let a = math.bitsf(yt.num(f[1], 0));
            let b = math.bitsf(yt.num(f[2], 0));
            let want = yt.num(f[3], 0);
            let got = if (f[0] == "hypot") { ref_hypot(b, a) } else { ref_atan2(a, b) };
            if (math.fbits(got) != want) {
                bad += "    " + f[0] + " (" + f[1] + ", " + f[2] + ")  ref " + tostring(math.fbits(got)) + "  libm " + f[3];
            };
        };
    };
    n[0] = count;
    if (bad.length == 0) { return ""; };
    "  THIS FILE'S REFERENCE disagrees with libm on " + tostring(bad.length) + " of " + tostring(count) + " table cases:\n"
        + join(bad[0:if (bad.length > 8) { 8 } else { bad.length }], "\n") + "\n  The REFERENCE is wrong, not the module. Fix mpairs.y."
};

// ── the pairs ────────────────────────────────────────────────────────────

let RNG = 20261006;

def rnd() -> long {
    RNG = RNG + 7046029254386353131;
    let z = RNG;
    z = (z ^ (z >>> 30)) * -4658895280553007687;
    z = (z ^ (z >>> 27)) * -7723592293110705685;
    z ^ (z >>> 31)
};

// uniform in [lo, hi)
def uniform(lo: float, hi: float) -> float {
    let u = math.bitsf(4607182418800017408 | (rnd() >>> 12)) - 1.0;
    lo + (hi - lo) * u
};

def pair_spread(n: long) -> [[float]] {
    let head = [0.0, 0.0 * -1.0, 1.0, -1.0, 5e-324, -5e-324, 1e-320, 2.2250738585072014e-308, -2.2250738585072014e-308,
                1e-300, 1e-8, 1e8, 1e300, 1.7976931348623157e308, -1.7976931348623157e308, math.inf, 0.0 - math.inf, nan()];
    let out: [[float]] = [];
    foreach (a in head) {
        foreach (b in head) { out += [[a, b]]; };
    };
    // the correlated family: every second decade, the ratios a program writes
    let d = -323;
    while (d < 309) {
        let m = uniform(1.0, 10.0) * math.pow(10.0, tofloat(d)!);
        foreach (r in [1.0, 2.0, 0.5, 3.0, 1.0 / 3.0, 0.75, 1e-8]) {
            out += [[m * r, m]];
            out += [[0.0 - m * r, 0.0 - m]];
        };
        d += 2;
    };
    // the thresholds the code tests, crossed with a correlated partner
    foreach (t in [1e-152, 1e153]) {
        foreach (m in [math.nextafter(t, 0.0), t, math.nextafter(t, math.inf), math.nextafter(t, 0.0 - math.inf)]) {
            foreach (r in [1.0, 2.0, 0.5, 0.999, 1.001]) {
                out += [[m * r, m]];
                out += [[0.0 - m * r, 0.0 - m]];
            };
        };
    };
    while (out.length < n) {
        let p: [float] = [];
        for k in 0..2 {
            let dd = tofloat((rnd() >>> 1) % 632 - 323)!;
            let v = uniform(1.0, 10.0) * math.pow(10.0, dd);
            if (math.is_nan(v) || math.is_inf(v)) { v = 1.0; };
            p += if ((rnd() & 1) == 0) { v } else { 0.0 - v };
        };
        out += [p];
    };
    out[0:n]
};

// A Y program printing, per pair, "A ybits xbits", then atan2 and hypot's bits.
def y_source(ps: [[float]]) -> str {
    let ys: [str] = [];
    let xs: [str] = [];
    foreach (p in ps) {
        ys += tostring(math.fbits(p[0]));
        xs += tostring(math.fbits(p[1]));
    };
    "import math;\nlet ys: [long] = [" + join(ys, ", ") + "];\nlet xs: [long] = [" + join(xs, ", ") + "];\n"
        + "let i = 0;\nwhile (i < len(xs)) {\n    let y = math.bitsf(ys[i]);\n    let x = math.bitsf(xs[i]);\n"
        + "    print(\"A \" + tostring(math.fbits(y)) + \" \" + tostring(math.fbits(x)));\n"
        + "    print(\"atan2 \" + tostring(math.fbits(math.atan2(y, x))));\n"
        + "    print(\"hypot \" + tostring(math.fbits(math.hypot(x, y))));\n    i = i + 1\n};\n"
};

/** The audit: references first, then the sweep. 0 clean, 1 over tolerance, 2 broken. */
def audit(n: long) -> long {
    let count = [0];
    let bad = check_references(yc.ROOT + "/test/math/ulp_table.txt", count);
    if (bad != "") {
        print(bad);
        return 2;
    };
    print("  reference check: " + tostring(count[0]) + " two-argument table cases, all agree with libm");
    let ps = pair_spread(n);
    let src = yt.tmp("pairs") + ".y";
    let exe = yt.tmp("pairs");
    yt.write(src, y_source(ps));
    let c = yc.compile(yc.YCC, [], src, exe, 600);
    if (c.code != 0) {
        eputs("cannot build the pair driver:\n" + c.out);
        return 2;
    };
    let r = yt.exe([exe]);
    fs.remove_file(src);
    fs.remove_file(exe);
    if (r.code != 0) {
        eputs("the pair driver died: " + r.err);
        return 2;
    };
    let lines = yt.lines(r.out);
    if (lines.length != ps.length * 3) {
        eputs("the driver printed " + tostring(lines.length) + " lines, expected " + tostring(ps.length * 3));
        return 2;
    };
    let names = ["atan2", "hypot"];
    let worst = [0, 0];
    let where = ["", ""];
    let over = [0, 0];
    for j in 0..ps.length {
        let head = yt.words(lines[j * 3]);
        let y = math.bitsf(yt.num(head[1], 0));
        let x = math.bitsf(yt.num(head[2], 0));
        for k in 0..2 {
            let got = math.bitsf(yt.num(yt.words(lines[j * 3 + 1 + k])[1], 0));
            let want = if (k == 0) { ref_atan2(y, x) } else { ref_hypot(x, y) };
            let g = gap(got, want);
            if (g > worst[k]) {
                worst[k] = g;
                where[k] = "(" + tostring(math.fbits(y)) + ", " + tostring(math.fbits(x)) + "): got " + tostring(math.fbits(got))
                    + " want " + tostring(math.fbits(want));
            };
            if (g > TOL) { over[k] += 1; };
        };
    };
    print("");
    print("  " + tostring(ps.length) + " PAIRS x 2 functions: the edges, a correlated family, the code's thresholds, then decade-uniform draws");
    print("  function   over " + tostring(TOL) + "   worst ulp");
    for k in 0..2 { print("  " + names[k].pad_right(8) + tostring(over[k]).pad_left(9) + tostring(worst[k]).pad_left(12)); };
    if (over[0] == 0 && over[1] == 0) {
        print("\n  NOTHING OVER " + tostring(TOL) + " ULP");
        return 0;
    };
    print("\n  WORST PER FUNCTION, so a regression names itself (argument bits):");
    for k in 0..2 {
        if (over[k] > 0) { print("    " + names[k] + " worst " + tostring(worst[k]) + " ulp at " + where[k] + "  (" + tostring(over[k]) + " over)"); };
    };
    1
};

def main(av: [str]) -> long { audit(if (av.length > 0) { yt.num(av[0], 20000) } else { 20000 }) };

export { audit, main, ref_hypot, ref_atan2, check_references };
