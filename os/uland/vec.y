// vec -- a small vector-image renderer: the `YVG2` files os/tools/genwall.py writes.
//
// An image is a stack of layers painted in order, each a flat colour filled through a set of
// closed outlines made of cubic Beziers (a hole is an outline wound the other way: the fill rule
// is non-zero, with the coverage clamped). `draw` flattens the curves for the size it is asked
// for and rasterises with exact signed-area accumulation: every edge adds, per pixel it crosses,
// the area it leaves to its right into a row of 32-bit cells, and a running sum along the row is
// the pixel's coverage, so anti-aliasing is exact (no sub-scanlines, no sorting, no active
// list) and a layer costs its bounding box. Integer arithmetic only; the accumulation cells
// are mmap'd for the call and given back, so rendering leaves nothing on the heap.
//
// File: "YVG2", u16 grid, u16 layers; per layer u8 r g b, varint outlines; per outline a varint node
// count and the nodes: varint (zigzag dx << 1 | corner) and zigzag dy from the previous node (grid
// units), u8 angle (256ths of a turn, the direction the curve leaves the node), for a corner a second
// u8 (the direction it arrived), then varint out-handle and in-handle lengths. Node i to node i+1 is
// the cubic P_i, P_i + out_i * dir_out_i, P_i+1 - in_i+1 * dir_in_i+1, P_i+1; outlines wrap round.
import gfx;

let pos = 0;
let acc: *i32 = ptr_from(0);
let stride = 0;
let sw = 0;
let sh = 0;
let bx0 = 0;
let bx1 = 0;
let by0 = 0;
let by1 = 0;

/** cos(2 pi k / 256) * 16384 for k = 0..64: the rest follows by symmetry. */
let quarter: [long] = [16384, 16379, 16364, 16340, 16305, 16261, 16207, 16143, 16069, 15986, 15893, 15791, 15679, 15557, 15426, 15286, 15137, 14978, 14811, 14635, 14449, 14256, 14053, 13842, 13623, 13395, 13160, 12916, 12665, 12406, 12140, 11866, 11585, 11297, 11003, 10702, 10394, 10080, 9760, 9434, 9102, 8765, 8423, 8076, 7723, 7366, 7005, 6639, 6270, 5897, 5520, 5139, 4756, 4370, 3981, 3590, 3196, 2801, 2404, 2006, 1606, 1205, 804, 402, 0];

def cosq(k: long) -> long {
    let a = k & 255;
    if (a <= 64) { quarter[a] } else if (a <= 128) { 0 - quarter[128 - a] } else if (a <= 192) { 0 - quarter[a - 128] } else { quarter[256 - a] }
};

def u8(d: str) -> long {
    let v = d[pos] & 255;
    pos = pos + 1;
    v
};

def u16(d: str) -> long {
    let lo = u8(d);
    lo | (u8(d) << 8)
};

/** One LEB128 integer. */
def varint(d: str) -> long {
    let z = 0;
    let s = 0;
    let more = true;
    while (more) {
        let c = u8(d);
        z = z | ((c & 127) << s);
        s = s + 7;
        more = (c & 128) != 0;
    };
    z
};

def unzig(z: long) -> long {
    if ((z & 1) == 0) { z >> 1 } else { 0 - ((z + 1) >> 1) }
};

/** Is `d` a YVG2 file; its grid size, or 0. */
def grid_of(d: str) -> long {
    if (len(d) < 8 || d[0] != 89 || d[1] != 86 || d[2] != 71 || d[3] != 50) { return 0; };
    pos = 4;
    u16(d)
};

