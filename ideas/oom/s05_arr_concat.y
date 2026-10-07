// a = a + [x] to grow an array.
// Go/Python/JS: append/concat amortizes or the collector frees the old
// array; live memory stays O(n).
// Y: `a + b` is y_arr_cat, a NEW array with every element copied, and the
// old one is never freed: each round copies the whole thing, O(n^2) bytes.
// The one-word change a += x is in place (amortized doubling) and flat.
def arg_n(dflt: long) -> long {
    let a = argv();
    if (a.length > 1) {
        let v = a[1].tolong();
        if (v != none) { v! } else { dflt }
    } else { dflt }
};
def main() {
    let n = arg_n(10000);
    let h0 = heap_used();
    let a: [long] = [];
    let i = 0;
    while (i < n) { a = a + [i]; i++; };
    let d = heap_used() - h0;
    print("s05_arr_concat n=" + tostring(n) + " len=" + tostring(a.length) +
        " heap=" + tostring(d) + " per_iter=" + tostring(d / n));
};
main();
