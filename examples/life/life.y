// life.y -- Conway's Game of Life in the terminal: a live view and a
// headless summary.
//
// ===========================================================================
// WHAT IT IS
//
// Conway's 1970 automaton on a torus-wrapped grid.  A live cell with 2 or 3
// live neighbours survives, a dead cell with exactly 3 is born, everything
// else is dead in the next generation.  Two ways to run it:
//
//   ./life                                   the live view: alt screen, 30 fps
//   ./life --frames 200 --pattern gosper     headless: a summary, exit 0
//
// The default path is deterministic: the default pattern is a glider, there is
// no unseeded randomness anywhere, and the headless run prints no timings
// unless --stats says so.  Time and randomness live behind --fps, --stats and
// --seed.
//
// ===========================================================================
// THE TWO MODES
//
// The interactive path follows the pattern tui's header insists on --
// raw mode, alt screen, the crash watchdog, and ONE restore_all_exit at the
// bottom that every early exit routes through:
//
//     if (!tui.raw_mode()) { ...exit 1... };
//     tui.enter_screen();
//     tui.arm_watchdog();      // covers SIGKILL and crashes
//     ... the loop, whose only exit is `running = false` ...
//     tui.restore_all_exit(0);
//
// The headless path never touches the terminal at all: no termios, no escape
// sequences, no watchdog.  That is what makes its stdout diffable, and it is
// why `--frames` is the flag to reach for in a test.
//
// ===========================================================================
// KEYS (interactive)
//
//   q  Esc  Ctrl-C   quit -- restore_all_exit(0), always
//   space             pause / resume
//   .                 one generation, even while paused
//   n                 next built-in pattern
//   r                 reseed the random pattern with seed+1
//   c                 cycle mono / gray / green
//   h                 the key list
//   + / -             faster / slower (the fps cap; 0 is as fast as it goes)
//
// There is no `break` in Y, so every one of these is an arm of one `else if`
// chain over one long, and the loop's own exit is a guard flag tested in the
// `while` -- see run_live().

import args;
import sim;
import rle;
import tui;

// The report's fixed-size bookkeeping.  Both are allocated once, before the
// run loop, and neither grows: a per-generation `+=` into an array would
// allocate (the arena never frees), so the generations are counted into fixed
// tables instead.  A population above HIST_CAP goes in the last bucket, and a
// run longer than TRACE_CAP generations is only traced for its first
// TRACE_CAP of them -- both are said out loud in the output, never silently.
const HIST_CAP = 4096;      // buckets 0..4095 are exact; 4096 means "4096+"
const TRACE_CAP = 4096;     // generations kept in the population trace

const OPTS: [args.Opt] = [
    { long: "pattern",  short: "p", kind: args.STR,  help: "glider | gosper | lwss | blinker | block | random | empty (default glider)" },
    { long: "size",     short: "z", kind: args.STR,  help: "grid as WxH, e.g. 120x40 (default: the terminal size)" },
    { long: "seed",     short: "s", kind: args.NUM,  help: "seed for --pattern random (default 1) -- same seed, same grid" },
    { long: "density",  short: "d", kind: args.NUM,  help: "percent of cells alive in a random pattern (default 30)" },
    { long: "rle",      short: "r", kind: args.STR,  help: "pattern as an RLE string, e.g. --rle 'bo$2bo$3o!' (overrides --pattern)" },
    { long: "frames",   short: "f", kind: args.NUM,  help: "run N generations headless, print a summary, exit 0" },
    { long: "dump",     short: "",   kind: args.NUM,  help: "print the grid as text every N generations (0 = never)" },
    { long: "fps",      short: "",   kind: args.NUM,  help: "live view frames per second (default 30, 0 = uncapped)" },
    { long: "color",    short: "c", kind: args.STR,  help: "mono | gray | green (default mono)" },
    { long: "stats",    short: "S", kind: args.BOOL, help: "print elapsed time, rate and heap use on exit" }
];

// -- --size ------------------------------------------------------------------

// The answer to a --size: ok, or the message to print before exiting 1.
type Size = { ok: bool, msg: str, w: long, h: long };

def all_digits(t: str) -> bool {
    let n = len(t);
    if (n == 0) { return false; };
    let ok = true;
    let i = 0;
    while (i < n && ok) {
        let c = t[i];
        if (c < 48 || c > 57) { ok = false; };
        i = i + 1
    };
    ok
};

