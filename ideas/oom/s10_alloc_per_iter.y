// The general rule behind all of these: an allocation per iteration is a
// permanent leak.  A record, an option, a capturing closure, a fixed array
// and a number formatted to a string are all scratch in Go/Python/Java --
// here each is a few tens of bytes that never come back.  Five loops,
// measured apart.
type P = { a: long, b: long };
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
    let n = arg_n(200000);
    // a record per iteration, dropped at the end of the body
    let h0 = heap_used();
    let acc = 0;
    let i = 0;
    while (i < n) { let p: P = { a: i, b: i }; acc += p.a; i++; };
    rate("s10a_record", n, heap_used() - h0);
    // an option per iteration
    i = 0;
    h0 = heap_used();
    while (i < n) { let o: long? = some(i); if (o != none) { acc += 1; }; i++; };
    rate("s10b_option", n, heap_used() - h0);
    // a closure that captures the loop variable
    i = 0;
    h0 = heap_used();
    while (i < n) { let k = i; let f = def(x: long) { x + k }; acc += f(0); i++; };
    rate("s10c_closure", n, heap_used() - h0);
    // an integer formatted to a string
    i = 0;
    h0 = heap_used();
    while (i < n) { acc += tostring(i).length; i++; };
    rate("s10d_tostring", n, heap_used() - h0);
    // a fixed [T; N]: the elements live in a heap cell, so declaring one
    // per iteration allocates per iteration too (docs/src/08-functions.tex)
    i = 0;
    h0 = heap_used();
    while (i < n) { let a: [long; 4] = [0; 4]; acc += a[0]; i++; };
    rate("s10e_fixed_array", n, heap_used() - h0);
    print("acc=" + tostring(acc));
};
main();
