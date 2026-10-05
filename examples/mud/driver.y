// driver.y -- starting the server, driving clients, and the two paired scripts
// the property checks need.
//
// ===========================================================================
// WHY THE POOL IS SPAWNED BEFORE ANY CLIENT CONNECTS
// ===========================================================================
//
// The accept loop is a thread and the pool is `NW` threads, and the order they
// start in is load-bearing for one non-obvious reason: a session's private world
// copy is written by the ACCEPTOR (server.init_session) and then read by a
// WORKER.  The handoff between them is the semaphore, so the ordering is already
// safe -- but starting the workers first means there is never a window in which a
// connection is accepted and queued with nobody free to take it, which turns that
// window into a barrier timeout rather than into a stall.  Cheapest to remove the
// window than to reason about it.
//
// ===========================================================================
// WHY THERE IS NO `join` ON ANY OF THESE THREADS
// ===========================================================================
//
// A spawn's value is a closure, and a closure's type cannot be written down in Y
// (it is `() -> long`, and `[(long) -> long]` is a DIFFERENT type and is
// rejected), so a thread handle cannot go into an array to be joined later.  That
// is why there is a rendezvous counter (`client.V_DONE`) instead of `join(t)`,
// and why the workers are released with SHUTDOWN and left for exit_group to reap.
// See README.md, "WORKAROUNDS".

import net;
import sockio;
import world;
import server;
import client;

// One name per client slot, EIGHT of them, all distinct.
//
// It was four, indexed `c % 4`, which is fine for the two-client default and
// quietly wrong above it: `--clients 5` gave two sessions the name "alice", the
// server refused the second login ("that name is taken"), and from then on that
// session's every command answered "log in first" -- including its `sync`, so a
// five-party barrier only ever collected four arrivals and timed out (measured:
// `mud: a client did not finish its script (2 of 5)`, exit 1).  Names are cheap;
// distinct ones are correct.
let NAMES: [str] = ["alice", "bob", "carol", "dave",
                    "erin", "frank", "grace", "heidi"];

def ps(b: [byte; 4096], n: long, s: str) -> long { sockio.obs(b, n, s) };
def pn(b: [byte; 4096], n: long, v: long) -> long { sockio.obn(b, n, v) };

def start_pool(nw: long) -> long {
    let i = 0;
    while (i < nw) {
        let k = i;
        spawn { server.worker(k) };
        i = i + 1;
    };
    nw
};

// The whole server side in one call: bind, listen, spawn the pool, spawn the
// acceptor.  Returns the listening fd.  The port is read back by the caller and
// NEVER printed -- a kernel-assigned port differs every run.
def serve(nw: long, want: long, goal: long, seed: long) -> long {
    let lfd = sockio.listen_on(0);
    server.LFD[0] = lfd;
    server.SYNC_GOAL[0] = goal;
    // SHUTDOWN is cleared HERE, and it has to be.  stop() sets it and leaves
    // exactly one token on JOBQ that no worker is left to take (it posts nw + 1
    // for nw workers), so a pool started afterwards inherits both: the first new
    // worker wakes on that stale token, finds no slot to claim, sees SHUTDOWN and
    // quits.  One worker lost per server.
    //
    // It was invisible in `--frames` (one server per run) and it broke `--check`,
    // which starts four: with `--workers 3` the fourth server had no worker left
    // and property check (d) reported "ada heard bo: FAIL" -- two clients that
    // needed two workers, given one.  Clearing the flag restores the pool to its
    // full size every time.
    server.SHUTDOWN[0] = 0;
    start_pool(nw);
    spawn { server.acceptor(want, seed) };
    lfd
};

// Release the pool and the acceptor.  Not strictly needed (exit_group reaps
// every thread) but it makes a --bench loop's second round deterministic instead
// of racing the previous round's workers.
def stop(nw: long) -> long {
    server.SHUTDOWN[0] = 1;
    let k = 0;
    while (k < nw + 1) { post server.JOBQ; k = k + 1 };
    0
};

