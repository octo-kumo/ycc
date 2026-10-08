// ulib -- the userland's thin layer over the kernel's Linux-ABI syscalls.
// Every program in os/uland imports it. A path or argument crosses the syscall
// boundary as NUL-terminated bytes (a Y str is length-prefixed, so its first
// byte is a count, not a character).

const AT_FDCWD = -100;
// write-only | create: what a real Linux needs for a new file (the kernel ignores the mode)
const O_CREATE = 65;
const SYS_READ = 0;
const SYS_WRITE = 1;
const SYS_CLOSE = 3;
const SYS_LSEEK = 8;
const SYS_FORK = 57;
const SYS_EXECVE = 59;
const SYS_WAIT4 = 61;
const SYS_GETDENTS64 = 217;
const SYS_OPENAT = 257;
const SYS_UNLINKAT = 263;
const SYS_RENAMEAT = 264;
const SYS_REBOOT = 169;

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

/** The whole file as bytes, or none. */
def read_all(path: str) -> [byte]? {
    let fd = open(path, 0);
    if (fd < 0) { return none; };
    let out: [byte] = [];
    let more = true;
    while (more) {
        let chunk = read(fd, 1024);
        if (len(chunk) == 0) { more = false; } else { out += chunk; };
    };
    close(fd);
    some(out)
};

/** Write all of `b` to `fd`; the count written, or a negative errno. */
def write_bytes(fd: long, b: [byte]) -> long {
    if (len(b) == 0) { return 0; };
    syscall(SYS_WRITE, fd, ptr_addr(&b[0]), len(b))
};

def write(fd: long, s: str) -> long {
    write_bytes(fd, cstr(s)[0:len(s)])
};

/** The names in directory `path`, or none if it cannot be opened. */
def list_dir(path: str) -> [str]? {
    let fd = open(path, 0);
    if (fd < 0) { return none; };
    let names: [str] = [];
    let buf: [byte] = [];
    let k = 0;
    while (k < 1024) { buf += 0; k = k + 1; };
    let n = 1;
    while (n > 0) {
        n = syscall(SYS_GETDENTS64, fd, ptr_addr(&buf[0]), 1024);
        let o = 0;
        while (n > 0 && o < n) {
            let reclen = buf[o + 16];
            let nm: [byte] = [];
            let c = o + 19;
            while (buf[c] != 0) { nm += buf[c]; c = c + 1; };
            names += from_bytes(nm);
            o = o + reclen;
        };
    };
    close(fd);
    some(names)
};

def unlink(path: str) -> long {
    let p = cstr(path);
    syscall(SYS_UNLINKAT, AT_FDCWD, ptr_addr(&p[0]), 0)
};

def rename(old: str, new: str) -> long {
    let a = cstr(old);
    let b = cstr(new);
    syscall(SYS_RENAMEAT, AT_FDCWD, ptr_addr(&a[0]), AT_FDCWD, ptr_addr(&b[0]))
};

def fork() -> long {
    syscall(SYS_FORK, 0, 0, 0)
};

/** Wait for any child; its pid (or a negative errno), the status in the `status` cell. */
def wait_child() -> long {
    syscall(SYS_WAIT4, -1, 0, 0, 0)
};

/** Replace this process with `path` and `args` (args[0] is the program's own name). */
def exec(path: str, args: [str]) -> long {
    let p = cstr(path);
    let bufs: [[byte]] = [];
    let ptrs: [long] = [];
    args.foreach((a) => { bufs += cstr(a); });
    let i = 0;
    while (i < len(bufs)) { ptrs += ptr_addr(&bufs[i][0]); i = i + 1; };
    ptrs += 0;
    syscall(SYS_EXECVE, ptr_addr(&p[0]), ptr_addr(&ptrs[0]), 0)
};

/** Halt the machine (the kernel's reboot(2)). */
def halt() -> void {
    syscall(SYS_REBOOT, 0, 0, 0);
};
