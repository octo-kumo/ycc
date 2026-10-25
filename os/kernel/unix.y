// unix -- AF_UNIX SOCK_STREAM sockets.
//
// A socket is an index (the `obj` of a kconst.SOCK description) into parallel
// arrays.  Two connected sockets each own a 16 KB receive ring that the OTHER
// writes into; reads and writes block with kernel.block_restart on
// fdt.fdt_chan(kconst.SOCK, id) and the peer wakes them with fdt.fdt_notify.
// accept blocks on fdt_chan(kconst.CH_ACCEPT, listener).
//
// States: 0 free, 1 fresh (socket(2) made it), 2 listening, 3 connected.  A
// connected socket whose peer is gone has sk_peer = -1: reads drain the ring and
// then answer 0, writes answer -EPIPE.  A bound name is a socket node made by
// vfs.vfs_mknod_sock; a listener is found by that node's inode, so closing the
// listener leaves a stale node that refuses connections (as on Linux).
import kernel;
import kconst from "./kconst.y";
import fdt from "./fdt.y";
import vfs from "./vfs.y";
import proc from "./proc.y";

const SK_MAX = 48;
const SK_CAP = 16384;
const SK_QMAX = 8;
const SK_EISCONN = 0 - 106;
const SK_EADDRINUSE = 0 - 98;
const SK_EPROTONOSUPPORT = 0 - 93;
const SK_ESOCKTNOSUPPORT = 0 - 94;
const SK_EDESTADDRREQ = 0 - 89;

let sk_st: [long] = [];
let sk_peer: [long] = [];
let sk_ino: [long] = [];
let sk_name: [str] = [];
let sk_head: [long] = [];
let sk_cnt: [long] = [];
let sk_shut: [long] = [];
let sk_qn: [long] = [];
let sk_back: [long] = [];
let sk_q: [long] = [];
let sk_buf: [[byte]] = [];

def sk_ensure() -> void {
    if (len(sk_st) >= SK_MAX) { return; };
    while (len(sk_st) < SK_MAX) {
        sk_st += 0;
        sk_peer += -1;
        sk_ino += -1;
        sk_name += "";
        sk_head += 0;
        sk_cnt += 0;
        sk_shut += 0;
        sk_qn += 0;
        sk_back += 0;
        let empty: [byte] = [];
        sk_buf += empty;
        let j = 0;
        while (j < SK_QMAX) { sk_q += -1; j = j + 1; };
    };
};

def sk_min(a: long, b: long) -> long { if (a < b) { a } else { b } };

/** A fresh socket id, or -1. */
def sk_alloc() -> long {
    sk_ensure();
    let i = 0;
    while (i < SK_MAX) {
        if (sk_st[i] == 0) {
            sk_st[i] = 1;
            sk_peer[i] = -1;
            sk_ino[i] = -1;
            sk_name[i] = "";
            sk_head[i] = 0;
            sk_cnt[i] = 0;
            sk_shut[i] = 0;
            sk_qn[i] = 0;
            sk_back[i] = 0;
            return i;
        };
        i = i + 1;
    };
    -1
};

/** Give socket `i` its (reused) ring, empty. */
def sk_ring(i: long) -> void {
    if (len(sk_buf[i]) == 0) {
        let b: [byte] = [0];
        let k = 0;
        while (k < 14) { b = b + b; k = k + 1; };
        sk_buf[i] = b;
    };
    sk_head[i] = 0;
    sk_cnt[i] = 0;
};

/** Connect `a` and `b` to each other. */
def sk_link(a: long, b: long) -> void {
    sk_ring(a);
    sk_ring(b);
    sk_peer[a] = b;
    sk_peer[b] = a;
    sk_st[a] = 3;
    sk_st[b] = 3;
    sk_shut[a] = 0;
    sk_shut[b] = 0;
};

