// bn.y -- arbitrary-precision signed integers over `long` limbs.
//
// SIGNED, BASE 2^28, LITTLE-ENDIAN.
//
// A bignum is a SLOT INDEX.  Its whole state lives in three module-level
// arrays, so no operation allocates:
//
//   L[s][i]   limb i, 0 <= L[s][i] < 2^28
//   NC[s]     number of significant limbs; 0 means the value is zero
//   NG[s]     1 iff the value is negative, always 0 when NC[s] == 0
//
// WHY 2^28 AND NOT 2^32.  Schoolbook multiplication needs `limb * limb +
// carry + accumulator`, and Y's `long` is a signed 64-bit integer, so the
// base is bounded by what one limb product costs:
//
//   base 2^32:  (2^32-1)^2 = 2^64 - 2^33 + 1  >  2^63-1   OVERFLOWS
//   base 2^31:  (2^31-1)^2 + 2*(2^31-1)      ~  2^62        fits, barely
//   base 2^28:  (2^28-1)^2 + 2*(2^28-1)      <  2^57        fits, 64x margin
//
// 2^28 is also the largest power of two that keeps division honest: Knuth's
// quotient estimate divides a two-limb numerator by a one-limb divisor, and
// two limbs is 2^56, comfortably inside a `long`. See README.md.

// ── configuration ──────────────────────────────────────────────────────────

let BITS = 28;                       // limbs are 28 bits
let BASE = 268435456;                // 2^28
let BMASK = 268435455;               // 2^28 - 1
let HSHA = 134217728;                // 2^27, the normalisation target
let NLIMB = 128;                     // 3584 bits: 1078 decimal digits
let SLIMB = NLIMB + 3;               // Knuth D wants n+2 scratch limbs
let NSLOT = 36;                      // S_A..S_I are 2..10; SL0..SL15 are 20..35

// INJECT -- the deliberate-defect knob.  It is 0 in every normal run, and
// `--inject N` on the command line sets it to N so `--check` can be shown to
// FAIL.  A golden file cannot do that: it records whatever the broken build
// printed.  Each injection is one number; see the INJECTION table in
// README.md for what each one breaks and which check catches it.  Every site
// below is a real bug this library actually had while being written -- none
// of them is a synthetic "if (INJ == 7) return 1" that proves nothing.
let INJECT: long = 0;

let L: [ [long] ] = [];
let NC: [long] = [];
let NG: [long] = [];

// The user-visible slots.  The algorithm scratch is SL0..SL11 and is only
// ever touched by the routines that own it.
let S_ZERO = 0;
let S_ONE = 1;
let S_A = 2;
let S_B = 3;
let S_C = 4;
let S_D = 5;
let S_E = 6;
let S_F = 7;
let S_G = 8;
let S_H = 9;
let SL0 = 20;
let SL1 = 21;
let SL2 = 22;
let SL3 = 23;
let SL4 = 24;
let SL5 = 25;
let SL6 = 26;
let SL7 = 27;
let SL8 = 28;
let SL9 = 29;
let SL10 = 30;
let SL11 = 31;
let SL12 = 32;
let SL13 = 33;
let SL14 = 34;
let SL15 = 35;
let S_I = 10;
// S_TWO is 2, for the same reason S_ONE is 1: the API takes SLOT INDICES, so
// `bn_add(d, a, 2)` reads slot 2 -- which is S_A -- and silently doubles `a`
// instead of adding two.  That mistake cost this file one whole demo section.
let S_TWO = 11;
let S_J = 12;
// S_TEN is 10, for the check's "a * 10^k is k multiplications by ten".
let S_TEN = 13;
// SL2 is the throwaway remainder slot of bn_div/bn_mod; the rest are the
// algorithms' own.  NSLOT must cover SL11.

// ── pool ───────────────────────────────────────────────────────────────────
//
// Grown once, at startup, to exactly SLIMB limbs per slot.  After that no
// routine in this file allocates, which is what lets --check report a flat
// heap curve instead of an arena's worth of garbage.

def bn_init() -> long {
  let i = 0;
  while (i < NSLOT) {
    let a: [long] = [];
    let k = 0;
    while (k < SLIMB) { a += 0; k = k + 1 };
    L += a;
    NC += 0;
    NG += 0;
    i = i + 1
  };
  // S_ONE is the constant 1 and S_ZERO the constant 0, and they are used by
  // name all over the interface (`bn_sub(d, S_ZERO, a)`, every `+1`).  An
  // earlier version left every slot zeroed, so S_ONE was 0 -- and
  // `bn_add(d, a, S_ONE)` with a zero right operand took the
  // "if NC[b] == 0 then copy a" path and returned a unchanged.  Every
  // increment in the program was a no-op, silently.  It is idempotent, so
  // calling it twice is harmless.
  bn_stamp(S_ZERO, 0, 0);
  bn_stamp(S_ONE, 0, 1);
  L[S_ONE][0] = 1;
  bn_stamp(S_TWO, 0, 1);
  L[S_TWO][0] = 2;
  bn_stamp(S_TEN, 0, 1);
  L[S_TEN][0] = 10;
  return L.length
}

// ── primitive access ───────────────────────────────────────────────────────

def bn_n(s: long) -> long { NC[s] }
def bn_neg(s: long) -> long { NG[s] }
def bn_lim(s: long, i: long) -> long { L[s][i] }

def bn_is_zero(s: long) -> bool { NC[s] == 0 }

// RETURN CONVENTION, for the whole file: every routine that MUTATES a slot
// returns a status -- 0 for fine, 1 for division by zero, 2 for too wide --
// and NEVER the slot index.  An earlier mix of the two (bn_add returned its
// destination slot, bn_div returned a status) made `bn_str(bn_div(q, a, b))`
// compile, run, print "0" and exit 0: the status 0 was read as slot 0, which
// is S_ZERO.  It cost a whole demo section before it was spotted.  So: no
// mutator returns a slot, and `bn_str`/`bn_dec`/`bn_bits` take one.
def bn_stamp(s: long, sg: long, cnt: long) -> long {
  NC[s] = cnt;
  NG[s] = (cnt == 0) ? 0 : (sg == 1 ? 1 : 0);
  0
}

