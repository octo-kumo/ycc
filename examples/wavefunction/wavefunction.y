// wavefunction.y -- wave function collapse by constraint propagation, with a
// terminal view, a deterministic golden, and a property battery.
//
//   build:  ../../refs/ycc.ref wavefunction.y -o wavefunction
//   run:    ./wavefunction                                  interactive
//          ./wavefunction --no-tty --frames 3 --seed 1     the deterministic run
//          ./wavefunction --check                          the property battery
//
// tiles.y  the sixteen tiles, the socket rule, the two projection tables
// wfc.y    the search: propagate, pick, collapse, backtrack
// sink.y   the text path: one fixed byte buffer, one write(2)
// check.y  the property battery, with its own copy of the socket rule
//
// ─────────────────────────────────────────────────────────────────────────────
// WHY THE TIMINGS ARE BEHIND A FLAG.  gate.py diffs stdout AND STDERR TOGETHER
// against EXPECTED, so a line carrying a wall-clock time would make the
// deterministic run irreproducible and the example would fail its own gate.
// Times are therefore reported only under --time, on stderr.  That is the
// honest trade: the measurements are real and printed on request, and the
// golden run stays byte-identical.
//
// WHY THE TERMINAL PATH AND THE GOLDEN RUN THE SAME CODE.  Both call
// wfc.next_event() in a loop.  There is no second solver to drift out of step
// with the first, and what the terminal animates is exactly what EXPECTED
// records.

import args;
import fb;
import fx;
import term;
import time;
import tiles;
import wfc;
import sink;
import check;

// ─────────────────────────────────────────────────────────────────── the CLI ───

let OPTS: [args.Opt] = [
    { long: "frames", short: "n", kind: args.NUM,
      help: "render exactly N display steps of the search, then exit 0 (0 = just the result)" },
    { long: "seed", short: "r", kind: args.NUM,
      help: "PRNG seed; same seed, same picture (default 1)" },
    { long: "tiles", short: "k", kind: args.STR,
      help: "all | loop | lines | elbows | ends | straights | cross  (default all)" },
    { long: "size", short: "w", kind: args.STR,
      help: "WxH cells, 1..64 each; default 24x14 without a terminal, else the window" },
    { long: "no-tty", short: "t", kind: args.BOOL,
      help: "print text instead of drawing to the terminal; never paces, never reads a key" },
    { long: "check", short: "c", kind: args.BOOL,
      help: "run the property battery and exit; no reference file is involved" },
    { long: "time", short: "e", kind: args.BOOL,
      help: "wall clock and heap delta on stderr when done" },
    { long: "soak", short: "p", kind: args.NUM,
      help: "solve N times in a row and report the heap delta (default 0: off)" },
    { long: "fps", short: "f", kind: args.NUM,
      help: "frames per second, interactive only (default 12)" },
    { long: "inject", short: "j", kind: args.NUM,
      help: "with --check, put deliberate defect N in force (1..17); it must FAIL" }
];

let SEED: long = 1;
let FRAMES: long = 0;
let NOTTY: long = 0;
let SHOWTIME: long = 0;
let CHECKMODE: long = 0;
let INJECT: long = 0;
let SOAK: long = 0;
let FPSWANT: long = 12;
let TWANT: long = 0;
let WANT_W: long = 24;
let WANT_H: long = 14;
let HAVE_SIZE: long = 0;

// Everything the run reports, filled in by text_run() and read by the summary.
let RES_RC: long = 0;
let RES_EVENTS: long = 0;
let RES_PAIRS: long = 0;
let RES_BAD: long = 0;
let RES_OFFGRID: long = 0;
let RES_CELLS_USED: long = 0;
let RES_COMPONENTS: long = 0;
let RES_H0: long = 0;

def die(msg: str) -> void {
    eputs("wavefunction: ");
    eputs(msg);
    eputs("\nwavefunction: try --help\n");
    exit(1)
};

