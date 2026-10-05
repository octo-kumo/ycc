// mandel.y -- the set itself: the iteration, the continuous (smooth) colouring
// and the palettes, all in Q30 fixed point with no float anywhere.
//
// WHY Q30 AND NOT A FLOAT.  Y has no `float` -> `long` and no cast syntax at
// all (ORCHESTRATOR.md 2.4a), so a coordinate a program computes can never
// leave a float: it would have to come back as an integer to index a pixel.
// Every number here is a `long` holding a real number scaled by 2^30
// (fx.ONE), so `xr` is the real part of a point in the complex plane and
// fx.mul/fx.fdiv are the arithmetic.
//
// ===========================================================================
// THE OVERFLOW STRATEGY -- read this, it is the whole design
// ===========================================================================
//
// The textbook iteration is
//
//     z <- z*z + c          i.e.   x' = x*x - y*y + cx
//                                   y' = 2*x*y + cy
//     escape when x*x + y*y > 4
//
// and in Q30 it overflows if you write it the obvious way, because
// `x*x` is then a Q60 number: x is 2^30 when x_real is 1, and the product
// needs 62 bits, and the SUM of the two squares needs 63.  The moment the
// point escapes, x can be up to |z|^2 + |c| ~ 6.5 and y up to ~8.6, so
// squaring THAT needs 66 bits and wraps to a small number -- which is not a
// wrong picture, it is a picture of the wrong thing: the orbit looks bounded
// again and the pixel is reported as inside the set.
//
// The fix has two halves, and both are needed.
//
// (1) EVERY PRODUCT GOES THROUGH fx.mul, WHICH CANNOT OVERFLOW.  fx.mul's
//     fast lane only forms x*y when one operand is under 2^32 and the other
//     under 2^31; anything bigger falls through to mul_wide(), which builds
//     the full 124-bit product in 16-bit limbs and keeps the bits.  So
//     fx.mul(7e9, 7e9) -- a product that does not fit in 64 bits -- answers
//     correctly.  A raw `zr * zr` does not.  This is why this file has no
//     bare multiplication of two coordinates anywhere.
//
// (2) THE ITERATE IS NEVER UNBOUNDED, so the products are small anyway.  The
//     loop tests the escape condition at the TOP of each iteration, on the
//     z it is about to square.  So the only z ever squared satisfies
//     |z|^2 < 4, i.e. |x|,|y| < 2 -- every product is then under 2^62 and
//     even a naive `x*x` would have been fine.  The escape test itself is
//     evaluated on a z that has NOT yet been through the test, so it is the
//     one place a big product appears, and it is exactly the place fx.mul is
//     needed.  After the update, |x|,|y| <= 6.5, so nothing after it squares
//     anything either.
//
// The magnitude the colouring needs is computed at the same place, from the
// same two fx.mul calls, so it costs nothing extra and cannot overflow.
//
// NOT DONE, ON PURPOSE: no cardioid/bulb early-out.  It is the classic speed
// trick and it is also three extra multiplies and four comparisons per pixel
// for a test most cheap renderers do not need; at these sizes the palette
// lookup and the smooth log dominate.  `--maxit` is the speed knob here.
//
// ===========================================================================
// THE SMOOTH COLOURING, AND WHY THERE IS NO SQRT IN IT
// ===========================================================================
//
// Bands of equal integer iteration count are what makes a Mandelbrot look
// cheap.  The continuous escape time
//
//     sm = n + 1 - log2(log|z|)
//
// removes the banding, because log|z| carries where in the last step the
// point left.  It needs a logarithm, and Y has none -- not even in fx.y,
// which is trigonometry and roots only.  So `ln` is written here, in 25
// lines: peel the binary exponent off x to leave m in [1,2), then
// atanh's series ln(m) = 2(u + u^3/3 + u^5/5 + ...) with u = (m-1)/(m+1),
// which is at most 1/3 in magnitude and so loses a factor of nine per term.
// Eight terms put the error at 6.6e-9 absolute over x in [0.125, 200],
// measured against IEEE-754 -- and the whole argument is divided by ln2 and
// multiplied by 256 bands, so that is 3e-9 of a band.
//
// The sqrt really is avoidable.  sm wants log|z| and |z| = sqrt(zr^2+zi^2),
// so with m2 = zr^2+zi^2 already in hand,
//
//     log|z| = log(sqrt(m2)) = 0.5 * log(m2)
//
// and the root never has to exist.  That matters for more than elegance: fx
// .sqrt's own input range tops out near 2^33 and m2 at the moment of escape
// is up to 1.3e11, so a sqrt of the raw m2 would have been out of range.  The
// log route has no range question at all.
//
// ===========================================================================
// ZERO ALLOCATION
// ===========================================================================
//
// The heap is an arena and nothing is ever freed (ORCHESTRATOR.md 2.7), so
// every table here is a module-level fixed array and md_shade() -- the
// function that runs once per pixel, up to 32768 times a frame -- builds
// nothing at all: no string, no record, no array literal, no closure.  The
// 256-entry palette table is filled ONCE by set_palette() and is then a
// lookup.  md_shade() returns a packed long so the caller gets the
// iteration count without an out-parameter, which would have needed a
// per-thread scratch array and therefore shared mutable state.

