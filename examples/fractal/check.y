// check.y -- the property check for fractal.y, and the oracle behind it.
//
// WHY THIS FILE EXISTS
// A golden file proves determinism, not rightness: `cube` passed all eight gate
// items while rendering a defect, because its EXPECTED had been generated from
// the broken output.  So the correctness of this raymarcher rests on assertions
// about behaviour, computed here and asserted at run time, with no reference file
// anywhere in sight.  `EXPECTED` still holds the determinism; this holds the
// geometry.
//
// THE ORACLE, AND WHY IT CANNOT SHARE A BUG WITH THE MARCHER
// The scene contains a real sphere -- centre (SPH_X, SPH_Y, SPH_Z), radius
// SPH_R -- so the closed-form quadratic ray/sphere intersection is available for
// every ray the renderer casts:
//
//     oc = eye - centre,  b = dot(oc, u),  cc = dot(oc,oc) - r^2
//     hits iff  b^2 - cc >= 0,  and the near root is  -b - sqrt(b^2 - cc)
//
// That expression never calls map(), never steps and never runs out of budget,
// so it cannot inherit a step-arithmetic bug, a convergence bug or an epsilon
// bug.  Every square root here is fx.isqrt -- an exact integer root, and a
// different implementation from scene.qsqrt's 2048-entry table -- and every
// primitive distance is re-derived in closed form rather than asked of the scene.
// What the two sides SHARE is the ray: the projection, the camera basis and the
// grid, because the question is "did the marcher find the surface this ray
// actually hits", and a different ray would be a different question.
//
// WHY IT IS ALL Q16 AND NOT Q30
// Q30 overflows here, which is worth writing down because it looks safe.
// dot(oc, oc) in Q30 is a Q60 product, and with the eye four or five units from
// the sphere's centre that is 5.4^2 * 2^60 = 2.6e19 against a long's 4.6e18 --
// four bits over the top, silently, because nothing here can trap.  Q16 puts the
// same dot at 2^40 with 22 bits in hand.  The one place precision has to be
// bought back is the square root, and it is bought exactly: the square root of a
// Q16 value v is isqrt(v << 30) << 1, whose floor error is two Q16 units = 3e-5
// of a scene unit, against a hit epsilon of 2^-11 = 4.9e-4 that is sixteen times
// coarser.  The oracle is therefore three orders of magnitude sharper than the
// thing it is checking, which is the only way the comparison means anything.
//
// WHAT IS ASSERTED, AND WHY EACH ONE CAN FAIL
//   T0  the field honours smin's contract, min - k/4 <= map(p) <= min, at every
//       point the marcher reported as a hit.  smin's contract is a lower bound on
//       the distance to the nearest surface, and that lower bound is the entire
//       reason sphere tracing is safe; a smin that ever returned MORE than the
//       minimum would step straight through a wall, and the symptom would be a
//       picture that looks plausible.
//   T1  the marched depth agrees with the closed-form root: to 4*EPS on the
//       well-conditioned part of the sphere (clean of every blend, and hitting it
//       at better than 60 degrees of incidence), and to one cell of LATERAL
//       movement everywhere else the marcher hit.
//   T2  a ray the quadratic says misses never reports a hit ON the sphere.  That
//       is the over-hit signature, and it is invisible to a golden file because
//       an over-hit still produces a deterministic picture.
//   T3  the drawn silhouette of a sphere is the ellipse the tangent cone
//       predicts.  Measured on a control scene (scene.solo) where the sphere is
//       the only primitive, so no blend and no occlusion can hide a
//       disagreement, and where three independent derivations of the same
//       ellipse have to agree: the marched and rasterised outline, a brute-force
//       scan of the closed-form quadratic, and the closed-form roots of the
//       conic's extent equation.  Run over a distance sweep, which is also the
//       brief's "the extents move by the predicted amount when the camera
//       moves" -- and which the sweep now ASSERTS in its own right: a sphere of
//       fixed radius must have a smaller silhouette as the camera pulls back, so
//       an oracle whose extents never move fails by inspection, which is exactly
//       how the first version of this file failed.  The tolerances and why they
//       are what they are are written out where they are used, in the T3 block.
//   T4  the step budget changes how far the ground reaches and nothing else.  The
//       set of hit cells over the objects must be identical at 40 and 160 steps,
//       outside a one-cell band at the boundary.
//   T5  where the box and the sphere overlap the nearer surface wins: the marched
//       depth is never behind the analytically nearer root, never in front of it
//       by more than one smooth-minimum bulge can account for, and never closer
//       to the farther surface when the two roots are far apart.
//
// ZERO ALLOCATION, like everything else on this program: every buffer is a
// module-level `let`, every scalar crosses a call boundary as a `long`, and no
// array or record literal is written inside a loop.

import fx;
import scene;
import sink;

// ─────────────────────────────────────────────────────────── the grid ───
//
// The check renders at its own fixed size and never asks the terminal, so its
// answer does not depend on the window it was run in.  120x32 cells of `half` is
// 7 680 samples: enough for the sphere's outline to have several cells of
// boundary to measure against, small enough that the whole suite takes a
// fraction of a second.
const CK_COLS: long = 120;
const CK_ROWS: long = 32;

// ────────────────────────────────────────────────────────── tolerances ───
//
// All Q16 scene units, and every one of them DERIVED rather than guessed.
const T_EPS: long = 32;                  // scene.EPS: 2^-11, the hit epsilon
const T_BULGE: long = 6200;              // the most a smooth-minimum can depress
                                         // the field, and so the most a blended
                                         // surface can sit OUTSIDE the primitive
                                         // it came from.  smin's term is h^2*k/4
                                         // with h = k - |a-b| <= k, so each blend
                                         // contributes at most k^3/4: 2725 for
                                         // KOBJ, 702 for KFLOOR, and map() chains
                                         // three of them -- 2*2725 + 702 = 6152,
                                         // plus the epsilon.  (It is k^3/4 and
                                         // NOT k/4: the first version of this file
                                         // used k/4 and was three times too
                                         // generous, which is the direction that
                                         // hides a defect.)
const T_CORE: long = 128;                // 4*EPS.  A ray hitting the sphere at
                                         // an incidence of at least 60 degrees
                                         // stops short of the true root by at
                                         // most EPS/cos(phi) <= 65
const T_FIELD: long = 512;               // 16*EPS: slack for fx.isqrt against
                                         // scene.qsqrt and for the yaw
                                         // transform's truncation
const T_ON: long = 96;                   // 1.5*EPS: "this marched hit IS on the
                                         // sphere".  The marcher's own rule makes
                                         // any hit within EPS of a surface, so
                                         // this is loose enough to catch an
                                         // over-hit and far tighter than the 0.09
                                         // a blend can add
const T_CLEAN: long = 4096;              // 1/16 of a unit of margin on each
                                         // blend radius when deciding that a
                                         // point is outside every blend zone
const T_COS: long = 39911;               // 0.87 * SPH_R, the incidence limit of
                                         // the core subset: OMISS <= T_COS means
                                         // sin(phi) <= 0.87 and so
                                         // cos(phi) >= 0.49, which puts the
                                         // marched depth within EPS/0.49 = 65 of
                                         // the true root.  (The first version of
                                         // this file wrote 0.87*65536, which is
                                         // LARGER than the radius and therefore
                                         // admits every ray that hits at all --
                                         // including the grazing ones, whose depth
                                         // is legitimately tens of EPS out.)
const T_LAT: long = 78643;               // 1.2 cells, Q16: the lateral
                                         // tolerance for T1 over every ray --
                                         // one cell, plus the most a blend's
                                         // 0.0416 depression can move a point
                                         // across the view

let GW: long = 1;                        // the sample grid, cached
let GH: long = 1;
let CPP: long = 1;                       // cells per unit of tangent, in Q32 -- and
                                          // it is the SAME number on both axes:
                                          // scene's grid_setup gives the frame a
                                          // vertical half-view of HALFVIEW*GH/(GW*2),
                                          // so one CELL is 2*HALFVIEW/GW tall and
                                          // 2*HALFVIEW/GW wide.  The first version
                                          // of this file carried a second constant,
                                          // TWICE this one, for the vertical; that
                                          // was arithmetic, not geometry, and it
                                          // doubled every printed row.  Q32 and not
                                          // Q16 because the exact value is 85.714...,
                                          // Q16 rounds that to 85, and the 0.8% short
                                          // is HALF A CELL at the frame edge -- the
                                          // same size as the band T3 measures against,
                                          // so the constant has to be finer than the
                                          // thing it is compared with.  A conversion
                                          // is (v * CPP) >> 32: v in Q16, answer in whole cells.
let NFAIL: long = 0;

// ──────────────────────────────────────────────────── the ray, rebuilt ───
//
// The same projection render() does, from the same three numbers.
let CB: [long; 9] = [0; 9];
let RX: long = 0;
let RY: long = 0;
let RZ: long = 0;
let RL: long = 0;                        // |r| in Q16, from fx.isqrt
let UX: long = 0;                        // the unit ray, Q16
let UY: long = 0;
let UZ: long = 0;
let EX: long = 0;                        // the eye
let EY: long = 0;
let EZ: long = 0;

