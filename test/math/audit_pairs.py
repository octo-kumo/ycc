#!/usr/bin/env python3
"""Two-argument Y-level math functions against a Decimal reference.

WHY THIS EXISTS, and it is a sentence that was wrong until recently.

audit_float.py carries a 20000-argument decade-uniform sweep for the ONE-argument
rounding functions, and its header said of the rest:

    Two-argument functions, and the assembly kernels. hypot, atan2 and the rest
    are covered by the table and by t325.

That was load-bearing and wrong. hypot had FOURTEEN cases in the table and t325
pinned one corner (hypot(inf, nan)). Fourteen cases cannot gate a function whose
whole difficulty is the ratio between its two arguments, and they had not: hypot
was 2 ulps from this platform's libm on 0.75% of the pairs with |s/m| between
1e-8 and 1e-1 -- a band fourteen pinned arguments have no reason to land in. The
same sentence covered atan2, which had 35 cases and was dropping the sign of y at
an infinite x.

So this is the same sweep audit_float.py runs, at the same scale, for the
functions it left out -- and the omission had a cause worth naming. A sweep needs
a reference, a one-argument reference is Decimal.exp and Decimal.ln, and
Decimal has no atan2. Writing one is work, and an unwritten reference reads the
same as a written one in a header.

THE REFERENCES, and how each was validated. A Decimal reference that is wrong is
worse than none: it turns correct code into a failing case and points at the
code. So each is checked against this platform's libm on every case in
ulp_table.txt -- 1055 two-argument cases spanning the pinned edges and the
seeded spreads -- and a disagreement is reported as what it is, a bug in THIS
file. That check is the argument that the sweep below means something, and it runs
on every invocation rather than once.

  hypot   sqrt(x^2 + y^2) in Decimal. No cancellation, so the answer's own
          17 digits are all that is needed and 60 is generous. The exponent range
          is decimal's, not binary64's: x^2 for x near 1.8e308 is 3e616, which no
          double holds and Decimal does, so nothing here needs the scaling the
          module has to do.
  atan2   Decimal has .atan() and no .atan2(), so the quadrant is applied here:
          atan(y/x) plus or minus pi by the signs. The ratio is formed in
          Decimal, so y/x never overflows or flushes the way it would in a
          double -- which is the whole reason to do it this way and not by
          calling libm.

Wall clock is not used to judge any of this: the numbers are instruction counts
or exact bit comparisons, and the tolerance is one ulp.

    python3 test/math/audit_pairs.py [n] [seed]
"""
import decimal
import math
import os
import random
import struct
import subprocess
import sys
import tempfile
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
# Two levels up: test/math -> test -> the tree root. One level lands in test/,
# where there is no ycc, and the failure is a FileNotFoundError from
# posix_spawn that says nothing about which path was wrong.
ROOT = os.path.dirname(os.path.dirname(HERE))
YCC = os.environ.get("YCC", os.path.join(ROOT, "ycc"))
TABLE = os.path.join(HERE, "ulp_table.txt")
NARGS = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
SEED = int(sys.argv[2]) if len(sys.argv) > 2 else 20261006
TOL = 1
U64 = (1 << 64) - 1
DBL_MAX = 1.7976931348623157e308

decimal.getcontext().Emax = 999999
decimal.getcontext().Emin = -999999
PI = decimal.Decimal("3.14159265358979323846264338327950288419716939937510582097494459")


def bits(x):
    (b,) = struct.unpack("<Q", struct.pack("<d", x))
    return b


def val(b):
    """A bit pattern as the double it names.

    The mask matters: the table writes -0.0 as the DECIMAL -9223372036854775808,
    which is a legal int64 but not a legal 64-bit PATTERN for struct's "q" on the
    way in -- "<q" wants a signed value in range, and masking first is what turns
    the printed decimal back into the bits it stands for.
    """
    return struct.unpack("<d", struct.pack("<Q", b & U64))[0]


def key(x):
    """The monotone key, IDENTICAL to test/math/ulp_check.y's.

    That file computes it as `if b < 0 { 0 - 1 - b } else { b }` on the SIGNED bit
    pattern. The `- 1` is not decoration: a plain two's-complement negation is one
    smaller for every negative value, which leaves gaps between two negatives
    unchanged but puts +0.0 and -0.0 one apart at the other end -- so two gates
    reading the same file would report the same sign-of-zero defect as 2^63 and
    2^63 - 1. Nothing turns on that here, and everything does if a reader ever
    compares the two numbers. So this is a transcription, not a translation:

        key(+0.0) = 0        key(-0.0) = 2^63 - 1
    """
    (u,) = struct.unpack("<Q", struct.pack("<d", x))
    if u >> 63:
        return (U64 - u) & U64          # -1 - (u - 2^64) = 2^64 - 1 - u
    return u


