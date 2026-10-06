// check.y -- the property battery for the x11 example (gate item 8).
//
// WHAT MAKES A BATTERY HERE WORTH ANYTHING.  Every figure below is either
//
//   (a) a CLOSED FORM derived from the definition of the primitive -- the
//       pixel count of a Bresenham line is max(|dx|,|dy|)+1 because the major
//       axis advances on every step; a filled rectangle is w*h; a one-pixel
//       frame is 2(w+h)-4; a checkerboard lights (cx+cy)-even cells and that
//       count is a closed form of the grid; a disc's column at offset dx is
//       2*isqrt(r*r-dx*dx)+1 pixels, which is an exact statement about
//       integers, not an approximation of a circle;
//
//   (b) a CONSTANT FIXED HERE AND COMPUTED OUTSIDE THIS PROGRAM -- see
//       FNV_ZEROS below, which was produced by a separate Python script, so
//       it is evidence rather than an echo; or
//
//   (c) a figure read back OUT OF THE FINISHED IMAGE by scanning pixels, which
//       is not the same thing as the number the drawing routine returned.
//
// What the battery deliberately never does is ask the routine that drew the
// image whether it drew correctly.  `scene_draw` returns five counts; those
// five counts are compared against (a), and then the pixels they claim to have
// written are counted independently out of the framebuffer by colour.
//
// NO REFERENCE FILE IS INVOLVED, and no display is touched: this must pass on a
// machine with no X server at all, in seconds.

import gfx;
import scene;
import test;

// This battery used to define its own `ck` and `ck_eq` here, with the counters
// `checks`/`failed` beside them and its own "N of M checks passed" line.  Both
// are std/test.y's now.  Nothing observable moved: the local `ck` already
// printed "  ok    "/"  FAIL  " plus the detail line and the summary already read
// "N of M checks passed", which is exactly std/test.y's wording -- and exactly
// what ../inject-defects.py greps for (`^  FAIL  (\S+)` and
// `(\d+) of (\d+) checks passed`), so the injected-defect table in README.md is
// still a measurement of the same thing.  Every assertion NAME below is
// unchanged, so the labels that table cites (C01, D05, H07, ...) still mean the
// same assertions.

// ─────────────────────────────────────────────────────────────── group A --
//
// The layout table is self-consistent, before anything is drawn.  If the scene
// were laid out so that two elements overlapped, every later count would be
// measuring a blend rather than an element, so the battery proves the layout
// first and only then measures against it.

def check_layout() {
    test.group("A layout: the table is self-consistent and nothing overlaps");

    test.ck_eq("A01 frame size is 320x240",
          scene.W * scene.H, 76800);

    // Every element's bounding box must lie inside the frame.  A box that
    // escapes would be silently clamped by the primitives, and the count would
    // then describe a smaller shape than the table claims -- which is exactly
    // the sort of drift a battery exists to catch.
    let inside = scene.PL_X1 < scene.W && scene.FR_X1 < scene.W
        && scene.CHK_X0 + scene.CHK_W - 1 < scene.W
        && scene.FR_Y1 < scene.H && scene.CHK_Y0 + scene.CHK_H - 1 < scene.H
        && scene.DY + scene.DR < scene.H && scene.DX - scene.DX >= 0;
    test.ck("A02 every element box lies inside the frame", inside,
       "plate x1=" + tostring(scene.PL_X1) + " frame x1=" + tostring(scene.FR_X1)
       + " checker x1=" + tostring(scene.CHK_X0 + scene.CHK_W - 1)
       + " disc bottom=" + tostring(scene.DY + scene.DR)
       + " against " + tostring(scene.W) + "x" + tostring(scene.H));

    // Non-overlap, pairwise, on inclusive bounding boxes.  The line is upper
    // left, the disc lower left, and everything else is right of x=200.
    let line_disc = !(scene.LN_X1 >= scene.DX - scene.DR
                      && scene.LN_Y1 >= scene.DY - scene.DR);
    test.ck("A03 line and disc bounding boxes are disjoint", line_disc,
       "line ends (" + tostring(scene.LN_X1) + "," + tostring(scene.LN_Y1)
       + "), disc starts (" + tostring(scene.DX - scene.DR) + ","
       + tostring(scene.DY - scene.DR) + ")");

    let left_right = scene.LN_X1 < scene.PL_X0
        && scene.DX + scene.DR < scene.PL_X0;
    test.ck("A04 the two left-hand elements clear the right-hand column",
       left_right,
       "right column starts at x=" + tostring(scene.PL_X0)
       + "; line ends " + tostring(scene.LN_X1)
       + ", disc ends " + tostring(scene.DX + scene.DR));

    // The three right-hand elements stack vertically, so they must not share a
    // row either.  plate 20..80, frame 100..200, checker 210..239.
    test.ck("A05 plate, frame and checker occupy disjoint row bands",
       scene.PL_Y1 < scene.FR_Y0 && scene.FR_Y1 < scene.CHK_Y0,
       "plate " + tostring(scene.PL_Y0) + ".." + tostring(scene.PL_Y1)
       + ", frame " + tostring(scene.FR_Y0) + ".." + tostring(scene.FR_Y1)
       + ", checker " + tostring(scene.CHK_Y0) + ".."
       + tostring(scene.CHK_Y0 + scene.CHK_H - 1));

    test.ck_eq("A06 the disc does not touch the frame's bottom edge",
          scene.DY + scene.DR, 227);

    // The disc must also not touch the left edge: a disc at the edge would be
    // clamped and its area would silently change.
    test.ck("A07 the disc is clear of the left edge",
       scene.DX - scene.DR > 0,
       "disc spans x=" + tostring(scene.DX - scene.DR) + ".."
       + tostring(scene.DX + scene.DR));

    // Cell grid: 111x30 over 3-pixel cells is 37x10 exactly, with no partial
    // cell on the right or the bottom.  A partial cell would make the
    // on-cell count depend on rounding rather than on the grid.
    test.ck_eq("A08 the checker divides evenly across", scene.CHK_W % scene.CHK_CELL, 0);
    test.ck_eq("A09 the checker divides evenly down", scene.CHK_H % scene.CHK_CELL, 0);
    test.ck_eq("A10 checker grid is 37x10 cells", scene.CHK_CELLS, 370);
}

