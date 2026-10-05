// check.y -- the property battery for `audio`.
//
// WHY A BATTERY AND NOT A BIGGER GOLDEN FILE.  A golden file proves
// determinism and nothing else.  `cube` cleared the whole gate while rendering
// filled wedges, because its EXPECTED had been captured from the broken
// output.  Every assertion below is therefore checked against something the
// program does not compute for itself:
//
//   * an ANALYTIC IDENTITY  -- the RMS of a sine is A/sqrt(2), the RMS of a
//     square is A, the RMS of a triangle and of a sawtooth are A/sqrt(3).  Those
//     are facts about mathematics, not about this code, and they are the
//     strongest checks here.
//   * the BYTES ON DISK     -- RMS, peak, DC offset and zero crossings are
//     measured from the s16 pairs in the written WAV, decoded independently,
//     so a byte-order bug, a channel swap or an off-by-one frame count all
//     show up.  Measuring the Q30 buffers instead would be asking the code
//     under test to confirm itself.
//   * a SCRIPTED SINK       -- the short-write arithmetic of snd_pcm_writei,
//     tested against sinks that return half, one frame at a time, nothing at
//     all, EPIPE twice, and more than they were asked for.  A real device
//     rarely short-writes on demand, so this is the only way to test it at all.
//
// THE STANDING RULE, and it is the campaign's: assert a value is PRESENT AND
// NON-ZERO before comparing it.  Two agents here shipped vacuous passes -- one
// asked "did the ones that open match?" which is trivially true when nothing
// opens, another compared heap_used() to itself.  So every measured block
// starts with its own presence check, and "silence is silent" is paired with a
// check that the same code path on a non-silent piece is NOT silent.

import args;
import fx;
import fs;
import crypto;
import dsp;
import wav;
import pcm;

let checks = 0;
let failed = 0;

// prep_calls counts the PREPARE calls the battery's own prep function made.
// Declared up here because check_feed is defined above the H section and Y
// resolves module-level names in declaration order.
let prep_calls: long = 0;

def ck(name: str, ok: bool, detail: str) {
    checks = checks + 1;
    if (ok) {
        print("  ok    " + name);
        if (detail != "") { print("          " + detail); };
    } else {
        failed = failed + 1;
        print("  FAIL  " + name);
        print("          " + detail);
    }
};

def ck_eq(name: str, got: long, want: long) {
    ck(name, got == want, "got " + tostring(got) + ", want " + tostring(want))
};

def ck_near(name: str, got: long, want: long, tol: long) {
    let d = got - want;
    if (d < 0) { d = 0 - d; };
    ck(name, d <= tol, "got " + tostring(got) + ", want " + tostring(want) +
       " +/- " + tostring(tol))
};

// one_ms(x): a Q30 value as integer millionths, for tolerances.
def micro(q: long) -> long { (q * 1000000) / fx.ONE };

// ── the scratch directory ────────────────────────────────────────────────
//
// The degradation paths need a directory that is not /dev/snd, because a
// machine with no sound hardware has no /dev/snd to point at and the
// behaviour there has to be identical to here.  Three directories are built
// under ./audio-check-tmp: an empty one, one with a regular file called
// pcmC9D9p (which opens but answers ENOTTY to INFO, exercising the
// "this is not a PCM device" refusal), and one with that file chmod 000
// (which gives a real EACCES).  All three are removed afterwards.
const TMP: str = "audio-check-tmp";

def tmp_mk() {
    fs.remove_all(TMP);
    fs.make_dirs(TMP)
};

def tmp_rm() { fs.remove_all(TMP) };

// ── a scratch render, so the battery does not disturb the demo ────────────

// render_one(wave, chz, amp_s16, frames, cutoff): one flat voice, no filter,
// and the SHORTEST attack and release the language allows -- one sample each,
// because voice_add clamps a zero-length segment to a sample.  That matters
// for the identities: a 1 ms attack and release is 96 samples of linear ramp
// whose mean square is a third of full, which costs 0.067% of the RMS and
// put every expectation 13 LSB out.  One sample of ramp in 48000 costs
// nothing measurable.  `amp_s16` is in s16 units --
// the same units the identities are stated in -- and is lifted into Q30 by the
// only route that is exact: multiply by fx.ONE and divide by full scale.
//
// The pan is ZERO, which for this pan law means FULL amplitude on the left and
// a quarter on the right.  That is why every measurement here is taken from
// the left channel alone: the two gains always sum to 1.25*amp, so there is no
// pan at which both channels carry `amp_s16`, and a pan of fx.ONE/2 makes every
// identity 0.625 of its target with a peak that still looks right.
//
// Note what the first draft got wrong: it read `amp` as THOUSANDTHS and then
// divided by 1000, so an amplitude of 20000 became 20.0 in Q30 -- twenty times
// full scale.  Every render saturated, every RMS came back as the RMS of a
// clipped square wave, and the four identities all failed by a factor of 2.2
// with no other symptom.  The battery caught it because the expectations are
// analytic rather than recorded.
def render_one(wave: long, chz: long, amp_s16: long, frames: long,
               cutoff: long) -> long {
    dsp.nvoices = 0;
    dsp.voices_refused = 0;
    dsp.voices = [];
    let ok = dsp.voice_add(wave, chz, 0, frames * 1000 / dsp.RATE,
                           (amp_s16 * fx.ONE) / dsp.FULL, 0, 0,
                           fx.ONE, 0, 0, 0);
    if (ok != 1) { return 0; };
    dsp.render(frames, dsp.RATE, cutoff);
    wav.wav_build(frames, dsp.RATE, dsp.CHANNELS, dsp.BITS)
};

// snap(): take ONE copy of the image and measure that from here on.  The
// measurements are four passes over the file, and taking a fresh slice for each
// would allocate four copies per fixture in a heap that never frees -- so the
// copy is taken once per fixture, explicitly, right after the render.
let img: [byte] = [];

def snap() {
    img = wav.image()
};

// pan_note(wave, chz, amp_s16, frames, pan_q30): one voice at an explicit pan,
// for the stereo checks.  A pan of 0 is full in BOTH channels (this pan law
// never lets a channel reach zero) and fx.ONE/2 is 0.625 each, so "centred"
// here does not mean "equal and untouched" -- it means equal, at 0.625.
def pan_note(wave: long, chz: long, amp_s16: long, frames: long,
             pan_q30: long) -> long {
    dsp.nvoices = 0;
    dsp.voices = [];
    dsp.voice_add(wave, chz, 0, frames * 1000 / dsp.RATE,
                  (amp_s16 * fx.ONE) / dsp.FULL, pan_q30, 0, fx.ONE, 1, 0, 1);
    dsp.render(frames, dsp.RATE, 0);
    wav.wav_build(frames, dsp.RATE, dsp.CHANNELS, dsp.BITS);
    snap();
    1
};

// The identities below are per-channel statements, so they are measured on the
// LEFT channel, which this pan law holds at FULL amplitude.  rms_of divides by
// `frames` rather than by `frames * 2` for that reason: averaging two channels
// whose gains sum to 1.25*amp would put every RMS out by a factor of 0.729
// while the peak -- which is scale-free -- stayed perfect.  fx.isqrt is exact
// on a whole number, so the only error is the integer division inside it, at
// most one LSB of the answer.
def rms_of(frames: long) -> long {
    fx.isqrt(stat1_of(frames).sumsq / frames)
};

def peak_of(frames: long) -> long { stat1_of(frames).peak };

def dc_of(frames: long) -> long { stat1_of(frames).sum / frames };

