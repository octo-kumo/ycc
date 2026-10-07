// Formatting a float to a string per iteration (logging, telemetry).
// Go/Python: a small temporary, collected.
// Y: y_str_float builds and concatenates a dozen intermediate strings,
// ~1 KB per call, all permanent.  A 1 kHz telemetry loop leaks 1 MB/s.
def arg_n(dflt: long) -> long {
    let a = argv();
    if (a.length > 1) {
        let v = a[1].tolong();
        if (v != none) { v! } else { dflt }
    } else { dflt }
};
def main() {
    let n = arg_n(200000);
    let h0 = heap_used();
    let acc = 0;
    let i = 0;
    while (i < n) { acc += tostring(i * 1.5).length; i++; };
    let d = heap_used() - h0;
    print("s12_float_format n=" + tostring(n) + " acc=" + tostring(acc) +
        " heap=" + tostring(d) + " per_iter=" + tostring(d / n));
};
main();