// ─────────────────────────────────────────────────────────────── group B --
//
// The gradient, checked against its own closed form rather than against
// whatever `gfx.gradient` happened to produce.

def check_gradient() {
    test.group("B gradient: closed forms and exact corners");

    // Measure the ramp ALONE.  The five scene elements overwrite part of the
    // frame with dark colours, so the full image's channel sums are not the
    // ramp's sums -- an earlier version of this check asserted 255*w*h/2 against
    // the finished scene and was wrong by 5%.  The driver redraws the scene
    // before group E.
    gfx.wipe(scene.W, scene.H);
    gfx.gradient(scene.W, scene.H);
    gfx.stats_scan(scene.W, scene.H);

    // The four corners are exact by construction: floor(255(w-1)/(w-1)) = 255.
    test.ck_eq("B01 near corner (0,0) is pure black", gfx.get(0, 0), 0);
    test.ck_eq("B02 far corner (319,239) is pure white",
          gfx.get(scene.W - 1, scene.H - 1), 16777215);
    // The far corner is the only pixel that is 255 in all three channels.  The
    // other two corners are NOT pure: at (319,0) blue is floor(255*319/558)=145
    // and at (0,239) it is floor(255*239/558)=109, so calling either of them
    // "pure red" or "pure green" is a claim about a formula, not about the
    // image.  Asserting the closed form is what makes these worth having.
    test.ck_eq("B03 top-right is the closed form, blue included",
          gfx.get(scene.W - 1, 0),
          scene.corner_expect(scene.W - 1, 0, scene.W, scene.H));
    test.ck_eq("B04 bottom-left is the closed form, blue included",
          gfx.get(0, scene.H - 1),
          scene.corner_expect(0, scene.H - 1, scene.W, scene.H));
    test.ck_eq("B05 the blue channel at (319,0) is 145, not 0",
          gfx.get(scene.W - 1, 0) % 256, 145);
    test.ck_eq("B06 the blue channel at (0,239) is 109, not 0",
          gfx.get(0, scene.H - 1) % 256, 109);

    // Spots where the closed form has an exact value, so integer division
    // cannot be off by one.  At x=255 the red channel is 255*255/319 = 203 and
    // at y=127 the green is 255*127/239 = 135; both are read back and compared
    // against the formula, not against a stored constant.
    test.ck_eq("B07 column x=255 has the predicted red",
          gfx.get(255, 0) / 65536, (255 * 255) / (scene.W - 1));
    test.ck_eq("B08 row y=127 has the predicted green",
          gfx.get(0, 127) / 256 % 256, (255 * 127) / (scene.H - 1));

    // The gradient is monotone in r along x and in g along y.  A gradient that
    // wrapped or aliased would break this, and a single spot check would not.
    let bad_r = 0;
    let x = 1;
    while (x < scene.W) {
        let a = gfx.get(x - 1, 0) / 65536;
        let b = gfx.get(x, 0) / 65536;
        if (b < a) { bad_r = bad_r + 1 };
        x = x + 1;
    };
    test.ck_eq("B09 red is non-decreasing along the top row", bad_r, 0);

    let bad_g = 0;
    let y = 1;
    while (y < scene.H) {
        let a = gfx.get(0, y - 1) / 256 % 256;
        let b = gfx.get(0, y) / 256 % 256;
        if (b < a) { bad_g = bad_g + 1 };
        y = y + 1;
    };
    test.ck_eq("B10 green is non-decreasing down the left column", bad_g, 0);

    // Blue is monotone along the anti-diagonal, which is the axis it runs on.
    let bad_b = 0;
    let d = 1;
    while (d < scene.W) {
        let a = gfx.get(d - 1, 0) % 256;
        let b = gfx.get(d, 0) % 256;
        if (b < a) { bad_b = bad_b + 1 };
        d = d + 1;
    };
    test.ck_eq("B11 blue is non-decreasing along the top row", bad_b, 0);

    // THE CLOSED FORMS, and this is the strongest statement in the group: each
    // channel's total over the whole frame is a sum that can be written down
    // here from the definition, with no reference to `gfx.gradient` at all.
    //
    //   sum_r = h * SUM_x floor(255x/(w-1))   (each column repeats h times)
    //   sum_g = w * SUM_y floor(255y/(h-1))   (each row repeats w times)
    //   sum_b = SUM_x SUM_y floor(255(x+y)/(w+h-2))
    //
    // The first two are single loops.  The third walks the same 76 800 pixels
    // the renderer does, but written out here from the formula, so agreement
    // means the renderer computes the ramp it claims to.
    let wr = 0;
    let x = 0;
    while (x < scene.W) { wr = wr + (255 * x) / (scene.W - 1); x = x + 1 };
    let wg = 0;
    let y = 0;
    while (y < scene.H) { wg = wg + (255 * y) / (scene.H - 1); y = y + 1 };
    test.ck_eq("B12 red total = h * SUM_x floor(255x/(w-1))",
          gfx.st.sum_r, scene.H * wr);
    test.ck_eq("B13 green total = w * SUM_y floor(255y/(h-1))",
          gfx.st.sum_g, scene.W * wg);

    let wb = 0;
    let by = 0;
    while (by < scene.H) {
        let bx = 0;
        while (bx < scene.W) {
            wb = wb + (255 * (bx + by)) / (scene.W + scene.H - 2);
            bx = bx + 1;
        };
        by = by + 1;
    };
    test.ck_eq("B14 blue total = SUM over every pixel of floor(255(x+y)/(w+h-2))",
          gfx.st.sum_b, wb);

    // The black count on the ramp alone, where nothing has been painted over it
    // -- which is exactly the case scene.y derives.
    test.ck_eq("B15 the ramp alone has exactly the predicted black pixels",
          scene.W * scene.H - gfx.st.nonzero,
          scene.background_black_expect(scene.W, scene.H));
}

