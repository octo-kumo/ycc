// report.y -- the headless report: a fixed-byte line writer, a per-frame
// table, and the final frame as text.
//
// ===========================================================================
// WHY THIS FILE EXISTS AT ALL
//
// The obvious way to print a per-frame row is
//
//     print(f"  {g} | mean {mean} | ...")
//
// which allocates an f-string and several concatenations, and the heap is an
// arena that never frees (ORCHESTRATOR.md 2.7).  Over 200 frames that is tens
// of kilobytes of garbage; over a long --stats run it is the whole cap.  So
// every per-frame line is assembled into ONE module-level byte buffer and left
// through one write(2), and that buffer is the only thing this file allocates.
//
// The header and summary blocks are the exception: they are built once, with
// `+`, from strings that live for the life of the program -- that is what
// field() is for, and it is why the numbers in them cost nothing to print.
//
// ===========================================================================
// WHAT THE TABLE COLUMNS ARE, AND WHY EACH ONE IS THERE
//
//   gen    the step number.  0 is the initial scatter, so row 0 is the world
//          as seeded and every later row is one step on.
//   mean   the flock's mean |v|, in units/step.  A settled flock holds a
//          steady mean; one that has collapsed into a line has a low one.
//   max    the largest |v| THIS FRAME.  Never above the cap: the clamp in
//          step() guarantees it, and this is where a clamp that failed would
//          appear as a number above the cap.
//   ord    mean neighbours per boid, two decimals.  The flocking number: under
//          1 the birds cannot see each other and the three rules do nothing at
//          all.  It is also what the isolated-rule tests move.
//   span   the flock's width, max(x) - min(x), NOT the torus width -- which is
//          why the column says "span" and not "width".
//   d      the state digest.  The per-frame fingerprint: one seed prints
//          identical columns twice, two seeds do not.

import flock;
import time;

let RBUF: [byte] = [0; 4096];
let RLEN = 0;
const RB_CAP = 4096;

// -- the line writer --------------------------------------------------------

def rb_reset() { RLEN = 0; };

// rb_byte drops anything past the cap and keeps counting, so an over-long line
// is TRUNCATED rather than an out-of-bounds trap -- and a trap prints to
// STDOUT, which would corrupt the very output this file produces.
def rb_byte(b: long) {
    if (RLEN < RB_CAP) { RBUF[RLEN] = b; };
    RLEN = RLEN + 1
};

def rb_str(t: str) {
    let i = 0;
    let n = len(t);
    while (i < n) {
        rb_byte(t[i]);
        i = i + 1
    }
};

// rb_num(v) -- a non-negative long in decimal, no leading zeros, 0 as "0".
// Everything printed here is a count or a setting main() has already checked
// is not negative, so there is no sign case.
def rb_num(v: long) {
    if (v == 0) {
        rb_byte(48);
        return
    };
    let d = 1;
    let t = v;
    while (t >= 10) {
        t = t / 10;
        d = d * 10
    };
    while (d > 0) {
        rb_byte(48 + (v / d) % 10);
        d = d / 10
    }
};

// rb_hex(v) -- 12 hex digits, a fixed width so the column lines up.  12 covers
// everything flock.digest() can return (it masks to 2^46) with room to spare.
def rb_hex(v: long) {
    let i = 11;
    while (i >= 0) {
        let d = (v >> (i * 4)) & 15;
        if (d < 10) {
            rb_byte(48 + d)
        } else {
            rb_byte(87 + d)
        };
        i = i - 1
    }
};

// hund(q16) -- a Q16 value in hundredths, so 65536 reads 100.  Integer
// division truncates toward zero, so -65536 reads -100 exactly.
//
// This is the ONLY way a fixed-point number becomes text in this program: Y
// has no float -> long and no cast syntax at all (ORCHESTRATOR.md 2.4a), so a
// number a computation produces can never leave a float in the first place.
def hund(q16: long) -> long { q16 * 100 / 65536 };

// rb_fixed(q16) -- a Q16 value as "-12.34", always two decimals.
def rb_fixed(q16: long) {
    let c = hund(q16);
    if (c < 0) {
        rb_byte(45);
        c = 0 - c
    };
    rb_num(c / 100);
    rb_byte(46);
    let f = c % 100;
    if (f < 10) { rb_byte(48); };
    rb_num(f)
};

