#!/usr/bin/env python3
"""Generate y_pow -- the routine test/y/native/t315_math_pow_asm.y gates.

    python3 test/math/gen_pow.py [OUT.s] [STAGE]

Run from the repository root. STAGE is `full`, or one of the intermediates
(`int`, `pos`, `l2`, `e2`), which returns that one instead of the answer -- how a
divergence gets localised, the way gen_exp.py and gen_log.py do it (§8 of
ideas/math.md).

To land a change to pow: edit src/y/std/math.y, run this, write the result over
the y_pow block in src/y/arch/math.s, and run t315.

Every constant is READ OUT of src/y/std/math.y rather than copied, and the
operation sequence mirrors the Y line for line: `pow_y` is the oracle and the
promise is the same double, not a close one.

WHAT MAKES POW THE ODD ONE OUT

`exp` and `log` are a reduction and a kernel, and each is a leaf: the argument
comes off the stack and the answer's bits go back in %rax. `pow` is three
routines and a dispatch, so it is the first thing in math.s that CALLS anything
other than a helper it is holding registers for, and that decides its shape:

* y_pow has a frame (`push %rbp`), because it calls, and the calls would
  otherwise land their return address on the caller's arguments. x and y are
  read into %rbp-relative slots once and reloaded after each call. Only y
  survives a call: log2_dd returns two registers and nothing else is live across
  the two calls.
* The internal convention is float arguments in %xmm0/%xmm1 and long ones in
  %rdi, answers back in %xmm0 (plus %xmm1 for a pair). Every xmm register is
  caller-saved, so a value that has to outlive a call lives in memory -- which is
  why log2_dd answers a PAIR in two registers rather than in the module-level
  cells the Y uses (`log2_hi`, `log2_lo`, `ts_lo`, `z_lo`).
* `prod_err` is INLINED into both paths that need it rather than called. It is
  twenty-odd instructions and it is the one call whose answer has to survive
  further arithmetic, so calling it would cost a spill and a reload in each of
  the three places; inlining costs the instructions twice and nothing at run
  time. (`y_prod_err`, the copy the trigonometry block emits, is still there for
  a caller that wants it whole.)
* The exponent kernel is a SECOND copy of y_exp's polynomial, reading the same
  `yexp_tab`. Sharing it would mean y_exp calling a helper, and y_exp's live
  values at that point are t in %xmm2, k in %rcx and f2 in %xmm6 -- all
  caller-saved, so the call would cost a spill and two reloads in exp's own hot
  path to save twenty-eight instructions of code that only a program using both
  exp and pow carries twice.
"""
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from genlib import Table, Writer, bits, emit, let_float, let_floats  # noqa: E402

WHICH = sys.argv[2] if len(sys.argv) > 2 else "full"

# ── the constants, read not copied ─────────────────────────────────────────
one = let_float("one") if False else 1.0     # `one` is a name in the table, not a module constant
half = 0.5
two = 2.0
zero = 0.0
pinf = float("inf")
ninf = float("-inf")
# The module's `nan` is `0.0 / 0.0`, and x86's default NaN CARRIES THE SIGN BIT
# (0xFFF8000000000000), so the oracle's NaN is not the one Python writes. Every
# NaN the model returns is this pattern, because every NaN the Y returns is the
# one constant -- and the assembly computes it with a divide for the same reason.
NAN_BITS = -2251799813685248                       # 0xFFF8000000000000
NAN = struct.unpack("<d", struct.pack("<q", NAN_BITS))[0]
assert struct.unpack("<Q", struct.pack("<d", NAN))[0] == 0xFFF8000000000000, hex(NAN_BITS)
inv_sqrt2 = let_float("inv_sqrt2")
ln2 = let_float("ln2")
ln2_hi = let_float("ln2_hi")
ln2_lo = let_float("ln2_lo")
inv_ln2 = let_float("inv_ln2")
inv_ln2_lo = let_float("inv_ln2_lo")
log_k = let_floats("log_k")
log_kl = let_floats("log_kl")
exp_k = let_floats("exp_k")
exp_kl = let_floats("exp_kl")
NL = len(log_k) - 1
NE = len(exp_k) - 1
assert len(log_k) == len(log_kl), (len(log_k), len(log_kl))
assert len(exp_k) == len(exp_kl), (len(exp_k), len(exp_kl))

# exp_field and the bit helpers, as the module writes them
TWO52 = 4503599627370496
MANTISSA_MASK = 4503599627370495
HALF_BITS = 4602678819172646912      # bits(0.5)
SIGN_BIT = -9223372036854775808      # 2^63, which no long holds


def exp_field(x: float) -> int:
    return (struct_bits(x) >> 52) & 2047


def struct_bits(x: float) -> int:
    import struct
    return struct.unpack("<Q", struct.pack("<d", x))[0]


def is_inf(x: float) -> bool:
    return x == pinf or x == ninf


def is_nan(x: float) -> bool:
    return x != x


def prod_err(a: float, b: float, p: float) -> float:
    """The Y's prod_err, in the Y's order."""
    ca = 134217729.0 * a
    ah = ca - (ca - a)
    al = a - ah
    cb = 134217729.0 * b
    bh = cb - (cb - b)
    bl = b - bh
    return ((ah * bh - p) + ah * bl + al * bh) + al * bl


def poly_split(co, clo, w):
    n = len(co) - 1
    p, q = co[n], clo[n]
    for i in range(n - 1, -1, -1):
        p = p * w + co[i]
        q = q * w + clo[i]
    return p + q


class TwoSum:
    """The Y's two_sum, which leaves its residual in a module-level cell."""

    def __init__(self):
        self.lo = 0.0

    def __call__(self, a: float, b: float) -> float:
        s = a + b
        bb = s - a
        self.lo = (a - (s - bb)) + (b - bb)
        return s


def frexp_bits(x: float):
    """The Y's frexp: [the fraction's own bits, the exponent]."""
    if is_nan(x) or x == 0.0 or is_inf(x):
        return struct_bits(x), 0
    r, guard = x, 0
    while guard < 60 and exp_field(r) == 0 and r != 0.0:
        r = r * 2.0
        guard += 1
    e = exp_field(r)
    if e == 0:
        return struct_bits(0.0), 0
    frac = ((struct_bits(r) & MANTISSA_MASK) | HALF_BITS)
    signed = frac + SIGN_BIT if x < 0.0 else frac
    return signed, e - 1022 - guard


def ldexp(x: float, k: int) -> float:
    if is_nan(x) or x == 0.0 or is_inf(x):
        return x
    r, k = x, k
    up, down = 1022, -1022
    while k >= up:
        r = r * 4.49423283715578977e307
        k -= up
    while k <= down:
        r = r * 2.2250738585072014e-308
        k -= down
    f = exp_field(r)
    if f == 0 or f + k < 1:
        step = -1 if k < 0 else 1
        rest = k
        while rest != 0:
            r = r * (0.5 if step < 0 else 2.0)
            rest -= step
    elif k != 0:
        b = struct_bits(r)
        neg = b < 0
        u = b & 0x7FFFFFFFFFFFFFFF
        shifted = u + k * TWO52
        r = from_bits((shifted + SIGN_BIT) if neg else shifted)
    return r


def from_bits(b: int) -> float:
    import struct
    return struct.unpack("<d", struct.pack("<q", b & 0xFFFFFFFFFFFFFFFF if b >= 0 else b))[0]


def log2_dd(x: float):
    """The Y's log2_dd: (the natural log, and what the summation lost)."""
    if is_nan(x) or x < 0.0:
        return NAN, 0.0
    if x == 0.0:
        return ninf, 0.0
    if is_inf(x):
        return pinf, 0.0
    pb, e = frexp_bits(x)
    m = from_bits(pb)
    if m < inv_sqrt2:
        m = m * 2.0
        e -= 1
    ts = TwoSum()
    num, den = m - 1.0, m + 1.0
    bb = den - m
    derr = (m - (den - bb)) + (1.0 - bb)
    z = num / den
    z_lo = 0.0 - (z * derr) / den
    z = z + z_lo
    w = z * z
    ef = float(e)
    a = z * (two + w * poly_split(log_k, log_kl, w))
    b = ts(ef * ln2_hi, ef * ln2_lo)
    bc_lo = ts.lo
    t = ts(a, b)
    return t, ts.lo + bc_lo


