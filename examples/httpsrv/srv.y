// srv.y -- the server half of httpsrv: a loopback HTTP/1.1 server with a
// live model behind it.
//
//   import srv;
//
//   let port = srv.start(0, srv.VIRTUAL);   // fork it, hand back the port
//   ... httpc.get(port, "/api/stats") ...
//   let code = srv.stop(srv.pid);            // 143 = 128 + SIGTERM
//
// ── why it is not net.listen_http ─────────────────────────────────────
//
// `net.listen_http` is one line and it works, but two things about it
// decide the shape of this module:
//
//   * It **never returns** and there is no shutdown path, so a program that joins it hangs for ever. The answer is
//     fork + `syscall(62, pid, 15)`, and that is what srv.start does.
//     stop() is the kill, and the child's 143 is what comes back.
//
//   * Its handler is `(str) -> str`, so every request allocates: the head
//     is a fresh string, the response is another one, and the arena never
//     frees. A server that is supposed to run for hours cannot do that.
//     So the accept loop here is the three syscalls it is -- 41 socket,
//     49 bind, 50 listen, 43 accept -- over **fixed buffers**: the head
//     lands in `rbuf` and the response is built in `obuf`, in place. The
//     measured result is 0 bytes of heap growth per request; see
//     --self-test, which asks the server for its own heap_used() before
//     and after 200 requests and prints the difference.
//
// Two details that cost time if forgotten:
//   * the port in a sockaddr_in is **big endian** (sa[2], sa[3]) -- the
//     only field that is not written a byte at a time;
//   * `syscall` takes its arguments in **kernel register order**, so
//     getsockname is syscall(51, fd, addr, lenptr) and ioctl would be
//     syscall(16, fd, REQUEST, arg).
//
// ── the live model ────────────────────────────────────────────────────
//
// Nothing here reads the wall clock unless --live asked it to (VIRTUAL vs
// REAL), because the default run has to be reproducible byte for byte.
// VIRTUAL is a seeded LCG: every request advances the model by one 10 ms
// tick and draws how much traffic arrived in it, 10..99 requests, so
// `rate` is that draw times 100 requests per second. The window starts
// full (32 warm-up ticks at boot) so `arrived == sum(window)` holds from
// the very first response -- which is one of the properties --self-test
// checks, because it is a real equation between two independently computed
// numbers and a golden file cannot check either.
//
// REAL measures: `rate` is 10000 / (ms between this request and the last
// one), so it is the client's own polling rate seen from the server.


// ── the model ──────────────────────────────────────────────────────────

const WN = 32;               // samples in the window, one per 10 ms tick
const VIRTUAL = 0;           // seeded LCG, reproducible
const REAL = 1;              // clock_gettime, what --live runs on
const TICK_MS = 10;          // one tick's worth of virtual time

const DEFAULT_SEED = 20260101;

let seed = DEFAULT_SEED;
let mode = VIRTUAL;
let win: [long; 32] = [0; 32];
let at = 0;                  // the ring cursor: where the next sample goes
let lcg = 0;
let ticks = 0;
let served = 0;
let arrived = 0;
let rate = 0;
let peak = 0;
let trough = 0;
let sum = 0;
let errors = 0;              // responses that were not 2xx
let bytes = 0;               // bytes written, head and body together
let conns = 0;               // connections accepted
let up_ms = 0;
let last_ms = 0;             // REAL only: when the last request arrived

// the counters as they were at boot, so a caller can ask for a delta
let base_heap = 0;

// ── the buffers ───────────────────────────────────────────────────────
//
// Fixed size, module level, never handed out: the arena has no free, so a
// buffer made per request is a leak (and a literal inside a function that
// runs per request costs 64 bytes a call -- measured).

const RBUFSZ = 8192;
const OBUFSZ = 65536;
const BODY_AT = 512;         // room for the head, then the body

let rbuf: [byte; 8192] = [0; 8192];
let obuf: [byte; 65536] = [0; 65536];
let sa: [byte; 16] = [0; 16];
let ga: [byte; 16] = [0; 16];
let gl: [long; 1] = [0; 1];
let msg: [byte; 8] = [0; 8];
let digits: [byte; 24] = [0; 24];

// ── writing into obuf ──────────────────────────────────────────────────

def w(p: long, s: str) -> long {
    let n = len(s);
    let i = 0;
    while (i < n) { obuf[p + i] = s[i]; i = i + 1; };
    p + n
};

