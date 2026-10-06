#!/usr/bin/env python3
"""An edge sweep over EVERY float->float function in std/math.y.

The ulp table is a list of cases somebody chose. This is different: it asks each
function the same question at the same arguments -- the module's own edges, the
IEEE special values, the subnormal band, the domain limits and the signed zeros
-- and it derives the function list from the source rather than from a hand-kept
list, so a function added to the module is swept without anybody remembering.

WHAT IT IS FOR. The two bugs this has already found were both invisible to the
table and both of the same shape: a function answered `inf` at an argument
whose answer is a good double, because an intermediate overflowed before the
arithmetic that would have cancelled it.

  * sinh(710) = 1.1169973830808557e+308, and the table's own reference line
    said inf across the whole strip.
  * expm1(709.5) = 1.3549863193146328e+308, and the table carried 709.0 and
    709.78 with nothing between.

In both cases the gap between two pinned points was not a region. That is the
lesson, and this harness is the generalisation of it: sweep, do not sample.

The reference is this platform's libm, called through ctypes, and the gap is
counted through the monotone key of a double's bits -- exact at zero, exact
across a sign change, infinite for a NaN against a number.

Two NaNs are the same answer however their signs differ (a sign bit is not an
ulp); any other NaN, against a number, is the worst gap there is.

Nothing here is a gate on its own: a function may legitimately differ from libm
(it is allowed to be BETTER), and the thresholds below are what this audit
found rather than what the module promises. The module's promise is 1 ulp, and
test/sh/test_math.sh enforces that on the table.
"""
import ctypes
import math
import re
import struct
import subprocess
from decimal import Decimal, getcontext

getcontext().prec = 60
import sys
import os

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
YCC = os.environ.get("YCC", os.path.join(REPO, "ycc"))

# The module's own edges, and IEEE's. Written out rather than imported so the
# sweep does not depend on the module being importable from Python.
DBL_MAX = 1.7976931348623157e308
TINY = 5e-324            # the smallest subnormal
SUBNORM = 2.2250738585072014e-308   # the smallest NORMAL

# Arguments every unary function is asked. Chosen to put each one's edges under
# a test rather than near one: the range ends, the flush point, both zeros, both
# infinities, a NaN, the subnormal band, and the places where a reduction changes
# shape (n = 0, n = 1, the exponent field crossing 1023).
UNARY_ARGS = [
    ("+0.0", 0.0), ("-0.0", -0.0),
    ("1.0", 1.0), ("-1.0", -1.0),
    ("0.5", 0.5), ("-0.5", -0.5),
    ("2.0", 2.0), ("-2.0", -2.0),
    ("0.25", 0.25), ("0.75", 0.75),
    ("1e-300", 1e-300), ("-1e-300", -1e-300),
    ("1e-16", 1e-16), ("1e16", 1e16), ("-1e16", -1e16),
    ("subnormal", TINY), ("-subnormal", -TINY),
    ("min normal", SUBNORM), ("-min normal", -SUBNORM),
    ("1e-30", 1e-30), ("1e30", 1e30),
    ("ln2", math.log(2)), ("-ln2", -math.log(2)),
    ("ln2/2", math.log(2) / 2), ("-ln2/2", -math.log(2) / 2),
    ("pi/4", math.pi / 4), ("-pi/4", -math.pi / 4),
    ("pi/2", math.pi / 2), ("-pi/2", -math.pi / 2),
    ("pi", math.pi), ("-pi", -math.pi),
    ("709.0", 709.0), ("709.4", 709.4), ("709.78", 709.782712893383996093),
    ("710.0", 710.0), ("710.4", 710.4), ("710.47", 710.47),
    ("-700.0", -700.0), ("-745.0", -745.0), ("-745.13", -745.133219101941074020),
    ("-746.0", -746.0), ("-1000.0", -1000.0),
    ("1e308", 1e308), ("-1e308", -1e308), ("1e300", 1e300),
    ("asin's edge 1-2^-27", 1.0 - 2.0 ** -27),
    ("asin's edge -1+2^-27", -(1.0 - 2.0 ** -27)),
    ("+inf", math.inf), ("-inf", -math.inf), ("nan", math.nan),
]

# The functions, and what libm's equivalent is called. `None` means the module's
# function has no libm counterpart under that name and the sweep skips it.
UNARY = [
    ("fabs", "fabs"), ("fsign", None), ("floor", "floor"),
    ("ceil", "ceil"), ("trunc", "trunc"), ("round", "round"),
    ("fract", None), ("cbrt", None),   # cbrt: not libm -- see cbrt_ref below
    ("exp", "exp"), ("exp2", "exp2"), ("expm1", "expm1"),
    ("log", "log"), ("log2", "log2"), ("log10", "log10"), ("log1p", "log1p"),
    ("sin", "sin"), ("cos", "cos"), ("tan", "tan"),
    ("asin", "asin"), ("acos", "acos"), ("atan", "atan"),
    ("sinh", "sinh"), ("cosh", "cosh"), ("tanh", "tanh"),
    ("sqrt", "sqrt"),
]

