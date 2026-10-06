// dsp.y -- the synthesiser, in integer fixed point, for `audio`.
//
// WHY INTEGER AND NOT FLOAT.  Y has no `float` -> `long` conversion and no
// cast syntax at all (ORCHESTRATOR.md section 2.4a), and no `sin`, `exp`,
// `pow` or `sqrt` in the language at all (2.4b).  A number a program
// computes therefore cannot leave a float, and an oscillator cannot call a
// library sine.  So everything here is a `long`, and every real number is a
// Q30 value: v holds v / 2^30.  The vendored `fx.y` is the only source of
// trigonometry, and it is used **once**, at start-up, to fill four wavetables.
// The per-sample path -- the part that runs 72000 times per render -- is a
// table read, an integer interpolate, an integer multiply and an add.  That
// is what a wavetable oscillator *is*, and doing it this way makes it literal
// rather than metaphorical.
//
// THE FORMAT, in one place:
//     fx.ONE        = 2^30 = 1073741824    1.0
//     phase         Q30 turns, wrapped to [0, fx.ONE)
//     table entry   Q30 sample, in [-fx.ONE, fx.ONE]
//     osc_inc       Q30 turns per sample = freq_hz * fx.ONE / rate
//     amp / pan     Q30
//     a sample      Q30 until the last step, quantised to s16 once
//
// WHY THE PHASE WRAPS THE WAY IT DOES.  `osc_step` adds the increment and
// subtracts fx.ONE when it passes it.  That is a single conditional subtract
// and it is exact, because a Q30 turn is bounded by 1.0 and an increment is
// always well below 0.5 (the highest note here is 784 Hz at 48000 Hz, an
// increment of 0.0163 turns).  No modulo, no division, no drift.
//
// WHY THE SCORE IS DATA, NOT CODE.  The note list is a module-level array
// built once, and the render loop reads it.  A literal array or record
// inside a loop body allocates on every iteration (ORCHESTRATOR.md 2.7) and
// the heap is an arena that never frees, so every one of the 72000 samples
// would leak.  Nothing in the render loop allocates: every buffer here is a
// fixed literal-sized array created at module load.

import fx;

// ── the format ────────────────────────────────────────────────────────────
const RATE: long = 48000;           // Hz; the rate every table and check uses
const CHANNELS: long = 2;           // stereo, interleaved
const BITS: long = 16;              // s16, little endian in the file
const FULL: long = 32767;           // the largest positive s16
const TBL_N: long = 4096;           // wavetable length; a literal, array sizes need one
const TBL_STRIDE: long = 4097;      // TBL_N + 1: the last entry repeats the first
const MAXV: long = 16;              // the most voices a score may carry
const MAXF: long = 96000;           // the most frames a render may hold (2.0 s at 48000)
const P30: long = 1073741823;       // 2^30 - 1, the fractional mask (fx.FRAC_MASK)

// The four waves, as indices into the one table array below.
const W_SINE: long = 0;
const W_TRI: long = 1;
const W_SAW: long = 2;
const W_SQR: long = 3;
const NWAVE: long = 4;

// ── the wavetable ─────────────────────────────────────────────────────────
//
// One flat array, four waves, TBL_STRIDE entries each.  A table is a pure
// function of its index, so it is filled once at load and never touched
// again -- which is also what makes a "wrong table entry" injectable as a
// one-character change.
let tab: [long] = [];
let tab_ready = false;

// Q30 index -> Q30 sample, for one wave.  Every branch is integer arithmetic;
// the only call into fx is the sine, and only at table-build time.
def wave_at(w: long, i: long) -> long {
    let r = 0;
    if (w == W_SINE) {
        r = fx.sin((i * fx.TWO_PI) / TBL_N);
    } else if (w == W_TRI) {
        // Triangle, peak at the quarter turn: 0 -> +1 at N/4 -> -1 at 3N/4 -> 0.
        let q = i;
        if (q >= 3 * (TBL_N / 4)) { q = q - TBL_N; };
        if (q <= TBL_N / 4) {
            r = (4 * q * fx.ONE) / TBL_N;
        } else {
            r = 2 * fx.ONE - (4 * q * fx.ONE) / TBL_N;
        };
    } else if (w == W_SAW) {
        r = (2 * i * fx.ONE) / TBL_N - fx.ONE;
    } else {
        // Square: a hard sign, so its RMS is exactly its amplitude -- which is
        // the identity the property battery checks against.
        if (i < TBL_N / 2) { r = fx.ONE; } else { r = 0 - fx.ONE; };
    };
    r
};

