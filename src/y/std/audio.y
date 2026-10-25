// std/audio.y -- sound files: decode WAV and FLAC to 16-bit PCM, encode WAV,
// and a few sample operations.
//
//     import audio;
//     let s = audio.load("song.flac")!;
//     print(s.rate, " Hz, ", s.channels, " channels, ", audio.seconds(s), " s");
//     audio.save("song.wav", audio.to_mono(s));
//
// A `Sound` is `rate` (frames per second), `channels` and `pcm`: signed 16-bit
// little-endian samples, the channels interleaved. Whatever a file held (8, 12,
// 20, 24 or 32 bit integers, 32/64 bit floats) is converted to that, rounding
// down to 16 bits. The decoders answer `none` for data that is damaged,
// truncated (FLAC frames are checked against their CRC-16), or of a kind they
// do not read, and never trap on hostile input.
import math;
import fs;

export {
    Sound, MAX_BYTES, format, decode, load, save, encode_wav, new_sound, tone,
    frames, seconds, sample, set_sample, to_mono, resample, gain, concat
};

type Sound = { rate: long, channels: long, pcm: [byte] };

/** The most PCM bytes a decoder will produce (a guard against a header that
promises more than any file holds). */
const MAX_BYTES = 1073741824;

def le16(d: [byte], p: long) -> long { d[p] | (d[p + 1] << 8) };
def le32(d: [byte], p: long) -> long {
    d[p] | (d[p + 1] << 8) | (d[p + 2] << 16) | (d[p + 3] << 24)
};

def fl(n: long) -> float {
    let f: float = n;
    f
};

def sound(rate: long, ch: long, pcm: [byte]) -> Sound {
    let s: Sound = { rate: rate, channels: ch, pcm: pcm };
    s
};

/** `n` frames of silence. */
def new_sound(rate: long, channels: long, n: long) -> Sound {
    let pcm: [byte] = [];
    let chunk: [byte] = [];
    let i = 0;
    while (i < 4096) { chunk += 0; i = i + 1; };
    let want = n * channels * 2;
    while (pcm.length + 4096 <= want) { pcm += chunk; };
    while (pcm.length < want) { pcm += 0; };
    sound(rate, channels, pcm)
};

/** The number of frames (one sample of every channel). */
def frames(s: Sound) -> long { s.pcm.length / (2 * s.channels) };

/** The length in seconds. */
def seconds(s: Sound) -> float {
    fl(frames(s)) / fl(s.rate)
};

/** Sample of channel `c` in frame `i`, -32768 to 32767; 0 out of range. */
def sample(s: Sound, i: long, c: long) -> long {
    if (i < 0 || c < 0 || c >= s.channels || i >= frames(s)) { return 0; };
    let o = (i * s.channels + c) * 2;
    let v = s.pcm[o] | (s.pcm[o + 1] << 8);
    if (v >= 32768) { v - 65536 } else { v }
};

/** Stores `v` (clamped to 16 bits) as channel `c` of frame `i`. */
def set_sample(s: Sound, i: long, c: long, v: long) -> long {
    if (i < 0 || c < 0 || c >= s.channels || i >= frames(s)) { return 0; };
    let x = v;
    if (x > 32767) { x = 32767; };
    if (x < -32768) { x = -32768; };
    x = x & 65535;
    let o = (i * s.channels + c) * 2;
    s.pcm[o] = x & 255;
    s.pcm[o + 1] = x >> 8;
    1
};

/** A sine wave of `hz` for `ms` milliseconds at `amp` (0 to 32767), mono. */
def tone(rate: long, hz: float, ms: long, amp: long = 16000) -> Sound {
    let n = rate * ms / 1000;
    let s = new_sound(rate, 1, n);
    let i = 0;
    let w = 6.283185307179586 * hz / fl(rate);
    while (i < n) {
        set_sample(s, i, 0, math.to_int(math.sin(w * fl(i)) * fl(amp)));
        i = i + 1;
    };
    s
};