def gap(got, want):
    if got != got or want != want:
        return 0 if got != got and want != want else (1 << 62)
    return abs(key(got) - key(want))


def _ctx(d):
    return decimal.Context(prec=d, Emax=999999, Emin=-999999)


def _to_float(d):
    if d.is_nan():
        return math.nan
    if d > decimal.Decimal(DBL_MAX):
        return math.inf
    if d < decimal.Decimal(-DBL_MAX):
        return -math.inf
    return float(d)


# ── the references ──────────────────────────────────────────────────────────

def ref_hypot(x, y):
    # The infinity is tested FIRST. C99 7.12.7.3, IEEE 754-2019 and glibc all give
    # +inf for hypot(inf, nan), and t325 pins that as a defect this module had --
    # "every comparison against a NaN is false, so taking a maximum hands back the
    # NaN". A reference that checks NaN first therefore reports the CORRECT
    # answer as wrong, which is the worst thing a reference can do. It did, on
    # four pairs, before this line moved.
    if math.isinf(x) or math.isinf(y):
        return math.inf
    if x != x or y != y:
        return math.nan
    with decimal.localcontext(_ctx(60)):
        dx, dy = decimal.Decimal(x), decimal.Decimal(y)
        return _to_float((dx * dx + dy * dy).sqrt())


TAN_PI_8 = decimal.Decimal("0.41421356237309504880168872420969807856967187537694")


def _atan_dec(t):
    """arctangent in Decimal, by reduction and a series.

    WRITTEN HERE because Python 3.14's decimal has no inverse trig: it has exp,
    ln, log10, sqrt and power, and nothing else. mpmath is not installed on this
    machine, and AGENTS.md already says so. So there was no reference to call,
    which is the real reason audit_float.py left the two-argument functions out
    -- not that checking them was inconvenient.

    Which makes writing one the only way to gate them, and a hand-written
    reference is exactly the thing that must not be trusted on its own. So it is
    checked against this platform's libm on every two-argument case in
    ulp_table.txt before the sweep runs, and a disagreement stops the run and
    says the reference is wrong. That check is what makes this trustworthy; the
    series below is only the thing being trusted into it.

    Two exact identities do the reduction, so the series only ever sees |t| <=
    tan(pi/8) and converges at a ratio of 0.1716 a term:

        atan(t)  =  pi/2 - atan(1/t)          for |t| > 1
        atan(t)  =  pi/4 + atan((t-1)/(t+1))  for tan(pi/8) < t <= 1

    and the series is the alternating one, t - t^3/3 + t^5/5 - ...
    """
    with decimal.localcontext(_ctx(90)):
        neg = t < 0
        a = -t if neg else t
        if a > 1:
            r = PI / 2 - _atan_dec(1 / a)
        elif a > TAN_PI_8:
            r = PI / 4 + _atan_dec((a - 1) / (a + 1))
        else:
            a2 = a * a
            term = a
            total = a
            k = 1
            while True:
                term = -term * a2
                add = term / (2 * k + 1)
                if add == 0 or abs(add) < abs(total) * decimal.Decimal(10) ** -85:
                    break
                total += add
                k += 1
                if k > 400:
                    raise AssertionError("atan series did not converge for %r" % t)
            r = total
        return -r if neg else r


def _atan2_generic(y, x):
    """atan2 for finite x and y, both non-zero. The quadrant is the signs and the
    ratio is formed in Decimal, so it neither overflows nor flushes -- y/x can be
    1e600 here, and _atan_dec's first identity brings it straight back."""
    with decimal.localcontext(_ctx(90)):
        dy, dx = decimal.Decimal(y), decimal.Decimal(x)
        a = _atan_dec(dy / dx)
        if dx < 0:
            a = a + PI if dy > 0 else a - PI
        return _to_float(a)


