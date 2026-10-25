// Scalar specialization must retain signed comparisons and wrapping arithmetic.
let high = 9223372036854775807;
let low = -high - 1;
print(high + 1 == low, low - 1 == high, low * -1 == low, high * 2 == -2);
print(low < 0, high > low, low <= low, high >= high);
let n = high;
n++;
print(n == low);
n -= 1;
print(n == high);
print(2 + 0.5, "number " + 7, [1, 2] + 3);
foreach (v in [-2097153, -2097152, -2097151, 0, 2097151, 2097152, 2097153]) {
    print(v, v + 1, v - 1);
};