// Fill the table.  4 * 4097 = 16388 entries, so a few hundred thousand
// instructions once per process.  Answers whether the table is ready.
def table_build() -> bool {
    if (tab_ready) { return true; };
    tab = [];
    let w = 0;
    while (w < NWAVE) {
        let i = 0;
        while (i < TBL_N) {
            tab += wave_at(w, i);
            i = i + 1;
        };
        // The wrap entry, so the interpolator can read i + 1 at the last cell.
        tab += wave_at(w, 0);
        w = w + 1;
    };
    tab_ready = true
};

// tab_read(w, phase) -- the oscillator's body: locate the cell, then read or
// interpolate it.
//
// `t = phase * TBL_N` puts the Q30 turn at Q30 *cells*: `t >> 30` is the cell
// index in 0..TBL_N-1 and `t & P30` is the Q30 position inside it.  Both fall
// out of one multiply, and the product cannot overflow (phase < 2^30 and
// TBL_N < 2^13, so t < 2^43).
//
// THE SQUARE AND THE SAWTOOTH ARE SAMPLED, NOT INTERPOLATED, and that is the
// one place this function is not uniform.  Both tables are DISCONTINUOUS --
// one at a half turn, the other at the wrap -- and interpolating across a
// discontinuity is not an approximation of anything: it smears the edge over a
// whole cell.  Measured: with the interpolation applied, a square of amplitude
// 20000 came back with an RMS of 19944 instead of 20000, because the two edges
// of every 48-sample period were being rounded into one sample each.  The
// band-limiting that stops a square from aliasing is done by BAND-LIMITING THE
// TABLE, not by smoothing the read, so nothing is lost by not smoothing here.
//
// The last cell.  `osc_step` already guarantees i < TBL_N, so the guard cannot
// fire on any path the program takes -- it is here because an out-of-range
// index is a trap on stdout (which would corrupt a diff) and the guard costs
// one comparison against an unbounded failure.
def tab_read(w: long, phase: long) -> long {
    let t = phase * TBL_N;
    let i = t >> 30;
    let f = t & P30;
    if (i >= TBL_N) { i = TBL_N - 1; };
    let base = w * TBL_STRIDE;
    if (w == W_SQR || w == W_SAW) { return tab[base + i]; };
    let a = tab[base + i];
    let b = tab[base + i + 1];
    a + fx.mul(b - a, f)
};

// ── the oscillator ────────────────────────────────────────────────────────

// osc_inc(freq_hz, rate): Q30 turns per sample.  A plain integer division of
// a scaled numerator, which is what a fixed-point quotient is -- NOT `a / b`
// on two Q30 values, which returns the bare ratio (ORCHESTRATOR.md 2.15).
def osc_inc(freq_hz: long, rate: long) -> long {
    (freq_hz * fx.ONE) / rate
};

// osc_inc_chz(chz, rate): the same, from a frequency in CENTIHERTZ.
//
// The score stores centihertz, because 440 Hz is not A4 to the byte and a
// note table of `44000` says so where `440` only looks like it does.  Dividing
// by `rate * 100` rather than by `rate` is the entire difference between A4
// sounding like A4 and sounding like a bird -- and it is a mistake that
// announces itself as an out-of-bounds index rather than as a wrong number,
// because an increment above 1.0 turn per sample needs more than one wrap and
// the single conditional subtract below does not do that.  `render` refuses
// any voice whose increment leaves (0, 1), so this cannot reach the table read.
def osc_inc_chz(chz: long, rate: long) -> long {
    (chz * fx.ONE) / (rate * 100)
};

// osc_step: advance a phase by one sample, wrapping exactly.
//
// The wrap is ONE conditional subtract, and it is exact only while the
// increment is below half a turn.  That invariant is checked where the
// increment is computed, not here, because checking it per sample would cost
// more than the whole oscillator.
def osc_step(phase: long, inc: long) -> long {
    let p = phase + inc;
    if (p >= fx.ONE) { p = p - fx.ONE; };
    p
};

