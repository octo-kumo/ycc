// roguelike.y -- a turn-based roguelike: procedural dungeon, field of view,
// and a real terminal UI.
//
//   usage: roguelike [options]
//
//   rooms and corridors, a shadowed field of view you can see the edge of, a
//   turn loop with bumping, doors, monsters, hit points, a pack and stairs
//   that go down.  No arguments means: the dungeon, the alt screen, and the
//   arrow keys.  `--frames N --no-tty` is the deterministic run.
//
//   build:  ycc -o roguelike roguelike.y     (fx.y fb.y term.y time.y args.y
//                                              rules.y dungeon.y fov.y game.y
//                                              view.y textout.y rnd.y must sit
//                                              beside it)
//   run:    ./roguelike                     interactive, until q or Escape
//          ./roguelike --frames 5 --no-tty --seed 1    the deterministic run
//          ./roguelike --check 200         the generator and field-of-view
//                                          validator over 200 levels
//
// ---------------------------------------------------------------------------
// THE MODULES
// ---------------------------------------------------------------------------
//
//   rnd.y      seeded LCG; the only source of randomness in the program
//   dungeon.y  rooms, corridors, doors, stairs, and the flood fill that proves
//              the player is not stranded
//   fov.y      the symmetric-permissive field of view, plus a second and
//              independent implementation used only to check the first
//   rules.y    the two record unions -- what a TILE is and what an ITEM is --
//              and the monster table
//   game.y     the state and the turn, written without `break` or `continue`
//   view.y     one decision per tile, drawn two ways: fb.y for the terminal,
//              ASCII for the deterministic dump
//   textout.y  the fixed byte sink the deterministic path prints through
//
// ---------------------------------------------------------------------------
// DETERMINISM
// ---------------------------------------------------------------------------
//
// There is no unseeded randomness anywhere on any path.  `--seed` defaults to 1
// and the whole run is a pure function of (seed, size, depth, walk), so the
// default path is reproducible too.  Nothing here reads the clock, the pid, or
// getrandom: `clock_us` appears once, in the `--time` report on stderr, and
// never in the output EXPECTED holds.

import fb;
import term;
import time;
import args;
import rnd;
import dungeon;
import fov;
import rules;
import game;
import view;
import textout;

// ─────────────────────────────────────────────────────────────── the options ───

let OPTS: [args.Opt] = [
    { long: "frames", short: "n", kind: args.NUM,
      help: "run exactly N turns, then exit 0 (default 0: play until q)" },
    { long: "seed", short: "s", kind: args.NUM,
      help: "random seed, 0..; the same seed gives the same dungeon and walk (default 1)" },
    { long: "size", short: "", kind: args.STR,
      help: "dungeon size WxH, " + tostring(dungeon.MIN_W) + "x"
            + tostring(dungeon.MIN_H) + " .. " + tostring(dungeon.MAX_W) + "x"
            + tostring(dungeon.MAX_H) + " (default 40x24)" },
    { long: "depth", short: "d", kind: args.NUM,
      help: "how many levels to descend before you win (default 3)" },
    { long: "walk", short: "w", kind: args.STR,
      help: "the scripted walk for --no-tty: hjkl yubn move, , grab, 1-8 use" },
    { long: "no-tty", short: "", kind: args.BOOL,
      help: "print the dungeon as text instead of drawing a terminal" },
    { long: "quiet", short: "Q", kind: args.BOOL,
      help: "no per-turn digest lines; the map and the summary still print" },
    { long: "invuln", short: "", kind: args.BOOL,
      help: "monsters cannot hurt you -- a measurement aid, so --frames 10000" },
    { long: "check", short: "", kind: args.NUM,
      help: "validate the generator and the field of view over N levels, then exit" },
    { long: "time", short: "", kind: args.BOOL,
      help: "report wall clock, turns per second and the heap delta on stderr" }
];
// NOTE: `--help` is NOT in the spec, on purpose.  args.y recognises it only
// when the spec does NOT declare it -- declaring a BOOL called "help" makes it
// an ordinary flag, so `--help` stops printing the usage and the program falls
// through to the interactive path and dies with "not a terminal".  args prints
// its own `-h, --help` line either way.

const DEF_W = 40;
const DEF_H = 24;
const DEF_DEPTH = 3;
// The default script, and every character in it is a key the interactive path
// answers to: l east, ',' grab, l east, j south, j south, h west.  The grab is
// second on purpose -- game.place_start_potion() guarantees a potion one tile
// east of the start, so the default run always exercises the pack and the
// message log.
//
// An earlier default spelled the cardinal directions e/s/w, which no roguelike
// uses and which this one deliberately does NOT bind, so three of its turns were
// silently free.  check_walk() cannot catch that: a character that is a legal
// ACTION but simply unbound is a no-op, not an error.  Worth knowing before you
// trust a golden.
const DEF_WALK = "l,ljjh";

