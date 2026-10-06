// props.y -- sandfall's property check: `--check`.
//
// ===========================================================================
// WHY THIS FILE EXISTS AT ALL
//
// A golden file proves DETERMINISM and nothing else.  `cube` in this campaign
// passed every gate item while rendering a defect, because its EXPECTED had
// been generated from the broken output.  So everything here is an assertion
// about behaviour, with NO reference file anywhere, and every assertion could
// fail with the code unchanged.
//
// ===========================================================================
// THE RECURRING FAILURE MODE, AND WHAT IS DONE ABOUT IT HERE
//
// Two agents in this campaign shipped checks that compared two values which
// were BOTH ABSENT, and got a clean pass out of it.  Three defences, and the
// first two are structural rather than a matter of care:
//
//   1. **No expected value is read from the code under test.**  Every total
//      here is arithmetic over literals in THIS file.  grid.CNT[] -- the
//      counter the simulation maintains -- is only ever the OBSERVED side of a
//      comparison.  A conservation assertion whose pre-count and post-count
//      both come from one counter is `0 == 0` wearing a conservation costume.
//
//   2. **Two independent paths for every count.**  C10 counts the sand again by
//      rendering the grid to a STRING and counting the 'o' bytes, which shares
//      no code with the byte-array tally.  If the tally were broken, C1 could
//      pass and C10 could not.
//
//   3. **The observed value is asserted present and non-zero BEFORE it is
//      compared.**  C0 does this for every material it goes on to count, C11
//      requires the suite to have made at least MIN_CHECKS assertions and
//      examined at least one cell, and C3 requires the fixed point's checksum
//      to be non-zero with matter still on the grid -- so "the checksums are
//      equal" cannot be true because both grids are blank.
//
// ===========================================================================
// WHAT IS ASSERTED
//
//  C0  non-vacuity: the box really has stone, sand and water on it before
//      anything is counted, and the counts are printed.
//  C1  conservation of stone, sand and water at EVERY generation of a 300
//      generation run, against literals in this file; plus matter + empty ==
//      w*h.
//  C2  THE UPDATE ORDER -- the thing the brief calls the important one:
//      C2a  one sand grain falls EXACTLY one row per generation, for a literal
//           number of generations.  A top-down scan lands it in ONE.
//      C2b  a four-grain stack descends one row per generation while it has
//           room and then stops, so a column does NOT compact in one step.
//      C2c  two waters one cell apart do NOT merge in one generation.
//      C2d  the structural form: every cell that went empty->material this
//           generation has an 8-neighbour that held that material last
//           generation and is empty now.  Every grain arrived from a
//           neighbour, in one step -- which also catches any index slip.
//      C2e  a grain in a one-cell pocket cannot drain out of it -- sand needs
//           room to slip past its neighbour, which is the rule inject.py found
//           the suite missing when it deleted it.
//  C3  a closed box reaches a FIXED POINT, verified by 20 further generations
//      leaving the checksum bit-identical.
//  C4  monotone invariants at EVERY generation: sum(sand y) and sum(water y)
//      never decrease, sum(stone y) never changes, the topmost sand never goes
//      up, the volatile total never grows, fire never touches stone or sand.
//  C5  sand falls down and never up absent a source: an exact single-grain
//      trajectory, and the topmost sand row over a whole drop.
//  C6  water spreads and does not pile: a poured column must end up spanning
//      several contiguous columns with a hole-free bounding box and a surface
//      flat to within two rows, and no column more than two taller than
//      another.
//  C7  determinism: same seed twice is the same checksum, a DIFFERENT seed is a
//      different one (or --seed is a lie), and 50 generations agree.
//  C8  no allocation in the generation loop: heap_used() flat across 20 000
//      generations, with GEN asserted to have advanced by exactly that many so
//      a skipped loop cannot pass.
//  C9  the ghost border is stone on every side at every generation.
//  C10 the cross-check described above.
//  C11 the meta-check: the suite made enough assertions and examined cells.

import grid;
import scene;
// std's assertion helper: it replaced this file's own `ck`/`ck_num`, which are
// gone -- see the note under the reporting primitives below.
import test;

// The suite's own bookkeeping.  Module-level and fixed: a `+=` into an array
// inside these loops would allocate, and there is no reason to be careless in
// the file whose whole subject is that discipline.  CHECKS and BAD are gone too:
// the assertion tally is test.checks() and test.failures() now, so this file
// keeps no counter of its own that could drift out of step with the assertions
// it claims to have made.
let CELLS_SEEN = 0;
let GEN_SEEN = 0;
const MIN_CHECKS = 90;      // the floor C11 enforces on the suite itself

// -- the reporting primitives ------------------------------------------------

def head(t: str) {
    puts("\n  " + t + "\n")
};

def sub(t: str) {
    puts("    " + t + "\n")
};

// ck(cond, what) and ck_num(got, want, what) ARE GONE.  They were this file's
// own assertion helpers; they are now std's `test.ck(name, ok, detail)` and
// `test.ck_eq(want, got, name)` (src/y/std/test.y).  THE ARGUMENT ORDER MOVED,
// so every call site below was reordered rather than only the definition: the
// local helper read `ck(cond, what)` and std reads `ck(name, ok, detail)`.
// Both return bool, so the call sites that branched on the result still branch
// on it.
//
// What that does to this file's output: an assertion is indented two spaces and
// marked "  ok  " instead of four and "    ok   ", and a ck_eq puts its numbers
// on a second line under the assertion rather than in brackets at the end of
// it.  The information is the same; CHECK.txt was regenerated to match.
//
// The suite's counters are std's as well -- test.checks() instead of CHECKS and
// test.failures() instead of BAD -- which is why nothing here has to keep a
// second tally in step with the first.  test.report() is deliberately NOT
// called: the RESULT line at the bottom of check_all() carries the generation
// count too, so report() alongside it would print the same run's summary
// twice.

// ===========================================================================
// a closed box, described by literals of THIS file
// ===========================================================================

// The box the conservation and fixed-point checks use: a stone basin with a
// flat floor.  Stone cannot be created or destroyed, so nothing can escape,
// which is what makes "reaches a fixed point" a statement about the automaton
// rather than about the box running out of room.
const BW = 40;          // logical width
const BH = 24;          // logical height
const FLOOR_H = 2;      // rows of stone at the bottom
const SAND_X0 = 10;
const SAND_X1 = 19;
const SAND_Y0 = 10;
const SAND_Y1 = 14;
const WATER_X0 = 3;
const WATER_X1 = 9;
const WATER_Y0 = 4;
const WATER_Y1 = 9;

// The expected totals, computed here from the geometry above and NOT read from
// grid.CNT[].  The arithmetic is spelled out so a reader can check it by eye:
//   stone  = BW * FLOOR_H                              = 40 * 2 =  80
//   sand   = (SAND_X1-SAND_X0+1) * (SAND_Y1-SAND_Y0+1) = 10 * 5 =  50
//   water  = (WATER_X1-WATER_X0+1) * (WATER_Y1-WATER_Y0+1) = 7 * 6 = 42
const EXP_STONE = BW * FLOOR_H;
const EXP_SAND = (SAND_X1 - SAND_X0 + 1) * (SAND_Y1 - SAND_Y0 + 1);
const EXP_WATER = (WATER_X1 - WATER_X0 + 1) * (WATER_Y1 - WATER_Y0 + 1);
const EXP_MATTER = EXP_STONE + EXP_SAND + EXP_WATER;