def bn_zero(s: long) -> long { bn_stamp(s, 0, 0) }

def bn_copy(d: long, s: long) -> long {
  let i = 0;
  while (i < NC[s]) { L[d][i] = L[s][i]; i = i + 1 };
  bn_stamp(d, NG[s], NC[s])
}

// bn_from_long(s, v) -- seed a slot from a native `long`.
//
// The one value that cannot be negated in a `long` is -2^63: 0 - v wraps back
// to -2^63, so a plain "m = 0 - v" reads a negative magnitude and every limb
// comes out wrong.  It is special-cased by its exact factorisation
// 2^63 = 128 * (2^28)^2, which is limbs [0, 0, 128].  An earlier version
// instead built the magnitude with `((0 - v) >>> 1) >>> 1`, which is wrong
// for every negative value, not just the extreme one -- -1 produced 0.
def bn_from_long(s: long, v: long) -> long {
  bn_zero(s);
  if (v == 0) { return 0 };
  let neg = v < 0;
  if (neg && (0 - v) < 0) {
    L[s][0] = 0;
    L[s][1] = 0;
    L[s][2] = 128;
    return bn_stamp(s, 1, 3)
  };
  let m = (INJECT == 4 && neg) ? (((0 - v) >>> 1) >>> 1) : (neg ? (0 - v) : v);
  let n = 0;
  let k = 0;
  // Every limb is WRITTEN, and `n` only counts up to the last nonzero one.
  // An earlier version skipped zero limbs without writing them, which slid
  // every higher limb down a place: 2^28 was stored as the single limb 1, so
  // dividing 1 by 2^28 answered 1 with remainder 0.
  if (INJECT == 5) {
    // the "skip a zero limb without writing it" bug: every higher limb
    // slides down a place, so 2^28 becomes the single limb 1
    let i = 0;
    while (k < NLIMB) {
      let d = m & BMASK;
      if (d != 0) { L[s][i] = d; i = i + 1 };
      m = m >>> BITS;
      k = k + 1
    };
    bn_stamp(s, (neg ? 1 : 0), i);
    return 0
  };
  while (k < NLIMB) {
    let d = m & BMASK;
    L[s][k] = d;
    if (d != 0) { n = k + 1 };
    m = m >>> BITS;
    k = k + 1
  };
  bn_stamp(s, (neg ? 1 : 0), n)
}

// bn_to_long(s) -> long -- exact only when bn_fits(s); the caller checks.
// bn_fits(s) -> bool -- does the value survive a round trip through a signed
// 64-bit `long`?  The accumulator runs from the TOP limb down, because limb 0
// is the least significant: v = v*BASE + limb read low-to-high computes
// limb0*BASE^(n-1) + ... and returns 1 for 2^28.
def bn_fits(s: long) -> bool {
  if (NC[s] > 3) { return false };
  // There is exactly one magnitude a signed long holds that a positive one
  // does not: 2^63, the magnitude of -2^63.  It is recognised by its limbs
  // rather than by a comparison, because 2^63 is not a `long` literal -- an
  // earlier version wrote the bound as `v <= 2^63-1` for the positive side
  // and `v <= 2^63-1` (written as 9223372036854775807 - 0) for the negative
  // one, which rejected every long from 2^63 down.
  if (NC[s] == 3 && L[s][0] == 0 && L[s][1] == 0 && L[s][2] == 128) {
    return NG[s] == 1
  };
  let v = 0;
  let i = NC[s] - 1;
  while (i >= 0) {
    // The guard is on the ACCUMULATOR, which is a prefix of the value, so the
    // bound is (2^63-1-(2^28-1))/2^28 = 2^35-1.  An earlier version guarded
    // at 2^30-1, which rejected every long past 2^58.
    if (v > 34359738367) { return false };
    v = v * BASE + L[s][i];
    i = i - 1
  };
  // The loop leaves v = |value| <= 2^63-1, and every long from -(2^63-1) to
  // +(2^63-1) is representable -- so at this point it fits, whatever the sign.
  true
}

// bn_to_long(s) -> long -- exact only when bn_fits(s); the caller checks.
def bn_to_long(s: long) -> long {
  let v = 0;
  let i = NC[s] - 1;
  while (i >= 0) { v = v * BASE + L[s][i]; i = i - 1 };
  NG[s] == 1 ? (0 - v) : v
}

def bn_to_long_checked(s: long, ok: long) -> long {
  // Two out-params would be noise in Y; this writes the value and returns 1
  // when it does not fit, leaving the caller to report it.
  if (bn_fits(s)) { return 0 };
  ok
}

// bn_bits(s) -> long -- how many bits the magnitude occupies.
def bn_bits(s: long) -> long {
  if (NC[s] == 0) { return 0 };
  let top = L[s][NC[s] - 1];
  let b = 0;
  while (top != 0) { b = b + 1; top = top >> 1 };
  (NC[s] - 1) * BITS + b
}

// bn_digits(s) -> long -- the decimal digit count of the magnitude.
//
// There is no `break` and no `log10` here (there are no math functions at
// all), so this walks the bound down with a positive condition.  The start
// is a strict upper bound: digits <= floor(b*log10(2)) + 1 and log10(2) is
// 0.30103, so (b*302)/1000 + 1 over-counts rather than under-counts -- an
// over-count would only mean one wasted division.
def bn_digits(s: long) -> long {
  if (NC[s] == 0) { return 1 };
  let d = (bn_bits(s) * 302) / 1000 + 1;
  let again = d > 1;
  while (again) {
    // p = 10^d, one decimal digit at a time.  10^1081 overflows a long long
    // before d can matter here: d <= 1081 but b <= 3584 bounds d at 1081,
    // and the loop stops as soon as 10^d exceeds the value, which for any
    // real value happens far below that.  The cap keeps it defined anyway.
    if (d > 18) { again = false }
    else {
      let p = 1;
      let i = 0;
      while (i < d) { p = p * 10; i = i + 1 };
      if (bn_cmp_mag_long(s, p) >= 0) { again = false } else { d = d - 1 }
    }
  };
  d
}

