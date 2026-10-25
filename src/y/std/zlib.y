// std/zlib.y -- deflate, zlib and gzip, and the two checksums they use.
//
//     import zlib;
//     let z = zlib.compress(bytes("hello hello hello"));
//     print(zlib.decompress(z)!.length);                   // 17
//     print(zlib.crc32(bytes("123456789")));                // 3421780262
//
// Everything works on `[byte]`. The readers answer `none` for data that is not
// a valid stream (a bad header, a code that decodes to nothing, a distance that
// reaches before the start, a checksum that does not match, input that ends
// early) and never trap on hostile input; `limit` caps how much a stream may
// expand to, so a few bytes cannot ask for a gigabyte.
//
// The decoder is the canonical-Huffman walk of zlib's own `puff.c`: it reads a
// code a bit at a time and is exact rather than fast. The encoder emits one
// block of fixed Huffman codes, found with LZ77 over a hash chain, and falls
// back to stored blocks when that is not smaller, so its output is always valid
// and never much bigger than its input.
export {
    crc32, adler32, inflate, decompress, gunzip, deflate, compress, gzip,
    stored
};

// ── checksums ───────────────────────────────────────────────────────────

def crc_table() -> [long] {
    let t: [long] = [];
    let n = 0;
    while (n < 256) {
        let c = n;
        let k = 0;
        while (k < 8) {
            if (c & 1 == 1) { c = 3988292384 ^ (c >>> 1); } else { c = c >>> 1; };
            k = k + 1;
        };
        t += c;
        n = n + 1;
    };
    t
};

let CRC: [long] = crc_table();

/** The CRC-32 (the one gzip, PNG and zip use) of `data`, continuing from `crc`
(0 to start); the result is an unsigned 32-bit value in a `long`. Feeding the
pieces of a message one after the other gives the CRC of the whole. */
def crc32(data: [byte], crc: long = 0) -> long {
    let c = crc ^ 4294967295;
    foreach (b in data) { c = CRC[(c ^ b) & 255] ^ (c >>> 8); };
    c ^ 4294967295
};

/** The Adler-32 checksum (zlib's) of `data`, continuing from `adler` (1 to
start). */
def adler32(data: [byte], adler: long = 1) -> long {
    let a = adler & 65535;
    let b = (adler >>> 16) & 65535;
    let i = 0;
    let n = data.length;
    while (i < n) {
        // 5552 bytes at most before the sums can overflow 32 bits; reduce then
        let stop = if (i + 5552 < n) { i + 5552 } else { n };
        while (i < stop) {
            a = a + data[i];
            b = b + a;
            i = i + 1;
        };
        a = a % 65521;
        b = b % 65521;
    };
    (b << 16) | a
};

// ── the decoder ─────────────────────────────────────────────────────────

type Bits = { d: [byte], pos: long, buf: long, cnt: long, ok: bool };

def getbits(b: Bits, n: long) -> long {
    while (b.cnt < n) {
        if (b.pos >= b.d.length) {
            b.ok = false;
            return 0;
        };
        b.buf = b.buf | (b.d[b.pos] << b.cnt);
        b.pos = b.pos + 1;
        b.cnt = b.cnt + 8;
    };
    let v = b.buf & ((1 << n) - 1);
    b.buf = b.buf >>> n;
    b.cnt = b.cnt - n;
    v
};

// a canonical Huffman code: how many codes there are of each length, and the
// symbols ordered by (length, value)
type Huff = { count: [long], symbol: [long] };

// Builds the code for `n` symbols whose lengths are `len[off ..]`. -1 for an
// over-subscribed set, 0 for a complete one, 1 for an incomplete one.
def build(h: Huff, len: [long], off: long, n: long) -> long {
    h.count = [];
    h.symbol = [];
    let i = 0;
    while (i <= 15) {
        h.count += 0;
        i = i + 1;
    };
    i = 0;
    while (i < n) {
        h.count[len[off + i]] = h.count[len[off + i]] + 1;
        h.symbol += 0;
        i = i + 1;
    };
    if (h.count[0] == n) { return 0; };
    let left = 1;
    let l = 1;
    while (l <= 15) {
        left = left << 1;
        left = left - h.count[l];
        if (left < 0) { return -1; };
        l = l + 1;
    };
    let offs: [long] = [0, 0];
    l = 1;
    while (l < 15) {
        offs += offs[l] + h.count[l];
        l = l + 1;
    };
    i = 0;
    while (i < n) {
        if (len[off + i] != 0) {
            h.symbol[offs[len[off + i]]] = i;
            offs[len[off + i]] = offs[len[off + i]] + 1;
        };
        i = i + 1;
    };
    left
};