/** Every frame's channels averaged into one. */
def to_mono(s: Sound) -> Sound {
    let n = frames(s);
    let out = new_sound(s.rate, 1, n);
    let i = 0;
    while (i < n) {
        let sum = 0;
        let c = 0;
        while (c < s.channels) { sum = sum + sample(s, i, c); c = c + 1; };
        set_sample(out, i, 0, sum / s.channels);
        i = i + 1;
    };
    out
};

/** `s` at another sample rate, by linear interpolation. */
def resample(s: Sound, rate: long) -> Sound {
    let n = frames(s);
    let m = n * rate / s.rate;
    let out = new_sound(rate, s.channels, m);
    let i = 0;
    while (i < m) {
        // position in the source, 16 fractional bits
        let pos = i * s.rate * 65536 / rate;
        let a = pos >> 16;
        let t = pos & 65535;
        let c = 0;
        while (c < s.channels) {
            let x = sample(s, a, c);
            let y = if (a + 1 < n) { sample(s, a + 1, c) } else { x };
            set_sample(out, i, c, (x * (65536 - t) + y * t) >> 16);
            c = c + 1;
        };
        i = i + 1;
    };
    out
};

/** Every sample times `f`, clipped. */
def gain(s: Sound, f: float) -> Sound {
    let out = new_sound(s.rate, s.channels, frames(s));
    let n = frames(s) * s.channels;
    let i = 0;
    while (i < n) {
        let o = i * 2;
        let v = s.pcm[o] | (s.pcm[o + 1] << 8);
        if (v >= 32768) { v = v - 65536; };
        let x = math.to_int(fl(v) * f);
        if (x > 32767) { x = 32767; };
        if (x < -32768) { x = -32768; };
        x = x & 65535;
        out.pcm[o] = x & 255;
        out.pcm[o + 1] = x >> 8;
        i = i + 1;
    };
    out
};

/** `a` followed by `b`; they must have the same rate and channel count (else
`a` is returned unchanged). */
def concat(a: Sound, b: Sound) -> Sound {
    if (a.rate != b.rate || a.channels != b.channels) { return a; };
    sound(a.rate, a.channels, a.pcm + b.pcm)
};

// ── WAV ─────────────────────────────────────────────────────────────────

def wav_decode(d: [byte]) -> Sound? {
    if (d.length < 12 || from_bytes(d[0:4]) != "RIFF" || from_bytes(d[8:12]) != "WAVE") { return none; };
    let p = 12;
    let tag = 0;
    let ch = 0;
    let rate = 0;
    let bits = 0;
    let align = 0;
    let have_fmt = false;
    while (p + 8 <= d.length) {
        let id = from_bytes(d[p:p + 4]);
        let len = le32(d, p + 4);
        let body = p + 8;
        if (id == "fmt ") {
            if (len < 16 || body + len > d.length) { return none; };
            tag = le16(d, body);
            ch = le16(d, body + 2);
            rate = le32(d, body + 4);
            align = le16(d, body + 12);
            bits = le16(d, body + 14);
            if (tag == 65534 && len >= 26) { tag = le16(d, body + 24); };
            have_fmt = true;
        } else if (id == "data") {
            if (!have_fmt) { return none; };
            let avail = d.length - body;
            if (len > avail) { len = avail; };
            if (ch < 1 || ch > 32 || rate < 1 || rate > 768000) { return none; };
            let bps = bits / 8;
            if (bits % 8 != 0 || bps < 1 || bps > 8 || align != bps * ch) { return none; };
            let isfloat = tag == 3;
            if (!isfloat && tag != 1) { return none; };
            if (isfloat && bps != 4 && bps != 8) { return none; };
            if (!isfloat && bps > 4) { return none; };
            let n = len / (bps * ch);
            if (n * ch * 2 > MAX_BYTES) { return none; };
            let s = new_sound(rate, ch, n);
            let i = 0;
            let total = n * ch;
            while (i < total) {
                let o = body + i * bps;
                let v = 0;
                if (isfloat) {
                    let f = 0.0;
                    if (bps == 4) { f = f32_at(d, o); } else { f = f64_at(d, o); };
                    let g = f * 32768.0;
                    if (g != g) { v = 0; } else if (g >= 32767.0) { v = 32767; } else if (g <= -32768.0) { v = -32768; } else { v = math.to_int(g); };
                } else if (bps == 1) {
                    v = (d[o] - 128) << 8;
                } else if (bps == 2) {
                    v = d[o] | (d[o + 1] << 8);
                    if (v >= 32768) { v = v - 65536; };
                } else if (bps == 3) {
                    v = (d[o + 1] | (d[o + 2] << 8));
                    if (v >= 32768) { v = v - 65536; };
                } else {
                    v = (d[o + 2] | (d[o + 3] << 8));
                    if (v >= 32768) { v = v - 65536; };
                };
                set_sample(s, i / ch, i % ch, v);
                i = i + 1;
            };
            return some(s);
        };
        p = body + len + (len & 1);
    };
    none
};

