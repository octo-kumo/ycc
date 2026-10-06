// sim.y -- Jos Stam's stable-fluids solver on a collocated grid, in integer
// Q30 fixed point, with nothing on the heap after start-up.
//
// ===========================================================================
// WHAT IS HERE
//
// One Euler step of Stam's "Stable Fluids" (SIGGRAPH 1999), in the order the
// paper gives it:
//
//   0  external forces      the emitter: a stirrer the user steers
//   1  viscosity            (I - nu dt laplacian) u = u, by Jacobi sweeps
//   2  project              make the field divergence-free with a pressure
//                           solve: div -> Poisson for p -> subtract grad p
//   3  advect               semi-Lagrangian: u(x) <- u(x - dt u(x))
//   4  vorticity confinement  the small force that feeds eddies back
//   5  project              again, because advection is not divergence-free
//   6  damping and dye decay
//
// Steps 2 and 5 are the same function called twice; that is Stam's order and
// it is what "stable" means -- every operator is unconditionally stable, so a
// big dt does not explode, it just diffuses.
//
// The two solvers are Jacobi for the viscous term and Gauss-Seidel for the
// pressure, which is exactly what Stam's code does: lin_solve() is Jacobi, and
// project()'s inner loop updates p in place.  Gauss-Seidel converges about
// twice as fast per sweep and this is a sequential program, so "about twice as
// fast" is exactly what it is here.  The sweep direction never changes, so the
// whole solver is deterministic to the bit.
//
// ===========================================================================
// THE TWO RULES THAT MAKE IT FIT IN THE LANGUAGE
//
// 1.  NO BREAK, NO CONTINUE (ORCHESTRATOR.md 2.9).  Every stencil below is
//     written straight out of the four/five neighbour loads it needs, because
//     the 3x3 loop you would reach for first needs a `continue` to skip the
//     centre cell -- and a guarded body is eight extra branches per cell in the
//     hottest loop in the program.  Where an early exit IS wanted (the emitter
//     falls off the edge of its radius; the advection backtrace clamps) the
//     idiom is the other verified one: a guard flag plus an explicit terminal
//     assignment, or a positive `if` around the whole body.
//
// 2.  NOTHING ALLOCATES (ORCHESTRATOR.md 2.7).  The heap is an arena; nothing
//     is ever freed.  Every array here is a fixed [long; MAXN] inside one
//     record, built once by new() -- 9 arrays, 2.25 MiB, for the whole life of
//     the program.  A step contains no array literal, no record literal and no
//     string.  The configuration is a record built ONCE by the caller and
//     passed in by reference, because a record literal written at the call
//     site would be a 64-byte leak per step.  `./fluid --frames 10000
//     --stats` prints heap_used() at both ends; the delta is zero.
//
// ===========================================================================
// THE OVERFLOW STRATEGY, WRITTEN DOWN (this is the part that bites)
//
// Y has no float -> long and no cast syntax at all (ORCHESTRATOR.md 2.4a), so
// every quantity here is a `long` in Q30: the real value v is held as
// v * 2^30, and fx.ONE = 1073741824 is one.  `long` is signed 64-bit, so
// |x| <= 2^63-1 is the hard limit and Q30 leaves 33 bits of integer part --
// but a product of two Q30 values is Q60 and a THIRD factor is instant death.
// The units in play are:
//
//     u, v        velocity, cells per step, Q30.  Clamped to +-4 cells/step,
//                 so |u| <= 2^32 and the interior sum of four of them is < 2^34.
//     p, div      pressure and divergence, Q30 of the same units.  |p| grows
//                 like the velocity, so it is clamped to the same envelope.
//     dye         density in [0, 1], Q30.
//
// Three rules keep every intermediate inside 62 bits:
//
//   (a) SQUARE ONLY AFTER SHIFTING DOWN.  A squared speed needs a square root
//       (energy, max speed, the vorticity normal), and sqrt(x) is computed from
//       x.  So the operands are shifted down by 17 bits before squaring and the
//       answer shifted back up: the quantity asked of fx.isqrt is then at most
//       2^31, not 2^64.  See speed() and energy().
//
//   (b) EVERY COEFFICIENT IS Q16, NEVER Q30.  Viscosity, confinement epsilon,
//       damping, decay, emitter strength and the bilinear weight are all Q16
//       (65536 == 1.0) even though the fields they multiply are Q30.  A
//       Q30 coefficient would make every one of those products Q60.  With a
//       Q16 coefficient the worst product is
//
//           field (2^34) * coefficient (2^20, since every coefficient is
//                                  validated to be <= 100.0 == 2^22.6)
//                                                      = 2^56
//
//       which has seven bits of headroom, and the products are taken one factor
//       at a time with a `>> 16` between them so nothing ever forms a triple
//       product at all.
//
//   (c) THE VELOCITY CLAMP IS THE BACKSTOP.  |u|, |v| <= 4 cells/step is
//       enforced after every operator that can add to them.  With the clamp in
//       force the magnitudes in (a) and (b) above are GUARANTEES, not
//       estimates: no combination of --viscosity, --vort and --ink can produce
//       a value the arithmetic cannot hold.
//
// The one place where a division could trap is the emitter's swirl (it divides
// by the distance from the emitter centre) and the vorticity normal (it divides
// by |grad|omega||).  Both guard: the emitter skips its own centre cell, and the
// normal falls back to zero where |grad|omega|| is zero.  There is no division
// by a user-supplied number anywhere -- --iters, --size and --seed are all
// validated in fluid.y before a grid is built, so --iters 0 skips the solve
// instead of dividing by it and --size 0x0 is refused rather than divided by.
//
// ===========================================================================
// THE GRID
//
// Collocated (velocities and pressure on cell centres), with one ghost border
// on each side.  Logical cell (x, y), 0 <= x < w, 0 <= y < h, lives at padded
// index (y+1)*sw + (x+1), so the four stencil neighbours are i+-1 and i+-sw
// with no arithmetic at all and no `%`.  sw = w+2, sh = h+2, n = sw*sh, and
// the store is sized 32768 so the largest legal grid (250x120 interior ->
// 252x122 = 30744 padded cells) fits with room to spare.
//
// BOUNDARY: free slip.  On the left and right walls u is negated and v copied;
// on the top and bottom walls v is negated and u copied.  A free-slip wall does
// not add or remove mass -- which is why the dye mass in the summary is
// conserved to the few per cent that semi-Lagrangian advection costs -- and
// it is the boundary under which the pressure Poisson problem with Neumann
// conditions (dp/dn = 0) is solvable at all.  p gets the same borders without
// the sign flip.  Note that Neumann pressure has a one-dimensional nullspace
// (the constant), which is harmless: the velocity update subtracts the
// GRADIENT of p, and the gradient of a constant is zero.

