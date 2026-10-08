// cp src dst -- copy a file (an existing dst is replaced).
import ulib;
let a = argv();
if (len(a) != 3) {
    puts("usage: cp <src> <dst>\n");
    exit(1);
};
let d = ulib.read_all(a[1]);
if (d == none) {
    puts("cp: " + a[1] + ": no such file\n");
    exit(1);
};
ulib.unlink(a[2]);
let fd = ulib.open(a[2], ulib.O_CREATE);
if (fd < 0) {
    puts("cp: cannot create " + a[2] + "\n");
    exit(1);
};
let w = ulib.write_bytes(fd, d!);
ulib.close(fd);
if (w < 0) {
    puts("cp: write failed (the disk is full?)\n");
    exit(1);
};
