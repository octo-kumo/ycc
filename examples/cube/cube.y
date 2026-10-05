// cube.y -- a rotating cube in your terminal: wireframe or shaded solid,
// perspective projected, 30 fps.
//
// Build:  ycc -o cube cube.y
// Run:    ./cube                      interactive, alt screen, q quits
//         ./cube --frames 60 --no-tty a plain-text capture on stdout
//
// WHAT IS HERE
// 8 vertices, 12 edges, 6 faces, all as constant tables near the top.  Two
// angles (yaw, pitch) are a pure function of the frame index, so a frame is
// reproducible from its number alone and the whole animation is a pure
// function of `--frames`.
//
// Every number in this file is a `long`.  Y has no `float` -> `long` and no
// cast syntax at all (ORCHESTRATOR.md §2.4a), so the geometry is integer from
// end to end and the trigonometry is Q30 fixed point from fx.y: `1.0` is
// `fx.ONE` = 1073741824, and an ANGLE is a Q30 value in radians, which means
// fx.sin/fx.cos want `fx.to_rad(fx.from_int(degrees))` and NOT
// fx.to_rad(degrees) -- the latter multiplies a *whole* 6 by 18740330 and then
// shifts right by 30, and comes back as 0.  That is the single sharpest edge
// in this program and it is silent.
//
// THE DIVIDE GUARD.  A perspective projection divides by the distance from
// the eye, and there is no camera that can never be inside the cube, so every
// divide in this file is either by a constant or by a depth that has been
// clamped first.  See `project()` and `z_depth()`; the two comments there are
// the whole story.
//
// NOTHING IS ALLOCATED IN THE FRAME LOOP.  Y's heap is an arena and nothing is
// ever freed (§2.7), so every per-frame buffer here is a fixed-size top-level
// array and the only heap the program owns is the one fb.Surface from
// fb.new() (1.5 MiB, once).  `--stats` prints heap_used() before and after the
// loop so this is checkable rather than claimed.

import fx;
import fb;
import term;
import time;
import args;

// ════════════════════════════════════════════════════════════════════ scene ══
//
// Q30 literals.  There is no float -> long, so a constant that would be a
// decimal in C is written out in full here and named.
const ONE: long = 1073741824;      // 1.0
const CAM_DIST: long = 6442450944; // 6.0 -- the eye sits on +z, looking -z

// MIN_DEPTH is the perspective divide's floor, and it is the reason this
// program cannot trap.  See z_depth().
const MIN_DEPTH: long = 1073741824; // 1.0

// The 8 corners of [-1,1]^3.  Vertex i: bit0 is x, bit1 is y, bit2 is z, and
// a set bit means +1.  So 0 is (-1,-1,-1) and 7 is (1,1,1).
const VTX: [long; 24] = [
    -1073741824, -1073741824, -1073741824,
    1073741824, -1073741824, -1073741824,
    -1073741824, 1073741824, -1073741824,
    1073741824, 1073741824, -1073741824,
    -1073741824, -1073741824, 1073741824,
    1073741824, -1073741824, 1073741824,
    -1073741824, 1073741824, 1073741824,
    1073741824, 1073741824, 1073741824
];

// The 6 faces as 4 vertex indices in cyclic order, so the projected quad is
// convex in screen space and can be filled by scanline.
//
// The order is the wireframe's hidden-line rule: face 2*axis is the +axis
// face and 2*axis+1 is the -axis face.  An edge only ever varies in one
// coordinate, so the two faces that contain it are exactly the two faces of
// its own axis -- which is why the edge table is ordered by axis and why an
// edge can be dimmed with one division.
const FACES: [long; 24] = [
    1, 3, 7, 5,        // 0: +x
    0, 2, 6, 4,        // 1: -x
    2, 3, 7, 6,        // 2: +y
    0, 1, 5, 4,        // 3: -y
    4, 5, 7, 6,        // 4: +z
    0, 1, 3, 2         // 5: -z
];

// The face normals before rotation: the unit vector along each face's axis,
// in the same face order as FACES.
const FNOR: [long; 18] = [
    1073741824, 0, 0,
    -1073741824, 0, 0,
    0, 1073741824, 0,
    0, -1073741824, 0,
    0, 0, 1073741824,
    0, 0, -1073741824
];

// The 12 edges as (u, v) pairs, ordered by axis, four per axis: edge e
// belongs to axis e / 4 and its two adjacent faces are 2*(e/4) and
// 2*(e/4)+1.
const EDGE: [long; 24] = [
    0, 1,  2, 3,  4, 5,  6, 7,     // axis 0 (x)
    0, 2,  1, 3,  4, 6,  5, 7,     // axis 1 (y)
    0, 4,  1, 5,  2, 6,  3, 7      // axis 2 (z)
];

// Light direction in VIEW space, so it stays put while the cube turns under
// it and the faces brighten and darken as they come round.  It is the unit
// vector (-5, 7, 11) / sqrt(195), written out in Q30; the squared length of
// these three numbers is ONE to within one step.
const L_X: long = -384461246;
const L_Y: long = 538245744;
const L_Z: long = 845814740;

// The floor plane, in world units: a grid just under the cube's bottom face.
// It runs well behind the cube so the converging lines give the eye a horizon;
// with the eye at y = 0 and the grid at y = -1.05, a point at depth d lands on
// screen row (ROWS/2 - 1) + 1.05 * FPV / d, so the far rungs crowd towards
// the vanishing line exactly as they should.
const FLOOR_Y: long = -1127428915;  // -1.05
const FLOOR_X: long = 4;            // rails and rungs span x in [-4, 4]
const FLOOR_Z0: long = 0 - 14;      // rungs at every whole z from here
const FLOOR_Z1: long = 2;

// The animation.  Both steps are whole degrees per frame and both are taken
// mod 360 so the angle is a bounded `long` however many frames are asked for:
// `--frames 1000000` is a million distinct frames and the angle never leaves
// [0, 2pi).
const STEP_YAW: long = 6;           // one full turn every 60 frames
const STEP_PITCH: long = 3;         // one full nod every 120 frames

// Shading.  AMBIENT_PCT is the darkest a front face is allowed to get, so a
// face turned away from the light is still a face and not a hole; AMBIENT_V is
// the same floor in the 0..255 the ramps want.
const AMBIENT_PCT: long = 14;
const AMBIENT_V: long = 32;

// Ink levels, 0..255.
const INK_HI: long = 255;
const INK_LO: long = 96;
const INK_FLOOR: long = 44;

// The colour modes, and the phosphor tints they peak at.
const C_MONO: long = 0;
const C_GRAY: long = 1;
const C_GREEN: long = 2;
const C_AMBER: long = 3;
const C_ICE: long = 4;
const RGB_GREEN: long = 1083578432;  // rgb(120, 255, 130)
const RGB_AMBER: long = 4279176192;  // rgb(255, 176,  64)
const RGB_ICE: long = 3665886464;    // rgb(150, 220, 255)

