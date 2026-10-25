// Shared iteration lowering must preserve evaluation order and early exits.
def main() -> long {
    let trace: [long] = [];
    def receiver() -> [long] { trace += 1; [1, 2, 3] };
    def mapper() -> (long)->long {
        trace += 2;
        let bias = 10;
        (x: long) => x + bias
    };
    print(receiver().map(mapper()));
    print(trace);
    let calls = 0;
    let xs = [1, 2, 3];
    print(xs.all((x) => { calls++; x < 2 }));
    print(calls);
    calls = 0;
    print(xs.some((x) => { calls++; x == 2 }));
    print(calls);
    calls = 0;
    print(xs.find((x) => { calls++; x == 2 }));
    print(calls);
    let empty: [long] = [];
    print(empty.reduce((a, b) => a + b, 99));
    print(empty.find((x) => true));
    print(empty.filter((x) => true));
    let bytes: [byte] = [1, 2, 3];
    print(bytes.filter((x, i) => i != 1));
    print([bytes, bytes].flat());
    print(["a", "bb", "ccc"].index("bb"));
    let rs = [{n: 1}, {n: 2}];
    print(rs.index(rs[1]));
    print(rs.index({n: 2}));
    let seed = [0];
    let result = xs.reduce((acc, x) => { acc += x; acc }, seed);
    print(result);
    print(seed);
    0
};
exit(main());
