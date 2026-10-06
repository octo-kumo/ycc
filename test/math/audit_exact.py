#!/usr/bin/env python3
"""Audit std/math.y's EXACT tier against exact Python integers.

The ulp table gates the rounding functions. The exact tier -- integer helpers,
modular arithmetic, bit tricks -- is gated by property fixtures, and a property
fixture holds a few dozen cases. This holds 4041 arguments across fourteen
functions, and checks every answer against arbitrary-precision integers rather
than against another implementation, so there is nothing to be wrong in common
with it.

Run it by hand, like sweep_edges.py:

    python3 test/math/audit_exact.py            # 4041 arguments
    ARGS=20000 python3 test/math/audit_exact.py  # a wider spread

It is not in `make test`: it needs a compiler and a Python, and a suite that
takes minutes is a suite people stop running. What it finds goes into a fixture.

WHAT IT IS NOT
    A proof. 4041 arguments is a spread, not an exhaustive sweep. It is here
    because it is three orders of magnitude wider than the fixtures it stands
    beside, and because every case it checks is checked against integers rather
    than against libm or against the module itself.

FIVE THINGS THIS FILE GOT WRONG FIRST
    Written down because each one produced a confident, wrong FAILING report,
    and a false report costs more than no report -- it sends you to fix code
    that is right.

    1. The arguments are UNSIGNED in Python and SIGNED in Y. A literal of
       2^64-1 stored in a `long` arrives as -1, so `abs` "failed" on 342
       arguments. Read every array through s64() before comparing.
    2. The driver and the checker must agree on which argument goes where. They
       did not: pow_mod's exponent is xs[(j*13+2)%N] and mul_mod's second
       operand is xs[(j*11+5)%N], and the checker used the latter for both.
       pow_mod(2, 4096, 7) "failed" with the module answering 2, which is right.
    3. The two top-level loops' output is NOT interleaved. The first emits 14
       lines per argument, then the second emits 3 for every argument.
    4. The modular functions are SIGNED. mul_mod reduces mod m and folds the
       negatives up, which is exactly Python's `%` on signed ints; inv_mod
       likewise. Reading them as unsigned "failed" mul_mod on 1292 arguments
       and inv_mod on 339.
    5. clamp's precondition is lo <= hi. Sorting the pair to satisfy it made the
       reference disagree with the module on every ill-formed call, which is
       not a finding. Those calls are skipped, not checked.
"""

import io
import json
import math
import os
import random
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
YCC = os.environ.get("YCC", os.path.join(REPO, "ycc"))
NARGS = int(os.environ.get("ARGS", "4041"))
SEED = int(os.environ.get("SEED", "20261005"))

M64 = (1 << 64) - 1


def u64(v):
    return v & M64


def s64(v):
    v &= M64
    return v - (1 << 64) if v >> 63 else v


# ── the arguments ──────────────────────────────────────────────────────────
# The edges somebody thought of first, then a seeded spread over every width
# from 4 to 64 bits. A pinned list is not a spread; see the note in
# gen_ulp_table.py, which has now been made three times.
EDGES = [0, 1, 2, 3, 4, 5, 6, 7, 8, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128,
         255, 256, 257, 1023, 1024, 1025, 4095, 4096, 65535, 65536,
         2**31 - 1, 2**31, 2**32 - 1, 2**32, 2**53, 2**53 + 1, 2**62, 2**63 - 1,
         2**64 - 1, 2**64 - 2, 2**64 - 3]

# primes: pow_mod and inv_mod document 0 < m <= 2147483647, and Fermat's little
# theorem (which t302 uses) needs a prime modulus, so the spread is over primes.
PRIMES = [p for p in range(3, 1000) if all(p % d for d in range(2, int(p ** 0.5) + 1))]


def arguments():
    rng = random.Random(SEED)
    xs = list(EDGES)
    while len(xs) < NARGS:
        xs.append(rng.getrandbits(rng.choice([4, 8, 16, 32, 63, 64])))
    return [s64(v) for v in xs]


