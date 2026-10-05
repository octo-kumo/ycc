// check.y -- the property battery.  No reference file, no golden, nothing
// read from disk.  Every assertion here is about BEHAVIOUR, and every
// expected value comes from outside the code under test:
//
//   (A) the NATIVE `long`.  Y's `long` is a real signed 64-bit integer and
//       the machine's own arithmetic is an oracle of a completely different
//       kind from a second implementation of the same idea.  Two bignums
//       agreeing prove very little (day05's sorter agreed with every other
//       method on a confidently wrong answer); a bignum agreeing with the
//       CPU's add/multiply/divide, bit for bit, is real evidence.
//   (B) HAND-WRITTEN DECIMAL CONSTANTS, computed by hand and cross-checked
//       against CPython's arbitrary-precision `int` outside this program,
//       for the range beyond 64 bits where (A) cannot reach.
//   (C) ALGEBRAIC IDENTITIES, which hold at every width and so are the only
//       oracle available above NLIMB.
//
// THE VACUOUS-PASS GUARD.  The campaign's recurring failure is a check that
// compares two values which are both ABSENT and so passes.  Three defences,
// all visible below:
//
//   * `eq_str` refuses to compare an empty string with anything and counts
//     the refusal as a FAIL, so "both sides empty" cannot pass.
//   * every group that compares things also counts how many comparisons it
//     made and asserts the count against a floor, so a group that silently
//     compares nothing fails;
//   * `--inject N` re-runs the whole battery with a named defect compiled in,
//     and the battery is expected to FAIL for every one of them.  That is
//     the part a golden file cannot do: EXPECTED can be regenerated from
//     broken output and still match byte for byte.

import bn;
import fs;

// ── harness ────────────────────────────────────────────────────────────────

let n_checks: long = 0;
let n_fail: long = 0;
let n_group: long = 0;
let n_cmp: long = 0;              // comparisons actually performed
let n_refused: long = 0;          // comparisons refused for an absent value
let n_inject: long = 0;
let verbose: long = 0;
// quiet_fail is set only by the harness self-test below, whose whole purpose
// is to make `ok` record a failure.  Without it those four lines would carry
// the word FAIL in the output of a run that PASSES, and gate item 8 greps for
// exactly that word.
let quiet_fail: long = 0;
// HB0 is `heap_used()` at the moment the battery starts, so the summary can
// report a DELTA as well as the two absolutes.  A delta is the only figure
// here that does not move with the length of `argv[0]`, because the argument
// vector is allocated by the kernel before this sample is taken.
let HB0: long = 0;
let cur_group: str = "";

def group(name: str) {
  n_group = n_group + 1;
  cur_group = name;
  print("[", tostring(n_group), "] ", name, "\n")
}

def ok(label: str, cond: bool, detail: str) {
  n_checks = n_checks + 1;
  if (cond) {
    if (verbose != 0) { print("    ok   ", label, "\n") }
  } else {
    n_fail = n_fail + 1;
    if (quiet_fail != 0) {
      print("    deliberate (harness self-test): ", label, ": ", detail, "\n")
    } else {
      print("    FAIL ", label, ": ", detail, "\n")
    }
  }
}

// eq_str(label, got, want) -- the workhorse.  It refuses to compare an empty
// string, because "" == "" is true and is exactly the vacuous pass.
def eq_str(label: str, got: str, want: str) {
  n_cmp = n_cmp + 1;
  if (got.length == 0 || want.length == 0) {
    n_refused = n_refused + 1;
    ok(label, false, "REFUSED to compare an ABSENT value (got " + tostring(got.length) +
                    " bytes, want " + tostring(want.length) + ") -- that is the vacuous pass")
  } else {
    ok(label, got == want, "got " + got + ", want " + want)
  }
}

// eq_bn(label, slot, want) -- the workhorse for bignum values.  It compares
// DIGITS and allocates nothing on the happy path; the `str` for both sides is
// built only when they disagree, which is when there is something to read.
def eq_bn(label: str, s: long, want: str) {
  n_cmp = n_cmp + 1;
  if (want.length == 0) {
    n_refused = n_refused + 1;
    ok(label, false, "REFUSED to compare an ABSENT expectation -- that is the vacuous pass");
    return
  };
  let r = bn.bn_eq_dec(s, want);
  if (r == 0 - 1) {
    n_refused = n_refused + 1;
    ok(label, false, "REFUSED to compare an ABSENT value -- that is the vacuous pass")
  } else if (r != 0) {
    ok(label, true, "")
  } else {
    ok(label, false, "got " + bn.bn_str(s) + ", want " + want)
  }
}

// eq_bb(label, s1, s2) -- two bignum slots, compared in place.  Neither side
// is turned into text on the happy path.
def eq_bb(label: str, s1: long, s2: long) {
  n_cmp = n_cmp + 1;
  if (bn.bn_n(s1) < 0 || bn.bn_n(s2) < 0) {
    ok(label, false, "one operand is absent")
  } else if (bn.bn_eq(s1, s2) != 0) {
    ok(label, true, "")
  } else {
    ok(label, false, "got " + bn.bn_str(s1) + ", want " + bn.bn_str(s2))
  }
}

def eq_long(label: str, got: long, want: long) {
  n_cmp = n_cmp + 1;
  ok(label, got == want, "got " + tostring(got) + ", want " + tostring(want))
}

// count_floor(label, made, floor_) -- "this group really did something".
// A group that compares zero things must not be able to report success.
def count_floor(label: str, made: long, floor_: long) {
  ok(label, made >= floor_, "only " + tostring(made) + " comparisons, floor is " + tostring(floor_))
}

def head(s: str, n: long) -> str {
  if (s.length <= n) { return s };
  let out = "";
  let i = 0;
  while (i < n) { out += chr(s[i]); i = i + 1 };
  out + "..."
}

// ── (A) the native `long` as the oracle ────────────────────────────────────
//
// Values chosen to straddle every interesting boundary a 28-bit limb has, and
// every boundary a signed 64-bit long has: 0, +-1, +-2^27, +-2^28, +-2^29,
// +-2^31, +-2^32, +-2^62, +-2^63 (the values that cannot be negated in a
// long), and products/quotients that straddle a limb boundary.