def f32_at(d: [byte], o: long) -> float {
    let b = le32(d, o);
    let sign = if (b >> 31 == 1) { -1.0 } else { 1.0 };
    let e = (b >> 23) & 255;
    let m = b & 8388607;
    if (e == 255) { return 0.0; };
    if (e == 0) { return sign * fl(m) * pow2(-149); };
    sign * fl(m + 8388608) * pow2(e - 150)
};

def f64_at(d: [byte], o: long) -> float {
    let hi = le32(d, o + 4);
    let lo = le32(d, o);
    let sign = if (hi >> 31 == 1) { -1.0 } else { 1.0 };
    let e = (hi >> 20) & 2047;
    let m = ((hi & 1048575) << 32) | lo;
    if (e == 2047) { return 0.0; };
    if (e == 0) { return sign * fl(m) * pow2(-1074); };
    sign * fl(m + 4503599627370496) * pow2(e - 1075)
};

def pow2(e: long) -> float {
    let r = 1.0;
    let k = e;
    while (k > 0) { r = r * 2.0; k = k - 1; };
    while (k < 0) { r = r * 0.5; k = k + 1; };
    r
};

def put16(o: [byte], v: long) -> long {
    o += v & 255;
    o += (v >> 8) & 255;
    0
};
def put32(o: [byte], v: long) -> long {
    put16(o, v & 65535);
    put16(o, (v >> 16) & 65535);
    0
};

/** `s` as a 16-bit PCM WAV file. */
def encode_wav(s: Sound) -> [byte] {
    let o = bytes("RIFF");
    put32(o, 36 + s.pcm.length);
    o += bytes("WAVEfmt ");
    put32(o, 16);
    put16(o, 1);
    put16(o, s.channels);
    put32(o, s.rate);
    put32(o, s.rate * s.channels * 2);
    put16(o, s.channels * 2);
    put16(o, 16);
    o += bytes("data");
    put32(o, s.pcm.length);
    o += s.pcm;
    o
};

// ── FLAC ────────────────────────────────────────────────────────────────

type Bits = { d: [byte], pos: long, end: long, bad: bool };

def rb(b: Bits, n: long) -> long {
    let v = 0;
    let left = n;
    while (left > 0) {
        let byte_i = b.pos >> 3;
        if (byte_i >= b.end) { b.bad = true; return 0; };
        let have = 8 - (b.pos & 7);
        let take = if (left < have) { left } else { have };
        v = (v << take) | ((b.d[byte_i] >> (have - take)) & ((1 << take) - 1));
        b.pos = b.pos + take;
        left = left - take;
    };
    v
};

def rbs(b: Bits, n: long) -> long {
    if (n == 0) { return 0; };
    let v = rb(b, n);
    if (v >= (1 << (n - 1))) { v - (1 << n) } else { v }
};