import fx;
import random;

// ln(2) * 2^30, rounded.  The one constant this file needs that fx does not
// have; fx.PI is there because pi is a length, not a ratio.
const LN2: long = 744261118;

// The escape radius, SQUARED, in Q30: 4.0.  Tested as `m2 >= ER2` because the
// test is on the square, which is what the iteration computes anyway, so the
// escape test costs one compare and no multiplication.
const ER2: long = 4294967296;

// 8.0 in Q30.  A view centre outside [-8, 8] is meaningless for this set, so
// this doubles as parse_q30()'s "that was not a number" answer and no valid
// coordinate can collide with it.
const Q30_BAD: long = 8589934592;

// The packed shade: bits 0..8 are the cell (0 = inside the set, 1..256 is
// band + 1) and the rest is the iteration count.  Nine bits, because a band
// index is 0..255 and +1 has to stay distinguishable from 0.
const CELL_MASK: long = 511;

// Packed shade built for a pixel that reached the iteration cap.
const SHADE_FULL: long = 0;

const PALN: long = 256;            // palette table entries == bands

// The default view: 3.6 real units across, which is x in [-2.4, 1.2] -- the
// whole set with a little margin -- and y in [-1.8, 1.8].
const SPAN0: long = 3865470566;     // 3.6 * fx.ONE

// ln's series length.  Eight terms: the last is u^15/15 with |u| <= 1/3, so
// it is under 5e-9 -- see the header.
const LN_TERMS: long = 8;

// ───────────────────────────────────────────────────────────── palette ───
// Palette kinds.  `random` is index 5 and is built from --seed instead of
// from PP, which is why it is one past the table.
const P_BLUE: long = 0;
const P_EMBER: long = 1;
const P_ICE: long = 2;
const P_MONO: long = 3;
const P_GRASS: long = 4;
const P_RANDOM: long = 5;

let PNAMES: [str] = ["blue", "ember", "ice", "mono", "grass", "random"];

// PP is twelve numbers per palette, in PERCENT so the table is readable and
// the constants are not hand-converted 2^30 scalings of 0.35 and 0.55:
//   a.r a.g a.b    the midpoint the cosine swings about
//   b.r b.g b.b    the amplitude
//   d.r d.g d.b    the frequency, in cycles across the 256 bands
//   c.r c.g c.b    the phase offset, in cycles
// A cosine palette, c(v) = clamp255((a + b*cos(2*pi*(d*v + c)))*255) with v
// the band as a fraction: the standard trick for a smooth, cyclic colour
// ramp that costs one table build and then one array read per pixel.
let PP: [long; 60] = [
    50,  50,  50,    50,  50,  50,    100, 100, 100,     0,  15,  30,   // blue
    50,  35,  15,    50,  40,  30,    100, 100, 100,     0,   5,  12,   // ember
    45,  55,  65,    35,  35,  35,    100, 100, 100,    55,  65,  75,   // ice
    50,  50,  50,    50,  50,  50,      0,   0,   0,      0,   0,   0,   // mono
    40,  50,  35,    40,  45,  35,    100, 100, 100,    30,  50,  20    // grass
];

// The palette as built, and the row of PP it was built from (or, for
// `random`, the generated row).  Module level, filled once.
let CUR: [long; 12] = [50; 12];
let PAL: [long; 256] = [0; 256];
let IN_BG: long = 0;

// ───────────────────────────────────────────────────────────────── view ───
//
// The view is four longs of module state rather than a record, because a
// record is a heap object and this is read once per worker per frame.  It is
// written under VLK and snapshotted under the same lock, so a worker never
// sees half of a new view and a new view never lands mid-frame.
let VLK = mutex();
let vcx: long = -644245094;         // -0.6, the whole set
let vcy: long = 0;
let vspan: long = SPAN0;
let vmaxit: long = 240;

