// The ulp harness: every case in test/math/ulp_table.txt, evaluated and
// measured against the reference value the table carries.
//
// The table is the reference: one line per case, the function's name, its
// argument(s) and the correctly-rounded answer, all as IEEE-754 bit patterns
// in decimal (tonum reads decimal, so the table reads in what the program can
// read). test/math/gen_ulp_table.py wrote it, from the platform libm.
//
// The measurement is the gap in ulps between what std/math.y returned and what
// the table says, counted through the standard monotone key of a double's bits
// -- so it is exact at zero, across a sign change, and for a subnormal, and it
// counts a NaN as infinitely far away (which is what it should be).
import fs;
import math;

// A double's bits in an order where +0.0 < -0.0 < the smallest subnormal, by
// flipping every pattern with the sign bit set. Long arithmetic wraps, which
// is what makes one comparison work for the whole range.
def key(x: float) -> long {
    let b = math.fbits(x);
    if (b < 0) { 0 - 1 - b } else { b }
};

// How many doubles separate a and b: 0 for equal, 1 for a neighbour.
// The gap between what came back and what the table says, in ulps -- with one
// exception: two NaNs are the same answer however their signs differ, and a
// sign bit is not an ulp. Any other NaN is infinitely far, which is what the
// key ordering says on its own.
def two_nan_ok(got: float, want: long) -> long {
    let w = math.bitsf(want);
    if (math.is_nan(got) && math.is_nan(w)) { 0 } else { ulp_gap(got, w) }
};

def ulp_gap(a: float, b: float) -> long {
    let ka = key(a);
    let kb = key(b);
    if (ka > kb) { ka - kb } else { kb - ka }
};

// One case, dispatched by name. The two-argument group is separate because Y
// has no tuples and a one-armed call would have to invent an argument.
// frexp's answer is a pair, which one ulp gap cannot hold, so it is checked the
// other way round: the pair is put back together and the identity
// ldexp(bitsf(fraction), exponent) == x is what the table asserts -- frexp has
// no rounding in it anywhere, so the identity either holds exactly or the
// answer is NaN, which is how a failure shows.
def frexp_pair(x: float) -> float {
    let p = math.frexp(x);
    if (p[1] == 0 && math.bitsf(p[0]) == 0.0) {
        x
    } else if (math.ldexp(math.bitsf(p[0]), p[1]) == x) {
        x
    } else {
        math.nan
    }
};

def apply1(name: str, x: float) -> float {
    if (name == "sqrt") { math.sqrt(x) }
    else if (name == "floor") { math.floor(x) }
    else if (name == "ceil") { math.ceil(x) }
    else if (name == "trunc") { math.trunc(x) }
    else if (name == "round") { math.round(x) }
    else if (name == "fract") { math.fract(x) }
    else if (name == "cbrt") { math.cbrt(x) }
    // to_int answers a long, so the table's bits are compared through the
    // float that carries them
    else if (name == "to_int") { math.bitsf(math.to_int(x)) }
    else if (name == "frexp") { frexp_pair(x) }
    else if (name == "exp") { math.exp(x) }
    else if (name == "exp2") { math.exp2(x) }
    else if (name == "log") { math.log(x) }
    else if (name == "log2") { math.log2(x) }
    else if (name == "log10") { math.log10(x) }
    else if (name == "sin") { math.sin(x) }
    else if (name == "cos") { math.cos(x) }
    else if (name == "tan") { math.tan(x) }
    else if (name == "atan") { math.atan(x) }
    else if (name == "expm1") { math.expm1(x) }
    else if (name == "log1p") { math.log1p(x) }
    else if (name == "sinh") { math.sinh(x) }
    else if (name == "cosh") { math.cosh(x) }
    else if (name == "tanh") { math.tanh(x) }
    else if (name == "asin") { math.asin(x) }
    else if (name == "acos") { math.acos(x) }
    // a predicate, so the answer is a float carrying 1.0 or 0.0
    else if (name == "is_signed_zero") { if (math.is_signed_zero(x)) { 1.0 } else { 0.0 } }
    else { math.nan }
};

def apply2(name: str, x: float, y: float) -> float {
    if (name == "hypot") { math.hypot(x, y) }
    else if (name == "nextafter") { math.nextafter(x, y) }
    else if (name == "pow") { math.pow(x, y) }
    else if (name == "atan2") { math.atan2(x, y) }
    else { math.nan }
};

