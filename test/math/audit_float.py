#!/usr/bin/env python3
"""Audit std/math.y's ROUNDING tier against exact arithmetic, over a spread.

WHAT THIS IS FOR

`ulp_table.txt` is the gate: 7572 cases, tolerance 1, every answer checked
against a checked-in bit pattern. That is a gate against REGRESSION -- against a
change moving an answer -- and it is exactly as good as the list.

This is the other question. A list is the arguments somebody thought of, and the
defects it missed were all in classes nobody thought of:

  - a rounding at the wrong SIZE rather than on the wrong line: fvariance's
    mean, ldexp's exponent field, fsum_kahan's compensation -- every one an
    intermediate leaving the range while the answer did not,
  - a behaviour decided by an accident of expression order: fsum's naive order,
    and the three-way `y > 0 / y < 0 / else` ladder that answers 0 for +0 in
    BOTH atan2 and atan2's own reference,
  - an answer differing only in its SIGN, which a table of magnitudes compares
    as equal,
  - a hole where the list is thin: a spread uniform in the DECADES found log2
    and log10 2 ulps out where their pinned cases had nothing to say,
  - a reference that was wrong, which reads as coverage.

So: sweep a spread uniform IN THE DECADES, and check every answer against an
exact reference.

Run it by hand, like sweep_edges.py and audit_exact.py:

    python3 test/math/audit_float.py                  # the default spread
    ARGS=200000 python3 test/math/audit_float.py      # a much wider one

It is not in `make test`: it needs a compiler and a Python, and a suite that
takes minutes is a suite people stop running. What it finds goes into a fixture.

THE REFERENCE, AND WHY IT IS NOT LIBM

    `Decimal.exp` and `Decimal.ln` are correctly rounded to the context
    precision, so at 60 digits they are exact for every purpose here and the one
    conversion to float at the end is the single rounding that decides the
    answer. libm cannot be that reference: it is 3 ulps out on cbrt on 1385 of
    3030 arguments, and its tanh is not within 1 ulp of the truth everywhere --
    comparing against it produced nine "failures" on arguments where the module
    was right and libm was not, on four of the nine.

    The precision FOLLOWS THE ARGUMENT. That is the tanh lesson, paid again: at a
    fixed 60 digits, ln(1 + 5e-324) rounds 1 + x to exactly 1 and answers 0,
    and exp(1e-15) - 1 cancels the same way. So the working precision is sized
    from the argument: enough digits that the leading cancellation cannot reach
    the last one, plus a margin.

WHAT IT DELIBERATELY DOES NOT COVER, AND WHY

    atan, asin, acos, tanh, sinh and cosh. They are the six whose exact
    references need a series of this file's own -- Decimal has exp, ln, log10,
    sqrt and the powers, and no atan -- and every one of those series was wrong
    when first written: pi by Machin came out as 3.22698 because the alternation
    was applied twice, and an atan's took a different form again. A reference
    that is wrong reports the MODULE as wrong, and it does so confidently; that
    has already happened six times in this table, so a seventh is not a risk
    worth taking for coverage the table and t303/t308/t319/t320 already provide.
    The lesson from `log(3)` and from pi is in this docstring and the fix is the
    same in both cases: derive the constant, then CHECK IT against libm before
    anything depends on it.

    Worth recording from the attempt: over 300 ordinary arguments, libm's own
    asin and acos are more than one ulp from the exact answer on two and one of
    them. So a reference for those two must be exact, not libm -- which is why
    the table's 60-digit tanh reference exists and why the same treatment would
    be needed here.

WHAT IT DOES NOT COVER, AND WHY

    Two-argument functions, and the assembly kernels. hypot, atan2 and the rest
    are covered by the table and by t325. `exp`, `log`, `sin`, `cos` and `pow`
    are ASSEMBLY in this compiler, and a Y-level reference for them would be a
    re-implementation rather than a check; they are pinned bit for bit against
    the Y loops they replaced (t311, t312, t313, t315), 10420 arguments each,
    which is a different and stronger claim than accuracy.

    sin, cos and tan are skipped for a declared reason rather than an accidental
    one: their argument reduction has no sharp limit, the quadrant stops fitting
    a long past 9.9999999999995904e18, and t320 measures the degradation. A
    harness that cried wolf there would be one people stopped reading.

WHAT IT FINDS, AND WHAT IT DOES NOT

    At the default spread (20000 arguments, seed 20260105) it reports:

        exp    0 over 1 ulp      log     0      log2    0
        expm1  0                 log10   379     log1p   1

    log10's 379 is the real gap and it is discussed where it belongs, in t322
    and in the manual: 2 ulps on 1.9% of decade-uniform arguments, because
    log10's two terms are of comparable size so ln(m)'s error is not diluted.
    log1p's single case is x = -0.0008820166623751244, where the z-series lands 2
    ulps out -- one argument in 20000, which is recorded as a limit rather than
    chased, and glibc is not better there either.

FIVE THINGS THIS FILE GOT WRONG FIRST

    audit_exact.py has the list for the exact tier. The two that apply here cost
    the most time, and both are about BITS:

    1. fbits returns a SIGNED long, and +inf's pattern (0x7FF0000000000000) is
       BELOW 2^63 -- so it prints as a positive number and -inf's prints as a
       small negative one. Reading that output as unsigned reports every
       negative answer as a catastrophe and every infinity as a large normal.
       Compare MASKED to unsigned.
    2. A ulp GAP is not abs(bits_a - bits_b). Across a sign change that
       subtraction is meaningless; across zero it counts every representable
       value on the way. `mono` below is the monotone key: exact at zero and
       across a sign change, which is what "how far apart are these two" means.
    3. My first reference for log multiplied the binary exponent by 2*ln(2)
       instead of ln(2) and answered 2.4849 for log(3), where the answer is
       1.0986 -- the exact arithmetic was fine and the ARITHMETIC around it was
       not. A reference is code, and code is wrong.
    4. The first two versions of the references were hand-rolled series, and
       three separate slips came out of them. `Decimal` does this correctly
       rounded and for free; the only judgement left is the precision, and that
       is one function with a comment.
    5. Not in this file -- in a probe written beside it -- but the same species,
       and it nearly became a committed "defect". A probe asserted
       `log10(1e-323) == -323` and got -323.0051853474518, a 9.1e10-ulp error
       by the monotone key, which reads exactly like the catastrophic findings
       this file exists to make. It is not one: **no negative power of ten below
       1 is a dyadic rational**, so `1e-323` is not 10^-323 but the nearest
       multiple of 2^-1074, which is 2^-1073, whose logarithm IS -323.00518.
       libm agrees with the module to the bit on every one of those arguments.
       A literal in the subnormal range is a nearby multiple of 2^-1074, and
       asserting a power of ten there is asserting something false. Only the
       NON-negative powers are exact, and those are worth asserting -- log10 of
       1, 10, 100, 1e10, 1e100, 1e300 is an exact integer and all six hold.
"""

