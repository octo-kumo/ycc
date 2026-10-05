// sockio.y -- the wire layer: a bound listener, a fixed-buffer line reader, and
// the byte-append helpers every reply is built through.
//
// ===========================================================================
// WHY NOT net.listen_tcp
// ===========================================================================
//
// `net.listen_tcp(port, handler)` (std/net.y:538) is a blocking accept loop
// that runs the handler to completion before accepting the next connection, so
// it is single-connection-at-a-time by construction: two players could never be
// in the world together.  The MUD needs the opposite -- an accept loop that
// returns immediately and hands the fd to a pool -- so the four calls it is made
// of (socket/bind/listen/accept, plus local_port for an ephemeral port) are
// spelled out here and the loop lives in server.y, where the pool is.
//
// net.listen_http/listen_tcp also never return and have no shutdown path
// (ORCHESTRATOR.md 2.13).  Nothing here does either: this module opens sockets
// and reads and writes bytes, and the ONE loop that could not be interrupted
// (accept) lives in server.y's acceptor, which takes a connection COUNT so it
// always terminates.
//
// ===========================================================================
// WHY THE BUFFERS ARE FIXED AND WHY THE HELPERS TAKE ONE
// ===========================================================================
//
// The heap is an arena and nothing is ever freed (ORCHESTRATOR.md 2.7), so a
// per-command string is a per-command leak.  Every reply here is assembled in
// a `[byte; 4096]` the CALLER owns -- one per worker thread, allocated once when
// the thread starts -- and written with a single write(2).  A command therefore
// allocates nothing at all: no format string, no intermediate str, not even for
// the text of a `say`.
//
// The consequence you notice in the signatures: Y has no generics, and a fixed
// array's size must be an INTEGER LITERAL in a type position, so a helper
// written for `[byte; 4096]` can only be called with a 4096-byte buffer.  That
// is why there is one buffer size here and a second, different set of helpers
// in client.y for the larger transcript buffer.  It is a language limit, not a
// style choice -- see README.md, "WORKAROUNDS".

import net;

// ---- the one buffer size (must be a literal in every type below) -----------
const BUFSZ = 4096;
const LIM = 3900;          // refuse to grow a reply past this, then fail loudly

// ---------------------------------------------------------------------------
// the socket calls
// ---------------------------------------------------------------------------

// Bind and listen.  A port of 0 asks the kernel for a free one, which is what
// every run here does: the port is then read back with port_of() and NEVER
// printed, because a kernel-assigned port is not reproducible.  Every failure
// here is named and exits 1 -- an error path must not trap.
def listen_on(port: long) -> long {
    let fd = net.socket_tcp();
    if (fd < 0) {
        eputs("mud: cannot create a socket: errno " + tostring(fd) + "\n");
        exit(1);
    };
    let b = net.bind_tcp(fd, port);
    if (b < 0) {
        eputs("mud: cannot bind port " + tostring(port) + ": errno " + tostring(b) + "\n");
        exit(1);
    };
    let l = net.listen_fd(fd, 16);
    if (l < 0) {
        eputs("mud: cannot listen on port " + tostring(port) + ": errno " + tostring(l) + "\n");
        exit(1);
    };
    fd
};

def port_of(fd: long) -> long { net.local_port(fd) };

// A short receive timeout, so a client that stops talking cannot pin a worker
// for ever.  secs is whole seconds (that is SO_RCVTIMEO's granularity), and 0
// means no timeout.
// A receive and send timeout of `secs` seconds, so a client that stops talking
// cannot pin a worker for ever.
//
// Not net.set_timeouts, which allocates a `[long; 2]` timespec per call -- 56
// bytes, measured -- and this runs once per connection on both sides.
//
// THE TIMESPEC IS THE CALLER'S, and that is not decoration.  A module-level
// buffer would be the obvious way to avoid the allocation, and it would be a
// data race: this is called from the acceptor, from every worker and from every
// client thread, with two different values (30 for the server's sessions, 20 for
// a scripted client), so two threads interleaving here would leave one socket with
// somebody else's timeout.  The allocation is 56 bytes ONCE per connection, which
// is the honest cost of correctness here; a per-thread buffer would be zero but
// needs one per thread, and a thread's buffers are already declared where the
// thread is (see driver.run_client, which passes its own in).
def set_timeout(fd: long, secs: long, tv: [long; 2]) -> long {
    tv[0] = secs;
    tv[1] = 0;
    syscall(54, fd, 1, 20, &tv[0], 16);        // SO_RCVTIMEO
    syscall(54, fd, 1, 21, &tv[0], 16)         // SO_SNDTIMEO
};

