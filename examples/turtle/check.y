// check.y -- the property check for turtle.y, and the oracle behind it.
//
// WHY THIS FILE EXISTS
// A golden file proves determinism, not rightness.  `cube` in this campaign
// passed all eight gate items while rendering a defect, because its EXPECTED had
// been generated from the broken output.  So the correctness of this
// interpreter rests on assertions about behaviour, computed here and asserted at
// run time, with no reference file anywhere in sight.  EXPECTED still holds the
// determinism; this holds the geometry.
//
// THE ORACLE, AND WHY IT CANNOT SHARE A BUG WITH THE INTERPRETER
//
// Three independent sources, and they are independent on purpose:
//
//   1. INTEGER ARITHMETIC.  The heading is a count of milli-degrees and the wrap
//      is h - 360000*(h/360000) with a sign fix-up.  There is no trig in it at
//      all, so "four quarter turns return the heading bit for bit" is a
//      statement about integers that fx cannot touch.
//
//   2. fx's OWN TRIG, measured against itself.  The claim that makes polygon
//      closure work is not "the trigonometry is exact" -- it is NOT, and
//      case_antipodal() below measures how far off it is.  The claim is that the
//      error is smaller than the distance from any step's pre-rounding product
//      to a rounding boundary, so the rounding cannot be steered by it.
//      case_margin() measures that distance and requires it to be large; those
//      two measurements together are what make the hand-written tables below
//      trustworthy, and they are the reason a table computed with a different
//      trig library agrees with this one exactly.
//
//   3. HAND-COMPUTED TABLES.  The vertex tables in case_poly() were derived
//      outside this program, from cos and sin at those angles, rounded half away
//      from zero.  They are pasted in as literals and never recomputed here, so
//      a bug in the step function cannot make them agree with themselves.  The
//      derivation is in README.md, "why the polygons close".
//
// WHAT IS ASSERTED
//   W  the heading wrap: exact on hand-picked values, inside [0, 360000) over a
//      sweep, unchanged by a heading far outside the range (no drift), a full
//      turn through the INTERPRETER returning the start bit for bit, and a
//      NEGATIVE heading (right 90 from 0 is 270000) which is where an off-by-one
//      hides -- a golden file cannot see that one, because the picture still
//      comes out right.
//   S  the step vector: exactly zero for a zero step, exactly n along +x, far
//      from a rounding boundary, and within one unit of antipodal everywhere
//      with the violations counted and reported.
//   P  polygon closure: square, triangle, hexagon, pentagon and octagon of
//      100-unit sides, vertex by vertex against the tables, each ending at
//      (0,0) facing exactly 0.
//   M  micro-programs: two to four commands each, tabulated in README.md.  These
//      pin the SIGN CONVENTION -- whether right 90 turns clockwise -- and a sign
//      error produces a perfectly plausible wrong picture.
//   Q  parsing: the exact opcode stream for a repeat, the aliases, comments and
//      separators, `repeat N` running its body exactly N times, nesting, and
//      fourteen malformed programs each refused with a message and no trap.
//   U  the pen: a pen-up move leaves the surface byte for byte as it found it,
//      and the pen-down equivalent of the same program differs -- with the
//      non-blank count asserted NON-ZERO first, so the comparison cannot pass
//      vacuously on two absent things.
//   C  the capture round-trip: the frame's byte count is non-zero, two flushes
//      of the same surface agree, perturbing ONE cell changes the checksum, and
//      flushing again without a change does not.
//   Z  zero allocation: the heap delta over 400 drawn frames is 0.
//   D  determinism in-process: the same program rendered twice gives the same
//      digest.
//
// NO VACUITY ANYWHERE: every comparison that could compare two absent values
// asserts the observed value is present and non-zero first, and the counts a
// comparison depends on come from outside the code under test (literal tables,
// or the surface itself rather than the interpreter's own counters).
//
// ZERO ALLOCATION, like everything else on this program: every buffer is a
// module-level `let`, every scalar crosses a call boundary as a `long`, and no
// array or record literal is written inside a loop.

import fb;
import tlang;
import scene;
import sink;

// The check renders at its own fixed size and never asks the terminal, so its
// answer does not depend on the window it was run in.
const CK_COLS: long = 60;
const CK_ROWS: long = 26;

// The rounding margin required in S3, in Q30 units.  fx's trig is good to about
// 30000 Q30 units at 100 units of step (measured), so requiring 1000000 -- a
// million Q30 units, 10^-3 of a unit -- leaves a factor of 30 of headroom over
// the error while still being far tighter than the 2^29 (half a unit) that would
// actually have to be crossed to change a rounded integer.
const MARGIN: long = 1000000;
const STEPN: long = 100;             // the step the trig error is measured on

let PASS: long = 0;
let FAILED: long = 0;

// ─────────────────────────────────────────────────── the report table ───

const COLW: long = 74;

def head(id: str, what: str) -> void {
    let m = sink.out_mark();
    sink.out_str(id);
    sink.out_str("  ");
    sink.out_str(what);
    sink.out_spaces(m + COLW);
    sink.out_str("ok\n");
    PASS = PASS + 1
};

def fail(id: str, what: str, why: str) -> void {
    let m = sink.out_mark();
    sink.out_str(id);
    sink.out_str("  ");
    sink.out_str(what);
    sink.out_spaces(m + COLW);
    sink.out_str("FAIL  ");
    sink.out_str(why);
    sink.out_str("\n");
    FAILED = FAILED + 1
};

// note(id, what, detail) -- a passing assertion that has a measured number
// worth printing, so the check's output is evidence rather than a tally.
def note(id: str, what: str, label: str, v: long) -> void {
    let m = sink.out_mark();
    sink.out_str(id);
    sink.out_str("  ");
    sink.out_str(what);
    sink.out_spaces(m + COLW);
    sink.out_str("ok  ");
    sink.out_str(label);
    sink.out_str("=");
    sink.out_num(v);
    sink.out_str("\n");
    PASS = PASS + 1
};

// num(id, what, got, want) -- one numeric comparison, reported either way.
def num(id: str, what: str, got: long, want: long) -> void {
    if (got == want) {
        head(id, what)
    } else {
        let m = sink.out_mark();
        sink.out_str(id);
        sink.out_str("  ");
        sink.out_str(what);
        sink.out_spaces(m + COLW);
        sink.out_str("FAIL  got ");
        sink.out_snum2(got);
        sink.out_str(" want ");
        sink.out_snum2(want);
        sink.out_str("\n");
        FAILED = FAILED + 1
    }
};

// ──────────────────────────────────────────────── running a program ───
//
// compile_and_run(src) -- compile, reset, run to the end, with the segment
// trace on.  Returns the opcode count, or -1 if the program was refused.
def compile_and_run(src: str) -> long {
    let n = tlang.compile(src);
    if (n < 0) { return 0 - 1 };
    tlang.reset();
    tlang.trace_on();
    tlang.run_to_end();
    tlang.trace_off();
    n
};

// ──────────────────────────────────────────────────── W: the wrap ───
//
// Hand-picked values, derived on paper.  10^12 = 1000000000000 and
// 1000000000000 mod 360000 = 280000, because 360000 * 2777777 = 999999720000
// and the remainder is 280000.
let WRAP_H: [long; 10] = [0, 360000, 720000, 359999, 0 - 1, 0 - 360000,
                          0 - 360001, 1000000000000, 0 - 1000000000000,
                          359999];
let WRAP_W: [long; 10] = [0, 0, 0, 359999, 359999, 0, 359999, 280000, 80000,
                          359999];

def case_wrap_points() -> void {
    let i = 0;
    let bad = 0 - 1;
    while (i < 10) {
        let got = tlang.wrap_deg(WRAP_H[i]);
        if (got != WRAP_W[i]) {
            if (bad < 0) { bad = i };
        };
        i = i + 1
    };
    if (bad < 0) {
        head("W1", "wrap_deg exact on ten hand-computed values")
    } else {
        sink.out_str("W1  wrap_deg exact on ten hand-computed values");
        sink.out_spaces(COLW);
        sink.out_str("FAIL  value ");
        sink.out_num(bad);
        sink.out_str(": got ");
        sink.out_snum2(tlang.wrap_deg(WRAP_H[bad]));
        sink.out_str(" want ");
        sink.out_snum2(WRAP_W[bad]);
        sink.out_str("\n");
        FAILED = FAILED + 1
    }
};

