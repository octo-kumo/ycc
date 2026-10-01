// std/io.y -- file I/O and process control over raw Linux syscalls.
// No C and no libc: every operation is the `syscall` intrinsic (native.y).
// Syscall numbers here are Linux x86_64 (arch-owned; only this file changes
// per OS/arch). Byte counts come from len(s) -- a `str` is
// {len, data..., NUL}, so it already carries its length -- and single bytes
// from s[i]; sizes and counts themselves are plain longs.
//
// open() uses openat(AT_FDCWD) like modern libc. fds: 0 stdin, 1 stdout,
// 2 stderr.

def stdin_fd() -> long { 0 };
def stdout_fd() -> long { 1 };
def stderr_fd() -> long { 2 };

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

// chmod(path, mode) -> 0 or negative errno. This is fchmodat(2) with its
// flags argument omitted, i.e. 0: like chmod(2) it FOLLOWS a symlink. Pass
// AT_SYMLINK_NOFOLLOW (256) as a fourth syscall argument to change that.
def chmod(path: str, mode: long) -> long {
    syscall(268, -100, path, mode)
};

def close(fd: long) -> long {
    syscall(3, fd)
};

// write(fd, buf, count) -> bytes written or negative errno.
// `buf` is a raw address, and a `str` flows into it implicitly: the
// `syscall` intrinsic hands the kernel the data pointer past the {len, ...}
// header. For an array buffer pass `&buf[0]` -- that is the element
// address, and it works for BOTH array kinds ([T; N] and [T]). `&buf` on
// its own is the address of the local slot, which holds the array header
// pointer, not its data (same for `read`).
def write(fd: long, buf: *long, count: long) -> long {
    syscall(1, fd, buf, count)
};

// write_str(fd, s, count): the same syscall as write, spelled for a `str`.
// The length is passed even though the string carries one -- len(s) is the
// idiom, and no NUL is written: `count` is the whole story.
def write_str(fd: long, s: str, count: long) -> long {
    syscall(1, fd, s, count)
};

// read(fd, buf, count) -> bytes read, 0 at EOF, negative errno on error.
// `count` is in BYTES and `buf` is the CALLER's buffer: a `[long; N]` array
// passed as `&buf[0]`, whose element address IS the data pointer (works for
// both array kinds). `&buf` alone is not it: that is the address of the
// local slot holding the array header, so the kernel writes over the frame
// and the array's own pointer is the first casualty.
// `buf: *long` also means a `[byte; N]` buffer does not typecheck here --
// `&b[0]` is a *byte -- so byte buffers need their own wrapper (or a
// widened parameter type).
def read(fd: long, buf: *long, count: long) -> long {
    syscall(0, fd, buf, count)
};

// This module deliberately has NO `exit` def. A def named `exit` shadows the
// `exit` intrinsic for the whole spliced program (rename.y rewrites every
// call named `exit` to it), so importing io would silently swap the
// intrinsic out from under every caller. Call the intrinsic `exit(code)`
// instead: it is available everywhere.
export { stdin_fd, stdout_fd, stderr_fd, O_RDONLY, O_WRONLY, O_RDWR, O_CREAT, O_TRUNC, open, close, read, write, write_str, chmod };
