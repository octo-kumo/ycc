// crypto_chat.y -- an encrypted chat between two forked processes.
//
//   alice runs here.  bob is a fork(2) child.  They agree a session key with
//   X25519 over two pipes, then exchange ten chat messages, every one sealed
//   with ChaCha20-Poly1305 under its own nonce and with an AAD that binds the
//   conversation, the sequence number and the direction.  Three of those ten
//   are deliberate forgeries -- a flipped ciphertext byte, a wrong AAD and the
//   other direction's key -- and the receiver refuses all three.
//
// Nothing here opens a socket.  The default run needs no network, no terminal,
// no clock and no arguments, and its output is a pure function of --seed.
//
// ── what to read in the output ─────────────────────────────────────────────
//
//   section 2  the handshake, and the two sides' independent copies of the
//              shared secret compared byte for byte
//   section 4  the AEAD's verdict on all ten messages, from both sides
//   section 5  the three rejections, with the reason the receiver gave
//   section 6  ten properties with no reference file behind them
//
// ── exit codes ─────────────────────────────────────────────────────────────
//
//   0  the exchange completed and every property held
//   1  a property failed, or the child reported a failure
//   2  a usage error (from args)
//   3  the protocol failed: a pipe broke, a frame was short, the child died

import args;
import wire;
import session;
import chat;
import crypto;
import fmt;
import props;
import bench;

const PROG = "crypto_chat";
const DESC = "X25519 + ChaCha20-Poly1305 chat between two forked processes";

// ── what the run is ──────────────────────────────────────────────────────

let SEED = 1;
let LABEL = "demo";
let LIVE = false;
let BENCH_N = 0;
let DO_CHECK = true;
let SHOW_KEYS = false;
let SHOW_PID = false;
let SHOW_REPORT = false;
let CHILD_PID = 0;
let MODE = "transcript";     // transcript | bench

let SEED_A = 0;
let SEED_B = 0;
let MY_PID = 0;

// Kept only so the transcript can print the 8-byte nonce prefix the key
// schedule derived, which is what both sides rebuild each message's nonce from.
let NBASE: [byte] = [];

const OPTS: [args.Opt] = [
    { long: "seed", short: "", kind: args.NUM, help: "reproducible key material and nonces (default 1)" },
    { long: "label", short: "", kind: args.STR, help: "the conversation label the AAD binds (default \"demo\")" },
    { long: "live", short: "", kind: args.BOOL, help: "draw keys from getrandom(2) instead of --seed; not reproducible" },
    { long: "show-keys", short: "", kind: args.BOOL, help: "print the whole shared secret, not just its sha256" },
    { long: "show-pid", short: "", kind: args.BOOL, help: "print both process ids (they are the only unreproducible numbers)" },
    { long: "show-report", short: "", kind: args.BOOL, help: "print bob's diagnostic report verbatim at the end" },
    { long: "bench", short: "b", kind: args.NUM, help: "measure allocation over N messages and exit" },
    { long: "check", short: "", kind: args.BOOL, help: "run the property check (the default; accepted so a script can say so)" },
    { long: "no-check", short: "", kind: args.BOOL, help: "skip the property check" }
];

def main() -> long {
    args.init(PROG, DESC, OPTS, "");
    let st = args.parse(argv());
    if (st == args.HELP) {
        print(args.usage());
        return 0;
    };
    if (st == args.USAGE) { return 2; };
    SEED = args.get_long("seed", 1);
    LABEL = args.get_str("label", "demo");
    LIVE = args.has("live");
    SHOW_KEYS = args.has("show-keys");
    SHOW_PID = args.has("show-pid");
    SHOW_REPORT = args.has("show-report");
    DO_CHECK = !args.has("no-check");
    BENCH_N = args.get_long("bench", 0);
    if (LABEL == "") { eputs(PROG + ": --label must not be empty\n"); return 2; };
    if (BENCH_N < 0) { eputs(PROG + ": --bench wants a count of 1 or more\n"); return 2; };
    if (len(args.positional()) != 0) {
        eputs(PROG + ": unexpected operand '" + args.positional()[0] + "'; this program takes no files\n");
        return 2;
    };
    MODE = "transcript";
    if (BENCH_N > 0) { MODE = "bench"; };

    SEED_A = SEED;
    SEED_B = SEED + 1;
    chat.build_script();

    if (MODE == "bench") {
        bench.run(BENCH_N, LABEL);
        return 0;
    };
    run_chat()
};