def cross_of(frames: long) -> long { stat1_of(frames).cross };

def nonzero_of(frames: long) -> long { stat1_of(frames).nonzero };

def stat1_of(frames: long) -> dsp.Stat { dsp.stats1(img, wav.HDR, frames) };

// stat_of is the two-channel view, used where the STEREO RELATIONSHIP is the
// thing being measured rather than the level.
def stat_of(frames: long) -> dsp.Stat { dsp.stats(img, wav.HDR, frames) };

// ── A. the container ──────────────────────────────────────────────────────
//
// The writer's answers are in the image and the values below are the ones the
// RIFF specification requires at those offsets, so this is not the writer
// agreeing with itself.
def check_container() {
    print("[A] the WAV container, parsed back out of the image");
    let total = wav.render_demo(wav.DEMO_CUTOFF);
    snap();
    ck("A00 the demo rendered", total > 0, tostring(total) + " bytes");
    if (total <= 0) { return; };
    let frames = wav.wav_frames;
    let h = wav.wav_read_hdr();
    ck("A01 'RIFF' at 0", h.riff_ok, wav.str_get(0));
    ck("A02 'WAVE' at 8", h.wave_ok, wav.str_get(8));
    ck("A03 'fmt ' at 12", h.fmt_ok, wav.str_get(12));
    ck("A04 'data' at 36", h.data_ok, wav.str_get(36));
    ck_eq("A05 fmt chunk size is 16", h.fmt_size, 16);
    ck_eq("A06 format is 1 (PCM)", h.format, 1);
    ck_eq("A07 channels", h.channels, dsp.CHANNELS);
    ck_eq("A08 sample rate", h.rate, dsp.RATE);
    ck_eq("A09 bits per sample", h.bits, dsp.BITS);
    ck_eq("A10 byte rate = rate*ch*2", h.byterate, dsp.RATE * dsp.CHANNELS * 2);
    ck_eq("A11 block align = ch*2", h.align, dsp.CHANNELS * 2);
    ck_eq("A12 data size = frames*4", h.data_size, frames * 4);
    ck_eq("A13 riff size = 36 + data", h.riff_size, 36 + h.data_size);
    ck_eq("A14 header is 44 bytes", wav.HDR, 44);
    ck_eq("A15 total = 44 + data", total, wav.HDR + h.data_size);
    // And the bytes that reached the disk agree with the bytes in memory.
    let path = TMP + "/a.wav";
    ck("A16 the image was written", wav.wav_save(path), path);
    ck_eq("A17 the file on disk is this long", wav.wav_size_on_disk(path), total);
    ck("A18 the file's sha256 is the image's sha256",
       wav.file_sha(path) == wav.image_sha(),
       wav.image_sha());
};

// ── B. quantisation ───────────────────────────────────────────────────────
//
// Every one of these is the conversion rule itself, checked on the values
// where a wrong rule gives a different answer: full scale, over full scale
// (which must clamp and not wrap), and the half-way cases (which must round
// away from zero and not to even).
def check_quant() {
    print("[B] Q30 -> s16 quantisation");
    ck_eq("B01 0.0 quantises to 0", dsp.q_to_s16(0), 0);
    ck_eq("B02 +1.0 is full scale", dsp.q_to_s16(fx.ONE), dsp.FULL);
    ck_eq("B03 -1.0 is -full scale", dsp.q_to_s16(0 - fx.ONE), 0 - dsp.FULL);
    ck_eq("B04 +2.0 clamps at full scale, does not wrap", dsp.q_to_s16(2 * fx.ONE),
          dsp.FULL);
    ck_eq("B05 -2.0 clamps at -32768, does not wrap",
          dsp.q_to_s16(0 - 2 * fx.ONE), 0 - dsp.FULL - 1);
    // -32768 is the most negative s16 and it has to be reachable, or a hot
    // mix cannot use the bottom of the range at all.  -(1 + 32768/2^30) times
    // 32767 is 32767.99997..., which rounds to 32768; 16384/2^30 gives exactly
    // 0.49999 and lands one short, which is why the bound is 32768 and not
    // the tidier 16384.
    ck_eq("B06 -32768 is reachable", dsp.q_to_s16(0 - fx.ONE - 32768),
          0 - dsp.FULL - 1);
    // Rounding, not truncation: every one of these lands on a fraction above
    // one half, where truncating toward zero would answer one LSB lower.
    // 0.5 * 32767 = 16383.5, 0.375 * 32767 = 12287.625.
    ck_eq("B07 +0.5 rounds up, not down", dsp.q_to_s16(fx.HALF), 16384);
    ck_eq("B08 -0.5 rounds away from zero", dsp.q_to_s16(0 - fx.HALF), -16384);
    ck_eq("B09 0.375 rounds to 12288", dsp.q_to_s16(fx.ONE * 3 / 8), 12288);
    ck_eq("B10 -0.375 rounds away from zero",
          dsp.q_to_s16(0 - fx.ONE * 3 / 8), -12288);
    ck_eq("B11 one LSB is one LSB", dsp.q_to_s16(fx.ONE / dsp.FULL), 1);
    ck_eq("B12 -one LSB is -one LSB", dsp.q_to_s16(0 - fx.ONE / dsp.FULL), -1);
};

