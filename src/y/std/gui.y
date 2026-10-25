// std/gui.y -- one window API over Win32, X11 and a plain buffer.
//
//     import gui;
//     let w = gui.open("hello", 640, 400)!;       // none: no display
//     gui.clear(w, 0x102030);
//     gui.text(w, 2, 1, "Hello", 0xffffff, 0x102030);
//     gui.present(w);
//     let ev = gui.new_event();
//     while (w.alive) {
//         while (gui.poll(w, ev)) { if (ev.kind == gui.EV_CLOSE) { gui.close(w); }; };
//         gui.wait(w, 16);
//     };
//
// A program never learns which system it is on: `open` picks the window system the
// process is running on (Windows: user32/gdi32, called from Y through the named OS
// layer; Linux: the X server's socket, the wire protocol spoken in Y, so a static
// ELF needs no libX11) and `open_headless` is a window that is only a buffer, for
// tests. `w.pixels` is the client area, 4 bytes a pixel, B G R A in memory (the
// u32 0xAARRGGBB), rows top to bottom, `w.width * 4` bytes apart; whatever the app
// writes there is on screen after `present`. A program that wants the platform
// reaches it through `w.win32?.hwnd` or `w.x11?.fd`: exactly one of the two is set.
//
// Events are polled, never called back: key (the key's code, Windows' virtual-key
// numbers on every system), char (a code point, after the keyboard layout), mouse
// move / button / wheel (client pixels), resize, focus, close, expose. A resize
// replaces `w.pixels` (a new array when the old one is too small), so read it from
// `w` each frame. Close is only an event: the window stays until `close`.
//
// A cell grid sits on top: `cell` rasterises one character cell (8x16 pixels times
// `w.scale`) with a baked bitmap font (gui.font beside this file: ASCII, Latin-1,
// Greek, arrows, geometric shapes and a few symbols, 1200 glyphs), and draws box
// drawing, block elements, shades and braille itself from rules so they tile exactly.
// `Grid` + `grid_flush` is the diffing renderer a terminal program wants: it
// rasterises only the cells that changed since the last flush.
//
// Everything runs on one thread (the one that opened the window).
import fs;
import ipc;

embed GUI_FONT from "gui.font";

export {
    HEADLESS, WIN32, X11, WAYLAND, YOS, EV_KEY, EV_CHAR, EV_MOVE, EV_BUTTON, EV_WHEEL,
    EV_RESIZE, EV_FOCUS, EV_CLOSE, EV_EXPOSE, MOD_SHIFT, MOD_CTRL, MOD_ALT,
    BTN_LEFT, BTN_MIDDLE, BTN_RIGHT, CELL_W, CELL_H,
    K_BACK, K_TAB, K_ENTER, K_ESC, K_SPACE, K_PGUP, K_PGDN, K_END, K_HOME, K_LEFT, K_UP,
    K_RIGHT, K_DOWN, K_INS, K_DEL, K_F1, K_SHIFT, K_CTRL, K_ALT,
    Window, Event, Win32Info, X11Info, Grid,
    open, open_headless, backend, backend_name, present, present_all, poll, wait, set_title,
    close, set_scale, set_hard, resize, read_back, checksum, checksum_of, inject, new_event, clear, fill, cell,
    text, cols, rows, pixel, grid_new, grid_put, grid_text, grid_clear, grid_flush,
    glyph_count, has_glyph, on_windows, redirect_stderr, write_ppm, verify_present
};

const HEADLESS = 0;
const WIN32 = 1;
const X11 = 2;
const WAYLAND = 3;
const YOS = 4;

const EV_KEY = 1;       // a: key code, b: 1 down / 0 up, c: modifiers, d: 1 if auto-repeat
const EV_CHAR = 2;      // a: code point, c: modifiers
const EV_MOVE = 3;      // a, b: x, y; c: buttons held (BTN_ bits)
const EV_BUTTON = 4;    // a, b: x, y; c: 1 left, 2 middle, 3 right; d: 1 down / 0 up
const EV_WHEEL = 5;     // a, b: x, y; c: notches, positive away from the user
const EV_RESIZE = 6;    // a, b: the new client width and height
const EV_FOCUS = 7;     // a: 1 gained / 0 lost
const EV_CLOSE = 8;     // the user asked to close the window
const EV_EXPOSE = 9;    // the window was uncovered; `poll` has already repainted it

const MOD_SHIFT = 1;
const MOD_CTRL = 2;
const MOD_ALT = 4;
const BTN_LEFT = 1;
const BTN_MIDDLE = 2;
const BTN_RIGHT = 4;

// key codes: the Windows virtual-key numbers (letters and digits are their ASCII capitals)
const K_BACK = 8;
const K_TAB = 9;
const K_ENTER = 13;
const K_SHIFT = 16;
const K_CTRL = 17;
const K_ALT = 18;
const K_ESC = 27;
const K_SPACE = 32;
const K_PGUP = 33;
const K_PGDN = 34;
const K_END = 35;
const K_HOME = 36;
const K_LEFT = 37;
const K_UP = 38;
const K_RIGHT = 39;
const K_DOWN = 40;
const K_INS = 45;
const K_DEL = 46;
const K_F1 = 112;       // F1..F12 are 112..123

const CELL_W = 8;
const CELL_H = 16;

// A program that wants a pixel font, not an anti-aliased one, turns this on
// with set_hard(true): coverage is thresholded so glyph edges land on whole
// pixels.  The default keeps the baked 4-bit coverage.
let HARD = false;

/** One thing that happened to a window; see the EV_ constants for the fields. */
type Event = { kind: long, a: long, b: long, c: long, d: long };

/** The Win32 handles of a window, for a program that wants to call user32 itself. */
type Win32Info = { hwnd: long, hdc: long, hinst: long };

/** The X connection of a window: the socket, the window id and the server's facts. */
type X11Info = {
    fd: long, win: long, gc: long, root: long, depth: long,
    atom_protocols: long, atom_delete: long,
    kmin: long, kmax: long, kpk: long, syms: [long],
    rx: [byte], rxn: long, pos: long,      // bytes received; those from `pos` on are not yet used
    maxreq: long, down: bool
};

type Window = {
    backend: long,
    width: long, height: long,      // the client area in pixels
    scale: long,                    // pixels per font pixel (an integer, 1 or more)
    pixels: [byte],                 // width * height * 4 bytes (it may be longer)
    title: str,
    alive: bool,                    // false once closed or destroyed
    win32: Win32Info?, x11: X11Info?,
    evq: [long], evr: long, evw: long,
    dx0: long, dy0: long, dx1: long, dy1: long,   // what changed since the last present
    mods: long, buttons: long, mx: long, my: long, hi: long
};

/** A grid of cells and the frame before it, for `grid_flush`. */
type Grid = {
    cols: long, rows: long,
    ch: [long], fg: [long], bg: [long], at: [long],
    pch: [long], pfg: [long], pbg: [long], pat: [long]
};

const EVQ = 128;

// ------------------------------------------------------------------ buffers ----

ndef y_bytes_zero(n: long) -> [byte] = "y_bytes_zero";

def zeros(n: long) -> [byte] {
    y_bytes_zero(n)
};

def long_array(n: long, v: long) -> [long] {
    let a: [long] = [];
    let i = 0;
    while (i < n) { a += v; i = i + 1; };
    a
};

def cstr(s: str) -> [byte] {
    let b = bytes(s);
    b += 0;
    b
};

def new_window(backend: long, title: str, w: long, h: long) -> Window {
    let win: Window = {
        backend: backend, width: w, height: h, scale: 1, pixels: zeros(w * h * 4), title: title,
        alive: true, win32: none, x11: none,
        evq: long_array(EVQ * 5, 0), evr: 0, evw: 0,
        dx0: 0, dy0: 0, dx1: w, dy1: h, mods: 0, buttons: 0, mx: 0, my: 0, hi: 0
    };
    win
};

/** A fresh Event to pass to `poll`. */
def new_event() -> Event {
    let e: Event = { kind: 0, a: 0, b: 0, c: 0, d: 0 };
    e
};

def push_event(w: Window, kind: long, a: long, b: long, c: long, d: long) -> void {
    if (w.evw - w.evr >= EVQ) { return; };
    let at = (w.evw % EVQ) * 5;
    w.evq[at] = kind;
    w.evq[at + 1] = a;
    w.evq[at + 2] = b;
    w.evq[at + 3] = c;
    w.evq[at + 4] = d;
    w.evw += 1;
};

/** Queue an event as if the window system had delivered it (tests, and replays). */
def inject(w: Window, kind: long, a: long, b: long, c: long, d: long) -> void {
    push_event(w, kind, a, b, c, d);
};

def mark(w: Window, x0: long, y0: long, x1: long, y1: long) -> void {
    let a = x0;
    let b = y0;
    let c = x1;
    let d = y1;
    if (a < 0) { a = 0; };
    if (b < 0) { b = 0; };
    if (c > w.width) { c = w.width; };
    if (d > w.height) { d = w.height; };
    if (a >= c || b >= d) { return; };
    if (w.dx0 >= w.dx1 || w.dy0 >= w.dy1) {
        w.dx0 = a;
        w.dy0 = b;
        w.dx1 = c;
        w.dy1 = d;
        return;
    };
    if (a < w.dx0) { w.dx0 = a; };
    if (b < w.dy0) { w.dy0 = b; };
    if (c > w.dx1) { w.dx1 = c; };
    if (d > w.dy1) { w.dy1 = d; };
};

def clean(w: Window) -> void {
    w.dx0 = 0;
    w.dy0 = 0;
    w.dx1 = 0;
    w.dy1 = 0;
};

// ------------------------------------------------------------------- pixels ----

/** The pixel at (x, y) as 0xRRGGBB, or -1 outside the window. */
def pixel(w: Window, x: long, y: long) -> long {
    if (x < 0 || y < 0 || x >= w.width || y >= w.height) { return -1; };
    let p: *u32 = ptr_from(ptr_addr(&w.pixels[0]) + (y * w.width + x) * 4);
    *p & 0xffffff
};

