// check.y -- boids' property check: what must be true whatever the numbers
// look like, asserted with no reference file involved.
//
// ===========================================================================
// WHY THIS FILE IS THE POINT
//
// A golden file proves DETERMINISM, not rightness.  `cube` passed all eight
// gate items while rendering a defect, because its EXPECTED had been generated
// from the broken output.  Every assertion below is a property of the
// arithmetic or of the physics, computed here, from the code under test and
// from numbers derived BY HAND -- never from a recorded run of the code.
//
// ===========================================================================
// THE VACUOUS PASS, AND THE FOUR RULES AGAINST IT
//
// Two agents in this campaign shipped checks that compared two values which
// were BOTH ABSENT, and one got `heap_used() == heap_used()` because a typo in
// a matcher meant the field never arrived.  A comparison of two zeroes is
// true.  So:
//
//   1. PRESENT FIRST.  Every assertion about an observed value is preceded by
//      one about that value being non-zero / non-empty / the right count.  If
//      the thing under test produced nothing, the check fails on THAT, not on
//      the comparison.
//   2. COUNTS FROM OUTSIDE.  The expected number of neighbours, the expected
//      flock size, the expected pair count and the expected roots are all
//      computed from the coordinates this file chose and the geometry of the
//      circle -- never read back out of the simulator.
//   3. NO RE-IMPLEMENTATION.  The check never recomputes a force with its own
//      copy of Reynolds' formulas.  It sets up a world, calls the production
//      accumulate()/rule_sum()/step(), and reads the production accumulators.
//   4. A MUTATION MUST FAIL.  Every group below was run against a deliberately
//      broken build; see inject.sh and README.md.  A mutation that is NOT
//      caught is proved equivalent or filed, never dropped.
//
// ===========================================================================
// THE HAND-COMPUTED NUMBERS, AND WHERE THEY COME FROM
//
// oracle.py in this folder is an INDEPENDENT integer model of flock.y's
// arithmetic, in a language with unbounded integers, written from the same
// formulas.  Every exact constant asserted below is cross-checked by it.  That
// is a second implementation, but it is not the code under test and it is not
// used at run time -- it is how the hand arithmetic was confirmed rather than
// guessed.

import flock;
import fx;

// -- the tally ---------------------------------------------------------------

let PASSED = 0;
let FAILED = 0;
let GROUP = "";

// Every puts() below ends in an explicit \n.  Y's puts() does NOT add one --
// it writes the string it is given -- so a literal without a trailing newline
// runs into the next line.  The first version of this file had no \n anywhere
// and printed 170 assertions as a single enormous line, which is exactly the
// kind of thing that hides a failure in the middle.
//
// say(name, ok, detail) -- one assertion's line.  The detail is BUILT BY THE
// CALLER and must include the observed value, so a failure report says what was
// seen rather than only that something differed.
def say(name: str, ok: bool, detail: str) {
    if (ok) {
        PASSED = PASSED + 1;
        puts("  ok   " + name + "\n");
    } else {
        FAILED = FAILED + 1;
        puts("  FAIL " + name + "  [" + detail + "]\n")
    }
};

// eq(name, got, want) -- the workhorse.  The detail always carries both
// values, so no failure is ever "expected X".
def eq(name: str, got: long, want: long) {
    say(name, got == want, "got " + tostring(got) + ", want " + tostring(want))
};

// ne(name, got, unwanted) -- for "this must NOT be", where a failure has to
// name the offending value.
def ne(name: str, got: long, unwanted: long) {
    say(name, got != unwanted, "got " + tostring(got) + ", must not be "
         + tostring(unwanted))
};

// nonzero(name, v) -> bool, and it RECORDS an assertion.  This is rule 1 above:
// the guard is an assertion in its own right, so "the observed value was
// absent" is a named failure rather than a silent zero that then compares
// equal.
def nonzero(name: str, v: long) -> bool {
    let ok = v != 0;
    say(name, ok, "got " + tostring(v));
    ok
};

// present(name, v) -> bool -- "there was something to look at": a count, or a
// non-empty accumulator.  Used where the value can legitimately be zero but the
// SET must not be empty.
def present(name: str, v: long) -> bool {
    let ok = v > 0;
    say(name, ok, "got " + tostring(v));
    ok
};

def head(t: str) {
    puts("\n");
    puts(t + "\n");
    puts("  ---------------------------------------------------------------\n")
};

// -- 1. the fixed-point primitives ------------------------------------------
//
// flock.qdiv is the function the Q16-ratio trap is about: `a / b` on two
// fixed-point values is their RATIO, not a scaled quotient, so 2.0 / 1.0 would
// come out as 2 instead of 131072.  These are the constants from the manual,
// and the bare division is asserted right beside them to make the difference
// visible in the output.

def t_fixed() {
    head("1. the Q16 primitives (qmul, qdiv, q32) -- and the ratio trap");
    // qdiv(a, b) = a*65536/b.
    eq("qdiv(2.0, 1.0) == 131072, the ratio of the same pair is 2",
       flock.qdiv(131072, 65536), 131072);
    eq("  and the bare / really is the ratio", 131072 / 65536, 2);
    eq("qdiv(3.0, 2.0) == 1.5", flock.qdiv(196608, 131072), 98304);
    eq("qdiv(1.0, 3.0) truncates toward zero", flock.qdiv(65536, 196608), 21845);
    eq("qdiv(-1.0, 3.0) truncates toward zero, not down",
       flock.qdiv(0 - 65536, 196608), 0 - 21845);
    eq("qdiv(-3.0, 2.0) is exact and negative", flock.qdiv(0 - 196608, 131072),
       0 - 98304);
    eq("qdiv(a, 0) returns 0 rather than trapping", flock.qdiv(65536, 0), 0);
    // qmul(a, b) = a*b/65536.
    eq("qmul(1.5, 2.0) == 3.0", flock.qmul(98304, 131072), 196608);
    eq("qmul(-2.0, 1.5) == -3.0", flock.qmul(0 - 131072, 98304), 0 - 196608);
    eq("qmul(0, anything) == 0", flock.qmul(0, 65536), 0);
    // qmul and qdiv are inverses on an exact quotient: qdiv(3.0, 2.0) is
    // exactly 1.5 in Q16, and multiplying that back by 2.0 gives exactly 3.0.
    // This is the property that makes a speed limit mean what it says -- and
    // it only closes because BOTH helpers carry their 65536.
    let inv = flock.qmul(flock.qdiv(196608, 131072), 131072);
    eq("qmul(qdiv(3.0, 2.0), 2.0) == 3.0", inv, 196608);
    // The bare `/` would not close: it answers 1 for 3.0/2.0 in Q16, and
    // multiplying that back by 2.0 gives 1, not 3.0.
    let naive = flock.qmul(196608 / 131072, 131072);
    ne("  while the bare / does not close", naive, 196608);
    // q32(a, b) = a*2^32/b, the scale the squared distance lives in.
    eq("q32(-3.0, 25.0) truncates toward zero", flock.q32(0 - 196608, 107374182400),
       0 - 7864);
    eq("q32(4.0, 25.0)", flock.q32(262144, 107374182400), 10485);
    eq("q32(a, 0) returns 0", flock.q32(65536, 0), 0)
};

// -- 2. the root -------------------------------------------------------------

// t_sqrt() -- flock.isqrt against fx.isqrt, which is the toolkit's digit
// recurrence and was tested independently of this example (fx_test.y).
//
// The two questions here are "does it agree with the library" and "is the
// library itself being asked about a NON-TRIVIAL set of inputs".  The second
// is the one that stops the first from passing vacuously: a spread of values
// that happens to be all perfect squares, or all zero, would agree for
// uninteresting reasons.  So the test asserts that its own input set contains
// both perfect squares and values that are NOT, and counts how many of each it
// actually compared -- with the count coming from THIS file's own arithmetic,
// not from the function under test.

