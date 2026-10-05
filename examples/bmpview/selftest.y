// selftest.y -- what the decoder accepts, what it refuses, and whether the
// pixels it hands back are the pixels that went in.
//
//   bmpview --selftest
//
// Malformed input is half of this example: an image viewer is a program that
// opens files other people made, and "it printed something" is not an
// acceptable answer to a file that is not an image.  Every case below goes
// through the SAME bmp.load the viewer uses, so what this table reports is
// what the viewer does -- there is no separate validation path that could
// disagree with the real one.
//
// Four halves:
//
//   accept   four real BMPs: bottom-up 24-bit, top-down 24-bit (negative
//            height), 32-bit BGRA and 8-bit paletted.  Geometry as the header
//            claimed it, and the FNV checksum the summary prints.
//
//   same     tux / topdown / bgra32 hold the SAME picture in three containers,
//            so all three must produce the same checksum.  This is the check
//            that fails if a negative height is treated as a magnitude or if
//            the BGRA quad is read at the wrong offset -- both of which look
//            fine on a symmetric picture.
//
//   refuse   eighteen files that are not decodable, each with a keyword its
//            message has to contain, so the diagnostic is asserted and not
//            merely printed.
//
//   probes   29 known pixels, taken from gen_image.py's pixel function through
//            golden/probes.txt.  The table below was generated from that file,
//            so if the pixel function changes the table has to be regenerated
//            with it; the diff against golden/probes.txt is what catches the
//            drift.  The probes at y > 0 are the interesting ones: they come
//            out wrong from any decoder that ignores the 4-byte row padding,
//            and tux.bmp is 63 pixels wide precisely so that it has some.
//
// NO TRAP ON ANY PATH.  A trap prints to STDOUT (ORCHESTRATOR.md 2.6), which
// would fail this table AND corrupt the EXPECTED diff, so every case here is
// also a test of the guard chain in bmp.load.

import struct;
import bmp;

// The embedded images arrive as arguments from the entry file, so the asset
// is embedded in exactly one place.
let NAMES: [str] = ["tux.bmp", "topdown.bmp", "bgra32.bmp", "blocks8.bmp"];
let EW: [long] = [63, 63, 63, 61];      // the widths the headers claim
let EH: [long] = [47, 47, 47, 45];
let EB: [long] = [24, 24, 32, 8];       // and the bit depths
let CKS: [long; 4] = [0, 0, 0, 0];
let OKS: long = 0;
let FAILS: long = 0;

// ── the truth table ────────────────────────────────────────────────────────
//
// Generated from golden/probes.txt.  `P` exists so the literal below is a call
// and not a `const`: a const wants a compile-time value, and a record literal
// is built at run time.

type Probe = { file: str, x: long, y: long, r: long, g: long, b: long };

def P(f: str, x: long, y: long, r: long, g: long, b: long) -> Probe {
    { file: f, x: x, y: y, r: r, g: g, b: b }
};

let PROBES: [Probe] = [
    P("tux.bmp", 0, 0, 255, 255, 0),
    P("tux.bmp", 1, 1, 4, 5, 80),
    P("tux.bmp", 3, 3, 12, 15, 80),
    P("tux.bmp", 40, 3, 160, 15, 80),
    P("tux.bmp", 62, 46, 255, 255, 0),
    P("tux.bmp", 20, 23, 240, 240, 240),
    P("tux.bmp", 33, 23, 240, 240, 240),
    P("tux.bmp", 34, 23, 255, 60, 60),
    P("tux.bmp", 36, 23, 144, 115, 80),
    P("tux.bmp", 44, 6, 0, 0, 0),
    P("tux.bmp", 48, 12, 255, 255, 255),
    P("tux.bmp", 38, 28, 20, 20, 200),
    P("tux.bmp", 46, 36, 20, 20, 200),
    P("topdown.bmp", 0, 0, 255, 255, 0),
    P("topdown.bmp", 3, 3, 12, 15, 80),
    P("topdown.bmp", 20, 23, 240, 240, 240),
    P("topdown.bmp", 34, 23, 255, 60, 60),
    P("topdown.bmp", 48, 12, 255, 255, 255),
    P("topdown.bmp", 62, 46, 255, 255, 0),
    P("bgra32.bmp", 0, 0, 255, 255, 0),
    P("bgra32.bmp", 3, 3, 12, 15, 80),
    P("bgra32.bmp", 20, 23, 240, 240, 240),
    P("bgra32.bmp", 34, 23, 255, 60, 60),
    P("bgra32.bmp", 48, 12, 255, 255, 255),
    P("bgra32.bmp", 62, 46, 255, 255, 0),
    P("blocks8.bmp", 0, 0, 0, 255, 128),
    P("blocks8.bmp", 8, 8, 153, 102, 56),
    P("blocks8.bmp", 60, 44, 255, 0, 8),
    P("blocks8.bmp", 32, 20, 255, 0, 8)
];