// parse_size(spec) -> Size -- "120x40", "120x", "120" (square) and "120X40"
// all parse; anything else is a message.  The digits are checked before
// tolong(), because tolong is deliberately forgiving (it reads a prefix and
// ignores the rest) and would turn "--size 40x9z" into a 9-row grid with no
// complaint at all.
def parse_size(spec: str) -> Size {
    let bad: Size = { ok: false, msg: "", w: 0, h: 0 };
    if (len(spec) == 0) {
        bad.msg = "--size wants WxH, e.g. --size 120x40";
        return bad
    };
    let p = spec.index_of("x");
    if (p < 0) { p = spec.index_of("X"); };
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
    let w = tolong(ws)!;
    let h = w;
    if (len(hs) > 0) { h = tolong(hs)!; };
    if (w < 2 || h < 2) {
        bad.msg = "--size '" + spec + "': a grid must be at least 2x2 (a 1x1 torus "
                + "makes every neighbour the cell itself)";
        return bad
    };
    if (w > sim.MAXW || h > sim.MAXH) {
        bad.msg = "--size '" + spec + "': at most " + tostring(sim.MAXW) + "x"
                + tostring(sim.MAXH) + ", because the grid store is "
                + tostring(sim.MAXCELLS) + " cells";
        return bad
    };
    if (w * h > sim.MAXCELLS) {
        bad.msg = "--size '" + spec + "': " + tostring(w * h) + " cells is more than the "
                + tostring(sim.MAXCELLS) + "-cell store";
        return bad
    };
    let ok: Size = { ok: true, msg: "", w: w, h: h };
    ok
};

// -- reporting helpers -------------------------------------------------------

// die(msg) -> long -- the message on stderr and the exit code, so a call site
// is one line and cannot forget one half of it: `exit(die("..."))`.
def die(msg: str) -> long {
    eputs("life: " + msg + "\n");
    1
};

// The grid the program would use when --size was not given.  tui.size() is
// right here -- it answers 24x80 when stdin is not a terminal, which is also
// the right answer for a headless run whose stdout went to a file -- and this
// is called ONCE at start-up, so the record it builds is one record.  The
// frame loop uses winsize() below instead, which is the same ioctl without the
// allocation.
def default_size() -> Size {
    let ws = tui.size();
    let w = ws.cols;
    let h = ws.rows - 1;          // one row of the terminal for the status line
    if (w < 2) { w = 2; };
    if (h < 2) { h = 2; };
    let s = parse_size(tostring(w) + "x" + tostring(h));
    s
};

// -- filling the grid --------------------------------------------------------

// The description of what is on the grid, for the report: a pattern name, an
// RLE header, or "random (seed N, P% alive)".
type Filled = { ok: bool, msg: str, name: str, what: str, count: long, seed: long };

// fill(s, pat_arg, rle_text, seed, density) -> Filled -- put the requested
// pattern on a cleared grid.  Exactly one source is used, in this order:
// --rle (with a note on stderr when it also overrides --pattern), then
// --pattern random, then a built-in name.  Every failure is a message, never a
// trap: a pattern that does not fit, a name that does not exist, an RLE string
// that does not parse, and a cell outside the grid are all diagnosed here.
def fill(s: sim.Sim, pat_arg: str, rle_text: str, seed: long, density: long) -> Filled {
    let no: Filled = { ok: false, msg: "", name: "", what: "", count: 0, seed: seed };
    sim.clear(s);

    if (len(rle_text) > 0) {
        if (len(pat_arg) > 0) {
            eputs("life: --rle overrides --pattern " + pat_arg + "\n")
        };
        let r: rle.Rle = rle.parse(rle_text);
        if (!r.ok) {
            no.msg = "--rle: " + r.msg;
            return no
        };
        // Every cell is bounds-checked before it is written, so a pattern that
        // does not fit is a message naming the cell, not an index-out-of-bounds
        // trap printed on stdout.
        let cells = r.cells;
        let i = 0;
        let bad = "";
        while (i < len(cells) && len(bad) == 0) {
            let c = cells[i];
            if (!sim.place_cell(s, c.x, c.y)) {
                bad = "a live cell at (" + tostring(c.x) + ", " + tostring(c.y)
                    + ") is outside the " + tostring(s.w) + "x" + tostring(s.h) + " grid";
            };
            i = i + 1
        };
        if (len(bad) > 0) {
            no.msg = "--rle: " + bad;
            return no
        };
        sim.count(s);
        let good: Filled = {
            ok: true, msg: "", name: "rle", count: s.pop, seed: seed,
            what: "RLE, " + tostring(len(cells)) + " live cells, header " + rle.extent(r)
        };
        return good
    };

    // No --pattern at all means the glider: the default path must not depend on
    // a clock or on a generator nobody seeded.
    let pat = pat_arg;
    if (len(pat) == 0) { pat = "glider"; };

    if (pat == "random") {
        let n = sim.random_fill(s, seed, density);
        sim.count(s);
        let good: Filled = {
            ok: true, msg: "", name: "random", count: n, seed: seed,
            what: "random, seed " + tostring(seed) + ", " + tostring(density) + "% alive"
        };
        return good
    };

    let bm = sim.by_name(pat);
    if (len(bm) == 0 && pat != "empty") {
        no.msg = "unknown pattern '" + pat + "'; expected " + sim.names();
        return no
    };
    if (!sim.place(s, bm)) {
        // The pattern is on hand as a bitmap, so its size is knowable here.
        let rows = bm.split("/");
        let pw = 0;
        foreach (r in rows) { if (len(r) > pw) { pw = len(r); } };
        no.msg = "pattern '" + pat + "' is " + tostring(pw) + "x" + tostring(len(rows))
               + " and does not fit in a " + tostring(s.w) + "x" + tostring(s.h)
               + " grid; use --size or --rle";
        return no
    };
    let good: Filled = { ok: true, msg: "", name: pat, what: pat, count: s.pop, seed: seed };
    good
};

