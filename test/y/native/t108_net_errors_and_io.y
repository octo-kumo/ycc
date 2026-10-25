import net;

print(is_some(net.recv_str(-1, 8)));
print(net.send_str(-1, "x"));
print(net.close_fd(-1));

let not_listening = net.socket_tcp();
print(not_listening >= 0);
print(net.accept_tcp(not_listening));
print(net.close_fd(not_listening));

let busy = net.socket_tcp();
print(net.bind_tcp(busy, 0));
let port = net.local_port(busy);
print(port > 0);
print(net.listen_fd(busy, 1));
let duplicate = net.socket_tcp();
print(net.bind_tcp(duplicate, port));
print(net.close_fd(duplicate));
print(net.close_fd(busy));

let addr: [byte; 16] = [0; 16];
print(net.addr_set(addr, "localhost", 8080));
print([
    addr[0], addr[1], addr[2], addr[3],
    addr[4], addr[5], addr[6], addr[7]
]);

// A port that refuses: bound but never listening. Holding it keeps anyone
// else off it, so the refusal does not depend on what the machine runs.
let refuser = net.socket_tcp();
net.bind_tcp(refuser, 0);
let refused_port = net.local_port(refuser);
print(net.connect_tcp("127.0.0.1", refused_port));
let baseline = net.socket_tcp();
net.close_fd(baseline);
let all_refused = true;
let attempts = 0;
while (attempts < 2000) {
    let failed = net.connect_tcp("127.0.0.1", refused_port);
    if (failed != -111) {
        all_refused = false;
        if (failed >= 0) { net.close_fd(failed); } else { 0; };
    } else { 0; };
    attempts = attempts + 1;
};
let after = net.socket_tcp();
print(after == baseline);
print(all_refused);
print(attempts);
print(net.close_fd(after));
net.close_fd(refuser);

let listener = net.socket_tcp();
net.bind_tcp(listener, 0);
let local = net.local_port(listener);
net.listen_fd(listener, 1);
let client = net.connect_tcp("127.0.0.1", local);
let server = net.accept_tcp(listener);
print(client >= 0 && server >= 0);
print(net.send_str(client, "from client"));
let from_client = net.recv_str(server, 64);
print(is_some(from_client) && unwrap(from_client) == "from client");
print(net.send_str(server, "from server"));
let from_server = net.recv_str(client, 64);
print(is_some(from_server) && unwrap(from_server) == "from server");

let bytes: [byte] = [];
let i = 0;
while (i < 5000) {
    bytes += 120;
    i = i + 1;
};
let payload = from_bytes(bytes);
print(net.send_str(server, payload));
let capped = net.recv_str(client, 5000);
print(is_some(capped));
print(len(unwrap(capped)));
print(unwrap(capped)[:4] == "xxxx");
print(is_some(net.recv_str(client, 0)));
print(is_some(net.recv_str(client, -2)));
print(net.close_fd(client));
print(net.close_fd(server));
print(net.close_fd(listener));
