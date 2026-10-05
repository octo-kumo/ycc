// flock.y -- Reynolds' three rules over fixed-point boids: the store, the
// per-pair neighbour loop, the steering, and the integration.
//
// ===========================================================================
// WHAT THIS FILE IS
//
// Craig Reynolds' 1987 "Boids" on a torus: every boid looks at the boids
// within a radius and steers by three rules, all weighted and summed, then
// integrates:
//
//   SEPARATION  push away from each neighbour, weighted by 1/d^2, so the
//               crowding term dominates when somebody gets close;
//   ALIGNMENT   head the way the neighbours head (their mean velocity);
//   COHESION    head for the centre of mass of the neighbours.
//
// The three are deliberately separable.  A module-level MASK turns them on and
// off one at a time, which is what lets boids.y --check test each rule's SIGN
// in isolation -- and it is also a live-view key ('1', '2', '3').
//
// ===========================================================================
// THE FIXED POINT IS Q16, AND HERE IS WHY IT IS NOT Q30
//
// fx.y is Q30 and this file does use it -- but only for GEOMETRY (fx.atan2 in
// heading()), never for the store.  The reason is the neighbour loop: it forms
// (dx*dx + dy*dy) once per PAIR and takes a root of it, and that product has
// to stay inside a signed 64-bit long (fx.y's own limit, |v| <= 2^62-1).
//
//   Q30  dx = 256 units * 2^30 = 2^38   dx*dx = 2^76   OVERFLOW
//   Q16  dx = 256 units * 2^16 = 2^24   dx*dx = 2^48   fine, two terms = 2^49
//
// So the store is Q16 (1.0 == 65536), the world is capped at 256x128 whole
// units, and the squared distance is a Q32 quantity (dx*dx with both operands
// Q16), which is exactly what makes the hand-computed numbers in --check's
// separation case come out right:
//
//   d2_real = d2 / 2^32                      a Q32 value
//   sep_real = -dx_real / d2_real
//   sep_q16  = -dx_q16 * 2^32 / d2_raw        <- flock.q32()
//
// The precision is not a compromise at this scale: Q16 resolves a world unit
// to 1/65536 of it, and one unit is one character cell on screen, so the
// smallest thing a boid can do here is 60000 times finer than a pixel.  What
// Q16 could not do is hold a Q30 squared distance, which is what the neighbour
// loop needs every pair.
//
// THE TRAP THIS FILE EXISTS TO AVOID (and --check pins it): `a / b` on two
// fixed-point values is their RATIO, not a scaled quotient.  2.0 / 1.0 in Q16
// is 2, not 131072.  So there are exactly three arithmetic helpers here and NO
// bare division of a fixed-point value anywhere:
//
//   qmul(a, b) = a * b / 65536              real product, Q16 out
//   qdiv(a, b) = a * 65536 / b               real quotient, Q16 out
//   q32(a, b)  = a * 2^32 / b                quotient from the Q32 scale
//
// All three truncate toward zero, like every other rounding in fx.y.
//
// ===========================================================================
// NO ALLOCATION, EVER, AFTER blank()
//
// The Y heap is an arena and nothing is freed (ORCHESTRATOR.md 2.7), so the
// six arrays are inside one Flock record, sized at compile time by literals,
// and every temporary the hot loop needs -- the accumulator, the steering
// result, the pair tally -- is a module-level scalar, never a record literal
// and never a local array.  A record literal in the pair loop would be 48 bytes
// a PAIR; 512 boids is 130 816 pairs a step, so 6 MiB a step, and the 3.5 GiB
// cap after about 600 frames.
//
// Verify with `./boids --frames 3000 --stats`, which prints heap_used() at both
// ends of the run loop; the delta is zero.
//
// ===========================================================================
// JACOBI, NOT GAUSS-SEIDEL
//
// step() makes TWO passes over the boids: the first computes every boid's
// steering from the state as it was at the top of the step (so a boid's
// neighbours cannot see it move), the second integrates all of them in place.
// A single interleaved pass would be cheaper (one loop, no ax/ay arrays) but it
// would make boid 3 see boid 2's new velocity -- order-dependent, and much
// harder to argue about when a test asserts a hand-computed result.

import fx;

// The three rules, as bits of the live mask.
const M_SEP: long = 1;
const M_ALI: long = 2;
const M_COH: long = 4;
const M_ALL: long = 7;

const Q16: long = 65536;          // 1.0 in Q16
const Q32: long = 4294967296;     // 1.0 in Q32 -- the scale of dx*dx
const MAXB = 512;                 // boids; the array sizes below are this
const MAXW = 256;                 // world width in whole units
const MAXH = 128;                 // world height in whole units
const MINW = 8;
const MINH = 6;
const MAX_SPEED_LIMIT = 4611686018427387903;    // 2^62-1, fx.MAX