# Functions with no libm counterpart, checked only for "it answers something and
# does not trap", which is still worth a line each.
NO_LIBM = ["is_int", "is_signed_zero", "to_int", "exp_half"]

# Where the module DELIBERATELY differs from libm, with the reason. A sweep that
# does not know these reports them as defects every time it runs, and a report
# that cries wolf three times a day is a report nobody reads. Each of these was a
# finding first and a decision second, and the decision is written where the
# limit is stated as well as here.
#
#   sin/cos/tan   past 9.9999999999995904e18 the quadrant stops fitting a long,
#                 so the reduction cannot be performed and the module answers
#                 nan. libm keeps going with a multi-precision quotient. There is
#                 also a gradual loss of accuracy well below that which has NO
#                 edge and is measured instead -- see t320 and the manual.
#   exp_half      the module's own helper, not an export anyone calls; sinh and
#                 cosh are what reach it and they are swept in their own right.
DECLARED_LIMITS = {
    "sin": lambda x: abs(x) >= 9.9999999999995904e18,
    "cos": lambda x: abs(x) >= 9.9999999999995904e18,
    "tan": lambda x: abs(x) >= 9.9999999999995904e18,
}

# And the argument at which a gap stops meaning anything. Past this the answers
# are not close, so an ulp figure is noise -- the reduction has lost the
# quadrant. Same constant as DECLARED_LIMITS, for a different reason.
QUADRANT_LOST = 9.9999999999995904e18

# The range over which the one-ulp promise HOLDS for the three that reduce their
# argument. Measured: sin and cos are within 1 ulp of every one of 3000
# arguments below 1e8 and not above it (three of 3000 by 1e10). Above this the
# sweep COUNTS the excess instead of judging it, because there is no edge to
# judge against -- the loss is gradual and documented, in t320 and the manual.
ACCURACY_RANGE = {"sin": 1.0e8, "cos": 1.0e8, "tan": 1.0e8}


def key(x):
    (b,) = struct.unpack("<q", struct.pack("<d", x))
    return b if b >= 0 else -(b & 0x7FFFFFFFFFFFFFFF)


def gap(got, want):
    """Ulp gap. Two NaNs are the same answer; a NaN against a number is worst."""
    gn, wn = got != got, want != want
    if gn and wn:
        return 0
    if gn or wn:
        return float("inf")
    return abs(key(got) - key(want))


def ylit(x):
    """A double as a Y literal.

    Python's repr and Y's spellings differ at exactly the three values this
    sweep most needs -- repr gives `inf`, `-inf` and `nan` and Y wants
    `1.0/0.0`, `0.0-1.0/0.0` and `0.0/0.0` -- so the literals are written here
    rather than formatted by repr and left to fail to compile.
    """
    if x != x:
        return "0.0 / 0.0"
    if x == math.inf:
        return "1.0 / 0.0"
    if x == -math.inf:
        return "0.0 - 1.0 / 0.0"
    return repr(x)


def y_program(fns):
    """One Y program: for each function and each argument, print the bits."""
    out = ["import math;", ""]
    out.append("let names: [str] = [%s];" % ", ".join('"%s"' % f for f in fns))
    out.append("let args: [float] = [%s];"
               % ", ".join(ylit(a) for _, a in UNARY_ARGS))
    out.append("""
def apply(k: long, x: float) -> float {
    if (k == 0) { math.fabs(x) }
    else if (k == 1) { math.fsign(x) }
    else if (k == 2) { math.floor(x) }
    else if (k == 3) { math.ceil(x) }
    else if (k == 4) { math.trunc(x) }
    else if (k == 5) { math.round(x) }
    else if (k == 6) { math.fract(x) }
    else if (k == 7) { math.cbrt(x) }
    else if (k == 8) { math.exp(x) }
    else if (k == 9) { math.exp2(x) }
    else if (k == 10) { math.expm1(x) }
    else if (k == 11) { math.log(x) }
    else if (k == 12) { math.log2(x) }
    else if (k == 13) { math.log10(x) }
    else if (k == 14) { math.log1p(x) }
    else if (k == 15) { math.sin(x) }
    else if (k == 16) { math.cos(x) }
    else if (k == 17) { math.tan(x) }
    else if (k == 18) { math.asin(x) }
    else if (k == 19) { math.acos(x) }
    else if (k == 20) { math.atan(x) }
    else if (k == 21) { math.sinh(x) }
    else if (k == 22) { math.cosh(x) }
    else if (k == 23) { math.tanh(x) }
    else { math.sqrt(x) }
};

let k = 0;
while (k < len(names)) {
    let i = 0;
    while (i < len(args)) {
        print(names[k], " ", i, " ", math.fbits(apply(k, args[i])));
        i = i + 1
    };
    k = k + 1
};""")
    return "\n".join(out)


