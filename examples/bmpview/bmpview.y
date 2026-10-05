// bmpview.y -- a BMP image viewer for the terminal.
//
//   build:  ../../refs/ycc.ref bmpview.y -o bmpview
//   run:    ./bmpview                            interactive, until q
//          ./bmpview --frames 2 --no-tty          the deterministic run
//          ./bmpview --file photo.bmp            any BMP on disk
//          ./bmpview --selftest                  the decoder's own tests
//
// WHAT IT IS
// The image is decoded into one reusable RGB buffer (bmp.y) and then blitted
// into the toolkit's terminal framebuffer three ways:
//
//   --mode half    truecolour HALF BLOCKS.  One cell carries two image rows:
//                  the upper half block U+2580 with the upper row as the
//                  FOREGROUND and the lower row as the BACKGROUND paints both
//                  at once, in 24-bit colour, from a single glyph.  This is
//                  the mode to use, because a terminal cell is about twice as
//                  tall as it is wide, so two image rows to a cell is what
//                  makes a pixel come out square instead of stretched.
//   --mode colour  one image pixel per cell, truecolour, as the background of
//                  a space.  Twice as much picture per cell row, at the cost
//                  of a 2:1 vertical stretch -- useful for seeing what is in
//                  a corner, wrong for looking at a picture.
//   --mode mono    the toolkit's 10-level ASCII ramp keyed on integer luma, in
//                  the terminal's own colours.  For a terminal without
//                  truecolour, and for piping into a file.
//
// KEYS, interactive: arrows or hjkl scroll, +/- zoom, f fit, 1 native, g
// cycles the mode, q or Escape quits.  Every exit goes through
// term.restore_all_exit(), and the watchdog is armed, so a crash or a kill -9
// still puts the terminal back (ORCHESTRATOR.md 2.3).
//
// THE ASSET IS EMBEDDED.  `embed` turns data/tux.bmp into a `const` string at
// compile time, so the example needs nothing beside it and always opens the
// same picture.  gen_image.py wrote that file: no download, no randomness, and
// the same bytes on every machine.
//
// NO PER-FRAME ALLOCATION.  The heap is an arena and nothing is ever freed
// (ORCHESTRATOR.md 2.7), so the frame loop must not contain a literal: an
// array literal costs 72 bytes and a record literal 64 every time the
// expression runs (both measured), which a per-pixel loop would leak by the
// megapixel.  So the surface, the pixel buffer and the text line buffer are all
// module-level; the status line writes digits straight into the surface
// instead of building a string; and the view transform is integer arithmetic
// on two longs.  `--time` prints the heap delta across the frames it drew, so
// the claim is measured rather than asserted.
//
// NO FLOAT AND NO MATH (ORCHESTRATOR.md 2.4).  A view is a rational scale, not
// a scale factor, and a pixel is three bytes, not a vector.  Downscaling
// averages in integers; luma is (77r + 150g + 29b) / 256.

import fb;
import term;
import time;
import args;
import fs;
import bmp;
import selftest;

// The shipped picture, and the three others the self-test decodes.  `embed` is
// a statement on its own line, terminated with ';', and its path resolves at
// compile time relative to THIS file.
embed IMG_TUX from "data/tux.bmp";
embed IMG_TOP from "data/topdown.bmp";
embed IMG_32 from "data/bgra32.bmp";
embed IMG_8 from "data/blocks8.bmp";

// ───────────────────────────────────────────────────────────── the CLI ───