// ── comparison ─────────────────────────────────────────────────────────────
//
// Every comparison is done on magnitudes first and only then on signs, so
// there is no way for a zero to acquire a negative sign by accident.

// cmp_mag(a, b) -> long -- -1, 0, 1, comparing |a| with |b|.
def bn_cmp_mag(a: long, b: long) -> long {
  if (NC[a] != NC[b]) { return NC[a] < NC[b] ? 0 - 1 : 1 };
  let i = NC[a] - 1;
  let go = true;
  let r = 0;
  while (go && i >= 0) {
    if (L[a][i] != L[b][i]) {
      r = L[a][i] < L[b][i] ? 0 - 1 : 1;
      go = false
    } else { i = i - 1 }
  };
  r
}

// bn_cmp(a, b) -> long -- -1, 0, 1, signed comparison.
def bn_cmp(a: long, b: long) -> long {
  if (NC[a] == 0 && NC[b] == 0) { return 0 };
  if (INJECT == 12) { return bn_cmp_mag(a, b) };
  if (NG[a] != NG[b]) { return NG[a] == 1 ? 0 - 1 : 1 };
  let m = bn_cmp_mag(a, b);
  NG[a] == 1 ? (0 - m) : m
}

// bn_cmp_mag_long(a, v) -> long -- |a| against a native `long`, v >= 0.
def bn_cmp_mag_long(a: long, v: long) -> long {
  if (v < 0) { return 1 };
  let b = S_ONE;
  bn_from_long(b, v);
  bn_cmp_mag(a, b)
}

def bn_eq(a: long, b: long) -> bool { bn_cmp(a, b) == 0 }

// ── add and subtract ───────────────────────────────────────────────────────
//
// Magnitude first, then the sign.  That is more code than the signed form
// but it cannot go wrong in the one place signed code always goes wrong: a
// zero result must come out non-negative.

// mag_add(d, a, b) -> long -- |d| = |a| + |b|, no sign set.  d may alias
// either operand (the loop reads each limb before writing it).
def mag_add(d: long, a: long, b: long) -> long {
  let n = NC[a];
  if (NC[b] > n) { n = NC[b] };
  let c = 0;
  let i = 0;
  while (i < n) {
    let t = c;
    if (i < NC[a]) { t += L[a][i] };
    if (i < NC[b]) { t += L[b][i] };
    L[d][i] = t & BMASK;
    c = t >>> BITS;
    i = i + 1
  };
  let nc = n;
  if (c != 0) { L[d][n] = c; nc = n + 1 };
  bn_stamp(d, 0, nc)
}

// mag_sub(d, a, b) -> long -- |d| = |a| - |b|, REQUIRES |a| >= |b|.
def mag_sub(d: long, a: long, b: long) -> long {
  let c = 0;
  let k = 0;
  while (k < NC[a]) {
    let t = L[a][k] - c;
    if (k < NC[b]) { t -= L[b][k] };
    if (t < 0) { t += BASE; c = (INJECT == 1 ? 0 : 1) } else { c = 0 };
    L[d][k] = t;
    k = k + 1
  };
  // Drop the leading zero limbs; NC is what `is zero` is asked, so a stale
  // high limb would make 0 - 0 look like a huge number.
  let n = NC[a];
  while (n > 0 && L[d][n - 1] == 0) { n = n - 1 };
  bn_stamp(d, 0, n)
}

def bn_add_s(d: long, a: long, b: long, sa: long, sb: long) -> long {
  // The short circuits must stamp the CALLER's sign, not the stored one:
  // `bn_sub(d, S_ZERO, a)` is 0 - a with sb = flip(NG[a]), and copying b
  // without re-stamping returned -x as +x.  That made -(2^1000) print as
  // 2^1000, and it made bn_abs(x, x) on a negative x return x unchanged.
  if (NC[a] == 0) { bn_copy(d, b); return bn_stamp(d, sb, NC[d]) };
  if (NC[b] == 0) { bn_copy(d, a); return bn_stamp(d, sa, NC[d]) };
  if (sa == sb) {
    mag_add(d, a, b);
    bn_stamp(d, sa, NC[d])
  } else {
    let m = bn_cmp_mag(a, b);
    if (m == 0) { return bn_zero(d) };
    if (m > 0) { mag_sub(d, a, b); bn_stamp(d, sa, NC[d]) }
    else { mag_sub(d, b, a); bn_stamp(d, sb, NC[d]) }
  };
  0
}

def bn_add(d: long, a: long, b: long) -> long { bn_add_s(d, a, b, NG[a], NG[b]) }

// bn_sub flips the sign of its SECOND operand.  It does that by passing the
// flipped sign down rather than by editing the operand: an earlier version
// toggled NG[b] and toggled it back, which is shorter and quietly wrong the
// moment anything reads b in between.
def bn_sub(d: long, a: long, b: long) -> long { bn_add_s(d, a, b, NG[a], (NG[b] == 1 ? 0 : 1)) }

