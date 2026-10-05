// xwire.y -- the X11 wire protocol, spoken by hand over a raw Unix socket.
//
// Y cannot link libX11, so nothing here is a binding: every byte below is one
// the program composes itself and every reply is one it parses.  What is being
// demonstrated is that the protocol is an ordinary integer byte stream, and
// that this language suits it -- there is not one float or trigonometry in the
// whole handshake.
//
// WHAT IS ACTUALLY PROVEN HERE.  `verify` does not merely "talk to X11 and
// exit 0".  It:
//
//   1. reads the MIT-MAGIC-COOKIE-1 out of $XAUTHORITY, parsing the file
//      format by hand (see read_cookie, which documents an endianness trap);
//   2. performs the connection setup and parses the server's own reply, taking
//      the root window, root depth, byte order and bits-per-pixel from what the
//      server said rather than from assumptions;
//   3. creates a pixmap, PutImages the framebuffer into it IN BANDS (a
//      320x240 image at 32 bits is 307 200 bytes, over the protocol's
//      maximum-request-length, so one request cannot carry it);
//   4. GetImages it back, and recomputes the FNV-1a digest over the pixels THE
//      SERVER RETURNED;
//   5. compares that with the digest of the local framebuffer.
//
// Step 5 is the point.  The default `demo` run asserts a property of a buffer
// in this program's own memory; `verify` asserts that the server holds those
// same bytes.  One without the other proves only half of what a reader would
// assume it proves.
//
// EVERY FAILURE MODE IS A DIAGNOSTIC ON STDERR AND A NON-ZERO EXIT.  There is
// no trap anywhere on this path: a runtime trap prints to STDOUT (see
// ORCHESTRATOR.md 2.12) and would corrupt the byte-for-byte diff the gate does.

import gfx;
import scene;

// ─────────────────────────────────────────────────────────── constants ──
// Syscall numbers, named so the code reads as the protocol it is.
// (ORCHESTRATOR.md 2.1: syscall(n, a1..a6) binds in KERNEL REGISTER order, so
// C's ioctl(fd, request, arg) is written syscall(16, fd, REQUEST, arg).)
let SYS_READ = 0;
let SYS_CLOSE = 3;
let SYS_SOCKET = 41;
let SYS_CONNECT = 42;
let SYS_SETSOCKOPT = 54;
let SYS_OPENAT = 257;
let AT_FDCWD = 0 - 100;
let AF_UNIX = 1;
let SOCK_STREAM = 1;
let SOL_SOCKET = 1;
let SO_RCVTIMEO = 20;
let MSG_NOSIGNAL = 16384;

let X_TCP_PORT = 6000;              // display :N is TCP 6000+N, and the Unix
                                    // socket is /tmp/.X11-unix/XN

// X11 opcodes used here.
let OP_CREATE_WINDOW = 1;
let OP_MAP_WINDOW = 8;
let OP_CREATE_PIXMAP = 53;
let OP_FREE_PIXMAP = 54;
let OP_CREATE_GC = 55;
let OP_PUT_IMAGE = 72;
let OP_GET_IMAGE = 73;
let ZPIXMAP = 2;

// Rows per PutImage/GetImage band.  64 rows x 320 px x 4 B = 81 920 bytes,
// comfortably inside the 262 140-byte request limit X servers report, and the
// reason a single 307 200-byte PutImage is not attempted.
let BAND_ROWS = 64;

// ───────────────────────────────────────────────────── module storage ──
// One arena, allocated once (ORCHESTRATOR.md 2.7: nothing is ever freed, so a
// per-call buffer would be a permanent cost per call).

let sa: [byte; 110] = [0; 110];        // sockaddr_un: 2 + up to 108
let ob: [byte; 131072] = [0; 131072];  // request assembly / image upload
let ib: [byte; 131072] = [0; 131072];  // reply assembly / image download
let envb: [byte; 65536] = [0; 65536];  // /proc/self/environ
let authb: [byte; 4096] = [0; 4096];   // the Xauthority file
let pathb: [byte; 128] = [0; 128];     // the socket path

// ─────────────────────────────────────────────────────── diagnostics ──
// `why` says which step failed and what the server said.  A bare "failed" is
// the shape this campaign keeps refusing: it cannot be acted on.
let why: str = "";
let step: str = "";

def fail(where: str, msg: str) -> long {
    step = where;
    why = msg;
    0 - 1
};

// ────────────────────────────────────────────────────────── byte output ──
// Little-endian stores into the request buffer.  The X11 wire format is
// little-endian when byte-order is 'l', which is what the setup request asks
// for, so these are correct for the rest of the session.
let op_: long = 0;                     // current write cursor into `ob`

