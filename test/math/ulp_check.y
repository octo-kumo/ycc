// The ulp harness: every case in test/math/ulp_table.txt, evaluated and
// measured against the reference value the table carries.
//
// The table is the reference: one line per case, the function's name, its
// argument(s) and the correctly-rounded answer, all as IEEE-754 bit patterns
// in decimal (tolong reads decimal, so the table reads in what the program can
// read). Every answer is the correctly rounded one: `ytest math-table` checks
// each row against mref.y's 320-bit references (the platform libm, which wrote
// the first version, was 1 ulp off the truth on 63 rows and certified a sign
// defect in trunc, ceil and round on 126 more).
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
    // The five below had NO cases at all until the table grew to carry them,
    // and fmin/fmax are why that mattered: their zeros' signs were decided by
    // whichever operand came last, so fmax(0.0, -0.0) answered -0.0 and
    // 1.0/fmax(0.0, -0.0) came out -inf. C99 allows either sign from fmin and
    // fmax on a +-0 pair; IEEE 754-2019's minNum/maxNum does not, and neither
    // does this platform's libm, which is the reference this table is written
    // against. The pinned cases are the four orderings.
    else if (name == "is_nan") { if (math.is_nan(x)) { 1.0 } else { 0.0 } }
    else if (name == "is_inf") { if (math.is_inf(x)) { 1.0 } else { 0.0 } }
    else if (name == "is_finite") { if (math.is_finite(x)) { 1.0 } else { 0.0 } }
    else if (name == "fabs") { math.fabs(x) }
    else if (name == "fsign") { math.fsign(x) }
    else { math.nan }
};

def apply2(name: str, x: float, y: float) -> float {
    if (name == "hypot") { math.hypot(x, y) }
    else if (name == "nextafter") { math.nextafter(x, y) }
    else if (name == "pow") { math.pow(x, y) }
    else if (name == "atan2") { math.atan2(x, y) }
    else if (name == "fmin") { math.fmin(x, y) }
    else if (name == "fmax") { math.fmax(x, y) }
    else { math.nan }
};

// lerp is the one function here with three arguments, so it gets its own
// dispatcher rather than a third slot in apply2 -- the table's lines are
// positional and a four-argument apply would have made every reader wonder
// which of the two middle fields is the weight.
def apply3(name: str, x: float, y: float, t: float) -> float {
    if (name == "lerp") { math.lerp(x, y, t) }
    else { math.nan }
};

def is_three_arg(name: str) -> bool {
    name == "lerp"
};

def is_two_arg(name: str) -> bool {
    name == "hypot" || name == "nextafter" || name == "pow" || name == "atan2"
        || name == "fmin" || name == "fmax"
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
//   * and the table had nine of this module's functions missing from it entirely
//     -- fmin, fmax, fabs, fsign, lerp and the three predicates, because it only
//     ever carried the functions with rounding in them. fmin and fmax were the
//     ones that mattered: the tie between the two zeros went to whichever
//     operand came LAST, so fmax(0.0, -0.0) answered -0.0 and
//     1.0/fmax(0.0, -0.0) came out -inf. C99 allows either sign there; minNum
//     and maxNum, this platform's libm, and any caller dividing by the answer do
//     not. The tie now goes by sign, and all four orderings are pinned.
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
            let a = math.bitsf(f[1].tolong()!);
            let want: long = 0;
            let got: float = math.nan;
            // Every argument, spelled, because a failure you cannot LOCATE is a
            // failure you cannot act on. This line printed only f[1] -- the first
            // argument -- so for a two-argument function the report named half
            // the case and the other half had to be found by guessing which line
            // of an 8340-line table it was. It cost an hour: three atan2 cases
            // and a hypot one were reported with one argument each, and every
            // reconstruction from that half turned out to be a case that passed.
            let args = f[1];
            if (is_three_arg(name)) {
                let b = math.bitsf(f[2].tolong()!);
                let t = math.bitsf(f[3].tolong()!);
                args = args + " " + f[2] + " " + f[3];
                want = f[4].tolong()!;
                got = apply3(name, a, b, t);
            } else if (is_two_arg(name)) {
                let b = math.bitsf(f[2].tolong()!);
                args = args + " " + f[2];
                want = f[3].tolong()!;
                got = apply2(name, a, b);
            } else {
                want = f[2].tolong()!;
                got = apply1(name, a);
            };
            let gap = two_nan_ok(got, want);
            n = n + 1;
            if (gap > worst) { worst = gap; worst_name = name; };
            if (gap > 1) { over_one = over_one + 1; };
            if (gap > tolerance) {
                bad = bad + 1;
                print("OVER " + tostring(tolerance) + " ULP: " + name
                    + " args=" + args
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

// exit(main()), NOT main(). This file ended in a bare `main();` -- a statement
// whose value is DISCARDED -- so the 1 that `bad > 0` produced went nowhere and
// _start fell through to its hardcoded exit_group(0). The gate could not fail.
//
// That is worth being precise about, because everything upstream believed the
// opposite: this file's own header says "a kernel that drifts past it fails
// here", src/tools/ytest/su_math.y reads the exit code and decides PASS or FAIL from it, and
// the number it printed -- "0 over 1", the promise this whole module is held to
// -- was a number the harness counted correctly and then threw away. Adding 768
// cases to the table is what exposed it: the summary line said 4 over 1 and the
// suite still said PASS, and those two facts cannot both be true.
//
// main() -> long exists precisely so the answer can become the exit code. Calling
// it and dropping the answer is the one spelling that cannot work.
exit(main());