/** Copy `n` user bytes at `buf` into the end of socket `d`'s ring. */
def sk_push(d: long, buf: long, n: long) -> void {
    let base = ptr_addr(&sk_buf[d][0]);
    let tail = (sk_head[d] + sk_cnt[d]) % SK_CAP;
    let first = sk_min(n, SK_CAP - tail);
    kernel.kcopy(base + tail, buf, first);
    if (n > first) { kernel.kcopy(base, buf + first, n - first); };
    sk_cnt[d] = sk_cnt[d] + n;
};

/** Copy `n` bytes from the front of socket `s`'s ring to user `buf`. */
def sk_pull(s: long, buf: long, n: long) -> void {
    let base = ptr_addr(&sk_buf[s][0]);
    let first = sk_min(n, SK_CAP - sk_head[s]);
    kernel.kcopy(buf, base + sk_head[s], first);
    if (n > first) { kernel.kcopy(buf + first, base, n - first); };
    sk_head[s] = (sk_head[s] + n) % SK_CAP;
    sk_cnt[s] = sk_cnt[s] - n;
};

/** True when reads on connected `i` will never get more than the ring holds. */
def sk_eof(i: long) -> bool {
    let p = sk_peer[i];
    if (p < 0) { return true; };
    ((sk_shut[p] & 2) != 0) || ((sk_shut[i] & 1) != 0)
};

/** True when writes on connected `i` can never succeed. */
def sk_broken(i: long) -> bool {
    let p = sk_peer[i];
    if (p < 0) { return true; };
    ((sk_shut[i] & 2) != 0) || ((sk_shut[p] & 1) != 0)
};

// ── the non-blocking cores: bytes moved, or -EAGAIN when they would block ──
def sk_read_try(obj: long, buf: long, n: long) -> long {
    if (obj < 0 || obj >= SK_MAX || sk_st[obj] == 0) { return kconst.EBADF; };
    if (sk_st[obj] != 3) { return kconst.ENOTCONN; };
    if (n <= 0) { return 0; };
    let c = sk_cnt[obj];
    if (c > 0) {
        let k = sk_min(c, n);
        sk_pull(obj, buf, k);
        if (sk_peer[obj] >= 0) { fdt.fdt_notify(kconst.SOCK, sk_peer[obj]); };
        return k;
    };
    if (sk_eof(obj)) { return 0; };
    kconst.EAGAIN
};

def sk_write_try(obj: long, buf: long, n: long) -> long {
    if (obj < 0 || obj >= SK_MAX || sk_st[obj] == 0) { return kconst.EBADF; };
    if (sk_st[obj] != 3) { return kconst.ENOTCONN; };
    if (sk_broken(obj)) { return kconst.EPIPE; };
    if (n <= 0) { return 0; };
    let p = sk_peer[obj];
    let room = SK_CAP - sk_cnt[p];
    if (room <= 0) { return kconst.EAGAIN; };
    let k = sk_min(n, room);
    sk_push(p, buf, k);
    fdt.fdt_notify(kconst.SOCK, p);
    k
};

// ── the fd-kind ops ─────────────────────────────────────────────────────
def sock_read(obj: long, buf: long, n: long, flags: long) -> long {
    sk_ensure();
    let r = sk_read_try(obj, buf, n);
    if (r == kconst.EAGAIN && (flags & kconst.O_NONBLOCK) == 0) {
        return kernel.block_restart(fdt.fdt_chan(kconst.SOCK, obj), 0);
    };
    r
};

def sock_write(obj: long, buf: long, n: long, flags: long) -> long {
    sk_ensure();
    let r = sk_write_try(obj, buf, n);
    if (r == kconst.EAGAIN && (flags & kconst.O_NONBLOCK) == 0) {
        return kernel.block_restart(fdt.fdt_chan(kconst.SOCK, obj), 0);
    };
    r
};

def sock_ioctl(obj: long, req: long, arg: long) -> long {
    sk_ensure();
    if (req == 21531) {
        // FIONREAD
        if (!kernel.user_ok(arg, 4)) { return kconst.EFAULT; };
        kernel.poke_va32(arg, sk_cnt[obj]);
        return 0;
    };
    // FIONBIO: the description's flag is fdt's (fcntl); accept it
    if (req == 21537) { return 0; };
    0 - 25
};

