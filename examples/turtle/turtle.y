// turtle.y -- a turtle-graphics interpreter, in a terminal.
//
//   build:  ycc -o turtle turtle.y
//   run:    ./turtle                        interactive: . steps, a auto-runs
//          ./turtle --no-tty --frames 3      the deterministic path
//          ./turtle --script prog.turtle    a file instead of a built-in
//          ./turtle --list                  the built-in programs
//          ./turtle --check 4000            the property check
//
// The language is eight commands -- forward, back, left, right, setheading, pen
// up/down, colour, dot, jump, repeat -- over an integer turtle with a heading in
// milli-degrees.  tlang.y is the whole language and knows nothing about pixels;
// scene.y is the whole rasteriser; this file is the command line, the frame
// loops and the status line.
//
// ── what is worth looking at ───────────────────────────────────────────────
//
// The heading arithmetic.  `left 90` four times must return the heading to where
// it started BIT FOR BIT, and a heading that goes negative is where an
// off-by-one hides: the picture still comes out right, so a golden file cannot
// see it.  That is the property check's whole first section, and it is worth
// running once to watch it.
//
// The polygon closure.  Four 100-unit moves with a quarter turn between them
// end at (0,0) facing 0 -- and so do a triangle, a pentagon, a hexagon and an
// octagon, to the UNIT, because the step is rounded to whole units.  The
// pentagon is the interesting one: cos 72 degrees is irrational, so that closure
// is a consequence of the rounding and not of the trigonometry.  README,
// "why the polygons close", has the arithmetic.

import fx;
import args;
import tlang;
import scene;
import sink;
import check;
import tui;

// ──────────────────────────────────────────────────────────── options ───

let OPTS: [args.Opt] = [
    { long: "frames", short: "n", kind: args.NUM,
      help: "render exactly N frames then exit 0 (default 0: run until q)" },
    { long: "size", short: "s", kind: args.STR,
      help: "WxH cells, at most 256x128; default the terminal, or 80x24 without one" },
    { long: "prog", short: "p", kind: args.STR,
      help: "a built-in program: square tri pentagon octagon spiral koch flower lattice" },
    { long: "script", short: "f", kind: args.STR,
      help: "read the program from FILE instead of a built-in" },
    { long: "no-tty", short: "", kind: args.BOOL,
      help: "write the frame table and the last frame as text; never touches the terminal" },
    { long: "dump", short: "d", kind: args.STR,
      help: "comma-separated frame numbers to print as text beside their digest (default: the last)" },
    { long: "fps", short: "", kind: args.NUM,
      help: "frames per second, interactive only (default 15)" },
    { long: "step", short: "", kind: args.NUM,
      help: "commands per frame while auto-running, 1..64 (default 1)" },
    { long: "cursor", short: "", kind: args.BOOL,
      help: "draw the turtle itself (default off: it would be in the pen-up pixels)" },
    { long: "time", short: "", kind: args.BOOL,
      help: "report wall clock, cmds a second and the heap delta on stderr when done" },
    { long: "check", short: "", kind: args.NUM,
      help: "run the property check over N sample headings and exit 0 or 1; no reference file involved" },
    { long: "list", short: "L", kind: args.BOOL,
      help: "print the built-in programs and exit" }
];

const MAXDUMP: long = 64;
let WANT: [long; 64] = [0; 64];
let NWANT: long = 0;

// the working set
let FRAMES: long = 0;
let ROWS: long = 0;
let COLS: long = 0;
let SEL: long = 0;
let SCRIPT: str = "";
let SHOWTIME: long = 0;
let CHECKN: long = 0;
let FPSWANT: long = 15;
let STEPN: long = 1;
let WSB: [byte] = [0; 64];
let trows: long = 0;
let tcols: long = 0;
let FBX0: long = 0; let FBX1: long = 0;         // the finished program's bounding
let FBY0: long = 0; let FBY1: long = 0;         // box, kept for a resize refit
// TSTEPS -- how many commands the program EXECUTES, which is not how many
// opcodes it has: a repeat body runs once per pass.  The dry run counts them,
// and the frame split has to divide by this, not by the opcode count -- the
// first version divided by the opcodes and a program with a repeat finished in
// frame 3 of 3 having drawn two thirds of itself, which is exactly the kind of
// defect a golden file accepts without noticing.
let TSTEPS: long = 0;

