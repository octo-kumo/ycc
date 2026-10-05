// The six bulk kernels against the Y loops they replace, element for element.
//
// Each kernel in src/y/arch/math.s is a drop-in for the loop beside it in
// std/math.y, which means the same double out of the same bits in -- so this
// compares them over a corpus rather than within a tolerance. It also walks the
// edges the loops care about: +0.0 and -0.0 (0.0 + a[0] is not a[0] when a[0] is
// -0.0, which is why the accumulator starts at +0.0), infinities, NaN in every
// position, subnormals, one element, and the empty array.
import math;

def eq_bits(x: float, y: float) -> bool {
    // Equal as doubles, including -0.0 against +0.0 and NaN against NaN: the
    // kernels promise the same BITS, not the same comparison.
    math.fbits(x) == math.fbits(y)
};

def check(name: str, got: float, want: float) -> long {
    if (eq_bits(got, want)) {
        0
    } else {
        print(f"{name}: got {fbits_hex(got)}, want {fbits_hex(want)}");
        1
    }
};

def fbits_hex(x: float) -> str {
    // The pattern in hex; fbits is a long, and the format specifier is the one
    // for a plain long.
    let h = "";
    let n = math.fbits(x);
    let d = "0123456789abcdef";
    let shift = 60;
    while (shift >= 0) {
        let nib = (n >> shift) & 15;
        h += d[nib:nib + 1];
        shift = shift - 4;
    };
    "0x" + h
};

let bad = 0;

// ── the corpus: a spread, a geometric one, and the awkward values ──────────
// A deterministic spread over four orders of magnitude and both signs, so the
// corpus is the same on every run and every compiler. The recurrence is the
// golden ratio's: multiply by 2/phi-ish and take the fractional part, which is
// the cheapest generator there is that does not need a long-to-float cast (Y
// has the float-to-long one and not its inverse).
def corpus(n: long) -> [float] {
    let a: [float] = [];
    let i = 0;
    let v = 0.5;
    while (i < n) {
        v = (v + 1.0) * 0.6180339887498949;
        v = v - math.floor(v);
        a += v * 1000.0 - 500.0;
        a += v;
        i = i + 1;
    };
    a
};

def mixed() -> [float] {
    // +0, -0, the two infinities, a signalling-ish NaN, a quiet NaN, the
    // smallest subnormal, the largest finite, 1, -1 and a value in between.
    [0.0, 0.0 - 0.0, 1.0 / 0.0, 0.0 - (1.0 / 0.0), math.nan, 0.0 / 0.0,
     5.0e-324, 1.7976931348623157e308, 1.0, 0.0 - 1.0, 0.1, 1e300, 2.0, 3.0]
};

def report(name: str, a: [float]) -> void {
    bad += check(name + "/sum", math.fsum(a), math.fsum_y(a));
    bad += check(name + "/min", math.fmin_of(a), math.fmin_of_y(a));
    bad += check(name + "/max", math.fmax_of(a), math.fmax_of_y(a));
};

let empty: [float] = [];
report("empty", empty);
report("one", [2.5]);
report("two", [2.5, 2.5]);
report("mixed", mixed());
let m = mixed();
let mrev: [float] = [];
let ri = 0;
while (ri < len(m)) {
    mrev += m[len(m) - 1 - ri];
    ri = ri + 1;
};
report("mixed-rev", mrev);
let i = 0;
while (i < 64) {
    report(f"rand{i}", corpus(i + 1));
    i = i + 1;
};
// the extremes, with a NaN in first, middle and last position
let with_nan_first = [math.nan, 1.0, 2.0];
let with_nan_mid = [1.0, math.nan, 2.0];
let with_nan_last = [1.0, 2.0, math.nan];
report("nan_first", with_nan_first);
report("nan_mid", with_nan_mid);
report("nan_last", with_nan_last);
let with_inf = [1.0 / 0.0, 0.0 - (1.0 / 0.0), 0.0, 1.0];
report("inf", with_inf);

// ── the dot product: two arrays, including a NaN in either ────────────────
let u = corpus(37);
let w = corpus(37);
bad += check("dot", math.fdot(u, w), math.fdot_y(u, w));
let v = [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0];
bad += check("dot_spike", math.fdot(v, v), math.fdot_y(v, v));
bad += check("dot_empty", math.fdot(empty, empty), math.fdot_y(empty, empty));
let one_nan = corpus(5);
one_nan[2] = math.nan;
bad += check("dot_nan", math.fdot(one_nan, corpus(5)), math.fdot_y(one_nan, corpus(5)));
bad += check("dot_o1", math.fdot(mixed(), mixed()), math.fdot_y(mixed(), mixed()));

// ── fscale and faxpy: the in-place ones, compared against a Y copy ────────
def same(a: [float], b: [float]) -> bool {
    if (len(a) != len(b)) {
        false
    } else {
        let i = 0;
        let ok = true;
        while (i < len(a)) {
            if (!eq_bits(a[i], b[i])) { ok = false; };
            i = i + 1;
        };
        ok
    }
};

let scales: [float] = [2.0, 0.5, 0.0, 1.0 / 0.0, 0.0 - 1.0, 5.0e-324, 3.0];
let si = 0;
while (si < len(scales)) {
    let k = scales[si];
    let a1 = mixed();
    let a2 = mixed();
    math.fscale(a1, k);
    math.fscale_y(a2, k);
    if (!same(a1, a2)) {
        print(f"scale {fbits_hex(k)}: differs");
        bad = bad + 1;
    };
    let y1 = mixed();
    let y2 = mixed();
    math.faxpy(y1, k, mixed());
    math.faxpy_y(y2, k, mixed());
    if (!same(y1, y2)) {
        print(f"axpy {fbits_hex(k)}: differs");
        bad = bad + 1;
    };
    // a long one, so the pointer walk is walked a long way
    let b1 = corpus(1000);
    let b2 = corpus(1000);
    math.fscale(b1, k);
    math.fscale_y(b2, k);
    if (!same(b1, b2)) { print("scale long differs"); bad = bad + 1; };
    let c1 = corpus(1000);
    let c2 = corpus(1000);
    math.faxpy(c1, k, corpus(1000));
    math.faxpy_y(c2, k, corpus(1000));
    if (!same(c1, c2)) { print("axpy long differs"); bad = bad + 1; };
    si = si + 1;
};

// ── the rest of the array tier still agrees with itself ───────────────────
// corpus(n) appends two elements per iteration, so divide by len and not by n
let mean_a = corpus(13);
bad += check("mean", math.fmean(mean_a), math.fsum(mean_a) / len(mean_a));
print(f"fmin_of empty {fbits_hex(math.fmin_of(empty))}");
print(f"fmax_of empty {fbits_hex(math.fmax_of(empty))}");
print(bad);