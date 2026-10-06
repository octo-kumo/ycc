// chat.y -- the protocol: the scripted conversation, the X25519 handshake, and
// the two roles.  `alice` runs in the parent, `bob` in a fork(2) child, and
// they meet over three pipes.
//
// ── the flow ────────────────────────────────────────────────────────────────
//
//   1. both draw an X25519 private scalar -- deterministically from --seed, or
//      from getrandom(2) under --live
//   2. alice sends her public point on a->b, bob sends his on b->a, and each
//      reads the other's.  32 bytes each way, one frame.
//   3. each runs X25519(sk, peer) independently, then HKDF-SHA256 to split the
//      shared secret into an a->b key and a b->a key
//   4. the conversation runs strictly alternately -- alice sends, bob reads,
//      bob sends, alice reads -- so neither side can deadlock on a full pipe
//      and both know the sequence number without exchanging it
//   5. bob writes his own view of the world on a third pipe: the shared secret
//      *he* computed, his crypto counters, his scan of the a->b wire, and his
//      verdict on each message of his.  That channel is diagnostic only; the
//      protocol never reads it.
//
// ── what each message is ───────────────────────────────────────────────────
//
//   frame   [kind=2(1) len(4)] [seq(4) dir(4) atk(1)] [sealed(len-9)]
//   sealed  ChaCha20-Poly1305 ciphertext || 16-byte Poly1305 tag
//   nonce   base[0..8] || le32(seq), 12 bytes
//   aad     "crypto-chat/v1|<label>|<seq>|<a->b|b->a>"
//
// `atk` is in the frame but NOT in the authenticated data: it is the sender's
// own account of which forgery it committed, kept outside the seal so that the
// receiver's verdict cannot depend on it.  The receiver's reason is always
// "Poly1305 tag check failed"; which forgery it was comes from the sender.

import wire;
import session;
import crypto;

// The three forgeries.  The plaintexts they carry are distinctive strings, so
// "this text must appear nowhere" is a claim props.P6 can actually check.
const ATK_NONE = 0;
const ATK_TAMPER = 1;    // one ciphertext byte flipped before the write
const ATK_WRONGKEY = 2;  // sealed under the *other* direction's key
const ATK_WRONGAAD = 3;  // aad names sequence 92, the frame says the real one

// The sequence number the wrong-AAD forgery claims.  A receiver never uses it.
const LIAR_SEQ = 92;

// ── the conversation ──────────────────────────────────────────────────────
//
// Built once per run.  Both processes build it from the same table, so each
// knows what its peer is supposed to say without being told.

let T_TXT: [str] = [];
let T_ATK: [long; 16] = [0; 16];
let T_SEQ: [long; 16] = [0; 16];
let T_DIR: [long; 16] = [0; 16];
let NITEMS = 0;

def build_script() -> void {
    script(1, 0, ATK_NONE, "bob, the pipes are ours and nobody else can hear us");
    script(2, 1, ATK_NONE, "confirmed. x25519 agreed, chacha20-poly1305 sealed");
    script(3, 0, ATK_NONE, "every message carries its own nonce, so nothing repeats");
    script(4, 1, ATK_NONE, "and the aad names the sequence and the direction");
    script(5, 0, ATK_TAMPER, "TAMPER-PLAINTEXT-05-MUST-NOT-APPEAR");
    script(6, 1, ATK_WRONGKEY, "WRONGKEY-PLAINTEXT-06-MUST-NOT-APPEAR");
    script(7, 0, ATK_WRONGAAD, "WRONGAAD-PLAINTEXT-07-MUST-NOT-APPEAR");
    script(8, 1, ATK_NONE, "three forgeries offered, three refusals returned");
    script(9, 0, ATK_NONE, "nothing got in. the session is still sound");
    script(10, 1, ATK_NONE, "closing the session. handshake was 32 bytes each way");
};

def script(seq: long, dir: long, atk: long, text: str) -> void {
    T_SEQ[NITEMS] = seq;
    T_DIR[NITEMS] = dir;
    T_ATK[NITEMS] = atk;
    T_TXT += text;
    NITEMS = NITEMS + 1;
};

def item_text(i: long) -> str { T_TXT[i] };
def item_atk(i: long) -> long { T_ATK[i] };
def item_seq(i: long) -> long { T_SEQ[i] };
def item_dir(i: long) -> long { T_DIR[i] };
def item_index_of_seq(s: long) -> long {
    let i = 0;
    let at = -1;
    while (i < NITEMS && at < 0) {
        if (T_SEQ[i] == s) { at = i; };
        i = i + 1;
    };
    at
};

