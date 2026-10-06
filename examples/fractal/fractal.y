// fractal.y -- a raymarched signed-distance-field scene, in a terminal.
//
//   usage: fractal [options]
//
// Four primitives -- a sphere, a yawed box, a tilted capsule and a ground plane
// -- welded together with a polynomial smooth-minimum, so they melt into one
// another instead of intersecting.  Every sample of the frame is a ray marched
// along that distance field until it reaches a surface; the surface is shaded
// from the SDF gradient with one ambient-occlusion tap, a Blinn highlight, a
// palette lookup and a fog into a gradient sky.
//
// All of it is integer fixed point.  Y has no float -> long and no cast syntax
// at all (ORCHESTRATOR.md 2.4a) and no math functions either (2.4b), so the
// maths is Q16 arithmetic with a hand-written integer sqrt (scene.y), and fx.y
// is called exactly twice a frame -- two sins and two cosines for the orbit.
//
//   build:  ycc -o fractal fractal.y    (fx.y tui tui tui args
//                                        scene.y and sink.y must sit beside it)
//   run:    ./fractal                        interactive: arrows orbit,
//          ./fractal --frames 2 --no-tty      + and - dolly, p cycles the
//                                            palette, q quits
//
// The geometry, the marcher and the palettes are all in scene.y.  This file is
// the command line, the cell assembly, the status line and the two frame loops.

import fx;
import args;
import scene;
import sink;
import check;
import tui;

// ─────────────────────────────────────────────────────────── glyph modes ───
//
// Four ways to spend one rendered sample on a terminal cell.  The choice is a
// real trade and the README says which way it went and why; this table is the
// whole of it:
//
//   glyph    sx  sy  glyph keys on        samples per cell
//   ascii     1   1  luminance             1
//   blocks    1   1  luminance             1
//   half      1   2  coverage: is the      2
//                     upper/lower half a
//                     surface hit
//   braille   2   4  coverage: which of    8
//                     the eight dots are
//
// so --glyph braille casts FOUR TIMES as many rays as --glyph half.  That is the
// argument for half as the default; the measured numbers are in the README's
// performance table.
let SXA: [long; 4] = [1, 1, 1, 2];
let SYA: [long; 4] = [1, 1, 2, 4];
let GLYPH: [str] = ["ascii", "blocks", "half", "braille"];
let GMODE_ASCII: long = 0;
let GMODE_BLOCKS: long = 1;
let GMODE_HALF: long = 2;
let GMODE_BRAILLE: long = 3;

let PALNAMES: [str] = ["ember", "ice", "spectrum", "mono", "phosphor"];

// ─────────────────────────────────────────────────────────────── options ───

let OPTS: [args.Opt] = [
    { long: "frames", short: "n", kind: args.NUM,
      help: "render exactly N frames, then exit 0 (default 0: run until q)" },
    { long: "size", short: "s", kind: args.STR,
      help: "WxH cells, at most 160x80; default the terminal, or 80x32 without one" },
    { long: "steps", short: "t", kind: args.NUM,
      help: "maximum march steps per ray, 1..4096 (default: from --quality)" },
    { long: "quality", short: "q", kind: args.NUM,
      help: "1..4, a preset for --steps: 40, 72, 112, 160 (default 2)" },
    { long: "glyph", short: "g", kind: args.STR,
      help: "ascii | blocks | half | braille   (half: two vertical levels a cell, the default)" },
    { long: "color", short: "c", kind: args.STR,
      help: "ember | ice | spectrum | mono | phosphor" },
    { long: "seed", short: "", kind: args.NUM,
      help: "0 (the default, no jitter) or 1..2147483647: a reproducible sub-sample jitter" },
    { long: "az", short: "a", kind: args.NUM,
      help: "opening azimuth in degrees, -360..360 (default 12.5)" },
    { long: "el", short: "e", kind: args.NUM,
      help: "opening elevation in degrees, -45..45 (default 2.0)" },
    { long: "dist", short: "", kind: args.NUM,
      help: "opening camera distance in scene units, 1..16 (default 4.6)" },
    { long: "fps", short: "f", kind: args.NUM,
      help: "frames per second, interactive only (default 15)" },
    { long: "no-tty", short: "", kind: args.BOOL,
      help: "render into a text capture instead of the terminal; never paces" },
    { long: "dump", short: "d", kind: args.STR,
      help: "comma-separated frame numbers to print as text beside their digest (default: the last frame)" },
    { long: "time", short: "", kind: args.BOOL,
      help: "report wall clock, fps, steps per ray and the heap delta on stderr when done" },
    { long: "check", short: "", kind: args.NUM,
      help: "run the property check over N camera poses and exit 0 or 1: the marched scene against a closed-form ray/sphere oracle, no reference file involved" },
    { long: "ansi", short: "", kind: args.STR,
      help: "headless only: also write the last frame's raw ANSI stream to FILE" }
];

