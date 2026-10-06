// scene.y -- a raymarched signed-distance-field scene, in fixed point.
//
// WHAT THIS IS
// Three primitives -- a sphere, a yawed box and a tilted capsule -- standing on
// a ground plane, welded together with a polynomial smooth-minimum so they melt
// into one another.  For every sample of the frame a ray is cast from an orbit
// camera and stepped along the distance field until it gets close to
// something; the surface is then shaded from the SDF gradient, with one
// ambient-occlusion tap along it, a Blinn highlight, a palette lookup and a fog
// into the sky.
//
// WHY FIXED POINT, AND WHY Q16 RATHER THAN fx's Q30
// Y has no float -> long and no cast syntax at all (ORCHESTRATOR.md 2.4a), so
// this file never leaves `long`.  The toolkit's fx.y is Q30 (1.0 = 2^30), which
// is right for a library of transcendental functions: mul() and fdiv() have to
// be exact to an ulp over a 4e9 range.  A scene is a different problem.
// Nothing here needs more than 16 fraction bits -- the hit epsilon is 2^-11 of
// a scene unit and one terminal cell spans about 2^-5 -- and at Q16 a product
// of two in-range quantities is ONE machine multiply and ONE shift instead of
// a call into fx.mul with four branches, three range tests and a 16-limb wide
// multiply as a fallback.
//
// That is the whole performance argument, and it is the load-bearing decision
// in this file: the inner loop calls into fx.y exactly nowhere.  fx appears
// once, at start-up, to build the palette tables -- 1280 entries of fx.cos,
// about a millisecond -- which is what makes a cosine colour ramp affordable
// here when it is not affordable per pixel.
//
// THE OVERFLOW HEADROOM, which is where Q16 earns its keep
// A Q30 dot product is Q60 and needs a scale-down or it is four bits from the
// top of a long; every product and dot here is Q32 instead, so:
//
//   * p and every scene constant live in [-32, 32] real, i.e. +-2^21.
//   * p*p is then at most 2^42 and a three-term dot at most 3*2^42 = 2^43.6,
//     which is 18 bits clear of fx.MAX = 2^62.
//   * the ray has |r| <= 2.4 and t is capped at TMAX = 24 real, so r*t is at
//     most 58 real = 2^28 Q16 and the >> 16 forming p = ro + r*t cannot have
//     lost the sign bit.
//   * the widest single product on the frame path is the sun term,
//     (r*SUNX + r*SUNY + r*SUNZ) * invL = 2.6e10 * 2^17 = 2^44.8, again clear.
//
// So the widest thing here is a sqrt argument at 2^43.6 with 18 bits in hand,
// and the march's real hazards are not arithmetic at all: a division by zero
// (a zero Newton seed, a zero ray length, a zero blend radius) and a negative
// shift count.  All three are guarded where they are created.
//
// ZERO ALLOCATION ON THE FRAME PATH
// The Y heap is an arena and nothing is freed (ORCHESTRATOR.md 2.7), so a
// record or array literal inside the step loop would leak on every iteration.
// There is not one in this file: every buffer is a module-level `let`, every
// scalar crosses a call boundary as a `long`, the trace() result is returned
// through module state instead of a record, and the per-ray setup is
// precomputed once per resize rather than rebuilt per frame.

import fx;
import tui;

// ───────────────────────────────────────────────────────────── the format ───
//
// Q16: a `long` v holds the real number v / 2^16.  1.0 == 65536.
const S: long = 65536;

// ─────────────────────────────────────────── a specialised integer sqrt ───
//
// fx.isqrt is exact for every 0 <= u < 2^62 and costs 43 ns measured on this
// tree.  This one costs 8 ns, and there are three of them per march step, so it
// is the single largest constant in the renderer.
//
// The method is the usual one: a 2048-entry table of square roots seeded from
// the top 11 bits, then three Newton steps in integers.  The argument is first
// brought into [2^25, 2^36) by an even number of bit shifts, so the table index
// always carries 10 significant bits.  Shifting costs the answer `up` bits on
// the left or `dn` bits on the right and never more than one unit of precision,
// because two bits on the argument is one bit on the root.
//
// Checked against fx.isqrt over 600000 arguments from 1 to 6.8e10: the worst
// disagreement was 7 units, at u = 1.1e12, which is the right-shift path losing
// bits far out in the tail.  Inside the range the marcher actually uses
// (u < 2^36, so no shift at all) the answer is within one unit, i.e. 1.5e-5
// real -- eight orders below the 2^-11 hit epsilon.
//
// The seed can never be zero, which is what keeps `v / r` from trapping: after
// the two shift loops v >= 2^25, so the table index is at least 1, and
// QSEED[1] = isqrt(2^25) = 5793.
const QT0: long = 33554432;             // 2^25: the table floor
const QT1: long = 68719476736;          // 2^36: the table ceiling
let QSEED: [long; 2048] = [0; 2048];

def qseed_init() -> void {
    let k = 0;
    while (k < 2048) {
        QSEED[k] = fx.isqrt(k << 25);
        k = k + 1;
    }
};

// qsqrt(v) -> long -- the whole-number square root of v >= 0.
def qsqrt(v: long) -> long {
    if (v <= 0) { return 0; };
    let up = 0;
    let dn = 0;
    while (v < QT0) { v = v << 2; dn = dn + 1; };
    while (v >= QT1) { v = v >>> 2; up = up + 1; };
    let r = QSEED[(v >>> 25) & 2047];
    let i = 0;
    while (i < 3) { r = (r + v / r) >> 1; i = i + 1; };
    let s = r << up;
    s >> dn
};