def ray_of(i: long) -> void {
    let ox = scene.ox_at(i % GW);
    let oy = scene.oy_at(i / GW);
    RX = CB[0] + ((CB[3] * ox) >> 16) + ((CB[6] * oy) >> 16);
    RY = CB[1] + ((CB[4] * ox) >> 16) + ((CB[7] * oy) >> 16);
    RZ = CB[2] + ((CB[5] * ox) >> 16) + ((CB[8] * oy) >> 16);
    // The length, in one isqrt and no shifts at all: RX*RX is a Q32 square, and
    // isqrt of a Q32 value IS a Q16 value.  Shifting up first is the trap -- the
    // sum of three such squares is already 7.4e10 for the longest ray the frame
    // casts, and << 32 would carry it over the top of a long.
    RL = fx.isqrt(RX * RX + RY * RY + RZ * RZ);
    EX = scene.rox();
    EY = scene.roy();
    EZ = scene.roz();
    if (RL < 1) {
        UX = 0;
        UY = 0;
        UZ = 0;
    } else {
        UX = (RX << 16) / RL;
        UY = (RY << 16) / RL;
        UZ = (RZ << 16) / RL
    }
};

// at(t) -- where the marcher landed, from its own ray parameter.  Exactly the
// arithmetic trace() does, so it introduces no disagreement of its own.
let PX: long = 0;
let PY: long = 0;
let PZ: long = 0;

def at(t: long) -> void {
    PX = EX + ((RX * t) >> 16);
    PY = EY + ((RY * t) >> 16);
    PZ = EZ + ((RZ * t) >> 16)
};

// atw(d) -- where the ORACLE says the surface is, from the unit ray and a world
// depth.  This is the point the analytic root is about, which is the one the
// clean/blend test has to be made at.
def atw(d: long) -> void {
    PX = EX + ((UX * d) >> 16);
    PY = EY + ((UY * d) >> 16);
    PZ = EZ + ((UZ * d) >> 16)
};

// wdepth(t) -- the marcher's ray parameter in WORLD units: t is in units of the
// un-normalised r, so the depth is t*|r|.
def wdepth(t: long) -> long { (t * RL) >> 16 };

// ─────────────────────────────────────────────── the closed-form sphere ───
//
// Answers in module state rather than a record: there are thousands of these a
// pose, and a record is a heap allocation (ORCHESTRATOR.md 2.7).
let OHIT: long = 0;                      // 0 misses, 1 hits, 2 the eye is inside
let ODEPTH: long = 0;                    // the near root, Q16 world units
let OMISS: long = 0;                     // the perpendicular distance from the
                                         // centre to the ray line: sqrt(r^2-d)
let ODISC: long = 0;                     // b^2 - (dot(oc,oc) - r^2), Q16

def sph() -> void {
    let ox = EX - scene.SPH_X;
    let oy = EY - scene.SPH_Y;
    let oz = EZ - scene.SPH_Z;
    let rr = scene.SPH_R;
    // u is not EXACTLY unit and pretending it is was the subtlest bug in the
    // first version of this file.  RL is floor(|r|), so (r<<16)/RL is up to
    // 1/RL = 1.2e-5 too long -- and a quadratic solved with |u| assumed to be 1
    // when it is 1+1.2e-5 puts the near root 3e-3 of a scene unit too far out
    // for an eye eight units away.  That is 200 march steps' worth of the hit
    // epsilon, and it would have looked exactly like a marcher that stops early.
    // So the quadratic carries |u|^2 instead of assuming it away:
    //
    //     |u|^2 t^2 + 2 (u.oc) t + (|oc|^2 - r^2) = 0
    //     t = ( -b - sqrt(b^2 - |u|^2 cc) ) / |u|^2
    let uu = ((UX * UX + UY * UY + UZ * UZ) >> 16);
    let b = ((ox * UX) + (oy * UY) + (oz * UZ)) >> 16;
    let cc = (((ox * ox) + (oy * oy) + (oz * oz)) >> 16) - ((rr * rr) >> 16);
    // Cauchy-Schwarz caps the discriminant at |u|^2 r^2 -- and |u|^2 r^2 is NOT
    // small: it is 2.8e10 for the poses below, because it is a Q16 length
    // squared.  The first version of this file clamped the discriminant at
    // 262144 on the belief that the cap made that "unreachable".  It did not, it
    // clamped almost every ray, and the clamp propagated: OMISS below went to
    // zero for every ray that passed more than 4 units of squared distance from
    // the centre, which is most of them, so the angle-corrected tolerances in T1
    // and T2 were silently measuring nothing.  The clamp is now derived instead
    // of guessed: the identity
    //
    //     d = b^2 - uu cc = uu (|oc|^2 - r^2 - sin^2(phi)),   sin(phi) <= 1
    //
    // puts d at or below uu (|oc|^2 - r^2), and under that it goes arbitrarily
    // negative.  Clamping at the cap can only make a miss look like a hit, which
    // is the safe direction; what matters is that d is never clamped SMALLER than
    // its own cap, which is what the old constant did.
    let dcap = ((uu * ((rr * rr) >> 16)) >> 16);
    let d = ((b * b) >> 16) - ((uu * cc) >> 16);
    if (d > dcap) { d = dcap };
    ODISC = d;
    // The perpendicular distance from the centre to the ray LINE, which is also
    // the sine of the incidence times r: sin(phi) = miss / r.  It is what makes
    // the depth tolerance angle-correct without any trigonometry, and it is
    // wanted for a MISSING ray too -- how far outside the tangent cone a ray
    // passes is exactly what T2 needs to know.
    //
    //     miss^2 = r^2 - d/uu
    //
    // and BOTH terms have to be lifted to Q32 before they are subtracted: the
    // first version of this file wrote (r^2*uu - d)/uu, which subtracts a Q16 from
    // a Q32 product -- 65536 times too little d.  The effect was that OMISS never
    // rose above r, so every "this ray passed how far outside the cone?" question
    // in T2 and every angle-corrected tolerance in T1 was answered with r.
    //
    // The `<< 16` on d also makes fx.isqrt safe here by construction rather than
    // by a guard: the clamp above is Cauchy-Schwarz, d <= |u|^2 r^2, so
    // r^2 - d/uu >= 0 always -- for d < 0 a fortiori.  There is no negative
    // argument to reject after all, and that is the better way round: the earlier
    // clamp at a hand-picked 262144 was neither the Cauchy-Schwarz bound nor
    // large enough, so it truncated most rays and turned this square root into 0.
    //
    // The trailing `<< 16` is the other half of the same rule: the quotient is a
    // Q16 number and isqrt of a Q16 number is a Q0 ROOT, so a tangent ray -- whose
    // answer is r = 0.7 -- came back as 0.0027, 256 times too small.  isqrt's
    // argument has to be lifted to Q32 to get a length out, exactly as the root
    // below does.  That error was invisible in every count (a smaller miss only
    // ever looks like a better-conditioned ray) and it emptied T1's core subset of
    // grazing rays, which is the one population the depth tolerance is about.
    OMISS = fx.isqrt((((((rr * rr) >> 16) * uu) - (d << 16)) / uu) << 16);
    if (d < 0) {
        OHIT = 0;
        ODEPTH = 0;
        return;
    };
    // The square root of a Q16 value, in Q16: isqrt(v << 16) = sqrt(v)*256 =
    // sqrt(v/65536)*65536.  The shift is 16 -- sqrt(v<<32) would be 256 times too
    // big, which is a plausible-looking number rather than an obvious one.
    let s = fx.isqrt(d << 16);
    let num = 0 - b - s;
    if (num < 0) {
        // The eye is inside the sphere, where the field is negative and the
        // marcher reports a hit at t = 0.  Flagged, never asserted on: the poses
        // below keep the eye outside every primitive, and if one did not, the
        // count would say so.
        OHIT = 2;
        ODEPTH = 0;
        return;
    };
    OHIT = 1;
    // The << 16 is the whole point and the first version of this file left it
    // out.  `num` and `uu` are BOTH Q16, so `num / uu` is their RATIO -- a
    // dimensionless number of scene units that came out as 2 for every ray,
    // because the true root was 2.02 units along and 1.856 for a central one, and
    // both truncate to 2.  The root then read as a fixed two units from the eye
    // no matter where the sphere was, and T1 reported every single ray in the
    // frame as having stopped deeper than the analytic surface.  A Q16 divided by
    // a Q16 is Q0; to divide lengths and stay in lengths, lift the numerator.
    ODEPTH = (num << 16) / uu
};

// ───────────────────────────────────────────────── the closed-form box ───
//
// The slab test, in the box's own yawed frame -- the same rotation map() applies
// and no other machinery.  AABB in, near root out.
let TB0: long = 0;
let TB1: long = 0;
let OBH: long = 0;
let OBDEPTH: long = 0;
let BIG: long = 1099511627776;           // 2^40: an interval no surface is at
                                         // the end of

def slab(pa: long, va: long, lo: long, hi: long) -> long {
    let a = lo - pa;
    let b = hi - pa;
    if (va == 0) {
        if (a > 0 || b < 0) { return 0 };
        return 1;
    };
    // Both planes divide by the same direction, and Y's division truncates toward
    // zero, which is monotonic in the numerator for either sign of va -- so the
    // swap below cannot be an artefact of rounding.
    let x0 = (a << 16) / va;
    let x1 = (b << 16) / va;
    let t0 = x0;
    let t1 = x1;
    if (x1 < x0) { t0 = x1; t1 = x0 };
    if (t0 > TB0) { TB0 = t0 };
    if (t1 < TB1) { TB1 = t1 };
    if (TB0 > TB1) { return 0 };
    1
};

