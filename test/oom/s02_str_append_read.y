// s += c, but the loop also READS s (here s.length).
// Go/Python: builders are mutable, a length read is free.
// Y: a read ends the append's ownership (docs/src/05-expressions.tex
// "Appending"), so the next += is a full copy: hidden O(n^2).
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
    let seen = 0;
    while (i < n) { s += "a"; seen = s.length; i++; };
    let d = heap_used() - h0;
    print("s02_str_append_read n=" + tostring(n) + " len=" + tostring(s.length) +
        " seen=" + tostring(seen) + " heap=" + tostring(d) + " per_iter=" + tostring(d / n));
};
main();
