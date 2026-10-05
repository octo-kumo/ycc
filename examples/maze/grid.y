// grid.y -- the maze itself: dimensions, walls, three generators, the corridor
// statistics that make them comparable, and the render-kind buffer.
//
// ─────────────────────────────────────────────────────────────────────────
// THE REPRESENTATION.  A maze is a w x h grid of CELLS with a wall between
// each pair of neighbours, so it draws as a (2w+1) x (2h+1) grid of CHARACTERS
// with a cell at every even row and column.  There is no cell object: a cell is
// its index, `y * w + x`, into one flat fixed array.  That is the whole reason
// the hot paths here allocate nothing -- a `[long; 40401]` allocated once is
// 323 KiB and costs nothing more for the life of the process, where an array of
// records would cost one 64-byte heap cell per cell per frame (ORCHESTRATOR.md
// 2.7: a record literal in a loop body is 64 bytes EVERY iteration).
//
// `cw` holds two bits per cell and stores OPEN passages, not walls:
//     bit 0 (1)   the passage to the EAST neighbour   (cw[i] % 2)
//     bit 1 (2)   the passage to the SOUTH neighbour  (cw[i] / 2)
// A fresh maze is all zeros, i.e. every wall standing, so "reset" is one clear
// loop and a boundary cell needs no special case: its east/south passage simply
// never gets opened.  Storing open rather than closed also makes carving a
// `+=`, which is the cheapest possible update.
//
// WEST and NORTH are read from the neighbour's east/south bit, so there are two
// bits per cell and not four.
//
// ─────────────────────────────────────────────────────────────────────────
// DIRECTIONS.  0 = north, 1 = east, 2 = south, 3 = west, clockwise, so the
// opposite of d is (d + 2) % 4 and a "random direction" is a random rotation
// of a scan, not a table of six cases.

import rng;

// The largest logical maze.  201 x 201 = 40401 cells; the render buffer is the
// (2w+1) x (2h+1) expansion of that, 403 x 403 = 162409 characters.  Array
// sizes have to be integer literals (there is no expression in a type
// position), so the numbers are spelled out below and these carry the same
// values for the reader -- the same convention tui uses.
const MAXW = 201;
const MAXH = 201;
const NCELL = 40401;         // MAXW * MAXH
const RMAX = 162409;         // (MAXW*2+1) * (MAXH*2+1)

// Kruskal's edge list: one entry per adjacency, at most
// MAXW*(MAXH-1) + (MAXW-1)*MAXH = 80400, packed as cell*4 + direction.
const EMAX = 80416;

// The generator names, so a report can label a row without duplicating the
// spelling.  maze.y has its own copy for its --gen parsing; this one exists for
// the tools in this folder that print tables.
let GENS: [str] = ["rb", "prim", "kruskal"];

let DXA: [long; 4] = [0, 1, 0, 0 - 1];          // by direction 0..3
let DYA: [long; 4] = [0 - 1, 0, 1, 0];

// ── the grid ───────────────────────────────────────────────────────────────
let cw: [byte; 40401] = [0; 40401];     // passage bits, see the header
let gv: [byte; 40401] = [0; 40401];     // generator scratch: 0 unseen, 1 taken
let dv: [byte; 40401] = [0; 40401];     // degree, filled by grid_degree()
let cm: [byte; 40401] = [0; 40401];     // corridor marking
let work: [long; 40401] = [0; 40401];   // backtracker stack / Prim frontier
let uf: [long; 40401] = [0; 40401];     // Kruskal union-find parent
let ebuf: [long; 80416] = [0; 80416];   // Kruskal edge list
let rk: [long; 162409] = [0; 162409];  // render kinds, RW * RH of them

// The three arrays the solver and the renderer share.  They live HERE rather
// than in astar.y because grid_paint() consumes two of them and the solver
// fills all three: astar.y imports grid, so the dependency runs one way, and a
// pair of array parameters is not an option anyway (a fixed [long; N] is not a
// [long], so it cannot be handed to a def at all -- the same rule that makes
// tui's termios buffers growable [byte]).
//   sord  the solver's expansion order, sno of them: the ORDER cells were
//         expanded in, which is what the --frames overlay animates
//   solv  the current solution, cell 0 .. cell plen
//   soli  the previous solution, kept so the two solvers can be compared
let sord: [long; 40401] = [0; 40401];
let solv: [long; 40401] = [0; 40401];
let soli: [long; 40401] = [0; 40401];
let sno: long = 0;