// A flock and its scratch.  Every array is fixed-size and allocated once, in
// blank(); n is the live count and always satisfies 1 <= n <= MAXB.
type Flock = {
    n: long,          // boids
    w: long,          // world width, whole units, MINW..MAXW
    h: long,          // world height, whole units, MINH..MAXH
    px: [long; 512],  // position, Q16, always inside [0, w*Q16)
    py: [long; 512],
    vx: [long; 512],  // velocity, Q16 units per step, |v| <= maxs
    vy: [long; 512],
    ax: [long; 512],  // accumulated steering for this step (pass 1)
    ay: [long; 512],
    vr2: long,        // view radius squared, Q32   (alignment + cohesion)
    sr2: long,        // separation radius squared, Q32
    vr: long,         // the same two radii in whole units, for the report
    sr: long,
    wsep: long,       // rule weights, Q16
    wali: long,
    wcoh: long,
    maxs: long,       // max speed, Q16 -- the hard clamp
    desire: long,     // DESIRED speed, Q16, <= maxs.  Reynolds has both: a
                      // flock cruises at the desired speed and only the
                      // separation spikes reach the max.  Equal to maxs unless
                      // set_desire() says otherwise, which is the case every
                      // --check world is in, so its hand-computed numbers are
                      // the simplest ones.
    maxf: long,       // max force (steering), Q16
    dt: long,         // integration scale, Q16
    gen: long,        // steps run
    pairs: long,      // neighbour pairs inside the view radius, last step
    sat: long,        // STEPS in which some velocity had to be clamped
    over: long,       // BOIDS clamped, cumulative
    vmax: long,       // largest |v| seen AFTER clamping, Q16, over the run
    vmax_now: long,   // largest |v| AFTER clamping, Q16, this frame only
    vraw: long        // largest raw |v| seen BEFORE clamping, Q16
};

// ── the accumulator, for boid i, out of the pair loop ─────────────────────
//
// These are the values accumulate() fills and rule_sum() reduces.  They are
// module level because a local array inside the pair loop would allocate once
// per call, and because --check reads them to test each rule in isolation.

let ACC_SPX: long = 0;    // separation accumulator, Q16
let ACC_SPY: long = 0;
let ACC_ALX: long = 0;    // sum of neighbour velocities, Q16
let ACC_ALY: long = 0;
let ACC_COX: long = 0;    // sum of neighbour offsets (towards the centroid), Q16
let ACC_COY: long = 0;
let ACC_NSEP: long = 0;   // neighbours inside the separation radius
let ACC_NALI: long = 0;   // neighbours inside the view radius
let ACC_IVX: long = 0;    // boid i's own velocity when the pass started
let ACC_IVY: long = 0;

// the pair loop's out-pair, from steer()
let OUT_FX: long = 0;
let OUT_FY: long = 0;

// The running pair tally.  Also module level, so the step loop can zero it and
// the report can read it without a record.
let FLK_PAIRS: long = 0;

// Which rules are live.  7 (all three) is what the flock runs on; --check
// narrows it to 1, 2 or 4 to test one rule's sign on its own.
let MASK: long = 7;

def set_mask(m: long) { MASK = m };

def mask() -> long { MASK };

def acc_sep_x() -> long { ACC_SPX };

def acc_sep_y() -> long { ACC_SPY };

def acc_ali_x() -> long { ACC_ALX };

def acc_ali_y() -> long { ACC_ALY };

def acc_coh_x() -> long { ACC_COX };

def acc_coh_y() -> long { ACC_COY };

def acc_nsep() -> long { ACC_NSEP };

def acc_nali() -> long { ACC_NALI };

def acc_fix() -> long { OUT_FX };

def acc_fiy() -> long { OUT_FY };

// ── fixed-point arithmetic ────────────────────────────────────────────────

// qmul(a, b) -> the real product a*b, in Q16.  Truncates toward zero, as
// every rounding in fx.y does.
//
// The overflow guard is not paranoia to be removed later: this is the
// innermost helper in the file and an overflow here would be a plausible wrong
// number with no trap at all.  Every call site below passes bounded operands
// (the biggest product is 2^48 against a 2^62 limit), so the guard never
// fires -- --check asserts that too, by asking for qmul of the largest values
// the simulation ever forms and getting the right answer back.
def qmul(a: long, b: long) -> long {
    let r = a * b;
    if (r > MAX_SPEED_LIMIT || r < 0 - MAX_SPEED_LIMIT) { return 0 };
    r / Q16
};