def sock_poll(obj: long, events: long) -> long {
    sk_ensure();
    if (obj < 0 || obj >= SK_MAX) { return kconst.POLLNVAL; };
    let st = sk_st[obj];
    let r = 0;
    if (st == 2) {
        if (sk_qn[obj] > 0) { r = r | kconst.POLLIN; };
    } else if (st == 3) {
        if (sk_cnt[obj] > 0) { r = r | kconst.POLLIN; };
        if (sk_eof(obj)) { r = r | kconst.POLLIN; };
        if (sk_peer[obj] < 0) { r = r | kconst.POLLHUP | kconst.POLLOUT; }
        else if (sk_broken(obj)) { r = r | kconst.POLLERR; }
        else if (sk_cnt[sk_peer[obj]] < SK_CAP) { r = r | kconst.POLLOUT; };
    } else if (st == 1) {
        r = kconst.POLLOUT;
    };
    r & (events | kconst.POLLERR | kconst.POLLHUP)
};

def sock_close(obj: long) -> long {
    sk_ensure();
    if (obj < 0 || obj >= SK_MAX || sk_st[obj] == 0) { return 0; };
    if (sk_st[obj] == 2) {
        // a listener: the connections nobody accepted are closed with it
        let j = 0;
        while (j < sk_qn[obj]) {
            let q = sk_q[obj * SK_QMAX + j];
            if (q >= 0) { sock_close(q); };
            j = j + 1;
        };
    };
    let p = sk_peer[obj];
    if (p >= 0 && sk_st[p] == 3) {
        sk_peer[p] = -1;
        fdt.fdt_notify(kconst.SOCK, p);
    };
    sk_st[obj] = 0;
    sk_peer[obj] = -1;
    sk_ino[obj] = -1;
    sk_name[obj] = "";
    sk_cnt[obj] = 0;
    sk_qn[obj] = 0;
    // a task parked in accept on a listener that just went
    kernel.wake_chan(fdt.fdt_chan(kconst.CH_ACCEPT, obj));
    fdt.fdt_notify(kconst.SOCK, obj);
    0
};

// ── user memory helpers ─────────────────────────────────────────────────
def sk_rd32(a: long) -> long {
    kernel.peek_va8(a) | (kernel.peek_va8(a + 1) << 8) | (kernel.peek_va8(a + 2) << 16) | (kernel.peek_va8(a + 3) << 24)
};

/** The sun_path of the sockaddr_un at `addr` (`alen` bytes) as a str; "" when it
 *  is not a usable pathname (too short, abstract, a different family). */
def sk_addr_path(addr: long, alen: long) -> str {
    if (alen < 3 || !kernel.user_ok(addr, alen)) { return ""; };
    if (kernel.peek_va8(addr) != 1 || kernel.peek_va8(addr + 1) != 0) { return ""; };
    let n = sk_min(alen, 110) - 2;
    let b: [byte] = [];
    let i = 0;
    while (i < n) {
        let c = kernel.peek_va8(addr + 2 + i);
        if (c == 0) { i = n; } else { b += c; i = i + 1; };
    };
    from_bytes(b)
};

/** Write a sockaddr_un naming `name` ("" = unnamed) to `addr`, and its length
 *  to the u32 at `alp` (truncating to the space the caller offered). */
def sk_put_addr(addr: long, alp: long, name: str) -> void {
    if (addr == 0 || alp == 0 || !kernel.user_ok(alp, 4)) { return; };
    let have = sk_rd32(alp);
    let total = 2;
    if (len(name) > 0) { total = 2 + len(name) + 1; };
    let n = sk_min(have, total);
    if (n > 0 && kernel.user_ok(addr, n)) {
        let i = 0;
        while (i < n) {
            let c = 0;
            if (i == 0) { c = 1; }
            else if (i >= 2 && i - 2 < len(name)) { c = name[i - 2] & 255; };
            kernel.poke_va8(addr + i, c);
            i = i + 1;
        };
    };
    kernel.poke_va32(alp, total);
};

