// The other half of the picture: the operations that DO stay flat.  These
// are the shapes to reach for in a long-running Y program.  Every number
// below should be a few hundred bytes no matter how large n is.
type P = { a: long, b: long };
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
def acc_all(s: str, xs: [str]) -> str {
    foreach (x in xs) { s += x; };
    s
};
def main() {
    let n = arg_n(200000);
    let acc = 0;
    // arithmetic: no heap at all
    let h0 = heap_used();
    for i in 0..n { acc += i * 3; };
    rate("c01_pure_loop", n, heap_used() - h0);
    // s += x with no read of s in the loop: the buffer doubles in place
    let h0b = heap_used();
    let s = "";
    let i = 0;
    while (i < n) { s += "a"; i++; };
    rate("c02_str_append_owned", n, heap_used() - h0b);
    // a += x / push: in place, amortized doubling
    let h0c = heap_used();
    let a: [long] = [];
    i = 0;
    while (i < n) { a += i; i++; };
    rate("c03_arr_push", n, heap_used() - h0c);
    // in-place sort, not `sorted`
    let h0d = heap_used();
    a.sort(def(x: long, y: long) { x - y });
    rate("c04_sort_in_place", n, heap_used() - h0d);
    // a helper appending to its str parameter keeps ownership
    let parts: [str] = [];
    for k in 0..1000 { parts += "a"; };
    let h0e = heap_used();
    let out = acc_all("", parts);
    rate("c05_param_append", len(parts), heap_used() - h0e);
    // the queue as an index, not a slice
    let q: [long] = [];
    for k in 0..10000 { q += k; };
    let h0f = heap_used();
    let head = 0;
    while (head < q.length) { acc += q[head]; head++; };
    rate("c06_queue_index", q.length, heap_used() - h0f);
    // destructuring a union member reads in place (s11 binds and copies)
    let sh: Shape = { aaa: 3, id: 1, tag: 2 };
    let h0g = heap_used();
    i = 0;
    while (i < n) { acc += match sh { Circle { aaa: v } => v, Square { bbb: w } => w }; i++; };
    rate("c07_union_destructure", n, heap_used() - h0g);
    print("acc=" + tostring(acc) + " s=" + tostring(s.length) + " out=" + tostring(out.length));
};
main();