def wn(p: long, v: long) -> long {
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
    if (neg) { obuf[p] = 45; p = p + 1; };
    let i = 0;
    while (i < n) { obuf[p + i] = digits[n - 1 - i]; i = i + 1; };
    p + n
};

// write(2) until the bytes are all gone -- a short write on a socket is
// legal, and dropping the tail of a response is a defect a client sees.
def write_all(fd: long, off: long, n: long) {
    let left = 0;
    while (left < n) {
        let wn2 = syscall(1, fd, &obuf[off + left], n - left);
        if (wn2 <= 0) { left = n; } else { left = left + wn2; };
    };
};

// ── the model ──────────────────────────────────────────────────────────

// one tick's worth of traffic, in **requests per second** -- the unit every
// rate on the dashboard is in, so the window, the peak, the mean and the
// chart all speak the same one. VIRTUAL draws 10..99 requests per 10 ms
// tick and scales by 100; REAL measures the gap to the last request.
def draw() -> long {
    if (mode == VIRTUAL) {
        lcg = (lcg * 1103515245 + 12345) % 2147483648;
        ((lcg / 65536) % 90 + 10) * 100
    } else {
        let now = (clock_us() / 1000);
        let dt = now - last_ms;
        last_ms = now;
        let r = 0;
        if (dt > 0) { r = 10000 / dt; };
        if (r > 9999) { r = 9999; };
        r
    }
};

// put a sample in the window and re-derive everything that depends on it.
// `v` is req/s; `arrived` counts **requests**, not rates, so it adds v/100 --
// exact in VIRTUAL mode, where every draw is a multiple of 100.
def push(v: long) {
    sum = sum - win[at] + v;
    win[at] = v;
    at = (at + 1) % WN;
    arrived = arrived + v / 100;
    rate = v;
    // 32 steps is nothing next to a request, and it keeps peak/trough/avg
    // true for whatever the window holds right now.
    let i = 0;
    let hi = win[0];
    let lo = win[0];
    while (i < WN) {
        if (win[i] > hi) { hi = win[i]; };
        if (win[i] < lo) { lo = win[i]; };
        i = i + 1;
    };
    peak = hi;
    trough = lo;
}

// boot the model: seed the LCG, fill the window so `arrived == sum(window)`
// holds before the first request is served.
def boot(s0: long, m: long) {
    // normalise: the generator is mod 2^31, and a negative state would
    // produce negative samples, which a renderer must then defend against
    let s = s0;
    if (s < 0) { s = 0; };
    if (s > 2147483647) { s = s % 2147483648; };
    seed = s;
    mode = m;
    lcg = s;
    at = 0;
    ticks = 0;
    served = 0;
    arrived = 0;
    rate = 0;
    errors = 0;
    bytes = 0;
    conns = 0;
    up_ms = 0;
    let i = 0;
    while (i < WN) { win[i] = 0; i = i + 1; };
    i = 0;
    while (i < WN) { push(draw()); i = i + 1; };
    if (mode == REAL) { last_ms = (clock_us() / 1000); };
    base_heap = heap_used();
};

// one served request: the model moves on by one tick.
def step() {
    push(draw());
    served = served + 1;
    ticks = ticks + 1;
    up_ms = ticks * TICK_MS;
};

// ── the request ────────────────────────────────────────────────────────

// where CRLFCRLF is in rbuf[0:got], plus 4, or -1
let got = 0;
let head_end = 0;
let m_at = 0;
let m_len = 0;
let t_at = 0;
let t_len = 0;
let v_ok = false;
let line_end = 0;           // the request line's own end, for the query

def find_head(g: long) -> long {
    let i = 0;
    let e = -1;
    while (i < g - 3 && e < 0) {
        if (rbuf[i] == 13 && rbuf[i + 1] == 10 && rbuf[i + 2] == 13 && rbuf[i + 3] == 10) {
            e = i + 4;
        } else {
            i = i + 1;
        };
    };
    e
};

def tok_eq(at0: long, n: long, s: str) -> bool {
    if (n != len(s)) { return false; };
    let i = 0;
    let same = true;
    while (i < n) {
        if (rbuf[at0 + i] != s[i]) { same = false; };
        i = i + 1;
    };
    same
};

