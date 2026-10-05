// bignum.y -- arbitrary-precision integers over `long` limbs.
//
//   bignum demo      a worked demonstration; this is the golden run
//   bignum check     the property battery; no reference file involved
//   bignum calc EXPR a small infix evaluator, for poking at the library
//   bignum show N    the decimal expansion, bit count, limbs and sign of N
//   bignum OP A B    one operation: add sub mul div mod gcd cmp pow
//   bignum help      the whole interface
//
// Every operation whose operand pair or result overflows a native `long`
// refuses with a message and a non-zero exit instead of wrapping, so the
// demonstration of "bigger than 64 bits" can never be confused with a
// silently wrapped one.
//
// NOTHING here depends on the terminal, the clock, a random source or the
// network.  `demo` is a pure function of its arguments.  There is no
// vendored toolkit: this example needs no terminal, no framebuffer, no
// fixed-point maths and no flag parser, and `args.y` would be the only file
// it could have used.
//
// EXIT CODES
//   0  it worked
//   1  bad INPUT: a malformed number, a division by zero, a result too wide
//   2  bad USAGE: no such command, missing operand, unknown operation

import bn;
import check;

let VER = "bignum 1.0";

// ── the documented deterministic run ───────────────────────────────────────

def demo() -> long {
  // The heap figure printed at the end is a DELTA against this sample, and
  // that is deliberate.  `heap_used()` counts the argument vector, which the
  // kernel allocated at exec time -- before this first sample -- so an
  // absolute total moves with the length of the path you typed:
  // `./bignum` reported 398888 bytes and `/home/.../bignum` 398936, on
  // identical input.  A delta is also the more useful number: it is the cost
  // of the computation, not the cost of the process.  Same pattern as
  // `SUGGESTIONS.md` #7.
  let h0 = heap_used();
  print(VER, " -- arbitrary-precision signed integers on ", tostring(bn.NLIMB),
        " limbs of ", tostring(bn.BITS), " bits\n");
  print("base 2^", tostring(bn.BITS), " = ", tostring(bn.BASE),
        "; budget ", tostring(bn.NLIMB * bn.BITS), " bits = at most ",
        tostring(bn.NLIMB * bn.BITS * 302 / 1000 + 1), " decimal digits\n");
  print("");
  bn.bn_init();

  // -- 1. the machine and the library, agreeing bit for bit.
  print("[1] the same arithmetic twice: once on `long`, once on limbs\n");
  let pairs: [[long]] = [
    [1, 2], [7, 3], [0, 5], [-7, 3], [7, -3], [-7, -3],
    [268435455, 2], [268435456, 268435456], [268435457, 1],
    [123456789, 1000000007], [1000000007, 12345], [-1000000007, 12345]
  ];
  let i = 0;
  while (i < len(pairs)) {
    let a = pairs[i][0];
    let b = pairs[i][1];
    bn.bn_from_long(bn.S_A, a);
    bn.bn_from_long(bn.S_B, b);
    bn.bn_add(bn.S_C, bn.S_A, bn.S_B);
    bn.bn_mul(bn.S_D, bn.S_A, bn.S_B);
    let rc = bn.bn_divmod(bn.S_E, bn.S_F, bn.S_A, bn.S_B);
    print("    a=", tostring(a), " b=", tostring(b), "  a+b=", bn.bn_str(bn.S_C), " (long ", tostring(a + b), ")");
    print("        a*b=", bn.bn_str(bn.S_D), " (long ", tostring(a * b), ")");
    if (rc == 0) {
      print("        a/b=", bn.bn_str(bn.S_E), " a%b=", bn.bn_str(bn.S_F),
            " (long ", tostring(a / b), ", ", tostring(a % b), ")")
    };
    i = i + 1
  };
  print("");

  // -- 2. past the 64-bit line, where `long` cannot follow
  print("[2] past the 64-bit line: the boundary, and one constant\n");
  bn_from_pow2(bn.S_A, 64);
  bn_from_pow2(bn.S_B, 1000);
  bn_from_pow2(bn.S_F, 32);
  print("    2^64      = ", bn.bn_str(bn.S_A), "   (", tostring(bn.bn_bits(bn.S_A)),
        " bits, ", tostring(bn.bn_n(bn.S_A)), " limbs of ", tostring(bn.BITS), ")");
  // Every mutator returns a STATUS, never a slot, so each result is read in
  // its own statement.  Nesting one inside bn_str() compiles, runs and prints
  // "0" -- the status read as slot 0, which is S_ZERO.
  bn.bn_sub(bn.S_C, bn.S_A, bn.S_ONE);
  print("    2^64 - 1  = ", bn.bn_str(bn.S_C));
  bn.bn_add(bn.S_C, bn.S_A, bn.S_ONE);
  print("    2^64 + 1  = ", bn.bn_str(bn.S_C));
  bn.bn_div(bn.S_C, bn.S_A, bn.S_F);
  print("    2^64 / 2^32  = ", bn.bn_str(bn.S_C), "   (exact, so the limb crossing is clean)");
  bn.bn_mod(bn.S_C, bn.S_A, bn.S_F);
  print("    2^64 mod 2^32 = ", bn.bn_str(bn.S_C));
  print("    2^1000    = ", bn.bn_str(bn.S_B));
  print("               ", tostring(bn.bn_bits(bn.S_B)), " bits, ",
        tostring(bn.bn_dec(bn.S_B)), " digits, ", tostring(bn.bn_n(bn.S_B)), " limbs");
  bn.bn_sub(bn.S_C, bn.S_ZERO, bn.S_B);
  bn.bn_add(bn.S_C, bn.S_C, bn.S_B);
  print("    -(2^1000) + 2^1000 = ", bn.bn_str(bn.S_C), "   (exactly zero: ",
        (bn.bn_cmp(bn.S_C, bn.S_ZERO) == 0 ? "yes" : "NO"), ")");
  print("");

  // -- 3. real work: factoring numbers a native long cannot hold
  print("[3] real work: factoring numbers a native long cannot hold\n");
  // 2^64+1 = 274177 * 67280421310721.  The input does not fit a signed long,
  // and neither does the product of the two factors (2^46 x 2^18 = 2^64).
  let n1 = "18446744073709551617";
  bn.from_dec(bn.S_A, n1);
  print("    n1 = ", n1, "   = 2^64+1, ", tostring(bn.bn_bits(bn.S_A)),
        " bits -- past the largest signed long");
  // The outputs live in S_G/S_H/S_I because trial_divisor and pollard use
  // S_A..S_F as their own working slots: reading the first factor out of
  // S_B after a second call reads rho's tortoise, not the answer.
  let f = bn.S_G;
  let found = check.trial_divisor(f, n1);
  print("    trial division by 2,3,4,...   -> ", bn.bn_str(f), "   (found: ",
        tostring(found), ")");
  bn.bn_div(bn.S_C, bn.S_A, f);
  bn.bn_mul(bn.S_D, f, bn.S_C);
  print("    check: factor * (n/factor) == n  ->  ",
        (bn.bn_cmp(bn.S_D, bn.S_A) == 0 ? "yes" : "NO"), ", the cofactor is ",
        bn.bn_str(bn.S_C), " (", tostring(bn.bn_bits(bn.S_C)), " bits)");
  let n2 = "9999999999999999999999999999999886878647";
  bn.from_dec(bn.S_A, n2);
  print("");
  print("    n2 = ", n2, "   = 1048573 * 9536770448981615967605498138899139");
  print("          ", tostring(bn.bn_bits(bn.S_A)), " bits, ",
        tostring(bn.bn_dec(bn.S_A)), " digits");
  let g = bn.S_H;
  let found2 = check.pollard(g, n2, 2);
  print("    pollard rho, seed 2           -> ", bn.bn_str(g), "   (found: ",
        tostring(found2), ")");
  bn.bn_div(bn.S_C, bn.S_A, g);
  bn.bn_mul(bn.S_D, g, bn.S_C);
  print("    check: factor * (n/factor) == n  ->  ", bn.bn_str(bn.S_D), "  (",
        (bn.bn_cmp(bn.S_D, bn.S_A) == 0 ? "yes" : "NO"), ")");
  // Same number, same seed, a second time.  rho has no clock and no random
  // source, so this has to come back with the identical factor.
  let g2 = bn.S_I;
  check.pollard(g2, n2, 2);
  print("    check: the same seed gives the same factor  ->  ",
        (bn.bn_cmp(g2, g) == 0 ? "yes" : "NO"));
  print("");

  // -- 4. modular arithmetic, cross-checked the other way round
  print("[4] modular exponentiation, two independent routes to one answer\n");
  bn.from_dec(bn.S_C, "1000000007");
  // route one: square and multiply, from the constant 2
  let rc = bn.bn_powmod(bn.S_D, bn.S_TWO, 1000, bn.S_C);
  print("    2^1000 mod 1000000007, by square-and-multiply  = ", bn.bn_str(bn.S_D),
        "   (rc ", tostring(rc), ")");
  // route two: 1000 modular doublings of a running product
  bn.bn_copy(bn.S_E, bn.S_ONE);
  let k = 0;
  while (k < 1000) {
    bn.bn_mul(bn.S_E, bn.S_E, bn.S_TWO);
    bn.bn_mod(bn.S_E, bn.S_E, bn.S_C);
    k = k + 1
  };
  print("    2^1000 mod 1000000007, by 1000 doublings         = ", bn.bn_str(bn.S_E));
  print("    the two routes agree  ->  ",
        (bn.bn_cmp(bn.S_D, bn.S_E) == 0 ? "yes" : "NO"));
  // Fermat: 2^(p-1) mod p == 1 for prime p.  p = 2^30+3 = 1073741827, which is
  // prime (and 2^30+1 is not, which is why it is written down this way).
  bn_from_pow2(bn.S_A, 30);
  bn.bn_add(bn.S_A, bn.S_A, bn.S_ONE);
  bn.bn_add(bn.S_A, bn.S_A, bn.S_TWO);     // 2^30 + 3 = 1073741827, prime
  bn.bn_sub(bn.S_F, bn.S_A, bn.S_ONE);
  let e = bn.bn_to_long(bn.S_F);           // the exponent VALUE, not a slot
  bn.bn_powmod(bn.S_D, bn.S_TWO, e, bn.S_A);
  print("");
  print("    2^(p-1) mod p for the prime p = ", tostring(bn.bn_to_long(bn.S_A)),
        "  -> ", bn.bn_str(bn.S_D), "  (Fermat: ",
        (bn.bn_cmp(bn.S_D, bn.S_ONE) == 0 ? "holds" : "FAILS"), ")");
  // 561 is a Carmichael number, where Fermat ALSO holds -- which is exactly
  // why one Fermat test is not a primality test.  Both facts are asserted in
  // `bignum check`.
  bn.from_dec(bn.S_A, "561");
  bn.bn_powmod(bn.S_D, bn.S_TWO, 560, bn.S_A);
  print("    2^(n-1) mod n for n = 561       -> ", bn.bn_str(bn.S_D),
        "  (a Carmichael number: ",
        (bn.bn_cmp(bn.S_D, bn.S_ONE) == 0 ? "also holds" : "differs"),
        " -- so Fermat alone does not prove primality)");
  print("");

  // -- 5. the shape on the heap
  print("[5] shape: the limbs of 2^1000, little-endian, and the budget\n");
  bn_from_pow2(bn.S_A, 1000);
  // One line, not one print per limb: `print` appends a newline to every
  // call, so a loop of prints is a column, not a row.
  let row = "    limbs: ";
  let i2 = 0;
  while (i2 < bn.bn_n(bn.S_A)) {
    if (i2 > 0) { row += ", " };
    row += tostring(bn.bn_lim(bn.S_A, i2));
    i2 = i2 + 1
  };
  print(row, "\n");
  print("    ", tostring(bn.bn_n(bn.S_A)), " limbs of ", tostring(bn.BITS),
        " bits = ", tostring(bn.bn_bits(bn.S_A)), " bits; budget ",
        tostring(bn.NLIMB * bn.BITS), " bits in ", tostring(bn.NLIMB), " slots");
  print("    the pool is ", tostring(bn.NSLOT), " slots of ", tostring(bn.SLIMB),
        " limbs = ", tostring(bn.NSLOT * bn.SLIMB * 8), " bytes of limbs, grown once");
  print("    heap this demo allocated: ", tostring(heap_used() - h0),
        " bytes (a delta -- an absolute would also count argv, so it would",
        "\n    move with the length of the path you ran this by)");
  print("");
  print("`bignum --stats demo` adds timings on stderr; `bignum check` runs the ",
        "property battery.  Neither is needed to see anything above.");
  0
}

