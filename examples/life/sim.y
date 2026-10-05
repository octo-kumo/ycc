// sim.y -- Conway's Game of Life on a torus: the grid store, the step
// function, and the built-in patterns.
//
// ===========================================================================
// THE ONE RULE IN THIS FILE: it allocates four fixed arrays ONCE, when new()
// is called, and never again.  The Y heap is an arena and nothing is ever
// freed (ORCHESTRATOR.md 2.7), so a cellular automaton that allocated a cell
// buffer per generation would walk straight into the 3.5 GiB cap -- a 200x100
// grid is 160 KiB a generation, so 20 000 generations and then it is over.
// Hence:
//
//   * the store is four `[long; 262144]` arrays, sized at compile time,
//     bigger than any grid -- the grid is only ever *narrower* than the
//     store, and `life.y` refuses a --size that does not fit;
//   * a generation is computed into `nxt` and the two references are then
//     SWAPPED (`t = s.cur; s.cur = s.nxt; s.nxt = t`), which is two pointer
//     writes and no copying at all.  This is the double-buffer the brief asks
//     for: `cur` always holds the generation you are looking at and `nxt` is
//     the scratch it was written into;
//   * the torus wrap is four small tables built once in new(), so the inner
//     loop never divides: no `%`, no `if` for the wrap, no out-of-range index.
//
// Verify with `./life --frames 100000 --stats`, which prints heap_used() at
// both ends; the delta is zero apart from the headless report itself.
//
// ===========================================================================
// WHY THE WRAP IS PRECOMPUTED RATHER THAN WRITTEN IN THE LOOP
//
// The obvious spelling is `(y + dy + h) % h`, and it is correct: y >= 0,
// dy >= -1 and h >= 1, so the operand is never negative and Y's `%` (which is
// C's, and would return a negative remainder on a negative operand) is never
// asked for one.  But it is three integer ops per neighbour, eight times per
// cell, and the table version is one array read.  px/nx/py/ny hold the four
// wrapped indices, so the hot loop reads what it needs and adds.
//
// ===========================================================================
// THE RULE, WRITTED OUT
//
//   a live cell with 2 or 3 live neighbours survives; a dead cell with
//   exactly 3 live neighbours is born; anything else is dead in the next
//   generation.  That is B3/S23, Conway's original rule, on all eight
//   neighbours of a cell, with the grid wrapping in both axes.

const MAXCELLS = 262144;   // the store size.  The array types below have to
                            // spell it as the literal 262144: a type position
                            // takes an integer literal only, not a const.
const MAXW = 512;
const MAXH = 512;

// A grid and its scratch.  Every array is fixed-size and allocated once;
// w and h are the logical size and always satisfy w*h <= MAXCELLS.
type Sim = {
    w: long,
    h: long,
    cur: [long; 262144],     // generation s.gen -- the one you look at
    nxt: [long; 262144],     // the scratch: generation s.gen + 1
    age: [long; 262144],     // generations each live cell has lived (1 = born
    age2: [long; 262144],    // this generation), so a renderer can colour by
                             // age without keeping a history
    px: [long; 512],         // the torus, precomputed in new():
    nx: [long; 512],         //   px[i] = (i + w - 1) % w    the cell to the left
    py: [long; 512],         //   nx[i] = (i + 1) % w        ... and to the right
    ny: [long; 512],         //   py / ny are the same in y
    pop: long,               // live cells in cur
    gen: long,               // generations run so far
    peak: long,              // the most live cells seen in any generation
    frozen_at: long,         // the first generation that changed nothing (-1),
    extinct_at: long         // the first generation with no live cells (-1)
};

