// grid.y -- the store, the materials, and THE PHYSICS of sandfall.
//
// ===========================================================================
// WHAT THIS FILE IS
//
// A falling-sand cellular automaton on a rectangular grid.  Seven materials,
// a ghost border of stone on every side, and one generation = one scan.
//
//   M_EMPTY   nothing
//   M_STONE   static; also the ghost border and every wall
//   M_SAND    falls; tries down, then down-left, then down-right
//   M_WATER   liquid; down, down-diag, then sideways into a LOWER column
//   M_OIL     liquid, exactly like water but it burns; stored separately so
//             the two pools do not share a level
//   M_FIRE    consumes an adjacent OIL cell per generation, expires to smoke
//   M_SMOKE   rises, then vanishes
//
// ===========================================================================
// THE ONE RULE IN THIS FILE: it allocates four fixed arrays ONCE, at module
// scope, and never again.  The Y heap is an arena and nothing is ever freed
// (ORCHESTRATOR.md 2.7), so an automaton that allocated a cell buffer per
// generation would walk into the 3.5 GiB cap -- a 200x100 grid is 20 000 cells,
// 160 KiB a generation, so 20 000 generations and then it is over.  Hence
//
//   * the store is a fixed [byte; 66564] / [long; 66564] pair sized at compile
//     time, bigger than any grid -- a grid is only ever NARROWER than the store,
//     and sandfall.y refuses a --size that does not fit;
//   * there is nothing to swap: the update is IN PLACE (see THE RULE below),
//     so there is one grid, not a double buffer;
//   * the two per-column level arrays are [long; 258] and are maintained
//     incrementally by the liquid move, not rescanned;
//   * no array, record or string literal appears inside step() or any helper
//     it calls.  A literal in a loop body is 64 bytes (a record) or 64 (an
//     array) PER ITERATION; `./sandfall --check` asserts heap_used() is flat
//     across 20 000 generations, which is the check that would notice.
//
// ===========================================================================
// THE GHOST BORDER -- why there is no bounds branch anywhere in step()
//
// The store is (w + 2) x (h + 2).  Store row 0, store row h+1, store column 0
// and store column w+1 are M_STONE, forever.  The *logical* grid -- what the
// user asked for, what gets drawn, what gets counted -- is store rows 1..h and
// store columns 1..w.
//
// Consequence: every neighbour an interior cell can look at is a valid index.
// The cell at logical (1, 1) has neighbours at store (0, 0) .. (2, 2) and every
// one of those is inside the array.  So step() contains no range test, no `%`
// wrap, no clamp, and no "what happens at column 0" special case -- the answer
// is "stone", which is the answer a falling-sand box wants anyway.  Compare
// life.y, which needs a torus and therefore four precomputed wrap tables.
//
// The cost is 2w + 2h + 4 cells of stone, and it is worth naming that the
// border is VISIBLE: the renderer draws it, so the picture has a one-cell frame.
//
// ===========================================================================
// THE RULE, WRITTEN OUT -- and this is the part that decides the physics
//
// One generation is ONE scan over the interior cells, in this order:
//
//     rows  BOTTOM to TOP   (store y = h down to 1)
//     within a row, LEFT to RIGHT (store x = 1 .. w)
//
// and the grid is updated **IN PLACE**: when the scan reaches a cell it reads
// whatever is there AT THAT MOMENT, not what was there when the generation
// started.  There is no snapshot and no double buffer.  Each material then
// tries its moves in a fixed order and takes the first that succeeds; a move
// succeeds when the target cell is M_EMPTY, M_FIRE or M_SMOKE (the
// pass-through set -- fire and smoke are gases and do not hold up a pile).
//
// Two consequences of the ORDER, both of which are the difference between a
// correct falling-sand and a wrong one:
//
//   * **Bottom-to-top is what stops sand teleporting.**  A grain at row y that
//     moves down lands in row y+1, which the scan has ALREADY visited, so it
//     cannot move again this generation.  Scan top-to-bottom instead and the
//     same grain lands in a row not yet visited, is picked up again, and falls
//     all the way to the floor in ONE generation.  So the row order alone is
//     the difference between "sand descends one row per generation" and "a
//     column of sand compacts instantly".  props.y C2a/C2b assert the one-row
//     descent as a literal trajectory, so this cannot silently regress.
//
//   * **Left-to-right is only half of it, and the STAMP is the other half.**
//     Water and oil move sideways at constant y.  In a left-to-right scan the
//     cell to the right has not been visited yet, so without a guard a single
//     grain would slide right, be visited again, and slide again -- one grain
//     crossing the whole grid in one generation.  STAMP[dst] = GEN on every
//     write, and a cell whose stamp is the current generation is SKIPPED, so
//     **every grain moves at most once per generation, and by at most one cell
//     in each axis**.  That is the invariant props.y C2 checks on the whole
//     grid every generation, and it is why a run of water merges with its
//     neighbour over two generations and not one.
//
//   * The scan order also decides which of two simultaneous moves wins when
//     both want the same cell, and that is a real, observable difference: two
//     water grains one cell apart in a level row both want the cell between
//     them, and the left one gets it.  Documented, tested, not accidental.
//
// ===========================================================================
// WHY THIS RULE TERMINATES -- a proof, not an observation
//
//   stone  never moves.
//   sand   only ever moves to a strictly greater y, so sum(sand y) strictly
//          increases while sand moves and is bounded above by h * nsand.
//   smoke  only moves to a strictly smaller y, and its age expires it.
//   fire   converts OIL to FIRE (conserving oil+fire+smoke) or expires to
//          smoke; nothing creates a fire except an existing fire, so the fire
//          population is bounded by 9x the oil and every fire eventually
//          becomes smoke.
//   liquid A *vertical* move strictly increases sum(liquid y).  A *sideways*
//          move keeps y and requires the destination column's water level to
//          be at least TWO lower, which strictly decreases
//          Psi = sum over columns of h_c^2 by at least 2.
//
// So the pair (sum(liquid y), -Psi) strictly increases, lexicographically, on
// every generation in which any liquid moves, and both components are bounded
// above: sum(liquid y) <= h * nliquid and Psi <= (nliquid)^2.  A bounded
// strictly-increasing lexicographic pair over two bounded naturals can be
// visited at most (h*nliquid) * (Psi_max + 1) times.  Therefore no run is
// infinite, and `./sandfall --check` C3 only has to CONFIRM the fixed point it
// is guaranteed -- it is not the thing that makes one arrive.
//
// The "at least two lower" in the sideways rule is the whole reason for that
// asymmetry.  The obvious rule -- move sideways into any column that is lower --
// has a period-2 cycle in a two-column box (levels (2,1) -> (1,2) -> (2,1)),
// which is a limping rather than a fixed point and would make "a closed box
// reaches a fixed point" false.  Requiring a gap of 2 costs one row of surface
// unevenness and buys a strictly decreasing potential.

