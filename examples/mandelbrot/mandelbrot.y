// mandelbrot.y -- a threaded Mandelbrot explorer.
//
//   build:  ycc -o mandelbrot mandelbrot.y
//           (fx.y tui tui tui args mandel.y render.y textout.y must
//            all sit beside it -- they are vendored, not imported across
//            folders: ORCHESTRATOR.md 4)
//   run:    ./mandelbrot                     the interactive explorer
//          ./mandelbrot --frames 3 --no-tty   the deterministic run
//
// The set, the arithmetic and the overflow story are in mandel.y.  The worker
// pool is in render.y.  This file is the command line, the two frame loops,
// the status line, and the two output paths -- ANSI into the terminal, plain
// text into a fixed byte buffer.
//
// TWO OUTPUT PATHS, ONE PICTURE.  The render fills render.CELLS; paint() puts
// it into a framebuffer and the text path reads the same cells.  Neither can
// disagree with the other about a pixel, and --chars additionally re-renders
// every dumped frame through a completely different sink (a `str` built one
// chr() at a time) and the bytes have to come out the same.  That is a
// self-test, not a decoration.

import fx;
import args;
import mandel;
import render;
import textout;
import tui;

// ──────────────────────────────────────────────────────────────── options ───
//
// Note what is NOT here: no option whose value can change the default run's
// stdout.  --threads in particular decides how many workers draw the same
// pixels and cannot change a single byte of the picture, so printing it would
// have made EXPECTED depend on the machine's core count.  It goes to stderr
// under --time and to the status line instead; the README shows the two runs
// diffing clean.
let OPTS: [args.Opt] = [
    { long: "frames", short: "n", kind: args.NUM,
      help: "render exactly N frames, then exit 0; each frame halves the span (default 0: run until a key)" },
    { long: "size", short: "s", kind: args.STR,
      help: "grid as WxH cells, clamped to 1x1..256x128; default the terminal minus the status row, or 72x36 without one" },
    { long: "maxit", short: "m", kind: args.NUM,
      help: "iteration cap per pixel, clamped to 0..1000000 (default 240)" },
    { long: "threads", short: "t", kind: args.NUM,
      help: "worker threads, clamped to 1..64; 1 renders inline with no threads at all (default: this machine's CPUs, capped at 8)" },
    { long: "palette", short: "p", kind: args.STR,
      help: "blue | ember | ice | mono | grass | random   (random is built from --seed)" },
    { long: "shade", short: "", kind: args.STR,
      help: "iter | lum -- what a cell's glyph follows: the colour band, or the palette's luminance" },
    { long: "at", short: "a", kind: args.STR,
      help: "named view: full | seahorse | elephant | double | spiral | needles | random" },
    { long: "center", short: "c", kind: args.STR,
      help: "view centre as X,Y in decimal, e.g. --center=-0.743643887,0.131825904" },
    { long: "zoom", short: "z", kind: args.NUM,
      help: "extra halvings of the span, 0..48 (default 0)" },
    { long: "seed", short: "S", kind: args.NUM,
      help: "seed for --palette random and --at random; the same seed is the same picture (default 1)" },
    { long: "dump", short: "d", kind: args.STR,
      help: "comma-separated frame numbers to print as text (default: every frame when --frames <= 8, else the last)" },
    { long: "chars", short: "", kind: args.BOOL,
      help: "build the dumped frames with a str accumulator instead of the byte buffer; the bytes must come out identical" },
    { long: "no-tty", short: "", kind: args.BOOL,
      help: "render into a text capture instead of the terminal; never paces and never looks at the window" },
    { long: "time", short: "", kind: args.BOOL,
      help: "wall clock, ms a frame and the heap delta on stderr when done" }
];

let SHADES: [str] = ["iter", "lum"];

// ───────────────────────────────────────────────────────────────── state ───
//
// Module level rather than in a record: a record is a heap object and this is
// written on the frame path.
let FRAMES: long = 0;
let NOTTY: long = 0;
let SHOWTIME: long = 0;
let CHARS: long = 0;
let MAXIT: long = 240;
let SHD: long = 0;                       // 0 = iter, 1 = lum
let SEED: long = 1;
let PALKIND: long = 0;
let PLACE: long = 0;
let ZOOM: long = 0;
let HAS_CTR: long = 0;
let GRID_ROWS: long = 24;
let GRID_COLS: long = 36;
let dirty: long = 1;

// The frames the deterministic run prints in full, as a LIST and not as a
// bitmap.
//
// It was a bitmap -- one bit per frame index in a [long; 1024] -- and that is a
// trap waiting for `--frames 2000`: indexing it with the frame number goes out
// of bounds at 1024, and since bounds are checked it comes out as
// `runtime error: index out of bounds` ON STDOUT, half way through the
// capture.  Measured: `--frames 1020` was clean and `--frames 1040` died on
// frame 1024, for every thread count.
//
// So the set is the list itself.  `wanted(f)` is a scan of at most 64 entries,
// once a frame, which is nothing, and it has no upper bound to be wrong about.
const MAXDUMP: long = 64;
let WANT: [long; 64] = [0; 64];
let NWANT: long = 0;

