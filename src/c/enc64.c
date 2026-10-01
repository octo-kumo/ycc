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
 * Every enc_* returns {bytes, fix, err}; bytes is a list of byte values
 * (0-255), which the C value model keeps boxed as long values.
 * le16/le32/le64/byte_of return the byte list itself.
 * Only the forms our backend emits exist here — anything else is a loud
 * error from the assembler, never a silent miscompile.
 */
#include "enc64.h"

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
static long rex_rm(int w, long reg, Yv *m);
static Yv *with_rex(long r, Yv *bytes);
static Yv *enc_mem_result(long r, Yv *b, Yv *t);
static Yv *enc_push(Yv *o);
static Yv *enc_pop(Yv *o);
static Yv *enc_mov(Yv *dst, Yv *src);
static Yv *enc_movb(Yv *dst, Yv *src);
static Yv *enc_movb_imm(Yv *dst, Yv *src);
static Yv *enc_movzbq(Yv *dst, Yv *src);
static Yv *enc_lea(Yv *dst, Yv *src);
static Yv *enc_arith(Yv *op, Yv *dst, Yv *src);
static Yv *enc_xor32(Yv *dst, Yv *src);
static Yv *enc_alu_imm(Yv *op, Yv *dst, long v);
static Yv *enc_alu_imm_go(Yv *op, Yv *dst, long v);
static Yv *enc_alu_imm_body(Yv *op, Yv *dst, long v);
static Yv *enc_shl(Yv *dst, long v);
static Yv *enc_shr(Yv *dst, long v);
static Yv *enc_sse_arith(Yv *mn, Yv *dst, Yv *src);
static Yv *enc_ucomisd(Yv *dst, Yv *src);
static Yv *enc_cvtsi2sd(Yv *dst, Yv *src);
static Yv *enc_cvttsd2si(Yv *dst, Yv *src);
static Yv *enc_movq(Yv *dst, Yv *src);
static Yv *enc_imul(Yv *dst, Yv *src);
static Yv *enc_unary(Yv *op, Yv *o);
static Yv *enc_jmp(Yv *o);
static Yv *enc_call(Yv *o);
static Yv *enc_jcc(long code, Yv *o);
static Yv *enc_setcc(long code, Yv *o);
static Yv *enc_cmpb(long v, Yv *m);
static Yv *enc_movb_reg(Yv *dst, Yv *src);
static Yv *need1(Yv *mn, Yv *ops);
static Yv *need2(Yv *mn, Yv *ops);

Yv *r64(long n) {
    return yr(3, "k", ys("reg"), "n", yv_long(n), "size", yv_long(64));
}

/* r32/r8 are module defs nothing in the tree calls (kept 1:1); external
   linkage keeps -Wunused-function quiet without widening the header. */
Yv *r32(long n) {
    return yr(3, "k", ys("reg"), "n", yv_long(n), "size", yv_long(32));
}

Yv *r8(long n) {
    return yr(3, "k", ys("reg"), "n", yv_long(n), "size", yv_long(8));
}

/* Register number by AT&T name. Supports the registers our backend uses. */
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

/* Safe size read: a non-register yields 0 without touching `.size`. A
   field read of a key the record does not carry is a run-time trap in the
   native backend (the y_dot_lookup primitive in arch_x64.y), so this shape
   gate is what keeps a mem/lbl/imm operand from faulting. (`&&`
   short-circuits — gen_bin / gen_logic in native.y — so `o.k == "reg" &&
   o.size` would be safe too; the gate stays as the explicit form.) */
static long op_size(Yv *o) {
    if (ys_eq_lit(yr_get(o, "k"), "reg")) { return yv_l(yr_get(o, "size")); } else { return 0; }
}

static long rex(int w, long r, long x, long b) {
    long v = 64;
    if (w) { v = v + 8; ; }
    if (r >= 8) { v = v + 4; ; }
    if (x >= 8) { v = v + 2; ; }
    if (b >= 8) { v = v + 1; ; }
    if (v == 64) { return -1; } else { return v; }
}

static long modrm(long mod, long reg, long rm) {
    return mod * 64 + (reg % 8) * 8 + rm % 8;
}

static long sib(long scale, long index, long base) {
    long s = 0;
    if (scale == 2) { s = 1; ; } else if (scale == 4) { s = 2; ; } else if (scale == 8) { s = 3; ; }
    return s * 64 + (index % 8) * 8 + base % 8;
}

Yv *le16(long v) {
    Yv *out = yav(2, yv_long(byte_of(v, 0)), yv_long(byte_of(v, 1)));
    return out;
}

Yv *le32(long v) {
    Yv *out = yav(4, yv_long(byte_of(v, 0)), yv_long(byte_of(v, 1)),
                  yv_long(byte_of(v, 2)), yv_long(byte_of(v, 3)));
    return out;
}

