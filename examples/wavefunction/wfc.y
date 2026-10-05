// wfc.y -- wave function collapse by constraint propagation.
//
//   setup(w, h, tilemask, seed)      build the grid and propagate to fixpoint
//   next_event()                     ONE step of the search, as an event
//   solve()                          drive next_event() to a verdict
//
// The search is the textbook algorithm and nothing cleverer:
//
//   1. every cell starts as the full set of available tiles, narrowed by the
//      boundary (a cell on the top edge may not have a north socket);
//   2. propagate: a worklist of cells whose mask shrank; for each, every
//      neighbour's mask is intersected with the union of what can face it.
//      A mask that becomes EMPTY is a contradiction.  Masks only ever shrink,
//      so the worklist drains and the fixpoint is reached -- no `break` is
//      wanted here, the guard flag IS the loop;
//   3. choose the uncollapsed cell of LOWEST ENTROPY, ties to the LOWEST CELL
//      INDEX, and collapse it to one tile drawn in proportion to the weights;
//   4. on a contradiction, undo the log back to the last decision and choose
//      again.  A step budget turns "no solution" and "gave up" into two
//      different, both non-zero, messages rather than a hang.
//
// WHY ONE CELL PER EVENT.  The interactive loop and the deterministic text
// dump drive the SAME state machine -- there is no second implementation to
// drift out of step.  `next_event()` is where entropy is read, a tile is
// chosen and the undo log is written, so the terminal shows the real search
// and the golden file records the same one.
//
// WHY NO `break` AND NO `continue`.  Both are undefined names in Y
// (ORCHESTRATOR.md 2.9).  `propagate()` and `solve()` use a guard flag with an
// explicit terminal assignment; `pick()` and `choose_r()` wrap their bodies in
// a positive condition (`if (CNT[i] > 1) { ... }`).  Written out in full below,
// which is also what makes the step counter honest: there is exactly one place
// each phase can stop.

import tiles;
// std's seeded generator (splitmix64).  It replaced the xorshift64 this file
// carried; see "the PRNG" below.
import random;

const MAXW: long = 64;
const MAXH: long = 64;
const NCELLMAX: long = 4096;         // MAXW * MAXH

const LOGCAP: long = 131072;         // undo-log entries: 3 longs each, 3 MiB
// MAXEV -- the event log saturates here rather than growing: `record()` stops
// appending, and the counters that the search itself depends on (collapses,
// contradictions, the undo log) are all separate and unaffected.  What a
// saturated log costs is the REPLAY length -- the interactive path and --frames
// scale their progress by EV_N -- and on the instances either is used for
// (24x14: 335 events) there is a factor of 46 of headroom.  A pathological
// instance (16x16 `elbows` makes 100 000 of them) would replay its first 16384
// events and stop, which is a display limit and not a wrong answer.
const MAXEV: long = 16384;           // recorded events (decisions + backtracks)
const MAXDEC: long = 16384;          // decisions on the stack
const BUDGET: long = 4000000;        // propagation steps before giving up

const R_OK: long = 0;
const R_UNSAT: long = 1;
const R_BUDGET: long = 2;

const E_COLLAPSE: long = 1;
const E_BACKTRACK: long = 2;
const E_DONE: long = 3;
const E_FAIL: long = 4;

const M_CONTRA: long = 1;            // a mask became empty
const M_OVERFLOW: long = 2;          // the undo log is full

// ─────────────────────────────────────────────────────────── the grid state ───

let GW: long = 0;
let GH: long = 0;
let NC: long = 0;
let AVAIL: long = 0;

let MASK: [long; 4096] = [0; 4096];
let WSUM: [long; 4096] = [0; 4096];  // total weight of the tiles in MASK
let CNT: [long; 4096] = [0; 4096];   // how many tiles are in MASK
let HENT: [long; 4096] = [0; 4096];  // Shannon entropy of MASK, Q30
let LASTDEC: [long; 4096] = [0; 4096];   // event index that collapsed the cell