// ── the one-pole lowpass ──────────────────────────────────────────────────
//
// y[n] = y[n-1] + a * (x[n] - y[n-1]),  a = 1 - exp(-2*pi*fc/fs)
//
// There is no exp, so a is the Taylor series of 1 - exp(-x) with
// x = 2*pi*fc/fs, evaluated in Q30 with fx.mul:
//
//     a = x * (1 - x/2 + x^2/6 - x^3/24 + x^4/120 - x^5/720 + x^6/5040)
//
// The series is taken to x^7/5040, i.e. six terms inside the bracket, and the
// first term dropped is x^8/40320.  At the largest cutoff this example accepts
// (12000 Hz at 48000 Hz, x = 1.5708) that is 1.2e-4 of a coefficient near
// 0.79, so the cutoff is right to about 1 part in 7000.  Truncating at x^5/120
// instead -- five terms, the obvious choice -- is out by 2.2% there, which is
// audible as a duller filter and is exactly the sort of thing a golden file
// cannot see.
//
// The Taylor coefficients are the same Q30 values fx.y uses for its own
// polynomials (C_1_2 .. C_1_5040); fx does not export them, so they are
// written here.  Two mistakes are worth recording, because both are silent:
// the first draft used 3006477107 for 1/120, which is 2.8 rather than 0.0083;
// and the Horner was written in u = x^2 rather than in x, which evaluates
// 1 - x^2/2 + x^4/6 - ... and so computes something near 1.0 where 0.94 was
// wanted.  Both still "work" as a filter.  That is why the battery measures
// the filter's behaviour rather than re-checking the formula.
const TC_1_5040: long = 213044;
const TC_1_720: long = 1491308;
const TC_1_120: long = 8947849;
const TC_1_24: long = 44739243;
const TC_1_6: long = 178956971;
const TC_1_2: long = 536870912;

// lp_coeff(fc_hz, rate): the one-pole coefficient for a cutoff in Hz.
//
// fc_hz <= 0 means NO FILTER, and answers exactly fx.ONE.  That has to be a
// special case rather than a consequence of the formula: at fc = 0 the series
// gives 0, and a one-pole with a = 0 has a transfer function of zero, so every
// sample would come out as silence.  The first draft did exactly that, and the
// symptom was a battery in which the "present and not silent" guards correctly
// refused every RMS comparison -- which is the guards earning their keep.
def lp_coeff(fc_hz: long, rate: long) -> long {
    if (fc_hz <= 0) { return fx.ONE; };
    let x = (2 * fx.PI * fc_hz) / rate;
    let c = TC_1_5040;
    c = 0 - TC_1_720 + fx.mul(x, c);
    c = TC_1_120 + fx.mul(x, c);
    c = 0 - TC_1_24 + fx.mul(x, c);
    c = TC_1_6 + fx.mul(x, c);
    c = 0 - TC_1_2 + fx.mul(x, c);
    c = fx.ONE + fx.mul(x, c);
    fx.mul(x, c)
};

// One sample of the filter.  `d = x - y` is bounded by 2*fx.ONE and a by
// fx.ONE, so the product is below 2^61 and fx.mul's fast path covers it.
def lp_step(y: long, x: long, a: long) -> long {
    y + fx.mul(x - y, a)
};

// ── the envelope ──────────────────────────────────────────────────────────
//
// Linear ADSR in Q30, with the three slopes and the four segment boundaries
// precomputed once per voice, so the per-sample cost is a compare and one
// multiply and there is no division anywhere in the render loop.
type Voice = {
    wave: long, chz: long, det: long,      // wave kind, centihertz, right-channel detune
    s0: long,                              // first sample of the note
    aend: long, dend: long, rel0: long, snd: long,   // segment boundaries, absolute
    ia: long, idr: long, ir: long,         // ONE/attack, decay slope, ONE/release
    sus: long,                             // sustain level, Q30
    gl: long, gr: long                     // the two pan gains, Q30
};

let voices: [Voice] = [];
let nvoices = 0;
let voices_refused = 0;
let voices_bad = 0;              // voices whose increment left (0, ONE)