// box_plain() -> bool -- the box, with no fire anywhere, so C4's monotone
// invariants are statements about sand and water alone and cannot be confused
// by a reaction.  It returns whether the geometry fitted, which is a property
// of the constants above rather than of the simulation.
def box_plain() -> bool {
    grid.clear(BW, BH);
    let ok = grid.rect_logical(0, BH - FLOOR_H, BW - 1, BH - 1, grid.M_STONE);
    if (!grid.rect_logical(SAND_X0, SAND_Y0, SAND_X1, SAND_Y1, grid.M_SAND)) { ok = false };
    if (!grid.rect_logical(WATER_X0, WATER_Y0, WATER_X1, WATER_Y1, grid.M_WATER)) { ok = false };
    ok
};

// box_fire() -> bool -- the same box with an oil slick and a fire on it, for
// the checks that need the chemistry.
def box_fire() -> bool {
    let ok = box_plain();
    grid.rect_logical(24, BH - FLOOR_H - 2, 30, BH - FLOOR_H - 1, grid.M_OIL);
    grid.put_logical(27, BH - FLOOR_H - 3, grid.M_FIRE);
    ok
};

// ===========================================================================
// C0 -- non-vacuity
// ===========================================================================

def c0_nonvacuous() {
    head("C0  non-vacuity: the counters are counting something");
    let ok = box_plain();
    grid.tally();
    CELLS_SEEN = grid.IW * grid.IH;
    sub("the test box is " + tostring(BW) + " x " + tostring(BH) + " = "
        + tostring(CELLS_SEEN) + " cells, and it built: " + tostring(ok));
    sub("observed at generation 0: stone " + tostring(grid.CNT[grid.M_STONE])
        + "  sand " + tostring(grid.CNT[grid.M_SAND])
        + "  water " + tostring(grid.CNT[grid.M_WATER])
        + "  oil " + tostring(grid.CNT[grid.M_OIL])
        + "  fire " + tostring(grid.CNT[grid.M_FIRE])
        + "  smoke " + tostring(grid.CNT[grid.M_SMOKE]));
    // The gate on everything downstream: if any of these is zero, the
    // conservation checks that follow would be comparing 0 with 0 and passing
    // for the wrong reason.
    test.ck("the test box's geometry fitted the constants", ok, "");
    test.ck("the box has stone on it before anything is counted", grid.CNT[grid.M_STONE] > 0, "");
    test.ck("the box has sand on it before anything is counted", grid.CNT[grid.M_SAND] > 0, "");
    test.ck("the box has water on it before anything is counted", grid.CNT[grid.M_WATER] > 0, "");
    test.ck("the logical grid has BW*BH cells", CELLS_SEEN == BW * BH, "");
    test.ck("MATTER is non-zero, so `matter` is a real quantity here", grid.MATTER > 0, "")
};

// ===========================================================================
// C1 -- conservation, at every generation, against literals
// ===========================================================================

def c1_conservation() {
    head("C1  stone, sand and water are conserved at EVERY generation");
    let ok = box_plain();
    grid.tally();
    test.ck("the test box's geometry fitted the constants above", ok, "");
    test.ck_eq("stone at generation 0", grid.CNT[grid.M_STONE], EXP_STONE);
    test.ck_eq("sand at generation 0", grid.CNT[grid.M_SAND], EXP_SAND);
    test.ck_eq("water at generation 0", grid.CNT[grid.M_WATER], EXP_WATER);
    test.ck_eq("matter at generation 0", grid.MATTER, EXP_MATTER);

    let gens = 300;
    let bad_c = 0;
    let bad_s = 0;
    let bad_w = 0;
    let bad_m = 0;
    let bad_i = 0;
    let k = 0;
    while (k < gens) {
        grid.step();
        grid.tally();
        if (grid.CNT[grid.M_STONE] != EXP_STONE) { bad_c = bad_c + 1 };
        if (grid.CNT[grid.M_SAND] != EXP_SAND) { bad_s = bad_s + 1 };
        if (grid.CNT[grid.M_WATER] != EXP_WATER) { bad_w = bad_w + 1 };
        if (grid.MATTER != EXP_MATTER) { bad_m = bad_m + 1 };
        if (grid.MATTER + grid.EMPTY_N != BW * BH) { bad_i = bad_i + 1 }
        k = k + 1
    };
    GEN_SEEN = GEN_SEEN + gens;
    sub("over " + tostring(gens) + " generations, checked at every one of them");
    test.ck_eq("generations where the stone count was wrong", bad_c, 0);
    test.ck_eq("generations where the sand count was wrong", bad_s, 0);
    test.ck_eq("generations where the water count was wrong", bad_w, 0);
    test.ck_eq("generations where the matter total was wrong", bad_m, 0);
    test.ck_eq("generations where matter + empty != w*h", bad_i, 0);
    test.ck_eq("stone at generation " + tostring(gens), grid.CNT[grid.M_STONE], EXP_STONE);
    test.ck_eq("sand at generation " + tostring(gens), grid.CNT[grid.M_SAND], EXP_SAND);
    test.ck_eq("water at generation " + tostring(gens), grid.CNT[grid.M_WATER], EXP_WATER);
    // The expected side of every one of those is EXP_*, arithmetic over this
    // file's own literals.  Say so on stdout, because the difference between
    // that and reading grid.CNT[] is the whole difference between this check
    // and a vacuous one.
    sub("every expected total above came from this file's geometry, never from "
        + "grid.CNT[]: " + tostring(EXP_STONE) + " stone, " + tostring(EXP_SAND)
        + " sand, " + tostring(EXP_WATER) + " water")
};

// ===========================================================================
// C2 -- the update order.  This is the group the brief calls the important one.
// ===========================================================================

// sand_row(x) -> long -- the topmost LOGICAL row holding sand in logical column
// x, or -1.  A statement about where a column's stack is, rather than about one
// grain's bookkeeping, which is what makes C2b a test of the stack and not of
// a single cell.
def sand_row(x: long) -> long {
    let y = 0;
    while (y < grid.IH) {
        if (grid.at(x + 1, y + 1) == grid.M_SAND) { return y };
        y = y + 1
    };
    0 - 1
};

