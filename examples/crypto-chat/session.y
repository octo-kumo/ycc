// session.y -- the cryptography: X25519 key agreement, an HKDF-SHA256 key
// schedule, and thin counted wrappers over ChaCha20-Poly1305.
//
// Everything real is in std/crypto.y (`x25519_base`, `x25519`, `hkdf_extract`,
// `hkdf_expand`, `chacha_seal`, `chacha_open`).  What this module adds is the
// *protocol* around them, which std deliberately leaves to the caller:
//
//   * a *directional* key schedule, so a->b and b->a keys are different and a
//     message sealed for one direction cannot be read in the other;
//   * a per-message nonce that is a function of the sequence number, so a
//     message never repeats a (key, nonce) pair;
//   * an AAD that names the conversation, the sequence number and the
//     direction, so a frame cannot be replayed at another position or in
//     another conversation;
//   * counters, so the transcript can state what was computed rather than imply
//     it.
//
// ── nonce construction ─────────────────────────────────────────────────────
//
// nonce = base[0..8] || le32(seq)                        -- 12 bytes, as
// RFC 8439 fixes it.  Because the two directions already have different keys, a
// counter alone is a safe nonce source (that is the whole reason the key
// schedule is directional); a random 8-byte base per session is mixed in
// anyway, and that is what `--live` takes from getrandom(2).

import crypto;

const TAGB = "crypto-chat/v1";

// What one party ends up holding after the handshake.
type Keys = {
    sk: [byte],      // this side's X25519 private scalar, 32 B
    pk: [byte],      // this side's X25519 public point, 32 B
    peer: [byte],    // the peer's X25519 public point, 32 B
    shared: [byte],  // the raw X25519 shared secret, 32 B
    tx: [byte],      // this side's send key, 32 B
    rx: [byte]       // this side's receive key, 32 B
};

// Counters for this process: one fixed cell, read through `count()`.
//   0 x25519 scalar multiplications
//   1 HKDF extracts          2 HKDF expands
//   3 explicit sha256 calls  4 chacha_seal calls   5 chacha_open calls
//   6 opens accepted         7 opens rejected
//   8 plaintext bytes sealed 9 sealed bytes produced
let C: [long; 10] = [0; 10];

def count(i: long) -> long { C[i] };

// The HKDF-SHA256 expand step for one direction.  The salt binds the label, so
// two sessions with the same shared secret and different labels still differ.
def derive(shared: [byte], label: str, info: str) -> [byte] {
    let h = crypto.hash_sha256();
    let salt = crypto.sha256(bytes(TAGB + " salt|" + label));
    C[3] = C[3] + 1;
    let prk = crypto.hkdf_extract(h, salt, shared);
    C[1] = C[1] + 1;
    let ok = crypto.hkdf_expand(h, prk, bytes(info), 32);
    C[2] = C[2] + 1;
    ok
};

// Agree.  `sk` is this side's scalar, `peer` the point the other side sent, and
// `dir` is *this side's send direction*: 0 for a->b, 1 for b->a.  The direction
// has to be a parameter, because the key schedule is directional -- if both
// sides derived "tx" from the same label, each would seal with the a->b key and
// the receiver would hold the b->a one, and every message would be refused.
def agree(sk: [byte], peer: [byte], label: str, dir: long) -> Keys {
    let pk = crypto.x25519_base(sk);
    C[0] = C[0] + 1;
    let shared = crypto.x25519(sk, peer);
    C[0] = C[0] + 1;
    let k: Keys = {
        sk: sk, pk: pk, peer: peer, shared: shared,
        tx: derive(shared, label, TAGB + " key " + dir_str(dir)),
        rx: derive(shared, label, TAGB + " key " + dir_str(1 - dir))
    };
    k
};

