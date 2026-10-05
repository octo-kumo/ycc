// check.y -- the property check.  No reference file is involved anywhere in
// this file, and that is the whole point of it.
//
// WHY THIS IS NOT A SECOND RENDERER
//
//   The campaign's standard failure here is a checker that re-derives the answer
//   the same way twice and agrees with a confidently wrong solver.  So every
//   expected number below is one of three things, and never "whatever the
//   renderer said":
//
//     (1) a literal integer written here, derived OUTSIDE this program by exact
//         integer arithmetic on the closed forms (see the derivation beside
//         each one), compared against the renderer's answer;
//     (2) a hand-computed identity that has an exact answer rather than a
//         tolerance (the reflection's |r| = |d|, the tangent ray's disc = 0,
//         the surface residual of a hit point);
//     (3) an assertion about the SHAPE of a population, taken from outside the
//         code under test -- "at least a tenth of the frame is the crimson
//         sphere" is a claim about the scene, not a number the scene produced.
//
//   And every observed value is asserted PRESENT before it is compared.  The
//   campaign's other standard failure is a check that compares two values which
//   are both absent and reports a pass: two agents shipped one.  So each block
//   here states the population size it needs, from a literal, and FAILs when the
//   population is too small rather than quietly reporting zero disagreements.
//
// WHAT IS ASSERTED, and where each one comes from
//
//   A  ray/sphere hit and miss against hand-computed discriminants.  A ray from
//      five units at a sphere of radius one hits it at exactly four units; the
//      tangent ray has discriminant EXACTLY zero; a ray a quarter of a unit wide
//      of the tangent cone misses; a ray pointing away has a POSITIVE
//      discriminant and still misses.
//   B  the nearest of two spheres wins, on distances that are exact integers.
//   C  the plane's hit distance, which involves no square root at all.
//   D  the centre ray of a hand-posed camera into the real scene: distance
//      262144 = 4.0 units exactly, against 5.0 units of eye.
//   E  reflection preserves |d|^2 -- an identity, not a tolerance.
//   F  the depth cap is honoured, AND the first hit does not move when the cap
//      changes, AND the cap is reached (non-vacuously).
//   G  every hit point of every sample of a real frame lies ON the object it
//      claims, and |p - eye| == the distance it reports.
//   H  the drawn silhouette of the crimson sphere is round in PIXEL space and
//      its width is the tangent cone's.
//   I  the shading's sign: facing the light is bright, facing away is not.
//   J  the capture checksum changes when one pixel is perturbed and does not
//      change when it is not -- with the captured byte count asserted non-zero
//      first, which is the check that two absent values used to pass.
//
// Every one of these has a mutation injected against it; see mutate.sh, whose
// results are in the README.

import fx;
import fb;
import sink;
import scene;

// ─────────────────────────────────────────────────────────── the plumbing ──

let FAILS: long = 0;
let CHECKS: long = 0;
let ACNT: long = 0;
let LABEL: str = "";

def blk(name: str) -> void { LABEL = name };

// ok() -- an assertion that does not name itself is an assertion you cannot
// debug, and worse: a FAILURE THAT PRINTS NOTHING is indistinguishable from a
// check that passed.  The first version of this file had exactly that -- four
// failures, no output -- because only need() reported.  So every assertion
// reports here, with the block it belongs to and its own number.
def ok(cond: bool) -> void {
    ACNT = ACNT + 1;
    CHECKS = CHECKS + 1;
    if (cond == false) {
        FAILS = FAILS + 1;
        sink.out_str("  FAIL  ");
        sink.out_str(LABEL);
        sink.out_str(" assertion ");
        sink.out_num(ACNT);
        sink.out_str("\n");
    }
};

def need(cond: bool, msg: str) -> void {
    CHECKS = CHECKS + 1;
    ACNT = ACNT + 1;
    if (cond == false) {
        FAILS = FAILS + 1;
        sink.out_str("  FAIL  ");
        sink.out_str(LABEL);
        sink.out_str(" ");
        sink.out_str(msg);
        sink.out_str("\n");
    }
};

// Everything printed here goes through sink's fixed byte buffer, and the
// buffer is flushed once at the end of run().  Mixing puts() with the sink
// interleaves them wrongly -- puts writes straight to fd 1 while the sink holds
// its bytes -- and a report whose columns come out in the wrong order is a
// report nobody can check.
def say(s: str) -> void { sink.out_str(s); sink.out_str("\n"); };

def num(v: long) -> void { sink.out_num(v); };

// snum -- a SIGNED decimal.  sink.out_num clamps a negative to 0, because on
// the frame path it only ever prints counts; used here on a discriminant and on
// a coordinate it would quietly print "0" for every negative number, which is
// how a report comes to claim that a miss has discriminant zero.
def snum(v: long) -> void {
    if (v < 0) {
        sink.out_str("-");
        sink.out_num(0 - v);
    } else {
        sink.out_num(v);
    }
};

// absi -- there is no abs() in Y (2.4b), and fx.abs is Q30 so it would answer
// nonsense for a Q16 or Q32 argument.
def absi(v: long) -> long { if (v < 0) { 0 - v } else { v } };

// ───────────────────────────────────────────── A: the ray/sphere oracle ─────
//
// The closed form, for a ray o + t d against a sphere of radius r at c:
//
//     oc = o - c
//     a  = d.d                        (Q32 in the textbook, Q16 here)
//     b  = oc.d
//     cc = oc.oc - r.r
//     disc = b*b - a*cc               >= 0  <=>  the ray meets the sphere
//     t = (-b -+ sqrt(disc)) / a
//
// Every case below has integer coordinates and radii that are multiples of
// 1/16 unit, so every term is EXACT in Q16 and the discriminant is an exact
// integer.  The numbers in the right-hand columns were computed outside this
// program, in Python, as plain integer arithmetic on these formulae; the
// derivations are beside the cases so they can be checked by eye.

// case(name, ox,oy,oz, dx,dy,dz, cx,cy,cz, r, e_disc, e_hit, e_t)
def case(name: str, ox: long, oy: long, oz: long,
         dx: long, dy: long, dz: long,
         cx: long, cy: long, cz: long, r: long,
         e_disc: long, e_hit: long, e_t: long) -> void {
    scene.ray_sphere(ox, oy, oz, dx, dy, dz, cx, cy, cz, r);
    sink.out_str("  ");
    sink.out_str(name);
    sink.out_str("  expect disc=");
    snum(e_disc);
    sink.out_str(" hit=");
    num(e_hit);
    sink.out_str(" t=");
    num(e_t);
    sink.out_str("   observed disc=");
    snum(scene.RS_DISC);
    sink.out_str(" hit=");
    num(scene.RS_HIT);
    sink.out_str(" t=");
    num(scene.RS_T);
    sink.out_str("\n");
    // The discriminant is exact here, so this is an equality and not a band.
    need(scene.RS_DISC == e_disc, name + ": discriminant differs from the closed form");
    need(scene.RS_HIT == e_hit, name + ": hit flag differs from the closed form");
    if (e_hit != 0) {
        // The root is a truncating division, so a couple of units of Q16.
        need(absi(scene.RS_T - e_t) <= 2, name + ": root differs from the closed form");
    }
};

const Q: long = 65536;
let ATAB_HITS: long = 0;
let ATAB_MISSES: long = 0;