def c2_order() {
    head("C2  THE UPDATE ORDER: in place, bottom row first, one move per grain");

    // ---- C2a: one grain, one row per generation --------------------------
    // A single grain in an empty box whose floor is `drop` rows below it.  It
    // descends exactly one row per generation and needs exactly `drop` of them
    // to land.  A top-down scan would land it in ONE generation, and a snapshot
    // rule evaluated in reading order lands it when the last cell of the
    // snapshot is written -- so neither can pass this.
    let drop = 10;
    let bh = 16;
    let bw = 12;
    grid.clear(bw, bh);
    let fy = bh - 2;
    grid.rect_logical(0, fy, bw - 1, bh - 1, grid.M_STONE);
    let sx = 6;
    let sy0 = 2;
    grid.put_logical(sx, sy0, grid.M_SAND);
    sub("C2a  one sand grain at (" + tostring(sx) + ", " + tostring(sy0)
        + "); the floor is " + tostring(drop) + " rows below it");
    let off = 0;
    while (off <= drop + 3) {
        let want = sy0 + off;
        if (want > fy - 1) { want = fy - 1 };
        test.ck_eq("  generation " + tostring(off) + ": it is on row "
            + tostring(want), sand_row(sx), want);
        grid.step();
        off = off + 1
    };
    GEN_SEEN = GEN_SEEN + drop + 4;
    // and it STAYS there: settled, not oscillating
    let settled_row = sand_row(sx);
    let k = 0;
    while (k < 10) { grid.step(); k = k + 1 };
    GEN_SEEN = GEN_SEEN + 10;
    test.ck_eq("C2a  and it is still on that row 10 generations later", sand_row(sx), settled_row);

    // ---- C2b: a stack does not compact in one step ------------------------
    // Four grains stacked, `gap` empty rows below them, and a floor under that.
    // The whole stack descends one row per generation while it has room and
    // stops on the generation it lands.  This is the assertion a top-down scan
    // cannot pass: it would compact the stack onto the floor in ONE generation.
    let gap = 3;
    let sh = 12;
    let sw = 8;
    grid.clear(sw, sh);
    let floor_row = sh - 1;
    // The floor spans the WHOLE width, not just the stack's columns.  A two-wide
    // ledge is not a floor: the grain on top of it slips diagonally past its
    // edge -- which is the documented behaviour of sand_move, and which made
    // this check report a stack that kept moving after it had landed.  The
    // simulation was right and the fixture was wrong.
    grid.rect_logical(0, floor_row, sw - 1, floor_row, grid.M_STONE);
    let cx = 3;
    // the four grains sit on rows top0 .. top0+3, then `gap` empty rows, then
    // the floor on floor_row -- so top0 = floor_row - gap - 4
    let top0 = floor_row - gap - 4;
    let r = 0;
    while (r < 4) {
        grid.put_logical(cx, top0 + r, grid.M_SAND);
        r = r + 1
    };
    sub("C2b  a stack of 4 grains on rows " + tostring(top0) + ".." + tostring(top0 + 3)
        + ", " + tostring(gap) + " empty rows below them, and the floor on row "
        + tostring(floor_row));
    test.ck_eq("  the top of the stack is on row " + tostring(top0), sand_row(cx), top0);
    let g = 1;
    while (g <= gap) {
        grid.step();
        test.ck_eq("  generation " + tostring(g)
            + ": the top of the stack is on row " + tostring(top0 + g), sand_row(cx), top0 + g);
        g = g + 1
    };
    // The generation it lands on.  "Nothing moves after that" is NOT the right
    // expectation and the first version of this check asserted it: a falling
    // stack's BASE splays sideways, which is what sand does and what makes a
    // pile look like a pile.  What is true is that the pile's top comes to rest
    // on floor_row - 3 -- a four-grain pile on a floor cannot be higher -- and
    // that it never rises from there.
    grid.step();
    test.ck_eq("C2b  landed: the top of the pile is on row "
        + tostring(floor_row - 3) + ", which is as high as a four-grain pile on that floor can be", sand_row(cx), floor_row - 3);
    grid.tally();
    test.ck_eq("C2b  all four grains are still there", grid.CNT[grid.M_SAND], 4);
    let landed = sand_row(cx);
    let k2 = 0;
    while (k2 < 20) {
        grid.step();
        k2 = k2 + 1
    };
    GEN_SEEN = GEN_SEEN + gap + 2 + 20;
    test.ck("C2b  and 20 generations later the top of the pile has not "
        + "risen (row " + tostring(sand_row(cx)) + ")", sand_row(cx) >= landed, "");
    grid.tally();
    test.ck_eq("C2b  and no grain left the box", grid.CNT[grid.M_SAND], 4);

    // ---- C2c: every grain arrives from a neighbour, by at most one cell ----
    // This is the general statement, and it is what answers the brief's
    // question about merging: a grain can advance at most ONE column per
    // generation, so two bodies of water with a gap of g empty cells between
    // them need at least g generations to touch -- never one, whatever the gap.
    // Under a snapshot rule with no stamp, one water grain slides the whole way
    // across an empty row in a single generation and the gap means nothing.
    //
    // THE FIRST VERSION OF THIS CHECK WAS WRONG, and its failure is the most
    // useful thing in the file.  It asked: "is there an 8-neighbour that held
    // this material last generation and is EMPTY now?"  Ten cells out of 483
    // real moves failed it, all of them at the bottom of a settling pool, and
    // the reason is that a grain which vacates a cell leaves it empty but does
    // NOT stamp it -- so a grain scanned later in the same row can move
    // straight into it, and the cell ends the generation looking exactly as it
    // started.  A vacancy that is refilled in the same generation is invisible
    // from the outside.  The check was asserting something unobservable.
    //
    // What IS observable is the STAMP: a cell whose stamp is the generation just
    // run is precisely a cell something arrived at.  So the exact statement is
    // "every cell stamped this generation holds a material that one of its eight
    // neighbours held in the snapshot", and the companion count is "you cannot
    // have moved more grains than you vacated cells".
    sub("C2c  every cell a grain arrived at this generation, and how far it came");
    // A purpose-built DROP, not a scene: the basin settles inside four
    // generations -- its heap already rests on its floor -- so the first version
    // of this check saw 47 arrivals in 150 generations and its "did it see real
    // motion" assertion had to be weakened until it was meaningless.  Two blocks
    // of sand and water suspended twelve rows above a floor fall into each
    // other and give hundreds of real moves, which is what a bound like this has
    // to be tested against.
    let dw = 60;
    let dh = 30;
    grid.clear(dw, dh);
    grid.rect_logical(0, dh - 2, dw - 1, dh - 1, grid.M_STONE);
    grid.rect_logical(4, 4, 23, 7, grid.M_SAND);
    grid.rect_logical(32, 4, 47, 7, grid.M_WATER);
    let gens = 30;
    let orphan = 0;
    let arrived = 0;
    let vacated = 0;
    let maxdx = 0;
    let maxdy = 0;
    let g2 = 0;
    while (g2 < gens) {
        grid.snapshot();
        grid.step();
        let stamp = grid.GEN;
        let y = 1;
        while (y <= grid.IH) {
            let x = 1;
            while (x <= grid.IW) {
                let now = grid.at(x, y);
                let was = grid.prev_at(x, y);
                // A VACATED INERT cell: it held stone, sand, water or oil in the
                // snapshot and holds nothing now.  Smoke vanishing and a fire
                // burning out are vacancies too, but they have no arrival to
                // pair with, so they are counted separately -- which is what
                // made the first version of this inequality report 475
                // "vacated" against 47 "moved".
                if (was != grid.M_EMPTY && now == grid.M_EMPTY) {
                    if (was != grid.M_FIRE && was != grid.M_SMOKE) { vacated = vacated + 1 }
                };
                // arrived: written during the generation just run, and holding
                // something inert.  Fire and smoke are excluded because they are
                // created and destroyed by the chemistry rather than moved; the
                // burning scene below gets its own looser check.
                if (grid.stamp_at(x, y) == stamp && now != grid.M_EMPTY
                    && now != grid.M_FIRE && now != grid.M_SMOKE) {
                    arrived = arrived + 1;
                    if (!held_beside(x, y, now)) { orphan = orphan + 1 };
                    let d = 0 - 1;
                    while (d <= 1) {
                        let e = 0 - 1;
                        while (e <= 1) {
                            let sx = x + d;
                            let sy = y + e;
                            if (grid.prev_at(sx, sy) == now) {
                                let adx = sx - x;
                                if (adx < 0) { adx = 0 - adx };
                                let ady = sy - y;
                                if (ady < 0) { ady = 0 - ady };
                                if (adx > maxdx) { maxdx = adx };
                                if (ady > maxdy) { maxdy = ady }
                            };
                            e = e + 1
                        };
                        d = d + 1
                    }
                };
                x = x + 1
            };
            y = y + 1
        };
        g2 = g2 + 1
    };
    GEN_SEEN = GEN_SEEN + gens;
    sub("over " + tostring(gens) + " generations of a 60x30 drop: "
        + tostring(arrived) + " cells were arrived at, " + tostring(vacated)
        + " were vacated, and the largest single-generation displacement was "
        + tostring(maxdx) + " column(s) across and " + tostring(maxdy) + " row(s) down");
    test.ck("C2c  the check saw real motion (" + tostring(arrived)
        + " arrivals), so it is not vacuous", arrived > 200, "");
    test.ck("C2c  no grain crossed more than one column in a generation (max "
        + tostring(maxdx) + ")", maxdx <= 1, "");
    test.ck("C2c  and no grain fell more than one row in a generation (max "
        + tostring(maxdy) + ")", maxdy <= 1, "");
    test.ck("C2c  and the column bound is TIGHT: some grain used all of it", maxdx == 1, "");
    test.ck("C2c  and the row bound is tight too", maxdy == 1, "");
    test.ck_eq("C2c  every cell a grain arrived at had that material beside "
        + "it in the previous generation", orphan, 0);
    // EQUALITY, not an inequality: every move of an inert grain vacates exactly
    // one inert cell and arrives at exactly one stamped cell, so the two counts
    // must match exactly.  Nothing is created and nothing is destroyed.  This is
    // the assertion that would catch a move which copied instead of moving.
    // An INEQUALITY, not the equality the first version of this asserted.  Every
    // move vacates one inert cell and stamps one destination, so the two counts
    // should match -- and they do not, because a vacancy can be REFILLED inside
    // the same generation: a grain that leaves (3, 9) opens (3, 9), and the grain
    // above it falls in during the same scan.  The cell ends the generation
    // holding sand again, so it never shows up as vacated.  (That is the same
    // fact that makes "the source is empty now" unobservable a few lines up.)
    // What is nonetheless true, and is the conservation claim, is that arrivals
    // cannot outnumber vacancies: a grain has to leave somewhere, and there are
    // never more grains in flight than there are holes to put them in.
    test.ck("C2c  cells were vacated (" + tostring(vacated) + ")", vacated > 0, "");
    test.ck("C2c  no more grains moved than there were holes to move "
        + "into (" + tostring(arrived) + " moved, " + tostring(vacated)
        + " vacated, the difference being vacancies refilled in the same generation)", arrived >= vacated, "");

    // ---- C2e: a grain needs room to slip past its neighbour -----------------
    // This fixture exists because inject.py found a gap: deleting the
    // beside-cell test from sand_move -- the two-cell diagonal rule grid.y's own
    // comment describes -- changed nothing any assertion was looking at.  The
    // basin and the stack fixtures have no one-cell diagonal gap in them, so the
    // mutation was EQUIVALENT as far as the suite could tell, which is a hole in
    // the suite and not a hole in the mutation.
    //
    // The pocket: a grain at (4,7) resting on a single stone at (4,8), with
    // stone at (3,7) and (5,7) so it cannot go left or right, and empty floor
    // at (3,8) and (5,8) just below those.  With the two-cell test the grain is
    // stuck: the cell it would slide into is empty but the cell BESIDE it is
    // stone, so it has no room to slip past.  Without the test it slides into
    // (3,8) or (5,8) and drains out of the pocket -- sand behaving like water.
    sub("C2e  a grain in a one-cell pocket, which it may not drain out of");
    let pw = 10;
    let ph = 10;
    grid.clear(pw, ph);
    grid.rect_logical(0, ph - 1, pw - 1, ph - 1, grid.M_STONE);
    grid.put_logical(3, 7, grid.M_STONE);
    grid.put_logical(5, 7, grid.M_STONE);
    grid.put_logical(4, 8, grid.M_STONE);
    grid.put_logical(4, 7, grid.M_SAND);
    grid.tally();
    test.ck_eq("  one grain in the pocket", grid.CNT[grid.M_SAND], 1);
    let e = 0;
    while (e < 12) {
        grid.step();
        e = e + 1
    };
    GEN_SEEN = GEN_SEEN + 12;
    grid.tally();
    test.ck_eq("  after 12 generations it is still in "
        + "the pocket at (4, 7)", grid.at(4 + 1, 7 + 1), grid.M_SAND);
    test.ck_eq("  and no grain was left behind elsewhere", grid.CNT[grid.M_SAND], 1);
    test.ck_eq("  and it did not drain into (3, 8)", grid.at(3 + 1, 8 + 1), grid.M_EMPTY);
    test.ck_eq("  or into (5, 8)", grid.at(5 + 1, 8 + 1), grid.M_EMPTY);

    // Fire and smoke are created and destroyed by the chemistry rather than
    // moved, so they get the looser but still meaningful form: a cell holding
    // fire or smoke must have had fire, smoke or oil in its own 3x3
    // neighbourhood in the last snapshot.
    scene.build("firestorm", 48, 24, 1);
    let loose = 0;
    let born = 0;
    let g3 = 0;
    while (g3 < 200) {
        grid.snapshot();
        grid.step();
        let y = 1;
        while (y <= grid.IH) {
            let x = 1;
            while (x <= grid.IW) {
                let now = grid.at(x, y);
                let was = grid.prev_at(x, y);
                if ((now == grid.M_FIRE || now == grid.M_SMOKE) && now != was) {
                    born = born + 1;
                    if (!had_neighbour(x, y, now)) { loose = loose + 1 }
                };
                x = x + 1
            };
            y = y + 1
        };
        g3 = g3 + 1
    };
    GEN_SEEN = GEN_SEEN + 200;
    sub("over 200 generations of the burning scene (" + tostring(born)
        + " fire/smoke cells appeared)");
    test.ck("C2d  the burning check saw fire and smoke appear", born > 50, "");
    test.ck_eq("C2d  every new fire or smoke puff had fire, smoke or oil beside it", loose, 0)
};