let OPTS: [args.Opt] = [
    { long: "frames", short: "n", kind: args.NUM,
      help: "draw exactly N frames, then exit 0 (default 0: run until q)" },
    { long: "file", short: "F", kind: args.STR,
      help: "open this BMP instead of the embedded one" },
    { long: "mode", short: "m", kind: args.STR,
      help: "half | colour | mono   (half: truecolour half blocks, 2 image rows per cell)" },
    { long: "zoom", short: "z", kind: args.NUM,
      help: "magnification 1..16; 0 fits the window (default 0)" },
    { long: "no-tty", short: "", kind: args.BOOL,
      help: "headless: render into a fixed grid, print the summary and the picture as text" },
    { long: "size", short: "", kind: args.STR,
      help: "WxH cells for --no-tty (default 80x24)" },
    { long: "selftest", short: "", kind: args.BOOL,
      help: "the decoder's own tests: 5 files accepted, 20 refused, 29 pixels checked" },
    { long: "time", short: "", kind: args.BOOL,
      help: "report decode time and the heap delta across the frames, on stderr" },
    { long: "quiet", short: "q", kind: args.BOOL,
      help: "suppress the text dump; print only the summary" }
];

// ────────────────────────────────────────────────────────────── the modes ───

const M_HALF = 0;
const M_COLOUR = 1;
const M_MONO = 2;

let MODES: [str] = ["half", "colour", "mono"];
let MODE: long = M_HALF;

const UPPER_HALF = 9600;              // U+2580, 'upper half block'
let BG: long = 0x000000;             // the surface background: black
let LETTERBOX_C: long = 0x001018;     // near-black slate: outside the picture
let HUD_FG: long = 0x00b4b4;          // the status line's main colour
let HUD_DIM: long = 0x006464;          // and its labels
let FRAME_FG: long = 0x002020;         // the rule above the status line

// Key bytes.  Y has no `'q'` character literal -- the single-quote form is
// `c'a'`, and a bare apostrophe in a file can turn a diagnostic into a
// different one (examples/BUGS.md) -- so the codes are written down here
// once, with their meanings, and used by number.
const K_TAB = 9;
const K_CR = 13;
const K_ETX = 3;                      // ^C, which reaches us as a byte in raw mode
const K_PLUS = 43;
const K_MINUS = 45;
const K_0 = 48;
const K_1 = 49;
const K_3 = 51;
const K_F = 102;
const K_G = 103;
const K_H = 104;
const K_J = 106;
const K_K = 107;
const K_L = 108;
const K_Q = 113;

// ─────────────────────────────────────────────────────── the view state ───
//
// A view is (VX0, VY0) plus a rational scale NUM/DEN, where NUM/DEN is how
// many source pixels one IMAGE ROW (or column) covers.  `rpc` is how many
// image rows a cell row consumes: 2 in half mode, 1 otherwise.
//
//   fit        NUM/DEN = cols*1000/w and rows*rpc*1000/h, the smaller, so the
//              whole picture lands in the window
//   native     NUM/DEN = 1/1
//   zoom z     NUM/DEN = 1/z, i.e. magnification, which is a floor division
//              i/z -- so a source pixel covers exactly z image rows
//
// Cell i on an axis maps to the source half-open range
//   [ origin + i*rpc*NUM/DEN , origin + (i+1)*rpc*NUM/DEN )
// computed from the same two integers on both ends, so the ranges tile
// exactly: no gap, no drift, no float.  A span that collapses to 0 under
// magnification is clamped to 1, which is the "replicate the pixel" rule.

let IM: bmp.Image = bmp.blank();
let NAME: str = "tux.bmp";
let NUM: long = 1000;
let DEN: long = 1000;
let VX0: long = 0;
let VY0: long = 0;
let ZOOM: long = 0;                   // 0 = fit

let FRAMES: long = 0;
let SHOWTIME: long = 0;
let QUIET: long = 0;
let NOTTY: long = 0;
let DECODE_US: long = 0;
let ANSI_CKS: long = 0;
let ANSI_BYTES: long = 0;
let CUR_ROWS: long = 24;              // the window the interactive path is in
let CUR_COLS: long = 80;

// One cell row of image rows.  Half mode gets two, because the whole point of
// the mode is that a cell is twice as tall as it is wide.
def rpc() -> long {
    if (MODE == M_HALF) { return 2; };
    1
};

def view_x(i: long) -> long {
    VX0 + (i * NUM) / DEN
};

def span_x(i: long) -> long {
    let a = (i * NUM) / DEN;
    let b = ((i + 1) * NUM) / DEN;
    let s = b - a;
    if (s < 1) { return 1; };
    s
};

