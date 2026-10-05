// maze.y -- maze generation and pathfinding with a terminal UI.
//
//   usage: maze [options]
//
// Three maze generators (recursive backtracker, randomised Prim, randomised
// Kruskal), two solvers (BFS and A* with a Manhattan heuristic and a binary
// min-heap), a corridor-length distribution that makes the three generators
// comparable, and a walkable terminal view.
//
//   build:  ycc -o maze maze.y    (rng.y grid.y astar.y sink.y must sit beside it)
//   run:    ./maze                       interactive; arrows walk, q quits
//          ./maze --no-tty --frames 3 --seed 1    the deterministic run
//
// All of the algorithms are in grid.y and astar.y.  This file is the command
// line, the two painters (ASCII into a byte sink, cells into an tui.Surface),
// the comparison table, and the interactive loop.
//
// rng.y is NOT imported here: the seeding lives in the generators (grid.y), and
// the only thing the driver needs from that stream is the integer, which is
// already a module-level `let` here.
//
// ─────────────────────────────────────────────────────────────────────────
// WHY THE TIMINGS ARE BEHIND A FLAG.  gate.py diffs stdout AND STDERR TOGETHER
// against EXPECTED, so a line carrying a wall-clock time would make the
// deterministic run non-reproducible and the example would fail its own gate.
// Generation and solve times are therefore reported only under --time, on
// stderr.  That is the honest trade: the measurements are real and printed on
// request, and the golden run stays byte-identical.

import args;
import grid;
import astar;
import sink;
import tui;

// ─────────────────────────────────────────────────────────────── the CLI ───

let GENS: [str] = ["rb", "prim", "kruskal"];
let SOLVERS: [str] = ["bfs", "astar"];

let OPTS: [args.Opt] = [
    { long: "frames", short: "n", kind: args.NUM,
      help: "render exactly N display steps, then exit 0 (0 = until a key; default 0)" },
    { long: "seed", short: "r", kind: args.NUM,
      help: "PRNG seed; same seed, same maze (default 1)" },
    { long: "gen", short: "g", kind: args.STR,
      help: "rb | prim | kruskal   (default rb: recursive backtracker)" },
    { long: "solver", short: "k", kind: args.STR,
      help: "bfs | astar   (default bfs; both are always run for the cross-check)" },
    { long: "size", short: "w", kind: args.STR,
      help: "WxH cells, 1..201 each; default the terminal, or 39x11 without one" },
    { long: "no-tty", short: "t", kind: args.BOOL,
      help: "print text instead of drawing to the terminal; never paces, never reads a key" },
    { long: "time", short: "e", kind: args.BOOL,
      help: "wall clock and heap delta on stderr when done" },
    { long: "ascii", short: "a", kind: args.BOOL,
      help: "print all three generators' mazes and the solved route as text" },
    { long: "soak", short: "p", kind: args.NUM,
      help: "solve N times in a row and report the heap delta (default 0: off)" },
    { long: "fps", short: "f", kind: args.NUM,
      help: "frames per second, interactive only (default 24)" }
];

let SEED: long = 1;
let FRAMES: long = 0;
let SOLVER: long = 0;
let GEN: long = 0;
let NOTTY: long = 0;
let SHOWTIME: long = 0;
let ASCII: long = 0;
let SOAK: long = 0;
let FPSWANT: long = 24;
let WANT_W: long = 0;
let WANT_H: long = 0;
let HAVE_SIZE: long = 0;

// ─────────────────────────────────────────────────────────── the CLI plumbing ───

def die(msg: str) -> void {
    eputs("maze: ");
    eputs(msg);
    eputs("\nmaze: try --help\n");
    exit(1)
};

// mode_of(name, what, allowed) -> long -- the index of a named choice.
//
// A bad name is a diagnostic, never a trap and never a silent default: asking
// for --solver=nope and getting BFS would be a lie about what was run.
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
        if (j + 1 < len(allowed)) { msg = msg + " | "; };
        j = j + 1;
    };
    die(msg);
    0
};

