#!/usr/bin/env python3
"""Write test/math/ulp_table.txt: one case per line, the reference values.

Every line is

    function arg1_bits [arg2_bits] want_bits

with the doubles as IEEE-754 bit patterns in decimal, because the harness
(test/math/ulp_check.y) reads them with tonum, which is decimal. The reference
is this platform's libm -- glibc's, which is the fdlibm algorithms -- so the
table is "what C's math.h gives", and the harness measures how far
std/math.y is from it in ulps.

Run it after changing a case list:

    python3 test/math/gen_ulp_table.py > test/math/ulp_table.txt

and commit the table it prints. The generator is not part of any gate: the
table is the checked-in artefact, and a machine whose libm disagreed with this
one would be arguing with a checked-in answer, which is the point.
"""
import math
import struct
import sys
from decimal import Decimal, getcontext

# The cube root at 60 digits, rounded once at the end: x ** (1/3) is not it
# (1/3 is not exact, and pow is a different function), and this platform's
# Python has no math.cbrt to ask.
getcontext().prec = 60


def cbrt_ref(x):
    if x != x or math.isinf(x) or x == 0.0:
        return x
    neg = x < 0.0
    v = float(Decimal(abs(x)) ** (Decimal(1) / Decimal(3)))
    return -v if neg else v


def zeros(fn):
    """C's floor/ceil/trunc/round/fract keep the sign of a zero; Python's return
    an int, which loses it. Same answer, one bit less information."""
    def g(x):
        if x == 0.0 and math.copysign(1.0, x) < 0:
            return -0.0
        return float(fn(x))
    return g


def bits(x):
    return struct.unpack("<q", struct.pack("<d", x))[0]


def unbits(b):
    return struct.unpack("<d", struct.pack("<q", b))[0]


# The cases. Each is (function name, argument, [second argument]) -- the value
# written here is the ARGUMENT, spelled as a double; the table gets its bits.
ONE = {
    # sqrt: exact for a perfect square, correctly rounded otherwise
    "sqrt": [0.0, -0.0, 1.0, 2.0, 4.0, 9.0, 0.5, 1e-8, 1e8, 1e300, 1e-300,
             3.0, 5.0, 7.0, 1e16, 1e-16, 2.0 ** 52, 2.0 ** -52, 123456789.0,
             float("inf"), float("nan"), -1.0, -4.0],
    # floor/ceil/trunc/round: the integer boundary, both signs, subnormals
    "floor": [0.0, -0.0, 0.5, -0.5, 1.0, -1.0, 1.5, -1.5, 2.5, -2.5,
              4503599627370496.0, -4503599627370496.0, 1e16, 1e16 + 2.0,
              1e300, -1e300, 5e-324, -5e-324, float("inf"), float("-inf"),
              float("nan"), 9007199254740993.0, 1234.5678, -1234.5678,
              2.0 ** 62, -(2.0 ** 62), 9223372036854774784.0,
              -9223372036854775808.0, 4503599627370496.0 + 0.5],
    "ceil": [0.0, -0.0, 0.5, -0.5, 1.0, -1.0, 1.5, -1.5, 2.5, -2.5,
             4503599627370496.0, -4503599627370496.0, 1e16, 1e16 + 2.0,
             1e300, -1e300, 5e-324, -5e-324, float("inf"), float("-inf"),
             float("nan"), 9007199254740993.0, 1234.5678, -1234.5678],
    "trunc": [0.0, -0.0, 0.5, -0.5, 1.0, -1.0, 1.5, -1.5, 2.5, -2.5,
              4503599627370496.0, -4503599627370496.0, 1e16, 1e16 + 2.0,
              1e300, -1e300, 5e-324, -5e-324, float("inf"), float("-inf"),
              float("nan"), 9007199254740993.0, 1234.5678, -1234.5678,
              2.0 ** 62, -(2.0 ** 62), 9223372036854774784.0,
              -9223372036854775808.0, 4503599627370496.0 + 0.5],
    "round": [0.0, -0.0, 0.5, -0.5, 1.0, -1.0, 1.5, -1.5, 2.5, -2.5, 0.49,
              -0.49, 0.51, -0.51, 1e16, 1e16 + 2.0, 4503599627370496.0,
              -4503599627370496.0, 1e300, -1e300, 1234.5678, -1234.5678,
              float("inf"), float("nan")],
    "fract": [0.0, -0.0, 0.5, -0.5, 1.5, -1.5, 2.25, -2.25, 1234.5678,
              -1234.5678, 1e16, 1e300, -1e300, float("inf"), float("nan")],
    # to_int: the range edges, the truncation, exact large longs
    # the cases in range only: 2^63 and past stop the program (to_int traps),
    # which a table-driven program cannot be asked to survive -- see
    # test/y/native/t307_math_trap.y
    # is_signed_zero: the answer is a float carrying 1.0/0.0
    "is_signed_zero": [0.0, -0.0, 1.0, -1.0, 5e-324, -5e-324,
                       float("nan"), float("inf")],
    # frexp: checked by the identity the harness re-checks, so the reference is
    # the input itself whenever frexp is exact (it is: no rounding anywhere)
    "frexp": [0.0, -0.0, 1.0, -1.0, 2.0, 0.5, 5e-324, -5e-324, 1e300,
              -1e300, 1e-300, 3.0, 4503599627370496.0, float("inf"),
              float("nan")],
    # is_signed_zero: the answer is a float carrying 1.0 or 0.0
    "is_signed_zero": [0.0, -0.0, 1.0, -1.0, 5e-324, -5e-324,
                       float("nan"), float("inf")],
    # frexp: the table carries x itself and the harness re-checks the identity
    # ldexp(bitsf(fraction), exponent) == x, which is the whole of frexp (there
    # is no rounding in it anywhere, so an answer that does not put back is a
    # bug rather than a last-bit question)
    "frexp": [0.0, -0.0, 1.0, -1.0, 2.0, 0.5, 5e-324, -5e-324, 1e300,
              -1e300, 1e-300, 3.0, 4503599627370496.0, float("inf"),
              float("nan")],
    "to_int": [0.0, -0.0, 1.0, -1.0, 0.9, -0.9, 2.0 ** 31, -(2.0 ** 31),
               2.0 ** 52, -(2.0 ** 52), 2.0 ** 62, -(2.0 ** 62), 1e18,
               -1e18, 9223372036854774784.0, -9223372036854775808.0,
               4294967296.0, -4294967296.0],
    # cbrt: Newton on cubes, and the subnormal corner
    "cbrt": [0.0, -0.0, 1.0, -1.0, 8.0, -8.0, 27.0, 2.0, 3.0, 10.0, 0.001,
             -0.001, 1e300, -1e300, 1e-300, -1e-300, 5e-324, -5e-324,
             float("inf"), float("-inf"), float("nan"), 1e100, 2.0 ** 60],
}

