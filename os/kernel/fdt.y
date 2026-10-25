// fdt -- per-process file descriptor tables and open file descriptions.
//
// A task slot names a TABLE (slot_tbl); a table maps fd -> open file description
// (tb_ofd) and keeps the FD_CLOEXEC bit per fd (tb_cx).  Tables are reference
// counted so a thread that shares its parent's files (fdt_share, for
// CLONE_FILES) uses the same one.  A description is {kind, obj, flags, refs}; fork
// and dup raise refs, the last close calls the kind's X_close(obj).
//
// A slot that never went through fdt_on_fork (the boot task) gets the console on
// 0, 1 and 2 the first time anything asks for its table.
//
// Kinds and their module ops (obj is that module's own handle):
//   kconst.FILE, kconst.DIR  vfs.file_*      kconst.TTY        tty.tty_*
//   kconst.PIPE_R/W          pipe.pipe_*     kconst.SOCK       unix.sock_*
//   kconst.DSP               dsp.dsp_*       kconst.NULL       here: obj 0 = /dev/null,
//        1 = /dev/zero, 2.. = a read-only memory file (/proc/self/environ).
//
// TRANSITIONAL (delete when vfs lands, see fdt_legacy): an fd that is not in the table
// but could be one of kernel.y's global fd.y descriptors (3..18) answers
// kernel.SYS_FALLBACK, and a TTY whose module still answers -ENOSYS is served by
// kernel.y's polling console.
import kernel;
import kconst from "./kconst.y";
import vfs from "./vfs.y";
import pipe from "./pipe.y";
import proc from "./proc.y";
import time from "./time.y";
import tty from "./tty.y";
import fbdev from "./fbdev.y";
import dsp from "./dsp.y";
import unix from "./unix.y";

const FDMAX = 128;
const FD_SETSIZE = 1024;

let of_kind: [long] = [];
let of_obj: [long] = [];
let of_flags: [long] = [];
let of_refs: [long] = [];

let tb_ofd: [long] = [];
let tb_cx: [long] = [];
let tb_refs: [long] = [];
let slot_tbl: [long] = [];
let poll_dl: [long] = [];

// memory files (kind NULL, obj 2 + index)
let mf_data: [str] = [];
let mf_off: [long] = [];
let mf_live: [long] = [];

/** The wait channel for (kind or space, obj).  Never 0. */
def fdt_chan(kind: long, obj: long) -> long {
    (kind << 40) | (obj & 1099511627775)
};

/** Something changed on (kind, obj): wake its waiters and every poller.
 *  Safe from an IRQ handler. */
def fdt_notify(kind: long, obj: long) -> void {
    kernel.wake_chan(fdt_chan(kind, obj));
    kernel.wake_chan(fdt_chan(kconst.CH_POLL, 0));
};

/** TRANSITIONAL: may `fd` be one of kernel.y's global fd.y descriptors?  Return
 *  false here once vfs installs real files into the tables. */
def fdt_legacy(n: long) -> bool { n >= 3 && n < 19 };

// ── user memory ─────────────────────────────────────────────────────────
def u_rd64(addr: long) -> long {
    if ((addr & 7) == 0) { return kernel.peek_va64(addr); };
    let v = 0;
    let i = 7;
    while (i >= 0) { v = (v << 8) | kernel.peek_va8(addr + i); i = i - 1; };
    v
};

def u_wr64(addr: long, v: long) -> void {
    if ((addr & 7) == 0) { kernel.poke_va64(addr, v); return; };
    let i = 0;
    while (i < 8) { kernel.poke_va8(addr + i, (v >> (8 * i)) & 255); i = i + 1; };
};

def u_rd32s(addr: long) -> long {
    let v = kernel.peek_va8(addr) | (kernel.peek_va8(addr + 1) << 8) | (kernel.peek_va8(addr + 2) << 16) | (kernel.peek_va8(addr + 3) << 24);
    if (v >= 2147483648) { v - 4294967296 } else { v }
};

// ── open file descriptions and tables ───────────────────────────────────
def of_new(kind: long, obj: long, flags: long) -> long {
    let i = 0;
    while (i < len(of_refs)) {
        if (of_refs[i] == 0) {
            of_kind[i] = kind;
            of_obj[i] = obj;
            of_flags[i] = flags;
            of_refs[i] = 1;
            return i;
        };
        i = i + 1;
    };
    of_kind += kind;
    of_obj += obj;
    of_flags += flags;
    of_refs += 1;
    len(of_refs) - 1
};