// rb_pad(to) -- pad with spaces to `to` columns.  A line that lost a digit
// ("PAUSED" back to "running") has to erase the tail of the longer line it
// replaced, and this is how, without clearing the row above it.
def rb_pad(to: long) {
    while (RLEN < to) { rb_byte(32); }
};

def rb_end() {
    let n = RLEN;
    if (n > RB_CAP) { n = RB_CAP; };
    syscall(1, 1, &RBUF[0], n);
    RLEN = 0
};

def rb_line(t: str) {
    rb_str(t);
    rb_end()
};

// field(name, value) -> "  name     value\n", the name padded to a fixed width
// so the header is a column and not a staircase.  Returns a str, so it
// allocates -- which is why it is used for the two blocks that are built once
// and never for anything per-frame.
def field(name: str, value: str) -> str {
    let out = "  " + name;
    let want = 15 - len(name);
    let k = 0;
    while (k < want) {
        out = out + " ";
        k = k + 1
    };
    out + value + "\n"
};

// -- the frame as text ------------------------------------------------------

// glyph(idx) -> one of four direction bytes for the text dump.  The screen's y
// grows DOWN, so heading 0 (+x) is '>', the next octant is down-right '\', then
// '<' and '/'.  Plain ASCII on purpose: the text dump is the golden file, and a
// UTF-8 arrow would put an encoding dependency in it (and chr() cannot make a
// non-ASCII glyph anyway).
def glyph(idx: long) -> long {
    if (idx == 0) { return 62 };     // '>'
    if (idx == 1) { return 92 };     // '\'
    if (idx == 2) { return 60 };     // '<'
    47                              // '/'
};

// GRID: [byte] -- the text dump's cells, one byte per cell, plus a newline per
// row.  Module level, so drawing a frame allocates nothing.
//
// Sized for the LARGEST WORLD THE STORE ALLOWS, not for the default: 256 * (128
// + 1) = 33024, because a world bigger than the grid would have to be either
// truncated or trapped on, and a `[0; n]` array size has to be an integer
// LITERAL, so the grid cannot be sized from a variable at run time.  One
// allocation, made once, for every world from 8x6 up.
const GRID_CAP = 33024;

let GRID: [byte] = [0; 33024];

// frame_text(s) -- the flock as text, on the terminal's axis convention: row 0
// is y = 0 at the top, x grows right.
//
// THE STRIDE IS cols + 1, NOT cols: the "+1" IS the row's newline byte.  The
// first version filled row y at y*cols and put the newline at y*cols + cols,
// which is row y+1's FIRST CELL -- so the next iteration's fill overwrote it
// with a '.' and the whole world printed as one enormous line with a single
// newline at the very end.  Everything below indexes with `stride`, the glyphs
// included, so the fill and the newline cannot collide again.
//
// A boid with no velocity prints 'o' rather than an arrow: flock.heading() of
// (0,0) is 0 by convention (fx.atan2(0,0) == 0), which would otherwise draw
// every stationary boid as pointing east.  Stacked boids keep the last one to
// land on the cell, and the occupied-cell count in the summary says how many
// were hidden that way -- so a frame where two boids share a cell is visible in
// the numbers instead of being silently lost.
def frame_text(s: flock.Flock) {
    let cols = s.w;
    let rows = s.h;
    let stride = cols + 1;
    // The world is bounded by flock.MAXW x flock.MAXH, so stride*rows can never
    // exceed GRID_CAP -- and it is checked anyway, because an out-of-bounds
    // store here would be a TRAP, and a trap prints to STDOUT and corrupts the
    // very output this file is producing.
    let need = stride * rows;
    if (need > GRID_CAP) { need = GRID_CAP; };
    let y = 0;
    while (y < rows) {
        let i = 0;
        while (i < cols) {
            GRID[y * stride + i] = 46;      // '.'
            i = i + 1
        };
        GRID[y * stride + cols] = 10;       // the row's newline
        y = y + 1
    };
    let k = 0;
    while (k < s.n) {
        let cx = s.px[k] / 65536;
        let cy = s.py[k] / 65536;
        if (cx >= 0 && cx < cols && cy >= 0 && cy < rows) {
            if (flock.speed(s, k) == 0) {
                GRID[cy * stride + cx] = 111          // 'o'
            } else {
                let idx = (flock.heading(s, k) + 2250) / 4500;
                GRID[cy * stride + cx] = glyph(idx % 4)
            }
        };
        k = k + 1
    };
    // One write(2) for the whole frame, not one a row: the per-row version
    // emitted every row's bytes but only the LAST row's newline, which
    // concatenated the whole world into one line.  One call has no such
    // boundary to get wrong.
    syscall(1, 1, &GRID[0], need)
};

