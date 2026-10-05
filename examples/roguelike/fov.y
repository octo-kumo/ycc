// fov.y -- a symmetric-permissive field of view.
//
// ===========================================================================
// WHAT THIS IS, AND WHY IT IS NOT RECURSIVE SHADOWCASTING
// ===========================================================================
//
// `compute(cx, cy, r)` answers "which tiles can the eye at (cx, cy) see?", and
// answers it by testing ONE THING for every tile inside the radius:
//
//     a tile is visible when the straight segment from the eye to that tile's
//     CENTRE crosses no opaque tile -- with the corner exception that a
//     segment grazing a corner between two tiles is blocked only when BOTH of
//     those tiles are opaque.
//
// That single sentence is the whole algorithm.  It has two properties the
// alternatives were chosen for:
//
//   SYMMETRIC.  Visibility is a property of the segment, and the segment from
//   A to B is the same segment as from B to A, so if you can see the rat then
//   the rat can see you.  A raycast is symmetric in practice but not by
//   construction; a slope-based shadowcaster is neither, and getting a
//   symmetric one means carrying the +/- half-cell slope window correctly
//   through eight octants.
//   PERMISSIVE.  The corner exception is what stops a doorway seen exactly
//   edge-on from being invisible, which is the classic complaint about the
//   strict rule.
//
// The brief offered "recursive shadowcasting or a symmetric-permissive FOV",
// and this is the second.  It is chosen here because it needs NO SLOPE
// ARITHMETIC AT ALL -- no octant multiplier table, no half-cell window, no
// fixed point -- and therefore no `fx`, and nothing to get subtly wrong.  The
// cost is one extra pass: at radius 8 that is 289 candidate tiles and about
// 1200 tile tests, against roughly 350 slope computations for a shadowcaster.
// Both are far below the cost of the two `write(2)`s a frame costs.
//
// A SECOND, INDEPENDENT IMPLEMENTATION IS HERE TOO: `ray()`, a plain
// symmetric raycast through `fx`'s integer trigonometry.  It is far too slow to
// ship and far too simple to be wrong, which is exactly what makes it a
// reference: `roguelike --check N` generates N levels and cross-checks the two
// against each other, so "the field of view respects walls" is a measurement
// rather than a claim.
//
// ===========================================================================
// MEMORY
// ===========================================================================
//
// VIS is one fixed [long; 8192] allocated at module load: 64 KiB, once, for
// the life of the program.  `compute` clears it with a flat 8192-iteration
// loop -- O(cells) rather than O(map) on purpose: it is one tight loop over a
// fixed array with no index arithmetic, and it beats a per-row loop with a
// multiply in it.  Nothing in this file allocates, ever, so `compute` is safe
// to call on the per-turn path.

import fx;
import dungeon;

const NCELL = 8192;

let VIS: [long; 8192] = [0; 8192];
let RADIUS: long = 8;
let LIT: long = 0;                 // tiles lit by the last compute()

def clear() -> void {
    let i = 0;
    while (i < NCELL) {
        VIS[i] = 0;
        i = i + 1;
    };
};

// lit(i) -- is tile i visible?  Out of range reads as not visible, so a caller
// holding an unchecked index gets a quiet answer instead of a trap.
def lit(i: long) -> bool {
    if (i < 0 || i >= NCELL) { return false; };
    VIS[i] == 1
};

// light(x, y) -- mark one tile and count it.  Off the map is ignored, and so is
// a tile already lit; an off-map tile is opaque to `los` anyway, so nothing can
// be lit past the border.  The answer is in the module-level LIT, which is why
// this and `compute` and `ray` return nothing: a caller that wants the count
// reads LIT, and no caller has to remember which of the three gave it one.
def light(x: long, y: long) -> void {
    if (dungeon.in_map(x, y)) {
        let k = y * dungeon.W + x;
        if (VIS[k] == 0) {
            VIS[k] = 1;
            LIT = LIT + 1;
        };
    };
};

