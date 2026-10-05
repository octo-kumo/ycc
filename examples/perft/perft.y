// perft.y -- chess perft, threaded: count the leaf nodes of the move tree to a
// fixed depth, over a bounded pool of workers started once.
//
// Build:  ../../refs/ycc.ref perft.y -o perft
// Run:    ./perft                 the built-in position suite (this is EXPECTED)
//         ./perft --check         the property check: published perft counts,
//                                 and threaded == single-threaded, every depth
//         ./perft --bench         nodes/second, one thread against the pool
//         ./perft --help          every flag
//
// ===========================================================================
// WHAT PERFT IS, AND WHY IT IS A GOOD EXAMPLE
// ===========================================================================
//
// perft(pos, d) counts the leaf nodes d moves below `pos`: at depth 1 it is
// simply the number of legal moves, at depth 2 it is the sum of the legal move
// counts of every position one move down, and so on.  It is the standard
// correctness test for a chess move generator, and unusually for a numeric
// benchmark the answers are PUBLISHED and AUTHORITATIVE -- the start position
// really does have 20 moves and 4 865 609 at depth 5, and any generator that
// disagrees is wrong, not differently right.  So the property check here needs
// no golden file at all: the expectation is in the program, as a table of
// constants, and a wrong generator fails a number rather than a diff.
//
// The counts are also a real test of the rules that are easy to get wrong and
// impossible to eyeball: castling through check, en passant removing a pawn
// from a square the mover never touched, promotion to all four pieces, and
// pins.  The fourth position below, `ep-pin`, is the en-passant pin -- a pawn
// that captures en passant and discovers a rook on its own king, which no
// move-by-move reading of the rules catches and every perft count does.  Four of
// the bugs this file's own comments record were found exactly that way, and
// none of them would have shown up in a golden file: the file would have been
// generated from the broken output and reproduced it perfectly.
//
// ===========================================================================
// THE THREADING, AND WHY IT IS A POOL
// ===========================================================================
//
// perft(root, d) = sum over the root's legal moves of perft(one move down, d-1).
// That identity is what makes the search splittable with nothing shared but the
// answer: each root move's subtree is independent, so the root moves are the
// work items and the count is their sum.  There is no shared board to lock,
// because every worker owns a Pos (its own board, its own move scratch) and
// copies the root position into it before each item.
//
// The workers are started ONCE, at start-up, and loop for the life of the
// program.  A spawn leaks: each thread allocates from a heap of its own and
// nothing is ever freed, so 2000 spawn/join cycles grow the process by 256000
// bytes (measured; ORCHESTRATOR.md 2.13).  A thread per node would allocate
// gigabytes over a depth-5 search -- this is the single most important thing to
// get right in a threaded example, and the reason the pool size is a constant
// rather than a function of the search.
//
// The work queue is a mutex-guarded cursor, not a fixed band per worker,
// because A COUNTING SEMAPHORE IS NOT FAIR: it hands a token to whoever asks
// first, so a worker coming back round early takes a second token and can take
// all of them.  With static bands that is not a slow worker, it is an INVISIBLE
// one -- its band is simply never counted, the total is short, and nothing
// complains.  The cursor makes every root move claimed exactly once whatever
// the wake-up order, and a worker that finds the cursor past the end does
// nothing, so duplicate or surplus wake-ups are harmless.
//
// Each worker takes ONE token per search and then drains the queue to the end,
// so the main thread waits for the pool with `wait(done)` N times instead of
// spinning on a counter, and there is no lost-wakeup window to get wrong.
//
// One consequence of the unfair semaphore is worth spelling out, because it is
// the bug this pool shipped with: a worker that comes back early is handed a
// SECOND token, finds the queue empty, and must then ADD its (zero) share to
// what it already reported rather than overwrite it.  Reporting by assignment
// lost whole subtrees -- 2715 short answers in 3000 rounds of the stress test in
// queue_test.y, every one of them silently wrong.

import chess;
import args;

// ===========================================================================
// STATE
// ===========================================================================
//
// Every module-level binding lives here, before the first use.  Top-level
// `let`s do NOT hoist in Y -- `rename.y` binds a name where it is written, so
// a forward reference is an error, not an initial zero.  (Worth knowing: the
// error is "undefined variable", not "used before it is declared", so it reads
// like a typo the first time you meet it.)

// ── the positions ─────────────────────────────────────────────────────────

// The four the property check asserts, plus one more that exists only to be
// played with (`--positions` lists them).  The counts for the trap are this
// program's own, cross-checked against an independent implementation; the
// counts for the other three are the published ones, which is the point.
type Case = { name: str, fen: str, maxd: long };