def atk_label(a: long) -> str {
    if (a == ATK_TAMPER) { "ciphertext byte 0 flipped (XOR 0x01)" }
    else if (a == ATK_WRONGKEY) { "sealed under the other direction's key" }
    else if (a == ATK_WRONGAAD) { "aad claims sequence " + tostring(LIAR_SEQ) + ", the frame says the real one" }
    else { "genuine" }
};

def atk_name(a: long) -> str {
    if (a == ATK_TAMPER) { "TAMPERED-CIPHERTEXT" }
    else if (a == ATK_WRONGKEY) { "WRONG-KEY" }
    else if (a == ATK_WRONGAAD) { "WRONG-AAD" }
    else { "-" }
};

// ── what a process records about each of its ten messages ─────────────────
//
// Parallel arrays rather than one record per message: a record literal written
// inside a loop costs 64 bytes of arena every iteration (ORCHESTRATOR.md
// SUGGESTIONS.md §7), and this loop is the one the gate measures.  Numeric
// columns are fixed cells written in place; the string columns hold one string
// value per message, which is the value itself and not a leak.

let SEQ: [long; 16] = [0; 16];
let DIR: [long; 16] = [0; 16];
let ATKC: [long; 16] = [0; 16];
let PTB: [long; 16] = [0; 16];    // plaintext bytes; -1 = the AEAD revealed nothing
let SLB: [long; 16] = [0; 16];    // sealed bytes: ciphertext + the 16-byte tag
let MINE: [bool; 16] = [false; 16];   // true = this process sealed it
let OPENED: [bool; 16] = [false; 16]; // the receiver's verdict; for a message this
                                   // process sent it is filled in from the peer's
                                   // report, since a sender is told nothing
let NREC = 0;
let NONCEH: [str] = [];
let AADTXT: [str] = [];
let SEALEDH: [str] = [];
let PLAINH: [str] = [];

def rec_slot(seq: long) -> long {
    let i = 0;
    let at = -1;
    while (i < NREC && at < 0) {
        if (SEQ[i] == seq) { at = i; };
        i = i + 1;
    };
    at
};

// ── the two roles ─────────────────────────────────────────────────────────
//
// One Role type used by both sides, so there is no second copy of the sealing
// logic to get out of step.

type Role = {
    keys: session.Keys,
    base: [byte],          // 8 nonce bytes
    label: str,
    tx_fd: long,           // write to the peer
    rx_fd: long,           // read from the peer
    record: bool           // false in the child, which reports instead
};

let TXBUF: [byte; 1024] = [0; 1024];
let RXBUF: [byte; 1024] = [0; 1024];

// ── sending ──────────────────────────────────────────────────────────────
//
// Returns the sealed byte count, or -1 on a protocol error.  The frame buffer is
// module level and reused, so a frame costs no allocation of its own.

def send_msg(r: Role, i: long) -> long {
    let seq = item_seq(i);
    let dir = item_dir(i);
    let atk = item_atk(i);
    let text = item_text(i);
    let plain = bytes(text);
    // The AAD a forgery claims: a wrong-AAD forgery lies about the sequence
    // number, and nothing else touches it.
    let claim = seq;
    if (atk == ATK_WRONGAAD) { claim = seq + LIAR_SEQ; };
    let aad = session.aad_of(r.label, claim, dir);
    let key = pick_key(r.keys, atk);
    let nonce = session.nonce_of(r.base, seq);
    let body = session.seal(key, nonce, aad, plain);
    if (atk == ATK_TAMPER) { body = flip_first(body); };
    let n = len(body);
    let hdr = wire.put_hdr(TXBUF, wire.K_MSG, wire.PHDR + n);
    wire.put32(TXBUF, hdr, seq);
    wire.put32(TXBUF, hdr + 4, dir);
    TXBUF[hdr + 8] = atk;
    wire.put_bytes(TXBUF, hdr + 9, body);
    if (wire.wr_all(r.tx_fd, TXBUF, 0, hdr + 9 + n) < 0) { return -1; };
    if (r.record) { note_sent(seq, dir, atk, plain, body, nonce, aad); };
    n
};

