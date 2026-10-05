// sandfall.y -- a falling-sand cellular automaton in the terminal.
//
// ===========================================================================
// WHAT IT IS
//
// A grid of cells holding sand, water, oil, fire, smoke and stone, stepped one
// generation at a time.  Three ways to run it:
//
//   ./sandfall                                    the live view (alt screen)
//   ./sandfall --no-tty --frames 40               headless, deterministic
//   ./sandfall --check                            the property check
//
// The default path is deterministic: the default scene is built from arithmetic,
// the seed defaults to 1, and the headless run prints no timing unless --stats
// asks for it.  Time and randomness live behind --fps, --stats and --seed.
//
// The physics -- the scan order, why there is a ghost border, and why the run
// is guaranteed to reach a fixed point -- is in grid.y's header.  The one
// sentence that matters here: **one generation is ONE scan, rows bottom to
// top, left to right within a row, updating the grid IN PLACE, with a stamp so
// that no grain moves twice.**  sandfall.y does not own any of that; it owns
// the flags, the two run modes, and the drawing.
//
// ===========================================================================
// THE TWO MODES
//
// The interactive path follows the pattern term.y's header insists on --
//
//     if (!term.raw_mode()) { ...exit 1... };
//     term.enter_screen();
//     term.arm_watchdog();
//     ... the loop, whose only exit is `running = false` ...
//     term.restore_all_exit(0);
//
// and the headless path never touches the terminal at all: no termios, no
// escape sequences, no watchdog.  That is what makes its stdout diffable, and
// it is why `--frames N --no-tty` is the invocation gate.conf names.
//
// There is no `break` in Y (ORCHESTRATOR.md 2.9), so every early exit is a
// guard flag with an explicit terminal assignment, and every "skip this" is a
// positive condition around the body.  The cell-update loop in grid.y is
// exactly the shape that wants both, and neither of them is optional there:
// see the comment above step().

import args;
import fb;
import grid;
import props;
import scene;
import term;
import time;

// The report's fixed bookkeeping.  Allocated once, at module scope, and never
// grown: the heap is an arena, so a per-generation `+=` into an array would
// allocate and every byte ever allocated counts against the cap.
const DUMP_CAP = 8;        // generations printed by --dump

const OPTS: [args.Opt] = [
    { long: "scene",    short: "s", kind: args.STR,  help: "basin | terrain | drip | firestorm | empty (default basin)" },
    { long: "size",     short: "z", kind: args.STR,  help: "grid as WxH, e.g. 80x24 (default: the terminal size)" },
    { long: "seed",     short: "",  kind: args.NUM,  help: "seed for --scene terrain (default 1) -- same seed, same grid" },
    { long: "frames",   short: "f", kind: args.NUM,  help: "run N generations headless, print a summary, exit 0" },
    { long: "no-tty",   short: "",  kind: args.BOOL, help: "never touch the terminal; print the final frame as text" },
    { long: "dump",     short: "",  kind: args.NUM,  help: "print the grid as text every N generations (at most 8 frames)" },
    { long: "fps",      short: "",  kind: args.NUM,  help: "live view frames per second (default 30, 0 = uncapped)" },
    { long: "color",    short: "c", kind: args.STR,  help: "mono | color (default mono)" },
    { long: "stats",    short: "S", kind: args.BOOL, help: "print elapsed time, rate and heap use on exit" },
    { long: "check",    short: "",  kind: args.BOOL, help: "run the property check and exit (no reference file involved)" }
];

// -- small string helpers, one line each -------------------------------------

// die(msg) -> long -- the message on stderr and the exit code, so a call site
// is one line and cannot forget one half of it: `exit(die("..."))`.
def die(msg: str) -> long {
    eputs("sandfall: " + msg + "\n");
    1
};

// -- --size ------------------------------------------------------------------

// The answer to a --size: ok, or the message to print before exiting 1.
type Size = { ok: bool, msg: str, w: long, h: long };

def all_digits(t: str) -> bool {
    let n = len(t);
    if (n == 0) { return false };
    let ok = true;
    let i = 0;
    while (i < n && ok) {
        let c = t[i];
        if (c < 48 || c > 57) { ok = false };
        i = i + 1
    };
    ok
};

