// fluid.y -- a real-time fluid simulation in the terminal, in integer fixed
// point, with no float anywhere in it.
//
//   usage: fluid [options]
//
//   ./fluid                             the live view: alt screen, stir it with
//                                      the arrow keys, q quits
//   ./fluid --frames 10 --no-tty        the deterministic run: a table and a
//                                      final frame as text, then exit 0
//
// ===========================================================================
// WHAT IT IS
//
// Jos Stam's "Stable Fluids" (SIGGRAPH 1999) on a collocated grid: velocity u
// and v, a scalar dye field, and a pressure Poisson solve that removes the part
// of the velocity field which would compress fluid.  The solver is sim.y; this
// file is the command line, the colour ramps, the status line and the two frame
// loops.
//
// WHY THIS ONE AND NOT SHALLOW WATER: the pressure solve is the interesting
// part of a fluid simulator and shallow water does not have one -- its
// projection is a single algebraic line.  The Gauss-Seidel solve is the thing
// worth showing in a language with no math library, and `--iters 0` against
// `--iters 40` is a visible, measurable difference in the residual divergence
// the summary reports.
//
// ===========================================================================
// THE THREE GAPS THIS IS BUILT AROUND (ORCHESTRATOR.md 2.4)
//   no float -> long, and no cast syntax at all, so every quantity is a Q30
//   `long`: a velocity is a whole number of cells per step times 2^30 and
//   fx.ONE is 1.0.  sim.y's header is where the overflow analysis lives; no
//   arithmetic below this line uses a float.
//   no sin/cos/sqrt, so the emitter's Lissajous orbit comes from fx.y, every
//   square root from fx.isqrt, and the colour ramps are integer lerps between
//   hand-picked RGB stops.
//   nothing is freed (2.7), so the solver's grids are built once at module
//   scope and a step allocates ZERO bytes.  `--frames 10000 --stats` prints
//   heap_used() at both ends and the delta is zero.
//
//   WHAT THE GOLDEN MAY HOLD OF THAT MEASUREMENT: the DELTA only.  heap_used()
//   counts the argument vector, which the kernel allocated at exec time, so an
//   absolute moves with the length of the path this program was invoked by and
//   a golden holding one matches only one invocation.  A delta cancels argv,
//   because argv is already in both readings.  See the header block below and
//   README.md, "The heap figure in the golden is a DELTA".
//
// NO BREAK, NO CONTINUE (2.9): the 3x3 and 5-point stencils are written out as
// straight-line neighbour loads in sim.y rather than as loops, and every early
// exit is a guard flag or a positive `if` around a whole body.
//
// ===========================================================================
// THE COLOUR, AND WHY THE GLYPH IS NOT THE COLOUR
//
// Every field is drawn TWICE over: the glyph ramp carries the MAGNITUDE and the
// colour carries the SIGN.  For the two unsigned fields (speed, dye) the hue is
// a sequential ramp; for the signed one (vorticity) the hue is a DIVERGING pair
// -- cool for clockwise, warm for counter-clockwise, both starting at the same
// near-black -- because a vortex core is a spot of one sign in a field of the
// other and a luminance-only rendering throws the sign away.  That is the one
// thing a vorticity plot has to get right.
//
// The glyph is tui.shade_blocks(), which maps a value to a glyph by COVERAGE
// rather than by brightness, so it reads the same on a light terminal and a
// dark one (examples/donut's note on ramp choice).  The magnitude it is fed is
// norm() then gmag(): position on [0,1], then the display gamma.  The gamma is
// not cosmetic -- see gmag() for why a fluid field looks like an empty screen
// without one.
//
// The scale is a decaying maximum (fit_scale), not a fixed one: a fixed scale
// either blows out on the first energetic step or shows nothing for the first
// hundred.  A decaying max tracks the field and still falls back to nothing
// when the fluid settles, instead of amplifying noise into a rainbow.  The top
// row of the live view is that ramp drawn across the full width, so the current
// scale is always on screen.
//
// KEYS (interactive)
//   q  Esc  Ctrl-C   quit -- always through tui.restore_all_exit(0)
//   arrows           move the emitter: the stirrer, at its own position
//   space            pause / resume
//   .                one step, even while paused
//   d                drop a dye blob at the emitter
//   s                the emitter's own seeded orbit on/off
//   r                re-seed the field with the same --seed
//   v                cycle --field speed / vort / dye
//   g                cycle --glyph blocks / half / ascii / braille / none
//   + / -            --iters up / down, the pressure solve quality
//
// There is no `break` in Y, so every key is an arm of one long else-if chain
// and the loop's own exit is a guard flag tested in the while.

import fx;
import args;
import sim;
import textout;
import tui;

// ───────────────────────────────────────────────────────────────── options ───

const OPTS: [args.Opt] = [
    { long: "frames", short: "n", kind: args.NUM,
      help: "run exactly N steps, print a summary, exit 0 (default 0: run until q)" },
    { long: "size", short: "s", kind: args.STR,
      help: "grid as WxH cells, 1x1..250x120 (default: the terminal, or 96x36 without one)" },
    { long: "iters", short: "i", kind: args.NUM,
      help: "pressure Gauss-Seidel sweeps per projection, 0..400 (default 24; 0 = do not project)" },
    { long: "diters", short: "d", kind: args.NUM,
      help: "viscous Jacobi sweeps per step, 0..64 (default 4; forced to 0 when --viscosity 0)" },
    { long: "viscosity", short: "", kind: args.NUM,
      help: "viscosity in 1/10000, 0..10000 (default 0: inviscid, the interesting case)" },
    { long: "vort", short: "", kind: args.NUM,
      help: "vorticity confinement in 1/1000, 0..1000 (default 25)" },
    { long: "damping", short: "", kind: args.NUM,
      help: "velocity damping per step in 1/1000, 0..1000 (default 0)" },
    { long: "decay", short: "", kind: args.NUM,
      help: "dye fade per step in 1/1000, 0..1000 (default 2)" },
    { long: "ink", short: "", kind: args.NUM,
      help: "dye the emitter lays down per step, in 1/1000 of full scale (default 250)" },
    { long: "swirl", short: "", kind: args.NUM,
      help: "emitter swirl in 1/1000 cells per step, 0..4000 (default 375)" },
    { long: "radius", short: "", kind: args.NUM,
      help: "emitter radius in cells, 1..64 (default 6)" },
    { long: "seed", short: "S", kind: args.NUM,
      help: "seed for the initial perturbation, 0..4294967295 (default 1); the same seed, the same run, byte for byte" },
    { long: "field", short: "F", kind: args.STR,
      help: "speed | vort | dye -- what is coloured (default speed)" },
    { long: "glyph", short: "g", kind: args.STR,
      help: "blocks | half | ascii | braille | none (default blocks)" },
    { long: "gamma", short: "", kind: args.NUM,
      help: "display gamma, 1..8: the magnitude ramp is t^(1/gamma) (default 2; a fluid field is mostly quiet and a linear ramp shows an empty screen)" },
    { long: "dump", short: "", kind: args.NUM,
      help: "print the grid as text every N steps as well (0: the last step only)" },
    { long: "fps", short: "f", kind: args.NUM,
      help: "live view frames per second (default 30)" },
    { long: "no-tty", short: "", kind: args.BOOL,
      help: "render into a text capture instead of the terminal; never paces" },
    { long: "stats", short: "", kind: args.BOOL,
      help: "print wall clock, rate and heap use on stderr when done" }
];

