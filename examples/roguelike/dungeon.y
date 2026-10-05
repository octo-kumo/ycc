// dungeon.y -- rooms, corridors, doors, stairs, and the flood fill that proves
// the generator did not strand anybody.
//
// ===========================================================================
// WHY PARALLEL FIXED ARRAYS AND NOT A MAP OF RECORDS
// ===========================================================================
//
// A tile is a `long` in `TILE[y * W + x]`, not a record in a map.  Three
// reasons, in order of how much they matter:
//
//   1. Y HAS NO `push`, NO `sort` AND NO GROWING FIXED ARRAY.  `+=` is the
//      whole array interface, and it appends; `TILE[n] = k` on a fixed
//      `[long; N]` is the only way to write one element without allocating.
//   2. A MAP IS A LINEAR SCAN in Y (ORCHESTRATOR.md 2.8).  The field-of-view
//      pass asks "is this tile opaque?" for every one of ~500 cells of a turn,
//      and `game` asks it again for every monster move.  With parallel fixed
//      arrays that is one load; with a `{long => long}` map it would be a walk
//      of the whole map, per query.
//   3. `y * W + x` is the representation a roguelike actually wants.  The
//      whole map is 8192 longs = 64 KiB, allocated once at module load, and a
//      level is thrown away by overwriting it -- the heap is an arena and never
//      frees (ORCHESTRATOR.md 2.7), so "regenerating" MUST mean "overwrite",
//      never "allocate another".
//
// The three arrays are deliberately the same size and the same indexing:
//   TILE     what is here        (T_WALL / T_FLOOR / T_DOOR / T_STAIRS)
//   DOOROPEN 1 while a door is open.  A closed door is opaque AND blocks, so
//            doors are the one tile whose meaning needs a second array -- and
//            it is a second ARRAY, not a wider tile, because a wider tile would
//            double the cost of the field-of-view loop for every tile.
//   REACH    scratch for the flood fill.  Never read by anything else.
//
// ===========================================================================
// THE GENERATOR
// ===========================================================================
//
// Rooms and corridors, the way every small roguelike has done it since Rogue:
// scatter `ROOM_TRIES` rectangles, keep the ones that do not touch an existing
// room even with a one-cell margin, and join consecutive room centres with an
// L-shaped corridor whose elbow goes horizontal-then-vertical or the other way
// round on a coin flip.  Three properties matter and all three are asserted,
// not hoped for:
//
//   * ROOMS DO NOT OVERLAP -- `boxes_touch` compares rectangles inflated by
//     MARGIN, so two rooms never share an edge either, which is what leaves a
//     wall for the corridor to run through.
//   * CORRIDORS CONNECT -- a corridor is carved only over T_WALL, and both its
//     ends are room CENTRES, which are already floor.  So a corridor cannot
//     stop one tile short of its room, and cannot carve a hole through a door or
//     the stairs.
//   * NOTHING IS STRANDED -- `check_reachable()` floods from the player's
//     start over every non-wall tile and then checks every room centre and the
//     stairs.  It returns the number of failures, and `roguelike.y` calls it on
//     every generated level; `--check N` calls it on N of them.
//
// A level with fewer than two rooms cannot be connected at all, so the
// generator retries with a deterministically derived seed (up to ATTEMPTS
// times) and reports failure rather than returning a broken dungeon.
//
// NO `break`, NO `continue`: every early exit below is either a guard flag the
// loop condition tests or the body wrapped in a positive condition.

import rnd;

// ---- dimensions.  Array sizes must be integer literals in a type position,
// so the numbers are written out in the types and repeated in the constants.
const MAX_W = 128;
const MAX_H = 64;
const NCELL = 8192;               // MAX_W * MAX_H
const MAX_ROOMS = 24;
const ROOM_TRIES = 400;
const MIN_RW = 3;
const MAX_RW = 8;
const MIN_RH = 3;
const MAX_RH = 6;
const MARGIN = 1;                 // the wall kept between two rooms
const ATTEMPTS = 8;
const MIN_W = 21;                 // the smallest map a dungeon fits in
const MIN_H = 15;

// ---- tile kinds.  Longs, not a union: see the header on why.
const T_WALL = 0;
const T_FLOOR = 1;
const T_DOOR = 2;
const T_STAIRS = 3;
const NTILES = 4;

let W: long = 64;
let H: long = 32;
let TILE: [long; 8192] = [0; 8192];
let DOOROPEN: [long; 8192] = [0; 8192];
let REACH: [long; 8192] = [0; 8192];
let QUEUE: [long; 8192] = [0; 8192];