// ──────────────────────────────────────────────────────── the key tables ───
//
// Two fixed [long; 128] tables and a move string, built once at start-up.  A
// `match` on literal byte values would be forty lines of the same comparison,
// and a map would be a linear scan (ORCHESTRATOR.md 2.8); a 128-entry direct
// table is one load.
const MOVE1: str = "hjklyubn";        // vi: h j k l, then the four diagonals
const GRAB1: str = ",g";
const DIRS_X: [long; 8] = [0 - 1, 0, 0, 1, 0 - 1, 1, 0 - 1, 1];
const DIRS_Y: [long; 8] = [0, 1, 0 - 1, 0, 0 - 1, 0 - 1, 1, 1];

let MOVED: [long; 128] = [0; 128];
let MDX: [long; 128] = [0; 128];
let MDY: [long; 128] = [0; 128];
let GRABBED: [long; 128] = [0; 128];
let USED: [long; 128] = [0; 128];

def build_keys() -> void {
    let i = 0;
    while (i < 8) {
        let b = byte_at(MOVE1, i);
        MOVED[b] = 1;
        MDX[b] = DIRS_X[i];
        MDY[b] = DIRS_Y[i];
        // the capital letter moves the same way, so Shift is the second hand
        MOVED[b - 32] = 1;
        MDX[b - 32] = DIRS_X[i];
        MDY[b - 32] = DIRS_Y[i];
        i = i + 1;
    };
    let g = 0;
    while (g < 2) {
        GRABBED[byte_at(GRAB1, g)] = 1;
        g = g + 1;
    };
    // '.' waits a turn without moving -- the rest key every roguelike has
    MOVED[46] = 1;
    MDX[46] = 0;
    MDY[46] = 0;
    let d = 0;
    while (d < 8) {
        USED[49 + d] = d + 1;
        d = d + 1;
    };
};

// ───────────────────────────────────────────────────────────── diagnostics ───
//
// Every one of these is a clean diagnostic on stderr with exit 1: a bad flag, a
// missing value, an unknown walk letter, a size that cannot hold a dungeon, a
// depth below one, a negative seed.  Nothing here divides, indexes or
// subtracts before the check that makes it safe.

def die(msg: str) -> void {
    eputs("roguelike: ");
    eputs(msg);
    eputs("\nroguelike: try --help\n");
    exit(1)
};

// parse_size(s) -> long -- W*1000000 + H, or 0 when the string is not that shape
// or the numbers are out of range.  `0` is the only failure value, and no valid
// size maps to it.
def parse_size(s: str) -> long {
    let at = s.index_of("x");
    if (at < 1) { return 0; };
    let a = s[0:at];
    let b = s[at + 1:];
    if (len(a) > 6 || len(b) > 6) { return 0; };
    if (!args.num_ok(a) || !args.num_ok(b)) { return 0; };
    let w = tonum(a);
    let h = tonum(b);
    if (w < dungeon.MIN_W || w > dungeon.MAX_W) { return 0; };
    if (h < dungeon.MIN_H || h > dungeon.MAX_H) { return 0; };
    w * 1000000 + h
};

// check_walk(s) -- refuse anything that is not a scripted action, so a typo in a
// walk string is a message and not a silent no-op for the rest of the run.
def check_walk(s: str) -> void {
    let i = 0;
    let n = len(s);
    while (i < n) {
        let b = byte_at(s, i);
        let ok = b == 46 || MOVED[b] == 1 || GRABBED[b] == 1
                 || (b >= 49 && b <= 56);
        if (!ok) {
            die("--walk has '" + chr(b) + "', which is not a move, grab or use; "
                + "letters are hjkl yubn (or their capitals), '.' waits, ',' grabs, "
                + "1-8 use a pack slot");
        };
        i = i + 1;
    };
};

// ──────────────────────────────────────────────────────── the walk script ───
//
// The headless path is a SCRIPTED walk, and that is what makes `--frames` a
// deterministic mode rather than a random one: same seed, same walk, same
// output.  `--walk` replaces it.

let WALK: str = DEF_WALK;
let WI: long = 0;

def next_byte() -> long {
    let n = len(WALK);
    let b = -1;
    if (n > 0) {
        b = byte_at(WALK, WI);
        WI = WI + 1;
        if (WI >= n) { WI = 0; };
    };
    b
};

// one_scripted_turn() -> long -- the same action a key would produce, routed
// through exactly the same game functions.  1 means a turn was spent.
def one_scripted_turn() -> long {
    let b = next_byte();
    if (b < 0) {
        return game.step(0, 0);
    };
    let spent = 0;
    if (MOVED[b] == 1) {
        spent = game.step(MDX[b], MDY[b]);
    } else if (GRABBED[b] == 1) {
        if (game.grab() == 1) {
            game.spend();
            spent = 1;
        };
    } else if (b >= 49 && b <= 56) {
        if (game.use_slot(b - 49) == 1) {
            game.spend();
            spent = 1;
        };
    };
    spent
};

