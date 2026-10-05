// tlang.y -- the turtle language: source text in, a stream of opcodes out, and
// a turtle that walks them.
//
// This module is the whole language and it deliberately knows NOTHING about
// frames, terminals or pixels: it imports fx (for sin/cos) and nothing else.
// Drawing is somebody else's job.  `run_one()` executes exactly one command and
// leaves the result in module-level globals -- EV with SX..EY for a segment, EV
// with EX/EY for a dot -- so the caller draws it.  That split is not tidiness:
// it is what lets check.y walk a whole program's path and assert every vertex
// against a hand-computed table without ever touching a framebuffer, and what
// lets the dry pass (which computes the bounding box the view is fitted to)
// reuse the identical executor.
//
// ── the numbers, and why they are integers ────────────────────────────────
//
// The turtle's position is in integer units and its heading is in MILLI-degrees
// (thousandths of a degree, so a full turn is 360000).  Both choices are load
// bearing:
//
//   * integer position: a step of n units at heading h advances by
//     (round(n*cos h), round(n*sin h)).  The rounding to whole units is what
//     makes polygon closure EXACT -- a 5-gon of 100-unit sides closes to (0,0)
//     and not to (0.4, -0.2) -- and check.y asserts that vertex by vertex.
//   * integer milli-degrees: the wrap is h - 360000*(h/360000) with a sign
//     fix-up, which is exact integer arithmetic, so `left 90` four times
//     returns the heading BIT FOR BIT, and no amount of drawing can change it.
//
// There is no float -> long in the language and no math functions at all
// (ORCHESTRATOR.md 2.4), so the trig is fx.sin/fx.cos in Q30.  The trap that
// costs the most here: fx.mul DIVIDES by 2^30, it does not scale up, so
// `fx.mul(h, 18740)` with h a count of milli-degrees is a ratio near zero and
// the turtle spins on the spot making tiny scribbles -- a picture that still
// looks plausible.  The heading has to be lifted into Q30 with fx.from_int
// first; rad() below is the only place that happens.

import fx;

// ───────────────────────────────────────────────────────────── limits ───
//
// Every one of these is a MESSAGE, never a trap: a program that trips one gets
// a diagnostic on stderr and a non-zero exit.  A malformed script must not be
// able to crash the interpreter, and runtime traps print to STDOUT, which would
// corrupt EXPECTED instead of announcing itself (ORCHESTRATOR.md §2.6).
const MAXTOK: long = 1024;           // tokens per program
const TOKW: long = 15;              // longest word, bytes
const MAXCMDS: long = 512;           // opcodes per program
const MAXDEPTH: long = 12;           // repeat nesting
const MAXUNIT: long = 100000;        // |distance| in a move command
const MAXDEG: long = 3600000;        // |degrees| in a turn command
const MAXNUM: long = 1000000000000;  // a literal past this is refused as absurd
const MAXTR: long = 300;             // segments the trace can hold

// ─────────────────────────────────────────────────────────── opcodes ───

const OP_FWD: long = 1;
const OP_BACK: long = 2;
const OP_LEFT: long = 3;
const OP_RIGHT: long = 4;
const OP_HEAD: long = 5;
const OP_PEN: long = 6;
const OP_COLOUR: long = 7;
const OP_JUMP: long = 8;
const OP_DOT: long = 9;
const OP_REPEAT: long = 10;
const OP_END: long = 11;

let OPNAME: [str] = ["?", "forward", "back", "left", "right", "heading",
                     "pen", "colour", "jump", "dot", "repeat", "end"];

// The colours, by name and by packed RGB (r<<16 | g<<8 | b, the packing tui.rgb
// uses).  The interpreter keeps them as plain longs so it stays independent of
// tui; scene.y hands the number to fb.
let CNAME: [str] = ["black", "red", "green", "yellow", "blue", "magenta",
                    "cyan", "white", "orange", "grey", "brown", "lime",
                    "pink", "violet", "silver", "gold"];
const NCOLOUR: long = 16;
let CRGB: [long] = [0, 13378082, 2271795, 13412898, 2245836, 11154346, 2271914,
                    14540253, 16746530, 8947848, 8934707, 10083652, 16751035,
                    8939263, 12303291, 16766720];