// ── C. the oscillator, measured ───────────────────────────────────────────
//
// The table is compared against fx.sin -- a different algorithm (Taylor on a
// reduced argument) reached through a different path (a lookup and an
// interpolate) -- so this is a genuine cross-check of the oscillator rather
// than of itself.  4 Q30 units is 4/2^30 = 3.7e-9, and the linear
// interpolation error of a 4096-point table is (2*pi/4096)^2/8 = 2.9e-7, so
// the bound is set by the table and is deliberately generous.
def check_osc() {
    print("[C] the wavetable and the oscillator");
    dsp.table_build();
    let n = len(dsp.tab);
    ck("C01 the table is present", n == 4 * dsp.TBL_STRIDE,
       tostring(n) + " entries, want " + tostring(4 * dsp.TBL_STRIDE));
    ck_eq("C02 a sine starts at zero", dsp.tab[0], 0);
    ck_near("C03 a sine peaks at fx.ONE at the quarter turn",
            dsp.tab[1024], fx.ONE, 2);
    ck_near("C04 a sine is -fx.ONE at three quarters",
            dsp.tab[3072], 0 - fx.ONE, 2);
    // Odd symmetry: sin(t + pi) = -sin(t), exactly, for a table built by one
    // formula.  This is the check that a table built by two different code
    // paths would fail.
    let bad = 0;
    let i = 0;
    while (i < dsp.TBL_N) {
        let j = (i + dsp.TBL_N / 2) % dsp.TBL_N;
        if (dsp.tab[i] != 0 - dsp.tab[j]) { bad = bad + 1; };
        i = i + 1;
    };
    ck_eq("C05 the sine table is exactly odd-symmetric", bad, 0);
    // Monotone over the first quarter: a table with a hole or a stray entry
    // breaks this and nothing else short of comparing every entry would.
    let falls = 0;
    i = 0;
    while (i < dsp.TBL_N / 4) {
        if (dsp.tab[i + 1] < dsp.tab[i]) { falls = falls + 1; };
        i = i + 1;
    };
    ck_eq("C06 the first quarter rises monotonically", falls, 0);
    // The oscillator against fx.sin, over a whole turn.  The PHASE here is in
    // TURNS (that is what a wavetable oscillator carries) and fx.sin takes
    // RADIANS, so the comparison has to convert -- fx.mul does it without
    // overflow.  Skipping the conversion is not a subtle bug, it is a
    // spectacular one: fx.sin(x) is very nearly x for small x, so it "almost"
    // matches and the comparison fails by a factor of six.
    let worst = 0;
    let ph = 0;
    // 3000 phases, and NOT 2048 or 4096: a phase count that divides the table
    // length puts every sample exactly ON a cell, and then this would be
    // comparing the table with fx.sin and never touching the interpolator at
    // all.  3000 leaves most samples part-way between cells.
    let steps = 3000;
    let s = 0;
    while (s < steps) {
        let got = dsp.tab_read(dsp.W_SINE, ph);
        let want = fx.sin(fx.mul(ph, fx.TWO_PI));
        let e = got - want;
        if (e < 0) { e = 0 - e; };
        if (e > worst) { worst = e; };
        ph = ph + fx.ONE / steps;
        if (ph >= fx.ONE) { ph = ph - fx.ONE; };
        s = s + 1;
    };
    // The bound is the interpolator's own error, not an arbitrary one: linear
    // interpolation of a sine between points h apart is off by at most
    // (h^2)/8 * sin, which for 4096 points is (2*pi/4096)^2/8 = 2.9e-7 of full
    // scale = 311 Q30 units.  The bound is 400, and fx.sin's own 1.5e-9 (1.6
    // Q30 units) is inside that.
    ck("C07 the table oscillator tracks fx.sin in radians", worst <= 400,
       "worst error " + tostring(worst) + " Q30 units over " +
       tostring(steps) + " phases, bound 400 (the interpolation error of " +
       "a 4096-point table is 311)");
    // The phase accumulator: after a whole second at 1000 Hz the phase must be
    // back at zero to within one step.  A `a / b` that returned the bare ratio
    // instead of the fixed-point quotient would put the increment at 0 and
    // this would be 48000 rather than 0.
    let inc = dsp.osc_inc(1000, dsp.RATE);
    let walked = (inc * dsp.RATE) - fx.ONE * 1000;
    let aw = walked;
    if (aw < 0) { aw = 0 - aw; };
    ck("C08 osc_inc is a fixed-point quotient, not a ratio", aw < dsp.RATE,
       "1000 Hz at 48000 Hz: increment " + tostring(inc) +
       ", a whole second accumulates to " + tostring(inc * dsp.RATE) +
       " vs " + tostring(fx.ONE * 1000) + " wanted (drift " + tostring(aw) +
       " of one step)");
    // Wrapping: the phase must land in [0, ONE) for every start phase.
    let wrapped_bad = 0;
    ph = 0;
    let t = 0;
    while (t < 500) {
        let p2 = dsp.osc_step(ph, inc);
        if (p2 < 0 || p2 >= fx.ONE) { wrapped_bad = wrapped_bad + 1; };
        ph = p2;
        t = t + 1;
    };
    ck_eq("C09 the phase stays in [0, ONE)", wrapped_bad, 0);
    // 1 kHz over exactly one second is 1000 periods of 48 samples, so 2000
    // zero crossings -- except that the FIRST one falls on sample 0, which the
    // 1 ms attack makes exactly zero, and a counter that remembers the last
    // NON-ZERO sign cannot see a crossing into a sample that is zero.  So the
    // measured count is 1999, and 1999/2 = 999.5 Hz against a nominal 1000:
    // half a hertz out of a thousand, and it is the best any zero-crossing
    // count can do on a signal that starts at zero.  Measured from the file's
    // bytes, not from the oscillator's own state.
    render_one(dsp.W_SINE, 100000, 20000, dsp.RATE, 0);
    snap();
    ck_eq("C10 one second of 1 kHz sine has 1999 crossings",
          cross_of(dsp.RATE), 1999);
    let f_est = (cross_of(dsp.RATE) * dsp.RATE) / (2 * dsp.RATE);
    ck("C11 the crossing count implies the frequency", f_est == 999,
       "1999 crossings in 1 s over both edges = " + tostring(f_est) +
       " Hz against a nominal 1000 Hz");
};

// ── D. the analytic RMS identities ────────────────────────────────────────
//
// The four identities are textbook: a sine of amplitude A has RMS A/sqrt(2),
// a square of amplitude A has RMS A exactly, and a triangle and a sawtooth of
// amplitude A both have RMS A/sqrt(3).  They are properties of mathematics,
// so agreeing with them is evidence about the code and not an agreement
// between two copies of the same mistake.  sqrt(2) = 1.4142136 and
// sqrt(3) = 1.7320508; the expectations are integer so the comparison is too.
const A_T: long = 20000;             // the test amplitude, in s16 units
const EXPECT_SINE: long = 14142;     // 20000 / sqrt(2)
const EXPECT_SQR: long = 20000;      // 20000
const EXPECT_RAMP: long = 11547;     // 20000 / sqrt(3)

// sine_tol: the total budget for the sine identity: the Q30 quantisation of
// the table (2.9e-7), the truncated phase increment (under 1e-9 a turn, so
// under 2e-5 of a cycle over a second), and one LSB of the integer division
// inside isqrt.  At 14142 that is under 1 LSB of s16 in total; 12 is a
// deliberate margin over the arithmetic and still 0.08% of the answer.
// SINE_TOL: the whole budget for the sine identity is (a) the Q30 rounding of
// the table, (b) the truncated phase increment, under 1e-9 of a turn, so under
// 1e-6 of a cycle over a second, and (c) one LSB of the integer division
// inside isqrt.  Measured worst case over the whole second: 0 LSB.  The bound
// of 20 is 0.14% and is pure margin.
const SINE_TOL: long = 20;
// RAMP_TOL: 375 Hz gives 128 samples a period, where the discrete mean square
// of a linear ramp differs from the continuous 1/3 by 0.011%, so 60 LSB
// (0.52%) is five times the arithmetic.
const RAMP_TOL: long = 60;