Yv *le64(long v) {
    Yv *out = yav(8, yv_long(byte_of(v, 0)), yv_long(byte_of(v, 1)),
                  yv_long(byte_of(v, 2)), yv_long(byte_of(v, 3)),
                  yv_long(byte_of(v, 4)), yv_long(byte_of(v, 5)),
                  yv_long(byte_of(v, 6)), yv_long(byte_of(v, 7)));
    return out;
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

static long div_floor(long v, long d) {
    /* NOTE: Y division truncates toward zero (C semantics — native.y emits
       `cqo; idiv` for `/`), so floor needs a correction when the remainder
       is nonzero and the signs differ. Both engines truncate the same way,
       so one correction serves them both. */
    long q = v / d;
    long r = v - q * d;
    if (r != 0) {
        if (v < 0) {
            if (d > 0) { q = q - 1; ; }
            ;
        } else if (d < 0) { q = q - 1; ; }
        ;
    }
    return q;
}

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

/* Encode a memory operand tail (ModRM + optional SIB + displacement).
   Returns {modrm, extra: [byte], rip_lbl/"", disp32: bool} — the caller
   supplies the reg field and any label fixup. */
static Yv *mem_tail(Yv *m, long reg) {
    if (yv_b(yr_get(m, "rip"))) {
        return yr(4, "modrm", yv_long(modrm(0, reg, 5)), "extra", yav(0),
                  "rip_lbl", yr_get(m, "lbl"), "disp32", yv_bool(1));
    } else if (yv_l(yr_get(m, "idx")) < 0) {
        /* no index: [base+disp]. Low 101 (rbp/r13) needs at least disp8
           (mod=00 would mean disp32-only); low 100 (rsp/r12) needs a SIB
           byte whose base field is 100 — which is rsp, or r12 once REX.B
           widens it (rex_rm sets that from m.base). */
        if (yv_l(yr_get(m, "base")) % 8 == 5) {
            if (fits8(yv_l(yr_get(m, "disp")))) {
                Yv *extra = yav(1, yv_long(u8(yv_l(yr_get(m, "disp")))));
                return yr(4, "modrm", yv_long(modrm(1, reg, 5)),
                          "extra", extra,
                          "rip_lbl", ys(""), "disp32", yv_bool(0));
            } else {
                return yr(4, "modrm", yv_long(modrm(2, reg, 5)),
                          "extra", le32(yv_l(yr_get(m, "disp"))),
                          "rip_lbl", ys(""), "disp32", yv_bool(0));
            }
        } else if (yv_l(yr_get(m, "base")) % 8 == 4) {
            /* rsp/r12 as base: SIB byte required (index=none, base=rsp).
               sib(1, 4, 4) = scale 00, index 100 (none), base 100 (rsp). */
            long s = sib(1, 4, 4);
            if (yv_l(yr_get(m, "disp")) == 0) {
                Yv *extra = yav(1, yv_long(s));
                return yr(4, "modrm", yv_long(modrm(0, reg, 4)),
                          "extra", extra,
                          "rip_lbl", ys(""), "disp32", yv_bool(0));
            } else if (fits8(yv_l(yr_get(m, "disp")))) {
                Yv *extra = yav(2, yv_long(s), yv_long(u8(yv_l(yr_get(m, "disp")))));
                return yr(4, "modrm", yv_long(modrm(1, reg, 4)),
                          "extra", extra,
                          "rip_lbl", ys(""), "disp32", yv_bool(0));
            } else {
                Yv *prefix = yav(1, yv_long(s));
                return yr(4, "modrm", yv_long(modrm(2, reg, 4)),
                          "extra", concat(prefix, le32(yv_l(yr_get(m, "disp")))),
                          "rip_lbl", ys(""), "disp32", yv_bool(0));
            }
        } else if (yv_l(yr_get(m, "disp")) == 0) {
            return yr(4, "modrm", yv_long(modrm(0, reg, yv_l(yr_get(m, "base")))),
                      "extra", yav(0), "rip_lbl", ys(""), "disp32", yv_bool(0));
        } else if (fits8(yv_l(yr_get(m, "disp")))) {
            Yv *extra = yav(1, yv_long(u8(yv_l(yr_get(m, "disp")))));
            return yr(4, "modrm", yv_long(modrm(1, reg, yv_l(yr_get(m, "base")))),
                      "extra", extra,
                      "rip_lbl", ys(""), "disp32", yv_bool(0));
        } else {
            return yr(4, "modrm", yv_long(modrm(2, reg, yv_l(yr_get(m, "base")))),
                      "extra", le32(yv_l(yr_get(m, "disp"))),
                      "rip_lbl", ys(""), "disp32", yv_bool(0));
        }
    } else {
        /* SIB: [base + idx*scale + disp]. Low 101 needs explicit disp. */
        long s = sib(yv_l(yr_get(m, "scale")), yv_l(yr_get(m, "idx")), yv_l(yr_get(m, "base")));
        if (yv_l(yr_get(m, "base")) % 8 == 5) {
            if (fits8(yv_l(yr_get(m, "disp")))) {
                Yv *extra = yav(2, yv_long(s), yv_long(u8(yv_l(yr_get(m, "disp")))));
                return yr(4, "modrm", yv_long(modrm(1, reg, 4)),
                          "extra", extra,
                          "rip_lbl", ys(""), "disp32", yv_bool(0));
            } else {
                Yv *prefix = yav(1, yv_long(s));
                return yr(4, "modrm", yv_long(modrm(2, reg, 4)),
                          "extra", concat(prefix, le32(yv_l(yr_get(m, "disp")))),
                          "rip_lbl", ys(""), "disp32", yv_bool(0));
            }
        } else if (yv_l(yr_get(m, "disp")) == 0) {
            Yv *extra = yav(1, yv_long(s));
            return yr(4, "modrm", yv_long(modrm(0, reg, 4)),
                      "extra", extra,
                      "rip_lbl", ys(""), "disp32", yv_bool(0));
        } else if (fits8(yv_l(yr_get(m, "disp")))) {
            Yv *extra = yav(2, yv_long(s), yv_long(u8(yv_l(yr_get(m, "disp")))));
            return yr(4, "modrm", yv_long(modrm(1, reg, 4)),
                      "extra", extra,
                      "rip_lbl", ys(""), "disp32", yv_bool(0));
        } else {
            Yv *prefix = yav(1, yv_long(s));
            return yr(4, "modrm", yv_long(modrm(2, reg, 4)),
                      "extra", concat(prefix, le32(yv_l(yr_get(m, "disp")))),
                      "rip_lbl", ys(""), "disp32", yv_bool(0));
        }
    }
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

Yv *concat(Yv *a, Yv *b) {
    Yv *out = yav(0);
    long i = 0;
    while (i < yv_len(a)) {
        out = ya_push(out, ya_get(a, i));
        i = i + 1;
    }
    long j = 0;
    while (j < yv_len(b)) {
        out = ya_push(out, ya_get(b, j));
        j = j + 1;
    }
    return out;
}

/* Fixup record for label-relative fields, resolved in pass 2:
   {off, kind, lbl, lbl2} (off relative to instruction start).
   kind: "rel32" (call/jmp/jcc), "rip32", "imm32diff". */
Yv *fixup(long at, Yv *kind, Yv *lbl, Yv *lbl2) {
    return yr(4, "off", yv_long(at), "kind", kind, "lbl", lbl, "lbl2", lbl2);
}

/* ── instruction encoders ───────────────────────────────────────────────
   Each returns {bytes, fix: [{off, kind, lbl, lbl2}], err} with off
   relative to the instruction start. Only forms our backend emits exist. */

static Yv *with_rex(long r, Yv *bytes) {
    if (r < 0) {
        return bytes;
    } else {
        Yv *prefix = yav(1, yv_long(r));
        return concat(prefix, bytes);
    }
}

static Yv *enc_push(Yv *o) {
    if (!ys_eq_lit(yr_get(o, "k"), "reg")) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("push needs r64"));
    } else if (op_size(o) != 64) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("push needs r64"));
    } else {
        long r = rex(0, -1, -1, yv_l(yr_get(o, "n")));
        Yv *b = yav(1, yv_long(80 + (yv_l(yr_get(o, "n")) % 8)));
        return yr(3, "bytes", with_rex(r, b), "fix", yav(0), "err", ys(""));
    }
}

