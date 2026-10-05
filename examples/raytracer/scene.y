// scene.y -- the geometry of the raytracer.
//
// One camera, six primitives (four spheres and two planes), a recursive
// intersection with a hard depth cap, and a shading pass.  Everything is
// integer fixed point in Q16 (1.0 = 65536), because Y has no float -> long and
// no cast syntax at all (ORCHESTRATOR.md 2.4a) and no math functions either
// (2.4b).  fx.y is used for the camera's four trig calls a frame, for tan(fov)
// and for one square root per sample.
//
// THE SCALE, AND THE TRAP THAT COMES WITH IT
//
//   Every quantity below is a Q16 *integer*.  Dividing one Q16 integer by
//   another does NOT give a Q16 quotient -- it gives their plain RATIO, which
//   is what every hand-rolled fixed-point renderer in this campaign got wrong
//   (examples/BUGS.md, and the Q16 section of fractal's README: six separate
//   defects, all of that one shape).  So:
//
//     a / b             both Q16 -> a scalar ratio.  Right for a RATIO, wrong
//                                    for a distance.
//     (a << 16) / b     the Q16 quotient.
//
//   ray_sphere and plane_t below both lift, and the places that want a genuine
//   ratio (the fog, the sky gradient) deliberately do not.  Each site says
//   which of the two it is doing, because "which" is the whole bug.
//
//   Every shift here is `>>` (arithmetic) unless the operand is provably
//   non-negative, which is noted at the site.  `>>>` on a value that can be
//   negative is silent and catastrophic (ORCHESTRATOR.md 2.15).
//
//   Nothing is allocated on the frame path: every array is module-level and
//   sized by a literal, and the tracer's answer travels in module-level longs
//   rather than in a record.

import fx;
import tui;

// ───────────────────────────────────────────────────────────────── scale ────

const ONE: long = 65536;             // 1.0 in Q16
const MAXC: long = 160;              // the cell cap
const MAXR: long = 80;
const MAXW: long = 320;              // MAXC * 2, the widest sample grid
const MAXH: long = 160;              // MAXR * 2
const MAXSAMP: long = 51200;         // MAXW * MAXH
const TMAX: long = 2621440;          // 40 scene units: the far plane
const TMIN: long = 256;              // 2^-8 unit: the near clip
const BIAS: long = 2048;             // 2^-5 unit: the reflection self-hit offset

// ─────────────────────────────────────────────────────────────── primitives ─
//
// Object ids are 0..NSPH-1 for the spheres and NSPH+k for the planes, so one
// table indexes every per-object property and the tracer can name "object 4"
// without a second lookup.

const NSPH: long = 4;
const NPLANE: long = 2;
const OBJ_FLOOR: long = 4;
const OBJ_WALL: long = 5;

// Spheres.  Centres and radii are exact multiples of 1/16 of a unit, which
// makes every term of the intersection EXACT in Q16 -- and check.y depends on
// that exactness, because it compares the discriminant against integers it
// derived outside this program.
let SCX: [long; 4] = [0, 0 - 85197, 72090, 19661];
let SCY: [long; 4] = [0, 22938, 16384, 9830];
let SCZ: [long; 4] = [0, 0 - 26214, 0 - 58982, 0 - 111411];
let SCR: [long; 4] = [65536, 39322, 29491, 19661];

// Planes as { p : n.p = d }, n a unit Q16 vector.
//   0: the floor,  n = +y, y = -1.0
//   1: the back wall, n = +z, z = -4.0
let PNLX: [long; 2] = [0, 0];
let PNY: [long; 2] = [65536, 0];
let PNLZ: [long; 2] = [0, 65536];
let PLD: [long; 2] = [0 - 65536, 0 - 393216];

// Reflectivity per object, 0..255; 255 is a mirror.  The floor is faintly
// reflective on purpose: a raytracer whose only mirror is one small sphere
// spends most of its bounce budget doing nothing, and a floor reflection is
// the cheapest way to give the deeper levels something to see.
let SREFL: [long; 6] = [0, 255, 110, 0, 45, 0];

// Base albedo per object, filled by init() because tui.rgb is a call.
let OBJRGB: [long; 6] = [0, 0, 0, 0, 0, 0];

let CHKA: long = 0;                 // the floor's checkerboard, two greys
let CHKB: long = 0;
let SKYH: long = 0;                 // the sky's horizon and zenith
let SKYZ: long = 0;
let SUNC: long = 0;                 // the sun's colour
let FOGC: long = 0;                 // the fog's colour
let WALLHI: long = 0;               // the back wall's gradient, top end

// The light, L = (-1, 2, 2)/3: a unit vector to within 2e-4 whose parts are
// exact multiples of 2^16/3, so no normalisation is needed.  It comes from the
// upper LEFT and the FRONT, so the camera-facing side of every sphere is the
// lit side and the frame has form instead of a flat wash.
const LNX: long = 0 - 21846;
const LNY: long = 43691;
const LNZ: long = 43691;
const AMB: long = 30;                // the ambient floor of the diffuse term
const SPMAX: long = 150;             // the specular highlight's peak, 0..255
const FOG0: long = 327680;           // fog starts at 5.0 units
const FOG1: long = 1703936;          // and is total at 26.0 units

def init() -> void {
    OBJRGB[0] = tui.rgb(196, 62, 54);      // sphere 0, crimson, matte
    OBJRGB[1] = tui.rgb(226, 230, 238);    // sphere 1, the mirror
    OBJRGB[2] = tui.rgb(226, 176, 74);     // sphere 2, gold, part mirror
    OBJRGB[3] = tui.rgb(62, 150, 158);     // sphere 3, teal, matte
    OBJRGB[4] = tui.rgb(0, 0, 0);          // the floor's checker supplies it
    OBJRGB[5] = tui.rgb(40, 44, 56);       // the wall's gradient starts here
    CHKA = tui.rgb(34, 36, 42);
    CHKB = tui.rgb(84, 86, 98);
    SKYH = tui.rgb(122, 132, 150);
    SKYZ = tui.rgb(28, 40, 72);
    SUNC = tui.rgb(255, 238, 198);
    FOGC = tui.rgb(46, 54, 72);
    WALLHI = tui.rgb(96, 104, 126);
};