def t_sqrt() {
    head("2. the fixed-point root: flock.isqrt vs fx.isqrt, and vs exact");
    let squares = 0;
    let nonsquares = 0;
    let bad = 0;
    let first_bad = 0;
    let compared = 0;

    // A spread of magnitudes up to 2^47, which is the largest square the
    // neighbour loop can form in Q16 inside a 256-unit world.
    let u = 0;
    let i = 0;
    while (i < 400) {
        // A deterministic spread: every 7th perfect square up to 400^2, and
        // between them a value one below it (never a square), so both kinds are
        // certainly present.
        u = (i * 7 + 3) * (i * 7 + 3);
        let mine = flock.isqrt(u);
        let theirs = fx.isqrt(u);
        if (mine != theirs) {
            bad = bad + 1;
            if (bad == 1) { first_bad = u; }
        };
        let m2 = flock.isqrt(u - 1);
        let t2 = fx.isqrt(u - 1);
        if (m2 != t2) { bad = bad + 1; };
        compared = compared + 2;
        i = i + 1
    };
    // And the exactness claim, from OUTSIDE: for k^2 the answer must be k, and
    // for k^2 - 1 it must be k - 1.  Those are arithmetic facts about
    // consecutive integers, not something the root decides.
    i = 1;
    while (i <= 300) {
        let k = i;
        let sq = k * k;
        if (flock.isqrt(sq) != k) { bad = bad + 1; };
        if (k > 1 && flock.isqrt(sq - 1) != k - 1) { bad = bad + 1; };
        if (flock.isqrt(sq) == k) { squares = squares + 1; };
        if (k > 1 && flock.isqrt(sq - 1) == k - 1) { nonsquares = nonsquares + 1; };
        compared = compared + 2;
        i = i + 1
    };
    // The hand table, including the two neighbours of every small root, so a
    // root that returned floor(sqrt(u)) - 1 or +1 would be caught.
    // Both neighbours of every root from 0 to 10, so a root that returned
    // floor(sqrt(u)) - 1 or +1, or that rounded to nearest, both fail.  The
    // `want` column is arithmetic about consecutive integers, not anything the
    // root decides: 24^2 = 576 > 576 - 1, and 25^2 = 625 > 576.
    // Both neighbours of every root from 0 to 10, so a root that returned
    // floor(sqrt(u)) - 1 or +1, or that rounded to nearest, both fail.  The
    // `want` column is arithmetic about consecutive integers, not anything the
    // root decides: 24^2 = 576 and 576 - 1 = 575 < 576, so the root of 575 is
    // at most 24; and 25^2 = 625 > 575, so at least 24.
    let tbl = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 15, 16, 17, 24, 25, 26,
               35, 36, 37, 48, 49, 50, 99, 100, 101, 1000000, 1000001];
    let want = [0, 1, 1, 1, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3, 4, 4, 4, 5, 5, 5, 6,
                6, 6, 7, 7, 9, 10, 10, 1000, 1000];
    let t_bad = 0;
    i = 0;
    while (i < len(tbl)) {
        if (flock.isqrt(tbl[i]) != want[i]) { t_bad = t_bad + 1; };
        compared = compared + 1;
        i = i + 1
    };

    // RULE 1: assert the input set was non-trivial BEFORE comparing against it.
    present("the exact-square inputs really were there", squares);
    present("the non-square inputs really were there", nonsquares);
    say("the hand table has the length it claims", len(tbl) == len(want),
        "table " + tostring(len(tbl)) + ", expected " + tostring(len(want)));
    eq("isqrt agrees with fx.isqrt and with exactness on every input",
       bad + t_bad, 0);
    if (bad + t_bad > 0) {
        puts("       (first disagreement at u = " + tostring(first_bad) + ")\n")
    };
    nonzero("the spread really covered two orders of magnitude", compared);

    // The largest root the loop can be asked for, and the identity that makes
    // dist() exact on a 3-4-5 triangle.
    eq("isqrt(2^47)", flock.isqrt(140737488355328), 11863283);
    eq("dist of a 3-4-5 triangle is exactly 5", flock.dist(196608, 262144), 327680);
    eq("dist(0,0) is 0, not a trap", flock.dist(0, 0), 0);
    eq("dist of a 1-1 diagonal is the root of 2",
       flock.dist(65536, 65536), 92681)
};

// -- 3. a hand-computed two-bird case ---------------------------------------

// t_hand() -- the strongest assertion in the file, because every number below
// was derived by hand and confirmed by oracle.py, and it pins the WHOLE chain:
// the squared distance, the 1/d^2 separation weight, the average over
// neighbours, the normalization to max speed, the force clamp, the integration
// and the position.
//
// The world: two boids at (10,10) and (13,14) -- exactly 5 units apart on a
// 3-4-5 triangle -- both perfectly still, separation only, everything else
// wide open.
//
//   dx = 3 units = 196608 in Q16,  dy = 4 units = 262144
//   d2 = dx^2 + dy^2 = (9 + 16) * 2^32 = 25 * 2^32 = 107374182400   (Q32)
//   the separation term is -dx/d2 in real units, which in Q16 is
//       -dx_q16 * 2^32 / d2_raw = -196608/25 = -7864.32  ->  -7864
//       -dy_q16 * 2^32 / d2_raw = -262144/25 = -10485.76 -> -10485
//   both are the only neighbour, so averaging leaves them
//   normalize: |(-7864,-10485)| = 13106, so the unit vector is
//       -7864*65536/13106 = -39325   (truncating toward zero)
//       -10485*65536/13106 = -52429
//   the desired velocity is that times maxs = 8.0 = 524288, so
//       -39325*4 = -157300 ... but steer() does it in ONE rounding:
//       (-7864*524288)/13106 = -314588   and   (-10485*524288)/13106 = -419438
//   the force is that minus v = (0,0), its length 524303, and max_force is
//       128.0, so the force clamp does not bite
//   one step: v = (-314588, -419438); the length 524303 is OVER maxs 524288,
//       so the velocity clamp scales it down by 524288/524303
//
// The clamp firing here is not incidental: it is the assertion that the clamp
// FIRES, and the hand value for the clamped pair is in the table below.