/** Fill the rectangle (x, y, rw, rh) with the colour 0xRRGGBB. */
def fill(w: Window, x: long, y: long, rw: long, rh: long, c: long) -> void {
    let x0 = x;
    let y0 = y;
    let x1 = x + rw;
    let y1 = y + rh;
    if (x0 < 0) { x0 = 0; };
    if (y0 < 0) { y0 = 0; };
    if (x1 > w.width) { x1 = w.width; };
    if (y1 > w.height) { y1 = w.height; };
    if (x0 >= x1 || y0 >= y1) { return; };
    let base = ptr_addr(&w.pixels[0]);
    let v = 0xff000000 | (c & 0xffffff);
    let yy = y0;
    while (yy < y1) {
        let q: *u32 = ptr_from(base + (yy * w.width + x0) * 4);
        let n = x1 - x0;
        while (n > 0) {
            *q = v;
            q += 1;
            n -= 1;
        };
        yy += 1;
    };
    mark(w, x0, y0, x1, y1);
};

/** Fill the whole window with a colour. */
def clear(w: Window, c: long) -> void {
    fill(w, 0, 0, w.width, w.height, c);
};

/** `bg` with `fg` over it at coverage `a` (0..255), both 0xRRGGBB. */
def mix(bg: long, fg: long, a: long) -> long {
    let t = a + (a >> 7);
    let r = ((bg >> 16) & 255) + (((((fg >> 16) & 255) - ((bg >> 16) & 255)) * t) >> 8);
    let g = ((bg >> 8) & 255) + (((((fg >> 8) & 255) - ((bg >> 8) & 255)) * t) >> 8);
    let b = (bg & 255) + ((((fg & 255) - (bg & 255)) * t) >> 8);
    (r << 16) | (g << 8) | b
};

// --------------------------------------------------------------------- font ----

let GN = -1;                       // glyph count; -1 until the header is read
let GCW = 8;
let GCH = 16;
let GOFF = 0;                      // where the coverage data starts
let ASC: [long; 256] = [-2; 256];

def font_init() -> void {
    if (GN >= 0) { return; };
    GN = GUI_FONT[4] | (GUI_FONT[5] << 8);
    GCW = GUI_FONT[6];
    GCH = GUI_FONT[7];
    GOFF = 8 + 4 * GN;
};

def font_cp(i: long) -> long {
    let o = 8 + 4 * i;
    GUI_FONT[o] | (GUI_FONT[o + 1] << 8) | (GUI_FONT[o + 2] << 16) | (GUI_FONT[o + 3] << 24)
};

def glyph_search(cp: long) -> long {
    let lo = 0;
    let hi = GN - 1;
    while (lo <= hi) {
        let mid = (lo + hi) / 2;
        let v = font_cp(mid);
        if (v == cp) { return mid; };
        if (v < cp) { lo = mid + 1; } else { hi = mid - 1; };
    };
    -1
};

/** The index of `cp` in the baked font, or -1 (drawn rules and blanks have none). */
def glyph_index(cp: long) -> long {
    font_init();
    if (cp >= 0 && cp < 256) {
        let v = ASC[cp];
        if (v == -2) {
            v = glyph_search(cp);
            ASC[cp] = v;
        };
        return v;
    };
    glyph_search(cp)
};

/** How many glyphs the baked font holds. */
def glyph_count() -> long {
    font_init();
    GN
};

/** True when `cell` can draw `cp` (a baked glyph, or one of the drawn ranges). */
def has_glyph(cp: long) -> bool {
    if (cp == 32) { return true; };
    if (cp >= 0x2500 && cp <= 0x259f) { return true; };
    if (cp >= 0x2800 && cp <= 0x28ff) { return true; };
    glyph_index(cp) >= 0
};

// ----------------------------------------------------- the box drawing table ----

// U+2500..U+257F: the weight of the four arms, L | R<<2 | U<<4 | D<<6, with 0 none,
// 1 light, 2 heavy, 3 double (src/tools/guifont/mkbox.py, from the Unicode names)
let BOXT: [long; 128] = [
    5, 10, 80, 160, 5, 10, 80, 160, 5, 10, 80, 160, 68, 72, 132, 136,
    65, 66, 129, 130, 20, 24, 36, 40, 17, 18, 33, 34, 84, 88, 100, 148,
    164, 104, 152, 168, 81, 82, 97, 145, 161, 98, 146, 162, 69, 70, 73, 74,
    133, 134, 137, 138, 21, 22, 25, 26, 37, 38, 41, 42, 85, 86, 89, 90,
    101, 149, 165, 102, 105, 150, 153, 106, 154, 166, 169, 170, 5, 10, 80, 160,
    15, 240, 76, 196, 204, 67, 193, 195, 28, 52, 60, 19, 49, 51, 92, 244,
    252, 83, 241, 243, 79, 197, 207, 31, 53, 63, 95, 245, 255, 68, 65, 17,
    20, 0, 0, 0, 1, 16, 4, 64, 2, 32, 8, 128, 9, 144, 6, 96
];

// the quadrants of U+2596..U+259F: UL 1, UR 2, LL 4, LR 8
let QUAD: [long; 10] = [4, 8, 1, 13, 9, 7, 11, 2, 6, 14];

// ------------------------------------------------------------ cell drawing ----

def band(w: Window, x0: long, y0: long, x1: long, y1: long, c: long) -> void {
    fill(w, x0, y0, x1 - x0, y1 - y0, c);
};

/** The width of an arm of weight k in units of `u` pixels. */
def arm_span(k: long, u: long) -> long {
    if (k == 0) { 0 } else if (k == 1) { u } else if (k == 2) { 2 * u } else { 3 * u }
};

// one horizontal run of weight k from x0 to x1, centred on the cell's middle row
def hrun(w: Window, ox: long, oy: long, x0: long, x1: long, k: long, ch: long, u: long, c: long) -> void {
    if (k == 0) { return; };
    let th = arm_span(k, u);
    let y = oy + (ch - th) / 2;
    if (k == 3) {
        band(w, ox + x0, y, ox + x1, y + u, c);
        band(w, ox + x0, y + 2 * u, ox + x1, y + 3 * u, c);
    } else {
        band(w, ox + x0, y, ox + x1, y + th, c);
    };
};

def vrun(w: Window, ox: long, oy: long, y0: long, y1: long, k: long, cw: long, u: long, c: long) -> void {
    if (k == 0) { return; };
    let th = arm_span(k, u);
    let x = ox + (cw - th) / 2;
    if (k == 3) {
        band(w, x, oy + y0, x + u, oy + y1, c);
        band(w, x + 2 * u, oy + y0, x + 3 * u, oy + y1, c);
    } else {
        band(w, x, oy + y0, x + th, oy + y1, c);
    };
};

def draw_box(w: Window, cp: long, ox: long, oy: long, c: long) -> void {
    let s = w.scale;
    let cw = CELL_W * s;
    let ch = CELL_H * s;
    let u = s;
    let bits = BOXT[cp - 0x2500];
    if (bits == 0) {
        // the diagonals U+2571..U+2573
        let y = 0;
        while (y < ch) {
            let x = ((ch - 1 - y) * (cw - 1)) / (ch - 1);
            let x2 = (y * (cw - 1)) / (ch - 1);
            if (cp == 0x2571 || cp == 0x2573) { band(w, ox + x, oy + y, ox + x + u, oy + y + 1, c); };
            if (cp == 0x2572 || cp == 0x2573) { band(w, ox + x2, oy + y, ox + x2 + u, oy + y + 1, c); };
            y += 1;
        };
        return;
    };
    let l = bits & 3;
    let r = (bits >> 2) & 3;
    let up = (bits >> 4) & 3;
    let dn = (bits >> 6) & 3;
    let vs = arm_span(up, u);
    let ds = arm_span(dn, u);
    if (ds > vs) { vs = ds; };
    let hs = arm_span(l, u);
    let rs = arm_span(r, u);
    if (rs > hs) { hs = rs; };
    let xc0 = (cw - vs) / 2;
    let xc1 = xc0 + vs;
    let yc0 = (ch - hs) / 2;
    let yc1 = yc0 + hs;
    hrun(w, ox, oy, 0, xc1, l, ch, u, c);
    hrun(w, ox, oy, xc0, cw, r, ch, u, c);
    vrun(w, ox, oy, 0, yc1, up, cw, u, c);
    vrun(w, ox, oy, yc0, ch, dn, cw, u, c);
};

def draw_block(w: Window, cp: long, ox: long, oy: long, fg: long, bg: long) -> void {
    let cw = CELL_W * w.scale;
    let ch = CELL_H * w.scale;
    if (cp == 0x2580) {
        band(w, ox, oy, ox + cw, oy + ch / 2, fg);
    } else if (cp >= 0x2581 && cp <= 0x2588) {
        let n = cp - 0x2580;
        band(w, ox, oy + ch - ch * n / 8, ox + cw, oy + ch, fg);
    } else if (cp >= 0x2589 && cp <= 0x258f) {
        let n = 0x2590 - cp;
        band(w, ox, oy, ox + cw * n / 8, oy + ch, fg);
    } else if (cp == 0x2590) {
        band(w, ox + cw / 2, oy, ox + cw, oy + ch, fg);
    } else if (cp >= 0x2591 && cp <= 0x2593) {
        band(w, ox, oy, ox + cw, oy + ch, mix(bg, fg, (cp - 0x2590) * 64 - 1));
    } else if (cp == 0x2594) {
        band(w, ox, oy, ox + cw, oy + ch / 8, fg);
    } else if (cp == 0x2595) {
        band(w, ox + cw - cw / 8, oy, ox + cw, oy + ch, fg);
    } else if (cp >= 0x2596 && cp <= 0x259f) {
        let m = QUAD[cp - 0x2596];
        let hw = cw / 2;
        let hh = ch / 2;
        if ((m & 1) != 0) { band(w, ox, oy, ox + hw, oy + hh, fg); };
        if ((m & 2) != 0) { band(w, ox + hw, oy, ox + cw, oy + hh, fg); };
        if ((m & 4) != 0) { band(w, ox, oy + hh, ox + hw, oy + ch, fg); };
        if ((m & 8) != 0) { band(w, ox + hw, oy + hh, ox + cw, oy + ch, fg); };
    };
};

