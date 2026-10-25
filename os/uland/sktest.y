// sktest [dir-prefix] -- exercise AF_UNIX stream sockets (kernel/unix.y; runs on Linux too).
//
// Prints "ok NAME" or "FAIL NAME ..." for each check.  The socket nodes are made at
// "<prefix>sk.sock" and "<prefix>sk2.sock" (prefix default "/").
import ulib;

const SYS_POLL = 7;
const SYS_SOCKET = 41;
const SYS_CONNECT = 42;
const SYS_ACCEPT = 43;
const SYS_SENDTO = 44;
const SYS_RECVFROM = 45;
const SYS_SENDMSG = 46;
const SYS_RECVMSG = 47;
const SYS_SHUTDOWN = 48;
const SYS_BIND = 49;
const SYS_LISTEN = 50;
const SYS_GETSOCKNAME = 51;
const SYS_SOCKETPAIR = 53;
const SYS_SETSOCKOPT = 54;
const SYS_ACCEPT4 = 288;
const NONBLOCK = 2048;
const DONTWAIT = 64;
const EAGAIN = -11;
const EPIPE = -32;

def report(name: str, ok: bool, got: long) -> void {
    if (ok) { puts("ok " + name + "\n"); } else { puts("FAIL " + name + " got " + tostring(got) + "\n"); };
};

def sockaddr(path: str) -> [byte] {
    let a: [byte] = [1, 0];
    let i = 0;
    while (i < len(path)) { a += path[i] & 255; i = i + 1; };
    a += 0;
    a
};

def stream(flags: long) -> long { syscall(SYS_SOCKET, 1, 1 | flags, 0) };

def bind_to(fd: long, path: str) -> long {
    let a = sockaddr(path);
    syscall(SYS_BIND, fd, &a[0], len(a))
};

def connect_to(fd: long, path: str) -> long {
    let a = sockaddr(path);
    syscall(SYS_CONNECT, fd, &a[0], len(a))
};

def send(fd: long, s: str) -> long {
    let b = ulib.cstr(s);
    syscall(SYS_SENDTO, fd, &b[0], len(s), 16384, 0, 0)
};

/** Up to `n` bytes as a str ("" at end of stream); a negative errno in `err`. */
def recv(fd: long, n: long, flags: long, err: [long]) -> str {
    let b: [byte; 256] = [0; 256];
    let r = syscall(SYS_RECVFROM, fd, &b[0], n, flags, 0, 0);
    err[0] = r;
    if (r <= 0) { return ""; };
    let out = "";
    let i = 0;
    while (i < r) { out += chr(b[i]); i = i + 1; };
    out
};

/** poll one fd for `ev` with timeout 0: its revents (or a negative errno). */
def poll1(fd: long, ev: long) -> long {
    let pf: [byte; 8] = [0; 8];
    pf[0] = fd & 255;
    pf[4] = ev;
    let r = syscall(SYS_POLL, &pf[0], 1, 0);
    if (r < 0) { r } else { pf[6] | (pf[7] << 8) }
};

def client(path: str) -> long {
    let c = stream(0);
    if (connect_to(c, path) != 0) { return 1; };
    send(c, "hello");
    let err = [0];
    if (recv(c, 16, 0, err) != "HELLO") { return 2; };
    // 100000 bytes: far more than a socket buffer holds, so this blocks and resumes
    let blk: [byte; 5000] = [0; 5000];
    let n = 0;
    while (n < 100000) {
        let i = 0;
        while (i < 5000) { blk[i] = (n + i) & 255; i = i + 1; };
        let off = 0;
        while (off < 5000) {
            let r = syscall(SYS_SENDTO, c, &blk[off], 5000 - off, 0, 0, 0);
            if (r <= 0) { return 3; };
            off = off + r;
        };
        n = n + 5000;
    };
    syscall(SYS_SHUTDOWN, c, 1);
    // the server closes after reading everything: end of stream for us
    if (recv(c, 16, 0, err) != "" || err[0] != 0) { return 4; };
    0
};

let a = argv();
let prefix = if (len(a) > 1) { a[1] } else { "/" };
let p1 = prefix + "sk.sock";
let p2 = prefix + "sk2.sock";
ulib.unlink(p1);
ulib.unlink(p2);
let err = [0];

// bind, listen, refusals
let srv = stream(0);
report("socket", srv >= 0, srv);
report("bind", bind_to(srv, p1) == 0, 0);
let dup = stream(0);
let twice = bind_to(dup, p1);
report("bind twice -> EADDRINUSE", twice == -98, twice);
report("listen", syscall(SYS_LISTEN, srv, 4) == 0, 0);
let nowhere = connect_to(stream(0), prefix + "nosuch.sock");
report("connect nowhere -> ENOENT", nowhere == -2, nowhere);
let nm: [byte; 64] = [0; 64];
let nl: [long; 1] = [64];
report("getsockname", syscall(SYS_GETSOCKNAME, srv, &nm[0], &nl[0]) == 0 && nl[0] == len(p1) + 3 && nm[0] == 1, nl[0]);
report("accept on a plain socket -> EINVAL", syscall(SYS_ACCEPT, dup, 0, 0) < 0, 0);
report("bad family", syscall(SYS_SOCKET, 99, 1, 0) < 0, 0);
let one: [long; 1] = [1];
report("setsockopt", syscall(SYS_SETSOCKOPT, srv, 1, 2, &one[0], 4) == 0, 0);