// bn_from_pow2(s, k) -- s = 2^k.  The 1 goes in scratch slot S_I, not in S_A:
// an earlier version seeded S_A unconditionally, so calling it with s = S_B
// still reset S_A to 1 and the demo then printed "2^64 = 1".
def bn_from_pow2(s: long, k: long) -> long {
  bn.bn_from_long(bn.S_I, 1);
  bn.bn_shl(s, bn.S_I, k)
}

// ── one-operation interface ────────────────────────────────────────────────

def usage() {
  print(VER, "\n");
  print("usage: bignum COMMAND [ARGS]\n");
  print("  demo                 a worked demonstration (the golden run)\n");
  print("  check [--verbose]    the property battery, no reference file\n");
  print("  check --inject N     re-run the battery with a named defect in it\n");
  print("  calc EXPR            an infix expression over + - * / % ( ) and integers\n");
  print("  show N               decimal, bits, limbs, sign and fits-64-bits of N\n");
  print("  OP A B               OP is add sub mul div mod gcd cmp pow\n");
  print("  help | version\n");
  print("\nexit codes: 0 ok, 1 bad input (including division by zero), 2 bad usage\n");
  print("numbers may be decimal, or 0x hex, or 0b binary\n")
}

def parse_int(text: str, out: [long]) -> long {
  // 0 = fine.  1 = not an integer at all.  2 = does not fit in a `long`.
  let n = text.length;
  if (n == 0) { return 1 };
  let i = 0;
  let sgn = 0;
  if (text[0] == 45) { sgn = 1; i = 1 };
  if (i >= n) { return 1 };
  let base = 10;
  if (i + 1 < n && text[i] == 48) {
    if (text[i + 1] == 120 || text[i + 1] == 88) { base = 16; i = i + 2 }
    else if (text[i + 1] == 98 || text[i + 1] == 66) { base = 2; i = i + 2 }
  };
  if (i >= n) { return 1 };
  let v = 0;
  while (i < n) {
    let c = text[i] + 0;
    let dv = 0;
    if (c >= 48 && c <= 57) { dv = c - 48 }
    else if (c >= 97 && c <= 102) { dv = c - 97 + 10 }
    else if (c >= 65 && c <= 70) { dv = c - 65 + 10 }
    else { return 1 };
    if (dv >= base) { return 1 };
    let t2 = v * base + dv;
    if (t2 < v) { return 2 };          // wrapped: too big for a long
    v = t2;
    i = i + 1
  };
  out[0] = (sgn == 1) ? (0 - v) : v;
  0
}