// POBJ is the palette's version of the object colours; palette() rebuilds the
// whole set on a keypress and never touches the geometry.
let POBJ: [long; 6] = [0, 0, 0, 0, 0, 0];
const NPAL: long = 5;

// ─────────────────────────────────────────────────────────── tracer output ──
//
// One trace() writes all of these.  trace() recurses, so a caller that needs
// its OWN answer to survive a recursive call must save these first -- which is
// exactly what trace() does internally before it recurses, and why this is
// written as an explicit save/restore rather than as a record return.  (A
// record returned from a recursive def allocates per call, and the arena never
// frees: a 64-byte record at 51200 samples x 4 levels is 13 MB a frame.)

let THIT: long = 0;               // 1 if the ray found something
let TOBJ: long = 0 - 1;           // which object, -1 for a miss
let TT: long = 0;                // the distance to the hit, Q16
let TDP: long = 0;               // the depth at which it was found
let HX: long = 0;
let HY: long = 0;
let HZ: long = 0;
let NXV: long = 0;               // the unit surface normal at the hit, Q16
let NYV: long = 0;
let NZV: long = 0;
let RCOL: long = 0;              // the shaded colour of this ray's answer
let RLUM: long = 0;              // its luminance, 0..255

// ray_sphere()'s answer.  RS_DISC is the discriminant in Q32 -- the single
// number that decides hit from miss, and the one check.y compares against
// analytic geometry derived outside this program.
let RS_HIT: long = 0;
let RS_T: long = 0;
let RS_TN: long = 0;
let RS_TF: long = 0;
let RS_DISC: long = 0;
let RS_A: long = 0;
let RS_B: long = 0;
let RS_C: long = 0;
let RS_IN: long = 0;             // 1 if the eye was inside the sphere

// plane_t()'s answer.
let PT_T: long = 0;
let PT_HIT: long = 0;

// reflect()'s answer, kept separate because check.y asks it the one question
// that has an exact answer: does |r| come back as |d|?
let RFX: long = 0;
let RFY: long = 0;
let RFZ: long = 0;

// ─────────────────────────────────────────────────────────── the primitives ─

// ray_sphere -- the closed-form ray/sphere intersection, which is the whole
// reason this example can be checked against a hand computation.  With
//     oc = o - c,  a = d.d,  b = oc.d,  cc = oc.oc - r.r
// the ray meets the sphere iff disc = b*b - a*cc >= 0, and the roots are
//     t = (-b -+ sqrt(disc)) / a.
//
// A negative disc misses.  So does a ray whose roots are both behind the eye,
// EVEN THOUGH the discriminant says otherwise -- and that is a second test,
// independent of the discriminant, which an analytic oracle has to make too.
// Case E in check.y is exactly that: from five units away, pointing straight
// away from a sphere of radius one, disc = 2^32 > 0 and the answer is still a
// miss, because the nearest point of that ray is the eye itself, five units
// from a surface of radius one.
//
// A ray that starts INSIDE the sphere takes the far root (tn <= 0 < tf).  That
// is the standard convention and it is what makes the camera dollying inside a
// sphere show the inside of it rather than vanish.
def ray_sphere(ox: long, oy: long, oz: long,
               dx: long, dy: long, dz: long,
               cx: long, cy: long, cz: long, r: long) -> void {
    let ocx = ox - cx;
    let ocy = oy - cy;
    let ocz = oz - cz;
    // a, b and cc are all brought DOWN to Q16 so that disc = b*b - a*cc is a
    // Q32 number whose square root comes out in Q16 directly.  Leaving a in Q32
    // would make a*cc a Q48 product, which is the overflow the brief warns
    // about when it says "a Q30 dot product is Q60 and needs a scale-down".
    let a = (dx * dx + dy * dy + dz * dz) >> 16;
    let b = (ocx * dx + ocy * dy + ocz * dz) >> 16;
    let cc = ((ocx * ocx + ocy * ocy + ocz * ocz) >> 16) - ((r * r) >> 16);
    let disc = b * b - a * cc;
    RS_A = a;
    RS_B = b;
    RS_C = cc;
    RS_DISC = disc;
    RS_HIT = 0;
    RS_IN = 0;
    RS_T = 0;
    RS_TN = 0;
    RS_TF = 0;
    // a <= 0 only when d is the zero vector, which no caller builds, but the
    // division below is a runtime trap on zero and this is where it is closed
    // off -- once, rather than trusted at every call site.
    if (disc >= 0 && a > 0) {
        let sq = fx.isqrt(disc);          // exact integer root of a Q32 value
        // THE LIFT.  b, sq and a are all Q16 and the answer is a Q16 distance,
        // so the numerator is lifted before the division.  Without it
        // (-b - sq)/a answers a scalar RATIO, and the tell is a hit distance
        // that comes out as a small constant independent of the geometry: case
        // D of check.py has a true answer of 0.270996 units and the unlifted
        // one is 0, because a is not 1 there.
        let tn = ((0 - b - sq) << 16) / a;
        let tf = ((0 - b + sq) << 16) / a;
        RS_TN = tn;
        RS_TF = tf;
        if (tf > TMIN) {
            RS_HIT = 1;
            if (tn > TMIN) {
                RS_T = tn;
            } else {
                RS_T = tf;
                RS_IN = 1;
            };
        };
    }
};