def unary(b: Bits) -> long {
    let q = 0;
    while (rb(b, 1) == 0) {
        if (b.bad) { return 0; };
        q = q + 1;
    };
    q
};

def crc16(d: [byte], a: long, e: long) -> long {
    let c = 0;
    let i = a;
    while (i < e) {
        c = c ^ (d[i] << 8);
        let k = 0;
        while (k < 8) {
            if (c & 32768 != 0) { c = ((c << 1) ^ 32773) & 65535; } else { c = (c << 1) & 65535; };
            k = k + 1;
        };
        i = i + 1;
    };
    c
};

def crc8(d: [byte], a: long, e: long) -> long {
    let c = 0;
    let i = a;
    while (i < e) {
        c = c ^ d[i];
        let k = 0;
        while (k < 8) {
            if (c & 128 != 0) { c = ((c << 1) ^ 7) & 255; } else { c = (c << 1) & 255; };
            k = k + 1;
        };
        i = i + 1;
    };
    c
};

/** Residual of a subframe into `out[order..n)`. */
def residual(b: Bits, out: [long], order: long, n: long) -> bool {
    let method = rb(b, 2);
    if (method > 1) { return false; };
    let po = rb(b, 4);
    let parts = 1 << po;
    if (n % parts != 0 || (n >> po) < order) { return false; };
    let pbits = if (method == 0) { 4 } else { 5 };
    let esc = (1 << pbits) - 1;
    let i = order;
    let pi = 0;
    while (pi < parts) {
        let cnt = (n >> po) - (if (pi == 0) { order } else { 0 });
        let k = rb(b, pbits);
        if (k == esc) {
            let nb = rb(b, 5);
            let j = 0;
            while (j < cnt) { out[i] = rbs(b, nb); i = i + 1; j = j + 1; };
        } else {
            let j = 0;
            while (j < cnt) {
                let q = unary(b);
                let r = rb(b, k);
                let u = (q << k) | r;
                if (u & 1 == 1) { out[i] = 0 - ((u + 1) >> 1); } else { out[i] = u >> 1; };
                i = i + 1;
                j = j + 1;
            };
        };
        if (b.bad) { return false; };
        pi = pi + 1;
    };
    true
};

def subframe(b: Bits, out: [long], n: long, bps: long) -> bool {
    if (rb(b, 1) != 0) { return false; };
    let ty = rb(b, 6);
    let wasted = 0;
    if (rb(b, 1) == 1) { wasted = unary(b) + 1; };
    let bits = bps - wasted;
    if (bits < 1 || bits > 33) { return false; };
    if (ty == 0) {
        let v = rbs(b, bits);
        let i = 0;
        while (i < n) { out[i] = v; i = i + 1; };
    } else if (ty == 1) {
        let i = 0;
        while (i < n) { out[i] = rbs(b, bits); i = i + 1; };
    } else if (ty >= 8 && ty <= 12) {
        let order = ty - 8;
        if (order > n) { return false; };
        let i = 0;
        while (i < order) { out[i] = rbs(b, bits); i = i + 1; };
        if (!residual(b, out, order, n)) { return false; };
        i = order;
        while (i < n) {
            let r = out[i];
            if (order == 1) { r = r + out[i - 1]; }
            else if (order == 2) { r = r + 2 * out[i - 1] - out[i - 2]; }
            else if (order == 3) { r = r + 3 * out[i - 1] - 3 * out[i - 2] + out[i - 3]; }
            else if (order == 4) { r = r + 4 * out[i - 1] - 6 * out[i - 2] + 4 * out[i - 3] - out[i - 4]; };
            out[i] = r;
            i = i + 1;
        };
    } else if (ty >= 32) {
        let order = (ty & 31) + 1;
        if (order > n) { return false; };
        let i = 0;
        while (i < order) { out[i] = rbs(b, bits); i = i + 1; };
        let prec = rb(b, 4) + 1;
        if (prec == 16) { return false; };
        let shift = rbs(b, 5);
        if (shift < 0) { return false; };
        let co: [long] = [];
        i = 0;
        while (i < order) { co += rbs(b, prec); i = i + 1; };
        if (!residual(b, out, order, n)) { return false; };
        i = order;
        while (i < n) {
            let sum = 0;
            let j = 0;
            while (j < order) { sum = sum + co[j] * out[i - 1 - j]; j = j + 1; };
            out[i] = out[i] + (sum >> shift);
            i = i + 1;
        };
    } else {
        return false;
    };
    if (b.bad) { return false; };
    if (wasted > 0) {
        let i = 0;
        while (i < n) { out[i] = out[i] << wasted; i = i + 1; };
    };
    true
};

