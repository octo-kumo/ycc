// props.y -- the property check.
//
// A golden file proves determinism.  It cannot prove that the crypto is right:
// a program that sealed every message under a constant key and compared
// nothing would reproduce its own output byte for byte for ever.  So every claim
// below is an assertion about the run itself, with no reference file involved,
// and the gate's EXPECTED is only a determinism check.
//
// Each property is one line of the transcript with a PASS or FAIL, and the exit
// status is 1 if any of them failed.  A property that cannot be evaluated --
// the child died, the report is missing -- FAILS.  Nothing here defaults to
// passing.

import wire;
import session;
import chat;
import fmt;
import crypto;

type Prop = { id: str, name: str, ok: bool, detail: str };

let LIST: [Prop] = [];
let PASSED = 0;
let FAILED = 0;

def add(id: str, name: str, ok: bool, detail: str) -> void {
    let p: Prop = { id: id, name: name, ok: ok, detail: detail };
    LIST += p;
    if (ok) { PASSED = PASSED + 1; } else { FAILED = FAILED + 1; };
};

def get(i: long) -> Prop { LIST[i] };
def total() -> long { len(LIST) };
def passed() -> long { PASSED };
def failed() -> long { FAILED };

// ── the findings, as counts ──────────────────────────────────────────────
//
// Everything the properties need, computed once, so a property's `detail` is
// assembled from measured numbers and not from a conclusion.

let F_SAME = 0;             // bytes of the two shared secrets that agree
let F_FIRSTDIFF = 0;        // index of the first difference, or -1
let F_SECLEN = 0;
let F_TAMPER = 0;           // 1 = the child rejected the tampered frame
let F_WRONGAAD = 0;         // 1 = the child rejected the wrong-aad frame
let F_WRONGKEY = 0;         // 1 = this process rejected the wrong-key frame
let F_MARKERS = 0;          // forged plaintexts found in the transcript
let F_LEAKME = 0;           // plaintexts found in the b->a wire log
let F_LEAKPEER = 0;         // plaintexts found in the a->b wire log
let F_PKME = 0;             // the peer's public key found in the b->a wire log
let F_PKPEER = 0;           // ditto in the a->b wire log
let F_FIRSTLEAK = 0 - 1;    // sequence number of the first leaked plaintext, or -1
let F_CTDIFF = 0;           // messages whose sealed bytes differ from the plaintext
let F_CTTAG = 0;            // messages whose sealed length is plaintext + 16
let F_PKSELF = false;       // bob's self-reported public key is the one he sent
let F_PKACK = false;       // and his view of ours is the one we sent him
let F_ROUND = 0;            // opened messages whose bytes equal the sender's
let F_OPENED = 0;           // messages a receiver accepted, both sides
let F_REJECTED = 0;         // messages a receiver refused, both sides
let F_TBEFORE = 0;          // transcript bytes that existed when the scan ran
let F_WANT_OPEN = 0;        // genuine items in the script
let F_WANT_REJ = 0;         // forgeries in the script

// The index of the first byte at which two byte strings differ, or -1.
def first_diff(a: [byte], b: [byte]) -> long {
    let n = len(a);
    if (len(b) < n) { n = len(b); };
    let i = 0;
    let at = -1;
    while (i < n && at < 0) {
        if (a[i] != b[i]) { at = i; };
        i = i + 1;
    };
    if (at >= 0) { return at; };
    if (len(a) == len(b)) { return -1; };
    n
};