// parse_size(s) -> long -- WxH packed as W*1000000 + H, or 0 if it is not that
// shape or is out of range.
//
// REFUSED, not clamped, and that is a deliberate difference from examples/donut,
// which clamps --size to 1x1.  A maze of zero cells has no cell to stand in, no
// neighbour to test, and a mean-corridor-length whose denominator is zero, so
// the useful answer to `--size 0x0` is a diagnostic on stderr and exit 1 --
// not a silently different maze.  The boundaries that DO survive are 1x1 (one
// cell, zero passages, a solution of length 0) and 2x1 (the smallest maze with
// a passage at all).
def parse_size(s: str) -> long {
    let at = s.index_of("x");
    if (at < 1) { return 0 - 1; };
    let a = s[0:at];
    let b = s[at + 1:];
    if (!args.num_ok(a) || !args.num_ok(b)) { return 0 - 1; };
    let w = tolong(a);
    let h = tolong(b);
    if (w < 1 || h < 1) { return 0 - 1; };
    if (w > grid.MAXW || h > grid.MAXH) { return 0 - 1; };
    w * 1000000 + h
};

// ─────────────────────────────────────────────────────────── generation ───

// run_gen(which, seed) -> long -- build the maze with generator `which`.
// One call site for all three, so the driver cannot forget to reseed: the
// stream is restarted from `seed` for every generator, which is what makes
// `--seed 1 --gen prim` and `--seed 1 --gen kruskal` comparable and what makes
// the comparison table below honest -- same seed, three different algorithms.
def run_gen(which: long, seed: long) -> long {
    let n = 0;
    if (which == 0) { n = grid.gen_rb(seed); }
    else if (which == 1) { n = grid.gen_prim(seed); }
    else { n = grid.gen_kruskal(seed); };
    n
};

// ─────────────────────────────────────────────────────── the report lines ───

// EDGES -- how many passages each of the three generators carved, kept so the
// spanning-tree check and --ascii can both read them afterwards.
let EDGES: [long; 3] = [0; 3];

//
// Everything here writes into sink.y's fixed byte buffer.  No `str`, no
// formatting library, no per-line allocation.

def line_gen(tag: str, passages: long) -> void {
    sink.sink_str("maze: ");
    sink.sink_padl(tag, 8);
    sink.sink_str(" passages ");
    sink.sink_pad(passages, 6);
    sink.sink_str("  dead ");
    sink.sink_pad(grid.s_dead, 6);
    sink.sink_str("  junc ");
    sink.sink_pad(grid.s_junc, 6);
    sink.sink_str("  corridors ");
    sink.sink_pad(grid.s_corr, 6);
    sink.sink_str("  longest ");
    sink.sink_pad(grid.s_long, 6);
    sink.sink_str("  mean ");
    // The mean is a long division printed with ONE decimal digit -- there is no
    // float->long conversion in Y at all (ORCHESTRATOR.md 2.4a), so the decimal
    // point is a character and the tenth is integer arithmetic:
    //     (total * 10 / count) % 10
    // The divisor is guarded.  A 1x1 maze has no corridors at all, and `x / 0`
    // is a runtime trap that prints to STDOUT (2.6) -- i.e. it would land in the
    // middle of this very line, in the middle of a frame.
    let cnt = grid.s_corr;
    if (cnt > 0) {
        sink.sink_pad(grid.s_total / cnt, 5);
        sink.sink_byte(46);
        sink.sink_pad((grid.s_total * 10 / cnt) % 10, 1);
    } else {
        sink.sink_pad(0, 5);
        sink.sink_byte(46);
        sink.sink_pad(0, 1)
    };
    sink.sink_str("  len 1-4:");
    sink.sink_pad(grid.s_bkt[0], 5);
    sink.sink_str(" 5-8:");
    sink.sink_pad(grid.s_bkt[1], 5);
    sink.sink_str(" 9-16:");
    sink.sink_pad(grid.s_bkt[2], 5);
    sink.sink_str(" 17-32:");
    sink.sink_pad(grid.s_bkt[3], 5);
    sink.sink_str(" 33+:");
    sink.sink_pad(grid.s_bkt[5], 5);
    sink.sink_nl()
};

def line_solver(tag: str, steps: long, expanded: long, pops: long, ok: long) -> void {
    sink.sink_str("maze: ");
    sink.sink_padl(tag, 10);
    sink.sink_str("steps ");
    sink.sink_pad(steps, 6);
    sink.sink_str("  expanded ");
    sink.sink_pad(expanded, 6);
    sink.sink_str("/");
    sink.sink_pad(grid.NCE, 6);
    sink.sink_str("  pops ");
    sink.sink_pad(pops, 6);
    sink.sink_str("  route ");
    if (ok == 1) { sink.sink_str("verified"); } else { sink.sink_str("NOT VERIFIED"); };
    sink.sink_nl()
};

