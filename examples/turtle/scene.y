// scene.y -- the rasteriser: world units to terminal cells, and the pixels.
//
// Everything that touches a framebuffer lives here, so tlang.y stays free of
// tui and can be asserted against by check.y with no surface at all.
//
// ── the view ────────────────────────────────────────────────────────────────
//
// The turtle works in integer world units with y UP; a terminal has y DOWN and
// its cells are about twice as tall as they are wide.  So the view is two
// independent shifts, not one scale:
//
//     col = OX + (x >> SHX)
//     row = OY - (y >> SHY)          -- the minus flips y up onto the screen
//
// and the two shifts are fitted SEPARATELY to the two axes, which is what makes
// a square look like a square: cells being twice as tall as they are wide means
// the y resolution wants one extra shift, and fitting each axis against its own
// usable cells hands it exactly that.  With one shared shift a 100-unit square
// comes out twice as tall as it is wide, which reads as "the drawing is wrong".
//
// A shift, not a rational scale, because a shift is exact integer arithmetic:
// two points the same distance apart in the world are the same number of cells
// apart on the screen, and the whole polygon-closure story survives into the
// picture without a rounding argument.
//
// The fit is computed ONCE per program from the bounding box of the WHOLE
// program, which a dry run (run the same executor with drawing suppressed)
// supplies.  Fitting per frame instead would make the picture jump and rescale
// as the turtle wanders; fitting once means the view is the same for frame 1 and
// for the finished drawing, which is also what makes a golden diff readable.

import tlang;
import tui;

const DEFROWS: long = 24;
const DEFCOLS: long = 80;
const MAXSHIFT: long = 40;
const MARGIN: long = 1;

// The surface.  One tui.new for the whole run -- it allocates 1.5 MiB (six
// 32768-long arrays) and that is the ONE allocation this program makes outside
// the module-level fixed buffers.  tui.resize is allocation-free, so a terminal
// resize mid-run costs nothing.
let SR: long = DEFROWS;
let SC: long = DEFCOLS;
let SRF = tui.new(DEFROWS, DEFCOLS);

let SHX: long = 0;              // the two shifts
let SHY: long = 0;
let OX: long = 0;               // the screen cell that world (0,0) lands on
let OY: long = 0;
let INK: long = 0;              // cells that are no longer blank
let CURSOR: long = 0;           // draw the turtle cursor
let CURCELL: long = 0 - 1;      // where it was drawn last time, to erase it

// A distinct printable glyph per colour, so a monochrome text dump -- the golden
// frame, the --no-tty tail, everything a diff can read -- is still a picture
// rather than a field of dots.  The colour itself rides in the cell foreground,
// so the terminal gets both: shape from the glyph, hue from the fg.
let CG: [str] = ["#", "@", "*", "+", "=", "-", ":", "o", "%", ",", "X", "W",
                 "P", "V", "s", "G"];

// The cursor's eight directions, north first, then the diagonals.
let CARROW: [str] = ["|", "/", "-", "\\", "|", "/", "-", "\\"];

// ───────────────────────────────────────────────────── the projection ───

def cx(x: long) -> long { OX + (x >> SHX) };
def cy(y: long) -> long { OY - (y >> SHY) };

// fit(rows, cols, x0, y0, x1, y1) -- choose the view for a bounding box in
// world units.  Costs two loops of at most MAXSHIFT iterations and allocates
// nothing; called once per program, never per frame.
def fit(rows: long, cols: long, x0: long, y0: long, x1: long, y1: long) -> void {
    SR = rows;
    SC = cols;
    SRF = tui.resize(SRF, rows, cols);
    let cw = cols - 2 * MARGIN;
    let chh = rows - 2 * MARGIN;
    if (cw < 1) { cw = 1 };
    if (chh < 1) { chh = 1 };
    let sx = x1 - x0;
    if (sx < 0) { sx = 0 - sx };
    if (sx < 1) { sx = 1 };
    let sy = y1 - y0;
    if (sy < 0) { sy = 0 - sy };
    if (sy < 1) { sy = 1 };
    SHX = 0;
    let fitx = false;
    while (fitx == false && SHX < MAXSHIFT) {
        if ((sx >> SHX) <= cw) { fitx = true } else { SHX = SHX + 1 }
    };
    SHY = 0;
    let fity = false;
    while (fity == false && SHY < MAXSHIFT) {
        if ((sy >> SHY) <= chh) { fity = true } else { SHY = SHY + 1 }
    };
    // centre the box: the midpoint lands in the middle cell of the surface.
    // The parentheses are for reading, not for correctness: `/` DOES bind
    // tighter than `>>` here (measured on the pinned compiler, `100 / 2 >> 1` is
    // 25 and `100 / 2 >> 3` is 6, so it is (100/2)>>3 and not 100/(2>>3) -- the
    // latter would be a division by zero, since 2>>3 is 0).  An earlier draft of
    // this comment claimed the opposite and blamed it for a picture that sat in
    // the corner; the real cause was `jump` being absolute while the lattice
    // program used it as a relative stride, so the bounding box was a stride
    // wide in the wrong direction.  Recorded here because a wrong explanation
    // left in the source is worse than no explanation.
    OX = cols / 2 - (((x0 + x1) / 2) >> SHX);
    OY = rows / 2 + (((y0 + y1) / 2) >> SHY)
};

