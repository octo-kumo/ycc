// The transcendentals, in nanoseconds a call.
//
// One row per function, all of them over the same kind of argument, so the rows
// are comparable. The `exp` pair is the interesting one: `exp (asm)` is the
// routine in src/y/arch/math.s and `exp (y)` is the loop in std/math.y it
// replaced, and the two return the same double for every argument
// (test/y/native/t311_math_exp_asm.y checks 10,420 of them bit for bit), so the
// gap between those two rows is the whole of what moving it into assembly bought.
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

// The rest of the module, so a change to one kernel is visible against the
// others. These are all still the Y versions except where a name says otherwise.
t = best5(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.log(1.0 + (j % 997) * 0.001); j = j + 1; };
    sink = s;
    0
});
row("log", t);
t = best5(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.sin(0.125 + (j % 997) * 0.01); j = j + 1; };
    sink = s;
    0
});
row("sin", t);
t = best5(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.cos(0.125 + (j % 997) * 0.01); j = j + 1; };
    sink = s;
    0
});
row("cos", t);
t = best5(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) { s = s + math.pow(1.0009, 0.5 + (j % 997) * 0.001); j = j + 1; };
    sink = s;
    0
});
row("pow", t);
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
    while (j < n) { s = s + math.tanh(0.125 + (j % 997) * 0.001); j = j + 1; };
    sink = s;
    0
});
row("tanh", t);
print(f"sink {sink:.6e}");