// vfs -- paths, inodes, files and directories over YFS (std/yfs.y).
//
// It implements: path walk relative to proc.cwd_ino(slot) or a dirfd
// (AT_FDCWD = -100), `.`/`..`; open/openat with O_CREAT/EXCL/TRUNC/APPEND/
// DIRECTORY installing FILE/DIR fds via fdt.fd_install (char-device nodes go
// through fdt.fdt_open_dev); stat/fstat/lstat/newfstatat/statx with st_mode for
// dir/reg/char/sock; mkdir(at)/rmdir/unlink(at)/rename(at/2) in any
// directory; getcwd/chdir/fchdir (proc.set_cwd); access/faccessat(2);
// truncate/ftruncate; readlink -> -EINVAL; chmod/fchmodat/utimensat accept (0);
// getdents64 for any directory; and the FILE/DIR ops below.
//
// The FILE/DIR handle (`obj`) is an index into this module's open-file table
// {ino, offset}: one per open file description (fdt shares it across
// fork/dup), released by file_close.
import kernel;
import kconst from "./kconst.y";
import yfs;
import fdt from "./fdt.y";
import proc from "./proc.y";


import fd;

// Node types, what node_type answers.
const T_REG = 1;
const T_DIR = 2;
const T_CHR = 3;
const T_SOCK = 4;

const VFS_PATH_MAX = 4096;
const VFS_NAME_MAX = 255;

// ── open file descriptions ──────────────────────────────────────────────
// obj = an index into these parallel arrays.  Free entries have of_ino == 0 and
// sit on the vfs_of_free stack (vfs_of_nfree deep).  A directory's of_off is the entry index it reads
// next (0 ".", 1 "..", then the entries); of_ce/of_cidx cache where entry
// `of_cidx` lives so a getdents walk is linear, and are dropped (of_gen) when the
// directory changes under them.
let of_ino: [long] = [];
let of_off: [long] = [];
let of_ce: [long] = [];
let of_cidx: [long] = [];
let of_gen: [long] = [];
let vfs_of_free: [long] = [];
let vfs_of_nfree: long = 0;
let vfs_dir_gen: long = 1;
// per inode: opens * 2 + 1 when it was unlinked while open (freed at the last close)
let ino_state: [long] = [];
// the last component and trailing-slash flag vfs_walk_parent left behind
let vfs_last: str = "";
let vfs_last_slash: long = 0;

def vfs_state(ino: long) -> long {
    while (len(ino_state) <= ino) { ino_state += 0; };
    ino_state[ino]
};

def vfs_set_state(ino: long, v: long) -> void {
    vfs_state(ino);
    ino_state[ino] = v;
};

/** Free `ino` now, or at its last close when something still has it open. */
def vfs_drop(ino: long) -> void {
    let st = vfs_state(ino);
    if (st >= 2) { vfs_set_state(ino, st | 1); } else { yfs.yfs_release(ino); vfs_set_state(ino, 0); };
};

// ── user memory ─────────────────────────────────────────────────────────
/** The NUL-terminated string at user VA `p` (up to PATH_MAX; "" when it is empty). */
def vfs_upath(p: long) -> str {
    let b: [byte] = [];
    let i = 0;
    while (i < VFS_PATH_MAX) {
        if (i == 0 || ((p + i) & 4095) == 0) {
            if (!kernel.user_ok(p + i, 1)) { break; };
        };
        let c = kernel.peek_va8(p + i);
        if (c == 0) { break; };
        b += c;
        i = i + 1;
    };
    from_bytes(b)
};

def vfs_put32(buf: long, off: long, v: long) -> void { kernel.poke_va32(buf + off, v & 4294967295); };
def vfs_put64(buf: long, off: long, v: long) -> void { kernel.poke_va64(buf + off, v); };

// ── path walking ────────────────────────────────────────────────────────
/** The directory a walk of `path` starts in: the root for an absolute path,
 *  else the working directory (AT_FDCWD) or the DIR fd `dirfd`; an errno otherwise. */
def vfs_start(slot: long, dirfd: long, path: str) -> long {
    if (len(path) > 0 && byte_at(path, 0) == 47) { return yfs.yfs_root; };
    if (dirfd == kconst.AT_FDCWD) { return proc.cwd_ino(slot); };
    let k = fdt.fd_kind(slot, dirfd);
    if (k < 0) { return kconst.EBADF; };
    if (k != kconst.DIR) { return kconst.ENOTDIR; };
    file_ino(fdt.fd_obj(slot, dirfd))
};

/** Walk the whole of `path` from directory `start`: the inode or an errno. */
def vfs_walk(start: long, path: str) -> long {
    let cur = start;
    let n = len(path);
    let i = 0;
    while (i < n) {
        while (i < n && byte_at(path, i) == 47) { i = i + 1; };
        if (i >= n) { break; };
        let j = i;
        while (j < n && byte_at(path, j) != 47) { j = j + 1; };
        if (j - i > VFS_NAME_MAX) { return kconst.ENAMETOOLONG; };
        if (yfs.yfs_type(cur) != yfs.YFS_DIR) { return kconst.ENOTDIR; };
        if (j - i == 1 && byte_at(path, i) == 46) {
            // "."
        } else if (j - i == 2 && byte_at(path, i) == 46 && byte_at(path, i + 1) == 46) {
            cur = yfs.yfs_parent(cur);
        } else {
            let nx = yfs.yfs_find_in(cur, path, i, j);
            if (nx < 0) { return kconst.ENOENT; };
            cur = nx;
        };
        i = j;
    };
    if (n > 0 && byte_at(path, n - 1) == 47 && yfs.yfs_type(cur) != yfs.YFS_DIR) { return kconst.ENOTDIR; };
    cur
};

