// gfx -- a small 2D library for the GUI: pixel surfaces in plain memory, alpha blending and
// anti-aliased shapes (circle, ring, rounded rectangle, capsule line, convex polygon, glyphs).
//
// A surface is a w x h run of 32-bit pixels (0x00RRGGBB on the screen; 0xAARRGGBB in an icon, the
// alpha straight, not premultiplied) at an address from mmap, so the pixel loops are loads and
// stores through `*u32` and nothing here allocates. Shapes take their geometry in 1/16 pixel
// (`f(v)` turns pixels into that) and are rasterised with 4x4 sub-samples per pixel: exact
// integer tests, no square roots and no floats, 17 levels of coverage. Everything honours the
// clip rectangle (`clip_set`), which is how the GUI redraws only what changed.
import font from "../kernel/font.y";

type Surf = { p: long, w: long, h: long };

/** Decode the font (call once before drawing any text). */
def init() -> void { font.font_init(); };

let clip_x0 = 0;
let clip_y0 = 0;
let clip_x1 = 0;
let clip_y1 = 0;

/** Pixels to the 1/16 pixel units of the shape functions. */
def f(v: long) -> long { v * 16 };

/** Bytes mmap'd through alloc and not yet released: the pixel memory this process holds. */
let mapped = 0;

/** `n` bytes of zeroed memory (mmap), or 0. */
def alloc(n: long) -> long {
    let a = syscall(9, 0, n, 3, 34, -1, 0);
    if (a < 0 && a > -4096) { 0 } else {
        mapped = mapped + n;
        a
    }
};

def release(a: long, n: long) -> void {
    if (a != 0) {
        syscall(11, a, n, 0);
        mapped = mapped - n;
    };
};

def surf_new(w: long, h: long) -> Surf {
    let s: Surf = { p: alloc(w * h * 4), w: w, h: h };
    s
};

def surf_free(s: Surf) -> void {
    release(s.p, s.w * s.h * 4);
};

def get(s: Surf, x: long, y: long) -> long {
    let q: *u32 = ptr_from(s.p + (y * s.w + x) * 4);
    *q
};

def put(s: Surf, x: long, y: long, c: long) -> void {
    let q: *u32 = ptr_from(s.p + (y * s.w + x) * 4);
    *q = c;
};

def clip_set(x0: long, y0: long, x1: long, y1: long) -> void {
    clip_x0 = x0;
    clip_y0 = y0;
    clip_x1 = x1;
    clip_y1 = y1;
};

def clip_to(s: Surf) -> void { clip_set(0, 0, s.w, s.h); };

def abs(v: long) -> long { if (v < 0) { 0 - v } else { v } };

def min(a: long, b: long) -> long { if (a < b) { a } else { b } };
def max(a: long, b: long) -> long { if (a > b) { a } else { b } };
def clamp(v: long, lo: long, hi: long) -> long {
    if (v < lo) { return lo; };
    if (v > hi) { return hi; };
    v
};

def rgb(r: long, g: long, b: long) -> long { (clamp(r, 0, 255) << 16) | (clamp(g, 0, 255) << 8) | clamp(b, 0, 255) };
def argb(a: long, r: long, g: long, b: long) -> long { (clamp(a, 0, 255) << 24) | (clamp(r, 0, 255) << 16) | (clamp(g, 0, 255) << 8) | clamp(b, 0, 255) };

/** `src` (0xAARRGGBB, straight alpha) over the opaque `dst` (0x00RRGGBB), with `cover` (0..255) more transparency. */
def over(dst: long, src: long, cover: long) -> long {
    let a = ((src >>> 24) & 255) * cover / 255;
    if (a == 0) { return dst; };
    if (a >= 255) { return src & 16777215; };
    let ia = 255 - a;
    let r = (((src >> 16) & 255) * a + ((dst >> 16) & 255) * ia) / 255;
    let g = (((src >> 8) & 255) * a + ((dst >> 8) & 255) * ia) / 255;
    let b = ((src & 255) * a + (dst & 255) * ia) / 255;
    (r << 16) | (g << 8) | b
};