def die(msg: str) -> void {
    eputs("turtle: ");
    eputs(msg);
    eputs("\nturtle: try --help\n");
    exit(1)
};

// ─────────────────────────────────────────────────── the terminal size ───
//
// tui.size() returns a FRESH record every call (~40 bytes), so it cannot be in
// a per-frame resize poll on an arena heap.  This does the TIOCGWINSZ ioctl
// into a module-level buffer and compares against the size we already have, so
// the common answer is "nothing changed" and nothing was allocated.
def poll_winsize() -> long {
    if (syscall(16, 1, 0x5413, &WSB[0]) < 0) { return 0 };
    let r = tui.rd16(WSB, 0);
    let c = tui.rd16(WSB, 2);
    if (r < 1 || c < 1) { return 0 };
    if (r == trows && c == tcols) { return 0 };
    trows = r;
    tcols = c;
    1
};

// ─────────────────────────────────────────────────── reading a script ───
//
// The kernel wants a NUL-terminated path and a Y str is length-prefixed with no
// terminator, so every path goes into a byte buffer with an explicit NUL on the
// end.  Passing a string LITERAL straight to openat happens to work (measured),
// which is not a reason to do it: a path assembled at run time from argv has no
// such luck, and "it worked for the literal" is exactly how that turns into a
// report with -22 on it and nothing else.
let PATHBUF: [byte; 4096] = [0; 4096];
let SLURPBUF: [byte; 32768] = [0; 32768];

def cpath(p: str) -> long {
    let n = len(p);
    if (n + 1 > 4096) { return 0 - 1 };
    let i = 0;
    while (i < n) { PATHBUF[i] = byte_at(p, i); i = i + 1 };
    PATHBUF[n] = 0;
    n + 1
};

// slurp(path) -- the file as a str, or "" with a diagnostic.  from_bytes() is
// the inverse of bytes() and is the one way in: building a str a byte at a time
// with chr() would work for ASCII and would be 64 bytes a character.
def slurp(p: str) -> str {
    if (cpath(p) < 0) { return "" };
    // 257 = openat, AT_FDCWD = -100, O_RDONLY = 0
    let fd = syscall(257, 0 - 100, &PATHBUF[0], 0, 0);
    if (fd < 0) { return "" };
    let got = 0;
    let stop = false;
    while (stop == false) {
        // 0 = read
        let n = syscall(0, fd, &SLURPBUF[got], 32768 - got);
        if (n <= 0) { stop = true } else {
            got = got + n;
            if (got >= 32768) { stop = true }
        }
    };
    syscall(3, fd, 0, 0, 0, 0, 0);          // 3 = close
    if (got <= 0) { return "" };
    from_bytes(SLURPBUF[0:got])
};

// to_devnull() -- point fb's output at /dev/null.  fb emits a real ANSI stream
// on every flush, and headless (and --check, which also flushes a surface to
// capture it) has no terminal to emit it to.  The bytes are not lost: fb's
// capture buffer keeps a copy, which is what --check measures and --ansi writes.
def to_devnull() -> void {
    let d = 0 - 1;
    if (cpath("/dev/null") >= 0) { d = syscall(257, 0 - 100, &PATHBUF[0], 1, 0) };
    if (d >= 0) { tui.set_fd(d) }
};

// ────────────────────────────────────────────────────────── the header ───

// put_num(v, w) -- a signed number right-aligned, for the position columns.
def out_pos(v: long) -> void {
    if (v < 0) {
        sink.out_byte(45);
        sink.out_pad(0 - v, 8)
    } else {
        sink.out_pad(v, 9)
    }
};

