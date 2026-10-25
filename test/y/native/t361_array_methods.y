// Array methods: mutation (pop/shift/remove/push/unshift/insert), iteration
// with arrow closures (foreach/map/filter/all/some/find), reduce, flat,
// index, sort/sorted.
def main() -> long {
    let a = [1, 2, 3, 4];
    print(a);
    print(a.pop());
    print(a);
    print(a.shift());
    print(a);
    print(a.remove(0));
    print(a);
    print(a.remove(0, 1));
    print(a);
    a.push(8); a.push(9);
    a.unshift(7);
    print(a);
    a.insert(1, 100);
    print(a);
    let m = a.map((e) => e + 1);
    print(m);
    let f = a.filter((e) => e > 7);
    print(f);
    print(a.all((e) => e > 0));
    print(a.some((e) => e == 100));
    print(a.index(8));
    print(a.index(123));
    print(a.reduce((acc, v) => acc + v, 0));
    print([[1, 2], [3], [4, 5]].flat());
    if let some(x) = a.find((e) => e == 8) { print(x); } else { print(0); };
    if let some(y) = a.find((e) => e == 123) { print(y); } else { print(-1); };
    let sorted = [3, 1, 4, 2].sorted((x, y) => x - y);
    print(sorted);
    a.sort((x, y) => y - x);
    print(a);
    0
};

exit(main());