def exp2_corr(p: float, q: float) -> float:
    """The Y's exp2_corr."""
    if is_nan(p):
        return p
    if p > 1024.0:
        return pinf
    if p < -1075.0:
        return 0.0
    import math
    n = float(math.floor(p + 0.5))
    s = (p - n) + q
    t = s * ln2
    k = int(n)
    f2 = 1.0
    if n > 1023.0:
        k -= 1
        f2 = 2.0
    hi = f2 * (one + t * (one + t * poly_split(exp_k, exp_kl, t)))
    lo = hi * prod_err(s, ln2, t)
    return ldexp(hi, k) + ldexp(lo, k)


def pow_int(x: float, n: int) -> float:
    neg = n < 0
    k = -n if neg else n
    r, b = 1.0, x
    kk = k
    while kk > 0:
        if kk % 2 == 1:
            r = r * b
        b = b * b
        kk = kk // 2
    return fdiv(one, r) if neg else r


def fdiv(a: float, b: float) -> float:
    """IEEE division, because Python raises where the hardware answers.

    Only one call in the whole model can reach it -- pow_int's reciprocal, when
    a power has already underflowed to 0.0 -- and there the answer is an infinity
    with the dividend's sign, which is what the Y's `1.0 / r` gives.
    """
    if b != 0.0:
        return a / b
    if a != a or a == 0.0:
        return NAN
    return pinf if (a > 0.0) == (not struct_bits(b) >> 63 & 1) else ninf


def is_int(y: float) -> bool:
    import math
    return y == math.floor(y)


def trunc(y: float) -> float:
    import math
    return math.trunc(y)


def odd_int(y: float) -> bool:
    """`is_int(y) && trunc(y/2)*2 != y` -- the parity of an integer exponent."""
    return is_int(y) and trunc(y / 2.0) * 2.0 != y


def pow_model(x: float, y: float) -> float:
    """The Y's pow, as the oracle computes it."""
    if y == 0.0:
        return one
    if is_nan(x) or is_nan(y):
        return NAN
    if x == 1.0 or x == -1.0:
        return -1.0 if (x == -1.0 and odd_int(y)) else one
    if y == 1.0:
        return x
    if x == 0.0:
        if y < 0.0:
            return pinf
        return -0.0 if odd_int(y) else 0.0
    if is_inf(x):
        if y < 0.0:
            return 0.0
        return ninf if (x < 0.0 and odd_int(y)) else pinf
    if x < 0.0:
        if not is_int(y):
            return NAN
        if -1024.0 <= y <= 1024.0:
            return pow_int(x, int(y))
        v = pow_pos_model(0.0 - x, y)
        return 0.0 - v if trunc(y / 2.0) * 2.0 != y else v
    if is_int(y) and -1024.0 <= y <= 1024.0:
        return pow_int(x, int(y))
    return pow_pos_model(x, y)


def pow_pos_model(x: float, y: float) -> float:
    l, log2_lo = log2_dd(x)
    u = y * inv_ln2
    p = u * l
    q = prod_err(u, l, p) + u * log2_lo + l * (prod_err(y, inv_ln2, u) + y * inv_ln2_lo)
    return exp2_corr(p, q)


def model(x: float, y: float) -> float:
    """What the assembly should return; libm is the sanity check, not the oracle."""
    if WHICH == "int":
        return pow_model(x, y)
    if WHICH == "pos":
        return pow_pos_model(x, y) if x > 0.0 else NAN
    if WHICH == "l2":
        return log2_dd(x)[0]
    if WHICH == "e2":
        return exp2_corr(x, y)
    return pow_model(x, y)


if __name__ == "__main__" and os.environ.get("POW_MODEL_CHECK"):
    import math
    import random
    random.seed(20261005)
    worst, over, zero = 0.0, 0, 0
    for _ in range(4000):
        x = math.exp(random.uniform(-30, 30))
        y = random.uniform(-40, 40)
        got = model(x, y)
        try:
            want = math.pow(x, y)
        except OverflowError:
            over += 1
            continue
        if want == 0.0:
            zero += 1
            continue
        if math.isfinite(want) and math.isfinite(got):
            worst = max(worst, abs(got - want) / want)
    print("model: %d pairs, worst relative gap against libm %.3g (%d overflowed, %d flushed)"
          % (4000, worst, over, zero))
    raise SystemExit(0)


# ── the tables ─────────────────────────────────────────────────────────────
t = Table("ypow_tab",
          "ypow_tab: pow's own constants, one label for the lot (a label per "
          "entry costs the shaker ~2K instructions of fixpoint each, on every "
          "compile). Read as ypow_tab+N(%rip), N = 8*index. The logarithm's "
          "kernel and the exponent's are NOT here: they are ylog_tab's and "
          "yexp_tab's, read where they already are, because the same "
          "coefficients in two tables is a table that can disagree with itself.")
ONE = t.add("one", 1.0)
NEG_ONE = t.add("neg_one", -1.0)
ZERO = t.add("zero", 0.0)
HALF = t.add("half", 0.5)
TWO = t.add("two", 2.0)
PINF = t.add("pinf", pinf)
NINF = t.add("ninf", ninf)
P1024 = t.add("p1024", 1024.0)
P1023 = t.add("p1023", 1023.0)
NM1075 = t.add("neg_1075", -1075.0)
TWO63 = t.add("two63", 9223372036854775808.0)
NEG_TWO63 = t.add("neg_two63", -9223372036854775808.0)
BIG_STEP = t.add("big_step", 4.49423283715578977e307)
SMALL_STEP = t.add("small_step", 2.2250738585072014e-308)
LN2 = t.add("ln2", ln2)
INV_LN2 = t.add("inv_ln2", inv_ln2)
INV_LN2_LO = t.add("inv_ln2_lo", inv_ln2_lo)
# Dekker's splitter, as a TABLE entry and not as `mov $134217729, %rdx` with a
# following movq: `movq %gpr, %xmm` (66 REX.W 0F 6E) is a BIT move on this
# machine, not a conversion -- measured, after a version of prod_err that put
# 134217729's bits where its value belonged and so split every number into
# itself and a zero. The trigonometry block has always read this from its table.
PROD_SPLIT = t.add("prod_split", 134217729.0)


def other_ref(label: str, name: str) -> str:
    """`label+N(%rip)` for an entry of a table another block owns.

    The offset is read out of the installed table rather than assumed, so a
    table that grows an entry makes this fail loudly instead of quietly reading
    the wrong coefficient -- which is the failure a hand-typed offset always
    eventually produces.
    """
    text = open("src/y/arch/math.s").read()
    i = text.index("\n%s:\n" % label)
    seg = text[i:text.index("\n\n", i)]
    names = re.findall(r"^# (\S+)$", seg, re.M)
    assert name in names, "%s has no %s (it has %s)" % (label, name, names[:14])
    return "%s+%d(%%rip)" % (label, 8 * names.index(name))


ISQRT2 = other_ref("ylog_tab", "isqrt2")
LN2_HI = other_ref("ylog_tab", "ln2h")
LN2_LO = other_ref("ylog_tab", "ln2l")
LK = [other_ref("ylog_tab", "k%d" % i) for i in range(NL + 1)]
LKL = [other_ref("ylog_tab", "kl%d" % i) for i in range(NL + 1)]
EK = [other_ref("yexp_tab", "k%d" % i) for i in range(NE + 1)]
EKL = [other_ref("yexp_tab", "kl%d" % i) for i in range(NE + 1)]

# The bit constants the module reaches for as longs. All three are imm64 and
# come out as `movabs`.
MANTISSA_MASK = 4503599627370495        # frexp's mask
AT_HALF = 4602678819172646912           # 0.5's pattern: exponent 1022, no fraction
SIGN_BIT = -9223372036854775808         # 2^63, which is sign_bit()'s value
TWO52 = 4503599627370496                # one added to a double's exponent field

w_ = Writer()
w = w_.w


