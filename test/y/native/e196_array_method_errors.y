// expect-error: 21:11: error: array has no method 'nope'
// expect-error: 22:18: error: 'array.map' takes 1 arg, got 0
// expect-error: 23:19: error: 'array.flat' needs an array of arrays, got [long]
// expect-error: 24:19: error: expected a closure, got long
// expect-error: 25:21: error: 'array.filter' predicate: expected bool, got long
// expect-error: 26:18: error: 'array.all' predicate: expected bool, got long
// expect-error: 27:19: error: 'array.some' predicate: expected bool, got long
// expect-error: 28:19: error: 'array.find' predicate: expected bool, got long
// expect-error: 29:21: error: 'array.reduce' reducer: expected long, got str
// expect-error: 30:19: error: 'array.sort' comparator: expected long, got str
// expect-error: 31:10: error: 'array.pop' takes no args, got 1
// expect-error: 32:13: error: 'array.remove' takes 1 or 2 args, got 0
// expect-error: 33:11: error: 'array.flat' takes no args, got 1
// expect-error: 34:10: error: 'array.map' takes 1 arg, got 2
// expect-error: 35:11: error: 'array.push' arg: expected long, got str
// expect-error: 36:19: error: closure parameter 1: expected long, got str
// expect-error: 37:19: error: closure argument 1: expected long, got str
def conv(s: str) -> str { s };
def main() -> long {
    let a = [1, 2, 3];
    a.nope();
    let b = a.map();
    let c = a.flat();
    let d = a.map(1);
    let e = a.filter((x) => 1);
    let f = a.all((x) => 1);
    let g = a.some((x) => 1);
    let h = a.find((x) => 1);
    let i = a.reduce((acc, v) => "x", 0);
    let j = a.sort((x, y) => "x");
    a.pop(1);
    a.remove();
    a.flat(1);
    a.map((x) => x, 1);
    a.push("x");
    let k = a.map((x: str) => x);
    let l = a.map(conv);
    0
}
exit(main());