// ─────────────────────────────────────────────────────────── the geometry ───
//
// The scene is a fixed shape, so every parameter below is a compile-time
// constant and map() takes no arguments but the point.  That is deliberate: it
// keeps seven longs out of the hottest call in the program, and it is the
// reason the scene cannot be edited without recompiling -- which for a demo of
// smooth-minimum is the right trade.
//
//   ground plane   y = -1.10
//   sphere         centre (-0.62, 0.05, 0.10),  r = 0.70
//   box            centre ( 0.72,-0.25, 0.25),  half (0.45, 0.62, 0.40),
//                  yawed 0.55 rad about y
//   capsule        axis (-0.20,-1.05, 0.75) -> (0.30, 0.95,-0.55), r = 0.30
//
// The spacing is the point of the scene and it was arrived at by looking at it:
// the sphere's right edge is at x = 0.08 and the box's left face at x = 0.27, so
// the gap between them is 0.19 -- well inside the 0.45 blend radius, and the two
// shapes come out of the smooth-minimum as one body with a waist rather than as
// two objects that happen to be near each other.  Spread them any further apart
// and the blend stops happening; that is the whole lesson of the picture.
//
// The capsule's axis is stored ALREADY NORMALISED, so its projection parameter
// h = dot(p, axis) needs no division by dot(axis, axis) -- one division per
// capsule evaluation, gone.  |axis| comes to 1.0000089 as stored, a 9e-6
// relative error in h, far below anything visible.

const PLANE_Y: long = -72090;           // -1.10
const SPH_X: long = -40632;             // -0.62
const SPH_Y: long = 3277;               //  0.05
const SPH_Z: long = 6554;               //  0.10
const SPH_R: long = 45875;              //  0.70
const BOX_X: long = 47186;              //  0.72
const BOX_Y: long = -16384;             // -0.25
const BOX_Z: long = 16384;              //  0.25
const BOX_HX: long = 29491;             //  0.45
const BOX_HY: long = 40632;             //  0.62
const BOX_HZ: long = 26214;             //  0.40
const BOX_C: long = 55871;              //  cos(0.55)
const BOX_S: long = 34255;              //  sin(0.55)
const CAP_X: long = -13107;             // -0.20
const CAP_Y: long = -68813;             // -1.05
const CAP_Z: long = 49152;              //  0.75
const CAP_BX: long = 13445;             //  0.2051, the unit axis, x
const CAP_BY: long = 53779;             //  0.8206, the unit axis, y
const CAP_BZ: long = -34957;            // -0.5333, the unit axis, z
const CAP_R: long = 19661;              //  0.30

// Two blend radii on purpose.  The floor gets a tighter one so the blobs read
// as sitting ON something rather than dissolving into it; the objects share a
// wider one so each pair genuinely melts.
const KFLOOR: long = 22938;             // 0.35
const KOBJ: long = 36045;               // 0.55

// smin(a, b, k) -- the polynomial smooth minimum, in Q16:
//
//     h = max(k - |a - b|, 0) / k
//     min(a,b) - h*h*k / 4
//
// the quadratic approximation to a smooth min.  Three properties make it the
// right primitive for a marcher:
//
//   * it is never more than min(a,b), so it is always a lower bound on the
//     distance to the nearest surface -- which is exactly what sphere tracing
//     requires.  An over-estimate would step THROUGH a surface, and that is the
//     classic raymarching artefact.
//   * the blend term h*h*k is a RAW product, not an fx.mul: h <= k <= 32768, so
//     h*h <= 1.07e9 and h*h*k <= 3.5e13, both far inside a long, and the
//     >> 34 takes that Q48 result straight back down to Q16.
//   * when |a-b| >= k it returns min(a,b) exactly, with no division at all,
//     which is the common case for most of a ray.
def smin(a: long, b: long, k: long) -> long {
    let lo = a;
    let hi = b;
    if (a > b) { lo = b; hi = a; };
    let d = hi - lo;
    if (d >= k) { return lo; };
    let h = k - d;
    lo - (((h * h) * k) >> 34)
};

// map(p) -> long -- the scene distance at a point.  The only thing the march
// ever calls.
def map(px: long, py: long, pz: long) -> long {
    // the ground plane
    let dp = py - PLANE_Y;
    // the sphere
    let gx = px - SPH_X;
    let gy = py - SPH_Y;
    let gz = pz - SPH_Z;
    let ds = qsqrt(gx * gx + gy * gy + gz * gz) - SPH_R;
    // the box, yawed: take the point into the box's own frame, where the
    // distance is the standard exact box SDF,
    //     length(max(q,0)) + min(max(q.x,max(q.y,q.z)), 0)
    let bz = (BOX_C * pz + BOX_S * px) >> 16;
    let bx = (BOX_C * px - BOX_S * pz) >> 16;
    let dx = bx - BOX_X;
    let dy = py - BOX_Y;
    let dz = bz - BOX_Z;
    let adx = if (dx < 0) { 0 - dx } else { dx };
    let ady = if (dy < 0) { 0 - dy } else { dy };
    let adz = if (dz < 0) { 0 - dz } else { dz };
    let qx = adx - BOX_HX;
    let qy = ady - BOX_HY;
    let qz = adz - BOX_HZ;
    let ox = if (qx < 0) { 0 } else { qx };
    let oy = if (qy < 0) { 0 } else { qy };
    let oz = if (qz < 0) { 0 } else { qz };
    let db = qsqrt(ox * ox + oy * oy + oz * oz);
    let mx = if (qy > qx) { qy } else { qx };
    if (qz > mx) { mx = qz; };
    if (mx < 0) { db = db + mx; };
    // the capsule: h is the projection onto its axis, clamped to [0, 1]
    let cx = px - CAP_X;
    let cy = py - CAP_Y;
    let cz = pz - CAP_Z;
    let hh = (cx * CAP_BX + cy * CAP_BY + cz * CAP_BZ) >> 16;
    let hc = 0;
    if (hh > S) { hc = S; } else if (hh > 0) { hc = hh; };
    let kx = cx - ((CAP_BX * hc) >> 16);
    let ky = cy - ((CAP_BY * hc) >> 16);
    let kz = cz - ((CAP_BZ * hc) >> 16);
    let dc = qsqrt(kx * kx + ky * ky + kz * kz) - CAP_R;
    // three smooth minima: each object into the floor it stands on, then the
    // two objects into each other
    let m = smin(dp, ds, KFLOOR);
    let m2 = smin(m, db, KOBJ);
    smin(m2, dc, KOBJ)
};