// voice_add -- turn one score note into a voice.  at_ms / ms / a_ms / d_ms /
// r_ms are milliseconds, amp / pan / sus are Q30, chz is centihertz, det is
// the right channel's start offset in Q30 turns.
//
// The segment boundaries are clamped so a note shorter than its own attack
// still has a well-ordered envelope: the attack ends no later than the decay,
// and the decay no later than the sound itself.  Without that an ADSR can run
// its release before its sustain and the envelope is not a function of time.
// Answers 1 when the voice was taken, 0 when the score was full.
def voice_add(wave: long, chz: long, at_ms: long, ms: long,
              amp: long, pan: long, det: long,
              sus: long, a_ms: long, d_ms: long, r_ms: long) -> long {
    if (nvoices >= MAXV) {
        voices_refused = voices_refused + 1;
        return 0;
    };
    let rate = RATE;
    let s0 = (at_ms * rate) / 1000;
    let body = (ms * rate) / 1000;
    let aa = if (a_ms <= 0) { 1 } else { (a_ms * rate) / 1000 };
    let da = if (d_ms <= 0) { 0 } else { (d_ms * rate) / 1000 };
    let ra = if (r_ms <= 0) { 1 } else { (r_ms * rate) / 1000 };
    let aend = if (s0 + aa > s0 + body) { s0 + body } else { s0 + aa };
    let dend = if (aend + da > s0 + body) { s0 + body } else { aend + da };
    let rel0 = s0 + body;
    let snd = rel0 + ra;
    let ia = fx.ONE / (if (aa == 0) { 1 } else { aa });
    let span = if (dend <= aend) { 1 } else { dend - aend };
    let idr = if (span == 0) { 0 } else { (fx.ONE - sus) / span };
    let ir = if (ra == 0) { 0 } else { sus / ra };
    // Pans: left is full at pan = 0 and a quarter full at pan = 1, right the
    // mirror.  A note never disappears entirely, so no voice is ever silent.
    let gl = fx.mul(amp, fx.ONE - fx.mul(pan, 805306368));
    let gr = fx.mul(amp, fx.ONE - fx.mul(fx.ONE - pan, 805306368));
    let v: Voice = {
        wave: wave, chz: chz, det: det,
        s0: s0, aend: aend, dend: dend, rel0: rel0, snd: snd,
        ia: ia, idr: idr, ir: ir, sus: sus,
        gl: gl, gr: gr
    };
    voices += v;
    nvoices = nvoices + 1;
    1
};

// env_at(v, n): the envelope of voice v at absolute sample n, in Q30.
// Segments in order: attack (0 -> 1), decay (1 -> sus), sustain (sus),
// release (sus -> 0).  Outside the note it is exactly 0, and the last sample
// of the release is exactly 0, so a note cannot leave a DC step behind.
//
// THE ONE SUBTLETY, and it cost this example its whole envelope once.  A slope
// like `ia = fx.ONE / attack_samples` is a Q30 value -- Q30 units of envelope
// per sample -- while `t` is a plain count of samples.  `fx.mul(t, ia)` is
// therefore a Q30 times a Q30, and it treats the sample COUNT as a fraction of
// a second: for an attack of 960 samples, fx.mul(959, 1118481) is 0, not
// 0.999.  fx.mul's own contract is correct; the caller has to scale, so the
// count is lifted into Q30 first: fx.mul(t * fx.ONE, ia).  The symptom is not
// a wrong envelope, it is a silent one, and it is invisible in a golden file
// because the output is still perfectly deterministic.
def env_at(v: Voice, n: long) -> long {
    if (n < v.s0 || n >= v.snd) { return 0; };
    let t = n - v.s0;
    let e = 0;
    if (n < v.aend) {
        e = fx.mul(t * fx.ONE, v.ia);
        if (e > fx.ONE) { e = fx.ONE; };
    } else if (n < v.dend) {
        let d = fx.mul((t - (v.aend - v.s0)) * fx.ONE, v.idr);
        e = fx.ONE - d;
        if (e < v.sus) { e = v.sus; };
    } else if (n < v.rel0) {
        e = v.sus;
    } else {
        let r = fx.mul((n - v.rel0) * fx.ONE, v.ir);
        e = v.sus - r;
        if (e < 0) { e = 0; };
    };
    e
};

// ── the render ────────────────────────────────────────────────────────────

// The sample buffers.  Fixed, literal-sized, module level: the render loop
// must not allocate, because the heap is an arena and nothing is ever freed.
let bufL: [long; 96000] = [0; 96000];
let bufR: [long; 96000] = [0; 96000];
let lframes = 0;

// The lowpass state, one per channel, carried across the whole render.
let lp_a: long = 0;
let lp_y: [long; 2] = [0; 2];

