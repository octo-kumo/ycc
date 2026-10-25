// Decimal literals may separate digits with `_` after the first digit of
// each part (whole, fraction, exponent). The lexer drops the separators,
// so whatever reads the literal (array lengths, shift counts, defaults,
// f-string fields) sees plain digits.
print(1_000_000);
print(1__0);
print(7_);
print(0_17);
print(9_223_372_036_854_775_807);
print(1_000 == 1000);
print(-2_5);
print(1_000.25);
print(0.000_5 * 1_000);
print(1_.5);
print(2.5_e1);
print(1e1_0);
print(1_e3);
let a = [0; 1_0];
print(len(a));
let b: [long; 1_2] = [7; 12];
print(len(b));
print(1 << 1_0);
print(1_024 >> 1_0);
let s = 0;
for i in 1_0..1_3 { s += i; };
print(s);
def f(x: long, d = 1_000) -> long { x + d };
print(f(1));
print(f(1, 2));
print(f"{1_000}|{2_0 * 2}");