let NAMES: [str] = ["speed", "vort", "dye"];
let GLYPHS: [str] = ["blocks", "half", "ascii", "braille", "none"];

// ────────────────────────────────────────────────────────── the colour ramps ─
//
// Six stops each, interpolated in integer Q30 (ramp6).  No float, and one
// division per channel -- which is per CELL, so the numbers are small: the
// channel difference is at most 255 and the weight at most 2^30, so the product
// is at most 2^38.
const RAMP_SPEED: [long; 6] = [
    tui.rgb(4, 6, 12),
    tui.rgb(12, 34, 74),
    tui.rgb(18, 88, 144),
    tui.rgb(40, 156, 194),
    tui.rgb(136, 216, 220),
    tui.rgb(255, 255, 232)
];
// Vorticity: two ramps, one per sign.  Cool for clockwise (negative here), warm
// for counter-clockwise, and both starting at the same near-black so that a
// quiet field is quiet in HUE as well as in brightness.
const RAMP_COOL: [long; 6] = [
    tui.rgb(4, 6, 12),
    tui.rgb(10, 22, 60),
    tui.rgb(18, 58, 128),
    tui.rgb(34, 126, 186),
    tui.rgb(96, 200, 232),
    tui.rgb(214, 248, 255)
];
const RAMP_WARM: [long; 6] = [
    tui.rgb(4, 6, 12),
    tui.rgb(52, 14, 22),
    tui.rgb(140, 34, 24),
    tui.rgb(212, 86, 20),
    tui.rgb(248, 168, 40),
    tui.rgb(255, 244, 206)
];
const RAMP_DYE: [long; 6] = [
    tui.rgb(4, 4, 10),
    tui.rgb(38, 12, 62),
    tui.rgb(116, 22, 84),
    tui.rgb(198, 70, 44),
    tui.rgb(248, 152, 52),
    tui.rgb(255, 248, 224)
];

let BG = 0;                 // the background we paint over
let FG_DIM = 0;             // HUD labels
let FG_HI = 0;              // HUD numbers

// ramp6(st, t) -> long -- t in [0, fx.ONE] picks a colour from six stops.
//
// t * 5 is at most 2^32.3 and the channel lerp at most 255 * 2^30 = 2^38:
// nothing here can overflow, and nothing here divides by anything the caller
// sets -- the caller has already clamped t.
def ramp6(st: [long; 6], t: long) -> long {
    if (t <= 0) { return st[0]; };
    if (t >= fx.ONE) { return st[5]; };
    let x = (t * 5) >> 30;
    let f = t * 5 - (x << 30);
    let a = st[x];
    let b = st[x + 1];
    tui.rgb(tui.r_of(a) + ((tui.r_of(b) - tui.r_of(a)) * f) / fx.ONE,
           tui.g_of(a) + ((tui.g_of(b) - tui.g_of(a)) * f) / fx.ONE,
           tui.b_of(a) + ((tui.b_of(b) - tui.b_of(a)) * f) / fx.ONE)
};

// ──────────────────────────────────────────────────────────── module state ───
//
// The solver's Field is built HERE, at module scope, before the command line is
// parsed -- 2.25 MiB, once, for the life of the program.  --size retunes it
// with sim.setup(), which allocates nothing (see sim.y).
let FL: sim.Field = sim.new(96, 36);
let CFG: sim.Cfg = {
    iters: 24, diters: 4, visc16: 0, vort16: 1638, damp16: 0, decay16: 131,
    swirl16: 24576, ink16: 16384, rad: 6, em: 1, ex: 48, ey: 18
};

let FLD = 0;                // 0 speed, 1 vorticity, 2 dye
let GLY = 0;                // 0..4, as GLYPHS
let GAMMA: long = 2;         // the display gamma: t^(1/GAMMA)
let SCALE: long = 0;        // the colour scale for this frame, Q30
let FRAMES: long = 0;
let NOTTY: long = 0;
let SHOWSTATS: long = 0;
let DUMPEVERY: long = 0;
let SEEDV: long = 1;
let ITERS = 24;             // kept for --help-ish messages and the reseed
let DRIFT: long = 1;        // the emitter's own seeded orbit
let PHASE: long = 0;        // its phase, Q30 radians
let PAUSED: long = 0;
let SR = 38;                // the surface is SR rows x SC cols
let SC = 96;

// the measurements, refreshed once per step and read by the HUD and the report,
// so the frame loop runs FOUR grid passes (the four measurements) instead of
// eight.  All of them are scalars: no array, no record, no heap.
let E_LAST: long = 0;
let V_LAST: long = 0;
let M_LAST: long = 0;
let D_LAST: long = 0;
let E_PEAK: long = 0;
let V_PEAK: long = 0;
let M_PEAK: long = 0;

// Row 0 of the surface is the colour bar, rows 1..SR-2 are the fluid, row SR-1
// is the status line.  So the solver's grid is (SR-2) x SC, and TOP is the
// surface row the fluid's own row 0 is drawn at.
let TOP = 1;

// ─────────────────────────────────────────────────────────────── the field ───

def grid_rows() -> long { SR - 2 };

// value_at(x, y) -> long -- the field being drawn, Q30, signed for vorticity.
// One call per cell in the render loop and nowhere else, so there is exactly
// one definition of "what is being coloured" and switching --field cannot
// half-work.
def value_at(x: long, y: long) -> long {
    if (FLD == 0) { return sim.speed(FL, x, y); };
    if (FLD == 2) { return sim.dye_at(FL, x, y); };
    sim.vort(FL, x, y)
};