// -- the headless report -----------------------------------------------------

// dump_gen(s, g) -- the grid as text, at column 0 so the output can be
// diffed, and so `golden/*.txt` is a plain sequence of grids.
def dump_gen(s: sim.Sim, g: long) {
    puts("generation " + tostring(g) + ":\n");
    let rows = sim.text(s);
    foreach (r in rows) { puts(r + "\n") };
    puts("\n")
};

// field(name, value) -- one aligned `name : value` line of the report, and
// the line itself, so a caller can start a block with it.  The value column
// is 19 characters in; bucket_line() indents to the same place.
def field(name: str, value: str) -> str {
    "  " + name.pad_right(15, " ") + ": " + value + "\n"
};

// populations(trace, n) -> str -- the population of each generation, joined.
// Short runs print in full; a long one prints its head and tail with an
// ellipsis, because 100 000 numbers is not a summary.  Two loops in two
// branches, since there is no `break` to stop after eight.
//
// The parameter is the FIXED array type, not `[long]`: a `[T; N]` is not a
// `[T]` in Y, so a growable-typed parameter will not take a fixed argument.
def populations(trace: [long; 4096], n: long) -> str {
    let out = "";
    if (n <= 64) {
        for i in 0..n { out += tostring(trace[i]) + " "; };
        out += "(" + tostring(n) + " generations, 0 to " + tostring(n - 1) + ")";
    } else {
        for i in 0..8 { out += tostring(trace[i]) + " "; };
        out += "... ";
        for i in n - 8..n { out += tostring(trace[i]) + " "; };
        out += "(" + tostring(n) + " generations, first 8 and last 8)";
    };
    out
};

// histogram(hist, n) -> str -- the buckets that were hit, low population
// first, as "population -> generations at that count".  More than 40 buckets
// and the middle is elided with a count, so the line stays a summary.
def histogram(hist: [long; 4097], n: long) -> str {
    let used = 0;
    for i in 0..HIST_CAP + 1 {
        if (hist[i] > 0) { used = used + 1; }
    };
    let out = field("histogram", "(live cells -> generations at that count)");
    if (used == 0) {
        out += "  (no generations)";
    } else if (used <= 40) {
        for i in 0..HIST_CAP + 1 {
            if (hist[i] > 0) { out += bucket_line(i, hist[i]) + "\n"; }
        }
    } else {
        // More than 40 buckets: the first 20 and the last 20, and a count of
        // what is in between.  Three counted passes over a fixed 4097-entry
        // table would be wasteful, so it is one pass with a counter that
        // prints, then skips, then prints again -- which is the two-loops-and-
        // no-`break` shape a gosper gun's histogram needs.
        let first = 0;
        let skip = used - 40;
        for i in 0..HIST_CAP + 1 {
            if (hist[i] > 0) {
                if (first < 20) {
                    out += bucket_line(i, hist[i]) + "\n";
                    first = first + 1
                } else if (skip > 0) {
                    skip = skip - 1
                } else {
                    out += bucket_line(i, hist[i]) + "\n"
                }
            }
        };
        out += "                   ... " + tostring(used - 40) + " buckets in between not shown\n"
    };
    out
};

// One bucket, indented to the value column that field() uses, so the numbers
// line up under one another however wide the population is.
def bucket_line(pop: long, gens: long) -> str {
    let label = tostring(pop);
    if (pop == HIST_CAP) { label = tostring(pop) + "+"; };
    "                   " + label.pad_right(7, " ") + "live cells -> "
        + tostring(gens).pad_right(8, " ") + " generations"
};

