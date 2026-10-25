def main() -> long {
    let xs = [1, 2, 3];
    let calls = 0;
    print(xs.reduce(() => { calls++; 7 }, 0));
    print(calls);
    print(xs.reduce((acc) => acc + 1, 0));
    let reducer = (acc: long) => acc + 1;
    print(xs.reduce(reducer, 0));
    print(xs.reduce((acc, x) => acc + x, 0));
    let cmp0 = () => 0;
    print([3, 2, 1].sorted(cmp0));
    print([3, 2, 1].sorted((x) => x - 2));
    let cmp1 = (x: long) => x - 2;
    print([3, 2, 1].sorted(cmp1));
    let a = [3, 1, 2];
    def comparator() -> (long, long) -> long {
        a[0] = 0;
        (x: long, y: long) => x - y
    };
    print(a.sorted(comparator()));
    print(a);
    0
};
exit(main());
