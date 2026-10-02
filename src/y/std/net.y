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
        a[4] = tonum(d[0]);
        a[5] = tonum(d[1]);
        a[6] = tonum(d[2]);
        a[7] = tonum(d[3]);
        0
    } else { 0; };
    0
};

// bind(fd, port) on 0.0.0.0. Port 0 lets the kernel pick a free one —
// read it back with local_port.
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

// connect_tcp(host, port) -> a connected fd, or a negative errno. A failed
// connect closes the socket before returning the errno: the caller only ever
// gets a usable fd or an error, never an fd it would have to know to close.
def connect_tcp(host: str, port: long) -> long {
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
        0
    } else { 0; };
    if (n < 0) {
        n = 0;
        0
    } else { 0; };
    let k = syscall(0, fd, &buf[0], n);
    if (k <= 0) {
        none
    } else {
        let out: [byte] = [];
        let i = 0;
        while (i < k) {
            out += buf[i];
            i = i + 1;
            0
        };
        some(from_bytes(out))
    }
};

def close_fd(fd: long) -> long {
    syscall(3, fd)
};

// http_response(status, body) -> a complete HTTP/1.1 response.
def http_response(status: long, body: str) -> str {
    let code = "200";
    let text = "OK";
    if (status == 404) {
        code = "404";
        text = "Not Found";
        0
    } else if (status == 500) {
        code = "500";
        text = "Internal Server Error";
        0
    } else if (status != 200) {
        code = tostring(status);
        text = "Status";
        0
    } else { 0; };
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
                0
            } else { 0; };
            if (len(out) > 65536) {
                done = true;
                0
            } else { 0; };
            0
        } else {
            done = true;
            0
        };
        0
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
    bind_tcp(fd, port);
    listen_fd(fd, 16);
    let go = true;
    while (go) {
        let c = accept_tcp(fd);
        if (c >= 0) {
            handler(c);
            close_fd(c);
            0
        } else {
            go = false;
            0
        };
        0
    };
    0
};

// listen_http(port, handler): a tiny blocking HTTP server. `handler` maps
// a request head to a response, usually `net.http_response(code, body)`.
// Same loop as listen_tcp: accept until an accept fails, and the socket,
// bind and listen results are not checked -- a busy port shows up as an
// immediate return of 0 rather than an error.
def listen_http(port: long, handler: (str) -> str) -> long {
    let fd = socket_tcp();
    bind_tcp(fd, port);
    listen_fd(fd, 16);
    let go = true;
    while (go) {
        let c = accept_tcp(fd);
        if (c >= 0) {
            http_serve_one(c, handler);
            0
        } else {
            go = false;
            0
        };
        0
    };
    0
};

export { socket_tcp, bind_tcp, listen_fd, accept_tcp, connect_tcp, local_port, send_str, recv_str, close_fd, addr_set, http_response, http_read_head, http_serve_one, listen_tcp, listen_http };
