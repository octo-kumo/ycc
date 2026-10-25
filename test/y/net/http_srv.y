// An HTTP/1.1 server for src/tools/ytest/su_net.y's http client checks, on port
// argv[1]: one connection at a time, each kept open for request after
// request. Routes: /hello (Content-Length), /chunked, /redirect (302 to
// /hello), /sredirect (302 to /hdrs, same origin), /xredirect (302 to
// /hdrs on localhost -- the same server by another name, so the origin
// changes), /hdrs (every header this request carried, one name a line),
// /setcookie, /whoami (the Cookie header), /echo (the body back),
// /header (X-Custom back), /conn (which connection this is), /close
// (Connection: close), /quit (the server ends). It prints "ready" once
// it listens.
import net;

let port = tolong(argv()[1])!;
let conns = 0;
let quit = false;

def reply(fd: long, status: str, extra: str, body: str) -> long {
    net.send_str(fd, "HTTP/1.1 " + status + "\r\n" + extra + "Content-Length: " + tostring(len(body)) + "\r\n\r\n" + body)
};

// The value of header `name` in a request head ("" when absent).
def header_of(head: str, name: str) -> str {
    let out = "";
    foreach (line in head.split("\r\n")) {
        let colon = index_of(line, ":");
        if (colon > 0 && line[0:colon].lower() == name) { out = line[colon + 1:len(line)].trim(); };
    };
    out
};

// Serve one connection until the client closes it (or asks to).
def serve(fd: long) {
    conns = conns + 1;
    let buf = "";
    let go = true;
    while (go && !quit) {
        while (index_of(buf, "\r\n\r\n") < 0 && go) {
            let more = net.recv_str(fd, 4096);
            if (more == none) { go = false; } else { buf = buf + more!; };
        };
        if (go) {
            let end = index_of(buf, "\r\n\r\n");
            let head = buf[0:end];
            buf = buf[end + 4:len(buf)];
            // A request without a Content-Length (chunked, or a GET) has no
            // number here; tolong answers none now, and 0 is the read this had.
            let n = 0;
            let nv = tolong(header_of(head, "content-length"));
            if (nv != none) { n = nv!; };
            while (len(buf) < n && go) {
                let more = net.recv_str(fd, 4096);
                if (more == none) { go = false; } else { buf = buf + more!; };
            };
            let body = buf[0:n];
            buf = buf[n:len(buf)];
            let path = head.split(" ")[1];
            if (path == "/hello") { reply(fd, "200 OK", "", "hello world"); }
            else if (path == "/chunked") {
                net.send_str(fd, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n4;ext=1\r\ndefg\r\n1\r\nh\r\n0\r\nX-Trailer: t\r\n\r\n");
            }
            else if (path == "/redirect") { reply(fd, "302 Found", "Location: /hello\r\n", ""); }
            else if (path == "/sredirect") {
                reply(fd, "302 Found", "Location: /hdrs\r\n", "");
            }
            // A redirect that leaves the origin: the same server, reached by
            // another name. The client's credentials must not come with it.
            else if (path == "/xredirect") {
                reply(fd, "302 Found", "Location: http://localhost:" + tostring(port) + "/hdrs\r\n", "");
            }
            // Every header this request carried, one per line: what a
            // cross-origin redirect is allowed to deliver.
            else if (path == "/hdrs") {
                let seen = "";
                foreach (hl in head.lines()) {
                    let hp = hl.index_of(":");
                    if (hp > 0) { seen = seen + hl[0:hp].lower() + "\n"; };
                };
                reply(fd, "200 OK", "", seen);
            }
            else if (path == "/setcookie") { reply(fd, "200 OK", "Set-Cookie: sid=abc123; Path=/\r\nSet-Cookie: theme=dark\r\n", "ok"); }
            else if (path == "/whoami") {
                let c = header_of(head, "cookie");
                if (c == "") { c = "anon"; };
                reply(fd, "200 OK", "", c);
            }
            else if (path == "/echo") { reply(fd, "200 OK", "", head.split(" ")[0] + " " + body); }
            else if (path == "/header") { reply(fd, "200 OK", "", header_of(head, "x-custom")); }
            else if (path == "/conn") { reply(fd, "200 OK", "", tostring(conns)); }
            else if (path == "/close") {
                reply(fd, "200 OK", "Connection: close\r\n", "bye");
                go = false;
            }
            else if (path == "/quit") {
                reply(fd, "200 OK", "Connection: close\r\n", "quit");
                quit = true;
            }
            else { reply(fd, "404 Not Found", "", "no " + path); };
            if (header_of(head, "connection").lower() == "close") { go = false; };
        };
    };
    net.close_fd(fd);
};

let lfd = net.socket_tcp();
if (net.bind_tcp(lfd, port) != 0) { exit(2); };
net.listen_fd(lfd, 8);
puts("ready\n");
while (!quit) {
    let c = net.accept_tcp(lfd);
    if (c >= 0) { serve(c); };
};