const M_EMPTY = 0;
const M_STONE = 1;
const M_SAND = 2;
const M_WATER = 3;
const M_OIL = 4;
const M_FIRE = 5;
const M_SMOKE = 6;
const NMAT = 7;

// The store.  MAXW/MAXH are the largest logical grid; the store is two cells
// bigger on each axis for the ghost border.
const MAXW = 256;
const MAXH = 256;
const GW = 258;             // MAXW + 2
const GH = 258;             // MAXH + 2
const CELLS = 66564;        // 258 * 258
const FIRE_LIFE = 14;       // generations a fire burns for
const SMOKE_LIFE = 30;      // generations a smoke puff lives for
const NMATN = 8;            // the tally arrays have a slot per material + 1

// The pass-through set: a grain may move into a cell holding a gas.
const PASS_EMPTY = 0;
const PASS_FIRE = 1;
const PASS_SMOKE = 2;

// -- the store.  Four module-level arrays, allocated once, never resized. -----
let MAT: [byte; 66564] = [0; 66564];     // the material of every store cell
let AGE: [byte; 66564] = [0; 66564];     // fire/smoke lifetime so far
let STAMP: [long; 66564] = [0; 66564];   // generation this cell was written in
let WL: [long; 258] = [0; 258];          // water cells per store column
let OL: [long; 258] = [0; 258];          // oil cells per store column

