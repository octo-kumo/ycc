// gexp.y -- y_exp, the routine test/y/native/t311_math_exp_asm.y gates
// (`ytest math-gen exp [STAGE]`).
//
// STAGE is `full` (the whole routine) or one of n/r/P/v, which returns that
// intermediate instead of the answer -- how a divergence gets localised: return
// the reduction's r, or the kernel, or v, and compare against the Y version's
// own value at that point. Four probes found four bugs in the first attempt.
//
// To land a change to exp: edit src/y/std/math.y, run `ytest math-gen exp`,
// write the result over the y_exp block in src/y/arch/math.s, and run t311.
//
// Every constant and coefficient is READ OUT of src/y/std/math.y rather than
// copied: the whole constraint is that the assembly return the same double as
// the Y. The operation sequence mirrors the Y line for line, because that is
// what makes the bits match:
//   n = to_int(floor(x*log2e + 0.5))   -> one cvttsd2si, one correction, cvtsi2sd
//   r = (x - nf*ln2_hi) - nf*ln2_lo    -> two multiplies, two subtracts
//   P = poly_split(exp_k, exp_kl, r)   -> two Horner chains, hi and lo, then p + q
//   v = f2 * (1 + r*(1 + r*P))         -> as written
//   ldexp(v, k)                        -> as written, big steps then the field,
//                                         then a doubling loop for a subnormal
import math;
import mgen;

let W = mgen.writer();

def w(s: str) { mgen.w(W, s) };

// The kernel's two halves, after the ten constants.
def ko(n: long) -> long { 8 * (10 + n) };
def klo(n: long) -> long { 8 * (23 + n) };