/** `src` over the translucent `dst` (both 0xAARRGGBB): what an icon being built needs. */
def over_argb(dst: long, src: long, cover: long) -> long {
    let sa = ((src >>> 24) & 255) * cover / 255;
    if (sa == 0) { return dst; };
    let da = (dst >>> 24) & 255;
    if (sa >= 255 || da == 0) { return (sa << 24) | (src & 16777215); };
    let oa = sa + da * (255 - sa) / 255;
    let r = (((src >> 16) & 255) * sa * 255 + ((dst >> 16) & 255) * da * (255 - sa)) / (oa * 255);
    let g = (((src >> 8) & 255) * sa * 255 + ((dst >> 8) & 255) * da * (255 - sa)) / (oa * 255);
    let b = ((src & 255) * sa * 255 + (dst & 255) * da * (255 - sa)) / (oa * 255);
    (oa << 24) | (clamp(r, 0, 255) << 16) | (clamp(g, 0, 255) << 8) | clamp(b, 0, 255)
};

/** How a shape lands on a pixel: onto a screen surface (alpha > 0 blends) or onto an icon. */
let target_argb = false;

def plot(s: Surf, x: long, y: long, c: long, cover: long) -> void {
    if (cover <= 0) { return; };
    let q: *u32 = ptr_from(s.p + (y * s.w + x) * 4);
    if (target_argb) { *q = over_argb(*q, c, cover); } else { *q = over(*q, c, cover); };
};

def fill(s: Surf, c: long) -> void {
    let q: *u32 = ptr_from(s.p);
    let n = s.w * s.h;
    let i = 0;
    while (i < n) {
        *(q + i) = c;
        i = i + 1;
    };
};

/** A filled rectangle of pixels (no anti-aliasing), blended by c's alpha. */
def rect(s: Surf, x0: long, y0: long, x1: long, y1: long, c: long) -> void {
    let a = max(x0, clip_x0);
    let b = max(y0, clip_y0);
    let e = min(x1, min(clip_x1, s.w));
    let g = min(y1, min(clip_y1, s.h));
    let y = b;
    while (y < g) {
        let x = a;
        while (x < e) {
            plot(s, x, y, c, 255);
            x = x + 1;
        };
        y = y + 1;
    };
};

/** Copy the rectangle [x0, x1) x [y0, y1) of `src` onto `dst` at the same place (clipped). */
def copy_rect(dst: Surf, src: Surf, x0: long, y0: long, x1: long, y1: long) -> void {
    let a = max(x0, max(clip_x0, 0));
    let b = max(y0, max(clip_y0, 0));
    let e = min(x1, min(clip_x1, min(dst.w, src.w)));
    let g = min(y1, min(clip_y1, min(dst.h, src.h)));
    let y = b;
    while (y < g) {
        let d: *long = ptr_from(dst.p + (y * dst.w + a) * 4);
        let s: *long = ptr_from(src.p + (y * src.w + a) * 4);
        let n = e - a;
        let i = 0;
        while (i + 1 < n) {
            *(d + i / 2) = *(s + i / 2);
            i = i + 2;
        };
        if (i < n) {
            let dd: *u32 = ptr_from(dst.p + (y * dst.w + a + i) * 4);
            let ss: *u32 = ptr_from(src.p + (y * src.w + a + i) * 4);
            *dd = *ss;
        };
        y = y + 1;
    };
};

