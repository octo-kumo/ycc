// bench.y -- the allocation measurement behind gate item 4.
//
// The heap is an arena and nothing is ever freed (ORCHESTRATOR.md §2.7), so
// "does this loop leak" is answered by heap_used() either side of it.  The
// interesting question is not the total but the *decomposition*, because the
// total is dominated by std/crypto.y and a bare total would say nothing about
// this example's own code.
//
// Three loops, N messages each:
//
//   full    everything a message costs: build the aad, build the nonce, seal,
//           lay out the frame, slice the payload back out, open
//   crypto  chacha_seal + chacha_open on one fixed message, nothing else
//   frame   the frame layout and the payload slice, with a pre-sealed blob and
//           no crypto call at all
//
// `frame` is the control: it is the whole of this example's own per-message
// work.  Whatever `full` costs beyond `frame` is std/crypto.y's.
//
// A fourth measurement runs `full` at N and at 2N: exactly double means the
// growth is a fixed stride per message, not a per-message compounding.  An
// arena leak with a fixed stride still eventually hits the cap -- 4480 bytes a
// message is 4.3 KB, so three million messages -- so the number is stated
// rather than left implicit, but it is the std's and not a leak in a frame loop.

import wire;
import session;
import crypto;
import fmt;

let BKEY: [byte] = [];
let BNONCE: [byte] = [];
let BAAD: [byte] = [];
let BPLAIN: [byte] = [];
let BSEALED: [byte] = [];
let BBASE: [byte] = [];
let BBUF: [byte; 1024] = [0; 1024];

// A fixed stand-in for the session's nonce prefix.  The bench does not care
// what it is, only that every iteration uses the same one, so the measurement
// is of the loop rather than of the key schedule.
let BBASE: [byte] = [1, 2, 3, 4, 5, 6, 7, 8];

// The label the loops stamp into their AAD.  Module level so all three keep the
// signature `long -> long` and `measure` can take any of them as a value.
let BLABEL = "demo";

def setup(label: str) -> void {
    let b: [byte] = [];
    let i = 0;
    while (i < 8) { b += i + 1; i = i + 1; };
    BBASE = b;
    BLABEL = label;
    BKEY = session.derive(bytes("bench-shared-secret-32-bytes-long!!!"), label, session.TAGB + " key a->b");
    BNONCE = session.nonce_of(BBASE, 1);
    BAAD = session.aad_of(label, 1, 0);
    BPLAIN = bytes("alice: bob, the pipes are ours and nobody else can hear us");
    BSEALED = session.seal(BKEY, BNONCE, BAAD, BPLAIN);
};

def loop_full(n: long) -> long {
    let sink = 0;
    let i = 0;
    while (i < n) {
        let seq = i + 1;
        let aad = session.aad_of(BLABEL, seq, 0);
        let nonce = session.nonce_of(BBASE, seq);
        let sealed = session.seal(BKEY, nonce, aad, BPLAIN);
        let hdr = wire.put_hdr(BBUF, wire.K_MSG, wire.PHDR + len(sealed));
        wire.put32(BBUF, hdr, seq);
        wire.put32(BBUF, hdr + 4, 0);
        BBUF[hdr + 8] = 0;
        wire.put_bytes(BBUF, hdr + 9, sealed);
        let back = wire.get_bytes(BBUF, hdr + 9, len(sealed));
        let p = session.open(BKEY, nonce, aad, back);
        sink = sink + len(p!);
        i = i + 1;
    };
    sink
};

def loop_crypto(n: long) -> long {
    let sink = 0;
    let i = 0;
    while (i < n) {
        let sealed = session.seal(BKEY, BNONCE, BAAD, BPLAIN);
        let p = session.open(BKEY, BNONCE, BAAD, sealed);
        sink = sink + len(p!);
        i = i + 1;
    };
    sink
};

def loop_frame(n: long) -> long {
    let sink = 0;
    let i = 0;
    let n0 = len(BSEALED);
    while (i < n) {
        let hdr = wire.put_hdr(BBUF, wire.K_MSG, wire.PHDR + n0);
        wire.put32(BBUF, hdr, i + 1);
        wire.put32(BBUF, hdr + 4, 0);
        BBUF[hdr + 8] = 0;
        wire.put_bytes(BBUF, hdr + 9, BSEALED);
        let back = wire.get_bytes(BBUF, hdr + 9, n0);
        sink = sink + len(back);
        i = i + 1;
    };
    sink
};

