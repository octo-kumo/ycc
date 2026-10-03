// A fake DNS server for test_net.sh, on UDP and TCP port argv[1] of
// 127.0.0.1: two.test is a CNAME of real.test, which has 10.1.2.3 and
// 10.4.5.6; trunc.test answers truncated over UDP, then in full (10.7.8.9)
// over TCP; garbage.test gets a packet that claims answers it does not
// hold; anything else is NXDOMAIN. It prints "ready" once both sockets
// are bound, and serves until it is killed.
import net;

let port = tonum(argv()[1]);

// The name a query asks for (its first question), labels joined by dots.
def qname(q: [byte]) -> str {
    let parts: [str] = [];
    let p = 12;
    while (p < len(q) && q[p] != 0) {
        let n: long = q[p];
        parts += from_bytes(q[p + 1:p + 1 + n]);
        p = p + 1 + n;
    };
    join(parts, ".")
};

// The bytes of a query's question: its name, type and class.
def question(q: [byte]) -> [byte] {
    let p = 12;
    while (p < len(q) && q[p] != 0) { p = p + 1 + q[p]; };
    q[12:p + 5]
};

// A name in labels, ending in a zero byte.
def labels(name: str) -> [byte] {
    let out: [byte] = [];
    foreach (l in name.split(".")) {
        out += len(l);
        out += bytes(l);
    };
    out += 0;
    out
};

// A resource record: owner (bytes), type, class IN, a TTL of 60, rdata.
def rr(owner: [byte], typ: long, rdata: [byte]) -> [byte] {
    let out: [byte] = [];
    out += owner;
    out += 0;
    out += typ;
    out += 0;
    out += 1;
    out += [0, 0, 0, 60];
    out += (len(rdata) >> 8) & 255;
    out += len(rdata) & 255;
    out += rdata;
    out
};

// The answer to query q: its ID and question, flags (QR, AA, RD as asked,
// RA; tc: truncated) and rcode, then `count` answer records `body`.
def reply(q: [byte], tc: bool, rcode: long, count: long, body: [byte]) -> [byte] {
    let out: [byte] = [];
    out += q[0];
    out += q[1];
    let f1 = 128 | 4 | (q[2] & 1);
    if (tc) { f1 = f1 | 2; };
    out += f1;
    out += 128 | rcode;
    out += [0, 1, 0, count, 0, 0, 0, 0];
    out += question(q);
    out += body;
    out
};

// two.test's answer: a CNAME to real.test, then its two A records, owned
// through a pointer to the CNAME's data.
def two_body(q: [byte]) -> [byte] {
    let qlen = len(question(q));
    let target = labels("real.test");
    let top: [byte] = [192, 12];
    let body = rr(top, 5, target);
    let at = 12 + qlen + 12;
    let owner: [byte] = [];
    owner += 192 | (at >> 8);
    owner += at & 255;
    let a1: [byte] = [10, 1, 2, 3];
    let a2: [byte] = [10, 4, 5, 6];
    body += rr(owner, 1, a1);
    body += rr(owner, 1, a2);
    body
};

def send_to(fd: long, data: [byte], from: [byte; 16]) -> long {
    syscall(44, fd, &data[0], len(data), 0, &from[0], 16)
};

// The full answer to a truncated query, over one TCP connection.
def serve_tcp(tfd: long) {
    let c = net.accept_tcp(tfd);
    if (c >= 0) {
        let buf: [byte; 512] = [0; 512];
        let k = syscall(0, c, &buf[0], 512);
        if (k > 2) {
            let q = buf[2:k];
            let top: [byte] = [192, 12];
            let addr: [byte] = [10, 7, 8, 9];
            let full = reply(q, false, 0, 1, rr(top, 1, addr));
            let msg: [byte] = [];
            msg += (len(full) >> 8) & 255;
            msg += len(full) & 255;
            msg += full;
            syscall(1, c, &msg[0], len(msg));
        };
        net.close_fd(c);
    };
};

let ufd = syscall(41, 2, 2, 0);
let a: [byte; 16] = [0; 16];
net.addr_set(a, "127.0.0.1", port);
if (syscall(49, ufd, &a[0], 16) != 0) { exit(2); };
let tfd = net.socket_tcp();
if (net.bind_tcp(tfd, port) != 0) { exit(2); };
net.listen_fd(tfd, 4);
puts("ready\n");
while (true) {
    let buf: [byte; 512] = [0; 512];
    let from: [byte; 16] = [0; 16];
    let fl: [long; 1] = [16; 1];
    let k = syscall(45, ufd, &buf[0], 512, 0, &from[0], &fl[0]);
    if (k >= 17) {
        let q = buf[0:k];
        let name = qname(q);
        if (name == "two.test") {
            send_to(ufd, reply(q, false, 0, 3, two_body(q)), from);
        } else if (name == "trunc.test") {
            send_to(ufd, reply(q, true, 0, 0, []), from);
            serve_tcp(tfd);
        } else if (name == "garbage.test") {
            let junk: [byte] = [192, 12, 0, 1, 0, 1, 0, 0];
            send_to(ufd, reply(q, false, 0, 5, junk), from);
        } else {
            send_to(ufd, reply(q, false, 3, 0, []), from);
        };
    };
};