// Glyphs.  The terminal path uses box drawing, which needs a font with
// U+2500; the plain-text capture and the `mono` mode use ASCII so EXPECTED is a
// text file and a machine without the font still shows a cube.
const G_H: long = 9472;      // U+2500 box drawings light horizontal
const G_V: long = 9474;      // U+2502 box drawings light vertical
const G_C: long = 9532;      // U+2534 box drawings light up and horizontal
const G_DOT: long = 183;     // U+00B7 middle dot, the floor grid at its faintest
const G_FLOOR_ASC: long = c'.';

// Keys.  A Y character literal is `c'q'`, never a bare `'q'` -- and it is a
// `byte`, so every one of these carries an explicit `long` annotation, which is
// the only bridge from a character to a whole number.
const K_Q: long = c'q';       // quit
const K_S: long = c's';       // toggle solid / wireframe
const K_C: long = c'c';       // next colour mode
const K_CTRL_C: long = c'\x03';  // arrives as a byte, since raw mode cleared ISIG

// ════════════════════════════════════════════════════════════════ options ══

const OPT: [args.Opt] = [
    { long: "frames",    short: "n", kind: args.NUM,
      help: "render exactly N frames, then exit 0 (default 0 = run until a key)" },
    { long: "solid",     short: "",  kind: args.BOOL,
      help: "fill the three front faces with shading; the default is wireframe" },
    { long: "wireframe", short: "w", kind: args.BOOL,
      help: "draw the 12 edges only, hidden ones dimmed (this is the default)" },
    { long: "color",     short: "c", kind: args.STR,
      help: "mono | gray | green | amber | ice (default mono)" },
    { long: "size",      short: "",  kind: args.STR,
      help: "WxH cells; default the window, or 24x60 with --no-tty (max 128x256)" },
    { long: "floor",     short: "",  kind: args.BOOL,
      help: "also draw a perspective floor grid; OFF by default, so --wireframe is only the 12 edges" },
    { long: "selftest",  short: "",  kind: args.NUM,
      help: "run the internal correctness checks over N frames, then exit; 0 or absent = off (try 60)" },
    { long: "fps",       short: "f", kind: args.NUM,
      help: "frames per second, 0 for as fast as possible (default 30, or 0 with --no-tty)" },
    { long: "no-tty",    short: "",  kind: args.BOOL,
      help: "write plain text to stdout instead of drawing to the terminal" },
    { long: "stats",     short: "",  kind: args.BOOL,
      help: "print timings, the measured rate and the heap delta to stderr" }
];

// ══════════════════════════════════════════════════════════════════ state ══
//
// Every one of these is a fixed-size top-level array or a scalar.  Nothing in
// this list is created, grown or replaced once `main` starts drawing.
let ROWS = 24;
let COLS = 60;
let SURF: fb.Surface = fb.new(24, 60);   // the only heap the program owns

let FOCAL_PX = 96;   // pixels per world unit at unit depth, on x
let FPV = 48;        // half of that on y: a terminal cell is about twice as
                     // tall as it is wide, so an equal world step must be half
                     // as many cells up
let SOLID = false;
let FLOOR_ON = false;
let OUTLINE = true;
let CMODE: long = C_MONO;
let NOTTY = false;

let PX: [long; 8] = [0; 8];      // view space, Q30
let PY: [long; 8] = [0; 8];
let PZ: [long; 8] = [0; 8];
let SX: [long; 8] = [0; 8];      // screen cells
let SY: [long; 8] = [0; 8];
let NZ: [long; 6] = [0; 6];      // face normal z in view space, Q30
let FRONT: [long; 6] = [0; 6];   // 1 when the face looks at the camera
let FORD: [long; 6] = [0; 6];    // front faces, farthest first
let NFRONT = 0;
let YAW: long = 0;
let PIT: long = 0;

// The cube's screen bounding box, recomputed every frame.  It is what stops
// the floor grid from drawing through the cube: this program has no z-buffer,
// so a cell inside the box belongs to the cube and the grid is not written
// there.  A bounding box is not the silhouette, so it over-occludes a little
// at the corners -- invisible in motion, and a z-buffer would be a much worse
// trade than four extra comparisons.
let BX0: long = 0;
let BX1: long = 0;
let BY0: long = 0;
let BY1: long = 0;

// Microseconds spent inside the frame body, so --stats can separate the cost
// of a frame from the time the pacer spends asleep.  One scalar, never grown.
let DRAW_US = 0;

// TIOCGWINSZ's out-parameter buffer, ours, so that the once-a-frame resize
// poll allocates NOTHING: term.size() builds a fresh WinSize record on every
// call, and at 30 fps that is 40 bytes a frame in a program whose whole claim
// is that the frame loop allocates nothing (ORCHESTRATOR.md §2.7).  Same
// ioctl, same descriptor, same layout -- four 16-bit little-endian values,
// ROW first (ORCHESTRATOR.md §2.3) -- and syscall arguments are in KERNEL
// REGISTER order, so ioctl(fd, request, arg) is syscall(16, fd, REQUEST, arg).
let WSZ: [byte; 64] = [0; 64];

// poll_size() -- adopt the window's geometry if it has changed.  A zero or
// failed answer leaves the current one alone: a pty nobody sized reports 0x0,
// and re-fitting to 1x1 on that would blank the picture for no reason.
def poll_size() {
    let r = 0;
    let c = 0;
    if (syscall(16, 1, term.TIOCGWINSZ, &WSZ[0]) >= 0) {
        r = WSZ[0] + WSZ[1] * 256;
        c = WSZ[2] + WSZ[3] * 256
    };
    if (r > 0 && c > 0 && (r != ROWS || c != COLS)) { fit(r, c) }
};

// A 4 KiB byte buffer for the plain-text path, so writing a row is one
// write(2) and costs no allocation.  `putc`/`putn`/`puts_bytes` are the only
// three writers and none of them grows it.
let OB: [byte; 4096] = [0; 4096];
let ON = 0;

// ═══════════════════════════════════════════════════════════════════ utils ══

def clampi(v: long, lo: long, hi: long) -> long {
    if (v < lo) { return lo; };
    if (v > hi) { return hi; };
    v
};

def iabs(v: long) -> long {
    if (v < 0) { return 0 - v; };
    v
};

def putc(b: long) {
    if (ON < 4096) { OB[ON] = b; ON = ON + 1; }
};

