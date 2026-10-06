// badapple.y -- Bad Apple!! in your terminal, 160x60 cells (30 fps),
// white on black: the C reference (bad_apple160x60.c) ported faithfully,
// down to its exact-match glyph families, its flip SGRs and its braille
// fallback.  The other 160x60 player, badapple160x60.y, draws the same
// picture with the termblocks matcher and adds the color modes.
//
// The video side is the original pipeline: a 40x30 binary mask,
// WNC-adaptively arithmetic coded with one keyframe every 4 frames (that
// coded stream is s40x30), the frames between keyframes rebuilt by
// temporal dither, and the field bilinearly upsampled 16x to 640x480,
// which is exactly 160x60 cells of 4x8 square subpixels.  Rows are diffed
// against the last frame, so only what changed is written.
//
// Build:  ycc -o badapple badapple.y      (needs s40x30 next to it)
// Run:    ./badapple                      (no options, as the C reference)

embed DATA from "s40x30";

let KB: [byte; 2400] = [0; 2400];
let F: [byte; 1200] = [0; 1200];
let R: [byte; 1200] = [0; 1200];
let obuf: [byte; 2088] = [0; 2088];      // ESC [ r c ; 1 H, then the row
let pbuf: [byte; 124800] = [0; 124800];  // 60 rows of 2080, as last painted
let plen: [long; 60] = [0; 60];           // how much of each was written
let P: [long; 8] = [0; 8];                // the coder's probabilities
let ts: [long; 2] = [0; 2];               // the shared timespec
let QT: [long; 16] = [32, 0x2597, 0x2596, 0x2584, 0x259d, 0x2590, 0x259e, 0x259f, 0x2598, 0x259a, 0x258c, 0x2599, 0x2580, 0x259c, 0x259b, 0x2588];
let framehome = "\x1b[1;1H";
let dpos = 0;
let dcur = 0;
let dbits = 0;
let clo = 0;
let chi = 0;
let ccode = 0;
// The row buffer opens with the CUP "ESC [ r c ; 1 H"; the row number goes
// into bytes 2 and 3 when the row is flushed.
let CUP = "\x1b[00;1H";

def set_tables() {
    for i in 0..1200 {
        R[i] = ((i * 2654435761) & 4294967295) >> 24;
    };
    for k in 0..7 { obuf[k] = byte_at(CUP, k) };
};

def gb() {
    if (dbits == 0) {
        if (dpos < len(DATA)) {
            dcur = byte_at(DATA, dpos);
            dpos ++;
            dbits = 8;
        };
    };
    let r = 0;
    if (dbits > 0) {
        dbits --;
        r = (dcur >> dbits) & 1;
    };
    r
};

def dec(p: long) {
    let range = chi - clo + 1;
    let split = chi - ((range * (65536 - p)) >> 16);
    let bit = 0;
    if (ccode <= split) { chi = split; } else { bit = 1; clo = split + 1; };
    let go = true;
    while (go) {
        if (clo < 32768 && chi < 32768) { }
        else if (clo >= 32768) {
            clo -= 32768; chi -= 32768; ccode -= 32768;
        } else if (clo >= 16384 && chi < 49152) {
            clo -= 16384; chi -= 16384; ccode -= 16384;
        } else { go = false; };
        if (go) {
            clo = clo * 2;
            chi = chi * 2 + 1;
            ccode = ccode * 2 + gb();
        };
    };
    bit
};

def kf(d: long, s: long) {
    for y in 0..30 {
        let base = y * 40;
        let left = 0;
        let kl = 0;
        for x in 0..40 {
            let i = base + x;
            let sv = KB[s + i];
            let cx = (sv << 2) | (left << 1) | kl;
            let p = P[cx];
            kl = sv;
            let b = dec(p);
            if (b != 0) { P[cx] = p - (p >> 5); }
            else { P[cx] = p + ((65536 - p) >> 5); };
            b = b ^ sv;
            KB[d + i] = b;
            left = b;
        };
    };
};

