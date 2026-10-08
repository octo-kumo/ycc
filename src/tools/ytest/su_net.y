// su_net.y -- the net, http and tls modules over loopback.
//
// The blocking listeners (listen_http, listen_tcp): the first connection is
// the readiness probe, the next one makes each handler exit cleanly, and one
// serves 100 connections under `ulimit -n 32` (an fd leak per accept fails
// it). Then the resolver against a fake DNS server (test/y/net/dns_srv.y), the
// http client against test/y/net/http_srv.y, and the TLS 1.3 client against
// `openssl s_server` when the machine has openssl. Every program is built by
// both copies, which must agree byte for byte.
import fs;
import net;
import yt;
import yc;

let W = "";
let SEED = 0;

// A port in 20000..60000, different in every case and every try.
def random_port() -> long {
    SEED = (SEED * 6364136223846793005 + 1442695040888963407 + clock_us()) & 9223372036854775807;
    20000 + (SEED >> 20) % 40001
};

// Both copies build test/y/net/NAME.y to the same bytes: W/NAME.ref, W/NAME.copy.
def pair(name: str) -> bool {
    let src = yc.ROOT + "/test/y/net/" + name + ".y";
    let r = yc.compile(yc.YREF, [], src, W + "/" + name + ".ref", 60);
    if (r.code != 0) {
        yt.fail(name + " reference compile", yt.clip(r.out, 300));
        return false;
    };
    let c = yc.compile(yc.CYCC, [], src, W + "/" + name + ".copy", 60);
    if (c.code != 0) {
        yt.fail(name + " C-copy compile", yt.clip(c.out, 300));
        return false;
    };
    yt.check(name + " compiler parity", yt.same_file(W + "/" + name + ".ref", W + "/" + name + ".copy"),
        "compiled server binaries differ")
};

def server(argv: [str], nofile: long) -> yt.Proc {
    let c = yt.cmd(argv);
    c.merge = true;
    c.timeout = 20;
    c.nofile = nofile;
    c.out = yt.tmp("srv");
    yt.start(c)
};

def stop(p: yt.Proc) {
    yt.kill(p);
    yt.wait(p);
};

// Connect to 127.0.0.1:port, send `req`, read to EOF within 3 s: the reply,
// or none when there was no connection or no clean end.
def request(port: long, req: str, read: bool) -> str? {
    let fd = net.connect_tcp("127.0.0.1", port);
    if (fd < 0) { return none; };
    if (req != "" && syscall(1, fd, req, req.length) != req.length) {
        syscall(3, fd);
        return none;
    };
    if (!read) {
        syscall(3, fd);
        return some("");
    };
    let out: [byte] = [];
    let buf: [byte; 4096] = [0; 4096];
    let deadline = clock_us() + 3000000;
    let pfd: [long; 1] = [0; 1];
    let go = true;
    while (go) {
        pfd[0] = fd + 4294967296;
        let left = (deadline - clock_us()) / 1000;
        if (left <= 0 || syscall(7, &pfd[0], 1, left) <= 0) {
            syscall(3, fd);
            return none;
        };
        let k = syscall(0, fd, &buf[0], 4096);
        if (k < 0) {
            syscall(3, fd);
            return none;
        };
        if (k == 0) { go = false; } else { out += buf[0:k]; };
    };
    syscall(3, fd);
    some(from_bytes(out))
};

// Start a listener and probe it until it answers `want` (20 ports, 5 s each):
// the server and its port, or the server with port 0 and the reason in `why`.
def listener(bin: str, limit: long, nofile: long, probe: str, want: str, why: [str]) -> yt.Proc {
    for attempt in 0..20 {
        let port = random_port();
        let p = server([bin, tostring(port), tostring(limit)], nofile);
        let polls = 0;
        while (polls < 50 && yt.alive(p)) {
            let got = request(port, probe, true);
            if (got != none) {
                if (got! == want && yt.alive(p)) {
                    why[0] = tostring(port);
                    return p;
                };
                why[0] = "port " + tostring(port) + " answered with a different response; retrying";
                polls = 50;
            } else {
                yt.sleep_us(100000);
                polls += 1;
            };
        };
        stop(p);
    };
    if (why[0] == "") { why[0] = "no listener became ready after 20 port attempts"; };
    server(["true"], 0)
};

let HTTP_OK = "HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\nhttp-ok";

def http_listener(bin: str, label: str) {
    let why = [""];
    let p = listener(bin, 2, 0, "GET /x HTTP/1.0\r\n\r\n", HTTP_OK, why);
    let port = yt.num(why[0], 0);
    if (port == 0) {
        yt.fail(label + " listen_http", why[0]);
        return;
    };
    if (request(port, "GET /stop HTTP/1.0\r\n\r\n", false) == none) {
        yt.fail(label + " listen_http", "could not send the handler's final request");
        stop(p);
        return;
    };
    let r = yt.wait(p);
    yt.check(label + " listen_http response and exit", r.code == 0, "server did not exit successfully");
};

