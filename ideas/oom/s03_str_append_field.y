// A struct field accumulates a string: rec.s += c.
// Go/Python: a struct field is a mutable slot or a reference to a builder.
// Y: only a plain local or global str gets the companion-cell in-place
// append; a field target has none, so every += copies: O(n^2).
type Buf = { s: str, n: long };
def arg_n(dflt: long) -> long {
    let a = argv();
    if (a.length > 1) {
        let v = a[1].tolong();
        if (v != none) { v! } else { dflt }
    } else { dflt }
};
def main() {
    let n = arg_n(15000);
    let b: Buf = { s: "", n: 0 };
    let h0 = heap_used();
    let i = 0;
    while (i < n) { b.s += "a"; i++; };
    let d = heap_used() - h0;
    print("s03_str_append_field n=" + tostring(n) + " len=" + tostring(b.s.length) +
        " heap=" + tostring(d) + " per_iter=" + tostring(d / n));
};
main();