/** Drop one reference; the last one closes the object behind it. */
def of_put(o: long) -> void {
    of_refs[o] = of_refs[o] - 1;
    if (of_refs[o] == 0) {
        let k = of_kind[o];
        let ob = of_obj[o];
        of_kind[o] = 0;
        fdt_kind_close(k, ob);
    };
};

def tbl_new() -> long {
    let t = 0;
    while (t < len(tb_refs)) {
        if (tb_refs[t] == 0) {
            let i = 0;
            while (i < FDMAX) { tb_ofd[t * FDMAX + i] = 0 - 1; tb_cx[t * FDMAX + i] = 0; i = i + 1; };
            tb_refs[t] = 1;
            return t;
        };
        t = t + 1;
    };
    let i = 0;
    while (i < FDMAX) { tb_ofd += 0 - 1; tb_cx += 0; i = i + 1; };
    tb_refs += 1;
    len(tb_refs) - 1
};

def fdt_grow(slot: long) -> void {
    while (len(slot_tbl) <= slot) { slot_tbl += 0 - 1; poll_dl += 0; };
};

/** The table of task `slot`; made with the console on 0, 1, 2 if it has none. */
def fdt_tbl(slot: long) -> long {
    fdt_grow(slot);
    if (slot_tbl[slot] >= 0) { return slot_tbl[slot]; };
    let t = tbl_new();
    slot_tbl[slot] = t;
    let o = of_new(kconst.TTY, tty.tty_open(2), 2);
    of_refs[o] = 3;
    tb_ofd[t * FDMAX] = o;
    tb_ofd[t * FDMAX + 1] = o;
    tb_ofd[t * FDMAX + 2] = o;
    t
};

/** The description behind `n` in task `slot`, or -EBADF. */
def fdt_of(slot: long, n: long) -> long {
    if (n < 0 || n >= FDMAX) { return kconst.EBADF; };
    let o = tb_ofd[fdt_tbl(slot) * FDMAX + n];
    if (o < 0) { kconst.EBADF } else { o }
};

/** The lowest free fd >= `lo` in table `t`, or -EMFILE. */
def tbl_free(t: long, lo: long) -> long {
    let i = lo;
    while (i < FDMAX) {
        if (tb_ofd[t * FDMAX + i] < 0) { return i; };
        i = i + 1;
    };
    kconst.EMFILE
};

/** Put description `o` (a reference the caller already holds) at fd `n`. */
def tbl_set(t: long, n: long, o: long, cx: long) -> void {
    tb_ofd[t * FDMAX + n] = o;
    tb_cx[t * FDMAX + n] = cx;
};

// ── the table, as other modules see it ──────────────────────────────────
/** Install a NEW open file description {kind, obj, flags} as the lowest free fd
 *  of task `slot`; the fd, or -EMFILE (-24).  flags: open(2) flags (O_CLOEXEC
 *  goes to the fd, the rest to the description). */
def fd_install(slot: long, kind: long, obj: long, flags: long) -> long {
    let t = fdt_tbl(slot);
    let n = tbl_free(t, 0);
    if (n < 0) { return n; };
    let cx = 0;
    if ((flags & kconst.O_CLOEXEC) != 0) { cx = 1; };
    let o = of_new(kind, obj, flags & (0 - 1 - kconst.O_CLOEXEC));
    tbl_set(t, n, o, cx);
    n
};

/** The kind of `fd` in task `slot`, or -EBADF. */
def fd_kind(slot: long, fd: long) -> long {
    let o = fdt_of(slot, fd);
    if (o < 0) { o } else { of_kind[o] }
};

/** The module handle behind `fd` in task `slot`, or -EBADF. */
def fd_obj(slot: long, fd: long) -> long {
    let o = fdt_of(slot, fd);
    if (o < 0) { o } else { of_obj[o] }
};

/** The description's status flags (O_NONBLOCK, O_APPEND, access mode), or -EBADF. */
def fd_flags(slot: long, fd: long) -> long {
    let o = fdt_of(slot, fd);
    if (o < 0) { o } else { of_flags[o] }
};

