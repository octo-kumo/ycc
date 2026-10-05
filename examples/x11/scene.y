// scene.y -- the image this example is about, the table that describes it,
// and the arithmetic that predicts every number the demo prints.
//
// Five elements, each chosen because one of its properties is a fact about
// arithmetic rather than about this code:
//
//   1. a three-channel linear gradient (exact corners; exactly two black
//      pixels, at (0,0) and (1,0), by a derivation below),
//   2. a Bresenham line (its pixel count is max(|dx|,|dy|)+1),
//   3. a filled disc tested with dx*dx+dy*dy <= r*r (per-column heights are
//      2*isqrt(r*r-dx*dx)+1, hand-computable),
//   4. a solid plate and a one-pixel frame (areas are w*h and
//      2*(w+h)-4),
//   5. a checkerboard (on-cells is a closed form of the cell grid).
//
// They are laid out so that **no two overlap** and none touches a pixel the
// gradient would otherwise leave black, which is what makes the per-element
// counts and the black-pixel count checkable in the finished image rather
// than only inside the routine that drew them.  The battery asserts the
// non-overlap; it is why the layout is a table and not scattered through the
// drawing calls.
//
// Everything in the lower half of this file is a PREDICTION, derived from the
// definitions.  `check.y` compares the render against these and against
// figures re-derived by hand, so nothing in the battery is satisfied by
// agreeing with the code that drew the image.

import gfx;

type Elem = {
    name: str,
    x0: long, y0: long, x1: long, y1: long,   // inclusive bounding box
    px: long,                                 // pixels the routine wrote
    kind: long                                // 0 disc, 1 line, 2 plate,
};                                            // 3 frame, 4 checker

let W = 320;
let H = 240;

// ---------------------------------------------------------------- layout --
// Every coordinate in one place.  `scene_draw` and `check.y` both read these,
// so the battery cannot accidentally check a different picture.

// the line: upper left, clear of everything else
let LN_X0 = 10;
let LN_Y0 = 8;
let LN_X1 = 150;
let LN_Y1 = 70;

// the disc: lower left, clear of the line (which stops at y=70) and of
// everything on the right (which starts at x=200)
let DX = 110;
let DY = 175;
let DR = 52;

// the plate: upper right
let PL_X0 = 200;
let PL_Y0 = 20;
let PL_X1 = 300;
let PL_Y1 = 80;

// the one-pixel frame: middle right
let FR_X0 = 200;
let FR_Y0 = 100;
let FR_X1 = 310;
let FR_Y1 = 200;

// the checkerboard: bottom right, 3-pixel cells over 111x30 -> a 37x10 grid
let CHK_X0 = 200;
let CHK_Y0 = 210;
let CHK_W = 111;
let CHK_H = 30;
let CHK_CELL = 3;
let CHK_COLS = CHK_W / CHK_CELL;      // 37
let CHK_ROWS = CHK_H / CHK_CELL;      // 10
let CHK_CELLS = CHK_COLS * CHK_ROWS;  // 370

// colours, all with a non-zero blue channel so none of them is black.
//
// COL_LINE is MAGENTA, and that is not decoration.  The first draft used white
// (0xFFFFFF), and the gradient's far corner (319,239) is exactly pure white in
// all three channels -- so counting the line's pixels by colour found 142 of
// them: the 141 the line draws, plus that one corner.  The renderer was right
// and the count was wrong, but a palette that a background pixel can imitate is
// a trap for whoever reads the code next.  Magenta is unreachable by this
// gradient: r = 255 forces x = 319, where b = floor(255*319/558) = 145, never
// 255.  Every other colour is chosen the same way, by being unreachable.
let COL_LINE = 16711935;      // 0xFF00FF  -> rgb(255, 0, 255)
let COL_DISC = 16744188;      // 0xFFC83C
let COL_PLATE = 3413;         // 0x000D55  -> rgb(0, 13, 85)
let COL_FRAME = 65470;        // 0x00FFB6  -> rgb(0, 255, 182)
let COL_ON = 65535;           // 0x00FFFF  -> rgb(0, 255, 255)
let COL_OFF = 2236962;        // 0x222222  -> rgb(34, 34, 34)