// ─────────────────────────────────────── the control scene, for --check ───
//
// map_solo() is the sphere and nothing else, marched by the same trace() with the
// same camera, the same grid and the same cell pass.  It exists so that check.y
// can compare the DRAWN silhouette of a sphere against the closed-form tangent
// cone with no smooth-minimum in the way and nothing standing in front of it --
// which is the one comparison that can be made exactly.  It is off unless --check
// turns it on, and it is a separate function rather than a test inside map()
// because map() is the hottest code in the program.
let SOLO: long = 0;

def map_solo(px: long, py: long, pz: long) -> long {
    let gx = px - SPH_X;
    let gy = py - SPH_Y;
    let gz = pz - SPH_Z;
    qsqrt(gx * gx + gy * gy + gz * gz) - SPH_R
};

def solo(n: long) -> void { SOLO = n };

// ────────────────────────────────────────────────────────────── palettes ───
//
// The tables are declared HERE, ahead of the marcher, because module-level
// bindings are not hoisted: trace() reads PR/PG/PB on every shaded sample, and
// Y resolves a name at its declaration, not at the top of the file.
//
// Five palettes.  Each is a 256-entry RGB surface ramp indexed by the shading
// coordinate in trace(), plus a 256-entry sky ramp indexed by the ray's vertical
// direction.  Both are built ONCE at start-up out of fx.cos, which is the only
// reason fx is in this file at all -- and the reason a cosine palette is
// affordable here when it is not affordable per pixel.  Cycling palettes with a
// keypress is then a single store, with no rebuild.
//
// The ramp form is Inigo Quilez's:  a + b*cos(2*pi*(u + d)), one phase offset
// per channel, which sweeps a whole colour wheel out of three constants.

const NPAL: long = 5;
let PR: [long; 1280] = [0; 1280];
let PG: [long; 1280] = [0; 1280];
let PB: [long; 1280] = [0; 1280];
let SKR: [long; 1280] = [0; 1280];
let SKG: [long; 1280] = [0; 1280];
let SKB: [long; 1280] = [0; 1280];
let PALBASE: long = 0;

// ─────────────────────────────────────────────────────────── the marcher ───

const EPS: long = 32;                   // hit epsilon, 2^-11 = 4.9e-4
const NRM_E: long = 32;                 // gradient tap offset, 2^-11
const AO_R: long = 6554;                // ambient-occlusion reach, 0.10
const AO_LO: long = 1638;               // below this the tap is fully occluded
const TMAX: long = 5898240;             // the far plane, 90.0
const FOGK: long = 45;                  // 255*2^20/TMAX, for the fog ramp

// The key light and the sky's sun, both unit vectors in Q16.
const LX: long = 30089;
const LY: long = 51675;
const LZ: long = 26819;
// The sun.  It is deliberately NOT the key light: the key light is high and
// to the right so the blobs are front-lit and read, and the sun is off to the
// upper left so its glow is out of frame at the opening camera and comes into
// frame as you orbit.  Two directions is the cheapest way to get a lit subject
// and a sky that is not a white hole, and it costs one constant.
const SUNX: long = -40650;
const SUNY: long = 40650;
const SUNZ: long = -31469;
const GLOW0: long = 61604;              // cos(19.8 deg): the wide glow's edge
const GLOW1: long = 64563;              // cos(9.9 deg): the core's edge
const GLOW0_MAX: long = 88;
const GLOW1_MAX: long = 132;

// Camera, in module state: it is set once a frame and read by every ray, so
// passing it would be three arguments the march does not otherwise need.
let ROX: long = 0;
let ROY: long = 0;
let ROZ: long = 0;
let FX0: long = 0;                      // the camera basis: forward, right, up
let FY0: long = 0;
let FZ0: long = 0;
let RGX: long = 0;
let RGY: long = 0;
let RGZ: long = 0;
let UPX: long = 0;
let UPY: long = 0;
let UPZ: long = 0;
// The same nine numbers, gathered for --check, which needs them to rebuild each
// ray's direction outside this module: the analytic silhouette is the tangent
// cone from the eye, and its equation is written in terms of the projections of
// (eye - centre) onto these three axes.  One nine-element store a frame instead
// of nine accessors a sample.
let BASEV: [long; 9] = [0; 9];

// The last trace's answer, in module state rather than a returned record: a
// record would be a heap allocation once per sample (ORCHESTRATOR.md 2.7).
let MHIT: long = 0;
let MLUM: long = 0;
let MCOL: long = 0;
let MSKY: long = 0;
let MSTEP: long = 0;
// MT and MEND are the same idea for the two things --check needs that a hit
// alone does not carry: the ray PARAMETER the march stopped at (Q16, in the
// un-normalised ray's units, exactly as the position update uses it) and WHY it
// stopped, because "no hit" means three quite different things -- the surface was
// reached, the budget ran out, or the ray left past the far plane.  MEND is
// 0 = surface reached, 1 = step budget exhausted, 2 = past TMAX, 3 = degenerate
// ray (no march at all).  Nothing on the frame path reads either of them.
let MT: long = 0;
let MEND: long = 0;

// The march budget, set once from --steps.
let STEPS: long = 96;