def poly(hi: str, lo: str, arg: str, co, clo) -> None:
    """poly_split(co, clo, arg) into hi and lo, the Y's Horner.

    Two chains in step, because the low half is a coefficient at 1e-17 and the
    whole point of the split is that its own rounding never reaches the high
    half's last bits. The multiply is FIRST in each step, as in the Y.
    """
    w("    movsd %s, %s" % (co[NL if co is LK else NE], hi))
    w("    movsd %s, %s" % (clo[NL if clo is LKL else NE], lo))
    n = NL if co is LK else NE
    for i in range(n - 1, -1, -1):
        w("    mulsd %s, %s" % (arg, hi))
        w("    addsd %s, %s" % (co[i], hi))
        w("    mulsd %s, %s" % (arg, lo))
        w("    addsd %s, %s" % (clo[i], lo))
    w("    addsd %s, %s" % (lo, hi))


def emit_prod_err() -> None:
    """prod_err, INLINED: a in %xmm0, b in %xmm1, p in %xmm8, answer in %xmm0.

    The splitter constant comes from the table rather than from an immediate,
    which is not a style choice: `movq %gpr, %xmm` moves BITS on this machine,
    so an `mov $134217729` into a register and a `movq` of that register into an
    xmm put 134217729's bit pattern where a double belonged. Every product then
    split into itself and a zero and this returned zero for every argument.

    The Y's expression term by term: ((ah*bh - p) + ah*bl + al*bh) + al*bl, with
    ah in %xmm4, al in %xmm5, bh in %xmm6 and bl in %xmm7 -- four values live at
    once, so the four registers are named here and nowhere else.

    Inlined rather than called, which is the opposite of what the trigonometry
    block does with the same routine, and the reason is what has to SURVIVE it:
    in pow_pos the first product's error is one of four terms the answer is
    summed from, so a call would spill three live values and reload them around
    it -- and a spill is the kind of mistake no test of the arithmetic catches.
    The trigonometry's two calls feed an accumulator and nothing else, so it
    calls y_prod_err.
    """
    w("    movsd %s, %%xmm2" % PROD_SPLIT)
    w("    mulsd %xmm0, %xmm2")                 # ca = (2^27 + 1) * a")
    w("    movsd %xmm2, %xmm3")
    w("    subsd %xmm0, %xmm3")                 # ca - a")
    w("    movsd %xmm2, %xmm4")
    w("    subsd %xmm3, %xmm4")                 # ah = ca - (ca - a)")
    w("    movsd %xmm0, %xmm5")
    w("    subsd %xmm4, %xmm5")                 # al = a - ah")
    w("    movsd %s, %%xmm2" % PROD_SPLIT)
    w("    mulsd %xmm1, %xmm2")                 # cb = (2^27 + 1) * b")
    w("    movsd %xmm2, %xmm3")
    w("    subsd %xmm1, %xmm3")                 # cb - b")
    w("    movsd %xmm2, %xmm6")
    w("    subsd %xmm3, %xmm6")                 # bh = cb - (cb - b)")
    w("    movsd %xmm1, %xmm7")
    w("    subsd %xmm6, %xmm7")                 # bl = b - bh")
    w("    movsd %xmm4, %xmm0")
    w("    mulsd %xmm6, %xmm0")                 # ah*bh")
    w("    subsd %xmm8, %xmm0")                 # - p")
    w("    movsd %xmm4, %xmm2")
    w("    mulsd %xmm7, %xmm2")                 # ah*bl")
    w("    addsd %xmm2, %xmm0")
    w("    movsd %xmm5, %xmm2")
    w("    mulsd %xmm6, %xmm2")                 # al*bh")
    w("    addsd %xmm2, %xmm0")
    w("    movsd %xmm5, %xmm2")
    w("    mulsd %xmm7, %xmm2")                 # al*bl")
    w("    addsd %xmm2, %xmm0")


def trunc_into(dst: str, src: str, tag: str) -> None:
    """trunc(src) into dst -- the Y's trunc, guards and all.

    The guards are what make it exact: a NaN and anything at or past 2^63 answer
    themselves, because there is no long to truncate them into. The NaN test is
    its own branch and comes FIRST, because an unordered comparison sets CF as
    well as ZF and PF, so a below-or-equal written as one branch would swallow
    the NaNs into the conversion: `cvttsd2si` of a NaN is the indefinite value,
    which is a very large number rather than no number at all. (That was the
    first version, and it made is_int(0.5) true -- which sent every fractional
    exponent down the integer path.)

    The Y's own `else if (x == 0.0) { x }` arm is not here, and cannot change an
    answer: the two callers ask for a BOOL out of this, and +0.0 and -0.0
    compare equal, so truncating either one gives the same flag.
    """
    w("    ucomisd %s, %s" % (src, src))
    w("    jp ypow_tunch_%s" % tag)
    w("    movsd %s, %s" % (TWO63, dst))
    w("    ucomisd %s, %s" % (dst, src))
    w("    jae ypow_tunch_%s" % tag)
    w("    movsd %s, %s" % (NEG_TWO63, dst))
    w("    ucomisd %s, %s" % (dst, src))
    w("    jb ypow_tunch_%s" % tag)
    w("    cvttsd2si %s, %%rax" % src)
    w("    cvtsi2sd %%rax, %s" % dst)
    w("    jmp ypow_tdone_%s" % tag)
    w("ypow_tunch_%s:" % tag)
    w("    movsd %s, %s" % (src, dst))
    w("ypow_tdone_%s:" % tag)


def is_int(tag: str) -> None:
    """is_int(y) -- `y == trunc(y)` -- into %rax, 1 for yes.

    Emitted inline at each of the places the dispatch asks it. A call would be
    shorter and would be wrong: the dispatch keeps x's bits in %rcx, which is
    caller-saved, and these are paths where nothing has been spilled yet.
    """
    w("# is_int(y): y == trunc(y)")
    trunc_into("%xmm0", "%xmm2", tag)
    w("    ucomisd %xmm0, %xmm2")
    w("    sete %al")
    w("    movzbq %al, %rax")


def parity(tag: str) -> None:
    """`trunc(y / 2.0) * 2.0 != y` -- the exponent's own parity -- into %rax.

    Inline for the reason `is_int` gives. The Y's is_int is `y == trunc(y)`, so
    an infinite exponent IS an integer and this says it is even: past 2^63 there
    is no long to halve it into and the parity is simply not visible, which is
    why the Y's own answer agrees.
    """
    w("# the parity: trunc(y / 2.0) * 2.0 != y. The halved value goes in %xmm3")
    w("# and NOT in %xmm2, which is y itself: dividing y in place leaves the")
    w("# comparison below answering against y/2 rather than against y, and every")
    w("# exponent with a low bit then reads as an odd one.")
    w("    movsd %xmm2, %xmm3")
    w("    divsd %s, %%xmm3" % TWO)
    trunc_into("%xmm15", "%xmm3", tag)
    w("    mulsd %s, %%xmm15" % TWO)
    w("    ucomisd %xmm2, %xmm15")
    w("    setne %al")
    w("    movzbq %al, %rax")


def odd(tag: str) -> None:
    """is_int(y) && the parity -- into %rax. The two the Y writes as one arm.

    The flag is kept in %rax rather than %eax because the encoder's register-to-
    register ALU form is r64-only: `test %eax, %eax` does not assemble
    ("arith reg form"), while `test %rax, %rax` does, and the byte move that
    makes the flag zero-extends it either way.
    """
    is_int(tag + "_i")
    w("    test %rax, %rax")
    w("    jz ypow_even_%s" % tag)
    parity(tag + "_p")
    w("    test %rax, %rax")
    w("    jz ypow_even_%s" % tag)
    w("    jmp ypow_odd_%s" % tag)
    w("ypow_odd_%s:" % tag)
    w("    mov $1, %rax")
    w("    jmp ypow_odd_%s_done" % tag)
    w("ypow_even_%s:" % tag)
    w("    xor %eax, %eax")
    w("ypow_odd_%s_done:" % tag)


