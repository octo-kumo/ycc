// torus.y -- Andy Sloane's torus, rasterised into an tui.Surface.
//
// Vendored beside donut.y.  This file is the
// geometry and nothing else: the CLI, the palettes and the frame loop live in
// donut.y, and the terminal, the framebuffer, the maths and the pacing live in
// the toolkit copies next to it.
//
// ── THE SURFACE, AND WHY ALL OF IT IS INTEGER ──────────────────────────────
//
// Y has no `float` -> `long` conversion and no cast syntax at all
//, and no sin/cos (2.4b), so the whole pipeline is
// fx.y's Q30 fixed point (1.0 == 2^30).  There is never a float anywhere in
// this file and never a conversion at a frame boundary.
//
// The one place a conversion *looks* like it happens is the projection, and it
// is written so that it is a plain integer multiply and a plain integer divide
// on longs -- no fx.mul, no fx.fdiv, no scaling by fx.ONE:
//
//     px = (x * scl) / den          den = z + K2   (all Q30)
//
// `x` is at most R2+R1 = 3 in Q30 and `scl` is a few hundred, so `x * scl` is
// around 1e12 and the quotient lands in subpixel units.  That is why `scl` is a
// plain integer here and not a Q30 constant: keeping it integral is what makes
// the hot path two machine ops instead of a Q30 multiply.
//
// ── THE SUBPIXEL GRID ──────────────────────────────────────────────────────
//
// A terminal cell is about twice as tall as it is wide, so square subpixels are
// 2 across by 4 down a cell -- exactly the braille geometry.  One cell is
// therefore eight subpixels, each with its own z-buffer entry, and a cell's
// glyph is the COVERAGE of its eight dots through fb's ramp.
//
// Coverage is the right thing to key a glyph on, and not brightness: the
// surface is sampled at roughly twice the subpixel density, so a spot where
// three dots out of eight were hit is genuinely a thinner part of the torus
// and the ramp should say so.  Keying the glyph on brightness instead would
// make a hole look full, which is the single thing that makes an ASCII torus
// read as broken.
//
// ── PER-FRAME ALLOCATION: none ─────────────────────────────────────────────
//
// The heap is an arena and nothing is ever freed, so
// every buffer here is a module-level fixed `[long; N]` and the frame loop only
// writes into them.  `torus_setup` writes tables; `torus_step` and
// `torus_draw` allocate nothing at all.  donut.y proves it with heap_used().
//
// ── THE SAMPLE GRID, AND WHY THE TRIG IS A STARTUP TABLE ──────────────────
//
// The torus is sampled on a fixed na x nb grid of (theta, phi), so cos and sin
// of those angles never change between frames.  Only the two rotation angles A
// and B move.  That is why there is no trigonometry in the inner loop at all:
//
//   startup   CT[i], ST[i] = cos/sin(2*pi*i/na), and CF[j], SF[j] likewise;
//             WI[i] = R2 + cos(theta_i)
//   per frame cos(A), sin(A), cos(B), sin(B): four calls, then the j and i
//             tables are rotated into the world frame
//   per sample four Q30 multiplies and nothing else
//
// ── THE TRANSFORM, DERIVED ─────────────────────────────────────────────────
//
// A point of the torus with R1 = 1:
//
//     P = ((R2 + cos theta) cos phi, (R2 + cos theta) sin phi, sin theta)
//
// rotated by B about z and then by A about x.  Folding phi + B first --
// because Rz(B) turns the pair ((R2+cos t)cos p, (R2+cos t) sin p) into
// ((R2+cos t) cos(p+B), (R2+cos t) sin(p+B)) exactly -- collapses the whole
// frame to
//
//     X = (R2 + cos theta) cos(phi + B)      <- already in Q30
//     Y = (R2 + cos theta) sin(phi + B)
//     y = Y cos A - sin theta sin A         <- rotation about x
//     z = Y sin A + sin theta cos A
//
// and the projection is x/z = X/(z + K2), y/z = y/(z + K2) with K2 the camera
// distance.  That is four multiplies a sample, and the algebra is the same one
// in Sloane's original: it is only rotated so the trigonometry can be hoisted.
//
// The surface normal is (cos theta cos psi, cos theta sin psi, sin theta)
// carried through the same two rotations, which lands on (nx, y, z) with the
// normal's x component equal to X's direction.  Lit from (0, 1, -1) --
// Sloane's light -- the dot product is therefore simply
//
//     L = ny - nz = y - z
//
// which is already computed, so the luminance is free: no extra normal, no
// extra rotation, no sqrt.  It runs over +-sqrt(2), and SQ2 is sqrt(2) in Q30.

import fx;
import tui;

// ---------------------------------------------------------------- shape ----

