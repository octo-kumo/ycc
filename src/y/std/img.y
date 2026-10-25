// std/img.y -- raster images: decode PNG, BMP, GIF, JPEG and PNM from bytes,
// encode PNG, BMP and PPM, and a few pixel operations.
//
//     import img;
//     let im = img.load("photo.png")!;
//     print(im.w, "x", im.h, " ", img.pixel(im, 0, 0));
//     img.save("copy.bmp", img.resize(im, 64, 64, true));
//
// An `Image` is `w`, `h` and `px`, 4 bytes per pixel (red, green, blue, alpha)
// in rows from the top; whatever a file held is expanded to that. `pixel` and
// `set_pixel` pack a colour into one `long` as `0xRRGGBBAA`. The decoders answer
// `none` for a file that is damaged, truncated, of an unsupported kind or
// larger than `MAX_PIXELS`, and never trap on hostile input.
import zlib;
import fs;

export {
    Image, MAX_PIXELS, new_image, rgba, pixel, set_pixel, decode, load, save,
    encode_png, encode_bmp, encode_ppm, format, crop, flip_h, flip_v, resize,
    to_gray, fill
};

type Image = { w: long, h: long, px: [byte] };

/** The most pixels a decoder will allocate (a guard against a header that asks
for the earth). */
const MAX_PIXELS = 134217728;

def zeros(n: long) -> [byte] {
    let z: [byte] = [];
    let chunk: [byte] = [];
    let i = 0;
    while (i < 4096) { chunk += 0; i = i + 1; };
    while (z.length + 4096 <= n) { z += chunk; };
    while (z.length < n) { z += 0; };
    z
};

/** A `w` by `h` image, every pixel transparent black. */
def new_image(w: long, h: long) -> Image {
    let im: Image = { w: w, h: h, px: zeros(w * h * 4) };
    im
};

/** Packs a colour as `0xRRGGBBAA`. Each part is taken modulo 256. */
def rgba(r: long, g: long, b: long, a: long = 255) -> long {
    ((r & 255) << 24) | ((g & 255) << 16) | ((b & 255) << 8) | (a & 255)
};

/** The colour at (`x`, `y`) as `0xRRGGBBAA`; 0 outside the image. */
def pixel(im: Image, x: long, y: long) -> long {
    if (x < 0 || y < 0 || x >= im.w || y >= im.h) { return 0; };
    let o = (y * im.w + x) * 4;
    (im.px[o] << 24) | (im.px[o + 1] << 16) | (im.px[o + 2] << 8) | im.px[o + 3]
};

/** Stores the colour `c` (`0xRRGGBBAA`) at (`x`, `y`); outside the image it does
nothing. */
def set_pixel(im: Image, x: long, y: long, c: long) -> long {
    if (x < 0 || y < 0 || x >= im.w || y >= im.h) { return 0; };
    let o = (y * im.w + x) * 4;
    im.px[o] = (c >>> 24) & 255;
    im.px[o + 1] = (c >>> 16) & 255;
    im.px[o + 2] = (c >>> 8) & 255;
    im.px[o + 3] = c & 255;
    1
};

/** Sets every pixel to `c`. */
def fill(im: Image, c: long) -> long {
    let o = 0;
    let n = im.w * im.h * 4;
    while (o < n) {
        im.px[o] = (c >>> 24) & 255;
        im.px[o + 1] = (c >>> 16) & 255;
        im.px[o + 2] = (c >>> 8) & 255;
        im.px[o + 3] = c & 255;
        o = o + 4;
    };
    0
};

def be32(d: [byte], p: long) -> long {
    (d[p] << 24) | (d[p + 1] << 16) | (d[p + 2] << 8) | d[p + 3]
};
def be16(d: [byte], p: long) -> long { (d[p] << 8) | d[p + 1] };
def le32(d: [byte], p: long) -> long {
    d[p] | (d[p + 1] << 8) | (d[p + 2] << 16) | (d[p + 3] << 24)
};
def le16(d: [byte], p: long) -> long { d[p] | (d[p + 1] << 8) };
def sle32(d: [byte], p: long) -> long {
    let v = le32(d, p);
    if (v >= 2147483648) { v - 4294967296 } else { v }
};

def sized(w: long, h: long) -> bool {
    w > 0 && h > 0 && w <= 1048576 && h <= 1048576 && w * h <= MAX_PIXELS
};

// ── PNG ─────────────────────────────────────────────────────────────────

def paeth(a: long, b: long, c: long) -> long {
    let p = a + b - c;
    let pa = if (p > a) { p - a } else { a - p };
    let pb = if (p > b) { p - b } else { b - p };
    let pc = if (p > c) { p - c } else { c - p };
    if (pa <= pb && pa <= pc) { a } else if (pb <= pc) { b } else { c }
};

/** Sample number `s` of the row starting at `b` in `raw`, `depth` bits each. */
def sample(raw: [byte], b: long, s: long, depth: long) -> long {
    if (depth == 8) { return raw[b + s]; };
    if (depth == 16) { return (raw[b + 2 * s] << 8) | raw[b + 2 * s + 1]; };
    let bit = s * depth;
    (raw[b + (bit >> 3)] >> (8 - depth - (bit & 7))) & ((1 << depth) - 1)
};

def to8(v: long, depth: long) -> long {
    if (depth == 8) { v } else if (depth == 16) { (v + 128) / 257 } else { v * 255 / ((1 << depth) - 1) }
};

def png_channels(ct: long) -> long {
    if (ct == 0 || ct == 3) { 1 } else if (ct == 2) { 3 } else if (ct == 4) { 2 } else { 4 }
};