def cls(m: long) -> long {
    if (m == 0) { return 32; };
    if (m == 4294967295) { return 0x2588; };
    for k in 1..8 {
        if (m == (4294967295 - ((1 << (32 - 4 * k)) - 1))) { return 0x2580 + k; };
    };
    for k in 1..4 {
        if (m == (((1 << k) - 1) * 0x11111111)) { return 0x2590 - 2 * k; };
    };
    let q = 0;
    let w = 0;
    if ((m & 0x3333) == 0x3333) { q = q + 8; w = w + 0x3333; };
    if ((m & 0xcccc) == 0xcccc) { q = q + 4; w = w + 0xcccc; };
    if ((m & 0x33330000) == 0x33330000) { q = q + 2; w = w + 0x33330000; };
    if ((m & 0xcccc0000) == 0xcccc0000) { q = q + 1; w = w + 0xcccc0000; };
    if (m == w) { return QT[q]; };
    0
};

def braille(m: long) -> long {
    let c = 0;
    for r in 0..4 {
        for k in 0..2 {
            let t = (m >> (8 * r + 2 * k)) & 0x33;
            let s = (t & 1) + ((t >> 1) & 1) + ((t >> 4) & 1) + ((t >> 5) & 1);
            if (s >= 2) { c = c | (1 << (k * 4 + r)); };
        };
    };
    0x2800 + c
}

def ink(m: long) -> long {
    let v = m - ((m >> 1) & 0x55555555);
    v = (v & 0x33333333) + ((v >> 2) & 0x33333333);
    v = (v + (v >> 4)) & 0x0f0f0f0f;
    ((v * 0x01010101) >> 24) & 255
};

// clock_gettime(CLOCK_MONOTONIC) in microseconds, over one shared
// timespec: the std clock_us()/sleep() pair allocates a two-word array on
// every call, and the frame loop calls them twice.
def now_us() -> long {
    syscall(228, 1, &ts[0]);
    ts[0] * 1000000 + ts[1] / 1000
};

// nanosleep(2) for microseconds.
def nap_us(us: long) {
    let s = us / 1000000;
    ts[0] = s;
    ts[1] = (us - s * 1000000) * 1000;
    syscall(35, &ts[0], 0)
};