def is_two_arg(name: str) -> bool {
    name == "hypot" || name == "nextafter" || name == "pow" || name == "atan2"
};

// The tolerance. One.
//
// It was three, over four cases, and the harness's own header claimed one while
// the code enforced three -- which is the worst kind of test: a comment that
// says something the code does not check. All four are closed now, and what
// closed them is the same lesson each time: the question is never WHICH line
// rounds, it is AT WHAT SIZE.
//
//   * cosh summed two exponentials. For a >= 0.5, e^-a is 1.2% of the answer,
//     so its own rounding is a hundredth of an ulp, while a second exp() call
//     brings a whole kernel's error along and exp is a ulp out at some
//     arguments. One exponential and its reciprocal is enough.
//
//   * pow's logarithm formed z*(2.0 + w*P), whose brackets round AT THE SIZE OF
//     2.0 -- a whole ulp of the logarithm, which pow then multiplies by the
//     exponent. Written as a two_sum of 2*z and (z*w)*P it is 2.3 times more
//     accurate, and both pow cases went with it.
//
//   * acos was `pi/2 - asin(x)`, and near x = 1 that answer is 3e-8 against a
//     pi/2 -- eight digits cancel before the answer exists, and
//     acos(1 - 4e-17) was FORTY ulps out. Its large half now takes the
//     half-angle quantity asin's kernel already computes, which is also FASTER
//     (77.3 ns/call against 93.3, and 1255 Ir against 1975) because it skips
//     asin's sign handling and the subtraction.
//
//   * asin used to reach atan, whose own ulp lands inside the answer whole, and
//     then needed `two = 2*asin(s)` to be a double before the pi/2 subtraction,
//     whose half-ulp is a whole ulp of the answer. Its own 24-term kernel on the
//     Taylor values C(2k,k)/(4^k(2k+1)) -- what sinh_k is too -- plus the
//     square root's own residual put back, plus `two` carried in two parts
//     THROUGH the subtraction, brings it inside. An earlier version of that
//     measurement said it could not be done, and it could: the low part had
//     been added after the 2-sum instead of folded into a compensated
//     three-term subtraction.
//
// One is the number C promises and the number the manual quotes, so one is what
// the gate is: a kernel that drifts past it fails here, and the printed worst
// gap says by how much and from which function.
let tolerance: long = 1;

def main() -> long {
    let path = "";
    let a = argv();
    if (len(a) > 1) { path = a[1]; };
    let text = fs.read_file(path)!;
    let lines = text.split("\n");
    let worst: long = 0;
    let worst_name = "";
    let over_one: long = 0;
    let bad: long = 0;
    let n: long = 0;
    let i = 0;
    while (i < len(lines)) {
        let raw = lines[i];
        i = i + 1;
        let line = raw.trim();
        // a blank line and a comment are not cases
        if (line.length == 0 || line.byte_at(0) == 35) { } else {
            let f = line.split(" ");
            let name = f[0];
            // a one-argument line is `name arg want`, a two-argument one
            // `name arg1 arg2 want`
            let a = math.bitsf(f[1].tonum());
            let want: long = 0;
            let got: float = math.nan;
            if (is_two_arg(name)) {
                let b = math.bitsf(f[2].tonum());
                want = f[3].tonum();
                got = apply2(name, a, b);
            } else {
                want = f[2].tonum();
                got = apply1(name, a);
            };
            let gap = two_nan_ok(got, want);
            n = n + 1;
            if (gap > worst) { worst = gap; worst_name = name; };
            if (gap > 1) { over_one = over_one + 1; };
            if (gap > tolerance) {
                bad = bad + 1;
                print("OVER " + tostring(tolerance) + " ULP: " + name + " arg=" + f[1]
                    + " gap=" + tostring(gap) + " got=" + tostring(math.fbits(got))
                    + " want=" + tostring(want));
            }
        }
    };
    print("ulp: " + tostring(n) + " cases, worst gap " + tostring(worst) + " ulp ("
        + worst_name + "), " + tostring(over_one) + " over 1, "
        + tostring(bad) + " over " + tostring(tolerance));
    if (bad > 0) { 1 } else { 0 }
};

main();