// ─────────────────────────────────────────────────────────────── the log ───

// ln(x) for x > 0, in Q30.  Returns 0 for x <= 0 rather than trapping: the
// caller guarantees a positive argument (see the header) but a log that
// trapped would be a trap on the render path, and 0 is a harmless answer for
// a value nothing is going to plot.
def ln(x: long) -> long {
    if (x <= 0) { return 0; };
    // Peel the binary exponent: m = x / 2^k ends up in [1,2).  A loop rather
    // than a count-leading-zeros because there is no clz in Y.
    let k: long = 0;
    let m = x;
    while (m >= fx.TWO) { m = m >>> 1; k = k + 1; };
    while (m < fx.ONE) { m = m << 1; k = k - 1; };
    // ln(m) = 2*atanh(u), u = (m-1)/(m+1), |u| <= 1/3 here.
    let u = fx.fdiv(m - fx.ONE, m + fx.ONE);
    let u2 = fx.mul(u, u);
    let s = u;
    let p = u;
    let n: long = 1;
    while (n < LN_TERMS) {
        p = fx.mul(p, u2);
        let d = 2 * n + 1;
        s = s + (p + d / 2) / d;
        n = n + 1;
    };
    k * LN2 + 2 * s
};

// ln(x) / ln(2) -- log base 2.  One multiply's worth of extra work and it
// makes the smooth formula read the way it is written.
def log2p(x: long) -> long {
    fx.fdiv(ln(x), LN2)
};

// ─────────────────────────────────────────────────── the escape iteration ───

// md_shade(xr, yr, maxit) -> long
//
// The whole per-pixel cost of this program, and the only function on the
// render path.  Returns the packed shade: bits 0..8 the cell, the rest the
// number of iterations performed.
//
// The escape test is at the TOP of the loop and is on the z about to be
// squared -- see (2) in the header.  There is no `break`, so the guard flag
// `done` and the `if/else` do the early exit: the test sets done and leaves
// z alone, and the else arm is the update.
def md_shade(xr: long, yr: long, maxit: long) -> long {
    let zr: long = 0;
    let zi: long = 0;
    let n: long = 0;
    let done: long = 0;
    // Hoisted out of the loop because the smooth term needs the magnitude at
    // the moment of escape, which is the last value this ever takes.  A `let`
    // inside the arm would be scoped to the arm.
    let m2: long = 0;
    while (n < maxit && done == 0) {
        let a = fx.mul(zr, zr);
        let b = fx.mul(zi, zi);
        m2 = a + b;
        if (m2 >= ER2) {
            done = 1;
        } else {
            let c2 = fx.mul(zr, zi);
            zr = a - b + xr;
            zi = c2 + c2 + yr;
            n = n + 1;
        };
    };
    if (done == 0) {
        // It survived maxit iterations: inside the set.  The iteration count
        // still matters for the mean, so it is packed in as usual.
        return maxit << 9
    };
    // Continuous escape time.  m2 is the square of the modulus at the moment
    // of escape, and log|z| = 0.5*log(m2), so no root is formed (header).
    // m2 >= ER2 = 4, so log(m2) >= 1.386 and half of it is 0.693 > 0: the
    // inner log always has a positive argument and cannot hit the x <= 0 arm.
    //
    // The band is the FRACTIONAL part of sm scaled to the palette, which is the
    // textbook continuous colouring and the reason the image has no flat
    // contour steps in it.  One honest limitation, measured rather than
    // assumed: at deep zoom the level sets of the escape-time function get
    // closer together than a cell, so frac(sm) runs through a whole cycle
    // between neighbouring cells and the frame turns to fine texture.  At
    // --at=seahorse (span 0.01, 2^8.5) it is already busy; by 2^15 it is
    // static.  That is what a continuous colouring does when the thing it is
    // colouring is finer than the display, and the alternative -- banding by the
    // integer iteration count -- trades it for contour rings that look worse
    // everywhere else: measured, `n % 24` with a ten-step dither inside each
    // ring paints the whole far field blank, because far-field points escape at
    // n = 1 or 2 and those two rings land on the emptiest glyphs.  The named
    // views below are given spans that keep the picture legible, and --zoom is
    // the knob when you want to go past them.
    let sm = fx.from_int(n + 1) - log2p(ln(m2) / 2);
    let fr = sm - fx.floor(sm);
    let band = (fr * PALN) >>> 30;
    if (band < 0) { return (n << 9) + 1; };
    if (band > PALN - 1) { return (n << 9) + PALN; };
    (n << 9) + band + 1
};

