// W4/S5: the exact NaN rule.  Wasm may return any NaN from an operation, so
// the lowering picks x86's: quiet(dst) if dst was NaN, else quiet(src) if src
// was NaN, else x86's default NaN 0xFFF8000000000000.  math.fbits reads the
// bits back, so this is the rule itself, not "it is some NaN".
import math;

let nan = 0.0 / 0.0;
let inf = 1.0 / 0.0;
// 0xFFF8000000000000, x86's default NaN, as a signed long
let defnan: long = -2251799813685248;
// one quiet NaN with a distinctive payload, and one signalling
let qnan = math.bitsf(0x7FF8000000000001);
let snan = math.bitsf(0x7FF0000000000001);

// 0/0 takes the default NaN
print(math.fbits(nan) == defnan, "\n");
// sqrtsd of a negative takes it too (neither operand was NaN)
print(math.fbits(math.sqrt(-1.0)) == defnan, "\n");
// a signalling operand comes back quiet, with its payload kept
print(math.fbits(snan + 1.0) == 0x7FF8000000000001, "\n");
print(math.fbits(1.0 * snan) == 0x7FF8000000000001, "\n");
// dst's NaN wins over src's
print(math.fbits(qnan + snan) == 0x7FF8000000000001, "\n");
print(math.fbits(snan + qnan) == 0x7FF8000000000001, "\n");
print(math.fbits(qnan + qnan) == 0x7FF8000000000001, "\n");
// ... but only when the result really is NaN
print(math.fbits(inf - inf) == defnan, "\n");
print(math.fbits(0.0 * inf) == defnan, "\n");
print(math.fbits(inf / inf) == defnan, "\n");
// ordering: NaN is unordered in every direction
print(nan < 1.0, " ", nan <= 1.0, " ", nan > 1.0, " ", nan >= 1.0, " ", nan == nan, " ", nan != nan, "\n");
// cvttsd2si: NaN and out of range give INT_MIN; the truncating cast rounds
// toward zero and the range test runs before the trapping trunc
print(math.raw_to_int(nan) == -9223372036854775807 - 1, "\n");
print(math.raw_to_int(inf) == -9223372036854775807 - 1, "\n");
print(math.raw_to_int(-inf) == -9223372036854775807 - 1, "\n");
print(math.raw_to_int(1.0e308) == -9223372036854775807 - 1, "\n");
print(math.raw_to_int(3.99), " ", math.raw_to_int(-3.99), "\n");
print(math.raw_to_int(9223372036854774784.0), "\n");
// cvtsi2sd, and the float back through the truncating cast
let n: long = 42;
let f: float = n;
print(math.raw_to_int(f), " ", math.raw_to_int(-f), "\n");