// -- the logical grid, and what the run has done so far. ---------------------
let GWa = GW;               // store width  (= w + 2)
let GHa = GH;               // store height (= h + 2)
let IW = 0;                 // logical width  (store cols 1..IW)
let IH = 0;                 // logical height (store rows 1..IH)
let GEN = 0;                // generations run
let MOVES = 0;              // grains that moved in the last generation
let CHANGED = 0;            // 1 when the last generation changed any cell
let SEEDV = 1;              // the seed, kept for the report

// ===========================================================================
// the store's own primitives
// ===========================================================================

// idx(x, y) -> long -- the store index.  Everything inside this file works in
// STORE coordinates; logical coordinates appear only at the edges (scene
// building, rendering, counting), where the +1 is written down once here and
// once in put_logical().
def idx(x: long, y: long) -> long { y * GWa + x };

// at(x, y) -> long -- the material at store (x, y).
def at(x: long, y: long) -> long { MAT[y * GWa + x] };

// passable(m) -> bool -- may a grain move into a cell holding m?  Empty, and
// the two gases.  Stone, sand and the liquids hold each other up.
def passable(m: long) -> bool {
    m == M_EMPTY || m == M_FIRE || m == M_SMOKE
};

// put(i, m, g) -- THE ONLY WAY A CELL EVER CHANGES MATERIAL.  Sets the stamp,
// which is what enforces "one move per grain per generation" (THE RULE above),
// and sets CHANGED, which is how the fixed point is detected.
def put(i: long, m: long, g: long) {
    MAT[i] = m;
    AGE[i] = 0;
    STAMP[i] = g;
    CHANGED = 1
};

// clear() -- a fresh, empty box: the whole store EMPTY and then a ghost border
// of STONE all the way round.  IW/IH are the logical size, already checked by
// sandfall.y against MAXW/MAXH and the store.
def clear(w: long, h: long) {
    IW = w;
    IH = h;
    GWa = w + 2;
    GHa = h + 2;
    let i = 0;
    while (i < CELLS) {
        MAT[i] = M_EMPTY;
        AGE[i] = 0;
        STAMP[i] = 0;
        i = i + 1
    };
    let x = 0;
    while (x < GWa) {
        WL[x] = 0;
        OL[x] = 0;
        x = x + 1
    };
    // the ghost border: the four sides of the store
    let r = 0;
    while (r < GHa) {
        let top = idx(0, r);
        let bot = idx(GWa - 1, r);
        MAT[top] = M_STONE;
        MAT[bot] = M_STONE;
        r = r + 1
    };
    let c = 0;
    while (c < GWa) {
        MAT[idx(c, 0)] = M_STONE;
        MAT[idx(c, GHa - 1)] = M_STONE;
        c = c + 1
    };
    GEN = 0;
    MOVES = 0;
    CHANGED = 0
};

// setm(x, y, m) -- set a cell without the stamp machinery, for SCENE BUILDING
// only (before any generation has run).  Keeps the column levels in step, so a
// scene that pours water already has correct levels at generation 0 -- which
// matters, because the level arrays are what the sideways rule reads.
def setm(x: long, y: long, m: long) {
    let i = idx(x, y);
    let was = MAT[i];
    if (was == M_WATER && m != M_WATER) { WL[x] = WL[x] - 1; };
    if (was != M_WATER && m == M_WATER) { WL[x] = WL[x] + 1; };
    if (was == M_OIL && m != M_OIL) { OL[x] = OL[x] - 1; };
    if (was != M_OIL && m == M_OIL) { OL[x] = OL[x] + 1; };
    MAT[i] = m;
    AGE[i] = 0;
    STAMP[i] = 0
};