import fx;
import random;

// The store size.  A type position takes an integer LITERAL only, not a const,
// so the array types below spell 32768 out; the constants carry the same values
// for the reader and for arithmetic.
const MAXN = 32768;
const MAXW = 250;
const MAXH = 120;

// The velocity envelope, 4 cells per step in Q30 = 4 * 2^30.  This is the
// backstop every operator clamps to (see rule (c) above), and it is what makes
// the overflow analysis a guarantee rather than an estimate.
const MAXV: long = 4294967296;

// ONE Q16 = 1.0 for every coefficient in this file.
const Q16: long = 65536;

// The store.  `w`/`h` are the logical interior size; `sw`/`sh`/`n` include the
// ghost border.  u0/v0/dye0 are the previous-step copies that diffusion and
// advection read (semi-Lagrangian sampling MUST see the whole field, not a
// partially updated one).  `dv` is the divergence, and it doubles as the
// vorticity field between calls -- see confine().
type Field = {
    w: long,
    h: long,
    sw: long,
    sh: long,
    n: long,
    u: [long; 32768],
    v: [long; 32768],
    u0: [long; 32768],
    v0: [long; 32768],
    dye: [long; 32768],
    dye0: [long; 32768],
    p: [long; 32768],
    dv: [long; 32768],
    om: [long; 32768],
    steps: long
};

// Everything one step needs, in a record the caller builds ONCE and mutates in
// place (records are passed by reference).  Building a record literal at the
// step() call site would cost 64 bytes of arena per step; see rule 2 above.
type Cfg = {
    iters: long,        // pressure Gauss-Seidel sweeps, per projection
    diters: long,       // viscous Jacobi sweeps
    visc16: long,       // viscosity, Q16 (65536 = 1.0); 0 = inviscid
    vort16: long,       // confinement epsilon, Q16; 0 = off
    damp16: long,       // velocity damping per step, Q16
    decay16: long,      // dye decay per step, Q16
    swirl16: long,      // emitter strength, Q16
    ink16: long,        // emitter dye, Q16
    rad: long,          // emitter radius, cells
    em: long,           // 1 = fire the emitter this step
    ex: long,           // emitter centre, logical cells
    ey: long
};

// new(w, h) -> Field -- the only allocation this module ever makes: one record
// with nine 32768-long arrays in it, 2.25 MiB.  fluid.y has already checked
// 1 <= w <= MAXW and 1 <= h <= MAXH.
def new(w: long, h: long) -> Field {
    let a: [long; 32768] = [0; 32768];
    let b: [long; 32768] = [0; 32768];
    let c: [long; 32768] = [0; 32768];
    let d: [long; 32768] = [0; 32768];
    let e: [long; 32768] = [0; 32768];
    let g: [long; 32768] = [0; 32768];
    let k: [long; 32768] = [0; 32768];
    let m: [long; 32768] = [0; 32768];
    let o: [long; 32768] = [0; 32768];
    let f: Field = {
        w: w, h: h, sw: w + 2, sh: h + 2, n: (w + 2) * (h + 2),
        u: a, v: b, u0: c, v0: d, dye: e, dye0: g,
        p: k, dv: m, om: o,
        steps: 0
    };
    f
};

// ------------------------------------------------------------------------
// small helpers.  None of these allocates, and none of them divides by
// anything the caller can set to zero.
// ------------------------------------------------------------------------

def clampv(x: long) -> long {
    if (x > MAXV) { return MAXV; };
    if (x < 0 - MAXV) { return 0 - MAXV; };
    x
};

// clampd(x) -- the dye is a DENSITY in [0, 1] by definition, so it gets its own
// clamp instead of the velocity envelope.  Saturating at exactly 1.0 is the
// right answer for a colour ramp as well: it reads as "as dense as this colour
// goes" rather than as a clipped number, and the mass in the summary is then a
// mass and not a count of clamped cells.
def clampd(x: long) -> long {
    if (x > fx.ONE) { return fx.ONE; };
    if (x < 0) { return 0; };
    x
};