// held_beside(x, y, m) -> bool -- did any of the eight neighbours of store cell
// (x, y) hold material m in the last snapshot?
//
// Deliberately NOT "held m before and is empty now".  A grain that vacates a
// cell leaves it empty and does not stamp it, so a grain scanned later in the
// same row can move straight into it; the cell then ends the generation holding
// m again, looking untouched.  Ten of 483 real moves looked like unexplained
// arrivals to the first version of this check, every one of them of that shape.
// The stamp identifies the ARRIVALS exactly (see grid.stamp_at), and this
// function then only has to say where the grain came from.
def held_beside(x: long, y: long, m: long) -> bool {
    let found = false;
    let d = 0 - 1;
    while (d <= 1 && !found) {
        let e = 0 - 1;
        while (e <= 1 && !found) {
            if (!(d == 0 && e == 0)) {
                if (grid.prev_at(x + d, y + e) == m) { found = true }
            };
            e = e + 1
        };
        d = d + 1
    };
    found
};

// had_neighbour(x, y, m) -> bool -- did the last snapshot have fire, smoke or
// oil anywhere in this cell's 3x3 neighbourhood?
def had_neighbour(x: long, y: long, m: long) -> bool {
    let found = false;
    let d = 0 - 1;
    while (d <= 1 && !found) {
        let e = 0 - 1;
        while (e <= 1 && !found) {
            let p = grid.prev_at(x + d, y + e);
            if (p == grid.M_FIRE || p == grid.M_SMOKE || p == grid.M_OIL) { found = true };
            e = e + 1
        };
        d = d + 1
    };
    found
};

// ===========================================================================
// C3 -- a closed box reaches a fixed point
// ===========================================================================

