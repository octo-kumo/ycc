// ls [dir] -- the names in a directory (the root by default), one per line.
import ulib;
let a = argv();
let dir = "/";
if (len(a) > 1) { dir = a[1]; };
let names = ulib.list_dir(dir);
if (names == none) {
    puts("ls: " + dir + ": no such directory\n");
    exit(1);
} else {
    names!.foreach((n) => { puts(n + "\n"); });
};