// ───────────────────────────────────────────────────────────────── state ───
//
// The camera, in Q16 radians and Q16 scene units.  The initial pose is chosen so
// the frame is worth looking at: three quarters on, a little above the equator,
// far enough out that the plane's horizon sits high in the picture.
const AZ0: long = 14296;                //  0.2182 rad =  12.5 degrees
const EL0: long = 2294;                 //  0.0350 rad =   2.0 degrees
const D0: long = 301465;                //  4.6 scene units
const AZ_STEP: long = 734;              //  0.0112 rad a keypress =  0.64 degrees
const EL_STEP: long = 550;              //  0.0084 rad a keypress =  0.48 degrees
const EL_MAX: long = 51472;             // +45 degrees
const D_STEP: long = 3277;              //  0.05 scene units a keypress
const D_MIN: long = 65536;              //  1.0
const D_MAX: long = 1048576;            // 16.0

let AZ: long = AZ0;
let EL: long = EL0;
let D: long = D0;
let GM: long = GMODE_HALF;
let PAL: long = 0;
let SEED: long = 0;
let FRAMES: long = 0;
let NOTTY: long = 0;
let SHOWTIME: long = 0;
let FPSWANT: long = 15;
let QWANT: long = 2;
let STEPS: long = 72;
let SX: long = 1;
let SY: long = 2;

// QSTEPS is what --quality expands to, indexed from 1 so the number on the
// command line is the index a reader expects.
let QSTEPS: [long; 5] = [0, 40, 72, 112, 160];

// ─────────────────────────────────────────────────── the cell pass state ───
//
// The sample grid's dimensions, cached here as plain longs.  cell_half() and its
// siblings ask for them once a cell, and a module-level `long` is a load next to
// a call into another module -- which is the whole of the cell pass's cost
// budget once the marching is done.
let GW: long = 1;
let GH: long = 1;

// ───────────────────────────────────────────────────────── cell assembly ───
//
// One rendered sample per grid position; one terminal cell per SX x SY block of
// them.  Three routines, one per idea, and the third is the interesting one.
//
// HALF BLOCKS.  A cell is sampled twice, once for its upper half and once for
// its lower half, so the shading has two independent levels.  That is what a lit
// 3D surface needs and an ascii ramp cannot give it: ten glyphs of coverage
// cannot hold a gradient, and a coverage-keyed glyph makes every cell inside the
// silhouette the same full block.
//
// The glyph is tui.shade_half(level, 4), where level is 0..3 built as
// `upper_hit + 2*lower_hit`.  That is the toolkit's own four-entry half-block
// ramp reached through its own monotonic ramp_index -- ramp_index(level, 4, 4) is
// level -- so no codepoint is spelled out here.  The ramp is
// [space, UPPER HALF BLOCK, LOWER HALF BLOCK, FULL BLOCK], and a glyph paints its
// FILLED halves in the foreground and leaves its open halves to the cell
// BACKGROUND.  That is why level 2 has to swap: U+2584 fills the BOTTOM, so the
// colour that belongs to the lower sample is the one that has to be the
// foreground.  Levels 0 and 3 fill the whole cell with a single colour, so those
// average the two samples.
def cell_half(s: tui.Surface, r: long, c: long) -> void {
    let iu = (r * 2) * GW + c;
    let il = iu + GW;
    let lvl = scene.shit(iu) + 2 * scene.shit(il);
    let cp = tui.shade_half(lvl, 4);
    let cu = scene.scol(iu);
    let cl = scene.scol(il);
    if (lvl == 1) {
        tui.put(s, r, c, cp, cu, cl);
    } else if (lvl == 2) {
        tui.put(s, r, c, cp, cl, cu);
    } else {
        tui.put(s, r, c, cp, tui.lerp_rgb(cu, cl, 128), cu);
    }
};

// ASCII AND BLOCKS.  One sample a cell and the glyph carries the LUMINANCE,
// which is the classic choice and is exactly what those two ramps are for.  The
// background is the terminal default, so the surface sits on whatever the user's
// own background is -- tui.DEFAULT, not a colour of ours.
def cell_flat(s: tui.Surface, r: long, c: long) -> void {
    let i = r * GW + c;
    let lum = scene.slum(i);
    let cp = if (GM == GMODE_ASCII) { tui.shade_ascii(lum, 256) }
             else { tui.shade_blocks(lum, 256) };
    tui.put(s, r, c, cp, scene.scol(i), tui.DEFAULT)
};

// BRAILLE.  A cell is used as what it is -- a 2-wide by 4-tall dot bitmap -- so
// the glyph carries COVERAGE (which of the eight dots are surface) and the
// colour is the average of the surface samples that won.  Eight rays a cell, so
// four times the cost of half, and twice the horizontal and four times the
// vertical resolution against it.
//
// VS is a module-level growable [long] for two reasons: a fixed [long; 8] is not
// a [long] in Y, and a literal here would be an eight-element heap allocation
// once a cell.
let VS: [long] = [0; 8];

