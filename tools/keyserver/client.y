// The launcher: hash the sealed binary, verify the pinned server key, run an
// X25519 handshake, optionally quote this client with TPM 2.0, fetch the key,
// put it on fd 9 through an anonymous pipe, exec.
// Compile the sealed binary with --obfuscate-key-fd=9.
import net;
import fs;
import crypto;
import proto;
import store;

def die(s: str) -> long { eputs("unseal: " + s + "\n"); 1 };

def main() -> long {
    let a = argv();
    if (len(a) < 9) {
        return die("usage: client HOST PORT RELEASE USER LICENSE SECRETFILE PINFILE BINARY [AKCTX TCTI]");
    };
    let host = a[1];
    let port = tolong(a[2]);
    if (port == none) { return die("bad port"); };
    let release = a[3];
    let user = a[4];
    let license = a[5];
    let sb = store.key_material(a[6], 16);
    let pk = store.load_rsa_pub(a[7]);
    let bb = fs.read_bytes(a[8]);
    if (sb == none) { return die("secret file needs 16 bytes"); };
    if (!pk.ok) { return die(pk.err); };
    if (bb == none) { return die("cannot read binary"); };
    let secret = sb!;
    let pin_n = pk.n;
    let pin_e = pk.e;
    let hash = crypto.sha256(bb!);
    let tpm = len(a) >= 11;
    let akctx = if (tpm) { a[9] } else { "" };
    let tcti = if (tpm) { a[10] } else { "" };
    let priv = crypto.random_bytes(32);
    let cpub = crypto.x25519_base(priv);
    let cnonce = crypto.random_bytes(32);
    let qmsg: [byte] = [];
    let qsig: [byte] = [];
    let qpcr: [byte] = [];
    if (tpm) {
        let tag = tostring(syscall(39)) + "-" + tostring(clock_us());
        let mp = "/tmp/yclientq-" + tag + ".msg";
        let sp = "/tmp/yclientq-" + tag + ".sig";
        let pp = "/tmp/yclientq-" + tag + ".pcr";
        let qc = "TPM2TOOLS_TCTI=" + tcti
            + " tpm2_flushcontext -t >/dev/null 2>&1; TPM2TOOLS_TCTI=" + tcti
            + " tpm2_quote -c " + akctx
            + " -l sha256:0,1,2 -q " + crypto.hex(cnonce)
            + " -m " + mp + " -s " + sp + " -o " + pp + " -g sha256 >/dev/null";
        if (exec(qc) != 0) { return die("tpm quote failed"); };
        let m = fs.read_bytes(mp);
        let sg = fs.read_bytes(sp);
        let pc = fs.read_bytes(pp);
        if (m != none) { qmsg = m!; };
        if (sg != none) { qsig = sg!; };
        if (pc != none) { qpcr = pc!; };
        fs.remove_file(mp); fs.remove_file(sp); fs.remove_file(pp);
    };
    let fd = net.connect_tcp(host, port!);
    if (fd < 0) { return die("connect failed"); };
    net.set_timeouts(fd, 30);
    let hello: [byte] = [];
    hello = proto.put_str(hello, release);
    hello = proto.put_str(hello, user);
    hello = proto.put_bytes(hello, cpub);
    hello = proto.put_bytes(hello, cnonce);
    hello = proto.put_bytes(hello, hash);
    hello = proto.put_blob(hello, qmsg);
    hello = proto.put_blob(hello, qsig);
    hello = proto.put_blob(hello, qpcr);
    if (!proto.send_msg(fd, hello)) { return die("send hello failed"); };
    let chb = proto.recv_msg(fd);
    if (chb == none || len(chb!) < 64 + len(pin_n)) { return die("bad challenge"); };
    let ch = chb!;
    if (crypto.bytes_eq(ch[0:4], bytes("ERR "))) { return die("server refused"); };
    let spub = ch[0:32];
    let snonce = ch[32:64];
    let sig = ch[64:64 + len(pin_n)];
    let th = proto.transcript(user, release, cpub, spub, cnonce, snonce, hash);
    let want_s = crypto.rsa_verify_pkcs1(pin_n, pin_e, crypto.sha256(th), sig);
    if (!want_s) {
        store.wipe(secret);
        return die("server authentication failed (pinned key mismatch)");
    };
    let shared = crypto.x25519(priv, spub);
    let k_c2s = proto.direction_key(shared, th, "yseal-c2s");
    let k_s2c = proto.direction_key(shared, th, "yseal-s2c");
    let mac = crypto.hmac(crypto.hash_sha256(), secret,
        proto.auth_context(th, user, license));
    let auth: [byte] = [];
    auth = proto.put_str(auth, license);
    auth = proto.put_bytes(auth, mac);
    let anonce = crypto.random_bytes(12);
    let asealed = crypto.chacha_seal(k_c2s, anonce,
        proto.aad(th, "client-auth"), auth);
    let wire: [byte] = [];
    wire += anonce;
    wire += asealed;
    if (!proto.send_msg(fd, wire)) {
        store.wipe(shared); store.wipe(k_c2s); store.wipe(k_s2c);
        store.wipe(secret);
        return die("send auth failed");
    };
    let kb = proto.recv_msg(fd);
    if (kb != none && len(kb!) >= 4 && crypto.bytes_eq(kb![0:4], bytes("ERR "))) {
        store.wipe(shared); store.wipe(k_c2s); store.wipe(k_s2c);
        store.wipe(secret);
        return die("server refused the licence");
    };
    if (kb == none || len(kb!) < 12 + 16) {
        store.wipe(shared); store.wipe(k_c2s); store.wipe(k_s2c);
        store.wipe(secret);
        return die("bad key reply");
    };
    let k = kb!;
    let nonce = k[0:12];
    let sealed = k[12:];
    let key = crypto.chacha_open(k_s2c, nonce,
        proto.aad(th, "server-key"), sealed);
    store.wipe(shared);
    store.wipe(k_c2s);
    store.wipe(k_s2c);
    store.wipe(secret);
    if (key == none || len(key!) != 16) { return die("key authentication failed"); };
    let fds: [long; 1] = [0; 1];
    if (os_call("y_os_pipe", ptr_addr(&fds[0])) < 0) { return die("pipe failed"); };
    let rfd = fds[0] & 4294967295;
    let wfd = fds[0] >> 32;
    let kb2 = key!;
    if (os_call("y_os_write", wfd, ptr_addr(&kb2[0]), 16) != 16) { return die("write key failed"); };
    os_call("y_os_close", wfd);
    store.wipe(kb2);
    if (os_call("y_os_dup2", rfd, 9) < 0) { return die("dup2 failed"); };
    os_call("y_os_close", rfd);
    exec(a[8])
};

let r = main();
exit(r);
