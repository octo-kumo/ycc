// cat [files...] -- write each file (standard input when none, or for `-`) to standard output.
import ulib;

def copy_fd(fd: long) -> void {
    let more = true;
    while (more) {
        let chunk = ulib.read(fd, 4096);
        if (len(chunk) == 0) { more = false; } else { ulib.write_bytes(1, chunk); };
    };
};

let a = argv();
let bad = 0;
if (len(a) < 2) { copy_fd(0); };
let i = 1;
while (i < len(a)) {
    if (a[i] == "-") {
        copy_fd(0);
    } else {
        let fd = ulib.open(a[i], 0);
        if (fd < 0) {
            puts("cat: " + a[i] + ": no such file\n");
            bad = 1;
        } else {
            copy_fd(fd);
            ulib.close(fd);
        };
    };
    i = i + 1;
};
exit(bad);
