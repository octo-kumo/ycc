// tiles.y -- the tile set, the socket rule, and the tables the solver reads.
//
// FOUR-WAY SOCKETS.  Every tile carries one bit per side: N=1, E=2, S=4, W=8.
// Two tiles may be neighbours only when their SHARED bits agree -- set against
// set, clear against clear.  That single rule is the whole constraint system,
// and it is the rule examples/wavefunction's --check asserts against the
// finished picture: for every vertical pair the upper's S must equal the
// lower's N, and for every horizontal pair the right's W must equal the left's E.
//
// The sixteen tiles, in index order.  The table is the specification; check.y
// carries its OWN copy of the socket column and asserts the two agree, so a
// corrupted entry here cannot quietly redefine the puzzle.
//
//   idx  sockets  name          weight  ascii  glyph
//    0      0000  empty            6      .      (space)
//    1      N     end-N            1      |      │
//    2      E     end-E            1      -      ─
//    3      S     end-S            1      |      │
//    4      W     end-W            1      -      ─
//    5      N+S   straight-NS      3      |      │
//    6      E+W   straight-EW      3      -      ─
//    7      N+E   elbow-NE         4      L      └
//    8      E+S   elbow-ES         4      7      ┌
//    9      S+W   elbow-SW         4      J      ┐
//   10      W+N   elbow-WN         4      F      ┘
//   11      N+E+S tee-NES          1      +      ├
//   12      E+S+W tee-ESW          1      +      ┬
//   13      S+W+N tee-SWN          1      +      ┤
//   14      W+N+E tee-WNE          1      +      ┴
//   15   N+E+S+W cross-NESW        1      *      ┼
//
// EVERY NAME IS MACHINE-READABLE ON PURPOSE: check.y parses the sockets out of
// the names (`elbow-NE` -> N|E, `cross-NESW` -> all four, `empty` -> none) and
// compares the result with SOCK.  A corrupted socket entry then shows up as a
// disagreement instead of quietly redefining the puzzle, and the oracle in
// check.y runs on the PARSED bits rather than on this table.
//
// WHY SIXTEEN, AND WHY THE EMPTY TILE IS THE COMMONEST.  Sixteen is the most
// tiles that fit in one 64-bit mask, which is what makes a cell's possibility
// set a single integer and its union a single OR.  `empty` is the commonest
// because a picture of closed loops wants more background than pipe; the
// weights are the ONLY thing that makes this a weighted collapse rather than a
// uniform one, and the entropy they feed is computed in integer Q30 (wfc.y).

const NT: long = 16;
const NDIR: long = 4;

const SN: long = 1;               // socket north
const SE: long = 2;               // socket east
const SS: long = 4;               // socket south
const SW: long = 8;               // socket west

const D_N: long = 0;
const D_E: long = 1;
const D_S: long = 2;
const D_W: long = 3;

// ───────────────────────────────────────────────────────── the tile table ───
//
// All six tables are module-level and read-only: nothing here allocates, and
// nothing here is inside a loop body (an array literal in a loop body costs
// 64 bytes an iteration, ORCHESTRATOR.md 2.4b).

let SOCK: [long; 16] = [0, 1, 2, 4, 8, 5, 10, 3, 6, 12, 9, 7, 14, 13, 11, 15];
let WT: [long; 16] = [6, 1, 1, 1, 1, 3, 3, 4, 4, 4, 4, 1, 1, 1, 1, 1];
let ASC: [long; 16] = [46, 124, 45, 124, 45, 124, 45, 76, 55, 74, 70, 43, 43, 43, 43, 42];
let GLY: [long; 16] = [32, 9474, 9472, 9474, 9472, 9474, 9472, 9492, 9484, 9488, 9496,
                       9500, 9516, 9508, 9524, 9532];

let NAMES: [str] = ["empty", "end-N", "end-E", "end-S", "end-W",
                    "straight-NS", "straight-EW", "elbow-NE", "elbow-ES",
                    "elbow-SW", "elbow-WN", "tee-NES", "tee-ESW", "tee-SWN",
                    "tee-WNE", "cross-NESW"];

// ─────────────────────────────────────────────────────────── tile subsets ───
//
// Named subsets of the sixteen, so an UNSATISFIABLE instance is a flag away
// rather than a second program.  `straights` is the interesting one: with only
// the two straight tiles, the top-left cell must have N and W clear and no
// available tile has both clear, so the very first propagation is a
// contradiction -- provable on paper, which is what makes it a usable test.