// ── fixtures ───────────────────────────────────────────────────────────────
//
// Every malformed case is the shipped image with one field wrong, which keeps
// the fixtures honest: a hand-built 20-byte file can be rejected for a reason
// that has nothing to do with the field under test.
//
// Arrays are REFERENCES, so `let bad = tux; set32(bad, ...)` would corrupt the
// embedded image itself and every case after it.  A slice copies, which is
// exactly what a fixture needs: `clone` is `src[0:len(src)]`.

def set32(b: [byte], off: long, v: long) {
    let w = struct.u32le(v);
    let i = 0;
    while (i < 4) { b[off + i] = w[i]; i = i + 1; };
};

def set16(b: [byte], off: long, v: long) {
    let w = struct.u16le(v);
    let i = 0;
    while (i < 2) { b[off + i] = w[i]; i = i + 1; };
};

def clone(src: [byte]) -> [byte] {
    src[0:len(src)]
};

def head(src: [byte], n: long) -> [byte] {
    src[0:n]
};

// Channel unpacking, spelled here rather than borrowed from fb: the probe
// table is about the DECODER, so it must not also depend on the renderer.
def chan_r(c: long) -> long { if (c < 0) { return 0; }; (c >> 16) & 255 };
def chan_g(c: long) -> long { if (c < 0) { return 0; }; (c >> 8) & 255 };
def chan_b(c: long) -> long { if (c < 0) { return 0; }; c & 255 };

// ── the assertions ─────────────────────────────────────────────────────────

def expect_accept(label: str, src: [byte], w: long, h: long, bpp: long, slot: long) {
    let im = bmp.load(src);
    if (len(im.err) > 0) {
        print("  FAIL  " + label + " -- refused a valid file: " + im.err);
        FAILS = FAILS + 1;
        return;
    };
    if (im.w != w || im.h != h || im.bpp != bpp) {
        print("  FAIL  " + label + " -- decoded " + tostring(im.w) + "x" + tostring(im.h) +
              " at " + tostring(im.bpp) + " bpp, expected " + tostring(w) + "x" +
              tostring(h) + " at " + tostring(bpp));
        FAILS = FAILS + 1;
        return;
    };
    CKS[slot] = bmp.checksum(im);
    print("  ok    " + label + " -- " + bmp.format(im) + ", " + tostring(im.w) + "x" +
          tostring(im.h) + ", stride " + tostring(im.stride) +
          ", bfOffBits " + tostring(im.dataoff) +
          ", fnv " + tostring(CKS[slot]));
    OKS = OKS + 1;
};

def expect_reject(label: str, kw: str, src: [byte]) {
    let im = bmp.load(src);
    if (len(im.err) == 0) {
        print("  FAIL  " + label + " -- ACCEPTED, but it is not a decodable picture");
        FAILS = FAILS + 1;
    } else if (index_of(im.err, kw) < 0) {
        print("  FAIL  " + label + " -- the message does not mention '" + kw + "': " + im.err);
        FAILS = FAILS + 1;
    } else {
        print("  ok    " + label + " -- " + im.err);
        OKS = OKS + 1;
    }
};

def expect_probe(name: str, p: Probe, im: bmp.Image) {
    let got = bmp.at(im, p.x, p.y);
    let r = chan_r(got);
    let g = chan_g(got);
    let b = chan_b(got);
    let good = (got >= 0 && r == p.r && g == p.g && b == p.b);
    if (good) {
        OKS = OKS + 1;
    } else {
        FAILS = FAILS + 1;
    };
    // The machine-readable line is "probe <file> <x> <y> <r> <g> <b> <ok|FAIL>".
    // golden/probes.txt holds those six fields, so
    //
    //   ./bmpview --selftest | grep '^probe' | cut -d' ' -f2-7 \
    //       | diff - golden/probes.txt
    //
    // is the pixel-correctness check, and it needs nothing but cut and diff.
    print("probe " + name + " " + tostring(p.x) + " " + tostring(p.y) + " " +
          tostring(r) + " " + tostring(g) + " " + tostring(b) + " " +
          if (good) { "ok" } else { "FAIL" })
};

// ── the run ────────────────────────────────────────────────────────────────

