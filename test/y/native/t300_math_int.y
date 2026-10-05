// integers and bit tricks
import math;

print(math.min(3, 9));
print(math.min(0 - 4, 0 - 4));
print(math.max(3, 9));
print(math.abs(0 - 7));
print(math.abs(7));
print(math.clamp(15, 0, 10));
print(math.clamp(0 - 15, 0, 10));
print(math.clamp(5, 0, 10));
print(math.sign(0 - 5));
print(math.sign(0));
print(math.sign(5));

print(math.gcd(462, 1071));
print(math.gcd(0, 0));
print(math.gcd(0 - 12, 18));
print(math.lcm(4, 6));
print(math.lcm(0, 5));

print(math.isqrt(0));
print(math.isqrt(1));
print(math.isqrt(2));
print(math.isqrt(15));
print(math.isqrt(16));
print(math.isqrt(2147483647));
print(math.isqrt(4611686018427387904));

print(math.popcount(0));
print(math.popcount(255));
print(math.popcount(0 - 1));
print(math.popcount(0 - 2));

print(math.ctz(1));
print(math.ctz(8));
print(math.ctz(0 - 1));
print(math.ctz(0));
print(math.clz(1));
print(math.clz(255));
print(math.clz(0 - 1));
print(math.clz(0));
// clz and ctz must agree about the same bit: clz + ctz = 63 for a non-zero x
print(math.clz(8) + math.ctz(8));

print(math.next_pow2(0));
print(math.next_pow2(1));
print(math.next_pow2(5));
print(math.next_pow2(1024));
print(math.next_pow2(1025));

// properties, checked rather than just printed
let ok = true;
let i = 1;
while (i < 200) {
    if (math.next_pow2(i) < i) { ok = false; };
    if (math.next_pow2(i) >= 2 * i) { ok = false; };
    if (math.clz(i) + math.ctz(i) != 63) { ok = false; };
    if (math.isqrt(i * i) != i) { ok = false; };
    if (math.gcd(i, i + 1) != 1) { ok = false; };
    i = i + 1;
};
print(ok);