// braille: two columns of four dots, bits 0 1 2 6 down the left, 3 4 5 7 down the right
def draw_braille(w: Window, cp: long, ox: long, oy: long, fg: long) -> void {
    let bits = cp - 0x2800;
    let s = w.scale;
    let d = 2 * s;
    let i = 0;
    while (i < 8) {
        if ((bits & (1 << i)) != 0) {
            let col = 0;
            let row = 0;
            if (i < 3) { col = 0; row = i; }
            else if (i < 6) { col = 1; row = i - 3; }
            else if (i == 6) { col = 0; row = 3; }
            else { col = 1; row = 3; };
            let x = ox + (CELL_W * s / 4) * (1 + 2 * col) - s;
            let y = oy + (CELL_H * s / 8) * (1 + 2 * row) - s;
            band(w, x, y, x + d, y + d, fg);
        };
        i += 1;
    };
};

// the coverage (0..255, from 4 bits) of glyph gi at (gx, gy)
def cov(gi: long, gx: long, gy: long) -> long {
    let p = gy * GCW + gx;
    let b = GUI_FONT[GOFF + gi * (GCW * GCH / 2) + (p >> 1)];
    if ((p & 1) == 0) { (b & 15) * 17 } else { ((b >> 4) & 15) * 17 }
};

def set_hard(on: bool) -> void { HARD = on; };

def draw_glyph(w: Window, gi: long, ox: long, oy: long, fg: long, bg: long, bold: bool) -> void {
    let s = w.scale;
    let gy = 0;
    while (gy < GCH) {
        let gx = 0;
        while (gx < GCW) {
            let a = cov(gi, gx, gy);
            if (bold && gx > 0) {
                let a2 = cov(gi, gx - 1, gy);
                if (a2 > a) { a = a2; };
            };
            if (HARD) { a = if (a >= 128) { 255 } else { 0 }; };
            if (a != 0) {
                let c = fg;
                if (a != 255) { c = mix(bg, fg, a); };
                fill(w, ox + gx * s, oy + gy * s, s, s, c);
            };
            gx += 1;
        };
        gy += 1;
    };
};

// an outline for a code point the font does not have
def draw_tofu(w: Window, ox: long, oy: long, fg: long) -> void {
    let s = w.scale;
    let cw = CELL_W * s;
    let ch = CELL_H * s;
    band(w, ox + s, oy + 2 * s, ox + cw - s, oy + 3 * s, fg);
    band(w, ox + s, oy + ch - 4 * s, ox + cw - s, oy + ch - 3 * s, fg);
    band(w, ox + s, oy + 2 * s, ox + 2 * s, oy + ch - 3 * s, fg);
    band(w, ox + cw - 2 * s, oy + 2 * s, ox + cw - s, oy + ch - 3 * s, fg);
};

/** Draw the cell at (`col`, `row`): background `bg`, then the character `cp` in `fg`.
`attr`: 1 bold, 2 dim, 8 underline, 16 reverse. */
def cell(w: Window, col: long, row: long, cp: long, fg: long, bg: long, attr: long = 0) -> void {
    let f = fg;
    let b = bg;
    if ((attr & 16) != 0) { f = bg; b = fg; };
    if ((attr & 2) != 0) { f = mix(b, f, 128); };
    let cw = CELL_W * w.scale;
    let ch = CELL_H * w.scale;
    let ox = col * cw;
    let oy = row * ch;
    fill(w, ox, oy, cw, ch, b);
    if (cp <= 32) {
        if ((attr & 8) != 0) { band(w, ox, oy + ch - 2 * w.scale, ox + cw, oy + ch - w.scale, f); };
        return;
    };
    if (cp >= 0x2500 && cp <= 0x257f) {
        draw_box(w, cp, ox, oy, f);
    } else if (cp >= 0x2580 && cp <= 0x259f) {
        draw_block(w, cp, ox, oy, f, b);
    } else if (cp >= 0x2800 && cp <= 0x28ff) {
        draw_braille(w, cp, ox, oy, f);
    } else {
        let gi = glyph_index(cp);
        if (gi >= 0) { draw_glyph(w, gi, ox, oy, f, b, (attr & 1) != 0); }
        else { draw_tofu(w, ox, oy, f); };
    };
    if ((attr & 8) != 0) { band(w, ox, oy + ch - 2 * w.scale, ox + cw, oy + ch - w.scale, f); };
};

/** Draw the UTF-8 string `s` as cells from (`col`, `row`); the column after it. */
def text(w: Window, col: long, row: long, s: str, fg: long, bg: long) -> long {
    let c = col;
    let i = 0;
    let n = len(s);
    while (i < n) {
        let b0: long = s[i];
        let cp: long = b0;
        let k = 1;
        if (b0 >= 0xf0 && i + 3 < n) { cp = ((b0 & 7) << 18) | ((s[i + 1] & 63) << 12) | ((s[i + 2] & 63) << 6) | (s[i + 3] & 63); k = 4; }
        else if (b0 >= 0xe0 && i + 2 < n) { cp = ((b0 & 15) << 12) | ((s[i + 1] & 63) << 6) | (s[i + 2] & 63); k = 3; }
        else if (b0 >= 0xc0 && i + 1 < n) { cp = ((b0 & 31) << 6) | (s[i + 1] & 63); k = 2; };
        cell(w, c, row, cp, fg, bg, 0);
        c += 1;
        i += k;
    };
    c
};

/** Whole cells across the window. */
def cols(w: Window) -> long { w.width / (CELL_W * w.scale) };

/** Whole cells down the window. */
def rows(w: Window) -> long { w.height / (CELL_H * w.scale) };

// --------------------------------------------------------------------- grid ----

/** A `cols` by `rows` grid, blank, with no previous frame (the first flush draws all). */
def grid_new(cols: long, rows: long) -> Grid {
    let n = cols * rows;
    let g: Grid = {
        cols: cols, rows: rows,
        ch: long_array(n, 32), fg: long_array(n, 0xffffff), bg: long_array(n, 0), at: long_array(n, 0),
        pch: long_array(n, -1), pfg: long_array(n, 0), pbg: long_array(n, 0), pat: long_array(n, 0)
    };
    g
};

def grid_put(g: Grid, x: long, y: long, cp: long, fg: long, bg: long, attr: long = 0) -> void {
    if (x < 0 || y < 0 || x >= g.cols || y >= g.rows) { return; };
    let i = y * g.cols + x;
    g.ch[i] = cp;
    g.fg[i] = fg;
    g.bg[i] = bg;
    g.at[i] = attr;
};

/** Put the UTF-8 string `s` into the grid from (`x`, `y`); the column after it. */
def grid_text(g: Grid, x: long, y: long, s: str, fg: long, bg: long) -> long {
    let c = x;
    let i = 0;
    let n = len(s);
    while (i < n) {
        let b0: long = s[i];
        let cp: long = b0;
        let k = 1;
        if (b0 >= 0xf0 && i + 3 < n) { cp = ((b0 & 7) << 18) | ((s[i + 1] & 63) << 12) | ((s[i + 2] & 63) << 6) | (s[i + 3] & 63); k = 4; }
        else if (b0 >= 0xe0 && i + 2 < n) { cp = ((b0 & 15) << 12) | ((s[i + 1] & 63) << 6) | (s[i + 2] & 63); k = 3; }
        else if (b0 >= 0xc0 && i + 1 < n) { cp = ((b0 & 31) << 6) | (s[i + 1] & 63); k = 2; };
        grid_put(g, c, y, cp, fg, bg, 0);
        c += 1;
        i += k;
    };
    c
};

def grid_clear(g: Grid, bg: long) -> void {
    let i = 0;
    let n = g.cols * g.rows;
    while (i < n) {
        g.ch[i] = 32;
        g.fg[i] = bg;
        g.bg[i] = bg;
        g.at[i] = 0;
        i += 1;
    };
};

/** Rasterise the cells that differ from the last flush into the window (call
`present` after); how many cells that was. */
def grid_flush(w: Window, g: Grid) -> long {
    let n = 0;
    let y = 0;
    while (y < g.rows) {
        let x = 0;
        while (x < g.cols) {
            let i = y * g.cols + x;
            if (g.ch[i] != g.pch[i] || g.fg[i] != g.pfg[i] || g.bg[i] != g.pbg[i] || g.at[i] != g.pat[i]) {
                cell(w, x, y, g.ch[i], g.fg[i], g.bg[i], g.at[i]);
                g.pch[i] = g.ch[i];
                g.pfg[i] = g.fg[i];
                g.pbg[i] = g.bg[i];
                g.pat[i] = g.at[i];
                n += 1;
            };
            x += 1;
        };
        y += 1;
    };
    n
};

/** A 32-bit FNV-1a style digest of the first `n` pixels of `px` (one step a pixel,
over its 0xRRGGBB), the same on every system. */
def checksum_of(px: [byte], n: long) -> long {
    let h = 2166136261;
    let p: *u32 = ptr_from(ptr_addr(&px[0]));
    let i = 0;
    while (i < n) {
        h = ((h ^ (*p & 0xffffff)) * 16777619) & 0xffffffff;
        p += 1;
        i += 1;
    };
    h
};

/** The digest of the window's pixels (`checksum_of` over the client area). */
def checksum(w: Window) -> long {
    checksum_of(w.pixels, w.width * w.height)
};

// ------------------------------------------------------------------- Win32 ----
// user32 and gdi32 are reached through two OS-layer names (arch/wgui.s): a symbol
// lookup and a call with a block of arguments. The window procedure is an assembly
// trampoline that queues (hwnd, message, wparam, lparam) of the messages we care
// about into RING, which is drained after each DispatchMessage.

const F_RegisterClassExA = 0;
const F_CreateWindowExA = 1;
const F_DefWindowProcA = 2;
const F_ShowWindow = 3;
const F_PeekMessageA = 4;
const F_TranslateMessage = 5;
const F_DispatchMessageA = 6;
const F_DestroyWindow = 7;
const F_SetWindowTextA = 8;
const F_AdjustWindowRectEx = 9;
const F_GetDC = 10;
const F_ReleaseDC = 11;
const F_LoadCursorA = 12;
const F_SetCapture = 13;
const F_ReleaseCapture = 14;
const F_GetKeyState = 15;
const F_MsgWait = 16;
const F_SetProcessDPIAware = 17;
const F_SetForegroundWindow = 18;
const F_IsWindow = 19;
const F_StretchDIBits = 20;
const F_CreateCompatibleDC = 21;
const F_CreateCompatibleBitmap = 22;
const F_SelectObject = 23;
const F_BitBlt = 24;
const F_GetDIBits = 25;
const F_DeleteObject = 26;
const F_DeleteDC = 27;
const F_GetModuleHandleA = 28;
const F_SetWindowPos = 29;