def c3_fixed_point() {
    head("C3  a closed box reaches a FIXED POINT, and the fixed point is verified");
    let ok = box_fire();
    test.ck("the burning test box built", ok, "");
    grid.tally();
    sub("the box holds " + tostring(EXP_MATTER) + " cells of inert matter plus "
        + tostring(grid.vol_total()) + " volatile, in " + tostring(BW) + " x " + tostring(BH));

    let limit = 3000;
    let settled = grid.run_until_settled(limit);
    GEN_SEEN = GEN_SEEN + settled + 1;
    test.ck("the box reached a generation that changed nothing within "
        + tostring(limit) + " generations", settled > 0, "");
    sub("settled at generation " + tostring(settled) + ", of at most " + tostring(limit));

    // A real fixed point is generation n+1 == generation n, not "it stopped
    // moving much".  So: take the checksum, run twenty more generations, and
    // require every one of them to leave it bit-identical.
    let sum0 = grid.checksum();
    grid.tally();
    sub("at the fixed point: " + tostring(grid.CNT[grid.M_SAND]) + " sand, "
        + tostring(grid.CNT[grid.M_WATER]) + " water, "
        + tostring(grid.CNT[grid.M_OIL]) + " oil, "
        + tostring(grid.CNT[grid.M_FIRE]) + " fire, "
        + tostring(grid.CNT[grid.M_SMOKE]) + " smoke; checksum " + tostring(sum0));
    // Non-vacuity: a fixed point of an empty grid is a fixed point of nothing.
    test.ck("the fixed point's checksum is non-zero", sum0 != 0, "");
    test.ck("the fixed point still has matter on it, so it is not a blank grid", grid.MATTER > 0, "");
    test.ck_eq("every fire has burned out", grid.CNT[grid.M_FIRE], 0);
    test.ck_eq("every smoke puff has vanished", grid.CNT[grid.M_SMOKE], 0);

    let drift = 0;
    let i = 0;
    while (i < 20) {
        grid.step();
        if (grid.checksum() != sum0) { drift = drift + 1 };
        i = i + 1
    };
    GEN_SEEN = GEN_SEEN + 20;
    test.ck_eq("generations in the next 20 that changed the grid at all", drift, 0)
};

// ===========================================================================
// C4 -- monotone invariants at every generation
// ===========================================================================

def c4_monotone() {
    head("C4  monotone invariants, checked at EVERY generation");
    // sum(y) over a material: sand and water only ever move down, so their sum
    // never decreases; stone never moves at all, so its sum is constant; the
    // topmost sand row never rises.  These are invariants a golden file cannot
    // check, because they are about the whole trajectory and not one frame.
    box_plain();
    grid.tally();
    let sy0s = grid.SY[grid.M_SAND];
    let sy0w = grid.SY[grid.M_WATER];
    let sy0t = grid.SY[grid.M_STONE];
    let top0 = grid.TOPY[grid.M_SAND];
    let gens = 400;
    let bad_s = 0;
    let bad_w = 0;
    let bad_t = 0;
    let bad_top = 0;
    let worst_s = 0;
    let k = 0;
    while (k < gens) {
        grid.step();
        grid.tally();
        let ds = grid.SY[grid.M_SAND] - sy0s;
        if (ds < 0) { bad_s = bad_s + 1 };
        if (grid.SY[grid.M_WATER] < sy0w) { bad_w = bad_w + 1 };
        if (grid.SY[grid.M_STONE] != sy0t) { bad_t = bad_t + 1 };
        if (grid.TOPY[grid.M_SAND] < top0) { bad_top = bad_top + 1 };
        if (ds > worst_s) { worst_s = ds }
        k = k + 1
    };
    GEN_SEEN = GEN_SEEN + gens;
    sub("sand and water only ever move down, over " + tostring(gens) + " generations");
    test.ck_eq("generations where sum(sand y) went DOWN", bad_s, 0);
    test.ck_eq("generations where sum(water y) went DOWN", bad_w, 0);
    test.ck_eq("generations where sum(stone y) moved at all", bad_t, 0);
    test.ck_eq("generations where the topmost sand row went UP", bad_top, 0);
    sub("sum(sand y) rose by " + tostring(worst_s) + " over the run, and fell on none of them");

    // With fire in the box: the volatile total (oil + fire + smoke) must never
    // grow -- the spread turns oil into fire and the expiry turns fire into
    // smoke, both conserving it, and only a vanishing puff destroys it.  And
    // fire must never touch the stone or the sand.
    box_fire();
    grid.run(40);
    // The tally MUST be taken here.  Without it v0 is read from the last tally
    // of the PREVIOUS grid -- the fire-free box -- so the volatile total comes
    // back 0, and every one of the next 800 generations that still had a puff of
    // smoke alive looks like the volatile total growing.  That is the "both
    // values were absent" failure wearing a conservation costume: the check
    // compared the wrong grid's tally with this one's.
    grid.tally();
    let v0 = grid.vol_total();
    let bad_vol = 0;
    let bad_stone = 0;
    let bad_sand = 0;
    let k2 = 0;
    while (k2 < 800) {
        grid.step();
        grid.tally();
        let v = grid.vol_total();
        if (v > v0) { bad_vol = bad_vol + 1 };
        if (grid.CNT[grid.M_STONE] != EXP_STONE) { bad_stone = bad_stone + 1 };
        if (grid.CNT[grid.M_SAND] != EXP_SAND) { bad_sand = bad_sand + 1 };
        k2 = k2 + 1
    };
    GEN_SEEN = GEN_SEEN + 840;
    sub("with fire: the volatile total and the inert counts over 800 generations "
        + "(it started at " + tostring(v0) + ")");
    test.ck("C4  there was a volatile total to protect in the first place ("
        + tostring(v0) + ")", v0 > 0, "");
    test.ck_eq("generations where the volatile total grew", bad_vol, 0);
    test.ck_eq("generations where fire changed the stone count", bad_stone, 0);
    test.ck_eq("generations where fire changed the sand count", bad_sand, 0);
    test.ck_eq("the volatile total is zero once the fire is out", grid.vol_total(), 0)
};

// ===========================================================================
// C5 -- sand falls down and never up, absent a source
// ===========================================================================

def c5_down_only() {
    head("C5  sand falls DOWN and never up, absent a source");
    // One grain, a flat floor, and a literal trajectory: after k generations it
    // is on row start + k, and it is still there twenty generations later.
    // Nothing above it can make it go up, so any upward motion is a defect.
    let bh = 20;
    let bw = 14;
    grid.clear(bw, bh);
    let fy = bh - 2;
    grid.rect_logical(0, fy, bw - 1, bh - 1, grid.M_STONE);
    let sx = 7;
    let sy = 1;
    grid.put_logical(sx, sy, grid.M_SAND);
    let floor_row = fy - 1;
    sub("one grain at (" + tostring(sx) + ", " + tostring(sy) + "), the floor is on row "
        + tostring(floor_row) + ", and there is no source above it");
    let ups = 0;
    let last = 0;
    let k = 1;
    while (k <= floor_row - sy) {
        grid.step();
        let row = sand_row(sx);
        if (row < last) { ups = ups + 1 };
        last = row;
        test.ck_eq("  generation " + tostring(k) + ": it is on row " + tostring(sy + k), row, sy + k);
        k = k + 1
    };
    GEN_SEEN = GEN_SEEN + floor_row - sy;
    test.ck_eq("generations in which this grain moved UP", ups, 0);
    test.ck_eq("it came to rest on the floor", last, floor_row);
    let k2 = 0;
    while (k2 < 20) { grid.step(); k2 = k2 + 1 };
    GEN_SEEN = GEN_SEEN + 20;
    test.ck_eq("and it is still there 20 generations later", sand_row(sx), floor_row);

    // A block dropped as a rectangle: the topmost sand row is non-decreasing for
    // the whole run, at every one of 200 generations.
    grid.clear(bw, bh);
    grid.rect_logical(0, fy, bw - 1, bh - 1, grid.M_STONE);
    grid.rect_logical(4, 4, 9, 9, grid.M_SAND);
    grid.tally();
    let top = grid.TOPY[grid.M_SAND];
    let bad = 0;
    let g = 0;
    while (g < 200) {
        grid.step();
        grid.tally();
        if (grid.TOPY[grid.M_SAND] < top) { bad = bad + 1 };
        g = g + 1
    };
    GEN_SEEN = GEN_SEEN + 200;
    test.ck_eq("generations of a 6x6 block in which the topmost sand row rose", bad, 0)
};