// put_logical(lx, ly, m) -> bool -- scene building in LOGICAL coordinates
// (0..w-1, 0..h-1).  False when the cell is outside the grid, so a scene that
// does not fit is a message and not an index-out-of-bounds trap printed on
// stdout (which would corrupt EXPECTED).
def put_logical(lx: long, ly: long, m: long) -> bool {
    if (lx < 0 || ly < 0 || lx >= IW || ly >= IH) {
        return false
    };
    setm(lx + 1, ly + 1, m);
    true
};

// rect_logical(lx0, ly0, lx1, ly1, m) -> bool -- a filled rectangle, inclusive
// of both corners.  False if any part of it is outside the grid.
def rect_logical(lx0: long, ly0: long, lx1: long, ly1: long, m: long) -> bool {
    if (lx0 < 0 || ly0 < 0 || lx1 >= IW || ly1 >= IH) { return false };
    if (lx1 < lx0 || ly1 < ly0) { return false };
    let y = ly0;
    while (y <= ly1) {
        let x = lx0;
        while (x <= lx1) {
            setm(x + 1, y + 1, m);
            x = x + 1
        };
        y = y + 1
    };
    true
};

// line_logical(x0, y0, dx, dy, n, m) -> bool -- n cells starting at (x0, y0)
// stepping (dx, dy).  Used for the ramps in a scene.  False if any of them
// leaves the grid, checked one cell at a time so the caller gets a position.
def line_logical(x0: long, y0: long, dx: long, dy: long, n: long, m: long) -> bool {
    let x = x0;
    let y = y0;
    let ok = true;
    let k = 0;
    while (k < n && ok) {
        if (!put_logical(x, y, m)) { ok = false; };
        x = x + dx;
        y = y + dy;
        k = k + 1
    };
    ok
};

// -- the per-column liquid levels -------------------------------------------

// lvl_get(liq, x) -> long -- how many cells of that liquid are in store column
// x.  Maintained incrementally by every move, so the sideways rule never
// rescans a column: the hot loop does not depend on the grid height here.
def lvl_get(liq: long, x: long) -> long {
    if (liq == M_WATER) { WL[x] } else { OL[x] }
};

// lvl_add(liq, x, d) -- one cell of that liquid appeared (+) or vanished (-) in
// store column x.
def lvl_add(liq: long, x: long, d: long) {
    if (liq == M_WATER) { WL[x] = WL[x] + d; } else { OL[x] = OL[x] + d; }
};

// ===========================================================================
// the moves
// ===========================================================================

// move_to(i, dst, liq, x, y, nx, ny) -> bool -- perform the move of the grain
// at store cell i into store cell dst, keeping both level arrays right.  This
// is the single place a grain changes cell, so the invariant "every grain moves
// at most one cell in each axis, at most once per generation" has exactly one
// place it could be broken.
def move_to(i: long, dst: long, liq: long, x: long, y: long, nx: long, ny: long) -> bool {
    if (!passable(MAT[dst])) { return false };
    put(dst, MAT[i], GEN);
    MAT[i] = M_EMPTY;
    AGE[i] = 0;
    if (liq > 0) {
        lvl_add(liq, x, 0 - 1);
        lvl_add(liq, nx, 1)
    };
    true
};

// sand_move(x, y) -> bool -- down, then down-left, then down-right.
//
// The two diagonals require BOTH the cell below-and-beside (x-1, y+1) and the
// cell simply beside (x-1, y) to be passable.  The second test is the whole
// point: a grain needs room to slip PAST its neighbour, and without it sand
// drains through a one-cell diagonal crack exactly the way water does and a pile
// looks like a fluid.  props.y C2b is what found this: the comment above the
// first version of this function described the two-cell test and the function
// implemented only the one-cell one.  A comment that disagrees with its code is
// a defect in its own right, and the only thing that catches it is a property
// check asking a question the comment answers.
def sand_move(x: long, y: long) -> bool {
    let i = idx(x, y);
    if (move_to(i, idx(x, y + 1), 0, x, y, x, y + 1)) { return true };
    if (passable(MAT[idx(x - 1, y)]) && passable(MAT[idx(x - 1, y + 1)])) {
        if (move_to(i, idx(x - 1, y + 1), 0, x, y, x - 1, y + 1)) { return true }
    };
    if (passable(MAT[idx(x + 1, y)]) && passable(MAT[idx(x + 1, y + 1)])) {
        if (move_to(i, idx(x + 1, y + 1), 0, x, y, x + 1, y + 1)) { return true }
    };
    false
};