// ────────────────────────────────────────────────────────── the text path ───

// ────────────────────────────────────────────────────────── the text path ───

// shown_for(k, frames) -> long -- how many cells of the expansion order frame
// k reveals.
//
// The route is on screen from the first frame -- it is the ANSWER, and a frame
// that hid it would only make the digest harder to read.  What the frames add is
// the EXPLORED set: frame 0 reveals nothing, and the last frame reveals every
// cell the solver popped.  Scaling by FRAMES-1 rather than one cell per frame is
// what makes `--frames 3` a readable three-frame digest instead of three almost
// identical frames: a 39x11 recursive-backtracker maze takes 117 pops, so a
// one-cell-per-frame animation would still be inside the first corridor at frame
// 100.
def shown_for(k: long, frames: long) -> long {
    let n = grid.sno;
    let r = 0;
    if (k > 0 || frames == 1) {
        if (frames > 1) {
            let d = frames - 1;
            r = k * n / d;
        } else {
            r = n
        }
    };
    if (r > n) { r = n; };
    r
};

// One frame of the deterministic output: a header line with the frame number, a
// checksum of the picture, and the picture itself as text.
def emit_frame(k: long, frames: long, steps: long, pcell: long) -> void {
    let shown = shown_for(k, frames);
    grid.grid_paint(shown, steps, pcell);
    sink.sink_str("frame ");
    sink.sink_pad(k, 2);
    sink.sink_str("/");
    sink.sink_pad(frames - 1, 2);
    sink.sink_str("  revealed ");
    sink.sink_pad(shown, 6);
    sink.sink_str("  sha ");
    sink.sink_hex16(grid.grid_paint_hash());
    sink.sink_nl();
    sink.sink_maze()
};

def text_run() -> void {
    sink.sink_str("maze ");
    sink.sink_num(grid.GW);
    sink.sink_str("x");
    sink.sink_num(grid.GH);
    sink.sink_str(" cells (");
    sink.sink_num(grid.RW);
    sink.sink_str("x");
    sink.sink_num(grid.RH);
    sink.sink_str(" chars), seed ");
    sink.sink_int(SEED);
    sink.sink_str(", gen ");
    sink.sink_str(GENS[GEN]);
    sink.sink_str(", solver ");
    sink.sink_str(SOLVERS[SOLVER]);
    sink.sink_nl();

    // The comparison table: all three generators, one run each, same seed.
    let g = 0;
    while (g < 3) {
        let e = run_gen(g, SEED);
        EDGES[g] = e;
        grid.grid_stats();
        line_gen(GENS[g], e);
        g = g + 1
    };
    // A perfect maze has exactly NCE-1 passages: every generator must answer
    // that, and saying so out loud is what turns three plausible pictures into
    // three spanning trees.
    let want = grid.NCE - 1;
    sink.sink_str("maze: spanning tree check  passages ");
    sink.sink_pad(EDGES[0], 6);
    sink.sink_str(" ");
    sink.sink_pad(EDGES[1], 6);
    sink.sink_str(" ");
    sink.sink_pad(EDGES[2], 6);
    sink.sink_str("  expected ");
    sink.sink_pad(want, 6);
    sink.sink_str("  ");
    let okall = 1;
    if (EDGES[0] != want) { okall = 0; };
    if (EDGES[1] != want) { okall = 0; };
    if (EDGES[2] != want) { okall = 0; };
    if (okall == 1) { sink.sink_str("ok"); } else { sink.sink_str("MISMATCH"); };
    sink.sink_nl();

    // The chosen maze, solved twice.
    run_gen(GEN, SEED);
    let goal = grid.NCE - 1;
    let lb = astar.bfs(0, goal);
    let bexp = astar.pexp;
    astar.keep_path();
    let bok = astar.pok;
    let la = astar.astar(0, goal);
    let aexp = astar.pexp;
    let apop = astar.ppop;
    let aok = astar.pok;
    line_solver("bfs", lb, bexp, bexp, bok);
    line_solver("astar", la, aexp, apop, aok);

    let agree = 0;
    if (lb == la && astar.same_path() == true) { agree = 1; };
    sink.sink_str("maze: cross-check  BFS ");
    sink.sink_num(lb);
    sink.sink_str(" = A* ");
    sink.sink_num(la);
    sink.sink_str("  ");
    if (agree == 1) { sink.sink_str("same length AND identical route"); }
    else { sink.sink_str("DISAGREE"); };
    sink.sink_nl();

    // The frames.  The selected solver's expansion order is what frame k
    // reveals, so the chosen solver runs once more here: the expansion order
    // grid.rk is painted from is the last solve's, and a reader comparing
    // `--solver astar` against `--solver bfs` must see each one's own order.
    let steps = astar.solve(SOLVER, 0, goal);
    let sn = grid.sno;
    let f = 0;
    while (f < FRAMES) {
        emit_frame(f, FRAMES, steps, 0);
        f = f + 1
    };
    if (sn < 0) { sn = 0; };
    sink.sink_str("maze: frames ");
    sink.sink_num(FRAMES);
    sink.sink_str("  expanded ");
    sink.sink_num(sn);
    sink.sink_str(" of ");
    sink.sink_num(grid.NCE);
    sink.sink_str(" cells");
    sink.sink_nl();

    if (ASCII != 0) { ascii_dump(); };
    if (SHOWTIME != 0) { timing_report(); };
    sink.sink_flush()
};

