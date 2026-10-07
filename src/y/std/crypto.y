// std/crypto.y — cryptography in plain Y: hashes, MACs, key derivation,
// ciphers, key agreement and signature verification -- what a TLS 1.3
// client needs (std/tls.y), and no more.
//
//     import crypto;
//     let d = crypto.sha256(bytes("abc"));
//     print(crypto.hex(d));
//
// Byte strings are [byte]. Words are longs: a 32-bit word is kept below
// 2^32 by masking, a 64-bit one wraps as a long does (`>>>` is the
// logical shift). Nothing here is constant-time beyond what its
// arithmetic happens to be: it verifies and encrypts, and its one secret
// key (the X25519 share) lives for one handshake.

// ── argument checks ──────────────────────────────────────────────────────
// A wrong argument is a bug in the caller, not a message to encrypt: say
// what was wanted and stop, the way struct's format check does.

// A wrong argument, named: `what` says what the call needs.
def arg_error(what: str) -> long {
    puts("crypto: " + what + "\n");
    exit(1);
    0
};

// A nonce is 12 bytes -- SP 800-38D fixes GCM's there, RFC 8439
// ChaCha20's -- and each of the ciphers reads exactly that many.
def check_nonce(cipher: str, nonce: [byte]) -> long {
    if (len(nonce) != 12) {
        arg_error("a " + cipher + " nonce must be 12 bytes, " + tostring(len(nonce)) + " given");
    };
    0
};

// A key of exactly n bytes.
def check_key(cipher: str, n: long, key: [byte]) -> long {
    if (len(key) != n) {
        arg_error("a " + cipher + " key must be " + tostring(n) + " bytes, " + tostring(len(key)) + " given");
    };
    0
};

// ── bytes ────────────────────────────────────────────────────────────────

// b as lowercase hex.
def hex(b: [byte]) -> str {
    let digits = "0123456789abcdef";
    let out: [byte] = [];
    foreach (x in b) {
        out += digits[x >> 4];
        out += digits[x & 15];
    };
    from_bytes(out)
};

// The bytes a hex string spells (pairs of digits; anything else stops it).
def unhex(s: str) -> [byte] {
    let out: [byte] = [];
    let i = 0;
    while (i + 1 < len(s)) {
        let hi = hexdigit(s[i]);
        let lo = hexdigit(s[i + 1]);
        if (hi < 0 || lo < 0) { return out; };
        out += hi * 16 + lo;
        i = i + 2;
    };
    out
};

def hexdigit(c: byte) -> long {
    if (c >= '0' && c <= '9') { c - '0' }
    else if (c >= 'a' && c <= 'f') { c - 'a' + 10 }
    else if (c >= 'A' && c <= 'F') { c - 'A' + 10 }
    else { -1 }
};

// n bytes from the kernel's random source (getrandom).
def random_bytes(n: long) -> [byte] {
    let out: [byte] = [];
    let i = 0;
    while (i < n) {
        out += 0;
        i = i + 1;
    };
    let got = 0;
    while (got < n) {
        // Through the named layer (B2): the Windows half of y_os_random is in
        // wsys.s and answers ENOSYS, because BCryptGenRandom is a DLL export
        // and the PE writer has no import table yet. So this FAILS CLOSED:
        // the old loop ignored a failure, which would have spun forever on
        // ENOSYS (a negative k never advances `got`), and on a target whose
        // syscall number meant something else it would have taken a positive
        // NTSTATUS for a byte count. A random source that cannot produce
        // randomness has to say so.
        let k = os_call("y_os_random", &out[got], n - got);
        if (k > 0) { got = got + k; }
        else {
            eputs("runtime error: no randomness source on this target\n");
            exit(1);
            0
        };
    };
    out
};

// a and b hold the same bytes; the time taken does not depend on where
// they differ.
def bytes_eq(a: [byte], b: [byte]) -> bool {
    if (len(a) != len(b)) { return false; };
    let d = 0;
    let i = 0;
    while (i < len(a)) {
        d = d | (a[i] ^ b[i]);
        i = i + 1;
    };
    d == 0
};

// Every byte of b is zero; the time taken does not depend on where the
// first zero is.
def is_zero(b: [byte]) -> bool {
    let d = 0;
    let i = 0;
    while (i < len(b)) {
        d = d | b[i];
        i = i + 1;
    };
    d == 0
};

// The big-endian n-byte encoding of v.
def be_bytes(v: long, n: long) -> [byte] {
    let out: [byte] = [];
    let i = n - 1;
    while (i >= 0) {
        out += (v >>> (8 * i)) & 255;
        i = i - 1;
    };
    out
};

// ── SHA-2 (FIPS 180-4) ───────────────────────────────────────────────────

// sha256's 64 immediates are built on first use, not as a top-level `let`: a top-level
// binding is inlined at _start, which is a shake root, so the table was in
// every binary that imports crypto whether it ever hashes anything (and this
// def, reachable from nothing else, is dropped).
let K256: [long] = [];

def k256_tab() -> [long] {
    if (len(K256) > 0) { return K256; };
    K256 = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ];
    K256
};

// sha384/sha512's 80 immediates are built on first use, not as a top-level `let`: a top-level
// binding is inlined at _start, which is a shake root, so the table was in
// every binary that imports crypto whether it ever hashes anything (and this
// def, reachable from nothing else, is dropped).
let K512: [long] = [];

def k512_tab() -> [long] {
    if (len(K512) > 0) { return K512; };
    K512 = [
        0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc,
        0x3956c25bf348b538, 0x59f111f1b605d019, 0x923f82a4af194f9b, 0xab1c5ed5da6d8118,
        0xd807aa98a3030242, 0x12835b0145706fbe, 0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2,
        0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235, 0xc19bf174cf692694,
        0xe49b69c19ef14ad2, 0xefbe4786384f25e3, 0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65,
        0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5,
        0x983e5152ee66dfab, 0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4,
        0xc6e00bf33da88fc2, 0xd5a79147930aa725, 0x06ca6351e003826f, 0x142929670a0e6e70,
        0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed, 0x53380d139d95b3df,
        0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b,
        0xa2bfe8a14cf10364, 0xa81a664bbc423001, 0xc24b8b70d0f89791, 0xc76c51a30654be30,
        0xd192e819d6ef5218, 0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8,
        0x19a4c116b8d2d0c8, 0x1e376c085141ab53, 0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8,
        0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb, 0x5b9cca4f7763e373, 0x682e6ff3d6b2b8a3,
        0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec,
        0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b,
        0xca273eceea26619c, 0xd186b8c721c0c207, 0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178,
        0x06f067aa72176fba, 0x0a637dc5a2c898a6, 0x113f9804bef90dae, 0x1b710b35131c471b,
        0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc, 0x431d67c49c100d4c,
        0x4cc5d4becb3e42b6, 0x597f299cfc657e2a, 0x5fcb6fab3ad6faec, 0x6c44198c4a475817
    ];
    K512
};

def rotr32(x: long, n: long) -> long {((x >>> n) | (x << (32 - n))) & 0xffffffff };
def rotr64(x: long, n: long) -> long {(x >>> n) | (x << (64 - n)) };

// data padded for a hash of block size `block` (64 or 128): a 1 bit,
// zeros, and the length in bits, big-endian, in the last 8 bytes.
def md_pad(data: [byte], block: long) -> [byte] {
    let m: [byte] = [];
    m += data;
    m += 128;
    let tail = block - 8;
    if (block == 128) { tail = 112; };
    while (len(m) % block != tail) { m += 0; };
    if (block == 128) { m += be_bytes(0, 8); };
    m += be_bytes(len(data) * 8, 8);
    m
};

def sha256(data: [byte]) -> [byte] {
    let h: [long] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    let m = md_pad(data, 64);
    let w: [long; 64] = [0; 64];
    let off = 0;
    while (off < len(m)) {
        let i = 0;
        while (i < 16) {
            let j = off + 4 * i;
            w[i] = (m[j] << 24) | (m[j + 1] << 16) | (m[j + 2] << 8) | m[j + 3];
            i = i + 1;
        };
        while (i < 64) {
            let x = w[i - 15];
            let y = w[i - 2];
            let s0 = rotr32(x, 7) ^ rotr32(x, 18) ^ (x >>> 3);
            let s1 = rotr32(y, 17) ^ rotr32(y, 19) ^ (y >>> 10);
            w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
            i = i + 1;
        };
        let a = h[0];
        let b = h[1];
        let c = h[2];
        let d = h[3];
        let e = h[4];
        let f = h[5];
        let g = h[6];
        let k = h[7];
        let ktab = k256_tab();
        i = 0;
        while (i < 64) {
            let t1 = (k + (rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25)) + ((e & f) ^ (~e & g)) + ktab[i] + w[i]) & 0xffffffff;
            let t2 = ((rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) & 0xffffffff;
            k = g;
            g = f;
            f = e;
            e = (d + t1) & 0xffffffff;
            d = c;
            c = b;
            b = a;
            a = (t1 + t2) & 0xffffffff;
            i = i + 1;
        };
        h[0] = (h[0] + a) & 0xffffffff;
        h[1] = (h[1] + b) & 0xffffffff;
        h[2] = (h[2] + c) & 0xffffffff;
        h[3] = (h[3] + d) & 0xffffffff;
        h[4] = (h[4] + e) & 0xffffffff;
        h[5] = (h[5] + f) & 0xffffffff;
        h[6] = (h[6] + g) & 0xffffffff;
        h[7] = (h[7] + k) & 0xffffffff;
        off = off + 64;
    };
    let out: [byte] = [];
    foreach (x in h) { out += be_bytes(x, 4); };
    out
};

