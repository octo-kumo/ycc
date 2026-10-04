// A float literal's value used to be built by the GENERATED code: the dotless
// digits as a long, then multiplied or divided by a power of ten in chunks of
// 18 so that each factor would be exact. Four things were wrong with that.
//
//   C2  more than 15 significant digits: 9007199254740991.0 is 2^53 - 1, exactly
//       representable, and it came out one to two ulp off -- the digits were
//       already rounded before the scaling began.
//   C3  a mantissa of 19 digits or more wrapped the long it was built in, and
//       2^64 itself wrapped to zero.
//   C4  an exponent past 2^63 wrapped the same way.
//   M2  a net power of ten past 18 was applied as two or more factors, so it
//       was rounded twice: 1e23 came out one ulp off.
//
// The compiler now decides each literal's IEEE-754 bits itself, with one
// rounding to nearest even, and emits them as a constant. This is the gate for
// that, in three parts, all against Python's float() as the oracle:
//
//   1. values big enough that %f resolves one ulp -- printed, and each one
//      checked to print differently from BOTH neighbouring doubles, so an error
//      of one ulp in either direction fails;
//   2. values too small for %f to resolve -- compared through an arithmetic
//      identity that holds only when every operand is correctly rounded;
//   3. the specials: signed zero, inf, and the values past the range, where
//      the text is the point.
//
// The expected file is generated, not hand-copied.

// 1. printed values: %f resolves a single ulp from here up

print(4503599627370496.0, " ", 9007199254740991.0, " ", 9007199254740993.0);
print(4503599627370497.0, " ", 4503599627370496.5, " ", 18446744073709551616.0);
print(99999999999999999999.0, " ", 12345678901234567890.0, " ", 12345678901234567168.0);
print(123456789012345678901.0, " ", 123456789012345678901234567890.0, " ", 123456789012345677877719597056.0);
print(123456789012345683968.0, " ", 1e22, " ", 1e23);
print(1.1e22, " ", 9.999999999999999e22, " ", 1.2345678901234567890123456789e+15);
print(1.7976931348623157e308, " ", 1.7976931348623159e308, " ", 1.2345678901234568e+308);
print(9007199254740991.0e10);

// 2. identities: true only when every literal is correctly rounded

print(0.1 + 0.2 == 0.30000000000000004);
print(0.1 * 0.1 == 0.010000000000000002);
print(0.7 + 0.1 == 0.7999999999999999);
print(3.0 * 0.1 == 0.30000000000000004);
print(1.0 / 3.0 * 3.0 == 1.0);
print(0.1 * 10.0 == 1.0);
print(1e-22 * 1e22 == 1.0);
print(1e-300 * 1e300 == 1.0);
print(1e300 * 1e-300 == 1.0);
print(0.5e-323 == 5e-324);
print(5e-324 * 2.0 == 1e-323);
print(2.2250738585072014e-308 == 1.0 / 4.49423283715579e307);
print(9007199254740993.0 == 9007199254740992.0);
print(1.7976931348623157e308 * 2.0 == 1.0 / 0.0);
print(0.0 == -0.0);
print(9007199254740991.0 == 9007199254740991);
print(1e23 + 1e23 == 2e23);
print(0.0000005 * 2.0 == 0.000001);
print(1.0000000000000002 == 1.0 + 0.0000000000000002220446049250313);
print(6879105134148699645568039637986203093674960635552166291252944497675248566517495211346034807148322417897589780936147709090693038139155132898807857338851787478322049021475630124221088286265825285141340151290946093403749409597883934927165271824886773518136942287618420882006400145326726695657864114037921013707215276269195709129590510233498434899956919252872467041015625e-502 == 68791051341486996455680396379862030936749606355521662912529444976752485665174952113460348071483224178975897809361477090906930381391551328988078573388517874783220490214756301242210882862658252851413401512909460934037494095978839349271652718248867735181369422876184208820064001453267266956578641140379210137072152762691957091295905102334984348999569192528724670410156250e-503);

// 3. the specials

print(0.0, " ", -0.0, " ", 1e400);
print(-1e400, " ", 1e40000, " ", 1e-400);
print(-1e-400, " ", 1e-323, " ", 1e-45);
print(2.2250738585072014e-308);