def t_hand() {
    head("3. two birds, 5 units apart on a 3-4-5: the whole chain by hand");
    flock.set_mask(flock.M_SEP);
    let s = flock.blank(32, 32, 2);
    // A view radius that includes the other bird, a separation radius that does
    // too, weights with only separation live, and limits wide open.
    flock.set_view(s, 6);
    flock.set_sep(s, 6);
    flock.set_weights(s, 65536, 0, 0);
    flock.set_limits(s, 524288, 8388608, 65536);
    eq("the flock took the parameters asked for (maxs)", s.maxs, 524288);
    eq("  and maxf", s.maxf, 8388608);
    eq("  and dt", s.dt, 65536);
    nonzero("the view radius really is 6 units (squared, Q32)", s.vr2);
    eq("  view radius squared == 36 * 2^32", s.vr2, 36 * 4294967296);

    // place() must have put them exactly where they were asked to go.
    flock.place(s, 0, 10, 10, 0, 0);
    flock.place(s, 1, 13, 14, 0, 0);
    eq("bird 0 x is 10 units in Q16", s.px[0], 655360);
    eq("bird 1 x is 13 units in Q16", s.px[1], 851968);
    eq("bird 1 y is 14 units in Q16", s.py[1], 917504);
    eq("bird 0 starts still", flock.speed(s, 0), 0);

    // The accumulator, read out of the production code.
    flock.accumulate(s, 0);
    eq("bird 0 sees exactly one neighbour", flock.acc_nali(), 1);
    eq("  inside the separation radius too", flock.acc_nsep(), 1);
    eq("the 1/d^2 separation accumulator x == -7864", flock.acc_sep_x(), 0 - 7864);
    eq("  and y == -10485", flock.acc_sep_y(), 0 - 10485);
    // The raw neighbour offsets the other two rules would have used: they are
    // the offset itself, NOT the 1/d^2 version, which is the difference between
    // the rules and is worth pinning.
    eq("the cohesion accumulator x is the raw offset, 196608",
       flock.acc_coh_x(), 196608);
    eq("  and y, 262144", flock.acc_coh_y(), 262144);
    eq("the alignment accumulator is the neighbour's velocity, 0 (still)",
       flock.acc_ali_x(), 0);
    // The reverse: from bird 1's side the separation must POINT THE OTHER WAY.
    flock.accumulate(s, 1);
    eq("bird 1's separation accumulator x == +7864", flock.acc_sep_x(), 7864);
    eq("  and y == +10485", flock.acc_sep_y(), 10485);

    // rule_sum reduces it to a force.  max_force is 128.0, so the sum clamp
    // cannot bite and the value is steer()'s output, weighted by 1.0.
    flock.accumulate(s, 0);
    flock.rule_sum(s);
    eq("the steering force x == -314588", flock.acc_fix(), 0 - 314588);
    eq("  and y == -419438", flock.acc_fiy(), 0 - 419438);

    // One step, and the velocity clamp.  The pre-clamp length is 524303 and
    // maxs is 524288, so the clamp scales the pair by 524288/524303:
    //   -314588*524288/524303 = -314578   -419438*524288/524303 = -419426
    flock.step(s);
    eq("after one step bird 0's vx == -314578 (clamped)", s.vx[0], 0 - 314578);
    eq("  and vy == -419426", s.vy[0], 0 - 419426);
    eq("the clamp bit on this step", s.sat, 1);
    eq("  on BOTH boids -- they are pushed apart symmetrically", s.over, 2);
    eq("  and the largest raw speed was 524303", s.vraw, 524303);
    // The position moved by exactly the clamped velocity (dt = 1.0).
    eq("bird 0's x moved by the velocity", s.px[0], 655360 - 314578);
    eq("  and its y", s.py[0], 655360 - 419426);
    // And bird 1 went the other way -- mirrored, because its accumulator is the
    // mirror image -- so the pair SEPARATED, which is what separation means.
    // Checked as a distance rather than as two signs, so a rule that pushed both
    // the same way could not satisfy it.
    //
    // The RAW separation, before the torus shortens it.  Each boid moved
    // |v| = 524288 = 8.0 units along the 3-4-5 line, so the gap grew by
    // 2 * 8.0.  By hand, in Q16:
    //   dx = (13 - 10) * 65536 + 2 * 314578 = 196608 + 629156 = 825764
    //   dy = (14 - 10) * 65536 + 2 * 419426 = 262144 + 838852 = 1100996
    //   isqrt(825764^2 + 1100996^2) = 1376255, i.e. 20.99998 units.  The
    // shortfall from 21.0 is the clamp, which scaled 524303 down to 524288 and
    // so shortened each bird's step by 15 Q16 units.
    let raw_dx = s.px[1] - s.px[0];
    let raw_dy = s.py[1] - s.py[0];
    eq("the raw x separation is 12.59998 units", raw_dx, 825764);
    eq("  and the raw y separation is 16.79998", raw_dy, 1100996);
    eq("  so the pair is 20.99998 apart unwrapped",
       flock.dist(raw_dx, raw_dy), 1376255);
    // 21 units is the ceiling: each boid moves at most maxs = 8.0 in a step, so
    // the gap can grow by at most 16.0.  Landing just under it says the clamp
    // was the only thing keeping them there.
    let ceiling = flock.dist(raw_dx, raw_dy);
    say("  just under the 21.0 ceiling the clamp implies",
        ceiling < 21 * 65536 && ceiling > 20 * 65536,
        "now " + tostring(ceiling) + ", ceiling " + tostring(21 * 65536));
    // AND the torus shortens it, because 21 units apart on a 32-unit world is
    // 11 the other way.  This is the wrap being RIGHT rather than being absent:
    // without wrap_delta the answer would be the 20.99998 above.
    let dx = flock.wrap_delta(s.px[1] - s.px[0], s.w);
    let dy = flock.wrap_delta(s.py[1] - s.py[0], s.h);
    eq("  and the wrap shortens that to 11.00002 (32 - 21)", dy,
       0 - 996156);
    let now = flock.dist(dx, dy);
    eq("  so the distance the flock sees is 11.00002 units", now, 1293913);
    nonzero("  and it is still much bigger than the 5.0 they started at",
            now - 327680);
};

// -- 4. each rule's sign, in isolation --------------------------------------

// t_signs() -- the three rules tested ONE AT A TIME, which is what the module
// mask is for.  Each case is a hand-built world, and each asserts the SIGN of
// the effect plus a magnitude relationship, so a rule that was negated, scaled
// wrong, or swapped for another rule all fail.
//
// The worlds are three birds in a line, which is the configuration the brief
// asks for and the one that separates the rules cleanly:
//
//   SEPARATION  a pair 5 apart must END UP FARTHER apart, and a line must
//               SPREAD.  Cohesion would do the opposite, so the assertion is
//               directional, not just "moved".
//   ALIGNMENT   two birds with opposed velocities must END UP agreeing: the
//               relative speed must shrink.  Nothing else shrinks a velocity
//               difference.
//   COHESION    a lone pair must ATTRACT: the distance must shrink.  Separation
//               would grow it.

