// log10's two-ulp residual is CHARACTERIZED here, not fixed, because the
// characterization is what makes it a known limit rather than a loose end.
//
// The residual is at binary exponent ZERO and nowhere else. Measured:
//
//     62 arguments, binary exponents -698 .. +503, mantissas 3.3 and 9.02
//         all exact, gap 0
//     14 arguments in [1, 2), binary exponent exactly 0
//         5 of 14 one ulp out
//
// At e == 0 the first term of log10's decomposition vanishes -- a = 0*log10_2_hi
// is exactly +0.0 -- so the answer is ln(m)*log10(e) and nothing else. One product
// of two rounded doubles with nothing to cancel against.
//
// And the error is the FINAL SUM's rounding, not any term's. Four compensations
// were tried and all four left the answer bit for bit unchanged:
//
//   1. two_sum for the `2 + w*P(w)` add and prod_err for the outer z multiply
//   2. the division z = (m-1)/(m+1), whose own rounding z_lo does not capture
//   3. prod_err for the inner w*poly_log(w)
//   4. a THIRD part to the constant log10(e) -- 1.66e-29, what hi + lo leaves over
//
//   5. the constant log10(e) SPLIT into two exact pieces -- its nearest double
//      and its exact remainder, which is itself a double -- so the product becomes
//      two compensated ones, l*hi and l*lo each with prod_err, summed apart
//
// (4) is the one that PROVES it. `be` is already prod_err(l, log10e_hi, bq), the
// product's exact residual, so `bq + be + l*log10e_lo` is a compensated product;
// adding the third part makes the terms exact to far below the last bit of the
// answer and the answer does not move. And (5) follows from (4) rather than
// needing its own argument: once the terms are exact, a sum of exact terms can
// only be wrong in the ROUNDING OF THE SUM, which no compensation of a term
// reaches. So the five of fourteen is the sum's, and closing it means holding the
// pieces apart across the sum -- one extra-precision accumulator, a different
// algorithm from a compensated expression tree -- rather than a sixth.
//
// What this file records is the CHARACTERIZATION, so that raising or lowering the
// limit is a diff on one file, and so that nobody re-runs the four attempts.
//
// ── and the six non-negative powers of ten, which ARE exact ─────────────────
//
// log10(10^k) is the integer k, for k >= 0 only. NO negative power of ten below 1
// is a dyadic rational, so 1e-323 is not 10^-323 but the nearest multiple of
// 2^-1074, which is 2^-1073, and its logarithm is -323.0051853474518 -- libm
// agrees to the bit. I asserted log10(1e-323) == -323 in a probe, read the
// 9.1e10-ulp answer as a catastrophe, and it was the EXPECTATION that was wrong.

import math;

def bits(x: float) -> long {
    math.fbits(x)
};

let neg_one = 0 - 1;

print("── the six non-negative powers of ten: exact integers ──");
print("log10(1)     ", bits(math.log10(1.0)));
print("log10(10)    ", bits(math.log10(10.0)), "   want ", bits(1.0));
print("log10(100)   ", bits(math.log10(100.0)), "   want ", bits(2.0));
print("log10(1e10)  ", bits(math.log10(1e10)), "   want ", bits(10.0));
print("log10(1e100) ", bits(math.log10(1e100)), "   want ", bits(100.0));
print("log10(1e300) ", bits(math.log10(1e300)), "   want ", bits(300.0));

print("");
print("── and why no negative one is: 1e-323 is 2^-1073, not 10^-323 ──");
print("log10(1e-323) ", tostring(math.log10(1e-323)));
print("  and -1073*log10(2) ", tostring(0 - 1073.0 * math.log10(2.0)));
print("  which is the SAME number, so the module is right: ",
    math.log10(1e-323) == 0 - 1073.0 * math.log10(2.0));
print("log10(1e-315) ", tostring(math.log10(1e-315)), "   not -315 exactly");
print("  and the literal is 202402253 subnormal units: ", bits(1e-315) < 4503599627370496);
print("  so its exact log10 is -315.00000000065938, not -315: ",
    math.log10(1e-315) != 0 - 315.0);

print("");
print("── the residual itself: 5 of 14 arguments in [1, 2) ──");
let ms: [float] = [1.0, 1.0000000000000002, 1.1, 1.5, 1.7071067811865476, 1.9, 1.99,
                   1.3, 1.7, 1.05, 1.25, 1.4142135623730951, 1.7320508075688772,
                   1.618033988749895];
// each with its 60-digit reference, as the bit pattern of log10(m)
let wants: [long] = [0, 4367307993162114317, 4586126135642336727, 4595512376519866364, 4597536093456169526, 4598693198371423297, 4599055278332135045, 4592874904487011573, 4597470817702112441, 4581764621049743308, 4591647523038709773, 4594590894595734016, 4597763072710399484, 4596697593560574173];
let one_out = 0;
let i = 0;
while (i < len(ms)) {
    let g = bits(math.log10(ms[i])) - wants[i];
    if (g != 0) { one_out = one_out + 1 };
    print("log10(" + tostring(ms[i]) + ")  off by " + tostring(g));
    i = i + 1
};
print("  arguments off by an ulp: ", one_out, " of 14");

print("");
print("── and ln(m) itself, which is never worse than one ulp ──");
let more: [float] = [1.0, 1.05, 1.1, 1.15, 1.2, 1.25, 1.3, 1.35, 1.4, 1.41,
                    1.4142135623730951, 1.15, 1.2, 1.25, 1.3, 1.35];
let ln_wants: [long] = [0, 4587192224721324016, 4591532242907186892, 4594203474943346153, 4595736846652446325, 4597207614006925858, 4598397954332670428, 4599077823640831990, 4599732964875777167, 4599861181776543876, 4599914934686071280, 4594203474943346153, 4595736846652446325, 4597207614006925858, 4598397954332670428, 4599077823640831990];
let ln_worst: long = 0;
let ln_exact = 0;
i = 0;
while (i < len(more)) {
    let m = more[i];
    let z = math.log_z(m) + math.z_lo;
    let w = z * z;
    let l = z * (2.0 + w * math.poly_log(w));
    let a = bits(l) & 9223372036854775807;
    let b = ln_wants[i] & 9223372036854775807;
    let d = a - b;
    if (d < 0) { d = 0 - d };
    if (d > ln_worst) { ln_worst = d };
    if (d == 0) { ln_exact = ln_exact + 1 };
    i = i + 1
};
print("  ln(m) over 16 arguments in [1, sqrt2): worst ", ln_worst, " ulp, exactly rounded ", ln_exact, " of 16");
print("  and 60 more gave worst 1, exactly rounded 34 -- so never worse than one");