// wanted(f) -> bool -- is frame f in the dump list?
def wanted(f: long) -> bool {
    let i: long = 0;
    while (i < NWANT) {
        if (WANT[i] == f) { return true };
        i = i + 1
    };
    false
};

// ─────────────────────────────────────────────────────────── small helpers ───

def die(msg: str) -> void {
    eputs("mandelbrot: ");
    eputs(msg);
    eputs("\nmandelbrot: try --help\n");
    exit(1)
};

def warn(msg: str) -> void {
    eputs("mandelbrot: ");
    eputs(msg);
    eputs("\n")
};

// index_of(name, table) -> long -- the position of name, or -1.  A linear
// scan: the tables have seven and six entries and are read once.
def index_of(name: str, table: [str]) -> long {
    let i: long = 0;
    while (i < len(table)) {
        if (table[i] == name) { return i };
        i = i + 1;
    };
    0 - 1
};

// ───────────────────────────────────────────── the frame, into a surface ───
//
// paint(s) draws render.CELLS into a framebuffer.  It runs on BOTH paths: on
// --no-tty the surface's ANSI stream goes to /dev/null and only its byte count
// is reported, which is what makes the `ansi` column of the per-frame table
// evidence that the terminal path ran too, rather than a claim that it would.
//
// One tui.put per cell and nothing else: the glyph ramp and the palette are
// both module-level tables, so no lookup allocates and no literal is built
// inside the loop.
def paint(s: tui.Surface) -> void {
    let bg = mandel.md_inside_bg();
    let r: long = 0;
    while (r < render.grid_rows()) {
        let c: long = 0;
        while (c < render.grid_cols()) {
            let cell = mandel.md_cell(render.at(r, c));
            if (cell == 0) {
                tui.put(s, r, c, 32, tui.DEFAULT, bg);
            } else {
                tui.put(s, r, c, mandel.md_glyph(cell, SHD),
                       mandel.md_colour(cell), bg);
            };
            c = c + 1;
        };
        r = r + 1
    }
};

// text_line_row(r) -- one row of the frame as plain ASCII through the byte
// sink.  Every glyph is ASCII (the ramp is ten printable characters and the
// interior is a space), so out_byte is the whole encoder.
def text_line_row(r: long) -> void {
    let c: long = 0;
    while (c < render.grid_cols()) {
        let cell = mandel.md_cell(render.at(r, c));
        textout.out_byte(mandel.md_glyph(cell, SHD));
        c = c + 1;
    };
    textout.out_byte(10)
};

// chars_line_row(r) -> str
//
// The same row built as a `str`, one chr() per cell.  This exists for ONE
// reason and it is a good one: it is a second, completely independent
// implementation of the text path, so `--chars` cross-checks that the byte sink
// and a real string produce the same bytes.
//
// It is also where this example meets the filed `str + byte` segfault.
// `line = line + glyph_byte` SEGFAULTS against the pinned compiler -- `s[i]`
// yields a byte and the `+` path hands the byte's numeric value to y_str_cat
// as a pointer (examples/BUGS.md, "`str + byte` segfaults") -- and
// `line += glyph_byte` does not even COMPILE: `'+=' string: expected str, got
// byte`, which means the compound-assign form the same filing lists as
// passing is not a workaround either.  chr() returns a real str, which is why
// this line type-checks and answers.
def chars_line_row(r: long) -> str {
    let line = "";
    let c: long = 0;
    while (c < render.grid_cols()) {
        let cell = mandel.md_cell(render.at(r, c));
        line = line + chr(mandel.md_glyph(cell, SHD));
        c = c + 1;
    };
    line
};

// ─────────────────────────────────────────────── allocation-free status line ───
//
// The status row is the one thing drawn every frame that is not part of the
// picture, and it is mostly numbers.  tostring() once a frame would allocate on
// the frame loop, so digits go through a module-level scratch buffer and
// tui.put, one cell at a time.  That is the sharp edge of the rule this file
// lives by: an ARRAY LITERAL is evaluated onto the heap every time the
// expression runs (examples/SUGGESTIONS.md section 7), so a literal written inside
// put_num here would leak once per number drawn.
let DIG: [long; 12] = [48; 12];
let HDR = tui.rgb(92, 100, 110);
let HFG = tui.rgb(208, 216, 224);
let HKEY = tui.rgb(224, 184, 90);
let HBG: long = 0;

