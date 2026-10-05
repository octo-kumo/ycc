// hexview.y -- a hex editor and file inspector for the terminal.
//
//   build:  ../../refs/ycc.ref hexview.y -o hexview
//   run:    ./hexview                       the shipped sample, read-only browse
//           ./hexview FILE                  open a file and edit it
//           ./hexview --no-tty              the deterministic inspector dump
//           ./hexview --check               the property check (see selftest.y)
//           ./hexview --check --od          ... plus the GNU od cross-check
//
// WHAT IT IS
// One file, held whole as a [byte] (hx.y holds the model and explains why that
// representation), drawn as
//
//     0000000 68 65 78 76 69 65 77 20 73 61 6d 70 6c 65 00 01  >hexview sample..<
//     ^offset ^two lowercase hex digits per byte, space separated   ^the gutter
//
// -- no-tty prints exactly what `od -A d -t x1z -v` prints, byte for byte,
// which --check proves by running that program and diffing.  Interactively
// the same rows are painted into the toolkit's framebuffer with a cursor, hex
// entry, bookmarks, search and an in-place save.
//
// KEYS (interactive)
//   arrows / hjkl   move the cursor or scroll        g G   first / last byte
//   pageup/pagedown a screen at a time                tab   hex pane / gutter
//   0-9 a-f         type a byte at the cursor (nibble by nibble)
//   m               set / clear a bookmark at the cursor
//   [ ]             previous / next bookmark        x  clear them all
//   n N             next / previous match of the search pattern
//   /               search for the ASCII in the buffer
//   w               write the buffer back to the file it came from
//   x               clear every bookmark      g G  first / last byte
//   h or ?          nothing (they are here so the line is symmetric)
//   q or escape     quit
//
// NOT ONE HEX DIGIT IS BOUND TO ANYTHING.  0-9 and a-f type a byte, because a
// byte is made of them, so every command above is on a key outside that set.
//
// NO PER-FRAME ALLOCATION.  The heap is an arena and nothing is ever freed
// (ORCHESTRATOR.md 2.7), so the frame loop holds no literal: a literal array
// costs 72 bytes and a record 64 every time the expression runs (measured),
// which a per-cell loop would leak by the million.  So the surface, the status
// buffer, the window-size scratch and the row scratch are all module-level, and
// the status line writes digits straight into the status buffer.
// --time prints the heap delta across the frames it drew, so the claim is
// measured rather than asserted.
//
// NO FLOAT AND NO MATH (ORCHESTRATOR.md 2.4): a hex editor is offsets and
// bytes, which are integers already.  There is no `sort`, no `push` and no
// map, so the bookmark list is a fixed [long; 64] with a linear duplicate
// scan and the recent-file list is a fixed [str; 8] ring; both are hand-rolled
// and both are named in the README.

import fb;
import term;
import time;
import args;
import fs;
import hx;
import selftest;

// The shipped file, so `./hexview` opens something and the folder needs nothing
// beside it.  `embed` makes it a const str at compile time; bytes() is the
// whole-file read.
embed SAMPLE from "data/sample.bin";

const NAME = "hexview";

// ───────────────────────────────────────────────────────────── the CLI ───

let OPTS: [args.Opt] = [
    { long: "file", short: "f", kind: args.STR,
      help: "open this file instead of the shipped sample" },
    { long: "width", short: "w", kind: args.NUM,
      help: "bytes per row: 8, 16 or 32 (default 16)" },
    { long: "offset", short: "o", kind: args.NUM,
      help: "first byte to show (default 0)" },
    { long: "rows", short: "r", kind: args.NUM,
      help: "rows to dump; 0 means every row (default 0)" },
    { long: "edit", short: "e", kind: args.STR,
      help: "apply edits before anything else: OFF=HH,OFF=HH,... -- BOTH are hex, and HH is exactly two digits" },
    { long: "save", short: "s", kind: args.STR,
      help: "write the (edited) buffer to this path" },
    { long: "dump", short: "d", kind: args.BOOL,
      help: "print the od-compatible dump and exit (the default under --no-tty)" },
    { long: "hist", short: "", kind: args.BOOL,
      help: "also print a byte-value histogram" },
    { long: "check", short: "k", kind: args.BOOL,
      help: "the property check: gutter, offsets, round-trip, bounds, error paths" },
    { long: "od", short: "", kind: args.BOOL,
      help: "with --check, cross-check the dump against GNU `od -A d -t x1z -v`" },
    { long: "no-tty", short: "", kind: args.BOOL,
      help: "headless: print the dump and exit, no terminal" },
    { long: "frames", short: "n", kind: args.NUM,
      help: "draw exactly N frames, then exit 0 (default 0: run until q)" },
    { long: "bench", short: "", kind: args.NUM,
      help: "time N passes of the row formatter over the open file and report MB/s" },
    { long: "time", short: "", kind: args.BOOL,
      help: "timings and the heap delta on stderr" }
];

// ─────────────────────────────────────────────── the one output buffer ───
//
// stdout is buffered into a module-level array so a dump of a large file is a
// handful of write(2)s rather than one per row, and so the row formatter's
// output can be counted in bytes for the summary line.  Nothing here allocates
// after the module is loaded.
const OUTCAP = 65536;
let OUT: [byte; 65536] = [0; 65536];
let OUTN: long = 0;
let OUTBYTES: long = 0;                   // bytes actually written
let OUTERR: long = 0;                     // 1 once a write(2) has failed
let D10: [byte; 24] = [0; 24];            // decimal digit scratch

def ob(v: long) {
    if (OUTN < OUTCAP) { OUT[OUTN] = v; OUTN = OUTN + 1; }
};

// A row is at most hx.LINECAP (256) bytes, so flushing "nearly full" is
// enough: if there were room for a row there is room for a whole row.
const ROWRESERVE = 300;

def oflush() -> long {
    let done = 0;
    while (done < OUTN) {
        let w = syscall(1, 1, ptr_addr(&OUT[done]), OUTN - done);
        if (w <= 0) { OUTERR = 1; done = OUTN; } else { done = done + w; }
    };
    OUTBYTES = OUTBYTES + done;
    OUTN = 0;
    done
};

def ostr(s: str) {
    if (OUTN > OUTCAP - ROWRESERVE) { oflush(); };
    let i = 0;
    while (i < len(s)) { ob(s[i]); i = i + 1; }
};

