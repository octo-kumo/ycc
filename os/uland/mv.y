// mv src... dst -- rename files; into dst when it is a directory.
import ulib;

def base(p: str) -> str {
    let e = len(p);
    while (e > 1 && p[e - 1] == 47) { e = e - 1; };
    let k = e;
    while (k > 0 && p[k - 1] != 47) { k = k - 1; };
    p[k:e]
};

let a = argv();
if (len(a) < 3) {
    puts("usage: mv <src>... <dst>\n");
    exit(1);
};
let dst = a[len(a) - 1];
let into = ulib.is_dir(dst);
if (len(a) > 3 && !into) {
    puts("mv: " + dst + ": not a directory\n");
    exit(1);
};
let bad = 0;
let i = 1;
while (i < len(a) - 1) {
    let to = if (into) { (if (dst[len(dst) - 1] == 47) { dst } else { dst + "/" }) + base(a[i]) } else { dst };
    if (ulib.rename(a[i], to) < 0) {
        puts("mv: cannot rename " + a[i] + "\n");
        bad = 1;
    };
    i = i + 1;
};
exit(bad);
