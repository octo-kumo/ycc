// server.y -- the accept loop, the bounded worker pool, the sessions, and the
// verbs.
//
// ===========================================================================
// WHY A SESSION OWNS A COPY OF THE WORLD
// ===========================================================================
//
// This is the decision the whole example turns on, so it is worth stating
// plainly, because the obvious design -- one shared world guarded by a mutex --
// is both slower and NON-DETERMINISTIC.
//
// The world is mutable: an item leaves the floor when somebody takes it, a
// monster's hit points go down when somebody fights it, and chat is delivered to
// everyone in a room.  If two sessions shared those, then whether alice's
// transcript said "you take the brass torch" or "there is no brass torch here"
// would depend on whether bob's thread got there first.  Two runs of
// `./mud --frames 12 --seed 1` would differ, and the golden file would be
// worthless -- not "flaky", but encoding a race.
//
// So: the world a session sees is PRIVATE to that session.  `MUT_ROOM` and
// `MUT_QTY` (which room each item instance is in, and how many are left) and
// `MUT_MHP` (each room's monster) are per-slot copies, written at login from the
// immutable world in world.y and never touched again by anyone else.  The only
// things two threads ever share are:
//
//   * the job queue (a semaphore for the hand-off and a binary semaphore for
//     the one lock, server.y below),
//   * the chat pending buffer, appended under the lock and drained at the
//     reader's next command, and
//   * the counters, under the lock.
//
// A session is served by exactly ONE worker for its whole life, so its private
// state needs no lock at all.  That is why the pool is not just an
// optimisation here: it is what makes the per-session copies safe.
//
// Two consequences worth naming, because they are the properties props.y then
// MEASURES rather than asserts:
//   * two players can both pick up the same torch, and
//   * one player dropping it does not empty the other's pack.
//
// ===========================================================================
// THE POOL, AND WHY IT IS BOUNDED
// ===========================================================================
//
// Each `spawn` leaks ~128 bytes and nothing is ever freed (ORCHESTRATOR.md
// 2.13): 2000 spawn/join cycles grew the heap by 256 000.  So the workers are
// spawned ONCE at startup -- never per connection, never per command -- and a
// connection is handed to an IDLE one with a semaphore.  `--bench 500` therefore
// costs five threads and five session slots, not 500 of either.
//
// A spawn's value is a closure, and a closure's type cannot be written down in Y
// (it is `() -> long` and `[(long) -> long]` is a different type), so the worker
// handles cannot be collected into an array and joined.  They are not joined:
// `SHUTDOWN` releases them and the process exits through exit_group(0), which
// reaps every thread at once.  That is the honest shape of the limit rather
// than a workaround hidden behind a comment.
//
// ===========================================================================
// THE PROTOCOL
// ===========================================================================
//
// Line-oriented, tag-first, one block per command, always terminated by `+END`.
// Every field is `|`-separated and every block ends `+STAT` then `+END`, so the
// client always knows when to stop reading and never has to guess a length.
//
//   +HELLO <proto> <rooms> <clients>   the answer to `login`
//   +MSG <text>                        a log line (this is the message log)
//   +ROOM <id>|<name>                  the room view opens
//   +RDESC <text>
//   +REXITS <n|e|s|w,->                -
//   +RITEM <inst>|<kind>|<name>|<qty>  ground items, one per instance
//   +ROTH <name>                       one per other session in the room
//   +CARRY <inst>|<kind>|<name>|<qty>  one per carried instance
//   +STAT <hp>|<maxhp>|<coin>|<carry>|<turn>|<room>|<msgs>
//   +MAP <rooms>|<exits>               the whole graph, for the map command
//   +MR <id>|<name>|<nexits>|<dirs>
//   +MEND
//   +BYE <text>
//   +ERR <text>
//   +END
//
// Nothing in a reply is built with `+=` on a str.  It is all appended into the
// worker's own `[byte; 4096]` and written with one write(2), so a command
// allocates nothing at all -- which is what makes `heap_used()` flat across
// hundreds of connections (README.md, "MEASUREMENTS").

// NOTE ON IMPORTS.  Every .y file in this folder compiles on its own (the
// acceptance gate builds each one), and a module's own `import` lines do not
// carry for the modules IT imports -- `import world;` here does not bring in
// the `rnd` that world.y uses.  So each file names the whole closure.
import rnd;
import net;
import world;
import sockio;

// ---- limits (each array size below must be an integer literal) -------------
const MAXS = 8;          // sessions == worker slots == peer connections
const MAXI = 72;         // item instances, world.MAXI
const MAXR = 24;         // rooms, world.MAXR
const PEND_SZ = 512;     // pending-chat bytes per session
const START_HP = 20;
const VERBMAX = 24;      // longest verb accepted

// ---- the shared pool machinery --------------------------------------------
let JOBQ = sem(0);

// THE ONE LOCK IS A BINARY SEMAPHORE, NOT A MUTEX, and that is the single
// biggest allocation decision in this program.
//
// `lock m { ... }` lowers the block to a CLOSURE and then calls it between
// `y_mutex_lock` and `y_mutex_unlock` (native.y gen_lock).  A closure is a heap
// record, so every lock costs a closure whether or not it does anything: a
// block capturing nothing measures 16 bytes a call, one captured local makes it
// 40, and each captured local ALSO becomes an 8-byte heap cell, because a cell
// has to exist for the closure to point at (SUGGESTIONS.md 10; measured again
// here: 0/1/2/3/4 captures = 16/40/64/88/112 bytes per 1000 calls = 16/40/64/
// 88/112 bytes each).  On a heap that never frees (ORCHESTRATOR.md 2.7) a
// per-command lock is a per-command leak: this server saw 136 bytes a command
// and 1 152 bytes a connection purely from locks.
//
// `sem(1)` is the same mutual exclusion with none of that.  `wait s;` and
// `post s;` are plain builtins -- `call y_sem_wait` / `call y_sem_post`, no
// record, no cell -- and y_sem_wait's read-modify-write is a full barrier, so
// the critical sections below are exactly as ordered as a mutex's.  Measured
// over 1000 critical sections: 0 bytes, and 40 000 of them across two threads
// interleaved give exactly the sum a lock-free program would.
//
// So `LM` is a semaphore used as a lock: `wait LM; ...; post LM;`.  The price,
// stated honestly: a semaphore has no owner, so a critical section that took
// `LM` twice would deadlock instead of trapping, and one that returned early
// would leave it taken.  Every section below is straight-line -- no return, no
// exit, no blocking call inside -- which is what makes the trade worth making.
let LM = sem(1);
let LFD: [long] = [0];           // the listening socket
let TV: [long; 2] = [0; 2];      // the acceptor's timespec (one acceptor)
let SHUTDOWN: [long] = [0];
let SYNC_GOAL: [long] = [2];
let BAR_N: [long] = [0];         // arrivals in the current round
let BAR_GEN: [long] = [0];       // bumped when a round opens

// ---- session slots --------------------------------------------------------
let S_FD: [long; 8] = [0; 8];
let S_STATE: [long; 8] = [0; 8];     // 0 free, 1 pending a worker, 2 being served
// The name is BYTES in a fixed per-slot buffer, not a str.  It used to be a
// `str`, and that was the last per-session allocation on the server side: one
// from_bytes() per login, which `--bench` shows as a steady climb of roughly 80
// bytes a connection.  Names are compared a byte at a time (name_eq) and rendered
// straight out of the buffer (pnm), so nothing on the login path ever needs a
// str -- and eight slots of 32 bytes is 256 bytes for the whole feature.
//
// (A name is at most 12 characters: see name_ok.)
let S_NAME: [byte; 256] = [0; 256];
let S_NLEN: [long; 8] = [0; 8];
let S_ROOM: [long; 8] = [0; 8];
let S_HP: [long; 8] = [0; 8];
let S_MHP: [long; 8] = [0; 8];
let S_COIN: [long; 8] = [0; 8];
let S_TURN: [long; 8] = [0; 8];
let S_MSG: [long; 8] = [0; 8];
let S_ON: [long; 8] = [0; 8];        // has logged in
let S_QUIT: [long; 8] = [0; 8];
let S_RNG: [long; 8] = [0; 8];       // the session's own generator

