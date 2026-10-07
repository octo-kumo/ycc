// End-to-end over a real socket: fork a client, serve one HTTP request in
// the parent. Output order is deterministic — the child prints after
// receiving the response, the parent after wait4 reaps the child.
import net;

def hello(req: str) -> str {
    net.http_response(200, "hello")
};

// is_quad: the address form addr_set takes, and what resolve reads
print(net.is_quad("127.0.0.1"));
print(net.is_quad("0.0.0.0"));
print(net.is_quad("255.255.255.255"));
print(net.is_quad("1.2.3"));         // too few parts
print(net.is_quad("1.2.3.4.5"));     // too many
print(net.is_quad("1.2.3.256"));     // out of range
print(net.is_quad("1.2.3.4a"));      // not decimal
print(net.is_quad("1.2..4"));        // an empty part
print(net.is_quad("1.2.3.4000"));    // a four-digit part
print(net.is_quad("::1"));           // not a dotted quad
print(net.is_quad(""));
print(net.is_quad("localhost"));

let srv = net.socket_tcp();
print(srv >= 0);
net.bind_tcp(srv, 0);
net.listen_fd(srv, 1);
let port = net.local_port(srv);
print(port > 0);

let pid = syscall(57);
if (pid == 0) {
    // client: send a request, print the status line of the response
    let c = net.connect_tcp("127.0.0.1", port);
    net.send_str(c, "GET / HTTP/1.1\r\nHost: t\r\n\r\n");
    let r = net.recv_str(c, 256);
    net.close_fd(c);
    if (is_some(r)) {
        print("client got: " + unwrap(r)[:15]);
    } else {
        print("client got: nothing");
    };
    exit(0);
} else {
    let conn = net.accept_tcp(srv);
    net.http_serve_one(conn, hello);
    syscall(61, pid, 0, 0, 0);
    net.close_fd(srv);
    print("server done");
    exit(0);
};
