// wav.y -- the RIFF/WAVE container: build it, write it, and read it back.
//
// The whole file lives in ONE fixed byte buffer, header at offset 0 and the
// sample data at offset 44.  That is a deliberate choice with two payoffs:
//   * one buffer means one allocation, so `sha256` can be taken over the
//     whole image as a single slice and the digest in EXPECTED pins every
//     byte of the file; and
//   * the same buffer is what `dsp.stats` reads to measure the signal, so the
//     measurement and the digest come from the same bytes that reached the
//     disk.
//
// A `[byte; N]` does not unify with `[byte]` (SUGGESTIONS.md #12) and a
// `*byte` cannot be walked (#12 again), so no helper here can take the buffer
// as a parameter.  The offset-taking helpers below read and write the one
// module-level buffer instead.  That is the shape the constraint forces, and
// it is written down here rather than left as an oddity.

import fs;
import crypto;
import fx;
import dsp;

const HDR: long = 44;               // the canonical PCM header length
const MAXW: long = 384044;           // 44 + 96000 frames * 2 channels * 2 bytes

// The memoised slice of the image, and the length it was taken at.  The
// declaration lives here rather than beside image() because wav_build()
// invalidates it and module-level bindings have to be declared before use.
let img_cache: [byte] = [];
let img_len: long = 0 - 1;

let wav: [byte; 384044] = [0; 384044];
let wav_bytes: long = 0;
let wav_frames: long = 0;

// ── byte stores ───────────────────────────────────────────────────────────
def put8(off: long, v: long) { wav[off] = v & 255 };

def put16(off: long, v: long) {
    wav[off] = v & 255;
    wav[off + 1] = (v >> 8) & 255
};

def put32(off: long, v: long) {
    wav[off] = v & 255;
    wav[off + 1] = (v >> 8) & 255;
    wav[off + 2] = (v >> 16) & 255;
    wav[off + 3] = (v >> 24) & 255
};

def get16(off: long) -> long { wav[off] + 256 * wav[off + 1] };

def get32(off: long) -> long {
    wav[off] + wav[off + 1]*256 + wav[off + 2]*65536 + wav[off + 3]*16777216
};

// put_tag(off, s): the four chunk-id bytes at `off`, copied from a literal.
//
// The first draft wrote these as one little-endian u32 constant per tag --
// `put32(0, 1380145677)` for "RIFF" -- and 1380145677 is 0x52435a0d, which is
// "RFCR" as bytes and nothing like "RIFF".  It is the kind of mistake that
// survives review, because the constant *is* a plausible-looking number and
// nothing else in the program looks at those four bytes.  Copying the four
// characters removes the class of error entirely.
def put_tag(off: long, s: str) {
    wav[off] = byte_at(s, 0);
    wav[off + 1] = byte_at(s, 1);
    wav[off + 2] = byte_at(s, 2);
    wav[off + 3] = byte_at(s, 3)
};

// str_eq(b, off, s): the four CC bytes at `off` against a literal.  Compared
// as bytes rather than through `from_bytes`, so a slice is never built.
def str_eq(off: long, s: str) -> bool {
    let i = 0;
    let ok = true;
    while (i < 4) {
        if (wav[off + i] != byte_at(s, i)) { ok = false; };
        i = i + 1;
    };
    ok
};

// str_get(off): the four CC bytes at `off` as a str, for diagnostics.
def str_get(off: long) -> str {
    chr(wav[off]) + chr(wav[off + 1]) + chr(wav[off + 2]) + chr(wav[off + 3])
};

// ── building the image ────────────────────────────────────────────────────

