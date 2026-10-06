// A fixed array's length is part of its type, so a method that would
// change that length is rejected the same way `+=` is. Read-only
// methods (map, index, ...) and `sort`, which keeps the length, are fine.
// expect-error: 12:11: error: cannot resize fixed array [long; 3] with '.push' (its length is part of its type; use [T] instead)
// expect-error: 13:14: error: cannot resize fixed array [long; 3] with '.unshift' (its length is part of its type; use [T] instead)
// expect-error: 14:13: error: cannot resize fixed array [long; 3] with '.insert' (its length is part of its type; use [T] instead)
// expect-error: 15:10: error: cannot resize fixed array [long; 3] with '.pop' (its length is part of its type; use [T] instead)
// expect-error: 16:12: error: cannot resize fixed array [long; 3] with '.shift' (its length is part of its type; use [T] instead)
// expect-error: 17:13: error: cannot resize fixed array [long; 3] with '.remove' (its length is part of its type; use [T] instead)
def main() -> long {
    let a: [long; 3] = [1, 2, 3];
    a.push(4);
    a.unshift(0);
    a.insert(1, 9);
    a.pop();
    a.shift();
    a.remove(0);
    print(a.map((e) => e + 1));
    print(a.index(2));
    a.sort((x, y) => x - y);
    0
}
exit(main());
