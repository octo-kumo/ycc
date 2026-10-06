// gfx.y -- an in-memory RGB framebuffer, and the integer renderer the
// example draws into it.
//
// WHY A FRAMEBUFFER IN MEMORY AT ALL: the acceptance gate diffs `EXPECTED`
// byte for byte, and a window on somebody's screen produces no bytes to diff.
// So the image this example is *about* is built here, deterministically, in
// plain integer arithmetic; the X11 path later uploads that same image to a
// real server and reads it back. Nothing in this file opens a socket, reads
// the clock, or looks at an environment variable, so `./x11 demo` and
// `./x11 check` work identically on a machine with no display at all.
//
// DISCIPLINE (ORCHESTRATOR.md 2.7): the heap is an arena and nothing is ever
// freed, so the image lives in ONE fixed module-level buffer sized for the
// largest frame this example will ever draw. Every routine writes in place.
// A `[byte; N]` does not unify with `[byte]` (SUGGESTIONS.md #12), so these
// routines cannot take the buffer as a parameter -- they use the module-level
// one, which is why nothing here allocates per pixel.

// The frame size the example draws at. 320x240 is 230400 bytes of RGB, which
// is comfortably inside the 512 MiB cap gate item 4 runs under, and is also
// the size of the window --show opens: small enough that it cannot take over
// a 3440x1440 screen.
let W_MAX = 320;
let H_MAX = 240;
let STRIDE_MAX = W_MAX * 3;
let PX_MAX = W_MAX * H_MAX * 3;      // 230400
let PX_BYTES = W_MAX * H_MAX;        // 76800 pixels

// The one framebuffer.  Module-level, so it is a .bss cell filled once.
let px: [byte; 230400] = [0; 230400];

// -----------------------------------------------------------------------
// A few integer helpers the renderer needs.  There is no `isqrt`, no `abs`
// and no `min`/`max` in the language (ORCHESTRATOR.md 2.4b), so they are here.
// -----------------------------------------------------------------------

// Integer square root, floor(sqrt(v)) for v >= 0, by the classic
// restoring "digit-by-digit" method: accumulate the root two bits at a time.
//
// THE BIT STEP IS /4, NOT /2.  That is the whole algorithm.  The first draft
// of this function did `bit = bit / 2`, halving where the method requires
// quartering, so it visited 2^30, 2^29, 2^28, ... instead of 2^30, 2^28, 2^26,
// ... -- the wrong bit sequence, and no error.  It also ran one iteration too
// long: with `bit` already 0, the else-branch halved `res` one last time and
// destroyed the answer, so isqrt(1) returned 0.  The battery's G17..G20 caught
// both, and D01 caught the consequence: `scene.disc_area_expect` sums
// 2*isqrt(r*r-dx*dx)+1 per column and was returning 639 for a disc that draws
// 8497 pixels.
//
// v <= 0 returns 0: isqrt is defined here only for v >= 0, and every caller
// guards the negative case itself.
def isqrt(v: long) -> long {
    if (v <= 0) { return 0 };
    let n = v;
    let res: long = 0;
    // The highest power of four not exceeding n.  Terminates because `bit`
    // grows fourfold while the bound n/4 is fixed; at most 32 doublings for a
    // 64-bit n, and for any n this example uses, at most 10.
    let bit: long = 1;
    while (bit <= n / 4) { bit = bit * 4 };
    // Two bits of root per step.  Terminates because `bit` is a positive power
    // of four and is divided by four each iteration, so it reaches 0 in at most
    // 32 steps; the guard below is a loose over-bound and is never the exit.
    let k = 0;
    while (bit > 0 && k < 40) {
        if (n >= res + bit) {
            n = n - (res + bit);
            res = (res / 2) + bit
        } else {
            res = res / 2
        };
        bit = bit / 4;
        k = k + 1
    };
    res
};

def imin(a: long, b: long) -> long { if a < b { a } else { b } };
def imax(a: long, b: long) -> long { if a > b { a } else { b } };
def iclamp(v: long, lo: long, hi: long) -> long {
    if v < lo { lo } else if v > hi { hi } else { v }
};