// ------------------------------------------------------------ the render --

// The element table, filled by `scene_draw` and read by the demo and by the
// battery.  Index by construction: 0 line, 1 disc, 2 plate, 3 frame,
// 4 checker.
let elems: [Elem] = [];

def elem_add(name: str, x0: long, y0: long, x1: long, y1: long,
             px: long, kind: long) -> long {
    elems += { name: name, x0: x0, y0: y0, x1: x1, y1: y1, px: px, kind: kind };
    len(elems)
};

// Draw the whole scene into gfx.px.  Returns the total pixels written by the
// five elements (the gradient is not counted; it covers the frame).
def scene_draw(w: long, h: long) -> long {
    let cw = gfx.imin(w, gfx.W_MAX);
    let chh = gfx.imin(h, gfx.H_MAX);

    // scene_draw MUST be idempotent, and it was not: `elems` is a module-level
    // array and elem_add APPENDS, so calling this twice left ten entries in the
    // scene table and the demo printed all ten.  Caught by `demo --repeat 25`,
    // whose output is required to be byte-identical to `demo`'s and was not --
    // the extra five elements per repeat showed up as extra lines.  Clearing
    // the table first is what makes "draw the scene again" mean the same thing
    // every time, which is the property the golden file depends on.
    elems = [];
    // Likewise, `clipped` counts out-of-bounds pixel writes and is cumulative
    // across the whole process.  Resetting it here means the figure the demo
    // prints describes THIS draw rather than everything that ever happened.
    gfx.clipped = 0;

    gfx.wipe(cw, chh);
    gfx.gradient(cw, chh);

    let n_line = gfx.line(LN_X0, LN_Y0, LN_X1, LN_Y1, COL_LINE);
    elem_add("line", LN_X0, LN_Y0, LN_X1, LN_Y1, n_line, 1);

    let n_disc = gfx.disc(DX, DY, DR, COL_DISC);
    elem_add("disc", DX - DR, DY - DR, DX + DR, DY + DR, n_disc, 0);

    let n_plate = gfx.fill_rect(PL_X0, PL_Y0, PL_X1, PL_Y1, COL_PLATE);
    elem_add("plate", PL_X0, PL_Y0, PL_X1, PL_Y1, n_plate, 2);

    let n_frame = gfx.stroke_rect(FR_X0, FR_Y0, FR_X1, FR_Y1, COL_FRAME);
    elem_add("frame", FR_X0, FR_Y0, FR_X1, FR_Y1, n_frame, 3);

    let n_chk = gfx.checker(CHK_X0, CHK_Y0, CHK_W, CHK_H, CHK_CELL,
                            COL_ON, COL_OFF);
    elem_add("checker", CHK_X0, CHK_Y0, CHK_X0 + CHK_W - 1,
             CHK_Y0 + CHK_H - 1, n_chk, 4);

    n_line + n_disc + n_plate + n_frame + n_chk
};

// --------------------------------------------------------- predictions ----
// All of these are closed forms or short sums derived from the definitions of
// the primitives, not from the primitives.

// A Bresenham line from (x0,y0) to (x1,y1) emits max(|dx|,|dy|)+1 pixels:
// exactly one plot per step, and the loop takes max(|dx|,|dy|) steps because
// the major axis advances on every one of them.
def line_expect(x0: long, y0: long, x1: long, y1: long) -> long {
    gfx.imax(gfx.imax(x0 - x1, x1 - x0), gfx.imax(y0 - y1, y1 - y0)) + 1
};

// Pixels of a filled rectangle, corners inclusive.
def plate_expect(x0: long, y0: long, x1: long, y1: long) -> long {
    (x1 - x0 + 1) * (y1 - y0 + 1)
};