let GW: long = 39;        // cells across
let GH: long = 11;        // cells down
let NCE: long = 429;      // cells in all
let RW: long = 79;        // rendered characters across
let RH: long = 23;        // rendered characters down

// The statistics grid_stats() fills.  Module level because they are read by the
// driver after the call, and because a record to carry six of them back would
// be a heap allocation per generator -- which this example's whole pitch is
// that it does not have.
let s_dead: long = 0;     // cells with exactly one open passage
let s_junc: long = 0;     // cells with three or four
let s_corr: long = 0;     // maximal runs of degree-2 cells
let s_long: long = 0;     // the longest such run
let s_total: long = 0;    // their summed length
let s_bkt: [long; 6] = [0; 6];   // length buckets 1-4 5-8 9-16 17-32 33-64 65+

// ─────────────────────────────────────────────────────────────────────────
// setup

// grid_setup(w, h) -> void -- take a w x h maze, every wall standing.
//
// Nothing is allocated: the arrays are module level and sized for the worst
// case, so this is a clear loop over the first w*h entries and nothing else.  A
// terminal resize, or --size, or a `g` regenerate all land here and cost one
// pass over the grid.
def grid_setup(w: long, h: long) -> void {
    GW = w;
    GH = h;
    NCE = w * h;
    RW = w * 2 + 1;
    RH = h * 2 + 1;
    grid_clear()
};

// grid_clear() -> void -- every wall standing again.
//
// The generators call this THEMSELVES, each one, at the top.  That is not
// tidiness, it is a correctness requirement: the comparison table in maze.y
// generates three mazes in a row inside one process, so whichever generator
// does not reset first carves on top of whatever the last one left.  Each would
// still report exactly NCE-1 passages of its own, but the DEGREE counts would
// then add up to more than 2*(NCE-1), which is how this was caught: prim
// reported 6 dead ends and 305 junctions in a 429-cell tree, and
// 6 + 2*118 + 3*305 = 1157 degrees against 856 passages.  The picture still
// looked like a maze; only the handshake lemma said otherwise.
//
// grid_setup calls it too, so a --size or a resize cannot leave the old walls
// standing either.
def grid_clear() -> void {
    let i = 0;
    while (i < NCE) {
        cw[i] = 0;
        gv[i] = 0;
        dv[i] = 0;
        cm[i] = 0;
        i = i + 1
    }
};

// cell(x, y) -> long -- the index of a cell.  Callers must know it is in range.
def cell(x: long, y: long) -> long { y * GW + x };

// nb(x, y, d) -> long -- the neighbour's index in direction d, or -1 when that
// is off the grid.  -1 rather than a trap is deliberate: every neighbour test
// in this file is "is there a neighbour", and folding the bounds check into
// the lookup is what keeps the generators from having to carry an `inside`
// predicate through five loops.
def nb(x: long, y: long, d: long) -> long {
    let nx = x + DXA[d];
    let ny = y + DYA[d];
    let r = 0 - 1;
    if (nx >= 0 && nx < GW && ny >= 0 && ny < GH) { r = ny * GW + nx; };
    r
};

// open_at(x, y, d) -> bool -- is the passage between (x,y) and its direction-d
// neighbour open?  False for an off-grid neighbour, which is what makes the
// boundary cells of a maze need no special case anywhere downstream.
def open_at(x: long, y: long, d: long) -> bool {
    let i = cell(x, y);
    let j = nb(x, y, d);
    let o = false;
    if (j >= 0) {
        if (d == 1) { o = cw[i] % 2 == 1; }
        else if (d == 2) { o = cw[i] / 2 == 1; }
        else if (d == 3) { o = cw[j] % 2 == 1; }
        else { o = cw[j] / 2 == 1; }
    };
    o
};

// carve(x, y, d) -> void -- knock the wall between (x,y) and direction d down.
//
// The bit is tested before it is set, so carving twice is the same as carving
// once.  That matters for correctness and not just tidiness: `+=` on a bit
// field turns 1 into 2, which is the OTHER axis's flag, so an unguarded carve
// would rotate the maze.  (Every generator here does guard itself; this is the
// belt to their braces.)
def carve(x: long, y: long, d: long) -> void {
    let i = cell(x, y);
    let j = nb(x, y, d);
    if (j >= 0) {
        if (d == 1) { if (cw[i] % 2 == 0) { cw[i] += 1; } }
        else if (d == 2) { if (cw[i] / 2 == 0) { cw[i] += 2; } }
        else if (d == 3) { if (cw[j] % 2 == 0) { cw[j] += 1; } }
        else { if (cw[j] / 2 == 0) { cw[j] += 2; } }
    }
};