// SHA-512 from the initial values h, its first `n` bytes: SHA-512 itself,
// or SHA-384 (other initial values, 48 bytes).
def sha512_from(data: [byte], h: [long], n: long) -> [byte] {
    let m = md_pad(data, 128);
    let w: [long; 80] = [0; 80];
    let off = 0;
    while (off < len(m)) {
        let i = 0;
        while (i < 16) {
            let v = 0;
            let j = 0;
            while (j < 8) {
                v = (v << 8) | m[off + 8 * i + j];
                j = j + 1;
            };
            w[i] = v;
            i = i + 1;
        };
        while (i < 80) {
            let x = w[i - 15];
            let y = w[i - 2];
            let s0 = rotr64(x, 1) ^ rotr64(x, 8) ^ (x >>> 7);
            let s1 = rotr64(y, 19) ^ rotr64(y, 61) ^ (y >>> 6);
            w[i] = w[i - 16] + s0 + w[i - 7] + s1;
            i = i + 1;
        };
        let a = h[0];
        let b = h[1];
        let c = h[2];
        let d = h[3];
        let e = h[4];
        let f = h[5];
        let g = h[6];
        let k = h[7];
        let ktab = k512_tab();
        i = 0;
        while (i < 80) {
            let t1 = k + (rotr64(e, 14) ^ rotr64(e, 18) ^ rotr64(e, 41)) + ((e & f) ^ (~e & g)) + ktab[i] + w[i];
            let t2 = (rotr64(a, 28) ^ rotr64(a, 34) ^ rotr64(a, 39)) + ((a & b) ^ (a & c) ^ (b & c));
            k = g;
            g = f;
            f = e;
            e = d + t1;
            d = c;
            c = b;
            b = a;
            a = t1 + t2;
            i = i + 1;
        };
        h[0] = h[0] + a;
        h[1] = h[1] + b;
        h[2] = h[2] + c;
        h[3] = h[3] + d;
        h[4] = h[4] + e;
        h[5] = h[5] + f;
        h[6] = h[6] + g;
        h[7] = h[7] + k;
        off = off + 128;
    };
    let out: [byte] = [];
    foreach (x in h) { out += be_bytes(x, 8); };
    out[0:n]
};

def sha512(data: [byte]) -> [byte] {
    let h: [long] = [0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179];
    sha512_from(data, h, 64)
};

def sha384(data: [byte]) -> [byte] {
    let h: [long] = [0xcbbb9d5dc1059ed8, 0x629a292a367cd507, 0x9159015a3070dd17, 0x152fecd8f70e5939,
        0x67332667ffc00b31, 0x8eb44a8768581511, 0xdb0c2e0d64f98fa7, 0x47b5481dbefa4fa4];
    sha512_from(data, h, 48)
};

// A hash function with what HMAC and HKDF need of it.
type Hash = { f: ([byte]) -> [byte], block: long, size: long };

def hash_sha256() -> Hash { { f: sha256, block: 64, size: 32 } };
def hash_sha384() -> Hash { { f: sha384, block: 128, size: 48 } };

// ── HMAC (RFC 2104) and HKDF (RFC 5869) ──────────────────────────────────

def hmac(h: Hash, key: [byte], msg: [byte]) -> [byte] {
    let k: [byte] = [];
    if (len(key) > h.block) { k += h.f(key); } else { k += key; };
    while (len(k) < h.block) { k += 0; };
    let inner: [byte] = [];
    let outer: [byte] = [];
    foreach (x in k) {
        inner += x ^ 0x36;
        outer += x ^ 0x5c;
    };
    inner += msg;
    outer += h.f(inner);
    h.f(outer)
};

def hkdf_extract(h: Hash, salt: [byte], ikm: [byte]) -> [byte] {
    let s: [byte] = [];
    s += salt;
    if (len(s) == 0) {
        let i = 0;
        while (i < h.size) {
            s += 0;
            i = i + 1;
        };
    };
    hmac(h, s, ikm)
};

def hkdf_expand(h: Hash, prk: [byte], info: [byte], n: long) -> [byte] {
    let out: [byte] = [];
    let t: [byte] = [];
    let c = 1;
    while (len(out) < n) {
        let m: [byte] = [];
        m += t;
        m += info;
        m += c;
        t = hmac(h, prk, m);
        out += t;
        c = c + 1;
    };
    out[0:n]
};

// ── ChaCha20 and Poly1305 (RFC 8439) ─────────────────────────────────────

def le32(b: [byte], i: long) -> long {
    b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24)
};

def rotl32(x: long, n: long) -> long {((x << n) | (x >>> (32 - n))) & 0xffffffff };

// The ChaCha20 quarter round on words a, b, c, d of x.
def qround(x: [long; 16], a: long, b: long, c: long, d: long) {
    x[a] = (x[a] + x[b]) & 0xffffffff;
    x[d] = rotl32(x[d] ^ x[a], 16);
    x[c] = (x[c] + x[d]) & 0xffffffff;
    x[b] = rotl32(x[b] ^ x[c], 12);
    x[a] = (x[a] + x[b]) & 0xffffffff;
    x[d] = rotl32(x[d] ^ x[a], 8);
    x[c] = (x[c] + x[d]) & 0xffffffff;
    x[b] = rotl32(x[b] ^ x[c], 7);
};

// The 64-byte ChaCha20 block for key (32 bytes), counter and nonce (12).
// A longer key would be used truncated and a short one read past its end,
// so both are refused by name.
def chacha20_block(key: [byte], counter: long, nonce: [byte]) -> [byte] {
    check_key("ChaCha20", 32, key);
    check_nonce("ChaCha20", nonce);
    let s: [long; 16] = [0; 16];
    s[0] = 0x61707865;
    s[1] = 0x3320646e;
    s[2] = 0x79622d32;
    s[3] = 0x6b206574;
    let i = 0;
    while (i < 8) {
        s[4 + i] = le32(key, 4 * i);
        i = i + 1;
    };
    s[12] = counter & 0xffffffff;
    s[13] = le32(nonce, 0);
    s[14] = le32(nonce, 4);
    s[15] = le32(nonce, 8);
    let x: [long; 16] = [0; 16];
    i = 0;
    while (i < 16) {
        x[i] = s[i];
        i = i + 1;
    };
    let r = 0;
    while (r < 10) {
        qround(x, 0, 4, 8, 12);
        qround(x, 1, 5, 9, 13);
        qround(x, 2, 6, 10, 14);
        qround(x, 3, 7, 11, 15);
        qround(x, 0, 5, 10, 15);
        qround(x, 1, 6, 11, 12);
        qround(x, 2, 7, 8, 13);
        qround(x, 3, 4, 9, 14);
        r = r + 1;
    };
    let out: [byte] = [];
    i = 0;
    while (i < 16) {
        let v = (x[i] + s[i]) & 0xffffffff;
        out += v & 255;
        out += (v >> 8) & 255;
        out += (v >> 16) & 255;
        out += (v >> 24) & 255;
        i = i + 1;
    };
    out
};

// data XOR the ChaCha20 key stream from block `counter` on.
def chacha20(key: [byte], counter: long, nonce: [byte], data: [byte]) -> [byte] {
    let out: [byte] = [];
    let off = 0;
    let c = counter;
    while (off < len(data)) {
        let ks = chacha20_block(key, c, nonce);
        let i = 0;
        while (i < 64 && off + i < len(data)) {
            out += data[off + i] ^ ks[i];
            i = i + 1;
        };
        off = off + 64;
        c = c + 1;
    };
    out
};