import decimal
import math
import os
import random
import struct
import subprocess
import sys
import tempfile

YCC = os.environ.get("YCC", os.path.abspath("./ycc"))
NARGS = int(os.environ.get("ARGS", "20000"))
SEED = int(os.environ.get("SEED", "20260105"))
TOL = 1

U64 = (1 << 64) - 1
DBL_MAX = decimal.Decimal(1.7976931348623157e308)
LN2 = 0.0
LN10 = 0.0


def bits(x):
    return struct.unpack("<Q", struct.pack("<d", x))[0]


def val(b):
    return struct.unpack("<d", struct.pack("<Q", b & U64))[0]


def is_nan(b):
    b &= U64
    return (b & 0x7FF0000000000000) == 0x7FF0000000000000 and (b & 0x000FFFFFFFFFFFFF) != 0


def is_inf(b):
    return (b & U64) in (0x7FF0000000000000, 0xFFF0000000000000)


def mono(b):
    """The monotone key of a double's bits: exact, and order-preserving.

    Reading the pattern as a SIGNED integer puts -0.0 immediately below +0.0 and
    every negative double below every positive one, so two answers on opposite
    sides of zero differ by a subtraction of two huge numbers. Folding the sign
    bit to the top and complementing the rest when it is set maps the whole
    range onto one ascending line.
    """
    b &= U64
    return b if b < (1 << 63) else (~b & U64) + 1


def gap(got, want):
    """How many representable doubles lie strictly between two answers."""
    g, w = got & U64, want & U64
    if g == w:
        return 0
    # Two NaNs are the same answer whatever their payload, and the payloads WILL
    # differ: the module's NaN and this file's Decimal NaN are not the same bits.
    # Comparing them as bits reported 1020 "failures" that were all log(-1.0).
    if is_nan(g) and is_nan(w):
        return 0
    if is_nan(g) or is_nan(w) or is_inf(g) or is_inf(w):
        return float("inf")
    if (val(g) > 0) != (val(w) > 0):
        return float("inf")
    return abs(mono(g) - mono(w))


# ── the spread ──────────────────────────────────────────────────────────────