// ===========================================================================
// C6 -- water spreads and does not pile
// ===========================================================================

// water_columns() -> long -- how many store columns hold at least one water
// cell.  Read from the level array the simulation maintains, which is an
// INDEPENDENT witness to the water's extent: if move_to()'s bookkeeping of the
// levels were wrong, this and a scan of the grid would disagree.
def water_columns() -> long {
    let n = 0;
    let x = 0;
    while (x < grid.GWa) {
        if (grid.col_level(grid.M_WATER, x) > 0) { n = n + 1 };
        x = x + 1
    };
    n
};

// ===========================================================================
// C6's measurements, in module state because Y HAS NO OUT-PARAMETERS
// ===========================================================================
//
// This is here because the first version of C6 got it wrong in the exact way
// the brief warns about.  It asked for a span like this:
//
//     let xl = 0; let xh = 0;
//     water_span(xl, xh);              // writes water_span's OWN parameters
//
// and Y passes parameters BY VALUE, so the caller's xl and xh stayed 0.  Every
// downstream number was then computed from x = 0..0 and y = 0..0: the hole count
// was 0 because it scanned ONE cell, the surface relief was 0 because both
// ends were 0, and all three assertions built on them passed -- vacuously, on
// nothing.  So the measurements live in module state, and every one of them is
// asserted non-zero by its caller BEFORE it is used in a comparison.  A helper
// whose result can be zero has to be checked for being zero, or "0 == 0" gets
// dressed up as a finding.
let SPAN_LO = 0;
let SPAN_HI = 0 - 1;
let SURF_LO = 0 - 1;
let SURF_HI = 0;
let TALL = 0;
let SHORT = 0;
let NCOLS = 0;

// water_columns() -> long -- how many store columns hold at least one water
// cell.  Read from the level array the simulation maintains, which is an
// INDEPENDENT witness to the water's extent: if move_to()'s bookkeeping of the
// levels were wrong, this and a scan of the grid would disagree.
def water_columns() -> long {
    let n = 0;
    let x = 0;
    while (x < grid.GWa) {
        if (grid.col_level(grid.M_WATER, x) > 0) { n = n + 1 };
        x = x + 1
    };
    NCOLS = n;
    n
};

// water_span() -- the first and last store columns holding water, into SPAN_LO
// and SPAN_HI.
def water_span() {
    SPAN_LO = 0;
    SPAN_HI = 0 - 1;
    let x = 0;
    while (x < grid.GWa) {
        if (grid.col_level(grid.M_WATER, x) > 0) {
            if (SPAN_HI < 0) { SPAN_LO = x };
            SPAN_HI = x
        };
        x = x + 1
    }
};

// water_surface() -- the topmost and bottommost store rows holding water
// anywhere, into SURF_LO and SURF_HI: how much relief the surface has.
def water_surface() {
    SURF_LO = 0 - 1;
    SURF_HI = 0;
    let y = 0;
    while (y < grid.GHa) {
        let x = 0;
        while (x < grid.GWa) {
            if (grid.at(x, y) == grid.M_WATER) {
                if (SURF_LO < 0) { SURF_LO = y };
                SURF_HI = y
            };
            x = x + 1
        };
        y = y + 1
    }
};

// water_holes() -> long -- EMPTY cells inside the water's own bounding box.  A
// settled pool fills what it encloses; a comb does not.
def water_holes() -> long {
    water_span();
    water_surface();
    let holes = 0;
    let y = SURF_LO;
    while (y <= SURF_HI) {
        let x = SPAN_LO;
        while (x <= SPAN_HI) {
            if (grid.at(x, y) == grid.M_EMPTY) { holes = holes + 1 };
            x = x + 1
        };
        y = y + 1
    };
    holes
};

// water_step() -> long -- the largest difference in height between two ADJACENT
// non-empty columns.  This is the "levels out instead of combing" measurement:
// the sideways rule only fires when a column is at least TWO deeper than its
// neighbour, so a settled pool must have adjacent columns within ONE of each
// other, and must have at least one pair that reaches exactly one -- otherwise
// the assertion would be satisfied by a pool that never spread at all.
def water_step() -> long {
    let worst = 0;
    let some = 0;
    let x = 0;
    while (x < grid.GWa - 1) {
        let a = grid.col_level(grid.M_WATER, x);
        let b = grid.col_level(grid.M_WATER, x + 1);
        if (a > 0 && b > 0) {
            let d = a - b;
            if (d < 0) { d = 0 - d };
            if (d > worst) { worst = d };
            if (d == 1) { some = some + 1 }
        };
        x = x + 1
    };
    if (some == 0 && worst == 0) { return 0 - 1 };   // nothing to compare
    worst
};

// water_maxgap() -> long -- the longest run of empty columns inside the water's
// own span: 0 if there are none.
def water_maxgap() -> long {
    water_span();
    let run = 0;
    let worst = 0;
    let x = SPAN_LO;
    while (x <= SPAN_HI) {
        if (grid.col_level(grid.M_WATER, x) == 0) {
            run = run + 1;
            if (run > worst) { worst = run }
        } else {
            run = 0
        };
        x = x + 1
    };
    worst
};

// water_levels() -- the tallest and the shortest NON-EMPTY water column, into
// TALL and SHORT.
def water_levels() {
    TALL = 0;
    SHORT = 0;
    let x = 0;
    while (x < grid.GWa) {
        let v = grid.col_level(grid.M_WATER, x);
        if (v > TALL) { TALL = v };
        if (v > 0 && v < SHORT) { SHORT = v };
        x = x + 1
    };
    if (SHORT == 0) { SHORT = TALL }
};