// put_num(s, row, col, v, width) -> long -- v right-aligned in `width` cells,
// blank-padded.  Answers the column just past the number.
def put_num(s: tui.Surface, row: long, col: long, v: long, width: long) -> long {
    let q = if (v < 0) { 0 } else { v };
    let n: long = 0;
    while (q > 0 && n < 12) {
        DIG[11 - n] = 48 + q % 10;
        q = q / 10;
        n = n + 1;
    };
    let pad = width - n;
    let at = col;
    let i: long = 0;
    while (i < pad) {
        tui.put(s, row, at, 32, HDR, HBG);
        at = at + 1;
        i = i + 1;
    };
    let j: long = 12 - n;
    while (j < 12) {
        tui.put(s, row, at, DIG[j], HFG, HBG);
        at = at + 1;
        j = j + 1;
    };
    at
};

// put_fixed(s, row, col, v, decimals) -> long -- a Q30 value as a decimal
// with exactly `decimals` places.  The fraction is ONE multiply and ONE
// divide (frac*10^decimals/2^30, exact to the last digit printed) and the
// digits are put individually, so there is no string and no rounding mode to
// get wrong -- which is the whole reason this is 30 lines instead of one call
// to fx.to_str.
def put_fixed(s: tui.Surface, row: long, col: long, v: long, decimals: long) -> long {
    let neg = v < 0;
    let a = if (neg) { 0 - v } else { v };
    let at = col;
    if (neg) {
        tui.put(s, row, at, 45, HFG, HBG);
        at = at + 1;
    };
    at = put_num(s, row, at, a >> 30, 1);
    tui.put(s, row, at, 46, HFG, HBG);            // '.'
    at = at + 1;
    let scale: long = 1;
    let k: long = 0;
    while (k < decimals) { scale = scale * 10; k = k + 1; };
    let micro = ((a & 1073741823) * scale) / 1073741824;
    let div: long = 1;
    k = 0;
    while (k < decimals - 1) { div = div * 10; k = k + 1; };
    k = 0;
    while (k < decimals) {
        let d = (micro / div) % 10;
        tui.put(s, row, at, 48 + d, HFG, HBG);
        at = at + 1;
        div = div / 10;
        k = k + 1
    };
    at
};

def hud(s: tui.Surface, row: long, ms_x100: long, frame: long) -> void {
    let bg = mandel.md_inside_bg();
    let k: long = 0;
    while (k < s.cols) {
        tui.put(s, row, k, 32, HFG, bg);
        k = k + 1
    };
    let c = tui.text(s, row, 1, "mandelbrot", HKEY, bg);
    c = c + 1;
    c = tui.text(s, row, c, "at", HDR, bg); c = c + 3;
    c = tui.text(s, row, c, mandel.place_name(PLACE), HFG, bg);
    c = c + tui.text(s, row, c, " x", HDR, bg);
    c = put_fixed(s, row, c, mandel.md_cx(), 4);
    c = c + tui.text(s, row, c, " y", HDR, bg);
    c = put_fixed(s, row, c, mandel.md_cy(), 4);
    c = c + tui.text(s, row, c, " span", HDR, bg);
    c = put_fixed(s, row, c, mandel.md_span(), 7);
    c = c + 1;
    c = tui.text(s, row, c, "maxit", HDR, bg); c = c + 6;
    c = put_num(s, row, c, MAXIT, 6);
    c = c + 1;
    c = tui.text(s, row, c, "thr", HDR, bg); c = c + 4;
    c = put_num(s, row, c, render.threads(), 2);
    c = c + 1;
    c = tui.text(s, row, c, "ms", HDR, bg); c = c + 3;
    c = put_num(s, row, c, ms_x100, 5);
    c = c + 1;
    c = tui.text(s, row, c, "frame", HDR, bg); c = c + 6;
    c = put_num(s, row, c, frame, 6);
    c = c + 2;
    tui.text(s, row, c, "hjkl/arrows pan  +/- zoom  0-6 places  [ ] maxit  r reset  q quit",
            HDR, bg)
};

// ─────────────────────────────────────────────────────────────── reporting ───

// report(n, ms_x100, h0, h1) -- the one-line summary both exits print on
// stderr, on top of the alt screen rather than inside it.  The heap delta is
// the load-bearing number: it is the frame loop's whole memory behaviour,
// measured rather than asserted.
def report(n: long, ms_x100: long, h0: long, h1: long) -> void {
    eputs("mandelbrot: ");
    eputs(tostring(n));
    eputs(" frames, ");
    eputs(tostring(render.threads()));
    eputs(" threads, ");
    eputs(tostring(ms_x100 / 100));
    eputs(".");
    let f = ms_x100 % 100;
    eputs(tostring(f));
    if (f < 10) { eputs("0") };
    eputs(" ms a frame, heap_used ");
    eputs(tostring(h0));
    eputs(" -> ");
    eputs(tostring(h1));
    eputs(" delta ");
    eputs(tostring(h1 - h0));
    eputs("\n")
};