// ──────────────────────────────────────────────────────────── drawing ───

// plot(r, c, col) -- one cell.  The INK count is maintained here rather than
// scanned out of the surface afterwards: it is what the per-frame line reports
// as "pixels", and it must count CELLS the drawing has touched, so a line that
// crosses its own tail is not counted twice.  Reading the cell to find out
// whether it was blank is one load, and the alternative -- a full scan of the
// surface every frame to get the same number -- is rows*cols per frame.
def plot(r: long, c: long, col: long) -> void {
    if (r < 0 || r >= SR || c < 0 || c >= SC) { return };
    let i = r * SC + c;
    if (SRF.ch[i] == tui.space) { INK = INK + 1 };
    tui.put_at(SRF, i, byte_at(CG[col], 0), tlang.CRGB[col], tui.DEFAULT)
};

// blank(r, c) -- put a space back, for erasing the cursor.
def blank(r: long, c: long) -> void {
    if (r < 0 || r >= SR || c < 0 || c >= SC) { return };
    let i = r * SC + c;
    if (SRF.ch[i] != tui.space) { INK = INK - 1 };
    tui.put_at(SRF, i, tui.space, tui.DEFAULT, tui.DEFAULT)
};

// line(x0, y0, x1, y1, col) -- a segment, in whole units returned.
//
// The endpoints are mapped to cells first and Bresenham runs over the cells.
// Marching in world units instead would step 10 000 times for a long segment to
// land on the same pixels, and would depend on the shift, so two segments of
// the same length could rasterise differently.  The loop is the standard
// integer Bresenham (dx, dy = -|dy|, err = dx + dy) with a step cap on top:
// err is bounded by dx + |dy| and each pass moves at least one coordinate, but
// a cap costs one compare and removes the possibility of a hang from the one
// place a hang would be worst -- the frame loop, where it would look like "the
// animation is stuck".
def line(x0: long, y0: long, x1: long, y1: long, col: long) -> long {
    let r = cy(y0);
    let c = cx(x0);
    let rc = cy(y1);
    let cc = cx(x1);
    let dx = cc - c;
    if (dx < 0) { dx = 0 - dx };
    let dy = 0 - (if (rc - r < 0) { 0 - (rc - r) } else { rc - r });
    let sx = if (c < cc) { 1 } else { 0 - 1 };
    let sy = if (r < rc) { 1 } else { 0 - 1 };
    let err = dx + dy;
    let n = 0;
    let cap = (SR + SC) * 4 + 8;
    let stop = false;
    while (stop == false) {
        plot(r, c, col);
        n = n + 1;
        if (c == cc && r == rc) { stop = true } else
        if (n >= cap) { stop = true } else {
            let e2 = 2 * err;
            if (e2 >= dy) { err = err + dy; c = c + sx };
            if (e2 <= dx) { err = err + dx; r = r + sy }
        }
    };
    n
};

// dot(x, y, col) -- one cell, for the `dot` command.
def dot(x: long, y: long, col: long) -> long {
    let r = cy(y);
    let c = cx(x);
    plot(r, c, col);
    1
};

// octant(h) -- which of the eight compass directions a heading points at, north
// first.  Integer, so it never lands on a boundary by accident: 225000 is
// exactly the corner of "north" and "north-east" and picks north.
def octant(h: long) -> long {
    let q = (h + 22500) / 45000;
    if (q < 0) { q = 0 };
    if (q > 7) { q = 7 };
    q
};

// draw_cursor(x, y, h) -- the turtle itself, one cell, pointing where it is
// going.  Erased on the next frame by erase_cursor(), so it never smears a
// trail of its own.
def draw_cursor(x: long, y: long, h: long) -> void {
    if (CURSOR == 0) { return };
    let r = cy(y);
    let c = cx(x);
    let i = r * SC + c;
    if (r >= 0 && r < SR && c >= 0 && c < SC) {
        if (SRF.ch[i] == tui.space) { INK = INK + 1 };
        tui.put_at(SRF, i, byte_at(CARROW[octant(h)], 0), tlang.CRGB[7], tui.DEFAULT)
    };
    CURCELL = r * SC + c
};

def erase_cursor() -> void {
    if (CURSOR == 0) { return };
    if (CURCELL < 0) { return };
    let i = CURCELL;
    if (SRF.ch[i] != tui.space) { INK = INK - 1 };
    tui.put_at(SRF, i, tui.space, tui.DEFAULT, tui.DEFAULT);
    CURCELL = 0 - 1
};

// ──────────────────────────────────────────────────────── the frame ───

def clear_frame() -> void {
    tui.clear(SRF, tui.DEFAULT);
    INK = 0;
    CURCELL = 0 - 1
};