def check_rms() {
    print("[D] RMS identities, measured from the written bytes");
    // Presence first: 48000 frames and a non-zero peak, BEFORE any RMS is
    // compared.  A buffer that rendered nothing has an RMS of 0 and every
    // identity below would "pass" in the sense of not trapping.
    let frames = dsp.RATE;
    render_one(dsp.W_SINE, 100000, A_T, frames, 0);
    snap();
    let pk = peak_of(frames);
    ck("D00 the sine render is present and not silent", pk > 0,
       "peak " + tostring(pk) + ", frames " + tostring(wav.wav_frames));
    ck_eq("D01 the sine render is exactly one second", wav.wav_frames, frames);
    ck_near("D02 a sine of amplitude A has RMS A/sqrt(2)", rms_of(frames),
            EXPECT_SINE, SINE_TOL);
    ck_near("D03 ... and its peak is A", peak_of(frames), A_T, 4);
    // The continuous identity is sum(sin) = 0 over whole periods, and the
    // measured mean is a couple of LSB rather than exactly zero.  The residue
    // is the one-sample envelope ramp at each end, which is not symmetric: the
    // note starts at zero amplitude and leaves at zero, but the sine under it
    // is not at the same phase at the two ends.  4 LSB of 20000 is 200 ppm.
    ck("D04 ... and its DC offset is under 4 LSB",
       0 - dc_of(frames) <= 4 && dc_of(frames) <= 4,
       "mean " + tostring(dc_of(frames)) + " LSB of " + tostring(A_T));
    // The square: amplitude A exactly, so RMS A to the bit.
    // The square: 1 kHz, so 48 samples a period, and it is SAMPLED rather
    // than interpolated (see tab_read), so its samples are exactly +-A and the
    // identity is exact rather than approximate.  That is the strongest check
    // in this group: rms == peak, to the bit.
    render_one(dsp.W_SQR, 100000, A_T, frames, 0);
    snap();
    ck("D10 the square render is present", peak_of(frames) > 0,
       "peak " + tostring(peak_of(frames)));
    // The identity, to one LSB.  The square table is SAMPLED rather than
    // interpolated, so every sample really is +-A, and the only reason RMS and
    // peak are not bit-identical is that the envelope's very first sample is
    // zero: sqrt(1 - 1/48000) is A - 0.2, which lands one LSB low.  For
    // comparison the sine differs from its own amplitude by 1.41 and the
    // triangle by 1.73, so a bound of 2 LSB -- 100 ppm -- separates "this is a
    // square" from "this is not a square" by three orders of magnitude.
    ck_near("D11 a square of amplitude A has RMS equal to its amplitude",
            rms_of(frames), peak_of(frames), 2);
    ck_near("D12 ... and that amplitude is A", peak_of(frames), A_T, 4);
    // The triangle and the sawtooth both integrate to A/sqrt(3).  375 Hz and
    // not 1000 Hz, because 375 Hz at 48000 is 128 samples a period -- and 128
    // samples a period is EXACTLY 32 wavetable cells a period, so every sample
    // lands on a cell the table holds and the peak is exactly A instead of
    // landing a fraction of a cell short of it.  48000 frames is then 375
    // WHOLE periods, so the discretised RMS and the continuous A/sqrt(3)
    // differ by 0.0055% rather than by the 0.2% they differ by at 1000 Hz.
    render_one(dsp.W_TRI, 37500, A_T, frames, 0);
    snap();
    ck("D20 the triangle render is present", peak_of(frames) > 0,
       "peak " + tostring(peak_of(frames)));
    ck_near("D21 a triangle of amplitude A has RMS A/sqrt(3)", rms_of(frames),
            EXPECT_RAMP, RAMP_TOL);
    ck_eq("D22 ... and its peak is A", peak_of(frames), A_T);
    render_one(dsp.W_SAW, 37500, A_T, frames, 0);
    snap();
    ck("D30 the sawtooth render is present", peak_of(frames) > 0,
       "peak " + tostring(peak_of(frames)));
    ck_near("D31 a sawtooth of amplitude A has RMS A/sqrt(3)", rms_of(frames),
            EXPECT_RAMP, RAMP_TOL);
    ck_near("D31b ... and its peak is A", peak_of(frames), A_T, 4);
    ck_near("D32 ... and its peak is A", peak_of(frames), A_T, 4);
    // Silence: all zero, and the buffer is the right length.  The pair is the
    // point -- a "silence is silent" check alone passes on an empty buffer.
    render_one(dsp.W_SINE, 100000, 0, frames, 0);
    snap();
    ck_eq("D40 a zero-amplitude render is exactly one second",
          wav.wav_frames, frames);
    ck_eq("D41 every sample of it is zero", rms_of(frames), 0);
    ck_eq("D42 ... and its peak is zero", peak_of(frames), 0);
    ck_eq("D43 ... and not one sample is non-zero",
          stat_of(frames).nonzero, 0);
    // And the same code path on a non-silent piece is NOT silent: the negative
    // control, so D40..D43 cannot be passing because the render does nothing.
    render_one(dsp.W_SINE, 100000, A_T, frames, 0);
    snap();
    ck("D44 the same render at amplitude A is not silent",
       stat_of(frames).nonzero > frames / 2,
       tostring(stat_of(frames).nonzero) + " of " +
       tostring(frames) + " frames non-zero");
};

// ── E. the envelope ───────────────────────────────────────────────────────
def check_env() {
    print("[E] the ADSR envelope");
    dsp.nvoices = 0;
    dsp.voices = [];
    let rate = dsp.RATE;
    // 400 ms of note at 48000 = 19200 samples: attack 20 ms, decay 60 ms,
    // sustain until 300 ms, release 100 ms.
    let at = 100;
    let v = dsp.voice_add(dsp.W_SINE, 44000, at, 400, fx.ONE, 500000, 0,
                         fx.ONE / 2, 20, 60, 100);
    ck("E00 the voice was taken", v == 1, "");
    if (v != 1) { return; };
    let vo: dsp.Voice = dsp.voices[0];
    let v_sus_2 = vo.sus;
    let s0 = (at * rate) / 1000;
    ck_eq("E01 the note starts where it was asked to", vo.s0, s0);
    ck_eq("E02 the attack ends after 20 ms", vo.aend - s0, 960);
    ck_eq("E03 the decay ends after 80 ms", vo.dend - s0, 3840);
    ck_eq("E04 the release starts at the note's end", vo.rel0 - s0, 19200);
    ck_eq("E05 the note ends after the release", vo.snd - s0, 24000);
    ck_eq("E06 one sample before the note is silent", dsp.env_at(vo, vo.s0 - 1), 0);
    ck_eq("E07 the last sample of the note is silent", dsp.env_at(vo, vo.snd), 0);
    ck_eq("E08 far past the note is silent", dsp.env_at(vo, vo.snd + 5000), 0);
    ck_eq("E09 the note starts at zero", dsp.env_at(vo, vo.s0), 0);
    // The attack is LINEAR IN SAMPLES, so the last sample before the corner is
    // one step short of unity by construction, not by error: the step is the
    // slope.  The invariant worth checking is that it is within one step.
    let e_atk = dsp.env_at(vo, vo.aend - 1);
    // Two steps, not one: the last attack sample is one step short by
    // construction, and fx.mul truncates, which is worth up to one more.
    ck("E10 the attack reaches full scale to within two sample steps",
       e_atk >= fx.ONE - 2 * vo.ia && e_atk <= fx.ONE,
       "got " + tostring(e_atk) + ", one step is " + tostring(vo.ia));
    // Monotonicity.  With no `break`, these are counted, not stopped: a counter
    // that rises on every violation and must be zero at the end.
    let bad_a = 0;
    let i = vo.s0;
    while (i < vo.aend - 1) {
        if (dsp.env_at(vo, i + 1) < dsp.env_at(vo, i)) { bad_a = bad_a + 1; };
        i = i + 1;
    };
    ck_eq("E11 the attack never falls", bad_a, 0);
    let bad_d = 0;
    i = vo.aend;
    while (i < vo.dend - 1) {
        if (dsp.env_at(vo, i + 1) > dsp.env_at(vo, i)) { bad_d = bad_d + 1; };
        i = i + 1;
    };
    ck_eq("E12 the decay never rises", bad_d, 0);
    let e_dec = dsp.env_at(vo, vo.dend - 1);
    ck("E13 the decay lands on the sustain level to within two steps",
       e_dec >= v_sus_2 && e_dec <= v_sus_2 + 2 * vo.idr,
       "got " + tostring(e_dec) + ", sustain " + tostring(v_sus_2) +
       ", one step " + tostring(vo.idr));
    ck_eq("E14 the sustain is held flat",
          dsp.env_at(vo, vo.rel0 - 1), fx.ONE / 2);
    let bad_r = 0;
    i = vo.rel0;
    while (i < vo.snd - 1) {
        if (dsp.env_at(vo, i + 1) > dsp.env_at(vo, i)) { bad_r = bad_r + 1; };
        i = i + 1;
    };
    ck_eq("E15 the release never rises", bad_r, 0);
    // Same story at the end of the release: the last sample before the note is
    // over is one step above zero, and the sample AT the end is exactly zero
    // (E07).  Together those are "the note leaves no DC step behind".
    let e_rel = dsp.env_at(vo, vo.snd - 1);
    ck("E16 the release ends within two steps of zero",
       e_rel >= 0 && e_rel <= 2 * vo.ir,
       "got " + tostring(e_rel) + ", one step is " + tostring(vo.ir));
    // No overshoot anywhere: the envelope is bounded by 1.
    let over = 0;
    i = vo.s0;
    while (i < vo.snd) {
        let e = dsp.env_at(vo, i);
        if (e > fx.ONE || e < 0) { over = over + 1; };
        i = i + 1;
    };
    ck_eq("E17 the envelope stays inside [0, ONE]", over, 0);
    // A note shorter than its own attack must not run its segments out of
    // order: the boundaries are clamped, and this is the check for it.
    dsp.nvoices = 0;
    dsp.voices = [];
    dsp.voice_add(dsp.W_SINE, 44000, 0, 2, fx.ONE, 500000, 0, fx.ONE / 2,
                  200, 200, 200);
    let tiny: dsp.Voice = dsp.voices[0];
    ck("E18 a 2 ms note with a 200 ms attack is still ordered",
       tiny.aend <= tiny.dend && tiny.dend <= tiny.rel0 &&
       tiny.rel0 < tiny.snd,
       "aend " + tostring(tiny.aend) + " dend " + tostring(tiny.dend) +
       " rel0 " + tostring(tiny.rel0) + " snd " + tostring(tiny.snd));
    ck_eq("E19 ... and its envelope is still monotone",
          dsp.env_at(tiny, 0), 0);
    // More notes than the buffer holds must be refused and counted, never
    // quietly dropped and never a write past the end of the array.
    dsp.nvoices = 0;
    dsp.voices_refused = 0;
    dsp.voices = [];
    let taken = 0;
    for k in 0..40 {
        taken = taken + dsp.voice_add(dsp.W_SINE, 44000, 0, 100, fx.ONE,
                                      500000, 0, fx.ONE, 5, 5, 20);
    };
    ck_eq("E20 no more than MAXV voices are taken", dsp.nvoices, dsp.MAXV);
    ck_eq("E21 the rest are refused and counted", dsp.voices_refused,
          40 - dsp.MAXV);
    ck_eq("E22 the voice array really is that long", len(dsp.voices), dsp.MAXV);
};

