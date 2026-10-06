// donut.y -- Andy Sloane's spinning ASCII torus, in your terminal, at 30 fps.
//
//   usage: donut [options]
//
// The picture is a torus sampled on a fixed na x nb grid of (theta, phi),
// rotated by two angles per frame, projected through a z-buffer and drawn one
// cell at a time through the framebuffer's ramps.  Only the cells that changed
// are written, which is what makes 30 fps affordable: a settled frame emits a
// few hundred bytes instead of a few hundred kilobytes.
//
//   build:  ycc -o donut donut.y     (fx.y tui tui tui args torus.y
//                                      and textout.y must sit beside it)
//   run:    ./donut                  interactive, until q or Escape
//          ./donut --frames 60 --no-tty   the deterministic run
//
// All of the geometry is in torus.y.  This file is the command line, the
// palettes, the status line and the two frame loops.

import fx;
import args;
import torus;
import textout;
import tui;

// ─────────────────────────────────────────────────────────── the palettes ───
//
// mono is examples/badapple's default and its spelling: classic white on
// black, with the shape carried entirely by the glyph ramp.  gray, green,
// amber and ice are the same luminance fit badapple does -- the foreground is
// lerped along the mode's ramp by the luminance of the nearest subpixel the
// surface won -- on a phosphor tint instead of neutral grey.
//
// These are `let`, not `const`: tui.rgb() is a call, and a const wants a
// compile-time value.  Top-level bindings do not warn (ORCHESTRATOR.md 2.11).
let PAL_LO: [long; 5] = [
    0,
    tui.rgb(20, 20, 24),          // gray
    tui.rgb(10, 44, 16),          // green
    tui.rgb(52, 22, 4),           // amber
    tui.rgb(12, 34, 68)           // ice
];
let PAL_HI: [long; 5] = [
    0,
    tui.rgb(240, 240, 240),
    tui.rgb(150, 255, 172),
    tui.rgb(255, 206, 96),
    tui.rgb(172, 226, 255)
];
let PAL_BG: [long; 5] = [
    tui.rgb(0, 0, 0),
    tui.rgb(6, 6, 8),
    tui.rgb(2, 8, 4),
    tui.rgb(10, 5, 1),
    tui.rgb(2, 6, 14)
];
let PAL_FLAT: [long; 5] = [1, 0, 0, 0, 0];          // 1 = one colour for all
let PAL_MONO: [long; 5] = [tui.rgb(214, 214, 214), 0, 0, 0, 0];

let NAMES: [str] = ["mono", "gray", "green", "amber", "ice"];
let GLYPHS: [str] = ["ascii", "blocks", "half", "braille"];
let GLNAME: [str] = ["ascii", "blocks", "half", "braille"];

// ─────────────────────────────────────────────────────────────── options ───
//
// Spelled and worded to match examples/badapple, which is where the
// --color=mono|gray|green|amber|ice convention comes from.
let OPTS: [args.Opt] = [
    { long: "frames", short: "n", kind: args.NUM,
      help: "render exactly N frames, then exit 0 (default 0: run until q)" },
    { long: "color", short: "c", kind: args.STR,
      help: "mono | gray | green | amber | ice   (mono: classic white-on-black; gray/green/amber/ice: the same luminance fit on a tint)" },
    { long: "glyph", short: "g", kind: args.STR,
      help: "ascii | blocks | half | braille   (ascii: the classic ' .:-=+*#@' ramp)" },
    { long: "size", short: "s", kind: args.STR,
      help: "WxH cells, clamped to 1x1..200x100; default the terminal, or 60x24 without one" },
    { long: "fps", short: "f", kind: args.NUM,
      help: "frames per second, interactive only (default 30)" },
    { long: "no-tty", short: "", kind: args.BOOL,
      help: "render into a text capture instead of the terminal; never paces" },
    { long: "dump", short: "d", kind: args.STR,
      help: "comma-separated frame numbers to print as text beside their digest (default: the last frame)" },
    { long: "time", short: "", kind: args.BOOL,
      help: "report wall clock, fps and the heap delta on stderr when done" }
];