// ascii_dump() -> void -- the three generators side by side, then the solved
// route.  This is what golden/ holds.
def ascii_dump() -> void {
    let goal = grid.NCE - 1;
    let g = 0;
    while (g < 3) {
        run_gen(g, SEED);
        grid.grid_stats();
        let steps = astar.solve(SOLVER, 0, goal);
        grid.grid_paint(0, steps, 0);
        sink.sink_str("\n--- ");
        sink.sink_str(GENS[g]);
        sink.sink_str(" seed ");
        sink.sink_int(SEED);
        sink.sink_str(" passages ");
        sink.sink_num(EDGES[g]);
        sink.sink_str("  route ");
        sink.sink_num(steps);
        sink.sink_str(" steps ---\n");
        sink.sink_maze();
        g = g + 1
    };
    sink.sink_nl()
};

def timing_report() -> void {
    let g = 0;
    let goal = grid.NCE - 1;
    while (g < 3) {
        let t0 = clock_us();
        run_gen(g, SEED);
        let t1 = clock_us();
        eputs("maze: gen ");
        eputs(GENS[g]);
        eputs(" ");
        eputs(tostring(t1 - t0));
        eputs(" us for ");
        eputs(tostring(grid.NCE));
        eputs(" cells\n");
        g = g + 1
    };
    let h0 = heap_used();
    let s0 = clock_us();
    let lb = astar.bfs(0, goal);
    let bexp = astar.pexp;
    let m0 = clock_us();
    let la = astar.astar(0, goal);
    let aexp = astar.pexp;
    let apop = astar.ppop;
    let m1 = clock_us();
    // Read the heap BEFORE the first tostring(): eputs(tostring(...)) allocates
    // about 32 bytes a call, so a delta taken afterwards reports the summary's
    // own strings as if the solvers had leaked them.
    let h1 = heap_used();
    eputs("maze: bfs   ");
    eputs(tostring(lb));
    eputs(" steps, ");
    eputs(tostring(bexp));
    eputs(" expanded, ");
    eputs(tostring(m0 - s0));
    eputs(" us\nmaze: astar ");
    eputs(tostring(la));
    eputs(" steps, ");
    eputs(tostring(aexp));
    eputs(" expanded, ");
    eputs(tostring(apop));
    eputs(" pops, ");
    eputs(tostring(m1 - m0));
    eputs(" us, saved ");
    eputs(tostring(bexp - aexp));
    eputs(" cells\nmaze: heap_used ");
    eputs(tostring(h0));
    eputs(" -> ");
    eputs(tostring(h1));
    eputs(" delta ");
    eputs(tostring(h1 - h0));
    eputs("\n")
};

export { ascii_dump, timing_report };

// ────────────────────────────────────────────────── soak: the no-alloc check ───
//
// `--soak N` solves the current maze N times in a row and reports the heap
// delta across the whole run.  A solver that allocated per step would show it
// immediately: the arena never frees (ORCHESTRATOR.md 2.7), so even a 40-byte
// record literal per expansion would grow heap_used() by 400 KB per 10 000
// steps and by 40 GB per million.  This is the measurement, not an assertion.