// ────────────────────────────────────────────── the compiled program ───
//
// Three fixed arrays rather than a list of records.  There is no `push` and no
// array-of-records literal to grow, the opcode stream is a hot path (one command
// per frame in the interactive view) and a record per command would allocate
// 40 bytes a step on an arena heap.  This is the shape the whole language wants:
// `+=` and `*=` are the array interface and nothing else needs to exist.

let CMD_OP: [long; 512] = [0; 512];
let CMD_A: [long; 512] = [0; 512];
let CMD_B: [long; 512] = [0; 512];
let NC: long = 0;                        // opcodes in the program

// The repeat stack: for each open block, where its body starts and how many
// passes are left.  Fixed size, module level, never grown.
let LP: [long; 12] = [0; 12];
let LC: [long; 12] = [0; 12];
// RP -- at COMPILE time, the opcode index of the `repeat` each still-open block
// belongs to, so the ']' that closes it can patch that opcode's skip target.
// Without it, `repeat 0 [ ... ]` would have nowhere to jump to and the block
// would run once, which is a defect a golden of any seeded program with a
// repeat 0 would show as a stray mark in the corner.
let RP: [long; 12] = [0; 12];
// RPLINE -- the source line of each open block, so an unclosed `repeat` can say
// WHERE it was opened instead of just that something was.
let RPLINE: [long; 12] = [0; 12];
let DEPTH: long = 0;

// ──────────────────────────────────────────────────────────── tokens ───
//
// Text goes into one module-level byte store rather than into `str` slices, so
// COMPILING a program allocates nothing either: s[i:j] builds a str, which on
// an arena heap is 64 bytes a token, so parsing a 512-command program would be
// 32 KiB.  A token is (offset, length) into the store, or a NUMBER, which is
// length 0 with a value.  A regex module exists and would tokenise this in one
// call, but it allocates a match record per call and this program is built to
// allocate nothing at all.
let TS: [byte; 15360] = [0; 15360];        // MAXTOK * TOKW
let TAT: [long; 1024] = [0; 1024];
let TLEN: [long; 1024] = [0; 1024];
let TVAL: [long; 1024] = [0; 1024];
let TLINE: [long; 1024] = [0; 1024];
let TN: long = 0;
let TSUSED: long = 0;

// ─────────────────────────────────────────────────── diagnostics ───
//
// There is no exception mechanism, so a failure is a message and a status: the
// compiler returns -1, the driver prints ERRTXT with ERRLINE and exits 1.
let ERRTXT: str = "";
let ERRLINE: long = 0;

def err(t: str, line: long) -> long {
    ERRTXT = t;
    ERRLINE = line;
    0 - 1
};

// ───────────────────────────────────────────────── the turtle itself ───

let X: long = 0;                 // position, integer units, y UP
let Y: long = 0;
let H: long = 0;                 // heading in milli-degrees, in [0, 360000)
let PEN: long = 1;               // 1 = down
let COL: long = 1;               // colour index
let PC: long = 0;                // program counter: an index into CMD_*
let DONE: long = 0;              // 0 running, 1 finished, 2 stopped on an error

// what run_one() did, for the caller to draw
let EV: long = 0;                // 0 nothing, 1 segment, 2 dot, 3 end, 4 error
let SX: long = 0; let SY: long = 0;
let EX: long = 0; let EY: long = 0;

let STEPS: long = 0;             // commands executed so far
let MOVED: long = 0;             // total distance commanded, for the header
let BX0: long = 0; let BX1: long = 0;   // the bounding box of everything the
let BY0: long = 0; let BY1: long = 0;   // program has touched, for the view fit

// ── the trace: an optional log of every drawn segment ─────────────────────
//
// check.y turns it on, runs a program, and then asserts the vertex table the
// interpreter recorded.  The expected table is hand-computed and pasted in as
// literals, so this is the code under test measured from outside -- not the
// check recomputing what the code does.  Fixed size, module level, zero
// allocation; a program that would overrun it has the tail dropped, and
// check.y asserts TRN against a literal too, so an overrun cannot pass quietly.
let TRON: long = 0;
let TRN: long = 0;
let TRX0: [long; 300] = [0; 300];
let TRY0: [long; 300] = [0; 300];
let TRX1: [long; 300] = [0; 300];
let TRY1: [long; 300] = [0; 300];