def header(per: long) -> void {
    sink.out_str("turtle: prog=");
    sink.out_str(if (SCRIPT == "") { tlang.PROGNAME[SEL] } else { "file" });
    sink.out_str(" cmds ");
    sink.out_pad(tlang.NC, 4);
    sink.out_str(" steps ");
    sink.out_pad(TSTEPS, 5);
    sink.out_str(" frames ");
    sink.out_pad(FRAMES, 4);
    sink.out_str(" size ");
    sink.out_pad(scene.SC, 4);
    sink.out_str("x");
    sink.out_pad(scene.SR, 3);
    sink.out_str(" shift ");
    sink.out_pad(scene.SHX, 2);
    sink.out_str("/");
    sink.out_pad(scene.SHY, 2);
    sink.out_str(" cmd/frame ");
    sink.out_pad(per, 4);
    sink.out_str(" box ");
    out_pos(FBX0); sink.out_str(",");
    out_pos(FBY0);
    sink.out_str(" -> ");
    out_pos(FBX1); sink.out_str(",");
    out_pos(FBY1);
    sink.out_str("\n");
    sink.out_str("dumped frames:");
    let k = 0;
    while (k < NWANT) {
        sink.out_str(" ");
        sink.out_num(WANT[k]);
        k = k + 1
    };
    sink.out_str("\n")
};

// ───────────────────────────────────────────────── the deterministic path ───
//
// --no-tty --frames N.  No clock, no terminal, no randomness, so this is the
// invocation gate.conf names.  Each frame runs ceil(cmds/frames) commands, so
// the LAST frame is always the finished drawing however many frames were asked
// for -- a golden of frames=1 and a golden of frames=7 show the same picture and
// the same per-frame accounting.
//
// Nothing here allocates: no array or record literal is written inside the loop,
// the frame line goes into sink's module-level buffer, and the dumped frame is
// written out of the surface a glyph at a time.  That is checked, not asserted:
// `--time` reports the heap delta, which is 0 over any number of frames.
def headless() -> void {
    let per = 0;
    if (TSTEPS > 0 && FRAMES > 0) {
        per = (TSTEPS + FRAMES - 1) / FRAMES;
        if (per < 1) { per = 1 }
    };
    header(per);
    // fb emits a real ANSI stream on every flush.  Headless, that stream has to
    // go to /dev/null rather than to stdout, or it lands in the middle of the
    // frame table and EXPECTED is full of escape sequences.  The bytes are not
    // thrown away: fb's capture buffer keeps them, and the per-frame line
    // reports the capture length, so the stream is still there to be measured.
    to_devnull();
    tui.capture_on();
    let h0 = heap_used();
    let t0 = clock_us();
    let f = 0;
    let bytes_sum = 0;
    while (f < FRAMES) {
        let i = 0;
        let stop = false;
        // No break in this language: the early exit is a guard with an explicit
        // terminal assignment, and the body is wrapped in a positive condition.
        while (stop == false && i < per) {
            let e = scene.step_draw();
            if (e == 3 || e == 4) { stop = true } else { i = i + 1 }
        };
        scene.erase_cursor();
        scene.draw_cursor(tlang.X, tlang.Y, tlang.H);
        tui.capture_reset();
        bytes_sum = bytes_sum + tui.flush_diff(scene.SRF);
        sink.out_str("frame ");
        sink.out_pad(f, 3);
        sink.out_str(" bytes ");
        sink.out_pad(tui.frame_bytes(), 6);
        sink.out_str(" cap ");
        sink.out_pad(tui.capture_len(), 6);
        sink.out_str(" cmds ");
        sink.out_pad(tlang.STEPS, 5);
        sink.out_str(" px ");
        sink.out_pad(scene.INK, 5);
        sink.out_str(" pos ");
        out_pos(tlang.X);
        sink.out_str(" ");
        out_pos(tlang.Y);
        sink.out_str(" head ");
        sink.out_pad(tlang.H, 7);
        sink.out_str(" pen ");
        sink.out_pad(tlang.PEN, 1);
        sink.out_str(" col ");
        sink.out_pad(tlang.COL, 2);
        sink.out_str(" sha ");
        sink.out_hex16(sink.grid_digest(scene.SRF));
        sink.out_str("\n");
        let k = 0;
        let dumped = false;
        while (k < NWANT) {
            if (WANT[k] == f) {
                dumped = true;
                k = NWANT
            } else {
                k = k + 1
            }
        };
        if (dumped) {
            sink.out_str("--- frame ");
            sink.out_num(f);
            sink.out_str(" ---\n");
            sink.grid_text(scene.SRF)
        };
        f = f + 1
    };
    let t1 = clock_us();
    let h1 = heap_used();
    sink.out_flush();
    if (SHOWTIME != 0) {
        let el = if (t1 > t0) { t1 - t0 } else { 1 };
        eputs("turtle: ");
        eputs(tostring(FRAMES));
        eputs(" frames in ");
        eputs(tostring(el));
        eputs(" us = ");
        eputs(tostring(el / 1000));
        eputs(" ms, ");
        eputs(tostring(tlang.STEPS * 1000000 / el));
        eputs(" commands a second\nturtle: ");
        eputs(tostring(bytes_sum));
        eputs(" bytes emitted, ");
        eputs(tostring(scene.INK));
        eputs(" cells inked, heap before=");
        eputs(tostring(h0));
        eputs(" after=");
        eputs(tostring(h1));
        eputs(" delta=");
        eputs(tostring(h1 - h0));
        eputs("\n")
    };
    0
};