// ──────────────────────────────────────────────────────── headless output ───

def put_line(s: str) -> void {
    textout.out_str(s);
    textout.out_str("\n");
};

// digest(f, spent) -- one line per turn: the state, the visible count and the
// explored count.  Strictly integers and literals through the fixed byte sink,
// so a turn of the digest allocates nothing and the heap number below it is a
// measurement rather than a claim.
def digest(f: long, spent: long) -> void {
    textout.out_str("turn ");
    textout.out_pad(f, 4);
    textout.out_str("  spent ");
    textout.out_pad(spent, 2);
    textout.out_str("  at ");
    textout.out_pad(game.PX, 3);
    textout.out_str(",");
    textout.out_pad(game.PY, 3);
    textout.out_str("  depth ");
    textout.out_pad(game.DEPTH, 2);
    textout.out_str("  hp ");
    textout.out_pad(game.P_HP, 3);
    textout.out_str("/");
    textout.out_pad(game.P_MAXHP, 3);
    textout.out_str("  lit ");
    textout.out_pad(fov.LIT, 5);
    textout.out_str("  seen ");
    textout.out_pad(game.SEEN_N, 5);
    textout.out_str("  ");
    textout.out_pad(game.explored_pct(), 3);
    textout.out_str("%  dmg ");
    textout.out_pad(game.LAST_DMG, 3);
    textout.out_str("  taken ");
    textout.out_pad(game.LAST_TAKEN, 3);
    textout.out_str("  foes ");
    textout.out_pad(game.alive_count(), 3);
    textout.out_str("  msg ");
    textout.out_pad(game.MSG[game.MSG_SLOTS - 1], 3);
    textout.out_str("\n");
};

def level_line() -> void {
    textout.out_str("level ");
    textout.out_pad(game.DEPTH, 2);
    textout.out_str(": rooms ");
    textout.out_pad(dungeon.NROOMS, 3);
    textout.out_str("  corridors ");
    textout.out_pad(dungeon.NCORR, 3);
    textout.out_str("  segments ");
    textout.out_pad(dungeon.NSEG, 3);
    textout.out_str("  floor ");
    textout.out_pad(dungeon.NFLOOR, 5);
    textout.out_str("/");
    textout.out_pad(game.MAP_W * game.MAP_H, 5);
    textout.out_str(" tiles (");
    textout.out_pad(dungeon.NFLOOR * 100 / (game.MAP_W * game.MAP_H), 3);
    textout.out_str("%)  monsters ");
    textout.out_pad(game.MN, 3);
    textout.out_str("  items ");
    textout.out_pad(count_items(), 3);
    textout.out_str("  stairs ");
    textout.out_pad(dungeon.STAIRS_X, 3);
    textout.out_str(",");
    textout.out_pad(dungeon.STAIRS_Y, 3);
    textout.out_str("\n");
};

def count_items() -> long {
    let n = 0;
    let i = 0;
    let all = game.MAP_W * game.MAP_H;
    while (i < all) {
        if (game.ITEM[i] != 0) { n = n + 1; };
        i = i + 1;
    };
    n
};

def pack_line() -> void {
    textout.out_str("pack:");
    let k = 0;
    while (k < game.INV_SLOTS) {
        if (game.INV_FULL[k] == 1) {
            textout.out_str("  [");
            textout.out_num(k + 1);
            textout.out_str("] ");
            textout.out_str(rules.loot_name_of_kind(game.INV_KIND[k]));
            if (game.INVN[k] > 1) {
                textout.out_str(" x");
                textout.out_num(game.INVN[k]);
            };
        };
        k = k + 1;
    };
    textout.out_str("\n");
};

// ───────────────────────────────────────────────────────────── the summary ───

def status_name() -> str {
    if (game.STATUS == game.S_DEAD) { return "dead"; };
    if (game.STATUS == game.S_ESCAPED) { return "escaped"; };
    if (game.STATUS == game.S_FAILED) { return "no-dungeon"; };
    "alive"
};

def summary(frames: long, heap_delta: long) -> void {
    textout.out_num(game.TURNS);
    textout.out_str(" turns in ");
    textout.out_num(frames);
    textout.out_str(" frames  depth ");
    textout.out_pad(game.DEPTH, 2);
    textout.out_str("/");
    textout.out_pad(game.MAX_DEPTH, 2);
    textout.out_str("  hp ");
    textout.out_pad(game.P_HP, 3);
    textout.out_str("/");
    textout.out_pad(game.P_MAXHP, 3);
    textout.out_str("  gold ");
    textout.out_pad(game.P_GOLD, 4);
    textout.out_str("  kills ");
    textout.out_pad(game.KILLS, 3);
    textout.out_str("  seen ");
    textout.out_pad(game.explored_pct(), 3);
    textout.out_str("%  foes ");
    textout.out_pad(game.alive_count(), 3);
    textout.out_str("  status ");
    textout.out_str(status_name());
    textout.out_str("  heap ");
    textout.out_pad(heap_delta, 4);
    textout.out_str(" B over ");
    textout.out_num(frames);
    textout.out_str(" frames\n");
};