// liquid_move(liq, x, y) -> bool -- down, down-left, down-right, and then
// sideways.  The sideways move is the interesting one: it is allowed only into
// a column whose level is at least TWO lower (see the termination proof at the
// head of this file), and when both sides qualify the LOWER one wins, with a
// tie going left.  That tie-break is what makes the sideways rule a function of
// the state rather than of the scan order, and it is the reason two liquids in
// the same row do not trade places.
def liquid_move(liq: long, x: long, y: long) -> bool {
    let i = idx(x, y);
    if (move_to(i, idx(x, y + 1), liq, x, y, x, y + 1)) { return true };
    if (move_to(i, idx(x - 1, y + 1), liq, x, y, x - 1, y + 1)) { return true };
    if (move_to(i, idx(x + 1, y + 1), liq, x, y, x + 1, y + 1)) { return true };

    let cl = lvl_get(liq, x);
    let lf = lvl_get(liq, x - 1);
    let rt = lvl_get(liq, x + 1);
    let okl = passable(MAT[idx(x - 1, y)]) && lf + 2 <= cl;
    let okr = passable(MAT[idx(x + 1, y)]) && rt + 2 <= cl;
    if (okl && !okr) { return move_to(i, idx(x - 1, y), liq, x, y, x - 1, y) };
    if (okr && !okl) { return move_to(i, idx(x + 1, y), liq, x, y, x + 1, y) };
    if (okl && okr) {
        if (lf <= rt) { return move_to(i, idx(x - 1, y), liq, x, y, x - 1, y) };
        return move_to(i, idx(x + 1, y), liq, x, y, x + 1, y)
    };
    false
};

// smoke_move(x, y, age) -> bool -- up, up-left, up-right, or vanish when the
// puff is old enough.  Smoke is the ONLY material that moves up, which is why
// the monotone invariant in props.y C4 is stated per material rather than
// globally: sum(sand y) and sum(water y) never decrease, sum(smoke y) never
// increases, sum(stone y) never changes at all.
//
// AGE COUNTS AS A CHANGE.  A smoke puff that cannot move -- because it is
// against the ceiling, or wedged -- still ages, and an ageing cell is a cell
// whose state differs from the generation before.  Without CHANGED = 1 here,
// run_until_settled() would report a "fixed point" while puffs were still
// counting down to their disappearance, and twenty generations later the grid
// would turn over.  That is exactly the failure props.y C3 caught the first
// time it ran: it reported a fixed point at generation 41 and then every one
// of the next twenty generations changed the grid.
def smoke_move(x: long, y: long, age: long) -> bool {
    let i = idx(x, y);
    if (age >= SMOKE_LIFE) {
        // vanished: no move, but the cell DID change, which CHANGED records
        MAT[i] = M_EMPTY;
        AGE[i] = 0;
        CHANGED = 1;
        return true
    };
    if (move_to(i, idx(x, y - 1), 0, x, y, x, y - 1)) { return true };
    if (move_to(i, idx(x - 1, y - 1), 0, x, y, x - 1, y - 1)) { return true };
    if (move_to(i, idx(x + 1, y - 1), 0, x, y, x + 1, y - 1)) { return true };
    AGE[i] = age;
    CHANGED = 1;
    false
};

