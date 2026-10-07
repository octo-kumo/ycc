// std/net.y — TCP and a minimal HTTP server, over raw Linux sockets.
//
// OPTIONAL std module: `import net;` splices this file and every function
// is called through the `net` namespace:
//
//     import net;
//
//     def hello(req: str) -> str {
//         net.http_response(200, "hi there")
//     };
//
//     net.listen_http(8080, hello);      // blocks, serving forever
//     // net.listen_tcp(22, handler);    // same, raw connections
//
// Host names resolve through /etc/hosts and DNS (resolve, resolve_with:
// UDP, then TCP for a truncated answer), so connect_tcp takes a name.
//
// Everything here is ordinary Y over the `syscall` intrinsic: the socket
// API is just syscalls 41 (socket) 42 (connect) 43 (accept) 49 (bind)
// 50 (listen) 51 (getsockname) plus read/write/close. A sockaddr_in is a
// 16-byte buffer built element by element — note that the port is BIG
// endian (network byte order), while every other field is written a byte
// at a time, so no host-order surprise.
//
// A module imported by name keeps its own scope (rename.y): the importer
// calls net.close_fd(...), and these names never meet the program's. The
// socket verbs carry a suffix that says what they do (`socket_tcp`,
// `listen_fd`, `accept_tcp`); `send_str`/`recv_str`/`close_fd` take an fd.

import fs;

// socket(AF_INET=2, SOCK_STREAM=1, 0) -> fd, or a negative errno.
def socket_tcp() -> long {
    syscall(41, 2, 1, 0)
};

// Fill a sockaddr_in for a dotted-quad host ("127.0.0.1") and port.
// Returns 0 either way: there is nothing to report here, and a host that
// does not split into exactly four parts leaves the address at 0.0.0.0.
def addr_set(a: [byte; 16], host: str, port: long) -> long {
    a[0] = 2;
    a[1] = 0;
    a[2] = port / 256;
    a[3] = port % 256;
    a[4] = 0;
    a[5] = 0;
    a[6] = 0;
    a[7] = 0;
    let d = split(host, ".");
    if (len(d) == 4) {
        // One octet at a time, leaving 0 where the part is not a number --
        // which is the read this had before tolong required a fully valid
        // input (it stopped at the first non-digit and answered what it had).
        let o0 = tolong(d[0]);
        let o1 = tolong(d[1]);
        let o2 = tolong(d[2]);
        let o3 = tolong(d[3]);
        if (o0 != none) { a[4] = o0 !; };
        if (o1 != none) { a[5] = o1 !; };
        if (o2 != none) { a[6] = o2 !; };
        if (o3 != none) { a[7] = o3 !; };
    }
    0
};

// A call that cannot go on, named: `what` says what failed and `errno` the
// kernel's own answer (syscalls give it negative). The listeners use it
// instead of carrying on, which is what this module used to do with a bind
// that failed: the socket was bound to nothing, listen had nothing to listen
// on, accept answered at once and the server returned 0 -- so a program that
// asked for a busy port got what looked like a server that had served
// nothing, and no word about why.
def net_error(what: str, errno: long) -> long {
    let name = if (errno == -98) { " (address in use)" } else {
        if (errno == -13) { " (permission denied)" } else {
            if (errno == -99) { " (address not available)" } else { "" }
        }
    };
    puts("net: " + what + ": errno " + tostring(errno) + name + "\n");
    exit(1);
    0
};

// bind(fd, port) on 0.0.0.0, answering the syscall's own result: 0 when the
// socket is bound, negative errno when it could not be (a port already in
// use is -98). A caller that ignores that answer is listening on a socket
// bound to nothing -- see listen_tcp. Port 0 lets the kernel pick a free
// one; read it back with local_port.
def bind_tcp(fd: long, port: long) -> long {
    let a: [byte; 16] = [0; 16];
    addr_set(a, "0.0.0.0", port);
    syscall(49, fd, &a[0], 16)
};

def listen_fd(fd: long, backlog: long) -> long {
    syscall(50, fd, backlog)
};

