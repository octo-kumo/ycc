// packstub.y -- the self-decompressing stub `ycc --pack` puts in front of a
import hostos from "./host_linux.y";
import zlib;

// ── syscalls ─────────────────────────────────────────────────────────────
// Linux syscall identities, translated to the stub's own architecture.
let SYS_READ = if (hostos.is_arm()) { 63 } else { 0 };
let SYS_WRITE = if (hostos.is_arm()) { 64 } else { 1 };
let SYS_CLOSE = if (hostos.is_arm()) { 57 } else { 3 };
let SYS_LSEEK = if (hostos.is_arm()) { 62 } else { 8 };
let SYS_EXECVE = if (hostos.is_arm()) { 221 } else { 59 };
let SYS_OPENAT = if (hostos.is_arm()) { 56 } else { 257 };
let SYS_MEMFD = if (hostos.is_arm()) { 279 } else { 319 };
let SYS_EXECVEAT = if (hostos.is_arm()) { 281 } else { 322 };
let SYS_FCNTL = if (hostos.is_arm()) { 25 } else { 72 };
let AT_FDCWD = -100;
let AT_EMPTY_PATH = 4096;
let MFD_CLOEXEC = 1;
let SEEK_END = 2;
let ENOSYS = 38;

def pack_magic() -> str {
    "YCCPACK2"
};

// The environment block's slice at the bottom of the argv buffer (the buffer
// itself is 256 KiB, the same order as meta.y's fabricated stack).
let ENV_CAP = 65536;

// ── small helpers ────────────────────────────────────────────────────────

// `s` as a NUL-terminated byte string, for a syscall argument.
def cbytes(s: str) -> [byte] {
    let b = bytes(s);
    b += 0;
    b
};

def die(msg: str) -> long {
    eputs("ycpack: " + msg + "\n");
    exit(1);
    0
};

// Eight decimal digits at `at` of `b`, or -1 when they are not digits.
def dec8(b: [byte], at: long) -> long {
    let v = 0;
    let i = 0;
    while (i < 8) {
        let c = b[at + i];
        if (c < 48 || c > 57) { return -1; };
        v = v * 10 + (c - 48);
        i = i + 1;
    };
    v
};

// Four bytes at `at`, least significant first (ycc.y le32).
def rd32(b: [byte], at: long) -> long {
    b[at] + b[at + 1] * 256 + b[at + 2] * 65536 + b[at + 3] * 16777216
};

// `n` bytes of `fd` at `off`, or [] when the read did not finish.
def read_at(fd: long, off: long, n: long) -> [byte] {
    let b: [byte] = [];
    let i = 0;
    while (i < n) {
        b += 0;
        i = i + 1;
    };
    syscall(SYS_LSEEK, fd, off, 0);
    let got = 0;
    while (got < n) {
        let k = syscall(SYS_READ, fd, ptr_addr(&b[got]), n - got);
        if (k <= 0) { got = -1; } else { got += k; };
    };
    if (got < 0) { [] } else { b }
};

// ── method 3: native.y's LZ tokens ───────────────────────────────────────
def lz_decode(b: [byte]) -> [byte] {
    let out: [byte] = [];
    let at = 0;
    let n = b.length;
    while (at < n) {
        let t = b[at];
        at += 1;
        let ll = t >> 4;
        let mh = t & 15;
        if (ll == 15) {
            let go = true;
            while (go) {
                if (at >= n) { return []; };
                let x = b[at];
                at += 1;
                ll += x;
                go = x == 255;
            };
        };
        if (at + ll > n) { return []; };
        out += b[at:at + ll];
        at += ll;
        if (at >= n) { return out; };
        if (at + 2 > n) { return []; };
        let moff = b[at] + b[at + 1] * 256;
        at += 2;
        let mlen = mh + 4;
        if (mh == 15) {
            let go = true;
            while (go) {
                if (at >= n) { return []; };
                let x = b[at];
                at += 1;
                mlen += x;
                go = x == 255;
            };
        };
        if (moff == 0 || moff > out.length) { return []; };
        let k = 0;
        while (k < mlen) {
            out += out[out.length - moff];
            k = k + 1;
        };
    };
    out
};

// ── the payload ──────────────────────────────────────────────────────────

// The packed file's own bytes at `[off, off+16)`: the trailer.
def read_trailer() -> [byte] {
    let p = cbytes("/proc/self/exe");
    let fd = syscall(SYS_OPENAT, AT_FDCWD, ptr_addr(&p[0]), 0, 0);
    if (fd < 0) { return []; };
    let size = syscall(SYS_LSEEK, fd, 0, SEEK_END);
    let out: [byte] = [];
    if (size >= 16) {
        let tail = read_at(fd, size - 16, 16);
        syscall(SYS_CLOSE, fd, 0, 0, 0, 0);
        if (tail.length == 16) { out = tail; };
    } else {
        syscall(SYS_CLOSE, fd, 0, 0, 0, 0);
    };
    out
};

