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
// log10's single exception is x = 0.76939152581348347, where ln(m) is itself
// half an ulp out and the scaling cannot move it back; closing that needs the
// z-series compensated too, six more instructions on a path already at 817
// against the assembly kernel's 149.
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
