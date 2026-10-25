// flags: --gc=never
// A helper returns a scalar while its scratch allocations die at the call.
// The empty loop still needs the call's region on its condition.
let ticks = 0;
def next() -> bool {
    ticks += 1;
    let a = [ticks; 100];
    let s = tostring(a[99]);
    s.length < 4
}
while (next()) { }
print(ticks);

def sum(n: long) -> long {
    let scratch = [n; 100];
    if (n == 0) { scratch[0] } else { scratch[0] + self(n - 1) }
}
print(sum(100));
let values: [long] = [];
for i in 0..1000 { values += i; }
print(values.length);