def png_decode(d: [byte]) -> Image? {
    if (d.length < 33) { return none; };
    let sig: [byte] = [137, 80, 78, 71, 13, 10, 26, 10];
    let i = 0;
    while (i < 8) { if (d[i] != sig[i]) { return none; }; i = i + 1; };
    let w = 0;
    let h = 0;
    let depth = 0;
    let ct = 0;
    let inter = 0;
    let seen = false;
    let pal: [byte] = [];
    let trns: [byte] = [];
    let idat: [byte] = [];
    let ended = false;
    let p = 8;
    while (p + 12 <= d.length && !ended) {
        let len = be32(d, p);
        if (p + 12 + len > d.length) { return none; };
        if (crc_of(d, p + 4, len + 4) != be32(d, p + 8 + len)) { return none; };
        let ty = from_bytes(d[p + 4:p + 8]);
        let body = d[p + 8:p + 8 + len];
        if (ty == "IHDR") {
            if (len != 13 || seen) { return none; };
            seen = true;
            w = be32(body, 0);
            h = be32(body, 4);
            depth = body[8];
            ct = body[9];
            inter = body[12];
            if (body[10] != 0 || body[11] != 0 || inter > 1) { return none; };
        } else if (!seen) {
            return none;
        } else if (ty == "PLTE") {
            pal = body;
        } else if (ty == "tRNS") {
            trns = body;
        } else if (ty == "IDAT") {
            idat += body;
        } else if (ty == "IEND") {
            ended = true;
        };
        p = p + 12 + len;
    };
    if (!seen || idat.length == 0 || !sized(w, h)) { return none; };
    let okd = (ct == 0 && (depth == 1 || depth == 2 || depth == 4 || depth == 8 || depth == 16))
        || (ct == 3 && (depth == 1 || depth == 2 || depth == 4 || depth == 8))
        || ((ct == 2 || ct == 4 || ct == 6) && (depth == 8 || depth == 16));
    if (!okd) { return none; };
    if (ct == 3 && (pal.length == 0 || pal.length % 3 != 0 || pal.length > 768)) { return none; };
    let ch = png_channels(ct);
    let bits = ch * depth;
    let bpp = if (bits >= 8) { bits / 8 } else { 1 };
    let px0: [long] = [0];
    let py0: [long] = [0];
    let pdx: [long] = [1];
    let pdy: [long] = [1];
    if (inter == 1) {
        px0 = [0, 4, 0, 2, 0, 1, 0];
        py0 = [0, 0, 4, 0, 2, 0, 1];
        pdx = [8, 8, 4, 4, 2, 2, 1];
        pdy = [8, 8, 8, 4, 4, 2, 2];
    };
    let np = px0.length;
    let total = 0;
    let k = 0;
    while (k < np) {
        let pw = (w - px0[k] + pdx[k] - 1) / pdx[k];
        let ph = (h - py0[k] + pdy[k] - 1) / pdy[k];
        if (pw > 0 && ph > 0) { total = total + ph * (1 + (pw * bits + 7) / 8); };
        k = k + 1;
    };
    let rawo = zlib.decompress(idat, total);
    if (rawo == none) { return none; };
    let raw = rawo!;
    if (raw.length != total) { return none; };
    let out = new_image(w, h);
    let off = 0;
    k = 0;
    while (k < np) {
        let pw = (w - px0[k] + pdx[k] - 1) / pdx[k];
        let ph = (h - py0[k] + pdy[k] - 1) / pdy[k];
        if (pw > 0 && ph > 0) {
            let rb = (pw * bits + 7) / 8;
            let r = 0;
            while (r < ph) {
                let f = raw[off];
                let b = off + 1;
                let pb = off - rb;
                if (f > 4) { return none; };
                let x = 0;
                while (x < rb) {
                    let a = 0;
                    if (x >= bpp) { a = raw[b + x - bpp]; };
                    let up = 0;
                    if (r > 0) { up = raw[pb + x]; };
                    let c = 0;
                    if (x >= bpp && r > 0) { c = raw[pb + x - bpp]; };
                    let v = raw[b + x];
                    if (f == 1) { v = v + a; } else if (f == 2) { v = v + up; } else if (f == 3) { v = v + (a + up) / 2; } else if (f == 4) { v = v + paeth(a, up, c); };
                    raw[b + x] = v & 255;
                    x = x + 1;
                };
                let y = py0[k] + r * pdy[k];
                x = 0;
                while (x < pw) {
                    let o = (y * w + px0[k] + x * pdx[k]) * 4;
                    let rr = 0;
                    let gg = 0;
                    let bb = 0;
                    let aa = 255;
                    if (ct == 0) {
                        let v = sample(raw, b, x, depth);
                        rr = to8(v, depth);
                        gg = rr;
                        bb = rr;
                        if (trns.length >= 2 && be16(trns, 0) == v) { aa = 0; };
                    } else if (ct == 2) {
                        let v0 = sample(raw, b, x * 3, depth);
                        let v1 = sample(raw, b, x * 3 + 1, depth);
                        let v2 = sample(raw, b, x * 3 + 2, depth);
                        rr = to8(v0, depth);
                        gg = to8(v1, depth);
                        bb = to8(v2, depth);
                        if (trns.length >= 6 && be16(trns, 0) == v0 && be16(trns, 2) == v1 && be16(trns, 4) == v2) { aa = 0; };
                    } else if (ct == 3) {
                        let v = sample(raw, b, x, depth);
                        if (v * 3 + 2 >= pal.length) { return none; };
                        rr = pal[v * 3];
                        gg = pal[v * 3 + 1];
                        bb = pal[v * 3 + 2];
                        if (v < trns.length) { aa = trns[v]; };
                    } else if (ct == 4) {
                        rr = to8(sample(raw, b, x * 2, depth), depth);
                        gg = rr;
                        bb = rr;
                        aa = to8(sample(raw, b, x * 2 + 1, depth), depth);
                    } else {
                        rr = to8(sample(raw, b, x * 4, depth), depth);
                        gg = to8(sample(raw, b, x * 4 + 1, depth), depth);
                        bb = to8(sample(raw, b, x * 4 + 2, depth), depth);
                        aa = to8(sample(raw, b, x * 4 + 3, depth), depth);
                    };
                    out.px[o] = rr;
                    out.px[o + 1] = gg;
                    out.px[o + 2] = bb;
                    out.px[o + 3] = aa;
                    x = x + 1;
                };
                off = off + 1 + rb;
                r = r + 1;
            };
        };
        k = k + 1;
    };
    some(out)
};

def crc_of(d: [byte], p: long, n: long) -> long {
    zlib.crc32(d[p:p + n])
};

def put32(o: [byte], v: long) -> long {
    o += (v >>> 24) & 255;
    o += (v >>> 16) & 255;
    o += (v >>> 8) & 255;
    o += v & 255;
    0
};

def png_chunk(out: [byte], ty: str, body: [byte]) -> long {
    put32(out, body.length);
    let t = bytes(ty) + body;
    out += t;
    put32(out, zlib.crc32(t));
    0
};

/** `im` as a PNG file: RGB when every pixel is opaque, RGBA otherwise, each row
filtered with whichever of the five PNG filters leaves the smallest sum. */
def encode_png(im: Image) -> [byte] {
    let opaque = true;
    let i = 3;
    let n = im.w * im.h * 4;
    while (i < n) { if (im.px[i] != 255) { opaque = false; break; }; i = i + 4; };
    let ch = if (opaque) { 3 } else { 4 };
    let rb = im.w * ch;
    let raw: [byte] = [];
    let prev: [byte] = [];
    let y = 0;
    while (y < im.h) {
        let row: [byte] = [];
        let x = 0;
        while (x < im.w) {
            let o = (y * im.w + x) * 4;
            row += im.px[o];
            row += im.px[o + 1];
            row += im.px[o + 2];
            if (!opaque) { row += im.px[o + 3]; };
            x = x + 1;
        };
        let best: [byte] = [];
        let bestsum = -1;
        let f = 0;
        while (f < 5) {
            let cand: [byte] = [f];
            let sum = 0;
            let q = 0;
            while (q < rb) {
                let a = 0;
                if (q >= ch) { a = row[q - ch]; };
                let up = 0;
                if (y > 0) { up = prev[q]; };
                let c = 0;
                if (q >= ch && y > 0) { c = prev[q - ch]; };
                let pr = 0;
                if (f == 1) { pr = a; } else if (f == 2) { pr = up; } else if (f == 3) { pr = (a + up) / 2; } else if (f == 4) { pr = paeth(a, up, c); };
                let v = (row[q] - pr) & 255;
                cand += v;
                sum = sum + (if (v < 128) { v } else { 256 - v });
                q = q + 1;
            };
            if (bestsum < 0 || sum < bestsum) { bestsum = sum; best = cand; };
            f = f + 1;
        };
        raw += best;
        prev = row;
        y = y + 1;
    };
    let out: [byte] = [137, 80, 78, 71, 13, 10, 26, 10];
    let hd: [byte] = [];
    put32(hd, im.w);
    put32(hd, im.h);
    hd += 8;
    hd += (if (opaque) { 2 } else { 6 });
    hd += 0;
    hd += 0;
    hd += 0;
    png_chunk(out, "IHDR", hd);
    png_chunk(out, "IDAT", zlib.compress(raw, 16));
    let none_body: [byte] = [];
    png_chunk(out, "IEND", none_body);
    out
};

// ── BMP ─────────────────────────────────────────────────────────────────

def mask_shift(m: long) -> long {
    let s = 0;
    if (m == 0) { return 0; };
    while ((m >> s) & 1 == 0) { s = s + 1; };
    s
};
def mask_bits(m: long) -> long {
    let s = mask_shift(m);
    let n = 0;
    while (((m >> (s + n)) & 1) == 1 && n < 32) { n = n + 1; };
    n
};
def scale_mask(v: long, bits: long) -> long {
    if (bits == 0) { 255 } else if (bits >= 8) { v >> (bits - 8) } else { v * 255 / ((1 << bits) - 1) }
};

