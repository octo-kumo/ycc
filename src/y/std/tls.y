// std/tls.y — a TLS 1.3 client (RFC 8446) over std/net, in plain Y.
//
//     import tls;
//     let c = tls.connect("example.com", 443);
//     if (c.err != "") { print(c.err); exit(1); };
//     tls.send(c, bytes("GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n"));
//     let chunk = tls.recv(c);
//     while (chunk != none) { puts(from_bytes(chunk!)); chunk = tls.recv(c); };
//     tls.close(c);
//
// The handshake offers X25519 and the suites TLS_CHACHA20_POLY1305_SHA256,
// TLS_AES_128_GCM_SHA256 and TLS_AES_256_GCM_SHA384 (std/crypto). The
// server's chain must lead to a trust anchor and name the host
// (std/x509), its CertificateVerify and Finished must hold. Not done: a
// HelloRetryRequest (a server that will not take X25519), resumption,
// 0-RTT, client certificates (a request for one is answered with none).
// A failure leaves c.err set (and the connection closed); send and recv
// then do nothing.
import crypto;
import x509;
import net;

// A connection. Records are references, so the functions below update
// one in place: its keys, sequence numbers and buffers. `alpn` is the
// protocol the server chose by ALPN (RFC 7301) and `alpn_matched` whether
// that is the one `Opts.alpn` asked for -- RFC 7301 3.2 has the client
// check it, so a caller that offered one and needs it tests that flag
// rather than reading `alpn` itself.
type Conn = {
    fd: long, err: str, host: str, suite: long, alpn: str,
    alpn_matched: bool, eof: bool,
    wkey: [byte], wiv: [byte], wseq: long, wsecret: [byte],
    rkey: [byte], riv: [byte], rseq: long, rsecret: [byte],
    inbuf: [byte], hs: [byte]
};

// connect_with's choices: trust anchors as PEM text instead of the
// system's, an ALPN protocol to ask for ("http/1.1"), no verification
// of the server's chain (insecure: its signatures still hold), and the
// seconds a read or a connect may wait (30).
type Opts = { anchors?: str, alpn?: str, insecure?: bool, timeout?: long };

// A record: its type and (decrypted) contents; typ -1 at the end or on an
// error (Conn.err).
type Rec = { typ: long, body: [byte] };

// A handshake message: its type, contents and its bytes for the
// transcript; typ -1 on an error.
type Msg = { typ: long, body: [byte], raw: [byte] };

// ── suites ───────────────────────────────────────────────────────────────

def suite_hash(s: long) -> crypto.Hash {
    if (s == 0x1302) { crypto.hash_sha384() } else { crypto.hash_sha256() }
};

def suite_keylen(s: long) -> long { if (s == 0x1301) { 16 } else { 32 } };

def seal(s: long, key: [byte], nonce: [byte], aad: [byte], plain: [byte]) -> [byte] {
    if (s == 0x1303) { crypto.chacha_seal(key, nonce, aad, plain) } else { crypto.gcm_seal(key, nonce, aad, plain) }
};

def open_sealed(s: long, key: [byte], nonce: [byte], aad: [byte], sealed: [byte]) -> [byte]? {
    if (s == 0x1303) { crypto.chacha_open(key, nonce, aad, sealed) } else { crypto.gcm_open(key, nonce, aad, sealed) }
};

// ── the key schedule (RFC 8446 7.1) ──────────────────────────────────────

def hkdf_label(h: crypto.Hash, secret: [byte], label: str, ctx: [byte], n: long) -> [byte] {
    let info: [byte] = [];
    info += crypto.be_bytes(n, 2);
    let l = bytes("tls13 " + label);
    info += len(l);
    info += l;
    info += len(ctx);
    info += ctx;
    crypto.hkdf_expand(h, secret, info, n)
};

// Derive-Secret: the label over the hash of the transcript so far.
def derive(h: crypto.Hash, secret: [byte], label: str, transcript: [byte]) -> [byte] {
    hkdf_label(h, secret, label, h.f(transcript), h.size)
};