// run() takes the four embedded images as an array of arrays.  A nested
// literal would be [[long]] rather than [[byte]] (the element literals are
// longs, and the two types are not interchangeable inside a nesting), so the
// array is grown instead -- `a += bytes(...)` is the only spelling that
// builds a [[byte]].
def run(tux: [byte], top: [byte], b32: [byte], b8: [byte]) -> long {
    let sources: [[byte]] = [];
    sources += tux;
    sources += top;
    sources += b32;
    sources += b8;
    print("bmpview selftest");
    print("");
    print("  what it accepts");
    let k = 0;
    while (k < 4) {
        expect_accept(NAMES[k], sources[k], EW[k], EH[k], EB[k], k);
        k = k + 1;
    };

    print("");
    print("  one picture, three containers");
    if (CKS[0] == CKS[1] && CKS[1] == CKS[2]) {
        print("  ok    bottom-up, top-down and 32-bit all decode to fnv " + tostring(CKS[0]));
        OKS = OKS + 1;
    } else {
        print("  FAIL  they disagree: " + tostring(CKS[0]) + " / " +
              tostring(CKS[1]) + " / " + tostring(CKS[2]));
        FAILS = FAILS + 1;
    };

    let tux = sources[0];
    let b8 = sources[3];

    // A paletted file that declares four palette entries and writes four,
    // while its pixels index up to fifteen.  This one must be ACCEPTED -- the
    // file is structurally sound, and the entries that ARE there are readable
    // -- and the out-of-range indices must be caught one pixel at a time and
    // counted, rather than being resolved out of whatever bytes happen to sit
    // where the palette would have continued (here, the pixel rows).  Built by
    // slicing: b8[0:54] is the headers, b8[54:70] four palette quads, and
    // b8[1078:] the same rows, which `+` concatenates into a new array.
    let shortpal: [byte] = b8[0:54] + b8[54:70] + b8[1078:];
    set32(shortpal, 2, len(shortpal));
    set32(shortpal, 10, 70);
    set32(shortpal, 46, 4);
    let sp = bmp.load(shortpal);
    if (len(sp.err) > 0) {
        print("  FAIL  4-entry palette -- refused a structurally sound file: " + sp.err);
        FAILS = FAILS + 1;
    } else if (sp.palbad == 0) {
        print("  FAIL  4-entry palette -- every index resolved, but 2489 of 2745 pixels point past the fourth entry");
        FAILS = FAILS + 1;
    } else {
        print("  ok    4-entry palette -- accepted, " + tostring(sp.palbad) +
              " of " + tostring(sp.npix) + " pixels indexed outside it and painted black");
        OKS = OKS + 1;
    };

    print("");
    print("  what it refuses");
    expect_reject("empty file (0 bytes)", "too short", []);
    expect_reject("10 bytes", "14 bytes", head(tux, 10));
    let notbm = clone(tux);
    set16(notbm, 0, 0x4b50);                          // "PK", as a zip begins
    expect_reject("not a BMP (starts PK)", "not a BMP", notbm);
    let bigsz = clone(tux);
    set32(bigsz, 2, 4194304);
    expect_reject("bfSize 4 MiB, file 9078 B", "truncated", bigsz);
    let badoff = clone(tux);
    set32(badoff, 10, 16777215);
    expect_reject("bfOffBits = 16 MiB", "bfOffBits", badoff);
    // A fixture that CUTS the file has to bring bfSize with it, or the size
    // cross-check fires first and the case stops testing the field it was
    // built for.  With the size field patched, each of these reaches exactly
    // the guard it is named after.
    let trunc = head(tux, 40);
    set32(trunc, 2, 40);
    expect_reject("DIB header cut short at 40 B", "DIB header", trunc);
    let os2 = clone(tux);
    set32(os2, 14, 12);
    expect_reject("OS/2 core header (12 B)", "OS/2", os2);
    let v3 = clone(tux);
    set32(v3, 14, 56);
    expect_reject("V3 header with channel masks", "not supported", v3);
    let v9 = clone(tux);
    set32(v9, 14, 999);
    expect_reject("DIB header size 999", "DIB header size", v9);
    let zw = clone(tux);
    set32(zw, 18, 0);
    expect_reject("width 0", "width", zw);
    let zh = clone(tux);
    set32(zh, 22, 0);
    expect_reject("height 0", "height", zh);
    // A negative height is LEGAL -- it is the top-down row order -- so what has
    // to be refused is one whose magnitude will not fit the buffer.  The
    // dimension test has to see that magnitude without overflowing.
    let nh = clone(tux);
    set32(nh, 22, -100000);
    expect_reject("height -100000", "ceiling", nh);
    let vwide = clone(tux);
    set32(vwide, 18, 100000);
    expect_reject("width 100000", "ceiling", vwide);
    let b7 = clone(tux);
    set16(b7, 28, 7);
    expect_reject("7 bits per pixel", "bit depth", b7);
    let b16 = clone(tux);
    set16(b16, 28, 16);
    expect_reject("16 bits per pixel", "bit depth", b16);
    let rle = clone(tux);
    set32(rle, 30, 1);
    expect_reject("BI_RLE8", "BI_RLE8", rle);
    let bfl = clone(tux);
    set32(bfl, 30, 3);
    expect_reject("BI_BITFIELDS", "BI_BITFIELDS", bfl);
    let pl = clone(tux);
    set16(pl, 26, 2);
    expect_reject("2 colour planes", "planes", pl);
    let norows = head(tux, 4000);
    set32(norows, 2, 4000);
    expect_reject("pixel rows missing", "rows", norows);
    let nopal = head(b8, 200);
    set32(nopal, 2, 200);
    expect_reject("8-bit, palette missing", "palette", nopal);

    print("");
    print("  pixels decoded (compare these with golden/probes.txt)");
    let j = 0;
    while (j < 4) {
        let im = bmp.load(sources[j]);
        let i = 0;
        while (i < len(PROBES)) {
            let p = PROBES[i];
            if (p.file == NAMES[j]) { expect_probe(NAMES[j], p, im) };
            i = i + 1;
        };
        j = j + 1;
    };

    print("");
    print("  " + tostring(OKS) + " checks passed, " + tostring(FAILS) + " failed");
    FAILS
};

export { run, PROBES };