def cell_braille(s: tui.Surface, r: long, c: long) -> void {
    let base = (r * 4) * GW + c * 2;
    let sr = 0;
    let sg = 0;
    let sb = 0;
    let n = 0;
    let k = 0;
    while (k < 8) {
        let i = base + (k / 2) * GW + (k % 2);
        let hit = scene.shit(i);
        // tui.braille takes COVERAGE and sets a dot at or above the threshold, so
        // a hit is 255 and a miss 0
        VS[k] = hit * 255;
        if (hit != 0) {
            let col = scene.scol(i);
            sr = sr + tui.r_of(col);
            sg = sg + tui.g_of(col);
            sb = sb + tui.b_of(col);
            n = n + 1;
        };
        k = k + 1;
    };
    let cp = tui.braille(VS, 128);
    // The colours.  A braille cell is mostly BACKGROUND, so painting the surface
    // colour as the foreground on the terminal's own background turns a solid
    // lit surface into a sparse grid of dots on black -- technically correct and
    // unreadable.  So the average of the hits is the BASE, it goes in the cell
    // background, and the foreground is the same colour brightened; the dot mask
    // then reads as coverage of a brighter tint over the base, which is what a
    // 2x4 dot cell is actually good at.  Both factors are 0..255 scalings of the
    // same three channels, so this is six multiplies and a divide.
    if (n == 0) {
        // no hits: sky only.  Both samples are sky, so the base is the sky and
        // the dots are off; the cell is the background colour with a tint on top
        // of nothing.
        let c0 = scene.scol(base);
        tui.put(s, r, c, cp, shade_up(c0, 118), shade_dn(c0, 150));
    } else {
        let c1 = tui.rgb(sr / n, sg / n, sb / n);
        tui.put(s, r, c, cp, shade_up(c1, 118), shade_dn(c1, 150));
    }
};

// shade_up(c, k) -- the cell's brightened foreground: c's channels, times k
// over 255, so k > 255 clips and k = 255 is the colour itself.
def shade_up(c: long, k: long) -> long {
    tui.rgb((tui.r_of(c) * k) / 255, (tui.g_of(c) * k) / 255, (tui.b_of(c) * k) / 255)
};

// shade_dn(c, k) -- the cell's base colour: the same, scaled down.
def shade_dn(c: long, k: long) -> long {
    tui.rgb((tui.r_of(c) * k) / 255, (tui.g_of(c) * k) / 255, (tui.b_of(c) * k) / 255)
};

// assemble(s) -- the whole cell pass.  No allocation of any kind.
def assemble(s: tui.Surface) -> void {
    let r = 0;
    while (r < s.rows) {
        let c = 0;
        while (c < s.cols) {
            if (GM == GMODE_HALF) {
                cell_half(s, r, c);
            } else if (GM == GMODE_BRAILLE) {
                cell_braille(s, r, c);
            } else {
                cell_flat(s, r, c);
            };
            c = c + 1;
        };
        r = r + 1;
    }
};

// ─────────────────────────────────────────── allocation-free status line ───
//
// One integer, a digit at a time, straight into the surface.  A HUD that called
// tostring() once a frame would allocate on the frame loop, and this example's
// load-bearing measurement is that the frame loop does not.
//
// The digit scratch is module level for the same reason, and that is the sharp
// edge of the rule: an ARRAY LITERAL is evaluated onto the heap every time the
// expression runs -- 72 bytes for [long; 12], measured -- so a literal written
// inside this def would leak twice a frame.
let DIG: [long; 12] = [48; 12];

def sline(s: tui.Surface, row: long, col: long, v: long) -> long {
    let d = DIG;
    let q = if (v < 0) { 0 } else { v };
    let n = 0;
    while (q > 0 && n < 12) {
        d[11 - n] = 48 + q % 10;
        q = q / 10;
        n = n + 1;
    };
    let at = col;
    let i = 12 - n;
    while (i < 12) {
        tui.put(s, row, at, d[i], 150, tui.DEFAULT);
        at = at + 1;
        i = i + 1;
    };
    at
};

// q16to30(v) -- a Q16 scene value as a Q30 one, which is what fx.to_deg wants.
// << 14 is the conversion, and it is the only place in the program where the
// two fixed-point formats meet.
def q16to30(v: long) -> long { v << 14 };

def hud(s: tui.Surface, row: long, frame: long, fps: long) -> void {
    let bg = tui.rgb(12, 14, 18);
    let dim = tui.rgb(96, 104, 116);
    let key = tui.rgb(150, 160, 172);
    let warm = tui.rgb(226, 168, 84);
    for k in 0..s.cols { tui.put(s, row, k, 9472, tui.rgb(30, 34, 40), bg); };
    let c = 1;
    tui.text(s, row, c, "fractal", key, bg);
    c = c + 8;
    c = sline(s, row, c, frame);
    tui.text(s, row, c, "fps", dim, bg); c = c + 4;
    c = sline(s, row, c, fps);
    c = c + 1;
    tui.text(s, row, c, PALNAMES[PAL], warm, bg);
    c = c + len(PALNAMES[PAL]);
    tui.text(s, row, c, "az", dim, bg); c = c + 3;
    c = sline(s, row, c, fx.to_int(fx.to_deg(q16to30(AZ))));
    tui.text(s, row, c, "el", dim, bg); c = c + 3;
    c = sline(s, row, c, fx.to_int(fx.to_deg(q16to30(EL))));
    // the camera distance to one decimal, digit by digit: fx.to_str would
    // allocate a string once a frame, and this line runs once a frame
    tui.text(s, row, c, "d", dim, bg); c = c + 2;
    let d10 = (D * 10) / 65536;
    c = sline(s, row, c, d10 / 10);
    tui.put(s, row, c, 46, dim, bg); c = c + 1;
    c = sline(s, row, c, d10 % 10);
    tui.text(s, row, c, "steps", dim, bg); c = c + 6;
    c = sline(s, row, c, STEPS);
    c = c + 2;
    tui.text(s, row, c, "q quit   arrows orbit   +/- dolly   p palette", dim, bg)
};

