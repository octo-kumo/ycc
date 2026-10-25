// touch file... -- make an empty file when there is none.
import ulib;
let a = argv();
if (len(a) < 2) { puts("usage: touch <file>...\n"); exit(1); };
let bad = 0;
let i = 1;
while (i < len(a)) {
    if (!ulib.exists(a[i])) {
        let fd = ulib.open(a[i], ulib.O_CREATE);
        if (fd < 0) { puts("touch: cannot create " + a[i] + "\n"); bad = 1; } else { ulib.close(fd); };
    };
    i = i + 1;
};
exit(bad);