const R1: long = 1073741824;          // R1 = 1.0 in Q30 -- kept for the record
const R2: long = 2147483648;          // R2 = 2.0
const K2: long = 5368709120;          // K2 = 5.0, the camera distance
const SQ2: long = 1518500249;         // sqrt(2), for the luminance scale

const NMAX: long = 400;               // samples per torus angle, at most
const COLS_MAX: long = 200;           // surface columns, at most
const ROWS_MAX: long = 100;           // surface rows, at most
const SUBW: long = 2;                 // subpixels across one cell
const SUBH: long = 4;                 // subpixels down one cell
const SUB_MAX: long = 160000;         // SUBW*COLS_MAX * SUBH*ROWS_MAX
const EMPTY: long = 9223372036854775807;   // "no surface here" in ZB
const EXT_STRIDE: long = 3;            // stride of the framing sweep

// ---------------------------------------------------------------- state ----

let na: long = 16;                    // samples around the tube (theta)
let nb: long = 16;                    // samples around the ring (phi)
let srows: long = 1;                  // surface rows
let scols: long = 1;                  // surface columns
let sw: long = SUBW;                  // subpixel columns
let sh: long = SUBH;                  // subpixel rows
let midx: long = 0;                   // subpixel centre, x
let midy: long = 0;                   // subpixel centre, y
let scl: long = 1;                    // projection scale, plain integer
let angA: long = 0;                   // rotation about x, Q30
let angB: long = 0;                   // rotation about z, Q30
let covered: long = 0;                // subpixels hit by the last frame
let missed: long = 0;                 // samples projected outside the frame
let extent: long = 1073741824;        // worst |x/(z+K2)| over all A, Q30
let drawn: long = 0;                  // cells with surface, in the last draw
let samples: long = 0;                // samples rasterised per frame

// Per-angle tables.  CT/ST are theta (fixed forever), CF/SF are phi (fixed
// forever), CR/SR are phi+B (rewritten each frame), WI is R2+cos(theta), and
// AS/AC are sin(theta) rotated into the world frame (rewritten each frame).
let CT: [long; 400] = [0; 400];
let ST: [long; 400] = [0; 400];
let CF: [long; 400] = [0; 400];
let SF: [long; 400] = [0; 400];
let CR: [long; 400] = [0; 400];
let SR: [long; 400] = [0; 400];
let WI: [long; 400] = [0; 400];
let AS: [long; 400] = [0; 400];
let AC: [long; 400] = [0; 400];

// The two per-subpixel buffers, allocated whole once and never grown.
// ZB is the nearest depth seen, EMPTY where nothing was drawn; LB is the
// luminance of whatever got there.
let ZB: [long; 160000] = [0; 160000];
let LB: [long; 160000] = [0; 160000];

// The palette a draw needs, so donut.y owns the colours and this file owns
// only the coverage.
type Pal = { lo: long, hi: long, bg: long, flat: long, mono_fg: long };

// ONE palette, held by the module, written once by torus_palette().
//
// Not a convenience: a record LITERAL allocates 64 bytes every time the
// expression is evaluated (measured, see donut.y's sline), so a palette built
// inside torus_draw would leak 64 bytes a frame for the life of the program.
// Records passed to a def are by reference and cost nothing, so this is a
// module-level binding rather than a parameter -- but the binding has to exist,
// and there has to be exactly one of it.
let PAL: Pal = { lo: 0, hi: 0, bg: 0, flat: 1, mono_fg: 0 };

// torus_palette(lo, hi, bg, flat, mono_fg) -> void -- the colours this module
// draws with.  `flat` is 1 for mono, where every glyph is `mono_fg`.
def torus_palette(lo: long, hi: long, bg: long, flat: long, mono_fg: long) -> void {
    PAL.lo = lo;
    PAL.hi = hi;
    PAL.bg = bg;
    PAL.flat = flat;
    PAL.mono_fg = mono_fg
};

// ---------------------------------------------------------------- setup ----

def clampi(v: long, lo: long, hi: long) -> long {
    if (v < lo) { return lo; };
    if (v > hi) { return hi; };
    v
};

// torus_reset() -- back to the start pose.  A = B = 0 is the iconic
// face-on ring, which is what a golden frame should show.
def torus_reset() -> void {
    angA = 0;
    angB = 0
};

