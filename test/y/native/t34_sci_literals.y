// scientific-notation literals (the exponent folds into the scale factor)
print(1e3);
print(1E3);
print(1e+3);
print(1.5e-2);
print(2.5e2);
print(1e0);
print(1.6e-19);
print(7.5e-1);
print(1e9);
print(1.23456e4);

// radix literals keep their meaning: 0xE1 / 0b101 are not exponents
print(0xff);
print(0b101);
print(0xE1);
print(0XAB);

// exponents mix with arithmetic like any other float
print(1e3 + 1.5);
print(2e2 * 3.0);
print(1e3 / 4.0);
let c = 3e2;
print(c - 1.0);
print(c > 299.0);