let FN: [long; 32] = [0; 32];
let WA: [long; 16] = [0; 16];            // the argument block of a call
let RING: [long; 1032] = [0; 1032];      // wgui.s: 8 header quadwords, then 256 entries of 4
let RING_READ = 0;
let W32_READY = 0;                       // 0 not tried, 1 ready, -1 not available
let W32_CLASS: [byte; 16] = [0; 16];
let W32_CLS: [long; 12] = [0; 12];       // WNDCLASSEXA
let W32_BMI: [long; 8] = [0; 8];         // BITMAPINFOHEADER and room
let W32_RC: [long; 4] = [0; 4];          // RECT
let W32_MSG: [long; 8] = [0; 8];         // MSG

def gsym(dll: str, name: str) -> long {
    let d = cstr(dll);
    let n = cstr(name);
    os_call("y_os_gui_sym", &d[0], &n[0])
};

def gcall(f: long, n: long) -> long {
    os_call("y_os_gui_call", FN[f], &WA[0], n)
};

def gcall4(f: long, a: long, b: long, c: long, d: long) -> long {
    WA[0] = a;
    WA[1] = b;
    WA[2] = c;
    WA[3] = d;
    gcall(f, 4)
};

def w32_load(i: long, dll: str, name: str) -> bool {
    FN[i] = gsym(dll, name);
    FN[i] != 0
};

def w32_init() -> bool {
    if (W32_READY != 0) { return W32_READY > 0; };
    W32_READY = -1;
    let ok = w32_load(F_RegisterClassExA, "user32.dll", "RegisterClassExA");
    ok = ok && w32_load(F_CreateWindowExA, "user32.dll", "CreateWindowExA");
    ok = ok && w32_load(F_DefWindowProcA, "user32.dll", "DefWindowProcA");
    ok = ok && w32_load(F_ShowWindow, "user32.dll", "ShowWindow");
    ok = ok && w32_load(F_PeekMessageA, "user32.dll", "PeekMessageA");
    ok = ok && w32_load(F_TranslateMessage, "user32.dll", "TranslateMessage");
    ok = ok && w32_load(F_DispatchMessageA, "user32.dll", "DispatchMessageA");
    ok = ok && w32_load(F_DestroyWindow, "user32.dll", "DestroyWindow");
    ok = ok && w32_load(F_SetWindowTextA, "user32.dll", "SetWindowTextA");
    ok = ok && w32_load(F_AdjustWindowRectEx, "user32.dll", "AdjustWindowRectEx");
    ok = ok && w32_load(F_GetDC, "user32.dll", "GetDC");
    ok = ok && w32_load(F_ReleaseDC, "user32.dll", "ReleaseDC");
    ok = ok && w32_load(F_LoadCursorA, "user32.dll", "LoadCursorA");
    ok = ok && w32_load(F_SetCapture, "user32.dll", "SetCapture");
    ok = ok && w32_load(F_ReleaseCapture, "user32.dll", "ReleaseCapture");
    ok = ok && w32_load(F_GetKeyState, "user32.dll", "GetKeyState");
    ok = ok && w32_load(F_MsgWait, "user32.dll", "MsgWaitForMultipleObjects");
    ok = ok && w32_load(F_SetForegroundWindow, "user32.dll", "SetForegroundWindow");
    ok = ok && w32_load(F_IsWindow, "user32.dll", "IsWindow");
    ok = ok && w32_load(F_SetWindowPos, "user32.dll", "SetWindowPos");
    ok = ok && w32_load(F_StretchDIBits, "gdi32.dll", "StretchDIBits");
    ok = ok && w32_load(F_CreateCompatibleDC, "gdi32.dll", "CreateCompatibleDC");
    ok = ok && w32_load(F_CreateCompatibleBitmap, "gdi32.dll", "CreateCompatibleBitmap");
    ok = ok && w32_load(F_SelectObject, "gdi32.dll", "SelectObject");
    ok = ok && w32_load(F_BitBlt, "gdi32.dll", "BitBlt");
    ok = ok && w32_load(F_GetDIBits, "gdi32.dll", "GetDIBits");
    ok = ok && w32_load(F_DeleteObject, "gdi32.dll", "DeleteObject");
    ok = ok && w32_load(F_DeleteDC, "gdi32.dll", "DeleteDC");
    ok = ok && w32_load(F_GetModuleHandleA, "kernel32.dll", "GetModuleHandleA");
    if (!ok) { return false; };
    // an optional one: without it a high-DPI display stretches the window's bitmap
    let dpi = gsym("user32.dll", "SetProcessDPIAware");
    if (dpi != 0) {
        FN[30] = dpi;
        WA[0] = 0;
        gcall(30, 4);
    };
    let proc = os_call("y_os_gui_wndproc", &RING[0], FN[F_DefWindowProcA]);
    if (proc == 0) { return false; };
    // the class: CS_OWNDC (so one device context serves for good), an arrow cursor, no brush
    let name = "YGuiWindow";
    let i = 0;
    while (i < len(name)) { W32_CLASS[i] = name[i]; i += 1; };
    let hinst = gcall4(F_GetModuleHandleA, 0, 0, 0, 0);
    let cursor = gcall4(F_LoadCursorA, 0, 32512, 0, 0);
    W32_CLS[0] = 80 | (32 << 32);                 // cbSize, style CS_OWNDC
    W32_CLS[1] = proc;
    W32_CLS[2] = 0;                               // cbClsExtra, cbWndExtra
    W32_CLS[3] = hinst;
    W32_CLS[4] = 0;                               // hIcon
    W32_CLS[5] = cursor;
    W32_CLS[6] = 0;                               // hbrBackground
    W32_CLS[7] = 0;                               // lpszMenuName
    W32_CLS[8] = ptr_addr(&W32_CLASS[0]);
    W32_CLS[9] = 0;                               // hIconSm
    let atom = gcall4(F_RegisterClassExA, ptr_addr(&W32_CLS[0]), 0, 0, 0) & 0xffff;
    if (atom == 0) { return false; };
    W32_READY = 1;
    true
};

def w32_open(title: str, cw: long, ch: long) -> Window? {
    if (!w32_init()) { return none; };
    // the outer size that leaves a client area of cw x ch (WS_OVERLAPPEDWINDOW); a RECT is
    // { left, top } and { right, bottom } as two quadwords of two 32-bit fields
    let style = 0xcf0000;
    W32_RC[0] = 0;
    W32_RC[1] = cw | (ch << 32);
    gcall4(F_AdjustWindowRectEx, ptr_addr(&W32_RC[0]), style, 0, 0);
    let rw = (W32_RC[1] & 0xffffffff) - (W32_RC[0] & 0xffffffff);
    let rh = ((W32_RC[1] >> 32) & 0xffffffff) - ((W32_RC[0] >> 32) & 0xffffffff);
    if (rw >= 2147483648) { rw -= 4294967296; };
    if (rh >= 2147483648) { rh -= 4294967296; };
    let t = cstr(title);
    WA[0] = 0;                              // exStyle
    WA[1] = ptr_addr(&W32_CLASS[0]);
    WA[2] = ptr_addr(&t[0]);
    WA[3] = style;
    WA[4] = 0x80000000;                     // CW_USEDEFAULT
    WA[5] = 0x80000000;
    WA[6] = rw;
    WA[7] = rh;
    WA[8] = 0;                              // parent
    WA[9] = 0;                              // menu
    WA[10] = W32_CLS[3];                    // hInstance
    WA[11] = 0;
    let hwnd = gcall(F_CreateWindowExA, 12);
    if (hwnd == 0) { return none; };
    let hdc = gcall4(F_GetDC, hwnd, 0, 0, 0);
    let w = new_window(WIN32, title, cw, ch);
    w.win32 = some({ hwnd: hwnd, hdc: hdc, hinst: W32_CLS[3] });
    gcall4(F_ShowWindow, hwnd, 1, 0, 0);
    gcall4(F_SetForegroundWindow, hwnd, 0, 0, 0);
    some(w)
};

def w32_hwnd(w: Window) -> long {
    let i = w.win32;
    if (i == none) { 0 } else { i!.hwnd }
};

def w32_hdc(w: Window) -> long {
    let i = w.win32;
    if (i == none) { 0 } else { i!.hdc }
};

// BITMAPINFOHEADER for a top-down 32-bit bitmap `w.width` wide and `rows` high
def w32_bmi(w: Window, rows: long) -> long {
    W32_BMI[0] = 40 | (w.width << 32);
    W32_BMI[1] = ((0 - rows) & 0xffffffff) | (1 << 32) | (32 << 48);
    W32_BMI[2] = 0;
    W32_BMI[3] = 0;
    W32_BMI[4] = 0;
    W32_BMI[5] = 0;
    ptr_addr(&W32_BMI[0])
};

def w32_present(w: Window, x0: long, y0: long, x1: long, y1: long) -> void {
    w32_blit(w, w32_hdc(w), x0, y0, x1, y1);
};

// the rectangle of the pixel buffer onto a device context (the window's, or a memory one)
def w32_blit(w: Window, hdc: long, x0: long, y0: long, x1: long, y1: long) -> void {
    let rw = x1 - x0;
    let rh = y1 - y0;
    if (rw <= 0 || rh <= 0) { return; };
    // the bits handed over start at row y0 and the source rectangle is measured from there:
    // StretchDIBits counts a top-down bitmap's rows from the bottom, so a source y other
    // than 0 lands somewhere else (measured: a partial present showed the wrong rows)
    WA[0] = hdc;
    WA[1] = x0;
    WA[2] = y0;
    WA[3] = rw;
    WA[4] = rh;
    WA[5] = x0;
    WA[6] = 0;
    WA[7] = rw;
    WA[8] = rh;
    WA[9] = ptr_addr(&w.pixels[0]) + y0 * w.width * 4;
    WA[10] = w32_bmi(w, rh);
    WA[11] = 0;                  // DIB_RGB_COLORS
    WA[12] = 0xcc0020;           // SRCCOPY
    gcall(F_StretchDIBits, 13);
};