// The forgery itself: bit 0 of ciphertext byte 0.  The Poly1305 tag is computed
// before this, so the tag no longer covers the ciphertext it authenticates.
def flip_first(body: [byte]) -> [byte] {
    let b: [byte] = [];
    let i = 0;
    while (i < len(body)) {
        if (i == 0) { b += body[i] ^ 1; } else { b += body[i]; };
        i = i + 1;
    };
    b
};

// A message goes out under this side's send key; a wrong-key forgery borrows
// the *other* direction's key.  The receiver holds that key too -- both sides
// derive both from the shared secret -- which is why this tests key separation
// rather than secrecy.
def pick_key(keys: session.Keys, atk: long) -> [byte] {
    if (atk == ATK_WRONGKEY) { keys.rx } else { keys.tx }
};

def note_sent(seq: long, dir: long, atk: long, plain: [byte], sealed: [byte], nonce: [byte], aad: [byte]) -> void {
    SEQ[NREC] = seq;
    DIR[NREC] = dir;
    ATKC[NREC] = atk;
    PTB[NREC] = len(plain);
    SLB[NREC] = len(sealed);
    MINE[NREC] = true;
    OPENED[NREC] = true;         // overwritten by the peer's verdict in the report
    NONCEH += crypto.hex(nonce);
    AADTXT += from_bytes(aad);
    SEALEDH += crypto.hex(sealed);
    PLAINH += crypto.hex(plain);
    NREC = NREC + 1;
};

// ── receiving ────────────────────────────────────────────────────────────
//
// Read one frame, rebuild the AAD from the frame's own header, and open it.  A
// rejected message yields no plaintext *and no length*: an AEAD says nothing at
// all about the bytes it refused, which is why PTB is -1 there.

def recv_msg(r: Role) -> long {
    if (wire.rd_all(r.rx_fd, RXBUF, 0, wire.HDR) < 0) { return -1; };
    let kind = wire.get_kind(RXBUF);
    let n = wire.get_len(RXBUF);
    if (kind != wire.K_MSG || n < wire.PHDR + 16) { return -1; };
    if (wire.rd_all(r.rx_fd, RXBUF, wire.HDR, n) < 0) { return -1; };
    // Every byte that crossed, frame header included, in the order it crossed.
    wire.log_bytes_buf(RXBUF, 0, wire.HDR + n);
    let seq = wire.get32(RXBUF, wire.HDR);
    let dir = wire.get32(RXBUF, wire.HDR + 4);
    let atk = RXBUF[wire.HDR + 8];
    let sealed = wire.get_bytes(RXBUF, wire.HDR + 9, n - wire.PHDR);
    let nonce = session.nonce_of(r.base, seq);
    let aad = session.aad_of(r.label, seq, dir);
    let pt = session.open(r.keys.rx, nonce, aad, sealed);
    let ok = false;
    let npt = -1;
    if (pt != none) {
        ok = true;
        npt = len(pt!);
    };
    if (r.record) { note_recv(seq, dir, atk, npt, len(sealed), ok, nonce, aad, sealed, pt); };
    n
};

def note_recv(seq: long, dir: long, atk: long, npt: long, slb: long, ok: bool, nonce: [byte], aad: [byte], sealed: [byte], pt: [byte]?) -> void {
    SEQ[NREC] = seq;
    DIR[NREC] = dir;
    ATKC[NREC] = atk;
    PTB[NREC] = npt;
    SLB[NREC] = slb;
    MINE[NREC] = false;
    OPENED[NREC] = ok;
    NONCEH += crypto.hex(nonce);
    AADTXT += from_bytes(aad);
    SEALEDH += crypto.hex(sealed);
    PLAINH += crypto.hex(of(pt));
    NREC = NREC + 1;
};

// The plaintext of an opened message, or an empty byte string for one that was
// refused -- an AEAD reveals nothing about the bytes it rejected.
def of(pt: [byte]?) -> [byte] {
    if (pt == none) { return []; };
    pt!
};

// ── the exchange ──────────────────────────────────────────────────────────
//
// Strict alternation over the ten scripted items, so the sequence numbers are
// 1..10 and neither side ever waits on a pipe that is not being written.  Alice
// sends first; bob reads first.  Both orders are the same code, and that is the
// whole point -- there is no second copy of the sealing logic to get out of step.

const PAIRS = 5;

def exchange(r: Role, send_first: bool) -> long {
    let k = 0;
    let err = 0;
    while (k < PAIRS && err == 0) {
        err = beat(r, k, send_first);
        k = k + 1;
    };
    err
};

