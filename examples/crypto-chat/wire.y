// wire.y -- the transport underneath the crypto.
//
// Three pipe2(2) pairs between two forked processes, a 5-byte frame header, and
// a log of every byte that crossed a pipe so the property check can prove that
// no plaintext ever left a process in the clear.
//
// ── two shapes of Y that shape every signature here ─────────────────────────
//
// 1. pipe2(2) writes its two descriptors as two C `int`s.  Read back as two
//    64-bit `long`s, element 0 comes back holding BOTH fds packed together
//    (0x400000003) and element 1 comes back 0 -- which is *stdin*, so the "peer"
//    is stdin and the program hangs with no error anywhere.
//    `mkpipe` assembles the two descriptors from a byte buffer, 4 bytes at a
//    time.  (ORCHESTRATOR.md §2.13.)
//
// 2. There is no pointer arithmetic -- `p + n` where `p: *byte` is
//    `error: '+' left operand: expected long, got *byte` -- and a `[byte; N]`
//    does not unify with `[byte]` (`error: 'rd_buf' arg 1: expected [byte],
//    got [byte; 16]`).  So a read or write helper cannot take a `*byte` and
//    walk it; it takes the fixed-size array *by name* and addresses bytes as
//    &buf[i] with an index it owns.  FRAME is therefore one number for the
//    whole example, and there is exactly one pair of read/write helpers rather
//    than one per buffer size.  See README, "Compiler workarounds", item 1.

// One frame buffer's size.  A chat frame is 5 (header) + 9 (payload header) +
// a sealed message; the longest chat line is 60 bytes, so 1024 is generous.
const FRAME = 1024;

// The frame header: one kind byte and a 4-byte little-endian payload length.
const HDR = 5;

// The chat payload header that follows it: seq(4) dir(4) atk(1) = 9 bytes.
const PHDR = 9;

// Frame kinds.
const K_PUB = 1;       // a 32-byte X25519 public point
const K_MSG = 2;       // a sealed chat message

// The one pipe descriptor pair this example ever needs.
type Pipe = { rd: long, wr: long };

// ── pipes ────────────────────────────────────────────────────────────────

// pipe2(2), syscall 293, flags 0.  Returns {0,0} when the call fails; the
// caller checks with `pipe_ok`.
def mkpipe() -> Pipe {
    let fds: [byte; 8] = [0; 8];
    let rc = syscall(293, &fds[0], 0);
    let p: Pipe = { rd: 0, wr: 0 };
    if (rc != 0) { return p; };
    // The kernel wrote int fds[2] -- 8 bytes -- so read it back as bytes.
    p.rd = fds[0] + fds[1] * 256 + fds[2] * 65536 + fds[3] * 16777216;
    p.wr = fds[4] + fds[5] * 256 + fds[6] * 65536 + fds[7] * 16777216;
    p
};

def pipe_ok(p: Pipe) -> bool { p.rd >= 3 && p.wr == p.rd + 1 };

// ── exact reads and writes ───────────────────────────────────────────────
//
// A pipe's read(2) returns what is there, not what was asked for, so both of
// these loop until the whole range has moved.  A short write would truncate a
// frame and desynchronise the peer for good, so it is an error, not a retry.

def wr_all(fd: long, buf: [byte; 1024], off: long, n: long) -> long {
    let i = off;
    let end = off + n;
    while (i < end) {
        let k = syscall(1, fd, &buf[i], end - i);
        if (k <= 0) { return -1; };
        i = i + k;
    };
    n
};

def rd_all(fd: long, buf: [byte; 1024], off: long, n: long) -> long {
    let i = off;
    let end = off + n;
    while (i < end) {
        let k = syscall(0, fd, &buf[i], end - i);
        if (k <= 0) { return -1; };
        i = i + k;
    };
    n
};

// ── little-endian scalars and buffer staging ──────────────────────────────

def put32(buf: [byte; 1024], off: long, v: long) -> void {
    buf[off] = v & 255;
    buf[off + 1] = (v >>> 8) & 255;
    buf[off + 2] = (v >>> 16) & 255;
    buf[off + 3] = (v >>> 24) & 255;
};

def get32(buf: [byte; 1024], off: long) -> long {
    buf[off] + buf[off + 1] * 256 + buf[off + 2] * 65536 + buf[off + 3] * 16777216
};

// Copy a string's bytes straight into a fixed buffer.  `s[i]` is a byte, so
// this costs no allocation -- which matters, because the alternative,
// `bytes(s)` then a copy loop, puts the whole string on the heap every call.
def put_str(buf: [byte; 1024], off: long, s: str) -> void {
    let i = 0;
    while (i < len(s)) { buf[off + i] = s[i]; i = i + 1; };
};

def put_bytes(buf: [byte; 1024], off: long, b: [byte]) -> void {
    let i = 0;
    while (i < len(b)) { buf[off + i] = b[i]; i = i + 1; };
};

def get_bytes(buf: [byte; 1024], off: long, n: long) -> [byte] { buf[off:off + n] };

// ── framing ──────────────────────────────────────────────────────────────
//
// Every frame on every pipe is [kind(1) len(4)] [payload(len)].  The chat
// payload is [seq(4) dir(4) atk(1)] [sealed].  `atk` is the sender's own
// account of what forgery it committed, and it is deliberately *outside* the
// authenticated data: the receiver's rejection never depends on it.

// Write a frame header into buf[0..5) and return the payload offset.
def put_hdr(buf: [byte; 1024], kind: long, n: long) -> long {
    buf[0] = kind;
    put32(buf, 1, n);
    HDR
};

def get_kind(buf: [byte; 1024]) -> long { buf[0] };
def get_len(buf: [byte; 1024]) -> long { get32(buf, 1) };

// ── the wire log ─────────────────────────────────────────────────────────
//
// One per process, one per direction: the child logs every byte it read on the
// a->b pipe, the parent every byte it read on the b->a pipe.  Every frame on
// both pipes is therefore logged exactly once, byte for byte as it crossed.
//
// `LOG` is a module-level array, so it is one heap cell created at _start and
// mutated in place -- the same pattern std/crypto.y's K256 table uses.  It is
// empty in both processes at the moment of fork(2), so parent and child never
// share it.

let LOG: [byte] = [];

def log_reset() { LOG = []; };

// Append bytes exactly as they crossed the pipe.  `LOG += b` is the array
// interface (there is no `push`), and it is amortised O(1) because an array
// doubles its capacity.
def log_bytes_buf(buf: [byte; 1024], off: long, n: long) { LOG += buf[off:off + n]; };

def log_len() -> long { len(LOG) };

// The index of the first occurrence of `needle` in the log at or after `from`,
// or -1.  A plain substring search; `props.y` calls it to prove that no
// plaintext is anywhere in the bytes that crossed.
def log_find(from: long, needle: [byte]) -> long {
    let nl = len(needle);
    let total = len(LOG);
    if (nl == 0) { return from; };
    if (from < 0 || nl > total - from) { return -1; };
    let i = from;
    while (i + nl <= total) {
        let j = 0;
        let same = true;
        while (j < nl && same) {
            if (LOG[i + j] != needle[j]) { same = false; };
            j = j + 1;
        };
        if (same) { return i; };
        i = i + 1;
    };
    -1
};

export { FRAME, HDR, PHDR, K_PUB, K_MSG, Pipe, mkpipe, pipe_ok, wr_all, rd_all, put32, get32, put_str, put_bytes, get_bytes, put_hdr, get_kind, get_len, log_reset, log_bytes_buf, log_len, log_find };