def parse_bignum(s: long, text: str) -> long {
  // 0 fine, 1 malformed, 2 too wide for the limb budget
  let rc = bn.from_dec(s, text);
  if (rc != 0) { return rc };
  if (bn.bn_bits(s) > bn.NLIMB * bn.BITS) { return 2 };
  0
}

def do_op(op: str, atext: str, btext: str) -> long {
  let pa: [long] = [0];
  let pb: [long] = [0];
  let rca = parse_int(atext, pa);
  if (rca != 0) { eputs("bignum: operand is not an integer in a 64-bit range: " + atext + "\n"); return 1 };
  let rcb = parse_int(btext, pb);
  if (rcb != 0) { eputs("bignum: operand is not an integer in a 64-bit range: " + btext + "\n"); return 1 };
  bn.bn_from_long(bn.S_A, pa[0]);
  bn.bn_from_long(bn.S_B, pb[0]);
  let rc = 0;
  if (op == "add") { rc = bn.bn_add(bn.S_C, bn.S_A, bn.S_B) }
  else if (op == "sub") { rc = bn.bn_sub(bn.S_C, bn.S_A, bn.S_B) }
  else if (op == "mul") { rc = bn.bn_mul(bn.S_C, bn.S_A, bn.S_B) }
  else if (op == "div") { rc = bn.bn_divmod(bn.S_C, bn.S_D, bn.S_A, bn.S_B); if (rc == 1) { eputs("bignum: division by zero\n"); return 1 } }
  else if (op == "mod") { rc = bn.bn_divmod(bn.S_D, bn.S_C, bn.S_A, bn.S_B); if (rc == 1) { eputs("bignum: modulo by zero\n"); return 1 } }
  else if (op == "gcd") { rc = bn.bn_gcd(bn.S_C, bn.S_A, bn.S_B) }
  else if (op == "pow") {
    if (pb[0] < 0) { eputs("bignum: a negative exponent is not supported\n"); return 1 };
    rc = bn.bn_pow(bn.S_C, bn.S_A, pb[0])
  }
  else if (op == "cmp") {
    let c = bn.bn_cmp(bn.S_A, bn.S_B);
    print(tostring(c));
    return 0
  }
  else { eputs("bignum: unknown operation '" + op + "'\n"); return 2 };
  if (rc == 1) { eputs("bignum: division by zero\n"); return 1 };
  // The bound a multiply can actually enforce is the SLOT's width (SLIMB
  // limbs), not the budget NLIMB.  bn_shl refuses at NLIMB and a multiply at
  // SLIMB, so quoting NLIMB here would be a diagnostic that describes the
  // wrong number.
  if (rc != 0) { eputs("bignum: the result does not fit in " + tostring(bn.SLIMB * bn.BITS) + " bits\n"); return 1 };
  print(bn.bn_str(bn.S_C));
  0
}

