// icons -- the dock's icons, drawn from shapes and lines at start-up (no image files).
//
// `icon_draw(name, s)` paints the app `name` on the 96 x 96 surface `s` (0xAARRGGBB, transparent
// where nothing is drawn): a rounded tile with a gradient and a gloss, then the app's glyph.
// An app with no drawing of its own gets a tile whose hue comes from its name and its first
// letter, so a program added to /bin shows up in the dock looking like it belongs.
import gfx;

const IS = 96;

/** Integer sine, `a` in degrees: -256..256 (a parabola, good to a few percent -- plenty for an icon). */
def isin(a: long) -> long {
    let d = a % 360;
    if (d < 0) { d = d + 360; };
    let x = d % 180;
    let v = 4 * x * (180 - x) * 256 / 32400;
    if (d >= 180) { 0 - v } else { v }
};

def icos(a: long) -> long { isin(a + 90) };

// pixel-unit shorthands for the shape calls
def ln(s: gfx.Surf, x0: long, y0: long, x1: long, y1: long, w: long, c: long) -> void {
    gfx.line(s, gfx.f(x0), gfx.f(y0), gfx.f(x1), gfx.f(y1), gfx.f(w), c);
};

def dc(s: gfx.Surf, cx: long, cy: long, r: long, c: long) -> void {
    gfx.disc(s, gfx.f(cx), gfx.f(cy), gfx.f(r), c);
};

def rg(s: gfx.Surf, cx: long, cy: long, r: long, ri: long, c: long) -> void {
    gfx.ring(s, gfx.f(cx), gfx.f(cy), gfx.f(r), gfx.f(ri), c);
};

def rr(s: gfx.Surf, x0: long, y0: long, x1: long, y1: long, r: long, c: long) -> void {
    gfx.rrect(s, gfx.f(x0), gfx.f(y0), gfx.f(x1), gfx.f(y1), gfx.f(r), c, c);
};

def el(s: gfx.Surf, cx: long, cy: long, rx: long, ry: long, c: long) -> void {
    gfx.ellipse(s, gfx.f(cx), gfx.f(cy), gfx.f(rx), gfx.f(ry), c);
};

def tr(s: gfx.Surf, x0: long, y0: long, x1: long, y1: long, x2: long, y2: long, c: long) -> void {
    gfx.tri(s, gfx.f(x0), gfx.f(y0), gfx.f(x1), gfx.f(y1), gfx.f(x2), gfx.f(y2), c);
};

def qd(s: gfx.Surf, x0: long, y0: long, x1: long, y1: long, x2: long, y2: long, x3: long, y3: long, c: long) -> void {
    gfx.quad(s, gfx.f(x0), gfx.f(y0), gfx.f(x1), gfx.f(y1), gfx.f(x2), gfx.f(y2), gfx.f(x3), gfx.f(y3), c);
};

/** The tile every icon sits on. */
def tile(s: gfx.Surf, top: long, bot: long) -> void {
    gfx.rrect(s, gfx.f(3), gfx.f(5), gfx.f(93), gfx.f(95), gfx.f(21), 0x30000000, 0x50000000);
    gfx.rrect(s, gfx.f(2), gfx.f(2), gfx.f(94), gfx.f(94), gfx.f(21), top, bot);
    gfx.rrect(s, gfx.f(2), gfx.f(2), gfx.f(94), gfx.f(94), gfx.f(21), 0x40FFFFFF, 0x00FFFFFF);
    gfx.rrect_line(s, gfx.f(2), gfx.f(2), gfx.f(94), gfx.f(94), gfx.f(21), gfx.f(1), 0x38000000);
};

/** A branch of a tree: a line, and two shorter ones off its end. */
def branch(s: gfx.Surf, x: long, y: long, ang: long, l: long, depth: long, c: long) -> void {
    let x1 = x + icos(ang) * l / 256;
    let y1 = y - isin(ang) * l / 256;
    ln(s, x, y, x1, y1, 1 + depth, c);
    if (depth > 0) {
        self(s, x1, y1, ang + 28, l * 7 / 10, depth - 1, c);
        self(s, x1, y1, ang - 28, l * 7 / 10, depth - 1, c);
    };
};

/** A sine wave across the tile, as a chain of short lines. */
def wave(s: gfx.Surf, y: long, amp: long, phase: long, w: long, c: long) -> void {
    let x = 14;
    let py = y - isin(phase) * amp / 256;
    while (x < 82) {
        let nx = x + 4;
        let ny = y - isin(phase + (nx - 14) * 6) * amp / 256;
        ln(s, x, py, nx, ny, w, c);
        x = nx;
        py = ny;
    };
};