// ---------------------------------------------------------------------------
// the step table: the client's policy
// ---------------------------------------------------------------------------
//
// One function, so the whole policy can be read top to bottom.  Each step reads
// what the server last said (this client's own slot state) and picks a command
// legal where the client believes it is.  If the belief is wrong the server says
// so with +ERR and the transcript shows it -- the client does NOT read the world
// directly, so a wrong belief is visible rather than papered over.
//
//   step mod 13:
//    1  sync            barrier
//    2  look
//    3  take the first thing on the floor   (else wait)
//    4  inventory
//    5  drop the first thing carried        (else look)
//    6  wait
//    7  sync            barrier
//    8  say hello there
//    9  sync            barrier
//   10  the first exit that exists          (else wait)
//   11  attack what watches here            (else wait)
//   12  sync            barrier
//    0  look (a filler, so 13 divides the walk evenly)
//
// WHY THE BARRIERS ARE AT 1, 7, 9 AND 12, AND WHY THEY ARE THERE AT ALL.
//
// A barrier is the program's only ordering primitive, and the step table is built
// out of three things it has to buy:
//
//   * chat.  The barrier that OPENS promotes every session's staged chat for
//     delivery (server.y, "CHAT: STAGED, THEN PROMOTED"), so a message appears in
//     the reply to the first barrier after the `say` that produced it.  One
//     barrier between every two `say`s is enough for that to happen once per
//     message, and props.y CHECKS that (check (e)) rather than trusting it.
//   * the room view.  `also here:` is drawn from what the server says NOW, so the
//     `look` at step 2 only means anything because step 1 was a barrier: after
//     it, every session is logged in and standing in room 0.  The same argument
//     covers the walk -- the move at 10 is between barriers at 9 and 12, so a
//     later `look` cannot see a half-finished move.
//   * the end of the script.  `quit` logs a session out, and a partner's `look`
//     afterwards would draw one fewer `also here:` line.  run_client sends a last
//     barrier before `map` for exactly that reason (see there), so every `quit`
//     happens after every `look`.
//
// The table that came before this one had barriers at 1, 8, 10, 12 and its `say`
// at 9, and it was NOT reproducible: the barrier that promoted the chat and the
// drain that delivered it were the same event, so whether the sender's `say` had
// been staged yet when the round opened was a coin toss -- usually the message
// arrived at the barrier at 8, about one run in five at the barrier at 10, and
// the two transcripts differed.  Promoting at the barrier and draining later
// removed the dependency on the schedule, and the table could then be arranged
// for readability.

// The table as predicates, so build_cmd and the property check read ONE
// definition of it -- and because a branch on `k == 8` cannot be checked from
// outside at all.
def step_is_sync(k: long) -> bool { k == 1 || k == 7 || k == 9 || k == 12 };
def step_is_say(k: long) -> bool { k == 8 };
def step_is_look(k: long) -> bool { k == 0 || k == 2 };
def step_count() -> long { 13 };

def build_cmd(c: long, step: long, goal: long, tx: [byte; 4096]) -> long {
    let n = 0;
    let k = step % 13;
    if (step_is_sync(k)) {
        n = ps(tx, n, "sync ");
        n = pn(tx, n, goal);
    } else if (step_is_look(k)) {
        n = ps(tx, n, "look");
    } else if (k == 3) {
        if (client.slot_len(c, client.SL_GROUND) > 0) {
            n = ps(tx, n, "take ");
            n = client.tcmd(tx, c, n, client.SL_GROUND);
        } else {
            n = ps(tx, n, "wait");
        };
    } else if (k == 4) {
        n = ps(tx, n, "inventory");
    } else if (k == 5) {
        if (client.slot_len(c, client.SL_CARRY) > 0) {
            n = ps(tx, n, "drop ");
            n = client.tcmd(tx, c, n, client.SL_CARRY);
        } else {
            n = ps(tx, n, "look");
        };
    } else if (k == 6) {
        n = ps(tx, n, "wait");
    } else if (step_is_say(k)) {
        n = ps(tx, n, "say hello there");
    } else if (k == 10) {
        // the first exit that exists, in compass order, so a walk down a
        // corridor reads as a column in the transcript
        let d = 0;
        let chose = 0;
        while (d < 4 && chose == 0) {
            if ((client.V_EXMASK[c] & (1 << d)) != 0) {
                n = ps(tx, n, world.dir_abbr(d));
                chose = 1;
            };
            d = d + 1;
        };
        if (chose == 0) { n = ps(tx, n, "wait") };
    } else if (k == 11) {
        // hit whatever is watching here; with no monster, let the turn pass
        if (client.slot_len(c, client.SL_MON) > 0) {
            n = ps(tx, n, "attack ");
            n = client.tcmd(tx, c, n, client.SL_MON);
        } else {
            n = ps(tx, n, "wait");
        };
    } else {
        n = ps(tx, n, "look");
    };
    n
};