// ─────────────────────────────────────────────────────────────── group C --
//
// Each primitive's pixel count against its closed form.

def check_primitives() {
    test.group("C primitives: returned counts against closed forms");

    // Group B wiped the buffer to measure the ramp on its own, so the scene has
    // to be drawn again here.  Doing it HERE rather than in the driver means
    // each group is self-contained and cannot be broken by reordering.
    scene.scene_draw(scene.W, scene.H);

    test.ck_eq("C01 Bresenham line count = max(|dx|,|dy|)+1",
          scene.elems[0].px,
          scene.line_expect(scene.LN_X0, scene.LN_Y0, scene.LN_X1, scene.LN_Y1));
    test.ck_eq("C02 the line count for this layout is 141",
          scene.elems[0].px, 141);
    // A line whose count were right by luck would still have to end where it
    // was asked to.  Read the endpoints back out of the framebuffer.
    test.ck_eq("C03 the line starts at its first endpoint",
          gfx.get(scene.LN_X0, scene.LN_Y0), scene.COL_LINE);
    test.ck_eq("C04 the line ends at its last endpoint",
          gfx.get(scene.LN_X1, scene.LN_Y1), scene.COL_LINE);

    test.ck_eq("C05 filled rectangle area = w*h",
          scene.elems[2].px,
          scene.plate_expect(scene.PL_X0, scene.PL_Y0, scene.PL_X1, scene.PL_Y1));
    test.ck_eq("C06 the plate is 101x61 = 6161", scene.elems[2].px, 6161);

    test.ck_eq("C07 one-pixel frame = 2(w+h)-4",
          scene.elems[3].px,
          scene.frame_expect(scene.FR_X0, scene.FR_Y0, scene.FR_X1, scene.FR_Y1));
    test.ck_eq("C08 the frame is 111x101 -> 420", scene.elems[3].px, 420);
    // The corners of a one-pixel frame are drawn once each, so they are the
    // frame's colour; the interior is not.
    test.ck_eq("C09 frame corner is frame-coloured",
          gfx.get(scene.FR_X0, scene.FR_Y0), scene.COL_FRAME);
    test.ck("A10b frame interior is NOT frame-coloured",
       gfx.get((scene.FR_X0 + scene.FR_X1) / 2, (scene.FR_Y0 + scene.FR_Y1) / 2)
       != scene.COL_FRAME,
       "interior must show the gradient, proving the frame is one pixel thick");

    test.ck_eq("C10 checker on-cells matches the closed form",
          scene.elems[4].px,
          scene.checker_on_expect(scene.CHK_COLS, scene.CHK_ROWS));
    test.ck_eq("C11 the checker lights 185 of 370 cells", scene.elems[4].px, 185);
    test.ck("C12 on-cells never exceed the total cell count",
       scene.elems[4].px
           <= scene.checker_cells_expect(scene.CHK_COLS, scene.CHK_ROWS),
       "on " + tostring(scene.elems[4].px) + " of "
       + tostring(scene.checker_cells_expect(scene.CHK_COLS, scene.CHK_ROWS)));
}

// ─────────────────────────────────────────────────────────────── group D --
//
// The disc, two ways.  `gfx.disc` walks a (2r+1)^2 box and tests every pixel;
// `scene.disc_area_expect` sums exact per-column heights derived from
// dx*dx+dy*dy <= r*r.  Two different computations of one number.