// dial: connect to 127.0.0.1 on `port`, using `a` as the sockaddr.
//
// NOT net.connect_addr, for two measured reasons:
//
//   * addr_set() (std/net.y:49) calls `split(host, ".")`, and a split allocates
//     -- 248 bytes over 100 calls, which on a once-per-connection path is 248
//     bytes a connection of pure garbage; and
//   * the std module declares its sockaddr as a LOCAL `let a: [byte; 16]`, and a
//     local array literal is a heap allocation on every call -- measured at 56
//     bytes for 1000 calls of a 16-byte array (a `[byte; 4096]` local is 4 136).
//
// So the sockaddr is the CALLER'S, for the same reason the line buffers are
// (see driver.run_client): the caller already owns per-thread storage, and a
// module-level sockaddr would be shared by every client thread at once.
def dial(a: [byte; 16], port: long) -> long {
    let fd = net.socket_tcp();
    if (fd < 0) { fd } else {
        a[0] = 2;                                    // AF_INET
        a[1] = 0;                                    // port, big endian
        a[2] = port / 256;
        a[3] = port % 256;
        a[4] = 127;                                  // 127.0.0.1
        a[5] = 0;
        a[6] = 0;
        a[7] = 1;
        let r = syscall(42, fd, &a[0], 16);
        if (r < 0) {
            syscall(3, fd);
            r
        } else {
            fd
        }
    }
};

// send_buf: ONE write(2) per reply, and never a signal.
//
// MSG_NOSIGNAL, not write(2).  A plain write to a socket whose peer has gone
// away does not return EPIPE -- it raises SIGPIPE, which kills the whole process
// (measured: `--clients 4` ended in rc 141 with nothing on stdout, because one
// client's socket closed while the server still had a reply for it).  sendto(2)
// with MSG_NOSIGNAL is the same call with that one flag, and it returns -32
// instead, so a hang-up is an error the caller can count rather than the end of
// the run.  This is why the server is still answering other sessions after a
// client vanishes, and it is the only place in the program that uses sendto.
//
// 44 = sendto, 16384 = MSG_NOSIGNAL, and a null destination is exactly `send`.
def send_buf(fd: long, b: [byte; 4096], n: long) -> long {
    if (n <= 0) { 0 } else { syscall(44, fd, &b[0], n, 16384, 0, 0) }
};

// did the peer go away?  -32 is EPIPE; the server counts these rather than
// letting them end the process (see send_buf).
def send_failed(r: long) -> bool { r < 0 && r != 0 - 11 };

def shut(fd: long) -> long { net.close_fd(fd) };

// ---------------------------------------------------------------------------
// the line reader
// ---------------------------------------------------------------------------
//
// A MUD is line-oriented, so this reads until '\n'.  `hold` is the whole of the
// reader's state: hold[0] = bytes held in b, hold[1] = how many of them have
// already been returned as lines.  One pair of longs per connection is the entire
// per-connection footprint, and it lives on the worker thread's own stack rather
// than on the heap.
//
// Returns the line PACKED as start * 8192 + length -- the caller reads it out of
// b at that offset.  It is packed rather than returned as two values because Y
// functions return one value, and returning a [long; 2] would allocate one per
// line.
//
// THE COMPACTION ORDER IS THE WHOLE TRICK, and getting it wrong is silent.  A
// read(2) routinely returns SEVERAL lines at once, so the buffer must be
// reclaimed or it fills and every later line is reported as over-long.  But the
// reclaim SHIFTS THE REMAINING BYTES DOWN OVER THE LINE JUST RETURNED -- so
// compacting inside line_get destroys the line it just handed back.  An earlier
// version did exactly that, and the symptom was a transcript whose messages were
// truncated at the first space and then repeated: the line was correct, and then
// overwritten before the renderer ever saw it.  So compaction happens at the TOP
// of the next call, once hold[1] has grown past COMPACT_AT, and by then the
// caller has consumed the previous line.
//
// Returns -1 at EOF or on a read error, or -2 when the line is longer than the
// buffer (the rest of that line is dropped, so a hostile client cannot make this
// loop run away).  An unterminated tail at EOF is still returned as a line: a
// client that sent "quit" and closed must still be answered.

const PACK = 8192;          // the packing stride for (start, length)
const COMPACT_AT = 2048;    // reclaim the buffer once this many bytes are spent

def line_reset(hold: [long; 2]) -> long { hold[0] = 0; hold[1] = 0; 0 };

def line_compact(b: [byte; 4096], hold: [long; 2]) -> long {
    let i = hold[1];
    let o = 0;
    while (i < hold[0]) {
        b[o] = b[i];
        o = o + 1;
        i = i + 1;
    };
    hold[0] = o;
    hold[1] = 0;
    o
};

// line_fetch moves the line line_get just returned down to byte 0 and returns
// its length, so a caller that wants the line AT 0 (which is what the server's
// command parser and the client's renderer both assume) can have it.  The copy is
// on the per-command path, so it costs one memmove of at most 4096 bytes per
// command -- and it is what lets the reader reclaim the buffer without
// destroying the line it is handing back.
//
// Skipping this is the bug worth naming: line_get returns an OFFSET, and a
// caller that passes the offset's LENGTH to a parser reading from byte 0 parses
// whatever happens to be at the front of the buffer.  The symptom is not a
// diagnostic -- the server happily answers a garbled command, and the first
// reply looks perfect.

