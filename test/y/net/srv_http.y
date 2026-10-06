import net;

let args = argv();
let port = tolong(args[1])!;
let limit = 2;
if (len(args) > 2) { limit = tolong(args[2])!; 0 } else { 0; };
let requests = 0;

def handler(req: str) -> str {
    requests = requests + 1;
    if (requests >= limit) { exit(0); 0 } else { 0; };
    net.http_response(200, "http-ok")
};

net.listen_http(port, handler);