// wav_build(frames, rate, channels, bits) -- quantise dsp.bufL/bufR into the
// data chunk and lay the header in front of it.
//
// Returns the file length in bytes, or 0 if the request is out of range (an
// empty or over-long render).  Zero means "nothing was written", never a
// partial file.
def wav_build(frames: long, rate: long, channels: long, bits: long) -> long {
    if (!dsp.frames_ok(frames, rate)) { return 0; };
    if (channels != 2 || bits != 16) { return 0; };
    let data = frames * channels * 2;
    let total = HDR + data;
    if (total > MAXW) { return 0; };
    // The data chunk first, so `frames` is known to be writable.
    let n = 0;
    while (n < frames) {
        let l = dsp.q_to_s16(dsp.bufL[n]);
        let r = dsp.q_to_s16(dsp.bufR[n]);
        put16(HDR + n * 4, l);
        put16(HDR + n * 4 + 2, r);
        n = n + 1;
    };
    put_tag(0, "RIFF");
    put32(4, 36 + data);
    put_tag(8, "WAVE");
    put_tag(12, "fmt ");
    put32(16, 16);                           // the PCM fmt chunk size
    put16(20, 1);                            // WAVE_FORMAT_PCM
    put16(22, channels);
    put32(24, rate);
    put32(28, rate * channels * (bits / 8));
    put16(32, channels * (bits / 8));        // block align
    put16(34, bits);
    put_tag(36, "data");
    put32(40, data);
    wav_bytes = total;
    wav_frames = frames;
    img_len = 0 - 1;
    total
};

// ── reading the header back ───────────────────────────────────────────────
//
// The property battery parses the image it just built and checks every field
// against the parameters it asked for.  That is not re-implementing the
// writer: the writer's answers are in the buffer, and these are the values
// the RIFF specification requires at those offsets.

type Hdr = {
    riff_ok: bool, wave_ok: bool, fmt_ok: bool, data_ok: bool,
    fmt_size: long, format: long, channels: long, rate: long,
    byterate: long, align: long, bits: long,
    riff_size: long, data_size: long, total: long
};

def wav_read_hdr() -> Hdr {
    let d = get32(40);
    let h: Hdr = {
        riff_ok: str_eq(0, "RIFF"), wave_ok: str_eq(8, "WAVE"),
        fmt_ok: str_eq(12, "fmt "), data_ok: str_eq(36, "data"),
        fmt_size: get32(16), format: get16(20), channels: get16(22),
        rate: get32(24), byterate: get32(28), align: get16(32),
        bits: get16(34), riff_size: get32(4), data_size: d,
        total: 36 + d
    };
    h
};

// ── writing it out ────────────────────────────────────────────────────────

// save_bytes(path, b): put `b` on disk, all of it, and answer whether every
// byte went.  A short write is retried with the offset advanced, because the
// only way a partial write becomes visible is if the caller checks.
//
// It takes a `[byte]` rather than the buffer, because that is the only shape
// a slice of the fixed buffer has; `fs.write_data` is given the slice directly
// and handles the short-write loop itself, so there is no second copy.
def save_bytes(path: str, b: [byte]) -> bool {
    let fd = fs.open_file(path, "w", 420);
    if (fd < 0) { return false; };
    let ok = fs.write_data(fd, b);
    let closed = fs.close_file(fd);
    if (ok && !closed) { ok = false; };
    ok
};

// wav_save(path): the module's own image.
def wav_save(path: str) -> bool {
    save_bytes(path, wav[0:wav_bytes])
};

// wav_size_on_disk(path): a file's length, or 0 when it cannot be stat'd.
def wav_size_on_disk(path: str) -> long {
    let n: long? = fs.file_size(path);
    if (n == none) { 0 } else { n! }
};

// image(): the module's own image as a `[byte]`, which is the only shape the
// measuring and hashing code can be handed.  It is a copy and the arena never
// frees, so it is MEMOISED on the length: the same image answers every call,
// and a different image (a different render) makes one new copy.  Without the
// memo a battery that measures RMS, peak, DC offset and zero crossings -- four
// measurements, each a full pass -- would allocate four copies of the file per
// fixture, which is the per-iteration allocation trap the arena turns into a
// slow leak rather than an error.
// wav_build INVALIDATES the cache, and it must: memoising on the length alone
// means a second render of the SAME length would hand back the FIRST render's
// bytes, and every RMS, peak and crossing count after it would be measuring
// the previous fixture.  That is not hypothetical -- it is exactly what
// happened while this battery was being written, and it showed up as a
// "silence is not silent" failure nine checks into the quantisation group.

def image() -> [byte] {
    if (img_len != wav_bytes) {
        img_cache = wav[0:wav_bytes];
        img_len = wav_bytes;
    };
    img_cache
};