/** Walk all but the last component: the directory holding it, or an errno.
 *  Leaves the last component in vfs_last ("" when the path is only slashes) and
 *  whether the path ended in a slash in vfs_last_slash. */
def vfs_walk_parent(start: long, path: str) -> long {
    let n = len(path);
    vfs_last = "";
    vfs_last_slash = 0;
    if (n == 0) { return kconst.ENOENT; };
    let end = n;
    while (end > 0 && byte_at(path, end - 1) == 47) { end = end - 1; };
    if (end < n) { vfs_last_slash = 1; };
    if (end == 0) { return yfs.yfs_root; };
    let k = end - 1;
    while (k >= 0 && byte_at(path, k) != 47) { k = k - 1; };
    if (end - 1 - k > VFS_NAME_MAX) { return kconst.ENAMETOOLONG; };
    let last = path[k + 1:end];
    let par = start;
    if (k >= 0) {
        par = vfs_walk(start, path[0:k + 1]);
        if (par < 0) { return par; };
    };
    if (yfs.yfs_type(par) != yfs.YFS_DIR) { return kconst.ENOTDIR; };
    vfs_last = last;
    par
};

/** The entry `name` of directory `par` ("." and ".." included): inode or -ENOENT. */
def vfs_child(par: long, name: str) -> long {
    if (name == ".") { return par; };
    if (name == "..") { return yfs.yfs_parent(par); };
    let ino = yfs.yfs_find_in(par, name, 0, len(name));
    if (ino < 0) { kconst.ENOENT } else { ino }
};

/** The absolute path of directory `ino`, by walking up the parents; -ENOENT when
 *  it has been removed. */
def vfs_ino_path(ino: long) -> str {
    if (ino == yfs.yfs_root) { return "/"; };
    let out = "";
    let cur = ino;
    let guard = 0;
    while (cur != yfs.yfs_root && guard < 256) {
        let par = yfs.yfs_parent(cur);
        let e = yfs.yfs_dir_next(par, 0);
        let found = "";
        let got = false;
        while (e != 0 && !got) {
            if (yfs.yfs_u32(e + 4) == cur) {
                let nl = yfs.yfs_u16(e);
                let b: [byte] = [];
                let k = 0;
                while (k < nl) { b += kmem_byte(e + 8 + k); k = k + 1; };
                found = from_bytes(b);
                got = true;
            } else {
                e = yfs.yfs_dir_next(par, e);
            };
        };
        if (!got) { return ""; };
        out = "/" + found + out;
        cur = par;
        guard = guard + 1;
    };
    out
};

def kmem_byte(imgoff: long) -> long {
    kernel.peek8(yfs.yfs_phys + imgoff)
};

// ── path helpers other modules use ──────────────────────────────────────
/** The inode `path` names, relative to directory inode `dir_ino` when not
 *  absolute; -ENOENT (-2) when it does not exist (another errno for a bad path). */
def vfs_lookup(dir_ino: long, path: str) -> long {
    if (len(path) == 0) { return kconst.ENOENT; };
    let start = dir_ino;
    if (byte_at(path, 0) == 47) { start = yfs.yfs_root; };
    vfs_walk(start, path)
};

/** Resolve a user path pointer for task `slot` against `dirfd` (AT_FDCWD or an
 *  open DIR fd): the inode or a negative errno. */
def vfs_resolve(slot: long, dirfd: long, pathp: long) -> long {
    if (pathp == 0) { return kconst.EFAULT; };
    let path = vfs_upath(pathp);
    if (len(path) == 0) { return kconst.ENOENT; };
    let start = vfs_start(slot, dirfd, path);
    if (start < 0) { return start; };
    vfs_walk(start, path)
};

/** T_REG, T_DIR, T_CHR or T_SOCK. */
def vfs_node_type(ino: long) -> long {
    if (!yfs.yfs_valid(ino)) { return T_REG; };
    let t = yfs.yfs_type(ino);
    if (t == yfs.YFS_DIR) { return T_DIR; };
    if (t == yfs.YFS_CHR) { return T_CHR; };
    if (t == yfs.YFS_SOCK) { return T_SOCK; };
    T_REG
};
/** A char node's device number (fdt.DEV_*), or 0. */
def vfs_node_dev(ino: long) -> long {
    if (!yfs.yfs_valid(ino) || yfs.yfs_type(ino) != yfs.YFS_CHR) { return 0; };
    yfs.yfs_dev(ino)
};

