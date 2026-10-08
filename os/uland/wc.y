// wc files... -- lines, words and bytes of each file.
import ulib;
let a = argv();
if (len(a) < 2) {
    puts("usage: wc <file>...\n");
    exit(1);
};
let i = 1;
while (i < len(a)) {
    let d = ulib.read_all(a[i]);
    if (d == none) {
        puts("wc: " + a[i] + ": no such file\n");
    } else {
        let b = d!;
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
        puts(tostring(lines) + " " + tostring(words) + " " + tostring(len(b)) + " " + a[i] + "\n");
    };
    i = i + 1;
};
