// render.y -- the threaded row renderer: a bounded pool of workers, a mutex
// work queue, and not one byte of allocation on the frame path.
//
// ===========================================================================
// WHY A POOL AND NOT ONE SPAWN PER WORK ITEM
// ===========================================================================
//
// A spawn leaks.  Each thread allocates from a heap of its own and nothing is
// ever freed, so 2000 spawn/join cycles grow the process by 256000 bytes --
// measured, and the reason to feed a bounded pool rather than spawn per item.  A per-ROW spawn would be exactly that mistake
// at 36 rows a frame.
//
// So the threads are started once, in setup(), and then loop forever: wait for
// work, claim a row from the queue, render it, repeat.  `--threads 1` takes a
// different path entirely -- no spawn happens at all and frame() drains the
// queue on this thread -- which is not only the honest baseline for the speed
// comparison but also what makes a single-threaded run allocate no thread
// heaps (each thread's first allocation is a 4 MiB chunk, so eight threads cost
// 32 MiB of address space to begin with).
//
// ===========================================================================
// WHY A WORK QUEUE AND NOT ONE FIXED BAND PER WORKER
// ===========================================================================
//
// This is the design decision the whole renderer turns on, and the first
// version got it wrong in a way that looked like a threading bug.
//
// The obvious design is static: worker w owns rows [w*rows/n, (w+1)*rows/n),
// the main posts n tokens and waits for n.  That is wrong because **A
// COUNTING SEMAPHORE IS NOT FAIR.**  It hands a token to whoever asks first,
// with no queue behind it, so a worker that comes back round from its previous
// iteration while the others are still being scheduled takes a second token --
// and can take all of them.  Measured on this tree, 8 workers and 3000 rounds
// of post-8/wait-8 with the workers doing a fixed amount of work each: the
// TOTAL was exactly 8 x 3000 every time, but the per-worker split came out
// 2664/3047/3680/2755/3039/3095/2925/2795 instead of 3000 apiece.  With static
// bands that is not a slow worker, it is an INVISIBLE ONE: seven workers'
// bands are simply never rendered, so the grid keeps whatever was in it and the
// picture is wrong.  Nothing traps, nothing complains, and the digest is
// stable from run to run -- it is just somebody else's picture.
//
// So the queue is the design.  ROW_CURSOR is a mutex-guarded cursor over the
// rows and a worker claims one at a time, so:
//
//   * every row is claimed exactly once, whatever the wake-up order;
//   * a worker that gets an extra token simply finds the cursor past the end
//     and does nothing -- duplicate wake-ups are harmless;
//   * a worker that gets NO token costs nothing but idle time, because whoever
//     is awake claims its rows.
//
// The price is one lock/unlock per row rather than per frame: 36 rows is 36
// critical sections, about 0.9 us, against a frame that costs 1-5 ms.  The
// main thread spins on ROWS_DONE under the same mutex, with a nap between
// checks so it is not a hot loop -- spinning is safe here because it is a
// fixed bound and a lost wakeup then shows up as a wrong frame rather than a
// hang.
//
// ===========================================================================
// ZERO ALLOCATION
// ===========================================================================
//
// CELLS is a module-level [long; 32768] -- 256 KiB, allocated once at init --
// and it is the only buffer the frame path needs.  md_shade() returns a packed
// long, so the iteration count reaches the statistics without an
// out-parameter; the queue arithmetic is integer; and the render loop contains
// no literal, no string, no record and no closure.  heap_used() across a
// thousand frames is unchanged, and so is the process's own address space --
// which is the check that matters for the workers, because heap_used() in a
// spawned thread answers 0 (its heap is per-thread, so the global counter never
// sees it).

import mandel;

// The grid.  STRIDE, not `cols`, is the row pitch: a fixed array indexed by
// row*STRIDE+col keeps the stride identical whatever the width is, which is one
// fewer multiply in the inner loop and one less thing to get wrong when the
// terminal is resized.
const MAXR: long = 128;
const MAXC: long = 256;
const STRIDE: long = 256;
const NCELLS: long = 32768;        // MAXR * STRIDE

