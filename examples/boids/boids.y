// boids.y -- Craig Reynolds' flocking in the terminal: a live view and a
// headless report, plus a property check.
//
// ===========================================================================
// WHAT IT IS
//
// Three rules over a torus (flock.y has the details): separation pushes each
// boid off its crowded neighbours, alignment turns it the way they turn, and
// cohesion brings it to their centre of mass.  Two ways to run:
//
//   ./boids                                the live view: alt screen, 30 fps
//   ./boids --no-tty --frames 200          headless: a table and a frame, exit 0
//
// The default path is deterministic -- the default seed is 1, there is no
// unseeded randomness anywhere, and the headless run prints no timings unless
// --stats says so.  The clock lives behind --fps and --stats; the terminal
// behind the absence of a tty.
//
// ===========================================================================
// THE FOUR MODES, AND WHY EACH ONE GETS ITS OWN SCREEN STATE
//
//   live      raw mode, alt screen, one restore_all_exit at the bottom that
//             every early exit routes through.  term.y's crash watchdog covers
//             SIGKILL and a fault.
//   headless  --no-tty or --frames: NO termios, no escape sequences, no
//             watchdog, no clock.  That is what makes its stdout diffable byte
//             for byte, and it is why --frames is the flag to reach for.
//   check     --check: no terminal, no frames, a fixed battery of assertions
//             about the arithmetic, the three rules' signs, the clamp and
//             determinism (check.y).
//   help      --help, exit 0.
//
// ===========================================================================
// KEYS (live view)
//
//   q  Esc  Ctrl-C   quit -- restore_all_exit(0), always
//   space             pause / resume
//   .                 one frame, even while paused
//   r                 reseed with seed+1 (the same seed always gives the same
//                     flock, so this is a reproducible jump)
//   1 2 3             toggle separation / alignment / cohesion
//   0                 all three on
//   c                 cycle the palette
//   + / -             faster / slower (the fps cap; 0 is as fast as it goes)
//   h                 the key list
//
// There is no `break` in Y, so every one of these is an arm of one `else if`
// chain over one long, and the loop's only exit is a guard flag tested in the
// `while` -- see run_live().

import args;
import fb;
import term;
import time;
import flock;
import report;
import check;

const OPTS: [args.Opt] = [
    { long: "boids",   short: "n", kind: args.NUM,  help: "how many boids, 1..512 (default 120)" },
    { long: "size",    short: "z", kind: args.STR,  help: "world as WxH units, 8x6..256x128 (default: the terminal size, else 100x40)" },
    { long: "seed",    short: "s", kind: args.NUM,  help: "the seed, default 1 -- the same seed always gives the same flock" },
    { long: "view",    short: "v", kind: args.NUM,  help: "view radius in units (default 9): alignment and cohesion reach this far" },
    { long: "sep",     short: "p", kind: args.NUM,  help: "separation radius in units (default 4)" },
    { long: "wsep",    short: "",   kind: args.NUM,  help: "separation weight in hundredths (default 150)" },
    { long: "wali",    short: "",   kind: args.NUM,  help: "alignment weight in hundredths (default 100)" },
    { long: "wcoh",    short: "",   kind: args.NUM,  help: "cohesion weight in hundredths (default 90)" },
    { long: "maxspeed", short: "m", kind: args.NUM,  help: "max speed in hundredths of a unit/step (default 140)" },
    { long: "frames",  short: "f", kind: args.NUM,  help: "run N steps headless, print the table and the final frame, exit 0" },
    { long: "dump",    short: "",   kind: args.NUM,  help: "also print a 'frame N' marker every N steps (0 = never)" },
    { long: "rules",   short: "",   kind: args.STR,  help: "which rules are live: all | sep | ali | coh | sep+ali ... (default all)" },
    { long: "no-tty",  short: "",   kind: args.BOOL, help: "force the headless path even when stdout is a terminal" },
    { long: "check",   short: "C", kind: args.BOOL, help: "run the property check and exit (0 pass, 1 fail)" },
    { long: "fps",     short: "",   kind: args.NUM,  help: "live view frames per second (default 30, 0 = uncapped)" },
    { long: "color",   short: "c", kind: args.STR,  help: "mono | speed | depth (default speed)" },
    { long: "stats",   short: "S", kind: args.BOOL, help: "print elapsed time, rate and heap use on exit" }
];

