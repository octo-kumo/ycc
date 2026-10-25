// flags: --warnings=all
def a(xs: [long]) -> long {
    let i = 0; // expect-warning: this index loop can be 'xs.foreach((e, i) => { ... })'
    while (i < len(xs)) {
        print(xs[i]);
        i++;
    };
    0
};
def b() -> long {
    let j = 0; // expect-warning: this index loop can be 'for j in <lo>..<hi> { ... }'
    while (j < 4) {
        print(j);
        j++;
    };
    0
};
def main() -> long {
    print(a([1, 2]));
    print(b());
    0
};
exit(main());
