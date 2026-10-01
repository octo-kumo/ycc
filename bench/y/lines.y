// lines.y — reading stdin a line at a time: readline() over ~5 MB of
// short lines. The harness runs every benchmark with stdin at /dev/null,
// so the program writes its own input under /tmp, dup2()s it onto fd 0
// and unlinks it before reading.

def make_input(path: str, n: long) -> long {
    let parts: [str] = [];
    let i = 0;
    while (i < n) {
        parts += "line " + tostring(i) + " the quick brown fox jumps over the lazy dog";
        i = i + 1;
    };
    write_file(path, join(parts, "\n") + "\n");
    let pb = bytes(path);
    pb += 0;
    let fd = syscall(2, &pb[0], 0);
    syscall(33, fd, 0);
    syscall(3, fd);
    syscall(87, &pb[0]);
    n
};

def count_lines() -> { lines: long, bytes: long } {
    let n = 0;
    let total = 0;
    let line = readline();
    while (line != none) {
        n = n + 1;
        total = total + len(line!);
        line = readline();
    };
    { lines: n, bytes: total }
};

make_input("/tmp/_ybench_lines_" + tostring(syscall(39)) + ".txt", 100000);
let r = count_lines();
print(tostring(r.lines) + " lines, " + tostring(r.bytes) + " bytes");
