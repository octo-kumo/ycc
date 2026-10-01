import net;

def handler(req: str) -> str {
    if (index_of(req, "/gone") >= 0) {
        net.http_response(404, "gone")
    } else {
        net.http_response(200, "served")
    }
};

let r200 = net.http_response(200, "ok");
let r404 = net.http_response(404, "gone");
let r500 = net.http_response(500, "oops");
let r418 = net.http_response(418, "teapot");
print(r200 == "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok");
print(r404 == "HTTP/1.1 404 Not Found\r\nContent-Length: 4\r\nConnection: close\r\n\r\ngone");
print(r500 == "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 4\r\nConnection: close\r\n\r\noops");
print(r418 == "HTTP/1.1 418 Status\r\nContent-Length: 6\r\nConnection: close\r\n\r\nteapot");

let listener = net.socket_tcp();
net.bind_tcp(listener, 0);
let port = net.local_port(listener);
net.listen_fd(listener, 1);
let client = net.connect_tcp("127.0.0.1", port);
let server = net.accept_tcp(listener);
print(net.send_str(client, "GET /gone HTTP/1.1\r\nHost: local\r\n\r\n"));
print(net.http_serve_one(server, handler));
let response = net.recv_str(client, 1024);
print(is_some(response));
print(unwrap(response) == r404);
print(net.close_fd(client));
print(net.close_fd(listener));