// The next symbol, or -1 on a bad code or the end of the input.
def decode(b: Bits, h: Huff) -> long {
    let code = 0;
    let first = 0;
    let index = 0;
    let l = 1;
    while (l <= 15) {
        code = code | getbits(b, 1);
        if (!b.ok) { return -1; };
        let count = h.count[l];
        if (code - count < first) { return h.symbol[index + (code - first)]; };
        index = index + count;
        first = (first + count) << 1;
        code = code << 1;
        l = l + 1;
    };
    -1
};

let LBASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
let LEXT = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
let DBASE = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577];
let DEXT = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];

// Decodes the symbols of one block into `out`; false on any error.
def codes(b: Bits, out: [byte], lit: Huff, dist: Huff, limit: long) -> bool {
    while (true) {
        let sym = decode(b, lit);
        if (sym < 0) { return false; };
        if (sym < 256) {
            if (out.length >= limit) { return false; };
            out += sym;
        } else if (sym == 256) {
            return true;
        } else {
            sym = sym - 257;
            if (sym >= 29) { return false; };
            let len = LBASE[sym] + getbits(b, LEXT[sym]);
            let ds = decode(b, dist);
            if (ds < 0 || ds >= 30) { return false; };
            let d = DBASE[ds] + getbits(b, DEXT[ds]);
            if (!b.ok || d > out.length || out.length + len > limit) { return false; };
            let from = out.length - d;
            let k = 0;
            while (k < len) {
                out += out[from + k];
                k = k + 1;
            };
        };
    };
    false
};

def fixed_tables(lit: Huff, dist: Huff) -> long {
    let lengths: [long] = [];
    let i = 0;
    while (i < 288) {
        if (i < 144) { lengths += 8; } else if (i < 256) { lengths += 9; } else if (i < 280) { lengths += 7; } else { lengths += 8; };
        i = i + 1;
    };
    build(lit, lengths, 0, 288);
    let dl: [long] = [];
    i = 0;
    while (i < 30) {
        dl += 5;
        i = i + 1;
    };
    build(dist, dl, 0, 30)
};

let ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

def dynamic(b: Bits, out: [byte], limit: long) -> bool {
    let nlen = getbits(b, 5) + 257;
    let ndist = getbits(b, 5) + 1;
    let ncode = getbits(b, 4) + 4;
    if (!b.ok || nlen > 286 || ndist > 30) { return false; };
    let lengths: [long] = [];
    let i = 0;
    while (i < 320) {
        lengths += 0;
        i = i + 1;
    };
    i = 0;
    while (i < ncode) {
        lengths[ORDER[i]] = getbits(b, 3);
        i = i + 1;
    };
    if (!b.ok) { return false; };
    let lencode: Huff = { count: [], symbol: [] };
    if (build(lencode, lengths, 0, 19) != 0) { return false; };
    let idx = 0;
    while (idx < nlen + ndist) {
        let sym = decode(b, lencode);
        if (sym < 0) { return false; };
        if (sym < 16) {
            lengths[idx] = sym;
            idx = idx + 1;
        } else {
            let prev = 0;
            let rep = 0;
            if (sym == 16) {
                if (idx == 0) { return false; };
                prev = lengths[idx - 1];
                rep = 3 + getbits(b, 2);
            } else if (sym == 17) {
                rep = 3 + getbits(b, 3);
            } else {
                rep = 11 + getbits(b, 7);
            };
            if (!b.ok || idx + rep > nlen + ndist) { return false; };
            while (rep > 0) {
                lengths[idx] = prev;
                idx = idx + 1;
                rep = rep - 1;
            };
        };
    };
    if (lengths[256] == 0) { return false; };
    let lit: Huff = { count: [], symbol: [] };
    let err = build(lit, lengths, 0, nlen);
    if (err < 0 || (err > 0 && nlen - lit.count[0] != 1)) { return false; };
    let dist: Huff = { count: [], symbol: [] };
    err = build(dist, lengths, nlen, ndist);
    if (err < 0 || (err > 0 && ndist - dist.count[0] != 1)) { return false; };
    codes(b, out, lit, dist, limit)
};