// ---- per-session copies of the mutable world (flat, indexed slot*MAXI + i) --
let MUT_ROOM: [long; 576] = [0; 576];
let MUT_QTY: [long; 576] = [0; 576];
let MUT_MHP: [long; 192] = [0; 192];

// ---- pending chat, one 512-byte region per session, flat ------------------
// TWO regions per session, both flat: PEND is the live one that say_fanout
// appends to, PEND2 is the one `sync` copies it into before it arrives at a
// barrier.  See "CHAT IS DELIVERED AT A BARRIER" below for why there are two.
let PEND: [byte; 4096] = [0; 4096];
let PEND2: [byte; 4096] = [0; 4096];
let PEND_N: [long; 8] = [0; 8];
let PEND2_N: [long; 8] = [0; 8];
const MSG_TAG = "+MSG ";
const MSG_N = 5;
const SAYS_TAG = " says: ";
const SAYS_N = 7;

// ---- counters the summary prints ------------------------------------------
// EVERY COUNTER IS PER SLOT, indexed by session, and summed on demand.
//
// They used to be globals guarded by a `lock`, which put a lock on the hot
// path of every single verb.  Two things are now true instead.  A counter
// owned by a slot needs no lock at all: a session is served by exactly ONE
// worker for its whole life (see the pool above), so there is one writer and
// the reader adds the slots up -- total() does the summing.  And even where a
// lock IS needed, `wait LM; ...; post LM;` is free where `lock LM { ... }` was
// a closure a time (see LM above), so the remaining sections are there for
// ordering, not for the counter.  The counters that genuinely span sessions --
// N_CONN, N_CONN_NOW, N_PEAK -- stay global, and they are only touched on
// connect and disconnect.
let C_CMD: [long; 8] = [0; 8];
let C_TURN: [long; 8] = [0; 8];
let C_SAY: [long; 8] = [0; 8];
let C_ERR: [long; 8] = [0; 8];
let C_LONG: [long; 8] = [0; 8];
let C_TRUNC: [long; 8] = [0; 8];

let N_CONN: [long] = [0];       // sessions served
let N_CONN_NOW: [long] = [0];
let N_PEAK: [long] = [0];

def total(c: [long; 8]) -> long {
    let s = 0;
    let i = 0;
    while (i < 8) { s = s + c[i]; i = i + 1 };
    s
};
def n_cmd() -> long { total(C_CMD) };
def n_turn() -> long { total(C_TURN) };
def n_say() -> long { total(C_SAY) };
def n_err() -> long { total(C_ERR) };
def n_long() -> long { total(C_LONG) };
def n_trunc() -> long { total(C_TRUNC) };
// Heap accounting per worker thread.  heap_used() reads %fs, so it can only be
// sampled from INSIDE the thread -- that is why these two exist.  WK_GROW is the
// thread's cumulative growth since it started (monotone, so the difference
// between two samples is that thread's growth over the interval) and WK_PEAK is
// the worst single-session growth, which is what a per-connection leak would
// show up in.
let WK_GROW: [long; 8] = [0; 8];
let WK_PEAK: [long; 8] = [0; 8];

// ---------------------------------------------------------------------------
// short spellings for the ~300 lines of reply text below.  Y has no function
// values, so these are defs, not aliases -- but they keep each append to one
// short call instead of a wrapped line.
// ---------------------------------------------------------------------------
def ps(b: [byte; 4096], n: long, s: str) -> long { sockio.obs(b, n, s) };
def pn(b: [byte; 4096], n: long, v: long) -> long { sockio.obn(b, n, v) };
def pc(b: [byte; 4096], n: long, c: long) -> long { sockio.ob(b, n, c) };
def pnl(b: [byte; 4096], n: long) -> long { sockio.ob(b, n, 10) };
def pbar(b: [byte; 4096], n: long) -> long { sockio.ob(b, n, 124) };

// ---------------------------------------------------------------------------
// the session's own generator
// ---------------------------------------------------------------------------
// rnd.y's generator is module-global state; a session must NOT share it (that is
// the whole reason sessions are separate), so the step is spelled out again
// here against the session's own slot.  Same constants, same shift.
def srng(slot: long) -> long {
    S_RNG[slot] = S_RNG[slot] * 6364136223846793005 + 1442695040888963407;
    S_RNG[slot]
};
def srng_below(slot: long, n: long) -> long {
    let u = (srng(slot) >> 33) & 0x7fffffff;
    if (u < 0 || n <= 0) { 0 } else { u % n }
};

// ---------------------------------------------------------------------------
// byte-level command parsing, out of the worker's own [byte; 4096]
// ---------------------------------------------------------------------------
// A MUD command is a verb and at most two words, and a session may send a
// thousand of them a second.  Every parser below works on bytes in the worker's
// line buffer and NEVER builds a str, so a command costs zero bytes of heap.
// (Contrast `from_bytes(buf[a:z])`: one ~48-byte allocation per command, which
// over 500 bench connections is 25 000 bytes of pure leak.)

def skip_sp(b: [byte; 4096], a: long, n: long) -> long {
    let i = a;
    while (i < n && b[i] == 32) { i = i + 1 };
    i
};
def word_end(b: [byte; 4096], a: long, n: long) -> long {
    let i = a;
    while (i < n && b[i] != 32) { i = i + 1 };
    i
};
// does the byte range [a, z) spell exactly s?
def weq(b: [byte; 4096], a: long, z: long, s: str) -> bool {
    let ok = z - a == len(s);
    let i = 0;
    while (i < len(s) && ok) {
        if (b[a + i] != s[i]) { ok = false };
        i = i + 1;
    };
    ok
};
// [a, z) as a decimal long, or -1 when it is not one
def wnum(b: [byte; 4096], a: long, z: long) -> long {
    if (z <= a) { 0 - 1 } else {
        let v = 0;
        let i = a;
        let ok = true;
        while (i < z) {
            let c = b[i];
            if (c < 48 || c > 57) { ok = false } else { v = v * 10 + (c - 48) };
            i = i + 1;
        };
        if (ok) { v } else { 0 - 1 }
    }
};

// ---------------------------------------------------------------------------
// pending chat
// ---------------------------------------------------------------------------
// Chat is NOT written to another session's socket from this thread.  It is
// appended to the recipient's own pending region under the mutex and drained at
// the top of that session's next reply block.  Two reasons: two threads writing
// one socket can interleave a partial line, and draining at a command boundary
// is a fixed, reproducible point in the stream -- which is what lets the golden
// file contain chat at all.

// Copy a string into dst at absolute offset `at`; returns HOW MANY BYTES it
// wrote, not the new absolute offset.  Returning the offset looked reasonable
// and was the bug: the caller was tracking an offset RELATIVE to its slot's
// region, so the second append landed at base+base+n -- a whole region's worth
// of NUL bytes before the text, and the text itself past the end of the slot.
// Every length in pend_add_locked comes from this function now, and every
// addition is a count.
// pnm: append a session's name, straight out of its fixed byte buffer.  There is
// no str of the name anywhere, so rendering one costs nothing.
def pnm(b: [byte; 4096], n: long, slot: long) -> long {
    let base = slot * 32;
    let i = 0;
    let k = n;
    while (i < S_NLEN[slot]) {
        k = sockio.ob(b, k, S_NAME[base + i]);
        i = i + 1;
    };
    k
};

// set_name: keep the name from the command buffer, at most 31 bytes (name_ok
// has already refused anything over 12).
def set_name(slot: long, ib: [byte; 4096], a: long, z: long) -> long {
    let base = slot * 32;
    let n = 0;
    let i = a;
    while (i < z && n < 31) {
        S_NAME[base + n] = ib[i];
        n = n + 1;
        i = i + 1;
    };
    S_NLEN[slot] = n;
    n
};

