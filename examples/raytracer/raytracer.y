// raytracer.y -- a reflective raytracer, in a terminal framebuffer.
//
//   usage: raytracer [options]
//
// One ray per sample through a pinhole camera into a small scene of four
// spheres and two planes, shading by depth (fog) and normal (diffuse plus a
// Blinn highlight), recursing on reflection to a hard depth cap, and shading
// the result through tui's surface with one of four ramps.
//
//   build:  ycc -o raytracer raytracer.y    (scene.y, sink.y, check.y and the
//                                             vendored toolkit must sit beside it)
//   run:    ./raytracer                      interactive: arrows orbit,
//          ./raytracer --frames 2 --no-tty   +/- dolly, p palette, g glyph,
//                                            b bounces, q quits
//
// The geometry, the intersection, the shading and the camera are all in
// scene.y.  This file is the command line, the cell assembly, the status line
// and the two frame loops.

import fx;
import args;
import scene;
import sink;
import check;
import tui;

// ─────────────────────────────────────────────────────────── glyph modes ───
//
//   glyph    sx  sy  the glyph keys on        samples a cell
//   ascii     1   1  luminance                1
//   blocks    1   1  luminance                1
//   half      1   2  coverage: which halves   2
//                  are surface
//   braille   2   4  coverage: which of the   8
//                  eight dots are surface
//
// so --glyph braille casts FOUR TIMES as many rays as --glyph half.  The reason
// half is the default is in the README: a coverage-keyed glyph saturates inside
// the silhouette, so every cell in the middle of a lit sphere comes out as the
// same full block and the shading has nowhere to go.  Half carries the two
// halves' colours in the cell foreground and background, which is two
// independent levels a row for twice the cost of ascii rather than four times.
let SXA: [long; 4] = [1, 1, 1, 2];
let SYA: [long; 4] = [1, 1, 2, 4];
let GLYPH: [str] = ["ascii", "blocks", "half", "braille"];
const GMODE_ASCII: long = 0;
const GMODE_BLOCKS: long = 1;
const GMODE_HALF: long = 2;
const GMODE_BRAILLE: long = 3;

let PALNAMES: [str] = ["ember", "ice", "spectrum", "mono", "phosphor"];

// ───────────────────────────────────────────────────────────────── options ───

let OPTS: [args.Opt] = [
    { long: "frames", short: "n", kind: args.NUM,
      help: "render exactly N frames, then exit 0 (default 0: run until q)" },
    { long: "size", short: "s", kind: args.STR,
      help: "WxH cells, at most 160x80; default the terminal, or 80x32 without one" },
    { long: "glyph", short: "g", kind: args.STR,
      help: "ascii | blocks | half | braille   (half: the default)" },
    { long: "color", short: "c", kind: args.STR,
      help: "ember | ice | spectrum | mono | phosphor" },
    { long: "bounces", short: "b", kind: args.NUM,
      help: "reflection depth cap, 0..8 (default 3)" },
    { long: "fov", short: "f", kind: args.NUM,
      help: "horizontal half-angle in degrees, 5..80 (default 32)" },
    { long: "seed", short: "", kind: args.NUM,
      help: "0 (the default, no jitter) or 1..2147483647: a reproducible sub-sample jitter" },
    { long: "az", short: "a", kind: args.NUM,
      help: "opening azimuth in degrees, -360..360 (default 0)" },
    { long: "el", short: "e", kind: args.NUM,
      help: "opening elevation in degrees, -45..45 (default 8)" },
    { long: "dist", short: "", kind: args.NUM,
      help: "opening camera distance in scene units, 1..16 (default 6)" },
    { long: "fps", short: "", kind: args.NUM,
      help: "frames per second, interactive only (default 20)" },
    { long: "no-tty", short: "", kind: args.BOOL,
      help: "render into a text capture instead of the terminal; never paces" },
    { long: "dump", short: "d", kind: args.STR,
      help: "comma-separated frame numbers to print as text (default: the last frame)" },
    { long: "time", short: "", kind: args.BOOL,
      help: "report wall clock, fps, rays a frame and the heap delta on stderr" },
    { long: "check", short: "", kind: args.NUM,
      help: "run the property check and exit 0 or 1: the tracer against analytic geometry computed outside it, no reference file involved" },
    { long: "ansi", short: "", kind: args.STR,
      help: "headless only: also write the last frame's raw ANSI to FILE" }
];