// the request line: METHOD SP TARGET SP HTTP/x.y, and nothing else. Sets
// m_*/t_* to the method and the target (query string included -- the
// caller splits it), v_ok to whether the version was there.
def parse_line(e: long) -> bool {
    // the end of the request line is the first CRLF, or the head end
    let stop = e;
    let j = 0;
    while (j < stop && rbuf[j] != 13) { j = j + 1; };
    if (j >= stop) { stop = j; };
    line_end = stop;
    let sp1 = -1;
    let sp2 = -1;
    let i = 0;
    while (i < stop && sp2 < 0) {
        if (rbuf[i] == 32) {
            if (sp1 < 0) { sp1 = i; } else { sp2 = i; };
        };
        i = i + 1;
    };
    v_ok = false;
    if (sp1 < 0 || sp2 < 0 || sp1 == 0 || sp2 <= sp1 + 1) { return false; };
    m_at = 0;
    m_len = sp1;
    t_at = sp1 + 1;
    t_len = sp2 - sp1 - 1;
    v_ok = stop - sp2 >= 9 && rbuf[sp2 + 1] == 72 && rbuf[sp2 + 2] == 84 && rbuf[sp2 + 3] == 84 &&
           rbuf[sp2 + 4] == 80;
    true
};

// the target without its query string: t_len becomes the path's length.
let q_at = -1;

def strip_query() -> long {
    let i = 0;
    q_at = -1;
    while (i < t_len) {
        if (rbuf[t_at + i] == 63) { q_at = t_at + i; t_len = i; i = t_len; } else { i = i + 1; };
    };
    t_len
};

// does the query string carry `k=1`? The scan is over the request line
// only (line_end), so a header cannot answer for it.
def query_is(k: str) -> bool {
    if (q_at < 0) { return false; };
    let q = q_at + 1;
    let total = line_end - q;        // the query ends with the request line,
    let want = len(k);               // not at the end of the head
    let i = 0;
    let found = false;
    while (i + want + 2 <= total && !found) {
        let same = rbuf[q + i + want] == 61 && rbuf[q + i + want + 1] == 49;
        if (same) {
            let c = 0;
            while (c < want) {
                if (rbuf[q + i + c] != k[c]) { same = false; };
                c = c + 1;
            };
        };
        if (same) { found = true; } else { i = i + 1; };
    };
    found
};

// ── the responses ──────────────────────────────────────────────────────

const OK = 200;
const BAD = 400;
const NOPE = 404;
const NOWAY = 405;
const LONG = 413;

let body_len = 0;

def status_line(p: long, code: long) -> long {
    p = w(p, "HTTP/1.1 ");
    p = wn(p, code);
    if (code == OK) {
        p = w(p, " OK\r\n");
    } else if (code == NOPE) {
        p = w(p, " Not Found\r\n");
    } else if (code == NOWAY) {
        p = w(p, " Method Not Allowed\r\n");
    } else if (code == BAD) {
        p = w(p, " Bad Request\r\n");
    } else if (code == LONG) {
        p = w(p, " Payload Too Large\r\n");
    } else {
        p = w(p, " Error\r\n");
    };
    p
};

// build the head at 0 and answer. `allow` adds the Allow header a 405 has
// to carry; `heapq` adds the server's own heap_used(), which the client
// asks for with ?heap=1 -- it is a number that moves, so it has to stay
// out of anything deterministic.
def head_and_send(fd: long, code: long, ctype: str, blen: long, allow: bool, heapq: bool) {
    let p = 0;
    p = status_line(p, code);
    p = w(p, "Server: httpsrv/1 (y)\r\nContent-Type: ");
    p = w(p, ctype);
    p = w(p, "\r\nContent-Length: ");
    p = wn(p, blen);
    p = w(p, "\r\nCache-Control: no-store\r\nX-Requests: ");
    p = wn(p, served);
    if (heapq) {
        p = w(p, "\r\nX-Heap: ");
        p = wn(p, heap_used());
    };
    if (allow) { p = w(p, "\r\nAllow: GET"); };
    p = w(p, "\r\nConnection: close\r\n\r\n");
    // p is the head's length and the body was built at BODY_AT, so the
    // head has to be the shorter of the two. It is a fixed header set, so
    // p is around 150 bytes against 512; the guard is here so that a
    // future header cannot quietly eat the front of the body.
    if (p > BODY_AT) { p = BODY_AT; };
    // Two writes, not one: the head is at 0 and the body was built at
    // BODY_AT, so `p + blen` bytes from offset 0 would send the gap
    // between them -- NULs the client would dutifully read as body. (The
    // client's JSON validator caught exactly this during development:
    // every declared length was right and every byte after the head was
    // zero, which a golden file full of NULs would have accepted.)
    let total = p + blen;
    write_all(fd, 0, p);
    write_all(fd, BODY_AT, blen);
    bytes = bytes + total;
    if (code < 200 || code >= 300) { errors = errors + 1; };
    body_len = blen;
};