// Is this command a `look`?  The client uses it to decide whether the reply's
// `also here:` line is a fact or a race -- see client.arm_others.
def cmd_is_look(tx: [byte; 4096], n: long) -> bool {
    n == 4 && tx[0] == 108 && tx[1] == 111 && tx[2] == 111 && tx[3] == 107
};

// ---------------------------------------------------------------------------
// one request / reply
// ---------------------------------------------------------------------------

// Send one command and render every line of its reply.  The whole reply is read
// before the next command goes out, so the transcript is in the server's order
// and cannot interleave.  Bounded by the socket's own read timeout, so a server
// that stops talking produces a reported stall rather than a hang.
def drain(c: long, fd: long, rx: [byte; 4096], hold: [long; 2]) -> long {
    let seen = 0;
    let rc = 0;
    let go = true;
    while (go) {
        // line_get returns the line PACKED as start * 8192 + length, because it
        // cannot compact before the caller has read it (see sockio.y).
        let pk = sockio.line_get(fd, rx, hold);
        if (pk < 0) {
            if (seen == 0) {
                client.TLEN[c] = client.ts(c, client.TLEN[c],
                    "  (the connection closed with no reply)\n");
                client.V_STALLS[c] = client.V_STALLS[c] + 1;
                rc = 1;
            };
            go = false;
        } else {
            let at = pk / sockio.PACK;
            let ln = pk % sockio.PACK;
            seen = seen + 1;
            client.TLEN[c] = client.render_line(c, client.TLEN[c], rx, at, at + ln, NAMES[0]);
            if (client.is_end(rx, at, at + ln)) { go = false };
        };
    };
    rc
};

// Send `a` + `b` as one command line, echoing it into the transcript first.
def send_cmd(c: long, fd: long, tx: [byte; 4096], rx: [byte; 4096], hold: [long; 2], a: str, b: str) -> long {
    let n = sockio.obs(tx, 0, a);
    n = sockio.obs(tx, n, b);
    client.TLEN[c] = client.ts(c, client.TLEN[c], "> ");
    client.TLEN[c] = client.tmem(c, client.TLEN[c], tx, 0, n);
    client.TLEN[c] = client.tnl(c, client.TLEN[c]);
    let w = sockio.ob(tx, n, 10);
    sockio.send_buf(fd, tx, w);
    drain(c, fd, rx, hold)
};

// send_sync: `sync <goal>` with the number written STRAIGHT into the line
// buffer.
//
// It is its own function because of `tostring`.  A `str` is a heap block, so
// `send_cmd(c, fd, tx, rx, hold, "sync ", tostring(goal))` allocates one every
// time it is called -- measured at 32 bytes -- and the client sends two of these
// per connection.  That was the last 64 bytes a connection of the main thread's
// heap in `--bench`, and it is the same reason every other number in this program
// is written with obn/ob into a byte buffer instead of being turned into a string
// (see sockio.obn and client.tn, both of which grew a scratch array per call
// until they were rewritten as two passes with no scratch).
def send_sync(c: long, fd: long, tx: [byte; 4096], rx: [byte; 4096], hold: [long; 2], goal: long) -> long {
    let n = sockio.obs(tx, 0, "sync ");
    n = sockio.obn(tx, n, goal);
    client.TLEN[c] = client.ts(c, client.TLEN[c], "> ");
    client.TLEN[c] = client.tmem(c, client.TLEN[c], tx, 0, n);
    client.TLEN[c] = client.tnl(c, client.TLEN[c]);
    let w = sockio.ob(tx, n, 10);
    sockio.send_buf(fd, tx, w);
    drain(c, fd, rx, hold)
};