// ──────────────────────────────────────────────────────────── CLI parsing ───

// cpu_count() -> long -- this process's share of the CPUs, from
// sched_getaffinity(2) = syscall 204, which fills a bitmask and leaves the
// count to the reader.  The count is the POPCOUNT of the mask, not the return
// value: the syscall returns 0 on success and -errno on failure, and a
// non-negative return says nothing about how many bits are set.
//
// A /proc read or an environment scan would do as well, but both allocate,
// and a syscall that cannot fail visibly is better for a default.
let CPUB: [byte; 8] = [0; 8];

def cpu_count() -> long {
    if (syscall(204, 0, 8, &CPUB[0]) < 0) { return 4; };
    let pc: long = 0;
    let k: long = 0;
    while (k < 8) {
        let v = CPUB[k];
        let b: long = 0;
        while (b < 8) {
            if (v % 2 == 1) { pc = pc + 1; };
            v = v / 2;
            b = b + 1
        };
        k = k + 1
    };
    if (pc < 1) { return 1; };
    pc
};

// parse_size(s) -> long -- WxH packed as W*1000000 + H, or 0 if the string is
// not that shape.  Slicing rather than a hand-rolled byte scan, because this
// runs once, at start-up, and a string slice is the clearest thing here.
//
// A size is CLAMPED, never refused: --size 0x0 must render one cell and exit 0
// rather than divide by zero somewhere in the projection.  parse_size does the
// clamping and render.setup() clamps again.
def parse_size(s: str) -> long {
    let at = s.index_of("x");
    if (at < 1) { return 0; };
    let a = s[0:at];
    let b = s[at + 1:];
    if (!args.num_ok(a) || !args.num_ok(b)) { return 0; };
    let w = tonum(a);
    let h = tonum(b);
    if (w < 1) { w = 1; };
    if (h < 1) { h = 1; };
    if (w > render.MAXC) { w = render.MAXC; };
    if (h > render.MAXR) { h = render.MAXR; };
    w * 1000000 + h
};

// parse_center(s) -> long -- read "X,Y" into CTX and CTY; answers 1 when the
// string was a coordinate pair.
//
// The answer is in two module-level longs rather than one packed value
// because two Q30 coordinates do not fit in one long -- they are signed and 34
// bits each -- and packing them by hand means losing bits: (x << 2) | (y >>>
// 30) keeps only the top FOUR bits of y, which is a coordinate grid of 16
// values and a visibly wrong picture.  Two variables are free (the heap is an
// arena, but these are globals in .bss) and they cannot lose precision.
//
// Both halves go through mandel.parse_q30(), which is where the range check
// lives: it refuses a malformed string and anything outside [-8, 8], and 8 is
// generous for a centre of this set -- all of it lives inside |c| < 2.1.
let CTX: long = 0;
let CTY: long = 0;

def parse_center(s: str) -> long {
    let at = s.index_of(",");
    if (at < 1) { return 0; };
    let x = mandel.parse_q30(s[0:at]);
    let y = mandel.parse_q30(s[at + 1:]);
    if (x == mandel.Q30_BAD || y == mandel.Q30_BAD) { return 0; };
    CTX = x;
    CTY = y;
    1
};

// ─────────────────────────────────────────────────────────────── the view ───
//
// One place builds the (centre, span) the whole program uses, so --at,
// --center, --zoom and the explorer's keys cannot disagree about it.  Every
// divisor here is a loop count or a clamp, never a runtime value that could be
// zero: `--maxit 0` and `--size 0x0` are the two ways to try to reach one, and
// both are handled before they get here.

// halve(n) -- the span after n halvings.  Halving is exact in Q30, so a
// 48-level zoom is still a clean binary fraction rather than 48 truncations of
// a decimal, and the result never reaches 0 because of the clamp.
def halve(sp: long, n: long) -> long {
    let s2 = sp;
    let k: long = 0;
    while (k < n) { s2 = s2 / 2; k = k + 1; };
    if (s2 < 1) { s2 = 1; };
    s2
};

def build_view() -> void {
    let cx: long = 0;
    let cy: long = 0;
    let sp: long = mandel.SPAN0;
    let last = mandel.place_count() - 1;
    if (PLACE == last) {
        // `random`: a centre drawn from the seed, so --seed 42 is the same
        // picture on every machine and every run.
        mandel.rnd_seed(SEED * 31 + 17);
        cx = mandel.rnd_unit() / 3 - 1;
        cy = mandel.rnd_unit() / 3 - 1;
        sp = mandel.place_span(last);
    } else {
        cx = mandel.place_cx(PLACE);
        cy = mandel.place_cy(PLACE);
        sp = mandel.place_span(PLACE);
    };
    if (HAS_CTR != 0) {
        cx = CTX;
        cy = CTY;
    };
    mandel.md_set(cx, cy, halve(sp, ZOOM), MAXIT)
};

