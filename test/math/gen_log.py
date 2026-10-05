#!/usr/bin/env python3
"""Generate y_log -- the routine test/y/native/t312_math_log_asm.y gates.

    python3 test/math/gen_log.py [OUT.s] [STAGE]

Run from the repository root. STAGE is `full`, or one of m/e/z/w/P/out, which
returns that intermediate instead of the answer -- how a divergence gets
localised: return the mantissa, or the exponent, or z, or z's low half, and
compare against the Y version's own value at that point. The same four probes
that found four bugs in y_exp's first attempt (§8 of ideas/math.md).

To land a change to log: edit src/y/std/math.y, run this, write the result over
the y_log block in src/y/arch/math.s, and run t312.

Every constant is READ OUT of src/y/std/math.py rather than copied: the promise
is that this returns the same double as the Y, so a table typed by hand is a
table that can disagree with the oracle, and nothing in the build would notice.
The operation sequence mirrors the Y line for line, because that is what makes the
bits match:

    p = frexp(x); m = bitsf(p[0]); e = p[1]     -> the pattern, and a
        subnormal doubled until its field is not 0 (frexp's guard loop)
    if (m < inv_sqrt2) { m = m*2; e = e-1 }     -> one compare
    z = log_z(m) + z_lo                          -> the division, and the
        quotient's own error turned back into a double by a second divide
    w = z*z; (z*(2 + w*poly_split(log_k, log_kl, w))) + e*ln2_hi + e*ln2_lo

Two things in the Y are worth naming, because the assembly has to do the same
thing rather than the obvious one:

* `log_z` keeps the error of `(m-1)/(m+1)` in a MODULE-LEVEL CELL, because m+1
  rounds and its half-ulp is a whole ulp of z. `two_sum` gives the denominator's
  residual and one more divide turns it into z's. The assembly has both halves in
  registers instead of a cell, which is the same arithmetic and one fewer store.
* the three summands are added in the order written, the small z part first and
  each large e*ln2 half at its own scale. Adding them any other way loses the
  low bits of z.
"""
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from genlib import Table, Writer, bits, emit, let_float, let_floats  # noqa: E402

WHICH = sys.argv[2] if len(sys.argv) > 2 else "full"

# ── the constants, read not copied ────────────────────────────────────────
inv_sqrt2 = let_float("inv_sqrt2")
ln2_hi = let_float("ln2_hi")
ln2_lo = let_float("ln2_lo")
log_k = let_floats("log_k")
log_kl = let_floats("log_kl")
N = len(log_k) - 1
assert len(log_k) == len(log_kl) and N >= 8, (len(log_k), len(log_kl))

# The same kernel in Python, in the same order: if it does not match math.log to
# within a few ulps over a spread of arguments, the table was mis-parsed and
# everything after this line is wrong.
def kernel(w: float) -> float:
    p, q = log_k[N], log_kl[N]
    for i in range(N - 1, -1, -1):
        p = p * w + log_k[i]
        q = q * w + log_kl[i]
    return p + q


def model(x: float) -> float:
    import math
    b = struct.unpack("<q", struct.pack("<d", x))[0]
    f = (b >> 52) & 0x7FF
    guard = 0
    while guard < 60 and f == 0 and x != 0.0:
        x *= 2.0
        b = struct.unpack("<q", struct.pack("<d", x))[0]
        f = (b >> 52) & 0x7FF
        guard += 1
    m = struct.unpack("<d", struct.pack("<q", (b & 4503599627370495) | 4602678819172646912))[0]
    e = f - 1022 - guard
    if m < inv_sqrt2:
        m *= 2.0
        e -= 1
    num, den = m - 1.0, m + 1.0
    bb = den - m
    derr = (m - (den - bb)) + (1.0 - bb)
    z = num / den
    z = z + (0.0 - (z * derr) / den)
    w = z * z
    ef = float(e)
    return (z * (2.0 + w * kernel(w))) + (ef * ln2_hi) + (ef * ln2_lo)


import math  # noqa: E402
for _x in (2.0, 0.5, 1.0, 3.25, 1e-300, 1e300, 5e-324, 0.75):
    _want = math.log(_x)
    _got = model(_x)
    assert abs(_got - _want) <= 8e-16 * max(1.0, abs(_want)), (_x, _got, _want)

# ── the table ─────────────────────────────────────────────────────────────
t = Table("ylog_tab", "ylog_tab: log's constants and its split kernel, one label for the lot "
       "(a label per entry costs the shaker ~2K instructions of fixpoint each, "
       "on every compile). Read as ylog_tab+N(%rip), N = 8*index.")
is2 = t.add("isqrt2", inv_sqrt2)
ln2h = t.add("ln2h", ln2_hi)
ln2l = t.add("ln2l", ln2_lo)
one = t.add("one", 1.0)
two = t.add("two", 2.0)
zero = t.add("zero", 0.0)
pinf = t.add("pinf", float("inf"))
ninf = t.add("ninf", float("-inf"))
K = [t.add("k%d" % i, v) for i, v in enumerate(log_k)]
KL = [t.add("kl%d" % i, v) for i, v in enumerate(log_kl)]

