// ulib -- the userland's thin layer over the kernel's Linux-ABI syscalls.
// Every program in os/uland imports it. A path or argument crosses the syscall
// boundary as NUL-terminated bytes (a Y str is length-prefixed, so its first
// byte is a count, not a character).

const AT_FDCWD = -100;
// write-only | create: what a real Linux needs for a new file (the kernel ignores the mode)
const O_CREATE = 65;
const O_RDONLY = 0;
const O_WRONLY = 1;
const O_CREAT = 64;
const O_TRUNC = 512;
const O_APPEND = 1024;
const O_DIRECTORY = 65536;
const AT_REMOVEDIR = 512;
const WNOHANG = 1;
const S_IFMT = 61440;
const S_IFDIR = 16384;
const S_IFREG = 32768;
const SYS_READ = 0;
const SYS_WRITE = 1;
const SYS_CLOSE = 3;
const SYS_LSEEK = 8;
const SYS_IOCTL = 16;
const SYS_PIPE = 22;
const SYS_DUP = 32;
const SYS_DUP2 = 33;
const SYS_NANOSLEEP = 35;
const SYS_GETPID = 39;
const SYS_FORK = 57;
const SYS_EXECVE = 59;
const SYS_WAIT4 = 61;
const SYS_KILL = 62;
const SYS_UNAME = 63;
const SYS_GETCWD = 79;
const SYS_CHDIR = 80;
const SYS_SETPGID = 109;
const SYS_GETPGID = 121;
const SYS_REBOOT = 169;
const SYS_GETDENTS64 = 217;
const SYS_OPENAT = 257;
const SYS_MKDIRAT = 258;
const SYS_NEWFSTATAT = 262;
const SYS_UNLINKAT = 263;
const SYS_RENAMEAT = 264;
const TCGETS = 21505;
const TIOCSPGRP = 21530;

/** `s` as NUL-terminated bytes. */
def cstr(s: str) -> [byte] {
    let b: [byte] = [];
    let i = 0;
    while (i < len(s)) { b += s[i] & 255; i = i + 1; };
    b += 0;
    b
};

/** open(path, flags) -> fd, or a negative errno. */
def open(path: str, flags: long) -> long {
    let p = cstr(path);
    syscall(SYS_OPENAT, AT_FDCWD, ptr_addr(&p[0]), flags, 420)
};

def close(fd: long) -> long {
    syscall(SYS_CLOSE, fd, 0, 0)
};

/** Read up to `n` bytes from `fd`: the bytes, empty at end of file or on an error. */
def read(fd: long, n: long) -> [byte] {
    let buf: [byte] = [];
    let k = 0;
    while (k < n) { buf += 0; k = k + 1; };
    let r = syscall(SYS_READ, fd, ptr_addr(&buf[0]), n);
    if (r <= 0) {
        let none_b: [byte] = [];
        none_b
    } else {
        buf[0:r]
    }
};

/** Everything `fd` yields up to end of file. */
def read_fd(fd: long) -> [byte] {
    let out: [byte] = [];
    let more = true;
    while (more) {
        let chunk = read(fd, 4096);
        if (len(chunk) == 0) { more = false; } else { out += chunk; };
    };
    out
};

/** The whole file as bytes, or none. */
def read_all(path: str) -> [byte]? {
    let fd = open(path, 0);
    if (fd < 0) { return none; };
    let out = read_fd(fd);
    close(fd);
    some(out)
};

/** Write all of `b` to `fd`; the count written, or a negative errno. */
def write_bytes(fd: long, b: [byte]) -> long {
    if (len(b) == 0) { return 0; };
    let done = 0;
    while (done < len(b)) {
        let rest = b[done:len(b)];
        let r = syscall(SYS_WRITE, fd, ptr_addr(&rest[0]), len(rest));
        if (r <= 0) { return if (done > 0) { done } else { r }; };
        done = done + r;
    };
    done
};

def write(fd: long, s: str) -> long {
    write_bytes(fd, cstr(s)[0:len(s)])
};

/** Little-endian `n` bytes of `b` at `off`. */
def le(b: [byte], off: long, n: long) -> long {
    let v = 0;
    let i = n - 1;
    while (i >= 0) { v = (v << 8) | b[off + i]; i = i - 1; };
    v
};

/** An entry of a directory: its name and d_type (4 directory, 8 file, 0 unknown). */
type Dent = { name: str, kind: long };