let START: str = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
let KIWIPETE: str = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1";
let POS3: str = "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1";
// The en-passant pin, and the sharpest test in the file.  White has just played
// c2-c4, so black's d4 pawn may take c3 EN PASSANT -- and doing so vacates BOTH
// c4 and d4, opening the fourth rank from h4 to the black king on a4.  That
// would leave the MOVER'S OWN king in check, so the move is illegal.
//
// The colours are the whole point and they are easy to get backwards: had the
// king on a4 been WHITE's, the same capture would be perfectly legal -- it
// simply gives check, and giving check is what moves are for.  The first version
// of this position had it the wrong way round, counted 14 instead of 7, and the
// "expected 9" it disagreed with was the real bug.  Note also that this is the
// only place in a perft suite where a move removes a piece from a square the
// mover never touched, which is why no amount of reading the rules finds it and
// a published node count does.
let TRAP: str = "8/8/8/8/k1Pp3R/8/8/7K b - c3 0 1";

// The default depth of each is its deepest PUBLISHED one, which is what makes
// the default run worth reading: the numbers in EXPECTED are the authoritative
// ones, and the property check asserts the same table.
let CASES: [Case] = [
    { name: "startpos", fen: START, maxd: 5 },
    { name: "kiwipete", fen: KIWIPETE, maxd: 4 },
    { name: "position3", fen: POS3, maxd: 5 },
    { name: "ep-pin", fen: TRAP, maxd: 5 }
];

// Two more positions, for the rule checks only.  Neither has a published count
// in the table above, because each of them is here to answer one question that
// a count alone cannot answer: is the en-passant pin in the move list, and is
// the promotion to all four pieces there?
// A white pawn on b7, a black knight on a8 to be captured onto, and the kings
// out of each other's way: 4 pushes + 4 captures = 8 pawn moves, and 3 king
// moves (b1 and b2 are both next to the black king on a1).  Eleven in all.
const PROMO_FEN: str = "n7/1P6/8/8/8/8/8/k1K5 w - - 0 1";
// Castling while f1 is attacked: the king may not pass through an attacked
// square, so e1g1 is illegal even though every square between is empty.  The
// attacker is a rook on f8, which hits the f-file and nothing else -- a queen
// on f2 would ALSO hit e1, and the position would then be testing "may not
// castle out of check", a different rule and a weaker test.
const CASTLE_THROUGH: str = "4kr2/8/8/8/8/8/8/R3K2R w KQ - 0 1";
// The en-passant pin position with the white rook moved off the fourth rank
// (g6), where the very same capture is perfectly legal: 6 moves instead of 5,
// and the sixth is the capture.
const EP_OK: str = "8/6R1/8/8/k1Pp4/8/8/7K b - c3 0 1";
// A pin: the white rook on e2 shields the king on e1 from the rook on e8, so it
// may only travel along the e-file.  Six rook moves (e3..e8, the last one a
// capture) and four king moves, and nothing sideways.
const PIN_FEN: str = "4r2k/8/8/8/8/8/4R3/4K3 w - - 0 1";

// A Pos of the rule checks' own, so they cannot disturb a search in progress.
let SCRATCH: chess.Pos = chess.new_pos();

// How many rule checks have been made.  Counted rather than declared: a
// hand-written constant beside a hand-written list is one more thing to be wrong
// about, and the summary line would then claim a total the run never reached.
let rule_run: long = 0;

// ck(ok, label, what) -> 0 or 1, and prints the verdict.  Every rule check goes
// through this, so the output names each one and the total cannot drift.
def ck(ok: bool, label: str, what: str) -> long {
    rule_run = rule_run + 1;
    if (ok) {
        print("  ok   ", pad(label, 16), what);
        0
    } else {
        print("  FAIL ", pad(label, 16), what);
        1
    }
}