def show(text: str) -> long {
  let rc = parse_bignum(bn.S_A, text);
  if (rc == 1) { eputs("bignum: not a decimal integer: " + text + "\n"); return 1 };
  if (rc != 0) { eputs("bignum: too many digits, the limit is " + tostring(bn.NLIMB * 9) + "\n"); return 1 };
  print("value   ", bn.bn_str(bn.S_A), "\n");
  print("sign    ", (bn.bn_neg(bn.S_A) == 1 ? "-1" : "+1"), "\n");
  print("bits    ", tostring(bn.bn_bits(bn.S_A)), "\n");
  print("limbs   ", tostring(bn.bn_n(bn.S_A)), " of base 2^", tostring(bn.BITS), "\n");
  print("digits  ", tostring(bn.bn_dec(bn.S_A)), "\n");
  print("fits64  ", (bn.bn_fits(bn.S_A) ? "yes" : "no"), "\n");
  let i = 0;
  print("limbs   ");
  while (i < bn.bn_n(bn.S_A)) {
    print(tostring(bn.bn_lim(bn.S_A, i)));
    if (i < bn.bn_n(bn.S_A) - 1) { print(" ") };
    i = i + 1
  };
  print("\n");
  0
}

// ── a small infix evaluator, so `calc` can reach every operator ────────────
//
// Recursive descent over a module-level cursor: parse_expr calls parse_primary
// which calls parse_expr for the parenthesised case.  Recursion is `self`,
// not the function's own name.  Every error is a message and a non-zero exit
// on stderr -- nothing here can trap, which matters because a Y trap prints
// to STDOUT and would splice itself into a golden diff.
//
// The previous version of this was a hand-rolled operator stack and it was
// wrong in the way this whole example is about: `1/0` trapped with
// "runtime error: index out of bounds", printed on stdout, and exited 1 --
// which looks like a *correct* division-by-zero refusal unless you read the
// first line.  The error-path group of `bignum check` exists to catch exactly
// that, and it did.