// parse_size(spec) -> Size -- "120x40", "120x", "120" (square) and "120X40" all
// parse; anything else is a message.  The digits are checked BEFORE tonum(),
// because tonum is deliberately forgiving (it reads a prefix and ignores the
// rest) and would turn "--size 40x9z" into a 9-row grid with no complaint.
def parse_size(spec: str) -> Size {
    let bad: Size = { ok: false, msg: "", w: 0, h: 0 };
    if (len(spec) == 0) {
        bad.msg = "--size wants WxH, e.g. --size 80x24";
        return bad
    };
    let p = spec.index_of("x");
    if (p < 0) { p = spec.index_of("X") };
    let ws = "";
    let hs = "";
    if (p < 0) {
        ws = spec;
        hs = spec
    } else {
        ws = spec[0:p];
        hs = spec[p + 1:]
    };
    if (!all_digits(ws)) {
        bad.msg = "--size '" + spec + "': the width '" + ws + "' is not a number";
        return bad
    };
    if (len(hs) > 0 && !all_digits(hs)) {
        bad.msg = "--size '" + spec + "': the height '" + hs + "' is not a number";
        return bad
    };
    let w = tonum(ws);
    let h = w;
    if (len(hs) > 0) { h = tonum(hs) };
    if (w < 4 || h < 4) {
        bad.msg = "--size '" + spec + "': a grid must be at least 4x4 -- the ghost "
                + "border takes one cell on every side and a scene needs somewhere to fall";
        return bad
    };
    if (w > grid.MAXW || h > grid.MAXH) {
        bad.msg = "--size '" + spec + "': at most " + tostring(grid.MAXW) + "x"
                + tostring(grid.MAXH) + ", because the store is "
                + tostring(grid.CELLS) + " cells";
        return bad
    };
    let good: Size = { ok: true, msg: "", w: w, h: h };
    good
};

// The grid the program would use when --size was not given.  term.size() is
// right here -- it answers 24x80 when stdin is not a terminal, which is also
// the right answer for a headless run whose stdout went to a file -- and this
// is called ONCE at start-up, so the record it builds is one record.  The
// frame loop uses winsize() below instead: the same ioctl, no allocation.
def default_size() -> Size {
    let ws = term.size();
    let w = ws.cols - 2;            // the ghost border, one cell each side
    let h = ws.rows - 3;            // two rows of status, one for the frame
    if (w < 4) { w = 4 };
    if (h < 4) { h = 4 };
    parse_size(tostring(w) + "x" + tostring(h))
};

// ===========================================================================
// text output -- what goes into EXPECTED
// ===========================================================================

// store_row_text(y) -> str -- one STORE row of the grid as glyphs, border
// included, so what the report shows is exactly what the store holds.  It
// allocates: it builds a string, so it is a REPORT path (--dump and the final
// frame), never a frame path.  That is why the headless run is not per-frame
// allocation free -- and it does not need to be, because it runs at most
// DUMP_CAP + 1 times.
def store_row_text(y: long) -> str {
    let s = "";
    let x = 0;
    while (x < grid.GWa) {
        s += char(grid.glyph(grid.at(x, y)));
        x = x + 1
    };
    s
};

// char(cp) -> str -- one character from a codepoint.  Every glyph is ASCII
// (see grid.glyph), so this is a one-byte string and there is no UTF-8 route
// needed.  `chr()` would be the wrong call: it is byte-oriented and cannot make
// a non-ASCII glyph at all (ORCHESTRATOR.md 2.4).
def char(cp: long) -> str {
    if (cp == 32) { return " " };
    if (cp == 35) { return "#" };
    if (cp == 46) { return "." };
    if (cp == 61) { return "=" };
    if (cp == 64) { return "@" };
    if (cp == 111) { return "o" };
    if (cp == 126) { return "~" };
    "?"
};