// Make a node of `mode` named by `path` (from the working directory of `slot`).
def vfs_mknod(slot: long, path: str, mode: long) -> long {
    if (len(path) == 0) { return kconst.ENOENT; };
    let start = vfs_start(slot, kconst.AT_FDCWD, path);
    if (start < 0) { return start; };
    let par = vfs_walk_parent(start, path);
    if (par < 0) { return par; };
    let last = vfs_last;
    if (len(last) == 0 || vfs_child(par, last) >= 0) { return kconst.EEXIST; };
    let ino = yfs.yfs_add_entry(par, last, mode);
    if (ino < 0) { return kconst.ENOSPC; };
    vfs_dir_gen = vfs_dir_gen + 1;
    ino
};

/** Make a socket node at `path` (relative to slot's cwd) for unix.bind: the
 *  inode, or -EEXIST (-17) / -ENOENT. */
def vfs_mknod_sock(slot: long, path: str) -> long {
    vfs_mknod(slot, path, yfs.YFS_SOCK)
};

// Remove a non-directory by path; shared by unlink and vfs_unlink_path.
def vfs_unlink_at(start: long, path: str) -> long {
    if (len(path) == 0) { return kconst.ENOENT; };
    let par = vfs_walk_parent(start, path);
    if (par < 0) { return par; };
    let last = vfs_last;
    let slash = vfs_last_slash;
    if (len(last) == 0 || last == "." || last == "..") { return kconst.EISDIR; };
    let ino = vfs_child(par, last);
    if (ino < 0) { return ino; };
    if (yfs.yfs_type(ino) == yfs.YFS_DIR) { return kconst.EISDIR; };
    if (slash != 0) { return kconst.ENOTDIR; };
    yfs.yfs_dir_remove(par, last);
    vfs_dir_gen = vfs_dir_gen + 1;
    vfs_drop(ino);
    0
};

/** Remove a socket node (unix: the last close of a bound listener need not). */
def vfs_unlink_path(slot: long, path: str) -> long {
    if (len(path) == 0) { return kconst.ENOENT; };
    let start = vfs_start(slot, kconst.AT_FDCWD, path);
    if (start < 0) { return start; };
    vfs_unlink_at(start, path)
};

// ── FILE/DIR ops (fdt dispatches here) ──────────────────────────────────
def vfs_of_ok(obj: long) -> bool {
    obj >= 0 && obj < len(of_ino) && of_ino[obj] != 0
};

def file_open(ino: long, flags: long) -> long {
    let h = 0;
    if (vfs_of_nfree > 0) {
        vfs_of_nfree = vfs_of_nfree - 1;
        h = vfs_of_free[vfs_of_nfree];
    } else {
        h = len(of_ino);
        of_ino += 0;
        of_off += 0;
        of_ce += 0;
        of_cidx += 0;
        of_gen += 0;
    };
    of_ino[h] = ino;
    of_off[h] = 0;
    of_ce[h] = 0;
    of_cidx[h] = 0 - 1;
    of_gen[h] = 0;
    vfs_set_state(ino, (vfs_state(ino) & 1) + (((vfs_state(ino) >> 1) + 1) << 1));
    h
};

def file_read(obj: long, buf: long, len: long, flags: long) -> long {
    if (!vfs_of_ok(obj)) { return kconst.EBADF; };
    let ino = of_ino[obj];
    if (yfs.yfs_type(ino) == yfs.YFS_DIR) { return kconst.EISDIR; };
    if ((flags & 3) == 1) { return kconst.EBADF; };
    if (len <= 0) { return 0; };
    let n = yfs.yfs_read(ino, of_off[obj], buf, len);
    if (n < 0) { return kconst.EIO; };
    of_off[obj] = of_off[obj] + n;
    n
};

def file_write(obj: long, buf: long, len: long, flags: long) -> long {
    if (!vfs_of_ok(obj)) { return kconst.EBADF; };
    let ino = of_ino[obj];
    if (yfs.yfs_type(ino) == yfs.YFS_DIR) { return kconst.EISDIR; };
    if ((flags & 3) == 0) { return kconst.EBADF; };
    if (len <= 0) { return 0; };
    if ((flags & kconst.O_APPEND) != 0) { of_off[obj] = yfs.yfs_size(ino); };
    let n = yfs.yfs_write(ino, of_off[obj], buf, len);
    if (n < 0) { return n; };
    of_off[obj] = of_off[obj] + n;
    n
};

def file_ioctl(obj: long, req: long, arg: long) -> long { 0 - 25 };
def file_poll(obj: long, events: long) -> long { events & 5 };

def file_close(obj: long) -> long {
    if (!vfs_of_ok(obj)) { return kconst.EBADF; };
    let ino = of_ino[obj];
    of_ino[obj] = 0;
    if (vfs_of_nfree < len(vfs_of_free)) { vfs_of_free[vfs_of_nfree] = obj; } else { vfs_of_free += obj; };
    vfs_of_nfree = vfs_of_nfree + 1;
    let st = vfs_state(ino);
    let opens = (st >> 1) - 1;
    if (opens <= 0 && (st & 1) != 0) {
        yfs.yfs_release(ino);
        vfs_set_state(ino, 0);
    } else {
        vfs_set_state(ino, (opens << 1) + (st & 1));
    };
    0
};