def t_signs() {
    head("4. the three rules, one at a time: a lone pair, and three in a line");

    // ---- separation: the distance between a pair must GROW -----------------
    flock.set_mask(flock.M_SEP);
    let s = flock.blank(40, 20, 2);
    flock.set_view(s, 8);
    flock.set_sep(s, 8);
    flock.set_weights(s, 65536, 0, 0);
    flock.set_limits(s, 131072, 524288, 65536);
    flock.place(s, 0, 10, 10, 0, 0);
    flock.place(s, 1, 13, 14, 0, 0);
    let d0 = flock.dist(flock.wrap_delta(s.px[1] - s.px[0], s.w),
                        flock.wrap_delta(s.py[1] - s.py[0], s.h));
    eq("the pair starts 5 units apart", d0, 327680);
    let g = 0;
    while (g < 8) {
        flock.step(s);
        g = g + 1
    };
    let d1 = flock.dist(flock.wrap_delta(s.px[1] - s.px[0], s.w),
                        flock.wrap_delta(s.py[1] - s.py[0], s.h));
    present("separation: the pair is still findable after 8 steps", d1);
    say("separation: a lone pair REPELS (5.0 -> further apart)",
        d1 > d0, "was " + tostring(d0) + ", now " + tostring(d1));
    // The stronger claim: the left one went left and the right one went right.
    say("separation: bird 0 moved left", s.px[0] < 655360,
        "px " + tostring(s.px[0]) + " vs 655360");
    say("separation: bird 1 moved right", s.px[1] > 851968,
        "px " + tostring(s.px[1]) + " vs 851968");
    say("separation: bird 0 moved down", s.py[0] > 655360,
        "py " + tostring(s.py[0]));
    say("separation: bird 1 moved up", s.py[1] < 917504,
        "py " + tostring(s.py[1]));

    // ---- cohesion: the distance must SHRINK -------------------------------
    flock.set_mask(flock.M_COH);
    let c = flock.blank(40, 20, 2);
    flock.set_view(c, 8);
    flock.set_sep(c, 8);
    flock.set_weights(c, 0, 0, 65536);
    flock.set_limits(c, 131072, 524288, 65536);
    flock.place(c, 0, 10, 10, 0, 0);
    flock.place(c, 1, 13, 14, 0, 0);
    let e0 = flock.dist(flock.wrap_delta(c.px[1] - c.px[0], c.w),
                        flock.wrap_delta(c.py[1] - c.py[0], c.h));
    eq("the attracting pair also starts 5 units apart", e0, 327680);
    // Cohesion normalizes the OFFSET to maxs, so the pull is toward the other
    // bird at full speed from the first step -- unlike separation, whose 1/d^2
    // weight shrinks as they part.  Two steps is enough to see the sign.
    flock.step(c);
    flock.step(c);
    let e1 = flock.dist(flock.wrap_delta(c.px[1] - c.px[0], c.w),
                        flock.wrap_delta(c.py[1] - c.py[0], c.h));
    present("cohesion: the pair is still findable", e1);
    say("cohesion: a lone pair ATTRACTS (5.0 -> closer)",
        e1 < e0, "was " + tostring(e0) + ", now " + tostring(e1));
    // Bird 1 is at (13,14) and bird 0 at (10,10), so "toward bird 1" is +x
    // AND +y: the screen's y grows DOWN, so 14 is below 10.
    say("cohesion: bird 0 moved toward bird 1 (right and down)",
        c.px[0] > 655360 && c.py[0] > 655360,
        "px " + tostring(c.px[0]) + " (was 655360), py " + tostring(c.py[0])
        + " (was 655360)");
    say("cohesion: bird 1 moved toward bird 0 (left and up)",
        c.px[1] < 851968 && c.py[1] < 917504,
        "px " + tostring(c.px[1]) + " (was 851968), py " + tostring(c.py[1])
        + " (was 917504)");

    // ---- alignment: the relative velocity must SHRINK ---------------------
    flock.set_mask(flock.M_ALI);
    let a = flock.blank(40, 20, 2);
    flock.set_view(a, 8);
    flock.set_sep(a, 8);
    flock.set_weights(a, 0, 65536, 0);
    flock.set_limits(a, 131072, 524288, 65536);
    // Head-on and dead even: bird 0 east at 1.0, bird 1 west at 1.0, 4 units
    // apart (INSIDE the 8-unit view radius -- the first version put them 10
    // apart, which is outside it, and then every alignment assertion below was
    // being made about two boids that could not see each other).
    flock.place(a, 0, 10, 10, 65536, 0);
    flock.place(a, 1, 14, 10, 0 - 65536, 0);
    let r0 = flock.dist(a.vx[0] - a.vx[1], a.vy[0] - a.vy[1]);
    eq("the opposed pair starts with a relative speed of 2.0", r0, 131072);
    // The accumulator holds the SUM of the neighbours' velocities, and with one
    // neighbour the mean is that one velocity -- NOT the mean of the pair.  So
    // bird 0's alignment target is bird 1's heading, west at 1.0.
    flock.accumulate(a, 0);
    eq("alignment sees one neighbour", flock.acc_nali(), 1);
    eq("  and the target is the neighbour's velocity, -1.0", flock.acc_ali_x(),
       0 - 65536);
    // steer(): l = 65536, so the desired is exactly west at maxs = 2.0 units,
    // the force is that minus bird 0's own +1.0 = -3.0, and |force| = 3.0 is
    // under the 8.0 max force, so it is NOT clamped.  One step therefore takes
    // bird 0 to -3.0 + 1.0 = -2.0 -- REVERSED, and exactly at the cap.
    flock.step(a);
    eq("a dead-even opposed pair OVERSHOOTS: bird 0 is reversed", a.vx[0],
       0 - 131072);
    eq("  and bird 1 with it", a.vx[1], 131072);
    let r1 = flock.dist(a.vx[0] - a.vx[1], a.vy[0] - a.vy[1]);
    eq("  so the relative speed DOUBLED, to 4.0", r1, 262144);
    // That is the real behaviour of undamped alignment on an exactly opposed
    // pair, and asserting it is worth more than asserting "it shrank": the
    // overshoot is the thing a wrong sign or a missing clamp would hide.
    nonzero("  and the speed did change, so this is not a stationary pair", r1 - r0);

    // Now the case that must converge.  Bird 0 at +1.0, bird 1 at +0.25, 4
    // apart.  Both point the same way, so both are pulled up to maxs:
    //   bird 0's target is +0.25 normalized to maxs = +2.0; force = 2.0 - 1.0
    //          = +1.0; v = 1.0 + 1.0 = 2.0 = maxs exactly
    //   bird 1's target is +1.0 normalized to maxs = +2.0; force = 2.0 - 0.25
    //          = +1.75; v = 0.25 + 1.75 = 2.0 = maxs exactly
    // so after ONE step they hold IDENTICAL velocities and the relative speed
    // is zero -- an exact number, not a bound.
    flock.place(a, 0, 10, 10, 65536, 0);
    flock.place(a, 1, 14, 10, 16384, 0);
    let u0 = flock.dist(a.vx[0] - a.vx[1], a.vy[0] - a.vy[1]);
    eq("the uneven pair starts 0.75 apart in velocity", u0, 49152);
    flock.step(a);
    eq("after one step bird 0 is at exactly maxs", a.vx[0], 131072);
    eq("  and so is bird 1", a.vx[1], 131072);
    let u1 = flock.dist(a.vx[0] - a.vx[1], a.vy[0] - a.vy[1]);
    eq("  so their relative speed is EXACTLY zero", u1, 0);
    nonzero("  and there was a relative speed to remove", u0);
    ne("  and it is not the same as where it started", u1, u0);
    // A second step changes nothing, because they already agree.
    flock.step(a);
    eq("  and a second step changes nothing", flock.dist(a.vx[0] - a.vx[1],
       a.vy[0] - a.vy[1]), 0);

    // ---- three in a line, cohesion: the order must RE-ORDER ---------------
    //
    // Three birds at x = 4, 6, 8, all still, cohesion only.  The middle one is
    // exactly AT the centre of mass of its two neighbours, so its cohesion
    // accumulator is EXACTLY zero -- a hand-computable zero -- and the outer
    // two accelerate toward it at full speed.  After a few steps they have
    // passed through the middle one, so the bird that started leftmost is no
    // longer leftmost.
    flock.set_mask(flock.M_COH);
    let l = flock.blank(40, 20, 3);
    flock.set_view(l, 8);
    flock.set_sep(l, 8);
    flock.set_weights(l, 0, 0, 65536);
    flock.set_limits(l, 32768, 524288, 65536);
    flock.place(l, 0, 4, 10, 0, 0);
    flock.place(l, 1, 6, 10, 0, 0);
    flock.place(l, 2, 8, 10, 0, 0);
    flock.accumulate(l, 1);
    eq("the middle bird's cohesion accumulator x is EXACTLY 0",
       flock.acc_coh_x(), 0);
    // ACC_CO* holds the SUM of the offsets, not the mean: rule_sum() divides by
    // ACC_NALI once per boid rather than once per pair.  Bird 0 at x=4 has
    // neighbours at 6 and 8, so its offsets are +2 and +4 and the raw sum is
    // +6 units = 393216, while the steering target -- the mean -- is +3 units.
    flock.accumulate(l, 0);
    eq("the left bird's cohesion SUM is +6 units (+2 and +4)", flock.acc_coh_x(),
       393216);
    flock.accumulate(l, 2);
    eq("the right bird's cohesion SUM is -6 units (-4 and -2)",
       flock.acc_coh_x(), 0 - 393216);
    eq("  (the mean over its two neighbours, the steering target: (4-8 + 6-8)/2 = -3)",
       flock.acc_coh_x() / flock.acc_nali() / 65536, 0 - 3);
    // Run it and watch the order change.
    let before = order_of(l);
    eq("initially the birds are in order 0, 1, 2 left to right", before, 123);
    let k = 0;
    let swapped = false;
    while (k < 40 && !swapped) {
        flock.step(l);
        k = k + 1;
        if (order_of(l) != 123) { swapped = true; }
    };
    present("the line was still findable after the run", order_of(l));
    say("cohesion: three in a line RE-ORDER", swapped,
        "order after " + tostring(k) + " steps is "
        + digits_of(order_of(l)) + ", started 123");
    ne("  and it did not stay 0,1,2", order_of(l), 123);

    // ---- three in a line, separation: the line must SPREAD ----------------
    //
    // The mirror image of the case above, and it is the one the brief asks for
    // by name.  Separation is 1/d^2 weighted, so it is not symmetric: the
    // nearest neighbour dominates.  For x = 4, 5, 8 the accumulators are
    // exactly
    //   bird 0: -65536/1 - 4*65536/16 = -65536 - 16384 = -81920
    //   bird 1: +65536/1 - 3*65536/9  = +65536 - 21845 = +43691
    //   bird 2: +4*65536/16 + 3*65536/9 = +16384 + 21845 = +38229
    // and all three are hand-computable, which is what makes this a test rather
    // than a snapshot.
    flock.set_mask(flock.M_SEP);
    let m = flock.blank(40, 20, 3);
    flock.set_view(m, 8);
    flock.set_sep(m, 8);
    flock.set_weights(m, 65536, 0, 0);
    flock.set_limits(m, 32768, 524288, 65536);
    flock.place(m, 0, 4, 10, 0, 0);
    flock.place(m, 1, 5, 10, 0, 0);
    flock.place(m, 2, 8, 10, 0, 0);
    flock.accumulate(m, 0);
    eq("bird 0's separation accumulator == -81920", flock.acc_sep_x(), 0 - 81920);
    flock.accumulate(m, 1);
    eq("bird 1's separation accumulator == +43691", flock.acc_sep_x(), 43691);
    flock.accumulate(m, 2);
    eq("bird 2's separation accumulator == +38229", flock.acc_sep_x(), 38229);
    // A line that stays a line is a flock that is not flocking.
    let sp0 = flock.span_x(m);
    let k2 = 0;
    while (k2 < 12) {
        flock.step(m);
        k2 = k2 + 1
    };
    let sp1 = flock.span_x(m);
    present("separation: the line had a span to grow", sp0);
    say("separation: three in a line SPREAD", sp1 > sp0,
        "span " + tostring(sp0) + " -> " + tostring(sp1));

    // ---- the three rules together are not the sum of their signs ----------
    //
    // The flock that is actually shipped: all three live.  Asserted as an
    // ORDERING that only holds with all three, so it fails if one is dropped:
    // with cohesion alone the flock collapses to a point; with separation alone
    // it disperses; with all three it settles into a band.
    flock.set_mask(flock.M_ALL);
    let f = flock.blank(60, 30, 40);
    flock.set_view(f, 9);
    flock.set_sep(f, 4);
    flock.set_weights(f, 98304, 65536, 58982);
    flock.set_limits(f, 91750, 183500, 65536);
    flock.seed_flock(f, 7, f.maxs / 2, f.maxs);
    // mean_order() reads s.pairs, which is what the LAST step counted, so it is
    // 0 until one has run.  Stepping first is the honest reading; asking for it
    // on a fresh flock would assert that a simulation which has simulated
    // nothing has neighbours, which is true and useless.
    flock.step(f);
    let ord0 = flock.mean_order(f);
    present("the flock has neighbours after one step", ord0);
    let g2 = 1;
    while (g2 < 60) {
        flock.step(f);
        g2 = g2 + 1
    };
    let ord1 = flock.mean_order(f);
    present("  and still has them after 60 steps", ord1);
    // A real flock: everybody sees somebody, and nobody is isolated.
    say("all three rules: the flock stays a flock (ord stays >= 1.00)",
        ord1 >= 100, "ord " + tostring(ord1) + " hundredths");
    say("all three rules: every bird is inside the world", flock.in_bounds(f),
        "a position fell outside the world");
};