// fire_step(x, y, age) -> bool -- a fire burns.  In one generation it
//   * converts EVERY adjacent OIL cell to fire (that is the only way a fire is
//     ever created, which is what makes oil+fire+smoke a conserved total);
//   * turns to smoke if it is next to water, which quenches it;
//   * otherwise ages, and becomes smoke when it is older than FIRE_LIFE.
// Returns true when this cell did anything.  The eight neighbours are walked
// explicitly rather than through a dx/dy table: it is eight straight lines and
// no table, and a literal [long; 16] offset table read inside step()'s hot path
// would be an allocation per generation to save eight subtractions.
def fire_step(x: long, y: long, age: long) -> bool {
    let i = idx(x, y);
    let spread = 0;
    let wet = 0;
    let d = 0 - 1;
    while (d <= 1) {
        let e = 0 - 1;
        while (e <= 1) {
            if (!(d == 0 && e == 0)) {
                let j = idx(x + d, y + e);
                if (MAT[j] == M_OIL) {
                    // the spread: OIL -> FIRE in place, so the volatile total
                    // oil+fire+smoke does not move at all
                    MAT[j] = M_FIRE;
                    AGE[j] = 0;
                    STAMP[j] = GEN;
                    CHANGED = 1;
                    spread = 1
                };
                if (MAT[j] == M_WATER) { wet = 1 }
            };
            e = e + 1
        };
        d = d + 1
    };
    // Quenched by water, or out of time: either way this cell becomes a puff of
    // smoke.  The water is untouched, so no liquid level changes.
    if (wet || age >= FIRE_LIFE) {
        MAT[i] = M_SMOKE;
        AGE[i] = 0;
        CHANGED = 1;
        return true
    };
    // Still burning.  AGE goes up, and that IS a change: a fire burning down is
    // a cell whose state differs from the generation before.  Without this,
    // run_until_settled() would report a fixed point while fires were still
    // counting down -- see the note on smoke_move.
    AGE[i] = age;
    CHANGED = 1;
    spread == 1
};

// ===========================================================================
// one generation
// ===========================================================================

// step() -> long -- advance one generation and return how many grains moved.
//
// The loop, in the order THE RULE demands: rows BOTTOM to TOP, and within a
// row LEFT to RIGHT.  Two things guard the body instead of `continue`, which
// does not exist in Y (ORCHESTRATOR.md 2.9): the stamp test and the material
// test are a positive condition around the work, and there is no early exit at
// all -- the scan is exactly (h) x (w) cells every generation, whether or not
// anything can move.  That costs nothing: the fixed point is detected by
// CHANGED, and a generation that changes nothing still costs one scan.
def step() -> long {
    GEN = GEN + 1;
    CHANGED = 0;
    let moved = 0;
    let g = GEN;
    let y = IH;               // store row IH == logical row IH-1, the bottom
    while (y >= 1) {
        let x = 1;
        while (x <= IW) {
            let i = y * GWa + x;
            // a cell written earlier this generation has already moved: it is
            // settled, and touching it would let one grain move twice.
            if (STAMP[i] != g) {
                let m = MAT[i];
                if (m != M_EMPTY && m != M_STONE) {
                    let did = false;
                    if (m == M_SAND) {
                        did = sand_move(x, y)
                    } else if (m == M_WATER || m == M_OIL) {
                        did = liquid_move(m, x, y)
                    } else if (m == M_FIRE) {
                        did = fire_step(x, y, AGE[i] + 1)
                    } else if (m == M_SMOKE) {
                        did = smoke_move(x, y, AGE[i] + 1)
                    };
                    if (did) { moved = moved + 1 }
                }
            };
            x = x + 1
        };
        y = y - 1
    };
    MOVES = moved;
    moved
};

// run(n) -> long -- n generations, and the generation at which the grid last
// changed (0 if it never did).  No allocation, no clock, no console.
def run(n: long) -> long {
    let last = 0;
    let k = 0;
    while (k < n) {
        step();
        if (CHANGED == 1) { last = GEN };
        k = k + 1
    };
    last
};

// run_until_settled(limit) -> long -- step until a generation changes NOTHING,
// which is a real fixed point (generation n+1 is byte-identical to generation
// n) and not "looks settled".  Returns the generation it settled at, or 0 - 1
// if it had not settled by `limit`.  Two loops, because there is no `break`.
def run_until_settled(limit: long) -> long {
    let k = 0;
    let settled = 0;
    while (k < limit && settled == 0) {
        step();
        if (CHANGED == 0) { settled = GEN; };
        k = k + 1
    };
    if (settled == 0) { 0 - 1 } else { settled }
};