// putn(v) -- v in decimal, no leading zeros, "-" for a negative.
//
// The obvious one-digit-at-a-time version is WRONG, and it was wrong here:
// each step tests the REDUCED value (`if (q >= 10)`) rather than the digit
// count, so a number whose tens digit is 0 loses that place entirely -- 900
// came out as "90", 1005 as "105", and the frame header printed
// `yaw 090` where it meant `yaw 0900`.  So: count the digits first, then emit
// exactly that many, dividing by a scale that walks 10000, 1000, ... 1.
// A golden file full of those headers passed every determinism check in the
// gate for exactly as long as nobody read them.
def putn(v: long) {
    let q = v;
    if (q < 0) { putc(45); q = 0 - q; };
    let n = 1;
    let t = q;
    while (t >= 10) { t = t / 10; n = n + 1; };
    let scale = 1;
    let i = 1;
    while (i < n) { scale = scale * 10; i = i + 1; };
    while (scale > 0) {
        putc(48 + (q / scale) % 10);
        scale = scale / 10
    }
};

// put4(v) -- v zero-padded to at least four digits, so a reader can tell 90
// from 900.  Angles are printed in tenths of a degree and reach 3600.
def put4(v: long) {
    if (v < 10) { putc(48); putc(48); putc(48); }
    else if (v < 100) { putc(48); putc(48); }
    else if (v < 1000) { putc(48); };
    putn(v)
};

def putbytes(t: str) {
    let i = 0;
    while (i < len(t)) {
        putc(byte_at(t, i));
        i = i + 1
    }
};

def flush_ob() {
    if (ON > 0) { syscall(1, 1, &OB[0], ON); ON = 0; }
};

// ══════════════════════════════════════════════════════════════════ colour ══

def peak(m: long) -> long {
    if (m == C_GREEN) { return RGB_GREEN; };
    if (m == C_AMBER) { return RGB_AMBER; };
    if (m == C_ICE) { return RGB_ICE; };
    fb.grey(255)
};

// The phosphor tint at brightness v (0..255).  `mono` has no colour at all and
// says so with fb.DEFAULT, which emits SGR 39 and lets the terminal's own
// palette through.
def tint(v: long) -> long {
    if (CMODE == C_MONO) { return fb.DEFAULT; };
    let p = peak(CMODE);
    if (CMODE == C_GRAY) { return fb.grey(v); };
    fb.rgb(fb.r_of(p) * v / 255, fb.g_of(p) * v / 255, fb.b_of(p) * v / 255)
};

// The page behind everything.
def back() -> long {
    if (CMODE == C_MONO) { return fb.DEFAULT; };
    fb.rgb(10, 10, 16)
};

// A lit colour and the shadow under the same face.  The glyph carries the
// coverage and these two carry the tone, which is what makes a flat-shaded
// face read as a curved one as it turns.
def lit(v: long) -> long { tint(v) };

def shade_of(v: long) -> long { tint(v * 42 / 100) };

// A luminance in [-1,1] Q30 becomes 0..255, with the ambient floor applied so
// nothing ever goes to the emptiest glyph.
def lum_to_v(q: long) -> long {
    let lo = AMBIENT_PCT * ONE / 100;
    let c = fx.clamp(q, lo, ONE);
    AMBIENT_V + fx.to_int(fx.mul(c, fx.from_int(255 - AMBIENT_V)))
};

// ═════════════════════════════════════════════════════════════ projection ══

// z_depth(z) -> the distance from the eye to a point whose view-space z is z.
//
// THE DIVIDE GUARD.  Everything downstream of here divides by the answer, and
// division by zero is a runtime trap that prints on STDOUT (ORCHESTRATOR.md
// §2.6) -- in the middle of a frame, into a diff.  The camera is 6 units out on
// +z, and the closest anything in this scene ever comes to it is the floor's
// near rail at z = 2, which is a depth of 4.0; so the clamp below never fires
// and the divisor is never less than 4.0.  It is here so that no future
// geometry, no resize and no adversarial --size can reach the divide: the
// divisor is at least MIN_DEPTH, which is 1.0 and therefore never 0.
def z_depth(z: long) -> long {
    let d = CAM_DIST - z;
    if (d < MIN_DEPTH) { d = MIN_DEPTH; };
    d
};

// project(i) -> put vertex i's screen cell into SX[i], SY[i].
//
// The projection is written so the focal length is a plain PIXEL count and not
// a Q30 angle, which keeps every intermediate inside a long:
//     offset_cells = (coord_Q30 * focal_px) / depth_Q30
// The Q30 factors cancel, so the quotient is already the whole number of
// cells.  That matters because the alternative -- a Q30 focal length, which is
// what fx.mul wants -- would form a product near 2^65 and saturate.
def project(i: long) {
    let d = z_depth(PZ[i]);
    SX[i] = COLS / 2 + (PX[i] * FOCAL_PX) / d;
    // The eye is a little above the middle of the frame, so the floor has
    // somewhere to go.  A negative row is not a special case: fb.put ignores
    // an out-of-range cell, so it clips.
    SY[i] = ROWS / 2 - 1 - (PY[i] * FPV) / d
};

// bbox() -- the cube's screen extent this frame, for the floor's occlusion.
def bbox() {
    BX0 = SX[0];
    BX1 = SX[0];
    BY0 = SY[0];
    BY1 = SY[0];
    for i in 1..8 {
        if (SX[i] < BX0) { BX0 = SX[i]; };
        if (SX[i] > BX1) { BX1 = SX[i]; };
        if (SY[i] < BY0) { BY0 = SY[i]; };
        if (SY[i] > BY1) { BY1 = SY[i]; }
    }
}

// ══════════════════════════════════════════════════════════════════ lines ══

// seg(u, v, gh, gv, fg, bg) -- one cube edge.
//
// A projected cube edge is axis-aligned most of the time, and then one
// fb.hline or fb.vline draws it exactly, which is what those two primitives
// are for.  When it is NOT axis-aligned it has to be walked: the previous
// revision picked the dominant axis and drew a full run along it, which for
// an edge with |dx| ~= |dy| draws a straight line that the edge does not
// follow -- the picture filled up with floating runs that joined nothing, and
// it did so deterministically, so the golden file blessed it.  A staircase
// along the segment is the segment.
//
// Both ends then get the corner glyph, because a staircase stops short of
// the far end's cell when the slope is shallow.
def seg(u: long, v: long, gh: long, gv: long, fg: long, bg: long) {
    let x0 = SX[u];
    let y0 = SY[u];
    let x1 = SX[v];
    let y1 = SY[v];
    let dx = x1 - x0;
    let dy = y1 - y0;
    if (dy == 0) {
        let a = x0;
        let b = x1;
        if (a > b) { let t = a; a = b; b = t; };
        fb.hline(SURF, y0, a, b - a + 1, gh, fg, bg)
    } else if (dx == 0) {
        let a = y0;
        let b = y1;
        if (a > b) { let t = a; a = b; b = t; };
        fb.vline(SURF, a, x0, b - a + 1, gv, fg, bg)
    } else {
        // The diagonal case.  `steps` is the divisor and is guarded by
        // `if (steps > 0)`, which also makes a degenerate point draw once.
        let steps = iabs(dx);
        if (iabs(dy) > steps) { steps = iabs(dy); };
        let i = 0;
        while (i <= steps) {
            let x = x0;
            let y = y0;
            if (steps > 0) {
                x = x0 + dx * i / steps;
                y = y0 + dy * i / steps
            };
            fb.put(SURF, y, x, if iabs(dx) >= iabs(dy) { gh } else { gv }, fg, bg);
            i = i + 1
        }
    };
    let gc = edge_c_glyph();
    fb.put(SURF, y0, x0, gc, fg, bg);
    fb.put(SURF, y1, x1, gc, fg, bg)
};

