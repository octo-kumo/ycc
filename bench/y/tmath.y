// The transcendentals, in nanoseconds a call.
//
// One row per function, all of them over the same kind of argument, so the rows
// are comparable. The `(asm)`/`(y)` pairs are the interesting ones: `exp (asm)`
// is the routine in src/y/arch/math.s and `exp (y)` is the loop in std/math.y it
// replaced, and each pair returns the same double for every argument
// (t311 checks 10,420 exp arguments, t312 10,317 log, t313 10,410 each for sin
// and cos, t315 15,137 pow pairs, all bit for bit), so the gap between a pair is
// the whole of what moving it into assembly bought.
//
// pow's argument is a base near 1 and an exponent near 0, so it takes the
// general path -- the logarithm, the two-part exponent and exp2 of it -- which is
// the expensive one, and which is the row worth having. An integer exponent goes
// through the repeated-squaring path instead and is far quicker than either row
// above.
//
// The argument varies inside the timed loop on purpose: a loop-invariant call is
// something the hoister can settle once, and then the row measures the hoister
// rather than the function.
//
// FAST BY DEFAULT, DEEP ON --full. Run bare it is a smoke test: 20,000 calls a
// row, three passes, and a handful of exact assertions. Run with `--full` it is
// the full measurement -- 1,000,000 calls a row,
// best of five.
//
// The reason is that `make check` profiles every benchmark under callgrind, and
// this one at the deep setting took 107 s of it: 85 million transcendental calls
// (17 rows x 5 passes x 1,000,000) against 5 s for the next-slowest benchmark.
// A quarter of the whole check was one file, and profile.sh attributes a
// correctness sweep's loop overhead rather than anything about the kernels --
// the timing it exists to compare comes from compare.sh, which runs whatever
// this default is.
//
// So: the default is the test, and `--full` is the measurement. Nothing is lost
// -- compare.sh times base and new over the same default either way, which is
// the comparison that matters -- and `make check` gets its time back.
import math;

// `--full` for the deep run. Anything else (including no argument at all, which
// is how compare.sh, profile.sh and compile_ir.sh invoke it) is the fast one.
def wants_full() -> bool {
    let out = false;
    let args = argv();
    let i = 0;
    while (i < len(args)) {
        if (args[i] == "--full") { out = true; };
        i = i + 1;
    };
    out
};

const FULL = wants_full();

// Calls per row, and passes per row. The deep numbers are the published ones,
// so they are the ones --full keeps.
let n: long = 20000;
let passes: long = 3;
if (FULL) { n = 1000000; passes = 5; };

// Best of `passes` passes, in microseconds.
def best(f: () -> long) -> long {
    let b = 1000000000;
    let r = 0;
    while (r < passes) {
        let t = clock_us();
        f();
        let d = clock_us() - t;
        if (d < b) { b = d; };
        r = r + 1;
    };
    b
};

def row(name: str, us: long) -> void {
    print(f"{name:<14}: {us * 1000.0 / (n * 1.0):7.2f} ns/call");
};

// ── the tests ───────────────────────────────────────────────────────────
//
// Cheap and exact, and they run in BOTH modes: a benchmark whose kernels were
// quietly broken should say so rather than print a fast row. Only values that
// are exact in binary floating point are asserted, so this is not a tolerance
// question -- each of these is a case where the right answer is representable.
//
// The `(asm)`/`(y)` pairs are also compared against each other on a handful of
// arguments, which is the bit-identity claim the deep ulp tables (t311-t315,
// test/math/ulp_check.y) make exhaustively. A few points catch a kernel that is
// wrong everywhere; they do not replace the tables.
def exact(name: str, got: float, want: float) {
    if (got != want) {
        print(f"FAIL {name}: got {got}, want {want}");
        exit(1);
    };
};

// Only the cases where the right answer is EXACTLY representable AND the
// algorithm must land on it: the zeros, the unit values, and the integer cases
// that go through an exact path. A first attempt asserted `exp(1)` against
// libm's double and it failed -- correctly. These kernels are accurate to
// within an ulp, not bit-equal to the platform's libm, so asserting a libm value here would be
// asserting something the language does not promise.
exact("exp(0)", math.exp(0.0), 1.0);
exact("log(1)", math.log(1.0), 0.0);
exact("sin(0)", math.sin(0.0), 0.0);
exact("cos(0)", math.cos(0.0), 1.0);
exact("sqrt(4)", math.sqrt(4.0), 2.0);
exact("cbrt(27)", math.cbrt(27.0), 3.0);
exact("pow(2,10)", math.pow(2.0, 10.0), 1024.0);
exact("expm1(0)", math.expm1(0.0), 0.0);
exact("log1p(0)", math.log1p(0.0), 0.0);
exact("tanh(0)", math.tanh(0.0), 0.0);
exact("exp_y(0)", math.exp_y(0.0), 1.0);
exact("log_y(1)", math.log_y(1.0), 0.0);
exact("sin_y(0)", math.sin_y(0.0), 0.0);
exact("cos_y(0)", math.cos_y(0.0), 1.0);
exact("pow_y(2,10)", math.pow_y(2.0, 10.0), 1024.0);