/** Open character device `dev` (DEV_*) for task `slot` with open flags: the fd. */
def fdt_open_dev(slot: long, dev: long, flags: long) -> long {
    if (dev == kconst.DEV_TTY) { return fd_install(slot, kconst.TTY, tty.tty_open(flags), flags); };
    if (dev == kconst.DEV_NULL) { return fd_install(slot, kconst.NULL, 0, flags); };
    if (dev == kconst.DEV_ZERO) { return fd_install(slot, kconst.NULL, 1, flags); };
    if (dev == kconst.DEV_DSP) {
        let obj = dsp.dsp_open(flags);
        if (obj < 0) { return obj; };
        let n = fd_install(slot, kconst.DSP, obj, flags);
        if (n < 0) { dsp.dsp_close(obj); };
        return n;
    };
    if (dev == kconst.DEV_FB) {
        let obj = fbdev.fb_open(flags);
        if (obj < 0) { return obj; };
        return fd_install(slot, kconst.FB, obj, flags);
    };
    if (dev == kconst.DEV_INPUT) {
        let obj = fbdev.input_open(flags);
        if (obj < 0) { return obj; };
        return fd_install(slot, kconst.INPUT, obj, flags);
    };
    kconst.ENODEV
};

/** A read-only fd on a copy of task `slot`'s environment (NAME=value, each NUL
 *  terminated): what vfs opens for /proc/self/environ.  The fd, or -errno. */
def fdt_open_environ(slot: long, flags: long) -> long {
    fdt_open_mem(slot, proc.proc_environ(slot), flags)
};

/** A read-only fd on the bytes of `data` (a snapshot).  The fd, or -errno. */
def fdt_open_mem(slot: long, data: str, flags: long) -> long {
    let i = 0;
    while (i < len(mf_live) && mf_live[i] != 0) { i = i + 1; };
    if (i == len(mf_live)) { mf_data += ""; mf_off += 0; mf_live += 0; };
    mf_data[i] = data;
    mf_off[i] = 0;
    mf_live[i] = 1;
    let n = fd_install(slot, kconst.NULL, 2 + i, flags & (0 - 1 - 3));
    if (n < 0) { mf_live[i] = 0; mf_data[i] = ""; };
    n
};

/** The size of a memory file (kind NULL, obj >= 2); 0 for /dev/null and /dev/zero. */
def fdt_mem_size(obj: long) -> long {
    if (obj < 2 || obj - 2 >= len(mf_live)) { return 0; };
    len(mf_data[obj - 2])
};

// ── lifecycle (sys.y) ───────────────────────────────────────────────────
def fdt_on_fork(parent: long, child: long) -> void {
    let pt = fdt_tbl(parent);
    fdt_grow(child);
    let t = tbl_new();
    slot_tbl[child] = t;
    let i = 0;
    while (i < FDMAX) {
        let o = tb_ofd[pt * FDMAX + i];
        if (o >= 0) {
            of_refs[o] = of_refs[o] + 1;
            tbl_set(t, i, o, tb_cx[pt * FDMAX + i]);
        };
        i = i + 1;
    };
};

/** `slot` (a new thread) uses `owner`'s table: CLONE_FILES.  Call INSTEAD of
 *  fdt_on_fork. */
def fdt_share(owner: long, slot: long) -> void {
    let t = fdt_tbl(owner);
    fdt_grow(slot);
    tb_refs[t] = tb_refs[t] + 1;
    slot_tbl[slot] = t;
};

def fdt_on_exec(slot: long) -> void {
    let t = fdt_tbl(slot);
    fdt_grow(slot);
    poll_dl[slot] = 0;
    let i = 0;
    while (i < FDMAX) {
        if (tb_ofd[t * FDMAX + i] >= 0 && tb_cx[t * FDMAX + i] != 0) {
            let o = tb_ofd[t * FDMAX + i];
            tb_ofd[t * FDMAX + i] = 0 - 1;
            tb_cx[t * FDMAX + i] = 0;
            of_put(o);
        };
        i = i + 1;
    };
};

def fdt_on_exit(slot: long) -> void {
    fdt_grow(slot);
    poll_dl[slot] = 0;
    let t = slot_tbl[slot];
    if (t < 0) { return; };
    slot_tbl[slot] = 0 - 1;
    tb_refs[t] = tb_refs[t] - 1;
    if (tb_refs[t] > 0) { return; };
    let i = 0;
    while (i < FDMAX) {
        let o = tb_ofd[t * FDMAX + i];
        if (o >= 0) {
            tb_ofd[t * FDMAX + i] = 0 - 1;
            of_put(o);
        };
        i = i + 1;
    };
};

// ── read / write ────────────────────────────────────────────────────────
/** The description for a data transfer of `cnt` bytes at `buf`, or the error
 *  (a TRANSITIONAL legacy answer is kernel.SYS_FALLBACK).  `want` is 0 for read
 *  (the description must not be write-only) or 1 for write. */
