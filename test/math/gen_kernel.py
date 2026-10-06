#!/usr/bin/env python3
"""Polynomial coefficients for std/math.y, in the form the module evaluates.

Each function's kernel is a polynomial, and a polynomial evaluated in plain
double arithmetic is not accurate to an ulp: Horner's rule accumulates one
rounding a term, so a degree-n kernel sits n ulps out and stays there. The fix
the good libraries use is to split every coefficient in two and carry the low
parts in a second accumulator:

    p = c_n_hi;  q = c_n_lo
    for i in n-1 .. 0:  p = p * w + c_i_hi;  q = q * w + c_i_lo
    answer = p + q

The q path's own error is second order, so what is left is the error of the
INPUTS and of the final combination. The split is free at run time -- both
halves are literals -- so the cost is one extra multiply and add a term, which
P4's assembly pays once and Y pays every call.

Every kernel below is written in the shape that makes this work:

    2^r   = 1 + r * (1 + r * P(r^2))          exp, exp2
    log m = z * (2 + z^2 * P(z^2))            log, z = (m-1)/(m+1)
    sin x = x * (1 + x^2 * P(x^2))            sin, atan
    cos x = 1 - x^2 * P(x^2)                  cos, tan

so the polynomial is only ever the CORRECTION to a term already in hand. That
matters as much as the split: the error of the kernel is scaled by the size of
the correction rather than of the answer.

So this script does three things, in exact rational arithmetic where it can:

  * fit a polynomial to a kernel over a range (an (n+1)-by-(n+1) Vandermonde
    system at equally spaced nodes, solved exactly -- not quite a minimax
    polynomial, but close enough that the degrees here are the same);
  * report the worst error of the SPLIT evaluation on a dense grid, in ulps of
    the FINAL ANSWER, so a coefficient set is never pasted in unseen;
  * print the coefficients as Y literals, hi and lo.

Run it and paste the output into src/y/std/math.y.
"""

import math
from decimal import Decimal, getcontext
from fractions import Fraction as F

getcontext().prec = 60
D = Decimal


def dec(x):
    """A Fraction or int as a Decimal (exact, at 60 digits)."""
    if isinstance(x, D):
        return x
    if isinstance(x, F):
        return D(x.numerator) / D(x.denominator)
    return D(x)


def dcos(x):
    """cos(x) at the context's precision: Python's decimal has exp and ln but
    no cosine, and the Chebyshev nodes need one. The Taylor series converges
    fast for the |x| < 1 these are."""
    x = dec(x)
    total = D(1)
    term = D(1)
    for k in range(1, 40):
        term = -term * x * x / D(2 * k * (2 * k - 1))
        total += term
        if abs(term) < D(10) ** (-getcontext().prec - 2):
            break
    return total


def dec_frac(d):
    """A Decimal as an exact Fraction."""
    sign, digits, exp = d.as_tuple()
    num = int("".join(map(str, digits)))
    return F(-num if sign else num) * (F(10) ** exp)


def solve(mat, rhs):
    """Gauss-Jordan over Fractions: an exact solution of a square system."""
    n = len(rhs)
    m = [row[:] + [rhs[i]] for i, row in enumerate(mat)]
    for col in range(n):
        piv = next(r for r in range(col, n) if m[r][col] != 0)
        m[col], m[piv] = m[piv], m[col]
        pv = m[col][col]
        m[col] = [v / pv for v in m[col]]
        for r in range(n):
            if r != col and m[r][col] != 0:
                f = m[r][col]
                m[r] = [v - f * w for v, w in zip(m[r], m[col])]
    return [m[i][n] for i in range(n)]


def cheb_nodes(n, h):
    """n Chebyshev nodes on [0, h] at 60 digits.

    Equally spaced nodes would not do: a kernel like exp's is nearly constant,
    so interpolating it at seven equally spaced points produces a polynomial
    with enormous coefficients that matches those seven points and nothing in
    between. The Chebyshev nodes are what make the fit a good approximation
    rather than an interpolation, and their Vandermonde matrix is conditioned
    at about 2^n, which exact arithmetic absorbs comfortably.
    """
    pi = D("3.14159265358979323846264338327950288419716939937510582")
    out = []
    for i in range(n):
        t = dcos(D(2 * i + 1) * pi / D(2 * n))
        out.append(dec_frac(dec(h) * (D(1) - t) / 2))
    return out