def tcp_listener(bin: str, label: str) {
    let why = [""];
    let p = listener(bin, 2, 0, "ping", "tcp-ok", why);
    let port = yt.num(why[0], 0);
    if (port == 0) {
        yt.fail(label + " listen_tcp", why[0]);
        return;
    };
    if (request(port, "", false) == none) {
        yt.fail(label + " listen_tcp", "could not open the handler's final connection");
        stop(p);
        return;
    };
    yt.check(label + " listen_tcp response and exit", yt.wait(p).code == 0, "server did not exit successfully");
};

def tcp_leak(bin: str, label: str) {
    let why = [""];
    let p = listener(bin, 101, 32, "ping", "tcp-ok", why);
    let port = yt.num(why[0], 0);
    if (port == 0) {
        yt.fail(label + " accept-loop fd limit", why[0]);
        return;
    };
    let detail = "";
    let i = 2;
    while (i <= 100 && detail == "") {
        let got = request(port, "ping", true);
        if (got == none) { detail = "connection " + tostring(i) + " did not receive a complete response"; }
        else if (got! != "tcp-ok") { detail = "connection " + tostring(i) + " returned an unexpected response"; };
        i += 1;
    };
    if (detail == "" && request(port, "", false) != none) {
        yt.check(label + " listen_tcp serves 100 connections under ulimit -n 32", yt.wait(p).code == 0,
            "server did not exit successfully");
    } else {
        yt.fail(label + " accept-loop fd limit", if (detail == "") { "could not open final shutdown connection" } else { detail });
        stop(p);
    };
};

// A server that prints "ready" once it listens: it, with its port in `port[0]`.
def ready_server(bin: str, port: [long]) -> yt.Proc {
    for attempt in 0..20 {
        let pt = random_port();
        let p = server([bin, tostring(pt), "0"], 0);
        let polls = 0;
        while (polls < 50 && yt.alive(p) && !yt.read(p.outp).contains("ready")) {
            yt.sleep_us(100000);
            polls += 1;
        };
        if (yt.read(p.outp).contains("ready")) {
            port[0] = pt;
            return p;
        };
        stop(p);
    };
    port[0] = 0;
    server(["true"], 0)
};

def client(bin: str, args: [str]) -> str { yc.run_bin(bin, args, "", 30).out };

// The resolver (net.resolve_with) against the fake server, UDP and TCP on one
// port: a CNAME and two A records, a truncated answer retried over TCP,
// NXDOMAIN, a malformed answer, an unaskable name; then names that need none.
def dns() {
    let want = "[10.1.2.3, 10.4.5.6]\n[10.7.8.9]\n[]\n[]\n[]\n[10.0.0.1] [127.0.0.1]\n";
    if (!(pair("dns_srv") && pair("dns_cli"))) { return; };
    foreach (side in [["copy", "C copy"], ["ref", "reference"]]) {
        let port = [0];
        let p = ready_server(W + "/dns_srv." + side[0], port);
        if (port[0] == 0) {
            yt.fail(side[1] + " DNS server", "no DNS server became ready after 20 port attempts");
        } else {
            foreach (c in ["dns_cli.copy", "dns_cli.ref"]) {
                let got = client(W + "/" + c, [tostring(port[0])]);
                yt.check(side[1] + " DNS server: " + c + " resolves", got == want, "got: " + got);
            };
        };
        stop(p);
    };
};

// The http client (std/http.y) against http_srv.y: one-shot requests and a
// session (cookies, a default header, one kept connection, Connection: close).
def http_client() {
    let want = "200 OK 11 hello world\n200 chunked b'ab' abcdefgh 8\ntwice hello world b'hello world' 4 4\n"
        + "200 true hello world\n200 POST posted body\nsame-origin 200 true\ncross-origin 200 -1 34\n"
        + "custom value\n200 11 []\n404 no /nothing\ncookies: anon\ncookies: sid=abc123; theme=dark\n"
        + "header: from session\nsame connection: true\nput: PUT put body\nbye then a new one: true\nquit: quit\n";
    if (!(pair("http_srv") && pair("http_cli"))) { return; };
    foreach (c in ["http_cli.copy", "http_cli.ref"]) {
        let port = [0];
        let p = ready_server(W + "/http_srv.copy", port);
        if (port[0] == 0) {
            yt.fail("http client", "the test server did not start");
        } else {
            let got = client(W + "/" + c, [tostring(port[0])]);
            yt.check("http client: " + c, got == want, "got: " + got);
        };
        stop(p);
    };
};

def openssl_server(args: [str], cwd: str) -> yt.Proc {
    let c = yt.cmd(["openssl", "s_server"] + args);
    c.cwd = cwd;
    c.timeout = 20;
    yt.start(c)
};