// ── key material ─────────────────────────────────────────────────────────

// Deterministic by default: the same --seed always produces the same private
// scalars and the same nonce bases, on every machine, which is what makes the
// golden file meaningful.  --live is the only path to getrandom(2).
def private_of(which: long) -> [byte] {
    if (LIVE) {
        return crypto.random_bytes(32);
    };
    session.seeded(if (which == 0) { SEED_A } else { SEED_B }, which + 1, 32)
};

// ── the child ────────────────────────────────────────────────────────────

// Bob.  He shares his public point, reads alice's, derives his own copy of the
// shared secret, takes part in the conversation, scans his half of the wire for
// leaked plaintext, and reports all of it -- plus his own copy of the shared
// secret, which is what makes P1 a byte-for-byte comparison rather than a
// shared assertion.
def bob(a2b: wire.Pipe, b2a: wire.Pipe, dbg: wire.Pipe) -> long {
    wire.log_reset();
    let sk_b = private_of(1);
    let pk_b = session.public_of(sk_b);
    let sent = chat.send_pub(b2a.wr, pk_b);
    if (sent != 32) { return 3; };
    let pk_a = chat.recv_pub(a2b.rd);
    if (len(pk_a) != 32) { return 3; };
    // bob sends b->a, so his send direction is 1 and his nonce prefix is the
    // one the key schedule derives for a session with this label.
    let k = session.agree(sk_b, pk_a, LABEL, 1);
    let r: chat.Role = { keys: k, base: session.nonce_base(k.shared, LABEL), label: LABEL,
                         tx_fd: b2a.wr, rx_fd: a2b.rd, record: true };
    let err = chat.exchange(r, false);
    if (err != 0) { return 3; };

    // Scan every byte that crossed a->b for any of the ten plaintexts, and for
    // the two public keys as a positive control.
    let found = 0;
    if (wire.log_find(0, pk_a) >= 0) { found = found + 1; };
    let leaks = 0;
    let first = 0 - 1;
    let i = 0;
    while (i < chat.NITEMS) {
        let at = wire.log_find(0, bytes(chat.item_text(i)));
        if (at >= 0) {
            leaks = leaks + 1;
            if (first < 0) { first = chat.item_seq(i); };
        };
        i = i + 1;
    };
    if (chat.send_report(dbg.wr, r, pk_a, pk_b, found, leaks, first) < 0) { return 3; };
    0
};

// ── the parent ───────────────────────────────────────────────────────────

let KEYS_A: session.Keys = { sk: [], pk: [], peer: [], shared: [], tx: [], rx: [] };
let PEER_PK: [byte] = [];
let PEER_REPORT = "";
let CHILD_CODE = 0;

// The arena, sampled either side of the work -- never the process total.
// heap_used() counts the argument vector, which the runtime has already copied
// onto this heap by the time the first line of main runs: the _start prologue
// calls y_argv_init (src/y/arch/prelude.s), which y_cstr_to_str's every entry
// including argv[0].  So an absolute figure moves with the length of however the
// caller spelled the path -- ./crypto_chat and the same binary by absolute path
// printed 2 828 424 B and 2 828 472 B for one identical run -- 46 more
// characters of argv[0], 48 more bytes of arena.  A delta cannot see any of it:
// the vector is already on the heap at the first sample.  And a delta is the
// better number besides -- it is the cost of the computation, not of the
// process.  See README.md, and SUGGESTIONS.md entries #7 and #24.
let ARENA0 = 0;
let ARENA1 = 0;