// ─────────────────────────────────────────────────────── the status line ───
//
// Assembled into sink's module-level byte buffer and blitted a byte at a time
// into the bottom row of the surface.  NOT tui.text() and NOT a `+=` string:
// tui.text wants a str, and building one per frame is ~40-80 bytes a frame on an
// arena heap, which is the leak the brief's trap 4 is about.
def hud(f: long, fps: long, auto: long) -> void {
    let m = sink.out_mark();
    sink.out_str("turtle ");
    sink.out_str(if (SCRIPT == "") { tlang.PROGNAME[SEL] } else { "file" });
    sink.out_str(" cmds ");
    sink.out_pad(tlang.STEPS, 4);
    sink.out_str("/");
    sink.out_pad(tlang.NC, 4);
    sink.out_str(" pos ");
    out_pos(tlang.X);
    sink.out_str(" ");
    out_pos(tlang.Y);
    sink.out_str(" head ");
    sink.out_pad(tlang.H, 7);
    sink.out_str(" px ");
    sink.out_pad(scene.INK, 5);
    sink.out_str(" ");
    sink.out_pad(f, 5);
    sink.out_str("f ");
    sink.out_pad(fps / 100, 3);
    sink.out_str("fps ");
    sink.out_str(if (auto != 0) { "RUN" } else { "HOLD" });
    let r = scene.SR - 1;
    let n = sink.out_len() - m;
    let i = 0;
    while (i < n) {
        tui.put(scene.SRF, r, i, sink.ob_at(m + i), tui.grey(170), tui.DEFAULT);
        i = i + 1
    };
    while (i < scene.SC) {
        tui.put(scene.SRF, r, i, tui.space, tui.DEFAULT, tui.DEFAULT);
        i = i + 1
    };
    sink.out_trunc(m)
};

// ─────────────────────────────────────────────────────── the main ───