# 2^52-1 and 0.5's pattern: frexp's mask and the exponent it leaves in place
# (0x3FE0000000000000 = 4602678819172646912, a literal because it is a PATTERN
# rather than a value anyone would write).
MASK = 4503599627370495
HALFPAT = 4602678819172646912

# ── the routine ───────────────────────────────────────────────────────────
# xmm0 z / num, xmm1 den, xmm2 m, xmm3 w, xmm4 derr, xmm5 r (the doubled
# subnormal), xmm6 ef, xmm7 z_lo, xmm8 scratch, xmm9 the poly's low half.
# GPRs: rax the pattern, rcx the guard, rdx the field, r8/r9/r10 scratch.

w_ = Writer()
w = w_.w

w("# y_log: log(x), x > 0. Generated by test/math/gen_log.py from src/y/std/math.y's")
w("# own log -- do not retype the table (see that file's note). The sequence is")
w("# the Y's line for line, which is what makes the answer the same double rather")
w("# than a near one.")
w("#")
w("# Argument at 8(%rsp) (the last and only one), answer's bits in %rax.")
w("y_log:")
w("    mov 8(%rsp), %rax")
w("    movq %rax, %xmm2                   # xmm2 = x")
w("# if (x != x || x < 0.0) return nan. The self-comparison is the NaN test (PF is")
w("# set only for the unordered result) and `jb` is the x < 0 one: x is not a NaN")
w("# by the time it is tested, so CF=1 means below zero and nothing else.")
w("    ucomisd %xmm2, %xmm2")
w("    jp ylog_nan")
w("    movsd " + zero + ", %xmm8")
w("    ucomisd %xmm8, %xmm2                # flags for x against zero")
w("    jb ylog_nan")
w("# if (x == 0.0) return -inf. +0.0 and -0.0 both compare equal to zero, which is")
w("# what the Y's `x == 0.0` does, so both answer -inf.")
w("    ucomisd %xmm8, %xmm2                # zero is still in xmm8")
w("    je ylog_ninf")
w("# if (is_inf(x)) return +inf. At this point x >= 0, so it is +inf or nothing.")
w("    movsd %xmm2, %xmm0")
w("    ucomisd " + pinf + ", %xmm0")
w("    je ylog_pinf")
w("")
w("# frexp: the mantissa is this mantissa at exponent 1022, in BITS because there")
w("# is no float-to-long conversion here, and the field carries a BIAS of 1023.")
w("# The sign comes off and goes back on as the exponent's sign -- a negative x's")
w("# pattern would put a 1 at the top of an 11-bit field and answer with a")
w("# positive fraction -- but x is positive here (the x < 0 case returned nan), so")
w("# there is nothing to put back.")
w("    movq %xmm2, %xmm5                   # r = x, the Y's `let r = x`")
w("    mov %rax, %rdx")
w("    shr $52, %rdx")
w("    and $2047, %rdx                     # the field, 0 for a subnormal")
w("    xor %ecx, %ecx                      # the guard counter")
w("    test %rdx, %rdx")
w("    jnz ylog_norm_done")
w("# A subnormal has no implicit leading bit, so it is doubled until the field is")
w("# not 0. The Y's loop also tests `r != 0.0`; x is not zero here (the zero case")
w("# returned above) and doubling a nonzero never reaches zero, so that test has")
w("# nothing to catch.")
w("ylog_norm:")
w("    cmp $60, %rcx")
w("    jge ylog_norm_done")
w("    movq %xmm5, %rax")
w("    shr $52, %rax")
w("    and $2047, %rax")
w("    test %rax, %rax")
w("    jnz ylog_norm_done")
w("    movsd %xmm5, %xmm8")
w("    mulsd " + two + ", %xmm8            # r = r * 2.0")
w("    movsd %xmm8, %xmm5")
w("    add $1, %rcx")
w("    jmp ylog_norm")
w("ylog_norm_done:")
w("    movq %xmm5, %rax                     # r's bits")
w("    mov %rax, %rdx")
w("    shr $52, %rdx")
w("    and $2047, %rdx                     # the field of r, before the mask")
w("    mov $%d, %%r10" % MASK)
w("    and %r10, %rax                      # the mantissa's 52 bits")
w("    mov $%d, %%r10" % HALFPAT)
w("    or %r10, %rax                       # at exponent 1022, so in [0.5, 1)")
w("    movq %rax, %xmm2                     # m")
w("    sub $1022, %rdx")
w("    sub %rcx, %rdx                      # e = field - 1023 - guard")
if WHICH == "m":
    w("    movq %xmm2, %rax")
    w("    ret")
if WHICH == "e":
    w("    mov %rdx, %rax")
    w("    ret")
w("")
w("# if (m < inv_sqrt2) { m = m*2; e = e-1 }, so the kernel's |z| stays at")
w("# sqrt(2)-1 rather than reaching 1.")
w("    movsd " + is2 + ", %xmm8")
w("    ucomisd %xmm8, %xmm2                # m against 1/sqrt(2)")
w("    jae ylog_m_ok")
w("    movsd %xmm2, %xmm8")
w("    mulsd " + two + ", %xmm8")
w("    movsd %xmm8, %xmm2")
w("    sub $1, %rdx")
w("ylog_m_ok:")
w("    cvtsi2sd %rdx, %xmm6                # xmm6 = ef, the exponent as a double")
if WHICH == "ef":
    w("    movq %xmm6, %rax")
    w("    ret")