/** BI_RLE8 / BI_RLE4 data from `start` as the plain padded rows BI_RGB holds. */
def rle_expand(d: [byte], start: long, w: long, h: long, bpp: long, rb: long) -> [byte] {
    let buf = zeros(rb * h);
    let p = start;
    let x = 0;
    let y = 0;
    while (p + 1 < d.length && y < h) {
        let n = d[p];
        let v = d[p + 1];
        p = p + 2;
        if (n > 0) {
            let i = 0;
            while (i < n) {
                let val = v;
                if (bpp == 4) { val = if (i & 1 == 0) { v >> 4 } else { v & 15 }; };
                rle_put(buf, rb, w, h, bpp, x, y, val);
                x = x + 1;
                i = i + 1;
            };
        } else if (v == 0) {
            x = 0;
            y = y + 1;
        } else if (v == 1) {
            break;
        } else if (v == 2) {
            if (p + 1 >= d.length) { break; };
            x = x + d[p];
            y = y + d[p + 1];
            p = p + 2;
        } else {
            let bytes_ = if (bpp == 8) { v + 0 } else { (v + 1) / 2 };
            let i = 0;
            while (i < v && p + (if (bpp == 8) { i } else { i / 2 }) < d.length) {
                let val = 0;
                if (bpp == 8) { val = d[p + i]; } else { val = if (i & 1 == 0) { d[p + i / 2] >> 4 } else { d[p + i / 2] & 15 }; };
                rle_put(buf, rb, w, h, bpp, x, y, val);
                x = x + 1;
                i = i + 1;
            };
            p = p + bytes_ + (bytes_ & 1);
        };
    };
    buf
};

def rle_put(buf: [byte], rb: long, w: long, h: long, bpp: long, x: long, y: long, v: long) -> long {
    if (x >= w || y >= h) { return 0; };
    if (bpp == 8) {
        buf[y * rb + x] = v;
    } else if (x & 1 == 0) {
        buf[y * rb + (x >> 1)] = (buf[y * rb + (x >> 1)] & 15) | (v << 4);
    } else {
        buf[y * rb + (x >> 1)] = (buf[y * rb + (x >> 1)] & 240) | v;
    };
    0
};

def bmp_decode(d0: [byte]) -> Image? {
    let d = d0;
    if (d.length < 26 || d[0] != 66 || d[1] != 77) { return none; };
    let dataoff = le32(d, 10);
    let hs = le32(d, 14);
    let w = 0;
    let h = 0;
    let bpp = 0;
    let comp = 0;
    let ncol = 0;
    if (hs == 12) {
        w = le16(d, 18);
        h = le16(d, 20);
        bpp = le16(d, 24);
    } else if (hs >= 40 && hs <= d.length - 14) {
        w = sle32(d, 18);
        h = sle32(d, 22);
        bpp = le16(d, 28);
        comp = le32(d, 30);
        ncol = le32(d, 46);
    } else {
        return none;
    };
    let topdown = h < 0;
    if (topdown) { h = 0 - h; };
    if (!sized(w, h)) { return none; };
    if (comp != 0 && comp != 3 && !(comp == 1 && bpp == 8) && !(comp == 2 && bpp == 4)) { return none; };
    if (bpp != 1 && bpp != 4 && bpp != 8 && bpp != 16 && bpp != 24 && bpp != 32) { return none; };
    if (comp == 3 && bpp != 16 && bpp != 32) { return none; };
    let rm = 0;
    let gm = 0;
    let bm = 0;
    let am = 0;
    let p = 14 + hs;
    if (comp == 3) {
        if (hs >= 52) {
            rm = le32(d, 54);
            gm = le32(d, 58);
            bm = le32(d, 62);
            if (hs >= 56) { am = le32(d, 66); };
        } else {
            if (p + 12 > d.length) { return none; };
            rm = le32(d, p);
            gm = le32(d, p + 4);
            bm = le32(d, p + 8);
            p = p + 12;
        };
    } else if (bpp == 16) {
        rm = 31744;
        gm = 992;
        bm = 31;
    };
    let pal: [byte] = [];
    if (bpp <= 8) {
        let n = if (ncol > 0) { ncol } else { 1 << bpp };
        if (n > 256) { return none; };
        let es = if (hs == 12) { 3 } else { 4 };
        if (p + n * es > d.length) { return none; };
        let i = 0;
        while (i < n) {
            pal += d[p + i * es + 2];
            pal += d[p + i * es + 1];
            pal += d[p + i * es];
            i = i + 1;
        };
    };
    let rb = ((w * bpp + 31) / 32) * 4;
    if (dataoff < 14 || dataoff > d.length) { return none; };
    if (comp == 1 || comp == 2) {
        d = d[0:dataoff] + rle_expand(d, dataoff, w, h, bpp, rb);
        comp = 0;
    };
    if (dataoff + rb * h > d.length) { return none; };
    let out = new_image(w, h);
    let anya = false;
    let y = 0;
    while (y < h) {
        let sy = if (topdown) { y } else { h - 1 - y };
        let b = dataoff + sy * rb;
        let x = 0;
        while (x < w) {
            let o = (y * w + x) * 4;
            let r = 0;
            let g = 0;
            let bl = 0;
            let a = 255;
            if (bpp <= 8) {
                let bit = x * bpp;
                let idx = (d[b + (bit >> 3)] >> (8 - bpp - (bit & 7))) & ((1 << bpp) - 1);
                if (idx * 3 + 2 >= pal.length) { return none; };
                r = pal[idx * 3];
                g = pal[idx * 3 + 1];
                bl = pal[idx * 3 + 2];
            } else if (bpp == 24) {
                bl = d[b + x * 3];
                g = d[b + x * 3 + 1];
                r = d[b + x * 3 + 2];
            } else {
                let v = if (bpp == 32) { le32(d, b + x * 4) } else { le16(d, b + x * 2) };
                if (comp == 0 && bpp == 32) {
                    bl = v & 255;
                    g = (v >> 8) & 255;
                    r = (v >> 16) & 255;
                    a = (v >> 24) & 255;
                    if (a != 0) { anya = true; };
                } else {
                    r = scale_mask((v & rm) >> mask_shift(rm), mask_bits(rm));
                    g = scale_mask((v & gm) >> mask_shift(gm), mask_bits(gm));
                    bl = scale_mask((v & bm) >> mask_shift(bm), mask_bits(bm));
                    if (am != 0) { a = scale_mask((v & am) >> mask_shift(am), mask_bits(am)); anya = true; };
                };
            };
            out.px[o] = r;
            out.px[o + 1] = g;
            out.px[o + 2] = bl;
            out.px[o + 3] = a;
            x = x + 1;
        };
        y = y + 1;
    };
    if (bpp == 32 && comp == 0 && !anya) {
        let i = 3;
        while (i < w * h * 4) { out.px[i] = 255; i = i + 4; };
    };
    some(out)
};

def put16le(o: [byte], v: long) -> long {
    o += v & 255;
    o += (v >> 8) & 255;
    0
};
def put32le(o: [byte], v: long) -> long {
    o += v & 255;
    o += (v >> 8) & 255;
    o += (v >> 16) & 255;
    o += (v >> 24) & 255;
    0
};

/** `im` as a BMP file: 24-bit when every pixel is opaque, else 32-bit with an
alpha mask (a version 4 header). */
def encode_bmp(im: Image) -> [byte] {
    let opaque = true;
    let i = 3;
    while (i < im.w * im.h * 4) { if (im.px[i] != 255) { opaque = false; break; }; i = i + 4; };
    let bpp = if (opaque) { 24 } else { 32 };
    let rb = ((im.w * bpp + 31) / 32) * 4;
    let hs = if (opaque) { 40 } else { 108 };
    let off = 14 + hs;
    let out: [byte] = [66, 77];
    put32le(out, off + rb * im.h);
    put32le(out, 0);
    put32le(out, off);
    put32le(out, hs);
    put32le(out, im.w);
    put32le(out, im.h);
    put16le(out, 1);
    put16le(out, bpp);
    put32le(out, if (opaque) { 0 } else { 3 });
    put32le(out, rb * im.h);
    put32le(out, 2835);
    put32le(out, 2835);
    put32le(out, 0);
    put32le(out, 0);
    if (!opaque) {
        put32le(out, 16711680);
        put32le(out, 65280);
        put32le(out, 255);
        put32le(out, 4278190080);
        put32le(out, 1934772034);
        let k = 0;
        while (k < 48) { out += 0; k = k + 1; };
    };
    let y = im.h - 1;
    while (y >= 0) {
        let x = 0;
        while (x < im.w) {
            let o = (y * im.w + x) * 4;
            out += im.px[o + 2];
            out += im.px[o + 1];
            out += im.px[o];
            if (!opaque) { out += im.px[o + 3]; };
            x = x + 1;
        };
        let pad = rb - im.w * (bpp / 8);
        while (pad > 0) { out += 0; pad = pad - 1; };
        y = y - 1;
    };
    out
};