def trace_on() -> void { TRON = 1; TRN = 0 };
def trace_off() -> void { TRON = 0 };
def trace_n() -> long { TRN };

def trace_seg(x0: long, y0: long, x1: long, y1: long) -> void {
    if (TRON == 0) { return };
    if (TRN >= MAXTR) { return };
    TRX0[TRN] = x0; TRY0[TRN] = y0; TRX1[TRN] = x1; TRY1[TRN] = y1;
    TRN = TRN + 1
};

// ─────────────────────────────────────────────── angles and stepping ───

// radians per milli-degree, as a Q30 NUMBER.  1.74533e-5 rad.  It is a plain
// Q30 value, not a count, which is why rad() lifts the heading with fx.from_int
// before calling fx.mul.
const RAD_PER_MDEG: long = 18740;

def rad(mdeg: long) -> long { fx.mul(fx.from_int(mdeg), RAD_PER_MDEG) };

// cosd(h), sind(h) -- the heading's direction in Q30, for h in [0, 360000).
// fx.cos takes radians, not degrees.
def cosd(h: long) -> long { fx.cos(rad(h)) };
def sind(h: long) -> long { fx.sin(rad(h)) };

// wrap_deg(h) -- fold ANY heading into [0, 360000), exactly.
//
// Division truncates toward zero in this language (measured: -7/2 = -3), so
// h - k*360000 keeps the sign of h and the fix-up is what makes the negative
// half work.  The expression is integer arithmetic on an integer constant, so
// there is no cancellation error and no drift whatsoever: `left 90` four times
// is +360000, k = 1, r = 0, and the heading is back where it started bit for
// bit.  A heading that goes NEGATIVE (right 90 from 0 lands on 270000) is the
// case an off-by-one hides in -- a golden file cannot see it, because the
// picture still comes out right -- and check.case_wrap() asserts it directly.
def wrap_deg(h: long) -> long {
    let k = h / 360000;
    let r = h - k * 360000;
    if (r < 0) { r = r + 360000 };
    r
};

// stepx(n, h), stepy(n, h) -- the displacement of a step of n units at heading
// h, in whole units, rounded HALF AWAY FROM ZERO (fx.round's rule, which is
// odd-symmetric).  The product n*cos is n times a Q30 value, so at most 2^47
// for the |n| <= 100000 this language allows: nowhere near a long's 2^62, and
// so nothing here can overflow silently.  fx.round gives a whole Q30 and
// fx.to_int is the sanctioned whole-number bridge (the language has no
// float -> long at all).
def stepx(n: long, h: long) -> long { fx.to_int(fx.round(n * cosd(h))) };
def stepy(n: long, h: long) -> long { fx.to_int(fx.round(n * sind(h))) };

// ───────────────────────────────────────────────────────── tokenise ───

def is_space(b: long) -> bool { b == 32 || b == 9 || b == 13 || b == 11 || b == 12 };

def is_digit(b: long) -> bool { b >= 48 && b <= 57 };

// tok_push(at, l, val, line) -- record one token.  -1 if the token table is full.
def tok_push(at: long, l: long, val: long, line: long) -> long {
    if (TN >= MAXTOK) { return err("too many tokens (max 1024)", line) };
    TAT[TN] = at;
    TLEN[TN] = l;
    TVAL[TN] = val;
    TLINE[TN] = line;
    TN = TN + 1;
    1
};

