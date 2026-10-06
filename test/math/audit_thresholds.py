#!/usr/bin/env python3
"""Every threshold std/math.y branches on, and whether anything straddles it.

THE DEFECT THIS COMES FROM, twice in one afternoon.

hypot_scaled picks between three forms on `m < 1e153 && m > 1e-152` and then on
`s/m < 1e-4`. Those three numbers are DECISION POINTS: a value exactly at one
takes one path, one ulp past it takes another, and both must be right. The high
bound was wrong by a factor of ten -- reasoned from `m*m` alone, when the line
evaluates `m*m + s*s`, which is up to twice as large -- and for every m in
(9.4808e153, 1e154) with s comparable to it the module answered +inf for an
answer of about 1.4e154.

Nothing caught it, and the reason is the point:

  - a 20000-pair DECADE-UNIFORM sweep did not, and could not have. The defect
    lives in the top 5.8 per cent of ONE decade, and it needs a second condition
    (s comparable to m) that an independent draw makes rare. The expected count
    where both hold is (1/628) x (2/600) = 5.3e-6, so 20000 draws give 0.11 --
    one chance in nine.
  - what caught it was a case built from the CONSTANT THE CODE TESTS.

So the rule, which is the reusable part: A SWEEP FINDS DEFECTS BY AREA. It finds
what is spread across the domain and is blind to a sliver of one. A threshold is
only findable if something NAMES it.

WHAT THIS DOES. It reads the comparisons out of src/y/std/math.y -- both the
numeric literals and the named `let` constants they are written against -- and
for each one asks whether anything in the gates puts a case on BOTH sides of it,
or within an ulp of it. A threshold nothing straddles is not a defect; it is a
threshold whose two branches have never been told apart, which is the state the
hypot bound was in.

It is a REPORT with a ratchet, not a verdict. `0.0`, `0` and `1` are on nearly
every line and straddle trivially; the ones worth a reader's attention are the
constants that sit at the edge of a domain -- `pio2_max`, `atan_max`,
`hypot`'s band, `to_int`'s 2147483647 -- and the report sorts those first.

    python3 test/math/audit_thresholds.py            # the report
    python3 test/math/audit_thresholds.py --selftest # does it find a planted seam?
"""
import io
import math
import os
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
MATH = os.environ.get("MATH_Y", os.path.join(ROOT, "src/y/std/math.y"))
TABLE = os.path.join(HERE, "ulp_table.txt")
FIXTURES = [os.path.join(ROOT, "test/y/native"), os.path.join(ROOT, "test/std")]

# Comparisons whose right-hand side is a NUMBER the code branches on. The
# comparisons against 0.0 and 0 are excluded from the report by `interesting()`
# rather than here, because there are 130-odd of them and every zero is pinned by
# the pinned-edge block the table already carries.
CMP = re.compile(r"(<=|>=|==|!=|<|>)\s*(-?\d+\.\d*(?:e-?\d+)?|-?\d+e-?\d+|-?\d+\.\d*|-?\d+)")
CMP_NAMED = re.compile(r"(<=|>=|==|!=|<|>)\s*([a-z_][a-z0-9_]*)")

# ONLY a comparison whose left operand is one of the enclosing function's own
# float PARAMETERS is decidable here, and the restriction is not tidiness.
#
# "Is there a table argument near this threshold" is the right question for a
# threshold on an ARGUMENT -- the value the caller passes. It is the wrong
# question for a threshold on something DERIVED: hypot_scaled tests `s/m < 1e-4`,
# a RATIO, and the table's boundary block crosses a threshold with a partner
# precisely because no single argument is ever near 1e-4. The first run of this
# tool reported that ratio as 1.5e15 ulps from anything, which is true and
# meaningless. An integer threshold is the same shape of mistake: 2047 is a
# LONG comparison, and measuring it in ulps of a double compares nothing.
DEF = re.compile(r"def\s+[A-Za-z_]\w*\s*\(([^)]*)\)")
PARAM = re.compile(r"([A-Za-z_]\w*)\s*:\s*float")


def named_constants(path):
    """The module-level `let NAME: float = <number>;` constants.

    Only numeric ones, and only float-typed: a name compared against that is not
    a float cannot be a float threshold, and the table's answers are doubles.
    """
    out = {}
    src = io.open(path, encoding="utf-8").read()
    for m in re.finditer(r"^let ([a-z_][a-z0-9_]*): float = (-?\d+\.?\d*(?:e-?\d+)?);",
                         src, re.M):
        try:
            out[m.group(1)] = float(m.group(2))
        except ValueError:
            pass
    return out