def run_chat() -> long {
    ARENA0 = heap_used();
    wire.log_reset();
    let a2b = wire.mkpipe();
    let b2a = wire.mkpipe();
    let dbg = wire.mkpipe();
    if (!wire.pipe_ok(a2b) || !wire.pipe_ok(b2a) || !wire.pipe_ok(dbg)) {
        eputs(PROG + ": pipe2 failed\n");
        return 3;
    };
    MY_PID = syscall(39);

    // Bob has his own private scalar: the seed gives him the same one the
    // deterministic table would, and --live gives him his own getrandom draw.
    let pid = fork {
        let c = bob(a2b, b2a, dbg);
        exit(c)
    };
    CHILD_PID = pid;
    if (pid == 0) {
        // Not reachable: the child never returns from fork.
        exit(3);
    };

    let sk_a = private_of(0);
    if (chat.send_pub(a2b.wr, session.public_of(sk_a)) != 32) { return 3; };
    PEER_PK = chat.recv_pub(b2a.rd);
    if (len(PEER_PK) != 32) { eputs(PROG + ": bob never sent a public key\n"); return 3; };
    KEYS_A = session.agree(sk_a, PEER_PK, LABEL, 0);
    NBASE = session.nonce_base(KEYS_A.shared, LABEL);
    let r: chat.Role = { keys: KEYS_A, base: NBASE, label: LABEL,
                         tx_fd: a2b.wr, rx_fd: b2a.rd, record: true };
    let err = chat.exchange(r, true);
    if (err != 0) { eputs(PROG + ": the exchange broke\n"); return 3; };
    PEER_REPORT = chat.read_report(dbg.rd);
    CHILD_CODE = wait_pid(pid);
    if (chat.parse_report(PEER_REPORT) < 8) {
        eputs(PROG + ": bob's report was short or missing (child exit " + tostring(CHILD_CODE) + ")\n");
        return 1;
    };
    // Fill in what this side knows only now: how the peer judged our messages.
    let i = 0;
    while (i < chat.NREC) {
        if (chat.MINE[i]) {
            let slot = chat.peer_verdict(chat.SEQ[i]);
            if (slot >= 0) { chat.OPENED[i] = chat.R_OPENED[slot]; };
        };
        i = i + 1;
    };

    // Measure first, always: the handshake and summary sections report the same
    // numbers the properties do, whether or not --no-check was given.
    props.measure(KEYS_A.pk, PEER_PK, KEYS_A.shared);
    // Second sample, before anything is printed: the delta is the cost of the
    // work above, and it does not include the transcript's own formatting.
    ARENA1 = heap_used();
    report();
    if (CHILD_CODE != 0) { eputs(PROG + ": bob exited " + tostring(CHILD_CODE) + "\n"); return 1; };
    if (DO_CHECK && props.failed() != 0) { eputs(PROG + ": property check failed\n"); return 1; };
    0
};

// ── the transcript ───────────────────────────────────────────────────────

const TITLE = "crypto-chat: X25519 key agreement and ChaCha20-Poly1305 between two forked processes";

def report() -> void {
    fmt.line(TITLE);
    fmt.line("=".pad_left(78, "="));
    fmt.kv("mode", mode_txt(), 12);
    fmt.kv("label", "\"" + LABEL + "\" -- the AAD binds it into every message", 12);
    fmt.kv("transport", "three pipe2(2) pairs between two processes; no socket is opened", 12);
    fmt.kv("processes", "alice = this process, bob = its fork(2) child" + pid_suffix(), 12);
    fmt.kv("build", "static ELF, pinned refs/ycc.ref -- see README.md", 12);

    handshake();
    conversation();
    per_message();
    summary();
    negatives();
    // The property section goes last, and it is the only one that must be built
    // after everything above: P5 scans the bytes the transcript has printed so
    // far, which is the whole point of checking against what was written.
    if (DO_CHECK) {
        props.scan_transcript();
        props.run(KEYS_A.shared, KEYS_A.tx, KEYS_A.rx);
        properties();
    } else {
        fmt.head("property check skipped (--no-check)");
    }
    if (SHOW_REPORT) { report_dump() }
};