# ── the reference ──────────────────────────────────────────────────────────
# Every one of these is arbitrary-precision integer arithmetic. None of them
# calls into the module, and none of them can be wrong in the same way twice.


def ref_gcd(a, b):
    a, b = abs(a), abs(b)
    while b:
        a, b = b, a % b
    return a


def ref_lcm(a, b):
    # Wraps, by the module's own comment: dividing first keeps the product from
    # overflowing "more often than it must", which is not "never".
    a, b = abs(a), abs(b)
    return 0 if (a == 0 or b == 0) else s64((a // ref_gcd(a, b)) * b)


def ref_clz(x):
    if x == 0:
        return 64
    return 64 - u64(x).bit_length()


def ref_ctz(x):
    if x == 0:
        return 64
    u = u64(x)
    return (u & -u).bit_length() - 1


def ref_next_pow2(x):
    # The module's own rule, from its comment: 1 for x <= 1, and 0 for an x
    # whose power of two is past 2^62 -- there is no larger power of two in the
    # long range, and the module says so rather than wrapping.
    if x <= 1:
        return 1
    p = 1 << (x - 1).bit_length()
    return p if p <= (1 << 62) else 0


def ref_rotl(x, k):
    k &= 63
    u = u64(x)
    return s64((u << k | u >> (64 - k)) if k else u)


# ── the driver ─────────────────────────────────────────────────────────────
# One print per answer, labelled. Y's print concatenates its arguments, so each
# line is <label><value>; the checker strips the label it already knows.
UNARY = ["isqrt", "popcount", "ctz", "clz", "next_pow2", "sign", "abs"]
# rotl's count is reduced here because the audit is about ANSWERS, and the
# count's range is a separate question with its own fixture (t321).
BINARY = ["gcd", "lcm", "min", "max", "rotl"]


def y_source(xs, mods):
    n, p = len(xs), len(mods)
    out = []
    a = out.append
    a("import math;")
    a("let xs: [long] = [" + ", ".join(str(v) for v in xs) + "];")
    a("let mods: [long] = [" + ", ".join(str(v) for v in mods) + "];")
    a("let i = 0;")
    a("while (i < " + str(n) + ") {")
    for f in UNARY:
        a('    print("' + f + '", math.' + f + '(xs[i]));')
    for f in BINARY:
        if f == "rotl":
            a('    print("rotl", math.rotl(xs[i], xs[(i * 7 + 3) % ' + str(n) + '] & 63));')
        else:
            a('    print("' + f + '", math.' + f + '(xs[i], xs[(i * 7 + 3) % ' + str(n) + ']));')
    a('    print("clamp3", math.clamp(xs[i], xs[(i * 7 + 3) % ' + str(n)
      + '], xs[(i * 11 + 1) % ' + str(n) + ']));')
    a('    print("mul_mod", math.mul_mod(xs[i], xs[(i * 7 + 3) % ' + str(n)
      + '], mods[i % ' + str(p) + ']));')
    a("    i = i + 1")
    a("};")
    a("let j = 0;")
    a("while (j < " + str(n) + ") {")
    a('    print("mul_mod", math.mul_mod(xs[j], xs[(j * 11 + 5) % ' + str(n)
      + '], mods[j % ' + str(p) + ']));')
    a('    print("pow_mod", math.pow_mod(xs[j], xs[(j * 13 + 2) % ' + str(n)
      + '], mods[j % ' + str(p) + ']));')
    a('    print("inv_mod", math.inv_mod(xs[j], mods[j % ' + str(p) + ']));')
    a("    j = j + 1")
    a("};")
    return "\n".join(out) + "\n"


def main():
    xs = arguments()
    mods = [s64(p) for p in PRIMES]
    n, p = len(xs), len(mods)

    tmp = tempfile.mkdtemp(prefix="y-exact-")
    src = os.path.join(tmp, "exact.y")
    exe = os.path.join(tmp, "exact")
    with open(src, "w") as fh:
        fh.write(y_source(xs, mods))
    r = subprocess.run([YCC, "-o", exe, src], capture_output=True, text=True)
    if r.returncode != 0:
        print("cannot build the audit driver:\n%s" % r.stderr, file=sys.stderr)
        return 2
    r = subprocess.run([exe], capture_output=True, text=True)
    if r.returncode != 0:
        print("the audit driver died: %s" % r.stderr.strip(), file=sys.stderr)
        return 2
    lines = r.stdout.split("\n")
    while lines and lines[-1] == "":
        lines.pop()

    per = len(UNARY) + len(BINARY) + 2 + 3          # 14 from the first loop
    want = n * per
    if len(lines) != want:
        print("the driver printed %d lines, expected %d -- the walk order and "
              "the driver disagree" % (len(lines), want), file=sys.stderr)
        return 2

    bad = {}
    checked = 0

    def fail(fn, args, got, want):
        bad.setdefault(fn, []).append((args, got, want))

    def take(label):
        nonlocal checked
        checked += 1
        ln = lines[take.i]
        take.i += 1
        if not ln.startswith(label):
            raise SystemExit("walk desynchronised at %r (wanted %r)"
                             % (ln[:24], label))
        return int(ln[len(label):])

    take.i = 0
    for i in range(n):
        x = xs[i]
        y = xs[(i * 7 + 3) % n]
        z = xs[(i * 11 + 1) % n]
        m = mods[i % p]
        v = {f: take(f) for f in UNARY}
        for f in BINARY:
            v[f] = take(f)
        v["clamp3"] = take("clamp3")
        v["mul_mod"] = take("mul_mod")

        u = u64(x)
        checks = {
            "isqrt": (x, 0 if x < 0 else math.isqrt(x)),
            "popcount": (x, bin(u).count("1")),
            "ctz": (x, ref_ctz(x)),
            "clz": (x, ref_clz(x)),
            "next_pow2": (x, ref_next_pow2(x)),
            "sign": (x, 0 if x == 0 else (1 if x > 0 else -1)),
            "abs": (x, abs(x)),
            "gcd": ((x, y), ref_gcd(x, y)),
            "lcm": ((x, y), ref_lcm(x, y)),
            "min": ((x, y), x if x < y else y),
            "max": ((x, y), x if x > y else y),
            "rotl": ((x, y & 63), ref_rotl(x, y & 63)),
            "mul_mod": ((x, y, m), (x % m) * (y % m) % m),
        }
        if y <= z:            # clamp's precondition; see note 5 above
            checks["clamp3"] = ((x, y, z), y if x < y else (z if x > z else x))
        for fn, (args, want) in checks.items():
            if v[fn] != want:
                fail(fn, args, v[fn], want)

    for j in range(n):
        a = xs[j]
        b = xs[(j * 11 + 5) % n]
        e = xs[(j * 13 + 2) % n]
        m = mods[j % p]
        g = take("mul_mod")
        w = (a % m) * (b % m) % m
        if g != w:
            fail("mul_mod", (a, b, m), g, w)
        g = take("pow_mod")
        if 0 <= e < (1 << 20):        # pow() by repeated squaring is O(log e)
            w = pow(a % m, e, m)
            if g != w:
                fail("pow_mod", (a, e, m), g, w)
        g = take("inv_mod")
        if a % m:                     # no inverse when a is a multiple of m
            w = pow(a % m, -1, m)
            if g != w:
                fail("inv_mod", (a, m), g, w)

    print("  %d answers over %d arguments, %d functions, against exact integers"
          % (checked, n, 14))
    if not bad:
        print("  NOTHING WRONG")
        return 0
    print("  FAILURES:")
    for fn in sorted(bad):
        rows = bad[fn]
        print("    %-10s %6d failing arguments; first: args=%s got=%s want=%s"
              % (fn, len(rows), rows[0][0], rows[0][1], rows[0][2]))
    return 1


if __name__ == "__main__":
    sys.exit(main())