// case_wrap_sweep(ns) -- the range invariant, and no drift: a heading of
// h + 4000000000 (about 11000 turns) must fold to exactly where h folds to.
// Without that second half, a wrap that only ever saw small headings would pass:
// it is the one that would slowly accumulate a turn per million commands.
def case_wrap_sweep(ns: long) -> void {
    let stride = 360000 / ns;
    if (stride < 1) { stride = 1 };
    let i = 0;
    let bad = 0;
    let drift = 0;
    while (i < 360000) {
        let r = tlang.wrap_deg(i);
        if (r < 0 || r >= 360000) { bad = bad + 1 };
        if (r != i) { bad = bad + 1 };
        // 100000 whole turns: a heading that has been round 100000 times folds
        // to exactly where it started.  It has to be a WHOLE number of turns or
        // this measures the wrong thing (the first version added 4000000000,
        // which is 11111 turns and 40000 millidegrees, so every heading
        // "drifted" by 40000 and the assertion was nonsense).
        if (tlang.wrap_deg(i + 36000000000) != r) { drift = drift + 1 };
        i = i + stride
    };
    if (bad == 0 && drift == 0) {
        note("W2", "wrap_deg in range and drift-free over 360000 headings",
             "headings", 360000 / stride)
    } else {
        sink.out_str("W2  wrap_deg in range and drift-free over 360000 headings");
        sink.out_spaces(COLW);
        sink.out_str("FAIL  out-of-range=");
        sink.out_num(bad);
        sink.out_str(" drift=");
        sink.out_num(drift);
        sink.out_str("\n");
        FAILED = FAILED + 1
    }
};

// case_full_turn() -- a full turn through the INTERPRETER, not through
// wrap_deg: `setheading X` then four `left 90` must land on exactly X's wrap.
// Six starting headings, including two that need wrapping first.
let TURN_FROM: [long; 6] = [0, 1, 123457, 270000, 359999, 200000];

def case_full_turn() -> void {
    let i = 0;
    let bad = 0 - 1;
    while (i < 6) {
        // build "setheading <h> left 90 left 90 left 90 left 90" from the table
        let src = "setheading ";
        src += tostring(TURN_FROM[i]);
        src += " left 90 left 90 left 90 left 90";
        let n = compile_and_run(src);
        let want = tlang.wrap_deg(TURN_FROM[i] * 1000);
        if (n < 0 || tlang.H != want) {
            if (bad < 0) { bad = i }
        };
        i = i + 1
    };
    if (bad < 0) {
        head("W3", "four left 90 through the interpreter return the start")
    } else {
        sink.out_str("W3  four left 90 through the interpreter return the start");
        sink.out_spaces(COLW);
        sink.out_str("FAIL  start ");
        sink.out_num(TURN_FROM[bad]);
        sink.out_str(" gave heading ");
        sink.out_snum2(tlang.H);
        sink.out_str("\n");
        FAILED = FAILED + 1
    }
};

// case_negative() -- the negative half.  right 90 from 0 is 270000, four of them
// return to 0, left 360 leaves the heading alone, and setheading -90 is 270000.
def case_negative() -> void {
    compile_and_run("right 90");
    let a = tlang.H;
    compile_and_run("right 90 right 90 right 90 right 90");
    let b = tlang.H;
    compile_and_run("left 360");
    let c = tlang.H;
    compile_and_run("setheading -90");
    let d = tlang.H;
    compile_and_run("setheading -450");
    let e = tlang.H;
    compile_and_run("right 90 forward 10");
    let ex = tlang.X;
    let ey = tlang.Y;
    if (a == 270000 && b == 0 && c == 0 && d == 270000 && e == 270000 &&
        ex == 0 && ey == 0 - 10) {
        head("W4", "negative headings wrap right: right 90 = 270000, y = -10")
    } else {
        sink.out_str("W4  negative headings wrap right: right 90 = 270000, y = -10");
        sink.out_spaces(COLW);
        sink.out_str("FAIL  r90=");
        sink.out_snum2(a);
        sink.out_str(" 4xr90=");
        sink.out_snum2(b);
        sink.out_str(" l360=");
        sink.out_snum2(c);
        sink.out_str(" s-90=");
        sink.out_snum2(d);
        sink.out_str(" s-450=");
        sink.out_snum2(e);
        sink.out_str(" pos=(");
        sink.out_snum2(ex);
        sink.out_str(",");
        sink.out_snum2(ey);
        sink.out_str(")\n");
        FAILED = FAILED + 1
    }
};

// case_walk(ns) -- `left 1` a whole turn, one degree at a time, through the
// interpreter: 360000 commands and the heading is back where it started, bit for
// bit.  This is the wrap under load rather than at a handful of values, and it
// is the assertion that would notice a wrap which drifts by a unit every few
// thousand turns.
// A whole turn, one degree at a time: 360000 wraps, which is what the
// interpreter's `left 1` does to the heading (run_one is literally
// `H = wrap_deg(H + a)`; W3 asserts that the interpreter really does that, at
// six starting headings, through a compiled program).  Doing it here rather than
// through 360000 opcodes is not a shortcut past the claim -- MAXCMDS is 512, and
// a program that long would test the compiler, not the wrap.  What is being
// asserted is the wrap under load rather than at a handful of values: a wrap that
// drifted by a unit every few thousand turns would pass W1 and W3 and fail here.
def case_walk(ns: long) -> void {
    let h0 = 12345;
    let h = h0;
    let n = 0;
    while (n < 360000) { h = tlang.wrap_deg(h + 1000); n = n + 1 };
    let left = h;
    h = h0;
    n = 0;
    while (n < 360000) { h = tlang.wrap_deg(h - 1000); n = n + 1 };
    let right = h;
    if (left == h0 && right == h0) {
        note("W5", "left 1 and right 1, a whole turn each, return the start",
             "steps", 360000)
    } else {
        sink.out_str("W5  left 1 and right 1, a whole turn each, return the start");
        sink.out_spaces(COLW);
        sink.out_str("FAIL  start=");
        sink.out_snum2(h0);
        sink.out_str(" left1=");
        sink.out_snum2(left);
        sink.out_str(" right1=");
        sink.out_snum2(right);
        sink.out_str("\n");
        FAILED = FAILED + 1
    }
};

// ───────────────────────────────────────────── S: the step vector ───

// case_axes() -- heading 0 is exactly +x and a zero step moves nowhere.  Both
// are exact, not approximate: cos(0) in fx is exactly ONE and sin(0) exactly 0,
// so these are integer identities.
def case_axes() -> void {
    let bad = 0;
    let n = 1;
    let list: [long; 6] = [1, 3, 7, 100, 1000, 99999];
    let i = 0;
    while (i < 6) {
        n = list[i];
        if (tlang.stepx(n, 0) != n || tlang.stepy(n, 0) != 0) { bad = bad + 1 };
        i = i + 1
    };
    let h = 0;
    while (h < 360000) {
        if (tlang.stepx(0, h) != 0 || tlang.stepy(0, h) != 0) { bad = bad + 1 };
        h = h + 997
    };
    if (bad == 0) {
        head("S1", "step(n, 0) = (n, 0) and step(0, h) = (0, 0), exactly")
    } else {
        sink.out_str("S1  step(n, 0) = (n, 0) and step(0, h) = (0, 0), exactly");
        sink.out_spaces(COLW);
        sink.out_str("FAIL  wrong in ");
        sink.out_num(bad);
        sink.out_str(" cases\n");
        FAILED = FAILED + 1
    }
};