// ── F. the one-pole lowpass, measured ─────────────────────────────────────
//
// Not one line of this re-checks the Taylor series.  It measures what the
// filter does: a DC input must arrive at its own value, a higher cutoff must
// attenuate less, and at the cutoff the gain must be the textbook -3 dB.  That
// catches a coefficient that is wrong by a factor of two, which is exactly the
// mistake the first draft of lp_coeff made.
def check_filter() {
    print("[F] the one-pole lowpass, measured");
    let a1k = dsp.lp_coeff(1000, dsp.RATE);
    ck("F00 the coefficient is inside [0, ONE]", a1k > 0 && a1k <= fx.ONE,
       "a(1000 Hz) = " + tostring(a1k) + " = " + tostring(micro(a1k)) +
       " / 1000000");
    ck("F01 the coefficient rises with the cutoff",
       dsp.lp_coeff(200, dsp.RATE) < dsp.lp_coeff(1000, dsp.RATE) &&
       dsp.lp_coeff(1000, dsp.RATE) < dsp.lp_coeff(5000, dsp.RATE),
       "a(200)=" + tostring(dsp.lp_coeff(200, dsp.RATE)) +
       " a(1000)=" + tostring(a1k) +
       " a(5000)=" + tostring(dsp.lp_coeff(5000, dsp.RATE)));
    ck("F02 a cutoff of 0 is a bypass", dsp.lp_coeff(0, dsp.RATE) == fx.ONE,
       "a(0) = " + tostring(dsp.lp_coeff(0, dsp.RATE)));
    // DC gain: a constant input must arrive at itself.  Run the filter for
    // 16 time constants -- tau = 1/(1-a) samples -- and look at the end.
    let y = 0;
    let i = 0;
    let tau = fx.ONE / (fx.ONE - a1k);
    let steps = (tau * 16) / fx.ONE + 16;
    while (i < steps) {
        y = dsp.lp_step(y, fx.ONE, a1k);
        i = i + 1;
    };
    ck("F03 a DC input arrives at its own value", 0 - y <= 8 && y <= fx.ONE,
       "after " + tostring(steps) + " samples (16 time constants of " +
       tostring(tau / 1000) + " samples) the output is " + tostring(y) +
       " = " + tostring(micro(y)) + " / 1000000 of 1.0");
    // At the cutoff the gain of this filter is 1/sqrt(2) = 0.7071.  Measured
    // on the written bytes against that textbook number.
    let frames = dsp.RATE;
    render_one(dsp.W_SINE, 100000, A_T, frames, 0);
    snap();
    let wide = rms_of(frames);
    render_one(dsp.W_SINE, 100000, A_T, frames, 1000);
    snap();
    let atfc = rms_of(frames);
    ck("F10 the filter run is present", wide > 0 && atfc > 0,
       "unfiltered RMS " + tostring(wide) + ", at the cutoff " +
       tostring(atfc));
    // sqrt(2)/2 = 0.70711, to five places.  The tolerance is 2.5% of the
    // unfiltered RMS, which covers the finite-record edge effects of a
    // 48000-sample measurement and nothing else.
    let want = (wide * 70711) / 100000;
    ck_near("F11 at the cutoff the gain is 1/sqrt(2)", atfc, want,
            wide / 40 + 20);
    render_one(dsp.W_SINE, 100000, A_T, frames, 5000);
    snap();
    let above = rms_of(frames);
    ck("F12 above the cutoff less is attenuated than at it", above > atfc,
       "5 kHz cutoff gives RMS " + tostring(above) + " against " +
       tostring(atfc) + " at 1 kHz");
    render_one(dsp.W_SINE, 100000, A_T, frames, 200);
    snap();
    let below = rms_of(frames);
    ck("F13 below the cutoff more is attenuated than at it", below < atfc,
       "200 Hz cutoff gives RMS " + tostring(below) + " against " +
       tostring(atfc) + " at 1 kHz");
    ck("F14 the response is monotone in the cutoff",
       below < atfc && atfc < above,
       tostring(below) + " < " + tostring(atfc) + " < " + tostring(above));
};