// The membership is spelled out in the comments and check.y derives each mask
// from the tile NAMES instead of trusting these constants: three of the six
// were wrong when this was first written (85 for {0,5,6}, 1063 for {0,7..10},
// 80 for {5,6} and 65409 for "everything but empty"), and the battery caught
// every one of them.  A hand-written bitmask is exactly the kind of thing that
// is wrong and looks right.
const SUB_ALL: long = 65535;            // tiles 0..15
const SUB_LINES: long = 97;             // 0,5,6    empty + the two straights
const SUB_ELBOWS: long = 1921;          // 0,7,8,9,10   empty + the four elbows
const SUB_ENDS: long = 31;              // 0,1,2,3,4    empty + the four ends
const SUB_LOOP: long = 65534;           // 1..15   everything EXCEPT empty: no
                                        //         cell may be unused, so the
                                        //         finished grid is a set of
                                        //         closed loops and nothing else
const SUB_STRAIGHTS: long = 96;         // 5,6     the two straights only: no tile
                                        //         has N, E, S and W all clear,
                                        //         so every corner's initial
                                        //         domain is EMPTY -- the
                                        //         unsatisfiable instance
const SUB_CROSS: long = 32768;          // 15      the cross only: all four
                                        //         sockets, so every cell would
                                        //         have to be interior

// The order here is the order of the constants above, and the table is BUILT from
// them rather than written out again.  A second copy of six bitmasks is a second
// place for them to be wrong, and they were: this table still carried the four
// wrong values after the constants were fixed, and check.y's membership check
// caught that too.
let SUBSETS: [str] = ["all", "loop", "lines", "elbows", "ends", "straights", "cross"];
let SUBMASK: [long; 7] = [SUB_ALL, SUB_LOOP, SUB_LINES, SUB_ELBOWS, SUB_ENDS,
                           SUB_STRAIGHTS, SUB_CROSS];

// subset_of(name) -> long -- the mask for a named subset, or -1 if unknown.
def subset_of(name: str) -> long {
    let i = 0;
    while (i < len(SUBSETS)) {
        if (SUBSETS[i] == name) { return SUBMASK[i] };
        i = i + 1
    };
    0 - 1
};

// ───────────────────────────────────────────────────────── the socket rule ───

// edge(t, d) -> long -- tile t's socket facing direction d, as one of the four
// bit constants.  `d` outside 0..3 gives 0 rather than trapping.
def edge(t: long, d: long) -> long {
    let e = 0;
    if (d == D_N) { e = SN; } else if (d == D_E) { e = SE; }
    else if (d == D_S) { e = SS; } else { e = SW };
    if (t < 0 || t >= NT) { return 0; };
    SOCK[t] & e
};

// edge_bit(t, d) -> long -- the same thing reduced to 0 or 1.
def edge_bit(t: long, d: long) -> long {
    if (edge(t, d) != 0) { 1 } else { 0 }
};

// opposite(d) -> long -- the direction facing back, so N<->S and E<->W.
//
// Written as a subtraction and not as a hand-rolled modulo: the first version
// of this file had `if (back > 3) { back = 3 + back - 4 }` here and in wfc.y's
// audit, and it silently returned 2 for the south direction -- i.e. "the tile
// to my south must have its own SOUTH socket clear", a rule that is not the
// rule and that made every vertical placement a contradiction.  The mistake was
// invisible in the horizontal case (N and E wrap nothing), which is why it took
// a printed mask to find.  One function, one copy, both callers.
def opposite(d: long) -> long {
    let b = d + 2;
    if (b > 3) { b = b - 4 };
    if (b < 0) { b = 0 };               // a direction outside 0..3 has no opposite
    b
};

// fits(a, b, d) -> bool -- may tile b sit at direction d from tile a?
//
// THE WHOLE CONSTRAINT SYSTEM, in one line: the two tiles must agree about the
// edge they share.  `d` is the direction from a to b, so a's socket facing d
// and b's socket facing back (opposite(d)) are the same physical edge.
def fits(a: long, b: long, d: long) -> bool {
    edge_bit(a, d) == edge_bit(b, opposite(d))
};

