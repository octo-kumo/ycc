// Winsock behind the Linux-shaped calls: a receive that times out (SO_RCVTIMEO,
// a timeval on Linux and milliseconds on Windows), poll (WSAPoll behind
// ipc.wait_readable), end of stream, and a name from the hosts file. The same
// program, the same output, on both targets (unicode.expected, argv.expected and
// the others are checked the same way).
import net;
import ipc;

let srv = net.socket_tcp();
net.bind_tcp(srv, 0);
net.listen_fd(srv, 4);
let port = net.local_port(srv);
let client = net.connect_tcp("127.0.0.1", port);
let conn = net.accept_tcp(srv);
print(client >= 0 && conn >= 0);

// nothing has been sent: the receive gives up after the timeout, not never
net.set_timeouts(client, 1);
let t0 = clock_us();
let nothing = net.recv_str(client, 16);
let dt = clock_us() - t0;
print(nothing == none, " ", dt < 4000000, " ", dt >= 500000);

// poll: not readable, then readable, then drained
print(ipc.wait_readable(client, 100));
net.send_str(conn, "x");
print(ipc.wait_readable(client, 1000));
print(net.recv_str(client, 16)!);
print(ipc.wait_readable(client, 100));

// the peer closes: readable, and the read answers end of stream
net.close_fd(conn);
print(ipc.wait_readable(client, 1000));
print(is_some(net.recv_str(client, 16)));
net.close_fd(client);
net.close_fd(srv);

// a name from the hosts file
let r = net.resolve("localhost");
print(len(r) > 0 && r[0] == "127.0.0.1");
