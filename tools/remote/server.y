// tools/remote/server.y -- phase-5 remote execution, hardened for a pilot.
// The server owns the program; the client sends a token-authenticated request
// with an argument vector and stdin. Each run gets CPU/address-space/file
// limits, a wall-clock timeout, a capped output and a replay-refusing nonce
// (optionally persisted across restarts).
import net;
import fs;
import crypto;
import proto from "../keyserver/proto.y";
import store from "../keyserver/store.y";

let MAX_IN = 61440;
let MAX_OUT = 61440;
let MAX_ARGS = 64;

def shell_quote(s: str) -> str {
    let out = "'";
    let i = 0;
    while (i < len(s)) {
        if (s[i] == 39) { out += "'\\''"; } else { out += s[i]; };
        i += 1;
    };
    out + "'"
};

def reply(fd: long, code: long, flags: long, out: [byte]) -> void {
    let r: [byte] = [];
    r += proto.be32(code);
    r += proto.be32(flags);
    r += out;
    proto.send_msg(fd, r);
};

def serve(fd: long, cmd: str, tokens: [[byte]], nonce_path: str,
        seen: [str]) -> long {
    net.set_timeouts(fd, 20);
    let req = proto.recv_msg(fd);
    if (req == none) { return 0; };
    let r = req!;
    if (len(r) < 16 + 32) { reply(fd, 127, 0, bytes("remote: short request\n")); return 0; };
    let nonce = r[0:16];
    let mac = r[16:48];
    let body = r[48:];
    let matched = false;
    foreach (t in tokens) {
        let m = crypto.hmac(crypto.hash_sha256(), t, body);
        if (crypto.bytes_eq(mac, m)) { matched = true; };
    };
    if (!matched) { reply(fd, 127, 0, bytes("remote: bad token\n")); return 0; };
    let nid = crypto.hex(nonce);
    if (store.nonce_has(seen, nid)) { reply(fd, 127, 0, bytes("remote: replayed request\n")); return 0; };
    let nargs = proto.u32(body, 0);
    if (nargs > 64) { reply(fd, 127, 0, bytes("remote: too many arguments\n")); return 0; };
    let at = 4;
    let argv: [str] = [];
    let alen = 0;
    let bad = false;
    let ai = 0;
    while (ai < nargs && !bad) {
        let a = proto.get_str(body, at);
        if (a.next > len(body)) { bad = true; } else {
            alen += len(a.s);
            if (alen > 2048) { bad = true; } else { argv += a.s; at = a.next; };
        };
        ai += 1;
    };
    if (bad) { reply(fd, 127, 0, bytes("remote: malformed arguments\n")); return 0; };
    let input = body[at:];
    if (len(input) > MAX_IN) { reply(fd, 127, 0, bytes("remote: stdin too large\n")); return 0; };
    if (nonce_path != "") {
        if (!store.nonce_add(nonce_path, seen, nid, 4096)) {
            reply(fd, 127, 0, bytes("remote: cannot persist the nonce\n")); return 0;
        };
    } else {
        seen += nid;
        if (len(seen) > 4096) { seen = seen[len(seen) - 2048:len(seen)]; };
    };
    let tag = tostring(syscall(39)) + "-" + tostring(clock_us());
    let ip = "/tmp/yremote-" + tag + ".in";
    let op = "/tmp/yremote-" + tag + ".out";
    if (!fs.write_bytes(ip, input)) { reply(fd, 127, 0, bytes("remote: server storage\n")); return 0; };
    let argstr = "";
    foreach (a in argv) { argstr += " " + shell_quote(a); };
    // 10 s CPU, 256 MiB of address space, 4 MiB files, 15 s wall clock. The
    // ulimit builtins are best-effort: a platform without them still gets the
    // timeout and the caps below.
    let line = "ulimit -t 10 2>/dev/null; ulimit -v 262144 2>/dev/null; ulimit -f 4096 2>/dev/null; "
        + "exec timeout 15 " + cmd + argstr + " < " + ip + " > " + op + " 2>&1";
    let code = exec(line);
    let raw = fs.read_bytes(op);
    fs.remove_file(ip);
    fs.remove_file(op);
    let out: [byte] = [];
    let flags = 0;
    if (raw != none) {
        out = raw!;
        if (len(out) > MAX_OUT) {
            out = out[0:MAX_OUT];
            flags = 1;
        };
    };
    reply(fd, code, flags, out);
    0
};

def main() -> long {
    let a = argv();
    if (len(a) < 4) { eputs("usage: server PORT COMMAND TOKENFILE [NONCEFILE]\n"); return 1; };
    let port = tolong(a[1]);
    if (port == none) { eputs("bad port\n"); return 1; };
    let tk = store.load_tokens(a[3]);
    if (!tk.ok) { eputs("remote: " + tk.err + "\n"); return 1; };
    let tokens = tk.tokens;
    let nonce_path = if (len(a) >= 5) { a[4] } else { "" };
    let seen: [str] = [];
    if (nonce_path != "") {
        let ns = store.load_nonces(nonce_path, 4096);
        if (ns.err != "") { eputs("remote: " + ns.err + "\n"); return 1; };
        seen = ns.seen;
    };
    eputs("remote: listening on " + tostring(port!) + " with "
        + tostring(len(tokens)) + " token(s)\n");
    net.listen_tcp(port!, def (fd: long) -> long {
        serve(fd, a[2], tokens, nonce_path, seen)
    })
};

let r = main();
exit(r);