// accept(fd) -> a connected fd, or a negative errno.
def accept_tcp(fd: long) -> long {
    syscall(43, fd, 0, 0)
};

// connect_tcp(host, port) -> a connected fd, or a negative errno. A host
// name is resolved first (resolve): each of its addresses is tried in
// turn, and a name with none gives -2 (ENOENT). A failed connect closes the
// socket before returning the errno: the caller only ever gets a usable fd
// or an error, never an fd it would have to know to close.
def connect_tcp(host: str, port: long) -> long {
    let addrs = resolve(host);
    let r = -2;
    foreach (a in addrs) {
        if (r < 0) { r = connect_addr(a, port); };
    };
    r
};

// connect_tcp to one dotted-quad address.
def connect_addr(host: str, port: long) -> long {
    let fd = socket_tcp();
    if (fd < 0) {
        fd
    } else {
        let a: [byte; 16] = [0; 16];
        addr_set(a, host, port);
        let r = syscall(42, fd, &a[0], 16);
        if (r < 0) {
            syscall(3, fd);
            r
        } else {
            fd
        }
    }
};

// The port the kernel assigned (for bind_tcp(fd, 0)).
def local_port(fd: long) -> long {
    let a: [byte; 16] = [0; 16];
    let l: [long; 1] = [16; 1];
    syscall(51, fd, &a[0], &l[0]);
    a[2] * 256 + a[3]
};

// send_str(fd, data) -> bytes written (a str is already its bytes, and
// len() is its length). One write(2): a short write is the caller's to
// finish, nothing here retries.
def send_str(fd: long, data: str) -> long {
    syscall(1, fd, data, len(data))
};

// recv_str(fd, max) -> up to max bytes as a str, none at EOF/error.
// One read(2), so `max` is clamped to the 4096-byte buffer below and a
// larger ask silently caps at that: call it again to read more.
def recv_str(fd: long, max: long) -> str? {
    let buf: [byte; 4096] = [0; 4096];
    let n = max;
    if (n > 4096) {
        n = 4096;
    }
    if (n < 0) {
        n = 0;
    }
    let k = syscall(0, fd, &buf[0], n);
    if (k <= 0) {
        none
    } else {
        let out: [byte] = [];
        let i = 0;
        while (i < k) {
            out += buf[i];
            i = i + 1;
        };
        some(from_bytes(out))
    }
};

def close_fd(fd: long) -> long {
    syscall(3, fd)
};

// ── names: /etc/hosts, then DNS (RFC 1035) ─────────────────────────────

// The last query's ID (resolve_with): each one moves it on.
let dns_id = 0;

// resolve(name) -> the IPv4 addresses of a host, dotted quads; [] when it
// has none. A dotted quad is itself. Otherwise /etc/hosts, then an A query
// to each nameserver of /etc/resolv.conf in turn (127.0.0.1 when it names
// none) until one answers with addresses: resolve_with. A name without a
// dot is tried under each `search` domain first, then alone.
def resolve(name: str) -> [str] {
    let out: [str] = [];
    if (is_quad(name)) {
        out += name;
        return out;
    };
    out = hosts_lookup(name);
    let conf = resolv_conf();
    let names: [str] = [];
    if (index_of(name, ".") < 0) {
        foreach (d in conf.search) { names += name + "." + d; };
    };
    names += name;
    foreach (n in names) {
        foreach (ns in conf.servers) {
            if (len(out) == 0) { out = resolve_with(n, ns, 53); };
        };
    };
    out
};

// resolve_with(name, server, port) -> the addresses one DNS server gives
// for name (its A records, CNAMEs followed by the server): a query over
// UDP, asked twice with 2 s to answer, then over TCP when the answer came
// back truncated. [] for no answer, an error (NXDOMAIN included) or a
// malformed packet -- which never stops the program.
def resolve_with(name: str, server: str, port: long) -> [str] {
    let out: [str] = [];
    dns_id = (dns_id + (time_us() & 65535) + 1) & 65535;
    let q = dns_query(name, dns_id);
    if (len(q) > 0) {
        let r = dns_udp(q, server, port);
        if (len(r) > 3 && (r[2] & 2) != 0) { r = dns_tcp(q, server, port); };
        out = dns_answers(r, q);
    };
    out
};