// The Poly1305 tag (16 bytes) of msg under the one-time key (32 bytes):
// h = (h + block) * r mod 2^130 - 5 over 26-bit limbs, then + s.
def poly1305(key: [byte], msg: [byte]) -> [byte] {
    let m26 = 0x3ffffff;
    let r0 = le32(key, 0) & 0x3ffffff;
    let r1 = (le32(key, 3) >> 2) & 0x3ffff03;
    let r2 = (le32(key, 6) >> 4) & 0x3ffc0ff;
    let r3 = (le32(key, 9) >> 6) & 0x3f03fff;
    let r4 = (le32(key, 12) >> 8) & 0x00fffff;
    let s1 = r1 * 5;
    let s2 = r2 * 5;
    let s3 = r3 * 5;
    let s4 = r4 * 5;
    let h0 = 0;
    let h1 = 0;
    let h2 = 0;
    let h3 = 0;
    let h4 = 0;
    let blk: [byte] = [0; 17];
    let off = 0;
    while (off < len(msg)) {
        let n = len(msg) - off;
        if (n > 16) { n = 16; };
        let i = 0;
        while (i < 17) {
            blk[i] = 0;
            i = i + 1;
        };
        i = 0;
        while (i < n) {
            blk[i] = msg[off + i];
            i = i + 1;
        };
        blk[n] = 1;
        h0 = h0 + (le32(blk, 0) & m26);
        h1 = h1 + ((le32(blk, 3) >> 2) & m26);
        h2 = h2 + ((le32(blk, 6) >> 4) & m26);
        h3 = h3 + ((le32(blk, 9) >> 6) & m26);
        h4 = h4 + ((le32(blk, 12) >> 8) | (blk[16] << 24));
        let d0 = h0 * r0 + h1 * s4 + h2 * s3 + h3 * s2 + h4 * s1;
        let d1 = h0 * r1 + h1 * r0 + h2 * s4 + h3 * s3 + h4 * s2;
        let d2 = h0 * r2 + h1 * r1 + h2 * r0 + h3 * s4 + h4 * s3;
        let d3 = h0 * r3 + h1 * r2 + h2 * r1 + h3 * r0 + h4 * s4;
        let d4 = h0 * r4 + h1 * r3 + h2 * r2 + h3 * r1 + h4 * r0;
        let c = d0 >> 26;
        h0 = d0 & m26;
        d1 = d1 + c;
        c = d1 >> 26;
        h1 = d1 & m26;
        d2 = d2 + c;
        c = d2 >> 26;
        h2 = d2 & m26;
        d3 = d3 + c;
        c = d3 >> 26;
        h3 = d3 & m26;
        d4 = d4 + c;
        c = d4 >> 26;
        h4 = d4 & m26;
        h0 = h0 + c * 5;
        c = h0 >> 26;
        h0 = h0 & m26;
        h1 = h1 + c;
        off = off + 16;
    };
    // the full carry, then h - p when h >= p
    let c = h1 >> 26;
    h1 = h1 & m26;
    h2 = h2 + c;
    c = h2 >> 26;
    h2 = h2 & m26;
    h3 = h3 + c;
    c = h3 >> 26;
    h3 = h3 & m26;
    h4 = h4 + c;
    c = h4 >> 26;
    h4 = h4 & m26;
    h0 = h0 + c * 5;
    c = h0 >> 26;
    h0 = h0 & m26;
    h1 = h1 + c;
    let g0 = h0 + 5;
    c = g0 >> 26;
    g0 = g0 & m26;
    let g1 = h1 + c;
    c = g1 >> 26;
    g1 = g1 & m26;
    let g2 = h2 + c;
    c = g2 >> 26;
    g2 = g2 & m26;
    let g3 = h3 + c;
    c = g3 >> 26;
    g3 = g3 & m26;
    let g4 = h4 + c - (1 << 26);
    if (g4 >= 0) {
        h0 = g0;
        h1 = g1;
        h2 = g2;
        h3 = g3;
        h4 = g4;
    };
    let w0 = (h0 | (h1 << 26)) & 0xffffffff;
    let w1 = ((h1 >> 6) | (h2 << 20)) & 0xffffffff;
    let w2 = ((h2 >> 12) | (h3 << 14)) & 0xffffffff;
    let w3 = ((h3 >> 18) | (h4 << 8)) & 0xffffffff;
    let f = w0 + le32(key, 16);
    let out: [byte] = [];
    out += le_bytes(f, 4);
    f = w1 + le32(key, 20) + (f >> 32);
    out += le_bytes(f, 4);
    f = w2 + le32(key, 24) + (f >> 32);
    out += le_bytes(f, 4);
    f = w3 + le32(key, 28) + (f >> 32);
    out += le_bytes(f, 4);
    out
};

// The little-endian n-byte encoding of v.
def le_bytes(v: long, n: long) -> [byte] {
    let out: [byte] = [];
    let i = 0;
    while (i < n) {
        out += (v >>> (8 * i)) & 255;
        i = i + 1;
    };
    out
};

// Poly1305's input for an AEAD: aad, ct, each zero-padded to 16 bytes,
// then their lengths (64-bit little-endian).
def aead_mac_data(aad: [byte], ct: [byte]) -> [byte] {
    let m: [byte] = [];
    m += aad;
    while (len(m) % 16 != 0) { m += 0; };
    m += ct;
    while (len(m) % 16 != 0) { m += 0; };
    m += le_bytes(len(aad), 8);
    m += le_bytes(len(ct), 8);
    m
};

// ChaCha20-Poly1305 (RFC 8439 2.8): the ciphertext, then its 16-byte tag.
def chacha_seal(key: [byte], nonce: [byte], aad: [byte], plain: [byte]) -> [byte] {
    let otk = chacha20_block(key, 0, nonce)[0:32];
    let ct = chacha20(key, 1, nonce, plain);
    let out: [byte] = [];
    out += ct;
    out += poly1305(otk, aead_mac_data(aad, ct));
    out
};

// The plaintext of a sealed message (ciphertext and tag), none when the
// tag is wrong.
def chacha_open(key: [byte], nonce: [byte], aad: [byte], sealed: [byte]) -> [byte]? {
    if (len(sealed) < 16) { return none; };
    let ct = sealed[0:len(sealed) - 16];
    let otk = chacha20_block(key, 0, nonce)[0:32];
    let tag = poly1305(otk, aead_mac_data(aad, ct));
    if (!bytes_eq(tag, sealed[len(sealed) - 16:len(sealed)])) { return none; };
    some(chacha20(key, 1, nonce, ct))
};

// ── AES (FIPS 197) and GCM (SP 800-38D) ──────────────────────────────────

// As K256: built on first use. The 256 bytes were in every binary importing
// crypto, the immediates because _start is a shake root and the table because
// a str literal's bytes go in .rodata whether or not the def reading it
// survives (the rule str.y's header states).
let SBOX: [byte] = [];

def sbox_tab() -> [byte] {
    if (len(SBOX) > 0) { return SBOX; };
    SBOX = unhex("637c777bf26b6fc53001672bfed7ab76ca82c97dfa5947f0add4a2af9ca472c0b7fd9326363ff7cc34a5e5f171d8311504c723c31896059a071280e2eb27b27509832c1a1b6e5aa0523bd6b329e32f8453d100ed20fcb15b6acbbe394a4c58cfd0efaafb434d338545f9027f503c9fa851a3408f929d38f5bcb6da2110fff3d2cd0c13ec5f974417c4a77e3d645d197360814fdc222a908846eeb814de5e0bdbe0323a0a4906245cc2d3ac629195e479e7c8376d8dd54ea96c56f4ea657aae08ba78252e1ca6b4c6e8dd741f4bbd8b8a703eb5664803f60e613557b986c11d9ee1f8981169d98e949b1e87e9ce5528df8ca1890dbfe6426841992d0fb054bb16");
    SBOX
};

// T-tables: a round's SubBytes, ShiftRows and MixColumns as four lookups
// per column (TE0[x] = 2s, s, s, 3s for s = sbox[x]; TE1..3 rotate it).
let TE0: [long] = [];
let TE1: [long] = [];
let TE2: [long] = [];
let TE3: [long] = [];

def xtime(b: long) -> long {
    let r = (b << 1) & 255;
    if ((b & 128) != 0) { r = r ^ 0x1b; };
    r
};

def aes_tables() {
    if (len(TE0) > 0) { return; };
    let sbox = sbox_tab();
    let i = 0;
    while (i < 256) {
        let s: long = sbox[i];
        let s2 = xtime(s);
        let s3 = s2 ^ s;
        let w = (s2 << 24) | (s << 16) | (s << 8) | s3;
        TE0 += w;
        TE1 += rotr32(w, 8);
        TE2 += rotr32(w, 16);
        TE3 += rotr32(w, 24);
        i = i + 1;
    };
};

