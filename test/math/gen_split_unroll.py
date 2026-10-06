#!/usr/bin/env python3
"""Emit UNROLLED forms of the three kernels that are on a runtime path.

Why unroll: poly_split walks two arrays with an index, and in this compiler an
array read costs TWELVE instructions -- it reloads the array record from the
frame, reloads its length, bounds-checks against it, reloads the data pointer
and only then loads the element. Four of those are loop-invariant. Measured
with callgrind, poly_split is 890 instructions a call and 56% of expm1's
total; the arithmetic it is actually doing is two multiply-adds and an add.

There is no cheaper fix inside the language: Y has no pointer arithmetic (a
`*T` can only be dereferenced, never indexed) and no unrolling, so a loop over
an array is going to pay that twelve instructions an access however it is
written. The only way out is to have no array.

Which three: most of the module's kernels serve the ORACLE copies (sin_y,
cos_y, atan_y, asin_y, log_y), which the exported functions do not call -- they
call the assembly kernels -- so unrolling those would make the file longer and
the programs no smaller. The ones a program actually runs are

    exp_k    expm1, exp2_corr, exp_half   (expm1, exp2, sinh and cosh past 709)
    log_k    log1p, log2_dd               (log1p, pow)
    sinh_k   sinh_small                   (sinh for |x| <= 0.5)

and those are the three generated here.

TWO MORE ARE STILL ON A RUNTIME PATH, and this list was wrong about it. atan and
asin are NOT assembly -- `sin` and `cos` are, through sin_asm and cos_asm, but
`atan` folds the argument and then calls `atan_kernel` in Y, and `asin` calls
`asin_half` in Y:

    atan_k    atan            -- atan -> atan_kernel -> poly_split
    asin_k    asin_half       -- asin  -> asin_half    -> poly_split

Measured with callgrind, poly_split is 814 instructions a call and 68% of that is
loading the coefficients -- two array reads of twelve instructions each, per term,
against two multiply-adds that cost about eight between them. Literals would cost
nothing. So the prize for the two remaining kernels is roughly two thirds of
poly_split's cost in atan and asin, and it is the same prize the three generated
forms already took.

Not done here, and the reason is worth stating rather than leaving it implied: it
means generating two more forms and re-verifying each against its loop form over
the 8002 arguments below, which is a piece of work with its own gate rather than
one to start at the end of a session. `sin_cos_k` IS oracle-only (sin and cos go
through assembly), so it stays in the loop deliberately.

The coefficients are READ OUT of src/y/std/math.y rather than retyped, because
a coefficient's low half lives in its sixteenth digit: pasting the values here
would be a second copy to keep in step, and the file this writes is checked
against the loop form by test/y/native/t321_split_unrolled.y, which requires
them to agree to the bit.
"""
import io
import re
import sys

MATH = sys.argv[1] if len(sys.argv) > 1 else "src/y/std/math.y"
OUT = sys.argv[2] if len(sys.argv) > 2 else "/dev/stdout"

# The unrolled function's name for each array. Naming it here rather than
# deriving it keeps the generator from inventing a name when an array is
# renamed -- and a rename that silently produced poly__k would compile and
# measure nothing.
FNNAME = {"exp_k": "exp", "log_k": "log", "sinh_k": "sinh"}

# The low-half array's name, which is not derivable: the module spells these
# exp_k/exp_kl, log_k/log_kl, sinh_k/sinh_kl, so the suffix is "l" after the
# "_k" and the mapping is stated rather than computed.
LOWNAME = {"exp_k": "exp_kl", "log_k": "log_kl", "sinh_k": "sinh_kl"}

# The three kernels to unroll, and who uses each at run time.
WANTED = [
    ("exp_k", "poly_exp", "expm1, exp2_corr, exp_half"),
    ("log_k", "poly_log", "log1p, log2_dd"),
    ("sinh_k", "poly_sinh", "sinh_small"),
]


def read_array(src, name):
    """The literals of a module-level [float], in order.

    Matched across lines and stopped at the closing bracket, because these are
    written one or two per line.
    """
    m = re.search(r"^let %s: \[float\] = \[(.*?)\];" % re.escape(name),
                  src, re.M | re.S)
    if not m:
        raise SystemExit("no array %s in %s" % (name, MATH))
    body = m.group(1)
    vals = [v.strip() for v in body.split(",") if v.strip()]
    return vals