// Rooms, as parallel arrays rather than 24 records: a record literal costs 40
// bytes every time it is evaluated (SUGGESTIONS.md 7), and this runs inside a
// placement loop.
let RX0: [long; 32] = [0; 32];
let RY0: [long; 32] = [0; 32];
let RX1: [long; 32] = [0; 32];
let RY1: [long; 32] = [0; 32];
let RCX: [long; 32] = [0; 32];
let RCY: [long; 32] = [0; 32];
let NROOMS: long = 0;
let NCORR: long = 0;              // room-to-room connections
let NSEG: long = 0;               // carved line segments (1 or 2 per corridor)
let NFLOOR: long = 0;
let START_X: long = 0;
let START_Y: long = 0;
let STAIRS_X: long = 0;
let STAIRS_Y: long = 0;
let HAS_STAIRS: long = 0;
let ATTEMPT: long = 0;             // which retry produced the level on screen

// ---------------------------------------------------------------------------
// accessors
// ---------------------------------------------------------------------------

def in_map(x: long, y: long) -> bool {
    x >= 0 && y >= 0 && x < W && y < H
};

def tile_at(x: long, y: long) -> long {
    // Out of bounds reads as rock.  Every caller that can be handed an
    // arbitrary coordinate gets an answer instead of an index-out-of-bounds
    // trap, which would land on stdout and corrupt a frame (2.6).
    if (!in_map(x, y)) { return T_WALL; };
    TILE[y * W + x]
};

// put -> void, and that is on purpose.  It used to answer `bool` ("was the tile
// on the map?") and NO caller ever read it, so a call as a statement was a
// dropped result -- which `-W 1` duly reports.  A function nobody reads a value
// from should not have one.
def put(x: long, y: long, k: long) -> void {
    if (in_map(x, y)) { TILE[y * W + x] = k; }
};

// opaque(x, y) -- does this tile stop light?  A wall does; a closed door does;
// an open door does not, which is why the door is worth having: you can see
// through it once you have opened it.  Off the map is opaque, so the field of
// view cannot leak round the border.
def opaque(x: long, y: long) -> bool {
    if (!in_map(x, y)) { return true; };
    let i = y * W + x;
    if (TILE[i] == T_WALL) { return true; };
    if (TILE[i] == T_DOOR) { return DOOROPEN[i] == 0; };
    false
};

// blocks(x, y) -- may the player not walk here?  A wall and a shut door both
// do.  A staircase does not: you walk onto it.
def blocks(x: long, y: long) -> bool {
    if (!in_map(x, y)) { return true; };
    let i = y * W + x;
    if (TILE[i] == T_WALL) { return true; };
    if (TILE[i] == T_DOOR) { return DOOROPEN[i] == 0; };
    false
};

// walkable(x, y) -- is this tile part of the floor the flood fill may cross?
// Doors count: a shut door is one `,` away from being open, so calling a room
// unreachable because a door is shut would be the wrong question.
def walkable(x: long, y: long) -> bool {
    if (!in_map(x, y)) { return false; };
    TILE[y * W + x] != T_WALL
};

def is_open_door(x: long, y: long) -> bool {
    in_map(x, y) && TILE[y * W + x] == T_DOOR && DOOROPEN[y * W + x] == 1
};

def open_door(x: long, y: long) -> void {
    if (in_map(x, y)) {
        let i = y * W + x;
        if (TILE[i] == T_DOOR) { DOOROPEN[i] = 1; };
    };
};

def count_floor() -> long {
    let n = 0;
    let i = 0;
    while (i < NCELL) {
        if (i < W * H && TILE[i] != T_WALL) { n = n + 1; };
        i = i + 1;
    };
    n
};

// ---------------------------------------------------------------------------
// carving
// ---------------------------------------------------------------------------

def boxes_touch(ax0: long, ay0: long, ax1: long, ay1: long, k: long) -> bool {
    // True when the rectangle (ax0..ax1, ay0..ay1) overlaps room k's rectangle
    // inflated by MARGIN on every side.  Touching counts as overlapping: two
    // rooms that share a wall would let a corridor run between them and fuse
    // them into one lumpy room.
    if (ax0 <= RX1[k] + MARGIN && ax1 >= RX0[k] - MARGIN
        && ay0 <= RY1[k] + MARGIN && ay1 >= RY0[k] - MARGIN) {
        return true;
    };
    false
};

def carve_room(x0: long, y0: long, x1: long, y1: long) {
    let y = y0;
    while (y <= y1) {
        let x = x0;
        while (x <= x1) {
            put(x, y, T_FLOOR);
            x = x + 1;
        };
        y = y + 1;
    };
};