// ───────────────────────────────────────────── the two projection tables ───
//
// A propagation step needs one number: given a cell's possibility set `mask` and a
// direction d, which tiles may sit at d from it?  Computed directly that is a
// sixteen-iteration OR loop per neighbour, four times per popped cell.
//
// So it is precomputed per BYTE.  ADJ[d*256 + b] is the union of CM[t][d] over
// the tiles whose bit is set in the mask byte b -- bit i of b is tile i for the
// low byte and tile 8 + i for the high one, which is what ADJ2 holds.  Two table
// reads and an OR then replace the loop:
//
//     adj(mask, d) = ADJ[d*256 + (mask & 255)] | ADJ2[d*256 + (mask >>> 8) & 255]
//
// `b` here is the VALUE of a mask byte and NOT a tile index, which is the mistake
// this file's first version made: it computed `b * 8 + i`, so every lookup for a
// mask byte above 2 returned nothing, the first propagation pass found a
// contradiction on a satisfiable 4x3, and the solver answered "unsatisfiable" for
// every grid until it was found.
//
// 2 x 4 x 256 longs = 16 KiB, built ONCE per tile subset.

let INJECT: long = 0;                   // --inject: see wfc.y

let CM: [long; 64] = [0; 64];           // CM[t*4 + d]: tiles admissible at direction d
let ADJ: [long; 1024] = [0; 1024];
let ADJ2: [long; 1024] = [0; 1024];

// set_inject(k) -- the defect switch, shared with wfc.y so one --check run can
// turn on a defect in either file.
def set_inject(k: long) -> void { INJECT = k };

def build(avail: long) -> void {
    // CM first, then fold it into the byte tables.  build() is called from
    // wfc.setup() -- once per solve, and once per --frames replay -- and every
    // entry of both tables is written on every call, so nothing is ever read
    // through a stale value from a previous tile subset.
    let t = 0;
    while (t < NT) {
        let d = 0;
        while (d < NDIR) {
            let acc = 0;
            let u = 0;
            while (u < NT) {
                if (fits(t, u, d) == true) { acc = acc | (1 << u) };
                u = u + 1
            };
            CM[t * NDIR + d] = if (INJECT == 11) { acc } else { acc & avail };
            d = d + 1
        };
        t = t + 1
    };
    let dd = 0;
    while (dd < NDIR) {
        let b = 0;
        while (b < 256) {
            let lo = 0;
            let hi = 0;
            let i = 0;
            while (i < 8) {
                // `b` is the VALUE of a mask byte, not a tile index: bit i of
                // the low byte is tile i, bit i of the high byte is tile 8 + i.
                if ((b & (1 << i)) != 0) {
                    if (i < NT) { lo = lo | CM[i * NDIR + dd] };
                    if (8 + i < NT) { hi = hi | CM[(8 + i) * NDIR + dd] }
                };
                i = i + 1
            };
            ADJ[dd * 256 + b] = lo;
            ADJ2[dd * 256 + b] = hi;
            b = b + 1
        };
        dd = dd + 1
    }
};

// adj(mask, d) -> long -- every tile admissible at direction d from a cell whose
// possibility set is `mask`.  Two reads and an OR; no allocation.
def adj(mask: long, d: long) -> long {
    ADJ[d * 256 + (mask & 255)] | ADJ2[d * 256 + ((mask >>> 8) & 255)]
};

// boundary(d) -> long -- the mask of tiles with NO socket facing direction d,
// which is every tile that can legally sit on that edge of the grid.
//
// --inject=11 answers for the OPPOSITE side, which is the exact mistake this
// project made once while writing it (a hand-rolled "opposite" that returned 2
// for south): it leaves every edge cell holding tiles whose sockets point off the
// grid, and the finished picture then has pipes running off the edge.
def boundary(d: long) -> long {
    let acc = 0;
    let dir = d;
    if (INJECT == 11) { dir = opposite(d) };
    let t = 0;
    while (t < NT) {
        if (edge_bit(t, dir) == 0) { acc = acc | (1 << t) };
        t = t + 1
    };
    acc
};

// ───────────────────────────────────────────────────────────────────────────
// BUG WORKAROUND, RECORDED HERE RATHER THAN IN A COMMENT IN THE README:
// `y_`-free, but the one language fact this file leans on is that a fixed
// array literal is evaluated ONCE at module load.  Every table above is a
// module-level literal, so setup costs 16 tiles x 4 directions of `fits` calls
// and nothing per frame; a `let` INSIDE a loop would have been the leak the
// campaign keeps warning about.

export { NT, NDIR, SN, SE, SS, SW, D_N, D_E, D_S, D_W,
         SUB_ALL, SUB_LINES, SUB_ELBOWS, SUB_ENDS, SUB_LOOP, SUB_STRAIGHTS, SUB_CROSS,
         SOCK, WT, ASC, GLY, NAMES, SUBSETS, SUBMASK, INJECT, set_inject,
         subset_of, edge, edge_bit, opposite, fits, build, adj, boundary,
         CM, ADJ, ADJ2 };