// -- small helpers ----------------------------------------------------------

// The answer to --size, in whole units.  Module level because a scalar
// PARAMETER is passed by value: parse_size() writing to one of its own `long`
// parameters would change nothing the caller could see.  See parse_size().
let SIZE_W: long = 0;
let SIZE_H: long = 0;

def die(msg: str) -> long {
    eputs("boids: " + msg + "\n");
    eputs("boids: try --help\n");
    1
};


// -- the window size --------------------------------------------------------

// winsize() -> long -- the window size packed as rows * 1000 + cols, read into
// THIS module's own buffer.
//
// Why not term.size()?  Because term.size() answers `{ rows, cols }` -- a
// record LITERAL, built fresh on every call -- and a record literal inside a
// loop body allocates (SUGGESTIONS.md 7 measures 40 bytes for a two-field
// record).  Polling it once a frame leaked exactly 40 bytes a frame, dead
// linear, and it would look fine for an hour and then hit the cap.
//
// The copy of term.y in this folder is frozen and NOT edited, so the four lines
// it would take to fix it upstream are written out here instead: one ioctl
// (syscall 16, fd, REQUEST, arg -- kernel register order, ORCHESTRATOR.md 2.1)
// into a module-level [byte; 64], then two 16-bit little-endian reads.  ROW
// FIRST, at bytes 0-1 (2.3).  Returning one packed long rather than a record
// keeps the allocation count at zero.
//
// 24x80 when the ioctl fails or reports a zero, which is what a pty from
// pty.fork() looks like before anybody sets TIOCSWINSZ.
//
// WS is a GROWABLE [byte], like term.y's own WS, and not a fixed [byte; 64]: a
// fixed array carries its elements inline, so `&WS[0]` has to box it, and the
// box is a one-time heap block that lands inside the frame measurement.
const WS: [byte] = [0; 64];

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

// -- the status line --------------------------------------------------------
//
// Built into a FIXED byte buffer, not into a `str`.  The obvious spelling is
//
//     fb.text(surf, s.h, 0, f"frame {s.gen} | {fps} fps | ...")
//
// which is one f-string and several `+` per frame -- and every one of those
// allocates, because the heap is an arena and nothing is freed.  Measured
// through a pty that leaked ~3.7 KB a frame.  `heap_used()` either side of the
// loop is what finds it: --stats, and README.md.

const SB_CAP = 256;

let SBUF: [byte; 256] = [0; 256];
let SBN = 0;

def sb_reset() { SBN = 0; };

// sb_byte drops anything past the cap rather than trapping on the store, and
// keeps counting, so an over-long line is truncated.
def sb_byte(b: long) {
    if (SBN < SB_CAP) { SBUF[SBN] = b; };
    SBN = SBN + 1
};

// sb_str(t) -- a string's bytes.  A `str` index is a `byte` in Y, so this is a
// copy loop rather than an ord() call per character.
def sb_str(t: str) {
    let i = 0;
    let n = len(t);
    while (i < n) {
        sb_byte(t[i]);
        i = i + 1
    }
};