// ──────────────────────────────────────────── allocation-free size poll ───
//
// Y has no SIGWINCH, so a program that wants to follow a terminal resize has to
// ask.  tui.size() is the right call and it is used once, at start-up -- but on
// a poll it is a leak: it ANSWERS WITH A RECORD, and a record literal is
// evaluated onto the heap every time the expression runs, so a once-a-frame size
// check would leak about 1.4 MB an hour.
//
// So the poll is TIOCGWINSZ into a byte buffer of our own plus tui.rd16, which
// is the very decode tui.size() performs -- same answer, one syscall, zero
// bytes of heap.  A [byte] has to be growable to be passed at all: a [byte; N]
// is not a [byte] in Y.
let WSB: [byte] = [0; 64];
let trows: long = 24;
let tcols: long = 80;

def poll_winsize() -> long {
    if (syscall(16, 1, tui.TIOCGWINSZ, &WSB[0]) < 0) { return 0; };
    let r = tui.rd16(WSB, 0);
    let c = tui.rd16(WSB, 2);
    if (r < 1 || c < 1) { return 0; };
    if (r == trows && c == tcols) { return 0; };
    trows = r;
    tcols = c;
    1
};

// ────────────────────────────────────────── the one-line stderr report ────
//
// Printed on both exits, on top of the alt screen rather than inside it.  The
// heap delta is the load-bearing number: it is the frame loop's whole memory
// behaviour, measured rather than asserted.
def report(n: long, bytes: long, fps: long, h0: long, h1: long) -> void {
    eputs("fractal: ");
    eputs(tostring(n));
    eputs(" frames, ");
    eputs(tostring(bytes / 1024));
    eputs(" KiB of ANSI in total, ");
    eputs(tostring(if (n > 0) { bytes / n } else { 0 }));
    eputs(" bytes a frame, measured ");
    eputs(tostring(fps));
    eputs(" fps, heap_used ");
    eputs(tostring(h0));
    eputs(" -> ");
    eputs(tostring(h1));
    eputs(" delta ");
    eputs(tostring(h1 - h0));
    eputs("\n");
};

// ────────────────────────────────────────────────────────── CLI plumbing ───

def die(msg: str) -> void {
    eputs("fractal: ");
    eputs(msg);
    eputs("\nfractal: try --help\n");
    exit(1)
};

def mode_of(name: str, what: str, allowed: [str]) -> long {
    let i = 0;
    while (i < len(allowed)) {
        if (allowed[i] == name) { return i; };
        i = i + 1;
    };
    let msg = "bad " + what + " '" + name + "'; expected one of: ";
    let j = 0;
    while (j < len(allowed)) {
        msg = msg + allowed[j];
        if (j + 1 < len(allowed)) { msg = msg + " | " };
        j = j + 1;
    };
    die(msg);
    0
};

// parse_size(s) -> long -- WxH packed as W*1000000 + H, 0 if the string is not
// that shape, or -1 if it is a degenerate size.  Slicing rather than a
// hand-rolled byte scan, because a string slice is the clearest thing here and it
// allocates once, at start-up.
//
// A degenerate size is REFUSED, not clamped: 0x0 has no frame to render, and
// quietly clamping it to 1x1 would answer a question nobody asked -- and the
// gate asks for a clean diagnostic.  A size past the cap IS clamped, because
// that is a request rather than a mistake, and the cap is a property of the
// sample store, not of the picture.
def parse_size(s: str) -> long {
    let at = s.index_of("x");
    if (at < 1) { return 0; };
    let a = s[0:at];
    let b = s[at + 1:];
    if (!args.num_ok(a) || !args.num_ok(b)) { return 0; };
    let w = tonum(a);
    let h = tonum(b);
    if (w < 1 || h < 1) { return -1; };
    if (w > scene.MAXC) { w = scene.MAXC; };
    if (h > scene.MAXR) { h = scene.MAXR; };
    w * 1000000 + h
};

// Frames the deterministic run prints in full.  want_dump is one bit per frame
// index; DUMPS is the same set in the order --dump listed it, for the header.
let want_dump: [long; 4096] = [0; 4096];
let NDUMP: long = 0;
let DUMPS: [long; 32] = [0; 32];