// stats_block(wall_us, gen, h0, h1, shown) -- the non-deterministic report,
// behind --stats only, so EXPECTED can be compared byte for byte.
//
// h0 is heap_used() before the generations ran and h1 right after they
// finished, which is the pair that says whether the run leaked: everything
// this program builds afterwards (the population trace line, the histogram) is
// a string, so measuring only at the end would blame the report for the loop.
def stats_block(wall_us: long, gen: long, h0: long, h1: long, shown: long) {
    let h2 = heap_used();
    puts(field("elapsed", f"{wall_us / 1000000.0:.3f} s"));
    if (wall_us > 0) {
        // generations / second = gen * 1e6 / microseconds
        puts(field("rate", f"{gen * 1000000.0 / wall_us:.0f} generations/second"))
    } else {
        puts(field("rate", "not measured (no wall clock)"))
    };
    puts(field("heap before", tostring(h0) + " bytes"));
    puts(field("heap after", tostring(h1) + " bytes"));
    puts(field("heap growth", tostring(h1 - h0) + " bytes over " + tostring(gen) + " generations"));
    puts(field("heap with report", tostring(h2) + " bytes (the report itself allocates)"));
    puts(field("grid store", tostring(4 * sim.MAXCELLS * 8 + 4 * 512 * 8)
               + " bytes, allocated once in sim.new()"));
    puts(field("traced", tostring(shown) + " of " + tostring(gen + 1)
               + " generations (TRACE_CAP is " + tostring(TRACE_CAP) + ")"))
};

// run_headless(...) -> long -- the --frames path.  Exactly `frames`
// generations, then a summary, then exit 0.  Nothing here touches the
// terminal and nothing here allocates after the two tables below.
def run_headless(s: sim.Sim, frames: long, dump: long, f: Filled, want_stats: bool) -> long {
    let trace: [long; 4096] = [0; 4096];
    let hist: [long; 4097] = [0; 4097];
    puts("life -- Conway's Game of Life, rule B3/S23, torus edges\n\n");
    let w0 = 0;
    if (want_stats) { w0 = clock_us(); };

    puts(field("pattern", f.what));
    puts(field("grid", tostring(s.w) + " x " + tostring(s.h) + " (torus)"));
    puts(field("frames", tostring(frames)));
    puts(field("seed", tostring(f.seed)));
    puts("\n");

    // Measured AFTER the header, so the only thing between the two readings is
    // the generation loop.  (The header builds strings and the arena counts
    // those: taking this reading before the header reported a "leak" of 2544
    // bytes that was really four lines of output.)
    let h0 = heap_used();
    let initial = s.pop;

    if (dump > 0) { dump_gen(s, 0); };

    // One loop over the generations, with the bookkeeping inside it.  The
    // tables are fixed, so a run of 100 000 generations costs the same memory
    // as a run of 10 -- generations past TRACE_CAP are simulated and counted
    // in the peak/frozen/extinct trackers but not traced, and the summary says
    // so rather than quietly showing a short list.
    let n = 0;
    if (frames < TRACE_CAP) { n = frames; } else { n = TRACE_CAP - 1; };
    let g = 0;
    let hist_n = 1;
    let shown = 1;
    trace[0] = initial;
    if (initial < HIST_CAP) {
        hist[initial] = hist[initial] + 1
    } else {
        hist[HIST_CAP] = hist[HIST_CAP] + 1
    };
    while (g < frames) {
        sim.step(s);
        g = g + 1;
        if (dump > 0 && (g % dump == 0 || g == frames)) { dump_gen(s, g); };
        if (g <= n) {
            let p = s.pop;
            trace[g] = p;
            shown = g + 1;
            hist_n = hist_n + 1;
            if (p < HIST_CAP) { hist[p] = hist[p] + 1; } else { hist[HIST_CAP] = hist[HIST_CAP] + 1; }
        }
    };

    // The leak measurement: taken here, with the generations run and nothing
    // of the report built yet.
    let h1 = heap_used();

    puts("summary\n");
    puts(field("initial live", tostring(initial)));
    puts(field("final live", tostring(s.pop)));
    puts(field("peak live", tostring(s.peak)));
    puts(field("populations", populations(trace, hist_n)));
    puts(histogram(hist, hist_n));
    if (s.frozen_at < 0) {
        puts(field("frozen", "never -- still evolving at generation " + tostring(s.gen)))
    } else {
        puts(field("frozen", "generation " + tostring(s.frozen_at)
                 + " (a still life: nothing changes from there on)"))
    };
    if (s.extinct_at < 0) {
        puts(field("extinct", "never"))
    } else {
        puts(field("extinct", "generation " + tostring(s.extinct_at)))
    };
    if (want_stats) {
        stats_block(clock_us() - w0, s.gen, h0, h1, shown)
    };
    0
};