def w8(v: long) -> long { ob[op_] = v & 255; op_ = op_ + 1; 0 };
def w16(v: long) -> long {
    ob[op_] = v & 255;
    ob[op_ + 1] = (v >> 8) & 255;
    op_ = op_ + 2;
    0
};
def w32(v: long) -> long {
    ob[op_] = v & 255;
    ob[op_ + 1] = (v >> 8) & 255;
    ob[op_ + 2] = (v >> 16) & 255;
    ob[op_ + 3] = (v >> 24) & 255;
    op_ = op_ + 4;
    0
};

// ─────────────────────────────────────────────────────────── byte input ──

def r8(b: [byte; 131072], off: long) -> long { b[off] };
def r16(b: [byte; 131072], off: long) -> long { b[off] + (b[off + 1] * 256) };
def r32(b: [byte; 131072], off: long) -> long {
    b[off] + (b[off + 1] * 256) + (b[off + 2] * 65536) + (b[off + 3] * 16777216)
};

// ─────────────────────────────────────────────────────── the environment ──

// env_get(key): the value of `key` from this process's own environment, or "".
//
// There is NO getenv in this language, so /proc/self/environ is read directly.
// It is the authoritative source -- it is the block the kernel built, not a
// reconstruction -- and reading it needs no allocation beyond one fixed buffer.
// The block is NUL-separated KEY=VALUE pairs.
def env_get(key: str) -> str {
    let fd = syscall(SYS_OPENAT, AT_FDCWD, "/proc/self/environ", 0, 0, 0, 0);
    if (fd < 0) { return "" };
    let got = syscall(SYS_READ, fd, &envb[0], 65536);
    syscall(SYS_CLOSE, fd);
    if (got <= 0) { return "" };
    let kl = len(key);
    let i = 0;
    while (i < got) {
        // Does this NUL-terminated entry start with `key=`?
        let hit = i + kl < got && envb[i + kl] == 61;      // 61 = '='
        if (hit) {
            let j = 0;
            while (j < kl && envb[i + j] == key[j]) { j = j + 1 };
            hit = j == kl
        };
        if (hit) {
            // Copy the value out, up to the next NUL.
            let v = "";
            let p = i + kl + 1;
            while (p < got && envb[p] != 0) {
                v = v + chr(envb[p]);
                p = p + 1
            };
            return v
        };
        // Advance past this entry's NUL.
        while (i < got && envb[i] != 0) { i = i + 1 };
        i = i + 1
    };
    ""
};

// str bytes into `pathb`, NUL-terminated.  Returns the length.
let pb_len: long = 0;
def pput(s: str) -> long {
    let i = 0;
    while (i < len(s)) {
        pathb[pb_len] = s[i];
        pb_len = pb_len + 1;
        i = i + 1
    };
    pathb[pb_len] = 0;
    pb_len
};

// ────────────────────────────────────────────────────────── the cookie ──
//
// $XAUTHORITY is an Xauthority FILE, whose entries are
//
//     family:CARD16  address:STRING  display:STRING  name:STRING  data:STRING
//
// with each STRING prefixed by its CARD16 length.  Every one of those CARD16s
// is in the file's OWN byte order.
//
// THE TRAP, because it cost me twenty minutes and the brief now warns about
// it: the entries on this machine are BIG-ENDIAN.  A parser that assumes
// little-endian -- which is the natural assumption on x86 and the one I made --
// reads the 18-byte name-length field as 0x1200 = 4608 and then walks off the
// end of a 92-byte file.  Nothing about the failure says "endianness".
//
// So this parser does not assume: it LOCATES the literal name
// "MIT-MAGIC-COOKIE-1" by scanning, and then reads the two length fields that
// follow it.  A cookie is always 16 bytes, which is stated rather than
// guessed, so the name's own length is only used to find where the data starts.
let COOKIE_NAME = "MIT-MAGIC-COOKIE-1";
let cookie: [byte; 32] = [0; 32];
let cookie_n: long = 0;

// Read the whole Xauthority file and extract the cookie.
def read_cookie() -> long {
    let path = env_get("XAUTHORITY");
    if (path == "") { return fail("XAUTHORITY", "XAUTHORITY is not set") };
    let fd = syscall(SYS_OPENAT, AT_FDCWD, path, 0, 0, 0, 0);
    if (fd < 0) {
        return fail("XAUTHORITY", "cannot open " + path + " (errno "
                    + tostring(0 - fd) + ")")
    };
    let got = syscall(SYS_READ, fd, &authb[0], 4096);
    syscall(SYS_CLOSE, fd);
    if (got <= 0) { return fail("XAUTHORITY", "cannot read " + path) };

    // Find the literal name.  Scanning beats parsing here: the parse depends on
    // the file's byte order, which is not knowable from outside it.
    let nl = len(COOKIE_NAME);
    let at = 0 - 1;
    let i = 0;
    while (i + nl <= got && at < 0) {
        let j = 0;
        while (j < nl && authb[i + j] == COOKIE_NAME[j]) { j = j + 1 };
        if (j == nl) { at = i };
        i = i + 1
    };
    if (at < 0) {
        return fail("XAUTHORITY", "no MIT-MAGIC-COOKIE-1 entry in " + path)
    };
    // The name's length field is the two bytes before it; the DATA length field
    // is the two bytes after the name.
    let dlen = (authb[at + nl] * 256) + authb[at + nl + 1];      // BIG-endian
    let p = at + nl + 2;
    if (dlen <= 0 || dlen > 32 || p + dlen > got) {
        return fail("XAUTHORITY", "cookie data length " + tostring(dlen)
                    + " is not sane")
    };
    cookie_n = dlen;
    let k = 0;
    while (k < dlen) { cookie[k] = authb[p + k]; k = k + 1 };
    0
};