def zeros(n: long) -> [byte] {
    let z: [byte] = [];
    let i = 0;
    while (i < n) {
        z += 0;
        i = i + 1;
    };
    z
};

def set_write(c: Conn, secret: [byte]) {
    let h = suite_hash(c.suite);
    c.wkey = hkdf_label(h, secret, "key", [], suite_keylen(c.suite));
    c.wiv = hkdf_label(h, secret, "iv", [], 12);
    c.wseq = 0;
    c.wsecret = secret;
};

def set_read(c: Conn, secret: [byte]) {
    let h = suite_hash(c.suite);
    c.rkey = hkdf_label(h, secret, "key", [], suite_keylen(c.suite));
    c.riv = hkdf_label(h, secret, "iv", [], 12);
    c.rseq = 0;
    c.rsecret = secret;
};

// The per-record nonce: the IV XOR the sequence number (RFC 8446 5.3).
def nonce(iv: [byte], seq: long) -> [byte] {
    let n: [byte] = [];
    n += iv;
    let i = 0;
    while (i < 8) {
        n[11 - i] = n[11 - i] ^ ((seq >>> (8 * i)) & 255);
        i = i + 1;
    };
    n
};

// ── records ──────────────────────────────────────────────────────────────

def fail(c: Conn, why: str) -> bool {
    if (c.err == "") { c.err = why; };
    if (c.fd >= 0) {
        net.close_fd(c.fd);
        c.fd = -1;
    };
    false
};

def write_all(c: Conn, data: [byte]) -> bool {
    let off = 0;
    while (off < len(data)) {
        // Through the named layer: fd 1 is write(2) on Linux and an unrelated
        // Nt function on Windows, so a raw number here is a target bug (B2).
        let k = os_call("y_os_write", c.fd, &data[off], len(data) - off);
        if (k <= 0) { return fail(c, "the connection broke while sending"); };
        off = off + k;
    };
    true
};

// A plaintext record (the ClientHello, a ChangeCipherSpec).
def write_plain(c: Conn, typ: long, payload: [byte], legacy: long) -> bool {
    let r: [byte] = [];
    r += typ;
    r += crypto.be_bytes(legacy, 2);
    r += crypto.be_bytes(len(payload), 2);
    r += payload;
    write_all(c, r)
};

// data of content type typ, sealed under the write keys, in records of at
// most 16 KiB.
def write_sealed(c: Conn, typ: long, data: [byte]) -> bool {
    let off = 0;
    let ok = c.err == "";
    while (ok && (off < len(data) || off == 0)) {
        let n = len(data) - off;
        if (n > 16384) { n = 16384; };
        let inner: [byte] = [];
        inner += data[off:off + n];
        inner += typ;
        let aad: [byte] = [23, 3, 3];
        aad += crypto.be_bytes(len(inner) + 16, 2);
        let rec: [byte] = [];
        rec += aad;
        rec += seal(c.suite, c.wkey, nonce(c.wiv, c.wseq), aad, inner);
        c.wseq = c.wseq + 1;
        ok = write_all(c, rec);
        off = off + n;
        if (n == 0) { off = 1; };
    };
    ok
};

// The next record, decrypted when the read keys are set.
def read_record(c: Conn) -> Rec {
    let none_r: Rec = { typ: -1, body: [] };
    if (c.err != "" || c.eof) { return none_r; };
    let buf: [byte; 16384] = [0; 16384];
    let need = 5;
    let have = false;
    while (!have) {
        if (len(c.inbuf) >= 5) { need = 5 + c.inbuf[3] * 256 + c.inbuf[4]; };
        if (len(c.inbuf) >= need) {
            have = true;
        } else {
            let k = os_call("y_os_read", c.fd, &buf[0], 16384);
            if (k <= 0) {
                if (len(c.inbuf) == 0 && k == 0) { c.eof = true; } else { fail(c, "the connection broke"); };
                return none_r;
            };
            c.inbuf += buf[0:k];
        };
    };
    let typ: long = c.inbuf[0];
    let body = c.inbuf[5:need];
    let header = c.inbuf[0:5];
    c.inbuf = c.inbuf[need:len(c.inbuf)];
    if (len(body) > 16384 + 256) {
        fail(c, "record overflow");
        return none_r;
    };
    if (typ == 23 && len(c.rkey) > 0) {
        let plain = open_sealed(c.suite, c.rkey, nonce(c.riv, c.rseq), header, body);
        if (plain == none) {
            fail(c, "bad record MAC");
            return none_r;
        };
        c.rseq = c.rseq + 1;
        let p = plain !;
        let i = len(p) - 1;
        while (i >= 0 && p[i] == 0) { i = i - 1; };
        if (i < 0) {
            fail(c, "an empty record");
            return none_r;
        };
        return { typ: p[i], body: p[0:i] };
    };
    { typ: typ, body: body }
};

