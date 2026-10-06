// bmp.y -- a Windows BMP decoder: header parse plus one reusable RGB buffer.
//
// WHAT IT IS
// `load(src)` takes the whole file as `[byte]` and either fills a normalised
// 8-8-8 RGB image or returns an Image whose `err` names the problem.  Every
// header field is read through a bounds-checked accessor, so a hostile,
// truncated or simply wrong file produces a diagnostic and never an index
// trap (ORCHESTRATOR.md 2.6: traps print to STDOUT and corrupt the diff).
//
//   let im = bmp.load(bytes(EMBED_TUX));
//   if (len(im.err) > 0) { eputs("bmpview: " + im.err + "\n"); exit(1) };
//   print(bmp.checksum());
//
// THE FORMAT AS IMPLEMENTED
//
//   file header, 14 bytes, little-endian
//     0  2  bfType      'B' 'M', 0x4d42 read as a u16
//     2  4  bfSize      the file's own length; checked against reality
//     6  2  bfReserved1
//     8  2  bfReserved2
//    10  4  bfOffBits   where the pixel rows start
//
//   DIB header, bfOffBits-independent, `dibSize` bytes at offset 14
//     0  4  biSize          40 = BITMAPINFOHEADER, 108 = V4, 124 = V5
//     4  4  biWidth         SIGNED
//     8  4  biHeight        SIGNED -- negative means the rows are stored
//                           top row first (top-down), positive means the
//                           first row in the file is the BOTTOM row
//    12  2  biPlanes        always 1
//    14  2  biBitCount      8 (paletted), 24 (BGR) or 32 (BGRA/BGRX)
//    16  4  biCompression   0 = BI_RGB only; 1/2 are the RLE codecs
//    20  4  biSizeImage     the pixel bytes; advisory, so not trusted
//    24  8  biXPelsPerMeter, biYPelsPerMeter
//    32  4  biClrUsed       palette entries present
//    36  4  biClrImportant
//   (V4 and V5 add channel masks and a colour space after that; both start
//    with the same 40 bytes, which is all this decoder reads.)
//
//   palette, for 8-bit images only: 4 bytes per entry, BGRA, straight after
//   the DIB header.  `bfOffBits` is where the pixel rows really begin, so the
//   palette is skipped by arithmetic, never by scanning.
//
//   pixel rows: `biHeight` rows, each `stride` bytes
//     stride = ((width * bpp + 31) / 32) * 4      <-- the classic bug
//   Every row starts on a 4-byte boundary: 63 pixels at 24 bpp is 189 bytes
//   and the row occupies 192, so three pad bytes per row.  A decoder that
//   forgets this shears every row below the first.  data/tux.bmp is 63 wide
//   precisely so that the shipped image cannot pass a decoder that omits it.
//
// NOT SUPPORTED, each with its own diagnostic rather than a trap:
//   OS/2 BITMAPCOREHEADER (12) and the V2/V3 headers with channel masks
//   (52/56); BI_RLE8 / BI_RLE4 / BI_BITFIELDS / BI_JPEG / BI_PNG;
//   1, 4, 16 and everything above 32 bits per pixel; 2-plane images.
//
// THE BUFFER, AND WHY IT IS FIXED-SIZE
// The heap is an arena and nothing is ever freed (ORCHESTRATOR.md 2.7), so a
// pixel store that grows costs a fresh allocation every time it is resized,
// and an array literal written in the decode loop leaks 72 bytes per pixel
// (measured -- see examples/SUGGESTIONS.md).  So the store is ONE module-level
// fixed array, PIXW*PIXL*3 bytes, and the decode loop only ever writes into
// it by index.  The price is a ceiling: a picture larger than PIXW x PIXL is
// refused with a diagnostic instead of being decoded.  `blank()` wraps the
// array in an Image record; records are passed by reference and arrays are
// references, so handing the Image around copies 100 bytes of header and not
// one byte of pixels.
//
// ONE IMAGE AT A TIME.  `load` returns a fresh header, but the pixels always
// land in the same buffer, so holding two decoded images at once is not
// possible.  A viewer has one; a tool that wanted two would make the buffer a
// parameter.  Nothing here allocates per call except the Image record itself
// (64 bytes, once per load).