// qdiv(a, b) -> the real quotient a/b, in Q16.
//
// THIS is the function the Q16-ratio trap is about.  The bare `a / b` is the
// RATIO: 2.0 / 1.0 would come out as 2 instead of 131072.  The 65536 goes in
// the numerator, and the sign of the answer follows the sign of b (C's
// truncation toward zero, so qdiv(-1.0, 3.0) is -21845, not -21846).
//
// A zero divisor returns 0 rather than trapping.  Every call site in this
// module has a non-zero denominator (a distance, a neighbour count), so this
// is a belt for a caller that gets it wrong, not a live path.
def qdiv(a: long, b: long) -> long {
    if (b == 0) { return 0 };
    let n = a * Q16;
    if (n > MAX_SPEED_LIMIT || n < 0 - MAX_SPEED_LIMIT) { return 0 };
    n / b
};

// q32(a, b) -> a / b, in Q16, for a and b in the Q32 scale -- which is what a
// squared distance is.  sep = -dx / d2 lands here: dx is Q16, d2 is Q32, and
// the quotient wanted is Q16, so the numerator carries the Q16 -> Q32 shift.
def q32(a: long, b: long) -> long {
    if (b == 0) { return 0 };
    let n = a * Q32;
    if (n > MAX_SPEED_LIMIT || n < 0 - MAX_SPEED_LIMIT) { return 0 };
    n / b
};

// ── the root ──────────────────────────────────────────────────────────────

// isqrt(u) -> floor(sqrt(u)), exactly, for 0 <= u < 2^63.
//
// The restoring digit recurrence: two bits of the root at a time, from the
// top.  `one` walks 1<<60 down to 1<<0 by fours, `res` is the partial root so
// far and `op` the running remainder.  Exact on every perfect square and one
// below the true root on any other, which is what "floor" means.
//
// WHY NOT fx.isqrt?  Because this is the stress test: this is the root taken
// once per neighbour PAIR, tens of thousands of times a frame, and the point of
// the example is to measure that.  --check pins it against fx.isqrt over a few
// hundred inputs, including every perfect square up to 300^2.
//
// Every value here is non-negative, so the shifts are plain `>>`.  `>>>` would
// behave the same on these operands, and this file uses `>>` everywhere on
// purpose: `>>>` is a LOGICAL shift in Y, and a logical shift on a negative
// intermediate is a silent wrong number rather than a trap.
def isqrt(u: long) -> long {
    if (u < 2) { return u; };
    let op = u;
    let res = 0;
    let one = 1 << 60;
    while (one > op) { one = one >> 2; };
    while (one != 0) {
        if (op >= res + one) {
            op = op - res - one;
            res = res + (one << 1)
        };
        res = res >> 1;
        one = one >> 2
    };
    res
};

// dist(dx, dy) -> the length of the Q16 vector (dx, dy), in Q16.
//
// The scale cancels under the root, which is why no shift appears here: dx and
// dy are real*2^16, so dx*dx + dy*dy is real*2^32 and its root is real*2^16.
def dist(dx: long, dy: long) -> long {
    let d2 = dist2(dx, dy);
    if (d2 < 2) { return 0 };
    isqrt(d2)
};

// dist2(dx, dy) -> dx*dx + dy*dy, the Q32 squared length.  Split out so the
// pair loop can take ONE root per pair and reuse the square for both the
// radius tests and the separation weight.
def dist2(dx: long, dy: long) -> long { dx * dx + dy * dy };

// unit(sx, sy) -> the Q16 unit vector along (sx, sy), in OUT_NX/OUT_NY.  A
// zero vector has no direction, so it answers (0,0).
//
// THIS FUNCTION IS THE RATIO TRAP AGAIN, IN ITS OTHER FORM.  Both operands are
// Q16, so the bare `sx / l` is the RATIO -- for a 3-4-5 triangle it is 3/5 = 0,
// and the "unit vector" comes out as the zero vector.  The Q16 has to be
// multiplied into the numerator, once per axis:
//     -7864 * 65536 / 13106 = -39325     (the unit x of (-0.12, -0.16))
// and steer() below does the same thing with maxs in place of Q16.
let OUT_NX: long = 0;
let OUT_NY: long = 0;

def unit(sx: long, sy: long) {
    let l = dist(sx, sy);
    let nx = 0;
    let ny = 0;
    if (l > 0) {
        nx = (sx * Q16) / l;
        ny = (sy * Q16) / l
    };
    OUT_NX = nx;
    OUT_NY = ny
};

// ── the torus ─────────────────────────────────────────────────────────────

// wrap_delta(d, span) -> d shortened to the shortest signed way round a torus
// of `span` whole units.  A boid 3 units behind another on a 10-unit world is
// 3 units behind, not 7 ahead.
def wrap_delta(d: long, span: long) -> long {
    let s = span * Q16;
    let half = s / 2;
    if (d > half) { return d - s; };
    if (d < 0 - half) { return d + s; };
    d
};