// The worklist.  INQ keeps one entry per cell at most, so 4096 slots is a
// bound and not a hope: qpush() is a no-op for a cell already queued.
let QQ: [long; 4096] = [0; 4096];
let INQ: [byte; 4096] = [0; 4096];
let QH: long = 0;
let QT: long = 0;
let QN: long = 0;

// The undo log: (cell, mask before, LASTDEC before) for every change, so a
// backtrack is a reverse walk and nothing has to be recomputed.
let UL_I: [long; 131072] = [0; 131072];
let UL_M: [long; 131072] = [0; 131072];
let UL_L: [long; 131072] = [0; 131072];
let UN: long = 0;

// The decision stack.  Only the LOG MARK is needed: a rewind walks the undo log
// down to it, which restores every cell the decision and its propagation
// touched.  Storing the cell and the tile here as well would be two more
// arrays that nothing ever reads.
let DL: [long; 16384] = [0; 16384];
let DN: long = 0;

// The event log, for the frames and for --check.
let EV_C: [long; 16384] = [0; 16384];
let EV_T: [long; 16384] = [0; 16384];
let EV_H: [long; 16384] = [0; 16384];
let EV_N: long = 0;

// Counters.
let STEPS: long = 0;
let COLLAPSES: long = 0;
let BACKTRACKS: long = 0;
let CONTRA: long = 0;
let UNDOMAX: long = 0;
let STATUS: long = 0;
let INJECT: long = 0;                // --inject: a deliberate defect, for --check

// Where the last contradiction was found.  A WFC contradiction is only
// actionable if you know which neighbour of which cell emptied, so these three
// are part of the program rather than a print: --time and --check read them.
let CONTRA_CELL: long = 0 - 1;
let CONTRA_FROM: long = 0 - 1;
let CONTRA_DIR: long = 0 - 1;
let CONTRA_OLD: long = 0;
let CONTRA_NEW: long = 0;

// How many rewinds found the entry below their mark already reflected in the
// masks (XTRA_SAME) and how many found it still in force (XTRA_DIFF).
let XTRA_SAME: long = 0;
let XTRA_DIFF: long = 0;
let XTRA_CELL: long = 0 - 1;

// Cells whose INITIAL domain was already empty.  Propagation cannot detect
// this: a mask of zero has nothing to narrow, so an unsatisfiable instance whose
// contradiction is in the initial domain would sail through propagate(), every
// cell would look "decided" to pick() (a zero mask is not "more than one tile"),
// and the search would announce a solution made of empty masks.  setup() counts
// them and solve() refuses.
let INITBAD: long = 0;

// ───────────────────────────────────────────────────────────────── the PRNG ───
//
// THE GENERATOR IS NOW STD'S.  This block used to be a xorshift64 of its own --
// a module-level `RS`, an `rs_next` and an `rnd(n)` doing `(RS >>> 33) % n` --
// and all three are gone.  A collapse now draws its tile index from
// `import random` (src/y/std/random.y, splitmix64): setup() calls
// random.seed(), and choose() calls random.below(WSUM[c]).
//
// What is unchanged is the contract, which is all the solver ever asked of it:
// deterministic given the seed, identical on every run, no float anywhere, and a
// value in 0..n-1 for a frontier of n cells (n < 1 answers 0 here as it did
// before -- `random.below` answers 0 for n < 1 too, so choose() is safe on a
// zero-weight mask, which only an unweighted range can produce).
//
// What changes is the STREAM, and this example is unusually exposed to that
// because the draw picks WHICH TILE each cell collapses to: same seed, different
// picture.  Three pinned numbers in check.y and one instance in gate.conf were
// chosen by searching for a seed under the OLD stream, and all four were
// re-found under the new one; each is named where it is used and README.md
// carries the table.  The properties they stand for -- that an instance exists
// which needs a rewind at all, that one exists which exhausts the budget, and
// that same seed gives same picture -- are properties of the solver and survive;
// the specific (size, seed) pairs are not, and are re-pinned rather than
// asserted from memory.  See check.y's t_backtrack() and t_giveup().
//
// The `>>> 33` note in the old block was about THIS generator and no longer
// applies to the solver; the `>>>` uses that remain in the program are sink.y's
// hex and fixed-point writers, which are about non-negative values by
// construction.

