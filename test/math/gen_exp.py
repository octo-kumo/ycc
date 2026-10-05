#!/usr/bin/env python3
#!/usr/bin/env python3
"""Generate y_exp -- the routine test/y/native/t311_math_exp_asm.y gates.

    python3 test/math/gen_exp.py [OUT.s] [STAGE]

Run from the repository root. OUT.s defaults to stdout. STAGE is `full` (the
whole routine) or one of n/r/P/v/ldx, which returns that intermediate instead of
the answer -- how a divergence gets localised: return the reduction's r, or the
kernel, or v, and compare against the Y version's own value at that point. Four
probes found four bugs in the first attempt (ideas/math.md §8).

To land a change to exp: edit src/y/std/math.y, run this, write the result over
the y_exp block in src/y/arch/math.s, and run t311.

Every constant and every coefficient is READ OUT of src/y/std/math.y rather than
copied: the whole constraint is that the assembly return the same double as the
Y, so a table typed by hand is a table that can disagree with the oracle without
anything noticing. The generator parses the `let` lines and the two coefficient
arrays, prints their bit patterns, and emits the routine.

The operation sequence mirrors the Y line for line, because that is what makes
the bits match:
  n = to_int(floor(x*log2e + 0.5))   -> one cvttsd2si, one correction, cvtsi2sd
  r = (x - nf*ln2_hi) - nf*ln2_lo    -> two multiplies, two subtracts
  P = poly_split(exp_k, exp_kl, r)  -> two Horner chains, hi and lo, then p + q
  v = f2 * (1 + r*(1 + r*P))         -> as written
  ldexp(v, k)                        -> as written, big steps then the field,
                                       then a doubling loop for a subnormal
"""
import re
import struct
import sys

# WHICH=full (default) is the whole routine; the others return one intermediate,
# which is how a divergence gets localised: return the reduction's r, or the
# kernel, or v, and compare against the Y version's own value at that point.
WHICH = sys.argv[2] if len(sys.argv) > 2 else "full"

MATHY = "src/y/std/math.y"
src = open(MATHY).read()


def bits(v: float) -> int:
    return struct.unpack("<q", struct.pack("<d", v))[0]


def let_floats(name: str) -> list:
    """The `let NAME: float = a; b; c;` list, in order."""
    m = re.search(r"^let %s: \[float\] = \[(.*?)\];" % name, src, re.S | re.M)
    assert m, name
    body = m.group(1)
    vals = []
    for tok in body.split(","):
        tok = tok.strip()
        if not tok:
            continue
        if tok.startswith("- "):
            tok = "-" + tok[2:]
        vals.append(float(tok))
    return vals


def let_float(name: str) -> float:
    m = re.search(r"^let %s: float = ([-0-9.eE+]+);" % name, src, re.M)
    assert m, name
    return float(m.group(1))


def fn_body(name: str) -> str:
    m = re.search(r"^def %s\(.*?^\};" % name, src, re.S | re.M)
    assert m, name
    return m.group(0)


# ── the constants, read not copied ────────────────────────────────────────
exp_hi = let_float("exp_hi")
exp_lo = let_float("exp_lo")
log2e = let_float("log2e")
ln2_hi = let_float("ln2_hi")
ln2_lo = let_float("ln2_lo")
exp_k = let_floats("exp_k")
exp_kl = let_floats("exp_kl")
assert len(exp_k) == len(exp_kl) and len(exp_k) == 13, (len(exp_k), len(exp_kl))

# A sanity check that the parse is right, before anything is emitted: the same
# Horner in Python, in the same order, must land within an ulp of exp(r) for a
# few r. If it does not, the table was mis-parsed and everything after is wrong.
import math


def kernel(r: float) -> float:
    p, q = exp_k[12], exp_kl[12]
    for i in range(11, -1, -1):
        p = p * r + exp_k[i]
        q = q * r + exp_kl[i]
    return p + q


for r in (0.0, 0.1, -0.2, 0.34657359027997264):
    got = 1.0 + r * (1.0 + r * kernel(r))
    want = math.exp(r)
    assert abs(got - want) <= 4e-16 * max(1.0, abs(want)), (r, got, want)