// dump_gen(g) -- the whole grid as text, INCLUDING the ghost border, which is
// the visible one-cell frame of the picture.
def dump_gen(g: long) {
    puts("generation " + tostring(g) + ":\n");
    let y = 0;
    while (y < grid.GHa) {
        puts(store_row_text(y) + "\n");
        y = y + 1
    };
    puts("\n")
};

// field(name, value) -> str -- one aligned `name : value` line of the report.
def field(name: str, value: str) -> str {
    "  " + name.pad_right(13, " ") + ": " + value + "\n"
};

// counts_line() -> str -- `stone 240  sand 36  water 72  oil 28  fire 1  smoke 0`,
// built with `+=` on a string.  This is a report path: it runs once per report,
// not once per generation, so it is not the quadratic `+=` the brief warns
// about (that is `str +=` as the LAST statement of a braced block inside a
// loop -- here the `+=` is not the last statement of the while body).
def counts_line() -> str {
    let s = "";
    let m = 1;
    while (m < grid.NMAT) {
        s += grid.material_name(m) + " " + tostring(grid.CNT[m]) + "  ";
        m = m + 1
    };
    s
};

// ===========================================================================
// the live view
// ===========================================================================

// The status line is assembled into this, never into a fresh string: one
// fb.text per frame with an f-string and three concatenations measured ~2.4 KB
// a frame, and a program that looks fine for an hour then meets the 3.5 GiB
// cap.  Same discipline as term.y's ESC_BUF, one size up.
let SBUF: [byte; 256] = [0; 256];
let SN = 0;

def sb_reset() { SN = 0 };

def sb_byte(b: long) {
    if (SN < 256) { SBUF[SN] = b; SN = SN + 1 }
};

def sb_str(t: str) {
    let i = 0;
    while (i < len(t)) {
        sb_byte(t[i]);
        i = i + 1
    }
};

// sb_num(v) -- the decimal of v, appended to SBUF.
//
// The first version of this built the number as a string and then appended it:
//
//     let d = "";
//     while (u > 0) { d = char(48 + u % 10) + d; u = u / 10 };
//     sb_str(d);
//
// which is correct and costs one string allocation PER DIGIT -- `char(..) + d`
// is a fresh `str` every time.  The status line has about fifteen digits in it,
// so the live view leaked roughly 413 bytes a frame, which `--stats` reported
// as `growth 50432 bytes over 122 generations` and which nothing else in the
// folder would have found.  Digits are counted first and then emitted most
// significant first, straight into SBUF: no allocation, and O(d^2) on a number
// of at most ten digits, which is not a cost worth measuring.
def sb_num(v: long) {
    let u = v;
    if (u < 0) {
        sb_byte(45);                        // '-'
        u = 0 - u
    };
    let n = 1;
    let t = u / 10;
    while (t > 0) {
        n = n + 1;
        t = t / 10
    };
    let i = n;
    while (i > 0) {
        i = i - 1;
        let p = 1;
        let q = i;
        while (q > 0) {
            p = p * 10;
            q = q - 1
        };
        sb_byte(48 + (u / p) % 10)
    }
};

// sb_hundredths(x100) -- a fixed-point reading as "12.34": the integer part, a
// dot, and two digits.
def sb_hundredths(x100: long) {
    sb_num(x100 / 100);
    sb_byte(46);
    let r = x100 % 100;
    if (r < 10) { sb_byte(48) };
    sb_num(r)
};

// winsize() -> long -- the terminal size packed as rows * 1000 + cols, from the
// same TIOCGWINSZ ioctl term.size() uses but into THIS module's buffer, so a
// per-frame resize poll allocates nothing.  term.size() returns a fresh record
// (~40 bytes) per call, which in a frame loop is 40 bytes a frame for ever.
// The syscall is 16 (ioctl) with the kernel register order -- fd, request,
// argument; the request is 0x5413 and the result is four 16-bit little-endian
// values, rows first (ORCHESTRATOR.md 2.1 and 2.3).
let WSB: [byte; 8] = [0; 8];

def ws16(at: long) -> long {
    WSB[at] + 256 * WSB[at + 1]
};

