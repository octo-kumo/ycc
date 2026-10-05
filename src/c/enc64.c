/* enc64.c — 1:1 port of src/y/enc64.y (translation contract: PORTING.md).
 *
 * x86-64 instruction encoding for the native backend's subset.
 * Operands use the assembler's parsed forms (asm.y parse_operand):
 *   {k:"reg", n, size}      n = 0-15, size = 64/32/8 (128 = an xmm)
 *   {k:"imm", v}            signed long
 *   {k:"mem", base, idx, scale, disp, rip, lbl}  rip: bool (lbl valid),
 *     base/idx: reg numbers (-1 = none), scale 1/2/4/8, disp long
 *   {k:"lbl", name}         code label (jumps/calls)
 *   {k:"ind", n, size}      call *%reg — an indirect target (closure code)
 *   {k:"diff", a, b}        a-b as imm32 (rodata lengths)
 * An encoder writes the instruction's bytes FORWARD into a caller-owned
 * scratch through a cursor (see "the byte sink" below) and returns
 * {at, fix, err}; the instruction is scratch[0:at].
 * Only the forms our backend emits exist here — anything else is a loud
 * error from the assembler, never a silent miscompile.
 */
#include "enc64.h"
#include "tags.h"

/* ── module-local defs (forward) ─────────────────────────────────────── */
static long op_size(Yv *o);
static long rex(int w, long r, long x, long b);
static long modrm(long mod, long reg, long rm);
static long sib(long scale, long index, long base);
static long pow256(long i);
static long div_floor(long v, long d);
static long u8(long v);
static int fits8(long v);
static Yv *mem_tail(Yv *m, long reg);
static long mem_tail_put(Yv *buf, long at, Yv *t);
static long rex_rm(int w, long reg, Yv *m);
static long put(Yv *buf, long at, long v);
static long put2(Yv *buf, long at, long a, long b);
static long put3(Yv *buf, long at, long a, long b, long c);
static long put_le16(Yv *buf, long at, long v);
static long put_le32(Yv *buf, long at, long v);
static long put_le64(Yv *buf, long at, long v);
static long put_rex(Yv *buf, long at, long r);
static Yv *enc_err(long at, Yv *msg);
static Yv *enc_ok(long at, Yv *fx);
static Yv *enc_br(long at, Yv *fx, long br);
static Yv *enc_mem_result(Yv *buf, long at, Yv *t);
static Yv *enc_mem_imm_result(Yv *buf, long at, Yv *t, long v, int wide);
static Yv *enc_xchg(Yv *buf, long at, Yv *a, Yv *b);
static Yv *enc_push(Yv *buf, long at, Yv *o);
static Yv *enc_pop(Yv *buf, long at, Yv *o);
static Yv *enc_mov(Yv *buf, long at, Yv *dst, Yv *src);
static Yv *enc_movb(Yv *buf, long at, Yv *dst, Yv *src);
static Yv *enc_movb_imm(Yv *buf, long at, Yv *dst, Yv *src);
static Yv *enc_movzbq(Yv *buf, long at, Yv *dst, Yv *src);
static Yv *enc_lea(Yv *buf, long at, Yv *dst, Yv *src);
static Yv *enc_arith(Yv *buf, long at, Yv *op, Yv *dst, Yv *src);
static Yv *enc_xor32(Yv *buf, long at, Yv *dst, Yv *src);
static Yv *enc_alu_imm(Yv *buf, long at, Yv *op, Yv *dst, long v);
static Yv *enc_alu_imm_mem(Yv *buf, long at, Yv *op, Yv *dst, long v);
static Yv *enc_alu_imm_go(Yv *buf, long at, Yv *op, Yv *dst, long v);
static Yv *enc_alu_imm_body(Yv *buf, long at, Yv *op, Yv *dst, long v);
static Yv *enc_shift(Yv *buf, long at, Yv *mn, Yv *dst, Yv *cnt);
static Yv *enc_sse_arith(Yv *buf, long at, Yv *mn, Yv *dst, Yv *src);
static long sse_op(Yv *mn);
static Yv *enc_movsd(Yv *buf, long at, Yv *dst, Yv *src);
static Yv *enc_sqrtsd(Yv *buf, long at, Yv *dst, Yv *src);
static Yv *enc_ucomisd(Yv *buf, long at, Yv *dst, Yv *src);
static Yv *enc_cvtsi2sd(Yv *buf, long at, Yv *dst, Yv *src);
static Yv *enc_cvttsd2si(Yv *buf, long at, Yv *dst, Yv *src);
static Yv *enc_movq(Yv *buf, long at, Yv *dst, Yv *src);
static Yv *enc_imul(Yv *buf, long at, Yv *dst, Yv *src);
static Yv *enc_unary(Yv *buf, long at, Yv *op, Yv *o);
static Yv *enc_unary_mem(Yv *buf, long at, Yv *op, Yv *o);
static Yv *enc_jmp(Yv *buf, long at, Yv *o, int lng);
static Yv *enc_call(Yv *buf, long at, Yv *o);
static Yv *enc_jcc(Yv *buf, long at, long code, Yv *o, int lng);
static Yv *enc_setcc(Yv *buf, long at, long code, Yv *o);
static Yv *enc_cmpb(Yv *buf, long at, long v, Yv *m);
static Yv *enc_movb_reg(Yv *buf, long at, Yv *dst, Yv *src);
static Yv *need1(Yv *mn, Yv *ops);
static Yv *need2(Yv *mn, Yv *ops);

Yv *r64(long n) {
    return yr(3, "k", yv_long(K_reg), "n", yv_long(n), "size", yv_long(64));
}

/* r32/r8 are module defs nothing in the tree calls (kept 1:1); external
   linkage keeps -Wunused-function quiet without widening the header. */
Yv *r32(long n) {
    return yr(3, "k", yv_long(K_reg), "n", yv_long(n), "size", yv_long(32));
}

Yv *r8(long n) {
    return yr(3, "k", yv_long(K_reg), "n", yv_long(n), "size", yv_long(8));
}

long reg_num(Yv *name) {
    if (ys_eq_lit(name, "%rax") || ys_eq_lit(name, "%eax") || ys_eq_lit(name, "%al")) { return 0; }
    else if (ys_eq_lit(name, "%rcx") || ys_eq_lit(name, "%ecx") || ys_eq_lit(name, "%cl")) { return 1; }
    else if (ys_eq_lit(name, "%rdx") || ys_eq_lit(name, "%edx") || ys_eq_lit(name, "%dl")) { return 2; }
    else if (ys_eq_lit(name, "%rbx") || ys_eq_lit(name, "%ebx") || ys_eq_lit(name, "%bl")) { return 3; }
    else if (ys_eq_lit(name, "%rsp") || ys_eq_lit(name, "%esp")) { return 4; }
    else if (ys_eq_lit(name, "%rbp") || ys_eq_lit(name, "%ebp")) { return 5; }
    else if (ys_eq_lit(name, "%rsi") || ys_eq_lit(name, "%esi") || ys_eq_lit(name, "%sil")) { return 6; }
    else if (ys_eq_lit(name, "%rdi") || ys_eq_lit(name, "%edi") || ys_eq_lit(name, "%dil")) { return 7; }
    else if (ys_eq_lit(name, "%r8") || ys_eq_lit(name, "%r8d") || ys_eq_lit(name, "%r8b")) { return 8; }
    else if (ys_eq_lit(name, "%r9") || ys_eq_lit(name, "%r9d") || ys_eq_lit(name, "%r9b")) { return 9; }
    else if (ys_eq_lit(name, "%r10") || ys_eq_lit(name, "%r10d") || ys_eq_lit(name, "%r10b")) { return 10; }
    else if (ys_eq_lit(name, "%r11") || ys_eq_lit(name, "%r11d") || ys_eq_lit(name, "%r11b")) { return 11; }
    else if (ys_eq_lit(name, "%r12") || ys_eq_lit(name, "%r12d")) { return 12; }
    else if (ys_eq_lit(name, "%r13") || ys_eq_lit(name, "%r13d")) { return 13; }
    else if (ys_eq_lit(name, "%r14") || ys_eq_lit(name, "%r14d")) { return 14; }
    else if (ys_eq_lit(name, "%r15") || ys_eq_lit(name, "%r15d")) { return 15; }
    else if (ys_eq_lit(name, "%xmm0")) { return 0; }
    else if (ys_eq_lit(name, "%xmm1")) { return 1; }
    else if (ys_eq_lit(name, "%xmm2")) { return 2; }
    else if (ys_eq_lit(name, "%xmm3")) { return 3; }
    else if (ys_eq_lit(name, "%xmm4")) { return 4; }
    else if (ys_eq_lit(name, "%xmm5")) { return 5; }
    else { return -1; }
}