# ── the table ─────────────────────────────────────────────────────────────
# One label, one block: a label per entry costs the shaker ~2K instructions of
# label-map fixpoint each, on every compile of every program.
tab = []          # (name, bits)
order = []        # the offsets, in the order the routine reads them


def add(name: str, v: float) -> int:
    tab.append((name, bits(v)))
    return 8 * (len(tab) - 1)


off_ehi = add("ehi", exp_hi)
off_elo = add("elo", exp_lo)
off_l2e = add("l2e", log2e)
off_ln2h = add("ln2h", ln2_hi)
off_ln2l = add("ln2l", ln2_lo)
off_half = add("half", 0.5)
off_one = add("one", 1.0)
off_two = add("two", 2.0)
off_2p = add("p1022", 4.49423283715578977e307)      # ldexp's big up step
off_2n = add("n1022", 2.2250738585072014e-308)      # ldexp's big down step
for i, v in enumerate(exp_k):
    add("k%d" % i, v)
for i, v in enumerate(exp_kl):
    add("kl%d" % i, v)


def ko(i: int) -> int:
    return 8 * (10 + i)


def klo(i: int) -> int:
    return 8 * (23 + i)


# ── the routine ───────────────────────────────────────────────────────────
# Registers: xmm0 scratch, xmm1 nf, xmm2 x (then r), xmm3 scratch, xmm4 p,
# xmm5 q, xmm6 f2, xmm7 spare. GPRs: rax the answer's bits / the long n,
# rcx k, rdx the exponent field, r8 scratch.

L = []


def w(line: str = "") -> None:
    """One line of assembly, or one line of comment.

    A comment that TRAILS an instruction is not a comment here: arch_asm_lines
    drops a line only when its first byte is `#`, so what follows becomes an
    operand and the assembler says `L###: bad operand` about an opcode the
    prelude uses everywhere. So every comment becomes a whole flush-left line,
    above the instruction it belongs to. (make asm-check passes either way --
    GNU as reads trailing comments and ycc's assembler does not.)
    """
    body, sep, tail = line.partition("  #")
    if sep and not body.lstrip().startswith("#"):
        L.append("#" + tail)
        L.append(body)
    else:
        L.append(line)


w("# y_exp: exp(x). Generated from src/y/std/math.y's exp by")
w("# test/math/gen_kernel.py-style reading of its own constants -- do not retype")
w("# the table, because the whole constraint is that this returns the same double")
w("# as that function, and a table typed by hand can disagree with it silently.")
w("#")
w("# The operation sequence is the Y line for line, which is what makes the bits")
w("# match: the same multiplies and subtracts in the same order, the same two")
w("# Horner chains for the split kernel, the same ldexp including its big steps")
w("# and its doubling loop for a subnormal answer. `t310`-style: the oracle is")
w("# math.exp itself and every call site compares bits.")
w("#")
w("# Argument at 8(%rsp) (the last and only one), answer's bits in %rax.")
w("y_exp:")
w("    mov 8(%rsp), %rax")
w("    movq %rax, %xmm2                   # xmm2 = x, kept for the reduction")
w("    movq %xmm2, %xmm0")
w("# if (x != x) return x: the operand compared with itself is unordered exactly")
w("# when it is a NaN, and unordered is the only answer with PF set.")
w("    ucomisd %xmm2, %xmm2")
w("    jp yexp_ret")
w("# if (x > exp_hi) return +inf")
w("    ucomisd yexp_tab+%d(%%rip), %%xmm2" % off_ehi)
w("    ja yexp_inf")
w("# if (x < exp_lo) return +0.0")
w("    ucomisd yexp_tab+%d(%%rip), %%xmm2" % off_elo)
w("    jb yexp_zero")
w("")
w("# n = to_int(floor(x*log2e + 0.5)). The truncating convert is a floor only")
w("# when the value it truncated was already at or below the integer; one less")
w("# when the truncation rounded UP, which is when the truncated value is")
w("# GREATER than what it came from -- a negative argument, or one in 1.0..1.5.")
w("    mulsd yexp_tab+%d(%%rip), %%xmm0" % off_l2e)
w("    addsd yexp_tab+%d(%%rip), %%xmm0    # t = x*log2e + 0.5" % off_half)
w("    cvttsd2si %xmm0, %rax              # trunc(t)")
w("    cvtsi2sd %rax, %xmm1")
w("    ucomisd %xmm0, %xmm1              # trunc(t) against t")
w("    jbe yexp_k_ok")
w("    sub $1, %rax                       # it rounded up: one less")
w("yexp_k_ok:")
w("    cvtsi2sd %rax, %xmm1               # xmm1 = nf")
w("")
w("# r = (x - nf*ln2_hi) - nf*ln2_lo: ln2 in two pieces so the reduction keeps")
w("# the low bits, which is what one rounding of nf*ln2 would have lost.")
w("    movsd %xmm1, %xmm3")
w("    mulsd yexp_tab+%d(%%rip), %%xmm3" % off_ln2h)
w("    subsd %xmm3, %xmm2")
w("    movsd %xmm1, %xmm3")
w("    mulsd yexp_tab+%d(%%rip), %%xmm3" % off_ln2l)
w("    subsd %xmm3, %xmm2                # xmm2 = r")
w("")
w("# k and f2: 2^1024 is an overflow and round(x*log2e) reaches 1024 for every x")
w("# above 709.4, so the last whole ln2 stays in r and its factor of two is put")
w("# in by hand -- which also keeps r inside the kernel's range.")
w("    mov %rax, %rcx                     # rcx = k")
w("    movsd yexp_tab+%d(%%rip), %%xmm6    # f2 = 1.0" % off_one)
w("    cmp $1023, %rcx")
w("    jle yexp_f2_ok")
w("    sub $1, %rcx")
w("    movsd yexp_tab+%d(%%rip), %%xmm6    # f2 = 2.0" % off_two)
w("yexp_f2_ok:")
if WHICH == "n":
    w("    movq %xmm1, %rax")
    w("    ret")