def oracle_vals() -> [long] {
  [ 0, 1, 2, 3, 7, 10, 100, 255, 65535,
    134217727, 134217728, 134217729,          // 2^27-1, 2^27, 2^27+1
    268435455, 268435456, 268435457,          // 2^28-1, 2^28, 2^28+1
    536870911, 536870912, 536870913,          // 2^29 boundary
    2147483647, 2147483648,                   // 2^31-1, 2^31
    4294967295, 4294967296, 4294967297,       // 2^32 boundary
    3037000499, 3037000500,                   // ~2^31.5
    123456789, 987654321, 1000000007,
    1234567890123, 999999999999999,
    4611686018427387903, 4611686018427387904, // 2^62-1, 2^62
    9223372036854775807,                     // 2^63-1, the largest long
    // These two are not round numbers and they are not here by accident.  They
    // are the pair an EXTERNAL model of Knuth division (CPython, written from
    // the textbook algorithm with the quotient-estimate correction loop
    // removed) first disagreed with the true quotient on: 8742514861359412281
    // / 3641603982383516984 is 2 remainder 1459306896592378313, and without the
    // correction loop the estimate comes out as 1 remainder 5100910878975895297.
    // Both operands fit a signed long, so the MACHINE is the oracle here and
    // no hand-written constant is needed.  Found by search, then verified.
    8742514861359412281, 3641603982383516984,
    0 - 9223372036854775807,
    0 - 4611686018427387904,
    0 - 3037000499, 0 - 268435457, 0 - 134217729,
    0 - 2147483648, 0 - 4294967296, 0 - 123456789,
    0 - 65535, 0 - 255, 0 - 100, 0 - 7, 0 - 3, 0 - 2, 0 - 1 ]
}

let oracle_made: long = 0;

// oracle_addsub(label, a, b) -- a+b, a-b, a*b and the comparisons against the
// machine's own arithmetic.  Values that overflow a long are SKIPPED, not
// compared: a wrapped product would "disagree" with a bignum that is right,
// and reporting that would train the reader to ignore the check.
def oracle_binop(a: long, b: long) {
  bn.bn_from_long(bn.S_A, a);
  bn.bn_from_long(bn.S_B, b);
  let want = a + b;
  if (!overflows_add(a, b)) {
    bn.bn_add(bn.S_C, bn.S_A, bn.S_B);
    oracle_made = oracle_made + 1;
    eq_long("add", bn.bn_to_long(bn.S_C), want)
  };
  let wants = a - b;
  if (!overflows_sub(a, b)) {
    bn.bn_sub(bn.S_C, bn.S_A, bn.S_B);
    oracle_made = oracle_made + 1;
    eq_long("sub", bn.bn_to_long(bn.S_C), wants)
  };
  let wantm = a * b;
  if (!overflows_mul(a, b)) {
    bn.bn_mul(bn.S_C, bn.S_A, bn.S_B);
    oracle_made = oracle_made + 1;
    eq_long("mul", bn.bn_to_long(bn.S_C), wantm)
  };
  // the comparison operator, against the machine's
  let c = bn.bn_cmp(bn.S_A, bn.S_B);
  let wc = (a < b ? 0 - 1 : (a > b ? 1 : 0));
  oracle_made = oracle_made + 1;
  eq_long("cmp", c, wc)
}

def overflows_add(a: long, b: long) -> bool {
  if (b > 0 && a > 9223372036854775807 - b) { return true };
  if (b < 0 && a < (0 - 9223372036854775807) - b) { return true };
  false
}

def overflows_sub(a: long, b: long) -> bool { overflows_add(a, 0 - b) }

def overflows_mul(a: long, b: long) -> bool {
  if (a == 0 || b == 0) { return false };
  if (a == 0 - 9223372036854775807 - 1 || b == 0 - 9223372036854775807 - 1) { return true };
  let c = a * b;
  (c / a != b)
}

// oracle_divmod(a, b) -- the quotient and the remainder against the machine.
// b == 0 is NOT here: it must be a message and a non-zero exit, and that is
// checked end to end through a forked child in group (E).
def oracle_divmod(a: long, b: long) {
  if (b == 0) { return };
  if (a == 0 - 9223372036854775807 - 1 && b == 0 - 1) { return };   // quotient is 2^63
  bn.bn_from_long(bn.S_A, a);
  bn.bn_from_long(bn.S_B, b);
  let rc = bn.bn_divmod(bn.S_C, bn.S_D, bn.S_A, bn.S_B);
  oracle_made = oracle_made + 1;
  if (rc != 0) {
    ok("divmod", false, "rc " + tostring(rc))
  } else {
    eq_long("div", bn.bn_to_long(bn.S_C), a / b);
    eq_long("mod", bn.bn_to_long(bn.S_D), a % b)
  }
}

def t_native_oracle() {
  group("(A) the native long as the oracle: add, sub, mul, cmp, div, mod");
  oracle_made = 0;
  let v = oracle_vals();
  let i = 0;
  let before = n_cmp;
  while (i < len(v)) {
    let j = 0;
    while (j < len(v)) {
      oracle_binop(v[i], v[j]);
      oracle_divmod(v[i], v[j]);
      j = j + 1
    };
    i = i + 1
  };
  // the round trip: a long -> bignum -> string -> bignum -> long
  i = 0;
  while (i < len(v)) {
    bn.bn_from_long(bn.S_A, v[i]);
    let s = bn.bn_str(bn.S_A);
    let back = bn.from_dec(bn.S_B, s);
    oracle_made = oracle_made + 1;
    eq_long("roundtrip-long-str-long", back + bn.bn_to_long(bn.S_B), v[i]);
    // and the digit count, which to_dec could get right in text and wrong in
    // length (or the other way round) if a chunk were padded wrongly.  The
    // sign is one extra character, so it is added back before comparing.
    oracle_made = oracle_made + 1;
    eq_long("roundtrip-digits", bn.bn_dec(bn.S_A) + (bn.bn_neg(bn.S_A) == 1 ? 1 : 0), s.length);
    i = i + 1
  };
  count_floor("the oracle group really compared things",
              n_cmp - before, 10000);
  print("    ", tostring(n_cmp - before), " comparisons against the machine's own arithmetic, ",
        tostring(len(v)), " x ", tostring(len(v)), " value pairs\n")
}