// case_margin() -- how far every step the polygon tables use sits from a
// rounding boundary, in Q30 units.  fx.mul(fx.from_int(100), 18740) is a Q30
// value scaled by 100, and fx.round rounds it at the half; the distance from the
// nearest boundary is what the trig error would have to exceed to change the
// answer.  Requiring a million Q30 units (10^-3 of a unit) leaves 30x the error
// fx actually has, which is what makes the hand-computed tables authoritative.
def case_margin() -> void {
    let worst = 1000000000000;
    let h = 0;
    let n = 0;
    while (n < 5) {
        // the headings the five tables use: 0, turn, 2*turn, ... for each
        let sides = 4;
        if (n == 1) { sides = 3 };
        if (n == 2) { sides = 6 };
        if (n == 3) { sides = 5 };
        if (n == 4) { sides = 8 };
        let turn = 360000 / sides;
        h = 0;
        let k = 0;
        while (k < sides) {
            let cx = STEPN * tlang.cosd(h);
            let cy = STEPN * tlang.sind(h);
            // Distance to the nearest rounding TIE, in Q30 units.  Adding half
            // a unit moves every tie onto a multiple of a unit, and then the
            // distance to the nearest such multiple is the margin.  The modulo
            // has to be brought into [0, 2^30) by hand: in this language -7 % 2
            // is -1, not 1, so a bare % hands back a negative distance.
            let qx = cx + 536870912;
            let mq = qx % 1073741824;
            if (mq < 0) { mq = mq + 1073741824 };
            let dx = if (mq < 1073741824 - mq) { mq } else { 1073741824 - mq };
            let qy = cy + 536870912;
            let mq2 = qy % 1073741824;
            if (mq2 < 0) { mq2 = mq2 + 1073741824 };
            let dy = if (mq2 < 1073741824 - mq2) { mq2 } else { 1073741824 - mq2 };
            if (dx < worst) { worst = dx };
            if (dy < worst) { worst = dy };
            h = tlang.wrap_deg(h + turn);
            k = k + 1
        };
        n = n + 1
    };
    if (worst >= MARGIN) {
        note("S2", "every polygon step is far from a rounding boundary",
             "min margin q30", worst)
    } else {
        sink.out_str("S2  every polygon step is far from a rounding boundary");
        sink.out_spaces(COLW);
        sink.out_str("FAIL  min margin q30=");
        sink.out_num(worst);
        sink.out_str(" want>=");
        sink.out_num(MARGIN);
        sink.out_str("\n");
        FAILED = FAILED + 1
    }
};

// case_antipodal() -- step(n, h + 180 degrees) == -step(n, h).
//
// This is NOT exactly true and the check does not pretend it is: fx's sin and cos
// are not exactly odd-symmetric about a half turn, so at STEPN = 100 a few
// hundred of the 360000 headings disagree by ONE unit.  What matters, and what is
// asserted, is the size of the disagreement -- at most one unit -- because one
// unit is what the rounding of a 100-unit step can absorb.  The headings the
// polygon tables use are asserted EXACTLY, and the number of headings that
// disagree at all is printed, so the measurement is visible rather than implied.
let AP_EXACT: [long; 12] = [0, 90000, 180000, 270000, 120000, 240000, 60000,
                             72000, 144000, 216000, 288000, 45000];

def case_antipodal(ns: long) -> void {
    let bad = 0 - 1;
    let i = 0;
    let worst = 0;
    while (i < 12) {
        let h = AP_EXACT[i];
        let ax = tlang.stepx(STEPN, h) + tlang.stepx(STEPN, h + 180000);
        let ay = tlang.stepy(STEPN, h) + tlang.stepy(STEPN, h + 180000);
        if (ax < 0) { ax = 0 - ax };
        if (ay < 0) { ay = 0 - ay };
        if (ax > worst) { worst = ax };
        if (ay > worst) { worst = ay };
        if (ax != 0 || ay != 0) {
            if (bad < 0) { bad = h }
        };
        i = i + 1
    };
    if (bad >= 0) {
        sink.out_str("S3  step(n, h+180) = -step(n, h) at the table headings");
        sink.out_spaces(COLW);
        sink.out_str("FAIL  heading ");
        sink.out_num(bad);
        sink.out_str(" off by ");
        sink.out_num(worst);
        sink.out_str("\n");
        FAILED = FAILED + 1;
        return
    };
    // and the sweep: at most one unit, everywhere
    let stride = 360000 / ns;
    if (stride < 1) { stride = 1 };
    let dis = 0;
    let over = 0;
    let h2 = 0;
    while (h2 < 360000) {
        let bx = tlang.stepx(STEPN, h2) + tlang.stepx(STEPN, h2 + 180000);
        let by = tlang.stepy(STEPN, h2) + tlang.stepy(STEPN, h2 + 180000);
        if (bx < 0) { bx = 0 - bx };
        if (by < 0) { by = 0 - by };
        if (bx > 1 || by > 1) { over = over + 1 };
        if (bx + by > 0) { dis = dis + 1 };
        h2 = h2 + stride
    };
    if (over == 0) {
        note("S3", "antipodal to within 1 unit over the whole circle",
             "disagree", dis)
    } else {
        sink.out_str("S3  antipodal to within 1 unit over the whole circle");
        sink.out_spaces(COLW);
        sink.out_str("FAIL  ");
        sink.out_num(over);
        sink.out_str(" headings off by more than 1 unit\n");
        FAILED = FAILED + 1
    }
};

// case_length() -- the step really is n long: |step(STEPN, h)|^2 within a unit of
// STEPN^2 over the sweep.  Without this, a trig that returned zero would pass
// the antipodality test and every polygon would collapse to a point.
def case_length(ns: long) -> void {
    let stride = 360000 / ns;
    if (stride < 1) { stride = 1 };
    let want = STEPN * STEPN;
    let worst = 0;
    let h = 0;
    let over = 0;
    while (h < 360000) {
        let vx = tlang.stepx(STEPN, h);
        let vy = tlang.stepy(STEPN, h);
        let d = vx * vx + vy * vy - want;
        if (d < 0) { d = 0 - d };
        if (d > worst) { worst = d };
        if (d > 200) { over = over + 1 };
        h = h + stride
    };
    if (over == 0) {
        note("S4", "|step(100, h)|^2 within 200 of 10000 over the circle",
             "worst d", worst)
    } else {
        sink.out_str("S4  |step(100, h)|^2 within 200 of 10000 over the circle");
        sink.out_spaces(COLW);
        sink.out_str("FAIL  ");
        sink.out_num(over);
        sink.out_str(" headings more than 200 out, worst ");
        sink.out_num(worst);
        sink.out_str("\n");
        FAILED = FAILED + 1
    }
};

// ─────────────────────────────────────────── P: polygon closure ───
//
// The tables.  Each is the vertex after each side, from
//   x += round_half_away(100*cos(h)),  y += round_half_away(100*sin(h)),
//   h -= 360/sides,
// computed outside this program (README.md, "why the polygons close"), with no
// value within 2e-3 of a rounding boundary -- which case_margin() confirms in
// here, against fx's own trig, at a million Q30 units.
// They are [long] and not [long; n] because that is the only array type a
// parameter can have: a fixed-size array is not a [long] and this program has no
// cast syntax.  Five literals, allocated once at module scope, never in a loop.
const P4N: long = 4;
let P4: [long] = [100, 0, 100, 0 - 100, 0, 0 - 100, 0, 0];
const P3N: long = 3;
let P3: [long] = [100, 0, 50, 0 - 87, 0, 0];
const P6N: long = 6;
let P6: [long] = [100, 0, 150, 0 - 87, 100, 0 - 174, 0, 0 - 174,
                  0 - 50, 0 - 87, 0, 0];
const P5N: long = 5;
let P5: [long] = [100, 0, 131, 0 - 95, 50, 0 - 154, 0 - 31, 0 - 95, 0, 0];
const P8N: long = 8;
let P8: [long] = [100, 0, 171, 0 - 71, 171, 0 - 171, 100, 0 - 242,
                  0, 0 - 242, 0 - 71, 0 - 171, 0 - 71, 0 - 71, 0, 0];

// poly_src(sides, turn, n) -- the program text, built into a module-level buffer
// rather than as a literal, because it is five near-identical programs and one
// table is easier to keep true than five strings.
let PSB: [byte; 512] = [0; 512];
let PSN: long = 0;

def pbyte(b: long) -> void {
    PSB[PSN] = b;
    PSN = PSN + 1
};
let PBUF: [long; 24] = [0; 24];

def pnum(v: long) -> void {
    let neg = false;
    let n = v;
    if (n < 0) { neg = true; n = 0 - n };
    let d = sink.digits(n);
    let buf = PBUF;
    let q = n;
    let k = d;
    while (k > 0) { buf[k - 1] = 48 + q % 10; q = q / 10; k = k - 1 };
    if (neg) { pbyte(45) };
    k = 0;
    while (k < d) { pbyte(buf[k]); k = k + 1 }
};
def pstr(t: str) -> void {
    let i = 0;
    while (i < len(t)) { pbyte(byte_at(t, i)); i = i + 1 }
};

def poly_src(sides: long, turn: long, n: long) -> str {
    PSN = 0;
    let i = 0;
    while (i < sides) {
        pstr("forward ");
        pnum(n);
        pstr(" right ");
        pnum(turn);
        i = i + 1
    };
    from_bytes(PSB[0:PSN])
};