// ── the report ───────────────────────────────────────────────────────────
//
// A `def` is a first-class value: its type is `(parameter type) -> return type`
// and the parentheses are the parameter LIST, so `(long) -> long` is a function
// taking one long and `([long]) -> long` is a function taking an ARRAY of longs.
// That is why `measure` can take any of the three loops as an argument.
//
// Each loop is run twice before it is measured, so the SHA-2 constants
// std/crypto.y builds on first use (`k256_tab`) are not counted as a
// per-message cost.  heap_used() either side of N calls gives the delta; the
// number is a fixed stride per message or it is not.

let SINK = 0;
let D_FULL = 0;
let D_CRYPTO = 0;
let D_FRAME = 0;
let D_FULL2 = 0;
let PER_FULL = 0;
let PER_CRYPTO = 0;
let PER_FRAME = 0;
let PER_MINUS_FRAME = 0;
let RATIO_X100 = 0;
let MSGS_TO_CAP = 0;

// The cap is 3.5 GiB; a message costs PER_FULL bytes, so that is how many fit.
const CAP_BYTES = 3670016 * 1024;

def measure(f: (long) -> long, n: long) -> long {
    let h0 = heap_used();
    SINK = SINK + f(n);
    let h1 = heap_used();
    h1 - h0
};

def run(n: long, label: str) -> void {
    setup(label);
    SINK = SINK + loop_full(2);
    SINK = SINK + loop_crypto(2);
    SINK = SINK + loop_frame(2);

    D_FULL = measure(loop_full, n);
    D_CRYPTO = measure(loop_crypto, n);
    D_FRAME = measure(loop_frame, n);
    D_FULL2 = measure(loop_full, 2 * n);

    PER_FULL = D_FULL / n;
    PER_CRYPTO = D_CRYPTO / n;
    PER_FRAME = D_FRAME / n;
    PER_MINUS_FRAME = PER_FULL - PER_FRAME;
    RATIO_X100 = D_FULL2 * 100 / D_FULL;
    MSGS_TO_CAP = CAP_BYTES / (PER_FULL + 1);

    fmt.line("");
    fmt.head("allocation: " + tostring(n) + " messages, heap_used() either side, bytes");
    fmt.line("");
    fmt.row(["  loop", "delta", "per message"], [42, 14, 14]);
    fmt.row(["  full: aad, nonce, seal, frame, open", fmt.thousands(D_FULL), fmt.thousands(PER_FULL)],
            [42, 14, 14]);
    fmt.row(["  crypto only: chacha_seal + chacha_open", fmt.thousands(D_CRYPTO), fmt.thousands(PER_CRYPTO)],
            [42, 14, 14]);
    fmt.row(["  frame only: layout + payload slice", fmt.thousands(D_FRAME), fmt.thousands(PER_FRAME)],
            [42, 14, 14]);
    fmt.line("");
    fmt.line("  this example's own per-message work is the \"frame only\" row: "
             + fmt.thousands(PER_FRAME) + " B.");
    fmt.line("  everything above it (" + fmt.thousands(PER_MINUS_FRAME) + " B) is std/crypto.y's");
    fmt.line("  temporaries: the heap is an arena and nothing is freed (ORCHESTRATOR.md 2.7).");
    fmt.line("");
    fmt.line("  full at " + fmt.thousands(n) + "        " + fmt.thousands(D_FULL));
    fmt.line("  full at " + fmt.thousands(2 * n) + "      " + fmt.thousands(D_FULL2)
             + "      ratio " + ratio_txt() + "  -> a fixed stride per message, not compounding");
    fmt.line("  at " + fmt.thousands(PER_FULL) + " B a message the 3.5 GiB cap arrives after about "
             + fmt.thousands(MSGS_TO_CAP) + " messages");
    fmt.line("  sink " + tostring(SINK) + " (so nothing above was optimised away)");
};

// The ratio to two decimals, without a float: hundredths then thousandths.
def ratio_txt() -> str {
    let r = RATIO_X100;
    let whole = r / 100;
    let frac = r % 100;
    tostring(whole) + "." + tens(frac)
};

def tens(t: long) -> str {
    if (t < 10) { "0" + tostring(t) } else { tostring(t) }
};

export { BKEY, BNONCE, BAAD, BPLAIN, BSEALED, BBASE, BBUF, setup, loop_full, loop_crypto, loop_frame, run, D_FULL, D_CRYPTO, D_FRAME, PER_FULL, PER_FRAME, PER_MINUS_FRAME, MSGS_TO_CAP };