/** The entries of directory `path` (with . and .. when the kernel lists them), or none. */
def read_dir(path: str) -> [Dent]? {
    let fd = open(path, O_DIRECTORY);
    if (fd < 0) { return none; };
    let ents: [Dent] = [];
    let buf: [byte] = [];
    let k = 0;
    while (k < 4096) { buf += 0; k = k + 1; };
    let n = 1;
    while (n > 0) {
        n = syscall(SYS_GETDENTS64, fd, ptr_addr(&buf[0]), 4096);
        let o = 0;
        while (n > 0 && o < n) {
            let reclen = le(buf, o + 16, 2);
            let nm: [byte] = [];
            let c = o + 19;
            while (buf[c] != 0) { nm += buf[c]; c = c + 1; };
            let e: Dent = { name: from_bytes(nm), kind: buf[o + 18] };
            ents += e;
            o = o + reclen;
        };
    };
    close(fd);
    some(ents)
};

/** The names in directory `path`, or none if it cannot be opened. */
def list_dir(path: str) -> [str]? {
    let ents = read_dir(path);
    if (ents == none) { return none; };
    let names: [str] = [];
    ents!.foreach((e) => { names += e.name; });
    some(names)
};

/** What stat reports: mode, size, inode, link count. */
type Stat = { mode: long, size: long, ino: long, nlink: long };

/** stat(path): the fields, or none when there is no such path. */
def stat(path: str) -> Stat? {
    let p = cstr(path);
    let sb: [byte] = [];
    let k = 0;
    while (k < 144) { sb += 0; k = k + 1; };
    if (syscall(SYS_NEWFSTATAT, AT_FDCWD, ptr_addr(&p[0]), ptr_addr(&sb[0]), 0) < 0) { return none; };
    let s: Stat = { mode: le(sb, 24, 4), size: le(sb, 48, 8), ino: le(sb, 8, 8), nlink: le(sb, 16, 8) };
    some(s)
};

def exists(path: str) -> bool {
    !(stat(path) == none)
};

def is_dir(path: str) -> bool {
    let s = stat(path);
    if (s == none) { false } else { (s!.mode & S_IFMT) == S_IFDIR }
};

def unlink(path: str) -> long {
    let p = cstr(path);
    syscall(SYS_UNLINKAT, AT_FDCWD, ptr_addr(&p[0]), 0)
};

def rmdir(path: str) -> long {
    let p = cstr(path);
    syscall(SYS_UNLINKAT, AT_FDCWD, ptr_addr(&p[0]), AT_REMOVEDIR)
};

def mkdir(path: str) -> long {
    let p = cstr(path);
    syscall(SYS_MKDIRAT, AT_FDCWD, ptr_addr(&p[0]), 493)
};

def chdir(path: str) -> long {
    let p = cstr(path);
    syscall(SYS_CHDIR, ptr_addr(&p[0]), 0, 0)
};

/** The working directory, or "" when the kernel cannot say. */
def getcwd() -> str {
    let buf: [byte] = [];
    let k = 0;
    while (k < 512) { buf += 0; k = k + 1; };
    let r = syscall(SYS_GETCWD, ptr_addr(&buf[0]), 512, 0);
    if (r <= 0) { return ""; };
    let nm: [byte] = [];
    let c = 0;
    while (c < 512 && buf[c] != 0) { nm += buf[c]; c = c + 1; };
    from_bytes(nm)
};

def rename(old: str, new: str) -> long {
    let a = cstr(old);
    let b = cstr(new);
    syscall(SYS_RENAMEAT, AT_FDCWD, ptr_addr(&a[0]), AT_FDCWD, ptr_addr(&b[0]))
};

def dup(fd: long) -> long {
    syscall(SYS_DUP, fd, 0, 0)
};

def dup2(old: long, new: long) -> long {
    syscall(SYS_DUP2, old, new, 0)
};

/** pipe(): [read end, write end], or [-1, -1]. */
def pipe() -> [long] {
    let p: [long; 1] = [0; 1];
    if (syscall(SYS_PIPE, ptr_addr(&p[0]), 0, 0) < 0) { return [-1, -1]; };
    [p[0] & 4294967295, p[0] >> 32]
};

def fork() -> long {
    syscall(SYS_FORK, 0, 0, 0)
};

def getpid() -> long {
    syscall(SYS_GETPID, 0, 0, 0)
};

def setpgid(pid: long, pgid: long) -> long {
    syscall(SYS_SETPGID, pid, pgid, 0)
};

def getpgid(pid: long) -> long {
    syscall(SYS_GETPGID, pid, 0, 0)
};

def kill(pid: long, sig: long) -> long {
    syscall(SYS_KILL, pid, sig, 0)
};