// The session's 8-byte nonce prefix.  It comes out of the key schedule, so both
// sides compute the same value from the shared secret without exchanging it --
// which matters, because a nonce prefix the receiver cannot rebuild makes every
// message unopenable.  Under --live the shared secret is already getrandom(2)
// output, so the prefix is too.  A real protocol would additionally prepend 4
// random bytes carried in the handshake; see README, "What this does not do".
def nonce_base(shared: [byte], label: str) -> [byte] {
    derive(shared, label, TAGB + " nonce")[0:8]
};

// The public point alone, which is all that crosses a pipe before a session key
// exists.
def public_of(sk: [byte]) -> [byte] {
    let pk = crypto.x25519_base(sk);
    C[0] = C[0] + 1;
    pk
};

// ── nonce and AAD ───────────────────────────────────────────────────────

def nonce_of(base: [byte], seq: long) -> [byte] {
    let n: [byte] = [];
    n += base;
    n += crypto.le_bytes(seq, 4);
    n
};

// The ADID.  It names the conversation label, the sequence number and the
// direction, and ChaCha20-Poly1305 authenticates it: a frame that arrives at
// the wrong position, in the wrong direction, or in a different conversation
// fails the tag check.
def aad_of(label: str, seq: long, dir: long) -> [byte] {
    bytes(TAGB + "|" + label + "|" + tostring(seq) + "|" + dir_str(dir))
};

// dir 0 is a->b, dir 1 is b->a.
def dir_str(dir: long) -> str {
    if (dir == 0) { "a->b" } else { "b->a" }
};

// ── the AEAD, counted ───────────────────────────────────────────────────

def seal(key: [byte], nonce: [byte], aad: [byte], plain: [byte]) -> [byte] {
    C[4] = C[4] + 1;
    C[8] = C[8] + len(plain);
    let s = crypto.chacha_seal(key, nonce, aad, plain);
    C[9] = C[9] + len(s);
    s
};

// none when the Poly1305 tag does not verify.  A wrong key, a wrong nonce, a
// wrong AAD and an altered ciphertext are all the *same* failure here, and that
// is the point: the AEAD never says which.
def open(key: [byte], nonce: [byte], aad: [byte], sealed: [byte]) -> [byte]? {
    C[5] = C[5] + 1;
    let p = crypto.chacha_open(key, nonce, aad, sealed);
    if (p == none) { C[7] = C[7] + 1; };
    if (p != none) { C[6] = C[6] + 1; };
    p
};

// ── reproducible key material ────────────────────────────────────────────
//
// SplitMix64.  Integer arithmetic only, so it is exact and identical on every
// run and every machine -- which is what makes --seed reproducible.  Every
// constant is below 2^32, so they are ordinary positive literals; the products
// wrap into the sign bit and that wrap is the mixing.

def mix64(x: long) -> long {
    let z = x + 2654435761;              // 0x9e3779b1
    z = (z ^ (z >>> 15)) * 2246822519;   // 0x85ebca77
    z = (z ^ (z >>> 13)) * 3266489917;   // 0xc2b2ae3d
    z ^ (z >>> 16)
};

// n deterministic bytes for stream `who` under `seed`.
def seeded(seed: long, who: long, n: long) -> [byte] {
    let out: [byte] = [];
    let st = mix64(seed * 1103515245 + who * 12345 + 1);
    let i = 0;
    while (i < n) {
        let v = mix64(st);
        st = v;
        let j = 0;
        while (j < 8 && i < n) {
            out += v & 255;
            v = v >>> 8;
            i = i + 1;
            j = j + 1;
        };
    };
    out
};

// sha256 of a secret, hex -- the one thing about a secret worth printing.
def secret_fp(shared: [byte]) -> str {
    let d = crypto.sha256(shared);
    C[3] = C[3] + 1;
    crypto.hex(d)
};

export { TAGB, Keys, C, count, derive, agree, public_of, nonce_base, nonce_of, aad_of, dir_str, seal, open, mix64, seeded, secret_fp };