def json_stats(p: long, heapq: bool) -> long {
    p = w(p, "{\"served\":");
    p = wn(p, served);
    p = w(p, ",\"ticks\":");
    p = wn(p, ticks);
    p = w(p, ",\"arrived\":");
    p = wn(p, arrived);
    p = w(p, ",\"rate\":");
    p = wn(p, rate);
    p = w(p, ",\"peak\":");
    p = wn(p, peak);
    p = w(p, ",\"trough\":");
    p = wn(p, trough);
    p = w(p, ",\"avg\":");
    p = wn(p, sum / WN);
    p = w(p, ",\"load\":");
    p = wn(p, sum);
    // oldest sample first: `at` is where the NEXT sample goes, so that is
    // the oldest one in the ring. A ring read from 0 would hand a client a
    // rotated series and no way to know which end was which.
    p = w(p, ",\"window\":[");
    let i = 0;
    while (i < WN) {
        if (i > 0) { p = w(p, ","); };
        p = wn(p, win[(at + i) % WN]);
        i = i + 1;
    };
    p = w(p, "],\"errors\":");
    p = wn(p, errors);
    p = w(p, ",\"bytes\":");
    p = wn(p, bytes);
    p = w(p, ",\"conns\":");
    p = wn(p, conns);
    p = w(p, ",\"uptime_ms\":");
    p = wn(p, up_ms);
    if (heapq) {
        p = w(p, ",\"heap\":");
        p = wn(p, heap_used());
        p = w(p, ",\"base_heap\":");
        p = wn(p, base_heap);
    };
    p = w(p, "}");
    p
};

def json_history(p: long) -> long {
    p = w(p, "{\"ticks\":");
    p = wn(p, ticks);
    p = w(p, ",\"peak\":");
    p = wn(p, peak);
    p = w(p, ",\"trough\":");
    p = wn(p, trough);
    p = w(p, ",\"avg\":");
    p = wn(p, sum / WN);
    p = w(p, ",\"load\":");
    p = wn(p, sum);
    p = w(p, ",\"window\":[");
    let i = 0;
    while (i < WN) {
        if (i > 0) { p = w(p, ","); };
        p = wn(p, win[(at + i) % WN]);
        i = i + 1;
    };
    p = w(p, "],\"arrived\":");
    p = wn(p, arrived);
    p = w(p, "}");
    p
};

def json_error(p: long, code: long, why: str, path: str) -> long {
    p = w(p, "{\"error\":\"");
    p = w(p, why);
    p = w(p, "\",\"status\":");
    p = wn(p, code);
    p = w(p, ",\"path\":\"");
    p = w(p, path);
    p = w(p, "\"}");
    p
};

// ── the dashboard page ─────────────────────────────────────────────────
//
// A real page, not a mock: the numbers in it are the live model, and the
// script at the bottom re-polls /api/stats every 500 ms so a browser
// watching it sees the same thing the terminal dashboard sees. The ids
// (`id=v-served`, `id=v-rate`, ...) are the contract the client checks:
// --self-test reads them out of the bytes and compares them with the JSON
// API, which is the check that the page is generated from the model rather
// than being a string someone typed once.

// one live tile: the id the client checks, then the number
def tile(p: long, id: str, v: long, label: str) -> long {
    p = w(p, "<div class=tile><b id=");
    p = w(p, id);
    p = w(p, ">");
    p = wn(p, v);
    p = w(p, "</b><span>");
    p = w(p, label);
    p = w(p, "</span></div>\n");
    p
};