// fput(y, x, cp, fg, bg) -- one floor cell, unless the cube owns it.
//
// The cube stands ON this grid, so the grid must not show through it, and
// there is no z-buffer here to ask.  The cube's screen bounding box is the
// cheap answer: everything inside it belongs to the cube.  Over-occludes the
// four corners of the box that are not really cube, which is not visible in
// motion.
def fput(y: long, x: long, cp: long, fg: long, bg: long) {
    let mine = y >= BY0 && y <= BY1 && x >= BX0 && x <= BX1;
    if (!mine) { fb.put(SURF, y, x, cp, fg, bg) }
};

// dline(x0, y0, x1, y1, cp, fg, bg) -- the floor's grid, which is diagonal in
// screen space and so needs a DDA rather than a run.  `steps` is the larger of
// the two spans and is the divisor in both places; the guard is that the loop
// only divides when steps > 0, which also makes a degenerate point draw once.
def dline(x0: long, y0: long, x1: long, y1: long, cp: long, fg: long, bg: long) {
    let dx = x1 - x0;
    let dy = y1 - y0;
    let steps = iabs(dx);
    if (iabs(dy) > steps) { steps = iabs(dy); };
    let i = 0;
    while (i <= steps) {
        let x = x0;
        let y = y0;
        if (steps > 0) {
            x = x0 + (dx * i) / steps;
            y = y0 + (dy * i) / steps;
        };
        fput(y, x, cp, fg, bg);
        i = i + 1
    }
};

// ── the floor ──
//
// WHY IT IS OFF BY DEFAULT.  The floor is a second subject, and a wireframe
// renders ONE thing: the 12 projected edges.  An earlier revision drew this
// unconditionally and the result was a stippled triangular wedge at the
// lower left and right of nearly every frame -- the rungs are one world unit
// apart, which is under a cell near the camera, so they merged into a solid
// fill between the cube's screen bounding box and the edge of the screen.
// Every determinism check passed, because the defect *was* deterministic.
// It is now `--floor`, off unless asked for.
//
// WHY IT IS DECIMATED AS WELL.  Turning it on is only honest if the grid
// still reads as a grid: a rung whose screen row is within FLOOR_GAP rows of
// the rung before it is dropped, and the same for the rails by column, so
// near the camera the grid thins instead of saturating.  This is the same
// idea as a mip level and it is four lines.
const FLOOR_GAP: long = 2;

def draw_floor() {
    let cp = if NOTTY { G_FLOOR_ASC } else { G_DOT };
    let fg = tint(INK_FLOOR);
    let bg = back();
    // Rungs: one line per whole z, thinned to FLOOR_GAP rows apart.
    let z = FLOOR_Z0;
    let lasty = 0 - 1000;
    while (z <= FLOOR_Z1) {
        let y = floor_y(z);
        if (iabs(y - lasty) >= FLOOR_GAP) {
            dline(floor_x(0 - FLOOR_X, z), y, floor_x(FLOOR_X, z), y, cp, fg, bg);
            lasty = y
        };
        z = z + 1
    };
    // Rails: one line per whole x, thinned to FLOOR_GAP columns apart.  Their
    // rows are not constant -- they run away towards the horizon -- so the
    // test is on the column they start at.
    let x = 0 - FLOOR_X;
    let lastx = 0 - 1000;
    while (x <= FLOOR_X) {
        let sx = floor_x(x, FLOOR_Z0);
        if (iabs(sx - lastx) >= FLOOR_GAP) {
            dline(sx, floor_y(FLOOR_Z0), floor_x(x, FLOOR_Z1), floor_y(FLOOR_Z1), cp, fg, bg);
            lastx = sx
        };
        x = x + 1
    }
};

// The same projection as project(), for a point on the floor plane.  The divide
// is guarded by z_depth() exactly as it is for the cube's vertices.
def floor_x(x: long, z: long) -> long {
    COLS / 2 + (fx.from_int(x) * FOCAL_PX) / z_depth(fx.from_int(z))
};

def floor_y(z: long) -> long {
    ROWS / 2 - 1 - (FLOOR_Y * FPV) / z_depth(fx.from_int(z))
};

// ═══════════════════════════════════════════════════════════════════ faces ══

// fill_face(f) -- scanline the projected quad of face f at brightness v.
//
// Painter's algorithm: FORD holds the visible faces farthest first, and for a
// convex solid the front faces never overlap except near a silhouette, where
// the centre-depth order is right anyway.  No z-buffer, no allocation.
//
// The loop has no `break` and no `continue` (§2.9), so the edge scan keeps a
// `got` flag instead of skipping.
def fill_face(f: long, v: long) {
    let g = face_glyph(v);
    let fg = lit(v);
    let bg = shade_of(v);
    let r = SY[FACES[f * 4]];
    if (SY[FACES[f * 4 + 1]] < r) { r = SY[FACES[f * 4 + 1]]; };
    if (SY[FACES[f * 4 + 2]] < r) { r = SY[FACES[f * 4 + 2]]; };
    if (SY[FACES[f * 4 + 3]] < r) { r = SY[FACES[f * 4 + 3]]; };
    let ymax = SY[FACES[f * 4]];
    if (SY[FACES[f * 4 + 1]] > ymax) { ymax = SY[FACES[f * 4 + 1]]; };
    if (SY[FACES[f * 4 + 2]] > ymax) { ymax = SY[FACES[f * 4 + 2]]; };
    if (SY[FACES[f * 4 + 3]] > ymax) { ymax = SY[FACES[f * 4 + 3]]; };
    let y = r;
    while (y <= ymax) {
        let lo = 0;
        let hi = 0;
        let got = false;
        let k = 0;
        while (k < 4) {
            let ia = FACES[f * 4 + k];
            let ib = FACES[f * 4 + (k + 1) % 4];
            let ya = SY[ia];
            let yb = SY[ib];
            // A horizontal edge covers no scanline, and skipping it is also
            // what keeps the divisor below non-zero.
            if (ya != yb) {
                let ylo = ya;
                let yhi = yb;
                if (ylo > yhi) { let t = ylo; ylo = yhi; yhi = t; };
                if (y >= ylo && y <= yhi) {
                    let x = SX[ia] + (SX[ib] - SX[ia]) * (y - ya) / (yb - ya);
                    if (!got) {
                        lo = x;
                        hi = x;
                        got = true;
                    } else {
                        if (x < lo) { lo = x; };
                        if (x > hi) { hi = x; };
                    };
                };
            };
            k = k + 1
        };
        if (got && hi >= lo) {
            fb.hline(SURF, y, lo, hi - lo + 1, g, fg, bg)
        };
        y = y + 1
    }
};