// render(frames, rate, fc_hz) -- mix every voice into bufL/bufR, then filter.
//
// Termination, spelled out because there is no `break` in Y and the exit
// condition is the whole proof: `n` starts at 0 and rises by exactly 1 each
// iteration while `n < frames`, and `frames` is at most MAXF.  The inner loop
// likewise advances `k` by 1 each pass while `k < nvoices`, and `nvoices` is
// at most MAXV because voice_add refuses past that.  So the render is at most
// MAXF * MAXV inner iterations, 1.54 million, and it allocates nothing.
def render(frames: long, rate: long, fc_hz: long) -> long {
    table_build();
    // Clear exactly the frames in use.  A fixed array is already zero at load,
    // but a second render into the same buffer must not inherit the first.
    let n = 0;
    while (n < frames) { bufL[n] = 0; bufR[n] = 0; n = n + 1; };
    lframes = frames;
    let a = lp_coeff(fc_hz, rate);
    lp_a = a;
    lp_y[0] = 0;
    lp_y[1] = 0;
    // One phase accumulator per voice per channel, in fixed flat arrays, and
    // the per-voice increment precomputed: nothing is allocated per sample.
    let ph: [long; 16] = [0; 16];
    let pr: [long; 16] = [0; 16];
    let inc: [long; 16] = [0; 16];
    voices_bad = 0;
    let k = 0;
    while (k < nvoices) {
        let v: Voice = voices[k];
        let step = osc_inc_chz(v.chz, rate);
        if (step > 0 && step < fx.ONE) {
            inc[k] = step;
        } else {
            // The wrap in osc_step is one conditional subtract, which is only
            // exact below half a turn.  A voice outside (0, 1) is therefore
            // refused here, counted, and left silent -- never handed to the
            // table read, where it would be an index out of bounds and a trap
            // on stdout.  A note of 0 Hz or of more than the sample rate is a
            // bug in the score, and this is where it stops.
            inc[k] = 0;
            voices_bad = voices_bad + 1;
        };
        ph[k] = 0;
        // The right channel starts a fraction of a sample away: a detune of a
        // few hundred Q30 units is a fraction of a microsecond, far below
        // audibility, and it is what makes the image wider than the pan alone.
        pr[k] = if (v.det >= 0) { v.det } else { v.det + fx.ONE };
        if (pr[k] >= fx.ONE) { pr[k] = 0; };
        k = k + 1;
    };
    n = 0;
    while (n < frames) {
        let sl = 0;
        let sr = 0;
        k = 0;
        while (k < nvoices) {
            let v: Voice = voices[k];
            if (inc[k] != 0 && n >= v.s0 && n < v.snd) {
                let e = env_at(v, n);
                let el = fx.mul(tab_read(v.wave, ph[k]), fx.mul(e, v.gl));
                let er = fx.mul(tab_read(v.wave, pr[k]), fx.mul(e, v.gr));
                sl = sl + el;
                sr = sr + er;
                ph[k] = osc_step(ph[k], inc[k]);
                pr[k] = osc_step(pr[k], inc[k]);
            };
            k = k + 1;
        };
        // One-pole lowpass per channel, its state carried across samples.
        lp_y[0] = lp_step(lp_y[0], sl, a);
        lp_y[1] = lp_step(lp_y[1], sr, a);
        bufL[n] = lp_y[0];
        bufR[n] = lp_y[1];
        n = n + 1;
    };
    frames
};

// frames_ok(n, rate): the only gate on a length.  Everything that indexes a
// buffer goes through here first, so an out-of-range render is a refusal with
// a message rather than a trap on stdout.
def frames_ok(n: long, rate: long) -> bool {
    if (n <= 0 || n > MAXF) { return false; };
    if (rate < 8000 || rate > 96000) { return false; };
    true
};

// ── quantisation ──────────────────────────────────────────────────────────

// q_to_s16(x): a Q30 sample to an s16, rounded half away from zero and
// clamped to the representable range.  fx.round() is exact and
// odd-symmetric; the clamp is the thing that stops a hot mix wrapping to a
// loud click instead of flat-topping.
def q_to_s16(x: long) -> long {
    let s = fx.to_int(fx.round(x * FULL));
    if (s > FULL) { s = FULL; };
    if (s < 0 - FULL - 1) { s = 0 - FULL - 1; };
    s
};

// ── analysis, from the bytes ──────────────────────────────────────────────
//
// Every measurement below reads the **bytes that were written**, decoding the
// little-endian s16 pairs itself.  That is deliberate: computing the RMS of a
// render from the Q30 buffers would be asking the code under test to confirm
// itself, and a value held in two places can agree while both are wrong.
// Decoding the file means a byte-order bug, a channel swap or an off-by-one
// frame count all show up here.