// tokenise(src) -- split into words, numbers and three punctuation marks.  '#'
// and ';' run to the end of the line, '[' and ']' are tokens, and anything else
// non-blank is a word.  A word longer than TOKW-1 is refused rather than
// silently truncated, because a truncated keyword compiles to a different
// command and the diagnostic would then be a lie.
def tokenise(src: str) -> long {
    TN = 0;
    TSUSED = 0;
    let n = len(src);
    let i = 0;
    let line = 1;
    while (i < n) {
        let b = byte_at(src, i);
        if (b == 10) {
            line = line + 1;
            i = i + 1
        } else if (is_space(b)) {
            i = i + 1
        } else if (b == 35) {
            while (i < n && byte_at(src, i) != 10) { i = i + 1 }
        } else if (b == 91 || b == 93 || b == 59) {
            if (tok_push(TSUSED, 1, b, line) < 0) { return 0 - 1 };
            TS[TSUSED] = b;
            TSUSED = TSUSED + 1;
            i = i + 1
        } else if (is_digit(b) ||
                   (b == 45 && i + 1 < n && is_digit(byte_at(src, i + 1)))) {
            let neg = false;
            if (b == 45) { neg = true; i = i + 1 };
            let v = 0;
            while (i < n && is_digit(byte_at(src, i))) {
                v = v * 10 + byte_at(src, i) - 48;
                if (v > MAXNUM) { return err("number too large", line) };
                i = i + 1
            };
            if (tok_push(0, 0, if (neg) { 0 - v } else { v }, line) < 0) {
                return 0 - 1
            }
        } else {
            let start = i;
            while (i < n && is_space(byte_at(src, i)) == false &&
                   byte_at(src, i) != 10 && byte_at(src, i) != 35 &&
                   byte_at(src, i) != 91 && byte_at(src, i) != 93 &&
                   byte_at(src, i) != 59) { i = i + 1 };
            let l = i - start;
            if (l >= TOKW) { return err("word too long (max 14 characters)", line) };
            if (TSUSED + l + 1 > MAXTOK * TOKW) { return err("program text too long", line) };
            let k = 0;
            while (k < l) { TS[TSUSED + k] = byte_at(src, start + k); k = k + 1 };
            if (tok_push(TSUSED, l, 0, line) < 0) { return 0 - 1 };
            TSUSED = TSUSED + l + 1
        }
    };
    1
};

// tok_is(i, w) -- is token i the word w?  A byte compare against the literal: no
// allocation, and no str comparison of a slice.
def tok_is(i: long, w: str) -> bool {
    if (i < 0 || i >= TN) { return false };
    let n = len(w);
    if (TLEN[i] != n) { return false };
    let k = 0;
    while (k < n) {
        if (TS[TAT[i] + k] != byte_at(w, k)) { return false };
        k = k + 1
    };
    true
};

// tok_is_num(i) -- token i is a number.  TLEN 0 is only ever set by the number
// branch of tokenise(), so it is unambiguous.
def tok_is_num(i: long) -> bool { i >= 0 && i < TN && TLEN[i] == 0 };

// tok_word(i) -- the offending word as a str, for a diagnostic.  Only ever
// called on the error path, so the str it builds costs nothing that matters.
def tok_word(i: long) -> str {
    let out = "";
    let k = 0;
    while (k < TLEN[i]) {
        out += chr(TS[TAT[i] + k]);
        k = k + 1
    };
    out
};

// num_at(i) -- the value of the number token at i, or a diagnostic.  A word
// where a number belongs is the commonest way to be wrong, so it names the word.
def num_at(i: long) -> long {
    if (i >= TN) { return err("missing a number", if (i > 0) { TLINE[i - 1] } else { 1 }) };
    if (tok_is_num(i) == false) {
        return err("expected a number, got '" + tok_word(i) + "'", TLINE[i])
    };
    TVAL[i]
};

// ─────────────────────────────────────────────────────────── compile ───

// CURLINE -- the line of the command being compiled, so a limit tripped inside
// emit() can name where the program got too long instead of saying "line 0".
let CURLINE: long = 0;

def emit(op: long, a: long, b: long) -> long {
    if (NC >= MAXCMDS) { return err("too many commands (max 512)", CURLINE) };
    CMD_OP[NC] = op;
    CMD_A[NC] = a;
    CMD_B[NC] = b;
    NC = NC + 1;
    1
};

// colour_of(name) -- the index of a colour name, or -1.
def colour_of(name: str) -> long {
    let i = 0;
    while (i < NCOLOUR) {
        if (CNAME[i] == name) { return i };
        i = i + 1
    };
    0 - 1
};