// rule_checks() -> failures among the hand-written rule checks.
//
// These are the parts of the generator a count cannot localise: a wrong count
// says something is broken, "the en-passant capture is in the move list" says
// what.  Each of the four positions below exists to break one rule, and the
// published counts above exist to break everything else.
def rule_checks() -> long {
    let fails = 0;
    // 1. the en-passant pin.  d4xc3 e.p. would vacate both c4 and d4 and open
    //    the fourth rank on the black king, so it is not a legal move -- while
    //    the quiet push on the same rank is.
    fails += ck(gen_count(TRAP) == 5, "ep-pin",
        "5 moves, the en passant excluded");
    fails += ck(!has_move(TRAP, "d4c3"), "ep-pin",
        "d4c3 (the illegal en passant) is NOT in the list");
    fails += ck(has_move(TRAP, "d4d3"), "ep-pin",
        "d4d3 (the quiet push) IS in the list");
    // 2. the same position with the rook off the fourth rank: now the very same
    //    capture is legal, and the count is exactly one higher.  If these two
    //    positions did not differ by exactly the capture, the ep rule would be
    //    being ignored in one direction or the other.
    fails += ck(gen_count(EP_OK) == 6, "ep-ok",
        "6 moves, the en passant included");
    fails += ck(has_move(EP_OK, "d4c3"), "ep-ok",
        "d4c3 IS in the list here");
    // 3. promotion: four pieces on the push, four on the capture, all legal.
    fails += ck(gen_count(PROMO_FEN) == 11, "promotion",
        "11 moves: 4 pushes + 4 captures + 3 king steps");
    fails += ck(has_move(PROMO_FEN, "b7b8q") && has_move(PROMO_FEN, "b7b8r")
        && has_move(PROMO_FEN, "b7b8b") && has_move(PROMO_FEN, "b7b8n"), "promotion",
        "all four promotions on b8 are legal");
    fails += ck(has_move(PROMO_FEN, "b7a8q") && has_move(PROMO_FEN, "b7a8n"),
        "promotion", "capturing promotions on a8 are legal");
    // 4. castling, allowed: Kiwipete may do both, and both are in the list.
    fails += ck(has_move(KIWIPETE, "e1g1") && has_move(KIWIPETE, "e1c1"),
        "castling", "kiwipete allows e1g1 and e1c1");
    // 5. castling refused through an attacked square: the black rook on f8 hits
    //    the f-file and nothing else, so the white king is not in check and
    //    could start -- it may not step onto g1 over f1.  The queenside castle,
    //    whose squares are all unattacked, is still there.
    fails += ck(!has_move(CASTLE_THROUGH, "e1g1"), "castle-through",
        "e1g1 is NOT legal through an attacked f1");
    fails += ck(has_move(CASTLE_THROUGH, "e1c1"), "castle-through",
        "e1c1 is still legal (d1 and c1 are not attacked)");
    fails += ck(gen_count(CASTLE_THROUGH) == 23, "castle-through",
        "23 moves in all");
    // 6. a pin: the white rook on e2 is pinned to the king on e1 by the rook on
    //    e8, so it may only move along the file -- a sideways move would leave
    //    the king in check, and a count at depth 2 is where that shows up.
    fails += ck(gen_count(PIN_FEN) == 10, "pin",
        "10 moves: the pinned rook has 6, the king 4");
    fails += ck(!has_move(PIN_FEN, "e2d2") && !has_move(PIN_FEN, "e2f2"), "pin",
        "the pinned rook has no sideways move");
    fails
}

// ── the pool ──────────────────────────────────────────────────────────────

// The most workers worth starting.  Two independent bounds: a worker takes
// whole root-move subtrees and the start position has 20 root moves, so past
// that it is pure overhead; and each thread's first allocation is a 4 MiB heap
// chunk, so the pool costs 4 MiB of address space a head.  16 is above any
// real core count and far below the 3.5 GiB cap.
const MAXW: long = 16;

// One token per worker per search: a worker takes its token, drains the shared
// cursor to the end, reports, and parks again (see worker()).
let jobs = sem(0);
let done = sem(0);
let vlk = mutex();

// The queue.  ROOTMV is the root's legal move list, cursor the claim, left how
// many are still unclaimed.  SPLIT is the per-worker answer, which is summed
// at the end -- summing under the lock instead would serialise the whole
// search on one mutex.
let ROOTMV: [long; 256] = [0; 256];
let ROOTN: long = 0;
let cursor: long = 0;
let left: long = 0;
let SPLIT: [long; 16] = [0; 16];
let ready: long = 0;
let stopping: bool = false;
let workers: [() -> long] = [];
let nworkers: long = 0;

// The root position, and the pristine copy every worker starts each of its
// items from.  One per driver, shared read-only: a worker COPIES the pieces into
// its own Pos rather than sharing one, which is what keeps the board free of
// locks.
let RP: chess.Pos = chess.new_pos();
let POOL: [chess.Pos] = [];
let pool_depth: long = 0;

// reset_root(p, fen, depth) -> "" or the reason the position was refused.
// Load, validate, and leave `p` holding the root position.
def reset_root(p: chess.Pos, fen: str, depth: long) -> str {
    let err = chess.set_fen(p, fen);
    if (err != "") { return err };
    if (depth < 1) { return "depth " + tostring(depth) + " is below 1" };
    if (depth > chess.MAXDEPTH) {
        return "depth " + tostring(depth) + " is over the " + tostring(chess.MAXDEPTH)
            + " the move buffer holds"
    };
    pool_depth = depth;
    ""
}

// give_root(p) -- p takes the root position, board and all state, and NOT the
// move scratch (which is per-worker and only ever holds work in progress).
def give_root(p: chess.Pos) -> void {
    let i = 0;
    let stop = false;
    while (stop == false) {
        if (i > 119) {
            stop = true
        } else {
            p.bd[i] = RP.bd[i];
            i = i + 1
        }
    };
    p.side = RP.side;
    p.castle = RP.castle;
    p.ep = RP.ep;
    p.ksq[0] = RP.ksq[0];
    p.ksq[1] = RP.ksq[1]
}