def mode_txt() -> str {
    if (LIVE) { "live -- keys from getrandom(2), NOT reproducible" } else { "deterministic -- seed " + tostring(SEED) }
};

// The one value in this transcript that is not reproducible is a process id, so
    // it is behind a flag and out of the golden run by default.
def pid_suffix() -> str {
    if (SHOW_PID) { return "  (pids " + tostring(MY_PID) + " and " + tostring(CHILD_PID) + ")" };
    "  (--show-pid prints them)"
};

// 1. the handshake, and the two independent copies of the shared secret
def handshake() -> void {
    fmt.rule(1, "handshake");
    fmt.line("");
    fmt.kv("alice x25519 private", show(KEYS_A.sk), 22);
    fmt.kv("alice x25519 public", show(KEYS_A.pk), 22);
    fmt.kv("bob   x25519 public", show(PEER_PK), 22);
    fmt.line("");
    fmt.line("  what crossed a pipe before any key existed:");
    fmt.line("    alice -> bob   32 B  one frame, kind " + tostring(wire.K_PUB));
    fmt.line("    bob   -> alice 32 B  one frame, kind " + tostring(wire.K_PUB));
    fmt.line("    alice -> bob   " + tostring(chat.R_WIRE) + " B of frames in total, all sealed");
    fmt.line("    bob   -> alice " + tostring(wire.log_len()) + " B of frames in total, all sealed");
    fmt.line("");
    fmt.line("  the shared secret, computed independently on each side:");
    fmt.line("    alice  sha256 " + session.secret_fp(KEYS_A.shared));
    fmt.line("    bob    sha256 " + chat.R_SFP);
    if (SHOW_KEYS) {
        fmt.line("    alice  raw    " + crypto.hex(KEYS_A.shared));
        fmt.line("    bob    raw    " + chat.R_SHARED);
    } else {
        fmt.line("    (--show-keys prints the raw 32 bytes; by default only sha256 is shown,");
        fmt.line("     because a transcript that prints the session secret is a bad habit)");
    };
    fmt.line("    compared " + tostring(props.F_SECLEN) + " of " + tostring(props.F_SECLEN)
             + " bytes: " + compare_txt());
    fmt.line("");
    fmt.line("  session keys -- HKDF-SHA256, salt = sha256(\"" + session.TAGB + " salt|" + LABEL + "\")");
    fmt.kv("a -> b  info \"" + session.TAGB + " key a->b\"", show(KEYS_A.tx), 42);
    fmt.kv("b -> a  info \"" + session.TAGB + " key b->a\"", show(KEYS_A.rx), 42);
    fmt.line("  different keys per direction: "
             + props.yesno(!crypto.bytes_eq(KEYS_A.tx, KEYS_A.rx))
             + " -- which is what stops a frame being read the other way round");
    fmt.line("");
    fmt.line("  nonce = prefix[0..8] || le32(seq)   -- 12 bytes, as RFC 8439 fixes it.");
    fmt.line("    prefix   " + show(prefix_of()) + "   a product of the key schedule");
    fmt.line("             (info \"" + session.TAGB + " nonce\"), so both sides compute it from");
    fmt.line("             the shared secret without exchanging it.  seq runs 1..10.");
    fmt.line("  a counter is only a safe nonce source here because the two directions");
    fmt.line("  already hold different keys; a real deployment would also prepend 4");
    fmt.line("  random bytes carried in the handshake.  See the README section WhatThisDoesNotDo.");
};