def soak(n: long) -> void {
    let goal = grid.NCE - 1;
    let h0 = heap_used();
    let t0 = clock_us();
    let last = 0;
    let i = 0;
    while (i < n) {
        last = astar.solve(SOLVER, 0, goal);
        i = i + 1
    };
    let t1 = clock_us();
    let h1 = heap_used();
    let each = 0;
    if (n > 0) { each = (t1 - t0) / n; };
    eputs("maze: soak ");
    eputs(tostring(n));
    eputs(" solves of ");
    eputs(tostring(grid.NCE));
    eputs(" cells with ");
    eputs(SOLVERS[SOLVER]);
    eputs(" in ");
    eputs(tostring(t1 - t0));
    eputs(" us, ");
    eputs(tostring(each));
    eputs(" us each, last path ");
    eputs(tostring(last));
    eputs(" steps\nmaze: heap_used ");
    eputs(tostring(h0));
    eputs(" -> ");
    eputs(tostring(h1));
    eputs(" delta ");
    eputs(tostring(h1 - h0));
    eputs(" over ");
    eputs(tostring(n));
    eputs(" solves\n");
    exit(0)
};

// ─────────────────────────────────────────────────── the interactive path ───
//
// tui's pattern verbatim (its header is the authority): raw mode, alt
// screen, watchdog, and ONE place that leaves.  Y has no atexit and no signal
// handler, so every exit below is tui.restore_all_exit().
//
// The palette is one rgb() per kind, computed ONCE at module level.  A call in
// the draw loop would be fine numerically and wrong in spirit: the claim this
// example makes is that a frame costs no heap, and a palette recomputed per
// frame is exactly the sort of thing that would stop that being true.
let BG: long = 0;
let FG_WALL: long = 0;
let FG_FLOOR: long = 0;
let FG_SEEN: long = 0;
let FG_PATH: long = 0;
let FG_ME: long = 0;
let FG_START: long = 0;
let FG_GOAL: long = 0;
let G_WALL: long = 9608;         // full block
let G_SEEN: long = 9617;         // light shade
let G_PATH: long = 9679;         // small square
let G_ME: long = 9673;           // diamond
let G_START: long = 9679;
let G_GOAL: long = 9679;

let FBG: long = 0;

// safe_ch(v) -> long -- one colour channel, moved off the values tui's SGR
// writer gets wrong.
//
// tui's `emit_num` drops a zero in the TENS place, so a channel of 205 reaches
// the terminal as 25 and 104 as 14 -- a silently wrong colour, not an error.
// Filed in examples/BUGS.md ("fb.y's emit_num drops a zero digit"), where the
// title still names the module as it was when the defect was found.  std `tui`
// COULD be edited to fix it -- that is what moved the other three modules out
// of the folders -- but it would change the byte stream every drawing example
// produces, so the palette is nudged here instead: any channel
// with `v % 100 < 10` moves UP to the next value with no zero digit in it, so
// 104 becomes 112 and 205 becomes 212.  The hues are within a couple of units of
// what they were meant to be, and the picture is right on this compiler.
def safe_ch(v: long) -> long {
    let q = if (v < 0) { 0 } else { if (v > 255) { 255 } else { v } };
    if (q % 100 < 10) { q = q - q % 100 + 16; };
    q
};

// safe_rgb(r, g, b) -> long -- tui.rgb() through safe_ch().
def safe_rgb(r: long, g: long, b: long) -> long {
    tui.rgb(safe_ch(r), safe_ch(g), safe_ch(b))
};

def palette() -> void {
    BG = safe_rgb(10, 12, 18);
    FBG = BG;
    FG_WALL = safe_rgb(74, 84, 102);
    FG_FLOOR = BG;
    FG_SEEN = safe_rgb(46, 66, 104);
    FG_PATH = safe_rgb(238, 186, 92);
    FG_ME = safe_rgb(126, 232, 255);
    FG_START = safe_rgb(120, 224, 150);
    FG_GOAL = safe_rgb(240, 122, 200)
};

// glyph_of(k) / colour_of(k) -- the interactive painter.  The same seven kinds
// sink.ascii_of draws, so the terminal picture and the golden text are the same
// picture; only the glyphs and colours differ.
def glyph_of(k: long) -> long {
    let g = 32;
    if (k == grid.K_WALL) { g = G_WALL; }
    else if (k == grid.K_FLOOR) { g = 32; }
    else if (k == grid.K_SEEN) { g = G_SEEN; }
    else if (k == grid.K_PATH) { g = G_PATH; }
    else if (k == grid.K_ME) { g = G_ME; }
    else if (k == grid.K_START) { g = G_START; }
    else if (k == grid.K_GOAL) { g = G_GOAL; };
    g
};