// The round keys of an AES key (16, 24 or 32 bytes), as 32-bit words.
// Any other length was silently rounded down to a multiple of four and
// its tail ignored -- 15 bytes read as 12, and 8 bytes as eight rounds,
// which is no AES at all -- so it is refused by name (FIPS 197 has
// nothing else).
def aes_key(key: [byte]) -> [long] {
    if (len(key) != 16 && len(key) != 24 && len(key) != 32) {
        arg_error("an AES key must be 16, 24 or 32 bytes, " + tostring(len(key)) + " given");
    };
    aes_tables();
    let sbox = sbox_tab();
    let nk = len(key) / 4;
    let nr = nk + 6;
    let w: [long] = [];
    let i = 0;
    while (i < nk) {
        w += (key[4 * i] << 24) | (key[4 * i + 1] << 16) | (key[4 * i + 2] << 8) | key[4 * i + 3];
        i = i + 1;
    };
    let rcon = 1;
    while (i < 4 * (nr + 1)) {
        let t = w[i - 1];
        if (i % nk == 0) {
            t = (sbox[(t >> 16) & 255] << 24) | (sbox[(t >> 8) & 255] << 16) | (sbox[t & 255] << 8) | sbox[(t >> 24) & 255];
            t = t ^ (rcon << 24);
            rcon = xtime(rcon);
        } else if (nk > 6 && i % nk == 4) {
            t = (sbox[(t >> 24) & 255] << 24) | (sbox[(t >> 16) & 255] << 16) | (sbox[(t >> 8) & 255] << 8) | sbox[t & 255];
        };
        w += w[i - nk] ^ t;
        i = i + 1;
    };
    w
};

// One 16-byte block (b[off..off+16]) encrypted under round keys rk, into
// out (four 32-bit words).
def aes_block(rk: [long], b: [byte], off: long, out: [long; 4]) {
    let sbox = sbox_tab();
    let nr = len(rk) / 4 - 1;
    let s0 = ((b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3]) ^ rk[0];
    let s1 = ((b[off + 4] << 24) | (b[off + 5] << 16) | (b[off + 6] << 8) | b[off + 7]) ^ rk[1];
    let s2 = ((b[off + 8] << 24) | (b[off + 9] << 16) | (b[off + 10] << 8) | b[off + 11]) ^ rk[2];
    let s3 = ((b[off + 12] << 24) | (b[off + 13] << 16) | (b[off + 14] << 8) | b[off + 15]) ^ rk[3];
    let r = 1;
    while (r < nr) {
        let k = 4 * r;
        let t0 = TE0[s0 >> 24] ^ TE1[(s1 >> 16) & 255] ^ TE2[(s2 >> 8) & 255] ^ TE3[s3 & 255] ^ rk[k];
        let t1 = TE0[s1 >> 24] ^ TE1[(s2 >> 16) & 255] ^ TE2[(s3 >> 8) & 255] ^ TE3[s0 & 255] ^ rk[k + 1];
        let t2 = TE0[s2 >> 24] ^ TE1[(s3 >> 16) & 255] ^ TE2[(s0 >> 8) & 255] ^ TE3[s1 & 255] ^ rk[k + 2];
        let t3 = TE0[s3 >> 24] ^ TE1[(s0 >> 16) & 255] ^ TE2[(s1 >> 8) & 255] ^ TE3[s2 & 255] ^ rk[k + 3];
        s0 = t0;
        s1 = t1;
        s2 = t2;
        s3 = t3;
        r = r + 1;
    };
    let k = 4 * nr;
    out[0] = ((sbox[s0 >> 24] << 24) | (sbox[(s1 >> 16) & 255] << 16) | (sbox[(s2 >> 8) & 255] << 8) | sbox[s3 & 255]) ^ rk[k];
    out[1] = ((sbox[s1 >> 24] << 24) | (sbox[(s2 >> 16) & 255] << 16) | (sbox[(s3 >> 8) & 255] << 8) | sbox[s0 & 255]) ^ rk[k + 1];
    out[2] = ((sbox[s2 >> 24] << 24) | (sbox[(s3 >> 16) & 255] << 16) | (sbox[(s0 >> 8) & 255] << 8) | sbox[s1 & 255]) ^ rk[k + 2];
    out[3] = ((sbox[s3 >> 24] << 24) | (sbox[(s0 >> 16) & 255] << 16) | (sbox[(s1 >> 8) & 255] << 8) | sbox[s2 & 255]) ^ rk[k + 3];
};

// One block encrypted, as bytes.
def aes_encrypt(rk: [long], block: [byte]) -> [byte] {
    let o: [long; 4] = [0; 4];
    aes_block(rk, block, 0, o);
    let out: [byte] = [];
    foreach (w in o) { out += be_bytes(w, 4); };
    out
};

// x * y in GF(2^128) as GCM defines it (each a pair of 64-bit halves,
// the first bit the most significant of hi): into z.
def gf128_mul(xh: long, xl: long, yh: long, yl: long, z: [long; 2]) {
    let zh = 0;
    let zl = 0;
    let vh = yh;
    let vl = yl;
    let i = 0;
    while (i < 128) {
        let bit = 0;
        if (i < 64) { bit = (xh >>> (63 - i)) & 1; } else { bit = (xl >>> (127 - i)) & 1; };
        if (bit == 1) {
            zh = zh ^ vh;
            zl = zl ^ vl;
        };
        let lsb = vl & 1;
        vl = (vl >>> 1) | (vh << 63);
        vh = vh >>> 1;
        if (lsb == 1) { vh = vh ^ 0xe100000000000000; };
        i = i + 1;
    };
    z[0] = zh;
    z[1] = zl;
};

def be64(b: [byte], i: long) -> long {
    let v = 0;
    let j = 0;
    while (j < 8) {
        v = (v << 8) | b[i + j];
        j = j + 1;
    };
    v
};

// GHASH_H of data (a multiple of 16 bytes).
def ghash(hh: long, hl: long, data: [byte]) -> [long; 2] {
    let y: [long; 2] = [0; 2];
    let off = 0;
    while (off < len(data)) {
        gf128_mul(y[0] ^ be64(data, off), y[1] ^ be64(data, off + 8), hh, hl, y);
        off = off + 16;
    };
    y
};

// GCTR from counter block j (a copy is advanced), applied to data.
def gctr(rk: [long], j: [byte], data: [byte]) -> [byte] {
    let cb: [byte] = [];
    cb += j;
    let o: [long; 4] = [0; 4];
    let out: [byte] = [];
    let off = 0;
    while (off < len(data)) {
        aes_block(rk, cb, 0, o);
        let i = 0;
        while (i < 16 && off + i < len(data)) {
            out += data[off + i] ^ ((o[i / 4] >> (24 - 8 * (i % 4))) & 255);
            i = i + 1;
        };
        // inc32: the last four bytes as a big-endian counter
        let k = 15;
        let carry = true;
        while (carry && k >= 12) {
            let v = cb[k] + 1;
            cb[k] = v & 255;
            carry = v > 255;
            k = k - 1;
        };
        off = off + 16;
    };
    out
};

// The GCM tag (16 bytes) of ct with aad, for key rk and counter block j0.
def gcm_tag(rk: [long], j0: [byte], aad: [byte], ct: [byte]) -> [byte] {
    let zero: [byte] = [0; 16];
    let hk = aes_encrypt(rk, zero);
    let m: [byte] = [];
    m += aad;
    while (len(m) % 16 != 0) { m += 0; };
    m += ct;
    while (len(m) % 16 != 0) { m += 0; };
    m += be_bytes(len(aad) * 8, 8);
    m += be_bytes(len(ct) * 8, 8);
    let s = ghash(be64(hk, 0), be64(hk, 8), m);
    let sb: [byte] = [];
    sb += be_bytes(s[0], 8);
    sb += be_bytes(s[1], 8);
    let ek = aes_encrypt(rk, j0);
    let tag: [byte] = [];
    let i = 0;
    while (i < 16) {
        tag += sb[i] ^ ek[i];
        i = i + 1;
    };
    tag
};

// The counter blocks for a 12-byte nonce: J0 and inc32(J0).
// SP 800-38D 7.1 defines J0 for a nonce of any length, but only the
// 12-byte one is the plain concatenation below: a longer nonce needs a
// GHASH of it, which this module does not build. Reject such a nonce
// rather than seal with the wrong J0 (two nonces sharing their first
// 16 bytes would then give the same ciphertext *and* the same tag, a
// nonce reuse in all but name).
def gcm_j0(nonce: [byte], last: long) -> [byte] {
    check_nonce("GCM", nonce);
    let j: [byte] = [];
    j += nonce;
    j += [0, 0, 0];
    j += last;
    j
};

