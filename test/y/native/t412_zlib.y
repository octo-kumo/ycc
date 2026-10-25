// std/zlib.y: the decoder against streams Python's zlib produced (every
// strategy it has, raw deflate and gzip too), the checksums against known
// values, the encoder's output round-tripping and never beating `stored`'s
// size the wrong way, and corrupt streams answering none. The expected output
// comes from t412_zlib.ref.py, which builds the same inputs independently and
// checks with Python's own zlib that each corrupt stream is refused there too.
import fs;
import zlib;
import crypto;

let state = 12345;
def rnd(m: long) -> long {
    state = (state * 1103515245 + 12345) & 2147483647;
    (state >> 8) % m
};
def rbyte() -> byte {
    state = (state * 1103515245 + 12345) & 2147483647;
    (state >> 16) & 255
};
def rand_bytes(n: long) -> [byte] {
    let b: [byte] = [];
    let i = 0;
    while (i < n) { b += rbyte(); i = i + 1; };
    b
};
def repeat(blk: [byte], times: long) -> [byte] {
    let b: [byte] = [];
    let t = 0;
    while (t < times) { b += blk; t = t + 1; };
    b
};
def inputs() -> [[byte]] {
    let all: [[byte]] = [];
    let empty: [byte] = [];
    all += empty;
    all += bytes("a");
    let aa: [byte] = [];
    let i = 0;
    while (i < 100000) { aa += 97; i = i + 1; };
    all += aa;
    all += rand_bytes(2500);
    let words = ["the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "zlib", "deflate", "stream", "huffman"];
    let t = "";
    while (t.length < 9000) {
        t = t + words[rnd(12)] + " ";
    };
    all += bytes(t[0:9000]);
    let st: [byte] = [];
    i = 0;
    while (i < 2000) {
        let v = i * 3 + rnd(4);
        st += v & 255;
        st += (v >> 8) & 255;
        st += (v >> 16) & 255;
        st += (v >> 24) & 255;
        i = i + 1;
    };
    all += st;
    all += repeat(rand_bytes(2000), 3);
    let seq: [byte] = [];
    i = 0;
    while (i < 256) { seq += i; i = i + 1; };
    all += repeat(seq, 12);
    all
};

def le32(b: [byte], p: long) -> long {
    b[p] | (b[p + 1] << 8) | (b[p + 2] << 16) | (b[p + 3] << 24)
};

let ins = inputs();
let blob = fs.read_bytes("test/data/zlib/fixtures.bin")!;

print("decode");
let p = 0;
while (p < blob.length) {
    let nl = blob[p];
    let name = from_bytes(blob[p + 1:p + 1 + nl]);
    let kind = blob[p + 1 + nl];
    let n = le32(blob, p + 2 + nl);
    let stream = blob[p + 6 + nl:p + 6 + nl + n];
    p = p + 6 + nl + n;
    let which = tolong(name[1:name.index_of("_")])!;
    let out = if (kind == 0) { zlib.decompress(stream) } else if (kind == 1) { zlib.inflate(stream) } else { zlib.gunzip(stream) };
    if (out == none) {
        print(name, " ", kind, " ", n, " none");
    } else {
        print(name, " ", kind, " ", n, " ", out! == ins[which], " ", out!.length, " ", zlib.crc32(out!));
    };
};

print("checksums");
let none0: [byte] = [];
print(zlib.crc32(bytes("123456789")), " ", zlib.crc32(none0), " ", zlib.adler32(bytes("Wikipedia")), " ", zlib.adler32(none0));
let msg = bytes("The quick brown fox jumps over the lazy dog");
print(zlib.crc32(msg), " ", zlib.adler32(msg));
print(zlib.crc32(msg[20:], zlib.crc32(msg[0:20])) == zlib.crc32(msg), " ", zlib.adler32(msg[20:], zlib.adler32(msg[0:20])) == zlib.adler32(msg));
let ff: [byte] = [255];
print(zlib.adler32(repeat(ff, 70000)), " ", zlib.crc32(repeat(ff, 70000)));

print("corrupt");
let hdr: [byte] = [31, 139];
let b7: [byte] = [7];
let b3: [byte] = [1, 5, 0, 250, 255];
let empty: [byte] = [];
let text = ins[4];
let good = zlib.compress(text);
let gz = zlib.gzip(text);
let rawd = zlib.deflate(text);
print(zlib.decompress(good) != none, " ", zlib.inflate(rawd) != none, " ", zlib.gunzip(gz) != none);
print(zlib.decompress(good[0:good.length / 2]), " ", zlib.inflate(rawd[0:rawd.length / 2]) == none);
let bad = repeat(good, 1);
bad[bad.length - 1] = bad[bad.length - 1] ^ 1;
print(zlib.decompress(bad));
bad = repeat(good, 1);
bad[0] = 121;
print(zlib.decompress(bad));
bad = repeat(good, 1);
bad[1] = bad[1] | 32;
print(zlib.decompress(bad));
bad = repeat(gz, 1);
bad[bad.length - 6] = bad[bad.length - 6] ^ 1;
print(zlib.gunzip(bad));
print(zlib.gunzip(good), " ", zlib.decompress(gz), " ", zlib.decompress(empty), " ", zlib.gunzip(hdr));
print(zlib.decompress(good, text.length - 1), " ", zlib.decompress(good, text.length) != none, " ", zlib.inflate(zlib.deflate(ins[2]), 99999), " ", zlib.inflate(zlib.deflate(ins[2]), 100000) != none);
print(zlib.inflate(b7), " ", zlib.inflate(empty), " ", zlib.inflate(b3));

print("encode");
print(crypto.hex(zlib.deflate(bytes("hello"))));
print(crypto.hex(zlib.stored(bytes("hello"))), " ", crypto.hex(zlib.stored(none0)));
foreach (k in [0, 1, 2, 3, 4, 5, 6, 7]) {
    let x = ins[k];
    let z = zlib.compress(x);
    let back = zlib.decompress(z);
    let g = zlib.gunzip(zlib.gzip(x));
    let r1 = zlib.inflate(zlib.deflate(x, 1));
    let r64 = zlib.inflate(zlib.deflate(x, 64));
    let st = zlib.inflate(zlib.stored(x));
    print(k, " ", back! == x, " ", g! == x, " ", r1! == x, " ", r64! == x, " ", st! == x, " ", z.length <= zlib.stored(x).length + 6,
        " ", zlib.deflate(x, 64).length <= zlib.deflate(x, 1).length);
};
print(zlib.compress(ins[2]).length < 700, " ", zlib.compress(ins[4]).length < ins[4].length / 2, " ", zlib.compress(ins[3]).length <= 2500 + 11 + 6);