def name_len(slot: long) -> long { S_NLEN[slot] };

// Does slot j's name equal the word spelled at ib[a .. z)?
//
// Straight out of the caller's line buffer: there is no copy, and no scratch.
// There USED to be a module buffer the candidate name was copied into before
// taking the lock, and it had to be PER SLOT -- one shared buffer was a data
// race, two clients logging in on two workers both wrote it before either took
// the lock, so one compared the other's name.  That was forced by the lock: a
// `[byte; 4096]` parameter had to cross INTO the lock block, and a block cannot
// capture a per-call buffer.  `wait LM; ...; post LM;` has no such rule, so the
// scan reads the caller's own buffer and the copy, and its scratch, are gone.
def name_eq_bytes(j: long, ib: [byte; 4096], a: long, z: long) -> bool {
    if (S_NLEN[j] != z - a) { false } else {
        let base = j * 32;
        let i = 0;
        let ok = true;
        while (i < z - a && ok) {
            if (S_NAME[base + i] != ib[a + i]) { ok = false };
            i = i + 1;
        };
        ok
    }
};

def pcopy(dst: [byte; 4096], at: long, s: str) -> long {
    let i = 0;
    let k = 0;
    while (i < len(s)) { dst[at + k] = s[i]; i = i + 1; k = k + 1 };
    k
};

def pend_add_locked(slot: long, from: long, txt: [byte; 4096], a: long, z: long) -> long {
    let base = slot * PEND_SZ;
    let nbase = from * 32;
    // Every length is a NAMED constant or a measured len() -- never a hand-counted
    // 7 for "+MSG ", which is FIVE bytes.  That wrote one byte past the constant
    // and trapped with `index out of bounds` on the first `say` two players
    // shared, and only then, because with one session nobody is ever addressed.
    let head = MSG_N + S_NLEN[from] + SAYS_N + 1;
    let n = 0;
    {
        n = PEND_N[slot];
        if (n + head + (z - a) <= PEND_SZ) {
            n = n + pcopy(PEND, base + n, MSG_TAG);
            let k = 0;
            while (k < S_NLEN[from]) {
                PEND[base + n] = S_NAME[nbase + k];
                n = n + 1;
                k = k + 1;
            };
            n = n + pcopy(PEND, base + n, SAYS_TAG);
            let j = a;
            while (j < z) { PEND[base + n] = txt[j]; n = n + 1; j = j + 1 };
            PEND[base + n] = 10;
            n = n + 1;
            PEND_N[slot] = n;
        };
    };
    n
};

// pend_add_locked is called with the lock ALREADY HELD (by say_fanout, which is
// scanning every slot).  The lock is a semaphore used as a lock (see LM), so it
// is not reentrant and taking it again inside would deadlock -- which is why the
// "locked" is in the name rather than in a comment nobody reads.
//
// It takes the text as an ordinary parameter, which only became possible when
// the lock stopped being a closure: see name_eq_bytes for the whole story.
//
// ---------------------------------------------------------------------------
// CHAT: STAGED, THEN PROMOTED BY THE BARRIER THAT OPENS
// ---------------------------------------------------------------------------
//
// This is the second half of the determinism argument (the first half is the
// generation barrier itself, below).  It took three attempts and the first two
// were both of the same shape: WHICH command's reply carried the chat line was a
// coin toss, measured, not guessed.
//
// Attempt 1 -- drain the pending region at the END of every command.  2 of 5 runs
// of `--frames 13 --seed 1` were identical; the rest put the message in a
// different block, sometimes in the sender's own `say` reply and sometimes in the
// recipient's next `move`.  A drain in a command nothing orders is a drain in a
// race.
//
// Attempt 2 -- drain only at `sync`, right after the barrier OPENS.  Everything
// queued before the opening is certainly there (a `say` precedes its own player's
// arrival, and the opening follows every arrival).  But the window between "the
// barrier opened" and "I drained" is wide open: the other worker is released at
// the same instant and its next command may be a `say`, so whether that message
// was in my region when I drained is unordered.  Measured: 3 of 14 runs
// delivered the chat one barrier late.
//
// Attempt 3, and what is here: THE BARRIER PROMOTES, THE CLIENT DRAINS.
//
//   PEND    is a STAGING area.  say_fanout appends there and nothing reads it.
//   PEND2   is the DELIVERABLE area.  The participant whose arrival OPENS the
//           round moves every session's staging bytes into its deliverable area,
//           inside the one critical section that opens the round.
//
// After the opening, each session's deliverable bytes are FROZEN: the promotion
// happened under the lock, and the next `say` goes to the staging area, not to
// the deliverable one.  So a session may drain whenever it likes -- it reads a
// set that can no longer change -- and which command's reply carries the chat is
// decided by the barrier, not by who drained first.  That is the whole fix, and
// it is why the step table does not have to be arranged around the chat at all
// (driver.y, check (e) in props.y).
//
// Two consequences, stated rather than hidden:
//   * a session that never sends `sync` never sees chat, because only a barrier
//     promotes.  Only `--live` pays that, and it runs one client with nobody to
//     talk to;
//   * a barrier that TIMES OUT promotes nothing, so its reply carries no chat and
//     the messages wait for the next barrier that does open.  That is the honest
//     behaviour when the ordering has already been lost.
//
// The count is only taken when the drain actually found something: counting
// every drain made `msgs` read 1 on a client that had heard nothing at all, and
// that number is what property check (d) asserts on -- a check that cannot fail.

// pend_promote: move every session's staging bytes into its deliverable bytes.
// Called with the lock HELD, from the one section that opens a round -- that is
// the whole reason it is here and not in do_sync.  Eight slots and a 512-byte
// region each, and only the sessions that actually have something are copied.
def pend_promote() -> long {
    let k = 0;
    while (k < MAXS) {
        let cnt = PEND_N[k];
        if (cnt > 0) {
            let base = k * PEND_SZ;
            let i = 0;
            while (i < cnt) {
                PEND2[base + i] = PEND[base + i];
                i = i + 1;
            };
            PEND2_N[k] = PEND2_N[k] + cnt;
            PEND_N[k] = 0;
        };
        k = k + 1;
    };
    0
};

// pend_drain: append this session's DELIVERABLE bytes to the reply and clear
// them.  No lock: PEND2's row belongs to this session's own worker, and the
// bytes in it were frozen by the promotion.  `held` is a parameter rather than
// something read back out of PEND2_N, so the append and the reply length cannot
// disagree -- an earlier version read PEND2_N here and was called as
// `pend_unstash(slot, b, pend_stash(slot))`, which threw the reply's own length
// away, truncated every `sync` reply to what followed the barrier line, and left
// the client's read-until-`+END` loop desynchronised.  Found by logging one
// reply per command and noticing a `sync` answered with a bare `+STAT`.
def pend_drain(slot: long, b: [byte; 4096], n: long, held: long) -> long {
    if (held > 0) { S_MSG[slot] = S_MSG[slot] + 1 };
    let base = slot * PEND_SZ;
    let k = n;
    let i = 0;
    while (i < held) {
        b[k] = PEND2[base + i];
        k = k + 1;
        i = i + 1;
    };
    PEND2_N[slot] = 0;
    k
};

// cmd_count: the per-session command tally.  It is a def of its own for the same
// reason the counters are per slot (see above): one writer, no lock, no closure.
def cmd_count(slot: long) -> long {
    C_CMD[slot] = C_CMD[slot] + 1;
    0
};

// ---------------------------------------------------------------------------
// session setup
// ---------------------------------------------------------------------------