def ref_atan2(y, x):
    """C's atan2, with every zero and infinity spelled out.

    The zero cases cannot come from the generic path and are not a detail: -0.0
    is neither greater nor less than zero, so a `y > 0` / `y < 0` / else ladder
    answers the same thing for all four zero pairs. That is not a hypothetical --
    it is the defect class this module has already produced twice.
    """
    if y != y or x != x:
        return math.nan
    yneg = math.copysign(1.0, y) < 0
    xneg = math.copysign(1.0, x) < 0
    if math.isinf(x) and math.isinf(y):
        # |y/x| is 1, so the answer is +-pi/4 or +-3pi/4, and WHICH of the two is
        # decided by x alone -- pi/4 on the positive x side, 3pi/4 on the
        # negative one -- with y only supplying the sign. Reading it as "x and y
        # agree in sign" is wrong and was wrong here: it answers -3pi/4 for
        # atan2(-inf, +inf), which is the fourth quadrant. The reference check
        # below caught it on two of the table's cases, which is the entire reason
        # that check runs before the sweep and not after.
        with decimal.localcontext(_ctx(60)):
            q = PI / 4 if x > 0 else 3 * PI / 4
            return _to_float(-q if yneg else q)
    if math.isinf(x):
        if xneg:
            return -math.pi if yneg else math.pi
        return -0.0 if yneg else 0.0
    if math.isinf(y):
        with decimal.localcontext(_ctx(60)):
            return _to_float(-PI / 2 if yneg else PI / 2)
    if x == 0.0 and y == 0.0:
        if xneg:
            return -math.pi if yneg else math.pi
        return -0.0 if yneg else 0.0
    if x == 0.0:
        with decimal.localcontext(_ctx(60)):
            return _to_float(-PI / 2 if yneg else PI / 2)
    if y == 0.0:
        if xneg:
            return -math.pi if yneg else math.pi
        return -0.0 if yneg else 0.0
    return _atan2_generic(y, x)


PAIRS = {
    "hypot": ref_hypot,
    "atan2": ref_atan2,
}


# ── the argument spread ─────────────────────────────────────────────────────

def pair_spread(n):
    """n pairs whose two arguments are each drawn from the DECADES independently.

    Independently is the whole point. Drawing both from one generator correlates
    them, and then y == x is the common case -- one point of a two-dimensional
    range rather than the shape of it. hypot divides the larger by the smaller to
    choose its scale and atan2's answer runs through y/x, so the RATIO is the
    structure, and a spread that does not reach wide ratios is testing one line
    of a two-dimensional domain.

    The pinned head is the same set audit_float.py pins, crossed with itself, so
    every combination of the edges -- the zeros, the subnormals, the infinities,
    the NaN -- is asked at least once. That is where the sign-of-zero defects
    live, and a random spread would reach them by luck.
    """
    rng = random.Random(SEED)
    head = [0.0, -0.0, 1.0, -1.0, 5e-324, -5e-324, 1e-320,
            2.2250738585072014e-308, -2.2250738585072014e-308,
            1e-300, 1e-8, 1e8, 1e300, 1.7976931348623157e308,
            -1.7976931348623157e308, math.inf, -math.inf, math.nan]
    out = [(a, b) for a in head for b in head]
    while len(out) < n:
        p = []
        for _ in range(2):
            d = rng.randrange(-323, 309)
            v = rng.uniform(1.0, 10.0) * (10.0 ** d)
            if v != v or abs(v) == math.inf:
                v = 1.0
            p.append(v if rng.random() < 0.5 else -v)
        out.append((p[0], p[1]))
    return out[:n]


# ── the reference check, on the table's own cases ───────────────────────────