// The text of an alert record's description.
def alert_text(body: [byte]) -> str {
    if (len(body) < 2) { "a malformed alert" }
    else if (body[1] == 0) { "the server closed the connection during the handshake (does it speak TLS 1.3?)" }
    else if (body[1] == 40) { "the server ended the handshake (handshake_failure)" }
    else if (body[1] == 42 || body[1] == 43 || body[1] == 44 || body[1] == 45 || body[1] == 46) { "the server rejected a certificate" }
    else if (body[1] == 70) { "the server does not speak TLS 1.3 (protocol_version)" }
    else if (body[1] == 112) { "the server knows no such name (unrecognized_name)" }
    else { "the server sent alert " + tostring(body[1]) }
};

// The next handshake message (one may span records, a record hold
// several); ChangeCipherSpec records pass unseen.
def next_msg(c: Conn) -> Msg {
    let bad: Msg = { typ: -1, body: [], raw: [] };
    while (len(c.hs) < 4 || len(c.hs) < 4 + ((c.hs[1] << 16) | (c.hs[2] << 8) | c.hs[3])) {
        let r = read_record(c);
        if (r.typ == 22) { c.hs += r.body; }
        else if (r.typ == 20) { }
        else if (r.typ == 21) {
            fail(c, alert_text(r.body));
            return bad;
        } else {
            if (c.err == "") { fail(c, "the server closed the connection during the handshake"); };
            return bad;
        };
    };
    let n = (c.hs[1] << 16) | (c.hs[2] << 8) | c.hs[3];
    let raw = c.hs[0:4 + n];
    c.hs = c.hs[4 + n:len(c.hs)];
    { typ: raw[0], body: raw[4:len(raw)], raw: raw }
};

// ── the handshake ────────────────────────────────────────────────────────

def u16(v: long) -> [byte] { crypto.be_bytes(v, 2) };

def vec8(b: [byte]) -> [byte] {
    let o: [byte] = [];
    o += len(b);
    o += b;
    o
};

def vec16(b: [byte]) -> [byte] {
    let o: [byte] = [];
    o += u16(len(b));
    o += b;
    o
};

def ext(typ: long, data: [byte]) -> [byte] {
    let o: [byte] = [];
    o += u16(typ);
    o += vec16(data);
    o
};

def hs_msg(typ: long, body: [byte]) -> [byte] {
    let o: [byte] = [];
    o += typ;
    o += crypto.be_bytes(len(body), 3);
    o += body;
    o
};

def client_hello(host: str, random: [byte], sid: [byte], pub: [byte], alpn: str) -> [byte] {
    let b: [byte] = [3, 3];
    b += random;
    b += vec8(sid);
    let suites: [byte] = [0x13, 0x03, 0x13, 0x01, 0x13, 0x02];
    b += vec16(suites);
    b += [1, 0];
    let exts: [byte] = [];
    if (!net.is_quad(host)) {
        let sn: [byte] = [0];
        sn += vec16(bytes(host));
        exts += ext(0, vec16(sn));
    };
    let groups: [byte] = [0, 0x1d];
    exts += ext(10, vec16(groups));
    let algs: [byte] = [4, 3, 5, 3, 8, 4, 8, 5, 4, 1, 5, 1];
    exts += ext(13, vec16(algs));
    let vers: [byte] = [3, 4];
    exts += ext(43, vec8(vers));
    let share: [byte] = [0, 0x1d];
    share += vec16(pub);
    exts += ext(51, vec16(share));
    if (alpn != "") { exts += ext(16, vec16(vec8(bytes(alpn)))); };
    b += vec16(exts);
    hs_msg(1, b)
};

