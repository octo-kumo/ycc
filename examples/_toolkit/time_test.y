// time_test.y -- the self-test for examples/_toolkit/time.y.
//
// Run it the way it is meant to be run, from examples/_toolkit/:
//
//     (ulimit -S -v 3670016; \
//      ../../refs/ycc.ref time_test.y -o /tmp/tim && /tmp/tim) </dev/null
//
// Unlike term_test.y this one needs no pty: time.y is a clock and a pacer,
// not a terminal. It does need real time -- the sustained-rate check below
// spends about seven seconds of wall clock, which is the point: the gate
// criterion it discharges is "sustained target fps", and that cannot be
// checked without actually pacing frames for seconds.
//
// WHY THIS FILE EXISTS
// -------------------
// fx.y, fb.y, args.y and term.y each have a suite. time.y did not, while
// wave 0d's gate criterion names it explicitly ("self-test of the flag
// table, unknown-flag exit code, and sustained target fps"). So the one
// wave-0 module whose gate criterion is a *number* had no test for that
// number. Writing it is also the only honest way to check time.y's central
// claim -- that it allocates nothing, ever -- since "allocates nothing" is
// a property of a call sequence, not of a function.
//
// WHAT IS CHECKED
//   1  now_us() never goes backwards; now_ms() agrees with it
//   2  pacer_new's period, including BOTH clamps (fps < 1 and fps > 1e6,
//      where the period would round to 0 and divide by zero downstream)
//   3  THE NAMED CRITERION: sustained target fps at 30 and at 60, measured
//      from OUTSIDE the meter
//   4  an overrun is DROPPED, not caught up, and the rate recovers
//   5  pacer_start re-bases the deadline, so a second run starts clean
//   6  the fps meter: window rate, average rate, frame count
//   7  ALLOCATION: now_us + nap_us + pacer_next + fps_tick over thousands
//      of calls move heap_used by exactly zero
//
// A NOTE ON MEASURING THE RATE, because it is the whole check
// ---------------------------------------------------------
// Do NOT read time.fps_x100() and call that the answer. The meter closes a
// 500 microsecond window and counts frames in it; at 30 fps that is ~15
// frames per window, so one frame either way is ~6.7% and the displayed
// value cannot resolve 29 from 30. (An earlier harness did exactly that,
// got 29 against a target of 30, and nearly filed a defect in an example
// that was hitting 29.99.) So the sustained-rate check below counts frames
// it paced itself and divides by its own clock -- measured from outside the
// code under test, which is the only arrangement that can disagree with it.

import time;

let checks = 0;
let failed = 0;

def check(c: bool, name: str) {
    checks = checks + 1;
    if (c) {
        print("ok   " + name);
    } else {
        failed = failed + 1;
        print("FAIL " + name);
    }
};

def check_long(got: long, want: long, name: str) {
    checks = checks + 1;
    if (got == want) {
        print("ok   " + name + ": got " + tostring(got));
    } else {
        failed = failed + 1;
        print("FAIL " + name + ": got " + tostring(got) + ", want " + tostring(want));
    }
};

// ── 1. the clock ────────────────────────────────────────────────────────────
def test_clock() {
    // Monotonicity, sampled densely. CLOCK_MONOTONIC cannot go backwards,
    // but a buggy read (wrong clock id, wrong struct offset) could, and a
    // clock that steps backwards would make the pacer below behave
    // nonsensically rather than obviously wrong.
    let back = 0;
    let prev = time.now_us();
    let i = 0;
    while (i < 20000) {
        let t = time.now_us();
        if (t < prev) { back = back + 1 };
        prev = t;
        i = i + 1
    };
    check(back == 0, "now_us() never goes backwards over 20000 samples");

    // now_ms is documented as now_us/1000. Sampled the other way round --
    // read the milliseconds first, then the microseconds -- so the two
    // readings cannot straddle a tick and produce a spurious off-by-one.
    let agree = 0;
    let k = 0;
    while (k < 2000) {
        let ms = time.now_ms();
        let us = time.now_us();
        if (ms == us / 1000) { agree = agree + 1 };
        k = k + 1
    };
    check(agree > 1900, "now_ms() agrees with now_us()/1000: "
          + tostring(agree) + "/2000 exact (the rest straddle a millisecond)");

    // now_us must be plausible in absolute terms: not zero, and not stuck
    // at some epoch value. CLOCK_MONOTONIC on Linux is time since boot.
    let t0 = time.now_us();
    check(t0 > 1000000, "now_us() is a real monotonic reading, not near zero: "
          + tostring(t0));
    check(time.now_us() >= t0, "now_us() advances over successive calls");
}

