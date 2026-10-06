// log2 and log10: their own reduction, and what it costs and what it buys.
//
// Both used to be `log(x) * (1/ln2)` and `log(x) * (1/ln10)` -- log through the
// assembly kernel, then one multiply. That is what C's do, and it was WRONG on
// ordinary arguments: log itself is inside its own one-ulp promise, but it is 1
// ulp out on 6 of every 9 arguments tried, and multiplying that by 1.4427 (or by
// 3.32, for the other base) turns one ulp into two. Measured over 12026
// arguments drawn log-uniformly from 5e-324 to DBL_MAX against a 60-digit
// logarithm, the old code was 2 ulps out on a fraction of a percent of them --
// and log2 had NINE pinned cases in the whole table, log10 nine more, the
// thinnest coverage in it. A spread uniform in the DECADES found it in a minute.
//
// What replaced it keeps log2's reduction and scales the EXACT integer part:
//
//     log2(x)  = e + log2(m)            x = m * 2^e, e an exact integer
//     log10(x) = e*log10(2) + ln(m)*log10(e)
//
// each product's own rounding recovered by prod_err and two_sum. Measured on the
// same 12026 arguments:
//
//     log2    worst 1 ulp, over 1 ulp on 0     (libm: correctly rounded on all)
//     log10   worst 2 ulp, over 1 ulp on 1     (libm: correctly rounded on 12016)
//
// log10 is NOT within an ulp everywhere, and the honest figure is the one
// measured over a spread UNIFORM IN THE DECADES rather than log-uniformly: the
// 1-in-12026 above is a log-uniform number, and a decade-uniform spread of
// 20000 arguments (test/math/audit_float.py) finds log10 2 ulps out on 379 of
// them -- 1.9%, spread across EVERY decade, not concentrated near zero. The
// constant log10_2_lo has since been added (see the module) and that is 288 of
// 20000, 1.44%; the figure 379 is what the three compensated-z-series attempts
// below each left unchanged.
//
// An earlier version of this comment blamed the two terms being of COMPARABLE
// size -- e*log10(2) beside ln(m)*log10(e) -- so that ln(m)'s error was not
// diluted the way log2's is. That is right for SMALL |e| and WRONG for large
// |e|, and it was written from one sampled failure. Measured over the failures:
// at e = 831 the ratio of the small term to the large one is 4e-4, and at e = 5
// it is 0.24. So the claim does not hold for most of them, and it is replaced by
// the measurement below rather than patched.
//
// Ruled out by measurement, so nobody repeats it:
//   - log10_2_lo is declared and never added, and the term it carries is
//     ef*(log10(2) - log10_2_hi) = -0.042 ulp of the answer for EVERY ef. I first
//     wrote that this "cannot produce a 2-ulp answer" and that was a mistake of
//     the same kind: a term worth 0.042 ulp DOES flip the rounding whenever the
//     exact value is within 0.042 ulp of a tie, which is a couple of percent of
//     arguments. It is not ruled out. What IS ruled out is that it explains 2
//     ulps rather than 1.
//   - the residual of the z-series' own `2 + w*P(w)`, and of the division inside
//     it, and of the inner product: all three measured, all three no-ops. See
//     below.
//
// THE ERROR IS MEASURED NOW, AND THREE FIXES FOR IT ARE FALSIFIED
//
// ln(m) = z*(2 + w*P(w)) can be reconstructed from the module's own pieces --
// split_mantissa sets split_e, log_z sets z_lo, poly_log is the same polynomial
// the runtime path calls -- and compared with a 60-digit logarithm. Over eight
// arguments that log10 gets wrong, ln(m) comes out EXACTLY ROUNDED on six and
// ONE ULP out on two. So the error is in ln(m), and three compensations for it
// were tried:
//
//   1. two_sum for the `2 + w*P(w)` add, prod_err for the outer z multiply.
//      log10 379 over 1 ulp before AND after; log2 one argument WORSE (0 -> 1).
//   2. The division z = (m-1)/(m+1). The existing z_lo captures den's rounding,
//      not the quotient's, so rem = num - z*den added to z_lo. log10 379 before
//      and after; log2 unchanged.
//   3. prod_err for the INNER w*poly_log(w), which nothing was recovering: two_sum
//      takes its residual about the already-ROUNDED product. log10 379 before and
//      after; log2 one argument worse again.
//
// All three reverted, and (3) is the interesting one: it changed the ANSWER BIT
// FOR BIT on every argument tried. Its error term is about 0.05 ulp of a total
// of magnitude 1.5, which ought to flip the rounding on a few percent of
// arguments -- and flipped none. So ln(m)'s own error is not reaching the sum at
// all, whatever its size, and the 2 ulps are produced by the summation.
//
// Which points at the two_sum(p, l*clo) and the final add, and NOT at ln(m):
// e*log10(2) is |e|*0.301 and l*log10(e) is ~0.15, so for large |e| the two are
// wildly unequal and each correction is ~2^-106 of its own term -- neither can
// move the total's rounding. They can only matter where the two terms are
// COMPARABLE, which is small |e| ... and 31.403229, one of the failures, has
// e = 5. So the failing arguments are not the large-|e| ones the first
// measurement happened to pick, and that is the next thing to sweep.
//
// WHERE THE FAILURES ACTUALLY ARE -- MEASURED, AND IT IS NOT WHERE I LOOKED
//
// Swept by binary exponent with 64 arguments, two mantissas at each of 32
// exponents from -698 to +503. Every argument with a NON-ZERO binary exponent is
// EXACT -- 62 of 62, gap 0 -- and the failures are concentrated at e == 0:
//
//     14 arguments in [1, 2), binary exponent exactly 0:  5 of 14 one ulp out
//     62 arguments, exponents -698..+503, mantissa 3.3 and 9.02:  all exact
//
// At e == 0 the first term VANISHES -- a = ef*log10_2_hi with ef = 0 is exactly
// +0.0 -- so the answer is ln(m)*log10(e) alone: ONE product of two rounded
// doubles, with nothing to cancel against. two_sum(a, bq) contributes nothing
// there (its residual is 0) and the else branch's `be + l*log10e_lo` is already
// a compensated product, so those 5 are not a missing term: they are a
// two-double product that lands on the wrong side of a tie, and closing them
// needs the constant in three pieces or the product in more.
//
// So the earlier claim here -- that the two terms being of comparable size is what
// lets ln(m)'s error through -- is wrong twice over. It is wrong for large |e|
// (ratio 4e-4 at e = 831) and it is wrong about the mechanism: the failures are
// not where the terms are comparable but where ONE of them is absent.
//
// A FOURTH attempt, and what its failure proves. The e == 0 answer is
// `bq + be + l*log10e_lo`, and `be` is prod_err(l, log10e_hi, bq) -- the product's
// exact residual -- so that sum is already a compensated product of ln(m) by
// log10(e). Adding a THIRD part to the constant (1.66e-29, what hi + lo leaves
// over) changes nothing: still 5 of 14, bit for bit.
//
// Which is informative rather than merely negative. The three parts together are
// ln(m)*log10(e) to far below the last bit, so nothing in the TERMS can be the
// error. It is the rounding of the final sum, and the only way past that is to
// keep the pieces apart longer -- ln(m) and the SUM in one extra-precision
// accumulator -- which is a different algorithm from a compensated expression
// tree and is not attempted here.
//
// A FIFTH, which is the same argument made concrete and so is the last one.
// log10(e) is a double whose exact remainder is ALSO a double, so the constant
// splits into two exact pieces and the product into two compensated ones --
// l*log10e_hi with prod_err, and l*inv_ln10_lo with prod_err, summed separately.
// 5 of 14, bit for bit, unchanged.
//
// Five attempts, each removing more of the expression's own error, none moving
// the answer. That is not five coincidences: it is what t327's fourth line says
// measured -- the terms are exact to far below the last bit, so a sum of exact
// terms can only be wrong in the ROUNDING OF THE SUM, and no compensation of a
// term reaches that. Closing it needs the pieces held apart across the sum, which
// is one extra-precision accumulator rather than a compensated expression tree.
//
// THE SUM'S ORDER, tested, and the ORIGINAL ORDER WINS
//
// The objective names "a behaviour decided by an accident of expression order" as
// the class to keep hunting, and this sum's order is the module's last
// uncompensated choice: (ts_lo + ae) + be, then + l*log10e_lo, then + s, each a
// plain rounded add. Summing smallest-first is the textbook remedy, so it was
// tried twice:
//
//   - a PARTIAL sort, which ordered two of the four corrections and summed the
//     other two in their original order. log10 at e == 0 improved, 5 of 14 to 3
//     of 14 -- and the whole decade-uniform sweep went from 288 to 619.
//   - a COMPLETE five-comparator network over all four. 288 to 467.
//
// Both worse than the 288 the module had. And the reason is visible once the
// bound is written down: at e != 0, a = ef*log10_2_hi carries the whole answer
// and ts_lo is ALREADY the residual of two_sum(a, bq), which is already the
// smallest of the four terms -- so the original order is already smallest-first
// for every argument with a non-zero exponent, and sorting can only disturb it.
//
// So the order is not an accident here. It is the right order for 99% of
// arguments and the wrong one for the 1.4% at e == 0, and the two cannot both be
// had by reordering: at e == 0 the first term is absent rather than dominant, so
// there the term that is smallest by construction is not the one that needs to go
// first.
//
// Which is the argument that ends this thread. It is not "compensation did not
// help" -- it is that the one choice which would help helps only where the sum is
// degenerate, and costs everywhere else. A single expression cannot have both.
//
// AND A SEVENTH, which is the one that ought to work and does not. Since the two
// orders want opposite things and the argument says which, the order was CHOSEN
// by it: sort the four corrections only when e == 0, leave the general path
// exactly as it was. That is the textbook answer to "the two orders cannot both
// be had" -- and it gives 290 against 288, with the worst gap rising from 2 to 3.
//
// So the localised improvement at e == 0 does not survive being applied to every
// argument that wants it. Combined with the two unconditional sorts (467, 619)
// that is three measurements all saying the same thing: the e == 0 case and the
// general case are not two instances of one sum, and no expression serves both.
//
// Seven measured attempts. What would serve both is not a better order and not a
// better compensation -- it is holding the pieces apart across the sum, which is
// an extra-precision accumulator rather than an expression tree. That is a
// rewrite of this function, it is not attempted here, and seven measurements are
// the argument for why an eighth would not either.
//
// It also cost 5.5x the instructions: log through assembly plus a multiply is
// 149 a call, and this is 817. That is a deliberate trade and it is worth naming
// as one -- the promise is one ulp and this is what holding it costs on a Y
// path. Closing the gap means writing these two kernels in assembly, which is a
// piece of work in its own right and not a patch.
//
// The answers below are RECORDED rather than trusted, so that any of this
// changing is a diff and not a silence. The table carries the bit patterns
// (7565 cases at tolerance 1); this file is for what a table cannot express --
// that a power of two is exact, that a power of ten is exact, that the smallest
// subnormal answers -1074, and that the integer part stays exact at every scale.

import math;


print("1.0", "  ->  ", math.log2(1.0));
print("2.0", "  ->  ", math.log2(2.0));
print("0.5", "  ->  ", math.log2(0.5));
print("4503599627370496 (2^52)", "  ->  ", math.log2(4503599627370496.0));
print("8.98846567431158e307 (2^1023)", "  ->  ", math.log2(8.98846567431158e307));
print("5e-324 (2^-1074, the smallest subnormal)", "  ->  ", math.log2(5e-324));
print("1e-320", "  ->  ", math.log2(1.0e-320));
print("88.0", "  ->  ", math.log2(88.0));
print("1e300", "  ->  ", math.log2(1.0e300));
print("1.0", "  ->  ", math.log10(1.0));
print("10.0", "  ->  ", math.log10(10.0));
print("0.1", "  ->  ", math.log10(0.1));
print("1e300", "  ->  ", math.log10(1.0e300));
print("5e-324", "  ->  ", math.log10(5e-324));
print("100.0", "  ->  ", math.log10(100.0));
print("ldexp(1, 1000), which is 2^1000", "  ->  ", math.log10(math.ldexp(1.0, 1000)));