// /etc/resolv.conf: its nameservers (IPv4; 127.0.0.1 when it names none)
// and its search domains (`search`, or the older `domain`).
def resolv_conf() -> { servers: [str], search: [str] } {
    let servers: [str] = [];
    let search: [str] = [];
    let text = fs.read_file("/etc/resolv.conf");
    if (text != none) {
        foreach (line in text !.lines()) {
            let f = words(line);
            if (len(f) >= 2 && f[0] == "nameserver" && is_quad(f[1])) { servers += f[1]; };
            if (len(f) >= 2 && (f[0] == "search" || f[0] == "domain")) { search = f[1:len(f)]; };
        };
    };
    if (len(servers) == 0) { servers += "127.0.0.1"; };
    { servers: servers, search: search }
};

// The addresses /etc/hosts gives name (IPv4 lines; names compare without
// regard to case, `#` starts a comment).
def hosts_lookup(name: str) -> [str] {
    let out: [str] = [];
    let want = name.lower();
    let text = fs.read_file("/etc/hosts");
    if (text != none) {
        foreach (line in text !.lines()) {
            let hash = index_of(line, "#");
            let body = line;
            if (hash >= 0) { body = line[0:hash]; };
            let f = words(body);
            if (len(f) >= 2 && is_quad(f[0])) {
                let i = 1;
                while (i < len(f)) {
                    if (f[i].lower() == want && !has_str(out, f[0])) { out += f[0]; };
                    i = i + 1;
                };
            };
        };
    };
    out
};

// s is among xs.
def has_str(xs: [str], s: str) -> bool {
    let found = false;
    foreach (x in xs) {
        if (x == s) { found = true; };
    };
    found
};

// The words of s: its runs of characters other than spaces and tabs.
def words(s: str) -> [str] {
    let out: [str] = [];
    let start = -1;
    let i = 0;
    while (i <= len(s)) {
        let blank = i == len(s) || s[i] == ' ' || s[i] == '\t' || s[i] == '\r';
        if (blank && start >= 0) {
            out += s[start:i];
            start = -1;
        } else if (!blank && start < 0) {
            start = i;
        };
        i = i + 1;
    };
    out
};

// s is a dotted quad: four numbers 0..255.
def is_quad(s: str) -> bool {
    let d = split(s, ".");
    let ok = len(d) == 4;
    foreach (p in d) {
        if (len(p) == 0 || len(p) > 3) { ok = false; };
        let i = 0;
        while (ok && i < len(p)) {
            if (p[i] < '0' || p[i] > '9') { ok = false; };
            i = i + 1;
        };
        if (ok) {
            let pn = tolong(p);
            if (pn == none || pn ! > 255) { ok = false; };
        };
    };
    ok
};

// A query for the A records of name (recursion desired), id its ID; []
// for a name no query can carry (a label over 63 bytes, over 253 in all).
def dns_query(name: str, id: long) -> [byte] {
    let q: [byte] = [];
    q += (id >> 8) & 255;
    q += id & 255;
    q += 1;
    q += 0;
    q += 0;
    q += 1;
    let i = 0;
    while (i < 6) {
        q += 0;
        i = i + 1;
    };
    let ok = len(name) > 0 && len(name) <= 253;
    foreach (label in split(name, ".")) {
        if (len(label) > 63) { ok = false; };
        if (len(label) > 0) {
            q += len(label);
            q += bytes(label);
        };
    };
    q += 0;
    q += 0;
    q += 1;
    q += 0;
    q += 1;
    if (!ok) {
        let none_q: [byte] = [];
        return none_q;
    };
    q
};

// SO_RCVTIMEO and SO_SNDTIMEO of fd: secs seconds (a connect waits as
// long as a send).
def set_timeouts(fd: long, secs: long) -> long {
    let tv: [long; 2] = [0; 2];
    tv[0] = secs;
    syscall(54, fd, 1, 20, &tv[0], 16);
    syscall(54, fd, 1, 21, &tv[0], 16)
};

