// flags: --obfuscate=full --obfuscate-vm=all --obfuscate-seed=3
// Two threads fault lazy code pages through the same loader lock.
def work(n: long) -> long {
    let s = 0;
    for i in 0..n { s += i; };
    s
};

let a = spawn { work(1000) };
let b = spawn { work(2000) };
print(join(a), " ", join(b));
