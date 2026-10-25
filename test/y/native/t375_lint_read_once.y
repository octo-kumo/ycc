// flags: --warnings=all
def f(a: long) -> long {
    let x = a + 1; // expect-warning: 'x' is read once; write its value where it is used
    x * 2
};
def main() -> long { print(f(3)); 0 };
exit(main());
