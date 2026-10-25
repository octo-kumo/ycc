// flags: --obfuscate --obfuscate-seed=3
// SSE arithmetic, comparisons and integer division in the bytecode VM.
def mixf(a: float, b: float) -> float { a * b + a / b - 1.25 };
def cmp(a: float, b: float) -> long {
    let x = a < b;
    let y = a > b;
    let z = a == b;
    (if (x) { 1 } else { 0 }) + (if (y) { 2 } else { 0 }) + (if (z) { 4 } else { 0 })
};
def quot(a: long, b: long) -> long { a / b };
def rem(a: long, b: long) -> long { a % b };
def conv(a: long, f: float) -> float { let x: float = a; x + f };
def main() -> long {
    print(tostring(mixf(1.5, 2.5)));
    print(tostring(cmp(1.5, 2.5)) + " " + tostring(cmp(3.0, 2.0)) + " " + tostring(cmp(2.0, 2.0)));
    print(tostring(quot(17, 5)) + " " + tostring(rem(17, 5)) + " " + tostring(quot(-17, 5)) + " " + tostring(rem(-17, 5)));
    print(tostring(conv(3, 0.5)));
    0
};
let r = main();