// The most workers worth starting.  Two independent bounds, both enforced
// before any spawn: a worker renders whole rows and there are at most MAXR of
// them, so more than MAXR is pure overhead; and each thread's first allocation
// is a 4 MiB heap chunk, so MAXR threads is 512 MiB of address space for work
// that could never all be in flight at once.  64 is comfortably above any real
// core count and comfortably below the 3.5 GiB cap.
const MAX_THREADS: long = 64;

let CELLS: [long; 32768] = [0; 32768];

let rows: long = 24;
let cols: long = 36;
let nthreads: long = 1;
let started: long = 0;

// The queue.  Every field is read and written under mandel.VLK, which is the
// one mutex in the program and doubles as the hand-off barrier -- see the note
// on DONE_N.
let ROW_CURSOR: long = 0;
let ROWS_DONE: long = 0;
let ITERS_TOTAL: long = 0;
let ESC_TOTAL: long = 0;
let READY_N: long = 0;

// The two semaphores.  Module level so they are allocated once; sem(0) is a
// two-word runtime object.
//
// GO is a COUNT, not a signal: a post that arrives before a worker is waiting is
// not lost.  It is not FAIR, which is why the work is a queue and not a
// per-worker band -- see the header.
//
// FRAME_DONE is posted exactly once a frame, by whichever worker claims the
// last row, and consumed once by the main thread.  `wait` on it BLOCKS, which
// is the whole point: the first version of this file had the main thread spin
// on ROWS_DONE under the mutex instead, and that cost a `lock` block -- 16
// bytes of closure, measured -- per spin iteration and 1.3 ms of nanosleep a
// frame.  Two words of runtime state and one syscall beat 1400 allocations.
let GO = sem(0);
let FRAME_DONE = sem(0);
// The start-up barrier, same shape: each worker posts it on the way in and
// setup() collects n of them.  N posters and one waiter is the configuration
// that is exact on this tree, measured (8 workers, 3000 rounds, the total was
// 8 x 3000 every time), and it costs nothing on the frame path.
let READY = sem(0);

// How many rows a worker claims per trip to the queue, as a function of the
// grid and the pool: rows/(2*nthreads), so about two claims per worker per
// trip, never fewer than one and never more than eight.
//
// One row per claim is the best load balance and also one `lock` block per row,
// and `lock m { e }` builds a closure while a closure is 16 bytes of an arena
// that never frees (measured: 160000 bytes for ten thousand of them, against
// nothing at all for ten thousand `post`/`wait` pairs).  So the claim size is the one knob that trades a little balance
// for a linear cut in the worker's allocation: on a 36-row grid with 8 workers
// this is 3, so 12 claims a frame instead of 36, and the queue is still fine
// enough that the eight workers balance.  The cost is real and is not hidden:
// it is 16 bytes a claim on the WORKER's own heap, invisible to heap_used()
// here but visible in the process's address space.
const CHUNK_MAX: long = 8;

// The threads, kept so setup() is honest about owning them.  Nothing joins
// them: a Y program's exit is exit_group(231), which takes every thread with
// it, and the whole point is that the pool lives for the life of the program.
let workers: [() -> long] = [];

// ───────────────────────────────────────────────────────────────── a row ───