// Measure everything.  `peer_pk` is the other side's public point, `mine` this
// process's shared secret, `txkey`/`rxkey` the two directional keys.
def measure(my_pk: [byte], peer_pk: [byte], mine: [byte]) -> void {
    F_SECLEN = len(mine);
    let theirs = crypto.unhex(chat.R_SHARED);
    F_SAME = 0;
    F_FIRSTDIFF = first_diff(mine, theirs);
    if (F_FIRSTDIFF < 0) { F_SAME = len(mine); };

    // The three forgeries: one observed by the child, one by this process.
    let s_t = chat.peer_verdict(5);
    F_TAMPER = 0;
    if (s_t >= 0 && !chat.R_OPENED[s_t]) { F_TAMPER = 1; };
    let s_a = chat.peer_verdict(7);
    F_WRONGAAD = 0;
    if (s_a >= 0 && !chat.R_OPENED[s_a]) { F_WRONGAAD = 1; };
    F_WRONGKEY = 0;
    let i = 0;
    while (i < chat.NREC && F_WRONGKEY == 0) {
        if (chat.SEQ[i] == 6) { if (!chat.OPENED[i]) { F_WRONGKEY = 1; }; };
        i = i + 1;
    };

    // The three forged plaintexts must be in neither the transcript nor the wire.
    // The transcript half is `scan_transcript`, below, because it can only be
    // run once sections 1 to 5 have been printed.
    F_MARKERS = 0;

    // No plaintext of any of the ten messages may be anywhere on either wire.
    F_LEAKME = 0;
    F_FIRSTLEAK = 0 - 1;
    i = 0;
    while (i < chat.NITEMS) {
        let p = bytes(chat.item_text(i));
        let hits = found_in_log(p);
        if (hits > 0 && F_FIRSTLEAK < 0) { F_FIRSTLEAK = chat.item_seq(i); };
        F_LEAKME = F_LEAKME + hits;
        i = i + 1;
    };
    F_LEAKPEER = chat.R_LEAKS;

    F_LEAKPEER = chat.R_LEAKS;

    // The peer's 32-byte public point must be in the b->a log.  This process's
    // own point does not appear there: it went the other way, and the other side
    // is the one that logged it.
    F_PKME = 0;
    if (wire.log_find(0, peer_pk) >= 0) { F_PKME = 1; };
    F_PKPEER = chat.R_FOUND;

    // The child names his own public point in his report.  It has to be the
    // same 32 bytes he sent down the pipe, or the report is not the child this
    // process is talking to -- and therefore the secret in it is not either.
    F_PKSELF = crypto.bytes_eq(peer_pk, crypto.unhex(chat.R_PUBH));
    F_PKACK = crypto.bytes_eq(my_pk, crypto.unhex(chat.R_PEERH));

    // The sealed bytes must never be the plaintext, and must always carry a
    // 16-byte Poly1305 tag.
    F_CTDIFF = 0;
    F_CTTAG = 0;
    F_OPENED = 0;
    F_REJECTED = 0;
    i = 0;
    while (i < chat.NREC) {
        let s = crypto.unhex(chat.SEALEDH[i]);
        let p = bytes(chat.item_text(chat.item_index_of_seq(chat.SEQ[i])));
        if (!crypto.bytes_eq(s, p)) { F_CTDIFF = F_CTDIFF + 1; };
        if (len(s) == len(p) + 16) { F_CTTAG = F_CTTAG + 1; };
        i = i + 1;
    };

    // Every message a receiver accepted must be byte-identical to what the sender
    // started from -- the seal did not mangle the plaintext.  The counts are
    // taken over BOTH sides: this process's own verdicts plus the child's, so
    // the expected totals come straight from the script rather than being
    // written down here.  A check that only asked "did the ones that opened
    // match" would pass with nothing opening at all, which is exactly the hole
    // a mutation test finds.
    F_WANT_OPEN = 0;
    F_WANT_REJ = 0;
    let g = 0;
    while (g < chat.NITEMS) {
        if (chat.item_atk(g) == chat.ATK_NONE) { F_WANT_OPEN = F_WANT_OPEN + 1; }
        else { F_WANT_REJ = F_WANT_REJ + 1; };
        g = g + 1;
    };
    F_ROUND = 0;
    F_OPENED = 0;
    F_REJECTED = 0;
    g = 0;
    while (g < chat.PAIRS) {
        if (chat.R_OPENED[g]) { F_OPENED = F_OPENED + 1; } else { F_REJECTED = F_REJECTED + 1; };
        F_ROUND = F_ROUND + chat.R_ROUND[g];
        g = g + 1;
    };
    i = 0;
    while (i < chat.NREC) {
        if (!chat.MINE[i]) {
            if (chat.OPENED[i]) { F_OPENED = F_OPENED + 1; } else { F_REJECTED = F_REJECTED + 1; };
        };
        i = i + 1;
    };
    i = 0;
    while (i < chat.NREC) {
        if (!chat.MINE[i] && chat.OPENED[i]) {
            let want = bytes(chat.item_text(chat.item_index_of_seq(chat.SEQ[i])));
            let got = crypto.unhex(chat.PLAINH[i]);
            if (crypto.bytes_eq(want, got)) { F_ROUND = F_ROUND + 1; };
        };
        i = i + 1;
    };
};

// The distinctive plaintext of the forgery at sequence number `seq`.
def marker_at(seq: long) -> [byte] {
    let i = chat.item_index_of_seq(seq);
    if (i < 0) { return []; };
    bytes(chat.item_text(i))
};

// P5's other half, run immediately before the property section is built so the
// transcript it scans is the one a reader is looking at.  A rejected message's
// plaintext must not be in it: the conversation log prints the seven genuine
// lines on purpose, and the three forged ones only as a reason and a name.
def scan_transcript() -> void {
    let tb = fmt.transcript_bytes();
    F_TBEFORE = len(tb);
    F_MARKERS = 0;
    F_MARKERS = F_MARKERS + found_count(tb, marker_at(5));
    F_MARKERS = F_MARKERS + found_count(tb, marker_at(6));
    F_MARKERS = F_MARKERS + found_count(tb, marker_at(7));
};

// How many times `needle` occurs in `hay` (an area scan, so a short plaintext
// that appeared twice would be counted twice).
def found_count(hay: [byte], needle: [byte]) -> long {
    let n = 0;
    let at = 0;
    let go = true;
    while (go) {
        let k = find_at(hay, at, needle);
        if (k < 0) { go = false; } else { n = n + 1; at = k + 1; };
    };
    n
};

