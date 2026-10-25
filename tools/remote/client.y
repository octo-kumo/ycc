// tools/remote/client.y -- sends an authenticated argv/stdin to the executor.
import net;
import fs;
import crypto;
import proto from "../keyserver/proto.y";
import store from "../keyserver/store.y";

let MAX_IN = 61440;

def main() -> long {
    let a = argv();
    if (len(a) < 4) { eputs("usage: client HOST PORT TOKENFILE [args...]\n"); return 1; };
    let host = a[1];
    let port = tolong(a[2]);
    if (port == none) { eputs("bad port\n"); return 1; };
    let tk = store.load_tokens(a[3]);
    if (!tk.ok) { eputs("remote: " + tk.err + "\n"); return 1; };
    let token = tk.tokens[0];
    let input = fs.read_all_bytes(0);
    if (len(input) > MAX_IN) { eputs("remote: stdin too large\n"); return 1; };
    let args: [str] = [];
    let i = 4;
    while (i < len(a)) { args += a[i]; i += 1; };
    let body: [byte] = [];
    body += proto.be32(len(args));
    foreach (x in args) { body = proto.put_str(body, x); };
    body += input;
    let nonce = crypto.random_bytes(16);
    let mac = crypto.hmac(crypto.hash_sha256(), token, body);
    let req: [byte] = [];
    req += nonce;
    req += mac;
    req += body;
    let fd = net.connect_tcp(host, port!);
    if (fd < 0) { eputs("connect failed\n"); return 1; };
    net.set_timeouts(fd, 30);
    if (!proto.send_msg(fd, req)) { eputs("send failed\n"); return 1; };
    let resp = proto.recv_msg(fd);
    if (resp == none || len(resp!) < 8) { eputs("bad reply\n"); return 1; };
    let r = resp!;
    let code = proto.u32(r, 0);
    let flags = proto.u32(r, 4);
    let out = from_bytes(r[8:]);
    if (len(out) > 0) { print(out); };
    if ((flags & 1) != 0) { eputs("remote: output truncated\n"); };
    return code;
};

let r = main();
exit(r);