long reg_size(Yv *name) {
    Yv *c = ys_slice(name, 1, 2);
    if (ys_eq_lit(c, "x")) {
        /* %xmmN: SSE register (size 128 marks the class apart from GPRs) */
        return 128;
    } else if (ys_eq_lit(c, "r")) {
        /* %r..: 64-bit, unless ends in d/b */
        Yv *last = ys_slice_from(name, yv_len(name) - 1);
        if (ys_eq_lit(last, "d")) { return 32; } else if (ys_eq_lit(last, "b")) { return 8; } else { return 64; }
    } else {
        /* %e..: 32-bit; %..l / %..h legacy: 8-bit; %r.. handled above */
        if (ys_eq_lit(c, "e")) { return 32; } else { return 8; }
    }
}

/* Safe size read: a non-register yields 0, whatever its `.size` holds. */
static long op_size(Yv *o) {
    if (yv_l(yr_get(o, "k")) == K_reg) { return yv_l(yr_get(o, "size")); } else { return 0; }
}
static long rex(int w, long r, long x, long b) {
    long v = 64;
    if (w) { v = v + 8; }
    if (r >= 8) { v = v + 4; }
    if (x >= 8) { v = v + 2; }
    if (b >= 8) { v = v + 1; }
    if (v == 64) { return -1; } else { return v; }
}

static long modrm(long mod, long reg, long rm) {
    return mod * 64 + (reg % 8) * 8 + rm % 8;
}

static long sib(long scale, long index, long base) {
    long s = 0;
    if (scale == 2) { s = 1; }
    else if (scale == 4) { s = 2; }
    else if (scale == 8) { s = 3; }
    return s * 64 + (index % 8) * 8 + base % 8;
}

/* A little-endian run as its own array, for the callers outside the encoders
   (asm.y's .quad and its patcher). Inside an encoder use
   put_le16/put_le32/put_le64, which write the same bytes through the cursor
   and allocate nothing. */
Yv *le16(long v) {
    return yav(2, yv_long(byte_of(v, 0)), yv_long(byte_of(v, 1)));
}

Yv *le32(long v) {
    return yav(4, yv_long(byte_of(v, 0)), yv_long(byte_of(v, 1)),
               yv_long(byte_of(v, 2)), yv_long(byte_of(v, 3)));
}

Yv *le64(long v) {
    return yav(8, yv_long(byte_of(v, 0)), yv_long(byte_of(v, 1)),
               yv_long(byte_of(v, 2)), yv_long(byte_of(v, 3)),
               yv_long(byte_of(v, 4)), yv_long(byte_of(v, 5)),
               yv_long(byte_of(v, 6)), yv_long(byte_of(v, 7)));
}

/* 256^i (the weight of byte i). */
static long pow256(long i) {
    long r = 1;
    long j = 0;
    while (j < i) {
        r = r * 256;
        j = j + 1;
    }
    return r;
}

/* NOTE: Y division truncates toward zero (C semantics — native.y emits
   `cqo; idiv` for `/`), so floor needs a correction when the remainder
   is nonzero and the signs differ. Both engines truncate the same way,
   so one correction serves them both. */
static long div_floor(long v, long d) {
    long q = v / d;
    long r = v - q * d;
    if (r != 0) {
        if (v < 0) {
            if (d > 0) { q = q - 1; }
        } else if (d < 0) { q = q - 1; }
    }
    return q;
}

/* Exact byte i (0 = least significant) of a signed long. Y division
   truncates, so floor it manually — correct for negatives (unlike %). */
long byte_of(long v, long i) {
    long q = div_floor(v, pow256(i));
    return q - div_floor(q, 256) * 256;
}

static long u8(long v) {
    return byte_of(v, 0);
}

/* fits in a signed 8-bit immediate? */
static int fits8(long v) {
    return v >= -128 && v <= 127;
}

/* ── the byte sink ──────────────────────────────────────────────────────
   An instruction is written byte by byte into a scratch the caller owns,
   through a cursor `at`, and read back as scratch[0:at]. It used to be
   assembled by concatenating little arrays instead — `concat(prefix, tail)`,
   `concat(prefix, le32(v))`, `with_rex(r, b)` prepending one more — which
   allocated two or three `[byte]`s per step, for a three-byte instruction,
   and that is where the assembler spent its memory: 368 MB of an 838 MB
   compile of ycc.y, in `concat` alone 512,082 allocations and 1,057,134
   single-byte pushes.

   x86 orders a form opcode, ModRM, SIB, displacement, immediate — which is
   exactly the order the encoders below write them — so `at` only ever moves
   forward and no encoder needs to backfill. That is what makes the shape
   possible: the old model prepended a REX prefix after the fact, which is
   why with_rex existed and why enc_mem_result had to add 1 to a fixup
   offset to account for a prefix it had not written yet. */

/* 16 slots; the longest form below is 12 bytes (`mov $imm32, mem(%rip)`:
   REX, opcode, ModRM, SIB, disp32, imm32). Writing past the end traps
   ("index out of bounds"), so an encoder that overruns is loud. */
Yv *scratch(void) {
    return yav(16, yv_long(0), yv_long(0), yv_long(0), yv_long(0), yv_long(0),
               yv_long(0), yv_long(0), yv_long(0), yv_long(0), yv_long(0),
               yv_long(0), yv_long(0), yv_long(0), yv_long(0), yv_long(0));
}

static long put(Yv *buf, long at, long v) {
    ya_set(buf, at, yv_long(v));
    return at + 1;
}

static long put2(Yv *buf, long at, long a, long b) {
    ya_set(buf, at, yv_long(a));
    ya_set(buf, at + 1, yv_long(b));
    return at + 2;
}

static long put3(Yv *buf, long at, long a, long b, long c) {
    long n = put2(buf, at, a, b);
    ya_set(buf, n, yv_long(c));
    return n + 1;
}

static long put_le16(Yv *buf, long at, long v) {
    return put2(buf, at, byte_of(v, 0), byte_of(v, 1));
}

static long put_le32(Yv *buf, long at, long v) {
    long n = put2(buf, at, byte_of(v, 0), byte_of(v, 1));
    return put2(buf, n, byte_of(v, 2), byte_of(v, 3));
}

static long put_le64(Yv *buf, long at, long v) {
    long n = put_le32(buf, at, v);
    return put_le32(buf, n, div_floor(v, 4294967296L));
}

/* The REX prefix, or nothing: -1 means the form needs no prefix, and the
   cursor does not move. */
static long put_rex(Yv *buf, long at, long r) {
    if (r < 0) {
        return at;
    } else {
        return put(buf, at, r);
    }
}

/* Encode a memory operand's tail (ModRM + optional SIB + displacement).
   Returns {modrm, sib, ne, disp, rip_lbl}: the caller writes the opcode and
   the ModRM, then mem_tail_put writes `sib` (or -1 for none) and the `ne`
   displacement bytes at `disp`, then any immediate — x86's own order.
   `rip_lbl` non-empty says a label-relative disp32 follows the tail, which
   enc_mem_result / enc_mem_imm_result write as a placeholder with a fixup. */