// The 16-bit big-endian number at b[i].
def be16(b: [byte], i: long) -> long { b[i] * 256 + b[i + 1] };

// The server's X25519 share from a ServerHello body (setting c.suite), or
// [] after fail().
def server_hello(c: Conn, b: [byte], sid: [byte]) -> [byte] {
    let none_b: [byte] = [];
    // SHA-256("HelloRetryRequest"): the random of a HelloRetryRequest
    let hrr = crypto.unhex("cf21ad74e59a6111be1d8c021e65b891c2a211167abb8c5e079e09e2c8a8339c");
    if (len(b) < 38) {
        fail(c, "a malformed ServerHello");
        return none_b;
    };
    if (crypto.bytes_eq(b[2:34], hrr)) {
        fail(c, "the server asked to retry with a key share other than X25519");
        return none_b;
    };
    let p = 34;
    let sl: long = b[p];
    if (p + 1 + sl + 3 > len(b) || !crypto.bytes_eq(b[p + 1:p + 1 + sl], sid)) {
        fail(c, "a malformed ServerHello");
        return none_b;
    };
    p = p + 1 + sl;
    let suite = be16(b, p);
    if (suite != 0x1301 && suite != 0x1302 && suite != 0x1303) {
        fail(c, "the server chose a cipher suite not offered");
        return none_b;
    };
    c.suite = suite;
    p = p + 3;
    let key: [byte] = [];
    let v13 = false;
    if (p + 2 <= len(b)) {
        let end = p + 2 + be16(b, p);
        p = p + 2;
        while (p + 4 <= end && end <= len(b)) {
            let et = be16(b, p);
            let el = be16(b, p + 2);
            let d = p + 4;
            if (d + el > end) {
                fail(c, "a malformed ServerHello");
                return none_b;
            };
            if (et == 43 && el == 2 && be16(b, d) == 0x0304) { v13 = true; };
            if (et == 51 && el >= 4 && be16(b, d) == 0x1d && be16(b, d + 2) == 32 && el == 36) { key = b[d + 4:d + 36]; };
            p = d + el;
        };
    };
    if (!v13) {
        fail(c, "the server does not speak TLS 1.3");
        return none_b;
    };
    if (len(key) != 32) {
        fail(c, "the server sent no X25519 key share");
        return none_b;
    };
    key
};

// The certificates (DER) of a Certificate message.
def cert_list(b: [byte]) -> [[byte]] {
    let out: [[byte]] = [];
    if (len(b) < 1) { return out; };
    let p = 1 + b[0];
    if (p + 3 > len(b)) { return out; };
    let end = p + 3 + ((b[p] << 16) | (b[p + 1] << 8) | b[p + 2]);
    p = p + 3;
    while (p + 3 <= end && end <= len(b)) {
        let n = (b[p] << 16) | (b[p + 1] << 8) | b[p + 2];
        if (p + 3 + n + 2 > end) { return out; };
        out += [b[p + 3:p + 3 + n]];
        p = p + 3 + n;
        p = p + 2 + be16(b, p);
    };
    out
};

// The content a server's CertificateVerify signs (RFC 8446 4.4.3).
def verify_content(thash: [byte]) -> [byte] {
    let m: [byte] = [];
    let i = 0;
    while (i < 64) {
        m += 32;
        i = i + 1;
    };
    m += bytes("TLS 1.3, server CertificateVerify");
    m += 0;
    m += thash;
    m
};

def blank(fd: long, host: str) -> Conn {
    {
        fd: fd, err: "", host: host, suite: 0, alpn: "", alpn_matched: false, eof: false,
        wkey: [], wiv: [], wseq: 0, wsecret: [], rkey: [], riv: [], rseq: 0, rsecret: [],
        inbuf: [], hs: []
    }
};

