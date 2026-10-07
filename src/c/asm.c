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
#include "ylong.h"
#include "asm.h"
#include "tags.h"
#include "dwarf.h"
#include "pe.h"
#include "target.h"
#include "elf.h"
#include "kelf.h"
#include "ir.h"
#include "labels.h"
#include "enc64.h"

#include "host.h"
#include <unistd.h>

/* imported (module calls from asm.y, names flattened) */
extern ylong reg_num(Yv *name);              /* enc64.c: enc.reg_num */
extern ylong reg_size(Yv *name);             /* enc64.c: enc.reg_size */
extern Yv *enc_insn(Yv *buf, ylong at, Yv *mn, Yv *ops, int lng); /* enc64.c: enc.enc_insn */
extern Yv *enc_branch_long(Yv *buf, ylong at, ylong br, Yv *lbl); /* enc64.c: enc.enc_branch_long */
extern Yv *scratch(void);                    /* enc64.c: enc.scratch */
extern Yv *le64(ylong v);                    /* enc64.c: enc.le64 */
extern Yv *le32(ylong v);                    /* enc64.c: enc.le32 */
extern ylong elf_bss_from_ro(ylong code_len, ylong ro_len); /* elf.c: elf.elf_bss_from_ro */
extern ylong elf_code_off(ylong bss_len);      /* elf.c: elf.elf_code_off */
extern Yv *elf_build(Yv *code, Yv *rodata, ylong entry_off, ylong bss_len,
                     Yv *syms, Yv *dsecs); /* elf.c: elf.elf_build */
/* pe.c's exports (pe.y): pe_build, pe_text_base, pe_bss_from_ro, pe_sec. Both
   writers are linked in and the one used is chosen at link time; see
   asm_image's note. */
extern Yv *pe_build(Yv *code, Yv *rodata, ylong entry_off, ylong bss_len,
                    Yv *pdata, Yv *xdata, Yv *dsecs, Yv *ddata, Yv *symtab,
                    Yv *imp);
extern Yv *pe_imports(void);
extern ylong pe_text_base(void);
extern ylong pe_bss_from_ro(ylong code_len, ylong ro_len, ylong bss_len);
extern Yv *pe_sec(Yv *name, ylong vsz, ylong rva, ylong rawptr, ylong chars);
/* elf.c's byte pushers, the ones pe_unwind_bytes writes .pdata with. */
extern Yv *push_bytes(Yv *out, Yv *bytes);
extern Yv *push_le16(Yv *out, ylong v);
extern Yv *push_le32(Yv *out, ylong v);

/* ── module-local defs (forward) ─────────────────────────────────────── */
static int is_digit_ch(ylong c);
static int is_oct_ch(ylong c);
static int is_alpha_ch(ylong c);
static Yv *parse_num(Yv *s);
static Yv *parse_num_go(Yv *s, ylong i, int neg);
static int is_num_text(Yv *s);
static Yv *split_ops(Yv *s);
static Yv *parse_operand(Yv *t);
static Yv *parse_operand_empty(Yv *t);
static Yv *parse_operand_nonempty(Yv *t);
static Yv *parse_operand_ind(Yv *t);
static Yv *parse_operand_reg(Yv *t);
static Yv *parse_operand_fs(Yv *t);
static Yv *parse_operand_seg(Yv *t, ylong seg);
static Yv *parse_operand_noreg(Yv *t);
static Yv *parse_operand_imm(Yv *t);
static Yv *parse_operand_memlbl(Yv *t);
static Yv *parse_imm(Yv *s);
static Yv *parse_imm_alpha(Yv *s, ylong dash);
static Yv *parse_imm_diff(Yv *s, ylong dash);
static Yv *parse_imm_num(Yv *s);
static Yv *parse_mem(Yv *t);
static Yv *parse_mem_head(Yv *t, Yv *head, Yv *parts);
static Yv *parse_mem_rip(Yv *t, Yv *head, Yv *parts);
static Yv *parse_mem_ripoff(Yv *t, Yv *head, Yv *off, Yv *parts);
static Yv *parse_mem_ripdisp(Yv *t, Yv *lbl, ylong disp, Yv *parts);
static Yv *parse_mem_disp(Yv *t, Yv *head, Yv *parts);
static Yv *parse_mem_regs(Yv *t, Yv *parts, ylong disp);
static Yv *mem_rest(Yv *t, Yv *parts, ylong disp, ylong bn);
static Yv *mem_scale(Yv *t, Yv *parts, ylong disp, ylong bn, ylong xn);
static Yv *mem_scaleThree(Yv *t, Yv *parts, ylong disp, ylong bn, ylong xn);
static Yv *mem_scaleVal(Yv *t, ylong v, ylong disp, ylong bn, ylong xn);
static Yv *decode_str(Yv *s);
static Yv *decode_oct(Yv *s, ylong k, ylong n);
ylong hash_str(Yv *s);
Yv *labmap_new(ylong cap);
Yv *labmap_put(Yv *m, Yv *name, ylong sec, ylong off);
Yv *labmap_get(Yv *m, Yv *name);
static Yv *labmap_build(Yv *labels);
static Yv *label_addr(Yv *lmap, ylong code_len, ylong pad, Yv *name);
static Yv *label_addr_off(Yv *lmap, ylong code_len, ylong pad, Yv *name, ylong plus);
static Yv *asm_assemble_line(Yv *lines, ylong li, ylong lbase, ylong sec, Yv *offs, Yv *items, Yv *labels, Yv *err);
static Yv *ir_enc_item(Yv *ir, ylong at, ylong sec, Yv *offs, Yv *where);
static Yv *asm_ir_st(ylong sec, Yv *offs, Yv *items, Yv *labels, Yv *err, ylong lno);
static Yv *asm_st_seg(Yv *st, Yv *lines, ylong li);
static Yv *asm_ir_loc(ylong file, ylong line, ylong sec, Yv *offs, ylong fno);
static Yv *asm_ir_items(Yv *ir, Yv *txt, ylong fno, int loc, ylong sec, Yv *offs, Yv *items, Yv *labels, Yv *err, ylong lno);
static Yv *ir_operand(Yv *ir, ylong wp, ylong k);
static Yv *asm_state(ylong sec, Yv *offs, Yv *items, Yv *labels, Yv *err);
static Yv *asm_state_err(ylong sec, Yv *offs, Yv *items, Yv *labels, ylong lno, Yv *msg);
static Yv *asm_labdef(Yv *line, ylong lno, ylong sec, Yv *offs, Yv *items, Yv *labels, Yv *err);
static Yv *asm_labdef_go(Yv *nm, ylong lno, ylong sec, Yv *offs, Yv *items, Yv *labels, Yv *err);
static Yv *asm_dirline(Yv *line, ylong lno, ylong sec, Yv *offs, Yv *items, Yv *labels, Yv *err);
static Yv *asm_maybe_labline(Yv *line, ylong lno, ylong sec, Yv *offs, Yv *items, Yv *labels, Yv *err);
static Yv *asm_insnline(Yv *line, ylong lno, ylong sec, Yv *offs, Yv *items, Yv *labels, Yv *err);
static Yv *asm_labline(Yv *line, ylong lno, ylong sec, Yv *offs, Yv *items, Yv *labels, Yv *err, ylong ci);
static Yv *asm_labline_go(Yv *nm, Yv *rest, ylong lno, ylong sec, Yv *offs, Yv *items, Yv *labels, Yv *err);
static Yv *asm_labline_content(Yv *nm, Yv *rest, ylong lno, ylong sec, Yv *offs, Yv *items, Yv *labels, Yv *err);
static Yv *asm_content(Yv *line, ylong lno, ylong sec, Yv *offs);
static Yv *asm_strdata(Yv *line, ylong lno, ylong sec, Yv *offs, Yv *rest, int nul);
static int asm_strdata_bad(Yv *rest);
static Yv *asm_strdata_err(Yv *line, ylong lno, ylong sec, Yv *offs);
static Yv *asm_strdata_go(Yv *line, ylong lno, ylong sec, Yv *offs, Yv *payload, int nul);
static Yv *asm_strdata_emit(ylong sec, Yv *offs, Yv *bytes, int nul);
static Yv *asm_strdata_item(ylong sec, Yv *offs, Yv *bb);
static Yv *asm_directive(Yv *line, ylong lno, ylong sec, Yv *offs);
static Yv *asm_loc(ylong lno, ylong sec, Yv *offs, Yv *rest);
static Yv *asm_file(ylong lno, ylong sec, Yv *offs, Yv *rest);
static Yv *asm_section(Yv *line, ylong lno, ylong sec, Yv *offs, Yv *rest);
static int asm_section_bad(Yv *rest);
static Yv *asm_section_err(Yv *line, ylong lno, ylong sec, Yv *offs, Yv *rest);
static Yv *asm_section_go(ylong sec, Yv *offs, Yv *rest);
static Yv *asm_quad(Yv *line, ylong lno, ylong sec, Yv *offs, Yv *rest);
static int asm_quad_bad(Yv *rest);
static Yv *asm_quad_err(Yv *line, ylong lno, ylong sec, Yv *offs, Yv *rest);
static Yv *asm_quad_go(ylong sec, Yv *offs, Yv *rest);
static Yv *asm_zero(Yv *line, ylong lno, ylong sec, Yv *offs, Yv *rest);
static Yv *asm_align(Yv *line, ylong lno, ylong sec, Yv *offs, Yv *rest);
static Yv *asm_insn(Yv *line, ylong lno, ylong sec, Yv *offs);
static Yv *asm_encode(Yv *mn, Yv *ops, ylong lno, ylong sec, Yv *offs);
static Yv *asm_link(Yv *items, Yv *labels, int debug);
static Yv *patch_item(Yv *code, Yv *it, Yv *lmap, ylong code_len, ylong pad);
static Yv *patch_item_loop(Yv *code, Yv *it, Yv *lmap, ylong code_len, ylong pad, Yv *bytes, Yv *err);
static Yv *patch_item_kind2(Yv *lmap, ylong code_len, ylong pad, Yv *fx, Yv *bytes, ylong base, Yv *it, ylong at);
static Yv *patch_item_rel(Yv *lmap, ylong code_len, ylong pad, Yv *fx, Yv *bytes, ylong base, Yv *it, ylong at);
static Yv *patch_item_diff(Yv *lmap, ylong code_len, ylong pad, Yv *fx, Yv *bytes, ylong base, Yv *it);
static Yv *patch_item_diff2(Yv *lmap, ylong code_len, ylong pad, Yv *fx, Yv *bytes, ylong ta);
static Yv *patch_item_finish(Yv *code, Yv *bytes, Yv *err);
static Yv *patch32(Yv *bytes, ylong at, ylong v);
static Yv *patch8(Yv *bytes, ylong at, ylong v);
static Yv *patch_item_rel8(Yv *lmap, ylong code_len, ylong pad, Yv *fx, Yv *bytes, ylong base, Yv *it, ylong at);
static ylong asm_relax(Yv *items, Yv *labels, int debug);
static Yv *relax_map(Yv *labels);
static int relax_round(Yv *items, Yv *labels, Yv *rlmap, Yv *lens, Yv *secs, Yv *brs, Yv *cum, int first);
static ylong relax_target(Yv *rlmap, Yv *lbl);
static ylong relax_grow(Yv *items, ylong i, Yv *lens, Yv *lbl);
static ylong relax_all_long(Yv *items, Yv *labels, Yv *lens);
static ylong relax_place(Yv *items, Yv *labels, Yv *lens, Yv *secs, int debug);
static Yv *debug_syms(Yv *labels, ylong code_len, ylong bss_len);
static Yv *debug_syms_sec(Yv *out, Yv *labels, ylong sec, ylong end);
static int is_sym_label(Yv *name, ylong sec);
static ylong asm_image_base(ylong bss_len);
static ylong asm_bss_shift(ylong code_len, ylong ro_len, ylong bss_len);
static Yv *asm_link_row(void);
static Yv *asm_image(Yv *code, Yv *ro, ylong entry_off, ylong bss_len, Yv *syms,
                     Yv *dsecs, Yv *items, Yv *labels);