// half(x) -- x/2, ROUNDED HALF AWAY FROM ZERO rather than truncated toward
// zero.  Every `*0.5` in the projection goes through here.  Y's `/` truncates
// toward zero, so a gradient of -1 Q30 unit becomes 0 instead of -0.5, and
// that asymmetry is a bias the next projection then has to remove -- which it
// can, but it costs iterations.  Rounding is within half a Q30 unit (9.3e-10)
// of the truth either way; only the bias is avoided.
def half(x: long) -> long {
    if (x >= 0) { return (x + 1) / 2; };
    (x - 1) / 2
};

def idx(f: Field, x: long, y: long) -> long {
    (y + 1) * f.sw + (x + 1)
};

def clampi(x: long, lo: long, hi: long) -> long {
    if (x < lo) { return lo; };
    if (x > hi) { return hi; };
    x
};

// ------------------------------------------------------------------------
// the boundary conditions
// ------------------------------------------------------------------------

// borders(f) -- free slip for the velocity.  Four walls, then the four
// corners, and every write READS an interior cell, so the passes cannot
// interfere with each other whatever order they run in.  O(w + h), which is
// noise next to a sweep.
def borders(f: Field) {
    let sw = f.sw;
    let sh = f.sh;
    let x = 0;
    while (x < f.w) {
        let c = x + 1;
        let top = c;
        let bot = (sh - 1) * sw + c;
        // top and bottom walls: v (the normal) negated, u (the tangent) copied
        f.v[top] = 0 - f.v[sw + c];
        f.v[bot] = 0 - f.v[(sh - 2) * sw + c];
        f.u[top] = f.u[sw + c];
        f.u[bot] = f.u[(sh - 2) * sw + c];
        x = x + 1
    };
    let y = 0;
    while (y < f.h) {
        let r = (y + 1) * sw;
        // left and right walls: u negated, v copied
        f.u[r] = 0 - f.u[r + 1];
        f.u[r + sw - 1] = 0 - f.u[r + f.w];
        f.v[r] = f.v[r + 1];
        f.v[r + sw - 1] = f.v[r + f.w];
        y = y + 1
    };
    // corners: the diagonal interior neighbour, which the two passes above
    // have already made consistent with its two edge neighbours
    let last = (sh - 1) * sw;
    f.u[0] = f.u[sw + 1];
    f.v[0] = f.v[sw + 1];
    f.u[sw - 1] = f.u[sw + 2];
    f.v[sw - 1] = f.v[sw + 2];
    f.u[last] = f.u[last - sw + 1];
    f.v[last] = f.v[last - sw + 1];
    f.u[last + sw - 1] = f.u[last - sw + f.w];
    f.v[last + sw - 1] = f.v[last - sw + f.w]
};

// oborders(f) -- the same ring for the vorticity MAGNITUDE, which is a scalar,
// so no sign flip: the ghost takes its interior neighbour.  confine() needs
// this or the gradient of |omega| sees a cliff at the wall and the
// confinement force points into the boundary -- a ring of artefacts one cell
// thick along the whole edge of the box.
//
// Only `om` is extended, and it is extended here rather than in borders()
// because only confine() reads it, so this is one O(w+h) pass per step instead
// of three.
def oborders(f: Field) {
    let sw = f.sw;
    let sh = f.sh;
    let x = 0;
    while (x < f.w) {
        let c = x + 1;
        f.om[c] = f.om[sw + c];
        f.om[(sh - 1) * sw + c] = f.om[(sh - 2) * sw + c];
        x = x + 1
    };
    let y = 0;
    while (y < f.h) {
        let r = (y + 1) * sw;
        f.om[r] = f.om[r + 1];
        f.om[r + sw - 1] = f.om[r + f.w];
        y = y + 1
    };
    let last = (sh - 1) * sw;
    f.om[0] = f.om[sw + 1];
    f.om[sw - 1] = f.om[sw + 2];
    f.om[last] = f.om[last - sw + 1];
    f.om[last + sw - 1] = f.om[last - sw + f.w]
};

// pborders(f) -- Neumann on the pressure: dp/dn = 0, so the ghost cell takes
// the interior value.  Called once per project(), not per sweep: a sweep only
// writes interior cells, so the boundary it was given is still the right one.
def pborders(f: Field) {
    let sw = f.sw;
    let sh = f.sh;
    let x = 0;
    while (x < f.w) {
        let c = x + 1;
        f.p[c] = f.p[sw + c];
        f.p[(sh - 1) * sw + c] = f.p[(sh - 2) * sw + c];
        x = x + 1
    };
    let y = 0;
    while (y < f.h) {
        let r = (y + 1) * sw;
        f.p[r] = f.p[r + 1];
        f.p[r + sw - 1] = f.p[r + f.w];
        y = y + 1
    };
    let last = (sh - 1) * sw;
    f.p[0] = f.p[sw + 1];
    f.p[sw - 1] = f.p[sw + 2];
    f.p[last] = f.p[last - sw + 1];
    f.p[last + sw - 1] = f.p[last - sw + f.w]
};

// ------------------------------------------------------------------------
// 2. the pressure solve.  This is the part worth reading.
// ------------------------------------------------------------------------