def check_references():
    """Every two-argument case in ulp_table.txt, against this file's references.

    This is the argument that the sweep means anything. A reference that is wrong
    reports correct code as failing, and the person who arrives to look will fix
    the code. So the check is loud, it is on every run, and it names itself as
    what it is.
    """
    bad = []
    n = 0
    for line in open(TABLE, encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        f = line.split()
        if f[0] not in PAIRS:
            continue
        n += 1
        a, b = val(int(f[1])), val(int(f[2]))
        want = val(int(f[3]))
        first, second = ORDER[f[0]]
        got = PAIRS[f[0]](b, a) if (first, second) == ("x", "y") \
            else PAIRS[f[0]](a, b)
        if bits(got) != bits(want):
            bad.append((f[0], a, b, got, want))
    if bad:
        print("  THIS FILE'S REFERENCE disagrees with libm on %d of %d table cases:"
              % (len(bad), n))
        for name, a, b, got, want in bad[:8]:
            print("    %-6s (%r, %r)  ref %r  libm %r" % (name, a, b, got, want))
        print("  The REFERENCE is wrong, not the module. Fix this file.")
        return 1
    print("  reference check: %d two-argument table cases, all agree with libm" % n)
    return 0


# ── the driver ──────────────────────────────────────────────────────────────

def lit(x):
    if x != x:
        return "math.nan"
    if x == math.inf:
        return "math.inf"
    if x == -math.inf:
        return "0.0 - math.inf"
    if x == 0.0:
        return "0.0" if math.copysign(1.0, x) > 0 else "0.0 * (0.0 - 1.0)"
    return repr(x)


# Which of the pair is each function's FIRST argument. atan2(y, x) takes the
# y-like one first; hypot(x, y) does not care -- it is symmetric -- but the
# reference here is called the same way round as the module, so that a
# disagreement is a disagreement about the ANSWER and never about the order.
#
# Getting this wrong is not hypothetical: the first run of this file reported
# 1948 atan2 cases over tolerance, every one of them the driver asking
# atan2(1.0, -0.0) while the reference answered for atan2(-0.0, 1.0). A harness
# that disagrees with itself on 97% of its cases is a harness with a bug, and the
# number it printed looked exactly like a catastrophic module defect.
ORDER = {"atan2": ("y", "x"), "hypot": ("x", "y")}


def y_source(ps):
    ys = [lit(a) for a, _ in ps]
    xs = [lit(b) for _, b in ps]
    lines = ["import math;",
             "let ys: [float] = [%s];" % ", ".join(ys),
             "let xs: [float] = [%s];" % ", ".join(xs),
             "let i = 0;", "while (i < len(xs)) {",
             "    let y = ys[i];", "    let x = xs[i];",
             '    print("A " + tostring(math.fbits(y)) + " " + tostring(math.fbits(x)));']
    for name in sorted(PAIRS):
        first, second = ORDER[name]
        lines.append('    print("%s " + tostring(math.fbits(math.%s(%s, %s))));'
                     % (name, name, first, second))
    lines += ["    i = i + 1", "};"]
    return "\n".join(lines) + "\n"


def main():
    if check_references():
        return 2

    ps = pair_spread(NARGS)
    tmp = tempfile.mkdtemp(prefix="y-pairs-")
    src = os.path.join(tmp, "pairs.y")
    exe = os.path.join(tmp, "pairs")
    with open(src, "w") as fh:
        fh.write(y_source(ps))
    r = subprocess.run([YCC, "-o", exe, src], capture_output=True, text=True)
    if r.returncode != 0:
        print("cannot build the pair driver:\n%s" % r.stderr, file=sys.stderr)
        return 2
    r = subprocess.run([exe], capture_output=True, text=True)
    if r.returncode != 0:
        print("the pair driver died: %s" % r.stderr.strip(), file=sys.stderr)
        return 2

    lines = [l for l in r.stdout.split("\n") if l]
    per = len(PAIRS) + 1
    if len(lines) != len(ps) * per:
        print("the driver printed %d lines, expected %d" % (len(lines), len(ps) * per),
              file=sys.stderr)
        return 2

    worst = {k: (0, None) for k in PAIRS}
    over = {k: [] for k in PAIRS}
    for j in range(len(ps)):
        # the A record is "A <bits> <bits>" -- THREE fields, so it is read by
        # position rather than turned into a dict, which wants pairs and would
        # have failed here with a message about dictionary update sequences
        blk = lines[j * per:(j + 1) * per]
        head = blk[0].split()
        y, x = val(int(head[1])), val(int(head[2]))
        rec = dict(p.split() for p in blk[1:])
        for name in PAIRS:
            gb = int(rec[name]) & U64
            first, second = ORDER[name]
            want = PAIRS[name](x, y) if (first, second) == ("x", "y") \
                else PAIRS[name](y, x)
            g = gap(val(gb), want)
            if g > worst[name][0]:
                worst[name] = (g, (y, x, val(gb), want))
            if g > TOL:
                over[name].append((y, x))

    print()
    print("  %d PAIRS x %d functions, each argument uniform in the decades and the"
          " two drawn INDEPENDENTLY, seed %d" % (len(ps), len(PAIRS), SEED))
    print("  %-8s %9s %11s" % ("function", "over %d" % TOL, "worst ulp"))
    bad = False
    for name in sorted(PAIRS):
        w = worst[name][0]
        print("  %-8s %9d %11d" % (name, len(over[name]), w))
        if over[name]:
            bad = True
    if not bad:
        print("\n  NOTHING OVER %d ULP" % TOL)
        return 0
    print("\n  WORST PER FUNCTION, so a regression names itself:")
    for name in sorted(PAIRS):
        if over[name]:
            g, (a, b, got, want) = worst[name]
            print("    %-8s worst %s ulp at (%r, %r): got %r want %r  (%d over)"
                  % (name, g, a, b, got, want, len(over[name])))
    return 1


if __name__ == "__main__":
    sys.exit(main())