// image_sha(): the sha256 of the image in memory, header included.  Equal to
// file_sha() of the file just written, which is what makes the digest printed
// by `audio demo` a statement about the WAV's bytes rather than about the
// program that produced them.
def image_sha() -> str { crypto.hex(crypto.sha256(image())) };

// file_sha(path): the sha256 of a file's bytes -- the check that what reached
// the disk is what was intended, since a truncated or half-written file cannot
// produce the same digest.
def file_sha(path: str) -> str {
    let b: [byte]? = fs.read_bytes(path);
    if (b == none) { return "(unreadable)" };
    let d: [byte] = b!;
    crypto.hex(crypto.sha256(d))
};

// ── the demo render ───────────────────────────────────────────────────────
//
// The note list lives HERE, once, and both `audio demo` and the property
// battery render from it.  That is deliberate: a battery carrying its own copy
// of the score would be checking a different piece from the one the golden
// file records, which is precisely the agreement-with-itself this campaign
// keeps finding.
const DEMO_MS: long = 1500;            // 1.5 s
const DEMO_CUTOFF: long = 6500;        // the one-pole lowpass, in Hz

// m(thousandths): thousandths of unity into Q30, so the score can be written
// as integers that read as music rather than as hex.
def m(t: long) -> long { (t * fx.ONE) / 1000 };

// demo_score(): nine notes of A minor over 1.5 s -- a triangle bass, a sine
// lead detuned a fraction of a sample between the channels for width, and one
// saw for edge.  Times and durations are milliseconds, chz is CENTIHERTZ (A4
// = 44000, because 440 Hz is not A4 to the byte), amp / pan / sus are
// thousandths of unity, and det is the right channel's start offset in Q30
// turns.
def demo_score() -> long {
    dsp.nvoices = 0;
    dsp.voices_refused = 0;
    dsp.voices = [];
    let p = 0;
    // wave, chz, at, dur, amp, pan, det, sustain, attack, decay, release
    p = p + dsp.voice_add(dsp.W_TRI, 11000, 0, 420, m(610), m(150), 0,
                          m(550), 12, 60, 180);
    p = p + dsp.voice_add(dsp.W_TRI, 13081, 380, 300, m(520), m(100), 0,
                          m(500), 10, 60, 160);
    p = p + dsp.voice_add(dsp.W_TRI, 16481, 660, 300, m(490), m(120), 0,
                          m(500), 10, 60, 160);
    p = p + dsp.voice_add(dsp.W_TRI, 11000, 940, 300, m(550), m(150), 0,
                          m(550), 10, 60, 200);
    p = p + dsp.voice_add(dsp.W_SINE, 44000, 120, 260, m(375), m(720), 300000,
                          m(400), 8, 40, 140);
    p = p + dsp.voice_add(dsp.W_SINE, 52325, 360, 200, m(350), m(780), 260000,
                          m(350), 8, 40, 140);
    p = p + dsp.voice_add(dsp.W_SINE, 65926, 540, 380, m(375), m(800), 340000,
                          m(450), 8, 40, 200);
    p = p + dsp.voice_add(dsp.W_SINE, 49388, 900, 220, m(320), m(740), 280000,
                          m(350), 8, 40, 140);
    p = p + dsp.voice_add(dsp.W_SAW, 44000, 1080, 240, m(175), m(660), 220000,
                          m(500), 6, 30, 140);
    p
};

// render_demo(cutoff): the score, rendered and quantised into the image.
// Answers the file length in bytes, or 0 when the request is out of range.
def render_demo(cutoff: long) -> long {
    let frames = (DEMO_MS * dsp.RATE) / 1000;
    if (!dsp.frames_ok(frames, dsp.RATE)) { return 0; };
    demo_score();
    dsp.render(frames, dsp.RATE, cutoff);
    wav_build(frames, dsp.RATE, dsp.CHANNELS, dsp.BITS)
};

export {
    HDR, MAXW, wav, wav_bytes, wav_frames, DEMO_MS, DEMO_CUTOFF,
    put8, put16, put32, put_tag, get16, get32, str_eq, str_get,
    wav_build, wav_read_hdr, wav_save, save_bytes, wav_size_on_disk,
    image, image_sha, file_sha, demo_score, render_demo, Hdr
};