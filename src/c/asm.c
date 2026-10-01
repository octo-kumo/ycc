/* asm.c — 1:1 port of src/y/asm.y (translation contract: PORTING.md).
 *
 * Assembler for the native backend's x86-64 dialect.
 * asm_assemble(text) -> {ok, bytes: [byte], error, times} (times: per-phase
 * us/heap rows for `ycc --time`).
 * ycc_assemble(text) -> the driver's wrapper (see its note at the bottom).
 * Only what native.y/arch_x64.y emit is accepted; anything else is a loud
 * error with a line number — never a silent miscompile.
 * Two passes: (1) parse + encode with zeroed label fields, recording fixups;
 * (2) resolve labels and patch. All jumps/calls use rel32 (fixed size), so
 * instruction lengths are known in pass 1.
 */
#include "asm.h"

/* imported (module calls from asm.y, names flattened) */
extern long reg_num(Yv *name);              /* enc64.c: enc.reg_num */
extern long reg_size(Yv *name);             /* enc64.c: enc.reg_size */
extern Yv *enc_insn(Yv *mn, Yv *ops);       /* enc64.c: enc.enc_insn */
extern Yv *le64(long v);                    /* enc64.c: enc.le64 */
extern Yv *le32(long v);                    /* enc64.c: enc.le32 */
extern Yv *elf_build(Yv *code, Yv *rodata, long entry_off); /* elf.c: elf.elf_build */

/* ── module-local defs (forward) ─────────────────────────────────────── */
static int is_digit_ch(Yv *c);
static int is_oct_ch(Yv *c);
static int is_alpha_ch(Yv *c);
static Yv *parse_num(Yv *s);
static Yv *parse_num_go(Yv *s, long i, int neg);
static int is_num_text(Yv *s);
static Yv *split_ops(Yv *s);
static Yv *parse_operand(Yv *t);
static Yv *parse_operand_empty(Yv *t);
static Yv *parse_operand_nonempty(Yv *t);
static Yv *parse_operand_ind(Yv *t);
static Yv *parse_operand_reg(Yv *t);
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
static long hash_str(Yv *s);
static Yv *labmap_new(long cap);
static Yv *labmap_put(Yv *m, Yv *name, long sec, long off);
static Yv *labmap_get(Yv *m, Yv *name);
static Yv *labmap_build(Yv *labels);
static Yv *label_addr(Yv *lmap, long code_len, long pad, Yv *name);
static Yv *asm_assemble_line(Yv *lines, long li, long sec, Yv *offs, Yv *items, Yv *labels, Yv *err);
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
static Yv *asm_section(Yv *line, long lno, long sec, Yv *offs, Yv *rest);
static int asm_section_bad(Yv *rest);
static Yv *asm_section_err(Yv *line, long lno, long sec, Yv *offs, Yv *rest);
static Yv *asm_section_go(long sec, Yv *offs, Yv *rest);
static Yv *asm_quad(Yv *line, long lno, long sec, Yv *offs, Yv *rest);
static int asm_quad_bad(Yv *rest);
static Yv *asm_quad_err(Yv *line, long lno, long sec, Yv *offs, Yv *rest);
static Yv *asm_quad_go(long sec, Yv *offs, Yv *rest);
static Yv *asm_insn(Yv *line, long lno, long sec, Yv *offs);
static Yv *asm_encode(Yv *mn, Yv *ops, long lno, long sec, Yv *offs);
static Yv *asm_link(Yv *items, Yv *labels);
static Yv *patch_item(Yv *code, Yv *it, Yv *lmap, long code_len, long pad);
static Yv *patch_item_loop(Yv *code, Yv *it, Yv *lmap, long code_len, long pad, Yv *bytes, Yv *err);
static Yv *patch_item_kind2(Yv *lmap, long code_len, long pad, Yv *fx, Yv *bytes, long base, Yv *it, long at);
static Yv *patch_item_rel(Yv *lmap, long code_len, long pad, Yv *fx, Yv *bytes, long base, Yv *it, long at);
static Yv *patch_item_diff(Yv *lmap, long code_len, long pad, Yv *fx, Yv *bytes, long base, Yv *it);
static Yv *patch_item_diff2(Yv *lmap, long code_len, long pad, Yv *fx, Yv *bytes, long ta);
static Yv *patch_item_finish(Yv *code, Yv *bytes, Yv *err);
static Yv *patch32(Yv *bytes, long at, long v);
static Yv *concat_bytes(Yv *a, Yv *b);