// A decimal number, straight into the output buffer.  A `str` built per number
// would allocate; this allocates nothing (ORCHESTRATOR.md 2.7).
def onum(v: long) {
    if (v < 0) { ob(45); v = 0 - v; };
    if (v == 0) { ob(48); return 0; };
    let k = 0;
    let x = v;
    while (x > 0) { D10[k] = 48 + (x % 10); x = x / 10; k = k + 1; };
    while (k > 0) { k = k - 1; ob(D10[k]); };
    0
};

// hx.LINE, verbatim, followed by a newline.  This is the whole of the dump.
def orow() -> long {
    if (OUTN > OUTCAP - ROWRESERVE) { oflush(); };
    let i = 0;
    while (i < hx.LINEN) { ob(hx.LINE[i]); i = i + 1; };
    ob(10);
    hx.LINEN
};

// ─────────────────────────────────────────────────────── open and edit ───

let WIDTH: long = 16;
let SHOW_FROM: long = 0;
let SHOW_ROWS: long = 0;                  // 0 = every row
let HIST: long = 0;
let NOTTY: long = 0;
let FRAMES: long = 0;
let SHOWTIME: long = 0;
let BENCH: long = 0;
let WANT_OD: long = 0;
let SOURCE: str = "data/sample.bin (embedded)";
let ROWS_OUT: long = 0;                   // rows the dump printed

// Which file the buffer came from, so `w` in the interactive path knows where to
// write and so a save to a *different* path is visible in the summary.
let PATH: str = "";
let SAVED_TO: str = "";
let EDITS: long = 0;

// Open the target: --file, else the first positional, else the embedded sample.
// Every refusal is a message and a non-zero status (see `die`).
def open_target() -> long {
    PATH = args.get_str("file", "");
    let pos = args.positional();
    if (len(PATH) == 0 && len(pos) > 0) { PATH = pos[0]; };
    if (len(pos) > 1) {
        eputs(NAME + ": one file at a time; got " + tostring(len(pos)) + "\n");
        return 2
    };
    if (len(PATH) == 0) {
        hx.adopt(bytes(SAMPLE));
        SOURCE = "data/sample.bin (embedded)";
        return 0
    };
    if (!hx.open_path(PATH)) {
        eputs(NAME + ": " + hx.ERRS + "\n");
        return 2
    };
    SOURCE = PATH;
    0
};

// `--edit OFF=HH,OFF=HH,...`.  Each field is validated before any byte is
// written, so a bad field half way down the list does not leave the buffer half
// edited: the offsets and values are collected first, then applied.
let MAXEDITS = 256;
let E_OFF: [long; 256] = [0; 256];
let E_VAL: [long; 256] = [0; 256];

def apply_edits(spec: str) -> long {
    if (len(spec) < 1) {
        eputs(NAME + ": --edit wants OFF=HH,OFF=HH,...\n");
        return 2
    };
    // No whole-string pre-scan.  There was one, rejecting anything that is not a
    // hex digit, '=' or ',', and it made the per-field "is not a hex offset"
    // check below DEAD -- the pre-scan had already refused every input that
    // could reach it, so `--edit zz=1` said "unexpected character in 'zz=1'"
    // instead of naming the field.  Validating per field gives a better message
    // and one reachable branch instead of two, one of them unreachable.
    let fields = spec.split(",");
    let n = 0;
    let f = 0;
    while (f < len(fields)) {
        let s = fields[f];
        let eq = s.index_of("=");
        if (eq < 1 || eq >= len(s) - 1) {
            eputs(NAME + ": --edit: '" + s + "' is not OFF=HH\n");
            return 2
        };
        let otext = s[0:eq];
        let vtext = s[eq + 1:len(s)];
        // 16 hex digits is 64 bits, which is what the accumulator below holds.
        // Without this bound, `--edit 1000000000000000000=ff` (0x1_0000_0000_0000_0000)
        // wraps to zero and edits byte 0 in silence -- the one failure mode a hex
        // editor must never have.
        if (len(otext) > 16) {
            eputs(NAME + ": --edit: the offset '" + otext
                  + "' is more than 16 hex digits\n");
            return 2
        };
        let j = 0;
        while (j < len(otext)) {
            let d = hx.hexdig_of(otext[j]);
            if (d < 0) {
                eputs(NAME + ": --edit: '" + otext + "' is not a hex offset\n");
                return 2
            };
            j = j + 1;
        };
        let v = hx.hexval(vtext);
        if (v < 0) {
            eputs(NAME + ": --edit: '" + vtext + "' is not two hex digits\n");
            return 2
        };
        if (n >= MAXEDITS) {
            eputs(NAME + ": --edit: at most " + tostring(MAXEDITS) + " edits\n");
            return 2
        };
        // The offset may be written in hex, so 'ff' is 255 and '100' is 256.
        let o = 0;
        let k = 0;
        while (k < len(otext)) {
            o = o * 16 + hx.hexdig_of(otext[k]);
            k = k + 1;
        };
        E_OFF[n] = o;
        E_VAL[n] = v;
        n = n + 1;
        f = f + 1;
    };
    // Nothing is written until every field has parsed.
    let a = 0;
    while (a < n) {
        let e = hx.set(E_OFF[a], E_VAL[a]);
        if (e != 0) {
            eputs(NAME + ": --edit: offset " + tostring(E_OFF[a]) + ": "
                  + hx.set_errname(e) + "\n");
            return 2
        };
        a = a + 1;
    };
    EDITS = n;
    0
}

// ─────────────────────────────────────────────────────────── the dump ───

// How many rows the dump will print, as a pure function of the request.  The
// summary line is printed BEFORE the dump (it is the header of the output), so
// the count has to be computed rather than counted on the way past -- and then
// `dump` has to produce exactly this many, which --check asserts.
def plan_rows(from: long, nrows: long) -> long {
    let avail = 0;
    if (from < hx.SIZE) { avail = hx.SIZE - from; };
    let n = (avail + WIDTH - 1) / WIDTH;
    if (nrows > 0 && nrows < n) { n = nrows; };
    n
};

// Print the od-compatible dump from `from` for `nrows` rows (all of them when
// nrows is 0 or negative), then the trailing size line.
def dump(from: long, nrows: long) -> long {
    ROWS_OUT = 0;
    if (from < 0) { from = 0; };
    let off = from;
    let stop = false;
    while (!stop) {
        if (off >= hx.SIZE) { stop = true; } else {
            if (nrows > 0 && ROWS_OUT >= nrows) { stop = true; } else {
                hx.row(off, WIDTH);
                orow();
                ROWS_OUT = ROWS_OUT + 1;
                off = off + WIDTH;
            }
        }
    };
    hx.end_line();
    orow();
    oflush();
    ROWS_OUT
};