// rezoom() -- apply the current ZOOM to the view as it stands, keeping the
// centre.  This is what `+` and `-` call, so a zoom step does not snap the
// centre back to the named view's.
def rezoom() -> void {
    let sp: long = mandel.place_span(if (PLACE == mandel.place_count() - 1)
                                     { mandel.place_count() - 1 } else { PLACE });
    mandel.md_set(mandel.md_cx(), mandel.md_cy(), halve(sp, ZOOM), MAXIT)
};

args.init("mandelbrot",
          "a threaded Mandelbrot explorer: smooth colouring in Q30 fixed point.",
          OPTS);
let st = args.parse(argv());
if (st == args.HELP) {
    puts(args.usage());
    puts("\nnamed views (--at NAME, or the 0..6 keys in the explorer):\n");
    puts("  full      the whole set, span 3.6 -- what --at defaults to\n");
    puts("  seahorse  the classic spiral valley on the cardioid's flank\n");
    puts("  elephant  the elephant valley, x = +0.2926\n");
    puts("  double    the double spiral on the left lobe\n");
    puts("  spiral    the diagonal arm, x = -0.727\n");
    puts("  needles   a needle at x = -0.1607, y = +1.0376 -- wants --maxit 900\n");
    puts("  random    a centre drawn from --seed's generator\n");
    puts("\ncell glyphs:\n");
    puts("  iter  the glyph follows the colour band, so the exterior draws as\n");
    puts("        repeating contour bands -- the classic text Mandelbrot\n");
    puts("  lum   the glyph follows the palette's own luminance (default: iter)\n");
    puts("\nkeys, interactive:  arrows or hjkl pan, +/- zoom, 0..6 jump to a named\n");
    puts("view, [ and ] change --maxit, r returns to the starting view, q or\n");
    puts("Escape quits.  The window is re-read every 16 frames and follows a\n");
    puts("resize; there is no SIGWINCH in Y to tell us sooner.\n");
    puts("\n--frames N is the deterministic mode: exactly N frames, each at half\n");
    puts("the previous span, a digest per frame, and the frames themselves as\n");
    puts("text.  --threads does not change a single byte of that output.\n");
    exit(0)
};
if (st == args.USAGE) {
    eputs("mandelbrot: try --help\n");
    exit(1)
};

if (len(args.positional()) > 0) {
    die("takes no operands; got '" + args.positional()[0] + "'")
};

// --maxit.  0 is legal and means "every pixel is inside the set": a blank
// frame and a report of inside = cells.  Not an error, and not a trap.
MAXIT = args.get_long("maxit", 240);
if (MAXIT < 0) { MAXIT = 0; };
if (MAXIT > 1000000) { MAXIT = 1000000; };

// --seed, normalised into [0, 2^31) so that --seed -1 is a seed and not a
// complaint.  mandel.rnd_seed() does the same normalisation for the palettes;
// doing it here as well means the value printed in the header is the value
// the generator actually starts from.
let RAW_SEED = args.get_long("seed", 1);
SEED = RAW_SEED % 2147483648;
if (SEED < 0) { SEED = SEED + 2147483648; };
if (SEED == 0) { SEED = 1; };

let SH = args.get_str("shade", "iter");
let shk = index_of(SH, SHADES);
if (shk < 0) { die("--shade wants iter or lum; got '" + SH + "'") };
SHD = shk;

let PK = args.get_str("palette", "blue");
PALKIND = index_of(PK, mandel.PNAMES);
if (PALKIND < 0) {
    die("--palette wants blue, ember, ice, mono, grass or random; got '" + PK + "'")
};

mandel.load_places();
if (mandel.places_ok == 0) {
    die("internal: the named-view table did not parse")
};

let AT = args.get_str("at", "full");
PLACE = index_of(AT, mandel.PLACES);
if (PLACE < 0) {
    die("--at wants one of: full seahorse elephant double spiral needles random")
};

HAS_CTR = if (args.has("center")) { 1 } else { 0 };
if (HAS_CTR != 0) {
    if (parse_center(args.get_str("center", "")) == 0) {
        die("--center wants X,Y in decimal, e.g. --center=-0.743643887,0.131825904")
    }
};

ZOOM = args.get_long("zoom", 0);
if (ZOOM < 0) { ZOOM = 0; };
if (ZOOM > 48) { ZOOM = 48; };

FRAMES = args.get_long("frames", 0);
if (FRAMES < 0) { FRAMES = 0; };
NOTTY = if (args.has("no-tty")) { 1 } else { 0 };
SHOWTIME = if (args.has("time")) { 1 } else { 0 };
CHARS = if (args.has("chars")) { 1 } else { 0 };

build_view();
mandel.set_palette(PALKIND, SEED);

