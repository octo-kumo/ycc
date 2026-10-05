// httpc.y -- a minimal HTTP/1.1 GET client that does not allocate.
//
//   import httpc;
//
//   if (httpc.get(port, "/api/stats") != 200) { ... };
//   let p = json.get(httpc.buf(), 0, 65536, "served");
//
// One request per call, one connection, `Connection: close`: the whole
// response lands in this module's own 64 KiB buffer and the results are
// offsets into it. Nothing is built as a string, no array is made, no
// record is created -- a poll in a frame loop costs zero bytes of heap,
// which is the whole point (the heap is an arena, nothing is freed).
//
// ── why not std `http.get` ───────────────────────────────────────────
//
// It works, and --self-test uses it to cross-check this client byte for
// byte. But it costs **about 42 KiB of heap per request**, measured on the
// pinned compiler: 200 requests through an http.session() grew heap_used()
// by 8 352 536 bytes, and 20 through http.get() by 851 200. Nothing is
// ever freed, so a dashboard polling at 10 fps would exhaust the 3.5 GiB
// cap in under an hour. Both numbers are reproduced by --self-test, which
// prints them, and the std client stays the honest, obvious choice for a
// one-shot request.
//
// ── the buffer convention ────────────────────────────────────────────
//
// `buf` is 65536 bytes and json.y's functions take `b: [byte; 65536]`, so
// the two modules hand each other the same fixed-size type and the
// compiler refuses a mismatch. It is the document buffer and the response
// buffer in one: head at the front, body behind it.

const BUFSZ = 65536;
const REQSZ = 1024;          // the request we send, with room to spare
const PORT_OFF = 0;          // where the learned port lands in req
const REQBODY = 256;         // request bytes start here
const MODE_OFF = 4;          // byte 4 of req: 0 virtual clock, 1 real
const ERRMSG_OFF = 8;        // a child's errno rides back in bytes 8..15

let buf: [byte; 65536] = [0; 65536];
let req: [byte; 1024] = [0; 1024];
let sa: [byte; 16] = [0; 16];

// ── what the last call found ──────────────────────────────────────────
let status = 0;              // the status code, 0 if nothing came
let reason = 0;              // bytes of the reason phrase
let clen = -1;               // the Content-Length the server declared
let head_len = 0;            // bytes of head, CRLFCRLF included
let body_off = 0;            // where the body starts in buf
let body_len = 0;            // how many body bytes actually arrived
let err = 0;                 // 0, or the negative errno that stopped us
let hdr_at = 0;              // hdr_off / hdr_len: a header's value
let hdr_len = 0;

let digits: [byte; 24] = [0; 24];   // module level: wnum's scratch, so a
                                     // number costs no allocation at all
let req_len = 0;

// ── writing ───────────────────────────────────────────────────────────

def w_str(p: long, s: str) -> long {
    let n = len(s);
    let i = 0;
    while (i < n) { req[p + i] = s[i]; i = i + 1; };
    p + n
};

// a decimal long, written into req. Hoisted scratch on purpose: a literal
// array inside a per-request function costs 64 bytes a call here (there
// is no free), so the buffer lives at module level and is reused.
def w_num(p: long, v: long) -> long {
    let n = 0;
    let x = v;
    let neg = x < 0;
    if (neg) { x = 0 - x; };
    if (x == 0) { digits[0] = 48; n = 1; };
    while (x > 0) {
        digits[n] = 48 + (x % 10);
        n = n + 1;
        x = x / 10;
    };
    if (neg) { req[p] = 45; p = p + 1; };
    let i = 0;
    while (i < n) { req[p + i] = digits[n - 1 - i]; i = i + 1; };
    p + n
};

def lower(c: long) -> long {
    if (c >= 65 && c <= 90) { c + 32 } else { c }
};

// byte-equal, case-insensitively -- header names are case-insensitive
// (RFC 9110 5.1) and a client that is not will break on a real server.
def same_nocase(a: [byte; 65536], ai: long, s: str, n: long) -> bool {
    let same = true;
    let i = 0;
    while (i < n) {
        if (lower(a[ai + i]) != lower(s[i])) { same = false; };
        i = i + 1;
    };
    same
};

// write(2) until it has all gone out: a short write on a socket is legal
// and losing the tail of a response is exactly the bug (b) hunts for.
def write_all(fd: long, p: long, n: long) {
    let off = 0;
    while (off < n) {
        let w = syscall(1, fd, &req[p + off], n - off);
        if (w <= 0) { off = n; } else { off = off + w; };
    };
};

// ── reading ───────────────────────────────────────────────────────────

// where the CRLFCRLF is in buf[0:got], plus 4, or -1
def head_end(got: long) -> long {
    let i = 0;
    let at = -1;
    while (i < got - 3 && at < 0) {
        if (buf[i] == 13 && buf[i + 1] == 10 && buf[i + 2] == 13 && buf[i + 3] == 10) {
            at = i + 4;
        } else {
            i = i + 1;
        };
    };
    at
};

// the value of header `name` in the head just read: hdr_off/hdr_len point
// at it, and false is "no such header". Offsets, never a string.
def header(name: str) -> bool {
    let want = len(name);
    let end = head_len - 2;                 // the blank line's own CRLF
    let i = 0;
    let line = 0;                           // 0 = the status line
    let found = false;
    let go = true;
    while (go) {
        let e = -1;
        let j = i;
        while (j < end && buf[j] != 13) { j = j + 1; };
        if (j >= end) {
            e = end;
        } else {
            e = j + 2;
        };
        if (line > 0 && e - i > want + 1) {
            if (buf[i + want] == 58 && same_nocase(buf, i, name, want)) {
                let v = i + want + 1;
                while (v < e - 2 && buf[v] == 32) { v = v + 1; };
                hdr_at = v;
                hdr_len = e - 2 - v;
                found = true;
                go = false;
            };
        };
        if (go) {
            i = e;
            if (i >= end) { go = false; } else { line = line + 1; };
        };
    };
    found
};