def init_session(slot: long, fd: long, seed: long, tv: [long; 2]) -> long {
    S_FD[slot] = fd;
    S_ROOM[slot] = 0;
    S_HP[slot] = START_HP;
    S_MHP[slot] = START_HP;
    S_COIN[slot] = 0;
    S_TURN[slot] = 0;
    S_MSG[slot] = 0;
    S_ON[slot] = 0;
    S_QUIT[slot] = 0;
    S_NLEN[slot] = 0;
    PEND_N[slot] = 0;
    PEND2_N[slot] = 0;
    // a per-session stream: distinct from every other slot's, and stable for a
    // given (seed, slot), so combat rolls are reproducible
    S_RNG[slot] = seed * 2654435761 + slot * 40503 + 1;
    if (S_RNG[slot] == 0) { S_RNG[slot] = 1 };
    let i = 0;
    while (i < world.insts()) {
        MUT_ROOM[slot * MAXI + i] = world.i_room(i);
        MUT_QTY[slot * MAXI + i] = world.i_qty(i);
        i = i + 1;
    };
    let r = 0;
    while (r < world.rooms()) {
        MUT_MHP[slot * MAXR + r] = world.m_hp(r);
        r = r + 1;
    };
    sockio.set_timeout(fd, 30, tv);
    0
};

// account: record what one served session cost the worker thread's heap, and
// count the connection.
//
// heap_used() reads %fs, so it can ONLY be sampled from inside the thread that
// owns the heap -- which is why this exists at all, and why the caller passes the
// two deltas in rather than the main thread reading them afterwards.
let D_A: [long; 8] = [0; 8];
let D_B: [long; 8] = [0; 8];
let D_C: [long; 8] = [0; 8];
let D_D: [long; 8] = [0; 8];
def account(k: long, grew: long, cum: long) -> long {
    wait LM;
    if (grew > WK_PEAK[k]) { WK_PEAK[k] = grew };
    WK_GROW[k] = cum;
    N_CONN[0] = N_CONN[0] + 1;
    post LM;
    0
};

// claim_slot: take the lowest slot that is PENDING a worker, and mark it being
// served.  This runs once per wake-up, which is once per connection in the
// steady state.
def claim_slot() -> long {
    let got = 0 - 1;
    wait LM;
    let i = 0;
    while (i < MAXS) {
        if (got < 0 && S_STATE[i] == 1) { got = i };
        i = i + 1;
    };
    if (got >= 0) { S_STATE[got] = 2 };
    post LM;
    got
};

// release_slot: the session is over, so the slot is free again.
def release_slot(slot: long) -> long {
    wait LM;
    S_STATE[slot] = 0;
    S_ON[slot] = 0;
    S_NLEN[slot] = 0;
    N_CONN_NOW[0] = N_CONN_NOW[0] - 1;
    post LM;
    0
};

// The lowest-numbered item instance lying on the floor of room 0, or -1.  Used by
// property check (b): both players take THIS instance by id, so the check is about
// sharing rather than about which item happened to be first.
def first_floor_inst(room: long) -> long {
    let i = 0;
    let ans = 0 - 1;
    while (i < world.insts()) {
        if (ans < 0 && world.i_room(i) == room && world.i_qty(i) > 0) { ans = i };
        i = i + 1;
    };
    ans
};

// ---------------------------------------------------------------------------
// the acceptor: the one blocking loop, bounded by a connection count
// ---------------------------------------------------------------------------

def acceptor(want: long, seed: long) -> long {
    let got = 0;
    let go = true;
    let ob: [byte; 4096] = [0; 4096];     // hoisted: a literal inside the loop
    let hold: [long; 2] = [0; 2];
    sockio.line_reset(hold);
    while (go) {
        let fd = net.accept_tcp(LFD[0]);
        if (fd < 0) {
            go = false;
        } else {
            let slot = 0 - 1;
            wait LM;
            let i = 0;
            while (i < MAXS) {
                if (slot < 0 && S_STATE[i] == 0) { slot = i };
                i = i + 1;
            };
            if (slot >= 0) {
                S_STATE[slot] = 1;          // reserved: no worker can see it
                N_CONN_NOW[0] = N_CONN_NOW[0] + 1;
                if (N_CONN_NOW[0] > N_PEAK[0]) { N_PEAK[0] = N_CONN_NOW[0] };
            };
            post LM;
            if (slot < 0) {
                // every slot is busy.  Say so on the wire and close: refusing a
                // connection must not be silent and must not trap.
                let n = ps(ob, 0, "+ERR the inn is full; try again shortly\n+BYE full\n+END\n");
                sockio.send_buf(fd, ob, n);
                sockio.shut(fd);
                // no slot to attribute this to, so it goes in the acceptor's own
                // per-slot counter -- the acceptor is one thread, so slot 0's row
                // is its row
                C_ERR[0] = C_ERR[0] + 1;
                got = got + 1;
                if (got >= want) { go = false };
            } else {
                // the acceptor's own timespec: one buffer, reused for every
                // session, because the acceptor is a single thread
                init_session(slot, fd, seed, TV);
                post JOBQ;
                got = got + 1;
                if (got >= want) { go = false };
            };
        };
    };
    got
};

// ---------------------------------------------------------------------------
// the worker: one thread, many sessions, forever
// ---------------------------------------------------------------------------

def serve(slot: long, ib: [byte; 4096], ob: [byte; 4096], hold: [long; 2], nslp: [long; 2]) -> long {
    sockio.line_reset(hold);
    let live = true;
    while (live) {
        let pk = sockio.line_get(S_FD[slot], ib, hold);
        if (pk == 0 - 2) {
            // an over-long line: say so and carry on, rather than treating the
            // negative as EOF and hanging up on a client that sent one long line
            C_TRUNC[slot] = C_TRUNC[slot] + 1;
            let tn = ps(ob, 0, "+ERR that line is too long; the limit is 4095 bytes\n");
            sockio.send_buf(S_FD[slot], ob, tn);
        } else if (pk < 0) {
            live = false;
        } else {
            // line_get returns an OFFSET; line_fetch brings the line to byte 0,
            // which is where the command parser reads from
            let ln = sockio.line_fetch(ib, pk);
            let q1 = heap_used();
            let rn = command(slot, ib, ln, ob, nslp);
            let q2 = heap_used();
            // a client that hangs up mid-reply is an ERROR ON THAT SESSION, not
            // the end of the process: sendto(MSG_NOSIGNAL) turns what used to be
            // SIGPIPE into -32, and the session is simply finished here.  The
            // other five sessions keep playing, which is the point.
            let sent = sockio.send_buf(S_FD[slot], ob, rn);
            let q3 = heap_used();
            if (sockio.send_failed(sent)) {
                C_ERR[slot] = C_ERR[slot] + 1;
                live = false;
            };
            if (q2 > q1 || q3 > q2) {
                wait LM;
                D_A[slot] = D_A[slot] + (q2 - q1);
                D_B[slot] = D_B[slot] + (q3 - q2);
                post LM
            };
            if (S_QUIT[slot] == 1) { live = false };
        };
    };
    sockio.shut(S_FD[slot]);
    let q4 = heap_used();
    let q5 = heap_used();
    wait LM;
    D_D[slot] = D_D[slot] + (q5 - q4);
    post LM;
    0
};

def worker(k: long) -> long {
    // allocated ONCE per thread, not once per connection and not once per
    // command -- that is the whole allocation story of this program
    let ib: [byte; 4096] = [0; 4096];
    let ob: [byte; 4096] = [0; 4096];
    let hold: [long; 2] = [0; 2];
    // the barrier spin's timespec: one per THREAD, never one per command
    let nslp: [long; 2] = [0; 2];
    let g0 = heap_used();
    let running = true;
    while (running) {
        wait JOBQ;
        let slot = claim_slot();
        if (slot >= 0) {
            let s0 = heap_used();
            D_C[slot] = s0;
            serve(slot, ib, ob, hold, nslp);
            // One critical section for the whole session: it records the heap,
            // which is a thread-local read, so the sample has to happen HERE, and
            // it counts the connection.  (It used to take two, because two
            // `lock` blocks were two closures.)
            let grew = heap_used() - s0;
            account(k, grew, heap_used() - g0);
            release_slot(slot);
        } else {
            // A wake-up with no work is the shutdown token.  It cannot happen
            // otherwise: one post per pending slot, one claim per post.
            if (SHUTDOWN[0] == 1) { running = false };
        };
    };
    0
};