// plane_t -- t where the ray meets { p : n.p = d }, or -1.
//     t = (d - n.o) / (n.d)
// A ray parallel to the plane has n.d == 0 and there is no answer: that is a
// miss, not a division by zero.  t <= 0 is behind the eye or already on the
// surface, and is a miss for the same reason the sphere's is.
//
// The wall is a bounded quad, not an infinite plane: an infinite back wall
// catches every ray that misses everything, so the frame has no sky in it at
// all and hitpc is 100 everywhere (measured, before this test existed).  The
// bounds are the rectangle's own edges, so the answer is still closed form.
def plane_t(ox: long, oy: long, oz: long,
            dx: long, dy: long, dz: long, k: long) -> long {
    let den = (PNLX[k] * dx + PNY[k] * dy + PNLZ[k] * dz) >> 16;
    PT_HIT = 0;
    PT_T = 0;
    if (den == 0) { return 0 - 1; };
    let num = PLD[k] - ((PNLX[k] * ox + PNY[k] * oy + PNLZ[k] * oz) >> 16);
    // THE LIFT again: num and den are Q16 and the answer is a Q16 distance.
    let t = (num << 16) / den;
    if (t <= TMIN) { return 0 - 1; };
    if (k == 1) {
        let px = ox + ((dx * t) >> 16);
        let py = oy + ((dy * t) >> 16);
        if (px < 0 - 393216 || px > 393216) { return 0 - 1; };   // |x| < 6.0
        if (py < 0 - 65536 || py > 262144) { return 0 - 1; };   // -1 .. 4.0
    };
    PT_T = t;
    PT_HIT = 1;
    t
};

// ───────────────────────────────────────────────────────────────── shading ──

// lum(c) -- BT.601 luma of a packed colour, 0..255.  The weights sum to 256, so
// the shift is exact at full white.
def lum(c: long) -> long {
    (tui.r_of(c) * 77 + tui.g_of(c) * 151 + tui.b_of(c) * 28) >> 8
};

// diffuse_level(nx, ny, nz) -- how lit a surface with this unit normal is,
// 0..255: ambient plus (1 - ambient) * max(0, n.L).
//
// THE SIGN IS THE WHOLE OF IT.  With the max() OUTSIDE -- clamp(n.L, 0) -- a
// normal pointing away from the light is dark, which is correct.  Written with
// the max() inside, as |n.L|, the whole scene lights up from behind: every
// surface in the frame looks flat and wrong, with no trap and no diagnostic,
// and a golden file reproduces it for ever.  check.y calls this function with
// n = L and n = -L and asserts that the first is bright and the second is not,
// so the mistake cannot come back quietly.
def diffuse_level(nx: long, ny: long, nz: long) -> long {
    let d = (nx * LNX + ny * LNY + nz * LNZ) >> 16;
    if (d < 0) { d = 0; };
    let di = (d * 255) >> 16;                   // 0..255, and d >= 0 here
    AMB + ((255 - AMB) * di) / 255
};

// specular_level(nx, ny, nz, dx, dy, dz) -- the Blinn highlight, 0..255.
// The half vector is h = L + V with V the direction back to the eye, so -d for
// a direction d pointing away from it.  |h| is NOT a constant: it runs from 0
// (looking away from the light) to 2 (looking straight into it), and normalising
// it with a fixed 1/sqrt(2) reports a half-vector cosine above 1 over a broad
// cap, saturates the exponent, and blows a whole region of the sphere to pure
// white.  One isqrt and one division per shaded sample is much cheaper than
// that.
//
// d is expected to be roughly a unit vector (render normalises it); the
// intersection math does not care, and neither does this beyond the half
// vector's length.
def specular_level(nx: long, ny: long, nz: long,
                   dx: long, dy: long, dz: long) -> long {
    let hx = LNX - dx;
    let hy = LNY - dy;
    let hz = LNZ - dz;
    let hl = fx.isqrt(hx * hx + hy * hy + hz * hz);      // |L - d|, Q16
    if (hl == 0) { return 0; };
    let s = ((nx * hx + ny * hy + nz * hz) >> 16) * ONE / hl;   // n.h, Q16
    if (s < 0) { s = 0; };
    // s^8, three squares.  The exponent is deliberately LOW: at one ray per
    // cell half a cell, a 24th or 64th power of a cosine that moves by a per
    // cent between neighbouring cells turns the highlight into salt and
    // pepper, and no care in the tracer will fix it.
    let s2 = (s * s) >> 16;
    let s4 = (s2 * s2) >> 16;
    let s8 = (s4 * s4) >> 16;
    (s8 * 255) >> 16
};

// sky(dx, dy, dz) -- the colour of a ray that hit nothing: a vertical gradient
// plus the sun's glow around L.
//
// The gradient coordinate is a RATIO of a Q16 direction component against a
// constant, so no lift here -- that is the point of the `+ 128` and the
// `>> 9`: they are not scales, they are the offsets that put the horizon at
// the middle of the ramp.
def sky(dx: long, dy: long, dz: long) -> long {
    let t = (dy >> 9) + 128;
    if (t < 0) { t = 0; };
    if (t > 255) { t = 255; };
    let col = tui.lerp_rgb(SKYH, SKYZ, t);
    let g = (dx * LNX + dy * LNY + dz * LNZ) >> 16;
    if (g > 0) {
        // g^8, so the sun is a small disc rather than half the sky
        let g2 = (g * g) >> 16;
        let g4 = (g2 * g2) >> 16;
        let g8 = (g4 * g4) >> 16;
        let r = tui.r_of(col) + ((SPMAX * g8) >> 16);
        let gg = tui.g_of(col) + ((SPMAX * g8) >> 16);
        let b = tui.b_of(col) + ((SPMAX * g8) >> 16);
        col = tui.rgb(r, gg, b);
    };
    col
};