// Two explicit stacks and a `reduce once` step -- the textbook shunting yard,
// no recursion and no `self`.  Operator codes: 0 +, 1 -, 2 *, 3 /, 4 %,
// 5 unary minus, -1 is the "(" marker (never reduced, only popped).
let CTXT: str = "";
let CPOS: long = 0;
let CERR: long = 0;
let CV: [long] = [];
let CVN: long = 0;
let CO: [long] = [];
let CON: long = 0;

// The two stacks are one array plus a top index.  The array is GROWN on
// demand and the value goes at CV[top], so index 0 is the BOTTOM: appending
// with `+=` and then reading CV[top] would pop from the front, which is the
// bug an earlier version of this file had -- `2+3*4` came out as 2.
def cvpush(v: long) -> long {
  if (CVN < CV.length) { CV[CVN] = v } else { CV += v };
  CVN = CVN + 1;
  0
}
def copush(o: long) -> long {
  if (CON < CO.length) { CO[CON] = o } else { CO += o };
  CON = CON + 1;
  0
}
def cvpop() -> long {
  if (CVN == 0) { return 0 - 1 };
  CVN = CVN - 1;
  CV[CVN]
}
def copop() -> long {
  if (CON == 0) { return 0 - 1 };
  CON = CON - 1;
  CO[CON]
}
// Unary minus binds TIGHTER than both binary levels.  Leaving it out of the
// precedence table is what made `-5+8` come out as -13: the pending unary
// minus sat below the '+' and was reduced last, negating the whole sum.
def cprec(o: long) -> long {
  if (o == 5) { return 3 };
  if (o == 2 || o == 3 || o == 4) { return 2 };
  1
}