// wrap_pos(p, span) -> p inside [0, span*Q16).  One correction is always
// enough, and set_limits() is what guarantees it: the max speed is capped at a
// quarter of the smaller world side, so a step can never travel half the world.
def wrap_pos(p: long, span: long) -> long {
    let s = span * Q16;
    if (p >= s) { return p - s; };
    if (p < 0) { return p + s; };
    p
};

// ── construction ──────────────────────────────────────────────────────────

// blank(w, h, n) -> a flock of n boids in a w x h world, all still, at the
// origin, with the rules at zero.  The ONLY allocation this module makes: six
// 512-long arrays inside one record.
//
// Out-of-range arguments are clamped here rather than trusted.  A 0 boids
// would make every mean a division by zero, and a 513 would be an
// out-of-bounds TRAP on some later frame -- and a trap prints to STDOUT, which
// silently corrupts a golden file instead of announcing itself.
def blank(w: long, h: long, n: long) -> Flock {
    let k = n;
    if (k < 1) { k = 1; };
    if (k > MAXB) { k = MAXB; };
    let vw = MINW;
    let vh = MINH;
    if (w > MINW) { vw = w; };
    if (h > MINH) { vh = h; };
    if (vw > MAXW) { vw = MAXW; };
    if (vh > MAXH) { vh = MAXH; };
    {
        n: k,
        w: vw,
        h: vh,
        px: [0; 512],
        py: [0; 512],
        vx: [0; 512],
        vy: [0; 512],
        ax: [0; 512],
        ay: [0; 512],
        vr2: 0,
        sr2: 0,
        vr: 1,
        sr: 1,
        wsep: 0,
        wali: 0,
        wcoh: 0,
        maxs: 0,
        desire: 0,
        maxf: 0,
        dt: 0,
        gen: 0,
        pairs: 0,
        sat: 0,
        over: 0,
        vmax: 0,
        vmax_now: 0,
        vraw: 0
    }
};

// set_view(s, r) -- the view radius in whole units, squared once here into the
// Q32 the pair loop tests against.  The unit value is kept too, so the report
// can print the radius that was asked for instead of taking a root to recover
// it (which is exact, but a needless 32 iterations a frame).
def set_view(s: Flock, r: long) {
    let v = r;
    if (v < 1) { v = 1; };
    if (v > MAXW) { v = MAXW; };
    let q = v * Q16;
    s.vr2 = q * q;
    s.vr = v
};

// set_sep(s, r) -- the separation radius in whole units.
def set_sep(s: Flock, r: long) {
    let v = r;
    if (v < 1) { v = 1; };
    if (v > MAXW) { v = MAXW; };
    let q = v * Q16;
    s.sr2 = q * q;
    s.sr = v
};

// mask_name(m) -> the live rules as text, for the report and the status line.
// "none" is a real answer, not an error: pressing '1' twice leaves a flock with
// every rule off, and it flies straight.
def mask_name(m: long) -> str {
    if ((m & M_ALL) == 0) { return "none -- the flock flies straight" };
    let s = "";
    if ((m & M_SEP) != 0) { s = s + "sep" };
    if ((m & M_ALI) != 0) {
        if (len(s) > 0) { s = s + "+" };
        s = s + "ali"
    };
    if ((m & M_COH) != 0) {
        if (len(s) > 0) { s = s + "+" };
        s = s + "coh"
    };
    s
};


// set_weights(s, sep, ali, coh) -- Q16 weights.  A negative weight is a
// mistake, not an inversion, so it clamps to zero.
def set_weights(s: Flock, sep: long, ali: long, coh: long) {
    s.wsep = if (sep < 0) { 0 } else { sep };
    s.wali = if (ali < 0) { 0 } else { ali };
    s.wcoh = if (coh < 0) { 0 } else { coh }
};

// set_limits(s, max_speed, max_force, dt) -- all Q16.  The max speed is also
// capped at a quarter of the smaller world side, which is what makes
// wrap_pos()'s single correction correct; the force at sixteen times that,
// which is enough headroom for a rule sum to be clamped rather than
// dominated by its own clamp.
def set_limits(s: Flock, max_speed: long, max_force: long, dt: long) {
    let room = (if (s.w < s.h) { s.w } else { s.h }) / 4;
    let cap = room * Q16;
    let m = max_speed;
    if (m < Q16 / 16) { m = Q16 / 16; };
    if (m > cap) { m = cap; };
    s.maxs = m;
    s.desire = m;
    let f = max_force;
    if (f < 0) { f = 0; };
    if (f > cap * 16) { f = cap * 16; };
    s.maxf = f;
    let d = dt;
    if (d < 0) { d = 0; };
    if (d > Q16 * 4) { d = Q16 * 4; };
    s.dt = d
};