// Query q over UDP to server:port: the answer with q's ID, or [] when two
// tries in 2 s each get none.
def dns_udp(q: [byte], server: str, port: long) -> [byte] {
    let out: [byte] = [];
    let fd = syscall(41, 2, 2, 0);
    if (fd < 0) { return out; };
    set_timeouts(fd, 2);
    let a: [byte; 16] = [0; 16];
    addr_set(a, server, port);
    if (syscall(42, fd, &a[0], 16) == 0) {
        let tries = 0;
        while (len(out) == 0 && tries < 2) {
            syscall(1, fd, &q[0], len(q));
            let buf: [byte; 4096] = [0; 4096];
            let k = syscall(0, fd, &buf[0], 4096);
            if (k >= 12 && buf[0] == q[0] && buf[1] == q[1]) { out = buf[0:k]; };
            tries = tries + 1;
        };
    };
    syscall(3, fd);
    out
};

// Query q over TCP to server:port (each message after its 2-byte length):
// the answer, or [] when the connection fails.
def dns_tcp(q: [byte], server: str, port: long) -> [byte] {
    let out: [byte] = [];
    let fd = socket_tcp();
    if (fd < 0) { return out; };
    set_timeouts(fd, 3);
    let a: [byte; 16] = [0; 16];
    addr_set(a, server, port);
    if (syscall(42, fd, &a[0], 16) == 0) {
        let msg: [byte] = [];
        msg += (len(q) >> 8) & 255;
        msg += len(q) & 255;
        msg += q;
        if (syscall(1, fd, &msg[0], len(msg)) == len(msg)) {
            let got = read_n(fd, 2);
            if (len(got) == 2) { out = read_n(fd, got[0] * 256 + got[1]); };
        };
    };
    syscall(3, fd);
    out
};

// n bytes from fd, or fewer when it ends or fails first.
def read_n(fd: long, n: long) -> [byte] {
    let out: [byte] = [];
    let buf: [byte; 4096] = [0; 4096];
    let go = n > 0;
    while (go) {
        let want = n - len(out);
        if (want > 4096) { want = 4096; };
        let k = syscall(0, fd, &buf[0], want);
        if (k <= 0) { go = false; } else {
            out += buf[0:k];
            go = len(out) < n;
        };
    };
    out
};

// The A records of DNS answer r to query q, as dotted quads: [] for
// another query's answer, an error or a malformed packet.
def dns_answers(r: [byte], q: [byte]) -> [str] {
    let out: [str] = [];
    let n = len(r);
    if (n < 12 || len(q) < 2 || r[0] != q[0] || r[1] != q[1] || (r[2] & 128) == 0 || (r[3] & 15) != 0) {
        return out;
    };
    let qd = r[4] * 256 + r[5];
    let an = r[6] * 256 + r[7];
    let p = 12;
    let i = 0;
    while (p >= 0 && i < qd) {
        p = dns_skip_name(r, p);
        if (p >= 0) { p = p + 4; };
        i = i + 1;
    };
    i = 0;
    while (p >= 0 && i < an) {
        p = dns_skip_name(r, p);
        if (p >= 0 && p + 10 <= n) {
            let typ = r[p] * 256 + r[p + 1];
            let cls = r[p + 2] * 256 + r[p + 3];
            let rdlen = r[p + 8] * 256 + r[p + 9];
            p = p + 10;
            if (p + rdlen > n) { p = -1; } else {
                if (typ == 1 && cls == 1 && rdlen == 4) {
                    out += tostring(r[p]) + "." + tostring(r[p + 1]) + "." + tostring(r[p + 2]) + "." + tostring(r[p + 3]);
                };
                p = p + rdlen;
            };
        } else { p = -1; };
        i = i + 1;
    };
    out
};