# ── y_pow: the dispatch ────────────────────────────────────────────────────
w("# y_pow: pow(x, y). Generated by test/math/gen_pow.py from src/y/std/math.y's")
w("# pow_y -- do not retype the table (see that file's note). The sequence is the")
w("# Y's line for line, which is what makes the answers the same doubles rather")
w("# than near ones.")
w("#")
w("# Two arguments, pushed in source order, so the LAST is the one at 8(%rsp) and")
w("# the base is at 16(%rsp). Worth writing down because the other way round is")
w("# the natural reading and is wrong: `sum_asm(a.ptr, len(a))` is the same shape,")
w("# and y_sum reads its pointer -- the FIRST argument -- from 16(%rsp) while its")
w("# count, the last, is at 8(%rsp).")
w("#")
w("# This is the first routine in math.s that CALLS, and that is what the rest of")
w("# its shape follows from. The calls would put their return addresses on top of")
w("# the arguments, so it has a frame; %rcx (x's bits) does not survive a call")
w("# either, and neither does any xmm register, so y is read once into the frame")
w("# and reloaded after each call, and log2_dd below answers a PAIR in two")
w("# registers where the Y leaves it in the module-level cells log2_hi, log2_lo,")
w("# ts_lo and z_lo. x is needed only before the first call, so it stays in %rcx.")
w("#")
w("# Answer's bits in %rax.")
w("y_pow:")
w("    push %rbp")
w("    mov %rsp, %rbp")
w("    sub $32, %rsp")
w("    mov 24(%rbp), %rcx                       # x's bits, the first argument")
w("    mov 16(%rbp), %rax                        # y's bits, the last")
w("    mov %rax, -8(%rbp)                       # y, below the frame")
w("    movq %rcx, %xmm1                         # xmm1 = x")
w("    movq %rax, %xmm2                         # xmm2 = y")
w("# if (y == 0.0) return 1.0 -- +0.0 and -0.0 both compare equal to zero,")
w("# which is what the Y's `y == 0.0` does")
w("#")
w("# TWO branches and not one: an UNORDERED comparison sets ZF as well as PF, so a")
w("# bare `je` after this is true for a NaN exponent, and pow(2, nan) came back")
w("# 1.0. The Y's order is what saves it -- `y == 0.0` is false for a NaN, so its")
w("# own NaN arm is what answers -- and the fix is to skip this arm when the")
w("# comparison was unordered rather than to move the NaN test up, which would")
w("# change pow(nan, 0.0) from 1.0 to nan.")
w("    movsd %s, %%xmm0" % ZERO)
w("    ucomisd %xmm0, %xmm2")
w("    jp ypow_not_zero")
w("    je ypow_ret_one")
w("ypow_not_zero:")
w("# if (x != x || y != y) return nan. The self-comparison is the NaN test: PF is")
w("# set only for an unordered result, which is the only way a double equals")
w("# something that is not itself.")
w("    ucomisd %xmm1, %xmm1")
w("    jp ypow_ret_nan")
w("    ucomisd %xmm2, %xmm2")
w("    jp ypow_ret_nan")
w("# if (x == 1.0 || x == -1.0): 1.0, or -1.0 when the exponent's parity says so")
w("    movsd %s, %%xmm0" % ONE)
w("    ucomisd %xmm0, %xmm1")
w("    je ypow_ret_one")
w("    movsd %s, %%xmm0" % NEG_ONE)
w("    ucomisd %xmm0, %xmm1")
w("    jne ypow_not_pm1")
w("# (-1)^anything is +-1, and (-1)^0.5 is 1 -- which is the case a")
w("# \"negative base, fractional exponent\" rule gets wrong")
odd("pm1")
w("    test %rax, %rax")
w("    jz ypow_ret_one")
w("    jmp ypow_ret_neg_one")
w("ypow_not_pm1:")
w("# if (y == 1.0) return x")
w("    movsd %s, %%xmm0" % ONE)
w("    ucomisd %xmm0, %xmm2")
w("    je ypow_ret_x")
w("# if (x == 0.0): (+-0)^positive is +-0 -- the sign follows the exponent's")
w("# parity -- and (+-0)^negative is +inf")
w("    movsd %s, %%xmm0" % ZERO)
w("    ucomisd %xmm0, %xmm1")
w("    jne ypow_x_nonzero")
w("    ucomisd %xmm0, %xmm2                      # y against zero again")
w("    jb ypow_ret_inf")
odd("x0")
w("    test %rax, %rax")
w("    jnz ypow_ret_neg_zero")
w("    jmp ypow_ret_zero")
w("ypow_x_nonzero:")
w("# if (is_inf(x)): the parity sign belongs to the BASE being negative, so a")
w("# positive infinity to any power is positive and pow(inf, 3) is +inf. x is not")
w("# a NaN by now, so is_inf is these two comparisons -- the Y's is")
w("# `!is_nan(x) && !is_finite(x)` and the first half is an earlier test above.")
w("    movsd %s, %%xmm0" % PINF)
w("    ucomisd %xmm0, %xmm1")
w("    je ypow_x_isinf")
w("    movsd %s, %%xmm0" % NINF)
w("    ucomisd %xmm0, %xmm1")
w("    jne ypow_not_inf")
w("ypow_x_isinf:")
w("    ucomisd %s, %%xmm2" % ZERO)
w("    jb ypow_ret_zero                         # y < 0 -> +0.0")
w("    ucomisd %s, %%xmm1" % ZERO)
w("    jae ypow_ret_inf                         # a positive base -> +inf")
odd("inf")
w("    test %rax, %rax")
w("    jz ypow_ret_inf")
w("    jmp ypow_ret_neg_inf")
w("ypow_not_inf:")
w("# else if (x < 0.0): a negative base needs an integer exponent, and past 1024")
w("# there are too many squarings to do -- the logarithm carries it instead, with")
w("# the sign back on afterwards")
w("    movsd %s, %%xmm0" % ZERO)
w("    ucomisd %xmm0, %xmm1")
w("    jae ypow_x_positive")
is_int("neg")
w("    test %rax, %rax")
w("    jz ypow_ret_nan")
w("# -1024 <= y <= 1024, as the Y writes it: y >= -1024.0 && y <= 1024.0")
w("    movsd %s, %%xmm0" % P1024)
w("    ucomisd %xmm0, %xmm2")
w("    ja ypow_neg_big")
w("    movsd %s, %%xmm0" % NEG_ONE)
w("    mulsd %s, %%xmm0" % P1024)               # -1024")
w("    ucomisd %xmm0, %xmm2")
w("    jb ypow_neg_big")
w("    cvttsd2si %xmm2, %rax")
w("    movq %xmm1, %xmm0")
w("    mov %rax, %rdi")
w("    call ypow_int")
w("    jmp ypow_ret")
w("ypow_neg_big:")
w("# the sign goes on afterwards, so it is decided BEFORE the call (the call")
w("# takes it) and remembered in the frame")
parity("negb")
w("    mov %rax, -16(%rbp)")
w("    movsd %s, %%xmm0" % ZERO)
w("    subsd %xmm1, %xmm0                       # -x")
w("    movq %xmm0, %xmm1")
w("    call ypow_pos_go")
w("    cmp $0, -16(%rbp)")
w("    je ypow_ret")
w("# `0.0 - v`, which for a finite v is the sign flip and for an infinity")
w("# the answer with the sign the parity asked for. The zero goes in %xmm1,")
w("# not %xmm0: subtracting %xmm0 from itself is 0.0 - 0.0, which is +0.0")
w("# always, and an odd exponent past 1024 then answered +inf where the Y")
w("# answers -inf.")
w("    movsd %s, %%xmm1" % ZERO)
w("    subsd %xmm0, %xmm1")
w("    movsd %xmm1, %xmm0")
w("    jmp ypow_ret")
w("ypow_x_positive:")
w("# else if (is_int(y) && y >= -1024.0 && y <= 1024.0) -> pow_int(x, to_int(y))")
is_int("posi")
w("    test %rax, %rax")
w("    jz ypow_pos")
w("    movsd %s, %%xmm0" % P1024)
w("    ucomisd %xmm0, %xmm2")
w("    ja ypow_pos")
w("    movsd %s, %%xmm0" % NEG_ONE)
w("    mulsd %s, %%xmm0" % P1024)
w("    ucomisd %xmm0, %xmm2")
w("    jb ypow_pos")
w("    cvttsd2si %xmm2, %rax")
w("    movq %xmm1, %xmm0")
w("    mov %rax, %rdi")
w("    call ypow_int")
w("    jmp ypow_ret")
w("# pow_pos(x, y), the general path. A separate routine so that the negative")
w("# base above can call it and then apply a sign; it shares y_pow's frame,")
w("# which is why it reloads y from -8(%rbp) rather than taking an argument.")
w("ypow_pos:")
w("    call ypow_pos_go")
w("    jmp ypow_ret")
w("# pow_pos: the logarithm in two parts, the exponent in two parts, and the")
w("# reduced argument in two parts. pow is the one function here that cannot take")
w("# its log's answer at face value, because it multiplies it by the exponent,")
w("# and an exponent of 500 turns the log's half-ulp into 5e-14 of the answer.")
w("# x in %xmm1, y in the frame; the answer in %xmm0.")
w("ypow_pos_go:")
w("    movq %xmm1, %xmm0")
w("    call ypow_log2_dd                         # -> %xmm0 l_hi, %xmm1 l_lo")
w("    movsd %xmm0, %xmm9")
w("    movsd %xmm1, %xmm10")
w("# u = y * inv_ln2, in two parts: the rounded constant is 1.4e-17 off, and")
w("# that is 7e-15 of an exponent of 500 -- 60 ulps of the answer, for nothing")
w("# more than rounding a constant")
w("    mov -8(%rbp), %rax")
w("    movq %rax, %xmm11")
w("    mulsd %s, %%xmm11" % INV_LN2)
w("# p = u * l_hi")
w("    movsd %xmm11, %xmm12")
w("    mulsd %xmm9, %xmm12")
w("# q = prod_err(u, l, p) + u * l_lo + l * (prod_err(y, inv_ln2, u) + y *")
w("# inv_ln2_lo), summed left to right as the Y sums it")
w("    movsd %xmm11, %xmm0")
w("    movsd %xmm9, %xmm1")
w("    movsd %xmm12, %xmm8")
emit_prod_err()
w("    movsd %xmm0, %xmm13")
w("    movsd %xmm11, %xmm0")
w("    mulsd %xmm10, %xmm0")
w("    movsd %xmm0, %xmm14")
w("    addsd %xmm14, %xmm13")
w("    mov -8(%rbp), %rax")
w("    movq %rax, %xmm0")
w("    movsd %s, %%xmm1" % INV_LN2)
w("    movsd %xmm11, %xmm8")
emit_prod_err()
w("    mov -8(%rbp), %rax")
w("    movq %rax, %xmm1")
w("    mulsd %s, %%xmm1" % INV_LN2_LO)
w("    addsd %xmm1, %xmm0")
w("    movsd %xmm0, %xmm15")
w("    mulsd %xmm15, %xmm9")
w("    addsd %xmm9, %xmm13")
w("    movsd %xmm12, %xmm0")
w("    movsd %xmm13, %xmm1")
w("    call ypow_exp2_corr")
w("    ret")
w("ypow_ret:")
w("    movq %xmm0, %rax                         # a float answer's bits go in %rax")
w("    mov %rbp, %rsp")
w("    pop %rbp")
w("    ret")
w("ypow_ret_one:")
w("    movsd %s, %%xmm0" % ONE)
w("    jmp ypow_ret")
w("ypow_ret_neg_one:")
w("    movsd %s, %%xmm0" % NEG_ONE)
w("    jmp ypow_ret")
w("ypow_ret_zero:")
w("    movsd %s, %%xmm0" % ZERO)
w("    jmp ypow_ret")
w("ypow_ret_neg_zero:")
w("    movsd %s, %%xmm0" % ZERO)
w("    mulsd %s, %%xmm0" % NEG_ONE)
w("    jmp ypow_ret")
w("ypow_ret_x:")
w("    movq %xmm1, %xmm0")
w("    jmp ypow_ret")
w("ypow_ret_inf:")
w("    movsd %s, %%xmm0" % PINF)
w("    jmp ypow_ret")
w("ypow_ret_neg_inf:")
w("    movsd %s, %%xmm0" % NINF)
w("    jmp ypow_ret")
w("ypow_ret_nan:")
w("# The module's `nan` is `0.0 / 0.0`, so the NaN is COMPUTED rather than stored:")
w("# the default NaN carries the sign bit (0xFFF8000000000000), so the one you")
w("# would write from memory is a different double from the one the Y returns.")
w("    movsd %s, %%xmm0" % ZERO)
w("    divsd %xmm0, %xmm0")
w("    jmp ypow_ret")
w("")
w("")
w("# ypow_int(x, n): repeated squaring over the BITS of the exponent. b is")
w("# x^(2^i) at step i and is multiplied in when bit i is set, so an integer")
w("# exponent comes out of as many rounded multiplies as the Y does -- which is")
w("# what the bit-identity promise is: the same sequence of roundings, not a")
w("# better one. x in %xmm0, n in %rdi, the answer in %xmm0.")
w("ypow_int:")
w("# k = |n|, and whether to reciprocate at the end. The flag is a REGISTER")
w("# rather than the sign of the negated %rdi, because that is what the first")
w("# version did and it reciprocated every positive exponent: `neg %rdi` leaves")
w("# the opposite sign behind, so the test at the end read it backwards.")
w("    mov $0, %r10                             # not negative")
w("    mov %rdi, %rsi                           # kk")
w("    test %rdi, %rdi")
w("    jns ypow_int_go")
w("    mov $1, %r10                             # negative: k = 0 - n")
w("    neg %rsi")
w("ypow_int_go:")
w("    movsd %s, %%xmm1                          # r = 1.0" % ONE)
w("ypow_int_loop:")
w("    test $1, %rsi                             # kk % 2 == 1")
w("    jz ypow_int_sqr")
w("    mulsd %xmm0, %xmm1                        # r = r * b")
w("ypow_int_sqr:")
w("    mulsd %xmm0, %xmm0                        # b = b * b")
w("    shr $1, %rsi                              # kk = kk / 2")
w("    jnz ypow_int_loop")
w("    test %r10, %r10")
w("    jz ypow_int_ret")
w("    movsd %s, %%xmm0" % ONE)
w("    divsd %xmm1, %xmm0                        # 1.0 / r")
w("    ret")
w("ypow_int_ret:")
w("    movsd %xmm1, %xmm0")
w("    ret")
w("")
# ── ypow_log2_dd: the same reduction as y_log, and a different tail ─────────
w("# ypow_log2_dd(x): log(x) in two parts, the second left in %xmm1 instead of")
w("# in the module-level cell the Y calls log2_lo. The reduction is y_log's, line")
w("# for line -- frexp with its subnormal guard, the inv_sqrt2 step, log_z's")
w("# division and its quotient error -- because it is the same arithmetic; only")
w("# the last four lines differ, and they differ because pow multiplies this")
w("# answer by an exponent. x in %xmm0, the pair in %xmm0 and %xmm1.")
w("ypow_log2_dd:")
w("    movq %xmm0, %xmm2")
w("# if (x != x || x < 0.0): nan, and the low part 0.0. `jb` is the x < 0 test:")
w("# x is not a NaN by then, so CF=1 means below zero and nothing else.")
w("    ucomisd %xmm2, %xmm2")
w("    jp ypow_l2_nan")
w("    movsd %s, %%xmm8" % ZERO)
w("    ucomisd %xmm8, %xmm2")
w("    jb ypow_l2_nan")
w("# if (x == 0.0) return -inf, low part 0.0")
w("    ucomisd %xmm8, %xmm2")
w("    je ypow_l2_ninf")
w("# if (is_inf(x)) return inf, low part 0.0. x >= 0 here, so +inf or nothing.")
w("    movsd %xmm2, %xmm0")
w("    ucomisd %s, %%xmm0" % PINF)
w("    je ypow_l2_pinf")
w("# frexp. The mantissa is this mantissa at exponent 1022, in BITS because there")
w("# is no float-to-long conversion; the sign comes off and goes back on as the")
w("# exponent's sign, which x being positive here has already settled.")
w("    movq %xmm2, %xmm5                         # r = x")
w("    movq %xmm5, %rax")
w("    shr $52, %rax")
w("    and $2047, %rax")
w("    xor %ecx, %ecx                            # the guard counter")
w("    test %rax, %rax")
w("    jnz ypow_l2_norm_done")
w("# A subnormal has no implicit leading bit, so it is doubled until its field is")
w("# not 0. The Y's loop also tests `r != 0.0`; x is not zero here (that case")
w("# returned above) and doubling a nonzero never reaches zero.")
w("ypow_l2_norm:")
w("    cmp $60, %rcx")
w("    jge ypow_l2_norm_done")
w("    movq %xmm5, %rax")
w("    shr $52, %rax")
w("    and $2047, %rax")
w("    test %rax, %rax")
w("    jnz ypow_l2_norm_done")
w("    movsd %xmm5, %xmm8")
w("    mulsd %s, %%xmm8                          # r = r * 2.0" % TWO)
w("    movsd %xmm8, %xmm5")
w("    add $1, %rcx")
w("    jmp ypow_l2_norm")
w("ypow_l2_norm_done:")
w("    movq %xmm5, %rax")
w("    mov %rax, %rdx")
w("    shr $52, %rdx")
w("    and $2047, %rdx                           # the exponent field")
w("    mov $%d, %%r10" % MANTISSA_MASK)
w("    and %r10, %rax")
w("    mov $%d, %%r10" % AT_HALF)
w("    or %r10, %rax                             # at exponent 1022, so [0.5, 1)")
w("    movq %rax, %xmm2                          # m")
w("    sub $1022, %rdx")
w("    sub %rcx, %rdx                            # e = field - 1022 - guard")
w("# if (m < inv_sqrt2) { m = m * 2.0; e = e - 1 }, which keeps |z| at")
w("# sqrt(2) - 1 rather than reaching 1")
w("    movsd %s, %%xmm8" % ISQRT2)
w("    ucomisd %xmm8, %xmm2")
w("    jae ypow_l2_m_ok")
w("    movsd %xmm2, %xmm8")
w("    mulsd %s, %%xmm8" % TWO)
w("    movsd %xmm8, %xmm2")
w("    sub $1, %rdx")
w("ypow_l2_m_ok:")
w("    cvtsi2sd %rdx, %xmm6                      # ef = (float) e")
w("# log_z(m): num = m - 1; den = m + 1; bb = den - m; derr = (m - (den - bb)) +")
w("# (1 - bb); z = num / den; z_lo = -(z * derr) / den. m + 1 rounds and its")
w("# half-ulp is a whole ulp of z, which is what the second divide puts back.")
w("    movsd %xmm2, %xmm0")
w("    subsd %s, %%xmm0                          # num" % ONE)
w("    movsd %xmm2, %xmm1")
w("    addsd %s, %%xmm1                          # den" % ONE)
w("    movsd %xmm1, %xmm8")
w("    subsd %xmm2, %xmm8                        # bb = den - m")
w("    movsd %xmm1, %xmm3")
w("    subsd %xmm8, %xmm3                        # den - bb")
w("    movsd %xmm2, %xmm4")
w("    subsd %xmm3, %xmm4                        # m - (den - bb)")
w("    movsd %s, %%xmm3" % ONE)
w("    subsd %xmm8, %xmm3                        # 1 - bb")
w("    addsd %xmm3, %xmm4                        # derr")
w("    divsd %xmm1, %xmm0                        # z = num / den")
w("    movsd %xmm0, %xmm7")
w("    mulsd %xmm4, %xmm7                        # z * derr")
w("    movsd %s, %%xmm8" % ZERO)
w("    subsd %xmm7, %xmm8                        # -(z * derr)")
w("    divsd %xmm1, %xmm8                        # z_lo")
w("    addsd %xmm8, %xmm0                        # z = z + z_lo")
w("    movsd %xmm0, %xmm3")
w("    mulsd %xmm0, %xmm3                        # w = z * z")
w("# a = two_sum(2.0 * z, (z * w) * P), NOT z * (2.0 + w * P) -- the Y's")
w("# change, and the reason pow was three ulps out at some arguments. The")
w("# brackets in the other form round at the size of 2.0, which is a whole ulp")
w("# of the logarithm, and pow multiplies the logarithm by the exponent. The")
w("# scaling by two here is exact and (z*w)*P is two orders smaller, so the")
w("# two_sum carries what the brackets used to drop.")
poly("%xmm2", "%xmm9", "%xmm3", LK, LKL)
w("    movsd %xmm0, %xmm4")
w("    mulsd %s, %%xmm4                          # a = 2.0 * z, and exact: it is a"
  % TWO)