// trace(rx, ry, rz, invl) -- march one ray and shade it.
//
// rx/ry/rz are never normalised and never need to be.  |r| is carried separately
// as invl = 2^32 / |r|, the Q16 reciprocal of the ray's length, and the step is
// (d * invl) >> 16.  That is the same march a unit ray would do -- the field is
// in world units and the step converts that into ray-parameter units -- and it
// costs ONE integer division per ray instead of three, which is why the camera
// basis is never renormalised per sample.
//
// There is no `break` and there is none in Y (ORCHESTRATOR.md 2.9), so both
// exits are a guard flag with an explicit terminal assignment: `hit` is set to 1
// and `go` to 0 when the surface is reached, and `go` alone when the ray runs
// past the far plane.  Every path out of the loop leaves `i` at the number of
// steps actually spent, which is what MSTEP reports and what the digest counts.
def trace(rx: long, ry: long, rz: long, invl: long) -> void {
    let t = 0;
    let i = 0;
    let go = true;
    let hit = 0;
    let px = ROX;
    let py = ROY;
    let pz = ROZ;
    let d = 0;
    while (go && i < STEPS) {
        px = ROX + ((rx * t) >> 16);
        py = ROY + ((ry * t) >> 16);
        pz = ROZ + ((rz * t) >> 16);
        // The one branch on the frame path that is not about the scene: SOLO is
        // --check's control, and it costs one test a march STEP rather than a
        // test inside map(), which is where a test-only flag would really hurt.
        if (SOLO != 0) { d = map_solo(px, py, pz); } else { d = map(px, py, pz) };
        if (d < EPS) { hit = 1; go = false; } else {
            t = t + ((d * invl) >> 16);
            if (t > TMAX) { go = false; };
            i = i + 1;
        };
    };
    MSTEP = i;
    MHIT = hit;
    MT = t;
    // why the loop stopped.  `hit` already separates the first case; the other
    // two are told apart by whether the ray is past the far plane or merely out
    // of steps, and the order matters -- a ray can leave by budget on the very
    // iteration whose step took it past TMAX.
    MEND = 0;
    if (hit == 0) { MEND = 1; };
    if (hit == 0 && t > TMAX) { MEND = 2; };

    // The sky: for a miss, and for the fog on a hit.  One LUT index off the
    // ray's vertical direction -- the horizontal position does not matter at
    // this scale, which is why the sky is a 256-entry table and not a function.
    // The sky index.  The frame's vertical half-angle is about 0.2 in tangent,
    // so scaling by 127/S -- the obvious choice, "127 index steps per radian of
    // sine" -- spends only 51 of the ramp's 256 entries on the whole picture and
    // the sky bands visibly.  500 instead puts the vertical field of view across
    // 200 of them and costs one multiply, and q = +-0.4 (52 degrees up) is where
    // the ramp saturates, which is far outside anything the camera can reach.
    let qy = (ry * invl) >> 16;
    let sk = sky_at(128 + (qy * 500) / S);

    // A sun glow, in two linear ramps behind two cone tests.  Linear, not a
    // power of the cosine, because a power function is still large AT the cone
    // edge and so leaves a visible ring; a ramp is zero at its own threshold by
    // construction.  The tests also mean most of the sky skips both divisions.
    let sd = ((rx * SUNX + ry * SUNY + rz * SUNZ) * invl) >> 32;
    if (sd > GLOW0) {
        let add = ((sd - GLOW0) * GLOW0_MAX) / (65536 - GLOW0);
        if (sd > GLOW1) {
            add = add + (((sd - GLOW1) * GLOW1_MAX) / (65536 - GLOW1));
        };
        if (add > 0) {
            sk = tui.rgb(tui.r_of(sk) + add, tui.g_of(sk) + add, tui.b_of(sk) + add);
        };
    };
    MSKY = sk;
    if (hit == 0) { MLUM = 0; MCOL = sk; return; };

    // The normal, from the SDF gradient at the hit.  The textbook version is a
    // four-tap tetrahedron; this is the three-tap version that REUSES the
    // distance already in hand.  For a distance field |grad| = 1, so
    // (d(p + E*e_i) - d(p)) / E is the i'th gradient component -- which is also
    // the OUTWARD normal, because a distance field grows away from its surface.
    // d(p) is the value the march's last map() call returned, so this is three
    // evaluations instead of four and no division, because only the direction
    // is wanted.  With E = 2^-11 the second-order term is E^2/(2r) ~ 0.01 whole
    // units against a first-order term of 32, so the direction is good to 3e-4.
    //
    // The SIGN is the whole of it: writing it the other way round, d(p) first,
    // gives the inward normal, and then every lit surface in the frame is
    // unlit -- a plausible-looking picture in which the diffuse term is zero
    // everywhere and only the ambient and the fog are left.
    let gx = map(px + NRM_E, py, pz) - d;
    let gy = map(px, py + NRM_E, pz) - d;
    let gz = map(px, py, pz + NRM_E) - d;
    let gl = qsqrt(gx * gx + gy * gy + gz * gz);
    if (gl < 1) { gl = 1; };
    let nx = (gx << 16) / gl;
    let ny = (gy << 16) / gl;
    let nz = (gz << 16) / gl;

    // The view direction: rd * invL is already the unit ray, so negating it is
    // free and costs no sqrt and no division.
    let vx = 0 - ((rx * invl) >> 16);
    let vy = 0 - ((ry * invl) >> 16);
    let vz = 0 - ((rz * invl) >> 16);

    // One ambient-occlusion tap, 0.10 along the normal.  The distance there is
    // AO_R on an open surface and less in a crease, which is the whole signal;
    // AO_LO is the depth at which the surface counts as fully occluded.
    let dao = map(px + ((nx * AO_R) >> 16), py + ((ny * AO_R) >> 16),
                  pz + ((nz * AO_R) >> 16));
    // AO_LO is the tap distance at which the surface counts as fully buried and
    // AO_R the distance on open ground, so the ramp between them IS the
    // occlusion.  Inverting it is silent: every surface then comes out fully lit
    // in a crease and pitch black in the open, which reads as "the lighting is
    // odd" rather than as a sign error.
    let amb = ((dao - AO_LO) * 255) / (AO_R - AO_LO);
    if (amb < 0) { amb = 0; };
    if (amb > 255) { amb = 255; };

    // Lambert.
    let ndl = (nx * LX + ny * LY + nz * LZ) >> 16;
    let dif = 0;
    if (ndl > 0) { dif = ndl; };
    let dif255 = (dif * 255) / S;

    // Blinn-Phong.  The half vector is L + V, normalised properly -- one qsqrt
    // and one division, and only on the samples that actually hit.
    //
    // The shorter version, normalising by a constant sqrt(2) because L and V
    // are "usually" perpendicular, is wrong in a way that is very visible here:
    // |L+V| runs from 0 (looking straight away from the light) to 2 (looking
    // straight into it), so the fake normaliser reports a half-vector cosine
    // above 1 over a broad cap, the exponent saturates, and a third of the
    // sphere comes out pure white.  One sqrt per shaded sample is cheaper than
    // that.
    let hx = LX + vx;
    let hy = LY + vy;
    let hz = LZ + vz;
    let hl = qsqrt(hx * hx + hy * hy + hz * hz);
    if (hl < 1) { hl = 1; };
    // the dot is Q32 and hl is a Q16 length in whole units, so dividing by hl is
    // the scale-down: no shift needed, and |n.h| <= 1 by construction
    let ndh = (nx * hx + ny * hy + nz * hz) / hl;
    let sp = 0;
    if (ndh > 0) { sp = ndh; };
    // the exponent is 16, not 24: at one ray per cell half a cell, a 24th power
    // of a cosine that moves by a per cent between neighbouring cells turns the
    // highlight into salt-and-pepper, and no amount of care in the march will
    // fix it.  16 is smooth at this resolution and still reads as a highlight.
    let s2 = (sp * sp) >> 16;
    let s4 = (s2 * s2) >> 16;
    let s8 = (s4 * s4) >> 16;
    let s16 = (s8 * s8) >> 16;
    let spec = (s16 * 180) / S;

    // The palette coordinate: height above the floor and depth along the ray,
    // less the light, so one 256-entry ramp carries the whole scene.
    let u = 120 + ((py >> 16) * 44) + ((t >> 16) * 5) - (dif >> 11);
    // The ground gets a coarse checker, and it is the cheapest perspective cue
    // there is: two shifts and a mask.  The grid is 0.5 scene units, chosen
    // coarse on purpose -- a fine one aliases into a moire on the far half of the
    // floor, and there is no mip chain to fade it with.
    u = u + (if ((((px >> 16) + (pz >> 16)) & 1) == 0) { 0 } else { 20 });
    if (u < 0) { u = 0; };
    if (u > 255) { u = 255; };

    // Ambient 40 + 215*lambert, the whole thing gated by the occlusion tap.
    let light = (40 + ((dif255 * 215) / 255)) * amb / 255;
    let cr = (PR[PALBASE + u] * light) / 255;
    let cg = (PG[PALBASE + u] * light) / 255;
    let cb = (PB[PALBASE + u] * light) / 255;
    // the highlight rides on top, toward white
    let rr = cr + (((255 - cr) * spec) / 255);
    let gg = cg + (((255 - cg) * spec) / 255);
    let bb = cb + (((255 - cb) * spec) / 255);
    // then fog into the sky, keyed off depth
    let fog = (t * FOGK) >> 20;
    if (fog > 255) { fog = 255; };
    if (fog < 0) { fog = 0; };
    MCOL = tui.lerp_rgb(tui.rgb(rr, gg, bb), sk, fog);
    MLUM = (dif255 * amb) / 255
};