def prefix_of() -> [byte] { NBASE };

def compare_txt() -> str {
    if (props.F_FIRSTDIFF < 0) { "IDENTICAL" } else { "first difference at byte " + tostring(props.F_FIRSTDIFF) }
};

def show(b: [byte]) -> str {
    if (SHOW_KEYS || len(b) != 32) { crypto.hex(b) } else { crypto.hex(b[0:12]) + ".." + crypto.hex(b[12:24]) + ".." }
};

// 2. the conversation as it reads, with the three refusals where they happen
def conversation() -> void {
    fmt.rule(2, "the conversation, as the receivers saw it");
    fmt.line("");
    let i = 0;
    while (i < chat.NITEMS) {
        let k = chat.rec_slot(chat.item_seq(i));
        if (k >= 0) {
            fmt.line("  #" + fmt.rpad(tostring(chat.SEQ[k]), 2) + "  " + session.dir_str(chat.DIR[k])
                     + "  " + line_text(k));
        };
        i = i + 1;
    };
    fmt.line("");
    fmt.line("  the three forged plaintexts are deliberately distinctive strings, and");
    fmt.line("  none of them appears above -- that is property P5, and it is checked");
    fmt.line("  against the bytes this run actually printed, not against this comment.");
};

def line_text(i: long) -> str {
    let who = who_of(i);
    let atk = chat.ATKC[i];
    if (atk != chat.ATK_NONE) {
        return fmt.pad(who, 6) + "[REJECTED " + chat.atk_name(atk) + "]  "
               + "receiver: Poly1305 tag check failed";
    };
    fmt.pad(who, 6) + "\"" + chat.item_text(chat.item_index_of_seq(chat.SEQ[i])) + "\""
};

// 3. the AEAD's verdict on every message, from both sides
def per_message() -> void {
    fmt.rule(3, "the AEAD's verdict on all ten messages");
    fmt.line("");
    fmt.line("  #  dir   by     pt   sealed  verdict");
    fmt.line("  -----------------------------------------------------------------------");
    let i = 0;
    while (i < chat.NREC) {
        fmt.line("  " + fmt.rpad(tostring(chat.SEQ[i]), 2) + " "
                 + session.dir_str(chat.DIR[i]) + "  " + fmt.pad(who_of(i), 5) + " "
                 + fmt.rpad(pt_txt(i), 3) + "  " + fmt.rpad(tostring(chat.SLB[i]), 5) + "  "
                 + verdict_txt(i));
        i = i + 1;
    };
    fmt.line("");
    fmt.line("  pt = plaintext bytes.  A rejected message shows \"?\": an AEAD reveals nothing");
    fmt.line("  about the bytes it refused, not even their length.  sealed = ciphertext plus");
    fmt.line("  the 16-byte Poly1305 tag, so it is always pt + 16 for a genuine message.");
    fmt.line("");
    fmt.line("  one message's wire bytes, in full:");
    let k = 0;
    while (k < chat.NREC) {
        if (chat.SEQ[k] == 3) {
            fmt.line("    #3 a->b  nonce     " + chat.NONCEH[k]);
            fmt.line("        aad         \"" + chat.AADTXT[k] + "\"");
            fmt.line("        sealed      " + chat.SEALEDH[k]);
            fmt.line("        plaintext   \"" + chat.item_text(2) + "\"");
        };
        k = k + 1;
    };
};

def who_of(i: long) -> str {
    if (chat.MINE[i]) { "alice" } else { "bob" }
};

def who_of(i: long) -> str {
    if (chat.MINE[i]) { "alice" } else { "bob" }
};

def pt_txt(i: long) -> str {
    if (chat.PTB[i] < 0) { "?" } else { tostring(chat.PTB[i]) }
};

def verdict_txt(i: long) -> str {
    if (chat.OPENED[i]) { "OPENED  (bytes identical to the sender's)" } else { "REJECTED (chacha_open -> none)" }
};