def one_step(c: long, fd: long, tx: [byte; 4096], rx: [byte; 4096], hold: [long; 2], step: long, goal: long) -> long {
    let n = build_cmd(c, step, goal, tx);
    client.arm_others(c, cmd_is_look(tx, n));
    client.TLEN[c] = client.ts(c, client.TLEN[c], "> ");
    client.TLEN[c] = client.tmem(c, client.TLEN[c], tx, 0, n);
    client.TLEN[c] = client.tnl(c, client.TLEN[c]);
    let w = sockio.ob(tx, n, 10);
    sockio.send_buf(fd, tx, w);
    drain(c, fd, rx, hold)
};

// ---------------------------------------------------------------------------
// the done-counter hand-off
// ---------------------------------------------------------------------------
//
// Every client thread bumps one counter when it is finished, and the main thread
// waits for n of them.  Both ends go through the pool's one lock, which is a
// binary semaphore rather than a mutex precisely so that this is free: a
// `lock server.LM { ... }` block is a closure, 16 bytes a time, once per client
// (server.y, LM; SUGGESTIONS.md 10).  wait_done is polled rather than blocked on
// a second semaphore because it also has to time out, and the poll is bounded.

def done_bump() -> long {
    wait server.LM;
    client.V_DONE[0] = client.V_DONE[0] + 1;
    post server.LM;
    0
};

def done_reset() -> long {
    wait server.LM;
    client.V_DONE[0] = 0;
    post server.LM;
    0
};

def done_count() -> long {
    let n = 0;
    wait server.LM;
    n = client.V_DONE[0];
    post server.LM;
    n
};

// ---------------------------------------------------------------------------
// run_client: one client, the whole step table
// ---------------------------------------------------------------------------
//
// Returns 0 when the client got through every step and said goodbye, 1 on a
// protocol stall, 2 on a connect failure.  Never traps: every read is bounded by
// the socket's own timeout and every index is bounds-checked by construction.
//
// THE BUFFERS ARE THE CALLER'S, and that is the point.  A `[byte; 4096]` local
// is a heap allocation (the heap is an arena, ORCHESTRATOR.md 2.7), so declaring
// the two line buffers inside run_client costs 8 208 bytes on EVERY CALL -- fine
// for the one-shot threaded run, and a leak for `--bench`, which calls this once
// per connection: measured at 8 736 bytes per connection, dead flat, i.e. exactly
// the buffers and nothing else.  Passing them in means the bench allocates once
// for the whole run and the per-connection figure drops to what the protocol
// genuinely costs.  The three paired scripts below take the same buffers, for the
// same reason.

def run_client(c: long, port: long, frames: long, goal: long,
               tx: [byte; 4096], rx: [byte; 4096], hold: [long; 2], tv: [long; 2],
               sa: [byte; 16]) -> long {
    sockio.line_reset(hold);
    client.reset(c, NAMES[c % 8], c, goal);
    let fd = sockio.dial(sa, port);
    if (fd < 0) {
        client.TLEN[c] = client.ts(c, client.TLEN[c], "  cannot reach the server: errno ");
        client.TLEN[c] = client.tn(c, client.TLEN[c], fd);
        client.TLEN[c] = client.tnl(c, client.TLEN[c]);
        done_bump();
        return 2;
    };
    sockio.set_timeout(fd, 20, tv);
    let bad = 0;
    if (send_cmd(c, fd, tx, rx, hold, "login ", NAMES[c % 8]) != 0) { bad = 1 };
    // The FIRST command after login is the barrier, not the first step of the
    // policy.  Without it, whether the other player's `also here:` line is in
    // this client's first `look` is a question of thread timing -- measured as 2
    // of 3 runs identical.  After the barrier, everybody is logged in, so
    // everybody is in the room, and `+ROTH` is the same on every run.
    if (bad == 0) {
        if (send_sync(c, fd, tx, rx, hold, goal) != 0) { bad = 1 };
    };
    let step = 0;
    while (bad == 0 && step < frames) {
        if (one_step(c, fd, tx, rx, hold, step, goal) != 0) { bad = 1 };
        step = step + 1;
    };
    // AND A LAST BARRIER, before the map, and this one is not optional.
    //
    // Everything after a barrier is ordered; everything after the LAST barrier is
    // a free-for-all, and the tail of this script is not order-independent.  A
    // client that quits logs out (S_ON goes to 0), and the next client's `look`
    // then draws one fewer `also here:` line -- so without this barrier, whether
    // the last player's room view mentions its partner is a race.  Measured
    // across frame counts with two clients: `--frames 13` stable over 20 runs
    // (its last step is itself a barrier), while 4, 6, 7, 8, 20 and 200 diverged
    // within five runs each, always in an `also here:` line or in a combat roll
    // that a changed number of turns had shifted.
    //
    // With it, every `quit` happens after every `look`, so the whole script is
    // reproducible for any frame count -- which is what lets README.md promise
    // that the golden file is the program, not one lucky schedule.
    if (bad == 0) {
        if (send_sync(c, fd, tx, rx, hold, goal) != 0) { bad = 1 };
    };
    // the map last: it is the big answer, and property check (c) compares the
    // client's parse of it against the server's model
    if (bad == 0) {
        client.arm_others(c, false);
        send_cmd(c, fd, tx, rx, hold, "map", "");
    };
    if (bad == 0) {
        send_cmd(c, fd, tx, rx, hold, "quit", "");
    };
    sockio.shut(fd);
    client.V_STEPS[c] = step;
    client.V_RC[c] = bad;
    done_bump();
    bad
};

