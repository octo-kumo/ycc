// Searching the same string with the same compiled pattern in a loop.
// Go/Python: the Match result is garbage, memory is flat.
// Y: every search allocates, and the previous results stay on the heap;
// ~1.8 KB per search for a 19-byte subject.
import regex;
def arg_n(dflt: long) -> long {
    let a = argv();
    if (a.length > 1) {
        let v = a[1].tolong();
        if (v != none) { v! } else { dflt }
    } else { dflt }
};
def main() {
    let n = arg_n(20000);
    let re = regex.compile("[0-9]+")!;
    let s = "abc 123 def 456 ghi";
    let h0 = heap_used();
    let acc = 0;
    let i = 0;
    while (i < n) { let m = regex.search(re, s); if (m != none) { acc++; }; i++; };
    let d = heap_used() - h0;
    print("s09_regex_loop n=" + tostring(n) + " acc=" + tostring(acc) +
        " heap=" + tostring(d) + " per_iter=" + tostring(d / n));
};
main();