// AES-GCM (key 16, 24 or 32 bytes, nonce 12): the ciphertext, then its
// tag.
def gcm_seal(key: [byte], nonce: [byte], aad: [byte], plain: [byte]) -> [byte] {
    let rk = aes_key(key);
    let ct = gctr(rk, gcm_j0(nonce, 2), plain);
    let out: [byte] = [];
    out += ct;
    out += gcm_tag(rk, gcm_j0(nonce, 1), aad, ct);
    out
};

// The plaintext of a sealed message, none when the tag is wrong.
def gcm_open(key: [byte], nonce: [byte], aad: [byte], sealed: [byte]) -> [byte]? {
    if (len(sealed) < 16) { return none; };
    let rk = aes_key(key);
    let ct = sealed[0:len(sealed) - 16];
    let tag = gcm_tag(rk, gcm_j0(nonce, 1), aad, ct);
    if (!bytes_eq(tag, sealed[len(sealed) - 16:len(sealed)])) { return none; };
    some(gctr(rk, gcm_j0(nonce, 2), ct))
};

// ── X25519 (RFC 7748), field arithmetic as TweetNaCl does it ─────────────
// A field element is 16 limbs of 16 bits (more between carries), least
// significant first.

def fe() -> [long] {
    let o: [long] = [];
    let i = 0;
    while (i < 16) {
        o += 0;
        i = i + 1;
    };
    o
};

def fe_copy(o: [long], a: [long]) {
    let i = 0;
    while (i < 16) {
        o[i] = a[i];
        i = i + 1;
    };
};

def car25519(o: [long]) {
    let i = 0;
    while (i < 16) {
        o[i] = o[i] + 65536;
        let c = o[i] >> 16;
        if (i < 15) { o[i + 1] = o[i + 1] + c - 1; } else { o[0] = o[0] + 38 * (c - 1); };
        o[i] = o[i] - (c << 16);
        i = i + 1;
    };
};

// p and q swapped when b is 1.
def sel25519(p: [long], q: [long], b: long) {
    let c = ~(b - 1);
    let i = 0;
    while (i < 16) {
        let t = c & (p[i] ^ q[i]);
        p[i] = p[i] ^ t;
        q[i] = q[i] ^ t;
        i = i + 1;
    };
};

def fe_add(o: [long], a: [long], b: [long]) {
    let i = 0;
    while (i < 16) {
        o[i] = a[i] + b[i];
        i = i + 1;
    };
};

def fe_sub(o: [long], a: [long], b: [long]) {
    let i = 0;
    while (i < 16) {
        o[i] = a[i] - b[i];
        i = i + 1;
    };
};

def fe_mul(o: [long], a: [long], b: [long]) {
    let t: [long; 31] = [0; 31];
    let i = 0;
    while (i < 16) {
        let ai = a[i];
        let j = 0;
        while (j < 16) {
            t[i + j] = t[i + j] + ai * b[j];
            j = j + 1;
        };
        i = i + 1;
    };
    i = 0;
    while (i < 15) {
        t[i] = t[i] + 38 * t[i + 16];
        i = i + 1;
    };
    i = 0;
    while (i < 16) {
        o[i] = t[i];
        i = i + 1;
    };
    car25519(o);
    car25519(o);
};

def fe_inv(o: [long], x: [long]) {
    let c = fe();
    fe_copy(c, x);
    let a = 253;
    while (a >= 0) {
        fe_mul(c, c, c);
        if (a != 2 && a != 4) { fe_mul(c, c, x); };
        a = a - 1;
    };
    fe_copy(o, c);
};

def unpack25519(n: [byte]) -> [long] {
    let o = fe();
    let i = 0;
    while (i < 16) {
        o[i] = n[2 * i] + (n[2 * i + 1] << 8);
        i = i + 1;
    };
    o[15] = o[15] & 0x7fff;
    o
};

def pack25519(n: [long]) -> [byte] {
    let t = fe();
    fe_copy(t, n);
    car25519(t);
    car25519(t);
    car25519(t);
    let m = fe();
    let j = 0;
    while (j < 2) {
        m[0] = t[0] - 0xffed;
        let i = 1;
        while (i < 15) {
            m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1);
            m[i - 1] = m[i - 1] & 0xffff;
            i = i + 1;
        };
        m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1);
        let b = (m[15] >> 16) & 1;
        m[14] = m[14] & 0xffff;
        sel25519(t, m, 1 - b);
        j = j + 1;
    };
    let out: [byte] = [];
    let i = 0;
    while (i < 16) {
        out += t[i] & 255;
        out += t[i] >> 8;
        i = i + 1;
    };
    out
};

// X25519(k, u): the scalar k (32 bytes) times the point u (32 bytes).
// A u longer than 32 bytes would be used truncated, so both lengths are
// refused by name. And RFC 8446 7.4.2 says a shared secret of all zeros
// must abort the handshake: the seven other low-order points of RFC 7748
// 6.1 (0, 1, p-1, p, p+1 and two more) all give it, and a peer that
// offers one would otherwise learn everything sent under that key --
// which is none at all, so the key exchange decides nothing.
def x25519(k: [byte], u: [byte]) -> [byte] {
    if (len(k) != 32 || len(u) != 32) {
        arg_error("X25519 takes a 32-byte scalar and a 32-byte point, " + tostring(len(k)) + " and " + tostring(len(u)) + " given");
    };
    let z: [byte] = [];
    z += k;
    z[31] = (k[31] & 127) | 64;
    z[0] = z[0] & 248;
    let x = unpack25519(u);
    let a = fe();
    let b = fe();
    let c = fe();
    let d = fe();
    let e = fe();
    let f = fe();
    let c121665 = fe();
    c121665[0] = 0xdb41;
    c121665[1] = 1;
    fe_copy(b, x);
    a[0] = 1;
    d[0] = 1;
    let i = 254;
    while (i >= 0) {
        let r = (z[i >> 3] >> (i & 7)) & 1;
        sel25519(a, b, r);
        sel25519(c, d, r);
        fe_add(e, a, c);
        fe_sub(a, a, c);
        fe_add(c, b, d);
        fe_sub(b, b, d);
        fe_mul(d, e, e);
        fe_mul(f, a, a);
        fe_mul(a, c, a);
        fe_mul(c, b, e);
        fe_add(e, a, c);
        fe_sub(a, a, c);
        fe_mul(b, a, a);
        fe_sub(c, d, f);
        fe_mul(a, c, c121665);
        fe_add(a, a, d);
        fe_mul(c, c, a);
        fe_mul(a, d, f);
        fe_mul(d, b, x);
        fe_mul(b, e, e);
        sel25519(a, b, r);
        sel25519(c, d, r);
        i = i - 1;
    };
    fe_inv(c, c);
    fe_mul(a, a, c);
    let s = pack25519(a);
    if (is_zero(s)) {
        arg_error("an X25519 point of low order: the shared secret is all zeros");
    };
    s
};

// The X25519 base point, u = 9.
def x25519_base(k: [byte]) -> [byte] {
    let u: [byte] = [9];
    while (len(u) < 32) { u += 0; };
    x25519(k, u)
};

// ── big naturals and Montgomery arithmetic ───────────────────────────────
// A natural number is [long] limbs of 30 bits, least significant first; the
// operations below keep a fixed limb count k (the modulus's).

let BN_MASK = 0x3fffffff;

// Limbs enough for nbytes bytes.
def bn_limbs(nbytes: long) -> long {(8 * nbytes + 29) / 30 };

def bn_zero(k: long) -> [long] {
    let o: [long] = [];
    let i = 0;
    while (i < k) {
        o += 0;
        i = i + 1;
    };
    o
};

// The big-endian bytes b as k limbs (bits past k limbs are dropped).
def bn_from_bytes(b: [byte], k: long) -> [long] {
    let o = bn_zero(k);
    let bit = 0;
    let i = len(b) - 1;
    while (i >= 0) {
        let limb = bit / 30;
        let sh = bit % 30;
        if (limb < k) { o[limb] = o[limb] | ((b[i] << sh) & BN_MASK); };
        if (sh > 22 && limb + 1 < k) { o[limb + 1] = o[limb + 1] | (b[i] >> (30 - sh)); };
        bit = bit + 8;
        i = i - 1;
    };
    o
};

// a as n big-endian bytes.
def bn_to_bytes(a: [long], n: long) -> [byte] {
    let out: [byte] = [];
    let i = n - 1;
    while (i >= 0) {
        let bit = 8 * i;
        let limb = bit / 30;
        let sh = bit % 30;
        let v = 0;
        if (limb < len(a)) { v = a[limb] >> sh; };
        if (sh > 22 && limb + 1 < len(a)) { v = v | (a[limb + 1] << (30 - sh)); };
        out += v & 255;
        i = i - 1;
    };
    out
};

