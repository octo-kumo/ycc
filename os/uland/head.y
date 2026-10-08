// head [-n N] file -- the first N lines (ten by default).
import ulib;
let a = argv();
let n = 10;
let at = 1;
if (len(a) > 2 && a[1] == "-n") {
    let v = tolong(a[2]);
    if (v != none) { n = v!; };
    at = 3;
};
if (at >= len(a)) {
    puts("usage: head [-n N] <file>\n");
    exit(1);
};
let d = ulib.read_all(a[at]);
if (d == none) {
    puts("head: " + a[at] + ": no such file\n");
    exit(1);
} else {
    let b = d!;
    let lines = 0;
    let k = 0;
    while (k < len(b) && lines < n) {
        if (b[k] == 10) { lines = lines + 1; };
        k = k + 1;
    };
    ulib.write_bytes(1, b[0:k]);
};