// poly_case(id, sides, turn, table, nverts) -- run the polygon and check every
// vertex, the segment count, the final position and the final heading.
def poly_case(id: str, sides: long, turn: long, tab: [long], nverts: long) -> void {
    let src = poly_src(sides, turn, STEPN);
    let nc = compile_and_run(src);
    if (nc < 0) {
        let m = sink.out_mark();
        sink.out_str(id);
        sink.out_spaces(m + COLW);
        sink.out_str("FAIL  the program was refused: ");
        sink.out_str(tlang.ERRTXT);
        sink.out_str("\n");
        FAILED = FAILED + 1;
        return
    };
    let bad = 0 - 1;
    if (tlang.TRN != nverts) { bad = nverts };
    let i = 0;
    while (i < nverts && bad < 0) {
        let gx = tlang.TRX1[i];
        let gy = tlang.TRY1[i];
        if (gx != tab[i * 2] || gy != tab[i * 2 + 1]) { bad = i };
        i = i + 1
    };
    if (bad >= 0) {
        let m = sink.out_mark();
        sink.out_str(id);
        sink.out_spaces(m + COLW);
        sink.out_str("FAIL  vertex ");
        sink.out_num(bad);
        sink.out_str(" got (");
        sink.out_snum2(tlang.TRX1[bad]);
        sink.out_str(",");
        sink.out_snum2(tlang.TRY1[bad]);
        sink.out_str(") want (");
        sink.out_snum2(tab[bad * 2]);
        sink.out_str(",");
        sink.out_snum2(tab[bad * 2 + 1]);
        sink.out_str(")\n");
        FAILED = FAILED + 1;
        return
    };
    if (tlang.X != 0 || tlang.Y != 0) {
        let m = sink.out_mark();
        sink.out_str(id);
        sink.out_spaces(m + COLW);
        sink.out_str("FAIL  ends at (");
        sink.out_snum2(tlang.X);
        sink.out_str(",");
        sink.out_snum2(tlang.Y);
        sink.out_str(") not the origin\n");
        FAILED = FAILED + 1;
        return
    };
    if (tlang.H != 0) {
        let m = sink.out_mark();
        sink.out_str(id);
        sink.out_spaces(m + COLW);
        sink.out_str("FAIL  ends facing ");
        sink.out_snum2(tlang.H);
        sink.out_str(" not 0\n");
        FAILED = FAILED + 1;
        return
    };
    note(id, "closes on the unit and returns to heading 0", "sides", sides)
};

def case_polygons() -> void {
    poly_case("P1", 4, 90, P4, P4N);
    poly_case("P2", 3, 120, P3, P3N);
    poly_case("P3", 6, 60, P6, P6N);
    poly_case("P4", 5, 72, P5, P5N);
    poly_case("P5", 8, 45, P8, P8N)
};

// ───────────────────────────────── M: the micro-programs ───
//
// Two to five commands each.  These exist to pin the SIGN CONVENTION: a `right`
// that added to the heading instead of subtracting draws a picture which is a
// perfectly plausible mirror image of the right one, and no golden file can tell
// the difference.  The expected vertices are in README.md's table; they are
// literals here, never recomputed.
//
//   program                                     vertices            ends at        heading
//   forward 100 right 90 forward 100             (100,0)(100,-100)   (100,-100)     270000
//   left 90 forward 10                           (0,10)              (0,10)          90000
//   right 90 forward 10                          (0,-10)             (0,-10)        270000
//   forward 10 left 90 forward 10                (10,0)(10,10)       (10,10)         90000
//   setheading 180 forward 7                     (-7,0)              (-7,0)         180000
//   setheading -90 forward 7                     (0,-7)              (0,-7)         270000
//   forward 10 back 4                            (10,0)(6,0)         (6,0)             0
//   forward 3 left 90 back 3                     (3,0)(3,-3)         (3,-3)          90000
//
// The last two are there because `back` is the command a sign error hides in:
// `back` is a NEGATIVE forward, so its vertex is the second one, and the first
// version of this table listed only the first.  The Python derivation that
// produced the table had no `back` branch at all and silently skipped it, so
// the table and the checker agreed with each other about a program neither had
// really run.  Two mistakes in the same direction is the failure mode this file
// exists to avoid, so the fix is BOTH halves: `back` is modelled, and the final
// position is now asserted as well as the vertices and the heading.
let MIC_CNT: [long; 8] = [2, 1, 1, 2, 1, 1, 2, 2];
let MIC_AT: [long; 8] = [0, 2, 3, 4, 6, 7, 8, 10];
let MIC_X: [long; 12] = [100, 100, 0, 0, 10, 10, 0 - 7, 0, 10, 6, 3, 3];
let MIC_Y: [long; 12] = [0, 0 - 100, 10, 0 - 10, 0, 10, 0, 0 - 7, 0, 0, 0, 0 - 3];
let MIC_H: [long; 8] = [270000, 90000, 270000, 90000, 180000, 270000, 0, 90000];
let MIC_FX: [long; 8] = [100, 0, 0, 10, 0 - 7, 0, 6, 3];
let MIC_FY: [long; 8] = [0 - 100, 10, 0 - 10, 10, 0, 0 - 7, 0, 0 - 3];

def micro_case(i: long, src: str) -> void {
    compile_and_run(src);
    let n = MIC_CNT[i];
    let at = MIC_AT[i];
    let k = 0;
    while (k < n) {
        if (tlang.TRX1[k] != MIC_X[at + k] || tlang.TRY1[k] != MIC_Y[at + k]) {
            let m = sink.out_mark();
            sink.out_str("M1  eight micro-programs match the tabulated path");
            sink.out_spaces(m + COLW);
            sink.out_str("FAIL  '");
            sink.out_str(src);
            sink.out_str("' vertex ");
            sink.out_num(k);
            sink.out_str(" got (");
            sink.out_snum2(tlang.TRX1[k]);
            sink.out_str(",");
            sink.out_snum2(tlang.TRY1[k]);
            sink.out_str(") want (");
            sink.out_snum2(MIC_X[at + k]);
            sink.out_str(",");
            sink.out_snum2(MIC_Y[at + k]);
            sink.out_str(")\n");
            FAILED = FAILED + 1;
            return
        };
        k = k + 1
    };
    if (tlang.H != MIC_H[i]) {
        let m = sink.out_mark();
        sink.out_str("M1  eight micro-programs match the tabulated path");
        sink.out_spaces(m + COLW);
        sink.out_str("FAIL  '");
        sink.out_str(src);
        sink.out_str("' ends facing ");
        sink.out_snum2(tlang.H);
        sink.out_str(" want ");
        sink.out_snum2(MIC_H[i]);
        sink.out_str("\n");
        FAILED = FAILED + 1;
        return
    };
    if (tlang.X != MIC_FX[i] || tlang.Y != MIC_FY[i]) {
        let m = sink.out_mark();
        sink.out_str("M1  eight micro-programs match the tabulated path");
        sink.out_spaces(m + COLW);
        sink.out_str("FAIL  '");
        sink.out_str(src);
        sink.out_str("' ends at (");
        sink.out_snum2(tlang.X);
        sink.out_str(",");
        sink.out_snum2(tlang.Y);
        sink.out_str(") want (");
        sink.out_snum2(MIC_FX[i]);
        sink.out_str(",");
        sink.out_snum2(MIC_FY[i]);
        sink.out_str(")\n");
        FAILED = FAILED + 1
    }
};

def case_micro() -> void {
    let before = FAILED;
    micro_case(0, "forward 100 right 90 forward 100");
    micro_case(1, "left 90 forward 10");
    micro_case(2, "right 90 forward 10");
    micro_case(3, "forward 10 left 90 forward 10");
    micro_case(4, "setheading 180 forward 7");
    micro_case(5, "setheading -90 forward 7");
    micro_case(6, "forward 10 back 4");
    micro_case(7, "forward 3 left 90 back 3");
    if (FAILED == before) { head("M1", "eight micro-programs match the tabulated path") }
};

// ───────────────────────────────────────────────── Q: parsing ───

// case_opcodes() -- the exact opcode stream for a repeat, against a literal
// list written by hand.  This is the assertion that says "a program parses into
// the commands I think it does", rather than "it parsed without complaining".
// (opcode, a, b) per opcode, for `repeat 3 [ forward 2 right 90 ]`:
//   0 repeat  a=3  b=3   (b is the index of the END, so b+1 skips the block)
//   1 forward a=2  b=0
//   2 right  a=-90000 b=0
//   3 end    a=0  b=0
let OP_EXP: [long; 12] = [10, 3, 3, 1, 2, 0, 4, 0 - 90000, 0, 11, 0, 0];
let OP_N: long = 4;

