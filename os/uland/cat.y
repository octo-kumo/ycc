// cat files... -- write each file to the console.
import ulib;
let a = argv();
if (len(a) < 2) {
    puts("usage: cat <file>...\n");
    exit(1);
};
let bad = 0;
let i = 1;
while (i < len(a)) {
    let d = ulib.read_all(a[i]);
    if (d == none) {
        puts("cat: " + a[i] + ": no such file\n");
        bad = 1;
    } else {
        ulib.write_bytes(1, d!);
    };
    i = i + 1;
};
exit(bad);