// capply(a, op, b) -> long -- one operation, with the division-by-zero test
// in the one place it belongs rather than at four call sites.
def capply(a: long, op: long, b: long) -> long {
  if ((op == 3 || op == 4) && b == 0) {
    eputs("bignum: division by zero in '" + CTXT + "'\n");
    return 0 - 1
  };
  bn.bn_from_long(bn.S_A, a);
  bn.bn_from_long(bn.S_B, b);
  let rc = 0;
  if (op == 0) { rc = bn.bn_add(bn.S_A, bn.S_A, bn.S_B) }
  else if (op == 1) { rc = bn.bn_sub(bn.S_A, bn.S_A, bn.S_B) }
  else if (op == 2) { rc = bn.bn_mul(bn.S_A, bn.S_A, bn.S_B) }
  else if (op == 3) { rc = bn.bn_div(bn.S_A, bn.S_A, bn.S_B) }
  else { rc = bn.bn_mod(bn.S_A, bn.S_A, bn.S_B) };
  if (rc == 1) { eputs("bignum: division by zero in '" + CTXT + "'\n"); return 0 - 1 };
  if (rc != 0) { eputs("bignum: calc: the result does not fit in a 64-bit long\n"); return 0 - 1 };
  if (!bn.bn_fits(bn.S_A)) {
    eputs("bignum: calc: the result does not fit in a 64-bit long (calc is 64-bit by design)\n");
    return 0 - 1
  };
  bn.bn_to_long(bn.S_A)
}

// creduce() -> long -- pop one operator and apply it.  0 = fine, -1 = error.
def creduce() -> long {
  let op = copop();
  if (op == 0 - 1) { return 0 - 1 };
  if (op == 5) {                       // unary minus: one operand
    let a = cvpop();
    if (a == 0 - 1) { return cbad("a unary minus with nothing after it") };
    bn.bn_from_long(bn.S_A, a);
    bn.bn_sub(bn.S_A, bn.S_ZERO, bn.S_A);
    cvpush(bn.bn_to_long(bn.S_A));
    return 0
  };
  let b = cvpop();
  let a = cvpop();
  // Which of the two is missing is genuinely ambiguous once the expression is
  // malformed, so the message does not pretend to know.
  if (a == 0 - 1 || b == 0 - 1) { return cbad("an operator is missing an operand") };
  let v = capply(a, op, b);
  if (v == 0 - 1) { return 0 - 1 };
  cvpush(v);
  0
}

def cbad(why: str) -> long {
  if (CERR == 0) {
    eputs("bignum: calc: " + why + " at character " + tostring(CPOS) + "\n")
  };
  CERR = 1;
  0 - 1
}

def cskip() -> long {
  let go = CPOS < CTXT.length && CTXT[CPOS] == 32;
  while (go) { CPOS = CPOS + 1; go = CPOS < CTXT.length && CTXT[CPOS] == 32 };
  0
}