TWO = {
    # hypot: the overflow that a naive x*x + y*y hits, and the underflow
    "hypot": [(3.0, 4.0), (0.0, 0.0), (-0.0, 0.0), (1.0, 0.0), (0.0, 1.0),
              (1e200, 1e200), (-1e200, 1e200), (1e-200, 1e-200),
              (5e-324, 5e-324), (float("inf"), 1.0), (1.0, float("-inf")),
              (float("nan"), 1.0), (3.0, 4.0), (2.0 ** 26, 2.0 ** 26)],
    # nextafter: every direction, both zeros, the extremes
    "nextafter": [(1.0, 2.0), (1.0, 0.0), (-1.0, 0.0), (0.0, 1.0),
                  (0.0, -1.0), (-0.0, 1.0), (-0.0, -1.0), (1.0, 1.0),
                  (5e-324, 0.0), (float("inf"), 1.0), (1.0, float("inf")),
                  (1.7976931348623157e308, 1.0),
                  (-1.7976931348623157e308, -1.0), (0.0, 0.0),
                  (-0.0, -0.0), (0.0, -0.0), (float("nan"), 1.0)],
}

# Every single-argument function the harness knows, so a name cannot go missing
# without the table noticing.
ONE_ARG_FNS = sorted(set(ONE) | {"exp", "log", "log2", "log10", "log1p",
                                 "expm1", "pow", "sin", "cos", "tan", "asin",
                                 "acos", "atan", "sinh", "cosh", "tanh"})

REF1 = {
    "sqrt": lambda x: math.sqrt(x) if x >= 0 else float("nan"),
    # math.floor(inf) raises in Python where C returns inf, so the infinite and
    # NaN cases answer themselves first
    "floor": lambda x: x if math.isinf(x) or math.isnan(x) else zeros(math.floor)(x),
    "ceil": lambda x: x if math.isinf(x) or math.isnan(x) else zeros(math.ceil)(x),
    "trunc": lambda x: x if math.isinf(x) or math.isnan(x) else zeros(math.trunc)(x),
    "round": lambda x: (x if math.isinf(x) or math.isnan(x)
                        else zeros(lambda v: math.floor(v + 0.5) if v >= 0
                                   else math.ceil(v - 0.5))(x)),
    # C99: fract(+-inf) is a NaN (inf - trunc(inf)), and that is the answer
    # fract is x - trunc(x), and -0.0 - -0.0 is +0.0: the signed zero does NOT
    # survive this one (which is why zeros() does not wrap it)
    "fract": lambda x: (x if math.isnan(x)
                        else float("nan") if math.isinf(x)
                        else x - x if x == 0.0 else x - math.trunc(x)),
    "cbrt": cbrt_ref,
    "to_int": lambda x: float(math.trunc(x)) if -2.0 ** 63 <= x < 2.0 ** 63 else float("nan"),
}

REF2 = {
    "hypot": math.hypot,
    "nextafter": math.nextafter,
}


def main():
    out = []
    out.append("# test/math/ulp_table.txt -- generated by gen_ulp_table.py; do not")
    out.append("# hand-edit. Each line is: function arg1_bits [arg2_bits] want_bits,")
    out.append("# every double as its IEEE-754 bit pattern in decimal. The reference")
    out.append("# is this platform's libm. A '#' line or a blank one is ignored.")
    for name in sorted(ONE):
        for x in ONE[name]:
            if name == "to_int":
                want = math.trunc(x)
            elif name == "is_signed_zero":
                want = bits(1.0) if (x == 0.0 and math.copysign(1.0, x) < 0) else bits(0.0)
            elif name == "frexp":
                # frexp is exact, so "the answer" is the identity the harness
                # checks; the table carries x itself
                want = bits(x)
            else:
                want = bits(float(REF1[name](x)))
            out.append("%s %d %d" % (name, bits(x), want))
    for name in sorted(TWO):
        for (x, y) in TWO[name]:
            ref = REF2[name](x, y)
            if name == "nextafter":
                want = bits(ref)
            else:
                want = bits(float(ref))
            out.append("%s %d %d %d" % (name, bits(x), bits(y), want))
    sys.stdout.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()