// order_of(s) -> the three birds' identities read left to right as a 3-digit
// number: the leftmost bird is the hundreds digit.  So 123 is "bird 0, then
// bird 1, then bird 2", and anything else is a re-order.  Digits come from
// the ids, not from a comparison of positions, so this cannot be fooled by a
// wrap.
def order_of(s: flock.Flock) -> long {
    let p0 = s.px[0];
    let p1 = s.px[1];
    let p2 = s.px[2];
    let acc = 0;
    if (p0 < p1 && p1 < p2) { acc = 123; } else
        if (p0 < p2 && p2 < p1) { acc = 132; } else
        if (p1 < p0 && p0 < p2) { acc = 213; } else
        if (p1 < p2 && p2 < p0) { acc = 231; } else
        if (p2 < p0 && p0 < p1) { acc = 312; } else
        { acc = 321; };
    acc
};

def digits_of(v: long) -> str {
    let d = v;
    if (d == 123) { return "123" };
    if (d == 132) { return "132" };
    if (d == 213) { return "213" };
    if (d == 231) { return "231" };
    if (d == 312) { return "312" };
    "321"
};

// -- 5. neighbour counts from geometry --------------------------------------

// t_counts() -- the pair loop's neighbour count, against the number of
// POINTS INSIDE A CIRCLE, worked out here from the coordinates rather than
// read out of the simulator.
//
// The setup is a probe at (20,20) and birds at KNOWN distances.  With a view
// radius of 7 and a separation radius of 3:
//
//   distance 1, 2  -> inside both      (2 birds)
//   distance 3     -> exactly ON the separation radius, so OUTSIDE it
//                      (the test is strict: d2 < r2)
//   distance 4, 6  -> inside the view radius only
//   distance 7     -> exactly ON the view radius, so OUTSIDE it
//   distance 8, 12 -> outside both
//
// Those counts are arithmetic facts about the setup, and the boundaries at 3
// and 7 are the convention under test.  A loop that used `<=` instead of `<`, or
// that forgot to wrap, would get both boundaries wrong.

def t_counts() {
    head("5. neighbour counts from geometry (a probe and known distances)");
    flock.set_mask(flock.M_ALL);
    let s = flock.blank(40, 40, 6);
    flock.set_view(s, 7);
    flock.set_sep(s, 3);
    flock.place(s, 0, 20, 20, 0, 0);          // the probe, index 0
    flock.place(s, 1, 21, 20, 0, 0);          // distance 1
    flock.place(s, 2, 18, 20, 0, 0);          // distance 2
    flock.place(s, 3, 17, 20, 0, 0);          // distance 3 -- on the sep edge
    flock.place(s, 4, 16, 20, 0, 0);          // distance 4
    flock.place(s, 5, 20, 26, 0, 0);          // distance 6
    flock.accumulate(s, 0);
    // In view: distances 1, 2, 3, 4, 6.  Out: nothing else is placed.
    eq("the probe sees 5 birds inside the view radius", flock.acc_nali(), 5);
    // In the separation radius: 1 and 2 only.  Distance 3 is ON the boundary.
    eq("  of which 2 are inside the separation radius", flock.acc_nsep(), 2);
    // The offsets sum: +1 - 2 - 3 - 4 + 0(y) and y: 0 + 0 + 0 + 0 + 6.
    eq("  the cohesion offset sum x == -8 units", flock.acc_coh_x(), 0 - 524288);
    eq("  and y == +6 units", flock.acc_coh_y(), 393216);

    // The strict boundary, isolated so a reader can see it is the RULE and not
    // an accident of these coordinates: a bird at exactly the radius is out,
    // one at radius-1 is in.
    flock.set_view(s, 7);
    flock.set_sep(s, 3);
    let b = flock.blank(40, 40, 2);
    flock.set_view(b, 7);
    flock.set_sep(b, 3);
    flock.place(b, 0, 20, 20, 0, 0);
    flock.place(b, 1, 27, 20, 0, 0);          // exactly 7 away
    flock.accumulate(b, 0);
    eq("a bird EXACTLY at the view radius is outside it", flock.acc_nali(), 0);
    flock.place(b, 1, 26, 20, 0, 0);          // 6 away
    flock.accumulate(b, 0);
    eq("a bird one unit inside the view radius is inside it", flock.acc_nali(), 1);
    flock.place(b, 1, 23, 20, 0, 0);          // exactly 3 away
    flock.accumulate(b, 0);
    eq("a bird exactly at the separation radius is outside THAT", flock.acc_nsep(), 0);
    flock.place(b, 1, 22, 20, 0, 0);          // 2 away
    flock.accumulate(b, 0);
    eq("a bird inside the separation radius counts in both", flock.acc_nsep(), 1);
    eq("  and in the view radius too", flock.acc_nali(), 1);

    // The torus: a bird just the other way round must still be seen, and at the
    // SHORT way round, not the long one.
    let w = flock.blank(40, 40, 2);
    flock.set_view(w, 5);
    flock.set_sep(w, 5);
    flock.place(w, 0, 1, 20, 0, 0);
    flock.place(w, 1, 39, 20, 0, 0);          // 38 the long way, 2 the short
    flock.accumulate(w, 0);
    eq("across the wrap the pair is 2 units apart, so they see each other",
       flock.acc_nali(), 1);
    eq("  and the offset is -2 units (the short way)", flock.acc_coh_x(), 0 - 131072);

    // The pair count is counted per BOID, so a flock of n sees at most
    // n*(n-1)/2 twice that.  The expected maximum comes from n, not from the
    // simulator.
    let big = flock.blank(60, 60, 4);
    flock.set_view(big, 60);                  // everything in view
    flock.set_sep(big, 60);
    flock.place(big, 0, 10, 10, 0, 0);
    flock.place(big, 1, 20, 20, 0, 0);
    flock.place(big, 2, 30, 30, 0, 0);
    flock.place(big, 3, 40, 40, 0, 0);
    flock.step(big);
    // 4 boids, all mutually in view: 4*3 = 12 ordered pairs.  The expected
    // value is n*(n-1), which is arithmetic.
    eq("with everything in view, the pair count is n*(n-1) = 12", big.pairs, 12);
    flock.step(big);
    eq("  and it stays 12 frame to frame", big.pairs, 12)
};

// -- 6. the velocity clamp ---------------------------------------------------

// t_clamp() -- the speed limit HOLDS, and -- the part that stops this being a
// vacuous truth -- the limit is actually REACHED, by a seed that drives it
// there.
//
// "No bird ever exceeded max speed" is true of a flock that never got near the
// limit, so asserting it alone would pass for a program that computes nothing.
// flock.over counts the boids the clamp caught and flock.vraw is the largest
// pre-clamp length: the assertion is that BOTH are non-zero and that no
// post-clamp length ever exceeded the cap.