// Beat k is items 2k (alice's) and 2k+1 (bob's).  Whichever side sends first
// sends its own item before reading; the other reads first and then answers.
def beat(r: Role, k: long, send_first: bool) -> long {
    let si = 2 * k;
    if (!send_first) { si = si + 1; };
    if (send_first) {
        if (send_msg(r, si) < 0) { return -1; };
        if (recv_msg(r) < 0) { return -1; };
    } else {
        if (recv_msg(r) < 0) { return -1; };
        if (send_msg(r, si) < 0) { return -1; };
    };
    0
};

// ── the handshake ────────────────────────────────────────────────────────

def send_pub(fd: long, pk: [byte]) -> long {
    let hdr = wire.put_hdr(TXBUF, wire.K_PUB, len(pk));
    wire.put_bytes(TXBUF, hdr, pk);
    if (wire.wr_all(fd, TXBUF, 0, hdr + len(pk)) < 0) { return -1; };
    len(pk)
};

def recv_pub(fd: long) -> [byte] {
    if (wire.rd_all(fd, RXBUF, 0, wire.HDR) < 0) { return []; };
    let kind = wire.get_kind(RXBUF);
    let n = wire.get_len(RXBUF);
    if (kind != wire.K_PUB || n != 32) { return []; };
    if (wire.rd_all(fd, RXBUF, wire.HDR, n) < 0) { return []; };
    wire.log_bytes_buf(RXBUF, 0, wire.HDR + n);
    RXBUF[wire.HDR:wire.HDR + n]
};

// ── the child's diagnostic report ────────────────────────────────────────
//
// A line-oriented text block: no JSON exists in Y (ORCHESTRATOR.md §2.4c) and a
// hand-rolled parser over `lines()` is the whole of it.

const K_RPT = 3;

def send_report(fd: long, r: Role, peer_pub: [byte], own_pub: [byte], found: long, leaks: long, firstleak: long) -> long {
    let txt = "";
    txt += "shared " + crypto.hex(r.keys.shared) + "\n";
    txt += "pub " + crypto.hex(own_pub) + "\n";
    txt += "secretfp " + session.secret_fp(r.keys.shared) + "\n";
    txt += "counter";
    let i = 0;
    while (i < 10) {
        txt += " " + tostring(session.count(i));
        i = i + 1;
    };
    txt += "\n";
    txt += "wire " + tostring(wire.log_len()) + "\n";
    txt += "scan " + tostring(found) + " " + tostring(leaks) + " " + tostring(firstleak) + "\n";
    txt += "peer " + crypto.hex(peer_pub) + "\n";
    let k = 0;
    while (k < PAIRS) {
        // Look the record up by sequence number, not by slot: this process
        // records what it sent as well as what it received, so slot k is not
        // the k-th received message.
        let s = rec_slot(item_seq(2 * k));
        let v = "MISSING";
        let n = 0 - 1;
        let rt = "0";
        if (s >= 0) {
            v = verdict_txt(s);
            n = ptb_at(s);
            rt = roundtrip_txt(s, item_seq(2 * k));
        };
        txt += "recv " + tostring(item_seq(2 * k)) + " " + v + " " + tostring(n) + " " + rt + "\n";
        k = k + 1;
    };
    let hdr = wire.put_hdr(TXBUF, K_RPT, len(txt));
    wire.put_str(TXBUF, hdr, txt);
    if (wire.wr_all(fd, TXBUF, 0, hdr + len(txt)) < 0) { return -1; };
    len(txt)
};

// This process's verdict on the message it received with that sequence number.
def verdict_txt(slot: long) -> str {
    if (OPENED[slot]) { "OPENED" } else { "REJECTED" }
};

// -1 for a refused message: an AEAD reveals nothing about the bytes it rejected.
def ptb_at(slot: long) -> long { PTB[slot] };

// "1" when the message this process received at `seq` opened and its bytes are
// exactly what the sender started from.  Computed here, in the child, so the
// round-trip claim is each side's own and not the parent's word for it.
def roundtrip_txt(slot: long, seq: long) -> str {
    let r = "0";
    if (OPENED[slot]) {
        let want = bytes(item_text(item_index_of_seq(seq)));
        if (crypto.bytes_eq(want, crypto.unhex(PLAINH[slot]))) { r = "1"; };
    };
    r
};