// worker(w) -- the whole life of a pool worker: park on a token, drain the
// queue, hand the answer back, park again.  It LOOPS.  The first version ran the
// drain once and returned, which is a pool of size one job: the second search
// posted four tokens that nobody was left to take and then sat in wait(done)
// until the alarm went off.  (A hang, not a wrong number -- the one good kind of
// bug to have, and still a bug.)
//
// `POOL[w]` is this worker's Pos, created once when the pool is started: a Pos
// is 2.2 KiB of fixed arrays, so building one per work item would be a leak of
// the exact kind this example exists to avoid.  It is also what keeps the board
// out of the locks: every worker owns its board and copies the root into it.
def worker(w: long) -> long {
    let mine = POOL[w];
    // The start-up barrier's other half: counted before the first wait, so the
    // main thread knows this worker exists and has not yet taken a token.
    lock vlk { ready = ready + 1 };
    let running = true;
    while (running) {
        wait(jobs);
        lock vlk {
            if (stopping) { running = false }
        };
        if (running) {
            let mine_n = 0;
            let go = true;
            while (go) {
                let m = 0;
                let claimed = false;
                lock vlk {
                    if (left > 0) {
                        m = ROOTMV[cursor];
                        cursor = cursor + 1;
                        left = left - 1;
                        claimed = true
                    }
                };
                if (claimed) {
                    give_root(mine);
                    let cap = chess.make(mine, m, 0);
                    // At depth 1 the leaf below a root move is that move, and
                    // perft(pos, 0) would answer the CHILD's move count (the
                    // engine returns gen_all for any depth <= 1, which is what
                    // makes the recursion stop).  So the last ply adds 1 here
                    // rather than searching -- and the pool is still doing the
                    // summing, at every depth, which is what the check compares.
                    if (pool_depth <= 1) {
                        mine_n += 1
                    } else {
                        mine_n += chess.perft(mine, pool_depth - 1, chess.MVSTRIDE)
                    };
                    chess.unmake(mine, m, 0, cap)
                } else {
                    go = false
                }
            };
            // ACCUMULATE, do not assign.  A worker that comes back round while
            // others are still searching simply finds the cursor past the end
            // and takes nothing -- and if it ASSIGNED its (empty) share here it
            // would wipe the subtree it already counted, which is exactly the
            // failure ORCHESTRATOR.md 2.13 warns about with static bands: an
            // invisible worker, a total that is quietly short, no diagnostic.
            // Measured on this pool: 2715 wrong answers out of 3000 rounds with
            // 16 workers and 5 items, every one of them short, none of them
            // announced.  (A first version of this worker also returned after
            // ONE job, which made the pool a pool of size one and hung the
            // second search; the loop and the += are both load-bearing.)
            SPLIT[w] = SPLIT[w] + mine_n;
            post(done)
        }
    };
    0
}

// start_pool(n) -- start the workers, once, and do not return until all of
// them are parked at their wait.  Without the barrier a worker that has been
// cloned but not yet scheduled is not in the pool, and the first search runs
// on fewer threads than asked for.
//
// THREE THINGS IN HERE ARE NOT OBVIOUS, and each was a trap this program fell
// into first:
//
// 1. `n == 1` starts NO thread at all.  This thread does the work itself
//    (perft_mt is never called), which is not only the honest baseline for
//    --bench but also keeps a single-threaded run free of thread heaps: each
//    thread's first allocation is a 4 MiB chunk.
//
// 2. The spawn loop is `for w in 0..n`, NOT `let w = 0; while (w < n)`.  A
//    `let` written before a loop is ONE shared capture cell (AGENTS.md,
//    "Captures are shared"), so every worker would read the w the loop
//    finished on -- n -- and POOL[n] on an n-element array is an index out of
//    bounds trap in a freshly spawned thread, with the message printed by that
//    thread and the whole program exiting 1.  A `for` loop's variable is fresh
//    per iteration, which is the whole reason that form exists.
//
// 3. `ready` is incremented BEFORE wait(jobs), not after, so it counts workers
//    that have started and not yet taken a token -- which is what the barrier
//    is asking.
def start_pool(n: long) -> void {
    nworkers = n;
    if (n < 2) { return };
    let i = 0;
    while (i < n) {
        POOL += chess.new_pos();
        i = i + 1
    };
    for w in 0..n {
        workers += spawn { worker(w) };
    };
    let spins = 0;
    let ok = false;
    while (spins < 20000000 && ok == false) {
        lock vlk { ok = ready >= n };
        spins = spins + 1
    }
}

// perft_mt() -> the count, computed by the pool.  The root position is already
// loaded and pool_depth is set.
//
// perft(root, d) = the sum over the root's legal moves of perft(one move down,
// d-1), and at d = 1 that is just the number of root moves.  The pool does that
// sum in parallel at EVERY depth -- including depth 1, where each worker claims
// a move and counts its single leaf -- so "threaded == single-threaded" is a
// statement about the same decomposition at every depth rather than a fallback
// to one thread at the shallow ones.
//
// The main thread only touches ROOTMV/cursor/left/SPLIT under the mutex; the
// workers' own boards and move scratch are private, so the critical section is
// one cursor update per work item and nothing else.
def perft_mt() -> long {
    ROOTN = chess.gen_all(RP, 0);
    let i = 0;
    lock vlk {
        while (i < ROOTN) {
            ROOTMV[i] = RP.mv[i];
            i = i + 1
        };
        cursor = 0;
        left = ROOTN;
        let w = 0;
        while (w < nworkers) {
            SPLIT[w] = 0;
            w = w + 1
        }
    };
    let w = 0;
    while (w < nworkers) {
        post(jobs);
        w = w + 1
    };
    w = 0;
    while (w < nworkers) {
        wait(done);
        w = w + 1
    };
    let total = 0;
    w = 0;
    while (w < nworkers) {
        total += SPLIT[w];
        w = w + 1
    };
    total
}