// carve_h -- floor from x0 to x1 along row y.  Returns the index of the last
// tile it actually CHANGED (rock to floor), or -1 when the whole run was
// already floor -- which is how `connect` finds the cell just outside a room
// and hangs a door on it.  Nothing is ever carved over a door or the stairs.
def carve_h(x0: long, x1: long, y: long) -> long {
    let last = 0 - 1;
    let x = if (x0 <= x1) { x0 } else { x1 };
    let hi = if (x0 <= x1) { x1 } else { x0 };
    while (x <= hi) {
        if (tile_at(x, y) == T_WALL) {
            put(x, y, T_FLOOR);
            last = y * W + x;
        };
        x = x + 1;
    };
    last
};

def carve_v(y0: long, y1: long, x: long) -> long {
    let last = 0 - 1;
    let y = if (y0 <= y1) { y0 } else { y1 };
    let hi = if (y0 <= y1) { y1 } else { y0 };
    while (y <= hi) {
        if (tile_at(x, y) == T_WALL) {
            put(x, y, T_FLOOR);
            last = y * W + x;
        };
        y = y + 1;
    };
    last
};

// connect -- one corridor, an L with the elbow's orientation on a coin flip.
// Both ends are room centres, so the corridor always reaches both rooms.  The
// door goes on the last tile the FINAL segment changed, i.e. the one in the
// doorway, and only on a coin flip, so some rooms have no door at all.
def connect(i: long) {
    let ax = RCX[i];
    let ay = RCY[i];
    let bx = RCX[i + 1];
    let by = RCY[i + 1];
    let last = 0 - 1;
    if (rnd.chance(50)) {
        let _first = carve_h(ax, bx, ay);
        last = carve_v(ay, by, bx);
    } else {
        let _first = carve_v(ay, by, ax);
        last = carve_h(ax, bx, by);
    };
    // An L with a zero-length arm is one segment, not two.
    let sh = if (ax != bx) { 1 } else { 0 };
    let sv = if (ay != by) { 1 } else { 0 };
    let segs = sh + sv;
    NSEG = NSEG + (if (segs == 0) { 1 } else { segs });
    NCORR = NCORR + 1;
    if (last >= 0 && rnd.chance(45)) {
        let lx = last % W;
        let ly = last / W;
        put(lx, ly, T_DOOR);
        DOOROPEN[last] = 0;
    }
};

def place_rooms() -> void {
    NROOMS = 0;
    let tries = 0;
    let go = tries < ROOM_TRIES;
    while (go) {
        tries = tries + 1;
        let rw = rnd.range(MIN_RW, MAX_RW);
        let rh = rnd.range(MIN_RH, MAX_RH);
        let x0 = rnd.range(1, W - rw - 2);
        let y0 = rnd.range(1, H - rh - 2);
        let x1 = x0 + rw;
        let y1 = y0 + rh;
        let fits = in_map(x0 - 1, y0 - 1) && in_map(x1 + 1, y1 + 1);
        let k = 0;
        if (fits) {
            while (k < NROOMS) {
                if (boxes_touch(x0, y0, x1, y1, k)) { fits = false; };
                k = k + 1;
            };
        };
        if (fits) {
            carve_room(x0, y0, x1, y1);
            RX0[NROOMS] = x0;
            RY0[NROOMS] = y0;
            RX1[NROOMS] = x1;
            RY1[NROOMS] = y1;
            RCX[NROOMS] = x0 + rw / 2;
            RCY[NROOMS] = y0 + rh / 2;
            NROOMS = NROOMS + 1;
        };
        go = tries < ROOM_TRIES && NROOMS < MAX_ROOMS;
    };
};

// ---------------------------------------------------------------------------
// the flood fill
// ---------------------------------------------------------------------------

// visit -- add (nx, ny) to the fill if it is walkable and unseen, and answer
// the new tail of the queue.  Taking and returning `tail` rather than
// mutating a module variable keeps the caller's loop honest and needs no
// `break`.
def visit(nx: long, ny: long, tail: long) -> long {
    if (nx < 0 || ny < 0 || nx >= W || ny >= H) { return tail; };
    let k = ny * W + nx;
    if (TILE[k] == T_WALL) { return tail; };
    if (REACH[k] == 1) { return tail; };
    REACH[k] = 1;
    QUEUE[tail] = k;
    tail + 1
};