static Yv *enc_pop(Yv *o) {
    if (!ys_eq_lit(yr_get(o, "k"), "reg")) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("pop needs r64"));
    } else if (op_size(o) != 64) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("pop needs r64"));
    } else {
        long r = rex(0, -1, -1, yv_l(yr_get(o, "n")));
        Yv *b = yav(1, yv_long(88 + (yv_l(yr_get(o, "n")) % 8)));
        return yr(3, "bytes", with_rex(r, b), "fix", yav(0), "err", ys(""));
    }
}

static Yv *enc_mov(Yv *dst, Yv *src) {
    if (ys_eq_lit(yr_get(dst, "k"), "reg") && ys_eq_lit(yr_get(src, "k"), "reg")) {
        if (op_size(dst) == 64 && op_size(src) == 64) {
            long r = rex(1, yv_l(yr_get(src, "n")), -1, yv_l(yr_get(dst, "n")));
            Yv *b = yav(2, yv_long(137), yv_long(modrm(3, yv_l(yr_get(src, "n")), yv_l(yr_get(dst, "n")))));
            return yr(3, "bytes", with_rex(r, b), "fix", yav(0), "err", ys(""));
        } else {
            return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("mov reg,reg size mix"));
        }
    } else if (ys_eq_lit(yr_get(dst, "k"), "reg") && ys_eq_lit(yr_get(src, "k"), "imm")) {
        if (op_size(dst) == 64) {
            if (yv_l(yr_get(src, "v")) >= -2147483648 && yv_l(yr_get(src, "v")) <= 2147483647) {
                long r = rex(1, -1, -1, yv_l(yr_get(dst, "n")));
                Yv *prefix = yav(2, yv_long(199), yv_long(modrm(3, 0, yv_l(yr_get(dst, "n")))));
                Yv *b = concat(prefix, le32(yv_l(yr_get(src, "v"))));
                return yr(3, "bytes", with_rex(r, b), "fix", yav(0), "err", ys(""));
            } else {
                long r = rex(1, -1, -1, yv_l(yr_get(dst, "n")));
                Yv *prefix = yav(1, yv_long(184 + (yv_l(yr_get(dst, "n")) % 8)));
                Yv *b = concat(prefix, le64(yv_l(yr_get(src, "v"))));
                return yr(3, "bytes", with_rex(r, b), "fix", yav(0), "err", ys(""));
            }
        } else if (op_size(dst) == 32) {
            long r = rex(0, -1, -1, yv_l(yr_get(dst, "n")));
            Yv *prefix = yav(2, yv_long(199), yv_long(modrm(3, 0, yv_l(yr_get(dst, "n")))));
            Yv *b = concat(prefix, le32(yv_l(yr_get(src, "v"))));
            return yr(3, "bytes", with_rex(r, b), "fix", yav(0), "err", ys(""));
        } else {
            return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("mov imm size"));
        }
    } else if (ys_eq_lit(yr_get(dst, "k"), "reg") && op_size(dst) == 64 && ys_eq_lit(yr_get(src, "k"), "diff")) {
        long r = rex(1, -1, -1, yv_l(yr_get(dst, "n")));
        Yv *prefix = yav(2, yv_long(199), yv_long(modrm(3, 0, yv_l(yr_get(dst, "n")))));
        Yv *zeros = yav(4, yv_long(0), yv_long(0), yv_long(0), yv_long(0));
        Yv *b = concat(prefix, zeros);
        long off = 3;
        if (r < 0) { off = 2; ; }
        return yr(3, "bytes", with_rex(r, b),
                  "fix", yav(1, fixup(off, ys("imm32diff"), yr_get(src, "a"), yr_get(src, "b"))), "err", ys(""));
    } else if (ys_eq_lit(yr_get(dst, "k"), "reg") && ys_eq_lit(yr_get(src, "k"), "mem")) {
        if (op_size(dst) == 64) {
            Yv *t = mem_tail(src, yv_l(yr_get(dst, "n")));
            long r = rex_rm(1, yv_l(yr_get(dst, "n")), src);
            Yv *prefix = yav(2, yv_long(139), yr_get(t, "modrm"));
            Yv *b = concat(prefix, yr_get(t, "extra"));
            return enc_mem_result(r, b, t);
        } else {
            return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("mov r,mem size"));
        }
    } else if (ys_eq_lit(yr_get(dst, "k"), "mem") && ys_eq_lit(yr_get(src, "k"), "imm")) {
        /* mov $imm32, mem (length/cap stores) */
        Yv *t = mem_tail(dst, 0);
        long r = rex_rm(1, 0, dst);
        Yv *prefix = yav(2, yv_long(199), yr_get(t, "modrm"));
        Yv *b = concat(concat(prefix, yr_get(t, "extra")), le32(yv_l(yr_get(src, "v"))));
        return enc_mem_result(r, b, t);
    } else if (ys_eq_lit(yr_get(dst, "k"), "mem") && ys_eq_lit(yr_get(src, "k"), "reg")) {
        if (op_size(src) == 64) {
            Yv *t = mem_tail(dst, yv_l(yr_get(src, "n")));
            long r = rex_rm(1, yv_l(yr_get(src, "n")), dst);
            Yv *prefix = yav(2, yv_long(137), yr_get(t, "modrm"));
            Yv *b = concat(prefix, yr_get(t, "extra"));
            return enc_mem_result(r, b, t);
        } else if (op_size(src) == 8) {
            Yv *t = mem_tail(dst, yv_l(yr_get(src, "n")));
            long r = rex_rm(0, yv_l(yr_get(src, "n")), dst);
            Yv *prefix = yav(2, yv_long(136), yr_get(t, "modrm"));
            Yv *b = concat(prefix, yr_get(t, "extra"));
            return enc_mem_result(r, b, t);
        } else {
            return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("mov mem,reg size"));
        }
    } else {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("mov form"));
    }
}