// object_rgb(obj, hx, hy, hz) -- the albedo of the surface at a hit point.
// The floor is a checkerboard on integer cells and the wall is a vertical
// gradient; both index off the hit point, so they need no extra state.
def object_rgb(obj: long, hx: long, hy: long, hz: long) -> long {
    if (obj == OBJ_FLOOR) {
        // A one-unit checkerboard.  ix and iz are the floor() of the hit point's
        // cell index (>> is arithmetic, so it rounds toward minus infinity), and
        // the parity of their SUM is the checker -- no absolute value, because
        // |x| is symmetric about the origin and the parity of |ix| + |iz| puts
        // two cells of the same colour side by side across the axis.
        // TWO units a cell, not one: seen at a grazing angle a one-unit cell is
        // narrower than a pixel from about six units out, and a checkerboard
        // narrower than the sampling grid does not average to grey -- it
        // aliases to something that depends on where the samples land, which is
        // the one thing a checkerboard must not do.
        let ix = hx >> 17;
        let iz = hz >> 17;
        if ((ix + iz) % 2 == 0) { CHKA } else { CHKB }
    } else if (obj == OBJ_WALL) {
        // A vertical gradient across the wall's own height, -1 to 4.0 units.
        // The `* 255 / (range)` is a RATIO scaled to 0..255, so the lift is not
        // wanted here -- with one, the gradient saturates at the first sample
        // and the wall is a single flat colour.
        let t = (((hy + 65536) * 255) / 327680) ;
        if (t < 0) { t = 0; };
        if (t > 255) { t = 255; };
        tui.lerp_rgb(POBJ[OBJ_WALL], WALLHI, t)
    } else {
        POBJ[obj]
    }
};

// shade_local(obj, hx, hy, hz, nx, ny, nz, dx, dy, dz) -- an opaque surface's
// own colour: albedo x (ambient + diffuse) plus the specular peak, each channel
// clamped.
def shade_local(obj: long, hx: long, hy: long, hz: long,
                nx: long, ny: long, nz: long,
                dx: long, dy: long, dz: long) -> long {
    let base = object_rgb(obj, hx, hy, hz);
    let lv = diffuse_level(nx, ny, nz);
    let sp = specular_level(nx, ny, nz, dx, dy, dz) * SPMAX / 255;
    let r = tui.r_of(base) * lv / 255 + sp;
    let g = tui.g_of(base) * lv / 255 + sp;
    let b = tui.b_of(base) * lv / 255 + sp;
    tui.rgb(r, g, b)
};

// fog(col, t, dx, dy, dz) -- blend a surface toward THE SKY IN THE RAY'S OWN
// DIRECTION with distance.  This is the "shade by depth" half of the shading.
//
// Blending toward a single fog COLOUR is the version that puts a visible seam
// along the horizon: the floor at fourteen units is FOGC, and the sky just above
// it is the gradient, and the two only match at one height.  Blending toward
// sky(d) makes the far plane continuous with the sky by construction, because
// as t -> infinity the surface's own colour is replaced by exactly the colour
// that ray would have had if it had hit nothing.
//
// The coordinate is a RATIO, not a quotient: (t - FOG0)/(FOG1 - FOG0) is
// already dimensionless and the 255 in front of it is a plain scale of that
// ratio.  This is why there is deliberately NO lift on this line -- and why
// "add the lift here too" would be the bug rather than the fix.  (The two are
// one character apart and the lift version saturates the fog at the first
// sample, which reads as a scene with no distance in it at all.)
def fog(col: long, t: long, dx: long, dy: long, dz: long) -> long {
    let f = ((t - FOG0) * 255) / (FOG1 - FOG0);
    if (f < 0) { f = 0; };
    if (f > 255) { f = 255; };
    tui.lerp_rgb(col, sky(dx, dy, dz), f)
};

// mix(a, b, k) -- a*k/255 + b*(255-k)/255.  The reflectivity blend, so a part
// mirror is a part mirror rather than a binary one.
def mix(a: long, b: long, k: long) -> long {
    let ia = 255 - k;
    tui.rgb((tui.r_of(a) * k + tui.r_of(b) * ia) / 255,
           (tui.g_of(a) * k + tui.g_of(b) * ia) / 255,
           (tui.b_of(a) * k + tui.b_of(b) * ia) / 255)
};

// reflect(dx, dy, dz, nx, ny, nz) -- d - 2(d.n)n, the mirror formula for a unit
// normal.  Its answer is in RFX/RFY/RFZ.
//
// |r| = |d| is an IDENTITY here, for any n with |n| = 1, and it is the
// strongest cheap assertion in this file: a sign error in the dot product, a
// missing normal, or a transposed term all change |r| immediately, and it is
// the one property of the reflection that has an exact answer rather than a
// tolerance.  check.y asserts it.
//
// Note the sign of n does not matter: r(-n) = d - 2(d.-n)(-n) = r(n), so
// mutating the normal's sign is an EQUIVALENT defect and check.y proves that
// rather than pretending to catch it.
def reflect(dx: long, dy: long, dz: long,
            nx: long, ny: long, nz: long) -> void {
    let dn = (dx * nx + dy * ny + dz * nz) >> 16;
    RFX = dx - ((2 * dn * nx) >> 16);
    RFY = dy - ((2 * dn * ny) >> 16);
    RFZ = dz - ((2 * dn * nz) >> 16);
};

// ────────────────────────────────────────────────────────────────── trace ───

// BHIST counts every hit in the recursion tree of the current frame, by depth;
// BMAX is the deepest depth actually reached.  Both are the renderer's answer
// to "how deep did it actually go", which is what the bounce cap is asserted
// against -- and the cap's own test asserts that the histogram is non-empty at
// every depth it is supposed to reach, because a cap that never fires and a cap
// that is never reached look identical from the outside.
let BHIST: [long; 16] = [0; 16];
let BMAX: long = 0;
let BHITS: long = 0;
// DEGEN counts the reflections that found the surface they left again -- a
// mirror seeing itself.  It takes BOTH the object id and the distance, and both
// are needed: a distance test alone fires on the legitimate case of a ray
// reflecting off the floor immediately in front of the wall, where the two hit
// points are the same point because the two surfaces meet at y = -1, z = -6
// (measured: 697 of them in one frame, which is very nearly every depth-1 hit),
// and an object test alone misses a reflection that is rejected by the near clip
// and lands somewhere else entirely.
const DEGEN_R2: long = 16777216;     // (2^-4)^2 in Q32, i.e. 4096*4096
let DEGEN: long = 0;
let RAYS: long = 0;
let BOUCE: long = 3;