def case_opcodes() -> void {
    let n = tlang.compile("repeat 3 [ forward 2 right 90 ]");
    if (n != OP_N) {
        sink.out_str("Q1  repeat parses to the expected opcode stream");
        sink.out_spaces(COLW);
        sink.out_str("FAIL  ");
        sink.out_num(n);
        sink.out_str(" opcodes, want ");
        sink.out_num(OP_N);
        sink.out_str("\n");
        FAILED = FAILED + 1;
        return
    };
    let i = 0;
    let bad = 0 - 1;
    while (i < OP_N) {
        // the table is (opcode, a, b) TRIPLES, so the stride is three: indexing
        // it as OP_EXP[i], [i+1], [i+2] reads across opcode boundaries and
        // compares opcode 3 against opcode 1's opcode.
        if (tlang.CMD_OP[i] != OP_EXP[i * 3] || tlang.CMD_A[i] != OP_EXP[i * 3 + 1] ||
            tlang.CMD_B[i] != OP_EXP[i * 3 + 2]) { bad = i };
        i = i + 1
    };
    // and the skip target of the repeat is the opcode AFTER its END, which is
    // what makes `repeat 0 [ ... ]` skip the body
    if (tlang.CMD_B[0] != 3 || tlang.CMD_B[0] + 1 != OP_N) { bad = 0 };
    if (bad >= 0) {
        sink.out_str("Q1  repeat parses to the expected opcode stream");
        sink.out_spaces(COLW);
        sink.out_str("FAIL  opcode ");
        sink.out_num(bad);
        sink.out_str(" got (");
        sink.out_num(tlang.CMD_OP[bad]);
        sink.out_str(",");
        sink.out_snum2(tlang.CMD_A[bad]);
        sink.out_str(",");
        sink.out_snum2(tlang.CMD_B[bad]);
        sink.out_str(")\n");
        FAILED = FAILED + 1;
        return
    };
    head("Q1", "repeat parses to the expected opcode stream")
};

// case_aliases() -- the short names mean the same as the long ones, and a
// comment and a ';' are both ignored.
def case_aliases() -> void {
    let a = tlang.compile("forward 5 right 90 back 5");
    let opa: [long; 6] = [0, 0, 0, 0, 0, 0];
    let i = 0;
    while (i < 3) {
        opa[i * 2] = tlang.CMD_OP[i];
        opa[i * 2 + 1] = tlang.CMD_A[i];
        i = i + 1
    };
    tlang.reset();
    let b = tlang.compile("f 5 r 90 b 5");
    let same = a == b;
    let i2 = 0;
    while (same && i2 < 3) {
        if (tlang.CMD_OP[i2] != opa[i2 * 2] || tlang.CMD_A[i2] != opa[i2 * 2 + 1]) {
            same = false
        };
        i2 = i2 + 1
    };
    tlang.reset();
    let c = tlang.compile("# a comment\nf 5 ; r 90 ; b 5 # trailing\n");
    if (same && c == a) {
        head("Q2", "f/r/b are forward/right/back; # and ; are ignored")
    } else {
        sink.out_str("Q2  f/r/b are forward/right/back; # and ; are ignored");
        sink.out_spaces(COLW);
        sink.out_str("FAIL  long=");
        sink.out_num(a);
        sink.out_str(" short=");
        sink.out_num(b);
        sink.out_str(" commented=");
        sink.out_num(c);
        sink.out_str("\n");
        FAILED = FAILED + 1
    }
};

// case_repeat() -- `repeat N [ forward 1 ]` advances exactly N units, for N in a
// table.  This is the assertion that found the loop-stack defect in this very
// file's first draft, where a nested repeat overwrote its parent's remaining-pass
// count: the picture was still closed and the frame table still deterministic.
let REP_N: [long; 6] = [0, 1, 2, 3, 17, 100];

def case_repeat() -> void {
    let i = 0;
    let bad = 0 - 1;
    while (i < 6) {
        let src = "repeat ";
        src += tostring(REP_N[i]);
        src += " [ forward 1 ]";
        compile_and_run(src);
        if (tlang.X != REP_N[i]) {
            if (bad < 0) { bad = i }
        };
        if (i > 0 && tlang.TRN != REP_N[i]) {
            if (bad < 0) { bad = i }
        };
        i = i + 1
    };
    if (bad < 0) {
        head("Q3", "repeat N runs its body exactly N times, for six counts")
    } else {
        sink.out_str("Q3  repeat N runs its body exactly N times, for six counts");
        sink.out_spaces(COLW);
        sink.out_str("FAIL  N=");
        sink.out_num(REP_N[bad]);
        sink.out_str(" advanced to x=");
        sink.out_num(tlang.X);
        sink.out_str(" drew ");
        sink.out_num(tlang.TRN);
        sink.out_str(" segments\n");
        FAILED = FAILED + 1
    }
};

// case_nesting() -- two nested loops, and the trace length, which is what the
// first draft got wrong.
def case_nesting() -> void {
    compile_and_run("repeat 2 [ repeat 3 [ forward 10 ] ]");
    let x = tlang.X;
    let n = tlang.TRN;
    tlang.reset();
    compile_and_run("repeat 0 [ forward 100 ]");
    let z = tlang.X;
    let zn = tlang.TRN;
    tlang.reset();
    compile_and_run("repeat 2 [ repeat 0 [ forward 100 ] forward 1 ]");
    let iz = tlang.X;
    if (x == 60 && n == 6 && z == 0 && zn == 0 && iz == 2) {
        head("Q4", "nested repeats: 2x3 forward 10 = 60, repeat 0 draws nothing")
    } else {
        sink.out_str("Q4  nested repeats: 2x3 forward 10 = 60, repeat 0 draws nothing");
        sink.out_spaces(COLW);
        sink.out_str("FAIL  x=");
        sink.out_num(x);
        sink.out_str(" segs=");
        sink.out_num(n);
        sink.out_str(" repeat0x=");
        sink.out_num(z);
        sink.out_str(" segs=");
        sink.out_num(zn);
        sink.out_str(" inner0x=");
        sink.out_num(iz);
        sink.out_str("\n");
        FAILED = FAILED + 1
    }
};

// case_errors() -- fourteen malformed programs, each refused with a message and
// no trap.  This is the in-process half of "no runtime trap on any path": if one
// of these trapped, the whole check would die here rather than report, which is
// why the message is asserted rather than the absence of a crash.
let BAD_N: long = 14;
let BAD_SRC: [str] = [
    "froward 5",              // a typo
    "forward",                // no distance
    "forward x",              // a word where a number belongs
    "pen sideways",           // pen wants up or down
    "colour mauve",           // no such colour
    "colour 3",               // a number where a name belongs
    "repeat 2 forward 1 ]",   // no '[' after the count
    "]",                      // a ']' with nothing open
    "[",                      // a '[' with no repeat
    "repeat 2 [ forward 1",   // unclosed
    "jump 1",                 // one number, not two
    "repeat 0 -1 [ forward 1 ]",  // a negative count
    "forward 999999",         // out of range
    "left 99999999"           // out of range
];

def case_errors() -> void {
    let i = 0;
    let accepted = 0;
    let silent = 0;
    let nofix = 0;
    let first = 0;
    while (i < BAD_N) {
        let n = tlang.compile(BAD_SRC[i]);
        if (n >= 0) {
            accepted = accepted + 1;
            if (first == 0) { first = i }
        } else {
            if (len(tlang.ERRTXT) == 0) { silent = silent + 1 }
        };
        i = i + 1
    };
    // The diagnostic itself, not just its existence.  A typo on line 3 has to be
    // reported as an unknown command ON LINE 3 -- and both halves are needed: a
    // parser that skipped the unknown word and then complained about the NUMBER
    // after it also returns -1 with a message and a line number, and "refused
    // with a message" is satisfied by it.  That is exactly what mutation 14 in
    // mutate.py does, and this assertion is what caught it.
    tlang.compile("forward 1\nforward 1\nfroward 2");
    let line = tlang.ERRLINE;
    let msg = tlang.ERRTXT;
    if (line != 3) { nofix = 1 };
    if (msg.index_of("unknown command") < 0) { nofix = nofix + 10 };
    if (accepted == 0 && silent == 0 && nofix == 0) {
        note("Q5", "fourteen malformed programs refused, with a message",
             "refused", BAD_N)
    } else {
        sink.out_str("Q5  fourteen malformed programs refused, with a message");
        sink.out_spaces(COLW);
        sink.out_str("FAIL  accepted=");
        sink.out_num(accepted);
        sink.out_str(" (first: '");
        sink.out_str(BAD_SRC[first]);
        sink.out_str("') silent=");
        sink.out_num(silent);
        sink.out_num(line);
        sink.out_str(" diagnostic-flavour=");
        sink.out_num(nofix);
        sink.out_str(" msg=[");
        sink.out_str(msg);
        sink.out_str("]\n");
        FAILED = FAILED + 1
    }
};