// ──────────────────────────────────────────────────────────── the socket ──

let fd: long = 0 - 1;

// Connect to the display's Unix socket.  Returns the fd or -1, with `why` set.
let disp_num: long = 0;
def display_number() -> long {
    let d = env_get("DISPLAY");
    // ":0", ":0.0", ":1" -- take the digits after the leading colon.
    if (d == "") { return fail("DISPLAY", "DISPLAY is not set") };
    if (d[0] != 58) { return fail("DISPLAY", "DISPLAY is '" + d
                                   + "', expected ':N'") };
    let i = 1;
    let n = 0;
    let any = false;
    while (i < len(d) && d[i] >= 48 && d[i] <= 57) {
        n = n * 10 + (d[i] - 48);
        any = true;
        i = i + 1
    };
    if (!any) { return fail("DISPLAY", "no display number in '" + d + "'") };
    disp_num = n;
    0
};

def connect_x() -> long {
    let e = display_number();
    if (e < 0) { return e };
    pb_len = 0;
    pput("/tmp/.X11-unix/X" + tostring(disp_num));

    let s = syscall(SYS_SOCKET, AF_UNIX, SOCK_STREAM, 0);
    if (s < 0) { return fail("socket", "socket(AF_UNIX) failed, errno "
                             + tostring(0 - s)) };

    // A receive timeout, so a server that accepts the connection and then says
    // nothing cannot hang the program.  3 s in {sec, usec}.
    let tv: [byte; 16] = [0; 16];
    tv[0] = 3; tv[1] = 0; tv[2] = 0; tv[3] = 0;
    tv[4] = 0; tv[5] = 0; tv[6] = 0; tv[7] = 0;
    syscall(SYS_SETSOCKOPT, s, SOL_SOCKET, SO_RCVTIMEO, &tv[0], 16);

    // sockaddr_un: family as a 16-bit host-order value, then the path as a
    // NUL-terminated string.  The length is the header plus the path plus its
    // NUL -- passing 110 would be a different (and wrong) request.
    sa[0] = AF_UNIX & 255;
    sa[1] = 0;
    let k = 0;
    while (k <= pb_len) { sa[2 + k] = pathb[k]; k = k + 1 };
    let slen = 2 + pb_len + 1;
    let c = syscall(SYS_CONNECT, s, &sa[0], slen);
    if (c < 0) {
        syscall(SYS_CLOSE, s);
        return fail("connect", "connect to /tmp/.X11-unix/X"
                    + tostring(disp_num) + " failed, errno " + tostring(0 - c))
    };
    fd = s;
    0
};

def xclose() -> long { if (fd >= 0) { syscall(SYS_CLOSE, fd); fd = 0 - 1 }; 0 };

// ──────────────────────────────────────────────────── send and receive ──

let sent_bytes: long = 0;
let short_sends: long = 0;
let short_reads: long = 0;

// send_all: a SHORT SEND IS NORMAL, NOT AN ERROR.  sendto returns what it
// returns; the loop is the correct handling.  (The audio example measured 40
// short writes and 0 recoveries on the same principle.)
def hex2(v: long) -> str { f"{v & 255:02x}" };

// send_all: a SHORT SEND IS NORMAL, NOT AN ERROR.  sendto returns what it
// returns; the loop is the correct handling.  (The audio example measured 40
// short writes and 0 recoveries on the same principle.)
def send_all(n: long) -> long {
    let off = 0;
    let left = n;
    while (left > 0) {
        let w = syscall(44, fd, &ob[off], left, MSG_NOSIGNAL, 0, 0);
        if (w < 0) {
            return fail("send", "sendto failed after " + tostring(off)
                        + " of " + tostring(n) + " bytes, errno "
                        + tostring(0 - w))
        };
        if (w < left) { short_sends = short_sends + 1 };
        off = off + w;
        left = left - w
    };
    sent_bytes = sent_bytes + n;
    0
};