def html(p: long) -> long {
    p = w(p, "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n");
    p = w(p, "<title>httpsrv dashboard</title>\n<style>\n");
    p = w(p, "body{background:#0d1117;color:#c9d1d9;font:14px/1.5 ui-monospace,monospace;margin:24px}\n");
    p = w(p, "h1{font-size:18px;margin:0}h2{font-size:13px;color:#8b949e;margin:24px 0 8px}\n");
    p = w(p, ".tiles{display:flex;gap:12px;flex-wrap:wrap}\n");
    p = w(p, ".tile{background:#161b22;border:1px solid #30363d;border-radius:6px;padding:8px 14px;min-width:96px}\n");
    p = w(p, ".tile b{display:block;font-size:22px;color:#58a6ff}\n");
    p = w(p, ".tile span{color:#8b949e;font-size:11px;text-transform:uppercase;letter-spacing:.08em}\n");
    p = w(p, "rect{fill:#58a6ff}\n</style>\n</head>\n<body>\n");
    // The tiles carry the live model, written by hand here: a curl of this
    // page shows the same numbers the JSON API and the terminal dashboard
    // show. --self-test reads them back out of the bytes and compares them
    // with /api/stats, which is the check that they are generated rather
    // than typed -- an earlier version of this page shipped literal zeros
    // and the property check caught it immediately.
    p = w(p, "<h1>httpsrv <small id=v-uptime>");
    p = wn(p, up_ms);
    p = w(p, "</small> ms uptime</h1>\n");
    p = w(p, "<div class=tiles>\n");
    p = tile(p, "v-served", served, "served");
    p = tile(p, "v-ticks", ticks, "ticks");
    p = tile(p, "v-rate", rate, "req/s");
    p = tile(p, "v-avg", sum / WN, "avg req/s");
    p = tile(p, "v-peak", peak, "peak req/s");
    p = tile(p, "v-trough", trough, "trough req/s");
    p = tile(p, "v-arrived", arrived, "arrived");
    p = w(p, "<div class=tile><b id=v-conns>");
    p = wn(p, conns);
    p = w(p, "</b><span>conns</span></div>\n");
    p = w(p, "<div class=tile><b id=v-bytes>");
    p = wn(p, bytes);
    p = w(p, "</b><span>bytes out</span></div>\n");
    p = w(p, "<div class=tile><b id=v-errors>");
    p = wn(p, errors);
    p = w(p, "</b><span>errors</span></div>\n");
    p = w(p, "</div>\n<h2>rate, last 32 samples, one per 10 ms tick</h2>\n");
    p = w(p, "<svg id=chart width=640 height=120 viewBox=\"0 0 320 60\" preserveAspectRatio=none>\n");
    // one 10-wide bar per sample, height in half-units of a 60-unit box
    let i = 0;
    while (i < WN) {
        let h = win[(at + i) % WN] * 60 / 10000;
        if (h < 1) { h = 1; };
        let y = 60 - h;
        p = w(p, "<rect x=");
        p = wn(p, i * 10);
        p = w(p, " y=");
        p = wn(p, y);
        p = w(p, " width=9 height=");
        p = wn(p, h);
        p = w(p, "/>\n");
        i = i + 1;
    };
    p = w(p, "</svg>\n<p><small>JSON: <a href=/api/stats>/api/stats</a> &middot; ");
    p = w(p, "<a href=/api/history>/api/history</a> &middot; <a href=/healthz>/healthz</a></small></p>\n");
    p = w(p, "<script>\n");
    p = w(p, "var ids=[['v-served','served'],['v-ticks','ticks'],['v-arrived','arrived'],['v-rate','rate'],");
    p = w(p, "['v-avg','avg'],['v-peak','peak'],['v-trough','trough'],['v-errors','errors'],['v-bytes','bytes'],");
    p = w(p, "['v-conns','conns'],['v-uptime','uptime_ms']];\n");
    p = w(p, "function poll(){fetch('/api/stats',{cache:'no-store'}).then(function(r){return r.json();}).then(function(d){");
    p = w(p, "for(var i=0;i<ids.length;i++){var e=document.getElementById(ids[i][0]);if(e)e.textContent=d[ids[i][1]];}");
    p = w(p, "var bars=document.querySelectorAll('#chart rect');");
    p = w(p, "for(var i=0;i<bars.length&&i<d.window.length;i++){");
    p = w(p, "var h=Math.max(1,Math.round(d.window[i]*60/1000));bars[i].setAttribute('height',h);bars[i].setAttribute('y',60-h);}");
    p = w(p, "}).catch(function(e){});}\n");
    p = w(p, "poll();setInterval(poll,500);\n</script>\n</body>\n</html>\n");
    p
};

// ── one connection ─────────────────────────────────────────────────────

const JSON_CT = "application/json";
const HTML_CT = "text/html; charset=utf-8";
const TEXT_CT = "text/plain; charset=utf-8";

