// flags: --ob=full --ob-seed=1
def fib(n: long) -> long {
    if (n < 2) { n } else { self(n - 1) + self(n - 2) }
};

def main() -> long {
    let xs = [1, 2, 3];
    xs += 4;
    let s = "ok";
    print(tostring(fib(10)) + " " + tostring(xs[0] + xs[3]));
    print(s + " " + tostring(len(s)));
    0
};

let r = main();