import struct;

// The pixel ceiling.  3 MiB of static store: big enough for a 1024x1024
// photograph, small enough that the module is never the reason a run is big.
const PIXW = 1024;
const PIXL = 1024;
const PIXCAP = PIXW * PIXL;          // 1048576 pixels
const RGBCAP = PIXCAP * 3;           // 3145728 bytes

let STORE: [byte; 3145728] = [0; 3145728];

// Offsets inside the DIB header are absolute file offsets (DIB + the field's
// place in the header), so each one reads straight out of the array.
const DIB = 14;                      // where the DIB header starts
const O_SIZE = 14;                   // biSize
const O_W = 18;                      // biWidth, signed
const O_H = 22;                      // biHeight, signed
const O_PLANES = 26;
const O_BPP = 28;
const O_COMP = 30;
const O_NCOL = 46;                   // biClrUsed

// BI_RGB and the compression codes worth naming in a diagnostic.
const C_RGB = 0;
const C_RLE8 = 1;
const C_RLE4 = 2;
const C_BITFIELDS = 3;
const C_JPEG = 4;
const C_PNG = 5;
const C_ALPHABITFIELDS = 6;

type Image = {
    w: long,             // width in pixels
    h: long,             // height in pixels, always positive
    bpp: long,           // bits per pixel, as the header declared it
    stride: long,        // bytes one padded source row occupies
    dataoff: long,       // where the rows start in the file
    dibsz: long,         // DIB header size in bytes
    ncol: long,          // palette entries the header declares
    paloff: long,        // where the palette starts
    palbad: long,        // pixels whose palette index was out of range
    topdown: long,       // 1 when the header's height was negative
    npix: long,          // w * h
    nbytes: long,        // bytes of file handed in
    err: str,            // "" on success, else the diagnostic
    rgb: [byte; 3145728] // npix * 3 bytes, aliasing STORE
};

def blank() -> Image {
    let im: Image = {
        w: 0, h: 0, bpp: 0, stride: 0, dataoff: 0, dibsz: 0, ncol: 0,
        paloff: 0, palbad: 0, topdown: 0, npix: 0, nbytes: 0,
        err: "", rgb: STORE
    };
    im
};

// ── bounds-checked little-endian accessors ─────────────────────────────────
//
// The std's struct.get_u32le and friends do NOT bounds-check: an offset past
// the end trips the runtime's index trap.  These wrap them so the decoder
// asks about an offset rather than trusting one, and answer -1 for "not
// there" -- which no unsigned field can legitimately be, and which the header
// parse then turns into a message naming the field.

def u16(src: [byte], off: long) -> long {
    if (off < 0 || off + 2 > len(src)) { return -1; };
    struct.get_u16le(src, off)
};

def u32(src: [byte], off: long) -> long {
    if (off < 0 || off + 4 > len(src)) { return -1; };
    struct.get_u32le(src, off)
};

def i32(src: [byte], off: long) -> long {
    if (off < 0 || off + 4 > len(src)) { return -1; };
    struct.get_i32le(src, off)
};

// hexnibble(v) -- one hex digit, lowercase.  10..15 are 97..102, so the +87
// offset from '0' only holds for digits: 48 + v up to 9, 87 + v above.
def hexnibble(v: long) -> str {
    if (v < 10) { return chr(48 + v); };
    chr(87 + v)
};

// hex2(v) -- the two hex digits of a byte, for a diagnostic.
def hex2(v: long) -> str {
    let b = v % 256;
    hexnibble(b / 16) + hexnibble(b - (b / 16) * 16)
};

// hex4(v) -- four hex digits, zero-padded, for a magic or a size field.
def hex4(v: long) -> str {
    let n = v % 65536;
    hex2(n / 256) + hex2(n - (n / 256) * 256)
};