// ────────────────────────────────────────────────────────────── log2 in Q30 ───
//
// log2(k) for k = 1..129, rounded to Q30.  Index 0 is 0: it is never read for a
// real logarithm (a weight is >= 1 and a weight sum is >= 1) and "no choice"
// is honestly 0 bits of entropy.
//
// A TABLE, NOT A CALL.  The weights are small integers and their sums top out
// at 37 for the full tile set, so there are only 129 values to know and a table
// is exact to one ulp.  Interpolating an approximation instead would put a
// fixed-point division in the hot path, where `a / b` on two Q30 values
// returns the RATIO rather than a scaled quotient (ORCHESTRATOR.md 2.4a) --
// the trap that cost one example in this campaign six defects.  Nothing in
// this file divides two fixed-point numbers.

let LOG2: [long; 130] = [
    0, 0, 1073741824, 1701840526, 2147483648, 2493151308, 2775582350, 3014374395,
    3221225472, 3403681053, 3566893132, 3714536416, 3849324174, 3973316893,
    4088116219, 4194991834, 4294967296, 4388879807, 4477422877, 4561177437,
    4640634956, 4716214921, 4788278240, 4857137666, 4923065998, 4986302616,
    5047058717, 5105521579, 5161858043, 5216217375, 5268733658, 5319527783,
    5368709120, 5416376943, 5462621631, 5507525702, 5551164701, 5593607959,
    5634919261, 5675157419, 5714376780, 5752627662, 5789956745, 5826407415,
    5862020064, 5896832361, 5930879490, 5964194365, 5996807822, 6028748789,
    6060044440, 6090720333, 6120800541, 6150307757, 6179263403, 6207687724,
    6235599867, 6263017963, 6289959199, 6316439878, 6342475482, 6368080726,
    6393269607, 6418055448, 6442450944, 6466468200, 6490118767, 6513413672,
    6536363455, 6558978192, 6581267526, 6603240689, 6624906525, 6646273512,
    6667349783, 6688143142, 6708661085, 6728910811, 6748899243, 6768633039,
    6788118604, 6807362106, 6826369486, 6845146467, 6863698569, 6882031114,
    6900149239, 6918057901, 6935761888, 6953265826, 6970574185, 6987691287,
    7004621314, 7021368309, 7037936189, 7054328744, 7070549646, 7086602453,
    7102490613, 7118217469, 7133786264, 7149200142, 7164462157, 7179575272,
    7194542365, 7209366229, 7224049581, 7238595058, 7253005227, 7267282582,
    7281429548, 7295448485, 7309341691, 7323111399, 7336759787, 7350288973,
    7363701023, 7376997946, 7390181702, 7403254201, 7416217306, 7429072832,
    7441822550, 7454468188, 7467011431, 7479453923, 7491797272, 7504043043,
    7516192768, 7528247942];

// entropy(mask) -> long -- Shannon entropy of a possibility set, in Q30.
//
//     H = log2(W) - ( sum over t of w_t * log2(w_t) ) / W
//
// with W the total weight.  The one division is by the plain integer W and both
// terms are already Q30, so the result is Q30 to within a rounding ulp.  A
// single-tile mask returns 0 exactly (no special case needed, and the early
// return keeps it exact rather than merely small).
def entropy(mask: long) -> long {
    if (mask == 0) { return 0 };
    if ((mask & (mask - 1)) == 0) { return 0 };
    let w = 0;
    let acc = 0;
    let t = 0;
    while (t < tiles.NT) {
        if ((mask & (1 << t)) != 0) {
            let wt = tiles.WT[t];
            w = w + wt;
            acc = acc + wt * LOG2[wt];
        };
        t = t + 1
    };
    let li = 0;
    if (w >= 1 && w <= 129) { li = LOG2[w] };
    if (INJECT == 9) { li = LOG2[w + 1] };              // MUTATION: off-by-one row
    li - acc / w
};

// popcount(m) -> long -- how many tiles a mask holds, by hand: there is no
// popcount builtin and the compiler's own one is not exposed.
def popcount(m: long) -> long {
    let n = 0;
    let t = 0;
    while (t < tiles.NT) {
        if ((m & (1 << t)) != 0) { n = n + 1 };
        t = t + 1
    };
    n
};