/** A solid rounded rectangle [x0, x1) x [y0, y1) with corner radius r: whole pixels, no anti-aliasing, a few
stores per row (the dock's plate). */
def fill_round(s: Surf, x0: long, y0: long, x1: long, y1: long, r: long, c: long) -> void {
    let y = max(y0, max(clip_y0, 0));
    let ye = min(y1, min(clip_y1, s.h));
    while (y < ye) {
        let inset = 0;
        let d = if (y - y0 < r) { y - y0 } else if (y1 - 1 - y < r) { y1 - 1 - y } else { r };
        if (d < r) {
            let dy2 = 2 * (r - d) - 1;
            while (inset < r && (2 * (r - inset) - 1) * (2 * (r - inset) - 1) + dy2 * dy2 > 4 * r * r) { inset = inset + 1; };
        };
        let xa = max(x0 + inset, max(clip_x0, 0));
        let xe = min(x1 - inset, min(clip_x1, s.w));
        let q: *u32 = ptr_from(s.p + (y * s.w + xa) * 4);
        let n = xe - xa;
        let i = 0;
        while (i < n) {
            *(q + i) = c;
            i = i + 1;
        };
        y = y + 1;
    };
};

/** Copy all of `src` (opaque) onto `dst` with its top-left at (x, y), clipped. */
def copy_to(dst: Surf, src: Surf, x: long, y: long) -> void {
    let a = max(x, max(clip_x0, 0));
    let b = max(y, max(clip_y0, 0));
    let e = min(x + src.w, min(clip_x1, dst.w));
    let g = min(y + src.h, min(clip_y1, dst.h));
    let py = b;
    while (py < g) {
        let d: *u32 = ptr_from(dst.p + (py * dst.w + a) * 4);
        let q: *u32 = ptr_from(src.p + ((py - y) * src.w + (a - x)) * 4);
        let n = e - a;
        let i = 0;
        while (i < n) {
            *(d + i) = *(q + i);
            i = i + 1;
        };
        py = py + 1;
    };
};

/** The pixel box a shape can touch: [x0, x1) x [y0, y1), clipped, from geometry in 1/16 px. */
def box_x0(v: long, s: Surf) -> long { max(max(v / 16, 0), clip_x0) };
def box_y0(v: long, s: Surf) -> long { max(max(v / 16, 0), clip_y0) };
def box_x1(v: long, s: Surf) -> long { min(min(v / 16 + 1, s.w), clip_x1) };
def box_y1(v: long, s: Surf) -> long { min(min(v / 16 + 1, s.h), clip_y1) };

/** A disc centred (cx, cy) of radius r. */
def disc(s: Surf, cx: long, cy: long, r: long, c: long) -> void {
    let r2 = r * r;
    let y = box_y0(cy - r, s);
    let ye = box_y1(cy + r, s);
    let xs = box_x0(cx - r, s);
    let xe = box_x1(cx + r, s);
    while (y < ye) {
        let x = xs;
        while (x < xe) {
            let n = 0;
            let sy = 0;
            while (sy < 4) {
                let dy = y * 16 + 2 + sy * 4 - cy;
                let sx = 0;
                while (sx < 4) {
                    let dx = x * 16 + 2 + sx * 4 - cx;
                    if (dx * dx + dy * dy <= r2) { n = n + 1; };
                    sx = sx + 1;
                };
                sy = sy + 1;
            };
            plot(s, x, y, c, n * 255 / 16);
            x = x + 1;
        };
        y = y + 1;
    };
};

/** A ring: radius `r` out, `ri` in. */
def ring(s: Surf, cx: long, cy: long, r: long, ri: long, c: long) -> void {
    let r2 = r * r;
    let i2 = ri * ri;
    let y = box_y0(cy - r, s);
    let ye = box_y1(cy + r, s);
    let xs = box_x0(cx - r, s);
    let xe = box_x1(cx + r, s);
    while (y < ye) {
        let x = xs;
        while (x < xe) {
            let n = 0;
            let sy = 0;
            while (sy < 4) {
                let dy = y * 16 + 2 + sy * 4 - cy;
                let sx = 0;
                while (sx < 4) {
                    let dx = x * 16 + 2 + sx * 4 - cx;
                    let d = dx * dx + dy * dy;
                    if (d <= r2 && d >= i2) { n = n + 1; };
                    sx = sx + 1;
                };
                sy = sy + 1;
            };
            plot(s, x, y, c, n * 255 / 16);
            x = x + 1;
        };
        y = y + 1;
    };
};