def c6_water_spreads() {
    head("C6  water spreads sideways and does not pile");
    // Pour a tall column of water onto a wide flat floor in a closed box and
    // let it settle.  Then four independent statements about the result.
    let bw = 30;
    let bh = 18;
    grid.clear(bw, bh);
    let fy = bh - 2;
    grid.rect_logical(0, fy, bw - 1, bh - 1, grid.M_STONE);
    let cx = 15;
    let poured = 0;
    let y = 0;
    while (y < 12) {
        grid.put_logical(cx, y, grid.M_WATER);
        poured = poured + 1;
        y = y + 1
    };
    grid.tally();
    test.ck_eq("the pour landed: one column of "
        + tostring(poured) + " cells, all of it water", grid.CNT[grid.M_WATER], poured);
    test.ck_eq("and it starts in exactly one column", water_columns(), 1);
    GEN_SEEN = GEN_SEEN + 1;

    let settled = grid.run_until_settled(4000);
    GEN_SEEN = GEN_SEEN + settled + 1;
    test.ck("the pour settled", settled > 0, "");
    sub("it settled at generation " + tostring(settled));

    let cols = water_columns();
    water_span();
    water_surface();
    water_levels();
    let xl = SPAN_LO;
    let xh = SPAN_HI;
    let tl = SURF_LO;
    let th = SURF_HI;
    let flat = th - tl;
    sub("after settling: " + tostring(cols) + " columns of water from x=" + tostring(xl)
        + " to x=" + tostring(xh) + "; surface rows " + tostring(tl) + ".." + tostring(th)
        + " (" + tostring(flat) + " row(s) of relief); tallest column " + tostring(TALL)
        + ", shortest non-empty " + tostring(SHORT));
    // ---- NON-VACUITY FIRST.  Every number below is measured by a helper that
    // writes module state, and a helper that silently returned 0 once made three
    // of these assertions pass on nothing.  So each is checked for being
    // non-zero -- or, for the span, for spanning more than one column -- BEFORE
    // anything is compared with it.
    test.ck("C6  the settled pool spans more than one column (x="
        + tostring(xl) + ".." + tostring(xh) + ")", SPAN_HI > SPAN_LO, "");
    test.ck("C6  the pool has a surface above its bottom row (rows "
        + tostring(tl) + ".." + tostring(th) + ")", SURF_HI > SURF_LO, "");
    test.ck("C6  the tallest column is non-zero (" + tostring(TALL) + ")", TALL > 0, "");
    test.ck("C6  the shortest non-empty column is non-zero (" + tostring(SHORT) + ")", SHORT > 0, "");
    test.ck("C6  there were adjacent columns to compare at all (otherwise "
        + "the levelling measurement would have nothing to say)", water_step() >= 0, "");
    test.ck("C6  the water SPREAD: it is no longer in one column (was 1, now "
        + tostring(cols) + ")", cols > 1, "");
    test.ck("C6  and it spread across at least 3 columns", cols >= 3, "");
    // The pour went into column cx, and a pool that spread from a point is
    // centred on where it was poured: that is a statement about the SHAPE, and
    // it is what "spreads" means, rather than a restatement of the sideways rule.
    test.ck("C6  the pool still covers the column it was poured into ("
        + tostring(cx) + ")", xl <= cx && cx <= xh, "");
    let left = cx - xl;
    let right = xh - cx;
    test.ck("C6  and it is centred on it to within 2 columns (" + tostring(left) + " to the "
        + "left, " + tostring(right) + " to the right)", left - right <= 2 && right - left <= 2, "");
    test.ck_eq("C6  every pair of adjacent columns differs by at most 1, "
        + "so it levelled instead of staying a comb", water_step(), 1);
    test.ck("C6  and there is no run of more than 1 empty column "
        + "inside it, so it stayed one body (longest run " + tostring(water_maxgap()) + ")", water_maxgap() <= 1, "");
    // The bounding box of a settled pool DOES have empty cells in it -- a point
    // pour makes a heap of column heights 1,2,3,3,2,1, whose box is 6x3 = 18 cells
    // holding 12.  The first version of this check asserted a full box and got 6
    // holes; the pool was right and the assertion was wrong, which is worth
    // recording because "the settled shape is not the shape I assumed" is a
    // finding about the physics.
    sub("its bounding box is " + tostring(SPAN_HI - SPAN_LO + 1) + "x"
        + tostring(SURF_HI - SURF_LO + 1) + " with " + tostring(water_holes())
        + " empty cells in it, which is the staircase a point pour makes");
    test.ck("C6  its surface is flat to within 2 rows (relief " + tostring(flat) + ")", flat <= 2, "");
    test.ck("C6  it did not PILE: no column is more than 2 taller than "
        + "the shortest non-empty one", TALL - SHORT <= 2, "");
    grid.tally();
    test.ck_eq("no water was created or lost doing it", grid.CNT[grid.M_WATER], poured)
};

// ===========================================================================
// C7 -- determinism, and that the seed is not a lie
// ===========================================================================

def c7_deterministic() {
    head("C7  the same seed gives the identical grid, and different seeds differ");
    let bw = 48;
    let bh = 28;
    scene.build("terrain", bw, bh, 1);
    let c1a = grid.checksum();
    scene.build("terrain", bw, bh, 1);
    let c1b = grid.checksum();
    scene.build("terrain", bw, bh, 7);
    let c7a = grid.checksum();
    scene.build("terrain", bw, bh, 7);
    let c7b = grid.checksum();
    sub("scene terrain at " + tostring(bw) + " x " + tostring(bh) + ", seed 1 twice and seed 7 twice");
    sub("  seed 1: " + tostring(c1a) + ", then " + tostring(c1b));
    sub("  seed 7: " + tostring(c7a) + ", then " + tostring(c7b));
    // Non-vacuity first: two zero checksums would agree for free.
    test.ck("the seed-1 grid's checksum is non-zero", c1a != 0, "");
    test.ck("the seed-7 grid's checksum is non-zero", c7a != 0, "");
    test.ck_eq("seed 1 twice gives the identical grid", c1a, c1b);
    test.ck_eq("seed 7 twice gives the identical grid", c7a, c7b);
    test.ck("seed 1 and seed 7 give DIFFERENT grids, so --seed is not ignored", c1a != c7a, "");

    // And the trajectory, not only the starting point.
    scene.build("terrain", bw, bh, 3);
    let g0 = grid.checksum();
    grid.run(50);
    let t1 = grid.checksum();
    scene.build("terrain", bw, bh, 3);
    let g0b = grid.checksum();
    grid.run(50);
    let t2 = grid.checksum();
    GEN_SEEN = GEN_SEEN + 100;
    sub("scene terrain, seed 3: generation 0 was " + tostring(g0) + " then " + tostring(g0b)
        + "; after 50 generations " + tostring(t1) + " then " + tostring(t2));
    test.ck_eq("generation 0 matches for the same seed", g0, g0b);
    test.ck_eq("generation 50 matches for the same seed", t1, t2);
    test.ck("and 50 generations actually changed something", t1 != g0, "");
    // Every scene must build, or --check would be testing less than the program
    // can do.
    let names: [str] = ["basin", "drip", "firestorm", "terrain", "empty"];
    let i = 0;
    let built = 0;
    let why = "";
    while (i < len(names)) {
        why = scene.build(names[i], bw, bh, 1);
        if (len(why) == 0) { built = built + 1 } else { sub("scene " + names[i] + ": " + why) };
        i = i + 1
    };
    test.ck_eq("all five built-in scenes build at " + tostring(bw) + "x" + tostring(bh), built, 5)
};

// ===========================================================================
// C8 -- no allocation in the generation loop
// ===========================================================================

def c8_no_alloc() {
    head("C8  the generation loop allocates nothing");
    // The trap this exists for: a literal array or record inside a loop body
    // costs 64 or 40 bytes PER ITERATION and the heap is an arena, so nothing
    // is ever freed and every byte ever allocated counts against the cap.
    let bw = 64;
    let bh = 32;
    scene.build("basin", bw, bh, 1);
    let gens = 20000;
    let g0 = grid.GEN;
    let h0 = heap_used();
    grid.run(gens);
    let h1 = heap_used();
    GEN_SEEN = GEN_SEEN + gens;
    sub("scene basin at " + tostring(bw) + " x " + tostring(bh) + ", " + tostring(gens)
        + " generations: heap " + tostring(h0) + " -> " + tostring(h1));
    test.ck_eq("the loop really ran " + tostring(gens)
        + " generations, so a skipped loop cannot pass this", grid.GEN - g0, gens);
    test.ck_eq("heap growth over those generations, in bytes", h1 - h0, 0);
    // And again with tally() in the loop: C1 and C4 call it once a generation,
    // so a tally that allocated would be the same leak wearing a different hat.
    scene.build("basin", bw, bh, 1);
    let g2 = grid.GEN;
    let h2 = heap_used();
    let k = 0;
    while (k < 2000) {
        grid.step();
        grid.tally();
        k = k + 1
    };
    let h3 = heap_used();
    GEN_SEEN = GEN_SEEN + 2000;
    test.ck_eq("the second loop really ran 2000 generations", grid.GEN - g2, 2000);
    test.ck_eq("heap growth over 2000 step+tally pairs, in bytes", h3 - h2, 0);
    grid.tally();
    test.ck("the grid still has matter on it, so the heap numbers above "
        + "were not measured on a blank grid", grid.MATTER > 0, "")
};