def view_y(i: long) -> long {
    let n = rpc();
    VY0 + (i * n * NUM) / DEN
};

def span_y(i: long) -> long {
    let n = rpc();
    let a = (i * n * NUM) / DEN;
    let b = ((i + 1) * n * NUM) / DEN;
    let s = b - a;
    if (s < 1) { return 1; };
    s
};

// clamp_origin() -- keep the picture from being scrolled off its own edge.
// There is no `break` in Y (ORCHESTRATOR.md 2.9), so each bound is written out
// as a guard rather than as a loop that stops when it is satisfied.
def clamp_origin(rows: long, cols: long) {
    let xmax = IM.w - view_x(cols);
    let ymax = IM.h - view_y(rows);
    if (xmax < 0) { xmax = 0; };
    if (ymax < 0) { ymax = 0; };
    if (VX0 > xmax) { VX0 = xmax; };
    if (VY0 > ymax) { VY0 = ymax; };
    if (VX0 < 0) { VX0 = 0; };
    if (VY0 < 0) { VY0 = 0; };
};

// set_view() -- turn the zoom setting into NUM/DEN for a window of this shape,
// then clamp.  Called at start-up, on a zoom change and on a mode change (a
// mode change moves the cell-to-image-row ratio, so the scale has to be
// recomputed even at a fixed zoom).
def set_view(rows: long, cols: long) {
    let n = rpc();
    if (ZOOM > 0) {
        NUM = 1;
        DEN = ZOOM;
    } else {
        let f = 1000;
        if (IM.w > 0 && IM.h > 0) {
            let a = cols * 1000 / IM.w;
            let b = rows * n * 1000 / IM.h;
            if (a > 1000) { a = 1000; };        // fit never magnifies
            if (b > 1000) { b = 1000; };
            if (b < a) { a = b; };
            if (a < 1000) { a = 1000; };        // and never goes under native
            f = a;
        };
        NUM = f;
        DEN = 1000;
    };
    clamp_origin(rows, cols)
};

// ──────────────────────────────────────────────────────── the sampling ───

// sample(x0, xs, y0, ys) -> 0xRRGGBB -- the average of the xs by ys block of
// source pixels at (x0, y0), clamped to the picture.  A span of 1 (the native
// and magnified cases) is one read per channel; a span over 1 is the box
// filter that makes downscaling legible instead of aliased.  Off the picture it
// returns the letterbox colour, which is how the edge of the picture is
// marked rather than guessed at.
def sample(x0: long, xs: long, y0: long, ys: long) -> long {
    let x = x0;
    let w = xs;
    let y = y0;
    let h = ys;
    if (w < 1) { w = 1; };
    if (h < 1) { h = 1; };
    if (x < 0) {
        w = w + x;
        x = 0;
    };
    if (y < 0) {
        h = h + y;
        y = 0;
    };
    if (x >= IM.w || y >= IM.h || w < 1 || h < 1) {
        return LETTERBOX_C;
    };
    if (x + w > IM.w) { w = IM.w - x; };
    if (y + h > IM.h) { h = IM.h - y; };
    let sr = 0;
    let sg = 0;
    let sb = 0;
    let j = 0;
    while (j < h) {
        let base = ((y + j) * IM.w + x) * 3;
        let i = 0;
        while (i < w) {
            // The buffer is r, g, b per pixel -- the same order bmp.at reads,
            // and the reverse of the BGR a BMP stores.  Getting these three
            // lines out of order renders every picture with red and blue
            // swapped, which is easy to miss on a grey gradient and obvious
            // on the first coloured shape.
            sr = sr + IM.rgb[base];
            sg = sg + IM.rgb[base + 1];
            sb = sb + IM.rgb[base + 2];
            base = base + 3;
            i = i + 1;
        };
        j = j + 1;
    };
    let k = w * h;
    (fb.clamp255(sr / k) << 16) | (fb.clamp255(sg / k) << 8) | fb.clamp255(sb / k)
};

