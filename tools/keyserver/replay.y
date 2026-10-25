// tools/keyserver/replay.y -- a red-team probe: send a hello with a nonce the
// server has already accepted and print its reply. Used to check that the
// nonce store survives a server restart.
import net;
import crypto;
import proto;

def main() -> long {
    let a = argv();
    if (len(a) < 7) {
        eputs("usage: replay HOST PORT RELEASE USER HASHHEX NONCEHEX\n");
        return 1;
    };
    let port = tolong(a[2])!;
    let nonce = crypto.unhex(a[6]);
    let hash = crypto.unhex(a[5]);
    let fd = net.connect_tcp(a[1], port);
    if (fd < 0) { return 2; };
    net.set_timeouts(fd, 20);
    let hello: [byte] = [];
    hello = proto.put_str(hello, a[3]);
    hello = proto.put_str(hello, a[4]);
    hello = proto.put_bytes(hello, crypto.random_bytes(32));
    hello = proto.put_bytes(hello, nonce);
    hello = proto.put_bytes(hello, hash);
    hello = proto.put_blob(hello, []);
    hello = proto.put_blob(hello, []);
    hello = proto.put_blob(hello, []);
    if (!proto.send_msg(fd, hello)) { return 3; };
    let r = proto.recv_msg(fd);
    if (r == none) { print("NO REPLY\n"); return 4; };
    print(from_bytes(r!) + "\n");
    0
};
let r = main();
exit(r);