// Wait for `n` clients to bump the done counter.  Bounded, so a client that died
// cannot hang the run.
def wait_done(n: long) -> long {
    let ts: [long; 2] = [0; 2];
    let spins = 0;
    let fin = 0;
    while (fin < n && spins < 12000) {
        fin = done_count();
        if (fin < n) {
            ts[0] = 0;
            ts[1] = 1000000;
            syscall(35, &ts[0], 0);
            spins = spins + 1;
        };
    };
    fin
};

// ---------------------------------------------------------------------------
// the paired script for property check (b)
// ---------------------------------------------------------------------------
//
// Two clients, run as two THREADS, both in the same room, both taking the SAME
// item instance by id.  This is the sharpest question the example can be asked
// and the one a golden file is worst at: a shared world would let exactly one of
// them have the torch, and which one would depend on thread timing.  Per-session
// worlds let both, every time.
//
// The `sync 2` on both sides is what puts them in the room together: it is a
// barrier, so neither client moves until the other has logged in.

def pair_one(c: long, port: long, inst: long, who: str,
             tx: [byte; 4096], rx: [byte; 4096], hold: [long; 2], tv: [long; 2],
             sa: [byte; 16]) -> long {
    sockio.line_reset(hold);
    client.reset(c, who, c, 2);
    let bad = 0;
    let fd = sockio.dial(sa, port);
    if (fd < 0) {
        done_bump();
        return 2;
    };
    sockio.set_timeout(fd, 20, tv);
    if (send_cmd(c, fd, tx, rx, hold, "login ", who) != 0) { bad = 1 };
    // Barrier FIRST, then the `look` that records who else is in the room.  With
    // the look after the barrier, both sessions are provably logged in before
    // either reply is built, so `+ROTH` is the same every run.  Without it, a
    // client that raced ahead to `quit` had already left the room and the other
    // saw no one -- measured, and it is why this script leads with the barrier.
    if (bad == 0) { if (send_cmd(c, fd, tx, rx, hold, "sync ", "2") != 0) { bad = 1 } };
    if (bad == 0) {
        client.arm_others(c, true);
        if (send_cmd(c, fd, tx, rx, hold, "look", "") != 0) { bad = 1 };
    };
    // the same instance, by id, from both sessions
    if (bad == 0) { if (send_cmd(c, fd, tx, rx, hold, "take ", tostring(inst)) != 0) { bad = 1 } };
    if (bad == 0) { if (send_cmd(c, fd, tx, rx, hold, "inventory", "") != 0) { bad = 1 } };
    // and a barrier before quitting, so neither can leave while the other is
    // still reading its inventory
    if (bad == 0) { if (send_cmd(c, fd, tx, rx, hold, "sync ", "2") != 0) { bad = 1 } };
    if (bad == 0) { send_cmd(c, fd, tx, rx, hold, "quit", "") };
    sockio.shut(fd);
    client.V_RC[c] = bad;
    done_bump();
    bad
};