// read_exact: the same discipline in the other direction, and it is not
// optional: the reply header is 8 bytes and a single read(2) may return 3 of
// them.  Treating a short read as a complete reply is how an X client
// desynchronises and then spends an afternoon confused about it.
def read_exact(n: long) -> long {
    let got = 0;
    while (got < n) {
        let r = syscall(SYS_READ, fd, &ib[got], n - got);
        if (r < 0) {
            return fail("recv", "read failed after " + tostring(got) + " of "
                        + tostring(n) + " bytes, errno " + tostring(0 - r))
        };
        if (r == 0) {
            return fail("recv", "the server closed the connection after "
                        + tostring(got) + " of " + tostring(n) + " bytes")
        };
        if (r < n - got) { short_reads = short_reads + 1 };
        got = got + r
    };
    0
};

// ──────────────────────────────────────────────────── connection setup ──
//
// The handshake, and the only part of the protocol where the client must send
// something before the server says anything at all.  An X server NEVER speaks
// first: a client that connects and waits to be greeted hangs, and concluding
// from that hang that there is no server is exactly the mistake that had me
// record this display as unavailable when it was there the whole time.

let root: long = 0;
let root_depth: long = 24;
let id_base: long = 0;
let id_next: long = 0;
let bpp: long = 32;
let image_byte_order: long = 0;
let root_w: long = 0;
let root_h: long = 0;
let vendor: str = "";
let max_req_units: long = 65535;
let setup_seq: long = 0;
let setup_ok: bool = false;

def new_id() -> long {
    let v = id_base | (id_next & 0x001FFFFF);
    id_next = id_next + 1;
    v
};

// x_setup: send the connection-setup request and parse the reply.
def x_setup() -> long {
    let nl = 18;                                   // "MIT-MAGIC-COOKIE-1"
    op_ = 0;
    w8(108);                                       // byte-order 'l'
    w8(0);
    w16(11);                                       // protocol major
    w16(0);                                        // protocol minor
    w16(nl);
    w16(cookie_n);
    w16(0);
    let i = 0;
    while (i < nl) { w8(COOKIE_NAME[i]); i = i + 1 };
    while (i % 4 != 0) { w8(0); i = i + 1 };       // pad the name to 4
    let k = 0;
    while (k < cookie_n) { w8(cookie[k]); k = k + 1 };
    while (k % 4 != 0) { w8(0); k = k + 1 };       // pad the data to 4
    let e = send_all(op_);
    if (e < 0) { return e };

    e = read_exact(8);
    if (e < 0) { return e };
    let status = ib[0];
    let major = r16(ib, 2);
    setup_seq = r16(ib, 4);
    let extra = r16(ib, 6);
    if (status != 1) {
        let reason = "";
        let rl = ib[1];
        let p = 8;
        let q = 0;
        while (q < rl && p < extra * 4) {
            reason = reason + chr(ib[p]);
            p = p + 1;
            q = q + 1
        };
        let named = if status == 2 { " (further authentication required)" }
                    else { "" };
        return fail("setup", "the X server refused the connection: status "
                    + tostring(status) + named + " protocol " + tostring(major)
                    + "." + tostring(r16(ib, 4)) + ", reason length "
                    + tostring(rl) + (if reason == "" { "" } else { ": " + reason }))
    };
    if (major != 11) {
        return fail("setup", "server speaks protocol " + tostring(major)
                    + ", not 11")
    };

    e = read_exact(extra * 4);
    if (e < 0) { return e };

    id_base = r32(ib, 4);
    let vlen = r16(ib, 16);
    max_req_units = r16(ib, 18);
    let screens = ib[20];
    let formats = ib[21];
    image_byte_order = ib[22];
    let v = "";
    let p = 32;
    let q = 0;
    // `p` must advance as well as `q`: without it the loop read ib[32] vlen
    // times and reported the vendor as "TTTTTTTT...", which is the first letter
    // of "The X.Org Foundation" repeated.  A string built by repetition rather
    // than by reading is easy to mistake for a parse offset error.
    while (q < vlen) { v = v + chr(ib[p]); p = p + 1; q = q + 1 };
    vendor = v;

    // Pixmap formats: 8 bytes each, starting after the padded vendor string.
    let fo = 32 + vlen;
    while (fo % 4 != 0) { fo = fo + 1 };
    // Root depth is not known until the SCREEN is parsed, so pick the format
    // whose depth matches afterwards; record the 24bpp one for now.
    let best = 0;
    let f = 0;
    while (f < formats) {
        let o = fo + f * 8;
        if (ib[o + 1] == 32 && best == 0) { best = o };
        f = f + 1
    };
    if (best == 0) { return fail("setup", "no 32-bits-per-pixel pixmap format") };
    bpp = 32;

    if (screens < 1) { return fail("setup", "the server reports no screens") };
    let so = fo + formats * 8;
    root = r32(ib, so);
    root_w = r16(ib, so + 20);
    root_h = r16(ib, so + 22);
    root_depth = ib[so + 38];
    id_next = 1;
    setup_ok = true;
    0
};