// ────────────────────────────────────────────── the allocation-free HUD ───
//
// No tostring() in here.  A status line that built a string once a frame would
// allocate on the frame loop, and the whole claim of this example is that it
// does not.  So the digits go straight into the surface, one cell each, out of
// a module-level scratch array -- a local `[long; 12]` literal would be 72
// bytes per evaluation, per frame (ORCHESTRATOR.md 2.7).
let DIG: [long; 12] = [48; 12];

def sline(s: fb.Surface, row: long, col: long, v: long) -> long {
    let d = DIG;
    let q = v;
    if (q < 0) { q = 0; };
    let n = 0;
    while (q > 0 && n < 12) {
        d[11 - n] = 48 + q % 10;
        q = q / 10;
        n = n + 1;
    };
    let at = col;
    let i = 12 - n;
    while (i < 12) {
        fb.put(s, row, at, d[i], HUD_FG, BG);
        at = at + 1;
        i = i + 1;
    };
    at
};

// label() -- a fixed string at a cell, then the cursor it left behind.  fb.text
// decodes UTF-8 out of the caller's own bytes, so this allocates nothing.
def label(s: fb.Surface, row: long, col: long, t: str, fg: long) -> long {
    fb.text(s, row, col, t, fg, BG);
    col + len(t)
};

def hud(s: fb.Surface) -> void {
    let row = s.rows - 1;
    if (row < 0) { return; };
    fb.hline(s, row, 0, s.cols, 9472, FRAME_FG, BG);
    let c = label(s, row, 1, NAME, HUD_FG);
    c = label(s, row, c, "  ", HUD_FG);
    c = sline(s, row, c, IM.w);
    c = label(s, row, c, "x", HUD_FG);
    c = sline(s, row, c, IM.h);
    c = label(s, row, c, "  ", HUD_FG);
    c = label(s, row, c, MODES[MODE], HUD_FG);
    c = label(s, row, c, "  zoom ", HUD_DIM);
    if (ZOOM > 0) {
        c = sline(s, row, c, ZOOM);
    } else {
        c = label(s, row, c, "fit", HUD_FG);
    };
    c = label(s, row, c, "  at ", HUD_DIM);
    c = sline(s, row, c, VX0);
    c = label(s, row, c, ",", HUD_FG);
    c = sline(s, row, c, VY0);
    label(s, row, c, "  arrows/hjkl  +/-  f  1  g  q", HUD_DIM);
};

// ────────────────────────────────────────────────────────── the renderer ───

// img_rows(s) -- the cell rows the picture gets, leaving the last row for the
// status line.  A one-row surface is all status.
def img_rows(s: fb.Surface) -> long {
    let n = s.rows - 1;
    if (n < 1) { return 1; };
    n
};

// draw(s) -- the whole picture, once.  Nothing in here allocates: every
// argument is a long, every array is module-level, and the two MODE tests are
// outside the per-cell loop.
def draw(s: fb.Surface) -> long {
    fb.fill(s, fb.space, fb.DEFAULT, BG);
    let rows = img_rows(s);
    let r = 0;
    while (r < rows) {
        let c = 0;
        if (MODE == M_HALF) {
            // Two image rows to a cell.  The upper half block's foreground is
            // the upper row and its background is the lower row, so one put()
            // with two colours is the whole half-block trick.
            let rs = view_y(r);
            let re = view_y(r + 1);
            let half = (re - rs) / 2;
            if (half < 1) { half = 1; };
            while (c < s.cols) {
                let x0 = view_x(c);
                let top = sample(x0, span_x(c), rs, half);
                let bot = top;
                if (re - rs - half >= 1) {
                    bot = sample(x0, span_x(c), rs + half, re - rs - half);
                };
                fb.put(s, r, c, UPPER_HALF, top, bot);
                c = c + 1;
            };
        } else {
            let y0 = view_y(r);
            let ys = span_y(r);
            while (c < s.cols) {
                let x0 = view_x(c);
                let col = sample(x0, span_x(c), y0, ys);
                if (MODE == M_COLOUR) {
                    fb.put(s, r, c, fb.space, fb.DEFAULT, col);
                } else {
                    fb.put(s, r, c, fb.shade_ascii(bmp.luma(col), 255), HUD_FG, BG);
                };
                c = c + 1;
            };
        };
        r = r + 1;
    };
    hud(s);
    1
};