def winsize() -> long {
    let r = 0;
    let c = 0;
    if (syscall(16, 1, 0x5413, &WSB[0]) >= 0) {
        r = ws16(0);
        c = ws16(2)
    };
    if (r < 1) { r = 24 };
    if (c < 1) { c = 80 };
    if (r > 1000) { r = 1000 };
    if (c > 1000) { c = 1000 };
    r * 1000 + c
};

// colour(m, mode) -> long -- the fb colour per material.  mode 0 is a grey ramp
// so the materials still read apart on a terminal without truecolour; mode 1 is
// the real palette.  A chain of returns rather than a [long; 7] table: a table
// literal read with a computed index is fine, but this keeps the ramp beside
// the names, and it costs six comparisons in a drawing path that does tens of
// thousands of cells.
def colour(m: long, mode: long) -> long {
    if (mode == 0) {
        if (m == grid.M_STONE) { return fb.grey(140) };
        if (m == grid.M_SAND) { return fb.grey(205) };
        if (m == grid.M_WATER) { return fb.grey(95) };
        if (m == grid.M_OIL) { return fb.grey(70) };
        if (m == grid.M_FIRE) { return fb.grey(255) };
        if (m == grid.M_SMOKE) { return fb.grey(160) };
        return fb.grey(18)
    };
    if (m == grid.M_STONE) { return fb.rgb(132, 132, 140) };
    if (m == grid.M_SAND) { return fb.rgb(216, 180, 98) };
    if (m == grid.M_WATER) { return fb.rgb(64, 128, 232) };
    if (m == grid.M_OIL) { return fb.rgb(156, 116, 44) };
    if (m == grid.M_FIRE) { return fb.rgb(255, 132, 32) };
    if (m == grid.M_SMOKE) { return fb.rgb(178, 178, 186) };
    fb.rgb(14, 14, 22)
};

// draw(surf, bg, mode) -- the grid into an fb surface, cell by cell.  The
// surface already holds the last frame, so flush_diff() redraws only what
// changed -- which for a settled automaton is almost nothing.
def draw(surf: fb.Surface, bg: long, mode: long) {
    let y = 0;
    while (y < grid.GHa) {
        let x = 0;
        while (x < grid.GWa) {
            let m = grid.at(x, y);
            fb.put(surf, y, x, grid.glyph(m), colour(m, mode), bg);
            x = x + 1
        };
        y = y + 1
    }
};

// status(surf, row, cols, cscene, mode, fps100, running) -- the status line,
// cell by cell out of SBUF.  One fb.put per cell and no allocation at all.
def status(surf: fb.Surface, row: long, cols: long, cscene: str, mode: long, fps100: long, running: bool) {
    sb_reset();
    sb_str("gen ");
    sb_num(grid.GEN);
    sb_str(" moved ");
    sb_num(grid.MOVES);
    sb_str(" sand ");
    sb_num(grid.CNT[grid.M_SAND]);
    sb_str(" water ");
    sb_num(grid.CNT[grid.M_WATER]);
    sb_str(" oil ");
    sb_num(grid.CNT[grid.M_OIL]);
    sb_str(" fire ");
    sb_num(grid.CNT[grid.M_FIRE]);
    sb_str(" | ");
    if (running) { sb_str("run") } else { sb_str("PAUSE") };
    sb_str(" | ");
    if (mode == 0) { sb_str("mono") } else { sb_str("color") };
    sb_str(" | ");
    sb_hundredths(fps100);
    sb_str(" fps | ");
    sb_str(cscene);
    sb_str(" seed ");
    sb_num(grid.SEEDV);
    sb_str(" | h keys");
    let i = 0;
    while (i < SN && i < cols) {
        fb.put(surf, row, i, SBUF[i], fb.grey(200), fb.grey(12));
        i = i + 1
    };
    // pad the rest of the line, so a shorter line next frame cannot leave stale
    // text behind it
    while (i < cols) {
        fb.put(surf, row, i, 32, fb.grey(200), fb.grey(12));
        i = i + 1
    }
};