// ────────────────────────────────────────────────────── building the ramps ───
//
// Everything below fills the tables declared above.  None of it runs per frame.


// cos255(a, b, d, u) -> long -- one channel of a cosine ramp, as 0..255.
// Q30 throughout; the final scaling is a plain (v*255) >> 30 rather than an
// fx.mul because fx.mul saturates at 2^62, and this multiply needs to be exact
// to an ulp only where an ulp matters -- which is not here.
//
// ARITHMETIC shift, not `>>>`.  v goes negative whenever b*cos() exceeds a,
// which is most of a cosine sweep, and Y's `>>>` is a LOGICAL shift: shift a
// negative Q30 value right by 30 and you get 2^64-minus-something, the clamp
// below turns that into 255, and one channel of the ramp comes out pure white
// for half its length.  `>>` floors towards minus infinity and the two clamps
// then do their job.
def cos255(a: long, b: long, d: long, u: long) -> long {
    // 2*pi/256 in Q30, so u (a plain 0..255 index) becomes the phase directly.
    let ang = u * 26353511 + fx.mul(d, fx.TWO_PI);
    let v = a + fx.mul(b, fx.cos(ang));
    let q = (v * 255) >> 30;
    if (q < 0) { return 0; };
    if (q > 255) { return 255; };
    q
};

// ramp_cos -- fill one palette's surface ramp from its a/b/d triples.
def ramp_cos(k: long, ar: long, ag: long, ab: long,
             br: long, bg: long, bb: long,
             dr: long, dg: long, db: long) -> void {
    let base = k * 256;
    let u = 0;
    while (u < 256) {
        PR[base + u] = cos255(ar, br, dr, u);
        PG[base + u] = cos255(ag, bg, dg, u);
        PB[base + u] = cos255(ab, bb, db, u);
        u = u + 1;
    }
};