w("")
w("# P = poly_split(exp_k, exp_kl, r): two Horner chains over the split table,")
w("# so a term whose low part would fall off the end of a double is kept, and")
w("# one add at the end brings the two halves together.")
w("    movsd yexp_tab+%d(%%rip), %%xmm4" % ko(12))
w("    movsd yexp_tab+%d(%%rip), %%xmm5" % klo(12))
for i in range(11, -1, -1):
    w("    mulsd %xmm2, %xmm4")
    w("    addsd yexp_tab+%d(%%rip), %%xmm4" % ko(i))
    w("    mulsd %xmm2, %xmm5")
    w("    addsd yexp_tab+%d(%%rip), %%xmm5" % klo(i))
w("    addsd %xmm5, %xmm4")
if WHICH == "r":
    w("    movq %xmm2, %rax")
    w("    ret")
if WHICH == "P":
    w("    movq %xmm4, %rax")
    w("    ret")

w("")
w("# v = f2 * (1 + r*(1 + r*P))")
w("    movsd %xmm2, %xmm3")
w("    mulsd %xmm4, %xmm3")
w("    addsd yexp_tab+%d(%%rip), %%xmm3" % off_one)
w("    mulsd %xmm2, %xmm3")
w("    addsd yexp_tab+%d(%%rip), %%xmm3" % off_one)
w("    mulsd %xmm6, %xmm3")
if WHICH == "v":
    w("    movq %xmm3, %rax")
    w("    ret")