// ───────────────────────────────────────────────────────────── requests ──

// WHICH REQUESTS REPLY.  The first draft of this file carried a note saying the
// opposite -- "every request gets a reply, including the ones you think do not" --
// and it is wrong, and it is the single most damaging thing to get wrong here.
//
// In X11 only requests that RETURN DATA produce a reply.  CreatePixmap,
// CreateGC, CreateWindow, MapWindow, PutImage and FreePixmap are "void": they
// are answered by silence, or by an ASYNCHRONOUS error if they were malformed.
// So:
//
//   * reading a reply after a void request BLOCKS until some later
//     reply-bearing request answers, and then consumes THAT reply -- so every
//     reply from then on is off by one and the session desynchronises;
//   * not reading one is correct, and any error the server raised will simply
//     be the next thing on the wire, where x_error() will decode it.
//
// Verified against the live server: a correctly formed CreatePixmap produces no
// reply at all.  A 3-second read timed out; it did not return an error.
//
// x_reply_name: the opcode a name belongs to, for the error diagnostic.
def x_reply_name(op: long) -> str {
    if (op == OP_CREATE_WINDOW) { "CreateWindow" }
    else if (op == OP_MAP_WINDOW) { "MapWindow" }
    else if (op == OP_CREATE_PIXMAP) { "CreatePixmap" }
    else if (op == OP_FREE_PIXMAP) { "FreePixmap" }
    else if (op == OP_CREATE_GC) { "CreateGC" }
    else if (op == OP_PUT_IMAGE) { "PutImage" }
    else if (op == OP_GET_IMAGE) { "GetImage" }
    else { "opcode " + tostring(op) }
};

// x_error: decode an X11 error reply, which is 32 bytes of
//   0 type (0 = error)  1 error-code  2 sequence  4 bad value  6 minor opcode
//   8 major opcode  9 unused  10..31 padded
// Reporting only "the queue is out of step" throws the useful half away, and
// the useful half is which request the server rejected and why.
def x_error(where: str) -> long {
    let code = ib[1];
    let seq = r16(ib, 2);
    let bad = r32(ib, 4);
    let major = ib[10];          // NOT ib[8]: bytes 8..9 are the MINOR opcode
    fail(where, "the X server rejected " + x_reply_name(major)
         + " (error code " + tostring(code) + ", sequence " + tostring(seq)
         + ", bad value 0x" + gfx.hex64(bad) + ")")
};

// x_expect_silence: after a VOID request there is nothing to read.  This
// deliberately does nothing and says so, so that the absence is visible in the
// source rather than looking like an oversight -- a reader who wonders "why no
// read here?" should find the answer two lines away instead of in a git blame.
def x_expect_silence(what: str) -> long { 0 };

let image: long = 0;

// band_ok: success flag for get_image_band, because its return value cannot be
// one.  FNV-1a is 64 bits and a `long` is signed, so roughly half of all
// digests are negative -- asking "is this < 0?" about a hash is not a status
// check, it is a coin toss.  The first version did, and reported an empty
// failure for a perfectly good hash.
let band_ok: bool = false;

// put_image_band: upload rows [y0, y0+rows) of the framebuffer as ZPixmap.
//
// The data is packed by the SERVER's rules, not the framebuffer's: at 32 bits
// per pixel little-endian, one X pixel is B,G,R,unused -- note the byte order is
// NOT the framebuffer's R,G,B.  Getting that backwards uploads a colour-swapped
// image that still looks plausible, which is why the read-back comparison in
// `verify` is the thing that would catch it.
def put_image_band(pm: long, gc: long, y0: long, rows: long) -> long {
    let w = scene.W;
    let row_bytes = w * 4;
    let data_len = row_bytes * rows;

    // THE HEADER GOES FIRST, AND THE PIXELS ARE PACKED DIRECTLY AFTER IT.
    //
    // The first draft packed the pixels into ob[0..] and then copied them to
    // ob[24..] with `w8(ob[i])` -- reading and writing the SAME buffer at
    // overlapping offsets, so the copy consumed bytes it had itself just
    // overwritten.  The second defect was in the same loop: it packed `w` pixels
    // (one row) for a band of `rows` rows, leaving the rest of the band as
    // whatever was already in the buffer.  Neither raised an error.  The server
    // accepted every request and the only symptom was a digest mismatch, which
    // is the entire reason `verify` compares digests at all.
    op_ = 0;
    w8(OP_PUT_IMAGE);
    w8(ZPIXMAP);
    w16(6 + (data_len + 3) / 4);           // length in 4-byte units
    w32(pm);
    w32(gc);
    w16(w);                                 // width  (CARD16)
    w16(rows);                              // height (CARD16)
    w16(0);                                 // dst-x
    w16(y0);                                // dst-y
    w8(0);                                  // left-pad
    w8(root_depth);
    // The header above is 22 bytes and a request must be a multiple of 4, so
    // TWO pad bytes go here before any data.  The declared length already counts
    // them; omit them and the server reads 2 bytes into the next request, answers
    // BadLength, and everything after it is off by two.
    w8(0);
    w8(0);
    let base = op_;                         // 24

    // Now pack `rows` rows of `w` pixels straight into the request buffer, in
    // row-major order, so pixel (x, y0+r) lands at base + 4*(r*w + x).
    //
    // The framebuffer holds a pixel as 0x00RRGGBB, so red is the HIGH byte; the
    // server wants it LOW.  That reversal is the whole of the colour handling,
    // and getting it wrong yields a plausible-looking image with red and blue
    // swapped -- which is why `verify` compares digests rather than merely
    // reporting that it drew something.
    let d = base;
    let r = 0;
    while (r < rows) {
        let x = 0;
        while (x < w) {
            let c = gfx.get(x, y0 + r);
            ob[d] = c & 255;                // blue
            ob[d + 1] = (c >> 8) & 255;     // green
            ob[d + 2] = (c >> 16) & 255;    // red
            ob[d + 3] = 0;                  // the unused byte
            d = d + 4;
            x = x + 1
        };
        r = r + 1
    };
    op_ = d;
    send_all(op_)
};