def t_clamp() {
    head("6. the velocity clamp: reached under a driving seed, and never passed");
    let seed = 1;
    let frames = 400;
    let s = flock.blank(60, 40, 120);
    flock.set_view(s, 9);
    flock.set_sep(s, 4);
    flock.set_weights(s, 98304, 65536, 58982);
    // A SMALL cap with a large force: the force is big enough to overshoot the
    // speed limit, which is what makes the clamp a live path rather than dead
    // code.  maxs = 0.35 units/step, maxf = 16x that.
    flock.set_limits(s, 22938, 367008, 65536);
    flock.seed_flock(s, seed, s.maxs / 2, s.maxs);
    eq("the driving seed produces 120 boids", s.n, 120);

    let worst_over = 0;
    let escaped = 0;
    let g = 0;
    while (g < frames) {
        flock.step(s);
        g = g + 1;
        // Every frame: the largest post-clamp speed must not exceed the cap, by
        // more than the one unit of truncation the clamp itself can leave.
        let room = s.vmax_now - s.maxs;
        if (room > worst_over) { worst_over = room; };
        // And every position must still be inside the world.  There is no
        // `break` in Y, so this is a counter rather than an early exit: the
        // run finishes and the assertion below is about the whole of it.
        if (!flock.in_bounds(s)) { escaped = escaped + 1; }
    };
    eq("the run finished all 400 steps", s.gen, frames);
    eq("no frame had a bird outside the world", escaped, 0);
    // RULE 1: the clamp must have been NEEDED before asserting it held.
    nonzero("the clamp actually fired (s.over)", s.over);
    present("  on many frames (s.sat)", s.sat);
    nonzero("  and the raw speed really did exceed the cap", s.vraw - s.maxs);
    say("the largest raw |v| is over the cap by a real margin",
        s.vraw > s.maxs * 105 / 100,
        "raw " + tostring(s.vraw) + " vs cap " + tostring(s.maxs));
    eq("no post-clamp |v| ever exceeded the cap (worst margin)", worst_over, 0);
    say("the flock reached the cap and stayed there (vmax == maxs)",
        s.vmax == s.maxs, "vmax " + tostring(s.vmax) + ", cap " + tostring(s.maxs));
    eq("  and the cap is the one that was asked for", s.maxs, 22938);
    say("every bird is still inside the world after 400 steps",
        flock.in_bounds(s), "a position fell outside");
    // A second seed must behave the same way -- the clamp is not a property of
    // one lucky flock.  The seed differs, so the FLOCK differs, but the
    // invariant does not.  (The state digest differing is asserted in group 7
    // and is the reason two seeds are distinguishable at all.)
    let t = flock.blank(60, 40, 120);
    flock.set_view(t, 9);
    flock.set_sep(t, 4);
    flock.set_weights(t, 98304, 65536, 58982);
    flock.set_limits(t, 22938, 367008, 65536);
    flock.seed_flock(t, 99, t.maxs / 2, t.maxs);
    let k = 0;
    while (k < frames) {
        flock.step(t);
        k = k + 1
    };
    nonzero("the same holds for seed 99", t.over);
    eq("  its post-clamp max is exactly the cap", t.vmax, t.maxs);

    // And the clamp must be a CLAMP, not a scaling: a bird that overshoots by
    // a lot must land exactly ON the cap, not near it.
    let u = flock.blank(20, 20, 2);
    flock.set_view(u, 10);
    flock.set_sep(u, 10);
    flock.set_weights(u, 65536, 0, 0);
    flock.set_limits(u, 65536, 65536, 65536);
    flock.place(u, 0, 10, 10, 0, 0);
    flock.place(u, 1, 11, 10, 0, 0);
    flock.step(u);
    // 1/d^2 at one unit is 1.0, so the force is 1.0 and the new speed is 1.0,
    // which is exactly the cap: on the cap, not over it.
    present("the single-pair case produced a speed", flock.speed(u, 0));
    say("a bird driven at exactly the cap lands on it, not over",
        flock.speed(u, 0) <= 65536, "speed " + tostring(flock.speed(u, 0)));
    // A much harder overshoot: max_force 8x the cap, one step.
    let v = flock.blank(20, 20, 2);
    flock.set_view(v, 10);
    flock.set_sep(v, 10);
    flock.set_weights(v, 524288, 0, 0);
    flock.set_limits(v, 65536, 524288, 65536);
    flock.place(v, 0, 10, 10, 0, 0);
    flock.place(v, 1, 10, 11, 0, 0);
    flock.step(v);
    nonzero("a hard overshoot produced a speed", flock.speed(v, 0));
    say("  and the cap still held exactly", flock.speed(v, 0) == 65536,
        "speed " + tostring(flock.speed(v, 0)) + " vs cap 65536");
    say("  the raw speed was well over it", v.vraw > 65536,
        "vraw " + tostring(v.vraw) + " vs cap 65536");
    eq("  the clamp caught both boids", v.over, 2)
};

// -- 7. determinism ----------------------------------------------------------

// t_determinism() -- the same seed gives the same state, over many frames.
//
// This is the property the golden file checks, but checked HERE as well and in
// a stronger form: the golden compares TEXT, which passes even if the
// simulation state differs in ways the text does not show.  These assertions
// compare the full state of two independent runs, boid by boid, and then do
// the thing that stops it from being vacuous: they assert that a DIFFERENT seed
// gives a DIFFERENT state, so "the two runs agree" cannot be true because
// nothing was compared at all.
//
// The frames count is 250 and the flock is 120 boids: 250 * 120 * 119/2 =
// 1.785 million pairs.  A per-pair error that only shows up deep into a run
// would be caught here and not by a 12-frame golden.

def t_determinism() {
    head("7. determinism: same seed, same state, over many frames");
    let frames = 250;
    let a = make_run(1, frames);
    let b = make_run(1, frames);
    // RULE 1 first: there must be a state worth comparing, and a non-trivial
    // amount of it.
    eq("run A did all 250 frames", a.gen, frames);
    eq("run B did all 250 frames", b.gen, frames);
    nonzero("run A's digest is non-zero", flock.digest(a));
    nonzero("run B's digest is non-zero", flock.digest(b));
    nonzero("the run actually moved the flock (digest changed from the seed)",
            flock.digest(a) - flock.digest(make_run(1, 0)));
    // The real assertion: every bird, every field.
    eq("the two runs differ in ZERO boids", flock.diff(a, b), 0);
    eq("  and their digests are equal", flock.digest(a), flock.digest(b));
    // ...and the negative control, which is what makes the one above mean
    // something.  If the generator ignored its seed, both runs would agree
    // because they were the same run twice, and the assertion above would pass
    // for the wrong reason.
    let c = make_run(2, frames);
    nonzero("the seed-2 run has a digest", flock.digest(c));
    ne("  and a DIFFERENT digest from seed 1", flock.digest(c), flock.digest(a));
    say("  and they really differ boid by boid", flock.diff(a, c) > 0,
        "differing boids " + tostring(flock.diff(a, c)));
    eq("  seed 2's run also completed every frame", c.gen, frames);

    // The digest must be SENSITIVE, not merely deterministic: one unit of
    // movement in one boid has to change it.  Otherwise "the digests match" is
    // a property of a hash that ignores its input.
    let d = make_run(1, frames);
    let before = flock.digest(d);
    d.px[7] = d.px[7] + 1;
    let after = flock.digest(d);
    ne("one unit of movement in one boid changes the digest", after, before);
    d.px[7] = d.px[7] - 1;
    eq("  and putting it back restores it", flock.digest(d), before);

    // Same seed, SAME LENGTH: identical state.  This is the assertion that
    // would fail if a run's length leaked into its result in some way other than
    // through the number of steps.
    //
    // NOTE WHAT THIS IS NOT.  diff() compares two CURRENT states, not a prefix
    // of one with the other, so it cannot say "the first 10 frames of a
    // 250-frame run equal a 10-frame run".  A 250-frame run is at a different
    // point in the simulation and MUST differ -- and that is asserted as its
    // own thing below, because it is what makes the equality above mean
    // something: length is the only thing that differs, and it does change the
    // state.
    let e10 = make_run(1, 10);
    let e10b = make_run(1, 10);
    eq("two 10-frame runs of seed 1 are identical", flock.diff(e10, e10b), 0);
    ne("but a 250-frame run is at a DIFFERENT point",
       flock.digest(make_run(1, 250)), flock.digest(e10));

    // Every position inside the world, after every one of those runs.
    say("run A is inside the world", flock.in_bounds(a), "a position escaped");
    say("run B is inside the world", flock.in_bounds(b), "a position escaped");
    say("run C is inside the world", flock.in_bounds(c), "a position escaped");

    // Two seeds must not merely give different digests, they must give
    // visibly different flocks: an ord/boid that is zero would mean the seed
    // produced a scatter so spread out that nobody sees anybody, which is a
    // plausible silent failure of seed_flock.
    present("the seed-1 flock has neighbours", flock.mean_order(a));
    present("the seed-2 flock has neighbours", flock.mean_order(c))
};