// occupied(s) -> how many distinct cells hold at least one boid.  An O(n^2)
// scan over n cells, which is the same shape as the pair loop and costs the
// same order, and it is only called once per run.  Compared against s.n in the
// summary: the two are equal unless boids are stacked.
def occupied(s: flock.Flock) -> long {
    let cells = 0;
    let k = 0;
    while (k < s.n) {
        let cx = s.px[k] / 65536;
        let cy = s.py[k] / 65536;
        let seen = false;
        let j = 0;
        while (j < k && !seen) {
            if (s.px[j] / 65536 == cx && s.py[j] / 65536 == cy) { seen = true; };
            j = j + 1
        };
        if (!seen) { cells = cells + 1; };
        k = k + 1
    };
    cells
}

// -- the per-frame table ----------------------------------------------------

// row(s, gen) -- one line of the table, built into the buffer and left through
// one write(2).  The column format lives here and nowhere else.
def row(s: flock.Flock, gen: long) {
    rb_reset();
    rb_pad(7);
    rb_num(gen);
    rb_str("  mean ");
    rb_fixed(flock.mean_speed(s));
    rb_str("   max ");
    rb_fixed(s.vmax_now);
    rb_str("   ord ");
    rb_fixed(flock.mean_order(s));
    rb_str("   span ");
    rb_num(flock.span_x(s));
    rb_str("   0x");
    rb_hex(flock.digest(s));
    rb_byte(10);
    rb_end()
};

// -- the headless report ----------------------------------------------------