// Q6 -- every colour name resolves to its documented index.  The names are the
// ones in tlang.CNAME and the indices are the order they appear in, written out
// here rather than asked of tlang, because "colour_of returns whatever
// colour_of returns" is not an assertion.  This is the argument half of "a
// program you can write a file for parses with the right commands": the operator
// spells a colour and gets that colour, not merely a colour.
let CNAME0: [str] = ["black", "red", "green", "yellow", "blue", "magenta", "cyan",
                     "white", "orange", "grey", "brown", "lime", "pink", "violet",
                     "silver", "gold"];

def case_colours() -> void {
    let bad = 0;
    let first = 0 - 1;
    let i = 0;
    while (i < 16) {
        let got = tlang.colour_of(CNAME0[i]);
        if (got != i) {
            bad = bad + 1;
            if (first < 0) { first = i }
        };
        i = i + 1
    };
    // and through the compiler, so the opcode carries the right index
    let j = 0;
    while (j < 16) {
        tlang.compile("colour " + CNAME0[j]);
        if (tlang.CMD_A[0] != j) {
            bad = bad + 1;
            if (first < 0) { first = j }
        };
        j = j + 1
    };
    if (tlang.colour_of("mauve") >= 0) { bad = bad + 1; first = 99 };
    if (tlang.colour_of("") >= 0) { bad = bad + 1; first = 99 };
    if (bad == 0) {
        num("Q6", "all sixteen colour names resolve to their own index", bad, 0)
    } else {
        sink.out_str("Q6  all sixteen colour names resolve to their own index");
        sink.out_spaces(COLW);
        sink.out_str("FAIL  ");
        sink.out_num(bad);
        sink.out_str(" wrong, first=");
        sink.out_snum2(first);
        sink.out_str("\n");
        FAILED = FAILED + 1
    }
};

// ────────────────────────────────────────── U: the pen, and C: capture ───

// render(src) -- compile, fit the view to the program's own bounding box, clear
// and draw every command.  The same sequence the headless path uses, so what the
// pen assertions measure is the real drawing path.
def render(src: str) -> long {
    let n = tlang.compile(src);
    if (n < 0) { return 0 - 1 };
    scene.set_size(CK_ROWS, CK_COLS);
    tlang.reset();
    tlang.run_to_end();
    scene.fit(CK_ROWS, CK_COLS, tlang.BX0, tlang.BY0, tlang.BX1, tlang.BY1);
    scene.clear_frame();
    tlang.reset();
    let stop = false;
    while (stop == false) {
        let e = scene.step_draw();
        if (e == 3 || e == 4) { stop = true }
    };
    n
};

// render_fixed(src) -- the same, but with the projection FORCED to one view for
// every program.  The pen assertions compare whole-frame digests, and the
// automatic fit is derived from each program's own bounding box, so two programs
// with different extents get different views and their frames are not comparable
// at all: the first version of U3 compared a blank frame drawn under one fit
// against a 10-cell line drawn under another and called the difference a failure.
// One cell per unit, origin ten columns in, and the segments are 12 units, so
// nothing clips and the cell counts mean what they say.
def render_fixed(src: str) -> long {
    let n = render(src);
    scene.fixed_view(0, 0, 10, CK_ROWS / 2);
    scene.clear_frame();
    tlang.reset();
    let stop = false;
    while (stop == false) {
        let e = scene.step_draw();
        if (e == 3 || e == 4) { stop = true }
    };
    n
};

def case_pen() -> void {
    scene.set_size(CK_ROWS, CK_COLS);
    scene.clear_frame();
    let cells = CK_ROWS * CK_COLS;
    let blank = sink.grid_digest(scene.SRF);
    let blank_n = scene.blank_cells();
    if (blank_n != cells) {
        sink.out_str("U0  a cleared surface is entirely blank");
        sink.out_spaces(CK_COLS);
        sink.out_str("FAIL  ");
        sink.out_num(blank_n);
        sink.out_str(" of ");
        sink.out_num(cells);
        sink.out_str(" cells are blank\n");
        FAILED = FAILED + 1;
        return
    };
    head("U0", "a cleared surface is entirely blank");

    // U1: a pen-up move leaves the surface exactly as it found it.
    render_fixed("pen up forward 12 forward 12");
    let up_ink = scene.inked();
    let up_blank = scene.blank_cells();
    let up_dig = sink.grid_digest(scene.SRF);
    if (up_ink == 0 && up_blank == cells && up_dig == blank) {
        note("U1", "pen up moves leave every cell untouched", "cells inked",
             up_ink)
    } else {
        sink.out_str("U1  pen up moves leave every cell untouched");
        sink.out_spaces(CK_COLS);
        sink.out_str("FAIL  ink=");
        sink.out_num(up_ink);
        sink.out_str(" blank=");
        sink.out_num(up_blank);
        sink.out_str(" same-digest=");
        sink.out_num(if (up_dig == blank) { 1 } else { 0 });
        sink.out_str("\n");
        FAILED = FAILED + 1
    };

    // U2: and the NON-VACUITY half -- the same moves with the pen down really do
    // draw.  Asserted BEFORE anything is compared against it, because "the pen-up
    // frame equals the blank frame" is also true of a rasteriser that draws
    // nothing at all, and the campaign has shipped that vacuous pass twice.
    render_fixed("forward 12 forward 12");
    let dn_ink = scene.inked();
    let dn_blank = scene.blank_cells();
    let dn_dig = sink.grid_digest(scene.SRF);
    if (dn_ink > 0 && dn_blank < cells && dn_dig != blank) {
        note("U2", "the same two moves with the pen down DO draw", "cells inked",
             dn_ink)
    } else {
        sink.out_str("U2  the same two moves with the pen down DO draw");
        sink.out_spaces(CK_COLS);
        sink.out_str("FAIL  ink=");
        sink.out_num(dn_ink);
        sink.out_str(" blank=");
        sink.out_num(dn_blank);
        sink.out_str(" digest-changed=");
        sink.out_num(if (dn_dig != blank) { 1 } else { 0 });
        sink.out_str("\n");
        FAILED = FAILED + 1
    };

    // U3: the sharp one, and the one that needs no argument about what "nothing"
    // looks like.  Three programs, ONE forced view, one cell per unit:
    //
    //   a   pen down forward 12   pen up forward 12   pen down forward 12
    //   b   forward 12            jump 12 0           forward 12
    //   c   forward 12            forward 12           forward 12
    //
    // a and b walk the identical path; only b has no pen-up anywhere.  So a and b
    // must produce BYTE-IDENTICAL frames -- including colours -- and if a's
    // middle segment leaked a single pixel the digests would differ.  c is the
    // non-vacuity half: c draws the segment a does not, so it must ink MORE
    // cells and have a different digest, or the equality above would be the
    // trivial one of two blank frames.
    render_fixed("pen down forward 12 pen up forward 12 pen down forward 12");
    let a_ink = scene.inked();
    let a_dig = sink.grid_digest(scene.SRF);
    render_fixed("forward 12 jump 12 0 forward 12");
    let b_dig = sink.grid_digest(scene.SRF);
    let b_ink = scene.inked();
    render_fixed("forward 12 forward 12 forward 12");
    let c_ink = scene.inked();
    let c_dig = sink.grid_digest(scene.SRF);
    if (a_dig == b_dig && a_ink == b_ink && a_ink > 0 && c_ink > a_ink &&
        c_dig != a_dig) {
        note("U3", "a pen-up segment's frame is byte-identical to skipping it",
             "cells a/b", a_ink)
    } else {
        sink.out_str("U3  a pen-up segment's frame is byte-identical to skipping it");
        sink.out_spaces(CK_COLS);
        sink.out_str("FAIL  a-b-same=");
        sink.out_num(if (a_dig == b_dig) { 1 } else { 0 });
        sink.out_str(" a-ink=");
        sink.out_num(a_ink);
        sink.out_str(" b-ink=");
        sink.out_num(b_ink);
        sink.out_str(" c-ink=");
        sink.out_num(c_ink);
        sink.out_str(" c-differs=");
        sink.out_num(if (c_dig != a_dig) { 1 } else { 0 });
        sink.out_str("\n");
        FAILED = FAILED + 1
    };

    // U4: a dot is one cell with the pen down and nothing with the pen up
    render_fixed("dot");
    let d1 = scene.inked();
    let d1b = scene.blank_cells();
    render_fixed("pen up dot");
    let d2 = scene.inked();
    let d2b = scene.blank_cells();
    let d2d = sink.grid_digest(scene.SRF);
    if (d1 == 1 && d1b == cells - 1 && d2 == 0 && d2b == cells && d2d == blank) {
        num("U4", "a dot is 1 cell with the pen down, 0 with it up", d1, 1)
    } else {
        sink.out_str("U4  a dot is 1 cell with the pen down, 0 with it up");
        sink.out_spaces(CK_COLS);
        sink.out_str("FAIL  down=");
        sink.out_num(d1);
        sink.out_str("/");
        sink.out_num(d1b);
        sink.out_str(" up=");
        sink.out_num(d2);
        sink.out_str("/");
        sink.out_num(d2b);
        sink.out_str("\n");
        FAILED = FAILED + 1
    };

    // U5: the frame digest watches all THREE channels, tested one at a time.
    // Comparing two programmes in two colours is NOT this test: the glyph is
    // chosen by the colour, so such a pair differs in the codepoint too and a
    // digest watching only the codepoint would agree that they differ.  So poke
    // one cell three times -- codepoint, then foreground alone, then background
    // alone -- and require the digest to move each time.  (The first version of
    // this assertion was the colour pair, and it passed a digest with the
    // foreground term deleted; that is mutation 24 in mutate.py.)
    render_fixed("forward 12");
    let d0 = sink.grid_digest(scene.SRF);
    let r = CK_ROWS / 2;
    scene.poke(r, 14, 0);
    let d1 = sink.grid_digest(scene.SRF);
    scene.poke(r, 14, 1);
    let d2 = sink.grid_digest(scene.SRF);
    scene.poke(r, 14, 2);
    let d3 = sink.grid_digest(scene.SRF);
    scene.poke(r, 14, 1);
    scene.poke(r, 14, 0);
    let d4 = sink.grid_digest(scene.SRF);
    if (d1 != d0 && d2 != d1 && d3 != d2 && d4 == d0) {
        head("U5", "the digest watches the codepoint, the fg and the bg")
    } else {
        sink.out_str("U5  the digest watches the codepoint, the fg and the bg");
        sink.out_spaces(COLW);
        sink.out_str("FAIL  glyph=");
        sink.out_num(if (d1 != d0) { 1 } else { 0 });
        sink.out_str(" fg=");
        sink.out_num(if (d2 != d1) { 1 } else { 0 });
        sink.out_str(" bg=");
        sink.out_num(if (d3 != d2) { 1 } else { 0 });
        sink.out_str(" restored=");
        sink.out_num(if (d4 == d0) { 1 } else { 0 });
        sink.out_str("\n");
        FAILED = FAILED + 1
    }
};