// ─────────────────────────────────────────────── the headless text dump ───
//
// The same view transform and the same sample(), but characters instead of
// cells: one character per cell, luminance through the toolkit's ASCII ramp.
// It is what lands in EXPECTED and in golden/, and it reads the decoded pixels
// directly rather than the surface, so diffing it diffs the decode.
//
// The line leaves through a fixed [byte; N] and one write(2).  Building it as a
// `str` would allocate on the way, and `str + byte` segfaults in this compiler
// (examples/BUGS.md) -- so a byte buffer is not just tidier, it is the
// workaround.
let TBUF: [byte; 300] = [0; 300];

def dump_text(rows: long, cols: long) -> void {
    let r = 0;
    while (r < rows) {
        let y0 = view_y(r);
        let ys = span_y(r);
        let n = 0;
        let c = 0;
        while (c < cols && n < 250) {
            let col = sample(view_x(c), span_x(c), y0, ys);
            TBUF[n] = fb.shade_ascii(bmp.luma(col), 255);
            n = n + 1;
            c = c + 1;
        };
        while (n < cols && n < 250) {
            TBUF[n] = 32;
            n = n + 1;
        };
        TBUF[n] = 10;
        syscall(1, 1, &TBUF[0], n + 1);
        r = r + 1;
    }
};

// ──────────────────────────────────────────────────────────── the summary ───

def summary(frames: long) -> void {
    print("");
    print("image       " + NAME);
    print("format      " + bmp.format(IM));
    print("size        " + tostring(IM.w) + " x " + tostring(IM.h) + " pixels, " +
          tostring(IM.npix) + " in all");
    print("header      DIB " + tostring(IM.dibsz) + " bytes, bfOffBits " +
          tostring(IM.dataoff) + ", " + tostring(IM.bpp) + " bpp, row stride " +
          tostring(IM.stride) + " bytes (" +
          tostring(IM.stride - IM.w * (IM.bpp / 8)) + " of padding)");
    if (IM.bpp == 8) {
        print("palette     " + tostring(IM.ncol) + " entries at offset " +
              tostring(IM.paloff) + ", " + tostring(IM.palbad) +
              " pixels indexed outside it");
    };
    print("file        " + tostring(IM.nbytes) + " bytes read");
    print("checksum    fnv1a64 " + tostring(bmp.checksum(IM)) + " over the decoded RGB");
    print("mode        " + MODES[MODE] + ", scale " + tostring(NUM) + "/" +
          tostring(DEN) + ", origin " + tostring(VX0) + "," + tostring(VY0));
    print("frames      " + tostring(frames) + " drawn, " + tostring(ANSI_BYTES) +
          " bytes of ANSI in all, fnv1a64 " + tostring(ANSI_CKS) +
          " over the captured stream");
};

// ─────────────────────────────────────────────────────────── opening ───

// or_exit() -- fs.read_bytes answers none for a missing file, a directory and
// an unreadable one alike, so all three end up in one message.
def or_exit(path: str) -> [byte] {
    let got = fs.read_bytes(path);
    if (got == none) {
        eputs("bmpview: cannot read " + path + ": no such file, or it is a directory\n");
        exit(1);
    };
    got!
};

// open_bytes() -- decode into the one buffer; diagnose and exit 1 on refusal.
def open_bytes(src: [byte]) -> long {
    let t0 = time.now_us();
    let im = bmp.load(src);
    DECODE_US = time.now_us() - t0;
    IM = im;
    if (len(im.err) > 0) {
        eputs("bmpview: " + NAME + ": " + im.err + "\n");
        exit(1);
    };
    1
};