def xfer_of(n: long, buf: long, cnt: long, want: long) -> long {
    let o = fdt_of(kernel.task_slot(), n);
    if (o < 0) {
        if (fdt_legacy(n)) { return kernel.SYS_FALLBACK; };
        return o;
    };
    let acc = of_flags[o] & kconst.O_ACCMODE;
    if (want == 0 && acc == 1) { return kconst.EBADF; };
    if (want == 1 && acc == 0) { return kconst.EBADF; };
    if (cnt < 0) { return kconst.EINVAL; };
    if (cnt > 0 && !kernel.user_ok(buf, cnt)) { return kconst.EFAULT; };
    o
};

def sys_read(n: long, buf: long, cnt: long) -> long {
    if (proc.proc_check_pending()) { return 0; };
    let o = xfer_of(n, buf, cnt, 0);
    if (o < 0) { return o; };
    if (cnt == 0) { return 0; };
    fdt_kind_read(of_kind[o], of_obj[o], buf, cnt, of_flags[o])
};

def sys_write(n: long, buf: long, cnt: long) -> long {
    if (proc.proc_check_pending()) { return 0; };
    let o = xfer_of(n, buf, cnt, 1);
    if (o < 0) { return o; };
    if (cnt == 0) { return 0; };
    fdt_kind_write(of_kind[o], of_obj[o], buf, cnt, of_flags[o])
};

def sys_close(n: long) -> long {
    let slot = kernel.task_slot();
    let o = fdt_of(slot, n);
    if (o < 0) {
        if (fdt_legacy(n)) { return kernel.SYS_FALLBACK; };
        return o;
    };
    let t = fdt_tbl(slot);
    tb_ofd[t * FDMAX + n] = 0 - 1;
    tb_cx[t * FDMAX + n] = 0;
    of_put(o);
    0
};

/** Is `kind` a file the vfs seeks in? */
def kind_seekable(kind: long) -> bool { kind == kconst.FILE || kind == kconst.DIR };

def sys_lseek(n: long, off: long, whence: long) -> long {
    let o = fdt_of(kernel.task_slot(), n);
    if (o < 0) {
        if (fdt_legacy(n)) { return kernel.SYS_FALLBACK; };
        return o;
    };
    let kind = of_kind[o];
    if (kind_seekable(kind)) { return vfs.file_lseek(of_obj[o], off, whence); };
    if (kind == kconst.NULL) {
        if (of_obj[o] < 2) { return 0; };
        let i = of_obj[o] - 2;
        let base = 0;
        if (whence == 1) { base = mf_off[i]; };
        if (whence == 2) { base = len(mf_data[i]); };
        if (whence < 0 || whence > 2) { return kconst.EINVAL; };
        if (base + off < 0) { return kconst.EINVAL; };
        mf_off[i] = base + off;
        return mf_off[i];
    };
    kconst.ESPIPE
};

def sys_pread64(n: long, buf: long, cnt: long, off: long) -> long {
    let o = xfer_of(n, buf, cnt, 0);
    if (o < 0) { return o; };
    if (!kind_seekable(of_kind[o])) { return kconst.ESPIPE; };
    if (off < 0) { return kconst.EINVAL; };
    let ob = of_obj[o];
    let cur = vfs.file_lseek(ob, 0, 1);
    if (cur < 0) { return cur; };
    vfs.file_lseek(ob, off, 0);
    let r = fdt_kind_read(of_kind[o], ob, buf, cnt, of_flags[o]);
    vfs.file_lseek(ob, cur, 0);
    r
};

def sys_pwrite64(n: long, buf: long, cnt: long, off: long) -> long {
    let o = xfer_of(n, buf, cnt, 1);
    if (o < 0) { return o; };
    if (!kind_seekable(of_kind[o])) { return kconst.ESPIPE; };
    if (off < 0) { return kconst.EINVAL; };
    let ob = of_obj[o];
    let cur = vfs.file_lseek(ob, 0, 1);
    if (cur < 0) { return cur; };
    vfs.file_lseek(ob, off, 0);
    let r = fdt_kind_write(of_kind[o], ob, buf, cnt, of_flags[o]);
    vfs.file_lseek(ob, cur, 0);
    r
};

/** readv (want 0) / writev (want 1).  Once a byte has moved a later vector never
 *  blocks (it is offered O_NONBLOCK), so a restart never repeats a transfer. */
