// stat path... -- type, size, inode, links and mode of each path.
import ulib;
let a = argv();
if (len(a) < 2) { puts("usage: stat <path>...\n"); exit(1); };
let bad = 0;
let i = 1;
while (i < len(a)) {
    let s = ulib.stat(a[i]);
    if (s == none) {
        puts("stat: " + a[i] + ": no such file or directory\n");
        bad = 1;
    } else {
        let k = s!.mode & ulib.S_IFMT;
        let t = if (k == ulib.S_IFDIR) { "directory" } else if (k == ulib.S_IFREG) { "regular file" } else if (k == 8192) { "character device" } else if (k == 49152) { "socket" } else { "other" };
        puts("  File: " + a[i] + "\n");
        puts("  Type: " + t + "\n");
        puts("  Size: " + tostring(s!.size) + "\n");
        puts(" Inode: " + tostring(s!.ino) + "  Links: " + tostring(s!.nlink) + "\n");
        puts("  Mode: " + tostring((s!.mode & 4095) / 512 % 8) + tostring((s!.mode & 511) / 64) + tostring((s!.mode & 63) / 8) + tostring(s!.mode & 7) + "\n");
    };
    i = i + 1;
};
exit(bad);
