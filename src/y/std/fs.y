// std/fs.y -- the file system: whole files, directories, paths and file
// descriptors, over raw Linux x86_64 syscalls (no libc). `import fs;` and
// call through the namespace: `fs.read_file("a.txt")`.
//
// Whole files read and write as a str (text) or a [byte] (anything); a
// read gives none when the file cannot be read, a write false when it
// cannot be written. Paths are relative to the working directory. A mode
// is the usual octal permission number, written as one (0o644, 0o755);
// -1 leaves a new file at 0o644 minus the umask.
//
// fds: open_file(path, how) takes a mode string as most languages do --
// "r" read, "w" write (create, truncate), "a" append (create), "x" create
// a file that must not exist yet; "+" adds the other direction ("r+",
// "w+", "a+") -- and gives an fd (-1 when it fails), which read_all,
// read_some, write_text, write_data, seek and close_file take.

// openat's dirfd for a path relative to the working directory.
def fs_at_cwd() -> long { -100 };

// The flags of an openat for mode string `how` (-1 for an unknown one).
def open_flags(how: str) -> long {
    let plus = how.ends_with("+");
    let base = how;
    if (plus) { base = how[0:len(how) - 1]; 0; }
    let rw = 1;
    if (plus) { rw = 2; 0; }
    if (base == "r") { if (plus) { 2 } else { 0 } }
    else if (base == "w") { rw + 64 + 512 }
    else if (base == "a") { rw + 64 + 1024 }
    else if (base == "x") { rw + 64 + 128 }
    else { -1 }
};

// ── fds ──────────────────────────────────────────────────────────────────

// Open `path` as `how` says (see the top); a file it creates gets `mode`.
// The fd, or -1.
def open_file(path: str, how: str, mode: long = 0o644) -> long {
    let fl = open_flags(how);
    let m = mode;
    if (m < 0) { m = 0o644; }
    if (fl < 0) { -1 } else {
        let fd = os_call("y_os_openat", fs_at_cwd(), path, len(path), fl + 524288, m);
        if (fd < 0) { -1 } else { fd }
    }
};

def close_file(fd: long) -> bool { os_call("y_os_close", fd) == 0 };

// Up to n bytes from fd, at most 65536 in one call ([] at the end, or on
// an error).
def read_some(fd: long, n: long) -> [byte] {
    let out: [byte] = [];
    let m = n;
    if (m > 65536) { m = 65536; }
    if (m > 0) {
        let buf: [byte; 65536] = [0; 65536];
        let k = os_call("y_os_read", fd, &buf[0], m);
        if (k > 0) { out = buf[0:k]; }
    }
    out
};

// Everything left in fd.
def read_all_bytes(fd: long) -> [byte] {
    let out: [byte] = [];
    let chunk: [byte; 65536] = [0; 65536];
    let go = true;
    while (go) {
        let k = os_call("y_os_read", fd, &chunk[0], 65536);
        if (k <= 0) { go = false; } else { out += chunk[0:k]; };
    };
    out
};

def read_all(fd: long) -> str { from_bytes(read_all_bytes(fd)) };

// All of b to fd (true when every byte went).
def write_data(fd: long, b: [byte]) -> bool {
    let total = len(b);
    let off = 0;
    let ok = true;
    while (ok && off < total) {
        let w = os_call("y_os_write", fd, &b[off], total - off);
        if (w <= 0) { ok = false; } else { off = off + w; };
    };
    ok
};

// All of s to fd: straight from the string, the rest (after a short
// write) through write_data.
def write_text(fd: long, s: str) -> bool {
    let n = len(s);
    let w = os_call("y_os_write", fd, s, n);
    if (w == n) { true } else if (w < 0) { false } else { write_data(fd, bytes(s)[w:]) }
};

// Move fd's position: from the start (whence 0), the current position (1)
// or the end (2). The new position, or -1.
def seek(fd: long, off: long, whence: long) -> long {
    let p = os_call("y_os_lseek", fd, off, whence);
    if (p < 0) { -1 } else { p }
};

// ── whole files ──────────────────────────────────────────────────────────

def read_bytes(path: str) -> [byte]? {
    // A directory opens for reading, and read(2) refuses one with EISDIR --
    // which a read loop sees only as end-of-file. So read_file("some/dir")
    // answered some(""), and `ycc <a dir>` compiled that nothing into an
    // empty executable. is_dir is one stat of the same path (newfstatat).
    if (is_dir(path)) { none } else {
        let fd = open_file(path, "r");
        if (fd < 0) { none } else {
            let b = read_all_bytes(fd);
            close_file(fd);
            some(b)
        }
    }
};

def read_file(path: str) -> str? {
    let b = read_bytes(path);
    if (b == none) { none } else { some(from_bytes(b!)) }
};

// The lines of a text file, without their newlines.
def read_lines(path: str) -> [str]? {
    let s = read_file(path);
    if (s == none) { none } else { some(s!.lines()) }
};

// Set the permissions of path (mode -1: leave them).
def set_mode(path: str, mode: long) -> bool {
    if (mode < 0) { true } else { syscall(268, fs_at_cwd(), path, mode, 0) == 0 }
};

// The end of a whole-file write that went `ok`: close fd, then (mode >= 0)
// set the permissions.
def end_write(path: str, fd: long, ok: bool, mode: long) -> bool {
    close_file(fd) && ok && set_mode(path, mode)
};

// Create or truncate path and write s / b; then, mode >= 0, set its
// permissions.
def write_file(path: str, s: str, mode: long = -1) -> bool {
    let fd = open_file(path, "w");
    fd >= 0 && end_write(path, fd, write_text(fd, s), mode)
};

def write_bytes(path: str, b: [byte], mode: long = -1) -> bool {
    let fd = open_file(path, "w");
    fd >= 0 && end_write(path, fd, write_data(fd, b), mode)
};