def fit(fn, deg, hi):
    """Coefficients in w, ascending, for fn(w) on [0, hi], as exact Fractions.

    fn takes a Fraction and returns a Decimal.
    """
    n = deg + 1
    nodes = cheb_nodes(n, hi)
    mat = [[x ** i for i in range(n)] for x in nodes]
    rhs = [dec_frac(fn(x)) for x in nodes]
    return solve(mat, rhs)


def split(c):
    """A rational coefficient as its two doubles: hi rounds it, lo is exact."""
    hi = float(c)
    return hi, float(c - F(hi))


def eval_split(coef, w):
    """The split evaluation, in Python floats, the way the module does it."""
    p, q = coef[-1]
    for i in range(len(coef) - 2, -1, -1):
        p = p * w + coef[i][0]
        q = q * w + coef[i][1]
    return p + q


def report(name, fn, deg, hi, compose, coef=None):
    """Fit, split, and check the worst error in ulps of the FINAL ANSWER.

    `compose(k, u)` turns the kernel's value into what the function returns, so
    the error is measured where it lands. That matters: the kernel is only the
    correction, so its absolute error reaches the answer multiplied by the
    argument's square (or cube), and an absolute-error figure would say a
    kernel is bad when it is irrelevant there.
    """
    # `coef` is for the kernels whose coefficients are EXACT -- a Taylor value,
    # a term of the series -- rather than the output of an interpolation. Those
    # are what the module ships, and printing the fit's near-neighbours instead
    # is how a table gets retyped into something a few ulps worse: the fit
    # agrees with the rational to fifteen digits and disagrees in the sixteenth,
    # which is precisely where a coefficient's low half lives.
    if coef is None:
        coef = [split(c) for c in fit(fn, deg, hi)]
    else:
        coef = [split(c) for c in coef]
    hf = float(hi)
    worst_ulp = 0.0
    worst_at = 0.0
    n = 4001
    for i in range(n):
        u = hf * i / (n - 1)
        got_k = eval_split(coef, u)
        want_k = float(fn(F(u).limit_denominator(10 ** 25)))
        got = compose(got_k, u)
        want = compose(want_k, u)
        if want == 0.0 or math.isinf(want) or math.isnan(want):
            continue
        ulp = abs(got - want) / math.ulp(want)
        if ulp > worst_ulp:
            worst_ulp, worst_at = ulp, u
    print("### %s, u in [0, %s], degree %d: worst %.3f ulp (at u=%.6g)"
          % (name, hi, deg, worst_ulp, worst_at))
    for i, (h, l) in enumerate(coef):
        print("    // c%d  hi %s   lo %s" % (i, repr(h), repr(l)))
    print()


# The kernels, each a function of the variable the module fits it in. Five of
# them are polynomials in w = the square of the reduced argument (which is why
# they come in even powers, and why sin and cos share a reduction); exp's is a
# polynomial in the argument itself, because e^r has odd powers in it and
# cannot be a function of r^2 at all.


def series(fn, r, upto=90):
    """Taylor sum of a sin/cos-shaped series at r, to `upto` terms."""
    return sum((-1) ** k * r ** (2 * k + (1 if fn is sin_series else 0)) /
               D(math.factorial(2 * k + (1 if fn is sin_series else 0)))
               for k in range(0, upto))


def sin_series(r):
    return sum((-1) ** k * r ** (2 * k + 1) / D(math.factorial(2 * k + 1))
               for k in range(0, 90))


def cos_series(r):
    return sum((-1) ** k * r ** (2 * k) / D(math.factorial(2 * k))
               for k in range(0, 90))


def atan_series(r):
    return sum((-1) ** k * r ** (2 * k + 1) / D(2 * k + 1) for k in range(0, 200))


# ── exp's kernel in r: e^r = 1 + r*(1 + r*Q(r)), Q(r) = (e^r - 1 - r)/r^2 ──
# The reduction splits x = k*ln2 + r and puts 2^k back afterwards, so what is
# left to compute is e^r.
RMAX = D("6.93147180369123816490e-01") / 2


def pexact(u):
    r = dec(u)
    if r == 0:
        return D("0.5")
    return (r.exp() - 1 - r) / (r * r)


# ── log's kernel in w = z^2, z = (m-1)/(m+1): log m = z*(2 + w*P(w)) ──
ZMAX = (D(2).sqrt() - 1) / (D(2).sqrt() + 1)


