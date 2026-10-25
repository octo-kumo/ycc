// flags: --obfuscate=full --obfuscate-vm=bytecode --obfuscate-seed=2
def mix(a: long, b: long) -> long { ((a * 3) ^ (b + 11)) - (a & b) }
def sign(n: long) -> long { if (n < 0) { 0 - n } else { n } }
def sh(n: long) -> long { (n << 3) + (n >> 1) }
def loop(n: long) -> long {
    let i = 0;
    let s = 0;
    while (i < n) { s += i; i += 1 };
    s
};
def main() -> long {
    print(tostring(mix(7, 4)) + " " + tostring(sign(0 - 9)) + " " + tostring(sh(6)) + " " + tostring(loop(5)));
    0
};
let r = main();