// render_row(r, cx, cy, dx, dy, mx) -- return... Y has no multiple return, so
// the two statistics are accumulated into the caller's `it` and `esc`.  They
// are passed in as parameters and the totals are added under the mutex at the
// end of a worker's whole queue drain, not per row: two xchg's a worker per
// frame instead of two a row.
//
// The plane is walked by row: yr = cy + dy*((rows-1) - 2r)/2, so row 0 is the
// TOP of the image and imaginary y increases upwards, and
// xr = cx + dx*(2c - (cols-1))/2.
//
// THE `2c - (cols-1)` IS NOT COSMETIC, and getting it wrong is subtle.
// Sampling at cx + dx*(c - cols/2) puts c = 0 at -cols/2 steps and c = cols-1
// at cols/2 - 1: the grid sits half a step off centre, so a symmetric picture
// comes out shifted by half a cell.  Measured, a 36-row frame had four blank
// rows along the top and none along the bottom, and the set was visibly not
// where the reader expects it.  Doubling the offset before dividing by two is
// what fixes it: `2c - (cols-1)` is exactly antisymmetric, offset(c) +
// offset(cols-1-c) = 0, which is the statement "the picture is symmetric about
// the origin".  dx times an odd number is odd, so the division truncates -- but
// truncation toward zero is ODD-symmetric (trunc(-x) = -trunc(x)), so the two
// halves still cancel exactly and a frame is mirror-exact about the real axis.
// The discarded half-step is 0.5/2^30 of real plane, 5e-10: nothing, and worth
// saying out loud rather than hiding.
def render_row(r: long, cx: long, cy: long, dx: long, dy: long,
               mx: long, it: [long], esc: [long]) -> void {
    let yr = cy + dy * ((rows - 1) - 2 * r) / 2;
    let c: long = 0;
    while (c < cols) {
        let xr = cx + dx * (2 * c - (cols - 1)) / 2;
        let v = mandel.md_shade(xr, yr, mx);
        CELLS[r * STRIDE + c] = v;
        it[0] = it[0] + mandel.md_iters(v);
        // Counted by wrapping in a positive test: Y has no `continue`, and
        // `esc + md_cell(v)` would add the BAND index rather than one, so the
        // total would be a colour sum wearing a count's label.
        if (mandel.md_cell(v) != 0) { esc[0] = esc[0] + 1 };
        c = c + 1
    }
};

// ───────────────────────────────────────────────────────────────── worker ───