// project(f, iters) -- make the velocity field divergence-free.
//
// The velocity is corrected by subtracting the gradient of a pressure field p
// that is the solution of the Poisson equation
//
//     laplacian(p) = div(u),      u <- u - grad(p)
//
// which is the discrete projection onto the space of divergence-free vectors.
// With the standard five-point Laplacian and the half-cell centred
// differences, one Jacobi (or Gauss-Seidel) sweep is
//
//     p[i] = (p[i-1] + p[i+1] + p[i-sw] + p[i+sw] + div[i]) / 4
//
// and the whole thing costs one linear pass for the divergence, `iters` sweeps
// and one linear pass for the gradient.  `iters = 0` is legal and means "do not
// project at all" -- the field stays divergent, which is exactly what the
// divergence figure in the summary then reports.  There is no division by
// `iters` anywhere, so 0 is not a trap.
//
// WHY GAUSS-SEIDEL AND NOT JACOBI: updating p in place means each sweep uses
// this iteration's values for the upwind half of its stencil, which roughly
// halves the number of sweeps needed for a given residual.  On a sequential
// machine that is a straight win, and it is still bit-for-bit deterministic
// because the sweep order never changes.
def project(f: Field, iters: long) {
    let w = f.w;
    let sw = f.sw;
    let u = f.u;
    let v = f.v;
    let p = f.p;
    let dv = f.dv;

    // 1. divergence, interior only.  Signed, so a negative div means the field
    //    is converging into the cell.
    //
    // The zeroing loop below needs `i` too, so `i` is hoisted to the top of the
    // function rather than declared inside the first row loop -- a `let` inside
    // a block is scoped to that block, and Y has no hoisting.
    let y = 0;
    let i = 0;
    while (y < f.h) {
        let r = (y + 1) * sw + 1;
        i = r;
        let end = r + w;
        while (i < end) {
            dv[i] = 0 - half(u[i + 1] - u[i - 1] + v[i + sw] - v[i - sw]);
            i = i + 1
        };
        y = y + 1
    };

    // 2. p starts at zero every projection (Stam does this too): a warm start
    //    would make the residual history depend on the previous step, and the
    //    point of reporting a divergence figure is that it is reproducible.
    i = 0;
    while (i < f.n) { p[i] = 0; i = i + 1; };

    // 3. the sweeps
    let it = 0;
    while (it < iters) {
        y = 0;
        while (y < f.h) {
            let r = (y + 1) * sw + 1;
            let j = r;
            let end = r + w;
            while (j < end) {
                p[j] = (p[j - 1] + p[j + 1] + p[j - sw] + p[j + sw] + dv[j]) / 4;
                j = j + 1
            };
            y = y + 1
        };
        it = it + 1
    };

    // 4. subtract the gradient, and clamp (rule (c)).
    if (iters > 0) {
        pborders(f);
        y = 0;
        while (y < f.h) {
            let r = (y + 1) * sw + 1;
            let j = r;
            let end = r + w;
            while (j < end) {
                u[j] = clampv(u[j] - half(p[j + 1] - p[j - 1]));
                v[j] = clampv(v[j] - half(p[j + sw] - p[j - sw]));
                j = j + 1
            };
            y = y + 1
        };
    }
}

// ------------------------------------------------------------------------
// 1. viscosity.  (I - nu dt laplacian) u = u, solved by Jacobi sweeps of the
// same form as the pressure solve.  Implicit, so it is unconditionally stable
// and `diters` only trades accuracy for time.
// ------------------------------------------------------------------------
def diffuse(f: Field, visc16: long, iters: long) {
    // Inviscid is the interesting case and the default; skipping both the copy
    // and the sweeps is why --viscosity 0 is not just a multiply by zero.
    if (visc16 <= 0 || iters <= 0) { return };

    let w = f.w;
    let sw = f.sw;
    let u = f.u;
    let v = f.v;
    let u0 = f.u0;
    let v0 = f.v0;
    let i = 0;
    while (i < f.n) {
        u0[i] = u[i];
        v0[i] = v[i];
        i = i + 1
    };
    let den = Q16 + 4 * visc16;
    let it = 0;
    while (it < iters) {
        let y = 0;
        while (y < f.h) {
            let r = (y + 1) * sw + 1;
            let j = r;
            let end = r + w;
            while (j < end) {
                // sum of the four neighbours minus 4x: |.| < 2^35 because the
                // velocity is clamped to +-2^32 (rule (c)).
                let du = u0[j - 1] + u0[j + 1] + u0[j - sw] + u0[j + sw] - 4 * u0[j];
                let dv = v0[j - 1] + v0[j + 1] + v0[j - sw] + v0[j + sw] - 4 * v0[j];
                // visc16 is Q16 (rule (b)): 2^35 * 2^23 = 2^58 at the very
                // worst coefficient fluid.y will accept, and each product is
                // brought back down before the next one is formed.
                u[j] = clampv((u0[j] + ((visc16 * du) >> 16)) * Q16 / den);
                v[j] = clampv((v0[j] + ((visc16 * dv) >> 16)) * Q16 / den);
                j = j + 1
            };
            y = y + 1
        };
        it = it + 1
    }
};