// fit_scale(peak) -- a decaying maximum.  Rise instantly, fall by 1/12 a frame,
// and never below 1/128 of a cell per step, which is the floor that stops a
// settled field from being amplified into a rainbow.
def fit_scale(peak: long) -> void {
    let lo = fx.ONE / 128;
    if (peak > SCALE) {
        SCALE = peak
    } else {
        SCALE = SCALE - SCALE / 12;
        if (SCALE < lo) { SCALE = lo; }
    }
};

// norm(v) -> long -- |v| as a position on [0, 1] in Q30, which is the unit both
// ramps want.  The division comes FIRST and the scale multiplies nothing
// afterwards, so nothing here can overflow: |v| <= SCALE, so the quotient is 0
// or 1 and shifting it up by 30 is one Q30 unit.
def norm(v: long) -> long {
    let a = if (v < 0) { 0 - v } else { v };
    // Saturation is checked BEFORE the multiply, and that is the whole reason
    // this is safe: below the branch a < SCALE <= 2^32, so a * fx.ONE is at
    // most 2^62 -- two bits of headroom, not the one bit a bare
    // a * fx.ONE / SCALE on a clamped-to-2^32 field would have left.
    if (a >= SCALE) { return fx.ONE; };
    (a * fx.ONE) / SCALE
};

// gmag(t) -> long -- the display gamma: t^(1/GAMMA), by taking the root
// GAMMA-1 times with fx.isqrt.
//
// WHY IT IS NOT 1 BY DEFAULT.  A fluid field is mostly quiet.  The speed field
// is quiet because most of the box is at rest; the VORTICITY field is quiet
// because away from a vortex core the flow of a converged projection is very
// nearly irrotational -- which is true of real fluids, and of this solver.
// Fed linearly to a ramp, either reads as a nearly empty screen with a few
// bright specks in it.  A square root is the standard fix, and it is what every
// fluid visualisation does.  --gamma 1 turns it off; none of the NUMBERS in the
// report depend on it, because those are measurements and not pixels.
def gmag(t: long) -> long {
    let a = if (t < 0) { 0 - t } else { t };
    // g counts roots taken: the loop body runs once for every g from 2 up to
    // and including GAMMA, which is GAMMA-1 roots -- one for gamma 2, two for
    // gamma 3, and NONE for gamma 1, which is what makes gamma 1 exactly linear
    // rather than accidentally a square root.
    let g = 2;
    while (g <= GAMMA) {
        a = fx.isqrt(a << 30);
        g = g + 1
    };
    a
};

// glyph_q(m) -> long -- fb's ramp on a 0..1 Q30 magnitude.  fb maps a value to a
// glyph by COVERAGE, so the glyph is monotonic in magnitude on any terminal,
// light or dark, and the hue is free to carry the sign.
def glyph_q(m: long) -> long {
    if (GLY == 1) { return tui.shade_half(m, fx.ONE); };
    if (GLY == 2) { return tui.shade_ascii(m, fx.ONE); };
    if (GLY == 3) { return tui.shade_braille(m, fx.ONE); };
    if (GLY == 4) { return tui.space; };
    tui.shade_blocks(m, fx.ONE)
};

// colour_q(neg, m) -> long -- the sign picks the ramp for a vorticity field, the
// magnitude picks the position.  m is already 0..1, which is ramp6's unit.
def colour_q(neg: bool, m: long) -> long {
    if (FLD == 1) {
        if (neg) { return ramp6(RAMP_COOL, m); };
        return ramp6(RAMP_WARM, m)
    };
    if (FLD == 2) { return ramp6(RAMP_DYE, m); };
    ramp6(RAMP_SPEED, m)
};

// ──────────────────────────────────────────────────────────────── render ────

// render(s) -- one frame: the field, then the colour bar on row 0.
def render(s: tui.Surface) -> void {
    let peak = 0;
    if (FLD == 0) { peak = V_LAST; };
    if (FLD == 1) { peak = sim.vort_peak(FL); };
    if (FLD == 2) {
        // dye is clamped to [0,1] by construction, so its scale is 1.0 and
        // nothing has to be measured
        peak = fx.ONE
    };
    fit_scale(peak);

    let r = 0;
    while (r < s.rows - 2) {
        let c = 0;
        while (c < s.cols) {
            let v = value_at(c, r);
            // norm -> gmag once per cell, then both ramps read the same number:
            // the gamma is paid for as many square roots per cell as there are
            // gamma steps, not twice
            let m = gmag(norm(v));
            tui.put(s, r + TOP, c, glyph_q(m), colour_q(v < 0, m), BG);
            c = c + 1
        };
        r = r + 1
    };
    // The colour bar: the whole ramp across the full width, as a run of full
    // blocks so it reads as a gradient on a real terminal and is still legible
    // in a text dump.  For a signed field it runs -SCALE .. +SCALE, so both
    // signs show in one row and the middle of the bar is exactly zero; for an
    // unsigned one it runs 0 .. SCALE.  c * 2^31 <= 2^39 and the division brings
    // it straight back to [0, 2*ONE], so nothing here can overflow.
    let c = 0;
    while (c < s.cols) {
        let p = (c * fx.ONE * 2) / s.cols;      // 0 .. 2*ONE
        if (FLD == 1) {
            let q = p - fx.ONE;                // -ONE .. ONE, the signed position
            tui.put(s, 0, c, 9608, colour_q(q < 0, gmag(q)), BG)
        } else {
            tui.put(s, 0, c, 9608, colour_q(false, gmag(p / 2)), BG)
        };
        c = c + 1
    };
    // the two ends, marked in the colours they stand for
    tui.put(s, 0, 0, 9472, colour_q(true, fx.ONE), BG);
    tui.put(s, 0, s.cols - 1, 9470, colour_q(false, fx.ONE), BG)
};

// ───────────────────────────────────────────── allocation-free status line ───
//
// A HUD built with tostring() once a frame would allocate on the frame loop,
// and the whole claim of this example is that a frame costs zero bytes of
// heap.  So the digits go straight into the surface, one cell at a time, from a
// module-level scratch array -- and the scratch is module level for the sharp
// edge of that rule: an ARRAY LITERAL is evaluated onto the heap every time the
// expression runs (72 bytes for [long; 12], measured), so a literal written
// inside these defs would leak several times a frame.
//
// tui.text() is safe to use per frame (it decodes in place out of the caller's
// bytes and allocates nothing), so the labels come from it and only the NUMBERS
// need a hand-rolled digit loop.
let DIG: [long; 24] = [48; 24];