static Yv *enc_mem_result(long r, Yv *b, Yv *t) {
    if (yv_l(yr_get(t, "modrm")) < 0) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("bad memory form"));
    } else {
        Yv *fx = yav(0);
        Yv *bb = b;
        if (yv_b(yr_get(t, "disp32"))) {
            if (!ys_eq_lit(yr_get(t, "rip_lbl"), "")) {
            /* fixup offset counts the REX prefix with_rex is about to add;
               the disp32 placeholder bytes must exist for the patch to land. */
                long off = yv_len(b);
                if (r >= 0) { off = off + 1; ; }
                fx = ya_push(fx, fixup(off, ys("rip32"), yr_get(t, "rip_lbl"), ys("")));
                Yv *zeros = yav(4, yv_long(0), yv_long(0), yv_long(0), yv_long(0));
                bb = concat(b, zeros);
                ;
            }
            ;
        }
        return yr(3, "bytes", with_rex(r, bb), "fix", fx, "err", ys(""));
    }
}

static Yv *enc_movb(Yv *dst, Yv *src) {
    /* movb $imm8, mem */
    if (!ys_eq_lit(yr_get(dst, "k"), "mem")) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("movb form"));
    } else if (!ys_eq_lit(yr_get(src, "k"), "imm")) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("movb form"));
    } else {
        return enc_movb_imm(dst, src);
    }
}

static Yv *enc_movb_imm(Yv *dst, Yv *src) {
    /* (split: shape gate above narrows; this body sees mem/imm only.) */
    if (yv_l(yr_get(src, "v")) < -128) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("movb imm range"));
    } else if (yv_l(yr_get(src, "v")) > 127) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("movb imm range"));
    } else {
        Yv *t = mem_tail(dst, 0);
        long r = rex_rm(0, 0, dst);
        Yv *prefix = yav(2, yv_long(198), yr_get(t, "modrm"));
        Yv *imm = yav(1, yv_long(u8(yv_l(yr_get(src, "v")))));
        Yv *b = concat(concat(prefix, yr_get(t, "extra")), imm);
        return enc_mem_result(r, b, t);
    }
}

static Yv *enc_movzbq(Yv *dst, Yv *src) {
    if (ys_eq_lit(yr_get(dst, "k"), "reg") && op_size(dst) == 64 && ys_eq_lit(yr_get(src, "k"), "reg") && op_size(src) == 8) {
        long r = rex(1, yv_l(yr_get(dst, "n")), -1, yv_l(yr_get(src, "n")));
        Yv *b = yav(3, yv_long(15), yv_long(182), yv_long(modrm(3, yv_l(yr_get(dst, "n")), yv_l(yr_get(src, "n")))));
        return yr(3, "bytes", with_rex(r, b), "fix", yav(0), "err", ys(""));
    } else if (ys_eq_lit(yr_get(dst, "k"), "reg") && op_size(dst) == 64 && ys_eq_lit(yr_get(src, "k"), "mem")) {
        /* movzbq mem8 -> r64 (single-byte loads for string data) */
        Yv *t = mem_tail(src, yv_l(yr_get(dst, "n")));
        long r = rex_rm(1, yv_l(yr_get(dst, "n")), src);
        Yv *prefix = yav(3, yv_long(15), yv_long(182), yr_get(t, "modrm"));
        Yv *b = concat(prefix, yr_get(t, "extra"));
        return enc_mem_result(r, b, t);
    } else {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("movzbq form"));
    }
}

static Yv *enc_lea(Yv *dst, Yv *src) {
    if (ys_eq_lit(yr_get(dst, "k"), "reg") && op_size(dst) == 64 && ys_eq_lit(yr_get(src, "k"), "mem")) {
        Yv *t = mem_tail(src, yv_l(yr_get(dst, "n")));
        long r = rex_rm(1, yv_l(yr_get(dst, "n")), src);
        Yv *prefix = yav(2, yv_long(141), yr_get(t, "modrm"));
        Yv *b = concat(prefix, yr_get(t, "extra"));
        return enc_mem_result(r, b, t);
    } else {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("lea form"));
    }
}

static Yv *enc_arith(Yv *op, Yv *dst, Yv *src) {
    /* op: add/sub/xor/and/or/cmp/test; r64,r64 only here */
    if (ys_eq_lit(yr_get(dst, "k"), "reg") && op_size(dst) == 64 && ys_eq_lit(yr_get(src, "k"), "reg") && op_size(src) == 64) {
        long base = 1;
        if (ys_eq_lit(op, "sub")) { base = 41; ; }
        else if (ys_eq_lit(op, "xor")) { base = 49; ; }
        else if (ys_eq_lit(op, "and")) { base = 33; ; }
        else if (ys_eq_lit(op, "or")) { base = 9; ; }
        else if (ys_eq_lit(op, "cmp")) { base = 57; ; }
        else if (ys_eq_lit(op, "test")) { base = 133; ; }
        long r = rex(1, yv_l(yr_get(src, "n")), -1, yv_l(yr_get(dst, "n")));
        Yv *b = yav(2, yv_long(base), yv_long(modrm(3, yv_l(yr_get(src, "n")), yv_l(yr_get(dst, "n")))));
        return yr(3, "bytes", with_rex(r, b), "fix", yav(0), "err", ys(""));
    } else {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("arith reg form"));
    }
}

static Yv *enc_xor32(Yv *dst, Yv *src) {
    if (ys_eq_lit(yr_get(dst, "k"), "reg") && op_size(dst) == 32 && ys_eq_lit(yr_get(src, "k"), "reg") && op_size(src) == 32) {
        long r = rex(0, yv_l(yr_get(src, "n")), -1, yv_l(yr_get(dst, "n")));
        Yv *b = yav(2, yv_long(49), yv_long(modrm(3, yv_l(yr_get(src, "n")), yv_l(yr_get(dst, "n")))));
        return yr(3, "bytes", with_rex(r, b), "fix", yav(0), "err", ys(""));
    } else {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("xor32 form"));
    }
}

static Yv *enc_alu_imm(Yv *op, Yv *dst, long v) {
    /* add/sub/cmp/xor/and/or $imm, %r64; cmp $imm, %r32 */
    if (!ys_eq_lit(yr_get(dst, "k"), "reg")) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("alu-imm dst"));
    } else if (op_size(dst) != 64) {
        if (op_size(dst) != 32) {
            return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("alu-imm dst"));
        } else {
            return enc_alu_imm_go(op, dst, v);
        }
    } else {
        return enc_alu_imm_go(op, dst, v);
    }
}