// 4. the crypto summary, both sides' accounts
def summary() -> void {
    fmt.rule(4, "crypto summary");
    fmt.line("");
    let c = session.count(0);
    fmt.row(["  primitive", "alice (this process)", "bob (the child)"], [30, 24, 24]);
    fmt.row(["  x25519 scalar mults", tostring(c), tostring(chat.R_CNT[0])], [30, 24, 24]);
    fmt.row(["  hkdf extract calls", tostring(session.count(1)), tostring(chat.R_CNT[1])], [30, 24, 24]);
    fmt.row(["  hkdf expand calls", tostring(session.count(2)), tostring(chat.R_CNT[2])], [30, 24, 24]);
    fmt.row(["  explicit sha256 calls", tostring(session.count(3)), tostring(chat.R_CNT[3])], [30, 24, 24]);
    fmt.row(["  chacha_seal calls", tostring(session.count(4)), tostring(chat.R_CNT[4])], [30, 24, 24]);
    fmt.row(["  chacha_open calls", tostring(session.count(5)), tostring(chat.R_CNT[5])], [30, 24, 24]);
    fmt.row(["  chacha_open accepted", tostring(session.count(6)), tostring(chat.R_CNT[6])], [30, 24, 24]);
    fmt.row(["  chacha_open rejected", tostring(session.count(7)), tostring(chat.R_CNT[7])], [30, 24, 24]);
    fmt.row(["  plaintext bytes sealed", tostring(session.count(8)), tostring(chat.R_CNT[8])], [30, 24, 24]);
    fmt.row(["  sealed bytes produced", tostring(session.count(9)), tostring(chat.R_CNT[9])], [30, 24, 24]);
    fmt.line("");
    fmt.line("  each side seals its own " + tostring(chat.PAIRS) + " messages and opens the peer's "
             + tostring(chat.PAIRS) + ".");
    fmt.line("  alice accepted " + tostring(session.count(6)) + " of her "
             + tostring(session.count(5)) + " opens and refused "
             + tostring(session.count(7)) + ";");
    fmt.line("  bob accepted " + tostring(chat.R_CNT[6]) + " of his "
             + tostring(chat.R_CNT[5]) + " and refused " + tostring(chat.R_CNT[7])
             + ".  Seven genuine messages opened, three were refused.");
    fmt.line("  neither side ever opens what it sealed itself -- a sender gets no receipt");
    fmt.line("  here, which is why the counts only add up across both sides.");
    fmt.line("");
    fmt.line("  what each side learned about the other's plaintext length, in arrival order.");
    fmt.line("  \"?\" is not a gap in the report: an AEAD reveals nothing about a message it");
    fmt.line("  refused, so a refusal is the only honest answer and -1 is what travels.");
    fmt.kv("alice, on bob's 2,4,6,8,10", peer_ptb_txt(0), 28);
    fmt.kv("bob, on alice's 1,3,5,7,9", peer_ptb_txt(1), 28);
    fmt.line("");
    fmt.line("  wire bytes this process logged (b->a): " + fmt.thousands(wire.log_len())
             + "   bob logged (a->b): " + fmt.thousands(chat.R_WIRE));
    fmt.line("  arena this exchange cost: " + fmt.thousands(ARENA1 - ARENA0) + " B"
             + "  (heap_used() either side of the work, not a process total)");
    fmt.line("  a delta, not the process total: the runtime copies the whole argument");
    fmt.line("    vector onto this heap at entry -- y_argv_init in the arch prelude calls");
    fmt.line("    y_cstr_to_str on every entry including argv[0] -- and that is before the");
    fmt.line("    first sample, so an absolute here would move with the length of however");
    fmt.line("    you spelled the path.  Neither figure includes bob's arena: he is a");
    fmt.line("    fork(2) child, and nothing is ever freed or shared back.");
};