def run_pair(port: long, ca: long, cb: long, seed: long) -> long {
    let inst = server.first_floor_inst(0);
    done_reset();
    spawn {
        let tx: [byte; 4096] = [0; 4096];
        let rx: [byte; 4096] = [0; 4096];
        let hold: [long; 2] = [0; 2];
        let tv: [long; 2] = [0; 2];
        let sa: [byte; 16] = [0; 16];
        pair_one(ca, port, inst, "ada", tx, rx, hold, tv, sa)
    };
    spawn {
        let tx: [byte; 4096] = [0; 4096];
        let rx: [byte; 4096] = [0; 4096];
        let hold: [long; 2] = [0; 2];
        let tv: [long; 2] = [0; 2];
        let sa: [byte; 16] = [0; 16];
        pair_one(cb, port, inst, "bo", tx, rx, hold, tv, sa)
    };
    wait_done(2);
    0
};

// ---------------------------------------------------------------------------
// the paired script for property check (d): chat, both ways
// ---------------------------------------------------------------------------
//
// Same barrier discipline: both log in, both sync, both say something, both sync
// AGAIN, and only then read.  The second barrier is the whole point -- it orders
// the pending-region write before the reader drains it, which is what makes the
// transcript (and this check) reproducible rather than a coin toss.

def chat_one(c: long, port: long, who: str, text: str,
             tx: [byte; 4096], rx: [byte; 4096], hold: [long; 2], tv: [long; 2],
             sa: [byte; 16]) -> long {
    sockio.line_reset(hold);
    client.reset(c, who, c, 2);
    let bad = 0;
    let fd = sockio.dial(sa, port);
    if (fd < 0) {
        done_bump();
        return 2;
    };
    sockio.set_timeout(fd, 20, tv);
    if (send_cmd(c, fd, tx, rx, hold, "login ", who) != 0) { bad = 1 };
    if (bad == 0) { if (send_cmd(c, fd, tx, rx, hold, "sync ", "2") != 0) { bad = 1 } };
    if (bad == 0) { if (send_cmd(c, fd, tx, rx, hold, "say ", text) != 0) { bad = 1 } };
    if (bad == 0) { if (send_cmd(c, fd, tx, rx, hold, "sync ", "2") != 0) { bad = 1 } };
    // one more round trip, so the pending region is drained and counted
    if (bad == 0) { if (send_cmd(c, fd, tx, rx, hold, "inventory", "") != 0) { bad = 1 } };
    if (bad == 0) { send_cmd(c, fd, tx, rx, hold, "quit", "") };
    sockio.shut(fd);
    client.V_RC[c] = bad;
    done_bump();
    bad
};

def run_chat_pair(port: long, ca: long, cb: long) -> long {
    done_reset();
    spawn {
        let tx: [byte; 4096] = [0; 4096];
        let rx: [byte; 4096] = [0; 4096];
        let hold: [long; 2] = [0; 2];
        let tv: [long; 2] = [0; 2];
        let sa: [byte; 16] = [0; 16];
        chat_one(ca, port, "ada", "greetings from ada", tx, rx, hold, tv, sa)
    };
    spawn {
        let tx: [byte; 4096] = [0; 4096];
        let rx: [byte; 4096] = [0; 4096];
        let hold: [long; 2] = [0; 2];
        let tv: [long; 2] = [0; 2];
        let sa: [byte; 16] = [0; 16];
        chat_one(cb, port, "bo", "greetings from bo", tx, rx, hold, tv, sa)
    };
    wait_done(2);
    let bad = 0;
    if (client.V_RC[ca] != 0) { bad = bad + 1 };
    if (client.V_RC[cb] != 0) { bad = bad + 1 };
    bad
};

export { NAMES, serve, stop, start_pool, run_client, build_cmd, cmd_is_look, drain, send_cmd,
         one_step, wait_done, run_pair, run_chat_pair, ps, pn,
         step_is_sync, step_is_say, step_is_look, step_count };