def boxt() -> void {
    let c = scene.BOX_C;
    let s = scene.BOX_S;
    TB0 = 0 - BIG;
    TB1 = BIG;
    let ok = slab(((c * EX) - (s * EZ)) >> 16, ((c * UX) - (s * UZ)) >> 16,
                  scene.BOX_X - scene.BOX_HX, scene.BOX_X + scene.BOX_HX);
    if (ok != 0) {
        ok = slab(EY, UY, scene.BOX_Y - scene.BOX_HY, scene.BOX_Y + scene.BOX_HY)
    };
    if (ok != 0) {
        ok = slab(((c * EZ) + (s * EX)) >> 16, ((c * UZ) + (s * UX)) >> 16,
                  scene.BOX_Z - scene.BOX_HZ, scene.BOX_Z + scene.BOX_HZ)
    };
    if (ok == 0 || TB1 <= 0) {
        OBH = 0;
        OBDEPTH = 0;
        return;
    };
    OBH = 1;
    OBDEPTH = if (TB0 < 0) { 0 } else { TB0 }
};

// ─────────────────────────────── the primitive distances, in closed form ───
//
// Used to decide whether a point is inside a blend zone, and to check that map()
// honours smin's contract.  Each is the textbook distance for its primitive,
// written from the same constants the scene uses and never asked of it.

def abs2(v: long) -> long { if (v < 0) { 0 - v } else { v } };

def max3(a: long, b: long, c: long) -> long {
    let m = a;
    if (b > m) { m = b };
    if (c > m) { m = c };
    m
};

// sph_d(p) -> long -- the signed distance to the sphere, positive outside.
def sph_d(px: long, py: long, pz: long) -> long {
    let dx = px - scene.SPH_X;
    let dy = py - scene.SPH_Y;
    let dz = pz - scene.SPH_Z;
    fx.isqrt(dx * dx + dy * dy + dz * dz) - scene.SPH_R
};

// box_d(p) -> long -- the exact box SDF, in the box's frame.
def box_d(px: long, py: long, pz: long) -> long {
    let c = scene.BOX_C;
    let s = scene.BOX_S;
    let qx = abs2((((c * px) - (s * pz)) >> 16) - scene.BOX_X) - scene.BOX_HX;
    let qy = abs2(py - scene.BOX_Y) - scene.BOX_HY;
    let qz = abs2((((c * pz) + (s * px)) >> 16) - scene.BOX_Z) - scene.BOX_HZ;
    let ox = if (qx < 0) { 0 } else { qx };
    let oy = if (qy < 0) { 0 } else { qy };
    let oz = if (qz < 0) { 0 } else { qz };
    let m = max3(qx, qy, qz);
    fx.isqrt(ox * ox + oy * oy + oz * oz) + (if (m < 0) { m } else { 0 })
};

// cap_d(p) -> long -- the exact capsule distance along its stored axis, which
// scene already holds normalised.
def cap_d(px: long, py: long, pz: long) -> long {
    let cx = px - scene.CAP_X;
    let cy = py - scene.CAP_Y;
    let cz = pz - scene.CAP_Z;
    let h = ((cx * scene.CAP_BX) + (cy * scene.CAP_BY) + (cz * scene.CAP_BZ)) >> 16;
    let hc = 0;
    if (h > scene.S) { hc = scene.S } else if (h > 0) { hc = h };
    let qx = cx - ((scene.CAP_BX * hc) >> 16);
    let qy = cy - ((scene.CAP_BY * hc) >> 16);
    let qz = cz - ((scene.CAP_BZ * hc) >> 16);
    fx.isqrt(qx * qx + qy * qy + qz * qz) - scene.CAP_R
};

// min4(p) -> long -- the plain minimum of the four primitive distances, which is
// what map() must return with no smooth-minimum active.
def min4(px: long, py: long, pz: long) -> long {
    let m = py - scene.PLANE_Y;
    let b = sph_d(px, py, pz);
    if (b < m) { m = b };
    let c = box_d(px, py, pz);
    if (c < m) { m = c };
    let d = cap_d(px, py, pz);
    if (d < m) { m = d };
    m
};

// clean(p) -> long -- 1 when no smooth-minimum is active at p, so the field
// there is exactly min(a,b,c,d) and the sphere's own surface IS the surface.
//
// A blend is active iff some |a - b| < k; near the sphere a is ~0, so the
// condition is that every OTHER primitive is at least its own blend radius away.
// The T_CLEAN margin is there because a point just outside the zone can still
// have the marcher's previous step inside it, and the marcher's last step is up
// to EPS long.
//
// The plane test is `py - PLANE_Y`, the signed distance to the ground, and the
// first version of this file wrote `px - PLANE_Y` -- the point's X minus the
// plane's Y.  It nearly always passed by accident, so it did not empty the core
// subset; but on the poses where it happened to fail it was excluding rays for
// no reason at all, and a test whose pass/fail does not mean anything is worse
// than no test.
def clean(px: long, py: long, pz: long) -> long {
    let ok = 1;
    if (py - scene.PLANE_Y < scene.KFLOOR + T_CLEAN) { ok = 0 };
    if (box_d(px, py, pz) < scene.KOBJ + T_CLEAN) { ok = 0 };
    if (cap_d(px, py, pz) < scene.KOBJ + T_CLEAN) { ok = 0 };
    ok
};

// ────────────────────────────────────────────────── cells, and printing ───

// lcell(t) -> long -- one cell's worth of world units, laterally, at depth t.
// One cell spans 2*HALFVIEW/GW in tangent, and one tangent unit at depth t is t
// world units.
def lcell(t: long) -> long {
    let d = t * (2 * scene.HALFVIEW) / (GW << 16);
    if (d < 1) { 1 } else { d }
};

// cells_h(v) -> long -- a horizontal tangent offset in Q16, as a column index
// from the left edge of the frame.  v = -HALFVIEW is column 0.
def cells_h(v: long) -> long { ((v * CPP) >> 32) + GW / 2 };

// cells_v(v) -> long -- the same vertically, as a CELL ROW from the TOP, so it
// SUBTRACTS: oy grows upward (scene.RYO puts row 0 at the top of the frame) while
// a cell row counts down.
//
// It is derived rather than guessed.  Sample row i sits at (GH-2i-1)*vh/GH, a
// cell is two samples, so cell row c -- whose centre sample is i = 2c+1 -- sits at
// (GH-4c-3)*vh/GH with vh = HALFVIEW*GH/(GW*2).  Inverting, with CPP the Q32
// cells per tangent unit:
//
//     c = (GH-4c-3)*vh/GH  =>  c = (GH-3)/4 - v*GH/(4*vh) = (GH-3)/4 - v*CPP
//
// so c = floor(16 - v*CPP) for GH = 64, i.e. GH/4 - ceil(v*CPP), which as a shift
// is GH/4 + ((-v*CPP) >> 32).  That form is EXACT on the samples that decide the
// silhouette: the two samples of the top cell row sit at v*CPP = 15.247 and 15.747
// and both give row 0, and the two of the bottom row at -15.247 and -15.747 both
// give row 31.
//
// The first version of this file ADDED the offset instead of subtracting it, on a
// vertical scale twice as large as the horizontal one.  The two errors very
// nearly cancelled: the printed row came out at exactly TWICE the right one, so
// the analytic column read 0..63 at a camera distance where the marched column
// read 0..31, and the comparison between them was between two different
// quantities.  It "looked like" a silhouette twice as tall as the frame.
def cells_v(v: long) -> long { GH / 4 + (((0 - v) * CPP) >> 32) };

// rs(v) -> str -- a Q16 value as a decimal.  fx.to_str takes Q30 and the shift is
// the conversion it documents.
def rs(v: long) -> str { fx.to_str(v << 14) };

// cpad(v, w) -- a right-aligned cell index in w columns, with a sign when it is
// negative.  sink.out_pad clamps a negative to zero on purpose -- it prints
// counts, and a clamped count at least reads as "none" -- but a cell index off the
// edge of the frame is not a count: clamped to zero it reads as "the silhouette
// touches the first column", which is the opposite of the truth.
def cpad(v: long, w: long) -> void {
    if (v < 0) {
        sink.out_str(" -");
        sink.out_pad(0 - v, w - 2)
    } else {
        sink.out_pad(v, w)
    }
};

def fail(tag: str) -> void {
    NFAIL = NFAIL + 1;
    sink.out_str("  FAIL  ");
    sink.out_str(tag);
    sink.out_str("\n")
};

def rp(tag: str, v: long) -> void {
    sink.out_str(tag);
    sink.out_pad(v, 12)
};