// -1, 0 or 1 as a < b, a == b, a > b (equal limb counts).
def bn_cmp(a: [long], b: [long]) -> long {
    let i = len(a) - 1;
    while (i >= 0) {
        if (a[i] < b[i]) { return -1; };
        if (a[i] > b[i]) { return 1; };
        i = i - 1;
    };
    0
};

def bn_is_zero(a: [long]) -> bool {
    let z = true;
    foreach (x in a) {
        if (x != 0) { z = false; };
    };
    z
};

// a - b (a >= b).
def bn_sub(a: [long], b: [long]) -> [long] {
    let o = bn_zero(len(a));
    let borrow = 0;
    let i = 0;
    while (i < len(a)) {
        let x = a[i] - b[i] - borrow;
        borrow = 0;
        if (x < 0) {
            x = x + (1 << 30);
            borrow = 1;
        };
        o[i] = x;
        i = i + 1;
    };
    o
};

// a + b, and whether it carried out of the top limb.
def bn_add_c(a: [long], b: [long], o: [long]) -> long {
    let carry = 0;
    let i = 0;
    while (i < len(a)) {
        let x = a[i] + b[i] + carry;
        o[i] = x & BN_MASK;
        carry = x >> 30;
        i = i + 1;
    };
    carry
};

// The bit length of a.
def bn_bits(a: [long]) -> long {
    let i = len(a) - 1;
    while (i >= 0 && a[i] == 0) { i = i - 1; };
    if (i < 0) { return 0; };
    let n = 30 * i;
    let v = a[i];
    while (v > 0) {
        n = n + 1;
        v = v >> 1;
    };
    n
};

// x = 2x mod n in place (x below n).
def bn_dbl_mod(x: [long], n: [long]) {
    let k = len(x);
    let carry = 0;
    let i = 0;
    while (i < k) {
        let v = x[i] * 2 + carry;
        x[i] = v & BN_MASK;
        carry = v >> 30;
        i = i + 1;
    };
    if (carry != 0 || bn_cmp(x, n) >= 0) {
        // x - n, the borrow out of the top limb dropped: the wrap
        let borrow = 0;
        i = 0;
        while (i < k) {
            let v = x[i] - n[i] - borrow;
            borrow = 0;
            if (v < 0) {
                v = v + (1 << 30);
                borrow = 1;
            };
            x[i] = v;
            i = i + 1;
        };
    };
};

// A Montgomery modulus (odd): R = 2^(30k); n0 = -n^-1 mod 2^30; r2 =
// R^2 mod n; one = R mod n, the Montgomery form of 1.
type Mont = { n: [long], k: long, n0: long, r2: [long], one: [long] };

def mont_new(nb: [byte]) -> Mont {
    let k = bn_limbs(len(nb));
    let n = bn_from_bytes(nb, k);
    // n0: Newton's iteration for n[0]^-1 mod 2^30, negated
    let inv = 1;
    let i = 0;
    while (i < 5) {
        inv = (inv * (2 - n[0] * inv)) & BN_MASK;
        i = i + 1;
    };
    let n0 = ((1 << 30) - inv) & BN_MASK;
    // R^2 mod n: 1 doubled 2 * 30k times, n taken away when it reaches n
    let x = bn_zero(k);
    x[0] = 1;
    let one: [long] = [];
    let steps = 60 * k;
    i = 0;
    while (i < steps) {
        bn_dbl_mod(x, n);
        i = i + 1;
        if (i == 30 * k) { one = x[0:k]; };
    };
    { n: n, k: k, n0: n0, r2: x, one: one }
};

// a * b / R mod n (CIOS), a and b below n.
def mont_mul(m: Mont, a: [long], b: [long]) -> [long] {
    let k = m.k;
    let n = m.n;
    let t: [long] = [];
    let i = 0;
    while (i < k + 2) {
        t += 0;
        i = i + 1;
    };
    i = 0;
    while (i < k) {
        let ai = a[i];
        let c = 0;
        let j = 0;
        while (j < k) {
            let x = t[j] + ai * b[j] + c;
            t[j] = x & BN_MASK;
            c = x >> 30;
            j = j + 1;
        };
        let x = t[k] + c;
        t[k] = x & BN_MASK;
        t[k + 1] = x >> 30;
        let mm = (t[0] * m.n0) & BN_MASK;
        x = t[0] + mm * n[0];
        c = x >> 30;
        j = 1;
        while (j < k) {
            x = t[j] + mm * n[j] + c;
            t[j - 1] = x & BN_MASK;
            c = x >> 30;
            j = j + 1;
        };
        x = t[k] + c;
        t[k - 1] = x & BN_MASK;
        c = x >> 30;
        t[k] = t[k + 1] + c;
        t[k + 1] = 0;
        i = i + 1;
    };
    let o = t[0:k];
    if (t[k] != 0 || bn_cmp(o, n) >= 0) { o = bn_sub(o, n); };
    o
};

def mont_in(m: Mont, a: [long]) -> [long] { mont_mul(m, a, m.r2) };

def mont_out(m: Mont, a: [long]) -> [long] {
    let one = bn_zero(m.k);
    one[0] = 1;
    mont_mul(m, a, one)
};

// a^e mod n, a and the result in Montgomery form; e big-endian bytes.
def mont_pow(m: Mont, a: [long], e: [byte]) -> [long] {
    let x = m.one;
    foreach (eb in e) {
        let bit = 7;
        while (bit >= 0) {
            x = mont_mul(m, x, x);
            if (((eb >> bit) & 1) == 1) { x = mont_mul(m, x, a); };
            bit = bit - 1;
        };
    };
    x
};

def mod_add(m: Mont, a: [long], b: [long]) -> [long] {
    let o = bn_zero(m.k);
    let carry = bn_add_c(a, b, o);
    if (carry != 0 || bn_cmp(o, m.n) >= 0) { o = bn_sub(o, m.n); };
    o
};

def mod_sub(m: Mont, a: [long], b: [long]) -> [long] {
    if (bn_cmp(a, b) >= 0) { bn_sub(a, b) } else {
        let o = bn_zero(m.k);
        bn_add_c(a, m.n, o);
        bn_sub(o, b)
    }
};

// n - 2 as big-endian bytes (for an inverse by Fermat).
def minus2_bytes(m: Mont, nbytes: long) -> [byte] {
    let two = bn_zero(m.k);
    two[0] = 2;
    bn_to_bytes(bn_sub(m.n, two), nbytes)
};

// ── RSA signatures (RFC 8017): PKCS #1 v1.5 and PSS ─────────────────────

// sig^e mod n as len(n) bytes; [] for a signature of another length or
// not below n. n and e big-endian, n with no leading zero byte.
def rsa_public(nb: [byte], eb: [byte], sig: [byte]) -> [byte] {
    let none_b: [byte] = [];
    if (len(sig) != len(nb) || len(nb) == 0 || (nb[len(nb) - 1] & 1) == 0) { return none_b; };
    let m = mont_new(nb);
    let s = bn_from_bytes(sig, m.k);
    if (bn_cmp(s, m.n) >= 0) { return none_b; };
    bn_to_bytes(mont_out(m, mont_pow(m, mont_in(m, s), eb)), len(nb))
};

// The DigestInfo prefix (RFC 8017 9.2) of a hash named by its length.
def digest_info(hlen: long) -> [byte] {
    if (hlen == 32) { unhex("3031300d060960864801650304020105000420") }
    else if (hlen == 48) { unhex("3041300d060960864801650304020205000430") }
    else { unhex("3051300d060960864801650304020305000440") }
};

// sig is n's PKCS #1 v1.5 signature of a message with this digest
// (SHA-256, -384 or -512, told apart by its length).
def rsa_verify_pkcs1(nb: [byte], eb: [byte], digest: [byte], sig: [byte]) -> bool {
    let em = rsa_public(strip0(nb), eb, sig);
    let t: [byte] = [];
    t += digest_info(len(digest));
    t += digest;
    let k = len(em);
    if (k < len(t) + 11) { return false; };
    let want: [byte] = [0, 1];
    while (len(want) < k - len(t) - 1) { want += 255; };
    want += 0;
    want += t;
    bytes_eq(em, want)
};

// MGF1 (RFC 8017 B.2.1) over hash h: n bytes from seed.
def mgf1(h: Hash, seed: [byte], n: long) -> [byte] {
    let out: [byte] = [];
    let c = 0;
    while (len(out) < n) {
        let m: [byte] = [];
        m += seed;
        m += be_bytes(c, 4);
        out += h.f(m);
        c = c + 1;
    };
    out[0:n]
};

