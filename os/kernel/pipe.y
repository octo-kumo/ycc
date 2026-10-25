// pipe -- anonymous pipes.
//
// A pipe is a 64 KB ring in kernel pages and two counters of open ends.  A
// description's obj is id * 2 + end (end 0 reads, 1 writes); fdt runs pipe_close
// once per description, so a fork or a dup never closes an end early.
//
//   read   data: take it, wake the writers.  Empty: 0 once no writer is left (EOF),
//          else -EAGAIN (O_NONBLOCK) or sleep on fdt_chan(PIPE_R, id).
//   write  no reader: SIGPIPE (kills unless ignored) and -EPIPE.  A write of at
//          most PIPE_BUF waits for room for ALL of it; a longer one copies what
//          fits and sleeps for the rest.  The bytes copied before a sleep are kept in
//          pp_prog[slot] so the restarted call carries on where it stopped.
import kernel;
import kconst from "./kconst.y";
import fdt from "./fdt.y";
import proc from "./proc.y";

const PIPE_SZ = 65536;
const PIPE_BUF = 4096;

let pp_buf: [long] = [];
let pp_rd: [long] = [];
let pp_cnt: [long] = [];
let pp_rdrs: [long] = [];
let pp_wrs: [long] = [];
let pp_prog: [long] = [];

def pipe_new() -> long {
    let buf = kernel.pages_alloc_va(PIPE_SZ);
    if (buf == 0) { return kconst.ENOMEM; };
    kernel.acct_add(kernel.ACCT_PIPE, PIPE_SZ);
    let id = 0;
    while (id < len(pp_buf) && pp_buf[id] != 0) { id = id + 1; };
    if (id == len(pp_buf)) { pp_buf += 0; pp_rd += 0; pp_cnt += 0; pp_rdrs += 0; pp_wrs += 0; };
    pp_buf[id] = buf;
    pp_rd[id] = 0;
    pp_cnt[id] = 0;
    pp_rdrs[id] = 1;
    pp_wrs[id] = 1;
    id
};

def sys_pipe(fds: long) -> long { sys_pipe2(fds, 0) };

def sys_pipe2(fds: long, flags: long) -> long {
    if ((flags & (0 - 1 - (kconst.O_CLOEXEC | kconst.O_NONBLOCK))) != 0) { return kconst.EINVAL; };
    if (!kernel.user_ok(fds, 8)) { return kconst.EFAULT; };
    let slot = kernel.task_slot();
    let id = pipe_new();
    if (id < 0) { return id; };
    let keep = flags & (kconst.O_CLOEXEC | kconst.O_NONBLOCK);
    let r = fdt.fd_install(slot, kconst.PIPE_R, id * 2, keep);
    if (r < 0) {
        pipe_close(id * 2);
        pipe_close(id * 2 + 1);
        return r;
    };
    let w = fdt.fd_install(slot, kconst.PIPE_W, id * 2 + 1, keep | 1);
    if (w < 0) {
        fdt.sys_close(r);
        pipe_close(id * 2 + 1);
        return w;
    };
    kernel.poke_va32(fds, r);
    kernel.poke_va32(fds + 4, w);
    0
};

def pp_grow(slot: long) -> void {
    while (len(pp_prog) <= slot) { pp_prog += 0; };
};

/** A slot starts or ends a task: forget the previous one's partial write. */
def pipe_on_task(slot: long) -> void {
    pp_grow(slot);
    pp_prog[slot] = 0;
};

def pipe_read(obj: long, buf: long, cnt: long, flags: long) -> long {
    let id = obj >> 1;
    let have = pp_cnt[id];
    if (have == 0) {
        if (pp_wrs[id] == 0) { return 0; };
        if ((flags & kconst.O_NONBLOCK) != 0) { return kconst.EAGAIN; };
        return kernel.block_restart(fdt.fdt_chan(kconst.PIPE_R, id), 0);
    };
    let n = cnt;
    if (n > have) { n = have; };
    let rd = pp_rd[id];
    let first = PIPE_SZ - rd;
    if (first > n) { first = n; };
    kernel.kcopy(buf, pp_buf[id] + rd, first);
    if (n > first) { kernel.kcopy(buf + first, pp_buf[id], n - first); };
    pp_rd[id] = (rd + n) % PIPE_SZ;
    pp_cnt[id] = have - n;
    fdt.fdt_notify(kconst.PIPE_W, id);
    n
};