w("                                               # scaling by a power of two")
w("    movsd %xmm3, %xmm7                         # b = (z * w) * P")
w("    mulsd %xmm0, %xmm7")
w("    mulsd %xmm2, %xmm7")
w("    # two_sum(a, b) in the Y's order: bb = s - a, and the residual is")
w("    # (a - (s - bb)) + (b - bb) -- it lands in %xmm5 and rides into the pair")
w("    movsd %xmm4, %xmm5")
w("    addsd %xmm7, %xmm4                         # s")
w("    movsd %xmm4, %xmm8")
w("    subsd %xmm5, %xmm8                        # bb = s - a")
w("    movsd %xmm4, %xmm10")
w("    subsd %xmm8, %xmm10                       # s - bb")
w("    subsd %xmm10, %xmm5                       # a - (s - bb)")
w("    movsd %xmm7, %xmm11")
w("    subsd %xmm8, %xmm11                       # b - bb")
w("    addsd %xmm11, %xmm5")
w("# b = two_sum(ef * ln2_hi, ef * ln2_lo), and bc_lo what that summation lost.")
w("# The two terms are of very different sizes -- this one is e * ln 2 and the")
w("# small one is the kernel's -- and the rounding that matters is this one's, so")
w("# this is the one two_sum keeps track of.")
w("    movsd %xmm6, %xmm7")
w("    mulsd %s, %%xmm7                          # ef * ln2_hi" % LN2_HI)
w("    movsd %xmm6, %xmm8")
w("    mulsd %s, %%xmm8                          # ef * ln2_lo" % LN2_LO)
w("    movsd %xmm7, %xmm9")
w("    addsd %xmm8, %xmm9                        # s = p + q")
w("    movsd %xmm9, %xmm10")
w("    subsd %xmm7, %xmm10                       # bb = s - p")
w("    movsd %xmm9, %xmm11")
w("    subsd %xmm10, %xmm11                      # s - bb")
w("    subsd %xmm11, %xmm7                       # p - (s - bb)")
w("    movsd %xmm8, %xmm12")
w("    subsd %xmm10, %xmm12                      # q - bb")
w("    addsd %xmm12, %xmm7                       # bc_lo")
w("# t = two_sum(a, b), and the answer's low part is what this lost plus bc_lo")
w("# `a` is %xmm4 -- it was %xmm0 until the two_sum above moved it, and this")
w("# block reading the wrong register is how the first version of that change")
w("# answered 86 cases of the table three orders of magnitude out")
w("    movsd %xmm4, %xmm13")
w("    addsd %xmm9, %xmm13                       # t = a + b")
w("    movsd %xmm13, %xmm14")
w("    subsd %xmm4, %xmm14                       # bb2 = t - a")
w("    movsd %xmm13, %xmm15")
w("    subsd %xmm14, %xmm15                      # t - bb2")
w("    subsd %xmm15, %xmm4                       # a - (t - bb2)")
w("    movsd %xmm9, %xmm12")
w("    subsd %xmm14, %xmm12                      # b - bb2")
w("    # The residual lands in %xmm4 and NOT %xmm0: `a` moved there when the")
w("    # two_sum above was introduced, and the Y puts the residual in the `a`")
w("    # variable. %xmm0 still holds z, and the version that summed into it")
w("    # returned lo = z -- a log2_dd pair whose low half was a quarter of the")
w("    # log, which is what put 85 of the table's pow cases over three ulps.")
w("    addsd %xmm12, %xmm4")
w("    # lo = (what t lost + what a lost) + bc_lo, the Y's order and not the")
w("    # other one: these three are of one size and their sum is not associative")
w("    addsd %xmm5, %xmm4                        # ts_lo + a_lo")
w("    addsd %xmm7, %xmm4                        # + bc_lo")
w("    movsd %xmm4, %xmm1")
w("    movsd %xmm13, %xmm0                       # hi = t")
w("    ret")
w("ypow_l2_nan:")
w("    movsd %s, %%xmm0" % ZERO)
w("    divsd %xmm0, %xmm0                        # 0.0 / 0.0 is the module's nan")
w("    movsd %s, %%xmm1                          # the low part is 0.0" % ZERO)
w("    ret")
w("ypow_l2_pinf:")
w("    movsd %s, %%xmm0" % PINF)
w("    movsd %s, %%xmm1" % ZERO)
w("    ret")
w("ypow_l2_ninf:")
w("    movsd %s, %%xmm0" % NINF)
w("    movsd %s, %%xmm1" % ZERO)
w("    ret")
w("")
# ── ypow_exp2_corr: 2^(p + q) ───────────────────────────────────────────────
w("# ypow_exp2_corr(p, q): 2^(p + q), where q is what the exponent's own rounding")
w("# left over. It has to be added AFTER the reduction -- an exponent error is an")
w("# absolute error in the reduced argument, and before the reduction it would be")
w("# multiplied by the whole exponent -- and it has to SURVIVE the reduction too,")
w("# which is the part that is easy to miss: one ulp of an exponent of 500 is")
w("# 5.7e-14 of the answer, 360 ulps of it. p in %xmm0, q in %xmm1, the answer in")
w("# %xmm0. The frame is because ldexp is called and every xmm register is")
w("# caller-saved: hi, lo and k all have to be in memory across those calls.")
w("ypow_exp2_corr:")
w("    push %rbp")
w("    mov %rsp, %rbp")
w("    sub $32, %rsp")
w("# if (p != p) return p")
w("    ucomisd %xmm0, %xmm0")
w("    jp ypow_e2_nan")
w("    movsd %s, %%xmm8" % P1024)
w("    ucomisd %xmm8, %xmm0")
w("    ja ypow_e2_inf")
w("    movsd %s, %%xmm8" % NM1075)
w("    ucomisd %xmm8, %xmm0")
w("    jb ypow_e2_zero")
w("# n = floor(p + 0.5): truncation, and one less when it rounded UP -- which is")
w("# when the truncated value is GREATER than the value it came from")
w("    movsd %xmm0, %xmm2")
w("    addsd %s, %%xmm2" % HALF)
w("    cvttsd2si %xmm2, %rax")
w("    cvtsi2sd %rax, %xmm3")
w("    ucomisd %xmm2, %xmm3")
w("    jbe ypow_e2_n_ok")
w("    sub $1, %rax")
w("ypow_e2_n_ok:")
w("    cvtsi2sd %rax, %xmm4                       # n as a float")
w("# s = (p - n) + q, in that order: the exponent's remainder, then what the")
w("# exponent itself lost")
w("    movsd %xmm0, %xmm5")
w("    subsd %xmm4, %xmm5")
w("    addsd %xmm1, %xmm5                        # s")
w("# t = s * ln2")
w("    movsd %xmm5, %xmm6")
w("    mulsd %s, %%xmm6                          # t" % LN2)
w("    mov %rax, %rdi                            # k = to_int(n)")
w("# f2 = 1.0, and 2.0 with one off k when n is past the largest exponent")
w("    movsd %s, %%xmm7" % ONE)
w("    movsd %s, %%xmm8" % P1023)
w("    ucomisd %xmm8, %xmm4")
w("    jbe ypow_e2_f2_ok")
w("    sub $1, %rdi")
w("    movsd %s, %%xmm7" % TWO)
w("ypow_e2_f2_ok:")
w("# hi = f2 * (1.0 + t * (1.0 + t * poly_split(exp_k, exp_kl, t))). The multiply")
w("# by f2 is LAST, as in the Y, and the polynomial is yexp_tab's -- the same")
w("# coefficients the same generator read for y_exp, read here rather than")
w("# copied, because the same coefficients in two tables is a table that can")
w("# disagree with itself.")
poly("%xmm2", "%xmm9", "%xmm6", EK, EKL)
w("    movsd %xmm6, %xmm3")
w("    mulsd %xmm2, %xmm3                        # t * P")
w("    addsd %s, %%xmm3" % ONE)
w("    mulsd %xmm6, %xmm3                        # t * (1 + t*P)")
w("    addsd %s, %%xmm3" % ONE)
w("    mulsd %xmm7, %xmm3                        # * f2")
w("    movsd %xmm3, %xmm9                        # hi")
w("# lo = hi * prod_err(s, ln2, t): e^(t + t_lo) = e^t * e^t_lo = e^t + e^t *")
w("# t_lo for a t_lo of 1e-17")
w("    movsd %xmm5, %xmm0")
w("    movsd %s, %%xmm1                          # b = ln2" % LN2)
w("    movsd %xmm6, %xmm8                        # p = t")
emit_prod_err()
w("    mulsd %xmm9, %xmm0                        # lo = hi * the error")
w("# ldexp(hi, k) + ldexp(lo, k), and the three values go to the frame first")
w("    movsd %xmm9, -8(%rbp)")
w("    movsd %xmm0, -16(%rbp)")
w("    mov %rdi, -24(%rbp)")
w("    movsd -8(%rbp), %xmm0")
w("    mov -24(%rbp), %rdi")
w("    call ypow_ldexp")
w("    movsd %xmm0, -8(%rbp)")
w("    movsd -16(%rbp), %xmm0")
w("    mov -24(%rbp), %rdi")
w("    call ypow_ldexp")
w("    addsd -8(%rbp), %xmm0")
w("    mov %rbp, %rsp")
w("    pop %rbp")
w("    ret")
w("ypow_e2_nan:")
w("    mov %rbp, %rsp")
w("    pop %rbp")
w("    ret")
w("ypow_e2_inf:")
w("    movsd %s, %%xmm0" % PINF)
w("    mov %rbp, %rsp")
w("    pop %rbp")
w("    ret")
w("ypow_e2_zero:")
w("    movsd %s, %%xmm0" % ZERO)
w("    mov %rbp, %rsp")
w("    pop %rbp")
w("    ret")
w("")
# ── ypow_ldexp ──────────────────────────────────────────────────────────────
w("# ypow_ldexp(x, e): x scaled by 2^e. The big steps first, since after them the")
w("# answer may already be 0 or an infinity and there is nothing left to do")
w("# exactly; 2^1022 rather than 2^1023, so that one step never overflows on its")
w("# own. Then, if the answer is still NORMAL, the exponent field is the whole of")
w("# the job -- k * 2^52 added to the bits IS k added to the field -- and the sign")
w("# comes off first and goes back on after, because a negative pattern would put")
w("# a 1 at the top of an 11-bit field and scale the wrong way. Otherwise one")
w("# doubling or halving at a time, which is how that is exact (and is also the")
w("# subnormal case: a subnormal's field is 0, so every step of it is a")
w("# doubling). x in %xmm0, e in %rdi, the answer in %xmm0.")
w("ypow_ldexp:")
w("    movq %xmm0, %xmm3                         # r = x")
w("    mov %rdi, %rsi                            # k = e")
w("# if (x != x || x == 0.0 || is_inf(x)) return x -- all four answer themselves")
w("    ucomisd %xmm3, %xmm3")
w("    jp ypow_ld_ret")
w("    movsd %s, %%xmm8" % ZERO)
w("    ucomisd %xmm8, %xmm3")
w("    je ypow_ld_ret")
w("    ucomisd %s, %%xmm3" % PINF)
w("    je ypow_ld_ret")
w("    ucomisd %s, %%xmm3" % NINF)
w("    je ypow_ld_ret")
w("    cmp $1022, %rsi")
w("    jl ypow_ld_big_done")
w("ypow_ld_big:")
w("    mulsd %s, %%xmm3" % BIG_STEP)
w("    sub $1022, %rsi")
w("    cmp $1022, %rsi")
w("    jge ypow_ld_big")
w("ypow_ld_big_done:")
w("    cmp $-1022, %rsi")
w("    jg ypow_ld_small_done")
w("ypow_ld_small:")
w("    mulsd %s, %%xmm3" % SMALL_STEP)
w("    add $1022, %rsi")
w("    cmp $-1022, %rsi")
w("    jle ypow_ld_small")
w("ypow_ld_small_done:")
w("    movq %xmm3, %rax")
w("    shr $52, %rax")
w("    mov $2047, %rdx")
w("    and %rdx, %rax                            # f = the exponent field")
w("    test %rax, %rax")
w("    jz ypow_ld_double")
w("    mov %rax, %rdx")
w("    add %rsi, %rdx                            # f + k")
w("    cmp $1, %rdx")
w("    jl ypow_ld_double")
w("    test %rsi, %rsi")
w("    jz ypow_ld_ret                            # k == 0")
w("    movq %xmm3, %rax                          # b = r's bits")
w("    test %rax, %rax")
w("    js ypow_ld_neg")
w("    mov $%d, %%rdx" % TWO52)
w("    imul %rsi, %rdx")
w("    add %rdx, %rax")
w("    movq %rax, %xmm3")
w("    jmp ypow_ld_ret")
w("ypow_ld_neg:")
w("    mov $%d, %%rdx" % SIGN_BIT)
w("    add %rdx, %rax                            # without_sign(b)")
w("    mov $%d, %%rdx" % TWO52)
w("    imul %rsi, %rdx")
w("    add %rdx, %rax")
w("    mov $%d, %%rdx" % SIGN_BIT)
w("    add %rdx, %rax                            # the sign goes back on")
w("    movq %rax, %xmm3")
w("    jmp ypow_ld_ret")
w("ypow_ld_double:")
w("    mov $1, %rdx                              # step = k < 0 ? -1 : 1")
w("    test %rsi, %rsi")
w("    jns ypow_ld_step_ok")
w("    mov $-1, %rdx")
w("ypow_ld_step_ok:")
w("    mov %rsi, %rcx                            # rest = k")
w("    test %rcx, %rcx")
w("    jz ypow_ld_ret")
w("ypow_ld_dbl:")
w("    cmp $-1, %rdx")
w("    jne ypow_ld_dbl_up")
w("    mulsd %s, %%xmm3                          # r = r * 0.5" % HALF)
w("    jmp ypow_ld_dbl_next")
w("ypow_ld_dbl_up:")
w("    mulsd %s, %%xmm3                          # r = r * 2.0" % TWO)
w("ypow_ld_dbl_next:")
w("    sub %rdx, %rcx")
w("    test %rcx, %rcx")
w("    jnz ypow_ld_dbl")
w("ypow_ld_ret:")
w("    movsd %xmm3, %xmm0")
w("    ret")
w("")