// hnum(s, row, col, v) -> long -- a decimal `long`, no padding; returns the
// column just past it.
def hnum(s: tui.Surface, row: long, col: long, v: long) -> long {
    let n = if (v < 0) { 0 - v } else { v };
    let d = textout.digits(n);
    let at = col;
    let i = d;
    while (i > 0) {
        i = i - 1;
        DIG[i] = 48 + n % 10;
        n = n / 10
    };
    i = 0;
    while (i < d) {
        tui.put(s, row, at, DIG[i], FG_HI, BG);
        at = at + 1;
        i = i + 1
    };
    at
};

// hpad(s, row, col, v, w) -> long -- right-aligned in `w` columns.
def hpad(s: tui.Surface, row: long, col: long, v: long, w: long) -> long {
    let n = if (v < 0) { 0 - v } else { v };
    let d = textout.digits(n);
    let at = col;
    let k = d;
    while (k < w) {
        tui.put(s, row, at, 32, FG_DIM, BG);
        at = at + 1;
        k = k + 1
    };
    hnum(s, row, at, v)
};

// hq(s, row, col, v, shift) -> long -- v / 2^shift with four decimals, a digit
// at a time.  The fraction is (remainder * 10000) >> shift, at most
// 2^30 * 10^4 = 2^43.3 for a Q30 value.
def hq(s: tui.Surface, row: long, col: long, v: long, shift: long) -> long {
    let a = if (v < 0) { 0 - v } else { v };
    let ip = a >> shift;
    let fr = ((a - (ip << shift)) * 10000) >> shift;
    let at = col;
    if (v < 0) {
        tui.put(s, row, at, 45, FG_HI, BG);
        at = at + 1
    };
    at = hnum(s, row, at, ip);
    tui.put(s, row, at, 46, FG_HI, BG);
    at = at + 1;
    let f = fr;
    if (f < 1000) {
        tui.put(s, row, at, 48, FG_HI, BG); at = at + 1
    };
    if (f < 100) {
        tui.put(s, row, at, 48, FG_HI, BG); at = at + 1
    };
    if (f < 10) {
        tui.put(s, row, at, 48, FG_HI, BG); at = at + 1
    };
    hnum(s, row, at, f)
};

// htext(s, row, col, t, fg) -> long -- a HUD label, returning the column just
// past it.
//
// NOT tui.text's return value, and this is worth being explicit about because
// getting it wrong is invisible for a frame and ruins the line for ever after:
// tui.text() answers HOW MANY CODEPOINTS IT DREW, which is a length and not a
// position.  Using it as the next column walks the cursor backwards by the
// length of every label, so each label lands on top of the last and the row
// ends up with the last string drawn sitting at column 2.  (It looks plausible
// enough to be worth the three debug lines it cost to find.)  Every label on
// this line is ASCII, so one byte is exactly one column and len(t) is the
// advance; a label with a box-drawing or CJK character in it would want
// tui.width_of() summed instead, and there are none.
def htext(s: tui.Surface, row: long, col: long, t: str, fg: long) -> long {
    tui.text(s, row, col, t, fg, BG);
    col + len(t)
};

// hgap(s, row, col, n) -> long -- n blanks, so a number does not touch the rule
// the hline drew.  A bare `c = c + 2` moves the cursor and leaves the rule
// showing through the gap, which reads as a separator and is not one.
def hgap(s: tui.Surface, row: long, col: long, n: long) -> long {
    let at = col;
    let k = 0;
    while (k < n) {
        tui.put(s, row, at, 32, FG_DIM, BG);
        at = at + 1;
        k = k + 1
    };
    at
};

// hud(s, row, fps) -- the status line: what the solver is doing, and how well.
//
// The key list at the right is chosen by how much room is left, because
// tui.text() clips SILENTLY at the surface edge (it is bounds-safe, not
// complaining) and a status line cut in half mid-word is worse than one that
// says less.  Four lengths, longest that fits.  tui.put() ignoring an
// out-of-range column is right for a renderer and wrong for a status line,
// which is the whole reason this function exists rather than one tui.text()
// call.
def hud(s: tui.Surface, row: long, fps: long) -> void {
    let c = 0;
    tui.hline(s, row, 0, s.cols, 9472, tui.rgb(28, 32, 38), BG);
    c = 2;
    c = htext(s, row, c, "fluid", FG_HI);
    c = hpad(s, row, c, FL.steps, 6);
    c = htext(s, row, c, "fps", FG_DIM);
    c = hpad(s, row, c, fps, 3);
    c = hgap(s, row, c, 2);
    c = htext(s, row, c, "E", FG_DIM);
    c = hq(s, row, c, E_LAST, 28);
    c = hgap(s, row, c, 2);
    c = htext(s, row, c, "v", FG_DIM);
    c = hq(s, row, c, V_LAST, 30);
    c = hgap(s, row, c, 2);
    c = htext(s, row, c, "m", FG_DIM);
    c = hq(s, row, c, M_LAST, 30);
    c = hgap(s, row, c, 2);
    c = htext(s, row, c, "div", FG_DIM);
    c = hq(s, row, c, D_LAST, 12);
    c = hgap(s, row, c, 2);
    c = htext(s, row, c, "+/-", FG_DIM);
    c = hpad(s, row, c, CFG.iters, 3);
    c = hgap(s, row, c, 1);
    c = htext(s, row, c, NAMES[FLD], tui.rgb(198, 170, 96));
    if (PAUSED != 0) {
        htext(s, row, c, "  PAUSED", tui.rgb(232, 176, 72))
    } else {
        let room = s.cols - c;
        if (room >= 80) {
            htext(s, row, c, "  q quit  arrows stir  space pause  . step  d dye  v field  g glyph  r reseed  s orbit", FG_DIM)
        } else if (room >= 44) {
            htext(s, row, c, "  q quit  arrows stir  space pause  v field  g glyph", FG_DIM)
        } else if (room >= 22) {
            htext(s, row, c, "  q quit  arrows stir", FG_DIM)
        } else {
            htext(s, row, c, "  q quit", FG_DIM)
        }
    }
};