// copy_params(dst, src) -- carry the RULES and the LIMITS from one flock to
// another, leaving the birds alone.
//
// The live view rebuilds its flock when the window changes, and the new one has
// to behave like the old one or a resize would silently reset the radii, the
// weights and the speed cap.  Seven fields, written out rather than looped over,
// because a record is not iterable in this language.
def copy_params(dst: Flock, src: Flock) {
    dst.w = src.w;
    dst.h = src.h;
    dst.vr2 = src.vr2;
    dst.sr2 = src.sr2;
    dst.vr = src.vr;
    dst.sr = src.sr;
    dst.wsep = src.wsep;
    dst.wali = src.wali;
    dst.wcoh = src.wcoh;
    dst.maxs = src.maxs;
    dst.desire = src.desire;
    dst.maxf = src.maxf;
    dst.dt = src.dt
};

// set_desire(s, d) -- the DESIRED cruising speed, Q16, clamped to the max speed.
// Every rule steers toward "the neighbours' direction at the desired speed",
// so this is what a settled flock's mean |v| settles at, and s.maxs is only
// ever touched by the clamp in step().  With desire == maxs (the default, and
// what every --check world uses) the flock cruises AT the limit, which makes
// the clamp fire on almost every boid every step and the "max |v|" column of
// the table read 1.39 forever.
def set_desire(s: Flock, d: long) {
    let v = d;
    if (v < 0) { v = 0; };
    if (v > s.maxs) { v = s.maxs; };
    s.desire = v
};

// place(s, i, x, y, pvx, pvy) -> put boid i at whole-unit position (x, y)
// with Q16 velocity (pvx, pvy).  The position is wrapped, so a caller may
// place one anywhere in the world including the far corner.
//
// False for an index outside the flock, rather than trapping: a caller that
// gets this wrong wants a message, not a stdout-corrupting runtime error.  The
// live view's reseed and every --check case go through here, so "the world I
// asked for" and "the world the simulation has" cannot drift apart.
def place(s: Flock, i: long, x: long, y: long, pvx: long, pvy: long) -> bool {
    if (i < 0 || i >= s.n) { return false; };
    s.px[i] = wrap_pos(x * Q16, s.w);
    s.py[i] = wrap_pos(y * Q16, s.h);
    s.vx[i] = pvx;
    s.vy[i] = pvy;
    true
};

// ── the rule pass ─────────────────────────────────────────────────────────

// steer(sx, sy, vx, vy, speed, maxf) -- Reynolds' steering: the desired
// VELOCITY is (sx, sy) normalized to `speed` (the flock's DESIRED speed, not
// its max -- see set_desire), and the force is that minus what the boid is
// already doing, clamped to the max force.
//
// A zero (sx, sy) has no direction to prefer, so the force is zero -- NOT
// "stop", which is what normalizing a zero vector to (0,0) and subtracting
// the velocity would give.  That matters for alignment: a flock that is
// perfectly still has nothing to align to, and no force is the honest answer.
//
// The answer leaves in OUT_FX/OUT_FY rather than in a record: this runs up to
// three times a BOID inside the hot loop, and a record literal here would be
// 48 bytes a call.
def steer(sx: long, sy: long, vx: long, vy: long, maxs: long, maxf: long) {
    let l = dist(sx, sy);
    let ux = 0;
    let uy = 0;
    if (l > 0) {
        // (sx/l) is the unit vector in Q16 and maxs is a Q16 speed, so the
        // product is Q32 and one / Q16 brings it back.  Folding it into a
        // single (sx * maxs) / l keeps the truncation to ONE rounding instead
        // of two, which matters because this is the hot path.
        let dx = (sx * maxs) / l;
        let dy = (sy * maxs) / l;
        ux = dx - vx;
        uy = dy - vy;
        let ul = dist(ux, uy);
        if (ul > maxf && ul > 0) {
            ux = (ux * maxf) / ul;
            uy = (uy * maxf) / ul
        }
    };
    OUT_FX = ux;
    OUT_FY = uy
};