// torus_setup(rows, cols) -> long -- pick the geometry for a surface of
// `rows` x `cols` cells and build the trig tables.  Called once at start-up
// (and again after a terminal resize, which is safe: it allocates nothing).
// Returns the sample count per frame.
def torus_setup(rows: long, cols: long) -> long {
    srows = clampi(rows, 1, ROWS_MAX);
    scols = clampi(cols, 1, COLS_MAX);
    sw = scols * SUBW;
    sh = srows * SUBH;
    midx = sw / 2;
    midy = sh / 2;

    // px = (x * scl) / den is (x / (z + K2)) * scl, so scl is how many
    // subpixels one unit of "x over z+K2" is worth.  The worst value of that
    // ratio over the surface depends on the orientation -- a torus seen
    // edge-on projects further than one seen face-on -- so instead of guessing a
    // constant, MEASURE it: 24 orientations of A against a strided sample of
    // the grid, taking the largest |x/(z+K2)| and |y/(z+K2)| seen.  A few
    // thousand iterations, once, and it is why the torus fits at every angle
    // and every terminal size instead of clipping at the end of its range.
    //
    // The ratio is carried in Q30 so the guard below can be a comparison
    // against fx.ONE; as a bare real it is under 1, and a guard against 1
    // would swallow the real answer.
    let m = if (sw < sh) { sw } else { sh };
    let extq: long = fx.ONE;
    for k in 0..24 {
        let a = (fx.TWO_PI * k) / 24;
        let ca = fx.cos(a);
        let sa = fx.sin(a);
        let i = 0;
        while (i < na) {
            let w = WI[i];
            let as_i = fx.mul(ST[i], sa);
            let ac_i = fx.mul(ST[i], ca);
            let j = 0;
            while (j < nb) {
                let x = fx.mul(w, CF[j]);
                let y0 = fx.mul(w, SF[j]);
                let y = fx.mul(y0, ca) - as_i;
                let z = fx.mul(y0, sa) + ac_i;
                let den = z + K2;
                if (den > 0) {
                    let ex = fx.abs(x) * fx.ONE / den;
                    let ey = fx.abs(y) * fx.ONE / den;
                    if (ex > extq) { extq = ex; };
                    if (ey > extq) { extq = ey; };
                };
                j = j + EXT_STRIDE;
            };
            i = i + EXT_STRIDE;
        };
    };
    if (extq < fx.ONE) { extq = fx.ONE; };
    // Half the smaller side, to 46%: the torus fills most of the frame at
    // every angle and never touches the edge.  Plain integers throughout --
    // min(), a multiply, two divides -- which is what keeps the hot loop off
    // the fixed-point path entirely.  The floor stops a one-cell surface from
    // dividing by zero; it renders as a dot rather than failing.
    let half = (m * 46) / 100;
    scl = (half * fx.ONE) / extq;
    if (scl < 1) { scl = 1; };
    extent = extq;

    // About two samples per subpixel is the density at which the coverage of a
    // cell is essentially complete; isqrt(2*sw*sh) gives na == nb with that
    // product, and it is a function of the size alone, so the sample grid is
    // as deterministic as everything else.
    let want = fx.isqrt(2 * sw * sh);
    na = clampi(want, 24, NMAX);
    nb = na;
    samples = na * nb;

    for i in 0..na {
        let th = (fx.TWO_PI * i) / na;
        CT[i] = fx.cos(th);
        ST[i] = fx.sin(th);
        WI[i] = R2 + CT[i];
    };
    for j in 0..nb {
        let ph = (fx.TWO_PI * j) / nb;
        CF[j] = fx.cos(ph);
        SF[j] = fx.sin(ph);
    };
    samples
};

// ---------------------------------------------------------------- frame ----

// torus_step(a_step, b_step) -> void -- advance both rotation angles by a Q30
// step each and rasterise the surface into ZB/LB.  Allocates nothing.
def torus_step(a_step: long, b_step: long) -> void {
    angA = fx.wrap_2pi(angA + a_step);
    angB = fx.wrap_2pi(angB + b_step);
    let ca = fx.cos(angA);
    let sa = fx.sin(angA);
    let cb = fx.cos(angB);
    let sb = fx.sin(angB);

    // phi -> phi + B, on the j axis only: 4 multiplies per sample index rather
    // than 4 per sample.
    for j in 0..nb {
        CR[j] = fx.mul(CF[j], cb) - fx.mul(SF[j], sb);
        SR[j] = fx.mul(CF[j], sb) + fx.mul(SF[j], cb);
    };
    // sin(theta) rotated by A, on the i axis only.
    for i in 0..na {
        AS[i] = fx.mul(ST[i], sa);
        AC[i] = fx.mul(ST[i], ca);
    };

    // Clear the depth buffer.  This is the one unavoidable per-frame pass
    // over the subpixels, and it is a plain fill of an existing array.
    let n = sw * sh;
    for k in 0..n {
        ZB[k] = EMPTY;
    };

    let hits = 0;
    let off = 0;
    for i in 0..na {
        let w = WI[i];
        let as_i = AS[i];
        let ac_i = AC[i];
        for j in 0..nb {
            let x = fx.mul(w, CR[j]);
            let yy0 = fx.mul(w, SR[j]);
            let y = fx.mul(yy0, ca) - as_i;
            let z = fx.mul(yy0, sa) + ac_i;
            let den = z + K2;
            // den > 0 guards the two divides below.  With R1 = 1 and R2 = 2
            // the surface's |z| is at most sqrt(10) < K2, so it cannot happen
            // -- and a division by zero traps to STDOUT (2.6), which would
            // splice a message into the middle of a frame.  The test costs one
            // compare and buys an example that cannot corrupt its own output.
            if (den > 0) {
                let px = (x * scl) / den + midx;
                let py = midy - (y * scl) / den;
                if (px >= 0 && px < sw && py >= 0 && py < sh) {
                    let k = py * sw + px;
                    if (den < ZB[k]) {
                        ZB[k] = den;
                        // L = ny - nz = y - z, the normal against the light
                        // (0,1,-1).  It runs over +-sqrt(2), so this maps it
                        // onto 0..256 with no scaling by fx.ONE anywhere.
                        let lum = ((y - z + SQ2) * 128) / SQ2;
                        LB[k] = if (lum > 255) { 255 } else { lum };
                        hits = hits + 1;
                    };
                } else {
                    off = off + 1;
                };
            };
        };
    };
    covered = hits;
    missed = off
};