// ── multiply ───────────────────────────────────────────────────────────────
//
// Schoolbook, one row of the product matrix at a time.
//
// The bound that makes base 2^28 legal lives here: the accumulator never
// exceeds (2^28-1)^2 + 2*(2^28-1) < 2^57, so nothing wraps a signed 64-bit
// `long`.  With a 2^32 base the same line would reach 2^64 and wrap SILENTLY
// -- no trap, just a wrong product.  See README.md.
def mag_mul(d: long, a: long, b: long) -> long {
  let an = NC[a];
  let bn = NC[b];
  if (an == 0 || bn == 0) { return bn_zero(d) };
  // A product of an n-limb and a m-limb value needs n+m limbs and a slot
  // holds exactly SLIMB of them, so this is the ONE bound that keeps the
  // write loop below inside the array.  Without it `bignum pow 2 3644` wrote
  // limb 131 of a 131-limb slot and trapped with "index out of bounds" --
  // on STDOUT, where it spliced itself into the output and exited 1, which
  // is the worst possible shape for a program whose output is a golden file.
  // Status 2 is "too wide", the same status bn_shl already returns, and
  // `bignum pow` already has a message for it.  It is unreachable from every
  // other call site: the widest product anywhere else in the program is
  // a 78-digit times a 78-digit in group (C), 20 limbs of 131.
  if (an + bn > SLIMB) { return 2 };
  // d is allowed to be either operand -- `bn_mul(c, a, b)` is the natural
  // way to write an accumulator loop, and an early version zeroed the result
  // limbs in place and so destroyed b when d == b and silently returned 0.
  // The two operands are therefore staged through the scratch slots.  They
  // cost two memcpys and make every call site alias-safe.
  let pa = SL0;
  let pb = SL1;
  bn_copy(pa, a);
  if (INJECT != 6) { bn_copy(pb, b) };
  let i = 0;
  while (i < an + bn) { L[d][i] = 0; i = i + 1 };
  let r = 0;
  while (r < an) {
    let av = L[pa][r];
    let c = 0;
    let j = 0;
    while (j < bn) {
      let t = av * L[pb][j] + L[d][r + j] + c;
      L[d][r + j] = t & BMASK;
      c = t >>> BITS;
      j = j + 1
    };
    L[d][r + bn] = (INJECT == 2) ? 0 : c;
    r = r + 1
  };
  let n = an + bn;
  while (n > 0 && L[d][n - 1] == 0) { n = n - 1 };
  bn_stamp(d, 0, n)
}

def bn_mul(d: long, a: long, b: long) -> long {
  // The operand signs are read BEFORE mag_mul, not after.  mag_mul finishes
  // with bn_stamp(d, 0, n) -- it writes magnitudes -- so if d aliases an
  // operand the sign it needs has already been cleared: `bn_mul(c, c, x)`
  // with c negative read NG[c] == 0 against NG[x] == 1 and concluded the
  // product was negative.  (-1) * (-1) came back as -1.
  let sa = NG[a];
  let sb = NG[b];
  let rc = mag_mul(d, a, b);
  // status 2 (too wide) is PASSED ON, not swallowed: it is the only way a
  // multiply can fail now, and bn_pow -- the one caller that can reach it --
  // has to be able to report it instead of writing past the end of a slot.
  // The destination is zeroed first, so a caller that ignores the status sees
  // a defined 0 rather than the tail of whatever was in the slot.
  if (rc != 0) { bn_zero(d); return rc };
  if (NC[d] == 0) { bn_stamp(d, 0, 0); return 0 };
  bn_stamp(d, (sa == sb ? 0 : 1), NC[d])
}

// ── shifts ─────────────────────────────────────────────────────────────────
//
// RETURN 0 on success, 2 if the result would not fit in NLIMB limbs.  A
// shift is the one operation whose size is chosen by the caller, so it is
// the one place the library has to be told "no" instead of trapping.

def bn_shl(d: long, a: long, k: long) -> long {
  if (NC[a] == 0) { bn_zero(d); return 0 };
  let limbs = k / BITS;
  let bits = k % BITS;
  if (NC[a] + limbs >= NLIMB + 1) { return 2 };
  let n = NC[a];
  let lowbits = (1 << bits) - 1;
  // Limb i of the result is (a[i] << bits) | (a[i+1] >> (BITS - bits)): the
  // limb above donates its LOW bits, which land in this limb's high bits.
  // The last two lines put the bits that fell off the top back on as a new
  // top limb.  The two bugs this shape is here to avoid, both of which look
  // right for a single-limb operand: OR-ing the carry into the BOTTOM of the
  // limb instead of using a[i+1] >> (BITS-bits) (so 2*2^27+1 came back a
  // hundred million times too big), and forgetting the top spill.
  let i = n - 1;
  let done = false;
  while (!done && i >= 0) {
    let v = L[a][i] << bits;
    if (INJECT == 7) { if (bits != 0 && i > 0) { v += (L[a][i - 1] & lowbits) } }
    else if (bits != 0 && i > 0) { v += L[a][i - 1] >> (BITS - bits) };
    L[d][i + limbs] = v & BMASK;
    i = i - 1
  };
  let top = (bits == 0) ? 0 : (L[a][n - 1] >> (BITS - bits));
  let total = n + limbs;
  if (top != 0) { L[d][total] = top; total = total + 1 };
  let i2 = 0;
  while (i2 < limbs) { L[d][i2] = 0; i2 = i2 + 1 };
  bn_stamp(d, NG[a], total);
  0
}

// bn_shr(d, a, k) -> long -- |d| = floor(|a| / 2^k), the magnitude only; the
// sign is NOT carried, because every caller here shifts a magnitude.
def bn_shr(d: long, a: long, k: long) -> long {
  let limbs = k / BITS;
  let bits = k % BITS;
  if (limbs >= NC[a]) { return bn_zero(d) };
  let n = NC[a] - limbs;
  let i = 0;
  while (i < n) {
    let v = L[a][i + limbs] >> bits;
    if (bits != 0 && i + limbs + 1 < NC[a]) { v += (L[a][i + limbs + 1] << (BITS - bits)) & BMASK };
    L[d][i] = v & BMASK;
    i = i + 1
  };
  let m = n;
  while (m > 0 && L[d][m - 1] == 0) { m = m - 1 };
  bn_stamp(d, 0, m)
}