def hsv(h: long, sat: long, v: long) -> long {
    let hh = h % 360;
    let region = hh / 60;
    let rem = (hh % 60) * 255 / 60;
    let p = v * (255 - sat) / 255;
    let q = v * (255 - sat * rem / 255) / 255;
    let t = v * (255 - sat * (255 - rem) / 255) / 255;
    if (region == 0) { return gfx.argb(255, v, t, p); };
    if (region == 1) { return gfx.argb(255, q, v, p); };
    if (region == 2) { return gfx.argb(255, p, v, t); };
    if (region == 3) { return gfx.argb(255, p, q, v); };
    if (region == 4) { return gfx.argb(255, t, p, v); };
    gfx.argb(255, v, p, q)
};

def name_hash(name: str) -> long {
    let h = 5381;
    let i = 0;
    while (i < len(name)) {
        h = (h * 33 + name[i]) & 1048575;
        i = i + 1;
    };
    h
};

/** The generated icon: a hue from the name, the name's first letter. */
def generic(s: gfx.Surf, name: str) -> void {
    let h = name_hash(name) % 360;
    tile(s, hsv(h, 150, 235), hsv(h + 24, 220, 150));
    let c = 65;
    if (len(name) > 0) { c = name[0]; };
    if (c >= 97 && c <= 122) { c = c - 32; };
    gfx.glyph(s, 32, 14, c, 4, 0xF2FFFFFF);
};