// face_glyph(v) -> the cell that carries a face's coverage.  The terminal path
// uses the block ramp, which is true coverage and survives a light terminal;
// the capture uses the ASCII ramp, so EXPECTED is a text file.
def face_glyph(v: long) -> long {
    if (NOTTY) { return fb.shade_ascii(v, 255); };
    fb.shade_blocks(v, 255)
};

// ══════════════════════════════════════════════════════════════ transform ══

// draw_frame(fno) -- one whole frame, from the frame number to the cells.
//
// The yaw-then-pitch rotation is applied to the 8 vertices and to the 6 face
// normals with the same four Q30 products, so a face's normal is always the
// exact rotation of its vertices' plane.  fx.mul forms each product in limbs
// and saturates rather than wrapping, so nothing here can overflow.
def draw_frame(fno: long) {
    // The angles are a pure function of the frame number, so any frame of any
    // run can be reproduced on its own -- which is what makes EXPECTED a
    // function of --frames alone.
    YAW = fx.to_rad(fx.from_int((fno * STEP_YAW) % 360));
    PIT = fx.to_rad(fx.from_int((fno * STEP_PITCH) % 360));
    let cy = fx.cos(YAW);
    let sy = fx.sin(YAW);
    let cp = fx.cos(PIT);
    let sp = fx.sin(PIT);

    for i in 0..8 {
        let vx = VTX[i * 3];
        let vy = VTX[i * 3 + 1];
        let vz = VTX[i * 3 + 2];
        let x1 = fx.mul(vx, cy) + fx.mul(vz, sy);
        let z1 = fx.mul(vz, cy) - fx.mul(vx, sy);
        PX[i] = x1;
        PY[i] = fx.mul(vy, cp) - fx.mul(z1, sp);
        PZ[i] = fx.mul(vy, sp) + fx.mul(z1, cp);
        project(i)
    };
    bbox();

    // BACK-FACE CULLING.  A face's normal is rotated exactly as its vertices
    // were, and because the cube is centred on the origin a face is visible
    // exactly when its rotated normal points back at the eye -- which reduces
    // to nz > 0 in view space, with no dot product and no per-face test
    // against the camera position.  Three of the six survive for a generic
    // angle.
    NFRONT = 0;
    for f in 0..6 {
        let nx = FNOR[f * 3];
        let ny = FNOR[f * 3 + 1];
        let nz0 = FNOR[f * 3 + 2];
        // Only the rotated z is needed here; the shading loop rotates the x
        // and y again for the Lambert term.
        let z1 = fx.mul(nz0, cy) - fx.mul(nx, sy);
        NZ[f] = fx.mul(ny, sp) + fx.mul(z1, cp);
        FRONT[f] = if NZ[f] > 0 { 1 } else { 0 };
        if (FRONT[f] == 1) {
            // Insertion sort by nz, ascending, so the farthest visible face
            // is filled first.  No break: the shift condition is the loop.
            let j = NFRONT;
            let go = true;
            while (go && j > 0) {
                if (NZ[FORD[j - 1]] > NZ[f]) {
                    FORD[j] = FORD[j - 1];
                    j = j - 1;
                } else {
                    go = false;
                };
            };
            FORD[j] = f;
            NFRONT = NFRONT + 1
        }
    };

    fb.clear(SURF, back());
    // The floor is a separate subject and only appears when asked for, so a
    // `--wireframe` frame contains the 12 projected edges and nothing else.
    // See draw_floor() for what went wrong when it did not.
    if (FLOOR_ON) { draw_floor() };

    if (SOLID) {
        for k in 0..NFRONT {
            let f = FORD[k];
            // Lambert: the normal dotted with the light, in Q30 throughout.
            let nx = fx.mul(FNOR[f * 3], cy) + fx.mul(FNOR[f * 3 + 2], sy);
            let ny0 = FNOR[f * 3 + 1];
            let z1 = fx.mul(FNOR[f * 3 + 2], cy) - fx.mul(FNOR[f * 3], sy);
            let ny = fx.mul(ny0, cp) - fx.mul(z1, sp);
            fill_face(f, lum_to_v(fx.mul(nx, L_X) + fx.mul(ny, L_Y) + fx.mul(NZ[f], L_Z)))
        };
        // The outline last, so it sits on top of every fill.  OUTLINE exists
        // for the self-test, which has to tell a fill cell from an edge cell.
        if (OUTLINE) {
            let ih = tint(INK_HI);
            for k in 0..NFRONT {
                let f = FORD[k];
                for m in 0..4 {
                    seg(FACES[f * 4 + m], FACES[f * 4 + (m + 1) % 4],
                        edge_h_glyph(), edge_v_glyph(), ih, back())
                }
            }
        }
    } else {
        for e in 0..12 {
            // HIDDEN-LINE REMOVAL.  An edge is on a visible face when at least
            // one of its two adjacent faces survived the cull, and those two
            // are 2*(e/4) and 2*(e/4)+1 by the table's construction.
            let ax = e / 4;
            let front = FRONT[ax * 2] == 1 || FRONT[ax * 2 + 1] == 1;
            let fg = if front { tint(INK_HI) } else { tint(INK_LO) };
            seg(EDGE[e * 2], EDGE[e * 2 + 1], edge_h_glyph(), edge_v_glyph(), fg, back())
        }
    }
};

// The three glyphs an edge can be drawn with, picked once per call site by
// whether there is a font: ASCII for `mono` and for the plain-text capture,
// box drawing otherwise.
def edge_h_glyph() -> long { if (CMODE == C_MONO || NOTTY) { return c'-'; }; G_H };
def edge_v_glyph() -> long { if (CMODE == C_MONO || NOTTY) { return c'|'; }; G_V };
def edge_c_glyph() -> long { if (CMODE == C_MONO || NOTTY) { return c'+'; }; G_C };