// ── PNM ─────────────────────────────────────────────────────────────────

type Cur = { d: [byte], p: long };

def pnm_skip(c: Cur) -> long {
    while (c.p < c.d.length) {
        let ch = c.d[c.p];
        if (ch == 35) {
            while (c.p < c.d.length && c.d[c.p] != 10) { c.p = c.p + 1; };
        } else if (ch == 32 || ch == 9 || ch == 10 || ch == 13 || ch == 11 || ch == 12) {
            c.p = c.p + 1;
        } else {
            break;
        };
    };
    0
};

/** The next decimal number of a PNM header or ASCII body, or -1. */
def pnm_num(c: Cur) -> long {
    pnm_skip(c);
    if (c.p >= c.d.length || c.d[c.p] < 48 || c.d[c.p] > 57) { return -1; };
    let v = 0;
    while (c.p < c.d.length && c.d[c.p] >= 48 && c.d[c.p] <= 57) {
        v = v * 10 + c.d[c.p] - 48;
        if (v > 1000000000) { return -1; };
        c.p = c.p + 1;
    };
    v
};

def pnm_decode(d: [byte]) -> Image? {
    if (d.length < 3 || d[0] != 80 || d[1] < 49 || d[1] > 54) { return none; };
    let kind = d[1] - 48;
    let c: Cur = { d: d, p: 2 };
    let w = pnm_num(c);
    let h = pnm_num(c);
    let maxv = 1;
    if (kind != 1 && kind != 4) { maxv = pnm_num(c); };
    if (w < 0 || h < 0 || maxv < 1 || maxv > 65535 || !sized(w, h)) { return none; };
    let ascii = kind <= 3;
    if (!ascii) { c.p = c.p + 1; };
    let ch = if (kind == 3 || kind == 6) { 3 } else { 1 };
    let out = new_image(w, h);
    let wide = maxv > 255;
    let rowbits = (w + 7) / 8;
    let y = 0;
    while (y < h) {
        let x = 0;
        while (x < w) {
            let v: [long] = [0, 0, 0];
            let s = 0;
            while (s < ch) {
                let val = 0;
                if (kind == 1) {
                    pnm_skip(c);
                    if (c.p >= d.length || (d[c.p] != 48 && d[c.p] != 49)) { return none; };
                    val = (if (d[c.p] == 48) { 255 } else { 0 });
                    c.p = c.p + 1;
                } else if (kind == 4) {
                    let q = c.p + y * rowbits + (x >> 3);
                    if (q >= d.length) { return none; };
                    val = (if ((d[q] >> (7 - (x & 7))) & 1 == 1) { 0 } else { 255 });
                } else if (ascii) {
                    let n = pnm_num(c);
                    if (n < 0 || n > maxv) { return none; };
                    val = n * 255 / maxv;
                } else if (wide) {
                    if (c.p + 2 > d.length) { return none; };
                    val = ((d[c.p] << 8) | d[c.p + 1]) * 255 / maxv;
                    c.p = c.p + 2;
                } else {
                    if (c.p >= d.length) { return none; };
                    val = d[c.p] * 255 / maxv;
                    c.p = c.p + 1;
                };
                v[s] = val;
                s = s + 1;
            };
            let o = (y * w + x) * 4;
            out.px[o] = v[0];
            out.px[o + 1] = if (ch == 3) { v[1] } else { v[0] };
            out.px[o + 2] = if (ch == 3) { v[2] } else { v[0] };
            out.px[o + 3] = 255;
            x = x + 1;
        };
        y = y + 1;
    };
    some(out)
};

/** `im` as a binary PPM (P6); the alpha channel is dropped. */
def encode_ppm(im: Image) -> [byte] {
    let out = bytes("P6\n" + tostring(im.w) + " " + tostring(im.h) + "\n255\n");
    let i = 0;
    let n = im.w * im.h * 4;
    while (i < n) {
        out += im.px[i];
        out += im.px[i + 1];
        out += im.px[i + 2];
        i = i + 4;
    };
    out
};


// ── GIF ─────────────────────────────────────────────────────────────────

/** The first frame of a GIF, drawn on the logical screen: pixels the frame does
not cover, and its transparent colour, are transparent. */
def gif_decode(d: [byte]) -> Image? {
    if (d.length < 14 || d[0] != 71 || d[1] != 73 || d[2] != 70) { return none; };
    let w = le16(d, 6);
    let h = le16(d, 8);
    if (!sized(w, h)) { return none; };
    let fl = d[10];
    let p = 13;
    let gct: [byte] = [];
    if (fl & 128 != 0) {
        let n = 3 << ((fl & 7) + 1);
        if (p + n > d.length) { return none; };
        gct = d[p:p + n];
        p = p + n;
    };
    let transp = -1;
    while (p < d.length) {
        let t = d[p];
        p = p + 1;
        if (t == 33) {
            if (p >= d.length) { return none; };
            let label = d[p];
            p = p + 1;
            if (label == 249 && p + 5 < d.length && d[p] >= 4) {
                if (d[p + 1] & 1 != 0) { transp = d[p + 4]; };
            };
            while (p < d.length && d[p] != 0) { p = p + d[p] + 1; };
            p = p + 1;
        } else if (t == 44) {
            if (p + 9 > d.length) { return none; };
            let fx = le16(d, p);
            let fy = le16(d, p + 2);
            let fw = le16(d, p + 4);
            let fh = le16(d, p + 6);
            let ff = d[p + 8];
            p = p + 9;
            let ct = gct;
            if (ff & 128 != 0) {
                let n = 3 << ((ff & 7) + 1);
                if (p + n > d.length) { return none; };
                ct = d[p:p + n];
                p = p + n;
            };
            if (p >= d.length || fw == 0 || fh == 0 || fw * fh > MAX_PIXELS) { return none; };
            let mincode = d[p];
            p = p + 1;
            if (mincode < 2 || mincode > 8) { return none; };
            let data: [byte] = [];
            while (p < d.length && d[p] != 0) {
                if (p + d[p] + 1 > d.length) { return none; };
                data += d[p + 1:p + 1 + d[p]];
                p = p + d[p] + 1;
            };
            let idx = lzw(data, mincode, fw * fh);
            if (idx.length < fw * fh) { return none; };
            let out = new_image(w, h);
            let inter = ff & 64 != 0;
            // row order of an interlaced frame: the source row for each output row
            let rowmap: [long] = [];
            if (inter) {
                let starts: [long] = [0, 4, 2, 1];
                let steps: [long] = [8, 8, 4, 2];
                let k = 0;
                while (k < 4) {
                    let r = starts[k];
                    while (r < fh) { rowmap += r; r = r + steps[k]; };
                    k = k + 1;
                };
            };
            let r = 0;
            while (r < fh) {
                let y = fy + (if (inter) { rowmap[r] } else { r });
                let x = 0;
                while (x < fw) {
                    let ci = idx[r * fw + x];
                    if (y < h && fx + x < w && ci != transp) {
                        if (ci * 3 + 2 >= ct.length) { return none; };
                        let o = (y * w + fx + x) * 4;
                        out.px[o] = ct[ci * 3];
                        out.px[o + 1] = ct[ci * 3 + 1];
                        out.px[o + 2] = ct[ci * 3 + 2];
                        out.px[o + 3] = 255;
                    };
                    x = x + 1;
                };
                r = r + 1;
            };
            return some(out);
        } else {
            return none;
        };
    };
    none
};