// connect_with the defaults: the system's trust anchors.
def connect(host: str, port: long) -> Conn { connect_with(host, port, {}) };

// A TLS 1.3 connection to host:port, its handshake done; c.err says why
// when it could not be made.
def connect_with(host: str, port: long, o: Opts) -> Conn {
    let fd = net.connect_tcp(host, port);
    let c = blank(fd, host);
    if (fd < 0) {
        c.err = "cannot connect to " + host + ":" + tostring(port) + " (" + tostring(-fd) + ")";
        return c;
    };
    let secs = 30;
    if (o.timeout != none) { secs = o.timeout !; };
    net.set_timeouts(fd, secs);
    let alpn = "";
    if (o.alpn != none) { alpn = o.alpn !; };
    handshake(c, o, alpn);
    c
};

def handshake(c: Conn, o: Opts, alpn: str) -> bool {
    let priv = crypto.random_bytes(32);
    let pub = crypto.x25519_base(priv);
    let sid = crypto.random_bytes(32);
    let ch = client_hello(c.host, crypto.random_bytes(32), sid, pub, alpn);
    let tr: [byte] = [];
    tr += ch;
    if (!write_plain(c, 22, ch, 0x0301)) { return false; };
    let sh = next_msg(c);
    if (sh.typ != 2) { return fail(c, "expected a ServerHello"); };
    let spub = server_hello(c, sh.body, sid);
    if (len(spub) == 0) { return false; };
    tr += sh.raw;
    let h = suite_hash(c.suite);
    let shared = crypto.x25519(priv, spub);
    let early = crypto.hkdf_extract(h, [], zeros(h.size));
    let empty: [byte] = [];
    let hsec = crypto.hkdf_extract(h, derive(h, early, "derived", empty), shared);
    let chs = derive(h, hsec, "c hs traffic", tr);
    let shs = derive(h, hsec, "s hs traffic", tr);
    set_read(c, shs);
    set_write(c, chs);
    // EncryptedExtensions .. server Finished
    let certs: [[byte]] = [];
    let asked = false;
    let verified = false;
    let done = false;
    while (!done) {
        let m = next_msg(c);
        if (m.typ < 0) { return false; };
        if (m.typ == 8) {
            c.alpn = ee_alpn(m.body);
            // RFC 7301 3.2: the client must check that the server chose a
            // protocol it offered, and abort if it did not. `alpn` is what
            // came back -- the value is reported either way, so a caller can
            // see what a server answered -- and `alpn_matched` says whether
            // that was the one asked for. An offer of none leaves it false
            // whatever the server sends.
            c.alpn_matched = (alpn != "" && c.alpn == alpn);
        } else if (m.typ == 13) {
            asked = true;
        } else if (m.typ == 11) {
            certs = cert_list(m.body);
            if (len(certs) == 0) { return fail(c, "the server sent no certificate"); };
            let insecure = o.insecure != none && o.insecure !;
            if (!insecure) {
                let now = time_us() / 1000000;
                let why = "";
                if (o.anchors != none) { why = x509.verify_chain_with(certs, c.host, now, x509.anchors_pem(o.anchors !)); }
                else { why = x509.verify_chain(certs, c.host, now); };
                if (why != "") { return fail(c, why); };
            };
        } else if (m.typ == 15) {
            if (len(certs) == 0 || len(m.body) < 4) { return fail(c, "a CertificateVerify without a certificate"); };
            let scheme = be16(m.body, 0);
            let sig = m.body[4:len(m.body)];
            if (!x509.verify_signed(certs[0], scheme, verify_content(h.f(tr)), sig)) {
                return fail(c, "the server's CertificateVerify signature does not hold");
            };
            verified = true;
        } else if (m.typ == 20) {
            let fk = hkdf_label(h, shs, "finished", [], h.size);
            if (!crypto.bytes_eq(crypto.hmac(h, fk, h.f(tr)), m.body)) {
                return fail(c, "the server's Finished does not match");
            };
            if (!verified) { return fail(c, "the server proved no certificate"); };
            done = true;
        } else {
            return fail(c, "an unexpected handshake message " + tostring(m.typ));
        };
        tr += m.raw;
    };
    let msec = crypto.hkdf_extract(h, derive(h, hsec, "derived", empty), zeros(h.size));
    let cap = derive(h, msec, "c ap traffic", tr);
    let sap = derive(h, msec, "s ap traffic", tr);
    // ChangeCipherSpec for middleboxes (RFC 8446 D.4), then our Finished
    let ccs: [byte] = [1];
    if (!write_plain(c, 20, ccs, 0x0303)) { return false; };
    if (asked) {
        // a Certificate with none: no client certificate
        let none_cert: [byte] = [0, 0, 0, 0];
        let cm = hs_msg(11, none_cert);
        if (!write_sealed(c, 22, cm)) { return false; };
        tr += cm;
    };
    let cfk = hkdf_label(h, chs, "finished", [], h.size);
    let fin = hs_msg(20, crypto.hmac(h, cfk, h.f(tr)));
    if (!write_sealed(c, 22, fin)) { return false; };
    set_read(c, sap);
    set_write(c, cap);
    true
};

