// std/audio.y and std/img.y: hostile input answers none or a clipped sound,
// never a trap (float WAV samples out of range; BMP headers cut short).
import audio;
import img;

def put(o: [byte], v: long, n: long) -> long {
    let i = 0;
    while (i < n) { o += (v >> (8 * i)) & 255; i = i + 1; };
    0
};

def float_wav(bps: long, sample: [byte]) -> [byte] {
    let o = bytes("RIFF");
    put(o, 36 + sample.length, 4);
    o += bytes("WAVEfmt ");
    put(o, 16, 4);
    put(o, 3, 2);
    put(o, 1, 2);
    put(o, 8000, 4);
    put(o, 8000 * bps, 4);
    put(o, bps, 2);
    put(o, bps * 8, 2);
    o += bytes("data");
    put(o, sample.length, 4);
    o += sample;
    o
};

// 1e300 as an IEEE double, then -1e300; 3e38 and -3e38 as singles
let s64: [byte] = [0x9c, 0x45, 0xc0, 0x2c, 0x78, 0x3b, 0x6e, 0x7e, 0x9c, 0x45, 0xc0, 0x2c, 0x78, 0x3b, 0x6e, 0xfe];
let d64 = float_wav(8, s64);
let s32: [byte] = [0x93, 0x4c, 0xc9, 0x7e, 0x93, 0x4c, 0xc9, 0xfe];
let d32 = float_wav(4, s32);
let a = audio.decode(d64);
let b = audio.decode(d32);
print(a != none, " ", b != none);
if let some(s) = a { print(s.pcm[0] | (s.pcm[1] << 8), " ", s.pcm[2] | (s.pcm[3] << 8)); };
if let some(s) = b { print(s.pcm[0] | (s.pcm[1] << 8), " ", s.pcm[2] | (s.pcm[3] << 8)); };

// a BMP cut at every header boundary, and one that claims a 124-byte header
let im = img.new_image(3, 2);
let bmp = img.encode_bmp(im);
let ok = 0;
let cuts: [long] = [0, 13, 14, 17, 18, 25, 26, 53, 54, 58, 66, 69, 70, 100];
foreach (cut in cuts) {
    if (cut < bmp.length && img.decode(bmp[0:cut]) == none) { ok = ok + 1; };
};
let big = bmp[0:60];
big[14] = 124;
big[15] = 0;
big[16] = 0;
big[17] = 0;
print(ok, " ", img.decode(big) == none);
