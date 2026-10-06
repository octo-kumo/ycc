// The array-method closures come in shapes: the element alone, element and
// index, or no parameter at all, and `v => v`, `(e, i) => ...` and
// `def(e, i) { ... }` are the same closure literal. An empty array answers
// the identity of each method; a [byte] and a fixed [T; N] receiver work
// with the methods that do not change its length.
def main() -> long {
    let a = [10, 20, 30];
    print(a.map((e, i) => e + i));
    print(a.filter((e, i) => i > 0));
    print(a.map(v => v * 2));
    let c = 0;
    a.foreach((e, i) => { c = c + e + i; });
    print(c);
    let seen: [long] = [];
    a.foreach((e) => { seen += e; });
    print(seen);
    let n = 0;
    a.foreach(() => { n = n + 1; });
    print(n);
    print(a.all((e, i) => e >= i * 10));
    print(a.some((e, i) => e == i * 10 + 30));
    if let some(f) = a.find((e, i) => i == 2) { print(f); } else { print(-1); };
    print(a.map(def(e, i) { e + i }));
    print(a.reduce(def(acc, v) { acc + v }, 100));
    let z: [long] = [];
    print(z.all((e) => false));
    print(z.some((e) => true));
    print(z.map((e) => e));
    print(z.index(1));
    let zz: [[long]] = [];
    print(zz.flat());
    let b: [byte] = [1, 2, 3];
    print(b.pop());
    b.push(4);
    print(b);
    print(b.map((x) => x + 1));
    let f: [long; 3] = [3, 1, 2];
    print(f.map((e) => e * 10));
    print(f.index(1));
    f.sort((x, y) => x - y);
    print(f);
    0
};
exit(main());