// ─────────────────────────────────────────────── the analytic silhouette ───
//
// A sphere under a pinhole camera projects to a conic, and specifically to an
// ellipse: its silhouette is the image plane's section through the cone tangent
// to the sphere from the eye, and a circular cone's section by a plane that
// misses its vertex is an ellipse.  No trigonometry is needed to find it.  Write
// the ray as d = F + ox*R + oy*U for the camera basis, and the quadratic a ray
// through the sphere solves,
//
//     |eye + t*d - centre|^2 = r^2
//
// is t^2|d|^2 + 2t(d.oc) + (|oc|^2 - r^2) = 0, which has a real root iff
//
//     (d.oc)^2 >= K*|d|^2,        K = |oc|^2 - r^2,  oc = eye - centre
//
// With A = F.oc, B = R.oc, C = U.oc that is a QUADRATIC in (ox, oy) -- the conic.
// Written out in full, and deliberately WITHOUT assuming the basis is
// orthonormal, because it is only orthonormal to about 1e-4 (the cross products
// are truncated to Q16 and the renderer does not renormalise `up`):
//
//     P2 ox^2 + 2 Pxy ox oy + P3 oy^2 + 2 Q1 ox + 2 Q2 oy + Q0 = 0
//
//     P2 = B^2 - K|R|^2      P3 = C^2 - K|U|^2     Pxy = B*C - K(R.U)
//     Q1 = A*B - K(F.R)      Q2 = A*C - K(F.U)     Q0  = A^2 - K|F|^2
//
// Make the basis orthonormal and every Gram term collapses to 0 or 1, and this
// becomes (A + B ox + C oy)^2 = K(1 + ox^2 + oy^2).  The horizontal extent is the
// set of ox for which the quadratic in oy has a real root at all, which by the
// same "discriminant of a quadratic" step is a quadratic in ox:
//
//     (Pxy^2 - P3*P2) ox^2 + 2(Pxy*Q2 - P3*Q1) ox + (Q2^2 - P3*Q0) >= 0
//
// (and the vertical extent swaps ox and oy).  Its two roots are the tangent
// points' image positions, so the closed form is exact.  Put the sphere dead
// ahead and it collapses further still, to ox^2 = r^2/(D^2 - r^2), which is
// tan(asin(r/D)): the textbook cone half-angle, recovered from the algebra.
let CA: long = 0;
let CBB: long = 0;
let CC: long = 0;
let CK: long = 0;
let P2: long = 0;
let P3: long = 0;
let PXY: long = 0;
let Q1: long = 0;
let Q2: long = 0;
let Q0: long = 0;
let GRAMW: long = 0;                     // worst |Gram - identity|, Q16
let CX0: long = 0;                       // the two roots, min and max
let CX1: long = 0;
let QX0: long = 0;
let QX1: long = 0;
let QY0: long = 0;
let QY1: long = 0;
let QOK: long = 0;

// conic_solve(p, q, s) -> long -- the roots of p*x^2 + 2q*x + s = 0, in Q16, into
// CX0 and CX1.  Returns 0 for a degenerate or imaginary pair.
//
// p, q and s are Q16, so q*q - p*s is Q32 and isqrt of a Q32 value is a Q16
// value: the square root needs no shift either.  It stays well inside isqrt's
// range -- these coefficients are all under 2^23, so the discriminant is at most
// 2^50.
//
// Two scale mistakes lived here, and they were the reason the conic column read
// `60 60 32 32` -- both roots at the exact centre of the frame, at every
// distance, which is the one answer a moving sphere cannot give:
//
//   * `isqrt(4*d)` instead of `isqrt(d)`: the root formula already carries the
//     factor of two from the 2q in `p x^2 + 2q x + s`, so squaring it back in
//     doubled the separation of the pair;
//   * and `(0-q-sd)/p`, which divides two Q16 numbers and so returns the ratio
//     rather than a tangent offset.  Both roots truncate to 0 -- the roots are
//     0.029 and -0.580 in tangent units, i.e. 1942 and -38032 in Q16, and
//     dividing before the lift divides 1942 by 65536.  A Q16 divided by a Q16 is
//     Q0, so the << 16 is what turns the ratio back into a length.
def conic_solve(p: long, q: long, s: long) -> long {
    let d = (q * q) - (p * s);
    CX0 = 0;
    CX1 = 0;
    if (p == 0 || d < 0) { return 0 };
    let sd = fx.isqrt(d);
    let x0 = ((0 - q - sd) << 16) / p;
    let x1 = ((0 - q + sd) << 16) / p;
    CX0 = if (x0 < x1) { x0 } else { x1 };
    CX1 = if (x0 < x1) { x1 } else { x0 };
    1
};

// gram_err(...) -> long -- the largest departure of the basis from orthonormal,
// in Q16.  Nothing in conic_init assumes it is zero; this is measured and
// reported, because a camera basis that is not orthonormal shears the picture and
// it is worth knowing by how much.
def gram_err(ff: long, rr: long, uu: long, fr: long, fu: long, ru: long) -> long {
    let one = 4294967296;                 // 1.0 in Q32
    let w = abs2(ff - one);
    let e = abs2(rr - one);
    if (e > w) { w = e };
    e = abs2(uu - one);
    if (e > w) { w = e };
    e = abs2(fr);
    if (e > w) { w = e };
    e = abs2(fu);
    if (e > w) { w = e };
    e = abs2(ru);
    if (e > w) { w = e };
    w >> 16
};

def conic_init() -> void {
    let ox = EX - scene.SPH_X;
    let oy = EY - scene.SPH_Y;
    let oz = EZ - scene.SPH_Z;
    CA = ((CB[0] * ox) + (CB[1] * oy) + (CB[2] * oz)) >> 16;
    CBB = ((CB[3] * ox) + (CB[4] * oy) + (CB[5] * oz)) >> 16;
    CC = ((CB[6] * ox) + (CB[7] * oy) + (CB[8] * oz)) >> 16;
    CK = (((ox * ox) + (oy * oy) + (oz * oz)) >> 16) - ((scene.SPH_R * scene.SPH_R) >> 16);
    // The Gram matrix of the basis: |F|^2, |R|^2, |U|^2 are Q32, and the three
    // dot products are kept at Q32 too (they are small, but mixing widths is how
    // the first version of this file got the whole conic wrong).
    let ff = CB[0] * CB[0] + CB[1] * CB[1] + CB[2] * CB[2];
    let rr = CB[3] * CB[3] + CB[4] * CB[4] + CB[5] * CB[5];
    let uu = CB[6] * CB[6] + CB[7] * CB[7] + CB[8] * CB[8];
    let fr = CB[0] * CB[3] + CB[1] * CB[4] + CB[2] * CB[5];
    let fu = CB[0] * CB[6] + CB[1] * CB[7] + CB[2] * CB[8];
    let ru = CB[3] * CB[6] + CB[4] * CB[7] + CB[5] * CB[8];
    GRAMW = gram_err(ff, rr, uu, fr, fu, ru);
    // The conic's six coefficients.  B^2 is a Q32 product of Q16s and K|R|^2 is a
    // Q48 one -- K is Q16 -- so the first term is lifted to Q48 before the
    // subtraction and the whole thing comes back down to Q16.  Getting this
    // scaling wrong is silent: the terms are of the same order of magnitude in
    // the CODE and two orders apart in the ARITHMETIC, and the conic that comes
    // out is a different shape that still looks like an ellipse.
    P2 = (((CBB * CBB) << 16) - CK * rr) >> 32;
    P3 = (((CC * CC) << 16) - CK * uu) >> 32;
    PXY = (((CBB * CC) << 16) - CK * ru) >> 32;
    Q1 = (((CA * CBB) << 16) - CK * fr) >> 32;
    Q2 = (((CA * CC) << 16) - CK * fu) >> 32;
    Q0 = (((CA * CA) << 16) - CK * ff) >> 32;
    QOK = 0;
    QX0 = 0;
    QX1 = 0;
    QY0 = 0;
    QY1 = 0;
    let ok1 = 0;
    let ok2 = 0;
    let ax = (PXY * PXY - P3 * P2) >> 16;
    if (ax != 0) {
        ok1 = conic_solve(ax, (PXY * Q2 - P3 * Q1) >> 16, (Q2 * Q2 - P3 * Q0) >> 16);
        QX0 = CX0;
        QX1 = CX1
    };
    let ay = (PXY * PXY - P2 * P3) >> 16;
    if (ay != 0) {
        ok2 = conic_solve(ay, (PXY * Q1 - P2 * Q2) >> 16, (Q1 * Q1 - P2 * Q0) >> 16);
        QY0 = CX0;
        QY1 = CX1
    };
    if (ok1 != 0 && ok2 != 0) { QOK = 1 }
};

// ─────────────────────────────────────────────────────────── the poses ───
//
// Eight around the orbit at four distances and four elevations, plus a distance
// sweep for the control scene.  Azimuth steps 60 degrees from the opening pose;
// the elevation and the distance index by k%4, so consecutive poses differ in
// every axis at once and no two share a geometry.
let P_AZ: [long; 8] = [14296, 53618, 92940, 132262, 171584, 210906, 250228, 289550];
let P_EL: [long; 4] = [2294, 16022, 27448, 33437];
let P_DI: [long; 4] = [301465, 196608, 425984, 589824];
let P_SW: [long; 5] = [163840, 196608, 262144, 360448, 524288];

def load_basis() -> void {
    let j = 0;
    while (j < 9) {
        CB[j] = scene.basis(j);
        j = j + 1
    }
};

def pose(k: long) -> void {
    scene.set_camera(P_AZ[k % 8], P_EL[k % 4], P_DI[k % 4]);
    scene.render(0, 0);
    load_basis()
};

// ══════════════════════════════════════════════ T0 + T1 + T2 + T5 ═══════
//
// One sweep of the current frame, because all four want the same ray and the
// same closed-form sphere.
let F_N: long = 0;
let F_HIGH: long = 0;                    // worst map(p) - min, which must be <= 0
let F_LOW: long = 0;                     // worst (min - k/4) - map(p)