// ─────────────────────────────────────────────────────────────────────────
// generator 1: recursive backtracker (depth-first)
//
// A stack of cells to visit; at the top, carve towards a random UNVISITED
// neighbour and push it; when there is none, pop.  The result is a perfect
// maze of long snaking corridors -- the cell count is right because a cell is
// pushed exactly once and never popped until it is exhausted.
//
// The early exit here is the loop's own condition: `go = top > 0` after each
// step.  There is no "found what we wanted, leave" case to write out because
// the loop IS the recursion -- an explicit stack has replaced the call stack,
// which is what Y's `self` recursion would otherwise be doing one frame at a
// time.
//
// The scan for an unvisited neighbour rotates a random start direction so that
// "pick a random direction" does not always prefer north.

// gen_rb(seed) -> long -- build a perfect maze; answers the passages carved,
// which must be exactly NCE-1 for a spanning tree.
def gen_rb(seed: long) -> long {
    rng.rng_seed(seed);
    grid_clear();
    let i = 0;
    while (i < NCE) { gv[i] = 0; i = i + 1; };
    let carved = 0;
    let top = 1;
    gv[0] = 1;
    work[0] = 0;
    let x = 0;
    let y = 0;
    let go = true;
    while (go) {
        let d0 = rng.rng_below(4);
        let pick = 0 - 1;
        let k = 0;
        // Rotate once round the compass and stop at the first unseen neighbour.
        // The `pick < 0` half of the condition is the early exit.
        while (k < 4 && pick < 0) {
            let d = (d0 + k) % 4;
            let n = nb(x, y, d);
            if (n >= 0 && gv[n] == 0) { pick = d; };
            k = k + 1;
        };
        if (pick < 0) {
            top = top - 1;
            let p = work[top];
            x = p % GW;
            y = p / GW;
        } else {
            let n = nb(x, y, pick);
            carve(x, y, pick);
            gv[n] = 1;
            carved = carved + 1;
            work[top] = n;
            top = top + 1;
            x = n % GW;
            y = n / GW;
        };
        go = top > 0;
    };
    carved
};

// ─────────────────────────────────────────────────────────────────────────
// generator 2: Prim's, randomised
//
// The frontier holds cells that are IN the tree and have at least one untaken
// edge.  Pop a uniformly random one, take an edge to an unseen neighbour,
// repeat.  Short corridors, lots of dead ends: the frontier is a wall of
// independent choices rather than one long commitment, so it branches.
//
// ONE DETAIL THAT IS EASY TO GET WRONG, and this file gets it right on
// purpose.  When a frontier cell is popped, it opens an edge towards EVERY
// unseen neighbour, not just the first one found.  Stopping at the first looks
// equivalent and is not: the cell is removed from the frontier when it is
// popped, so an unseen neighbour on the far side of that stop is never
// reconsidered from here, and nothing else is guaranteed to reach it.  The
// result is a maze with holes -- a forest, not a tree.  Opening every edge is
// what makes the final tree MAXIMAL, and maximal == spanning here.
//
// The other detail is the pop.  `work[j] = work[fc-1]; fc = fc - 1` removes an
// arbitrary frontier entry in O(1) while the CHOICE of which one is uniform,
// which is the standard "random element from an array" trick: one draw, no
// scan, no re-shuffle.

// gen_prim(seed) -> long -- the passages carved, again NCE-1 for a perfect maze.
def gen_prim(seed: long) -> long {
    rng.rng_seed(seed);
    grid_clear();
    let i = 0;
    while (i < NCE) { gv[i] = 0; i = i + 1; };
    let carved = 0;
    let fc = 1;
    gv[0] = 1;
    work[0] = 0;
    let go = true;
    while (go) {
        let j = rng.rng_below(fc);
        let c = work[j];
        work[j] = work[fc - 1];
        fc = fc - 1;
        let x = c % GW;
        let y = c / GW;
        let d0 = rng.rng_below(4);
        let k = 0;
        while (k < 4) {
            let d = (d0 + k) % 4;
            let n = nb(x, y, d);
            if (n >= 0 && gv[n] == 0) {
                carve(x, y, d);
                gv[n] = 1;
                carved = carved + 1;
                work[fc] = n;
                fc = fc + 1;
            };
            k = k + 1;
        };
        go = fc > 0;
    };
    carved
};