// -- the live view -----------------------------------------------------------

// winsize() -> long -- the window size packed as rows * 1000 + cols, read into
// THIS module's own buffer.
//
// Why not tui.size()?  Because tui.size() answers `{ rows, cols }` -- a
// record LITERAL, built fresh on every call -- and a record literal inside a
// loop body allocates.  Polling it once a frame leaked exactly 40 bytes a frame:
// 222 KB over 90 frames, dead linear.
//
// The copy of tui in this folder is frozen and NOT edited, so the four lines
// it would take to fix it upstream are written out here instead: one ioctl
// (syscall 16, fd, REQUEST, arg -- kernel register order, §2.1) into a
// module-level [byte; 64], then two 16-bit little-endian reads.  ROW FIRST, at
// bytes 0-1 (§2.3).  Returning one packed long rather than a record keeps the
// allocation count at zero.
//
// 24x80 when the ioctl fails or reports a zero, which is what a pty from
// pty.fork() looks like before anybody sets TIOCSWINSZ.
//
// WS is a GROWABLE [byte], like tui's own WS, and not a fixed [byte; 64]:
// a fixed array carries its elements inline, so `&WS[0]` has to box it, and
// the box is a one-time 64-byte heap block.  Measured as "64 bytes over 121
// frames" and the same 64 over 421 -- constant, so not a leak, but a growable
// array moves even that before the measurement starts.
let WS: [byte] = [0; 64];

def winsize() -> long {
    WS[0] = 0; WS[1] = 0; WS[2] = 0; WS[3] = 0;
    let r = 0;
    let c = 0;
    if (syscall(16, 1, 0x5413, &WS[0]) >= 0) {
        r = WS[0] + WS[1] * 256;
        c = WS[2] + WS[3] * 256
    };
    if (r < 1) { r = 24; };
    if (c < 1) { c = 80; };
    if (r > 1000) { r = 1000; };
    if (c > 1000) { c = 1000; };
    r * 1000 + c
};

def ws_rows(packed: long) -> long { packed / 1000 };

def ws_cols(packed: long) -> long { packed % 1000 };

//
// The status line is built into a FIXED byte buffer, not into a `str`, and
// that is the reason this whole block exists.  The obvious spelling is
//
//     tui.text(surf, s.h, 0, f"gen {s.gen} | live {s.pop} | …", fg, bg)
//
// which is one f-string and several `+` per frame -- and every one of those
// allocates, because the heap is an arena and nothing is freed.  Measured
// through a pty that leaked ~3.7 KB a frame (222 KB over 90 frames, 690 KB
// over 271, dead linear): a program that looks fine for an hour and then runs
// into the 3.5 GiB cap.  `heap_used()` either side of the loop is what found
// it -- see --stats.
//
// The buffer is module level, so it is allocated ONCE, and every helper writes
// into it in place.  tui's ESC_BUF is the same idea, but it is 64 bytes and
// a status line is 80.

// A status line plus its padding has to fit; nothing here is unbounded, and
// sb_byte drops anything past the cap rather than trapping on the store.
const SB_CAP = 256;

let SBUF: [byte; 256] = [0; 256];
let SBN = 0;

def sb_reset() { SBN = 0; };

def sb_byte(b: long) {
    if (SBN < SB_CAP) { SBUF[SBN] = b; };
    SBN = SBN + 1
};

// sb_str(t) -- a string's bytes.  A str index is a `byte` in Y, so this is a
// copy loop rather than an ord() call per character.
def sb_str(t: str) {
    let i = 0;
    let n = len(t);
    while (i < n) {
        sb_byte(t[i]);
        i = i + 1
    }
};

// sb_num(v) -- a non-negative long in decimal, no leading zeros, 0 as "0".
// Every value printed here is a count or a setting that main() has already
// checked is not negative, so there is no sign case.
def sb_num(v: long) {
    let d = 1;
    let t = v;
    while (t >= 10) {
        t = t / 10;
        d = d * 10
    };
    while (d > 0) {
        sb_byte(48 + (v / d) % 10);
        d = d / 10
    }
};

// sb_hundredths(x) -- x hundredths as "12.3".  tui reports hundredths of a
// frame per second because there is no float -> long (§2.4a), and this prints
// them without one.
def sb_hundredths(x: long) {
    sb_num(x / 100);
    sb_byte(46);                        // '.'
    let f = x % 100;
    if (f < 10) { sb_byte(48); };
    sb_num(f)
};

// sb_pad(to) -- pad with spaces up to `to` columns.  A line that got shorter
// (the generation count lost a digit, "PAUSED" back to "running") has to erase
// the tail of the longer line it replaced, and this is how -- without clearing
// the row above it.
def sb_pad(to: long) {
    while (SBN < to) { sb_byte(32); }
};