// ── divide ─────────────────────────────────────────────────────────────────
//
// Knuth Algorithm D (TAOCP vol. 2 4.3.1), schoolbook.  It is the only part of
// this file where a wrong answer could be silent rather than obvious, because
// the intermediate is a two-limb numerator:
//
//   num  = u[j+n]*BASE + u[j+n-1]              <  2^56
//   qhat = num / v[n-1]      v[n-1] >= 2^27 after the normalisation shift
//   rem  = num - qhat*v[n-1]                    <  BASE
//   (qhat+1)*v[n-2] <= rem*BASE + u[j+n-2]     both sides < 2^56
//
// Every one of those fits a signed 64-bit `long`.  The normalisation --
// shifting BOTH operands left until the divisor's top limb reaches 2^27 --
// is what makes qhat within 2 of exact, and that is what bounds the give-one-
// limb-back correction below to a single attempt.
//
// SIGN.  Y's `long` division truncates toward zero and `%` takes the sign of
// the dividend.  That is measured, not assumed: --check compares bignum
// a/b and a%b against the native `long` operations for every sign
// combination, and they must agree bit for bit.  So the quotient flips with
// XOR of the signs and the remainder keeps the DIVIDEND's sign, and
// `a == (a/b)*b + a%b` holds for all four sign combinations.  Making the
// remainder follow the divisor instead is the classic way to be wrong by a
// whole multiple of the divisor, and only a %= b identity would catch it.
//
// RETURN.  0 = fine, 1 = division by zero, 2 = the quotient would need more
// than NLIMB limbs.  Both non-zero cases are REPORTED, never trapped: a Y
// runtime trap prints to stdout, so it would splice itself into the golden
// diff rather than announce itself.

def bn_divmod(q: long, r: long, a: long, b: long) -> long {
  let sa = NG[a];
  let sb = NG[b];
  // The outputs may alias the inputs, and `bn_mod(x, x, n)` -- reduce in
  // place -- is the natural way to write most of this file's call sites.  So
  // when they do, both inputs are staged into scratch slots first.  An
  // earlier version opened with `bn_zero(q); bn_zero(r)`, which destroys the
  // dividend whenever r == a: every in-place reduction in the program then
  // returned 0, and 2 mod n came back as 0 for every n.
  let A = a;
  let B = b;
  let staged = (q == a) || (q == b) || (r == a) || (r == b);
  if (staged) {
    A = SL14;
    B = SL15;
    bn_copy(A, a);
    bn_copy(B, b);
    NG[A] = 0;
    NG[B] = 0
  };
  bn_zero(q);
  bn_zero(r);
  if (NC[B] == 0) { return 1 };
  if (bn_cmp_mag(A, B) < 0) {
    bn_copy(r, A);
    NG[r] = sa;
    return 0
  };
  let n = NC[B];
  if (n == 1) {
    let rc = divmod_small(q, r, A, L[B][0]);
    // signs: quotient XOR, remainder follows the dividend
    bn_stamp(q, (sa == sb ? 0 : 1), NC[q]);
    bn_stamp(r, sa, NC[r]);
    return rc
  };
  let m = NC[A] - n;
  if (m >= NLIMB) { return 2 };

  // s: how far the divisor's top limb is below 2^27.
  let s = 0;
  let top = L[B][n - 1];
  let find = top < HSHA;
  while (find) { top = top << 1; s = s + 1; find = top < HSHA };

  let u = SL0;                      // |a| * 2^s, exactly n+m+1 limbs
  let v = SL1;                      // |b| * 2^s, exactly n limbs
  bn_shl(u, A, s);
  bn_shl(v, B, s);
  // A left shift only adds a limb when bits spill out of the top, so pin the
  // dividend to n+m+1 limbs: the loop below reads u[j+n] at j = m, i.e.
  // u[NC[a]], which exists as a real zero only when no bit spilled.
  let un = NC[A] + 1;
  let pad = NC[u];
  while (pad < un) { L[u][pad] = 0; pad = pad + 1 };
  NC[u] = un;
  NG[u] = 0;

  let j = m;
  let jdone = false;
  while (!jdone && j >= 0) {
    // -- the estimate, then the correction.
    //
    // The correction tests the WHOLE trial product, top limb against the
    // top two numerator limbs:
    //
    //     (qh+1)*v[n-1]  <=  rem*BASE + u[j+n-2]
    //
    // and it decrements `rem` by v[n-1], not v[n-2].  The textbook form that
    // compares v[n-2] against u[j+n-2] and adds v[n-2] to the remainder is
    // the one to be careful with: when v[n-2] is 0 -- 2^55 / 2^55, or any
    // power-of-two divisor -- its loop condition is 0 <= anything, `rem` never
    // moves, and the loop spins for ever.  Subtracting v[n-1] makes `rem`
    // negative on the first correction, so the loop is bounded by Theorem B's
    // "at most 2", and the `qh < BASE-1` guard bounds it even if that were
    // not true.
    let num = L[u][j + n] * BASE + L[u][j + n - 1];
    let qh = num / L[v][n - 1];
    let cl = (INJECT == 13) ? BASE - 2 : BASE - 1;
    if (qh >= cl) { qh = cl };
    let rem = num - qh * L[v][n - 1];
    let adjust = (qh < cl) && INJECT != 9;
    while (adjust) {
      let rest = rem * BASE + L[u][j + n - 2];
      if ((qh + 1) * L[v][n - 1] > rest) { adjust = false }
      else {
        qh = qh + 1;
        rem = rem - L[v][n - 1];
        adjust = qh < BASE - 1
      }
    };

    // -- multiply and subtract.  `owed` is what u still owes after this row
    //    and is at most BASE, so each subtraction below is exact.
    let carry = 0;
    let borrow = 0;
    let i = 0;
    while (i < n) {
      let p = qh * L[v][i] + carry;
      let lo = p & BMASK;
      carry = p >>> BITS;
      let t = L[u][j + i] - lo - borrow;
      let nb = 0;
      if (t < 0) { t = t + BASE; nb = 1 };
      L[u][j + i] = t;
      borrow = nb;
      i = i + 1
    };
    let owed = carry + borrow;
    let left = L[u][j + n] - owed;
    if (left >= 0 || INJECT == 8) {
      L[u][j + n] = (left >= 0 ? left : 0)
    } else {
      // -- the estimate was one too big: give the divisor back, once.
      qh = qh - 1;
      let c = 0;
      let i2 = 0;
      while (i2 < n) {
        let s2 = L[u][j + i2] + L[v][i2] + c;
        if (s2 >= BASE) { L[u][j + i2] = s2 - BASE; c = 1 }
        else { L[u][j + i2] = s2; c = 0 };
        i2 = i2 + 1
      };
      L[u][j + n] = L[u][j + n] - owed + c
    };
    L[q][j] = qh;
    j = j - 1
  };
  let qn = m + 1;
  while (qn > 0 && L[q][qn - 1] == 0) { qn = qn - 1 };
  NC[q] = qn;
  NG[q] = 0;
  let rn = n;
  while (rn > 0 && L[u][rn - 1] == 0) { rn = rn - 1 };
  NC[u] = rn;
  bn_shr(r, u, s);

  // -- signs: truncate toward zero, remainder follows the dividend
  NC[q] = qn;
  NG[q] = (sa == sb ? 0 : 1);
  NG[r] = (INJECT == 3) ? sb : sa;
  if (NC[r] == 0) { NG[r] = 0 };
  0
}