def set_bounces(n: long) -> void { BOUCE = n };

def trace(ox: long, oy: long, oz: long,
          dx: long, dy: long, dz: long, depth: long) -> void {
    // The nearest hit over every primitive.  Four sphere quadratics and two
    // plane quotients per level, and the winner is the smallest t that clears
    // the near clip.  There is no early exit to be had: a nearer object found
    // later must still be compared, which is what `bt` is for.
    let bt = TMAX;
    let bobj = 0 - 1;
    for k in 0..NSPH {
        ray_sphere(ox, oy, oz, dx, dy, dz, SCX[k], SCY[k], SCZ[k], SCR[k]);
        if (RS_HIT != 0 && RS_T < bt) { bt = RS_T; bobj = k; }
    };
    for k in 0..NPLANE {
        let t = plane_t(ox, oy, oz, dx, dy, dz, k);
        if (t > 0 && t < bt) { bt = t; bobj = NSPH + k; }
    };

    if (bobj < 0) {
        // Nothing.  The sky, and the sky's the fog colour too, so a surface
        // fading out of the distance fades into the sky rather than into a
        // flat grey.
        THIT = 0;
        TOBJ = 0 - 1;
        TT = TMAX;
        TDP = depth;
        HX = 0; HY = 0; HZ = 0;
        NXV = 0; NYV = 0; NZV = 0;
        RCOL = sky(dx, dy, dz);
        RLUM = lum(RCOL);
        return;
    };

    // The hit point.  dx and bt are both Q16, so the product is Q32 and one
    // shift brings it down.
    let hx = ox + ((dx * bt) >> 16);
    let hy = oy + ((dy * bt) >> 16);
    let hz = oz + ((dz * bt) >> 16);
    // The outward normal.  For a sphere it is exactly (p - c)/r, and since the
    // hit point is on the surface that is exactly a unit vector -- which is
    // what lets reflect() be right without normalising it first.
    let nx = 0;
    let ny = 0;
    let nz = 0;
    if (bobj < NSPH) {
        let r = SCR[bobj];
        nx = ((hx - SCX[bobj]) * ONE) / r;
        ny = ((hy - SCY[bobj]) * ONE) / r;
        nz = ((hz - SCZ[bobj]) * ONE) / r;
    } else {
        let kk = bobj - NSPH;
        nx = PNLX[kk]; ny = PNY[kk]; nz = PNLZ[kk];
    };

    // This level's own answer has to survive the recursive call below, which
    // overwrites every one of these names.  Six longs, saved and restored.
    let my_t = bt;
    let my_obj = bobj;
    let my_hx = hx;
    let my_hy = hy;
    let my_hz = hz;
    let my_nx = nx;
    let my_ny = ny;
    let my_nz = nz;
    let mine = shade_local(bobj, hx, hy, hz, nx, ny, nz, dx, dy, dz);
    let refl = SREFL[bobj];

    if (refl > 0 && depth < BOUCE) {
        reflect(dx, dy, dz, nx, ny, nz);
        // The new origin is pushed BIAS along the OUTWARD normal, not along the
        // reflected direction: the reflected ray leaves the surface, so an
        // offset along the normal is the one that cannot re-find this surface
        // at t ~ 0.  Without it every mirror reports itself as its own
        // reflection and the picture is a solid ball of the mirror's colour.
        trace(my_hx + ((nx * BIAS) >> 16), my_hy + ((ny * BIAS) >> 16),
              my_hz + ((nz * BIAS) >> 16), RFX, RFY, RFZ, depth + 1);
        // The reflection's first hit must not be where the reflection started.
        // The BIAS offset is what guarantees it and this counter is how the
        // guarantee is checked rather than believed.
        if (THIT != 0 && TOBJ == my_obj) {
            let ddx = HX - my_hx;
            let ddy = HY - my_hy;
            let ddz = HZ - my_hz;
            if (((ddx * ddx + ddy * ddy + ddz * ddz) >> 16) < DEGEN_R2) {
                DEGEN = DEGEN + 1;
            };
        };
        mine = mix(mine, RCOL, refl);
    };

    THIT = 1;
    TOBJ = my_obj;
    TT = my_t;
    TDP = depth;
    HX = my_hx;
    HY = my_hy;
    HZ = my_hz;
    NXV = my_nx;
    NYV = my_ny;
    NZV = my_nz;
    RCOL = fog(mine, my_t, dx, dy, dz);
    RLUM = lum(RCOL);

    // The per-frame bounce accounting.  BHIST counts every hit at every level,
    // which is what makes the cap's test non-vacuous: a cap of 3 with nothing
    // at depth 3 has to fail, because depth 3 is what the cap permits.
    if (depth < 16) {
        BHIST[depth] = BHIST[depth] + 1;
        BHITS = BHITS + 1;
    };
    if (depth > BMAX) { BMAX = depth; }
};

// tintc(c, p) -- the palette's version of one colour.
//   0 ember     identity: the colours in init()
//   1 ice       blue up, red down
//   2 spectrum  the channels rotated, which is the cheapest honest hue wheel
//   3 mono      luma in all three, so only the geometry and the shading show
//   4 phosphor  green, the classic terminal
//
// A palette is a per-CHANNEL function of the base colour rather than a second
// set of hand-picked values, so a new look is one line and the geometry is
// never touched.  The table is built once per palette change, never per pixel.
def tintc(c: long, p: long) -> long {
    let r = tui.r_of(c);
    let g = tui.g_of(c);
    let b = tui.b_of(c);
    if (p == 1) {
        let nb = (b * 4) / 3;
        if (nb > 255) { nb = 255; };
        tui.rgb((r * 3) / 4, (g * 9) / 10, nb)
    } else if (p == 2) {
        tui.rgb(b, r, g)
    } else if (p == 3) {
        let l = (r * 77 + g * 151 + b * 28) >> 8;
        tui.rgb(l, l, l)
    } else if (p == 4) {
        let l = (r * 77 + g * 151 + b * 28) >> 8;
        tui.rgb((l * 3) / 10, l, (l * 4) / 10)
    } else {
        c
    }
};