// case_capture() -- the byte-level round trip.  A checksum that is compared
// without first proving it is over a non-empty stream is the vacuous pass this
// campaign has produced twice, so the byte count is asserted first and printed.
def case_capture() -> void {
    scene.set_size(CK_ROWS, CK_COLS);
    scene.clear_frame();
    render("colour red forward 50 right 90 forward 50 right 90 forward 50");
    fb.capture_on();
    fb.capture_reset();
    fb.flush(scene.SRF);
    let n1 = fb.capture_len();
    let c1 = fb.capture_checksum();
    fb.capture_reset();
    fb.flush(scene.SRF);
    let n2 = fb.capture_len();
    let c2 = fb.capture_checksum();
    // C1 FIRST, and separately: a checksum compared without first proving it is
    // over a non-empty stream is the vacuous pass this campaign has produced
    // twice.  c1 over zero bytes would equal c2 over zero bytes for ever.
    if (n1 > 0 && n2 == n1 && c1 == c2) {
        note("C1", "the frame flushes to a non-empty, repeatable capture",
             "bytes", n1)
    } else {
        sink.out_str("C1  the frame flushes to a non-empty, repeatable capture");
        sink.out_spaces(COLW);
        sink.out_str("FAIL  n1=");
        sink.out_num(n1);
        sink.out_str(" n2=");
        sink.out_num(n2);
        sink.out_str(" same-checksum=");
        sink.out_num(if (c1 == c2) { 1 } else { 0 });
        sink.out_str("\n");
        FAILED = FAILED + 1
    };
    // perturb exactly one cell and flush again
    scene.perturb();
    fb.capture_reset();
    fb.flush(scene.SRF);
    let n3 = fb.capture_len();
    let c3 = fb.capture_checksum();
    // and put it back: the checksum must return
    scene.perturb();
    fb.capture_reset();
    fb.flush(scene.SRF);
    let c4 = fb.capture_checksum();
    // and a blank surface must not have the same checksum as a drawn one
    scene.clear_frame();
    fb.capture_reset();
    fb.flush(scene.SRF);
    let c5 = fb.capture_checksum();
    if (n3 > 0 && c3 != c1 && c4 == c1 && c5 != c1) {
        note("C2", "one perturbed cell changes the checksum, back again restores it",
             "bytes", n1)
    } else {
        sink.out_str("C2  one perturbed cell changes the checksum; back again restores it");
        sink.out_spaces(COLW);
        sink.out_str("FAIL  n3=");
        sink.out_num(n3);
        sink.out_str(" perturbed-differs=");
        sink.out_num(if (c3 != c1) { 1 } else { 0 });
        sink.out_str(" restored=");
        sink.out_num(if (c4 == c1) { 1 } else { 0 });
        sink.out_str(" blank-differs=");
        sink.out_num(if (c5 != c1) { 1 } else { 0 });
        sink.out_str("\n");
        FAILED = FAILED + 1
    };
    fb.capture_off()
};

