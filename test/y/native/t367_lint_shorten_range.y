// flags: -W 2
def f(a: [long]) -> long {
    let s = 0;
    foreach (i in range(len(a))) { // expect-warning: this range loop over an array's indices can be '<a>.foreach((e, i) => { ... })'
        s += a[i];
    };
    s
};
def main() -> long {
    print(f([1, 2, 3]));
    0
};
exit(main());
