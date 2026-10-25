// tools/keyserver/proto.y -- length-prefixed messages and the transcript.
import net;
import crypto;

def be32(v: long) -> [byte] { crypto.be_bytes(v, 4) };

def u32(b: [byte], at: long) -> long {
    (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3]
};

def put_bytes(out: [byte], b: [byte]) -> [byte] {
    let o = out;
    o += b;
    o
};

def put_blob(out: [byte], b: [byte]) -> [byte] {
    let o = out;
    o += be32(len(b));
    o += b;
    o
};

def put_str(out: [byte], s: str) -> [byte] {
    let b = bytes(s);
    let o = out;
    o += be32(len(b));
    o += b;
    o
};

// A length is trusted only after it is known to fit; otherwise the cursor
// moves past the end and every later range check fails instead of slicing.
def bad_next(b: [byte]) -> long { len(b) + 1 };

def get_str(b: [byte], at: long) -> { s: str, next: long } {
    if (at < 0 || at + 4 > len(b)) { return { s: "", next: bad_next(b) }; };
    let n = u32(b, at);
    if (n > len(b) - at - 4) { return { s: "", next: bad_next(b) }; };
    { s: from_bytes(b[at + 4:at + 4 + n]), next: at + 4 + n }
};

def get_bytes(b: [byte], at: long) -> { b: [byte], next: long } {
    if (at < 0 || at + 4 > len(b)) { return { b: [], next: bad_next(b) }; };
    let n = u32(b, at);
    if (n > len(b) - at - 4) { return { b: [], next: bad_next(b) }; };
    { b: b[at + 4:at + 4 + n], next: at + 4 + n }
};

def send_msg(fd: long, b: [byte]) -> bool {
    let wire: [byte] = [];
    wire += be32(len(b));
    wire += b;
    let s = from_bytes(wire);
    let off = 0;
    while (off < len(s)) {
        let n = net.send_str(fd, s[off:]);
        if (n <= 0) { return false; };
        off += n;
    };
    true
};

def read_exact(fd: long, n: long) -> [byte]? {
    let out: [byte] = [];
    while (len(out) < n) {
        let s = net.recv_str(fd, n - len(out));
        if (s == none) { return none; };
        let b = bytes(s!);
        if (len(b) == 0) { return none; };
        out += b;
    };
    some(out)
};

def recv_msg(fd: long) -> [byte]? {
    let h = read_exact(fd, 4);
    if (h == none) { return none; };
    let n = u32(h!, 0);
    if (n > 65536) { return none; };
    read_exact(fd, n)
};

def transcript(user: str, release: str, cpub: [byte], spub: [byte],
        cnonce: [byte], snonce: [byte], hash: [byte]) -> [byte] {
    let b = bytes("YSEAL3");
    b = put_str(b, user);
    b = put_str(b, release);
    b = put_bytes(b, cpub);
    b = put_bytes(b, spub);
    b = put_bytes(b, cnonce);
    b = put_bytes(b, snonce);
    b = put_bytes(b, hash);
    crypto.sha256(b)
};

// The licence and the user name are bound into the licence MAC on top of the
// transcript, so a proof for one account cannot be moved to another.
// A copy, because put_str appends in place: a caller must be able to keep the
// transcript it derived the keys from.
def copy_bytes(b: [byte]) -> [byte] {
    let out: [byte] = [];
    out += b;
    out
};

def auth_context(th: [byte], user: str, license: str) -> [byte] {
    let b = put_str(copy_bytes(th), user);
    put_str(b, license)
};

// Direction-separated keys from the X25519 secret. The transcript is the
// HKDF salt, so each connection gets fresh keys even if a random nonce ever
// repeats, and a client-to-server ciphertext cannot be reflected as one from
// the server.
def direction_key(shared: [byte], th: [byte], label: str) -> [byte] {
    let h = crypto.hash_sha256();
    let prk = crypto.hkdf_extract(h, th, shared);
    crypto.hkdf_expand(h, prk, bytes(label), 32)
};

def aad(th: [byte], label: str) -> [byte] {
    let b = copy_bytes(th);
    b += bytes(label);
    b
};

def zeros12() -> [byte] {
    let z: [byte] = [];
    for i in 0..12 { z += 0; };
    z
};

def session_key(shared: [byte], th: [byte]) -> [byte] {
    direction_key(shared, th, "yseal-session")
};

export { be32, u32, put_bytes, put_blob, put_str, get_str, get_bytes, send_msg,
    recv_msg, transcript, auth_context, copy_bytes, session_key, direction_key, aad, zeros12 };