// shutdown_pool() -- stop the workers and wait for them, so nothing is left
// running when the program returns.  One token each, exactly as a search posts
// them: a worker takes its token, sees `stopping`, and leaves without posting
// `done`, which is what distinguishes this from a search.
def shutdown_pool() -> void {
    if (nworkers < 2) { return };
    lock vlk { stopping = true };
    let w = 0;
    while (w < nworkers) {
        post(jobs);
        w = w + 1
    };
    w = 0;
    while (w < len(workers)) {
        join(workers[w]);
        w = w + 1
    }
}

// perft_st(depth) -> the count, computed on this thread alone.  Also the
// honest baseline for --bench: no spawn happens on this path, so a
// single-threaded run also costs no thread heaps.
def perft_st() -> long {
    chess.perft(RP, pool_depth, 0)
}

// load(fen, depth) -> 0 when the position is accepted, or -1 after SAYING WHY on
// stderr.
//
// One place decides what a bad FEN looks like from outside, because the
// alternative -- each caller testing the empty-string return and carrying on -- is
// how a malformed FEN ends up silently counting a different game.  It did,
// twice, while this was being written: `--fen` with no black king printed
// nothing at all and exited 0.  Every position load in the program goes through
// here, so every error path produces a message on stderr and a non-zero exit.
def load(fen: str, depth: long) -> long {
    let err = reset_root(RP, fen, depth);
    if (err == "") { 0 } else {
        eputs("perft: " + fen + ": " + err + "\n");
        -1
    }
}

// count(fen, depth, threaded) -> the number of nodes, or -1 if the position was
// refused (in which case the reason has already gone to stderr).
def count(fen: str, depth: long, threaded: bool) -> long {
    if (load(fen, depth) < 0) { return -1 };
    if (threaded && nworkers > 1) { perft_mt() } else { perft_st() }
}

// ── output helpers ────────────────────────────────────────────────────────

// Nothing in the SEARCH path builds a string at all -- the only strings this
// program makes are in these output helpers, which run once per line of output
// and never once per node.
def pad(s: str, w: long) -> str {
    let n = s.length;
    let out = s;
    let i = n;
    while (i < w) {
        out += " ";
        i = i + 1
    };
    out
}

// ── the modes ─────────────────────────────────────────────────────────────

// perft_table(name, fen, maxd, threaded) -> 0, or -1 if a position was refused.
//
// It returns a STATUS and not the sum of the counts, because main() hands this
// value to exit(): a table that answered "the total nodes" would exit with the
// total (measured: 720879 & 0xFF = 239) and a successful run would look like a
// failure.  Every helper on the way to exit() returns a status, and only a
// status.
def perft_table(name: str, fen: str, maxd: long, threaded: bool) -> long {
    print("  ", name, "  ", fen);
    let d = 1;
    while (d <= maxd) {
        let n = count(fen, d, threaded);
        if (n < 0) { return -1 };
        print(f"    depth {d}: {n:>11}");
        d = d + 1
    };
    0
}

// move_list(fen) -> print the legal moves, one per line, in generation order.
// A status, like everything else on the way to exit().
def move_list(fen: str) -> long {
    if (load(fen, 1) < 0) { return -1 };
    let n = chess.gen_all(RP, 0);
    print("  ", fen, ": ", tostring(n), " legal move", if (n == 1) { "" } else { "s" });
    let i = 0;
    while (i < n) {
        print("    ", chess.move_name(RP.mv[i]));
        i = i + 1
    };
    0
}

// split(fen, depth) -> the root divide: one line per root move with the number
// of nodes below it, then the total.  This is where a move generator's bugs
// are visible one at a time instead of in a total -- a missing castling move
// is one line short, and its absence is named.
def split(fen: str, depth: long) -> long {
    if (load(fen, depth) < 0) { return -1 };
    let n = chess.gen_all(RP, 0);
    print("  ", fen, ", depth ", tostring(depth), ": ", tostring(n), " root moves");
    let total = 0;
    let i = 0;
    while (i < n) {
        let m = RP.mv[i];
        let sub = 0;
        if (depth > 1) {
            let cap = chess.make(RP, m, 0);
            sub = chess.perft(RP, depth - 1, chess.MVSTRIDE);
            chess.unmake(RP, m, 0, cap)
        };
        print("    ", pad(chess.move_name(m), 8), tostring(sub));
        total += sub;
        i = i + 1
    };
    print("    total", pad("", 5), tostring(total));
    0
}

// ── the property check ────────────────────────────────────────────────────

// The published counts.  Every one of these is authoritative and is the reason
// this example can check itself with no reference file: startpos depth 5 is
// 4865609 nodes, Kiwipete depth 4 is 4085603, position 3 depth 5 is 674624.
type Want = { fen: str, d1: long, d2: long, d3: long, d4: long, d5: long };

