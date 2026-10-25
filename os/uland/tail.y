// tail [-n N] [file] -- the last N lines (ten by default) of a file or standard input.
import ulib;
let a = argv();
let n = 10;
let at = 1;
if (len(a) > 2 && a[1] == "-n") {
    let v = tolong(a[2]);
    if (v != none) { n = v!; };
    at = 3;
};
let b: [byte] = [];
if (at >= len(a)) {
    b = ulib.read_fd(0);
} else {
    let d = ulib.read_all(a[at]);
    if (d == none) {
        puts("tail: " + a[at] + ": no such file\n");
        exit(1);
    };
    b = d!;
};
// walk back over n newlines, not counting a final one
let end = len(b);
let k = end;
let seen = 0;
if (k > 0 && b[k - 1] == 10) { k = k - 1; };
while (k > 0 && seen < n) {
    k = k - 1;
    if (b[k] == 10) { seen = seen + 1; };
};
if (seen == n && n > 0) { k = k + 1; };
if (n == 0) { k = end; };
ulib.write_bytes(1, b[k:end]);