// divmod_small(q, r, a, d) -> long -- the one-limb divisor, which needs no
// normalisation and no give-back: num = rem*BASE + limb < BASE^2 = 2^56.
def divmod_small(q: long, r: long, a: long, d: long) -> long {
  let rem = 0;
  let i = NC[a] - 1;
  let done = false;
  while (!done && i >= 0) {
    let num = rem * BASE + L[a][i];
    L[q][i] = num / d;
    rem = num % d;
    i = i - 1
  };
  let qn = NC[a];
  while (qn > 0 && L[q][qn - 1] == 0) { qn = qn - 1 };
  NC[q] = qn;
  NC[r] = 0;
  if (rem != 0) { L[r][0] = rem; NC[r] = 1 };
  0
}

// TEMPORARY (search only, deleted afterwards): bn_divmod with the
// quotient-estimate correction loop removed, so a scan can find an operand pair
// where that loop is load-bearing.  Not part of the library.
def bn_divmod_uc(q: long, r: long, a: long, b: long) -> long {
  let sa = NG[a];
  let sb = NG[b];
  let A = a;
  let B = b;
  let staged = (q == a) || (q == b) || (r == a) || (r == b);
  if (staged) {
    A = SL14;
    B = SL15;
    bn_copy(A, a);
    bn_copy(B, b);
    NG[A] = 0;
    NG[B] = 0
  };
  bn_zero(q);
  bn_zero(r);
  if (NC[B] == 0) { return 1 };
  if (bn_cmp_mag(A, B) < 0) { bn_copy(r, A); NG[r] = sa; return 0 };
  let n = NC[B];
  if (n == 1) {
    let rc = divmod_small(q, r, A, L[B][0]);
    bn_stamp(q, (sa == sb ? 0 : 1), NC[q]);
    bn_stamp(r, sa, NC[r]);
    return rc
  };
  let m = NC[A] - n;
  let s = 0;
  let top = L[B][n - 1];
  let find = top < HSHA;
  while (find) { top = top << 1; s = s + 1; find = top < HSHA };
  let u = SL0;
  let v = SL1;
  bn_shl(u, A, s);
  bn_shl(v, B, s);
  let un = NC[A] + 1;
  let pad = NC[u];
  while (pad < un) { L[u][pad] = 0; pad = pad + 1 };
  NC[u] = un;
  NG[u] = 0;
  let j = m;
  let jdone = false;
  while (!jdone && j >= 0) {
    let num = L[u][j + n] * BASE + L[u][j + n - 1];
    let qh = num / L[v][n - 1];
    if (qh >= BASE) { qh = BASE - 1 };
    let carry = 0;
    let borrow = 0;
    let i = 0;
    while (i < n) {
      let p = qh * L[v][i] + carry;
      let lo = p & BMASK;
      carry = p >>> BITS;
      let t = L[u][j + i] - lo - borrow;
      let nb = 0;
      if (t < 0) { t = t + BASE; nb = 1 };
      L[u][j + i] = t;
      borrow = nb;
      i = i + 1
    };
    let owed = carry + borrow;
    let left = L[u][j + n] - owed;
    if (left >= 0) {
      L[u][j + n] = left
    } else {
      qh = qh - 1;
      let c = 0;
      let i2 = 0;
      while (i2 < n) {
        let s2 = L[u][j + i2] + L[v][i2] + c;
        if (s2 >= BASE) { L[u][j + i2] = s2 - BASE; c = 1 }
        else { L[u][j + i2] = s2; c = 0 };
        i2 = i2 + 1
      };
      L[u][j + n] = L[u][j + n] - owed + c
    };
    L[q][j] = qh;
    j = j - 1
  };
  let qn = m + 1;
  while (qn > 0 && L[q][qn - 1] == 0) { qn = qn - 1 };
  NC[q] = qn;
  NG[q] = (sa == sb ? 0 : 1);
  let rn = n;
  while (rn > 0 && L[u][rn - 1] == 0) { rn = rn - 1 };
  NC[u] = rn;
  bn_shr(r, u, s);
  NG[r] = sa;
  if (NC[r] == 0) { NG[r] = 0 };
  0
}

def bn_div(q: long, a: long, b: long) -> long { bn_divmod(q, SL2, a, b) }
def bn_mod(r: long, a: long, b: long) -> long { bn_divmod(SL2, r, a, b) }

// div_small(a, d) -> long -- a = a / d in place, returns the old a % d.
def div_small(a: long, d: long) -> long {
  let rem = 0;
  let i = NC[a] - 1;
  let done = false;
  while (!done && i >= 0) {
    let num = rem * BASE + L[a][i];
    L[a][i] = num / d;
    rem = num % d;
    i = i - 1
  };
  let n = NC[a];
  while (n > 0 && L[a][n - 1] == 0) { n = n - 1 };
  NC[a] = n;
  rem
}