def check_disc() {
    test.group("D disc: box-walk area against summed exact columns");

    scene.scene_draw(scene.W, scene.H);

    let want = scene.disc_area_expect(scene.DR);
    test.ck_eq("D01 disc area from summed columns", scene.elems[1].px, want);
    test.ck_eq("D02 that area is 8497 for r=52", want, 8497);

    // Gauss's circle bound: the lattice disc differs from pi*r^2 by at most
    // the perimeter 2*pi*r.  Checked in integer arithmetic, in thousandths.
    let approx = scene.pi_milli(scene.DR);
    let perim = scene.disc_perimeter_milli(scene.DR);
    let lo = (scene.DR * scene.DR * 3141593 - 2 * scene.DR * 3141593) / 1000000;
    let hi = (scene.DR * scene.DR * 3141593 + 2 * scene.DR * 3141593) / 1000000;
    test.ck("D03 area lies within Gauss's perimeter bound",
       scene.elems[1].px >= lo && scene.elems[1].px <= hi,
       "area " + tostring(scene.elems[1].px) + ", pi*r^2/1000 = "
       + tostring(approx) + ", bound 2*pi*r/1000 = " + tostring(perim)
       + ", so " + tostring(lo) + ".." + tostring(hi));
    test.ck("D04 the perimeter bound is not vacuous (it has width)",
       hi > lo, "bound spans " + tostring(hi - lo) + " pixels");

    // Per-column heights, read out of the finished image by counting the disc's
    // colour in each column.  This is (c): a measurement of the picture, not a
    // number the disc routine returned.
    let mism = 0;
    let dx = 0 - scene.DR;
    while (dx <= scene.DR) {
        let col = scene.DX + dx;
        let seen = 0;
        let y = 0;
        while (y < scene.H) {
            if (gfx.get(col, y) == scene.COL_DISC) { seen = seen + 1 };
            y = y + 1;
        };
        if (seen != scene.disc_col_expect(scene.DR, dx)) { mism = mism + 1 };
        dx = dx + 1;
    };
    test.ck_eq("D05 every disc column has the height the integer test predicts",
          mism, 0);

    // The disc's extremes: the widest row is the centre row and is 2r+1 wide.
    let widest = 0;
    let y = 0;
    while (y < scene.H) {
        let n = 0;
        let x = 0;
        while (x < scene.W) {
            if (gfx.get(x, y) == scene.COL_DISC) { n = n + 1 };
            x = x + 1;
        };
        if (n > widest) { widest = n };
        y = y + 1;
    };
    test.ck_eq("D06 the disc's widest row is 2r+1", widest, 2 * scene.DR + 1);
    test.ck_eq("D07 the disc is vertically centred on its row",
          widest, 105);
}

// ─────────────────────────────────────────────────────────────── group E --
//
// The finished image, counted by colour.  Nothing here consults the counts the
// drawing routines returned: every figure is measured off the framebuffer.

def count_colour(c: long, w: long, h: long) -> long {
    let n = 0;
    let y = 0;
    while (y < h) {
        let x = 0;
        while (x < w) {
            if (gfx.get(x, y) == c) { n = n + 1 };
            x = x + 1;
        };
        y = y + 1;
    };
    n
};

// count_colour_box: the same count restricted to one element's bounding box.
//
// Counting over the whole frame is only safe when the colour is one the
// background cannot produce.  The white line was counted as 142 rather than 141
// because the gradient's far corner is exactly pure white -- the palette has
// since changed, but the robust form is to count INSIDE the box, which also
// checks that the element is where the table says it is.
def count_colour_box(c: long, x0: long, y0: long, x1: long, y1: long) -> long {
    let n = 0;
    let y = y0;
    while (y <= y1) {
        let x = x0;
        while (x <= x1) {
            if (gfx.get(x, y) == c) { n = n + 1 };
            x = x + 1;
        };
        y = y + 1;
    };
    n
};