// md_cell(shade) -> long -- the cell field: 0 inside, 1..256 outside.
def md_cell(shade: long) -> long { shade & CELL_MASK };

// md_iters(shade) -> long -- how many iterations this pixel took.
def md_iters(shade: long) -> long { shade >> 9 };

// ─────────────────────────────────────────────────────────────── palette ───

// lum(c) -> long -- 0..255 perceptual luminance of a packed 0xRRGGBB.  The
// usual integer weights (77, 150, 29) so the sum is 256 and the shift is a
// divide rather than a multiply.
def lum(c: long) -> long {
    let r = (c >> 16) & 255;
    let g = (c >> 8) & 255;
    let b = c & 255;
    (r * 77 + g * 150 + b * 29) >> 8
};

// chan(k, v) -> long -- one channel of the cosine palette at band fraction v.
// CUR holds percentages; the whole expression stays in Q30 until the last
// divide by 100, and fx.mul is used for every product so the phase term
// (2*pi*(d*v + c), which for d = 1 and v = 1 is 2*pi*2^30 squared) cannot
// overflow.
def chan(k: long, v: long) -> long {
    let i = k * 4;
    let a = CUR[i];
    let b = CUR[i + 1];
    let d = CUR[i + 2];
    let c = CUR[i + 3];
    let ph = fx.mul(fx.from_int(d), v) + fx.from_int(c);
    let s = fx.from_int(a) + fx.mul(fx.from_int(b), fx.cos(fx.mul(fx.TWO_PI, ph)));
    let q = s / 100;
    if (q < 0) { return 0; };
    if (q > 255) { return 255; };
    q
};

// ─────────────────────────────────────────────────────── the seed and rng ───
//
// The randomness is std's (import random at the top of this file): this was a
// 31-bit LCG, s' = (s*1103515245 + 12345) mod 2^31, in a module-level
// `rng_state`, drawn as `s >>> 1`.  What the two consumers here need is
// "a uniform number in [0, 1)", for a cosine palette's amplitude and for a
// random view centre -- nothing more -- and `random.below(fx.ONE)` is that.
// fx.ONE is a power of two, so below()'s rejection loop cannot reject.
//
// rnd_unit() stays because "a Q30 value in [0, 1)" is this file's own unit and
// both call sites want that name, not a bare modulus; it is one line now.  The
// old `rnd_seed()` normalisation is gone with the generator: it existed to fold
// a seed into [0, 2^31) and to keep 0 off a fixed point, and mandelbrot.y
// already normalises --seed into [0, 2^31) before it reaches here (see the note
// there), which is where the printed-header agreement lives.
//
// Both consumers run on the MAIN thread -- set_palette() at start-up before any
// worker exists, and the random view centre in build_view() -- so the one
// module-level state std keeps is touched by one thread, exactly as rng_state
// was.  A thread shares the address space and the module-level lets with its
// spawner (NATIVE.md, "Threads and processes"), so this is worth saying rather
// than leaving to be rediscovered.

// A Q30 value in [0, fx.ONE).
def rnd_unit() -> long { random.below(fx.ONE) };

// ─────────────────────────────────────────────────────────── named places ───
//
// The places are written as decimal STRINGS and parsed by parse_q30 at
// start-up, so a reader can see the real coordinate instead of a 2^30 scaling
// of it.  Each span is chosen so that --maxit 240 resolves the interesting
// structure at that magnification; `needles` needs about 900.
let PLACES: [str] = ["full", "seahorse", "elephant", "double",
                     "spiral", "needles", "random"];
let PX: [str] = [
    "-0.600000000", "-0.743643887", "0.292575500", "-1.250660000",
    "-0.726900000", "-0.160701350", "0.000000000"
];
let PY: [str] = [
    "0.000000000", "0.131825904", "0.014997500", "0.020120000",
    "0.188900000", "1.037566500", "0.000000000"
];
let PS: [str] = [
    "3.600000000", "0.010000000", "0.050000000", "0.006000000",
    "0.015000000", "0.000200000", "0.040000000"
];