def colour_of(k: long) -> long {
    let c = FG_FLOOR;
    if (k == grid.K_WALL) { c = FG_WALL; }
    else if (k == grid.K_FLOOR) { c = FG_FLOOR; }
    else if (k == grid.K_SEEN) { c = FG_SEEN; }
    else if (k == grid.K_PATH) { c = FG_PATH; }
    else if (k == grid.K_ME) { c = FG_ME; }
    else if (k == grid.K_START) { c = FG_START; }
    else if (k == grid.K_GOAL) { c = FG_GOAL; };
    c
};

// draw() -- one interactive frame.
//
// `shown` is how many cells of the solver's expansion order to reveal, and the
// interactive path passes all of `grid.sno`: the search's footprint IS the
// interesting half of this picture, dimmed behind the route.  (The --frames
// path is the one that reveals it progressively.)
def draw(s: tui.Surface, steps: long, pcell: long, showpath: long, shown: long) -> void {
    grid.grid_paint(shown, if (showpath == 1) { steps } else { 0 }, pcell);
    tui.fill(s, 32, FBG, BG);
    let y = 0;
    while (y < grid.RH) {
        let x = 0;
        while (x < grid.RW) {
            let k = grid.rk[y * grid.RW + x];
            tui.put(s, y, x, glyph_of(k), colour_of(k), BG);
            x = x + 1
        };
        y = y + 1
    }
};

// hud(s, row, steps, solver) -- the status line.  Numbers go out one digit at a
// time through a module-level scratch array; a HUD that called tostring() would
// allocate on the frame loop, and the whole point of this example is that it
// does not.
let DIG: [long; 20] = [48; 20];

def sline(s: tui.Surface, row: long, col: long, v: long) -> long {
    let d = DIG;
    // The seed may be negative, and a HUD that printed `-1` as `1` would be
    // lying; there is no room for a minus sign in the column budget, so a
    // negative seed shows as 0 here and in full on the --no-tty header.
    let q = if (v < 0) { 0 } else { v };
    let n = 0;
    while (q > 0 && n < 20) {
        d[19 - n] = 48 + q % 10;
        q = q / 10;
        n = n + 1
    };
    let at = col;
    let i = 20 - n;
    while (i < 20) {
        tui.put(s, row, at, d[i], safe_rgb(180, 190, 205), BG);
        at = at + 1;
        i = i + 1
    };
    at
};

// hud() -- the status line, one terminal row.
//
// Numbers go out one digit at a time through a module-level scratch array
// (DIG).  A HUD that called tostring() would allocate on the frame loop, and
// this example's whole claim is that the frame loop does not.
//
// The hint text is only drawn when there is room for it: tui.text() does not
// bound-check the column, so a line longer than the window silently wraps into
// the next row and lands ON the maze.  tui.put() ignores an out-of-range cell,
// so the guard below is not about safety, it is about the picture.
let HINT = "arrows/hjkl  g new  s solver  t path  q";

def hud(s: tui.Surface, row: long, steps: long) -> void {
    let dim = safe_rgb(120, 130, 146);
    let c = 1;
    c = sline(s, row, c, grid.GW);
    tui.text(s, row, c, "x", dim, BG); c = c + 1;
    c = sline(s, row, c, grid.GH);
    c = c + 2;
    tui.text(s, row, c, "seed ", dim, BG); c = c + 5;
    c = sline(s, row, c, SEED);
    c = c + 2;
    tui.text(s, row, c, GENS[GEN], safe_rgb(210, 180, 100), BG);
    c = c + len(GENS[GEN]) + 2;
    tui.text(s, row, c, SOLVERS[SOLVER], safe_rgb(150, 210, 250), BG);
    c = c + len(SOLVERS[SOLVER]) + 2;
    tui.text(s, row, c, "route ", dim, BG); c = c + 6;
    c = sline(s, row, c, steps);
    c = c + 2;
    tui.text(s, row, c, "expanded ", dim, BG); c = c + 9;
    c = sline(s, row, c, astar.pexp);
    if (c + 2 + len(HINT) <= s.cols) {
        tui.text(s, row, c + 2, HINT, safe_rgb(96, 104, 118), BG)
    }
};