// -- 8. the generator --------------------------------------------------------

// TALLY is a module-level histogram, allocated ONCE.  Returning a [long; 1024]
// from a function would be a type error and building one inside a loop would be
// 8 KB an iteration, so the draw loop below writes into this one.
let TALLY: [long; 1024] = [0; 1024];

// t_generator() -- the seed is honoured and the generator is not degenerate.
//
// Three things have to be true, and the third is the one that stops the first
// two from being trivial:
//
//   * the same seed gives the same sequence of draws;
//   * a different seed gives a different one;
//   * the draws are actually SPREAD OUT and roughly uniform -- 400 draws from a
//     low-order generator's low bits, or from a generator whose state never
//     advances, would satisfy the first two and produce a flock that is a line.
//
// The expected counts here are properties of a uniform generator over 0..999:
// most of 400 draws are distinct, the range is most of 0..999, and the mean is
// near 500.  None of the three numbers is read out of the generator.
// The return type is annotated because run() calls this before the definition
// is reached -- a forward call needs its return type written.  (It is called
// from run() rather than from t_determinism() so that the groups PRINT in the
// order they are NUMBERED; called from the end of t_determinism() it ran after
// group 8's heading and the output read 1..7, 9, 8.)
def t_generator() -> long {
    head("8. the generator: same seed, same draws; and spread out");
    flock.rng_seed(1);
    let k = 0;
    while (k < 1024) {
        TALLY[k] = 0;
        k = k + 1
    };
    let n = 0;
    let lo = 1000;
    let hi = 0 - 1;
    let sum = 0;
    while (n < 400) {
        let v = flock.rng_below(1000);
        TALLY[v] = TALLY[v] + 1;
        if (v < lo) { lo = v; };
        if (v > hi) { hi = v; };
        sum = sum + v;
        n = n + 1
    };
    // The parens matter: `-` binds LOOSER than a comparison in this grammar, so
// `hi - lo >= 0` as an argument comes through as the bool, not as the long the
// assertion wants.
eq("  and none landed outside 0..999", if (hi - lo >= 0) { 1 } else { 0 }, 1);
    let distinct = 0;
    k = 0;
    while (k < 1000) {
        if (TALLY[k] > 0) { distinct = distinct + 1; };
        k = k + 1
    };
    let mean = sum / n;
    // RULE 1: the sample has to be worth looking at before any of these is
    // meaningful, and 400 is asserted so a shortened loop cannot pass quietly.
    eq("the sample really was 400 draws", n, 400);
    present("and most of them were distinct values", distinct);
    say("  400 draws over 1000 values are mostly distinct", distinct > 300,
        "distinct " + tostring(distinct) + " of 400");
    say("  and they span most of the range", hi - lo > 700,
        "range " + tostring(hi - lo) + " (from " + tostring(lo) + " to "
        + tostring(hi) + ")");
    // In RAW units the mean of a uniform generator over 0..999 is about 500;
    // it is not a fraction, so there is no *100 here.
    say("  with a mean near the middle of 0..999", mean > 400 && mean < 600,
        "mean " + tostring(mean));

    // The same seed, twice: the first 20 draws must be identical.  Both
    // sequences are compared through a second tally, so the comparison is of
    // VALUES that were observed, not of a remembered list.
    flock.rng_seed(1);
    let first = [0; 20];
    let i = 0;
    while (i < 20) {
        first[i] = flock.rng_below(1000);
        i = i + 1
    };
    flock.rng_seed(1);
    let same = 0;
    i = 0;
    while (i < 20) {
        if (flock.rng_below(1000) == first[i]) { same = same + 1; };
        i = i + 1
    };
    eq("the same seed gives the same 20 draws", same, 20);
    nonzero("  and those draws were not all zero", first[0]);

    // A different seed must break at least one of them.  Seed 2 is not an
    // arbitrary choice: it is the seed of run C above, whose flock is already
    // known to differ, so this ties the generator to the simulation.
    flock.rng_seed(2);
    let diffs = 0;
    i = 0;
    while (i < 20) {
        if (flock.rng_below(1000) != first[i]) { diffs = diffs + 1; };
        i = i + 1
    };
    present("a different seed produced a different sequence", diffs);

    // rng_below(0) is a mistake, not a division by zero: it answers 0.
    eq("rng_below(0) returns 0 rather than trapping", flock.rng_below(0), 0);
    0
};

// make_run(seed, frames) -> a flock run for `frames` frames at the SHIPPED
// settings.  They are stated HERE rather than read from args, so this does not
// depend on the option table -- a change to a default would make the check test
// something other than what ships.  They match boids.y's main() exactly:
//   --boids 120 --size 60x40 --view 9 --sep 4
//   --wsep 150 --wali 100 --wcoh 90 --maxspeed 140
// with dt = 0.5 (32768) and the cruising speed at 65% of the limit.
//
// The other hand-computed cases in this file deliberately do NOT use these: they
// pin dt = 1.0, desire == maxs and wide-open limits, because that is the
// arithmetic a human can work out on paper.  A hand-computed case has to be the
// SIMPLEST case, not the shipped one.
def make_run(seed: long, frames: long) -> flock.Flock {
    let s = flock.blank(60, 40, 120);
    flock.set_view(s, 9);
    flock.set_sep(s, 4);
    flock.set_weights(s, 98304, 65536, 58982);
    flock.set_limits(s, 91750, 91750, 32768);
    flock.set_desire(s, 59637);
    flock.set_mask(flock.M_ALL);
    flock.seed_flock(s, seed, s.desire / 2, s.desire * 3 / 2);
    let g = 0;
    while (g < frames) {
        flock.step(s);
        g = g + 1
    };
    s
};

// -- 9. structure and edges --------------------------------------------------

// HD_A and HD_B hold every boid's heading either side of a run, so "nobody
// turned" can be asserted without allocating.  A [long; 8] literal inside the
// loop that CONSUMES these would be 64 bytes an iteration, and the heap is an
// arena: 60 frames of that is 3.8 KB for nothing.
//
// They are module level rather than parameters because a parameter typed
// `[long]` does not accept a `[long; 8]` argument -- the checker treats the two
// as different types, and the fixed size is what stops the array growing.
let HD_A: [long; 512] = [0; 512];
let HD_B: [long; 512] = [0; 512];

// headings(s, out) -- every boid's heading into `out`.
def headings(s: flock.Flock, out: [long; 512]) {
    let i = 0;
    while (i < s.n) {
        out[i] = flock.heading(s, i);
        i = i + 1
    }
};

// turn_diff(a, b) -> how far a heading moved, in hundredths of a degree, taking
// the short way round the circle.  A boid that crossed due north has not
// "turned 180 degrees", it has turned 180 degrees either way -- the wrap
// matters, or this assertion would fire on a boid that merely crossed 0.
def turn_diff(a: long, b: long) -> long {
    let d = a - b;
    if (d < 0) { d = 0 - d; };
    if (d > 18000) { d = 36000 - d; };
    d
};

// t_structure() -- things that must hold of the STATE rather than the physics,
// each of which is a way the program could be quietly wrong.
//
//   * every position inside the world, always;
//   * the flock size never changes;
//   * a one-bird flock is stable (nothing to see, nothing to steer);
//   * the mask can be emptied, and then the flock flies STRAIGHT -- the
//     clearest possible check that the three rules are what turn a swarm into a
//     flock;
//   * place() refuses an out-of-range index instead of trapping;
//   * the wrap is a wrap: a boid leaving one edge appears on the other.