def w32_signed16(v: long) -> long {
    let x = v & 0xffff;
    if (x >= 32768) { x - 65536 } else { x }
};

def w32_mods() -> long {
    let m = 0;
    if ((gcall4(F_GetKeyState, 16, 0, 0, 0) & 0x8000) != 0) { m = m | MOD_SHIFT; };
    if ((gcall4(F_GetKeyState, 17, 0, 0, 0) & 0x8000) != 0) { m = m | MOD_CTRL; };
    if ((gcall4(F_GetKeyState, 18, 0, 0, 0) & 0x8000) != 0) { m = m | MOD_ALT; };
    m
};

def w32_buttons(wp: long) -> long {
    let b = 0;
    if ((wp & 1) != 0) { b = b | BTN_LEFT; };
    if ((wp & 2) != 0) { b = b | BTN_RIGHT; };
    if ((wp & 16) != 0) { b = b | BTN_MIDDLE; };
    b
};

// one queued message
def w32_message(w: Window, msg: long, wp: long, lp: long) -> void {
    if (msg == 5) {                                  // WM_SIZE
        if (wp == 1) { return; };                    // minimised
        let nw = lp & 0xffff;
        let nh = (lp >> 16) & 0xffff;
        if (nw > 0 && nh > 0 && (nw != w.width || nh != w.height)) { set_size(w, nw, nh); };
    } else if (msg == 7) {
        push_event(w, EV_FOCUS, 1, 0, 0, 0);
    } else if (msg == 8) {
        push_event(w, EV_FOCUS, 0, 0, 0, 0);
    } else if (msg == 16) {                          // WM_CLOSE
        push_event(w, EV_CLOSE, 0, 0, 0, 0);
    } else if (msg == 2) {                           // WM_DESTROY
        if (w.alive) {
            w.alive = false;
            push_event(w, EV_CLOSE, 0, 0, 0, 0);
        };
    } else if (msg == 15) {                          // WM_PAINT: nothing was lost but the screen
        w32_present(w, 0, 0, w.width, w.height);
        push_event(w, EV_EXPOSE, 0, 0, w.width, w.height);
    } else if (msg == 0x100 || msg == 0x104) {
        w.mods = w32_mods();
        push_event(w, EV_KEY, wp & 255, 1, w.mods, (lp >> 30) & 1);
    } else if (msg == 0x101 || msg == 0x105) {
        w.mods = w32_mods();
        push_event(w, EV_KEY, wp & 255, 0, w.mods, 0);
    } else if (msg == 0x102 || msg == 0x106) {       // WM_CHAR: UTF-16 code units
        let u = wp & 0xffff;
        if (u >= 0xd800 && u < 0xdc00) {
            w.hi = u;
        } else if (u >= 0xdc00 && u < 0xe000 && w.hi != 0) {
            push_event(w, EV_CHAR, 65536 + ((w.hi - 0xd800) << 10) + (u - 0xdc00), 0, w32_mods(), 0);
            w.hi = 0;
        } else {
            push_event(w, EV_CHAR, u, 0, w32_mods(), 0);
        };
    } else if (msg == 0x200) {
        w.mx = w32_signed16(lp);
        w.my = w32_signed16(lp >> 16);
        w.buttons = w32_buttons(wp);
        push_event(w, EV_MOVE, w.mx, w.my, w.buttons, 0);
    } else if (msg == 0x201 || msg == 0x202 || msg == 0x204 || msg == 0x205 || msg == 0x207 || msg == 0x208) {
        let x = w32_signed16(lp);
        let y = w32_signed16(lp >> 16);
        let b = 1;
        if (msg == 0x204 || msg == 0x205) { b = 3; };
        if (msg == 0x207 || msg == 0x208) { b = 2; };
        let down = 0;
        if (msg == 0x201 || msg == 0x204 || msg == 0x207) { down = 1; };
        w.mx = x;
        w.my = y;
        w.buttons = w32_buttons(wp);
        if (down == 1) { gcall4(F_SetCapture, w32_hwnd(w), 0, 0, 0); }
        else if (w.buttons == 0) { gcall4(F_ReleaseCapture, 0, 0, 0, 0); };
        push_event(w, EV_BUTTON, x, y, b, down);
    } else if (msg == 0x20a) {                       // WM_MOUSEWHEEL
        let d = w32_signed16(wp >> 16);
        push_event(w, EV_WHEEL, w.mx, w.my, d / 120, 0);
    };
};

def w32_pump(w: Window) -> void {
    let guard = 0;
    while (guard < 1000) {
        WA[0] = ptr_addr(&W32_MSG[0]);
        WA[1] = 0;
        WA[2] = 0;
        WA[3] = 0;
        WA[4] = 1;                                   // PM_REMOVE
        let got = gcall(F_PeekMessageA, 5) & 0xffffffff;
        if (got == 0) { break; };
        gcall4(F_TranslateMessage, ptr_addr(&W32_MSG[0]), 0, 0, 0);
        gcall4(F_DispatchMessageA, ptr_addr(&W32_MSG[0]), 0, 0, 0);
        guard += 1;
    };
    let wr = RING[0];
    if (wr - RING_READ > 256) { RING_READ = wr - 256; };
    while (RING_READ < wr) {
        let at = 8 + (RING_READ % 256) * 4;
        let msg = RING[at + 1];
        if (RING[at] == w32_hwnd(w) || w32_hwnd(w) == 0) { w32_message(w, msg, RING[at + 2], RING[at + 3]); };
        RING_READ += 1;
    };
};

// --------------------------------------------------------------------- X11 ----
// The wire protocol, little endian, over the server's Unix socket. Requests that
// return nothing are sent and forgotten; the few that answer (atoms, the keyboard
// map, GetImage) are read through the same receive buffer, with any event that
// arrives first handled on the way.

let TXB: [byte; 262144] = [0; 262144];
let TXP = 0;

def t8(v: long) -> void { TXB[TXP] = v & 255; TXP += 1; };

def t16(v: long) -> void {
    TXB[TXP] = v & 255;
    TXB[TXP + 1] = (v >> 8) & 255;
    TXP += 2;
};

def t32(v: long) -> void {
    TXB[TXP] = v & 255;
    TXB[TXP + 1] = (v >> 8) & 255;
    TXB[TXP + 2] = (v >> 16) & 255;
    TXB[TXP + 3] = (v >> 24) & 255;
    TXP += 4;
};

def tpad() -> void {
    while (TXP % 4 != 0) { TXB[TXP] = 0; TXP += 1; };
};

def tstr(s: str) -> void {
    let i = 0;
    while (i < len(s)) { TXB[TXP] = s[i]; TXP += 1; i += 1; };
    tpad();
};

def x_send(x: X11Info, n: long) -> bool {
    let off = 0;
    let base = ptr_addr(&TXB[0]);
    while (off < n) {
        let k = os_call("y_os_send", x.fd, base + off, n - off, 16384);
        if (k == -4) { continue; };
        if (k <= 0) { x.down = true; return false; };
        off += k;
    };
    true
};

def r16(p: [byte], o: long) -> long { p[o] | (p[o + 1] << 8) };
def r32(p: [byte], o: long) -> long { p[o] | (p[o + 1] << 8) | (p[o + 2] << 16) | (p[o + 3] << 24) };
def s16(p: [byte], o: long) -> long {
    let v = r16(p, o);
    if (v >= 32768) { v - 65536 } else { v }
};

let XPOLL: [byte; 8] = [0; 8];
const XRX_CAP = 65536;

// true when the socket has bytes (or has hung up) within `ms`; nothing is allocated
def x_readable(fd: long, ms: long) -> bool {
    XPOLL[0] = fd & 255;
    XPOLL[1] = (fd >> 8) & 255;
    XPOLL[2] = (fd >> 16) & 255;
    XPOLL[3] = (fd >> 24) & 255;
    XPOLL[4] = 1;
    os_call("y_os_poll", &XPOLL[0], 1, ms) > 0
};

// Wait up to `ms` for bytes and read them into the receive buffer, in place (the socket is read
// straight into the array: a frame of events costs no allocation). A full buffer is slid to the
// front, or grown when one packet is bigger than all of it (a GetImage reply). False at the end
// of the stream.
def x_more(x: X11Info, ms: long) -> bool {
    if (x.down) { return false; };
    if (x.pos > 0 && x.pos == x.rxn) {
        x.pos = 0;
        x.rxn = 0;
    };
    if (x.rxn >= x.rx.length) {
        if (x.pos > 0) {
            let base = ptr_addr(&x.rx[0]);
            let i = 0;
            while (x.pos + i < x.rxn) {
                let d: *byte = ptr_from(base + i);
                let q: *byte = ptr_from(base + x.pos + i);
                *d = *q;
                i += 1;
            };
            x.rxn -= x.pos;
            x.pos = 0;
        } else {
            x.rx = x.rx + zeros(x.rx.length);
        };
    };
    if (!x_readable(x.fd, ms)) { return true; };
    let n = os_call("y_os_recv", x.fd, ptr_addr(&x.rx[0]) + x.rxn, x.rx.length - x.rxn);
    if (n == -4) { return true; };
    if (n <= 0) {
        x.down = true;
        return false;
    };
    x.rxn += n;
    true
};

// the length of the next whole packet already received (32 bytes; a reply adds its extra
// words), or 0
def x_peek(x: X11Info) -> long {
    let avail = x.rxn - x.pos;
    if (avail < 32) { return 0; };
    let t = x.rx[x.pos];
    let need = 32;
    if (t == 1 || (t & 127) == 35) { need = 32 + 4 * r32(x.rx, x.pos + 4); };
    if (avail < need) { return 0; };
    need
};

