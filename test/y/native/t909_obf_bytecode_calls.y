// flags: --obfuscate=full --obfuscate-vm=bytecode --obfuscate-seed=5
// The bytecode VM's call bridge: recursion and four stack arguments.
def fact(n: long) -> long { if (n <= 1) { 1 } else { n * fact(n - 1) } };
def sum4(a: long, b: long, c: long, d: long) -> long { a + b + c + d };
def main() -> long {
    print(tostring(fact(6)) + " " + tostring(sum4(1, 2, 3, 4)));
    let xs = [1, 2, 3];
    let s = 0;
    for i in 0..3 { s += xs[i]; };
    print(tostring(s));
    0
};
let r = main();