// a client process: blocking accept, echo, a 100000-byte stream, EOF
let pid = ulib.fork();
if (pid == 0) { exit(client(p1)); };
let cfd = syscall(SYS_ACCEPT, srv, 0, 0);
report("accept", cfd >= 0, cfd);
let got = recv(cfd, 16, 0, err);
report("recv hello", got == "hello", err[0]);
report("send HELLO", send(cfd, "HELLO") == 5, 0);
let total = 0;
let bad = 0;
let big: [byte; 4096] = [0; 4096];
let more = true;
while (more) {
    let r = syscall(SYS_RECVFROM, cfd, &big[0], 4096, 0, 0, 0);
    if (r <= 0) { more = false; }
    else {
        let i = 0;
        while (i < r) {
            if (big[i] != (total + i) & 255) { bad = bad + 1; };
            i = i + 1;
        };
        total = total + r;
    };
};
report("100000 bytes, in order", total == 100000 && bad == 0, total);
syscall(3, cfd);
let st: [long; 1] = [0];
let w = syscall(61, pid, &st[0], 0, 0);
report("client finished", w == pid && ((st[0] >> 8) & 255) == 0, (st[0] >> 8) & 255);
syscall(3, srv);

// a non-blocking listener, and both ends in one process
let l2 = stream(NONBLOCK);
bind_to(l2, p2);
syscall(SYS_LISTEN, l2, 1);
report("accept4 would block -> EAGAIN", syscall(SYS_ACCEPT4, l2, 0, 0, NONBLOCK) == EAGAIN, 0);
report("poll listener idle", poll1(l2, 1) == 0, poll1(l2, 1));
let cl = stream(0);
report("connect", connect_to(cl, p2) == 0, 0);
report("poll listener ready", poll1(l2, 1) == 1, poll1(l2, 1));
let sv2 = syscall(SYS_ACCEPT4, l2, 0, 0, NONBLOCK);
report("accept4", sv2 >= 0, sv2);
report("poll empty socket", poll1(sv2, 1) == 0, poll1(sv2, 1));
report("poll writable", poll1(sv2, 4) == 4, poll1(sv2, 4));
report("recv would block -> EAGAIN", syscall(SYS_RECVFROM, sv2, &big[0], 4, DONTWAIT, 0, 0) == EAGAIN, 0);
send(cl, "abc");
report("poll readable", poll1(sv2, 1) == 1, poll1(sv2, 1));
report("recv abc", recv(sv2, 16, 0, err) == "abc", err[0]);

// sendmsg / recvmsg with two iovecs
let m1 = ulib.cstr("foo");
let m2 = ulib.cstr("barbaz");
let iov: [long; 4] = [ptr_addr(&m1[0]), 3, ptr_addr(&m2[0]), 6];
let msg: [long; 7] = [0, 0, ptr_addr(&iov[0]), 2, 0, 0, 0];
report("sendmsg", syscall(SYS_SENDMSG, cl, &msg[0], 0) == 9, 0);
let r1: [byte; 4] = [0; 4];
let r2: [byte; 16] = [0; 16];
let riov: [long; 4] = [ptr_addr(&r1[0]), 4, ptr_addr(&r2[0]), 16];
let rmsg: [long; 7] = [0, 0, ptr_addr(&riov[0]), 2, 0, 0, 0];
let rn = syscall(SYS_RECVMSG, sv2, &rmsg[0], 0);
report("recvmsg", rn == 9 && r1[0] == 102 && r1[3] == 98 && r2[0] == 97 && r2[4] == 122, rn);

// the peer goes: end of stream, then EPIPE
syscall(SYS_SHUTDOWN, cl, 1);
report("shutdown(WR) -> EOF for the peer", syscall(SYS_RECVFROM, sv2, &big[0], 4, 0, 0, 0) == 0, 0);
report("poll after EOF", (poll1(sv2, 1) & 1) == 1, poll1(sv2, 1));
syscall(3, cl);
report("write to a closed peer -> EPIPE", send(sv2, "x") == EPIPE, send(sv2, "x"));
report("poll hangup", (poll1(sv2, 1) & 16) != 0, poll1(sv2, 1));
syscall(3, sv2);
syscall(3, l2);
report("connect to a closed listener -> ECONNREFUSED", connect_to(stream(0), p2) == -111, 0);

// socketpair
let sv: [long; 1] = [0];
report("socketpair", syscall(SYS_SOCKETPAIR, 1, 1, 0, &sv[0]) == 0, 0);
let fa = sv[0] & 4294967295;
let fb = sv[0] >> 32;
send(fa, "ping");
report("socketpair recv", recv(fb, 16, 0, err) == "ping", err[0]);
send(fb, "pong");
report("socketpair back", recv(fa, 16, 0, err) == "pong", err[0]);
ulib.unlink(p1);
ulib.unlink(p2);
exit(0);