// ------------------------------------------------------------------------
// 3. advection, semi-Lagrangian.  The unconditionally stable step that makes
// the whole scheme stable: trace each cell backwards along its own velocity
// field and read what is there.
//
// The backtrace position is exact Q30 -- x*fx.ONE - u -- but the BILINEAR
// WEIGHTS cannot be, because blending two velocities means forming
// (u10 - u00) * w with w in Q30, and that product is Q60: 2^32 * 2^30 = 2^62,
// one bit short of disaster and wrong the moment the velocity clamp is
// raised.  So the weight is truncated to Q10 first (1024 levels of position
// inside a cell, i.e. 1/1024 of a cell -- far below anything the eye or the
// scheme can see) and every product then tops out at 2^43:
//
//     (u10 - u00) * 1024 <= 2^33 * 2^10 = 2^43
//
// and the increment is added to u00 rather than blended with it, so the
// constant part of the field keeps full Q30 precision and only the
// interpolation increment is quantised.
// ------------------------------------------------------------------------
def advect(f: Field) {
    let w = f.w;
    let h = f.h;
    let sw = f.sw;
    let one = fx.ONE;
    let i = 0;
    while (i < f.n) {
        f.u0[i] = f.u[i];
        f.v0[i] = f.v[i];
        f.dye0[i] = f.dye[i];
        i = i + 1
    };

    let y = 0;
    while (y < h) {
        let r = (y + 1) * sw + 1;
        let j = r;
        let end = r + w;
        while (j < end) {
            let x = j - r;
            // Backtrace: where did the parcel that is now at (x, y) come from?
            // Clamped to the grid, which is the standard no-outflow boundary
            // treatment for semi-Lagrangian advection.
            let pxx = clampi(x * one - f.u0[j], 0, (w - 1) * one);
            let pyy = clampi(y * one - f.v0[j], 0, (h - 1) * one);
            // Fetch index and weight.  ix is pulled back to w-2 so that ix+1 is
            // a legal column; when the clamp does that the weight becomes ONE,
            // i.e. the sample is taken exactly on the last column.  The w == 1
            // case is the --size 1x1 grid: there is no second column, so the
            // weight is ZERO and the sample is the cell itself.
            let ix = pxx / one;
            let wx = pxx - ix * one;
            if (w >= 2) {
                if (ix > w - 2) { ix = w - 2; wx = one; }
            } else {
                ix = 0; wx = 0
            };
            let iy = pyy / one;
            let wy = pyy - iy * one;
            if (h >= 2) {
                if (iy > h - 2) { iy = h - 2; wy = one; }
            } else {
                iy = 0; wy = 0
            };
            let wq = wx >> 20;
            let hq = wy >> 20;
            let a = (iy + 1) * sw + ix + 1;
            let b = a + sw;

            // three fields, one interpolation each: u, v and the dye
            let tu = f.u0[a] + ((f.u0[a + 1] - f.u0[a]) * wq) / 1024;
            let bu = f.u0[b] + ((f.u0[b + 1] - f.u0[b]) * wq) / 1024;
            let tv = f.v0[a] + ((f.v0[a + 1] - f.v0[a]) * wq) / 1024;
            let bv = f.v0[b] + ((f.v0[b + 1] - f.v0[b]) * wq) / 1024;
            let td = f.dye0[a] + ((f.dye0[a + 1] - f.dye0[a]) * wq) / 1024;
            let bd = f.dye0[b] + ((f.dye0[b + 1] - f.dye0[b]) * wq) / 1024;

            f.u[j] = clampv(tu + ((bu - tu) * hq) / 1024);
            f.v[j] = clampv(tv + ((bv - tv) * hq) / 1024);
            f.dye[j] = clampd(td + ((bd - td) * hq) / 1024);
            j = j + 1
        };
        y = y + 1
    }
};

// ------------------------------------------------------------------------
// 4. vorticity confinement.
//
// Semi-Lagrangian advection is very diffusive: a swirl that has been carried
// for a few steps has been smoothed into the background.  Confines it back, by
// pushing velocity ALONG the gradient of the vorticity magnitude:
//
//     omega = dv/dx - du/dy
//     N     = grad|omega| / |grad|omega||          (a unit vector)
//     f     = eps (N x omega)                        so u += eps Ny omega,
//                                                    v -= eps Nx omega
//
// The normalisation is where a fixed-point program has to be careful, because
// |grad|omega|| needs a square root of a SUM OF SQUARES of Q30 quantities:
// that is a Q60 square and there is no 64-bit answer.  So the gradient goes
// down 15 bits first (Q15, |g| <= 2^18, squares summing to <= 2^37), fx.isqrt
// gives the length in Q15 (its input is at most 2^37, well inside its 2^33
// domain... it is at most 2^37 so use the exact isqrt, which has no domain
// limit), and the normal comes back by multiplying by 2^15 again.  fx.isqrt's
// result is >= |gx| by construction, so the normal can never exceed ONE.
//
// f.dv holds omega on the way in and f.om holds |omega|; `dv` is the
// divergence, but it is recomputed from scratch by every project() call, so
// borrowing it here is safe and saves a whole 256 KiB array.
// ------------------------------------------------------------------------
def confine(f: Field, eps16: long) {
    if (eps16 <= 0) { return };

    let w = f.w;
    let sw = f.sw;
    let u = f.u;
    let v = f.v;
    let dv = f.dv;
    let om = f.om;
    let y = 0;
    while (y < f.h) {
        let r = (y + 1) * sw + 1;
        let j = r;
        let end = r + w;
        while (j < end) {
            // omega = half(dv/dx - du/dy), same units as the velocity
            dv[j] = half(v[j + 1] - v[j - 1] - u[j + sw] + u[j - sw]);
            om[j] = fx.abs(dv[j]);
            j = j + 1
        };
        y = y + 1
    };
    // the ghost ring for |omega|, so the gradient below sees the same field the
    // interior does (see oborders)
    oborders(f);
    y = 0;
    while (y < f.h) {
        let r = (y + 1) * sw + 1;
        let j = r;
        let end = r + w;
        while (j < end) {
            let gx = half(om[j + 1] - om[j - 1]);
            let gy = half(om[j + sw] - om[j - sw]);
            let sx = gx >> 15;
            let sy = gy >> 15;
            let l2 = sx * sx + sy * sy;
            let l = fx.isqrt(l2);
            if (l > 0) {
                let nx = (sx << 15) / l;
                let ny = (sy << 15) / l;
                // omega shifted to Q14 before it multiplies the normal (Q30):
                // 2^30 * 2^17 = 2^47, then two more Q16 scalings down to the
                // final Q30 increment.
                let wo = dv[j] >> 16;
                let fx1 = (ny * wo) >> 16;
                let fy1 = (nx * wo) >> 16;
                u[j] = clampv(u[j] + ((eps16 * fx1) >> 16));
                v[j] = clampv(v[j] - ((eps16 * fy1) >> 16))
            };
            j = j + 1
        };
        y = y + 1
    }
};