def load_dumps(s: str, last: long) -> void {
    if (s == "") {
        // the default is the last frame, which is the one a reader wants to see
        // and the one a golden file should hold
        if (last >= 0 && last < FRAMES) {
            want_dump[last] = 1;
            NDUMP = 1;
            DUMPS[0] = last;
        };
        return;
    };
    let parts = s.split(",");
    for k in 0..len(parts) {
        let p = parts[k];
        if (len(p) > 0 && args.num_ok(p)) {
            let v = tonum(p);
            // a frame the run will not reach is not a frame it can dump, and
            // listing it in the header would promise something the output does
            // not contain
            if (v >= 0 && v < FRAMES) {
                if (want_dump[v] == 0) {
                    want_dump[v] = 1;
                    if (NDUMP < 32) { DUMPS[NDUMP] = v; NDUMP = NDUMP + 1; };
                };
            };
        };
    }
};

// ─────────────────────────────────────────────────────── argument parsing ───

args.init("fractal", "a raymarched signed-distance-field scene, in a terminal.",
          OPTS);
let st = args.parse(argv());
if (st == args.HELP) {
    puts(args.usage());
    puts("\nthe scene: a ground plane at y = -1.10 carrying a sphere, a yawed box\n");
    puts("and a tilted capsule, the three objects welded to the plane and to each\n");
    puts("other with a polynomial smooth-minimum.  The march is sphere tracing: the\n");
    puts("step IS the distance field, so the step length falls to nothing as the\n");
    puts("ray lands and no epsilon is needed to stop it overshooting.  The normal is\n");
    puts("the SDF gradient, estimated with three taps that reuse the distance the\n");
    puts("last march step already computed.\n");
    puts("\npalettes:\n");
    puts("  ember     warm and dark, sweeping maroon -> orange -> gold (default)\n");
    puts("  ice       cold, high blue\n");
    puts("  spectrum  the whole wheel, in phase-offset thirds\n");
    puts("  mono      plain grey, for reading the geometry without the colour\n");
    puts("  phosphor  green, the classic terminal\n");
    puts("\nglyph modes:\n");
    puts("  ascii     ' .:-=+*#%@' by luminance, one ray a cell\n");
    puts("  blocks    tui's shade-block ramp by luminance, 5 levels\n");
    puts("  half      tui's half-block ramp: TWO rays a cell, one for the upper\n");
    puts("            half and one for the lower.  The glyph says which halves are\n");
    puts("            surface, and the two colours ride in the cell foreground and\n");
    puts("            background, so the shading is two levels a row\n");
    puts("  braille   U+2800+mask by coverage: EIGHT rays a cell, and twice the\n");
    puts("            horizontal and four times the vertical resolution\n");
    puts("\nkeys, interactive:  q or Escape quit, arrows orbit, +/- dolly,\n");
    puts("                    p cycles the palette, space pauses, r resets\n");
    puts("\nthe property check:\n");
    puts("  --check N is not a golden file.  It asserts things about the geometry\n");
    puts("  that no reference file can be regenerated to agree with, and exits 1 if\n");
    puts("  any of them fails.  The scene contains a real sphere, so for every ray\n");
    puts("  the closed-form quadratic ray/sphere intersection is available in exact\n");
    puts("  integer arithmetic, and that oracle never marches: it cannot share a bug\n");
    puts("  with map() or the marcher.  It checks the marched depth against the\n");
    puts("  analytic root, that rays which provably miss never stop on the sphere,\n");
    puts("  that the drawn silhouette IS the tangent cone's ellipse, that the step\n");
    puts("  budget does not change the hit set over the objects, and that where the\n");
    puts("  box and the sphere overlap the nearer surface wins.  N is the number of\n");
    puts("  camera poses; it needs no terminal and ignores --size, because its own\n");
    puts("  answer must not depend on the window it was run in.\n");
    exit(0)
};
if (st == args.USAGE) {
    eputs("fractal: try --help\n");
    exit(1)
};

if (len(args.positional()) > 0) {
    die("takes no operands; got '" + args.positional()[0] + "'")
};

GM = mode_of(args.get_str("glyph", "half"), "--glyph", GLYPH);
PAL = mode_of(args.get_str("color", "ember"), "--color", PALNAMES);
FRAMES = args.get_long("frames", 0);
FPSWANT = args.get_long("fps", 15);
if (FPSWANT < 1) { FPSWANT = 1; };
if (FPSWANT > 240) { FPSWANT = 240; };
NOTTY = if (args.has("no-tty")) { 1 } else { 0 };
SHOWTIME = if (args.has("time")) { 1 } else { 0 };

// --quality and --steps are one knob at two altitudes: the preset expands to a
// step count and an explicit --steps overrides it.  Which one won is printed in
// the header, because "quality 3" means 112 steps today and 96 next release.
QWANT = args.get_long("quality", 2);
if (QWANT < 1 || QWANT > 4) {
    die("--quality wants 1..4 (40, 72, 112 or 160 march steps)")
};
STEPS = QSTEPS[QWANT];
if (args.has("steps")) {
    let sv = args.get_long("steps", 0);
    if (sv < 1 || sv > 4096) { die("--steps wants 1..4096") };
    STEPS = sv;
};