/** The socket id behind `fd` of the current task, or a negative errno. */
def sk_of(fd: long) -> long {
    sk_ensure();
    let slot = kernel.task_slot();
    let k = fdt.fd_kind(slot, fd);
    if (k < 0) { return k; };
    if (k != kconst.SOCK) { return kconst.ENOTSOCK; };
    fdt.fd_obj(slot, fd)
};

/** The description's status flags for `fd` (O_NONBLOCK ...). */
def sk_fl(fd: long) -> long {
    let f = fdt.fd_flags(kernel.task_slot(), fd);
    if (f < 0) { 0 } else { f }
};

/** The listener bound to node `ino`, or -1. */
def sk_find_listener(ino: long) -> long {
    let i = 0;
    while (i < SK_MAX) {
        if (sk_st[i] == 2 && sk_ino[i] == ino) { return i; };
        i = i + 1;
    };
    -1
};

// ── syscalls ────────────────────────────────────────────────────────────
def sys_socket(domain: long, stype: long, protocol: long) -> long {
    sk_ensure();
    if (domain != 1) { return kconst.EAFNOSUPPORT; };
    if ((stype & 255) != 1) { return SK_ESOCKTNOSUPPORT; };
    if (protocol != 0) { return SK_EPROTONOSUPPORT; };
    let id = sk_alloc();
    if (id < 0) { return kconst.ENOMEM; };
    // SOCK_NONBLOCK 0x800 and SOCK_CLOEXEC 0x80000 are O_NONBLOCK and O_CLOEXEC
    let fd = fdt.fd_install(kernel.task_slot(), kconst.SOCK, id, stype & (kconst.O_NONBLOCK | kconst.O_CLOEXEC));
    if (fd < 0) { sock_close(id); };
    fd
};

def sys_socketpair(domain: long, stype: long, protocol: long, sv: long) -> long {
    sk_ensure();
    if (domain != 1) { return kconst.EAFNOSUPPORT; };
    if ((stype & 255) != 1) { return SK_ESOCKTNOSUPPORT; };
    if (!kernel.user_ok(sv, 8)) { return kconst.EFAULT; };
    let a = sk_alloc();
    let b = sk_alloc();
    if (a < 0 || b < 0) {
        if (a >= 0) { sock_close(a); };
        return kconst.ENOMEM;
    };
    sk_link(a, b);
    let slot = kernel.task_slot();
    let fl = stype & (kconst.O_NONBLOCK | kconst.O_CLOEXEC);
    let fa = fdt.fd_install(slot, kconst.SOCK, a, fl);
    if (fa < 0) { sock_close(a); sock_close(b); return fa; };
    let fb = fdt.fd_install(slot, kconst.SOCK, b, fl);
    if (fb < 0) { fdt.sys_close(fa); sock_close(b); return fb; };
    kernel.poke_va32(sv, fa);
    kernel.poke_va32(sv + 4, fb);
    0
};

def sys_bind(fd: long, addr: long, addrlen: long) -> long {
    let id = sk_of(fd);
    if (id < 0) { return id; };
    if (sk_st[id] != 1 || sk_ino[id] >= 0) { return kconst.EINVAL; };
    let path = sk_addr_path(addr, addrlen);
    if (path == "") { return kconst.EINVAL; };
    let ino = vfs.vfs_mknod_sock(kernel.task_slot(), path);
    if (ino == kconst.EEXIST) { return SK_EADDRINUSE; };
    if (ino < 0) { return ino; };
    sk_ino[id] = ino;
    sk_name[id] = path;
    0
};

def sys_listen(fd: long, backlog: long) -> long {
    let id = sk_of(fd);
    if (id < 0) { return id; };
    if (sk_st[id] == 2) { return 0; };
    if (sk_st[id] != 1 || sk_ino[id] < 0) { return kconst.EINVAL; };
    let b = backlog;
    if (b < 1) { b = 1; };
    if (b > SK_QMAX) { b = SK_QMAX; };
    sk_back[id] = b;
    sk_qn[id] = 0;
    sk_st[id] = 2;
    0
};