// ───────────────────────────────────────────────────────────────── state ────
//
// az/el are Q16 radians, dist is Q16 units.  The opening pose is 8 degrees up,
// six units back and dead ahead of the crimson sphere -- chosen by LOOKING at
// the frames, not by reasoning about them: far enough that the sphere does not
// fill the width, low enough that the three of them still overlap, and high
// enough that the floor's checkerboard runs away under the sphere's reflection.
const AZ0: long = 0;
const EL0: long = 8738;                 //  0.1333 rad =  7.6 degrees
const D0: long = 393216;                //  6.0 scene units
const AZ_STEP: long = 734;              //  0.0112 rad a keypress =  0.64 degrees
const EL_STEP: long = 550;              //  0.0084 rad a keypress =  0.48 degrees
const EL_MAX: long = 51472;             // +45 degrees
const D_STEP: long = 3277;              //  0.05 units a keypress
const D_MIN: long = 65536;              //  1.0
const D_MAX: long = 1048576;            // 16.0

let AZ: long = AZ0;
let EL: long = EL0;
let DDIST: long = D0;
let GM: long = GMODE_HALF;
let PAL: long = 0;
let SEED: long = 0;
let FRAMES: long = 0;
let NOTTY: long = 0;
let SHOWTIME: long = 0;
let FPSWANT: long = 20;
let FOVDEG: long = 32;
let BNCE: long = 3;
let GW: long = 1;
let GH: long = 1;

// ───────────────────────────────────────────────────────── cell assembly ───

// cell_half -- a cell sampled twice, once per vertical half, so the shading has
// two independent levels a row.  The glyph is tui.shade_half(lvl, 4), where lvl
// is 0..3 built as upper_hit + 2*lower_hit; that is the toolkit's own four
// entry half-block ramp through its own monotonic ramp_index, so no codepoint
// is spelled out here.
//
// A glyph paints its FILLED halves in the foreground and leaves its open
// halves to the cell BACKGROUND, which is why level 2 has to swap: U+2584
// fills the BOTTOM, so the colour that belongs to the lower sample is the one
// that has to be the foreground.  Levels 0 and 3 fill the whole cell with one
// colour, so those average the two.
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

// cell_flat -- one sample a cell and the glyph carries the LUMINANCE, which is
// what the ascii and blocks ramps are for.  The background is the terminal's
// own, not a colour of ours.
def cell_flat(s: tui.Surface, r: long, c: long) -> void {
    let i = r * GW + c;
    let cp = if (GM == GMODE_ASCII) {
        tui.shade_ascii(scene.lum(scene.scol(i)), 256)
    } else {
        tui.shade_blocks(scene.lum(scene.scol(i)), 256)
    };
    tui.put(s, r, c, cp, scene.scol(i), tui.DEFAULT)
};

// cell_braille -- a cell used as what it is, a 2-wide by 4-tall dot bitmap, so
// the glyph carries COVERAGE and the colour is the average of the samples that
// won.  Eight rays a cell: four times the cost of half.
//
// A braille cell is mostly BACKGROUND, so painting the surface colour as the
// foreground turns a solid lit sphere into a sparse grid of dots on black --
// technically correct and unreadable.  So the average of the hits goes in the
// background and the foreground is the same colour brightened, and the dot mask
// reads as coverage of a brighter tint over the base, which is what a 2x4 dot
// cell is actually good at.
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
        // tui.braille takes COVERAGE and sets a dot at or above the threshold, so
        // a hit is 255 and a miss 0
        VS[k] = scene.shit(i) * 255;
        if (scene.shit(i) != 0) {
            let col = scene.scol(i);
            sr = sr + tui.r_of(col);
            sg = sg + tui.g_of(col);
            sb = sb + tui.b_of(col);
            n = n + 1;
        };
        k = k + 1;
    };
    let cp = tui.braille(VS, 128);
    if (n == 0) {
        let c0 = scene.scol(base);
        tui.put(s, r, c, cp, tint(c0, 200), tint(c0, 128));
    } else {
        let c1 = tui.rgb(sr / n, sg / n, sb / n);
        tui.put(s, r, c, cp, tint(c1, 200), tint(c1, 128));
    }
};

