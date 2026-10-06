"""Emit the UNROLLED form of every polynomial kernel on a runtime path.

Why unroll: poly_split walks two arrays with an index, and in this compiler an
array read costs TWELVE instructions -- it reloads the array record from the
frame, reloads its length, bounds-checks against it, reloads the data pointer
and only then loads the element. Measured with callgrind, poly_split is 814
instructions a call and 68% of that is LOADING THE COEFFICIENTS: two array
reads a term, against two multiply-adds costing about eight between them.

That 68% is the number worth keeping. The arithmetic the loop exists to do is a
small part of what it costs, and the twelve instructions are not the bounds
check -- y_oob is 3 a call, because the index runs from len-1 down to 0 and is
never out of range. They are the read sequence itself, four of them
loop-invariant.

There is no cheaper fix inside the language: Y has no pointer arithmetic (a
`*T` can only be dereferenced, never indexed) and no unrolling, so a loop over
an array pays those twelve an access however it is written. The only way out is
to have no array -- which means the coefficients become literals, and a
generated chain.

WHICH ones. This list was wrong twice, and both times in the same direction: it
under-counted what a program actually runs, because it assumed a kernel serving
an ORACLE copy was dead. The oracles (exp_y, log_y, sin_y, cos_y, atan_y,
asin_y) are real functions with their own tests, but an exported function only
calls one if it has no assembly kernel of its own:

    exp_k    expm1, exp2_corr, exp_half   (expm1, exp2, sinh and cosh past 709)
    log_k    log1p, log2_dd               (log1p, pow)
    sinh_k   sinh_small                   (sinh for |x| <= 0.5)
    tanh_k   tanh_small                   (tanh for |x| <= 0.5)
    atan_k   atan_kernel                  (atan: NOT assembly, it folds first)
    asin_k   asin_half                    (asin and acos both reach it)
    sin_k    sin_cos_k                    (via TAN -- sin and cos are assembly)
    cos_k    sin_cos_k                    (via TAN)

and those are the eight generated here. The two corrections, since both were
believed and both were wrong:

  - sin and cos ARE assembly (sin_asm, cos_asm), so sin_cos_k looked like it
    served their oracles only. It does not: `tan` is a Y function, and tan
    calls sin_cos_k twice a call. That made tan 1212 instructions a call, 72%
    of it the two array walks.
  - and atan and asin are not assembly either, which had been recorded as if
    they were.

poly_split is kept, for the oracles. It is a real function with real callers and
its loops are what sin_y, cos_y, exp_y and log_y evaluate; unrolling those would
make the file longer and the programs no smaller, since nothing a program calls
reaches them.

THE PRICE, stated rather than left out. A chain is more code than a loop: the
benchmark below trades roughly 5.5 KB of binary for 45-50% of the instructions
in atan, asin, acos and tan. That is a good trade for a function called in a
loop and a poor one for a program that calls it once and exits, so the honest
summary is that this makes these functions faster and the module bigger. exp,
log, sinh and tanh had already been unrolled for exactly this reason; the five
that followed are the same decision applied to the kernels that were missed.

The coefficients are READ OUT of src/y/std/math.y rather than retyped, because
a coefficient's low half lives in its sixteenth digit: pasting the values here
would be a second copy to keep in step. The gate for what this writes is
test/y/native/t328_split_unrolled.y, which asks both forms 32024 questions and
requires the same bits for all eight -- that file existed for none of them until
this one, though four of the chains had been carrying a signpost to it by name.
"""
import io
import re
import sys

# --verify takes no output path: it generates nothing on disk and instead asks
# whether src/y/std/math.y still holds EXACTLY what this script would write. It is
# a gate, and it earns its place because the drift is invisible: a chain that was
# hand-edited, or spliced from a generation made before a fix, still compiles,
# still answers within an ulp (the coefficients are right; only a comment or a
# stray term moved), and still reads as generated. That is what happened twice
# while this was being built -- four of the chains named a gate that did not
# exist, and the generator still emitted the dead name after the fix.
MATH = "src/y/std/math.y"
OUT = "/dev/stdout"
VERIFY = False
if sys.argv[1:2] == ["--verify"]:
    VERIFY = True
    MATH = sys.argv[2] if len(sys.argv) > 2 else MATH
else:
    MATH = sys.argv[1] if len(sys.argv) > 1 else MATH
    OUT = sys.argv[2] if len(sys.argv) > 2 else OUT

# The unrolled function's name for each array. Naming it here rather than
# deriving it keeps the generator from inventing a name when an array is
# renamed -- and a rename that silently produced poly__k would compile and
# measure nothing.
FNNAME = {"exp_k": "exp", "log_k": "log", "sinh_k": "sinh",
          "tanh_k": "tanh", "atan_k": "atan", "asin_k": "asin",
          "sin_k": "sin", "cos_k": "cos"}