// Inflates the raw deflate stream in `d` from byte `start`; sets `used` to the
// byte just past it in used[0].
def run(d: [byte], start: long, limit: long, used: [long]) -> [byte]? {
    let b: Bits = { d: d, pos: start, buf: 0, cnt: 0, ok: true };
    let out: [byte] = [];
    let last = 0;
    while (last == 0) {
        last = getbits(b, 1);
        let kind = getbits(b, 2);
        if (!b.ok) { return none; };
        if (kind == 0) {
            b.buf = 0;
            b.cnt = 0;
            if (b.pos + 4 > d.length) { return none; };
            let n = d[b.pos] | (d[b.pos + 1] << 8);
            let nn = d[b.pos + 2] | (d[b.pos + 3] << 8);
            if (n != (nn ^ 65535)) { return none; };
            b.pos = b.pos + 4;
            if (b.pos + n > d.length || out.length + n > limit) { return none; };
            let k = 0;
            while (k < n) {
                out += d[b.pos + k];
                k = k + 1;
            };
            b.pos = b.pos + n;
        } else if (kind == 1) {
            let lit: Huff = { count: [], symbol: [] };
            let dist: Huff = { count: [], symbol: [] };
            fixed_tables(lit, dist);
            if (!codes(b, out, lit, dist, limit)) { return none; };
        } else if (kind == 2) {
            if (!dynamic(b, out, limit)) { return none; };
        } else {
            return none;
        };
    };
    used[0] = b.pos;
    some(out)
};

/** Inflates the raw deflate stream `data` (no header, no checksum), or `none`
if it is not valid or would expand past `limit` bytes. */
def inflate(data: [byte], limit: long = 1073741824) -> [byte]? {
    let used: [long] = [0];
    run(data, 0, limit, used)
};

/** Decompresses a zlib stream (RFC 1950: a two-byte header, deflate data, an
Adler-32 of the result), or `none` if the header is wrong, a preset dictionary
is asked for, the data is invalid, or the checksum does not match. */
def decompress(data: [byte], limit: long = 1073741824) -> [byte]? {
    if (data.length < 6) { return none; };
    let cmf = data[0];
    let flg = data[1];
    if (cmf & 15 != 8 || (cmf >> 4) > 7 || ((cmf << 8) | flg) % 31 != 0 || (flg & 32) != 0) { return none; };
    let used: [long] = [0];
    let out = run(data, 2, limit, used);
    if (out == none) { return none; };
    let p = used[0];
    if (p + 4 > data.length) { return none; };
    let want = (data[p] << 24) | (data[p + 1] << 16) | (data[p + 2] << 8) | data[p + 3];
    if (adler32(out!) != want) { return none; };
    out
};

/** Decompresses a gzip file (RFC 1952), or `none` if the header, the data or
the CRC-32 and length trailer is wrong. Only the first member is read. */
def gunzip(data: [byte], limit: long = 1073741824) -> [byte]? {
    if (data.length < 18 || data[0] != 31 || data[1] != 139 || data[2] != 8) { return none; };
    let flg = data[3];
    let p = 10;
    if (flg & 4 != 0) {
        if (p + 2 > data.length) { return none; };
        p = p + 2 + (data[p] | (data[p + 1] << 8));
    };
    if (flg & 8 != 0) {
        while (p < data.length && data[p] != 0) { p = p + 1; };
        p = p + 1;
    };
    if (flg & 16 != 0) {
        while (p < data.length && data[p] != 0) { p = p + 1; };
        p = p + 1;
    };
    if (flg & 2 != 0) { p = p + 2; };
    if (p >= data.length) { return none; };
    let used: [long] = [0];
    let out = run(data, p, limit, used);
    if (out == none) { return none; };
    let q = used[0];
    if (q + 8 > data.length) { return none; };
    let crc = data[q] | (data[q + 1] << 8) | (data[q + 2] << 16) | (data[q + 3] << 24);
    let size = data[q + 4] | (data[q + 5] << 8) | (data[q + 6] << 16) | (data[q + 7] << 24);
    if (crc32(out!) != crc || (out!.length & 4294967295) != size) { return none; };
    out
};

// ── the encoder ─────────────────────────────────────────────────────────

type Out = { b: [byte], acc: long, n: long };

def put(o: Out, v: long, bits: long) -> long {
    o.acc = o.acc | (v << o.n);
    o.n = o.n + bits;
    while (o.n >= 8) {
        o.b += o.acc & 255;
        o.acc = o.acc >>> 8;
        o.n = o.n - 8;
    };
    0
};

// a Huffman code is sent most significant bit first, the rest least first
def put_code(o: Out, code: long, bits: long) -> long {
    let r = 0;
    let i = 0;
    while (i < bits) {
        r = (r << 1) | ((code >> i) & 1);
        i = i + 1;
    };
    put(o, r, bits)
};

def put_lit(o: Out, sym: long) -> long {
    if (sym < 144) { put_code(o, 48 + sym, 8) }
    else if (sym < 256) { put_code(o, 400 + sym - 144, 9) }
    else if (sym < 280) { put_code(o, sym - 256, 7) }
    else { put_code(o, 192 + sym - 280, 8) }
};