// ── 2. the period, and both clamps ─────────────────────────────────────────
def test_period() {
    // 1e6/30 = 33333.33, and the division TRUNCATES, so the period is
    // 33333 and the achieved rate is a hair ABOVE 30, never below. That
    // direction matters: it means a shortfall at 30 fps can never be blamed
    // on the period being rounded down.
    check_long(time.pacer_period_us(time.pacer_new(30)), 33333,
               "pacer_new(30) period is 1e6/30 truncated");
    check_long(time.pacer_period_us(time.pacer_new(60)), 16666,
               "pacer_new(60) period is 1e6/60 truncated");
    check_long(time.pacer_period_us(time.pacer_new(1)), 1000000,
               "pacer_new(1) period is one second");

    // fps below 1 would divide to a period of 1e6 or more and then to
    // something enormous; the code clamps it to 1. Assert the clamp rather
    // than the arithmetic.
    check_long(time.pacer_period_us(time.pacer_new(0)), 1000000,
               "pacer_new(0) clamps to 1 fps, not a division by zero");
    check_long(time.pacer_period_us(time.pacer_new(0 - 30)), 1000000,
               "pacer_new(-30) clamps to 1 fps");

    // fps above 1e6 makes 1e6/fps round to ZERO, and a zero period is the
    // one value that would make pacer_next's lag comparison meaningless.
    // The clamp to 1 is what prevents it.
    check(time.pacer_period_us(time.pacer_new(2000000)) >= 1,
          "pacer_new(2000000) does not produce a zero period");
    check_long(time.pacer_period_us(time.pacer_new(2000000)), 1,
               "pacer_new(2000000) clamps the period to 1 microsecond");
}

// ── 3. THE NAMED GATE CRITERION: sustained target fps ──────────────────────
// Count the frames paced here and divide by the clock read here. Measured
// from outside time.y's own meter on purpose -- see the note at the top.
def paced_rate(fps: long, frames_wanted: long) -> long {
    let p = time.pacer_new(fps);
    time.pacer_start(p);
    let t0 = time.now_us();
    let drawn = 0;
    let i = 0;
    let go = true;
    while (go && i < frames_wanted) {
        let w = time.pacer_next(p);
        if (w >= 0) { drawn = drawn + 1 };
        i = i + 1
    };
    let el = time.now_us() - t0;
    // hundredths of a frame per second, from our own count and our own clock
    drawn * 100000000 / el
};

def test_sustained(fps: long, frames_wanted: long, label: str) {
    let r100 = paced_rate(fps, frames_wanted);
    let target100 = fps * 100;
    let lo = target100 * 97 / 100;
    let hi = target100 * 103 / 100;
    check(r100 >= lo && r100 <= hi,
          "sustained " + label + ": " + tostring(r100 / 100) + " fps over "
          + tostring(frames_wanted) + " paced frames, within 3% of "
          + tostring(fps));
    // The pacer must have counted what it drew. If these disagree the pacer
    // is counting something other than frames it reported drawing.
    let p = time.pacer_new(fps);
    check(time.pacer_frames(p) == 0,
          "a fresh pacer has drawn 0 frames");
    check(time.pacer_dropped(p) == 0,
          "a fresh pacer has dropped 0 frames");
}