// Pixels of a one-pixel frame, corners inclusive: two rows of (x1-x0+1) and
// two columns of (y1-y0+1), less the four corner pixels each side drew twice.
def frame_expect(x0: long, y0: long, x1: long, y1: long) -> long {
    2 * (x1 - x0 + 1) + 2 * (y1 - y0 + 1) - 4
};

// Pixels of the filled disc in the column at horizontal offset dx from the
// centre: the largest dy with dx*dx + dy*dy <= r*r, taken twice, plus one.
// Exact for the integer test the renderer uses.
def disc_col_expect(r: long, dx: long) -> long {
    let s = r * r - dx * dx;
    if (s < 0) { 0 } else { 2 * gfx.isqrt(s) + 1 }
};

// The disc's area, summed over columns.  This is NOT what `gfx.disc` does --
// that one walks a (2r+1)^2 box and tests every pixel -- so the two are
// genuinely different computations of the same number.
def disc_area_expect(r: long) -> long {
    let n = 0;
    let dx = 0 - r;
    while (dx <= r) { n = n + disc_col_expect(r, dx); dx = dx + 1 };
    n
};

// pi to six decimals, as an integer.  The disc's area is pi*r*r to within the
// lattice-point error, which is at most the perimeter 2*pi*r (Gauss's bound:
// the disc differs from the union of its unit cells by at most one cell per
// boundary cell).  3141593/1000000, accurate to 1e-6, is far tighter than
// that bound.
def pi_milli(r: long) -> long { (r * r * 3141593) / 1000000 };
def disc_perimeter_milli(r: long) -> long { (2 * r * 3141593) / 1000 };

// The checker's on-cell count: a cell is lit when (cx+cy) is even, so among
// `cols` columns and `rows` rows the lit ones are even-column/even-row and
// odd-column/odd-row.  For the scene's 37x10 grid: (19*5) + (18*5) = 185.
def checker_on_expect(cols: long, rows: long) -> long {
    (((cols + 1) / 2) * ((rows + 1) / 2)) + ((cols / 2) * (rows / 2))
};
def checker_cells_expect(cols: long, rows: long) -> long { cols * rows };

// ---------------------------------------------------------------------
// How many pixels of the GRADIENT are black, and why exactly that many.
//
// The gradient is
//     r = floor(255x/(w-1)),  g = floor(255y/(h-1)),  b = floor(255(x+y)/(w+h-2))
// A pixel is black iff all three are zero, and floor(v/d) = 0 iff v < d, so
//     255x        < w-1     ->  x <= (w-2)/255
//     255y        < h-1     ->  y  = 0      (because 255 > h-1 for h <= 240)
//     255(x+y)    < w+h-2   ->  x+y <= (w+h-3)/255
// So the black set is {(x, 0) : x = 0 .. min((w-2)/255, (w+h-3)/255)} and its
// size is that minimum plus one.  At 320x240 that is min(1, 2) + 1 = 2, at
// (0,0) and (1,0).  This is where the demo's "nonzero" figure comes from:
// it is 76800 - 2 = 76798, and `nonzero` is printed precisely so that a
// gradient defect cannot leave it looking healthy.
def background_black_expect(w: long, h: long) -> long {
    let xmax = gfx.imin((w - 2) / 255, (w + h - 3) / 255);
    if (xmax < 0) { 0 } else { xmax + 1 }
};

// Where those black pixels are: (x, 0) for x = 0..background_black_expect()-1.
// Written as a loop because `check.y` wants to compare the set, not just its
// size.  Fills `black_x`, returns how many it wrote.
let black_x: [long; 8] = [0; 8];
def black_x_expect(w: long, h: long) -> long {
    let k = background_black_expect(w, h);
    let i = 0;
    while (i < k && i < 8) { black_x[i] = i; i = i + 1 };
    k
};

// The gradient's exact corners.  floor(255(w-1)/(w-1)) = 255 exactly, so the
// far corner is pure white in all three channels.
def corner_expect(x: long, y: long, w: long, h: long) -> long {
    ((255 * x / (w - 1)) * 65536) + ((255 * y / (h - 1)) * 256)
        + (255 * (x + y) / (w + h - 2))
};
