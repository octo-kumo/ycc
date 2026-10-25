// W4: two threads of 300k allocations (t385's shape, with shorter strings).
// The host's clone/futex run them; the collector is the program's own.
import fs;
def churn(n: long) -> long {
    let total = 0;
    let i = 0;
    while (i < n) {
        let s = "x" + tostring(i);
        total = total + s.length;
        i = i + 1;
    };
    total
};
let a = spawn { churn(300000) };
let b = spawn { churn(300000) };
print(join a, " ", join b);
