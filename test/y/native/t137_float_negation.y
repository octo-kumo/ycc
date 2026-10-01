// Unary minus on a float flips the sign bit, so it is exact for every
// value: -0.0 is a negative zero (1.0 / -0.0 is -inf), and -(-x) is x.
let z = 0.0;
let x = 1.5;
let inf = 1.0 / z;
print(-x);
print(-(-x));
print(-x + 1.0);
print(1.0 / -0.0 < 0.0);
print(1.0 / -z < 0.0);
print(1.0 / -(-z) > 0.0);
print(-inf < 0.0);
print(-(-inf) > 0.0);
print(-0.0 == 0.0);
print([-0.0] == [0.0]);
let one = 1.0;
print(1.0 / (0.0 * -one) < 0.0);