// accumulate(s, i) -- ONE BOID'S WHOLE NEIGHBOURHOOD, into the module-level
// ACC_* slots.
//
// This is the inner loop of the example and the reason the example exists:
// n^2/2 pairs, and for each of them a distance SQUARED here and a root taken
// later in steer().  The three rules share the pair:
//
//   inside the separation radius   the 1/d^2 repulsion, and ACC_NSEP++
//   inside the view radius         the neighbour's velocity into ACC_AL*, and
//                                  its offset from i into ACC_CO*, so that
//                                  ACC_CO/n is the way to the centre of mass
//
// ACC_AL* and ACC_CO* are SUMS, not means: the mean is taken once per BOID in
// rule_sum(), not once per pair.
//
// Both radius tests are strict (d2 < r2), so a pair exactly ON the radius is
// outside it.  --check pins that boundary: a bird exactly `view` units from
// the probe is not a view neighbour.  Two birds on the same cell (d2 == 0)
// are counted as neighbours but contribute no separation, since 1/0 is not a
// direction.
def accumulate(s: Flock, i: long) {
    ACC_SPX = 0;
    ACC_SPY = 0;
    ACC_ALX = 0;
    ACC_ALY = 0;
    ACC_COX = 0;
    ACC_COY = 0;
    ACC_NSEP = 0;
    ACC_NALI = 0;
    ACC_IVX = s.vx[i];
    ACC_IVY = s.vy[i];
    let pairs = 0;
    let ix = s.px[i];
    let iy = s.py[i];
    let k = 0;
    while (k < s.n) {
        if (k != i) {
            let dx = wrap_delta(s.px[k] - ix, s.w);
            let dy = wrap_delta(s.py[k] - iy, s.h);
            let d2 = dist2(dx, dy);
            if (d2 < s.vr2) {
                pairs = pairs + 1;
                ACC_NALI = ACC_NALI + 1;
                ACC_ALX = ACC_ALX + s.vx[k];
                ACC_ALY = ACC_ALY + s.vy[k];
                ACC_COX = ACC_COX + dx;
                ACC_COY = ACC_COY + dy;
                if (d2 < s.sr2 && d2 > 0) {
                    ACC_NSEP = ACC_NSEP + 1;
                    // -dx / d2, weighted by nothing else: the crowding term.
                    ACC_SPX = ACC_SPX + q32(0 - dx, d2);
                    ACC_SPY = ACC_SPY + q32(0 - dy, d2)
                }
            }
        };
        k = k + 1
    };
    FLK_PAIRS = FLK_PAIRS + pairs
};

// rule_sum(s) -- reduce the ACC_* slots into OUT_FX/OUT_FY: the three rules,
// each weighted, summed, and the SUM clamped to the max force as well (each
// individual steering is already clamped inside steer()).
//
// This is the sign-sensitive part, and it is what --check reads for a rule on
// its own.  A rule whose neighbour count is zero contributes nothing at all:
// cohesion of one boid is undefined, and no force is the honest answer.
def rule_sum(s: Flock) {
    let fx = 0;
    let fy = 0;
    if ((MASK & M_SEP) != 0 && ACC_NSEP > 0) {
        let cx = ACC_SPX / ACC_NSEP;
        let cy = ACC_SPY / ACC_NSEP;
        steer(cx, cy, ACC_IVX, ACC_IVY, s.desire, s.maxf);
        fx = fx + qmul(OUT_FX, s.wsep);
        fy = fy + qmul(OUT_FY, s.wsep)
    };
    if ((MASK & M_ALI) != 0 && ACC_NALI > 0) {
        let ax = ACC_ALX / ACC_NALI;
        let ay = ACC_ALY / ACC_NALI;
        steer(ax, ay, ACC_IVX, ACC_IVY, s.desire, s.maxf);
        fx = fx + qmul(OUT_FX, s.wali);
        fy = fy + qmul(OUT_FY, s.wali)
    };
    if ((MASK & M_COH) != 0 && ACC_NALI > 0) {
        let ox = ACC_COX / ACC_NALI;
        let oy = ACC_COY / ACC_NALI;
        steer(ox, oy, ACC_IVX, ACC_IVY, s.desire, s.maxf);
        fx = fx + qmul(OUT_FX, s.wcoh);
        fy = fy + qmul(OUT_FY, s.wcoh)
    };
    let fl = dist(fx, fy);
    if (fl > s.maxf && fl > 0) {
        fx = (fx * s.maxf) / fl;
        fy = (fy * s.maxf) / fl
    };
    OUT_FX = fx;
    OUT_FY = fy
};

