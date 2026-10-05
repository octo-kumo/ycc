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
import math;

let n: long = 1000000;

// Best of five passes, in microseconds.
def best5(f: () -> long) -> long {
    let b = 1000000000;
    let r = 0;
    while (r < 5) {
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

// The loop on its own, so every row below can be read net of it.
let sink = 0.0;
let t = best5(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + 0.125 + (j % 997) * 0.001; j = j + 1; };
    sink = s;
    0
});
row("loop only", t);

t = best5(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.exp(0.125 + (j % 997) * 0.001); j = j + 1; };
    sink = s;
    0
});
row("exp (asm)", t);

t = best5(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.exp_y(0.125 + (j % 997) * 0.001); j = j + 1; };
    sink = s;
    0
});
row("exp (y)", t);

t = best5(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.log(1.0 + (j % 997) * 0.001); j = j + 1; };
    sink = s;
    0
});
row("log (asm)", t);
t = best5(def () -> long {
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
t = best5(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.sin(0.125 + (j % 997) * 0.01); j = j + 1; };
    sink = s;
    0
});
row("sin (asm)", t);
t = best5(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.sin_y(0.125 + (j % 997) * 0.01); j = j + 1; };
    sink = s;
    0
});
row("sin (y)", t);
t = best5(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.cos(0.125 + (j % 997) * 0.01); j = j + 1; };
    sink = s;
    0
});
row("cos (asm)", t);
t = best5(def () -> long {
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
t = best5(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.atan(0.125 + (j % 997) * 0.001); j = j + 1; };
    sink = s;
    0
});
row("atan", t);
t = best5(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.sqrt(0.125 + (j % 997) * 0.001); j = j + 1; };
    sink = s;
    0
});
row("sqrt", t);
t = best5(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.cbrt(0.125 + (j % 997) * 0.001); j = j + 1; };
    sink = s;
    0
});
row("cbrt", t);
t = best5(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.expm1((j % 997) * 0.0002); j = j + 1; };
    sink = s;
    0
});
row("expm1", t);
t = best5(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.log1p((j % 997) * 0.0002); j = j + 1; };
    sink = s;
    0
});
row("log1p", t);
t = best5(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.pow(1.125, 0.125 + (j % 997) * 0.001); j = j + 1; };
    sink = s;
    0
});
row("pow (asm)", t);
t = best5(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.pow_y(1.125, 0.125 + (j % 997) * 0.001); j = j + 1; };
    sink = s;
    0
});
row("pow (y)", t);
t = best5(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.tanh(0.125 + (j % 997) * 0.001); j = j + 1; };
    sink = s;
    0
});
row("tanh", t);
print(f"sink {sink:.6e}");