def paint_frame() -> void {
    for y in 0..60 {
        let o = 7;
        let lasto = -1;
        for x in 0..160 {
            // One cell at a time, all 8 subpixel rows inside: the mask is
            // finished before its glyph is chosen, so it stays in a local
            // instead of being written out and read back per subpixel row.
            let m = 0;
            for i in 0..8 {
                let yy = y * 8 + i;
                // The C's sy0/sy1/syw, tabulated: 320x240 is exactly 4
                // across by 8 down subpixels per cell, which on a 2:1 cell
                // are square subpositions, and bilinear-then-threshold IS
                // the linear-interpolation marching-squares level set, so
                // the silhouette edge lands on a sub-cell contour rather
                // than a pixel-snapped one.  The C clamps fy to 239 and fx
                // to 319; the arithmetic peaks at 235 and 315, so only the
                // low end can go out of range.
                let fy = ((2 * yy + 1) >> 2) - 4;
                if (fy < 0) { fy = 0; };
                let c0 = fy >> 3;
                let c1 = c0 + 1;
                if (c1 > 29) { c1 = 29; };
                let r0 = c0 * 40;
                let r1 = c1 * 40;
                let wy = fy & 7;
                let wyy = 8 - wy;
                for k in 0..4 {
                    let xx = x * 4 + k;
                    let fx = ((2 * xx + 1) >> 2) - 4;
                    if (fx < 0) { fx = 0; };
                    let d0 = fx >> 3;
                    let d1 = d0 + 1;
                    if (d1 > 39) { d1 = 39; };
                    let wx = fx & 7;
                    let wxx = 8 - wx;
                    let a0 = F[r0 + d0];
                    let b0 = F[r0 + d1];
                    let a1 = F[r1 + d0];
                    let b1 = F[r1 + d1];
                    let v = (a0 * wxx + b0 * wx) * wyy
                        + (a1 * wxx + b1 * wx) * wy;
                    // The C sharpens with (v - 32) * K + 32, K = 3, and
                    // clamps to 0..64 before thresholding at 32.  That map
                    // is increasing and fixes 32, and the clamp cannot
                    // reach across the threshold (it bites below 22 and
                    // above 43, where the test already agrees), so
                    // thresholding v is the same decision.
                    let bit = if v >= 32 { 1 } else { 0 };
                    m = m | (bit << (i * 4 + k));
                };
            };
            let g = cls(m);
            let f = 0;
            if (g == 0) {
                m = m ^ 4294967295;
                g = cls(m);
                f = 1;
            };
            if (g == 0) {
                // Neither orientation is a family: take the sparser one
                // and paint it as braille.  m is the inverted mask here, so
                // ink(m) < 16 is the C's "more than half ink" test on the
                // mask itself.
                if (ink(m) < 16) { f = 1; }
                else { f = 0; m = m ^ 4294967295; };
                g = braille(m);
            };
            if (f != lasto) {
                let e = if f == 0 { "\x1b[0;37;40m" } else { "\x1b[0;30;47m" };
                for k in 0..10 {
                    obuf[o] = byte_at(e, k);
                    o = o + 1;
                };
                lasto = f;
            };
            // 3-byte UTF-8 for U+2500..U+28FF (Block Elements, Braille); a
            // codepoint below 0x80 is itself -- SPACE IS NOT A GLYPH,
            // three-byte-encoding U+0020 would be the U+2020 DAGGER.
            if (g == 32) {
                obuf[o] = 32;
                o = o + 1;
            } else {
                obuf[o] = 224 | (g >> 12);
                obuf[o + 1] = 128 | ((g >> 6) & 63);
                obuf[o + 2] = 128 | (g & 63);
                o = o + 3;
            };
        };
        // The row against the one the last frame left there: write it only
        // when it changed, and keep pbuf in step either way.  The CUP sits
        // in the head of the buffer, so a changed row is one write(2).
        let rl = o - 7;
        let base = y * 2080;
        let n = 0;
        for i in 0..rl {
            let nv = obuf[i + 7];
            n = n | (pbuf[base + i] ^ nv);
            pbuf[base + i] = nv;
        };
        if (n != 0 || rl != plen[y]) {
            let tens = (y + 1) / 10;
            obuf[2] = 48 + tens;
            obuf[3] = 48 + (y + 1) - tens * 10;
            syscall(1, 1, &obuf[0], o);
            plen[y] = rl;
        };
    };
};

let curb = 0;
let tgtb = 1200;
let sched = now_us();
let skip = false;
let t = 0;

dpos = 0;
ccode = 0;
for i in 0..16 {
    ccode = (ccode << 1) | gb();
};
clo = 0;
chi = 65535;
for i in 0..8 {
    P[i] = 32768;
};
set_tables();
kf(0, 1200);
kf(1200, 0);

puts("\x1b[?1049h\x1b[?25l");
while (t < 6569) {
    let ph = t & 3;
    let paint = !skip;
    if (ph == 0 && t != 0) {
        let dead = curb;
        curb = tgtb;
        if ((t >> 2) + 1 < 1643) {
            kf(dead, curb);
            tgtb = dead;
        };
    };
    let thresh = ph * 64;
    for i in 0..1200 {
        let av = KB[curb + i];
        let bv = KB[tgtb + i];
        let cross = R[i] < thresh ? 1 : 0;
        F[i] = av ^ ((av ^ bv) & cross);
    };
    if (paint) {
        puts(framehome);
        paint_frame();
    };
    sched += 33333;
    let d = sched - now_us();
    skip = d <= -33333;
    if (!skip) {
        while (d > 0) {
            // keep 1 ms in hand, as the C reference does, so a small
            // overshoot cannot stretch the schedule
            nap_us(if d > 1200 { d - 1000 } else { d });
            d = sched - now_us();
        };
    };
    t ++;
};
puts("\x1b[?25h\x1b[?1049l");
