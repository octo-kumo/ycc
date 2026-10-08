// bench/y/records.y — records in arrays: field reads and writes through an
// index, records passed to and returned from defs, and a running aggregate.
type P = { x: long, y: long, vx: long, vy: long };
def step(p: P, k: long) -> P {
    { x: p.x + p.vx * k % 7, y: p.y + p.vy - k % 3, vx: p.vx, vy: p.vy }
};
def run(n: long) -> long {
    let ps: [P] = [];
    for i in 0..256 { ps += { x: i, y: i * 2, vx: i % 5 - 2, vy: i % 3 - 1 }; };
    let acc = 0;
    for r in 0..n {
        for i in 0..256 {
            ps[i] = step(ps[i], r);
            ps[i].vx = ps[i].vx + (r & 1) * 2 - 1;
            acc = acc + ps[i].x - ps[i].y;
        };
    };
    acc
};
print(run(12000));