// ────────────────────────────────────────────────────────────── the emitter ──
//
// The emitter follows a Lissajous orbit whose PHASE comes from --seed, so the
// deterministic run's stirrer is as reproducible as everything else and there
// is no unseeded randomness on any path.  In the live view the arrow keys take
// it over and `s` gives the orbit back.
def move_emitter() -> void {
    if (DRIFT == 0) { return; };
    // 1:1 horizontal against 2:3 vertical -- deliberately incommensurate, so the
    // orbit never repeats inside a run.
    //
    // a and b are CELL COUNTS, not Q30 values: fx.sin() answers in Q30, and a
    // Q30 count multiplied by a Q30 sine is a Q60 product -- 125 * 2^30 * 2^30
    // is 2^67, which is three bits of the wrong answer and one of a hang (see
    // the note on emit() in sim.y).  Count times Q30, divided by fx.ONE, is
    // how a Q30 quantity becomes a cell count, and that is the only conversion
    // there is: Y has no float -> long either.
    let a = SC / 2 - 3;
    let b = grid_rows() / 2 - 3;
    CFG.ex = SC / 2 + a * fx.sin(PHASE) / fx.ONE;
    CFG.ey = grid_rows() / 2 + b * fx.sin(PHASE * 2 / 3 + fx.from_int(1)) / fx.ONE;
    if (CFG.ex < 0) { CFG.ex = 0; };
    if (CFG.ex > SC - 1) { CFG.ex = SC - 1; };
    if (CFG.ey < 0) { CFG.ey = 0; };
    if (CFG.ey > grid_rows() - 1) { CFG.ey = grid_rows() - 1; };
    // 0.021 rad a step: a full turn in about five minutes at 30 fps, slow
    // enough to read the fluid between passes and fast enough that two passes
    // overlap
    PHASE = PHASE + 22517998;
    if (PHASE >= fx.TWO_PI) { PHASE = PHASE - fx.TWO_PI; }
};

def emitter_home() -> void {
    CFG.ex = SC / 2;
    CFG.ey = grid_rows() / 2
};

// ────────────────────────────────────────────────────────────────── CLI ──────

def die(msg: str) -> void {
    eputs("fluid: ");
    eputs(msg);
    eputs("\nfluid: try --help\n");
    exit(1)
};

// mode_of(name, what, allowed) -> long
def mode_of(name: str, what: str, allowed: [str]) -> long {
    let i = 0;
    while (i < len(allowed)) {
        if (allowed[i] == name) { return i; };
        i = i + 1
    };
    let msg = "bad " + what + " '" + name + "'; expected one of: ";
    let j = 0;
    while (j < len(allowed)) {
        msg = msg + allowed[j];
        if (j + 1 < len(allowed)) { msg = msg + " | "; };
        j = j + 1
    };
    die(msg);
    0
};

// parse_size(spec) -> long -- WxH packed as W*1000000 + H, or 0 if the string is
// not that shape.  It refuses rather than clamps: a fluid solver divides by the
// cell count, so --size 0x0 has to be diagnosed here and never reach it.
def parse_size(spec: str) -> long {
    let at = spec.index_of("x");
    if (at < 1) { return 0; };
    let a = spec[0:at];
    let b = spec[at + 1:];
    if (!args.num_ok(a) || !args.num_ok(b)) { return 0; };
    let w = tonum(a);
    let h = tonum(b);
    if (w < 1 || w > sim.MAXW || h < 1 || h > sim.MAXH) { return 0; };
    w * 1000000 + h
};

// ranged(name, v, lo, hi) -> long -- a validated integer flag.  A flag outside
// its range is a diagnostic and exit 1, never a clamp: --size 0x0 and --iters
// -1 have to be told about, because silently running the nearest legal thing is
// how a "why did it do that" bug gets filed against the program instead of the
// user's typo.
def ranged(name: str, v: long, lo: long, hi: long) -> long {
    if (v < lo || v > hi) {
        die("--" + name + " must be " + tostring(lo) + ".." + tostring(hi)
            + ", got " + tostring(v))
    };
    v
};

args.init("fluid",
          "Jos Stam's stable fluids in the terminal: an integer Q30 solver, a "
          + "Gauss-Seidel pressure projection, and a stirrer you drive with the "
          + "arrow keys.",
          OPTS,
          "no arguments: the live view.  --frames N --no-tty: the deterministic run.");
let st = args.parse(argv());
if (st == args.HELP) {
    puts(args.usage());
    puts("\nthe step, in order:\n");
    puts("  0  the emitter's rotational force  (-dy, +dx)/r -- a SOURCE would be\n");
    puts("     almost pure divergence and the projection would delete it\n");
    puts("  1  viscosity: (I - nu dt laplacian) u = u, Jacobi sweeps\n");
    puts("  2  project: div -> Poisson for p -> u -= grad p.  THIS is the\n");
    puts("     interesting part, and --iters is how many sweeps it gets\n");
    puts("  3  advect: semi-Lagrangian, u(x) <- u(x - dt u(x))\n");
    puts("  4  vorticity confinement, feeding eddies back after advection\n");
    puts("  5  project again -- advection is not divergence-free\n");
    puts("  6  damping and dye fade\n");
    puts("\nfields:\n");
    puts("  speed   |(u,v)|, unsigned.  the hue is a sequential heat ramp.  This\n");
    puts("          is the default because it shows the WHOLE flow\n");
    puts("  vort    dv/dx - du/dy, SIGNED.  a diverging hue -- cool one way, warm\n");
    puts("          the other -- and the glyph ramp on the magnitude, which is how\n");
    puts("          a vortex core shows up.  Sparser than speed, and honestly so:\n");
    puts("          away from a core a converged projection is nearly irrotational\n");
    puts("  dye     the scalar the emitter lays down, so you can watch the\n");
    puts("          semi-Lagrangian backtrace carry it\n");
    puts("\nkeys, live view:  q or Esc quit, arrows stir, space pause, . one step,\n");
    puts("                  d drop dye, s orbit on/off, r reseed, v field, g glyph,\n");
    puts("                  +/- pressure iterations\n");
    puts("\nevery number this program reports is an integer: there is no float in\n");
    puts("it, so an energy or a speed is a Q30 long printed by out_q().\n");
    exit(0)
};
if (st == args.USAGE) {
    eputs("fluid: try --help\n");
    exit(1)
};
if (len(args.positional()) > 0) {
    die("takes no operands; got '" + args.positional()[0] + "'")
};