// Add s / b at the end of path (created when missing).
def append_file(path: str, s: str) -> bool {
    let fd = open_file(path, "a");
    fd >= 0 && end_write(path, fd, write_text(fd, s), -1)
};

def append_bytes(path: str, b: [byte]) -> bool {
    let fd = open_file(path, "a");
    fd >= 0 && end_write(path, fd, write_data(fd, b), -1)
};

def copy_file(from: str, to: str) -> bool {
    let b = read_bytes(from);
    if (b == none) { false } else { write_bytes(to, b!) }
};

// ── paths ────────────────────────────────────────────────────────────────

// The st_mode of path by newfstatat: -1 when there is no such path. flags
// 0 is stat, which follows a symlink; 256 (AT_SYMLINK_NOFOLLOW) is lstat,
// which does not.
def mode_of(path: str, flags: long) -> long {
    let st: [long; 18] = [0; 18];
    if (os_call("y_os_stat", fs_at_cwd(), path, len(path), &st[0], flags) != 0) { -1 } else { st[3] & 4294967295 }
};

// The st_mode of path (stat follows a symlink), -1 when there is no such
// path.
def path_mode(path: str) -> long { mode_of(path, 0) };

// The same for path's last component itself, so a symlink's mode is S_IFL
// whatever it names.
def path_mode_itself(path: str) -> long { mode_of(path, 256) };

def exists(path: str) -> bool { path_mode(path) >= 0 };
def is_file(path: str) -> bool { (path_mode(path) & 61440) == 32768 };
def is_dir(path: str) -> bool { (path_mode(path) & 61440) == 16384 };
// A directory itself: a symlink to one is not.
def is_dir_itself(path: str) -> bool { (path_mode_itself(path) & 61440) == 16384 };

// The size of path in bytes.
def file_size(path: str) -> long? {
    let st: [long; 18] = [0; 18];
    if (os_call("y_os_stat", fs_at_cwd(), path, len(path), &st[0], 0) != 0) { none } else { some(st[6]) }
};

def rename(from: str, to: str) -> bool {
    os_call("y_os_rename", from, len(from), to, len(to)) == 0
};
def remove_file(path: str) -> bool { os_call("y_os_unlink", path, len(path), 0) == 0 };
// An empty directory.
def remove_dir(path: str) -> bool { os_call("y_os_unlink", path, len(path), 1) == 0 };

// path and everything in it. A symlink is unlinked, never followed: what
// it names is not this path's to delete (and rm -rf, which decides
// "directory" with lstat too, takes the link and leaves the target). A
// trailing slash is a different path -- resolution makes "link/" name the
// target's contents, and rm -rf empties it there too.
def remove_all(path: str) -> bool {
    if (is_dir_itself(path)) {
        let names = list_dir(path);
        let ok = names != none;
        if (ok) {
            foreach (n in names!) {
                if (!remove_all(path + "/" + n)) { ok = false; }
            };
        }
        ok && remove_dir(path)
    } else { remove_file(path) }
};

def make_dir(path: str, mode: long = 0o755) -> bool { os_call("y_os_mkdir", path, len(path), mode) == 0 };

// path and every directory above it that is missing (true when path is a
// directory already).
def make_dirs(path: str, mode: long = 0o755) -> bool {
    if (is_dir(path)) { true }
    else {
        let cut = path.last_index_of("/");
        let up = true;
        if (cut > 0) { up = make_dirs(path[0:cut], mode); }
        up && (make_dir(path, mode) || is_dir(path))
    }
};

// The names in directory path (without "." and ".."), sorted.
def list_dir(path: str) -> [str]? {
    let fd = syscall(257, fs_at_cwd(), path, 65536 + 524288, 0);
    if (fd < 0) { none } else {
        let names: [str] = [];
        let buf: [byte; 32768] = [0; 32768];
        let go = true;
        while (go) {
            let k = syscall(217, fd, &buf[0], 32768);
            if (k <= 0) { go = false; } else {
                let off = 0;
                while (off < k) {
                    let reclen = buf[off + 16] + 256 * buf[off + 17];
                    let e = off + 19;
                    while (buf[e] != 0) { e = e + 1; };
                    let name = from_bytes(buf[off + 19:e]);
                    if (name != "." && name != "..") { names += name; }
                    off = off + reclen;
                };
            };
        };
        close_file(fd);
        some(sort_names(names))
    }
};

// xs sorted (a merge sort).
def sort_names(xs: [str]) -> [str] {
    if (len(xs) < 2) { xs } else {
        let mid = len(xs) / 2;
        let a = sort_names(xs[0:mid]);
        let b = sort_names(xs[mid:]);
        let out: [str] = [];
        let i = 0;
        let j = 0;
        while (i < len(a) || j < len(b)) {
            if (j >= len(b) || (i < len(a) && a[i] <= b[j])) { out += a[i]; i = i + 1; }
            else { out += b[j]; j = j + 1; };
        };
        out
    }
};

// The working directory ("" when it cannot be read).
def cwd() -> str {
    let buf: [byte; 4096] = [0; 4096];
    let n = os_call("y_os_getcwd", &buf[0], 4096);
    if (n <= 0) { "" } else { from_bytes(buf[0:n - 1]) }
};

def chdir(path: str) -> bool { os_call("y_os_chdir", path, len(path)) == 0 };

export { open_file, close_file, read_some, read_all, read_all_bytes, write_text, write_data, seek, read_file, read_bytes, read_lines, write_file, write_bytes, append_file, append_bytes, copy_file, set_mode, exists, is_file, is_dir, file_size, rename, remove_file, remove_dir, remove_all, make_dir, make_dirs, list_dir, cwd, chdir };