/** An axis-aligned ellipse. */
def ellipse(s: Surf, cx: long, cy: long, rx: long, ry: long, c: long) -> void {
    let y = box_y0(cy - ry, s);
    let ye = box_y1(cy + ry, s);
    let xs = box_x0(cx - rx, s);
    let xe = box_x1(cx + rx, s);
    let rx2 = rx * rx;
    let ry2 = ry * ry;
    while (y < ye) {
        let x = xs;
        while (x < xe) {
            let n = 0;
            let sy = 0;
            while (sy < 4) {
                let dy = y * 16 + 2 + sy * 4 - cy;
                let sx = 0;
                while (sx < 4) {
                    let dx = x * 16 + 2 + sx * 4 - cx;
                    if (dx * dx * ry2 + dy * dy * rx2 <= rx2 * ry2) { n = n + 1; };
                    sx = sx + 1;
                };
                sy = sy + 1;
            };
            plot(s, x, y, c, n * 255 / 16);
            x = x + 1;
        };
        y = y + 1;
    };
};

/** Does the point (px, py) lie in the rounded rectangle [x0, x1] x [y0, y1] with corner radius r? */
def in_rrect(px: long, py: long, x0: long, y0: long, x1: long, y1: long, r: long) -> bool {
    if (px < x0 || px > x1 || py < y0 || py > y1) { return false; };
    let cx = clamp(px, x0 + r, x1 - r);
    let cy = clamp(py, y0 + r, y1 - r);
    let dx = px - cx;
    let dy = py - cy;
    dx * dx + dy * dy <= r * r
};

/** A rounded rectangle, `top` at its top edge fading to `bot` at the bottom (the same colour for a flat fill). */
def rrect(s: Surf, x0: long, y0: long, x1: long, y1: long, r: long, top: long, bot: long) -> void {
    let y = box_y0(y0, s);
    let ye = box_y1(y1, s);
    let xs = box_x0(x0, s);
    let xe = box_x1(x1, s);
    let hh = max(y1 - y0, 1);
    while (y < ye) {
        let t = clamp((y * 16 + 8 - y0) * 255 / hh, 0, 255);
        let c = lerp_argb(top, bot, t);
        let x = xs;
        while (x < xe) {
            let n = 0;
            let sy = 0;
            while (sy < 4) {
                let py = y * 16 + 2 + sy * 4;
                let sx = 0;
                while (sx < 4) {
                    if (in_rrect(x * 16 + 2 + sx * 4, py, x0, y0, x1, y1, r)) { n = n + 1; };
                    sx = sx + 1;
                };
                sy = sy + 1;
            };
            plot(s, x, y, c, n * 255 / 16);
            x = x + 1;
        };
        y = y + 1;
    };
};

/** The outline of a rounded rectangle, `w` thick (inside). */
def rrect_line(s: Surf, x0: long, y0: long, x1: long, y1: long, r: long, w: long, c: long) -> void {
    let y = box_y0(y0, s);
    let ye = box_y1(y1, s);
    let xs = box_x0(x0, s);
    let xe = box_x1(x1, s);
    let ri = max(r - w, 0);
    while (y < ye) {
        let x = xs;
        while (x < xe) {
            let n = 0;
            let sy = 0;
            while (sy < 4) {
                let py = y * 16 + 2 + sy * 4;
                let sx = 0;
                while (sx < 4) {
                    let px = x * 16 + 2 + sx * 4;
                    if (in_rrect(px, py, x0, y0, x1, y1, r) && !in_rrect(px, py, x0 + w, y0 + w, x1 - w, y1 - w, ri)) { n = n + 1; };
                    sx = sx + 1;
                };
                sy = sy + 1;
            };
            plot(s, x, y, c, n * 255 / 16);
            x = x + 1;
        };
        y = y + 1;
    };
};

