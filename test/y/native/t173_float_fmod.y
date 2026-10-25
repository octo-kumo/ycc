// `float % float` was never implemented: it fell through to the comparison
// branch, so `5.5 % 2.0` compared instead of dividing, and the 0/1 bool was read
// as the double's bits -- every result was zero.
//
// It is now the IEEE remainder truncated toward zero, which is what C's fmod
// returns: the sign follows the dividend, the magnitude is under |y|, and
// nothing rounds (x86 has no fmod instruction, so the prelude does long
// division on the significands -- y_fmod in arch_x64.y). Integers are
// unaffected: `7 % 3` is still 1, and 7.0 % 3.0 is 1.0.

let inf = 1.0 / 0.0;
let nan = 0.0 / 0.0;

// NaN never equals anything, itself included, so comparing is how these are
// pinned down where %f cannot resolve the value
def same(x: float, y: float) -> bool { if (x != x) { y != y } else { x == y } };

def wrap(v: float, m: float) -> float { v % m };

print(5.5 % 2.0, " ", -5.5 % 2.0, " ", 5.5 % -2.0, " ", -5.5 % -2.0);

// an exact multiple gives zero, with the dividend's sign
print(4.0 % 2.0, " ", -4.0 % 2.0, " ", 6.0 % 1.5, " ", -6.0 % 1.5);

// under the divisor is the dividend itself
print(2.0 % 4.0, " ", -2.0 % 4.0, " ", 0.0 % 3.0, " ", -0.0 % 3.0);

// and over it, to any size: 1e300 / 3 is a quotient of 300 digits
print(1e300 % 7.0, " ", 100.0 % 7.0, " ", 2.25 % 1.5, " ", -2.25 % 1.5);

// subnormal and tiny values, which %f prints as 0.000000
print(same(1.0 % 1e-300, 8.963186528039712e-301), " ", same(3.0 % 1e-310, 5.2229528313e-312));
print(same(1.0 % 5e-324, 0.0), " ", same(24443.580472511356 % 1.5e-323, 1e-323));
print(same(-1.0 % 1e-300, -8.963186528039712e-301), " ", same(-24443.580472511356 % 1.5e-323, -1e-323));

// the special cases: NaN wherever IEEE says so, and the dividend itself for an
// infinite divisor
print(same(nan % 2.0, nan), " ", same(1.0 % 0.0, nan), " ", same(0.0 % 0.0, nan));
print(same(1.0 % nan, nan), " ", same(nan % nan, nan), " ", same(inf % 2.0, nan));
print(5.0 % inf, " ", -5.0 % inf, " ", same(inf % inf, nan), " ", same(nan % inf, nan));

// variables, a def, and the compound form
let x = 9.75;
let y = 2.5;
print(x % y, " ", wrap(x, y), " ", wrap(-x, y));
let w = 10.0;
w %= 3.0;
print(w);
let i = 7;
i %= 3;
print(i);

// integers keep the old meaning
print(7 % 3, " ", -7 % 3, " ", 7 % -3, " ", 7.0 % 3.0);

// and it composes: an angle wrapped into [0, 2pi)
let two_pi = 6.283185307179586;
let ang = 3 * two_pi / 2.0;
print(ang % two_pi);