// recompute(i) -> void -- the derived columns of cell i, from MASK[i] alone.
//
// CNT, WSUM and HENT are kept so pick() is a scan of three arrays rather than
// sixteen ORs per cell per decision.  check.y asserts each of them against
// MASK[i] recomputed bit by bit, so a stale column cannot hide: that is the
// "possibility-set bookkeeping matches the bitmask" property, and it is why
// these three are kept in one function that nothing else writes.
def recompute(i: long) -> long {
    let m = MASK[i];
    CNT[i] = popcount(m);
    if (INJECT == 10) { CNT[i] = CNT[i] + 1 };       // MUTATION: off by one
    let w = 0;
    let t = 0;
    while (t < tiles.NT) {
        if ((m & (1 << t)) != 0) { w = w + tiles.WT[t] };
        t = t + 1
    };
    WSUM[i] = w;
    HENT[i] = entropy(m);
    if (INJECT == 15) { HENT[i] = HENT[i] + 1 };        // MUTATION: stale entropy
    0
};

// setmask(i, nm) -> long -- shrink cell i to nm, logging the way back.
//
// Returns 0 normally and M_OVERFLOW when the undo log is full, which is a
// BUDGET failure and not an out-of-bounds write: the guard is here precisely
// so the log can never be overrun, because a fixed-array overrun is a runtime
// trap and traps print to stdout (ORCHESTRATOR.md 2.6).
def setmask(i: long, nm: long) -> long {
    if (UN >= LOGCAP) { return M_OVERFLOW };
    UL_I[UN] = i;
    UL_M[UN] = MASK[i];
    UL_L[UN] = LASTDEC[i];
    UN = UN + 1;
    if (UN > UNDOMAX) { UNDOMAX = UN; };
    MASK[i] = nm;
    recompute(i);
    0
};

// ────────────────────────────────────────────────────────────── the worklist ───

def qreset() -> void { QH = 0; QT = 0; QN = 0 };

def qpush(i: long) -> void {
    if (INQ[i] == 1) { return };
    INQ[i] = 1;
    QQ[QT] = i;
    QT = QT + 1;
    if (QT >= NCELLMAX) { QT = 0; };
    QN = QN + 1
};

def qpop() -> long {
    let i = QQ[QH];
    INQ[i] = 0;
    QH = QH + 1;
    if (QH >= NCELLMAX) { QH = 0; };
    QN = QN - 1;
    i
};

// ─────────────────────────────────────────────────────────────────── set-up ───

def set_inject(k: long) -> void { INJECT = k };

// setup(w, h, avail, seed) -> long -- a fresh grid, a fresh log, a fresh PRNG,
// and the initial propagation already queued.  Called once per solve; --frames
// calls it once per frame, which is why nothing here may depend on what came
// before.
def setup(w: long, h: long, avail: long, seed: long) -> long {
    GW = w;
    GH = h;
    NC = w * h;
    AVAIL = avail;
    tiles.build(avail);
    // std's generator, seeded here: every solve restarts the stream, which is
    // why --frames (which calls setup once per frame) still prints the same
    // picture three times.  `--seed 0` is a legal seed and needs no special
    // case: random.seed(0) offsets the state by the golden-ratio constant
    // before the first draw, which is exactly why splitmix64's author says so.
    random.seed(seed);
    STATUS = R_OK;
    STEPS = 0;
    COLLAPSES = 0;
    BACKTRACKS = 0;
    CONTRA = 0;
    UNDOMAX = 0;
    UN = 0;
    DN = 0;
    EV_N = 0;
    CONTRA_CELL = 0 - 1;
    CONTRA_FROM = 0 - 1;
    CONTRA_DIR = 0 - 1;
    XTRA_SAME = 0;
    XTRA_DIFF = 0;
    XTRA_CELL = 0 - 1;
    INITBAD = 0;
    qreset();
    let y = 0;
    while (y < h) {
        let x = 0;
        while (x < w) {
            let i = y * w + x;
            // The boundary is part of the initial domain, not a special case:
            // a cell on an edge may not have a socket facing off the grid.
            let m = avail;
            if (y == 0) { m = m & tiles.boundary(0) };
            if (y == h - 1) { m = m & tiles.boundary(2) };
            if (x == 0) { m = m & tiles.boundary(3) };
            if (x == w - 1) { m = m & tiles.boundary(1) };
            if (INJECT == 12 && y == 0) { m = avail };    // MUTATION: no N edge
            MASK[i] = m;
            LASTDEC[i] = 0;
            recompute(i);
            x = x + 1
        };
        y = y + 1
    };
    // INQ is cleared over the WHOLE array, not over NC.  A cell still flagged
    // from the previous solve would refuse to be queued, propagation would never
    // reach it, and setup() would return a grid whose masks are not even mutually
    // consistent -- while the first solve, whose INQ was clean, looked perfect.
    // This is the defect the property battery found: the 4x3 instance came back
    // with three disagreeing pairs only on its SECOND setup.
    let q = 0;
    while (q < NCELLMAX) {
        INQ[q] = 0;
        q = q + 1
    };
    let i = 0;
    while (i < NC) {
        if (MASK[i] == 0) { INITBAD = INITBAD + 1 };
        qpush(i);
        i = i + 1
    };
    NC
};