// A byte-value histogram: 16 rows of 16 counters, then the total.  The total
// must equal the file's length, which --check reads from fs.file_size -- i.e.
// from the operating system, not from this program.
const HIST16 = 16;
let HBUCK: [long; 256] = [0; 256];
let HTOT: long = 0;

def hist_reset() {
    let i = 0;
    while (i < 256) { HBUCK[i] = 0; i = i + 1; };
    HTOT = 0
};

def hist_count() {
    let i = 0;
    while (i < hx.SIZE) { HBUCK[hx.DATA[i]] = HBUCK[hx.DATA[i]] + 1; i = i + 1; };
    HTOT = hx.SIZE
};

def hist_print() {
    let r = 0;
    while (r < HIST16) {
        // The row label, "%02x-%02x ", written as digits.
        ostr("  ");
        ob(hx.hexdig(r / 16));
        ob(hx.hexdig(r % 16));
        ostr("-");
        ob(hx.hexdig(r));
        ob(hx.hexdig(15));
        ostr("  ");
        let c = 0;
        while (c < HIST16) {
            let v = HBUCK[r * HIST16 + c];
            // Four wide, right-aligned, zero filled -- the classic layout.
            let d = hx.digits(v);
            if (d > 4) { onum(v); } else {
                let p = 4 - d;
                while (p > 0) { ostr(" "); p = p - 1; };
                onum(v);
            };
            if (c < HIST16 - 1) { ostr(" "); };
            c = c + 1;
        };
        ostr("\n");
        r = r + 1;
    };
    ostr("  total  ");
    onum(HTOT);
    ostr("\n");
    oflush()
};

// ───────────────────────────────────────────────────────────── the run ───

// The summary line the dump mode prints first.  Every number in it is derived
// from the buffer, and --check re-derives the same numbers from the file on
// disk.
def print_head() {
    ostr(NAME);
    ostr("  ");
    ostr(SOURCE);
    ostr("\n");
    ostr("  ");
    onum(hx.SIZE);
    ostr(" bytes, width ");
    onum(WIDTH);
    ostr(", from ");
    onum(SHOW_FROM);
    ostr(", ");
    onum(ROWS_OUT);
    if (ROWS_OUT == 1) { ostr(" row\n"); } else { ostr(" rows\n"); };
    oflush()
};

// The deterministic mode: --no-tty, and the default when stdout is not a
// terminal and no frame count was asked for.
def run_dump() -> long {
    ROWS_OUT = plan_rows(SHOW_FROM, SHOW_ROWS);
    print_head();
    let got = dump(SHOW_FROM, SHOW_ROWS);
    if (EDITS > 0) {
        ostr("  ");
        onum(EDITS);
        if (EDITS == 1) { ostr(" edit applied"); } else { ostr(" edits applied"); };
        if (hx.DIRTY == 1) { ostr(", buffer dirty"); };
        ostr("\n");
    };
    if (len(SAVED_TO) > 0) {
        ostr("  written ");
        onum(hx.SIZE);
        ostr(" bytes to ");
        ostr(SAVED_TO);
        ostr("\n");
    };
    if (got != ROWS_OUT) {
        // A row count that disagrees with the plan is a bug in this file, and
        // saying so is better than printing a wrong count.
        ostr("  hexview: internal: planned ");
        onum(ROWS_OUT);
        ostr(" rows, printed ");
        onum(got);
        ostr("\n");
        oflush();
        return 4
    };
    if (HIST == 1) {
        hist_reset();
        hist_count();
        hist_print();
    };
    if (SHOWTIME == 1) {
        eputs(NAME + ": wrote " + tostring(OUTBYTES) + " bytes, heap "
              + tostring(heap_used()) + "\n");
    };
    0
};

// A throughput number: `passes` passes of the row formatter over the open
// file, reported as MB/s.  It formats into hx.LINE and never writes, so the
// number measures the formatter and not the terminal.
def run_bench(passes: long) -> long {
    if (passes < 1) { passes = 1; };
    if (hx.SIZE < 1) {
        eputs(NAME + ": nothing to bench: the file is empty\n");
        return 2
    };
    let rows = 0;
    let off = 0;
    while (off < hx.SIZE) { hx.row(off, WIDTH); off = off + WIDTH; rows = rows + 1; };
    let t0 = time.now_us();
    let nrows = 0;
    let p = 0;
    while (p < passes) {
        let o = 0;
        while (o < hx.SIZE) { hx.row(o, WIDTH); nrows = nrows + 1; o = o + WIDTH; };
        p = p + 1;
    };
    let dt = time.now_us() - t0;
    if (dt < 1) { dt = 1; };
    // MB/s in thousandths, in integers: no float and no division that loses
    // precision.  bytes / microseconds IS bytes per second / 1e6 IS MB/s, so
    // (bytes * 1000) / microseconds is MB/s x 1000.  (The first draft of this
    // line carried a stray 1000 twice and reported 54 GB/s for what is 54 MB/s.
    // A throughput number that is a thousand times too big is the sort of thing
    // nobody checks, so the arithmetic is written out rather than folded.)
    let total = hx.SIZE * passes;
    let mb_x1000 = (total * 1000) / dt;
    eputs(NAME + ": bench " + tostring(hx.SIZE) + " bytes x " + tostring(passes)
          + " passes = " + tostring(nrows) + " rows in " + tostring(dt / 1000)
          + " ms, " + tostring(mb_x1000 / 1000) + "."
          + three_digits(mb_x1000 % 1000) + " MB/s, heap "
          + tostring(heap_used()) + "\n");
    0
};

// The last three digits of a rate, zero-padded, so 54.3 does not print as 54.300
// by accident and 4 does not print as 54.4.
def three_digits(v: long) -> str {
    if (v < 100) { return "0" + two_digits(v); };
    two_digits(v)
};

def two_digits(v: long) -> str {
    if (v < 10) { return "0" + tostring(v); };
    tostring(v)
};

// ─────────────────────────────────────────────────────────── the check ───

def run_check() -> long {
    selftest.run(WANT_OD == 1, progpath())
};

// The path of this program, for --check's child-process sections.  argv()[0]
// may be bare (`hexview`), which /bin/sh would look up in PATH, so a name with
// no '/' in it gets a './' in front.
let PROGPATH: str = "";

def progpath() -> str {
    if (len(PROGPATH) > 0) { return PROGPATH; };
    let a = argv();
    let p = "";
    if (len(a) > 0) { p = a[0]; };
    if (len(p) < 1) { p = "hexview"; };
    if (p.index_of("/") < 0) { p = "./" + p; };
    PROGPATH = p;
    PROGPATH
};