// scroll() -- one cell's worth of source pixels, which is two image rows in
// half mode: a step you can see, not a jump.
def scroll(dx: long, dy: long) -> void {
    let sx = span_x(1);
    let sy = span_y(1);
    let a = sx;
    let b = sy;
    if (a < 1) { a = 1; };
    if (b < 1) { b = 1; };
    VX0 = VX0 + dx * a;
    VY0 = VY0 + dy * b;
    clamp_origin(CUR_ROWS, CUR_COLS);
};

def zoom_by(dir: long) -> void {
    let z = ZOOM;
    if (dir > 0) {
        if (z < 2) { z = 2; } else { z = z * 2; };
        if (z > 16) { z = 16; };
    } else if (z > 2) {
        z = z / 2;
    } else {
        z = 0;
    };
    ZOOM = z;
    set_view(CUR_ROWS, CUR_COLS);
};

// ───────────────────────────────────────────────────────────── the runs ───

// headless() -- the deterministic run: a fixed surface, the frame loop, then
// the summary and the picture on stdout.  The framebuffer's own output goes to
// /dev/null and is kept in its capture buffer, so the summary can checksum the
// exact ANSI stream without putting escape sequences into a file a person wants
// to read.
def headless(rows: long, cols: long) -> void {
    let devnull = fs.open_file("/dev/null", "w");
    if (devnull >= 0) { fb.set_fd(devnull); };
    let s = fb.new(rows, cols);
    set_view(img_rows(s), cols);
    fb.capture_on();
    let want = FRAMES;
    if (want < 1) { want = 1; };
    let heap0 = heap_used();
    let t0 = time.now_us();
    let f = 0;
    while (f < want) {
        draw(s);
        fb.flush_diff(s);
        f = f + 1;
    };
    let el = time.now_us() - t0;
    let heap1 = heap_used();
    ANSI_BYTES = fb.capture_len();
    ANSI_CKS = fb.capture_checksum();
    fb.capture_off();
    summary(want);
    if (SHOWTIME != 0) {
        eputs("bmpview: decode " + tostring(DECODE_US) + " us, " +
              tostring(want) + " frames in " + tostring(el / 1000) + " ms (" +
              tostring(el / want) + " us a frame), heap " + tostring(heap0) +
              " -> " + tostring(heap1) + " (delta " + tostring(heap1 - heap0) + ")\n");
    };
    if (QUIET == 0) {
        print("");
        print("  " + tostring(IM.w) + "x" + tostring(IM.h) +
              " through the luminance ramp, one character per cell:");
        print("");
        dump_text(img_rows(s), cols);
    }
};

// interactive() -- the viewer proper.  term owns the restore guarantee, so the
// shape is term's shape: enter, run, and leave through exactly one call.
def interactive(rows: long, cols: long) -> void {
    if (!term.raw_mode()) {
        eputs("bmpview: not a terminal; use --no-tty\n");
        exit(1);
    };
    term.enter_screen();
    term.arm_watchdog();
    let s = fb.new(rows, cols);
    CUR_ROWS = img_rows(s);
    CUR_COLS = cols;
    set_view(CUR_ROWS, cols);
    fb.flush(s);
    let done = false;
    let f = 0;
    let heap0 = heap_used();
    let t0 = time.now_us();
    while (done == false) {
        draw(s);
        fb.flush_diff(s);
        f = f + 1;
        if (FRAMES > 0 && f >= FRAMES) {
            done = true;
        } else {
            // There is no animation here, so a frame is only drawn again once
            // a key has been read: a blocking read, which is what a viewer
            // wants, and what makes redraw-on-keypress the whole event loop.
            let k = term.read_key();
            if (k == K_Q || k == K_ETX || k == term.KEY_ESC) {
                done = true;
            } else if (k == term.KEY_UP || k == K_K) {
                scroll(0, -1);
            } else if (k == term.KEY_DOWN || k == K_J) {
                scroll(0, 1);
            } else if (k == term.KEY_LEFT || k == K_H) {
                scroll(-1, 0);
            } else if (k == term.KEY_RIGHT || k == K_L) {
                scroll(1, 0);
            } else if (k == K_PLUS) {
                zoom_by(1);
            } else if (k == K_MINUS) {
                zoom_by(-1);
            } else if (k == K_F) {
                ZOOM = 0;
                set_view(CUR_ROWS, cols);
            } else if (k == K_1) {
                ZOOM = 1;
                set_view(CUR_ROWS, cols);
            } else if (k == K_G) {
                MODE = (MODE + 1) % 3;
                set_view(CUR_ROWS, cols);
            } else if (k == K_0) {
                ZOOM = 0;
                set_view(CUR_ROWS, cols);
            };
        };
    };
    let heap1 = heap_used();
    let el = time.now_us() - t0;
    // Report BEFORE leaving: restore_all_exit() exits, so anything after it
    // never runs -- which is exactly the sort of thing a pty test finds and a
    // headless run never does.
    if (SHOWTIME != 0) {
        eputs("bmpview: " + tostring(f) + " frames in " + tostring(el / 1000) +
              " ms, heap " + tostring(heap0) + " -> " + tostring(heap1) +
              " (delta " + tostring(heap1 - heap0) + ")\n");
    };
    // Put the cursor back, leave the alt screen, restore the mode and exit, in
    // one call, and let that be the end of the program.
    term.restore_all_exit(0);
};