/** Is fd a terminal, and if so is it in canonical mode (the kernel edits the line)?
0 not a terminal, 1 a raw terminal, 2 a canonical one. */
def tty_mode(fd: long) -> long {
    let t: [byte] = [];
    let k = 0;
    while (k < 64) { t += 0; k = k + 1; };
    if (syscall(SYS_IOCTL, fd, TCGETS, ptr_addr(&t[0])) < 0) { return 0; };
    if ((le(t, 12, 4) & 2) != 0) { 2 } else { 1 }
};

/** The terminal's termios (a Linux `struct termios`: four u32 flag words, c_line, c_cc[19]), or [] when fd is no terminal. */
def tty_get(fd: long) -> [byte] {
    let t: [byte] = [];
    let k = 0;
    while (k < 64) { t += 0; k = k + 1; };
    if (syscall(SYS_IOCTL, fd, TCGETS, ptr_addr(&t[0])) < 0) { return []; };
    t
};

/** Install a termios from tty_get (TCSETS). */
def tty_set(fd: long, t: [byte]) -> long {
    if (len(t) < 36) { return -1; };
    syscall(SYS_IOCTL, fd, 21506, ptr_addr(&t[0]))
};

/** Make `pgid` the terminal's foreground process group. */
def set_foreground(fd: long, pgid: long) -> long {
    let g: [long; 1] = [pgid];
    syscall(SYS_IOCTL, fd, TIOCSPGRP, ptr_addr(&g[0]))
};

/** Wait for `pid` (-1: any child) with `opts`; its pid (0 with WNOHANG and none ready,
or a negative errno) and in st[0] the raw wait status. */
def wait_pid(pid: long, st: [long; 1], opts: long) -> long {
    st[0] = 0;
    syscall(SYS_WAIT4, pid, ptr_addr(&st[0]), opts, 0)
};

/** Wait for any child; its pid (or a negative errno). */
def wait_child() -> long {
    syscall(SYS_WAIT4, -1, 0, 0, 0)
};

/** A wait status as the shell reports it: the exit code, or 128 + the signal. */
def exit_code(status: long) -> long {
    let sig = status & 127;
    if (sig == 0) { (status >> 8) & 255 } else { 128 + sig }
};

/** uname(2): sysname, nodename, release, version, machine ("yunix" and so on if the
kernel cannot say). */
def uname() -> [str] {
    let buf: [byte] = [];
    let k = 0;
    while (k < 390) { buf += 0; k = k + 1; };
    if (syscall(SYS_UNAME, ptr_addr(&buf[0]), 0, 0) < 0) {
        return ["yunix", "yunix", "0", "0", "x86_64"];
    };
    let out: [str] = [];
    let f = 0;
    while (f < 5) {
        let nm: [byte] = [];
        let c = f * 65;
        while (buf[c] != 0) { nm += buf[c]; c = c + 1; };
        out += from_bytes(nm);
        f = f + 1;
    };
    out
};

/** Sleep `ms` milliseconds. */
def sleep_ms(ms: long) -> void {
    let ts: [long; 2] = [ms / 1000, (ms % 1000) * 1000000];
    syscall(SYS_NANOSLEEP, ptr_addr(&ts[0]), 0, 0);
};

/** The environment this process started with, or the system's defaults when the
kernel has no /proc/self/environ to read. */
def environ() -> [str] {
    let d = read_all("/proc/self/environ");
    let out: [str] = [];
    if (!(d == none)) {
        let cur: [byte] = [];
        d!.foreach((c) => {
            if (c == 0) {
                if (len(cur) > 0) { out += from_bytes(cur); };
                cur = [];
            } else { cur += c; };
        });
    };
    if (len(out) == 0) {
        out = ["HOME=/home/user", "USER=user", "PATH=/bin", "TERM=xterm-256color", "XDG_RUNTIME_DIR=/run/user/1000"];
    };
    out
};

/** Replace this process with `path`, `args` (args[0] is the program's own name)
and the environment `env` ("NAME=value" strings). Returns only on failure. */
def exec(path: str, args: [str], env: [str]) -> long {
    let p = cstr(path);
    let bufs: [[byte]] = [];
    let ptrs: [long] = [];
    let eptrs: [long] = [];
    args.foreach((a) => { bufs += cstr(a); });
    env.foreach((a) => { bufs += cstr(a); });
    let i = 0;
    while (i < len(bufs)) {
        if (i < len(args)) { ptrs += ptr_addr(&bufs[i][0]); } else { eptrs += ptr_addr(&bufs[i][0]); };
        i = i + 1;
    };
    ptrs += 0;
    eptrs += 0;
    syscall(SYS_EXECVE, ptr_addr(&p[0]), ptr_addr(&ptrs[0]), ptr_addr(&eptrs[0]))
};

/** Halt the machine (the kernel's reboot(2)). */
def halt() -> void {
    syscall(SYS_REBOOT, 0, 0, 0);
};
