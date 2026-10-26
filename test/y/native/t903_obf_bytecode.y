// flags: --ob=full --ob-seed=1
def add(a: long, b: long) -> long { a + b }
def sq(n: long) -> long { n * n }
def choose(n: long) -> long { if (n > 3) { n - 1 } else { n + 1 } }
def main() -> long {
    print(tostring(add(2, 3)) + " " + tostring(sq(4)) + " " + tostring(choose(9)) + " " + tostring(choose(1)));
    0
};
let r = main();
