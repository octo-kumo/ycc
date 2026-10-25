// b1 -- helpers for the proc/fd test programs: raw Linux syscalls, nothing else.
const T_BUF = 4096;
let t_buf: [byte; 4096] = [0; 4096];
let t_pair: [long; 2] = [0; 2];
let t_st: [long; 2] = [0; 2];

def sc(nr: long, a: long, b: long, c: long, d: long) -> long { syscall(nr, a, b, c, d) };

def sc5(nr: long, a: long, b: long, c: long, d: long, e: long) -> long { syscall(nr, a, b, c, d, e) };

def fork() -> long { sc(57, 0, 0, 0, 0) };
def getpid() -> long { sc(39, 0, 0, 0, 0) };
def close(fd: long) -> long { sc(3, fd, 0, 0, 0) };
def dup(fd: long) -> long { sc(32, fd, 0, 0, 0) };
def dup2(a: long, b: long) -> long { sc(33, a, b, 0, 0) };
def kill(pid: long, sig: long) -> long { sc(62, pid, sig, 0, 0) };

/** pipe2(flags): [read fd, write fd] (negative errno in [0] on failure). */
def pipe2(flags: long) -> [long] {
    t_pair[0] = 0;
    let r = sc(293, ptr_addr(&t_pair[0]), flags, 0, 0);
    let w = t_pair[0] >> 32;
    let out: [long] = [t_pair[0] & 4294967295, w];
    if (r < 0) { out[0] = r; };
    out
};
def pipe() -> [long] { pipe2(0) };

/** Write all of `s` to `fd`: the syscall's answer. */
def wr(fd: long, s: str) -> long {
    if (len(s) == 0) { return 0; };
    let b = bytes(s);
    sc(1, fd, ptr_addr(&b[0]), len(b), 0)
};

/** One read of at most n (<= 4096) bytes: the text, or "" at EOF; the answer in t_st[0]. */
def rd(fd: long, n: long) -> str {
    let r = sc(0, fd, ptr_addr(&t_buf[0]), n, 0);
    t_st[0] = r;
    if (r <= 0) { return ""; };
    from_bytes(t_buf[0:r])
};

/** Read until EOF. */
def rd_all(fd: long) -> str {
    let out = "";
    let more = true;
    while (more) {
        let s = rd(fd, 1000);
        if (len(s) == 0) { more = false; } else { out += s; };
    };
    out
};

/** wait4(pid, WNOHANG?): the pid; the raw status in t_st[1]. */
def wait4(pid: long, opts: long) -> long {
    t_st[1] = 0;
    sc(61, pid, ptr_addr(&t_st[1]), opts, 0)
};
def wstatus() -> long { t_st[1] };

def check(name: str, ok: bool) -> void {
    if (ok) { puts("ok   " + name + "\n"); } else { puts("FAIL " + name + "\n"); };
};
def eq(name: str, got: long, want: long) -> void {
    if (got == want) { puts("ok   " + name + "\n"); } else { puts("FAIL " + name + ": got " + tostring(got) + " want " + tostring(want) + "\n"); };
};

/** Burn n cheap syscalls (a delay with no other dependency). */
def spin(n: long) -> void {
    let i = 0;
    while (i < n) { getpid(); i = i + 1; };
};