// The decoded payload image, or [] plus `why` set.
def decode_payload(why: [str]) -> [byte] {
    let trailer = read_trailer();
    if (trailer.length != 16 || from_bytes(trailer[8:16]) != pack_magic()) {
        why[0] = "not a packed binary (no " + pack_magic() + " trailer)";
        return [];
    };
    let n = dec8(trailer, 0);
    if (n <= 0) {
        why[0] = "bad payload length in the trailer";
        return [];
    };
    let p = cbytes("/proc/self/exe");
    let fd = syscall(SYS_OPENAT, AT_FDCWD, ptr_addr(&p[0]), 0, 0);
    if (fd < 0) {
        why[0] = "cannot open /proc/self/exe";
        return [];
    };
    let size = syscall(SYS_LSEEK, fd, 0, SEEK_END);
    if (n > size - 16) {
        syscall(SYS_CLOSE, fd, 0, 0, 0, 0);
        why[0] = "the payload runs past the end of the file";
        return [];
    };
    let body = read_at(fd, size - 16 - n, n);
    syscall(SYS_CLOSE, fd, 0, 0, 0, 0);
    if (body.length != n) {
        why[0] = "cannot read the payload";
        return [];
    };
    let method = body[0];
    if (body.length < 5) {
        why[0] = "the payload frame is too short";
        return [];
    };
    let raw_len = rd32(body, 1);
    let data = body[5:body.length];
    let img: [byte] = [];
    if (method == 0) {
        img = data;
    } else if (method == 1 || method == 2) {
        let out = zlib.inflate(data, raw_len);
        if (out == none) {
            why[0] = "inflate failed";
            return [];
        };
        img = unwrap(out);
    } else if (method == 3) {
        img = lz_decode(data);
    } else {
        why[0] = "unknown method " + tostring(method);
        return [];
    };
    if (img.length != raw_len) {
        why[0] = "decoded " + tostring(img.length) + " bytes, expected " + tostring(raw_len);
        return [];
    };
    img
};

// ── running it ───────────────────────────────────────────────────────────

// argv as a NUL-terminated C string vector inside `buf`, and the same for
// envp from /proc/self/environ, then execveat the image in `fd`. Never
// returns on success.
def exec_image(fd: long, img: [byte], av: [str]) -> long {
    let buf: [byte; 262144] = [0; 262144];
    let base = ptr_addr(&buf[0]);
    let p = base + 262144;
    // the environment block at the bottom of the buffer; NAME=value entries
    // are already NUL-separated, so the pointers come from a scan
    let envptrs: [long] = [];
    // named, not a temporary: the pointer handed to the syscall must outlive
    // the expression that built it
    let envpath = cbytes("/proc/self/environ");
    let ef = syscall(SYS_OPENAT, AT_FDCWD, ptr_addr(&envpath[0]), 0, 0);
    if (ef >= 0) {
        let ep = p - ENV_CAP;
        let got = syscall(SYS_READ, ef, ep, ENV_CAP);
        syscall(SYS_CLOSE, ef, 0, 0, 0, 0);
        let i = 0;
        while (i < got) {
            if (buf[ep - base + i] == 0) {
                i += 1;
            } else {
                envptrs += ep + i;
                while (i < got && buf[ep - base + i] != 0) { i += 1; };
            };
        };
        p = ep;
    };
    // the command line, copied so that growing a Y array cannot move a string
    // a pointer already names
    let aps: [long] = [];
    let k = 0;
    while (k < av.length) {
        let s = av[k];
        let n = len(s);
        p = p - n - 1;
        let q = p - base;
        let j = 0;
        while (j < n) {
            buf[q + j] = s[j];
            j = j + 1;
        };
        buf[q + n] = 0;
        aps += p;
        k = k + 1;
    };
    let argv2: [long] = [];
    foreach (x in aps) { argv2 += x; };
    argv2 += 0;
    let env2: [long] = [];
    foreach (x in envptrs) { env2 += x; };
    env2 += 0;
    let zero: [byte; 1] = [0; 1];
    let r = syscall(SYS_EXECVEAT, fd, ptr_addr(&zero[0]), ptr_addr(&argv2[0]), ptr_addr(&env2[0]), AT_EMPTY_PATH);
    if (r == -ENOSYS || r == -2) {
        // binfmt_misc interpreters may need to open the descriptor after
        // exec. Retry ENOENT without CLOEXEC as well as the old-kernel path.
        syscall(SYS_FCNTL, fd, 2, 0);
        // a kernel without execveat(2): /proc/self/fd names the memfd
        let path = cbytes("/proc/self/fd/" + tostring(fd));
        r = syscall(SYS_EXECVE, ptr_addr(&path[0]), ptr_addr(&argv2[0]), ptr_addr(&env2[0]), 0);
    };
    if (r < 0) { die("cannot run the payload (" + tostring(r) + ")") } else { 1 }
};

def main(av: [str]) -> long {
    let why: [str] = [""];
    let img = decode_payload(why);
    if (img.length == 0) {
        if (why[0] == "") { die("the payload is empty") } else { die(why[0]) }
    } else {
        let nm = cbytes("ycpack");
        let fd = syscall(SYS_MEMFD, ptr_addr(&nm[0]), MFD_CLOEXEC);
        if (fd < 0) {
            die("memfd_create failed (" + tostring(fd) + ")")
        } else {
            let off = 0;
            let at = ptr_addr(&img[0]);
            while (off < img.length) {
                let k = syscall(SYS_WRITE, fd, at + off, img.length - off);
                if (k <= 0) { return die("writing the payload failed"); };
                off += k;
            };
            exec_image(fd, img, av)
        }
    }
};

// All decoder scratch is bounded by this payload's input/output. Nothing
// survives exec (or process exit); the launcher itself needs no collector.
region { main(argv()); }