// ─────────────────────────────────────────────────────────────── the grid ───
//
// The size is decided BEFORE anything is built: the surface and the pool must
// agree on it, so both come from these two numbers.
let WANT_THREADS = args.get_long("threads", 0);
if (WANT_THREADS == 0) {
    // The default: this machine's CPUs, capped at 8.  Capped because the
    // spawn cost is real and a 64-core box does not get a better picture out
    // of 64 workers on a 36-row grid -- it gets more synchronisation.
    let ncpu = cpu_count();
    if (ncpu > 8) { ncpu = 8; };
    WANT_THREADS = ncpu
};

let HAVE_SIZE = args.has("size");
if (HAVE_SIZE) {
    let sz = parse_size(args.get_str("size", ""));
    if (sz == 0) { die("--size wants WxH cells, e.g. --size 72x36") };
    GRID_COLS = sz / 1000000;
    GRID_ROWS = sz % 1000000;
} else if (NOTTY != 0) {
    // No terminal to ask, so without --size the size is a fixed default.  That
    // is what makes the deterministic run reproducible on a machine whose
    // window happens to be a different shape, and 72x36 is chosen so one cell
    // is twice as tall as it is wide and the set comes out round.
    GRID_COLS = 72;
    GRID_ROWS = 36;
    if (FRAMES < 1) { FRAMES = 1; };
} else {
    // One row of the terminal is the status line.
    let ws = tui.size();
    GRID_COLS = ws.cols;
    GRID_ROWS = ws.rows - 1;
    if (GRID_ROWS < 2) { GRID_ROWS = 2; };
    if (GRID_COLS < 24) { GRID_COLS = 24; };
};

render.setup(GRID_ROWS, GRID_COLS, WANT_THREADS);
GRID_ROWS = render.grid_rows();
GRID_COLS = render.grid_cols();
if (render.threads_clamped() != 0) {
    warn("--threads " + tostring(WANT_THREADS) + " clamped to "
         + tostring(render.threads()) + "; the useful bounds are 1.."
         + tostring(render.max_threads()))
};

let srf = tui.new(GRID_ROWS, GRID_COLS);