// new(w, h) -> Sim -- the ONLY allocation this module ever makes: four
// 262144-long arrays (8 MiB together) and four 512-long wrap tables.  The
// caller has already checked that w and h are in range.
def new(w: long, h: long) -> Sim {
    let c1: [long; 262144] = [0; 262144];
    let c2: [long; 262144] = [0; 262144];
    let a1: [long; 262144] = [0; 262144];
    let a2: [long; 262144] = [0; 262144];
    let pxa: [long; 512] = [0; 512];
    let nxa: [long; 512] = [0; 512];
    let pya: [long; 512] = [0; 512];
    let nya: [long; 512] = [0; 512];
    let s: Sim = {
        w: w, h: h,
        cur: c1, nxt: c2,
        age: a1, age2: a2,
        px: pxa, nx: nxa, py: pya, ny: nya,
        pop: 0, gen: 0, peak: 0,
        frozen_at: 0 - 1, extinct_at: 0 - 1
    };
    // The wrap tables.  `(i + w - 1) % w` cannot be negative here -- i >= 0,
    // w >= 1 -- so this is the one place the torus is defined, and it is
    // written once instead of 8 times per cell per generation.
    for i in 0..MAXW {
        pxa[i] = (i + w - 1) % w;
        nxa[i] = (i + 1) % w;
        pya[i] = (i + h - 1) % h;
        nya[i] = (i + 1) % h;
    };
    s
};

// clear(s) -- every cell dead, every age 0.  Both stores, so a grid is clean
// whichever one the next step reads.
def clear(s: Sim) {
    for i in 0..s.w * s.h {
        s.cur[i] = 0;
        s.nxt[i] = 0;
        s.age[i] = 0;
        s.age2[i] = 0
    };
    s.pop = 0;
    s.peak = 0;
    s.gen = 0;
    s.frozen_at = 0 - 1;
    s.extinct_at = 0 - 1
};

// set(s, x, y, v) -- one cell.  x and y are logical coordinates and MUST be
// inside the grid: life.y checks that before it gets here, because indexing
// is bounds-checked and an out-of-range index is a runtime trap on stdout.
def set(s: Sim, x: long, y: long, v: long) {
    s.cur[y * s.w + x] = v;
    if (v == 1) { s.age[y * s.w + x] = 1; } else { s.age[y * s.w + x] = 0; }
};

// count(s) -- recount the live cells into s.pop and reset the trackers.  Cheap
// (one linear pass) and called only when the grid has just been filled.
def count(s: Sim) {
    let n = 0;
    let k = s.w * s.h;
    let cur = s.cur;
    for i in 0..k {
        if (cur[i] == 1) { n = n + 1; };
    };
    s.pop = n;
    s.peak = n;
    s.gen = 0;
    s.frozen_at = 0 - 1;
    if (n == 0) { s.extinct_at = 0; } else { s.extinct_at = 0 - 1 }
};

