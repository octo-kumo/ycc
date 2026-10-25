// flags: --obfuscate --obfuscate-seed=1
// Two bytecode calls in one expression: a Y callee returns with ret $8n, so
// the interpreter must drop that argument window from the virtual stack.
def fib(n: long) -> long {
    if (n < 2) { n } else { self(n - 1) + self(n - 2) }
};
def main() -> long {
    print(tostring(fib(10)) + " " + tostring(fib(15)));
    0
};
let r = main();
