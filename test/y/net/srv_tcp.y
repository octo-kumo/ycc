import net;

let args = argv();
let port = tolong(args[1])!;
let limit = 2;
if (len(args) > 2) { limit = tolong(args[2])!; 0 } else { 0; };
let requests = 0;

def handler(fd: long) -> long {
    requests = requests + 1;
    if (requests >= limit) { exit(0); 0 } else { 0; };
    let request = net.recv_str(fd, 64);
    net.send_str(fd, "tcp-ok")
};

net.listen_tcp(port, handler);