// tint(c, k) -- c's channels scaled by k over 255, so 255 is the colour itself
// and 128 is half of it.  Two multiplies and two divisions a channel.
def tint(c: long, k: long) -> long {
    tui.rgb((tui.r_of(c) * k) / 255, (tui.g_of(c) * k) / 255, (tui.b_of(c) * k) / 255)
};

// assemble(s) -- the whole cell pass, zero allocation of any kind.
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
// tostring() once a frame would allocate on the frame path, and "the frame loop
// does not allocate" is this example's load-bearing measurement.
//
// The digit scratch is module level for the sharp edge of that rule: an ARRAY
// LITERAL is evaluated onto the heap every time the expression runs -- 72 bytes
// for [long; 12], measured -- so a literal written inside this def would leak
// twice a frame.
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

// q16to30(v) -- a Q16 value as a Q30 one, which is what fx.to_deg wants.  << 14
// is the conversion, and it is the only place the two fixed-point formats meet.
def q16to30(v: long) -> long { v << 14 };

def hud(s: tui.Surface, row: long, frame: long, fps: long) -> void {
    let bg = tui.rgb(12, 14, 18);
    let dim = tui.rgb(96, 104, 116);
    let key = tui.rgb(150, 160, 172);
    let warm = tui.rgb(226, 168, 84);
    for k in 0..s.cols { tui.put(s, row, k, 9472, tui.rgb(30, 34, 40), bg); };
    let c = 1;
    tui.text(s, row, c, "raytracer", key, bg);
    c = c + 10;
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
    tui.text(s, row, c, "d", dim, bg); c = c + 2;
    let d10 = (DDIST * 10) / 65536;
    c = sline(s, row, c, d10 / 10);
    tui.put(s, row, c, 46, dim, bg); c = c + 1;
    c = sline(s, row, c, d10 % 10);
    tui.text(s, row, c, "bounce", dim, bg); c = c + 7;
    c = sline(s, row, c, BNCE);
    c = c + 2;
    tui.text(s, row, c, "q quit   arrows orbit   +/- dolly   p palette   g glyph   b bounces",
            dim, bg)
};

// ──────────────────────────────────────────── allocation-free size poll ───
//
// Y has no SIGWINCH, so a program that wants to follow a resize has to ask.
// tui.size() is the right call and it is used ONCE, at start-up -- but on a
// poll it is a leak: it ANSWERS WITH A RECORD, and a record literal is
// evaluated onto the heap every time the expression runs, so a once-a-frame
// size check would leak about 1.4 MB an hour.
//
// So the poll is TIOCGWINSZ into a byte buffer of our own plus tui.rd16, which
// is the very decode tui.size() performs: same answer, one syscall, zero bytes
// of heap.  A [byte] has to be growable to be passed to syscall at all -- a
// [byte; N] is not a [byte] in Y.
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

// ────────────────────────────────────────────── the one-line stderr report ───