// The opening camera, so a view can be scripted.  Degrees in, because that is
// what a reader has; Q16 radians out, because that is what the marcher takes.
// Two conversions, both of which are a trap.  fx.DEG and fx.RAD are Q30 *per
// unit*, so fx.to_rad's argument is a Q30 DEGREE COUNT: to_rad(90) is to_rad of
// 90/2^30 of a degree, and answers 0, not 1.5708.  The shift by 30 is not
// optional.  And getting Q30 back to Q16 is a shift of 14, not an fx.mul: an
// fx.mul second argument is itself a Q30 value, so "multiply by 16384" would mean
// 16384/2^30 and every angle would come out a quarter of what was asked for.
if (args.has("az")) {
    let av = args.get_long("az", 0);
    if (av < -360 || av > 360) { die("--az wants -360..360 degrees") };
    AZ = fx.to_rad(av << 30) >> 14;
};
if (args.has("el")) {
    let ev = args.get_long("el", 0);
    if (ev < -45 || ev > 45) { die("--el wants -45..45 degrees") };
    EL = fx.to_rad(ev << 30) >> 14;
};
if (args.has("dist")) {
    let dv = args.get_long("dist", 0);
    if (dv < 1 || dv > 16) { die("--dist wants 1..16 scene units") };
    D = dv * 65536;
};

// --seed is the only stochastic knob and it is off unless asked for: 0 means no
// jitter at all, which is what makes the documented run byte-identical.  A
// negative seed is refused rather than clamped, because -1 is a mistake and the
// message is the useful answer.
let seedv = args.get_long("seed", 0);
if (seedv < 0 || seedv > 2147483647) { die("--seed wants 0..2147483647") };
SEED = seedv;

// --check N runs the property check instead of the picture: the marched scene
// against a closed-form ray/sphere oracle, asserted with no reference file
// involved.  It implies --no-tty, because it must give the same answer in a
// window of any shape and on a machine with no window at all -- and it renders at
// its OWN fixed size, so --size does not change what it measures.
let CHECK = args.get_long("check", 0);
if (CHECK < 0 || CHECK > 64) { die("--check wants 0 (off) to 64 camera poses") };
// A lower bound, and it is a statistical one rather than an arbitrary taste: the
// suite asserts on populations -- T1's well-conditioned core subset, T5's pixels
// where the box and the sphere both sit well apart -- and it deliberately FAILS
// when a population is too small to mean anything ("T5 too few overlapping pixels
// to mean anything").  With one or two poses those populations are a handful of
// samples, so the suite would report a failure about sample size while saying
// nothing about the geometry.  Saying so here is the honest version of the same
// fact: a check that cannot mean anything should say so, not print FAIL.
// 8 poses is the smallest count that satisfies every precondition; it is a floor,
// not a recommendation -- 24 is what the gate runs.
if (CHECK > 0 && CHECK < 8) {
    die("--check needs at least 8 camera poses to mean anything; try 24");
};
if (CHECK != 0) { NOTTY = 1; };

// The size, decided before anything is built: the sample grid and the surface
// must agree, so both come from the same two numbers.
let ws = tui.size();
trows = ws.rows;
tcols = ws.cols;
let grow = 0;
let gcol = 0;
let HAVE_SIZE = args.has("size");
if (HAVE_SIZE) {
    let sz = parse_size(args.get_str("size", ""));
    if (sz == -1) { die("--size wants a positive WxH, e.g. --size 80x24") };
    if (sz == 0) { die("--size wants WxH, e.g. --size 80x24") };
    gcol = sz / 1000000;
    grow = sz % 1000000;
};
if (NOTTY != 0) {
    // there is no terminal to ask, so without --size the size is a fixed
    // default.  That is what makes the documented run reproducible on a machine
    // whose window happens to be a different shape.
    if (HAVE_SIZE == false) { gcol = 80; grow = 32; };
    if (FRAMES < 1) { FRAMES = 1; };
} else {
    // one row of the terminal is the status line
    grow = ws.rows - 1;
    gcol = ws.cols;
    if (grow < 2) { grow = 2; };
    if (gcol < 4) { gcol = 4; };
};
if (grow > scene.MAXR) { grow = scene.MAXR; };
if (gcol > scene.MAXC) { gcol = scene.MAXC; };

SX = SXA[GM];
SY = SYA[GM];
scene.qseed_init();
scene.palette_init();
scene.palette(PAL);
scene.set_steps(STEPS);
scene.set_camera(AZ, EL, D);
scene.grid_setup(gcol, grow, SX, SY);
GW = scene.grid_w();
GH = scene.grid_h();
let SR: long = grow;
let SC: long = gcol;
let srf = tui.new(SR, SC);
let RAYS = GW * GH;
load_dumps(args.get_str("dump", ""), FRAMES - 1);

// ═══════════════════════════════════════════════════ the property check ═══
//
// Placed before the deterministic path because it replaces it: --check answers a
// question about the geometry, not about the picture, and it prints its own
// report on stdout and exits 0 or 1.  check.y owns the whole of it -- the
// closed-form sphere, the tangent cone's ellipse, the closed-form box and every
// assertion -- and all that happens here is that it is handed a number.
if (CHECK > 0) {
    exit(check.run(CHECK))
};