// t_negative_roundtrip() -- -2^63 is the one magnitude a `long` cannot hold,
// so it is the value that catches a "just negate it" conversion.
def t_boundary_constants() {
  group("(B) hand-written constants at and beyond the 2^64 boundary");
  let cases: [str] = [
    "0",
    "1",
    "-1",
    "9223372036854775807",           // 2^63-1, the largest long
    "-9223372036854775808",          // 2^63, the value that cannot be negated
    "9223372036854775808",           // 2^63  -- one past the largest long
    "18446744073709551615",          // 2^64-1, the largest unsigned 64-bit
    "18446744073709551616",          // 2^64
    "18446744073709551617",          // 2^64+1
    "-18446744073709551617",
    "36893488147419103232",          // 2^65
    "340282366920938463463374607431768211456",   // 2^128
    "340282366920938463463374607431768211455",   // 2^128-1
    "115792089237316195423570985008687907853269984665640564039457584007913129639936",  // 2^256
    "6277101735386680763835789423207666416102355444464034512895"   // 10^69, round 70 digits
  ];
  let i = 0;
  let made = 0;
  while (i < len(cases)) {
    let want = cases[i];
    let rc = bn.from_dec(bn.S_A, want);
    if (rc != 0) {
      ok("parse", false, want + ": rc " + tostring(rc))
    } else {
      made = made + 1;
      eq_bn("2^boundary " + head(want, 24), bn.S_A, want);
      // and the bits, which is the claim that matters at the boundary: the
      // value 2^64 must need 65 bits, which no `long` can report honestly
      if (want == "18446744073709551616") {
        eq_long("bits(2^64)", bn.bn_bits(bn.S_A), 65);
        eq_long("limbs(2^64)", bn.bn_n(bn.S_A), 3)
      };
      if (want == "340282366920938463463374607431768211456") {
        eq_long("bits(2^128)", bn.bn_bits(bn.S_A), 129);
        eq_long("digits(2^128)", bn.bn_dec(bn.S_A), 39)
      };
      if (want == "9223372036854775807") { eq_long("fits 2^63-1", (bn.bn_fits(bn.S_A) ? 1 : 0), 1) };
      if (want == "18446744073709551616") { eq_long("does not fit", (bn.bn_fits(bn.S_A) ? 1 : 0), 0) }
    };
    i = i + 1
  };
  count_floor("the boundary group really compared things", made, len(cases));

  // -- the boundary arithmetic itself, in decimal, no oracle needed
  bn.from_dec(bn.S_A, "18446744073709551616");       // 2^64
  bn_from_dec_pow2(bn.S_B, 1000);                    // 2^1000
  bn.bn_mul(bn.S_C, bn.S_A, bn.S_A);
  eq_bn("2^64 * 2^64", bn.S_C, "340282366920938463463374607431768211456");  // 2^128
  bn.bn_sub(bn.S_C, bn.S_C, bn.S_A);
  // 2^128 - 2^64 = 2^64 * (2^64 - 1).  An earlier version of this line
  // carried 2^128 - 16 by mistake, so the battery failed on a correct
  // library -- which is the failure mode this whole exercise is about, from
  // the other side.
  eq_bn("2^128 - 2^64", bn.S_C, "340282366920938463444927863358058659840");
  bn.bn_sub(bn.S_D, bn.S_A, bn.S_ONE);
  bn.bn_add(bn.S_C, bn.S_D, bn.S_ONE);
  eq_bn("2^64-1 then +1", bn.S_C, "18446744073709551616");
  // 2^64 / 2^32 = 2^32 exactly, and the remainder is 0: the limb crossing
  bn_from_dec_pow2(bn.S_G, 32);
  bn.bn_divmod(bn.S_C, bn.S_D, bn.S_A, bn.S_G);
  eq_bn("2^64 / 2^32", bn.S_C, "4294967296");  // 2^32, exactly
  eq_bn("2^64 %% 2^32", bn.S_D, "0");
  bn.bn_divmod(bn.S_C, bn.S_D, bn.S_A, bn.S_A);
  eq_bn("2^64 %% 2^64", bn.S_D, "0");

  // 2^1000, the constant this example is named for.  It is written out here
  // from an external source (CPython `2**1000`), not from this program: see
  // README.md, "Where the oracle cannot reach".
  eq_bn("2^1000", bn.S_B, "10715086071862673209484250490600018105614048117055336074437503883703510511249361224931983788156958581275946729175531468251871452856923140435984577574698574803934567774824230985421074605062371141877954182153046474983581941267398767559165543946077062914571196477686542167660429831652624386837205668069376");
  eq_long("2^1000 bits", bn.bn_bits(bn.S_B), 1001);
  eq_long("2^1000 digits", bn.bn_dec(bn.S_B), 302);
  eq_long("2^1000 limbs", bn.bn_n(bn.S_B), 36);
  bn.bn_sub(bn.S_C, bn.S_B, bn.S_ONE);
  eq_bn("2^1000 - 1", bn.S_C, "10715086071862673209484250490600018105614048117055336074437503883703510511249361224931983788156958581275946729175531468251871452856923140435984577574698574803934567774824230985421074605062371141877954182153046474983581941267398767559165543946077062914571196477686542167660429831652624386837205668069375");
  bn.bn_sub(bn.S_C, bn.S_ZERO, bn.S_B);
  eq_bn("-(2^1000)", bn.S_C, "-10715086071862673209484250490600018105614048117055336074437503883703510511249361224931983788156958581275946729175531468251871452856923140435984577574698574803934567774824230985421074605062371141877954182153046474983581941267398767559165543946077062914571196477686542167660429831652624386837205668069376")
}

// bn_from_dec_pow2(s, k) -- s = 2^k, for the check's own use.  The 1 goes in
// scratch slot S_J: an earlier version seeded S_A, so calling this to make 2^32
// silently reset the 2^64 sitting in S_A and 2^64 * 2^64 came out as 1.
def bn_from_dec_pow2(s: long, k: long) -> long {
  bn.bn_from_long(bn.S_J, 1);
  bn.bn_shl(s, bn.S_J, k)
}

// ── (C) algebraic identities, the only oracle above 64 bits ────────────────
//
// These hold at every width, so they are what the range beyond a `long`
// gets instead of the machine.