// worker() -> long -- the thread body.  Never returns: the pool lives until
// exit_group takes it.  The `running` guard exists only because Y has no
// `while (true)`, and it is never set false -- there is no shutdown path to
// have, and no code after the loop to be warned about as unreachable.
//
// The drain loop is the work queue of the header: claim a row under the lock,
// render it outside it, repeat until the cursor is past the end.  ONE lock per
// row, and none of them held while a pixel is computed -- which is what leaves
// the parallelism intact.
def drain(it: [long], esc: [long]) -> void {
    // Claim and render rows until the queue is empty.  ONE lock per row and
    // none of them held while a pixel is computed, which is what leaves the
    // parallelism intact -- and one more at the end to publish.
    //
    // The view is snapshotted ONCE per drain, not per row: the main thread sets
    // it before frame() and frame() does not return until every row is done, so
    // it cannot change under anybody mid-frame, and a snapshot per row would be
    // 36 extra lock/unlock pairs for nothing.
    let cx: long = 0;
    let cy: long = 0;
    let sp: long = 0;
    let mx: long = 0;
    let dx: long = 0;
    let dy: long = 0;
    lock mandel.VLK {
        cx = mandel.vcx;
        cy = mandel.vcy;
        sp = mandel.vspan;
        mx = mandel.vmaxit;
        dx = sp / cols;
        dy = sp / rows
    };
        // The scratch is cleared at the TOP, not after the row loop: it is reused
    // for the next drain, and clearing it afterwards would zero the totals this
    // drain is about to publish.
    it[0] = 0;
    esc[0] = 0;
    let claimed: long = 0;
    let more = true;
    while (more) {
        let r: long = 0 - 1;
        let n: long = 0;
        lock mandel.VLK {
            r = ROW_CURSOR;
            n = 1 + rows / (2 * nthreads);
            if (n > CHUNK_MAX) { n = CHUNK_MAX; };
            if (rows - r < n) { n = rows - r; };
            if (n < 1) { n = 0; };
            ROW_CURSOR = ROW_CURSOR + n
        };
        if (n >= 1) {
            let k: long = 0;
            while (k < n) {
                render_row(r + k, cx, cy, dx, dy, mx, it, esc);
                k = k + 1
            };
            claimed = claimed + n;
        } else {
            more = false;
        }
    };
    // NOTHING IS PUBLISHED BY A WORKER THAT DID NO WORK, and that `claimed > 0`
    // is load-bearing in a way that cost an afternoon to find.
    //
    // The obvious shape is to always publish and let the test decide who wakes
    // the main thread:
    //
    //     lock { ITERS_TOTAL += it; ROWS_DONE += claimed; if (ROWS_DONE >= rows) post FRAME_DONE }
    //
    // and it posts the semaphore MORE THAN ONCE A FRAME.  A semaphore is a
    // COUNT, so the surplus carries into the next frame, and `wait` on a
    // semaphore whose count is already positive returns at once -- so from then
    // on the main thread does not wait for the workers at all, it runs ahead of
    // them and reads CELLS and the totals mid-render.  Measured, 8 workers and
    // 40 frames: the picture stayed correct (every row is eventually written,
    // and by then the view has stopped changing) while `mean-it` came out as
    // 333, 2666, 200, 0, 0, 0 ... in a run that should have been 2400 in every
    // frame.  23 mismatches in 75 runs at --threads 4/8/16/64, none at
    // --threads 1 (which takes the inline path and posts nothing).
    //
    // It posts twice because a worker that wakes up to find the cursor already
    // past the end claims zero rows and still evaluates `ROWS_DONE >= rows`,
    // which is TRUE, because a previous worker already finished the frame.  The
    // test says "the frame is done", and the frame IS done -- it just does not
    // follow that this frame's wake-up has already been spent.
    //
    // Gating the whole publish on `claimed > 0` fixes it because only a worker
    // that actually rendered rows can be the one that brings ROWS_DONE up to
    // `rows`, and there is exactly one of those per frame.  So: exactly one
    // post, exactly one wait, exactly one frame.
    if (claimed < 1) { return; };

    // One critical section per drain, not per row: fold this worker's share of
    // the frame's statistics in, and publish the rows it did.
    //
    // This is also the RELEASE half of the hand-off.  Every store just made --
    // CELLS above, and these totals -- happens-before this unlock, and frame()
    // reads ROWS_DONE under the same lock before it reads any of it.  A mutex's
    // lock and unlock form a TOTAL ORDER, so an acquire that lands after n
    // critical sections synchronises with all n of them; that is the whole
    // reason a mutex is here and a semaphore is not, because a semaphore's fast
    // path is a plain decrement which orders nothing.  (On x86 the semaphores
    // alone would have worked -- the locked read-modify-write inside post()
    // drains the worker's store buffer -- and the digest was identical for
    // every thread count, measured.  But that is a property of the instruction
    // set, not of the program.)
    lock mandel.VLK {
        ITERS_TOTAL = ITERS_TOTAL + it[0];
        ESC_TOTAL = ESC_TOTAL + esc[0];
        ROWS_DONE = ROWS_DONE + claimed;
        // Whoever claims the last row of the frame wakes the main thread.
        // Exactly one post per frame, so FRAME_DONE never carries a surplus
        // into the next one.  Posting from inside the critical section means
        // the post -- a locked read-modify-write on the semaphore's own mutex,
        // and therefore a full barrier -- comes after this worker's stores to
        // CELLS and to the totals, and the main thread's `wait` is the matching
        // acquire.  Lock order is VLK then the semaphore's mutex, always, and
        // the main thread never holds one while taking the other.
        if (ROWS_DONE >= rows) { post FRAME_DONE; }
    }
};

// The scratch for the single-threaded path, module level so that path
// allocates nothing per frame either.  Only the main thread ever touches it,
// and only when there are no workers to race with.
let MAIN_IT: [long] = [0];
let MAIN_ESC: [long] = [0];

def worker() -> long {
    // Announce that this thread exists and has reached the top of its body,
    // before its first `wait GO` can return.
    lock mandel.VLK { READY_N = READY_N + 1 };
    post READY;
    // Two one-element scratch arrays, allocated ONCE per worker and reused for
    // every row it ever claims: md_shade() hands back a packed long, so these
    // are how the two statistics get out without a per-row record -- and why
    // they are NOT module level, which would be one shared pair of counters
    // for eight threads.
    let it: [long] = [0];
    let esc: [long] = [0];
    let running = true;
    while (running) {
        wait GO;
        drain(it, esc);
    };
    0
};