// ══════════════════════════════════════════════ the deterministic path ═══
//
// The same scene, the same marcher, the same cell pass and the same
// tui.flush_diff as the terminal path -- the ANSI stream is built and counted
// either way, which is what makes the `bytes` column in the digest evidence
// rather than a claim -- except that it goes to /dev/null and the text goes to
// stdout instead.
//
// NO PACING HERE, deliberately.  This path exists to answer "how fast can this
// machine march frames", and a sleep in the middle of it would measure
// nanosleep instead.  --fps is an interactive knob.
//
// NO HUD HERE either: a status line carrying a frame rate cannot be
// byte-identical between two runs.
if (NOTTY != 0) {
    let devnull = syscall(257, 0 - 100, "/dev/null", 1, 0, 0, 0);   // openat
    if (devnull >= 0) { tui.set_fd(devnull); };
    tui.capture_on();

    sink.out_str("fractal: frames=");
    sink.out_num(FRAMES);
    sink.out_str(" size=");
    sink.out_num(SC);
    sink.out_str("x");
    sink.out_num(SR);
    sink.out_str(" glyph=");
    sink.out_str(GLYPH[GM]);
    sink.out_str(" color=");
    sink.out_str(PALNAMES[PAL]);
    sink.out_str(" steps=");
    sink.out_num(STEPS);
    sink.out_str(" quality=");
    sink.out_num(QWANT);
    sink.out_str(" seed=");
    sink.out_num(SEED);
    sink.out_str(" rays/frame=");
    sink.out_num(RAYS);
    sink.out_str("\ndumped frames:");
    for k in 0..NDUMP {
        sink.out_str(" ");
        sink.out_num(DUMPS[k]);
    };
    sink.out_str("\n");

    // --ansi FILE: the raw byte stream the framebuffer built, straight into a
    // file.  The headless path otherwise throws it away, and it is the one form
    // of the picture that keeps the colour -- this folder's golden/ holds the
    // text frames, and this is how you get a truecolor one out to look at.
    // Only the last frame is written, because that is the one a reader wants;
    // the capture buffer is bounded, so writing all of them would not fit.
    let ansifd = -1;
    let want_ansi = args.has("ansi");
    if (want_ansi) {
        // O_WRONLY|O_CREAT|O_TRUNC = 577 on x86-64
        ansifd = syscall(257, 0 - 100, args.get_str("ansi", ""), 577, 420, 0, 0);
        if (ansifd < 0) { die("cannot open --ansi file '" + args.get_str("ansi", "") + "'") };
    };

    let h0 = heap_used();
    let t0 = clock_us();
    let f = 0;
    while (f < FRAMES) {
        // the orbit advances one keypress-step a frame, so consecutive frames
        // differ and the per-frame digest is worth having
        scene.set_camera(AZ + f * AZ_STEP, EL, D);
        scene.render(SEED, f);
        assemble(srf);
        tui.capture_reset();
        tui.flush_diff(srf);
        sink.out_str("frame ");
        sink.out_pad(f, 5);
        sink.out_str(" bytes ");
        sink.out_pad(tui.frame_bytes(), 8);
        sink.out_str(" rows ");
        sink.out_pad(tui.row_count(), 5);
        sink.out_str(" hits ");
        sink.out_pad(scene.hits(), 7);
        sink.out_str(" hitpc ");
        sink.out_pad((scene.hits() * 100) / RAYS, 3);
        sink.out_str(" astep ");
        sink.out_pad(scene.steps_used() / RAYS, 4);
        sink.out_str(" sha ");
        sink.out_hex16(sink.grid_digest(srf));
        if (ansifd >= 0 && f == FRAMES - 1) {
            // point the emitter at the file and repaint in full, so what lands
            // there is the frame and not a diff against whatever came before it
            tui.set_fd(ansifd);
            tui.flush(srf);
            tui.set_fd(devnull);
        };
        if (want_dump[f] != 0) {
            sink.out_str("\n--- frame ");
            sink.out_num(f);
            sink.out_str(" ---\n");
            sink.grid_text(srf);
        };
        sink.out_str("\n");
        f = f + 1;
    };
    if (ansifd >= 0) {
        // tui.spill() has already pushed the last flush down its own pipe; this is
        // fb's capture buffer, which holds the same bytes and is what the
        // headless path has been counting all along
        sink.out_capture(ansifd, tui.capture_len());
        syscall(3, ansifd, 0, 0, 0, 0, 0);      // close(2)
    };
    let t1 = clock_us();
    let h1 = heap_used();
    sink.out_flush();

    if (SHOWTIME != 0) {
        let el = t1 - t0;
        let per = el / FRAMES;
        let x100 = if (per > 0) { 10000000 / per } else { 0 };
        eputs("fractal: ");
        eputs(tostring(FRAMES));
        eputs(" frames in ");
        eputs(tostring(el));
        eputs(" us = ");
        eputs(tostring(el / 1000));
        eputs(" ms -> ");
        eputs(tostring(x100 / 100));
        eputs(".");
        let frac = x100 % 100;
        eputs(tostring(frac));
        if (frac < 10) { eputs("0") };
        eputs(" fps\nfractal: ");
        eputs(tostring(SC));
        eputs("x");
        eputs(tostring(SR));
        eputs(" ");
        eputs(GLYPH[GM]);
        eputs(" steps=");
        eputs(tostring(STEPS));
        eputs(" rays/frame=");
        eputs(tostring(RAYS));
        eputs(" avg march steps/ray (last frame)=");
        eputs(tostring(scene.steps_used() / RAYS));
        eputs("\nfractal: heap_used before=");
        eputs(tostring(h0));
        eputs(" after=");
        eputs(tostring(h1));
        eputs(" delta=");
        eputs(tostring(h1 - h0));
        eputs("\n");
    };
    exit(0)
};