// ===========================================================================
// THE STEP.  Read-only over cur, write-only over nxt, then swap.
//
// This is the function the whole example exists to get right inside Y's two
// loop shapes, neither of which has `break` or `continue`:
//
//   * the 3x3 neighbour sum is UNROLLED, not a nested 3x3 loop.  A loop needs
//     a `continue` to skip the centre cell (dx == 0 && dy == 0), and Y has no
//     `continue`; the idiom is to guard the body instead, but at eight
//     neighbours per cell that is eight extra branches in the hottest loop in
//     the program.  Written out, the eight adds read like the rule and cost
//     nothing.  (For comparison, the guarded form is one line:
//     `if (dy != 0 || dx != 0) { n = n + cur[...] }` -- see the note above the
//     function for why the unrolled one won.)
//   * the outer loop has no early exit either: it runs exactly h rows, which
//     is the whole point, and every "are we done" decision lives in the
//     caller's guard flag, not in here.
// ===========================================================================
def step(s: Sim) -> long {
    let w = s.w;
    let h = s.h;
    let cur = s.cur;
    let nxt = s.nxt;
    let age = s.age;
    let age2 = s.age2;
    let px = s.px;
    let nx = s.nx;
    let py = s.py;
    let ny = s.ny;

    let pop = 0;
    let changed = false;

    for y in 0..h {
        let up = py[y] * w;      // the row above, wrapped
        let mid = y * w;         // this row
        let dn = ny[y] * w;       // the row below, wrapped
        for x in 0..w {
            let lx = px[x];       // the column to the left, wrapped
            let rx = nx[x];       // ... and to the right, wrapped
            // Eight neighbours: three above, two beside, three below.  The
            // centre cell (mid + x) is deliberately not in the sum.
            let n = cur[up + lx] + cur[up + x] + cur[up + rx]
                  + cur[mid + lx] + cur[mid + rx]
                  + cur[dn + lx] + cur[dn + x] + cur[dn + rx];
            let al = cur[mid + x];
            // B3/S23: born of exactly 3, or alive with 2.  One `if` and one
            // `else` nested inside it, because the two arms agree in type and
            // a `||` of two tests would be the same predicate written longer.
            let born = 0;
            if (n == 3) { born = 1; } else { if (al == 1 && n == 2) { born = 1; }; };
            nxt[mid + x] = born;
            pop = pop + born;
            // The age ramp: a survivor is one generation older, a newborn is
            // 1, a cell that died is 0.
            let na = 0;
            if (born == 1) {
                if (al == 1) { na = age[mid + x] + 1; } else { na = 1; }
            };
            age2[mid + x] = na;
            if (al != born) { changed = true; }
        }
    };

    // The swap.  Three reference writes, no data moved: this is why the
    // arena cannot leak here no matter how many generations run.
    let t = s.cur;
    s.cur = s.nxt;
    s.nxt = t;
    let t2 = s.age;
    s.age = s.age2;
    s.age2 = t2;

    s.pop = pop;
    s.gen = s.gen + 1;
    if (pop > s.peak) { s.peak = pop; };
    // A generation that changed nothing is the last one: the automaton is a
    // pure function of its state, so every later generation equals it too.
    if (!changed && s.frozen_at < 0) { s.frozen_at = s.gen; };
    if (pop == 0 && s.extinct_at < 0) { s.extinct_at = s.gen; };
    s.gen
};

// ===========================================================================
// THE BUILT-IN PATTERNS, as bitmaps: '#' is a live cell, '.' is dead, and
// '/' ends a row.  A bitmap rather than RLE because these are hand-written
// constants -- the RLE parser in rle.y exists for patterns that come from
// outside, and feeding it a string from here would be a strange little loop.
//
// life.y's --help text lists the same names; add to both.
// ===========================================================================

// The glider: 5 cells, 4 generations per step, 2 cells of travel.  It is the
// smallest thing that moves, and the run everyone recognises.
const GLIDER =
    ".#./..#/###";

// A blinker: 3 cells in a row, one generation flips it to a column.  The
// shortest oscillator -- period 2.
const BLINKER =
    "###";

// A block: 4 cells, and it never moves again.  The shortest still life.
const BLOCK =
    "##/##";

// A lightweight spaceship: 9 cells, period 4, 2 cells of travel every 4
// generations -- the smallest pattern that crosses the grid in a straight
// line without ever changing shape or population.
const LWSS =
    ".#..#/#..../#...#/####.";

// The Gosper glider gun: 36x9, the first pattern found (1970) that makes
// cells forever.  It emits a glider every 30 generations -- one off each
// corner, which is why the corners are asymmetric -- and never dies, so on a
// torus it keeps growing until it wraps into its own output.
const GOSPER =
    "........................#.........../" +
    "......................#.#.........../" +
    "............##......##............##/" +
    "...........#...#....##............##/" +
    "##........#.....#...##............../" +
    "##........#...#.#.#....#.#........../" +
    "..........#.....#.......#.........../" +
    "...........#...#..................../" +
    "............##......................";

// by_name(nm) -> str -- the bitmap for a --pattern name, or "" when there is
// no such pattern (life.y turns that into a diagnostic and exit 1; it must
// never be handed on to a parser that would trap).
def by_name(nm: str) -> str {
    if (nm == "glider") { return GLIDER; };
    if (nm == "gosper") { return GOSPER; };
    if (nm == "lwss") { return LWSS; };
    if (nm == "blinker") { return BLINKER; };
    if (nm == "block") { return BLOCK; };
    if (nm == "empty") { return ""; };
    ""
};