// ───────────────────────────────────────────────────── the interactive path ───

let WSB: [byte] = [0; 64];
let trows: long = 24;
let tcols: long = 80;
let HELP: long = 0;

// poll_winsize() -> long -- TIOCGWINSZ into a byte buffer of our own plus
// term.rd16, which is the decode term.size() performs -- same answer, one
// syscall, ZERO bytes of heap.  term.size() would do too, but it answers with a
// record and a record literal is evaluated onto the heap every time the
// expression runs, so on a per-frame poll it would leak.  A [byte] has to be
// growable to be passed at all: a [byte; N] is not a [byte] in Y.
def poll_winsize() -> long {
    if (syscall(16, 1, term.TIOCGWINSZ, &WSB[0]) < 0) { return 0; };
    let r = term.rd16(WSB, 0);
    let c = term.rd16(WSB, 2);
    if (r < 1 || c < 1) { return 0; };
    if (r == trows && c == tcols) { return 0; };
    trows = r;
    tcols = c;
    1
};

const HELP_LINES: [str; 9] = [
    "  Y -- the amulet is on the last level.  Walk onto the stair to descend.",
    "",
    "   hjkl   yubn     move (the capitals move the same way)",
    "   .              wait one turn",
    "   ,  or  g        pick up what you are standing on",
    "   1 .. 8         use that pack slot: drink, read, or ready",
    "   ?              this text          q  or  Escape  quit",
    "",
    "   '#' lit wall   ':' wall you remember   '.' lit floor   ',' floor you remember"
];

def draw_help(s: fb.Surface) -> void {
    let r = 1;
    while (r < 10 && r < s.rows - 4) {
        fb.fill_rect(s, r, 2, 1, s.cols - 4, 32, fb.rgb(150, 160, 170), fb.rgb(10, 10, 14));
        fb.text(s, r, 3, HELP_LINES[r - 1], fb.rgb(170, 178, 186), fb.rgb(10, 10, 14));
        r = r + 1;
    };
};

// report(bytes_sum, h0) -- the one-line summary the interactive path prints on
// stderr however it ends, `--frames` or `q`.  On stderr rather than stdout so it
// never lands inside the alt screen's byte stream, and identical on both exits so
// the two paths cannot drift apart.
def report(bytes_sum: long, h0: long) -> void {
    let h1 = heap_used();
    eputs("roguelike: ");
    eputs(tostring(game.TURNS));
    eputs(" turns, depth ");
    eputs(tostring(game.DEPTH));
    eputs("/");
    eputs(tostring(game.MAX_DEPTH));
    eputs(", hp ");
    eputs(tostring(game.P_HP));
    eputs("/");
    eputs(tostring(game.P_MAXHP));
    eputs(", gold ");
    eputs(tostring(game.P_GOLD));
    eputs(", kills ");
    eputs(tostring(game.KILLS));
    eputs(", explored ");
    eputs(tostring(game.explored_pct()));
    eputs("%, status ");
    eputs(status_name());
    eputs("\nroguelike: ");
    eputs(tostring(bytes_sum));
    eputs(" bytes of ANSI, heap_used ");
    eputs(tostring(h0));
    eputs(" -> ");
    eputs(tostring(h1));
    eputs(", delta ");
    eputs(tostring(h1 - h0));
    eputs("\n");
};