// ───────────────────────────────────────────────────────────────── state ───
//
// Radians per frame in Q30, spelled through fx.ONE so the scale is visible:
// 0.045 rad a frame is a full turn about x every 5.8 s at 30 fps, and 0.018 is
// a turn about z every 14.6 s -- deliberately incommensurate, so the torus
// never comes back to the same pose and the loop never looks like a loop.
let stepA: long = 45 * fx.ONE / 1000;
let stepB: long = 18 * fx.ONE / 1000;
let rate: long = 100;              // percent; + and - move it
let paused: long = 0;
let gm: long = 0;                  // glyph mode, 0..3
let cm: long = 0;                  // colour mode, 0..4

let FRAMES: long = 0;              // 0 = until a key
let NOTTY: long = 0;
let SHOWTIME: long = 0;
let FPSWANT: long = 30;

// Frames the deterministic run prints in full.  want_dump is one bit per frame
// index; DUMPS is the same set in the order --dump listed it, for the header.
let WANTN: long = 1024;
let want_dump: [long; 1024] = [0; 1024];
let NDUMP: long = 0;
let DUMPS: [long; 32] = [0; 32];
let want_any: long = 0;

// ─────────────────────────────────────────────────────────────── palette ───
//
// torus_palette() is called ONCE, after the colour mode is known.  It is a
// setter rather than a record passed per frame because a record literal costs
// 64 bytes every time it is evaluated (ORCHESTRATOR.md 2.7), and this example's
// whole claim is that a frame costs zero bytes of heap.
def render(s: tui.Surface) -> void {
    if (paused == 0) {
        torus.torus_step(stepA * rate / 100, stepB * rate / 100)
    } else {
        torus.torus_step(0, 0)
    };
    torus.torus_draw(s, gm)
};

// ──────────────────────────────────────────── allocation-free size poll ───
//
// Y has no SIGWINCH, so a program that wants to follow a terminal resize has to
// ask.  tui.size() is the right call and it is used once, at start-up -- but on
// a poll it is a leak: it ANSWERS WITH A RECORD, and a record literal is
// evaluated onto the heap every time the expression runs (39 bytes measured,
// see the note on DIG below), so a once-a-frame size check would leak 1.4 MB
// an hour.
//
// So the poll is TIOCGWINSZ into a byte buffer of our own plus tui.rd16, which
// is the very decode tui.size() performs -- same answer, one syscall, zero
// bytes of heap.  A [byte] has to be growable to be passed at all: a [byte; N]
// is not a [byte] in Y.
let WSB: [byte] = [0; 64];
let trows: long = 24;
let tcols: long = 80;

// poll_winsize() -> long -- 1 when the window changed and trows/tcols now hold
// its new size, 0 when it did not (or when the ioctl failed, or reported a
// zero, which is what a pty with no TIOCSWINSZ looks like).
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

// ─────────────────────────────────────────── allocation-free status line ───
//
// One integer, a digit at a time, straight into the surface.  A HUD that
// called tostring() once a frame would allocate on the frame loop, and the whole
// claim of this example is that the frame loop does not.
//
// The digit scratch is a module-level array for the same reason, and this is
// the sharp edge of that rule: an ARRAY LITERAL is evaluated onto the heap
// every time the expression runs -- 72 bytes for [long; 12], measured -- so a
// literal written inside this def would leak six times a frame.  Records are
// the same: a record literal allocates 64 bytes per evaluation.  Records passed
// to a def are free, though -- they go by reference -- so what a frame path may
// never contain is a literal, not a record.
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
        tui.put(s, row, at, d[i], 150, PAL_BG[cm]);
        at = at + 1;
        i = i + 1;
    };
    at
};