FRAMES = args.get_long("frames", 0);
NOTTY = if (args.has("no-tty")) { 1 } else { 0 };
SHOWSTATS = if (args.has("stats")) { 1 } else { 0 };
DUMPEVERY = args.get_long("dump", 0);
FLD = mode_of(args.get_str("field", "speed"), "--field", NAMES);
GLY = mode_of(args.get_str("glyph", "blocks"), "--glyph", GLYPHS);

// The seed's range is 2^32-1 and not "any long" because the generator is
// xorshift32 (sim.y's rnd): its state is 32 bits, so seeds above 2^32-1 would be
// aliases of seeds below it.  Saying so beats letting two different --seed
// values quietly produce the same run.  args also refuses more than 18 digits
// outright, which is a clean diagnostic and not a trap.
SEEDV = ranged("seed", args.get_long("seed", 1), 0, 4294967295);
ITERS = ranged("iters", args.get_long("iters", 24), 0, 400);
let diters = ranged("diters", args.get_long("diters", 4), 0, 64);
let visc = ranged("viscosity", args.get_long("viscosity", 0), 0, 10000);
let vort = ranged("vort", args.get_long("vort", 25), 0, 1000);
let damping = ranged("damping", args.get_long("damping", 0), 0, 1000);
let decay = ranged("decay", args.get_long("decay", 2), 0, 1000);
let ink = ranged("ink", args.get_long("ink", 250), 0, 1000);
let swirl = ranged("swirl", args.get_long("swirl", 375), 0, 4000);
let rad = ranged("radius", args.get_long("radius", 6), 1, 64);
let fpswant = ranged("fps", args.get_long("fps", 30), 1, 240);
GAMMA = ranged("gamma", args.get_long("gamma", 2), 1, 8);
if (DUMPEVERY < 0) { DUMPEVERY = 0; };

// The coefficients into sim.y's Q16 units.  Every one of them was validated
// above, so nothing downstream can divide by a zero or overflow: the largest is
// viscosity at 10000/10000 = 1.0 = 65536, and sim.y's rule (b) is that a Q16
// coefficient never forms a Q60 product.
CFG.iters = ITERS;
CFG.diters = diters;
CFG.visc16 = visc * 65536 / 10000;
CFG.vort16 = vort * 65536 / 1000;
CFG.damp16 = damping * 65536 / 1000;
CFG.decay16 = decay * 65536 / 1000;
CFG.swirl16 = swirl * 65536 / 1000;
CFG.ink16 = ink * 65536 / 1000;
CFG.rad = rad;
CFG.em = 1;
if (visc == 0) { CFG.diters = 0; };

// The size: the terminal's, or --size, or a fixed default with no terminal.
// Row 0 is the colour bar and row SR-1 the status line, so the solver's grid is
// (SR-2) x SC.
let wsize = args.get_str("size", "");
let have_size = args.has("size");
SR = 38;
SC = 96;
let ws = tui.size();
if (ws.rows > 4 && ws.cols > 11) {
    SR = ws.rows;
    SC = ws.cols
};
if (NOTTY != 0 && have_size == false) {
    // No terminal to ask and none given: a FIXED default, which is what makes
    // the deterministic run reproducible on a machine whose window happens to
    // be a different shape.
    SR = 38;
    SC = 96
};
if (have_size) {
    let sz = parse_size(wsize);
    if (sz == 0) {
        die("--size wants WxH with 1 <= W <= " + tostring(sim.MAXW)
            + " and 1 <= H <= " + tostring(sim.MAXH)
            + ", e.g. --size 96x36; got '" + wsize + "'")
    };
    SC = sz / 1000000;
    SR = sz % 1000000 + 2
};
if (SR < 5) { SR = 5; };
if (SC < 12) { SC = 12; };
if (SR > sim.MAXH + 2) { SR = sim.MAXH + 2; };
if (SC > sim.MAXW) { SC = sim.MAXW; };
let srf = tui.new(SR, SC);

BG = tui.rgb(2, 3, 6);
FG_DIM = tui.rgb(126, 136, 148);
FG_HI = tui.rgb(226, 232, 240);

sim.setup(FL, SC, grid_rows(), SEEDV, ITERS);
emitter_home();
PHASE = fx.mul(fx.from_int(SEEDV % 1000), fx.from_int(1000));

// ────────────────────────────────────────────── one step + its measurements ───
//
// step_and_measure() -- advance one step, then take the four measurements the
// HUD and the report read.  One def so the two frame loops cannot drift apart,
// and so --stats brackets exactly this call: four grid passes a step, all of
// them reading, none of them allocating.
def step_and_measure() -> void {
    move_emitter();
    sim.step(FL, CFG);
    E_LAST = sim.energy(FL);
    V_LAST = sim.max_speed(FL);
    M_LAST = sim.mass(FL);
    D_LAST = sim.div_rms(FL);
    if (E_LAST > E_PEAK) { E_PEAK = E_LAST; };
    if (V_LAST > V_PEAK) { V_PEAK = V_LAST; };
    if (M_LAST > M_PEAK) { M_PEAK = M_LAST; }
};

def measure() -> void {
    E_LAST = sim.energy(FL);
    V_LAST = sim.max_speed(FL);
    M_LAST = sim.mass(FL);
    D_LAST = sim.div_rms(FL);
    if (E_LAST > E_PEAK) { E_PEAK = E_LAST; };
    if (V_LAST > V_PEAK) { V_PEAK = V_LAST; };
    if (M_LAST > M_PEAK) { M_PEAK = M_LAST; }
};