// neighbour(i, d) -> long -- the cell at direction d from cell i, or -1 when
// that would leave the grid.  -1 rather than a wrap, so every edge case needs
// no special handling anywhere else.  Note `i / GW` is an integer division of
// two plain longs; there is no fixed point anywhere near it.
def neighbour(i: long, d: long) -> long {
    let x = i % GW;
    let y = i / GW;
    let nx = x;
    let ny = y;
    if (d == 0) { ny = y - 1 } else if (d == 1) { nx = x + 1 }
    else if (d == 2) { ny = y + 1 } else { nx = x - 1 };
    if (INJECT == 13 && d == 2) { nx = x + 1 };         // MUTATION: S reads as E
    let go = 1;
    if (nx < 0 || nx >= GW) { go = 0 };
    if (ny < 0 || ny >= GH) { go = 0 };
    if (go == 1) { ny * GW + nx } else { 0 - 1 }
};

// ─────────────────────────────────────────────────────────────── propagate ───
//
// propagate() -> long -- run the worklist to a fixpoint.
//
// Returns 0 for a fixpoint, M_CONTRA when some cell's mask went empty, and
// M_OVERFLOW when the undo log filled up.  The guard flag is the loop
// condition and `rc` the terminal assignment; there is no `break` because the
// queue has to keep draining until it is provably empty.
def propagate() -> long {
    let rc = 0;
    let go = QN > 0;
    while (go) {
        let i = qpop();
        STEPS = STEPS + 1;
        let d = 0;
        while (d < 4 && rc == 0) {
            let j = neighbour(i, d);
            if (INJECT == 1 && d == 2) { j = 0 - 1 };    // MUTATION: skip the S step
            if (j >= 0) {
                let allowed = tiles.adj(MASK[i], d);
                let nm = MASK[j] & allowed;
                if (INJECT == 2) { nm = MASK[j] | allowed };    // MUTATION: union
                if (nm != MASK[j]) {
                    if (nm == 0) {
                        CONTRA = CONTRA + 1;
                        CONTRA_CELL = j;
                        CONTRA_FROM = i;
                        CONTRA_DIR = d;
                        CONTRA_OLD = MASK[j];
                        CONTRA_NEW = allowed;
                        if (INJECT != 3) { rc = M_CONTRA };     // MUTATION: ignore it
                    } else {
                        let r = setmask(j, nm);
                        if (r != 0) { rc = r }
                        else if (INJECT != 17) { qpush(j) };  // MUTATION: one pass
                    }
                }
            };
            d = d + 1
        };
        go = QN > 0 && rc == 0;
        if (STEPS > BUDGET) { rc = M_OVERFLOW }
    };
    rc
};

