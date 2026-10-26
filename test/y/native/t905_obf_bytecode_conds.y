// flags: --ob=full --ob-seed=3
def ops(a: long, b: long) -> long {
    let r = 0;
    if (a == b) { r += 1 };
    if (a != b) { r += 2 };
    if (a < b) { r += 4 };
    if (a <= b) { r += 8 };
    if (a > b) { r += 16 };
    if (a >= b) { r += 32 };
    r
};
def bits(n: long) -> long { (~n) + (0 - n) + (n & 15) + (n | 3) + (n ^ 5) };
def loop(n: long) -> long {
    let i = 0;
    let s = 0;
    while (i < n) { s += i; i += 1 };
    s
};
def main() -> long {
    print(tostring(ops(3, 3)) + " " + tostring(ops(2, 5)) + " " + tostring(ops(7, 1)) + " " + tostring(bits(6)) + " " + tostring(loop(5)));
    0
};
let r = main();