// mode_of(name, what, allowed) -> long -- the index of a named choice.
//
// A bad name is a diagnostic, never a trap and never a silent default: asking
// for --tiles=nope and getting `all` would be a lie about what was solved.
def mode_of(name: str, what: str, allowed: [str]) -> long {
    let i = 0;
    while (i < len(allowed)) {
        if (allowed[i] == name) { return i };
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

// parse_size(s) -> long -- WxH packed as W*1000000 + H, or -1 if it is not that
// shape or is out of range.
//
// REFUSED, not clamped, and for the same reason maze refuses: --size 0x0 has no
// cell to collapse, and a silently clamped size would be a different puzzle
// than the one asked for.  1x1 IS legal and interesting -- one cell, no
// neighbours, and the boundary masks reduce the domain to the tiles with all
// four sockets clear.
def parse_size(s: str) -> long {
    let at = s.index_of("x");
    if (at < 1) { return 0 - 1 };
    let a = s[0:at];
    let b = s[at + 1:];
    if (!args.num_ok(a) || !args.num_ok(b)) { return 0 - 1 };
    let w = tonum(a);
    let h = tonum(b);
    if (w < 1 || h < 1) { return 0 - 1 };
    if (w > wfc.MAXW || h > wfc.MAXH) { return 0 - 1 };
    w * 1000000 + h
};

// ─────────────────────────────────────────────────────────── the network ───
//
// components(n) -> long -- how many connected groups of socket-carrying cells
// the finished grid holds, by an explicit flood fill over a module-level stack.
//
// A flood fill and not a union-find because it is used once per run and the
// stack is free; check.y computes the same number a second way (union-find over
// the same socket rule) and the two must agree.  `stop` is the guard flag that
// stands in for the `break` a flood fill would otherwise want.
let FSTACK: [long; 4096] = [0; 4096];
let FSEEN: [byte; 4096] = [0; 4096];

def components() -> long {
    let i = 0;
    while (i < wfc.NC) { FSEEN[i] = 0; i = i + 1 };
    let n = 0;
    let start = 0;
    while (start < wfc.NC) {
        if (FSEEN[start] == 0 && tiles.SOCK[wfc.first_bit(wfc.MASK[start])] != 0) {
            n = n + 1;
            let sp = 0;
            FSTACK[sp] = start;
            sp = sp + 1;
            FSEEN[start] = 1;
            let go = true;
            while (go) {
                let c = FSTACK[sp - 1];
                sp = sp - 1;
                // Queue the four neighbours that share a socket with c.  The
                // `if (... && ok)` IS the early exit: a cell with no socket in
                // that direction has nothing to add, and neither has one that
                // has been seen already.
                let d = 0;
                while (d < 4) {
                    let j = wfc.neighbour(c, d);
                    if (j >= 0 && FSEEN[j] == 0) {
                        if (tiles.edge_bit(wfc.first_bit(wfc.MASK[c]), d) != 0 &&
                            tiles.edge_bit(wfc.first_bit(wfc.MASK[j]), tiles.opposite(d)) != 0) {
                            FSEEN[j] = 1;
                            FSTACK[sp] = j;
                            sp = sp + 1
                        }
                    };
                    d = d + 1
                };
                go = sp > 0
            }
        };
        start = start + 1
    };
    n
};

// ────────────────────────────────────────────────────────────── the text path ───

// The whole deterministic run.  Everything printed here goes through sink.y and
// leaves in one write(2), and nothing on this path allocates after setup: the
// frames re-run the search from scratch (setup resets every module-level array
// and the PRNG) precisely so no frame depends on the frame before it.
def text_run() -> void {
    let av = tiles.SUBMASK[TWANT];
    let t0 = time.now_us();
    let h0 = heap_used();
    wfc.setup(WANT_W, WANT_H, av, SEED);
    RES_H0 = h0;
    let hmean = wfc.mean_entropy();
    let rc = wfc.solve();
    let t1 = time.now_us();
    RES_RC = rc;
    RES_EVENTS = wfc.EV_N;
    RES_PAIRS = adj_pairs();
    RES_BAD = adj_bad();
    RES_OFFGRID = adj_offgrid();
    RES_CELLS_USED = cells_used();
    RES_COMPONENTS = components();

    sink.sink_str("wavefunction: ");
    sink.sink_num(WANT_W);
    sink.sink_str("x");
    sink.sink_num(WANT_H);
    sink.sink_str(" cells, seed ");
    sink.sink_int(SEED);
    sink.sink_str(", tiles ");
    sink.sink_str(tiles.SUBSETS[TWANT]);
    sink.sink_str(" (");
    sink.sink_num(popcount(av));
    sink.sink_str(" available)\n");
    sink.sink_str("rule: sockets N=1 E=2 S=4 W=8, a neighbour must agree on the edge they share\n");
    sink.sink_str("solve: ");
    sink.sink_num(wfc.COLLAPSES);
    sink.sink_str(" collapses, ");
    sink.sink_num(wfc.BACKTRACKS);
    sink.sink_str(" backtracks, ");
    sink.sink_num(wfc.CONTRA);
    sink.sink_str(" contradictions, ");
    sink.sink_num(wfc.STEPS);
    sink.sink_str(" steps, ");
    sink.sink_num(wfc.UNDOMAX);
    sink.sink_str(" undo entries, budget ");
    sink.sink_num(wfc.BUDGET);
    sink.sink_nl();
    sink.sink_str("entropy: ");
    sink.sink_q30(hmean, 3);
    sink.sink_str(" bits/cell over the open cells before the first collapse, ");
    sink.sink_num(wfc.COLLAPSES);
    sink.sink_str(" decisions\n");
    sink.sink_str("adjacency: ");
    sink.sink_num(RES_PAIRS);
    sink.sink_str(" adjacent pairs, ");
    sink.sink_num(RES_BAD);
    sink.sink_str(" disagreements, ");
    sink.sink_num(RES_OFFGRID);
    sink.sink_str(" sockets facing off-grid\n");
    sink.sink_str("network: ");
    sink.sink_num(RES_CELLS_USED);
    sink.sink_str(" cells carry a socket, in ");
    sink.sink_num(RES_COMPONENTS);
    sink.sink_str(" closed components\n");

    if (FRAMES > 0) { frames_dump(RES_EVENTS); };

    // The final grid, from a solve run on its own so the frames above could not
    // have left a half-consumed search behind.  Same seed, same bytes.
    wfc.setup(WANT_W, WANT_H, av, SEED);
    wfc.solve();
    sink.sink_str("final grid\n");
    sink.paint();
    sink.sink_flush();
    if (SHOWTIME != 0) { timing_report(t1 - t0); }
};

// frames_dump(total) -- replay the search to `total` events and FRAMES evenly
// spaced points along it, printing the picture at each.
//
// Why re-run instead of snapshotting: a snapshot of the whole grid is one long
// per cell per event, and at 336 cells and 335 events that is 450 KiB a frame
// for a picture that the next frame supersedes.  Re-running the search is
// deterministic, so "the state after k events" is exactly reproducible and
// costs nothing but time -- which is what --soak measures.
def frames_dump(total: long) -> void {
    let av = tiles.SUBMASK[TWANT];
    let k = 0;
    while (k < FRAMES) {
        let want = 0;
        if (FRAMES == 1) {
            want = total
        } else {
            want = k * total / (FRAMES - 1)
        };
        wfc.setup(WANT_W, WANT_H, av, SEED);
        // `go = want > 0` IS the early exit: frame 0 must show the state BEFORE
        // any event, so the loop must not take one event and then notice that it
        // has taken one too many.
        let e = 0;
        let go = want > 0;
        while (go) {
            let ev = wfc.next_event();
            e = e + 1;
            if (ev == wfc.E_DONE || ev == wfc.E_FAIL || e >= want) { go = false }
        };
        sink.sink_str("frame ");
        sink.sink_pad(k, 2);
        sink.sink_str("/");
        sink.sink_pad(FRAMES, 2);
        sink.sink_str("  events ");
        sink.sink_pad(want, 5);
        sink.sink_str("  decided ");
        sink.sink_pad(decided(), 4);
        sink.sink_str("/");
        sink.sink_num(wfc.NC);
        sink.sink_str("  meanH ");
        sink.sink_q30(wfc.mean_entropy(), 2);
        sink.sink_str("  sha ");
        sink.sink_hex16(sink.paint_hash());
        sink.sink_nl();
        sink.paint();
        k = k + 1
    };
    sink.sink_nl()
};

// decided() -> long -- cells whose mask holds exactly one tile.
def decided() -> long {
    let n = 0;
    let i = 0;
    while (i < wfc.NC) {
        if (wfc.CNT[i] == 1) { n = n + 1 };
        i = i + 1
    };
    n
};

// cells_used() -> long -- cells carrying at least one socket.
def cells_used() -> long {
    let n = 0;
    let i = 0;
    while (i < wfc.NC) {
        if (tiles.SOCK[wfc.first_bit(wfc.MASK[i])] != 0) { n = n + 1 };
        i = i + 1
    };
    n
};

def popcount(m: long) -> long {
    let n = 0;
    let t = 0;
    while (t < tiles.NT) {
        if ((m & (1 << t)) != 0) { n = n + 1 };
        t = t + 1
    };
    n
};

// adj_pairs() -> long -- how many neighbour pairs there are: the number of
// adjacency constraints the finished grid has to satisfy, counted from the
// geometry rather than from the rule, so "0 disagreements" is a statement about
// that many constraints.
def adj_pairs() -> long {
    ((WANT_W - 1) * WANT_H) + (WANT_W * (WANT_H - 1))
};

// adj_bad() / adj_offgrid() -- the solver's own audit, split into the two kinds
// so the golden file cannot report "0 violations" for a grid that merely has
// no interior violations.
def adj_bad() -> long { wfc.audit() };

def adj_offgrid() -> long {
    let n = 0;
    let i = 0;
    while (i < wfc.NC) {
        let t = wfc.first_bit(wfc.MASK[i]);
        let d = 0;
        while (d < 4) {
            if (wfc.neighbour(i, d) < 0 && tiles.edge_bit(t, d) != 0) { n = n + 1 };
            d = d + 1
        };
        i = i + 1
    };
    n
};

// timing_report(us) -- everything the golden run must NOT print, because
// gate.py diffs stdout AND stderr against EXPECTED: the wall clock and the heap
// delta.  A line carrying a time would make the deterministic run irreproducible
// and the example would fail its own gate.  It is the honest trade: the
// measurements are real and printed on request.
def timing_report(us: long) -> void {
    let h1 = heap_used();
    eputs("wavefunction: solve ");
    eputs(tostring(WANT_W));
    eputs("x");
    eputs(tostring(WANT_H));
    eputs(" in ");
    eputs(tostring(us));
    eputs(" us, ");
    eputs(tostring(wfc.STEPS));
    eputs(" steps, ");
    eputs(tostring(wfc.COLLAPSES));
    eputs(" collapses, ");
    eputs(tostring(wfc.BACKTRACKS));
    eputs(" backtracks\n");
    eputs("wavefunction: heap_used ");
    eputs(tostring(RES_H0));
    eputs(" -> ");
    eputs(tostring(h1));
    eputs(" delta ");
    eputs(tostring(h1 - RES_H0));
    eputs(" bytes\n");
    exit(0)
};

// ──────────────────────────────────────────────────────────────────── soak ───
//
// `--soak N` solves the same instance N times in a row and reports the heap
// delta across the whole run.  A solver that allocated per step would show it
// at once: the arena never frees (ORCHESTRATOR.md 2.7), so even a 64-byte
// array literal per decision would add 6.4 MB per 100 000 decisions.  This is
// the measurement, not the assertion.
def soak(n: long) -> void {
    let av = tiles.SUBMASK[TWANT];
    wfc.setup(WANT_W, WANT_H, av, SEED);
    let h0 = heap_used();
    let t0 = time.now_us();
    let i = 0;
    let last = 0;
    while (i < n) {
        wfc.setup(WANT_W, WANT_H, av, SEED);
        last = wfc.solve();
        i = i + 1
    };
    let t1 = time.now_us();
    let h1 = heap_used();
    let each = 0;
    if (n > 0) { each = (t1 - t0) / n };
    eputs("wavefunction: soak ");
    eputs(tostring(n));
    eputs(" solves of ");
    eputs(tostring(wfc.NC));
    eputs(" cells in ");
    eputs(tostring(t1 - t0));
    eputs(" us, ");
    eputs(tostring(each));
    eputs(" us each, last rc ");
    eputs(tostring(last));
    eputs("\nwavefunction: heap_used ");
    eputs(tostring(h0));
    eputs(" -> ");
    eputs(tostring(h1));
    eputs(" delta ");
    eputs(tostring(h1 - h0));
    eputs(" bytes over ");
    eputs(tostring(n));
    eputs(" solves\n");
    exit(0)
};

// ─────────────────────────────────────────────────────────── the interactive path ───
//
// term.y's pattern verbatim: raw mode, alt screen, watchdog, and ONE place that
// leaves.  Y has no atexit and no signal handler, so every exit below is
// term.restore_all_exit().
//
// The palette is one fb.rgb() per role, computed ONCE at module scope.  A call
// inside the draw loop would be fine numerically and wrong in spirit: the claim
// this example makes is that a frame costs no heap, and a palette recomputed per
// frame is exactly the sort of thing that would stop that being true.
let BG: long = 0;
let FG_PIPE: long = 0;
let FG_EMPTY: long = 0;
let C_COLD: long = 0;
let C_HOT: long = 0;
let FG_DIM: long = 0;
let FG_KEY: long = 0;
let G_OPEN: long = 9634;             // U+25A2 BLACK SMALL SQUARE: an undecided cell.
// (The digits do not read as the codepoint they mean: 9679 is U+25CF, a black
// CIRCLE, which is what the first version of this drew for every cell the search
// had not reached.  0x2500 is 9472, so U+25A2 is 9472 + 0xA2 = 9634.)

// safe_ch(v) -> long -- one colour channel, moved off the values fb.y's SGR
// writer gets wrong.
//
// fb.y's `emit_num` drops a zero in the TENS place, so a channel of 205 reaches
// the terminal as 25 and 104 as 14 -- a silently wrong colour, not an error.
// Filed in examples/BUGS.md ("fb.y's emit_num drops a zero digit").  The frozen
// vendored copy cannot be edited, so the palette is nudged instead: any channel
// with `v % 100 < 10` moves UP to the next value with no zero digit in it, so
// 104 becomes 112 and 205 becomes 212.  The hues are within a couple of units of
// what they were meant to be, and the picture is right on this compiler.
def safe_ch(v: long) -> long {
    let q = if (v < 0) { 0 } else { if (v > 255) { 255 } else { v } };
    if (q % 100 < 10) { q = q - q % 100 + 16; };
    q
};

def safe_rgb(r: long, g: long, b: long) -> long {
    fb.rgb(safe_ch(r), safe_ch(g), safe_ch(b))
};

def palette() -> void {
    BG = safe_rgb(12, 14, 20);
    FG_PIPE = safe_rgb(126, 216, 238);
    FG_EMPTY = safe_rgb(30, 34, 44);
    C_COLD = safe_rgb(52, 66, 118);
    C_HOT = safe_rgb(214, 92, 128);
    FG_DIM = safe_rgb(118, 128, 146);
    FG_KEY = safe_rgb(232, 198, 96)
};

// colour_of(t) -> long -- the pipe colour.  One colour for every tile that has
// a socket: the SHAPE already says which, and a second hue per orientation
// would be decoration.
def colour_of(t: long) -> long {
    if (tiles.SOCK[t] == 0) { FG_EMPTY } else { FG_PIPE }
};

// shade_of(h) -> long -- the colour of an UNDECIDED cell, from its entropy.
//
// The one place fx.y earns its place in this example: h is a Q30 fixed-point
// value and fx.to_int() is the sanctioned conversion to an integer, so the
// "entropy to 0..255" step goes through the library rather than through a
// hand-rolled shift.  Note what is NOT here: no division of two fixed-point
// values.  `a / b` on two Q30 operands returns their RATIO (ORCHESTRATOR.md
// 2.4a), which is the trap that cost another example in this campaign six
// defects; here the only division is by the plain integer 255.
def shade_of(h: long) -> long {
    let whole = fx.to_int(h);
    if (whole < 0) { whole = 0 };
    let t = whole * 42;
    if (t > 255) { t = 255 };
    fb.lerp_rgb(C_COLD, C_HOT, t)
};

// draw(srf, heat) -- one interactive frame.
//
// heat == 1 tints the undecided cells by entropy; heat == 0 leaves them flat.
// The pipe glyphs are the same sixteen codepoints the ASCII table maps, so the
// terminal shows the actual socket pattern and not a proxy for it.
def draw(srf: fb.Surface, heat: long) -> void {
    fb.fill(srf, 32, BG, BG);
    let y = 0;
    while (y < wfc.GH) {
        let x = 0;
        while (x < wfc.GW) {
            let i = y * wfc.GW + x;
            if (wfc.CNT[i] == 1) {
                let t = wfc.first_bit(wfc.MASK[i]);
                fb.put(srf, y, x, tiles.GLY[t], colour_of(t), BG);
            } else if (heat == 1) {
                fb.put(srf, y, x, G_OPEN, shade_of(wfc.HENT[i]), BG);
            } else {
                fb.put(srf, y, x, G_OPEN, C_COLD, BG)
            };
            x = x + 1
        };
        y = y + 1
    }
};

// ── the status line ──
//
// Numbers go out one digit at a time through a module-level scratch array.  A
// HUD that called tostring() would allocate on the frame loop, and this
// example's whole claim is that the frame loop does not.
let DIG: [long; 20] = [48; 20];

def sline(srf: fb.Surface, row: long, col: long, v: long) -> long {
    let d = DIG;
    // The seed may be negative and a HUD with no room for a minus sign would
    // print -1 as 1, which is a lie; the --no-tty header shows it in full.
    let q = if (v < 0) { 0 } else { v };
    let n = 0;
    while (q > 0 && n < 20) {
        d[19 - n] = 48 + q % 10;
        q = q / 10;
        n = n + 1
    };
    // Zero is one digit.  The loop above leaves n at 0 for v = 0 and then prints
    // nothing, which put "decided /1078" in the status line -- the field the eye
    // reads first, empty.
    if (n == 0) { d[19] = 48; n = 1 };
    let at = col;
    let i = 20 - n;
    while (i < 20) {
        fb.put(srf, row, at, d[i], FG_DIM, BG);
        at = at + 1;
        i = i + 1
    };
    at
};

// hud(srf, row) -- the status line, one terminal row.
//
// The hint text is only drawn when there is room for it: fb.text() does not
// bound-check the column, so a line longer than the window silently wraps into
// the next row and lands ON the grid.  fb.put() ignores an out-of-range cell, so
// the guard below is not about safety, it is about the picture.
let HINT = "space step  a auto  n reseed  t heat  q quit";

def hud(srf: fb.Surface, row: long) -> void {
    let c = 1;
    c = sline(srf, row, c, wfc.GW);
    fb.text(srf, row, c, "x", FG_DIM, BG); c = c + 1;
    c = sline(srf, row, c, wfc.GH);
    c = c + 2;
    fb.text(srf, row, c, "seed ", FG_DIM, BG); c = c + 5;
    c = sline(srf, row, c, SEED);
    c = c + 2;
    fb.text(srf, row, c, tiles.SUBSETS[TWANT], FG_KEY, BG);
    c = c + len(tiles.SUBSETS[TWANT]) + 2;
    fb.text(srf, row, c, "decided ", FG_DIM, BG); c = c + 8;
    c = sline(srf, row, c, decided());
    fb.text(srf, row, c, "/", FG_DIM, BG); c = c + 1;
    c = sline(srf, row, c, wfc.NC);
    c = c + 2;
    fb.text(srf, row, c, "open ", FG_DIM, BG); c = c + 5;
    c = sline(srf, row, c, wfc.undecided());
    c = c + 2;
    fb.text(srf, row, c, "bt ", FG_DIM, BG); c = c + 3;
    c = sline(srf, row, c, wfc.BACKTRACKS);
    c = c + 2;
    fb.text(srf, row, c, "H ", FG_DIM, BG); c = c + 2;
    // The mean entropy in bits, one decimal: a Q30 integer divided by 2^30 is
    // done with fx.to_int and then by a plain 10, never by 2^30.
    let b10 = (wfc.mean_entropy() * 10) >>> 30;
    c = sline(srf, row, c, b10 / 1000);
    fb.text(srf, row, c, ".", FG_DIM, BG); c = c + 1;
    c = sline(srf, row, c, b10 % 1000);
    if (c + 2 + len(HINT) <= srf.cols) {
        fb.text(srf, row, c + 2, HINT, safe_rgb(92, 100, 116), BG)
    }
};

def interactive() -> void {
    if (!term.raw_mode()) {
        eputs("wavefunction: not a terminal; try --no-tty\n");
        exit(1)
    };
    term.enter_screen();
    term.arm_watchdog();

    let pacer = time.pacer_new(FPSWANT);
    time.pacer_start(pacer);

    // The surface is allocated once and resized, never rebuilt: fb.resize
    // allocates nothing (fb.y's own note).
    let srf = fb.new(WANT_H + 1, WANT_W);
    let av = tiles.SUBMASK[TWANT];
    wfc.setup(WANT_W, WANT_H, av, SEED);
    let rc = wfc.solve();
    let total = wfc.EV_N;
    // Replay: the search runs to its verdict, then the events are shown in
    // order.  Playing back a RECORDED solve rather than solving in front of the
    // reader is deliberate -- it means the picture on the terminal is the same
    // bytes EXPECTED holds, and a frame counter that disagrees with the golden
    // is impossible.
    wfc.setup(WANT_W, WANT_H, av, SEED);
    let ev = 0;
    let heat = 1;
    let auto = 0;
    let quit = false;
    let frames = 0;
    let bytes = 0;
    let ih0 = heap_used();

    while (quit == false) {
        let due = time.pacer_next(pacer);
        if (due >= 0) {
            if (auto == 1 && ev < total) {
                wfc.next_event();
                ev = ev + 1
            };
            draw(srf, heat);
            hud(srf, WANT_H);
            bytes = bytes + fb.flush_diff(srf);
            frames = frames + 1;
            if (FRAMES > 0 && frames >= FRAMES) {
                // heap_used() is READ BEFORE anything is printed, because
                // eputs(tostring(...)) allocates -- 32 bytes a call -- and
                // reading it afterwards reports the summary's own strings as if
                // the frame loop had leaked them.
                let h1 = heap_used();
                eputs("wavefunction: ");
                eputs(tostring(frames));
                eputs(" frames, ");
                eputs(tostring(bytes));
                eputs(" bytes of ANSI, heap_used ");
                eputs(tostring(ih0));
                eputs(" -> ");
                eputs(tostring(h1));
                eputs(" delta ");
                eputs(tostring(h1 - ih0));
                eputs("\n");
                term.restore_all_exit(0)
            }
        };

        // Keys are polled every frame; read_key_timeout(0) never blocks.  A
        // 1..99 ms poll would round up to 100 ms (VTIME counts deciseconds) and
        // report ~0.6 fps with a stuck frame counter.
        let k = term.read_key_timeout(0);
        if (k == ord("q") || k == ord("Q") || k == term.KEY_ESC) {
            quit = true;
        } else if (k == ord(" ")) {
            if (ev < total) { wfc.next_event(); ev = ev + 1 }
        } else if (k == ord("a")) {
            if (auto == 1) { auto = 0 } else { auto = 1 }
        } else if (k == ord("n")) {
            SEED = SEED + 1;
            wfc.setup(WANT_W, WANT_H, av, SEED);
            wfc.solve();
            total = wfc.EV_N;
            ev = 0
        } else if (k == ord("t")) {
            if (heat == 1) { heat = 0 } else { heat = 1 }
        }
    };

    // Same ordering rule as the --frames exit above: read the heap before the
    // first tostring(), or the delta measures the summary.
    let h1 = heap_used();
    eputs("wavefunction: ");
    eputs(tostring(frames));
    eputs(" frames, ");
    eputs(tostring(ev));
    eputs("/");
    eputs(tostring(total));
    eputs(" events, ");
    eputs(tostring(rc));
    eputs(" rc, ");
    eputs(tostring(bytes));
    eputs(" bytes of ANSI, heap_used ");
    eputs(tostring(ih0));
    eputs(" -> ");
    eputs(tostring(h1));
    eputs(" delta ");
    eputs(tostring(h1 - ih0));
    eputs("\n");
    term.restore_all_exit(0)
};

// ───────────────────────────────────────────────────────────────── the run ───

args.init("wavefunction",
          "wave function collapse by constraint propagation: sixteen socket tiles, arc-consistent propagation, lowest-entropy collapse with backtracking.",
          OPTS);
let st = args.parse(argv());
if (st == args.HELP) {
    puts(args.usage());
    puts("\ntiles (a tile is a set of four socket bits, N=1 E=2 S=4 W=8; two tiles may be\n");
    puts("neighbours only when they agree on the edge they share):\n");
    puts("  all        the sixteen: empty, four ends, two straights, four elbows,\n");
    puts("             four tees and the cross, with weights 6,1,1,1,1,3,3,4,4,4,4,1,1,1,1,1\n");
    puts("  loop       everything except `empty`: every cell must carry a socket, so\n");
    puts("             the finished grid is a set of closed loops and nothing else\n");
    puts("  lines      empty and the two straights\n");
    puts("  elbows     empty and the four elbows\n");
    puts("  ends       empty and the four ends\n");
    puts("  straights  the two straights only -- UNSATISFIABLE on any grid with a\n");
    puts("             corner, which is what the contradiction path is tested with\n");
    puts("  cross      the cross only -- also unsatisfiable, by the boundary\n");
    puts("\nthe search: every cell starts with the full set, the boundary narrows it, a\n");
    puts("worklist propagates to a fixpoint, then the cell of lowest Shannon entropy is\n");
    puts("collapsed -- ties to the LOWEST CELL INDEX, which is what makes EXPECTED\n");
    puts("reproducible -- and a contradiction rewinds the undo log and tries again.\n");
    puts("\nkeys, interactive:\n");
    puts("  space       one event: propagate to a fixpoint and collapse one cell\n");
    puts("  a           auto-run (one event a frame) / stop\n");
    puts("  n           reseed and solve again\n");
    puts("  t           toggle the entropy tint on the undecided cells\n");
    puts("  q or Escape quit\n");
    puts("\nchecks:\n");
    puts("  --check     the property battery: the finished grid against the socket rule,\n");
    puts("             an exhaustive solution count for hand-checked tiny grids, the\n");
    puts("             bookkeeping, the weighted draw, an unsatisfiable instance, and a\n");
    puts("             run with each of 17 injected defects, each of which must fail\n");
    puts("             (see README.md for the list and for what each one is)\n");
    puts("\nexit codes:  0 fine, 1 a bad flag or a bad argument (message on stderr),\n");
    puts("             2 a usage error from the flag parser itself,\n");
    puts("             3 the instance is UNSATISFIABLE and the search proved it,\n");
    puts("             4 the step budget ran out (no answer either way),\n");
    puts("             5 --check found something wrong\n");
    exit(0)
};
if (st == args.USAGE) {
    eputs("wavefunction: try --help\n");
    exit(1)
};

if (len(args.positional()) > 0) {
    die("takes no operands; got '" + args.positional()[0] + "'")
};

TWANT = mode_of(args.get_str("tiles", "all"), "--tiles", tiles.SUBSETS);
SEED = args.get_long("seed", 1);
FRAMES = args.get_long("frames", 0);
SOAK = args.get_long("soak", 0);
FPSWANT = args.get_long("fps", 12);
if (FPSWANT < 1) { FPSWANT = 1 };
if (FPSWANT > 240) { FPSWANT = 240 };
if (FRAMES < 0) { die("--frames wants a count, not a negative number") };
if (FRAMES > 4096) { die("--frames wants at most 4096 (one frame per event is 336)") };
if (SOAK < 0) { die("--soak wants a count, not a negative number") };
NOTTY = if (args.has("no-tty")) { 1 } else { 0 };
SHOWTIME = if (args.has("time")) { 1 } else { 0 };
CHECKMODE = if (args.has("check")) { 1 } else { 0 };
INJECT = args.get_long("inject", 0);
if (INJECT < 0 || INJECT > 17) { die("--inject takes 0 to 17") };
if (INJECT != 0 && CHECKMODE == 0) { die("--inject only means something with --check") };

// ── the size, decided before anything is allocated ───────────────────────────
//
// The size is a property of the instance, not of the terminal: --size wins, and
// without it the terminal decides (or a fixed default when there is no
// terminal, which is what makes the deterministic run reproducible on a machine
// whose window happens to be a different shape).
let ws = term.size();
if (args.has("size")) {
    let sz = parse_size(args.get_str("size", ""));
    if (sz < 0) {
        die("--size wants WxH cells, both from 1 to " + tostring(wfc.MAXW) +
            " (got '" + args.get_str("size", "") + "')")
    };
    WANT_W = sz / 1000000;
    WANT_H = sz % 1000000;
    HAVE_SIZE = 1;
} else if (NOTTY != 0 || SOAK > 0) {
    // 24x14 renders as 24x15: an 80x24 terminal with the status line.
    //
    // --soak counts this as "no terminal" on purpose.  It prints to stderr and
    // nothing else, so the size it measures should be the size the golden run
    // uses and not the size of whatever window happens to be attached -- without
    // this, `--soak 200` on a machine with no terminal measured a 49x22 grid,
    // because term.size() reports the fallback shape when stdin is not a tty.
    WANT_W = 24;
    WANT_H = 14;
} else {
    // One glyph per cell, and one terminal row is the status line, so a 24-row
    // window fits 23 rows of grid and an 80-column one fits 80 columns.
    //
    // 99 columns and 99 rows is the CEILING, and it is a bug workaround rather
    // than a taste: fb.y writes the CUP with the same emit_num that drops a zero
    // digit (examples/BUGS.md), so column 101 is emitted as 11 and everything
    // from there is written in the wrong place.  1..99 is exactly the range
    // emit_num gets right, so 49x23 fills a 50x24 window and a 200-column window
    // shows the same 49x23 grid, which is smaller than the window could hold and
    // is said so here rather than quietly drawing in the wrong place.
    WANT_W = ws.cols - 1;
    WANT_H = ws.rows - 2;
    if (WANT_W > 49) { WANT_W = 49 };
    if (WANT_H > 23) { WANT_H = 23 };
    if (WANT_W < 1) { WANT_W = 1 };
    if (WANT_H < 1) { WANT_H = 1 }
};

if (CHECKMODE != 0) {
    // --check decides its own sizes: the battery needs grids small enough to
    // enumerate exhaustively, not the window's.
    check.set_inject_want(INJECT);
    exit(check.run_check())
};

if (SOAK > 0) { soak(SOAK); };

if (NOTTY != 0) {
    text_run();
    if (RES_RC == wfc.R_UNSAT) {
        eputs("wavefunction: the instance is UNSATISFIABLE: the search exhausted every\n");
        eputs("wavefunction: choice and reached a contradiction with nothing left to try\n");
        exit(3)
    };
    if (RES_RC == wfc.R_BUDGET) {
        eputs("wavefunction: gave up after ");
        eputs(tostring(wfc.STEPS));
        eputs(" steps (budget ");
        eputs(tostring(wfc.BUDGET));
        eputs("); no answer either way\n");
        exit(4)
    };
    exit(0)
};

// Interactive.  --frames without --no-tty is an animation of N frames then a
// clean exit 0, which is how a human can watch the same thing the golden run
// records; with neither, it runs until q.
interactive();