// s = s + c in a loop.
// Go/Python/Java: every intermediate is garbage; the collector keeps the
// live set at O(n) bytes, so this runs in flat memory.
// Y: `+` is y_str_cat, a fresh allocation, and nothing is ever freed, so
// the loop retains every intermediate: O(n^2) bytes.
def arg_n(dflt: long) -> long {
    let a = argv();
    if (a.length > 1) {
        let v = a[1].tolong();
        if (v != none) { v! } else { dflt }
    } else { dflt }
};
def main() {
    let n = arg_n(15000);
    let h0 = heap_used();
    let s = "";
    let i = 0;
    while (i < n) { s = s + "a"; i++; };
    let d = heap_used() - h0;
    print("s01_str_concat n=" + tostring(n) + " len=" + tostring(s.length) +
        " heap=" + tostring(d) + " per_iter=" + tostring(d / n));
};
main();