// ---------------------------------------------------------------------------
// the reply blocks
// ---------------------------------------------------------------------------

def alive(slot: long) -> bool { S_HP[slot] > 0 };

def carry_count(slot: long) -> long {
    let n = 0;
    let i = 0;
    while (i < world.insts()) {
        if (MUT_ROOM[slot * MAXI + i] == 0 - 1 && MUT_QTY[slot * MAXI + i] > 0) {
            n = n + 1;
        };
        i = i + 1;
    };
    n
};

def msg(b: [byte; 4096], n: long, s: str) -> long {
    n = ps(b, n, "+MSG ");
    n = ps(b, n, s);
    pnl(b, n)
};

// The status line and the block terminator.  EVERY reply ends with these two
// lines, which is what lets the client read until `+END` and never guess.
def stat_block(slot: long, b: [byte; 4096], n: long) -> long {
    n = ps(b, n, "+STAT ");
    n = pn(b, n, S_HP[slot]); n = pbar(b, n);
    n = pn(b, n, S_MHP[slot]); n = pbar(b, n);
    n = pn(b, n, S_COIN[slot]); n = pbar(b, n);
    n = pn(b, n, carry_count(slot)); n = pbar(b, n);
    n = pn(b, n, S_TURN[slot]); n = pbar(b, n);
    n = pn(b, n, S_ROOM[slot]); n = pbar(b, n);
    n = pn(b, n, S_MSG[slot]);
    n = pnl(b, n);
    n = ps(b, n, "+END");
    pnl(b, n)
};

def carry_list(slot: long, b: [byte; 4096], n: long) -> long {
    let i = 0;
    let any = 0;
    while (i < world.insts()) {
        if (MUT_ROOM[slot * MAXI + i] == 0 - 1 && MUT_QTY[slot * MAXI + i] > 0) {
            n = ps(b, n, "+CARRY "); n = pn(b, n, i); n = pbar(b, n);
            n = pn(b, n, world.i_id(i)); n = pbar(b, n);
            n = ps(b, n, world.item_name(world.i_id(i))); n = pbar(b, n);
            n = pn(b, n, MUT_QTY[slot * MAXI + i]);
            n = pnl(b, n);
            any = any + 1;
        };
        i = i + 1;
    };
    if (any == 0) { n = ps(b, n, "+CARRY -") ; n = pnl(b, n) };
    n
};

// The room the session is standing in: name, description, exits, what is on the
// floor, who else is here.  It also carries the carry list, so one round trip
// gives a client everything it needs to choose its next command.
def room_view(slot: long, b: [byte; 4096], n: long) -> long {
    let r = S_ROOM[slot];
    n = ps(b, n, "+ROOM "); n = pn(b, n, r); n = pbar(b, n);
    n = ps(b, n, world.name(r)); n = pbar(b, n);
    n = pn(b, n, world.lx(r)); n = pbar(b, n); n = pn(b, n, world.ly(r));
    n = pnl(b, n);
    // +REXITS BEFORE +RDESC, deliberately: the client draws the room header on
    // the last of the header's inputs, so the directions have to arrive before
    // the description that follows them.
    n = ps(b, n, "+REXITS ");
    let d = 0;
    let any = 0;
    while (d < 4) {
        if (world.ex_to(r, d) >= 0) {
            if (any > 0) { n = pc(b, n, 44) };
            n = ps(b, n, world.dir_abbr(d));
            any = any + 1;
        };
        d = d + 1;
    };
    if (any == 0) { n = ps(b, n, "-") };
    n = pnl(b, n);
    n = ps(b, n, "+RDESC "); n = ps(b, n, world.desc(r)); n = pnl(b, n);
    let got = 0;
    let i = 0;
    while (i < world.insts()) {
        if (MUT_ROOM[slot * MAXI + i] == r && MUT_QTY[slot * MAXI + i] > 0) {
            n = ps(b, n, "+RITEM "); n = pn(b, n, i); n = pbar(b, n);
            n = pn(b, n, world.i_id(i)); n = pbar(b, n);
            n = ps(b, n, world.item_name(world.i_id(i))); n = pbar(b, n);
            n = pn(b, n, MUT_QTY[slot * MAXI + i]);
            n = pnl(b, n);
            got = got + 1;
        };
        i = i + 1;
    };
    if (got == 0) { n = ps(b, n, "+RITEM -"); n = pnl(b, n) };
    // the monster, if this room has one, so a client can name it for `attack`
    let mk = world.m_kind(r);
    if (mk >= 0 && MUT_MHP[slot * MAXR + r] > 0) {
        n = ps(b, n, "+RMON "); n = pn(b, n, mk); n = pbar(b, n);
        n = ps(b, n, world.mon_name(mk)); n = pbar(b, n);
        n = pn(b, n, MUT_MHP[slot * MAXR + r]);
        n = pnl(b, n);
    } else {
        n = ps(b, n, "+RMON -"); n = pnl(b, n);
    };
    // who else is standing here -- the one thing that IS shared between
    // sessions, and the reason two players in a room can find each other
    // Check before taking the section: a `+ROTH` line is only worth building
    // when somebody else is logged in, and the scan of S_ON is a plain read.
    if (others_here(slot, r) > 0) { n = draw_others(slot, b, n) };
    n = carry_list(slot, b, n);
    n
};

// `map`: the whole graph, so a client can build its own picture and check it
// against the server's (that is property check (c) in props.y).
def map_block(slot: long, b: [byte; 4096], n: long) -> long {
    n = ps(b, n, "+MAP "); n = pn(b, n, world.rooms()); n = pbar(b, n);
    n = pn(b, n, world.exits_total()); n = pnl(b, n);
    let r = 0;
    while (r < world.rooms()) {
        n = ps(b, n, "+MR "); n = pn(b, n, r); n = pbar(b, n);
        n = ps(b, n, world.name(r)); n = pbar(b, n);
        n = pn(b, n, world.ex_n(r)); n = pbar(b, n);
        let d = 0;
        let got = 0;
        while (d < 4) {
            if (world.ex_to(r, d) >= 0) {
                if (got > 0) { n = pc(b, n, 44) };
                n = ps(b, n, world.dir_abbr(d));
                got = got + 1;
            };
            d = d + 1;
        };
        if (got == 0) { n = pc(b, n, 45) };
        n = pbar(b, n);
        n = pn(b, n, world.lx(r)); n = pbar(b, n);
        n = pn(b, n, world.ly(r));
        n = pnl(b, n);
        r = r + 1;
    };
    n = ps(b, n, "+MEND"); n = pnl(b, n);
    n
};

// OTHERS: the slots sharing `room` with `slot`, found under the lock.
//
// THE LOCK RETURNS INDICES, NOT TEXT.  Formatting `+ROTH` inside the critical
// section would hold the one lock while building reply text, which is wrong on
// its own terms: the section is O(slots) and the formatting is O(bytes).  So the
// section leaves a list of slot numbers and draw_others renders it afterwards.
// PER SLOT, again: `OTHERS` indexed by the caller's slot is written by one worker
// and read by that same worker, so there is nothing to race.  A single shared
// list would be two threads appending to one array.
let OTHERS: [long; 64] = [0; 64];
let NOTHER: [long; 8] = [0; 8];

def list_others(slot: long, r: long) -> long {
    let n = 0;
    wait LM;
    let j = 0;
    while (j < MAXS) {
        if (j != slot && S_ON[j] == 1 && S_ROOM[j] == r) {
            OTHERS[slot * MAXS + n] = j;
            n = n + 1;
        };
        j = j + 1;
    };
    post LM;
    NOTHER[slot] = n;
    n
};

// draw_others: the `+ROTH` lines, rendered OUTSIDE the section, from the indices
// list_others left.  Two rounds, because the client overwrites its slot on each
// line (the last one seen is the one it shows) and a scan would otherwise read a
// slot number the render had already clobbered.
def draw_others(slot: long, b: [byte; 4096], n: long) -> long {
    let k = n;
    let count = list_others(slot, S_ROOM[slot]);
    let i = 0;
    while (i < count) {
        k = ps(b, k, "+ROTH "); k = pnm(b, k, OTHERS[slot * MAXS + i]); k = pnl(b, k);
        i = i + 1;
    };
    k
};