// comp_name(c) -- the BI_* spelling of a compression code, or its number.
def comp_name(c: long) -> str {
    if (c == C_RGB) { return "BI_RGB"; };
    if (c == C_RLE8) { return "BI_RLE8"; };
    if (c == C_RLE4) { return "BI_RLE4"; };
    if (c == C_BITFIELDS) { return "BI_BITFIELDS"; };
    if (c == C_JPEG) { return "BI_JPEG"; };
    if (c == C_PNG) { return "BI_PNG"; };
    if (c == C_ALPHABITFIELDS) { return "BI_ALPHABITFIELDS"; };
    "code " + tostring(c)
};

def dib_name(sz: long) -> str {
    if (sz == 12) { return "OS/2 BITMAPCOREHEADER"; };
    if (sz == 40) { return "BITMAPINFOHEADER"; };
    if (sz == 52) { return "BITMAPV2INFOHEADER"; };
    if (sz == 56) { return "BITMAPV3INFOHEADER"; };
    if (sz == 64) { return "OS/2 BITMAPCOREHEADER2"; };
    if (sz == 108) { return "BITMAPV4HEADER"; };
    if (sz == 124) { return "BITMAPV5HEADER"; };
    "an unrecognised header of " + tostring(sz) + " bytes"
};

// ── the decode ─────────────────────────────────────────────────────────────