// step_draw() -- run one command and draw whatever it produced.  Returns the
// event from tlang.run_one(): 1 a segment, 2 a dot, 0 nothing, 3 the end, 4 an
// error.  One command a call, so the interactive view can step and the headless
// view can run a whole frame's worth, and both go through the same code.
def step_draw() -> long {
    let e = tlang.run_one();
    if (e == 1) {
        line(tlang.SX, tlang.SY, tlang.EX, tlang.EY, tlang.COL)
    } else if (e == 2) {
        dot(tlang.EX, tlang.EY, tlang.COL)
    } else {
        0
    };
    e
};

// draw_all() -- the dry pass plus the fit, then clear.  Returns nothing; the
// caller has the bounding box in tlang afterwards.  run_to_end() is the same
// executor the real frames use, with no drawing, so the fit cannot disagree with
// what is about to be drawn.
def draw_all() -> void {
    tlang.reset();
    tlang.run_to_end();
    fit(SR, SC, tlang.BX0, tlang.BY0, tlang.BX1, tlang.BY1);
    clear_frame();
    tlang.reset()
};

// ────────────────────────────────────────── accessors and the test hook ───
//
// The surface is exported as a value so sink.grid_digest can walk it; these are
// the scalar halves, reached through functions rather than written across a
// module boundary.
def inked() -> long { INK };
def rows() -> long { SR };
def cols() -> long { SC };
def shift_x() -> long { SHX };
def shift_y() -> long { SHY };

def set_size(r: long, c: long) -> void {
    SR = r;
    SC = c;
    SRF = tui.resize(SRF, r, c)
};

// perturb() -- flip ONE cell in the middle of the surface: a space becomes a
// glyph, a glyph becomes a space.  This exists for the property check, which has
// to be able to change exactly one byte of a rendered frame and prove that the
// capture checksum notices.  It is on no drawing path and nothing calls it but
// check.y.
def perturb() -> long {
    let r = SR / 2;
    let c = SC / 2;
    if (r < 0 || r >= SR || c < 0 || c >= SC) { return 0 };
    let i = r * SC + c;
    if (SRF.ch[i] == tui.space) {
        INK = INK + 1;
        tui.put_at(SRF, i, 64, tlang.CRGB[1], tui.DEFAULT)
    } else {
        INK = INK - 1;
        tui.put_at(SRF, i, tui.space, tui.DEFAULT, tui.DEFAULT)
    };
    1
};

// fixed_view(shx, shy, ox, oy) -- force the projection.  This exists for the
// property check's pen assertions, which compare the DIGEST of two programs'
// output: the automatic fit is derived from each program's own bounding box, so
// two programs with different extents get different views and their frames are
// not comparable at all.  Forcing one view for both turns "the pen-up move drew
// nothing" into a byte-for-byte comparison instead of an argument.
def fixed_view(sx: long, sy: long, ox: long, oy: long) -> void {
    SHX = sx;
    SHY = sy;
    OX = ox;
    OY = oy
};

// poke(r, c, what) -- change ONE thing about one cell and nothing else:
//   0  the codepoint (a space becomes '@', an '@' becomes a space)
//   1  the FOREGROUND COLOUR only, leaving the codepoint alone
//   2  the BACKGROUND only
// It exists for the property check's digest-channel assertions.  They need to
// know that the frame digest really does watch all three channels, and the only
// honest way to show that is to change one channel at a time: two programs
// drawing the same shape in two colours differ in the glyph as well as the
// colour, so a digest that watched only the glyph would still pass.
def poke(r: long, c: long, what: long) -> long {
    if (r < 0 || r >= SR || c < 0 || c >= SC) { return 0 };
    let i = r * SC + c;
    if (what == 0) {
        if (SRF.ch[i] == tui.space) {
            INK = INK + 1;
            tui.put_at(SRF, i, 64, tlang.CRGB[1], tui.DEFAULT)
        } else {
            INK = INK - 1;
            tui.put_at(SRF, i, tui.space, tui.DEFAULT, tui.DEFAULT)
        }
    } else if (what == 1) {
        tui.put_at(SRF, i, SRF.ch[i], tlang.CRGB[4], tui.DEFAULT)
    } else {
        tui.put_at(SRF, i, SRF.ch[i], tlang.CRGB[1], tlang.CRGB[2])
    };
    1
};

// blank_cells() -- cells still holding a space, counted from the SURFACE rather
// than taken from INK's complement, so a counter that stopped being maintained
// cannot make a check vacuously true.  The pen-up assertions use both numbers
// and require them to agree.
def blank_cells() -> long {
    let n = 0;
    let k = 0;
    let tot = SR * SC;
    while (k < tot) {
        if (SRF.ch[k] == tui.space) { n = n + 1 };
        k = k + 1
    };
    n
};

export { DEFROWS, DEFCOLS, MAXSHIFT, MARGIN, SR, SC, SRF, SHX, SHY, OX, OY,
          INK, CURSOR, CG, CARROW,
          cx, cy, fit, plot, blank, line, dot, octant, draw_cursor, erase_cursor,
          clear_frame, step_draw, draw_all,
          inked, rows, cols, shift_x, shift_y, set_size, perturb,
          fixed_view, poke, blank_cells };