static Yv *enc_alu_imm_go(Yv *op, Yv *dst, long v) {
    /* (split from enc_alu_imm: the size gate above narrows; this body sees
       only r64/r32 regs — no merged-shape reads.) */
    return enc_alu_imm_body(op, dst, v);
}

static Yv *enc_alu_imm_body(Yv *op, Yv *dst, long v) {
    /* (the size gate lives in enc_alu_imm; no gate here) */
    long ext = 0;
    if (ys_eq_lit(op, "sub")) { ext = 5; ; }
    else if (ys_eq_lit(op, "cmp")) { ext = 7; ; }
    else if (ys_eq_lit(op, "xor")) { ext = 6; ; }
    else if (ys_eq_lit(op, "and")) { ext = 4; ; }
    else if (ys_eq_lit(op, "or")) { ext = 1; ; }
    int wide = op_size(dst) == 64;
    long r = rex(wide, -1, -1, yv_l(yr_get(dst, "n")));
    if (fits8(v)) {
        Yv *prefix = yav(2, yv_long(131), yv_long(modrm(3, ext, yv_l(yr_get(dst, "n")))));
        Yv *imm = yav(1, yv_long(u8(v)));
        Yv *b = concat(prefix, imm);
        return yr(3, "bytes", with_rex(r, b), "fix", yav(0), "err", ys(""));
    } else {
        Yv *prefix = yav(2, yv_long(129), yv_long(modrm(3, ext, yv_l(yr_get(dst, "n")))));
        Yv *b = concat(prefix, le32(v));
        return yr(3, "bytes", with_rex(r, b), "fix", yav(0), "err", ys(""));
    }
}

static Yv *enc_shl(Yv *dst, long v) {
    /* shl $imm8, %r64 */
    if (!ys_eq_lit(yr_get(dst, "k"), "reg")) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("shl dst"));
    } else if (op_size(dst) != 64) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("shl dst"));
    } else if (v < 0) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("shl count range"));
    } else if (v > 63) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("shl count range"));
    } else {
        long r = rex(1, -1, -1, yv_l(yr_get(dst, "n")));
        Yv *prefix = yav(2, yv_long(193), yv_long(modrm(3, 4, yv_l(yr_get(dst, "n")))));
        Yv *imm = yav(1, yv_long(u8(v)));
        Yv *b = concat(prefix, imm);
        return yr(3, "bytes", with_rex(r, b), "fix", yav(0), "err", ys(""));
    }
}

static Yv *enc_shr(Yv *dst, long v) {
    /* shr $imm8, %r64 (logical, for unsigned divide-by-pow2) */
    if (!ys_eq_lit(yr_get(dst, "k"), "reg")) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("shr dst"));
    } else if (op_size(dst) != 64) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("shr dst"));
    } else if (v < 0) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("shr count range"));
    } else if (v > 63) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("shr count range"));
    } else {
        long r = rex(1, -1, -1, yv_l(yr_get(dst, "n")));
        Yv *prefix = yav(2, yv_long(193), yv_long(modrm(3, 5, yv_l(yr_get(dst, "n")))));
        Yv *imm = yav(1, yv_long(u8(v)));
        Yv *b = concat(prefix, imm);
        return yr(3, "bytes", with_rex(r, b), "fix", yav(0), "err", ys(""));
    }
}

/* ── SSE scalar-double encodings ────────────────────────────────────────
   Floats travel in %rax as their raw IEEE754 bits; only arithmetic and
   comparison move them into %xmmN, so the rest of the backend (slots,
   pushes, calls) is unchanged. */

static Yv *enc_sse_arith(Yv *mn, Yv *dst, Yv *src) {
    /* F2 0F <op> /r  — addsd 58, subsd 5C, mulsd 59, divsd 5E */
    if (!ys_eq_lit(yr_get(dst, "k"), "reg")) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("sse dst"));
    } else if (!ys_eq_lit(yr_get(src, "k"), "reg")) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("sse src"));
    } else {
        long op = 88;
        if (ys_eq_lit(mn, "subsd")) { op = 92; ; } else { ; };
        if (ys_eq_lit(mn, "mulsd")) { op = 89; ; } else { ; };
        if (ys_eq_lit(mn, "divsd")) { op = 94; ; } else { ; };
        long r = rex(0, yv_l(yr_get(dst, "n")), -1, yv_l(yr_get(src, "n")));
        Yv *tail = yav(3, yv_long(15), yv_long(op), yv_long(modrm(3, yv_l(yr_get(dst, "n")), yv_l(yr_get(src, "n")))));
        if (r < 0) {
            Yv *prefix = yav(1, yv_long(242));
            return yr(3, "bytes", concat(prefix, tail), "fix", yav(0), "err", ys(""));
        } else {
            Yv *prefix = yav(2, yv_long(242), yv_long(r));
            return yr(3, "bytes", concat(prefix, tail), "fix", yav(0), "err", ys(""));
        }
    }
}

static Yv *enc_ucomisd(Yv *dst, Yv *src) {
    /* 66 0F 2E /r */
    if (!ys_eq_lit(yr_get(dst, "k"), "reg")) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("ucomisd dst"));
    } else if (!ys_eq_lit(yr_get(src, "k"), "reg")) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("ucomisd src"));
    } else {
        long r = rex(0, yv_l(yr_get(dst, "n")), -1, yv_l(yr_get(src, "n")));
        Yv *tail = yav(3, yv_long(15), yv_long(46), yv_long(modrm(3, yv_l(yr_get(dst, "n")), yv_l(yr_get(src, "n")))));
        if (r < 0) {
            Yv *prefix = yav(1, yv_long(102));
            return yr(3, "bytes", concat(prefix, tail), "fix", yav(0), "err", ys(""));
        } else {
            Yv *prefix = yav(2, yv_long(102), yv_long(r));
            return yr(3, "bytes", concat(prefix, tail), "fix", yav(0), "err", ys(""));
        }
    }
}