/** Add the signed area one edge leaves to its right (1/256 pixel units in; 65536 is a whole pixel). */
def edge(xa0: long, ya0: long, xb0: long, yb0: long) -> void {
    if (ya0 == yb0) { return; };
    let dir = 1;
    let xa = xa0;
    let ya = ya0;
    let xb = xb0;
    let yb = yb0;
    if (ya > yb) {
        dir = 0 - 1;
        xa = xb0;
        ya = yb0;
        xb = xa0;
        yb = ya0;
    };
    if (yb <= 0 || ya >= sh * 256) { return; };
    let dy_all = yb - ya;
    let dx_all = xb - xa;
    let r0 = if (ya < 0) { 0 } else { ya >> 8 };
    let r1 = (if (yb > sh * 256) { sh * 256 } else { yb } - 1) >> 8;
    if (r0 < by0) { by0 = r0; };
    if (r1 > by1) { by1 = r1; };
    let wmax = sw * 256;
    let row = r0;
    while (row <= r1) {
        let yt = if (ya > row * 256) { ya } else { row * 256 };
        let yu = if (yb < row * 256 + 256) { yb } else { row * 256 + 256 };
        let d = (yu - yt) * dir;
        let cx0 = xa + (yt - ya) * dx_all / dy_all;
        let cx1 = xa + (yu - ya) * dx_all / dy_all;
        if (cx0 < 0) { cx0 = 0; };
        if (cx1 < 0) { cx1 = 0; };
        if (cx0 > wmax) { cx0 = wmax; };
        if (cx1 > wmax) { cx1 = wmax; };
        let xl = if (cx0 < cx1) { cx0 } else { cx1 };
        let xr = if (cx0 < cx1) { cx1 } else { cx0 };
        let i0 = xl >> 8;
        let ic = (xr + 255) >> 8;
        let n = ic - i0;
        let base: *i32 = acc + row * stride;
        if (i0 < bx0) { bx0 = i0; };
        if (ic + 1 > bx1) { bx1 = ic + 1; };
        let ad = if (d < 0) { 0 - d } else { d };
        if (n <= 1) {
            let xm = ((cx0 + cx1) >> 1) - i0 * 256;
            *(base + i0) = *(base + i0) + d * (256 - xm);
            *(base + i0 + 1) = *(base + i0 + 1) + d * xm;
        } else {
            let dx = xr - xl;
            let fx0 = xl & 255;
            let fx1 = xr - (ic - 1) * 256;
            let a0 = ad * (256 - fx0) * (256 - fx0) / (2 * dx);
            let am = ad * fx1 * fx1 / (2 * dx);
            let sg = if (d < 0) { 0 - 1 } else { 1 };
            if (n == 2) {
                *(base + i0) = *(base + i0) + sg * a0;
                *(base + i0 + 1) = *(base + i0 + 1) + sg * (ad * 256 - a0 - am);
                *(base + i0 + 2) = *(base + i0 + 2) + sg * am;
            } else {
                let a1 = ad * (384 - fx0) * 256 / dx;
                let sd = ad * 65536 / dx;
                *(base + i0) = *(base + i0) + sg * a0;
                *(base + i0 + 1) = *(base + i0 + 1) + sg * (a1 - a0);
                let xi = i0 + 2;
                while (xi < ic - 1) {
                    *(base + xi) = *(base + xi) + sg * sd;
                    xi = xi + 1;
                };
                let a2 = a1 + (n - 3) * sd;
                *(base + ic - 1) = *(base + ic - 1) + sg * (ad * 256 - a2 - am);
                *(base + ic) = *(base + ic) + sg * am;
            };
        };
        row = row + 1;
    };
};

/** Flatten the cubic (1/256 pixel units) into edges, ending at (x3, y3). */
def cubic(x0: long, y0: long, x1: long, y1: long, x2: long, y2: long, x3: long, y3: long) -> void {
    let ax = x0 - 2 * x1 + x2;
    let ay = y0 - 2 * y1 + y2;
    let bx = x1 - 2 * x2 + x3;
    let by = y1 - 2 * y2 + y3;
    if (ax < 0) { ax = 0 - ax; };
    if (ay < 0) { ay = 0 - ay; };
    if (bx < 0) { bx = 0 - bx; };
    if (by < 0) { by = 0 - by; };
    let dv = gfx.max(ax + ay, bx + by);
    // pieces: error ~ 3/4 * dv / n^2, aimed at 1/8 pixel (32 units)
    let n = 1;
    while (n * n * 43 < dv && n < 64) { n = n + 1; };
    let px = x0;
    let py = y0;
    let i = 1;
    while (i <= n) {
        let qx = x3;
        let qy = y3;
        if (i < n) {
            let t = i * 4096 / n;
            let u = 4096 - t;
            let c0 = u * u * u;
            let c1 = 3 * u * u * t;
            let c2 = 3 * u * t * t;
            let c3 = t * t * t;
            qx = (c0 * x0 + c1 * x1 + c2 * x2 + c3 * x3) >> 36;
            qy = (c0 * y0 + c1 * y1 + c2 * y2 + c3 * y3) >> 36;
        };
        edge(px, py, qx, qy);
        px = qx;
        py = qy;
        i = i + 1;
    };
};

