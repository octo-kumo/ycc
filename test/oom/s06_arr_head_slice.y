// A FIFO queue: q = q[1:] drops the head element each round.
// Go/Rust/JS: shift()/s[1:] is a view or an O(1) index bump; the collector
// reclaims the old tail view, so live memory is O(n).
// Y: a slice is y_arr_slice, a fresh copy of the tail, kept forever, so
// draining an n-element queue allocates O(n^2) bytes.
def arg_n(dflt: long) -> long {
    let a = argv();
    if (a.length > 1) {
        let v = a[1].tolong();
        if (v != none) { v! } else { dflt }
    } else { dflt }
};
def main() {
    let n = arg_n(10000);
    let q: [long] = [];
    for i in 0..n { q += i; };
    let h0 = heap_used();
    let acc = 0;
    while (q.length > 0) { acc += q[0]; q = q[1: ]; };
    let d = heap_used() - h0;
    print("s06_arr_head_slice n=" + tostring(n) + " acc=" + tostring(acc) +
        " heap=" + tostring(d) + " per_iter=" + tostring(d / n));
};
main();