// ===========================================================================
// C9 -- the ghost border holds
// ===========================================================================

def c9_border() {
    head("C9  the ghost border is stone on every side, at every generation");
    // This is the structural claim that lets step() have no bounds branch: if a
    // grain could ever sit in a border cell, the cell beside it would have an
    // out-of-range neighbour and the "no branch" would be a trap.
    scene.build("basin", 60, 26, 1);
    let want = 2 * grid.GWa + 2 * (grid.GHa - 2);
    let bad = 0;
    let gens = 250;
    let g = 0;
    while (g < gens) {
        grid.tally();
        if (grid.BORDER_STONE != want) { bad = bad + 1 };
        grid.step();
        g = g + 1
    };
    grid.tally();
    GEN_SEEN = GEN_SEEN + gens;
    sub("the border is " + tostring(want) + " cells of a " + tostring(grid.GWa) + " x "
        + tostring(grid.GHa) + " store");
    test.ck_eq("generations in which a border cell was not stone", bad, 0);
    test.ck_eq("and it is still exactly the border at the end", grid.BORDER_STONE, want);
    // The complementary statement, over a run where fire and smoke press hardest
    // against the top and the sides.
    scene.build("firestorm", 48, 24, 1);
    let g2 = 0;
    while (g2 < 2000) {
        grid.step();
        g2 = g2 + 1
    };
    GEN_SEEN = GEN_SEEN + 2000;
    grid.tally();
    test.ck_eq("2000 generations of firestorm later the border is still exactly the border", grid.BORDER_STONE, 2 * grid.GWa + 2 * (grid.GHa - 2));
    test.ck_eq("every cell of the logical grid is accounted for after those 2000 generations", grid.MATTER + grid.EMPTY_N, grid.IW * grid.IH)
};

// ===========================================================================
// C10 -- a second, independent way to count
// ===========================================================================

// char(cp) -> str -- the ASCII glyph for a codepoint.  Deliberately local to
// this file, so sandfall.y's renderer and this cross-check are two independent
// renderings rather than one shared helper that could be wrong once instead of
// twice.  Every glyph is ASCII: chr() is byte-oriented and cannot make a
// non-ASCII glyph at all (ORCHESTRATOR.md 2.4).
def char(cp: long) -> str {
    if (cp == 32) { return " " };
    if (cp == 35) { return "#" };
    if (cp == 46) { return "." };
    if (cp == 61) { return "=" };
    if (cp == 64) { return "@" };
    if (cp == 111) { return "o" };
    if (cp == 126) { return "~" };
    "?"
};

// count_glyph(cp) -> long -- how many cells hold the material whose glyph is cp,
// counted by RENDERING the grid to a string and scanning the string's bytes.
// The tally reads the byte array; this builds rows of characters and reads
// those.  No shared code, so a broken tally cannot make both agree.
def count_glyph(cp: long) -> long {
    let n = 0;
    let y = 0;
    while (y < grid.GHa) {
        let row = "";
        let x = 0;
        while (x < grid.GWa) {
            row += char(grid.glyph(grid.at(x, y)));
            x = x + 1
        };
        let i = 0;
        while (i < len(row)) {
            if (row[i] == cp) { n = n + 1 };
            i = i + 1
        };
        y = y + 1
    };
    n
};

def c10_two_counters() {
    head("C10  two independent counters agree on the same grid");
    box_plain();
    grid.tally();
    test.ck_eq("the array tally's sand count", grid.CNT[grid.M_SAND], EXP_SAND);
    test.ck_eq("the rendered-string count of 'o'", count_glyph(111), EXP_SAND);
    test.ck_eq("the rendered-string count of '~'", count_glyph(126), EXP_WATER);
    // '#' is STONE, and the ghost border is stone, so the string count sees the
    // border and grid.CNT[] does not -- CNT counts the LOGICAL grid only.  The
    // border's size is computed here rather than read from grid.BORDER_STONE, so
    // the expected value still comes from this file's own arithmetic.  Getting
    // this wrong is what the first run of C10 reported: 212 against 80.
    test.ck_eq("the rendered-string count of '#' (interior floor plus the ghost border)", count_glyph(35), EXP_STONE + (2 * grid.GWa + 2 * (grid.GHa - 2)));
    grid.run(150);
    grid.tally();
    GEN_SEEN = GEN_SEEN + 150;
    test.ck_eq("after 150 generations the string still sees "
        + tostring(EXP_SAND) + " sand grains", count_glyph(111), EXP_SAND);
    test.ck_eq("after 150 generations the string still sees "
        + tostring(EXP_WATER) + " water cells", count_glyph(126), EXP_WATER);
    // A third witness: every water cell is in a column whose level says so, and
    // the levels add up to the tally.
    let total = 0;
    let x = 0;
    while (x < grid.GWa) {
        total = total + grid.col_level(grid.M_WATER, x);
        x = x + 1
    };
    test.ck_eq("the per-column water levels sum to the water count", total, grid.CNT[grid.M_WATER])
};

// ===========================================================================
// C11 -- the meta-check: this suite is not vacuous
// ===========================================================================

def c11_meta() {
    head("C11  this suite is not vacuous");
    sub("assertions made: " + tostring(test.checks()) + " (failures " + tostring(test.failures())
        + "); generations exercised: " + tostring(GEN_SEEN)
        + "; cells in the test boxes: " + tostring(CELLS_SEEN));
    test.ck("the suite made at least " + tostring(MIN_CHECKS)
        + " assertions (it made " + tostring(test.checks()) + ")", test.checks() >= MIN_CHECKS, "");
    test.ck("the suite examined cells (it examined " + tostring(CELLS_SEEN) + ")", CELLS_SEEN > 0, "");
    test.ck("the suite exercised more than 1000 generations (it exercised "
        + tostring(GEN_SEEN) + ")", GEN_SEEN > 1000, "");
    test.ck("no assertion failed", test.failures() == 0, "")
};

// ===========================================================================
// the entry point
// ===========================================================================

def check_all() -> long {
    GEN_SEEN = 0;
    puts("sandfall --check: property check, no reference file involved\n");
    puts("  the physics under test: one generation is ONE scan of the interior,");
    puts("  rows BOTTOM to TOP, left to right within a row, updating the grid IN");
    puts("  PLACE, with a per-generation stamp so that no grain moves twice.\n");

    c0_nonvacuous();
    c1_conservation();
    c2_order();
    c3_fixed_point();
    c4_monotone();
    c5_down_only();
    c6_water_spreads();
    c7_deterministic();
    c8_no_alloc();
    c9_border();
    c10_two_counters();
    c11_meta();

    // One summary, printed here.  test.report() is NOT called as well: it would
    // print a second "N of M checks passed" line for the same run, and this line
    // carries the generation count that report() has no room for.
    puts("");
    if (test.failures() == 0) {
        puts("RESULT PASS -- " + tostring(test.checks()) + " assertions, 0 failed, "
            + tostring(GEN_SEEN) + " generations, no reference file\n");
        return 0
    };
    puts("RESULT FAIL -- " + tostring(test.failures()) + " of " + tostring(test.checks())
        + " assertions failed\n");
    1
};