// the key code a keysym stands for, in the Windows virtual-key numbers
def x_vk(sym: long) -> long {
    if (sym >= 97 && sym <= 122) { return sym - 32; };
    if (sym >= 32 && sym <= 126) { return sym; };
    if (sym == 0xff08) { return K_BACK; };
    if (sym == 0xff09) { return K_TAB; };
    if (sym == 0xff0d || sym == 0xff8d) { return K_ENTER; };
    if (sym == 0xff1b) { return K_ESC; };
    if (sym >= 0xff50 && sym <= 0xff57) {
        // Home Left Up Right Down Prior Next End
        let m: [long; 8] = [36, 37, 38, 39, 40, 33, 34, 35];
        return m[sym - 0xff50];
    };
    if (sym == 0xff63) { return K_INS; };
    if (sym == 0xffff) { return K_DEL; };
    if (sym >= 0xffbe && sym <= 0xffc9) { return K_F1 + sym - 0xffbe; };
    if (sym == 0xffe1 || sym == 0xffe2) { return K_SHIFT; };
    if (sym == 0xffe3 || sym == 0xffe4) { return K_CTRL; };
    if (sym == 0xffe9 || sym == 0xffea || sym == 0xffe7 || sym == 0xffe8) { return K_ALT; };
    if (sym >= 0xffb0 && sym <= 0xffb9) { return 48 + sym - 0xffb0; };
    0
};

// the text a key press types: a code point, or 0
def x_char(sym: long, mods: long) -> long {
    let c = 0;
    if ((sym >= 32 && sym <= 126) || (sym >= 160 && sym <= 255)) { c = sym; }
    else if (sym >= 0x1000100 && sym <= 0x110ffff) { c = sym - 0x1000000; }
    else if (sym == 0xff08) { c = 8; }
    else if (sym == 0xff09) { c = 9; }
    else if (sym == 0xff0d || sym == 0xff8d) { c = 13; }
    else if (sym == 0xff1b) { c = 27; };
    if ((mods & MOD_CTRL) != 0 && c >= 64 && c <= 126) { c = c & 31; }
    else if ((mods & MOD_CTRL) != 0 && c >= 32 && c < 64 && c != 32) { c = 0; };
    c
};

def x_mods(state: long) -> long {
    let m = 0;
    if ((state & 1) != 0) { m = m | MOD_SHIFT; };
    if ((state & 4) != 0) { m = m | MOD_CTRL; };
    if ((state & 8) != 0) { m = m | MOD_ALT; };
    m
};

def x_buttons(state: long) -> long {
    let b = 0;
    if ((state & 256) != 0) { b = b | BTN_LEFT; };
    if ((state & 512) != 0) { b = b | BTN_MIDDLE; };
    if ((state & 1024) != 0) { b = b | BTN_RIGHT; };
    b
};

def x_keysym(x: X11Info, kc: long, state: long) -> long {
    if (x.kpk <= 0 || kc < x.kmin || kc > x.kmax) { return 0; };
    let base = (kc - x.kmin) * x.kpk;
    let col = 0;
    if ((state & 1) != 0 && x.kpk > 1) { col = 1; };
    let sym = x.syms[base + col];
    // caps lock turns a lower-case letter upper, and shift turns it back
    let plain = x.syms[base];
    if ((state & 2) != 0 && plain >= 97 && plain <= 122) {
        if (col == 0) { sym = plain - 32; } else { sym = plain; };
    };
    if (sym == 0) { sym = plain; };
    sym
};

// the event or error at the front of the receive buffer (32 bytes; the caller moves on)
def x_dispatch(w: Window, xi: X11Info) -> void {
    let p = xi.rx;
    let o = xi.pos;
    let t = p[o] & 127;
    if (t == 2 || t == 3) {
        let kc = p[o + 1];
        let state = r16(p, o + 28);
        w.mods = x_mods(state);
        let sym = x_keysym(xi, kc, state);
        if (t == 3) {
            // an auto-repeat is a release and a press with the same time: swallow the release
            if (xi.rxn - o >= 64 && p[o + 32] == 2 && p[o + 33] == kc && r32(p, o + 36) == r32(p, o + 4)) {
                w.hi = 1;
                return;
            };
            push_event(w, EV_KEY, x_vk(sym), 0, w.mods, 0);
            return;
        };
        let rep = w.hi;
        w.hi = 0;
        push_event(w, EV_KEY, x_vk(sym), 1, w.mods, rep);
        let ch = x_char(sym, w.mods);
        if (ch != 0) { push_event(w, EV_CHAR, ch, 0, w.mods, 0); };
    } else if (t == 4 || t == 5) {
        let b = p[o + 1];
        let ex = s16(p, o + 24);
        let ey = s16(p, o + 26);
        let state = r16(p, o + 28);
        w.mx = ex;
        w.my = ey;
        w.mods = x_mods(state);
        if (b >= 1 && b <= 3) {
            let down = 0;
            if (t == 4) { down = 1; };
            w.buttons = x_buttons(state);
            push_event(w, EV_BUTTON, ex, ey, b, down);     // X: 1 left, 2 middle, 3 right, as ours
        } else if ((b == 4 || b == 5) && t == 4) {
            if (b == 4) { push_event(w, EV_WHEEL, ex, ey, 1, 0); } else { push_event(w, EV_WHEEL, ex, ey, -1, 0); };
        };
    } else if (t == 6) {
        w.mx = s16(p, o + 24);
        w.my = s16(p, o + 26);
        w.buttons = x_buttons(r16(p, o + 28));
        push_event(w, EV_MOVE, w.mx, w.my, w.buttons, 0);
    } else if (t == 9) {
        push_event(w, EV_FOCUS, 1, 0, 0, 0);
    } else if (t == 10) {
        push_event(w, EV_FOCUS, 0, 0, 0, 0);
    } else if (t == 12) {                            // Expose: repaint the rectangle now
        let ex = r16(p, o + 8);
        let ey = r16(p, o + 10);
        let ew = r16(p, o + 12);
        let eh = r16(p, o + 14);
        let more = r16(p, o + 16);
        x_present(w, ex, ey, ex + ew, ey + eh);
        if (more == 0) { push_event(w, EV_EXPOSE, 0, 0, w.width, w.height); };
    } else if (t == 22) {                            // ConfigureNotify
        let nw = r16(p, o + 20);
        let nh = r16(p, o + 22);
        if (nw > 0 && nh > 0 && (nw != w.width || nh != w.height)) { set_size(w, nw, nh); };
    } else if (t == 33) {                            // ClientMessage
        if (r32(p, o + 12) == xi.atom_delete && xi.atom_delete != 0) { push_event(w, EV_CLOSE, 0, 0, 0, 0); };
    } else if (t == 17) {                            // DestroyNotify
        if (w.alive) {
            w.alive = false;
            push_event(w, EV_CLOSE, 0, 0, 0, 0);
        };
    };
};

def x_pump(w: Window) -> void {
    let x = w.x11;
    if (x == none) { return; };
    let xi = x!;
    x_more(xi, 0);
    let n = 0;
    while (n < 4096) {
        let need = x_peek(xi);
        if (need == 0) { break; };
        x_dispatch(w, xi);
        xi.pos += need;
        n += 1;
    };
    if (xi.down && w.alive) {
        w.alive = false;
        push_event(w, EV_CLOSE, 0, 0, 0, 0);
    };
};

// the reply to the last request that answers (a copy), handling events that come first; none
// on an error packet, a closed socket or five seconds of silence
def x_reply(w: Window, xi: X11Info) -> [byte]? {
    let waited = 0;
    while (waited < 5000) {
        let need = x_peek(xi);
        if (need > 0) {
            let t = xi.rx[xi.pos];
            if (t == 1) {
                let r = xi.rx[xi.pos:xi.pos + need];
                xi.pos += need;
                return some(r);
            };
            if (t != 0) { x_dispatch(w, xi); };
            xi.pos += need;
            if (t == 0) { return none; };
            continue;
        };
        if (xi.down) { return none; };
        let t0 = clock_us();
        x_more(xi, 100);
        waited += (clock_us() - t0) / 1000 + 1;
    };
    none
};

def x_atom(w: Window, xi: X11Info, name: str) -> long {
    TXP = 0;
    t8(16);
    t8(0);
    t16(2 + (len(name) + 3) / 4);
    t16(len(name));
    t16(0);
    tstr(name);
    if (!x_send(xi, TXP)) { return 0; };
    let r = x_reply(w, xi);
    if (r == none || r!.length < 12) { return 0; };
    r32(r!, 8)
};

def x_property(xi: X11Info, prop: long, ty: long, fmt: long, data: [byte], n: long) -> void {
    TXP = 0;
    t8(18);
    t8(0);
    t16(6 + (data.length + 3) / 4);
    t32(xi.win);
    t32(prop);
    t32(ty);
    t8(fmt);
    t8(0);
    t16(0);
    t32(n);
    let i = 0;
    while (i < data.length) { TXB[TXP] = data[i]; TXP += 1; i += 1; };
    tpad();
    x_send(xi, TXP);
};

def x_title(w: Window, xi: X11Info, title: str) -> void {
    let b = bytes(title);
    x_property(xi, 39, 31, 8, b, b.length);                    // WM_NAME, STRING
    let nn = x_atom(w, xi, "_NET_WM_NAME");
    let u8 = x_atom(w, xi, "UTF8_STRING");
    if (nn != 0 && u8 != 0) { x_property(xi, nn, u8, 8, b, b.length); };
};

// the Xauthority cookie for display `num`, or empty
def x_cookie(num: long) -> [byte] {
    let none_b: [byte] = [];
    let path = "";
    let e = fs.getenv("XAUTHORITY");
    if (e != none) { path = e!; }
    else {
        let h = fs.getenv("HOME");
        if (h != none) { path = h! + "/.Xauthority"; };
    };
    if (path == "") { return none_b; };
    let f = fs.read_bytes(path);
    if (f == none) { return none_b; };
    let d = f!;
    let want = tostring(num);
    let p = 0;
    while (p + 2 <= d.length) {
        p += 2;                                               // family
        let ok = true;
        let num_s = "";
        let name_s = "";
        let data: [byte] = [];
        let field = 0;
        while (field < 4 && ok) {
            if (p + 2 > d.length) { ok = false; break; };
            let n = (d[p] << 8) | d[p + 1];
            p += 2;
            if (p + n > d.length) { ok = false; break; };
            if (field == 1) { num_s = from_bytes(d[p:p + n]); };
            if (field == 2) { name_s = from_bytes(d[p:p + n]); };
            if (field == 3) { data = d[p:p + n]; };
            p += n;
            field += 1;
        };
        if (!ok) { return none_b; };
        if ((num_s == want || num_s == "") && name_s == "MIT-MAGIC-COOKIE-1") { return data; };
    };
    none_b
};