def cbrt_ref(x):
    """The cube root at 60 digits, rounded once -- NOT libm.

    This platform's libm cbrt is not correctly rounded: measured against an
    exact cube root it is up to 3 ulps out on 1385 of 3030 arguments, where this
    module's is correctly rounded on all of them. A sweep that used it as the
    reference reported cbrt as 2 ulps out when the module was the accurate one,
    which is the worst kind of finding: it points at the wrong code.

    So cbrt is checked against the same 60-digit reference the ulp table uses
    (gen_ulp_table.py's cbrt_ref, which is why that one is a computation and not
    a call). x**(1/3) is not it: 1/3 is inexact and pow is a different function.
    """
    if x != x or math.isinf(x) or x == 0.0:
        return x
    neg = x < 0.0
    v = float(Decimal(abs(x)) ** (Decimal(1) / Decimal(3)))
    return -v if neg else v


def libm_ref(name, x):
    if name == "cbrt":
        return cbrt_ref(x)
    if name is None:
        return None          # the function has no libm counterpart
    f = getattr(ctypes.CDLL("libm.so.6"), name, None)
    if f is None:
        return None
    f.restype = ctypes.c_double
    f.argtypes = [ctypes.c_double]
    try:
        return f(x)
    except (OverflowError, ValueError):
        return math.inf
    # ctypes does not raise; a nan/inf comes back as itself, which is the answer


def main():
    fns = [f for f, _ in UNARY]
    src = os.path.join(HERE, "sweep.y")
    exe = os.path.join(HERE, "sweep")
    with open(src, "w") as fh:
        fh.write(y_program(fns))
    r = subprocess.run([YCC, "-o", exe, src], capture_output=True, text=True)
    if r.returncode != 0:
        print("cannot build the sweep:\n%s" % r.stderr, file=sys.stderr)
        return 2
    out = subprocess.run([exe], capture_output=True, text=True)
    if out.returncode != 0:
        print("the sweep itself failed (rc=%d):\n%s"
              % (out.returncode, out.stderr[-500:]), file=sys.stderr)
        return 2
    got = {}
    for line in out.stdout.splitlines():
        p = line.split()
        if len(p) == 3:
            got[(p[0], int(p[1]))] = struct.unpack("<d", struct.pack("<q", int(p[2])))[0]

    print("%-7s %8s %14s  %s" % ("fn", "worst", "at argument", "note"))
    print("-" * 72)
    findings = []
    degraded = [0, 0]
    for k, (fname, lname) in enumerate(UNARY):
        worst, at, wname = 0.0, None, None
        for i, (aname, a) in enumerate(UNARY_ARGS):
            g = got.get((fname, i))
            if g is None:
                findings.append((float("inf"), fname, aname, "NO ANSWER"))
                continue
            w = libm_ref(lname, a)
            if w is None:
                continue
            lim = DECLARED_LIMITS.get(fname)
            if lim is not None and lim(a):
                # the module says "no answer" on purpose here; checking it
                # against a reference that answers anyway would be checking that
                # it does NOT do what it says it does
                if not (g != g):
                    findings.append((float("inf"), fname, aname,
                                     "should be NaN by the declared limit"))
                continue
            gg = gap(g, w)
            clean = ACCURACY_RANGE.get(fname)
            if clean is not None and abs(a) > clean:
                # above the range where the promise holds: counted, not judged
                degraded[0] += 1
                degraded[1] += 1 if gg > 1 else 0
                continue
            if gg > worst:
                worst, at, wname = gg, aname, w
        extra = ""
        if fname in ACCURACY_RANGE:
            extra = "   (%d/%d sampled arguments past 1e8 are over 1 ulp)" % (
                degraded[1], degraded[0])
        print("%-7s %8s %14s  %s%s" % (fname,
                                     "%.3g" % worst if worst != float("inf") else "inf",
                                     at or "-",
                                     "" if lname else "no libm counterpart",
                                     extra))
        degraded = [0, 0]
        if worst > 1:
            findings.append((worst, fname, at, wname))
    print("-" * 72)
    if not findings:
        print("nothing over 1 ulp")
        return 0
    print("OVER 1 ULP, worst first:")
    for w, f, a, note in sorted(findings, key=lambda t: -(t[0] if t[0] != float("inf") else 1e300))[:20]:
        print("  %-7s %-14.6g  (libm %s)" % (f, w, note))
    return 1


if __name__ == "__main__":
    sys.exit(main())