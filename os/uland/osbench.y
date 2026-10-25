// osbench [NAME...] -- time the kernel's hot paths: one line "name  microseconds  detail" each.
// Names: syscall file pipe fork exec heap tty sleep (default: all but tty, which floods the screen).
import ulib;

let sink = 0;

/** A block of `n` text bytes. */
def block(n: long) -> str {
    let s = "";
    while (len(s) < n) { s += "0123456789abcdef"; };
    s[0:n]
};

def report(name: str, t0: long, detail: str) -> void {
    puts(name + "  " + tostring(clock_us() - t0) + " us  " + detail + "\n");
};

def bench_syscall() -> void {
    let t0 = clock_us();
    let i = 0;
    while (i < 20000) { sink += ulib.getpid(); i += 1; };
    report("syscall", t0, "20000 getpid");
};

def bench_file() -> void {
    let blk = block(4096);
    let t0 = clock_us();
    let fd = ulib.open("/tmp/osbench.dat", ulib.O_WRONLY | ulib.O_CREAT | ulib.O_TRUNC);
    let i = 0;
    while (i < 256) { ulib.write(fd, blk); i += 1; };
    ulib.close(fd);
    report("file-write", t0, "1 MiB in 4 KiB writes");
    t0 = clock_us();
    let all = ulib.read_all("/tmp/osbench.dat");
    if (all != none) { sink += len(all!); };
    report("file-read", t0, "1 MiB");
    t0 = clock_us();
    i = 0;
    while (i < 200) {
        let p = "/tmp/osb" + tostring(i);
        let f = ulib.open(p, ulib.O_WRONLY | ulib.O_CREAT);
        ulib.close(f);
        i += 1;
    };
    i = 0;
    while (i < 200) { ulib.unlink("/tmp/osb" + tostring(i)); i += 1; };
    report("file-meta", t0, "200 create + unlink");
    t0 = clock_us();
    i = 0;
    while (i < 2000) { ulib.stat("/bin/ls"); i += 1; };
    report("stat", t0, "2000 stat /bin/ls");
    ulib.unlink("/tmp/osbench.dat");
};

def bench_pipe() -> void {
    let blk = block(4096);
    let p = ulib.pipe();
    let t0 = clock_us();
    let pid = ulib.fork();
    if (pid == 0) {
        ulib.close(p[1]);
        while (len(ulib.read(p[0], 4096)) > 0) { };
        exit(0);
    };
    ulib.close(p[0]);
    let i = 0;
    while (i < 256) { ulib.write(p[1], blk); i += 1; };
    ulib.close(p[1]);
    let st: [long; 1] = [0; 1];
    ulib.wait_pid(pid, st, 0);
    report("pipe", t0, "1 MiB through a pipe to a child");
};

def bench_fork() -> void {
    let st: [long; 1] = [0; 1];
    let t0 = clock_us();
    let i = 0;
    while (i < 200) {
        let pid = ulib.fork();
        if (pid == 0) { exit(0); };
        ulib.wait_pid(pid, st, 0);
        i += 1;
    };
    report("fork", t0, "200 fork + exit + wait");
};

def bench_exec() -> void {
    let st: [long; 1] = [0; 1];
    let t0 = clock_us();
    let i = 0;
    while (i < 50) {
        let pid = ulib.fork();
        if (pid == 0) {
            let z = ulib.open("/dev/null", ulib.O_WRONLY);
            ulib.dup2(z, 1);
            ulib.exec("/bin/uname", ["uname"], ulib.environ());
            exit(127);
        };
        ulib.wait_pid(pid, st, 0);
        i += 1;
    };
    report("exec", t0, "50 fork + exec /bin/uname + wait");
};

def bench_heap() -> void {
    let t0 = clock_us();
    let i = 0;
    while (i < 64) {
        let a: [long] = [];
        let j = 0;
        while (j < 131072) { a += j; j += 1; };
        sink += len(a);
        i += 1;
    };
    report("heap", t0, "64 x 1 MiB arrays grown by 131072 appends");
};

def bench_tty() -> void {
    let line = block(79) + "\n";
    let t0 = clock_us();
    let i = 0;
    while (i < 3000) { ulib.write(1, line); i += 1; };
    report("tty", t0, "3000 lines of 79 columns to the terminal");
};

def bench_sleep() -> void {
    let t0 = clock_us();
    let i = 0;
    while (i < 20) { ulib.sleep_ms(10); i += 1; };
    report("sleep", t0, "20 x 10 ms (ideal 200000)");
};

let a = argv();
let want: [str] = [];
let k = 1;
while (k < len(a)) { want += a[k]; k += 1; };
def wanted(n: str) -> bool {
    if (len(want) == 0) { return n != "tty"; };
    let i = 0;
    while (i < len(want)) { if (want[i] == n) { return true; }; i += 1; };
    false
};
if (wanted("syscall")) { bench_syscall(); };
if (wanted("file")) { bench_file(); };
if (wanted("pipe")) { bench_pipe(); };
if (wanted("fork")) { bench_fork(); };
if (wanted("exec")) { bench_exec(); };
if (wanted("heap")) { bench_heap(); };
if (wanted("tty")) { bench_tty(); };
if (wanted("sleep")) { bench_sleep(); };