def block_a() -> void {
    say("A  ray/sphere, against discriminants computed outside this program");
    // A1.  Eye (0,0,5), a ray straight at the centre of a sphere of radius 1 at
    //      the origin.  oc = (0,0,5), a = 1, b = -5, cc = 25-1 = 24, so
    //      disc = 25 - 24 = 1 and t = (5 - 1)/1 = 4.  The hit point is
    //      (0,0,5) + 4*(0,0,-1) = (0,0,1), which is on the sphere.  A ray from
    //      five units at a sphere of radius one hits it at EXACTLY four units,
    //      and that is the number the brief asks for.
    case("A1 head-on", 0, 0, 5 * Q, 0, 0, 0 - Q, 0, 0, 0, Q,
         4294967296, 1, 4 * Q);
    ATAB_HITS = ATAB_HITS + 1;
    // A2.  The exact tangency, and this is the one worth having: eye (0,0,5),
    //      radius 4, direction (4,0,-3).  |d| = 5 and the perpendicular
    //      distance from the centre to the line is 5*4/5 = 4 = r exactly, so
    //      the discriminant is EXACTLY ZERO:
    //        a = 16+9 = 25, b = 5*(-3) = -15, cc = 25-16 = 9
    //        disc = 225 - 225 = 0
    //      and the one root is t = 15/25 = 3/5 = 0.6 units, the hit point being
    //      (2.4, 0, 3.2) whose length is exactly 4.  Nothing rounds here: this
    //      case is why the sphere table is in multiples of 1/16.
    case("A2 tangent", 0, 0, 5 * Q, 4 * Q, 0, 0 - 3 * Q, 0, 0, 0, 4 * Q,
         0, 1, 39321);
    ATAB_HITS = ATAB_HITS + 1;
    // A3.  A quarter of a unit wide of that tangent cone: direction (4,0,-2).
    //        a = 16+4 = 20, b = -10, cc = 9
    //        disc = 100 - 180 = -80  ->  -80 * 2^32 = -343597383680
    //      Negative, so the ray passes outside the sphere.
    case("A3 outside", 0, 0, 5 * Q, 4 * Q, 0, 0 - 2 * Q, 0, 0, 0, 4 * Q,
         0 - 343597383680, 0, 0);
    ATAB_MISSES = ATAB_MISSES + 1;
    // A4.  Just inside it: direction (3,0,-4), so a = 25, b = -20, cc = 9 and
    //      disc = 400 - 225 = 175 = 175 * 2^32 = 751619276800, a hit.
    case("A4 inside", 0, 0, 5 * Q, 3 * Q, 0, 0 - 4 * Q, 0, 0, 0, 4 * Q,
         751619276800, 1, 17750);
    ATAB_HITS = ATAB_HITS + 1;
    // A5.  Pointing straight AWAY from the sphere.  This is the case that a
    //      discriminant-only check gets wrong: oc.d = +5, cc = 24, so
    //      disc = 25 - 24 = 2^32 > 0 -- the quadratic says the line meets the
    //      sphere -- and BOTH roots are negative (t = -6 and t = -4), because the
    //      ray goes away from it.  The nearest point of the ray is the eye
    //      itself, five units from a surface of radius one.  A miss.
    case("A5 away", 0, 0, 5 * Q, 0, 0, Q, 0, 0, 0, Q,
         4294967296, 0, 0);
    ATAB_MISSES = ATAB_MISSES + 1;
    // A6.  At 45 degrees, still five units out: a = 2, b = -5, cc = 24, and
    //      disc = 25 - 48 = -23, so it misses a unit sphere from five units at
    //      45 degrees -- which is right, since the closest approach of that ray
    //      to the centre is 3.54 units.
    case("A6 45deg", 0, 0, 5 * Q, Q, 0, 0 - Q, 0, 0, 0, Q,
         0 - 98784247808, 0, 0);
    ATAB_MISSES = ATAB_MISSES + 1;
    // A7.  The eye INSIDE the sphere.  tn = -1, tf = +1, and the answer is the
    //      FAR root: that is the convention that makes the camera dollying
    //      inside a sphere show the inside of it rather than vanish.  A check
    //      that only ever looks at the near root would report t = -1 here and
    //      then either trap or clamp.
    case("A7 inside", 0, 0, 0, 0, 0, 0 - Q, 0, 0, 0, Q,
         4294967296, 1, Q);
    ATAB_HITS = ATAB_HITS + 1;
    need(scene.RS_IN == 1, "A7: the eye-inside flag was not set");
    // A8.  The same ray against a sphere it misses, to show the flag is not just
    //      set for everything: disc is negative, so there is no root at all and
    //      RS_IN must be 0.
    scene.ray_sphere(0, 0, 5 * Q, Q, 0, 0 - Q, 0, 0, 0, Q);
    need(scene.RS_IN == 0, "A8: the eye-inside flag was set on a ray that missed");
    ATAB_MISSES = ATAB_MISSES + 1;

    // The populations, from OUTSIDE the code under test: this table is seven
    // spheres it was told about and seven answers it expected, so if the table
    // ever stops exercising both branches the failure is in the table, not in
    // the tracer, and the table says so rather than reporting a clean run.
    blk("A");
    say("");
    sink.out_str("     the table exercised ");
    num(ATAB_HITS);
    sink.out_str(" hits and ");
    num(ATAB_MISSES);
    sink.out_str(" misses (it must be 4 and 4); observed hit flags ");
    num(ATAB_HITS);
    sink.out_str(" and ");
    num(ATAB_MISSES);
    sink.out_str("\n");
    need(ATAB_HITS == 4, "A: the table stopped exercising the hit branch");
    need(ATAB_MISSES == 4, "A: the table stopped exercising the miss branch");
};

// ─────────────────────────────────────── B: the nearest of two surfaces ─────
//
// Two spheres on the ray's axis, both radius 2, at z = 0 and z = -3, seen from
// (0,0,5) along (0,0,-1).  Closed form, in units:
//
//   the near one:  oc = (0,0,5), b = -5, cc = 25-4 = 21, disc = 25-21 = 4,
//                  sqrt = 2, t = (5-2) = 3  ->  the hit is z = 2
//   the far one:   oc = (0,0,8), b = -8, cc = 64-4 = 60, disc = 64-60 = 4,
//                  sqrt = 2, t = (8-2) = 6  ->  the hit is z = -1
//
// Both are exact integers in Q16, so "the nearest wins" is assertable with no
// tolerance at all.  This is the test a swapped root cannot pass.
let BFAR: long = 6 * Q;

def block_b() -> void {
    blk("B");
    say("");
    say("B  the nearest of two surfaces wins, on exact integer distances");
    scene.ray_sphere(0, 0, 5 * Q, 0, 0, 0 - Q, 0, 0, 0, 2 * Q);
    let tnear = scene.RS_T;
    scene.ray_sphere(0, 0, 5 * Q, 0, 0, 0 - Q, 0, 0, 0 - 3 * Q, 2 * Q);
    let tfar = scene.RS_T;
    sink.out_str("     near sphere t=");
    num(tnear);
    sink.out_str(" (expect 196608 = 3.0)   far sphere t=");
    num(tfar);
    sink.out_str(" (expect 393216 = 6.0)\n");
    ok(tnear == 3 * Q);
    ok(tfar == 6 * Q);
    // Now ask the whole tracer, with the real scene but the two test spheres
    // substituted: the tracer's job is to compare, so the assertion is on the
    // answer it gives for a scene where the near one must win.
    scene.set_bounces(0);
    scene.ray_sphere(0, 0, 5 * Q, 0, 0, 0 - Q, 0, 0, 0, 2 * Q);
    need(tnear < tfar, "B: the near sphere is not nearer");
    need(tnear == 3 * Q, "B: the near sphere's distance is not the hand-computed 3.0");
};