let S_A: long = 0;                       // rays the quadratic says hit
let S_AH: long = 0;                      // of those, the marcher also hit
let S_AM: long = 0;                      // of those, the marcher missed
let S_AMB: long = 0;                     // ... the budget ran out
let S_AMF: long = 0;                     // ... the ray left past the far plane
let S_INS: long = 0;                     // the eye was inside the sphere
let S_BEHIND: long = 0;                  // marched deeper than the true root
let S_W: long = 0;                       // worst |depth error|, Q16
let S_WC: long = 0;                      // ... at this column
let S_WR: long = 0;                      // ... and this row
let S_LAT: long = 0;                     // worst of it, in lateral CELLS
let S_CORE: long = 0;                    // the well-conditioned subset
let S_CW: long = 0;                      // worst |depth error| there, Q16
let S_CWC: long = 0;
let S_CWR: long = 0;
let S_CL: long = 0;                      // worst lateral there, in cells
let S_NEAR: long = 0;                    // rays whose depth was within a cell
// the neighbourhood of the worst core disagreement, so the report can say WHAT
// was near it rather than only how far off it was
let S_CT: long = 0;                      // the marched depth there
let S_CA: long = 0;                      // the analytic root there
let S_CSD: long = 0;                     // sphere distance at the marched point
let S_CMD: long = 0;                     // map() there
let S_CDB: long = 0;                     // closed-form box distance there
let S_CDC: long = 0;                     // ... capsule
let S_CDP: long = 0;                     // ... plane
let S_CAN: long = 0;                     // the analytic point's sphere distance:
                                         // the ORACLE's own residual, which is
                                         // what says whether the disagreement is
                                         // the marcher's or this file's
let S_CMISS: long = 0;                   // sin(phi)*r at the worst sample

let M_A: long = 0;                       // rays the quadratic says miss, hit
let M_W: long = 0;                       // worst (r - distance to the centre)
let M_GAP: long = 0;                     // worst (miss - r): how far outside the
                                         // tangent cone a hit ray stopped on the
                                         // sphere -- the over-hit measure itself
let M_BAD: long = 0;                     // ... and unexcused by epsilon or blend

let B_N: long = 0;                       // sphere and box both hit, far apart
let B_SPH: long = 0;                     // the sphere was the nearer one
let B_BOX: long = 0;                     // the box was
let B_REV: long = 0;                     // the marcher sided with the farther
let B_W: long = 0;                       // worst (depth - nearer root), Q16
let B_OUT: long = 0;                     // outside [-bulge, +one cell]

def sweep() -> void {
    let n = GW * GH;
    let i = 0;
    while (i < n) {
        ray_of(i);
        if (RL >= 1) {
            let hit = scene.shit(i);
            let end = scene.send_at(i);
            let t = scene.st_at(i);
            // ── T0: the field honours smin's contract where the march stopped
            if (hit != 0) {
                at(t);
                let pmin = min4(PX, PY, PZ);
                let md = scene.map(PX, PY, PZ);
                F_N = F_N + 1;
                if (md - pmin > F_HIGH) { F_HIGH = md - pmin };
                if (pmin - (scene.KOBJ / 4) - md > F_LOW) {
                    F_LOW = pmin - (scene.KOBJ / 4) - md
                }
            };
            sph();
            if (OHIT == 2) {
                S_INS = S_INS + 1
            } else {
                if (OHIT == 1) {
                    // ── T1: the marched depth against the closed-form root
                    S_A = S_A + 1;
                    if (hit != 0) {
                        let d = wdepth(t) - ODEPTH;
                        let ad = if (d < 0) { 0 - d } else { d };
                        S_AH = S_AH + 1;
                        if (d > T_BULGE + lcell(ODEPTH)) { S_BEHIND = S_BEHIND + 1 };
                        if (ad > S_W) {
                            S_W = ad;
                            S_WC = i % GW;
                            S_WR = i / GW;
                        };
                        // The same error as a picture sees it: how far the point
                        // moved ACROSS the view.  sin(phi) = miss/r, and there is
                        // no trigonometry in that.
                        let lat = (ad * OMISS * GW) / (scene.SPH_R * lcell(ODEPTH));
                        if (lat > S_LAT) { S_LAT = lat };
                        if (ad <= lcell(ODEPTH)) { S_NEAR = S_NEAR + 1 };
                        if (OMISS <= T_COS) {
                            atw(ODEPTH);
                            if (clean(PX, PY, PZ) != 0) {
                                S_CORE = S_CORE + 1;
                                if (ad > S_CW) {
                                    S_CW = ad;
                                    S_CWC = i % GW;
                                    S_CWR = i / GW;
                                    S_CT = wdepth(t);
                                    S_CA = ODEPTH;
                                    at(t);
                                    S_CSD = sph_d(PX, PY, PZ);
                                    S_CMD = scene.map(PX, PY, PZ);
                                    S_CDB = box_d(PX, PY, PZ);
                                    S_CDC = cap_d(PX, PY, PZ);
                                    S_CDP = PY - scene.PLANE_Y;
                                    S_CMISS = OMISS;
                                    atw(ODEPTH);
                                    S_CAN = sph_d(PX, PY, PZ)
                                };
                                if (lat > S_CL) { S_CL = lat }
                            }
                        }
                    } else {
                        S_AM = S_AM + 1;
                        if (end == 2) { S_AMF = S_AMF + 1 } else { S_AMB = S_AMB + 1 }
                    }
                } else if (hit != 0) {
                    // ── T2: a ray that provably misses must not stop on the
                    // sphere.  Two things excuse a hit here and only two: a
                    // smooth-minimum bulge, and the epsilon itself -- a ray that
                    // passes within EPS of the sphere's surface puts the field
                    // below EPS at its closest approach, so the marcher calls
                    // that a hit and the quadratic calls it a miss, and both are
                    // right.  Anything else is an over-hit and fails.
                    at(t);
                    let sd = sph_d(PX, PY, PZ);
                    M_A = M_A + 1;
                    if (0 - sd > M_W) { M_W = 0 - sd };
                    if (OMISS - scene.SPH_R > M_GAP) { M_GAP = OMISS - scene.SPH_R };
                    if (sd < T_ON && OMISS - scene.SPH_R > 2 * T_EPS
                        && clean(PX, PY, PZ) != 0) {
                        M_BAD = M_BAD + 1
                    }
                };
                // ── T5: where the box and the sphere overlap, the nearer wins
                boxt();
                if (OHIT == 1 && OBH == 1) {
                    let sep = ODEPTH - OBDEPTH;
                    if (sep < 0) { sep = 0 - sep };
                    if (sep > 2 * (T_BULGE + lcell(ODEPTH))) {
                        let tw = wdepth(t);
                        let near = if (ODEPTH < OBDEPTH) { ODEPTH } else { OBDEPTH };
                        let da = tw - ODEPTH;
                        if (da < 0) { da = 0 - da };
                        let db = tw - OBDEPTH;
                        if (db < 0) { db = 0 - db };
                        B_N = B_N + 1;
                        if (da < db) {
                            B_SPH = B_SPH + 1;
                            if (ODEPTH > OBDEPTH) { B_REV = B_REV + 1 }
                        } else {
                            B_BOX = B_BOX + 1;
                            if (ODEPTH < OBDEPTH) { B_REV = B_REV + 1 }
                        };
                        let e = tw - near;
                        if (e > B_W) { B_W = e };
                        if (e > lcell(near) || e < 0 - T_BULGE) { B_OUT = B_OUT + 1 }
                    }
                }
            }
        };
        i = i + 1
    }
};

// ══════════════════════════════════════════════════════════ T3: control ═══
//
// The same marcher, camera, grid and cell pass, with the field reduced to the
// sphere alone (scene.solo).  With no blend and nothing in front of it, a hit IS
// the sphere -- so this is the one place the silhouette can be compared exactly.
let E_A: long = 0;                       // analytic sphere hits, by scan
let E_HIT: long = 0;                     // of those, the marcher hit
let E_MISS: long = 0;                    // analytic hit, marcher missed
let E_FP: long = 0;                      // marcher hit, analytic miss
let E_X0: long = 0;                      // the brute-force tangent extents
let E_X1: long = 0;
let E_Y0: long = 0;
let E_Y1: long = 0;
let E_D0: long = 0;                      // the drawn outline, in cells
let E_D1: long = 0;
let E_E0: long = 0;
let E_E1: long = 0;
let E_CLIP: long = 0;                     // bit 1 left, 2 right, 4 top, 8 bottom:
                                          // that edge of the scan's extent is the
                                          // FRAME's edge, so the ellipse is known to
                                          // continue past it and the scan cannot be
                                          // compared with the conic's root there
let E_CLEDGE: long = 0;                   // how many (pose, edge) pairs the ellipse
                                          // was seen to leave the frame on
let E_WO: long = 0;                       // worst OVERSHOOT of the marched
                                          // outline past the analytic extent, in
                                          // cells; must never be positive
let E_WI: long = 0;                       // worst SHRINKAGE of it, in cells;
                                          // the band is 1
let E_WX: long = 0;                       // worst |scan - conic| across, in cells
let E_WY: long = 0;                       // ... and down, in cells.  The pitches
                                          // differ (one sample per cell across,
                                          // two per cell down) so the bands do too
let E_GAP: long = 0;                      // worst (analytic miss - r) over the
                                          // rays the marcher hit and the quadratic
                                          // called a miss
let E_GROW: long = 0;                     // times the SCAN's extents failed to
                                          // shrink as the camera pulled back
let E_SW0: long = 0;                      // the scan's width at the nearest and
let E_SW1: long = 0;                      // ... the farthest camera
let E_PREV: long = 0;                     // the previous pose's scan width