static Yv *enc_cvtsi2sd(Yv *dst, Yv *src) {
    /* F2 REX.W 0F 2A /r  — cvtsi2sd %gpr, %xmm */
    if (!ys_eq_lit(yr_get(dst, "k"), "reg")) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("cvtsi2sd dst"));
    } else if (!ys_eq_lit(yr_get(src, "k"), "reg")) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("cvtsi2sd src"));
    } else {
        long r = rex(1, yv_l(yr_get(dst, "n")), -1, yv_l(yr_get(src, "n")));
        Yv *prefix = yav(2, yv_long(242), yv_long(r));
        Yv *tail = yav(3, yv_long(15), yv_long(42), yv_long(modrm(3, yv_l(yr_get(dst, "n")), yv_l(yr_get(src, "n")))));
        return yr(3, "bytes",
                  concat(prefix, tail),
                  "fix", yav(0), "err", ys(""));
    }
}

static Yv *enc_cvttsd2si(Yv *dst, Yv *src) {
    /* F2 REX.W 0F 2C /r  — cvttsd2si %xmm, %gpr (truncating) */
    if (!ys_eq_lit(yr_get(dst, "k"), "reg")) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("cvttsd2si dst"));
    } else if (!ys_eq_lit(yr_get(src, "k"), "reg")) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("cvttsd2si src"));
    } else {
        long r = rex(1, yv_l(yr_get(dst, "n")), -1, yv_l(yr_get(src, "n")));
        Yv *prefix = yav(2, yv_long(242), yv_long(r));
        Yv *tail = yav(3, yv_long(15), yv_long(44), yv_long(modrm(3, yv_l(yr_get(dst, "n")), yv_l(yr_get(src, "n")))));
        return yr(3, "bytes",
                  concat(prefix, tail),
                  "fix", yav(0), "err", ys(""));
    }
}

static Yv *enc_movq(Yv *dst, Yv *src) {
    /* 66 REX.W 0F 6E /r  — movq %gpr, %xmm   (gpr -> xmm)
       66 REX.W 0F 7E /r  — movq %xmm, %gpr   (xmm -> gpr) */
    if (!ys_eq_lit(yr_get(dst, "k"), "reg")) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("movq dst"));
    } else if (!ys_eq_lit(yr_get(src, "k"), "reg")) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("movq src"));
    } else if (op_size(dst) == 128) {
        /* into an xmm: the xmm is the reg field, the gpr the rm field */
        long r = rex(1, yv_l(yr_get(dst, "n")), -1, yv_l(yr_get(src, "n")));
        Yv *prefix = yav(2, yv_long(102), yv_long(r));
        Yv *tail = yav(3, yv_long(15), yv_long(110), yv_long(modrm(3, yv_l(yr_get(dst, "n")), yv_l(yr_get(src, "n")))));
        return yr(3, "bytes",
                  concat(prefix, tail),
                  "fix", yav(0), "err", ys(""));
    } else {
        /* out of an xmm: the xmm is still the reg field */
        long r = rex(1, yv_l(yr_get(src, "n")), -1, yv_l(yr_get(dst, "n")));
        Yv *prefix = yav(2, yv_long(102), yv_long(r));
        Yv *tail = yav(3, yv_long(15), yv_long(126), yv_long(modrm(3, yv_l(yr_get(src, "n")), yv_l(yr_get(dst, "n")))));
        return yr(3, "bytes",
                  concat(prefix, tail),
                  "fix", yav(0), "err", ys(""));
    }
}

static Yv *enc_imul(Yv *dst, Yv *src) {
    if (ys_eq_lit(yr_get(dst, "k"), "reg") && op_size(dst) == 64 && ys_eq_lit(yr_get(src, "k"), "reg") && op_size(src) == 64) {
        long r = rex(1, yv_l(yr_get(dst, "n")), -1, yv_l(yr_get(src, "n")));
        Yv *b = yav(3, yv_long(15), yv_long(175), yv_long(modrm(3, yv_l(yr_get(dst, "n")), yv_l(yr_get(src, "n")))));
        return yr(3, "bytes", with_rex(r, b), "fix", yav(0), "err", ys(""));
    } else {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("imul form"));
    }
}

static Yv *enc_unary(Yv *op, Yv *o) {
    if (!ys_eq_lit(yr_get(o, "k"), "reg")) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("unary form"));
    } else if (op_size(o) != 64) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("unary form"));
    } else {
        long ext = 3;
        long opc = 247;
        if (ys_eq_lit(op, "idiv")) { ext = 7; ; }
        else if (ys_eq_lit(op, "div")) { ext = 6; ; }
        else if (ys_eq_lit(op, "dec")) { ext = 1; opc = 255; ; }
        else if (ys_eq_lit(op, "inc")) { ext = 0; opc = 255; ; }
        long r = rex(1, -1, -1, yv_l(yr_get(o, "n")));
        Yv *b = yav(2, yv_long(opc), yv_long(modrm(3, ext, yv_l(yr_get(o, "n")))));
        return yr(3, "bytes", with_rex(r, b), "fix", yav(0), "err", ys(""));
    }
}

static Yv *enc_jmp(Yv *o) {
    if (!ys_eq_lit(yr_get(o, "k"), "lbl")) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("jmp target"));
    } else {
        Yv *bytes = yav(5, yv_long(233), yv_long(0), yv_long(0), yv_long(0), yv_long(0));
        return yr(3, "bytes", bytes,
                  "fix", yav(1, fixup(1, ys("rel32"), yr_get(o, "name"), ys(""))), "err", ys(""));
    }
}

static Yv *enc_call(Yv *o) {
    if (ys_eq_lit(yr_get(o, "k"), "ind")) {
        /* call *%reg — FF /2, used for closure code pointers. */
        long r = rex(0, 0, -1, yv_l(yr_get(o, "n")));
        Yv *b = yav(2, yv_long(255), yv_long(modrm(3, 2, yv_l(yr_get(o, "n")))));
        return yr(3, "bytes", with_rex(r, b), "fix", yav(0), "err", ys(""));
    } else if (!ys_eq_lit(yr_get(o, "k"), "lbl")) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("call target"));
    } else {
        Yv *bytes = yav(5, yv_long(232), yv_long(0), yv_long(0), yv_long(0), yv_long(0));
        return yr(3, "bytes", bytes,
                  "fix", yav(1, fixup(1, ys("rel32"), yr_get(o, "name"), ys(""))), "err", ys(""));
    }
}