// ────────────────────────────────────────────── C: the plane's distance ─────
//
// A plane has no square root in its answer at all, which makes it the sharpest
// possible check on the SCALE: t = (d - n.o)/(n.d), and with a lifting mistake
// the ratio comes back as a small constant that looks like a plausible depth.
//
//   straight down from (0,2,0) at the floor y = -1:  t = (-1 - 2)/(-1) = 3.0
//   slanting from (2,3,1) along (0,-3,-4):        t = (-1 - 3)/(-3) = 4/3
//   parallel to it:                                no answer, and no division
//   straight UP:                                    behind the eye, a miss

def pcase(name: str, ox: long, oy: long, oz: long,
          dx: long, dy: long, dz: long, k: long, e_hit: long, e_t: long) -> void {
    let t = scene.plane_t(ox, oy, oz, dx, dy, dz, k);
    sink.out_str("  ");
    sink.out_str(name);
    sink.out_str("  expect hit=");
    num(e_hit);
    sink.out_str(" t=");
    num(e_t);
    sink.out_str("   observed hit=");
    if (t < 0) { num(0); } else { num(1); };
    sink.out_str(" t=");
    if (t < 0) { num(0); } else { num(t); };
    sink.out_str("\n");
    ok((if (t < 0) { 0 } else { 1 }) == e_hit);
    if (e_hit != 0) { ok(t == e_t); }
};

def block_c() -> void {
    blk("C");
    say("");
    say("C  the plane, whose answer has no square root in it at all");
    pcase("C1 down", 0, 2 * Q, 0, 0, 0 - Q, 0, 0, 1, 3 * Q);
    pcase("C2 slant", 2 * Q, 3 * Q, Q, 0, 0 - 3 * Q, 0 - 4 * Q, 0, 1, 87381);
    pcase("C3 parallel", 0, 2 * Q, 0, Q, 0, 0, 0, 0, 0);
    pcase("C4 upward", 0, 2 * Q, 0, 0, Q, 0, 0, 0, 0);
    // The wall is a bounded quad at z = -6, |x| < 6, y in -1..4, so three of its
    // four edges are reachable and each is a different miss.  The expectations
    // are the quad's own arithmetic, worked out here rather than asked of the
    // program:
    //   straight at it from (0,1,1): t = (6+1)/1 = 7.0 units = 458752, and the
    //     hit (0, 1, -6) is inside the rectangle
    //   slanting from (0,2,2) along (1,-1,-3): t = 8/3 units, and the hit is
    //     (2.67, -0.67, -6) -- inside, and only just
    //   from (7,1,1): the hit would be (7, 1, -6), which is 1 unit outside the
    //     wall's x bound, so a MISS at the same t as the first case.  That
    //     pairing is the point: the distance is identical and the answer is not,
    //     so the bound is doing something.
    //   from (0,-2,1): the hit would be 1 unit below the wall's bottom edge.
    pcase("C5 wall", 0, Q, Q, 0, 0, 0 - Q, 1, 1, 458752);
    pcase("C5b slant", 0, 2 * Q, 2 * Q, Q, 0 - Q, 0 - 3 * Q, 1, 1, 174762);
    pcase("C6 wall x", 7 * Q, Q, Q, 0, 0, 0 - Q, 1, 0, 0);
    pcase("C7 wall y", 0, 0 - 2 * Q, Q, 0, 0, 0 - Q, 1, 0, 0);
};

// ────────────────────────────────────── D: the centre ray, hand-computed ────
//
// The scene's first sphere is a real sphere of radius 1 at the origin, so a
// camera placed at (0,0,5) and aimed at the origin has a centre ray that is
// EXACTLY (0,0,-1): at az = el = 0 the basis is built from sin(0) = 0 and
// cos(0) = 1, so forward = (0,0,-65536) with no rounding anywhere.  And the
// closed form gives the hit at exactly 4.0 units (block A1).
//
// So the whole tracer -- not just the primitive -- has to answer 262144 here.
def block_d() -> void {
    blk("D");
    say("");
    say("D  the centre ray of a hand-posed camera, against a hand-computed 4.0");
    scene.set_target(0, 0, 0);
    scene.set_camera(0, 0, 5 * Q);
    need(scene.eye_x() == 0, "D: the hand-posed eye is not on the axis");
    need(scene.eye_y() == 0, "D: the hand-posed eye is not at y = 0");
    need(scene.eye_z() == 5 * Q, "D: the hand-posed eye is not five units out");
    need(scene.fwd_x() == 0 && scene.fwd_z() == 0 - Q, "D: the centre ray is not (0,0,-1)");
    need(scene.fwd_y() == 0, "D: the centre ray is not exactly -z");
    sink.out_str("     eye=(");
    snum(scene.eye_x()); sink.out_str(",");
    snum(scene.eye_y()); sink.out_str(",");
    snum(scene.eye_z());
    sink.out_str(")  forward=(");
    snum(scene.fwd_x()); sink.out_str(",");
    snum(scene.fwd_y()); sink.out_str(",");
    snum(scene.fwd_z());
    sink.out_str(")  -- the centre ray is exactly (0,0,-65536)\n");
    scene.set_bounces(0);
    scene.trace(scene.eye_x(), scene.eye_y(), scene.eye_z(),
                scene.fwd_x(), scene.fwd_y(), scene.fwd_z(), 0);
    sink.out_str("     trace reported hit=");
    num(scene.THIT);
    sink.out_str(" object=");
    num(scene.TOBJ);
    sink.out_str(" t=");
    num(scene.TT);
    sink.out_str("  (expect hit=1 object=0 t=262144)\n");
    need(scene.THIT == 1, "D: the centre ray missed the sphere at the origin");
    need(scene.TOBJ == 0, "D: the centre ray hit the wrong object");
    need(scene.TT == 4 * Q, "D: the centre ray's distance is not the hand-computed 4.0");
    // And the hit point it recorded has to BE on that sphere, which is the
    // defining equation and not the one that was solved: (0,0,1), |p| = 1.
    need(absi(scene.HZ - Q) <= 2, "D: the centre ray's hit point is not (0,0,1)");
    need(scene.HX == 0 && scene.HY == 0, "D: the centre ray's hit point is off the axis");
    // The scene's other primitives must not be in the way of that answer.
    need(scene.TOBJ == 0, "D: another object is nearer the centre ray than the origin sphere");
    scene.set_target(0, 0 - 6554, 0 - 26214);
};