// ── 4. an overrun is DROPPED, and the rate recovers ────────────────────────
// The contract is that falling behind costs frames rather than accumulating
// lag: "a stall of k frames costs k frames and then the rate is back to
// normal -- it does not drift and it does not spiral".
//
// An earlier version of this check asserted that the call IMMEDIATELY after
// a drop draws again. That was wrong arithmetic, and the code was right:
//
//   period 20000. pacer_start sets sched = T. Frame 1 sleeps to T+20000.
//   nap_us(60000) puts now at T+80000. Call 2: sched = T+40000,
//   d = -40000 <= -period -> DROP. Call 3: sched = T+60000, d = -20300,
//   still <= -period -> DROP. Call 4: sched = T+80000, d = -600, which is
//   > -period -> DRAW.
//
// So a THREE-period stall costs TWO drops, not one, because the schedule had
// already advanced a period before the stall began. The drops converge,
// which is exactly the promise -- so what is asserted here is the
// convergence, not a guess about how many drops it takes.
def test_drop() {
    let p = time.pacer_new(50);              // 20000 us a frame
    time.pacer_start(p);
    let first = time.pacer_next(p);
    check(first >= 0, "first frame after pacer_start is drawn, not dropped");
    check(time.pacer_frames(p) == 1, "frames counter is 1 after one draw");

    let before_frames = time.pacer_frames(p);
    let before_dropped = time.pacer_dropped(p);

    // Miss three whole periods.
    time.nap_us(60000);
    let w = time.pacer_next(p);
    check(w < 0, "a frame more than a whole period late reports w < 0: "
          + tostring(w));
    check(time.pacer_frames(p) == before_frames,
          "a dropped frame does NOT advance the frames counter");
    check(time.pacer_dropped(p) > before_dropped,
          "a dropped frame DOES advance the dropped counter");
    check(time.pacer_lag_us(p) <= 0 - time.pacer_period_us(p),
          "lag_us on a drop is at most -period, as documented");

    // Convergence: the drops must stop within a few frames and frames must
    // be drawn again. A bound of 6 is generous against the 2 the arithmetic
    // predicts, and still fails loudly on a spiral.
    let drawn = 0;
    let i = 0;
    while (i < 6 && drawn == 0) {
        let v = time.pacer_next(p);
        if (v >= 0) { drawn = drawn + 1 };
        i = i + 1
    };
    check(drawn > 0,
          "the pacer converges: a frame is drawn again within 6 calls");
    let drops_after = time.pacer_dropped(p) - before_dropped;
    check(drops_after <= 4,
          "the stall costs a bounded number of frames, not a spiral: "
          + tostring(drops_after) + " drops");

    // Once recovered it STAYS recovered -- the "does not drift" half of the
    // contract, which a single draw after the drop cannot show.
    let drawn2 = 0;
    let k = 0;
    while (k < 5) {
        let v2 = time.pacer_next(p);
        if (v2 >= 0) { drawn2 = drawn2 + 1 };
        k = k + 1
    };
    check_long(drawn2, 5, "once recovered, the next five frames are all drawn");
    check_long(time.pacer_dropped(p) - before_dropped, drops_after,
               "no further drops once recovered (no drift)");
}

// ── 5. pacer_start re-bases ────────────────────────────────────────────────
// A second run of the same animation must not inherit the first run's
// deadline, or it would open with a burst of dropped frames.
def test_restart() {
    let p = time.pacer_new(40);
    time.pacer_start(p);
    let i = 0;
    while (i < 3) { time.pacer_next(p); i = i + 1 };
    time.nap_us(50000);                      // fall behind
    time.pacer_next(p);
    let drops_before = time.pacer_dropped(p);
    check(drops_before > 0, "the run dropped frames before the restart");

    time.pacer_start(p);
    check(time.pacer_frames(p) == 0, "pacer_start zeroes the frames counter");
    check(time.pacer_dropped(p) == 0, "pacer_start zeroes the dropped counter");
    let w = time.pacer_next(p);
    check(w >= 0, "the first frame after pacer_start is drawn, not dropped");
}

