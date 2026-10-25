def f(n: long, a: [long], s: str) -> long {
    let x = 0;
    if (n in s) { x = 1; }; // expect-error: 'in' on a str needs a byte or a str on the left, got long
    if (s in a) { x = 2; }; // expect-error: 'in' on an array needs one of its elements on the left, got str
    if (n in 3) { x = 3; }; // expect-error: 'in' needs a str, an array or a map on the right, got long
    x
};
def main() -> long { print(f(1, [1], "a")); 0 };
exit(main());