// ------------------------------------------------------------------------
// 0. the emitter.  A stirrer, not a source.
//
// This is worth spelling out because it is the whole lesson of the projection
// step: a force field is split by the projection into its divergence-free part
// (which survives) and its solenoidal-irrelevant remainder (which is deleted).
// A radial "source" -- push outward from a point -- is almost pure divergence,
// so almost all of it is thrown away by the first project() and the user sees
// nothing.  A ROTATIONAL force is almost pure curl, so it survives and spins
// the fluid up into vortices.  Hence the emitter injects (-dy, +dx)/r and not
// (dx, +dy)/r.
//
// The falloff is (r2 - d2)^2 normalised, which is a smooth compactly-supported
// bump: no division by the radius at the edge, no discontinuity, and the
// quadratic makes it twice as flat as a linear falloff at the rim so the
// stirring has no visible edge.
// ------------------------------------------------------------------------
def emit(f: Field, cx: long, cy: long, kq: long, inkq: long, rad: long) {
    if (rad < 1) { rad = 1; };
    if (rad > 64) { rad = 64; };
    // The centre is clamped INTO the grid before anything else.  The loop
    // bounds below would be safe either way -- they are clamped too -- but the
    // distance `d2` inside is measured from (cx, cy), and a centre outside the
    // box makes d2 huge enough that dx*dx + dy*dy overflows a signed 64-bit
    // long.  That is not a crash: the overflow makes d2 small or negative, the
    // falloff test then passes, and fx.isqrt() is called with a NEGATIVE
    // argument -- which loops forever (filed in examples/BUGS.md).  A module
    // function should be total, so the clamp is here rather than trusted to
    // every caller.
    cx = clampi(cx, 0, f.w - 1);
    cy = clampi(cy, 0, f.h - 1);
    let r2 = rad * rad;
    let sw = f.sw;
    let x0 = clampi(cx - rad, 0, f.w - 1);
    let x1 = clampi(cx + rad, 0, f.w - 1);
    let y0 = clampi(cy - rad, 0, f.h - 1);
    let y1 = clampi(cy + rad, 0, f.h - 1);
    let y = y0;
    while (y <= y1) {
        let r = (y + 1) * sw;
        let x = x0;
        while (x <= x1) {
            let dx = x - cx;
            let dy = y - cy;
            let d2 = dx * dx + dy * dy;
            // No `continue` in Y: the positive condition IS the continue.  One
            // compare, and the falloff weight is computed only inside.
            if (d2 < r2) {
                let g = r2 - d2;
                // Q16 bump, 0..65536, by construction (g*g <= r2*r2)
                let wt = (g * g * Q16) / (r2 * r2);
                let d = fx.isqrt(d2);
                // d is 0 only at the emitter centre, where a tangential
                // direction does not exist.  Skipping that one cell is also
                // what keeps this from dividing by zero.
                if (d > 0) {
                    let m = (kq * wt) / Q16;
                    f.u[r + x + 1] = clampv(f.u[r + x + 1] + ((m * (0 - dy) / d) << 14));
                    f.v[r + x + 1] = clampv(f.v[r + x + 1] + ((m * dx / d) << 14))
                };
                f.dye[r + x + 1] = clampd(f.dye[r + x + 1] + ((inkq * wt) >> 4))
            };
            x = x + 1
        };
        y = y + 1
    }
};

// ------------------------------------------------------------------------
// the initial condition
// ------------------------------------------------------------------------

// The noise below is std's generator (import random at the top of this file):
// this was `rnd(f)`, an xorshift32 whose 32 bits lived in the Field's `rng`
// field, drawn as `f.rng >>> 2` for a value in [0, fx.ONE).  One Field exists
// per program and it is mutated in place, so the 32-bit per-field state bought
// nothing that std's one module-level stream does not; the `rng` field is gone
// with it.  Only the DISTRIBUTION had to survive, and it did: a draw is still
// uniform over [0, fx.ONE), which is what `random.below(fx.ONE)` is for.  fx.ONE
// is a power of two, so below()'s rejection loop cannot reject.
//
// This is the ONLY randomness in the program and it is entirely seeded: the
// state is a pure function of --seed, so the same seed reproduces the same
// run byte for byte.  There is no unseeded path, not even in the interactive
// mode, where the emitter follows a Lissajous curve whose phase comes from the
// seed too.  (ORCHESTRATOR.md 1-B7.)
//
// The old `mix(sd)` seed scrambler went with the generator: its only job was to
// keep a --seed of 0 off a degenerate stream, and std's `seed()` offsets the
// state by the golden-ratio constant before the first draw for exactly that
// reason.  So --seed 0 is still a usable seed and still a distinct run.