def x_open(title: str, cw: long, ch: long) -> Window? {
    let disp = fs.getenv("DISPLAY");
    if (disp == none) { return none; };
    let d = disp!;
    let colon = index_of(d, ":");
    if (colon != 0 && !(len(d) > 5 && d[0:5] == "unix:")) { return none; };       // a TCP display
    let rest = d[colon + 1:];
    let num = 0;
    let i = 0;
    while (i < len(rest) && rest[i] >= 48 && rest[i] <= 57) {
        num = num * 10 + (rest[i] - 48);
        i += 1;
    };
    if (i == 0) { return none; };
    let fd = ipc.connect_unix("/tmp/.X11-unix/X" + tostring(num));
    if (fd < 0) { return none; };
    let w = new_window(X11, title, cw, ch);
    let xi: X11Info = {
        fd: fd, win: 0, gc: 0, root: 0, depth: 24, atom_protocols: 0, atom_delete: 0,
        kmin: 8, kmax: 255, kpk: 0, syms: [], rx: zeros(XRX_CAP), rxn: 0, pos: 0, maxreq: 65535, down: false
    };
    // the connection setup, with the cookie when there is one
    let cookie = x_cookie(num);
    let name = "MIT-MAGIC-COOKIE-1";
    TXP = 0;
    t8(108);
    t8(0);
    t16(11);
    t16(0);
    if (cookie.length > 0) { t16(len(name)); t16(cookie.length); } else { t16(0); t16(0); };
    t16(0);
    if (cookie.length > 0) {
        tstr(name);
        let k = 0;
        while (k < cookie.length) { TXB[TXP] = cookie[k]; TXP += 1; k += 1; };
        tpad();
    };
    if (!x_send(xi, TXP)) { ipc.close(fd); return none; };
    // the answer: 8 bytes, then 4 * the length at its end
    let waited = 0;
    while (xi.rxn < 8 && waited < 5000 && !xi.down) {
        x_more(xi, 100);
        waited += 100;
    };
    if (xi.rxn < 8 || xi.rx[0] != 1) { ipc.close(fd); return none; };
    let total = 8 + 4 * r16(xi.rx, 6);
    while (xi.rxn < total && waited < 5000 && !xi.down) {
        x_more(xi, 100);
        waited += 100;
    };
    if (xi.rxn < total) { ipc.close(fd); return none; };
    let s = xi.rx[0:total];
    xi.pos = total;
    if (s[30] != 0) { ipc.close(fd); return none; };         // only little-endian servers
    let base = r32(s, 12);
    let vlen = r16(s, 24);
    xi.maxreq = r16(s, 26);
    let nformats = s[29];
    xi.kmin = s[34];
    xi.kmax = s[35];
    let fo = 40 + vlen;
    while (fo % 4 != 0) { fo += 1; };
    let so = fo + nformats * 8;
    xi.root = r32(s, so);
    let rootvis = r32(s, so + 32);
    xi.depth = s[so + 38];
    let good = false;
    let f = 0;
    while (f < nformats) {
        let o = fo + f * 8;
        if (s[o] == xi.depth && s[o + 1] == 32) { good = true; };
        f += 1;
    };
    if (!good) { ipc.close(fd); return none; };
    xi.win = base | 1;
    xi.gc = base | 2;
    w.x11 = some(xi);
    // CreateWindow
    TXP = 0;
    t8(1);
    t8(0);
    t16(9);
    t32(xi.win);
    t32(xi.root);
    t16(0);
    t16(0);
    t16(cw);
    t16(ch);
    t16(0);
    t16(1);                       // InputOutput
    t32(rootvis);
    t32(0x800);                   // CWEventMask
    t32(1 | 2 | 4 | 8 | 64 | 32768 | 131072 | 2097152);
    if (!x_send(xi, TXP)) { ipc.close(fd); return none; };
    // CreateGC on the window
    TXP = 0;
    t8(55);
    t8(0);
    t16(4);
    t32(xi.gc);
    t32(xi.win);
    t32(0);
    x_send(xi, TXP);
    // WM_PROTOCOLS / WM_DELETE_WINDOW, so the close button is an event, not a dead socket
    xi.atom_protocols = x_atom(w, xi, "WM_PROTOCOLS");
    xi.atom_delete = x_atom(w, xi, "WM_DELETE_WINDOW");
    if (xi.atom_protocols != 0 && xi.atom_delete != 0) {
        let da: [byte] = [];
        da += xi.atom_delete & 255;
        da += (xi.atom_delete >> 8) & 255;
        da += (xi.atom_delete >> 16) & 255;
        da += (xi.atom_delete >> 24) & 255;
        x_property(xi, xi.atom_protocols, 4, 32, da, 1);
    };
    x_title(w, xi, title);
    // the keyboard map
    TXP = 0;
    t8(101);
    t8(0);
    t16(2);
    t8(xi.kmin);
    t8(xi.kmax - xi.kmin + 1);
    t16(0);
    if (x_send(xi, TXP)) {
        let r = x_reply(w, xi);
        if (r != none) {
            xi.kpk = r![1];
            let n = (r!.length - 32) / 4;
            let syms: [long] = [];
            let k = 0;
            while (k < n) { syms += r32(r!, 32 + 4 * k); k += 1; };
            xi.syms = syms;
        };
    };
    // MapWindow
    TXP = 0;
    t8(8);
    t8(0);
    t16(2);
    t32(xi.win);
    x_send(xi, TXP);
    some(w)
};

def x_present(w: Window, x0: long, y0: long, x1: long, y1: long) -> void {
    let x = w.x11;
    if (x == none) { return; };
    let xi = x!;
    let a = x0;
    let b = y0;
    let c = x1;
    let d = y1;
    if (a < 0) { a = 0; };
    if (b < 0) { b = 0; };
    if (c > w.width) { c = w.width; };
    if (d > w.height) { d = w.height; };
    if (a >= c || b >= d) { return; };
    let rw = c - a;
    let room = (xi.maxreq - 6) * 4;
    if (room > 262144 - 24) { room = 262144 - 24; };
    let per = room / (rw * 4);
    if (per < 1) { return; };
    let pix = ptr_addr(&w.pixels[0]);
    let tx = ptr_addr(&TXB[0]);
    let y = b;
    while (y < d) {
        let n = d - y;
        if (n > per) { n = per; };
        // header
        TXP = 0;
        t8(72);
        t8(2);
        t16(6 + rw * n);
        t32(xi.win);
        t32(xi.gc);
        t16(rw);
        t16(n);
        t16(a);
        t16(y);
        t8(0);
        t8(xi.depth);
        t16(0);
        let r = 0;
        while (r < n) {
            let src: *u32 = ptr_from(pix + ((y + r) * w.width + a) * 4);
            let dst: *u32 = ptr_from(tx + 24 + r * rw * 4);
            let k = rw;
            while (k > 0) {
                *dst = *src;
                dst += 1;
                src += 1;
                k -= 1;
            };
            r += 1;
        };
        if (!x_send(xi, 24 + rw * n * 4)) { return; };
        y += n;
    };
};

// the window's contents as the server holds them (GetImage), 4 bytes a pixel
def x_read_back(w: Window) -> [byte]? {
    let x = w.x11;
    if (x == none) { return none; };
    let xi = x!;
    TXP = 0;
    t8(73);
    t8(2);
    t16(5);
    t32(xi.win);
    t16(0);
    t16(0);
    t16(w.width);
    t16(w.height);
    t32(0xffffffff);
    if (!x_send(xi, TXP)) { return none; };
    let r = x_reply(w, xi);
    if (r == none) { return none; };
    let n = w.width * w.height * 4;
    if (r!.length < 32 + n) { return none; };
    some(r![32:32 + n])
};

def w32_read_back(w: Window) -> [byte]? {
    let hdc = w32_hdc(w);
    let mem = gcall4(F_CreateCompatibleDC, hdc, 0, 0, 0);
    if (mem == 0) { return none; };
    let bmp = gcall4(F_CreateCompatibleBitmap, hdc, w.width, w.height, 0);
    let old = gcall4(F_SelectObject, mem, bmp, 0, 0);
    WA[0] = mem;
    WA[1] = 0;
    WA[2] = 0;
    WA[3] = w.width;
    WA[4] = w.height;
    WA[5] = hdc;
    WA[6] = 0;
    WA[7] = 0;
    WA[8] = 0xcc0020;
    gcall(F_BitBlt, 9);
    gcall4(F_SelectObject, mem, old, 0, 0);
    let out = zeros(w.width * w.height * 4);
    WA[0] = mem;
    WA[1] = bmp;
    WA[2] = 0;
    WA[3] = w.height;
    WA[4] = ptr_addr(&out[0]);
    WA[5] = w32_bmi(w, w.height);
    WA[6] = 0;
    let lines = gcall(F_GetDIBits, 7) & 0xffffffff;
    gcall4(F_DeleteObject, bmp, 0, 0, 0);
    gcall4(F_DeleteDC, mem, 0, 0, 0);
    if (lines != w.height) { return none; };
    some(out)
};

// blit a rectangle into a memory bitmap that was cleared to black and compare: what is
// inside must be the buffer's pixels and what is outside must still be black
def w32_check_rect(w: Window, mem: long, bmp: long, x0: long, y0: long, x1: long, y1: long) -> bool {
    let old = gcall4(F_SelectObject, mem, bmp, 0, 0);
    WA[0] = mem;
    WA[1] = 0;
    WA[2] = 0;
    WA[3] = w.width;
    WA[4] = w.height;
    WA[5] = 0;
    WA[6] = 0;
    WA[7] = 0;
    WA[8] = 0x42;                // BLACKNESS
    gcall(F_BitBlt, 9);
    w32_blit(w, mem, x0, y0, x1, y1);
    gcall4(F_SelectObject, mem, old, 0, 0);
    let out = zeros(w.width * w.height * 4);
    WA[0] = mem;
    WA[1] = bmp;
    WA[2] = 0;
    WA[3] = w.height;
    WA[4] = ptr_addr(&out[0]);
    WA[5] = w32_bmi(w, w.height);
    WA[6] = 0;
    let lines = gcall(F_GetDIBits, 7) & 0xffffffff;
    if (lines != w.height) { return false; };
    let a: *u32 = ptr_from(ptr_addr(&out[0]));
    let b: *u32 = ptr_from(ptr_addr(&w.pixels[0]));
    let y = 0;
    while (y < w.height) {
        let x = 0;
        while (x < w.width) {
            let want = 0;
            if (x >= x0 && x < x1 && y >= y0 && y < y1) { want = *b & 0xffffff; };
            if ((*a & 0xffffff) != want) { return false; };
            a += 1;
            b += 1;
            x += 1;
        };
        y += 1;
    };
    true
};

