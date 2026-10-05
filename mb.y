import fx;
// Mandelbrot in Q30 fixed point: does it run fast enough?
def mb(w: long, h: long, maxit: long) -> long {
    let cnt = 0;
    let y = 0;
    while (y < h) {
        let ci = ((2 * y * fx.ONE) / h) - fx.ONE;
        let x = 0;
        while (x < w) {
            let cr = ((2 * x * fx.ONE) / w) - fx.ONE * 3 / 4;
            let zr = 0; let zi = 0;
            let i = 0;
            let alive = true;
            while (i < maxit && alive) {
                let nzr = zr * zr - zi * zi + cr;
                zi = 2 * zr * zi + ci;
                zr = nzr;
                if (zr * zr + zi * zi > 4 * fx.ONE * fx.ONE) { alive = false; }
                else { i = i + 1; };
            };
            cnt = cnt + i;
            x = x + 1;
        };
        y = y + 1;
    };
    cnt
};
let t0 = time.clock_us();
let r = mb(80, 30, 50);
let t1 = time.clock_us();
print("80x30 maxit50: ", t1 - t0, " us   checksum=", r);
let t2 = time.clock_us();
let r2 = mb(200, 60, 200);
let t3 = time.clock_us();
print("200x60 maxit200:", t3 - t2, " us   checksum=", r2);