// ─────────────────────────────────────────────────────────────────────────
// generator 3: Kruskal's, randomised -- a uniform spanning tree
//
// Every adjacency is an edge; shuffle the edges; take each one whose ends are
// in different components and merge them.  The result is a spanning tree, and
// because the EDGES are in a uniformly random order the tree is a UNIFORM
// spanning tree -- the same distribution Aldous-Broder produces by a random
// walk, arrived at by a completely different method.  That is the interesting
// thing about this generator: it is the reference "uniform" against which the
// other two are biased.
//
// The disjoint set is union-find with full path compression, union by index
// (the smaller-indexed root wins).  Both are here because this file has no
// `sort`, no `push`, and no map: a `map_get`/`map_set` disjoint set would be a
// LINEAR SCAN per lookup, i.e. O(n^2) for this algorithm, and it would also
// allocate on every insert (ORCHESTRATOR.md 2.8).
//
// Path compression is written as two loops rather than recursion: the second
// loop walks the same path again and flattens every node it passes.  That is
// what "full" compression means, and it is why find() is called twice per edge
// and still costs amortised O(1).

// uf_find(a) -> long -- the root of a's component, flattening the path.
def uf_find(a: long) -> long {
    let r = a;
    let up = true;
    while (up) {
        let p = uf[r];
        if (p == r) { up = false; } else { r = p; }
    };
    let c = a;
    let down = true;
    while (down) {
        let p = uf[c];
        if (p == r) { down = false; } else { uf[c] = r; c = p; }
    };
    r
};

// uf_union(a, b) -> void -- merge two components, given their roots.
def uf_union(a: long, b: long) -> void {
    if (a < b) { uf[b] = a; } else { uf[a] = b; }
};

// gen_kruskal(seed) -> long -- the passages carved.
def gen_kruskal(seed: long) -> long {
    rng.rng_seed(seed);
    grid_clear();
    let i = 0;
    while (i < NCE) { gv[i] = 0; uf[i] = i; i = i + 1; };

    // The edge list: east and south adjacencies only, so every adjacency is
    // listed exactly once.  Packed as cell*4 + direction; 4 * 40401 = 161604
    // fits a long with room to spare, and cell<2^30 so direction survives.
    let ne = 0;
    let y = 0;
    while (y < GH) {
        let x = 0;
        while (x < GW) {
            let c = y * GW + x;
            if (x + 1 < GW) { ebuf[ne] = c * 4 + 1; ne = ne + 1; };
            if (y + 1 < GH) { ebuf[ne] = c * 4 + 2; ne = ne + 1; };
            x = x + 1;
        };
        y = y + 1
    };

    // Fisher-Yates, from the back, using the shared rng.  k > 0 is the exit.
    let k = ne - 1;
    let shuf = k > 0;
    while (shuf) {
        let j = rng.rng_below(k + 1);
        let t = ebuf[k];
        ebuf[k] = ebuf[j];
        ebuf[j] = t;
        k = k - 1;
        shuf = k > 0;
    };

    // Kruskal proper.  The `ne` bound is the whole loop: there is no "stop when
    // it is connected" test here, because taking NCE-1 edges IS the tree, and
    // the remaining rejected edges are what the tail of the loop is for.
    let carved = 0;
    let e = 0;
    let go = e < ne;
    while (go) {
        let code = ebuf[e];
        let c = code / 4;
        let d = code % 4;
        let x2 = c % GW;
        let y2 = c / GW;
        let ra = uf_find(c);
        let n = nb(x2, y2, d);
        let rn = uf_find(n);
        if (ra != rn) {
            uf_union(ra, rn);
            carve(x2, y2, d);
            carved = carved + 1;
        };
        e = e + 1;
        go = e < ne;
    };
    carved
};