def palette(p: long) -> void {
    let i = 0;
    while (i < 6) {
        POBJ[i] = tintc(OBJRGB[i], p);
        i = i + 1;
    };
    CHKA = tintc(tui.rgb(34, 36, 42), p);
    CHKB = tintc(tui.rgb(84, 86, 98), p);
    SKYH = tintc(tui.rgb(122, 132, 150), p);
    SKYZ = tintc(tui.rgb(28, 40, 72), p);
    SUNC = tintc(tui.rgb(255, 238, 198), p);
    FOGC = tintc(tui.rgb(46, 54, 72), p);
    WALLHI = tintc(tui.rgb(96, 104, 126), p);
};

// ───────────────────────────────────────────────────────────────── camera ───

let TX: long = 0;                   // the target: (0, -0.10, -0.40)
let TY: long = 0 - 6554;
let TZ: long = 0 - 26214;
let EYX: long = 0;                  // the eye
let EYY: long = 0;
let EYZ: long = 0;
let FWX: long = 0;                  // the unit basis: forward
let FWY: long = 0;
let FWZ: long = 0;
let RIX: long = 0;                  // right
let RIY: long = 0;
let RIZ: long = 0;
let UIX: long = 0;                  // up
let UIY: long = 0;
let UIZ: long = 0;
let FOVX: long = 40632;             // the horizontal half-angle, tan, in Q16

def set_target(tx: long, ty: long, tz: long) -> void {
    TX = tx; TY = ty; TZ = tz
};

// set_camera(az, el, dist) -- az and el are Q16 radians, dist is Q16 units.
// The eye orbits the target at `dist`, the basis is built from it, and the four
// trig calls happen ONCE per frame rather than once per sample.
def set_camera(az: long, el: long, dist: long) -> void {
    let sa = fx.sin(az << 14);      // Q30 in, Q30 out; << 14 is Q16 -> Q30
    let ca = fx.cos(az << 14);
    let se = fx.sin(el << 14);
    let ce = fx.cos(el << 14);
    let dd = dist << 14;             // Q16 units -> Q30, for fx.mul
    // THE TARGET IS LIFTED FIRST.  The target is Q16 and fx.mul answers Q30, so
    // adding it to a Q30 term BEFORE the >> 14 scales it by 2^14: a target of
    // -0.4 units contributes -1.6 units, and the camera ends up 25% further
    // from the scene than it was asked for.  Nothing about that looks wrong --
    // the picture is still a picture, just of a different place -- which is
    // why the compiler warning that would have caught it does not exist.
    EYX = ((TX << 14) + fx.mul(fx.mul(dd, ce), sa)) >> 14;
    EYY = ((TY << 14) + fx.mul(dd, se)) >> 14;
    EYZ = ((TZ << 14) + fx.mul(fx.mul(dd, ce), ca)) >> 14;

    // forward = normalise(target - eye)
    let gx = TX - EYX;
    let gy = TY - EYY;
    let gz = TZ - EYZ;
    let gl = fx.isqrt(gx * gx + gy * gy + gz * gz);
    if (gl < 1) { gl = 1; };
    FWX = (gx * ONE) / gl;
    FWY = (gy * ONE) / gl;
    FWZ = (gz * ONE) / gl;

    // right = normalise(forward x worldup) with worldup = (0,1,0), which is
    // (-fz, 0, fx).  Looking straight up or down makes that vector vanish, so
    // that case falls back to (1,0,0) rather than dividing by zero -- and the
    // elevation is clamped to +-45 degrees anyway, so it cannot happen from the
    // keyboard.  It is closed off here once, which is the only reason it is.
    let rx = 0 - FWZ;
    let rz = FWX;
    let rl2 = rx * rx + rz * rz;
    if (rl2 < 256) {
        RIX = ONE; RIY = 0; RIZ = 0;
    } else {
        let rl = fx.isqrt(rl2);
        RIX = (rx * ONE) / rl;
        RIY = 0;
        RIZ = (rz * ONE) / rl;
    };
    // up = right x forward
    UIX = (RIY * FWZ - RIZ * FWY) >> 16;
    UIY = (RIZ * FWX - RIX * FWZ) >> 16;
    UIZ = (RIX * FWY - RIY * FWX) >> 16;
};

// set_fov(deg) -- the horizontal half-angle in degrees.  Refuses nothing; the
// caller has already bounded it, because fx.tan divides by cos and 90 degrees
// would be a runtime trap rather than a diagnostic.
def set_fov(deg: long) -> void {
    FOVX = fx.tan(fx.to_rad(deg << 30)) >> 14;
};

def fovx() -> long { FOVX };

// ────────────────────────────────────────────────────────── the sample grid ──

let GW: long = 1;                  // the sample grid
let GH: long = 1;
let SX: long = 1;                  // samples a cell, horizontally
let SY: long = 1;                  // samples a cell, vertically
let RXO: [long; 320] = [0; 320];   // the tangent-space x of each column, Q16
let RYO: [long; 160] = [0; 160];   // and of each row