def pipe_write(obj: long, buf: long, cnt: long, flags: long) -> long {
    let id = obj >> 1;
    let slot = kernel.task_slot();
    pp_grow(slot);
    let done = pp_prog[slot];
    if (pp_rdrs[id] == 0) {
        pp_prog[slot] = 0;
        proc.proc_sigpipe();
        return kconst.EPIPE;
    };
    let rem = cnt - done;
    let space = PIPE_SZ - pp_cnt[id];
    let nb = (flags & kconst.O_NONBLOCK) != 0;
    if (rem <= PIPE_BUF && space < rem) {
        // all or nothing for a small write
        if (nb) { pp_prog[slot] = 0; return kconst.EAGAIN; };
        return kernel.block_restart(fdt.fdt_chan(kconst.PIPE_W, id), 0);
    };
    let n = rem;
    if (n > space) { n = space; };
    if (n > 0) {
        let wr = (pp_rd[id] + pp_cnt[id]) % PIPE_SZ;
        let first = PIPE_SZ - wr;
        if (first > n) { first = n; };
        kernel.kcopy(pp_buf[id] + wr, buf + done, first);
        if (n > first) { kernel.kcopy(pp_buf[id], buf + done + first, n - first); };
        pp_cnt[id] = pp_cnt[id] + n;
        done = done + n;
        fdt.fdt_notify(kconst.PIPE_R, id);
    };
    if (done >= cnt) { pp_prog[slot] = 0; return cnt; };
    if (nb) {
        pp_prog[slot] = 0;
        if (done > 0) { return done; };
        return kconst.EAGAIN;
    };
    pp_prog[slot] = done;
    kernel.block_restart(fdt.fdt_chan(kconst.PIPE_W, id), 0)
};

def pipe_ioctl(obj: long, req: long, arg: long) -> long {
    if (req == 21531) {                                  // FIONREAD
        if (!kernel.user_ok(arg, 4)) { return kconst.EFAULT; };
        kernel.poke_va32(arg, pp_cnt[obj >> 1]);
        return 0;
    };
    kconst.ENOTTY
};

/** revents for `events` (kconst.POLLIN/POLLOUT/POLLHUP/POLLERR). */
def pipe_poll(obj: long, events: long) -> long {
    let id = obj >> 1;
    let rev = 0;
    if ((obj & 1) == 0) {
        if (pp_cnt[id] > 0) { rev = rev | kconst.POLLIN; };
        if (pp_wrs[id] == 0) { rev = rev | kconst.POLLHUP; };
    } else {
        if (pp_rdrs[id] == 0) { rev = rev | kconst.POLLERR; } else if (PIPE_SZ - pp_cnt[id] >= PIPE_BUF) { rev = rev | kconst.POLLOUT; };
    };
    rev & (events | kconst.POLLERR | kconst.POLLHUP)
};

def pipe_close(obj: long) -> long {
    let id = obj >> 1;
    if ((obj & 1) == 0) {
        pp_rdrs[id] = pp_rdrs[id] - 1;
        fdt.fdt_notify(kconst.PIPE_W, id);
    } else {
        pp_wrs[id] = pp_wrs[id] - 1;
        fdt.fdt_notify(kconst.PIPE_R, id);
    };
    if (pp_rdrs[id] == 0 && pp_wrs[id] == 0) {
        let base = pp_buf[id] - kernel.DIRECT_BASE;
        let i = 0;
        while (i < PIPE_SZ / 4096) { kernel.page_free(base + i * 4096); i = i + 1; };
        pp_buf[id] = 0;
        pp_cnt[id] = 0;
        kernel.acct_add(kernel.ACCT_PIPE, 0 - PIPE_SZ);
    };
    0
};