static Yv *pe_image(Yv *code, Yv *ro, ylong entry_off, ylong bss_len, Yv *syms,
                    Yv *dsecs, Yv *items, Yv *labels);
static Yv *pe_unwind(Yv *items, Yv *labels);
static Yv *pe_coff_syms(Yv *syms);
static Yv *pe_unwind_bytes(Yv *frames, ylong xbase);
static Yv *pe_frames(Yv *items, Yv *labels);
static Yv *pe_frame_prologues(Yv *items, Yv *frames);
static Yv *pe_prologue(Yv *items, Yv *f, ylong stop, ylong last);
static Yv *pe_prologue_insn(Yv *it, ylong off, int fp, ylong fp_off, ylong alloc,
                            ylong alloc_off, Yv *pushes, ylong prolog);
static Yv *pe_prologue_push(ylong reg, ylong done, int fp, ylong fp_off, ylong alloc,
                            ylong alloc_off, Yv *pushes, ylong prolog);
static int pe_nonvol(ylong reg);
static Yv *pe_codes(Yv *f);
static Yv *pe_alloc(ylong size, ylong off);
static Yv *concat_arrays(Yv *a, Yv *b);
static Yv *pe_codes_sorted(Yv *g, ylong i);
static Yv *pe_unwind_info(Yv *xdata, Yv *f);
static ylong pe_coff_secnum(ylong sec);
static Yv *pe_coff_sym(Yv *out, Yv *nm, ylong val, ylong secnum);
static Yv *sym_name(Yv *lbl);
static Yv *after_uid(Yv *s, ylong k);
static Yv *debug_lines(Yv *items, ylong code_len, ylong code_off);
static Yv *asm_cwd(void);
static Yv *concat_bytes(Yv *a, Yv *b);

static int is_digit_ch(ylong c) {
    /* 1:1 of asm.y's `c >= c'0' && c <= c'9'`. The character is a byte, so
       this is an integer range test; the string form it replaces compared a
       1-char slice with ys_cmp. */
    return c >= '0' && c <= '9';
}

static int is_oct_ch(ylong c) {
    /* 1:1 of asm.y's `c >= c'0' && c <= c'7'` (same integer range test). */
    return c >= '0' && c <= '7';
}

static int is_alpha_ch(ylong c) {
    /* 1:1 of asm.y's `c == c'_' || (c >= c'A' && c <= c'Z') ||
       (c >= c'a' && c <= c'z')`. */
    return c == '_' ||
           (c >= 'A' && c <= 'Z') ||
           (c >= 'a' && c <= 'z');
}