// ═══════════════════════════════════════════════ the deterministic path ═══
//
// The same draw and the same tui.flush_diff as the terminal path -- the ANSI
// stream is built and counted either way, which is what makes the digest column
// evidence rather than a claim -- except that it goes to /dev/null and the text
// goes to stdout instead.
//
// NO PACING HERE, deliberately.  This path exists to answer "how fast is the
// solver", and a sleep in the middle of it would measure nanosleep instead.
// --fps is a live-view knob.
if (NOTTY != 0) {
    if (FRAMES < 1) {
        die("--no-tty needs --frames N, or it would run forever into a stdout nobody is watching")
    };
    let devnull = syscall(257, 0 - 100, "/dev/null", 1, 0, 0, 0);   // openat
    if (devnull >= 0) { tui.set_fd(devnull); };
    tui.capture_on();

    let h0 = heap_used();
    let t0 = clock_us();

    textout.out_str("fluid -- Jos Stam's stable fluids, integer Q30, no float in it\n\n");
    textout.out_str("grid         ");
    textout.out_num(SC);
    textout.out_str(" x ");
    textout.out_num(grid_rows());
    textout.out_str(" cells, ");
    textout.out_num(FL.n);
    textout.out_str(" padded, one ghost border on every side\n");
    textout.out_str("store        ");
    textout.out_num(9 * 32768 * 8);
    textout.out_str(" bytes: nine fixed arrays, allocated once at module scope\n");
    textout.out_str("step         emitter -> viscosity -> project -> advect -> confine -> project -> drag\n");
    textout.out_str("projection   ");
    textout.out_num(ITERS);
    textout.out_str(" Gauss-Seidel sweeps x 2 a step");
    if (ITERS == 0) { textout.out_str("   (OFF: the field is left divergent on purpose)"); };
    textout.out_str("\n");
    textout.out_str("viscosity    ");
    textout.out_q(visc, 2);
    if (visc == 0) { textout.out_str("   inviscid"); };
    textout.out_str("\n");
    textout.out_str("confinement  ");
    textout.out_q(vort, 3);
    textout.out_str(" x 1000 vorticity\n");
    textout.out_str("damping      ");
    textout.out_q(damping, 3);
    textout.out_str(" x 1000      dye fade ");
    textout.out_q(decay, 3);
    textout.out_str(" x 1000\n");
    textout.out_str("emitter      swirl ");
    textout.out_q(swirl, 3);
    textout.out_str(" cells/step, ink ");
    textout.out_q(ink, 3);
    textout.out_str(" x 1000, radius ");
    textout.out_num(rad);
    textout.out_str(" cells, on the seeded orbit\n");
    textout.out_str("seed         ");
    textout.out_num(SEEDV);
    textout.out_str("\nfield        ");
    textout.out_str(NAMES[FLD]);
    if (FLD == 1) { textout.out_str("   colour = sign, glyph = |value|"); };
    if (GLY == 4) { textout.out_str("   glyph none: colour only"); };
    textout.out_str("\ngamma        1/");
    textout.out_num(GAMMA);
    textout.out_str(" on the magnitude ramp (display only; no number below depends on it)");
    if (GAMMA == 1) { textout.out_str("   LINEAR"); };
    textout.out_str("\nglyph        ");
    textout.out_str(GLYPHS[GLY]);
    // NOT an absolute, and deliberately so.  heap_used() counts the ARGUMENT
    // VECTOR, which the kernel allocated before this line ever ran, so an
    // absolute printed here moves with the length of the path fluid was invoked
    // by -- 36 bytes as ./fluid, 76 by absolute path -- and a golden holding one
    // is a golden that fails for a reason no amount of re-running will find.
    // The delta, measured either side of the step loop, does not: argv is
    // already in both readings, so it cancels.  It is in the summary.
    textout.out_str("\nheap         measured either side of the step loop; the delta is in the summary\n\n");

    textout.out_str("step   energy      vmax       dye mass   div rms      scale    digest\n");
    textout.out_str("       (Q28)     (cells/s)     (cells)    (Q12)      (cells/s)\n");

    measure();
    let f = 0;
    let dumped = 0;
    while (f <= FRAMES) {
        if (f > 0) { step_and_measure(); };
        render(srf);
        tui.capture_reset();
        tui.flush_diff(srf);
        textout.out_pad(f, 6);
        textout.out_str("  ");
        textout.out_q(E_LAST, 28);
        textout.out_str("  ");
        textout.out_q(V_LAST, 30);
        textout.out_str("  ");
        textout.out_q(M_LAST, 30);
        textout.out_str("  ");
        textout.out_q(D_LAST, 12);
        textout.out_str("  ");
        textout.out_q(SCALE, 30);
        textout.out_str("  ");
        textout.out_hex16(textout.grid_digest(srf));
        textout.out_str("\n");
        // The last frame always, and every --dump N.  The guard flag rather
        // than a `break`, and there is no `break` to reach for anyway.
        let want = f == FRAMES;
        if (DUMPEVERY > 0 && f > 0 && f % DUMPEVERY == 0) { want = true; };
        if (want) {
            textout.out_str("\n--- frame ");
            textout.out_num(f);
            textout.out_str(" ---\n");
            textout.grid_text(srf);
            dumped = dumped + 1
        };
        f = f + 1
    };
    let h1 = heap_used();
    let t1 = clock_us();

    textout.out_str("\nsummary\n");
    textout.out_str("steps        ");
    textout.out_num(FRAMES);
    textout.out_str("\nenergy       final ");
    textout.out_q(E_LAST, 28);
    textout.out_str("   peak ");
    textout.out_q(E_PEAK, 28);
    textout.out_str("\nmax speed    final ");
    textout.out_q(V_LAST, 30);
    textout.out_str("   peak ");
    textout.out_q(V_PEAK, 30);
    textout.out_str(" cells/step\n");
    textout.out_str("dye mass     final ");
    textout.out_q(M_LAST, 30);
    textout.out_str("   peak ");
    textout.out_q(M_PEAK, 30);
    textout.out_str(" cells\n");
    textout.out_str("div rms      final ");
    textout.out_q(D_LAST, 12);
    if (ITERS == 0) {
        textout.out_str("   the projection was OFF, so this is the whole divergence\n")
    } else {
        textout.out_str("   residual after the projection; README.md has the --iters table\n")
    };
    textout.out_str("frames dumped ");
    textout.out_num(dumped);
    textout.out_str("\nheap         used ");
    textout.out_num(h1 - h0);
    textout.out_str(" bytes over ");
    textout.out_num(FRAMES);
    textout.out_str(" steps   (a delta, not a total: heap_used() counts argv)\n");
    textout.out_flush();

    if (SHOWSTATS != 0) {
        let el = t1 - t0;
        eputs("fluid: ");
        eputs(tostring(FRAMES));
        eputs(" steps in ");
        eputs(tostring(el));
        eputs(" us = ");
        eputs(tostring(el / 1000));
        eputs(" ms -> ");
        eputs(tostring(if (el > 0) { FRAMES * 1000000 / el } else { 0 }));
        eputs(" steps/second on ");
        eputs(tostring(SC));
        eputs("x");
        eputs(tostring(grid_rows()));
        eputs(" with ");
        eputs(tostring(ITERS));
        eputs(" sweeps\nfluid: heap_used before=");
        eputs(tostring(h0));
        eputs(" after=");
        eputs(tostring(h1));
        eputs(" delta=");
        eputs(tostring(h1 - h0));
        eputs("\n")
    };
    exit(0)
};