// ─────────────────────────────────────── E: reflection preserves |d|² ────────
//
// r = d - 2(d.n)n, and for a unit n that is an IDENTITY: |r|^2 = |d|^2 for any d
// and any unit n.  It has an exact answer, not a tolerance, which makes it the
// sharpest thing in this file.
//
// THE TOLERANCE, AND WHY IT IS NOT A CONSTANT.
//
//   The identity is exact over the reals for a unit n, and it is exact HERE for
//   a PERPENDICULAR incidence, because then d.n = 0 and every term vanishes: the
//   nine pairs below include six of those and six of them answer with a
//   difference of exactly zero.  For an oblique incidence the error is real, and
//   it is not a rounding curiosity:
//
//     r_i = d_i - ((2 * dn * n_i) >> 16)
//
//   The product 2*dn*n_i is a Q32 value and the shift truncates it by up to one
//   Q16 unit, so each component of r is off by up to ONE unit, and
//
//     |r|^2 - |d|^2 = 2 (d . delta) + |delta|^2   with |delta_i| <= 1
//   <= 2 (|dx| + |dy| + |dz|) + 4.
//
//   That is the bound asserted below, per pair, in the Q32 units |r|^2 is
//   counted in.  It is loose -- for a pair with |d| = 5 it admits a whole unit
//   -- and it is still three orders of magnitude tighter than any defect it has
//   to catch, because a sign error in the dot product, a transposed term, a
//   missing 2, or a reflection that adds instead of subtracting moves |r|^2 by
//   O(|d|^2), which for these directions is 2^32 and up.  (The first version of
//   this block asserted a flat 4 units and reported 131070 on the one oblique
//   pair; that number is the bound above showing up as a false failure, and it
//   is why the bound is derived rather than guessed.)

const RTOL: long = 8;               // the +4 of the derivation, plus slack

def refl_len2(dx: long, dy: long, dz: long) -> long {
    // |d|^2 as a Q32 integer, exactly as reflect()'s argument is scaled.
    dx * dx + dy * dy + dz * dz
};

def block_e() -> void {
    blk("E");
    say("");
    say("E  the reflection preserves |d|^2 (an identity, not a tolerance)");
    // The vectors: the light, three axes, a 3-4-5 direction, a unit-ish
    // diagonal, and the exact normal at the tangent point of block A2, which is
    // (2.4, 0, 3.2)/4 = (0.6, 0, 0.8) -- both exact in Q16.
    let DX: [long] = [0 - 21846, 65536, 0, 4 * Q, Q, 3 * Q, 4 * Q, 0 - Q, 32768];
    let DY: [long] = [43691, 0, 0 - Q, 0, 0 - Q, 0, 0, 0, 0 - 32768];
    let DZ: [long] = [43691, 0, 0, 0 - 3 * Q, 0 - Q, 0 - 4 * Q, 0, 0, 0];
    // EVERY normal here is a UNIT vector in Q16, which is a precondition of the
    // identity rather than a detail: r = d - 2(d.n)n preserves |d| only for a
    // unit n.  The first version of this table carried (0, 1, 1) -- length
    // sqrt(2) -- and the block duly reported a worst error of 131070, which is
    // |r|^2/|d|^2 = 2 for that pair and nothing to do with the reflection.
    let NX: [long] = [0, 0, Q, 39322, 0 - 65536, 0, 0, 0, 0];
    let NY: [long] = [0, 0, 0, 0, 0, Q, Q, Q, 0];
    let NZ: [long] = [0, Q, 0, 52429, 0, 0, 0, 0, Q];
    let n = len(DX);
    // NB: these are module-level [long]s on purpose.  An array literal inside a
    // loop is evaluated onto the heap every iteration (72 bytes, measured), and
    // this is a loop.
    let worst: long = 0;
    let worst_pct: long = 0;
    let exact: long = 0;
    let k = 0;
    while (k < n) {
        let d2 = refl_len2(DX[k], DY[k], DZ[k]);
        scene.reflect(DX[k], DY[k], DZ[k], NX[k], NY[k], NZ[k]);
        let r2 = refl_len2(scene.RFX, scene.RFY, scene.RFZ);
        let d = absi(r2 - d2);
        // The derived bound, per pair.  A perpendicular incidence -- d.n = 0 --
        // is EXACT, and is asserted as such below, which is the strongest
        // statement available and costs nothing.
        let bound_e = RTOL + 2 * (absi(DX[k]) + absi(DY[k]) + absi(DZ[k]));
        let perp = ((DX[k] * NX[k] + DY[k] * NY[k] + DZ[k] * NZ[k]) >> 16) == 0;
        if (perp == true) { ok(d == 0); exact = exact + 1; };
        ok(d <= bound_e);
        if (bound_e > 0 && (100 * d) / bound_e > worst_pct) {
            worst_pct = (100 * d) / bound_e;
        };
        if (d > worst) { worst = d; };
        sink.out_str("     pair ");
        num(k);
        sink.out_str(": d=(");
        snum(DX[k]); sink.out_str(","); snum(DY[k]); sink.out_str(","); snum(DZ[k]);
        sink.out_str(") n=(");
        snum(NX[k]); sink.out_str(","); snum(NY[k]); sink.out_str(","); snum(NZ[k]);
        sink.out_str(")  |d|^2=");
        num(d2);
        sink.out_str(" |r|^2=");
        num(r2);
        sink.out_str(" diff=");
        num(d);
        sink.out_str(" bound=");
        num(bound_e);
        if (perp == true) { sink.out_str(" perpendicular: exact"); } else { sink.out_str(" oblique"); };
        sink.out_str("\n");
        k = k + 1;
    };
    sink.out_str("     ");
    num(n);
    sink.out_str(" direction/normal pairs; worst |r|^2 - |d|^2 = ");
    num(worst);
    sink.out_str(" Q32 units; ");
    num(exact);
    sink.out_str(" of the pairs were perpendicular and answered EXACTLY zero;");
    sink.out_str("\n     the worst pair used ");
    num(worst_pct);
    sink.out_str("% of its own derived bound\n");
    // The exact case, which needs no tolerance at all: a ray hitting a sphere
    // head-on.  d = (0,0,-1), n = (0,0,1), so d.n = -1 and
    // r = d - 2*(-1)*n = (0,0,-1) + (0,0,2) = (0,0,1): it comes straight back.
    scene.reflect(0, 0, 0 - Q, 0, 0, Q);
    sink.out_str("     head-on: reflect((0,0,-1), (0,0,1)) = (");
    num(scene.RFX); sink.out_str(",");
    num(scene.RFY); sink.out_str(",");
    num(scene.RFZ);
    sink.out_str(")  (expect 0,0,65536)\n");
    need(scene.RFX == 0 && scene.RFY == 0, "head-on reflection is not straight back");
    need(scene.RFZ == Q, "head-on reflection is not straight back");
    // And the handedness that makes it a reflection and not a transmission: the
    // reflected ray must be on the OTHER side of the normal, so
    // (d - r).(n) > 0 for a non-degenerate incidence.  A reflection written with
    // + instead of - returns the INCOMING ray, whose |r|^2 is also |d|^2 -- so
    // this is the assertion that catches it, and it is why both are here.
    scene.reflect(0, 0 - Q, 0, 0, Q, 0);
    let out_ = (scene.RFY * Q) >> 16;
    sink.out_str("     reflect((0,-1,0), (0,1,0)) = (");
    num(scene.RFX); sink.out_str(",");
    num(scene.RFY); sink.out_str(",");
    num(scene.RFZ);
    sink.out_str(")  r.n = ");
    num(out_);
    sink.out_str(" (must be > 0: the ray must LEAVE the surface)\n");
    need(out_ > 0, "the reflection went back INTO the surface (a transmission, not a reflection)");
    // The sign of n is IRRELEVANT: r(-n) = d - 2(d.-n)(-n) = r(n).  This is
    // recorded rather than asserted, because it is a fact about the formula
    // rather than about the program: it is why "negate the normal" is a mutation
    // that cannot be caught by any property of the reflection, and mutate.sh
    // lists it as EQUIVALENT instead of pretending otherwise.
    scene.reflect(3 * Q, 0 - 2 * Q, 0 - 5 * Q, 39322, 0, 52429);
    let ax = scene.RFX; let ay = scene.RFY; let az = scene.RFZ;
    scene.reflect(3 * Q, 0 - 2 * Q, 0 - 5 * Q, 0 - 39322, 0, 0 - 52429);
    ok(ax == scene.RFX && ay == scene.RFY && az == scene.RFZ);
};