// seed(f, sd, iters) -- the initial perturbation.  Two coherent counter-rotating
// vortices so there is structure at step 0, plus seeded noise at +-0.5 cells
// per step, then ONE projection to make the whole thing divergence-free (the
// noise is not, so without this the first step would be mostly a correction).
// An unprojected random velocity field is a bad starting point for this
// scheme: half of it is removed on the first step and the reader would blame
// the solver.
def seed(f: Field, sd: long, iters: long) {
    let i = 0;
    while (i < f.n) {
        f.u[i] = 0;
        f.v[i] = 0;
        f.p[i] = 0;
        f.dv[i] = 0;
        f.om[i] = 0;
        f.u0[i] = 0;
        f.v0[i] = 0;
        f.dye[i] = 0;
        f.dye0[i] = 0;
        i = i + 1
    };
    // Re-seed on EVERY seed() call, not once at start-up: `r` (reset) and
    // `clear` both come back here, and the whole point of them is to lay down
    // the same field again from the same --seed.
    random.seed(sd);
    f.steps = 0;

    // seeded noise: the small scales the two big vortices cannot supply
    let sw = f.sw;
    let y = 0;
    while (y < f.h) {
        let r = (y + 1) * sw + 1;
        let j = r;
        let end = r + f.w;
        while (j < end) {
            f.u[j] = (random.below(fx.ONE) - fx.ONE / 2) / 2;
            f.v[j] = (random.below(fx.ONE) - fx.ONE / 2) / 2;
            j = j + 1
        };
        y = y + 1
    };
    // Two vortices of opposite sense, a third of the way in from each end.
    // Their strength is Q16, so 24576 is a peak of 0.375 cells per step -- the
    // units of the emitter's swirl16, and the number that says how strong a
    // stir this is.  Bigger and the clamp (rule (c)) starts doing the
    // integration's job, which is not what a demonstration should show.
    emit(f, f.w / 3, f.h / 2, 24576, 0, f.h / 6 + 2);
    emit(f, 2 * f.w / 3, f.h / 2, 0 - 24576, 0, f.h / 6 + 2);
    // dye blobs, so --field dye has something to show from the first frame
    emit(f, f.w / 3, f.h / 2, 0, Q16, f.h / 8 + 1);
    emit(f, 2 * f.w / 3, f.h / 2, 0, Q16, f.h / 8 + 1);
    borders(f);
    project(f, iters);
    borders(f)
};

// setup(f, w, h, sd, iters) -- retune the store to a w x h interior and lay
// down the seeded initial condition.
//
// It allocates NOTHING: the nine arrays are already MAXN, so retuning the grid
// is five field writes and a clear.  That is why fluid.y can build the Field at
// MODULE SCOPE -- before the command line has been parsed, so --size is not
// known yet -- and simply call setup() once the flags are in.  A second
// sim.new() would have cost another 2.25 MiB.
def setup(f: Field, w: long, h: long, sd: long, iters: long) {
    f.w = w;
    f.h = h;
    f.sw = w + 2;
    f.sh = h + 2;
    f.n = (w + 2) * (h + 2);
    seed(f, sd, iters)
};

// reset(f, sd, iters) -- the `r` key: same grid, same seed, same field.  Not
// the same SIMULATION history (f.steps goes back to 0), which is the point.
def reset(f: Field, sd: long, iters: long) {
    seed(f, sd, iters)
};

def clear(f: Field, sd: long, iters: long) {
    seed(f, sd, iters)
};

// ------------------------------------------------------------------------
// the step
// ------------------------------------------------------------------------

// step(f, c) -- one Euler step, in the order stated at the top of this file.
// `c` is a record the caller owns and mutates (emitter position, mostly), so
// nothing is allocated here.
def step(f: Field, c: Cfg) {
    // 0. external forces
    if (c.em != 0) { emit(f, c.ex, c.ey, c.swirl16, c.ink16, c.rad); };

    // 1. viscosity
    diffuse(f, c.visc16, c.diters);
    borders(f);

    // 2. projection: divergence-free before anything is carried anywhere
    project(f, c.iters);

    // 3. advection
    advect(f);

    // 4. vorticity confinement -- a FORCE, so it belongs with the forces, and
    //    therefore after advection (it feeds on the vorticity advection just
    //    smoothed away) and before the final projection.
    confine(f, c.vort16);

    // 5. projection again: advection is not divergence-free even when its input
    //    was, which is the whole reason the order is add/diffuse/project/
    //    advect/project rather than add/diffuse/project/advect.
    borders(f);
    project(f, c.iters);

    // 6. drag and dye fade
    let i = 0;
    if (c.damp16 > 0 || c.decay16 > 0) {
        while (i < f.n) {
            if (c.damp16 > 0) {
                f.u[i] = clampv(f.u[i] - ((f.u[i] * c.damp16) >> 16));
                f.v[i] = clampv(f.v[i] - ((f.v[i] * c.damp16) >> 16))
            };
            if (c.decay16 > 0) {
                f.dye[i] = clampd(f.dye[i] - ((f.dye[i] * c.decay16) >> 16))
            };
            i = i + 1
        }
    };
    borders(f);
    f.steps = f.steps + 1
};