// ────────────────────────────────────────────────────── interactive ───
//
// The window, the cursor and the two panes.  Everything is module-level and
// sized by a literal: the frame loop must not contain a literal of any kind
// (ORCHESTRATOR.md 2.7 -- an array costs 72 bytes and a record 64 every time the
// expression runs), and the status line is assembled into one fixed byte buffer
// rather than into a `str`.
//
// LAYOUT, for a window of R rows and C columns:
//
//   row 0        title:  hexview  <source>  <n> bytes  [modified]
//   rows 1..R-4  one line per WIDTH bytes, in the same shape as the dump, so
//                what the interactive view shows and what --dump prints are the
//                same layout at the same widths:
//                  <offset><' '><3*WIDTH hex><2 pad><'><gutter><'<'
//   row R-3      a rule
//   row R-2      status: cursor offset, the byte under it, the pane, the
//                bookmarks, the last search hit, or a message
//   row R-1      the key line, or the open/search prompt
//
// COLUMNS NEEDED for one row: 9 + 3*WIDTH + 2 + WIDTH + 2, which is 76 at
// WIDTH 16, 44 at 8 and 139 at 32.  A narrower window clips the right-hand end
// rather than wrapping, so the offset column stays put.

const VIEW_FPS = 30;
const MAXMARKS = 64;
const MAXPAT = 96;
const MAXPATH = 256;
const RULECOL = 0x003040;                  // the rule under the panes
let SURF: fb.Surface = fb.new(24, 80);
let WROWS: long = 24;
let WCOLS: long = 80;
let WSBUF: [byte; 64] = [0; 64];           // the winsize scratch, not term.size()

// Cursor state.
let CUR: long = 0;                         // the byte the cursor is on
let TOP: long = 0;                         // the first byte on screen
let PANE: long = 0;                        // 0 = hex, 1 = gutter
let NIBBLE: long = 0;                      // 0: high nibble next, 1: low
let NIBVAL: long = 0;                      // what the high nibble was
let HITS: long = 0;                        // 0 = normal, 1 = open, 2 = search
let DIRTYF: long = 0;                      // 1 = the view must be redrawn
let FRAMES_DRAWN: long = 0;
let HEAP0: long = 0;

// Bookmarks.  A fixed [long; MAXMARKS] and a linear duplicate scan: the language
// has no push, no pop and no map, so "is this offset already marked" is a loop
// over the array and "add one" is an index assignment.  That is the whole
// hand-roll, and it is four lines.
let MARKS: [long; 64] = [0; 64];
let NMARKS: long = 0;
let MARKI: long = 0;

// The search pattern, and the recent-file list.  RECENT is a variable-length
// [str] kept at MAXREC entries long; `*=` prepends (there is no push in this
// language -- ORCHESTRATOR.md §2.10) and the tail is dropped by slicing.
const MAXREC = 8;
let RECENT: [str] = [];

// The line buffer the status line is assembled into.  A [byte; 256] at module
// scope, never a str built per frame (ORCHESTRATOR.md 2.7: fb.text plus a
// freshly built string costs ~2.4 KB a frame).
let SBUF: [byte; 256] = [0; 256];
let SN: long = 0;
let PAT: [byte; 96] = [0; 96];
let PATN: long = 0;
let PATHBUF: [byte; 256] = [0; 256];
let PATHN: long = 0;
let P10: [long; 8] = [1, 10, 100, 1000, 10000, 100000, 1000000, 10000000];
let LASTHIT: long = 0 - 1;
// A message to show on the status line until the next keypress.  The
// interactive path's error channel: a bad open, a refused write, an edit at the
// end of the file.  All of them a line of text and no exit -- an editor that
// quits because you typed a bad path is not an editor.
let MSG: [byte; 200] = [0; 200];
let MSGN: long = 0;
let RUNNING: long = 1;
let REDRAW_ALL: long = 1;   // set by a resize: the next frame repaints in full

// Colours.  Truecolour, from the toolkit's rgb(); a terminal without it shows
// the same layout in its own eight.
let C_BG: long = 0x000c10;
let C_OFF: long = 0x006070;                // the offset column
let C_HEX: long = 0x00c0d0;
let C_GUT: long = 0x0090a0;
let C_RULE: long = RULECOL;
let C_TITLE: long = 0x00e0e0;
let C_KEYS: long = 0x006a7a;
let C_MSG: long = 0x00ff88;
let C_SEL: long = 0x0060a0;                // the cursor cell's background
let C_ZERO: long = 0x00a0a0;               // a byte that is 0x00
let C_LAST: long = 0x00e080;               // the last byte of a row

// ── the two scratch writers ──
//
// sb* append to SBUF, the status line.  sput then walks SBUF into the
// surface.  Neither allocates: this is the path a frame takes, twice.

def sb(v: long) {
    if (SN < 256) { SBUF[SN] = v; SN = SN + 1; }
};

def sbs(t: str) {
    let i = 0;
    while (i < len(t)) { sb(t[i]); i = i + 1; }
};

def sbn(v: long) {
    if (v < 0) { sb(45); v = 0 - v; };
    if (v == 0) { sb(48); return 0; };
    let k = 0;
    let x = v;
    while (x > 0) { D10[k] = 48 + (x % 10); x = x / 10; k = k + 1; };
    while (k > 0) { k = k - 1; sb(D10[k]); };
    0
};

// An offset in hex without the leading zeros -- the status line shows 0x0,
// not 0x0000000.  `>>` and not `>>>`: the shift is on a value that is never
// negative here, and `>>>` is a LOGICAL shift (ORCHESTRATOR.md §2.10).
def sbx(v: long) {
    sbs("0x");
    let started = 0;
    let sh = 28;
    while (sh >= 0) {
        let d = (v >> sh) & 15;
        if (d > 0 || started == 1) {
            sb(hx.hexdig(d));
            started = 1;
        };
        sh = sh - 4;
    };
    if (started == 0) { sb(48); };
    0
};

def sbclr() {
    SN = 0
};

// SBUF -> the surface, one cell at a time.  `fb.text` wants a str, and a str
// made per frame is the 2.4 KB leak ORCHESTRATOR.md 2.7 warns about, so the
// cells are put directly.
def sput(row: long, col: long, fg: long) -> long {
    let i = 0;
    while (i < SN) {
        fb.put(SURF, row, col + i, SBUF[i], fg, C_BG);
        i = i + 1;
    };
    SN
};