def iov_xfer(n: long, iov: long, cnt: long, want: long) -> long {
    if (cnt < 0 || cnt > 1024) { return kconst.EINVAL; };
    if (cnt == 0) { return 0; };
    if (!kernel.user_ok(iov, cnt * 16)) { return kconst.EFAULT; };
    let o = xfer_of(n, 0, 0, want);
    if (o < 0) { return o; };
    let total = 0;
    let i = 0;
    while (i < cnt) {
        let base = u_rd64(iov + i * 16);
        let l = u_rd64(iov + i * 16 + 8);
        if (l < 0 || (l > 0 && !kernel.user_ok(base, l))) {
            if (total > 0) { return total; };
            return kconst.EFAULT;
        };
        if (l > 0) {
            let fl = of_flags[o];
            if (total > 0) { fl = fl | kconst.O_NONBLOCK; };
            let r = 0;
            if (want == 0) { r = fdt_kind_read(of_kind[o], of_obj[o], base, l, fl); } else { r = fdt_kind_write(of_kind[o], of_obj[o], base, l, fl); };
            if (r < 0) {
                if (total > 0) { return total; };
                return r;
            };
            total = total + r;
            if (r < l) { return total; };
        };
        i = i + 1;
    };
    total
};

def sys_readv(n: long, iov: long, cnt: long) -> long {
    if (proc.proc_check_pending()) { return 0; };
    iov_xfer(n, iov, cnt, 0)
};

def sys_writev(n: long, iov: long, cnt: long) -> long {
    if (proc.proc_check_pending()) { return 0; };
    iov_xfer(n, iov, cnt, 1)
};

// ── ioctl, dup, fcntl ───────────────────────────────────────────────────
def sys_ioctl(n: long, req: long, arg: long) -> long {
    let slot = kernel.task_slot();
    let o = fdt_of(slot, n);
    if (o < 0) { return o; };
    if (req == 21537) {                       // FIONBIO
        if (!kernel.user_ok(arg, 4)) { return kconst.EFAULT; };
        if (u_rd32s(arg) != 0) { of_flags[o] = of_flags[o] | kconst.O_NONBLOCK; } else { of_flags[o] = of_flags[o] & (0 - 1 - kconst.O_NONBLOCK); };
        return 0;
    };
    if (req == 21585) { tb_cx[fdt_tbl(slot) * FDMAX + n] = 1; return 0; };   // FIOCLEX
    if (req == 21584) { tb_cx[fdt_tbl(slot) * FDMAX + n] = 0; return 0; };   // FIONCLEX
    fdt_kind_ioctl(of_kind[o], of_obj[o], req, arg)
};

/** Share description `o` as the lowest free fd >= `lo`, with the close-on-exec bit `cx`. */
def dup_at(slot: long, o: long, lo: long, cx: long) -> long {
    let t = fdt_tbl(slot);
    let m = tbl_free(t, lo);
    if (m < 0) { return m; };
    of_refs[o] = of_refs[o] + 1;
    tbl_set(t, m, o, cx);
    m
};

def sys_dup(n: long) -> long {
    let slot = kernel.task_slot();
    let o = fdt_of(slot, n);
    if (o < 0) { return o; };
    dup_at(slot, o, 0, 0)
};

def dup_to(oldfd: long, newfd: long, cx: long) -> long {
    let slot = kernel.task_slot();
    let o = fdt_of(slot, oldfd);
    if (o < 0) { return o; };
    if (newfd < 0 || newfd >= FDMAX) { return kconst.EBADF; };
    if (oldfd == newfd) { return newfd; };
    let t = fdt_tbl(slot);
    let prev = tb_ofd[t * FDMAX + newfd];
    of_refs[o] = of_refs[o] + 1;
    tbl_set(t, newfd, o, cx);
    if (prev >= 0) { of_put(prev); };
    newfd
};

def sys_dup2(oldfd: long, newfd: long) -> long { dup_to(oldfd, newfd, 0) };

def sys_dup3(oldfd: long, newfd: long, flags: long) -> long {
    if ((flags & (0 - 1 - kconst.O_CLOEXEC)) != 0) { return kconst.EINVAL; };
    if (oldfd == newfd) { return kconst.EINVAL; };
    dup_to(oldfd, newfd, if ((flags & kconst.O_CLOEXEC) != 0) { 1 } else { 0 })
};