// compile(src) -- source text to opcodes.  Returns the opcode count, or -1 with
// ERRTXT and ERRLINE set.  Everything it refuses it refuses with a line number:
// "line 7: unknown command 'froward'" is the difference between a usable
// interpreter and a puzzle.
//
// The argument checks are uniform on purpose -- bound first, then token kind,
// then range -- so no path can read TLINE or TVAL past the token table.
def compile(src: str) -> long {
    ERRTXT = "";
    ERRLINE = 0;
    NC = 0;
    DEPTH = 0;
    if (tokenise(src) < 0) { return 0 - 1 };
    let i = 0;
    let n = 0;
    while (i < TN) {
        CURLINE = TLINE[i];
        if (tok_is(i, ";")) { i = i + 1 } else
        if (tok_is(i, "]")) {
            if (DEPTH == 0) { return err("']' with no open repeat", TLINE[i]) };
            DEPTH = DEPTH - 1;
            if (emit(OP_END, 0, 0) < 0) { return 0 - 1 };
            // NC - 1 is the index emit() just used.  Taking emit()'s RETURN value
            // here instead (it returns 1 on success) made every repeat 0 jump to
            // opcode 1, so `repeat 0 [ forward 1 ]` ran the block's END.
            CMD_B[RP[DEPTH]] = NC - 1;
            i = i + 1
        } else
        if (tok_is(i, "[")) { return err("'[' with no repeat", TLINE[i]) } else
        if (tok_is(i, "forward") || tok_is(i, "fd") || tok_is(i, "f") ||
            tok_is(i, "back") || tok_is(i, "backward") || tok_is(i, "bk") ||
            tok_is(i, "b")) {
            let fwd = tok_is(i, "forward") || tok_is(i, "fd") || tok_is(i, "f");
            if (i + 1 >= TN) { return err("missing a distance", TLINE[i]) };
            n = num_at(i + 1);
            if (n == 0 - 1 && tok_is_num(i + 1) == false) { return 0 - 1 };
            if (n > MAXUNIT || n < 0 - MAXUNIT) {
                return err("a step wants -100000..100000 units", TLINE[i + 1])
            };
            if (emit(if (fwd) { OP_FWD } else { OP_BACK }, n, 0) < 0) { return 0 - 1 };
            i = i + 2
        } else
        if (tok_is(i, "left") || tok_is(i, "lt") || tok_is(i, "l") ||
            tok_is(i, "right") || tok_is(i, "rt") || tok_is(i, "r") ||
            tok_is(i, "setheading") || tok_is(i, "heading")) {
            let lft = tok_is(i, "left") || tok_is(i, "lt") || tok_is(i, "l");
            let abs = tok_is(i, "setheading") || tok_is(i, "heading");
            if (i + 1 >= TN) { return err("missing degrees", TLINE[i]) };
            n = num_at(i + 1);
            if (n == 0 - 1 && tok_is_num(i + 1) == false) { return 0 - 1 };
            if (n > MAXDEG || n < 0 - MAXDEG) {
                return err("a turn wants -3600000..3600000 degrees", TLINE[i + 1])
            };
            if (abs) {
                if (emit(OP_HEAD, n * 1000, 0) < 0) { return 0 - 1 }
            } else {
                if (emit(if (lft) { OP_LEFT } else { OP_RIGHT },
                         if (lft) { n * 1000 } else { 0 - n * 1000 }, 0) < 0) {
                    return 0 - 1
                }
            };
            i = i + 2
        } else
        if (tok_is(i, "pen")) {
            if (i + 1 >= TN) { return err("pen wants 'up' or 'down'", TLINE[i]) };
            if (tok_is(i + 1, "up")) {
                if (emit(OP_PEN, 0, 0) < 0) { return 0 - 1 };
                i = i + 2
            } else if (tok_is(i + 1, "down")) {
                if (emit(OP_PEN, 1, 0) < 0) { return 0 - 1 };
                i = i + 2
            } else {
                return err("pen wants 'up' or 'down', got '" + tok_word(i + 1) + "'",
                            TLINE[i + 1])
            }
        } else
        if (tok_is(i, "colour") || tok_is(i, "color")) {
            if (i + 1 >= TN) { return err("colour wants a name", TLINE[i]) };
            if (tok_is_num(i + 1)) {
                return err("colour wants a name, not a number", TLINE[i + 1])
            };
            n = colour_of(tok_word(i + 1));
            if (n < 0) { return err("no colour named '" + tok_word(i + 1) + "'", TLINE[i + 1]) };
            if (emit(OP_COLOUR, n, 0) < 0) { return 0 - 1 };
            i = i + 2
        } else
        if (tok_is(i, "dot")) {
            if (emit(OP_DOT, 0, 0) < 0) { return 0 - 1 };
            i = i + 1
        } else
        if (tok_is(i, "jump")) {
            if (i + 2 >= TN) { return err("jump wants two numbers", TLINE[i]) };
            n = num_at(i + 1);
            if (n == 0 - 1 && tok_is_num(i + 1) == false) { return 0 - 1 };
            if (n > MAXUNIT || n < 0 - MAXUNIT) {
                return err("a coordinate wants -100000..100000 units", TLINE[i + 1])
            };
            if (TVAL[i + 2] > MAXUNIT || TVAL[i + 2] < 0 - MAXUNIT) {
                return err("a coordinate wants -100000..100000 units", TLINE[i + 2])
            };
            if (emit(OP_JUMP, n, TVAL[i + 2]) < 0) { return 0 - 1 };
            i = i + 3
        } else
        if (tok_is(i, "repeat")) {
            if (i + 1 >= TN) { return err("missing a count after 'repeat'", TLINE[i]) };
            n = num_at(i + 1);
            if (n == 0 - 1 && tok_is_num(i + 1) == false) { return 0 - 1 };
            if (n < 0 || n > MAXUNIT) { return err("repeat wants 0..100000", TLINE[i + 1]) };
            if (i + 2 >= TN || tok_is(i + 2, "[") == false) {
                return err("repeat wants a count then '['",
                           if (i + 2 < TN) { TLINE[i + 2] } else { TLINE[i + 1] })
            };
            if (DEPTH >= MAXDEPTH) { return err("repeat nested more than 12 deep", TLINE[i]) };
            RP[DEPTH] = NC;
            RPLINE[DEPTH] = TLINE[i];
            if (emit(OP_REPEAT, n, 0) < 0) { return 0 - 1 };
            DEPTH = DEPTH + 1;
            i = i + 3
        } else {
            if (tok_is_num(i)) { return err("a number with no command", TLINE[i]) };
            return err("unknown command '" + tok_word(i) + "'", TLINE[i])
        }
    };
    if (DEPTH != 0) {
        return err("this repeat block is never closed", RPLINE[DEPTH - 1])
    };
    NC
};