def spread(n):
    rng = random.Random(SEED)
    out = [0.0, -0.0, 1.0, -1.0, 5e-324, -5e-324, 1e-320,
           2.2250738585072014e-308, -2.2250738585072014e-308,
           1e-300, 1e-8, 1.0e8, 1e300, 1e15, 1e-15,
           1.7976931348623157e308, -1.7976931348623157e308,
           math.inf, -math.inf, math.nan]
    while len(out) < n:
        d = rng.randrange(-323, 309)
        v = rng.uniform(1.0, 10.0) * (10.0 ** d)
        if v != v or abs(v) == math.inf:
            continue
        out.append(v if rng.random() < 0.5 else -v)
    return out


# ── the references ──────────────────────────────────────────────────────────


def _to_float(d):
    """One rounding from an exact decimal to a double, with the range handled.

    A decimal context has its own exponent range, and exp(1e300) is 10^434297941
    -- comfortably inside decimal's and outside binary64's. Decimal raises
    Overflow where the answer is a plain infinity, so the range is settled here
    rather than left to raise: a reference that raises looks exactly like a
    harness bug, and this file has already produced four of those.
    """
    if d.is_nan():
        return math.nan
    if d > DBL_MAX:
        return math.inf
    if d < -DBL_MAX:
        return -math.inf
    return float(d)


def _ctx(d):
    return decimal.Context(prec=d, Emax=999999, Emin=-999999)


def ref_exp(x):
    if x != x:
        return math.nan
    if x > 709.8:
        return math.inf
    if x < -746.0:
        return 0.0
    # 60 digits is far past a double's 17, and exp's argument error is relative:
    # a relative error of 2^-53 in x becomes a relative error of the same size in
    # the answer, so there is nothing to chase past that.
    with decimal.localcontext(_ctx(60)):
        return _to_float(decimal.Decimal(x).exp())


def _cancel_digits(x):
    """How many extra digits `1 + x` needs so the leading cancellation cannot
    reach the last one.

    For |x| far below 1 the sum is 1 and every leading digit of x is lost, so the
    precision has to rise as x falls: 60 + (-log10|x|) leaves 60 digits after the
    cancellation. The cap keeps the context from asking for more digits than a
    double can express an answer to, and the floor at |x| >= 1 is the ordinary
    case where nothing is cancelled at all.
    """
    a = abs(x)
    if a == 0.0 or a >= 1.0 or a != a:
        return 60
    return min(60 + max(0, -int(math.log10(a))), 1400)


def ref_expm1(x):
    if x != x:
        return math.nan
    if x == 0.0:
        # expm1(-0.0) is -0.0 and expm1(+0.0) is +0.0 (C99 7.12.11.2), so the sign
        # of the argument carries into a zero answer. Decimal does not: 1 - 1 is
        # +0 whatever came in, and reading that as agreement turned two correct
        # answers into "9223372036854775808 ulp" failures. It is the same defect
        # class as fmin/fmax's zeros and atan2's -- an answer that differs only in
        # its sign, which a magnitude comparison calls identical.
        return x
    if x > 709.8:
        return math.inf
    if x < -746.0:
        return -1.0
    # exp(x) - 1 CANCELS: for |x| below 2^-53 the two are the same double and the
    # difference is exactly 0, while the answer is x. So the subtraction is done
    # in decimal at a precision set by how small x is, and the single rounding
    # to float happens after. This is the tanh table's lesson, in expm1's terms.
    with decimal.localcontext(_ctx(_cancel_digits(x))):
        return _to_float(decimal.Decimal(x).exp() - 1)


def ref_log(x):
    if x != x:
        return math.nan
    if x == 0.0:
        return -math.inf
    if x < 0.0:
        return math.nan
    if x == math.inf:
        return math.inf
    if x == 1.0:
        return 0.0
    # ln(x) for a subnormal is ~-744 and for the largest double ~+710: the
    # answer's own magnitude, not the argument's, sets the precision needed.
    with decimal.localcontext(_ctx(60)):
        return _to_float(decimal.Decimal(x).ln())


def ref_log1p(x):
    if x != x:
        return math.nan
    if x == -1.0:
        return -math.inf
    if x < -1.0:
        return math.nan
    if x == 0.0:
        return x          # log1p(-0.0) is -0.0, for expm1's reason
    # ln(1 + x) CANCELS the same way expm1 does: 1 + 5e-324 is 1 in binary64 and
    # the answer is 5e-324, not 0. So 1 + x is formed in decimal too.
    with decimal.localcontext(_ctx(_cancel_digits(x))):
        return _to_float((decimal.Decimal(1) + decimal.Decimal(x)).ln())


def ref_log2(x):
    r = ref_log(x)
    return math.nan if r != r else r / LN2


def ref_log10(x):
    r = ref_log(x)
    return math.nan if r != r else r / LN10


CHECKED = {
    "exp": ref_exp,
    "expm1": ref_expm1,
    "log": ref_log,
    "log1p": ref_log1p,
    "log2": ref_log2,
    "log10": ref_log10,
}

