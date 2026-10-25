// Lowered methods evaluate operands once and keep stable array aliases.
def main() -> long {
    let trace: [long] = [];
    let a = [10, 20, 30, 40];
    let alias = a;
    def receiver() -> [long] { trace += 1; a };
    def index() -> long { trace += 2; 1 };
    def count() -> long { trace += 3; 2 };
    print(receiver().remove(index(), count()));
    print(trace);
    print(alias);
    print(a.remove(len(a), 0));
    print(a.remove(0, 0));
    print(a);
    let empty: [long] = [];
    print(empty.remove(0, 0));
    let bytes: [byte] = [10, 20, 30, 40];
    let ba = bytes;
    print(bytes.shift());
    print(bytes.remove(1));
    print(bytes.pop());
    print(ba);
    print(bytes.unshift(99));
    print(bytes.push(88));
    print(ba);
    let xs = [1];
    let seen: [long] = [];
    xs.foreach((x) => {
        seen += x;
        if (x < 24) { xs += x + 1; };
    });
    print(len(seen));
    print(seen[23]);
    let calls = 0;
    print([1, 2, 3].map((x) => { calls++; return [x, calls]; }));
    print(calls);
    let rs = [{key: 2, id: 1}, {key: 1, id: 2}, {key: 2, id: 3}];
    let sorted = rs.sorted((x, y) => x.key - y.key);
    print(sorted.map((x) => x.id));
    print(rs.map((x) => x.id));
    let captured = 1;
    let compare = (x: long, y: long) => { captured++; x - y };
    print([3, 2, 1].sorted(compare));
    print(captured);
    0
};
exit(main());