// parse_q30(s) -> long
//
// "2^30 times the decimal in s", in exact integer arithmetic: the sign, the
// whole part, then up to nine fractional digits accumulated as an integer
// and divided once by 10^9.  No float, no locale, no rounding mode, and the
// same string always gives the same long -- which is what makes a coordinate
// in a command line reproducible.
//
// Returns Q30_BAD (8.0) for anything it does not understand, and for
// anything outside [-8, 8]: both are impossible for a centre of a view of
// the Mandelbrot set, so one sentinel covers "malformed" and "absurd" and the
// caller does not have to tell them apart.  Nine digits is 1e-9, which is
// about 1e-9 of the narrowest span any of the places above uses.
def parse_q30(s: str) -> long {
    let n = len(s);
    if (n == 0) { return Q30_BAD; };
    let i: long = 0;
    let neg = false;
    if (s[0] == 45) { neg = true; i = 1; } else if (s[0] == 43) { i = 1; };
    let whole: long = 0;
    let ndig: long = 0;
    while (i < n && s[i] >= 48 && s[i] <= 57) {
        whole = whole * 10 + (s[i] - 48);
        if (whole > 100000000) { return Q30_BAD; };
        i = i + 1;
        ndig = ndig + 1;
    };
    let frac: long = 0;
    let scale: long = 1;
    if (i < n && s[i] == 46) {
        i = i + 1;
        while (i < n && s[i] >= 48 && s[i] <= 57 && scale < 1000000000) {
            frac = frac * 10 + (s[i] - 48);
            scale = scale * 10;
            i = i + 1;
        };
    };
    // Trailing junk, or nothing at all but a sign and a point.
    if (i != n || (ndig == 0 && scale == 1)) { return Q30_BAD; };
    // frac < 10^9, so frac * ONE < 1.1e18 -- inside a long.
    let v = whole * fx.ONE + frac * fx.ONE / scale;
    if (v >= Q30_BAD) { return Q30_BAD; };
    if (neg) { 0 - v } else { v }
};

// ─────────────────────────────────────────────────────────────── setters ───
//
// NO LOCK ON ANY OF THESE, and that is a considered decision rather than an
// oversight.
//
// VLK exists, and render.y uses it, because `lock m { e }` builds a CLOSURE and
// a closure is 16 bytes of an arena that never frees: measured here, ten
// thousand `lock M { x = 1 }` cost 160000 bytes, while ten thousand `post`/`wait`
// pairs cost nothing at all.  Locking the view accessors therefore put four
// closures a frame on the output path -- 64 bytes a frame, forever.
//
// They are not needed.  There is exactly one writer (this program's main
// thread) and it only ever writes BETWEEN frames, and the readers are the
// workers, which reach the view from inside a critical section of their own and
// therefore inside the mutex's total order.  The one thing that has to be true
// is that a worker cannot observe this thread's stores late, and that is the
// `post GO` at the end of render.frame(): a locked read-modify-write, hence a
// full barrier, hence everything this thread wrote before it is visible to
// every worker that wakes after it.  Rendered and checked: the digest is
// identical for --threads 1 through 64 over 40 frames each.
//
// If this module ever grows a second writer -- a second thread panning, say --
// these have to go back under VLK, and that is the note to leave behind.

def md_set(cx: long, cy: long, span: long, maxit: long) -> void {
    vcx = cx;
    vcy = cy;
    vspan = span;
    vmaxit = maxit
};

def md_cx() -> long { vcx };
def md_cy() -> long { vcy };
def md_span() -> long { vspan };
def md_maxit() -> long { vmaxit };

// ────────────────────────────────────────────────────────────── colours ───

// md_glyph(cell) -> long -- the text glyph for a cell, in ASCII.  Inside the
// set is a space, which is the convention every text Mandelbrot uses: the set
// is the empty paper and the exterior is the ink.
//
// Two ways to shade, because they are genuinely different pictures:
//   shade = 0 (iter)  the ramp follows the band's position, so the exterior
//                     draws as repeating contour bands -- the classic look.
//   shade = 1 (lum)   the ramp follows the colour's luminance, so the picture
//                     keeps the palette's own light and dark and reads more
//                     like the terminal's other output.
def md_glyph(cell: long, lum_mode: long) -> long {
    if (cell == 0) { return 32; };
    let b = cell - 1;
    if (lum_mode != 0) { return fb_ascii(lum(PAL[b]), 255); };
    fb_ascii(b, 255)
};

// tui.shade_ascii reimplemented here rather than imported: md_glyph must stay
// callable from a worker without dragging the whole framebuffer into the
// set's module, and the ramp is ten integers.  ramp_index's rule -- v <= 0 is
// the emptiest glyph, v >= n the fullest, otherwise v*levels/n -- is tui's,
// so the two agree cell for cell.
let ARAMP: [long; 10] = [32, 46, 58, 45, 61, 43, 42, 35, 37, 64];