/** Paint the icon for app `name` on `s` (96 x 96, cleared). */
def icon_draw(name: str, s: gfx.Surf) -> void {
    gfx.target_argb = true;
    gfx.clip_to(s);
    if (name == "terminal") {
        tile(s, 0xFF3A404A, 0xFF16181D);
        ln(s, 26, 34, 44, 48, 6, 0xFF7EE787);
        ln(s, 44, 48, 26, 62, 6, 0xFF7EE787);
        ln(s, 50, 64, 72, 64, 6, 0xFFE6EDF3);
    } else if (name == "files") {
        tile(s, 0xFF60A5FA, 0xFF1E3A8A);
        rr(s, 16, 28, 44, 40, 4, 0xFFFCD34D);
        rr(s, 16, 34, 80, 74, 6, 0xFFFBBF24);
        rr(s, 16, 40, 80, 74, 6, 0xFFFDE68A);
        ln(s, 26, 56, 70, 56, 3, 0x60B45309);
        ln(s, 26, 64, 58, 64, 3, 0x60B45309);
    } else if (name == "donut") {
        tile(s, 0xFFFF9EB5, 0xFFC9184A);
        rg(s, 48, 48, 31, 11, 0xFFE0A458);
        rg(s, 48, 48, 28, 12, 0xFFFF6FA5);
        ln(s, 30, 30, 34, 27, 3, 0xFFFFFFFF);
        ln(s, 60, 24, 64, 28, 3, 0xFFFFE066);
        ln(s, 70, 44, 74, 47, 3, 0xFF8EE3FF);
        ln(s, 22, 52, 25, 57, 3, 0xFFFFE066);
        ln(s, 66, 66, 62, 70, 3, 0xFFFFFFFF);
        ln(s, 38, 72, 43, 71, 3, 0xFF8EE3FF);
    } else if (name == "life") {
        tile(s, 0xFF2A9D8F, 0xFF144B52);
        let gx = [1, 2, 0, 1, 2];
        let gy = [0, 1, 2, 2, 2];
        let r = 0;
        while (r < 3) {
            let c = 0;
            while (c < 3) {
                rr(s, 20 + c * 20, 20 + r * 20, 38 + c * 20, 38 + r * 20, 5, 0x30FFFFFF);
                c = c + 1;
            };
            r = r + 1;
        };
        let i = 0;
        while (i < 5) {
            rr(s, 20 + gx[i] * 20, 20 + gy[i] * 20, 38 + gx[i] * 20, 38 + gy[i] * 20, 5, 0xFFC8F560);
            i = i + 1;
        };
    } else if (name == "cube") {
        tile(s, 0xFFA78BFA, 0xFF4C1D95);
        ln(s, 26, 38, 58, 38, 5, 0xFFFFFFFF);
        ln(s, 58, 38, 58, 70, 5, 0xFFFFFFFF);
        ln(s, 58, 70, 26, 70, 5, 0xFFFFFFFF);
        ln(s, 26, 70, 26, 38, 5, 0xFFFFFFFF);
        ln(s, 40, 24, 72, 24, 5, 0xB0FFFFFF);
        ln(s, 72, 24, 72, 56, 5, 0xB0FFFFFF);
        ln(s, 26, 38, 40, 24, 5, 0xB0FFFFFF);
        ln(s, 58, 38, 72, 24, 5, 0xB0FFFFFF);
        ln(s, 58, 70, 72, 56, 5, 0xB0FFFFFF);
    } else if (name == "mandelbrot") {
        tile(s, 0xFF1E3A8A, 0xFF050B24);
        dc(s, 42, 48, 25, 0xFFFFC857);
        dc(s, 42, 48, 22, 0xFF08122E);
        dc(s, 72, 48, 12, 0xFFFF7A59);
        dc(s, 72, 48, 9, 0xFF08122E);
        dc(s, 85, 48, 5, 0xFF7AE7FF);
        dc(s, 85, 48, 3, 0xFF08122E);
        dc(s, 28, 26, 5, 0xFFFFC857);
        dc(s, 28, 70, 5, 0xFFFFC857);
    } else if (name == "editor") {
        tile(s, 0xFF93C5FD, 0xFF1D4ED8);
        rr(s, 24, 14, 72, 82, 6, 0xFFFFFFFF);
        ln(s, 33, 30, 62, 30, 4, 0xFF94A3B8);
        ln(s, 33, 42, 62, 42, 4, 0xFF94A3B8);
        ln(s, 33, 54, 54, 54, 4, 0xFF94A3B8);
        ln(s, 33, 66, 58, 66, 4, 0xFF94A3B8);
        ln(s, 58, 74, 84, 40, 6, 0xFFF59E0B);
        tr(s, 52, 80, 56, 70, 62, 76, 0xFF1E293B);
    } else if (name == "sndtone" || name == "beep") {
        tile(s, 0xFFF0ABFC, 0xFF86198F);
        qd(s, 22, 38, 36, 38, 36, 58, 22, 58, 0xFFFFFFFF);
        tr(s, 36, 38, 54, 24, 54, 72, 0xFFFFFFFF);
        tr(s, 36, 58, 54, 72, 36, 38, 0xFFFFFFFF);
        ln(s, 62, 38, 68, 48, 5, 0xE0FFFFFF);
        ln(s, 68, 48, 62, 58, 5, 0xE0FFFFFF);
        ln(s, 70, 30, 80, 48, 5, 0xA0FFFFFF);
        ln(s, 80, 48, 70, 66, 5, 0xA0FFFFFF);
    } else if (name == "raytracer") {
        tile(s, 0xFF1E293B, 0xFF020617);
        el(s, 48, 74, 30, 8, 0x60000000);
        dc(s, 48, 46, 28, 0xFF1D4ED8);
        dc(s, 44, 42, 23, 0xFF3B82F6);
        dc(s, 40, 36, 15, 0xFF93C5FD);
        dc(s, 36, 31, 7, 0xFFFFFFFF);
        ln(s, 10, 80, 86, 80, 3, 0x80FFFFFF);
    } else if (name == "perft") {
        tile(s, 0xFF64748B, 0xFF1E293B);
        let r = 0;
        while (r < 4) {
            let c = 0;
            while (c < 4) {
                let col = 0xFFE2E8F0;
                if ((r + c) % 2 == 1) { col = 0xFF475569; };
                rr(s, 16 + c * 16, 16 + r * 16, 32 + c * 16, 32 + r * 16, 1, col);
                c = c + 1;
            };
            r = r + 1;
        };
    } else if (name == "toolkit-cli") {
        tile(s, 0xFF9CA3AF, 0xFF374151);
        dc(s, 48, 48, 24, 0xFFFFFFFF);
        let a = 0;
        while (a < 360) {
            ln(s, 48 + icos(a) * 22 / 256, 48 - isin(a) * 22 / 256, 48 + icos(a) * 33 / 256, 48 - isin(a) * 33 / 256, 11, 0xFFFFFFFF);
            a = a + 45;
        };
        dc(s, 48, 48, 11, 0xFF5B6472);
    } else if (name == "bignum") {
        tile(s, 0xFFFB923C, 0xFF9A3412);
        gfx.text(s, 11, 30, "123", 3, 0xFFFFFFFF);
    } else if (name == "halt") {
        tile(s, 0xFFF87171, 0xFF7F1D1D);
        rg(s, 48, 50, 24, 17, 0xFFFFFFFF);
        rr(s, 38, 20, 58, 44, 0, 0xFFC84A4A);
        ln(s, 48, 22, 48, 50, 7, 0xFFFFFFFF);
    } else if (name == "vtdemo") {
        tile(s, 0xFF111827, 0xFF030712);
        let i = 0;
        while (i < 6) {
            rr(s, 14 + i * 12, 22, 24 + i * 12, 74, 3, hsv(i * 60, 200, 240));
            i = i + 1;
        };
        ln(s, 14, 82, 82, 82, 4, 0xFFFFFFFF);
    } else {
        generic(s, name);
    };
};
