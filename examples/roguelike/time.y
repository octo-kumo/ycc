// time.y -- sub-millisecond timing and frame pacing, shared by the examples
// campaign.
//
// Vendored into an example folder beside the program that uses it (see
// ORCHESTRATOR.md, "The folder contract"); `import time;` and call through
// the namespace.  A module imported by name keeps its own scope (rename.y),
// so these names never meet the program's own.
//
//   import time;
//
//   let p = time.pacer_new(30);          // 30 fps
//   let f = time.fps_new();              // the rate meter
//   let go = true;
//   while (go) {
//       let w = time.pacer_next(p);      // sleeps; see the contract below
//       if (w >= 0) { draw(); time.fps_tick(f) } else { /* skipped */ };
//       go = !done();
//   };
//   puts(time.fps_line(f) + "\n");
//
// ── why this exists ──────────────────────────────────────────────────────
//
// The std `sleep(ms)` takes milliseconds, which cannot pace a 30 fps
// animation (a frame is 33.3 ms) nor anything finer.  `clock_us()` does
// give microseconds, but it allocates a two-word array on every call -- in a
// per-frame path, where the heap is an arena and nothing is ever freed
// (§2.7), that is a leak.  So the clock here is read into one pair of
// module-level longs that every call reuses: now_us() and nap_us() and the
// pacer allocate nothing, ever.  That is what makes them safe to call twice
// per frame for the life of a program.
//
// Clock: CLOCK_MONOTONIC (syscall 228, clock id 1), in microseconds.  It
// never goes backwards and is not affected by settimeofday, which is what a
// schedule wants.  For the wall clock there is `time_us()` in the std.
//
// ── NOT REENTRANT ────────────────────────────────────────────────────────
//
// tm_ts and tm_rm are module-level scratch: one timespec for the request
// and one for what nanosleep leaves behind.  Two threads calling these
// functions at once would overwrite each other's buffer.  This is a
// single-threaded utility by design -- one render loop, one clock.  (A
// program that wants a second, independent pacer, e.g. one thread per
// simulation, must not share this module; give each its own.)
//
// ── the pacer contract ───────────────────────────────────────────────────
//
// `pacer_new(fps)` -> `Pacer` (one heap record, made once).  Then, once per
// frame, **before drawing**:
//
//     let w = time.pacer_next(p);
//     if (w >= 0) { draw_frame() } else { /* drop this frame */ };
//
// pacer_next adds one period to an absolute deadline, then:
//
//   w >= 0   sleep until the deadline (in <= 1 ms naps, so an overshoot
//            cannot stretch the schedule) and draw.  w is the microseconds
//            actually slept.
//   w <  0    the deadline had already passed by a whole frame or more:
//            **drop the frame and draw nothing**.  w is the lag in
//            microseconds, always <= -period.
//
// Dropping rather than catching up is the point (this is the loop
// badapple80x30.y runs at 30 fps): a program that fell behind must not try
// to make the time up by drawing faster than real time, and it must not let
// the lag accumulate, so the deadline is absolute and never rebased.  One
// dropped frame is what lets the schedule recover, so a stall of k frames
// costs k frames and then the rate is back to normal -- it does not drift
// and it does not spiral.
//
// The wait belongs *before* the drawing, so the time the frame took is
// accounted for: the deadline for frame n is start + n * period no matter
// how long frame n-1 took.  `pacer_start(p)` re-bases the deadline on the
// clock now, for a second run.

// ── the scratch buffers ──────────────────────────────────────────────────
//
// clock_gettime and nanosleep fill a struct timespec {sec, nsec}, which is
// two 8-byte longs.  Module level, so allocated once, and never handed out:
// only the values leave.
let tm_ts: [long; 2] = [0; 2];
let tm_rm: [long; 2] = [0; 2];

// ── the clock ────────────────────────────────────────────────────────────

// now_us() -> long -- microseconds from CLOCK_MONOTONIC.  Allocation-free:
// one syscall, one reused buffer, and the answer is a long.
def now_us() -> long {
    syscall(228, 1, &tm_ts[0]);
    tm_ts[0] * 1000000 + tm_ts[1] / 1000
};

// now_ms() -> long -- the same clock in milliseconds, for a progress line
// rather than for scheduling.
def now_ms() -> long { now_us() / 1000 };

// nap_us(us) -> long -- sleep `us` microseconds (syscall 35, nanosleep).
// nanosleep returns early when a signal arrives, leaving the time it did
// not sleep in the second buffer, so it is resumed with what is left --
// which is what keeps a Ctrl-C's SIGINT from shortening the wait.
// Returns the microseconds slept (at least `us` when no signal cuts it
// short).  A us of 0 or less returns at once.
def nap_us(us: long) -> long {
    let left = us;
    let slept = 0;
    // The turns cap is a belt-and-braces guard: a storm of signals must
    // not spin this loop forever.
    let turns = 0;
    while (left > 0 && turns < 64) {
        let s = left / 1000000;
        tm_ts[0] = s;
        tm_ts[1] = (left - s * 1000000) * 1000;
        let r = syscall(35, &tm_ts[0], &tm_rm[0]);
        if (r == 0) {
            left = 0;
        } else {
            left = tm_rm[0] * 1000000 + tm_rm[1] / 1000;
        };
        turns = turns + 1;
    };
    slept + us - left
};