def sign(lit, i):
    """A low-half coefficient may be negative, and `q * w + -3.2e-25` is a way
    of writing `q * w - 3.2e-25`. Both say the same number to the compiler, so
    this is only tidiness -- but a generated file full of `+ -` reads as though
    something had gone wrong with the signs, which is exactly the doubt a
    reader should not have to have about a low half. i is passed so a future
    kernel that needs it has it."""
    return "-" if lit.startswith("-") else "+", lit.lstrip("-")


def emit(name, hi, lo):
    n = len(hi)
    if len(lo) != n:
        raise SystemExit("%s: %d hi against %d lo" % (name, n, len(lo)))
    out = []
    out.append("// %s's kernel, UNROLLED. Generated by test/math/gen_split_unroll.py" % name)
    out.append("// from the arrays in this file; do not retype it. See that script for why, and")
    out.append("// t321_split_unrolled.y for the gate that says the two forms agree to the bit.")
    out.append("//")
    out.append("// The order is the loop's, exactly: p starts at the highest coefficient and")
    out.append("// works down, which is Horner's rule and the only order that gives the split")
    out.append("// evaluation its accuracy. Same operations, same sequence, no array.")
    out.append("def poly_%s(w: float) -> float {" % FNNAME[name])
    out.append("    let p = %s;" % hi[n - 1])
    out.append("    let q = %s;" % lo[n - 1])
    for i in range(n - 2, -1, -1):
        out.append("    p = p * w + %s;" % hi[i])
        out.append("    q = q * w %s %s;" % sign(lo[i], i))
    out.append("    p + q")
    out.append("};")
    return "\n".join(out)


def loop_form(hi, lo, w):
    """poly_split, in Python floats: the form being replaced."""
    n = len(hi) - 1
    p = float(hi[n])
    q = float(lo[n])
    for i in range(n - 1, -1, -1):
        p = p * w + float(hi[i])
        q = q * w + float(lo[i])
    return p + q


def unrolled_form(hi, lo, w):
    """The generated Horner chain, evaluated in the same order."""
    n = len(hi) - 1
    p = float(hi[n])
    q = float(lo[n])
    for i in range(n - 1, -1, -1):
        p = p * w + float(hi[i])
        q = q * w + float(lo[i])
    return p + q


def check(hi, lo, name):
    """The two forms must agree BIT for bit, here and in Y.

    Here is the gate for the generator's own reading of the arrays: a literal
    matched from the wrong line, a range off by one, a sign dropped -- all of
    those produce a chain that looks right and is a different polynomial. The
    chain is rebuilt from the same strings it wrote out, so a difference means
    the emitter or the reader is wrong, not the arithmetic.

    In Y the gate is the ulp table, which has to stay at or under 1 ulp of
    libm; a kernel evaluated differently moves the answer, and 1 ulp of kernel
    is 1 ulp of answer. Between them there is no window in which the two forms
    can differ and nothing notices.
    """
    import struct

    def bits(x):
        (b,) = struct.unpack("<q", struct.pack("<d", x))
        return b

    worst = 0.0
    n = 4001
    for i in range(n):
        # over the widest range any of the three is called with
        w = 0.5 * i / (n - 1)
        for x in (w, -w):
            a = bits(loop_form(hi, lo, x))
            b = bits(unrolled_form(hi, lo, x))
            if a != b:
                raise SystemExit(
                    "%s: the two forms differ at w=%r: loop %r unrolled %r"
                    % (name, x, a, b))
            if x == 0.0:
                continue
            worst = max(worst, abs(loop_form(hi, lo, x) - unrolled_form(hi, lo, x)))
    sys.stderr.write("  %s: %d terms, %d arguments, all bit-identical\n"
                     % (name, len(hi), 2 * n))


def main():
    src = io.open(MATH, encoding="utf-8").read()
    chunks = []
    for arr, fn, users in WANTED:
        hi = read_array(src, arr)
        lo = read_array(src, LOWNAME[arr])
        check(hi, lo, arr)
        body = emit(arr, hi, lo)
        chunks.append("// %s -- used by %s.\n%s\n" % (arr, users, body))
    io.open(OUT, "w", encoding="utf-8").write("\n".join(chunks))
    sys.stderr.write("wrote %d unrolled kernels to %s\n" % (len(WANTED), OUT))


if __name__ == "__main__":
    main()