// ---------------------------------------------------------------------------
// the segment predicate
// ---------------------------------------------------------------------------

// los(ax, ay, bx, by) -> bool -- is the straight segment from A to B free of
// opaque tiles?  Endpoints are NOT tested: the eye stands in A (always floor)
// and B is allowed to be a wall, because seeing the FACE of a wall is the
// point of a field of view.
//
// THE CANONICALISATION IS THE WHOLE SYMMETRY ARGUMENT.  The walk is a
// monotone supercover DDA, and a DDA is not symmetric: Bresenham's error term
// breaks ties in the direction of travel, so walking A->B and B->A can visit
// different cells.  So the walk is first forced into one direction -- always
// left to right, i.e. bx >= ax -- by swapping the endpoints.  After that the
// walk for (A, B) and the walk for (B, A) are the same walk, and `los` is
// symmetric by construction rather than by luck.
//
// The diagonal case is the permissive one.  When a step advances both x and y
// the segment passes exactly through the corner shared by two tiles, so it is
// blocked only when BOTH of them are opaque.  That is one comparison instead of
// two and it is the difference between a doorway you can see edge-on and one you
// cannot.
def los(ax: long, ay: long, bx: long, by: long) -> bool {
    let x0 = ax;
    let y0 = ay;
    let x1 = bx;
    let y1 = by;
    if (x1 < x0) {
        x0 = bx;
        y0 = by;
        x1 = ax;
        y1 = ay;
    };
    let dx = x1 - x0;              // >= 0 by the canonicalisation above
    let dy = y1 - y0;
    let ady = if (dy < 0) { 0 - dy } else { dy };
    if (dx == 0 && ady == 0) { return true; };
    let sy = if (dy < 0) { 0 - 1 } else { 1 };
    let clear = true;
    let x = x0;
    let y = y0;
    if (dx >= ady) {
        // x-dominant: dx steps in x, ady of them also step in y.
        let err = ady;
        let i = 0;
        while (i < dx && clear) {
            x = x + 1;
            err = err - ady;
            if (err <= 0 && ady > 0) {
                // a corner crossing: (x, y) and (x - 1, y + sy)
                if (x != x1 || y != y1) {
                    if (dungeon.opaque(x, y) && dungeon.opaque(x - 1, y + sy)) {
                        clear = false;
                    };
                };
                y = y + sy;
                err = err + dx;
            } else if (x != x1 || y != y1) {
                if (dungeon.opaque(x, y)) { clear = false; };
            };
            i = i + 1;
        };
    } else {
        // y-dominant: ady steps in y, dx of them also step in x.  dx >= 0 still
        // holds, so x only ever increases here too.
        let err = dx;
        let i = 0;
        while (i < ady && clear) {
            y = y + sy;
            err = err - dx;
            if (err <= 0 && dx > 0) {
                // a corner crossing: (x, y) and (x + 1, y - sy)
                if (x != x1 || y != y1) {
                    if (dungeon.opaque(x, y) && dungeon.opaque(x + 1, y - sy)) {
                        clear = false;
                    };
                };
                x = x + 1;
                err = err + ady;
            } else if (x != x1 || y != y1) {
                if (dungeon.opaque(x, y)) { clear = false; };
            };
            i = i + 1;
        };
    };
    clear
};

// compute(cx, cy, r) -- the whole field of view; how many tiles it lit is in
// LIT when it returns.  The scan is a plain square of the radius, minus the corners outside the
// circle, because a candidate set that needs no octant table is worth more than
// the 60-odd cells it costs.  `r` is clamped to 1..64 so a bad radius cannot walk
// off the map, and the origin is always lit.
def compute(cx: long, cy: long, r: long) -> void {
    clear();
    LIT = 0;
    RADIUS = if (r < 1) { 1 } else { if (r > 64) { 64 } else { r } };
    let rad = RADIUS;
    let r2 = rad * rad;
    light(cx, cy);
    let dy = 0 - rad;
    while (dy <= rad) {
        let dx = 0 - rad;
        while (dx <= rad) {
            if ((dx != 0 || dy != 0) && dx * dx + dy * dy <= r2) {
                let tx = cx + dx;
                let ty = cy + dy;
                // Off the map is opaque, so `los` says no and nothing is lit
                // out there.  The `in_map` test is the cheap half of that.
                if (dungeon.in_map(tx, ty) && los(cx, cy, tx, ty)) {
                    light(tx, ty);
                };
            };
            dx = dx + 1;
        };
        dy = dy + 1;
    };
};

