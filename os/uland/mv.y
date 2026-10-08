// mv old new -- rename a file.
import ulib;
let a = argv();
if (len(a) != 3) {
    puts("usage: mv <old> <new>\n");
    exit(1);
};
if (ulib.rename(a[1], a[2]) < 0) {
    puts("mv: cannot rename " + a[1] + "\n");
    exit(1);
};