// grid_setup(cols, rows, sx, sy) -- the sample grid, and the two per-axis
// tangent offsets.
//
// THE ASPECT, AND THE FACTOR OF TWO IN IT.  A terminal cell is about twice as
// tall as it is wide: GW samples span GW *pixels* across, and GH samples span
// 2*GH pixels up.  "Match the angular scale per PIXEL" -- which is what makes a
// sphere look like a sphere rather than an egg -- therefore means
//
//     FOVY / (2 * GH)  ==  FOVX / GW        =>     FOVY = FOVX * 2 * GH / GW
//
// and the 2 is load-bearing.  Without it the vertical field is HALF of what it
// should be, which stretches every object 2:1 up and down and is not obviously
// wrong to look at: an egg-shaped sphere and an egg-shaped checkerboard read as
// "a raytracer of a scene of eggs".  Nothing traps, no count moves, and the
// silhouette is still the silhouette -- so it is exactly the sort of defect a
// golden file blesses for ever.  (fractal's grid_setup carries the same
// factor, for the same reason.)
def grid_setup(cols: long, rows: long, sx: long, sy: long) -> void {
    SX = sx;
    SY = sy;
    GW = cols * sx;
    GH = rows * sy;
    let gx = 0;
    while (gx < GW) {
        RXO[gx] = ((2 * gx + 1 - GW) * FOVX) / GW;
        gx = gx + 1;
    };
    // THE PER-SAMPLE TANGENT STEP IS THE SAME IN BOTH AXES, TIMES TWO.
    //
    // A cell is about two pixels tall and one wide, so one vertical sample
    // covers twice the screen of one horizontal sample; to put the same angular
    // step on a pixel in both axes the vertical step per sample must therefore
    // be twice the horizontal one.  So the coefficient is 2*FOVX/GW and it does
    // NOT involve GH at all -- the number of rows decides how much of the scene
    // fits vertically, not how big a step a row takes.
    //
    // This was measured, not reasoned out, and the two candidates are far apart:
    // with the coefficient left at FOVX/GW the crimson sphere draws 12 columns
    // by 23 rows, and with a 2*GH/GW factor thrown in it draws 12 by 14; a round
    // sphere at this distance and size is 12 by 6.  Every intersection in the
    // frame is exact in all three variants, every distance is right, and the
    // shading is plausible -- which is why only the silhouette can catch it.
    let vsc = (2 * FOVX) / GW;
    let gy = 0;
    while (gy < GH) {
        // GH-1-2gy, not 2gy+1-GH: the vertical axis counts UP in this program
        // (grid row 0 is the TOP of the frame, and RYO is the tan of the ray's
        // elevation), so a row's offset has to be positive at the top.  The
        // mirrored formula renders the whole scene upside down, which is a
        // picture that still looks like a picture -- it is only the shading and
        // the floor that give it away.
        RYO[gy] = ((GH - 1 - 2 * gy) * vsc);
        gy = gy + 1;
    };
};

// ──────────────────────────────────────────────────────────── the frame ────

let SHIT: [long; 51200] = [0; 51200];   // 1 if this sample hit something
let SCOL: [long; 51200] = [0; 51200];   // its colour
// The primary hit, per sample: which object, how far, and where.  Three longs
// and two more is 2.4 MB of arena, allocated once at module scope and never
// again, and it is what lets check.y audit the WHOLE frame analytically rather
// than a handful of hand-picked rays: given the eye and a hit point p at
// distance t on object k, the two identities
//
//     |p - eye| == t                 and     p lies ON object k
//
// are the defining equations of the geometry, and neither of them is the
// equation the tracer solved.  A scaling slip, a wrong root, a mis-indexed
// store or an off-by-one in the hit point all break one of them immediately,
// over every sample, with no golden file involved.
let SOBJ: [long; 51200] = [0; 51200];
let STT: [long; 51200] = [0; 51200];
let SHX: [long; 51200] = [0; 51200];
let SHY: [long; 51200] = [0; 51200];
let SHZ: [long; 51200] = [0; 51200];
let HITS: long = 0;
// OBJCNT[k] is how many of this frame's samples hit object k-1, so object -1
// (the sky) is slot 0.  Eight longs, counted in trace()'s caller, and it is
// what makes "the mirror is in the picture" a fact rather than an assumption:
// a bounce-cap test that asserts on depth-1 hits is vacuous if nothing in the
// scene is reflective at all, and this is how that is ruled out.
let OBJCNT: [long; 8] = [0, 0, 0, 0, 0, 0, 0, 0];
let PERT_I: long = 0 - 1;               // the test hook: see perturb()
let PERT_M: long = 0;

// perturb(i, mask) -- the property check's hook, and the only way to change
// one sample of the frame.  It XORs `mask` into one sample's packed colour
// after the ray has been traced, which is precisely "one pixel of the image
// changed and nothing else did": the geometry, the depth, the hit flags and
// every other sample are bit-identical.
//
// It is not reachable from the command line, so the documented deterministic
// run cannot be perturbed by accident, and it is off (i == -1) by default.
def perturb(i: long, mask: long) -> void {
    PERT_I = i;
    PERT_M = mask;
};

def clear_perturb() -> void {
    PERT_I = 0 - 1;
    PERT_M = 0;
};