// ═════════════════════════════════════════════════════════════════ self test ══
//
// WHY THIS EXISTS.  A golden file proves the output is DETERMINISTIC.  It
// cannot prove the output is CORRECT: a bug that is deterministic passes the
// determinism check forever.  This example shipped a wireframe with a stippled
// filled wedge in it -- the floor grid, drawn unconditionally -- and every
// gate item passed, because the defect was just as reproducible as the
// picture.  So the two properties that were actually wrong are now checked
// mechanically, against oracles computed a DIFFERENT way from the drawing
// code, and the check ships with the program.
//
//   T1  WIREFRAME FILLS NOTHING.  Every non-blank cell of a `--wireframe`
//       frame lies on one of the 12 projected edges.  The oracle walks each
//       edge with an integer DDA -- not seg()'s dominant-axis run -- and
//       accepts a cell within one cell of the staircase, which is more
//       generous than seg() is, so this can only fail if something was drawn
//       AWAY from every edge.  That is the defect, exactly.
//
//   T2  THE SOLID FILL IS THE QUAD, NOT ITS BOUNDING BOX.  Every non-blank
//       cell of a `--solid` frame (drawn with the outline off, so fill and
//       edge cannot be confused) lies inside the projected quadrilateral of
//       some front face.  The oracle is a point-in-convex-polygon test on
//       four cross products -- nothing like fill_face()'s scanline spans --
//       so a fill that walked the wrong span, or walked the bounding box,
//       puts cells outside the quad and fails here.
//
// Both report the worst frame and the worst cell.  Exit 0 if every frame
// passes, 1 otherwise.  This is the check worth more than another golden file.

// on_edge(r, c) -> is (r,c) within one cell of some projected cube edge?
// `steps` is the divisor below and is guarded by `if (steps > 0)`, the same
// guard dline() uses; the whole reason the check can afford a per-cell DDA
// walk over all 12 edges is that 12 is small.
def on_edge(r: long, c: long) -> bool {
    let hit = false;
    for e in 0..12 {
        if (!hit) {
            let a = EDGE[e * 2];
            let b = EDGE[e * 2 + 1];
            let x0 = SX[a];
            let y0 = SY[a];
            let x1 = SX[b];
            let y1 = SY[b];
            let steps = iabs(x1 - x0);
            if (iabs(y1 - y0) > steps) { steps = iabs(y1 - y0); };
            let i = 0;
            while (i <= steps && !hit) {
                let px = x0;
                let py = y0;
                if (steps > 0) {
                    px = x0 + (x1 - x0) * i / steps;
                    py = y0 + (y1 - y0) * i / steps
                };
                if (iabs(px - c) <= 1 && iabs(py - r) <= 1) { hit = true; };
                i = i + 1
            }
        }
    };
    hit
};

// in_quad(f, r, c) -> is (r,c) inside the projected quad of face f?
// Four cross products of (edge) x (point - vertex), which for a convex quad
// in cyclic order all share a sign; winding-agnostic, so `n == 0 || n == 4`.
def in_quad(f: long, r: long, c: long) -> bool {
    let pos = 0;
    let neg = 0;
    for k in 0..4 {
        let ia = FACES[f * 4 + k];
        let ib = FACES[f * 4 + (k + 1) % 4];
        let ex = SX[ib] - SX[ia];
        let ey = SY[ib] - SY[ia];
        let cr = ex * (r - SY[ia]) - ey * (c - SX[ia]);
        if (cr > 0) { pos = pos + 1 } else { if (cr < 0) { neg = neg + 1 } };
    };
    neg == 0 || pos == 0
};

// quad_over(r, c) -> the Chebyshev distance from (r,c) to the nearest cell that
// is inside a front face's projected quad, capped at 9.
//
// Why a DISTANCE, and why a tolerance of T2_TOL cells:
//
//  * A scanline fill computes each row's span endpoints with integer
//    division, so its extreme cell can land one cell outside the true edge.
//    That is inherent to filling a real polygon into an integer grid.
//  * The quad's four vertices are themselves rounded to cells, and for a thin
//    face that rounding can make one vertex slightly reflex, so the polygon
//    the fill actually covers is not quite convex and in_quad()'s
//    all-signs-agree test rejects the very vertex it contains.  That costs one
//    more cell.
//  * What WOULD be a defect is a fill that walks the bounding box instead of
//    the quad: that overhangs by tens of cells.  Injected and measured, it
//    reports 9 -- the cap -- against this code's 0..2.
//
// So the check is quantitative and the number is printed, rather than a
// yes/no tuned until it passes.
const T2_TOL: long = 2;

def quad_over(r: long, c: long) -> long {
    let best = 9;
    for dr in 0 - T2_TOL..T2_TOL + 1 {
        for dc in 0 - T2_TOL..T2_TOL + 1 {
            if (best > 1) {
                let hitq = false;
                for k in 0..NFRONT {
                    if (in_quad(FORD[k], r + dr, c + dc)) { hitq = true; };
                };
                if (hitq) {
                    let d = iabs(dr);
                    if (iabs(dc) < d) { d = iabs(dc) };
                    if (d < best) { best = d; };
                }
            }
        }
    };
    best
};

// selftest(n) -> 0 if every frame passes both checks, 1 otherwise.
def selftest(n: long) -> long {
    let fails = 0;
    let shown = 0;
    let worst_draw = 0;
    let worst_off = 0;
    let worst_fill = 0;
    let fno: long = 0;
    let go = n > 0;
    let save_solid = SOLID;
    let save_floor = FLOOR_ON;
    let save_outline = OUTLINE;
    while (go) {
        // ---- T1: a wireframe draws only edges
        SOLID = false;
        FLOOR_ON = false;
        OUTLINE = true;
        draw_frame(fno);
        let drawn = 0;
        let off = 0;
        for r in 0..ROWS {
            let c = 0;
            while (c < COLS) {
                if (fb.get(SURF, r, c) != 32) {
                    drawn = drawn + 1;
                    if (!on_edge(r, c)) { off = off + 1 };
                };
                c = c + 1
            }
        };
        if (drawn > worst_draw) { worst_draw = drawn; };
        if (off > 0) {
            fails = fails + 1;
            if (off > worst_off) { worst_off = off; };
            // Ten lines is plenty: a systematic failure prints ten and then
            // the summary, rather than burying the summary.
            if (shown < 10) {
                shown = shown + 1;
                puts("T1 FAIL frame " + tostring(fno) + ": " + tostring(off) + " of "
                     + tostring(drawn) + " drawn cells are not on a projected edge\n")
            }
        };

        // ---- T2: the solid fill is the projected quad, not its bounding box
        SOLID = true;
        OUTLINE = false;
        draw_frame(fno);
        let out = 0;
        let over = 0;
        for r in 0..ROWS {
            let c = 0;
            while (c < COLS) {
                if (fb.get(SURF, r, c) != 32) {
                    let d = quad_over(r, c);
                    if (d > over) { over = d; };
                    if (d > T2_TOL) { out = out + 1 };
                };
                c = c + 1
            }
        };
        if (over > worst_fill) { worst_fill = over; };
        if (out > 0) {
            fails = fails + 1;
            if (shown < 10) {
                shown = shown + 1;
                puts("T2 FAIL frame " + tostring(fno) + ": " + tostring(out)
                     + " filled cells are more than " + tostring(T2_TOL) + " cells outside every front"
                     + " face's projected quad (worst " + tostring(over) + ")\n")
            }
        };

        fno = fno + 1;
        go = fno < n
    };
    SOLID = save_solid;
    FLOOR_ON = save_floor;
    OUTLINE = save_outline;
    puts("selftest: " + tostring(n) + " frames at " + tostring(ROWS) + "x"
         + tostring(COLS) + "\n");
    puts("  T1 wireframe: most cells drawn in one frame " + tostring(worst_draw)
         + ", most cells off a projected edge " + tostring(worst_off) + "\n");
    puts("  T2 solid:     most cells outside a front face's quad, in cells "
         + tostring(worst_fill) + " (a bounding-box fill measures 9; must be <= "
         + tostring(T2_TOL) + ")\n");
    puts("  RESULT " + (if fails == 0 { "PASS" } else { "FAIL" }) + "\n");
    if (fails == 0) { 0 } else { 1 }
};