let WANTS: [Want] = [
    { fen: START, d1: 20, d2: 400, d3: 8902, d4: 197281, d5: 4865609 },
    { fen: KIWIPETE, d1: 48, d2: 2039, d3: 97862, d4: 4085603, d5: -1 },
    { fen: POS3, d1: 14, d2: 191, d3: 2812, d4: 43238, d5: 674624 }
];

// self_test() -> how many checks failed.  Prints every check it makes.
//
// Three properties, and the third is the one a golden file could never catch:
//
//   1. the counts are the published ones, at every depth, for all three
//      published positions;
//   2. the threaded count EQUALS the single-threaded count, exactly, at every
//      depth of every position including the trap -- a threaded perft that
//      silently drops a subtree is wrong and totals the wrong way;
//   3. the move generator does what the rules say on the positions built to
//      break it: the en-passant pin is not a legal move, all four promotions
//      are, castling is there and goes through check when it should not.
def self_test() -> long {
    let fails = 0;
    let checks = 0;
    print("property check: published perft counts");
    let wi = 0;
    while (wi < len(WANTS)) {
        let w = WANTS[wi];
        let name = case_name(w.fen);
        let d = 1;
        while (d <= 5) {
            let want = if (d == 1) { w.d1 } else if (d == 2) { w.d2 }
                else if (d == 3) { w.d3 } else if (d == 4) { w.d4 } else { w.d5 };
            if (want > 0) {
                checks += 1;
                let got = count(w.fen, d, false);
                if (got != want) {
                    print("  FAIL ", name, " depth ", tostring(d), ": got ", tostring(got),
                        ", want ", tostring(want));
                    fails += 1
                } else {
                    print("  ok   ", name, " depth ", tostring(d), ": ", tostring(got))
                }
            };
            d = d + 1
        };
        wi += 1
    };
    print("");
    print("property check: threaded count == single-threaded count");
    let ci = 0;
    while (ci < len(CASES)) {
        let c = CASES[ci];
        let d = 1;
        while (d <= c.maxd) {
            checks += 1;
            let one = count(c.fen, d, false);
            let many = count(c.fen, d, true);
            if (one != many) {
                print("  FAIL ", c.name, " depth ", tostring(d), ": threaded ", tostring(many),
                    " vs single ", tostring(one));
                fails += 1
            } else {
                print("  ok   ", pad(c.name, 12), " depth ", tostring(d), ": both ", tostring(one))
            };
            d = d + 1
        };
        ci += 1
    };
    print("");
    print("property check: the rules that perft counts depend on");
    fails += rule_checks();
    print("");
    print("property check: ", tostring(checks + rule_run), " checks, ", tostring(fails),
        " failed");
    fails
}

// case_name(fen) -- which of the four it is.
def case_name(fen: str) -> str {
    if (fen == START) { "startpos" } else if (fen == KIWIPETE) { "kiwipete" }
    else if (fen == POS3) { "position3" } else { "ep-pin" }
}

// load_scratch(fen) -> 0 when the position parses, or -1 after reporting it.
// The rule checks work in SCRATCH, a Pos of their own, so they can neither
// disturb a search in progress nor leave pool_depth pointing somewhere else.
def load_scratch(fen: str) -> long {
    let err = chess.set_fen(SCRATCH, fen);
    if (err == "") { 0 } else {
        eputs("perft: " + fen + ": " + err + "\n");
        -1
    }
}

// gen_count(fen) -> the number of legal moves, or -1 if the FEN was refused.
def gen_count(fen: str) -> long {
    if (load_scratch(fen) < 0) { return -1 };
    chess.gen_all(SCRATCH, 0)
}

// has_move(fen, name) -> is that long-algebraic move in the legal list?
def has_move(fen: str, name: str) -> bool {
    if (load_scratch(fen) < 0) { return false };
    let n = chess.gen_all(SCRATCH, 0);
    let i = 0;
    let found = false;
    while (i < n) {
        if (chess.move_name(SCRATCH.mv[i]) == name) { found = true };
        i = i + 1
    };
    found
}

// ── the heap ──────────────────────────────────────────────────────────────

// heap_probe(fen, depth) -- the heap delta over a deep search.  Printed, not
// asserted: the number is 0 and is worth seeing rather than trusting.  It is
// measured on THIS thread, because heap_used() in a spawned thread answers 0 --
// the heap is per-thread, so the global counter never sees a worker's bytes.
def heap_probe(fen: str, depth: long, threaded: bool) -> long {
    if (load(fen, depth) < 0) { return -1 };
    // One search first, so the warm-up allocations (the FEN's split strings) are
    // already paid for and the delta measures the search alone.
    if (threaded && nworkers > 1) { perft_mt() } else { perft_st() };
    let before = heap_used();
    let nodes = if (threaded && nworkers > 1) { perft_mt() } else { perft_st() };
    let after = heap_used();
    print("  ", fen);
    print("    depth ", tostring(depth), ": ", group(nodes), " nodes, heap ",
        group(before), " -> ", group(after), " (delta ", tostring(after - before), ")");
    0
}