// -----------------------------------------------------------------------
// Pixel access.  Every store is bounds-checked against the *buffer*, and
// every public routine additionally clamps to the logical (w, h) of the
// frame currently being drawn, so a defect in a caller cannot walk off it.
// -----------------------------------------------------------------------

def inb(x: long, y: long, w: long, h: long) -> bool {
    x >= 0 && x < w && y >= 0 && y < h
};

// One pixel, three channels.  Out-of-range writes are dropped and counted
// by `clipped`, so a battery can prove the renderer never needed to.
let clipped: long = 0;

def put(x: long, y: long, r: long, g: long, b: long) -> long {
    if (!inb(x, y, W_MAX, H_MAX)) {
        clipped = clipped + 1;
        0
    } else {
        let i = (y * W_MAX + x) * 3;
        px[i] = r & 255;
        px[i + 1] = g & 255;
        px[i + 2] = b & 255;
        1
    }
};

def putn(x: long, y: long, c: long) -> long {
    put(x, y, (c >> 16) & 255, (c >> 8) & 255, c & 255)
};

// One pixel packed 0x00RRGGBB.  -1 outside the buffer.
def get(x: long, y: long) -> long {
    if (!inb(x, y, W_MAX, H_MAX)) {
        -1
    } else {
        let i = (y * W_MAX + x) * 3;
        (px[i] * 65536) + (px[i + 1] * 256) + px[i + 2]
    }
};

// -----------------------------------------------------------------------
// Statistics and the digest.
//
// FNV-1a, 64-bit.  The state is a `long`, so it goes negative -- two's
// complement overflow is silent and wraps, which is what the algorithm wants.
// It is printed as four 16-bit groups rather than one 64-bit hex number,
// because `f"{-1:02x}"` prints `-1` and not `ffffffffffffffff` (verified), and
// because `(h >> 48) & 65535` is exact whether or not h is negative.
let FNV_OFF: long = -3750763034362895579;        // 0xcbf29ce484222325
let FNV_PRIME: long = 1099511628211;             // 0x100000001b3

def hex16(v: long) -> str { f"{v & 65535:04x}" };

def hex64(h: long) -> str {
    hex16((h >> 48) & 65535) + hex16((h >> 32) & 65535)
    + hex16((h >> 16) & 65535) + hex16(h & 65535)
};

def digest_hex(h: long) -> str { "0x" + hex64(h) };

// Hash `n` bytes starting at `off` in the framebuffer, carrying `h` in.
// Streaming, so a caller can hash in bands and get the same value as hashing
// the whole thing in one pass -- which is what the GetImage read-back does.
def digest_add(h: long, off: long, n: long) -> long {
    let last = off + n;
    if (off < 0 || last > PX_MAX) { return 0 - 1 };
    let i = off;
    while (i < last) {
        h = (h ^ px[i]) * FNV_PRIME;
        i = i + 1;
    };
    h
};

// FNV-1a over the first w*h*3 bytes of the framebuffer, in row order.
def digest(w: long, h: long) -> long {
    digest_add(FNV_OFF, 0, w * h * 3)
};

// -----------------------------------------------------------------------
// Statistics.  Recorded in a module-level record the stat routines fill, so
// no caller has to take an out-parameter (there are no out-parameters for a
// scalar in this language -- ORCHESTRATOR.md 2.15 -- and a helper that
// assigns to a scalar parameter changes nothing at all).
// -----------------------------------------------------------------------

type Stats = {
    pixels: long,        // w * h
    nonzero: long,       // pixels whose three channels are not all zero
    sum_r: long,
    sum_g: long,
    sum_b: long,
    sum_all: long        // sum_r + sum_g + sum_b
};

let st: Stats = {
    pixels: 0, nonzero: 0, sum_r: 0, sum_g: 0, sum_b: 0, sum_all: 0
};

def stats_reset() -> long {
    st.pixels = 0; st.nonzero = 0;
    st.sum_r = 0; st.sum_g = 0; st.sum_b = 0; st.sum_all = 0;
    0
};