/** A line segment of width `w` with round ends (a capsule). */
def line(s: Surf, x0: long, y0: long, x1: long, y1: long, w: long, c: long) -> void {
    let hw = w / 2;
    let r2 = hw * hw;
    let y = box_y0(min(y0, y1) - hw, s);
    let ye = box_y1(max(y0, y1) + hw, s);
    let xs = box_x0(min(x0, x1) - hw, s);
    let xe = box_x1(max(x0, x1) + hw, s);
    let vx = x1 - x0;
    let vy = y1 - y0;
    let len2 = vx * vx + vy * vy;
    while (y < ye) {
        let x = xs;
        while (x < xe) {
            let n = 0;
            let sy = 0;
            while (sy < 4) {
                let py = y * 16 + 2 + sy * 4;
                let sx = 0;
                while (sx < 4) {
                    let px = x * 16 + 2 + sx * 4;
                    let dx = px - x0;
                    let dy = py - y0;
                    let qx = 0;
                    let qy = 0;
                    if (len2 == 0) {
                        qx = dx;
                        qy = dy;
                    } else {
                        let t = dx * vx + dy * vy;
                        if (t <= 0) { qx = dx; qy = dy; }
                        else if (t >= len2) { qx = px - x1; qy = py - y1; }
                        else {
                            qx = dx - vx * t / len2;
                            qy = dy - vy * t / len2;
                        };
                    };
                    if (qx * qx + qy * qy <= r2) { n = n + 1; };
                    sx = sx + 1;
                };
                sy = sy + 1;
            };
            plot(s, x, y, c, n * 255 / 16);
            x = x + 1;
        };
        y = y + 1;
    };
};

/** A convex polygon (vertices xs[i], ys[i], either winding). */
def poly(s: Surf, xs: [long], ys: [long], c: long) -> void {
    let n = len(xs);
    let lox = xs[0];
    let hix = xs[0];
    let loy = ys[0];
    let hiy = ys[0];
    let i = 1;
    while (i < n) {
        lox = min(lox, xs[i]);
        hix = max(hix, xs[i]);
        loy = min(loy, ys[i]);
        hiy = max(hiy, ys[i]);
        i = i + 1;
    };
    let y = box_y0(loy, s);
    let ye = box_y1(hiy, s);
    let xa = box_x0(lox, s);
    let xe = box_x1(hix, s);
    while (y < ye) {
        let x = xa;
        while (x < xe) {
            let cnt = 0;
            let sy = 0;
            while (sy < 4) {
                let py = y * 16 + 2 + sy * 4;
                let sx = 0;
                while (sx < 4) {
                    let px = x * 16 + 2 + sx * 4;
                    let pos = 0;
                    let neg = 0;
                    let k = 0;
                    while (k < n) {
                        let k2 = k + 1;
                        if (k2 == n) { k2 = 0; };
                        let e = (xs[k2] - xs[k]) * (py - ys[k]) - (ys[k2] - ys[k]) * (px - xs[k]);
                        if (e > 0) { pos = pos + 1; } else if (e < 0) { neg = neg + 1; };
                        k = k + 1;
                    };
                    if (pos == 0 || neg == 0) { cnt = cnt + 1; };
                    sx = sx + 1;
                };
                sy = sy + 1;
            };
            plot(s, x, y, c, cnt * 255 / 16);
            x = x + 1;
        };
        y = y + 1;
    };
};

/** A triangle. */
def tri(s: Surf, x0: long, y0: long, x1: long, y1: long, x2: long, y2: long, c: long) -> void {
    poly(s, [x0, x1, x2], [y0, y1, y2], c);
};

/** A quadrilateral. */
def quad(s: Surf, x0: long, y0: long, x1: long, y1: long, x2: long, y2: long, x3: long, y3: long, c: long) -> void {
    poly(s, [x0, x1, x2, x3], [y0, y1, y2, y3], c);
};

/** Blend two 0xAARRGGBB colours, `t` (0..255) of the way from a to b. */
def lerp_argb(a: long, b: long, t: long) -> long {
    let it = 255 - t;
    let aa = (((a >>> 24) & 255) * it + ((b >>> 24) & 255) * t) / 255;
    let r = (((a >> 16) & 255) * it + ((b >> 16) & 255) * t) / 255;
    let g = (((a >> 8) & 255) * it + ((b >> 8) & 255) * t) / 255;
    let bl = ((a & 255) * it + (b & 255) * t) / 255;
    (aa << 24) | (r << 16) | (g << 8) | bl
};

