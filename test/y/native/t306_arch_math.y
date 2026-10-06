// the four machine primitives in src/y/arch/math.s, reached through
// `native def` -- the only machine code between Y and a numeric library, and
// what std/math.y's transcendentals will be written on
native def sqrt(x: float) -> float = "y_sqrt";
native def to_int(x: float) -> long = "y_to_int";
native def fbits(x: float) -> long = "y_fbits";
native def bitsf(b: long) -> float = "y_bitsf";

def is_nan(x: float) -> bool { x != x };

// sqrtsd is the hardware's own root, so it is correctly rounded: sqrt(2) is
// the double below, not one computed to a few digits
print(sqrt(4.0));
print(f"{sqrt(2.0):.17f}");
print(sqrt(0.0));
print(sqrt(1.0));
print(sqrt(1024.0));
print(sqrt(1.0e10));
print(is_nan(sqrt(0.0 - 1.0)));              // a negative root is the NaN SSE gives
print(sqrt(1.0 / 0.0));                      // and sqrt(+inf) is +inf
print(is_nan(sqrt(0.0 / 0.0)));

// to_int truncates toward zero -- not a floor, not a round
print(to_int(3.9));
print(to_int(0.0 - 3.9));
print(to_int(42.0));
print(to_int(0.5));
print(to_int(0.0 - 0.5));
print(to_int(0.0 - 0.0));
// a NaN, an infinity, or a magnitude past the largest long comes back as the
// "integer indefinite" value, the most negative long: the caller can see it
print(to_int(0.0 / 0.0));
print(to_int(1.0 / 0.0));
print(to_int(1.0e300));

// the two bit casts. 1.0 is 0x3FF0000000000000, -2.0 is 0xC000000000000000,
// and an infinity 0x7FF0000000000000
print(fbits(1.0));
print(fbits(0.0 - 2.0));
print(fbits(0.0));
print(fbits(1.0 / 0.0));
print(bitsf(4607182418800017408));
print(bitsf(0));
print(bitsf(0 - 9223372036854775807 - 1));   // -0.0
print(bitsf(9218868437227405312));           // +inf
print(fbits(bitsf(4613937818241073152)));    // 2.0, through both casts

// a float is 8 bytes like every other value, so this works now
print(sqrt(to_int(16.0)));
print(f"{bitsf(fbits(1.0)):.1f}");