def sys_fcntl(n: long, cmd: long, arg: long) -> long {
    let slot = kernel.task_slot();
    let o = fdt_of(slot, n);
    if (o < 0) { return o; };
    let t = fdt_tbl(slot);
    if (cmd == 0) { return dup_at(slot, o, arg, 0); };          // F_DUPFD
    if (cmd == 1030) { return dup_at(slot, o, arg, 1); };       // F_DUPFD_CLOEXEC
    if (cmd == 1) { return tb_cx[t * FDMAX + n]; };             // F_GETFD
    if (cmd == 2) { tb_cx[t * FDMAX + n] = arg & 1; return 0; };   // F_SETFD
    if (cmd == 3) { return of_flags[o]; };                      // F_GETFL
    if (cmd == 4) {                                             // F_SETFL
        let mask = kconst.O_NONBLOCK | kconst.O_APPEND;
        of_flags[o] = (of_flags[o] & (0 - 1 - mask)) | (arg & mask);
        return 0;
    };
    if (cmd == 5 || cmd == 6 || cmd == 7 || cmd == 8 || cmd == 9) { return 0; };   // locks, owner
    kconst.EINVAL
};

// ── poll, ppoll, select, pselect6 ───────────────────────────────────────
/** After a scan found nothing: `tmo_us` < 0 waits forever, 0 never waits.  Answers
 *  true when the call must return now with 0 ready, false when the task was
 *  put to sleep (the call re-executes when woken). */
def poll_idle(slot: long, tmo_us: long) -> bool {
    if (tmo_us == 0) { poll_dl[slot] = 0; return true; };
    let now = time.now_us();
    let dl = poll_dl[slot];
    if (dl == 0) {
        dl = 0 - 1;
        if (tmo_us > 0) { dl = now + tmo_us; };
        poll_dl[slot] = dl;
    };
    if (dl > 0 && now >= dl) { poll_dl[slot] = 0; return true; };
    let until = 0;
    if (dl > 0) { until = dl; };
    kernel.block_restart(fdt_chan(kconst.CH_POLL, 0), until);
    false
};

/** The timeout of ppoll/pselect6 (a timespec at `tsp`, 0 = forever) in microseconds, -1 forever. */
def ts_us(tsp: long) -> long {
    if (tsp == 0) { return 0 - 1; };
    u_rd64(tsp) * 1000000 + (u_rd64(tsp + 8) + 999) / 1000
};

def poll_scan(slot: long, fds: long, nfds: long) -> long {
    let ready = 0;
    let i = 0;
    while (i < nfds) {
        let w = u_rd64(fds + i * 8);
        let n = w & 4294967295;
        if (n >= 2147483648) { n = n - 4294967296; };
        let ev = (w >> 32) & 65535;
        let rev = 0;
        if (n >= 0) {
            let o = fdt_of(slot, n);
            if (o < 0) { rev = kconst.POLLNVAL; } else {
                rev = fdt_kind_poll(of_kind[o], of_obj[o], ev) & (ev | kconst.POLLERR | kconst.POLLHUP | kconst.POLLNVAL);
            };
        };
        u_wr64(fds + i * 8, (w & 281474976710655) | (rev << 48));
        if (rev != 0) { ready = ready + 1; };
        i = i + 1;
    };
    ready
};

def poll_common(fds: long, nfds: long, tmo_us: long) -> long {
    if (proc.proc_check_pending()) { return 0; };
    if (nfds < 0 || nfds > FD_SETSIZE) { return kconst.EINVAL; };
    if (nfds > 0 && !kernel.user_ok(fds, nfds * 8)) { return kconst.EFAULT; };
    let slot = kernel.task_slot();
    fdt_grow(slot);
    let ready = poll_scan(slot, fds, nfds);
    if (ready > 0) { poll_dl[slot] = 0; return ready; };
    if (poll_idle(slot, tmo_us)) { return 0; };
    0
};

def sys_poll(fds: long, nfds: long, timeout_ms: long) -> long {
    let t = 0 - 1;
    if (timeout_ms >= 0) { t = timeout_ms * 1000; };
    poll_common(fds, nfds, t)
};

def sys_ppoll(fds: long, nfds: long, tsp: long, sigmask: long, sigsetsize: long) -> long {
    poll_common(fds, nfds, ts_us(tsp))
};

/** The 16 words of the fd_set at `p` (all zero when p == 0). */
def sel_load(p: long) -> [long] {
    let w: [long] = [];
    let i = 0;
    while (i < 16) {
        if (p == 0) { w += 0; } else { w += u_rd64(p + i * 8); };
        i = i + 1;
    };
    w
};