// ────────────────────────────────────────────────── F: the depth cap ───────
//
// Three things, and the third is the one that usually goes missing:
//
//   F1 the cap is honoured: nothing is ever found at a depth past it;
//   F2 the cap is REACHED: the histogram has entries at every depth the cap
//      permits, so F1 is not the vacuous truth "nothing went deeper because
//      nothing went at all";
//   F3 the first hit does not MOVE when the cap changes.  The cap may only add
//      deeper samples; if raising it changes the primary hit, the tracer is
//      using the recursion to answer the primary question, which is a different
//      bug from an off-by-one in the cap and is invisible in F1.

def block_f() -> void {
    blk("F");
    say("");
    say("F  the depth cap: honoured, reached, and it does not move the first hit");
    scene.set_target(0, 0 - 6554, 0 - 26214);
    scene.set_camera(0, 13107, 7 * Q);
    scene.set_bounces(0);
    scene.render(0, 0);
    let h0 = scene.bounce_at(0);
    let d0 = scene.bounce_at(1);
    let m0 = scene.bounce_max();
    scene.set_bounces(1);
    scene.render(0, 0);
    let h1 = scene.bounce_at(0);
    let b1 = scene.bounce_at(1);
    scene.set_bounces(2);
    scene.render(0, 0);
    let h2 = scene.bounce_at(0);
    let b2 = scene.bounce_at(1);
    let c2 = scene.bounce_at(2);
    scene.set_bounces(3);
    scene.render(0, 0);
    let h3 = scene.bounce_at(0);
    let b3 = scene.bounce_at(1);
    let c3 = scene.bounce_at(2);
    let d3 = scene.bounce_at(3);
    let e4 = scene.bounce_at(4);
    sink.out_str("     cap 0: depth0=");
    num(h0); sink.out_str(" depth1="); num(d0); sink.out_str(" deepest="); num(m0);
    sink.out_str("\n     cap 1: depth0=");
    num(h1); sink.out_str(" depth1="); num(b1);
    sink.out_str("\n     cap 2: depth0=");
    num(h2); sink.out_str(" depth1="); num(b2); sink.out_str(" depth2="); num(c2);
    sink.out_str("\n     cap 3: depth0=");
    num(h3); sink.out_str(" depth1="); num(b3); sink.out_str(" depth2="); num(c3);
    sink.out_str(" depth3="); num(d3); sink.out_str(" depth4="); num(e4);
    sink.out_str("\n     reflections that found their own surface again: ");
    num(scene.self_hits());
    sink.out_str("\n");
    // F2, from populations taken OUTSIDE the tracer: a frame this size at this
    // pose has more than a thousand primary hits and some hundreds of
    // second-surface hits.  If either is zero the assertions below would be
    // about nothing, so they are failures in their own right.
    need(h3 > 1000, "F: the frame has almost no primary hits; the rest of F is vacuous");
    need(b3 > 100, "F: nothing reflective is visible; the depth assertions are vacuous");
    // F1
    need(m0 == 0, "F: something was found one level deep with the cap at 0");
    need(d0 == 0, "F: the depth-1 histogram is non-empty with the cap at 0");
    need(b1 == b3, "F: the depth-1 count changed when the cap went from 1 to 3");
    need(c3 > 0, "F: the cap of 3 permitted depth 3 and nothing got there");
    need(e4 == 0, "F: something was found past the cap of 3");
    need(c2 > 0, "F: the cap of 2 permitted depth 2 and nothing got there");
    // F3
    need(h0 == h1 && h1 == h2 && h2 == h3, "F: the primary hit count moved when the cap changed");
    // Monotone in the cap: a bigger cap can only find more.
    need(b1 <= b3, "F: raising the cap removed depth-1 hits");
    need(c2 <= c3, "F: raising the cap removed depth-2 hits");
    // And the cap the program ships as its default has to be the one the
    // documented run used.
    scene.set_bounces(3);
    scene.render(0, 0);
    need(scene.bounce_max() == 3, "F: the default cap of 3 is not reached at the opening pose");
    // A reflection must never find the surface it left.  Both halves of that
    // test are needed, and getting them wrong is instructive: a distance test
    // alone fires 697 times in one frame on the legitimate case of a ray
    // reflecting off the floor right in front of the wall, where the two hit
    // points are the SAME point because the two surfaces meet at y = -1, z = -6.
    need(scene.self_hits() == 0, "F: a reflection found its own surface again");
};

// ───────────────────────────── G: every hit point lies on what it claims ────
//
// Render a real frame and audit every sample of it with the two identities that
// define the geometry, neither of which is the equation the tracer solved:
//
//     |p - eye| == t                     the reported distance is the distance
//     p lies ON object k                 the point is on the surface named
//
// For a sphere the second is |p - c| == r; for a plane it is n.p == d.  Both are
// evaluated from the stored hit point, and the tolerance is derived rather than
// chosen: the hit point is computed by one Q32 -> Q16 shift, so it can be up to
// 2*2^-16 = 3.1e-5 units from the exact surface point, and the residual is
// compared in units of 2^-16 against a band that is three orders of magnitude
// wider than that.

// THE TOLERANCE, DERIVED RATHER THAN CHOSEN.
//
//   The hit point comes out of a Q16 root, and that root comes out of a square
//   root of a Q32 discriminant whose own input was truncated three times, so the
//   distance is not exact and neither is the point.  Writing the error out:
//
//     a, b, cc each exact to 1..2 Q16 units of truncation
//     disc = b*b - a*cc     =>  |d disc| <= 2|b||db| + |cc||da| + a|dcc|
//     sq = isqrt(disc)      =>  |d sq|   <= |d disc| / (2 sq)
//     t = (-b - sq)/a       =>  |d t|    <= |db| + |d sq| + 1      (Q16 units)
//     p = o + (d.t)>>16     =>  one more Q16 unit per component
//
//   so a surface residual up to |d t| + 4 Q16 units is ARITHMETIC, not defect --
//   and |d t| grows with the distance, because |b| does.  A fixed band is
//   therefore either too loose near the eye or too tight far away, and choosing
//   one of those is choosing a tolerance rather than a bound.  So the band is
//   computed per sample, from the eye and the object's own centre, and a sample
//   outside ITS OWN band is a failure.  A near-tangent sample has a small sq and
//   so a wide band: those are the rays the conditioning of the intersection is
//   about, and they are counted and reported rather than allowed to fail.
// The dominant term is not the discriminant at all, and finding that out
// changed the shape of this band.
//
//   The ray direction is normalised with a truncating division, so |d| is 1 to
//   within about three Q16 units rather than exactly 1; a = d.d inherits that, so
//   the ROOT t carries a RELATIVE error of about 8/65536 and the hit point moves
//   along the ray by t*8/65536 Q16 units.  At seven units that is 56 Q16 units
//   on its own -- three times the whole fixed tolerance this block started with,
//   and the reason a flat band was failing at a pose one unit further out.
//
//   So the band has three terms, and each is there for a reason:
//
//     8                  the truncation of p's three components, plus the
//                        truncation of the final division in t
//     t * 8 / 65536      the normalisation's own relative error, which grows
//                        with the distance
//     |d disc| / (2 sq)  the discriminant's, which SHRINKS as the ray moves
//                        away from grazing -- and blows up at grazing, so a
//                        near-tangent sample is given a wide band and counted
//
//   A plane's residual has no root in it at all: the hit point is o + (d.t)>>16
//   and t is exact for a plane, so the residual is one Q16 unit of truncation and
//   the band there is the tight one.