def thresholds(path):
    """(function, line, text, value) for every comparison against a number."""
    src = io.open(path, encoding="utf-8").read().split("\n")
    consts = named_constants(path)
    out = []
    cur = None
    params = ()
    for n, raw in enumerate(src, 1):
        line = re.sub(r"//.*$", "", raw)
        m = re.match(r"\s*(?:native\s+)?def\s+([A-Za-z_]\w*)", line)
        if m and cur is None:
            cur = m.group(1)
            sig = DEF.search(raw)
            params = set(PARAM.findall(sig.group(1))) if sig else set()
        # The left operand, whole-token. `x < 1e153` and `(x) < 1e153` both give
        # `x`; `s / m < 1e-4` gives `m`, which is not what is being compared, and
        # the whole-token rule is what keeps that out.
        for lhs, op, lit in re.findall(r"(?:^|[^\w.])([A-Za-z_]\w*)\s*(<=|>=|==|!=|<|>)\s*"
                                      r"(-?\d+\.?\d*(?:e-?\d+)?)", line):
            if lhs not in params:
                continue
            try:
                out.append((cur or "?", n, line.strip()[:60], float(lit)))
            except ValueError:
                pass
        for lhs, op, name in re.findall(r"(?:^|[^\w.])([A-Za-z_]\w*)\s*(<=|>=|==|!=|<|>)\s*"
                                         r"([a-z_][a-z0-9_]*)", line):
            if lhs in params and name in consts:
                out.append((cur or "?", n, line.strip()[:60], consts[name]))
        if cur and line.strip() == "};":
            cur = None
    return out


# How far, in ulps of the threshold, the nearest table argument may be before
# this is worth reading. 1e6 ulps is about 2e-13 relative: close enough that the
# branch is exercised on both sides, which is all a threshold strictly needs.
# 1e10 is about 2e-6, and by then a sliver beside the threshold is invisible.
LIMIT = 1e6

# Thresholds known to be far from the TABLE, each with what covers it instead.
# All three are ORACLE seams -- comparisons inside exp_y and pow_y, which are not
# exported and so cannot appear in ulp_table.txt at all. They are pinned by the
# fixture that compares each oracle against the assembly kernel it stands in for,
# and those fixtures call BOTH sides at the seam:
#
#   t311_math_exp_asm.y's check(x) runs math.exp(x) and math.exp_y(x) and fails
#   unless they agree bit for bit, and it is called with -745.133219101941074020
#   -- which is exp_lo exactly -- and with the double below it.
#
#   t315_math_pow_asm.y's header says it reaches "the integer-exponent path at
#   both ends of +-1024, and the negative base past 1024 where the logarithm
#   carries it", which is this seam.
#
# So each is pinned once, by the gate that CAN see it, and the table's silence is
# a fact about the table rather than a gap. Recording that is the point: an
# unexplained "far" is indistinguishable from an unpinned one, and this is the
# difference between the two.
KNOWN_FAR = {
    ("exp_y", -745.133): (
        "the ORACLE's underflow seam, exp_lo. Pinned by "
        "t311_math_exp_asm.y, whose check() runs math.exp and math.exp_y and "
        "requires the same bits -- and it is called with exp_lo exactly. The "
        "table cannot see it: exp is ASSEMBLY, so its exp cases do not execute "
        "this line at all, and exp_y is not exported."),
    ("pow_y", -1024.0): (
        "the ORACLE's integer-path bound. Pinned by t315_math_pow_asm.y, whose "
        "header names 'the integer-exponent path at both ends of +-1024' and the "
        "negative base past 1024. pow is ASSEMBLY and pow_y is not exported, so "
        "the table cannot reach this comparison."),
}


def at_interesting(v):
    """0, 1 and -1 straddle on every argument list there is. The thresholds worth
    a reader's attention are the ones at the edge of a domain."""
    return v not in (0.0, -0.0, 1.0, -1.0, 2.0, -2.0, 0.5, -0.5)


def _known(fn, v):
    for (f, t), _why in KNOWN_FAR.items():
        if f == fn and abs(t - v) <= abs(t) * 1e-6:
            return True
    return False