// ─────────────────────────────────────────────────────────────────────────
// the statistics that make the three generators comparable
//
// A corridor is a MAXIMAL RUN OF DEGREE-2 CELLS: the cells you pass through
// with nothing to do at them.  Its length is how many cells that is.  Dead ends
// (degree 1) and junctions (degree 3 or 4) are what end corridors.
//
// This is the payoff measurement, and it separates the three generators hard:
//
//   recursive backtracker   few dead ends, very long corridors: it commits to
//                           one direction and keeps going, so the corridors are
//                           the depth-first snake itself.
//   randomised Prim         many dead ends, short corridors: the frontier is a
//                           wall of independent choices, so it branches and
//                           then runs out of frontier fast.
//   randomised Kruskal      in between and biased uniformly, which is the point
//                           of having it: the other two are NOT uniform.
//
// Every number below is exact and integer.  There is no float anywhere: there
// is no float->long conversion in Y at all (ORCHESTRATOR.md 2.4a), so the mean
// is a division the caller does in long and it is guarded against an empty
// denominator rather than being allowed to trap.

// grid_degree() -> void -- each cell's count of open passages into dv.
def grid_degree() -> void {
    let i = 0;
    while (i < NCE) {
        let x = i % GW;
        let y = i / GW;
        let n = 0;
        let d = 0;
        while (d < 4) {
            if (open_at(x, y, d)) { n = n + 1; };
            d = d + 1
        };
        dv[i] = n;
        i = i + 1
    }
};

// walk(from, d) -> long -- follow a corridor from `from` in direction d, marking
// as it goes, and answer how many degree-2 cells it collected.
//
// The `go` flag is the early exit: a corridor ends at a wall, at a junction, or
// at a cell another corridor already claimed.  All three are "not another
// degree-2 unmarked cell", and one condition says all three.
def walk(from: long, d: long) -> long {
    let cnt = 0;
    let x = from % GW;
    let y = from / GW;
    let go = true;
    while (go) {
        let n = nb(x, y, d);
        if (n >= 0 && dv[n] == 2 && cm[n] == 0) {
            cm[n] = 1;
            cnt = cnt + 1;
            x = n % GW;
            y = n / GW;
        } else {
            go = false
        }
    };
    cnt
};

// bucket_of(L) -> long -- which of the six length buckets a corridor is in.
// Buckets rather than a histogram because a 1..N histogram printed for a 39x11
// maze is forty numbers of which thirty-eight are zero.
def bucket_of(L: long) -> long {
    let b = 5;
    if (L <= 4) { b = 0; }
    else if (L <= 8) { b = 1; }
    else if (L <= 16) { b = 2; }
    else if (L <= 32) { b = 3; }
    else if (L <= 64) { b = 4; };
    b
};

// grid_stats() -> void -- fill s_dead/s_junc/s_corr/s_long/s_total/s_bkt.
def grid_stats() -> void {
    grid_degree();
    let i = 0;
    while (i < NCE) { cm[i] = 0; i = i + 1; };
    s_dead = 0;
    s_junc = 0;
    s_corr = 0;
    s_long = 0;
    s_total = 0;
    let b = 0;
    while (b < 6) { s_bkt[b] = 0; b = b + 1; };

    i = 0;
    while (i < NCE) {
        let dg = dv[i];
        if (dg == 1) { s_dead = s_dead + 1; }
        else if (dg >= 3) { s_junc = s_junc + 1; };
        // An unmarked degree-2 cell is the start of a corridor nobody has
        // counted.  A perfect maze has no cycles, so the two open directions of
        // such a cell are the corridor's two ends and the walk can meet no other
        // corridor -- but `cm[n] == 0` in walk() makes that an assumption and
        // not a requirement, which is why this is safe on ANY passage set.
        if (dg == 2 && cm[i] == 0) {
            cm[i] = 1;
            // The cell's two open directions, in compass order.
            let d1 = 0 - 1;
            let d2 = 0 - 1;
            let x = i % GW;
            let y = i / GW;
            let d = 0;
            while (d < 4) {
                if (open_at(x, y, d)) {
                    if (d1 < 0) { d1 = d; } else { d2 = d; }
                };
                d = d + 1
            };
            let L = 1;
            if (d1 >= 0 && d2 >= 0) { L = 1 + walk(i, d1) + walk(i, d2); };
            s_corr = s_corr + 1;
            s_total = s_total + L;
            if (L > s_long) { s_long = L; };
            let bk = bucket_of(L);
            s_bkt[bk] = s_bkt[bk] + 1;
        };
        i = i + 1
    }
};

