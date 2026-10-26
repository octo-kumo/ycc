// A release service: TCP + X25519 + ChaCha20-Poly1305, a pinned server key,
// per-user licence HMACs, a persistent client-nonce store and per-connection
// timeouts. Offline tpm2_checkquote verifies an optional TPM 2.0 quote; the
// PCR values must match the server's expected file. It is not TLS; see
// AGENTS.md (--ob) for the threat model.
import net;
import fs;
import crypto;
import proto;
import store;

def die(s: str) -> long { eputs("keyserver: " + s + "\n"); 1 };

// The failure path sleeps without a dependency on the terminal unit; it is a
// rate limit, so a few burned microseconds are fine.
def nap_ms(ms: long) -> void {
    let until = clock_us() + ms * 1000;
    while (clock_us() < until) { };
};

// A failed handshake costs a little, and a burst of them locks the listener
// for a minute. There is no peer address in the net API, so this is a global
// rate limit rather than a per-source one; the stream is still sequential.
let fails = 0;
let fail_since = 0;
let blocked_until = 0;

def note_failure() -> void {
    let t = clock_us();
    if (t - fail_since > 60000000) { fails = 0; fail_since = t; };
    fails += 1;
    if (fails >= 12) { blocked_until = t + 60000000; };
    let nap = fails * 150;
    if (nap > 2000) { nap = 2000; };
    nap_ms(nap);
};

def refuse(fd: long, why: str) -> long {
    eputs("keyserver: refused: " + why + "\n");
    let e: [byte] = bytes("ERR refused");
    proto.send_msg(fd, e);
    note_failure();
    0
};