// ===========================================================================
// measuring the grid -- one pass, two fixed tally arrays
// ===========================================================================

let CNT: [long; 8] = [0; 8];    // cells per material; slot 7 is the total matter
let SY: [long; 8] = [0; 8];     // sum of y over the cells of each material
let TOPY: [long; 8] = [0; 8];   // the smallest y (the topmost row) per material
let MATTER = 0;                  // cells that are not EMPTY
let EMPTY_N = 0;                 // EMPTY cells inside the LOGICAL grid
let BORDER_STONE = 0;            // STONE cells that are not in the logical grid

// tally() -- one pass over the store, filling the three module-level arrays.
// Called by the report and by every property check.  It allocates nothing, so
// it can be called once per generation in a test.
def tally() {
    let m = 0;
    while (m < NMATN) {
        CNT[m] = 0;
        SY[m] = 0;
        TOPY[m] = 0 - 1;
        m = m + 1
    };
    MATTER = 0;
    EMPTY_N = 0;
    BORDER_STONE = 0;
    let y = 1;
    while (y <= IH) {
        let x = 1;
        while (x <= IW) {
            let v = MAT[y * GWa + x];
            CNT[v] = CNT[v] + 1;
            SY[v] = SY[v] + y;
            if (TOPY[v] < 0) { TOPY[v] = y; };
            if (v == M_EMPTY) { EMPTY_N = EMPTY_N + 1; };
            x = x + 1
        };
        y = y + 1
    };
    MATTER = CNT[M_STONE] + CNT[M_SAND] + CNT[M_WATER] + CNT[M_OIL]
           + CNT[M_FIRE] + CNT[M_SMOKE];
    // the ghost border, counted from OUTSIDE the logical grid: every store cell
    // that is not interior must be STONE, and this counts them.  props.y C9
    // asserts it is exactly the border's size at every generation.
    BORDER_STONE = 0;
    let r = 0;
    while (r < GHa) {
        let c = 0;
        while (c < GWa) {
            if (!(r >= 1 && r <= IH && c >= 1 && c <= IW)) {
                if (MAT[r * GWa + c] == M_STONE) { BORDER_STONE = BORDER_STONE + 1 }
            };
            c = c + 1
        };
        r = r + 1
    }
};

// checksum() -> long -- FNV-1a 64 over the whole store's material AND age bytes.
// Used by the property check to compare two grids, and by the report.  It is
// over the WHOLE store, border included, so a corrupted ghost border cannot
// hide.  `long` multiply wraps (the same note fb.y's capture_checksum makes), so
// the FNV prime's high bits fold in as intended and there is no masking.
def checksum() -> long {
    let h: long = -3750763034362895579;   // 14695981039346656037, signed
    let i = 0;
    while (i < CELLS) {
        h = (h ^ (MAT[i] + 0)) * 1099511628211;
        h = (h ^ (AGE[i] + 0)) * 1099511628211;
        i = i + 1
    };
    h
};

// material_sum(m) -> long -- the sum of y over every cell of material m.  Kept
// as a function so props.y cannot accidentally read a stale SY[] from a tally
// it did not take.
def material_sum(m: long) -> long { SY[m] };

// ===========================================================================
// the snapshot -- 64 KiB, allocated once, and used ONLY by the property check
//
// props.py C2 needs to compare generation n with generation n+1 cell by cell,
// and that needs a copy of the grid to compare against.  It lives here rather
// than in props.y so the store stays in one module: two modules each holding a
// view of the same array is a way to have one of them be a stale copy.  It is
// never touched by step(), so the no-allocation property is unaffected.
let PREV: [byte; 66564] = [0; 66564];

// snapshot() -- copy the whole store's materials into PREV.  Call it BEFORE
// step().
def snapshot() {
    let i = 0;
    while (i < CELLS) {
        PREV[i] = MAT[i];
        i = i + 1
    }
};