w("")
w("# ldexp(v, k), as written in std/math.y: the big steps first, so that after")
w("# them the answer may already be 0 or an infinity and there is nothing left")
w("# to do exactly. 2^1022 rather than 2^1023: one more step than the range")
w("# needs, so a step never overflows on its own.")
# %rdx is the value, the way `r` is the variable in the Y: the big steps and the
# field shift all work on it and the answer is in it at the end. Doing it any
# other way means one of the paths returns the value from BEFORE its own step --
# which is what the first version did, and the symptom was exp(1) coming back as
# e^r with the 2^k simply missing.
w("# ldexp(v, k), as written in std/math.y: the big steps first, so that after")
w("# them the answer may already be 0 or an infinity and there is nothing left")
w("# to do exactly. 2^1022 rather than 2^1023: one more step than the range")
w("# needs, so a step never overflows on its own.")
w("    movq %xmm3, %rdx                   # rdx = the value")
w("    cmp $1022, %rcx")
w("    jl yexp_ld_up_done")
w("    movq %rdx, %xmm4")
w("    mulsd yexp_tab+%d(%%rip), %%xmm4" % off_2p)
w("    movq %xmm4, %rdx")
w("    sub $1022, %rcx")
w("yexp_ld_up_done:")
w("    cmp $-1022, %rcx")
w("    jg yexp_ld_dn_done")
w("    movq %rdx, %xmm4")
w("    mulsd yexp_tab+%d(%%rip), %%xmm4" % off_2n)
w("    movq %xmm4, %rdx")
w("    add $1022, %rcx")
w("yexp_ld_dn_done:")
w("# f = exp_field(r) = the pattern's exponent field")
w("    mov %rdx, %rax")
w("    shr $52, %rax")
w("    and $2047, %rax")
w("# if (f == 0 || f + k < 1) the mantissa has to shift too, and one doubling at")
w("# a time is how that is exact -- which is also the subnormal case, where the")
w("# field is 0 and every step is a doubling.")
w("    test %rax, %rax")
w("    jz yexp_ld_shift")
w("    mov %rax, %r8")
w("    add %rcx, %r8")
w("    cmp $1, %r8")
w("    jl yexp_ld_shift")
w("# else if (k != 0): k * 2^52 added to the bits is k added to the field, so the")
w("# sign comes off first (a negative pattern would put a 1 at the top of the")
w("# field and scale the wrong way) and goes back on after.")
w("    test %rcx, %rcx")
w("    jz yexp_ld_done")
w("# The sign that matters is the VALUE's. `js` after the `shl` would be reading")
w("# k's -- the first version did exactly that, so every x below about zero")
w("# (half the range) took the negative path and had 2^63 added to a pattern")
w("# that was already positive.")
w("    test %rdx, %rdx")
w("    js yexp_ld_neg")
w("    mov %rcx, %r8")
w("    shl $52, %r8")
w("    add %r8, %rdx")
w("    jmp yexp_ld_done")
w("yexp_ld_neg:")
w("    mov %rcx, %r8")
w("    shl $52, %r8")
w("    add %r8, %rdx")
w("# shifted + sign_bit(). 2^63 is one past the largest long, so it is a movabs")
w("# rather than an immediate: `mov $4611686018427387904, %r8` cannot be spelled,")
w("# and `mov $-1, %r8; shl $63, %r8` would be one instruction longer for the")
w("# same bits.")
w("    mov $-9223372036854775808, %r8")
w("    add %r8, %rdx")
w("    jmp yexp_ld_done")
w("yexp_ld_shift:")
w("    test %rcx, %rcx")
w("    jz yexp_ld_done")
w("    cmp $0, %rcx")
w("    jg yexp_ld_up_loop")
w("    movsd yexp_tab+%d(%%rip), %%xmm7    # 0.5" % off_half)
w("    jmp yexp_ld_loop")
w("yexp_ld_up_loop:")
w("    movsd yexp_tab+%d(%%rip), %%xmm7    # 2.0" % off_two)
w("yexp_ld_loop:")
w("    movq %rdx, %xmm4")
w("    mulsd %xmm7, %xmm4")
w("    movq %xmm4, %rdx")
w("    add $1, %rcx")
w("    jnz yexp_ld_loop")
w("yexp_ld_done:")
w("    mov %rdx, %rax")
w("yexp_ret:")
w("    ret")
w("yexp_inf:")
w("    mov $9218868437227405312, %rax    # +inf")
w("    ret")
w("yexp_zero:")
w("    xor %eax, %eax                     # +0.0")
w("    ret")
w("")

# ── the table block ───────────────────────────────────────────────────────
w("# yexp_tab: exp's constants and its split kernel, one label for the lot (a")
w("# label per entry costs the shaker ~2K instructions of fixpoint each, on")
w("# every compile). Read as yexp_tab+N(%rip), N = 8*index.")
w("yexp_tab:")
for name, b in tab:
    w("    .quad %d    # %s" % (b, name))
w("")


out = "\n".join(L) + "\n"
if len(sys.argv) > 1:
    open(sys.argv[1], "w").write(out)
else:
    sys.stdout.write(out)

print("# generated %d lines, %d table entries (%d bytes)" % (len(L), len(tab), 8 * len(tab)),
      file=sys.stderr)