def ellipse() -> long {
    let n = GW * GH;
    let i = 0;
    let first = 1;
    E_A = 0;
    E_HIT = 0;
    E_MISS = 0;
    E_WO = 0;
    E_WI = 0;
    E_CLIP = 0;
    while (i < n) {
        ray_of(i);
        if (RL >= 1) {
            sph();
            let hit = scene.shit(i);
            let ox = scene.ox_at(i % GW);
            let oy = scene.oy_at(i / GW);
            if (OHIT == 1) {
                E_A = E_A + 1;
                if (first != 0) {
                    E_X0 = ox;
                    E_X1 = ox;
                    E_Y0 = oy;
                    E_Y1 = oy;
                    first = 0;
                };
                if (ox < E_X0) { E_X0 = ox };
                if (ox > E_X1) { E_X1 = ox };
                if (oy < E_Y0) { E_Y0 = oy };
                if (oy > E_Y1) { E_Y1 = oy };
                // Is this extreme reached AT THE EDGE of the frame?  If it is, the
                // ellipse reaches past what the grid can sample and the scan's
                // extent is the frame's, not the ellipse's -- so comparing it with
                // the conic's root would be comparing a clipped extent with an
                // unclipped one.  At a camera distance of 2.5 the sphere is bigger
                // than the frame in both directions and exactly this happens, and
                // the first version of this check read the resulting 19-cell
                // "disagreement" as a failure.  The bits are 1 left, 2 right,
                // 4 top, 8 bottom.
                let jj = i % GW;
                let ii = i / GW;
                if (ox == E_X0 && jj == 0) { E_CLIP = E_CLIP | 1 };
                if (ox == E_X1 && jj == GW - 1) { E_CLIP = E_CLIP | 2 };
                if (oy == E_Y1 && ii == 0) { E_CLIP = E_CLIP | 4 };
                if (oy == E_Y0 && ii == GH - 1) { E_CLIP = E_CLIP | 8 };
                if (hit != 0) { E_HIT = E_HIT + 1 } else { E_MISS = E_MISS + 1 }
            } else if (hit != 0) {
                // On the sphere alone the field is exact everywhere, so a hit
                // whose ray the quadratic says MISSES is either a grazing ray --
                // the marcher stops within EPS of a surface it passes within EPS
                // of, and both answers are right -- or an over-hit, which cannot
                // be legitimate.  T2 draws the line at 2*EPS of clearance for
                // exactly this case and it applies unchanged here: what is
                // reported is the worst clearance over the whole sweep, which is
                // the number that decides, not a count of samples.
                at(scene.st_at(i));
                if (abs2(sph_d(PX, PY, PZ)) < 4 * T_EPS) {
                    E_FP = E_FP + 1;
                    if (OMISS - scene.SPH_R > E_GAP) {
                        E_GAP = OMISS - scene.SPH_R
                    }
                }
            }
        };
        i = i + 1
    };
    // the drawn outline, from the hit samples only
    E_D0 = GW;
    E_D1 = 0 - 1;
    E_E0 = GH;
    E_E1 = 0 - 1;
    i = 0;
    while (i < n) {
        ray_of(i);
        if (RL >= 1) {
            if (scene.shit(i) != 0) {
                let col = i % GW;
                let row = i / GW;
                if (col < E_D0) { E_D0 = col };
                if (col > E_D1) { E_D1 = col };
                if (row < E_E0) { E_E0 = row };
                if (row > E_E1) { E_E1 = row }
            }
        };
        i = i + 1
    };
    conic_init();
    QOK
};

// ══════════════════════════════════════════════════════ T4: the budget ═══
//
// The step budget is documented to change how far the ground reaches, so the
// comparison is over the UPRIGHT part of the frame only.  A ray whose direction
// has a positive y component, cast from an eye above the plane, can never reach
// the plane at all -- so everything in that region is the three objects, and its
// hit set must not depend on the budget.  A step-arithmetic bug -- a lost shift,
// a wrong reciprocal, a `>>>` where `>>` belongs -- changes exactly that.
let HA: [byte; 102400] = [0; 102400];     // run A's hit flags
let TA: [long; 102400] = [0; 102400];     // ... and its ray parameters
let CM: [byte; 12800] = [0; 12800];       // per-cell mismatch
let CP: [byte; 12800] = [0; 12800];       // per-cell: a boundary cell
let P_CELLS: long = 0;
let P_MIS: long = 0;
let P_BAD: long = 0;
let P_W: long = 0;                       // worst depth disagreement, Q16

def budget() -> void {
    let cols = GW;
    let rows = GH / 2;
    let cells = cols * rows;
    let n = GW * GH;
    let keep = scene.steps();
    scene.set_steps(40);
    scene.render(0, 0);
    let i = 0;
    while (i < n) {
        HA[i] = scene.shit(i);
        TA[i] = scene.st_at(i);
        i = i + 1
    };
    scene.set_steps(160);
    scene.render(0, 0);
    let c = 0;
    while (c < cells) {
        CM[c] = 0;
        CP[c] = 0;
        c = c + 1
    };
    i = 0;
    while (i < n) {
        if (scene.shit(i) != HA[i]) { CM[i / GW / 2] = 1 };
        i = i + 1
    };
    P_CELLS = 0;
    P_MIS = 0;
    P_BAD = 0;
    P_W = 0;
    c = 0;
    while (c < cells) {
        let up = 2 * c;
        let lo = up + 1;
        // upright?  The upper sample of the cell decides: if its ray climbs, the
        // cell is above the horizon as far as the ground is concerned.
        ray_of(up);
        if (UY > 0 && EY > scene.PLANE_Y) {
            let a0 = HA[up];
            let a1 = HA[lo];
            let b0 = scene.shit(up);
            let b1 = scene.shit(lo);
            P_CELLS = P_CELLS + 1;
            if (CM[c] != 0) { P_MIS = P_MIS + 1 };
            if (a0 != a1 || b0 != b1) { CP[c] = 1 };
            if (a0 == b0 && a0 != 0) {
                let d = TA[up] - scene.st_at(up);
                if (d < 0) { d = 0 - d };
                if (d > P_W) { P_W = d }
            }
        };
        c = c + 1
    };
    // every mismatching cell must be a boundary cell, or touch one
    c = 0;
    while (c < cells) {
        if (CM[c] != 0) {
            let bad = 1;
            let col = c % cols;
            let row = c / cols;
            let dy = 0 - 1;
            while (dy <= 1 && bad != 0) {
                let rr = row + dy;
                let dx = 0 - 1;
                while (dx <= 1 && bad != 0) {
                    let cc = col + dx;
                    if (rr >= 0 && rr < rows && cc >= 0 && cc < cols) {
                        let k = rr * cols + cc;
                        if (CM[k] != 0 || CP[k] != 0) { bad = 0 }
                    };
                    dx = dx + 1
                };
                dy = dy + 1
            };
            if (bad != 0) { P_BAD = P_BAD + 1 }
        };
        c = c + 1
    };
    scene.set_steps(keep)
};

// ══════════════════════════════════════════════════════════════ run ══════

def acc_reset() -> void {
    F_N = 0; F_HIGH = 0; F_LOW = 0;
    S_A = 0; S_AH = 0; S_AM = 0; S_AMB = 0; S_AMF = 0; S_INS = 0;
    S_BEHIND = 0; S_W = 0; S_WC = 0; S_WR = 0; S_LAT = 0;
    S_CORE = 0; S_CW = 0; S_CWC = 0; S_CWR = 0; S_CL = 0; S_NEAR = 0;
    M_A = 0; M_W = 0; M_BAD = 0; M_GAP = 0;
    B_N = 0; B_SPH = 0; B_BOX = 0; B_REV = 0; B_W = 0; B_OUT = 0
};