// names() -> str -- the pattern names, for the usage text and the summary.
def names() -> str {
    "glider | gosper | lwss | blinker | block | random | empty"
};

// random_fill(s, seed, pct) -- the one random pattern, and it is NOT random
// at all until you give it a seed: `seed` feeds a Lehmer LCG (the classic
// 48271/2^31-1 multiplier), so the same seed fills the same grid on every
// machine and every run.  life.y calls this with an explicit seed, never with
// a clock or an unseeded generator, so the default path is deterministic.
//
// pct is a percentage of cells that start alive.  The draw is
// `next() % 100 < pct`, so the generator only has to be uniform over a
// modulus, not over anything wider.
def random_fill(s: Sim, seed: long, pct: long) -> long {
    // A Lehmer LCG in the module's own state: one long, never allocated.
    let st = seed % 2147483647;
    if (st <= 0) { st = st + 2147483646; };
    let p = pct;
    if (p < 0) { p = 0; };
    if (p > 100) { p = 100; };
    let n = 0;
    let k = s.w * s.h;
    let cur = s.cur;
    for i in 0..k {
        st = (st * 48271) % 2147483647;
        let hit = 0;
        if (st % 100 < p) { hit = 1; };
        cur[i] = hit;
        if (hit == 1) { s.age[i] = 1; } else { s.age[i] = 0; };
        n = n + hit
    };
    n
};

// place(s, bitmap) -> bool -- centre a "/"-separated bitmap on the grid and
// recount.  false when the pattern does not fit, which is a diagnostic and
// not a crash: the caller says so and exits 1.  (A pattern larger than the
// grid is the one way this program can run off the end of a row, so the check
// is here, before any index is computed.)
def place(s: Sim, bitmap: str) -> bool {
    let rows = bitmap.split("/");
    let ph = len(rows);
    let pw = 0;
    foreach (r in rows) {
        if (len(r) > pw) { pw = len(r); }
    };
    clear(s);
    if (ph == 0) { count(s); return true; };      // --pattern empty
    if (pw > s.w || ph > s.h) { return false; };
    let ox = (s.w - pw) / 2;
    let oy = (s.h - ph) / 2;
    for y in 0..ph {
        let row = rows[y];
        // The inner loop runs to the WIDEST row, so a shorter row has to be
        // tested before it is indexed: string indexing is bounds-checked and a
        // ragged bitmap would otherwise trap.  (This program ships ragged rows
        // nowhere -- but the guard is two comparisons and it is the difference
        // between "a bitmap that is not rectangular" and "a runtime error".)
        for x in 0..pw {
            // A str index is a `byte`, so the '#' is written as 35.  (It is
            // not `row[x] == "#"`: that is `'==' compares byte with str`.)
            if (x < len(row) && row[x] == 35) { s.cur[(y + oy) * s.w + x + ox] = 1; };
        };
    };
    count(s);
    true
};

// place_cell(s, x, y) -> bool -- one cell from an RLE run, in grid
// coordinates.  false when it lands outside the grid, which is the RLE
// parser's job to report as a clean error.
def place_cell(s: Sim, x: long, y: long) -> bool {
    if (x < 0 || y < 0 || x >= s.w || y >= s.h) { return false; };
    s.cur[y * s.w + x] = 1;
    s.age[y * s.w + x] = 1;
    true
};

// text(s) -> [str] -- the grid as text rows, '#' alive and '.' dead.  For
// --dump and the golden captures.  Allocates (one string per row), so it is
// a reporting call, not something to put in a frame loop.
def text(s: Sim) -> [str] {
    let out: [str] = [];
    for y in 0..s.h {
        let line = "";
        let base = y * s.w;
        for x in 0..s.w {
            if (s.cur[base + x] == 1) { line += "#"; } else { line += "."; }
        };
        out += line
    };
    out
};

export {
    MAXCELLS, MAXW, MAXH, Sim,
    new, clear, set, count, step,
    GLIDER, BLINKER, BLOCK, LWSS, GOSPER, by_name, names,
    random_fill, place, place_cell, text
};