// ── --bench ───────────────────────────────────────────────────────────────

// bench(fen, depth) -- one thread against the pool, nodes/second and the
// speedup.  Under --bench only: a timing number cannot be in EXPECTED.
def bench(fen: str, depth: long) -> long {
    if (load(fen, depth) < 0) { return -1 };
    // Warm the pool and the caches with one untimed pass each, so the numbers
    // are steady-state.
    let t0 = clock_us();
    let warm1 = perft_st();
    let t1 = clock_us();
    let warm2 = if (nworkers > 1) { perft_mt() } else { warm1 };
    let t2 = clock_us();
    print("  ", fen, " depth ", tostring(depth), ", ", tostring(nworkers), " worker",
        if (nworkers == 1) { "" } else { "s" });
    print("    one thread : ", tostring(warm1), " nodes in ", ms_of(t1 - t0), " ms  -> ",
        rate_of(warm1, t1 - t0), " nodes/s");
    if (nworkers > 1) {
        // speedup = the single-thread time over the pool time, in hundredths so
        // that the print is integer arithmetic with no float anywhere:
        // (t_single * 100) / t_pool.  (The first version of this divided one
        // rate by another and reported 5.01x for two workers, which is not a
        // number any machine can produce.)
        let sp = 0;
        if (t2 - t1 > 0) {
            sp = ((t1 - t0) * 100) / (t2 - t1)
        };
        print("    pool       : ", tostring(warm2), " nodes in ", ms_of(t2 - t1), " ms  -> ",
            rate_of(warm2, t2 - t1), " nodes/s");
        print("    counts equal: ", if (warm1 == warm2) { "yes" } else { "NO" });
        print("    speedup    : ", f"{sp / 100.0:.2f}", "x");
        if (warm1 != warm2) { return -1 }
    } else {
        print("    pool       : not started (--threads 1: this thread does the work)")
    };
    0
}

// ms_of(us) -> milliseconds, with one decimal.  Integer arithmetic: there is no
// float->long conversion and no round(), so the tenths are done by hand.
def ms_of(us: long) -> str {
    let tenths = (us + 50) / 100;
    f"{tenths / 10}.{tenths % 10}"
}

// rate_of(n, us) -> the throughput in nodes/second, grouped so it can be read
// without counting digits.  All integer: a microsecond count and a node count
// are longs, and the only division is the one that turns them into a rate.
def rate_of(n: long, us: long) -> str {
    if (us <= 0) { return "unknown" };
    group((n * 1000000 + us / 2) / us)
}

// group(n) -> "4085603" as "4,085,603".  Groups of three from the right, with
// the leading partial group handled first so that every case is the same two
// steps: take three, glue a comma, take three.
def group(n: long) -> str {
    if (n < 1000) { return tostring(n) };
    let s = tostring(n);
    let lead = s.length % 3;
    let out = "";
    let i = 0;
    if (lead > 0) {
        out = s[0:lead];
        i = lead
    };
    while (i < s.length) {
        let piece = s[i:i + 3];
        if (out == "") { out = piece } else { out = out + "," + piece };
        i = i + 3
    };
    out
}

// ── main ──────────────────────────────────────────────────────────────────

const OPTS: [args.Opt] = [
    { long: "fen", short: "f", kind: args.STR, help: "the position to search, as a FEN (default: the built-in suite)" },
    { long: "depth", short: "d", kind: args.NUM, help: "plies to count (default: per position, see --positions)" },
    { long: "name", short: "n", kind: args.STR, help: "which built-in position: startpos | kiwipete | position3 | ep-pin" },
    { long: "positions", short: "", kind: args.BOOL, help: "list the built-in positions with their default depths" },
    { long: "moves", short: "m", kind: args.BOOL, help: "print the legal moves of the position and stop" },
    { long: "split", short: "s", kind: args.BOOL, help: "print the root divide: nodes per root move" },
    { long: "check", short: "c", kind: args.BOOL, help: "the property check: published counts, and threaded == single" },
    { long: "bench", short: "b", kind: args.BOOL, help: "nodes/second, one thread against the pool, and the speedup" },
    { long: "heap", short: "", kind: args.BOOL, help: "the heap delta over a deep search" },
    { long: "threads", short: "t", kind: args.NUM, help: "workers in the pool, 1..16 (default 4; 1 means no spawn)" }
];

// args.usage() appends the tail to the "usage:" line, so a tail that should
// read as a line of its own has to bring its own newline.
def usage_tail() -> str {
    "\n  position: --fen \"<FEN>\", or --name startpos|kiwipete|position3|ep-pin,\n  or neither for the built-in suite.  See --positions."
};