// ─────────────────────────────────────────────────────────── execute ───

// reset() -- the turtle back to the start of the program: origin, pen down,
// heading 0, red.
def reset() -> void {
    X = 0; Y = 0; H = 0;
    PEN = 1;
    COL = 1;
    PC = 0;
    DEPTH = 0;
    DONE = 0;
    EV = 0;
    STEPS = 0;
    MOVED = 0;
    BX0 = 0; BX1 = 0; BY0 = 0; BY1 = 0
};

// track(x, y) -- grow the bounding box.  The view is fitted to it, so it must
// include the starting point and every point a `jump` teleports past.
def track(x: long, y: long) -> void {
    if (x < BX0) { BX0 = x };
    if (x > BX1) { BX1 = x };
    if (y < BY0) { BY0 = y };
    if (y > BY1) { BY1 = y }
};

// run_one() -- execute ONE command and leave the result in EV:
//
//   0  nothing to draw
//   1  a segment, SX, SY to EX, EY, pen down
//   2  a dot at EX, EY
//   3  the program ended
//   4  stopped on an error (ERRTXT set)
//
// `jump dx dy` moves RELATIVE and draws NOTHING whatever the pen is doing: it
// is a stride, and the way to draw a line to somewhere else is pen up / jump /
// pen down around it.  Relative because that composes with forward and back,
// which are relative too, so a lattice can be laid out in the program itself
// instead of needing a variable to remember where the last row ended.
//
// There is no `break` and no `continue` in this language -- both are undefined
// names (ORCHESTRATOR.md §2.10) -- so the early exits are a guard with an explicit terminal
// assignment, and the loop body is wrapped in a positive condition.
def run_one() -> long {
    EV = 0;
    if (DONE != 0) { return if (DONE == 1) { 3 } else { 4 } };
    if (PC >= NC) { DONE = 1; return 3 };
    let op = CMD_OP[PC];
    let a = CMD_A[PC];
    if (op == OP_FWD || op == OP_BACK) {
        let n = if (op == OP_BACK) { 0 - a } else { a };
        SX = X; SY = Y;
        EX = X + stepx(n, H);
        EY = Y + stepy(n, H);
        X = EX; Y = EY;
        MOVED = MOVED + (if (n < 0) { 0 - n } else { n });
        track(X, Y);
        if (PEN != 0) { EV = 1; trace_seg(SX, SY, EX, EY) };
        PC = PC + 1
    } else if (op == OP_LEFT || op == OP_RIGHT) {
        H = wrap_deg(H + a);
        PC = PC + 1
    } else if (op == OP_HEAD) {
        H = wrap_deg(a);
        PC = PC + 1
    } else if (op == OP_PEN) {
        PEN = a;
        PC = PC + 1
    } else if (op == OP_COLOUR) {
        COL = a;
        PC = PC + 1
    } else if (op == OP_JUMP) {
        X = X + a; Y = Y + CMD_B[PC];      // RELATIVE: a move that draws nothing
        track(X, Y);
        PC = PC + 1
    } else if (op == OP_DOT) {
        EX = X; EY = Y;
        if (PEN != 0) { EV = 2 };
        PC = PC + 1
    } else if (op == OP_REPEAT) {
        if (a <= 0) {
            PC = CMD_B[PC] + 1            // repeat 0: the whole block is skipped
        } else if (DEPTH >= MAXDEPTH) {
            ERRTXT = "INTERNAL: the repeat stack over-pushed";
            ERRLINE = 0;
            DONE = 2;
            return 4
        } else {
            LP[DEPTH] = PC + 1;
            LC[DEPTH] = a;
            DEPTH = DEPTH + 1;
            PC = PC + 1
        }
    } else if (op == OP_END) {
        // The loop that owns this END is the TOP of the stack, which is at
        // DEPTH-1: OP_REPEAT pushes and THEN increments, so incrementing first
        // would read the slot above the loop's own.  And the pop happens only
        // when the loop is finished, never on every pass -- that is the whole
        // nesting rule, because while an outer loop still has passes left it
        // stays on the stack, so a nested repeat re-pushes at the depth below
        // it and cannot overwrite the outer's counter.  Popping every time made
        // `repeat 2 [ repeat 3 [ forward 1 ] ]` advance 5 units instead of 6.
        // The picture was still a closed shape and the frame table still
        // deterministic, so only an assertion about the interpreter's own step
        // count could see it.
        if (DEPTH > 0 && LC[DEPTH - 1] > 1) {
            LC[DEPTH - 1] = LC[DEPTH - 1] - 1;
            PC = LP[DEPTH - 1]
        } else {
            DEPTH = DEPTH - 1;
            if (DEPTH < 0) { DEPTH = 0 };
            PC = PC + 1
        }
    } else {
        ERRTXT = "INTERNAL: bad opcode";
        ERRLINE = 0;
        DONE = 2;
        return 4
    };
    STEPS = STEPS + 1;
    EV
};