def check_image() {
    test.group("E the finished image, measured by colour and counted by hand");

    let w = scene.W;
    let h = scene.H;

    test.ck_eq("E01 line pixels, counted inside its bounding box",
          count_colour_box(scene.COL_LINE, scene.LN_X0, scene.LN_Y0,
                           scene.LN_X1, scene.LN_Y1), 141);
    test.ck_eq("E02 disc pixels, counted inside its bounding box",
          count_colour_box(scene.COL_DISC, scene.DX - scene.DR,
                           scene.DY - scene.DR, scene.DX + scene.DR,
                           scene.DY + scene.DR), 8497);
    test.ck_eq("E03 plate pixels, counted inside its bounding box",
          count_colour_box(scene.COL_PLATE, scene.PL_X0, scene.PL_Y0,
                           scene.PL_X1, scene.PL_Y1), 6161);
    test.ck_eq("E04 frame pixels, counted inside its bounding box",
          count_colour_box(scene.COL_FRAME, scene.FR_X0, scene.FR_Y0,
                           scene.FR_X1, scene.FR_Y1), 420);
    // The same count over the WHOLE frame must now agree too, because the
    // palette is now chosen so the background cannot imitate any element colour.
    test.ck_eq("E04b and over the whole frame too, for the line",
          count_colour(scene.COL_LINE, w, h), 141);
    test.ck_eq("E04c and for the disc", count_colour(scene.COL_DISC, w, h), 8497);

    // The checker's two colours, counted separately, must add up to its area:
    // 37x10 cells of 3x3 pixels = 111x30 = 3330 pixels.
    let cx1 = scene.CHK_X0 + scene.CHK_W - 1;
    let cy1 = scene.CHK_Y0 + scene.CHK_H - 1;
    let on = count_colour_box(scene.COL_ON, scene.CHK_X0, scene.CHK_Y0, cx1, cy1);
    let off = count_colour_box(scene.COL_OFF, scene.CHK_X0, scene.CHK_Y0,
                               cx1, cy1);
    test.ck_eq("E05 checker on-colour pixels = 185 cells x 9",
          on, 185 * scene.CHK_CELL * scene.CHK_CELL);
    test.ck_eq("E06 checker covers its whole 111x30 box",
          on + off, scene.CHK_W * scene.CHK_H);
    test.ck("E07 on-cells and off-cells are within one cell of each other",
       (on - off) * (on - off) <= 81,
       "on " + tostring(on) + ", off " + tostring(off)
       + ", differ by " + tostring((on - off) / 9) + " cells");

    // Nothing was clipped: the primitives write outside the buffer only if the
    // caller asked for it, and the layout provably does not.
    test.ck_eq("E08 no pixel write fell outside the frame", gfx.clipped, 0);

    // The black-pixel count is the one the derivation in scene.y predicts.
    let black = w * h - gfx.st.nonzero;
    test.ck_eq("E09 black pixels = the predicted 2",
          black, scene.background_black_expect(w, h));
    test.ck_eq("E10 that is 2, at (0,0) and (1,0)", black, 2);
    test.ck_eq("E11 pixel (0,0) really is black", gfx.get(0, 0), 0);
    test.ck_eq("E12 pixel (1,0) really is black", gfx.get(1, 0), 0);
    test.ck("E13 pixel (2,0) is NOT black", gfx.get(2, 0) != 0,
       "x=2 gives r = 255*2/319 = 1, so it is the first non-black pixel");

    // Every pixel is either black or non-black, and the tally adds up.  This
    // is the anti-vacuity anchor: a `nonzero` of 0 would satisfy nothing else.
    test.ck_eq("E14 nonzero + black = the whole frame",
          gfx.st.nonzero + black, w * h);
    test.ck("E15 the image is not blank", gfx.st.nonzero > 0,
       "nonzero " + tostring(gfx.st.nonzero) + " of " + tostring(w * h));

    // The channel sums must agree with each other.  The gradient alone puts
    // sum_b at 255/2 per pixel (x+y averages (w-1+h-1)/2), and sum_r and sum_g
    // at 255/2 as well, so all three are within 1% of 255*w*h/2.  This is a
    // real identity of the ramp, not a tautology about the counter.
    // The channel sums of a GRADIENT-ONLY image have a closed form, and it is
    // worth checking -- but the scene has five elements painted over it, so the
    // full image's sums are not the gradient's sums.  Asserting 255*w*h/2 here
    // was wrong by about 5%, and it was my TEST that was wrong, not the image.
    // The real check is in group B, on a wiped buffer, against a sum computed
    // there from the formula alone.
    test.ck_eq("E16 sum_all is the three sums added",
          gfx.st.sum_all, gfx.st.sum_r + gfx.st.sum_g + gfx.st.sum_b);
    test.ck("E17 the scene's red total is below the pure gradient's",
       gfx.st.sum_r < 255 * w * h / 2,
       "sum_r " + tostring(gfx.st.sum_r) + " < "
       + tostring(255 * w * h / 2));
    test.ck("E18 the scene's green total is below the pure gradient's",
       gfx.st.sum_g < 255 * w * h / 2, "sum_g " + tostring(gfx.st.sum_g));
    // No direction is claimed for blue.  An earlier version of this check
    // asserted the same "below" as red and green and was wrong: the checker's
    // lit cells are 0x00FFFF, whose blue channel is 255 -- the maximum -- so
    // they push the total UP, not down.  "The elements changed it" is the true
    // and useful statement.
    test.ck("E19 the scene's blue total differs from the pure gradient's",
       gfx.st.sum_b != 255 * w * h / 2,
       "sum_b " + tostring(gfx.st.sum_b) + " against a gradient total of "
       + tostring(255 * w * h / 2) + " -- raised, because the checker's lit "
       + "cells are 0x00FFFF and their blue channel is 255");
}

// ─────────────────────────────────────────────────────────────── group F --
//
// The digest, and specifically the anti-vacuity property that makes a digest
// meaningful: a digest must be able to tell a rendered image from nothing at
// all.  A battery that only ever compared a digest against a copy of itself
// would pass on an empty buffer.
//
// FNV_ZEROS was computed by a SEPARATE PROGRAM (a Python script), not by this
// one, so it is independent evidence.  It is the FNV-1a 64 of 230400 zero
// bytes: 0x326e0739b4ae7325.

let FNV_ZEROS = 3633849893760430885;      // 0x326e0739b4ae7325