def report(n: long, bytes: long, fps: long, h0: long, h1: long) -> void {
    eputs("raytracer: ");
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

// ───────────────────────────────────────────────────────── CLI plumbing ────

def die(msg: str) -> void {
    eputs("raytracer: ");
    eputs(msg);
    eputs("\nraytracer: try --help\n");
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

// parse_size(s) -- WxH packed as W*1000000 + H, 0 if the string is not that
// shape, or -1 if it is degenerate.  Slicing rather than a hand-rolled byte
// scan, because a string slice is the clearest thing here and it allocates
// once, at start-up.
//
// A degenerate size is REFUSED, not clamped: 0x0 has no frame to render, and
// quietly clamping it to 1x1 would answer a question nobody asked.  A size past
// the cap IS clamped, because 999x999 is a request rather than a mistake and
// the cap is a property of the sample store, not of the picture.
def parse_size(s: str) -> long {
    let at = s.index_of("x");
    if (at < 1) { return 0; };
    let a = s[0:at];
    let b = s[at + 1:];
    if (!args.num_ok(a) || !args.num_ok(b)) { return 0; };
    let w = tonum(a);
    let h = tonum(b);
    if (w < 1 || h < 1) { return 0 - 1; };
    if (w > scene.MAXC) { w = scene.MAXC; };
    if (h > scene.MAXR) { h = scene.MAXR; };
    w * 1000000 + h
};

// Frames the deterministic run prints in full.  want_dump is one bit per frame
// index and DUMPS is the same set in the order --dump listed it.
let want_dump: [long; 4096] = [0; 4096];
let NDUMP: long = 0;
let DUMPS: [long; 32] = [0; 32];

def load_dumps(s: str, last: long) -> void {
    if (s == "") {
        // the default is the last frame: the one a reader wants to see, and the
        // one a golden file should hold
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

args.init("raytracer", "a reflective raytracer, in a terminal framebuffer.", OPTS);
let st = args.parse(argv());
if (st == args.HELP) {
    puts(args.usage());
    puts("\nthe scene: four spheres and two planes.  Sphere 1 is a full mirror,\n");
    puts("sphere 2 reflects 43% and the floor 18%, so a three-bounce frame really\n");
    puts("does three bounces instead of three bounces' worth of nothing.  The\n");
    puts("floor is a two-cell checkerboard and the back wall is a vertical\n");
    puts("gradient.  Every sample of the frame is one ray: six closed-form\n");
    puts("intersections, the nearest wins, and a reflective surface recurses with\n");
    puts("the depth cap one deeper.\n");
    puts("\nall of it is integer Q16 fixed point, because Y has no float -> long and\n");
    puts("no math functions at all (ORCHESTRATOR.md 2.4): fx.y supplies the camera's\n");
    puts("four trig calls a frame, tan(fov) and one exact integer square root per\n");
    puts("sample.\n");
    puts("\npalettes:\n");
    puts("  ember     warm and dark, sweeping maroon -> orange -> gold (default)\n");
    puts("  ice       cold, high blue\n");
    puts("  spectrum  the whole wheel, in phase-offset thirds\n");
    puts("  mono      plain grey, for reading the geometry without the colour\n");
    puts("  phosphor  green, the classic terminal\n");
    puts("\nglyph modes:\n");
    puts("  ascii     ' .:-=+*#%@' by luminance, one ray a cell\n");
    puts("  blocks    tui's block ramp by luminance, 5 levels\n");
    puts("  half      tui's half-block ramp: TWO rays a cell, and the two halves'\n");
    puts("            colours ride in the foreground and the background, so the\n");
    puts("            shading is two levels a row\n");
    puts("  braille   U+2800+mask by coverage: EIGHT rays a cell\n");
    puts("\nkeys, interactive:  q or Escape quit, arrows orbit, +/- dolly,\n");
    puts("                    p cycles the palette, g cycles the glyph, b bounces\n");
    puts("\nthe property check:\n");
    puts("  --check is not a golden file.  It asserts things about the geometry\n");
    puts("  that no reference file could be regenerated to agree with, and exits\n");
    puts("  1 if any of them fails.  The centre of the scene is a real sphere, so\n");
    puts("  the closed-form quadratic is available in exact integer arithmetic for\n");
    puts("  any ray aimed anywhere: a ray from five units at a sphere of radius one\n");
    puts("  hits it at exactly four units, a ray aimed a quarter of a unit wide of\n");
    puts("  the tangent cone misses, and a tangent ray has discriminant exactly\n");
    puts("  zero.  Those are hand computations, not a second renderer.  It also\n");
    puts("  asserts that the reflection preserves |d|^2, that the depth cap is\n");
    puts("  honoured and that the first hit does not move when the cap changes,\n");
    puts("  and that the capture checksum changes when one pixel is perturbed.\n");
    exit(0)
};
if (st == args.USAGE) {
    eputs("raytracer: try --help\n");
    exit(1)
};
if (len(args.positional()) > 0) {
    die("takes no operands; got '" + args.positional()[0] + "'")
};

GM = mode_of(args.get_str("glyph", "half"), "--glyph", GLYPH);
PAL = mode_of(args.get_str("color", "ember"), "--color", PALNAMES);
FRAMES = args.get_long("frames", 0);
FPSWANT = args.get_long("fps", 20);
if (FPSWANT < 1) { FPSWANT = 1; };
if (FPSWANT > 240) { FPSWANT = 240; };
NOTTY = if (args.has("no-tty")) { 1 } else { 0 };
SHOWTIME = if (args.has("time")) { 1 } else { 0 };

// --bounces is the depth cap, and 0 is a legal value (no reflection at all:
// every reflective surface becomes its own diffuse colour).  It is refused
// outside 0..8 because past 8 the extra levels cost frames and the histogram
// has 16 slots.
BNCE = args.get_long("bounces", 3);
if (BNCE < 0 || BNCE > 8) { die("--bounces wants 0..8") };

// --fov is the horizontal HALF-angle.  It is bounded at 80 rather than 90
// because the horizon goes to infinity there and fx.tan divides by cos, so 90
// would be a runtime trap rather than a diagnostic.
FOVDEG = args.get_long("fov", 32);
if (FOVDEG < 5 || FOVDEG > 80) { die("--fov wants 5..80 degrees") };

// --seed is the only stochastic knob and it is off unless asked for: 0 means no
// jitter at all, which is what makes the documented run byte-identical.  A
// negative seed is refused rather than clamped, because -1 is a mistake and the
// message is the useful answer.
let seedv = args.get_long("seed", 0);
if (seedv < 0 || seedv > 2147483647) { die("--seed wants 0..2147483647") };
SEED = seedv;

// The opening camera, so a view can be scripted.  Degrees in, because that is
// what a reader has; Q16 radians out, because that is what the tracer takes.
// Two conversions, both of which are traps.  fx.DEG and fx.RAD are Q30 per
// UNIT, so fx.to_rad's argument is a Q30 DEGREE COUNT: to_rad(90) is to_rad of
// 90/2^30 of a degree and answers 0, not 1.5708 -- the shift by 30 is not
// optional.  And getting Q30 back to Q16 is a shift of 14, not an fx.mul: an
// fx.mul second argument is itself a Q30 value, so "multiply by 16384" would
// mean 16384/2^30 and every angle would come out a quarter of what was asked.
if (args.has("az")) {
    let av = args.get_long("az", 0);
    if (av < 0 - 360 || av > 360) { die("--az wants -360..360 degrees") };
    AZ = fx.to_rad(av << 30) >> 14;
};
if (args.has("el")) {
    let ev = args.get_long("el", 0);
    if (ev < 0 - 45 || ev > 45) { die("--el wants -45..45 degrees") };
    EL = fx.to_rad(ev << 30) >> 14;
};
if (args.has("dist")) {
    let dv = args.get_long("dist", 0);
    if (dv < 1 || dv > 16) { die("--dist wants 1..16 scene units") };
    DDIST = dv * 65536;
};

// --check runs the property check instead of the picture: the tracer against
// analytic geometry, asserted with no reference file involved.  It implies
// --no-tty, because it has to give the same answer in a window of any shape and
// on a machine with no window at all -- and it renders at its OWN fixed size,
// so --size does not change what it measures.
let CHECK = args.get_long("check", 0);
if (CHECK < 0 || CHECK > 2) { die("--check wants 0 (off), 1 or 2 (how much to sweep)") };
if (CHECK != 0) { NOTTY = 1; };

// The size, decided before anything is built: the sample grid and the surface
// have to agree, so both come from the same two numbers.
let ws = tui.size();
trows = ws.rows;
tcols = ws.cols;
let grow = 0;
let gcol = 0;
let HAVE_SIZE = args.has("size");
if (HAVE_SIZE) {
    let sz = parse_size(args.get_str("size", ""));
    if (sz == 0 - 1) { die("--size wants a positive WxH, e.g. --size 80x24") };
    if (sz == 0) { die("--size wants WxH, e.g. --size 80x24") };
    gcol = sz / 1000000;
    grow = sz % 1000000;
};
if (NOTTY != 0) {
    // There is no terminal to ask, so without --size the size is a fixed
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

scene.init();
scene.set_bounces(BNCE);
scene.set_fov(FOVDEG);
scene.palette(PAL);
scene.set_camera(AZ, EL, DDIST);
scene.grid_setup(gcol, grow, SXA[GM], SYA[GM]);
GW = scene.grid_w();
GH = scene.grid_h();
let SR: long = grow;
let SC: long = gcol;
let srf = tui.new(SR, SC);
load_dumps(args.get_str("dump", ""), FRAMES - 1);

// ═══════════════════════════════════════════════════ the property check ═══
//
// Placed before the deterministic path because it replaces it: --check answers
// a question about the geometry, not about the picture, and it prints its own
// report on stdout and exits 0 or 1.  check.y owns the whole of it -- the
// analytic expectations, every assertion, and the injection ledger -- and all
// that happens here is that it is handed a number.
if (CHECK > 0) {
    exit(check.run(CHECK))
};

// ═════════════════════════════════════════════════════ the deterministic path ═
//
// The same scene, the same tracer, the same cell pass and the same
// tui.flush_diff as the terminal path -- the ANSI stream is built and counted
// either way, which is what makes the `bytes` column in the digest evidence
// rather than a claim -- except that it goes to /dev/null and the text goes to
// stdout instead.
//
// NO PACING HERE, deliberately: this path exists to answer "how fast can this
// machine trace frames", and a sleep in the middle of it would measure
// nanosleep instead.  --fps is an interactive knob.
//
// NO HUD HERE either: a status line carrying a frame rate cannot be
// byte-identical between two runs.
if (NOTTY != 0) {
    let devnull = syscall(257, 0 - 100, "/dev/null", 1, 0, 0, 0);   // openat
    if (devnull >= 0) { tui.set_fd(devnull); };
    tui.capture_on();

    sink.out_str("raytracer: frames=");
    sink.out_num(FRAMES);
    sink.out_str(" size=");
    sink.out_num(SC);
    sink.out_str("x");
    sink.out_num(SR);
    sink.out_str(" glyph=");
    sink.out_str(GLYPH[GM]);
    sink.out_str(" color=");
    sink.out_str(PALNAMES[PAL]);
    sink.out_str(" bounces=");
    sink.out_num(BNCE);
    sink.out_str(" fov=");
    sink.out_num(FOVDEG);
    sink.out_str(" seed=");
    sink.out_num(SEED);
    sink.out_str(" rays/frame=");
    sink.out_num(GW * GH);
    sink.out_str("\ndumped frames:");
    for k in 0..NDUMP {
        sink.out_str(" ");
        sink.out_num(DUMPS[k]);
    };
    sink.out_str("\n");

    // --ansi FILE: the raw byte stream the framebuffer built, straight into a
    // file.  The headless path otherwise throws it away, and it is the one form
    // of the picture that keeps the colour -- golden/ holds the text frames, and
    // this is how you get a truecolour one out to look at.  Only the last frame
    // is written, because that is the one a reader wants; fb's capture buffer
    // is bounded at 256 KiB, so writing all of them would not fit.
    let ansifd = 0 - 1;
    let want_ansi = args.has("ansi");
    if (want_ansi) {
        // O_WRONLY|O_CREAT|O_TRUNC = 577 on x86-64
        ansifd = syscall(257, 0 - 100, args.get_str("ansi", ""), 577, 420, 0, 0);
        if (ansifd < 0) {
            die("cannot open --ansi file '" + args.get_str("ansi", "") + "'")
        };
    };

    let h0 = heap_used();
    let t0 = clock_us();
    let f = 0;
    while (f < FRAMES) {
        // The orbit advances one keypress-step a frame, so consecutive frames
        // differ and the per-frame digest is worth having.
        scene.set_camera(AZ + f * AZ_STEP, EL, DDIST);
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
        sink.out_pad((scene.hits() * 100) / (GW * GH), 3);
        sink.out_str(" bmax ");
        sink.out_pad(scene.bounce_max(), 4);
        sink.out_str(" depthhist ");
        sink.out_pad(scene.bounce_at(0), 7);
        let d = 1;
        while (d <= 5) {
            sink.out_str("/");
            sink.out_pad(scene.bounce_at(d), 7);
            d = d + 1;
        };
        sink.out_str(" sha ");
        sink.out_hex16(sink.grid_digest(srf));
        // Which objects the frame found, by count.  It is one more line and it
        // is the line that makes "the mirror is in this picture" a fact rather
        // than an assumption: the bounce histogram below is depth, and depth
        // without an object count is a bounce cap that might never have had
        // anything to reflect.
        sink.out_str("\nobjects  sky ");
        sink.out_pad(scene.obj_at(0), 6);
        let oi = 0;
        while (oi < 6) {
            sink.out_str("  ");
            sink.out_num(oi);
            sink.out_str(": ");
            sink.out_pad(scene.obj_at(oi + 1), 6);
            oi = oi + 1;
        };
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
        // tui.spill() has already pushed the last flush down its own descriptor;
        // this is fb's capture buffer, which holds the same bytes and is what the
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
        eputs("raytracer: ");
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
        eputs(" fps\nraytracer: ");
        eputs(tostring(SC));
        eputs("x");
        eputs(tostring(SR));
        eputs(" ");
        eputs(GLYPH[GM]);
        eputs(" bounces=");
        eputs(tostring(BNCE));
        eputs(" rays/frame=");
        eputs(tostring(GW * GH));
        eputs(" hits=");
        eputs(tostring(scene.hits()));
        eputs(" deepest bounce=");
        eputs(tostring(scene.bounce_max()));
        eputs("\nraytracer: heap_used before=");
        eputs(tostring(h0));
        eputs(" after=");
        eputs(tostring(h1));
        eputs(" delta=");
        eputs(tostring(h1 - h0));
        eputs("\n");
    };
    exit(0)
};

// ═════════════════════════════════════════════════════ the interactive path ═
//
// tui's pattern verbatim: raw mode, alt screen, watchdog, and ONE place that
// leaves.  Y has no atexit and no signal handler, so every exit below is a call
// to tui.restore_all_exit() -- there is no path out of this loop that does not
// go through it -- and a SIGKILL of the program is covered by the watchdog,
// which restores the saved termios itself.
if (!tui.raw_mode()) {
    eputs("raytracer: not a terminal; try --frames N --no-tty\n");
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
            scene.set_camera(AZ, EL, DDIST);
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
    // read_key_timeout(0) is an immediate poll, never a blocking read.  A
    // NON-ZERO timeout is the trap: VTIME counts deciseconds, so
    // read_key_timeout(1) is a 100 ms sleep every frame, the pacer drops every
    // frame, and the program reports ~0.6 fps with a stuck frame counter --
    // which reads as "the animation is slow" rather than as a timing bug
    // (ORCHESTRATOR.md 2.3).
    //
    // A resize is looked for on the same beat, because Y has no SIGWINCH.
    checked = checked + 1;
    if (checked >= 4 || FRAMES == 0) {
        checked = 0;
        // keys come back as bytes, so they are compared as bytes: Y has no char
        // literal (c'a' is the character form), and ord() is how a name becomes
        // the byte it means
        let k = tui.read_key_timeout(0);
        let moved = 0;
        if (k == ord("q") || k == ord("Q") || k == tui.KEY_ESC) {
            quit = true;
        } else if (k == ord("p") || k == ord("P")) {
            PAL = (PAL + 1) % 5;
            scene.palette(PAL);
        } else if (k == ord("g") || k == ord("G")) {
            GM = (GM + 1) % 4;
            SXA[GM] = 1;
            SYA[GM] = 1;
            if (GM == GMODE_HALF) { SYA[GM] = 2; };
            if (GM == GMODE_BRAILLE) { SXA[GM] = 2; SYA[GM] = 4; };
            scene.grid_setup(SC, SR, SXA[GM], SYA[GM]);
            GW = scene.grid_w();
            GH = scene.grid_h();
            moved = 1;
        } else if (k == ord("b") || k == ord("B")) {
            BNCE = (BNCE + 1) % 9;
            scene.set_bounces(BNCE);
        } else if (k == ord(" ")) {
            if (paused != 0) { paused = 0; } else { paused = 1; };
        } else if (k == ord("r")) {
            AZ = AZ0; EL = EL0; DDIST = D0;
            moved = 1;
        } else if (k == ord("+") || k == ord("=")) {
            if (DDIST < D_MAX) { DDIST = DDIST + D_STEP; };
            moved = 1;
        } else if (k == ord("-") || k == ord("_")) {
            if (DDIST > D_MIN) { DDIST = DDIST - D_STEP; };
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
            if (DDIST > D_MAX) { DDIST = D_MAX; };
            if (DDIST < D_MIN) { DDIST = D_MIN; };
            scene.set_camera(AZ, EL, DDIST);
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
            scene.grid_setup(SC, SR, SXA[GM], SYA[GM]);
            GW = scene.grid_w();
            GH = scene.grid_h();
        };
    }
};

report(frame, bytes_sum, tui.fps_x100(meter) / 100, ih0, heap_used());
tui.restore_all_exit(0);