static Yv *mem_tail(Yv *m, long reg) {
    if (yv_b(yr_get(m, "rip"))) {
        return yr(5, "modrm", yv_long(modrm(0, reg, 5)), "sib", yv_long(-1),
                  "ne", yv_long(0), "disp", yv_long(0),
                  "rip_lbl", yr_get(m, "lbl"));
    } else if (yv_l(yr_get(m, "idx")) < 0) {
        /* no index: [base+disp]. Low 101 (rbp/r13) needs at least disp8
           (mod=00 would mean disp32-only); low 100 (rsp/r12) needs a SIB
           byte whose base field is 100 — which is rsp, or r12 once REX.B
           widens it (rex_rm sets that from m.base). */
        if (yv_l(yr_get(m, "base")) % 8 == 5) {
            if (fits8(yv_l(yr_get(m, "disp")))) {
                return yr(5, "modrm", yv_long(modrm(1, reg, 5)), "sib", yv_long(-1),
                          "ne", yv_long(1), "disp", yr_get(m, "disp"),
                          "rip_lbl", ys(""));
            } else {
                return yr(5, "modrm", yv_long(modrm(2, reg, 5)), "sib", yv_long(-1),
                          "ne", yv_long(4), "disp", yr_get(m, "disp"),
                          "rip_lbl", ys(""));
            }
        } else if (yv_l(yr_get(m, "base")) % 8 == 4) {
            /* rsp/r12 as base: SIB byte required (index=none, base=rsp).
               sib(1, 4, 4) = scale 00, index 100 (none), base 100 (rsp). */
            long s = sib(1, 4, 4);
            if (yv_l(yr_get(m, "disp")) == 0) {
                return yr(5, "modrm", yv_long(modrm(0, reg, 4)), "sib", yv_long(s),
                          "ne", yv_long(0), "disp", yv_long(0), "rip_lbl", ys(""));
            } else if (fits8(yv_l(yr_get(m, "disp")))) {
                return yr(5, "modrm", yv_long(modrm(1, reg, 4)), "sib", yv_long(s),
                          "ne", yv_long(1), "disp", yr_get(m, "disp"),
                          "rip_lbl", ys(""));
            } else {
                return yr(5, "modrm", yv_long(modrm(2, reg, 4)), "sib", yv_long(s),
                          "ne", yv_long(4), "disp", yr_get(m, "disp"),
                          "rip_lbl", ys(""));
            }
        } else if (yv_l(yr_get(m, "disp")) == 0) {
            return yr(5, "modrm", yv_long(modrm(0, reg, yv_l(yr_get(m, "base")))),
                      "sib", yv_long(-1), "ne", yv_long(0), "disp", yv_long(0),
                      "rip_lbl", ys(""));
        } else if (fits8(yv_l(yr_get(m, "disp")))) {
            return yr(5, "modrm", yv_long(modrm(1, reg, yv_l(yr_get(m, "base")))),
                      "sib", yv_long(-1), "ne", yv_long(1),
                      "disp", yr_get(m, "disp"), "rip_lbl", ys(""));
        } else {
            return yr(5, "modrm", yv_long(modrm(2, reg, yv_l(yr_get(m, "base")))),
                      "sib", yv_long(-1), "ne", yv_long(4),
                      "disp", yr_get(m, "disp"), "rip_lbl", ys(""));
        }
    } else {
        /* SIB: [base + idx*scale + disp]. Low 101 needs explicit disp. */
        long s = sib(yv_l(yr_get(m, "scale")), yv_l(yr_get(m, "idx")), yv_l(yr_get(m, "base")));
        if (yv_l(yr_get(m, "base")) % 8 == 5) {
            if (fits8(yv_l(yr_get(m, "disp")))) {
                return yr(5, "modrm", yv_long(modrm(1, reg, 4)), "sib", yv_long(s),
                          "ne", yv_long(1), "disp", yr_get(m, "disp"),
                          "rip_lbl", ys(""));
            } else {
                return yr(5, "modrm", yv_long(modrm(2, reg, 4)), "sib", yv_long(s),
                          "ne", yv_long(4), "disp", yr_get(m, "disp"),
                          "rip_lbl", ys(""));
            }
        } else if (yv_l(yr_get(m, "disp")) == 0) {
            return yr(5, "modrm", yv_long(modrm(0, reg, 4)), "sib", yv_long(s),
                      "ne", yv_long(0), "disp", yv_long(0), "rip_lbl", ys(""));
        } else if (fits8(yv_l(yr_get(m, "disp")))) {
            return yr(5, "modrm", yv_long(modrm(1, reg, 4)), "sib", yv_long(s),
                      "ne", yv_long(1), "disp", yr_get(m, "disp"), "rip_lbl", ys(""));
        } else {
            return yr(5, "modrm", yv_long(modrm(2, reg, 4)), "sib", yv_long(s),
                      "ne", yv_long(4), "disp", yr_get(m, "disp"), "rip_lbl", ys(""));
        }
    }
}

/* The tail's own bytes, after the ModRM the caller wrote. */
static long mem_tail_put(Yv *buf, long at, Yv *t) {
    long n = at;
    if (yv_l(yr_get(t, "sib")) >= 0) { n = put(buf, n, yv_l(yr_get(t, "sib"))); }
    if (yv_l(yr_get(t, "ne")) == 1) { n = put(buf, n, u8(yv_l(yr_get(t, "disp")))); }
    else if (yv_l(yr_get(t, "ne")) == 4) { n = put_le32(buf, n, yv_l(yr_get(t, "disp"))); }
    return n;
}

/* REX for r/m operands: W + extensions from reg field and mem SIB/base. */
static long rex_rm(int w, long reg, Yv *m) {
    if (yv_b(yr_get(m, "rip"))) {
        return rex(w, reg, -1, -1);
    } else if (yv_l(yr_get(m, "idx")) < 0) {
        return rex(w, reg, -1, yv_l(yr_get(m, "base")));
    } else {
        return rex(w, reg, yv_l(yr_get(m, "idx")), yv_l(yr_get(m, "base")));
    }
}

/* Fixup record for label-relative fields, resolved in pass 2:
   {off, kind, lbl, lbl2} (off relative to instruction start).
   kind: "rel32" (call/jmp/jcc), "rip32", "imm32diff".
   NOTE: do not add a field here. asm_loc/asm_file build four-field records for
   the DWARF markers and hand them back where a Fixup is expected, and the
   earlier attempt at a fifth field (`add`, the byte offset of `tab+8(%rip)`)
   made Y and C disagree about the .debug_line table with no port-gate signal:
   the gate builds ycc.y WITHOUT -g. The table offset rides in `lbl` instead,
   and asm.c's label_addr evaluates it. */
Yv *fixup(long at, Yv *kind, Yv *lbl, Yv *lbl2) {
    return yr(4, "off", yv_long(at), "kind", kind, "lbl", lbl, "lbl2", lbl2);
}

/* ── instruction encoders ───────────────────────────────────────────────
   Each writes its bytes into `buf` from `at` and returns {at, fix, err, br},
   with every fixup offset relative to the instruction's first byte (which is
   where the caller started), and `br` the branch this instruction is (0 for
   jmp, the long form's condition byte for a jcc, -1 for everything else) so
   the assembler's relaxation pass can re-encode one without re-parsing its
   line. Only forms our backend emits exist. */
static Yv *enc_err(long at, Yv *msg) {
    return yr(4, "at", yv_long(at), "fix", yav(0), "err", msg, "br", yv_long(-1));
}

static Yv *enc_ok(long at, Yv *fx) {
    return yr(4, "at", yv_long(at), "fix", fx, "err", ys(""), "br", yv_long(-1));
}

/* A branch, which is what `br` names. */
static Yv *enc_br(long at, Yv *fx, long br) {
    return yr(4, "at", yv_long(at), "fix", fx, "err", ys(""), "br", yv_long(br));
}

/* A label operand, for re-encoding a branch whose target is already known (the
   item's fixup carries the name). */