// The TLS 1.3 client against `openssl s_server -www`: each suite, an RSA and
// an ECDSA P-384 certificate trusted as the anchor, ALPN, and a host the
// certificate does not name.
def tls_case(suite: str, cert: str, key: str, host: str, want: str, extra: [str]) {
    let port = 0;
    let p = server(["true"], 0);
    for attempt in 0..20 {
        if (port == 0) {
            let pt = random_port();
            p = openssl_server(["-accept", tostring(pt), "-cert", cert, "-key", key, "-tls1_3", "-ciphersuites", suite]
                + extra + ["-www", "-quiet"], "");
            let polls = 0;
            while (polls < 50 && yt.alive(p) && request(pt, "", false) == none) {
                yt.sleep_us(100000);
                polls += 1;
            };
            if (yt.alive(p)) { port = pt; } else { stop(p); };
        };
    };
    if (port == 0) {
        yt.fail("TLS " + suite, "openssl s_server did not start");
        return;
    };
    foreach (c in ["tls_cli.copy", "tls_cli.ref"]) {
        let got = client(W + "/" + c, [tostring(port), cert, host]);
        yt.check("TLS " + suite + " " + fs.path_basename(cert) + " " + host + ": " + c, got == want + "\n", "got: " + got);
    };
    stop(p);
};

def req_cert(key: str, cert: str, newkey: [str], subj: str, san: str) {
    yt.exe2(["openssl", "req", "-x509"] + newkey + ["-keyout", key, "-out", cert, "-days", "2", "-nodes",
        "-subj", subj, "-addext", "subjectAltName=" + san]);
};

def tls() {
    if (!yt.have("openssl")) {
        yt.skip("TLS client", "openssl is not installed");
        return;
    };
    if (!pair("tls_cli")) { return; };
    req_cert(W + "/rsa_key.pem", W + "/rsa.pem", ["-newkey", "rsa:2048"], "/CN=localhost", "DNS:localhost");
    req_cert(W + "/ec_key.pem", W + "/ec.pem", ["-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-384"], "/CN=localhost",
        "DNS:localhost");
    let ok = " HTTP/1.0 200 ok true err []";
    tls_case("TLS_AES_128_GCM_SHA256", W + "/rsa.pem", W + "/rsa_key.pem", "localhost",
        "suite 4865 alpn [http/1.1] matched true" + ok, ["-alpn", "http/1.1"]);
    tls_case("TLS_AES_256_GCM_SHA384", W + "/rsa.pem", W + "/rsa_key.pem", "localhost", "suite 4866 alpn [] matched false" + ok, []);
    tls_case("TLS_CHACHA20_POLY1305_SHA256", W + "/ec.pem", W + "/ec_key.pem", "localhost",
        "suite 4867 alpn [] matched false" + ok, []);
    tls_case("TLS_AES_256_GCM_SHA384", W + "/ec.pem", W + "/ec_key.pem", "127.0.0.1",
        "ERROR certificate is not valid for 127.0.0.1", []);
    // a certificate naming the address in an iPAddress SAN: it was once refused
    // (names_host read only c.dns) while openssl s_client -CAfile verifies it
    req_cert(W + "/ip_key.pem", W + "/ip.pem", ["-newkey", "rsa:2048"], "/CN=127.0.0.1", "IP:127.0.0.1");
    tls_case("TLS_AES_128_GCM_SHA256", W + "/ip.pem", W + "/ip_key.pem", "127.0.0.1", "suite 4865 alpn [] matched false" + ok, []);
    // https: the http client against `openssl s_server -WWW` (built here
    // again, unreported: its parity is the http client case's)
    let src = yc.ROOT + "/test/y/net/http_cli.y";
    if (yc.compile(yc.CYCC, [], src, W + "/http_cli.copy", 60).code == 0
        && yc.compile(yc.YREF, [], src, W + "/http_cli.ref", 60).code == 0) {
        yt.write(W + "/hello.txt", "hello over tls\n");
        let pt = random_port();
        let p = openssl_server(["-accept", tostring(pt), "-cert", W + "/ec.pem", "-key", W + "/ec_key.pem", "-WWW", "-quiet"], W);
        let polls = 0;
        while (polls < 50 && request(pt, "", false) == none) {
            yt.sleep_us(100000);
            polls += 1;
        };
        foreach (c in ["http_cli.copy", "http_cli.ref"]) {
            let got = client(W + "/" + c, [tostring(pt), W + "/ec.pem"]);
            yt.check("https client: " + c, got == "200 hello over tls []\n0 [certificate is not valid for 127.0.0.1]\n", "got: " + got);
        };
        stop(p);
    };
};

def listeners() {
    if (pair("srv_http")) {
        http_listener(W + "/srv_http.copy", "C copy");
        http_listener(W + "/srv_http.ref", "reference");
    };
    if (pair("srv_tcp")) {
        tcp_listener(W + "/srv_tcp.copy", "C copy");
        tcp_listener(W + "/srv_tcp.ref", "reference");
        tcp_leak(W + "/srv_tcp.copy", "C copy");
        tcp_leak(W + "/srv_tcp.ref", "reference");
    };
};

def in_work(body: () -> void) -> () -> void {
    () => {
        W = yt.tmp_dir("net");
        SEED = yt.getpid() * 2654435761;
        body();
        fs.remove_all(W);
    }
};

def cases() -> [yt.Case] {
    [yt.case_of("net", "listeners", in_work(listeners)), yt.case_of("net", "dns", in_work(dns)),
     yt.case_of("net", "http client", in_work(http_client)), yt.case_of("net", "tls", in_work(tls))]
};

export { cases };