// play -- the interactive loop.  `--frames N` bounds it on this path too, so the
// same flag means "run exactly N turns" whether or not there is a terminal --
// except that a turn needs a key to happen, so on a terminal `--frames` ends the
// run once N keys' worth of turns have gone by, and a `--frames` that the walk
// can never reach (bumping a wall costs no turn) simply waits for more keys.
def play(srf: fb.Surface, frame_limit: long) -> long {
    // status row 0, the map from row 1, the pack, then the message log
    let rows = srf.rows;
    let cols = srf.cols;
    let camh = rows - 5;
    if (camh < 3) { camh = 3; };
    let camw = cols;
    if (camw > game.MAP_W) { camw = game.MAP_W; };
    let frames = 0;
    let quit = false;
    let bytes_sum = 0;
    let ih0 = heap_used();
    while (quit == false) {
        if (HELP != 0) {
            view.draw_window(srf, 1, camw, camh);
            draw_help(srf);
        } else {
            view.draw_window(srf, 1, camw, camh);
        };
        view.draw_status(srf, 0);
        view.draw_pack(srf, rows - 4);
        view.draw_msgs(srf, rows - 3);
        bytes_sum = bytes_sum + fb.flush_diff(srf);

        // A resize is looked for on the same beat as the input: Y has no
        // SIGWINCH, so the only way to follow one is to ask.
        let k = term.read_key_timeout(40);
        if (k == term.KEY_NONE) {
            if (poll_winsize() != 0) {
                let nr = trows;
                let nc = tcols;
                if (nr < 10) { nr = 10; };
                if (nc < 40) { nc = 40; };
                if (nr > fb.MAX_ROWS) { nr = fb.MAX_ROWS; };
                if (nc > fb.MAX_COLS) { nc = fb.MAX_COLS; };
                srf = fb.resize(srf, nr, nc);
                view.invalidate();
                frames = 0;
            };
        } else if (k == term.KEY_ESC || k == ord("q") || k == ord("Q")) {
            quit = true;
        } else if (k == term.KEY_UP) {
            game.step(0, 0 - 1);
        } else if (k == term.KEY_DOWN) {
            game.step(0, 1);
        } else if (k == term.KEY_LEFT) {
            game.step(0 - 1, 0);
        } else if (k == term.KEY_RIGHT) {
            game.step(1, 0);
        } else if (k >= 32 && k < 128 && MOVED[k] == 1) {
            game.step(MDX[k], MDY[k]);
        } else if (k >= 32 && k < 128 && GRABBED[k] == 1) {
            if (game.grab() == 1) { game.spend(); };
        } else if (k >= 49 && k <= 56) {
            if (game.use_slot(k - 49) == 1) { game.spend(); };
        } else if (k == ord("?")) {
            HELP = if (HELP != 0) { 0 } else { 1 };
        };
        frames = frames + 1;
        if (frame_limit > 0 && game.TURNS >= frame_limit) {
            report(bytes_sum, ih0);
            term.restore_all_exit(0);
        };
    };
    report(bytes_sum, ih0);
    bytes_sum
};

// ───────────────────────────────────────────────────────── the validator ───
//
// `--check N` is the acceptance gate for the two algorithms, and it is the reason
// both are trustworthy rather than merely plausible.  Four of the six checks are
// ASSERTED and two are REPORTED, and the split is deliberate:
//
//   ASSERTED
//     reach failures   flood the level from the player's start and require every
//                      room centre and the stairs to be in the fill.  A generator
//                      that strands the player is THE classic roguelike bug, and
//                      this is where it gets caught rather than by a player.
//     symmetry breaks  every tile the player can see can see the player back.
//                      This is the defining property of a symmetric field of view
//                      and the one that catches a leak and an over-shadow both.
//     neighbour misses every walkable 8-neighbour of the eye is visible.
//     batch/predicate  `fov.compute` marks exactly the tiles `fov.los` accepts, and
//     disagreements     nothing outside the radius is marked.  A sharp, cheap
//                      consistency check on the two entry points into the same
//                      predicate, which is where a bounds bug would live.
//     walk failures    N turns of a scripted walk per level: no trap, the player
//                      always on a walkable tile, hit points never out of range.
//                      (This is what caught the player walking into a wall.)
//
//   REPORTED, NOT ASSERTED
//     ray-vs-segment   fov.ray is a SECOND, INDEPENDENT implementation of the same
//                      idea -- no DDA, no error term, trigonometry instead of
//                      integer stepping -- and it is in the tree to be read and to
//                      be compared.  It is not an oracle, and pretending it were
//                      would be dishonest: a raymarch and a segment walk are two
//                      approximations of one curve and they disagree in BOTH
//                      directions, on the tiles where a ray grazes a corner and the
//                      permissive rule decides.  Over 200 levels the two disagree
//                      by about six tiles each way per level, and every one of
//                      them is a corner case.  The numbers are printed so the
//                      disagreement is visible rather than asserted away.
//
// So "the field of view respects walls" rests on the symmetry assertion, the
// neighbour assertion, the predicate consistency assertion, and on `los` being
// short enough to read in full: a monotone supercover DDA with the corner rule
// written out in one comment.

def count_lit() -> long {
    let n = 0;
    let i = 0;
    let all = dungeon.W * dungeon.H;
    while (i < all) {
        if (fov.VIS[i] == 1) { n = n + 1; };
        i = i + 1;
    };
    n
};