def t_structure() {
    head("9. structure: bounds, size, an empty mask, place()'s refusals, the wrap");
    let s = flock.blank(30, 20, 5);
    flock.set_view(s, 6);
    flock.set_sep(s, 3);
    flock.set_weights(s, 98304, 65536, 58982);
    flock.set_limits(s, 65536, 131072, 65536);
    flock.seed_flock(s, 3, 32768, 65536);
    eq("the flock has the boids it was asked for", s.n, 5);
    let g = 0;
    let escaped = 0;
    while (g < 300) {
        flock.step(s);
        g = g + 1;
        if (!flock.in_bounds(s)) { escaped = escaped + 1; }
    };
    eq("300 steps ran", s.gen, 300);
    eq("no frame had a bird outside the world", escaped, 0);
    eq("the flock is still the same size", s.n, 5);

    // One bird: nothing to see, so nothing to steer, so it goes straight.
    flock.set_mask(flock.M_ALL);
    let o = flock.blank(30, 20, 1);
    flock.set_view(o, 6);
    flock.set_sep(o, 3);
    flock.set_weights(o, 98304, 65536, 58982);
    flock.set_limits(o, 65536, 131072, 65536);
    // The velocity is (0.75, 0.375) = 0.838 units, BELOW the 1.0 cap on
    // purpose.  The first version used (1.0, 0.5), whose length is 1.118 --
    // over the cap -- so the clamp fired and the "keeps its velocity exactly"
    // assertion was really asserting that the clamp works.
    flock.place(o, 0, 5, 5, 49152, 24576);
    flock.step(o);
    eq("a lone bird sees nobody", flock.acc_nali(), 0);
    eq("  so its acceleration is zero", o.ax[0], 0);
    eq("  and it keeps its velocity exactly", o.vx[0], 49152);
    eq("  and its y velocity too", o.vy[0], 24576);
    eq("  and moved x by exactly its velocity", o.px[0], 5 * 65536 + 49152);
    flock.step(o);
    flock.step(o);
    // Three steps in total from x = 5, not two more from the one-step value.
    eq("  and keeps doing so (3 steps from x = 5)", o.px[0], 5 * 65536 + 3 * 49152);

    // Every rule off: the flock flies dead straight, so each bird's direction
    // is unchanged for ever.  This is the cleanest demonstration that the rules
    // are what make a flock, and it fails if any rule is applied when it should
    // not be -- or if the mask is not consulted at all.
    flock.set_mask(0);
    let n = flock.blank(40, 20, 8);
    flock.set_view(n, 9);
    flock.set_sep(n, 4);
    flock.set_weights(n, 98304, 65536, 58982);
    flock.set_limits(n, 65536, 131072, 65536);
    flock.seed_flock(n, 4, 32768, 65536);
    headings(n, HD_A);
    let k = 0;
    while (k < 60) {
        flock.step(n);
        k = k + 1
    };
    headings(n, HD_B);
    let turned = 0;
    let i = 0;
    while (i < n.n) {
        if (turn_diff(HD_A[i], HD_B[i]) > 0) { turned = turned + 1; };
        i = i + 1
    };
    eq("with every rule off, NO bird turned in 60 steps", turned, 0);
    say("  and they all still have a velocity", flock.mean_speed(n) > 0,
        "mean " + tostring(flock.mean_speed(n)));

    // The same flock WITH the rules on must turn somebody: the negative
    // control, so "no bird turned" above cannot be because heading() is
    // returning a constant.
    flock.set_mask(flock.M_ALL);
    let m = flock.blank(40, 20, 8);
    flock.set_view(m, 9);
    flock.set_sep(m, 4);
    flock.set_weights(m, 98304, 65536, 58982);
    flock.set_limits(m, 65536, 131072, 65536);
    flock.seed_flock(m, 4, 32768, 65536);
    headings(m, HD_A);
    k = 0;
    while (k < 60) {
        flock.step(m);
        k = k + 1
    };
    headings(m, HD_B);
    let turned2 = 0;
    i = 0;
    while (i < m.n) {
        if (turn_diff(HD_A[i], HD_B[i]) > 0) { turned2 = turned2 + 1; };
        i = i + 1
    };
    present("with the rules on, some bird turned", turned2);

    // place() refuses a bad index rather than trapping.
    eq("place() refuses index -1", if (flock.place(s, 0 - 1, 1, 1, 0, 0)) { 1 } else { 0 }, 0);
    eq("  and index == n", if (flock.place(s, s.n, 1, 1, 0, 0)) { 1 } else { 0 }, 0);
    eq("  and index 999", if (flock.place(s, 999, 1, 1, 0, 0)) { 1 } else { 0 }, 0);
    eq("  but accepts n-1", if (flock.place(s, s.n - 1, 1, 1, 0, 0)) { 1 } else { 0 }, 1);

    // The wrap: a bird a hair from the right edge, moving right, appears on
    // the left.  This is what makes the torus a torus.
    let t = flock.blank(20, 20, 1);
    flock.set_view(t, 2);
    flock.set_sep(t, 2);
    flock.set_limits(t, 65536, 65536, 65536);
    flock.place(t, 0, 19, 10, 65536, 0);       // x = 19 of 20, moving +1
    flock.step(t);
    eq("a bird off the right edge wraps to x = 0", t.px[0], 0);
    flock.place(t, 0, 0, 10, 0 - 65536, 0);    // x = 0, moving -1
    flock.step(t);
    eq("and off the left edge to x = 19", t.px[0], 19 * 65536);
    // A position just past the edge is normalized by place() itself.
    flock.place(t, 0, 20, 10, 0, 0);
    eq("place() wraps a coordinate past the edge", t.px[0], 0);
    flock.place(t, 0, 25, 10, 0, 0);
    eq("  and one several units past it", t.px[0], 5 * 65536);

    // The radii are squared ONCE into Q32, and the square is right.
    flock.set_view(s, 9);
    eq("view radius 9 squared into Q32", s.vr2, 81 * 4294967296);
    flock.set_sep(s, 4);
    eq("separation radius 4 squared into Q32", s.sr2, 16 * 4294967296);
    // And the pair loop compares the SQUARED distance, so a 9-unit radius
    // really does include a bird at 8.99 units and exclude one at 9.01.
    let u = flock.blank(40, 40, 2);
    flock.set_view(u, 9);
    flock.set_sep(u, 4);
    flock.place(u, 0, 20, 20, 0, 0);
    flock.place(u, 1, 28, 20, 0, 0);
    flock.accumulate(u, 0);
    eq("8 units away with a 9 radius: seen", flock.acc_nali(), 1);
    flock.place(u, 1, 29, 20, 0, 0);
    flock.accumulate(u, 0);
    eq("9 units away: not seen (strict <)", flock.acc_nali(), 0)
};

// -- the driver --------------------------------------------------------------

// run(w, h) -> long -- the whole battery, and the exit status: 0 if every
// assertion held, 1 otherwise.  boids.y's --check calls it and exits with it.
def run(w: long, h: long) -> long {
    flock.set_mask(flock.M_ALL);
    puts("boids --check: properties of the fixed-point flocking simulation\n");
    puts("no reference file is involved: every expected value below is\n");
    puts("computed here from the geometry, or derived by hand.\n");
    t_fixed();
    t_sqrt();
    t_hand();
    t_signs();
    t_counts();
    t_clamp();
    t_determinism();
    t_generator();
    t_structure();
    puts("\n");
    puts("  ---------------------------------------------------------------\n");
    // The pass and the fail are the two ARMS of one `if`, and an arm's value is
    // its last statement.  Written as `if (...) { ...; 0 }; ...; 1` -- which is
    // what this was at first -- the arm's 0 is the BLOCK's value, the block is
    // discarded, and the function falls through to the trailing 1: the check
    // printed "0 failed" and then exited 1, which the gate duly reported as a
    // failure of the check.  An exit status has to be the LAST thing.
    if (FAILED == 0) {
        puts("boids --check: " + tostring(PASSED) + " assertions passed, 0 failed\n")
    } else {
        puts("boids --check: " + tostring(PASSED) + " passed, " + tostring(FAILED)
             + " FAILED\n")
    };
    FAILED
};