def sk_accept(fd: long, addr: long, alp: long, flags: long) -> long {
    let id = sk_of(fd);
    if (id < 0) { return id; };
    if (sk_st[id] != 2) { return kconst.EINVAL; };
    if (sk_qn[id] == 0) {
        if ((sk_fl(fd) & kconst.O_NONBLOCK) != 0) { return kconst.EAGAIN; };
        return kernel.block_restart(fdt.fdt_chan(kconst.CH_ACCEPT, id), 0);
    };
    let s2 = sk_q[id * SK_QMAX];
    let nfd = fdt.fd_install(kernel.task_slot(), kconst.SOCK, s2, flags & (kconst.O_NONBLOCK | kconst.O_CLOEXEC));
    if (nfd < 0) { return nfd; };
    let j = 1;
    while (j < sk_qn[id]) {
        sk_q[id * SK_QMAX + j - 1] = sk_q[id * SK_QMAX + j];
        j = j + 1;
    };
    sk_qn[id] = sk_qn[id] - 1;
    sk_q[id * SK_QMAX + sk_qn[id]] = -1;
    // a connect parked on a full queue may go now
    kernel.wake_chan(fdt.fdt_chan(kconst.CH_ACCEPT, id));
    sk_put_addr(addr, alp, "");
    nfd
};

def sys_accept(fd: long, addr: long, addrlen: long) -> long { sk_accept(fd, addr, addrlen, 0) };
def sys_accept4(fd: long, addr: long, addrlen: long, flags: long) -> long { sk_accept(fd, addr, addrlen, flags) };

def sys_connect(fd: long, addr: long, addrlen: long) -> long {
    let id = sk_of(fd);
    if (id < 0) { return id; };
    if (sk_st[id] == 3) { return SK_EISCONN; };
    if (sk_st[id] != 1) { return kconst.EINVAL; };
    let path = sk_addr_path(addr, addrlen);
    if (path == "") { return kconst.EINVAL; };
    let slot = kernel.task_slot();
    let ino = vfs.vfs_lookup(proc.cwd_ino(slot), path);
    if (ino < 0) { return kconst.ENOENT; };
    let l = sk_find_listener(ino);
    if (l < 0) { return kconst.ECONNREFUSED; };
    if (sk_qn[l] >= sk_back[l]) {
        if ((sk_fl(fd) & kconst.O_NONBLOCK) != 0) { return kconst.EAGAIN; };
        return kernel.block_restart(fdt.fdt_chan(kconst.CH_ACCEPT, l), 0);
    };
    let s2 = sk_alloc();
    if (s2 < 0) { return kconst.ECONNREFUSED; };
    sk_link(id, s2);
    sk_name[s2] = sk_name[l];
    sk_q[l * SK_QMAX + sk_qn[l]] = s2;
    sk_qn[l] = sk_qn[l] + 1;
    kernel.wake_chan(fdt.fdt_chan(kconst.CH_ACCEPT, l));
    fdt.fdt_notify(kconst.SOCK, l);
    0
};

def sys_sendto(fd: long, buf: long, n: long, flags: long, addr: long, addrlen: long) -> long {
    let id = sk_of(fd);
    if (id < 0) { return id; };
    if (n < 0 || !kernel.user_ok(buf, n)) { return kconst.EFAULT; };
    let fl = sk_fl(fd);
    if ((flags & 64) != 0) { fl = fl | kconst.O_NONBLOCK; };
    sock_write(id, buf, n, fl)
};

def sys_recvfrom(fd: long, buf: long, n: long, flags: long, addr: long, addrlen: long) -> long {
    let id = sk_of(fd);
    if (id < 0) { return id; };
    if (n < 0 || !kernel.user_ok(buf, n)) { return kconst.EFAULT; };
    let fl = sk_fl(fd);
    if ((flags & 64) != 0) { fl = fl | kconst.O_NONBLOCK; };
    let r = sock_read(id, buf, n, fl);
    if (r >= 0) { sk_put_addr(addr, addrlen, ""); };
    r
};