def load(src: [byte]) -> Image {
    let im = blank();
    let n = len(src);
    im.nbytes = n;

    // 1. the 14-byte file header.  Each step is an early return with the
    //    message that says what is wrong, so there is no "ok" flag to keep
    //    in step with the rest of the parse.
    if (n < 2) {
        im.err = "the file is " + tostring(n) + " bytes, too short to hold a BMP signature";
        return im;
    };
    let magic = u16(src, 0);
    if (magic != 0x4d42) {
        im.err = "not a BMP: the file starts " + hex4(magic) +
                 ", not 4d42 ('BM')";
        return im;
    };
    if (n < DIB) {
        im.err = "truncated: the BMP file header is 14 bytes but the file is " + tostring(n);
        return im;
    };

    // 2. the file's own length, which is the first of two cross-checks.  A
    //    file cut short in transit, or a JPEG renamed to .bmp, both land
    //    here rather than three fields later.
    let fsize = u32(src, 2);
    if (fsize < 0) {
        im.err = "truncated: the file header's size field is not in the file";
        return im;
    };
    if (fsize > n) {
        im.err = "the header says the file is " + tostring(fsize) +
                 " bytes but only " + tostring(n) + " are here; it is truncated";
        return im;
    };

    // 3. the DIB header's declared size, which fixes where the palette and
    //    the pixel rows can possibly be.
    let dibsz = u32(src, DIB);
    if (dibsz < 0) {
        im.err = "truncated: the file is " + tostring(n) +
                 " bytes, so the DIB header does not even start";
        return im;
    };
    im.dibsz = dibsz;
    if (dibsz == 40 || dibsz == 108 || dibsz == 124) {
        // read on
    } else if (dibsz == 12) {
        im.err = "OS/2 BITMAPCOREHEADER (12 bytes) is not supported; this viewer reads BITMAPINFOHEADER and later";
        return im;
    } else if (dibsz == 52 || dibsz == 56 || dibsz == 64) {
        im.err = dib_name(dibsz) + " is not supported; this viewer reads BITMAPINFOHEADER, V4 and V5";
        return im;
    } else {
        im.err = "unsupported DIB header size " + tostring(dibsz) +
                 " bytes (this viewer reads 40, 108 and 124)";
        return im;
    };
    let have = n - DIB;
    if (dibsz > have) {
        im.err = "truncated: the DIB header declares " + tostring(dibsz) +
                 " bytes but only " + tostring(have) + " are present";
        return im;
    };

    // 4. the geometry.  Width and height are SIGNED: a negative height is not
    //    an error, it is the top-down row order, and it is read as such below.
    //    Once the DIB header's declared size is known to be inside the file,
    //    the first 40 bytes of it are there too, so both fields are readable
    //    -- there is no "field absent" case left to handle separately, and a
    //    zero width can be rejected as the zero it is instead of being taken
    //    for a missing field.
    let w = i32(src, O_W);
    let h = i32(src, O_H);
    if (w <= 0) {
        im.err = "the width must be positive; the header says " + tostring(w);
        return im;
    };
    if (h == 0) {
        im.err = "the height must not be zero";
        return im;
    };
    let bpp = u16(src, O_BPP);
    let comp = u32(src, O_COMP);
    let planes = u16(src, O_PLANES);
    if (bpp == 8 || bpp == 24 || bpp == 32) {
        // read on
    } else if (bpp == 16) {
        im.err = "unsupported bit depth 16; this viewer reads 8 (paletted), 24 and 32 bits per pixel";
        return im;
    } else if (bpp == 4 || bpp == 1) {
        im.err = "unsupported bit depth " + tostring(bpp) +
                 "; this viewer reads 8 (paletted), 24 and 32 bits per pixel";
        return im;
    } else {
        im.err = "unsupported bit depth " + tostring(bpp) +
                 "; this viewer reads 8 (paletted), 24 and 32 bits per pixel";
        return im;
    };
    if (comp != C_RGB) {
        im.err = "compressed BMP: " + comp_name(comp) +
                 " is not supported; this viewer reads uncompressed BI_RGB";
        return im;
    };
    if (planes != 1) {
        im.err = "the header declares " + tostring(planes) +
                 " colour planes; a BMP has exactly one";
        return im;
    };

    // A negative height means the rows are stored top row first.
    let topdown = 0;
    let hh = h;
    if (h < 0) {
        topdown = 1;
        hh = 0 - h;
    };
    // The ceiling is checked in two steps so neither the product nor a
    // multiplication of two hostile 32-bit header fields can overflow.
    if (w > PIXW || hh > PIXL) {
        im.err = "the picture is " + tostring(w) + "x" + tostring(hh) +
                 " pixels, which is past this viewer's " + tostring(PIXW) +
                 "x" + tostring(PIXL) + " ceiling";
        return im;
    };
    if (w > PIXCAP / hh) {
        im.err = "the picture is " + tostring(w) + "x" + tostring(hh) +
                 " pixels, which is more than the " + tostring(PIXCAP) +
                 " the buffer holds";
        return im;
    };

    im.w = w;
    im.h = hh;
    im.bpp = bpp;
    im.topdown = topdown;
    im.npix = w * hh;
    im.stride = ((w * bpp + 31) / 32) * 4;      // the 4-byte row padding
    im.paloff = DIB + dibsz;
    im.ncol = u32(src, O_NCOL);
    if (im.ncol < 0) { im.ncol = 0; };

    // 5. bfOffBits, and for 8-bit images how far the palette reaches.  A zero
    //    bfOffBits is legal in a header that predates the field, so it is
    //    computed rather than believed.
    //
    //    The palette bound is not biClrUsed on its own.  Everything between
    //    the end of the DIB header and the first pixel row IS palette, by the
    //    format, so a file that declares four entries but writes 256 is legal
    //    and readable -- and a file that declares 256 but writes 4 must have
    //    its indices past the fourth entry caught rather than resolved out of
    //    whatever happens to sit there.
    let off = u32(src, 10);
    let palbytes = 0;
    let palcount = 0;
    if (bpp == 8) {
        palcount = im.ncol;
        if (palcount <= 0 || palcount > 256) { palcount = 256; };
        palbytes = palcount * 4;
    };
    if (off == 0) {
        off = im.paloff + palbytes;
    };
    let palend = im.paloff + palbytes;
    if (off > palend) { palend = off; };
    if (palend > n) { palend = n; };

    // 6. the palette must actually be in the file
    if (bpp == 8 && im.paloff + palbytes > n) {
        im.err = "truncated: " + tostring(palcount) + " palette entries need " +
                 tostring(palbytes) + " bytes at offset " + tostring(im.paloff) +
                 ", but the file is only " + tostring(n) + " bytes";
        return im;
    };

    // 7. bfOffBits has to point inside the file, and the rows have to be there
    if (off < DIB || off > n) {
        im.err = "bfOffBits is " + tostring(off) +
                 ", which is outside the " + tostring(n) + "-byte file";
        return im;
    };
    let need = hh * im.stride;
    if (off + need > n) {
        im.err = "truncated: " + tostring(hh) + " rows of " + tostring(im.stride) +
                 " bytes need " + tostring(need) + " bytes from offset " + tostring(off) +
                 ", but only " + tostring(n - off) + " are present";
        return im;
    };
    im.dataoff = off;

    // 8. the pixels.  After step 7 every offset this loop forms is inside the
    //    file, so no per-byte test is needed on the direct paths: the loop is
    //    63*47*3 stores for the shipped image and allocates nothing.  The one
    //    exception is the palette lookup, where the INDEX comes from the file
    //    and so cannot be assumed in range -- that is a guard per pixel rather
    //    than a validation pass, because a corrupt index should cost one black
    //    pixel and a counter, not the whole picture.
    let bytespp = bpp / 8;
    let fy = 0;
    while (fy < hh) {
        let sy = fy;
        if (topdown == 0) { sy = hh - 1 - fy; };    // bottom-up is the default
        let ro = off + fy * im.stride;
        let dp = sy * w * 3;
        let x = 0;
        while (x < w) {
            let so = ro + x * bytespp;
            let r = 0;
            let g = 0;
            let b = 0;
            if (bpp == 8) {
                let e = src[so];
                let po = im.paloff + e * 4;
                if (po + 3 < palend) {
                    b = src[po];
                    g = src[po + 1];
                    r = src[po + 2];
                } else {
                    im.palbad = im.palbad + 1;
                };
            } else {
                b = src[so];
                g = src[so + 1];
                r = src[so + 2];                    // BMP stores BGR
            };
            im.rgb[dp] = r;
            im.rgb[dp + 1] = g;
            im.rgb[dp + 2] = b;
            dp = dp + 3;
            x = x + 1;
        };
        fy = fy + 1;
    };
    im
};

