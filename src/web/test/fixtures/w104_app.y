// W5 /app: files.bin is the read-only bundle, /proc and /dev stay synthetic.
import fs;
region {
    let t = fs.read_file("/app/hello.txt");
    if (t == none) { puts("missing app file\n"); } else { puts(unwrap(t)); };
    let st = fs.read_file("/proc/self/status");
    if (st != none) {
        if (index_of(unwrap(st), "Name:\t") >= 0) { puts("proc ok\n"); } else { puts("proc bad\n"); };
    };
    puts("devnull " + tostring(fs.exists("/dev/null")) + "\n");
    puts("cwd " + fs.cwd() + "\n");
};