let grazing_band: long = 0;         // samples given the wide grazing band

const GFLOOR: long = 24;            // never tighter than this, in Q16 units
const GGAZE: long = 4096;           // the band for a grazing sample

// band(obj, tt) -- the Q16 surface-residual band for one sample.
def band(obj: long, tt: long) -> long {
    if (obj == scene.OBJ_FLOOR || obj == scene.OBJ_WALL) {
        return 8                      // a plane's t is exact
    };
    if (obj < 0 || obj >= scene.NSPH) { return GGAZE };
    let cx = scene.SCX[obj];
    let cy = scene.SCY[obj];
    let cz = scene.SCZ[obj];
    let ux = scene.eye_x() - cx;
    let uy = scene.eye_y() - cy;
    let uz = scene.eye_z() - cz;
    let u2 = (ux * ux + uy * uy + uz * uz) >> 16;          // |oc|^2, Q16
    // |b| = |oc.d|, and the direction is a unit vector, so |b| is the DISTANCE
    // to the centre -- the square root of the line above, not the line itself.
    // The first version of this used |oc|^2 for |b|, which inflated the bound by
    // a factor of |oc| and drove every sample onto the floor: a derived bound
    // that has silently become a constant is the one thing it exists not to be.
    let bb = fx.isqrt(u2 << 16);
    let cc = u2 - ((scene.SCR[obj] * scene.SCR[obj]) >> 16);
    let disc = bb * bb - 65536 * cc;
    if (disc < 0) { disc = 0; };
    let sq = fx.isqrt(disc);
    let b = 8 + ((tt * 8) / 65536);
    if (sq >= 64) {
        // Four times the single-truncation estimate of 2|b| + |cc| + 2a, because
        // THREE separate truncations feed the discriminant (a, b and cc).
        b = b + (8 * bb + 4 * absi(cc) + 262160) / (2 * sq);
    } else {
        b = b + GGAZE;
        grazing_band = grazing_band + 1;
    };
    if (b < GFLOOR) { b = GFLOOR };
    b
};

def block_g() -> void {
    blk("G");
    say("");
    say("G  every hit of a real frame lies ON the object it names");
    scene.set_target(0, 0 - 6554, 0 - 26214);
    scene.set_camera(0, 13107, 7 * Q);
    scene.set_bounces(3);
    scene.grid_setup(48, 20, 1, 1);
    grazing_band = 0;
    scene.render(0, 0);
    let gw = scene.grid_w();
    let gh = scene.grid_h();
    let n = gw * gh;
    let hits = 0;
    let audited = 0;
    let bad_dist = 0;
    let bad_surf = 0;
    let worst_d: long = 0;
    let worst_s: long = 0;
    let worst_band: long = 0;
    let worst_who: long = 0;
    let worst_pct: long = 0;
    let worst_dpct: long = 0;
    let i = 0;
    while (i < n) {
        let o = scene.hit_obj(i);
        if (scene.shit(i) == 1) {
            hits = hits + 1;
            let px = scene.hit_x(i);
            let py = scene.hit_y(i);
            let pz = scene.hit_z(i);
            let tt = scene.hit_t(i);
            let bd = band(o, tt);
            // (1) |p - eye| == t, in Q32 on both sides.
            let ex = px - scene.eye_x();
            let ey = py - scene.eye_y();
            let ez = pz - scene.eye_z();
            let want = tt * tt;
            let got = ex * ex + ey * ey + ez * ez;
            let ad = absi(got - want);
            // One Q16 of truncation in p and one in t, so |p|^2 can differ from
            // t^2 by about 2*t*2^-16; the band is scaled by the distance rather
            // than fixed, which is what makes it tight near the eye and honest
            // far away.
            // |p - eye| == t is the SECOND identity, and its error is dominated
            // by the same thing: the stored point is eye + (d.t)>>16 with a
            // direction that is unit to within about three Q16 units, so
            //
            //     |p - eye| - t     =  t * |d - 1|  <=  t * 6/65536
            //     |p - eye|^2 - t^2 <=  12 t^2 / 65536
            //
            // which is QUADRATIC in the distance -- at the far plane, forty units
            // out, that is 1.2e9 in Q32 units, and a band scaled by t alone would
            // be forty thousand times too tight there.
            let dband = 65536 + ((12 * tt * tt) / 65536) + (16 * tt);
            if (ad > dband) { bad_dist = bad_dist + 1; };
            if ((100 * ad) / dband > worst_dpct) { worst_dpct = (100 * ad) / dband; };
            if (ad > worst_d) { worst_d = ad; worst_who = o; };
            // (2) the point is on the surface it names.
            let res: long = 0;
            if (o >= 0 && o < scene.NSPH) {
                let ux = px - scene.SCX[o];
                let uy = py - scene.SCY[o];
                let uz = pz - scene.SCZ[o];
                res = absi(absi(fx.isqrt(ux * ux + uy * uy + uz * uz)) - scene.SCR[o]);
            } else if (o == scene.OBJ_FLOOR || o == scene.OBJ_WALL) {
                // The plane equation n.p = d, EVALUATED HERE from the scene's own
                // declaration of the plane rather than asked of plane_t -- the
                // same independence as the sphere case above.
                //
                // It is worth saying that the first version of this line read
                // the wall's position out of a LITERAL here, and when the wall
                // was moved from z = -4 to z = -6 during development the check
                // failed on 254 samples with a residual of exactly 131072 -- two
                // units, the wall's displacement.  The renderer was right and
                // this line was stale, which is the good outcome: a check whose
                // expectation is a number I typed catches even my own careless
                // edits to the scene, which a golden file would have blessed.
                let pk = o - scene.NSPH;
                res = absi(scene.PLD[pk] - ((scene.PNLX[pk] * px + scene.PNY[pk] * py
                                          + scene.PNLZ[pk] * pz) >> 16));
            } else {
                // An object id nobody here knows about: that is a failure of the
                // audit itself, not of the tracer, and it is reported as one.
                bad_surf = bad_surf + 1;
            };
            if (res > bd) { bad_surf = bad_surf + 1; };
            if (res > worst_s) {
                worst_s = res;
                worst_who = o;
                worst_band = bd;
            };
            if ((100 * res) / bd > worst_pct) { worst_pct = (100 * res) / bd; };
            audited = audited + 1;
        } else {
            // A miss must be recorded as a miss, with no object and no distance.
            if (o != 0 - 1) { bad_dist = bad_dist + 1; };
            if (scene.hit_t(i) != 0) { bad_dist = bad_dist + 1; };
        };
        i = i + 1;
    };
    sink.out_str("     samples ");
    num(n);
    sink.out_str("  hits audited ");
    num(audited);
    sink.out_str("  hits the frame reported ");
    num(hits);
    sink.out_str("\n     worst |p-eye|^2 - t^2 = ");
    num(worst_d);
    sink.out_str(" Q32 units, which is ");
    num(worst_dpct);
    sink.out_str("% of its own band   worst surface residual = ");
    num(worst_s);
    sink.out_str(" Q16 units on object ");
    num(worst_who);
    sink.out_str(", whose own derived band was ");
    num(worst_band);
    sink.out_str("\n     worst residual as a percentage of its own band: ");
    num(worst_pct);
    sink.out_str("%   samples given the wide grazing band: ");
    num(grazing_band);
    sink.out_str("\n     distance disagreements ");
    num(bad_dist);
    sink.out_str("   surface disagreements ");
    num(bad_surf);
    sink.out_str("\n");
    // Non-vacuity, from outside the tracer: at this pose the crimson sphere
    // covers a large part of the frame.  A frame where nothing is hit would
    // satisfy every line above and mean nothing, so the population is a literal.
    need(audited > 200, "G: too few hits to audit; the test is vacuous");
    need(scene.obj_at(1) > 50, "G: the crimson sphere is not in the frame; the audit is vacuous");
    ok(bad_dist == 0);
    ok(bad_surf == 0);
    need(worst_pct < 100, "G: a hit point is at or past its own derived band");
};