// step(s) -- one Jacobi step: every boid's steering from the state at the top
// of the step, then every boid integrated in place.
//
// The velocity clamp is COUNTED, not just applied.  `s.over` records how many
// boids the clamp caught and `s.sat` how many STEPS it bit in, which is what
// makes --check's clamping assertion non-vacuous: "no boid ever exceeded max
// speed" is a true statement about a flock that never went near the limit, and
// `over > 0` is the proof that the limit was actually reached.  `s.vraw` keeps
// the largest pre-clamp length, so a test can see how far over it went.
def step(s: Flock) {
    FLK_PAIRS = 0;
    let i = 0;
    while (i < s.n) {
        accumulate(s, i);
        rule_sum(s);
        s.ax[i] = OUT_FX;
        s.ay[i] = OUT_FY;
        i = i + 1
    };
    s.pairs = FLK_PAIRS;
    let clamped = 0;
    let vmax = 0;
    i = 0;
    while (i < s.n) {
        let nvx = s.vx[i] + qmul(s.ax[i], s.dt);
        let nvy = s.vy[i] + qmul(s.ay[i], s.dt);
        let raw = dist(nvx, nvy);
        if (raw > s.maxs && raw > 0) {
            nvx = (nvx * s.maxs) / raw;
            nvy = (nvy * s.maxs) / raw;
            clamped = clamped + 1
        };
        if (raw > s.vraw) { s.vraw = raw; };
        let al = dist(nvx, nvy);
        if (al > vmax) { vmax = al; };
        s.vx[i] = nvx;
        s.vy[i] = nvy;
        s.px[i] = wrap_pos(s.px[i] + qmul(nvx, s.dt), s.w);
        s.py[i] = wrap_pos(s.py[i] + qmul(nvy, s.dt), s.h);
        i = i + 1
    };
    s.over = s.over + clamped;
    if (clamped > 0) { s.sat = s.sat + 1 };
    if (vmax > s.vmax) { s.vmax = vmax; };
    s.vmax_now = vmax;
    s.gen = s.gen + 1
};

// ── reading the state ─────────────────────────────────────────────────────

// speed(i) -> |v| in Q16, or 0 for an index outside the flock.
def speed(s: Flock, i: long) -> long {
    if (i < 0 || i >= s.n) { return 0 };
    dist(s.vx[i], s.vy[i])
};

// heading(i) -> the velocity angle in hundredths of a degree, 0..35999,
// measured from +x towards +y.  fx.atan2 does the quadrant work; the Q16
// argument is lifted to Q30 by the 14-bit shift, and the Q30 answer comes
// back in degrees and is scaled by 100 with a fixed divisor (2^30/100,
// rounded down to 10737418 -- 0.02% low, which cannot move a glyph).
def heading(s: Flock, i: long) -> long {
    if (i < 0 || i >= s.n) { return 0 };
    let a = fx.atan2(s.vy[i] << 14, s.vx[i] << 14);
    if (a < 0) { a = a + fx.TWO_PI; };
    fx.to_deg(a) / 10737418
};

// mean_speed() -> the flock's mean |v|, in Q16.
def mean_speed(s: Flock) -> long {
    if (s.n < 1) { return 0 };
    let t = 0;
    let i = 0;
    while (i < s.n) {
        t = t + dist(s.vx[i], s.vy[i]);
        i = i + 1
    };
    t / s.n
};

// mean_order() -> the flock's mean neighbour count, in Q16: the total view
// pairs the last step saw, divided by the boid count.  This is the number that
// says whether the flock is a flock (a few neighbours each) or a dust cloud
// (nobody sees anybody) -- and it is what the three-rule sign tests move.
//
// It comes out in Q16 like every other measured quantity, so report.y can
// format it with the same rb_fixed() as a speed.  (It was hundredths once, and
// report.rb_fixed() then divided it by 65536 a second time: a table that read
// "ord 0.01" for a flock with 7.85 neighbours each.)
def mean_order(s: Flock) -> long {
    if (s.n < 1) { return 0 };
    s.pairs * Q16 / s.n
};

// span_x() -> max(x) - min(x) in whole units, the NON-wrapping span.
// --check uses it for the "a line spreads" assertion, where the flock is known
// not to straddle the wrap point; the headless report says "span x", never
// "width", so the two are not confused.
def span_x(s: Flock) -> long {
    if (s.n < 1) { return 0 };
    let lo = s.px[0];
    let hi = s.px[0];
    let i = 1;
    while (i < s.n) {
        if (s.px[i] < lo) { lo = s.px[i]; };
        if (s.px[i] > hi) { hi = s.px[i]; };
        i = i + 1
    };
    (hi - lo) / Q16
};

// in_bounds() -> true when every boid's position is inside the world.  A step
// that got the wrap wrong shows up here and nowhere else, so --check asks
// after every frame of the long run.
def in_bounds(s: Flock) -> bool {
    let i = 0;
    while (i < s.n) {
        if (s.px[i] < 0 || s.px[i] >= s.w * Q16) { return false; };
        if (s.py[i] < 0 || s.py[i] >= s.h * Q16) { return false; };
        i = i + 1
    };
    true
};

