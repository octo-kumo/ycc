// std/ipc.y -- local sockets: connect to a Unix-domain socket, send and
// receive bytes, wait for data. The plumbing under `snd` (PulseAudio) and `x11`.
//
//     import ipc;
//     let fd = ipc.connect_unix("/run/user/1000/pulse/native");
//     if (fd >= 0) { ipc.send(fd, bytes("hello")); ipc.close(fd); }
//
// Through the named OS layer (os_call): Linux system calls, or Winsock on Windows, no libc. Failures are values: `connect_unix`
// answers a negative errno, `recv_exact` and `recv_some` answer `none` at end of
// stream or on an error, `send` answers false.
export { connect_unix, send, recv_exact, recv_some, wait_readable, close };

/** Opens a stream socket and connects it to the Unix-domain socket at `path`
(up to 107 bytes); the file descriptor, or a negative errno. */
def connect_unix(path: str) -> long {
    if (len(path) > 107) { return -36; };
    let fd = os_call("y_os_socket", 1, 524289, 0);
    if (fd < 0) { return fd; };
    let a: [byte; 110] = [0; 110];
    a[0] = 1;
    let b = bytes(path);
    let i = 0;
    while (i < b.length) { a[2 + i] = b[i]; i = i + 1; };
    let r = os_call("y_os_connect", fd, &a[0], 3 + b.length);
    if (r < 0) {
        os_call("y_os_closesocket", fd);
        return r;
    };
    fd
};

/** Writes all of `data` to `fd`; false if the peer has gone or the write fails. */
def send(fd: long, data: [byte]) -> bool {
    let off = 0;
    while (off < data.length) {
        let n = os_call("y_os_send", fd, &data[off], data.length - off, 16384);
        if (n == -4) { continue; };
        if (n <= 0) { return false; };
        off = off + n;
    };
    true
};

def buffer(n: long) -> [byte] {
    let b: [byte] = [];
    let chunk: [byte] = [];
    let i = 0;
    while (i < 4096) { chunk += 0; i = i + 1; };
    while (b.length + 4096 <= n) { b += chunk; };
    while (b.length < n) { b += 0; };
    b
};

/** Reads exactly `n` bytes, waiting for them; `none` if the stream ends first. */
def recv_exact(fd: long, n: long) -> [byte]? {
    let b = buffer(n);
    let off = 0;
    while (off < n) {
        let k = os_call("y_os_recv", fd, &b[off], n - off);
        if (k == -4) { continue; };
        if (k <= 0) { return none; };
        off = off + k;
    };
    some(b)
};

/** Reads whatever is there, up to `max` bytes, waiting for at least one;
`none` at end of stream. */
def recv_some(fd: long, max: long) -> [byte]? {
    let b = buffer(max);
    let k = 0 - 4;
    while (k == -4) { k = os_call("y_os_recv", fd, &b[0], max); };
    if (k <= 0) { return none; };
    some(b[0:k])
};

/** True if `fd` has data to read (or has hung up, so a read would answer at
once) within `ms` milliseconds; a negative `ms` waits for ever. */
def wait_readable(fd: long, ms: long) -> bool {
    let p: [byte; 8] = [0; 8];
    p[0] = fd & 255;
    p[1] = (fd >> 8) & 255;
    p[2] = (fd >> 16) & 255;
    p[3] = (fd >> 24) & 255;
    p[4] = 1;
    let r = os_call("y_os_poll", &p[0], 1, ms);
    r > 0
};

/** Closes `fd`. */
def close(fd: long) -> long {
    os_call("y_os_closesocket", fd)
};