def w32_verify(w: Window) -> bool {
    let hdc = w32_hdc(w);
    let mem = gcall4(F_CreateCompatibleDC, hdc, 0, 0, 0);
    if (mem == 0) { return false; };
    let bmp = gcall4(F_CreateCompatibleBitmap, hdc, w.width, w.height, 0);
    let ok = bmp != 0;
    let cw = w.width;
    let ch = w.height;
    ok = ok && w32_check_rect(w, mem, bmp, 0, 0, cw, ch);
    ok = ok && w32_check_rect(w, mem, bmp, cw / 4, ch / 3, cw / 4 + cw / 2, ch / 3 + ch / 4);
    ok = ok && w32_check_rect(w, mem, bmp, 0, ch - 3, cw, ch);
    ok = ok && w32_check_rect(w, mem, bmp, cw - 5, 0, cw, ch);
    ok = ok && w32_check_rect(w, mem, bmp, 7, 9, 8, 10);
    gcall4(F_DeleteObject, bmp, 0, 0, 0);
    gcall4(F_DeleteDC, mem, 0, 0, 0);
    ok
};

// ------------------------------------------------------------- the front door ----

/** Open a window with a client area of `w` by `h` pixels: a native window on Windows
or under an X server; none when there is no display. */
def open(title: str, w: long, h: long) -> Window? {
    let r = w32_open(title, w, h);
    if (r != none) { return r; };
    x_open(title, w, h)
};

/** A window that is only a buffer: no screen, no events but those `inject` queues. */
def open_headless(w: long, h: long) -> Window {
    new_window(HEADLESS, "headless", w, h)
};

/** Which window system `w` is on: HEADLESS, WIN32 or X11. */
def backend(w: Window) -> long { w.backend };

def backend_name(b: long) -> str {
    if (b == WIN32) { "win32" }
    else if (b == X11) { "x11" }
    else if (b == WAYLAND) { "wayland" }
    else if (b == YOS) { "yos" }
    else { "headless" }
};

/** The client area changed size (the window system's doing, or `resize`'s). */
def set_size(w: Window, nw: long, nh: long) -> void {
    if (nw * nh * 4 > w.pixels.length) { w.pixels = zeros(nw * nh * 4); };
    w.width = nw;
    w.height = nh;
    clear(w, 0);
    push_event(w, EV_RESIZE, nw, nh, 0, 0);
};

/** Show what changed since the last present. */
def present(w: Window) -> void {
    if (w.dx0 >= w.dx1 || w.dy0 >= w.dy1) { return; };
    if (!w.alive) { clean(w); return; };
    if (w.backend == WIN32) { w32_present(w, w.dx0, w.dy0, w.dx1, w.dy1); }
    else if (w.backend == X11) { x_present(w, w.dx0, w.dy0, w.dx1, w.dy1); };
    clean(w);
};

/** Show the whole window. */
def present_all(w: Window) -> void {
    mark(w, 0, 0, w.width, w.height);
    present(w);
};

def pump(w: Window) -> void {
    if (w.backend == WIN32) { w32_pump(w); }
    else if (w.backend == X11) { x_pump(w); };
};

/** The next event into `ev`; false when there is none. Never waits. */
def poll(w: Window, ev: Event) -> bool {
    if (w.evr >= w.evw) { pump(w); };
    if (w.evr >= w.evw) { return false; };
    let at = (w.evr % EVQ) * 5;
    ev.kind = w.evq[at];
    ev.a = w.evq[at + 1];
    ev.b = w.evq[at + 2];
    ev.c = w.evq[at + 3];
    ev.d = w.evq[at + 4];
    w.evr += 1;
    true
};

/** Wait up to `ms` milliseconds for something to happen to the window (input, a
resize); returns at once when an event is already waiting. */
def wait(w: Window, ms: long) -> void {
    if (w.evr < w.evw || !w.alive) { return; };
    if (w.backend == WIN32) {
        WA[0] = 0;
        WA[1] = 0;
        WA[2] = 0;
        WA[3] = ms;
        WA[4] = 0x4ff;               // QS_ALLINPUT
        WA[5] = 0;
        gcall(F_MsgWait, 6);
    } else if (w.backend == X11) {
        let x = w.x11;
        if (x != none) { x_more(x!, ms); };
    };
};

def set_title(w: Window, t: str) -> void {
    w.title = t;
    if (w.backend == WIN32) {
        let b = cstr(t);
        gcall4(F_SetWindowTextA, w32_hwnd(w), ptr_addr(&b[0]), 0, 0);
    } else if (w.backend == X11) {
        let x = w.x11;
        if (x != none) { x_title(w, x!, t); };
    };
};

/** Make each font pixel `s` by `s` screen pixels (an integer, 1 or more). */
def set_scale(w: Window, s: long) -> void {
    if (s < 1) { return; };
    w.scale = s;
};

/** Ask the window system for a client area of `nw` by `nh`; the new size arrives as an
EV_RESIZE (at once for a headless window). */
def resize(w: Window, nw: long, nh: long) -> void {
    if (w.backend == WIN32) {
        W32_RC[0] = 0;
        W32_RC[1] = nw | (nh << 32);
        gcall4(F_AdjustWindowRectEx, ptr_addr(&W32_RC[0]), 0xcf0000, 0, 0);
        let rw = (W32_RC[1] & 0xffffffff) - (W32_RC[0] & 0xffffffff);
        let rh = ((W32_RC[1] >> 32) & 0xffffffff) - ((W32_RC[0] >> 32) & 0xffffffff);
        WA[0] = w32_hwnd(w);
        WA[1] = 0;
        WA[2] = 0;
        WA[3] = 0;
        WA[4] = rw;
        WA[5] = rh;
        WA[6] = 6;                   // SWP_NOMOVE | SWP_NOZORDER
        gcall(F_SetWindowPos, 7);
    } else if (w.backend == X11) {
        let x = w.x11;
        if (x != none) {
            TXP = 0;
            t8(12);
            t8(0);
            t16(5);
            t32(x!.win);
            t16(12);                 // width | height
            t16(0);
            t32(nw);
            t32(nh);
            x_send(x!, TXP);
        };
    } else {
        set_size(w, nw, nh);
    };
};

/** The window's contents as the screen holds them, 4 bytes a pixel, or none when it
cannot be read (a covered window, a system that will not say). A headless window
answers with a copy of its own pixels. */
def read_back(w: Window) -> [byte]? {
    if (w.backend == WIN32) { return w32_read_back(w); };
    if (w.backend == X11) { return x_read_back(w); };
    some(w.pixels[0:w.width * w.height * 4])
};

/** Does what `present` sends reach the screen intact? On Windows: whole and partial
rectangles of the pixel buffer are blitted into a memory bitmap and read back (not the
window's own surface, which a session with no visible desktop does not keep); under X:
the window is presented and the server's copy compared; headless: true. */
def verify_present(w: Window) -> bool {
    if (w.backend == WIN32) { return w32_verify(w); };
    if (w.backend == X11) {
        present_all(w);
        let rb = x_read_back(w);
        if (rb == none) { return false; };
        return checksum_of(rb!, w.width * w.height) == checksum(w);
    };
    true
};

/** Close the window; `alive` is false after. */
def close(w: Window) -> void {
    if (w.backend == WIN32) {
        let i = w.win32;
        if (i != none && w.alive) {
            w.alive = false;
            gcall4(F_ReleaseDC, i!.hwnd, i!.hdc, 0, 0);
            gcall4(F_DestroyWindow, i!.hwnd, 0, 0, 0);
        };
        w32_pump(w);
    } else if (w.backend == X11) {
        let x = w.x11;
        if (x != none && !x!.down) {
            TXP = 0;
            t8(4);
            t8(0);
            t16(2);
            t32(x!.win);
            x_send(x!, TXP);
            ipc.close(x!.fd);
            x!.down = true;
        };
    };
    w.alive = false;
};

// ------------------------------------------------------------------ platform ----

/** True when the process is a Windows one (the Win32 half of the OS layer is there). */
def on_windows() -> bool {
    w32_init()
};

/** Send the process's standard error to the file `path` (created, emptied): what a
program with no console, a GUI one, does to keep a trap's message. False on failure. */
def redirect_stderr(path: str) -> bool {
    if (w32_init()) {
        let k = gsym("kernel32.dll", "CreateFileA");
        let ss = gsym("kernel32.dll", "SetStdHandle");
        if (k == 0 || ss == 0) { return false; };
        let p = cstr(path);
        FN[30] = k;
        WA[0] = ptr_addr(&p[0]);
        WA[1] = 0x40000000;                  // GENERIC_WRITE
        WA[2] = 3;                           // FILE_SHARE_READ | FILE_SHARE_WRITE
        WA[3] = 0;
        WA[4] = 2;                           // CREATE_ALWAYS
        WA[5] = 0x80;                        // FILE_ATTRIBUTE_NORMAL
        WA[6] = 0;
        let h = gcall(30, 7);
        if (h == 0 || h == -1) { return false; };
        FN[30] = ss;
        WA[0] = -12;                         // STD_ERROR_HANDLE
        WA[1] = h;
        gcall(30, 4);
        return true;
    };
    let fd = fs.open_file(path, "w");
    if (fd < 0) { return false; };
    os_call("y_os_dup2", fd, 2);
    os_call("y_os_close", fd);
    true
};

/** Save the window's pixels as a binary PPM (P6) file: what a frame looks like, for a person. */
def write_ppm(w: Window, path: str) -> bool {
    let n = w.width * w.height;
    let o: [byte] = bytes("P6\n" + tostring(w.width) + " " + tostring(w.height) + "\n255\n");
    let i = 0;
    while (i < n) {
        o += w.pixels[i * 4 + 2];
        o += w.pixels[i * 4 + 1];
        o += w.pixels[i * 4];
        i += 1;
    };
    fs.write_bytes(path, o)
};