// main() -> the exit code.  IT DOES NOT SET ONE BY ITSELF: `main()` at the end
// of the file is an ordinary call, and a Y program exits 0 whatever the call
// returned unless it calls exit() itself.  An earlier version of this returned
// 1 from every error path and every error path exited 0, which is worse than no
// check at all -- a malformed FEN looked like a successful run that printed
// nothing.  `exit(main())` at the bottom of the file is what makes the return
// value mean anything.
def main() -> long {
    args.init("perft", "chess perft: count the leaf nodes of the move tree, threaded", OPTS, usage_tail());
    args.parse_or_exit(argv());
    let nthreads = args.get_long("threads", 4);
    if (nthreads < 1) {
        eputs("perft: --threads " + tostring(nthreads) + " is below 1\n");
        return 2
    };
    if (nthreads > MAXW) {
        eputs("perft: --threads " + tostring(nthreads) + " is over the pool's " + tostring(MAXW)
            + "; clamped\n");
        nthreads = MAXW
    };

    if (args.has("positions")) {
        print("built-in positions:");
        let i = 0;
        while (i < len(CASES)) {
            print("  ", pad(CASES[i].name, 12), "depth ", tostring(CASES[i].maxd), "  ", CASES[i].fen);
            i += 1
        };
        return 0
    };

    // --depth is checked ONCE, here, before any mode runs, so `--depth 0` is a
    // message and exit 2 whichever mode it was given with.  The modes below ask
    // for their own default when the flag is absent.
    let asked = want_depth(1);
    if (asked < 0) { return 2 };

    // A named position has to EXIST before anything searches it, or a typo
    // silently searches the start position instead.
    let name = args.get_str("name", "");
    if (name != "" && fen_of_name(name) == "") {
        eputs("perft: --name " + name + " is not one of the built-in positions\n");
        return 2
    };

    // The pool starts here, ONCE, and lives for the whole program.
    start_pool(nthreads);

    if (args.has("check")) {
        return self_test()
    };
    if (args.has("bench")) {
        return code(bench(want_fen(), want_depth(4)))
    };
    if (args.has("heap")) {
        return code(heap_probe(want_fen(), want_depth(5), nthreads > 1))
    };
    if (args.has("moves")) {
        return code(move_list(want_fen()))
    };
    if (args.has("split")) {
        return code(split(want_fen(), want_depth(3)))
    };

    // The default run.  Deterministic, quick, and no clock anywhere -- this is
    // what EXPECTED holds.
    print("perft -- chess perft, threaded.  ", tostring(nthreads), " worker",
        if (nthreads == 1) { "" } else { "s" });
    if (name != "") {
        // One position, to its own default depth unless --depth says otherwise.
        print("built-in positions:");
        return code(perft_table(name, fen_of_name(name), want_depth(depth_of_name(name)), false))
    };
    let fen = args.get_str("fen", "");
    if (fen != "") {
        print("custom position:");
        return code(perft_table("given", fen, want_depth(3), false))
    };
    print("built-in positions:");
    let i = 0;
    while (i < len(CASES)) {
        if (perft_table(CASES[i].name, CASES[i].fen, CASES[i].maxd, false) < 0) { return 1 };
        i += 1
    };
    0
}

// code(r) -> an exit status.  The mode helpers answer -1 for "the position was
// refused", which is not an exit status; exit(-1) would be 255, so it is
// folded to 1 here.  2 is kept for a usage mistake (a bad flag value), 1 for a
// position the program will not accept, 0 for success.
def code(r: long) -> long {
    if (r < 0) { 1 } else { r }
}

// want_fen() -> the position the flags ask for: --fen, else --name's, else the
// start position.
def want_fen() -> str {
    let f = args.get_str("fen", "");
    if (f != "") { return f };
    let n = args.get_str("name", "");
    if (n != "") { return fen_of_name(n) };
    START
}

// want_depth(d) -> --depth, else d.  Checked here as well as in reset_root, so
// a bad depth is a message and a non-zero exit rather than a count of nothing.
def want_depth(d: long) -> long {
    let v = args.get_long("depth", d);
    if (v < 1) {
        eputs("perft: --depth " + tostring(v) + " is below 1\n");
        return -1
    };
    if (v > chess.MAXDEPTH) {
        eputs("perft: --depth " + tostring(v) + " is over the " + tostring(chess.MAXDEPTH)
            + " the move buffer holds\n");
        return -1
    };
    v
}

// fen_of_name(n) -> the FEN of a built-in position, or "" if the name is not
// one -- which the caller turns into a message.
def fen_of_name(n: str) -> str {
    let i = 0;
    let out = "";
    while (i < len(CASES)) {
        if (CASES[i].name == n) { out = CASES[i].fen };
        i += 1
    };
    out
}

// depth_of_name(n) -> that position's default depth, or 3 for a name that is
// not one of them (main has already refused those).
def depth_of_name(n: str) -> long {
    let i = 0;
    let out = 3;
    while (i < len(CASES)) {
        if (CASES[i].name == n) { out = CASES[i].maxd };
        i += 1
    };
    out
}

// The exit code is main()'s RETURN value, so it has to be handed to exit()
// explicitly -- see the note on main().  The pool is stopped and joined first,
// so no worker is still parked on its semaphore when the program ends.
let code_out: long = main();
shutdown_pool();
exit(code_out);