def main() {
    args.init("bmpview", "a BMP image viewer for the terminal: half blocks, colour or mono", OPTS);
    args.parse_or_exit(argv());
    FRAMES = args.get_long("frames", 0);
    ZOOM = args.get_long("zoom", 0);
    SHOWTIME = if (args.has("time")) { 1 } else { 0 };
    QUIET = if (args.has("quiet")) { 1 } else { 0 };
    NOTTY = if (args.has("no-tty")) { 1 } else { 0 };
    let mode = args.get_str("mode", "half");
    if (mode == "half") {
        MODE = M_HALF;
    } else if (mode == "color" || mode == "colour") {
        MODE = M_COLOUR;
    } else if (mode == "mono" || mode == "ascii") {
        MODE = M_MONO;
    } else {
        eputs("bmpview: --mode must be half, colour or mono, not '" + mode + "'\n");
        exit(1);
    };
    if (ZOOM < 0 || ZOOM > 16) {
        eputs("bmpview: --zoom must be 0 (fit) to 16\n");
        exit(1);
    };

    // --selftest carries its own four images, so it needs none of the above.
    if (args.has("selftest")) {
        let bad = selftest.run(bytes(IMG_TUX), bytes(IMG_TOP), bytes(IMG_32), bytes(IMG_8));
        if (bad > 0) { exit(1) };
        exit(0);
    };

    // The image: a positional operand, or --file, or the embedded one.
    let pos = args.positional();
    let named = args.get_str("file", "");
    if (len(pos) > 0 && len(named) > 0) {
        eputs("bmpview: name the file once, as an operand or with --file\n");
        exit(1);
    };
    if (len(pos) > 0) {
        NAME = pos[0];
        open_bytes(or_exit(pos[0]));
    } else if (len(named) > 0) {
        NAME = named;
        open_bytes(or_exit(named));
    } else {
        open_bytes(bytes(IMG_TUX));
    };

    if (NOTTY != 0) {
        let rows = 24;
        let cols = 80;
        let size = args.get_str("size", "");
        if (len(size) > 0 && index_of(size, "x") > 0) {
            let parts = size.split("x");
            if (len(parts) == 2 && args.num_ok(parts[0]) && args.num_ok(parts[1])) {
                // WxH, width first, as the help says: 80x24 is eighty columns
                // by twenty-four rows.
                cols = tonum(parts[0]);
                rows = tonum(parts[1]);
            };
        };
        if (rows < 3 || rows > fb.MAX_ROWS || cols < 8 || cols > fb.MAX_COLS) {
            eputs("bmpview: --size must be 8x3 to " + tostring(fb.MAX_COLS) + "x" +
                  tostring(fb.MAX_ROWS) + " cells\n");
            exit(1);
        };
        headless(rows, cols);
        exit(0);
    };

    let ws = term.size();
    interactive(ws.rows, ws.cols);
    exit(0)
}

main()