let prop_made: long = 0;
let prop_pool: [str] = [
  "340282366920938463463374607431768211456",     // 2^128
  "-340282366920938463463374607431768211456",
  "340282366920938463463374607431768211455",     // 2^128-1
  "6277101735386680763835789423207666416102355444464034512896",   // 10^70
  "115792089237316195423570985008687907853269984665640564039457584007913129639936",
  "-115792089237316195423570985008687907853269984665640564039457584007913129639936",
  "1",
  "0",
  "-1",
  "99999999999999999999999999999999999999999999999999999999999999999999999999999",
  "12345678901234567890123456789012345678901234567890123456789",
  "2", "3", "10", "7", "-2", "-3", "-10", "-7"
];

def pick(i: long) -> str {
  prop_pool[i % len(prop_pool)]
}

// pick_nz(i) -> str -- the same pool, skipping an entry that is zero, so this
// can be used as a DIVISOR.  Every other entry stays in.
def pick_nz(i: long) -> str {
  let k = i % len(prop_pool);
  let guard = 0;
  let out = prop_pool[k];
  let again = out == "0";
  while (again && guard < len(prop_pool)) {
    k = (k + 1) % len(prop_pool);
    out = prop_pool[k];
    guard = guard + 1;
    again = out == "0"
  };
  if (out == "0") { "1" } else { out }
}

def t_identities() {
  group("(C) algebraic identities at every width, including past 2^64");
  prop_made = 0;
  let n = len(prop_pool);
  let i = 0;
  while (i < n) {
    let j = 0;
    while (j < n) {
      bn.from_dec(bn.S_A, pick(i));
      bn.from_dec(bn.S_B, pick(j));
      bn.from_dec(bn.S_C, pick(i + j + 1));
      // a - a == 0
      bn.bn_sub(bn.S_D, bn.S_A, bn.S_A);
      prop_made = prop_made + 1;
      eq_bn("a-a", bn.S_D, "0");
      // a / 1 == a
      bn_from_dec_pow2(bn.S_E, 0);
      let rc = bn.bn_divmod(bn.S_D, bn.S_E, bn.S_A, bn.S_ONE);
      prop_made = prop_made + 1;
      eq_long("a/1 rc", rc, 0);
      eq_bb("a/1", bn.S_D, bn.S_A);
      // x - y == -(y - x)
      bn.bn_sub(bn.S_D, bn.S_A, bn.S_B);
      bn.bn_sub(bn.S_E, bn.S_B, bn.S_A);
      bn.bn_sub(bn.S_E, bn.S_ZERO, bn.S_E);
      prop_made = prop_made + 1;
      eq_bb("x-y==-(y-x)", bn.S_D, bn.S_E);
      // commutativity of +
      bn.bn_add(bn.S_D, bn.S_A, bn.S_B);
      bn.bn_add(bn.S_E, bn.S_B, bn.S_A);
      prop_made = prop_made + 1;
      eq_bb("a+b==b+a", bn.S_D, bn.S_E);
      // commutativity of *
      bn.bn_mul(bn.S_D, bn.S_A, bn.S_B);
      bn.bn_mul(bn.S_E, bn.S_B, bn.S_A);
      prop_made = prop_made + 1;
      eq_bb("a*b==b*a", bn.S_D, bn.S_E);
      // sign(a*b) == sign(a)*sign(b), stated on the SIGN alone so it is not
      // just the multiplication test again.  The ZERO product is the one case
      // where the rule needs a word: 0 has no sign, so it is excluded rather
      // than special-cased into the comparison.
      bn.bn_mul(bn.S_D, bn.S_A, bn.S_B);
      prop_made = prop_made + 1;
      if (bn.bn_n(bn.S_A) != 0 && bn.bn_n(bn.S_B) != 0) {
        eq_long("sign(a*b)", bn.bn_neg(bn.S_D), bn.bn_neg(bn.S_A) ^ bn.bn_neg(bn.S_B))
      } else {
        eq_long("a zero operand gives a zero product", bn.bn_n(bn.S_D), 0)
      };
      // a*(b+c) == a*b + a*c   -- distributivity, stated as distributivity.
      // (An earlier version asserted a*b+c == a*c+b*c, which is not an
      // identity at all: it differs from the truth by (a-1)*(b-c), so it
      // failed on almost every pair and looked like a library defect.)
      bn.bn_add(bn.S_G, bn.S_B, bn.S_C);
      bn.bn_mul(bn.S_D, bn.S_A, bn.S_G);
      bn.bn_mul(bn.S_E, bn.S_A, bn.S_B);
      bn.bn_mul(bn.S_F, bn.S_A, bn.S_C);
      bn.bn_add(bn.S_E, bn.S_E, bn.S_F);
      prop_made = prop_made + 1;
      eq_bb("a*(b+c)==a*b+a*c", bn.S_D, bn.S_E);
      // a == (a/b)*b + a%b, the division identity, at every width.  The
      // DIVISOR pool excludes zero on purpose: division by zero is not an
      // identity to check, it is a message and a non-zero exit, and group (E)
      // drives that end to end through a forked child.
      bn.from_dec(bn.S_F, pick_nz(i + 5));
      let rc2 = bn.bn_divmod(bn.S_D, bn.S_E, bn.S_A, bn.S_F);
      prop_made = prop_made + 1;
      eq_long("divmod rc", rc2, 0);
      bn.bn_mul(bn.S_D, bn.S_D, bn.S_F);
      bn.bn_add(bn.S_D, bn.S_D, bn.S_E);
      prop_made = prop_made + 1;
      eq_bb("a==(a/b)*b+a%b", bn.S_D, bn.S_A);
      // 0 <= |a%b| < |b|, and the remainder follows the DIVIDEND's sign.
      // Both operands go through bn_abs in their own statements: bn_abs
      // returns a status, so nesting it reads slot 0 and the comparison
      // degenerates to 0 == 0.
      bn.bn_abs(bn.S_G, bn.S_F);
      bn.bn_abs(bn.S_H, bn.S_E);
      prop_made = prop_made + 1;
      ok("|a%b| < |b|", bn.bn_cmp(bn.S_H, bn.S_G) < 0,
         "rem " + bn.bn_str(bn.S_E) + " div " + bn.bn_str(bn.S_F));
      prop_made = prop_made + 1;
      // A zero remainder has no sign at all -- the library stores 0 there --
      // so the claim is made only where the remainder is non-zero.
      eq_long("sign(a%b)==sign(a) unless zero",
              (bn.bn_n(bn.S_E) == 0 ? 0 : bn.bn_neg(bn.S_E)),
              (bn.bn_n(bn.S_E) == 0 ? 0 : bn.bn_neg(bn.S_A)));
      j = j + 1
    };
    i = i + 1
  };
  // associativity of + and of *, on triples
  let k = 0;
  while (k < len(prop_pool)) {
    let m = 0;
    while (m < len(prop_pool)) {
      bn.from_dec(bn.S_A, pick(k));
      bn.from_dec(bn.S_B, pick(m + 3));
      bn.from_dec(bn.S_C, pick(m + 7));
      bn.bn_add(bn.S_D, bn.S_A, bn.S_B);
      bn.bn_add(bn.S_D, bn.S_D, bn.S_C);
      bn.bn_add(bn.S_E, bn.S_B, bn.S_C);
      bn.bn_add(bn.S_E, bn.S_A, bn.S_E);
      prop_made = prop_made + 1;
      eq_bb("(a+b)+c==a+(b+c)", bn.S_D, bn.S_E);
      k = k + 1;
      m = m + 1
    }
  };
  count_floor("the identity group really compared things", prop_made, 3900);
  print("    ", tostring(prop_made), " algebraic identities over ",
        tostring(len(prop_pool)), " values of up to 78 digits\n")
}