// sb_draw(surf, row, fg, bg) -- the buffer onto one surface row, one cell per
// byte.  The buffer is ASCII, so a byte is a codepoint of width 1.
def sb_draw(surf: tui.Surface, row: long, fg: long, bg: long) {
    let n = SBN;
    if (n > SB_CAP) { n = SB_CAP; };
    for i in 0..n {
        tui.put(surf, row, i, SBUF[i], fg, bg)
    }
};

// live_colour(age, mode) -> long -- the colour of a live cell, by how long it
// has been alive.  The age is what makes a Gosper gun legible: the cells it
// just made are bright and the ones that have been around a while are dim, so
// the stream of gliders shows up as a moving edge.
def live_colour(age: long, mode: long) -> long {
    let k = age;
    if (k > 40) { k = 40; };
    if (mode == 1) { return tui.grey(80 + k * 4); };
    if (mode == 2) { return tui.rgb(40 + k * 4, 190, 80 + k * 3); };
    tui.DEFAULT
};

// dead_colour(mode) -> long -- the board behind the cells.  The default
// terminal background in mono mode, a very dark blue otherwise.
def dead_colour(mode: long) -> long {
    if (mode == 0) { return tui.DEFAULT; };
    tui.rgb(10, 12, 16)
};

// draw(surf, s, mode) -- the whole grid into the surface.  Allocation-free:
// tui.put writes into arrays that already exist.  It does NOT flush; the caller
// draws the status line and then flushes once, so a frame costs one
// flush_diff and therefore one write(2) per row that changed.
def draw(surf: tui.Surface, s: sim.Sim, mode: long) {
    let dead = dead_colour(mode);
    for y in 0..s.h {
        let row = y;
        for x in 0..s.w {
            let i = y * s.w + x;
            if (s.cur[i] == 1) {
                tui.put(surf, row, x, 9608, live_colour(s.age[i], mode), dead)
            } else {
                tui.put(surf, row, x, 32, tui.DEFAULT, dead)
            }
        }
    }
};

// status(surf, s, pat, seed, fps, mode, paused, meter, help) -- the line along
// the bottom of the screen, built into the fixed buffer above and drawn in
// place.  Padded to the full width so a shorter line erases the longer one it
// replaces.  'h' puts the key list here instead.
def status(surf: tui.Surface, s: sim.Sim, pat: str, seed: long, fps: long, mode: long,
           paused: bool, meter: tui.Fps, help: bool) {
    let bg = dead_colour(mode);
    sb_reset();
    if (help) {
        sb_str("q quit  space pause  . step  n pattern  r reseed  c colour  +/- speed  h back");
        sb_pad(s.w);
        sb_draw(surf, s.h, tui.rgb(255, 200, 0), bg)
    } else {
        sb_str("gen ");
        sb_num(s.gen);
        sb_str(" | live ");
        sb_num(s.pop);
        sb_str(" | ");
        // The three states that replace "running", most alarming first: a grid
        // with no live cells cannot come back, and a frozen one never changes.
        if (s.pop == 0) {
            sb_str("EXTINCT");
        } else if (s.frozen_at >= 0) {
            sb_str("STILL LIFE");
        } else if (paused) {
            sb_str("PAUSED");
        } else {
            sb_str("running");
        };
        sb_str(" | ");
        if (mode == 1) {
            sb_str("gray");
        } else if (mode == 2) {
            sb_str("green");
        } else {
            sb_str("mono");
        };
        sb_str(" | ");
        sb_hundredths(tui.fps_x100(meter));
        sb_str(" fps");
        // The measured rate and the cap it is measured against, as "30.00/30",
        // so the line fits 80 columns even with a three-digit generation count.
        if (fps > 0) {
            sb_str("/");
            sb_num(fps)
        } else {
            sb_str(" uncapped")
        };
        sb_str(" | seed ");
        sb_num(seed);
        sb_str(" | ");
        sb_str(pat);
        sb_str(" | h keys");
        sb_pad(s.w);
        sb_draw(surf, s.h, tui.DEFAULT, bg)
    }
};