def calc(text: str) -> long {
  CTXT = text;
  CPOS = 0;
  CERR = 0;
  CVN = 0;
  CON = 0;
  if (text.length == 0) { eputs("bignum: calc: empty expression\n"); return 1 };
  let i = 0;
  let n = text.length;
  // want_op is the shunting yard's "an operator may appear here" flag, which is
  // what makes unary minus work without a second pass.
  let want_op = true;
  while (i < n && CERR == 0) {
    let c = text[i];
    if (c == 32) { i = i + 1 }
    else if (c >= 48 && c <= 57) {
      if (!want_op) { cbad("two numbers in a row") };
      let s = "";
      let more = true;
      while (more) {
        more = i < n && text[i] >= 48 && text[i] <= 57;
        if (more) { s += chr(text[i]); i = i + 1 }
      };
      let out: [long] = [0];
      let r = parse_int(s, out);
      if (r != 0) { cbad("'" + s + "' is not an integer in a 64-bit range") }
      else { cvpush(out[0]); want_op = false }
    }
    else if (c == 40) { copush(0 - 1); i = i + 1 }
    else if (c == 41) {
      let go = CON > 0 && CO[CON - 1] != 0 - 1;
      while (go) {
        if (creduce() != 0) { CERR = 1; go = false }
        else { go = CON > 0 && CO[CON - 1] != 0 - 1 }
      };
      if (CERR == 0) {
        if (CON == 0) { cbad("unbalanced )") }
        else { copop(); want_op = false }
      };
      i = i + 1
    }
    else if (c == 45 && want_op) { copush(5); i = i + 1 }
    else if (c == 43 || c == 45 || c == 42 || c == 47 || c == 37) {
      let code = (c == 43) ? 0 : ((c == 45) ? 1 : ((c == 42) ? 2 : ((c == 47) ? 3 : 4)));
      // left-associative: reduce everything of at least this precedence first
      let go = CON > 0 && CO[CON - 1] != 0 - 1 &&
               cprec(CO[CON - 1]) >= cprec(code);
      while (go) {
        if (creduce() != 0) { CERR = 1; go = false }
        else {
          go = CON > 0 && CO[CON - 1] != 0 - 1 &&
               cprec(CO[CON - 1]) >= cprec(code)
        }
      };
      if (CERR == 0) { copush(code); want_op = true };
      i = i + 1
    }
    else { cbad("unexpected character '" + chr(c) + "'") }
  };
  if (CERR == 0) {
    // Stop at a "(" marker rather than reducing it: `creduce` returns a bare
    // -1 for the marker, which used to end the loop with CERR set and NO
    // message, so `calc '6*(2+'` exited 1 silently -- the one shape of bad
    // input that looks like a success to anything reading only the exit code
    // and the stdout.
    let go = CON > 0 && CO[CON - 1] != 0 - 1;
    while (go) {
      if (creduce() != 0) { CERR = 1; go = false }
      else { go = CON > 0 && CO[CON - 1] != 0 - 1 }
    }
  };
  if (CERR != 0) { return 1 };
  if (CON != 0) { eputs("bignum: calc: unbalanced (\n"); return 1 };
  if (CVN != 1) { eputs("bignum: calc: the expression is not a single value\n"); return 1 };
  print(tostring(CV[CVN - 1]));
  0
}

// ── --stats: timings on stderr, so stdout stays byte-identical ─────────────

def stats_dispatch(rest: [str]) -> long {
  if (len(rest) < 2) { eputs("bignum: --stats needs a command\n"); return 2 };
  let cmd = rest[1];
  if (cmd == "demo") {
    let t0 = clock_us();
    let h0 = heap_used();
    let r = demo();
    let t1 = clock_us();
    let h1 = heap_used();
    eputs("demo: " + tostring(t1 - t0) + " us + heap +" + tostring(h1 - h0) + " bytes\n");
    // the same work again, timed in pieces
    bn_from_pow2(bn.S_A, 1000);
    let t2 = clock_us();
    let reps = 2000;
    let j = 0;
    while (j < reps) { bn.bn_mul(bn.S_C, bn.S_A, bn.S_A); j = j + 1 };
    let t3 = clock_us();
    eputs("mul: " + tostring(reps) + " squarings of a " + tostring(bn.bn_n(bn.S_A)) +
          "-limb number in " + tostring(t3 - t2) + " us = " +
          tostring((t3 - t2) * 1000 / reps) + " ns each\n");
    let t4 = clock_us();
    j = 0;
    while (j < reps) { bn.bn_add(bn.S_D, bn.S_A, bn.S_A); j = j + 1 };
    let t5 = clock_us();
    eputs("add: " + tostring(reps) + " additions of a " + tostring(bn.bn_n(bn.S_A)) +
          "-limb number in " + tostring(t5 - t4) + " us = " +
          tostring((t5 - t4) * 1000 / reps) + " ns each\n");
    let t6 = clock_us();
    bn.from_dec(bn.S_E, "18446744073709551617");
    j = 0;
    while (j < 200) { check.trial_divisor(bn.S_F, "18446744073709551617"); j = j + 1 };
    let t7 = clock_us();
    eputs("trial division to 274177: 200 runs in " + tostring(t7 - t6) + " us = " +
          tostring((t7 - t6) * 1000 / 200) + " ns each\n");
    return r
  };
  if (cmd == "check") {
    let t0 = clock_us();
    let r = check.run_check(0, 0);
    eputs("check: " + tostring(clock_us() - t0) + " us\n");
    return r
  };
  eputs("bignum: --stats understands only `demo` and `check`\n");
  2
}