def check_run(n: long, base_seed: long) -> long {
    let reach_fail = 0;
    let asym = 0;
    let nb_fail = 0;
    let batch_fail = 0;
    let walk_fail = 0;
    let ray_los_only = 0;
    let ray_only = 0;
    let rooms_lo = 9999;
    let rooms_hi = 0;
    let rooms_sum = 0;
    let cov_lo = 100;
    let cov_hi = 0;
    let cov_sum = 0;
    let turns_done = 0;
    let kills = 0;
    let deepest = 0;
    let lit_sum = 0;
    let k = 1;
    while (k <= n) {
        let w = DEF_W + (k % 5) * 8;
        let h = DEF_H + (k % 3) * 6;
        dungeon.configure(w, h);
        let rooms = dungeon.generate(base_seed + k * 7919);
        if (rooms < 2) {
            walk_fail = walk_fail + 1;
        } else {
            if (dungeon.check_reachable() != 0) { reach_fail = reach_fail + 1; };
            if (rooms < rooms_lo) { rooms_lo = rooms; };
            if (rooms > rooms_hi) { rooms_hi = rooms; };
            rooms_sum = rooms_sum + rooms;
            let cov = dungeon.NFLOOR * 100 / (dungeon.W * dungeon.H);
            if (cov < cov_lo) { cov_lo = cov; };
            if (cov > cov_hi) { cov_hi = cov; };
            cov_sum = cov_sum + cov;
            let sx = dungeon.START_X;
            let sy = dungeon.START_Y;
            fov.compute(sx, sy, game.RADIUS);
            lit_sum = lit_sum + fov.LIT;
            let r2 = game.RADIUS * game.RADIUS;
            let y = 0;
            while (y < dungeon.H) {
                let x = 0;
                while (x < dungeon.W) {
                    let key = y * dungeon.W + x;
                    let dx = x - sx;
                    let dy = y - sy;
                    let outside = dx * dx + dy * dy > r2;
                    // BATCH/PREDICATE: `compute` must mark exactly what `los`
                    // accepts, and nothing outside the radius.
                    if (fov.VIS[key] == 1
                        && (!fov.los(sx, sy, x, y) || outside)) {
                        batch_fail = batch_fail + 1;
                    };
                    // SYMMETRY: what the player can see can see the player.
                    if (fov.VIS[key] == 1 && !fov.los(x, y, sx, sy)) {
                        asym = asym + 1;
                    };
                    // NEIGHBOURS: you can see the tiles you stand in.  Checked on
                    // the eye's own neighbourhood rather than per lit tile, which
                    // is the same assertion with a hundred times less work.
                    if (x == sx && y == sy) {
                        let by = 0 - 1;
                        while (by <= 1) {
                            let bx = 0 - 1;
                            while (bx <= 1) {
                                let nx = sx + bx;
                                let ny = sy + by;
                                if ((bx != 0 || by != 0) && dungeon.in_map(nx, ny)
                                    && !dungeon.blocks(nx, ny)
                                    && fov.VIS[ny * dungeon.W + nx] != 1) {
                                    nb_fail = nb_fail + 1;
                                };
                                bx = bx + 1;
                            };
                            by = by + 1;
                        };
                    };
                    x = x + 1;
                };
                y = y + 1;
            };
            // REPORTED: the second implementation, and how far apart the two are.
            let mine = fov.LIT;
            fov.ray(sx, sy, game.RADIUS, 2048, 4);
            let theirs = fov.LIT;
            ray_los_only = ray_los_only + (mine - theirs);
            let y2 = 0;
            while (y2 < dungeon.H) {
                let x2 = 0;
                while (x2 < dungeon.W) {
                    let key2 = y2 * dungeon.W + x2;
                    if (fov.VIS[key2] == 1 && !fov.los(sx, sy, x2, y2)) {
                        ray_only = ray_only + 1;
                    };
                    x2 = x2 + 1;
                };
                y2 = y2 + 1;
            };
            // WALK: the integration test.  The scripted walk is the same code the
            // deterministic run uses, so this is the headless path under load.
            if (game.setup(w, h, base_seed + k * 7919, 3) == 0) {
                walk_fail = walk_fail + 1;
            } else {
                let t = 0;
                while (t < 60) {
                    one_scripted_turn();
                    t = t + 1;
                    if (!dungeon.in_map(game.PX, game.PY) || dungeon.blocks(game.PX, game.PY)) {
                        walk_fail = walk_fail + 1;
                    };
                    if (game.P_HP < 0 || game.P_HP > game.P_MAXHP) {
                        walk_fail = walk_fail + 1;
                    };
                    if (game.STATUS == game.S_FAILED) { walk_fail = walk_fail + 1; };
                };
                turns_done = turns_done + game.TURNS;
                kills = kills + game.KILLS;
                if (game.DEPTH > deepest) { deepest = game.DEPTH; };
            };
        };
        k = k + 1;
    };
    textout.out_flush();
    textout.out_str("roguelike --check ");
    textout.out_num(n);
    textout.out_str(" from seed ");
    textout.out_num(base_seed);
    textout.out_str("\n");
    textout.out_str("ASSERTED\n");
    textout.out_str("  reach failures      ");
    textout.out_num(reach_fail);
    textout.out_str("\n  symmetry breaks     ");
    textout.out_num(asym);
    textout.out_str("\n  neighbour misses    ");
    textout.out_num(nb_fail);
    textout.out_str("\n  batch/los disagree  ");
    textout.out_num(batch_fail);
    textout.out_str("\n  walk failures       ");
    textout.out_num(walk_fail);
    textout.out_str("\nREPORTED\n");
    textout.out_str("  rooms per level     ");
    textout.out_num(rooms_lo);
    textout.out_str(" .. ");
    textout.out_num(rooms_hi);
    textout.out_str("  mean ");
    textout.out_num(rooms_sum / n);
    textout.out_str("\n  floor coverage      ");
    textout.out_num(cov_lo);
    textout.out_str(" .. ");
    textout.out_num(cov_hi);
    textout.out_str(" %  mean ");
    textout.out_num(cov_sum / n);
    textout.out_str("\n  tiles lit (mean)    ");
    textout.out_num(lit_sum / n);
    textout.out_str("\n  ray misses of los   ");
    textout.out_num(ray_los_only);
    textout.out_str("\n  ray-only, corner    ");
    textout.out_num(ray_only);
    textout.out_str("\n  scripted turns      ");
    textout.out_num(turns_done);
    textout.out_str("\n  kills               ");
    textout.out_num(kills);
    textout.out_str("\n  deepest level       ");
    textout.out_num(deepest);
    textout.out_str("\n");
    let ok = reach_fail == 0 && asym == 0 && nb_fail == 0 && batch_fail == 0
             && walk_fail == 0;
    textout.out_str(ok ? "check OK\n" : "check FAILED\n");
    textout.out_flush();
    if (ok) { 0 } else { 1 }
};