// How many OTHER sessions are logged in and standing in `room`?  A plain read of
// S_ON, used to decide whether a critical section is worth entering at all.
def others_here(slot: long, room: long) -> long {
    let n = 0;
    let k = 0;
    while (k < MAXS) {
        if (k != slot && S_ON[k] == 1 && S_ROOM[k] == room) { n = n + 1 };
        k = k + 1;
    };
    n
};

// anyone at all logged in?
def anyone_on() -> long {
    let n = 0;
    let k = 0;
    while (k < MAXS) {
        if (S_ON[k] == 1) { n = n + 1 };
        k = k + 1;
    };
    n
};

// list_who: the locked half of `who`, its own function for the same reason as
// list_others -- the WHO lines are rendered outside the section, and the check
// that anybody is logged in at all happens before it (who_block).
let WHO_N: [long; 8] = [0; 8];

def list_who(slot: long) -> long {
    let n = 0;
    wait LM;
    let j = 0;
    while (j < MAXS) {
        if (S_ON[j] == 1) {
            OTHERS[slot * MAXS + n] = j;
            n = n + 1;
        };
        j = j + 1;
    };
    post LM;
    WHO_N[slot] = n;
    n
};

def draw_who(slot: long, b: [byte; 4096], n: long) -> long {
    let k = n;
    let count = list_who(slot);
    let i = 0;
    while (i < count) {
        let j = OTHERS[slot * MAXS + i];
        k = ps(b, k, "+WHOW "); k = pnm(b, k, j); k = pbar(b, k);
        k = pn(b, k, S_ROOM[j]); k = pbar(b, k);
        k = pn(b, k, S_TURN[j]); k = pnl(b, k);
        i = i + 1;
    };
    k
};

def who_block(slot: long, b: [byte; 4096], n: long) -> long {
    let on = anyone_on();
    n = ps(b, n, "+WHO "); n = pn(b, n, on); n = pnl(b, n);
    if (on > 0) { n = draw_who(slot, b, n) };
    n
};

// ---------------------------------------------------------------------------
// sync: the rendezvous that makes concurrent play reproducible
// ---------------------------------------------------------------------------
//
// `sync n` blocks until n sessions have arrived, then releases all of them.  It
// is what makes chat and the two-client property checks deterministic: a client
// that has just said something waits at a second barrier before reading again,
// and by then the write into the other client's pending region has definitely
// happened.  Without it, "did bob's greeting arrive before or after alice's
// next command" is a coin toss, and a coin toss cannot go in a golden file.
//
// THE IMPLEMENTATION IS A GENERATION BARRIER, and getting this wrong is subtle
// enough to be worth spelling out.  The obvious "ticket t waits for REL > t" is
// NOT a barrier at all: with two participants and want=2, the first waits for
// REL > 1 and the second waits for REL > 2, and the second can only set
// REL = 2 after passing -- so BOTH time out.  (Measured: every `sync` cost three
// seconds and every run ended in SIGPIPE, exit 141.)
//
// What works: read the generation, count yourself in, and the participant whose
// arrival completes the round bumps the generation and clears the count.  Every
// waiter is watching the generation it saw on entry, so a fast participant
// cannot miss the release, and a round that is short (a client died) releases on
// the bounded spin instead of hanging.

// The two halves of the barrier, each in its own function so the spin loop below
// reads as what it is: arrive once, then poll.  The values that cross the
// critical section are ordinary parameters and ordinary locals now -- they were
// module scratch (`BAR_MINE`, `BAR_OPEN`, `BAR_WANT`) only because a `lock` block
// is a closure and a closure cannot be handed a local for free.
//
// THE SECTION THAT OPENS THE ROUND ALSO PROMOTES THE CHAT.  That is the whole
// determinism mechanism, and it is one line here for a reason: the promotion has
// to happen inside the same critical section that bumps the generation, because
// that is the only moment at which "everything said before this barrier" and
// "nothing said after it" are both true.  See "CHAT: STAGED, THEN PROMOTED".
def bar_arrive(want: long) -> long {
    let mine = 0;
    wait LM;
    mine = BAR_GEN[0];
    BAR_N[0] = BAR_N[0] + 1;
    if (BAR_N[0] >= want) {
        BAR_N[0] = 0;
        BAR_GEN[0] = BAR_GEN[0] + 1;
        pend_promote();
    };
    post LM;
    mine
};

def bar_opened(mine: long) -> bool {
    let open = false;
    wait LM;
    if (BAR_GEN[0] != mine) { open = true };
    post LM;
    open
};

// nslp is the spin's timespec, and it is the CALLER's: a local `let ts: [long; 2]
// = [0; 2]` inside the loop is a 24-byte heap allocation per iteration (a local
// array literal is an allocation), and how many iterations a barrier takes is
// timing -- so it was the last nondeterministic number in the run: the summary's
// "worker heap growth" read 168 on one run and 280 on the next, and nothing else
// differed.  One buffer per worker thread, handed down from worker -> serve ->
// command -> here, the same way the line buffers are.
def do_sync(slot: long, want: long, b: [byte; 4096], n: long, nslp: [long; 2]) -> long {
    let mine = bar_arrive(want);
    let spins = 0;
    let open = 0;
    while (spins < 150 && open == 0) {
        if (bar_opened(mine)) { open = 1 } else {
            nslp[0] = 0;
            nslp[1] = 20000000;                 // 20 ms
            syscall(35, &nslp[0], 0);
            spins = spins + 1;
        };
    };
    if (open == 1) {
        n = msg(b, n, "the barrier opens");
    } else {
        n = msg(b, n, "the barrier timed out; carrying on alone");
    };
    // and the chat the barrier promoted for this session.  Frozen when the round
    // opened, so reading it now is as good as reading it at any later moment --
    // which is the entire point.  See "CHAT: STAGED, THEN PROMOTED".
    pend_drain(slot, b, n, PEND2_N[slot])
};

// say_fanout: hand the text to every other session in the room, under the lock.
// Returns how many were told.  Its own function so v_say can skip the whole
// critical section when there is nobody to tell.
def say_fanout(slot: long, ib: [byte; 4096], a: long, z: long) -> long {
    let r = S_ROOM[slot];
    let sent = 0;
    wait LM;
    let k = 0;
    while (k < MAXS) {
        if (k != slot && S_ON[k] == 1 && S_ROOM[k] == r) {
            pend_add_locked(k, slot, ib, a, z);
            sent = sent + 1;
        };
        k = k + 1;
    };
    post LM;
    sent
};

// ---------------------------------------------------------------------------
// the verbs
// ---------------------------------------------------------------------------

def dir_of_bytes(b: [byte; 4096], a: long, z: long) -> long {
    let d = 0 - 1;
    if (d < 0 && (weq(b, a, z, "n") || weq(b, a, z, "north"))) { d = 0 };
    if (d < 0 && (weq(b, a, z, "e") || weq(b, a, z, "east"))) { d = 1 };
    if (d < 0 && (weq(b, a, z, "s") || weq(b, a, z, "south"))) { d = 2 };
    if (d < 0 && (weq(b, a, z, "w") || weq(b, a, z, "west"))) { d = 3 };
    d
};