# The low-half array's name, which is not derivable: the module spells these
# exp_k/exp_kl, log_k/log_kl, sinh_k/sinh_kl, so the suffix is "l" after the
# "_k" and the mapping is stated rather than computed.
LOWNAME = {"exp_k": "exp_kl", "log_k": "log_kl", "sinh_k": "sinh_kl",
           "tanh_k": "tanh_kl", "atan_k": "atan_kl", "asin_k": "asin_kl",
           "sin_k": "sin_kl", "cos_k": "cos_kl"}

# The three kernels to unroll, and who uses each at run time.
WANTED = [
    ("exp_k", "poly_exp", "expm1, exp2_corr, exp_half"),
    ("log_k", "poly_log", "log1p, log2_dd"),
    ("sinh_k", "poly_sinh", "sinh_small"),
    ("tanh_k", "poly_tanh", "tanh_small"),
    ("atan_k", "poly_atan", "atan_kernel"),
    ("asin_k", "poly_asin", "asin_half"),
    ("sin_k", "poly_sin", "sin_cos_k (via tan)"),
    ("cos_k", "poly_cos", "sin_cos_k (via tan)"),
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
    out.append("// t328_split_unrolled.y for the gate that says the two forms agree to the bit.")
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


# Each kernel's own domain, as its caller guarantees it. Kept for the record and
# for the gate, not to size the sweep.
#
#   exp_k    expm1, exp2_corr, exp_half   r = x - k*ln2   |r| <= ln(2)/2
#   log_k    log1p, log2_dd               z = w/(1+w)     <= 1/4
#   sinh_k   sinh_small                   |x| <= 0.5
#   tanh_k   tanh_small                   |x| <= 0.5
#   atan_k   atan_kernel                  |x| <= tan(pi/8)
#   asin_k   asin_half                    z = (1-a)/2     <= 1/4
#   sin_k    sin_cos_k, via tan           |x| <= pi/4
#   cos_k    sin_cos_k, via tan           |x| <= pi/4
#
# The sweep below uses the WIDEST of those -- (pi/4)^2, from sin_cos_k -- for
# every kernel. One sweep wider than any caller needs is strictly more evidence
# for a bit-identity check than eight narrower ones, because the chains are
# polynomials: there is no range outside which they stop being defined, so an
# argument past a caller's domain is still a question both forms must answer
# alike.
SPAN = (3.141592653589793 / 4.0) ** 2


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
    span = SPAN
    for i in range(n):
        # over the widest domain any caller passes, and past it where a kernel
        # is called on less
        w = span * i / (n - 1)
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
    sys.stderr.write("  %s: %d terms, %d arguments over |w| <= %g, all "
                     "bit-identical\n" % (name, len(hi), 2 * n, span))


def block(text, arr, fn):
    """The banner-plus-def block for one kernel, out of whatever text holds it.

    Matched on the array's name and the def's stem separately. Deriving one from
    the other -- asking for poly_<array>, say -- is the bug this file made while
    it was being written: the names do not always differ that way, and the regex
    that got it wrong matched nothing at all rather than matching the wrong
    thing, which is at least honest.
    """
    m = re.search(r"// %s -- used by .*?\ndef %s\(.*?\n};"
                  % (re.escape(arr), re.escape(fn)), text, re.S)
    if not m:
        raise SystemExit("no generated block for %s (%s) in %s" % (arr, fn, MATH))
    return m.group(0)


def verify(src):
    """Every chain in math.y must be byte-identical to what this script writes.

    The WHOLE block, banner included: the banner carries the list of callers, and
    a caller list gone stale is the same defect as a stale chain -- it compiles,
    it answers correctly, and it misleads whoever reads it next. Which is how
    poly_tanh came to claim it was generated by this script while the script did
    not list it.
    """
    bad = []
    for arr, fn, users in WANTED:
        hi = read_array(src, arr)
        lo = read_array(src, LOWNAME[arr])
        check(hi, lo, arr)
        mine = "// %s -- used by %s.\n%s\n" % (arr, users, emit(arr, hi, lo))
        if block(src, arr, fn) != mine.rstrip("\n"):
            bad.append(fn)
    if bad:
        raise SystemExit("math.y has drifted from the generator: %s\n"
                         "  re-run this script into math.y" % ", ".join(bad))
    sys.stderr.write("  math.y matches the generator for all %d kernels\n"
                     % len(WANTED))



def main():
    src = io.open(MATH, encoding="utf-8").read()
    if VERIFY:
        verify(src)
        return
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