// ══════════════════════════════════════════════════════════════ plain text ══
//
// --no-tty writes one header line and ROWS lines of ROWS characters per frame,
// through the same surface the terminal path draws into, so the two paths
// cannot drift apart.  The colour mode is in the header and the glyphs are the
// ASCII ramp: a text file cannot carry a colour, and saying so is better than
// pretending.
def emit_text(fno: long, total: long) {
    putbytes("--- frame ");
    put4(fno);
    putbytes("/");
    put4(total);
    putbytes(" ");
    putbytes(if SOLID { "solid" } else { "wire" });
    putbytes(" ");
    putbytes(color_name());
    putbytes(" yaw ");
    put4(tenths(YAW));
    putbytes(" pitch ");
    put4(tenths(PIT));
    putbytes(" ---\n");
    flush_ob();
    for r in 0..ROWS {
        ON = 0;
        for c in 0..COLS {
            let cp = fb.get(SURF, r, c);
            // Everything the plain-text path draws is printable ASCII; a
            // stray byte outside that would be a bug here rather than a
            // reason to emit it.
            putc(if cp >= 32 && cp <= 126 { cp } else { 32 });
        };
        putc(10);
        flush_ob()
    }
};

// tenths(rad) -- an angle in radians as tenths of a degree, rounded.  The
// rounding matters: 6 degrees is 5.99985 after two Q30 products, and a header
// that said 5.998 would be lying about a frame the reader can count.
def tenths(rad: long) -> long {
    fx.to_int(fx.round(fx.mul(fx.to_deg(rad), fx.from_int(10))))
};

def color_name() -> str {
    if (CMODE == C_GRAY) { return "gray"; };
    if (CMODE == C_GREEN) { return "green"; };
    if (CMODE == C_AMBER) { return "amber"; };
    if (CMODE == C_ICE) { return "ice"; };
    "mono"
};

def color_of(s: str) -> long {
    if (s == "gray" || s == "grey") { return C_GRAY; };
    if (s == "green") { return C_GREEN; };
    if (s == "amber") { return C_AMBER; };
    if (s == "ice") { return C_ICE; };
    if (s == "mono") { return C_MONO; };
    0 - 1
};

// ══════════════════════════════════════════════════════════════════ driver ══

// The interactive path.  Every exit out of here goes through
// term.restore_all_exit, and the watchdog is armed before the first frame so
// a crash or a SIGKILL still puts the terminal back (term.y's whole reason).
def run_tty(nframes: long, fps: long, stats: bool) {
    if (!term.is_tty(0) || !term.is_tty(1)) {
        eputs("cube: stdout is not a terminal -- try --no-tty --frames N\n");
        exit(1);
    };
    if (!term.raw_mode()) {
        eputs("cube: cannot enter raw mode\n");
        exit(1);
    };
    term.enter_screen();
    term.arm_watchdog();

    let pacer = time.pacer_new(if fps > 0 { fps } else { 1 });
    let meter = time.fps_new();
    let h0 = heap_used();
    let t0 = time.now_us();
    let fno: long = 0;
    let go = true;
    while (go) {
        // POLL, do not wait.  read_key_timeout takes whole deciseconds on the
        // terminal's own clock, so read_key_timeout(10) is a 100 ms wait --
        // three frame times at 30 fps -- and using it as a "key handler" caps
        // the loop at 10 fps and makes the pacer drop every frame.  0 is a
        // pure poll (VMIN=0, VTIME=0) and costs nothing, and the pacer below
        // owns the waiting.
        let k = term.read_key_timeout(0);
        if (k == K_Q || k == term.KEY_ESC || k == K_CTRL_C) { go = false; }
        else if (k == K_S) { SOLID = !SOLID; }
        else if (k == K_C) { CMODE = (CMODE + 1) % 5; };
        if (go) {
            // Resize costs no allocation and forces one full repaint.
            poll_size();
            // The pacer sleeps to an absolute deadline and answers negative
            // when the frame was already a whole period late: drop it rather
            // than draw faster than real time, so a stall costs one frame and
            // the schedule comes straight back.  Unpaced (`--fps 0`) there is
            // no pacer in the way and the answer is 0, which draws.
            let late: long = 0;
            if (fps > 0) { late = time.pacer_next(pacer); };
            if (late >= 0) {
                let d0 = time.now_us();
                draw_frame(fno);
                fb.flush_diff(SURF);
                DRAW_US = DRAW_US + (time.now_us() - d0);
                time.fps_tick(meter);
                fno = fno + 1;
                if (nframes > 0 && fno >= nframes) { go = false; }
            }
        }
    };
    if (stats) { report(nframes, fno, h0, t0, meter) };
    term.restore_all_exit(0)
};