// ───────────────────────────────── V: absolute geometry ───
//
// Everything above compares the interpreter against ITSELF: two renders, two
// programs that ought to match, a count against another count.  Those comparisons
// are blind to a defect that shifts every pixel the same way -- a rasteriser
// that wrote one row lower, a view fitted to the wrong axis, a line one cell
// short.  V1..V3 pin the projection and the rasteriser to ABSOLUTE hand-computed
// cells, so a uniform shift cannot hide.
//
// The projection is fixed by the documented rule, so the expected cells can be
// written out by hand: with a forced view of shift 0 and the origin at column 10
// row 13, a 12-unit step along +x from the origin is cells (13,10) through
// (13,22) and nothing else -- THIRTEEN cells, in one row, starting at column 10,
// because both endpoints are plotted and a 12-unit span has 13 of them.  The
// first version of this assertion said twelve and failed with ink=13, which is
// the right answer and the wrong expectation: a line's cell count is its length
// in units PLUS ONE, and every count in this file that comes from a length needs
// that +1.
def case_cells() -> void {
    render_fixed("forward 12");
    let ink = scene.inked();
    let blank = scene.blank_cells();
    let r = CK_ROWS / 2;
    let want = 13;
    let cols = scene.cols();
    let rows = scene.rows();
    // every one of the twelve cells holds a glyph, and every other cell is blank
    let wrong = 0;
    let first = 0 - 1;
    let c = 0;
    let at = 10;
    while (c < cols) {
        let is_ink = scene.SRF.ch[r * cols + c] != fb.space;
        if (c >= at && c < at + want) {
            if (is_ink == false) {
                if (first < 0) { first = c };
                wrong = wrong + 1
            }
        } else if (is_ink) {
            wrong = wrong + 1;
            if (first < 0) { first = c }
        };
        c = c + 1
    };
    // and no cell in any other row
    let rr = 0;
    while (rr < rows) {
        if (rr != r) {
            let cc = 0;
            while (cc < cols) {
                if (scene.SRF.ch[rr * cols + cc] != fb.space) {
                    wrong = wrong + 1;
                    if (first < 0) { first = cc }
                };
                cc = cc + 1
            }
        };
        rr = rr + 1
    };
    if (ink == want && blank == rows * cols - want && wrong == 0) {
        note("V1", "a 12-unit step inks exactly cells (13,10)..(13,22)",
             "cells", ink)
    } else {
        sink.out_str("V1  a 12-unit step inks exactly cells (13,10)..(13,22)");
        sink.out_spaces(COLW);
        sink.out_str("FAIL  ink=");
        sink.out_num(ink);
        sink.out_str(" wrong-cells=");
        sink.out_num(wrong);
        sink.out_str(" first-col=");
        sink.out_snum2(first);
        sink.out_str("\n");
        FAILED = FAILED + 1
    };

    // V2: the view is fitted to each axis separately, and the shifts are
    // hand-derivable from the rule: the largest shift at which the span still
    // fits the usable cells.  For the unit square (a 100-unit span on both axes)
    // on a 60x26 surface the usable widths are 58 and 24: x needs shift 1
    // (100>>1 = 50 <= 58) and y needs shift 3 (100>>2 = 25 > 24, 100>>3 = 12).
    // A single shared shift would give 1/1 and the square would come out 50
    // cells wide and 50 rows tall -- twice as tall as it is wide, because a
    // terminal cell is.
    render("colour red forward 100 right 90 forward 100 right 90 forward 100 right 90 forward 100 right 90");
    let sx = scene.shift_x();
    let sy = scene.shift_y();
    if (sx == 1 && sy == 3) {
        note("V2", "the view is fitted per axis: shift 1/3 for the unit square",
             "shift x", sx)
    } else {
        sink.out_str("V2  the view is fitted per axis: shift 1/3 for the unit square");
        sink.out_spaces(COLW);
        sink.out_str("FAIL  shift=");
        sink.out_num(sx);
        sink.out_str("/");
        sink.out_num(sy);
        sink.out_str("\n");
        FAILED = FAILED + 1
    };

    // V3: the bounding box the view is fitted to.  It has to include the point
    // the turtle STARTED at as well as everywhere it went, because the start is
    // not necessarily the minimum: a program that turns left walks into negative
    // x, and one that reports only the far side of the path centres the picture
    // off by half its own width.  0,-100 .. 100,0 is the unit square's box.
    if (tlang.BX0 == 0 && tlang.BY0 == 0 - 100 && tlang.BX1 == 100 && tlang.BY1 == 0) {
        head("V3", "the bounding box includes the origin the turtle started at")
    } else {
        sink.out_str("V3  the bounding box includes the origin the turtle started at");
        sink.out_spaces(COLW);
        sink.out_str("FAIL  box=(");
        sink.out_snum2(tlang.BX0);
        sink.out_str(",");
        sink.out_snum2(tlang.BY0);
        sink.out_str(")..(");
        sink.out_snum2(tlang.BX1);
        sink.out_str(",");
        sink.out_snum2(tlang.BY1);
        sink.out_str(") want (0,-100)..(100,0)\n");
        FAILED = FAILED + 1
    };

    // V4: the same box, for a path that never comes back.  This is the case that
    // catches a reset() which starts the box at the wrong place: `forward 100`
    // only ever visits x >= 0, so a box that began at 1 would stay at 1 and the
    // picture would be centred a unit off -- invisible in the golden (it is
    // deterministic either way) and invisible in P1..P5 (the polygons are about
    // closure, not about where the picture sits).
    render("forward 100");
    if (tlang.BX0 == 0 && tlang.BY0 == 0 && tlang.BX1 == 100 && tlang.BY1 == 0) {
        head("V4", "a path that only goes +x still has the origin in its box")
    } else {
        sink.out_str("V4  a path that only goes +x still has the origin in its box");
        sink.out_spaces(COLW);
        sink.out_str("FAIL  box=(");
        sink.out_snum2(tlang.BX0);
        sink.out_str(",");
        sink.out_snum2(tlang.BY0);
        sink.out_str(")..(");
        sink.out_snum2(tlang.BX1);
        sink.out_str(",");
        sink.out_snum2(tlang.BY1);
        sink.out_str(") want (0,0)..(100,0)\n");
        FAILED = FAILED + 1
    }
};


// ─────────────────────────────── Z: no allocation, D: determinism ───

// case_zero_alloc() -- the heap delta over 400 drawn frames is 0.  Asserted
// rather than asserted-in-the-README, because "no per-frame allocation" is a
// property of the frame loop and the frame loop is the thing the arena punishes.
// The frame count is checked to be non-zero first, for the same reason as
// everywhere else here.
def case_zero_alloc() -> void {
    scene.set_size(CK_ROWS, CK_COLS);
    scene.clear_frame();
    tlang.compile("colour red repeat 8 [ forward 20 right 45 ]");
    tlang.reset();
    tlang.run_to_end();
    scene.fit(CK_ROWS, CK_COLS, tlang.BX0, tlang.BY0, tlang.BX1, tlang.BY1);
    scene.clear_frame();
    tlang.reset();
    fb.capture_on();
    // warm the frame path once, so a first-call allocation is not counted
    scene.step_draw();
    let h0 = heap_used();
    let frames = 400;
    let f = 0;
    while (f < frames) {
        scene.step_draw();
        fb.flush_diff(scene.SRF);
        f = f + 1
    };
    let h1 = heap_used();
    fb.capture_off();
    let delta = h1 - h0;
    if (delta == 0 && frames > 0) {
        note("Z1", "heap delta over 400 drawn frames", "delta", delta)
    } else {
        sink.out_str("Z1  heap delta over 400 drawn frames");
        sink.out_spaces(COLW);
        sink.out_str("FAIL  delta=");
        sink.out_snum2(delta);
        sink.out_str(" frames=");
        sink.out_num(frames);
        sink.out_str("\n");
        FAILED = FAILED + 1
    }
};

// case_determinism() -- the same program rendered twice, from scratch, gives the
// same digest; and two different programs do not.
def case_determinism() -> void {
    scene.clear_frame();
    render("colour green repeat 6 [ forward 30 right 60 ]");
    let d1 = sink.grid_digest(scene.SRF);
    scene.clear_frame();
    render("colour green repeat 6 [ forward 30 right 60 ]");
    let d2 = sink.grid_digest(scene.SRF);
    scene.clear_frame();
    render("colour green repeat 5 [ forward 30 right 60 ]");
    let d3 = sink.grid_digest(scene.SRF);
    if (d1 == d2 && d1 != d3) {
        head("D1", "the same program renders to the same digest, a different one not")
    } else {
        sink.out_str("D1  the same program renders to the same digest, a different one not");
        sink.out_spaces(COLW);
        sink.out_str("FAIL  repeat-runs-differ=");
        sink.out_num(if (d1 != d2) { 1 } else { 0 });
        sink.out_str(" different-program-same=");
        sink.out_num(if (d1 == d3) { 1 } else { 0 });
        sink.out_str("\n");
        FAILED = FAILED + 1
    }
};

// ─────────────────────────────────────────────────────────── the run ───

def run(ns: long) -> long {
    PASS = 0;
    FAILED = 0;
    sink.out_reset();
    sink.out_str("turtle: property check -- no reference file is involved\n");
    sink.out_str("turtle: sample headings per sweep = ");
    sink.out_num(ns);
    sink.out_str(", surface ");
    sink.out_num(CK_COLS);
    sink.out_str("x");
    sink.out_num(CK_ROWS);
    sink.out_str("\n");

    case_wrap_points();
    sink.out_flush();
    case_wrap_sweep(ns);
    sink.out_flush();
    case_full_turn();
    sink.out_flush();
    case_negative();
    sink.out_flush();
    case_walk(ns);
    sink.out_flush();
    case_axes();
    sink.out_flush();
    case_margin();
    sink.out_flush();
    case_antipodal(ns);
    sink.out_flush();
    case_length(ns);
    sink.out_flush();
    case_polygons();
    sink.out_flush();
    case_micro();
    sink.out_flush();
    case_opcodes();
    sink.out_flush();
    case_aliases();
    sink.out_flush();
    case_repeat();
    sink.out_flush();
    case_nesting();
    sink.out_flush();
    case_errors();
    sink.out_flush();
    case_colours();
    sink.out_flush();
    case_pen();
    sink.out_flush();
    case_capture();
    sink.out_flush();
    case_cells();
    sink.out_flush();
    case_zero_alloc();
    sink.out_flush();
    case_determinism();
    sink.out_flush();

    sink.out_str("\nassertions ");
    sink.out_num(PASS + FAILED);
    sink.out_str("  passed ");
    sink.out_num(PASS);
    sink.out_str("  failed ");
    sink.out_num(FAILED);
    sink.out_str("\n");
    if (FAILED == 0) { sink.out_str("check: PASS\n") } else {
        sink.out_str("check: FAIL\n")
    };
    sink.out_flush();
    FAILED
};

export { run };