// torus_draw(s, gm, p) -> void -- turn the depth buffer into cells.
//
// Two different things want the glyph, and this is where the choice is made:
//
//   ascii / blocks / half   the glyph is the LUMINANCE of the nearest subpixel
//       the surface won.  That is the classic donut, and it is what a ramp is
//       for: the ramp steps ARE an intensity scale, so a cell the eye reads as
//       a shaded surface gets the glyph that reads as that shade.  Coverage
//       would be wrong here -- inside the silhouette coverage saturates at 8 of
//       8, so every cell in the body of the torus would come out as the same
//       full block and the picture would read as a blob.
//   braille   the glyph is the COVERAGE of the eight dots, one bit each, which
//       is the whole point of a 2x4 dot cell: it is a bitmap, not a shade.
//
// Either way the colour comes from the same luminance, so the tinted modes
// shade the surface continuously while ascii puts the shading in the glyph.
// `p.flat` is 1 in mono mode, where every glyph is one colour.
def torus_draw(s: tui.Surface, gm: long) -> void {
    let n = 0;
    let cols = if (s.cols < scols) { s.cols } else { scols };
    let rows = if (s.rows < srows) { s.rows } else { srows };
    for r in 0..rows {
        for c in 0..cols {
            let base = (r * SUBH) * sw + c * SUBW;
            let cov = 0;
            let bd = EMPTY;
            let bl = 0;
            for q in 0..SUBH {
                let row0 = base + q * sw;
                for t in 0..SUBW {
                    let d = ZB[row0 + t];
                    if (d != EMPTY) {
                        cov = cov + 1;
                        if (d < bd) {
                            bd = d;
                            bl = LB[row0 + t];
                        };
                    };
                };
            };
            let fg = PAL.bg;
            let cp = 32;
            if (cov > 0) {
                if (gm == 3) {
                    cp = tui.braille_cp(tui.braille_mask(cov));
                } else {
                    cp = torus_shade(bl, gm);
                };
                if (PAL.flat != 0) {
                    fg = PAL.mono_fg;
                } else {
                    fg = tui.lerp_rgb(PAL.lo, PAL.hi, bl);
                };
                n = n + 1;
            };
            tui.put(s, r, c, cp, fg, PAL.bg);
        };
    };
    drawn = n
};

// torus_shade(lum, gm) -- luminance 0..256 through fb's ramps.  The span is
// 256 rather than 255 because that is the scale the projection produces, and
// tui.ramp_index is monotonic in both arguments, so the ramp cannot invert.
def torus_shade(lum: long, gm: long) -> long {
    if (gm == 1) { return tui.shade_blocks(lum, 256); };
    if (gm == 2) { return tui.shade_half(lum, 256); };
    tui.shade_ascii(lum, 256)
};

// torus_rows() / torus_cols() -- the geometry torus_setup actually chose, so
// donut.y can size its surface to match exactly.
def torus_rows() -> long { srows };
def torus_cols() -> long { scols };
def torus_samples() -> long { samples };
def torus_covered() -> long { covered };
def torus_missed() -> long { missed };
def torus_extent() -> long { extent };
def torus_drawn() -> long { drawn };
def torus_a() -> long { angA };
def torus_b() -> long { angB };

export { Pal, R1, R2, K2, NMAX, COLS_MAX, ROWS_MAX, torus_palette,
          torus_reset, torus_setup, torus_step, torus_draw, torus_shade,
          torus_rows, torus_cols, torus_samples, torus_covered, torus_missed, torus_extent,
          torus_a, torus_b };