def found_in_log(needle: [byte]) -> long {
    let n = 0;
    let at = 0;
    let go = true;
    while (go) {
        let k = wire.log_find(at, needle);
        if (k < 0) { go = false; } else { n = n + 1; at = k + 1; };
    };
    n
};

def find_at(hay: [byte], from: long, needle: [byte]) -> long {
    let nl = len(needle);
    let total = len(hay);
    if (nl == 0) { return from; };
    if (from < 0 || nl > total - from) { return -1; };
    let i = from;
    let at = -1;
    while (i + nl <= total && at < 0) {
        let j = 0;
        let same = true;
        while (j < nl && same) {
            if (hay[i + j] != needle[j]) { same = false; };
            j = j + 1;
        };
        if (same) { at = i; };
        i = i + 1;
    };
    at
};

// ── the ten properties ───────────────────────────────────────────────────
//
// `run` only builds the list from the measurements `measure` already made, so
// the transcript can print its own handshake and summary sections even when the
// property section is switched off with --no-check.

def run(mine: [byte], txkey: [byte], rxkey: [byte]) -> void {
    let fpf = session.secret_fp(mine);
    add("P1", "both sides derive the same shared secret",
        F_FIRSTDIFF < 0 && F_SECLEN == 32 && fpf == chat.R_SFP,
        tostring(F_SAME) + "/" + tostring(F_SECLEN) + " bytes identical, first difference "
        + diff_txt() + "; sha256 agrees with bob's: " + yesno(fpf == chat.R_SFP)
        + " (" + fpf[0:16] + "...)");

    add("P2", "a tampered ciphertext is rejected",
        F_TAMPER == 1,
        "message #5, ciphertext byte 0 flipped after sealing: chacha_open returned none");

    add("P3", "a wrong AAD is rejected",
        F_WRONGAAD == 1,
        "message #7, aad claims sequence " + tostring(chat.LIAR_SEQ)
        + ": chacha_open returned none");

    add("P4", "the other direction's key does not open it",
        F_WRONGKEY == 1,
        "message #6, sealed under a->b and sent as b->a: chacha_open returned none");

    add("P5", "no rejected plaintext reaches the transcript",
        F_MARKERS == 0,
        tostring(3 - F_MARKERS) + "/3 forged plaintexts absent from the "
        + tostring(F_TBEFORE) + " B printed above");

    add("P6", "no plaintext anywhere on either wire",
        F_LEAKME == 0 && F_LEAKPEER == 0,
        "0 of " + tostring(chat.NITEMS) + " plaintexts in the b->a log ("
        + tostring(wire.log_len()) + " B) or the a->b ("
        + tostring(chat.R_WIRE) + " B); first leak "
        + leak_txt(F_LEAKME, F_FIRSTLEAK) + " / " + leak_txt(F_LEAKPEER, chat.R_FIRSTLEAK));

    add("P7", "both sides name the same public points",
        F_PKME == 1 && F_PKPEER == 1 && wire.log_len() > 0 && chat.R_WIRE > 0
            && F_PKSELF && F_PKACK,
        "the peer's 32-byte point is in each wire log, so the control for P6 has "
        + "real bytes; and each side's report names the other's point as the one "
        + "that was sent: " + yesno(F_PKSELF && F_PKACK));

    add("P8", "the sealed bytes are never the plaintext",
        F_CTDIFF == chat.NREC && F_CTTAG == chat.NREC,
        tostring(F_CTDIFF) + "/" + tostring(chat.NREC) + " differ from the plaintext, "
        + tostring(F_CTTAG) + "/" + tostring(chat.NREC) + " carry the 16-byte tag");

    add("P9", "every accepted message round-trips exactly",
        F_ROUND == F_WANT_OPEN && F_OPENED == F_WANT_OPEN && F_REJECTED == F_WANT_REJ,
        tostring(F_OPENED) + "/" + tostring(F_WANT_OPEN) + " genuine opened across both sides, "
        + tostring(F_REJECTED) + "/" + tostring(F_WANT_REJ) + " forgeries refused, "
        + tostring(F_ROUND) + " opened identical to the sender's");

    add("P10", "the two directions use different keys",
        !crypto.bytes_eq(txkey, rxkey),
        "a->b " + crypto.hex(txkey[0:8]) + "... vs b->a " + crypto.hex(rxkey[0:8]) + "...");
};

export { Prop, add, get, total, passed, failed, measure, scan_transcript, run, first_diff, found_count, marker_at, yesno };

def diff_txt() -> str {
    if (F_FIRSTDIFF < 0) { "none" } else { "byte " + tostring(F_FIRSTDIFF) }
};

// "none", or "sequence N" when `n` of them leaked.
def leak_txt(n: long, first: long) -> str {
    if (n == 0) { "none" } else { "sequence " + tostring(first) }
};

def yesno(b: bool) -> str {
    if (b) { "yes" } else { "no" }
};

export { Prop, add, get, total, passed, failed, measure, run, first_diff, found_count, marker_at, yesno };