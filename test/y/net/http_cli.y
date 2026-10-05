// The http client (std/http.y) against test/y/net/http_srv.y on port
// argv[1] (test_net.sh): one-shot requests, then a session (a base URL,
// a header for every request, cookies, one kept connection).
import http;

// With a certificate (argv[2]): GET https://localhost/hello.txt from an
// `openssl s_server -WWW` on that port instead, trusting the certificate.
import fs;
if (len(argv()) > 2) {
    let pem = fs.read_file(argv()[2])!;
    let t = http.get("https://localhost:" + argv()[1] + "/hello.txt", { anchors: pem, timeout: 10 });
    print(t.status, " ", t.text().trim(), " [", t.err, "]");
    let u = http.get("https://127.0.0.1:" + argv()[1] + "/hello.txt", { anchors: pem, timeout: 10 });
    print(u.status, " [", u.err, "]");
    exit(0);
};
let base = "http://127.0.0.1:" + argv()[1];
let r = http.get(base + "/hello");
print(r.status, " ", r.reason, " ", r.size, " ", r.text());
let c = http.get(base + "/chunked");
print(c.status, " ", c.headers["transfer-encoding"], " ", c.read(2), " ", c.text(), " ", c.text().length);
// the body is a value, not a stream: a read after the body has ended is
// answered from what came, so text() twice is the same text and read(4)
// twice is the same four bytes
let rr = http.get(base + "/hello");
print("twice ", rr.text(), " ", rr.read(0), " ", len(rr.read(4)), " ", len(rr.read(4)));
let d = http.get(base + "/redirect");
print(d.status, " ", d.url == base + "/hello", " ", d.text());
let e = http.post(base + "/echo", "posted body");
print(e.status, " ", e.text());
let h = http.get(base + "/header", { headers: {"X-Custom": "custom value"} });
print(h.text());
let hd = http.head(base + "/hello");
print(hd.status, " ", hd.size, " [", hd.text(), "]");
let nf = http.get(base + "/nothing");
print(nf.status, " ", nf.text());
let s = http.session({ base: base, headers: {"X-Custom": "from session"} });
let a = s.get("/conn");
let first = a.text();
print("cookies: ", s.get("/whoami").text());
s.get("/setcookie").read(0);
print("cookies: ", s.get("/whoami").text());
print("header: ", s.get("/header").text());
print("same connection: ", s.get("/conn").text() == first);
print("put: ", s.put("/echo", "put body").text());
let bye = s.get("/close");
print(bye.text(), " then a new one: ", s.get("/conn").text() != first);
s.close();
print("quit: ", http.get(base + "/quit").text());