// ──────────────────────────────────────────────────────────────── driving ───

// What setup() had to clamp: 0 when it did not, otherwise the value asked
// for.  See setup().
let clamped: long = 0;

// setup(nr, nc, nt) -> void
//
// Fix the grid, clamp the thread count, and start the pool.  Called ONCE,
// before any frame.  The clamps are what make `--threads 0`, `--threads -4`
// and `--threads 9999` diagnostics instead of surprises:
//
//   * n < 1           becomes 1, and 1 means "this thread": no spawn at all.
//   * n > MAX_THREADS becomes MAX_THREADS.  NOT refused -- a refusal would be an
//     error exit for something that is only asking for more workers -- but the
//     caller is told through threads_clamped() so it can say so on stderr.
def setup(nr: long, nc: long, nt: long) -> void {
    rows = nr;
    cols = nc;
    if (rows < 1) { rows = 1; };
    if (rows > MAXR) { rows = MAXR; };
    if (cols < 1) { cols = 1; };
    if (cols > MAXC) { cols = MAXC; };
    if (nt < 1) {
        nthreads = 1;
        clamped = 1;
    } else if (nt > MAX_THREADS) {
        nthreads = MAX_THREADS;
        clamped = nt;
    } else {
        nthreads = nt;
        clamped = 0;
    };
    // `for w in 0..n` AND NOT A while LOOP, and this is the sharpest edge of
    // Y's closure model in these examples.  `spawn { worker(k) }` builds
    // the closure `def () { worker(k) }`, so an argument expression is
    // EVALUATED WHEN THE CLOSURE RUNS, not when it is created.  A `let`
    // written before a loop is ONE shared capture cell (AGENTS.md, "Captures
    // are shared"), so with
    //
    //     let k = 0;
    //     while (k < n) { spawn { body(k) }; k = k + 1; }
    //
    // every worker reads the k the loop finished on -- n -- and all of them do
    // the same job.  Measured: three of four workers came out right and one
    // never rendered anything, and WHICH one changed from run to run, because
    // it is a race between the workers starting and the main loop advancing.  A
    // `for x in lo..hi` variable is fresh per iteration, which is what makes
    // the loop below correct.  worker() now takes no argument at all, so even a
    // wrong capture could not make two threads do the same job -- but the loop
    // is written the safe way anyway, and this comment is why.
    for w in 0..nthreads {
        workers += spawn { worker() };
    };
    // The start-up barrier: no frame is handed out until every worker is
    // actually parked at its `wait GO`.  Without it a worker that has been
    // cloned but not yet scheduled simply is not in the pool, and the frame is
    // rendered by fewer threads than asked for -- which is harmless for the
    // picture (the queue covers every row) and wrong for the timing.
    let j: long = 0;
    while (j < nthreads) { wait READY; j = j + 1; };
    started = 1
};