// run_to_end() -- execute everything that is left and return the event of the
// last command.  The dry pass (which computes the bounding box the view is
// fitted to) uses it; the frame path never does.
def run_to_end() -> long {
    let ev = 0;
    let stop = false;
    while (stop == false) {
        ev = run_one();
        if (ev == 3 || ev == 4) { stop = true }
    };
    ev
};

// ─────────────────────────────────────────────────────── built-ins ───
//
// The programs that ship with the interpreter, as source text.  They are the
// documentation: every command in the language appears in one of them and
// `turtle --list` prints them.  They are handed to the same compile() a file
// is, so nothing here is privileged.  No arithmetic -- the language has no
// expressions -- so a program that wants four different lengths says so.
let PROGS: [str] = [
    // 0 square: the closure demonstration.  Four 100-unit sides, and it ends
    // where it started, facing exactly 0.
    "forward 100 right 90 forward 100 right 90 forward 100 right 90 forward 100 right 90",
    // 1 tri: a 3-gon of 100-unit sides.  It closes exactly too, and the README
    // has the arithmetic for why.
    "forward 100 right 120 forward 100 right 120 forward 100 right 120",
    // 2 pentagon: the odd one.  cos 72 is irrational, so this closes only
    // because the step is rounded to whole units.
    "forward 100 right 72 forward 100 right 72 forward 100 right 72 forward 100 right 72 forward 100 right 72",
    // 3 octagon: eight 100-unit sides, the fourth closure case the check runs.
    "forward 100 right 45 forward 100 right 45 forward 100 right 45 forward 100 right 45 forward 100 right 45 forward 100 right 45 forward 100 right 45 forward 100 right 45",
    // 4 spiral: an Archimedean square spiral, lengths 1 1 2 2 3 3 ... out to 8.
    // No arithmetic in the language, so the numbers are all written out.
    "forward 1 right 90 forward 1 right 90 forward 2 right 90 forward 2 right 90 forward 3 right 90 forward 3 right 90 forward 4 right 90 forward 4 right 90 forward 5 right 90 forward 5 right 90 forward 6 right 90 forward 6 right 90 forward 7 right 90 forward 7 right 90 forward 8 right 90 forward 8 right 90",
    // 5 koch: the snowflake.  Each side of the triangle becomes four, with a
    // bump in the middle; the second colour draws the same triangle subdivided
    // once more, which is the classic second iteration lying inside the first.
    "colour red\nrepeat 3 [ forward 20 right 60 forward 20 left 120 forward 20 right 60 forward 20 right 120 ]\ncolour orange\nrepeat 3 [ forward 5 right 60 forward 5 left 120 forward 5 right 60 forward 5 right 60 forward 5 left 120 forward 5 right 60 forward 5 right 120 ]",
    // 6 star: an eight-pointed star, then a pen-up stride across it (which
    // moves the turtle and is NOT drawn, so the fit accounts for where it went),
    // then a second figure in another colour.
    "colour green\nrepeat 8 [ forward 40 right 135 forward 40 right 135 ]\npen up\nforward 10\npen down\ncolour cyan\nrepeat 8 [ forward 20 right 90 forward 20 right 90 ]",
    // 7 lattice: a 5x5 grid of dots.  The only one that needs a repeat inside a
    // repeat, and the reason `jump` exists: with the pen DOWN, the stride
    // between two dots has to be something that moves without drawing, or every
    // row would come out as a line through its own dots.
    "colour violet\nrepeat 5 [ repeat 5 [ jump 8 0 dot ] jump -40 8 ]"
];

let PROGNAME: [str] = ["square", "tri", "pentagon", "octagon", "spiral",
                       "koch", "star", "lattice"];
const NPROG: long = 8;

export { MAXUNIT, MAXDEG, MAXCMDS, MAXTOK, TOKW, MAXDEPTH, MAXTR, NCOLOUR,
          OP_FWD, OP_BACK, OP_LEFT, OP_RIGHT, OP_HEAD, OP_PEN, OP_COLOUR,
          OP_JUMP, OP_DOT, OP_REPEAT, OP_END,
          OPNAME, CNAME, CRGB, PROGS, PROGNAME, NPROG,
          CMD_OP, CMD_A, CMD_B, NC, TN, DEPTH, LP, LC,
          ERRTXT, ERRLINE, X, Y, H, PEN, COL, PC, DONE, EV, SX, SY, EX, EY,
          STEPS, MOVED, BX0, BX1, BY0, BY1,
          TRN, TRX0, TRY0, TRX1, TRY1,
          wrap_deg, stepx, stepy, cosd, sind, rad, colour_of,
          compile, reset, run_one, run_to_end,
          trace_on, trace_off, trace_n, trace_seg, tok_is, tok_is_num, tok_word };