static Yv *enc_jcc(long code, Yv *o) {
    if (!ys_eq_lit(yr_get(o, "k"), "lbl")) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("jcc target"));
    } else {
        Yv *bytes = yav(6, yv_long(15), yv_long(code), yv_long(0), yv_long(0), yv_long(0), yv_long(0));
        return yr(3, "bytes", bytes,
                  "fix", yav(1, fixup(2, ys("rel32"), yr_get(o, "name"), ys(""))), "err", ys(""));
    }
}

static Yv *enc_setcc(long code, Yv *o) {
    if (!ys_eq_lit(yr_get(o, "k"), "reg") || op_size(o) != 8) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("setcc form"));
    } else {
        long r = rex(0, -1, -1, yv_l(yr_get(o, "n")));
        Yv *b = yav(3, yv_long(15), yv_long(code), yv_long(modrm(3, 0, yv_l(yr_get(o, "n")))));
        return yr(3, "bytes", with_rex(r, b), "fix", yav(0), "err", ys(""));
    }
}

static Yv *enc_cmpb(long v, Yv *m) {
    if (!ys_eq_lit(yr_get(m, "k"), "mem")) {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("cmpb form"));
    } else {
        Yv *t = mem_tail(m, 7);
        long r = rex_rm(0, 7, m);
        Yv *prefix = yav(2, yv_long(128), yr_get(t, "modrm"));
        Yv *imm = yav(1, yv_long(u8(v)));
        Yv *b = concat(concat(prefix, yr_get(t, "extra")), imm);
        return enc_mem_result(r, b, t);
    }
}

static Yv *enc_movb_reg(Yv *dst, Yv *src) {
    /* movb %r8 -> mem8 (single-byte stores for string data) */
    if (ys_eq_lit(yr_get(dst, "k"), "mem") && ys_eq_lit(yr_get(src, "k"), "reg") && op_size(src) == 8) {
        Yv *t = mem_tail(dst, yv_l(yr_get(src, "n")));
        long r = rex_rm(0, yv_l(yr_get(src, "n")), dst);
        Yv *prefix = yav(2, yv_long(136), yr_get(t, "modrm"));
        Yv *b = concat(prefix, yr_get(t, "extra"));
        return enc_mem_result(r, b, t);
    } else {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("movb reg form"));
    }
}

/* ── mnemonic dispatch ────────────────────────────────────────────────── */

static Yv *need1(Yv *mn, Yv *ops) {
    if (yv_len(ops) != 1) { return ys_cat(mn, ys(" takes 1 operand")); } else { return ys(""); }
}

static Yv *need2(Yv *mn, Yv *ops) {
    if (yv_len(ops) != 2) { return ys_cat(mn, ys(" takes 2 operands")); } else { return ys(""); }
}