// run_live(...) -> long -- the interactive path.  Every exit goes through the
// restore_all_exit at the bottom, including the one the quit key causes.
def run_live(s: sim.Sim, f: Filled, pat_arg: str, seed: long, density: long,
             rle_text: str, fps: long, mode: long, want_stats: bool) -> long {
    if (!tui.raw_mode()) {
        eputs("life: stdin is not a terminal, so there is no live view.\n");
        eputs("life: use --frames N for the headless summary, e.g. `life --frames 200`.\n");
        return 1
    };
    tui.enter_screen();
    tui.arm_watchdog();

    let rows = s.h + 1;
    let cols = s.w;
    let surf = tui.new(rows, cols);
    let meter = tui.fps_new();
    let w0 = clock_us();
    let cap = fps;
    if (cap < 1) { cap = 1000000; };
    let pacer = tui.pacer_new(cap);
    let running = true;
    let paused = false;
    let help = false;
    // f.name is the RESOLVED pattern ("glider" when --pattern was not given,
    // "rle" when it was), which is what the status line and the 'n' cycle need;
    // pat_arg is still "" in the default case and is only what fill() wants.
    let cur_pat = f.name;
    let cur_mode = mode;
    let cur_fps = fps;
    let cur_seed = seed;
    // Read here, not one line earlier, because tui.pacer_new() above returns
    // a RECORD LITERAL and that is its own 64 bytes -- a setup cost, not a
    // frame cost.  With the reading taken before it, --stats reported a
    // constant "64 bytes over N generations" that was neither zero nor a leak,
    // which is the least useful of the three answers.
    let h0 = heap_used();

    while (running) {
        let wait = tui.pacer_next(pacer);

        // The window can change under a running program.  winsize() is one
        // ioctl into a fixed buffer, so it is cheap enough to ask every frame;
        // a rebuild allocates one new grid (8 MiB) and resizes the surface,
        // which is why it only happens when the size really changed.
        let packed = winsize();
        let wr = ws_rows(packed);
        let wc = ws_cols(packed);
        if (wr != rows || wc != cols) {
            let nw = wc;
            let nh = wr - 1;
            if (nw < 2) { nw = 2; };
            if (nh < 2) { nh = 2; };
            if (nw > sim.MAXW) { nw = sim.MAXW; };
            if (nh > sim.MAXH) { nh = sim.MAXH; };
            let ns: sim.Sim = sim.new(nw, nh);
            let nf = fill(ns, cur_pat, rle_text, cur_seed, density);
            if (nf.ok) {
                s = ns;
                cols = nw;
                rows = nh + 1;
                tui.resize(surf, rows, cols);
                tui.clear(surf, dead_colour(cur_mode));
                tui.pacer_start(pacer);
                draw(surf, s, cur_mode);
                status(surf, s, cur_pat, cur_seed, cur_fps, cur_mode, paused, meter, help);
                tui.flush_diff(surf)
            }
        };

        if (wait >= 0) {
            if (!paused) { sim.step(s); };
            draw(surf, s, cur_mode);
            status(surf, s, cur_pat, cur_seed, cur_fps, cur_mode, paused, meter, help);
            tui.flush_diff(surf);
            tui.fps_tick(meter)
        };

        // One keypress, polled WITHOUT waiting.
        //
        // read_key_timeout(ms) spends the wait in the terminal's VTIME, which
        // counts DECISECONDS: any non-zero request is rounded UP to the next
        // 100 ms, so `read_key_timeout(20)` is a 100 ms block.  At a 33 ms
        // frame period that makes every frame late by more than a whole
        // period, the pacer drops it, and -- because a dropped frame still
        // costs its 100 ms -- the schedule never recovers.  The first version
        // of this loop did exactly that and sat at 0.6 fps with the
        // generation counter stuck on 1.  A 0 ms deadline is an immediate poll
        // (VMIN=0, VTIME=0), so a key is picked up within one frame period
        // and the loop's own pacing is the only clock in it.
        //
        // The keys are compared with ord("q") and friends rather than written
        // as `k == 'q'`: this compiler has no character literal at all, and
        // `'q'` is a lexer error ("expected ')', got 'q'").  tui's header
        // comment shows the `'q'` spelling; the numbers are what works.
        let k = tui.read_key_timeout(0);
        if (k != tui.KEY_NONE) {
            if (k == ord("q") || k == tui.KEY_ESC || k == 3) {
                running = false
            } else if (k == 32) {
                paused = !paused
            } else if (k == 46) {
                sim.step(s)
            } else if (k == ord("h") || k == 63) {
                help = !help
            } else if (k == ord("c")) {
                cur_mode = (cur_mode + 1) % 3;
                tui.clear(surf, dead_colour(cur_mode))
            } else if (k == ord("+") || k == 61) {
                cur_fps = if (cur_fps == 0) { 30 } else { cur_fps * 2 };
                pacer = tui.pacer_new(if (cur_fps > 0) { cur_fps } else { 1000000 });
                tui.pacer_start(pacer)
            } else if (k == ord("-") || k == 95) {
                cur_fps = cur_fps / 2;
                if (cur_fps < 1) { cur_fps = 0; };
                pacer = tui.pacer_new(if (cur_fps > 0) { cur_fps } else { 1000000 });
                tui.pacer_start(pacer)
            } else if (k == ord("n")) {
                let names = ["glider", "gosper", "lwss", "blinker", "block", "random", "empty"];
                let at = 0;
                let i = 0;
                while (i < len(names)) {
                    if (names[i] == cur_pat) { at = (i + 1) % len(names); };
                    i = i + 1
                };
                cur_pat = names[at];
                let nf = fill(s, cur_pat, "", cur_seed, density);
                if (!nf.ok) {
                    cur_pat = "empty";
                    fill(s, "empty", "", cur_seed, density)
                }
            } else if (k == ord("r")) {
                cur_seed = cur_seed + 1;
                fill(s, "random", "", cur_seed, density)
            }
        }
    };

    let h1 = heap_used();
    // --stats has to be printed on the PRIMARY screen: everything written to
    // the alt screen is thrown away when it is left, and restore_all_exit
    // exits, so it could never print anything.  restore() and leave_screen()
    // are idempotent, so doing them here and then calling restore_all_exit
    // below is safe -- the last call is still the one that exits.
    tui.restore();
    tui.leave_screen();
    if (want_stats) { stats_block(clock_us() - w0, s.gen, h0, h1, s.gen); };
    tui.restore_all_exit(0);
    0
};