// ──────────────────────────────────────────────────────────────── selection ───
//
// THE DETERMINISM RULE, stated once and asserted by check.y:
//
//   the cell of LOWEST Shannon entropy is collapsed, and among cells of EQUAL
//   entropy the one with the LOWEST CELL INDEX (row-major, i = y*W + x).
//
// Equal entropy is the common case, not an edge case: at the start every cell
// has the same population, and the tile set is the same for all of them.  The
// scan runs in index order and keeps the first minimum, which is exactly that
// rule; --inject=4 keeps the LAST minimum instead, which is still perfectly
// deterministic and still wrong, and check.y catches it.
def pick() -> long {
    let best = 0 - 1;
    let bh = 0;
    let i = 0;
    while (i < NC) {
        // `if (CNT[i] > 1)` IS the `continue`: skip the cells already decided.
        if (CNT[i] > 1) {
            let take = 0;
            if (best < 0) { take = 1 }
            else if (INJECT == 5) { take = 0 }      // MUTATION: first open cell wins
            else if (HENT[i] < bh) { take = 1 }
            else if (HENT[i] == bh) {
                if (INJECT == 4) { take = 1 } else if (i < best) { take = 1 }
            };
            if (take == 1) { best = i; bh = HENT[i] }
        };
        i = i + 1
    };
    if (INJECT == 16 && DN >= 1) { return 0 - 1 };        // MUTATION: "all done" early
    best
};

// choose_r(mask, r) -> long -- the weighted draw, as a pure mapping.
//
// One uniform integer r in [0, W) and a walk over the tiles in INDEX order: a
// tile is picked when the running total first passes it, so tile index breaks
// ties between equal weights.  Split out from choose() so check.y can assert
// the distribution exactly -- over r = 0..W-1 every tile must come up exactly
// weight(t) times -- instead of asserting it statistically.
def choose_r(mask: long, r: long) -> long {
    let acc = 0;
    let t = 0;
    let out = 0 - 1;
    while (t < tiles.NT) {
        if ((mask & (1 << t)) != 0) {
            if (INJECT == 6) { acc = acc + 1 }        // MUTATION: counts tiles,
            else { acc = acc + tiles.WT[t] };         // not weight
            if (out < 0 && r < acc) { out = t }
        };
        t = t + 1
    };
    if (out < 0) { out = last_tile(mask) };
    out
};

// last_tile(m) -> long -- the highest tile index in a mask, for a draw whose r
// ran past the end of the range (which only an unweighted range can do).  Kept
// so that case is a visible clamp rather than a trap or a wrong answer.
def last_tile(m: long) -> long {
    let t = tiles.NT - 1;
    while (t > 0) {
        if ((m & (1 << t)) != 0) { return t };
        t = t - 1
    };
    0
};

// choose(c) -> long -- collapse cell c: one seeded draw over its own weights.
def choose(c: long) -> long {
    choose_r(MASK[c], random.below(WSUM[c]))
};

// first_bit(m) -> long -- the lowest tile index in a mask; 0 for an empty mask.
def first_bit(m: long) -> long {
    let t = 0;
    while (t < tiles.NT) {
        if ((m & (1 << t)) != 0) { return t };
        t = t + 1
    };
    0
};