let HELP: [str] = [
    "sandfall -- keys",
    "",
    "  q  Esc  Ctrl-C   quit",
    "  space             pause / resume",
    "  .                 one generation, even while paused",
    "  n                 next scene",
    "  r                 reseed (seed + 1)",
    "  c                 cycle mono / color",
    "  + / -             faster / slower",
    "  h                 this list",
    "",
    "one generation is one scan: rows bottom to top, left to",
    "right within a row, the grid updated in place, and no",
    "grain moves twice.  so sand falls exactly one row per",
    "generation and two waters merge over two, not one."
];

// run_live(...) -- the interactive path.  Every exit routes through the single
// restore_all_exit at the bottom, and so does the error path above it.
def run_live(sz: Size, cscene: str, seed: long, fps: long, mode: long, stats: bool) -> long {
    if (!term.raw_mode()) {
        exit(die("not a terminal; try --frames N --no-tty"))
    };
    term.enter_screen();
    term.arm_watchdog();

    let surf = fb.new(24, 80);
    let bg = fb.rgb(8, 8, 14);
    let pacer = time.pacer_new(fps);
    time.pacer_start(pacer);
    let meter = time.fps_new();
    let running = true;
    let showing_help = false;
    let gen_at_start = grid.GEN;
    let t0 = time.now_us();
    let h0 = heap_used();
    let worst = 0;

    // The frame loop.  `running` is the guard flag that stands in for `break`;
    // the key handling is one chain of tests with no early exit of its own, and
    // the "skip this cell" cases are positive conditions rather than a
    // `continue`.  read_key_timeout(0) -- a 1..99 ms poll spends its wait in
    // VTIME, which counts DECISECONDS, so it rounds up to the next 100 ms and
    // the loop lands a whole period late every frame and reports ~0.6 fps with
    // a stuck generation counter.  The pacer owns the deadline instead.
    while (running) {
        let k = term.read_key_timeout(0);
        if (k >= 0) {
            let quit = false;
            if (k == ord("q") || k == term.KEY_ESC || k == 3) { quit = true };
            if (k == ord(" ")) { running = !running };
            if (k == ord(".")) { grid.step() };
            if (k == ord("h")) { showing_help = !showing_help };
            if (k == ord("c")) { mode = 1 - mode };
            if (k == ord("+")) {
                fps = fps + 5;
                if (fps > 240) { fps = 240 }
            };
            if (k == ord("-")) {
                fps = fps - 5;
                if (fps < 0) { fps = 0 }
            };
            if (k == ord("n")) { cscene = scene.next_scene(cscene) };
            if (k == ord("r")) {
                seed = seed + 1;
                let why = scene.build(cscene, sz.w, sz.h, seed);
                if (len(why) > 0) {
                    term.leave_screen();
                    term.restore_exit(die(why))
                }
            };
            if (quit) { running = false }
        };

        let packed = winsize();
        let rows = packed / 1000;
        let cols = packed - rows * 1000;
        if (rows < 8) { rows = 8 };
        if (cols < 12) { cols = 12 };
        // Rebuild the grid only when it no longer fits the window, so a resize
        // poll that returns the same size every frame costs nothing and
        // allocates nothing.  fb.resize is called only when the size changed.
        if (cols - 2 != sz.w || rows - 3 != sz.h) {
            let ns = parse_size(tostring(cols - 2) + "x" + tostring(rows - 3));
            if (!ns.ok) {
                term.leave_screen();
                term.restore_exit(die(ns.msg))
            };
            sz = ns;
            let why = scene.build(cscene, sz.w, sz.h, seed);
            if (len(why) > 0) {
                term.leave_screen();
                term.restore_exit(die(why))
            };
            surf = fb.resize(surf, rows, cols)
        };

        // The deadline: pace first, then draw.  Dropping a frame is better than
        // accumulating lag, and time.y already does that.
        time.pacer_next(pacer);
        let dropped = time.pacer_dropped(pacer);
        if (dropped > worst) { worst = dropped };
        if (running) { grid.step() };
        grid.tally();
        fb.begin_frame();
        if (showing_help) {
            fb.clear(surf, bg);
            let r = 1;
            while (r <= len(HELP) && r < rows - 1) {
                let i = 0;
                while (i < len(HELP[r - 1]) && i < cols) {
                    fb.put(surf, r, i, HELP[r - 1][i], fb.grey(210), bg);
                    i = i + 1
                };
                r = r + 1
            }
        } else {
            draw(surf, bg, mode);
            status(surf, rows - 1, cols, cscene, mode, time.fps_avg_x100(meter), running)
        };
        fb.flush_diff(surf);
        fb.end_frame(surf);
        time.fps_tick(meter)
    };

    let h1 = heap_used();
    let el = time.now_us() - t0;
    let frames = grid.GEN - gen_at_start;
    if (stats) {
        eputs("sandfall: " + tostring(el / 1000) + " ms, " + tostring(frames)
            + " generations, " + tostring(time.fps_avg_x100(meter) / 100)
            + " fps, " + tostring(worst) + " frames dropped by the pacer\n");
        eputs("sandfall: heap " + tostring(h0) + " -> " + tostring(h1)
            + ", growth " + tostring(h1 - h0) + " bytes over "
            + tostring(frames) + " generations\n")
    };
    term.restore_all_exit(0);
    0
};

