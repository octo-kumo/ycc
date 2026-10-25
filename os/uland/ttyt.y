// ttyt MODE -- exercises the console from the session driver's side.  Each mode
// prints "$ " when it wants the next line the driver types (the driver sends a
// line whenever the output ends in "$ ").
import ulib;

let tm: [byte; 40] = [0; 40];
let buf: [byte; 256] = [0; 256];
let orig: [byte; 40] = [0; 40];

def get() -> void { syscall(16, 0, 21505, ptr_addr(&tm[0])); };
def set() -> void { syscall(16, 0, 21506, ptr_addr(&tm[0])); };

def dump(n: long) -> void {
    let s = "[" + tostring(n) + "]";
    let i = 0;
    while (i < n) {
        s += " " + tostring(buf[i]);
        i = i + 1;
    };
    puts(s + "\n");
};

let a = argv();
let mode = a[1];
get();
let oi = 0;
while (oi < 40) { orig[oi] = tm[oi]; oi = oi + 1; };
if (mode == "canon") {
    tm[12] = 59;
    tm[13] = 138;
    tm[1] = tm[1] | 1;
    tm[17 + 6] = 1;
    set();
    // two canonical lines, then ^D at the start of a line
    puts("$ ");
    let n = syscall(0, 0, ptr_addr(&buf[0]), 100);
    dump(n);
    puts("$ ");
    n = syscall(0, 0, ptr_addr(&buf[0]), 3);
    dump(n);
    n = syscall(0, 0, ptr_addr(&buf[0]), 100);
    dump(n);
    puts("$ ");
    n = syscall(0, 0, ptr_addr(&buf[0]), 100);
    dump(n);
    n = syscall(0, 0, ptr_addr(&buf[0]), 100);
    dump(n);
    puts("$ ");
    n = syscall(0, 0, ptr_addr(&buf[0]), 100);
    dump(n);
    n = syscall(0, 0, ptr_addr(&buf[0]), 100);
    dump(n);
} else if (mode == "raw") {
    // raw, VMIN=1: bytes as typed
    tm[12] = tm[12] & 244;
    tm[1] = tm[1] & 254;
    tm[17 + 6] = 4;
    tm[17 + 5] = 0;
    set();
    puts("$ ");
    let n = syscall(0, 0, ptr_addr(&buf[0]), 100);
    dump(n);
} else if (mode == "poll0") {
    // VMIN=0: returns at once, nothing there
    tm[12] = tm[12] & 244;
    tm[17 + 6] = 0;
    tm[17 + 5] = 0;
    set();
    let n = syscall(0, 0, ptr_addr(&buf[0]), 100);
    dump(n);
    tm[17 + 6] = 0;
    tm[17 + 5] = 5;
    set();
    n = syscall(0, 0, ptr_addr(&buf[0]), 100);
    dump(n);
} else if (mode == "fionread") {
    tm[12] = tm[12] & 244;
    tm[17 + 6] = 1;
    set();
    puts("$ ");
    let n = syscall(0, 0, ptr_addr(&buf[0]), 1);
    let k: [long; 1] = [0 - 1; 1];
    syscall(16, 0, 21531, ptr_addr(&k[0]));
    puts("nread " + tostring(k[0] & 4294967295) + "\n");
    n = syscall(0, 0, ptr_addr(&buf[0]), 100);
    dump(n);
} else if (mode == "isig") {
    // ^C is a byte with ISIG off
    tm[12] = tm[12] & 244;
    tm[17 + 6] = 2;
    set();
    puts("$ ");
    let n = syscall(0, 0, ptr_addr(&buf[0]), 100);
    dump(n);
} else if (mode == "pgrp") {
    let g: [long; 1] = [0; 1];
    let r = syscall(16, 0, 21519, ptr_addr(&g[0]));
    puts("tiocgpgrp " + tostring(r) + " " + tostring(g[0] & 4294967295 > 0) + "\n");
    g[0] = 77;
    r = syscall(16, 0, 21520, ptr_addr(&g[0]));
    g[0] = 0;
    syscall(16, 0, 21519, ptr_addr(&g[0]));
    puts("tiocspgrp " + tostring(r) + " " + tostring(g[0] & 4294967295) + "\n");
};
syscall(16, 0, 21506, ptr_addr(&orig[0]));