// ──────────────────────────────────────────────────────────────── backtrack ───
//
// backtrack() -> bool -- rewind to the previous decision.  False when the
// stack is empty, which is the answer "this instance has no solution".
//
// The rewind is a reverse walk of the undo log down to the mark the decision
// recorded, so every cell that decision and its propagation touched goes back
// to exactly the mask it had -- including LASTDEC, which is why the log
// carries three columns and not one.
def backtrack() -> bool {
    if (DN == 0) { return false };
    DN = DN - 1;
    // MUTATION: the mark is one entry too far forward, so the decision's OWN
    // collapse is never undone -- the classic off-by-one in a rewind, and the one
    // version of it that is always visible: the cell the search is about to choose
    // again is still collapsed to the tile it just rejected.
    let mark = if (INJECT == 8) { DL[DN] + 1 } else { DL[DN] };
    // MUTATION: the classic off-by-one -- one entry too many is popped AND
    // restored before the loop even starts, so a cell the undone decision never
    // touched comes back with an older mask.  Two earlier versions of this defect
    // were invisible: one only decremented UN after the loop (where `UN > mark` is
    // already false, so it never fired at all), and one threw the entry away
    // without restoring it (on this instance the entry it destroyed was never
    // needed again).  A mutation you cannot catch is usually one you have not made
    // visible.
    // A DIAGNOSTIC, always on: is the entry just below the mark already reflected
    // in the current masks?  XTRA_SAME counts the rewinds where an off-by-one
    // rewind would have restored a cell to the value it already had -- which is how
    // two earlier versions of the rewind defect were invisible here: the cell they
    // disturbed was also touched by the undone decision, so the loop's own restore
    // of that cell overwrote the damage.  Reporting the count is what turns "I
    // think this mutation is equivalent" into something a reader can check.
    if (UN > mark) {
        let below = UL_I[UN - 1];
        if (MASK[below] == UL_M[UN - 1]) {
            XTRA_SAME = XTRA_SAME + 1
        } else {
            XTRA_DIFF = XTRA_DIFF + 1;
            XTRA_CELL = below
        }
    };
    while (UN > mark) {
        UN = UN - 1;
        let cell = UL_I[UN];
        if (INJECT == 7) {
            MASK[cell] = MASK[cell]        // MUTATION: the mask is never restored
        } else {
            MASK[cell] = UL_M[UN]
        };
        LASTDEC[cell] = UL_L[UN];
        recompute(cell);
        qpush(cell)
    };
    // Everything already queued stays queued, and the queue is exactly the set
    // of cells that may have been narrowed since the last fixpoint, so one more
    // propagate() re-establishes arc consistency.  Clearing the queue here
    // instead would be the bug that turns a correct search into one that
    // accepts unsatisfiable grids, so the queue is deliberately left alone.
    true
};

// ─────────────────────────────────────────────────────────────────── events ───

// record(c, t, h, dec) -> void -- append an event.
//
// c is the cell decided and t the tile it was given, or -1 for a backtrack.  h
// is the entropy of the cell BEFORE the collapse, which is the number check.y
// compares against the minimum it recomputes: recorded after the collapse it
// would be the entropy of a one-tile mask, which is always exactly 0.
def record(c: long, t: long, h: long) -> void {
    if (EV_N >= MAXEV) { return };
    EV_C[EV_N] = c;
    EV_T[EV_N] = t;
    EV_H[EV_N] = h;
    EV_N = EV_N + 1
};

// next_event() -> long -- ONE step of the search.
//
//   E_COLLAPSE  a cell was chosen and given a tile
//   E_BACKTRACK a contradiction was undone
//   E_DONE      every cell holds exactly one tile
//   E_FAIL      no solution (R_UNSAT) or the budget ran out (R_BUDGET)
//
// An event is a DECISION, not a propagation step: propagation runs to a
// fixpoint inside the event, because a frame that stopped mid-propagation
// would show a half-reduced possibility set and no entropy worth looking at.
def next_event() -> long {
    if (INITBAD > 0) {
        // A contradiction that is already in the initial domain: no amount of
        // propagation will find it, because there is nothing left to narrow.
        CONTRA = CONTRA + 1;
        CONTRA_CELL = 0;
        CONTRA_FROM = 0 - 1;
        CONTRA_DIR = 0 - 1;
        STATUS = R_UNSAT;
        return E_FAIL
    };
    let rc = propagate();
    if (rc == M_CONTRA) {
        if (backtrack() == false || INJECT == 14) {          // MUTATION: fatal
            STATUS = R_UNSAT;
            return E_FAIL
        };
        BACKTRACKS = BACKTRACKS + 1;
        record(0 - 1, 0 - 1, 0);
        return E_BACKTRACK
    };
    if (rc == M_OVERFLOW) { STATUS = R_BUDGET; return E_FAIL };
    if (STEPS > BUDGET) { STATUS = R_BUDGET; return E_FAIL };

    let c = pick();
    if (c < 0) { STATUS = R_OK; return E_DONE };
    if (DN >= MAXDEC) { STATUS = R_BUDGET; return E_FAIL };

    let mark = UN;
    // The entropy is read BEFORE the collapse, while the cell still holds its
    // whole possibility set.  Recorded afterwards it would be the entropy of a
    // one-tile mask -- which is always exactly 0 -- and the recorded entropy
    // would be a constant that verifies nothing.
    let hpre = HENT[c];
    let t = choose(c);
    let r = setmask(c, 1 << t);
    if (r != 0) { STATUS = R_BUDGET; return E_FAIL };
    DL[DN] = mark;
    DN = DN + 1;
    COLLAPSES = COLLAPSES + 1;
    STEPS = STEPS + 1;
    LASTDEC[c] = EV_N;
    // The collapsed cell goes back on the worklist.  WITHOUT THIS the collapse
    // is never applied to its neighbours: setmask() narrows one cell and
    // nothing else, so the search would finish a grid whose cells disagree --
    // a self-consistent-looking picture of an unsatisfiable instance, which is
    // exactly the failure a golden file cannot see.
    qpush(c);
    record(c, t, hpre);
    E_COLLAPSE
};

