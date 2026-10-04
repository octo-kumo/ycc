embed DATA from "s40x30.bin";

let KB: [byte; 2400] = [0; 2400];
let F: [byte; 1200] = [0; 1200];
let R: [byte; 1200] = [0; 1200];
let cm: [long; 160] = [0; 160];
let obuf: [byte; 2080] = [0; 2080];
let cup: [byte; 7] = [0; 7];
let pbuf: [byte; 124800] = [0; 124800];
let plen: [long; 60] = [0; 60];
let P: [long; 8] = [0; 8];
let QT: [long; 16] = [32, 0x2597, 0x2596, 0x2584, 0x259d, 0x2590, 0x259e, 0x259f, 0x2598, 0x259a, 0x258c, 0x2599, 0x2580, 0x259c, 0x259b, 0x2588];
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
    cup[0] = 27; cup[1] = 91; cup[4] = 59; cup[5] = 49; cup[6] = 72;
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

def paint_frame() -> void {
    for y in 0..60 {
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
            for x in 0..160 {
                let m = 0;
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
                    m = m | (bit << k);
                };
                if (i == 0) { cm[x] = m; } else { cm[x] = cm[x] | (m << (i * 4)); };
            };
        };
        let o = 0;
        let lasto = -1;
        for x in 0..160 {
            let m = cm[x];
            let g = cls(m);
            let f = 0;
            if (g == 0) {
                m = m ^ 4294967295;
                g = cls(m);
                f = 1;
            };
            if (g == 0) {
                if (ink(cm[x]) > 16) { f = 1; m = cm[x] ^ 4294967295; }
                else { f = 0; m = cm[x]; };
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
        let rl = o;
        let base = y * 2080;
        let n = 0;
        for i in 0..rl {
            let nv = obuf[i];
            n = n | (pbuf[base + i] ^ nv);
            pbuf[base + i] = nv;
        };
        if (n != 0 || rl != plen[y]) {
            let tens = (y + 1) / 10;
            cup[2] = 48 + tens;
            cup[3] = 48 + (y + 1) - tens * 10;
            syscall(1, 1, &cup[0], 7);
            syscall(1, 1, &obuf[0], rl);
            plen[y] = rl;
        };
    };
};

let curb = 0;
let tgtb = 1200;
let sched = clock_us();
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
    let d = sched - clock_us();
    skip = d <= -33333;
    if (!skip) {
        while (d > 0) {
            sleep(d / 1000000);
            d = sched - clock_us();
        };
    };
    t ++;
};
puts("\x1b[?25h\x1b[?1049l");