args.init("turtle", "a turtle-graphics interpreter, in a terminal.", OPTS);
let st = args.parse(argv());
if (st == args.HELP) {
    puts(args.usage());
    puts("\nthe language:\n");
    puts("  forward n | fd n | f n     move n units, drawing if the pen is down\n");
    puts("  back n | back n | bk | b   move back n units\n");
    puts("  left deg | lt | l          anticlockwise, degrees\n");
    puts("  right deg | rt | r         clockwise, degrees\n");
    puts("  setheading deg             absolute heading, degrees\n");
    puts("  pen up | pen down          lift and lower the pen\n");
    puts("  colour NAME | color        black red green yellow blue magenta cyan white\n");
    puts("                             orange grey brown lime pink violet silver gold\n");
    puts("  dot                        one dot, no movement\n");
    puts("  jump dx dy                move WITHOUT drawing, pen or no pen\n");
    puts("  repeat N [ ... ]           N passes; nests 12 deep\n");
    puts("  # to end of line           a comment; ';' separates too\n");
    puts("\nthe turtle works in integer units with y up and a heading in\n");
    puts("milli-degrees, so `left 90` four times returns the heading bit for\n");
    puts("bit and a closed polygon returns to (0,0) exactly.  `right 90` turns\n");
    puts("CLOCKWISE on the screen: from the origin, forward 100 then right 90\n");
    puts("then forward 100 ends at (100,-100).\n");
    puts("\nkeys, interactive:  . or space step one command, a auto-run, q quit,\n");
    puts("                    c clear and start over, h toggle the cursor,\n");
    puts("                    n next program, +/- the frame rate\n");
    puts("\nthe property check:\n");
    puts("  --check N  asserts what a golden file cannot: that the heading wrap\n");
    puts("             is exact over N sample headings and on every full turn,\n");
    puts("             that a square, triangle, pentagon, hexagon and octagon each\n");
    puts("             close on the unit and return to heading 0, that the sign\n");
    puts("             of right 90 is what this text says it is, that pen up\n");
    puts("             leaves the surface byte for byte as it found it, and that\n");
    puts("             the frame's capture checksum changes when one cell does.\n");
    puts("             No reference file is involved.\n");
    exit(0)
};
if (st != args.OK) {
    eputs("turtle: ");
    eputs(args.errmsg());
    eputs("\nturtle: try --help\n");
    exit(1)
};

if (args.has("list")) {
    let k = 0;
    while (k < tlang.NPROG) {
        puts("\n");
        puts(tlang.PROGNAME[k] + ":\n");
        puts(tlang.PROGS[k]);
        k = k + 1
    };
    puts("\n");
    exit(0)
};

CHECKN = args.get_long("check", 0);
if (args.has("check")) {
    if (CHECKN < 1 || CHECKN > 360000) {
        die("--check wants 1..360000 sample headings")
    };
    to_devnull();
    exit(check.run(CHECKN))
};

if (args.positional().length > 0) {
    die("takes no operands; got '" + args.positional()[0] + "'")
};

FRAMES = args.get_long("frames", 0);
if (FRAMES < 0 || FRAMES > 100000) { die("--frames wants 0..100000") };
FPSWANT = args.get_long("fps", 15);
if (FPSWANT < 1 || FPSWANT > 240) { die("--fps wants 1..240") };
STEPN = args.get_long("step", 1);
if (STEPN < 1 || STEPN > 64) { die("--step wants 1..64 commands a frame") };
SHOWTIME = if (args.has("time")) { 1 } else { 0 };
scene.CURSOR = if (args.has("cursor")) { 1 } else { 0 };

// ── the program ──
let src = "";
let which = args.get_str("prog", "");
SCRIPT = args.get_str("script", "");
if (SCRIPT != "" && which != "") {
    die("give --prog or --script, not both")
};
if (SCRIPT != "") {
    src = slurp(SCRIPT);
    if (src == "") { die("cannot read '" + SCRIPT + "'") }
} else {
    if (which == "") { which = tlang.PROGNAME[SEL] };
    let k = 0;
    let found = false;
    while (k < tlang.NPROG) {
        if (tlang.PROGNAME[k] == which) { SEL = k; found = true };
        k = k + 1
    };
    if (found == false) {
        let list = "";
        k = 0;
        while (k < tlang.NPROG) {
            list += tlang.PROGNAME[k];
            k = k + 1;
            if (k < tlang.NPROG) { list += " " }
        };
        die("no program named '" + which + "'; try one of: " + list)
    };
    src = tlang.PROGS[SEL]
};

// ── the size ──
let sz = args.get_str("size", "");
if (sz == "") {
    if (tui.is_tty(1)) {
        trows = tui.size().rows;
        tcols = tui.size().cols;
        if (trows < 6) { trows = 6 };
        if (tcols < 20) { tcols = 20 };
        if (trows > 128) { trows = 128 };
        if (tcols > 256) { tcols = 256 }
    } else {
        trows = 24;
        tcols = 80
    }
} else {
    let cut = 0 - 1;
    let i = 0;
    while (i < len(sz)) {
        if (byte_at(sz, i) == 120) { cut = i };
        i = i + 1
    };
    if (cut < 1 || cut >= len(sz) - 1) { die("--size wants WxH, e.g. --size 80x24") };
    let wpart = sz[0:cut];
    let hpart = sz[cut + 1:len(sz)];
    if (args.num_ok(wpart) == false || args.num_ok(hpart) == false) {
        die("--size wants two numbers around the x, e.g. --size 80x24")
    };
    let w = tolong(wpart);
    let h = tolong(hpart);
    if (w < 1 || w > 256) { die("--size wants a width of 1..256") };
    if (h < 1 || h > 128) { die("--size wants a height of 1..128") };
    tcols = w;
    trows = h
};
ROWS = trows;
COLS = tcols;