/** GIF's variable-width LZW: up to `want` colour indices from `data`. */
def lzw(data: [byte], mincode: long, want: long) -> [byte] {
    let out: [byte] = [];
    let clear = 1 << mincode;
    let eoi = clear + 1;
    let prefix: [long] = [];
    let suffix: [byte] = [];
    let i = 0;
    while (i < 4096) { prefix += 0; suffix += 0; i = i + 1; };
    let size = mincode + 1;
    let next = clear + 2;
    let prev = -1;
    let acc = 0;
    let nacc = 0;
    let p = 0;
    let stack: [byte] = [];
    while (out.length < want) {
        while (nacc < size && p < data.length) {
            acc = acc | (data[p] << nacc);
            nacc = nacc + 8;
            p = p + 1;
        };
        if (nacc < size) { break; };
        let code = acc & ((1 << size) - 1);
        acc = acc >> size;
        nacc = nacc - size;
        if (code == clear) {
            size = mincode + 1;
            next = clear + 2;
            prev = -1;
        } else if (code == eoi) {
            break;
        } else {
            let cur = code;
            stack = [];
            if (code >= next) {
                if (prev < 0 || code > next) { break; };
                cur = prev;
            };
            let first = 0;
            while (cur >= clear + 2) { stack += suffix[cur]; cur = prefix[cur]; };
            if (cur >= clear) { break; };
            first = cur;
            stack += cur;
            let j = stack.length - 1;
            if (code >= next) {
                // the code being defined: the previous string plus its own first byte
                let c = 0;
                let q = stack.length - 1;
                c = stack[q];
                j = q;
                while (j >= 0) { out += stack[j]; j = j - 1; };
                out += c;
            } else {
                while (j >= 0) { out += stack[j]; j = j - 1; };
            };
            if (prev >= 0 && next < 4096) {
                prefix[next] = prev;
                suffix[next] = first;
                next = next + 1;
                if (next == (1 << size) && size < 12) { size = size + 1; };
            };
            prev = code;
        };
    };
    out
};


// ── JPEG ────────────────────────────────────────────────────────────────

type Ht = { mincode: [long], maxcode: [long], valptr: [long], vals: [byte], ok: bool };
type Br = { d: [byte], p: long, acc: long, n: long, hit: bool };
type Comp = { id: long, h: long, v: long, tq: long, bw: long, bh: long, coef: [long], pred: long, td: long, ta: long, cw: long, ch: long };

const ZZ = [0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63];

def ht_empty() -> Ht {
    let t: Ht = { mincode: [], maxcode: [], valptr: [], vals: [], ok: false };
    t
};

def ht_build(counts: [byte], vals: [byte]) -> Ht {
    let t = ht_empty();
    t.mincode += 0;
    t.maxcode += -1;
    t.valptr += 0;
    let code = 0;
    let k = 0;
    let l = 1;
    while (l <= 16) {
        t.valptr += k;
        t.mincode += code;
        code = code + counts[l - 1];
        k = k + counts[l - 1];
        t.maxcode += (if (counts[l - 1] > 0) { code - 1 } else { -1 });
        code = code << 1;
        l = l + 1;
    };
    t.vals = vals;
    t.ok = true;
    t
};

def br_bit(b: Br) -> long {
    if (b.n == 0) {
        if (b.hit || b.p >= b.d.length) { b.hit = true; return 0; };
        let c = b.d[b.p];
        if (c == 255) {
            if (b.p + 1 < b.d.length && b.d[b.p + 1] == 0) {
                b.p = b.p + 2;
            } else {
                b.hit = true;
                return 0;
            };
        } else {
            b.p = b.p + 1;
        };
        b.acc = c;
        b.n = 8;
    };
    b.n = b.n - 1;
    (b.acc >> b.n) & 1
};

def br_bits(b: Br, n: long) -> long {
    let v = 0;
    let i = 0;
    while (i < n) { v = (v << 1) | br_bit(b); i = i + 1; };
    v
};

def br_huff(b: Br, t: Ht) -> long {
    let code = 0;
    let l = 1;
    while (l <= 16) {
        code = (code << 1) | br_bit(b);
        if (code <= t.maxcode[l]) {
            let ix = t.valptr[l] + code - t.mincode[l];
            if (ix < 0 || ix >= t.vals.length) { return -1; };
            return t.vals[ix];
        };
        l = l + 1;
    };
    -1
};

def extend(v: long, s: long) -> long {
    if (s == 0) { 0 } else if (v < (1 << (s - 1))) { v - (1 << s) + 1 } else { v }
};

type Jp = { w: long, h: long, prog: bool, hmax: long, vmax: long, mcux: long, mcuy: long, ri: long, eobrun: long };

/** Restart bookkeeping between MCUs: byte-align, swallow the RSTn marker. */
def jp_restart(b: Br, comps: [Comp], j: Jp) -> long {
    b.n = 0;
    b.acc = 0;
    // find the marker
    let p = b.p;
    while (p + 1 < b.d.length && !(b.d[p] == 255 && b.d[p + 1] >= 208 && b.d[p + 1] <= 215)) {
        if (b.d[p] == 255 && b.d[p + 1] != 0 && b.d[p + 1] != 255) { break; };
        p = p + 1;
    };
    if (p + 1 < b.d.length && b.d[p] == 255 && b.d[p + 1] >= 208 && b.d[p + 1] <= 215) { b.p = p + 2; } else { b.p = p; };
    b.hit = false;
    foreach (c in comps) { c.pred = 0; };
    j.eobrun = 0;
    0
};

/** One block of a scan, into `c.coef` at `o`. */
def jp_block(b: Br, c: Comp, o: long, dc: Ht, ac: Ht, j: Jp, ss: long, se: long, ah: long, al: long) -> bool {
    if (!j.prog) {
        let t = br_huff(b, dc);
        if (t < 0 || t > 16) { return false; };
        c.pred = c.pred + extend(br_bits(b, t), t);
        c.coef[o] = c.pred;
        let k = 1;
        while (k < 64) {
            let rs = br_huff(b, ac);
            if (rs < 0) { return false; };
            let r = rs >> 4;
            let s = rs & 15;
            if (s == 0) {
                if (r != 15) { break; };
                k = k + 16;
            } else {
                k = k + r;
                if (k > 63) { return false; };
                c.coef[o + ZZ[k]] = extend(br_bits(b, s), s);
                k = k + 1;
            };
        };
        return true;
    };
    if (ss == 0) {
        if (ah == 0) {
            let t = br_huff(b, dc);
            if (t < 0 || t > 16) { return false; };
            c.pred = c.pred + extend(br_bits(b, t), t);
            c.coef[o] = c.pred << al;
        } else {
            if (br_bit(b) == 1) { c.coef[o] = c.coef[o] | (1 << al); };
        };
        return true;
    };
    if (ah == 0) {
        if (j.eobrun > 0) { j.eobrun = j.eobrun - 1; return true; };
        let k = ss;
        while (k <= se) {
            let rs = br_huff(b, ac);
            if (rs < 0) { return false; };
            let r = rs >> 4;
            let s = rs & 15;
            if (s == 0) {
                if (r < 15) {
                    j.eobrun = (1 << r) - 1;
                    if (r > 0) { j.eobrun = j.eobrun + br_bits(b, r); };
                    break;
                };
                k = k + 16;
            } else {
                k = k + r;
                if (k > 63) { return false; };
                c.coef[o + ZZ[k]] = extend(br_bits(b, s), s) * (1 << al);
                k = k + 1;
            };
        };
        return true;
    };
    // successive approximation refinement of AC coefficients
    let p1 = 1 << al;
    let m1 = 0 - (1 << al);
    let k = ss;
    if (j.eobrun == 0) {
        while (k <= se) {
            let rs = br_huff(b, ac);
            if (rs < 0) { return false; };
            let r = rs >> 4;
            let s = rs & 15;
            let val = 0;
            if (s != 0) {
                val = if (br_bit(b) == 1) { p1 } else { m1 };
            } else if (r != 15) {
                j.eobrun = 1 << r;
                if (r > 0) { j.eobrun = j.eobrun + br_bits(b, r); };
                break;
            };
            while (k <= se) {
                let q = o + ZZ[k];
                if (c.coef[q] != 0) {
                    if (br_bit(b) == 1) {
                        if (c.coef[q] & p1 == 0) {
                            if (c.coef[q] >= 0) { c.coef[q] = c.coef[q] + p1; } else { c.coef[q] = c.coef[q] + m1; };
                        };
                    };
                } else {
                    r = r - 1;
                    if (r < 0) { break; };
                };
                k = k + 1;
            };
            if (s != 0 && k <= 63) { c.coef[o + ZZ[k]] = val; };
            k = k + 1;
        };
    };
    if (j.eobrun > 0) {
        while (k <= se) {
            let q = o + ZZ[k];
            if (c.coef[q] != 0) {
                if (br_bit(b) == 1) {
                    if (c.coef[q] & p1 == 0) {
                        if (c.coef[q] >= 0) { c.coef[q] = c.coef[q] + p1; } else { c.coef[q] = c.coef[q] + m1; };
                    };
                };
            };
            k = k + 1;
        };
        j.eobrun = j.eobrun - 1;
    };
    true
};