// The index just past the name at p in packet r -- its labels, ended by
// a zero byte or a compression pointer -- or -1 when it runs off the end.
def dns_skip_name(r: [byte], p: long) -> long {
    let n = len(r);
    let at = p;
    let done = false;
    while (!done) {
        if (at < 0 || at >= n) {
            at = -1;
            done = true;
        } else {
            let b: long = r[at];
            if (b == 0) {
                at = at + 1;
                done = true;
            } else if ((b & 192) == 192) {
                at = at + 2;
                if (at > n) { at = -1; };
                done = true;
            } else if ((b & 192) != 0) {
                at = -1;
                done = true;
            } else {
                at = at + 1 + b;
            };
        };
    };
    at
};

// http_response(status, body) -> a complete HTTP/1.1 response.
def http_response(status: long, body: str) -> str {
    let code = "200";
    let text = "OK";
    if (status == 404) {
        code = "404";
        text = "Not Found";
    } else if (status == 500) {
        code = "500";
        text = "Internal Server Error";
    } else if (status != 200) {
        code = tostring(status);
        text = "Status";
    }
    "HTTP/1.1 " + code + " " + text + "\r\nContent-Length: " + tostring(len(body))
    + "\r\nConnection: close\r\n\r\n" + body
};

// http_read_head(fd) -> the request head: every chunk read until the blank
// line that ends it shows up (or the peer goes quiet, or 64 KiB has piled
// up -- the last two are the safety valves). Bytes of the BODY may already
// be in the string when a client pipelines them with the head.
def http_read_head(fd: long) -> str {
    let out = "";
    let done = false;
    while (!done) {
        let chunk = recv_str(fd, 1024);
        if (is_some(chunk)) {
            out = out + unwrap(chunk);
            if (index_of(out, "\r\n\r\n") >= 0) {
                done = true;
            }
            if (len(out) > 65536) {
                done = true;
            }
        } else {
            done = true;
        };
    };
    out
};

// http_serve_one(fd, handler): read one request, answer it, close the
// connection. `handler` receives the request head and returns the FULL
// response — build it with http_response.
def http_serve_one(fd: long, handler: (str) -> str) -> long {
    let req = http_read_head(fd);
    let resp = handler(req);
    send_str(fd, resp);
    close_fd(fd);
    0
};

// listen_tcp(port, handler): bind + listen + accept until an accept fails.
// `handler` receives each connection fd and the LOOP closes it once the
// handler returns -- it must not close it itself, or that close hits a
// recycled fd. As in listen_http, socket/bind/listen results go unchecked.
def listen_tcp(port: long, handler: (long) -> long) -> long {
    let fd = socket_tcp();
    let b = bind_tcp(fd, port);
    if (b < 0) { net_error("cannot listen on port " + tostring(port), b); };
    let l = listen_fd(fd, 16);
    if (l < 0) {
        close_fd(fd);
        net_error("cannot listen on port " + tostring(port), l);
    };
    let go = true;
    while (go) {
        let c = accept_tcp(fd);
        if (c >= 0) {
            handler(c);
            close_fd(c);
        } else {
            go = false;
        };
    };
    0
};

// listen_http(port, handler): a tiny blocking HTTP server. `handler` maps
// a request head to a response, usually `net.http_response(code, body)`.
// Same loop as listen_tcp, and the same check: a port that could not be
// bound is reported, not carried on from.
def listen_http(port: long, handler: (str) -> str) -> long {
    let fd = socket_tcp();
    let b = bind_tcp(fd, port);
    if (b < 0) { net_error("cannot serve on port " + tostring(port), b); };
    let l = listen_fd(fd, 16);
    if (l < 0) {
        close_fd(fd);
        net_error("cannot serve on port " + tostring(port), l);
    };
    let go = true;
    while (go) {
        let c = accept_tcp(fd);
        if (c >= 0) {
            http_serve_one(c, handler);
        } else {
            go = false;
        };
    };
    0
};

export { socket_tcp, bind_tcp, listen_fd, accept_tcp, connect_tcp, local_port, send_str, recv_str, close_fd, addr_set, resolve, resolve_with, is_quad, set_timeouts, http_response, http_read_head, http_serve_one, listen_tcp, listen_http };