def fb_ascii(v: long, n: long) -> long {
    if (n <= 0) { return 64; };
    if (v <= 0) { return 32; };
    if (v >= n) { return 64; };
    ARAMP[(v * 10) / n]
};

// md_colour(cell) -> long -- the packed 0xRRGGBB for a cell, or the palette's
// darkest shade for the interior.
def md_colour(cell: long) -> long {
    if (cell == 0) { return IN_BG; };
    PAL[cell - 1]
};

def md_inside_bg() -> long { IN_BG };
def md_palette_at(i: long) -> long { PAL[i] };

// set_palette(kind, seed) -> void
//
// Build PAL from PP's row (or, for `random`, from the seed's stream in
// std/random.y) and derive IN_BG as a quarter of band 0, so the interior is
// visibly the same family as the exterior rather than an unrelated black.
//
// CALLED ONCE, at start-up, from the main thread -- before any worker exists.
def set_palette(kind: long, seed: long) -> void {
    if (kind == P_RANDOM) {
        // Two streams off one seed so the two flags that ask for randomness
        // do not march in step: the palette and a random start point.  Both
        // RE-SEED before drawing, which is what keeps them apart now that they
        // share std's one module-level state.
        random.seed(seed + 7919);
        let k: long = 0;
        while (k < 12) {
            // Amplitude and frequency stay in a range that makes a ramp worth
            // looking at: a > 20 .. 70, b > 15 .. 55, d in 0 .. 250, c in
            // 0 .. 99.
            let pick = k % 4;
            let lo: long = 20;
            let hi: long = 70;
            if (pick == 1) { lo = 15; hi = 55; };
            if (pick == 2) { lo = 0; hi = 250; };
            if (pick == 3) { lo = 0; hi = 99; };
            let width = hi - lo;
            CUR[k] = lo + (rnd_unit() * width) / fx.ONE;
            k = k + 1;
        }
    } else {
        let base = kind * 12;
        let k: long = 0;
        while (k < 12) { CUR[k] = PP[base + k]; k = k + 1; };
    };
    let i: long = 0;
    while (i < PALN) {
        let v = (i * fx.ONE) / (PALN - 1);
        let r = chan(0, v);
        let g = chan(1, v);
        let b = chan(2, v);
        PAL[i] = (r << 16) | (g << 8) | b;
        i = i + 1;
    };
    let q = PAL[0];
    IN_BG = ((((q >> 16) & 255) / 4) << 16) | ((((q >> 8) & 255) / 4) << 8)
            | ((q & 255) / 4)
};

// The place table, parsed once.  place_centre(i) answers through these, so a
// caller never has to know the coordinates are strings.
let place_x: [long; 7] = [0; 7];
let place_y: [long; 7] = [0; 7];
let place_s: [long; 7] = [0; 7];
let places_ok: long = 0;

def load_places() -> void {
    let k: long = 0;
    let bad: long = 0;
    while (k < 7) {
        let x = parse_q30(PX[k]);
        let y = parse_q30(PY[k]);
        let s = parse_q30(PS[k]);
        if (x == Q30_BAD || y == Q30_BAD || s == Q30_BAD || s <= 0) {
            bad = bad + 1;
        } else {
            place_x[k] = x;
            place_y[k] = y;
            place_s[k] = s;
        };
        k = k + 1;
    };
    places_ok = if (bad == 0) { 1 } else { 0 }
};

def place_count() -> long { 7 };
def place_name(i: long) -> str { PLACES[i] };
def place_cx(i: long) -> long { place_x[i] };
def place_cy(i: long) -> long { place_y[i] };
def place_span(i: long) -> long { place_s[i] };

export {
    LN2, ER2, Q30_BAD, CELL_MASK, PALN, SPAN0, P_BLUE, P_EMBER, P_ICE,
    P_MONO, P_GRASS, P_RANDOM, PNAMES, VLK,
    vcx, vcy, vspan, vmaxit,
    ln, log2p, md_shade, md_cell, md_iters, lum, PLACES,
    md_glyph, md_colour, md_inside_bg, md_palette_at,
    md_set, md_cx, md_cy, md_span, md_maxit,
    rnd_unit,
    parse_q30, load_places, places_ok, place_count, place_name,
    place_cx, place_cy, place_span, set_palette
};