static Yv *lbl_op(Yv *name) {
    return yr(13, "k", yv_long(K_lbl), "n", yv_long(0), "size", yv_long(0),
              "v", yv_long(0), "a", ys(""), "b", ys(""), "name", name,
              "base", yv_long(-1), "idx", yv_long(-1), "scale", yv_long(1),
              "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys(""));
}

/* The long (rel32) form of a branch, for asm_relax's grower pass: `br` is what
   the item recorded, `lbl` what its fixup names. */
Yv *enc_branch_long(Yv *buf, long at, long br, Yv *lbl) {
    if (br == 0) { return enc_jmp(buf, at, lbl_op(lbl), 1); }
    else { return enc_jcc(buf, at, br, lbl_op(lbl), 1); }
}

static Yv *enc_push(Yv *buf, long at, Yv *o) {
    if (yv_l(yr_get(o, "k")) != K_reg) {
        return enc_err(at, ys("push needs r64"));
    } else if (op_size(o) != 64) {
        return enc_err(at, ys("push needs r64"));
    } else {
        long n = put_rex(buf, at, rex(0, -1, -1, yv_l(yr_get(o, "n"))));
        return enc_ok(put(buf, n, 80 + (yv_l(yr_get(o, "n")) % 8)), yav(0));
    }
}

static Yv *enc_pop(Yv *buf, long at, Yv *o) {
    if (yv_l(yr_get(o, "k")) != K_reg) {
        return enc_err(at, ys("pop needs r64"));
    } else if (op_size(o) != 64) {
        return enc_err(at, ys("pop needs r64"));
    } else {
        long n = put_rex(buf, at, rex(0, -1, -1, yv_l(yr_get(o, "n"))));
        return enc_ok(put(buf, n, 88 + (yv_l(yr_get(o, "n")) % 8)), yav(0));
    }
}

static Yv *enc_mov(Yv *buf, long at, Yv *dst, Yv *src) {
    if (yv_l(yr_get(dst, "k")) == K_reg && yv_l(yr_get(src, "k")) == K_reg) {
        if (op_size(dst) == 64 && op_size(src) == 64) {
            long n = put_rex(buf, at, rex(1, yv_l(yr_get(src, "n")), -1, yv_l(yr_get(dst, "n"))));
            return enc_ok(put2(buf, n, 137, modrm(3, yv_l(yr_get(src, "n")), yv_l(yr_get(dst, "n")))), yav(0));
        } else {
            return enc_err(at, ys("mov reg,reg size mix"));
        }
    } else if (yv_l(yr_get(dst, "k")) == K_reg && yv_l(yr_get(src, "k")) == K_imm) {
        if (op_size(dst) == 64) {
            if (yv_l(yr_get(src, "v")) >= -2147483648L && yv_l(yr_get(src, "v")) <= 2147483647L) {
                long n = put_rex(buf, at, rex(1, -1, -1, yv_l(yr_get(dst, "n"))));
                long m = put2(buf, n, 199, modrm(3, 0, yv_l(yr_get(dst, "n"))));
                return enc_ok(put_le32(buf, m, yv_l(yr_get(src, "v"))), yav(0));
            } else {
                long n = put_rex(buf, at, rex(1, -1, -1, yv_l(yr_get(dst, "n"))));
                long m = put(buf, n, 184 + (yv_l(yr_get(dst, "n")) % 8));
                return enc_ok(put_le64(buf, m, yv_l(yr_get(src, "v"))), yav(0));
            }
        } else if (op_size(dst) == 32) {
            long n = put_rex(buf, at, rex(0, -1, -1, yv_l(yr_get(dst, "n"))));
            long m = put2(buf, n, 199, modrm(3, 0, yv_l(yr_get(dst, "n"))));
            return enc_ok(put_le32(buf, m, yv_l(yr_get(src, "v"))), yav(0));
        } else {
            return enc_err(at, ys("mov imm size"));
        }
    } else if (yv_l(yr_get(dst, "k")) == K_reg && op_size(dst) == 64 && yv_l(yr_get(src, "k")) == K_diff) {
        long r = rex(1, -1, -1, yv_l(yr_get(dst, "n")));
        long n = put_rex(buf, at, r);
        long m = put2(buf, n, 199, modrm(3, 0, yv_l(yr_get(dst, "n"))));
        /* the four bytes are placeholders; pass 2 writes src.a - src.b */
        long q = put_le32(buf, m, 0);
        long off = 3;
        if (r < 0) { off = 2; }
        return enc_ok(q, yav(1, fixup(at + off, ys("imm32diff"), yr_get(src, "a"), yr_get(src, "b"))));
    } else if (yv_l(yr_get(dst, "k")) == K_reg && yv_l(yr_get(src, "k")) == K_fs && op_size(dst) == 64) {
        /* mov %fs:disp32, r64: the fs prefix, REX.W, 8B, a SIB with no
           base and no index (an absolute disp32) */
        long n = put(buf, at, 100);
        long m = put(buf, n, rex(1, yv_l(yr_get(dst, "n")), -1, -1));
        long q = put2(buf, m, 139, modrm(0, yv_l(yr_get(dst, "n")), 4));
        long p = put(buf, q, 37);
        return enc_ok(put_le32(buf, p, yv_l(yr_get(src, "disp"))), yav(0));
    } else if (yv_l(yr_get(dst, "k")) == K_reg && yv_l(yr_get(src, "k")) == K_mem) {
        if (op_size(dst) == 64) {
            Yv *t = mem_tail(src, yv_l(yr_get(dst, "n")));
            long n = put_rex(buf, at, rex_rm(1, yv_l(yr_get(dst, "n")), src));
            long m = put2(buf, n, 139, yv_l(yr_get(t, "modrm")));
            return enc_mem_result(buf, mem_tail_put(buf, m, t), t);
        } else {
            return enc_err(at, ys("mov r,mem size"));
        }
    } else if (yv_l(yr_get(dst, "k")) == K_mem && yv_l(yr_get(src, "k")) == K_imm) {
        /* mov $imm32, mem (length/cap stores) */
        Yv *t = mem_tail(dst, 0);
        long n = put_rex(buf, at, rex_rm(1, 0, dst));
        long m = put2(buf, n, 199, yv_l(yr_get(t, "modrm")));
        return enc_mem_imm_result(buf, mem_tail_put(buf, m, t), t, yv_l(yr_get(src, "v")), 1);
    } else if (yv_l(yr_get(dst, "k")) == K_mem && yv_l(yr_get(src, "k")) == K_reg) {
        if (op_size(src) == 64) {
            Yv *t = mem_tail(dst, yv_l(yr_get(src, "n")));
            long n = put_rex(buf, at, rex_rm(1, yv_l(yr_get(src, "n")), dst));
            long m = put2(buf, n, 137, yv_l(yr_get(t, "modrm")));
            return enc_mem_result(buf, mem_tail_put(buf, m, t), t);
        } else if (op_size(src) == 8) {
            Yv *t = mem_tail(dst, yv_l(yr_get(src, "n")));
            long n = put_rex(buf, at, rex_rm(0, yv_l(yr_get(src, "n")), dst));
            long m = put2(buf, n, 136, yv_l(yr_get(t, "modrm")));
            return enc_mem_result(buf, mem_tail_put(buf, m, t), t);
        } else {
            return enc_err(at, ys("mov mem,reg size"));
        }
    } else {
        return enc_err(at, ys("mov form"));
    }
}
/* xchg r64, mem (either order): REX.W 87 /r, locked by the processor
   (the threads' mutexes). */
static Yv *enc_xchg(Yv *buf, long at, Yv *a, Yv *b) {
    Yv *reg = a;
    Yv *mem = b;
    if (yv_l(yr_get(a, "k")) == K_mem) {
        reg = b;
        mem = a;
    }
    if (yv_l(yr_get(reg, "k")) != K_reg || yv_l(yr_get(mem, "k")) != K_mem || op_size(reg) != 64) {
        return enc_err(at, ys("xchg form"));
    } else {
        Yv *t = mem_tail(mem, yv_l(yr_get(reg, "n")));
        long n = put_rex(buf, at, rex_rm(1, yv_l(yr_get(reg, "n")), mem));
        long m = put2(buf, n, 135, yv_l(yr_get(t, "modrm")));
        return enc_mem_result(buf, mem_tail_put(buf, m, t), t);
    }
}

/* The tail's label-relative disp32 for a form with no immediate after it:
   four placeholder bytes the linker fills in, with the fixup pointing at
   them — the cursor, which is where they start. (The old model appended the
   placeholders to an array and added 1 to the offset when a REX prefix was
   about to be prepended; writing forward, the prefix is already written.) */
static Yv *enc_mem_result(Yv *buf, long at, Yv *t) {
    if (yv_l(yr_get(t, "modrm")) < 0) {
        return enc_err(at, ys("bad memory form"));
    } else if (ys_eq_lit(yr_get(t, "rip_lbl"), "")) {
        return enc_ok(at, yav(0));
    } else {
        return enc_ok(put_le32(buf, at, 0),
                      yav(1, fixup(at, ys("rip32"), yr_get(t, "rip_lbl"), ys(""))));
    }
}

/* Like enc_mem_result, but for the forms whose immediate comes AFTER the
   memory operand (C7 /0 id, C6 /0 ib, 83 /ext ib, 81 /ext id). x86 orders a
   form ModRM, SIB, displacement, immediate, while enc_mem_result's
   placeholder would come after the immediate -- so the forms with an
   immediate need this order. It matters for `mov $imm32, sym(%rip)`: with the
   placeholder after the immediate the instruction silently addresses the
   wrong 4 bytes. */
static Yv *enc_mem_imm_result(Yv *buf, long at, Yv *t, long v, int wide) {
    if (yv_l(yr_get(t, "modrm")) < 0) {
        return enc_err(at, ys("bad memory form"));
    } else {
        long n = at;
        Yv *fx = yav(0);
        if (!ys_eq_lit(yr_get(t, "rip_lbl"), "")) {
            fx = ya_push(fx, fixup(at, ys("rip32"), yr_get(t, "rip_lbl"), ys("")));
            n = put_le32(buf, n, 0);
        }
        if (wide) { return enc_ok(put_le32(buf, n, v), fx); }
        else { return enc_ok(put(buf, n, u8(v)), fx); }
    }
}

static Yv *enc_movb(Yv *buf, long at, Yv *dst, Yv *src) {
    /* movb $imm8, mem */
    if (yv_l(yr_get(dst, "k")) != K_mem) {
        return enc_err(at, ys("movb form"));
    } else if (yv_l(yr_get(src, "k")) != K_imm) {
        return enc_err(at, ys("movb form"));
    } else {
        return enc_movb_imm(buf, at, dst, src);
    }
}

static Yv *enc_movb_imm(Yv *buf, long at, Yv *dst, Yv *src) {
    /* (split: shape gate above narrows; this body sees mem/imm only.) */
    if (yv_l(yr_get(src, "v")) < -128) {
        return enc_err(at, ys("movb imm range"));
    } else if (yv_l(yr_get(src, "v")) > 127) {
        return enc_err(at, ys("movb imm range"));
    } else {
        Yv *t = mem_tail(dst, 0);
        long n = put_rex(buf, at, rex_rm(0, 0, dst));
        long m = put2(buf, n, 198, yv_l(yr_get(t, "modrm")));
        return enc_mem_imm_result(buf, mem_tail_put(buf, m, t), t, yv_l(yr_get(src, "v")), 0);
    }
}

static Yv *enc_movzbq(Yv *buf, long at, Yv *dst, Yv *src) {
    if (yv_l(yr_get(dst, "k")) == K_reg && op_size(dst) == 64
        && yv_l(yr_get(src, "k")) == K_reg && op_size(src) == 8) {
        long n = put_rex(buf, at, rex(1, yv_l(yr_get(dst, "n")), -1, yv_l(yr_get(src, "n"))));
        return enc_ok(put3(buf, n, 15, 182, modrm(3, yv_l(yr_get(dst, "n")), yv_l(yr_get(src, "n")))), yav(0));
    } else if (yv_l(yr_get(dst, "k")) == K_reg && op_size(dst) == 64
               && yv_l(yr_get(src, "k")) == K_mem) {
        /* movzbq mem8 -> r64 (single-byte loads for string data) */
        Yv *t = mem_tail(src, yv_l(yr_get(dst, "n")));
        long n = put_rex(buf, at, rex_rm(1, yv_l(yr_get(dst, "n")), src));
        long m = put3(buf, n, 15, 182, yv_l(yr_get(t, "modrm")));
        return enc_mem_result(buf, mem_tail_put(buf, m, t), t);
    } else {
        return enc_err(at, ys("movzbq form"));
    }
}

static Yv *enc_lea(Yv *buf, long at, Yv *dst, Yv *src) {
    if (yv_l(yr_get(dst, "k")) == K_reg && op_size(dst) == 64 && yv_l(yr_get(src, "k")) == K_mem) {
        Yv *t = mem_tail(src, yv_l(yr_get(dst, "n")));
        long n = put_rex(buf, at, rex_rm(1, yv_l(yr_get(dst, "n")), src));
        long m = put2(buf, n, 141, yv_l(yr_get(t, "modrm")));
        return enc_mem_result(buf, mem_tail_put(buf, m, t), t);
    } else {
        return enc_err(at, ys("lea form"));
    }
}

static Yv *enc_arith(Yv *buf, long at, Yv *op, Yv *dst, Yv *src) {
    /* op: add/sub/xor/and/or/cmp/test; r64,r64 only here */
    if (yv_l(yr_get(dst, "k")) == K_reg && op_size(dst) == 64
        && yv_l(yr_get(src, "k")) == K_reg && op_size(src) == 64) {
        long base = 1;
        if (ys_eq_lit(op, "sub")) { base = 41; }
        else if (ys_eq_lit(op, "xor")) { base = 49; }
        else if (ys_eq_lit(op, "and")) { base = 33; }
        else if (ys_eq_lit(op, "or")) { base = 9; }
        else if (ys_eq_lit(op, "cmp")) { base = 57; }
        else if (ys_eq_lit(op, "test")) { base = 133; }
        long n = put_rex(buf, at, rex(1, yv_l(yr_get(src, "n")), -1, yv_l(yr_get(dst, "n"))));
        return enc_ok(put2(buf, n, base, modrm(3, yv_l(yr_get(src, "n")), yv_l(yr_get(dst, "n")))), yav(0));
    } else {
        return enc_err(at, ys("arith reg form"));
    }
}

static Yv *enc_xor32(Yv *buf, long at, Yv *dst, Yv *src) {
    if (yv_l(yr_get(dst, "k")) == K_reg && op_size(dst) == 32
        && yv_l(yr_get(src, "k")) == K_reg && op_size(src) == 32) {
        long n = put_rex(buf, at, rex(0, yv_l(yr_get(src, "n")), -1, yv_l(yr_get(dst, "n"))));
        return enc_ok(put2(buf, n, 49, modrm(3, yv_l(yr_get(src, "n")), yv_l(yr_get(dst, "n")))), yav(0));
    } else {
        return enc_err(at, ys("xor32 form"));
    }
}

/* The /ext of the ALU group (add is 0): the register and the memory forms are
   the same instruction with a different ModRM, so they share the table. */
static long alu_ext(Yv *op) {
    if (ys_eq_lit(op, "sub")) { return 5; }
    else if (ys_eq_lit(op, "cmp")) { return 7; }
    else if (ys_eq_lit(op, "xor")) { return 6; }
    else if (ys_eq_lit(op, "and")) { return 4; }
    else if (ys_eq_lit(op, "or")) { return 1; }
    else { return 0; }
}

static Yv *enc_alu_imm(Yv *buf, long at, Yv *op, Yv *dst, long v) {
    /* add/sub/cmp/xor/and/or $imm, %r64; cmp $imm, %r32; and $imm, mem */
    if (yv_l(yr_get(dst, "k")) == K_mem) {
        return enc_alu_imm_mem(buf, at, op, dst, v);
    } else if (yv_l(yr_get(dst, "k")) != K_reg) {
        return enc_err(at, ys("alu-imm dst"));
    } else if (op_size(dst) != 64) {
        if (op_size(dst) != 32) {
            return enc_err(at, ys("alu-imm dst"));
        } else {
            return enc_alu_imm_go(buf, at, op, dst, v);
        }
    } else {
        return enc_alu_imm_go(buf, at, op, dst, v);
    }
}

static Yv *enc_alu_imm_mem(Yv *buf, long at, Yv *op, Yv *dst, long v) {
    /* (split from enc_alu_imm: the shape gate above narrows; this body sees a
       memory destination, and no size -- a memory operand carries none, so this
       is the 64-bit form, which is what a Y long is. GNU as guesses 32-bit for
       a sizeless memory operand with no register operand, and that would zero
       the upper half of every long.) */
    long ext = alu_ext(op);
    if (fits8(v)) {
        Yv *t = mem_tail(dst, ext);
        long n = put_rex(buf, at, rex_rm(1, ext, dst));
        long m = put2(buf, n, 131, yv_l(yr_get(t, "modrm")));
        return enc_mem_imm_result(buf, mem_tail_put(buf, m, t), t, v, 0);
    } else if (v < -2147483648L || v > 2147483647L) {
        /* the same door the register form has (see enc_alu_imm_body) */
        return enc_err(at, ys("an immediate does not fit in 32 bits"));
    } else {
        Yv *t = mem_tail(dst, ext);
        long n = put_rex(buf, at, rex_rm(1, ext, dst));
        long m = put2(buf, n, 129, yv_l(yr_get(t, "modrm")));
        return enc_mem_imm_result(buf, mem_tail_put(buf, m, t), t, v, 1);
    }
}

static Yv *enc_alu_imm_go(Yv *buf, long at, Yv *op, Yv *dst, long v) {
    /* (split from enc_alu_imm: the size gate above narrows; this body sees
       only r64/r32 regs — no merged-shape reads.) */
    return enc_alu_imm_body(buf, at, op, dst, v);
}

static Yv *enc_alu_imm_body(Yv *buf, long at, Yv *op, Yv *dst, long v) {
    /* (the size gate lives in enc_alu_imm; this one is on the value) */
    long ext = alu_ext(op);
    int wide = op_size(dst) == 64;
    long r = rex(wide, -1, -1, yv_l(yr_get(dst, "n")));
    if (fits8(v)) {
        long n = put_rex(buf, at, r);
        long m = put2(buf, n, 131, modrm(3, ext, yv_l(yr_get(dst, "n"))));
        return enc_ok(put(buf, m, u8(v)), yav(0));
    } else if (v < -2147483648L || v > 2147483647L) {
        /* 81 /n id takes a sign-extended imm32 and nothing else, and put_le32
           would quietly keep the low four bytes: `cmp $4294967366, %rcx` (a
           fixed array of 4 billion elements) would encode as `cmp $10` and
           the bounds check would pass for every index under ten. No emitter
           path reaches it -- the checker caps a fixed array's size at int32
           ("an integer literal from 0 to 2147483647 in a type") and every
           other immediate here is a frame offset or a small constant -- but
           an encoder that would quietly encode a different instruction is
           worth a door, and this is that door. */
        return enc_err(at, ys("an immediate does not fit in 32 bits"));
    } else {
        long n = put_rex(buf, at, r);
        long m = put2(buf, n, 129, modrm(3, ext, yv_l(yr_get(dst, "n"))));
        return enc_ok(put_le32(buf, m, v), yav(0));
    }
}

static Yv *enc_shift(Yv *buf, long at, Yv *mn, Yv *dst, Yv *cnt) {
    /* shl/shr/sar $imm8 (0-63) or %cl, %r64: C1 /ext ib and D3 /ext, where
       ext is shl 4, shr 5 (logical), sar 7 (arithmetic) */
    long ext = 4;
    if (ys_eq_lit(mn, "shr")) { ext = 5; }
    else if (ys_eq_lit(mn, "sar")) { ext = 7; }
    if (yv_l(yr_get(dst, "k")) != K_reg) {
        return enc_err(at, ys_cat(mn, ys(" dst")));
    } else if (op_size(dst) != 64) {
        return enc_err(at, ys_cat(mn, ys(" dst")));
    } else if (yv_l(yr_get(cnt, "k")) == K_reg) {
        if (yv_l(yr_get(cnt, "n")) == 1 && op_size(cnt) == 8) {
            long n = put_rex(buf, at, rex(1, -1, -1, yv_l(yr_get(dst, "n"))));
            return enc_ok(put2(buf, n, 211, modrm(3, ext, yv_l(yr_get(dst, "n")))), yav(0));
        } else {
            return enc_err(at, ys_cat(mn, ys(" count register is %cl")));
        }
    } else if (yv_l(yr_get(cnt, "k")) == K_imm) {
        if (yv_l(yr_get(cnt, "v")) < 0 || yv_l(yr_get(cnt, "v")) > 63) {
            return enc_err(at, ys_cat(mn, ys(" count range")));
        } else {
            long n = put_rex(buf, at, rex(1, -1, -1, yv_l(yr_get(dst, "n"))));
            long m = put2(buf, n, 193, modrm(3, ext, yv_l(yr_get(dst, "n"))));
            return enc_ok(put(buf, m, u8(yv_l(yr_get(cnt, "v")))), yav(0));
        }
    } else {
        return enc_err(at, ys_cat(mn, ys(" count")));
    }
}

/* ── SSE scalar-double encodings ────────────────────────────────────────
   Floats travel in %rax as their raw IEEE754 bits; only arithmetic and
   comparison move them into %xmmN, so the rest of the backend (slots,
   pushes, calls) is unchanged. */

static long sse_op(Yv *mn) {
    /* addsd 58, subsd 5C, mulsd 59, divsd 5E */
    long op = 88;
    if (ys_eq_lit(mn, "subsd")) { op = 92; }
    if (ys_eq_lit(mn, "mulsd")) { op = 89; }
    if (ys_eq_lit(mn, "divsd")) { op = 94; }
    return op;
}

/* F2 0F <op> /r, with the destination an xmm and the source either an xmm or
 * memory.
 *
 * The memory form is the point. A transcendental's kernel is
 * `mulsd %xmm0, c7(%rip)` over a table of coefficients, and the F2 is what
 * makes it the SCALAR form: without it the same bytes are the packed mulps,
 * which multiplies sixteen bytes at once -- and they assemble. */
static Yv *enc_sse_arith(Yv *buf, long at, Yv *mn, Yv *dst, Yv *src) {
    if (yv_l(yr_get(dst, "k")) != K_reg || op_size(dst) != 128) {
        return enc_err(at, ys("sse dst"));
    } else if (yv_l(yr_get(src, "k")) == K_reg) {
        long n = put(buf, at, 242);
        long m = put_rex(buf, n, rex(0, yv_l(yr_get(dst, "n")), -1, yv_l(yr_get(src, "n"))));
        return enc_ok(put3(buf, m, 15, sse_op(mn), modrm(3, yv_l(yr_get(dst, "n")), yv_l(yr_get(src, "n")))), yav(0));
    } else if (yv_l(yr_get(src, "k")) == K_mem) {
        Yv *t = mem_tail(src, yv_l(yr_get(dst, "n")));
        long n = put_rex(buf, put(buf, at, 242), rex_rm(0, yv_l(yr_get(dst, "n")), src));
        long m = put2(buf, n, 15, sse_op(mn));
        return enc_mem_result(buf, mem_tail_put(buf, put(buf, m, yv_l(yr_get(t, "modrm"))), t), t);
    } else {
        return enc_err(at, ys("sse src"));
    }
}

/* F2 0F 10 /r loads into an xmm (or moves xmm to xmm); F2 0F 11 /r stores.
 * There is no REX.W: the value is eight bytes wide either way. */
static Yv *enc_movsd(Yv *buf, long at, Yv *dst, Yv *src) {
    if (yv_l(yr_get(dst, "k")) == K_reg && op_size(dst) == 128) {
        if (yv_l(yr_get(src, "k")) == K_reg && op_size(src) == 128) {
            long n = put(buf, at, 242);
            long m = put_rex(buf, n, rex(0, yv_l(yr_get(dst, "n")), -1, yv_l(yr_get(src, "n"))));
            return enc_ok(put3(buf, m, 15, 16, modrm(3, yv_l(yr_get(dst, "n")), yv_l(yr_get(src, "n")))), yav(0));
        } else if (yv_l(yr_get(src, "k")) == K_mem) {
            Yv *t = mem_tail(src, yv_l(yr_get(dst, "n")));
            long n = put_rex(buf, put(buf, at, 242), rex_rm(0, yv_l(yr_get(dst, "n")), src));
            long m = put2(buf, n, 15, 16);
            return enc_mem_result(buf, mem_tail_put(buf, put(buf, m, yv_l(yr_get(t, "modrm"))), t), t);
        } else {
            return enc_err(at, ys("movsd src"));
        }
    } else if (yv_l(yr_get(dst, "k")) == K_mem && yv_l(yr_get(src, "k")) == K_reg
               && op_size(src) == 128) {
        Yv *t = mem_tail(dst, yv_l(yr_get(src, "n")));
        long n = put_rex(buf, put(buf, at, 242), rex_rm(0, yv_l(yr_get(src, "n")), dst));
        long m = put2(buf, n, 15, 17);
        return enc_mem_result(buf, mem_tail_put(buf, put(buf, m, yv_l(yr_get(t, "modrm"))), t), t);
    } else {
        return enc_err(at, ys("movsd form"));
    }
}

static Yv *enc_sqrtsd(Yv *buf, long at, Yv *dst, Yv *src) {
    /* F2 0F 51 /r  — sqrtsd %xmm, %xmm */
    if (yv_l(yr_get(dst, "k")) != K_reg) {
        return enc_err(at, ys("sqrtsd dst"));
    } else if (yv_l(yr_get(src, "k")) != K_reg) {
        return enc_err(at, ys("sqrtsd src"));
    } else {
        long n = put(buf, at, 242);
        long m = put_rex(buf, n, rex(0, yv_l(yr_get(dst, "n")), -1, yv_l(yr_get(src, "n"))));
        return enc_ok(put3(buf, m, 15, 81, modrm(3, yv_l(yr_get(dst, "n")), yv_l(yr_get(src, "n")))), yav(0));
    }
}

static Yv *enc_ucomisd(Yv *buf, long at, Yv *dst, Yv *src) {
    /* 66 0F 2E /r */
    if (yv_l(yr_get(dst, "k")) != K_reg) {
        return enc_err(at, ys("ucomisd dst"));
    } else if (yv_l(yr_get(src, "k")) != K_reg) {
        return enc_err(at, ys("ucomisd src"));
    } else {
        long n = put(buf, at, 102);
        long m = put_rex(buf, n, rex(0, yv_l(yr_get(dst, "n")), -1, yv_l(yr_get(src, "n"))));
        return enc_ok(put3(buf, m, 15, 46, modrm(3, yv_l(yr_get(dst, "n")), yv_l(yr_get(src, "n")))), yav(0));
    }
}

static Yv *enc_cvtsi2sd(Yv *buf, long at, Yv *dst, Yv *src) {
    /* F2 REX.W 0F 2A /r  — cvtsi2sd %gpr, %xmm */
    if (yv_l(yr_get(dst, "k")) != K_reg) {
        return enc_err(at, ys("cvtsi2sd dst"));
    } else if (yv_l(yr_get(src, "k")) != K_reg) {
        return enc_err(at, ys("cvtsi2sd src"));
    } else {
        long n = put(buf, at, 242);
        long m = put(buf, n, rex(1, yv_l(yr_get(dst, "n")), -1, yv_l(yr_get(src, "n"))));
        return enc_ok(put3(buf, m, 15, 42, modrm(3, yv_l(yr_get(dst, "n")), yv_l(yr_get(src, "n")))), yav(0));
    }
}

static Yv *enc_cvttsd2si(Yv *buf, long at, Yv *dst, Yv *src) {
    /* F2 REX.W 0F 2C /r  — cvttsd2si %xmm, %gpr (truncating) */
    if (yv_l(yr_get(dst, "k")) != K_reg) {
        return enc_err(at, ys("cvttsd2si dst"));
    } else if (yv_l(yr_get(src, "k")) != K_reg) {
        return enc_err(at, ys("cvttsd2si src"));
    } else {
        long n = put(buf, at, 242);
        long m = put(buf, n, rex(1, yv_l(yr_get(dst, "n")), -1, yv_l(yr_get(src, "n"))));
        return enc_ok(put3(buf, m, 15, 44, modrm(3, yv_l(yr_get(dst, "n")), yv_l(yr_get(src, "n")))), yav(0));
    }
}

static Yv *enc_movq(Yv *buf, long at, Yv *dst, Yv *src) {
    /* 66 REX.W 0F 6E /r  — movq %gpr, %xmm   (gpr -> xmm)
       66 REX.W 0F 7E /r  — movq %xmm, %gpr   (xmm -> gpr) */
    if (yv_l(yr_get(dst, "k")) != K_reg) {
        return enc_err(at, ys("movq dst"));
    } else if (yv_l(yr_get(src, "k")) != K_reg) {
        return enc_err(at, ys("movq src"));
    } else if (op_size(dst) == 128) {
        /* into an xmm: the xmm is the reg field, the gpr the rm field */
        long n = put(buf, at, 102);
        long m = put(buf, n, rex(1, yv_l(yr_get(dst, "n")), -1, yv_l(yr_get(src, "n"))));
        return enc_ok(put3(buf, m, 15, 110, modrm(3, yv_l(yr_get(dst, "n")), yv_l(yr_get(src, "n")))), yav(0));
    } else if (op_size(src) != 128) {
        /* Neither side is an xmm, so this is not a float move at all. Taking
           it as one would quietly read an SSE register and write a GPR (or the
           other way round) where the source said a register move -- a silent
           miscompile, and this assembler's one rule is to be loud instead. */
        return enc_err(at, ys("movq needs an xmm register"));
    } else {
        /* out of an xmm: 66 REX.W 0F 7E /r is reg=xmm, rm=r/m64 */
        long n = put(buf, at, 102);
        long m = put(buf, n, rex(1, yv_l(yr_get(src, "n")), -1, yv_l(yr_get(dst, "n"))));
        return enc_ok(put3(buf, m, 15, 126, modrm(3, yv_l(yr_get(src, "n")), yv_l(yr_get(dst, "n")))), yav(0));
    }
}

static Yv *enc_imul(Yv *buf, long at, Yv *dst, Yv *src) {
    if (yv_l(yr_get(dst, "k")) == K_reg && op_size(dst) == 64
        && yv_l(yr_get(src, "k")) == K_reg && op_size(src) == 64) {
        long n = put_rex(buf, at, rex(1, yv_l(yr_get(dst, "n")), -1, yv_l(yr_get(src, "n"))));
        return enc_ok(put3(buf, n, 15, 175, modrm(3, yv_l(yr_get(dst, "n")), yv_l(yr_get(src, "n")))), yav(0));
    } else {
        return enc_err(at, ys("imul form"));
    }
}

static Yv *enc_unary(Yv *buf, long at, Yv *op, Yv *o) {
    if (yv_l(yr_get(o, "k")) == K_mem) {
        return enc_unary_mem(buf, at, op, o);
    } else if (yv_l(yr_get(o, "k")) != K_reg) {
        return enc_err(at, ys("unary form"));
    } else if (op_size(o) != 64) {
        return enc_err(at, ys("unary form"));
    } else {
        long ext = 3;
        long opc = 247;
        if (ys_eq_lit(op, "idiv")) { ext = 7; }
        else if (ys_eq_lit(op, "div")) { ext = 6; }
        else if (ys_eq_lit(op, "not")) { ext = 2; }
        else if (ys_eq_lit(op, "dec")) { ext = 1; opc = 255; }
        else if (ys_eq_lit(op, "inc")) { ext = 0; opc = 255; }
        long n = put_rex(buf, at, rex(1, -1, -1, yv_l(yr_get(o, "n"))));
        return enc_ok(put2(buf, n, opc, modrm(3, ext, yv_l(yr_get(o, "n")))), yav(0));
    }
}

static Yv *enc_unary_mem(Yv *buf, long at, Yv *op, Yv *o) {
    /* (split from enc_unary: the shape gate above narrows; this body sees a
       memory operand, hence a ModRM that is not mod=11.) inc/dec/not have
       memory forms -- FF /0, FF /1, F7 /2 -- and are 64-bit here for the same
       reason the ALU form is. idiv/div/imul/neg do not (their encoding is
       F7 with mod=11 only), so they stay an error. */
    long ext = 0;
    long opc = 255;
    if (ys_eq_lit(op, "dec")) { ext = 1; }
    else if (ys_eq_lit(op, "not")) { ext = 2; opc = 247; }
    if (ys_eq_lit(op, "inc") || ys_eq_lit(op, "dec") || ys_eq_lit(op, "not")) {
        Yv *t = mem_tail(o, ext);
        long n = put_rex(buf, at, rex_rm(1, ext, o));
        long m = put2(buf, n, opc, yv_l(yr_get(t, "modrm")));
        return enc_mem_result(buf, mem_tail_put(buf, m, t), t);
    } else {
        return enc_err(at, ys("unary form"));
    }
}

/* A branch is encoded in the short (rel8) or long (rel32) form on request:
   `EB rel8` / `E9 rel32`, and `70+cc rel8` / `0F 80+cc rel32` for a
   conditional. Which form an instruction gets is not the encoder's to decide —
   an instruction's length has to be known before the addresses are, and a
   branch's target is usually not where it is yet — so the assembler asks for
   short first and grows the ones that turn out to be out of range (asm.y's
   asm_relax). `code` is the long form's condition byte (0x84 for je, 0x85 for
   jne, ...), which setcc shares. */
static Yv *enc_jmp(Yv *buf, long at, Yv *o, int lng) {
    if (yv_l(yr_get(o, "k")) != K_lbl) {
        return enc_err(at, ys("jmp target"));
    } else if (lng) {
        long n = put(buf, at, 233);
        long m = put_le32(buf, n, 0);
        return enc_br(m, yav(1, fixup(at + 1, ys("rel32"), yr_get(o, "name"), ys(""))), 0);
    } else {
        long n = put(buf, at, 235);
        return enc_br(put(buf, n, 0), yav(1, fixup(at + 1, ys("rel8"), yr_get(o, "name"), ys(""))), 0);
    }
}

static Yv *enc_call(Yv *buf, long at, Yv *o) {
    if (yv_l(yr_get(o, "k")) == K_ind) {
        /* call *%reg — FF /2, used for closure code pointers. */
        long n = put_rex(buf, at, rex(0, 0, -1, yv_l(yr_get(o, "n"))));
        return enc_ok(put2(buf, n, 255, modrm(3, 2, yv_l(yr_get(o, "n")))), yav(0));
    } else if (yv_l(yr_get(o, "k")) != K_lbl) {
        return enc_err(at, ys("call target"));
    } else {
        long n = put(buf, at, 232);
        long m = put_le32(buf, n, 0);
        return enc_ok(m, yav(1, fixup(at + 1, ys("rel32"), yr_get(o, "name"), ys(""))));
    }
}

static Yv *enc_jcc(Yv *buf, long at, long code, Yv *o, int lng) {
    if (yv_l(yr_get(o, "k")) != K_lbl) {
        return enc_err(at, ys("jcc target"));
    } else if (lng) {
        long n = put2(buf, at, 15, code);
        long m = put_le32(buf, n, 0);
        return enc_br(m, yav(1, fixup(at + 2, ys("rel32"), yr_get(o, "name"), ys(""))), code);
    } else {
        /* the short form's opcode is the long form's 16 bytes lower */
        long n = put(buf, at, code - 16);
        return enc_br(put(buf, n, 0), yav(1, fixup(at + 1, ys("rel8"), yr_get(o, "name"), ys(""))), code);
    }
}

static Yv *enc_setcc(Yv *buf, long at, long code, Yv *o) {
    if (yv_l(yr_get(o, "k")) != K_reg || op_size(o) != 8) {
        return enc_err(at, ys("setcc form"));
    } else {
        long n = put_rex(buf, at, rex(0, -1, -1, yv_l(yr_get(o, "n"))));
        return enc_ok(put3(buf, n, 15, code, modrm(3, 0, yv_l(yr_get(o, "n")))), yav(0));
    }
}

/* cmpb $imm8, mem8. No emitter produces this form (the byte comparisons the
   backend needs all go through movzbq), but the assembler accepts it, so it
   goes through enc_mem_imm_result like the other immediate forms: the rip
   placeholder belongs between the ModRM and the immediate, not after it. */
static Yv *enc_cmpb(Yv *buf, long at, long v, Yv *m) {
    if (yv_l(yr_get(m, "k")) != K_mem) {
        return enc_err(at, ys("cmpb form"));
    } else {
        Yv *t = mem_tail(m, 7);
        long n = put_rex(buf, at, rex_rm(0, 7, m));
        long q = put2(buf, n, 128, yv_l(yr_get(t, "modrm")));
        return enc_mem_imm_result(buf, mem_tail_put(buf, q, t), t, v, 0);
    }
}

static Yv *enc_movb_reg(Yv *buf, long at, Yv *dst, Yv *src) {
    /* movb %r8 -> mem8 (single-byte stores for string data) */
    if (yv_l(yr_get(dst, "k")) == K_mem && yv_l(yr_get(src, "k")) == K_reg && op_size(src) == 8) {
        Yv *t = mem_tail(dst, yv_l(yr_get(src, "n")));
        long n = put_rex(buf, at, rex_rm(0, yv_l(yr_get(src, "n")), dst));
        long m = put2(buf, n, 136, yv_l(yr_get(t, "modrm")));
        return enc_mem_result(buf, mem_tail_put(buf, m, t), t);
    } else {
        return enc_err(at, ys("movb reg form"));
    }
}

/* ── mnemonic dispatch ───────────────────────────────────────────────────
   A ladder of string comparisons, and it stays one: the plan wanted a
   mnemonic id ("dispatch on a mnemonic id rather than a string"), and the id
   version is measurably SLOWER on this tree. Encoding ycc.y walks this ladder
   6.69 arms deep per instruction; a whole-string comparison costs 29
   instructions (measured), and a *character* read — what a hash walk needs —
   costs 35 (measured), so hashing a 3-character name costs about what six
   ladder arms do, and the id table came out +0.62% on every benchmark. The
   whole dispatch is 194 instructions per emitted instruction, 0.85% of a
   compile; an ordering that only reorders it by this workload's frequencies
   would buy 0.30% and make the ladder's order a function of the corpus. The
   id is worth having when the emitter stops producing text (Part 4 stage 2);
   until then this ladder is the cheapest dispatch the primitives allow. */
static Yv *need1(Yv *mn, Yv *ops) {
    if (yv_len(ops) != 1) { return ys_cat(mn, ys(" takes 1 operand")); } else { return ys(""); }
}

static Yv *need2(Yv *mn, Yv *ops) {
    if (yv_len(ops) != 2) { return ys_cat(mn, ys(" takes 2 operands")); } else { return ys(""); }
}

/* `lng` is the branch form: 0 asks for the short (rel8) encoding, 1 for
   rel32. Only jmp and the jcc family read it; everything else ignores it.
   See enc_jmp for why it is a parameter and not the encoder's own decision. */
Yv *enc_insn(Yv *buf, long at, Yv *mn, Yv *ops, int lng) {
    if (ys_eq_lit(mn, "push")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_push(buf, at, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "pop")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_pop(buf, at, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "mov")) {
        Yv *e = need2(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_mov(buf, at, ya_get(ops, 1), ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "movb")) {
        Yv *e = need2(mn, ops);
        if (!ys_eq_lit(e, "")) {
            return enc_err(at, e);
        } else if (yv_l(yr_get(ya_get(ops, 0), "k")) == K_imm) {
            return enc_movb(buf, at, ya_get(ops, 1), ya_get(ops, 0));
        } else {
            return enc_movb_reg(buf, at, ya_get(ops, 1), ya_get(ops, 0));
        }
    } else if (ys_eq_lit(mn, "movzbq")) {
        Yv *e = need2(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_movzbq(buf, at, ya_get(ops, 1), ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "lea")) {
        Yv *e = need2(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_lea(buf, at, ya_get(ops, 1), ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "xchg")) {
        Yv *e = need2(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_xchg(buf, at, ya_get(ops, 0), ya_get(ops, 1)); }
    } else if (ys_eq_lit(mn, "add") || ys_eq_lit(mn, "sub") || ys_eq_lit(mn, "cmp") || ys_eq_lit(mn, "xor") || ys_eq_lit(mn, "and") || ys_eq_lit(mn, "or") || ys_eq_lit(mn, "test")) {
        Yv *e = need2(mn, ops);
        if (!ys_eq_lit(e, "")) {
            return enc_err(at, e);
        } else {
            Yv *dst = ya_get(ops, 1);
            Yv *src = ya_get(ops, 0);
            if (yv_l(yr_get(src, "k")) == K_imm) {
                if (ys_eq_lit(mn, "add") || ys_eq_lit(mn, "sub") || ys_eq_lit(mn, "cmp") || ys_eq_lit(mn, "xor") || ys_eq_lit(mn, "and") || ys_eq_lit(mn, "or")) {
                    return enc_alu_imm(buf, at, mn, dst, yv_l(yr_get(src, "v")));
                } else {
                    return enc_err(at, ys_cat(mn, ys(" imm form")));
                }
            } else if (yv_l(yr_get(dst, "k")) == K_reg && yv_l(yr_get(src, "k")) == K_reg
                       && ys_eq_lit(mn, "xor") && op_size(dst) == 32 && op_size(src) == 32) {
                return enc_xor32(buf, at, dst, src);
            } else {
                return enc_arith(buf, at, mn, dst, src);
            }
        }
    } else if (ys_eq_lit(mn, "shl") || ys_eq_lit(mn, "shr") || ys_eq_lit(mn, "sar")) {
        Yv *e = need2(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_shift(buf, at, mn, ya_get(ops, 1), ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "addsd") || ys_eq_lit(mn, "subsd") || ys_eq_lit(mn, "mulsd") || ys_eq_lit(mn, "divsd")) {
        Yv *e = need2(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_sse_arith(buf, at, mn, ya_get(ops, 1), ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "movsd")) {
        Yv *e = need2(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_movsd(buf, at, ya_get(ops, 1), ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "sqrtsd")) {
        Yv *e = need2(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_sqrtsd(buf, at, ya_get(ops, 1), ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "ucomisd")) {
        Yv *e = need2(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_ucomisd(buf, at, ya_get(ops, 1), ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "cvtsi2sd")) {
        Yv *e = need2(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_cvtsi2sd(buf, at, ya_get(ops, 1), ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "cvttsd2si")) {
        Yv *e = need2(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_cvttsd2si(buf, at, ya_get(ops, 1), ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "movq")) {
        Yv *e = need2(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_movq(buf, at, ya_get(ops, 1), ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "imul")) {
        Yv *e = need2(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_imul(buf, at, ya_get(ops, 1), ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "neg") || ys_eq_lit(mn, "not") || ys_eq_lit(mn, "idiv") || ys_eq_lit(mn, "div") || ys_eq_lit(mn, "dec") || ys_eq_lit(mn, "inc")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_unary(buf, at, mn, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "jmp")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_jmp(buf, at, ya_get(ops, 0), lng); }
    } else if (ys_eq_lit(mn, "call")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_call(buf, at, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "jz") || ys_eq_lit(mn, "je")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_jcc(buf, at, 132, ya_get(ops, 0), lng); }
    } else if (ys_eq_lit(mn, "jp") || ys_eq_lit(mn, "jpe")) {
        /* parity set: how an SSE comparison says "unordered", which is to say
         * that one operand was a NaN -- the first test of every float function */
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_jcc(buf, at, 138, ya_get(ops, 0), lng); }
    } else if (ys_eq_lit(mn, "jnp") || ys_eq_lit(mn, "jpo")) {
        /* parity clear: the same test, for the other side of the branch */
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_jcc(buf, at, 139, ya_get(ops, 0), lng); }
    } else if (ys_eq_lit(mn, "ja") || ys_eq_lit(mn, "jnbe")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_jcc(buf, at, 135, ya_get(ops, 0), lng); }
    } else if (ys_eq_lit(mn, "jae") || ys_eq_lit(mn, "jnb") || ys_eq_lit(mn, "jnc")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_jcc(buf, at, 131, ya_get(ops, 0), lng); }
    } else if (ys_eq_lit(mn, "jbe") || ys_eq_lit(mn, "jna")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_jcc(buf, at, 134, ya_get(ops, 0), lng); }
    } else if (ys_eq_lit(mn, "jnz") || ys_eq_lit(mn, "jne")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_jcc(buf, at, 133, ya_get(ops, 0), lng); }
    } else if (ys_eq_lit(mn, "js")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_jcc(buf, at, 136, ya_get(ops, 0), lng); }
    } else if (ys_eq_lit(mn, "jns")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_jcc(buf, at, 137, ya_get(ops, 0), lng); }
    } else if (ys_eq_lit(mn, "jge")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_jcc(buf, at, 141, ya_get(ops, 0), lng); }
    } else if (ys_eq_lit(mn, "jl")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_jcc(buf, at, 140, ya_get(ops, 0), lng); }
    } else if (ys_eq_lit(mn, "jle")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_jcc(buf, at, 142, ya_get(ops, 0), lng); }
    } else if (ys_eq_lit(mn, "jg")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_jcc(buf, at, 143, ya_get(ops, 0), lng); }
    } else if (ys_eq_lit(mn, "jb")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_jcc(buf, at, 130, ya_get(ops, 0), lng); }
    } else if (ys_eq_lit(mn, "setl")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_setcc(buf, at, 156, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "setg")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_setcc(buf, at, 159, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "setle")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_setcc(buf, at, 158, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "setge")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_setcc(buf, at, 157, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "sete")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_setcc(buf, at, 148, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "setne")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_setcc(buf, at, 149, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "seta")) {
        /* unsigned >: the correct condition after ucomisd (floats) */
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_setcc(buf, at, 151, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "setae")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_setcc(buf, at, 147, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "setb")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_setcc(buf, at, 146, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "setbe")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_setcc(buf, at, 150, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "setp")) {
        /* parity set: after ucomisd, unordered */
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_setcc(buf, at, 154, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "setnp")) {
        /* parity clear: after ucomisd, ordered */
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return enc_err(at, e); } else { return enc_setcc(buf, at, 155, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "cmpb")) {
        Yv *e = need2(mn, ops);
        if (!ys_eq_lit(e, "")) {
            return enc_err(at, e);
        } else if (yv_l(yr_get(ya_get(ops, 0), "k")) != K_imm) {
            return enc_err(at, ys("cmpb needs imm"));
        } else {
            return enc_cmpb(buf, at, yv_l(yr_get(ya_get(ops, 0), "v")), ya_get(ops, 1));
        }
    } else if (ys_eq_lit(mn, "cqo")) {
        return enc_ok(put2(buf, at, 72, 153), yav(0));
    } else if (ys_eq_lit(mn, "syscall")) {
        return enc_ok(put2(buf, at, 15, 5), yav(0));
    } else if (ys_eq_lit(mn, "ret")) {
        return enc_ok(put(buf, at, 195), yav(0));
    } else {
        return enc_err(at, ys_cat(ys_cat(ys("unknown mnemonic '"), mn), ys("'")));
    }
}