// An item instance named by the client: by decimal id, or by item name -- on the
// floor of this room first, then in the pack, so `take torch` and `drop torch`
// both work without the client tracking ids.
def find_inst(slot: long, b: [byte; 4096], a: long, z: long) -> long {
    let ans = 0 - 1;
    let id = wnum(b, a, z);
    if (id >= 0 && id < world.insts()) { ans = id };
    if (ans < 0) {
        let i = 0;
        while (i < world.insts()) {
            if (ans < 0 && MUT_ROOM[slot * MAXI + i] == S_ROOM[slot]
                && MUT_QTY[slot * MAXI + i] > 0
                && weq(b, a, z, world.item_name(world.i_id(i)))) { ans = i };
            i = i + 1;
        };
        i = 0;
        while (i < world.insts()) {
            if (ans < 0 && MUT_ROOM[slot * MAXI + i] == 0 - 1
                && MUT_QTY[slot * MAXI + i] > 0
                && weq(b, a, z, world.item_name(world.i_id(i)))) { ans = i };
            i = i + 1;
        };
    };
    ans
};

// One turn passes and whatever lives here gets to swing.  The roll comes from the
// SESSION's generator, so a player's damage is the same every run even though
// other players are fighting elsewhere at the same time.
def monster_tick(slot: long, b: [byte; 4096], n: long) -> long {
    let r = S_ROOM[slot];
    let k = world.m_kind(r);
    if (k >= 0 && MUT_MHP[slot * MAXR + r] > 0) {
        let hit = world.mon_atk(k) + srng_below(slot, 2);
        S_HP[slot] = S_HP[slot] - hit;
        n = ps(b, n, "+MSG the "); n = ps(b, n, world.mon_name(k));
        n = ps(b, n, " hits you for "); n = pn(b, n, hit);
        n = ps(b, n, ".");
        n = pnl(b, n);
        if (S_HP[slot] <= 0) {
            S_HP[slot] = 0;
            n = msg(b, n, "you die. the room goes quiet.");
        };
    } else {
        n = msg(b, n, "nothing moves.");
    };
    n
};

def v_move(slot: long, b: [byte; 4096], n: long, d: long) -> long {
    let r = S_ROOM[slot];
    if (d < 0) {
        n = msg(b, n, "that is not a direction I know. try north, east, south or west.");
    } else {
        let t = world.ex_to(r, d);
        if (t < 0) {
            n = msg(b, n, "there is no exit that way.");
        } else {
            S_ROOM[slot] = t;
            S_TURN[slot] = S_TURN[slot] + 1;
            C_TURN[slot] = C_TURN[slot] + 1;
            n = room_view(slot, b, n);
        };
    };
    n
};

def v_take(slot: long, b: [byte; 4096], n: long, ib: [byte; 4096], a: long, z: long) -> long {
    let i = find_inst(slot, ib, a, z);
    if (i < 0) {
        n = msg(b, n, "there is no such thing here.");
    } else {
        if (MUT_ROOM[slot * MAXI + i] != S_ROOM[slot] || MUT_QTY[slot * MAXI + i] <= 0) {
            n = msg(b, n, "that is not on the floor here.");
        } else {
            MUT_ROOM[slot * MAXI + i] = 0 - 1;
            S_COIN[slot] = S_COIN[slot] + world.item_value(world.i_id(i)) * MUT_QTY[slot * MAXI + i];
            S_TURN[slot] = S_TURN[slot] + 1;
            n = ps(b, n, "+MSG you take the ");
            n = ps(b, n, world.item_name(world.i_id(i)));
            n = ps(b, n, ".");
            n = pnl(b, n);
            n = carry_list(slot, b, n);
        };
    };
    n
};

def v_drop(slot: long, b: [byte; 4096], n: long, ib: [byte; 4096], a: long, z: long) -> long {
    let i = find_inst(slot, ib, a, z);
    if (i < 0) {
        n = msg(b, n, "you are not carrying that.");
    } else {
        if (MUT_ROOM[slot * MAXI + i] != 0 - 1 || MUT_QTY[slot * MAXI + i] <= 0) {
            n = msg(b, n, "you are not carrying that.");
        } else {
            MUT_ROOM[slot * MAXI + i] = S_ROOM[slot];
            let v = world.item_value(world.i_id(i)) * MUT_QTY[slot * MAXI + i];
            if (v < S_COIN[slot]) { S_COIN[slot] = S_COIN[slot] - v } else { S_COIN[slot] = 0 };
            S_TURN[slot] = S_TURN[slot] + 1;
            n = ps(b, n, "+MSG you drop the ");
            n = ps(b, n, world.item_name(world.i_id(i)));
            n = ps(b, n, ".");
            n = pnl(b, n);
            n = carry_list(slot, b, n);
        };
    };
    n
};

// Combat.  The player's swing is 2 + roll(3); the monster always swings back if
// it is still breathing, so a fight costs turns on both sides.
def v_attack(slot: long, b: [byte; 4096], n: long, ib: [byte; 4096], a: long, z: long) -> long {
    let r = S_ROOM[slot];
    let k = world.m_kind(r);
    if (k < 0) {
        n = msg(b, n, "there is nothing here to fight.");
    } else {
        let named = weq(ib, a, z, world.mon_name(k));
        if (!named) {
            n = msg(b, n, "that is not what you meant to attack.");
        } else {
            if (MUT_MHP[slot * MAXR + r] <= 0) {
                n = ps(b, n, "+MSG the "); n = ps(b, n, world.mon_name(k));
                n = ps(b, n, " is already dead.");
                n = pnl(b, n);
            } else {
                let dmg = 2 + srng_below(slot, 3);
                MUT_MHP[slot * MAXR + r] = MUT_MHP[slot * MAXR + r] - dmg;
                S_TURN[slot] = S_TURN[slot] + 1;
                n = ps(b, n, "+MSG you hit the "); n = ps(b, n, world.mon_name(k));
                n = ps(b, n, " for "); n = pn(b, n, dmg); n = ps(b, n, ".");
                n = pnl(b, n);
                if (MUT_MHP[slot * MAXR + r] <= 0) {
                    n = ps(b, n, "+MSG the "); n = ps(b, n, world.mon_name(k));
                    n = ps(b, n, " dies.");
                    n = pnl(b, n);
                };
            };
        };
    };
    n
};

// `say`: the reply goes into every OTHER session in the room (via its pending
// region, under the mutex) and into this one's log immediately.
def v_say(slot: long, b: [byte; 4096], n: long, ib: [byte; 4096], a: long, z: long) -> long {
    if (z <= a) {
        n = msg(b, n, "you say nothing at all.");
    } else {
        // the locked fan-out is its own function, and it is skipped entirely when
        // nobody else is in the room (see say_fanout)
        let sent = 0;
        if (others_here(slot, S_ROOM[slot]) > 0) {
            sent = say_fanout(slot, ib, a, z);
        };
        n = ps(b, n, "+MSG "); n = pnm(b, n, slot);
        n = ps(b, n, " says: ");
        n = sockio.obmem(b, n, ib, a, z);
        n = pnl(b, n);
        if (sent == 0) { n = msg(b, n, "nobody else is here.") };
        C_SAY[slot] = C_SAY[slot] + 1;
    };
    n
};

// A name has to be something you can shout across a room: 1..12 characters of
// letters and digits.  Anything else is refused by name, not by trap.
def name_ok(ib: [byte; 4096], a: long, z: long) -> bool {
    let ok = z > a && z - a <= 12;
    let i = a;
    while (i < z && ok) {
        let c = ib[i];
        let alpha = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57);
        if (!alpha) { ok = false };
        i = i + 1;
    };
    ok
};

// name_taken: is any OTHER session already using this name?  Returns 1 or 0
// because that is what v_login branches on.
def name_taken(slot: long, ib: [byte; 4096], a: long, z: long) -> long {
    let dup = 0;
    wait LM;
    let k = 0;
    while (k < MAXS) {
        if (k != slot && S_ON[k] == 1 && name_eq_bytes(k, ib, a, z)) { dup = 1 };
        k = k + 1;
    };
    post LM;
    dup
};