// ── the pacer ────────────────────────────────────────────────────────────

type Pacer = { period_us: long, sched: long, frames: long, dropped: long, last: long };

// pacer_new(fps) -> Pacer -- a pacer for `fps` frames per second.  An fps
// below 1 (or above a million, whose period would round to 0) is clamped
// rather than left to divide by zero.
def pacer_new(fps: long) -> Pacer {
    let f = fps;
    if (f < 1) { f = 1; };
    let per = 1000000 / f;
    if (per < 1) { per = 1; };
    { period_us: per, sched: now_us(), frames: 0, dropped: 0, last: 0 }
};

// pacer_start(p) -- re-base the schedule on the clock now and zero the
// counters.  pacer_new() has already done this, so a second run of the
// animation is the only reason to call it.
def pacer_start(p: Pacer) {
    p.sched = now_us();
    p.frames = 0;
    p.dropped = 0;
    p.last = 0
};

// pacer_next(p) -> long -- one frame's wait.  See "the pacer contract".
// Returns the microseconds slept (draw now) or the negative lag (drop the
// frame).  Allocation-free: the deadline lives in the Pacer record.
def pacer_next(p: Pacer) -> long {
    p.sched = p.sched + p.period_us;
    let d = p.sched - now_us();
    if (d <= 0 - p.period_us) {
        // At least a whole frame late: draw nothing and let the schedule
        // come back on its own, rather than trying to catch up.
        p.dropped = p.dropped + 1;
        p.last = d;
        d
    } else {
        let slept = 0;
        let left = d;
        while (left > 0) {
            // Keep 1 ms in hand (as badapple80x30.y does), so that a small
            // overshoot cannot stretch the schedule.
            let sl = left;
            if (left > 1200) { sl = left - 1000; };
            nap_us(sl);
            slept = slept + sl;
            left = p.sched - now_us();
        };
        p.frames = p.frames + 1;
        p.last = left;
        slept
    }
};

// pacer_period_us(p) -> long -- the frame period in microseconds.
def pacer_period_us(p: Pacer) -> long { p.period_us };

// pacer_frames(p) -> long -- frames presented (not dropped).
def pacer_frames(p: Pacer) -> long { p.frames };

// pacer_dropped(p) -> long -- frames dropped for being late.
def pacer_dropped(p: Pacer) -> long { p.dropped };

// pacer_lag_us(p) -> long -- how late the last pacer_next() found the
// schedule: 0 or negative, and negative whenever a frame was dropped.
def pacer_lag_us(p: Pacer) -> long { p.last };

// ── the rate meter ───────────────────────────────────────────────────────
//
// A frame counter with a window.  Call fps_tick once per frame *drawn* (not
// per frame scheduled), then read the rate.  Rates are hundredths of a
// frame per second, because there is no float -> long (§2.4a): 3000 is
// 30.00 fps.  fps_line() does the formatting for a status line.

type Fps = { win_us: long, t_beg: long, t0: long, f0: long, n: long, x100: long };

// fps_new(win_us = 500000) -> Fps -- a meter over windows of `win_us`
// microseconds (half a second by default).  A window shorter than a
// millisecond is raised to one, so a rate is never divided by nothing.
def fps_new(win_us: long = 500000) -> Fps {
    let w = win_us;
    if (w < 1000) { w = 1000; };
    let t = now_us();
    { win_us: w, t_beg: t, t0: t, f0: 0, n: 0, x100: 0 }
};

// fps_tick(f) -- count one drawn frame, and close the window when it is
// full.  Allocation-free, one clock read.
def fps_tick(f: Fps) {
    f.n = f.n + 1;
    let t = now_us();
    let d = t - f.t0;
    if (d >= f.win_us) {
        f.x100 = (f.n - f.f0) * 100000000 / d;
        f.t0 = t;
        f.f0 = f.n;
    }
};

// fps_x100(f) -> long -- the rate over the last completed window, in
// hundredths of a frame per second; 0 until the first window closes.
def fps_x100(f: Fps) -> long { f.x100 };

// fps_frames(f) -> long -- frames counted since fps_new().
def fps_frames(f: Fps) -> long { f.n };

// fps_avg_x100(f) -> long -- the rate since fps_new(), in hundredths of a
// frame per second.  Before the first frame it reports the window rate
// rather than dividing by a zero-length span.
def fps_avg_x100(f: Fps) -> long {
    let d = now_us() - f.t_beg;
    if (d < 1000) { f.x100 } else { f.n * 100000000 / d }
};

// fps_line(f) -> str -- "29.94 fps now, 29.97 avg over 300 frames", for a
// status line at the end of a run.  This one allocates (it builds a
// string); it is not for a per-frame path.
def fps_line(f: Fps) -> str {
    f"{fps_x100(f) / 100.0:.2f} fps now, {fps_avg_x100(f) / 100.0:.2f} avg over {fps_frames(f)} frames"
};

export { now_us, now_ms, nap_us, Pacer, pacer_new, pacer_start, pacer_next, pacer_period_us, pacer_frames, pacer_dropped, pacer_lag_us, Fps, fps_new, fps_tick, fps_x100, fps_frames, fps_avg_x100, fps_line };