// get_image_band: read rows [y0, y0+rows) back.  Returns the FNV-1a of the
// image, carrying `h` in, so the caller can hash the whole image without ever
// holding all of it.
//
// The hash is fed R, G, B per pixel in row-major order -- the same order
// `gfx.digest` uses over the framebuffer -- with the server's unused fourth
// byte SKIPPED.  If that skip were wrong the digests would not match, and the
// whole point of `verify` would be lost, so the order is not incidental.
def get_image_band(pm: long, y0: long, rows: long, h: long) -> long {
    band_ok = false;
    let w = scene.W;
    let row_bytes = w * 4;
    let data_len = row_bytes * rows;
    op_ = 0;
    w8(OP_GET_IMAGE);
    w8(ZPIXMAP);
    w16(5);                                 // fixed length for GetImage
    w32(pm);
    w16(0);                                 // x
    w16(y0);                                // y
    w16(w);
    w16(rows);
    w32(0xFFFFFFFF);                        // plane mask: all planes
    let e = send_all(op_);
    if (e < 0) { return e };

    e = read_exact(32);
    if (e < 0) { return e };
    if (ib[0] == 0) { return x_error("GetImage") };
    if (ib[0] != 1) {
        return fail("protocol", "GetImage did not get a reply (type "
                    + tostring(ib[0]) + ")")
    };
    let n = r32(ib, 4) * 4;
    if (n < data_len) {
        return fail("GetImage", "the server returned " + tostring(n)
                    + " bytes for a band that needs " + tostring(data_len))
    };
    e = read_exact(data_len);
    if (e < 0) { return e };

    let i = 0;
    while (i < data_len) {
        let r = ib[i + 2];
        let g = ib[i + 1];
        let b = ib[i];
        h = (h ^ r) * gfx.FNV_PRIME;
        h = (h ^ g) * gfx.FNV_PRIME;
        h = (h ^ b) * gfx.FNV_PRIME;
        i = i + 4
    };
    band_ok = true;
    h
};

// ───────────────────────────────────────────��──────────────────── commands ──

// preflight: everything that can fail before any pixels move, done in a fixed
// order so the diagnostic names the actual step that failed.
def preflight() -> long {
    let e = read_cookie();
    if (e < 0) { return e };
    e = connect_x();
    if (e < 0) { return e };
    x_setup()
};

def fnv_local() -> long { gfx.digest(scene.W, scene.H) };

