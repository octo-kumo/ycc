import net;

let listener = net.socket_tcp();
net.bind_tcp(listener, 0);
let port = net.local_port(listener);
net.listen_fd(listener, 1);

let client = net.connect_tcp("127.0.0.1", port);
let server = net.accept_tcp(listener);
let first = "GET /piece HTTP/1.1\r\nHost: loopback\r\n";
let second = "\r\nBODY";
print(net.send_str(client, first));
print(net.send_str(client, second));

let request = net.http_read_head(server);
print(request == "GET /piece HTTP/1.1\r\nHost: loopback\r\n\r\nBODY");
print(len(request));

print(net.close_fd(client));
print(net.close_fd(server));
print(net.close_fd(listener));