def clamp8(v: long) -> long { if (v < 0) { 0 } else if (v > 255) { 255 } else { v } };

/** libjpeg's accurate integer inverse DCT of the 8x8 block of `coef` at `o`
(already dequantised), written into `plane` (row stride `stride`) at `po`. */
def idct(coef: [long], o: long, ws: [long], plane: [byte], po: long, stride: long) -> long {
    let c = 0;
    while (c < 8) {
        let z2 = coef[o + c + 16];
        let z3 = coef[o + c + 48];
        let z1 = (z2 + z3) * 4433;
        let t2 = z1 + z3 * -15137;
        let t3 = z1 + z2 * 6270;
        z2 = coef[o + c];
        z3 = coef[o + c + 32];
        let t0 = (z2 + z3) << 13;
        let t1 = (z2 - z3) << 13;
        let t10 = t0 + t3;
        let t13 = t0 - t3;
        let t11 = t1 + t2;
        let t12 = t1 - t2;
        t0 = coef[o + c + 56];
        t1 = coef[o + c + 40];
        t2 = coef[o + c + 24];
        t3 = coef[o + c + 8];
        z1 = t0 + t3;
        z2 = t1 + t2;
        z3 = t0 + t2;
        let z4 = t1 + t3;
        let z5 = (z3 + z4) * 9633;
        t0 = t0 * 2446;
        t1 = t1 * 16819;
        t2 = t2 * 25172;
        t3 = t3 * 12299;
        z1 = z1 * -7373;
        z2 = z2 * -20995;
        z3 = z3 * -16069 + z5;
        z4 = z4 * -3196 + z5;
        t0 = t0 + z1 + z3;
        t1 = t1 + z2 + z4;
        t2 = t2 + z2 + z3;
        t3 = t3 + z1 + z4;
        ws[c] = (t10 + t3 + 1024) >> 11;
        ws[c + 56] = (t10 - t3 + 1024) >> 11;
        ws[c + 8] = (t11 + t2 + 1024) >> 11;
        ws[c + 48] = (t11 - t2 + 1024) >> 11;
        ws[c + 16] = (t12 + t1 + 1024) >> 11;
        ws[c + 40] = (t12 - t1 + 1024) >> 11;
        ws[c + 24] = (t13 + t0 + 1024) >> 11;
        ws[c + 32] = (t13 - t0 + 1024) >> 11;
        c = c + 1;
    };
    let r = 0;
    while (r < 8) {
        let b = r * 8;
        let z2 = ws[b + 2];
        let z3 = ws[b + 6];
        let z1 = (z2 + z3) * 4433;
        let t2 = z1 + z3 * -15137;
        let t3 = z1 + z2 * 6270;
        let t0 = (ws[b] + ws[b + 4]) << 13;
        let t1 = (ws[b] - ws[b + 4]) << 13;
        let t10 = t0 + t3;
        let t13 = t0 - t3;
        let t11 = t1 + t2;
        let t12 = t1 - t2;
        t0 = ws[b + 7];
        t1 = ws[b + 5];
        t2 = ws[b + 3];
        t3 = ws[b + 1];
        z1 = t0 + t3;
        z2 = t1 + t2;
        z3 = t0 + t2;
        let z4 = t1 + t3;
        let z5 = (z3 + z4) * 9633;
        t0 = t0 * 2446;
        t1 = t1 * 16819;
        t2 = t2 * 25172;
        t3 = t3 * 12299;
        z1 = z1 * -7373;
        z2 = z2 * -20995;
        z3 = z3 * -16069 + z5;
        z4 = z4 * -3196 + z5;
        t0 = t0 + z1 + z3;
        t1 = t1 + z2 + z4;
        t2 = t2 + z2 + z3;
        t3 = t3 + z1 + z4;
        let q = po + r * stride;
        plane[q] = clamp8(((t10 + t3 + 131072) >> 18) + 128);
        plane[q + 7] = clamp8(((t10 - t3 + 131072) >> 18) + 128);
        plane[q + 1] = clamp8(((t11 + t2 + 131072) >> 18) + 128);
        plane[q + 6] = clamp8(((t11 - t2 + 131072) >> 18) + 128);
        plane[q + 2] = clamp8(((t12 + t1 + 131072) >> 18) + 128);
        plane[q + 5] = clamp8(((t12 - t1 + 131072) >> 18) + 128);
        plane[q + 3] = clamp8(((t13 + t0 + 131072) >> 18) + 128);
        plane[q + 4] = clamp8(((t13 - t0 + 131072) >> 18) + 128);
        r = r + 1;
    };
    0
};

/** A component plane (`stride` wide, `cw` by `ch` real samples) brought to
`w` by `h`: libjpeg's triangle filter for 2:1 horizontally (and 2:1 vertically),
a copy of the nearest sample otherwise. */
def upsample(pl: [byte], stride: long, cw: long, ch: long, hx: long, vy: long, w: long, h: long) -> [byte] {
    let out = zeros(w * h);
    let y = 0;
    while (y < h) {
        let x = 0;
        if (hx == 2 && vy == 1 && cw >= 2) {
            let row = (y / vy) * stride;
            while (x < w) {
                let i = x >> 1;
                let v = 0;
                if (x & 1 == 0) {
                    if (i == 0) { v = pl[row]; } else { v = (3 * pl[row + i] + pl[row + i - 1] + 1) >> 2; };
                } else {
                    if (i == cw - 1) { v = pl[row + i]; } else { v = (3 * pl[row + i] + pl[row + i + 1] + 2) >> 2; };
                };
                out[y * w + x] = v;
                x = x + 1;
            };
        } else if (hx == 2 && vy == 2 && cw >= 2) {
            let r = y >> 1;
            let r2 = if (y & 1 == 0) { r - 1 } else { r + 1 };
            if (r2 < 0) { r2 = 0; };
            if (r2 >= ch) { r2 = ch - 1; };
            let a = r * stride;
            let b = r2 * stride;
            while (x < w) {
                let i = x >> 1;
                let cur = 3 * pl[a + i] + pl[b + i];
                let v = 0;
                if (x & 1 == 0) {
                    if (i == 0) { v = (cur * 4 + 8) >> 4; } else { v = (3 * cur + 3 * pl[a + i - 1] + pl[b + i - 1] + 8) >> 4; };
                } else {
                    if (i == cw - 1) { v = (cur * 4 + 7) >> 4; } else { v = (3 * cur + 3 * pl[a + i + 1] + pl[b + i + 1] + 7) >> 4; };
                };
                out[y * w + x] = v;
                x = x + 1;
            };
        } else {
            let row = (y / vy) * stride;
            while (x < w) {
                out[y * w + x] = pl[row + x / hx];
                x = x + 1;
            };
        };
        y = y + 1;
    };
    out
};