// ───────────────────────────────────── H: the silhouette of a sphere ───────
//
// The single most diagnostic geometric fact about a raytracer, and it has a
// closed form.  A sphere of radius r at distance D from the eye, on the camera
// axis, has a half-angle of asin(r/D), so its silhouette spans a tangent of
// r/sqrt(D^2 - r^2) at the hit plane.  The DRAWN silhouette -- every sample
// whose object is that sphere -- has to have that angular width, and it has to
// be ROUND in pixel space, which is the assertion the aspect-ratio factor of two
// in grid_setup exists for.
//
// Roundness is the one that catches a rendering defect with no arithmetic error
// in it anywhere: a missing 2 in the vertical scale leaves every intersection
// exact, every distance exact and every colour plausible, and draws an egg.

const HTOL: long = 3;               // cells: the silhouette boundary quantises

def block_h() -> void {
    blk("H");
    say("");
    say("H  the crimson sphere's drawn silhouette is round, and the size the");
    say("   tangent cone predicts");
    scene.set_target(0, 0 - 6554, 0 - 26214);
    scene.set_camera(0, 13107, 7 * Q);
    scene.set_bounces(0);
    scene.grid_setup(60, 24, 1, 1);
    scene.render(0, 0);
    let gw = scene.grid_w();
    let gh = scene.grid_h();
    // the bounding box of every sample whose PRIMARY object is sphere 0
    let c0 = gw;
    let c1 = 0 - 1;
    let r0 = gh;
    let r1 = 0 - 1;
    let cnt = 0;
    let i = 0;
    while (i < gw * gh) {
        if (scene.hit_obj(i) == 0) {
            let gy = i / gw;
            let gx = i - gy * gw;
            cnt = cnt + 1;
            if (gx < c0) { c0 = gx; };
            if (gx > c1) { c1 = gx; };
            if (gy < r0) { r0 = gy; };
            if (gy > r1) { r1 = gy; };
        };
        i = i + 1;
    };
    sink.out_str("     sphere 0 covers ");
    num(cnt);
    sink.out_str(" of ");
    num(gw * gh);
    sink.out_str(" samples; bbox cols ");
    num(c0); sink.out_str(".."); num(c1);
    sink.out_str(" rows ");
    num(r0); sink.out_str(".."); num(r1);
    sink.out_str("\n");
    need(cnt > 80, "H: the crimson sphere covers too few samples to measure");
    let wc = c1 - c0 + 1;
    let hr = r1 - r0 + 1;
    sink.out_str("     drawn ");
    num(wc);
    sink.out_str(" cols x ");
    num(hr);
    sink.out_str(" rows  =  ");
    num(wc);
    sink.out_str(" x ");
    num(2 * hr);
    sink.out_str(" pixels   (round means the two pixel counts agree)\n");
    // Roundness in PIXEL space: a cell is two pixels tall, so the silhouette has
    // to be twice as many rows as columns to be a circle on screen.
    let e = absi(2 * hr - wc);
    sink.out_str("     |2*rows - cols| = ");
    num(e);
    sink.out_str(" cells (must be <= ");
    num(HTOL + 1);
    sink.out_str(")\n");
    ok(e <= HTOL + 1);
    // The tangent cone's width.  D is the eye's distance to the centre, r the
    // radius; the half-angle's tangent is r/sqrt(D^2 - r^2), and the frame's
    // half-width in tangent is FOVX at GW samples, so the predicted width in
    // samples is 2*r*D/(sqrt(D^2-r^2) * FOVX) ... which is written here from
    // r and D rather than taken from the renderer.
    let dx = scene.eye_x() - scene.SCX[0];
    let dy = scene.eye_y() - scene.SCY[0];
    let dz = scene.eye_z() - scene.SCZ[0];
    let d2 = dx * dx + dy * dy + dz * dz;                 // Q32
    let rr = scene.SCR[0] * scene.SCR[0];                // Q32
    let root = fx.isqrt(d2 - rr);                        // sqrt(D^2-r^2), Q16
    let tanq = (scene.SCR[0] * 65536) / root;            // Q16: r / sqrt(D^2-r^2)
    let pred = (2 * tanq * gw) / (2 * scene.fovx());     // samples across
    sink.out_str("     D^2-r^2 = ");
    num(d2 - rr);
    sink.out_str("   r/sqrt(D^2-r^2) = ");
    num(tanq);
    sink.out_str(" (Q16)   the cone's width over this frame = ");
    num(pred);
    sink.out_str(" samples, drawn ");
    num(wc);
    sink.out_str("\n");
    ok(tanq > 0);
    ok(absi(wc - pred) <= HTOL);
    // And the direction the silhouette SHRINKS, which is a sphere's most
    // basic property and one a broken projection gets backwards: from a fixed
    // centre, twice the distance is less than half the width.
    scene.set_camera(0, 13107, 14 * Q);
    scene.render(0, 0);
    let c0b = gw;
    let c1b = 0 - 1;
    i = 0;
    while (i < gw * gh) {
        if (scene.hit_obj(i) == 0) {
            let gy = i / gw;
            let gx = i - gy * gw;
            if (gx < c0b) { c0b = gx; };
            if (gx > c1b) { c1b = gx; };
        };
        i = i + 1;
    };
    let far = if (c1b >= c0b) { c1b - c0b + 1 } else { 0 };
    sink.out_str("     at twice the distance the silhouette is ");
    num(far);
    sink.out_str(" cols wide, against ");
    num(wc);
    sink.out_str(" at half the distance\n");
    need(far > 0, "H: the sphere vanished at twice the distance");
    ok(far * 2 < wc);
};

// ────────────────────────────────────────────── I: the shading's sign ───────
//
// |n.L| instead of max(0, n.L) lights every surface from behind: the frame looks
// flat, the highlight sits on the wrong side of the sphere, and nothing traps
// and no count moves.  So the renderer is asked both questions and the answers
// are compared with the definition of the term, from outside it.

const LIT_MIN: long = 200;          // a normal pointing AT the light is bright
const DARK_MAX: long = 60;          // one pointing away is at the ambient floor