// solve() -> long -- drive next_event() to a verdict: R_OK, R_UNSAT, R_BUDGET.
def solve() -> long {
    let e = 0;
    let go = true;
    while (go) {
        e = next_event();
        if (e == E_DONE || e == E_FAIL) { go = false }
    };
    STATUS
};

// ─────────────────────────────────────────────────────────────────── audit ───
//
// audit() -> long -- the solver's OWN count of adjacency violations in the
// finished grid, printed by the golden run.  It is NOT the oracle: check.y
// carries an independent one built from its own copy of the socket table, and
// that is the number the property battery trusts.  This one exists so the
// golden file can print a line about the invariant for a reader to cross-examine.
def audit() -> long {
    let bad = 0;
    let y = 0;
    while (y < GH) {
        let x = 0;
        while (x < GW) {
            let i = y * GW + x;
            let a = first_bit(MASK[i]);
            let d = 0;
            while (d < 4) {
                let j = neighbour(i, d);
                let open = tiles.edge_bit(a, d);
                if (j < 0) {
                    if (open != 0) { bad = bad + 1 }
                } else {
                    let b = first_bit(MASK[j]);
                    if (open != tiles.edge_bit(b, tiles.opposite(d))) { bad = bad + 1 }
                };
                d = d + 1
            };
            x = x + 1
        };
        y = y + 1
    };
    bad
};

// undecided() -> long -- how many cells still hold more than one tile.
def undecided() -> long {
    let n = 0;
    let i = 0;
    while (i < NC) {
        if (CNT[i] > 1) { n = n + 1 };
        i = i + 1
    };
    n
};

// mean_entropy() -> long -- the mean entropy of the undecided cells, Q30.  Zero
// on a finished grid, which is the point: it is only read mid-solve.
def mean_entropy() -> long {
    let acc = 0;
    let n = 0;
    let i = 0;
    while (i < NC) {
        if (CNT[i] > 1) { acc = acc + HENT[i]; n = n + 1 };
        i = i + 1
    };
    if (n == 0) { return 0 };
    acc / n
};

export {
    MAXW, MAXH, NCELLMAX, BUDGET, R_OK, R_UNSAT, R_BUDGET,
    E_COLLAPSE, E_BACKTRACK, E_DONE, E_FAIL,
    GW, GH, NC, AVAIL, MASK, WSUM, CNT, HENT, LASTDEC,
    EV_C, EV_T, EV_H, EV_N,
    STEPS, COLLAPSES, BACKTRACKS, CONTRA, UNDOMAX, STATUS, INJECT,
    CONTRA_CELL, CONTRA_FROM, CONTRA_DIR, CONTRA_OLD, CONTRA_NEW, INITBAD,
    XTRA_SAME, XTRA_DIFF, XTRA_CELL,
    UL_I, UL_M, UN, DL, DN,
    set_inject, setup, propagate, pick, choose, choose_r, out_uniform, backtrack,
    next_event, solve, entropy, popcount, recompute, setmask, neighbour, audit,
    last_tile,
    undecided, mean_entropy, first_bit
};