# Declared limits, skipped with a reason rather than by omission. A harness that
# cries wolf on a boundary somebody documented is one people stop reading.
SKIPPED = {
    "sin": "argument reduction has no sharp limit (t320)",
    "cos": "argument reduction has no sharp limit (t320)",
    "tan": "the quadrant stops fitting a long (t320); all three answer nan past it",
    "sinh": "past its own exponential, the obvious form answers inf (t319)",
    "cosh": "past its own exponential, the obvious form answers inf (t319)",
}


def y_source(xs):
    lits = []
    for x in xs:
        if x != x:
            lits.append("math.nan")
        elif x == math.inf:
            lits.append("math.inf")
        elif x == -math.inf:
            lits.append("0.0 - math.inf")
        elif x == 0.0:
            lits.append("0.0" if math.copysign(1.0, x) > 0 else "0.0 * (0.0 - 1.0)")
        else:
            lits.append(repr(x))
    lines = ["import math;", "let xs: [float] = [%s];" % ", ".join(lits),
             "let i = 0;", "while (i < len(xs)) {", "    let x = xs[i];",
             '    print("ARG " + tostring(math.fbits(x)));']
    for name in sorted(CHECKED):
        lines.append('    print("%s " + tostring(math.fbits(math.%s(x))));' % (name, name))
    lines += ["    i = i + 1", "};"]
    return "\n".join(lines) + "\n"


def main():
    global LN2, LN10
    with decimal.localcontext(_ctx(80)):
        LN2 = float(decimal.Decimal(2).ln())
        LN10 = float(decimal.Decimal(10).ln())
    # The two constants the divided references need must round to what libm
    # gives, or every log2 and log10 case fails by a rounding of THIS file. It is
    # checked once, loudly, because that failure looks exactly like a compiler
    # bug and would send someone to fix correct code.
    for name, got, want in (("ln(2)", LN2, math.log(2.0)), ("ln(10)", LN10, math.log(10.0))):
        if got != want:
            print("this harness's %s is %r where libm gives %r -- the REFERENCE "
                  "is wrong, not the module" % (name, got, want), file=sys.stderr)
            return 2

    xs = spread(NARGS)
    tmp = tempfile.mkdtemp(prefix="y-float-")
    src = os.path.join(tmp, "float.y")
    exe = os.path.join(tmp, "float")
    with open(src, "w") as fh:
        fh.write(y_source(xs))
    r = subprocess.run([YCC, "-o", exe, src], capture_output=True, text=True)
    if r.returncode != 0:
        print("cannot build the audit driver:\n%s" % r.stderr, file=sys.stderr)
        return 2
    r = subprocess.run([exe], capture_output=True, text=True)
    if r.returncode != 0:
        print("the audit driver died: %s" % r.stderr.strip(), file=sys.stderr)
        return 2
    lines = [l for l in r.stdout.split("\n") if l]
    per = len(CHECKED) + 1
    if len(lines) != len(xs) * per:
        print("the driver printed %d lines, expected %d -- the walk order and "
              "the driver disagree" % (len(lines), len(xs) * per), file=sys.stderr)
        return 2

    worst = {k: (0, None) for k in CHECKED}
    over = {k: [] for k in CHECKED}
    for j in range(len(xs)):
        rec = dict(p.split() for p in lines[j * per:(j + 1) * per])
        x = val(int(rec["ARG"]))
        for name in CHECKED:
            gb = int(rec[name]) & U64
            want = CHECKED[name](x)
            g = gap(gb, bits(want))
            if g > worst[name][0]:
                worst[name] = (g, (x, val(gb), want))
            if g > TOL:
                over[name].append(x)

    print("  %d arguments x %d functions, uniform in the decades, seed %d"
          % (len(xs), len(CHECKED), SEED))
    print("  %-8s %9s %11s" % ("function", "over %d" % TOL, "worst ulp"))
    bad = False
    for name in sorted(CHECKED):
        w = worst[name][0]
        print("  %-8s %9d %11s" % (name, len(over[name]), w))
        if over[name]:
            bad = True
    for name in sorted(SKIPPED):
        print("  %-8s %9s  skipped: %s" % (name, "-", SKIPPED[name]))
    if not bad:
        print("\n  NOTHING OVER %d ULP" % TOL)
        return 0
    print("\n  WORST PER FUNCTION, so a regression names itself:")
    for name in sorted(CHECKED):
        if over[name]:
            g, (x, got, want) = worst[name]
            print("    %-8s worst %s ulp at x=%r: got %r want %r  (%d cases over)"
                  % (name, g, x, got, want, len(over[name])))
    return 1


if __name__ == "__main__":
    sys.exit(main())