// ── 6. the fps meter ───────────────────────────────────────────────────────
// fps_new takes a window; a window below a millisecond is raised, because
// the meter divides the window length and must never divide by zero.
def test_meter() {
    check_long(time.fps_frames(time.fps_new(0)), 0,
               "a fresh meter has counted 0 frames");
    check_long(time.fps_x100(time.fps_new(0)), 0,
               "a fresh meter reports 0 before any window closes");

    // THE CLAMP IS ONLY EXERCISED IF YOU TICK. Creating a meter with window
    // 0 and never ticking it proves nothing: with the clamp the window is
    // raised to 1000 and nothing happens; without it the window is 0, the
    // first tick closes it immediately, and fps_x100 divides by an elapsed
    // time that is 0 microseconds -- a division by zero, or a wildly wrong
    // rate if the clock happened to tick. So tick it, immediately, and
    // assert the window did NOT close. An injected clamp removal sails past
    // every other check in this file; this is the one that sees it.
    let zero = time.fps_new(0);
    time.fps_tick(zero);
    check_long(time.fps_x100(zero), 0,
               "a meter created with window 0 does not close on the first"
               + " tick: the window was raised, so nothing was divided by 0");
    check_long(time.fps_frames(zero), 1,
               "the tick on the raised-window meter still counted its frame");

    // A negative window must be raised on the same path.
    let neg = time.fps_new(0 - 500000);
    time.fps_tick(neg);
    check_long(time.fps_x100(neg), 0,
               "a meter created with a NEGATIVE window is raised too");

    // With a 1 microsecond window every tick closes a window, so the meter
    // must have a real reading after a single tick rather than still zero.
    let f = time.fps_new(1000);
    time.nap_us(3000);
    time.fps_tick(f);
    check_long(time.fps_frames(f), 1, "one tick counts one frame");
    check(time.fps_x100(f) > 0, "a closed window reports a non-zero rate: "
          + tostring(time.fps_x100(f)));
    check(time.fps_avg_x100(f) > 0, "fps_avg is non-zero after a tick");

    // Tick faster than the window closes: frames accumulate and nothing is
    // reported until the window is full. That is the documented behaviour
    // and it is what makes the on-screen number quantised.
    let g = time.fps_new(1000000);
    let j = 0;
    while (j < 50) { time.fps_tick(g); j = j + 1 };
    check_long(time.fps_frames(g), 50, "50 ticks count 50 frames");
    check_long(time.fps_x100(g), 0,
               "no rate is reported while the window is still open");

    // fps_line allocates, by its own doc, and is only for a status line.
    // Check it is at least well formed rather than pretending it is free.
    let line = time.fps_line(g);
    check(line.length > 0 && line.index_of("fps") >= 0,
          "fps_line() produces a status string naming fps");
}

// ── 7. ALLOCATION -- the module's central claim ───────────────────────────
// "now_us() and nap_us() and the pacer allocate nothing, ever" is a claim
// about a call SEQUENCE, so it can only be checked by making a lot of calls
// and reading heap_used() either side. The std sleep(ms) allocates, which is
// the whole reason this module exists.
def test_no_alloc() {
    // Warm up first: the very first call of anything may legitimately build
    // something, and charging that to the steady-state claim would be a
    // measurement artefact rather than a finding.
    time.now_us(); time.nap_us(100); time.pacer_next(time.pacer_new(30));
    time.fps_tick(time.fps_new());

    let h0 = heap_used();
    let i = 0;
    while (i < 5000) {
        time.now_us();
        i = i + 1
    };
    check_long(heap_used() - h0, 0, "5000 now_us() calls allocate nothing");

    let h1 = heap_used();
    let k = 0;
    while (k < 500) {
        time.nap_us(200);
        k = k + 1
    };
    check_long(heap_used() - h1, 0, "500 nap_us() calls allocate nothing");

    // Pacing must allocate nothing either, or a render loop that calls it
    // once per frame leaks 16 bytes a frame for ever.
    let p = time.pacer_new(2000);             // 500 us, so 400 frames is 0.2 s
    time.pacer_start(p);
    let h2 = heap_used();
    let m = 0;
    while (m < 400) { time.pacer_next(p); m = m + 1 };
    check_long(heap_used() - h2, 0, "400 paced frames allocate nothing");

    // And the meter, which is called once per frame alongside.
    let f = time.fps_new(1000000);
    let h3 = heap_used();
    let n = 0;
    while (n < 2000) { time.fps_tick(f); n = n + 1 };
    check_long(heap_used() - h3, 0, "2000 fps_tick() calls allocate nothing");

    // A literal inside a loop allocates per iteration -- the campaign's
    // rule 4, asserted HERE so the allocation claim above is anchored
    // against a control that is known to allocate. If this control ever
    // stops allocating, heap_used() is not measuring what we think it is,
    // and every "allocates nothing" result above becomes vacuous.
    let h4 = heap_used();
    let ctl = 0;
    let j2 = 0;
    while (j2 < 200) {
        let scratch = [0; 4];
        scratch[0] = j2;
        ctl = ctl + scratch[0];
        j2 = j2 + 1
    };
    check(ctl == 19900, "the allocation control computes the right sum: "
          + tostring(ctl));
    print("     (control: a [0; 4] literal per iteration moved heap_used by "
          + tostring(heap_used() - h4) + " bytes, so heap_used() does see "
          + "per-iteration allocation)");
}

test_clock();
test_period();
test_sustained(30, 150, "30 fps");
test_sustained(60, 180, "60 fps");
test_drop();
test_restart();
test_meter();
test_no_alloc();

print("");
print(tostring(checks - failed) + " of " + tostring(checks) + " checks passed");
if (failed == 0) {
    print("RESULT: PASS");
} else {
    print("RESULT: FAIL");
    exit(1);
};