// dir 0 is what this process learned from bob, dir 1 is what the child learned
// from alice.  Each reads the length out of its own records: this process out of
// chat.PTB, the child out of the text report.
def peer_ptb_txt(dir: long) -> str {
    let s = "";
    let k = 0;
    while (k < chat.PAIRS) {
        let pt = 0 - 1;
        if (dir == 0) { pt = my_recv_ptb(chat.item_seq(2 * k + 1)); } else { pt = chat.R_PTB[k] };
        if (k > 0) { s = s + " "; };
        if (pt < 0) { s = s + "?"; } else { s = s + tostring(pt); };
        k = k + 1;
    };
    s
};

def my_recv_ptb(seq: long) -> long {
    let i = 0;
    let got = 0 - 1;
    while (i < chat.NREC && got < 0) {
        if (chat.SEQ[i] == seq && !chat.MINE[i]) { got = chat.PTB[i]; };
        i = i + 1;
    };
    got
};

// 5. the three rejections, one per line, with the sender's account
def negatives() -> void {
    fmt.rule(5, "the three forgeries, and why each was refused");
    fmt.line("");
    let i = 0;
    while (i < chat.NREC) {
        let a = chat.ATKC[i];
        if (a != chat.ATK_NONE) {
            fmt.line("  #" + fmt.rpad(tostring(chat.SEQ[i]), 2) + "  " + session.dir_str(chat.DIR[i])
                     + "  " + fmt.pad(chat.atk_name(a), 20) + " observed by " + fmt.pad(observer(i), 5)
                     + "  " + verdict_txt(i));
            fmt.line("      sender did: " + chat.atk_label(a));
            fmt.line("      what the receiver can know: only that the 16-byte Poly1305 tag did");
            fmt.line("      not verify.  chacha_open returns none and says nothing else -- it");
            fmt.line("      does not distinguish a wrong key from a wrong aad from a flipped");
            fmt.line("      ciphertext byte, and the forgery name above is the sender's own account.");
        };
        i = i + 1;
    };
    fmt.line("");
    fmt.line("  the AAD is not on the wire.  Each side rebuilds it from the frame's own header");
    fmt.line("  (sequence and direction) and the session label, which is what makes the a->b");
    fmt.line("  key useless in the b->a direction and a replay at another sequence impossible.");
};

def observer(i: long) -> str {
    if (chat.MINE[i]) { "bob" } else { "alice" }
};

// 6. the properties.  Built by props.run, which must have been called first.
def properties() -> void {
    fmt.rule(6, "property check -- assertions about this run, no reference file");
    fmt.line("");
    fmt.line("  A golden file proves determinism.  It cannot prove the crypto is right: a");
    fmt.line("  program that sealed everything under a constant key and compared nothing");
    fmt.line("  would reproduce its own output for ever.  These ten do not use EXPECTED.");
    fmt.line("");
    let i = 0;
    while (i < props.total()) {
        let p = props.get(i);
        fmt.line("  " + fmt.pad(p.id, 4) + fmt.pad(p.name, 48) + verdict(p.ok));
        fmt.line("      " + p.detail);
        i = i + 1;
    };
    fmt.line("");
    fmt.line("  PROPERTY CHECK: " + verdict(props.failed() == 0)
             + "  (" + tostring(props.passed()) + "/" + tostring(props.total()) + ")");
    if (props.failed() != 0) {
        fmt.line("  exit status is 1: at least one of the assertions above is false");
    };
};

def verdict(b: bool) -> str {
    if (b) { "PASS" } else { "FAIL" }
};

// Bob's report verbatim, for a reader who wants to see what the child actually
// said rather than what the parent parsed out of it.  It is a text block because
// there is no JSON in Y (ORCHESTRATOR.md 2.4c) -- `lines()` is the whole parser.
def report_dump() -> void {
    fmt.head("bob's diagnostic report, verbatim");
    fmt.line("");
    fmt.line(chat.RPT);
};

exit(main());