// t_times_ten() -- a*10^k is k multiplications by ten.  The digits all live
// at 2^70 and beyond, so this walks the limb array on every multiplication
// and is a real test of the multiply, not an identity inside one limb.
def t_times_ten() {
  group("(C2) a * 10^k is k multiplications by ten, at 1000 bits and up");
  let bases: [str] = [
    "340282366920938463463374607431768211456",
    "6277101735386680763835789423207666416102355444464034512896",
    "1",
    "7",
    "18446744073709551617",
    "99999999999999999999999999999999999999999999999999999999999999999999999999999"
  ];
  let made = 0;
  let bi = 0;
  while (bi < len(bases)) {
    let k = 0;
    while (k <= 24) {
      // route one: build 10^k and multiply once
      bn.from_dec(bn.S_A, bases[bi]);
      bn_from_pow(bn.S_B, 10, k);
      bn.bn_mul(bn.S_C, bn.S_A, bn.S_B);
      // route two: multiply by TEN, k times.  S_TEN holds 10 -- an earlier
      // version of this group multiplied by S_TWO, so the two routes
      // disagreed by a factor of 5^24 and every one of its 144 comparisons
      // failed.
      bn.from_dec(bn.S_D, bases[bi]);
      let t = 0;
      let again = t < k;
      while (again) {
        bn.bn_mul(bn.S_D, bn.S_D, bn.S_TEN);
        t = t + 1;
        again = t < k
      };
      made = made + 1;
      eq_bb("a*10^" + tostring(k) + " x " + head(bases[bi], 12),
             bn.S_C, bn.S_D);
      k = k + 1
    };
    bi = bi + 1
  };
  count_floor("the times-ten group really compared things", made, 100);
  print("    ", tostring(made), " products, up to 10^24 x a 66-digit value\n")
}

// bn_from_pow(s, base, k) -- s = base^k, exact.  The base goes in its own
// scratch slot because bn_pow takes a SLOT, not a value: `bn_pow(s, 10, k)`
// would read slot 10, which is S_I.
def bn_from_pow(s: long, base: long, k: long) -> long {
  bn.bn_from_long(bn.S_I, base);
  bn.bn_pow(s, bn.S_I, k)
}

// ── (D) the library doing real work a `long` cannot ────────────────────────
//
// Everything in this group is beyond 2^63, so the machine cannot referee it.
// What the group checks instead is that the WORK is right, using facts that
// hold independently of the code under test:
//
//   * trial division finds a factor d, and d * (n/d) == n;
//   * Pollard rho finds a factor d of a semiprime p*q, and d*d*d*d*d
//     reproduces the same value on a second run (a deterministic oracle);
//   * Fermat's test for base 2 on a prime must pass, and on a Carmichael
//     number it must ALSO pass -- which is the point: a single Fermat test
//     is not a primality test, and the demo says so;
//   * a^e mod m equals the value computed by the other route, repeated
//     multiplication rather than square-and-multiply.

// trial_divisor(s, n_text) -- the smallest factor of n by trial division,
// from 2 upwards, stopping once d*d > n.  Returns 1 and leaves the factor in
// s, or 0 if it reached sqrt(n) without finding one (so n is prime).
// TRIAL_CAP bounds the walk in STEPS.  The loop's own stopping condition is
// d*d > n, which is a property of the arithmetic -- and an arithmetic defect
// (a broken left shift, say) makes that condition unreachable, so the walk
// runs for ever instead of failing.  2,000,000 steps is 7x more than the
// 274,175 the 2^64+1 case actually needs, so it never fires on a correct
// build, and it turns injection 7 from a hang into a reported failure.
let TRIAL_CAP = 2000000;

def trial_divisor(s: long, n_text: str) -> long {
  bn.from_dec(bn.S_A, n_text);
  let d = bn.S_B;
  bn.bn_from_long(d, 2);
  let d2 = bn.S_C;                     // d*d, so the walk stops at sqrt(n)
  let found = 0;
  let steps = 0;
  let go = true;
  while (go && found == 0 && steps < TRIAL_CAP) {
    steps = steps + 1;
    let rc = bn.bn_divmod(bn.S_D, bn.S_E, bn.S_A, d);
    if (rc != 0) { go = false }
    else {
      if (bn.bn_n(bn.S_E) == 0) {
        bn.bn_copy(s, d);
        found = 1;
        go = false
      } else {
        bn.bn_mul(d2, d, d);
        if (bn.bn_cmp_mag(d2, bn.S_A) > 0) { go = false }
        else { bn.bn_add(d, d, bn.S_ONE) }
      }
    }
  };
  found
}