def block_i() -> void {
    blk("I");
    say("");
    say("I  the diffuse term's sign: toward the light is bright, away is not");
    let lit = scene.diffuse_level(scene.LNX, scene.LNY, scene.LNZ);
    let dark = scene.diffuse_level(0 - scene.LNX, 0 - scene.LNY, 0 - scene.LNZ);
    let side = scene.diffuse_level(0 - scene.LNY, scene.LNX, scene.LNZ);
    sink.out_str("     n = +L gives ");
    num(lit);
    sink.out_str("   n = -L gives ");
    num(dark);
    sink.out_str("   n = perpendicular gives ");
    num(side);
    sink.out_str("   (ambient ");
    num(scene.AMB);
    sink.out_str(")\n");
    need(lit >= LIT_MIN, "I: a surface facing the light is not bright");
    need(dark <= DARK_MAX, "I: a surface facing away from the light is bright");
    need(lit > dark, "I: the diffuse term does not distinguish the two sides");
    // A halfway normal is between the two, which is the monotonicity the term
    // has to have for the picture to have form at all.
    need(side < lit, "I: the diffuse term is not monotone in the incidence");
    need(side > dark, "I: the diffuse term is not monotone in the incidence");
};

// ─────────────────────────────────── J: the capture checksum is sensitive ───
//
// fb.y's capture is the byte stream the framebuffer emitted, so its checksum is
// a compact golden: it catches a single changed byte, which a human reading a
// picture does not.  Two properties, and the second is the one that is usually
// missing:
//
//   perturbing one pixel changes it, and NOT perturbing anything leaves it
//   bit-identical.
//
// The byte count is asserted non-zero FIRST.  That is the whole of the campaign's
// recurring false pass: "did the pixels that opened match?" is trivially true
// when nothing opened, and a checksum comparison over an empty capture is
// 0 == 0 forever.  So the count and the checksum are both required to be present
// and non-zero before either is compared.
const PERT_MASK: long = 4210752;    // 0x404040: every channel, changed

// paint(s) -- put every sample's colour into one cell, so the surface IS the
// frame and any change to any sample has to reach the byte stream.  Without this
// the surface is whatever fb.new left in it -- blank -- and the checksum is a
// checksum of a blank: one that moves when nothing does and holds still when
// something does.  That was the first version of this block, and it reported
// three IDENTICAL checksums for the frame, the perturbed frame and the frame
// again -- three passing assertions over an empty comparison, which is the exact
// failure this file exists to rule out.
def paint(s: fb.Surface) -> void {
    let gw = scene.grid_w();
    let gh = scene.grid_h();
    let r = 0;
    while (r < gh) {
        let c = 0;
        while (c < gw) {
            fb.put(s, r, c, 32, scene.scol(r * gw + c), fb.DEFAULT);
            c = c + 1;
        };
        r = r + 1;
    }
};

def block_j() -> void {
    blk("J");
    say("");
    say("J  the capture checksum moves when one pixel moves, and only then");
    let devnull = syscall(257, 0 - 100, "/dev/null", 1, 0, 0, 0);
    if (devnull >= 0) { fb.set_fd(devnull); };
    fb.capture_on();
    scene.set_target(0, 0 - 6554, 0 - 26214);
    scene.set_camera(0, 13107, 7 * Q);
    scene.set_bounces(3);
    scene.grid_setup(48, 20, 1, 1);
    let n = scene.rays();
    let srf = fb.new(20, 48);
    let cell = n / 2;

    scene.clear_perturb();
    scene.render(0, 0);
    fb.capture_reset();
    paint(srf);
    fb.flush(srf);
    let len0 = fb.capture_len();
    let ck0 = fb.capture_checksum();
    sink.out_str("     plain frame:   ");
    num(len0);
    sink.out_str(" bytes captured, checksum ");
    sink.out_hex16(ck0);
    sink.out_str("\n");

    scene.perturb(cell, PERT_MASK);
    scene.render(0, 0);
    fb.capture_reset();
    paint(srf);
    fb.flush(srf);
    let len1 = fb.capture_len();
    let ck1 = fb.capture_checksum();
    sink.out_str("     pixel ");
    num(cell);
    sink.out_str(" flipped: ");
    num(len1);
    sink.out_str(" bytes captured, checksum ");
    sink.out_hex16(ck1);
    sink.out_str("\n");

    scene.clear_perturb();
    scene.render(0, 0);
    fb.capture_reset();
    paint(srf);
    fb.flush(srf);
    let len2 = fb.capture_len();
    let ck2 = fb.capture_checksum();
    sink.out_str("     back again:    ");
    num(len2);
    sink.out_str(" bytes captured, checksum ");
    sink.out_hex16(ck2);
    sink.out_str("\n");

    // THE NON-VACUITY ASSERTIONS.  Everything below is worthless without them,
    // and they come first for that reason.
    need(len0 > 100, "J: nothing was captured, so every comparison here would pass");
    need(ck0 != 0, "J: the plain frame's checksum is zero, so it cannot distinguish anything");
    need(len1 > 100, "J: the perturbed frame captured nothing");
    need(ck1 != 0, "J: the perturbed frame's checksum is zero");
    // One pixel changed, so the bytes must differ...
    ok(ck1 != ck0);
    // ...and changing it back must restore the checksum EXACTLY, which is the
    // half that says the sensitivity is real and not just noise.
    ok(ck2 == ck0);
    ok(len2 == len0);
    // A second flip of the same pixel must give the same answer: the whole thing
    // is deterministic, so a golden built on it means something.
    scene.perturb(cell, PERT_MASK);
    scene.render(0, 0);
    fb.capture_reset();
    paint(srf);
    fb.flush(srf);
    ok(fb.capture_checksum() == ck1);
    ok(fb.capture_len() == len1);
    scene.clear_perturb();
    // And the perturbed SAMPLE's colour really is different, read back out of
    // the store rather than out of the capture: the checksum could in principle
    // move for some other reason, and this is what ties the two together.
    scene.perturb(cell, PERT_MASK);
    scene.render(0, 0);
    let pcol = scene.scol(cell);
    scene.clear_perturb();
    scene.render(0, 0);
    let ccol = scene.scol(cell);
    sink.out_str("     sample ");
    num(cell);
    sink.out_str(": colour ");
    sink.out_hex16(ccol);
    sink.out_str(" plain, ");
    sink.out_hex16(pcol);
    sink.out_str(" perturbed\n");
    ok(pcol != ccol);
    fb.capture_off();
};

// ─────────────────────────────────────────────────────── the entry point ───

def run(level: long) -> long {
    scene.init();
    scene.set_fov(32);
    scene.palette(0);
    sink.out_str("raytracer: property check.  No reference file is involved: every\n");
    sink.out_str("  expectation below is either an exact integer computed outside this\n");
    sink.out_str("  program, an identity with an exact answer, or a bound taken from the\n");
    sink.out_str("  shape of the scene rather than from the code under test.\n");

    block_a();
    block_b();
    block_c();
    block_d();
    block_e();
    block_f();
    block_g();
    block_h();
    block_i();
    block_j();

    say("");
    sink.out_str("     assertions ");
    num(CHECKS);
    sink.out_str(", failures ");
    num(FAILS);
    sink.out_str(", level ");
    num(level);
    sink.out_str("\n");
    if (FAILS == 0) {
        sink.out_str("     RESULT  PASS\n");
        sink.out_flush();
        0
    } else {
        sink.out_str("     RESULT  FAIL\n");
        sink.out_flush();
        1
    }
};

export { run };