def hud(s: tui.Surface, row: long, frame: long, fps: long) -> void {
    let dim = tui.rgb(88, 96, 104);
    tui.put(s, row, 0, 9472, tui.rgb(34, 38, 42), PAL_BG[cm]);
    for k in 1..s.cols { tui.put(s, row, k, 9472, tui.rgb(34, 38, 42), PAL_BG[cm]); };
    let c = 2;
    tui.text(s, row, c, "donut", tui.rgb(150, 160, 170), PAL_BG[cm]);
    c = c + 6;
    c = sline(s, row, c, frame);
    tui.text(s, row, c, "fps", dim, PAL_BG[cm]); c = c + 4;
    c = sline(s, row, c, fps);
    c = c + 1;
    tui.text(s, row, c, NAMES[cm], tui.rgb(205, 175, 95), PAL_BG[cm]);
    c = c + len(NAMES[cm]);
    tui.text(s, row, c, "spin", dim, PAL_BG[cm]); c = c + 5;
    c = sline(s, row, c, rate);
    tui.text(s, row, c, "%", dim, PAL_BG[cm]); c = c + 2;
    if (paused != 0) {
        tui.text(s, row, c, "PAUSED", tui.rgb(225, 185, 85), PAL_BG[cm]);
    } else {
        tui.text(s, row, c, "q quit   +/- spin   space pause", dim, PAL_BG[cm])
    }
};

// ─────────────────────────────────────────────────────────── CLI parsing ───

// report(n, bytes, fps, h0, h1) -> void -- the one-line summary both exits
// print on stderr, on top of the alt screen rather than inside it.  The heap
// delta is the load-bearing number: it is the frame loop's whole memory
// behaviour, measured rather than asserted.
def report(n: long, bytes: long, fps: long, h0: long, h1: long) -> void {
    eputs("donut: ");
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
    eputs("\n")
};