// ═══════════════════════════════════════════════════ the interactive path ══
//
// tui's pattern verbatim: raw mode, alt screen, watchdog, and ONE place that
// leaves.  Y has no atexit and no signal handler, so every exit below is a call
// to tui.restore_all_exit() -- there is no path out of this loop that does not
// go through it.
if (!tui.raw_mode()) {
    eputs("fluid: not a terminal; try --frames N --no-tty\n");
    exit(1)
};
tui.enter_screen();
tui.arm_watchdog();

let pacer = tui.pacer_new(fpswant);
let meter = tui.fps_new();
tui.pacer_start(pacer);
measure();

let ih0 = heap_used();
let frame = 0;
let quit = false;
let checked = 0;
let WSB: [byte] = [0; 64];
let trows = SR;
let tcols = SC;

// poll_winsize() -> long -- 1 when the window changed, 0 when it did not (or the
// ioctl failed, or reported a degenerate size, which is what a pty with no
// TIOCSWINSZ looks like).
//
// TIOCGWINSZ into a byte buffer plus tui.rd16 IS tui.size(): the same decode,
// one syscall, zero bytes of heap.  tui.size() answers with a record, and a
// record literal is evaluated onto the heap every time the expression runs
// (ORCHESTRATOR.md 2.7), so a once-a-frame size check through it would leak
// 1.4 MB an hour.  Y has no SIGWINCH, so a program that wants to follow a
// resize has to poll.
def poll_winsize() -> long {
    if (syscall(16, 1, tui.TIOCGWINSZ, &WSB[0]) < 0) { return 0; };
    let r = tui.rd16(WSB, 0);
    let c = tui.rd16(WSB, 2);
    if (r < 5 || c < 12) { return 0; };
    if (r == trows && c == tcols) { return 0; };
    trows = r;
    tcols = c;
    1
};

while (quit == false) {
    let wait = tui.pacer_next(pacer);
    if (wait >= 0) {
        if (PAUSED == 0) { step_and_measure(); };
        render(srf);
        hud(srf, SR - 1, tui.fps_x100(meter) / 100);
        tui.flush_diff(srf);
        tui.fps_tick(meter);
        frame = frame + 1;
        // A guard flag instead of `break`; Y has no `break`.
        if (FRAMES > 0 && frame >= FRAMES) { quit = true; }
    };

    // Keys are polled on every other frame: read_key_timeout(0) is an immediate
    // poll, never a blocking read, so this costs one non-blocking read(2) and
    // 30 fps of key latency is 33 ms, which nobody can feel.
    checked = checked + 1;
    if (checked >= 2) {
        checked = 0;
        // Keys come back as bytes, so they are compared as bytes: Y has no
        // character literal and ord() is how a name becomes the byte it means.
        let k = tui.read_key_timeout(0);
        if (k == ord("q") || k == ord("Q") || k == tui.KEY_ESC) {
            quit = true
        } else if (k == tui.KEY_LEFT) {
            if (CFG.ex > 0) { CFG.ex = CFG.ex - 1; };
            DRIFT = 0
        } else if (k == tui.KEY_RIGHT) {
            if (CFG.ex < SC - 1) { CFG.ex = CFG.ex + 1; };
            DRIFT = 0
        } else if (k == tui.KEY_UP) {
            if (CFG.ey > 0) { CFG.ey = CFG.ey - 1; };
            DRIFT = 0
        } else if (k == tui.KEY_DOWN) {
            if (CFG.ey < grid_rows() - 1) { CFG.ey = CFG.ey + 1; };
            DRIFT = 0
        } else if (k == ord(" ")) {
            if (PAUSED != 0) { PAUSED = 0; } else { PAUSED = 1; }
        } else if (k == ord(".")) {
            step_and_measure()
        } else if (k == ord("d")) {
            // a dye blob right here, without touching the velocity field
            sim.emit(FL, CFG.ex, CFG.ey, 0, CFG.ink16 * 4, CFG.rad)
        } else if (k == ord("s")) {
            if (DRIFT != 0) { DRIFT = 0; } else { DRIFT = 1; }
        } else if (k == ord("r")) {
            sim.reset(FL, SEEDV, ITERS);
            emitter_home();
            E_PEAK = 0;
            V_PEAK = 0;
            M_PEAK = 0;
            measure()
        } else if (k == ord("v")) {
            if (FLD == 0) { FLD = 1; } else { if (FLD == 1) { FLD = 2; } else { FLD = 0; } }
        } else if (k == ord("g")) {
            if (GLY < 4) { GLY = GLY + 1; } else { GLY = 0; }
        } else if (k == ord("+") || k == ord("=")) {
            if (CFG.iters < 400) { CFG.iters = CFG.iters + 4; }
        } else if (k == ord("-") || k == ord("_")) {
            if (CFG.iters > 0) { CFG.iters = CFG.iters - 4; }
        };
        if (poll_winsize() != 0) {
            // A resize retunes the solver, and sim.setup() RESEEDS: the grid
            // the field was on no longer exists.  Said out loud rather than
            // hidden, because it is the one place a running simulation is
            // thrown away.
            SR = trows;
            SC = tcols;
            srf = tui.resize(srf, SR, SC);
            sim.setup(FL, SC, grid_rows(), SEEDV, ITERS);
            emitter_home();
            E_PEAK = 0;
            V_PEAK = 0;
            M_PEAK = 0;
            measure();
            // The notice goes through term's own byte buffer rather than
            // eputs(), because it is painted INSIDE the alt screen: eputs()
            // writes to fd 2, which is still the terminal, but tui.out_flush()
            // puts it in the same stream as the frames and in the same place
            // (the top-left corner, over the colour bar).
            tui.put_csi();
            tui.put_str("1;1H");
            tui.put_str("fluid: resized to ");
            tui.put_num(SC);
            tui.put_str(" x ");
            tui.put_num(SR);
            tui.put_str(", field re-seeded  ");
            tui.put_csi();
            tui.put_str("0m");
            tui.put_byte(10);
            tui.out_flush()
        }
    }
};

if (SHOWSTATS != 0) {
    let ih1 = heap_used();
    eputs("fluid: ");
    eputs(tostring(frame));
    eputs(" frames, heap_used ");
    eputs(tostring(ih0));
    eputs(" -> ");
    eputs(tostring(ih1));
    eputs(" delta ");
    eputs(tostring(ih1 - ih0));
    eputs("\n")
};
tui.restore_all_exit(0);