def v_login(slot: long, b: [byte; 4096], n: long, ib: [byte; 4096], a: long, z: long) -> long {
    if (S_ON[slot] == 1) {
        n = msg(b, n, "you are already in.");
    } else {
        if (!name_ok(ib, a, z)) {
            n = msg(b, n, "a name is 1 to 12 letters and digits, please.");
        } else {
            // Only ONE session's login can be in flight at a time per slot, and
            // the duplicate scan reads other slots -- so it does need the lock.
            let dup = name_taken(slot, ib, a, z);
            if (dup == 1) {
                n = msg(b, n, "that name is taken; try another.");
            } else {
                set_name(slot, ib, a, z);
                S_ON[slot] = 1;
                n = ps(b, n, "+HELLO 1 ");
                n = pn(b, n, world.rooms()); n = pbar(b, n);
                n = pn(b, n, SYNC_GOAL[0]);
                n = pnl(b, n);
                n = msg(b, n, "welcome in. type `help' for the verbs.");
                n = room_view(slot, b, n);
            };
        };
    };
    n
};

def help_block(b: [byte; 4096], n: long) -> long {
    n = msg(b, n, "look | l        look around");
    n = msg(b, n, "n e s w         go that way (north, east, south, west)");
    n = msg(b, n, "go <dir>        the same, spelled out");
    n = msg(b, n, "take <item>     pick something off the floor");
    n = msg(b, n, "drop <item>     put something back");
    n = msg(b, n, "inventory | i   what you are carrying");
    n = msg(b, n, "attack <mon>    hit the monster here");
    n = msg(b, n, "wait | .        let a turn pass");
    n = msg(b, n, "say <text>      say it to the room");
    n = msg(b, n, "who             who is online");
    n = msg(b, n, "map             the whole graph, room by room");
    n = msg(b, n, "sync <n>        wait for n players, then all go on");
    n = msg(b, n, "help            this list");
    n = msg(b, n, "quit | q        log out");
    n
};

// ---------------------------------------------------------------------------
// the dispatcher
// ---------------------------------------------------------------------------

// WHY `sync` DRAINS AND NOTHING ELSE DOES
//
// The natural place to drain the pending-chat region is the top of the command,
// and that is exactly where it makes concurrent play irreproducible.  Consider
// `sync` / `say` / `sync`: at the second barrier's reply, the sender's message
// has been written iff the OTHER player got its `say` in first.  If the drain is
// before the barrier, that is a race between two threads and the transcript
// differs run to run (measured: 2 of 3 runs identical, the third had the message
// one block later).  Draining after the barrier fixes THAT race -- by the time any
// participant's barrier returns, EVERY participant has finished its `say`,
// because arriving at the barrier is what happens after saying.
//
// It does not fix the next one, which is why `sync` is now the only verb that
// drains.  A barrier says "everybody has arrived", not "nobody has run on past
// me": the instant it opens, both workers are free to execute the next command,
// and the other player's `say` can land in this session's region in the gap
// between "my barrier reported" and "my next command drains".  That was measured
// too.  See "CHAT IS DELIVERED AT A BARRIER" for the two rules that close both
// windows, and for why the drain belongs inside `sync` and nowhere else.
def command(slot: long, ib: [byte; 4096], ln: long, b: [byte; 4096], nslp: [long; 2]) -> long {
    let n = 0;
    let a = skip_sp(ib, 0, ln);
    let z = word_end(ib, a, ln);
    let arg = skip_sp(ib, z, ln);
    let argz = ln;
    while (argz > arg && ib[argz - 1] == 32) { argz = argz - 1 };
    let issync = weq(ib, a, z, "sync");
    if (S_ON[slot] == 0 && !weq(ib, a, z, "login") && !weq(ib, a, z, "quit")) {
        n = msg(b, n, "log in first: `login <name>'.");
    } else if (weq(ib, a, z, "login")) {
        n = v_login(slot, b, n, ib, arg, argz);
    } else if (weq(ib, a, z, "quit") || weq(ib, a, z, "q")) {
        n = msg(b, n, "off you go.");
        n = ps(b, n, "+BYE "); n = pnm(b, n, slot); n = pnl(b, n);
        S_QUIT[slot] = 1;
    } else if (weq(ib, a, z, "look") || weq(ib, a, z, "l")) {
        n = room_view(slot, b, n);
    } else if (weq(ib, a, z, "go")) {
        // `go north` -- the argument is parsed the same way as a bare direction,
        // so both spellings take exactly one code path
        n = v_move(slot, b, n, dir_of_bytes(ib, arg, argz));
    } else if (dir_of_bytes(ib, a, z) >= 0) {
        // a bare direction: n, e, s, w, or the long spelling
        n = v_move(slot, b, n, dir_of_bytes(ib, a, z));
    } else if (weq(ib, a, z, "help") || weq(ib, a, z, "?")) {
        n = help_block(b, n);
    } else if (weq(ib, a, z, "inventory") || weq(ib, a, z, "i") || weq(ib, a, z, "inv")) {
        n = msg(b, n, "you are carrying:");
        n = carry_list(slot, b, n);
    } else if (weq(ib, a, z, "take") || weq(ib, a, z, "get")) {
        n = v_take(slot, b, n, ib, arg, argz);
    } else if (weq(ib, a, z, "drop")) {
        n = v_drop(slot, b, n, ib, arg, argz);
    } else if (weq(ib, a, z, "attack") || weq(ib, a, z, "kill")) {
        n = v_attack(slot, b, n, ib, arg, argz);
    } else if (weq(ib, a, z, "wait") || weq(ib, a, z, ".")) {
        S_TURN[slot] = S_TURN[slot] + 1;
        C_TURN[slot] = C_TURN[slot] + 1;
        n = monster_tick(slot, b, n);
    } else if (weq(ib, a, z, "say")) {
        n = v_say(slot, b, n, ib, arg, argz);
    } else if (weq(ib, a, z, "who")) {
        n = who_block(slot, b, n);
    } else if (weq(ib, a, z, "map")) {
        n = map_block(slot, b, n);
    } else if (issync) {
        let want = wnum(ib, arg, argz);
        if (want < 1 || want > MAXS) { want = SYNC_GOAL[0] };
        n = do_sync(slot, want, b, n, nslp);
    } else if (z == a) {
        n = msg(b, n, "say something. `help' lists the verbs.");
    } else {
        n = msg(b, n, "I do not know that verb. `help' lists them.");
        C_ERR[slot] = C_ERR[slot] + 1;
    };
    if (!alive(slot) && S_QUIT[slot] == 0) {
        n = ps(b, n, "+BYE ");
        n = pnm(b, n, slot);
        n = pnl(b, n);
        S_QUIT[slot] = 1;
    };
    cmd_count(slot);
    let fin = stat_block(slot, b, n);
    // A reply that would not fit is replaced by a short one, never truncated:
    // a half-sent block would desynchronise the client's read-until-+END loop.
    if (fin >= sockio.LIM) {
        C_LONG[slot] = C_LONG[slot] + 1;
        let short = msg(b, 0, "that reply will not fit in one packet; try `map' or `look'");
        fin = stat_block(slot, b, short);
    };
    fin
};

export { MAXS, START_HP, JOBQ, LM, LFD, SHUTDOWN, SYNC_GOAL, N_CONN, N_CONN_NOW,
         N_PEAK, WK_GROW, WK_PEAK, account, D_A, D_B, D_C, D_D,
         C_CMD, C_TURN, C_SAY, C_ERR, C_LONG, C_TRUNC,
         n_cmd, n_turn, n_say, n_err, n_long, n_trunc, total,
         others_here, anyone_on, draw_others, draw_who, list_others, list_who,
         name_eq_bytes, name_taken, pend_promote, pend_drain, cmd_count,
         S_FD, S_STATE, S_NAME, S_ROOM, S_HP, S_MHP, S_COIN, S_TURN, S_MSG,
         S_ON, S_QUIT, S_NLEN, name_len, name_eq, pnm, set_name,
         init_session, claim_slot, release_slot, acceptor, worker,
         ps, pn, pc, pnl, pbar,
         skip_sp, word_end, weq, wnum, srng_below, pend_add_locked,
         command, room_view, do_sync, stat_block, alive,
         carry_count, carry_list, map_block, who_block, help_block,
         monster_tick, find_inst, v_say, name_ok, first_floor_inst };