static int is_digit_ch(Yv *c) {
    /* 1:1 of asm.y's `c >= "0" && c <= "9"`. Str ordering is lexicographic
       by unsigned byte on both sides — asm.y reaches it through native.y's
       gen_str_cmp and the y_str_cmp stub, the C twin through yv.c's ys_cmp
       (memcmp on the common prefix, then length) — so a range test is
       ys_cmp(...) >= 0 / <= 0, the same translation lexer.c uses for
       isdigit/isupper/islower. */
    return ys_cmp(c, ys("0")) >= 0 && ys_cmp(c, ys("9")) <= 0;
}

static int is_oct_ch(Yv *c) {
    /* 1:1 of asm.y's `c >= "0" && c <= "7"` (same ys_cmp range test). */
    return ys_cmp(c, ys("0")) >= 0 && ys_cmp(c, ys("7")) <= 0;
}

static int is_alpha_ch(Yv *c) {
    /* 1:1 of asm.y's `c == "_" || (c >= "A" && c <= "Z") ||
       (c >= "a" && c <= "z")`. */
    return ys_eq_lit(c, "_") ||
           (ys_cmp(c, ys("A")) >= 0 && ys_cmp(c, ys("Z")) <= 0) ||
           (ys_cmp(c, ys("a")) >= 0 && ys_cmp(c, ys("z")) <= 0);
}

/* parse a decimal integer (optional leading -). Returns {ok, v}. */
static Yv *parse_num(Yv *s) {
    int neg = 0;
    long i = 0;
    /* NOTE: `0;` tails (see parser.y parse_binary note). */
    if (ys_eq_lit(ys_substr(s, 0, 1), "-")) {
        neg = 1;
        i = 1;
        ;
    } else { ; };
    if (i >= yv_len(s)) {
        return yr(2, "ok", yv_bool(0), "v", yv_long(0));
    } else {
        return parse_num_go(s, i, neg);
    }
}

static Yv *parse_num_go(Yv *s, long i, int neg) {
    /* (split: non-empty remainder narrows; `{ok,v}` built ONLY here.)
       NOTE: `0;` tails (see parser.y parse_binary note). */
    long v = 0;
    int ok = 1;
    while (i < yv_len(s)) {
        Yv *c = ys_substr(s, i, 1);
        if (is_digit_ch(c)) {
            v = v * 10 + ys_ord(c) - 48;
            ;
        } else {
            ok = 0;
            ;
        };
        i = i + 1;
        ;
    };
    if (neg) { v = 0 - v; ; } else { ; };
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
    Yv *cur = ys("");
    long i = 0;
    /* NOTE: nested ifs, not `&&` (see is_digit_ch note); `0;` tails. */
    while (i < yv_len(s)) {
        Yv *c = ys_substr(s, i, 1);
        if (ys_eq_lit(c, "(")) { depth = depth + 1; ; } else { ; };
        if (ys_eq_lit(c, ")")) { depth = depth - 1; ; } else { ; };
        if (ys_eq_lit(c, ",")) {
            if (depth == 0) {
                out = ya_push(out, ys_trim(cur));
                cur = ys("");
                ;
            } else {
                cur = ys_cat(cur, c);
                ;
            };
            ;
        } else {
            cur = ys_cat(cur, c);
            ;
        };
        i = i + 1;
        ;
    };
    out = ya_push(out, ys_trim(cur));
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
              "op", yr(13, "k", ys("bad"), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                        "a", ys(""), "b", ys(""), "name", ys(""),
                        "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                        "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys("")),
              "error", ys("empty operand"));
}

static Yv *parse_operand_nonempty(Yv *t) {
    /* `*%reg` — register-indirect call/jump target (closure code pointers). */
    if (ys_eq_lit(ys_substr(t, 0, 1), "*")) {
        return parse_operand_ind(t);
    } else if (ys_eq_lit(ys_substr(t, 0, 1), "%")) {
        return parse_operand_reg(t);
    } else {
        return parse_operand_noreg(t);
    }
}

