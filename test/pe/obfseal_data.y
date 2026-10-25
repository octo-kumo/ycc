// flags: --obfuscate --obfuscate-seed=11
// A sealed PE with a heap array, a map, a closure and recursion: code and
// literals both have to be decrypted before the runtime sees them.
def fact(n: long) -> long { if (n <= 1) { 1 } else { n * self(n - 1) } };
def main() -> long {
    let xs = [1, 2, 3];
    xs += 4;
    let m: { str => long } = { "alpha": 1, "beta": 2 };
    let c = def (x: long) -> long { x * 2 };
    print(tostring(fact(6)) + " " + tostring(xs[3]) + " " + tostring(m["beta"]!) + " " + tostring(c(21)));
    print("data seal ok");
    0
};
let r = main();
