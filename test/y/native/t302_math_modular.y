// modular arithmetic: the modulus bound and the exactness that goes with it
import math;

// mul_mod, pow_mod, inv_mod all take 0 < m <= 2^31-1
print(math.mul_mod(1000000, 1000000, 2147483647));
print(math.mul_mod(0 - 3, 5, 7));
print(math.mul_mod(0, 12345, 97));
print(math.mul_mod(7, 0, 97));
print(math.mul_mod(7, 1, 1));                  // everything is 0 mod 1
print(math.mul_mod(5, 5, 0));                  // no modulus, no answer

print(math.pow_mod(2, 10, 1000));
print(math.pow_mod(2, 0, 1000));
print(math.pow_mod(0, 0, 1000));               // 1, as in C
print(math.pow_mod(3, 1, 2147483647));
print(math.pow_mod(2, 62, 2147483647));
print(math.pow_mod(2, 0 - 1, 1000));           // a negative power is 0 here

print(math.inv_mod(3, 11));
print(math.inv_mod(0 - 4, 11));
print(math.inv_mod(1, 2));
print(math.inv_mod(4, 8));                     // no inverse, so 0
print(math.inv_mod(0, 7));                     // 0 has no inverse mod 7

// Fermat: a^(m-1) == 1 (mod m) for a prime m and any a
print(math.pow_mod(2, 2147483646, 2147483647));
print(math.pow_mod(3, 2147483646, 2147483647));

// properties, over a prime modulus
let m = 1000003;                               // prime
let ok = true;
let a = 1;
while (a < 300) {
    if (math.mul_mod(a, 1, m) != a % m) { ok = false; };
    if (math.pow_mod(a, 2, m) != math.mul_mod(a, a, m)) { ok = false; };
    let inv = math.inv_mod(a, m);
    if (math.mul_mod(a, inv, m) != 1) { ok = false; };
    a = a + 1;
};
print(ok);