// fit(rows, cols) -- adopt a geometry, clamped to what fb.Surface holds.  No
// allocation: fb.resize() only rewrites two fields and resets the shadow.
def fit(rows: long, cols: long) -> void {
    ROWS = clampi(rows, 1, fb.MAX_ROWS);
    COLS = clampi(cols, 1, fb.MAX_COLS);
    // The focal length, in PIXELS per world unit at unit depth, and the single
    // number that decides how big the cube looks.
    //
    // Sweeping both angles over a whole turn, the projected radius of the cube
    // is at most 0.283 across and 0.3015 up, whatever the orientation -- those
    // two constants are what the vertical and horizontal limits below are made
    // of, and they are why the cube stays whole at every angle instead of
    // swinging off the top of the screen twice a turn.
    //
    // A terminal cell is about twice as tall as it is wide, so the vertical
    // half is FPV = FOCAL_PX / 2 and the ROW count is what binds first:
    //   1/0.283 = 3.54    horizontal: FOCAL_PX * 0.283 <= COLS/2 - 2
    //   1/0.3015 = 3.32   vertical:   FPV * 0.3015 <= ROWS/2 - 1, the rows
    //                          above the centre
    // Both are worked out in integers below.  The cube then fills the frame
    // at its worst angle and about 70% of it at its best, which is what
    // perspective does to a solid: it breathes, and the breathe is the point.
    FOCAL_PX = 7 * (COLS / 2 - 2) / 2;
    let vcap = (33 * ROWS - 66) / 10;
    if (vcap < FOCAL_PX) { FOCAL_PX = vcap; };
    if (FOCAL_PX < 1) { FOCAL_PX = 1; };
    FPV = FOCAL_PX / 2;
    SURF = fb.resize(SURF, ROWS, COLS)
};

def report(want: long, got: long, h0: long, t0: long, meter: time.Fps) -> void {
    let el = time.now_us() - t0;
    let x100 = time.fps_avg_x100(meter);
    let h1 = heap_used();
    // `got` can be 0 -- the plain-text path with --frames 0 draws nothing --
    // and a divide by it would be the one trap left in this file, so the
    // per-frame figure is guarded here and nowhere else it is needed.
    let per = if got > 0 { DRAW_US / got } else { 0 };
    eputs("cube: " + tostring(got) + " frames at " + tostring(ROWS) + "x"
          + tostring(COLS) + ", " + (if SOLID { "solid" } else { "wireframe" })
          + ", " + color_name() + "\n");
    eputs("cube: " + tostring(el / 1000) + " ms wall, "
          + tostring(x100 / 100) + "." + two_digits(x100 % 100) + " fps average"
          + ", " + tostring(per) + " us of work a frame (a 30 fps frame is 33333 us)\n");
    eputs("cube: heap_used() " + tostring(h0) + " -> " + tostring(h1)
          + ", delta " + (if h1 >= h0 { "+" } else { "" })
          + tostring(h1 - h0) + " bytes over the frame loop\n");
    if (want > 0) { eputs("cube: " + tostring(want) + " frames requested\n") }
};

def two_digits(v: long) -> str {
    if (v < 10) { return "0" + tostring(v) };
    tostring(v)
};

// The plain-text path.  No pacing by default: the output is a file, not an
// animation, and --frames 60 should not take two seconds to produce 71 KB of
// text.  --fps 30 asks for the pacing back.
def run_text(nframes: long, fps: long, stats: bool) {
    let pacer = time.pacer_new(if fps > 0 { fps } else { 1 });
    let meter = time.fps_new();
    let h0 = heap_used();
    let t0 = time.now_us();
    let fno: long = 0;
    let go = nframes != 0;
    while (go) {
        if (fps > 0) { time.pacer_next(pacer); };
        // DRAW_US covers drawing AND writing, so it is the whole cost of a
        // frame on this path and the number to compare against the 33333 us a
        // 30 fps frame allows.
        let d0 = time.now_us();
        draw_frame(fno);
        emit_text(fno, if nframes > 0 { nframes } else { 0 });
        DRAW_US = DRAW_US + (time.now_us() - d0);
        time.fps_tick(meter);
        fno = fno + 1;
        if (nframes > 0 && fno >= nframes) { go = false; }
    };
    if (stats) { report(nframes, fno, h0, t0, meter) }
};

// ── main ──
args.init("cube", "a rotating cube, wireframe or shaded solid, 30 fps", OPT);
let ast = args.parse(argv());
if (ast == args.HELP) { puts(args.usage()); exit(0); };
if (ast == args.USAGE) {
    // args.y has already printed "cube: unknown option '--whatever'" on
    // stderr; all that is left is the exit code.
    exit(1)
};
// This program takes no operands, so an operand is a mistake worth naming
// rather than a file to be quietly ignored.
let extra = args.positional();
if (len(extra) > 0) {
    eputs("cube: unexpected operand '" + extra[0] + "'\n");
    exit(1)
};

let nframes = clampi(args.get_long("frames", 0), 0, 100000000);
let stats = args.has("stats");
NOTTY = args.has("no-tty");
SOLID = args.has("solid");
if (args.has("wireframe")) { SOLID = false; };
FLOOR_ON = args.has("floor");
let ntest = clampi(args.get_long("selftest", 0), 0, 1000000);

let cname = args.get_str("color", "mono");
let cm = color_of(cname);
if (cm < 0) {
    eputs("cube: --color wants mono|gray|green|amber|ice, got '" + cname + "'\n");
    exit(1)
};
CMODE = cm;

// --size WxH, if given.  Both halves must be whole numbers, or this is a
// usage error: a size nobody asked for is worse than one that is rejected.
// --size is WIDTH x HEIGHT and fit() is (rows, cols), so the halves swap
// places on the way in; everything else here -- fb.new(rows, cols),
// term.WinSize{rows, cols} -- is rows first, which is why this call says so.
let sz = args.get_str("size", "");
if (len(sz) > 0) {
    let at = sz.index_of("x");
    if (at < 0) { at = sz.index_of("X") };
    let ok = at > 0 && at < len(sz) - 1;
    let sr = 0;
    let sc = 0;
    if (ok) {
        let a = sz[0:at];
        let b = sz[at + 1:];
        if (args.num_ok(a) && args.num_ok(b)) {
            sr = tonum(a);
            sc = tonum(b);
        } else {
            ok = false
        }
    };
    if (!ok) {
        eputs("cube: --size wants WxH, got '" + sz + "'\n");
        exit(1)
    };
    let w = sr;
    let h = sc;
    fit(h, w)
} else if (NOTTY) {
    // The window is not ours to ask about in the plain-text path, and a
    // size that depended on the terminal would make EXPECTED depend on the
    // machine.  24 rows by 60 columns is the documented default.
    fit(24, 60)
} else {
    let ws = term.size();
    fit(ws.rows, ws.cols)
};

// The frame rate.  Unpaced in the plain-text path unless it is asked for, and
// 30 everywhere else.
let fps = if args.has("fps") { args.get_long("fps", 30) } else { if NOTTY { 0 } else { 30 } };
let pace = clampi(fps, 0, 1000);

// The correctness checks come first and exit: they are a gate, not a mode.
// They draw into the surface and read it back, so they need no terminal and
// ignore --fps.
if (ntest > 0) {
    exit(selftest(ntest))
};

if (NOTTY) {
    run_text(nframes, pace, stats);
} else {
    run_tty(nframes, pace, stats)
};
exit(0);