def table_arguments():
    """Every argument the checked-in table carries, as floats."""
    vals = set()
    for line in io.open(TABLE, encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        for f in line.split()[1:-1]:
            b = int(f) & ((1 << 64) - 1)
            vals.add(struct.unpack("<d", struct.pack("<Q", b))[0])
    return vals


def _key(x):
    (u,) = struct.unpack("<Q", struct.pack("<d", x))
    return -((~u + 1) & ((1 << 64) - 1)) if u >> 63 else u


def nearest_ulps(v, args):
    """How far the NEAREST table argument is from this threshold, in ulps of v.

    NOT "is there an argument on each side", which was the first version of this
    function and which is worthless: with 7572 cases spread over the decades,
    almost every threshold in the module has arguments above and below it, and so
    did hypot's 1e154 while the two branches on either side of it had never been
    told apart. Asking "how close does anything get" is the question a seam needs
    answered, and the answer is a number.

    Returned in ulps of v itself, so 1 means an argument one representable step
    away. A value of 1e6 means the nearest argument is about 2e-13 relative --
    close enough that the branch is exercised on both sides, which is all a
    threshold strictly needs. 1e10 is 2e-6 relative, and by then a defect that
    only lives in the sliver beside the threshold can hide there indefinitely.
    """
    if v == 0.0 or v != v or math.isinf(v):
        return None
    step = abs(_key(math.nextafter(v, math.inf)) - _key(v)) or 1
    best = None
    for a in args:
        if a != a or math.isinf(a):
            continue
        g = abs(_key(a) - _key(v)) / step
        if best is None or g < best:
            best = g
    return best


def selftest():
    """Does the extractor see a seam at all?

    A report that finds nothing because it parsed nothing is the same shape as a
    report that finds nothing because there is nothing, and only one of them is a
    result. So: plant a comparison against a distinctive constant, and require the
    extractor to name it.
    """
    plant = """
def planted(x: float) -> float {
    if (x < 3.25e77) { 1.0 } else { 2.0 }
};
"""
    with open("/tmp/.y-thresholds-plant.y", "w", encoding="utf-8") as fh:
        fh.write(plant)
    try:
        found = [t for t in thresholds("/tmp/.y-thresholds-plant.y") if t[3] == 3.25e77]
        if not found:
            print("  FAILED  the extractor did not find a planted comparison")
            return 1
        print("  ok      the extractor finds a planted comparison (%s, line %d)"
              % (found[0][0], found[0][1]))
        return 0
    finally:
        os.unlink("/tmp/.y-thresholds-plant.y")


def main():
    if "--selftest" in sys.argv:
        return selftest()
    path = sys.argv[1] if len(sys.argv) > 1 else MATH
    ths = thresholds(path)
    args = table_arguments()
    named = named_constants(path)

    seen = {}
    for fn, n, text, v in ths:
        seen.setdefault(v, []).append((fn, n, text))
    edges = sorted((v for v in seen if at_interesting(v)), key=lambda v: -len(seen[v]))

    print("  %d comparisons against a number or a float constant, %d distinct values"
          % (len(ths), len(seen)))
    print("  %d of those are at the edge of a domain (not 0, +-1, +-2, 0.5)" % len(edges))
    print()
    print("  %-14s %-4s %14s  %s" % ("threshold", "used", "nearest (ulps)", "where"))
    rows = []
    for v in edges:
        g = nearest_ulps(v, args)
        if g is None:
            continue
        rows.append((g, v))
    rows.sort()
    far = []
    for g, v in rows:
        fn, n, text = seen[v][0]
        mark = ""
        if g > LIMIT:
            mark = "  <-- FAR" + (" (known)" if _known(fn, v) else " *** NEW ***")
            if not _known(fn, v):
                far.append((fn, v, g))
        print("    %-14.6g x%-3d %14.6g  %s line %d%s"
              % (v, len(seen[v]), g, fn, n, mark))
    print()
    print("  %d of %d edge thresholds have no table argument within %g ulps of them."
          % (len(rows) - len([r for r in rows if r[0] <= LIMIT]), len(rows), LIMIT))
    if far:
        print()
        for fn, v, g in far:
            print("  *** %s's threshold %r is %.4g ulps from anything in the table."
                  % (fn, v, g))
            print("      A defect that lives only beside that seam can hide there")
            print("      indefinitely: a decade-uniform sweep finds by AREA, and this")
            print("      is a sliver. The fix is a case -- the value, its two")
            print("      neighbouring doubles, and a partner close enough that any")
            print("      second condition also holds -- or a reason in KNOWN.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
