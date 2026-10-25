// data.y — the data fuzzer's harness (driven by `ytest fuzz --data`).
//   data TARGET SEED ITERS CURRENT
// Mutates seed inputs of one std decoder (audio, img, zlib, json, regex, utf8)
// ITERS times and feeds each result to it. CURRENT names a file the input is
// written to BEFORE each call, so a trap, a timeout or the memory cap leaves
// the offending input behind. The same SEED always gives the same inputs.
import fs;
import audio;
import img;
import zlib;
import json;
import regex;
import utf8;

let rng: [long] = [0];

// 0 <= result < n (n > 0): a 64-bit LCG, high bits.
def rand(n: long) -> long {
    rng[0] = rng[0] * 6364136223846793005 + 1442695040888963407;
    let r = (rng[0] / 65536) % n;
    if (r < 0) { r + n } else { r }
};

def le32(b: [byte], p: long) -> long {
    b[p] | (b[p + 1] << 8) | (b[p + 2] << 16) | (b[p + 3] << 24)
};

def put(o: [byte], v: long, n: long) -> long {
    let i = 0;
    while (i < n) { o += (v >> (8 * i)) & 255; i = i + 1; };
    0
};

const SMALL = 30000;

def keep(files: [[byte]], f: [byte]) -> long {
    if (f.length < SMALL) { files += f; };
    0
};

// fixtures.bin layouts, as the t41x fixtures read them
def audio_seeds() -> [[byte]] {
    let files: [[byte]] = [];
    let blob = fs.read_bytes("test/data/audio/fixtures.bin")!;
    let p = 0;
    while (p < blob.length) {
        let nl = blob[p];
        let q = p + 1 + nl;
        let n = le32(blob, q + 5);
        keep(files, blob[q + 9:q + 9 + n]);
        p = q + 13 + n + le32(blob, q + 9 + n);
    };
    files += audio.encode_wav(audio.tone(8000, 440.0, 20));
    files
};

def img_seeds() -> [[byte]] {
    let files: [[byte]] = [];
    let blob = fs.read_bytes("test/data/img/fixtures.bin")!;
    let p = 0;
    while (p < blob.length) {
        let nl = blob[p];
        let q = p + 2 + nl;
        let w = le32(blob, q);
        let h = le32(blob, q + 4);
        let n = le32(blob, q + 8);
        keep(files, blob[q + 12:q + 12 + n]);
        p = q + 12 + n + w * h * 4;
    };
    let im = img.new_image(5, 3);
    files += img.encode_png(im);
    files += img.encode_bmp(im);
    files += img.encode_ppm(im);
    files
};

def zlib_seeds() -> [[byte]] {
    let files: [[byte]] = [];
    let blob = fs.read_bytes("test/data/zlib/fixtures.bin")!;
    let p = 0;
    while (p < blob.length) {
        let nl = blob[p];
        let n = le32(blob, p + 2 + nl);
        keep(files, blob[p + 6 + nl:p + 6 + nl + n]);
        p = p + 6 + nl + n;
    };
    files += zlib.compress(bytes("hello hello hello hello, fuzzing the inflater"));
    files += zlib.gzip(bytes("hello hello hello hello"));
    files
};

def text_seeds(which: str) -> [[byte]] {
    let ss: [str] = [];
    if (which == "json") {
        ss = ["{\"a\": [1, 2.5, -3e2, true, false, null, \"x\\u00e9\\n\"], \"b\": {\"c\": {}}}", "[[[[1]]]]", "\"\\ud83d\\ude00\"", "{\"k\": 12345678901234567890}"];
    } else if (which == "regex") {
        ss = ["a(b|c)*d", "^[a-z]+\\d{2,4}$", "(?:x+)+y", "(a|ab)(c|bcd)(d*)", "\\bfoo\\b", "[^\\w\\s]*", "(?i)abc.\\1"];
    } else {
        ss = ["plain ascii", "café 中文 \U0001f600", "ÿ"];
    };
    let out: [[byte]] = [];
    foreach (s in ss) { out += bytes(s); };
    out
};

def mutate(seed: [byte], other: [byte]) -> [byte] {
    let m = seed[0:seed.length];
    let edits = 1 + rand(3);
    let e = 0;
    while (e < edits) {
        let what = rand(6);
        if (what == 0) {
            m = m[0:rand(m.length + 1)];
        } else if (what == 1 && m.length > 0) {
            let at = rand(m.length);
            m[at] = m[at] ^ (1 << rand(8));
        } else if (what == 2 && m.length > 0) {
            m[rand(m.length)] = rand(256);
        } else if (what == 3 && m.length > 4) {
            // a length field: 0, 1, 0x7fffffff or 0xffffffff
            let vals = [0, 1, 2147483647, 4294967295];
            let at = rand(m.length - 3);
            let v = vals[rand(4)];
            let i = 0;
            while (i < 4) { m[at + i] = (v >> (8 * i)) & 255; i = i + 1; };
        } else if (what == 4 && other.length > 0) {
            let a = rand(other.length);
            let b = a + rand(other.length - a + 1);
            let at = rand(m.length + 1);
            m = m[0:at] + other[a:b] + m[at:m.length];
        } else if (m.length > 1) {
            let at = rand(m.length);
            let b = at + rand(m.length - at + 1);
            m = m[0:at] + m[b:m.length];
        };
        e = e + 1;
    };
    m
};

def feed(target: str, d: [byte]) -> long {
    if (target == "audio") {
        audio.decode(d);
    } else if (target == "img") {
        img.decode(d);
    } else if (target == "zlib") {
        zlib.decompress(d, 16777216);
        zlib.inflate(d);
        zlib.gunzip(d);
    } else if (target == "json") {
        json.parse_val(from_bytes(d));
    } else if (target == "regex") {
        let re = regex.compile(from_bytes(d));
        if (re != none) { regex.match(re!, "aabcd foo 12 abcabc xxxy"); };
    } else {
        utf8.codes(from_bytes(d));
    };
    0
};

let av = argv();
if (len(av) != 5) {
    eputs("usage: data TARGET SEED ITERS CURRENT\n");
    exit(2);
};
let target = av[1];
rng[0] = tolong(av[2])!;
let iters = tolong(av[3])!;
let seeds: [[byte]] = [];
if (target == "audio") { seeds = audio_seeds(); }
else if (target == "img") { seeds = img_seeds(); }
else if (target == "zlib") { seeds = zlib_seeds(); }
else if (target == "json" || target == "regex" || target == "utf8") { seeds = text_seeds(target); }
else { eputs("data: unknown target " + target + "\n"); exit(2); };
let i = 0;
while (i < iters) {
    let m = mutate(seeds[rand(seeds.length)], seeds[rand(seeds.length)]);
    fs.write_bytes(av[4], m);
    feed(target, m);
    i = i + 1;
};
print(target, " ", iters, " inputs, no finding");
