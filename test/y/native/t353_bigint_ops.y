import math;

def add(a: bigint, b: bigint) -> bigint { a + b };

def main() -> long {
    print(1000n);
    print(2n + 3n * 4n);
    print(1000n / 7n);
    print(1000n % 7n);
    print(0 - 5n);
    print(0b1010n + 0o17n + 0xFFn);
    print(5n == 5);
    print(5n < 6);
    print(5n > 4.5);
    print(tolong(123456789n));
    print(tofloat(123n));
    print(add(20n, 22));
    let xs: [bigint] = [1n, 2n];
    let ys: [bigint] = [1n, 2n];
    print(xs == ys);
    let o: bigint? = some(9n);
    print(o);
    print("big=" + 1000n);
    print(f"{1000n}");
    print(math.isnan(0.0 / 0.0));
    print(math.isnan(1.0));
    0
};
exit(main());