// ═══════════════════════════════════════════════════ the interactive path ══
//
// tui's pattern verbatim: raw mode, alt screen, watchdog, and ONE place that
// leaves.  Y has no atexit and no signal handler, so every exit below is a call
// to tui.restore_all_exit() -- there is no path out of this loop that does not
// go through it -- and a SIGKILL of the program is covered by the watchdog,
// which restores the saved termios itself.
if (!tui.raw_mode()) {
    eputs("fractal: not a terminal; try --frames N --no-tty\n");
    exit(1)
};
tui.enter_screen();
tui.arm_watchdog();

let pacer = tui.pacer_new(FPSWANT);
let meter = tui.fps_new();
tui.pacer_start(pacer);

let frame = 0;
let quit = false;
let paused = 0;
let checked = 0;
let bytes_sum = 0;
let ih0 = heap_used();

while (quit == false) {
    let wait = tui.pacer_next(pacer);
    if (wait >= 0) {
        if (paused == 0) {
            AZ = AZ + AZ_STEP;
            scene.set_camera(AZ, EL, D);
        };
        scene.render(SEED, frame);
        assemble(srf);
        hud(srf, SR - 1, frame, tui.fps_x100(meter) / 100);
        bytes_sum = bytes_sum + tui.flush_diff(srf);
        tui.fps_tick(meter);
        frame = frame + 1;
        if (FRAMES > 0 && frame >= FRAMES) {
            report(frame, bytes_sum, tui.fps_x100(meter) / 100, ih0, heap_used());
            tui.restore_all_exit(0)
        };
    };

    // Poll the keyboard on every frame when nobody is timing us and every fourth
    // frame when they are: 13 ms of key latency at 20 fps, and
    // read_key_timeout(0) is an immediate poll, never a blocking read.  A resize
    // is looked for on the same beat, because Y has no SIGWINCH.
    checked = checked + 1;
    if (checked >= 4 || FRAMES == 0) {
        checked = 0;
        // keys come back as bytes, so they are compared as bytes: Y has no char
        // literal, and ord() is how a name becomes the byte it means.
        let k = tui.read_key_timeout(0);
        let moved = 0;
        if (k == ord("q") || k == ord("Q") || k == tui.KEY_ESC) {
            quit = true;
        } else if (k == ord("p") || k == ord("P")) {
            PAL = (PAL + 1) % scene.NPAL;
            scene.palette(PAL);
        } else if (k == ord(" ")) {
            if (paused != 0) { paused = 0; } else { paused = 1; };
        } else if (k == ord("r")) {
            AZ = AZ0; EL = EL0; D = D0;
            moved = 1;
        } else if (k == ord("+") || k == ord("=")) {
            if (D < D_MAX) { D = D + D_STEP; };
            moved = 1;
        } else if (k == ord("-") || k == ord("_")) {
            if (D > D_MIN) { D = D - D_STEP; };
            moved = 1;
        } else if (k == tui.KEY_LEFT) {
            AZ = AZ - AZ_STEP;
            moved = 1;
        } else if (k == tui.KEY_RIGHT) {
            AZ = AZ + AZ_STEP;
            moved = 1;
        } else if (k == tui.KEY_UP) {
            EL = EL + EL_STEP;
            moved = 1;
        } else if (k == tui.KEY_DOWN) {
            EL = EL - EL_STEP;
            moved = 1;
        };
        if (moved != 0) {
            if (EL > EL_MAX) { EL = EL_MAX; };
            if (EL < 0 - EL_MAX) { EL = 0 - EL_MAX; };
            if (D > D_MAX) { D = D_MAX; };
            if (D < D_MIN) { D = D_MIN; };
            scene.set_camera(AZ, EL, D);
        };
        if (poll_winsize() != 0) {
            let nr = trows - 1;
            let nc = tcols;
            if (nr < 2) { nr = 2; };
            if (nr > scene.MAXR) { nr = scene.MAXR; };
            if (nc < 4) { nc = 4; };
            if (nc > scene.MAXC) { nc = scene.MAXC; };
            srf = tui.resize(srf, nr, nc);
            SR = nr;
            SC = nc;
            scene.grid_setup(SC, SR, SX, SY);
            GW = scene.grid_w();
            GH = scene.grid_h();
            RAYS = GW * GH;
        };
    };
};

report(frame, bytes_sum, tui.fps_x100(meter) / 100, ih0, heap_used());
tui.restore_all_exit(0);