// ── the window size ──
//
// term.size() answers a fresh record per call (~40 B), so a per-frame resize
// poll with it leaks; this reads TIOCGWINSZ into a module-level buffer instead.
def poll_winsize() -> bool {
    for i in 0..8 { WSBUF[i] = 0; };
    let changed = false;
    if (syscall(16, 1, term.TIOCGWINSZ, &WSBUF[0]) >= 0) {
        let r = (WSBUF[0] & 255) | ((WSBUF[1] & 255) << 8);
        let c = (WSBUF[2] & 255) | ((WSBUF[3] & 255) << 8);
        if (r > 0 && c > 0 && (r != WROWS || c != WCOLS)) {
            WROWS = r;
            WCOLS = c;
            changed = true;
        }
    };
    if (changed && WROWS > 2 && WCOLS > 4) {
        SURF = fb.resize(SURF, WROWS, WCOLS);
        // A resize invalidates the shadow, so the next frame repaints in full.
        REDRAW_ALL = 1;
    };
    changed
};

// The cell a byte starts in, on a line of WIDTH bytes.
def hex_col(i: long) -> long {
    10 + i * 3
};

def gut_col(i: long) -> long {
    10 + WIDTH * 3 + 2 + i
};

// Which of the WIDTH columns of the line the cursor is on, 0..WIDTH-1.
def cursor_i() -> long {
    let i = CUR - TOP;
    if (i < 0) { i = 0; };
    if (i >= WIDTH) { i = WIDTH - 1; };
    i
};

// Where the cursor's cell is, given the pane.
def cursor_col() -> long {
    if (PANE == 0) { return hex_col(cursor_i()); };
    gut_col(cursor_i())
};

// How many bytes one screen of this window shows.
def view_rows() -> long {
    let n = WROWS - 5;
    if (n < 1) { n = 1; };
    n
};

// ── bookmarks ──

def mark_find(off: long) -> long {
    let i = 0;
    while (i < NMARKS) {
        if (MARKS[i] == off) { return i; };
        i = i + 1;
    };
    0 - 1
};

// Add the offset, or take it out again if it is already there.  A toggle, which
// is what a bookmark key wants.  When the array is full the oldest is dropped,
// so the list never grows past MAXMARKS and never allocates.
def mark_toggle(off: long) -> long {
    let at = mark_find(off);
    if (at >= 0) {
        let i = at;
        while (i + 1 < NMARKS) { MARKS[i] = MARKS[i + 1]; i = i + 1; };
        NMARKS = NMARKS - 1;
        if (MARKI >= NMARKS) { MARKI = 0; };
        return at
    };
    if (NMARKS >= MAXMARKS) {
        let i = 0;
        while (i + 1 < NMARKS) { MARKS[i] = MARKS[i + 1]; i = i + 1; };
        NMARKS = NMARKS - 1;
    };
    MARKS[NMARKS] = off;
    MARKI = NMARKS;
    NMARKS = NMARKS + 1;
    NMARKS - 1
};

def mark_clear() {
    NMARKS = 0;
    MARKI = 0
};

def mark_step(dir: long) -> long {
    if (NMARKS < 1) { return 0 - 1; };
    MARKI = MARKI + dir;
    if (MARKI < 0) { MARKI = NMARKS - 1; };
    if (MARKI >= NMARKS) { MARKI = 0; };
    MARKS[MARKI]
};

// ── the recent-file list ──
//
// There is no push and no pop.  `*=` prepends one element (an array that holds
// strings), and the tail is dropped with a slice -- so this is the whole array
// interface, used where the language has nothing else to offer.  It costs one
// array per OPEN, which happens at most a handful of times in a session and
// never in the frame loop.
def recent_add(p: str) -> void {
    if (recent_at(0) == p) { return; };
    RECENT *= p;
    while (len(RECENT) > MAXREC) {
        RECENT = RECENT[0:len(RECENT) - 1];
    };
    0
};

def recent_at(i: long) -> str {
    if (i < 0 || i >= len(RECENT)) { return ""; };
    RECENT[i]
};

// ── drawing ──

def draw_title() -> void {
    fb.clear(SURF, C_BG);
    sbclr();
    sbs(NAME);
    sb(32);
    sbs(SOURCE);
    sb(32);
    sbn(hx.SIZE);
    sbs(" bytes");
    if (hx.DIRTY == 1) { sbs("  [modified]"); };
    sput(0, 0, C_TITLE);
    fb.hline(SURF, WROWS - 3, 0, WCOLS, 9472, C_RULE, C_BG);
    0
};

// One line of WIDTH bytes at file offset `base`, at screen row `row`.  The
// cursor cell gets the selection background; a 0x00 byte is tinted so a run of
// zeros is findable at a glance; the last byte of the row is marked.
def draw_row(row: long, base: long) -> void {
    // The offset column, eight DECIMAL digits and two spaces -- the same base the
    // dump prints, so the interactive view and `--dump` are one layout rather
    // than two.  (This was hex at first, and having the two disagree about what
    // an offset looks like turned out to be a distraction with no upside.)
    let d = hx.digits(base);
    let i = 0;
    while (i < 8) {
        let sh = 7 - i;
        let dg = 0;
        if (sh < d) { dg = (base / P10[sh]) % 10; };
        fb.put(SURF, row, i, 48 + dg, C_OFF, C_BG);
        i = i + 1;
    };
    fb.put(SURF, row, 8, 32, C_OFF, C_BG);
    fb.put(SURF, row, 9, 32, C_OFF, C_BG);
    let k = 0;
    while (k < WIDTH && base + k < hx.SIZE) {
        let v = hx.byte_at(base + k);
        let fg = C_HEX;
        if (v == 0) { fg = C_ZERO; };
        if (base + k == hx.SIZE - 1) { fg = C_LAST; };
        let hb = hx.hexdig(v / 16);
        let lb = hx.hexdig(v % 16);
        let col = hex_col(k);
        let here = base + k == CUR;
        // The nibble the cursor is on, when the hex pane is active.
        let mark_hi = here && PANE == 0 && NIBBLE == 0;
        let mark_lo = here && PANE == 0 && NIBBLE == 1;
        let bg = C_BG;
        if (here && PANE == 0) { bg = C_SEL; };
        if (mark_hi) { fb.put(SURF, row, col, hb, 16, C_SEL); } else {
            fb.put(SURF, row, col, hb, fg, bg);
        };
        if (mark_lo) { fb.put(SURF, row, col + 1, lb, 16, C_SEL); } else {
            fb.put(SURF, row, col + 1, lb, fg, bg);
        };
        let g = hx.glyph(v);
        let gfg = C_GUT;
        if (g == hx.DOT) { gfg = C_ZERO; };
        let gbg = C_BG;
        if (here && PANE == 1) { gbg = C_SEL; };
        fb.put(SURF, row, gut_col(k), g, gfg, gbg);
        k = k + 1;
    };
    if (base < hx.SIZE) {
        fb.put(SURF, row, hex_col(0) - 1, 62, C_RULE, C_BG);
        fb.put(SURF, row, gut_col(0) - 1, 62, C_RULE, C_BG);
    };
    if (mark_find(base) >= 0 || mark_find(base + WIDTH - 1) >= 0) {
        // A bookmarked row says so on the rule line under the offset.
        fb.put(SURF, row, 0, 42, C_MSG, C_BG);
    };
    0
};