# ── the STAGE probes ───────────────────────────────────────────────────────
if WHICH != "full":
    w("# The stage probes. Each takes pow's two arguments and answers one")
    w("# intermediate, so a divergence can be localised the way gen_exp.py and")
    w("# gen_log.py localise one -- against the Y's own value at that point, which")
    w("# for l and lo is `math.log2_dd(x)` and the module's `math.log2_lo`.")
    w("#")
    w("# The slots are the awkward part and are worth stating: after this prologue")
    w("# the LAST of the two arguments is at 16(%rbp) and the first at 24(%rbp),")
    w("# which is the reverse of how they read at 8(%rsp) and 16(%rsp) without a")
    w("# frame. Reading them the other way round swaps p and q, and the exp2_corr")
    w("# probe then measures nothing at all while looking entirely plausible.")
    if WHICH in ("l", "lo"):
        w("y_pow_%s:" % WHICH)
        w("    push %rbp")
        w("    mov %rsp, %rbp")
        w("    mov 24(%rbp), %rax")
        w("    movq %rax, %xmm0")
        w("    call ypow_log2_dd")
        if WHICH == "lo":
            w("    movsd %xmm1, %xmm0")
        w("    movq %xmm0, %rax")
        w("    mov %rbp, %rsp")
        w("    pop %rbp")
        w("    ret")
    if WHICH in ("p", "q", "e1", "e2a"):
        w("y_pow_%s:" % WHICH)
        w("    push %rbp")
        w("    mov %rsp, %rbp")
        w("    sub $32, %rsp")
        w("    mov 16(%rbp), %rax                        # y's bits, the last argument")
        w("    mov %rax, -8(%rbp)")
        w("    mov 24(%rbp), %rcx                        # x's bits, the first")
        w("    movq %rcx, %xmm1")
        w("    movq %rcx, %xmm0")
        w("    call ypow_log2_dd")
        w("    movsd %xmm0, %xmm9")
        w("    movsd %xmm1, %xmm10")
        w("    mov -8(%rbp), %rax")
        w("    movq %rax, %xmm11")
        w("    mulsd %s, %%xmm11" % INV_LN2)
        w("    movsd %xmm11, %xmm12")
        w("    mulsd %xmm9, %xmm12")
        w("    movsd %xmm11, %xmm0")
        w("    movsd %xmm9, %xmm1")
        w("    movsd %xmm12, %xmm8")
        emit_prod_err()
        if WHICH == "e1":
            w("    jmp ypow_%s_out" % WHICH)
        if WHICH == "e2a":
            w("    mov -8(%rbp), %rax")
            w("    movq %rax, %xmm0")
            w("    movsd %s, %%xmm1" % INV_LN2)
            w("    movsd %xmm11, %xmm8")
            emit_prod_err()
            w("    jmp ypow_%s_out" % WHICH)
        if WHICH == "p":
            w("    movsd %xmm12, %xmm0")
            w("    jmp ypow_%s_out" % WHICH)
        w("    movsd %xmm0, %xmm13")
        w("    movsd %xmm11, %xmm0")
        w("    mulsd %xmm10, %xmm0")
        w("    movsd %xmm0, %xmm14")
        w("    addsd %xmm14, %xmm13")
        w("    mov -8(%rbp), %rax")
        w("    movq %rax, %xmm0")
        w("    movsd %s, %%xmm1" % INV_LN2)
        w("    movsd %xmm11, %xmm8")
        emit_prod_err()
        w("    mov -8(%rbp), %rax")
        w("    movq %rax, %xmm1")
        w("    mulsd %s, %%xmm1" % INV_LN2_LO)
        w("    addsd %xmm1, %xmm0")
        w("    movsd %xmm0, %xmm15")
        w("    mulsd %xmm15, %xmm9")
        w("    addsd %xmm9, %xmm13")
        w("    movsd %xmm13, %xmm0")
        w("ypow_%s_out:" % WHICH)
        w("    movq %xmm0, %rax")
        w("    mov %rbp, %rsp")
        w("    pop %rbp")
        w("    ret")
    if WHICH == "e2":
        w("y_pow_e2:")
        w("    push %rbp")
        w("    mov %rsp, %rbp")
        w("    sub $32, %rsp")
        w("    mov 24(%rbp), %rax                        # p, the first argument")
        w("    movq %rax, %xmm0")
        w("    mov 16(%rbp), %rax                        # q, the last")
        w("    movq %rax, %xmm1")
        w("    call ypow_exp2_corr")
        w("    movq %xmm0, %rax")
        w("    mov %rbp, %rsp")
        w("    pop %rbp")
        w("    ret")
    if WHICH == "int":
        w("y_pow_int:")
        w("    push %rbp")
        w("    mov %rsp, %rbp")
        w("    mov 24(%rbp), %rax")
        w("    movq %rax, %xmm0")
        w("    mov 16(%rbp), %rax")
        w("    cvttsd2si %rax, %rdi")
        w("    call ypow_int_g")
        w("    movq %xmm0, %rax")
        w("    mov %rbp, %rsp")
        w("    pop %rbp")
        w("    ret")
        w("ypow_int_g:")
        w("    jmp ypow_int")

emit(sys.argv[1] if len(sys.argv) > 1 else None, w_, t)
print("# generated %d lines, %d table entries (%d bytes)"
      % (len(w_.lines), len(t.entries), 8 * len(t.entries)), file=sys.stderr)