// ══════════════════════════════════════════════ the deterministic path ═══
//
// The same render and the same tui.flush_diff as the terminal path -- the ANSI
// stream is built and counted either way, which is what makes the `ansi`
// column evidence rather than a claim -- except that it goes to /dev/null and
// the text goes to stdout instead.
//
// NO PACING HERE, deliberately.  This path answers "how fast can this machine
// draw", and a sleep in the middle of it would measure nanosleep instead.
if (NOTTY != 0) {
    let devnull = syscall(257, 0 - 100, "/dev/null", 1, 0, 0, 0);   // openat
    if (devnull >= 0) { tui.set_fd(devnull); };
    tui.capture_on();

    textout.out_str("mandelbrot grid ");
    textout.out_num(GRID_COLS);
    textout.out_str("x");
    textout.out_num(GRID_ROWS);
    textout.out_str(" maxit ");
    textout.out_num(MAXIT);
    textout.out_str(" palette ");
    textout.out_str(mandel.PNAMES[PALKIND]);
    textout.out_str(" shade ");
    textout.out_str(SHADES[SHD]);
    textout.out_str(" at ");
    textout.out_str(mandel.place_name(PLACE));
    textout.out_str(" seed ");
    textout.out_num(SEED);
    textout.out_str("\n");
    textout.out_str("frames ");
    textout.out_num(FRAMES);
    textout.out_str(", each halving the span from ");
    textout.out_fixed6(mandel.md_span());
    textout.out_str("; cells/frame ");
    textout.out_num(GRID_ROWS * GRID_COLS);
    textout.out_str("; text glyphs from the byte buffer\n");
    textout.out_str("dumped frames:");

    // Which frames to print in full.  The default is EVERY frame while the
    // count is small, because a digest line per frame with the picture only at
    // the end is a weak determinism test: if the frames were identical the
    // test could not see per-frame state at all.  Past 8 frames the output
    // would be more picture than anyone diffs, so it falls back to the last.
    let dump_s = args.get_str("dump", "");
    if (dump_s == "") {
        let lo: long = 0;
        let hi = FRAMES;
        if (FRAMES > 8) { lo = FRAMES - 1; hi = FRAMES; };
        while (lo < hi) {
            if (NWANT < MAXDUMP) { WANT[NWANT] = lo; NWANT = NWANT + 1; };
            lo = lo + 1
        }
    } else {
        let parts = dump_s.split(",");
        for k in 0..len(parts) {
            let p = parts[k];
            if (len(p) > 0 && args.num_ok(p)) {
                let v = tonum(p);
                // A frame the run will not reach is not a frame it can dump,
                // and listing it in the header would promise something the
                // output does not contain.
                if (v >= 0 && v < FRAMES && !wanted(v)) {
                    if (NWANT < MAXDUMP) { WANT[NWANT] = v; NWANT = NWANT + 1; }
                }
            }
        }
    };
    for k in 0..NWANT {
        textout.out_str(" ");
        textout.out_num(WANT[k])
    };
    if (NWANT == 0) { textout.out_str(" none") };
    textout.out_str("\n");

    let h0 = heap_used();
    let t0 = clock_us();
    // SPAN_BASE is the view's span as the command line asked for it, captured
    // once: frame f is SPAN_BASE halved f times, so frame 0 is the view itself
    // and the frames differ from each other.  Halving the LIVE span each frame
    // instead would start at half and never show the view at all.
    let SPAN_BASE = mandel.md_span();
    let f: long = 0;
    while (f < FRAMES) {
        // Each headless frame is the same view at half the span, so the frames
        // differ and a digest per frame is worth something.
        let s3 = halve(SPAN_BASE, f);
        mandel.md_set(mandel.md_cx(), mandel.md_cy(), s3, MAXIT);

        let iters = render.frame();
        paint(srf);
        tui.capture_reset();
        tui.flush_diff(srf);

        let cells = GRID_ROWS * GRID_COLS;
        let esc = render.escaped();
        textout.out_str("frame ");
        textout.out_pad(f, 4);
        textout.out_str(" span ");
        textout.out_fixed6(s3);
        textout.out_str(" escaped ");
        textout.out_pad(esc, 6);
        textout.out_str(" inside ");
        textout.out_pad(cells - esc, 6);
        textout.out_str(" mean-it-x10 ");
        textout.out_pad((iters * 10) / cells, 6);
        textout.out_str(" ansi ");
        textout.out_pad(tui.frame_bytes(), 7);
        textout.out_str(" sha ");
        textout.out_hex16(render.digest());
        if (wanted(f)) {
            textout.out_str("\n--- frame ");
            textout.out_num(f);
            textout.out_str(" ---\n");
            let r: long = 0;
            while (r < GRID_ROWS) {
                if (CHARS != 0) {
                    textout.out_str(chars_line_row(r));
                    textout.out_str("\n");
                } else {
                    text_line_row(r)
                };
                r = r + 1
            }
        };
        textout.out_str("\n");
        f = f + 1
    };
    let t1 = clock_us();
    let h1 = heap_used();
    textout.out_flush();

    if (SHOWTIME != 0) {
        let el = t1 - t0;
        let per = if (FRAMES > 0) { el / FRAMES } else { 0 };
        report(FRAMES, (per * 100) / 1000, h0, h1);
        eputs("mandelbrot: threads ");
        eputs(tostring(render.threads()));
        eputs(" (requested ");
        eputs(tostring(WANT_THREADS));
        eputs("), ");
        eputs(tostring(el / 1000));
        eputs(" ms for ");
        eputs(tostring(FRAMES));
        eputs(" frames = ");
        eputs(tostring((FRAMES * GRID_ROWS * GRID_COLS * 1000) / (el + 1)));
        eputs(" kcell/s\n");
        if (CHARS != 0) {
            eputs("mandelbrot: dumped frames were built through the str path\n")
        }
    };
    exit(0)
};

// ═══════════════════════════════════════════════════ the interactive path ══
//
// tui's pattern verbatim: raw mode, alt screen, watchdog, and ONE place
// that leaves.  Y has no atexit and no signal handler, so every exit below is
// a call to tui.restore_all_exit() -- there is no path out of this loop that
// does not go through it.  The watchdog is armed BEFORE the pool starts, so
// the child it forks is a copy of a single-threaded process and cannot be
// holding an inherited lock.
if (!tui.raw_mode()) {
    eputs("mandelbrot: not a terminal; try --frames N --no-tty\n");
    exit(1)
};
tui.enter_screen();
tui.arm_watchdog();

let frame: long = 0;
let quit = false;
let checked: long = 0;
let ms_x100: long = 0;
let ih0 = heap_used();

// WSB is a growable [byte] because tui.rd16 takes a [byte] and a [byte; N] is
// NOT a [byte] in Y -- see tui's header.
let WSB: [byte] = [0; 64];