// Scan the first w*h pixels of the framebuffer.  Bounded by construction:
// `last` is w*h*3 and every offset is below it, and w,h are clamped by the
// caller.  76800 iterations at the demo size, in place, zero allocation.
def stats_scan(w: long, h: long) -> long {
    stats_reset();
    st.pixels = w * h;
    let i = 0;
    let last = w * h * 3;
    while (i < last) {
        let r = px[i];
        let g = px[i + 1];
        let b = px[i + 2];
        st.sum_r = st.sum_r + r;
        st.sum_g = st.sum_g + g;
        st.sum_b = st.sum_b + b;
        if (r != 0 || g != 0 || b != 0) { st.nonzero = st.nonzero + 1 };
        i = i + 3;
    };
    st.sum_all = st.sum_r + st.sum_g + st.sum_b;
    st.nonzero
};

// -----------------------------------------------------------------------
// Primitives.  Each returns the number of pixels it wrote, counted, so the
// demo can report a figure and the battery can hold the renderer to it
// against arithmetic done by hand.  Every one clamps its arguments to the
// frame it was given, so a caller cannot ask for a 4096x4096 blob.
// -----------------------------------------------------------------------

// Solid rectangle, corners inclusive.  Returns the pixels written.
def fill_rect(x0: long, y0: long, x1: long, y1: long, c: long) -> long {
    let ax = iclamp(x0, 0, W_MAX - 1);
    let bx = iclamp(x1, 0, W_MAX - 1);
    let ay = iclamp(y0, 0, H_MAX - 1);
    let by = iclamp(y1, 0, H_MAX - 1);
    let n = 0;
    if (ax <= bx && ay <= by) {
        let y = ay;
        while (y <= by) {
            let x = ax;
            while (x <= bx) {
                n = n + putn(x, y, c);
                x = x + 1;
            };
            y = y + 1;
        };
    };
    n
};

// One-pixel frame, corners inclusive.  Returns the number of pixels
// written, which is 2*(x1-x0+1) + 2*(y1-y0+1) - 4 for a rectangle at least
// 2x2 -- the four corners are written once each, so the vertical runs skip
// them.  The first draft drew all four sides in full and reported the four
// corner pixels twice.
def stroke_rect(x0: long, y0: long, x1: long, y1: long, c: long) -> long {
    let ax = iclamp(x0, 0, W_MAX - 1);
    let bx = iclamp(x1, 0, W_MAX - 1);
    let ay = iclamp(y0, 0, H_MAX - 1);
    let by = iclamp(y1, 0, H_MAX - 1);
    let n = 0;
    if (ax <= bx && ay <= by) {
        n = n + fill_rect(ax, ay, bx, ay, c);
        // The second row only when there IS a second row.  Without this guard a
        // 1x1 "frame" draws its single pixel twice and reports 2 -- an
        // over-count that makes the return value mean "pixels written" only for
        // boxes at least two rows tall.  Caught by check G10.
        if (by > ay) { n = n + fill_rect(ax, by, bx, by, c) };
        if (ay + 1 <= by - 1) {
            n = n + fill_rect(ax, ay + 1, ax, by - 1, c);
            n = n + fill_rect(bx, ay + 1, bx, by - 1, c);
        };
    };
    n
};

// Filled disc: every pixel whose squared distance from the centre is at most
// r*r.  No square root, no trigonometry, no float -- the whole test is
// dx*dx + dy*dy <= r*r, which is why this language suits this protocol.
// Bounded: |dx| and |dy| are both <= r, and r is clamped to W_MAX, so the
// loop is at most (2r+1)^2 iterations and 2r+1 <= 641.
def disc(cx: long, cy: long, r: long, c: long) -> long {
    let rr = iclamp(r, 0, imax(W_MAX, H_MAX));
    let r2 = rr * rr;
    let n = 0;
    let dy = 0 - rr;
    while (dy <= rr) {
        let dy2 = dy * dy;
        let dx = 0 - rr;
        while (dx <= rr) {
            if (dx * dx + dy2 <= r2) { n = n + putn(cx + dx, cy + dy, c) };
            dx = dx + 1;
        };
        dy = dy + 1;
    };
    n
};