// The protocol an EncryptedExtensions body chose by ALPN ("" for none).
def ee_alpn(b: [byte]) -> str {
    if (len(b) < 2) { return ""; };
    let end = 2 + be16(b, 0);
    let p = 2;
    while (p + 4 <= end && end <= len(b)) {
        let et = be16(b, p);
        let el = be16(b, p + 2);
        if (et == 16 && el >= 3 && p + 4 + el <= end) {
            let n: long = b[p + 6];
            if (p + 7 + n <= end) { return from_bytes(b[p + 7:p + 7 + n]); };
        };
        p = p + 4 + el;
    };
    ""
};

// ── application data ─────────────────────────────────────────────────────

// Send data; false (and c.err) when the connection cannot take it.
def send(c: Conn, data: [byte]) -> bool {
    if (c.err != "") { return false; };
    if (len(data) == 0) { return true; };
    write_sealed(c, 23, data)
};

// The next data the server sent; none at its end (close_notify, or the
// connection closing) or on an error (c.err).
def recv(c: Conn) -> [byte]? {
    while (true) {
        let r = read_record(c);
        if (r.typ == 23) {
            if (len(r.body) > 0) { return some(r.body); };
        } else if (r.typ == 22) {
            c.hs += r.body;
            if (!post_handshake(c)) { return none; };
        } else if (r.typ == 21) {
            if (len(r.body) >= 2 && r.body[1] == 0) { c.eof = true; } else { fail(c, alert_text(r.body)); };
            return none;
        } else {
            return none;
        };
    };
    none
};

// Handshake messages after the handshake: NewSessionTicket (ignored),
// KeyUpdate (the read keys move on; answered when asked).
def post_handshake(c: Conn) -> bool {
    while (len(c.hs) >= 4 && len(c.hs) >= 4 + ((c.hs[1] << 16) | (c.hs[2] << 8) | c.hs[3])) {
        let n = (c.hs[1] << 16) | (c.hs[2] << 8) | c.hs[3];
        let typ: long = c.hs[0];
        let body = c.hs[4:4 + n];
        c.hs = c.hs[4 + n:len(c.hs)];
        if (typ == 24) {
            let h = suite_hash(c.suite);
            set_read(c, hkdf_label(h, c.rsecret, "traffic upd", [], h.size));
            if (len(body) == 1 && body[0] == 1) {
                let ku: [byte] = [0];
                if (!write_sealed(c, 22, hs_msg(24, ku))) { return false; };
                set_write(c, hkdf_label(h, c.wsecret, "traffic upd", [], h.size));
            };
        } else if (typ != 4) {
            return fail(c, "an unexpected handshake message " + tostring(typ));
        };
    };
    true
};

// Close: a close_notify alert, then the socket.
def close(c: Conn) {
    if (c.err == "" && c.fd >= 0) {
        let alert: [byte] = [1, 0];
        write_sealed(c, 21, alert);
    };
    if (c.fd >= 0) {
        net.close_fd(c.fd);
        c.fd = -1;
    };
};

export { connect, connect_with, send, recv, close };