// flood(x0, y0) -> long -- how many tiles are reachable from (x0, y0) walking
// on anything that is not a wall.  The queue is a fixed [long; 8192] and every
// tile is enqueued at most once, so it cannot overflow.  Returns 0 when the
// start itself is not walkable.
def flood(x0: long, y0: long) -> long {
    let i = 0;
    while (i < NCELL) { REACH[i] = 0; i = i + 1; };
    if (!walkable(x0, y0)) { return 0; };
    REACH[y0 * W + x0] = 1;
    QUEUE[0] = y0 * W + x0;
    let head = 0;
    let tail = 1;
    let live = true;
    while (head < tail && live) {
        let c = QUEUE[head];
        head = head + 1;
        let cx = c % W;
        let cy = c / W;
        tail = visit(cx - 1, cy, tail);
        tail = visit(cx + 1, cy, tail);
        tail = visit(cx, cy - 1, tail);
        tail = visit(cx, cy + 1, tail);
    };
    tail
};

// check_reachable() -> long -- 0 when every room centre and the stairs are
// reachable from the start, and the number of failures otherwise.  This is the
// assertion that makes "a generator that strands the player" a caught bug and
// not a shipped one; `--check N` runs it over N levels.
def check_reachable() -> long {
    let start_bad = flood(START_X, START_Y);
    let bad = 0;
    if (start_bad == 0) { return 99; };
    let k = 0;
    while (k < NROOMS) {
        if (REACH[RCY[k] * W + RCX[k]] == 0) { bad = bad + 1; };
        k = k + 1;
    };
    if (HAS_STAIRS == 1) {
        if (REACH[STAIRS_Y * W + STAIRS_X] == 0) { bad = bad + 1; };
    };
    bad
};

// ---------------------------------------------------------------------------
// the level
// ---------------------------------------------------------------------------

def configure(w: long, h: long) {
    // The caller has already refused a map too small to hold a dungeon, so
    // this only clamps.  Clamping rather than refusing is deliberate: the
    // bounds are checked in every accessor anyway.
    W = if (w < MIN_W) { MIN_W } else { if (w > MAX_W) { MAX_W } else { w } };
    H = if (h < MIN_H) { MIN_H } else { if (h > MAX_H) { MAX_H } else { h } }
};

def blank() -> void {
    let i = 0;
    while (i < NCELL) {
        TILE[i] = T_WALL;
        DOOROPEN[i] = 0;
        i = i + 1;
    };
    NSEG = 0;
    NCORR = 0;
    HAS_STAIRS = 0
};

// generate(base) -> long -- one level, deterministic in `base`.  Returns the
// number of rooms, or 0 when ATTEMPTS tries all failed to produce two, which
// the caller reports as a diagnostic rather than playing.
// `blank()` is the whole "free" a level gets: the heap is an arena, so a new
// level is the same 64 KiB overwritten.
def generate(base: long) -> long {
    let attempt = 0;
    let got = 0;
    let try_more = true;
    while (try_more && attempt < ATTEMPTS) {
        blank();
        rnd.seed(base + attempt * 65537);
        place_rooms();
        if (NROOMS >= 2) {
            let i = 0;
            while (i + 1 < NROOMS) {
                connect(i);
                i = i + 1;
            };
            START_X = RCX[0];
            START_Y = RCY[0];
            // The stairs go in the LAST room, so the walk to the exit crosses
            // every corridor the level has.
            STAIRS_X = RCX[NROOMS - 1];
            STAIRS_Y = RCY[NROOMS - 1];
            if (STAIRS_X == START_X && STAIRS_Y == START_Y) {
                STAIRS_X = RX1[NROOMS - 1];
                STAIRS_Y = RY1[NROOMS - 1];
            };
            put(STAIRS_X, STAIRS_Y, T_STAIRS);
            HAS_STAIRS = 1;
            got = NROOMS;
            try_more = false;
        } else {
            attempt = attempt + 1;
        };
    };
    ATTEMPT = attempt;
    NFLOOR = count_floor();
    got
};

export { MAX_W, MAX_H, NCELL, MAX_ROOMS, MIN_W, MIN_H, MIN_RW, MAX_RW,
          MIN_RH, MAX_RH, T_WALL, T_FLOOR, T_DOOR, T_STAIRS, NTILES,
          W, H, NROOMS, NCORR, NSEG, NFLOOR, START_X, START_Y,
          STAIRS_X, STAIRS_Y, HAS_STAIRS, ATTEMPT,
          RX0, RY0, RX1, RY1, RCX, RCY,
          in_map, tile_at, put, opaque, blocks, walkable, is_open_door,
          open_door, count_floor, carve_room, carve_h, carve_v, connect,
          place_rooms, visit, flood, check_reachable, configure, blank, generate };