/** Paint the image `d` onto `dst` (opaque 0x00RRGGBB) with its square's top-left at (ox, oy) and
side `size` pixels. */
def draw(dst: gfx.Surf, d: str, ox: long, oy: long, size: long) -> bool {
    let grid = grid_of(d);
    if (grid == 0 || size <= 0) { return false; };
    let layers = u16(d);
    let w = dst.w;
    let h = dst.h;
    sw = w;
    sh = h;
    stride = w + 3;
    let maxn = len(d) / 3 + 8;
    let cells = (h + 1) * stride * 4;
    let nbytes = maxn * 64;
    let abuf = gfx.alloc(cells);
    let nbuf = gfx.alloc(nbytes);
    if (abuf == 0 || nbuf == 0) {
        gfx.release(abuf, cells);
        gfx.release(nbuf, nbytes);
        return false;
    };
    acc = ptr_from(abuf);
    let nd: *long = ptr_from(nbuf);
    // grid units to 1/256 pixel: * size / 8 when grid is 2048; the general form keeps 8 bits of the ratio
    let gx = 0;
    let gy = 0;
    let ox8 = ox * 256;
    let oy8 = oy * 256;
    let li = 0;
    while (li < layers) {
        let r = u8(d);
        let g = u8(d);
        let b = u8(d);
        let col = (r << 16) | (g << 8) | b;
        let nc = varint(d);
        bx0 = 0x7FFFFFFF;
        bx1 = 0;
        by0 = 0x7FFFFFFF;
        by1 = 0 - 1;
        let ci = 0;
        while (ci < nc) {
            let n = varint(d);
            let i = 0;
            while (i < n) {
                let v = varint(d);
                let corner = v & 1;
                gx = gx + unzig(v >> 1);
                gy = gy + unzig(varint(d));
                let ao = u8(d);
                let ai = ao;
                if (corner == 1) { ai = u8(d); };
                let lo = varint(d);
                let li2 = varint(d);
                let q = nd + i * 8;
                *q = ox8 + gx * size * 256 / grid;
                *(q + 1) = oy8 + gy * size * 256 / grid;
                *(q + 2) = ao;
                *(q + 3) = ai;
                *(q + 4) = lo * size * 256 / grid;
                *(q + 5) = li2 * size * 256 / grid;
                i = i + 1;
            };
            i = 0;
            while (i < n) {
                let p = nd + i * 8;
                let j = if (i + 1 == n) { 0 } else { i + 1 };
                let q = nd + j * 8;
                let ao = *(p + 2);
                let ai = *(q + 3);
                let lo = *(p + 4);
                let lin = *(q + 5);
                let x0 = *p;
                let y0 = *(p + 1);
                let x3 = *q;
                let y3 = *(q + 1);
                cubic(x0, y0, x0 + ((lo * cosq(ao)) >> 14), y0 + ((lo * cosq(ao - 64)) >> 14), x3 - ((lin * cosq(ai)) >> 14), y3 - ((lin * cosq(ai - 64)) >> 14), x3, y3);
                i = i + 1;
            };
            ci = ci + 1;
        };
        // sweep the layer's box: running sum along each row is the coverage
        let ya = gfx.max(by0, 0);
        let yb = gfx.min(by1, h - 1);
        let xa = gfx.max(bx0, 0);
        let xb = gfx.min(bx1, w + 1);
        let row = ya;
        while (row <= yb) {
            let base: *i32 = acc + row * stride;
            let px: *u32 = ptr_from(dst.p + row * w * 4);
            let run = 0;
            let x = xa;
            while (x <= xb) {
                run = run + *(base + x);
                *(base + x) = 0;
                if (x < w) {
                    let c = if (run < 0) { 0 - run } else { run };
                    if (c >= 65280) {
                        *(px + x) = col;
                    } else if (c >= 256) {
                        let k = c >> 8;
                        let o = *(px + x);
                        let rb = (((o & 0xFF00FF) * (256 - k) + (col & 0xFF00FF) * k) >> 8) & 0xFF00FF;
                        let gg = (((o & 0xFF00) * (256 - k) + (col & 0xFF00) * k) >> 8) & 0xFF00;
                        *(px + x) = rb | gg;
                    };
                };
                x = x + 1;
            };
            row = row + 1;
        };
        li = li + 1;
    };
    gfx.release(abuf, cells);
    gfx.release(nbuf, nbytes);
    true
};