// Bresenham line, endpoints inclusive.  Returns the number of pixels
// emitted, which for a non-degenerate line is max(|dx|,|dy|)+1 -- a figure
// the battery computes by hand.
//
// NOTE THE SIGN OF `dy`.  The standard form carries dy NEGATIVE
// (`dy = -|y1-y0|`) and accumulates `err = dx + dy`; the variant with a
// positive dy needs different comparisons.  Mixing the two is silent: the
// `e2 >= dy` test then succeeds on every step, x advances alone, the endpoint
// test never fires and the loop runs to its guard.  The first draft of this
// function did exactly that, and reported 310 pixels for a 141-pixel line
// while writing 812 pixels outside the frame.  `gfx.clipped` is printed by
// the demo precisely so that class of defect cannot be quiet; see the
// injected-defect list in README.md.
def line(x0: long, y0: long, x1: long, y1: long, c: long) -> long {
    let ddx = x1 - x0;
    let ddy = y1 - y0;
    let dx = imax(0 - ddx, ddx);
    let dy = 0 - imax(0 - ddy, ddy);      // negative: -|dy|
    let sx = if x0 < x1 { 1 } else { 0 - 1 };
    let sy = if y0 < y1 { 1 } else { 0 - 1 };
    let err = dx + dy;
    let n = 0;
    let ax = x0;
    let ay = y0;
    // Termination argument (there is no `break`, so this is the whole proof):
    // `dy <= 0 <= dx`, so `e2 >= dy` and `e2 <= dx` cannot both be false --
    // that would need dy > e2 > dx.  Hence every iteration advances at least
    // one of ax toward x1 or ay toward y1, and both are monotonic, so
    // |ax-x1| + |ay-y1| strictly decreases.  It starts at dx + |dy|, at most
    // 2*max(W_MAX,H_MAX) for any two points of this frame, so the guard
    // below is a loose over-bound and is never the exit.
    let go = true;
    let guard = 0;
    while (go && guard < 2 * imax(W_MAX, H_MAX) + 2) {
        n = n + putn(ax, ay, c);
        if (ax == x1 && ay == y1) {
            go = false
        } else {
            let e2 = err * 2;
            if (e2 >= dy) { err = err + dy; ax = ax + sx };
            if (e2 <= dx) { err = err + dx; ay = ay + sy };
        };
        guard = guard + 1;
    };
    n
}

// A checkerboard of `cell`-pixel squares filling [x0,x1]x[y0,y1].
// Returns the number of ON cells.  A cell is on when (cx + cy) is even,
// counted in cell coordinates, so the count of on cells over a Wc x Hc grid
// is a function of Wc and Hc alone -- which the battery derives by hand.
def checker(x0: long, y0: long, w: long, h: long, cell: long,
            on: long, off: long) -> long {
    let cs = imax(cell, 1);
    let cells_n = 0;
    let on_n = 0;
    let y = 0;
    while (y < h) {
        let x = 0;
        while (x < w) {
            let cy = y / cs;
            let cx = x / cs;
            let lit = (cx + cy) % 2 == 0;
            let c = if lit { on } else { off };
            let bw = imin(cs, w - x);
            let bh = imin(cs, h - y);
            fill_rect(x0 + x, y0 + y, x0 + x + bw - 1, y0 + y + bh - 1, c);
            if (lit) { on_n = on_n + 1 };
            cells_n = cells_n + 1;
            x = x + cs;
        };
        y = y + cs;
    };
    on_n
};

// The background: an exact linear ramp in each channel, computed as
// x*255/(w-1), y*255/(h-1) and (x+y)*255/(w+h-2).  Integer division, so it
// is reproducible to the bit on any machine.  Its four corners are exact:
// (0,0) = (0,0,0), (w-1,0) has r = 255, (0,h-1) has g = 255 and
// (w-1,h-1) = (255,255,255).
def gradient(w: long, h: long) -> long {
    let den_r = imax(w - 1, 1);
    let den_g = imax(h - 1, 1);
    let den_b = imax(w + h - 2, 1);
    let y = 0;
    while (y < h) {
        let x = 0;
        while (x < w) {
            put(x, y, (x * 255) / den_r, (y * 255) / den_g,
                ((x + y) * 255) / den_b);
            x = x + 1;
        };
        y = y + 1;
    };
    w * h
};

// Wipe the first w*h pixels of the framebuffer to zero, in place.
def wipe(w: long, h: long) -> long {
    let last = iclamp(w * h * 3, 0, PX_MAX);
    let i = 0;
    while (i < last) { px[i] = 0; i = i + 1 };
    last
};