def file_lseek(obj: long, off: long, whence: long) -> long {
    if (!vfs_of_ok(obj)) { return kconst.EBADF; };
    let ino = of_ino[obj];
    let isdir = yfs.yfs_type(ino) == yfs.YFS_DIR;
    let base = 0;
    if (whence == 1) { base = of_off[obj]; }
    else if (whence == 2) {
        if (isdir) { base = yfs.yfs_dir_count(ino) + 2; } else { base = yfs.yfs_size(ino); };
    } else if (whence != 0) { return kconst.EINVAL; };
    let np = base + off;
    if (np < 0) { return kconst.EINVAL; };
    of_off[obj] = np;
    np
};

def vfs_dtype(ino: long) -> long {
    let t = yfs.yfs_type(ino);
    if (t == yfs.YFS_DIR) { return 4; };
    if (t == yfs.YFS_CHR) { return 2; };
    if (t == yfs.YFS_SOCK) { return 12; };
    8
};

// Emit one linux_dirent64 at buf+w; the new w, or -1 when it does not fit.
def vfs_dirent(buf: long, w: long, room: long, dino: long, doff: long, name: str, dt: long) -> long {
    let nl = len(name);
    let reclen = (19 + nl + 1 + 7) & (0 - 8);
    if (w + reclen > room) { return 0 - 1; };
    vfs_put64(buf, w, dino);
    vfs_put64(buf, w + 8, doff);
    kernel.poke_va8(buf + w + 16, reclen & 255);
    kernel.poke_va8(buf + w + 17, (reclen >> 8) & 255);
    kernel.poke_va8(buf + w + 18, dt);
    let k = 0;
    while (k < nl) { kernel.poke_va8(buf + w + 19 + k, byte_at(name, k)); k = k + 1; };
    kernel.poke_va8(buf + w + 19 + nl, 0);
    w + reclen
};

def file_getdents(obj: long, buf: long, len: long) -> long {
    if (!vfs_of_ok(obj)) { return kconst.EBADF; };
    let dino = of_ino[obj];
    if (yfs.yfs_type(dino) != yfs.YFS_DIR) { return kconst.ENOTDIR; };
    if (!kernel.user_ok(buf, len)) { return kconst.EFAULT; };
    let w = 0;
    let idx = of_off[obj];
    let done = false;
    while (!done) {
        let nw = 0 - 1;
        if (idx == 0) {
            nw = vfs_dirent(buf, w, len, dino, 1, ".", 4);
        } else if (idx == 1) {
            nw = vfs_dirent(buf, w, len, yfs.yfs_parent(dino), 2, "..", 4);
        } else {
            if (of_gen[obj] != vfs_dir_gen || of_cidx[obj] != idx - 2) {
                of_ce[obj] = yfs.yfs_entry_off(dino, idx - 2);
                of_cidx[obj] = idx - 2;
                of_gen[obj] = vfs_dir_gen;
            };
            let e = of_ce[obj];
            if (e == 0) { done = true; } else {
                let nl = yfs.yfs_u16(e);
                let b: [byte] = [];
                let k = 0;
                while (k < nl) { b += kmem_byte(e + 8 + k); k = k + 1; };
                let ci = yfs.yfs_u32(e + 4);
                nw = vfs_dirent(buf, w, len, ci, idx + 1, from_bytes(b), vfs_dtype(ci));
                if (nw >= 0) {
                    of_ce[obj] = yfs.yfs_dir_next(dino, e);
                    of_cidx[obj] = idx - 1;
                };
            };
        };
        if (!done) {
            if (nw < 0) {
                done = true;
                if (w == 0) { return kconst.EINVAL; };
            } else {
                w = nw;
                idx = idx + 1;
            };
        };
    };
    of_off[obj] = idx;
    w
};

// st_rdev of a char device number.
def vfs_rdev(dev: long) -> long {
    if (dev == kconst.DEV_NULL) { return (1 << 8) | 3; };
    if (dev == kconst.DEV_ZERO) { return (1 << 8) | 5; };
    if (dev == kconst.DEV_DSP) { return (14 << 8) | 3; };
    if (dev == kconst.DEV_FB) { return (29 << 8) | 0; };
    if (dev == kconst.DEV_INPUT) { return (13 << 8) | 64; };
    5 << 8
};

// What stat reports about a node, set by the vfs_facts_* helpers and written
// out by vfs_put_stat / vfs_put_statx.
let f_ino: long = 0;
let f_mode: long = 0;
let f_nlink: long = 1;
let f_rdev: long = 0;
let f_size: long = 0;

def vfs_facts(ino: long, mode: long, nlink: long, rdev: long, size: long) -> void {
    f_ino = ino;
    f_mode = mode;
    f_nlink = nlink;
    f_rdev = rdev;
    f_size = size;
};

def vfs_facts_ino(ino: long) -> void {
    let t = yfs.yfs_type(ino);
    if (t == yfs.YFS_DIR) {
        let nb = 0;
        while (yfs.yfs_bget(ino, nb) != 0) { nb = nb + 1; };
        vfs_facts(ino, 16384 + 493, 2, 0, nb * yfs.yfs_block_size);
    } else if (t == yfs.YFS_CHR) {
        vfs_facts(ino, 8192 + 438, 1, vfs_rdev(yfs.yfs_dev(ino)), 0);
    } else if (t == yfs.YFS_SOCK) {
        vfs_facts(ino, 49152 + 493, 1, 0, 0);
    } else {
        vfs_facts(ino, 32768 + 420, 1, 0, yfs.yfs_size(ino));
    };
};