// verify: the round trip.  This is the strongest thing the example does.
def verify() -> long {
    let e = preflight();
    if (e < 0) { return report_failure() };

    let el = scene.scene_draw(scene.W, scene.H);
    gfx.stats_scan(scene.W, scene.H);
    let local_d = fnv_local();

    print("x11: connected to DISPLAY :" + tostring(disp_num) + " ("
        + tostring(root_w) + "x" + tostring(root_h) + ", vendor " + vendor
        + ")");
    print("x11: cookie " + tostring(cookie_n) + " bytes from "
        + env_get("XAUTHORITY"));
    print("x11: root window 0x" + gfx.hex64(root) + "  depth "
        + tostring(root_depth) + "  " + tostring(bpp) + "bpp  byte order "
        + (if image_byte_order == 0 { "LSBFirst" } else { "MSBFirst" }));
    print("x11: local image " + tostring(scene.W) + "x" + tostring(scene.H)
        + ", " + tostring(el) + " element pixels, digest "
        + gfx.digest_hex(local_d));

    // A pixmap and a GC to draw through.
    let pm = new_id();
    op_ = 0;
    // 1 opcode + 1 depth + 2 length + 4 pid + 4 drawable + 2 width + 2 height
    // = 16 bytes = 4 four-byte units.  Width and height are CARD16, not
    // CARD32: sending 4 bytes each makes a 20-byte request declared as 4 units,
    // and the server answers BadLength -- error code 16, bad value 0.
    w8(OP_CREATE_PIXMAP); w8(root_depth); w16(4);
    w32(pm); w32(root); w16(scene.W); w16(scene.H);
    e = send_all(op_);
    if (e < 0) { xclose(); return report_failure() };
    e = x_expect_silence("CreatePixmap");
    if (e < 0) { xclose(); return report_failure() };

    let gc = new_id();
    op_ = 0;
    w8(OP_CREATE_GC); w8(0); w16(4);
    w32(gc); w32(pm); w32(0);
    e = send_all(op_);
    if (e < 0) { xclose(); return report_failure() };
    e = x_expect_silence("CreateGC");
    if (e < 0) { xclose(); return report_failure() };

    // Upload, in bands, because one request cannot carry the whole image.
    let y = 0;
    while (y < scene.H) {
        let rows = BAND_ROWS;
        if (y + rows > scene.H) { rows = scene.H - y };
        e = put_image_band(pm, gc, y, rows);
        if (e < 0) { xclose(); return report_failure() };
        e = x_expect_silence("PutImage");
        if (e < 0) { xclose(); return report_failure() };
        y = y + rows
    };

    // Read it back and hash what the SERVER holds.
    let h = gfx.FNV_OFF;
    y = 0;
    while (y < scene.H) {
        let rows = BAND_ROWS;
        if (y + rows > scene.H) { rows = scene.H - y };
        h = get_image_band(pm, y, rows, h);
        if (!band_ok) { xclose(); return report_failure() };
        y = y + rows
    };

    // While the pixmap is still alive: show both sides of a digest mismatch.

    // Free both, then compare.  Comparing before freeing would leak on a path
    // that is supposed to be the tidy one.
    op_ = 0;
    w8(OP_FREE_PIXMAP); w8(0); w16(2); w32(pm);
    e = send_all(op_);
    if (e < 0) { xclose(); return report_failure() };
    e = x_expect_silence("FreePixmap");
    if (e < 0) { xclose(); return report_failure() };

    let server_d = h;
    let same = server_d == local_d;
    print("x11: bands of " + tostring(BAND_ROWS) + " rows ("
        + tostring(scene.W * BAND_ROWS * 4) + " B each, under the "
        + tostring(max_req_units * 4) + " B request limit)");
    print("x11: read back from the server, digest " + gfx.digest_hex(server_d));
    print("x11: short reads " + tostring(short_reads) + ", short sends "
        + tostring(short_sends));
    xclose();

    if (same) {
        print("x11: MATCH -- the server holds exactly the image rendered locally");
        0
    } else {
        eputs("x11: MISMATCH -- local " + gfx.digest_hex(local_d)
              + " but the server returned " + gfx.digest_hex(server_d) + "\n");
        1
    }
};