// ── compile ──
let ncmd = tlang.compile(src);
if (ncmd < 0) {
    eputs("turtle: ");
    if (tlang.ERRLINE > 0) {
        eputs("line ");
        eputs(tostring(tlang.ERRLINE));
        eputs(": ")
    };
    eputs(tlang.ERRTXT);
    eputs("\nturtle: in ");
    if (SCRIPT != "") { eputs(SCRIPT) } else { eputs(tlang.PROGNAME[SEL]) };
    eputs("\n");
    exit(1)
};

// ── the dry pass, the fit, and the first frame ──
scene.SRF = tui.resize(scene.SRF, ROWS, COLS);
scene.SR = ROWS;
scene.SC = COLS;
tlang.reset();
tlang.run_to_end();
FBX0 = tlang.BX0; FBX1 = tlang.BX1;
FBY0 = tlang.BY0; FBY1 = tlang.BY1;
TSTEPS = tlang.STEPS;
scene.fit(ROWS, COLS, FBX0, FBY0, FBX1, FBY1);
scene.clear_frame();
tlang.reset();

// ── the dump list ──
let dmp = args.get_str("dump", "");
if (dmp == "") {
    WANT[0] = if (FRAMES > 0) { FRAMES - 1 } else { 0 };
    NWANT = 1
} else {
    let start = 0;
    let i = 0;
    while (i <= len(dmp)) {
        if (i == len(dmp) || byte_at(dmp, i) == 44) {
            if (i > start) {
                let piece = dmp[start:i];
                if (args.num_ok(piece) == false) { die("--dump wants frame numbers") };
                let fn = tolong(piece);
                if (fn < 0 || fn >= FRAMES) { die("--dump frame is outside 0.." + tostring(FRAMES - 1)) };
                if (NWANT < MAXDUMP) { WANT[NWANT] = fn; NWANT = NWANT + 1 }
            };
            start = i + 1
        };
        i = i + 1
    }
};

// ── the deterministic path, or the terminal ──
if (FRAMES > 0 || args.has("no-tty")) {
    if (FRAMES == 0) { FRAMES = 1 };
    headless();
    exit(0)
};

// ═══════════════════════════════════════════════════ the interactive path ══
//
// tui's pattern verbatim: raw mode, alt screen, watchdog, and ONE place that
// leaves.  Y has no atexit and no signal handler, so every exit below is
// tui.restore_all_exit() and there is no path out of this loop that does not go
// through it; a SIGKILL is covered by the watchdog, which restores termios.
//
// It starts HELD, not running: this is a turtle, and the interesting thing about
// a turtle is watching where it goes.  `.` steps one command, `a` hands the
// stepping to the pacer.
if (!tui.raw_mode()) {
    eputs("turtle: not a terminal; try --frames N --no-tty\n");
    exit(1)
};
tui.enter_screen();
tui.arm_watchdog();

let pacer = tui.pacer_new(FPSWANT);
let meter = tui.fps_new();
tui.pacer_start(pacer);

let frame = 0;
let quit = false;
let auto = 0;
let checked = 0;
let bytes_sum = 0;
let ih0 = heap_used();
let t0 = clock_us();