def line_fetch(b: [byte; 4096], pk: long) -> long {
    let at = pk / PACK;
    let ln = pk % PACK;
    if (at > 0) {
        let i = 0;
        while (i < ln) {
            b[i] = b[at + i];
            i = i + 1;
        };
    };
    ln
};

def line_get(fd: long, b: [byte; 4096], hold: [long; 2]) -> long {
    // reclaim first: the previous line has been consumed by now
    if (hold[1] >= COMPACT_AT) { line_compact(b, hold) };
    let start = hold[1];
    let go = true;
    let ans = 0;
    while (go) {
        let nl = 0 - 1;
        let i = start;
        while (i < hold[0]) {
            if (nl < 0 && b[i] == 10) { nl = i };
            i = i + 1;
        };
        if (nl >= 0) {
            ans = nl;
            go = false;
        } else {
            if (hold[0] >= BUFSZ - 1) {
                line_reset(hold);
                return 0 - 2;
            };
            let k = syscall(0, fd, &b[hold[0]], BUFSZ - 1 - hold[0]);
            if (k <= 0) {
                if (start < hold[0]) {
                    ans = hold[0];
                } else {
                    line_reset(hold);
                    return 0 - 1;
                };
                go = false;
            } else {
                hold[0] = hold[0] + k;
            };
        };
    };
    let e = ans;
    if (e > start && b[e - 1] == 13) { e = e - 1; };
    hold[1] = ans + 1;
    start * PACK + (e - start)
};

// ---------------------------------------------------------------------------
// byte appends into a [byte; 4096]
// ---------------------------------------------------------------------------
//
// Each returns the NEW length and stops at BUFSZ - 1.  Callers check the final
// length against LIM before writing, so a reply that would not fit is replaced
// by an error instead of being truncated onto the wire.

def ob(b: [byte; 4096], n: long, c: long) -> long {
    if (n < BUFSZ - 1) { b[n] = c; n = n + 1 };
    n
};

def obs(b: [byte; 4096], n: long, s: str) -> long {
    let i = 0;
    let k = n;
    while (i < len(s)) {
        k = ob(b, k, s[i]);
        i = i + 1;
    };
    k
};

// Copy a byte RANGE of another buffer: this is how a `say` line reaches the
// reply without ever becoming a str.
def obmem(b: [byte; 4096], n: long, src: [byte; 4096], a: long, z: long) -> long {
    let i = a;
    let k = n;
    while (i < z) {
        k = ob(b, k, src[i]);
        i = i + 1;
    };
    k
};

// A digit scratch array would be the obvious way to write this, and it is a
// 192-byte allocation ON EVERY CALL: measured 23 200 bytes over 100 obn calls.
// The heap is an arena and nothing is freed (ORCHESTRATOR.md 2.7), so a number
// formatter that allocates is a leak proportional to how many numbers the
// program prints -- and this one prints numbers on every protocol line.
//
// The scratch cannot simply be hoisted to module level either: obn runs on
// eight worker threads at once, and a shared digit buffer would interleave two
// players' numbers (a preempt between the count pass and the emit pass is all it
// takes).  So the digits are written STRAIGHT into the destination, backwards,
// with no scratch at all: count the digits, then fill from the last one.
//
// Two passes over v is a division per digit instead of one, which is the right
// trade for an allocator that never frees.
def obn(b: [byte; 4096], n: long, v: long) -> long {
    if (v < 0) {
        n = ob(b, n, 45);
        v = 0 - v;
    };
    // pass 1: how many digits
    let k = 1;
    let t = v;
    while (t >= 10) {
        t = t / 10;
        k = k + 1;
    };
    // pass 2: fill backwards, least significant first
    let at = n;
    let room = BUFSZ - 1 - k;
    let ok = room >= n;
    if (ok) {
        let p = n + k;
        let w = v;
        while (p > at) {
            p = p - 1;
            b[p] = 48 + (w % 10);
            w = w / 10;
        };
        n = n + k;
    };
    n
};

def obsp(b: [byte; 4096], n: long) -> long { ob(b, n, 32) };

// Right-align a number in `w` columns, so a column of longs lines up.
def obpad(b: [byte; 4096], n: long, v: long, w: long) -> long {
    if (v < 0) { n = ob(b, n, 45); v = 0 - v };
    let k = 1;
    let t = v;
    while (t >= 10) { t = t / 10; k = k + 1 };
    let pad = w - k;
    let i = 0;
    while (i < pad) { n = ob(b, n, 32); i = i + 1 };
    n = obn(b, n, v);
    n
};

export { BUFSZ, LIM, PACK, COMPACT_AT, listen_on, port_of, set_timeout, dial,
         send_buf, shut, line_reset, line_get, line_fetch, line_compact,
         ob, obs, obmem, obn, obsp, obpad };