// render(seed, frame) -- one ray per sample, into the sample store.  No
// allocation.
//
// `seed` is 0 (the default) or a positive integer; it is a pure hash of
// (seed, frame, sample index), so it is reproducible from the seed alone and
// costs one multiply and a mask per sample -- and costs nothing at all when it
// is 0, which is what keeps the documented run byte-identical.  It jitters the
// sub-sample position inside its cell, which is the only place randomness can
// legitimately go: it changes which ray a cell casts, never what any ray means.
def render(seed: long, frame: long) -> void {
    HITS = 0;
    RAYS = GW * GH;
    for d in 0..16 { BHIST[d] = 0; };
    for d in 0..8 { OBJCNT[d] = 0; };
    BMAX = 0;
    BHITS = 0;
    DEGEN = 0;
    let jscale = if (seed == 0) { 0 } else { FOVX / (GW * 512) };
    let gy = 0;
    while (gy < GH) {
        let gx = 0;
        while (gx < GW) {
            // The sample's own index, recomputed rather than carried: carrying it
            // means one more place to forget to advance it, and the symptom is a
            // frame where every column of a row shares one sample's colour --
            // a plausible-looking picture with one column's worth of information.
            let idx = gy * GW + gx;
            let ux = RXO[gx];
            let uy = RYO[gy];
            if (jscale != 0) {
                // A sub-sample offset of +-1/512 of a cell: large enough to
                // break the sampling bands, small enough that it cannot move a
                // sample into a neighbouring cell's story.
                let h = (idx * 2654435761 + seed * 40503 + frame * 97) & 1048575;
                ux = ux + (((h % 1024) - 512) * jscale);
                uy = uy + ((((h / 1024) % 1024) - 512) * jscale);
            };
            let dx = FWX + ((RIX * ux) >> 16) + ((UIX * uy) >> 16);
            let dy = FWY + ((RIY * ux) >> 16) + ((UIY * uy) >> 16);
            let dz = FWZ + ((RIZ * ux) >> 16) + ((UIZ * uy) >> 16);
            // Normalise, once: |d|^2 is a Q32 integer and its exact integer root
            // is the Q16 length.  This is the one place the frame calls
            // fx.isqrt, and it buys two things -- a unit direction for the
            // specular half vector and the sky gradient, and a checkable
            // invariant (check.y asserts |d| == 1 on a frame's rays).
            let dl = fx.isqrt(dx * dx + dy * dy + dz * dz);
            if (dl < 1) { dl = 1; };
            trace(EYX, EYY, EYZ, (dx * ONE) / dl, (dy * ONE) / dl, (dz * ONE) / dl, 0);
            let c = RCOL;
            if (idx == PERT_I) { c = c ^ PERT_M; };
            SCOL[idx] = c;
            if (THIT != 0) {
                SHIT[idx] = 1;
                SOBJ[idx] = TOBJ;
                STT[idx] = TT;
                SHX[idx] = HX;
                SHY[idx] = HY;
                SHZ[idx] = HZ;
                HITS = HITS + 1;
                let ok = TOBJ + 1;
                if (ok >= 0 && ok < 8) { OBJCNT[ok] = OBJCNT[ok] + 1; };
            } else {
                SHIT[idx] = 0;
                SOBJ[idx] = 0 - 1;
                STT[idx] = 0;
                SHX[idx] = 0;
                SHY[idx] = 0;
                SHZ[idx] = 0;
            };
            gx = gx + 1;
        };
        gy = gy + 1;
    };
};

// ───────────────────────────────────────────────────────────── accessors ────

def grid_w() -> long { GW };
def grid_h() -> long { GH };
def grid_sx() -> long { SX };
def grid_sy() -> long { SY };
def shit(i: long) -> long { SHIT[i] };
def scol(i: long) -> long { SCOL[i] };
def hits() -> long { HITS };
def hit_obj(i: long) -> long { if (i >= 0 && i < MAXSAMP) { SOBJ[i] } else { 0 - 2 } };
def hit_t(i: long) -> long { if (i >= 0 && i < MAXSAMP) { STT[i] } else { 0 } };
def hit_x(i: long) -> long { if (i >= 0 && i < MAXSAMP) { SHX[i] } else { 0 } };
def hit_y(i: long) -> long { if (i >= 0 && i < MAXSAMP) { SHY[i] } else { 0 } };
def hit_z(i: long) -> long { if (i >= 0 && i < MAXSAMP) { SHZ[i] } else { 0 } };
def obj_at(k: long) -> long { if (k >= 0 && k < 8) { OBJCNT[k] } else { 0 } };
def rays() -> long { GW * GH };
def bounce_at(d: long) -> long { if (d < 16) { BHIST[d] } else { 0 } };
def bounce_max() -> long { BMAX };
def bounce_total() -> long { BHITS };
def self_hits() -> long { DEGEN };
def eye_x() -> long { EYX };
def eye_y() -> long { EYY };
def eye_z() -> long { EYZ };
def tgt_x() -> long { TX };
def tgt_y() -> long { TY };
def tgt_z() -> long { TZ };
def fwd_x() -> long { FWX };
def fwd_y() -> long { FWY };
def fwd_z() -> long { FWZ };
def rgt_x() -> long { RIX };
def rgt_y() -> long { RIY };
def rgt_z() -> long { RIZ };
def up_x() -> long { UIX };
def up_y() -> long { UIY };
def up_z() -> long { UIZ };
def tan_x(i: long) -> long { if (i >= 0 && i < MAXW) { RXO[i] } else { 0 } };
def tan_y(i: long) -> long { if (i >= 0 && i < MAXH) { RYO[i] } else { 0 } };

export { ONE, MAXC, MAXR, MAXW, MAXH, MAXSAMP, TMAX, TMIN, BIAS,
          NSPH, NPLANE, OBJ_FLOOR, OBJ_WALL, SREFL, OBJRGB,
          SCX, SCY, SCZ, SCR, PLD, PNLX, PNY, PNLZ,
          LNX, LNY, LNZ, AMB, SPMAX, FOG0, FOG1, SKYH, SKYZ, SUNC, FOGC,
          THIT, TOBJ, TT, TDP, HX, HY, HZ, NXV, NYV, NZV, RCOL, RLUM,
          RS_HIT, RS_T, RS_TN, RS_TF, RS_DISC, RS_A, RS_B, RS_C, RS_IN,
          PT_T, PT_HIT, RFX, RFY, RFZ,
          init, lum, diffuse_level, specular_level, sky, object_rgb,
          shade_local, fog, mix, reflect, trace, ray_sphere, plane_t,
          set_camera, set_fov, set_target, set_bounces, fovx, palette,
          NPAL, POBJ, WALLHI,
          eye_x, eye_y, eye_z, tgt_x, tgt_y, tgt_z,
          fwd_x, fwd_y, fwd_z, rgt_x, rgt_y, rgt_z, up_x, up_y, up_z,
          tan_x, tan_y,
          grid_setup, grid_w, grid_h, grid_sx, grid_sy,
          shit, scol, hits, obj_at, rays, render, perturb, clear_perturb,
          hit_obj, hit_t, hit_x, hit_y, hit_z,
          bounce_at, bounce_max, bounce_total, self_hits, GW, GH };