def check_digest() {
    test.group("F digest: deterministic, and able to distinguish an image from nothing");

    let d1 = gfx.digest(scene.W, scene.H);
    let d2 = gfx.digest(scene.W, scene.H);
    test.ck_eq("F01 digesting the same bytes twice agrees", d1, d2);

    // Redraw from scratch.  If any of the render depended on uninitialised
    // memory, map order, or the clock, the two digests would differ.
    let _re = scene.scene_draw(scene.W, scene.H);
    let d3 = gfx.digest(scene.W, scene.H);
    test.ck_eq("F02 a full redraw gives a byte-identical image", d3, d1);

    // Streaming in bands must equal hashing in one pass.  This is what the
    // GetImage read-back relies on, so it is tested here rather than only on a
    // machine with a display.
    // 230400 is not a multiple of 4096, so the LAST band must be clamped or it
    // asks for bytes past the end of the buffer.  digest_add refuses that
    // correctly, which is what the first version of this check tripped over.
    let total = scene.W * scene.H * 3;
    let band = 0;
    let h_band = gfx.FNV_OFF;
    while (band < total) {
        let bn = 4096;
        if (band + bn > total) { bn = total - band };
        let nh = gfx.digest_add(h_band, band, bn);
        if (nh == 0 - 1) { h_band = 0 - 1 } else { h_band = nh };
        band = band + 4096;
    };
    test.ck_eq("F03 banded digest equals whole-image digest", h_band, d1);

    // THE ANTI-VACUITY ANCHOR.  An all-zero framebuffer must hash to the
    // externally computed constant, and the rendered scene must NOT hash to
    // it.  Without this, "the digest matches" could be satisfied by a buffer
    // that was never drawn into.
    gfx.wipe(scene.W, scene.H);
    let dz = gfx.digest(scene.W, scene.H);
    test.ck_eq("F04 an all-zero framebuffer hashes to the external constant",
          dz, FNV_ZEROS);
    test.ck("F05 the rendered image does NOT hash to that constant",
       d1 != FNV_ZEROS,
       "rendered digest " + gfx.digest_hex(d1) + " vs zeroed "
       + gfx.digest_hex(FNV_ZEROS));

    // And the round trip: redraw and confirm we are back where we started.
    scene.scene_draw(scene.W, scene.H);
    test.ck_eq("F06 redrawing after a wipe restores the digest exactly",
          gfx.digest(scene.W, scene.H), d1);
    test.ck_eq("F07 and the nonzero count with it", gfx.stats_scan(scene.W, scene.H),
          76798);

    // A one-byte change must change the digest.  Otherwise the digest is not
    // sensitive to the image and proves nothing.
    // Save what was there: restoring to 0,0,0 would not restore, because the
    // gradient had put a non-zero value in that pixel.  That was a bug in this
    // test, and one that a weaker check would have hidden.
    let saved = gfx.get(160, 120);
    let before = gfx.digest(scene.W, scene.H);
    gfx.put(160, 120, 255, 0, 255);
    let after = gfx.digest(scene.W, scene.H);
    test.ck("F08 flipping one pixel changes the digest", before != after,
       gfx.digest_hex(before) + " -> " + gfx.digest_hex(after));
    gfx.put(160, 120, (saved >> 16) & 255, (saved >> 8) & 255, saved & 255);
    test.ck_eq("F09 and restoring the pixel restores the digest",
          gfx.digest(scene.W, scene.H), before);
    test.ck_eq("F09b and the restored pixel is the one that was there",
          gfx.get(160, 120), saved);

    // digest_add must refuse to read outside the buffer instead of trapping.
    test.ck_eq("F10 digest_add rejects an overrun", gfx.digest_add(gfx.FNV_OFF,
          gfx.PX_MAX - 3, 8), 0 - 1);
    test.ck_eq("F11 digest_add rejects a negative offset", gfx.digest_add(gfx.FNV_OFF,
          0 - 1, 4), 0 - 1);
    test.ck_eq("F12 and a zero-length hash at the very end is legal",
          gfx.digest_add(gfx.FNV_OFF, gfx.PX_MAX, 0), gfx.FNV_OFF);
}

// ─────────────────────────────────────────────────────────────── group G --
//
// The clamping and degenerate-input paths.  There is no `break` in this
// language, so every routine's behaviour on a bad argument is a real question
// rather than a formality: it must terminate and must not write out of bounds.

def check_edges() {
    test.group("G degenerate geometry: terminates, clamps, never clips");

    // Inverted rectangles.  ax > bx, so nothing may be drawn and 0 returned.
    test.ck_eq("G01 an inverted rectangle writes nothing",
          gfx.fill_rect(50, 50, 10, 10, 0xFF00FF), 0);
    test.ck_eq("G02 a zero-area rectangle writes one pixel",
          gfx.fill_rect(7, 7, 7, 7, 0xFF00FF), 1);

    // A line whose endpoints coincide is one pixel, not zero and not a loop.
    test.ck_eq("G03 a zero-length line is one pixel", gfx.line(20, 20, 20, 20, 0xFF00FF),
          1);

    // A horizontal and a vertical line have the same closed form as any other:
    // max(|dx|,|dy|)+1.
    test.ck_eq("G04 horizontal line count = width+1",
          gfx.line(0, 5, 100, 5, 0xFF00FF), 101);
    test.ck_eq("G05 vertical line count = height+1",
          gfx.line(5, 0, 5, 100, 0xFF00FF), 101);

    // A disc of radius 0 is one pixel; radius 1 is the 5-pixel plus shape.
    test.ck_eq("G06 a zero-radius disc is one pixel", gfx.disc(30, 30, 0, 0xFF00FF), 1);
    test.ck_eq("G07 a unit disc is the 5-pixel plus", gfx.disc(30, 30, 1, 0xFF00FF), 5);
    // Three columns, not two: dx = -1, 0, +1.  Summing only the centre and one
    // side column gave 2, and that was this test's bug.
    test.ck_eq("G08 and that matches the closed form over all 3 columns", 5,
          scene.disc_col_expect(1, 0 - 1) + scene.disc_col_expect(1, 0)
              + scene.disc_col_expect(1, 1));

    // A negative radius is clamped to 0, not made into a huge disc.
    test.ck_eq("G09 a negative radius is clamped to zero",
          gfx.disc(30, 30, 0 - 5, 0xFF00FF), 1);

    // A frame smaller than 2x2 degenerates but must still terminate.
    test.ck("G10 a 1x1 frame draws one pixel", gfx.stroke_rect(9, 9, 9, 9, 0xFF00FF) == 1,
       "got " + tostring(gfx.stroke_rect(9, 9, 9, 9, 0xFF00FF)));
    test.ck("G11 a 2x2 frame draws 4 pixels", gfx.stroke_rect(11, 11, 12, 12, 0xFF00FF) == 4,
       "got " + tostring(gfx.stroke_rect(11, 11, 12, 12, 0xFF00FF)));

    // Out-of-bounds reads return the sentinel rather than trapping.
    test.ck_eq("G12 reading outside the buffer returns -1", gfx.get(-1, 0), 0 - 1);
    test.ck_eq("G13 reading past the right edge returns -1",
          gfx.get(gfx.W_MAX, 0), 0 - 1);
    test.ck_eq("G14 reading past the bottom returns -1",
          gfx.get(0, gfx.H_MAX), 0 - 1);

    // Out-of-bounds writes are dropped AND counted, which is what lets the
    // demo assert `clipped == 0`.
    let c0 = gfx.clipped;
    gfx.putn(gfx.W_MAX + 5, 5, 0xFF00FF);
    gfx.putn(0 - 5, 5, 0xFF00FF);
    gfx.putn(5, gfx.H_MAX + 5, 0xFF00FF);
    test.ck_eq("G15 three out-of-bounds writes were each counted",
          gfx.clipped - c0, 3);
    gfx.clipped = c0;

    // isqrt, which the disc's closed form depends on.  Checked against squares
    // whose roots are exact, and against the defining inequality.
    test.ck_eq("G16 isqrt(0)", gfx.isqrt(0), 0);
    test.ck_eq("G17 isqrt(1)", gfx.isqrt(1), 1);
    test.ck_eq("G18 isqrt(52*52)", gfx.isqrt(52 * 52), 52);
    test.ck_eq("G19 isqrt(320*240)", gfx.isqrt(320 * 240), 277);
    let bad = 0;
    let v = 0;
    while (v < 3000) {
        let r = gfx.isqrt(v);
        if (r * r > v || (r + 1) * (r + 1) <= v) { bad = bad + 1 };
        v = v + 1;
    };
    test.ck_eq("G20 isqrt is floor(sqrt) for all 3000 values tried", bad, 0);

    // clamp helpers
    test.ck_eq("G21 iclamp clamps low", gfx.iclamp(0 - 5, 0, 10), 0);
    test.ck_eq("G22 iclamp clamps high", gfx.iclamp(99, 0, 10), 10);
    test.ck_eq("G23 iclamp passes the middle through", gfx.iclamp(5, 0, 10), 5);
}