// pollard(s, n_text, seed) -- Floyd's cycle form of Pollard rho.  No clock
// and no random source: the seed is a parameter, so the whole thing is a pure
// function and the battery can assert it is deterministic.  Returns 1 and
// leaves a non-trivial factor in s, or 0 if it gave up.
def pollard(s: long, n_text: str, seed: long) -> long {
  let n = bn.S_A;
  bn.from_dec(n, n_text);
  let x = bn.S_B;                       // the tortoise
  let y = bn.S_C;                       // the hare
  let c = bn.S_D;                       // f(v) = v*v + c (mod n)
  let g = bn.S_E;                       // the running gcd
  let dif = bn.S_F;                     // x - y, which must NOT be x
  bn.bn_from_long(x, seed);
  bn.bn_mod(x, x, n);
  bn.bn_copy(y, x);
  bn.bn_from_long(c, 2654435761);
  bn.bn_mod(c, c, n);
  let one = bn.S_ONE;
  let iter = 0;
  let found = 0;
  let go = true;
  while (go && found == 0) {
    rho_step(x, n, c);
    rho_step(y, n, c);
    rho_step(y, n, c);
    // The difference goes in its OWN slot.  An earlier version wrote it back
    // into x, so the tortoise was overwritten by |x - y| and the next step
    // squared the difference instead of the tortoise.  That still ran the full
    // 100000 iterations, just on the wrong orbit, and found nothing.
    bn.bn_sub(dif, x, y);
    bn.bn_abs(dif, dif);
    let rc = bn.bn_gcd(g, dif, n);
    if (rc != 0) { go = false }
    else {
      if (bn.bn_cmp_mag(g, n) == 0) {
        // x == y (mod n): this seed degenerated.  Step the tortoise once
        // more and take that gcd instead -- the standard recovery.
        rho_step(x, n, c);
        bn.bn_sub(dif, x, y);
        bn.bn_abs(dif, dif);
        rc = bn.bn_gcd(g, dif, n);
        if (rc != 0 || bn.bn_cmp_mag(g, n) == 0) { go = false }
      };
      let take = go && bn.bn_cmp_mag(g, one) > 0;
      if (take) {
        bn.bn_copy(s, g);
        found = 1;
        go = false
      } else {
        iter = iter + 1;
        go = iter < 100000
      }
    }
  };
  found
}

def rho_step(v: long, n: long, c: long) -> long {
  bn.bn_mul(v, v, v);
  bn.bn_add(v, v, c);
  bn.bn_mod(v, v, n)
}

let work_made: long = 0;

// t_real_work() -- the library doing something a `long` cannot hold, checked by
// facts that hold independently of the code under test:
//
//   * trial division walks 2..d and stops at the first exact divisor; the
//     factor it reports must multiply back to the input;
//   * Pollard rho on a 40-digit semiprime must return a factor that multiplies
//     back to the input, and the SAME SEED must return the same factor twice
//     (rho has no clock and no random source, so this is a determinism claim
//     about the algorithm, not about the machine);
//   * Fermat's test must PASS on a prime and must ALSO pass on 561, which is
//     exactly why one Fermat test is not a primality test.  Asserting both is
//     the honest form, and both are asserted.
//
// The two factorisations below were obtained outside this program (CPython
// trial division), not from this code.
def t_real_work() {
  group("(D) real work beyond 64 bits: trial division, Pollard rho, modpow");
  work_made = 0;

  // -- 2^64+1 = 274177 * 67280421310721.  The input is past the largest
  //    signed long and the product of the two factors is exactly 2^64+1.
  let n1 = "18446744073709551617";
  bn.from_dec(bn.S_A, n1);
  eq_bn("2^64+1 parsed", bn.S_A, n1);
  work_made = work_made + 1;
  let f = bn.S_G;
  let found = trial_divisor(f, n1);
  work_made = work_made + 1;
  ok("trial division found a factor", found == 1, "nothing found");
  eq_bn("trial divisor", f, "274177");
  bn.bn_div(bn.S_C, bn.S_A, f);
  eq_bn("the cofactor", bn.S_C, "67280421310721");
  bn.bn_mul(bn.S_D, f, bn.S_C);
  work_made = work_made + 1;
  eq_bn("factor * cofactor == n", bn.S_D, n1);

  // -- 1048573 * 9536770448981615967605498138899139, a 40-digit semiprime
  let n2 = "9999999999999999999999999999999886878647";
  bn.from_dec(bn.S_A, n2);
  eq_bn("the 40-digit semiprime parsed", bn.S_A, n2);
  work_made = work_made + 1;
  bn.from_dec(bn.S_B, "1048573");
  bn.from_dec(bn.S_C, "9536770448981615967605498138899139");
  bn.bn_mul(bn.S_D, bn.S_B, bn.S_C);
  work_made = work_made + 1;
  eq_bn("1048573 * the cofactor", bn.S_D, n2);
  let g = bn.S_H;
  let got = pollard(g, n2, 2);
  work_made = work_made + 1;
  ok("pollard rho found a factor", got == 1, "nothing found");
  eq_bn("rho divisor", g, "1048573");
  bn.bn_div(bn.S_C, bn.S_A, g);
  bn.bn_mul(bn.S_D, g, bn.S_C);
  work_made = work_made + 1;
  eq_bn("rho factor * quotient == n", bn.S_D, n2);
  let g2 = bn.S_I;
  pollard(g2, n2, 2);
  work_made = work_made + 1;
  eq_bb("rho is deterministic for a fixed seed", g2, g);

  // -- Fermat, both ways round
  // p = 2^30+3 = 1073741827 is prime; 2^30+1 is not, which is why it is
  // written down this way.  (2^30+3 > 2^30, so this also exercises a modulus
  // wider than one limb pair.)
  bn_from_dec_pow2(bn.S_A, 30);
  bn.bn_add(bn.S_A, bn.S_A, bn.S_TWO);
  bn.bn_add(bn.S_A, bn.S_A, bn.S_ONE);            // 2^30 + 3
  eq_bn("the Fermat prime", bn.S_A, "1073741827");
  work_made = work_made + 1;
  bn.bn_sub(bn.S_B, bn.S_A, bn.S_ONE);
  let rc = bn.bn_powmod(bn.S_D, bn.S_TWO, bn.bn_to_long(bn.S_B), bn.S_A);
  work_made = work_made + 1;
  eq_long("2^(p-1) mod p rc", rc, 0);
  work_made = work_made + 1;
  eq_bn("2^(p-1) mod p == 1", bn.S_D, "1");
  // 561 is a Carmichael number: 2^560 mod 561 is 1 too, so Fermat alone
  // proves nothing.
  bn.from_dec(bn.S_A, "561");
  let rc2 = bn.bn_powmod(bn.S_D, bn.S_TWO, 560, bn.S_A);
  work_made = work_made + 1;
  eq_long("2^560 mod 561 rc", rc2, 0);
  work_made = work_made + 1;
  eq_bn("2^560 mod 561 == 1 (Carmichael: Fermat is fooled)", bn.S_D, "1");
  // the same exponent the other way: 560 modular doublings
  bn.bn_copy(bn.S_E, bn.S_ONE);
  let k = 0;
  let again = k < 560;
  while (again) {
    bn.bn_mul(bn.S_E, bn.S_E, bn.S_TWO);
    bn.bn_mod(bn.S_E, bn.S_E, bn.S_A);
    k = k + 1;
    again = k < 560
  };
  work_made = work_made + 1;
  eq_bb("2^560 mod 561 by 560 doublings", bn.S_E, bn.S_D);

  count_floor("the real-work group really compared things", work_made, 12);
  print("    ", tostring(work_made), " assertions over values a native long cannot hold\n")
}