def respond(fd: long, heapq: bool) {
    let code = OK;
    let ctype = TEXT_CT;
    let is_get = tok_eq(m_at, m_len, "GET");
    let known = tok_eq(t_at, t_len, "/") || tok_eq(t_at, t_len, "/api/stats") ||
                tok_eq(t_at, t_len, "/api/history") || tok_eq(t_at, t_len, "/healthz");
    let p = BODY_AT;
    if (!is_get) {
        code = NOWAY;
        ctype = JSON_CT;
        p = json_error(p, NOWAY, "method not allowed", tstr());
    } else if (!known) {
        code = NOPE;
        ctype = JSON_CT;
        p = json_error(p, NOPE, "not found", tstr());
    } else if (tok_eq(t_at, t_len, "/")) {
        ctype = HTML_CT;
        p = html(p);
    } else if (tok_eq(t_at, t_len, "/api/stats")) {
        ctype = JSON_CT;
        p = json_stats(p, heapq);
    } else if (tok_eq(t_at, t_len, "/api/history")) {
        ctype = JSON_CT;
        p = json_history(p);
    } else {
        p = w(p, "ok\n");
    };
    head_and_send(fd, code, ctype, p - BODY_AT, code == NOWAY, heapq);
};

// the target as a string, for the JSON error bodies only. It allocates --
// but only on the 404/405 paths, which is where the client is checking a
// diagnostic rather than polling, and the arena cost of that is two small
// strings per bad request rather than 42 KiB.
def tstr() -> str {
    from_bytes(rbuf[t_at : t_at + t_len])
};

// read one head and answer it. got == 0 means the peer closed without
// saying anything, which is not an error to report to nobody.
def serve_one(fd: long) {
    got = 0;
    let reading = true;
    head_end = -1;
    while (reading && got < RBUFSZ) {
        let k = syscall(0, fd, &rbuf[got], RBUFSZ - got);
        if (k <= 0) { reading = false; } else {
            got = got + k;
            head_end = find_head(got);
            if (head_end >= 0) { reading = false; };
        };
    };
    if (got <= 0) { return; };
    if (head_end < 0) {
        // no CRLFCRLF in 8 KiB: the head is too long to be one
        let p = BODY_AT;
        p = json_error(p, LONG, "request head too long", "");
        head_and_send(fd, LONG, JSON_CT, p - BODY_AT, false, false);
        return;
    };
    step();
    if (!parse_line(head_end)) {
        let p = BODY_AT;
        p = json_error(p, BAD, "bad request line", "");
        head_and_send(fd, BAD, JSON_CT, p - BODY_AT, false, false);
        return;
    };
    strip_query();
    respond(fd, query_is("heap"));
};

// ── the socket, and the fork that owns it ──────────────────────────────

// tell the parent which port the kernel gave us: port little endian in
// bytes 0..1, then the child's errno (0 when all is well) in 2..5.
def tell(wr: long, port: long, e: long) {
    msg[0] = port % 256;
    msg[1] = (port / 256) % 256;
    msg[2] = e % 256;
    msg[3] = (e / 256) % 256;
    msg[4] = (e / 65536) % 256;
    msg[5] = (e / 16777216) % 256;
    syscall(1, wr, &msg[0], 8);
};

let ppid = 0;               // the process that forked us
let port = 0;               // the port the server is on
let pid = 0;                // the forked child
let spawn_err = 0;          // why start() answered 0
let child_exit = 0;         // what the child exited with

def local_port_of(fd: long) -> long {
    gl[0] = 16;
    syscall(51, fd, &ga[0], &gl[0]);
    ga[2] * 256 + ga[3]
};