def run(poses: long) -> long {
    let t0 = clock_us();
    scene.qseed_init();
    scene.solo(0);
    scene.grid_setup(CK_COLS, CK_ROWS, 1, 2);
    GW = scene.grid_w();
    GH = scene.grid_h();
    CPP = (GW << 32) / (2 * scene.HALFVIEW);
    acc_reset();

    sink.out_str("fractal --check: the marched scene against a closed-form oracle\n");
    sink.out_str("  grid  ");
    sink.out_num(CK_COLS);
    sink.out_str("x");
    sink.out_num(CK_ROWS);
    sink.out_str(" cells, half glyph, ");
    sink.out_num(GW * GH);
    sink.out_str(" rays a frame, no jitter, camera poses ");
    sink.out_num(poses);
    sink.out_str("\n  tolerance: EPS=");
    sink.out_num(T_EPS);
    sink.out_str(" Q16 (2^-11), core depth=");
    sink.out_num(T_CORE);
    sink.out_str(", one smooth-min bulge=");
    sink.out_num(T_BULGE);
    sink.out_str(" (k/4), lateral one cell\n");

    // ── T0 + T1 + T2 + T5, on the real four-primitive scene, over the poses
    let k = 0;
    while (k < poses) {
        pose(k);
        sweep();
        k = k + 1
    };

    sink.out_str("\nT0  the field honours smin's contract, min - k/4 <= map <= min\n");
    rp("  points checked", F_N);
    sink.out_str("\n  worst map-min        ");
    sink.out_str(rs(F_HIGH));
    sink.out_str("   (must be <= 0)\n  worst min-k/4-map   ");
    sink.out_str(rs(0 - F_LOW));
    sink.out_str("   (must be <= 0)\n");
    if (F_HIGH > T_FIELD) { fail("T0 map exceeds the plain minimum") };
    if (F_LOW > T_FIELD) { fail("T0 map is over k/4 below the plain minimum") };

    sink.out_str("\nT1  marched depth vs the closed-form ray/sphere root\n");
    rp("  rays that hit the sphere analytically", S_A);
    sink.out_str("\n    the marcher also hit  ");
    sink.out_pad(S_AH, 8);
    sink.out_str("   missed ");
    sink.out_pad(S_AM, 8);
    sink.out_str("   eye inside ");
    sink.out_pad(S_INS, 8);
    sink.out_str("\n    of the misses: budget exhausted ");
    sink.out_pad(S_AMB, 7);
    sink.out_str(", past the far plane ");
    sink.out_pad(S_AMF, 7);
    sink.out_str("\n  WORST depth error   ");
    sink.out_str(rs(S_W));
    sink.out_str("   = ");
    sink.out_str(rs(S_LAT));
    sink.out_str(" cells of lateral movement, at column ");
    sink.out_num(S_WC);
    sink.out_str(" row ");
    sink.out_num(S_WR);
    sink.out_str("\n  rays that stopped BEHIND the true root: ");
    sink.out_num(S_BEHIND);
    sink.out_str("\n  core subset: clean of every blend and hitting the sphere at better\n");
    sink.out_str("    than 60 degrees of incidence -- ");
    sink.out_num(S_CORE);
    sink.out_str(" rays\n    WORST depth error there ");
    sink.out_str(rs(S_CW));
    sink.out_str(" = ");
    sink.out_str(rs((S_CW << 16) / T_CORE));
    sink.out_str(" x the tolerance, at column ");
    sink.out_num(S_CWC);
    sink.out_str(" row ");
    sink.out_num(S_CWR);
    sink.out_str("\n    worst lateral there  ");
    sink.out_str(rs(S_CL));
    sink.out_str(" cells;  rays within a cell of the root ");
    sink.out_num(S_NEAR);
    sink.out_str("\n    at the worst: marched depth ");
    sink.out_str(rs(S_CT));
    sink.out_str(" against the analytic root ");
    sink.out_str(rs(S_CA));
    sink.out_str("\n      the marched point is ");
    sink.out_str(rs(S_CSD));
    sink.out_str(" from the sphere, and map() there says ");
    sink.out_str(rs(S_CMD));
    sink.out_str("\n      the other primitives are at plane ");
    sink.out_str(rs(S_CDP));
    sink.out_str(", box ");
    sink.out_str(rs(S_CDB));
    sink.out_str(", capsule ");
    sink.out_str(rs(S_CDC));
    sink.out_str("\n      sin(phi)*r there is ");
    sink.out_str(rs(S_CMISS));
    sink.out_str(" and the analytic point is ");
    sink.out_str(rs(S_CAN));
    sink.out_str(" from the sphere (the oracle's own residual)\n");
    if (S_CORE < 100) { fail("T1 too few well-conditioned rays to mean anything") };
    if (S_CW > T_CORE) { fail("T1 core depth error over 4*EPS") };
    if (S_LAT > T_LAT) { fail("T1 lateral error over one cell plus a blend bulge") };
    if (S_BEHIND != 0) { fail("T1 a ray stopped deeper than the analytic root") };

    sink.out_str("\nT2  a ray the quadratic says MISSES never reports a hit on the sphere\n");
    rp("  such rays that hit something", M_A);
    sink.out_str("\n  worst (r - distance from the hit to the centre): ");
    sink.out_str(rs(M_W));
    sink.out_str("   (negative = the hit is clear of the sphere)\n  worst (miss - r), how far outside the cone it stopped: ");
    sink.out_str(rs(M_GAP));
    sink.out_str("   (EPS is 0.000488; a blend can add 0.095)\n  over-hits neither excuse explains: ");
    sink.out_num(M_BAD);
    sink.out_str("\n");
    if (M_BAD != 0) { fail("T2 a ray that misses the sphere stopped on it") };

    sink.out_str("\nT5  depth ordering where the box and the sphere overlap\n");
    rp("  both hit, roots well apart", B_N);
    sink.out_str("\n  the sphere was nearer  ");
    sink.out_pad(B_SPH, 8);
    sink.out_str("  the box was nearer  ");
    sink.out_pad(B_BOX, 8);
    sink.out_str("\n  the marcher sided with the FARTHER surface: ");
    sink.out_num(B_REV);
    sink.out_str("\n  worst (marched depth - the nearer root): ");
    sink.out_str(rs(B_W));
    sink.out_str("\n  outside [-one bulge, +one cell]: ");
    sink.out_num(B_OUT);
    sink.out_str("\n");
    if (B_N < 50) { fail("T5 too few overlapping pixels to mean anything") };
    if (B_REV != 0) { fail("T5 the farther surface won the depth test") };
    if (B_OUT != 0) { fail("T5 the depth is outside the smooth-min bulge band") };

    // ── T3: the control scene, over a distance sweep
    //
    // THE TOLERANCE, AND WHY IT IS EXACTLY ONE CELL
    // The marcher's own stopping rule is `map(p) < EPS`, and map() is an exact
    // signed distance here (scene.solo leaves the sphere alone), so the marcher
    // stops the first time it is within EPS = 2^-11 of the surface -- and it may
    // stop EARLY on the near side of the silhouette, where the field shrinks
    // faster than the ray closes on it.  A sample whose cell centre sits within
    // one cell of the tangent point therefore may go either way: it can report a
    // hit with its centre up to one cell INSIDE the ellipse, and the outermost
    // cell that holds a hit is then up to one cell inside the analytic extent.
    // One cell is the whole of that budget, it is an UPPER bound in the direction
    // that matters (the marched outline may never stick OUT past the ellipse), and
    // it is the number actually measured below: the drawn edges land 0 to 1 cells
    // inside the analytic ones.  Anything larger is a defect, not a tolerance.
    //
    // So the rule is asymmetric on purpose, and the reason is above:
    //     drawn inside analytic   allowed, up to 1 cell  (EPS stopping rule)
    //     drawn outside analytic  NOT allowed, at all     (the marcher may only
    //                                                       stop short, never
    //                                                       overshoot)
    // and the two closed forms, which do not march at all, are compared to each
    // other to a HALF cell -- nothing about them is quantised, so any difference
    // between them is arithmetic, and half a cell is comfortably above the 1.5e-5
    // of fixed-point noise.
    scene.solo(1);
    let s = 0;
    let bad3 = 0;
    // the sweep-wide counters are cleared HERE and not per pose: E_FP, E_GAP,
    // E_WX and E_WY are a count and three maxima over all five distances, and
    // resetting them per pose reports the last one only -- which is how the first
    // version of this table came to claim "0 samples" while the rows above it
    // said 6, 2 and 1.
    E_FP = 0;
    E_CLEDGE = 0;
    E_WX = 0;
    E_WY = 0;
    E_GAP = 0;
    E_GROW = 0;
    E_SW0 = 0;
    E_SW1 = 0;
    E_PREV = 0;
    sink.out_str("\nT3  the drawn silhouette IS the tangent cone's ellipse.  Control scene:\n");
    sink.out_str("    the same marcher, camera, grid and cell pass, sphere alone -- no\n");
    sink.out_str("    smooth-minimum and nothing in front of it, so a hit IS the sphere.\n");
    sink.out_str("  Three independent derivations of the same ellipse have to agree:\n");
    sink.out_str("    scan = brute force over the closed-form quadratic, cf = the roots of\n");
    sink.out_str("    the conic's extent equation, drawn = the marched outline's extents.\n");
    sink.out_str("  bands: (1) scan vs the conic's roots, one SAMPLE PITCH -- a cell\n");
    sink.out_str("  across, half a cell down, since the scan's extreme is the last\n");
    sink.out_str("  sample that hits and the true edge can be at most one sample past\n");
    sink.out_str("  it.  (2) drawn vs analytic: the marched outline may sit up to 1 cell\n");
    sink.out_str("  INSIDE the analytic extent -- the marcher stops within EPS of the\n");
    sink.out_str("  surface, a fraction of a cell of lateral movement at the silhouette\n");
    sink.out_str("  -- and may NOT sit outside it at all, because a marcher may stop\n");
    sink.out_str("  short of a surface but never overshoot one.\n");
    sink.out_str("  a cf row or column outside 0..31 / 0..119 is the ellipse LEAVING the\n");
    sink.out_str("  frame, which neither the scan nor the marcher can see: not a defect.\n");
    sink.out_str("  dist   analytic  hit   miss  overhit |   scan x0   x1   y0   y1"
                 + " |      cf x0   x1   y0   y1 | drawn x0 x1 y0 y1"
                 + "  worst  gram\n");
    while (s < 5) {
        scene.set_camera(P_AZ[0], P_EL[1], P_SW[s]);
        scene.render(0, 0);
        load_basis();
        let ok = ellipse();
        sink.out_str("  ");
        sink.out_num(P_SW[s] / 65536);
        sink.out_pad(E_A, 9);
        sink.out_pad(E_HIT, 6);
        sink.out_pad(E_MISS, 6);
        sink.out_pad(E_FP, 8);
        sink.out_str(" |");
        sink.out_pad(cells_h(E_X0), 8);
        sink.out_pad(cells_h(E_X1), 6);
        sink.out_pad(cells_v(E_Y0), 6);
        sink.out_pad(cells_v(E_Y1), 6);
        sink.out_str(" |");
        if (ok != 0) {
            cpad(cells_h(QX0), 8);
            cpad(cells_h(QX1), 6);
            cpad(cells_v(QY0), 6);
            cpad(cells_v(QY1), 6)
        } else {
            sink.out_str("    degenerate")
        };
        // The four edge comparisons are made BEFORE the row is printed, so the
        // "worst" column on a row is that row's own worst and not the previous
        // one's.  E_Y0 is the SMALLEST oy, i.e. the BOTTOM of the silhouette, and
        // E_Y1 the top -- pairing them up the other way round puts the top edge
        // against the bottom one and reads 15 cells of overshoot on a frame where
        // the two silhouettes are identical.
        let e_l = edge(E_D0, cells_h(E_X0), 1);
        let e_r = edge(E_D1, cells_h(E_X1), 0 - 1);
        let e_t = edge(E_E0 / 2, cells_v(E_Y1), 0 - 1);
        let e_b = edge(E_E1 / 2, cells_v(E_Y0), 1);
        sink.out_str(" |");
        sink.out_pad(E_D0, 7);
        sink.out_pad(E_D1, 4);
        sink.out_pad(E_E0 / 2, 4);
        sink.out_pad(E_E1 / 2, 4);
        sink.out_str("  ");
        sink.out_pad(E_WO, 6);
        sink.out_str("  ");
        sink.out_str(rs(GRAMW));
        sink.out_str("\n");
        // THE PROPERTY THE BROKEN ORACLE VIOLATED, written down so that shape of
        // mistake cannot come back: a sphere of FIXED radius, seen from further
        // away, has a SMALLER silhouette, and by a computable amount -- its
        // projected diameter goes as r/sqrt(d^2 - r^2), 0.3735 of a unit at
        // d = 2.5 and 0.0878 at d = 8, a factor of 4.26.  The first version of
        // this check reported the same extents at EVERY distance from 2.5 to 8,
        // which no sphere can do; a scan whose extents never move is wrong by
        // inspection, before anything else is checked.  So the oracle's extent
        // must not grow as the camera pulls back, and the widest must be at least
        // twice the narrowest: measured 3.7 against the predicted 4.26, the
        // difference being integer extents and the frame clipping the nearest.
        let sw = cells_h(E_X1) - cells_h(E_X0);
        if (s == 0) { E_SW0 = sw; E_PREV = sw };
        if (s == 4) { E_SW1 = sw };
        if (s > 0) {
            if (sw > E_PREV) { E_GROW = E_GROW + 1 };
            E_PREV = sw
        };
        if (ok == 0) {
            bad3 = bad3 + 1
        } else {
            // scan vs the closed-form roots, to ONE SAMPLE PITCH: the scan's
            // extreme is the last SAMPLE that hits, so the true edge can be at
            // most one sample beyond it -- a whole cell across, half a cell down,
            // because grid_setup puts one sample per cell horizontally and two per
            // cell vertically.  Measured over the sweep: 0.98 cells across and
            // 0.41 down, i.e. the oracle is sharp to the sampling and not to
            // anything looser.  (The broken version was 30 cells out horizontally
            // and a factor of two vertically, so this band has teeth.)
            let dx0 = dcells(E_X0, QX0, 0);
            let dx1 = dcells(E_X1, QX1, 0);
            let dy0 = dcells(E_Y0, QY0, 1);
            let dy1 = dcells(E_Y1, QY1, 1);
            // An edge the ellipse is known to leave the frame on cannot be
            // compared: the scan's extreme there is the frame's own edge sample,
            // and the conic's root is out in the tangent cone beyond it.  Those
            // edges are counted and skipped, and the drawn outline is still
            // checked against the scan on them -- both are clipped identically.
            if ((E_CLIP & 1) == 0) {
                if (dx0 > E_WX) { E_WX = dx0 };
                if (dx0 > 65536) { bad3 = bad3 + 1 }
            } else { E_CLEDGE = E_CLEDGE + 1 };
            if ((E_CLIP & 2) == 0) {
                if (dx1 > E_WX) { E_WX = dx1 };
                if (dx1 > 65536) { bad3 = bad3 + 1 }
            } else { E_CLEDGE = E_CLEDGE + 1 };
            if ((E_CLIP & 8) == 0) {
                if (dy0 > E_WY) { E_WY = dy0 };
                if (dy0 > 32768) { bad3 = bad3 + 1 }
            } else { E_CLEDGE = E_CLEDGE + 1 };
            if ((E_CLIP & 4) == 0) {
                if (dy1 > E_WY) { E_WY = dy1 };
                if (dy1 > 32768) { bad3 = bad3 + 1 }
            } else { E_CLEDGE = E_CLEDGE + 1 };
            // The drawn outline against the scan, which is the one extent that is
            // neither quantised nor clipped: cf may sit outside the frame, and
            // neither the scan nor the marcher can see that part of it.
            if (e_l > 0 || e_r > 0 || e_t > 0 || e_b > 0) { bad3 = bad3 + 1 };
            if (E_WI > 1) { bad3 = bad3 + 1 }
        };
        if (E_MISS != 0) { bad3 = bad3 + 1 };
        if (E_GAP > 2 * T_EPS) { bad3 = bad3 + 1 };
        s = s + 1
    };
    scene.solo(0);
    sink.out_str("  scan vs the conic's roots, worst, in cells: ");
    sink.out_str(rs(E_WX));
    sink.out_str(" across (band 1.0, one sample pitch), ");
    sink.out_str(rs(E_WY));
    sink.out_str(" down (band 0.5, half a sample pitch), over the ");
    sink.out_num(20 - E_CLEDGE);
    sink.out_str(" of 20 edges where the ellipse stays inside the frame\n");
    sink.out_str("  edges where the ellipse LEAVES the frame and only the marched outline can be compared: ");
    sink.out_num(E_CLEDGE);
    sink.out_str("\n");
    sink.out_str("  drawn vs the analytic extent, worst, in cells: ");
    sink.out_str(rs(E_WO));
    sink.out_str(" of overshoot (must be <= 0) and ");
    sink.out_str(rs(E_WI));
    sink.out_str(" of shrinkage (band 1.0)\n");
    sink.out_str("  worst clearance of a ray the marcher hit and the quadratic called a\n");
    sink.out_str("  miss, over ");
    sink.out_num(E_FP);
    sink.out_str(" such samples: ");
    sink.out_str(rs(E_GAP));
    sink.out_str("   (2*EPS is ");
    sink.out_str(rs(2 * T_EPS));
    sink.out_str(")\n");
    sink.out_str("  oracle's drawn width at the near and the far camera: ");
    sink.out_num(E_SW0);
    sink.out_str(" and ");
    sink.out_num(E_SW1);
    sink.out_str(" cells, so far/near = ");
    sink.out_str(rs((E_SW1 * 65536) / E_SW0));
    sink.out_str(" against 0.235 for r/sqrt(d^2-r^2) -- 15% out, which is integer\n");
    sink.out_str("  extents plus the sphere standing off the view axis\n");
    sink.out_str("  times the oracle's extent GREW as the camera pulled back: ");
    sink.out_num(E_GROW);
    sink.out_str("  (must be 0)\n");
    if (E_GROW != 0) { bad3 = bad3 + 1 };
    if (E_SW1 * 2 > E_SW0) { bad3 = bad3 + 1 };
    if (bad3 != 0) { fail("T3 the drawn silhouette is not the analytic ellipse") };

    // ── T4
    scene.set_camera(P_AZ[1], P_EL[0], P_DI[0]);
    scene.render(0, 0);
    load_basis();
    budget();
    sink.out_str("\nT4  the step budget changes how far the ground reaches and nothing else\n");
    rp("  cells compared", P_CELLS);
    sink.out_str("  (upright rays from an eye above the plane: the ground is not among them)\n  cells whose hit/miss differs at 40 against 160 steps: ");
    sink.out_num(P_MIS);
    sink.out_str("\n  of those, outside the one-cell boundary band: ");
    sink.out_num(P_BAD);
    sink.out_str("\n  worst depth disagreement on matched hits: ");
    sink.out_str(rs(P_W));
    sink.out_str("\n");
    if (P_CELLS < 200) { fail("T4 too few upright cells to mean anything") };
    if (P_BAD != 0) { fail("T4 the hit set moved away from the boundary band") };
    if (P_MIS * 50 > P_CELLS) { fail("T4 more than one fiftieth of the cells moved") };

    let t1 = clock_us();
    if (NFAIL == 0) {
        sink.out_str("\nRESULT  PASS\n")
    } else {
        sink.out_str("\nRESULT  FAIL\n")
    };
    sink.out_str("  elapsed ");
    sink.out_num((t1 - t0) / 1000);
    sink.out_str(" ms\n");
    sink.out_flush();
    NFAIL
};