// the declared Content-Length, or -1. Uses header() so there is one
// parser, not two.
def content_length() -> long {
    if (!header("Content-Length")) { return -1; };
    let v = 0;
    let i = 0;
    let seen = false;
    while (i < hdr_len && buf[hdr_at + i] >= 48 && buf[hdr_at + i] <= 57) {
        v = v * 10 + (buf[hdr_at + i] - 48);
        i = i + 1;
        seen = true;
    };
    if (seen) { v } else { -1 }
};

// ── one request ───────────────────────────────────────────────────────

// request(port, method, path) -> the status code (0 when nothing came).
// err says why (0 = no trouble), and the layout of the response is in
// head_len / body_off / body_len / clen.
//
// `path` may carry a query string; the server reads the '?' itself. The
// connection is closed as soon as the body is in, so the server's one
// request per connection loop is never left holding a half-read socket.
def request(port: long, method: str, path: str) -> long {
    status = 0;
    clen = -1;
    head_len = 0;
    body_off = 0;
    body_len = 0;
    err = 0;
    reason = 0;

    let p = REQBODY;
    p = w_str(p, method);
    p = w_str(p, " ");
    p = w_str(p, path);
    p = w_str(p, " HTTP/1.1\r\nHost: 127.0.0.1:");
    p = w_num(p, port);
    p = w_str(p, "\r\nUser-Agent: httpsrv/1 (y)\r\nAccept: */*\r\nConnection: close\r\n\r\n");
    req_len = p - REQBODY;

    let fd = syscall(41, 2, 1, 0);          // socket(AF_INET, SOCK_STREAM)
    if (fd < 0) { err = fd; return 0; };
    sa[0] = 2;
    sa[1] = 0;
    sa[2] = port / 256;                     // the port is big endian: the
    sa[3] = port % 256;                     // one place it surprises people
    sa[4] = 127;
    sa[5] = 0;
    sa[6] = 0;
    sa[7] = 1;
    let cn = syscall(42, fd, &sa[0], 16);   // connect
    if (cn < 0) {
        syscall(3, fd);
        err = cn;
        return 0;
    };
    let w = syscall(1, fd, &req[REQBODY], req_len);
    if (w != req_len) {
        syscall(3, fd);
        err = -32;
        return 0;
    };

    let got = 0;
    let alive = true;
    let e = -1;
    while (alive && got < BUFSZ) {
        let k = syscall(0, fd, &buf[got], BUFSZ - got);
        if (k <= 0) {
            alive = false;
        } else {
            got = got + k;
            e = head_end(got);
            if (e >= 0) { alive = false; };
        };
    };
    if (e < 0) {
        syscall(3, fd);
        err = -11;
        return 0;
    };
    head_len = e;
    body_off = e;
    body_len = got - e;
    clen = content_length();
    if (clen >= 0 && body_len < clen) {
        // the body is short of what the server promised: take the rest,
        // and count what really arrived -- property (b) is about the
        // difference between those two numbers, not about the promise.
        let more = true;
        while (body_len < clen && more && got < BUFSZ) {
            let k = syscall(0, fd, &buf[got], BUFSZ - got);
            if (k <= 0) { more = false; } else { got = got + k; body_len = got - e; };
        };
    };
    syscall(3, fd);

    // "HTTP/1.1 NNN reason" -- the code is fixed width, so no parsing
    let firstsp = 0;
    let i = 0;
    while (i < got && i < 12) {
        if (buf[i] == 32) { firstsp = i; };
        i = i + 1;
    };
    if (firstsp > 0 && firstsp + 3 < got) {
        status = (buf[firstsp + 1] - 48) * 100 + (buf[firstsp + 2] - 48) * 10 + (buf[firstsp + 3] - 48);
        reason = got - (firstsp + 4);
    } else {
        err = -22;
    };
    status
};

// get(port, path) -- the only verb this client speaks.
def get(port: long, path: str) -> long {
    request(port, "GET", path)
};

// the body is buf[body_off : body_off + body_len]. Splitting is spelled
// out rather than offered, because a str of it would allocate -- which is
// the cost this module exists to avoid. Callers that want the bytes (the
// JSON walk, the marker scan) use the offsets directly.
def body() -> long { body_off };

// is `m` somewhere in the body? -1 when it is not. Bytes, not a string.
def body_has(m: str) -> long {
    let n = len(m);
    let i = 0;
    let found = -1;
    while (i + n <= body_len && found < 0) {
        let same = true;
        let j = 0;
        while (j < n) {
            if (buf[body_off + i + j] != m[j]) { same = false; };
            j = j + 1;
        };
        if (same) { found = body_off + i; } else { i = i + 1; };
    };
    found
};

// does the body's first byte match `s`'s first? A cheap "is this the same
// document as the other one" test that cannot be fooled by a shared
// length. Used by property (a): a 404 body must never be a 200 body.
def body_starts(s: str) -> bool {
    if (body_len < len(s)) { return false; };
    let i = 0;
    let same = true;
    while (i < len(s)) {
        if (buf[body_off + i] != s[i]) { same = false; };
        i = i + 1;
    };
    same
};

export { BUFSZ, REQSZ, buf, status, clen, head_len, body_off, body_len, err, hdr_at, hdr_len, header, content_length, request, get, body, body_has, body_starts };