// mix(h, v) -- one mixing step of digest(): a multiply by 131 and a shift-xor,
// sized so no intermediate can overflow a signed long (x stays under 2^46, so
// x*131 is under 2^53, against a 2^62 ceiling).
def mix(h: long, v: long) -> long {
    let x = (h + (v & 2097151) + 40503) & 70368744177663;
    x = (x * 131) & 70368744177663;
    x ^ (x >> 19)
};

// digest(s) -> a 46-bit checksum over every position and velocity, for "same
// seed, same run".
//
// This is not a hash for security and does not need to be.  What it has to
// catch is a one-unit difference in one boid after 300 frames, and it has to
// be a function of the WHOLE state: two runs that agree on every aggregate
// (mean speed, pair count, span) but differ in the state would otherwise look
// identical, which is the vacuous pass this check is written to avoid.
def digest(s: Flock) -> long {
    let h = 1125899906842625;
    let i = 0;
    while (i < s.n) {
        h = mix(h, s.px[i]);
        h = mix(h, s.py[i]);
        h = mix(h, s.vx[i]);
        h = mix(h, s.vy[i]);
        i = i + 1
    };
    h = mix(h, s.n);
    h = mix(h, s.gen);
    h = mix(h, s.w);
    h = mix(h, s.h);
    if (h == 0) { 1 } else { h }
};

// diff(a, b) -> how many of a's boids differ from b's in position or
// velocity.  Two flocks built the same way and stepped the same number of
// times must answer 0; two built from different seeds must not.  --check
// asserts BOTH, which is what stops the comparison from passing vacuously when
// nothing was ever compared at all.
def diff(a: Flock, b: Flock) -> long {
    if (a.n != b.n) { return 1000000; };
    let d = 0;
    let i = 0;
    while (i < a.n) {
        if (a.px[i] != b.px[i] || a.py[i] != b.py[i]
            || a.vx[i] != b.vx[i] || a.vy[i] != b.vy[i]) { d = d + 1; };
        i = i + 1
    };
    d
}

// ── the deterministic seed ────────────────────────────────────────────────

// The generator is Lehmer's MINSTD (the "minimal standard"), state held in
// 1..2^31-2 and stepped by state = state * 48271 mod (2^31-1).  Chosen over a
// 64-bit xorshift for one reason: state * 48271 is under 1.03e14, so no
// multiplication in it can overflow, and there is no masking to get wrong.
//
// Deterministic across both compilers and every frame count, which is what the
// gate needs; the period (2^31-2) is far longer than any run here needs.

const RNG_M: long = 2147483647;
const RNG_A: long = 48271;
const RNG_MOD48: long = 2147483646;

let RNG: long = 1;

def rng_seed(seed: long) {
    let k = seed % RNG_MOD48;
    if (k < 1) { k = 1 };
    RNG = (k * RNG_A) % RNG_M
};

def rng_next() -> long {
    RNG = (RNG * RNG_A) % RNG_M;
    RNG
};

// rng_below(n) -> a value in 0..n-1, for n >= 1.  MINSTD's low bits are its
// weakest, so this folds in a second draw before the modulo -- the residue of a
// single multiply is visibly banded, and a flock that starts in stripes looks
// like a flock that started striped.
def rng_below(n: long) -> long {
    if (n < 1) { return 0 };
    let a = rng_next();
    let b = rng_next();
    (a ^ (b >> 7)) % n
};

// seed_flock(s, seed, speed_lo, speed_hi) -- scatter every boid with a
// pseudo-random position and a pseudo-random direction at a speed in
// [speed_lo, speed_hi] Q16 units/step, all inside the world.
//
// The direction is unit()'d and then scaled, rather than the direction being
// scaled first, because that is the order that keeps the ratio trap out: two
// Q16 values divided is a ratio.  The root here is the same dist() the pair
// loop uses, deliberately -- this is the example's own arithmetic, not a
// special case for setup.
def seed_flock(s: Flock, seed: long, speed_lo: long, speed_hi: long) {
    rng_seed(seed);
    let k = 0;
    while (k < s.n) {
        let x = rng_below(s.w);
        let y = rng_below(s.h);
        let ux = rng_below(2001) - 1000;
        let uy = rng_below(2001) - 1000;
        unit(ux * Q16, uy * Q16);
        let sp = speed_lo;
        if (speed_hi > speed_lo) { sp = speed_lo + rng_below(speed_hi - speed_lo); };
        s.px[k] = x * Q16;
        s.py[k] = y * Q16;
        s.vx[k] = (OUT_NX * sp) / Q16;
        s.vy[k] = (OUT_NY * sp) / Q16;
        let l = dist(s.vx[k], s.vy[k]);
        if (l > s.vmax_now) { s.vmax_now = l; };
        k = k + 1
    };
    s.vmax = s.vmax_now;
    s.gen = 0
};