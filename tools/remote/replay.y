// tools/remote/replay.y -- a red-team probe for the remote executor's nonce
// store. `save` sends one request and writes its exact bytes; `send` resends
// them, so a server restarted with the same NONCEFILE must refuse it.
import net;
import fs;
import crypto;
import proto from "../keyserver/proto.y";
import store from "../keyserver/store.y";

def send(fd: long, r: [byte]) -> [byte]? {
    if (!proto.send_msg(fd, r)) { return none; };
    proto.recv_msg(fd)
};

def main() -> long {
    let a = argv();
    if (len(a) < 4) {
        eputs("usage: replay save HOST PORT TOKENFILE FILE   (or: replay send HOST PORT FILE)\n");
        return 1;
    };
    let port = tolong(a[3]);
    if (port == none) { eputs("bad port\n"); return 1; };
    if (a[1] == "save") {
        if (len(a) < 6) { eputs("usage: replay save HOST PORT TOKENFILE FILE\n"); return 1; };
        let tk = store.load_tokens(a[4]);
        if (!tk.ok) { eputs(tk.err + "\n"); return 1; };
        let body: [byte] = [];
        body += proto.be32(1);
        body = proto.put_str(body, "replay-probe");
        let nonce = crypto.random_bytes(16);
        let mac = crypto.hmac(crypto.hash_sha256(), tk.tokens[0], body);
        let req: [byte] = [];
        req += nonce;
        req += mac;
        req += body;
        let fd = net.connect_tcp(a[2], port!);
        if (fd < 0) { eputs("connect failed\n"); return 1; };
        net.set_timeouts(fd, 30);
        let r = send(fd, req);
        if (r == none) { eputs("send failed\n"); return 1; };
        if (!fs.write_bytes(a[5], req)) { eputs("cannot save the request\n"); return 1; };
        print("saved\n");
        0
    } else if (a[1] == "send") {
        if (len(a) < 5) { eputs("usage: replay send HOST PORT FILE\n"); return 1; };
        let b = fs.read_bytes(a[4]);
        if (b == none) { eputs("cannot read the request\n"); return 1; };
        let fd = net.connect_tcp(a[2], port!);
        if (fd < 0) { eputs("connect failed\n"); return 1; };
        net.set_timeouts(fd, 30);
        let r = send(fd, b!);
        if (r == none) { eputs("no reply\n"); return 1; };
        let resp = r!;
        print(from_bytes(resp[8:]));
        0
    } else {
        eputs("replay: mode must be save or send\n");
        1
    }
};

let r = main();
exit(r);