// ── G. determinism, the demo, and the stereo image ────────────────────────
def check_demo() {
    print("[G] determinism and the demo mix");
    let a = wav.render_demo(wav.DEMO_CUTOFF);
    snap();
    let da = wav.image_sha();
    // Poison the buffer, then render again.  Without the poison a render that
    // only wrote part of the buffer would look identical to a full one, which
    // is the classic way a golden file records a defect.
    let i = 0;
    while (i < wav.MAXW) { wav.wav[i] = 255; i = i + 1; };
    let b = wav.render_demo(wav.DEMO_CUTOFF);
    snap();
    let db = wav.image_sha();
    ck("G00 the demo renders", a > 0 && b > 0, tostring(a) + " and " +
       tostring(b) + " bytes");
    ck("G01 two renders are byte-identical", da == db,
       "sha256 " + da);
    ck_eq("G02 no voice was refused", dsp.voices_refused, 0);
    ck("G03 the score has voices", dsp.nvoices >= 4 && dsp.nvoices <= dsp.MAXV,
       tostring(dsp.nvoices) + " voices");
    // Every voice inside the render: the last note's release must not run off
    // the end of the buffer, and no note may start before it.
    let frames = wav.wav_frames;
    let late = 0;
    i = 0;
    while (i < dsp.nvoices) {
        let v: dsp.Voice = dsp.voices[i];
        if (v.s0 < 0 || v.snd > frames) { late = late + 1; };
        i = i + 1;
    };
    ck_eq("G04 every voice fits inside the render", late, 0);
    let st = stat_of(frames);
    ck("G05 the demo is present and not silent", st.nonzero > frames / 2,
       tostring(st.nonzero) + " of " + tostring(frames) +
       " frames non-zero, peak " + tostring(st.peak));
    ck("G06 nothing clipped", st.peak <= dsp.FULL && st.peak > 15000,
       "peak " + tostring(st.peak) + " of " + tostring(dsp.FULL));
    ck("G07 the DC offset is small",
       0 - dc_of(frames) <= 40 && dc_of(frames) <= 40,
       "mean " + tostring(dc_of(frames)) + " LSB of " + tostring(dsp.FULL) +
       " (" + tostring(micro(dc_of(frames) * dsp.FULL)) + " ppm)");
    // Stereo: a mix with panning and a per-channel detune must have channels
    // that differ, and they must differ by the right sign on the lead.
    ck("G08 the two channels differ", st.lsum != st.rsum,
       "L mean " + tostring(st.lsum / frames) + ", R mean " +
       tostring(st.rsum / frames));
    // A single centred note must land on both channels equally: the pan law
    // gives 0.625 each at the centre, so the two means must match closely.
    // This is the check that catches a swapped channel.
    pan_note(dsp.W_SINE, 44000, 20000, 4800, fx.ONE / 2);
    let c = stat_of(4800);
    ck_eq("G09 a centred note puts the same mean in both channels",
          c.lsum / 4800, c.rsum / 4800);
    ck("G10 a centred note is not silent", c.lsum != 0 && c.rsum != 0,
       "L " + tostring(c.lsum) + ", R " + tostring(c.rsum));
    // A hard-left note must be louder on the left.  Pan 0 gives full left and
    // a quarter right.
    pan_note(dsp.W_SINE, 44000, 20000, 4800, 0);
    let p = stat_of(4800);
    ck("G11 a hard-left note is louder on the left",
       0 - p.lsum > 0 - p.rsum && p.rsum != 0,
       "L " + tostring(p.lsum) + " against R " + tostring(p.rsum));
};

// ── H. the transfer arithmetic, against scripted sinks ────────────────────
//
// This is the section the brief singles out: "the writei return value is
// frames written, which is routinely less than requested -- a short write is
// normal, not an error, and treating it as one is the first bug everyone
// writes."  A real device will not short-write on demand, so the sink is a
// function value and these eight cases test the loop's arithmetic directly.
let script: [long] = [];
let si = 0;
let calls: long = 0;

def sc_reset() {
    script = [];
    si = 0;
    calls = 0;
    prep_calls = 0
};

def sc_push(v: long) { script += v };

// script_sink(dev, frames): the next scripted answer, or `frames` once the
// script runs out -- so a script can end in "and then it behaves".
def script_sink(dev: long, frames: long) -> long {
    calls = calls + 1;
    if (si < len(script)) {
        let v = script[si];
        si = si + 1;
        return v;
    };
    frames
};

// fixed_sink: always answers `n` frames, however many are asked for.  It
// counts its calls, because "one call" is half of what H01 is checking.
def fixed_sink(dev: long, frames: long) -> long {
    calls = calls + 1;
    frames
};

// never_sink: always zero -- the hang every write loop has to avoid.
let never_v: long = 0;
def never_sink(dev: long, frames: long) -> long { never_v };

// epipe_sink: EPIPE until it has been asked `n` times, then everything.
let epipe_left: long = 0;
def epipe_sink(dev: long, frames: long) -> long {
    if (epipe_left > 0) {
        epipe_left = epipe_left - 1;
        return 0 - 32;
    };
    frames
};

// bad_sink: a fixed errno.
let bad_v: long = 0;
def bad_sink(dev: long, frames: long) -> long { bad_v };

// eagain_sink: EAGAIN for a while, then everything.  This is the shape a real
// device has -- measured on /dev/snd/pcmC3D0p: a blocking write(2) of 5760
// frames answered 1920 (what fitted in the 1920-frame ring) and the next call
// answered -EAGAIN until the hardware had consumed some.  EAGAIN here is the
// normal state of a device being drained at the sample rate, not a failure.
let eagain_left: long = 0;
def eagain_sink(dev: long, frames: long) -> long {
    if (eagain_left > 0) {
        eagain_left = eagain_left - 1;
        return 0 - 11;
    };
    frames
};

// ok_prep / bad_prep: the PREPARE a sink's recovery asks for.  Injectable for
// the reason in pcm.y's header: the real PREPARE is an ioctl, and pointing it
// at a device number that is not a device answers ENOTTY, which ends the
// recovery before the arithmetic under test is ever reached.
let prep_v: long = 0;
def ok_prep(dev: long) -> long {
    prep_calls = prep_calls + 1;
    prep_v
};
def count_prep(dev: long) -> long {
    prep_calls = prep_calls + 1;
    0
};