// -- main --------------------------------------------------------------------

def main() {
    args.init("life",
              "Conway's Game of Life (B3/S23) on a torus: a live view, or a headless summary",
              OPTS);

    // args's own convention is exit 2 for a usage error; this program's
    // contract is 1 for every diagnostic it raises, and it is a one-line
    // difference.  The message is already on stderr.
    let st = args.parse(argv());
    if (st == args.HELP) {
        puts(args.usage());
        exit(0)
    };
    if (st == args.USAGE) { exit(1); };

    let operands = args.positional();
    if (len(operands) > 0) {
        exit(die("unexpected operand '" + operands[0] + "'; everything is an option -- try --help"))
    };

    let rle_text = args.get_str("rle", "");
    let rle_given = args.has("rle");
    let pat_arg = args.get_str("pattern", "");
    let seed = args.get_long("seed", 1);
    let density = args.get_long("density", 30);
    let frames = args.get_long("frames", 0 - 1);
    let dump = args.get_long("dump", 0);
    let fps = args.get_long("fps", 30);
    let want_stats = args.has("stats");
    let cname = args.get_str("color", "mono");

    if (rle_given && len(rle_text) == 0) {
        // `--rle=""` is a mistake, not a request for the default pattern: it is
        // answered here rather than quietly falling through to --pattern.
        exit(die("--rle was given an empty string"))
    };
    // An unknown --pattern is caught here, before a grid is allocated, so the
    // live view can assume the name is real.  (fill() checks it again; it is
    // the one that has the grid and can say how big the pattern would be.)
    if (len(rle_text) == 0 && len(pat_arg) > 0
        && pat_arg != "random" && pat_arg != "empty" && sim.by_name(pat_arg) == "") {
        exit(die("unknown pattern '" + pat_arg + "'; expected " + sim.names()))
    };
    if (frames < 0 - 1) {
        exit(die("--frames cannot be negative (got " + tostring(frames) + ")"))
    };
    if (dump < 0) { exit(die("--dump cannot be negative (got " + tostring(dump) + ")")); };
    if (fps < 0) { exit(die("--fps cannot be negative (got " + tostring(fps) + ")")); };
    if (density < 0 || density > 100) {
        exit(die("--density is a percentage, 0 to 100 (got " + tostring(density) + ")"))
    };
    let mode = 0;
    if (cname == "gray") { mode = 1; };
    if (cname == "green") { mode = 2; };
    if (cname != "mono" && cname != "gray" && cname != "green") {
        exit(die("--color must be mono, gray or green (got '" + cname + "')"))
    };

    // --size, or the terminal's own size
    let sz_arg = args.get_str("size", "");
    let sz: Size = if (len(sz_arg) > 0) { parse_size(sz_arg) } else { default_size() };
    if (!sz.ok) { exit(die(sz.msg)); };

    // THE ALLOCATION: one grid, made here, used by both modes.  sim.new() is
    // the only thing in this program that allocates a buffer, and the headless
    // loop below it allocates nothing at all.
    let s: sim.Sim = sim.new(sz.w, sz.h);
    let f = fill(s, pat_arg, rle_text, seed, density);
    if (!f.ok) { exit(die(f.msg)); };

    if (frames >= 0) {
        exit(run_headless(s, frames, dump, f, want_stats))
    };
    exit(run_live(s, f, pat_arg, seed, density, rle_text, fps, mode, want_stats))
};

main();
