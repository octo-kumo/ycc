/* asm.c — 1:1 port of src/y/asm.y (translation contract: PORTING.md).
 *
 * Assembler for the native backend's x86-64 dialect.
 * asm_assemble(text, debug) -> {ok, bytes: [byte], error, times} (times:
 * per-phase us/heap rows for `ycc --time`; debug is `ycc -g`, which adds a
 * symbol table — see debug_syms — and, from the text's `.file`/`.loc`
 * line markers, DWARF line info — see debug_lines).
 * ycc_assemble(text, debug) -> the driver's wrapper (see its note at the bottom).
 * Only what native.y/arch_x64.y emit is accepted; anything else is a loud
 * error with a line number — never a silent miscompile.
 * Two passes: (1) parse + encode with zeroed label fields, recording fixups;
 * (2) resolve labels and patch. All jumps/calls use rel32 (fixed size), so
 * instruction lengths are known in pass 1.
 */
#include "asm.h"
#include "tags.h"
#include "dwarf.h"
#include "ir.h"
#include "labels.h"
#include "enc64.h"

#include <sys/syscall.h>
#include <unistd.h>

/* imported (module calls from asm.y, names flattened) */
extern long reg_num(Yv *name);              /* enc64.c: enc.reg_num */
extern long reg_size(Yv *name);             /* enc64.c: enc.reg_size */
extern Yv *enc_insn(Yv *buf, long at, Yv *mn, Yv *ops, int lng); /* enc64.c: enc.enc_insn */
extern Yv *enc_branch_long(Yv *buf, long at, long br, Yv *lbl); /* enc64.c: enc.enc_branch_long */
extern Yv *scratch(void);                    /* enc64.c: enc.scratch */
extern Yv *le64(long v);                    /* enc64.c: enc.le64 */
extern Yv *le32(long v);                    /* enc64.c: enc.le32 */
extern long elf_bss_from_ro(long code_len, long ro_len); /* elf.c: elf.elf_bss_from_ro */
extern long elf_code_off(long bss_len);      /* elf.c: elf.elf_code_off */
extern Yv *elf_build(Yv *code, Yv *rodata, long entry_off, long bss_len,
                     Yv *syms, Yv *dsecs); /* elf.c: elf.elf_build */

/* ── module-local defs (forward) ─────────────────────────────────────── */
static int is_digit_ch(long c);
static int is_oct_ch(long c);
static int is_alpha_ch(long c);
static Yv *parse_num(Yv *s);
static Yv *parse_num_go(Yv *s, long i, int neg);
static int is_num_text(Yv *s);
static Yv *split_ops(Yv *s);
static Yv *parse_operand(Yv *t);
static Yv *parse_operand_empty(Yv *t);
static Yv *parse_operand_nonempty(Yv *t);
static Yv *parse_operand_ind(Yv *t);
static Yv *parse_operand_reg(Yv *t);
static Yv *parse_operand_fs(Yv *t);
static Yv *parse_operand_noreg(Yv *t);
static Yv *parse_operand_imm(Yv *t);
static Yv *parse_operand_memlbl(Yv *t);
static Yv *parse_imm(Yv *s);
static Yv *parse_imm_alpha(Yv *s, long dash);
static Yv *parse_imm_diff(Yv *s, long dash);
static Yv *parse_imm_num(Yv *s);
static Yv *parse_mem(Yv *t);
static Yv *parse_mem_head(Yv *t, Yv *head, Yv *parts);
static Yv *parse_mem_rip(Yv *t, Yv *head, Yv *parts);
static Yv *parse_mem_disp(Yv *t, Yv *head, Yv *parts);
static Yv *parse_mem_regs(Yv *t, Yv *parts, long disp);
static Yv *mem_rest(Yv *t, Yv *parts, long disp, long bn);
static Yv *mem_scale(Yv *t, Yv *parts, long disp, long bn, long xn);
static Yv *mem_scaleThree(Yv *t, Yv *parts, long disp, long bn, long xn);
static Yv *mem_scaleVal(Yv *t, long v, long disp, long bn, long xn);
static Yv *decode_str(Yv *s);
static Yv *decode_oct(Yv *s, long k, long n);
long hash_str(Yv *s);
Yv *labmap_new(long cap);
Yv *labmap_put(Yv *m, Yv *name, long sec, long off);
Yv *labmap_get(Yv *m, Yv *name);
static Yv *labmap_build(Yv *labels);
static Yv *label_addr(Yv *lmap, long code_len, long pad, Yv *name);
static Yv *asm_assemble_line(Yv *lines, long li, long lbase, long sec, Yv *offs, Yv *items, Yv *labels, Yv *err);
static Yv *ir_enc_item(Yv *ir, long at, long sec, Yv *offs, Yv *where);
static Yv *asm_ir_st(long sec, Yv *offs, Yv *items, Yv *labels, Yv *err, long lno);
static Yv *asm_st_seg(Yv *st, Yv *lines, long li);
static Yv *asm_ir_loc(long file, long line, long sec, Yv *offs, long fno);
static Yv *asm_ir_items(Yv *ir, Yv *txt, long fno, int loc, long sec, Yv *offs, Yv *items, Yv *labels, Yv *err, long lno);
static Yv *ir_operand(Yv *ir, long wp, long k);
static Yv *asm_state(long sec, Yv *offs, Yv *items, Yv *labels, Yv *err);
static Yv *asm_state_err(long sec, Yv *offs, Yv *items, Yv *labels, long lno, Yv *msg);
static Yv *asm_labdef(Yv *line, long lno, long sec, Yv *offs, Yv *items, Yv *labels, Yv *err);
static Yv *asm_labdef_go(Yv *nm, long lno, long sec, Yv *offs, Yv *items, Yv *labels, Yv *err);
static Yv *asm_dirline(Yv *line, long lno, long sec, Yv *offs, Yv *items, Yv *labels, Yv *err);
static Yv *asm_maybe_labline(Yv *line, long lno, long sec, Yv *offs, Yv *items, Yv *labels, Yv *err);
static Yv *asm_insnline(Yv *line, long lno, long sec, Yv *offs, Yv *items, Yv *labels, Yv *err);
static Yv *asm_labline(Yv *line, long lno, long sec, Yv *offs, Yv *items, Yv *labels, Yv *err, long ci);
static Yv *asm_labline_go(Yv *nm, Yv *rest, long lno, long sec, Yv *offs, Yv *items, Yv *labels, Yv *err);
static Yv *asm_labline_content(Yv *nm, Yv *rest, long lno, long sec, Yv *offs, Yv *items, Yv *labels, Yv *err);
static Yv *asm_content(Yv *line, long lno, long sec, Yv *offs);
static Yv *asm_strdata(Yv *line, long lno, long sec, Yv *offs, Yv *rest, int nul);
static int asm_strdata_bad(Yv *rest);
static Yv *asm_strdata_err(Yv *line, long lno, long sec, Yv *offs);
static Yv *asm_strdata_go(Yv *line, long lno, long sec, Yv *offs, Yv *payload, int nul);
static Yv *asm_strdata_emit(long sec, Yv *offs, Yv *bytes, int nul);
static Yv *asm_strdata_item(long sec, Yv *offs, Yv *bb);
static Yv *asm_directive(Yv *line, long lno, long sec, Yv *offs);
static Yv *asm_loc(long lno, long sec, Yv *offs, Yv *rest);
static Yv *asm_file(long lno, long sec, Yv *offs, Yv *rest);
static Yv *asm_section(Yv *line, long lno, long sec, Yv *offs, Yv *rest);
static int asm_section_bad(Yv *rest);
static Yv *asm_section_err(Yv *line, long lno, long sec, Yv *offs, Yv *rest);
static Yv *asm_section_go(long sec, Yv *offs, Yv *rest);
static Yv *asm_quad(Yv *line, long lno, long sec, Yv *offs, Yv *rest);
static int asm_quad_bad(Yv *rest);
static Yv *asm_quad_err(Yv *line, long lno, long sec, Yv *offs, Yv *rest);
static Yv *asm_quad_go(long sec, Yv *offs, Yv *rest);
static Yv *asm_zero(Yv *line, long lno, long sec, Yv *offs, Yv *rest);
static Yv *asm_insn(Yv *line, long lno, long sec, Yv *offs);
static Yv *asm_encode(Yv *mn, Yv *ops, long lno, long sec, Yv *offs);
static Yv *asm_link(Yv *items, Yv *labels, int debug);
static Yv *patch_item(Yv *code, Yv *it, Yv *lmap, long code_len, long pad);
static Yv *patch_item_loop(Yv *code, Yv *it, Yv *lmap, long code_len, long pad, Yv *bytes, Yv *err);
static Yv *patch_item_kind2(Yv *lmap, long code_len, long pad, Yv *fx, Yv *bytes, long base, Yv *it, long at);
static Yv *patch_item_rel(Yv *lmap, long code_len, long pad, Yv *fx, Yv *bytes, long base, Yv *it, long at);
static Yv *patch_item_diff(Yv *lmap, long code_len, long pad, Yv *fx, Yv *bytes, long base, Yv *it);
static Yv *patch_item_diff2(Yv *lmap, long code_len, long pad, Yv *fx, Yv *bytes, long ta);
static Yv *patch_item_finish(Yv *code, Yv *bytes, Yv *err);
static Yv *patch32(Yv *bytes, long at, long v);
static Yv *patch8(Yv *bytes, long at, long v);
static Yv *patch_item_rel8(Yv *lmap, long code_len, long pad, Yv *fx, Yv *bytes, long base, Yv *it, long at);
static long asm_relax(Yv *items, Yv *labels, int debug);
static Yv *relax_map(Yv *labels);
static int relax_round(Yv *items, Yv *labels, Yv *rlmap, Yv *lens, Yv *secs, Yv *brs, Yv *cum, int first);
static long relax_target(Yv *rlmap, Yv *lbl);
static long relax_grow(Yv *items, long i, Yv *lens, Yv *lbl);
static long relax_all_long(Yv *items, Yv *labels, Yv *lens);
static long relax_place(Yv *items, Yv *labels, Yv *lens, Yv *secs, int debug);
static Yv *debug_syms(Yv *labels, long code_len, long bss_len);
static Yv *debug_syms_sec(Yv *out, Yv *labels, long sec, long end);
static int is_sym_label(Yv *name, long sec);
static Yv *sym_name(Yv *lbl);
static Yv *after_uid(Yv *s, long k);
static Yv *debug_lines(Yv *items, long code_len, long code_off);
static Yv *asm_cwd(void);
static Yv *concat_bytes(Yv *a, Yv *b);

static int is_digit_ch(long c) {
    /* 1:1 of asm.y's `c >= c'0' && c <= c'9'`. The character is a byte, so
       this is an integer range test; the string form it replaces compared a
       1-char slice with ys_cmp. */
    return c >= '0' && c <= '9';
}

static int is_oct_ch(long c) {
    /* 1:1 of asm.y's `c >= c'0' && c <= c'7'` (same integer range test). */
    return c >= '0' && c <= '7';
}

static int is_alpha_ch(long c) {
    /* 1:1 of asm.y's `c == c'_' || (c >= c'A' && c <= c'Z') ||
       (c >= c'a' && c <= c'z')`. */
    return c == '_' ||
           (c >= 'A' && c <= 'Z') ||
           (c >= 'a' && c <= 'z');
}

/* parse a decimal integer (optional leading -). Returns {ok, v}. */
static Yv *parse_num(Yv *s) {
    int neg = 0;
    long i = 0;
    /* NOTE: `0;` tails (see parser.y parse_binary note). */
    if (ys_eq_lit(ys_slice(s, 0, 1), "-")) {
        neg = 1;
        i = 1;
        ;
    }
    if (i >= yv_len(s)) {
        return yr(2, "ok", yv_bool(0), "v", yv_long(0));
    } else {
        return parse_num_go(s, i, neg);
    }
}

static Yv *parse_num_go(Yv *s, long i, int neg) {
    /* (split: non-empty remainder narrows; `{ok,v}` built ONLY here.)
       NOTE: `0;` tails (see parser.y parse_binary note).
       Y's long arithmetic wraps (NATIVE.md), and the numbers that get
       here need it: an out-of-range literal in a program reaches the
       assembler as written, and so does LONG_MIN's magnitude. In C that
       is unsigned arithmetic — the same bits, without the undefined
       behavior of signed overflow. */
    long v = 0;
    int ok = 1;
    while (i < yv_len(s)) {
        long c = ys_byte_at(s, i);
        if (is_digit_ch(c)) {
            v = (long)((unsigned long)v * 10 + (unsigned long)c - '0');
            ;
        } else {
            ok = 0;
            ;
        };
        i = i + 1;
        ;
    };
    if (neg) { v = (long)(0 - (unsigned long)v); ; }
    return yr(2, "ok", yv_bool(ok), "v", yv_long(v));
}

static int is_num_text(Yv *s) {
    Yv *r = parse_num(s);
    return yv_b(yr_get(r, "ok"));
}

/* Split operands on top-level commas (ignore commas inside parens). */
static Yv *split_ops(Yv *s) {
    Yv *out = yav(0);
    long depth = 0;
    /* One slice per FIELD, not one per character. The loop used to take
     * s[i:i + 1] and append it, so every byte of every operand allocated a
     * throwaway 1-byte string -- ycc's single largest allocation site, at
     * ~10% of all heap. Tracking where the field starts slices each field
     * once instead, with the same bytes in the same order. */
    long start = 0;
    long i = 0;
    long n = yv_len(s);
    /* NOTE: nested ifs, not `&&` (see is_digit_ch note); `0;` tails. */
    while (i < n) {
        long b = ys_byte_at(s, i);
        if (b == 40) { depth = depth + 1; ; }
        if (b == 41) { depth = depth - 1; ; }
        if (b == 44) {  /* ',' */
            if (depth == 0) {
                out = ya_push(out, ys_trim(ys_slice(s, start, i)));
                start = i + 1;
                ;
            }
            ;
        }
        i = i + 1;
        ;
    };
    out = ya_push(out, ys_trim(ys_slice(s, start, n)));
    return out;
}