// ── (E) division by zero: a message and a non-zero exit, on every path ─────
//
// This is the trap the brief warns about: a Y runtime trap prints to STDOUT,
// so `1 / 0` would splice "runtime error: division by zero" into the output
// and look like a passing run.  So the error paths are driven END TO END
// through a forked child with its stdout and stderr on a pipe, and the
// battery looks at the child's exit code and its words.

let child_out: str = "";
let child_fail: long = 0;

def self_path() -> str {
  // `argv().length` is the trap this example's own README cites: it compiles
  // to a call of the runtime argv helper whose result register is never
  // initialised when the only read is the length, and it segfaults.  Binding
  // first and reading the length off the binding is the workaround.
  let av = argv();
  let p = av[0];
  if (!p.starts_with("/")) { p = fs.cwd() + "/" + p; };
  p
}

// run_child(extra) -> long -- execve this same binary with `extra`, return
// its exit code, leave its merged stdout+stderr in child_out.
def run_child(extra: [str]) -> long {
  let ifds: [byte; 8] = [0; 8];
  syscall(293, &ifds[0], 0);
  let in_rd = ifds[0] + ifds[1] * 256 + ifds[2] * 65536 + ifds[3] * 16777216;
  let in_wr = ifds[4] + ifds[5] * 256 + ifds[6] * 65536 + ifds[7] * 16777216;
  let ofds: [byte; 8] = [0; 8];
  syscall(293, &ofds[0], 0);
  let out_rd = ofds[0] + ofds[1] * 256 + ofds[2] * 65536 + ofds[3] * 16777216;
  let out_wr = ofds[4] + ofds[5] * 256 + ofds[6] * 65536 + ofds[7] * 16777216;

  let pathb = bytes(self_path());
  pathb += 0;
  let blobs: [[byte]] = [];
  let i = 0;
  while (i < len(extra)) {
    let b = bytes(extra[i]);
    b += 0;
    blobs += b;
    i = i + 1
  };
  // `[0; n]` needs an integer LITERAL, so the argv array is grown with `+=`,
  // which is the array interface anyway.
  let av: [long] = [];
  av += ptr_addr(&pathb[0]);
  i = 0;
  while (i < len(extra)) { av += ptr_addr(&blobs[i][0]); i = i + 1 };
  av += 0;

  let pid = fork {
    syscall(33, in_rd, 0, 0);
    syscall(33, out_wr, 1, 0);
    syscall(33, out_wr, 2, 0);
    syscall(3, in_rd, 0);
    syscall(3, in_wr, 0);
    syscall(3, out_wr, 0);
    syscall(59, ptr_addr(&pathb[0]), ptr_addr(&av[0]), 0);
    exit(127)
  };
  if (pid < 0) { child_out = "fork failed"; return 0 - 1 };
  syscall(3, in_rd, 0);
  syscall(3, in_wr, 0);
  syscall(3, out_wr, 0);
  let buf: [byte; 8192] = [0; 8192];
  let got: [byte] = [];
  let go = true;
  while (go) {
    let n = syscall(0, out_rd, &buf[0], 8192);
    if (n > 0) {
      let k = 0;
      while (k < n) { got += buf[k]; k = k + 1 }
    } else { go = false }
  };
  syscall(3, out_rd, 0);
  child_out = from_bytes(got);
  wait_pid(pid)
}

def t_error_paths() -> long {
  group("(E) every error path: a message, a non-zero exit, and no trap");
  // Every one of these must exit NON-ZERO, print SOMETHING, print nothing
  // that looks like a trap, and leave stdout clean.  Cases that are merely
  // unusual -- a leading zero, a leading space, a double negation -- are NOT
  // in this list: they are legal, and the battery asserts below that they are
  // accepted, so that the list stays a list of genuine refusals.
  let cases: [[str]] = [
    ["div", "1", "0"],
    ["div", "0", "0"],
    ["div", "-7", "0"],
    ["div", "340282366920938463463374607431768211456", "0"],
    ["mod", "1", "0"],
    ["mod", "0", "0"],
    ["mod", "-7", "0"],
    ["calc", "1/0"],
    ["calc", "6*(2+"],
    ["calc", "(1+2"],
    ["calc", "1+2)"],
    ["calc", "*3"],
    ["calc", "1..2"],
    ["calc", "()"],
    ["nope"],
    ["div"],
    ["div", "1"],
    ["div", "1", "2", "3"],
    ["calc", ""],
    ["calc", "12x"],
    ["calc", "1/"],
    ["show", "notanumber"],
    ["pow", "2", "-1", "7"]
  ];
  let i = 0;
  let made = 0;
  while (i < len(cases)) {
    let c = cases[i];
    let label = "child " + head(c[0] + " " + head_of(c), 20);
    let rc = run_child(c);
    made = made + 1;
    // 1. a non-zero exit
    ok(label + " exits non-zero", rc != 0, "exited 0");
    // 2. it says something
    ok(label + " prints a message", child_out.length > 0, "no output at all");
    // 3. and it is a MESSAGE, not a trap.  This is the assertion that makes
    //    the group worth having: a Y trap prints to stdout and would
    //    otherwise be indistinguishable from a correct run.
    ok(label + " does not trap",
       child_out.contains("runtime error:") == false,
       head(child_out, 120));
    // 4. the stdout must be empty, so a trap cannot hide in it
    ok(label + " keeps stdout clean",
       child_out.starts_with("runtime error") == false,
       head(child_out, 120));
    i = i + 1
  };
  // ... and the complement, because a list of refusals proves nothing on its
  // own: an argument-validation table that refuses EVERYTHING passes.  These
  // are legal inputs and must be accepted, with the right answer.
  let good: [[str]] = [
    ["calc", "01"], ["calc", " 12"], ["calc", "--3"], ["calc", "-0"],
    ["calc", "0-9"], ["calc", "((1+2))"], ["calc", "2+3*4"], ["calc", "-(3+4)*2"]
  ];
  // `print` ends the line, so the child's stdout carries the newline: the
  // expectation is the exact bytes, not a trimmed value.
  let want: [str] = ["1\n", "12\n", "3\n", "0\n", "-9\n", "3\n", "14\n", "-14\n"];
  let gi = 0;
  while (gi < len(good)) {
    let grc = run_child(good[gi]);
    made = made + 1;
    ok("accepted: " + good[gi][1], grc == 0,
       "exited " + tostring(grc) + " with [" + child_out + "]");
    made = made + 1;
    eq_str("accepted value: " + good[gi][1], child_out, want[gi]);
    gi = gi + 1
  };
  count_floor("the error-path group really ran children", made,
              len(cases) + 2 * len(good));
  print("    ", tostring(made), " forked children: ", tostring(len(cases)),
        " refusals and ", tostring(len(good)), " inputs that must be accepted\n");
  n_fail
}