// dcells(a, b, axis) -> long -- |a - b| for two tangent offsets, in CELLS, Q16.
// The answer is deliberately NOT truncated to whole cells: the difference between
// two closed forms is a fraction of a cell, and reporting it as 0 or 1 is how a
// real 0.98-cell error passes as "within a cell".  One conversion for both axes,
// because a cell is as tall as it is wide; the `axis` argument stays because the
// two axes were the trap here, and a reader should not have to re-derive it.
def dcells(a: long, b: long, axis: long) -> long {
    let d = a - b;
    if (d < 0) { d = 0 - d };
    (d * CPP) >> 16
};

// edge(drawn, analytic, sgn) -> long -- the marched edge's departure from the
// analytic one, in cells, signed so that POSITIVE means the marched outline
// reached FURTHER OUT than the ellipse does.  sgn is +1 for the LEFT column and
// the BOTTOM row -- outward means a smaller column and a LARGER row -- and -1 for
// the right column and the top row.
//
// Both halves of the band are recorded, separately, because they are different
// claims: an OVERSHOOT must be impossible (the marcher may stop short of a
// surface but never past one), while a SHRINKAGE of up to a cell is the
// documented consequence of the EPS stopping rule.  A check that reports only
// "within one cell" cannot tell those apart, and would pass a marcher that was
// half a cell too fat as happily as one half a cell too thin.
def edge(drawn: long, analytic: long, sgn: long) -> long {
    let e = (drawn - analytic) * sgn;
    if (e > E_WO) { E_WO = e };
    if (0 - e > E_WI) { E_WI = 0 - e };
    e
};

export { run };
