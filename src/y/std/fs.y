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

// The buffer `list_dir` reads a directory's names into, and the size it is
// grown to on the first call. It is module state on purpose: the heap is an
// arena that never frees, so allocating it per call cost 32 KiB for every
// directory of every walk -- measured, on a 30-name directory, 43 592 B of
// arena a call, and 6.56 MB a walk over a 201-directory tree
// (examples/SUGGESTIONS.md 22). One buffer for the process is the same trick
// `examples/indexer`'s read_dirs uses. It is built on FIRST USE rather than at
// startup, because a program that imports fs to read one file must not pay
// 32 KiB of arena for a directory listing it never makes (an eager buffer
// costs every fs-importing program 32 864 B). The `y_` prefix keeps it out of
// the module's surface, and it is NOT reentrant: two threads that call
// list_dir at the same time share it.
const FS_LISTBUF = 32768;
let y_fs_listbuf: [byte] = [];

// list_dir's own sort now lives in std/sort.y.
import sort;

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
    while (true) {
        let k = os_call("y_os_read", fd, &chunk[0], 65536);
        if (k <= 0) { break; } else { out += chunk[0:k]; };
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
        if (w <= 0) { ok = false; } else { off += w; };
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
    if let some(b) = read_bytes(path) {
        some(from_bytes(b))
    } else {
        none
    }
};

// The lines of a text file, without their newlines.
def read_lines(path: str) -> [str]? {
    if let some(s) = read_file(path) {
        some(s.lines())
    } else {
        none
    }
};

// Set the permissions of path (mode -1: leave them).
def set_mode(path: str, mode: long) -> bool {
    if (mode < 0) { true } else { os_call("y_os_set_mode", path, len(path), mode) == 0 }
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
    if let some(b) = read_bytes(from) {
        write_bytes(to, b)
    } else {
        false
    }
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
def is_file(path: str) -> bool {(path_mode(path) & 61440) == 32768 };
def is_dir(path: str) -> bool {(path_mode(path) & 61440) == 16384 };
// A directory itself: a symlink to one is not.
def is_dir_itself(path: str) -> bool {(path_mode_itself(path) & 61440) == 16384 };

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
            foreach (n in names !) {
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
    let fd = os_call("y_os_openat", fs_at_cwd(), path, len(path), 65536 + 524288, 0);
    if (fd < 0) { none } else {
        let names: [str] = [];
        // 32760, not 32768: y_os_list writes each name with an 8-byte store
        // and a name may end at the last byte it was given, so the call gets
        // seven bytes less than the array to keep that store inside it.
        if (len(y_fs_listbuf) < FS_LISTBUF) {
            let b: [byte] = [];
            for z in 0..FS_LISTBUF { b += 0; };
            y_fs_listbuf = b;
        };
        let buf: [byte] = y_fs_listbuf;
        let go = true;
        let first = 1;
        while (go) {
            let k = os_call("y_os_list", fd, &buf[0], 32760, first);
            first = 0;
            if (k <= 0) { go = false; } else {
                // NUL-separated names, whatever the kernel's own record shape
                // is -- that is y_os_list's contract on both targets.
                let off = 0;
                while (off < k) {
                    let e = off;
                    while (buf[e] != 0) { e = e + 1; };
                    names += from_bytes(buf[off:e]);
                    off = e + 1;
                };
            };
        };
        close_file(fd);
        // list_dir sorts its names, and std/sort.y is where that sort lives now
        // (it had one copy here of its own).
        some(sort.sort_str(names))
    }
};

// The working directory ("" when it cannot be read).
def cwd() -> str {
    let buf: [byte; 4096] = [0; 4096];
    let n = os_call("y_os_getcwd", &buf[0], 4096);
    if (n <= 0) { "" } else { from_bytes(buf[0:n - 1]) }
};

/** The value of environment variable `name`, or `none` if it is unset. Read from
/proc/self/environ, so it is the environment the process started with (there
is no setenv) and, with no /proc, `none` -- on Windows too. */
def getenv(name: str) -> str? {
    let all = read_file("/proc/self/environ");
    if (all == none) { return none; };
    let pre = name + "=";
    let n = len(pre);
    foreach (e in split(all!, chr(0))) {
        if (len(e) >= n && e[0:n] == pre) { return some(e[n:]); };
    };
    none
};

def chdir(path: str) -> bool { os_call("y_os_chdir", path, len(path)) == 0 };

// ── paths ───────────────────────────────────────────────────────────────
// String work on a path, touching no file: the other half of this module is
// all syscalls, and every program that walks a tree needs these first.
// Trailing slashes do not count (POSIX: "/a/b/" is "/a/b"), `.` and `..` are
// NOT resolved, and a path that is only a root stays a root.

// "/a/b/c" -> "/a/b", "a" -> ".", "/" -> "/", "" -> "."
def path_dirname(p: str) -> str {
    let q = p;
    while (len(q) > 1 && q[len(q) - 1:len(q)] == "/") { q = q[0:len(q) - 1]; };
    if (q == "/" || q == "") { if (q == "") { "." } else { "/" } } else {
        let cut = last_index_of(q, "/");
        if (cut < 0) { "." }
        else if (cut == 0) { "/" }
        else { q[0:cut] }
    }
};

// "/a/b/c" -> "c", "a" -> "a", "/" -> "/", "" -> ""
def path_basename(p: str) -> str {
    let q = p;
    while (len(q) > 1 && q[len(q) - 1:len(q)] == "/") { q = q[0:len(q) - 1]; };
    if (q == "/" || q == "") { q } else {
        let cut = last_index_of(q, "/");
        if (cut < 0) { q } else { q[cut + 1:len(q)] }
    }
};

// The last ".name" of the base name, without the dot; "" when there is none.
// A leading dot is part of the name, not an extension: ".bashrc" has none.
def path_extension(p: str) -> str {
    let b = path_basename(p);
    let dot = last_index_of(b, ".");
    if (dot <= 0) { "" } else { b[dot + 1:len(b)] }
};

// The base name without its extension: "a.tar.gz" -> "a.tar".
def path_stem(p: str) -> str {
    let b = path_basename(p);
    let dot = last_index_of(b, ".");
    if (dot <= 0) { b } else { b[0:dot] }
};

// Two paths, one: an empty side is the other, and an absolute `b` replaces
// `a` outright (so path_join("a", "/b") is "/b"). Otherwise exactly one "/"
// goes between them. A relative path is left relative -- joining is not
// resolving, and the caller may want to see what it wrote.
def path_join(a: str, b: str) -> str {
    if (len(a) == 0) { b }
    else if (len(b) == 0) { a }
    else if (b[0:1] == "/") { b }
    else if (a[len(a) - 1:len(a)] == "/") { a + b }
    else { a + "/" + b }
};

export { open_file, close_file, read_some, read_all, read_all_bytes, write_text, write_data, seek, read_file, read_bytes, read_lines, write_file, write_bytes, append_file, append_bytes, copy_file, set_mode, exists, is_file, is_dir, file_size, rename, remove_file, remove_dir, remove_all, make_dir, make_dirs, list_dir, cwd, getenv, chdir, path_dirname, path_basename, path_extension, path_stem, path_join };