while (quit == false) {
    // A 16 ms deadline rather than a poll: read_key_timeout(0) would spin the
    // CPU flat while nobody is typing, and the render loop below is the only
    // thing that should cost anything when the view has not changed.
    let k = tui.read_key_timeout(16);
    if (k != tui.KEY_NONE) {
        // Keys come back as bytes, so they are compared as bytes: Y has no
        // bare character literal (c'a' is the syntax), so ord() is how a name
        // becomes the byte it means.
        let pan = mandel.md_span() / 8;
        let panx = pan / 2;
        if (k == ord("q") || k == ord("Q") || k == tui.KEY_ESC) {
            quit = true;
        } else if (k == ord("l") || k == tui.KEY_RIGHT) {
            mandel.md_set(mandel.md_cx() + panx, mandel.md_cy(), mandel.md_span(), MAXIT);
            dirty = 1;
        } else if (k == ord("h") || k == tui.KEY_LEFT) {
            mandel.md_set(mandel.md_cx() - panx, mandel.md_cy(), mandel.md_span(), MAXIT);
            dirty = 1;
        } else if (k == ord("k") || k == tui.KEY_UP) {
            mandel.md_set(mandel.md_cx(), mandel.md_cy() + pan, mandel.md_span(), MAXIT);
            dirty = 1;
        } else if (k == ord("j") || k == tui.KEY_DOWN) {
            mandel.md_set(mandel.md_cx(), mandel.md_cy() - pan, mandel.md_span(), MAXIT);
            dirty = 1;
        } else if (k == ord("+") || k == ord("=")) {
            if (ZOOM < 48) { ZOOM = ZOOM + 1; rezoom(); dirty = 1; };
        } else if (k == ord("-") || k == ord("_")) {
            if (ZOOM > 0) { ZOOM = ZOOM - 1; rezoom(); dirty = 1; };
        } else if (k == ord("[") || k == ord("{")) {
            if (MAXIT > 0) {
                MAXIT = MAXIT / 2 + 40;
                mandel.md_set(mandel.md_cx(), mandel.md_cy(), mandel.md_span(), MAXIT);
                dirty = 1
            }
        } else if (k == ord("]") || k == ord("}")) {
            if (MAXIT < 1000000) {
                MAXIT = MAXIT * 2 + 40;
                mandel.md_set(mandel.md_cx(), mandel.md_cy(), mandel.md_span(), MAXIT);
                dirty = 1
            }
        } else if (k == ord("r")) {
            // Back to the view the command line asked for, re-derived from the
            // same flags -- not a hard-coded constant, so `r` means the same
            // thing in every invocation.
            PLACE = index_of(args.get_str("at", "full"), mandel.PLACES);
            if (PLACE < 0) { PLACE = 0; };
            HAS_CTR = if (args.has("center")) { 1 } else { 0 };
            build_view();
            dirty = 1;
        } else if (k >= ord("0") && k <= ord("6")) {
            PLACE = k - ord("0");
            HAS_CTR = 0;
            ZOOM = 0;
            build_view();
            dirty = 1
        };
    };

    // Only a redraw costs anything, so an idle explorer costs nothing: the
    // workers are parked on `wait GO` and no pixel is recomputed until the
    // view, the grid or maxit actually changes.
    if (dirty != 0 && quit == false) {
        let ta = clock_us();
        render.frame();
        paint(srf);
        hud(srf, GRID_ROWS, ms_x100, frame);
        tui.flush_diff(srf);
        ms_x100 = ((clock_us() - ta) * 100) / 1000;
        frame = frame + 1;
        dirty = 0;
        // With --frames on the TERMINAL, each frame is the same zoom step the
        // headless path takes, so the flag means the same thing in both modes
        // and there is something to look at while it runs.  Without it the
        // explorer is still: it redraws only when the view changes, and an idle
        // one costs nothing.
        if (FRAMES > 0 && frame < FRAMES) {
            mandel.md_set(mandel.md_cx(), mandel.md_cy(),
                          mandel.md_span() / 2, MAXIT);
            dirty = 1
        }
    };

    // OUTSIDE the dirty block, and it has to be: with `--frames 60` and no key
    // pressed there is nothing to make the view dirty after the first frame, so
    // a check inside would exit after one frame however many were asked for.
    if (FRAMES > 0 && frame >= FRAMES && quit == false) {
        report(frame, ms_x100, ih0, heap_used());
        tui.restore_all_exit(0)
    };

    // Follow a resize.  Y has no SIGWINCH, so this is a poll -- and tui.size()
    // ANSWERS WITH A RECORD, which is a heap allocation every time the
    // expression is evaluated, so the poll is TIOCGWINSZ into a byte buffer of
    // our own plus tui.rd16: the same decode tui.size() performs, one
    // syscall, zero bytes of heap.
    checked = checked + 1;
    if (checked >= 16) {
        checked = 0;
        if (syscall(16, 1, tui.TIOCGWINSZ, &WSB[0]) >= 0) {
            let nr = tui.rd16(WSB, 0) - 1;
            let nc = tui.rd16(WSB, 2);
            if (nr >= 2 && nc >= 24 && nr <= render.MAXR && nc <= render.MAXC) {
                if (nr != GRID_ROWS || nc != GRID_COLS) {
                    // The pool does not need restarting: a worker's row band is
                    // recomputed from `rows` on every frame.
                    render.resize(nr, nc);
                    GRID_ROWS = nr;
                    GRID_COLS = nc;
                    srf = tui.resize(srf, GRID_ROWS, GRID_COLS);
                    dirty = 1
                }
            }
        }
    }
};

report(frame, ms_x100, ih0, heap_used());
tui.restore_all_exit(0);