// The status line's colour: a prompt or a message is loud, the readout is not.
def status_col() -> long {
    if (HITS == 0 && MSGN == 0) { return C_HEX; };
    C_MSG
};

def draw_status() -> void {
    let row = WROWS - 2;
    let line = WROWS - 1;
    sbclr();
    if (HITS == 1) {
        sbs("open: ");
        sbs(from_bytes(PATHBUF[0:PATHN]));
    } else if (HITS == 2) {
        sbs("search: ");
        sbs(from_bytes(PAT[0:PATN]));
    } else if (MSGN > 0) {
        sbs(NAME);
        sbs(": ");
        sbs(from_bytes(MSG[0:MSGN]));
    } else {
        sbs("off ");
        sbx(CUR);
        if (CUR < hx.SIZE) {
            sbs("  byte ");
            sb(hx.hexdig(hx.byte_at(CUR) / 16));
            sb(hx.hexdig(hx.byte_at(CUR) % 16));
            sbs("  '");
            sb(hx.glyph(hx.byte_at(CUR)));
            sbs("'");
        } else {
            sbs("  (past the end)");
        };
        sbs("  pane ");
        if (PANE == 0) { sbs("hex"); } else { sbs("gutter"); };
        sbs("  marks ");
        sbn(NMARKS);
        if (NMARKS > 0) {
            sbs(" @");
            sbn(MARKS[MARKI]);
        };
        if (PATN > 0) {
            sbs("  find ");
            sbn(PATN);
            sbs("B");
            if (LASTHIT >= 0) { sbs(" last "); sbn(LASTHIT); };
        };
    };
    sput(row, 0, status_col());
    sbclr();
    if (HITS != 0) {
        sbs("enter accept   backspace erase   esc cancel");
    } else {
        // TWO calls, not one call with a `+` between two literals.  This line
        // was written the other way and cost 136 bytes A FRAME -- the `+` builds
        // a fresh str on the heap every time the expression runs, because sbs
        // takes a str and the concatenation has to exist before it does.  It is
        // the string form of the hard rule in ORCHESTRATOR.md §2.7 ("hoist every literal out
        // of every loop"), and `--frames 120 --time` is what measured it: the
        // heap delta went 512 -> 512 once this was split.
        sbs("arrows/hjkl move  tab pane  0-9a-f type  m mark  [ ] marks  ");
        sbs("/ find  n N next  o open  w write  g G ends  q quit");
    };
    sput(line, 0, C_KEYS);
    0
};

def draw() -> long {
    let rows = view_rows();
    // Keep the cursor on screen: TOP is the first byte, a multiple of WIDTH so
    // the offset column stays aligned.
    if (CUR < TOP) { TOP = CUR - (CUR % WIDTH); };
    if (CUR >= TOP + WIDTH * rows) { TOP = CUR - (CUR % WIDTH) - (rows - 1) * WIDTH; };
    if (TOP < 0) { TOP = 0; };
    draw_title();
    let r = 0;
    while (r < rows) {
        let row = 1 + r;
        if (row < WROWS - 3) {
            let base = TOP + r * WIDTH;
            if (base < hx.SIZE) { draw_row(row, base); };
        };
        r = r + 1;
    };
    draw_status();
    term.cursor_to(cursor_row(), cursor_col());
    if (REDRAW_ALL == 1) { fb.flush(SURF); REDRAW_ALL = 0; } else { fb.flush_diff(SURF); };
    FRAMES_DRAWN = FRAMES_DRAWN + 1;
    DIRTYF = 0;
    FRAMES_DRAWN
};

def cursor_row() -> long {
    let r = (CUR - TOP) / WIDTH;
    1 + r
};

// ── editing ──

// Type one hex digit at the cursor.  The high nibble waits for the low one, so
// 'f' 'f' writes 0xff, and the byte is stored by hx.set -- which is the
// element store `DATA[off] = v`, zero bytes, no struct writer needed
// (SUGGESTIONS.md #9).
def type_hex(c: long) -> long {
    let d = hx.hexdig_of(c);
    if (d < 0) { return 0 - 1; };
    if (CUR < 0 || CUR >= hx.SIZE) { return hx.E_PAST; };
    if (NIBBLE == 0) {
        NIBVAL = d * 16;
        NIBBLE = 1;
        return 0
    };
    let e = hx.set(CUR, NIBVAL + d);
    NIBBLE = 0;
    NIBVAL = 0;
    if (e == 0) { step(1); };
    e
};

def step(n: long) -> void {
    let c = CUR + n;
    if (c < 0) { c = 0; };
    if (hx.SIZE > 0 && c > hx.SIZE - 1) { c = hx.SIZE - 1; };
    CUR = c;
    NIBBLE = 0;
    NIBVAL = 0;
    0
};

// ── search ──

def search_from(from: long, dir: long) -> long {
    if (PATN < 1) { return 0 - 1; };
    if (dir >= 0) {
        let at = hx.find_text(from_bytes(PAT[0:PATN]), from);
        if (at >= 0) { LASTHIT = at; CUR = at; return at };
        return 0 - 1
    };
    // Backwards: scan the candidate starts from 0, keeping the last hit strictly
    // before `from`.  A linear re-scan rather than a reversed search, because
    // there is no reverse find in the language.
    let pat = from_bytes(PAT[0:PATN]);
    let best = 0 - 1;
    let i = 0;
    while (i + PATN <= hx.SIZE) {
        if (i < from) {
            let j = 0;
            let same = 1;
            while (j < PATN) {
                if (hx.DATA[i + j] != pat[j]) { same = 0; };
                j = j + 1;
            };
            if (same == 1) { best = i; };
        };
        i = i + 1;
    };
    if (best >= 0) { LASTHIT = best; CUR = best };
    best
};

// ── the loop ──