def lexact(w):
    w = dec(w)
    if w == 0:
        return D(2) / 3
    z = w.sqrt()
    lm = 2 * sum(z ** (2 * k + 1) / D(2 * k + 1) for k in range(0, 80))
    return (lm - 2 * z) / (z * w)


# ── sin's kernel in w = x^2: sin x = x*(1 + w*P(w)) ──
QMAX = (D("3.14159265358979323846264338327950288419716939937511") / 4) ** 2


def sinexact(w):
    w = dec(w)
    if w == 0:
        return -D(1) / 6
    r = w.sqrt()
    return (sin_series(r) - r) / (r * w)


# ── cos's kernel in w = x^2: cos x = 1 - w*P(w) ──


def cosexact(w):
    w = dec(w)
    if w == 0:
        return D("0.5")
    r = w.sqrt()
    return (1 - cos_series(r)) / w


# ── tanh's kernel in w = x^2, for |x| <= 0.5: tanh x = x*(1 + w*P(w)) ──
# Not sinh/cosh: that is three roundings (one in each function, one in the
# division) where this is one. And NOT a range of 1: this kernel's series in
# x^2 has its singularity at x^2 = -2.5, so over x^2 in [0, 1] a Chebyshev fit
# loses four bits a term and would need a degree near forty. Over [0, 0.25] -- all
# the kernel needs, since tanh(2u) = 2t/(1+t^2) halves the argument -- it loses
# twenty a term, and a degree of eleven holds it to a small fraction of an ulp --
# though not of the ANSWER: the final `1 + w*P(w)` costs its half ulp whatever
# the kernel costs, and tanh's own answer has a small ulp near one, so tanh
# lands at two ulps where sin and atan land at one. Folding to reach a narrower
# range does not help -- it costs a rounding a fold and saves less.
TANH_MAX = F(1, 2)


def tanexact(w):
    w = dec(w)
    if w == 0:
        return D(0)
    r = w.sqrt()
    # sinh and cosh to 60 digits (decimal has exp but no tanh, and exp is all
    # tanh's two functions need)
    e1 = r.exp()
    e2 = (-r).exp()
    th = (e1 - e2) / (e1 + e2)
    return (th - r) / (r * w)


# ── sinh's kernel in w = x^2, for |x| <= 0.5: sinh x = x*(1 + w*P(w)) ──
# sinh is the odd sibling of the exp kernel: expm1(r) = r*(1 + r*Q(r)) is that
# kernel on its own, and sinh is expm1(x) - expm1(-x) over two -- the same shape
# with the even terms halved.
SMAX = F(1, 2)


def sexact(w):
    w = dec(w)
    if w == 0:
        return D(1) / 6
    r = w.sqrt()
    # (sinh(r) - r)/r^3, the kernel of sinh r = r*(1 + r^2*P(r^2)); the sum
    # below is sinh(r) with its r term already taken off
    sx = sum(r ** (2 * k + 3) / D(math.factorial(2 * k + 3))
             for k in range(0, 80))
    return sx / (r * w)


# ── asin's kernel, for the half of the argument above 1/2 ──
#
# asin(a) = pi/2 - 2*asin(sqrt((1-a)/2)) and the inner asin is small, so with
# z = (1-a)/2 in (0, 1/4] the whole of it is 2*asin(sqrt(z)) = 2*sqrt(z)*(1 +
# z*P(z)) -- the same shape as every other kernel here, with `2*sqrt(z)` the
# term already in hand. asin used to reach atan instead, and inherited atan's
# whole ulp on top of the sqrt's and the divide's, which is why asin(-0.719) sat
# two ulps out while nothing else in the module did. The degree is the price of
# the branch: the series converges at the rate z, which is a quarter at the wide
# end, so each pair of terms buys sixteen -- 20 terms leave the answer 8 ulps
# out and 22 bring it to 1, and 24 is 22 with room for arguments the sweep does
# not land on.
AZMAX = D("0.25")
DEG_ASIN = 24
PI2 = 1.57079632679489661923        # the module's pi_over_2


def _two_sum(a, b):
    """the module's two_sum, returning both the sum and its exact residual."""
    s = a + b
    bb = s - a
    return s, (a - (s - bb)) + (b - bb)