/** sendmsg/recvmsg over the msghdr's iovecs (no ancillary data); `out` writes. */
def sk_msg(fd: long, msg: long, flags: long, out: bool) -> long {
    let id = sk_of(fd);
    if (id < 0) { return id; };
    if (!kernel.user_ok(msg, 56)) { return kconst.EFAULT; };
    let iov = kernel.peek_va64(msg + 16);
    let cnt = kernel.peek_va64(msg + 24);
    if (cnt < 0 || cnt > 1024 || !kernel.user_ok(iov, cnt * 16)) { return kconst.EFAULT; };
    let fl = sk_fl(fd);
    if ((flags & 64) != 0) { fl = fl | kconst.O_NONBLOCK; };
    let total = 0;
    let j = 0;
    let stop = false;
    while (j < cnt && !stop) {
        let base = kernel.peek_va64(iov + j * 16);
        let n = kernel.peek_va64(iov + j * 16 + 8);
        if (n > 0) {
            if (!kernel.user_ok(base, n)) {
                if (total == 0) { return kconst.EFAULT; };
                stop = true;
            } else {
                let r = 0;
                if (out) { r = sk_write_try(id, base, n); } else { r = sk_read_try(id, base, n); };
                if (r < 0) {
                    if (total > 0) { stop = true; }
                    else if (r == kconst.EAGAIN && (fl & kconst.O_NONBLOCK) == 0) {
                        return kernel.block_restart(fdt.fdt_chan(kconst.SOCK, id), 0);
                    } else { return r; };
                } else {
                    total = total + r;
                    if (r < n) { stop = true; };
                };
            };
        };
        j = j + 1;
    };
    if (!out) {
        kernel.poke_va32(msg + 8, 0);
        kernel.poke_va64(msg + 40, 0);
        kernel.poke_va32(msg + 48, 0);
    };
    total
};

def sys_sendmsg(fd: long, msg: long, flags: long) -> long { sk_msg(fd, msg, flags, true) };
def sys_recvmsg(fd: long, msg: long, flags: long) -> long { sk_msg(fd, msg, flags, false) };

def sys_shutdown(fd: long, how: long) -> long {
    let id = sk_of(fd);
    if (id < 0) { return id; };
    if (how < 0 || how > 2) { return kconst.EINVAL; };
    if (sk_st[id] != 3) { return kconst.ENOTCONN; };
    if (how == 0 || how == 2) { sk_shut[id] = sk_shut[id] | 1; };
    if (how == 1 || how == 2) { sk_shut[id] = sk_shut[id] | 2; };
    fdt.fdt_notify(kconst.SOCK, id);
    if (sk_peer[id] >= 0) { fdt.fdt_notify(kconst.SOCK, sk_peer[id]); };
    0
};

def sys_getsockname(fd: long, addr: long, addrlen: long) -> long {
    let id = sk_of(fd);
    if (id < 0) { return id; };
    sk_put_addr(addr, addrlen, sk_name[id]);
    0
};

def sys_getpeername(fd: long, addr: long, addrlen: long) -> long {
    let id = sk_of(fd);
    if (id < 0) { return id; };
    if (sk_st[id] != 3 || sk_peer[id] < 0) { return kconst.ENOTCONN; };
    sk_put_addr(addr, addrlen, sk_name[sk_peer[id]]);
    0
};

def sys_setsockopt(fd: long, level: long, name: long, val: long, n: long) -> long {
    let id = sk_of(fd);
    if (id < 0) { return id; };
    0
};

def sys_getsockopt(fd: long, level: long, name: long, val: long, optlen: long) -> long {
    let id = sk_of(fd);
    if (id < 0) { return id; };
    if (val == 0 || optlen == 0 || !kernel.user_ok(val, 4) || !kernel.user_ok(optlen, 4)) { return kconst.EFAULT; };
    let v = 0;
    // SOL_SOCKET: SO_TYPE 3 (stream), SO_SNDBUF 7 / SO_RCVBUF 8; SO_ERROR 4 and the rest 0
    if (level == 1 && name == 3) { v = 1; };
    if (level == 1 && (name == 7 || name == 8)) { v = SK_CAP; };
    kernel.poke_va32(val, v);
    kernel.poke_va32(optlen, 4);
    0
};