// run(s, frames, dump, want_stats, seed) -> long -- the deterministic
// invocation: no clock, no terminal, no randomness beyond the seed, so its
// stdout is diffable byte for byte.
//
// The heap readings bracket ONLY the frame loop.  The header above and the
// summary below both build strings, and measuring across them would report
// that output as a leak.
def run(s: flock.Flock, frames: long, dump: long, want_stats: bool, seed: long) -> long {
    puts("boids -- Reynolds' flocking: separation, alignment, cohesion\n\n");
    puts(field("seed", tostring(seed)));
    puts(field("boids", tostring(s.n)));
    puts(field("world", tostring(s.w) + " x " + tostring(s.h) + " units (torus)"));
    puts(field("frames", tostring(frames)));
    puts(field("weights", "sep " + fixed(hund(s.wsep)) + "   ali "
                          + fixed(hund(s.wali)) + "   coh " + fixed(hund(s.wcoh))));
    puts(field("radii", "view " + tostring(s.vr) + "   sep " + tostring(s.sr)
                        + " units (the pair test is strict: a pair exactly on "
                        + "the radius is outside it)"));
    puts(field("max speed", fixed(hund(s.maxs)) + "   the clamp; a 'max' "
                                            + "column above it is a bug"));
    puts(field("max force", fixed(hund(s.maxf)) + "   units/step"));
    puts(field("dt", fixed(hund(s.dt))));
    puts(field("rules", flock.mask_name(flock.mask())));
    puts(field("arithmetic", "Q16 (1.0 = 65536); the root is flock.isqrt's "
                            + "digit recurrence, taken once per pair"));
    puts("\n");
    puts("  frame       mean |v|      max |v|     ord/boid   span x"
         + "        state digest\n");

    // Read AFTER the header: the only thing between the two readings is the
    // frame loop.  (life.y measures it the same way, for the same reason.)
    let h0 = heap_used();
    let w0 = time.now_us();

    // One row per frame while that fits, then a stride, so the table is the
    // same shape whatever --frames says.  The stride is a function of `frames`
    // alone, so the golden does not depend on it being a round number.
    let stride = 1;
    if (frames > 64) { stride = (frames + 63) / 64; };
    if (dump > 0 && dump < stride) { stride = dump; };

    // --dump additionally prints a marker every dump frames, so a golden made
    // with --dump says which rows are dumps and which are the table.
    if (dump > 0) {
        rb_str("frame 0\n");
        rb_end()
    };
    row(s, 0);
    let g = 0;
    while (g < frames) {
        flock.step(s);
        g = g + 1;
        if (dump > 0 && (g % dump == 0 || g == frames)) {
            rb_str("frame ");
            rb_num(g);
            rb_byte(10);
            rb_end()
        };
        if (g % stride == 0 || g == frames) { row(s, g); }
    };

    // Read here, with the frames run and nothing of the summary built yet.
    let h1 = heap_used();
    let wall = time.now_us() - w0;
    let pairs = s.pairs;

    puts("\nfinal frame, after " + tostring(frames) + " steps\n");
    frame_text(s);

    puts("\nsummary\n");
    puts(field("boids", tostring(s.n)));
    puts(field("occupied cells", tostring(occupied(s))
                        + " of " + tostring(s.n)
                        + (if (occupied(s) == s.n) { "" } else { "  (some are stacked)"})));
    puts(field("final mean |v|", fixed(hund(flock.mean_speed(s)))));
    puts(field("final max |v|", fixed(hund(s.vmax_now))));
    puts(field("speed cap", fixed(hund(s.maxs))));
    puts(field("final ord/boid", fixed(hund(flock.mean_order(s)))));
    puts(field("view pairs", tostring(pairs) + " in the last step"));
    puts(field("steps at clamp", tostring(s.sat)));
    puts(field("boids clamped", tostring(s.over)));
    puts(field("largest raw |v|", fixed(hund(s.vraw)) + "  before the clamp"));
    puts(field("state digest", "0x" + hexstr(flock.digest(s))));
    puts(field("in bounds", if (flock.in_bounds(s)) { "yes" } else { "NO" }));
    if (want_stats) {
        let per = 0;
        if (frames > 0) { per = wall / frames; };
        puts(field("wall", tostring(wall) + " us  (" + tostring(wall / 1000)
                   + " ms)"));
        puts(field("heap", tostring(h0) + " -> " + tostring(h1) + " B  ("
                    + tostring(h1 - h0) + " over " + tostring(frames)
                    + " steps)"));
        puts(field("us/step", tostring(per)));
        puts(field("pairs last step", tostring(pairs)));
        if (frames > 0) {
            // Each pair inside the view radius forms one squared distance, and
            // each rule force takes one root of the force, so this is the count
            // of isqrt() calls the run made.  Pairs are counted per BOID, so
            // n*(n-1), and the three rules add at most three roots a boid.
            // `wall` is MICROSECONDS, so the rates multiply the count by 1e6
            // and not by 1e3.  (They multiplied by 1e3 first, which reported
            // 107 pair-steps/s for a run that did 9 million of them.)
            let roots = (pairs + 3 * s.n) * frames;
            let steps = frames * pairs;
            let pps = 0;
            let rps = 0;
            if (wall > 0) {
                pps = steps * 1000000 / wall;
                rps = roots * 1000000 / wall
            };
            puts(field("pair-steps", tostring(steps)));
            puts(field("pair-steps/s", tostring(pps)));
            puts(field("roots", tostring(roots)));
            puts(field("roots/s", tostring(rps)))
            ;
            puts(field("ns per root", tostring(if (roots > 0)
                    { wall * 1000 / roots } else { 0 }) + "  (1000 = one "
                    + "microsecond per root)"))
        }
    };
    0
}

// fixed(n) -- n hundredths as "-1.23".  Allocates, so it is for the two blocks
// that are built once, never for the per-frame table (which uses rb_fixed into
// the buffer).
def fixed(n: long) -> str {
    let neg = false;
    let v = n;
    if (v < 0) {
        neg = true;
        v = 0 - v
    };
    let s = tostring(v / 100) + ".";
    let f = v % 100;
    if (f < 10) { s = s + "0" };
    s = s + tostring(f);
    if (neg) { "-" + s } else { s }
};

const HEXD = "0123456789abcdef";

def hexstr(v: long) -> str {
    let s = "";
    let i = 11;
    while (i >= 0) {
        let d = (v >> (i * 4)) & 15;
        s = s + HEXD[d:d + 1];
        i = i - 1
    };
    s
};