// ─────────────────────────────────────────────────────────────── group H --
//
// WHICH PIXELS, not how many.  Groups A..G check counts, endpoints and closed
// forms, and that left a real gap: changing Bresenham's tie test from
// `e2 <= dx` to `e2 < dx` keeps the pixel COUNT (max(|dx|,|dy|)+1) and both
// ENDPOINTS, and only moves pixels in between.  A defect that did exactly that
// survived every one of the 102 checks -- and it moves pixels for 575 of the
// 3481 small slopes, including the scene's own 140x62 line.
//
// So this group verifies the pixel SET, against a closed form written out
// independently of the loop:
//
//     on step i of a line whose major axis advances every step, the minor
//     coordinate is y0 + sy * ((i*|dy| + dx/2) / dx)
//
// with integer division, i.e. round-half-up.  That is a statement about the
// line's geometry; `gfx.line` computes it by accumulating an error term.  Two
// different computations of one set of points.

let LINECOL = 16711680;          // 0xFF0000, not used by the scene

// check a line from (x0,y0) to (x1,y1) pixel by pixel against the closed form
def check_line_shape(tag: str, x0: long, y0: long, x1: long, y1: long) {
    let dx = gfx.imax(x0 - x1, x1 - x0);
    let dy = gfx.imax(y0 - y1, y1 - y0);
    let sx = if x0 < x1 { 1 } else { 0 - 1 };
    let sy = if y0 < y1 { 1 } else { 0 - 1 };

    // The MAJOR axis advances on every step and the minor one is derived, so
    // which axis is which matters.  The first version of this check assumed
    // dx was always the major one, and reported 50 "unexpected pixels" for a
    // line steeper than wide -- it was checking 11 of the 61 steps and calling
    // the other 50 spurious.  That was this test's bug, not the renderer's, and
    // it is the third time in this file that a plausible assumption about which
    // axis dominates has been wrong.
    let mx = gfx.imax(dx, dy);
    let mn = gfx.imin(dx, dy);
    let x_major = dx >= dy;
    let half = mx / 2;

    let bad = 0;
    let bad_list = "";
    let i = 0;
    while (i <= mx) {
        let m = (i * mn + half) / mx;
        let ex = 0;
        let ey = 0;
        if (x_major) {
            ex = x0 + i * sx;
            ey = y0 + m * sy
        } else {
            ey = y0 + i * sy;
            ex = x0 + m * sx
        };
        if (gfx.get(ex, ey) != LINECOL) {
            bad = bad + 1;
            if (bad_list == "") {
                bad_list = " first miss at step " + tostring(i) + ", expected ("
                    + tostring(ex) + "," + tostring(ey) + ")"
            }
        };
        i = i + 1
    };
    // And nothing ELSE of this colour anywhere on the frame: a line that also
    // plotted a pixel the closed form does not predict must be caught too.
    let extra = 0;
    let y = 0;
    while (y < scene.H) {
        let x = 0;
        while (x < scene.W) {
            if (gfx.get(x, y) == LINECOL) {
                let on = false;
                let k = 0;
                while (k <= mx) {
                    let mm = (k * mn + half) / mx;
                    let px = 0;
                    let py = 0;
                    if (x_major) {
                        px = x0 + k * sx;
                        py = y0 + mm * sy
                    } else {
                        py = y0 + k * sy;
                        px = x0 + mm * sx
                    };
                    if (px == x && py == y) { on = true };
                    k = k + 1
                };
                if (!on) { extra = extra + 1 }
            };
            x = x + 1
        };
        y = y + 1
    };
    test.ck(tag, bad == 0 && extra == 0,
       tostring(bad) + " predicted pixel(s) missing" + bad_list + ", "
       + tostring(extra) + " unexpected pixel(s), over " + tostring(mx + 1)
       + " steps");
};