// Every exit from here goes through term.restore_all_exit(), and the watchdog is
// armed, so a signal still puts the terminal back (ORCHESTRATOR.md 2.3).
def run_interactive() -> long {
    if (!term.raw_mode()) {
        eputs(NAME + ": not a terminal (stdin); use --no-tty for the dump\n");
        return 2
    };
    term.arm_watchdog();
    term.enter_screen();
    fb.set_fd(1);
    poll_winsize();
    SURF = fb.resize(SURF, WROWS, WCOLS);
    let pacer = time.pacer_new(VIEW_FPS);
    let rc = 0;
    HEAP0 = heap_used();
    DIRTYF = 1;
    RUNNING = 1;
    while (RUNNING == 1) {
        if (poll_winsize()) { DIRTYF = 1; };
        // read_key_timeout(0): a poll, with the pacer owning the deadline.  A
        // 1..99 ms poll rounds up to 100 ms (VTIME counts deciseconds,
        // ORCHESTRATOR.md 2.1) and every frame lands a period late.
        let k = term.read_key_timeout(0);
        if (k != term.KEY_NONE) { handle(k); };
        let wait = time.pacer_next(pacer);
        let due = wait > 0;
        // An editor redraws when something changed.  `--frames N` is the other
        // contract -- draw exactly N frames whether or not anything happened --
        // so in that mode every tick is a redraw.  Without this, `q` aside, the
        // loop drew one frame and then sat there: there is no key to type, so
        // nothing ever set DIRTYF again and FRAMES_DRAWN never reached N.
        if (FRAMES > 0) { DIRTYF = 1; };
        if (DIRTYF == 1 && due) { draw(); };
        if (FRAMES > 0 && FRAMES_DRAWN >= FRAMES) { RUNNING = 0; };
    };
    if (SHOWTIME == 1) {
        eputs(NAME + ": frames " + tostring(FRAMES_DRAWN) + ", heap "
              + tostring(HEAP0) + " -> " + tostring(heap_used()) + " (delta "
              + tostring(heap_used() - HEAP0) + "), keys dropped "
              + tostring(time.pacer_dropped(pacer)) + "\n");
    };
    if (OUTERR == 1) { rc = 5; };
    term.restore_all_exit(rc);
    rc
};

// One key.  Three modes: normal, the open prompt and the search prompt.
def handle(k: long) -> void {
    DIRTYF = 1;
    // A message lives until the next key.  A key typed INTO a prompt belongs to
    // the prompt, though, so a message raised while prompting stays up.
    if (HITS == 0) { MSGN = 0; };
    if (HITS == 1) { handle_open(k); return };
    if (HITS == 2) { handle_find(k); return };
    handle_normal(k);
    0
};

// The status-line message, written straight into MSG.  msgw/msgb/msgn are three
// appends rather than one `setmsg("wrote " + tostring(n) + " bytes to " + path)`,
// because that concatenation is a fresh heap string every time it runs and this
// one is on a keypress path that redraws a frame.  Zero bytes, like everything
// else on the frame path.
def msgclr() -> void {
    MSGN = 0
};

def msgw(s: str) -> void {
    let i = 0;
    while (i < len(s) && MSGN < 198) { MSG[MSGN] = s[i]; MSGN = MSGN + 1; i = i + 1; }
};

def msgb(v: long) -> void {
    if (MSGN < 200) { MSG[MSGN] = v; MSGN = MSGN + 1; }
};

// setmsg(s) -- put a line of text on the status line.
def msgn(v: long) -> void {
    if (v < 0) { msgb(45); v = 0 - v; };
    if (v == 0) { msgb(48); return; };
    let k = 0;
    let x = v;
    while (x > 0) { D10[k] = 48 + (x % 10); x = x / 10; k = k + 1; };
    while (k > 0) { k = k - 1; msgb(D10[k]); }
};

def setmsg(s: str) -> void {
    msgclr();
    msgw(s);
    0
};

def handle_open(k: long) -> void {
    if (k == term.KEY_ESC) {
        HITS = 0;
        PATHN = 0;
        return
    };
    if (k == 10 || k == 13) {
        let p = from_bytes(PATHBUF[0:PATHN]);
        if (len(p) < 1) {
            HITS = 0;
            PATHN = 0;
            return
        };
        // A refusal here is a message and NO exit: the buffer on screen is
        // still the one the user had, which is the whole point of an editor.
        if (!hx.open_path(p)) {
            // A refusal is a message and NO exit: the buffer on screen is still
            // the one the user had, which is the whole point of an editor.
            setmsg(hx.ERRS);
            HITS = 0;
            PATHN = 0;
            return
        };
        recent_add(p);
        SOURCE = p;
        PATH = p;
        CUR = 0;
        TOP = 0;
        NMARKS = 0;
        MARKI = 0;
        PATN = 0;
        LASTHIT = 0 - 1;
        HITS = 0;
        PATHN = 0;
        return
    };
    if (k == 8 || k == 127) {
        if (PATHN > 0) { PATHN = PATHN - 1; };
        return
    };
    if (k >= 32 && k < 127 && PATHN < MAXPATH - 1) {
        PATHBUF[PATHN] = k;
        PATHN = PATHN + 1;
    };
    0
};

def handle_find(k: long) -> void {
    if (k == term.KEY_ESC) {
        HITS = 0;
        PATN = 0;
        return
    };
    if (k == 10 || k == 13) {
        HITS = 0;
        if (PATN > 0) { search_from(0, 1); };
        return
    };
    if (k == 8 || k == 127) {
        if (PATN > 0) { PATN = PATN - 1; };
        return
    };
    if (k >= 32 && k < 127 && PATN < MAXPAT - 1) {
        PAT[PATN] = k;
        PATN = PATN + 1;
    };
    0
};

let LASTMESS: long = 0;                    // 1 = the status line carries a message

