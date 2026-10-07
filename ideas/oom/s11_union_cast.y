// Matching a union member with a BINDING (Circle c) copies the record
// whenever the member's own field order differs from the union's
// shared-fields-first layout; a DESTRUCTURING pattern reads in place.
// Other languages: a tagged union is a no-copy discriminator test.
// Here the same loop allocates 48 bytes a round or nothing at all --
// depending on the field NAMES, because records are laid out by name.
type Shape = Circle | Square;
type Circle = { aaa: long, id: long, tag: long };
type Square = { bbb: long, id: long, tag: long };
def arg_n(dflt: long) -> long {
    let a = argv();
    if (a.length > 1) {
        let v = a[1].tolong();
        if (v != none) { v! } else { dflt }
    } else { dflt }
};
def rate(tag: str, n: long, d: long) {
    print(tag + " n=" + tostring(n) + " heap=" + tostring(d) + " per_iter=" + tostring(d / n));
};
def main() {
    let n = arg_n(1000000);
    let s: Shape = { aaa: 3, id: 1, tag: 2 };
    // binding arm: the cast copies because the standalone Circle sorts
    // {aaa, id, tag} but the union layout is {id, tag, aaa}
    let h0 = heap_used();
    let acc = 0;
    let i = 0;
    while (i < n) { acc += match s { Circle c => c.aaa, Square q => q.bbb }; i++; };
    rate("s11a_bind", n, heap_used() - h0);
    // destructuring arm: no copy
    i = 0;
    h0 = heap_used();
    while (i < n) { acc += match s { Circle { aaa: v } => v, Square { bbb: w } => w }; i++; };
    rate("s11b_destructure", n, heap_used() - h0);
    print("acc=" + tostring(acc));
};
main();