// sig is n's RSASSA-PSS signature (MGF1 and salt length from hash h) of
// a message with digest mhash.
def rsa_verify_pss(nb: [byte], eb: [byte], h: Hash, mhash: [byte], sig: [byte]) -> bool {
    let n = strip0(nb);
    let em0 = rsa_public(n, eb, sig);
    if (len(em0) == 0) { return false; };
    let k = bn_limbs(len(n));
    let embits = bn_bits(bn_from_bytes(n, k)) - 1;
    let emlen = (embits + 7) / 8;
    let em = em0;
    if (emlen < len(em0)) {
        if (em0[0] != 0) { return false; };
        em = em0[1:len(em0)];
    };
    let hl = h.size;
    let sl = h.size;
    if (emlen < hl + sl + 2 || em[emlen - 1] != 0xbc) { return false; };
    let masked = em[0:emlen - hl - 1];
    let hh = em[emlen - hl - 1:emlen - 1];
    let top = 8 * emlen - embits;
    let topmask = 255 >> top;
    if ((masked[0] & ~topmask) != 0) { return false; };
    let mask = mgf1(h, hh, emlen - hl - 1);
    let db: [byte] = [];
    let i = 0;
    while (i < len(masked)) {
        db += masked[i] ^ mask[i];
        i = i + 1;
    };
    db[0] = db[0] & topmask;
    let ps = emlen - hl - sl - 2;
    i = 0;
    while (i < ps) {
        if (db[i] != 0) { return false; };
        i = i + 1;
    };
    if (db[ps] != 1) { return false; };
    let mp: [byte] = [0, 0, 0, 0, 0, 0, 0, 0];
    mp += mhash;
    mp += db[len(db) - sl:len(db)];
    bytes_eq(h.f(mp), hh)
};

// b without its leading zero bytes (DER integers carry one for the sign).
def strip0(b: [byte]) -> [byte] {
    let i = 0;
    while (i < len(b) - 1 && b[i] == 0) { i = i + 1; };
    b[i:len(b)]
};

// ── ECDSA (FIPS 186-4) over P-256 and P-384 ─────────────────────────────
// Points in Jacobian coordinates (X/Z^2, Y/Z^3), each a field element in
// Montgomery form; Z = 0 is the point at infinity. a = -3 on both curves.

type Curve = { p: Mont, n: Mont, b: [long], gx: [long], gy: [long], size: long };
type Pt = { x: [long], y: [long], z: [long] };

def curve(p: str, n: str, b: str, gx: str, gy: str) -> Curve {
    let pm = mont_new(unhex(p));
    let nm = mont_new(unhex(n));
    let k = pm.k;
    {
        p: pm, n: nm, size: len(p) / 2,
        b: mont_in(pm, bn_from_bytes(unhex(b), k)),
        gx: mont_in(pm, bn_from_bytes(unhex(gx), k)),
        gy: mont_in(pm, bn_from_bytes(unhex(gy), k))
    }
};

def p256() -> Curve {
    curve("ffffffff00000001000000000000000000000000ffffffffffffffffffffffff",
        "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551",
        "5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b",
        "6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296",
        "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5")
};

def p384() -> Curve {
    curve("fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffeffffffff0000000000000000ffffffff",
        "ffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973",
        "b3312fa7e23ee7e4988e056be3f82d19181d9c6efe8141120314088f5013875ac656398d8a2ed19d2a85c8edd3ec2aef",
        "aa87ca22be8b05378eb1c71ef320ad746e1d3b628ba79b9859f741e082542a385502f25dbf55296c3a545e3872760ab7",
        "3617de4a96262c6f5d9e98bf9292dc29f8f41dbd289a147ce9da3113b5f0b8c00a60b1ce1d7e819d7a431d7c90ea0e5f")
};

def pt_double(c: Curve, a: Pt) -> Pt {
    let f = c.p;
    if (bn_is_zero(a.z)) { return a; };
    let delta = mont_mul(f, a.z, a.z);
    let gamma = mont_mul(f, a.y, a.y);
    let beta = mont_mul(f, a.x, gamma);
    let t = mont_mul(f, mod_sub(f, a.x, delta), mod_add(f, a.x, delta));
    let alpha = mod_add(f, mod_add(f, t, t), t);
    let beta4 = mod_add(f, beta, beta);
    beta4 = mod_add(f, beta4, beta4);
    let x3 = mod_sub(f, mont_mul(f, alpha, alpha), mod_add(f, beta4, beta4));
    let yz = mod_add(f, a.y, a.z);
    let z3 = mod_sub(f, mod_sub(f, mont_mul(f, yz, yz), gamma), delta);
    let g2 = mont_mul(f, gamma, gamma);
    let g8 = mod_add(f, g2, g2);
    g8 = mod_add(f, g8, g8);
    g8 = mod_add(f, g8, g8);
    let y3 = mod_sub(f, mont_mul(f, alpha, mod_sub(f, beta4, x3)), g8);
    { x: x3, y: y3, z: z3 }
};

def pt_add(c: Curve, a: Pt, b: Pt) -> Pt {
    let f = c.p;
    if (bn_is_zero(a.z)) { return b; };
    if (bn_is_zero(b.z)) { return a; };
    let z1z1 = mont_mul(f, a.z, a.z);
    let z2z2 = mont_mul(f, b.z, b.z);
    let u1 = mont_mul(f, a.x, z2z2);
    let u2 = mont_mul(f, b.x, z1z1);
    let s1 = mont_mul(f, a.y, mont_mul(f, b.z, z2z2));
    let s2 = mont_mul(f, b.y, mont_mul(f, a.z, z1z1));
    let h = mod_sub(f, u2, u1);
    let r = mod_sub(f, s2, s1);
    if (bn_is_zero(h)) {
        if (bn_is_zero(r)) { return pt_double(c, a); };
        return { x: f.one, y: f.one, z: bn_zero(f.k) };
    };
    r = mod_add(f, r, r);
    let h2 = mod_add(f, h, h);
    let i = mont_mul(f, h2, h2);
    let j = mont_mul(f, h, i);
    let v = mont_mul(f, u1, i);
    let x3 = mod_sub(f, mod_sub(f, mont_mul(f, r, r), j), mod_add(f, v, v));
    let s1j = mont_mul(f, s1, j);
    let y3 = mod_sub(f, mont_mul(f, r, mod_sub(f, v, x3)), mod_add(f, s1j, s1j));
    let zz = mod_add(f, a.z, b.z);
    let z3 = mont_mul(f, mod_sub(f, mod_sub(f, mont_mul(f, zz, zz), z1z1), z2z2), h);
    { x: x3, y: y3, z: z3 }
};

// The bit of a big-endian byte string, counted from the most significant.
def bit_at(b: [byte], i: long) -> long {(b[i / 8] >> (7 - i % 8)) & 1 };

// x lies on the curve with some y: y^2 = x^3 - 3x + b (Montgomery form).
def on_curve(c: Curve, x: [long], y: [long]) -> bool {
    let f = c.p;
    let x3 = mont_mul(f, mont_mul(f, x, x), x);
    let three_x = mod_add(f, mod_add(f, x, x), x);
    let rhs = mod_add(f, mod_sub(f, x3, three_x), c.b);
    bn_cmp(mont_mul(f, y, y), rhs) == 0
};

// The ECDSA signature (r, s, big-endian) of digest by the public key
// (qx, qy) on curve c holds.
def ecdsa_verify(c: Curve, qx: [byte], qy: [byte], digest: [byte], rb: [byte], sb: [byte]) -> bool {
    let nm = c.n;
    let f = c.p;
    let r0 = strip0(rb);
    let s0 = strip0(sb);
    if (len(r0) > c.size || len(s0) > c.size || len(qx) != c.size || len(qy) != c.size) { return false; };
    let r = bn_from_bytes(r0, nm.k);
    let s = bn_from_bytes(s0, nm.k);
    if (bn_is_zero(r) || bn_is_zero(s) || bn_cmp(r, nm.n) >= 0 || bn_cmp(s, nm.n) >= 0) { return false; };
    let pxn = bn_from_bytes(qx, f.k);
    let pyn = bn_from_bytes(qy, f.k);
    if (bn_cmp(pxn, f.n) >= 0 || bn_cmp(pyn, f.n) >= 0) { return false; };
    let qxm = mont_in(f, pxn);
    let qym = mont_in(f, pyn);
    if (!on_curve(c, qxm, qym)) { return false; };
    // z: the digest's leftmost bits as many as n has, reduced mod n
    let d = digest;
    if (len(d) > c.size) { d = d[0:c.size]; };
    let z = bn_from_bytes(d, nm.k);
    if (bn_cmp(z, nm.n) >= 0) { z = bn_sub(z, nm.n); };
    let w = mont_pow(nm, mont_in(nm, s), minus2_bytes(nm, c.size));
    let u1 = mont_out(nm, mont_mul(nm, mont_in(nm, z), w));
    let u2 = mont_out(nm, mont_mul(nm, mont_in(nm, r), w));
    let u1b = bn_to_bytes(u1, c.size);
    let u2b = bn_to_bytes(u2, c.size);
    let g: Pt = { x: c.gx, y: c.gy, z: f.one };
    let q: Pt = { x: qxm, y: qym, z: f.one };
    let gq = pt_add(c, g, q);
    let acc: Pt = { x: f.one, y: f.one, z: bn_zero(f.k) };
    let i = 0;
    while (i < 8 * c.size) {
        acc = pt_double(c, acc);
        let b1 = bit_at(u1b, i);
        let b2 = bit_at(u2b, i);
        if (b1 == 1 && b2 == 1) { acc = pt_add(c, acc, gq); }
        else if (b1 == 1) { acc = pt_add(c, acc, g); }
        else if (b2 == 1) { acc = pt_add(c, acc, q); };
        i = i + 1;
    };
    if (bn_is_zero(acc.z)) { return false; };
    // x = X / Z^2, then mod n
    let zinv = mont_pow(f, acc.z, minus2_bytes(f, c.size));
    let x = mont_out(f, mont_mul(f, acc.x, mont_mul(f, zinv, zinv)));
    let xn = bn_from_bytes(bn_to_bytes(x, c.size), nm.k);
    if (bn_cmp(xn, nm.n) >= 0) { xn = bn_sub(xn, nm.n); };
    bn_cmp(xn, r) == 0
};