def sel_store(p: long, w: [long]) -> void {
    if (p == 0) { return; };
    let i = 0;
    while (i < 16) { u_wr64(p + i * 8, w[i]); i = i + 1; };
};

def sel_bit(w: [long], n: long) -> bool { ((w[n >> 6] >> (n & 63)) & 1) != 0 };

def select_common(nfd: long, rfds: long, wfds: long, efds: long, tmo_us: long) -> long {
    if (proc.proc_check_pending()) { return 0; };
    if (nfd < 0 || nfd > FD_SETSIZE) { return kconst.EINVAL; };
    if ((rfds != 0 && !kernel.user_ok(rfds, 128)) || (wfds != 0 && !kernel.user_ok(wfds, 128)) || (efds != 0 && !kernel.user_ok(efds, 128))) { return kconst.EFAULT; };
    let slot = kernel.task_slot();
    fdt_grow(slot);
    let ri = sel_load(rfds);
    let wi = sel_load(wfds);
    let ei = sel_load(efds);
    let ro = sel_load(0);
    let wo = sel_load(0);
    let eo = sel_load(0);
    let ready = 0;
    let n = 0;
    while (n < nfd) {
        let r = sel_bit(ri, n);
        let w = sel_bit(wi, n);
        let e = sel_bit(ei, n);
        if (r || w || e) {
            let o = fdt_of(slot, n);
            if (o < 0) { poll_dl[slot] = 0; return o; };
            let ev = 0;
            if (r) { ev = ev | kconst.POLLIN; };
            if (w) { ev = ev | kconst.POLLOUT; };
            if (e) { ev = ev | kconst.POLLPRI; };
            let rev = fdt_kind_poll(of_kind[o], of_obj[o], ev);
            let bit = 1 << (n & 63);
            if (r && (rev & (kconst.POLLIN | kconst.POLLHUP | kconst.POLLERR)) != 0) { ro[n >> 6] = ro[n >> 6] | bit; ready = ready + 1; };
            if (w && (rev & (kconst.POLLOUT | kconst.POLLERR)) != 0) { wo[n >> 6] = wo[n >> 6] | bit; ready = ready + 1; };
            if (e && (rev & kconst.POLLPRI) != 0) { eo[n >> 6] = eo[n >> 6] | bit; ready = ready + 1; };
        };
        n = n + 1;
    };
    if (ready > 0 || poll_idle(slot, tmo_us)) {
        poll_dl[slot] = 0;
        sel_store(rfds, ro);
        sel_store(wfds, wo);
        sel_store(efds, eo);
        return ready;
    };
    0
};

def sys_select(n: long, rfds: long, wfds: long, efds: long, tv: long) -> long {
    let t = 0 - 1;
    if (tv != 0) { t = u_rd64(tv) * 1000000 + u_rd64(tv + 8); };
    select_common(n, rfds, wfds, efds, t)
};

def sys_pselect6(n: long, rfds: long, wfds: long, efds: long, tsp: long, sig: long) -> long {
    select_common(n, rfds, wfds, efds, ts_us(tsp))
};

// ── the kconst.NULL kind's ops (obj 0 = /dev/null, 1 = /dev/zero, 2.. memory files) ──
def null_read(obj: long, buf: long, cnt: long, flags: long) -> long {
    if (obj == 1) {
        kernel.kzero(buf, cnt);
        return cnt;
    };
    if (obj >= 2) {
        let i = obj - 2;
        let s = mf_data[i];
        let left = len(s) - mf_off[i];
        if (left <= 0) { return 0; };
        let k = cnt;
        if (k > left) { k = left; };
        let j = 0;
        while (j < k) { kernel.poke_va8(buf + j, byte_at(s, mf_off[i] + j)); j = j + 1; };
        mf_off[i] = mf_off[i] + k;
        return k;
    };
    0
};
def null_write(obj: long, buf: long, cnt: long, flags: long) -> long {
    if (obj >= 2) { return kconst.EBADF; };
    cnt
};
def null_ioctl(obj: long, req: long, arg: long) -> long { kconst.ENOTTY };
def null_poll(obj: long, events: long) -> long { events & (kconst.POLLIN | kconst.POLLOUT) };
def null_close(obj: long) -> long {
    if (obj >= 2) { mf_live[obj - 2] = 0; mf_data[obj - 2] = ""; };
    0
};