type Stat = {
    frames: long, sum: long, sumsq: long, peak: long, cross: long,
    nonzero: long, lsum: long, rsum: long
};

// le16(b, i): one signed 16-bit little-endian sample.  A byte is unsigned,
// so the sign is applied by hand at the end; a `>>` into the sign would be
// an arithmetic shift on a `long` and would work, but writing it this way
// keeps the byte math visible.
def le16(b: [byte], i: long) -> long {
    let v = b[i] + 256 * b[i + 1];
    if (v >= 32768) { v - 65536 } else { v }
};

// stats(b, off, frames): measure the interleaved s16 stereo stream at byte
// offset `off`.  `b` is the WHOLE wav image, header included, so `off` is 44
// for a file written by wav_write -- and the caller must pass a length that
// the image can actually hold, or this reads past the end and traps.
def stats(b: [byte], off: long, frames: long) -> Stat {
    let st: Stat = {
        frames: frames, sum: 0, sumsq: 0, peak: 0, cross: 0,
        nonzero: 0, lsum: 0, rsum: 0
    };
    let n = 0;
    let lastsign = 0;
    while (n < frames) {
        let p = off + n * 4;
        let l = le16(b, p);
        let r = le16(b, p + 2);
        let ml = if (l < 0) { 0 - l } else { l };
        let mr = if (r < 0) { 0 - r } else { r };
        if (ml > st.peak) { st.peak = ml; };
        if (mr > st.peak) { st.peak = mr; };
        st.sum = st.sum + l + r;
        st.sumsq = st.sumsq + l * l + r * r;
        st.lsum = st.lsum + l;
        st.rsum = st.rsum + r;
        if (l != 0) { st.nonzero = st.nonzero + 1; };
        // A zero-crossing count that remembers the last non-zero sign, so a
        // sample that lands exactly on zero at the crossing still counts once.
        if (l > 0 && lastsign < 0) { st.cross = st.cross + 1; };
        if (l < 0 && lastsign > 0) { st.cross = st.cross + 1; };
        if (l > 0) { lastsign = 1; };
        if (l < 0) { lastsign = 0 - 1; };
        n = n + 1;
    };
    st
};

// stats1(b, off, frames): the same, for the LEFT CHANNEL alone.
//
// The RMS, peak, DC and zero-crossing identities are per-channel statements --
// "a sine of amplitude A has RMS A/sqrt(2)" is about one channel of samples,
// not about the sum of two -- so they have to be measured on one channel.
// Averaging both channels instead folds in the stereo pan law, whose two gains
// always sum to 1.25*amp, and put every one of the four identities out by a
// factor of sqrt(1.0625/2) = 0.729 with nothing else wrong.  The two-channel
// view above is still what the DC and stereo checks use.
def stats1(b: [byte], off: long, frames: long) -> Stat {
    let st: Stat = {
        frames: frames, sum: 0, sumsq: 0, peak: 0, cross: 0,
        nonzero: 0, lsum: 0, rsum: 0
    };
    let n = 0;
    let lastsign = 0;
    while (n < frames) {
        let p = off + n * 4;
        let l = le16(b, p);
        let m = if (l < 0) { 0 - l } else { l };
        if (m > st.peak) { st.peak = m; };
        st.sum = st.sum + l;
        st.sumsq = st.sumsq + l * l;
        st.lsum = st.lsum + l;
        st.rsum = st.rsum + le16(b, p + 2);
        if (l != 0) { st.nonzero = st.nonzero + 1; };
        if (l > 0 && lastsign < 0) { st.cross = st.cross + 1; };
        if (l < 0 && lastsign > 0) { st.cross = st.cross + 1; };
        if (l > 0) { lastsign = 1; };
        if (l < 0) { lastsign = 0 - 1; };
        n = n + 1;
    };
    st
};
export {
    RATE, CHANNELS, BITS, FULL, TBL_N, TBL_STRIDE, MAXV, MAXF,
    W_SINE, W_TRI, W_SAW, W_SQR, NWAVE,
    tab, tab_ready, table_build, wave_at, tab_read,
    osc_inc, osc_inc_chz, osc_step, lp_coeff, lp_step,
    voices, nvoices, voices_refused, voices_bad, voice_add, env_at, Voice,
    bufL, bufR, lframes, lp_a, render, frames_ok,
    q_to_s16, le16, stats, stats1, Stat
};