def check_feed() {
    print("[H] the snd_pcm_writei loop, against scripted sinks");
    // H1: everything at once.
    sc_reset();
    let n = 4800;
    let x = pcm.feed(0, n, fixed_sink, ok_prep);
    ck("H01 a sink that takes everything needs one call",
       x.ok && x.frames_written == n && x.short_writes == 0 && calls == 1,
       "ok " + tostring(x.ok) + ", frames " + tostring(x.frames_written) +
       ", calls " + tostring(calls));
    // H2: half every time.  A loop that treats a short write as an error stops
    // after the first one; this is that test.
    sc_reset();
    sc_push(n / 2);
    sc_push(n / 2);
    sc_push(n / 2);
    sc_push(n / 2);
    x = pcm.feed(0, n, script_sink, ok_prep);
    ck("H02 half-sized writes still reach every frame",
       x.ok && x.frames_written == n,
       "frames " + tostring(x.frames_written) + " of " + tostring(n) +
       ", short writes " + tostring(x.short_writes));
    // Four half-writes for a whole would need THREE short writes and four
    // calls, but the loop stops as soon as nothing is left, so it is two calls
    // and one short write: 4800 = 2400 + 2400.  A counter that said 4 here
    // would be counting calls, not short writes.
    ck("H03 the short-write count is the calls that were short",
       x.short_writes == 1 && calls == 2,
       tostring(x.short_writes) + " short of " + tostring(calls) + " calls");
    // H3: one frame at a time -- the worst a well-behaved device does.
    sc_reset();
    let k = 0;
    while (k < n - 1) { sc_push(1); k = k + 1; };
    x = pcm.feed(0, n, script_sink, ok_prep);
    ck("H04 one frame at a time still terminates", x.ok,
       "frames " + tostring(x.frames_written) + " of " + tostring(n) +
       ", calls " + tostring(calls));
    ck_eq("H05 ... having written exactly every frame", x.frames_written, n);
    // H4: a sink that never progresses.  The loop must give up, not hang.
    sc_reset();
    never_v = 0;
    x = pcm.feed(0, n, never_sink, ok_prep);
    ck("H06 a sink that never progresses is given up on, not waited on",
       !x.ok && x.err == 0 - 11 && x.stalls == 9,
       "err " + tostring(x.err) + " (EAGAIN), stalls " + tostring(x.stalls) +
       ", frames " + tostring(x.frames_written));
    // H4b: EAGAIN is a WAIT, not a failure.  This is the shape a real device
    // has, and treating it as fatal stops playback after one period.
    eagain_left = 5;
    sc_reset();
    x = pcm.feed(0, n, eagain_sink, ok_prep);
    ck("H06b EAGAIN is waited out, not treated as fatal",
       x.ok && x.frames_written == n && x.stalls == 5,
       "frames " + tostring(x.frames_written) + " of " + tostring(n) +
       ", stalls " + tostring(x.stalls) + ", why '" + x.why + "'");
    // H5: an underrun, recovered.
    epipe_left = 2;
    sc_reset();
    x = pcm.feed(0, n, epipe_sink, ok_prep);
    ck("H07 two EPIPEs are recovered and the frames still all go",
       x.ok && x.frames_written == n && x.recoveries == 2 && prep_calls == 2,
       "recoveries " + tostring(x.recoveries) + ", PREPARE calls " +
       tostring(prep_calls) + ", frames " + tostring(x.frames_written));
    // H6: EPIPE for ever.
    epipe_left = 99;
    sc_reset();
    x = pcm.feed(0, n, epipe_sink, ok_prep);
    ck("H08 EPIPE for ever is given up on",
       !x.ok && x.err == 0 - 32 && x.recoveries == 9 && prep_calls == 8,
       "err " + tostring(x.err) + " (EPIPE), recoveries " +
       tostring(x.recoveries) + ", PREPARE calls " + tostring(prep_calls) +
       " (the ninth recovery gives up BEFORE its PREPARE)");
    // ... and a PREPARE that itself fails is reported, not swallowed.
    sc_reset();
    epipe_left = 1;
    prep_v = 0 - 22;
    x = pcm.feed(0, n, epipe_sink, ok_prep);
    ck("H08b a failing PREPARE is reported with its errno",
       !x.ok && x.err == 0 - 22 && x.frames_written == 0,
       "err " + tostring(x.err) + ", why '" + x.why + "'");
    prep_v = 0;
    // H7: a hard error.
    sc_reset();
    bad_v = 0 - 22;
    x = pcm.feed(0, n, bad_sink, ok_prep);
    ck("H09 a hard errno is reported, not retried",
       !x.ok && x.err == 0 - 22 && x.why == "transfer: EINVAL",
       "err " + tostring(x.err) + ", why '" + x.why + "'");
    bad_v = 0 - 86;
    x = pcm.feed(0, n, bad_sink, ok_prep);
    ck("H10 ESTRPIPE is reported rather than half-handled",
       !x.ok && x.err == 0 - 86,
       "err " + tostring(x.err) + ", why '" + x.why + "'");
    // H8: a sink that over-reports.  The loop must clamp, so the total can
    // never exceed what was offered -- otherwise a frame count is invented.
    sc_reset();
    sc_push(n * 3);
    x = pcm.feed(0, n, script_sink, ok_prep);
    ck("H11 a sink that over-reports cannot invent frames",
       x.ok && x.frames_written == n,
       "offered " + tostring(n) + ", claimed " + tostring(x.frames_written));
    // H9: nothing to do is not a failure.
    sc_reset();
    x = pcm.feed(0, 0, fixed_sink, ok_prep);
    ck("H12 zero frames is success, and calls nobody",
       x.ok && x.frames_written == 0 && calls == 0,
       "ok " + tostring(x.ok) + ", calls " + tostring(calls));
};

// ── I. the ioctl ABI, recomputed ──────────────────────────────────────────
//
// Each request number is stored twice: once as the constant the code uses, and
// once as the (dir, nr, size) the kernel's uapi header writes it as.  If the
// two disagree then one of them is wrong, and a hex table on its own could
// not tell you which.
def check_abi() {
    print("[I] the ALSA ioctl ABI, recomputed from its components");
    ck_eq("I01 SNDRV_PCM_IOCTL_INFO", pcm.REQ_INFO,
          pcm.ioc(pcm.IOC_READ, pcm.INFO_NR, pcm.SIZE_PCM_INFO));
    ck_eq("I02 SNDRV_PCM_IOCTL_HW_PARAMS", pcm.REQ_HW_PARAMS,
          pcm.ioc(3, pcm.HW_PARAMS_NR, pcm.SIZE_HW_PARAMS));
    ck_eq("I03 SNDRV_PCM_IOCTL_SW_PARAMS", pcm.REQ_SW_PARAMS,
          pcm.ioc(3, pcm.SW_PARAMS_NR, pcm.SIZE_SW_PARAMS));
    ck_eq("I04 SNDRV_PCM_IOCTL_PREPARE", pcm.REQ_PREPARE,
          pcm.ioc(0, pcm.PREPARE_NR, 0));
    ck_eq("I05 SNDRV_PCM_IOCTL_DRAIN", pcm.REQ_DRAIN,
          pcm.ioc(0, pcm.DRAIN_NR, 0));
    ck_eq("I06 SNDRV_PCM_IOCTL_DROP", pcm.REQ_DROP,
          pcm.ioc(0, pcm.DROP_NR, 0));
    ck_eq("I07 SNDRV_PCM_IOCTL_WRITEI_FRAMES", pcm.REQ_WRITEI,
          pcm.ioc(pcm.IOC_WRITE, pcm.WRITEI_NR, pcm.SIZE_WRITEI));
    // The encoded sizes must be the real struct sizes, which is what stops a
    // struct layout change from being silently ignored.
    ck_eq("I08 the encoded hw_params size is 608",
          (pcm.REQ_HW_PARAMS >> 16) & 16383, 608);
    ck_eq("I09 the encoded sw_params size is 136",
          (pcm.REQ_SW_PARAMS >> 16) & 16383, 136);
    ck_eq("I10 the encoded info size is 288",
          (pcm.REQ_INFO >> 16) & 16383, 288);
    ck_eq("I11 the encoded writei size is 24",
          (pcm.REQ_WRITEI >> 16) & 16383, 24);
    // Every struct offset the module uses must land inside its struct.
    ck("I12 the last hw_params offset used is inside 608 bytes",
       pcm.HW_PARAMS_OFF_MASKS + 3 * 32 <= 608 &&
       pcm.HW_PARAMS_OFF_INTERVALS + 12 * 12 <= 608 &&
       pcm.HW_PARAMS_OFF_RMASK + 4 <= 608,
       "masks " + tostring(pcm.HW_PARAMS_OFF_MASKS) + ", intervals " +
       tostring(pcm.HW_PARAMS_OFF_INTERVALS) + ", rmask " +
       tostring(pcm.HW_PARAMS_OFF_RMASK));
    ck_eq("I13 the ioctl type is 'A'", pcm.ALSA_TYPE, 65);
    ck_eq("I14 PREPARE is _IO('A',0x40)", pcm.REQ_PREPARE, 0x4140);
    ck_eq("I15 DRAIN is _IO('A',0x44)", pcm.REQ_DRAIN, 0x4144);
    // errno names, because a diagnostic that says "errno -16" is not one.
    ck("I16 EBUSY", pcm.errno_name(0 - 16) == "EBUSY", pcm.errno_name(0 - 16));
    ck("I17 EACCES", pcm.errno_name(0 - 13) == "EACCES", pcm.errno_name(0 - 13));
    ck("I18 EPIPE", pcm.errno_name(0 - 32) == "EPIPE", pcm.errno_name(0 - 32));
    ck("I19 ENXIO", pcm.errno_name(0 - 6) == "ENXIO", pcm.errno_name(0 - 6));
    ck("I20 EFAULT is named, and that is what an unbuilt snd_xferi answers",
       pcm.errno_name(0 - 14) == "EFAULT", pcm.errno_name(0 - 14));
    ck("I21 an unknown errno still names itself",
       pcm.errno_name(0 - 4095) == "errno 4095", pcm.errno_name(0 - 4095));
    ck("I22 ESTRPIPE is named", pcm.errno_name(0 - 86) == "ESTRPIPE",
       pcm.errno_name(0 - 86));
    // The three request shapes, checked against the ABI rather than against the
    // code that builds them: 608 bytes of hw_params, the ioctl type 'A', and
    // three strategies tried in order from most to least constrained.
    ck_eq("I23 there are three request shapes", pcm.NSTRATEGY, 3);
    ck("I24 the full shape is the first one tried",
       pcm.STRATEGY_FULL == 0 && pcm.STRATEGY_RATE == 1 &&
       pcm.STRATEGY_MIN == 2, "full/rate/min are 0/1/2");
    ck_eq("I25 the intervals occupy 144 bytes of the 608", pcm.NINTERVAL * 12,
          144);
    ck("I27 fcntl is syscall 72, not 55",
       pcm.SYS_FCNTL == 72 && pcm.F_SETFL == 4,
       "fcntl is " + tostring(pcm.SYS_FCNTL) + ", F_SETFL is " +
       tostring(pcm.F_SETFL));
    ck("I28 the last interval ends before the struct does",
       pcm.HW_PARAMS_OFF_INTERVALS + pcm.NINTERVAL * 12 <= pcm.SIZE_HW_PARAMS,
       "intervals end at " +
       tostring(pcm.HW_PARAMS_OFF_INTERVALS + pcm.NINTERVAL * 12) +
       ", struct is " + tostring(pcm.SIZE_HW_PARAMS));
};