def flac_decode(d: [byte]) -> Sound? {
    if (d.length < 42 || from_bytes(d[0:4]) != "fLaC") { return none; };
    let p = 4;
    let rate = 0;
    let channels = 0;
    let bps = 0;
    let total = 0;
    let last = false;
    let have = false;
    while (!last) {
        if (p + 4 > d.length) { return none; };
        last = d[p] & 128 != 0;
        let ty = d[p] & 127;
        let len = (d[p + 1] << 16) | (d[p + 2] << 8) | d[p + 3];
        p = p + 4;
        if (p + len > d.length) { return none; };
        if (ty == 0) {
            if (len < 34) { return none; };
            rate = (d[p + 10] << 12) | (d[p + 11] << 4) | (d[p + 12] >> 4);
            channels = ((d[p + 12] >> 1) & 7) + 1;
            bps = (((d[p + 12] & 1) << 4) | (d[p + 13] >> 4)) + 1;
            total = ((d[p + 13] & 15) << 32) | (d[p + 14] << 24) | (d[p + 15] << 16) | (d[p + 16] << 8) | d[p + 17];
            have = true;
        };
        p = p + len;
    };
    if (!have || rate == 0 || bps < 4 || bps > 32 || total * channels * 2 > MAX_BYTES) { return none; };
    let pcm: [byte] = [];
    let rates: [long] = [0, 88200, 176400, 192000, 8000, 16000, 22050, 24000, 32000, 44100, 48000, 96000];
    let sizes: [long] = [0, 8, 12, 0, 16, 20, 24, 32];
    let b: Bits = { d: d, pos: 0, end: d.length, bad: false };
    let chans: [[long]] = [];
    let ci = 0;
    while (ci < channels) { chans += [0]; ci = ci + 1; };
    while (p + 6 < d.length) {
        let start = p;
        if (d[p] != 255 || (d[p + 1] & 254) != 248) { return none; };
        let bc = d[p + 2] >> 4;
        let rc = d[p + 2] & 15;
        let ca = d[p + 3] >> 4;
        let sc = (d[p + 3] >> 1) & 7;
        if (d[p + 3] & 1 != 0) { return none; };
        let q = p + 4;
        // the coded frame or sample number
        let lead = d[q];
        let extra = 0;
        if (lead < 128) { extra = 0; } else if (lead < 224) { extra = 1; } else if (lead < 240) { extra = 2; } else if (lead < 248) { extra = 3; } else if (lead < 252) { extra = 4; } else if (lead < 254) { extra = 5; } else { extra = 6; };
        q = q + 1 + extra;
        if (q + 3 > d.length) { return none; };
        let n = 0;
        if (bc == 1) { n = 192; }
        else if (bc >= 2 && bc <= 5) { n = 576 << (bc - 2); }
        else if (bc == 6) { n = d[q] + 1; q = q + 1; }
        else if (bc == 7) { n = ((d[q] << 8) | d[q + 1]) + 1; q = q + 2; }
        else if (bc >= 8) { n = 256 << (bc - 8); }
        else { return none; };
        let fr = rate;
        if (rc == 0) { fr = rate; }
        else if (rc < 12) { fr = rates[rc]; }
        else if (rc == 12) { fr = d[q] * 1000; q = q + 1; }
        else if (rc == 13) { fr = (d[q] << 8) | d[q + 1]; q = q + 2; }
        else if (rc == 14) { fr = ((d[q] << 8) | d[q + 1]) * 10; q = q + 2; }
        else { return none; };
        if (fr <= 0 || q + 1 > d.length || crc8(d, p, q) != d[q]) { return none; };
        q = q + 1;
        let fb = bps;
        if (sc != 0) { fb = sizes[sc]; if (fb == 0) { return none; }; };
        let nch = channels;
        if (ca < 8) { nch = ca + 1; } else if (ca <= 10) { nch = 2; } else { return none; };
        if (nch != channels) { return none; };
        b.pos = q * 8;
        let ch = 0;
        while (ch < nch) {
            let sb = fb;
            if ((ca == 8 && ch == 1) || (ca == 9 && ch == 0) || (ca == 10 && ch == 1)) { sb = sb + 1; };
            let buf: [long] = [];
            let z = 0;
            while (z < n) { buf += 0; z = z + 1; };
            if (!subframe(b, buf, n, sb)) { return none; };
            chans[ch] = buf;
            ch = ch + 1;
        };
        // align, then the CRC-16 of the whole frame
        b.pos = (b.pos + 7) & -8;
        let e = b.pos >> 3;
        if (e + 2 > d.length || crc16(d, start, e) != ((d[e] << 8) | d[e + 1])) { return none; };
        p = e + 2;
        if (ca == 8) {
            let i = 0;
            while (i < n) { chans[1][i] = chans[0][i] - chans[1][i]; i = i + 1; };
        } else if (ca == 9) {
            let i = 0;
            while (i < n) { chans[0][i] = chans[0][i] + chans[1][i]; i = i + 1; };
        } else if (ca == 10) {
            let i = 0;
            while (i < n) {
                let side = chans[1][i];
                let mid = (chans[0][i] << 1) | (side & 1);
                chans[0][i] = (mid + side) >> 1;
                chans[1][i] = (mid - side) >> 1;
                i = i + 1;
            };
        };
        let i = 0;
        while (i < n) {
            ch = 0;
            while (ch < nch) {
                let v = chans[ch][i];
                if (fb > 16) { v = v >> (fb - 16); } else if (fb < 16) { v = v << (16 - fb); };
                if (v > 32767) { v = 32767; };
                if (v < -32768) { v = -32768; };
                v = v & 65535;
                pcm += v & 255;
                pcm += v >> 8;
                ch = ch + 1;
            };
            i = i + 1;
        };
        if (pcm.length > MAX_BYTES) { return none; };
    };
    if (fixed_len_wrong(pcm, channels, total)) { return none; };
    some(sound(rate, channels, pcm))
};

def fixed_len_wrong(pcm: [byte], channels: long, total: long) -> bool {
    total != 0 && pcm.length != total * channels * 2
};

// ── front door ──────────────────────────────────────────────────────────

/** "wav", "flac" or "" by the first bytes of `d`. */
def format(d: [byte]) -> str {
    if (d.length >= 12 && from_bytes(d[0:4]) == "RIFF" && from_bytes(d[8:12]) == "WAVE") { return "wav"; };
    if (d.length >= 4 && from_bytes(d[0:4]) == "fLaC") { return "flac"; };
    ""
};

/** Decodes a sound file held in `d`, whatever its kind. */
def decode(d: [byte]) -> Sound? {
    let f = format(d);
    if (f == "wav") { wav_decode(d) }
    else if (f == "flac") { flac_decode(d) }
    else { none }
};

/** Reads and decodes the sound file at `path`. */
def load(path: str) -> Sound? {
    let b = fs.read_bytes(path);
    if (b == none) { none } else { decode(b!) }
};

/** Writes `s` to `path` as a WAV file (the only format it writes); false for
another extension or a failed write. */
def save(path: str, s: Sound) -> bool {
    if (path.lower().ends_with(".wav")) { fs.write_bytes(path, encode_wav(s)) } else { false }
};