// ------------------------------------------------------------------------
// measurements.  All three of these need a square root of a sum of squares,
// which is the one operation that would overflow in Q30 -- so they all shift
// down first and back up after (rule (a)).
// ------------------------------------------------------------------------

// speed(f, x, y) -> long -- |(u, v)| at one cell, Q30 cells/step.
def speed(f: Field, x: long, y: long) -> long {
    let j = idx(f, x, y);
    // 17 down: |u| <= 2^32 so (u>>17)^2 <= 2^30 and the pair sums to <= 2^31,
    // inside fx.isqrt's domain with room to spare.  17 bits back up = Q30.
    let a = f.u[j] >> 17;
    let b = f.v[j] >> 17;
    fx.isqrt(a * a + b * b) << 17
};

// vort(f, x, y) -> long -- dv/dx - du/dy at one cell, Q30.  Signed: positive is
// counter-clockwise.  This is the field a vortex core shows up in, which is why
// it is the default to colour by.
def vort(f: Field, x: long, y: long) -> long {
    let j = idx(f, x, y);
    half(f.v[j + 1] - f.v[j - 1] - f.u[j + f.sw] + f.u[j - f.sw])
};

// dye_at(f, x, y) -> long -- the density at one cell, Q30 in [0, ONE].  The
// third field, and the one that makes the semi-Lagrangian backtrace visible:
// a blob of dye carried across the box is advection made visible.
def dye_at(f: Field, x: long, y: long) -> long {
    let j = idx(f, x, y);
    f.dye[j]
};

// energy(f) -> long -- total kinetic energy sum(u^2+v^2)/2 in Q28.
// (u>>16)^2 <= 2^32 and there are at most 30744 cells, so the accumulator tops
// out at 2^48.
def energy(f: Field) -> long {
    let sw = f.sw;
    let s = 0;
    let y = 0;
    while (y < f.h) {
        let r = (y + 1) * sw + 1;
        let j = r;
        let end = r + f.w;
        while (j < end) {
            let a = f.u[j] >> 16;
            let b = f.v[j] >> 16;
            s = s + a * a + b * b;
            j = j + 1
        };
        y = y + 1
    };
    s >> 1
};

// max_speed(f) -> long -- the fastest cell, Q30.  A maximum over ~30000 cells
// of |(u,v)|, squared with the same 17-bit shift as speed().
def max_speed(f: Field) -> long {
    let sw = f.sw;
    let best = 0;
    let y = 0;
    while (y < f.h) {
        let r = (y + 1) * sw + 1;
        let j = r;
        let end = r + f.w;
        while (j < end) {
            let a = f.u[j] >> 17;
            let b = f.v[j] >> 17;
            let m = a * a + b * b;
            if (m > best) { best = m; };
            j = j + 1
        };
        y = y + 1
    };
    fx.isqrt(best) << 17
};

// mass(f) -> long -- total dye, Q30.  30744 cells each at most fx.ONE sums to
// 2^45, which is the widest accumulator in this file and still 18 bits clear.
def mass(f: Field) -> long {
    let sw = f.sw;
    let s = 0;
    let y = 0;
    while (y < f.h) {
        let r = (y + 1) * sw + 1;
        let j = r;
        let end = r + f.w;
        while (j < end) {
            s = s + f.dye[j];
            j = j + 1
        };
        y = y + 1
    };
    s
};

// div_rms(f) -> long -- the RMS of the divergence, Q12: how far the field is
// from incompressible, and the one number that says whether the pressure solve
// is doing its job.  Recomputes the divergence from the CURRENT velocity rather
// than reading the one project() left behind, because the interesting quantity
// is the RESIDUAL after the correction, not the error before it.
//
// (div>>18)^2 sums to at most 2^45, the mean is at most 2^30 (inside
// fx.isqrt's stated 2^33 domain), and the answer comes back in Q12.
def div_rms(f: Field) -> long {
    let sw = f.sw;
    let s = 0;
    let y = 0;
    while (y < f.h) {
        let r = (y + 1) * sw + 1;
        let j = r;
        let end = r + f.w;
        while (j < end) {
            let d = half(f.u[j + 1] - f.u[j - 1] + f.v[j + sw] - f.v[j - sw]) >> 18;
            s = s + d * d;
            j = j + 1
        };
        y = y + 1
    };
    let mean = s / (f.w * f.h);
    fx.isqrt(mean)
};

// vort_peak(f) -> long -- max |omega|, Q30.  The colour scale for --field vort,
// and the honest measure of "how much rotation is in here".
def vort_peak(f: Field) -> long {
    let sw = f.sw;
    let best = 0;
    let y = 0;
    while (y < f.h) {
        let r = (y + 1) * sw + 1;
        let j = r;
        let end = r + f.w;
        while (j < end) {
            let o = fx.abs(half(f.v[j + 1] - f.v[j - 1] - f.u[j + sw] + f.u[j - f.sw]));
            if (o > best) { best = o; };
            j = j + 1
        };
        y = y + 1
    };
    best
};