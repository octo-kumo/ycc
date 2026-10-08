// write file words... -- make a file whose contents are the words and a newline.
// (There is no shell redirection yet; this is `echo words > file`.)
import ulib;
let a = argv();
if (len(a) < 3) {
    puts("usage: write <file> <words>...\n");
    exit(1);
};
let text = "";
let i = 2;
while (i < len(a)) {
    if (i > 2) { text += " "; };
    text += a[i];
    i = i + 1;
};
ulib.unlink(a[1]);
let fd = ulib.open(a[1], ulib.O_CREATE);
if (fd < 0) {
    puts("write: cannot create " + a[1] + "\n");
    exit(1);
};
ulib.write(fd, text + "\n");
ulib.close(fd);