// ── reading the decoded image ──────────────────────────────────────────────

def at(im: Image, x: long, y: long) -> long {
    // One pixel as 0xRRGGBB, or -1 out of range.  tui.rgb takes channels, so
    // callers that want a colour use r_of/g_of/b_of or pass this straight to
    // tui.put as a truecolour SGR pair.
    if (x < 0 || y < 0 || x >= im.w || y >= im.h) { return -1; };
    let i = (y * im.w + x) * 3;
    (im.rgb[i] << 16) | (im.rgb[i + 1] << 8) | im.rgb[i + 2]
};

def luma(c: long) -> long {
    // Integer luma, 0..255.  No float anywhere (ORCHESTRATOR.md 2.4a): the
    // weights are the usual 77/150/29 but scaled so the sum is 256, and the
    // result is clamped into a byte.
    if (c < 0) { return 0; };
    let v = (77 * ((c >> 16) & 255) + 150 * ((c >> 8) & 255) + 29 * (c & 255)) / 256;
    if (v < 0) { return 0; };
    if (v > 255) { return 255; };
    v
};

def checksum(im: Image) -> long {
    // FNV-1a 64 over every decoded byte.  Two loads of the same file must
    // agree, and a stride or row-order mistake changes it, which is what the
    // summary line and the golden files record.  `long` multiply wraps, so the
    // prime's high bits fold in as intended.
    let h: long = -3750763034362895579;      // 14695981039346656037
    let n = im.npix * 3;
    let i = 0;
    while (i < n) {
        h = (h ^ im.rgb[i]) * 1099511628211;
        i = i + 1;
    };
    h
};

// ── describing it ──────────────────────────────────────────────────────────

def format(im: Image) -> str {
    // "BMP 24-bit BI_RGB bottom-up", the one-line form the summary prints.
    let s = "BMP " + tostring(im.bpp) + "-bit " + comp_name(C_RGB);
    if (im.bpp == 8) {
        s += " paletted";
    };
    s += if (im.topdown == 1) { " top-down" } else { " bottom-up" }
};

export { Image, PIXW, PIXL, PIXCAP, RGBCAP, C_RGB, C_RLE8, C_RLE4, C_BITFIELDS,
         blank, load, u16, u32, i32, at, luma, checksum, format, hex2, hex4,
         comp_name, dib_name };