def jpeg_decode(d: [byte]) -> Image? {
    if (d.length < 4 || d[0] != 255 || d[1] != 216) { return none; };
    let qt: [[long]] = [[], [], [], []];
    let dcs: [Ht] = [ht_empty(), ht_empty(), ht_empty(), ht_empty()];
    let acs: [Ht] = [ht_empty(), ht_empty(), ht_empty(), ht_empty()];
    let comps: [Comp] = [];
    let j: Jp = { w: 0, h: 0, prog: false, hmax: 1, vmax: 1, mcux: 0, mcuy: 0, ri: 0, eobrun: 0 };
    let adobe = -1;
    let sof = false;
    let scans = 0;
    let p = 2;
    while (p + 4 <= d.length) {
        if (d[p] != 255) { return none; };
        let m = d[p + 1];
        if (m == 255) { p = p + 1; continue; };
        if (m == 0 || (m >= 208 && m <= 215) || m == 216 || m == 1) { p = p + 2; continue; };
        if (m == 217) { break; };
        let len = be16(d, p + 2);
        if (len < 2 || p + 2 + len > d.length) { return none; };
        let q = p + 4;
        let end = p + 2 + len;
        if (m == 219) {
            while (q < end) {
                let pq = d[q] >> 4;
                let id = d[q] & 15;
                q = q + 1;
                if (id > 3 || pq > 1) { return none; };
                let t = zeros_l(64);
                let k = 0;
                while (k < 64) {
                    if (q + 1 + pq > end) { return none; };
                    if (pq == 1) { t[ZZ[k]] = be16(d, q); } else { t[ZZ[k]] = d[q]; };
                    q = q + 1 + pq;
                    k = k + 1;
                };
                qt[id] = t;
            };
        } else if (m == 196) {
            while (q + 17 <= end) {
                let cl = d[q] >> 4;
                let id = d[q] & 15;
                if (cl > 1 || id > 3) { return none; };
                let counts = d[q + 1:q + 17];
                let n = 0;
                foreach (c in counts) { n = n + c; };
                if (q + 17 + n > end || n > 256) { return none; };
                let t = ht_build(counts, d[q + 17:q + 17 + n]);
                if (cl == 0) { dcs[id] = t; } else { acs[id] = t; };
                q = q + 17 + n;
            };
        } else if (m == 192 || m == 193 || m == 194) {
            if (sof || len < 8) { return none; };
            sof = true;
            j.prog = m == 194;
            if (d[q] != 8) { return none; };
            j.h = be16(d, q + 1);
            j.w = be16(d, q + 3);
            let nc = d[q + 5];
            if (!sized(j.w, j.h) || (nc != 1 && nc != 3) || len < 8 + nc * 3) { return none; };
            let i = 0;
            while (i < nc) {
                let c: Comp = { id: d[q + 6 + i * 3], h: d[q + 7 + i * 3] >> 4, v: d[q + 7 + i * 3] & 15, tq: d[q + 8 + i * 3], bw: 0, bh: 0, coef: [], pred: 0, td: 0, ta: 0, cw: 0, ch: 0 };
                if (c.h < 1 || c.h > 4 || c.v < 1 || c.v > 4 || c.tq > 3) { return none; };
                if (c.h > j.hmax) { j.hmax = c.h; };
                if (c.v > j.vmax) { j.vmax = c.v; };
                comps += c;
                i = i + 1;
            };
            j.mcux = (j.w + 8 * j.hmax - 1) / (8 * j.hmax);
            j.mcuy = (j.h + 8 * j.vmax - 1) / (8 * j.vmax);
            foreach (c in comps) {
                c.bw = j.mcux * c.h;
                c.bh = j.mcuy * c.v;
                c.cw = (j.w * c.h + j.hmax - 1) / j.hmax;
                c.ch = (j.h * c.v + j.vmax - 1) / j.vmax;
                c.coef = zeros_l(c.bw * c.bh * 64);
            };
        } else if (m == 195 || (m >= 197 && m <= 207 && m != 200 && m != 204)) {
            return none;
        } else if (m == 221) {
            if (len < 4) { return none; };
            j.ri = be16(d, q);
        } else if (m == 238) {
            if (len >= 14 && d[q] == 65 && d[q + 1] == 100 && d[q + 2] == 111 && d[q + 3] == 98 && d[q + 4] == 101) { adobe = d[q + 11]; };
        } else if (m == 218) {
            if (!sof) { return none; };
            let ns = d[q];
            if (ns < 1 || ns > comps.length || len < 6 + ns * 2) { return none; };
            let sc: [Comp] = [];
            let i = 0;
            while (i < ns) {
                let cid = d[q + 1 + i * 2];
                let found = false;
                foreach (c in comps) {
                    if (c.id == cid) {
                        c.td = d[q + 2 + i * 2] >> 4;
                        c.ta = d[q + 2 + i * 2] & 15;
                        if (c.td > 3 || c.ta > 3) { return none; };
                        sc += c;
                        found = true;
                    };
                };
                if (!found) { return none; };
                i = i + 1;
            };
            let ss = d[q + 1 + ns * 2];
            let se = d[q + 2 + ns * 2];
            let ah = d[q + 3 + ns * 2] >> 4;
            let al = d[q + 3 + ns * 2] & 15;
            if (!j.prog) { ss = 0; se = 63; ah = 0; al = 0; };
            if (ss > se || se > 63 || (j.prog && ss == 0 && se != 0) || (j.prog && ss > 0 && ns != 1)) { return none; };
            let b: Br = { d: d, p: end, acc: 0, n: 0, hit: false };
            foreach (c in sc) { c.pred = 0; };
            j.eobrun = 0;
            let total = 0;
            let single = ns == 1;
            let c0 = sc[0];
            let nx = if (single) { (c0.cw + 7) / 8 } else { j.mcux };
            let ny = if (single) { (c0.ch + 7) / 8 } else { j.mcuy };
            total = nx * ny;
            let mi = 0;
            while (mi < total) {
                if (j.ri > 0 && mi > 0 && mi % j.ri == 0) { jp_restart(b, sc, j); };
                let mx = mi % nx;
                let my = mi / nx;
                foreach (c in sc) {
                    let dc = dcs[c.td];
                    let ac = acs[c.ta];
                    if ((!j.prog || ss == 0) && !dc.ok && (ah == 0)) { return none; };
                    if ((!j.prog || ss > 0) && !ac.ok) { return none; };
                    if (single) {
                        if (!jp_block(b, c, (my * c.bw + mx) * 64, dc, ac, j, ss, se, ah, al)) { return none; };
                    } else {
                        let by = 0;
                        while (by < c.v) {
                            let bx = 0;
                            while (bx < c.h) {
                                if (!jp_block(b, c, ((my * c.v + by) * c.bw + mx * c.h + bx) * 64, dc, ac, j, ss, se, ah, al)) { return none; };
                                bx = bx + 1;
                            };
                            by = by + 1;
                        };
                    };
                };
                mi = mi + 1;
            };
            scans = scans + 1;
            // on to the marker after the entropy-coded data
            p = b.p;
            while (p + 1 < d.length && !(d[p] == 255 && d[p + 1] != 0 && !(d[p + 1] >= 208 && d[p + 1] <= 215) && d[p + 1] != 255)) { p = p + 1; };
            continue;
        };
        p = end;
    };
    if (!sof || scans == 0) { return none; };
    // dequantise, transform, upsample
    let planes: [[byte]] = [];
    let ws = zeros_l(64);
    let blk = zeros_l(64);
    foreach (c in comps) {
        if (qt[c.tq].length != 64) { return none; };
        let stride = c.bw * 8;
        let pl = zeros(stride * c.bh * 8);
        let by = 0;
        while (by < c.bh) {
            let bx = 0;
            while (bx < c.bw) {
                let o = (by * c.bw + bx) * 64;
                let k = 0;
                while (k < 64) { blk[k] = c.coef[o + k] * qt[c.tq][k]; k = k + 1; };
                idct(blk, 0, ws, pl, by * 8 * stride + bx * 8, stride);
                bx = bx + 1;
            };
            by = by + 1;
        };
        if (j.hmax % c.h != 0 || j.vmax % c.v != 0) { return none; };
        planes += upsample(pl, stride, c.cw, c.ch, j.hmax / c.h, j.vmax / c.v, j.w, j.h);
    };
    let out = new_image(j.w, j.h);
    let rgb = comps.length == 3 && (adobe == 0 || (comps[0].id == 82 && comps[1].id == 71 && comps[2].id == 66));
    let n = j.w * j.h;
    let i = 0;
    while (i < n) {
        let o = i * 4;
        if (comps.length == 1) {
            let y = planes[0][i];
            out.px[o] = y;
            out.px[o + 1] = y;
            out.px[o + 2] = y;
        } else if (rgb) {
            out.px[o] = planes[0][i];
            out.px[o + 1] = planes[1][i];
            out.px[o + 2] = planes[2][i];
        } else {
            let y = planes[0][i];
            let cb = planes[1][i] - 128;
            let cr = planes[2][i] - 128;
            out.px[o] = clamp8(y + ((91881 * cr + 32768) >> 16));
            out.px[o + 1] = clamp8(y + ((-22554 * cb - 46802 * cr + 32768) >> 16));
            out.px[o + 2] = clamp8(y + ((116130 * cb + 32768) >> 16));
        };
        out.px[o + 3] = 255;
        i = i + 1;
    };
    some(out)
};