// ---------------------------------------------------------------------------
// the reference implementation
// ---------------------------------------------------------------------------

// ray(cx, cy, r, rays, sub) -- an INDEPENDENT field of view: march `rays`
// evenly spaced rays out to radius r, sampling `sub` points per cell of distance
// so the staircase is finer than the grid, and light every tile one of those
// samples lands in plus the opaque tile a ray dies in.
//
// It shares no code with `los` in any particular: no DDA, no error term, no
// corner rule -- trigonometry and integer stepping.  Which is exactly what makes
// it usable as a reference, and exactly why it needs the resolution it needs.
//
// THE RESOLUTION IS NOT COSMETIC.  Marching one sample per cell of distance walks
// a staircase that differs from the true segment by one cell in the middle of a
// long diagonal, so with one sample per cell this reference MISSES tiles `los`
// finds -- it is a coarser approximation of the same thing, not a check on it.
// At four samples per cell it converges from below and covers everything `los`
// lights, which is the direction `--check` asserts:
//
//     every tile `los` lights is lit by the reference too, and
//     the tiles only the reference lights are the cells a segment merely GRAZES,
//     which is the permissive convention doing its job.
//
// The other direction is reported and is NOT asserted: those grazing cells are
// legitimately visible, so a ray that misses one is the ray being coarse, not
// `los` being wrong.
def ray(cx: long, cy: long, r: long, rays: long, sub: long) -> void {
    clear();
    LIT = 0;
    let rad = if (r < 1) { 1 } else { r };
    let n = if (rays < 8) { 8 } else { rays };
    let s_sub = if (sub < 1) { 1 } else { sub };
    light(cx, cy);
    // Angles in Q30, k * 2pi / n, no float anywhere.  angle 0 is +x (right) and
    // angle pi/2 is +y (down the screen), so x comes from sin and y from cos --
    // the other way round walks the same ray twice and misses a quarter of the
    // circle.
    let step_ang = fx.fdiv(fx.TWO_PI, fx.from_int(n));
    let k = 0;
    while (k < n) {
        let ang = fx.mul(fx.from_int(k), step_ang);
        let s = fx.sin(ang);
        let c = fx.cos(ang);
        let steps = rad * s_sub;
        let i = 0;
        let dead = false;
        while (i < steps && !dead) {
            // sample at the MIDDLE of each sub-step, in half-cell units of 1/s_sub
            let half = 2 * i + 1;
            let t = fx.fdiv(fx.from_int(half), fx.from_int(2 * s_sub));
            let px = fx.to_int(fx.mul(s, t) + fx.from_int(cx));
            let py = fx.to_int(fx.mul(c, t) + fx.from_int(cy));
            light(px, py);
            if (dungeon.opaque(px, py)) {
                dead = true;
            } else {
                i = i + 1;
            };
        };
        k = k + 1;
    };
};

// visible(x0, y0, x1, y1) -- the symmetry property as a predicate: can (x0, y0)
// see (x1, y1)?  Defined once so the validator and the renderer agree on what
// visibility means.
def visible(x0: long, y0: long, x1: long, y1: long) -> bool {
    if (x0 == x1 && y0 == y1) { return true; };
    los(x0, y0, x1, y1)
};

export { NCELL, VIS, RADIUS, LIT, clear, lit, light, los, visible,
          compute, ray };
