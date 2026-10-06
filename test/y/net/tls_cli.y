// The TLS 1.3 client (std/tls.y) for test_net.sh: to localhost-or-not
// argv[3] on port argv[1], trusting the PEM certificate in file argv[2],
// asking for ALPN http/1.1; it GETs / from an `openssl s_server -www`
// and says which suite it got and what came back.
import tls;
import fs;
let port = tolong(argv()[1])!;
let pem = fs.read_file(argv()[2])!;
let host = argv()[3];
let c = tls.connect_with(host, port, { anchors: pem, alpn: "http/1.1", timeout: 10 });
if (c.err != "") {
    print("ERROR ", c.err);
} else {
    tls.send(c, bytes("GET / HTTP/1.0\r\n\r\n"));
    let total = 0;
    let first = "";
    let chunk = tls.recv(c);
    while (chunk != none) {
        if (first == "") { first = from_bytes(chunk!).split("\r\n")[0]; };
        total = total + len(chunk!);
        chunk = tls.recv(c);
    };
    tls.close(c);
    print("suite ", c.suite, " alpn [", c.alpn, "] ", first, " ", total > 100, " err [", c.err, "]");
};
