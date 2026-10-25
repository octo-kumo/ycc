// The TLS 1.3 client (std/tls.y) for src/tools/ytest/su_net.y: to localhost-or-not
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
    // alpn_matched is the RFC 7301 3.2 check: did the server choose the
    // protocol this client offered? The suite only sends -alpn http/1.1 in
    // one of its three cases, so all three answers have to be right.
    print("suite ", c.suite, " alpn [", c.alpn, "] matched ", c.alpn_matched, " ", first, " ", total > 100, " err [", c.err, "]");
};