// The pairs, where both sides must return the same double.
let agree = 0;
let k = 0;
while (k < 64) {
    let x = 0.125 + (k % 61) * 0.017;
    if (math.exp(x) != math.exp_y(x)) { print(f"FAIL exp != exp_y at {x}"); exit(1); };
    if (k > 0 && math.log(x) != math.log_y(x)) { print(f"FAIL log != log_y at {x}"); exit(1); };
    if (math.sin(x) != math.sin_y(x)) { print(f"FAIL sin != sin_y at {x}"); exit(1); };
    if (math.cos(x) != math.cos_y(x)) { print(f"FAIL cos != cos_y at {x}"); exit(1); };
    if (math.pow(1.125, x) != math.pow_y(1.125, x)) { print(f"FAIL pow != pow_y at {x}"); exit(1); };
    agree = agree + 1;
    k = k + 1;
};
print(f"exact checks: 15 values, {agree} (asm)/(y) pairs bit-identical");
print(FULL ? "mode: --full (1,000,000 calls a row, best of 5)" : "mode: default (fast; --full for the measurement)");

// The loop on its own, so every row below can be read net of it.
let sink = 0.0;
let t = best(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + 0.125 + (j % 997) * 0.001; j = j + 1; };
    sink = s;
    0
});
row("loop only", t);

t = best(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.exp(0.125 + (j % 997) * 0.001); j = j + 1; };
    sink = s;
    0
});
row("exp (asm)", t);

t = best(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.exp_y(0.125 + (j % 997) * 0.001); j = j + 1; };
    sink = s;
    0
});
row("exp (y)", t);

t = best(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.log(1.0 + (j % 997) * 0.001); j = j + 1; };
    sink = s;
    0
});
row("log (asm)", t);
t = best(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.log_y(1.0 + (j % 997) * 0.001); j = j + 1; };
    sink = s;
    0
});
row("log (y)", t);

// sin and cos are the same pair as exp and log: the routine in math.s and the
// loop in std/math.y it replaced, over the same arguments on both sides so the
// two rows differ only in where the arithmetic is. The argument runs to 10
// radians, so most of them take the reduction and three quadrants rather than
// the |x| <= pi/4 shortcut (t313 checks 10,410 of them bit for bit).
t = best(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.sin(0.125 + (j % 997) * 0.01); j = j + 1; };
    sink = s;
    0
});
row("sin (asm)", t);
t = best(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.sin_y(0.125 + (j % 997) * 0.01); j = j + 1; };
    sink = s;
    0
});
row("sin (y)", t);
t = best(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.cos(0.125 + (j % 997) * 0.01); j = j + 1; };
    sink = s;
    0
});
row("cos (asm)", t);
t = best(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.cos_y(0.125 + (j % 997) * 0.01); j = j + 1; };
    sink = s;
    0
});
row("cos (y)", t);

// The rest of the module, so a change to one kernel is visible against the
// others. These are all still the Y versions -- pow was the last one to move, and
// it has its own pair above.
t = best(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.atan(0.125 + (j % 997) * 0.001); j = j + 1; };
    sink = s;
    0
});
row("atan", t);
t = best(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.sqrt(0.125 + (j % 997) * 0.001); j = j + 1; };
    sink = s;
    0
});
row("sqrt", t);
t = best(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.cbrt(0.125 + (j % 997) * 0.001); j = j + 1; };
    sink = s;
    0
});
row("cbrt", t);
t = best(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.expm1((j % 997) * 0.0002); j = j + 1; };
    sink = s;
    0
});
row("expm1", t);
t = best(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.log1p((j % 997) * 0.0002); j = j + 1; };
    sink = s;
    0
});
row("log1p", t);
t = best(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.pow(1.125, 0.125 + (j % 997) * 0.001); j = j + 1; };
    sink = s;
    0
});
row("pow (asm)", t);
t = best(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.pow_y(1.125, 0.125 + (j % 997) * 0.001); j = j + 1; };
    sink = s;
    0
});
row("pow (y)", t);
t = best(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.tanh(0.125 + (j % 997) * 0.001); j = j + 1; };
    sink = s;
    0
});
row("tanh", t);
print(f"sink {sink:.6e}");