// ── J. degradation, with no sound hardware involved ───────────────────────
//
// The brief is explicit: `--play` on a machine with no /dev/snd, no pcm*p or
// EACCES on open must give a clear one-line diagnostic on stderr, a non-zero
// exit and NO TRAP -- and traps print to stdout, where they would corrupt the
// diff.  None of that can be tested on the machine that HAS a sound card, so
// it is tested against directories that are deliberately not /dev/snd: one
// that does not exist, one that is empty, one holding a regular file called
// pcmC9D9p (which opens and then answers ENOTTY to INFO), and one holding the
// same file with mode 000, which gives a real EACCES.
def check_degrade() {
    print("[J] degradation, against directories that are not /dev/snd");
    tmp_mk();
    ck("J00 the scratch directory exists", fs.is_dir(TMP), TMP);
    // The name filter, which is what keeps capture devices out of the list.
    ck("J01 pcmC3D0p is a playback node", pcm.is_playback_node("pcmC3D0p"), "");
    ck("J02 pcmC0D0c is not", !pcm.is_playback_node("pcmC0D0c"), "");
    ck("J03 controlC0 is not", !pcm.is_playback_node("controlC0"), "");
    ck("J04 seq is not", !pcm.is_playback_node("seq"), "");
    ck("J05 by-id is not", !pcm.is_playback_node("by-id"), "");
    ck("J06 a bare pcm is not", !pcm.is_playback_node("pcm"), "");
    ck("J07 pcmC3D0x is not", !pcm.is_playback_node("pcmC3D0x"), "");
    // A directory that is not there at all.
    let missing = TMP + "/nope";
    let n = pcm.enumerate(missing, dsp.RATE, dsp.CHANNELS, true);
    ck("J08 a missing directory is reported, not fatal",
       n == 0 - 1 && pcm.nnodes == 0,
       "enumerate answered " + tostring(n) + " (" + pcm.errno_name(n) + ")");
    let fd = pcm.pick(missing, dsp.RATE, dsp.CHANNELS);
    ck("J09 pick on a missing directory fails cleanly",
       fd < 0 && pcm.pick_why != "" && pcm.pick_why.index_of(missing) >= 0,
       "fd " + tostring(fd) + ", why '" + pcm.pick_why + "'");
    // An empty directory: there are nodes, and none of them plays.
    let empty = TMP + "/empty";
    fs.make_dir(empty);
    n = pcm.enumerate(empty, dsp.RATE, dsp.CHANNELS, true);
    ck("J10 an empty directory lists nothing", n == 0 && pcm.nnodes == 0,
       tostring(n) + " candidate(s)");
    fd = pcm.pick(empty, dsp.RATE, dsp.CHANNELS);
    ck("J11 pick on an empty directory says what it looked for",
       fd < 0 && pcm.pick_why.index_of("pcm*p") >= 0,
       "why '" + pcm.pick_why + "'");
    // A regular file with a PCM node's name: it opens, and INFO refuses it.
    // That is the "the node is there but it is not a PCM device" path, with a
    // real ioctl answer rather than a simulated one.
    let fake = TMP + "/fake";
    fs.make_dir(fake);
    let fpath = fake + "/pcmC9D9p";
    fs.write_file(fpath, "not a device\n");
    n = pcm.enumerate(fake, dsp.RATE, dsp.CHANNELS, true);
    ck("J12 a regular file named pcm*p is found as a candidate", n == 1,
       tostring(n) + " candidate(s)");
    if (n == 1) {
        let d: pcm.Node = pcm.nodes[0];
        ck("J13 ... and it is refused", !d.playable,
           "why '" + d.why + "'");
        ck("J14 ... with the errno the kernel gave",
           d.why.index_of("ENOTTY") > 0 || d.why.index_of("ENOTTY") == 0,
           "why '" + d.why + "'");
    };
    fd = pcm.pick(fake, dsp.RATE, dsp.CHANNELS);
    ck("J15 pick refuses the file too", fd < 0, "fd " + tostring(fd));
    // The same file with mode 000: a real EACCES from openat.  This is the
    // path a machine whose POSIX ACL does not grant this user would take, and
    // it is exercised without touching the real sound hardware at all.
    let noacc = TMP + "/noacc";
    fs.make_dir(noacc);
    let npath = noacc + "/pcmC8D8p";
    fs.write_file(npath, "x");
    fs.set_mode(npath, 0);
    n = pcm.enumerate(noacc, dsp.RATE, dsp.CHANNELS, true);
    ck("J16 an unreadable node is found as a candidate", n == 1,
       tostring(n) + " candidate(s)");
    if (n == 1) {
        let d: pcm.Node = pcm.nodes[0];
        ck("J17 ... and it is refused with EACCES",
           !d.playable && d.why.index_of("EACCES") >= 0,
           "why '" + d.why + "'");
    };
    fd = pcm.pick(noacc, dsp.RATE, dsp.CHANNELS);
    ck("J18 pick reports the EACCES and the path",
       fd < 0 && pcm.pick_why.index_of("EACCES") >= 0,
       "why '" + pcm.pick_why + "'");
    fs.set_mode(npath, 420);
    tmp_rm();
    ck("J19 the scratch directory is gone", !fs.exists(TMP), TMP);
};

def do_check() -> long {
    print("audio -- property battery");
    print("");
    print("pinned compiler: build with refs/ycc.ref and nothing else.");
    print("every expectation below is analytic, measured from the written");
    print("bytes, or a scripted sink -- never a second copy of the code.");
    print("");
    tmp_mk();
    check_container();
    check_quant();
    check_osc();
    check_rms();
    check_env();
    check_filter();
    check_demo();
    check_feed();
    check_abi();
    check_degrade();
    tmp_rm();
    print("");
    print(tostring(checks - failed) + " of " + tostring(checks) +
          " checks passed");
    if (failed > 0) { return 1; };
    0
};

export { do_check, checks, failed };