def handle_normal(k: long) -> void {
    if (k == term.KEY_UP || k == 75) { step(0 - WIDTH); return };
    if (k == term.KEY_DOWN || k == 74) { step(WIDTH); return };
    if (k == term.KEY_LEFT || k == 72) { step(0 - 1); return };
    if (k == term.KEY_RIGHT || k == 76) { step(1); return };
    if (k == term.KEY_PGUP || k == 21) { step(0 - WIDTH * view_rows()); return };
    if (k == term.KEY_PGDN || k == 22) { step(WIDTH * view_rows()); return };
    // No letter that is a HEX DIGIT may be bound to a command: 0-9 a-f have to
    // be typeable, because a byte is made of them.  `a` was bound to Home here
    // and `f` to fit, so neither could be typed -- found by pty_check.py, which
    // typed a byte and watched the file not change.  Home/End are the escape
    // sequences, and g / G do first and last.
    if (k == term.KEY_HOME || k == 103) { CUR = 0; NIBBLE = 0; return };
    if (k == 9) { PANE = 1 - PANE; NIBBLE = 0; return };
    if (k == term.KEY_ESC || k == 113 || k == 3) { handle_quit(); return };
    if (k == 8 || k == 127) { step(0 - 1); return };
    if (k == 10 || k == 13) { step(WIDTH); return };
    if (k == 47) { HITS = 2; PATN = 0; return };
    if (k == 79) { HITS = 1; PATHN = 0; return };
    if (k == 78) { search_from(LASTHIT + 1, 1); return };
    if (k == 80) { search_from(LASTHIT, 0 - 1); return };
    // `m`, not `b`: b is a hex digit, and a hex editor that cannot type
    // its own alphabet is not a hex editor.  Found by pty_check.py, which types
    // a byte and watched the bookmark count move instead.
    if (k == 109) { mark_toggle(CUR); return };
    if (k == 91) { let m = mark_step(0 - 1); if (m >= 0) { CUR = m; }; return };
    if (k == 93) { let m = mark_step(1); if (m >= 0) { CUR = m; }; return };
    if (k == 120) { mark_clear(); setmsg("marks cleared"); return };
    if (k == 119) { do_write(); return };
    if (k == 71) { do_fit(); return };
    if (k == 104 || k == 63) { return };
    // Everything else that is a hex digit types a byte.
    let e = type_hex(k);
    if (e == hx.E_PAST) {
        msgclr();
        msgw("cannot type at offset ");
        msgn(CUR);
        msgw(": past the end of the file");
    };
    if (e == hx.E_NEG) {
        msgclr();
        msgw("cannot type at offset ");
        msgn(CUR);
        msgw(": before the start of the file");
    };
    0
};

def handle_quit() -> void {
    RUNNING = 0;
    0
};

def do_write() -> void {
    if (len(PATH) < 1) {
        setmsg("nothing to write: this buffer is the embedded sample");
        return
    };
    if (!hx.save(PATH)) {
        setmsg(hx.ERRS);
        return
    };
    msgclr();
    msgw("wrote ");
    msgn(hx.SIZE);
    msgw(" bytes to ");
    msgw(PATH);
    0
};

// `G`: jump to the last byte, so a small file can be seen whole without
// scrolling.  (It was `f` until pty_check.py typed a byte and watched nothing
// change: f is a hex digit.)
def do_fit() -> void {
    if (hx.SIZE > 0) { CUR = hx.SIZE - 1; NIBBLE = 0; }
    0
};

// ──────────────────────────────────────────────────────── entry point ───

def main() -> long {
    args.init(NAME,
              "a hex editor and file inspector.  With no file it opens the "
              + "shipped sample; with --no-tty it prints the dump that "
              + "`od -A d -t x1z -v` prints.",
              OPTS,
              "keys: arrows/hjkl move, tab switches pane, 0-9a-f types a byte, "
              + "m marks, [ ] jump between marks, n/N next/previous match, "
              + "/ searches, o opens, w writes, g/G first/last byte, q quits.");
    let st = args.parse(argv());
    if (st == args.HELP) {
        // The one case where the usage text belongs on stdout: the user asked
        // for it.  Exit 0, because asking for help and getting it is success.
        print(NAME + ": " + args.usage() + "\n");
        return 0
    };
    if (st != args.OK) {
        // args.ar_fail has ALREADY written its message to stderr.  The usage
        // text goes there too: a usage error printed on stdout would land in a
        // golden diff looking like program output, and this program has an
        // --edit that changes its bytes.  And the status is 2, not 0 -- an
        // unrecognised option is a failure, and the check in selftest.y section 8
        // is what keeps that true.
        eputs(NAME + ": " + args.usage() + "\n");
        return 2
    };

    NOTTY = args.has("no-tty") ? 1 : 0;
    FRAMES = args.get_long("frames", 0);
    HIST = args.has("hist") ? 1 : 0;
    SHOWTIME = args.has("time") ? 1 : 0;
    WANT_OD = args.has("od") ? 1 : 0;
    BENCH = args.get_long("bench", 0);

    // The self-check owns its own fixtures and its own file handling, so it
    // runs before the target is opened and ignores --file.
    if (args.has("check")) {
        let rc = run_check();
        if (rc == 0) { return 0 };
        eputs(NAME + ": --check failed\n");
        return 3
    };

    WIDTH = args.get_long("width", 16);
    SHOW_FROM = args.get_long("offset", 0);
    SHOW_ROWS = args.get_long("rows", 0);

    if (WIDTH != 8 && WIDTH != 16 && WIDTH != 32) {
        eputs(NAME + ": --width must be 8, 16 or 32, not " + tostring(WIDTH) + "\n");
        return 2
    };
    if (SHOW_FROM < 0) {
        eputs(NAME + ": --offset cannot be negative (" + tostring(SHOW_FROM) + ")\n");
        return 2
    };
    if (SHOW_ROWS < 0) {
        eputs(NAME + ": --rows cannot be negative (" + tostring(SHOW_ROWS) + ")\n");
        return 2
    };
    if (FRAMES < 0) {
        eputs(NAME + ": --frames cannot be negative (" + tostring(FRAMES) + ")\n");
        return 2
    };
    if (BENCH < 0) {
        eputs(NAME + ": --bench cannot be negative (" + tostring(BENCH) + ")\n");
        return 2
    };

    let ro = open_target();
    if (ro != 0) { return ro };

    if (SHOW_FROM > hx.SIZE) {
        // Not a trap: a window that starts past the end is a message.  Clamping
        // to the last row would hide the mistake, so this refuses instead.
        eputs(NAME + ": --offset " + tostring(SHOW_FROM) + " is past the end of "
              + SOURCE + " (" + tostring(hx.SIZE) + " bytes)\n");
        return 2
    };

    if (args.has("edit")) {
        let re = apply_edits(args.get_str("edit", ""));
        if (re != 0) { return re };
    };

    if (args.has("save")) {
        let sp = args.get_str("save", "");
        if (!hx.save(sp)) {
            eputs(NAME + ": " + hx.ERRS + "\n");
            return 2
        };
        SAVED_TO = sp;
    };

    if (BENCH > 0) {
        let rb = run_bench(BENCH);
        if (rb != 0) { return rb };
    };

    let want_dump = args.has("dump");
    let interactive = NOTTY == 0 && !want_dump && BENCH == 0;
    if (NOTTY == 1 || want_dump || BENCH > 0) {
        if (!interactive) {
            let rd = run_dump();
            return rd
        };
    };
    if (interactive) { return run_interactive() };
    run_dump()
};

exit(main())