// ═══════════════════════════════════════════════════════════════ the driver ═══

args.init("roguelike",
          "rooms, corridors, a shadowed field of view, and a turn loop.",
          OPTS);
let st = args.parse(argv());
if (st == args.HELP) {
    puts(args.usage());
    puts("\nthe dungeon:\n");
    puts("  rooms and corridors on a seeded LCG; a symmetric-permissive field of\n");
    puts("  view; a turn loop with bumping, doors, monsters, hit points, a pack of\n");
    puts("  eight slots and stairs that descend.  Reach the bottom and you escape\n");
    puts("  with the amulet of Y.  Gold is picked up with ',' or 'g'.\n");
    puts("\nmeasurement:\n");
    puts("  --check N        validate the generator and the field of view over N\n");
    puts("                   levels and exit: reachability, symmetry, neighbours,\n");
    puts("                   batch/predicate agreement, and N turns of a scripted walk\n");
    puts("                   per level.  Every assertion is 0 or it exits 1.\n");
    puts("  --invuln         monsters cannot hurt you, so --frames 10000 measures ten\n");
    puts("                   thousand real turns instead of stopping at the first death\n");
    puts("  --quiet          no per-turn digest lines\n");
    puts("\nkeys, interactive:\n");
    puts("  arrows or hjkl, and yubn for the four diagonals (capitals too)\n");
    puts("  . wait    , or g pick up    1-8 use a pack slot    ? help    q quit\n");
    puts("\nthe deterministic run is scripted, not random:\n");
    puts("  ./roguelike --frames 5 --no-tty --seed 1\n");
    puts("  walks the string --walk (default \"" + DEF_WALK + "\") and prints the\n");
    puts("  dungeon as text.  Same seed and same flags, same bytes.\n");
    exit(0)
};
if (st == args.USAGE) {
    eputs("roguelike: try --help\n");
    exit(1)
};

if (len(args.positional()) > 0) {
    die("takes no operands; got '" + args.positional()[0] + "'")
};

build_keys();

let SEED = args.get_long("seed", 1);
let FRAMES = args.get_long("frames", 0);
let DEPTH_WANT = args.get_long("depth", DEF_DEPTH);
let CHECK_N = args.get_long("check", 0);
let NOTTY = if (args.has("no-tty")) { 1 } else { 0 };
let QUIET = if (args.has("quiet")) { 1 } else { 0 };
let SHOWTIME = if (args.has("time")) { 1 } else { 0 };

if (SEED < 0) {
    die("--seed wants a non-negative integer, got " + tostring(SEED))
};
if (SEED > 999999999999) {
    die("--seed wants at most 999999999999, got " + tostring(SEED))
};
if (FRAMES < 0) {
    die("--frames wants a non-negative integer, got " + tostring(FRAMES))
};
if (FRAMES > 100000000) {
    die("--frames wants at most 100000000, got " + tostring(FRAMES))
};
if (DEPTH_WANT < 1) {
    die("--depth wants at least 1 level, got " + tostring(DEPTH_WANT))
};
if (DEPTH_WANT > 40) {
    die("--depth wants at most 40 levels, got " + tostring(DEPTH_WANT))
};
if (CHECK_N < 0) {
    die("--check wants a non-negative integer, got " + tostring(CHECK_N))
};
if (CHECK_N > 100000) {
    die("--check wants at most 100000 levels, got " + tostring(CHECK_N))
};

let HAVE_WALK = args.has("walk");
if (HAVE_WALK) {
    WALK = args.get_str("walk", DEF_WALK);
    check_walk(WALK);
    if (len(WALK) == 0) {
        die("--walk was given but empty; use \".\" for a single waiting turn")
    };
};