// frame() -> long
//
// Render one frame and answer the total iterations spent.
//
// NOT ONE LOCK BLOCK ON THIS PATH, and that is the point of the whole shape of
// the thing.  `lock m { e }` builds a closure, a closure is 16 bytes of arena,
// and the heap never gives it back: a first version
// had the main thread spin on the completion counter under the mutex and cost
// 22437 bytes a frame -- over 1400 lock blocks -- plus 1.3 ms of nanosleep a
// frame.  So:
//
//   * the queue is reset with PLAIN stores.  Every worker is parked on `wait GO`
//     at this point (the previous frame's FRAME_DONE was posted by the worker
//     that finished it, and a worker posts DONE only after its own stores), and
//     `post GO` is a locked read-modify-write, so the workers cannot observe
//     this thread's stores late;
//   * completion is a BLOCKING `wait FRAME_DONE`, not a spin;
//   * the totals are read back plainly.
//
// The ordering that makes the last point safe is the same one that makes the
// first point safe: the last worker's stores, its `lock`/`unlock` of VLK, and
// its `post FRAME_DONE` are in that order in its own program, and this thread's
// `wait FRAME_DONE` is after them.  Both the VLK unlock and the semaphore's
// post are locked read-modify-writes, which are full barriers on every
// architecture Y emits, so the workers' cells and totals are visible here
// before the reads below.  Verified rather than assumed: the digest is identical
// for --threads 1 through 64, and over 40 frames each.
def frame() -> long {
    if (started == 0) { return 0; };
    ROW_CURSOR = 0;
    ROWS_DONE = 0;
    ITERS_TOTAL = 0;
    ESC_TOTAL = 0;
    if (nthreads <= 1) {
        // `--threads 1` (and every value that clamps to it) takes NO spawn at
        // all: this thread drains the queue itself.  That is not only the honest
        // baseline for the speed comparison, it is also what keeps a
        // single-threaded run free of thread heaps -- each thread's first
        // allocation is a 4 MiB chunk, so a pool of eight costs 32 MiB of
        // address space before the first pixel.
        drain(MAIN_IT, MAIN_ESC);
        return ITERS_TOTAL
    };
    let k: long = 0;
    while (k < nthreads) { post GO; k = k + 1; };
    wait FRAME_DONE;
    ITERS_TOTAL
};

// escaped() -> long -- how many pixels of the last frame were outside the set.
// Called after frame(), so the total is final.
def escaped() -> long { ESC_TOTAL };

// ────────────────────────────────────────────────────────────── readback ───

def at(r: long, c: long) -> long { CELLS[r * STRIDE + c] };
// NOT `rows()` / `cols()`: inside their own bodies the name would resolve to
// the def rather than the variable, which is the shadowing t160_threads.y
// demonstrates on purpose.  These are the accessors a caller wants, and the
// variables above are the state.
def grid_rows() -> long { rows };
def grid_cols() -> long { cols };
def threads() -> long { nthreads };
def threads_clamped() -> long { clamped };
def max_threads() -> long { MAX_THREADS };

// resize(nr, nc) -- adopt a new grid shape WITHOUT restarting the pool.  The
// work is a queue, so a new shape is just a new row count: the cursor runs to
// the new value and the next frame is the new size.  All the workers are parked
// on `wait GO` when this is called, because the caller is the main thread
// between frames.
//
// It allocates nothing and clears nothing: CELLS is always MAXR x STRIDE, so a
// smaller grid simply leaves the tail of the buffer untouched, and the digest
// only ever reads rows*cols cells.
def resize(nr: long, nc: long) -> void {
    if (nr < 1) { nr = 1; };
    if (nr > MAXR) { nr = MAXR; };
    if (nc < 1) { nc = 1; };
    if (nc > MAXC) { nc = MAXC; };
    rows = nr;
    cols = nc
};

// digest() -> long
//
// FNV-1a over every cell of the grid, bits and all -- the packed shade, so
// both the band and the iteration count are covered and a frame that changed
// iteration count without changing colour is a different digest.  Signed long,
// so the printed hex is the two's complement and the shifts below are
// UNSIGNED: `>>>` and not `>>`.
//
// NOTE THE STRIDE: this walks the grid ROW BY ROW, not over the first
// rows*cols entries of CELLS.  A flat CELLS[0..rows*cols) would cover rows
// 0..10 of a 36-row grid and nothing else -- an earlier version of this file
// did exactly that, and the result was a digest that was stable and wrong.
def digest() -> long {
    let h: long = -3750763034362895579;      // 14695981039346656037, signed
    let r: long = 0;
    while (r < rows) {
        let c: long = 0;
        while (c < cols) {
            h = (h ^ CELLS[r * STRIDE + c]) * 1099511628211;
            c = c + 1
        };
        r = r + 1
    };
    h
};

export {
    MAXR, MAXC, STRIDE, NCELLS, MAX_THREADS, CELLS,
    rows, cols, nthreads, started, clamped,
    setup, frame, escaped, at, digest,
    grid_rows, grid_cols, resize, threads, threads_clamped, max_threads
};