// struct stat (144 bytes) at user VA `sb`.
def vfs_put_stat(sb: long) -> long {
    if (!kernel.user_ok(sb, 144)) { return kconst.EFAULT; };
    kernel.kzero(sb, 144);
    vfs_put64(sb, 8, f_ino);
    vfs_put64(sb, 16, f_nlink);
    vfs_put32(sb, 24, f_mode);
    vfs_put32(sb, 28, 1000);
    vfs_put32(sb, 32, 1000);
    vfs_put64(sb, 40, f_rdev);
    vfs_put64(sb, 48, f_size);
    vfs_put64(sb, 56, 4096);
    vfs_put64(sb, 64, (f_size + 511) / 512);
    0
};

// struct statx (256 bytes) at user VA `sb`.
def vfs_put_statx(sb: long) -> long {
    if (!kernel.user_ok(sb, 256)) { return kconst.EFAULT; };
    kernel.kzero(sb, 256);
    vfs_put32(sb, 0, 2047);
    vfs_put32(sb, 4, 4096);
    vfs_put32(sb, 16, f_nlink);
    vfs_put32(sb, 20, 1000);
    vfs_put32(sb, 24, 1000);
    kernel.poke_va8(sb + 28, f_mode & 255);
    kernel.poke_va8(sb + 29, (f_mode >> 8) & 255);
    vfs_put64(sb, 32, f_ino);
    vfs_put64(sb, 40, f_size);
    vfs_put64(sb, 48, (f_size + 511) / 512);
    vfs_put32(sb, 128, f_rdev >> 8);
    vfs_put32(sb, 132, f_rdev & 255);
    0
};

/** Fill a Linux `struct stat` (144 bytes) at user VA `statbuf`. */
def file_fstat(obj: long, statbuf: long) -> long {
    if (!vfs_of_ok(obj)) { return kconst.EBADF; };
    vfs_facts_ino(of_ino[obj]);
    vfs_put_stat(statbuf)
};

def file_ino(obj: long) -> long {
    if (!vfs_of_ok(obj)) { return 0 - 9; };
    of_ino[obj]
};

// ── syscalls ────────────────────────────────────────────────────────────
// The fd table is fdt's.  If fd_install answers -ENOSYS (an fdt without a table)
// a file is opened in std/fd.y's legacy global table instead, so the rest of
// the system keeps working; with the real fdt this never happens.
def vfs_install(slot: long, kind: long, ino: long, flags: long) -> long {
    let h = file_open(ino, flags);
    let r = fdt.fd_install(slot, kind, h, flags);
    if (r == kconst.ENOSYS) {
        file_close(h);
        let l = fd.fd_open_ino(ino);
        if (l < 0) { return kconst.EMFILE; };
        if ((flags & kconst.O_APPEND) != 0) { fd.fd_seek_set(l, yfs.yfs_size(ino)); };
        return l;
    };
    if (r < 0) { file_close(h); };
    r
};

def vfs_open_path(slot: long, dirfd: long, path: str, flags: long) -> long {
    if (len(path) == 0) { return kconst.ENOENT; };
    if (path == "/proc/self/environ") { return fdt.fdt_open_environ(slot, flags); };
    let start = vfs_start(slot, dirfd, path);
    if (start < 0) { return start; };
    let par = vfs_walk_parent(start, path);
    if (par < 0) { return par; };
    let last = vfs_last;
    let slash = vfs_last_slash;
    let ino = par;
    if (len(last) > 0) { ino = vfs_child(par, last); };
    let acc = flags & kconst.O_ACCMODE;
    if (ino < 0) {
        if (ino != kconst.ENOENT) { return ino; };
        if ((flags & kconst.O_CREAT) == 0) { return kconst.ENOENT; };
        if (slash != 0) { return kconst.EISDIR; };
        ino = yfs.yfs_add_entry(par, last, yfs.YFS_REG);
        if (ino < 0) { return kconst.ENOSPC; };
        vfs_dir_gen = vfs_dir_gen + 1;
    } else {
        if ((flags & kconst.O_CREAT) != 0 && (flags & kconst.O_EXCL) != 0) { return kconst.EEXIST; };
    };
    let t = yfs.yfs_type(ino);
    if (t == yfs.YFS_DIR) {
        if (acc != 0 || (flags & kconst.O_CREAT) != 0 && ino != par) { return kconst.EISDIR; };
        return vfs_install(slot, kconst.DIR, ino, flags);
    };
    if (slash != 0 || (flags & kconst.O_DIRECTORY) != 0) { return kconst.ENOTDIR; };
    if (t == yfs.YFS_CHR) { return fdt.fdt_open_dev(slot, yfs.yfs_dev(ino), flags); };
    if (t == yfs.YFS_SOCK) { return 0 - 6; };
    if ((flags & kconst.O_TRUNC) != 0 && acc != 0) { yfs.yfs_truncate(ino, 0); };
    vfs_install(slot, kconst.FILE, ino, flags)
};