// ── the per-kind switch (kept here so the routing is one place) ──────────────
def fdt_kind_read(kind: long, obj: long, buf: long, cnt: long, flags: long) -> long {
    if (kind == kconst.FILE || kind == kconst.DIR) { return vfs.file_read(obj, buf, cnt, flags); };
    if (kind == kconst.TTY) {
        let r = tty.tty_read(obj, buf, cnt, flags);
        if (r == kconst.ENOSYS) { return kernel.sys_read(0, buf, cnt); };
        return r;
    };
    if (kind == kconst.PIPE_R || kind == kconst.PIPE_W) { return pipe.pipe_read(obj, buf, cnt, flags); };
    if (kind == kconst.SOCK) { return unix.sock_read(obj, buf, cnt, flags); };
    if (kind == kconst.DSP) { return dsp.dsp_read(obj, buf, cnt, flags); };
    if (kind == kconst.INPUT) { return fbdev.input_read(obj, buf, cnt, flags); };
    if (kind == kconst.NULL) { return null_read(obj, buf, cnt, flags); };
    kconst.EBADF
};

def fdt_kind_write(kind: long, obj: long, buf: long, cnt: long, flags: long) -> long {
    if (kind == kconst.FILE || kind == kconst.DIR) { return vfs.file_write(obj, buf, cnt, flags); };
    if (kind == kconst.TTY) {
        let r = tty.tty_write(obj, buf, cnt, flags);
        if (r == kconst.ENOSYS) { return kernel.sys_write(1, buf, cnt); };
        return r;
    };
    if (kind == kconst.PIPE_R || kind == kconst.PIPE_W) { return pipe.pipe_write(obj, buf, cnt, flags); };
    if (kind == kconst.SOCK) { return unix.sock_write(obj, buf, cnt, flags); };
    if (kind == kconst.DSP) { return dsp.dsp_write(obj, buf, cnt, flags); };
    if (kind == kconst.FB) { return fbdev.fb_write(obj, buf, cnt, flags); };
    if (kind == kconst.NULL) { return null_write(obj, buf, cnt, flags); };
    kconst.EBADF
};

def fdt_kind_ioctl(kind: long, obj: long, req: long, arg: long) -> long {
    if (kind == kconst.FILE || kind == kconst.DIR) { return vfs.file_ioctl(obj, req, arg); };
    if (kind == kconst.TTY) { return tty.tty_ioctl(obj, req, arg); };
    if (kind == kconst.PIPE_R || kind == kconst.PIPE_W) { return pipe.pipe_ioctl(obj, req, arg); };
    if (kind == kconst.SOCK) { return unix.sock_ioctl(obj, req, arg); };
    if (kind == kconst.DSP) { return dsp.dsp_ioctl(obj, req, arg); };
    if (kind == kconst.FB) { return fbdev.fb_ioctl(obj, req, arg); };
    if (kind == kconst.INPUT) { return fbdev.input_ioctl(obj, req, arg); };
    if (kind == kconst.NULL) { return null_ioctl(obj, req, arg); };
    kconst.EBADF
};

def fdt_kind_poll(kind: long, obj: long, events: long) -> long {
    if (kind == kconst.FILE || kind == kconst.DIR) { return vfs.file_poll(obj, events); };
    if (kind == kconst.TTY) { return tty.tty_poll(obj, events); };
    if (kind == kconst.PIPE_R || kind == kconst.PIPE_W) { return pipe.pipe_poll(obj, events); };
    if (kind == kconst.SOCK) { return unix.sock_poll(obj, events); };
    if (kind == kconst.DSP) { return dsp.dsp_poll(obj, events); };
    if (kind == kconst.INPUT) { return fbdev.input_poll(obj, events); };
    if (kind == kconst.FB) { return events & kconst.POLLOUT; };
    if (kind == kconst.NULL) { return null_poll(obj, events); };
    kconst.POLLNVAL
};

def fdt_kind_close(kind: long, obj: long) -> long {
    if (kind == kconst.FILE || kind == kconst.DIR) { return vfs.file_close(obj); };
    if (kind == kconst.TTY) { return tty.tty_close(obj); };
    if (kind == kconst.PIPE_R || kind == kconst.PIPE_W) { return pipe.pipe_close(obj); };
    if (kind == kconst.SOCK) { return unix.sock_close(obj); };
    if (kind == kconst.DSP) { return dsp.dsp_close(obj); };
    if (kind == kconst.FB) { return fbdev.fb_close(obj); };
    if (kind == kconst.INPUT) { return 0; };
    if (kind == kconst.NULL) { return null_close(obj); };
    kconst.EBADF
};