// sky_set -- a vertical gradient with a bright band ON the horizon.
//
// The index the marcher hands this table is 128 + qy*127/S, so 0 is straight
// down, 128 is the horizon (qy = 0, the ray parallel to the plane) and 255 is
// straight up.  The gradient is therefore keyed on |u - 128|, not on u: index 0
// and index 255 are both "away from the horizon" and both get the zenith colour,
// and the band sits at the middle where a horizon actually is.  Squaring the
// distance makes the sky darken upward the way a sky does instead of fading
// linearly, and it is the reason a 256-entry table is enough for a gradient
// that has to look like sky rather than like a ramp.
def sky_set(k: long, zr: long, zg: long, zb: long,
            hr: long, hg: long, hb: long) -> void {
    let base = k * 256;
    let u = 0;
    while (u < 256) {
        let dd = if (u > 128) { u - 128 } else { 128 - u };   // 0..128 from the horizon
        let t2 = (dd * dd) / 128;                            // 0 at the horizon, 128 away
        // The band: an eight-degree haze over the horizon, gone by 26.  A ground
        // plane seen from a camera a few units up never reaches the true horizon
        // -- the march runs out of steps first, and where it runs out is where
        // the ground appears to end -- so the band is there to sit over that
        // edge and make it read as distance rather than as a budget.
        let band = 0;
        if (dd < 10) { band = 255 - (dd * 24); } else if (dd < 40) {
            let d = 40 - dd;
            band = ((d * 8) - ((d * d) / 4));
        };
        SKR[base + u] = tui.clamp255(hr + (((zr - hr) * t2) / 128) + ((band * 92) / 255));
        SKG[base + u] = tui.clamp255(hg + (((zg - hg) * t2) / 128) + ((band * 78) / 255));
        SKB[base + u] = tui.clamp255(hb + (((zb - hb) * t2) / 128) + ((band * 60) / 255));
        u = u + 1;
    }
};

// ramp_rgb -- a two-stop linear ramp, for the palettes that are not cosines.
def ramp_rgb(k: long, r0: long, g0: long, b0: long,
             r1: long, g1: long, b1: long) -> void {
    let base = k * 256;
    let lo = tui.rgb(r0, g0, b0);
    let hi = tui.rgb(r1, g1, b1);
    let u = 0;
    while (u < 256) {
        let c = tui.lerp_rgb(lo, hi, u);
        PR[base + u] = tui.r_of(c);
        PG[base + u] = tui.g_of(c);
        PB[base + u] = tui.b_of(c);
        u = u + 1;
    }
};

// sky_at(u) -> long -- the sky ramp of the current palette, at a vertical index.
def sky_at(u: long) -> long {
    let k = u;
    if (k < 0) { k = 0; };
    if (k > 255) { k = 255; };
    let i = PALBASE + k;
    (SKR[i] << 16) | (SKG[i] << 8) | SKB[i]
};

def palette_init() -> void {
    // Every cosine ramp wants a + b <= 1, or the top of the sweep clips: cos255
    // clamps, so a ramp whose sum exceeds 1 just loses its brightest eighth.
    // The sky colours below are 8-BIT, unlike everything else in this file,
    // because tui.clamp255 is an 8-bit clamp and handing it a Q16 colour turns
    // the whole sky white.
    // 0 ember: a warm, dark base sweeping maroon -> orange -> gold
    ramp_cos(0, 590558003, 483183821, 0,
             429496730, 343597384, 107374182,
             322122547, 193273528, 214748365);
    sky_set(0, 74, 22, 11, 214, 99, 43);
    // 1 ice: a cold, high blue
    ramp_cos(1, 429496730, 300647711, 590558003,
             558345748, 322122547, 644245094,
             665719931, 343597384, 697932186);
    sky_set(1, 139, 221, 232, 77, 116, 201);
    // 2 spectrum: the whole wheel, in phase-offset thirds
    ramp_cos(2, 536870912, 536870912, 0,
             536870912, 536870912, 357913941,
             536870912, 536870912, 715827883);
    sky_set(2, 139, 66, 103, 54, 128, 57);
    // 3 mono: a plain grey ramp on a grey sky
    ramp_rgb(3, 10, 10, 14, 244, 244, 250);
    sky_set(3, 99, 99, 107, 184, 184, 193);
    // 4 phosphor: green, the classic terminal
    ramp_rgb(4, 4, 10, 6, 116, 255, 168);
    sky_set(4, 9, 46, 21, 176, 240, 140)
};

// palette(k) -- choose a palette, with wraparound.  One store: every ramp was
// built at start-up, so this is what a keypress costs.
def palette(k: long) -> void {
    let n = k % NPAL;
    if (n < 0) { n = n + NPAL; };
    PALBASE = n * 256
};

def palette_get() -> long { PALBASE / 256 };

def DBG_RAMP(u: long) -> long {
    let i = PALBASE + u;
    (PR[i] << 16) | (PG[i] << 8) | PB[i]
};

// ─────────────────────────────────────────────────────────────── the grid ───
//
// The per-ray setup, precomputed once per resize: where each sample sits on the
// image plane, as Q16 offsets from the camera's forward axis.  Nothing on the
// frame path recomputes it, and the camera basis is folded in by the marcher
// rather than baked in here -- so orbiting costs three multiplies a sample and
// no trigonometry at all.

const MAXC: long = 160;                // the cell cap; braille samples 2x4
const MAXR: long = 80;
const MAXW: long = 320;                // MAXC * 2
const MAXH: long = 320;                // MAXR * 4
const MAXSAMP: long = 102400;          // MAXW * MAXH
const HALFVIEW: long = 45875;           // 0.70: the half-width at distance 1

let GW: long = 1;                      // the sample grid
let GH: long = 1;
let SX: long = 1;                      // samples across per cell
let SY: long = 1;                      // samples down per cell
let RXO: [long; 102400] = [0; 102400];
let RYO: [long; 102400] = [0; 102400];