def len_sym(len: long) -> long {
    let s = 28;
    while (LBASE[s] > len) { s = s - 1; };
    s
};

def dist_sym(d: long) -> long {
    let s = 29;
    while (DBASE[s] > d) { s = s - 1; };
    s
};

/** The data as stored blocks (deflate's "no compression"): 5 bytes of header
per 65535, so at most that much larger than the input. */
def stored(data: [byte]) -> [byte] {
    let out: [byte] = [];
    let n = data.length;
    let p = 0;
    if (n == 0) {
        out += 1;
        out += 0;
        out += 0;
        out += 255;
        out += 255;
        return out;
    };
    while (p < n) {
        let m = if (n - p > 65535) { 65535 } else { n - p };
        out += if (p + m >= n) { 1 } else { 0 };
        out += m & 255;
        out += m >> 8;
        out += (m ^ 65535) & 255;
        out += (m ^ 65535) >> 8;
        let k = 0;
        while (k < m) {
            out += data[p + k];
            k = k + 1;
        };
        p = p + m;
    };
    out
};

/** Compresses `data` to a raw deflate stream. One block of fixed Huffman codes
over LZ77 matches found along hash chains (`effort` is how many candidates are
tried per position: 1 is quick, 64 finds more); stored blocks instead if those
would not be smaller. */
def deflate(data: [byte], effort: long = 24) -> [byte] {
    let n = data.length;
    let o: Out = { b: [], acc: 0, n: 0 };
    put(o, 1, 1);
    put(o, 1, 2);
    let head: [long] = [];
    let i = 0;
    while (i < 65536) {
        head += -1;
        i = i + 1;
    };
    let prev: [long] = [];
    i = 0;
    while (i < n) {
        prev += -1;
        i = i + 1;
    };
    let p = 0;
    while (p < n) {
        let best = 0;
        let bestd = 0;
        let h = 0;
        if (p + 2 < n) {
            h = ((data[p] << 8) ^ (data[p + 1] << 4) ^ data[p + 2]) & 65535;
            let cand = head[h];
            let tries = 0;
            while (cand >= 0 && p - cand <= 32768 && tries < effort) {
                let l = 0;
                while (l < 258 && p + l < n && data[cand + l] == data[p + l]) { l = l + 1; };
                if (l > best) {
                    best = l;
                    bestd = p - cand;
                };
                cand = prev[cand];
                tries = tries + 1;
            };
        };
        let step = 1;
        if (best >= 3) {
            let ls = len_sym(best);
            put_lit(o, 257 + ls);
            put(o, best - LBASE[ls], LEXT[ls]);
            let ds = dist_sym(bestd);
            put_code(o, ds, 5);
            put(o, bestd - DBASE[ds], DEXT[ds]);
            step = best;
        } else {
            put_lit(o, data[p]);
        };
        // every position the match covers joins its hash chain
        let q = p;
        while (q < p + step) {
            if (q + 2 < n) {
                let hq = ((data[q] << 8) ^ (data[q + 1] << 4) ^ data[q + 2]) & 65535;
                prev[q] = head[hq];
                head[hq] = q;
            };
            q = q + 1;
        };
        p = p + step;
    };
    put_lit(o, 256);
    if (o.n > 0) { put(o, 0, 8 - o.n); };
    if (o.b.length >= n + 5 + 5 * (n / 65535)) { return stored(data); };
    o.b
};

def be32(out: [byte], v: long) -> long {
    out += (v >> 24) & 255;
    out += (v >> 16) & 255;
    out += (v >> 8) & 255;
    out += v & 255;
    0
};

/** Compresses `data` to a zlib stream (RFC 1950). */
def compress(data: [byte], effort: long = 24) -> [byte] {
    let out: [byte] = [120, 156];
    out += deflate(data, effort);
    be32(out, adler32(data));
    out
};

/** Compresses `data` to a gzip file (RFC 1952), no name and no time. */
def gzip(data: [byte], effort: long = 24) -> [byte] {
    let out: [byte] = [31, 139, 8, 0, 0, 0, 0, 0, 0, 255];
    out += deflate(data, effort);
    let c = crc32(data);
    out += c & 255;
    out += (c >> 8) & 255;
    out += (c >> 16) & 255;
    out += (c >> 24) & 255;
    let s = data.length;
    out += s & 255;
    out += (s >> 8) & 255;
    out += (s >> 16) & 255;
    out += (s >> 24) & 255;
    out
};