/* parse a decimal integer (optional leading -). Returns {ok, v}. */
static Yv *parse_num(Yv *s) {
    int neg = 0;
    ylong i = 0;
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

static Yv *parse_num_go(Yv *s, ylong i, int neg) {
    /* (split: non-empty remainder narrows; `{ok,v}` built ONLY here.)
       NOTE: `0;` tails (see parser.y parse_binary note).
       Y's long arithmetic wraps (NATIVE.md), and the numbers that get
       here need it: an out-of-range literal in a program reaches the
       assembler as written, and so does LONG_MIN's magnitude. In C that
       is unsigned arithmetic — the same bits, without the undefined
       behavior of signed overflow. */
    ylong v = 0;
    int ok = 1;
    while (i < yv_len(s)) {
        ylong c = ys_byte_at(s, i);
        if (is_digit_ch(c)) {
            v = (ylong)((unsigned long long)v * 10 + (unsigned long long)c - '0');
            ;
        } else {
            ok = 0;
            ;
        };
        i = i + 1;
        ;
    };
    if (neg) { v = (ylong)(0 - (unsigned long long)v); ; }
    return yr(2, "ok", yv_bool(ok), "v", yv_long(v));
}

static int is_num_text(Yv *s) {
    Yv *r = parse_num(s);
    return yv_b(yr_get(r, "ok"));
}

/* Split operands on top-level commas (ignore commas inside parens). */
static Yv *split_ops(Yv *s) {
    Yv *out = yav(0);
    ylong depth = 0;
    /* One slice per FIELD, not one per character. The loop used to take
     * s[i:i + 1] and append it, so every byte of every operand allocated a
     * throwaway 1-byte string -- ycc's single largest allocation site, at
     * ~10% of all heap. Tracking where the field starts slices each field
     * once instead, with the same bytes in the same order. */
    ylong start = 0;
    ylong i = 0;
    ylong n = yv_len(s);
    /* NOTE: nested ifs, not `&&` (see is_digit_ch note); `0;` tails. */
    while (i < n) {
        ylong b = ys_byte_at(s, i);
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
    ylong n = reg_num(r);
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

/* `%fs:N` and `%gs:N`: the segment-relative word at N. `%fs:24` is a thread's
 * heap block (its own address, in word 3; arch_x64.c); `%gs:0x60` is the PEB
 * on x64 Windows, which is where the standard I/O handles live. The segment
 * rides in `n` (0 = %fs, 1 = %gs) because the operand has no other use for
 * it -- enc64.c turns that into the 0x64/0x65 prefix byte. Tried only once no
 * register matches.
 *
 * DECIMAL, and that is deliberate rather than an omission: parse_num is the
 * assembler's decimal reader, so `%gs:0x60` -- the natural spelling -- is a
 * "bad segment operand" whose diagnostic names the instruction rather than the
 * literal. src/y/arch/wsys.s writes 96/32/40 for the same reason. */
static Yv *parse_operand_fs(Yv *t) {
    return parse_operand_seg(t, 0);
}

static Yv *parse_operand_seg(Yv *t, ylong seg) {
    Yv *r = parse_num(ys_slice_from(t, 4));
    if (!yv_b(yr_get(r, "ok"))) {
        return yr(3, "ok", yv_bool(0),
                  "op", yr(13, "k", yv_long(K_bad), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                            "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys_cat(ys_cat(ys("bad segment operand '"), t), ys("'")));
    } else {
        return yr(3, "ok", yv_bool(1),
                  "op", yr(13, "k", yv_long(K_fs), "n", yv_long(seg), "size", yv_long(64), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                            "disp", yr_get(r, "v"), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys(""));
    }
}

static Yv *parse_operand_reg(Yv *t) {
    /* (split: %-gate above narrows; this body sees registers, and
     * `%fs:N`, which no register name matches.) */
    ylong n = reg_num(t);
    if (n < 0) {
        if (ys_eq_lit(ys_slice(t, 0, 4), "%fs:")) {
            return parse_operand_fs(t);
        } else if (ys_eq_lit(ys_slice(t, 0, 4), "%gs:")) {
            return parse_operand_seg(t, 1);
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
    ylong dash = ys_index_of(ys_slice_from(s, 1), ys("-"));
    if (yv_len(s) > 0) {
        return parse_imm_alpha(s, dash);
    } else {
        return parse_imm_num(s);
    }
}

static Yv *parse_imm_alpha(Yv *s, ylong dash) {
    /* (split: len>0 narrows; this body checks the alpha gate only.) */
    if (is_alpha_ch(ys_byte_at(s, 0))) {
        return parse_imm_diff(s, dash);
    } else {
        return parse_imm_num(s);
    }
}

static Yv *parse_imm_diff(Yv *s, ylong dash) {
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
    ylong open = ys_index_of(t, ys("("));
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
    /* (split: non-empty head narrows; a numeric displacement, a rip-relative
       label, or a label with a byte offset into a table.) */
    if (is_num_text(head)) {
        return parse_mem_disp(t, head, parts);
    } else {
        ylong plus = ys_index_of(head, ys("+"));
        if (plus < 0) {
            return parse_mem_rip(t, head, parts);
        } else {
            return parse_mem_ripoff(t, head,
                                    ys_trim(ys_slice(head, plus + 1, yv_len(head))), parts);
        }
    }
}

/* label+N(%rip): the N-th entry of a table. This is not a nicety -- a
   transcendental's kernel is twelve `mulsd c7(%rip)`-shaped reads of one
   coefficient table, and a label per coefficient costs the shaker ~2K
   instructions of label-map fixpoint each, forever, on every compile.

   The offset stays part of the LABEL (`tab+8` reaches label_addr whole), so the
   fixup needs no field of its own -- see the note on Fixup in enc64.c. */
static Yv *parse_mem_ripoff(Yv *t, Yv *head, Yv *off, Yv *parts) {
    if (!is_num_text(off)) {
        return yr(3, "ok", yv_bool(0),
                  "op", yr(13, "k", yv_long(K_bad), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(0), "idx", yv_long(0), "scale", yv_long(0),
                            "disp", yv_long(0), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys_cat(ys_cat(ys_cat(ys("bad table offset '"), off), ys("'")), ys("")));
    } else {
        return parse_mem_ripdisp(t, head, 0, parts);
    }
}

static Yv *parse_mem_rip(Yv *t, Yv *head, Yv *parts) {
    return parse_mem_ripdisp(t, head, 0, parts);
}

static Yv *parse_mem_ripdisp(Yv *t, Yv *lbl, ylong disp, Yv *parts) {
    /* label(%rip), with disp the byte offset into the table -- mem-shape built
       ONLY here.
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
                            "disp", yv_long(disp), "rip", yv_bool(1), "lbl", lbl),
                  "error", ys(""));
    }
}

static Yv *parse_mem_disp(Yv *t, Yv *head, Yv *parts) {
    /* numeric displacement head: parse_num cannot fail (is_num_text held). */
    Yv *r = parse_num(head);
    return parse_mem_regs(t, parts, yv_l(yr_get(r, "v")));
}

static Yv *parse_mem_regs(Yv *t, Yv *parts, ylong disp) {
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
        ylong bn = reg_num(ya_get(parts, 0));
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

static Yv *mem_rest(Yv *t, Yv *parts, ylong disp, ylong bn) {
    if (yv_len(parts) == 1) {
        return yr(3, "ok", yv_bool(1),
                  "op", yr(13, "k", yv_long(K_mem), "n", yv_long(0), "size", yv_long(0), "v", yv_long(0),
                            "a", ys(""), "b", ys(""), "name", ys(""),
                            "base", yv_long(bn), "idx", yv_long(-1), "scale", yv_long(1),
                            "disp", yv_long(disp), "rip", yv_bool(0), "lbl", ys("")),
                  "error", ys(""));
    } else {
        ylong xn = reg_num(ya_get(parts, 1));
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

static Yv *mem_scale(Yv *t, Yv *parts, ylong disp, ylong bn, ylong xn) {
    /* NOTE: nested ifs, not `||`/`&&` (see is_digit_ch note). */
    ylong scale = 1;
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

static Yv *mem_scaleThree(Yv *t, Yv *parts, ylong disp, ylong bn, ylong xn) {
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

static Yv *mem_scaleVal(Yv *t, ylong v, ylong disp, ylong bn, ylong xn) {
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
    ylong i = 0;
    ylong n = yv_len(s);
    Yv *err = ys("");
    while (i < n) {
        ylong c = ys_byte_at(s, i);
        if (c != '\\') {
            out = ya_push(out, yv_long(c));
            i = i + 1;
        } else if (i + 1 >= n) {
            /* a backslash as the last byte: no escape follows it */
            err = ys("bad escape '\\'");
            i = n;
        } else {
            ylong e = ys_byte_at(s, i + 1);
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

static Yv *decode_oct(Yv *s, ylong k, ylong n) {
    /* Octal escape starting after the backslash (e is already known-octal).
       Returns {v, k (pos after digits), err}. Split from decode_str: the
       `{ok,bytes,error}` shape is built ONLY in decode_str.
       NOTE: `0;` tails (see parser.y parse_binary note). */
    ylong e = ys_byte_at(s, k - 1);
    ylong v = e - '0';
    ylong kk = k;
    ylong nd = 1;
    while (nd < 3) {
        if (kk < n) {
            ylong d = ys_byte_at(s, kk);
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

ylong hash_str(Yv *s) {
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
    ylong h = 0;
    ylong i = 0;
    ylong n = yv_len(s);
    while (i < n) {
        h = (h * 31 + ys_byte_at(s, i)) & 4294967295L;
        i = i + 1;
    }
    return h ^ (h >> 13);
}

Yv *labmap_new(ylong cap) {
    Yv *m = yav(0);
    ylong i = 0;
    while (i < cap) {
        m = ya_push(m, yr(4, "name", ys(""), "sec", yv_long(0), "off", yv_long(0), "at_item", yv_long(0)));
        i = i + 1;
    }
    return m;
}

Yv *labmap_put(Yv *m, Yv *name, ylong sec, ylong off) {
    ylong cap = yv_len(m);
    ylong i = hash_str(name) % cap;
    int dup = 0;
    int done = 0;
    ylong n = 0;
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
    ylong cap = yv_len(m);
    ylong i = hash_str(name) % cap;
    ylong found_sec = -1;
    ylong found_off = 0;
    int done = 0;
    ylong n = 0;
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
    ylong cap = yv_len(labels) * 2 + 16;
    Yv *m = labmap_new(cap);
    Yv *dup = ys("");
    ylong i = 0;
    while (i < yv_len(labels)) {
        Yv *e = ya_get(labels, i);
        Yv *r = labmap_put(m, yr_get(e, "name"), yv_l(yr_get(e, "sec")), yv_l(yr_get(e, "off")));
        m = yr_get(r, "map");
        if (yv_b(yr_get(r, "dup"))) { dup = yr_get(e, "name"); ; }
        i = i + 1;
    }
    return yr(2, "map", m, "dup", dup);
}

static Yv *label_addr(Yv *lmap, ylong code_len, ylong pad, Yv *name) {
    Yv *e = labmap_get(lmap, name);
    if (yv_l(yr_get(e, "sec")) < 0) {
        /* `tab+8`: the eighth byte of a table, which is how one label serves a
           whole coefficient table. Only on a miss, so the cost is nothing on
           every jump and every ordinary rip reference. */
        ylong plus = ys_index_of(name, ys("+"));
        if (plus > 0) {
            return label_addr_off(lmap, code_len, pad, name, plus);
        } else {
            return yr(2, "ok", yv_bool(0), "addr", yv_long(0));
        }
    } else if (yv_l(yr_get(e, "sec")) == 0) {
        return yr(2, "ok", yv_bool(1), "addr", yr_get(e, "off"));
    } else {
        return yr(2, "ok", yv_bool(1), "addr", yv_long(code_len + pad + yv_l(yr_get(e, "off"))));
    }
}

/* The `name+off` half of label_addr. It re-reads `name` rather than taking the
   two halves, so the lookup key is the same string the label map holds. */
static Yv *label_addr_off(Yv *lmap, ylong code_len, ylong pad, Yv *name, ylong plus) {
    Yv *off = ys_trim(ys_slice_from(name, plus + 1));
    if (!is_num_text(off)) {
        return yr(2, "ok", yv_bool(0), "addr", yv_long(0));
    } else {
        Yv *e = labmap_get(lmap, ys_slice(name, 0, plus));
        if (yv_l(yr_get(e, "sec")) < 0) {
            return yr(2, "ok", yv_bool(0), "addr", yv_long(0));
        } else if (yv_l(yr_get(e, "sec")) == 0) {
            return yr(2, "ok", yv_bool(1), "addr",
                      yv_long(yv_l(yr_get(e, "off")) + ys_tolong(off)));
        } else {
            return yr(2, "ok", yv_bool(1), "addr",
                      yv_long(code_len + pad + yv_l(yr_get(e, "off")) + ys_tolong(off)));
        }
    }
}

/* ── pass 1: parse lines into items ───────────────────────────────────── */

Yv *asm_assemble(Yv *parts, int debug) {
    ylong t0 = clock_us();
    ylong h0 = heap_used();
    /* The text parts' lines, up front: the split is its own phase (a:split),
       as it was when the whole assembly was one string. */
    Yv *segs = yav(0);
    ylong pi = 0;
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
    ylong t1 = clock_us();
    ylong h1 = heap_used();
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
                ylong li = 0;
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
    ylong tr0 = clock_us();
    ylong hr0 = heap_used();
    if (!ys_eq_lit(err, "")) {
        return yr(5, "ok", yv_bool(0), "bytes", yav(0), "error", err,
                  "items", yv_long(0),
                  "times", yav(2,
                               yr(3, "name", ys("a:split"), "us", yv_long(t1 - t0), "heap", yv_long(h1 - h0)),
                               yr(3, "name", ys("a:encode"), "us", yv_long(tr0 - t1), "heap", yv_long(hr0 - h1))));
    } else {
        asm_relax(items, labels, debug);
        ylong tr1 = clock_us();
        ylong hr1 = heap_used();
        Yv *lk = asm_link(items, labels, debug);
        ylong t3 = clock_us();
        ylong h3 = heap_used();
        Yv *tl = yav(4,
                     yr(3, "name", ys("a:split"), "us", yv_long(t1 - t0), "heap", yv_long(h1 - h0)),
                     yr(3, "name", ys("a:encode"), "us", yv_long(tr0 - t1), "heap", yv_long(hr0 - h1)),
                     yr(3, "name", ys("a:relax"), "us", yv_long(tr1 - tr0), "heap", yv_long(hr1 - hr0)),
                     yr(3, "name", ys("a:link"), "us", yv_long(t3 - tr1), "heap", yv_long(h3 - hr1)));
        Yv *lsub = yr_get(lk, "times");
        ylong k = 0;
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
static Yv *asm_assemble_line(Yv *lines, ylong li, ylong lbase, ylong sec, Yv *offs, Yv *items, Yv *labels, Yv *err) {
    Yv *line = ys_trim(ya_get(lines, li));
    ylong lno = lbase + li + 1;
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

static Yv *asm_state(ylong sec, Yv *offs, Yv *items, Yv *labels, Yv *err) {
    return yr(5, "sec", yv_long(sec), "offs", offs, "items", items, "labels", labels, "err", err);
}

static Yv *asm_state_err(ylong sec, Yv *offs, Yv *items, Yv *labels, ylong lno, Yv *msg) {
    return yr(5, "sec", yv_long(sec), "offs", offs, "items", items, "labels", labels,
              "err", ys_cat(ys_cat(ys_cat(ys("L"), ys_long(lno)), ys(": ")), msg));
}

static Yv *asm_labdef(Yv *line, ylong lno, ylong sec, Yv *offs, Yv *items, Yv *labels, Yv *err) {
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

static Yv *asm_labdef_go(Yv *nm, ylong lno, ylong sec, Yv *offs, Yv *items, Yv *labels, Yv *err) {
    /* NOTE: no definition-site duplicate scan (was O(L^2)): duplicates are
       detected once at index build (labmap_build reports the name). */
    (void)lno; /* carried only for the asm_* line-handler shape */
    return asm_state(sec, offs, items,
                     ya_push(labels, yr(4, "name", nm, "sec", yv_long(sec), "off", ya_get(offs, sec),
                                        "at_item", yv_long(yv_len(items)))), err);
}

static Yv *asm_dirline(Yv *line, ylong lno, ylong sec, Yv *offs, Yv *items, Yv *labels, Yv *err) {
    Yv *r = asm_directive(line, lno, sec, offs);
    if (!ys_eq_lit(yr_get(r, "err"), "")) {
        return asm_state(yv_l(yr_get(r, "sec")), yr_get(r, "offs"), items, labels, yr_get(r, "err"));
    } else {
        return asm_state(yv_l(yr_get(r, "sec")), yr_get(r, "offs"),
                         ya_push(items, yr_get(r, "item")), labels, err);
    }
}

static Yv *asm_maybe_labline(Yv *line, ylong lno, ylong sec, Yv *offs, Yv *items, Yv *labels, Yv *err) {
    /* maybe `label: rest` (rodata emits `ystr_N: .string ...`); otherwise a
       plain instruction. NOTE: misnomer fixed: the else-arm assembles an
       INSTRUCTION (asm_insnline), not a directive. */
    ylong ci = ys_index_of(line, ys(":"));
    /* a `%` before it: an operand's `%fs:N` / `%gs:N`, not a label */
    if (ci > 0 && ys_index_of(ys_slice(line, 0, ci), ys("%")) < 0) {
        return asm_labline(line, lno, sec, offs, items, labels, err, ci);
    } else {
        return asm_insnline(line, lno, sec, offs, items, labels, err);
    }
}

static Yv *asm_insnline(Yv *line, ylong lno, ylong sec, Yv *offs, Yv *items, Yv *labels, Yv *err) {
    Yv *r = asm_content(line, lno, sec, offs);
    if (!ys_eq_lit(yr_get(r, "err"), "")) {
        return asm_state(yv_l(yr_get(r, "sec")), yr_get(r, "offs"), items, labels, yr_get(r, "err"));
    } else {
        return asm_state(yv_l(yr_get(r, "sec")), yr_get(r, "offs"),
                         ya_push(items, yr_get(r, "item")), labels, err);
    }
}

static Yv *asm_labline(Yv *line, ylong lno, ylong sec, Yv *offs, Yv *items, Yv *labels, Yv *err, ylong ci) {
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

static Yv *asm_labline_go(Yv *nm, Yv *rest, ylong lno, ylong sec, Yv *offs, Yv *items, Yv *labels, Yv *err) {
    /* NOTE: no definition-site duplicate scan (see asm_labdef_go note). */
    return asm_labline_content(nm, rest, lno, sec, offs, items, labels, err);
}

static Yv *asm_labline_content(Yv *nm, Yv *rest, ylong lno, ylong sec, Yv *offs, Yv *items, Yv *labels, Yv *err) {
    /* The item builder does `offs[sec] = offs[sec] + len` IN PLACE, and
       arrays are REFERENCE values in both toolchains (yv.c's ya_push/
       ya_set mutate the shared array), so offs[sec] read AFTER
       asm_content is the POST-item offset: the label would land on its own
       item's bytes (ystr_nl -> 't' of "true"). Bind the pre-item offset
       FIRST. */
    ylong lab_off = yv_l(ya_get(offs, sec));
    ylong lab_at = yv_len(items);
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

static Yv *asm_content(Yv *line, ylong lno, ylong sec, Yv *offs) {
    if (ys_eq_lit(ys_slice(line, 0, 1), ".")) {
        return asm_directive(line, lno, sec, offs);
    } else {
        return asm_insn(line, lno, sec, offs);
    }
}

static Yv *asm_strdata(Yv *line, ylong lno, ylong sec, Yv *offs, Yv *rest, int nul) {
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

static Yv *asm_strdata_err(Yv *line, ylong lno, ylong sec, Yv *offs) {
    /* (split: error shape `{err,sec,offs,item:{}}` built ONLY here.) */
    (void)line;
    return yr(4,
              "err", ys_cat(ys_cat(ys("L"), ys_long(lno)), ys(": bad string literal")),
              "sec", yv_long(sec), "offs", offs,
              "item", yr(7, "sec", yv_long(-1), "off", yv_long(0), "len", yv_long(0),
                         "kind", ys(""), "bytes", yav(0), "fix", yav(0), "br", yv_long(-1)));
}

static Yv *asm_strdata_go(Yv *line, ylong lno, ylong sec, Yv *offs, Yv *payload, int nul) {
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

static Yv *asm_strdata_emit(ylong sec, Yv *offs, Yv *bytes, int nul) {
    /* NOTE: `0;` tails (see parser.y parse_binary note). */
    Yv *bb = bytes;
    if (nul) {
        bb = ya_push(bb, yv_long(0));
        ;
    }
    return asm_strdata_item(sec, offs, bb);
}

static Yv *asm_strdata_item(ylong sec, Yv *offs, Yv *bb) {
    Yv *item = yr(7, "sec", yv_long(sec), "off", ya_get(offs, sec), "len", yv_long(yv_len(bb)),
                  "kind", ys("data"), "bytes", bb, "fix", yav(0), "br", yv_long(-1));
    ya_set(offs, sec, yv_long(yv_l(ya_get(offs, sec)) + yv_len(bb)));
    return yr(4, "err", ys(""), "sec", yv_long(sec), "offs", offs, "item", item);
}

static Yv *asm_directive(Yv *line, ylong lno, ylong sec, Yv *offs) {
    ylong sp = ys_index_of(line, ys(" "));
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
    } else if (ys_eq_lit(dir, ".align")) {
        return asm_align(line, lno, sec, offs, rest);
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
static Yv *asm_loc(ylong lno, ylong sec, Yv *offs, Yv *rest) {
    ylong sp = ys_index_of(rest, ys(" "));
    Yv *fs = rest;
    Yv *ls = ys("");
    if (sp > 0) {
        fs = ys_slice(rest, 0, sp);
        ls = ys_trim(ys_slice_from(rest, sp + 1));
        ;
    }
    if (!is_num_text(fs) || !is_num_text(ls) ||
        ys_tolong(fs) < 1 || ys_tolong(ls) < 0) {
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
            yr(4, "off", yv_long(ys_tolong(fs)), "kind", ys("file"),
               "lbl", ys(""), "lbl2", ys("")),
            yr(4, "off", yv_long(ys_tolong(ls)), "kind", ys("line"),
               "lbl", ys(""), "lbl2", ys("")));
        return yr(4, "err", ys(""), "sec", yv_long(sec), "offs", offs,
                  "item", yr(7, "sec", yv_long(0), "off", ya_get(offs, 0),
                             "len", yv_long(0), "kind", ys("loc"),
                             "bytes", yav(0), "fix", fx, "br", yv_long(-1)));
    }
}

static Yv *asm_file(ylong lno, ylong sec, Yv *offs, Yv *rest) {
    ylong sp = ys_index_of(rest, ys(" "));
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
    if (!is_num_text(ns) || ys_tolong(ns) < 1 || asm_strdata_bad(q) ||
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
                             yv_long(ys_tolong(ns)), "len", yv_long(0),
                             "kind", ys("file"), "bytes", yav(0), "fix", fx, "br", yv_long(-1)));
    }
}

/* .section payload (split from asm_directive: dir-gate above narrows).
   NOTE: single bool gate (see asm_strdata note): marker-vs-error never mix. */
static Yv *asm_section(Yv *line, ylong lno, ylong sec, Yv *offs, Yv *rest) {
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

static Yv *asm_section_err(Yv *line, ylong lno, ylong sec, Yv *offs, Yv *rest) {
    /* (split: error shape built ONLY here.) */
    (void)line;
    return yr(4,
              "err", ys_cat(ys_cat(ys_cat(ys_cat(ys("L"), ys_long(lno)), ys(": unsupported section '")), rest), ys("'")),
              "sec", yv_long(sec), "offs", offs,
              "item", yr(7, "sec", yv_long(-1), "off", yv_long(0), "len", yv_long(0),
                         "kind", ys(""), "bytes", yav(0), "fix", yav(0), "br", yv_long(-1)));
}

static Yv *asm_section_go(ylong sec, Yv *offs, Yv *rest) {
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
static Yv *asm_quad(Yv *line, ylong lno, ylong sec, Yv *offs, Yv *rest) {
    /* NOTE: single bool gate (see asm_strdata note). */
    if (asm_quad_bad(rest)) {
        return asm_quad_err(line, lno, sec, offs, rest);
    } else {
        return asm_quad_go(sec, offs, rest);
    }
}

static int asm_quad_bad(Yv *rest) {
    /* `!is_num_text(rest)` is fine — `!` (an `un` node) needs a bool operand
       (types.y typeof_expr's "un" arm) and is_num_text returns one.
       A NEGATIVE value is allowed, and has to be: a .quad is a bit pattern, and
       half of every double's pattern reads as a negative long (that is the sign
       bit). Rejecting it made a table of IEEE-754 constants impossible to
       write, which is what every transcendental's coefficient table is. */
    if (!is_num_text(rest)) { return 1; }
    else { return 0; }
}

static Yv *asm_quad_err(Yv *line, ylong lno, ylong sec, Yv *offs, Yv *rest) {
    /* One cause, one message — see asm_quad_bad on why there is no second. */
    (void)line;
    return yr(4,
              "err", ys_cat(ys_cat(ys_cat(ys_cat(ys("L"), ys_long(lno)), ys(": bad .quad value '")), rest), ys("'")),
              "sec", yv_long(sec), "offs", offs,
              "item", yr(7, "sec", yv_long(-1), "off", yv_long(0), "len", yv_long(0),
                         "kind", ys(""), "bytes", yav(0), "fix", yav(0), "br", yv_long(-1)));
}

static Yv *asm_quad_go(ylong sec, Yv *offs, Yv *rest) {
    /* (split: data-item shape built ONLY here.) */
    /* parse_num, not ys_tolong: a .quad is a 64-bit bit pattern and the read
       is meant to be modulo 2^64 (ys_tolong is strtoll, which CLAMPS at the
       ends of the range instead). It is also the read asm_quad_bad validated,
       so the two cannot disagree. */
    Yv *bytes = le64(yv_l(yr_get(parse_num(rest), "v")));
    Yv *item = yr(7, "sec", yv_long(sec), "off", ya_get(offs, sec), "len", yv_long(yv_len(bytes)),
                  "kind", ys("data"), "bytes", bytes, "fix", yav(0), "br", yv_long(-1));
    ya_set(offs, sec, yv_long(yv_l(ya_get(offs, sec)) + yv_len(bytes)));
    return yr(4, "err", ys(""), "sec", yv_long(sec), "offs", offs, "item", item);
}

/* .zero N: N zero bytes. In .bss they only reserve space (no file bytes). */
static Yv *asm_zero(Yv *line, ylong lno, ylong sec, Yv *offs, Yv *rest) {
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
        ylong n = ys_tolong(rest);
        Yv *zb = yav(0);
        if (sec != 2) {
            ylong i = 0;
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

/* .align N: pad to the next multiple of N. The kernel's IDT and stack want it
   (a misaligned IDT works by luck, and a misaligned stack breaks the
   alignment-only-if-it-is-aligned SSE the runtime may one day use) and .bss
   has no bytes to place, so the pad is a hole like .zero's. GNU as reads
   .align N as "N bytes" on x86 too, so asm-check sees the same thing. */
static Yv *asm_align(Yv *line, ylong lno, ylong sec, Yv *offs, Yv *rest) {
    if (asm_quad_bad(rest)) {
        (void)line;
        return yr(4,
                  "err", ys_cat(ys_cat(ys_cat(ys_cat(ys("L"), ys_long(lno)),
                                               ys(": bad .align size '")),
                                       rest),
                                ys("'")),
                  "sec", yv_long(sec), "offs", offs,
                  "item", yr(7, "sec", yv_long(-1), "off", yv_long(0), "len", yv_long(0),
                             "kind", ys(""), "bytes", yav(0), "fix", yav(0), "br", yv_long(-1)));
    } else {
        (void)line;
        ylong n = ys_tolong(rest);
        Yv *cur = ya_get(offs, sec);
        ylong pad = 0;
        if (n > 0 && yv_l(cur) % n != 0) { pad = n - yv_l(cur) % n; };
        Yv *zb = yav(0);
        if (sec != 2) {
            ylong i = 0;
            while (i < pad) {
                zb = ya_push(zb, yv_long(0));
                i = i + 1;
            }
        }
        Yv *item = yr(7, "sec", yv_long(sec), "off", cur,
                      "len", yv_long(pad), "kind", ys("data"), "bytes", zb,
                      "fix", yav(0), "br", yv_long(-1));
        ya_set(offs, sec, yv_long(yv_l(cur) + pad));
        return yr(4, "err", ys(""), "sec", yv_long(sec), "offs", offs,
                  "item", item);
    }
}

static Yv *asm_insn(Yv *line, ylong lno, ylong sec, Yv *offs) {
    ylong sp = ys_index_of(line, ys(" "));
    ylong tab = ys_index_of(line, ys("\t"));
    ylong cut = sp;
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
        ylong i = 0;
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
static Yv *asm_encode(Yv *mn, Yv *ops, ylong lno, ylong sec, Yv *offs) {
    Yv *buf = scratch();
    Yv *r = enc_insn(buf, 0, mn, ops, 0);
    if (!ys_eq_lit(yr_get(r, "err"), "")) {
        return yr(4,
                  "err", ys_cat(ys_cat(ys_cat(ys_cat(ys_cat(ys_cat(ys("L"), ys_long(lno)), ys(": ")), yr_get(r, "err")), ys(" in '")), mn), ys("'")),
                  "sec", yv_long(sec), "offs", offs,
                  "item", yr(7, "sec", yv_long(-1), "off", yv_long(0), "len", yv_long(0),
                             "kind", ys(""), "bytes", yav(0), "fix", yav(0), "br", yv_long(-1)));
    } else {
        ylong blen = yv_l(yr_get(r, "at"));
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
static Yv *ir_operand(Yv *ir, ylong wp, ylong k) {
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
        ylong ml = yv_l(ya_get(ir, wp + 4));
        if (ml >= 0) {
            return yr(13, "k", yv_long(K_mem), "n", yv_long(0), "size", yv_long(0), "v",
                      yv_long(0), "a", ys(""), "b", ys(""), "name", ys(""), "base",
                      yv_long(-1), "idx", yv_long(-1), "scale", yv_long(1), "disp",
                      yv_long(0), "rip", yv_bool(1), "lbl", lname(ya_get(ir, wp + 4)));
        } else {
            ylong disp = yv_l(ya_get(ir, wp + 3));
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
static Yv *ir_where(Yv *lblname, ylong n) {
    if (ys_eq_lit(lblname, "")) {
        return ys_cat(ys("item "), ys_long(n));
    } else {
        return ys_cat(ys_cat(lblname, ys("+")), ys_long(n));
    }
}

static Yv *ir_enc_item(Yv *ir, ylong at, ylong sec, Yv *offs, Yv *where) {
    ylong f = yv_l(ya_get(ir, at));
    Yv *fo = ir_form(f);
    Yv *kinds = yr_get(fo, "kinds");
    Yv *ops = yav(0);
    ylong wp = at + 1;
    ylong i = 0;
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
        ylong blen = yv_l(yr_get(r, "at"));
        Yv *item = yr(7, "sec", yv_long(sec), "off", ya_get(offs, sec), "len", yv_long(blen),
                      "kind", ys("insn"), "bytes", ya_slice(buf, 0, blen), "fix",
                      yr_get(r, "fix"), "br", yr_get(r, "br"));
        ya_set(offs, sec, yv_long(yv_l(ya_get(offs, sec)) + blen));
        return yr(4, "err", ys(""), "sec", yv_long(sec), "offs", offs, "item", item);
    }
}

/* A label definition (IR_LABEL): the AsmLabel asm_labdef_go builds, with the
   name from the label table rather than from the line. */
static Yv *asm_ir_label(ylong id, ylong sec, Yv *offs, Yv *items, Yv *labels) {
    return ya_push(labels, yr(4, "name", lname(yv_long(id)), "sec", yv_long(sec), "off",
                              ya_get(offs, sec), "at_item", yv_long(yv_len(items))));
}

/* A .loc marker (IR_LOC): the item asm_loc builds, with the numbers read from
   the item instead of from a line. No sec check: a body is all .text. */
static Yv *asm_ir_loc(ylong file, ylong line, ylong sec, Yv *offs, ylong fno) {
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
static Yv *asm_ir_items(Yv *ir, Yv *txt, ylong fno, int loc, ylong sec, Yv *offs, Yv *items, Yv *labels, Yv *err, ylong lno) {
    ylong at = 0;
    ylong n = 0;
    Yv *cur = ys("");
    while (at < yv_len(ir)) {
        ylong f = yv_l(ya_get(ir, at));
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
            ylong i = yv_l(ya_get(ir, at + 1));
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
Yv *part_ir(Yv *ir, Yv *txt, ylong fno, int loc) {
    return yr(5, "ir", ir, "txt", txt, "text", ys(""), "fno", yv_long(fno), "loc",
              yv_bool(loc));
}

Yv *part_text(Yv *text) {
    return yr(5, "ir", yav(0), "txt", yav(0), "text", text, "fno", yv_long(0), "loc",
              yv_bool(0));
}

static Yv *asm_ir_st(ylong sec, Yv *offs, Yv *items, Yv *labels, Yv *err, ylong lno) {
    return yr(6, "sec", yv_long(sec), "offs", offs, "items", items, "labels", labels,
              "err", err, "lno", yv_long(lno));
}

/* One text line through the text path, on the IR path's state (the line
   counter it advances is what an IR_TEXT item's error names). */
static Yv *asm_st_seg(Yv *st, Yv *lines, ylong li) {
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

static ylong asm_relax(Yv *items, Yv *labels, int debug) {
    /* The rounds walk two compact arrays of the items' lengths and sections
       rather than the records: an AsmItem is seven words, and streaming 13 MB
       of them four times over was most of this pass (measured 47 ms for ycc.y
       before this, against 9 ms after). One sweep builds the arrays; a branch
       index list (there are 15k branches to 234k items) keeps the rounds off
       the records entirely, and `cum` holds the round's frozen offsets. */
    Yv *lens = yav(0);
    Yv *secs = yav(0);
    Yv *brs = yav(0);
    ylong i = 0;
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
    ylong rounds = 0;
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
    ylong cap = yv_len(labels) * 2 + 16;
    Yv *m = labmap_new(cap);
    ylong i = 0;
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
        ylong at = 0;
        ylong i = 0;
        while (i < yv_len(lens)) {
            if (i < yv_len(cum)) { ya_set(cum, i, yv_long(at)); }
            else { cum = ya_push(cum, yv_long(at)); }
            if (yv_l(ya_get(secs, i)) == 0) { at = at + yv_l(ya_get(lens, i)); }
            i = i + 1;
        }
        ylong j = 0;
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
    ylong k = 0;
    while (k < yv_len(brs)) {
        ylong i = yv_l(ya_get(brs, k));
        /* len 2 is the short form; a grower is already long. */
        if (yv_l(ya_get(lens, i)) == 2) {
            Yv *it = ya_get(items, i);
            Yv *fx = ya_get(yr_get(it, "fix"), 0);
            ylong li = relax_target(rlmap, yr_get(fx, "lbl"));
            ylong here = first ? yv_l(yr_get(it, "off")) : yv_l(ya_get(cum, i));
            /* An unknown target is pass 2's error to report, and a target
               outside .text has no address to measure yet: grow both, so
               nothing here can be wrong in a way pass 2 would not catch. */
            if (li >= 0 && yv_l(yr_get(ya_get(labels, li), "sec")) == 0) {
                ylong d = yv_l(yr_get(ya_get(labels, li), "off")) - (here + 2);
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
static ylong relax_target(Yv *rlmap, Yv *lbl) {
    Yv *e = labmap_get(rlmap, lbl);
    if (yv_l(yr_get(e, "sec")) < 0) { return -1; }
    return yv_l(yr_get(e, "off"));
}

/* Re-encode item `i` in the long form, from what it recorded (`br`) and what
   its fixup names. Returns the new length. */
static ylong relax_grow(Yv *items, ylong i, Yv *lens, Yv *lbl) {
    Yv *it = ya_get(items, i);
    Yv *buf = scratch();
    Yv *r = enc_branch_long(buf, 0, yv_l(yr_get(it, "br")), lbl);
    ylong alen = yv_l(yr_get(r, "at"));
    ya_set(items, i, yr(7, "sec", yr_get(it, "sec"), "off", yr_get(it, "off"),
                        "len", yv_long(alen), "kind", yr_get(it, "kind"),
                        "bytes", ya_slice(buf, 0, alen), "fix", yr_get(r, "fix"),
                        "br", yr_get(it, "br")));
    ya_set(lens, i, yv_long(alen));
    return alen;
}

/* The bound case: every branch long, which is the pre-relaxation encoding. */
static ylong relax_all_long(Yv *items, Yv *labels, Yv *lens) {
    (void)labels;
    ylong n = 0;
    ylong i = 0;
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
static ylong relax_place(Yv *items, Yv *labels, Yv *lens, Yv *secs, int debug) {
    Yv *offs = yav(3, yv_long(0), yv_long(0), yv_long(0));
    ylong i = 0;
    ylong j = 0;
    while (i < yv_len(lens)) {
        while (j < yv_len(labels) && yv_l(yr_get(ya_get(labels, j), "at_item")) <= i) {
            Yv *lb = ya_get(labels, j);
            ya_set(labels, j, yr(4, "name", yr_get(lb, "name"), "sec", yr_get(lb, "sec"),
                                  "off", ya_get(offs, yv_l(yr_get(lb, "sec"))),
                                  "at_item", yr_get(lb, "at_item")));
            j = j + 1;
        }
        ylong s = yv_l(ya_get(secs, i));
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
    ylong lt0 = clock_us();
    ylong lh0 = heap_used();
    ylong code_len = 0;
    ylong ro_len = 0;
    ylong bss_len = 0;
    int bss_data = 0;
    /* NOTE: `0;` tails (see parser.y parse_binary note). `it.len` reads go
       through the bare hole (tnone unifies — see types.y typeof_def note).
       elf_build takes the rodata bytes and sizes that segment itself; the
       rodata length only places the .bss. */
    ylong i = 0;
    while (i < yv_len(items)) {
        Yv *it = ya_get(items, i);
        ylong sec = yv_l(yr_get(it, "sec"));
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
       asm_bss_shift), so the fixups below only know two sections. */
    Yv *labs = labels;
    if (bss_len > 0) {
        ylong bshift = asm_bss_shift(code_len, ro_len, bss_len);
        labs = yav(0);
        ylong j = 0;
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
    ylong lt1 = clock_us();
    ylong lh1 = heap_used();
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
        ylong pad = 0;
        Yv *code = yav(0);
        Yv *ro = yav(0);
        Yv *err = ys("");
        ylong i = 0;
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
                ylong j = 0;
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
            ylong lt2 = clock_us();
            ylong lh2 = heap_used();
            Yv *syms = yav(0);
            Yv *dsecs = yav(0);
            if (debug) {
                syms = debug_syms(labels, code_len, bss_len);
                dsecs = debug_lines(items, code_len, asm_image_base(bss_len));
            }
            Yv *eb = asm_image(code, ro, yv_l(yr_get(start, "off")),
                               bss_len, syms, dsecs, items, labels);
            ylong lt3 = clock_us();
            ylong lh3 = heap_used();
            return yr(4, "ok", yv_bool(1), "bytes", eb, "error", ys(""),
                      "times", yav(3,
                                   yr(3, "name", ys("l:labmap"), "us", yv_long(lt1 - lt0), "heap", yv_long(lh1 - lh0)),
                                   yr(3, "name", ys("l:patch"), "us", yv_long(lt2 - lt1), "heap", yv_long(lh2 - lh1)),
                                   yr(3, "name", asm_link_row(), "us", yv_long(lt3 - lt2), "heap", yv_long(lh3 - lh2))));
        }
    }
}

static Yv *patch_item(Yv *code, Yv *it, Yv *lmap, ylong code_len, ylong pad) {
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

static Yv *patch_item_loop(Yv *code, Yv *it, Yv *lmap, ylong code_len, ylong pad, Yv *bytes, Yv *err) {
    ylong base = yv_len(code);
    Yv *fxlist = yr_get(it, "fix");
    ylong f = 0;
    /* NOTE: nested ifs, not `&&` (see is_digit_ch note); `0;` tails. */
    while (f < yv_len(fxlist)) {
        if (!ys_eq_lit(err, "")) {
            f = yv_len(fxlist);
            ;
        } else {
        Yv *fx = ya_get(fxlist, f);
        /* at is instruction-relative: bytes is the ITEM's list, and the
           rel target is relative to the instruction END (base + it.len). */
        ylong at = yv_l(yr_get(fx, "off"));
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

/* A no-relocation image can hold a fixup only if it is a displacement or a
   difference of two labels: there is no `.reloc` for an absolute address to be
   rebased against, and enc64.c writes no relocated absolute address at all.
   The kinds are enumerated here so that a future absolute one is refused by
   NAME at assembly time rather than silently written as a difference of two
   labels and truncated to 32 bits. pe.c's no-.reloc claim rests on this. */
static int pe_no_abs(Yv *kind) {
    return ys_eq_lit(kind, "rel32") || ys_eq_lit(kind, "rel8") ||
           ys_eq_lit(kind, "rip32") || ys_eq_lit(kind, "imm32diff");
}

static Yv *patch_item_kind2(Yv *lmap, ylong code_len, ylong pad, Yv *fx, Yv *bytes, ylong base, Yv *it, ylong at) {
    /* (split: non-rel32 kinds; `{bytes,err}` built ONLY here + callees.) */
    if (ys_eq_lit(yr_get(fx, "kind"), "rip32")) {
        return patch_item_rel(lmap, code_len, pad, fx, bytes, base, it, at);
    } else if (!pe_no_abs(yr_get(fx, "kind"))) {
        /* rel32 and rel8 never reach here (patch_item_loop handles them); what
           is left is the diff form, or a kind no no-relocation image can hold. */
        return yr(2, "bytes", bytes,
                  "err", ys_cat(ys_cat(ys("absolute fixup kind '"), yr_get(fx, "kind")),
                                ys("' has no representation in a no-relocation image")));
    } else {
        return patch_item_diff(lmap, code_len, pad, fx, bytes, base, it);
    }
}

static Yv *patch_item_rel(Yv *lmap, ylong code_len, ylong pad, Yv *fx, Yv *bytes, ylong base, Yv *it, ylong at) {
    /* rel32/rip32: target - address past the instruction.
       NOTE: fx/it stay BARE holes (see types.y typeof_def note): single
       reads unify. */
    Yv *t = label_addr(lmap, code_len, pad, yr_get(fx, "lbl"));
    if (!(yv_b(yr_get(t, "ok")))) {
        return yr(2, "bytes", bytes,
                  "err", ys_cat(ys_cat(ys("undefined label '"), yr_get(fx, "lbl")), ys("'")));
    } else {
        /* label_addr has already added `tab+8(%rip)`'s 8, so this is the target
           less the address past the instruction. */
        ylong v = yv_l(yr_get(t, "addr")) - (base + yv_l(yr_get(it, "len")));
        return yr(2, "bytes", patch32(bytes, at, v), "err", ys(""));
    }
}

static Yv *patch_item_rel8(Yv *lmap, ylong code_len, ylong pad, Yv *fx, Yv *bytes, ylong base, Yv *it, ylong at) {
    /* rel8: the same displacement in one byte, for a branch that relaxed.
       asm_relax only leaves one of these in range, so the value fits by
       construction (it grew the item otherwise); the truncation is still a
       byte store, not a silent 32-bit write past the instruction.
       NOTE: fx/it stay BARE holes (see types.y typeof_def note). */
    Yv *t = label_addr(lmap, code_len, pad, yr_get(fx, "lbl"));
    if (!yv_b(yr_get(t, "ok"))) {
        return yr(2, "bytes", bytes, "err", ys_cat(ys_cat(ys("undefined label '"), yr_get(fx, "lbl")), ys("'")));
    } else {
        ylong v = yv_l(yr_get(t, "addr")) - (base + yv_l(yr_get(it, "len")));
        return yr(2, "bytes", patch8(bytes, at, v), "err", ys(""));
    }
}

static Yv *patch_item_diff(Yv *lmap, ylong code_len, ylong pad, Yv *fx, Yv *bytes, ylong base, Yv *it) {
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

static Yv *patch_item_diff2(Yv *lmap, ylong code_len, ylong pad, Yv *fx, Yv *bytes, ylong ta) {
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

static Yv *patch32(Yv *bytes, ylong at, ylong v) {
    Yv *b = le32(v);
    ya_set(bytes, at, ya_get(b, 0));
    ya_set(bytes, at + 1, ya_get(b, 1));
    ya_set(bytes, at + 2, ya_get(b, 2));
    ya_set(bytes, at + 3, ya_get(b, 3));
    return bytes;
}

static Yv *patch8(Yv *bytes, ylong at, ylong v) {
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
static Yv *debug_syms(Yv *labels, ylong code_len, ylong bss_len) {
    Yv *out = yav(0);
    out = debug_syms_sec(out, labels, 0, code_len);
    out = debug_syms_sec(out, labels, 2, bss_len);
    return out;
}

static Yv *debug_syms_sec(Yv *out, Yv *labels, ylong sec, ylong end) {
    ylong first = yv_len(out);
    ylong j = 0;
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
    ylong i = first;
    while (i < yv_len(out)) {
        Yv *e = ya_get(out, i);
        ylong nxt = end;
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

static int is_sym_label(Yv *name, ylong sec) {
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
    ylong d = ys_last_index_of(s, ys("$"));
    if (d > 0) {
        ylong k = d + 1;
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
static Yv *after_uid(Yv *s, ylong k) {
    ylong i = k;
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
/* `code_off` is the ABSOLUTE address the first code byte is loaded at --
   asm_image_base's answer, which is the ELF base plus the header size or the
   PE's ImageBase plus .text's RVA. See the Y twin's note: this used to be a
   segment offset with 4194304 added here, which is right for exactly one
   target, and the caller already passed an absolute address, so every
   .debug_line address under -g read 0x800000-something for code that sits at
   0x401000. The port gate surfaced it: this side's shape produced the correct
   0x401xxx and the two copies disagreed on every -g binary. */
static Yv *debug_lines(Yv *items, ylong code_len, ylong code_off) {
    Yv *files = yav(0);
    Yv *rows = yav(0);
    ylong i = 0;
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
            ylong file_no = yv_l(yr_get(it, "off"));
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
        return dwarf_sections(files, rows, code_off, code_len, asm_cwd());
    }
}

/* The working directory, recorded as the compile unit's DW_AT_comp_dir
 * (as GNU as does): the raw getcwd syscall fills buf and returns the
 * path's length with its NUL, or a negative errno -- "." then. */
static Yv *asm_cwd(void) {
    char buf[4096];
    ylong n = syscall(SYS_getcwd, buf, 4096);
    if (n > 1) {
        return ys_cstr(buf);
    } else {
        return ys(".");
    }
}

/* asm.y's `code += bytes` (yv.h has no `+=` helper for an array operand, so
   the in-place append is spelled out as one push per element). */
static Yv *concat_bytes(Yv *a, Yv *b) {
    ylong i = 0;
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

/* ── the object writer ───────────────────────────────────────────────────
   One assembler, two object formats, chosen at link time (ideas/WINDOWS.md,
   "The target reaches three places", item 1): elf_build and pe_build have
   distinct names and distinct types, so both are linked in and nothing in
   the splicer has to know a target exists. Everything above them is
   format-agnostic: parse, labels, relax, fixups, and the segment-offset
   label_addr that is why a PE needs no .reloc. */

/* Where the code sits in the image, which the DWARF line table hangs off: on
   ELF the base plus the header size the ELF writer chose (the code's file
   offset, since the first segment is mapped at the base), on PE the image
   base plus the .text section's RVA. */
static ylong asm_image_base(ylong bss_len) {
    if (target_is_windows()) { return pe_text_base(); }
    else if (target_is_kernel()) { return kelf_base() + kelf_code_off(); }
    else { return 4194304 + elf_code_off(bss_len); }
}

/* Where the .bss section starts, as an offset from the rodata's start. The
   three writers round it differently (a page plus a page on ELF, the section
   alignment on PE, the page after the image on the kernel's ELF32), so the
   fixups must measure against the one that will place the bytes. */
static ylong asm_bss_shift(ylong code_len, ylong ro_len, ylong bss_len) {
    if (target_is_windows()) { return pe_bss_from_ro(code_len, ro_len, bss_len); }
    else if (target_is_kernel()) { return kelf_bss_from_ro(code_len, ro_len); }
    else { return elf_bss_from_ro(code_len, ro_len); }
}

/* The `ycc --time` row name for the writer, so the table names the format it
   actually ran. */
static Yv *asm_link_row(void) {
    if (target_is_windows()) { return ys("l:pe"); }
    else if (target_is_kernel()) { return ys("l:kelf"); }
    else { return ys("l:elf"); }
}

static Yv *asm_image(Yv *code, Yv *ro, ylong entry_off, ylong bss_len, Yv *syms,
                     Yv *dsecs, Yv *items, Yv *labels) {
    if (target_is_windows()) {
        return pe_image(code, ro, entry_off, bss_len, syms, dsecs, items, labels);
    } else if (target_is_kernel()) {
        /* No -g on a kernel image (ycc refuses the combination): the two
           debug writers here are ELF64/DWARF64, and an ELF32 kernel with a
           64-bit line table would be worse than no line table. */
        return kelf_build(code, ro, entry_off, bss_len);
    } else {
        return elf_build(code, ro, entry_off, bss_len, syms, dsecs);
    }
}

/* The PE writer, fed what it needs in its own shapes. `syms`/`dsecs` are the
   ELF-shaped records the -g pass above builds (debug_syms, dwarf.c's
   dwarf_sections): the same facts re-typed, because Y records are exact and a
   record goes only where its own type is expected -- and because the C copy
   SHARES records (yv.h), the fields are read through yr_get on the record the
   value lives in, never through a copy. */
static Yv *pe_image(Yv *code, Yv *ro, ylong entry_off, ylong bss_len, Yv *syms,
                    Yv *dsecs, Yv *items, Yv *labels) {
    Yv *un = pe_unwind(items, labels);
    Yv *dsecs2 = yav(0);
    Yv *ddata = yav(0);
    ylong i = 0;
    while (i < yv_len(dsecs)) {
        Yv *ds = ya_get(dsecs, i);
        dsecs2 = ya_push(dsecs2, pe_sec(yr_get(ds, "name"),
                                        yv_len(yr_get(ds, "data")), 0, 0, 1073741888));
        ddata = ya_push(ddata, yr_get(ds, "data"));
        i = i + 1;
    }
    Yv *coff = pe_coff_syms(syms);
    /* Windows has no syscall for randomness, sockets or the console: those
       arrive as imports, and this is the first one (see pe.c's import table). */
    return pe_build(code, ro, entry_off, bss_len, yr_get(un, "pdata"),
                    yr_get(un, "xdata"), dsecs2, ddata, coff,
                    pe_imports());
}

/* ── PE unwind data ─────────────────────────────────────────────────────
   RUNTIME_FUNCTION (12 bytes: BeginAddress, EndAddress, UnwindInfoAddress)
   and UNWIND_INFO (Version:Flags, SizeOfProlog, CountOfCodes, FrameRegister,
   then the codes). The bitfield pack a C struct would use is wrong here:
   `UBYTE UnwindOp : 4; UBYTE OpInfo : 4;` and a little-endian bitfield pack
   puts the first declared field in the low bits. Verified against a real
   ntdll's .xdata rather than taken from memory, because the other order
   decodes every record into nonsense. */

/* What one function's prologue turned out to be: its extent, whether it
   establishes a frame pointer, the total bytes it takes off the stack and
   where that is in effect from, and one (prolog offset, register number) per
   callee-saved register it pushed. */
static Yv *pe_frame0(ylong start, ylong first) {
    return yr(10, "start", yv_long(start), "end", yv_long(0),
              "first", yv_long(first), "last", yv_long(0),
              "fp", yv_bool(0), "fp_off", yv_long(0),
              "alloc", yv_long(0), "alloc_off", yv_long(0),
              "pushes", yav(0), "prolog", yv_long(0));
}

/* The two unwind sections, or two empty arrays when there is nothing to say. */
static Yv *pe_unwind(Yv *items, Yv *labels) {
    return pe_unwind_bytes(pe_frames(items, labels), 0);
}

/* Every function's extent, from the labels: a function starts at a label
   debug_syms would give a symbol to (`_start`, a `y_*` runtime helper, a
   `yfn_*` compiled def) and runs to the next such label, or to the end of
   .text. Jump targets (yL_*) and the arch prelude's internal labels belong
   to the function before them. */
static Yv *pe_frames(Yv *items, Yv *labels) {
    Yv *out = yav(0);
    ylong i = 0;
    while (i < yv_len(labels)) {
        Yv *lb = ya_get(labels, i);
        if (yv_l(yr_get(lb, "sec")) == 0 && is_sym_label(yr_get(lb, "name"), 0)) {
            out = ya_push(out, pe_frame0(yv_l(yr_get(lb, "off")),
                                         yv_l(yr_get(lb, "at_item"))));
        }
        i = i + 1;
    }
    return pe_frame_prologues(items, out);
}

/* Win64 nonvolatile integer registers (RBX, RBP, RSI, RDI, R12..R15 -- RSI
   and RDI are volatile on SysV, which is one of the two ABI deltas that is
   vacuous here: no live value ever crosses a call, so the emitted code is
   free to treat them as scratch, and only the unwind record has to say they
   were saved). */
static int pe_nonvol(ylong reg) {
    return reg == 3 || reg == 5 || reg == 6 || reg == 7
           || (reg >= 12 && reg <= 15);
}

/* Read one function's prologue off its items: a run of pushes, an optional
   `mov %rsp,%rbp`, and an optional `sub $N,%rsp`. Any other instruction ends
   it -- so a routine whose prologue this file has never seen records only the
   prefix it did recognise, which is exactly right for that prefix, rather
   than a guess. (A wrong unwind record makes a debugger walk into the middle
   of a frame; a short one makes it stop unwinding early, which is visible and
   harmless.)
   A frame's extent is its label to the next one's, and its ITEMS run from the
   item index its label sits at to the next one's. Item offsets cannot be used
   for this: relax_place only rewrites an item's `off` under -g, so without it
   `off` is still pass 1's, before the branch relaxation that moved everything
   (relax_place's own note). Counting items from `at_item` and adding lengths
   is the one position that is right either way. */
static Yv *pe_frame_prologues(Yv *items, Yv *frames) {
    ylong n = yv_len(frames);
    ylong i = 0;
    while (i < n) {
        ylong stop = 0;
        ylong last = yv_len(items);
        if (i + 1 < n) {
            stop = yv_l(yr_get(ya_get(frames, i + 1), "start"));
            last = yv_l(yr_get(ya_get(frames, i + 1), "first"));
        }
        ya_set(frames, i, pe_prologue(items, ya_get(frames, i), stop, last));
        i = i + 1;
    }
    return frames;
}

/* The Y twin mutates the frame record's fields in place and returns it; here
   yr_set does the same on the shared record (yv.h), so the caller below
   writes `ya_set(frames, i, ...)` exactly as the twin writes
   `frames[i] = pe_prologue(...)`. */
static Yv *pe_prologue(Yv *items, Yv *f, ylong stop, ylong last) {
    ylong alloc = 0;
    ylong alloc_off = 0;
    Yv *pushes = yav(0);
    ylong prolog = 0;
    int fp = 0;
    ylong fp_off = 0;
    ylong at = 0;
    ylong k = yv_l(yr_get(f, "first"));
    int open = 1;
    while (open && k < last) {
        Yv *it = ya_get(items, k);
        k = k + 1;
        if (yv_l(yr_get(it, "sec")) == 0) {
            Yv *r = pe_prologue_insn(it, at, fp, fp_off, alloc, alloc_off, pushes, prolog);
            if (yv_b(yr_get(r, "go"))) {
                fp = yv_b(yr_get(r, "fp"));
                fp_off = yv_l(yr_get(r, "fp_off"));
                alloc = yv_l(yr_get(r, "alloc"));
                alloc_off = yv_l(yr_get(r, "alloc_off"));
                pushes = yr_get(r, "pushes");
                prolog = yv_l(yr_get(r, "prolog"));
                at = prolog;
            } else {
                open = 0;
            }
        }
    }
    yr_set(f, "end", yv_long(stop));
    yr_set(f, "fp", yv_bool(fp));
    yr_set(f, "fp_off", yv_long(fp_off));
    yr_set(f, "alloc", yv_long(alloc));
    yr_set(f, "alloc_off", yv_long(alloc_off));
    yr_set(f, "pushes", pushes);
    yr_set(f, "prolog", yv_long(prolog));
    return f;
}

/* One prologue instruction, as {go} (it belonged to the prologue) or {go:
   false, ...} (it did not). `off` is the instruction's offset within the
   function; the CodeOffset a code carries is that instruction's last byte
   plus one, which is where the effect is in force. */
static Yv *pe_prologue_insn(Yv *it, ylong off, int fp, ylong fp_off, ylong alloc,
                            ylong alloc_off, Yv *pushes, ylong prolog) {
    Yv *b = yr_get(it, "bytes");
    ylong n = yv_len(b);
    ylong done = off + yv_l(yr_get(it, "len"));
    Yv *no = yr(7, "go", yv_bool(0), "fp", yv_bool(fp), "fp_off", yv_long(fp_off),
                "alloc", yv_long(alloc), "alloc_off", yv_long(alloc_off),
                "pushes", pushes, "prolog", yv_long(prolog));
    /* b[0] is read AFTER the length guard, not before it. Reading it first is
       what made `cycc --target=windows -g` trap with "index out of bounds" on
       any program: a zero-byte item (a line marker, which -g introduces) is
       walked by pe_frame_prologues, and ya_get on an empty array is a trap.
       The Y twin has always had the guard first -- src/y/asm.y's
       pe_prologue_insn reads b[0] inside the else -- so this is a PORT
       divergence, and the port gate could not see it because it compiles the
       corpus for Linux only and the walker is the PE one. */
    if (n < 1) {
        return no;
    }
    ylong b0 = yv_l(ya_get(b, 0));
    if (b0 == 0x55 || (b0 >= 0x50 && b0 <= 0x57)) {
        /* push %reg (no REX: rax..rdi) */
        return pe_prologue_push(b0 - 0x50, done, fp, fp_off, alloc, done, pushes, prolog);
    } else if (b0 == 0x41 && n >= 2 && yv_l(ya_get(b, 1)) >= 0x50 && yv_l(ya_get(b, 1)) <= 0x57) {
        /* push %r8..%r15 */
        return pe_prologue_push(yv_l(ya_get(b, 1)) - 0x50 + 8, done, fp, fp_off, alloc, done, pushes, prolog);
    } else if (n >= 3 && b0 == 0x48 && yv_l(ya_get(b, 1)) == 0x89 && yv_l(ya_get(b, 2)) == 0xe5) {
        /* mov %rsp,%rbp: the frame register, established HERE -- so its code
           carries this instruction's offset, not the prologue's end, which
           may be several pushes and a `sub` later. */
        return yr(7, "go", yv_bool(1), "fp", yv_bool(1), "fp_off", yv_long(done),
                   "alloc", yv_long(alloc), "alloc_off", yv_long(alloc_off),
                   "pushes", pushes, "prolog", yv_long(done));
    } else if (n == 4 && b0 == 0x48 && yv_l(ya_get(b, 1)) == 0x83 && yv_l(ya_get(b, 2)) == 0xec) {
        /* sub $imm8,%rsp */
        return yr(7, "go", yv_bool(1), "fp", yv_bool(fp), "fp_off", yv_long(fp_off),
                   "alloc", yv_long(alloc + yv_l(ya_get(b, 3))),
                   "alloc_off", yv_long(done), "pushes", pushes, "prolog", yv_long(done));
    } else if (n == 7 && b0 == 0x48 && yv_l(ya_get(b, 1)) == 0x81 && yv_l(ya_get(b, 2)) == 0xec) {
        /* sub $imm32,%rsp */
        Yv *sz = le32(yv_l(ya_get(b, 3)));
        ylong v = yv_l(ya_get(sz, 0)) + 256 * yv_l(ya_get(sz, 1))
                 + 65536 * yv_l(ya_get(sz, 2)) + 16777216 * yv_l(ya_get(sz, 3));
        if (v < 0) { return no; }
        else {
            return yr(7, "go", yv_bool(1), "fp", yv_bool(fp), "fp_off", yv_long(fp_off),
                       "alloc", yv_long(alloc + v), "alloc_off", yv_long(done),
                       "pushes", pushes, "prolog", yv_long(done));
        }
    } else {
        return no;
    }
}

/* A push: 8 bytes off the stack either way, and -- for a register Win64
   considers nonvolatile -- a UWOP_PUSH_NONVOL whose CodeOffset is where that
   register becomes unreadable. The pack is offset * 16 + register, which
   keeps a frame's whole code list flat. */
static Yv *pe_prologue_push(ylong reg, ylong done, int fp, ylong fp_off, ylong alloc,
                            ylong alloc_off, Yv *pushes, ylong prolog) {
    Yv *np = pushes;
    ylong na = alloc;
    if (pe_nonvol(reg)) {
        /* A nonvolatile push gets UWOP_PUSH_NONVOL, which ALREADY says RSP
           went down by eight; counting it in the allocation as well would
           describe the same eight bytes twice and unwind 8 bytes too far. */
        np = ya_push(pushes, yv_long((done + 1) * 16 + reg));
    } else {
        /* A volatile push has no code of its own (that is what MASM's
           .allocstack 8 is for), so the allocation is what covers it. */
        na = alloc + 8;
    }
    return yr(7, "go", yv_bool(1), "fp", yv_bool(fp), "fp_off", yv_long(fp_off),
               "alloc", yv_long(na), "alloc_off", yv_long(done),
               "pushes", np, "prolog", yv_long(done));
}

/* One RUNTIME_FUNCTION per frame and one UNWIND_INFO per frame, the .pdata
   entry naming the .xdata offset. With no frames both sections are empty and
   pe_build leaves them out. */
static Yv *pe_unwind_bytes(Yv *frames, ylong xbase) {
    Yv *pdata = yav(0);
    Yv *xdata = yav(0);
    ylong i = 0;
    while (i < yv_len(frames)) {
        Yv *f = ya_get(frames, i);
        pdata = push_le32(pdata, yv_l(yr_get(f, "start")));
        pdata = push_le32(pdata, yv_l(yr_get(f, "end")));
        pdata = push_le32(pdata, xbase + yv_len(xdata));
        xdata = pe_unwind_info(xdata, f);
        i = i + 1;
    }
    return yr(2, "pdata", pdata, "xdata", xdata);
}

/* The codes of one frame, each a two-slot group packed into one long per
   slot, SORTED BY DESCENDING PROLOG OFFSET -- the order the epilog undoes
   them, and the order the unwinder scans (it walks the array for the first
   entry whose offset is <= the RIP offset, then undoes the rest).

   The packing: byte 0 of a slot is its CodeOffset, byte 1 is UnwindOp in the
   LOW nibble and OpInfo in the HIGH one. So a slot is
       offset + (op + info * 16) * 256
   and the writer below splits it back into two bytes. Note that the groups
   are sorted as UNITS, not slot by slot: UWOP_ALLOC_LARGE's second slot holds
   the allocation size, not an offset, and it must stay glued to its first. */
static Yv *pe_codes(Yv *f) {
    Yv *g = yav(0);
    Yv *ps = yr_get(f, "pushes");
    ylong i = 0;
    while (i < yv_len(ps)) {
        /* the push is packed as offset*16 + register (pe_prologue_push), and
           the register is OpInfo, i.e. the HIGH nibble: multiply by 16. */
        ylong packed = yv_l(ya_get(ps, i));
        g = ya_push(g, yav(1, yv_long(packed / 16 + (packed % 16) * 4096)));
        i = i + 1;
    }
    if (yv_b(yr_get(f, "fp"))) {
        g = ya_push(g, yav(1, yv_long(yv_l(yr_get(f, "fp_off")) + 1 + 3 * 256)));
    }
    if (yv_l(yr_get(f, "alloc")) > 0) {
        g = concat_arrays(g, pe_alloc(yv_l(yr_get(f, "alloc")), yv_l(yr_get(f, "alloc_off"))));
    }
    return pe_codes_sorted(g, 0);
}

/* One allocation's group. CodeOffset is "the end of the instruction that did
   it, plus one" -- the start of the next one -- which is what makes the
   unwinder's scan for the first code with offset <= rip-offset work.
   UWOP_ALLOC_SMALL covers 8..128 bytes (info = size/8 - 1); above that it is
   UWOP_ALLOC_LARGE with info 0 and size/8 in the next slot. */
static Yv *pe_alloc(ylong size, ylong off) {
    if (size >= 8 && size <= 128) {
        return yav(1, yav(1, yv_long(off + 1 + (2 + (size / 8 - 1) * 16) * 256)));
    } else if (size > 128) {
        return yav(1, yav(2, yv_long(off + 1 + 1 * 256), yv_long(size / 8)));
    } else {
        return yav(0);
    }
}

/* `a += b` for an array-of-arrays operand: yv.h has no `+=` helper for an
   array, so the in-place append is spelled out. */
static Yv *concat_arrays(Yv *a, Yv *b) {
    ylong i = 0;
    while (i < yv_len(b)) {
        a = ya_push(a, ya_get(b, i));
        i = i + 1;
    }
    return a;
}

/* Insertion sort by descending CodeOffset (the low byte of a group's first
   slot). A frame has at most nine groups. */
static Yv *pe_codes_sorted(Yv *g, ylong i) {
    Yv *out = yav(0);
    ylong at = i;
    while (at < yv_len(g)) {
        Yv *cur = ya_get(g, at);
        ylong j = yv_len(out);
        out = ya_push(out, cur);                 /* the slot to insert into */
        while (j > 0
               && yv_l(ya_get(ya_get(out, j - 1), 0)) % 256
                    < yv_l(ya_get(cur, 0)) % 256) {
            ya_set(out, j, ya_get(out, j - 1));
            j = j - 1;
        }
        ya_set(out, j, cur);
        at = at + 1;
    }
    Yv *slots = yav(0);
    ylong k = 0;
    while (k < yv_len(out)) {
        Yv *grp = ya_get(out, k);
        ylong q = 0;
        while (q < yv_len(grp)) { slots = ya_push(slots, ya_get(grp, q)); q = q + 1; }
        k = k + 1;
    }
    return slots;
}

/* One UNWIND_INFO: the 4-byte header, the codes, then the padding to an even
   slot count. With no flags there is no trailing handler or chained-info
   DWORD, so a function with no codes is exactly 4 bytes. */
static Yv *pe_unwind_info(Yv *xdata, Yv *f) {
    Yv *c = pe_codes(f);
    ylong n = yv_len(c);
    xdata = ya_push(xdata, yv_long(1));                       /* Version 1, no flags */
    xdata = ya_push(xdata, yv_long(yv_l(yr_get(f, "prolog")) % 256));
    xdata = ya_push(xdata, yv_long(n % 256));
    /* FrameRegister RBP (5) in the low nibble, the scaled offset (0 for
       `mov %rsp,%rbp`) in the high one. */
    if (yv_b(yr_get(f, "fp"))) { xdata = ya_push(xdata, yv_long(5)); }
    else { xdata = ya_push(xdata, yv_long(0)); }
    ylong i = 0;
    while (i < n) {
        xdata = ya_push(xdata, yv_long(yv_l(ya_get(c, i)) % 256));
        xdata = ya_push(xdata, yv_long(yv_l(ya_get(c, i)) / 256 % 256));
        i = i + 1;
    }
    if (n % 2 == 1) {
        xdata = ya_push(xdata, yv_long(0));
        xdata = ya_push(xdata, yv_long(0));
    }
    return xdata;
}

/* ── PE -g: the COFF symbol table ────────────────────────────────────────
   debug_syms already knows every function and global and its size; PE wants
   the same facts as 18-byte COFF records (section numbers 1-based, Value an
   RVA, no st_info byte as ELF has). The table and its string table are
   appended to the file by pe_build and mapped by nothing. */
static Yv *pe_coff_syms(Yv *syms) {
    Yv *out = yav(0);
    Yv *strtab = yav(0);
    ylong i = 0;
    while (i < yv_len(syms)) {
        Yv *s = ya_get(syms, i);
        out = pe_coff_sym(out, yr_get(s, "name"), yv_l(yr_get(s, "off")),
                          pe_coff_secnum(yv_l(yr_get(s, "sec"))));
        i = i + 1;
    }
    Yv *tail = yav(0);
    tail = push_le32(tail, yv_len(strtab) + yv_len(out));
    tail = push_bytes(tail, strtab);
    return push_bytes(out, tail);
}

static ylong pe_coff_secnum(ylong sec) {
    if (sec == 2) { return 2; } else { return 1; }
}

/* The 8-byte name field, zero-padded. A name of 8 bytes or more goes in the
   string table behind a zero field, and none of ours is that long -- the
   renamed `yfn_<uid>_<name>` symbols are shortened by sym_name first, which
   is what keeps them short. */
static Yv *pe_coff_sym(Yv *out, Yv *nm, ylong val, ylong secnum) {
    ylong i = 0;
    ylong n = yv_len(nm);
    /* ys_byte_at, not ya_get: `nm` is a str and a str is not an array (the
       Y twin's `nm[0:8]` is a byte slice of it). See pe_shdr's note in pe.c. */
    while (i < 8) {
        if (i < n) { out = ya_push(out, yv_long(ys_byte_at(nm, i))); }
        else { out = ya_push(out, yv_long(0)); }
        i = i + 1;
    }
    out = push_le32(out, val);
    out = push_le16(out, secnum);
    out = push_le16(out, 32);            /* Type: IMAGE_SYM_DTYPE_FUNCTION << 4 */
    out = ya_push(out, yv_long(3));      /* StorageClass: STATIC */
    out = ya_push(out, yv_long(0));      /* NumberOfAuxSymbols */
    return out;
}