/** Draw glyph `cp` of the 8x16 console font at pixel (x, y), each font pixel `sc` x `sc` screen pixels. */
def glyph(s: Surf, x: long, y: long, cp: long, sc: long, c: long) -> void {
    let slot = font.font_slot(cp);
    let row = 0;
    while (row < 16) {
        let bits = font.font_row(slot, row);
        let col = 0;
        while (col < 8) {
            if ((bits & (128 >> col)) != 0) { rect(s, x + col * sc, y + row * sc, x + col * sc + sc, y + row * sc + sc, c); };
            col = col + 1;
        };
        row = row + 1;
    };
};

/** The width in pixels of `text` at scale `sc`. */
def text_width(text: str, sc: long) -> long { len(text) * 8 * sc };

/** Draw `text` (ASCII/Latin-1) at (x, y) at scale `sc`. */
def text(s: Surf, x: long, y: long, t: str, sc: long, c: long) -> void {
    if (y >= clip_y1 || y + 16 * sc <= clip_y0 || x >= clip_x1 || x + len(t) * 8 * sc <= clip_x0) { return; };
    let i = 0;
    while (i < len(t)) {
        let gx = x + i * 8 * sc;
        if (gx < clip_x1 && gx + 8 * sc > clip_x0) { glyph(s, gx, y, t[i], sc, c); };
        i = i + 1;
    };
};

/** Like lerp_argb but weighting each colour by its alpha, so a transparent pixel's colour does not tint the edge. */
def lerp_wa(a: long, b: long, t: long) -> long {
    let wa = ((a >>> 24) & 255) * (255 - t);
    let wb = ((b >>> 24) & 255) * t;
    let sum = wa + wb;
    if (sum == 0) { return 0; };
    let r = (((a >> 16) & 255) * wa + ((b >> 16) & 255) * wb) / sum;
    let g = (((a >> 8) & 255) * wa + ((b >> 8) & 255) * wb) / sum;
    let bl = ((a & 255) * wa + (b & 255) * wb) / sum;
    ((sum / 255) << 24) | (r << 16) | (g << 8) | bl
};

/** Draw the surface `src` (an icon, 0xAARRGGBB) with its top-left at (x, y) scaled to `size` x `size` pixels (bilinear). */
def blit_scaled(dst: Surf, src: Surf, x: long, y: long, size: long) -> void {
    let y0 = max(y, max(clip_y0, 0));
    let y1 = min(y + size, min(clip_y1, dst.h));
    let x0 = max(x, max(clip_x0, 0));
    let x1 = min(x + size, min(clip_x1, dst.w));
    let py = y0;
    while (py < y1) {
        let fy = ((py - y) * 2 + 1) * src.h * 128 / size - 128;
        let sy0 = clamp(fy >> 8, 0, src.h - 1);
        let sy1 = min(sy0 + 1, src.h - 1);
        let wy = clamp(fy & 255, 0, 255);
        if (fy < 0) { wy = 0; };
        let px = x0;
        while (px < x1) {
            let fx = ((px - x) * 2 + 1) * src.w * 128 / size - 128;
            let sx0 = clamp(fx >> 8, 0, src.w - 1);
            let sx1 = min(sx0 + 1, src.w - 1);
            let wx = clamp(fx & 255, 0, 255);
            if (fx < 0) { wx = 0; };
            let a = lerp_wa(get(src, sx0, sy0), get(src, sx1, sy0), wx);
            let b = lerp_wa(get(src, sx0, sy1), get(src, sx1, sy1), wx);
            let c = lerp_wa(a, b, wy);
            let q: *u32 = ptr_from(dst.p + (py * dst.w + px) * 4);
            *q = over(*q, c, 255);
            px = px + 1;
        };
        py = py + 1;
    };
};