// ===========================================================================
// the headless path
// ===========================================================================

// run_headless(...) -- exactly `frames` generations: no clock, no terminal, no
// randomness beyond --seed.  Prints a table and the final frame, exits 0.
// This is the invocation gate.conf names and its stdout is EXPECTED.
def run_headless(sz: Size, cscene: str, frames: long, dump_every: long, stats: bool) {
    grid.tally();
    puts("sandfall -- falling sand, in place, one scan a generation\n\n");
    puts(field("scene", cscene));
    puts(field("grid", tostring(grid.IW) + " x " + tostring(grid.IH)
                + ", plus a one-cell ghost border of stone on every side"));
    puts(field("store", tostring(grid.GWa) + " x " + tostring(grid.GHa)
                + " = " + tostring(grid.CELLS) + " cells, fixed at compile time"));
    puts(field("scan order", "rows bottom to top, left to right, in place, "
                + "at most one move per grain"));
    puts(field("seed", tostring(grid.SEEDV)));
    puts(field("frames", tostring(frames)));
    puts(field("initial", counts_line()));
    puts("\n");

    if (dump_every > 0 && frames > 0) { dump_gen(0) };

    // The run loop.  heap_used() is read either side of it and --stats prints
    // the delta, which is the number that would catch a literal in the loop
    // body (64 bytes an iteration, and the heap is an arena).
    let h0 = heap_used();
    let t0 = time.now_us();
    let next_dump = dump_every;
    let dumped = 0;
    let settled_at = 0;
    let k = 0;
    while (k < frames) {
        grid.step();
        if (grid.CHANGED == 1) { settled_at = grid.GEN };
        if (dump_every > 0 && grid.GEN >= next_dump && dumped < DUMP_CAP) {
            dump_gen(grid.GEN);
            dumped = dumped + 1;
            next_dump = next_dump + dump_every
        };
        k = k + 1
    };
    let el = time.now_us() - t0;
    let h1 = heap_used();
    grid.tally();

    puts(field("generations", tostring(grid.GEN)));
    let last_change = "the last generation";
    if (settled_at == 0) { last_change = "the last generation (nothing settled yet)" };
    if (settled_at > 0 && settled_at < grid.GEN) {
        last_change = "generation " + tostring(settled_at)
    };
    puts(field("last change", last_change));
    puts(field("final", counts_line()));
    puts(field("moved last", tostring(grid.MOVES)));
    puts(field("empty cells", tostring(grid.EMPTY_N)));
    puts(field("ghost border", tostring(grid.BORDER_STONE) + " stone cells, which is "
                + "the whole border (" + tostring(2 * grid.GWa + 2 * (grid.GHa - 2)) + ")"));
    puts(field("matter", tostring(grid.MATTER) + " of " + tostring(grid.IW * grid.IH)
                + " cells"));
    if (stats) {
        // tenths of a microsecond per generation.  el/frames is microseconds
        // already, but at 6 us a generation the tenths are all that carry any
        // information -- a millisecond field read "0.0 ms" for every grid here.
        let tenths = 0;
        if (frames > 0) { tenths = (el * 10) / frames };
        puts(field("elapsed", tostring(el / 1000) + " ms"));
        puts(field("per generation", tostring(tenths / 10) + "." + tostring(tenths % 10)
                    + " us, " + tostring((frames * 1000000) / (el + 1)) + " gen/s"));
        puts(field("heap", tostring(h0) + " -> " + tostring(h1) + ", growth "
                    + tostring(h1 - h0) + " bytes over " + tostring(frames)
                    + " generations"));
        // Is the final frame a fixed point?  run_until_settled answers with the
        // first generation from HERE that changes nothing, so a grid that had
        // already settled answers with GEN + 1 and a grid still moving answers
        // with a large number.  Both are reported, because "the run stopped"
        // and "the run reached a fixed point" are different claims.
        let before = grid.GEN;
        let q = grid.run_until_settled(20000);
        let fixed = "no -- still moving after 20000 more generations";
        if (q == before + 1) {
            fixed = "yes -- the final frame is already a fixed point"
        } else if (q > 0) {
            fixed = "after " + tostring(q - before) + " more generations"
        };
        puts(field("fixed point", fixed));
        puts(field("checksum", tostring(grid.checksum())))
    };
    puts("\n");
    puts("final frame (the ghost border is the one-cell frame around it):\n");
    let y = 0;
    while (y < grid.GHa) {
        puts(store_row_text(y) + "\n");
        y = y + 1
    }
};