def read_report(fd: long) -> str {
    if (wire.rd_all(fd, RXBUF, 0, wire.HDR) < 0) { return ""; };
    let n = wire.get_len(RXBUF);
    if (n < 1 || n > wire.FRAME - wire.HDR) { return ""; };
    if (wire.rd_all(fd, RXBUF, wire.HDR, n) < 0) { return ""; };
    from_bytes(RXBUF[wire.HDR:wire.HDR + n])
};

// ── and its parse ────────────────────────────────────────────────────────
//
// The parent's facts about the other side, so the transcript can state both
// sides' accounts rather than only its own.  `parse_report` returns the number
// of lines it understood; anything else means the child failed, and the
// properties then fail rather than pass by default.

let RPT = "";
let R_SHARED = "";
let R_PUBH = "";
let R_PEERH = "";
let R_SFP = "";
let R_WIRE = 0;
let R_FOUND = 0;
let R_LEAKS = 0;
let R_FIRSTLEAK = 0 - 1;
let R_CNT: [long; 10] = [0; 10];
let R_OPENED: [bool; 5] = [false; 5];
let R_PTB: [long; 5] = [0; 5];
let R_ROUND: [long; 5] = [0; 5];
let R_OK = 0;

def field(ln: str, n: long) -> str {
    let parts = ln.split(" ");
    if (n < len(parts)) { parts[n] } else { "" }
};

def parse_report(txt: str) -> long {
    RPT = txt;
    R_OK = 0;
    if (len(txt) < 8) { return -1; };
    let lines = txt.lines();
    let i = 0;
    while (i < len(lines)) {
        let ln = lines[i];
        let key = field(ln, 0);
        if (key == "shared") { R_SHARED = field(ln, 1); R_OK = R_OK + 1; }
        else if (key == "pub") { R_PUBH = field(ln, 1); R_OK = R_OK + 1; }
        else if (key == "peer") { R_PEERH = field(ln, 1); R_OK = R_OK + 1; }
        else if (key == "secretfp") { R_SFP = field(ln, 1); R_OK = R_OK + 1; }
        else if (key == "counter") {
            let k = 0;
            while (k < 10 && 1 + k < len(ln.split(" "))) {
                R_CNT[k] = tonum(field(ln, 1 + k));
                k = k + 1;
            };
            R_OK = R_OK + 1;
        }
        else if (key == "wire") { R_WIRE = tonum(field(ln, 1)); R_OK = R_OK + 1; }
        else if (key == "scan") {
            R_FOUND = tonum(field(ln, 1));
            R_LEAKS = tonum(field(ln, 2));
            R_FIRSTLEAK = tonum(field(ln, 3));
            R_OK = R_OK + 1;
        }
        else if (key == "recv") {
            let s = tonum(field(ln, 1));
            let j = 0;
            let slot = -1;
            while (j < 5 && slot < 0) {
                if (item_seq(2 * j) == s) { slot = j; };
                j = j + 1;
            };
            if (slot >= 0) {
                R_OPENED[slot] = field(ln, 2) == "OPENED";
                R_PTB[slot] = tonum(field(ln, 3));
                R_ROUND[slot] = tonum(field(ln, 4));
                R_OK = R_OK + 1;
            };
        };
        i = i + 1;
    };
    R_OK
};

// The peer's verdict on one of *our* messages: the report's slot for a sequence
// number, or -1 when the report says nothing about it.
def peer_verdict(seq: long) -> long {
    let j = 0;
    let at = -1;
    while (j < 5 && at < 0) {
        if (item_seq(2 * j) == seq) { at = j; };
        j = j + 1;
    };
    at
};

export { ATK_NONE, ATK_TAMPER, ATK_WRONGKEY, ATK_WRONGAAD, LIAR_SEQ, PAIRS, K_RPT, Role, build_script, item_text, item_atk, item_seq, item_dir, item_index_of_seq, atk_label, atk_name, exchange, send_pub, recv_pub, send_report, read_report, parse_report, peer_verdict, rec_slot, SEQ, DIR, ATKC, PTB, SLB, MINE, OPENED, NREC, NONCEH, AADTXT, SEALEDH, PLAINH, RPT, R_SHARED, R_PUBH, R_PEERH, R_SFP, R_WIRE, R_FOUND, R_LEAKS, R_FIRSTLEAK, R_CNT, R_OPENED, R_PTB, R_ROUND, R_OK };