def sb_num(v: long) {
    if (v == 0) {
        sb_byte(48);
        return
    };
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

// sb_fixed(q16) -- a Q16 value as "1.40".  This is the only way a fixed-point
// number becomes text: Y has no float -> long and no cast syntax at all
// (ORCHESTRATOR.md 2.4a), so a number a computation produces can never leave a
// float in the first place.
def sb_fixed(q16: long) {
    let c = q16 * 100 / 65536;
    if (c < 0) {
        sb_byte(45);
        c = 0 - c
    };
    sb_num(c / 100);
    sb_byte(46);
    let f = c % 100;
    if (f < 10) { sb_byte(48); };
    sb_num(f)
};

def sb_pad(to: long) {
    while (SBN < to) { sb_byte(32); }
};

def sb_draw(surf: fb.Surface, row: long, fg: long, bg: long) {
    let n = SBN;
    if (n > SB_CAP) { n = SB_CAP; };
    for i in 0..n {
        fb.put(surf, row, i, SBUF[i], fg, bg)
    }
};

// -- colours ----------------------------------------------------------------

// back_colour() -> long -- the board behind the birds.  The terminal's own
// background in mono, a very dark blue otherwise.
def back_colour(mode: long) -> long {
    if (mode == 0) { return fb.DEFAULT };
    fb.rgb(8, 10, 20)
};

// bird_colour(speed, maxs, mode) -> long.  Three palettes:
//
//   0 mono   flat white -- the shape of the flock and nothing else, which is
//           the view to check the rules in;
//   1 speed  cyan through white, by speed / max speed.  The default, because a
//           flock's whole story is who is moving fast;
//   2 depth  blue through yellow, by speed again but reversed in feel, which
//           makes the leaders stand out against the mass.
def bird_colour(sp: long, maxs: long, mode: long) -> long {
    if (mode == 0) { return fb.grey(200) };
    let t = 0;
    if (maxs > 0) { t = sp * 100 / maxs; };
    if (t > 100) { t = 100; };
    if (mode == 1) {
        return fb.lerp_rgb(fb.rgb(30, 90, 150), fb.rgb(255, 250, 220), t)
    };
    fb.lerp_rgb(fb.rgb(70, 40, 120), fb.rgb(255, 220, 90), t)
};

// -- the live view ----------------------------------------------------------

// ARROW[0..7] -- the eight direction glyphs, U+2190..U+2197, chosen so the
// boid's heading is legible without a legend.
//
// NOT chr(): chr() is byte-oriented and cannot make a non-ASCII glyph --
// chr(8594).length is 1 and ord(chr(8594)) is 136, because 8594 & 255 == 136.
// fb.put takes a CODEPOINT and encodes it through fb.utf8_byte, which is the
// one route that works.
def arrow(i: long) -> long { 8592 + i };

// draw(surf, s, mode) -- the whole flock into the surface.
//
// The mapping is one world unit to one cell: px is Q16 in [0, w*Q16), so
// `px / 65536` is the cell, and the same division finds the column in
// flock.isqrt... no: in the glyph choice.  A boid on the wrap edge simply
// appears on the other side, which is what a torus means.
//
// Allocation-free: fb.put writes into arrays that already exist.  It does NOT
// flush; the caller draws the status line and then flushes once, so a frame
// costs one flush_diff and therefore one write(2) per row that changed.
def draw(surf: fb.Surface, s: flock.Flock, mode: long) {
    let back = back_colour(mode);
    for y in 0..s.h {
        for x in 0..s.w {
            fb.put(surf, y, x, 32, fb.DEFAULT, back)
        }
    };
    for i in 0..s.n {
        let x = s.px[i] / 65536;
        let y = s.py[i] / 65536;
        if (x >= 0 && x < s.w && y >= 0 && y < s.h) {
            let sp = flock.speed(s, i);
            // heading() is hundredths of a degree, so /2250 is the octant with
            // the boundaries already rounded: 0 is +x, which is octant 0, and
            // going clockwise on screen (y grows down) is heading increasing.
            let oct = (flock.heading(s, i) + 1125) / 2250;
            fb.put(surf, y, x, arrow(oct % 8), bird_colour(sp, s.maxs, mode), back)
        }
    }
};

// status(surf, s, seed, fps, mode, paused, meter, help) -- the line along the
// bottom of the screen, built into the fixed buffer above and drawn in place.
// Padded to the full width so a shorter line erases the longer one it replaces.
// 'h' puts the key list here instead.
def status(surf: fb.Surface, s: flock.Flock, seed: long, fps: long, mode: long,
           paused: bool, meter: time.Fps, help: bool, pairs: long,
           rules: str) {
    let back = back_colour(mode);
    sb_reset();
    if (help) {
        sb_str("q quit  space pause  . step  r reseed  1/2/3 rules  0 all  c colour  +/- speed  h back");
        sb_pad(s.w);
        sb_draw(surf, s.h, fb.rgb(255, 200, 0), back)
    } else {
        sb_str("frame ");
        sb_num(s.gen);
        sb_str("  ");
        if (flock.mean_order(s) == 0) {
            sb_str("NOBODDY SEES ANYBODY ");
        } else if (paused) {
            sb_str("PAUSED ");
        } else {
            sb_str("running ");
        };
        sb_str("rules ");
        sb_str(rules);
        sb_str("  |v| ");
        sb_fixed(flock.mean_speed(s));
        sb_str("/");
        sb_fixed(s.maxs);
        sb_str("  see ");
        sb_num(pairs);
        sb_str("  ");
        // The measured rate and the cap it is measured against, as "30.00/30",
        // so the line fits 80 columns even with a three-digit frame count.
        if (fps > 0) {
            sb_num(time.fps_x100(meter) / 100);
            sb_byte(46);
            let f = time.fps_x100(meter) % 100;
            if (f < 10) { sb_byte(48); };
            sb_num(f);
            sb_str("/");
            sb_num(fps);
            sb_str("fps ")
        } else {
            sb_str("uncapped ")
        };
        sb_str("seed ");
        sb_num(seed);
        sb_pad(s.w);
        sb_draw(surf, s.h, fb.DEFAULT, back)
    }
};

// stats_block(where, wall_us, gen, h0, h1, pairs) -- the --stats line, printed
// on the PRIMARY screen.  Everything written to the alt screen is thrown away
// when it is left, and restore_all_exit() exits, so --stats could never print
// anything from there.
def stats_block(where: str, wall_us: long, gen: long, h0: long, h1: long,
                pairs: long) {
    let per = 0;
    if (gen > 0) { per = wall_us / gen; };
    eputs("boids: " + where + "\n");
    eputs("boids:   " + tostring(gen) + " frames in " + tostring(wall_us)
          + " us (" + tostring(wall_us / 1000) + " ms, "
          + tostring(per) + " us/frame)\n");
    eputs("boids:   heap " + tostring(h0) + " -> " + tostring(h1) + " B  ("
          + tostring(h1 - h0) + " over the loop)\n");
    // wall_us is microseconds, so the rate multiplies by 1e6.  It multiplied by
    // 1e3 first, which reported 1347 pair-steps/s for a run that did about a
    // million.
    if (gen > 0 && wall_us > 0) {
        let steps = gen * pairs;
        eputs("boids:   " + tostring(steps) + " pair-steps at "
              + tostring(steps * 1000000 / wall_us) + "/s, "
              + tostring(pairs) + " pairs/frame\n")
    }
};

// run_live(...) -> long -- the interactive path.  Every exit goes through the
// restore_all_exit at the bottom, including the one the quit key causes.
def run_live(s: flock.Flock, seed: long, fps: long, mode: long,
             want_stats: bool) -> long {
    if (!term.raw_mode()) {
        eputs("boids: stdin is not a terminal, so there is no live view.\n");
        eputs("boids: use --no-tty --frames N for the headless report, e.g. "
              + "`boids --no-tty --frames 200`.\n");
        return 1
    };
    term.enter_screen();
    term.arm_watchdog();

    let rows = s.h + 1;
    let cols = s.w;
    let surf = fb.new(rows, cols);
    let meter = time.fps_new();
    let w0 = time.now_us();
    let cap = fps;
    if (cap < 1) { cap = 1000000; };
    let pacer = time.pacer_new(cap);
    let running = true;
    let paused = false;
    let help = false;
    let cur_mode = mode;
    let cur_fps = fps;
    let cur_seed = seed;
    let pairs = 0;
    // The rule NAMES are a str built by concatenation, so mask_name() allocates
    // -- three of them a frame at 30 fps is ~5 KB/s and the heap is an arena, so
    // it is a leak that only shows up in a long run.  The mask changes only when
    // a key is pressed, so the name is built once here and refreshed there.
    let cur_mask = flock.mask();
    let cur_rules = flock.mask_name(cur_mask);

    // Read here, not one line earlier: time.pacer_new() above returns a RECORD
    // LITERAL and that is its own 48 bytes -- a setup cost, not a frame cost.
    // With the reading taken before it, --stats reported a constant "48 bytes
    // over N frames", which is neither zero nor a leak, and is the least useful
    // of the three answers.
    let h0 = heap_used();

    while (running) {
        let wait = time.pacer_next(pacer);

        // The window can change under a running program.  winsize() is one
        // ioctl into a fixed buffer, so it is cheap enough to ask every frame;
        // a rebuild allocates one new flock and resizes the surface, which is
        // why it only happens when the size really changed.
        let packed = winsize();
        let wr = ws_rows(packed);
        let wc = ws_cols(packed);
        if (wr != rows || wc != cols) {
            let nw = wc;
            let nh = wr - 1;
            if (nw < flock.MINW) { nw = flock.MINW; };
            if (nh < flock.MINH) { nh = flock.MINH; };
            if (nw > flock.MAXW) { nw = flock.MAXW; };
            if (nh > flock.MAXH) { nh = flock.MAXH; };
            let ns = flock.blank(nw, nh, s.n);
            flock.copy_params(ns, s);
            flock.set_desire(ns, s.desire);
            flock.seed_flock(ns, cur_seed, s.desire / 2, s.desire * 3 / 2);
            s = ns;
            cols = nw;
            rows = nh + 1;
            fb.resize(surf, rows, cols);
            fb.clear(surf, back_colour(cur_mode));
            time.pacer_start(pacer);
            draw(surf, s, cur_mode);
            status(surf, s, cur_seed, cur_fps, cur_mode, paused, meter, help,
                   pairs, cur_rules);
            fb.flush_diff(surf)
        };

        if (wait >= 0) {
            if (!paused) {
                flock.step(s);
                pairs = s.pairs
            };
            draw(surf, s, cur_mode);
            status(surf, s, cur_seed, cur_fps, cur_mode, paused, meter, help,
                   pairs, cur_rules);
            fb.flush_diff(surf);
            time.fps_tick(meter)
        };

        // One keypress, polled WITHOUT waiting.
        //
        // read_key_timeout(ms) spends the wait in the terminal's VTIME, which
        // counts DECISECONDS: any non-zero request is rounded UP to the next
        // 100 ms, so `read_key_timeout(20)` is a 100 ms block.  At a 33 ms
        // frame period that makes every frame late by more than a whole period,
        // the pacer drops it, and -- because a dropped frame still costs its
        // 100 ms -- the schedule never recovers.  The first version of this
        // loop did exactly that and sat at 0.6 fps with the frame counter
        // stuck on 1.  A 0 ms deadline is an immediate poll (VMIN=0, VTIME=0),
        // so a key is picked up within one frame period and the loop's own
        // pacing is the only clock in it.
        //
        // The keys are compared with ord("q") and friends rather than written
        // as `k == 'q'`: this compiler has no character literal at all, and
        // `'q'` is a lexer error.  term.y's header comment shows the `'q'`
        // spelling; the numbers are what works.
        let k = term.read_key_timeout(0);
        if (k != term.KEY_NONE) {
            if (k == ord("q") || k == term.KEY_ESC || k == 3) {
                running = false
            } else if (k == 32) {
                paused = !paused
            } else if (k == 46) {
                flock.step(s);
                pairs = s.pairs
            } else if (k == ord("h") || k == 63) {
                help = !help
            } else if (k == ord("r")) {
                cur_seed = cur_seed + 1;
                flock.seed_flock(s, cur_seed, s.maxs / 2, s.maxs)
            } else if (k == ord("1") || k == ord("2") || k == ord("3")) {
                let bit = flock.M_SEP;
                if (k == ord("2")) { bit = flock.M_ALI; };
                if (k == ord("3")) { bit = flock.M_COH; };
                cur_mask = cur_mask ^ bit;
                flock.set_mask(cur_mask);
                cur_rules = flock.mask_name(cur_mask)
            } else if (k == ord("0")) {
                cur_mask = flock.M_ALL;
                flock.set_mask(cur_mask);
                cur_rules = flock.mask_name(cur_mask)
            } else if (k == ord("c")) {
                cur_mode = (cur_mode + 1) % 3;
                fb.clear(surf, back_colour(cur_mode))
            } else if (k == ord("+") || k == 61) {
                cur_fps = if (cur_fps == 0) { 30 } else { cur_fps * 2 };
                pacer = time.pacer_new(if (cur_fps > 0) { cur_fps } else { 1000000 });
                time.pacer_start(pacer)
            } else if (k == ord("-") || k == 95) {
                cur_fps = cur_fps / 2;
                if (cur_fps < 1) { cur_fps = 0; };
                pacer = time.pacer_new(if (cur_fps > 0) { cur_fps } else { 1000000 });
                time.pacer_start(pacer)
            }
        }
    };

    let h1 = heap_used();
    // --stats has to be printed on the PRIMARY screen, which is what
    // stats_block's eputs does.  term.restore() and leave_screen() are
    // idempotent, so doing them here and then calling restore_all_exit below is
    // safe -- the last call is still the one that exits.
    term.restore();
    term.leave_screen();
    if (want_stats) {
        stats_block("live", time.now_us() - w0, s.gen, h0, h1, pairs)
    };
    term.restore_all_exit(0);
    0
};

// -- main --------------------------------------------------------------------

// main() -> the exit STATUS, and `exit(main())` at the bottom of the file is
// what reaches the shell.  `main();` would discard it and exit 0 even when a
// diagnostic had been printed -- an error path that "returns 1" and then exits
// 0 looks successful to anything watching, which is worse than no message at
// all.
//
// So every path here RETURNS a status and none of them calls exit() itself:
// exit() is void, so a body ending in exit() has no value, and `-> long` on the
// function is then a compile error.
def main() -> long {
    args.init("boids",
              "Reynolds' flocking: separation, alignment, cohesion, in fixed-point Q16",
              OPTS,
              "");
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

    let want_check = args.has("check");
    let want_stats = args.has("stats");
    let seed = args.get_long("seed", 1);
    // Whether --frames was given is asked SEPARATELY from its value.  The first
    // version used -1 as the "not given" sentinel and checked `frames < -1`,
    // which meant `--frames=-1` was indistinguishable from not giving it at
    // all: it printed the default 200-frame report and exited 0.  A number the
    // user typed must never be the same as a number they did not.
    let frames = args.get_long("frames", 0);
    let frames_given = args.has("frames");
    let dump = args.get_long("dump", 0);
    let n_ask = args.get_long("boids", 120);
    let fps = args.get_long("fps", 30);
    let no_tty = args.has("no-tty") || frames_given;

    if (frames_given && frames < 0) {
        return die("--frames cannot be negative (got " + tostring(frames) + ")")
    };
    if (dump < 0) {
        return die("--dump cannot be negative (got " + tostring(dump) + ")")
    };
    if (fps < 0) {
        return die("--fps cannot be negative (got " + tostring(fps) + ")")
    };
    if (seed < 1) {
        return die("--seed is 1 or more (got " + tostring(seed)
                   + "); the generator folds 0 to 1, and saying otherwise here "
                   + "would be a lie")
    };
    if (n_ask < 1 || n_ask > flock.MAXB) {
        // An over-large request is REJECTED rather than clamped.  The store is
        // fixed-size, so 9999 boids cannot exist; saying so is better than
        // quietly running 512 of them under a flag that asked for 9999.
        return die("--boids is 1.." + tostring(flock.MAXB) + " (got "
                   + tostring(n_ask) + ")")
    };
    // --color is validated HERE, with the other flags, rather than on the live
    // path where it is used.  Validated down there, `--no-tty --color nonsense`
        // printed a perfectly normal report and exited 0: the headless path
    // returns before the colour is ever looked at, so a typo in the colour went
    // unnoticed for exactly the runs that are compared byte for byte.
    let cname = args.get_str("color", "speed");
    let mode = 1;
    if (cname == "mono") { mode = 0; };
    if (cname == "speed") { mode = 1; };
    if (cname == "depth") { mode = 2; };
    if (cname != "mono" && cname != "speed" && cname != "depth") {
        return die("--color must be mono, speed or depth (got '" + cname + "')")
    };

    // The weights and the speeds arrive in hundredths -- there is no
    // float -> long to speak in (ORCHESTRATOR.md 2.4a) -- and go straight into
    // Q16.  Each is range-checked HERE, in main, so the message can name the
    // flag; hundredths() itself only clamps.
    let wsep = args.get_long("wsep", 150);
    let wali = args.get_long("wali", 100);
    let wcoh = args.get_long("wcoh", 90);
    let maxs_ask = args.get_long("maxspeed", 140);
    if (wsep < 0 || wsep > 900) {
        return die("--wsep is 0..900 hundredths (got " + tostring(wsep) + ")")
    };
    if (wali < 0 || wali > 900) {
        return die("--wali is 0..900 hundredths (got " + tostring(wali) + ")")
    };
    if (wcoh < 0 || wcoh > 900) {
        return die("--wcoh is 0..900 hundredths (got " + tostring(wcoh) + ")")
    };
    if (maxs_ask < 1 || maxs_ask > 900) {
        return die("--maxspeed is 1..900 hundredths of a unit per step (got "
                   + tostring(maxs_ask) + ")")
    };
    // --rules, so the three rules can be seen SEPARATELY in a golden file as
    // well as in --check.  It is the same module-level mask --check narrows, and
    // the interactive view's 1/2/3 keys toggle.
    let rules_arg = args.get_str("rules", "all");
    let want_mask = parse_rules(rules_arg);
    if (want_mask < 0) {
        return die("--rules wants all, none, or some of sep/ali/coh joined "
                   + "with '+' (got '" + rules_arg + "')")
    };
    let view = args.get_long("view", 9);
    let sep = args.get_long("sep", 4);
    if (view < 1 || view > 64) {
        return die("--view is 1..64 units (got " + tostring(view) + ")")
    };
    if (sep < 1 || sep > 64) {
        return die("--sep is 1..64 units (got " + tostring(sep) + ")")
    };

    // --size, or the terminal's own size, or a default that needs neither.
    //
    // winsize() is the module's own ioctl into a fixed buffer (see its comment),
    // and it is safe to call here: the headless path must not depend on the
    // terminal, so when --size is given nothing reads the window at all.
    let sz_arg = args.get_str("size", "");
    let w = 0;
    let h = 0;
    if (len(sz_arg) > 0) {
        if (!parse_size(sz_arg)) {
            return die("--size wants WxH in units, e.g. --size 120x40 (got '"
                       + sz_arg + "')")
        };
        w = SIZE_W;
        h = SIZE_H
    } else {
        let packed = winsize();
        w = ws_cols(packed);
        h = ws_rows(packed) - 1;
        if (h < flock.MINH) { h = flock.MINH; };
        if (w < flock.MINW) { w = flock.MINW; };
        if (w > flock.MAXW) { w = flock.MAXW; };
        if (h > flock.MAXH) { h = flock.MAXH; }
    };
    if (w < flock.MINW || h < flock.MINH) {
        return die("the world must be at least " + tostring(flock.MINW) + "x"
                   + tostring(flock.MINH) + " units (got " + tostring(w) + "x"
                   + tostring(h) + ")")
    };
    if (w > flock.MAXW || h > flock.MAXH) {
        return die("the world is at most " + tostring(flock.MAXW) + "x"
                   + tostring(flock.MAXH) + " units (got " + tostring(w) + "x"
                   + tostring(h) + "); the store is fixed-size, and a Q16 "
                   + "squared distance has to stay inside a signed long")
    };

    // --check builds its own worlds and needs no arguments at all.  It runs
    // BEFORE a flock is allocated, so it cannot be affected by any of the
    // settings above -- which is the point: the check tests the arithmetic and
    // the rules, not the option table.
    if (want_check) { return check.run(w, h); };

    let s = flock.blank(w, h, n_ask);
    flock.set_view(s, view);
    flock.set_sep(s, sep);
    flock.set_weights(s, hundredths(wsep), hundredths(wali), hundredths(wcoh));
    // dt is the integration scale, and it is what makes the flock look like a
    // flock.  At dt = 1.0 the three weighted forces SUM to several max speeds,
    // the sum lands on the clamp every step, and the "max |v|" column of the
    // table reads 1.39 for ever -- every bird pinned to the limit, no bird
    // outrunning another.  At dt = 0.5 with the max force one max speed, a boid
    // changes course over a few frames instead of instantly, which is what
    // makes the mean speed settle somewhere BELOW the cap.
    flock.set_limits(s, hundredths(maxs_ask), hundredths(maxs_ask), 32768);
    // ... and the flock CRUISES at 65% of the limit, so the clamp is there for
    // the separation spikes and not for the cruise.
    flock.set_desire(s, hundredths(maxs_ask) * 65 / 100);
    // Seeded around the CRUISING speed rather than the limit: a flock that
    // starts pinned at its maximum spends its first ten frames decelerating,
    // which is not what the picture is about.  The spread is +-50% of desire, so
    // the flock starts with real variety in its speeds and settles out of it.
    flock.set_mask(want_mask);
    flock.seed_flock(s, seed, s.desire / 2, s.desire * 3 / 2);

    // The headless path, which is also where a terminal-less run ends up.
    if (no_tty) {
        let nf = 200;
        if (frames_given) { nf = frames; };
        return report.run(s, nf, dump, want_stats, seed)
    };

    // The live path.  It needs a terminal on BOTH ends -- stdout to draw on and
    // stdin to read keys from -- and a one-sided pty would render into the void.
    run_live(s, seed, fps, mode, want_stats)
};

// parse_rules(s) -> the rule mask for "all", "none", "sep", "ali", "coh" or any
// of them joined with '+' -- or -1 for anything else, which is what main() turns
// into a message and exit 1.
//
// "all" and "none" are the two that matter as words: "none" is a real request
// (a swarm that flies straight is a thing worth seeing and worth a golden file),
// and the empty mask is exactly what --check's "with every rule off, NO bird
// turned" case uses.
//
// The walk looks at the NEXT THREE BYTES -- not at the whole remainder, which
// is what the first version compared and which is why "sep+coh" was rejected:
// the remainder there is "sep+coh", not "sep".  And there is no `in` for str in
// this language and no `startswith`, so a slice is the honest tool.
//
// Every slice is bounded by `i + k <= n` first, because an out-of-range slice is
// a runtime trap and a trap prints to STDOUT -- which, in this program, is the
// golden file.
def parse_rules(s: str) -> long {
    if (s == "all") { return flock.M_ALL };
    if (s == "none" || s == "") { return 0 };
    let m = 0;
    let i = 0;
    let n = len(s);
    while (i < n) {
        let c = s[i];
        if (c == 43) {            // '+' -- a separator, so it may not lead or
            if (i == 0 || i == n - 1) { return 0 - 1 };   // trail
            i = i + 1
        } else if (i + 3 <= n) {
            let t = s[i:i + 3];
            if (t == "sep") {
                m = m | flock.M_SEP;
                i = i + 3
            } else if (t == "ali") {
                m = m | flock.M_ALI;
                i = i + 3
            } else if (t == "coh") {
                m = m | flock.M_COH;
                i = i + 3
            } else {
                return 0 - 1
            }
        } else {
            return 0 - 1
        }
    };
    m
};

// hundredths(n) -> n hundredths in Q16, clamped to 900.00.  The whole program
// speaks hundredths to its user because there is no float -> long to speak in
// (ORCHESTRATOR.md 2.4a).
//
// It CLAMPS rather than exiting, and main() is what refuses an out-of-range
// value with a message.  A helper that called exit() in the middle would make
// its own body void, which does not typecheck against the long it returns on
// the other path -- the checker wants both arms of an `if` to agree.
def hundredths(n: long) -> long {
    let v = n;
    if (v < 0) { v = 0; };
    if (v > 900) { v = 900; };
    v * 65536 / 100
};

// parse_size(spec) -> true when spec is "120x40", with the answer left in
// SIZE_W and SIZE_H (declared at the top of this file, because a module-level
// variable has to be declared before the code that names it).
//
// Into module-level variables rather than a returned record, because a record
// out of a parser allocates 40 bytes a call and this is called on every option
// parse; and NOT through `long` parameters, because a scalar parameter is passed
// BY VALUE: writing to it inside the function changes the local copy and
// main() still reads its own zero.  That cost one debugging round here --
// --size 60x24 was rejected as "the world must be at least 8x6 (got 0x0)".
def parse_size(spec: str) -> bool {
    let n = len(spec);
    if (n == 0) { return false };
    let i = 0;
    let seen_x = false;
    let a = 0;
    let b = 0;
    let d1 = 0;
    let d2 = 0;
    while (i < n) {
        let c = spec[i];
        if (c == 120 || c == 88) {          // 'x' or 'X'
            if (seen_x) { return false };
            seen_x = true;
            i = i + 1
        } else if (c >= 48 && c <= 57) {
            if (!seen_x) {
                a = a * 10 + (c - 48);
                d1 = d1 + 1
            } else {
                b = b * 10 + (c - 48);
                d2 = d2 + 1
            };
            i = i + 1
        } else {
            return false
        }
    };
    if (d1 == 0 || d2 == 0) { return false };
    if (a < flock.MINW || a > flock.MAXW) { return false };
    if (b < flock.MINH || b > flock.MAXH) { return false };
    SIZE_W = a;
    SIZE_H = b;
    true
};

exit(main());