// std/audio.y: WAV in every sample format and FLAC from the reference encoder
// (levels 0-8, block sizes, 8/16/24 bit, mono to six channels, wasted bits,
// verbatim and constant subframes, every stereo mode), each compared sample for
// sample with the 16-bit PCM make.py computed independently; the WAV encoder
// round-tripped; operations; hostile input answering none without a trap.
import fs;
import audio;

def le32(b: [byte], p: long) -> long {
    b[p] | (b[p + 1] << 8) | (b[p + 2] << 16) | (b[p + 3] << 24)
};

let blob = fs.read_bytes("test/data/audio/fixtures.bin")!;
print("decode");
let p = 0;
let files: [[byte]] = [];
while (p < blob.length) {
    let nl = blob[p];
    let name = from_bytes(blob[p + 1:p + 1 + nl]);
    let q = p + 1 + nl;
    let rate = le32(blob, q);
    let ch = blob[q + 4];
    let n = le32(blob, q + 5);
    let file = blob[q + 9:q + 9 + n];
    let m = le32(blob, q + 9 + n);
    let pcm = blob[q + 13 + n:q + 13 + n + m];
    p = q + 13 + n + m;
    files += file;
    let s = audio.decode(file);
    if (s == none) {
        print(name, " ", audio.format(file), " none");
    } else {
        print(name, " ", audio.format(file), " ", s!.rate == rate, " ", s!.channels == ch, " ", s!.pcm == pcm, " ", s!.pcm.length);
    };
};

print("encode");
let t = audio.tone(8000, 440.0, 250);
print(audio.frames(t), " ", audio.seconds(t), " ", audio.sample(t, 5, 0), " ", audio.sample(t, 6, 0), " ", audio.sample(t, 9999, 0));
let wv = audio.encode_wav(t);
let back = audio.decode(wv)!;
print(wv.length, " ", back.rate, " ", back.channels, " ", back.pcm == t.pcm, " ", audio.format(wv));
print(audio.save("_snd_x.wav", t), " ", audio.save("_snd_x.mp9", t), " ", audio.load("_snd_x.wav")!.pcm == t.pcm, " ", audio.load("nope.wav") == none);
fs.remove_file("_snd_x.wav");

print("operations");
let st = audio.new_sound(8000, 2, 4);
audio.set_sample(st, 0, 0, 1000);
audio.set_sample(st, 0, 1, 3000);
audio.set_sample(st, 3, 1, -40000);
print(audio.sample(st, 0, 0), " ", audio.sample(st, 0, 1), " ", audio.sample(st, 3, 1), " ", audio.set_sample(st, 4, 0, 1), " ", audio.sample(st, 0, 2));
let mo = audio.to_mono(st);
print(mo.channels, " ", audio.frames(mo), " ", audio.sample(mo, 0, 0), " ", audio.sample(mo, 3, 0));
let up = audio.resample(t, 16000);
print(up.rate, " ", audio.frames(up), " ", audio.sample(up, 10, 0), " ", audio.sample(up, 11, 0));
let lo = audio.gain(t, 0.5);
print(audio.sample(lo, 5, 0), " ", audio.sample(audio.gain(t, 4.0), 5, 0));
let cc = audio.concat(t, t);
print(audio.frames(cc), " ", audio.concat(t, st).pcm == t.pcm);

print("hostile");
let state = 5;
def rnd(m: long) -> long {
    state = (state * 1103515245 + 12345) & 2147483647;
    (state >> 8) % m
};
let handled = 0;
let nones = 0;
let k = 0;
while (k < files.length) {
    let f = files[k];
    if (f.length < 30000) {
        let u = 0;
        while (u < 12) {
            let m = f[0:(if (u < 6) { rnd(f.length) } else { f.length })];
            if (u >= 6) {
                let flips = 1 + rnd(3);
                let v = 0;
                while (v < flips) { m[rnd(if (u < 9) { 60 } else { m.length })] = rnd(256); v = v + 1; };
            };
            if (audio.decode(m) == none) { nones = nones + 1; };
            handled = handled + 1;
            u = u + 1;
        };
    };
    k = k + 1;
};
print(handled, " mutated or truncated files decoded without a trap");
print(nones > 50, " ", nones < handled);
