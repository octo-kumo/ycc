// badapple160x60.y -- Bad Apple!! in your terminal, 160x60 cells (30 fps).
//
// The original player's rendering logic is REPLACED by the termblocks
// matcher: every 4x8 pixel cell is drawn with the Hamming-optimal
// (character, fg/bg-flip) pair over the 284-mask charset.  The pixel ->
// text renderer (matching, colors, SGR/UTF-8 emission, row diffing)
// lives in tbrender.y, imported below -- this file is the video side:
// arithmetic decoder, keyframe crossfade, 16x bilinear upscaler, pacing.
//
// Build:  ycc -o badapple160x60 badapple160x60.y   (needs tbrender.y and
//                                                    s40x30 next to it)
// Run:    ./badapple160x60 [--color=mono|gray|green|amber|ice]

import tbrender;

embed DATA from "s40x30";

let KB: [byte; 2400] = [0; 2400];
let F: [byte; 1200] = [0; 1200];
let R: [byte; 1200] = [0; 1200];
let P: [long; 8] = [0; 8];
let ts: [long; 2] = [0; 2];
let framehome = "\x1b[1;1H";
let dpos = 0;
let dcur = 0;
let dbits = 0;
let clo = 0;
let chi = 0;
let ccode = 0;
def set_tables() {
    for i in 0..1200 {
        R[i] = ((i * 2654435761) & 4294967295) >> 24;
    };
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
        tbrender.tb_row_reset();
        for x in 0..160 {
            // One cell at a time, all 8 subpixel rows inside: the mask and
            // the two soft-coverage sums then live in locals instead of
            // being read back and written out once per subpixel row.
            let m = 0;
            let sv = 0;
            let sm = 0;
            for i in 0..8 {
                let yy = y * 8 + i;
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
                    let bit = if v >= 32 { 1 } else { 0 };
                    m = m | (bit << (i * 4 + k));
                    sv = sv + v;
                    sm = sm + bit * v;
                };
            };
            tbrender.tb_paint(m, sv, sm);
        };
        tbrender.tb_row_flush(y + 1);
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
tbrender.tb_init();

let args = argv();
for i in 1..len(args) {
    let s = args[i];
    let r = tbrender.tb_opt(s);
    if (r == -1) {
        puts("badapple -- Bad Apple!! at 160x60 cells, 30 fps\n");
        tbrender.tb_print_usage();
        exit(0);
    };
    if (r == 0) {
        if (len(s) > 0) {
            if (byte_at(s, 0) == 45) {
                puts("badapple: unknown option '");
                puts(s);
                puts("'\n");
                tbrender.tb_print_usage();
                exit(1);
            };
        };
    };
};

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