def sys_open(path: long, flags: long, mode: long) -> long {
    sys_openat(kconst.AT_FDCWD, path, flags, mode)
};

def sys_openat(dirfd: long, path: long, flags: long, mode: long) -> long {
    if (path == 0) { return kconst.EFAULT; };
    vfs_open_path(kernel.task_slot(), dirfd, vfs_upath(path), flags)
};

// The facts about fd `fdno`; fds that are not files get a synthesized node (a tty
// is a char device, a pipe a FIFO).  0 or an errno.
def vfs_facts_fd(slot: long, fdno: long) -> long {
    let k = fdt.fd_kind(slot, fdno);
    if (k < 0) {
        // the stub fdt: the legacy table, and the console as fds 0 1 2
        if (fd.fd_valid(fdno)) { vfs_facts_ino(fd.fd_ino(fdno)); return 0; };
        if (fdno >= 0 && fdno <= 2) { vfs_facts(1, 8192 + 400, 1, 5 << 8, 0); return 0; };
        return kconst.EBADF;
    };
    if (k == kconst.FILE || k == kconst.DIR) { vfs_facts_ino(file_ino(fdt.fd_obj(slot, fdno))); return 0; };
    if (k == kconst.PIPE_R || k == kconst.PIPE_W) { vfs_facts(1, 4096 + 384, 1, 0, 0); return 0; };
    if (k == kconst.SOCK) { vfs_facts(1, 49152 + 493, 1, 0, 0); return 0; };
    if (k == kconst.NULL && fdt.fd_obj(slot, fdno) >= 2) { vfs_facts(1, 32768 + 292, 1, 0, fdt.fdt_mem_size(fdt.fd_obj(slot, fdno))); return 0; };
    if (k == kconst.NULL) { vfs_facts(1, 8192 + 438, 1, vfs_rdev(kconst.DEV_NULL + fdt.fd_obj(slot, fdno)), 0); return 0; };
    if (k == kconst.DSP) { vfs_facts(1, 8192 + 438, 1, vfs_rdev(kconst.DEV_DSP), 0); return 0; };
    if (k == kconst.FB) { vfs_facts(1, 8192 + 438, 1, vfs_rdev(kconst.DEV_FB), 0); return 0; };
    if (k == kconst.INPUT) { vfs_facts(1, 8192 + 438, 1, vfs_rdev(kconst.DEV_INPUT), 0); return 0; };
    vfs_facts(1, 8192 + 400, 1, 5 << 8, 0);
    0
};

// The facts about a path (or, with AT_EMPTY_PATH and an empty path, about `dirfd`).
def vfs_facts_path(dirfd: long, path: long, flags: long) -> long {
    let slot = kernel.task_slot();
    if (path == 0) { return kconst.EFAULT; };
    let p = vfs_upath(path);
    if (len(p) == 0) {
        if ((flags & 4096) != 0) { return vfs_facts_fd(slot, dirfd); };
        return kconst.ENOENT;
    };
    let start = vfs_start(slot, dirfd, p);
    if (start < 0) { return start; };
    let ino = vfs_walk(start, p);
    if (ino < 0) { return ino; };
    vfs_facts_ino(ino);
    0
};

def vfs_stat_path(dirfd: long, path: long, statbuf: long, flags: long) -> long {
    let r = vfs_facts_path(dirfd, path, flags);
    if (r < 0) { return r; };
    vfs_put_stat(statbuf)
};

def sys_stat(path: long, statbuf: long) -> long {
    vfs_stat_path(kconst.AT_FDCWD, path, statbuf, 0)
};
def sys_fstat(fdno: long, statbuf: long) -> long {
    let r = vfs_facts_fd(kernel.task_slot(), fdno);
    if (r < 0) { return r; };
    vfs_put_stat(statbuf)
};
def sys_lstat(path: long, statbuf: long) -> long {
    vfs_stat_path(kconst.AT_FDCWD, path, statbuf, 0)
};
def sys_newfstatat(dirfd: long, path: long, statbuf: long, flags: long) -> long {
    vfs_stat_path(dirfd, path, statbuf, flags)
};

def sys_statx(dirfd: long, path: long, flags: long, mask: long, buf: long) -> long {
    let r = vfs_facts_path(dirfd, path, flags);
    if (r < 0) { return r; };
    vfs_put_statx(buf)
};

def vfs_access(dirfd: long, path: long, mode: long) -> long {
    let r = vfs_resolve(kernel.task_slot(), dirfd, path);
    if (r < 0) { r } else { 0 }
};

def sys_access(path: long, mode: long) -> long { vfs_access(kconst.AT_FDCWD, path, mode) };
def sys_faccessat(dirfd: long, path: long, mode: long, flags: long) -> long { vfs_access(dirfd, path, mode) };
def sys_faccessat2(dirfd: long, path: long, mode: long, flags: long) -> long { vfs_access(dirfd, path, mode) };

