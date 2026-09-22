// std/io.y -- file I/O and process control over raw Linux syscalls.
// Zero C code: every operation is the `syscall` compiler intrinsic.
// Syscall numbers here are Linux x86_64 (arch-owned; only this file changes
// per OS/arch). All sizes/counts are explicit longs -- no strlen yet
// (needs byte access; planned with stack arrays).
//
// open() uses openat(AT_FDCWD) like modern libc. fds: 0 stdin, 1 stdout.

def stdin_fd() -> long { 0 };
def stdout_fd() -> long { 1 };
def stderr_fd() -> long { 2 };

def SEEK_SET() -> long { 0 };

def O_RDONLY() -> long { 0 };
def O_WRONLY() -> long { 1 };
def O_RDWR() -> long { 2 };
def O_CREAT() -> long { 64 };
def O_TRUNC() -> long { 512 };

// open(path, flags, mode) -> fd or negative errno. Creates with `mode`
// (e.g. 420 = 0644) when O_CREAT is set.
def open(path: str, flags: long, mode: long) -> long {
    syscall(257, -100, path, flags, mode)
};

// chmod(path, mode) -> 0 or negative errno (fchmodat, no follow).
def chmod(path: str, mode: long) -> long {
    syscall(268, -100, path, mode)
};

def close(fd: long) -> long {
    syscall(3, fd)
};

// write(fd, buf, count) -> bytes written or negative errno.
// buf is a raw address (a `str` flows in implicitly -- it IS an address;
// `&buf` element addresses work for both array kinds).
def write(fd: long, buf: *long, count: long) -> long {
    syscall(1, fd, buf, count)
};

// write_str needs an explicit length (no strlen yet).
def write_str(fd: long, s: str, count: long) -> long {
    syscall(1, fd, s, count)
};

// write_data(fd, addr, n): write n bytes from address addr (raw ELF data
// for the self-hosted emit path -- replaces the octal-printf hack: data go
// straight through the write syscall, NULs included).
// Takes an explicit ADDRESS (a plain long): pointer arithmetic (`p + i`) is
// ordinary long math, so no `&x` address-of is needed anywhere in this
// module (the C parser cannot parse `&x`).
def write_data(fd: long, addr: long, n: long) -> long {
    let count = 0;
    let i = 0;
    while (i < n) {
        let w = syscall(1, fd, addr + i, 1);
        if (w != 1) {
            count = w;
            i = n;
        } else {
            count = count + 1;
            i = i + 1;
        };
    };
    count
};

// read(fd, buf, count) -> bytes read, 0 at EOF, negative errno on error.
// buf is a caller-owned stack array (&buf); count is in BYTES.
def read(fd: long, buf: *long, count: long) -> long {
    syscall(0, fd, buf, count)
};

def exit(code: long) -> long {
    syscall(60, code)
};

export { stdin_fd, stdout_fd, stderr_fd, SEEK_SET, O_RDONLY, O_WRONLY, O_RDWR, O_CREAT, O_TRUNC, open, close, read, write, write_str, write_data, chmod, exit };