def zeros_l(n: long) -> [long] {
    let z: [long] = [];
    let i = 0;
    while (i < n) { z += 0; i = i + 1; };
    z
};

// ── front door ──────────────────────────────────────────────────────────

/** The kind of image `d` starts like: "png", "bmp", "gif", "jpeg", "pnm", or
"" when it is none of them. */
def format(d: [byte]) -> str {
    if (d.length >= 8 && d[0] == 137 && d[1] == 80 && d[2] == 78 && d[3] == 71) { return "png"; };
    if (d.length >= 2 && d[0] == 66 && d[1] == 77) { return "bmp"; };
    if (d.length >= 6 && d[0] == 71 && d[1] == 73 && d[2] == 70) { return "gif"; };
    if (d.length >= 3 && d[0] == 255 && d[1] == 216 && d[2] == 255) { return "jpeg"; };
    if (d.length >= 3 && d[0] == 80 && d[1] >= 49 && d[1] <= 54) { return "pnm"; };
    ""
};

/** Decodes an image file held in `d`, whatever its kind (see `format`). */
def decode(d: [byte]) -> Image? {
    let f = format(d);
    if (f == "png") { png_decode(d) }
    else if (f == "bmp") { bmp_decode(d) }
    else if (f == "pnm") { pnm_decode(d) }
    else if (f == "gif") { gif_decode(d) }
    else if (f == "jpeg") { jpeg_decode(d) }
    else { none }
};

/** Reads and decodes the image file at `path`. */
def load(path: str) -> Image? {
    let b = fs.read_bytes(path);
    if (b == none) { none } else { decode(b!) }
};

/** Writes `im` to `path` as PNG, BMP or PPM by the extension (".png", ".bmp",
".ppm"); false for another extension or a failed write. */
def save(path: str, im: Image) -> bool {
    let p = path.lower();
    if (p.ends_with(".png")) { fs.write_bytes(path, encode_png(im)) }
    else if (p.ends_with(".bmp")) { fs.write_bytes(path, encode_bmp(im)) }
    else if (p.ends_with(".ppm")) { fs.write_bytes(path, encode_ppm(im)) }
    else { false }
};

// ── operations ──────────────────────────────────────────────────────────

/** The `w` by `h` window of `im` whose top left is (`x`, `y`); parts outside
`im` are transparent. */
def crop(im: Image, x: long, y: long, w: long, h: long) -> Image {
    let out = new_image(w, h);
    let j = 0;
    while (j < h) {
        let i = 0;
        while (i < w) {
            set_pixel(out, i, j, pixel(im, x + i, y + j));
            i = i + 1;
        };
        j = j + 1;
    };
    out
};

/** A mirror image, left to right. */
def flip_h(im: Image) -> Image {
    let out = new_image(im.w, im.h);
    let y = 0;
    while (y < im.h) {
        let x = 0;
        while (x < im.w) { set_pixel(out, im.w - 1 - x, y, pixel(im, x, y)); x = x + 1; };
        y = y + 1;
    };
    out
};

/** A mirror image, top to bottom. */
def flip_v(im: Image) -> Image {
    let out = new_image(im.w, im.h);
    let y = 0;
    while (y < im.h) {
        let x = 0;
        while (x < im.w) { set_pixel(out, x, im.h - 1 - y, pixel(im, x, y)); x = x + 1; };
        y = y + 1;
    };
    out
};

/** `im` scaled to `w` by `h`: bilinear when `smooth`, nearest pixel otherwise. */
def resize(im: Image, w: long, h: long, smooth: bool = true) -> Image {
    let out = new_image(w, h);
    if (im.w == 0 || im.h == 0 || w <= 0 || h <= 0) { return out; };
    let y = 0;
    while (y < h) {
        let x = 0;
        while (x < w) {
            let o = (y * w + x) * 4;
            if (!smooth) {
                let s = ((y * im.h) / h * im.w + (x * im.w) / w) * 4;
                let c = 0;
                while (c < 4) { out.px[o + c] = im.px[s + c]; c = c + 1; };
            } else {
                // sample centres, 8 fractional bits
                let fx = ((2 * x + 1) * im.w * 256) / (2 * w) - 128;
                let fy = ((2 * y + 1) * im.h * 256) / (2 * h) - 128;
                if (fx < 0) { fx = 0; };
                if (fy < 0) { fy = 0; };
                let x0 = fx >> 8;
                let y0 = fy >> 8;
                let tx = fx & 255;
                let ty = fy & 255;
                let x1 = if (x0 + 1 < im.w) { x0 + 1 } else { im.w - 1 };
                let y1 = if (y0 + 1 < im.h) { y0 + 1 } else { im.h - 1 };
                if (x0 >= im.w) { x0 = im.w - 1; };
                if (y0 >= im.h) { y0 = im.h - 1; };
                let c = 0;
                while (c < 4) {
                    let a = im.px[(y0 * im.w + x0) * 4 + c];
                    let b = im.px[(y0 * im.w + x1) * 4 + c];
                    let d = im.px[(y1 * im.w + x0) * 4 + c];
                    let e = im.px[(y1 * im.w + x1) * 4 + c];
                    let top = a * (256 - tx) + b * tx;
                    let bot = d * (256 - tx) + e * tx;
                    out.px[o + c] = (top * (256 - ty) + bot * ty + 32768) >> 16;
                    c = c + 1;
                };
            };
            x = x + 1;
        };
        y = y + 1;
    };
    out
};

/** A grey copy: each pixel's red, green and blue become its luma (Rec. 601). */
def to_gray(im: Image) -> Image {
    let out = new_image(im.w, im.h);
    let i = 0;
    let n = im.w * im.h * 4;
    while (i < n) {
        let g = (im.px[i] * 299 + im.px[i + 1] * 587 + im.px[i + 2] * 114 + 500) / 1000;
        out.px[i] = g;
        out.px[i + 1] = g;
        out.px[i + 2] = g;
        out.px[i + 3] = im.px[i + 3];
        i = i + 4;
    };
    out
};