def die(msg: str) -> void {
    eputs("donut: ");
    eputs(msg);
    eputs("\ndonut: try --help\n");
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

// parse_size -> long -- WxH packed as W*1000000 + H, or 0 if the string is not
// that shape.  Slicing rather than a hand-rolled byte scan, because a string
// slice is the clearest thing here and it allocates once, at start-up.
def parse_size(s: str) -> long {
    let at = s.index_of("x");
    if (at < 1) { return 0; };
    let a = s[0:at];
    let b = s[at + 1:];
    if (!args.num_ok(a) || !args.num_ok(b)) { return 0; };
    let w = tolong(a);
    let h = tolong(b);
    // A size is clamped, never refused: --size 0x0 must render one cell and
    // exit 0 rather than divide by zero somewhere in the projection.
    if (w < 1) { w = 1; };
    if (h < 1) { h = 1; };
    if (w > torus.COLS_MAX) { w = torus.COLS_MAX; };
    if (h > torus.ROWS_MAX) { h = torus.ROWS_MAX; };
    w * 1000000 + h
};

def load_dumps(s: str, last: long) -> void {
    if (s == "") {
        // The default is the last frame, which is the one a reader wants to
        // see and the one a golden file should hold.
        if (last >= 0 && last < FRAMES) {
            want_dump[last] = 1;
            want_any = 1;
            NDUMP = 1;
            DUMPS[0] = last;
        };
        return;
    };
    let parts = s.split(",");
    for k in 0..len(parts) {
        let p = parts[k];
        if (len(p) > 0 && args.num_ok(p)) {
            let v = tolong(p);
            // A frame the run will not reach is not a frame it can dump, and
            // listing it in the header would promise something the output does
            // not contain.
            if (v >= 0 && v < FRAMES) {
                if (want_dump[v] == 0) {
                    want_dump[v] = 1;
                    want_any = want_any + 1;
                    if (NDUMP < 32) { DUMPS[NDUMP] = v; NDUMP = NDUMP + 1; };
                };
            };
        };
    }
};

// ─────────────────────────────────────────────────────────────── the run ───

args.init("donut", "Andy Sloane's spinning torus, in a terminal, at 30 fps.",
          OPTS);
let st = args.parse(argv());
if (st == args.HELP) {
    puts(args.usage());
    puts("\ncolor modes (as in examples/badapple):\n");
    puts("  mono   classic white-on-black, shape carried by the glyph ramp (default)\n");
    puts("  gray   the same luminance fit on neutral grey, so edges read soft\n");
    puts("  green / amber / ice   the same fit on a phosphor tint\n");
    puts("\nglyph modes:\n");
    puts("  ascii    ' .:-=+*#@' by luminance -- the classic donut ramp (default)\n");
    puts("  blocks   tui's shade-block ramp by luminance, 5 levels\n");
    puts("  half     tui's half-block ramp by luminance, 4 levels\n");
    puts("  braille  U+2800+mask by coverage: the honest 2x4 dots of each cell\n");
    puts("\nkeys, interactive:  q or Escape quit, +/- spin speed, space pause, r reset\n");
    exit(0)
};
if (st == args.USAGE) {
    eputs("donut: try --help\n");
    exit(1)
};

if (len(args.positional()) > 0) {
    die("takes no operands; got '" + args.positional()[0] + "'")
};

cm = mode_of(args.get_str("color", "mono"), "--color", NAMES);
gm = mode_of(args.get_str("glyph", "ascii"), "--glyph", GLYPHS);
FRAMES = args.get_long("frames", 0);
FPSWANT = args.get_long("fps", 30);
if (FPSWANT < 1) { FPSWANT = 1; };
if (FPSWANT > 240) { FPSWANT = 240; };
NOTTY = if (args.has("no-tty")) { 1 } else { 0 };
SHOWTIME = if (args.has("time")) { 1 } else { 0 };
let SZ = args.get_str("size", "");
let HAVE_SIZE = args.has("size");

// The size, decided before anything is built: the geometry and the surface must
// agree, so both come from the same two numbers.
let ws = tui.size();
trows = ws.rows;
tcols = ws.cols;
let grow = 0;
let gcol = 0;
if (HAVE_SIZE) {
    let sz = parse_size(SZ);
    if (sz == 0) { die("--size wants WxH, e.g. --size 80x24"); };
    gcol = sz / 1000000;
    grow = sz % 1000000;
};
if (NOTTY != 0) {
    // There is no terminal to ask, so without --size the size is a fixed
    // default.  That is what makes the deterministic run reproducible on a
    // machine whose window happens to be a different shape.
    if (HAVE_SIZE == false) { gcol = 60; grow = 24; };
    if (FRAMES < 1) { FRAMES = 1; };
} else {
    // One row of the terminal is the status line.
    grow = ws.rows - 1;
    gcol = ws.cols;
    if (grow < 2) { grow = 2; };
    if (grow > torus.ROWS_MAX) { grow = torus.ROWS_MAX; };
    if (gcol < 4) { gcol = 4; };
    if (gcol > torus.COLS_MAX) { gcol = torus.COLS_MAX; };
};
load_dumps(args.get_str("dump", ""), FRAMES - 1);

torus.torus_palette(PAL_LO[cm], PAL_HI[cm], PAL_BG[cm],
                    PAL_FLAT[cm], PAL_MONO[cm]);
torus.torus_reset();
let SAMPLES = torus.torus_setup(grow, gcol);
let SR = torus.torus_rows();
let SC = torus.torus_cols();
let srf = tui.new(SR, SC);

// ══════════════════════════════════════════════ the deterministic path ═══
//
// The same draw and the same tui.flush_diff as the terminal path -- the ANSI
// stream is built and counted either way, which is what makes the byte column
// in the digest evidence rather than a claim -- except that it goes to
// /dev/null and the text goes to stdout instead.
//
// NO PACING HERE, deliberately.  This path exists to answer "how fast can the
// machine draw frames", and a sleep in the middle of it would measure
// nanosleep instead.  fpsWanted is an interactive knob.
if (NOTTY != 0) {
    let devnull = syscall(257, 0 - 100, "/dev/null", 1, 0, 0, 0);   // openat
    if (devnull >= 0) { tui.set_fd(devnull); };
    tui.capture_on();

    textout.out_str("donut: frames=");
    textout.out_num(FRAMES);
    textout.out_str(" size=");
    textout.out_num(SC);
    textout.out_str("x");
    textout.out_num(SR);
    textout.out_str(" glyph=");
    textout.out_str(GLNAME[gm]);
    textout.out_str(" color=");
    textout.out_str(NAMES[cm]);
    textout.out_str(" samples=");
    textout.out_num(SAMPLES);
    textout.out_str("\ndumped frames:");
    for k in 0..NDUMP {
        textout.out_str(" ");
        textout.out_num(DUMPS[k]);
    };
    textout.out_str("\n");

    let h0 = heap_used();
    let t0 = clock_us();
    let f = 0;
    while (f < FRAMES) {
        render(srf);
        tui.capture_reset();
        tui.flush_diff(srf);
        textout.out_str("frame ");
        textout.out_pad(f, 4);
        textout.out_str(" bytes ");
        textout.out_pad(tui.frame_bytes(), 8);
        textout.out_str(" rows ");
        textout.out_pad(tui.row_count(), 5);
        textout.out_str(" dots ");
        textout.out_pad(torus.torus_covered(), 8);
        textout.out_str(" clip ");
        textout.out_pad(torus.torus_missed(), 7);
        textout.out_str(" sha ");
        textout.out_hex16(textout.grid_digest(srf));
        if (want_dump[f] != 0) {
            textout.out_str("\n--- frame ");
            textout.out_num(f);
            textout.out_str(" ---\n");
            textout.grid_text(srf);
        };
        textout.out_str("\n");
        f = f + 1;
    };
    let t1 = clock_us();
    let h1 = heap_used();
    textout.out_flush();

    if (SHOWTIME != 0) {
        let el = t1 - t0;
        let per = el / FRAMES;
        let x100 = if (per > 0) { 10000000 / per } else { 0 };
        eputs("donut: ");
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
        eputs(" fps\ndonut: heap_used before=");
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
// leaves.  Y has no atexit and no signal handler, so every exit below is a
// call to tui.restore_all_exit() -- there is no path out of this loop that
// does not go through it.
if (!tui.raw_mode()) {
    eputs("donut: not a terminal; try --frames N --no-tty\n");
    exit(1)
};
tui.enter_screen();
tui.arm_watchdog();

let pacer = tui.pacer_new(FPSWANT);
let meter = tui.fps_new();
tui.pacer_start(pacer);

let frame = 0;
let quit = false;
let checked = 0;
let bytes = 0;
let bytes_sum = 0;
let ih0 = heap_used();

while (quit == false) {
    let wait = tui.pacer_next(pacer);
    if (wait >= 0) {
        render(srf);
        hud(srf, SR - 1, frame, tui.fps_x100(meter) / 100);
        bytes = tui.flush_diff(srf);
        bytes_sum = bytes_sum + bytes;
        tui.fps_tick(meter);
        frame = frame + 1;
        if (FRAMES > 0 && frame >= FRAMES) {
            report(frame, bytes_sum, tui.fps_x100(meter) / 100, ih0, heap_used());
            tui.restore_all_exit(0)
        };
    };

    // Poll the keyboard on every frame when nobody is timing us and every
    // fourth frame when they are: 13 ms of key latency at 30 fps, and
    // read_key_timeout(0) is an immediate poll, never a blocking read.  A
    // resize is looked for on the same beat, because Y has no SIGWINCH.
    checked = checked + 1;
    if (checked >= 4 || FRAMES == 0) {
        checked = 0;
        // Keys come back as bytes, so they are compared as bytes: Y has no
        // char literal, and ord() is how a name becomes the byte it means.
        let k = tui.read_key_timeout(0);
        if (k == ord("q") || k == ord("Q") || k == tui.KEY_ESC) {
            quit = true;
        } else if (k == ord("+") || k == ord("=")) {
            if (rate < 400) { rate = rate + 25; };
        } else if (k == ord("-") || k == ord("_")) {
            if (rate > 25) { rate = rate - 25; };
        } else if (k == ord(" ")) {
            if (paused != 0) { paused = 0; } else { paused = 1; };
        } else if (k == ord("r")) {
            torus.torus_reset()
        };
        if (poll_winsize() != 0) {
            let nr = trows - 1;
            let nc = tcols;
            if (nr < 2) { nr = 2; };
            if (nr > torus.ROWS_MAX) { nr = torus.ROWS_MAX; };
            if (nc < 4) { nc = 4; };
            if (nc > torus.COLS_MAX) { nc = torus.COLS_MAX; };
            torus.torus_setup(nr, nc);
            srf = tui.resize(srf, torus.torus_rows(), torus.torus_cols());
            SR = torus.torus_rows();
            SC = torus.torus_cols();
        };
    };
};

report(frame, bytes_sum, tui.fps_x100(meter) / 100, ih0, heap_used());
tui.restore_all_exit(0);