// the whole server, in the foreground of whatever process calls it: bind,
// listen, hand the port over, then accept for ever. It returns only if
// accept() fails; the usual way out is SIGTERM (see stop).
def run(port_wanted: long, mode_wanted: long, seed_wanted: long, wr: long) -> long {
    let fd = syscall(41, 2, 1, 0);
    if (fd < 0) { tell(wr, 0, fd); exit(1); };
    sa[0] = 2;
    sa[1] = 0;
    sa[2] = 0;
    sa[3] = 0;
    sa[4] = 127;              // 127.0.0.1 only: this is a loopback example,
    sa[5] = 0;                // and a server on 0.0.0.0 would be a surprise
    sa[6] = 0;
    sa[7] = 1;
    if (port_wanted > 0) {
        sa[2] = port_wanted / 256;
        sa[3] = port_wanted % 256;
    };
    let b = syscall(49, fd, &sa[0], 16);
    if (b < 0) { tell(wr, 0, b); exit(1); };
    let l = syscall(50, fd, 64);
    if (l < 0) {
        syscall(3, fd);
        tell(wr, 0, l);
        exit(1);
    };
    ppid = syscall(110, 0);  // getppid: an orphan has no client to serve
    port = port_wanted;
    if (port == 0) { port = local_port_of(fd); };
    boot(seed_wanted, mode_wanted);
    tell(wr, port, 0);
    // wr <= 2 means nobody handed us a pipe: this is --serve in the
    // foreground, so a banner is wanted.  A forked child keeps its mouth
    // shut -- its stdout is the parent's, and it would land in the middle
    // of a dashboard frame.
    let banner = wr <= 2;
    if (wr > 2) { syscall(3, wr); };
    if (banner) {
        puts("httpsrv: serving http://127.0.0.1:" + tostring(port) + "/  (seed " + tostring(seed_wanted) +
             ", " + (if (mode_wanted == REAL) { "real clock" } else { "virtual clock" }) + ")\n");
        puts("httpsrv: ^C or SIGTERM to stop; routes / /api/stats /api/history /healthz\n");
    };
    let go = true;
    while (go) {
        let c = syscall(43, fd, 0, 0);
        if (c < 0) {
            go = false;
        } else {
            conns = conns + 1;
            serve_one(c);
            syscall(3, c);
            // If the process that forked us is gone the kernel reparents
            // us to init, and there is nobody left to SIGTERM us -- so
            // leave rather than become a server for ever on a busy box.
            if (syscall(110, 0) != ppid) { go = false; };
        };
    };
    0
};

// start(port_wanted, mode_wanted, seed_wanted) -> the port, or 0 with
// spawn_err saying why. port_wanted 0 means "any free port", which is
// what the default run uses so that two copies of this example can share a
// machine without colliding; the port comes back over a pipe, because a
// fork's memory is the parent's memory and there is no shared variable.
//
// The pipe is pipe2(293) and **its two fds are 32-bit ints**: read them
// from a [byte; 8] and reassemble, or both fds arrive packed into the
// first element of a [long; 2] and the write end reads as 0 -- which is
// stdin, and a hang that looks like nothing at all.
def start(port_wanted: long, mode_wanted: long, seed_wanted: long) -> long {
    spawn_err = 0;
    port = 0;
    let fds: [byte; 8] = [0; 8];
    let rc = syscall(293, &fds[0], 0);
    if (rc < 0) {
        spawn_err = rc;
        return 0;
    };
    let rd = fds[0] + fds[1]*256 + fds[2]*65536 + fds[3]*16777216;
    let wr = fds[4] + fds[5]*256 + fds[6]*65536 + fds[7]*16777216;
    pid = fork { run(port_wanted, mode_wanted, seed_wanted, wr) };
    syscall(3, wr);
    let got = 0;
    let alive = true;
    while (got < 8 && alive) {
        let k = syscall(0, rd, &msg[got], 8 - got);
        if (k <= 0) { alive = false; } else { got = got + k; };
    };
    syscall(3, rd);
    if (got < 8) {
        spawn_err = -11;
        port = 0;
    } else {
        let e = msg[2] + msg[3]*256 + msg[4]*65536 + msg[5]*16777216;
        if (e != 0) { spawn_err = e; port = 0; } else { port = msg[0] + msg[1]*256; };
    };
    port
};

// stop() -- the only way out of a process that cannot be interrupted: Y
// has no signal handlers, so the kernel is asked directly. The child's
// 143 is 128 + 15 (SIGTERM), and that is what stop() answers, so a caller
// can tell a killed server from a crashed one.
def stop(p: long) -> long {
    child_exit = wait_pid(p);
    child_exit
};

def kill(p: long) {
    syscall(62, p, 15);
};

export {
    WN, VIRTUAL, REAL, TICK_MS, DEFAULT_SEED, RBUFSZ, OBUFSZ,
    seed, mode, win, ticks, served, arrived, rate, peak, trough, sum, errors, bytes, conns,
    up_ms, base_heap, body_len, port, pid, spawn_err, child_exit,
    boot, step, local_port_of, run, start, stop, kill
};