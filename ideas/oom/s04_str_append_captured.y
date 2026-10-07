// The accumulator is captured by a closure.
// Go/Python: a closure over an accumulator is idiomatic.
// Y: a captured str is boxed and never qualifies for the in-place append
// (docs/src/05-expressions.tex says so), so every += copies: O(n^2).
def arg_n(dflt: long) -> long {
    let a = argv();
    if (a.length > 1) {
        let v = a[1].tolong();
        if (v != none) { v! } else { dflt }
    } else { dflt }
};
def main() {
    let n = arg_n(15000);
    let s = "";
    let size = def() { s.length };
    let h0 = heap_used();
    let i = 0;
    while (i < n) { s += "a"; i++; };
    let d = heap_used() - h0;
    print("s04_str_append_captured n=" + tostring(n) + " len=" + tostring(s.length) +
        " size=" + tostring(size()) + " heap=" + tostring(d) + " per_iter=" + tostring(d / n));
};
main();