def walk_to(px: long, py: long, k: long) -> long {
    let nx = px;
    let ny = py;
    if (k == tui.KEY_LEFT || k == ord("h")) { nx = px - 1; }
    else if (k == tui.KEY_RIGHT || k == ord("l")) { nx = px + 1; }
    else if (k == tui.KEY_UP || k == ord("k")) { ny = py - 1; }
    else if (k == tui.KEY_DOWN || k == ord("j")) { ny = py + 1; };
    let ok = 0;
    if (nx != px || ny != py) {
        // Only ever move into an open passage: the walk is the maze, not a
        // teleport.  grid.open_at answers false off the grid, so the bounds
        // check and the wall check are one call.
        let d = 0 - 1;
        if (nx == px - 1) { d = 3; } else if (nx == px + 1) { d = 1; }
        else if (ny == py - 1) { d = 0; } else { d = 2; };
        if (d >= 0 && grid.open_at(px, py, d)) { ok = 1; }
    };
    ok
};

def interactive() -> void {
    if (!tui.raw_mode()) {
        eputs("maze: not a terminal; try --no-tty\n");
        exit(1)
    };
    tui.enter_screen();
    tui.arm_watchdog();

    let pacer = tui.pacer_new(FPSWANT);
    tui.pacer_start(pacer);

    // The surface is allocated once and resized, never rebuilt: tui.resize
    // allocates nothing (tui's own note).
    let srf = tui.new(grid.RH + 1, grid.RW);
    let px = 0;
    let py = 0;
    let steps = 0;
    let showpath = 1;
    let quit = false;
    let ih0 = heap_used();
    let bytes = 0;
    let frames = 0;

    steps = astar.solve(SOLVER, 0, grid.NCE - 1);

    while (quit == false) {
        let w = tui.pacer_next(pacer);
        if (w >= 0) {
            draw(srf, steps, py * grid.GW + px, showpath, grid.sno);
            hud(srf, grid.RH, steps);
            bytes = bytes + tui.flush_diff(srf);
            frames = frames + 1;
            if (FRAMES > 0 && frames >= FRAMES) {
                // heap_used() is READ BEFORE anything is printed, because
                // eputs(tostring(...)) allocates -- 32 bytes a call, four of
                // them here -- and reading it afterwards reports the summary's
                // own strings as if the frame loop had leaked them.
                let h1 = heap_used();
                eputs("maze: ");
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
                tui.restore_all_exit(0)
            }
        };

        // Keys are polled every frame; read_key_timeout(0) never blocks.
        let k = tui.read_key_timeout(0);
        if (k == ord("q") || k == ord("Q") || k == tui.KEY_ESC) {
            quit = true;
        } else if (k == ord("g")) {
            // `g` re-generates with the NEXT seed.  Still seeded, so the
            // sequence of mazes is reproducible; the status line shows which.
            SEED = SEED + 1;
            run_gen(GEN, SEED);
            steps = astar.solve(SOLVER, 0, grid.NCE - 1);
            px = 0;
            py = 0;
        } else if (k == ord("s")) {
            // Toggle the solver and re-solve from where the walker stands: the
            // route on screen is always the route from YOU, not from the start.
            if (SOLVER == 0) { SOLVER = 1; } else { SOLVER = 0; };
            steps = astar.solve(SOLVER, py * grid.GW + px, grid.NCE - 1);
        } else if (k == ord("t")) {
            if (showpath == 1) { showpath = 0; } else { showpath = 1; }
        } else {
            let mx = px;
            let my = py;
            if (walk_to(px, py, k) == 1) {
                px = mx;
                py = my;
                if (k == tui.KEY_LEFT || k == ord("h")) { px = px - 1; }
                else if (k == tui.KEY_RIGHT || k == ord("l")) { px = px + 1; }
                else if (k == tui.KEY_UP || k == ord("k")) { py = py - 1; }
                else if (k == tui.KEY_DOWN || k == ord("j")) { py = py + 1; };
                steps = astar.solve(SOLVER, py * grid.GW + px, grid.NCE - 1)
            }
        }
    };

    // Same ordering rule as the --frames exit above: read the heap before the
    // first tostring(), or the delta measures the summary.
    let h1 = heap_used();
    eputs("maze: ");
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
    tui.restore_all_exit(0)
};

// ───────────────────────────────────────────────────────────────── the run ───

args.init("maze", "maze generation and pathfinding: three generators, BFS and A*, a walkable view.",
          OPTS);