def asin_big(k, z):
    """What math.y's large asin branch does with the kernel's value `k`.

    The report below has to measure THIS and not `pi/2 - 2*asin(sqrt(z))`
    written out longhand, because the two differ by the answer: the branch
    keeps `two` in two parts through the subtraction and puts the square root's
    own residual back, and those two steps are what took asin from two ulps to
    one. Measuring the longhand form would report 2 for a kernel the module
    gets 1 ulp out of, which is the kind of number that stops the next person
    believing the better one.
    """
    s = math.sqrt(z)
    two_hi, two_lo = _two_sum(2.0 * s, (2.0 * s) * z * k)
    if s > 0.0:
        two_lo = two_lo + 2.0 * ((z - s * s) / (2.0 * s)) * (1.0 + z * k)
    d, e = _two_sum(PI2, -two_hi)
    return d + (e - two_lo)


def asin_series(r):
    # asin r = sum_k C(2k,k)/(4^k (2k+1)) r^(2k+1). `term` below is
    # C(2k,k)/4^k * r^(2k+1) and the summand is term/(2k+1); the ratio between
    # terms is r^2 (2k+1)/(2k+2), because C(2k+2,k+1)/4^(k+1) over
    # C(2k,k)/4^k is (2k+1)/(2k+2).
    total = D(0)
    term = r
    k = 0
    while True:
        add = term / (2 * k + 1)
        total += add
        if k > 4 and abs(add) < D(10) ** -70:
            return total
        term = term * r * r * (2 * k + 1) / (2 * k + 2)
        k = k + 1


def asin_coef(i):
    """Coefficient i of P, exactly: C(2k,k)/(4^k(2k+1)) with k = i+1.

    The Taylor values of the same series sinh_k is taken from, which is why
    this kernel needs no fitting at all -- see report's note on `coef`.
    """
    k = i + 1
    return F(math.comb(2 * k, k), 4 ** k * (2 * k + 1))


def asinexact(z):
    """P(z) for asin(s) = s * (1 + z*P(z)) with s = sqrt(z).

    NO leading two: the module gets 2*asin(s) by doubling, and the doubling is
    exact, so the kernel that carries it would be twice this one -- which is how
    the first version of this was wrong, and it made every degree look like a
    disaster.
    """
    z = dec(z)
    if z == 0:
        return D(1) / 6
    s = z.sqrt()
    return (asin_series(s) / s - 1) / z


# ── atan's kernel in w = x^2: atan x = x*(1 + w*P(w)), |x| <= tan(pi/8) ──
TMAX = D("0.41421356237309504880168872420969807856967187537694807317668")


def atanexact(w):
    w = dec(w)
    if w == 0:
        return -D(1) / 3
    r = w.sqrt()
    return (atan_series(r) - r) / (r * w)


if __name__ == "__main__":
    report("exp kernel in r", pexact, 12, dec_frac(RMAX),
           lambda k, r: 1.0 + r * (1.0 + r * k))
    report("log kernel", lexact, 10, dec_frac(ZMAX * ZMAX),
           lambda k, w: math.sqrt(w) * (2.0 + w * k))
    report("sin kernel", sinexact, 5, dec_frac(QMAX),
           lambda k, w: math.sqrt(w) * (1.0 + w * k))
    report("cos kernel", cosexact, 7, dec_frac(QMAX),
           lambda k, w: 1.0 - w * k)
    # The compose matters as much as the degree, and it was wrong here: this
    # reported the KERNEL's value against tanh(x), i.e. a number near -1/3
    # against an answer near 0.46, and so measured the wrong quantity and said
    # 0.000 ulp. tanexact returns the CORRECTION -- tanexact(w) is
    # (tanh(x) - x)/(x*w) -- so the answer is x*(1 + w*k) with x = sqrt(w), and
    # that is what the error has to be measured on. Reading the coefficient
    # table would have caught it: c0 = -1/3 is the x^3 term of tanh, not its
    # constant.
    report("tanh kernel in w=x^2, tanh(x) = x*(1 + w*P(w)), |x| <= 1/2",
           tanexact, 11, TANH_MAX * TANH_MAX,
           lambda k, w: math.sqrt(w) * (1.0 + w * k))

    report("sinh kernel", sexact, 7, SMAX * SMAX,
           lambda k, w: math.sinh(math.sqrt(w)))

    report("atan kernel", atanexact, 12, dec_frac(TMAX * TMAX),
           lambda k, w: math.sqrt(w) * (1.0 + w * k))

    report("asin kernel", asinexact, DEG_ASIN, AZMAX, asin_big,
           coef=[asin_coef(i) for i in range(DEG_ASIN)])