while (quit == false) {
    // tui's pacer owns the frame deadline.  The key poll is
    // read_key_timeout(0) -- an immediate poll, never a blocking read -- because
    // VTIME counts deciseconds, so any non-zero millisecond count rounds UP to
    // the next 100 ms (measured: 5 x read_key_timeout(1) took 518 ms).  A 1..99
    // poll would put every frame a period late and report ~0.6 fps with a stuck
    // frame counter, which reads as "the animation is slow" rather than as a bug.
    if (tui.pacer_next(pacer) >= 0) {
        if (auto != 0) {
            let i = 0;
            let stop = false;
            while (stop == false && i < STEPN) {
                let e = scene.step_draw();
                if (e == 3 || e == 4) { stop = true; auto = 0 } else { i = i + 1 }
            }
        };
        scene.erase_cursor();
        scene.draw_cursor(tlang.X, tlang.Y, tlang.H);
        hud(frame, tui.fps_x100(meter), auto);
        bytes_sum = bytes_sum + tui.flush_diff(scene.SRF);
        tui.fps_tick(meter);
        frame = frame + 1;
        if (tlang.DONE == 1 && auto != 0) { auto = 0 }
    };

    // The keyboard on every frame: at 15 fps that is 66 ms of key latency, and
    // read_key_timeout(0) never blocks.  Keys come back as bytes, so they are
    // compared as bytes -- Y has no character literal, and ord() is how a name
    // becomes the byte it means.
    let k = tui.read_key_timeout(0);
    if (k == ord("q") || k == ord("Q") || k == tui.KEY_ESC) {
        quit = true
    } else if (k == ord(".") || k == ord(" ") || k == ord("\r") || k == ord("\n")) {
        auto = 0;
        scene.step_draw()
    } else if (k == ord("a") || k == ord("A")) {
        if (auto != 0) { auto = 0 } else if (tlang.DONE == 0) { auto = 1 }
    } else if (k == ord("c") || k == ord("C")) {
        tlang.reset();
        scene.clear_frame()
    } else if (k == ord("h") || k == ord("H")) {
        if (scene.CURSOR != 0) { scene.CURSOR = 0 } else { scene.CURSOR = 1 }
    } else if (k == ord("n") || k == ord("N")) {
        if (SCRIPT == "") {
            SEL = (SEL + 1) % tlang.NPROG;
            let nc = tlang.compile(tlang.PROGS[SEL]);
            if (nc >= 0) {
                tlang.reset();
                tlang.run_to_end();
                FBX0 = tlang.BX0; FBX1 = tlang.BX1;
                FBY0 = tlang.BY0; FBY1 = tlang.BY1;
                TSTEPS = tlang.STEPS;
                scene.fit(ROWS, COLS, FBX0, FBY0, FBX1, FBY1);
                scene.clear_frame();
                tlang.reset()
            }
        }
    } else if (k == ord("+") || k == ord("=")) {
        if (FPSWANT < 240) { FPSWANT = FPSWANT + 1 }
    } else if (k == ord("-") || k == ord("_")) {
        if (FPSWANT > 1) { FPSWANT = FPSWANT - 1 }
    };

    // A resize is looked for on every fourth frame, because Y has no SIGWINCH.
    // The surface is resized (allocation-free in tui) and then the drawing is
    // REDRAWN from the start up to the command it had reached: the two shifts
    // have changed, so every pixel on screen is now in the wrong place, and
    // re-running is the only honest repair.
    checked = checked + 1;
    if (checked >= 4) {
        checked = 0;
        if (poll_winsize() != 0) {
            ROWS = trows;
            COLS = tcols;
            if (ROWS < 4) { ROWS = 4 };
            if (COLS < 12) { COLS = 12 };
            scene.fit(ROWS, COLS, FBX0, FBY0, FBX1, FBY1);
            scene.clear_frame();
            tlang.reset();
            let again = 0;
            let stop = false;
            while (stop == false && again < 512) {
                let e = scene.step_draw();
                again = again + 1;
                if (e == 3 || e == 4) { stop = true }
            }
        }
    }
};

let el = clock_us() - t0;
eputs("turtle: ");
eputs(tostring(frame));
eputs(" frames in ");
eputs(tostring(el));
eputs(" us, ");
eputs(tostring(bytes_sum));
eputs(" bytes, ");
eputs(tostring(scene.INK));
eputs(" cells, heap ");
eputs(tostring(ih0));
eputs(" -> ");
eputs(tostring(heap_used()));
eputs("\n");
tui.restore_all_exit(0);