def gen(stage: str) -> str {
    W = mgen.writer();
    let src = mgen.src();
    let exp_k = mgen.let_floats(src, "exp_k");
    let exp_kl = mgen.let_floats(src, "exp_kl");
    if (exp_k.length != 13 || exp_kl.length != 13) { mgen.die("exp_k/exp_kl: 13 coefficients each"); };
    // A sanity check that the parse is right, before anything is emitted: the
    // same Horner in the same order must land within an ulp of exp(r).
    foreach (r in [0.0, 0.1, -0.2, 0.34657359027997264]) {
        let p = exp_k[12];
        let q = exp_kl[12];
        let k = 11;
        while (k >= 0) {
            p = p * r + exp_k[k];
            q = q * r + exp_kl[k];
            k -= 1;
        };
        let got = 1.0 + r * (1.0 + r * (p + q));
        let want = math.exp(r);
        if (math.fabs(got - want) > 4e-16 * math.fmax(1.0, math.fabs(want))) { mgen.die("exp_k mis-parsed"); };
    };
    // One label, one block: the offsets the routine reads, in table order.
    let names = ["ehi", "elo", "l2e", "ln2h", "ln2l", "half", "one", "two", "p1022", "n1022"];
    let vals = [mgen.let_float(src, "exp_hi"), mgen.let_float(src, "exp_lo"), mgen.let_float(src, "log2e"),
        mgen.let_float(src, "ln2_hi"), mgen.let_float(src, "ln2_lo"), 0.5, 1.0, 2.0,
        // ldexp's big up and down steps
        4.49423283715578977e307, 2.2250738585072014e-308];
    let k = 0;
    while (k < 13) { names += "k" + tostring(k); vals += exp_k[k]; k += 1; };
    k = 0;
    while (k < 13) { names += "kl" + tostring(k); vals += exp_kl[k]; k += 1; };
    let off_ehi = 0;
    let off_elo = 8;
    let off_l2e = 16;
    let off_ln2h = 24;
    let off_ln2l = 32;
    let off_half = 40;
    let off_one = 48;
    let off_two = 56;
    let off_2p = 64;
    let off_2n = 72;

    // Registers: xmm0 scratch, xmm1 nf, xmm2 x (then r), xmm3 scratch, xmm4 p,
    // xmm5 q, xmm6 f2, xmm7 spare. GPRs: rax the answer's bits / the long n,
    // rcx k, rdx the exponent field, r8 scratch.
    w("# y_exp: exp(x). Generated from src/y/std/math.y's exp by");
    w("# `ytest math-gen exp`, which reads its own constants -- do not retype");
    w("# the table, because the whole constraint is that this returns the same double");
    w("# as that function, and a table typed by hand can disagree with it silently.");
    w("#");
    w("# The operation sequence is the Y line for line, which is what makes the bits");
    w("# match: the same multiplies and subtracts in the same order, the same two");
    w("# Horner chains for the split kernel, the same ldexp including its big steps");
    w("# and its doubling loop for a subnormal answer. `t310`-style: the oracle is");
    w("# math.exp itself and every call site compares bits.");
    w("#");
    w("# Argument at 8(%rsp) (the last and only one), answer's bits in %rax.");
    w("y_exp:");
    w("    mov 8(%rsp), %rax");
    w("    movq %rax, %xmm2                   # xmm2 = x, kept for the reduction");
    w("    movq %xmm2, %xmm0");
    w("# if (x != x) return x: the operand compared with itself is unordered exactly");
    w("# when it is a NaN, and unordered is the only answer with PF set.");
    w("    ucomisd %xmm2, %xmm2");
    w("    jp yexp_ret");
    w("# if (x > exp_hi) return +inf");
    w("    ucomisd yexp_tab+" + tostring(off_ehi) + "(%rip), %xmm2");
    w("    ja yexp_inf");
    w("# if (x < exp_lo) return +0.0");
    w("    ucomisd yexp_tab+" + tostring(off_elo) + "(%rip), %xmm2");
    w("    jb yexp_zero");
    w("");
    w("# n = to_int(floor(x*log2e + 0.5)). The truncating convert is a floor only");
    w("# when the value it truncated was already at or below the integer; one less");
    w("# when the truncation rounded UP, which is when the truncated value is");
    w("# GREATER than what it came from -- a negative argument, or one in 1.0..1.5.");
    w("    mulsd yexp_tab+" + tostring(off_l2e) + "(%rip), %xmm0");
    w("    addsd yexp_tab+" + tostring(off_half) + "(%rip), %xmm0    # t = x*log2e + 0.5");
    w("    cvttsd2si %xmm0, %rax              # trunc(t)");
    w("    cvtsi2sd %rax, %xmm1");
    w("    ucomisd %xmm0, %xmm1              # trunc(t) against t");
    w("    jbe yexp_k_ok");
    w("    sub $1, %rax                       # it rounded up: one less");
    w("yexp_k_ok:");
    w("    cvtsi2sd %rax, %xmm1               # xmm1 = nf");
    w("");
    w("# r = (x - nf*ln2_hi) - nf*ln2_lo: ln2 in two pieces so the reduction keeps");
    w("# the low bits, which is what one rounding of nf*ln2 would have lost.");
    w("    movsd %xmm1, %xmm3");
    w("    mulsd yexp_tab+" + tostring(off_ln2h) + "(%rip), %xmm3");
    w("    subsd %xmm3, %xmm2");
    w("    movsd %xmm1, %xmm3");
    w("    mulsd yexp_tab+" + tostring(off_ln2l) + "(%rip), %xmm3");
    w("    subsd %xmm3, %xmm2                # xmm2 = r");
    w("");
    w("# k and f2: 2^1024 is an overflow and round(x*log2e) reaches 1024 for every x");
    w("# above 709.4, so the last whole ln2 stays in r and its factor of two is put");
    w("# in by hand -- which also keeps r inside the kernel's range.");
    w("    mov %rax, %rcx                     # rcx = k");
    w("    movsd yexp_tab+" + tostring(off_one) + "(%rip), %xmm6    # f2 = 1.0");
    w("    cmp $1023, %rcx");
    w("    jle yexp_f2_ok");
    w("    sub $1, %rcx");
    w("    movsd yexp_tab+" + tostring(off_two) + "(%rip), %xmm6    # f2 = 2.0");
    w("yexp_f2_ok:");
    if (stage == "n") {
        w("    movq %xmm1, %rax");
        w("    ret");
    };
    w("");
    w("# P = poly_split(exp_k, exp_kl, r): two Horner chains over the split table,");
    w("# so a term whose low part would fall off the end of a double is kept, and");
    w("# one add at the end brings the two halves together.");
    w("    movsd yexp_tab+" + tostring(ko(12)) + "(%rip), %xmm4");
    w("    movsd yexp_tab+" + tostring(klo(12)) + "(%rip), %xmm5");
    let i = 11;
    while (i > -1) {
        w("    mulsd %xmm2, %xmm4");
        w("    addsd yexp_tab+" + tostring(ko(i)) + "(%rip), %xmm4");
        w("    mulsd %xmm2, %xmm5");
        w("    addsd yexp_tab+" + tostring(klo(i)) + "(%rip), %xmm5");
        i -= 1;
    };
    w("    addsd %xmm5, %xmm4");
    if (stage == "r") {
        w("    movq %xmm2, %rax");
        w("    ret");
    };
    if (stage == "P") {
        w("    movq %xmm4, %rax");
        w("    ret");
    };
    w("");
    w("# v = f2 * (1 + r*(1 + r*P))");
    w("    movsd %xmm2, %xmm3");
    w("    mulsd %xmm4, %xmm3");
    w("    addsd yexp_tab+" + tostring(off_one) + "(%rip), %xmm3");
    w("    mulsd %xmm2, %xmm3");
    w("    addsd yexp_tab+" + tostring(off_one) + "(%rip), %xmm3");
    w("    mulsd %xmm6, %xmm3");
    if (stage == "v") {
        w("    movq %xmm3, %rax");
        w("    ret");
    };
    w("");
    // %rdx is the value, the way `r` is the variable in the Y: the big steps and the
    // field shift all work on it and the answer is in it at the end. Doing it any
    // other way means one of the paths returns the value from BEFORE its own step --
    // which is what the first version did, and the symptom was exp(1) coming back as
    // e^r with the 2^k simply missing.
    w("# ldexp(v, k), as written in std/math.y: the big steps first, so that after");
    w("# them the answer may already be 0 or an infinity and there is nothing left");
    w("# to do exactly. 2^1022 rather than 2^1023: one more step than the range");
    w("# needs, so a step never overflows on its own.");
    w("    movq %xmm3, %rdx                   # rdx = the value");
    w("    cmp $1022, %rcx");
    w("    jl yexp_ld_up_done");
    w("    movq %rdx, %xmm4");
    w("    mulsd yexp_tab+" + tostring(off_2p) + "(%rip), %xmm4");
    w("    movq %xmm4, %rdx");
    w("    sub $1022, %rcx");
    w("yexp_ld_up_done:");
    w("    cmp $-1022, %rcx");
    w("    jg yexp_ld_dn_done");
    w("    movq %rdx, %xmm4");
    w("    mulsd yexp_tab+" + tostring(off_2n) + "(%rip), %xmm4");
    w("    movq %xmm4, %rdx");
    w("    add $1022, %rcx");
    w("yexp_ld_dn_done:");
    w("# f = exp_field(r) = the pattern's exponent field");
    w("    mov %rdx, %rax");
    w("    shr $52, %rax");
    w("    and $2047, %rax");
    w("# if (f == 0 || f + k < 1) the mantissa has to shift too, and one doubling at");
    w("# a time is how that is exact -- which is also the subnormal case, where the");
    w("# field is 0 and every step is a doubling.");
    w("    test %rax, %rax");
    w("    jz yexp_ld_shift");
    w("    mov %rax, %r8");
    w("    add %rcx, %r8");
    w("    cmp $1, %r8");
    w("    jl yexp_ld_shift");
    w("# else if (k != 0): k * 2^52 added to the bits is k added to the field, so the");
    w("# sign comes off first (a negative pattern would put a 1 at the top of the");
    w("# field and scale the wrong way) and goes back on after.");
    w("    test %rcx, %rcx");
    w("    jz yexp_ld_done");
    w("# The sign that matters is the VALUE's. `js` after the `shl` would be reading");
    w("# k's -- the first version did exactly that, so every x below about zero");
    w("# (half the range) took the negative path and had 2^63 added to a pattern");
    w("# that was already positive.");
    w("    test %rdx, %rdx");
    w("    js yexp_ld_neg");
    w("    mov %rcx, %r8");
    w("    shl $52, %r8");
    w("    add %r8, %rdx");
    w("    jmp yexp_ld_done");
    w("yexp_ld_neg:");
    w("    mov %rcx, %r8");
    w("    shl $52, %r8");
    w("    add %r8, %rdx");
    w("# shifted + sign_bit(). 2^63 is one past the largest long, so it is a movabs");
    w("# rather than an immediate: `mov $4611686018427387904, %r8` cannot be spelled,");
    w("# and `mov $-1, %r8; shl $63, %r8` would be one instruction longer for the");
    w("# same bits.");
    w("    mov $-9223372036854775808, %r8");
    w("    add %r8, %rdx");
    w("    jmp yexp_ld_done");
    w("yexp_ld_shift:");
    w("    test %rcx, %rcx");
    w("    jz yexp_ld_done");
    w("    cmp $0, %rcx");
    w("    jg yexp_ld_up_loop");
    w("    movsd yexp_tab+" + tostring(off_half) + "(%rip), %xmm7    # 0.5");
    w("    jmp yexp_ld_loop");
    w("yexp_ld_up_loop:");
    w("    movsd yexp_tab+" + tostring(off_two) + "(%rip), %xmm7    # 2.0");
    w("yexp_ld_loop:");
    w("    movq %rdx, %xmm4");
    w("    mulsd %xmm7, %xmm4");
    w("    movq %xmm4, %rdx");
    w("    add $1, %rcx");
    w("    jnz yexp_ld_loop");
    w("yexp_ld_done:");
    w("    mov %rdx, %rax");
    w("yexp_ret:");
    w("    ret");
    w("yexp_inf:");
    w("    mov $9218868437227405312, %rax    # +inf");
    w("    ret");
    w("yexp_zero:");
    w("    xor %eax, %eax                     # +0.0");
    w("    ret");
    w("");

    // ── the table block ───────────────────────────────────────────────────────
    w("# yexp_tab: exp's constants and its split kernel, one label for the lot (a");
    w("# label per entry costs the shaker ~2K instructions of fixpoint each, on");
    w("# every compile). Read as yexp_tab+N(%rip), N = 8*index.");
    w("yexp_tab:");

    k = 0;
    while (k < names.length) {
        w("    .quad " + tostring(mgen.bits(vals[k])) + "    # " + names[k]);
        k += 1;
    };
    w("");
    mgen.text(W, [])
};

export { gen };
