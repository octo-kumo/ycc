// The [float] bulk kernels in nanoseconds an element -- the P5 gate.
//
// Every row walks the same 2M-element array, in the same order, so the rows
// differ only in what they do per element. The Y loops are here too (`fsum_y`
// and friends, which std/math.y keeps as the oracle for test/y/native/
// t310_math_bulk.y), which is what makes this a measurement of the assembly and
// not of the machine: `fsum (asm)` against `fsum (y)` is the whole of the
// change, over the same bytes in the same order, and the two agree bit for bit.
//
// The last row is the number the plan quotes: a plain Y element walk,
// `s = s + a[j]` with a bounds check and an index add, measured at 1.27 ns an
// element on this box. That is the baseline every kernel here is against.
//
// fsum is at the hardware's limit, and it is worth knowing which limit: an
// addsd into one accumulator is a four-cycle dependency on most x86 and two on
// Golden Cove, so a plain sum cannot go faster than one element per addsd
// latency however few instructions it takes. At this box's clock that is
// ~0.44 ns, which is what the row reads. Going under it needs more than one
// accumulator, which changes the order of the additions and so the answer --
// that is `fsum_kahan`'s job, in Y, where it belongs. What the assembly buys is
// everything else: the bounds check, the index add, the compare and the branch
// that the Y loop spends between the adds, which is the whole of the gap
// between 1.26 and 0.44.
import math;

let n: long = 2000000;
let a: [float] = [];
let b: [float] = [];
let y: [float] = [];
let i = 0;
let v = 0.5;
while (i < n) {
    // The golden ratio's recurrence: the cheapest spread there is that does not
    // need a long-to-float cast (Y has the float-to-long one, not its inverse).
    v = (v + 1.0) * 0.6180339887498949;
    v = v - math.floor(v);
    a += v * 1000.0 - 500.0;
    b += 500.0 - v;
    y += 0.0;
    i = i + 1;
};

// Best of three passes, in microseconds. The sink is printed inside the timed
// closure so nothing can be hoisted out of it, and printing costs the same in
// every row.
def best3(f: () -> long) -> long {
    let b = 1000000000;
    let r = 0;
    while (r < 3) {
        let t = clock_us();
        f();
        let d = clock_us() - t;
        if (d < b) { b = d; };
        r = r + 1;
    };
    b
};

def row(name: str, us: long) -> void {
    print(f"{name:<14}: {us * 1000.0 / (len(a) * 1.0):6.3f} ns/element");
};

let t = best3(def () -> long { print(f"{math.fsum(a):.1e}"); 0 });
row("fsum (asm)", t);
t = best3(def () -> long { print(f"{math.fsum_y(a):.1e}"); 0 });
row("fsum (y)", t);
t = best3(def () -> long { print(f"{math.fdot(a, b):.1e}"); 0 });
row("fdot (asm)", t);
t = best3(def () -> long { print(f"{math.fdot_y(a, b):.1e}"); 0 });
row("fdot (y)", t);
t = best3(def () -> long { print(f"{math.fmin_of(a):.1e}"); 0 });
row("fmin_of", t);
t = best3(def () -> long { print(f"{math.fmax_of(a):.1e}"); 0 });
row("fmax_of", t);
t = best3(def () -> long { math.fscale(a, 1.0000001); 0 });
row("fscale", t);
t = best3(def () -> long { math.faxpy(y, 0.5, b); 0 });
row("faxpy", t);
// The baseline: a plain Y element walk, one load, a multiply and an add, with
// the language's own bounds check and index arithmetic.
t = best3(def () -> long {
    let s = 0.0;
    let j = 0;
    while (j < n) {
        s = s + a[j] * 1.0;
        j = j + 1;
    };
    print(f"{s:.1e}");
    0
});
row("y loop", t);