// prev_at(x, y) -> long -- what the material at store (x, y) was when
// snapshot() was last called.
def prev_at(x: long, y: long) -> long { PREV[y * GWa + x] };

// age_at(x, y) -> long -- the age of the cell at store (x, y).
def age_at(x: long, y: long) -> long { AGE[y * GWa + x] };

// stamp_at(x, y) -> long -- the generation in which this cell was last written.
// A cell whose stamp equals the current GEN was ARRIVED AT during the
// generation just run, which is the only way to know where a grain came from:
// a grain that vacates a cell leaves it empty and unstamped, so a later grain in
// the same scan may move straight in and the cell ends up looking untouched.
// props.y C2c reads this for exactly that reason, and grid.y's own header says
// why the stamp exists in the first place.
def stamp_at(x: long, y: long) -> long { STAMP[y * GWa + x] };

// vol_total() -> long -- oil + fire + smoke: the volatile total, conserved by
// the spread (oil -> fire) and the expiry (fire -> smoke) and destroyed only by
// smoke vanishing.
def vol_total() -> long { CNT[M_OIL] + CNT[M_FIRE] + CNT[M_SMOKE] };

// col_heights(liq) -- no, a function returning an array would allocate.  The
// column levels are already maintained by lvl_add/lvl_set, so the property
// check reads them through col_level().
def col_level(liq: long, x: long) -> long { lvl_get(liq, x) };

// ===========================================================================
// the deterministic generator -- and why it is a module-level LCG
//
// No float, no clock, no unseeded randomness.  A 64-bit LCG whose state lives
// in two module-level longs, so filling a scene allocates nothing and the same
// --seed gives the same grid on every run and every machine.  The multiplication
// is masked to 64 bits after every step; without the mask the state would grow
// out of the range a long holds.
let RNG = 1;

def srand(s: long) {
    let v = s & 0x7FFFFFFFFFFFFFFF;
    if (v == 0) { v = 0x2545F4914F6CDD1D };
    RNG = v;
    SEEDV = s
};

// rnd() -> long -- the next value, a 63-bit LCG (Knuth's MMIX constants).
// `long` multiply wraps, so the mask is only there to keep the value in range.
def rnd() -> long {
    RNG = (RNG * 6364136223846793005 + 1442695040888963407) & 0x7FFFFFFFFFFFFFFF;
    RNG
};

// rnd_below(n) -> long -- a value in 0..n-1.  The multiply-shift: a plain
// `RND % n` would bias toward the low end, which matters only cosmetically
// here, but the shift costs nothing and the range is exact.
def rnd_below(n: long) -> long {
    if (n <= 1) { return 0 };
    let v = (rnd() >> 16) * n;
    (v >> 48) % n
};

// ===========================================================================
// text rendering -- a glyph and a colour per material
// ===========================================================================

// glyph(m) -> long -- the codepoint drawn for a material in --no-tty mode.
// Plain ASCII so EXPECTED is a text file anyone can read in a diff.
def glyph(m: long) -> long {
    if (m == M_STONE) { return 35 };     // '#'
    if (m == M_SAND) { return 111 };     // 'o'
    if (m == M_WATER) { return 126 };    // '~'
    if (m == M_OIL) { return 61 };       // '='
    if (m == M_FIRE) { return 64 };      // '@'
    if (m == M_SMOKE) { return 46 };     // '.'
    if (m == M_EMPTY) { return 32 };     // ' '
    63                                 // '?', a material that cannot happen
};

// material_name(m) -> str -- for the report.  A chain of returns, not an array
// literal built per call: `[".", "stone", ...][m]` would allocate an 8-element
// array on every report line, and the report is printed from inside a loop.
def material_name(m: long) -> str {
    if (m == M_EMPTY) { return "empty" };
    if (m == M_STONE) { return "stone" };
    if (m == M_SAND) { return "sand" };
    if (m == M_WATER) { return "water" };
    if (m == M_OIL) { return "oil" };
    if (m == M_FIRE) { return "fire" };
    if (m == M_SMOKE) { return "smoke" };
    "?"
};