static Yv *parse_operand(Yv *t) {
    /* NOTE: dispatch by SHAPE into dedicated callees (see parser.y
       parse_type_tail note): each callee builds ONE op shape, so branch
       gates never compare disjoint literals ({ok:false,op:{}} vs reg/lbl). */
    if (ys_eq_lit(t, "")) {
        return parse_operand_empty(t);
    } else {
        return parse_operand_nonempty(t);
    }
}

static Yv *parse_operand_empty(Yv *t) {
    (void)t; /* t is carried only for the shape dispatch (see parse_operand) */
    return yr(3, "ok", yv_bool(0),
              "op", yr(13, "k", yv_long(K_bad), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                        "a", ys(""), "b", ys(""), "name", ys(""),
                        "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                        "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys("")),
              "error", ys("empty operand"));
}

static Yv *parse_operand_nonempty(Yv *t) {
    /* `*%reg` — register-indirect call/jump target (closure code pointers). */
    if (ys_eq_lit(ys_slice(t, 0, 1), "*")) {
        return parse_operand_ind(t);
    } else if (ys_eq_lit(ys_slice(t, 0, 1), "%")) {
        return parse_operand_reg(t);
    } else {
        return parse_operand_noreg(t);
    }
}

static Yv *parse_operand_ind(Yv *t) {
    /* (split: *-gate above narrows; the rest must be a 64-bit register.) */
    Yv *r = ys_slice_from(t, 1);
    long n = reg_num(r);
    if (n < 0) {
        return yr(3, "ok", yv_bool(0),
                  "op", yr(13, "k", yv_long(K_bad), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                            "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys_cat(ys_cat(ys("unknown register '"), r), ys("'")));
    } else {
        return yr(3, "ok", yv_bool(1),
                  "op", yr(13, "k", yv_long(K_ind), "n", yv_long(n), "size", yv_long(reg_size(r)), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                            "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys(""));
    }
}

/* `%fs:N`: the thread-local word at N (a thread's heap block, its word 3
 * its own address; arch_x64.c). Tried only once no register matches. */
static Yv *parse_operand_fs(Yv *t) {
    Yv *r = parse_num(ys_slice_from(t, 4));
    if (!yv_b(yr_get(r, "ok"))) {
        return yr(3, "ok", yv_bool(0),
                  "op", yr(13, "k", yv_long(K_bad), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                            "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys_cat(ys_cat(ys("bad fs operand '"), t), ys("'")));
    } else {
        return yr(3, "ok", yv_bool(1),
                  "op", yr(13, "k", yv_long(K_fs), "n", yv_long(0), "size", yv_long(64), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                            "disp", yr_get(r, "v"), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys(""));
    }
}

static Yv *parse_operand_reg(Yv *t) {
    /* (split: %-gate above narrows; this body sees registers, and
     * `%fs:N`, which no register name matches.) */
    long n = reg_num(t);
    if (n < 0) {
        if (ys_eq_lit(ys_slice(t, 0, 4), "%fs:")) {
            return parse_operand_fs(t);
        }
        return yr(3, "ok", yv_bool(0),
                  "op", yr(13, "k", yv_long(K_bad), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                            "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys_cat(ys_cat(ys("unknown register '"), t), ys("'")));
    } else {
        return yr(3, "ok", yv_bool(1),
                  "op", yr(13, "k", yv_long(K_reg), "n", yv_long(n), "size", yv_long(reg_size(t)), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                            "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys(""));
    }
}

static Yv *parse_operand_noreg(Yv *t) {
    if (ys_eq_lit(ys_slice(t, 0, 1), "$")) {
        return parse_operand_imm(t);
    } else {
        return parse_operand_memlbl(t);
    }
}

static Yv *parse_operand_imm(Yv *t) {
    /* (split: $-gate above narrows; strips the $ and parses the immediate.) */
    return parse_imm(ys_slice_from(t, 1));
}

static Yv *parse_operand_memlbl(Yv *t) {
    if (ys_index_of(t, ys("(")) >= 0) {
        return parse_mem(t);
    } else {
        return yr(3, "ok", yv_bool(1),
                  "op", yr(13, "k", yv_long(K_lbl), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", t,
                            "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                            "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys(""));
    }
}

static Yv *parse_imm(Yv *s) {
    /* $a-b label difference, else decimal number */
    long dash = ys_index_of(ys_slice_from(s, 1), ys("-"));
    if (yv_len(s) > 0) {
        return parse_imm_alpha(s, dash);
    } else {
        return parse_imm_num(s);
    }
}

static Yv *parse_imm_alpha(Yv *s, long dash) {
    /* (split: len>0 narrows; this body checks the alpha gate only.) */
    if (is_alpha_ch(ys_byte_at(s, 0))) {
        return parse_imm_diff(s, dash);
    } else {
        return parse_imm_num(s);
    }
}

static Yv *parse_imm_diff(Yv *s, long dash) {
    /* (split: alpha-gate above narrows; diff-shape built ONLY here.) */
    if (dash >= 0) {
        Yv *a = ys_slice(s, 0, dash + 1);
        Yv *b = ys_slice_from(s, dash + 2);
        return yr(3, "ok", yv_bool(1),
                  "op", yr(13, "k", yv_long(K_diff), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", a, "b", b, "name", ys(""),
                            "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                            "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys(""));
    } else {
        return parse_imm_num(s);
    }
}

static Yv *parse_imm_num(Yv *s) {
    /* (split from parse_imm: the label-diff gate above narrows; this body
       sees plain decimal immediates only.) */
    Yv *r = parse_num(s);
    if (yv_b(yr_get(r, "ok"))) {
        return yr(3, "ok", yv_bool(1),
                  "op", yr(13, "k", yv_long(K_imm), "n", yv_long(0), "size", yv_long(0), "v", yr_get(r, "v"),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                            "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys(""));
    } else {
        return yr(3, "ok", yv_bool(0),
                  "op", yr(13, "k", yv_long(K_bad), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                            "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys_cat(ys_cat(ys("bad immediate '"), s), ys("'")));
    }
}

static Yv *parse_mem(Yv *t) {
    /* dispatch by SHAPE (see parse_operand note): `8(%rbp)` has a head,
       `(%rbx,%rcx,1)` does not. */
    long open = ys_index_of(t, ys("("));
    Yv *head = ys_trim(ys_slice(t, 0, open));
    Yv *inside = ys_slice(t, open + 1, yv_len(t) - 1);
    Yv *parts = split_ops(inside);
    if (!ys_eq_lit(head, "")) {
        return parse_mem_head(t, head, parts);
    } else {
        return parse_mem_regs(t, parts, 0);
    }
}

static Yv *parse_mem_head(Yv *t, Yv *head, Yv *parts) {
    /* (split: non-empty head narrows; rip-label vs numeric displacement.) */
    if (is_num_text(head)) {
        return parse_mem_disp(t, head, parts);
    } else {
        return parse_mem_rip(t, head, parts);
    }
}

static Yv *parse_mem_rip(Yv *t, Yv *head, Yv *parts) {
    /* label(%rip) — mem-shape built ONLY here.
       NOTE: nested ifs, not `||` (see is_digit_ch note). */
    if (yv_len(parts) != 1) {
        return yr(3, "ok", yv_bool(0),
                  "op", yr(13, "k", yv_long(K_bad), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                            "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys_cat(ys_cat(ys("bad rip-relative '"), t), ys("'")));
    } else if (!ys_eq_lit(ya_get(parts, 0), "%rip")) {
        return yr(3, "ok", yv_bool(0),
                  "op", yr(13, "k", yv_long(K_bad), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                            "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys_cat(ys_cat(ys("bad rip-relative '"), t), ys("'")));
    } else {
        return yr(3, "ok", yv_bool(1),
                  "op", yr(13, "k", yv_long(K_mem), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(-1), "idx", yv_long(-1), "scale", yv_long(1),
                            "disp", yv_long(0), "rip", yv_bool(1), "lbl", head),
                  "error", ys(""));
    }
}

static Yv *parse_mem_disp(Yv *t, Yv *head, Yv *parts) {
    /* numeric displacement head: parse_num cannot fail (is_num_text held). */
    Yv *r = parse_num(head);
    return parse_mem_regs(t, parts, yv_l(yr_get(r, "v")));
}

static Yv *parse_mem_regs(Yv *t, Yv *parts, long disp) {
    /* NOTE: nested ifs, not `||` (see is_digit_ch note). */
    if (yv_len(parts) < 1) {
        return yr(3, "ok", yv_bool(0),
                  "op", yr(13, "k", yv_long(K_bad), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                            "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys_cat(ys_cat(ys("bad memory '"), t), ys("'")));
    } else if (yv_len(parts) > 3) {
        return yr(3, "ok", yv_bool(0),
                  "op", yr(13, "k", yv_long(K_bad), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                            "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys_cat(ys_cat(ys("bad memory '"), t), ys("'")));
    } else {
        long bn = reg_num(ya_get(parts, 0));
        if (bn < 0) {
            return yr(3, "ok", yv_bool(0),
                      "op", yr(13, "k", yv_long(K_bad), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                                "a", ys(""), "b", ys(""), "name", ys(""),
                                "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                                "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys("")),
                      "error", ys_cat(ys_cat(ys("bad base register '"), t), ys("'")));
        } else {
            return mem_rest(t, parts, disp, bn);
        }
    }
}

static Yv *mem_rest(Yv *t, Yv *parts, long disp, long bn) {
    if (yv_len(parts) == 1) {
        return yr(3, "ok", yv_bool(1),
                  "op", yr(13, "k", yv_long(K_mem), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(bn), "idx", yv_long(-1), "scale", yv_long(1),
                            "disp", yv_long(disp), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys(""));
    } else {
        long xn = reg_num(ya_get(parts, 1));
        if (xn < 0) {
            return yr(3, "ok", yv_bool(0),
                      "op", yr(13, "k", yv_long(K_bad), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                                "a", ys(""), "b", ys(""), "name", ys(""),
                                "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                                "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys("")),
                      "error", ys_cat(ys_cat(ys("bad index register '"), t), ys("'")));
        } else if (xn == 4) {
            return yr(3, "ok", yv_bool(0),
                      "op", yr(13, "k", yv_long(K_bad), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                                "a", ys(""), "b", ys(""), "name", ys(""),
                                "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                                "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys("")),
                      "error", ys_cat(ys_cat(ys("rsp cannot be index '"), t), ys("'")));
        } else {
            return mem_scale(t, parts, disp, bn, xn);
        }
    }
}

static Yv *mem_scale(Yv *t, Yv *parts, long disp, long bn, long xn) {
    /* NOTE: nested ifs, not `||`/`&&` (see is_digit_ch note). */
    long scale = 1;
    if (yv_len(parts) == 3) {
        return mem_scaleThree(t, parts, disp, bn, xn);
    } else {
        return yr(3, "ok", yv_bool(1),
                  "op", yr(13, "k", yv_long(K_mem), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(bn), "idx", yv_long(xn), "scale", yv_long(scale),
                            "disp", yv_long(disp), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys(""));
    }
}

static Yv *mem_scaleThree(Yv *t, Yv *parts, long disp, long bn, long xn) {
    /* (split: 3-part gate above narrows; scale-shape built ONLY here.) */
    Yv *r = parse_num(ya_get(parts, 2));
    if (!(yv_b(yr_get(r, "ok")))) {
        return yr(3, "ok", yv_bool(0),
                  "op", yr(13, "k", yv_long(K_bad), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                            "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys_cat(ys_cat(ys("bad scale '"), t), ys("'")));
    } else {
        return mem_scaleVal(t, yv_l(yr_get(r, "v")), disp, bn, xn);
    }
}

static Yv *mem_scaleVal(Yv *t, long v, long disp, long bn, long xn) {
    /* (split: numeric scale narrows; mem-shape built ONLY here.) */
    if (v == 1) {
        return yr(3, "ok", yv_bool(1),
                  "op", yr(13, "k", yv_long(K_mem), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(bn), "idx", yv_long(xn), "scale", yv_long(1),
                            "disp", yv_long(disp), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys(""));
    } else if (v == 2) {
        return yr(3, "ok", yv_bool(1),
                  "op", yr(13, "k", yv_long(K_mem), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(bn), "idx", yv_long(xn), "scale", yv_long(2),
                            "disp", yv_long(disp), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys(""));
    } else if (v == 4) {
        return yr(3, "ok", yv_bool(1),
                  "op", yr(13, "k", yv_long(K_mem), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(bn), "idx", yv_long(xn), "scale", yv_long(4),
                            "disp", yv_long(disp), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys(""));
    } else if (v == 8) {
        return yr(3, "ok", yv_bool(1),
                  "op", yr(13, "k", yv_long(K_mem), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(bn), "idx", yv_long(xn), "scale", yv_long(8),
                            "disp", yv_long(disp), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys(""));
    } else {
        return yr(3, "ok", yv_bool(0),
                  "op", yr(13, "k", yv_long(K_bad), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                            "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys_cat(ys_cat(ys("bad scale '"), t), ys("'")));
    }
}

/* Decode a quoted GAS string (no surrounding quotes in s).
   Handles \\ \" \n \t \r and \ooo octal. Returns {ok, bytes, error}. */
static Yv *decode_str(Yv *s) {
    Yv *out = yav(0);
    long i = 0;
    long n = yv_len(s);
    Yv *err = ys("");
    while (i < n) {
        long c = ys_byte_at(s, i);
        if (c != '\\') {
            out = ya_push(out, yv_long(c));
            i = i + 1;
        } else if (i + 1 >= n) {
            /* a backslash as the last byte: no escape follows it */
            err = ys("bad escape '\\'");
            i = n;
        } else {
            long e = ys_byte_at(s, i + 1);
            if (e == 'n') {
                out = ya_push(out, yv_long('\n'));
                i = i + 2;
            } else if (e == 't') {
                out = ya_push(out, yv_long('\t'));
                i = i + 2;
            } else if (e == 'r') {
                out = ya_push(out, yv_long('\r'));
                i = i + 2;
            } else if (e == '\\') {
                out = ya_push(out, yv_long('\\'));
                i = i + 2;
            } else if (e == '\x22') {
                out = ya_push(out, yv_long('\x22'));
                i = i + 2;
            } else if (is_oct_ch(e)) {
                /* NOTE: nested ifs, not `&&` (see is_digit_ch note); `0;`
                   tails (see parser.y parse_binary note). */
                Yv *oct = decode_oct(s, i + 2, n);
                if (!ys_eq_lit(yr_get(oct, "err"), "")) {
                    err = yr_get(oct, "err");
                    ;
                } else {
                    out = ya_push(out, yr_get(oct, "v"));
                    ;
                };
                i = yv_l(yr_get(oct, "k"));
            } else {
                err = ys_cat(ys_cat(ys("bad escape '\\"),
                                     ys_slice(s, i + 1, i + 2)), ys("'"));
                i = n;
            };
        }
    }
    return yr(3, "ok", yv_bool(ys_eq_lit(err, "")), "bytes", out, "error", err);
}

static Yv *decode_oct(Yv *s, long k, long n) {
    /* Octal escape starting after the backslash (e is already known-octal).
       Returns {v, k (pos after digits), err}. Split from decode_str: the
       `{ok,bytes,error}` shape is built ONLY in decode_str.
       NOTE: `0;` tails (see parser.y parse_binary note). */
    long e = ys_byte_at(s, k - 1);
    long v = e - '0';
    long kk = k;
    long nd = 1;
    while (nd < 3) {
        if (kk < n) {
            long d = ys_byte_at(s, kk);
            if (is_oct_ch(d)) {
                v = v * 8 + d - '0';
                kk = kk + 1;
                nd = nd + 1;
                ;
            } else {
                kk = n + 1;
                ;
            };
            ;
        } else {
            nd = 3;
            ;
        };
        ;
    };
    if (v > 255) {
        return yr(3, "v", yv_long(0), "k", yv_long(kk), "err", ys("octal escape out of range"));
    } else {
        return yr(3, "v", yv_long(v), "k", yv_long(kk), "err", ys(""));
    }
}


/* ── label index (hash table: name -> {sec, off}) ─────────────────────────
   Pass 1 threads a plain labels LIST (cheap amortized pushes); resolving
   every fixup (plus the old duplicate scan) against that list is O(F·L) —
   minutes on big programs (7k labels × 11k refs). This index makes queries
   O(1): flat [{name,sec,off}] with name "" marking empty slots, put-if-
   absent (first wins, matching linear-scan order). Plain Y only (arrays,
   longs, strings, ord) — nothing yv.c lacks already. */

long hash_str(Yv *s) {
    /* byte_at, not ord(s[i:i + 1]): the slice allocated a throwaway string
     * per character, and the tree shaker hashes ~191k names per compile
     * through this (native.c namemap_build/namemap_get).
     *
     * Masked to 32 bits with a final shift-xor, as in src/y/asm.y -- and it has
     * to be the same function, not just a same-shaped one: an object file
     * carries a checksum over its body (native.c unit_obj), and a .yo the C
     * copy wrote would not verify in the Y compiler (or the reverse) while
     * this one kept the pre-mask version. What the Y copy changed and this one
     * did not: no `% 1000000007` per byte. That is a 64-bit idiv -- twenty-odd
     * instructions -- and with it a lookup in either table cost 509
     * instructions a call, 2.6% of everything ycc executes. Both users
     * take the result modulo a table size, so any well-spread 32-bit
     * value is as good as a prime: masking to 32 bits keeps `h * 31` from
     * overflowing (it cannot exceed 2^37), and the final shift-xor spreads
     * the high bits down into the low ones the modulo keeps. */
    long h = 0;
    long i = 0;
    long n = yv_len(s);
    while (i < n) {
        h = (h * 31 + ys_byte_at(s, i)) & 4294967295L;
        i = i + 1;
    }
    return h ^ (h >> 13);
}

Yv *labmap_new(long cap) {
    Yv *m = yav(0);
    long i = 0;
    while (i < cap) {
        m = ya_push(m, yr(4, "name", ys(""), "sec", yv_long(0), "off", yv_long(0), "at_item", yv_long(0)));
        i = i + 1;
    }
    return m;
}

Yv *labmap_put(Yv *m, Yv *name, long sec, long off) {
    long cap = yv_len(m);
    long i = hash_str(name) % cap;
    int dup = 0;
    int done = 0;
    long n = 0;
    while (done == 0) {
        Yv *e = ya_get(m, i);
        if (ys_eq_lit(yr_get(e, "name"), "")) {
            ya_set(m, i, yr(4, "name", name, "sec", yv_long(sec), "off", yv_long(off), "at_item", yv_long(0)));
            done = 1;
            ;
        } else if (ys_eq(yr_get(e, "name"), name)) {
            dup = 1;
            done = 1;
            ;
        } else {
            i = i + 1;
            if (i >= cap) { i = 0; ; }
            ;
        };
        n = n + 1;
        if (n > cap) { done = 1; ; }
    };
    return yr(2, "map", m, "dup", yv_bool(dup));
}

Yv *labmap_get(Yv *m, Yv *name) {
    long cap = yv_len(m);
    long i = hash_str(name) % cap;
    long found_sec = -1;
    long found_off = 0;
    int done = 0;
    long n = 0;
    while (done == 0) {
        Yv *e = ya_get(m, i);
        if (ys_eq_lit(yr_get(e, "name"), "")) {
            done = 1;
            ;
        } else if (ys_eq(yr_get(e, "name"), name)) {
            found_sec = yv_l(yr_get(e, "sec"));
            found_off = yv_l(yr_get(e, "off"));
            done = 1;
            ;
        } else {
            i = i + 1;
            if (i >= cap) { i = 0; ; }
            ;
        };
        n = n + 1;
        if (n > cap) { done = 1; ; }
    };
    return yr(2, "sec", yv_long(found_sec), "off", yv_long(found_off));
}

/* Build the index from pass-1 labels; reports the first duplicate name
   ("" when clean). Replaces the old O(L^2) definition-site scans — our
   emitter only feeds unique labels, and no test pins dup positions. */
static Yv *labmap_build(Yv *labels) {
    long cap = yv_len(labels) * 2 + 16;
    Yv *m = labmap_new(cap);
    Yv *dup = ys("");
    long i = 0;
    while (i < yv_len(labels)) {
        Yv *e = ya_get(labels, i);
        Yv *r = labmap_put(m, yr_get(e, "name"), yv_l(yr_get(e, "sec")), yv_l(yr_get(e, "off")));
        m = yr_get(r, "map");
        if (yv_b(yr_get(r, "dup"))) { dup = yr_get(e, "name"); ; }
        i = i + 1;
    }
    return yr(2, "map", m, "dup", dup);
}

static Yv *label_addr(Yv *lmap, long code_len, long pad, Yv *name) {
    Yv *e = labmap_get(lmap, name);
    if (yv_l(yr_get(e, "sec")) < 0) {
        return yr(2, "ok", yv_bool(0), "addr", yv_long(0));
    } else if (yv_l(yr_get(e, "sec")) == 0) {
        return yr(2, "ok", yv_bool(1), "addr", yr_get(e, "off"));
    } else {
        return yr(2, "ok", yv_bool(1), "addr", yv_long(code_len + pad + yv_l(yr_get(e, "off"))));
    }
}

/* ── pass 1: parse lines into items ───────────────────────────────────── */

Yv *asm_assemble(Yv *parts, int debug) {
    long t0 = clock_us();
    long h0 = heap_used();
    /* The text parts' lines, up front: the split is its own phase (a:split),
       as it was when the whole assembly was one string. */
    Yv *segs = yav(0);
    long pi = 0;
    while (pi < yv_len(parts)) {
        Yv *p = ya_get(parts, pi);
        if (yv_len(yr_get(p, "text")) > 0) {
            segs = ya_push(segs, yr(5, "lines", ys_split(yr_get(p, "text"), ys("\n")),
                                    "ir", yav(0), "txt", yav(0), "fno", yv_long(0),
                                    "loc", yv_bool(0)));
        } else {
            segs = ya_push(segs, yr(5, "lines", yav(0), "ir", yr_get(p, "ir"),
                                    "txt", yr_get(p, "txt"), "fno", yr_get(p, "fno"),
                                    "loc", yr_get(p, "loc")));
        };
        pi = pi + 1;
        ;
    };
    long t1 = clock_us();
    long h1 = heap_used();
    /* Pass 1: every piece turned into items, in order -- the text parts a line
       at a time, an IR part item by item. */
    Yv *st = asm_ir_st(0, yav(3, yv_long(0), yv_long(0), yv_long(0)), yav(0), yav(0),
                       ys(""), 0);
    Yv *err = ys("");
    pi = 0;
    while (pi < yv_len(segs)) {
        if (!ys_eq_lit(err, "")) {
            pi = yv_len(segs);
            ;
        } else {
            Yv *sg = ya_get(segs, pi);
            if (yv_len(yr_get(sg, "ir")) > 0) {
                Yv *r = asm_ir_items(yr_get(sg, "ir"), yr_get(sg, "txt"),
                                     yv_l(yr_get(sg, "fno")), yv_b(yr_get(sg, "loc")),
                                     yv_l(yr_get(st, "sec")), yr_get(st, "offs"),
                                     yr_get(st, "items"), yr_get(st, "labels"),
                                     yr_get(st, "err"), yv_l(yr_get(st, "lno")) + 1);
                st = asm_ir_st(yv_l(yr_get(r, "sec")), yr_get(r, "offs"),
                               yr_get(r, "items"), yr_get(r, "labels"),
                               yr_get(r, "err"), yv_l(yr_get(r, "lno")));
            } else {
                Yv *lines = yr_get(sg, "lines");
                long li = 0;
                while (li < yv_len(lines) && ys_eq_lit(yr_get(st, "err"), "")) {
                    st = asm_st_seg(st, lines, li);
                    li = li + 1;
                    ;
                };
            };
            pi = pi + 1;
            ;
        };
    };
    Yv *items = yr_get(st, "items");
    Yv *labels = yr_get(st, "labels");
    err = yr_get(st, "err");
    long tr0 = clock_us();
    long hr0 = heap_used();
    if (!ys_eq_lit(err, "")) {
        return yr(5, "ok", yv_bool(0), "bytes", yav(0), "error", err,
                  "items", yv_long(0),
                  "times", yav(2,
                               yr(3, "name", ys("a:split"), "us", yv_long(t1 - t0), "heap", yv_long(h1 - h0)),
                               yr(3, "name", ys("a:encode"), "us", yv_long(tr0 - t1), "heap", yv_long(hr0 - h1))));
    } else {
        asm_relax(items, labels, debug);
        long tr1 = clock_us();
        long hr1 = heap_used();
        Yv *lk = asm_link(items, labels, debug);
        long t3 = clock_us();
        long h3 = heap_used();
        Yv *tl = yav(4,
                     yr(3, "name", ys("a:split"), "us", yv_long(t1 - t0), "heap", yv_long(h1 - h0)),
                     yr(3, "name", ys("a:encode"), "us", yv_long(tr0 - t1), "heap", yv_long(hr0 - h1)),
                     yr(3, "name", ys("a:relax"), "us", yv_long(tr1 - tr0), "heap", yv_long(hr1 - hr0)),
                     yr(3, "name", ys("a:link"), "us", yv_long(t3 - tr1), "heap", yv_long(h3 - hr1)));
        Yv *lsub = yr_get(lk, "times");
        long k = 0;
        while (k < yv_len(lsub)) {
            Yv *le = ya_get(lsub, k);
            tl = ya_push(tl, le);
            k = k + 1;
        }
        return yr(5, "ok", yr_get(lk, "ok"), "bytes", yr_get(lk, "bytes"),
                  "error", yr_get(lk, "error"), "items", yv_long(yv_len(items)),
                  "times", tl);
    }
}

/* Per-line state threading for asm_assemble (see note above): one STATE
   record {sec,offs,items,labels,err} threaded through per-class callees.
   Each callee reads ONLY its inputs and returns the full STATE — single key
   set everywhere, no merged-shape rebinds. */
static Yv *asm_assemble_line(Yv *lines, long li, long lbase, long sec, Yv *offs, Yv *items, Yv *labels, Yv *err) {
    Yv *line = ys_trim(ya_get(lines, li));
    long lno = lbase + li + 1;
    if (ys_eq_lit(line, "")) {
        return asm_state(sec, offs, items, labels, err);
    } else if (ys_eq_lit(ys_slice(line, 0, 1), "#")) {
        return asm_state_err(sec, offs, items, labels, lno, ys("unexpected comment (backend bug)"));
    } else if (ys_eq_lit(ys_slice_from(line, yv_len(line) - 1), ":")) {
        return asm_labdef(line, lno, sec, offs, items, labels, err);
    } else if (ys_eq_lit(ys_slice(line, 0, 1), ".")) {
        return asm_dirline(line, lno, sec, offs, items, labels, err);
    } else {
        return asm_maybe_labline(line, lno, sec, offs, items, labels, err);
    }
}

static Yv *asm_state(long sec, Yv *offs, Yv *items, Yv *labels, Yv *err) {
    return yr(5, "sec", yv_long(sec), "offs", offs, "items", items, "labels", labels, "err", err);
}

static Yv *asm_state_err(long sec, Yv *offs, Yv *items, Yv *labels, long lno, Yv *msg) {
    return yr(5, "sec", yv_long(sec), "offs", offs, "items", items, "labels", labels,
              "err", ys_cat(ys_cat(ys_cat(ys("L"), ys_long(lno)), ys(": ")), msg));
}

static Yv *asm_labdef(Yv *line, long lno, long sec, Yv *offs, Yv *items, Yv *labels, Yv *err) {
    /* `label:` definition line.
       NOTE: nested ifs, not `||` (see is_digit_ch note). */
    Yv *nm = ys_trim(ys_slice(line, 0, yv_len(line) - 1));
    if (ys_eq_lit(nm, "")) {
        return asm_state_err(sec, offs, items, labels, lno, ys("bad label"));
    } else if (ys_index_of(nm, ys(" ")) >= 0) {
        return asm_state_err(sec, offs, items, labels, lno, ys("bad label"));
    } else {
        return asm_labdef_go(nm, lno, sec, offs, items, labels, err);
    }
}

static Yv *asm_labdef_go(Yv *nm, long lno, long sec, Yv *offs, Yv *items, Yv *labels, Yv *err) {
    /* NOTE: no definition-site duplicate scan (was O(L^2)): duplicates are
       detected once at index build (labmap_build reports the name). */
    (void)lno; /* carried only for the asm_* line-handler shape */
    return asm_state(sec, offs, items,
                     ya_push(labels, yr(4, "name", nm, "sec", yv_long(sec), "off", ya_get(offs, sec),
                                        "at_item", yv_long(yv_len(items)))), err);
}

static Yv *asm_dirline(Yv *line, long lno, long sec, Yv *offs, Yv *items, Yv *labels, Yv *err) {
    Yv *r = asm_directive(line, lno, sec, offs);
    if (!ys_eq_lit(yr_get(r, "err"), "")) {
        return asm_state(yv_l(yr_get(r, "sec")), yr_get(r, "offs"), items, labels, yr_get(r, "err"));
    } else {
        return asm_state(yv_l(yr_get(r, "sec")), yr_get(r, "offs"),
                         ya_push(items, yr_get(r, "item")), labels, err);
    }
}

static Yv *asm_maybe_labline(Yv *line, long lno, long sec, Yv *offs, Yv *items, Yv *labels, Yv *err) {
    /* maybe `label: rest` (rodata emits `ystr_N: .string ...`); otherwise a
       plain instruction. NOTE: misnomer fixed: the else-arm assembles an
       INSTRUCTION (asm_insnline), not a directive. */
    long ci = ys_index_of(line, ys(":"));
    /* a `%` before it: an operand's `%fs:N`, not a label */
    if (ci > 0 && ys_index_of(ys_slice(line, 0, ci), ys("%")) < 0) {
        return asm_labline(line, lno, sec, offs, items, labels, err, ci);
    } else {
        return asm_insnline(line, lno, sec, offs, items, labels, err);
    }
}

static Yv *asm_insnline(Yv *line, long lno, long sec, Yv *offs, Yv *items, Yv *labels, Yv *err) {
    Yv *r = asm_content(line, lno, sec, offs);
    if (!ys_eq_lit(yr_get(r, "err"), "")) {
        return asm_state(yv_l(yr_get(r, "sec")), yr_get(r, "offs"), items, labels, yr_get(r, "err"));
    } else {
        return asm_state(yv_l(yr_get(r, "sec")), yr_get(r, "offs"),
                         ya_push(items, yr_get(r, "item")), labels, err);
    }
}

static Yv *asm_labline(Yv *line, long lno, long sec, Yv *offs, Yv *items, Yv *labels, Yv *err, long ci) {
    /* NOTE: nested ifs, not `||` (see is_digit_ch note). */
    Yv *nm = ys_trim(ys_slice(line, 0, ci));
    Yv *rest = ys_trim(ys_slice_from(line, ci + 1));
    if (ys_eq_lit(nm, "")) {
        return asm_state_err(sec, offs, items, labels, lno, ys("bad label"));
    } else if (ys_index_of(nm, ys(" ")) >= 0) {
        return asm_state_err(sec, offs, items, labels, lno, ys("bad label"));
    } else if (ys_eq_lit(rest, "")) {
        return asm_state_err(sec, offs, items, labels, lno, ys("bad label"));
    } else {
        return asm_labline_go(nm, rest, lno, sec, offs, items, labels, err);
    }
}

static Yv *asm_labline_go(Yv *nm, Yv *rest, long lno, long sec, Yv *offs, Yv *items, Yv *labels, Yv *err) {
    /* NOTE: no definition-site duplicate scan (see asm_labdef_go note). */
    return asm_labline_content(nm, rest, lno, sec, offs, items, labels, err);
}

static Yv *asm_labline_content(Yv *nm, Yv *rest, long lno, long sec, Yv *offs, Yv *items, Yv *labels, Yv *err) {
    /* The item builder does `offs[sec] = offs[sec] + len` IN PLACE, and
       arrays are REFERENCE values in both toolchains (yv.c's ya_push/
       ya_set mutate the shared array), so offs[sec] read AFTER
       asm_content is the POST-item offset: the label would land on its own
       item's bytes (ystr_nl -> 't' of "true"). Bind the pre-item offset
       FIRST. */
    long lab_off = yv_l(ya_get(offs, sec));
    long lab_at = yv_len(items);
    Yv *r = asm_content(rest, lno, sec, offs);
    if (!ys_eq_lit(yr_get(r, "err"), "")) {
        return asm_state(yv_l(yr_get(r, "sec")), yr_get(r, "offs"), items, labels, yr_get(r, "err"));
    } else {
        return asm_state(yv_l(yr_get(r, "sec")), yr_get(r, "offs"),
                         ya_push(items, yr_get(r, "item")),
                         ya_push(labels, yr(4, "name", nm, "sec", yv_long(sec), "off", yv_long(lab_off),
                                            "at_item", yv_long(lab_at))),
                         err);
    }
}

static Yv *asm_content(Yv *line, long lno, long sec, Yv *offs) {
    if (ys_eq_lit(ys_slice(line, 0, 1), ".")) {
        return asm_directive(line, lno, sec, offs);
    } else {
        return asm_insn(line, lno, sec, offs);
    }
}

static Yv *asm_strdata(Yv *line, long lno, long sec, Yv *offs, Yv *rest, int nul) {
    /* .string/.ascii quoted payload (split from asm_directive: dir-gate above
       narrows; data-item shape built ONLY here).
       NOTE: single gate on a BOOL (str narrowing is exact — see
       parse_type_arrow note): error-vs-success shapes never mix in one chain. */
    if (asm_strdata_bad(rest)) {
        return asm_strdata_err(line, lno, sec, offs);
    } else {
        return asm_strdata_go(line, lno, sec, offs, ys_slice(rest, 1, yv_len(rest) - 1), nul);
    }
}

static int asm_strdata_bad(Yv *rest) {
    /* NOTE: nested ifs, not `||` (see is_digit_ch note). */
    if (yv_len(rest) < 2) { return 1; }
    else if (!ys_eq_lit(ys_slice(rest, 0, 1), "\"")) { return 1; }
    else if (!ys_eq_lit(ys_slice_from(rest, yv_len(rest) - 1), "\"")) { return 1; }
    else { return 0; }
}

static Yv *asm_strdata_err(Yv *line, long lno, long sec, Yv *offs) {
    /* (split: error shape `{err,sec,offs,item:{}}` built ONLY here.) */
    (void)line;
    return yr(4,
              "err", ys_cat(ys_cat(ys("L"), ys_long(lno)), ys(": bad string literal")),
              "sec", yv_long(sec), "offs", offs,
              "item", yr(7, "sec", yv_long(-1), "off", yv_long(0), "len", yv_long(0),
                         "kind", ys(""), "bytes", yav(0), "fix", yav(0), "br", yv_long(-1)));
}

static Yv *asm_strdata_go(Yv *line, long lno, long sec, Yv *offs, Yv *payload, int nul) {
    (void)line;
    Yv *d = decode_str(payload);
    if (!(yv_b(yr_get(d, "ok")))) {
        return yr(4,
                  "err", ys_cat(ys_cat(ys_cat(ys("L"), ys_long(lno)), ys(": ")), yr_get(d, "error")),
                  "sec", yv_long(sec), "offs", offs,
                  "item", yr(7, "sec", yv_long(-1), "off", yv_long(0), "len", yv_long(0),
                             "kind", ys(""), "bytes", yav(0), "fix", yav(0), "br", yv_long(-1)));
    } else {
        return asm_strdata_emit(sec, offs, yr_get(d, "bytes"), nul);
    }
}

static Yv *asm_strdata_emit(long sec, Yv *offs, Yv *bytes, int nul) {
    /* NOTE: `0;` tails (see parser.y parse_binary note). */
    Yv *bb = bytes;
    if (nul) {
        bb = ya_push(bb, yv_long(0));
        ;
    }
    return asm_strdata_item(sec, offs, bb);
}

static Yv *asm_strdata_item(long sec, Yv *offs, Yv *bb) {
    Yv *item = yr(7, "sec", yv_long(sec), "off", ya_get(offs, sec), "len", yv_long(yv_len(bb)),
                  "kind", ys("data"), "bytes", bb, "fix", yav(0), "br", yv_long(-1));
    ya_set(offs, sec, yv_long(yv_l(ya_get(offs, sec)) + yv_len(bb)));
    return yr(4, "err", ys(""), "sec", yv_long(sec), "offs", offs, "item", item);
}

static Yv *asm_directive(Yv *line, long lno, long sec, Yv *offs) {
    long sp = ys_index_of(line, ys(" "));
    Yv *dir = line;
    Yv *rest = ys("");
    /* NOTE: `0;` tails (see parser.y parse_binary note). */
    if (sp >= 0) {
        dir = ys_slice(line, 0, sp);
        rest = ys_trim(ys_slice_from(line, sp + 1));
        ;
    }
    if (ys_eq_lit(dir, ".text")) {
        return yr(4, "err", ys(""), "sec", yv_long(0), "offs", offs,
                  "item", yr(7, "sec", yv_long(-1), "off", yv_long(0), "len", yv_long(0),
                             "kind", ys(""), "bytes", yav(0), "fix", yav(0), "br", yv_long(-1)));
    } else if (ys_eq_lit(dir, ".globl")) {
        return yr(4, "err", ys(""), "sec", yv_long(sec), "offs", offs,
                  "item", yr(7, "sec", yv_long(-1), "off", yv_long(0), "len", yv_long(0),
                             "kind", ys(""), "bytes", yav(0), "fix", yav(0), "br", yv_long(-1)));
    } else if (ys_eq_lit(dir, ".string")) {
        return asm_strdata(line, lno, sec, offs, rest, 1);
    } else if (ys_eq_lit(dir, ".ascii")) {
        return asm_strdata(line, lno, sec, offs, rest, 0);
    } else if (ys_eq_lit(dir, ".section")) {
        return asm_section(line, lno, sec, offs, rest);
    } else if (ys_eq_lit(dir, ".quad")) {
        return asm_quad(line, lno, sec, offs, rest);
    } else if (ys_eq_lit(dir, ".zero")) {
        return asm_zero(line, lno, sec, offs, rest);
    } else if (ys_eq_lit(dir, ".loc")) {
        return asm_loc(lno, sec, offs, rest);
    } else if (ys_eq_lit(dir, ".file")) {
        return asm_file(lno, sec, offs, rest);
    } else {
        return yr(4,
                  "err", ys_cat(ys_cat(ys_cat(ys_cat(ys("L"), ys_long(lno)), ys(": unsupported directive '")), dir), ys("'")),
                  "sec", yv_long(sec), "offs", offs,
                  "item", yr(7, "sec", yv_long(-1), "off", yv_long(0), "len", yv_long(0),
                             "kind", ys(""), "bytes", yav(0), "fix", yav(0), "br", yv_long(-1)));
    }
}

/* -g: line-number directives.
 * GNU as's own (native.y emits them under -g, see dbg_lines): `.file N
 * "path"` names file N, `.loc N LINE` says the code that follows comes
 * from LINE of file N. Neither adds a byte. A .loc is an empty item at its
 * .text offset (kind "loc", fix = [file, line] in the `off` fields); a
 * .file one outside every section (sec -1: never laid out) with N in
 * `off` and the path in its fix's `lbl`. asm_link hands both to dwarf.y
 * (debug_lines). */
static Yv *asm_loc(long lno, long sec, Yv *offs, Yv *rest) {
    long sp = ys_index_of(rest, ys(" "));
    Yv *fs = rest;
    Yv *ls = ys("");
    if (sp > 0) {
        fs = ys_slice(rest, 0, sp);
        ls = ys_trim(ys_slice_from(rest, sp + 1));
        ;
    }
    if (!is_num_text(fs) || !is_num_text(ls) ||
        ys_tonum(fs) < 1 || ys_tonum(ls) < 0) {
        return yr(4,
                  "err", ys_cat(ys_cat(ys_cat(ys("L"), ys_long(lno)),
                                       ys(": bad .loc '")),
                                ys_cat(rest, ys("'"))),
                  "sec", yv_long(sec), "offs", offs,
                  "item", yr(6, "sec", yv_long(-1), "off", yv_long(0),
                             "len", yv_long(0), "kind", ys(""),
                             "bytes", yav(0), "fix", yav(0)));
    } else if (sec != 0) {
        return yr(4,
                  "err", ys_cat(ys_cat(ys("L"), ys_long(lno)),
                                ys(": .loc outside .text")),
                  "sec", yv_long(sec), "offs", offs,
                  "item", yr(6, "sec", yv_long(-1), "off", yv_long(0),
                             "len", yv_long(0), "kind", ys(""),
                             "bytes", yav(0), "fix", yav(0)));
    } else {
        Yv *fx = yav(
            2,
            yr(4, "off", yv_long(ys_tonum(fs)), "kind", ys("file"),
               "lbl", ys(""), "lbl2", ys("")),
            yr(4, "off", yv_long(ys_tonum(ls)), "kind", ys("line"),
               "lbl", ys(""), "lbl2", ys("")));
        return yr(4, "err", ys(""), "sec", yv_long(sec), "offs", offs,
                  "item", yr(7, "sec", yv_long(0), "off", ya_get(offs, 0),
                             "len", yv_long(0), "kind", ys("loc"),
                             "bytes", yav(0), "fix", fx, "br", yv_long(-1)));
    }
}

static Yv *asm_file(long lno, long sec, Yv *offs, Yv *rest) {
    long sp = ys_index_of(rest, ys(" "));
    Yv *ns = rest;
    Yv *q = ys("");
    if (sp > 0) {
        ns = ys_slice(rest, 0, sp);
        q = ys_trim(ys_slice_from(rest, sp + 1));
        ;
    }
    Yv *d = decode_str(ys(""));
    if (!asm_strdata_bad(q)) {
        d = decode_str(ys_slice(q, 1, yv_len(q) - 1));
        ;
    }
    if (!is_num_text(ns) || ys_tonum(ns) < 1 || asm_strdata_bad(q) ||
        !yv_b(yr_get(d, "ok"))) {
        return yr(4,
                  "err", ys_cat(ys_cat(ys_cat(ys("L"), ys_long(lno)),
                                       ys(": bad .file '")),
                                ys_cat(rest, ys("'"))),
                  "sec", yv_long(sec), "offs", offs,
                  "item", yr(6, "sec", yv_long(-1), "off", yv_long(0),
                             "len", yv_long(0), "kind", ys(""),
                             "bytes", yav(0), "fix", yav(0)));
    } else {
        Yv *fx = yav(1, yr(4, "off", yv_long(0), "kind", ys("file"),
                           "lbl", from_bytes(yr_get(d, "bytes")),
                           "lbl2", ys("")));
        return yr(4, "err", ys(""), "sec", yv_long(sec), "offs", offs,
                  "item", yr(7, "sec", yv_long(-1), "off",
                             yv_long(ys_tonum(ns)), "len", yv_long(0),
                             "kind", ys("file"), "bytes", yav(0), "fix", fx, "br", yv_long(-1)));
    }
}

/* .section payload (split from asm_directive: dir-gate above narrows).
   NOTE: single bool gate (see asm_strdata note): marker-vs-error never mix. */
static Yv *asm_section(Yv *line, long lno, long sec, Yv *offs, Yv *rest) {
    if (asm_section_bad(rest)) {
        return asm_section_err(line, lno, sec, offs, rest);
    } else {
        return asm_section_go(sec, offs, rest);
    }
}

static int asm_section_bad(Yv *rest) {
    if (ys_eq_lit(rest, ".rodata")) { return 0; }
    else if (ys_eq_lit(rest, ".text")) { return 0; }
    else if (ys_eq_lit(rest, ".bss")) { return 0; }
    else { return 1; }
}

static Yv *asm_section_err(Yv *line, long lno, long sec, Yv *offs, Yv *rest) {
    /* (split: error shape built ONLY here.) */
    (void)line;
    return yr(4,
              "err", ys_cat(ys_cat(ys_cat(ys_cat(ys("L"), ys_long(lno)), ys(": unsupported section '")), rest), ys("'")),
              "sec", yv_long(sec), "offs", offs,
              "item", yr(7, "sec", yv_long(-1), "off", yv_long(0), "len", yv_long(0),
                         "kind", ys(""), "bytes", yav(0), "fix", yav(0), "br", yv_long(-1)));
}

static Yv *asm_section_go(long sec, Yv *offs, Yv *rest) {
    /* (split: marker shape `{err,sec,offs,item:{sec}}` built ONLY here.)
       NOTE: both arms share the key set — teq holds. */
    (void)sec;
    if (ys_eq_lit(rest, ".rodata")) {
        return yr(4, "err", ys(""), "sec", yv_long(1), "offs", offs,
                  "item", yr(7, "sec", yv_long(-1), "off", yv_long(0), "len", yv_long(0),
                             "kind", ys(""), "bytes", yav(0), "fix", yav(0), "br", yv_long(-1)));
    } else if (ys_eq_lit(rest, ".bss")) {
        return yr(4, "err", ys(""), "sec", yv_long(2), "offs", offs,
                  "item", yr(7, "sec", yv_long(-1), "off", yv_long(0), "len", yv_long(0),
                             "kind", ys(""), "bytes", yav(0), "fix", yav(0), "br", yv_long(-1)));
    } else {
        return yr(4, "err", ys(""), "sec", yv_long(0), "offs", offs,
                  "item", yr(7, "sec", yv_long(-1), "off", yv_long(0), "len", yv_long(0),
                             "kind", ys(""), "bytes", yav(0), "fix", yav(0), "br", yv_long(-1)));
    }
}

/* .quad payload: single non-negative long, 8 bytes little-endian (string headers). */
static Yv *asm_quad(Yv *line, long lno, long sec, Yv *offs, Yv *rest) {
    /* NOTE: single bool gate (see asm_strdata note). */
    if (asm_quad_bad(rest)) {
        return asm_quad_err(line, lno, sec, offs, rest);
    } else {
        return asm_quad_go(sec, offs, rest);
    }
}

static int asm_quad_bad(Yv *rest) {
    /* `!is_num_text(rest)` is fine — `!` (an `un` node) needs a bool operand
       (types.y typeof_expr's "un" arm) and is_num_text returns one. The
       range test below stays a separate arm because the two causes need
       different messages (see asm_quad_err). */
    if (!is_num_text(rest)) { return 1; }
    else if (ys_tonum(rest) < 0) { return 1; }
    else { return 0; }
}

static Yv *asm_quad_err(Yv *line, long lno, long sec, Yv *offs, Yv *rest) {
    /* (split: error shape built ONLY here — one message per cause.)
       NOTE: nested ifs (see is_digit_ch note); both arms share the key set. */
    (void)line;
    if (!is_num_text(rest)) {
        return yr(4,
                  "err", ys_cat(ys_cat(ys_cat(ys_cat(ys("L"), ys_long(lno)), ys(": bad .quad value '")), rest), ys("'")),
                  "sec", yv_long(sec), "offs", offs,
                  "item", yr(7, "sec", yv_long(-1), "off", yv_long(0), "len", yv_long(0),
                             "kind", ys(""), "bytes", yav(0), "fix", yav(0), "br", yv_long(-1)));
    } else {
        return yr(4,
                  "err", ys_cat(ys_cat(ys("L"), ys_long(lno)), ys(": negative .quad value")),
                  "sec", yv_long(sec), "offs", offs,
                  "item", yr(7, "sec", yv_long(-1), "off", yv_long(0), "len", yv_long(0),
                             "kind", ys(""), "bytes", yav(0), "fix", yav(0), "br", yv_long(-1)));
    }
}

static Yv *asm_quad_go(long sec, Yv *offs, Yv *rest) {
    /* (split: data-item shape built ONLY here.) */
    Yv *bytes = le64(ys_tonum(rest));
    Yv *item = yr(7, "sec", yv_long(sec), "off", ya_get(offs, sec), "len", yv_long(yv_len(bytes)),
                  "kind", ys("data"), "bytes", bytes, "fix", yav(0), "br", yv_long(-1));
    ya_set(offs, sec, yv_long(yv_l(ya_get(offs, sec)) + yv_len(bytes)));
    return yr(4, "err", ys(""), "sec", yv_long(sec), "offs", offs, "item", item);
}

/* .zero N: N zero bytes. In .bss they only reserve space (no file bytes). */
static Yv *asm_zero(Yv *line, long lno, long sec, Yv *offs, Yv *rest) {
    if (asm_quad_bad(rest)) {
        (void)line;
        return yr(4,
                  "err", ys_cat(ys_cat(ys_cat(ys_cat(ys("L"), ys_long(lno)),
                                               ys(": bad .zero size '")),
                                       rest),
                                ys("'")),
                  "sec", yv_long(sec), "offs", offs,
                  "item", yr(7, "sec", yv_long(-1), "off", yv_long(0), "len", yv_long(0),
                             "kind", ys(""), "bytes", yav(0), "fix", yav(0), "br", yv_long(-1)));
    } else {
        (void)line;
        long n = ys_tonum(rest);
        Yv *zb = yav(0);
        if (sec != 2) {
            long i = 0;
            while (i < n) {
                zb = ya_push(zb, yv_long(0));
                i = i + 1;
            }
        }
        Yv *item = yr(6, "sec", yv_long(sec), "off", ya_get(offs, sec),
                      "len", yv_long(n), "kind", ys("data"), "bytes", zb,
                      "fix", yav(0));
        ya_set(offs, sec, yv_long(yv_l(ya_get(offs, sec)) + n));
        return yr(4, "err", ys(""), "sec", yv_long(sec), "offs", offs,
                  "item", item);
    }
}

static Yv *asm_insn(Yv *line, long lno, long sec, Yv *offs) {
    long sp = ys_index_of(line, ys(" "));
    long tab = ys_index_of(line, ys("\t"));
    long cut = sp;
    /* NOTE: nested ifs, not `||` (see is_digit_ch note); `0;` tails. */
    if (tab >= 0) {
        if (sp < 0) { cut = tab; ; }
        else if (tab < sp) { cut = tab; ; }

        ;
    }
    Yv *mn = line;
    Yv *rest = ys("");
    if (cut >= 0) {
        mn = ys_slice(line, 0, cut);
        rest = ys_trim(ys_slice_from(line, cut + 1));
        ;
    }
    Yv *ops = yav(0);
    if (!ys_eq_lit(rest, "")) {
        Yv *texts = split_ops(rest);
        long i = 0;
        int ok = 1;
        while (i < yv_len(texts)) {
            Yv *r = parse_operand(ya_get(texts, i));
            /* NOTE: `0;` tails (see parser.y parse_binary note): `ok = false`
               is bool-typed; the else-arm is void-typed. */
            if (!(yv_b(yr_get(r, "ok")))) {
                ok = 0;
                ;
            } else {
                ops = ya_push(ops, yr_get(r, "op"));
                ;
            };
            i = i + 1;
            ;
        };
        if (!ok) {
            return yr(4,
                      "err", ys_cat(ys_cat(ys("L"), ys_long(lno)), ys(": bad operand")),
                      "sec", yv_long(sec), "offs", offs,
                      "item", yr(7, "sec", yv_long(-1), "off", yv_long(0), "len", yv_long(0),
                                 "kind", ys(""), "bytes", yav(0), "fix", yav(0), "br", yv_long(-1)));
        } else {
            return asm_encode(mn, ops, lno, sec, offs);
        }
    } else {
        return asm_encode(mn, ops, lno, sec, offs);
    }
}

/* The encoder writes the instruction into a scratch it fills through a
   cursor (enc64.c "the byte sink"): one array for the line, instead of the two
   or three little ones each concat step allocated. */
static Yv *asm_encode(Yv *mn, Yv *ops, long lno, long sec, Yv *offs) {
    Yv *buf = scratch();
    Yv *r = enc_insn(buf, 0, mn, ops, 0);
    if (!ys_eq_lit(yr_get(r, "err"), "")) {
        return yr(4,
                  "err", ys_cat(ys_cat(ys_cat(ys_cat(ys_cat(ys_cat(ys("L"), ys_long(lno)), ys(": ")), yr_get(r, "err")), ys(" in '")), mn), ys("'")),
                  "sec", yv_long(sec), "offs", offs,
                  "item", yr(7, "sec", yv_long(-1), "off", yv_long(0), "len", yv_long(0),
                             "kind", ys(""), "bytes", yav(0), "fix", yav(0), "br", yv_long(-1)));
    } else {
        long blen = yv_l(yr_get(r, "at"));
        Yv *item = yr(7, "sec", yv_long(sec), "off", ya_get(offs, sec), "len", yv_long(blen),
                      "kind", ys("insn"), "bytes", ya_slice(buf, 0, blen), "fix", yr_get(r, "fix"),
                      "br", yr_get(r, "br"));
        ya_set(offs, sec, yv_long(yv_l(ya_get(offs, sec)) + blen));
        return yr(4, "err", ys(""), "sec", yv_long(sec), "offs", offs, "item", item);
    }
}


/* ── the IR path: the emitter's items ────────────────────────────────────
 * A body the emitter wrote is a list of IR items (ir.y): the form and its
 * field words, IR_W (8) of them per item. asm.y assembles an item through the
 * same encoders as the text path -- enc_form instead of enc_insn, so the
 * dispatch is on the form id rather than a mnemonic string -- and everything
 * after pass 1 (asm_relax, asm_link, the ELF) works on the AsmItems either
 * way, so nothing else in this file changes.
 *
 * What is still text, and still lexed here: the header, the arch prelude
 * (~1.7k lines), the rodata and the .bss cells -- the blocks the emitter does
 * not write items for. */

/* One operand of kind `k` at word `wp`, as the encoder's Operand: the same
   shape parse_operand builds for the same instruction, so enc64 is unchanged. */
static Yv *ir_operand(Yv *ir, long wp, long k) {
    if (k == O_REG) {
        return yr(13, "k", yv_long(K_reg), "n", ya_get(ir, wp), "size", ya_get(ir, wp + 1),
                  "v", yv_long(0), "a", ys(""), "b", ys(""), "name", ys(""), "base",
                  yv_long(0), "idx", yv_long(0), "scale", yv_long(0), "disp",
                  yv_long(0), "rip", yv_bool(0), "lbl", ys(""));
    } else if (k == O_IND) {
        return yr(13, "k", yv_long(K_ind), "n", ya_get(ir, wp), "size", ya_get(ir, wp + 1),
                  "v", yv_long(0), "a", ys(""), "b", ys(""), "name", ys(""), "base",
                  yv_long(0), "idx", yv_long(0), "scale", yv_long(0), "disp",
                  yv_long(0), "rip", yv_bool(0), "lbl", ys(""));
    } else if (k == O_IMM) {
        return yr(13, "k", yv_long(K_imm), "n", yv_long(0), "size", yv_long(0), "v",
                  ya_get(ir, wp), "a", ys(""), "b", ys(""), "name", ys(""), "base",
                  yv_long(0), "idx", yv_long(0), "scale", yv_long(0), "disp",
                  yv_long(0), "rip", yv_bool(0), "lbl", ys(""));
    } else if (k == O_LBL) {
        return yr(13, "k", yv_long(K_lbl), "n", yv_long(0), "size", yv_long(0), "v",
                  yv_long(0), "a", ys(""), "b", ys(""), "name", lname(ya_get(ir, wp)),
                  "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0), "disp",
                  yv_long(0), "rip", yv_bool(0), "lbl", ys(""));
    } else if (k == O_DIFF) {
        return yr(13, "k", yv_long(K_diff), "n", yv_long(0), "size", yv_long(0), "v",
                  yv_long(0), "a", lname(ya_get(ir, wp)), "b", lname(ya_get(ir, wp + 1)),
                  "name", ys(""), "base", yv_long(0), "idx", yv_long(0), "scale",
                  yv_long(0), "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys(""));
    } else if (k == O_MEM || k == O_MEM0) {
        /* Five words: base, index, scale, disp, label. A label is a symbol at
           (%rip) -- what parse_mem_rip builds.
           O_MEM0 is `(%base)`, no displacement written: its disp word says
           nothing (the emitter leaves -1 there), and the encoder's convention
           for "no displacement byte" is a zero, not a -1 -- so O_MEM0 gets 0
           and O_MEM its own word, negative displacements and all. */
        long ml = yv_l(ya_get(ir, wp + 4));
        if (ml >= 0) {
            return yr(13, "k", yv_long(K_mem), "n", yv_long(0), "size", yv_long(0), "v",
                      yv_long(0), "a", ys(""), "b", ys(""), "name", ys(""), "base",
                      yv_long(-1), "idx", yv_long(-1), "scale", yv_long(1), "disp",
                      yv_long(0), "rip", yv_bool(1), "lbl", lname(ya_get(ir, wp + 4)));
        } else {
            long disp = yv_l(ya_get(ir, wp + 3));
            if (k == O_MEM0) { disp = 0; };
            return yr(13, "k", yv_long(K_mem), "n", yv_long(0), "size", yv_long(0), "v",
                      yv_long(0), "a", ys(""), "b", ys(""), "name", ys(""), "base",
                      ya_get(ir, wp), "idx", ya_get(ir, wp + 1), "scale",
                      ya_get(ir, wp + 2), "disp", yv_long(disp), "rip", yv_bool(0),
                      "lbl", ys(""));
        }
    } else {
        /* O_FS: the %fs:N word (a thread's own heap block) */
        return yr(13, "k", yv_long(K_fs), "n", yv_long(0), "size", yv_long(64), "v",
                  yv_long(0), "a", ys(""), "b", ys(""), "name", ys(""), "base",
                  yv_long(0), "idx", yv_long(0), "scale", yv_long(0), "disp",
                  ya_get(ir, wp), "rip", yv_bool(0), "lbl", ys(""));
    }
}

/* Where an error in an item is reported: an item has no line of assembly text
   to name, so it is the body's label and the item's number in it. */
static Yv *ir_where(Yv *lblname, long n) {
    if (ys_eq_lit(lblname, "")) {
        return ys_cat(ys("item "), ys_long(n));
    } else {
        return ys_cat(ys_cat(lblname, ys("+")), ys_long(n));
    }
}

static Yv *ir_enc_item(Yv *ir, long at, long sec, Yv *offs, Yv *where) {
    long f = yv_l(ya_get(ir, at));
    Yv *fo = ir_form(f);
    Yv *kinds = yr_get(fo, "kinds");
    Yv *ops = yav(0);
    long wp = at + 1;
    long i = 0;
    while (i < yv_len(kinds)) {
        ops = ya_push(ops, ir_operand(ir, wp, yv_l(ya_get(kinds, i))));
        wp = wp + ir_kind_words(yv_l(ya_get(kinds, i)));
        i = i + 1;
        ;
    };
    /* The encoder writes into the same scratch the text path uses, and a
       branch is asked for in the short form: asm_relax grows the ones that
       turn out to be out of range. */
    Yv *buf = scratch();
    Yv *r = enc_form(buf, 0, f, yr_get(fo, "mn"), ops, 0);
    if (!ys_eq_lit(yr_get(r, "err"), "")) {
        return yr(4, "err",
                  ys_cat(ys_cat(ys_cat(where, ys(": ")), yr_get(r, "err")),
                         ys_cat(ys_cat(ys(" in '"), yr_get(fo, "mn")), ys("'"))),
                  "sec", yv_long(sec), "offs", offs,
                  "item", yr(7, "sec", yv_long(-1), "off", yv_long(0), "len", yv_long(0),
                             "kind", ys(""), "bytes", yav(0), "fix", yav(0), "br", yv_long(-1)));
    } else {
        long blen = yv_l(yr_get(r, "at"));
        Yv *item = yr(7, "sec", yv_long(sec), "off", ya_get(offs, sec), "len", yv_long(blen),
                      "kind", ys("insn"), "bytes", ya_slice(buf, 0, blen), "fix",
                      yr_get(r, "fix"), "br", yr_get(r, "br"));
        ya_set(offs, sec, yv_long(yv_l(ya_get(offs, sec)) + blen));
        return yr(4, "err", ys(""), "sec", yv_long(sec), "offs", offs, "item", item);
    }
}

/* A label definition (IR_LABEL): the AsmLabel asm_labdef_go builds, with the
   name from the label table rather than from the line. */
static Yv *asm_ir_label(long id, long sec, Yv *offs, Yv *items, Yv *labels) {
    return ya_push(labels, yr(4, "name", lname(yv_long(id)), "sec", yv_long(sec), "off",
                              ya_get(offs, sec), "at_item", yv_long(yv_len(items))));
}

/* A .loc marker (IR_LOC): the item asm_loc builds, with the numbers read from
   the item instead of from a line. No sec check: a body is all .text. */
static Yv *asm_ir_loc(long file, long line, long sec, Yv *offs, long fno) {
    (void)sec; /* a body is all .text, so the marker goes in .text */
    Yv *fx = yav(2, yr(4, "off", yv_long(file + fno), "kind", ys("file"), "lbl", ys(""), "lbl2", ys("")),
                 yr(4, "off", yv_long(line), "kind", ys("line"), "lbl", ys(""), "lbl2", ys("")));
    return yr(4, "err", ys(""), "sec", yv_long(0), "offs", offs,
              "item", yr(7, "sec", yv_long(0), "off", ya_get(offs, 0), "len", yv_long(0),
                         "kind", ys("loc"), "bytes", yav(0), "fix", fx, "br", yv_long(-1)));
}

/* One part's items. `txt` holds the raw lines the IR_TEXT items index (the
   emitter's comment lines), `lno` the assembly line counter, which an
   IR_TEXT item's line error names as before. */
static Yv *asm_ir_items(Yv *ir, Yv *txt, long fno, int loc, long sec, Yv *offs, Yv *items, Yv *labels, Yv *err, long lno) {
    long at = 0;
    long n = 0;
    Yv *cur = ys("");
    while (at < yv_len(ir)) {
        long f = yv_l(ya_get(ir, at));
        if (f == IR_LABEL) {
            labels = asm_ir_label(yv_l(ya_get(ir, at + 1)), sec, offs, items, labels);
            cur = lname(ya_get(ir, at + 1));
        } else if (f == IR_LOC) {
            /* A marker nobody asked for is no item at all (see LinkPart.loc) */
            if (loc) {
                Yv *r = asm_ir_loc(yv_l(ya_get(ir, at + 1)), yv_l(ya_get(ir, at + 2)), sec,
                                   offs, fno);
                offs = yr_get(r, "offs");
                items = ya_push(items, yr_get(r, "item"));
            };
        } else if (f == IR_TEXT) {
            /* A line of assembly text (the emitter's comment lines): the text
               path, so it is read -- and refused -- exactly as it was. */
            long i = yv_l(ya_get(ir, at + 1));
            Yv *line = ys("");
            if (i >= 0 && i < yv_len(txt)) { line = ya_get(txt, i); };
            Yv *st = asm_assemble_line(yav(1, line), 0, lno, sec, offs, items, labels, err);
            sec = yv_l(yr_get(st, "sec"));
            offs = yr_get(st, "offs");
            items = yr_get(st, "items");
            labels = yr_get(st, "labels");
            err = yr_get(st, "err");
            lno = lno + 1;
        } else {
            Yv *r = ir_enc_item(ir, at, sec, offs, ir_where(cur, n));
            offs = yr_get(r, "offs");
            if (!ys_eq_lit(yr_get(r, "err"), "")) {
                err = yr_get(r, "err");
            } else {
                items = ya_push(items, yr_get(r, "item"));
            };
        };
        at = at + IR_W;
        n = n + 1;
        ;
    };
    return asm_ir_st(sec, offs, items, labels, err, lno);
}

/* A part of the assembly to assemble: a body's items (`ir`, with the raw lines
   its IR_TEXT items index in `txt`), or a piece of assembly text -- the
   header, the arch prelude, the rodata, the .bss cells, and a body read from
   the std pack or an object cache (packed, native.y's unpack_body).
   `fno` moves this part's `.loc` markers' file numbers: a unit's body numbers
   its own files from 1, and the linker gives it its place in the program's
   file table (0 when there is nothing to move) -- which is also what
   ir_render does with them, so a `-g -S` listing is the text assembled here.
   `loc` says the markers are wanted at all: a std unit's bodies are compiled
   with line info whatever the program asked for, so without -g they are
   dropped. */
Yv *part_ir(Yv *ir, Yv *txt, long fno, int loc) {
    return yr(5, "ir", ir, "txt", txt, "text", ys(""), "fno", yv_long(fno), "loc",
              yv_bool(loc));
}

Yv *part_text(Yv *text) {
    return yr(5, "ir", yav(0), "txt", yav(0), "text", text, "fno", yv_long(0), "loc",
              yv_bool(0));
}

static Yv *asm_ir_st(long sec, Yv *offs, Yv *items, Yv *labels, Yv *err, long lno) {
    return yr(6, "sec", yv_long(sec), "offs", offs, "items", items, "labels", labels,
              "err", err, "lno", yv_long(lno));
}

/* One text line through the text path, on the IR path's state (the line
   counter it advances is what an IR_TEXT item's error names). */
static Yv *asm_st_seg(Yv *st, Yv *lines, long li) {
    Yv *r = asm_assemble_line(lines, li, yv_l(yr_get(st, "lno")), yv_l(yr_get(st, "sec")),
                              yr_get(st, "offs"), yr_get(st, "items"),
                              yr_get(st, "labels"), yr_get(st, "err"));
    return asm_ir_st(yv_l(yr_get(r, "sec")), yr_get(r, "offs"), yr_get(r, "items"),
                     yr_get(r, "labels"), yr_get(r, "err"), yv_l(yr_get(st, "lno")) + 1);
}

/* ── branch relaxation ───────────────────────────────────────────────────
   A branch within rel8 of its target is two bytes instead of five or six, and
   54% of the branches in ycc.y are (measured on ycc.y compiled by this
   compiler: 8,053 of 14,832, and the short form is 53,661 bytes of branch
   against 83,596 for the long form of every one of them). Which ones is not
   known while encoding — an instruction's length has to be settled before the
   addresses are, and a branch's target is usually not where it is yet — so
   pass 1 asks for the short form everywhere
   and this pass grows what does not reach: a grower is three or four bytes
   longer, which moves everything after it, so the distances are recomputed
   and the rest retested. Growth is monotone, so the rounds end at a fixpoint;
   measured on ycc.y it takes 4 rounds and 6,780 grows, and a round is one
   sweep of the items plus a re-encode per grower.

   RELAX_ROUNDS bounds the work. Hitting it is not a wrong answer — every branch
   still gets re-encoded long, which is exactly what the assembler emitted
   before — so the bound costs size, never correctness. */
#define RELAX_ROUNDS 8

static long asm_relax(Yv *items, Yv *labels, int debug) {
    /* The rounds walk two compact arrays of the items' lengths and sections
       rather than the records: an AsmItem is seven words, and streaming 13 MB
       of them four times over was most of this pass (measured 47 ms for ycc.y
       before this, against 9 ms after). One sweep builds the arrays; a branch
       index list (there are 15k branches to 234k items) keeps the rounds off
       the records entirely, and `cum` holds the round's frozen offsets. */
    Yv *lens = yav(0);
    Yv *secs = yav(0);
    Yv *brs = yav(0);
    long i = 0;
    while (i < yv_len(items)) {
        Yv *it = ya_get(items, i);
        lens = ya_push(lens, yr_get(it, "len"));
        secs = ya_push(secs, yr_get(it, "sec"));
        if (yv_l(yr_get(it, "br")) >= 0 && yv_l(yr_get(it, "sec")) == 0) {
            brs = ya_push(brs, yv_long(i));
        }
        i = i + 1;
    }
    Yv *cum = yav(0);
    Yv *rlmap = relax_map(labels);
    long rounds = 0;
    int again = 1;
    while (again && rounds < RELAX_ROUNDS) {
        rounds = rounds + 1;
        /* Round 1 has nothing to place: pass 1 laid the items and the labels
           out with every branch short, which is exactly this round's frozen
           layout. */
        again = relax_round(items, labels, rlmap, lens, secs, brs, cum, rounds == 1);
    }
    if (again) { relax_all_long(items, labels, lens); }
    /* One last placement, at the final lengths: the rounds place the labels
       from the lengths they started with, so the last round's growers leave
       every label stale by what they added -- and every label-relative fixup
       (rel32, rip32, imm32diff) is measured against these. */
    relax_place(items, labels, lens, secs, debug);
    return rounds;
}

/* The relaxation's own name -> label map, built once. It is the assembler's
   labmap with `off` carrying the label's INDEX in `labels` rather than an
   address: an address moves every round (that is the whole point) while an
   index does not, so one build serves every round instead of one per round. */
static Yv *relax_map(Yv *labels) {
    long cap = yv_len(labels) * 2 + 16;
    Yv *m = labmap_new(cap);
    long i = 0;
    while (i < yv_len(labels)) {
        Yv *r = labmap_put(m, yr_get(ya_get(labels, i), "name"), 0, i);
        m = yr_get(r, "map");
        i = i + 1;
    }
    return m;
}

/* One round: place the .text labels (unless `first`, when pass 1's offsets
   are already this round's), then grow every short branch whose target is out
   of range. Returns true if anything grew. */
static int relax_round(Yv *items, Yv *labels, Yv *rlmap, Yv *lens, Yv *secs, Yv *brs, Yv *cum, int first) {
    if (!first) {
        /* cum[k] is where item k starts in .text at the current lengths; the
           label before item `at_item` is therefore at cum[at_item]. */
        long at = 0;
        long i = 0;
        while (i < yv_len(lens)) {
            if (i < yv_len(cum)) { ya_set(cum, i, yv_long(at)); }
            else { cum = ya_push(cum, yv_long(at)); }
            if (yv_l(ya_get(secs, i)) == 0) { at = at + yv_l(ya_get(lens, i)); }
            i = i + 1;
        }
        long j = 0;
        while (j < yv_len(labels)) {
            Yv *lb = ya_get(labels, j);
            if (yv_l(yr_get(lb, "sec")) == 0) {
                ya_set(labels, j, yr(4, "name", yr_get(lb, "name"), "sec", yv_long(0),
                                      "off", ya_get(cum, yv_l(yr_get(lb, "at_item"))),
                                      "at_item", yr_get(lb, "at_item")));
            }
            j = j + 1;
        }
    }
    /* The branches, against the FROZEN offsets: growth is permanent, so a
       branch that fits in this round's layout but is pushed out of range by a
       grower earlier in the same sweep must wait for the next round, or the
       sweep cascades and every branch ends up long (measured: 14,680 grown in
       one round that way, against 6,673 with the frozen layout, and 140 short
       branches at the end instead of 8,047). */
    int grew = 0;
    long k = 0;
    while (k < yv_len(brs)) {
        long i = yv_l(ya_get(brs, k));
        /* len 2 is the short form; a grower is already long. */
        if (yv_l(ya_get(lens, i)) == 2) {
            Yv *it = ya_get(items, i);
            Yv *fx = ya_get(yr_get(it, "fix"), 0);
            long li = relax_target(rlmap, yr_get(fx, "lbl"));
            long here = first ? yv_l(yr_get(it, "off")) : yv_l(ya_get(cum, i));
            /* An unknown target is pass 2's error to report, and a target
               outside .text has no address to measure yet: grow both, so
               nothing here can be wrong in a way pass 2 would not catch. */
            if (li >= 0 && yv_l(yr_get(ya_get(labels, li), "sec")) == 0) {
                long d = yv_l(yr_get(ya_get(labels, li), "off")) - (here + 2);
                if (d < -128 || d > 127) {
                    relax_grow(items, i, lens, yr_get(fx, "lbl"));
                    grew = 1;
                }
            } else {
                relax_grow(items, i, lens, yr_get(fx, "lbl"));
                grew = 1;
            }
        }
        k = k + 1;
    }
    return grew;
}

/* The label a branch names, or -1 when the map does not have it. */
static long relax_target(Yv *rlmap, Yv *lbl) {
    Yv *e = labmap_get(rlmap, lbl);
    if (yv_l(yr_get(e, "sec")) < 0) { return -1; }
    return yv_l(yr_get(e, "off"));
}

/* Re-encode item `i` in the long form, from what it recorded (`br`) and what
   its fixup names. Returns the new length. */
static long relax_grow(Yv *items, long i, Yv *lens, Yv *lbl) {
    Yv *it = ya_get(items, i);
    Yv *buf = scratch();
    Yv *r = enc_branch_long(buf, 0, yv_l(yr_get(it, "br")), lbl);
    long alen = yv_l(yr_get(r, "at"));
    ya_set(items, i, yr(7, "sec", yr_get(it, "sec"), "off", yr_get(it, "off"),
                        "len", yv_long(alen), "kind", yr_get(it, "kind"),
                        "bytes", ya_slice(buf, 0, alen), "fix", yr_get(r, "fix"),
                        "br", yr_get(it, "br")));
    ya_set(lens, i, yv_long(alen));
    return alen;
}

/* The bound case: every branch long, which is the pre-relaxation encoding. */
static long relax_all_long(Yv *items, Yv *labels, Yv *lens) {
    (void)labels;
    long n = 0;
    long i = 0;
    while (i < yv_len(lens)) {
        Yv *it = ya_get(items, i);
        if (yv_l(yr_get(it, "sec")) == 0 && yv_l(yr_get(it, "br")) >= 0 && yv_l(ya_get(lens, i)) != 2) {
            relax_grow(items, i, lens, yr_get(ya_get(yr_get(it, "fix"), 0), "lbl"));
            n = n + 1;
        }
        i = i + 1;
    }
    return n;
}

/* The final placement: the labels at the final lengths (always -- pass 2
   measures every fixup against them), and the item offsets too, but only for
   -g: they are one record rebuild per item, and the line table is their only
   reader. */
static long relax_place(Yv *items, Yv *labels, Yv *lens, Yv *secs, int debug) {
    Yv *offs = yav(3, yv_long(0), yv_long(0), yv_long(0));
    long i = 0;
    long j = 0;
    while (i < yv_len(lens)) {
        while (j < yv_len(labels) && yv_l(yr_get(ya_get(labels, j), "at_item")) <= i) {
            Yv *lb = ya_get(labels, j);
            ya_set(labels, j, yr(4, "name", yr_get(lb, "name"), "sec", yr_get(lb, "sec"),
                                  "off", ya_get(offs, yv_l(yr_get(lb, "sec"))),
                                  "at_item", yr_get(lb, "at_item")));
            j = j + 1;
        }
        long s = yv_l(ya_get(secs, i));
        if (s >= 0) {
            if (debug) {
                Yv *it = ya_get(items, i);
                ya_set(items, i, yr(7, "sec", yr_get(it, "sec"), "off", ya_get(offs, s),
                                    "len", yr_get(it, "len"), "kind", yr_get(it, "kind"),
                                    "bytes", yr_get(it, "bytes"), "fix", yr_get(it, "fix"),
                                    "br", yr_get(it, "br")));
            }
            ya_set(offs, s, yv_long(yv_l(ya_get(offs, s)) + yv_l(ya_get(lens, i))));
        }
        i = i + 1;
    }
    while (j < yv_len(labels)) {
        Yv *lb = ya_get(labels, j);
        ya_set(labels, j, yr(4, "name", yr_get(lb, "name"), "sec", yr_get(lb, "sec"),
                              "off", ya_get(offs, yv_l(yr_get(lb, "sec"))),
                              "at_item", yr_get(lb, "at_item")));
        j = j + 1;
    }
    return yv_l(ya_get(offs, 0));
}

/* ── pass 2: layout, fixups, ELF ──────────────────────────────────────── */

static Yv *asm_link(Yv *items, Yv *labels, int debug) {
    /* section sizes */
    long lt0 = clock_us();
    long lh0 = heap_used();
    long code_len = 0;
    long ro_len = 0;
    long bss_len = 0;
    int bss_data = 0;
    /* NOTE: `0;` tails (see parser.y parse_binary note). `it.len` reads go
       through the bare hole (tnone unifies — see types.y typeof_def note).
       elf_build takes the rodata bytes and sizes that segment itself; the
       rodata length only places the .bss. */
    long i = 0;
    while (i < yv_len(items)) {
        Yv *it = ya_get(items, i);
        long sec = yv_l(yr_get(it, "sec"));
        if (sec == 0) {
            code_len = code_len + yv_l(yr_get(it, "len"));
            ;
        } else if (sec == 1) {
            ro_len = ro_len + yv_l(yr_get(it, "len"));
            ;
        } else if (sec == 2) {
            bss_len = bss_len + yv_l(yr_get(it, "len"));
            if (yv_len(yr_get(it, "bytes")) > 0) { bss_data = 1; ; }
            ;
        }
        i = i + 1;
        ;
    };
    /* A .bss label resolves like a rodata one, past the mapped image (see
       elf_bss_from_ro), so the fixups below only know two sections. */
    Yv *labs = labels;
    if (bss_len > 0) {
        long bshift = elf_bss_from_ro(code_len, ro_len);
        labs = yav(0);
        long j = 0;
        while (j < yv_len(labels)) {
            Yv *lb = ya_get(labels, j);
            if (yv_l(yr_get(lb, "sec")) == 2) {
                labs = ya_push(
                    labs,
                    yr(3, "name", yr_get(lb, "name"), "sec", yv_long(1),
                       "off", yv_long(bshift + yv_l(yr_get(lb, "off")))));
            } else {
                labs = ya_push(labs, lb);
            }
            j = j + 1;
        }
    }
    Yv *lm = labmap_build(labs);
    long lt1 = clock_us();
    long lh1 = heap_used();
    Yv *lmap = yr_get(lm, "map");
    Yv *start = labmap_get(lmap, ys("_start"));
    if (!ys_eq_lit(yr_get(lm, "dup"), "")) {
        return yr(4, "ok", yv_bool(0), "bytes", yav(0),
                  "error", ys_cat(ys_cat(ys("duplicate label '"), yr_get(lm, "dup")), ys("'")),
                  "times", yav(1, yr(3, "name", ys("l:labmap"), "us", yv_long(lt1 - lt0), "heap", yv_long(lh1 - lh0))));
    } else if (yv_l(yr_get(start, "sec")) != 0) {
        return yr(4, "ok", yv_bool(0), "bytes", yav(0), "error", ys("no _start label (empty program?)"),
                  "times", yav(1, yr(3, "name", ys("l:labmap"), "us", yv_long(lt1 - lt0), "heap", yv_long(lh1 - lh0))));
    } else if (bss_data) {
        return yr(4, "ok", yv_bool(0), "bytes", yav(0),
                  "error", ys("data or code in .bss"),
                  "times", yav(1, yr(3, "name", ys("l:labmap"), "us", yv_long(lt1 - lt0), "heap", yv_long(lh1 - lh0))));
    } else {
        /* No padding between the code and the rodata (mirrors elf.y): the
           loader zero-fills the last page of the mapping instead, so a
           rodata label's offset is exactly code_len + its own offset. */
        long pad = 0;
        Yv *code = yav(0);
        Yv *ro = yav(0);
        Yv *err = ys("");
        long i = 0;
        /* NOTE: nested ifs, not `&&` (see is_digit_ch note); `0;` tails. */
        while (i < yv_len(items)) {
            if (!ys_eq_lit(err, "")) {
                i = yv_len(items);
                ;
            } else {
            Yv *it = ya_get(items, i);
            if (yv_l(yr_get(it, "sec")) == 0) {
                Yv *r = patch_item(code, it, lmap, code_len, pad);
                /* NOTE: `0;` tails (see note above): str-arm vs [byte]-arm. */
                if (!ys_eq_lit(yr_get(r, "err"), "")) {
                    err = yr_get(r, "err");
                    ;
                } else {
                    code = yr_get(r, "bytes");
                    ;
                };
                ;
            } else if (yv_l(yr_get(it, "sec")) == 1) {
                /* Y: `ro += it.bytes` — one push per element (yv.h has no
                   `+=` helper, so the array form is spelled out here). The
                   append is in place: the array header never moves. */
                Yv *rbytes = yr_get(it, "bytes");
                long j = 0;
                while (j < yv_len(rbytes)) {
                    ro = ya_push(ro, ya_get(rbytes, j));
                    j = j + 1;
                    ;
                };
                ;
            }
            i = i + 1;
            ;
            };
        };
        if (!ys_eq_lit(err, "")) {
            return yr(4, "ok", yv_bool(0), "bytes", yav(0), "error", err,
                      "times", yav(1, yr(3, "name", ys("l:labmap"), "us", yv_long(lt1 - lt0), "heap", yv_long(lh1 - lh0))));
        } else {
            long lt2 = clock_us();
            long lh2 = heap_used();
            Yv *syms = yav(0);
            Yv *dsecs = yav(0);
            if (debug) {
                syms = debug_syms(labels, code_len, bss_len);
                dsecs = debug_lines(items, code_len, elf_code_off(bss_len));
            }
            Yv *eb = elf_build(code, ro, yv_l(yr_get(start, "off")),
                               bss_len, syms, dsecs);
            long lt3 = clock_us();
            long lh3 = heap_used();
            return yr(4, "ok", yv_bool(1), "bytes", eb, "error", ys(""),
                      "times", yav(3,
                                   yr(3, "name", ys("l:labmap"), "us", yv_long(lt1 - lt0), "heap", yv_long(lh1 - lh0)),
                                   yr(3, "name", ys("l:patch"), "us", yv_long(lt2 - lt1), "heap", yv_long(lh2 - lh1)),
                                   yr(3, "name", ys("l:elf"), "us", yv_long(lt3 - lt2), "heap", yv_long(lh3 - lh2))));
        }
    }
}

static Yv *patch_item(Yv *code, Yv *it, Yv *lmap, long code_len, long pad) {
    Yv *bytes = yr_get(it, "bytes");
    Yv *err = ys("");
    /* NOTE: single gate (see asm_strdata note): insn-vs-other shapes never
       mix in one chain. */
    if (!ys_eq_lit(yr_get(it, "kind"), "insn")) {
        return patch_item_finish(code, bytes, err);
    } else {
        return patch_item_loop(code, it, lmap, code_len, pad, bytes, err);
    }
}

static Yv *patch_item_loop(Yv *code, Yv *it, Yv *lmap, long code_len, long pad, Yv *bytes, Yv *err) {
    long base = yv_len(code);
    Yv *fxlist = yr_get(it, "fix");
    long f = 0;
    /* NOTE: nested ifs, not `&&` (see is_digit_ch note); `0;` tails. */
    while (f < yv_len(fxlist)) {
        if (!ys_eq_lit(err, "")) {
            f = yv_len(fxlist);
            ;
        } else {
        Yv *fx = ya_get(fxlist, f);
        /* at is instruction-relative: bytes is the ITEM's list, and the
           rel target is relative to the instruction END (base + it.len). */
        long at = yv_l(yr_get(fx, "off"));
        /* NOTE: nested ifs, not `||` (see is_digit_ch note).
           NOTE: thread callee results (see note above): the callee's
           {bytes,err} is the only path the patched bytes take to the
           caller, so both arms must rebind `bytes` (and `err`). */
        if (ys_eq_lit(yr_get(fx, "kind"), "rel32") || ys_eq_lit(yr_get(fx, "kind"), "rip32")) {
            Yv *rr = patch_item_rel(lmap, code_len, pad, fx, bytes, base, it, at);
            bytes = yr_get(rr, "bytes");
            if (!ys_eq_lit(yr_get(rr, "err"), "")) { err = yr_get(rr, "err"); ; }
            ;
        } else if (ys_eq_lit(yr_get(fx, "kind"), "rel8")) {
            Yv *r8 = patch_item_rel8(lmap, code_len, pad, fx, bytes, base, it, at);
            bytes = yr_get(r8, "bytes");
            if (!ys_eq_lit(yr_get(r8, "err"), "")) { err = yr_get(r8, "err"); ; }
            ;
        } else {
            Yv *rk = patch_item_kind2(lmap, code_len, pad, fx, bytes, base, it, at);
            bytes = yr_get(rk, "bytes");
            if (!ys_eq_lit(yr_get(rk, "err"), "")) { err = yr_get(rk, "err"); ; }
            ;
        };
        f = f + 1;
        ;
        };
    };
    return patch_item_finish(code, bytes, err);
}

static Yv *patch_item_kind2(Yv *lmap, long code_len, long pad, Yv *fx, Yv *bytes, long base, Yv *it, long at) {
    /* (split: non-rel32 kinds; `{bytes,err}` built ONLY here + callees.) */
    if (ys_eq_lit(yr_get(fx, "kind"), "rip32")) {
        return patch_item_rel(lmap, code_len, pad, fx, bytes, base, it, at);
    } else {
        return patch_item_diff(lmap, code_len, pad, fx, bytes, base, it);
    }
}

static Yv *patch_item_rel(Yv *lmap, long code_len, long pad, Yv *fx, Yv *bytes, long base, Yv *it, long at) {
    /* rel32/rip32: target - address past the instruction.
       NOTE: fx/it stay BARE holes (see types.y typeof_def note): single
       reads unify. */
    Yv *t = label_addr(lmap, code_len, pad, yr_get(fx, "lbl"));
    if (!(yv_b(yr_get(t, "ok")))) {
        return yr(2, "bytes", bytes,
                  "err", ys_cat(ys_cat(ys("undefined label '"), yr_get(fx, "lbl")), ys("'")));
    } else {
        long v = yv_l(yr_get(t, "addr")) - (base + yv_l(yr_get(it, "len")));
        return yr(2, "bytes", patch32(bytes, at, v), "err", ys(""));
    }
}

static Yv *patch_item_rel8(Yv *lmap, long code_len, long pad, Yv *fx, Yv *bytes, long base, Yv *it, long at) {
    /* rel8: the same displacement in one byte, for a branch that relaxed.
       asm_relax only leaves one of these in range, so the value fits by
       construction (it grew the item otherwise); the truncation is still a
       byte store, not a silent 32-bit write past the instruction.
       NOTE: fx/it stay BARE holes (see types.y typeof_def note). */
    Yv *t = label_addr(lmap, code_len, pad, yr_get(fx, "lbl"));
    if (!yv_b(yr_get(t, "ok"))) {
        return yr(2, "bytes", bytes, "err", ys_cat(ys_cat(ys("undefined label '"), yr_get(fx, "lbl")), ys("'")));
    } else {
        long v = yv_l(yr_get(t, "addr")) - (base + yv_l(yr_get(it, "len")));
        return yr(2, "bytes", patch8(bytes, at, v), "err", ys(""));
    }
}

static Yv *patch_item_diff(Yv *lmap, long code_len, long pad, Yv *fx, Yv *bytes, long base, Yv *it) {
    /* (split: diff-shape fixups only; `{bytes,err}` built ONLY here.)
       NOTE: fx/it stay BARE holes (see types.y typeof_def note): single
       reads unify. */
    (void)base;
    (void)it;
    Yv *ta = label_addr(lmap, code_len, pad, yr_get(fx, "lbl"));
    if (!(yv_b(yr_get(ta, "ok")))) {
        return yr(2, "bytes", bytes,
                  "err", ys_cat(ys_cat(ys("undefined label '"), yr_get(fx, "lbl")), ys("'")));
    } else {
        Yv *dd = patch_item_diff2(lmap, code_len, pad, fx, bytes, yv_l(yr_get(ta, "addr")));
        return yr(2, "bytes", yr_get(dd, "bytes"), "err", yr_get(dd, "err"));
    }
}

static Yv *patch_item_diff2(Yv *lmap, long code_len, long pad, Yv *fx, Yv *bytes, long ta) {
    Yv *tb = label_addr(lmap, code_len, pad, yr_get(fx, "lbl2"));
    if (!(yv_b(yr_get(tb, "ok")))) {
        return yr(2, "bytes", bytes,
                  "err", ys_cat(ys_cat(ys("undefined label '"), yr_get(fx, "lbl2")), ys("'")));
    } else {
        return yr(2, "bytes", patch32(bytes, yv_l(yr_get(fx, "off")), ta - yv_l(yr_get(tb, "addr"))), "err", ys(""));
    }
}

static Yv *patch_item_finish(Yv *code, Yv *bytes, Yv *err) {
    /* In place: `code + bytes` built a fresh copy of the whole code buffer
       per instruction (O(n^2) arena; ~30 GB on the self-compile). */
    code = concat_bytes(code, bytes);
    return yr(2, "bytes", code, "err", err);
}

static Yv *patch32(Yv *bytes, long at, long v) {
    Yv *b = le32(v);
    ya_set(bytes, at, ya_get(b, 0));
    ya_set(bytes, at + 1, ya_get(b, 1));
    ya_set(bytes, at + 2, ya_get(b, 2));
    ya_set(bytes, at + 3, ya_get(b, 3));
    return bytes;
}

static Yv *patch8(Yv *bytes, long at, long v) {
    /* The low byte of a rel8 displacement, which is two's complement: v + 256
       before the modulo because Y's % truncates toward zero and a negative
       displacement must land on its high byte (v - 128 stores 128, not -128). */
    ya_set(bytes, at, yv_long((v + 256) % 256));
    return bytes;
}

/* ── -g: the symbol table ───────────────────────────────────────────────
 * A function symbol starts at every label a body begins with: `_start`,
 * a runtime helper (`y_*`) or a compiled def (`yfn_<uid>_<name>`). Jump
 * targets (`yL_*`) and the arch prelude's internal labels (`yse_loop`,
 * `ysj_sum`, ...) belong to the function before them, and rodata strings
 * get no symbol. In the .bss, the globals (`yg_*`) and the allocator's
 * `y_heap` cells are data symbols. Each symbol is sized up to the next
 * one in its section (the last one to the section end), which is exactly
 * what perf and valgrind need to attribute an address. */
static Yv *debug_syms(Yv *labels, long code_len, long bss_len) {
    Yv *out = yav(0);
    out = debug_syms_sec(out, labels, 0, code_len);
    out = debug_syms_sec(out, labels, 2, bss_len);
    return out;
}

static Yv *debug_syms_sec(Yv *out, Yv *labels, long sec, long end) {
    long first = yv_len(out);
    long j = 0;
    while (j < yv_len(labels)) {
        Yv *lb = ya_get(labels, j);
        if (yv_l(yr_get(lb, "sec")) == sec) {
            if (is_sym_label(yr_get(lb, "name"), sec)) {
                out = ya_push(
                    out, yr(4, "name", sym_name(yr_get(lb, "name")), "sec",
                            yv_long(sec), "off", yr_get(lb, "off"), "size",
                            yv_long(0)));
            }
        }
        j = j + 1;
    }
    /* labels arrive in definition order, so offsets only grow */
    long i = first;
    while (i < yv_len(out)) {
        Yv *e = ya_get(out, i);
        long nxt = end;
        if (i + 1 < yv_len(out)) {
            Yv *n = ya_get(out, i + 1);
            nxt = yv_l(yr_get(n, "off"));
        }
        yr_set(e, "size",
               yv_long(nxt - yv_l(yr_get(e, "off"))));
        i = i + 1;
    }
    return out;
}

static int is_sym_label(Yv *name, long sec) {
    if (sec == 0) {
        return ys_eq_lit(name, "_start") ||
               ys_starts_with(name, ys("y_")) ||
               ys_starts_with(name, ys("yfn_"));
    } else {
        return ys_starts_with(name, ys("yg_")) ||
               ys_starts_with(name, ys("y_"));
    }
}

/* The source name behind a label: `yfn_12_foo$3` -> `foo`, `yg_0_n$7` ->
 * `n`; runtime names (`y_print_long`) stay as they are. The uid and
 * rename's `$N` change from build to build, so they would only make
 * profiles of two builds harder to line up. */
static Yv *sym_name(Yv *lbl) {
    Yv *s = lbl;
    if (ys_starts_with(s, ys("yfn_"))) {
        s = after_uid(s, 4);
    } else if (ys_starts_with(s, ys("yg_"))) {
        s = after_uid(s, 3);
    }
    long d = ys_last_index_of(s, ys("$"));
    if (d > 0) {
        long k = d + 1;
        int digits = k < yv_len(s);
        while (k < yv_len(s)) {
            if (!is_digit_ch(ys_byte_at(s, k))) {
                digits = 0;
            }
            k = k + 1;
        }
        if (digits) {
            s = ys_slice(s, 0, d);
        }
    }
    return s;
}

/* `s` minus its `<prefix><digits>_` head, or `s` itself when the shape
 * does not match. */
static Yv *after_uid(Yv *s, long k) {
    long i = k;
    while (i < yv_len(s) && is_digit_ch(ys_byte_at(s, i))) {
        i = i + 1;
    }
    if (i > k && i < yv_len(s) && ys_eq_lit(ys_slice(s, i, i + 1), "_")) {
        return ys_slice_from(s, i + 1);
    } else {
        return s;
    }
}

/* The `.file` table and the `.loc` rows (asm_file/asm_loc) as dwarf.y's
 * sections. Rows are flat (offset, file, line) triples in text order; a
 * `.file N` fills slot N-1 of the table ("?" stands in for a number never
 * named). No row -- a text without markers -- means no sections at all. */
static Yv *debug_lines(Yv *items, long code_len, long code_off) {
    Yv *files = yav(0);
    Yv *rows = yav(0);
    long i = 0;
    while (i < yv_len(items)) {
        Yv *it = ya_get(items, i);
        Yv *k = yr_get(it, "kind");
        if (ys_eq_lit(k, "loc")) {
            Yv *fx = yr_get(it, "fix");
            rows = ya_push(rows, yr_get(it, "off"));
            rows = ya_push(rows, yr_get(ya_get(fx, 0), "off"));
            rows = ya_push(rows, yr_get(ya_get(fx, 1), "off"));
            ;
        } else if (ys_eq_lit(k, "file")) {
            Yv *fx = yr_get(it, "fix");
            long file_no = yv_l(yr_get(it, "off"));
            while (yv_len(files) < file_no) {
                files = ya_push(files, ys("?"));
                ;
            }
            ya_set(files, file_no - 1, yr_get(ya_get(fx, 0), "lbl"));
            ;
        }
        i = i + 1;
    }
    if (yv_len(rows) == 0) {
        return yav(0);
    } else {
        return dwarf_sections(files, rows, 4194304 + code_off, code_len,
                              asm_cwd());
    }
}

/* The working directory, recorded as the compile unit's DW_AT_comp_dir
 * (as GNU as does): the raw getcwd syscall fills buf and returns the
 * path's length with its NUL, or a negative errno -- "." then. */
static Yv *asm_cwd(void) {
    char buf[4096];
    long n = syscall(SYS_getcwd, buf, 4096);
    if (n > 1) {
        return ys_cstr(buf);
    } else {
        return ys(".");
    }
}

/* asm.y's `code += bytes` (yv.h has no `+=` helper for an array operand, so
   the in-place append is spelled out as one push per element). */
static Yv *concat_bytes(Yv *a, Yv *b) {
    long i = 0;
    while (i < yv_len(b)) {
        a = ya_push(a, ya_get(b, i));
        i = i + 1;
    }
    return a;
}

/* Convenience for the driver: text in, bytes out. The driver writes the
   bytes straight through the write syscall (NUL-safe). The old `octal`
   RENDERING was removed: it cost O(n^2) string building (one malloc+copy
   per byte) and nothing read it — it dominated -o time. The field itself
   stays in the record shape (always "") so the shape does not change. */
Yv *ycc_assemble(Yv *parts, int debug) {
    Yv *r = asm_assemble(parts, debug);
    if (!(yv_b(yr_get(r, "ok")))) {
        return yr(6, "ok", yv_bool(0), "bytes", yav(0), "octal", ys(""),
                  "error", yr_get(r, "error"), "times", yr_get(r, "times"),
                  "items", yv_long(0));
    } else {
        return yr(6, "ok", yv_bool(1), "bytes", yr_get(r, "bytes"), "octal", ys(""),
                  "error", ys(""), "times", yr_get(r, "times"), "items",
                  yr_get(r, "items"));
    }
}
