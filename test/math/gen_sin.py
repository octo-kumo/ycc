#!/usr/bin/env python3
"""Generate y_sin and y_cos -- the routines test/y/native/t313_math_sin_asm.y gates.

    python3 test/math/gen_sin.py [OUT.s] [STAGE]

Run from the repository root. STAGE is `full`, or one of n/r/s/c/out, which returns
that intermediate instead of the answer -- how a divergence gets localised: return
the quadrant, the reduced argument, sin r, cos r, and compare against the Y
version's own value at that point. The same probes found four bugs in y_exp's
first attempt and three in y_log's (§8 of ideas/math.md).

To land a change to sin or cos: edit src/y/std/math.y, run this, write the result
over the y_sin block in src/y/arch/math.s, and run t313.

Every constant is READ OUT of src/y/std/math.py rather than copied: the promise is
that this returns the same double as the Y, so a table typed by hand is a table
that can disagree with the oracle, and nothing in the build would notice. The
operation sequence mirrors the Y line for line, because that is what makes the
bits match:

    n = to_int(floor(x*two_over_pi + 0.5))  -> one cvttsd2si, one correction
    r = rem_pio2(x, n)                     -> four products, two of them
        compensated by prod_err, subtracted one at a time
    s, c = sin_cos_k(r)                    -> two split kernels, x*x computed once
    q = quadrant(n)                        -> n & 3, which is the same answer as
        the Y's `n % 4` adjusted upwards, for every n including the negative ones

Three things about the selection, which is the one part of this that is not a
line-for-line copy:

* ONE body serves both. `y_sin` and `y_cos` are two-line entry blocks into a
  shared `ysincos_go`, with the choice in %r11, so a program that calls neither costs
  nothing and a program that calls both carries the arithmetic once. The
  shake_refs fall-through keeps `ysincos_go` for either entry.
* the index is `(q + which) & 3`, because cos's table is sin's rotated left by
  one: sin answers [s, c, -s, -c] for q = 0..3 and cos [c, -s, -c, s], which is the
  same table one place along. Then the answer is s when the index is even, c when
  it is odd, and negated when bit 1 is set -- two tests instead of eight cases.
* the negation is `0.0 - x` from a zero register, the way the Y writes it, and not
  a sign-bit flip: `0.0 - 0.0` is +0.0, which is what the Y's `0.0 - sc[0]` gives,
  and the difference is visible in sin(-0.0).
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from genlib import Table, Writer, bits, emit, let_float, let_floats  # noqa: E402

WHICH = sys.argv[2] if len(sys.argv) > 2 else "full"

# ── the constants, read not copied ────────────────────────────────────────
two_over_pi = let_float("two_over_pi")
pio2_1 = let_float("pio2_1")
pio2_1t = let_float("pio2_1t")
pio2_2 = let_float("pio2_2")
pio2_2t = let_float("pio2_2t")
pi_over_4 = let_float("pi_over_4")
sin_k = let_floats("sin_k")
sin_kl = let_floats("sin_kl")
cos_k = let_floats("cos_k")
cos_kl = let_floats("cos_kl")
NS, NC = len(sin_k) - 1, len(cos_k) - 1
assert len(sin_k) == len(sin_kl) and NS == 5, (len(sin_k), len(sin_kl))
assert len(cos_k) == len(cos_kl) and NC == 7, (len(cos_k), len(cos_kl))


# The same kernels in Python, in the same order: if they do not match the
# platform's libm over a spread of arguments, the tables were mis-parsed and
# everything after this line is wrong.
def poly(co, clo, w):
    p, q = co[-1], clo[-1]
    for i in range(len(co) - 2, -1, -1):
        p = p * w + co[i]
        q = q * w + clo[i]
    return p + q


def prod_err(a, b, p):
    ca = 134217729.0 * a
    ah = ca - (ca - a)
    al = a - ah
    cb = 134217729.0 * b
    bh = cb - (cb - b)
    bl = b - bh
    return ((ah * bh - p) + ah * bl + al * bh) + al * bl


def rem_pio2(x, n):
    nf = float(n)
    p1 = nf * pio2_1
    p1t = nf * pio2_1t
    p2 = nf * pio2_2
    p2t = nf * pio2_2t
    err = prod_err(nf, pio2_1, p1) + prod_err(nf, pio2_1t, p1t)
    return ((((x - p1) - p1t) - p2) - p2t) - err


def sc_k(r):
    s = r * (1.0 + r * r * poly(sin_k, sin_kl, r * r))
    w = r * r
    return s, 1.0 - w * poly(cos_k, cos_kl, w)


def model(x, which):
    import math
    if x != x or math.isinf(x):
        return float("nan")
    if -pi_over_4 <= x <= pi_over_4:
        s, c = sc_k(x)
        return s if which == 0 else c
    n = math.floor(x * two_over_pi + 0.5)
    s, c = sc_k(rem_pio2(x, n))
    q = n % 4
    if q < 0:
        q += 4
    idx = (q + which) & 3
    v = s if (idx & 1) == 0 else c
    return 0.0 - v if (idx & 2) != 0 else v


import math  # noqa: E402
for _which in (0, 1):
    for _x in (0.0, 0.3, -0.3, 0.7853981633974483, -0.7853981633974483,
               1.0, 2.0, 1.5707963267948966, 3.141592653589793,
               100.0, -100.0, 1e6, 1e-6, 6.283185307179586):
        _want = math.sin(_x) if _which == 0 else math.cos(_x)
        _got = model(_x, _which)
        _tol = 4e-16 * max(1.0, abs(_want))
        assert abs(_got - _want) <= _tol, (_which, _x, _got, _want)

# ── the table ─────────────────────────────────────────────────────────────
t = Table("ysincos_tab", "ysincos_tab: the trigonometry's constants and both split kernels, one "
       "label for the lot (a label per entry costs the shaker ~2K instructions of "
       "fixpoint each, on every compile). Read as ysincos_tab+N(%rip), N = 8*index.")
top = t.add("two_over_pi", two_over_pi)
p21 = t.add("pio2_1", pio2_1)
p21t = t.add("pio2_1t", pio2_1t)
p22 = t.add("pio2_2", pio2_2)
p22t = t.add("pio2_2t", pio2_2t)
p4 = t.add("pi_over_4", pi_over_4)
np4 = t.add("neg_pi_over_4", -pi_over_4)
half = t.add("half", 0.5)
one = t.add("one", 1.0)
two = t.add("two", 2.0)
zero = t.add("zero", 0.0)
c2p27 = t.add("2p27_plus_1", 134217729.0)      # prod_err's splitting constant
pinf = t.add("pinf", float("inf"))
ninf = t.add("ninf", float("-inf"))
SK = [t.add("sk%d" % i, v) for i, v in enumerate(sin_k)]
SKL = [t.add("skl%d" % i, v) for i, v in enumerate(sin_kl)]
CK = [t.add("ck%d" % i, v) for i, v in enumerate(cos_k)]
CKL = [t.add("ckl%d" % i, v) for i, v in enumerate(cos_kl)]

# ── the routine ───────────────────────────────────────────────────────────
# The shared body, ysincos_go: %r11 is 0 for sin and 1 for cos, %r10 is n. The two
# entry blocks are two instructions each and the shaker keeps ysincos_go for either.
#
# Inside ysincos_go: xmm9 x, xmm10 nf, xmm11 p1, xmm12 p1t, xmm13 p2, xmm14 p2t,
# xmm15 err, and after the reduction xmm3 r, xmm0 w, xmm1 scratch, xmm2 P,
# xmm4 P's low half, xmm5 scratch, xmm6 s, xmm7 c.
#
# prod_err takes a in xmm0, b in xmm1 and p in xmm8 (so the caller keeps x safe),
# works in xmm2..xmm7, and answers in xmm0. It touches no GPR, so n in %r10 and
# the choice in %r11 survive the calls.

w_ = Writer()
w = w_.w

w("# The trigonometry: sin and cos, one body for both. GENERATED by")
w("# test/math/gen_sin.py from src/y/std/math.y's own constants -- do not retype")
w("# the table (see that file's note). The sequence is the Y's line for line,")
w("# which is what makes the answers the same doubles rather than near ones.")
w("#")
w("# The two entry blocks are two instructions each. The shake_refs fall-through")
w("# keeps ysincos_go for either one, so a program that calls only sin carries only")
w("# sin's entry, and one that calls both carries the arithmetic once.")
w("#")
w("# Argument at 8(%rsp) (the last and only one), answer's bits in %rax.")
w("y_sin:")
w("    xor %r11, %r11                      # sin")
w("    jmp ysincos_go")
w("y_cos:")
w("    mov $1, %r11                         # cos")
w("ysincos_go:")
w("    mov 8(%rsp), %rax")
w("    movq %rax, %xmm9                    # xmm9 = x")
w("# if (x != x || is_inf(x)) return nan. The self-comparison is the NaN test --")
w("# PF is set only for the unordered result -- and the two infinities are")
w("# compared against, because an infinite self-comparison is EQUAL and not")
w("# unordered, so the same trick that finds a NaN cannot find an infinity.")
w("    ucomisd %xmm9, %xmm9")
w("    jp ysincos_nan")
w("    movsd " + pinf + ", %xmm0")
w("    ucomisd %xmm0, %xmm9")
w("    je ysincos_nan")
w("    movsd " + ninf + ", %xmm0")
w("    ucomisd %xmm0, %xmm9")
w("    je ysincos_nan")
w("# if (x >= -pi_over_4 && x <= pi_over_4) then r = x and n = 0, which falls into")
w("# the same kernel and the same selection: q = 0, so sin takes s and cos takes c,")
w("# with no sign to apply. The Y returns sin_cos_k(x) directly here and the two")
w("# paths agree, which is worth saying because a smaller argument does not need")
w("# a reduction only because pi/4 is the point where the kernel's argument is")
w("# still short enough to be exact.")
w("    movsd " + np4 + ", %xmm0")
w("    ucomisd %xmm0, %xmm9")
w("    jl ysincos_reduce")
w("    movsd " + p4 + ", %xmm0")
w("    ucomisd %xmm0, %xmm9")
w("    jg ysincos_reduce")
w("    movsd %xmm9, %xmm3                   # r = x")
w("    xor %r10, %r10                      # n = 0")
w("    jmp ysincos_kernel")
w("ysincos_reduce:")
w("# n = to_int(floor(x*two_over_pi + 0.5))")
w("    movq %xmm9, %xmm0")
w("    mulsd " + top + ", %xmm0")
w("    addsd " + half + ", %xmm0             # t")
w("    cvttsd2si %xmm0, %rax")
w("    cvtsi2sd %rax, %xmm1")
w("    ucomisd %xmm0, %xmm1")
w("    jbe ysincos_n_ok")
w("    sub $1, %rax")
w("ysincos_n_ok:")
w("    mov %rax, %r10                        # n")
w("    cvtsi2sd %rax, %xmm10                # nf")
w("# r = rem_pio2(x, n). The four products of n with the four pieces of pi/2 are")
w("# taken together, and two of them are compensated: n*pio2_1 needs more than 53")
w("# bits once n passes 2^21 and n*pio2_1t once n passes 2^10, while the other two")
w("# are 3.5e-27 and below, where the rounding is twenty orders under the answer's")
w("# last bit however large n grows. That is why there are two prod_err calls and")
w("# not four.")
w("    movsd %xmm10, %xmm11")
w("    mulsd " + p21 + ", %xmm11            # p1")
w("    movsd %xmm10, %xmm12")
w("    mulsd " + p21t + ", %xmm12           # p1t")
w("    movsd %xmm10, %xmm13")
w("    mulsd " + p22 + ", %xmm13            # p2")
w("    movsd %xmm10, %xmm14")
w("    mulsd " + p22t + ", %xmm14           # p2t")
w("    movsd %xmm10, %xmm0")
w("    movsd " + p21 + ", %xmm1")
w("    movsd %xmm11, %xmm8")
w("    call ysincos_prod_err")
w("    movsd %xmm0, %xmm15                  # err, the first half")
w("    movsd %xmm10, %xmm0")
w("    movsd " + p21t + ", %xmm1")
w("    movsd %xmm12, %xmm8")
w("    call ysincos_prod_err")
w("    addsd %xmm0, %xmm15                  # err")
w("# ((((x - p1) - p1t) - p2) - p2t) - err, one subtraction at a time: the sum of")
w("# the four pieces is what has to be small, and only a running difference keeps")
w("# it that way.")
w("    movsd %xmm9, %xmm0")
w("    subsd %xmm11, %xmm0")
w("    subsd %xmm12, %xmm0")
w("    subsd %xmm13, %xmm0")
w("    subsd %xmm14, %xmm0")
w("    subsd %xmm15, %xmm0")
w("    movsd %xmm0, %xmm3                   # r")
if WHICH == "n":
    w("    mov %r10, %rax")
    w("    ret")
if WHICH == "r":
    w("    movq %xmm3, %rax")
    w("    ret")
w("ysincos_kernel:")
w("# sin_cos_k(r): s = r*(1 + r*r*poly_split(sin_k, sin_kl, r*r)) and")
w("# c = 1.0 - w*poly_split(cos_k, cos_kl, w) with w = r*r. The Y computes r*r")
w("# twice, once for the kernel's argument and once for the multiply, and both")
w("# are the same double, so it is computed once here.")
w("    movsd %xmm3, %xmm0")
w("    mulsd %xmm3, %xmm0                   # w = r*r")
w("    movsd %xmm0, %xmm1                   # w again, for the cos kernel")
w("    movsd " + SK[NS] + ", %xmm2          # sin's P, high")
w("    movsd " + SKL[NS] + ", %xmm4         # sin's P, low")
for i in range(NS - 1, -1, -1):
    w("    mulsd %xmm0, %xmm2")
    w("    addsd " + SK[i] + ", %xmm2")
    w("    mulsd %xmm0, %xmm4")
    w("    addsd " + SKL[i] + ", %xmm4")
w("    addsd %xmm4, %xmm2                   # P")
# s = r*(1 + w*P), in the Y's order and no other: x*x, then w*P, then the
# 1.0, then the multiply by r LAST. Folding r in early -- r*(1 + r*w*P), which
# is the same formula to a mathematician -- moves a rounding and put sin(0.5)
# at 0.48971277 against the Y's 0.47942554, a 2% error that no 6-term kernel
# could ever have. The multiply by r is the last instruction, not the first.
w("    movsd %xmm0, %xmm5")
w("    mulsd %xmm2, %xmm5                   # w*P")
w("    addsd " + one + ", %xmm5             # 1 + w*P")
w("    mulsd %xmm3, %xmm5                   # times r")
w("    movsd %xmm5, %xmm6                   # s")
w("    movsd " + CK[NC] + ", %xmm2          # cos's P, high")
w("    movsd " + CKL[NC] + ", %xmm4         # cos's P, low")
for i in range(NC - 1, -1, -1):
    w("    mulsd %xmm1, %xmm2")
    w("    addsd " + CK[i] + ", %xmm2")
    w("    mulsd %xmm1, %xmm4")
    w("    addsd " + CKL[i] + ", %xmm4")
w("    addsd %xmm4, %xmm2                   # P")
w("    mulsd %xmm1, %xmm2                   # w*P")
w("    movsd " + one + ", %xmm7")
w("    subsd %xmm2, %xmm7")
w("    movsd %xmm7, %xmm7                   # c")
if WHICH == "s":
    w("    movq %xmm6, %rax")
    w("    ret")
if WHICH == "c":
    w("    movq %xmm7, %rax")
    w("    ret")
w("# The selection. cos's table is sin's rotated left by one -- sin answers")
w("# [s, c, -s, -c] and cos [c, -s, -c, s] -- so the index is (q + which) & 3, and")
w("# `n & 3` is the Y's quadrant(n) for every n including the negative ones (its")
w("# `n % 4` then `+4` is the low two bits read as unsigned). Then the answer is s")
w("# where the index is even, c where it is odd, and negated where bit 1 is set:")
w("# two tests rather than eight cases.")
w("    mov %r10, %rax")
w("    add %r11, %rax")
w("    and $3, %rax")
if WHICH == "out":
    w("    ret")
w("    test $1, %rax")
w("    jnz ysincos_pick_c")
w("    movsd %xmm6, %xmm7                   # s into the answer's place")
w("    jmp ysincos_sign")
w("ysincos_pick_c:")
w("    movsd %xmm7, %xmm6")
w("ysincos_sign:")
w("    test $2, %rax")
w("    jz ysincos_done")
w("# The negation is `0.0 - answer` from a zero register, the way the Y writes")
w("# it, and not a sign-bit flip: 0.0 - 0.0 is +0.0, which is what the Y's")
w("# `0.0 - sc[0]` gives, and the difference shows in sin(-0.0).")
w("    movsd " + zero + ", %xmm5")
w("    subsd %xmm6, %xmm5")
w("    movsd %xmm5, %xmm6")
w("ysincos_done:")
w("    movq %xmm6, %rax")
w("    ret")
w("ysincos_nan:")
w("# The module's `nan` is `0.0 / 0.0`, so the NaN is COMPUTED rather than stored:")
w("# the default NaN carries the sign bit (0xFFF8000000000000), so the one you")
w("# would write from memory is a different double from the one the Y returns.")
w("    movsd " + zero + ", %xmm0")
w("    divsd %xmm0, %xmm0")
w("    movq %xmm0, %rax")
w("    ret")
w("")
w("# ysincos_prod_err(a, b, p) -> the error of a*b given the rounded product p.")
w("# prod_err splits each factor into a head and a tail by multiplying by")
w("# 134217729 = 2^27+1 and subtracting, which leaves the head exact and the tail")
w("# as what is left; then ah*bh - p is the whole error and the three cross terms")
w("# are what a plain product would have thrown away. a in xmm0, b in xmm1, p in")
w("# xmm8, the answer in xmm0. No GPR is touched, so n in %r10 and the choice in")
w("# %r11 survive the call.")
w("ysincos_prod_err:")
w("    movsd " + c2p27 + ", %xmm2")
w("# a -> ah in xmm7, al in xmm5. Four values are live at once here (ah, al,")
w("# bh, bl), so the four registers are fixed and said out loud: ah xmm7, al")
w("# xmm5, bh xmm6, bl xmm4, and %xmm3 is the scratch the sums go through.")
w("# ah got its own register because the b split wanted the one it was in:")
w("# sharing it computed (bh*bl - p) + bh*bl + al*bh + al*bl, which is not an")
w("# error term at all -- with a = 0 it returned bh*bl where the Y returns 0,")
w("# and every argument below pi/4 came out with 4.39e-8 added to it (the")
w("# reduction's r = x - err, and err was that much).")
w("    movsd %xmm2, %xmm3")
w("    mulsd %xmm0, %xmm3                    # ca = 2^27+1 times a")
w("    movsd %xmm3, %xmm4")
w("    subsd %xmm0, %xmm4                   # ca - a")
w("    movsd %xmm3, %xmm7")
w("    subsd %xmm4, %xmm7                   # ah = ca - (ca - a)")
w("    movsd %xmm0, %xmm5")
w("    subsd %xmm7, %xmm5                   # al = a - ah")
w("# b -> bh in xmm6, bl in xmm4")
w("    movsd %xmm2, %xmm3")
w("    mulsd %xmm1, %xmm3                    # cb = 2^27+1 times b")
w("    movsd %xmm3, %xmm4")
w("    subsd %xmm1, %xmm4                   # cb - b")
w("    movsd %xmm3, %xmm6")
w("    subsd %xmm4, %xmm6                   # bh = cb - (cb - b)")
w("    movsd %xmm1, %xmm4")
w("    subsd %xmm6, %xmm4                   # bl = b - bh")
w("# ((ah*bh - p) + ah*bl + al*bh) + al*bl, in that order")
w("    movsd %xmm7, %xmm0")
w("    mulsd %xmm6, %xmm0                    # ah*bh")
w("    subsd %xmm8, %xmm0                   # - p")
w("    movsd %xmm7, %xmm3")
w("    mulsd %xmm4, %xmm3                    # ah*bl")
w("    addsd %xmm3, %xmm0")
w("    movsd %xmm5, %xmm3")
w("    mulsd %xmm6, %xmm3                    # al*bh")
w("    addsd %xmm3, %xmm0")
w("    movsd %xmm5, %xmm3")
w("    mulsd %xmm4, %xmm3                    # al*bl")
w("    addsd %xmm3, %xmm0")
w("    ret")
w("")

emit(sys.argv[1] if len(sys.argv) > 1 else None, w_, t)
print("# generated %d lines, %d table entries (%d bytes)"
      % (len(w_.lines), len(t.entries), 8 * len(t.entries)), file=sys.stderr)