// ── dispatch ───────────────────────────────────────────────────────────────

// STATS is set by `--stats`, which prints timings on STDERR.  Nothing
// time-dependent is ever allowed into the golden run, so the flag is what
// keeps `demo` deterministic while still letting anybody measure it.
let STATS: long = 0;

def main() -> long {
  bn.bn_init();
  // `let av = argv()` and then `av[0]`/`av[1]`, never `argv().length` in a
  // condition: `argv().length` compiles, runs and SEGFAULTS, because the only
  // read of argv is then its length and the tree shaker drops the argv
  // initialiser while the emitter still calls the runtime helper.  Filed in
  // examples/BUGS.md; see the note above `self_path` in check.y too.
  let av = argv();
  if (len(av) >= 2 && (av[1] == "--stats" || av[1] == "-S")) {
    STATS = 1;
    let rest: [str] = [];
    let i = 1;
    while (i < len(av)) { rest += av[i]; i = i + 1 };
    return stats_dispatch(rest)
  };
  if (len(av) < 2) {
    eputs("bignum: no command\n\n");
    usage();
    return 2
  };
  let cmd = av[1];
  if (cmd == "help" || cmd == "-h" || cmd == "--help") { usage(); return 0 };
  if (cmd == "version" || cmd == "--version") { print(VER, "\n"); return 0 };
  if (cmd == "demo") { return demo() };
  if (cmd == "check") {
    let inject = 0;
    let verb = 0;
    let i = 2;
    while (i < len(av)) {
      let a = av[i];
      if (a == "--verbose" || a == "-v") { verb = 1 }
      else if (a == "--inject") {
        if (i + 1 >= len(av)) { eputs("bignum: --inject needs a number\n"); return 2 };
        let out: [long] = [0];
        let r = parse_int(av[i + 1], out);
        if (r != 0) { eputs("bignum: --inject wants a number\n"); return 2 };
        inject = out[0];
        i = i + 1
      }
      else if (a.starts_with("--inject=")) {
        let out: [long] = [0];
        let r = parse_int(a[9:a.length], out);
        if (r != 0) { eputs("bignum: --inject= wants a number\n"); return 2 };
        inject = out[0]
      }
      else { eputs("bignum: check: unknown flag '" + a + "'\n"); return 2 };
      i = i + 1
    };
    bn.INJECT = inject;
    return check.run_check(inject, verb)
  };
  if (cmd == "calc") {
    if (len(av) != 3) { eputs("bignum: calc needs one expression\n"); return 2 };
    return calc(av[2])
  };
  if (cmd == "show") {
    if (len(av) != 3) { eputs("bignum: show needs one number\n"); return 2 };
    return show(av[2])
  };
  if (cmd == "errorpaths") {
    // Group (E) on its own, so the forked children can be watched.  `check`
    // runs it anyway; this exists because the whole group is 30 processes and
    // when it hangs you want to be able to run just it.
    let e = check.t_error_paths();
    if (e == 0) { return 0 };
    return 1
  };
  if (cmd == "nope") { eputs("bignum: unknown command '" + cmd + "'\n\n"); usage(); return 2 };
  if (len(av) != 4) { eputs("bignum: '" + cmd + "' needs exactly two operands\n"); return 2 };
  return do_op(cmd, av[2], av[3])
}; exit(main())