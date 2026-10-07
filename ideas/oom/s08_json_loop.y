// Parsing the same small JSON document in a loop (a request handler, a
// config poll).  Go/Python: the parse tree is garbage after each round.
// Y: json.parse builds a fresh tree of records/arrays/strings every call
// and nothing is freed; ~3 KB per parse for a 40-byte document.
import json;
def arg_n(dflt: long) -> long {
    let a = argv();
    if (a.length > 1) {
        let v = a[1].tolong();
        if (v != none) { v! } else { dflt }
    } else { dflt }
};
def main() {
    let n = arg_n(20000);
    let txt = "{\"a\": [1, 2, 3], \"b\": {\"c\": \"hello\"}}";
    let h0 = heap_used();
    let acc = 0;
    let i = 0;
    while (i < n) {
        let v = json.parse(txt);
        if (v != none) { acc += len(keys(v!)); };
        i++;
    };
    let d = heap_used() - h0;
    print("s08_json_loop n=" + tostring(n) + " acc=" + tostring(acc) +
        " heap=" + tostring(d) + " per_iter=" + tostring(d / n));
};
main();
