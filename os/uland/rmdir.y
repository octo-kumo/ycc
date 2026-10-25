// rmdir dir... -- remove empty directories.
import ulib;
let a = argv();
if (len(a) < 2) { puts("usage: rmdir <dir>...\n"); exit(1); };
let bad = 0;
let i = 1;
while (i < len(a)) {
    if (ulib.rmdir(a[i]) < 0) {
        puts("rmdir: " + a[i] + ": cannot remove (missing, not a directory or not empty)\n");
        bad = 1;
    };
    i = i + 1;
};
exit(bad);