static Yv *parse_operand_ind(Yv *t) {
    /* (split: *-gate above narrows; the rest must be a 64-bit register.) */
    Yv *r = ys_substr(t, 1, yv_len(t) - 1);
    long n = reg_num(r);
    if (n < 0) {
        return yr(3, "ok", yv_bool(0),
                  "op", yr(13, "k", ys("bad"), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                            "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys_cat(ys_cat(ys("unknown register '"), r), ys("'")));
    } else {
        return yr(3, "ok", yv_bool(1),
                  "op", yr(13, "k", ys("ind"), "n", yv_long(n), "size", yv_long(reg_size(r)), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                            "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys(""));
    }
}

static Yv *parse_operand_reg(Yv *t) {
    /* (split: %-gate above narrows; this body sees registers only.) */
    long n = reg_num(t);
    if (n < 0) {
        return yr(3, "ok", yv_bool(0),
                  "op", yr(13, "k", ys("bad"), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                            "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys_cat(ys_cat(ys("unknown register '"), t), ys("'")));
    } else {
        return yr(3, "ok", yv_bool(1),
                  "op", yr(13, "k", ys("reg"), "n", yv_long(n), "size", yv_long(reg_size(t)), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                            "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys(""));
    }
}

static Yv *parse_operand_noreg(Yv *t) {
    if (ys_eq_lit(ys_substr(t, 0, 1), "$")) {
        return parse_operand_imm(t);
    } else {
        return parse_operand_memlbl(t);
    }
}

static Yv *parse_operand_imm(Yv *t) {
    /* (split: $-gate above narrows; strips the $ and parses the immediate.) */
    return parse_imm(ys_substr(t, 1, yv_len(t) - 1));
}

static Yv *parse_operand_memlbl(Yv *t) {
    if (ys_index_of(t, ys("(")) >= 0) {
        return parse_mem(t);
    } else {
        return yr(3, "ok", yv_bool(1),
                  "op", yr(13, "k", ys("lbl"), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", t,
                            "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                            "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys(""));
    }
}

static Yv *parse_imm(Yv *s) {
    /* $a-b label difference, else decimal number */
    long dash = ys_index_of(ys_substr(s, 1, yv_len(s) - 1), ys("-"));
    if (yv_len(s) > 0) {
        return parse_imm_alpha(s, dash);
    } else {
        return parse_imm_num(s);
    }
}

static Yv *parse_imm_alpha(Yv *s, long dash) {
    /* (split: len>0 narrows; this body checks the alpha gate only.) */
    if (is_alpha_ch(ys_substr(s, 0, 1))) {
        return parse_imm_diff(s, dash);
    } else {
        return parse_imm_num(s);
    }
}

static Yv *parse_imm_diff(Yv *s, long dash) {
    /* (split: alpha-gate above narrows; diff-shape built ONLY here.) */
    if (dash >= 0) {
        Yv *a = ys_substr(s, 0, dash + 1);
        Yv *b = ys_substr(s, dash + 2, yv_len(s) - dash - 2);
        return yr(3, "ok", yv_bool(1),
                  "op", yr(13, "k", ys("diff"), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
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
                  "op", yr(13, "k", ys("imm"), "n", yv_long(0), "size", yv_long(0), "v", yr_get(r, "v"),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                            "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys(""));
    } else {
        return yr(3, "ok", yv_bool(0),
                  "op", yr(13, "k", ys("bad"), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
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
    Yv *head = ys_trim(ys_substr(t, 0, open));
    Yv *inside = ys_substr(t, open + 1, yv_len(t) - open - 2);
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
                  "op", yr(13, "k", ys("bad"), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                            "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys_cat(ys_cat(ys("bad rip-relative '"), t), ys("'")));
    } else if (!ys_eq_lit(ya_get(parts, 0), "%rip")) {
        return yr(3, "ok", yv_bool(0),
                  "op", yr(13, "k", ys("bad"), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                            "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys_cat(ys_cat(ys("bad rip-relative '"), t), ys("'")));
    } else {
        return yr(3, "ok", yv_bool(1),
                  "op", yr(13, "k", ys("mem"), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
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
                  "op", yr(13, "k", ys("bad"), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                            "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys_cat(ys_cat(ys("bad memory '"), t), ys("'")));
    } else if (yv_len(parts) > 3) {
        return yr(3, "ok", yv_bool(0),
                  "op", yr(13, "k", ys("bad"), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                            "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys_cat(ys_cat(ys("bad memory '"), t), ys("'")));
    } else {
        long bn = reg_num(ya_get(parts, 0));
        if (bn < 0) {
            return yr(3, "ok", yv_bool(0),
                      "op", yr(13, "k", ys("bad"), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
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
                  "op", yr(13, "k", ys("mem"), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(bn), "idx", yv_long(-1), "scale", yv_long(1),
                            "disp", yv_long(disp), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys(""));
    } else {
        long xn = reg_num(ya_get(parts, 1));
        if (xn < 0) {
            return yr(3, "ok", yv_bool(0),
                      "op", yr(13, "k", ys("bad"), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                                "a", ys(""), "b", ys(""), "name", ys(""),
                                "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                                "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys("")),
                      "error", ys_cat(ys_cat(ys("bad index register '"), t), ys("'")));
        } else if (xn == 4) {
            return yr(3, "ok", yv_bool(0),
                      "op", yr(13, "k", ys("bad"), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
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
                  "op", yr(13, "k", ys("mem"), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
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
                  "op", yr(13, "k", ys("bad"), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
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
                  "op", yr(13, "k", ys("mem"), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(bn), "idx", yv_long(xn), "scale", yv_long(1),
                            "disp", yv_long(disp), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys(""));
    } else if (v == 2) {
        return yr(3, "ok", yv_bool(1),
                  "op", yr(13, "k", ys("mem"), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(bn), "idx", yv_long(xn), "scale", yv_long(2),
                            "disp", yv_long(disp), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys(""));
    } else if (v == 4) {
        return yr(3, "ok", yv_bool(1),
                  "op", yr(13, "k", ys("mem"), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(bn), "idx", yv_long(xn), "scale", yv_long(4),
                            "disp", yv_long(disp), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys(""));
    } else if (v == 8) {
        return yr(3, "ok", yv_bool(1),
                  "op", yr(13, "k", ys("mem"), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(bn), "idx", yv_long(xn), "scale", yv_long(8),
                            "disp", yv_long(disp), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys(""));
    } else {
        return yr(3, "ok", yv_bool(0),
                  "op", yr(13, "k", ys("bad"), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
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
        Yv *c = ys_substr(s, i, 1);
        if (!ys_eq_lit(c, "\\")) {
            out = ya_push(out, yv_long(ys_ord(c)));
            i = i + 1;
        } else {
            Yv *e = ys_substr(s, i + 1, 1);
            if (ys_eq_lit(e, "n")) {
                out = ya_push(out, yv_long(10));
                i = i + 2;
            } else if (ys_eq_lit(e, "t")) {
                out = ya_push(out, yv_long(9));
                i = i + 2;
            } else if (ys_eq_lit(e, "r")) {
                out = ya_push(out, yv_long(13));
                i = i + 2;
            } else if (ys_eq_lit(e, "\\")) {
                out = ya_push(out, yv_long(92));
                i = i + 2;
            } else if (ys_eq_lit(e, "\"")) {
                out = ya_push(out, yv_long(34));
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
                err = ys_cat(ys_cat(ys("bad escape '\\"), e), ys("'"));
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
    Yv *e = ys_substr(s, k - 1, 1);
    long v = ys_ord(e) - 48;
    long kk = k;
    long nd = 1;
    while (nd < 3) {
        if (kk < n) {
            Yv *d = ys_substr(s, kk, 1);
            if (is_oct_ch(d)) {
                v = v * 8 + ys_ord(d) - 48;
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

static long hash_str(Yv *s) {
    long h = 0;
    long i = 0;
    while (i < yv_len(s)) {
        h = (h * 31 + ys_ord(ys_substr(s, i, 1))) % 1000000007;
        i = i + 1;
    }
    return h;
}

static Yv *labmap_new(long cap) {
    Yv *m = yav(0);
    long i = 0;
    while (i < cap) {
        m = ya_push(m, yr(3, "name", ys(""), "sec", yv_long(0), "off", yv_long(0)));
        i = i + 1;
    }
    return m;
}

static Yv *labmap_put(Yv *m, Yv *name, long sec, long off) {
    long cap = yv_len(m);
    long i = hash_str(name) % cap;
    int dup = 0;
    int done = 0;
    long n = 0;
    while (done == 0) {
        Yv *e = ya_get(m, i);
        if (ys_eq_lit(yr_get(e, "name"), "")) {
            ya_set(m, i, yr(3, "name", name, "sec", yv_long(sec), "off", yv_long(off)));
            done = 1;
            ;
        } else if (ys_eq(yr_get(e, "name"), name)) {
            dup = 1;
            done = 1;
            ;
        } else {
            i = i + 1;
            if (i >= cap) { i = 0; ; } else { ; };
            ;
        };
        n = n + 1;
        if (n > cap) { done = 1; ; } else { ; };
    };
    return yr(2, "map", m, "dup", yv_bool(dup));
}

static Yv *labmap_get(Yv *m, Yv *name) {
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
            if (i >= cap) { i = 0; ; } else { ; };
            ;
        };
        n = n + 1;
        if (n > cap) { done = 1; ; } else { ; };
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
        if (yv_b(yr_get(r, "dup"))) { dup = yr_get(e, "name"); ; } else { ; };
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

Yv *asm_assemble(Yv *text) {
    long t0 = clock_us();
    long h0 = heap_used();
    Yv *lines = ys_split(text, ys("\n"));
    long t1 = clock_us();
    long h1 = heap_used();
    Yv *items = yav(0);
    Yv *labels = yav(0);
    long sec = 0;
    Yv *offs = yav(2, yv_long(0), yv_long(0));
    long li = 0;
    Yv *err = ys("");
    /* NOTE: threaded STATE record (see note below): sec/offs/items/labels/err
       rebound across 6+ arms merge through the flow-insensitive env. Threading
       one {sec,offs,items,labels,err} value through per-line callees keeps a
       single key set everywhere.
       NOTE: nested ifs, not `&&` (see is_digit_ch note); `0;` tails. */
    while (li < yv_len(lines)) {
        if (!ys_eq_lit(err, "")) {
            li = yv_len(lines);
            ;
        } else {
            Yv *st = asm_assemble_line(lines, li, sec, offs, items, labels, err);
            sec = yv_l(yr_get(st, "sec"));
            offs = yr_get(st, "offs");
            items = yr_get(st, "items");
            labels = yr_get(st, "labels");
            err = yr_get(st, "err");
            ;
        };
        li = li + 1;
        ;
    };
    long t2 = clock_us();
    long h2 = heap_used();
    if (!ys_eq_lit(err, "")) {
        return yr(4, "ok", yv_bool(0), "bytes", yav(0), "error", err,
                  "times", yav(2,
                               yr(3, "name", ys("a:split"), "us", yv_long(t1 - t0), "heap", yv_long(h1 - h0)),
                               yr(3, "name", ys("a:encode"), "us", yv_long(t2 - t1), "heap", yv_long(h2 - h1))));
    } else {
        Yv *lk = asm_link(items, labels);
        long t3 = clock_us();
        long h3 = heap_used();
        Yv *tl = yav(3,
                     yr(3, "name", ys("a:split"), "us", yv_long(t1 - t0), "heap", yv_long(h1 - h0)),
                     yr(3, "name", ys("a:encode"), "us", yv_long(t2 - t1), "heap", yv_long(h2 - h1)),
                     yr(3, "name", ys("a:link"), "us", yv_long(t3 - t2), "heap", yv_long(h3 - h2)));
        Yv *lsub = yr_get(lk, "times");
        long k = 0;
        while (k < yv_len(lsub)) {
            Yv *le = ya_get(lsub, k);
            tl = ya_push(tl, le);
            k = k + 1;
        }
        return yr(4, "ok", yr_get(lk, "ok"), "bytes", yr_get(lk, "bytes"),
                  "error", yr_get(lk, "error"), "times", tl);
    }
}

/* Per-line state threading for asm_assemble (see note above): one STATE
   record {sec,offs,items,labels,err} threaded through per-class callees.
   Each callee reads ONLY its inputs and returns the full STATE — single key
   set everywhere, no merged-shape rebinds. */
static Yv *asm_assemble_line(Yv *lines, long li, long sec, Yv *offs, Yv *items, Yv *labels, Yv *err) {
    Yv *line = ys_trim(ya_get(lines, li));
    long lno = li + 1;
    if (ys_eq_lit(line, "")) {
        return asm_state(sec, offs, items, labels, err);
    } else if (ys_eq_lit(ys_substr(line, 0, 1), "#")) {
        return asm_state_err(sec, offs, items, labels, lno, ys("unexpected comment (backend bug)"));
    } else if (ys_eq_lit(ys_substr(line, yv_len(line) - 1, 1), ":")) {
        return asm_labdef(line, lno, sec, offs, items, labels, err);
    } else if (ys_eq_lit(ys_substr(line, 0, 1), ".")) {
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
    Yv *nm = ys_trim(ys_substr(line, 0, yv_len(line) - 1));
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
                     ya_push(labels, yr(3, "name", nm, "sec", yv_long(sec), "off", ya_get(offs, sec))), err);
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
    if (ci > 0) {
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
    Yv *nm = ys_trim(ys_substr(line, 0, ci));
    Yv *rest = ys_trim(ys_substr(line, ci + 1, yv_len(line) - ci - 1));
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
    Yv *r = asm_content(rest, lno, sec, offs);
    if (!ys_eq_lit(yr_get(r, "err"), "")) {
        return asm_state(yv_l(yr_get(r, "sec")), yr_get(r, "offs"), items, labels, yr_get(r, "err"));
    } else {
        return asm_state(yv_l(yr_get(r, "sec")), yr_get(r, "offs"),
                         ya_push(items, yr_get(r, "item")),
                         ya_push(labels, yr(3, "name", nm, "sec", yv_long(sec), "off", yv_long(lab_off))),
                         err);
    }
}

static Yv *asm_content(Yv *line, long lno, long sec, Yv *offs) {
    if (ys_eq_lit(ys_substr(line, 0, 1), ".")) {
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
        return asm_strdata_go(line, lno, sec, offs, ys_substr(rest, 1, yv_len(rest) - 2), nul);
    }
}

static int asm_strdata_bad(Yv *rest) {
    /* NOTE: nested ifs, not `||` (see is_digit_ch note). */
    if (yv_len(rest) < 2) { return 1; }
    else if (!ys_eq_lit(ys_substr(rest, 0, 1), "\"")) { return 1; }
    else if (!ys_eq_lit(ys_substr(rest, yv_len(rest) - 1, 1), "\"")) { return 1; }
    else { return 0; }
}

static Yv *asm_strdata_err(Yv *line, long lno, long sec, Yv *offs) {
    /* (split: error shape `{err,sec,offs,item:{}}` built ONLY here.) */
    (void)line;
    return yr(4,
              "err", ys_cat(ys_cat(ys("L"), ys_long(lno)), ys(": bad string literal")),
              "sec", yv_long(sec), "offs", offs,
              "item", yr(6, "sec", yv_long(-1), "off", yv_long(0), "len", yv_long(0),
                         "kind", ys(""), "bytes", yav(0), "fix", yav(0)));
}

static Yv *asm_strdata_go(Yv *line, long lno, long sec, Yv *offs, Yv *payload, int nul) {
    (void)line;
    Yv *d = decode_str(payload);
    if (!(yv_b(yr_get(d, "ok")))) {
        return yr(4,
                  "err", ys_cat(ys_cat(ys_cat(ys("L"), ys_long(lno)), ys(": ")), yr_get(d, "error")),
                  "sec", yv_long(sec), "offs", offs,
                  "item", yr(6, "sec", yv_long(-1), "off", yv_long(0), "len", yv_long(0),
                             "kind", ys(""), "bytes", yav(0), "fix", yav(0)));
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
    } else { ; };
    return asm_strdata_item(sec, offs, bb);
}

static Yv *asm_strdata_item(long sec, Yv *offs, Yv *bb) {
    Yv *item = yr(6, "sec", yv_long(sec), "off", ya_get(offs, sec), "len", yv_long(yv_len(bb)),
                  "kind", ys("data"), "bytes", bb, "fix", yav(0));
    ya_set(offs, sec, yv_long(yv_l(ya_get(offs, sec)) + yv_len(bb)));
    return yr(4, "err", ys(""), "sec", yv_long(sec), "offs", offs, "item", item);
}

static Yv *asm_directive(Yv *line, long lno, long sec, Yv *offs) {
    long sp = ys_index_of(line, ys(" "));
    Yv *dir = line;
    Yv *rest = ys("");
    /* NOTE: `0;` tails (see parser.y parse_binary note). */
    if (sp >= 0) {
        dir = ys_substr(line, 0, sp);
        rest = ys_trim(ys_substr(line, sp + 1, yv_len(line) - sp - 1));
        ;
    } else { ; };
    if (ys_eq_lit(dir, ".text")) {
        return yr(4, "err", ys(""), "sec", yv_long(0), "offs", offs,
                  "item", yr(6, "sec", yv_long(-1), "off", yv_long(0), "len", yv_long(0),
                             "kind", ys(""), "bytes", yav(0), "fix", yav(0)));
    } else if (ys_eq_lit(dir, ".globl")) {
        return yr(4, "err", ys(""), "sec", yv_long(sec), "offs", offs,
                  "item", yr(6, "sec", yv_long(-1), "off", yv_long(0), "len", yv_long(0),
                             "kind", ys(""), "bytes", yav(0), "fix", yav(0)));
    } else if (ys_eq_lit(dir, ".string")) {
        return asm_strdata(line, lno, sec, offs, rest, 1);
    } else if (ys_eq_lit(dir, ".ascii")) {
        return asm_strdata(line, lno, sec, offs, rest, 0);
    } else if (ys_eq_lit(dir, ".section")) {
        return asm_section(line, lno, sec, offs, rest);
    } else if (ys_eq_lit(dir, ".quad")) {
        return asm_quad(line, lno, sec, offs, rest);
    } else {
        return yr(4,
                  "err", ys_cat(ys_cat(ys_cat(ys_cat(ys("L"), ys_long(lno)), ys(": unsupported directive '")), dir), ys("'")),
                  "sec", yv_long(sec), "offs", offs,
                  "item", yr(6, "sec", yv_long(-1), "off", yv_long(0), "len", yv_long(0),
                             "kind", ys(""), "bytes", yav(0), "fix", yav(0)));
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
    else { return 1; }
}

static Yv *asm_section_err(Yv *line, long lno, long sec, Yv *offs, Yv *rest) {
    /* (split: error shape built ONLY here.) */
    (void)line;
    return yr(4,
              "err", ys_cat(ys_cat(ys_cat(ys_cat(ys("L"), ys_long(lno)), ys(": unsupported section '")), rest), ys("'")),
              "sec", yv_long(sec), "offs", offs,
              "item", yr(6, "sec", yv_long(-1), "off", yv_long(0), "len", yv_long(0),
                         "kind", ys(""), "bytes", yav(0), "fix", yav(0)));
}

static Yv *asm_section_go(long sec, Yv *offs, Yv *rest) {
    /* (split: marker shape `{err,sec,offs,item:{sec}}` built ONLY here.)
       NOTE: both arms share the key set — teq holds. */
    (void)sec;
    if (ys_eq_lit(rest, ".rodata")) {
        return yr(4, "err", ys(""), "sec", yv_long(1), "offs", offs,
                  "item", yr(6, "sec", yv_long(-1), "off", yv_long(0), "len", yv_long(0),
                             "kind", ys(""), "bytes", yav(0), "fix", yav(0)));
    } else {
        return yr(4, "err", ys(""), "sec", yv_long(0), "offs", offs,
                  "item", yr(6, "sec", yv_long(-1), "off", yv_long(0), "len", yv_long(0),
                             "kind", ys(""), "bytes", yav(0), "fix", yav(0)));
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
                  "item", yr(6, "sec", yv_long(-1), "off", yv_long(0), "len", yv_long(0),
                             "kind", ys(""), "bytes", yav(0), "fix", yav(0)));
    } else {
        return yr(4,
                  "err", ys_cat(ys_cat(ys("L"), ys_long(lno)), ys(": negative .quad value")),
                  "sec", yv_long(sec), "offs", offs,
                  "item", yr(6, "sec", yv_long(-1), "off", yv_long(0), "len", yv_long(0),
                             "kind", ys(""), "bytes", yav(0), "fix", yav(0)));
    }
}

static Yv *asm_quad_go(long sec, Yv *offs, Yv *rest) {
    /* (split: data-item shape built ONLY here.) */
    Yv *bytes = le64(ys_tonum(rest));
    Yv *item = yr(6, "sec", yv_long(sec), "off", ya_get(offs, sec), "len", yv_long(yv_len(bytes)),
                  "kind", ys("data"), "bytes", bytes, "fix", yav(0));
    ya_set(offs, sec, yv_long(yv_l(ya_get(offs, sec)) + yv_len(bytes)));
    return yr(4, "err", ys(""), "sec", yv_long(sec), "offs", offs, "item", item);
}

static Yv *asm_insn(Yv *line, long lno, long sec, Yv *offs) {
    long sp = ys_index_of(line, ys(" "));
    long tab = ys_index_of(line, ys("\t"));
    long cut = sp;
    /* NOTE: nested ifs, not `||` (see is_digit_ch note); `0;` tails. */
    if (tab >= 0) {
        if (sp < 0) { cut = tab; ; }
        else if (tab < sp) { cut = tab; ; }
        else { ; };
        ;
    } else { ; };
    Yv *mn = line;
    Yv *rest = ys("");
    if (cut >= 0) {
        mn = ys_substr(line, 0, cut);
        rest = ys_trim(ys_substr(line, cut + 1, yv_len(line) - cut - 1));
        ;
    } else { ; };
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
                      "item", yr(6, "sec", yv_long(-1), "off", yv_long(0), "len", yv_long(0),
                                 "kind", ys(""), "bytes", yav(0), "fix", yav(0)));
        } else {
            return asm_encode(mn, ops, lno, sec, offs);
        }
    } else {
        return asm_encode(mn, ops, lno, sec, offs);
    }
}

static Yv *asm_encode(Yv *mn, Yv *ops, long lno, long sec, Yv *offs) {
    Yv *r = enc_insn(mn, ops);
    if (!ys_eq_lit(yr_get(r, "err"), "")) {
        return yr(4,
                  "err", ys_cat(ys_cat(ys_cat(ys_cat(ys_cat(ys_cat(ys("L"), ys_long(lno)), ys(": ")), yr_get(r, "err")), ys(" in '")), mn), ys("'")),
                  "sec", yv_long(sec), "offs", offs,
                  "item", yr(6, "sec", yv_long(-1), "off", yv_long(0), "len", yv_long(0),
                             "kind", ys(""), "bytes", yav(0), "fix", yav(0)));
    } else {
        long blen = yv_len(yr_get(r, "bytes"));
        Yv *item = yr(6, "sec", yv_long(sec), "off", ya_get(offs, sec), "len", yv_long(blen),
                      "kind", ys("insn"), "bytes", yr_get(r, "bytes"), "fix", yr_get(r, "fix"));
        ya_set(offs, sec, yv_long(yv_l(ya_get(offs, sec)) + blen));
        return yr(4, "err", ys(""), "sec", yv_long(sec), "offs", offs, "item", item);
    }
}


/* ── pass 2: layout, fixups, ELF ──────────────────────────────────────── */

static Yv *asm_link(Yv *items, Yv *labels) {
    /* section sizes */
    long lt0 = clock_us();
    long lh0 = heap_used();
    long code_len = 0;
    /* NOTE: `0;` tails (see parser.y parse_binary note). `it.len` reads go
       through the bare hole (tnone unifies — see types.y typeof_def note).
       Only the code length is needed: elf_build takes the rodata bytes and
       sizes that segment itself. */
    long i = 0;
    while (i < yv_len(items)) {
        Yv *it = ya_get(items, i);
        if (yv_l(yr_get(it, "sec")) == 0) { code_len = code_len + yv_l(yr_get(it, "len")); ; } else { ; };
        i = i + 1;
        ;
    };
    Yv *lm = labmap_build(labels);
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
    } else {
        /* pad code to a page so rodata lands page-aligned (mirrors elf.y) */
        long pad = 0;
        long trail = code_len % 4096;
        if (trail != 0) { pad = 4096 - trail; ; } else { ; };
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
            } else { ; };
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
            Yv *eb = elf_build(code, ro, yv_l(yr_get(start, "off")));
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
        if (ys_eq_lit(yr_get(fx, "kind"), "rel32")) {
            Yv *rr = patch_item_rel(lmap, code_len, pad, fx, bytes, base, it, at);
            bytes = yr_get(rr, "bytes");
            if (!ys_eq_lit(yr_get(rr, "err"), "")) { err = yr_get(rr, "err"); ; } else { ; };
            ;
        } else {
            Yv *rk = patch_item_kind2(lmap, code_len, pad, fx, bytes, base, it, at);
            bytes = yr_get(rk, "bytes");
            if (!ys_eq_lit(yr_get(rk, "err"), "")) { err = yr_get(rk, "err"); ; } else { ; };
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
    return yr(2, "bytes", concat_bytes(code, bytes), "err", err);
}

static Yv *patch32(Yv *bytes, long at, long v) {
    Yv *b = le32(v);
    ya_set(bytes, at, ya_get(b, 0));
    ya_set(bytes, at + 1, ya_get(b, 1));
    ya_set(bytes, at + 2, ya_get(b, 2));
    ya_set(bytes, at + 3, ya_get(b, 3));
    return bytes;
}

/* asm.y writes `code + bytes` (array concat -> a NEW array). The push form
   grows `a` in place instead; that is unobservable here because the only
   caller (asm_link) rebinds its `code` to the result and drops the old
   array on the floor. */
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
Yv *ycc_assemble(Yv *asm_text) {
    Yv *r = asm_assemble(asm_text);
    if (!(yv_b(yr_get(r, "ok")))) {
        return yr(5, "ok", yv_bool(0), "bytes", yav(0), "octal", ys(""),
                  "error", yr_get(r, "error"), "times", yr_get(r, "times"));
    } else {
        return yr(5, "ok", yv_bool(1), "bytes", yr_get(r, "bytes"), "octal", ys(""),
                  "error", ys(""), "times", yr_get(r, "times"));
    }
}