Yv *enc_insn(Yv *mn, Yv *ops) {
    if (ys_eq_lit(mn, "push")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return yr(3, "bytes", yav(0), "fix", yav(0), "err", e); } else { return enc_push(ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "pop")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return yr(3, "bytes", yav(0), "fix", yav(0), "err", e); } else { return enc_pop(ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "mov")) {
        Yv *e = need2(mn, ops);
        if (!ys_eq_lit(e, "")) { return yr(3, "bytes", yav(0), "fix", yav(0), "err", e); } else { return enc_mov(ya_get(ops, 1), ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "movb")) {
        Yv *e = need2(mn, ops);
        if (!ys_eq_lit(e, "")) {
            return yr(3, "bytes", yav(0), "fix", yav(0), "err", e);
        } else if (ys_eq_lit(yr_get(ya_get(ops, 0), "k"), "imm")) {
            return enc_movb(ya_get(ops, 1), ya_get(ops, 0));
        } else {
            return enc_movb_reg(ya_get(ops, 1), ya_get(ops, 0));
        }
    } else if (ys_eq_lit(mn, "movzbq")) {
        Yv *e = need2(mn, ops);
        if (!ys_eq_lit(e, "")) { return yr(3, "bytes", yav(0), "fix", yav(0), "err", e); } else { return enc_movzbq(ya_get(ops, 1), ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "lea")) {
        Yv *e = need2(mn, ops);
        if (!ys_eq_lit(e, "")) { return yr(3, "bytes", yav(0), "fix", yav(0), "err", e); } else { return enc_lea(ya_get(ops, 1), ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "add") || ys_eq_lit(mn, "sub") || ys_eq_lit(mn, "cmp") || ys_eq_lit(mn, "xor") || ys_eq_lit(mn, "and") || ys_eq_lit(mn, "or") || ys_eq_lit(mn, "test")) {
        Yv *e = need2(mn, ops);
        if (!ys_eq_lit(e, "")) {
            return yr(3, "bytes", yav(0), "fix", yav(0), "err", e);
        } else {
            Yv *dst = ya_get(ops, 1);
            Yv *src = ya_get(ops, 0);
            if (ys_eq_lit(yr_get(src, "k"), "imm")) {
                if (ys_eq_lit(mn, "add") || ys_eq_lit(mn, "sub") || ys_eq_lit(mn, "cmp") || ys_eq_lit(mn, "xor") || ys_eq_lit(mn, "and") || ys_eq_lit(mn, "or")) {
                    return enc_alu_imm(mn, dst, yv_l(yr_get(src, "v")));
                } else {
                    return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys_cat(mn, ys(" imm form")));
                }
            } else if (ys_eq_lit(yr_get(dst, "k"), "reg") && ys_eq_lit(yr_get(src, "k"), "reg") && ys_eq_lit(mn, "xor") && op_size(dst) == 32 && op_size(src) == 32) {
                return enc_xor32(dst, src);
            } else {
                return enc_arith(mn, dst, src);
            }
        }
    } else if (ys_eq_lit(mn, "shl")) {
        Yv *e = need2(mn, ops);
        if (!ys_eq_lit(e, "")) {
            return yr(3, "bytes", yav(0), "fix", yav(0), "err", e);
        } else if (!ys_eq_lit(yr_get(ya_get(ops, 0), "k"), "imm")) {
            return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("shl needs imm"));
        } else {
            return enc_shl(ya_get(ops, 1), yv_l(yr_get(ya_get(ops, 0), "v")));
        }
    } else if (ys_eq_lit(mn, "shr")) {
        Yv *e = need2(mn, ops);
        if (!ys_eq_lit(e, "")) {
            return yr(3, "bytes", yav(0), "fix", yav(0), "err", e);
        } else if (!ys_eq_lit(yr_get(ya_get(ops, 0), "k"), "imm")) {
            return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("shr needs imm"));
        } else {
            return enc_shr(ya_get(ops, 1), yv_l(yr_get(ya_get(ops, 0), "v")));
        }
    } else if (ys_eq_lit(mn, "addsd") || ys_eq_lit(mn, "subsd") || ys_eq_lit(mn, "mulsd") || ys_eq_lit(mn, "divsd")) {
        Yv *e = need2(mn, ops);
        if (!ys_eq_lit(e, "")) { return yr(3, "bytes", yav(0), "fix", yav(0), "err", e); } else { return enc_sse_arith(mn, ya_get(ops, 1), ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "ucomisd")) {
        Yv *e = need2(mn, ops);
        if (!ys_eq_lit(e, "")) { return yr(3, "bytes", yav(0), "fix", yav(0), "err", e); } else { return enc_ucomisd(ya_get(ops, 1), ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "cvtsi2sd")) {
        Yv *e = need2(mn, ops);
        if (!ys_eq_lit(e, "")) { return yr(3, "bytes", yav(0), "fix", yav(0), "err", e); } else { return enc_cvtsi2sd(ya_get(ops, 1), ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "cvttsd2si")) {
        Yv *e = need2(mn, ops);
        if (!ys_eq_lit(e, "")) { return yr(3, "bytes", yav(0), "fix", yav(0), "err", e); } else { return enc_cvttsd2si(ya_get(ops, 1), ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "movq")) {
        Yv *e = need2(mn, ops);
        if (!ys_eq_lit(e, "")) { return yr(3, "bytes", yav(0), "fix", yav(0), "err", e); } else { return enc_movq(ya_get(ops, 1), ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "imul")) {
        Yv *e = need2(mn, ops);
        if (!ys_eq_lit(e, "")) { return yr(3, "bytes", yav(0), "fix", yav(0), "err", e); } else { return enc_imul(ya_get(ops, 1), ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "neg") || ys_eq_lit(mn, "idiv") || ys_eq_lit(mn, "div") || ys_eq_lit(mn, "dec") || ys_eq_lit(mn, "inc")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return yr(3, "bytes", yav(0), "fix", yav(0), "err", e); } else { return enc_unary(mn, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "jmp")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return yr(3, "bytes", yav(0), "fix", yav(0), "err", e); } else { return enc_jmp(ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "call")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return yr(3, "bytes", yav(0), "fix", yav(0), "err", e); } else { return enc_call(ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "jz") || ys_eq_lit(mn, "je")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return yr(3, "bytes", yav(0), "fix", yav(0), "err", e); } else { return enc_jcc(132, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "jnz") || ys_eq_lit(mn, "jne")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return yr(3, "bytes", yav(0), "fix", yav(0), "err", e); } else { return enc_jcc(133, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "js")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return yr(3, "bytes", yav(0), "fix", yav(0), "err", e); } else { return enc_jcc(136, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "jns")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return yr(3, "bytes", yav(0), "fix", yav(0), "err", e); } else { return enc_jcc(137, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "jge")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return yr(3, "bytes", yav(0), "fix", yav(0), "err", e); } else { return enc_jcc(141, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "jl")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return yr(3, "bytes", yav(0), "fix", yav(0), "err", e); } else { return enc_jcc(140, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "jle")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return yr(3, "bytes", yav(0), "fix", yav(0), "err", e); } else { return enc_jcc(142, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "jg")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return yr(3, "bytes", yav(0), "fix", yav(0), "err", e); } else { return enc_jcc(143, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "jb")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return yr(3, "bytes", yav(0), "fix", yav(0), "err", e); } else { return enc_jcc(130, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "setl")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return yr(3, "bytes", yav(0), "fix", yav(0), "err", e); } else { return enc_setcc(156, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "setg")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return yr(3, "bytes", yav(0), "fix", yav(0), "err", e); } else { return enc_setcc(159, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "setle")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return yr(3, "bytes", yav(0), "fix", yav(0), "err", e); } else { return enc_setcc(158, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "setge")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return yr(3, "bytes", yav(0), "fix", yav(0), "err", e); } else { return enc_setcc(157, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "sete")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return yr(3, "bytes", yav(0), "fix", yav(0), "err", e); } else { return enc_setcc(148, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "setne")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return yr(3, "bytes", yav(0), "fix", yav(0), "err", e); } else { return enc_setcc(149, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "seta")) {
        /* unsigned >: the correct condition after ucomisd (floats) */
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return yr(3, "bytes", yav(0), "fix", yav(0), "err", e); } else { return enc_setcc(151, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "setae")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return yr(3, "bytes", yav(0), "fix", yav(0), "err", e); } else { return enc_setcc(147, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "setb")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return yr(3, "bytes", yav(0), "fix", yav(0), "err", e); } else { return enc_setcc(146, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "setbe")) {
        Yv *e = need1(mn, ops);
        if (!ys_eq_lit(e, "")) { return yr(3, "bytes", yav(0), "fix", yav(0), "err", e); } else { return enc_setcc(150, ya_get(ops, 0)); }
    } else if (ys_eq_lit(mn, "cmpb")) {
        Yv *e = need2(mn, ops);
        if (!ys_eq_lit(e, "")) {
            return yr(3, "bytes", yav(0), "fix", yav(0), "err", e);
        } else if (!ys_eq_lit(yr_get(ya_get(ops, 0), "k"), "imm")) {
            return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys("cmpb needs imm"));
        } else {
            return enc_cmpb(yv_l(yr_get(ya_get(ops, 0), "v")), ya_get(ops, 1));
        }
    } else if (ys_eq_lit(mn, "cqo")) {
        Yv *bytes = yav(2, yv_long(72), yv_long(153));
        return yr(3, "bytes", bytes, "fix", yav(0), "err", ys(""));
    } else if (ys_eq_lit(mn, "syscall")) {
        Yv *bytes = yav(2, yv_long(15), yv_long(5));
        return yr(3, "bytes", bytes, "fix", yav(0), "err", ys(""));
    } else if (ys_eq_lit(mn, "ret")) {
        Yv *bytes = yav(1, yv_long(195));
        return yr(3, "bytes", bytes, "fix", yav(0), "err", ys(""));
    } else {
        return yr(3, "bytes", yav(0), "fix", yav(0), "err", ys_cat(ys_cat(ys("unknown mnemonic '"), mn), ys("'")));
    }
}