let st = args.parse(argv());
if (st == args.HELP) {
    puts(args.usage());
    puts("\ngenerators (all three are always generated and compared):\n");
    puts("  rb        recursive backtracker, depth-first: long snaking corridors, few dead ends\n");
    puts("  prim      randomised Prim: short corridors, many dead ends\n");
    puts("  kruskal   randomised Kruskal over a union-find: a UNIFORM spanning tree\n");
    puts("\nsolvers:\n");
    puts("  bfs       breadth-first: shortest by steps, expands the whole ball of radius L\n");
    puts("  astar     A* with a Manhattan heuristic and a binary min-heap: expands the\n");
    puts("            ellipse g+h <= L instead, which on a snaking maze is far fewer cells\n");
    puts("\nkeys, interactive:\n");
    puts("  arrows or hjkl   walk (only through open passages)\n");
    puts("  g                regenerate with the next seed\n");
    puts("  s                switch solver and re-solve from where you stand\n");
    puts("  t                toggle the route overlay\n");
    puts("  q or Escape      quit\n");
    puts("\nexit codes:  0 fine, 1 a bad flag or a bad argument (message on stderr),\n");
    puts("             2 a usage error from the flag parser itself.\n");
    exit(0)
};
if (st == args.USAGE) {
    eputs("maze: try --help\n");
    exit(1)
};

if (len(args.positional()) > 0) {
    die("takes no operands; got '" + args.positional()[0] + "'")
};

GEN = mode_of(args.get_str("gen", "rb"), "--gen", GENS);
SOLVER = mode_of(args.get_str("solver", "bfs"), "--solver", SOLVERS);
SEED = args.get_long("seed", 1);
FRAMES = args.get_long("frames", 0);
SOAK = args.get_long("soak", 0);
FPSWANT = args.get_long("fps", 24);
if (FPSWANT < 1) { FPSWANT = 1; };
if (FPSWANT > 240) { FPSWANT = 240; };
NOTTY = if (args.has("no-tty")) { 1 } else { 0 };
SHOWTIME = if (args.has("time")) { 1 } else { 0 };
ASCII = if (args.has("ascii")) { 1 } else { 0 };
if (FRAMES < 0) { die("--frames wants a count, not a negative number"); };

// ── the size, decided before anything is allocated ────────────────────────
//
// The size is a property of the maze, not of the terminal: --size wins, and
// without it the terminal decides (or a fixed default when there is no
// terminal, which is what makes the deterministic run reproducible on a machine
// whose window happens to be a different shape).
let ws = tui.size();
let w = 0;
let h = 0;
if (args.has("size")) {
    let sz = parse_size(args.get_str("size", ""));
    if (sz < 0) {
        die("--size wants WxH cells, both from 1 to " + tostring(grid.MAXW) +
            " (got '" + args.get_str("size", "") + "')")
    };
    w = sz / 1000000;
    h = sz % 1000000;
} else if (NOTTY != 0) {
    // 39x11 renders as 79x23: an 80x24 terminal with the status line.
    w = 39;
    h = 11;
} else {
    // The render is 2w+1 by 2h+1 and one terminal row is the status line, so a
    // 24-row window fits an 11-cell maze and an 80-column one fits 39.
    //
    // 99 columns and 99 rows is the CEILING, and it is a bug workaround rather
    // than a taste: tui writes the CUP with the same emit_num that drops a zero
    // digit (examples/BUGS.md), so column 101 is emitted as 11 and everything
    // from there is written in the wrong place.  1..99 is exactly the range
    // emit_num gets right, so 49x11 in a 100-column window fills it and a
    // 200-column window shows 49x11 as well, which is a smaller maze than the
    // window could hold and is said so here rather than quietly drawing in the
    // wrong place.
    w = (ws.cols - 1) / 2;
    h = (ws.rows - 2) / 2;
    if (w > 49) { w = 49; };
    if (h > 49) { h = 49; };
    if (w < 1) { w = 1; };
    if (h < 1) { h = 1; }
};

grid.grid_setup(w, h);
palette();

// The maze, generated once.  Everything after this reads it.
run_gen(GEN, SEED);

if (SOAK > 0) { soak(SOAK); };

if (NOTTY != 0) {
    if (FRAMES < 0) { FRAMES = 0; };
    text_run();
    exit(0)
};

// Interactive.  --frames without --no-tty is an animation of N frames then a
// clean exit 0, which is how a human can watch the same thing the golden run
// records; with neither, it runs until q.
interactive();