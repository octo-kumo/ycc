// Slicing a big buffer in a loop, e.g. a rolling window or a per-frame
// view of a scratch buffer -- the shape Go/Rust give you for free.
// Go: buf[0:k] is a view, O(1).  Rust: &buf[..k], O(1).
// Y: every slice allocates a k-byte copy, and it is never freed, so the
// heap grows by k bytes per iteration regardless of the live set.
// This one reaches the 3.5 GB cap in a few thousand iterations.
def arg_n(dflt: long) -> long {
    let a = argv();
    if (a.length > 1) {
        let v = a[1].tolong();
        if (v != none) { v! } else { dflt }
    } else { dflt }
};
def main() {
    let n = arg_n(500);
    let k = 1000000;
    let buf: [byte] = [];
    for i in 0..k { buf += 65; };
    let h0 = heap_used();
    let acc = 0;
    let i = 0;
    while (i < n) { let w = buf[0:k]; acc += w.length; i++; };
    let d = heap_used() - h0;
    print("s07_slice_view n=" + tostring(n) + " k=" + tostring(k) + " acc=" + tostring(acc) +
        " heap=" + tostring(d) + " per_iter=" + tostring(d / n));
};
main();