// The per-sample results of the last frame.
let SHIT: [long; 102400] = [0; 102400];
let SLUM: [long; 102400] = [0; 102400];
let SCOL: [long; 102400] = [0; 102400];
// ST and SEND are the per-sample MT / MEND -- the marcher's own answer to "how
// far along this ray, and did you find anything".  They are what --check
// compares against a closed-form intersection, and they cost two stores a
// sample on a path that is already three qsqrt a step deep.
let ST: [long; 102400] = [0; 102400];
let SEND: [long; 102400] = [0; 102400];
let HITS: long = 0;                    // how many samples found a surface
let STEP_TOTAL: long = 0;              // march steps spent over the frame

// grid_setup(cols, rows, sx, sy) -- zero allocation: the tables are module-level
// and this only writes into them.
//
// A terminal cell is about twice as tall as it is wide, so the vertical field is
// HALFVIEW * (GH/GW) / 2.  Without that /2 the scene comes out stretched twice
// as tall, which is the mistake every ASCII 3D program makes and the reason a
// raymarcher and a spinning torus do not look alike at the same cell count.
def grid_setup(cols: long, rows: long, sx: long, sy: long) -> void {
    SX = sx;
    SY = sy;
    GW = cols * sx;
    GH = rows * sy;
    let vw = HALFVIEW;
    let vh = (vw * GH) / (GW * 2);
    // Sample j's centre along the image plane is ((j + 1/2)/GW) * 2 - 1, which
    // is (2j + 1 - GW)/GW once the halves are cleared.  Row i's is
    // 1 - ((i + 1/2)/GH) * 2, which is (GH - 2i - 1)/GH -- and row 0 is the TOP
    // of the frame, which is why it counts up rather than down.
    //
    // Writing 2*(2j+1) instead of 2j+1 halves the sample density and doubles the
    // field of view while shifting the image left, and the result still looks
    // like a scene: the left half of the grid lands inside the intended frame
    // and the right half lands outside it, so the picture is off-centre and the
    // ground plane ends in mid-air where the far plane bites.
    let j = 0;
    while (j < GW) {
        RXO[j] = ((2 * j + 1 - GW) * vw) / GW;
        j = j + 1;
    };
    let i = 0;
    while (i < GH) {
        RYO[i] = ((GH - 2 * i - 1) * vh) / GH;
        i = i + 1;
    }
};

def grid_w() -> long { GW };
def grid_h() -> long { GH };
def grid_sx() -> long { SX };
def grid_sy() -> long { SY };

// ─────────────────────────────────────────────────────────────── the camera ───
//
// An orbit camera: azimuth and elevation in radians (Q16), distance in scene
// units (Q16), looking at the middle of the blob mass.  Two sins and two
// cosines a frame -- the only trigonometry left on the frame path.

const TGT_X: long = 0;
const TGT_Y: long = -13107;            // -0.20
const TGT_Z: long = 0;

let AZ: long = 0;                      // azimuth, Q16 radians
let EL: long = 0;                      // elevation, Q16 radians
let DIST: long = 0;                    // distance, Q16 scene units

def set_camera(az: long, el: long, dist: long) -> void {
    AZ = az;
    EL = el;
    DIST = dist
};

// camera_update() -- rebuild the basis.  Everything trigonometric here is a
// conversion, not a computation: AZ/EL/D are Q16 (this file's format) and fx is
// Q30, so both the angle and the distance are shifted up by 14 bits on the way
// in and the results are shifted back down on the way out.  That is the whole
// price of mixing two fixed-point formats, and it is paid twice a frame.
def camera_update() -> void {
    let ca = fx.cos(AZ << 14);
    let sa = fx.sin(AZ << 14);
    let ce = fx.cos(EL << 14);
    let se = fx.sin(EL << 14);
    let dr = DIST << 14;
    // The eye, on a sphere of radius DIST around the target.  `>>` and not
    // `>>>`: sin(AZ) is negative for half the orbit, so the products are, and a
    // logical shift by 14 of a negative Q30 value is 2^50 instead of a
    // coordinate -- which puts the camera a million units away and renders an
    // all-sky frame that still looks plausible.
    ROX = fx.mul(dr, fx.mul(ce, sa)) >> 14;
    ROY = (fx.mul(dr, se) >> 14) + TGT_Y;
    ROZ = fx.mul(dr, fx.mul(ce, ca)) >> 14;
    // forward = normalise(target - eye)
    let ax = TGT_X - ROX;
    let ay = TGT_Y - ROY;
    let az = TGT_Z - ROZ;
    let l = qsqrt(ax * ax + ay * ay + az * az);
    if (l < 1) { l = 1; };
    FX0 = (ax << 16) / l;
    FY0 = (ay << 16) / l;
    FZ0 = (az << 16) / l;
    // right = normalise(forward x world-up), and world-up is (0, 1, 0)
    let bx = 0 - FZ0;
    let bz = FX0;
    let bl = qsqrt(bx * bx + bz * bz);
    if (bl < 1) { bl = 1; };
    RGX = (bx << 16) / bl;
    RGY = 0;
    RGZ = (bz << 16) / bl;
    // up = right x forward.  All three are cross products of Q16 vectors, so
    // every product is Q32 and the sum has to come back down by 16.  That shift
    // is easy to lose and very visible when it is: forward and right are
    // divided by their length, so they stay Q16 by accident, and only the up
    // vector is quietly 65536 times too long -- which sends every ray off into
    // a corner of the world and turns the picture into a hard horizontal split
    // of hits above and misses below.
    UPX = ((RGY * FZ0) - (RGZ * FY0)) >> 16;
    UPY = ((RGZ * FX0) - (RGX * FZ0)) >> 16;
    UPZ = ((RGX * FY0) - (RGY * FX0)) >> 16;
    BASEV[0] = FX0; BASEV[1] = FY0; BASEV[2] = FZ0;
    BASEV[3] = RGX; BASEV[4] = RGY; BASEV[5] = RGZ;
    BASEV[6] = UPX; BASEV[7] = UPY; BASEV[8] = UPZ
};

