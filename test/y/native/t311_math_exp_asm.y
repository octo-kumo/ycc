// exp, in assembly, against the Y loop it replaces: bit for bit, over 10k
// arguments.
//
// src/y/arch/math.s's y_exp is generated from std/math.y's own constants and
// walks the same operations in the same order, so the promise is not "close to"
// but "the same double". That makes the test a comparison of patterns over a
// corpus rather than a tolerance over a few values, and it is worth having the
// corpus reach every branch: the NaN test, the two range edges, the reduction
// boundary at each end, the subnormal band where ldexp doubles one step at a
// time, and the top of the range where the last whole ln2 stays in r.
import math;

// One bit of difference: enough to say "the same double", and it keeps -0.0 and
// +0.0 apart, which `==` does not.
def same(a: float, b: float) -> bool {
    math.fbits(a) == math.fbits(b)
};

def pat(x: float) -> str {
    let h = "";
    let d = "0123456789abcdef";
    let n = math.fbits(x);
    let shift = 60;
    while (shift >= 0) {
        let nib = (n >> shift) & 15;
        h += d[nib:nib + 1];
        shift = shift - 4;
    };
    h
};

let bad = 0;
let n = 0;

def check(x: float) -> void {
    let a = math.exp(x);
    let b = math.exp_y(x);
    n = n + 1;
    if (!same(a, b)) {
        bad = bad + 1;
        // only the first few, so a systematic break is readable
        if (bad < 12) {
            print(f"x={x:<24.17} asm {pat(a)} y {pat(b)}");
        }
    }
};

// ── the edges, one per branch ─────────────────────────────────────────────
check(0.0);
check(0.0 - 0.0);
check(1.0);
check(0.0 - 1.0);
check(math.nan);
check(1.0 / 0.0);
check(0.0 - (1.0 / 0.0));
check(5.0e-324);                 // the least subnormal in
check(0.0 - 5.0e-324);
check(1.7976931348623157e308);    // and the largest finite in
// the two range edges, and either side of each
check(709.782712893383996093);
check(709.782712893384);
check(709.0);
check(708.0);
check(709.4);                    // round(x*log2e) first reaches 1024 here
check(709.5);
check(0.0 - 745.133219101941074020);
check(0.0 - 745.133219101941);
check(0.0 - 745.0);
check(0.0 - 744.0);
// the subnormal band: exp(x) is below 2^-1022 for x under -708.4, and that is
// where ldexp stops adding to the field and doubles one step at a time
let sub = 0;
while (sub < 200) {
    check(0.0 - (708.4 + sub * 0.01));
    sub = sub + 1;
};
// the reduction boundary: r = x - n*ln2 crosses zero at every n*ln2, and that is
// where the kernel's two halves are furthest from each other
let j = 0;
while (j < 400) {
    let ln2 = 0.6931471805599453094172321214581765680755001343602553;
    let x = ln2 * (j - 200);
    check(x);
    // and just either side of it, where the rounding of x*log2e + 0.5 decides n
    check(x - 5.0e-13);
    check(x + 5.0e-13);
    j = j + 1;
};

// ── the spread: 9000 arguments, deterministic ──────────────────────────────
// The golden ratio's recurrence over a range that covers both signs and every
// order of magnitude exp has an answer for. No long-to-float cast exists in Y,
// so the generator works in floats.
let i = 0;
let v = 0.5;
while (i < 9000) {
    v = (v + 1.0) * 0.6180339887498949;
    v = v - math.floor(v);
    // v in [0, 1) -> x in [-750, 715], and the edges come out of the spread too
    check(v * 1465.0 - 750.0);
    i = i + 1;
};

// ── and the answers are right, not merely equal ────────────────────────────
// Bit-identity with the Y is only half the promise; the Y is checked against the
// platform's libm in test/math/ulp_table.txt. These four are the identity an
// implementation can only pass by being right.
print(f"exp(1)  = {math.exp(1.0):.17}");
print(f"exp(-1) = {math.exp(0.0 - 1.0):.17}");
print(f"ln(exp(10)) - 10 = {math.log(math.exp(10.0)) - 10.0:.3e}");
print(f"{n} arguments, {bad} differing");