let MAPW = DEF_W;
let MAPH = DEF_H;
if (args.has("size")) {
    let sz = parse_size(args.get_str("size", ""));
    if (sz == 0) {
        die("--size wants WxH with " + tostring(dungeon.MIN_W) + " <= W <= "
            + tostring(dungeon.MAX_W) + " and " + tostring(dungeon.MIN_H)
            + " <= H <= " + tostring(dungeon.MAX_H) + ", got '"
            + args.get_str("size", "") + "'")
    };
    MAPW = sz / 1000000;
    MAPH = sz % 1000000;
};

// ═══════════════════════════════════════════════════════ the validator path ═══

if (CHECK_N > 0) {
    exit(check_run(CHECK_N, SEED))
};

if (args.has("invuln")) { game.INVULN = 1; };

// ══════════════════════════════════════════════════════ the headless path ═══

if (NOTTY != 0) {
    // The framebuffer is never used here, but its output descriptor is sent to
    // /dev/null anyway so that nothing can accidentally write ANSI into the
    // bytes EXPECTED holds.
    let devnull = syscall(257, 0 - 100, "/dev/null", 1, 0, 0, 0);   // openat
    if (devnull >= 0) { fb.set_fd(devnull); };
    view.build_legend();

    if (game.setup(MAPW, MAPH, SEED, DEPTH_WANT) == 0) {
        textout.out_str("roguelike: the generator could not make a dungeon "
            + "at seed ");
        textout.out_num(SEED);
        textout.out_str(" and size ");
        textout.out_num(MAPW);
        textout.out_str("x");
        textout.out_num(MAPH);
        textout.out_str("\n");
        textout.out_flush();
        eputs("roguelike: no dungeon for that seed and size\n");
        exit(1)
    };

    textout.out_str("roguelike: seed ");
    textout.out_num(SEED);
    textout.out_str("  size ");
    textout.out_num(MAPW);
    textout.out_str("x");
    textout.out_num(MAPH);
    textout.out_str("  depth ");
    textout.out_num(DEPTH_WANT);
    textout.out_str("  radius ");
    textout.out_num(game.RADIUS);
    textout.out_str("  walk \"");
    textout.out_str(WALK);
    textout.out_str("\"\n");
    textout.out_str("glyphs ");
    textout.out_str(view.legend());
    textout.out_str("  # lit wall  : wall remembered  . lit floor  "
        + ", floor remembered  + door  > stairs  @ you\n");
    level_line();

    let h0 = heap_used();
    let t0 = time.now_us();
    let f = 0;
    let spent_sum = 0;
    while (f < FRAMES) {
        let spent = one_scripted_turn();
        spent_sum = spent_sum + spent;
        if (QUIET == 0) { digest(f + 1, spent); };
        f = f + 1;
    };
    let t1 = time.now_us();
    let h1 = heap_used();

    level_line();
    view.dump_map("the level as it stands:");
    pack_line();
    textout.out_str("last: ");
    let i = 0;
    while (i < game.MSG_SLOTS) {
        if (game.MSG[i] != game.MSG_NONE) {
            textout.out_str(game.message_line(i));
            textout.out_str(" | ");
        };
        i = i + 1;
    };
    textout.out_str("\n");
    summary(spent_sum, h1 - h0);
    textout.out_flush();

    if (SHOWTIME != 0) {
        let el = t1 - t0;
        let us = if (FRAMES > 0) { el / FRAMES } else { 0 };
        eputs("roguelike: ");
        eputs(tostring(FRAMES));
        eputs(" turns in ");
        eputs(tostring(el));
        eputs(" us = ");
        eputs(tostring(us));
        eputs(" us/turn, heap_used ");
        eputs(tostring(h0));
        eputs(" -> ");
        eputs(tostring(h1));
        eputs(" delta ");
        eputs(tostring(h1 - h0));
        eputs("\n");
    };
    exit(0)
};

// ═════════════════════════════════════════════════════ the interactive path ═══
//
// term.y's pattern verbatim: raw mode, alt screen, watchdog, and ONE place that
// leaves.  Y has no atexit and no signal handler, so every exit below is a call
// to term.restore_all_exit() -- there is no path out of this loop that does not
// go through it.
if (!term.raw_mode()) {
    eputs("roguelike: not a terminal; try --frames N --no-tty\n");
    exit(1)
};
term.enter_screen();
term.arm_watchdog();

let ws = term.size();
trows = ws.rows;
tcols = ws.cols;
let rows = trows;
let cols = tcols;
if (rows < 10) { rows = 10; };
if (cols < 40) { cols = 40; };
if (rows > fb.MAX_ROWS) { rows = fb.MAX_ROWS; };
if (cols > fb.MAX_COLS) { cols = fb.MAX_COLS; };
let srf = fb.new(rows, cols);

if (game.setup(MAPW, MAPH, SEED, DEPTH_WANT) == 0) {
    eputs("roguelike: the generator could not make a dungeon at that seed and size\n");
    term.restore_all_exit(1)
};

view.invalidate();
let ibytes = play(srf, FRAMES);
term.restore_all_exit(0);