def vfs_trunc_ino(ino: long, size: long) -> long {
    if (size < 0) { return kconst.EINVAL; };
    let t = yfs.yfs_type(ino);
    if (t == yfs.YFS_DIR) { return kconst.EISDIR; };
    if (t != yfs.YFS_REG) { return kconst.EINVAL; };
    yfs.yfs_truncate(ino, size)
};

def sys_truncate(path: long, len: long) -> long {
    let ino = vfs_resolve(kernel.task_slot(), kconst.AT_FDCWD, path);
    if (ino < 0) { return ino; };
    vfs_trunc_ino(ino, len)
};

def sys_ftruncate(fdno: long, len: long) -> long {
    let slot = kernel.task_slot();
    let k = fdt.fd_kind(slot, fdno);
    if (k < 0) {
        if (fd.fd_valid(fdno)) { return vfs_trunc_ino(fd.fd_ino(fdno), len); };
        return kconst.EBADF;
    };
    if (k != kconst.FILE && k != kconst.DIR) { return kconst.EINVAL; };
    if ((fdt.fd_flags(slot, fdno) & 3) == 0) { return kconst.EINVAL; };
    vfs_trunc_ino(file_ino(fdt.fd_obj(slot, fdno)), len)
};

def sys_getcwd(buf: long, size: long) -> long {
    let slot = kernel.task_slot();
    let p = vfs_ino_path(proc.cwd_ino(slot));
    if (len(p) == 0) { return kconst.ENOENT; };
    if (len(p) + 1 > size) { return kconst.ERANGE; };
    if (!kernel.user_ok(buf, len(p) + 1)) { return kconst.EFAULT; };
    let i = 0;
    while (i < len(p)) { kernel.poke_va8(buf + i, byte_at(p, i)); i = i + 1; };
    kernel.poke_va8(buf + len(p), 0);
    len(p) + 1
};

def vfs_chdir_ino(slot: long, ino: long) -> long {
    if (ino < 0) { return ino; };
    if (yfs.yfs_type(ino) != yfs.YFS_DIR) { return kconst.ENOTDIR; };
    proc.set_cwd(slot, ino, vfs_ino_path(ino));
    0
};

def sys_chdir(path: long) -> long {
    let slot = kernel.task_slot();
    vfs_chdir_ino(slot, vfs_resolve(slot, kconst.AT_FDCWD, path))
};

def sys_fchdir(fdno: long) -> long {
    let slot = kernel.task_slot();
    let k = fdt.fd_kind(slot, fdno);
    if (k < 0) { return kconst.EBADF; };
    if (k != kconst.DIR) { return kconst.ENOTDIR; };
    vfs_chdir_ino(slot, file_ino(fdt.fd_obj(slot, fdno)))
};

// Is directory `anc` the directory `d` or one of its ancestors?
def vfs_is_ancestor(anc: long, d: long) -> bool {
    let cur = d;
    let guard = 0;
    while (guard < 1024) {
        if (cur == anc) { return true; };
        if (cur == yfs.yfs_root) { return false; };
        cur = yfs.yfs_parent(cur);
        guard = guard + 1;
    };
    false
};

def vfs_rename_at(od: long, oldp: long, nd: long, newp: long, flags: long) -> long {
    if (oldp == 0 || newp == 0) { return kconst.EFAULT; };
    if ((flags & 6) != 0) { return kconst.EINVAL; };
    let slot = kernel.task_slot();
    let op = vfs_upath(oldp);
    let np = vfs_upath(newp);
    if (len(op) == 0 || len(np) == 0) { return kconst.ENOENT; };
    let os = vfs_start(slot, od, op);
    if (os < 0) { return os; };
    let ns = vfs_start(slot, nd, np);
    if (ns < 0) { return ns; };
    let opar = vfs_walk_parent(os, op);
    if (opar < 0) { return opar; };
    let olast = vfs_last;
    let npar = vfs_walk_parent(ns, np);
    if (npar < 0) { return npar; };
    let nlast = vfs_last;
    if (len(olast) == 0 || len(nlast) == 0) { return 0 - 16; };
    if (olast == "." || olast == ".." || nlast == "." || nlast == "..") { return kconst.EINVAL; };
    let ino = vfs_child(opar, olast);
    if (ino < 0) { return ino; };
    let ex = vfs_child(npar, nlast);
    if (ex >= 0 && (flags & 1) != 0) { return kconst.EEXIST; };
    if (ex == ino) { return 0; };
    let isdir = yfs.yfs_type(ino) == yfs.YFS_DIR;
    if (isdir && vfs_is_ancestor(ino, npar)) { return kconst.EINVAL; };
    if (ex >= 0) {
        let exdir = yfs.yfs_type(ex) == yfs.YFS_DIR;
        if (isdir && !exdir) { return kconst.ENOTDIR; };
        if (!isdir && exdir) { return kconst.EISDIR; };
        if (exdir && yfs.yfs_dir_count(ex) != 0) { return kconst.ENOTEMPTY; };
        yfs.yfs_dir_remove(npar, nlast);
    };
    if (yfs.yfs_link(npar, nlast, ino) < 0) {
        if (ex >= 0) { yfs.yfs_link(npar, nlast, ex); };
        return kconst.ENOSPC;
    };
    yfs.yfs_dir_remove(opar, olast);
    if (isdir) { yfs.yfs_set_parent(ino, npar); };
    if (ex >= 0) { vfs_drop(ex); };
    vfs_dir_gen = vfs_dir_gen + 1;
    0
};

