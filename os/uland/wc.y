// wc [-l] [-w] [-c] [files...] -- lines, words and bytes of each file (standard
// input when none); the flags choose which of the three to show.
import ulib;

let show_l = true;
let show_w = true;
let show_c = true;

def count(b: [byte], name: str) -> void {
    let lines = 0;
    let words = 0;
    let inword = false;
    let k = 0;
    while (k < len(b)) {
        let c = b[k];
        if (c == 10) { lines = lines + 1; };
        if (c == 32 || c == 10 || c == 9 || c == 13) { inword = false; }
        else if (!inword) { inword = true; words = words + 1; };
        k = k + 1;
    };
    let cols: [str] = [];
    if (show_l) { cols += tostring(lines); };
    if (show_w) { cols += tostring(words); };
    if (show_c) { cols += tostring(len(b)); };
    if (name != "") { cols += name; };
    puts(join(cols, " ") + "\n");
};

let a0 = argv();
let a: [str] = [a0[0]];
let flags = "";
a0[1:len(a0)].foreach((x) => {
    if (len(x) > 1 && x[0] == 45) { flags += x[1:len(x)]; } else { a += x; };
});
if (len(flags) > 0) {
    show_l = flags.contains("l");
    show_w = flags.contains("w");
    show_c = flags.contains("c");
};
let bad = 0;
if (len(a) < 2) { count(ulib.read_fd(0), ""); };
let i = 1;
while (i < len(a)) {
    let d = ulib.read_all(a[i]);
    if (d == none) {
        puts("wc: " + a[i] + ": no such file\n");
        bad = 1;
    } else {
        count(d!, a[i]);
    };
    i = i + 1;
};
exit(bad);