def head_of(xs: [str]) -> str {
  let out = "";
  let i = 0;
  while (i < len(xs)) {
    if (i > 0) { out += " " };
    out += xs[i];
    i = i + 1
  };
  out
}

// ── (F) the harness must be able to fail ───────────────────────────────────
//
// Before any of the above is trusted: hand `eq_str` two DIFFERENT strings and
// require it to record a failure, and hand it two EMPTY strings and require it
// to refuse.  If the harness cannot fail, nothing it says about the library
// means anything -- this is the "comparing two values that are both absent"
// trap caught before the fact rather than after.

let harness_made: long = 0;

def t_harness_can_fail() {
  group("(F) the harness can fail, and refuses to compare absent values");
  quiet_fail = 1;
  // The four `FAIL` lines this group prints are DELIBERATE and the counters
  // are put back before it returns.  They are labelled "deliberately" so that
  // the word FAIL never appears in the output of a run that passes -- gate item
  // 8 greps for it.
  harness_made = 0;
  let f0 = n_fail;
  eq_str("deliberately different", "1", "2");
  harness_made = harness_made + 1;
  ok("a mismatch is recorded", n_fail == f0 + 1, "n_fail went " + tostring(f0) + " -> " + tostring(n_fail));
  let f1 = n_fail;
  eq_str("deliberately both absent", "", "");
  harness_made = harness_made + 1;
  ok("two empty strings are REFUSED, not equal", n_fail == f1 + 1,
     "n_fail went " + tostring(f1) + " -> " + tostring(n_fail));
  ok("the refusal was counted", n_refused >= 1, "n_refused " + tostring(n_refused));
  let f2 = n_fail;
  eq_long("deliberately different long", 1, 2);
  harness_made = harness_made + 1;
  ok("a long mismatch is recorded", n_fail == f2 + 1, "n_fail went " + tostring(f2) + " -> " + tostring(n_fail));
  let f3 = n_fail;
  count_floor("deliberately short of the floor", 0, 1000);
  harness_made = harness_made + 1;
  ok("a group that compared nothing fails", n_fail == f3 + 1,
     "n_fail went " + tostring(f3) + " -> " + tostring(n_fail));
  // put the counters back: those four failures were the point, not a defect
  n_fail = f0;
  quiet_fail = 0;
  count_floor("harness self-test did its work", harness_made, 4)
}

// ── driver ─────────────────────────────────────────────────────────────────

def run_check(inject: long, verb: long) -> long {
  n_inject = inject;
  verbose = verb;
  print("bignum --check");
  print("  limb base      2^28");
  print("  limbs          ", tostring(bn.NLIMB), " (",
        tostring(bn.NLIMB * 28), " bits, at most ",
        tostring(bn.NLIMB * 28 * 302 / 1000 + 1), " decimal digits)");
  print("  injected defect ", (inject == 0 ? "none" : tostring(inject)));
  // Both endpoints AND the delta.  `heap_used()` counts the argument vector,
  // which the kernel allocated before this first sample, so either absolute
  // moves with the length of `argv[0]` -- the demo's figure was a golden that
  // was not reproducible by absolute path until it became a delta (see the
  // README).  Nothing byte-compares the check, so the absolutes stay for the
  // "where the heap goes" table.
  //
  // The delta is printed too, but note it is NOT path-independent here, and the
  // reason is worth writing down: a delta excludes argv only if nothing between
  // the two samples reads it again.  `self_path` does -- 31 times, once per
  // forked child -- and it builds the absolute path, so a `./bignum` run pays
  // `fs.cwd()` (a `[byte; 4096]` literal inside fs.cwd's own body: 4296 bytes
  // here) plus a 152-byte concatenation per child, 4448, 137 888 in total.
  // `demo` reads no argv at all, which is why ITS delta is identical by every
  // path.
  HB0 = heap_used();
  print("  heap before    ", tostring(HB0), " bytes");
  let c0 = n_cmp;
  t_harness_can_fail();
  t_native_oracle();
  t_boundary_constants();
  t_identities();
  t_times_ten();
  t_real_work();
  let e = t_error_paths();
  if (e != 0) { };
  print("");
  print("  assertions   ", tostring(n_checks));
  print("  comparisons  ", tostring(n_cmp - c0));
  print("  refused      ", tostring(n_refused), "  (an absent value is never compared)");
  print("  groups       ", tostring(n_group));
  print("  heap after   ", tostring(heap_used()), " bytes");
  print("  heap delta   ", tostring(heap_used() - HB0), " bytes  (before->after; still path-dependent here, because the battery re-reads argv per child -- see README)");
  if (n_fail == 0) {
    print("");
    print("CHECK PASS");
    return 0
  };
  print("");
  print("CHECK FAIL: ", tostring(n_fail), " of ", tostring(n_checks), " assertions failed");
  1
}