// ===========================================================================
// main
// ===========================================================================

def main() -> long {
    args.init("sandfall", "a falling-sand cellular automaton in the terminal", OPTS);

    // args.y's own convention is exit 2 for a usage error; this program's
    // contract is 1 for every diagnostic it raises, and it is a one-line
    // difference.  The message is already on stderr.
    let st = args.parse(argv());
    if (st == args.HELP) {
        puts(args.usage());
        return 0
    };
    if (st == args.USAGE) { return 1; };

    let operands = args.positional();
    if (len(operands) > 0) {
        return die("unexpected operand '" + operands[0]
                   + "'; everything is an option -- try --help")
    };

    let mode_name = args.get_str("color", "mono");
    if (mode_name != "mono" && mode_name != "color") {
        return die("--color must be mono or color (got '" + mode_name + "')")
    };
    let mode = 0;
    if (mode_name == "color") { mode = 1 };

    if (args.has("check")) { return props.check_all() };

    // --size, and the checks that make every later index safe
    let szarg = args.get_str("size", "");
    let sz: Size = if (len(szarg) > 0) { parse_size(szarg) } else { default_size() };
    if (!sz.ok) { return die(sz.msg) };

    let cscene = args.get_str("scene", scene.DEFAULT_SCENE);
    let seed = args.get_long("seed", 1);
    let frames = args.get_long("frames", 0);
    let dump_every = args.get_long("dump", 0);
    let fps = args.get_long("fps", 30);
    let stats = args.has("stats");
    if (seed < 0 || seed > 1000000) {
        return die("--seed " + tostring(seed) + ": must be between 0 and 1000000")
    };
    if (frames < 0 || frames > 10000000) {
        return die("--frames " + tostring(frames) + ": must be between 0 and 10000000")
    };
    if (dump_every < 0 || dump_every > 10000000) {
        return die("--dump " + tostring(dump_every) + ": must be between 0 and 10000000")
    };
    if (fps < 0 || fps > 1000) {
        return die("--fps " + tostring(fps) + ": must be between 0 and 1000")
    };

    let why = scene.build(cscene, sz.w, sz.h, seed);
    if (len(why) > 0) { return die(why) };

    if (!args.has("no-tty") && frames == 0) {
        if (!term.is_tty(0)) {
            return die("not a terminal; try --frames N --no-tty")
        };
        return run_live(sz, cscene, seed, fps, mode, stats)
    };

    run_headless(sz, cscene, frames, dump_every, stats);
    0
};

exit(main())