// ─────────────────────────────────────────────────────────────────────────
// the render buffer
//
// rk[] holds a KIND per rendered character, and exactly two painters read it:
// one writes ASCII (the --no-tty path, which is what EXPECTED holds), one writes
// cells and colours into an tui.Surface.  Keeping the geometry in one pass and
// the painting in two is what stops the two renderers from drifting apart --
// and it is why the interactive view and the golden file are the same picture.

// The kinds.  Numbers, not names: Y has no enum, and a `const` per kind would
// be seven exports to keep in step with seven cases in each painter.
const K_WALL = 0;
const K_FLOOR = 1;
const K_SEEN = 2;
const K_PATH = 3;
const K_ME = 4;
const K_START = 5;
const K_GOAL = 6;

// grid_paint(shown, plen, pcell) -> void -- fill rk for the current maze.
//
// `shown` is how many cells of the solver's expansion order to reveal, `plen`
// the solution length (0 for "no solution to draw"), `pcell` where the walker
// stands.  The start is always cell 0 and the goal always the far corner, so
// neither needs an argument.
//
// Paint order matters and is bottom-up: walls and passages first, then the
// explored cells, then the path, then start, goal and walker.  Later writes win,
// which is how the walker ends up visible when it is standing on the start.
def grid_paint(shown: long, plen: long, pcell: long) -> void {
    let tot = RW * RH;
    let i = 0;
    while (i < tot) { rk[i] = K_WALL; i = i + 1; };

    // Cell centres: even row, even column.
    let y = 0;
    while (y < GH) {
        let x = 0;
        while (x < GW) {
            rk[(2 * y) * RW + 2 * x] = K_FLOOR;
            x = x + 1
        };
        y = y + 1
    };

    // Passages: the odd character between two cell centres.
    y = 0;
    while (y < GH) {
        let x = 0;
        while (x < GW) {
            let c = y * GW + x;
            if (x + 1 < GW && cw[c] % 2 == 1) { rk[(2 * y) * RW + 2 * x + 1] = K_FLOOR; };
            if (y + 1 < GH && cw[c] / 2 == 1) { rk[(2 * y + 1) * RW + 2 * x] = K_FLOOR; };
            x = x + 1
        };
        y = y + 1
    };

    // The explored cells: the first `shown` entries of the solver's expansion
    // order.  This is why the solver records one -- it turns the solver's
    // internal order into something a human can watch.
    let k = 0;
    while (k < shown && k < sno) {
        let c = sord[k];
        rk[(2 * (c / GW)) * RW + 2 * (c % GW)] = K_SEEN;
        k = k + 1
    };

    // The solution, over the top of the explored cells.  plen STEPS means
    // plen+1 cells, so the loop goes to plen inclusive -- off by one here loses
    // exactly the start or the goal marker underneath.
    let t = 0;
    while (t <= plen && t < NCE) {
        let c = solv[t];
        rk[(2 * (c / GW)) * RW + 2 * (c % GW)] = K_PATH;
        t = t + 1
    };

    rk[0] = K_START;
    rk[(2 * (GH - 1)) * RW + 2 * (GW - 1)] = K_GOAL;
    rk[(2 * (pcell / GW)) * RW + 2 * (pcell % GW)] = K_ME
};

// grid_paint_hash() -> long -- FNV-1a over the render kinds, so a frame line
// carries a checksum of the picture and not just its length.  Same function
// tui uses for its capture checksum.
def grid_paint_hash() -> long {
    let h: long = -3750763034362895579;      // 14695981039346656037, signed
    let n = RW * RH;
    let i = 0;
    while (i < n) {
        h = (h ^ rk[i]) * 1099511628211;
        i = i + 1
    };
    h
};

export { MAXW, MAXH, NCELL, RMAX, EMAX, GW, GH, NCE, RW, RH,
         K_WALL, K_FLOOR, K_SEEN, K_PATH, K_ME, K_START, K_GOAL,
         GENS, DXA, DYA, cw, rk, sord, solv, soli, sno,
         s_dead, s_junc, s_corr, s_long, s_total, s_bkt,
         cell, nb, open_at, carve, grid_setup, grid_clear,
         gen_rb, gen_prim, gen_kruskal,
         grid_degree, grid_stats, grid_paint, grid_paint_hash };