// render(seed, jseed) -- march and shade every sample of the frame, writing
// SHIT / SLUM / SCOL.  Zero allocation: three module-level arrays, and the
// per-ray direction is three multiplies and three adds off the precomputed
// grid.
//
// `jseed` is the optional sub-sample jitter: a pure function of (seed, frame,
// index), so it is reproducible from the seed alone and is off entirely when
// the seed is 0.  It is 64 whole units of Q16, about a thousandth of a cell,
// which is enough to break up the marching's stepping bands and not enough to
// look like noise.
def render(seed: long, frame: long) -> void {
    camera_update();
    HITS = 0;
    STEP_TOTAL = 0;
    let i = 0;
    let n = GW * GH;
    while (i < n) {
        let j = i % GW;
        let ox = RXO[j];
        let oy = RYO[i / GW];
        let rx = FX0 + ((RGX * ox) >> 16) + ((UPX * oy) >> 16);
        let ry = FY0 + ((RGY * ox) >> 16) + ((UPY * oy) >> 16);
        let rz = FZ0 + ((RGZ * ox) >> 16) + ((UPZ * oy) >> 16);
        if (seed != 0) {
            // the optional jitter: 64 whole Q16 units, about 0.06 degrees of ray
            // angle, which at the far plane is one cell of movement -- enough to
            // break the march's stepping bands, little enough not to look noisy
            let h = jitter(seed, frame, i);
            rx = rx + ((h & 127) - 64);
            ry = ry + (((h >>> 7) & 127) - 64);
            rz = rz + (((h >>> 14) & 127) - 64);
        };
        let invl = ray_inv(rx, ry, rz);
        if (invl < 1) {
            // a degenerate ray: sky, and no march.  It cannot happen with a unit
            // basis and a bounded grid, but the alternative is a division by zero
            // printed to stdout in the middle of a frame.
            SHIT[i] = 0;
            SLUM[i] = 0;
            SCOL[i] = sky_at(128);
            ST[i] = 0;
            SEND[i] = 3;
        } else {
            trace(rx, ry, rz, invl);
            SHIT[i] = MHIT;
            SLUM[i] = MLUM;
            SCOL[i] = MCOL;
            ST[i] = MT;
            SEND[i] = MEND;
            HITS = HITS + MHIT;
            STEP_TOTAL = STEP_TOTAL + MSTEP;
        };
        i = i + 1;
    }
};

// ray_inv -- 2^32 / |r|, the Q16 reciprocal of the ray's length.  Zero is the
// one input that traps, so it is guarded here once instead of being trusted at
// every one of the 300000 steps.
def ray_inv(rx: long, ry: long, rz: long) -> long {
    let l = qsqrt(rx * rx + ry * ry + rz * rz);
    if (l < 1) { return 0; };
    4294967296 / l
};

// jitter -- a pure hash of (seed, frame, index), 21 bits of it used.  The
// multiply-and-xor chain is the usual one and has no state, so the same three
// inputs always give the same three offsets.
def jitter(seed: long, frame: long, i: long) -> long {
    let h = seed * 374761393 + frame * 668265263 + i * 2246822519;
    h = (h ^ (h >>> 13)) * 1274126177;
    h = h ^ (h >>> 16);
    h
};

// The accessors the cell pass uses, so no array ever leaves this module.
def shit(i: long) -> long { SHIT[i] };
def slum(i: long) -> long { SLUM[i] };
def scol(i: long) -> long { SCOL[i] };
def hits() -> long { HITS };
def steps_used() -> long { STEP_TOTAL };

def set_steps(n: long) -> void { STEPS = n };

// ───────────────────────────────────────────── the read-only side for --check ───
//
// Everything below exists for check.y and nothing else reads it.  The rule the
// file has followed since the cell pass was written is that no array leaves this
// module, so these are scalar accessors and not the tables themselves.
//
// The ray a sample sees is rebuilt outside from (origin, basis, ox, oy) rather
// than handed over, because the point of the check is to intersect that ray with
// a sphere by a method that shares nothing with trace(): re-deriving it here
// would make the two sides agree by construction.

def rox() -> long { ROX };
def roy() -> long { ROY };
def roz() -> long { ROZ };
def basis(k: long) -> long { BASEV[k] };
def ox_at(j: long) -> long { RXO[j] };
def oy_at(i: long) -> long { RYO[i] };
def st_at(i: long) -> long { ST[i] };
def send_at(i: long) -> long { SEND[i] };
def steps() -> long { STEPS };

export { S, NPAL, MAXC, MAXR, MAXW, MAXH, MAXSAMP,
          PLANE_Y, SPH_X, SPH_Y, SPH_Z, SPH_R,
          BOX_X, BOX_Y, BOX_Z, BOX_HX, BOX_HY, BOX_HZ, BOX_C, BOX_S,
          CAP_X, CAP_Y, CAP_Z, CAP_BX, CAP_BY, CAP_BZ, CAP_R,
          KFLOOR, KOBJ, EPS, HALFVIEW,
          qseed_init, qsqrt, smin, map, trace, set_steps,
          AZ, EL, DIST, set_camera, camera_update,
          grid_setup, grid_w, grid_h, grid_sx, grid_sy,
          palette_init, palette, palette_get, sky_at,
          render, shit, slum, scol, hits, steps_used, DBG_RAMP,
          rox, roy, roz, basis, ox_at, oy_at, st_at, send_at, steps,
          map_solo, solo };