w("")
w("# log_z(m): z = (m-1)/(m+1), and z_lo the error of that division. m-1 is exact")
w("# (Sterbenz) and the division rounds once, but m+1 rounds too and its half an")
w("# ulp of 2 is a WHOLE ulp of z, which would be the whole budget. bb = den - m")
w("# and derr = (m - (den - bb)) + (1.0 - bb) is the denominator's residual by")
w("# two_sum, and one more divide turns it into z's.")
w("    movsd %xmm2, %xmm0")
w("    subsd " + one + ", %xmm0            # num = m - 1.0")
w("    movsd %xmm2, %xmm1")
w("    addsd " + one + ", %xmm1            # den = m + 1.0")
w("    movsd %xmm1, %xmm8")
w("    subsd %xmm2, %xmm8                  # bb = den - m")
w("    movsd %xmm1, %xmm3")
w("    subsd %xmm8, %xmm3                  # den - bb")
w("    movsd %xmm2, %xmm4")
w("    subsd %xmm3, %xmm4                  # m - (den - bb)")
w("    movsd " + one + ", %xmm3")
w("    subsd %xmm8, %xmm3                  # 1.0 - bb")
w("    addsd %xmm3, %xmm4                  # derr")
w("    divsd %xmm1, %xmm0                  # z = num/den")
w("    movsd %xmm0, %xmm7")
w("    mulsd %xmm4, %xmm7                  # z * derr")
w("    movsd " + zero + ", %xmm8")
w("    subsd %xmm7, %xmm8                  # 0.0 - z*derr")
w("    divsd %xmm1, %xmm8                  # xmm8 = z_lo")
if WHICH == "z":
    w("    movq %xmm0, %rax")
    w("    ret")
if WHICH == "zlo":
    w("    movq %xmm8, %rax")
    w("    ret")
w("    addsd %xmm8, %xmm0                  # z = z + z_lo")
w("    movsd %xmm0, %xmm3")
w("    mulsd %xmm0, %xmm3                  # w = z*z")
if WHICH == "w":
    w("    movq %xmm3, %rax")
    w("    ret")
w("")
w("# P = poly_split(log_k, log_kl, w): two Horner chains over the split table, so")
w("# a term whose low part would fall off the end of a double is kept.")
w("    movsd " + K[N] + ", %xmm2")
w("    movsd " + KL[N] + ", %xmm9")
for i in range(N - 1, -1, -1):
    w("    mulsd %xmm3, %xmm2")
    w("    addsd " + K[i] + ", %xmm2")
    w("    mulsd %xmm3, %xmm9")
    w("    addsd " + KL[i] + ", %xmm9")
w("    addsd %xmm9, %xmm2                  # P")
if WHICH == "P":
    w("    movq %xmm2, %rax")
    w("    ret")
w("")
w("# (z*(2 + w*P)) + (ef*ln2_hi) + (ef*ln2_lo), in that order: the small z part")
w("# first and each large half at its own scale, which is the only order that")
w("# keeps z's low bits.")
w("    movsd %xmm3, %xmm7")
w("    mulsd %xmm2, %xmm7                  # w*P")
w("    addsd " + two + ", %xmm7            # 2 + w*P")
w("    mulsd %xmm7, %xmm0                  # z*(2 + w*P)")
w("    movsd %xmm6, %xmm7")
w("    mulsd " + ln2h + ", %xmm7")
w("    addsd %xmm7, %xmm0")
w("    movsd %xmm6, %xmm7")
w("    mulsd " + ln2l + ", %xmm7")
w("    addsd %xmm7, %xmm0")
w("    movq %xmm0, %rax")
w("    ret")
w("ylog_nan:")
w("# The module's `nan` is `0.0 / 0.0`, so the NaN is COMPUTED rather than stored:")
w("# a table entry would have to be written down, and the default NaN carries the")
w("# sign bit (0xFFF8000000000000), so the one you would write from memory --")
w("# 0x7FF8000000000000 -- is a different double from the one the Y returns. One")
w("# divide is the same instruction the module itself runs.")
w("    movsd " + zero + ", %xmm0")
w("    divsd %xmm0, %xmm0")
w("    movq %xmm0, %rax")
w("    ret")
w("ylog_pinf:")
w("    movsd " + pinf + ", %xmm0")
w("    movq %xmm0, %rax")
w("    ret")
w("ylog_ninf:")
w("    movsd " + ninf + ", %xmm0")
w("    movq %xmm0, %rax")
w("    ret")
w("")

emit(sys.argv[1] if len(sys.argv) > 1 else None, w_, t)
print("# generated %d lines, %d table entries (%d bytes)"
      % (len(w_.lines), len(t.entries), 8 * len(t.entries)), file=sys.stderr)