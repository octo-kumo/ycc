// rm files... -- remove files.
import ulib;
let a = argv();
if (len(a) < 2) {
    puts("usage: rm <file>...\n");
    exit(1);
};
let bad = 0;
let i = 1;
while (i < len(a)) {
    if (ulib.unlink(a[i]) < 0) {
        puts("rm: " + a[i] + ": no such file\n");
        bad = 1;
    };
    i = i + 1;
};
exit(bad);