// ── big integers and primality ─────────────────────────────────────────
// The language's bigint type is the arithmetic core (native helpers under
// std/rt.y); this section exposes the byte bridges and the prime utilities a
// caller actually reaches for. A bigint has no fixed width, so N is a byte
// count and the top byte is kept non-zero for random primes.

// Big-endian bytes -> non-negative bigint.
def bigint_from_bytes_be(b: [byte]) -> bigint {
    let x: bigint = 0n;
    let i = 0;
    while (i < len(b)) {
        x = x * 256n + b[i];
        i = i + 1;
    };
    x
};

// The low n big-endian bytes of x (zero-padded on the left).
def bigint_to_bytes_be(x: bigint, n: long) -> [byte] {
    let out: [byte] = [];
    let i = 0;
    while (i < n) {
        out += 0;
        i = i + 1;
    };
    let y = x;
    if (y < 0n) { y = 0n - y; };
    i = n - 1;
    while (i >= 0) {
        let rem: bigint = y % 256n;
        out[i] = tolong(rem) !;
        y = y / 256n;
        i = i - 1;
    };
    if (x < 0n) { return out; };
    out
};

def bigint_byte_len(x: bigint) -> long {
    let y = x;
    if (y < 0n) { y = 0n - y; };
    let n = 0;
    while (y > 0n) {
        y = y / 256n;
        n = n + 1;
    };
    n
};

// n random bytes as a non-negative bigint.
def random_bigint(n: long) -> bigint {
    bigint_from_bytes_be(random_bytes(n))
};

// a*b mod m with a non-negative exponent; m must be positive.
def bigint_mod_pow(b: bigint, e: bigint, m: bigint) -> bigint {
    if (m == 1n) { return 0n; };
    let result: bigint = 1n;
    let base = b % m;
    if (base < 0n) { base = base + m; };
    let exp = e;
    while (exp > 0n) {
        if (exp % 2n == 1n) { result = (result * base) % m; };
        base = (base * base) % m;
        exp = exp / 2n;
    };
    result
};

// The names callers coming from the long helpers in std/math.y expect.
def pow_mod(b: bigint, e: bigint, m: bigint) -> bigint {
    bigint_mod_pow(b, e, m)
};

def mod_pow(b: bigint, e: bigint, m: bigint) -> bigint {
    bigint_mod_pow(b, e, m)
};

def gcd(a: bigint, b: bigint) -> bigint {
    bigint_gcd(a, b)
};

def bigint_gcd(a: bigint, b: bigint) -> bigint {
    let x = a;
    if (x < 0n) { x = 0n - x; };
    let y = b;
    if (y < 0n) { y = 0n - y; };
    while (y > 0n) {
        let r = x % y;
        x = y;
        y = r;
    };
    x
};

// Modular inverse of a modulo m, or 0 when it does not exist.
def bigint_inv_mod(a: bigint, m: bigint) -> bigint {
    if (m == 1n) { return 0n; };
    let aa = a % m;
    if (aa < 0n) { aa = aa + m; };
    let old_r = aa;
    let r = m;
    let old_s: bigint = 1n;
    let s: bigint = 0n;
    while (r != 0n) {
        let q = old_r / r;
        let tr = old_r - q * r;
        old_r = r;
        r = tr;
        let ts = old_s - q * s;
        old_s = s;
        s = ts;
    };
    if (old_r != 1n) { return 0n; };
    let inv = old_s % m;
    if (inv < 0n) { inv = inv + m; };
    inv
};

def inv_mod(a: bigint, m: bigint) -> bigint {
    bigint_inv_mod(a, m)
};

// Miller-Rabin, with 16 random bases. Small prime divisors are taken out
// first; the result is deterministic for the small cases and has a
// negligible error probability past them.
def is_prime(n: bigint) -> bool {
    if (n < 2n) { return false; };
    if (n == 2n) { return true; };
    if (n == 3n) { return true; };
    if (n % 2n == 0n) { return false; };
    let small: [long] = [3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43];
    let si = 0;
    while (si < len(small)) {
        let p = small[si];
        if (n == p) { return true; };
        if (n % p == 0n) { return false; };
        si = si + 1;
    };
    let d = n - 1n;
    let s = 0;
    while (d % 2n == 0n) {
        d = d / 2n;
        s = s + 1;
    };
    let nbytes = bigint_byte_len(n);
    if (nbytes < 1) { nbytes = 1; };
    let rounds = 16;
    let i = 0;
    while (i < rounds) {
        let a = random_bigint(nbytes) % (n - 3n) + 2n;
        let x = bigint_mod_pow(a, d, n);
        if (x != 1n && x != n - 1n) {
            let j = 1;
            let ok = false;
            while (j < s) {
                x = (x * x) % n;
                if (x == n - 1n) {
                    ok = true;
                    j = s;
                } else {
                    j = j + 1;
                };
            };
            if (!ok) { return false; };
        };
        i = i + 1;
    };
    true
};

def prime_test(n: bigint) -> bool {
    is_prime(n)
};

def next_prime(n: bigint) -> bigint {
    if (n < 2n) { return 2n; };
    let p = n + 1n;
    if (p % 2n == 0n) { p = p + 1n; };
    while (!is_prime(p)) {
        p = p + 2n;
    };
    p
};

// A prime with exactly n random bytes (top and bottom bits set).
def random_prime(nbytes: long) -> bigint {
    if (nbytes < 1) {
        arg_error("a random prime needs at least one byte");
    };
    while (true) {
        let b = random_bytes(nbytes);
        b[0] = b[0] | 128;
        b[nbytes - 1] = b[nbytes - 1] | 1;
        let p = bigint_from_bytes_be(b);
        if (is_prime(p)) { return p; };
    };
    0n
};

// The prime's big-endian bytes, for protocols that want the raw value.
def random_prime_bytes(nbytes: long) -> [byte] {
    bigint_to_bytes_be(random_prime(nbytes), nbytes)
};

// A spelling for callers that want to be explicit about the result type.
def random_prime_bigint(nbytes: long) -> bigint {
    random_prime(nbytes)
};

def rand_prime(nbytes: long) -> bigint {
    random_prime(nbytes)
};

def random_prime_bits(bits: long) -> bigint {
    if (bits < 2) {
        arg_error("a random prime needs at least two bits");
    };
    random_prime((bits + 7) / 8)
};

def prime_bytes(nbytes: long) -> [byte] {
    bigint_to_bytes_be(random_prime(nbytes), nbytes)
};

export { hex, unhex, random_bytes, bytes_eq, be_bytes, le_bytes, sha256, sha384, sha512, hash_sha256, hash_sha384, hmac, hkdf_extract, hkdf_expand, chacha20, poly1305, chacha_seal, chacha_open, aes_key, aes_encrypt, gcm_seal, gcm_open, x25519, x25519_base, rsa_verify_pkcs1, rsa_verify_pss, p256, p384, ecdsa_verify, bigint_from_bytes_be, bigint_to_bytes_be, bigint_byte_len, random_bigint, bigint_mod_pow, pow_mod, bigint_gcd, bigint_inv_mod, inv_mod, is_prime, prime_test, next_prime, random_prime, random_prime_bytes, random_prime_bigint, rand_prime, random_prime_bits, prime_bytes, mod_pow, gcd };