// mul_small_add(a, m, add) -> long -- a = a*m + add in place; 1 on overflow.
// a*m < 2^28 * 10^7 < 2^52 and the carry stays below m, so exact in a long.
def mul_small_add(a: long, m: long, add: long) -> long {
  let n = NC[a];
  let i = 0;
  while (i < n) { L[a][i] = L[a][i] * m; i = i + 1 };
  let c = add;
  let j = 0;
  while (j < n || c != 0) {
    if (j >= n) {
      if (n >= NLIMB) { return 1 };
      L[a][n] = 0;
      n = n + 1
    };
    let t = L[a][j] + c;
    L[a][j] = t & BMASK;
    c = t >>> BITS;
    j = j + 1
  };
  let m2 = n;
  while (m2 > 0 && L[a][m2 - 1] == 0) { m2 = m2 - 1 };
  NC[a] = m2;
  0
}

// ── decimal ────────────────────────────────────────────────────────────────
//
// 10^7 is the largest power of ten below the 2^28 limb base, so one
// conversion round is a single-limb division in and a single-limb multiply
// out, and both are exact in `long`.

let CHUNK = 10000000;
let CHUNK_DIGITS = 7;
let DECBUF: [byte; 1300] = [0; 1300];

// to_dec(a, buf, cap) -> long -- the decimal digits of a, LSB FIRST, into
// buf.  Returns the digit count, or -1 if the buffer is too small.  No `str`
// is built and nothing is allocated, which is what lets --check convert tens
// of thousands of values without moving the heap.
def to_dec(a: long, cap: long) -> long {
  if (NC[a] == 0) {
    if (cap < 1) { return 0 - 1 };
    DECBUF[0] = 48;
    return 1
  };
  let w = SL3;                        // the shrinking copy of |a|
  bn_copy(w, a);
  NG[w] = 0;
  let got = 0;
  let room = true;
  // Digits come out LSB first, seven per division by 10^7.  Every chunk but
  // the last is EXACTLY seven digits wide, zeros included -- those zeros are
  // real digits in the middle of the number.  Only the most significant
  // chunk is variable width, because only there a leading zero is padding.
  // Zero-padding every chunk (an earlier version's mistake) prints
  // 1000000*1000000 as "10", and suppressing every chunk's padding prints it
  // as "1".  Either way the two mistakes cancel on some inputs, which is why
  // --check compares the digit COUNT as well as the text.
  let more = true;
  while (more) {
    let rem = div_small(w, CHUNK);
    if (NC[w] == 0) {
      if (rem == 0 && got == 0) {
        if (got < cap) { DECBUF[got] = 48; got = got + 1 } else { room = false }
      };
      let again = rem != 0;
      while (again) {
        let dg = rem % 10;
        rem = rem / 10;
        again = rem != 0;
        if (got < cap) { DECBUF[got] = 48 + dg; got = got + 1 }
        else { room = false }
      };
      // the bug this shape really had: pad the most significant chunk out to
      // seven digits as well, so 1000000*1000000 prints as "01000000"
      let pad = CHUNK_DIGITS;
      while (INJECT == 10 && pad > 0) {
        pad = pad - 1;
        if (got < cap) { DECBUF[got] = 48; got = got + 1 }
        else { room = false }
      };
      more = false
    } else {
      let k = 0;
      while (k < CHUNK_DIGITS || (INJECT == 10 && rem != 0)) {
        let dg = rem % 10;
        rem = rem / 10;
        k = k + 1;
        if (got < cap) { DECBUF[got] = 48 + dg; got = got + 1 }
        else { room = false }
      };
      more = true
    }
  };
  if (!room) { return 0 - 1 };
  got
}

// bn_dec(a) -> long -- the decimal length of a, from to_dec itself, so this
// can never disagree with what to_dec prints.
def bn_dec(a: long) -> long {
  let n = to_dec(a, 1300);
  n
}

// bn_eq(a, b) -> long -- 1 if the two slots hold the same value, 0 if not.
// Sign then limb count then limbs, high to low; no allocation, no `str`.
def bn_eq(a: long, b: long) -> long {
  if (NG[a] != NG[b]) { return 0 };
  if (NC[a] != NC[b]) { return 0 };
  let i = NC[a] - 1;
  while (i >= 0) {
    if (L[a][i] != L[b][i]) { return 0 };
    i = i - 1
  };
  1
}

// bn_eq_dec(a, want) -> long -- 1 if a equals this decimal text, 0 if not,
// -1 if `want` is empty.  It compares DIGITS, both sides least-significant
// first, so an equality test allocates nothing at all.  That matters here:
// the property battery runs seventeen thousand comparisons, and building a
// `str` for each one put 23 MB on a heap that never gives anything back.
//
// The length is checked against `to_dec`'s own digit count BEFORE any digit
// is compared.  That is the presence check: an empty `want` is REFUSED with
// -1 rather than compared, because "" == "" is true and is exactly the
// vacuous pass this example is supposed to be immune to.
def bn_eq_dec(a: long, want: str) -> long {
  let n = want.length;
  if (n == 0) { return 0 - 1 };
  let k = 0;
  if (want[0] == 45) {
    if (NG[a] != 1) { return 0 };
    k = 1
  } else {
    if (NG[a] == 1) { return 0 }
  };
  let d = to_dec(a, 1300);
  if (d < 0) { return 0 };
  if (n - k != d) { return 0 };
  let i = 0;
  let same = 1;
  while (i < d) {
    if (DECBUF[i] + 0 != want[n - 1 - i] + 0) { same = 0; i = d }
    else { i = i + 1 }
  };
  same
}

// bn_str(a) -> str -- the decimal text of a, MSB first.  to_dec fills the
// module-level DECBUF LSB first, which is the order the chunking loop wants,
// so this reads it backwards and appends digit by digit.  (Reversing the
// buffer first and then reading it backwards, which is what an earlier
// version did, prints every number with its digits mirrored -- and the
// product below came out as "00000010".)
def bn_str(a: long) -> str {
  let n = to_dec(a, 1300);
  if (n < 0) { return "<too wide>" };
  let out = "";
  if (NG[a] == 1 && NC[a] > 0) { out = "-" };
  let k = n - 1;
  while (k >= 0) { out += chr(DECBUF[k]); k = k - 1 };
  out
}

