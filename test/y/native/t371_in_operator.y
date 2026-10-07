def f(s: str, c: byte, a: [long], n: long) -> long {
    let x = 0;
    if (c in s) { x = x + 1; };
    if ("ab" in s) { x = x + 2; };
    if (n in a) { x = x + 4; };
    x
};
def main() -> long { print(f("aab", 'a', [3, 1, 2], 1)); print(f("xy", 'a', [3], 9)); 0 };
exit(main());