def sys_rename(oldp: long, newp: long) -> long {
    vfs_rename_at(kconst.AT_FDCWD, oldp, kconst.AT_FDCWD, newp, 0)
};
def sys_renameat(od: long, oldp: long, nd: long, newp: long) -> long {
    vfs_rename_at(od, oldp, nd, newp, 0)
};
def sys_renameat2(od: long, oldp: long, nd: long, newp: long, flags: long) -> long {
    vfs_rename_at(od, oldp, nd, newp, flags)
};

def vfs_mkdir_at(dirfd: long, pathp: long) -> long {
    if (pathp == 0) { return kconst.EFAULT; };
    let slot = kernel.task_slot();
    let path = vfs_upath(pathp);
    if (len(path) == 0) { return kconst.ENOENT; };
    let start = vfs_start(slot, dirfd, path);
    if (start < 0) { return start; };
    let par = vfs_walk_parent(start, path);
    if (par < 0) { return par; };
    let last = vfs_last;
    if (len(last) == 0 || vfs_child(par, last) >= 0) { return kconst.EEXIST; };
    let ino = yfs.yfs_add_entry(par, last, yfs.YFS_DIR);
    if (ino < 0) { return kconst.ENOSPC; };
    vfs_dir_gen = vfs_dir_gen + 1;
    0
};

def sys_mkdir(path: long, mode: long) -> long { vfs_mkdir_at(kconst.AT_FDCWD, path) };
def sys_mkdirat(dirfd: long, path: long, mode: long) -> long { vfs_mkdir_at(dirfd, path) };

def vfs_rmdir_at(dirfd: long, pathp: long) -> long {
    if (pathp == 0) { return kconst.EFAULT; };
    let slot = kernel.task_slot();
    let path = vfs_upath(pathp);
    if (len(path) == 0) { return kconst.ENOENT; };
    let start = vfs_start(slot, dirfd, path);
    if (start < 0) { return start; };
    let par = vfs_walk_parent(start, path);
    if (par < 0) { return par; };
    let last = vfs_last;
    if (len(last) == 0) { return 0 - 16; };
    if (last == ".") { return kconst.EINVAL; };
    if (last == "..") { return kconst.ENOTEMPTY; };
    let ino = vfs_child(par, last);
    if (ino < 0) { return ino; };
    if (yfs.yfs_type(ino) != yfs.YFS_DIR) { return kconst.ENOTDIR; };
    if (yfs.yfs_dir_count(ino) != 0) { return kconst.ENOTEMPTY; };
    yfs.yfs_dir_remove(par, last);
    vfs_dir_gen = vfs_dir_gen + 1;
    vfs_drop(ino);
    0
};

def sys_rmdir(path: long) -> long { vfs_rmdir_at(kconst.AT_FDCWD, path) };

def vfs_unlink_user(dirfd: long, pathp: long) -> long {
    if (pathp == 0) { return kconst.EFAULT; };
    let slot = kernel.task_slot();
    let path = vfs_upath(pathp);
    if (len(path) == 0) { return kconst.ENOENT; };
    let start = vfs_start(slot, dirfd, path);
    if (start < 0) { return start; };
    vfs_unlink_at(start, path)
};

def sys_unlink(path: long) -> long { vfs_unlink_user(kconst.AT_FDCWD, path) };
def sys_unlinkat(dirfd: long, path: long, flags: long) -> long {
    if ((flags & 512) != 0) { return vfs_rmdir_at(dirfd, path); };
    vfs_unlink_user(dirfd, path)
};

def sys_readlink(path: long, buf: long, size: long) -> long {
    let r = vfs_resolve(kernel.task_slot(), kconst.AT_FDCWD, path);
    if (r < 0) { r } else { kconst.EINVAL }
};

def sys_chmod(path: long, mode: long) -> long {
    let r = vfs_resolve(kernel.task_slot(), kconst.AT_FDCWD, path);
    if (r < 0) { r } else { 0 }
};

def sys_fchmodat(dirfd: long, path: long, mode: long, flags: long) -> long {
    let r = vfs_resolve(kernel.task_slot(), dirfd, path);
    if (r < 0) { r } else { 0 }
};

def sys_utimensat(dirfd: long, path: long, times: long, flags: long) -> long {
    if (path == 0) { return 0; };
    let r = vfs_resolve(kernel.task_slot(), dirfd, path);
    if (r < 0) { r } else { 0 }
};

def sys_getdents64(fdno: long, buf: long, len: long) -> long {
    let slot = kernel.task_slot();
    let k = fdt.fd_kind(slot, fdno);
    if (k < 0) {
        // the stub fdt: the legacy table's own getdents
        if (fd.fd_valid(fdno)) { return kernel.SYS_FALLBACK; };
        return kconst.EBADF;
    };
    if (k != kconst.DIR) { return kconst.ENOTDIR; };
    file_getdents(fdt.fd_obj(slot, fdno), buf, len)
};