def main() -> long {
    let a = argv();
    if (len(a) < 8) {
        return die("usage: server PORT KEYFILE SERVERKEYFILE USERSFILE NONCEFILE RELEASE HASHHEX [AKPUB PCRFILE]");
    };
    let port = tolong(a[1]);
    if (port == none) { return die("bad port"); };
    let kb = store.key_material(a[2], 16);
    if (kb == none) { return die("key file needs 16 bytes"); };
    let key = kb!;
    let sk = store.load_rsa_priv(a[3]);
    if (!sk.ok) { return die(sk.err); };
    let sign_n = sk.n;
    let sign_d = sk.d;
    let uf = store.load_users(a[4]);
    if (!uf.ok) { return die(uf.err); };
    let users = uf.users;
    let nonce_path = a[5];
    let ns = store.load_nonces(nonce_path, 4096);
    if (ns.err != "") { return die(ns.err); };
    let seen = ns.seen;
    let release = a[6];
    let allowed = crypto.unhex(a[7]);
    if (len(allowed) != 32) { return die("hash must be 32 hex bytes"); };
    let tpm = len(a) >= 10;
    let akpub = if (tpm) { a[8] } else { "" };
    let pcrfile = if (tpm) { a[9] } else { "" };
    let expected_pcr: [byte] = [];
    if (tpm) {
        let pb = fs.read_bytes(pcrfile);
        if (pb == none) { return die("cannot read expected PCR file"); };
        expected_pcr = pb!;
    };
    let serve = def (fd: long) -> long {
        net.set_timeouts(fd, 30);
        if (clock_us() < blocked_until) {
            let e: [byte] = bytes("ERR busy");
            proto.send_msg(fd, e);
            nap_ms(200);
            return 0;
        };
        let hello = proto.recv_msg(fd);
        if (hello == none) { return refuse(fd, "short hello"); };
        let h = hello!;
        let rr = proto.get_str(h, 0);
        if (rr.next > len(h)) { return refuse(fd, "malformed release"); };
        let rel = rr.s;
        let ru = proto.get_str(h, rr.next);
        if (ru.next > len(h)) { return refuse(fd, "malformed user"); };
        let user = ru.s;
        let at = ru.next;
        if (len(h) < at + 96) { return refuse(fd, "short hello body"); };
        let cpub = h[at:at + 32]; at += 32;
        let cnonce = h[at:at + 32]; at += 32;
        let hash = h[at:at + 32]; at += 32;
        let qm = proto.get_bytes(h, at);
        let qs = proto.get_bytes(h, qm.next);
        let qp = proto.get_bytes(h, qs.next);
        if (qp.next > len(h)) { return refuse(fd, "malformed attestation fields"); };
        let rec = store.find_user(users, user);
        if (rec == none || rel != release || !crypto.bytes_eq(hash, allowed)) {
            return refuse(fd, "unknown user, release or binary hash");
        };
        let u = rec!;
        let cid = crypto.hex(cnonce);
        if (store.nonce_has(seen, cid)) { return refuse(fd, "replayed client nonce"); };
        if (tpm) {
            if (len(qm.b) == 0 || len(qs.b) == 0 || len(qp.b) == 0
                || !crypto.bytes_eq(qp.b, expected_pcr)) {
                return refuse(fd, "attestation fields");
            };
            let tag = tostring(syscall(39)) + "-" + tostring(clock_us());
            let mp = "/tmp/yquote-" + tag + ".msg";
            let sp = "/tmp/yquote-" + tag + ".sig";
            let pp = "/tmp/yquote-" + tag + ".pcr";
            fs.write_bytes(mp, qm.b);
            fs.write_bytes(sp, qs.b);
            fs.write_bytes(pp, qp.b);
            let qcmd = "env -u TPM2TOOLS_TCTI tpm2_checkquote -u " + akpub
                + " -m " + mp + " -s " + sp + " -f " + pp + " -g sha256"
                + " -q " + crypto.hex(cnonce) + " >/dev/null";
            let qcode = exec(qcmd);
            fs.remove_file(mp);
            fs.remove_file(sp);
            fs.remove_file(pp);
            if (qcode != 0) { return refuse(fd, "TPM quote"); };
        };
        let priv = crypto.random_bytes(32);
        let spub = crypto.x25519_base(priv);
        let snonce = crypto.random_bytes(32);
        let th = proto.transcript(user, release, cpub, spub, cnonce, snonce, hash);
        let sig = crypto.rsa_sign_pkcs1(sign_n, sign_d, crypto.sha256(th));
        let ch: [byte] = [];
        ch = proto.put_bytes(ch, spub);
        ch = proto.put_bytes(ch, snonce);
        ch = proto.put_bytes(ch, sig);
        if (!proto.send_msg(fd, ch)) { return 0; };
        let shared = crypto.x25519(priv, cpub);
        let k_c2s = proto.direction_key(shared, th, "yseal-c2s");
        let k_s2c = proto.direction_key(shared, th, "yseal-s2c");
        let authb = proto.recv_msg(fd);
        if (authb == none) {
            store.wipe(shared); store.wipe(k_c2s); store.wipe(k_s2c);
            return refuse(fd, "short auth");
        };
        let ab = authb!;
        if (len(ab) < 12 + 16) {
            store.wipe(shared); store.wipe(k_c2s); store.wipe(k_s2c);
            return refuse(fd, "malformed auth");
        };
        let anonce = ab[0:12];
        let aplain = crypto.chacha_open(k_c2s, anonce,
            proto.aad(th, "client-auth"), ab[12:]);
        if (aplain == none) {
            store.wipe(shared); store.wipe(k_c2s); store.wipe(k_s2c);
            return refuse(fd, "auth decrypt");
        };
        let ap = aplain!;
        let ar = proto.get_str(ap, 0);
        if (ar.next > len(ap) || len(ap) < ar.next + 32) {
            store.wipe(shared); store.wipe(k_c2s); store.wipe(k_s2c);
            return refuse(fd, "malformed auth");
        };
        let license = ar.s;
        let mac = ap[ar.next:ar.next + 32];
        if (license != u.license) {
            store.wipe(shared); store.wipe(k_c2s); store.wipe(k_s2c);
            return refuse(fd, "license");
        };
        let am = proto.auth_context(th, user, license);
        let want = crypto.hmac(crypto.hash_sha256(), u.secret, am);
        if (!crypto.bytes_eq(mac, want)) {
            store.wipe(shared); store.wipe(k_c2s); store.wipe(k_s2c);
            return refuse(fd, "licence MAC");
        };
        if (!store.nonce_add(nonce_path, seen, cid, 4096)) {
            store.wipe(shared); store.wipe(k_c2s); store.wipe(k_s2c);
            return refuse(fd, "cannot persist the nonce");
        };
        let nonce = crypto.random_bytes(12);
        let sealed = crypto.chacha_seal(k_s2c, nonce,
            proto.aad(th, "server-key"), key);
        let out: [byte] = [];
        out += nonce;
        out += sealed;
        let ok = proto.send_msg(fd, out);
        store.wipe(shared);
        store.wipe(k_c2s);
        store.wipe(k_s2c);
        fails = 0;
        if (!ok) { eputs("keyserver: short key reply\n"); };
        0
    };
    eputs("keyserver: listening on " + tostring(port!) + "\n");
    net.listen_tcp(port!, serve)
};

let r = main();
exit(r);