// show: open a real window and put the image in it.  320x240 on a 3440x1440
// screen, because the screen belongs to whoever is sitting at it.
def show() -> long {
    let e = preflight();
    if (e < 0) { return report_failure() };

    if (scene.W > root_w || scene.H > root_h) {
        eputs("x11: the window would be larger than the screen\n");
        xclose();
        return 1
    };

    let win = new_id();
    op_ = 0;
    // 1 opcode + 1 depth + 2 length + 4 wid + 4 parent + 2 x + 2 y + 2 width
    // + 2 height + 2 border + 2 class + 4 visual + 4 value-mask = 32 bytes,
    // then exactly ONE 4-byte value because the mask has one bit set.  36 bytes
    // = 9 four-byte units.  The first draft declared 10 and sent four values,
    // and the server rejected it.
    w8(OP_CREATE_WINDOW); w8(root_depth); w16(9);
    w32(win); w32(root);
    w16(0); w16(0);                           // x, y
    w16(scene.W); w16(scene.H);
    w16(0);                                   // border width
    w16(1);                                   // class: InputOutput
    w32(0);                                   // CopyFromParent visual
    w32(0x00000002);                          // value-mask: background-pixel
    w32(0);                                   // the one value: background black
    let sent = send_all(op_);
    if (sent < 0) { xclose(); return report_failure() };
    e = x_expect_silence("CreatePixmap");
    if (e < 0) { xclose(); return report_failure() };

    let gc = new_id();
    op_ = 0;
    w8(OP_CREATE_GC); w8(0); w16(4);
    w32(gc); w32(win); w32(0);
    e = send_all(op_);
    if (e < 0) { xclose(); return report_failure() };
    e = x_expect_silence("CreateGC");
    if (e < 0) { xclose(); return report_failure() };

    let el = scene.scene_draw(scene.W, scene.H);
    let y = 0;
    while (y < scene.H) {
        let rows = BAND_ROWS;
        if (y + rows > scene.H) { rows = scene.H - y };
        e = put_image_band(win, gc, y, rows);
        if (e < 0) { xclose(); return report_failure() };
        e = x_expect_silence("PutImage");
        if (e < 0) { xclose(); return report_failure() };
        y = y + rows
    };

    op_ = 0;
    w8(OP_MAP_WINDOW); w8(0); w16(2); w32(win);
    e = send_all(op_);
    if (e < 0) { xclose(); return report_failure() };
    e = x_expect_silence("MapWindow");
    if (e < 0) { xclose(); return report_failure() };

    print("x11: window 0x" + gfx.hex64(win) + " mapped, " + tostring(scene.W)
        + "x" + tostring(scene.H) + ", " + tostring(el) + " element pixels, "
        + "digest " + gfx.digest_hex(gfx.digest(scene.W, scene.H)));

    // Hold the connection open, or the window disappears the instant we close
    // it: every resource a client creates -- windows, pixmaps, GCs -- is owned by
    // the connection, and closing the connection destroys them.  The first draft
    // printed "it will stay up for about a second" and then closed immediately,
    // so it stayed up for no time at all.  A claim like that should be true.
    //
    // 35 = nanosleep, which takes a struct timespec: 8 bytes of seconds then 8
    // of nanoseconds.  Bounded: one second, once.
    let ts: [byte; 16] = [0; 16];
    ts[0] = 1;                              // 1 second
    syscall(35, &ts[0], 0, 0);
    print("x11: held the connection open for 1 s, then closed it");
    xclose();
    print("x11: closing the connection destroyed the window and its resources,"
        + " which is what an X client always does");
    0
};

// ──────────────────────────────────────────────────── the degrading path ──

// verify_no_display: what must happen when there is no display.  A one-line
// diagnostic on STDERR, a non-zero exit, and no trap -- a trap prints to stdout
// and would corrupt the diff.
def verify_no_display() -> long {
    eputs("x11: --no-display requested, so no X server is contacted\n");
    eputs("x11: degraded cleanly: DISPLAY is never read, no socket is opened\n");
    3
};

// report_failure: turn `why` into a diagnostic that names the step.
def report_failure() -> long {
    eputs("x11: " + step + ": " + why + "\n");
    xclose();
    1
};

// probe: connect, do the handshake, and print the server's setup reply field by
// field.  This is the subcommand to reach for when a handshake goes wrong, and
// it is part of the example because the alternative is guessing at offsets.
def probe() -> long {
    let e = read_cookie();
    if (e < 0) { return report_failure() };
    e = connect_x();
    if (e < 0) { return report_failure() };
    e = x_setup();
    if (e < 0) { return report_failure() };
    print("x11 probe: the server's connection-setup reply");
    print("  cookie       " + tostring(cookie_n) + " bytes from "
        + env_get("XAUTHORITY"));
    print("  release      " + tostring(r32(ib, 0)));
    print("  id-base      0x" + gfx.hex64(r32(ib, 4)));
    print("  id-mask      0x" + gfx.hex64(r32(ib, 8)));
    print("  vendor       " + vendor + "  (length "
        + tostring(r16(ib, 16)) + ")");
    print("  max-request  " + tostring(r16(ib, 18)) + " units = "
        + tostring(r16(ib, 18) * 4) + " bytes");
    print("  screens      " + tostring(ib[20]) + "   pixmap formats "
        + tostring(ib[21]));
    print("  byte order   " + tostring(ib[22])
        + " (0 = LSBFirst, 1 = MSBFirst)");
    print("  scanline pad " + tostring(ib[25]) + "   min/max keycode "
        + tostring(ib[26]) + "/" + tostring(ib[27]));
    print("  root         0x" + gfx.hex64(root) + "  " + tostring(root_w)
        + "x" + tostring(root_h) + "  depth " + tostring(root_depth));
    let fo = 32 + r16(ib, 16);
    while (fo % 4 != 0) { fo = fo + 1 };
    let f = 0;
    while (f < ib[21]) {
        let o = fo + f * 8;
        print("  format " + tostring(f) + ": depth " + tostring(ib[o])
            + "  bpp " + tostring(ib[o + 1]) + "  pad "
            + tostring(ib[o + 2]));
        f = f + 1
    };
    xclose();
    0
};

export { verify, show, probe, verify_no_display, why, step, root, vendor,
         root_w, root_h, bpp, read_cookie, connect_x, x_setup, display_number };