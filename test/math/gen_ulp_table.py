#!/usr/bin/env python3
"""Write test/math/ulp_table.txt: one case per line, the reference values.

Every line is

    function arg1_bits [arg2_bits] want_bits

with the doubles as IEEE-754 bit patterns in decimal, because the harness
(test/math/ulp_check.y) reads them with tolong, which is decimal. The reference
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
import random
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


# The reduction's limit, in one place, for the three references that share it.
# 2^53 * (pi/2) -- the argument past which a quadrant stops being computable in a
# double. std/math.y's own pio2_max is the same number, and t320 pins both
# sides of it.
# The reduction's reach, tested the way the module tests it: on the expression
# to_int is handed, because a constant boundary is off by one double (at the
# largest argument whose quadrant fits, the product rounds UP to 2^63).
PIO2_TWO_OVER_PI = 6.36619772367581382433e-01
PIO2_LONGS_MAX = 9223372036854775807.0


def pio2_limit(x):
    q = x * PIO2_TWO_OVER_PI + 0.5
    return q < PIO2_LONGS_MAX and q > 0.0 - PIO2_LONGS_MAX


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
    # exp: the reduction's edges, the overflow and flush points, both signs
    "exp": [0.0, -0.0, 1.0, -1.0, 0.5, -0.5, 0.25, -0.25, 0.6931471805599453,
            10.0, -10.0, 100.0, -100.0, 700.0, -700.0, 709.0, 709.7, 709.78,
            709.782712893384, -745.0, -745.13, -745.2, -750.0, -800.0,
            1e-300, -1e-300, 1e300, 0.34657359027997264, -0.34657359027997264,
            36.0, -36.0, 0.001, -0.001, 1234.5678, -1234.5678,
            float("inf"), float("-inf"), float("nan")],
    "exp2": [0.0, 1.0, -1.0, 0.5, 3.0, -3.0, 10.0, -10.0, 1023.0, -1022.0,
             1024.0, -1074.0, -1075.0, 100.0, -100.0, 0.25, 31.0, -31.0],
    # log: 1 exactly, either side of it, the subnormal range, both signs
    "log": [1.0, 2.0, 10.0, 0.5, 0.1, 1.0e-300, 1.0e300, 5e-324,
            2.2250738585072014e-308, 1.0000000000000002, 0.9999999999999999,
            1.7976931348623157e308, 2.718281828459045, 3.141592653589793,
            1.0e-15, 1.0e15, 2.0 ** -1074, 2.0 ** 1023, 0.0, -1.0, -0.0,
            float("inf"), float("nan")],
    "log2": [1.0, 2.0, 4.0, 0.5, 1024.0, 1e300, 5e-324, 3.0, 10.0, 0.1],
    "log10": [1.0, 10.0, 100.0, 0.1, 1e300, 5e-324, 3.0, 2.0, 1000.0],
    # sin/cos/tan: the reduction's quadrants, the quarter points, the poles
    "sin": [0.0, -0.0, 0.5, -0.5, 1.0, -1.0, 0.7853981633974483,
            -0.7853981633974483, 1.5707963267948966, -1.5707963267948966,
            3.141592653589793, -3.141592653589793, 6.283185307179586,
            -6.283185307179586, 10.0, -10.0, 100.0, -100.0, 1000.0, 1e6,
            -1e6, 1e12, -1e12, 1e15, 0.001, -0.001, 1e-8, 12345.6789,
            float("inf"), float("-inf"), float("nan")],
    "cos": [0.0, -0.0, 0.5, -0.5, 1.0, -1.0, 0.7853981633974483,
            1.5707963267948966, 3.141592653589793, -3.141592653589793,
            6.283185307179586, -6.283185307179586, 10.0, -10.0, 100.0, -100.0,
            1000.0, 1e6, -1e6, 1e12, 1e15, 0.001, 12345.6789,
            float("inf"), float("nan")],
    # The last six are the region where the quadrant no longer fits a long, and
    # they are here because tan(1e30) used to KILL THE PROGRAM: to_int traps
    # rather than returning a wrong number, and a trap ends the program, which is
    # a worse answer than any number could be. The module answers NaN there and
    # the reference below says so -- libm would answer -0.009331875232662407 and
    # be two thousand times further from the truth.
    "tan": [0.0, -0.0, 0.5, -0.5, 1.0, -1.0, 0.7853981633974483,
            1.5707963267948966, -1.5707963267948966, 3.141592653589793,
            6.283185307179586, 10.0, -10.0, 100.0, -100.0, 0.001,
            12345.6789, 0.5 * 3.141592653589793,
            1e20, -1e20, 1e30, -1e30, 1e300, -1e300,
            float("inf"), float("nan")],
    "atan": [0.0, -0.0, 0.1, -0.1, 0.19891236737965801,
             -0.19891236737965801, 0.5, -0.5, 1.0, -1.0, 2.0, -2.0, 2.5, -2.5,
             10.0, -10.0, 1e300, -1e300, 5e-324, -5e-324, 0.7071067811865476,
             1.5, -1.5, float("inf"), float("-inf"), float("nan")],
    # expm1 and log1p: the ones a plain e^x - 1 or log(1+x) gets wrong at the
    # bottom of their range
    # The strip where the reduction's n becomes 1024, which is where 2^n stops
    # existing (2^1024 is one ulp past DBL_MAX) and where expm1 answered inf for
    # arguments whose answer is 1.35e308. The table carried 709.0 and 709.78
    # and nothing between, and the gap between two pinned points is not a
    # region: 709.4 is correct and 709.5 is not.
    "expm1": [0.0, -0.0, 1.0, -1.0, 0.5, -0.5, 1e-17, -1e-17, 1e-10, -1e-10,
              1e-8, 1e-5, 0.1, -0.1, 1.0e-300, -1.0e-300, 10.0, -10.0, 700.0,
              -700.0, 709.0, -745.0, -750.0, 0.6931471805599453, 36.0, -36.0,
              709.4, 709.44, 709.5, 709.6, 709.7, 709.75, 709.78,
              float("inf"), float("-inf"), float("nan")],
    "log1p": [0.0, -0.0, 1.0, -1.0, 0.5, -0.5, 1e-17, -1e-17, 1e-10, -1e-10,
              1e-8, 0.1, -0.1, 0.9, -0.9, 1e300, -1e-9, 1e-300, 1234.5678,
              -0.5, 0.5, float("inf"), float("nan")],
    # sinh/cosh/tanh: the cancellation the exponential form has near zero, and
    # the overflow above it.
    # The strip where the exponential form of sinh/cosh has already gone to inf
    # but the answer is still a double: 709.78 (exp's ceiling) to 710.4758 (the
    # true one). Those ten values per function are the cases that found the
    # bug, so they are here rather than only at 710.0.
    #
    # Note on the last of them: 710.47586007394398 written as a decimal literal
    # is a DIFFERENT double from the true bound 710.475860073943863... -- it
    # rounds up, PAST it, so the answer is inf. That is correct and worth
    # having: a boundary written as a literal is never on the boundary, and the
    # row now says so instead of the comment above claiming they overflow at
    # 709.78.
    "sinh": [0.0, -0.0, 1.0, -1.0, 0.5, -0.5, 0.1, -0.1, 1e-8, -1e-8, 1e-300,
             -1e-300, 10.0, -10.0, 100.0, -100.0, 700.0, -700.0, 0.001,
             1234.5678, float("inf"), float("-inf"), float("nan"),
             709.78, -709.78, 709.9, -709.9, 710.0, -710.0, 710.4, -710.4,
             710.47, 710.47586007394398],
    "cosh": [0.0, -0.0, 1.0, -1.0, 0.5, -0.5, 1e-8, 1e-300, 10.0, -10.0, 100.0,
             700.0, -700.0, 0.001, float("inf"), float("nan"),
             709.78, -709.78, 709.9, -709.9, 710.0, -710.0, 710.4, -710.4,
             710.47, 710.47586007394398],
    "tanh": [0.0, -0.0, 1.0, -1.0, 0.5, -0.5, 0.1, -0.1, 1e-8, -1e-8, 1e-300,
             -1e-300, 10.0, -10.0, 20.0, -20.0, 100.0, -100.0, 1e300,
             0.001, -0.001, float("inf"), float("-inf"), float("nan")],
    # asin/acos: the half-angle step's ends, and both zeros
    "asin": [0.0, -0.0, 0.1, -0.1, 0.5, -0.5, 0.9, -0.9, 0.9999999999999999,
             -0.9999999999999999, 1.0, -1.0, 1.0000000000000002, -1.0000000000000002,
             0.7071067811865476, 1234.5678, float("nan")],
    "acos": [0.0, -0.0, 0.1, -0.1, 0.5, -0.5, 0.9, -0.9, 0.9999999999999999,
             -0.9999999999999999, 1.0, -1.0, 0.7071067811865476,
             float("nan")],
    # is_signed_zero: the answer is a float carrying 1.0/0.0
    "is_signed_zero": [0.0, -0.0, 1.0, -1.0, 5e-324, -5e-324,
                       float("nan"), float("inf")],
    # frexp: checked by the identity the harness re-checks, so the reference is
    # the input itself whenever frexp is exact (it is: no rounding anywhere)
    "frexp": [0.0, -0.0, 1.0, -1.0, 2.0, 0.5, 5e-324, -5e-324, 1e300,
              -1e300, 1e-300, 3.0, 4503599627370496.0, float("inf"),
              float("nan")],
    # The five below are EXACT -- a sign-bit test, a comparison, a negation --
    # so their cases are not about ulps at all. They are here because a function
    # with no cases is a function with no gate, and that is how fmin/fmax's
    # zeros went on being decided by operand order for as long as they were.
    "fabs": [0.0, -0.0, 1.0, -1.0, float("inf"), float("-inf"), float("nan"),
             5e-324, -5e-324, 1e308, -1e308, 0.1, -0.1],
    "fsign": [0.0, -0.0, 1.0, -1.0, float("inf"), float("-inf"), float("nan"),
              5e-324, -5e-324, 1e308, -1e308, 0.1, -0.1],
    "is_nan": [0.0, -0.0, 1.0, -1.0, float("inf"), float("-inf"), float("nan"),
               5e-324, -5e-324, 1e308, -1e308],
    "is_inf": [0.0, -0.0, 1.0, -1.0, float("inf"), float("-inf"), float("nan"),
               5e-324, -5e-324, 1e308, -1e308],
    "is_finite": [0.0, -0.0, 1.0, -1.0, float("inf"), float("-inf"),
                  float("nan"), 5e-324, -5e-324, 1e308, -1e308],
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
    # A SEEDED SPREAD, not just the pinned points. The twenty-odd values above
    # are the ones somebody thought of, and cbrt was 2 ulps out on 3.5% of
    # ordinary arguments -- none of which any of them happened to be. The spread
    # is what found that, and it is also what holds the fix: with the residual
    # carried in double-double, cbrt is now the correctly rounded answer on every
    # argument tried, where libm is 3 ulps out on 1385 of 3030. (libm is NOT this
    # table's reference for cbrt -- cbrt_ref computes it in 60 digits and rounds
    # once -- and that is why the improvement could be gated at all: a libm
    # reference would have failed the correctly rounded answers.)
    "cbrt": [0.0, -0.0, 1.0, -1.0, 8.0, -8.0, 27.0, 2.0, 3.0, 10.0, 0.001,
             -0.001, 1e300, -1e300, 1e-300, -1e-300, 5e-324, -5e-324,
             float("inf"), float("-inf"), float("nan"), 1e100, 2.0 ** 60,
             1e-320, 2.2250738585072014e-308, -1.7976931348623157e308],
}

TWO = {
    # fmin/fmax: the edges, which are the whole point -- the zeros' signs, both
    # infinities, the smallest subnormal either side of zero, and a NaN in each
    # position. TWO_EXTRA crosses the same list with itself and adds the
    # ordinary arguments.
    "fmin": [(0.0, -0.0), (-0.0, 0.0), (0.0, 0.0), (-0.0, -0.0),
             (float("inf"), float("-inf")), (float("nan"), 2.0),
             (2.0, float("nan")), (float("nan"), float("nan"))],
    "fmax": [(0.0, -0.0), (-0.0, 0.0), (0.0, 0.0), (-0.0, -0.0),
             (float("-inf"), float("inf")), (float("nan"), 2.0),
             (2.0, float("nan")), (float("nan"), float("nan"))],
    # hypot: the overflow that a naive x*x + y*y hits, and the underflow
    # pow: the exact integer path, the log path, and every special case C has
    "pow": [(2.0, 10.0), (2.0, 0.5), (2.0, -1.0), (10.0, 3.0), (0.5, 0.5),
            (3.0, -2.5), (1.0000001, 12345.0), (0.9, 0.1), (1e300, 0.5),
            (2.0, 1024.0), (2.0, 1023.0), (2.0, -1074.0), (2.0, -1075.0),
            (2.0, 1e300), (0.9999999999999999, 1e15), (-2.0, 3.0), (-2.0, 4.0),
            (-2.0, 0.5), (-2.0, -3.0), (-0.0, 3.0), (-0.0, 2.0), (-0.0, -1.0),
            (0.0, -1.0), (0.0, 0.5), (0.0, -0.5), (0.0, 0.0), (1.0, 0.0),
            (1.0, 0.5), (1.0, 1e300), (-1.0, 0.5), (-1.0, 3.0), (-1.0, 1e300),
            (float("inf"), 0.5), (float("inf"), -0.5), (float("inf"), 2.0),
            (float("inf"), 3.0), (float("-inf"), 2.0), (float("-inf"), 3.0),
            (float("inf"), 0.0), (float("nan"), 0.0), (2.0, float("nan"))],
    # atan2: every quadrant, both axes, and the infinities
    "atan2": [(0.0, 1.0), (1.0, 0.0), (0.0, -1.0), (-1.0, 0.0), (1.0, 1.0),
              (1.0, -1.0), (-1.0, -1.0), (-1.0, 1.0), (0.0, 0.0), (-0.0, -1.0),
              (0.0, -0.0), (1e300, -1e300), (-1e300, 1e300), (1.0, 1e-300),
              (1e-300, 1.0), (0.5, 0.5), (3.0, 4.0), (-3.0, 4.0), (3.0, -4.0),
              (float("inf"), 1.0), (float("inf"), -1.0), (1.0, float("inf")),
              (-1.0, float("inf")), (1.0, float("-inf")),
              (float("inf"), float("inf")), (float("inf"), float("-inf")),
              (float("nan"), 1.0), (1.0, float("nan"))],
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

# Every single-argument function the table knows, so a name cannot go missing
# without the table noticing (test_math.sh checks the harness dispatches it).
ONE_ARG_FNS = sorted(set(ONE))

# The references for the functions whose ANSWER is a rule rather than a
# rounding: stated here as the rule, not as the module's expression, because a
# table generated from the implementation under test proves nothing.
def fmin_ref(a, b):
    """IEEE 754-2019 minNum, written out rather than borrowed.

    C99 says either sign may come back for a +-0 pair; minNum does not, and
    neither does this platform's libm. The module had the strict `<`, which made
    the answer depend on which operand came LAST, and the table had no case that
    could see it.
    """
    if math.isnan(a):
        return b
    if math.isnan(b):
        return a
    if a == 0.0 and b == 0.0:
        return -0.0 if (math.copysign(1.0, a) < 0 or math.copysign(1.0, b) < 0) else 0.0
    return a if a < b else b


def fmax_ref(a, b):
    """maxNum: the same rule with the other sign winning a tie."""
    if math.isnan(a):
        return b
    if math.isnan(b):
        return a
    if a == 0.0 and b == 0.0:
        return 0.0 if (math.copysign(1.0, a) > 0 or math.copysign(1.0, b) > 0) else -0.0
    return a if a > b else b


def fsign_ref(x):
    """The module's convention: 1, -1, or 0 -- and 0 for a NaN, which is the
    one place two libraries differ (Rust's f64::signum gives 1.0). Pinned here
    because a convention nobody writes down is a convention nobody keeps."""
    if math.isnan(x):
        return 0.0
    return 1.0 if x > 0.0 else (-1.0 if x < 0.0 else 0.0)


def lerp_ref(a, b, t):
    """The definition, and its two exact ends: t = 0 is a and t = 1 is b, both
    exactly, which is what a program relies on when it interpolates a frame."""
    return a + (b - a) * t


REF1 = {
    # The exact layer: no rounding anywhere, so these are the module's own
    # definitions restated -- which is the point of a table for them, to catch a
    # definition that CHANGES.
    "fabs": abs,
    "fsign": fsign_ref,
    "is_nan": lambda x: 1.0 if math.isnan(x) else 0.0,
    "is_inf": lambda x: 1.0 if math.isinf(x) else 0.0,
    "is_finite": lambda x: 1.0 if math.isfinite(x) else 0.0,
    # Python raises OverflowError where C returns an infinity, so the two edges
    # are spelled out: an overflow IS the answer there, not an error
    "exp": lambda x: (float("nan") if math.isnan(x) else
                      (math.exp(x) if -745.2 < x < 709.79 else
                       (float("inf") if x > 0 else 0.0))),
    "exp2": lambda x: (float("nan") if math.isnan(x) else
                       (2.0 ** x if -1080.0 < x < 1024.0 else
                        (float("inf") if x > 0 else 0.0))),
    "log": lambda x: (math.log(x) if x > 0 else
                      (float("-inf") if x == 0 else float("nan"))),
    "log2": lambda x: math.log2(x) if x > 0 else (float("-inf") if x == 0 else float("nan")),
    "log10": lambda x: math.log10(x) if x > 0 else (float("-inf") if x == 0 else float("nan")),
    # sin, cos and tan share one reference for the reduction's limit, so the
    # three cannot drift apart in what they claim. Past 2^53*(pi/2) the quadrant
    # wants more bits than a double can carry and the answers are not close --
    # sin(1e18) is -3.7e18 where the truth is -0.993 -- so the module answers NaN
    # and so does the reference. libm keeps going with a multi-precision
    # quotient, which is the honest answer and a different piece of work.
    "sin": lambda x: (float("nan") if math.isinf(x) else
                      (float("nan") if not pio2_limit(x) else math.sin(x))),
    "cos": lambda x: (float("nan") if math.isinf(x) else
                      (float("nan") if not pio2_limit(x) else math.cos(x))),
    "tan": lambda x: (float("nan") if math.isinf(x) else
                      (float("nan") if not pio2_limit(x) else math.tan(x))),
    "atan": lambda x: (math.atan(x) if not math.isnan(x) else float("nan")),
    "expm1": lambda x: (float("nan") if math.isnan(x) else
                        (math.expm1(x) if -745.2 < x < 709.79 else
                         (float("inf") if x > 0 else -1.0))),
    "log1p": lambda x: (float("nan") if (math.isnan(x) or x < -1.0) else
                        (math.log1p(x) if x != -1.0 else float("-inf"))),
    # sinh and cosh overflow LATER than exp, by exactly ln(2), and the bound is
    # 710.47586007394398 -- found by bisection against libm, not reasoned out.
    # The old comment here said they overflow "at the same place exp does,
    # |x| > ln(DBL_MAX)", i.e. at 709.78, and that was WRONG: it wrote inf as
    # the reference for the whole strip from 709.78 to 710.47, so the table
    # CERTIFIED a bug that was really there (a sinh written as
    # (e^x - e^-x)/2 answers inf at 710, where the true answer is
    # 1.1169973830808557e+308 -- the halving buys back one exponent). A
    # reference table is only as good as its reference; this line was the
    # reason the strip was never tested rather than a fact about sinh.
    # Both use a real libm call, which raises OverflowError past the true
    # bound, so the range test has to come first and the answer has to come
    # from the call -- there is nothing to substitute.
    # The bound is INCLUSIVE (>=, not >): 710.47586007394398 is itself the
    # first argument with no answer, so >= is what libm agrees with. Both use a
    # real libm call below it -- Python's math module raises OverflowError past
    # the edge rather than returning inf, so the range test has to come first.
    "sinh": lambda x: (float("nan") if math.isnan(x) else
                       (math.inf if x == math.inf else
                        (-math.inf if x == -math.inf else
                         (float("inf") if abs(x) >= 710.47586007394398
                          else math.sinh(x))))),
    "cosh": lambda x: (float("nan") if math.isnan(x) else
                       (math.inf if math.isinf(x) else
                        (float("inf") if abs(x) >= 710.47586007394398
                         else math.cosh(x)))),
    "tanh": lambda x: (float("nan") if math.isnan(x) else
                       (1.0 if x > 0 else (-1.0 if x < 0 else 0.0))
                       if math.isinf(x) else math.tanh(x)),
    "asin": lambda x: (float("nan") if (math.isnan(x) or abs(x) > 1.0)
                       else math.asin(x)),
    "acos": lambda x: (float("nan") if (math.isnan(x) or abs(x) > 1.0)
                       else math.acos(x)),
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

def _odd_int(y):
    """Is y an odd integer? The sign of a zero, an infinity or a negative base
    all turn on it, and Python's % on a float says what we want."""
    return y == math.floor(y) and math.fmod(y, 2.0) != 0.0


def pow_ref(x, y):
    """C's pow, including the cases Python raises or answers differently.

    Four of them, all of which the table checks:

      pow(x, +-0) is 1 for every x, a NaN included (Python: NaN);
      pow(-1, y) is 1 for every finite y, 0.5 included (Python: raises);
      pow(+-inf, an odd integer) carries the sign (Python: +inf);
      pow(x, y) that overflows is an infinity, not an exception.

    An infinity where Python raises is still the ANSWER there -- an overflow is
    what C returns -- so the exception is caught and mapped by the exponent's
    sign, which is what C's overflow and underflow do.
    """
    if y == 0.0:
        return 1.0
    if math.isnan(x) or math.isnan(y):
        return float("nan")
    if x == 1.0 or x == -1.0:
        return -1.0 if (x == -1.0 and _odd_int(y)) else 1.0
    odd = _odd_int(y)
    if x == 0.0:
        return math.inf if y < 0.0 else (-0.0 if odd else 0.0)
    if math.isinf(x):
        if y < 0.0:
            return 0.0
        if x > 0.0:
            return math.inf
        return -math.inf if odd else math.inf
    try:
        return math.pow(x, y)
    except OverflowError:
        return float("inf") if y > 0 else 0.0
    except ValueError:
        # 0**negative, and the negative-base-with-fractional-exponent NaNs
        return float("inf") if y < 0 else float("nan")


def atan2_ref(y, x):
    """C's atan2: the quadrant, with every zero and infinity spelled out."""
    if math.isnan(y) or math.isnan(x):
        return float("nan")
    pi2 = math.pi / 2
    if math.isinf(x) and math.isinf(y):
        if x > 0:
            return pi2 / 2 if y > 0 else -pi2 / 2
        return (3 * math.pi / 4 if y > 0 else -3 * math.pi / 4)
    if math.isinf(x):
        if y > 0:
            return math.pi if x < 0 else 0.0
        if y < 0:
            return -math.pi if x < 0 else 0.0
        return math.pi if x < 0 else 0.0
    if math.isinf(y):
        return pi2 if y > 0 else -pi2
    if x == 0.0:
        if y > 0:
            return pi2
        if y < 0:
            return -pi2
        return 0.0
    if y == 0.0:
        # the sign of the zero decides: atan2(-0.0, -1.0) is -pi
        if x > 0:
            return 0.0
        return -math.pi if math.copysign(1.0, y) < 0 else math.pi
    return math.atan2(y, x)


REF2 = {
    "hypot": math.hypot,
    "nextafter": math.nextafter,
    "pow": pow_ref,
    "fmin": fmin_ref,
    "fmax": fmax_ref,
    # Python has no atan2 with C's zero cases (math.atan2 raises on (0, 0)),
    # and the table's zero and infinity rows are what make it worth spelling
    "atan2": atan2_ref,
}



def spread(seed, n, lo=-8.0, hi=8.0):
    """n reproducible values in [lo, hi] -- a fixed seed, so the table is the
    same file for everyone who regenerates it. The hand-picked cases above pin
    the edges; these are what find the argument nobody thought of."""
    rng = random.Random(seed)
    out = []
    for _ in range(n):
        v = rng.uniform(lo, hi)
        # and a third of them snapped to the argument a program would really use
        if rng.random() < 0.34:
            v = round(v, rng.randrange(0, 4))
        out.append(v)
    return out


def pair_spread(seed, n=80):
    """n reproducible (base, exponent) pairs, most of them with an exponent
    under 1 -- which is where pow's log is most sensitive, since the error it
    carries is the logarithm's own and the exponent multiplies it."""
    rng = random.Random(seed)
    out = []
    for _ in range(n):
        out.append((rng.uniform(0.01, 40.0), rng.uniform(-6.0, 6.0)))
    return out


EXTRA = {name: spread(1000 + i, 60) for i, name in enumerate(
    ["exp", "expm1", "log", "log1p", "sinh", "cosh", "tanh", "asin", "acos",
     "atan", "sin", "cos", "tan"])}
# cbrt gets its own spread, and it needs far more than the 80 it had. Those 80
# were added because the native fixture found 7.5 a trillion times out and the
# pinned list had missed it -- and 80 was still not enough, because cbrt was 2
# ulps out on 3.5% of ORDINARY arguments and neither the 80 nor the twenty-odd
# pinned values was one of them.
#
# That is this table's lesson stated a third time: a pinned list is not a spread,
# and the arguments BETWEEN the pins are where the defects live. expm1 answered
# inf across the strip between 709.4 and 709.78; sinh answered inf from 709.78 to
# 710.47; cbrt was 2 ulps out at 96.2371129. All three were found by SWEEPING,
# and all three sat between values somebody had already thought to write down.
#
# So cbrt gets 1600: [1, 8] where its kernel runs, the whole negative half, and
# [0.001, 1) where the seed and the exponent split differ.
#
# libm is NOT this table's reference for cbrt. cbrt_ref computes the cube root in
# 60 digits and rounds once (see above), because this platform's libm cbrt is not
# correctly rounded -- up to 3 ulps out on 1385 of 3030 arguments, where this
# module's is correctly rounded on all of them. A libm reference would have
# failed the better answers, which is the second time in this file that the
# reference line rather than the code has been the thing to fix.
EXTRA["cbrt"] = (spread(4242, 80, 1.0, 8.0) + spread(4243, 720, 1.0, 8.0)
                 + spread(4244, 800, -100.0, -0.001))

# asin and acos get a spread over the domain they HAVE, on top of the general
# one (which is what supplies their out-of-domain NaN cases and must stay). A
# uniform value in [-8, 8] lands inside [-1, 1] about one time in eight, so the
# general spread left each of them with EIGHT interior arguments -- and 59 of
# each function's 77 cases were the |x| == 1 edge, which returns pi/2 before the
# half-angle step does any work at all. That is eight cases gating a 24-term
# polynomial: the sweep that chose the degree ran over 20,001 points and said 1
# ulp, and the checked-in gate that has to agree with it said nothing.
#
# Half of [-1, 1] is the branch asin's kernel actually computes (|x| > 1/2 goes
# through it, |x| <= 1/2 through atan), so 240 cases put about 120 of them on
# the kernel and 120 on the branch beside it -- which is the first time both
# sides of that boundary are checked by anything but the pinned list.
EXTRA["asin"] = spread(1007, 60) + spread(1101, 240, -1.0, 1.0)
EXTRA["acos"] = spread(1008, 60) + spread(1102, 240, -1.0, 1.0)

# The eight the table had NO cases for. Every other function the module exports
# was in it, and that gap is not tidiness: fmin and fmax decide a +-0 tie by
# whichever operand comes last, so fmax(0.0, -0.0) answered -0.0 and
# 1.0/fmax(0.0, -0.0) came out -inf -- with a comment in the module saying the
# sign was "not specified", which C99 allows and IEEE 754-2019's maxNum, this
# platform's libm and any caller dividing by the answer do not. Four of the
# eight are exact, so their cases are cheap; two are a convention; one is a
# definition with two exact ends.
EXTRA["fabs"] = spread(1201, 40, -8.0, 8.0)
EXTRA["fsign"] = spread(1202, 40, -8.0, 8.0)
EXTRA["is_nan"] = spread(1203, 40, -8.0, 8.0)
EXTRA["is_inf"] = spread(1204, 40, -8.0, 8.0)
EXTRA["is_finite"] = spread(1205, 40, -8.0, 8.0)
TWO_EXTRA = {
    "fmin": [(a, b) for a in (0.0, -0.0, 1.0, -1.0, float("inf"), float("-inf"),
                              5e-324, -5e-324, 1e308, -1e308)
             for b in (0.0, -0.0, 2.0, -2.0, float("inf"), float("-inf"),
                       -5e-324, 1e-308, 1e308, -1e308)],
    "fmax": [(a, b) for a in (0.0, -0.0, 1.0, -1.0, float("inf"), float("-inf"),
                              5e-324, -5e-324, 1e308, -1e308)
             for b in (0.0, -0.0, 2.0, -2.0, float("inf"), float("-inf"),
                       -5e-324, 1e-308, 1e308, -1e308)],
}
# the ordinary arguments, so the tables are not all edges
TWO_EXTRA["fmin"] = TWO_EXTRA["fmin"] + pair_spread(1301, 60)
TWO_EXTRA["fmax"] = TWO_EXTRA["fmax"] + pair_spread(1302, 60)
THREE = {
    # lerp: the two ends are EXACT, which is the property a caller interpolating
    # a frame depends on, and neither is true of a formula that forgets them
    "lerp": [(a, b, t)
             for (a, b) in [(0.0, 1.0), (1.0, -1.0), (0.0, -0.0), (5.0, 5.0),
                            (-3.0, 7.0), (2.5, -2.5), (1e300, -1e300),
                            (1e-300, 1e-300)]
             for t in (0.0, 1.0, 0.5)]}


def main():
    out = []
    out.append("# test/math/ulp_table.txt -- generated by gen_ulp_table.py; do not")
    out.append("# hand-edit. Each line is: function arg1_bits [arg2_bits] want_bits,")
    out.append("# every double as its IEEE-754 bit pattern in decimal. The reference")
    out.append("# is this platform's libm. A '#' line or a blank one is ignored.")
    for name in sorted(ONE):
        for x in ONE[name] + EXTRA.get(name, []):
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
        cases = TWO[name] + (pair_spread(name) if name == "pow" else [])
        for (x, y) in cases + TWO_EXTRA.get(name, []):
            want = bits(float(REF2[name](x, y)))
            out.append("%s %d %d %d" % (name, bits(x), bits(y), want))
    for name in sorted(THREE):
        for (x, y, t) in THREE[name]:
            want = bits(float(lerp_ref(x, y, t)))
            out.append("%s %d %d %d %d" % (name, bits(x), bits(y), bits(t), want))
    sys.stdout.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