// from_dec(d, text) -> long -- 0 = fine, 1 = not a decimal integer,
// 2 = more than NLIMB limbs.  The scan is strict on purpose: "12x", " 12",
// "1_0", "--3" and "" are errors rather than silent truncations.
def from_dec(d: long, text: str) -> long {
  bn_zero(d);
  let len = text.length;
  if (len == 0) { return 1 };
  let sgn = 0;
  let i = 0;
  if (text[0] == 45) { sgn = 1; i = 1 };
  let ndig = len - i;
  if (ndig == 0) { return 1 };
  let k = 0;
  let any = 0;
  while (k < ndig) {
    let c = text[i + k] + 0;
    if (c < 48 || c > 57) { return 1 };
    any = 1;
    k = k + 1
  };
  if (any == 0) { return 1 };
  // 7 digits per round: the exact inverse of to_dec.  `go` is RECOMPUTED at
  // the bottom of the loop -- hoisting it out (an earlier version did) runs
  // the loop past the end of the text and traps on `text[i + pos + t]`,
  // because the first chunk is ndig % 7 digits and only the rest are full.
  let first = ndig % CHUNK_DIGITS;
  let pos = 0;
  let over = false;
  let go = true;
  while (go) {
    let take = CHUNK_DIGITS;
    if (pos == 0 && first != 0) { take = first };
    let v = 0;
    let t = 0;
    while (t < take) {
      v = v * 10 + ((text[i + pos + t] + 0) - 48);
      t = t + 1
    };
    if (mul_small_add(d, CHUNK, v) != 0) { over = true };
    pos = pos + take;
    go = (pos < ndig) && !over
  };
  if (over) { return 2 };
  NG[d] = (NC[d] == 0 ? 0 : (INJECT == 11 ? 0 : sgn));
  0
}

// bn_abs(d, a) -> long -- |a|.  The staging slot matters: for a negative `a`
// this is 0 - a, and 0 - a is `bn_add_s(d, S_ZERO, a, ...)` whose short
// circuit would otherwise read `a` while writing `d`.
def bn_abs(d: long, a: long) -> long {
  if (NG[a] == 0) { return bn_copy(d, a) };
  if (d == a) { bn_copy(SL13, a); return bn_sub(d, S_ZERO, SL13) };
  bn_sub(d, S_ZERO, a)
}

// bn_pow(d, base, e) -> long -- base^e, exact, no modulus.  e must be
// non-negative.  Used by the check to build 10^k without trusting bn_powmod.
//
// It also returns 2 when the result cannot fit a slot, which is the only
// documented use of that status here and the only reason this loop has to
// look at what bn_mul returns.  `bignum pow` already prints a message for a
// non-zero status, so the refusal costs one line at the call site instead of
// a trap that would land on stdout in the middle of a golden diff.
def bn_pow(d: long, base: long, e: long) -> long {
  bn_from_long(d, 1);
  let acc = SL12;
  bn_copy(acc, base);
  let k = e;
  let go = k > 0;
  while (go) {
    if (k % 2 == 1) {
      let rc = bn_mul(d, d, acc);
      if (rc != 0) { return rc }
    };
    k = k / 2;
    go = k > 0;
    if (go) {
      let rc2 = bn_mul(acc, acc, acc);
      if (rc2 != 0) { return rc2 }
    }
  };
  0
}

// ── gcd, powmod, and the small helpers the demo is built on ───────────────
//
// These are here because the example has to PUT THE LIBRARY TO WORK on
// something a native `long` cannot do, and trial division, Pollard rho and
// Fermat/Miller-Rabin all need them.

// bn_gcd(d, a, b) -> long -- Euclid, magnitudes only.  Returns 1 (never 0),
// so a caller can test the result without a zero special case.
// bn_gcd(d, a, b) -> long -- Euclid on the magnitudes.  Returns 0, or 1 if
// `b` is zero, so a caller can test without a special case.
//
// `go` is RECOMPUTED at the bottom of the loop.  Hoisting it out is the
// third instance of the same bug in this file (the other two are in
// `from_dec` and in the previous version of this loop): Euclid's last step
// leaves y == 0, and a guard read before the loop then divides by zero, so
// `bn_gcd` of a pair that shares no factor returned 1 instead of 1-the-value.
def bn_gcd(d: long, a: long, b: long) -> long {
  let x = SL4;
  let y = SL5;
  bn_copy(x, a);
  bn_copy(y, b);
  NG[x] = 0;
  NG[y] = 0;
  let go = NC[y] != 0;
  let rc = 0;
  while (go) {
    rc = bn_divmod(SL6, SL7, x, y);
    if (rc != 0) { go = false }
    else {
      bn_copy(x, y);
      bn_copy(y, SL7);
      go = NC[y] != 0
    }
  };
  if (rc != 0) { return rc };
  bn_copy(d, x);
  0
}

// bn_powmod(d, base, e, m) -> long -- base^e mod m by square and multiply.
// Returns 0, or 1 if m is zero.  e must be non-negative.
//
// The slots are named for what they hold, because getting this wrong is
// invisible in a smoke test: an earlier version kept the quotient where the
// remainder belongs, so every modular exponentiation returned 0 -- including
// 2^(p-1) mod p, which must be 1.
def bn_powmod(d: long, base: long, e: long, m: long) -> long {
  if (NC[m] == 0) { return 1 };
  bn_copy(d, S_ONE);               // the result starts at 1
  let acc = SL9;                   // base^(2^i) mod m
  bn_copy(acc, base);
  bn_mod(acc, acc, m);
  let k = e;
  let go = k > 0;
  while (go) {
    if (k % 2 == 1) {
      bn_mul(SL10, d, acc);                  // the product
      let rc = bn_divmod(SL8, SL11, SL10, m);   // quotient, remainder
      if (rc != 0) { return rc };
      bn_copy(d, SL11)                       // the REMAINDER is the answer
    };
    k = k / 2;
    go = k > 0;
    if (go) {
      bn_mul(SL10, acc, acc);
      let rc2 = bn_divmod(SL8, SL11, SL10, m);
      if (rc2 != 0) { return rc2 };
      bn_copy(acc, SL11)
    }
  };
  0
}