def check_shapes() {
    test.group("H shapes: which pixels, against a closed form independent of the loop");

    // Slopes chosen because the tie case is REACHED on them.  dx=4 dy=1 puts
    // the error term exactly on dx/2 at step 2, which is where `e2 <= dx` and
    // `e2 < dx` disagree.  575 of the 3481 slopes up to 60x60 differ, so these
    // are not special-cased trivia.
    gfx.wipe(scene.W, scene.H);
    gfx.line(4, 3, 8, 4, LINECOL);
    check_line_shape("H01 dx=4 dy=1, the error term lands exactly on dx/2",
                     4, 3, 8, 4);

    gfx.wipe(scene.W, scene.H);
    gfx.line(4, 3, 6, 4, LINECOL);
    check_line_shape("H02 dx=2 dy=1, a tie on the very first step", 4, 3, 6, 4);

    gfx.wipe(scene.W, scene.H);
    gfx.line(2, 2, 8, 5, LINECOL);
    check_line_shape("H03 dx=6 dy=3", 2, 2, 8, 5);

    // And the scene's own line, which is one of the 575.
    gfx.wipe(scene.W, scene.H);
    gfx.line(scene.LN_X0, scene.LN_Y0, scene.LN_X1, scene.LN_Y1, LINECOL);
    check_line_shape("H04 the scene's line, dx=140 dy=62",
                     scene.LN_X0, scene.LN_Y0, scene.LN_X1, scene.LN_Y1);

    // Descending, so sy = -1 is exercised rather than assumed.
    gfx.wipe(scene.W, scene.H);
    gfx.line(10, 60, 90, 20, LINECOL);
    check_line_shape("H05 a descending line, dx=80 dy=-40", 10, 60, 90, 20);

    // Steeper than wide, so dx is NOT the major axis and the roles swap.
    gfx.wipe(scene.W, scene.H);
    gfx.line(10, 10, 20, 70, LINECOL);
    check_line_shape("H06 steeper than wide, dx=10 dy=60", 10, 10, 20, 70);

    // The checkerboard's PATTERN, not its count.  Shifting the cell origin by
    // one row leaves the number of lit cells exactly 185 and the number of lit
    // pixels exactly 185*9, because the pattern is symmetric -- so C11 and E05
    // both stay green while the image is wrong.  These read individual cells.
    gfx.wipe(scene.W, scene.H);
    gfx.checker(scene.CHK_X0, scene.CHK_Y0, scene.CHK_W, scene.CHK_H,
                scene.CHK_CELL, scene.COL_ON, scene.COL_OFF);
    let cs = scene.CHK_CELL;
    // Cell (0,0): cx+cy = 0, even, so lit.  Row 2 of it is the row an off-by-one
    // cell origin moves, which is the whole point of looking at THIS row.
    test.ck_eq("H07 first cell, its third row is still the ON colour",
          gfx.get(scene.CHK_X0 + 1, scene.CHK_Y0 + 2), scene.COL_ON);
    test.ck_eq("H08 first cell, its first row is the ON colour",
          gfx.get(scene.CHK_X0 + 1, scene.CHK_Y0 + 0), scene.COL_ON);
    test.ck_eq("H09 second cell across is the OFF colour",
          gfx.get(scene.CHK_X0 + cs + 1, scene.CHK_Y0 + 0), scene.COL_OFF);
    test.ck_eq("H10 second cell down is the OFF colour",
          gfx.get(scene.CHK_X0 + 0, scene.CHK_Y0 + cs), scene.COL_OFF);
    test.ck_eq("H11 the cell diagonally across is the ON colour",
          gfx.get(scene.CHK_X0 + cs, scene.CHK_Y0 + cs), scene.COL_ON);
    // And the boundary between two cell rows, which is where a shift shows.
    test.ck_eq("H12 the last row of cell row 0 is still cell row 0",
          gfx.get(scene.CHK_X0 + 1, scene.CHK_Y0 + cs - 1), scene.COL_ON);
    test.ck_eq("H13 and the first row of cell row 1 belongs to cell row 1",
          gfx.get(scene.CHK_X0 + 1, scene.CHK_Y0 + cs), scene.COL_OFF);
};

// ─────────────────────────────────────────────────────────────── driver ---

def do_check() -> long {
    print("x11 check: property battery, no display and no reference file");
    print("");
    scene.scene_draw(scene.W, scene.H);
    gfx.stats_scan(scene.W, scene.H);

    // Every group below names itself with test.group(), which prints the blank
    // line and the heading; the separators used to be hand-written print("")
    // calls between the calls, and keeping both would have doubled every gap.
    check_layout();
    check_gradient();
    check_primitives();
    check_disc();
    // Re-draw before counting the image: groups B..G scribble test colours over
    // the scene, so the picture must be restored before it is measured by
    // colour.  Restoring is itself worth asserting, so it is not silent.
    scene.scene_draw(scene.W, scene.H);
    gfx.stats_scan(scene.W, scene.H);
    check_image();
    check_digest();
    check_edges();
    scene.scene_draw(scene.W, scene.H);
    check_shapes();
    print("  note: groups B..G overwrite pixels with test colours; the image");
    print("        was redrawn before group E so its counts are of the scene.");
    // std/test.y's summary and its 0-or-1, in the same words this battery
    // always printed by hand.  It prints its own leading blank line, which is
    // why there is no print("") in front of it.
    test.report()
};

export { do_check };