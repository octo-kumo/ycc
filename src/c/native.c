/* native.c — typed AST -> x86_64 assembly (AT&T/GAS) for the native backend.
 * 1:1 copy of src/y/native.y (see PORTING.md): every def is one function,
 * same names, same parameter order, same control flow.
 *
 * Usage (the driver, ycc.y):
 *   let nr = native_resolve_x(src, dir, 0, allow_exec, path);
 *   let su = std_units(nr.std, pack);  // the std units it links
 *   // (pack: ycc's std pack, or "" to compile them from source)
 *   let r = emit_program(ast, nr, debug, wlevel, su, []);
 *   // { ok, asm, errors }. debug is `-g`, which adds `.file`/`.loc`
 *   // line markers -- see dbg_lines.
 *   // compile_package builds one separately linked package unit.
 *   // r.ok: asm holds a complete .s file (cc-assemblable). else errors.
 *
 * Pipeline: types.check_program (fatal) -> collect defs (incl. hoisting of
 * capture-free nested defs = baby lambda lifting) -> frame layout -> emit.
 * Every value is 8 bytes (long/bool/ptr/str-address); expression values in
 * %rax; locals at negative rbp offsets; Y-function args pushed on the stack.
 */
#include <sys/syscall.h>
#include <unistd.h>
#include "ir.h"
#include "native.h"

#include "lexer.h"
#include "parser.h"
#include "lint.h"
#include "asm.h"
#include "labels.h"
#include "yv.h"
#include "tags.h"

/* Portability: no special subset is required of the Y twin any more. It is
 * hand-maintained alongside this file, not a machine translation, so both
 * compilers see the same constructs — dot chains, dot-assign and
 * short-circuit `&&` all work. What still binds is PORTING.md's 1:1
 * contract: same defs, same order, same arms.
 *
 * House style in src/y/native.y: a subexpression read more than once is
 * bound to a local (`let k = node.k;`) instead of re-read inline. The binds
 * are not free to remove either: every `let` costs a frame slot, so dropping
 * one changes the emitted `sub $N, %rsp`. */

/* ── imported (flattened module calls; PORTING.md rule 6) ─────────────── */

/* src/y/arch_x64.y */
Yv *arch_fn_label(long uid, Yv *name);
Yv *arch_global_label(long uid, Yv *name);
Yv *arch_loc_label(long fuid, long n);
Yv *arch_str_label(long i);
Yv *arch_header(void);
Yv *arch_rodata(void);
Yv *arch_text(void);
Yv *arch_bss(void);
Yv *arch_global_cell(Yv *label);
Yv *arch_heap_cells(void);
long arch_frame(long slots);
Yv *arch_prelude_lines(void);
Yv *arch_prelude_threads_lines(void);
Yv *arch_consts(void);
/* src/y/types.y */
Yv *tstr(Yv *t);
Yv *check_program(Yv *ast, Yv *ext);
Yv *field_merge(Yv *fields, Yv *name, Yv *typ);
Yv *str_method(Yv *m);
Yv *fmt_spec(Yv *spec);
long fmt_kind(Yv *t);
Yv *leaf_of(Yv *node);
Yv *narrow_type(Yv *s, Yv *t);
Yv *type_names(Yv *t);
Yv *arr_plus_kind(Yv *lt, Yv *rt);
int is_bits_op(Yv *op);
int teq(Yv *a, Yv *b);
long field_pos(Yv *fs, Yv *name, long hint);
Yv *union_member(Yv *u, Yv *t);
Yv *unfold(Yv *t);
Yv *members(Yv *t);
Yv *union_parts(Yv *t);
Yv *pat_members(Yv *s, Yv *t);
Yv *lit_target(Yv *node, Yv *want);
int opt_wraps(Yv *vt, Yv *ft);
Yv *t_mutex(void);
Yv *t_sem(void);
Yv *tcanon(Yv *t);
Yv *tsig(Yv *t);
Yv *inferred_ret(long line, long col);
Yv *fn_ret(Yv *func);
Yv *str_sorted(Yv *xs);
Yv *rec_names(Yv *fs);
/* src/y/rename.y */
Yv *rename_program(Yv *ast);
Yv *rename_program_x(Yv *ast, Yv *dfl, Yv *ofile, Yv *fmods);

/* The std units' sources (see std_units): native.y's `embed` declarations
 * (see Y_EMBED in yv.h). */
Y_EMBED(RT_SRC, "src/y/std/rt.y")
Y_EMBED(PRELUDE_SRC, "src/y/std/prelude.y")
Y_EMBED(EXEC_SRC, "src/y/std/exec.y")
Y_EMBED(STR_SRC, "src/y/std/str.y")

/* `ycc -g` line markers, set by compile_unit for each unit. With
 * dbg_lines on, the text opens with a `.file N "path"` per origin file
 * and every statement (gen_loc_stmt) and function entry (emit_one_fn)
 * gets a `.loc FILE LINE` before its code -- GNU as's own line-number
 * directives, which asm.y turns into DWARF. dbg_file/dbg_line are the
 * origin map's (native_resolve_x): the way back from a line of a unit
 * to its file. Off, nothing is emitted. */
static int dbg_lines;
static Yv *dbg_file;
static Yv *dbg_line;
static Yv *res_pkgs;
static Yv *res_roots;
static Yv *res_used;
static Yv *pkg_ns;
/* tcode's and tdecode's recursive aliases (trefs) being spelled out and
 * read back, and the count behind the unit ids tdecode gives them. */
static Yv *tcode_refs;
static Yv *tdec_encs;
static Yv *tdec_refs;
static long tdec_n;
/* The record-type descriptors emitted so far (ty_desc; link_units reuses
 * it for the whole program): an open-addressing set of their labels, with
 * each label's canonical form beside it ("" = an empty slot). compile_unit
 * empties it for each unit. */
static Yv *ty_seen;
static Yv *ty_forms;
static long ty_count;
/* ty_desc's labels in this unit, by type signature (types.c tsig): a type
 * named again needs no canonical form spelled out and hashed (a recursive
 * union's is long, and a read through a union asks for every member's).
 * 512 buckets of indices into ty_sig_keys/ty_sig_ids, made when first
 * used (ty_sig_init); tyset_reset empties them. */
static Yv *ty_sig_keys;
static Yv *ty_sig_ids;
static Yv *ty_sig_bkts;
/* union_shared's answers in this unit, by the union's node. */
static Yv *ush_nodes;
static Yv *ush_vals;

/* ── forward declarations (native.y def order) ────────────────────────── */

Yv *native_resolve(Yv *src, Yv *base_dir, long depth);
Yv *native_resolve_x(Yv *src, Yv *base_dir, long depth, int allow_exec,
                     Yv *root);
Yv *native_resolve_pk(Yv *src, Yv *base_dir, int allow_exec, Yv *root,
                      Yv *pkgs, Yv *roots);
Yv *resolve_unit(Yv *src, Yv *base_dir, long depth, int allow_exec,
                 Yv *root);
long origin_file(Yv *o, long ln);
Yv *origin_at(Yv *o, long ln, int bare);
Yv *prelude_names(void);
Yv *exec_names(void);
Yv *str_names(void);
Yv *std_text(Yv *s);
Yv *words_seen(Yv *code, Yv *names);
long words_scan(Yv *code, long lo, long n, Yv *names, Yv *seen);
int word_byte(long c);
int blank_byte(long c);
int word_at(Yv *code, long i, Yv *nm);
int seen_any(Yv *seen, long lo, long hi, long level);
Yv *norm_path(Yv *p);
long seen_index(Yv *seen, Yv *full);
int seen_has(Yv *seen, Yv *full);
Yv *dir_of(Yv *p);
Yv *std_resolve(Yv *name, Yv *base_dir);
Yv *native_resolve_seen(Yv *src, Yv *base_dir, long depth, Yv *seen,
                        Yv *smods, long fid);
int is_embed_decl(Yv *trimmed);
Yv *embed_decl(Yv *trimmed, Yv *base_dir);
Yv *quote_text(Yv *s);
int is_id_b(long c);
long skip_sp(Yv *b, long i, long hi);
long tok_end_b(Yv *b, long i, long hi);
Yv *tok_at_b(Yv *text, Yv *b, long i, long hi);
Yv *tok_push(Yv *out, Yv *t);
Yv *line_refs_b(Yv *text, Yv *b, long lo, long hi, Yv *out, int want_jumps);
Yv *refs_range(Yv *text, Yv *b, long lo, long hi, Yv *out, int want_jumps);
static Yv *ir_refs(Yv *ir);
static Yv *ir_refs_item(Yv *ir, long at, Yv *out);
static Yv *ir_refs_push(Yv *out, Yv *nm);
static Yv *ir_relabel(Yv *ir, Yv *m, Yv *dup_new);
static long ir_relabel_one(long id, Yv *m, Yv *dup_new);
Yv *label_at(Yv *text, Yv *b, long lo, long hi);
int is_data_line_b(Yv *text, Yv *b, long lo, long hi);
int block_falls_b(Yv *text, Yv *b, long lo, long hi);
Yv *namemap_build(Yv *names);
long namemap_get(Yv *m, Yv *name);
Yv *fntab_of(Yv *syms, Yv *ids);
Yv *fntab_ids(Yv *syms);
Yv *labmap_new(long cap);
Yv *labmap_put(Yv *m, Yv *name, long sec, long off);
Yv *labmap_get(Yv *m, Yv *name);
Yv *shake_keep(Yv *names, Yv *refs, Yv *falls, Yv *keep, Yv *roots);
Yv *shake_refs(Yv *text, Yv *root_refs);
Yv *prelude_blocks(Yv *lines);
Yv *lines_refs(Yv *lines, long lo, long hi);
int lines_fall(Yv *lines, long lo, long hi);
Yv *shake_prelude(Yv *pb, Yv *roots);
Yv *prelude_with(Yv *core, int threads);
Yv *unkept_refs(Yv *refs, Yv *bmap, Yv *keep);
Yv *prune_bodies(Yv *labels, Yv *refs, Yv *extra_roots);
int is_all_digits(Yv *s);
Yv *runtime_base(Yv *name);
Yv *fn_label_of(long uid, Yv *name);
int is_ns(Yv *name, Yv *imports);
Yv *normnode(Yv *anode);
Yv *strip_list(Yv *nodes, Yv *imports);
Yv *strip_ns(Yv *node, Yv *imports);
Yv *strip_decl(Yv *node, Yv *imports);
Yv *st_new(void);
Yv *emit(Yv *st, Yv *line);
Yv *next_uid(Yv *st);
Yv *next_loc(Yv *st);
Yv *esc_asm(Yv *s);
Yv *env_find(Yv *st, Yv *name);
Yv *env_define(Yv *st, Yv *name, Yv *kind, long off, Yv *label, Yv *mark,
               Yv *typ);
Yv *infer(Yv *st, Yv *node);
Yv *infer_call(Yv *st, Yv *node);
Yv *cur_fn_type(Yv *st);
Yv *cur_fn_ret(Yv *st);
Yv *fn_args_of(Yv *t);
Yv *infer_block(Yv *st, Yv *node);
Yv *infer_decl(Yv *st, Yv *node);
Yv *uses_scan_block(Yv *stmts, Yv *out);
Yv *uses_scan_node(Yv *node, Yv *out);
Yv *collect_from_block(Yv *stmts, Yv *out);
Yv *collect_from_node(Yv *node, Yv *out);
int uses_threads(Yv *refs);
int name_in(Yv *xs, Yv *n);
int is_intrinsic_name(Yv *n);
Yv *fv_walk(Yv *node, Yv *out, int collect);
Yv *fv_walk_list(Yv *nodes, Yv *out, int collect);
Yv *fv_ids(Yv *node, Yv *out);
Yv *fv_binds(Yv *node, Yv *out);
Yv *fv_binds_list(Yv *nodes, Yv *out);
Yv *fn_captures(Yv *func, Yv *ex, Yv *extra);
Yv *fv_bind_params(Yv *ps, Yv *out);
Yv *fn_names_of(Yv *fns);
Yv *fns_kind(Yv *label);
Yv *gen(Yv *st, Yv *node);
Yv *gen_go(Yv *st, Yv *node);
Yv *gen_as(Yv *st, Yv *node, Yv *want);
int union_within(Yv *s, Yv *t);
Yv *cast_members(Yv *s, Yv *t);
Yv *gen_cast_check(Yv *st, Yv *ts, Yv *u);
Yv *ty_desc_as(Yv *st, Yv *rt, Yv *lay);
Yv *union_shared(Yv *u);
Yv *union_lay(Yv *m, Yv *u);
Yv *lay_of(Yv *t, Yv *inu);
int same_lay(Yv *a, Yv *b);
Yv *ty_desc_in(Yv *st, Yv *m, Yv *inu);
Yv *gen_copy_rec(Yv *st, Yv *from, Yv *to, Yv *tag);
Yv *gen_convert(Yv *st, Yv *src0, Yv *want0, int check);
Yv *gen_str_const(Yv *st, Yv *s);
Yv *gen_id(Yv *st, Yv *node);
Yv *gen_cap_ptr(Yv *st, Yv *name);
Yv *box_capture(Yv *st, Yv *name);
Yv *box_names(Yv *func);
Yv *box_bound(Yv *st, Yv *name);
Yv *app_walk(Yv *node, Yv *out, int deep);
Yv *app_walk_list(Yv *nodes, Yv *out, int deep);
Yv *app_names(Yv *node, int deep, Yv *skip);
int own_wanted(Yv *st, Yv *name);
Yv *bind_own(Yv *st, Yv *name, Yv *t);
Yv *gen_stmt(Yv *st, Yv *node);
Yv *gen_sappend(Yv *st, Yv *v, Yv *var_lbl, long var_disp, Yv *cell_lbl,
                long cell_disp);
Yv *gen_discard(Yv *st, Yv *node);
Yv *gen_make_closure(Yv *st, Yv *label, Yv *caps);
Yv *gen_range(Yv *st, Yv *node);
Yv *gen_slice(Yv *st, Yv *node);
Yv *gen_indirect(Yv *st, Yv *node, Yv *callee);
Yv *gen_str_slice(Yv *st, Yv *node);
Yv *gen_sliceassign(Yv *st, Yv *node);
Yv *gen_rectest(Yv *st, Yv *node);
Yv *rectest_members(Yv *s, Yv *t);
Yv *gen_tag_in(Yv *st, Yv *ts, Yv *inu);
Yv *gen_union_slot(Yv *st, Yv *t, Yv *dkey, int store);
Yv *gen_narrow_field(Yv *st, Yv *nar, Yv *s, Yv *dkey);
Yv *gen_slot_move(Yv *st, long sl, int store);
Yv *gen_union_str_rax(Yv *st, Yv *t, Yv *path);
int is_void_node(Yv *n);
Yv *loc_pos(long ln);
static Yv *emit_loc(Yv *st, long ln);
static Yv *ir_loc(Yv *body, long ln);
Yv *gen_loc_stmt(Yv *st, Yv *node);
Yv *gen_loc_elif(Yv *st, Yv *els);
Yv *gen_loc_loop(Yv *st, Yv *node);
Yv *file_dirs(Yv *files);
Yv *gen_un(Yv *st, Yv *node);
Yv *gen_addr(Yv *st, Yv *node);
Yv *gen_elem_addr(Yv *st, Yv *node);
Yv *gen_bin(Yv *st, Yv *node);
Yv *gen_logic(Yv *st, Yv *node, int is_or);
Yv *gen_cat(Yv *st, Yv *node, Yv *lt, Yv *rt);
Yv *gen_float_bin(Yv *st, Yv *node, Yv *lt, Yv *rt);
Yv *gen_str_cmp(Yv *st, Yv *node, Yv *op);
int eq_elem_loop(Yv *t);
Yv *gen_eq_vals(Yv *st, Yv *t);
Yv *gen_eq_opt(Yv *st, Yv *pt);
Yv *gen_eq_arr_deep(Yv *st, Yv *et);
Yv *gen_bin_rest(Yv *st, Yv *node);
Yv *gen_shift(Yv *st, Yv *node, Yv *op);
long shift_imm(Yv *r);
long syscall_reg(long i);
Yv *gen_push_args(Yv *st, Yv *args);
Yv *gen_push_args_as(Yv *st, Yv *args, Yv *ptypes);
Yv *gen_conv(Yv *st, Yv *got, Yv *want);
Yv *arr_elem_type(Yv *t);
Yv *store_elem_type(Yv *t, long esz);
Yv *gen_helper1(Yv *st, Yv *name);
Yv *gen_call(Yv *st, Yv *node);
Yv *gen_fmt(Yv *st, Yv *node);
Yv *gen_method(Yv *st, Yv *node);
Yv *gen_print(Yv *st, Yv *node);
Yv *gen_print_scalar(Yv *st, Yv *arg, Yv *t);
Yv *gen_typeof(Yv *st, Yv *node);
Yv *gen_opt_str_rax(Yv *st, Yv *t, Yv *path);
Yv *gen_rec_str(Yv *st, Yv *arg, Yv *t);
Yv *gen_rec_str_rax(Yv *st, Yv *t, Yv *lay, Yv *path);
Yv *gen_cons(Yv *st, Yv *node);
Yv *gen_cat_conv(Yv *st, Yv *node, Yv *lt);
Yv *gen_cat_arr(Yv *st, Yv *node, Yv *lt, Yv *rt);
Yv *gen_acc_cat_const(Yv *st, Yv *s);
Yv *gen_rec_field_str(Yv *st, long idx, Yv *ft, Yv *path);
Yv *gen_syscall(Yv *st, Yv *node);
long capture_off(Yv *st);
Yv *gen_direct(Yv *st, Yv *node, Yv *name);
Yv *gen_if(Yv *st, Yv *node);
Yv *gen_while(Yv *st, Yv *node);
Yv *gen_for(Yv *st, Yv *node);
Yv *gen_forrange(Yv *st, Yv *node);
Yv *gen_foreach(Yv *st, Yv *node);
Yv *gen_bstr(Yv *st, Yv *node);
Yv *gen_tail(Yv *st, Yv *node);
Yv *gen_tail_call(Yv *st, Yv *node);
int is_self_call(Yv *st, Yv *node);
Yv *gen_block(Yv *st, Yv *node);
Yv *gen_block_as(Yv *st, Yv *node, int dropped);
long mfield_idx(Yv *names, Yv *name);
Yv *gen_reclit(Yv *st, Yv *node, Yv *want);
int lit_wraps(Yv *st, Yv *mv, Yv *rtu, Yv *mk, Yv *ft);
long fnv64(Yv *s);
Yv *hex16(long h);
long rec_slot(Yv *fs, Yv *key);
long tyset_add(Yv *lbl, Yv *form);
void tyset_grow(void);
void tyset_reset(void);
void ty_sig_init(void);
void ty_collision(Yv *lbl, Yv *form);
Yv *ty_desc(Yv *st, Yv *rt);
Yv *ty_form(Yv *rt);
Yv *alias_of(Yv *t);
int same_rec(Yv *lt, Yv *t);
Yv *rec_lit_type(Yv *lt, Yv *want);
Yv *infer_go(Yv *st, Yv *node);
Yv *gen_slot_load(Yv *st, long idx);
Yv *gen_func_literal(Yv *st, Yv *node);
Yv *gen_closure_binding(Yv *st, Yv *name, Yv *func, Yv *caps);
Yv *gen_decl(Yv *st, Yv *node);
Yv *bind_decl(Yv *st, Yv *name, Yv *t);
Yv *gen_assign(Yv *st, Yv *node);
Yv *gen_fill(Yv *st, long base, long n);
Yv *gen_fill_heap(Yv *st, long n, long esz);
Yv *gen_arrrep(Yv *st, Yv *node);
Yv *gen_arrrep_esz(Yv *st, Yv *node, long esz, Yv *ety);
long hexval_ch(Yv *c);
int lit_is_float(Yv *s);
Yv *norm_num(Yv *s);
long flit_ebase(Yv *s);
long flit_bits(Yv *s);
int flit_dmul_limb(Yv *a, long n);
void flit_ddiv_limb(Yv *a, long n);
Yv *gen_lit(Yv *st, Yv *node);
Yv *gen_index(Yv *st, Yv *node);
Yv *gen_dotassign(Yv *st, Yv *node);
Yv *n_num(Yv *v, long line, long col);
Yv *n_id(Yv *v, long line, long col);
Yv *args1(Yv *a);
Yv *args2(Yv *a, Yv *b);
Yv *n_call1(Yv *name, Yv *a0, long line, long col);
Yv *n_call2(Yv *name, Yv *a0, Yv *a1, long line, long col);
Yv *block2(Yv *a, Yv *b, long ln, long cl);
Yv *block3(Yv *a, Yv *b, Yv *c, long ln, long cl);
Yv *block_bind(Yv *first, Yv *rest, long ln, long cl);
Yv *block4(Yv *a, Yv *b, Yv *c, Yv *d, long ln, long cl);
Yv *block5(Yv *a, Yv *b, Yv *c, Yv *d, Yv *e, long ln, long cl);
Yv *block6(Yv *a, Yv *b, Yv *c, Yv *d, Yv *e, Yv *f, long ln, long cl);
Yv *gen_incdec(Yv *st, Yv *node, int dropped);
Yv *gen_incdec_desugar(Yv *st, Yv *node, int dropped);
Yv *gen_opassign_desugar(Yv *st, Yv *node, int dropped);
Yv *gen_incdec_end(Yv *st, Yv *bind, Yv *d2, Yv *asg, int dropped,
                   long ln, long cl);
Yv *place_value_type(Yv *t);
Yv *gen_opassign(Yv *st, Yv *node, int dropped);
/* maps (the section at the end of the file) */
Yv *n_str(Yv *v, long line, long col);
Yv *n_bool(Yv *v, long line, long col);
Yv *n_dot(Yv *obj, Yv *key, long line, long col);
Yv *n_idx(Yv *arr, Yv *idx, long line, long col);
Yv *n_bin(Yv *op, Yv *l, Yv *r, long line, long col);
Yv *n_not(Yv *e, long line, long col);
Yv *n_if(Yv *c, Yv *t, Yv *e, long ln, long cl);
Yv *n_while(Yv *c, Yv *b, long ln, long cl);
Yv *n_decl(Yv *name, Yv *v, long ln, long cl);
Yv *n_assign(Yv *name, Yv *v, long ln, long cl);
Yv *block_of(Yv *sts, long ln, long cl);
Yv *gen_maplit(Yv *st, Yv *node);
int is_map_read(Yv *st, Yv *e);
int is_none_id(Yv *e);
Yv *map_scan(Yv *t, long ln, long cl);
Yv *gen_map_get(Yv *st, Yv *node, Yv *mode);
Yv *gen_map_set(Yv *st, Yv *node);
Yv *map_key_repr(Yv *node, Yv *kt, long ln, long cl);
Yv *gen_map_repr(Yv *st, Yv *arg, Yv *t);
Yv *gen_opassign_arith(Yv *st, Yv *node, int dropped);
Yv *place_read_id(Yv *tgt, Yv *t1, long ln, long cl);
Yv *place_arr(Yv *tgt, Yv *t1, long ln, long cl);
Yv *place_read_idx(Yv *tgt, Yv *t1, long ln, long cl);
Yv *place_read_dot(Yv *tgt, Yv *t1, long ln, long cl);
Yv *gen_place_read(Yv *tgt, Yv *t1, long ln, long cl);
Yv *place_asg_id(Yv *tgt, Yv *valnode, Yv *t1, long ln, long cl);
Yv *place_asg_idx(Yv *tgt, Yv *valnode, Yv *t1, long ln, long cl);
Yv *place_asg_dot(Yv *tgt, Yv *valnode, Yv *t1, long ln, long cl);
Yv *gen_place_assign(Yv *tgt, Yv *valnode, Yv *t1, long ln, long cl);
Yv *place_bind_id(Yv *tgt, Yv *t1, long ln, long cl);
Yv *place_bind_idx_id(Yv *tgt, Yv *t1, long ln, long cl);
Yv *place_bind_idx_nest(Yv *tgt, Yv *t1, long ln, long cl);
Yv *place_bind_idx(Yv *tgt, Yv *t1, long ln, long cl);
Yv *place_bind_dot(Yv *tgt, Yv *t1, long ln, long cl);
Yv *gen_place_bind(Yv *tgt, Yv *t1, long ln, long cl);
Yv *gen_opassign_arr(Yv *st, Yv *node, int dropped);
Yv *gen_idxassign(Yv *st, Yv *node);
Yv *gen_val_tostr_rax(Yv *st, Yv *t, Yv *path);
static Yv *path_push(Yv *path, Yv *t);
Yv *gen_acc_cat_rax(Yv *st, long aoff);
Yv *gen_map_repr_rax(Yv *st, Yv *t, Yv *path);
Yv *gen_arr_tostr_rax(Yv *st, Yv *elty, Yv *path);
Yv *gen_acc_cat_slot(Yv *st, long off, Yv *s);
long elem_bytes(Yv *t);
long arr_elem_bytes(Yv *t);
long ptr_width(Yv *t);
Yv *elem_load(Yv *st, long esz, long base, long idx, long dst);
Yv *elem_store_rdx(Yv *st, long esz, long base, long idx);
Yv *elem_store_rdx_const(Yv *st, long esz, long base, long k);
long arr_alloc_size(long esz, long n);
long arr_header_size(void);
Yv *gen_dot(Yv *st, Yv *node);
Yv *gen_prop(Yv *st, Yv *obj, Yv *key, long line, long col);
Yv *gen_dot_rec(Yv *st, Yv *dobj, Yv *dkey, Yv *t);
long rec_field_idx(Yv *t, Yv *key);
Yv *rec_field_type(Yv *t, Yv *key);
Yv *gen_array(Yv *st, Yv *node);
Yv *gen_array_esz(Yv *st, Yv *node, long esz, Yv *ety);
Yv *gen_len(Yv *st, Yv *node);
Yv *gen_push(Yv *st, Yv *node);
Yv *gen_push_all(Yv *st, Yv *node);
Yv *gen_opt_val(Yv *st, Yv *node);
Yv *gen_some(Yv *st, Yv *node);
Yv *gen_box_rax(Yv *st);
int some_of_lit(Yv *node);
Yv *gen_is_some(Yv *st, Yv *node);
Yv *gen_unwrap(Yv *st, Yv *node);
Yv *gen_trim(Yv *st, Yv *node);
Yv *gen_prepend(Yv *st, Yv *node);
Yv *gen_byte_at(Yv *st, Yv *node);
Yv *gen_ord(Yv *st, Yv *node);
Yv *gen_chr(Yv *st, Yv *node);
Yv *gen_tonum(Yv *st, Yv *node);
Yv *gen_tostring(Yv *st, Yv *node);
long fmt_code(Yv *f, long kind, long ty);
Yv *fmt_push(Yv *st, long v);
Yv *gen_index_of(Yv *st, Yv *node, int last);
Yv *gen_join(Yv *st, Yv *node);
Yv *gen_join_conv(Yv *st, Yv *node, Yv *tostr_fn, long esz);
Yv *gen_split(Yv *st, Yv *node);
Yv *gen_puts(Yv *st, Yv *node);
Yv *gen_eputs(Yv *st, Yv *node);
Yv *gen_clock_us(Yv *st, Yv *node);
Yv *gen_heap_used(Yv *st, Yv *node);
Yv *gen_sleep(Yv *st, Yv *node);
Yv *gen_sync_new(Yv *st, Yv *node);
Yv *gen_lock(Yv *st, Yv *node, int attempt);
Yv *gen_call_top(Yv *st);
Yv *gen_exit(Yv *st, Yv *node);
Yv *gen_argv(Yv *st, Yv *node);
Yv *gen_store(Yv *st, Yv *node);
Yv *emit_one_fn(Yv *st, Yv *label, long fuid, Yv *func, int is_main,
                int want_argv, Yv *captypes, Yv *selfname);
Yv *infer_fn_ret(Yv *st, Yv *func);
Yv *func_type(Yv *func);
Yv *func_type_in(Yv *st, Yv *func);
Yv *find_dup(Yv *stmts, Yv *origin);
Yv *top_def_name(Yv *s);
Yv *top_name_in(Yv *s, Yv *origin);
Yv *top_def_name_go(Yv *s);
Yv *global_decls(Yv *stmts);
Yv *decl_name(Yv *d);
Yv *decl_type(Yv *d);
Yv *decl_value(Yv *d);
Yv *global_entries(Yv *st, Yv *gdecls, long gbase);
Yv *app_cells(Yv *gl, Yv *stmts);
Yv *capturing_defs(Yv *defs, Yv *gnames);
Yv *fix_fn_types(Yv *st, Yv *hdefs, Yv *only);
int ret_omitted(Yv *func);
Yv *fn_ptypes(Yv *func);
int reads_any(Yv *func, Yv *names);
Yv *phase_end(Yv *times, Yv *name, long t0, long h0);
Yv *unit_empty(Yv *name);
Yv *externs_none(void);
Yv *std_unit_src(Yv *name);
long std_unit_base(Yv *name);
int std_unit_bound(Yv *name);
Yv *std_unit_names(void);
Yv *std_units(Yv *names, Yv *pack);
Yv *std_compile(Yv *name, Yv *ext);
Yv *export_name(Yv *name);
Yv *unit_exports(Yv *stmts, Yv *hdefs, Yv *fns);
int pkg_base(long base);
Yv *pkg_exports(Yv *xs, Yv *gl);
Yv *unit_dfl(Yv *stmts, Yv *origin);
Yv *dfl_codes(Yv *func);
Yv *lit_code(Yv *d);
Yv *lit_text(Yv *d);
Yv *lit_neg_text(Yv *d);
Yv *lit_decode(Yv *c);
Yv *compile_unit(Yv *ast, Yv *imports, Yv *origin, int debug, long wlevel,
                 Yv *name, long base, Yv *xt);
Yv *link_locs(Yv *body, long file);
Yv *rodata_intern(Yv *pieces, Yv *allrod, Yv *refs);
Yv *relabel_dups(Yv *body, Yv *m, Yv *dup_new);
Yv *link_units(Yv *std, Yv *deps, Yv *prog);
Yv *pack_version(void);
Yv *obj_version(void);
Yv *pack_put(Yv *out, Yv *s);
Yv *pack_strs(Yv *out, Yv *xs);
static Yv *unpack_body(Yv *blob);   /* a pack body's items, decoded when kept */
Yv *tcode(Yv *t);
Yv *tcode_go(Yv *out, Yv *t);
Yv *tcode_list(Yv *out, Yv *ts);
Yv *tdecode(Yv *s);
Yv *tdecode_go(Yv *cur);
Yv *tdecode_list(Yv *cur);
Yv *pack_iface(Yv *out, Yv *unit);
Yv *pack_unit_fields(Yv *unit);
Yv *std_pack(Yv *units);
long pack_len(Yv *cur);
Yv *pack_get(Yv *cur);
long pack_num(Yv *cur);
Yv *pack_get_strs(Yv *cur);
Yv *unit_read(Yv *cur, Yv *name, int bound);
Yv *std_unpack(Yv *pack, Yv *names);
Yv *unit_obj(Yv *unit, Yv *key);
Yv *unit_unobj(Yv *text, Yv *key);
Yv *unit_iface(Yv *unit);
Yv *unit_externs(Yv *std, Yv *snames, Yv *deps, Yv *pkgs);
Yv *compile_package(Yv *ast, Yv *nr, Yv *name, long base, long wlevel,
                    Yv *std, Yv *deps);
Yv *emit_program(Yv *ast, Yv *nr, int debug, long wlevel, Yv *std, Yv *deps);

/* ── native import resolution ───────────────────────────────────────────
 * An import is a COMPILE-TIME text splice, and both compilers splice the
 * same way: `import io from "path"` inlines the module's source in place and
 * drops its `export` line. References `io.x` are rewritten to plain `x` by
 * strip_namespaces (AST-level, so strings are untouched). Module top-levels
 * must be defs; a def that replaces one from another file is a loud error
 * (find_dup). A module imported by NAME (`import fs;`, std_resolve) keeps
 * its own scope instead: rename.y binds its top-level names as `fs.x`,
 * which is how the importer spells them (the origin map's `mods`).
 *
 * The ORIGIN MAP says where each line of the spliced program came from:
 * line i + 1 is line `line[i]` of file `files[file[i]]`. files[0] is the
 * program itself (`root`, the path the driver was given), then the
 * imported modules in splice order; `nuser` counts them all (the std
 * library is no part of the text any more -- it is linked as separate
 * units, see std_units). Error positions are printed through it (ycc.c
 * print_native_errors), and find_dup tells files apart by it. mods[k]
 * is the module files[k] was imported as by name (`import fs;`: "fs"),
 * "" for the program and the files imported by path. */

Yv *native_resolve(Yv *src, Yv *base_dir, long depth) {
    return native_resolve_x(src, base_dir, depth, 1, ys(""));
}

/* `std` lists the std units the program links, in link order: prelude,
 * exec, str, rt (std_units compiles them). allow_exec = false is
 * `ycc --no-exec`: exec is left out, so `exec(...)` fails with
 * "undefined function" and the binary has no path to a shell at all. */
Yv *native_resolve_x(Yv *src, Yv *base_dir, long depth, int allow_exec,
                     Yv *root) {
    res_pkgs = yav(0);
    res_roots = yav(0);
    return resolve_unit(src, base_dir, depth, allow_exec, root);
}

/* Resolve one unit of a package build. A bare import naming one of
 * `pkgs` is a linked package dependency rather than a spliced source
 * file; `roots` are searched for ordinary module imports. */
Yv *native_resolve_pk(Yv *src, Yv *base_dir, int allow_exec, Yv *root,
                      Yv *pkgs, Yv *roots) {
    res_pkgs = pkgs;
    res_roots = roots;
    return resolve_unit(src, base_dir, 0, allow_exec, root);
}

/* Resolve one program or package unit, collecting its spliced imports,
 * origin map, std dependencies, and linked package dependencies. */
Yv *resolve_unit(Yv *src, Yv *base_dir, long depth, int allow_exec,
                 Yv *root) {
    res_used = yav(0);
    /* NOTE: seen-threading wrapper (see native_resolve_seen): asm.y imports
     * enc64 as `enc` AND elf.y imports enc64 as `elfenc`; without dedup the
     * encoder splices twice and every enc64 def collides (find_dup). */
    Yv *r = native_resolve_seen(src, base_dir, depth, yav(0), yav(0), 0);
    Yv *rsrc = ys_join(yr_get(r, "lines"), ys("\n"));
    Yv *rimports = yr_get(r, "imports");
    Yv *files = yav(1, root);
    Yv *rseen = yr_get(r, "seen");
    long fi = 0;
    while (fi < yv_len(rseen)) {
        files = ya_push(files, ya_get(rseen, fi));
        fi = fi + 1;
    }
    Yv *mods = yav(1, ys(""));
    Yv *rsmods = yr_get(r, "smods");
    fi = 0;
    while (fi < yv_len(rsmods)) {
        mods = ya_push(mods, ya_get(rsmods, fi));
        fi = fi + 1;
    }
    Yv *origin = yr(5, "files", files, "nuser", yv_long(yv_len(files)),
                    "file", yr_get(r, "ofile"), "line", yr_get(r, "oline"),
                    "mods", mods);
    /* What the name checks below search: the program's own text, in one
     * pass for all three name lists (words_seen). No std unit is
     * searched: rt and str.y call none of the trigger names, and exec.y's
     * one call into another unit (y_stdin_sync, a prelude def) is why
     * linking exec also links the prelude. */
    Yv *pn = prelude_names();
    Yv *xn = exec_names();
    Yv *sn = str_names();
    Yv *names = yav(0);
    long ni = 0;
    while (ni < yv_len(pn)) {
        names = ya_push(names, ya_get(pn, ni));
        ni = ni + 1;
    }
    ni = 0;
    while (ni < yv_len(xn)) {
        names = ya_push(names, ya_get(xn, ni));
        ni = ni + 1;
    }
    ni = 0;
    while (ni < yv_len(sn)) {
        names = ya_push(names, ya_get(sn, ni));
        ni = ni + 1;
    }
    Yv *seen = words_seen(rsrc, names);
    long px = yv_len(pn) + yv_len(xn);
    /* std/prelude.y, std/exec.y and std/str.y are linked only when the
     * program actually mentions one of their names -- otherwise every
     * binary would carry code it never calls. str.y's names count only
     * in method-call form, `.name(`: a helper-backed string method cannot
     * be reached any other way, so a variable called `lines` or a field
     * `r.count` links nothing. The last slot of seen stands for the
     * y_fmt_* helpers: an f-string field with a format spec sets it to 2
     * (words_scan). */
    int want_prelude = seen_any(seen, 0, yv_len(pn), 1);
    int want_exec = 0;
    if (allow_exec) {
        if (seen_any(seen, yv_len(pn), px, 1)) {
            want_exec = 1;
            want_prelude = 1;
            ;
        }
        ;
    }
    Yv *std = yav(0);
    if (want_prelude) {
        std = ya_push(std, ys("prelude"));
        ;
    }
    if (want_exec) {
        std = ya_push(std, ys("exec"));
        ;
    }
    /* str is linked into EVERY program too, for the same reason rt is:
     * y_float_tostr (the runtime's float printer, arch_x64.y) calls std's
     * y_fmt_f, which writes a double's exact decimal value and rounds half to
     * even, so print(x) and f"{x:.6f}" give the same text as C's printf. The
     * link costs nothing in the output -- prune_bodies drops whatever the
     * program does not reach (hello.y is 8312 bytes either way) -- and with
     * the std pack it is one precompiled unit. */
    std = ya_push(std, ys("str"));
    /* The runtime library (std/rt.y) is linked into EVERY program:
     * generated code calls into it by fixed label (`call y_print_long`),
     * so there is no name to test for. Unused helpers cost nothing in the
     * output -- prune_bodies drops them at link time. */
    std = ya_push(std, ys("rt"));
    return yr(5, "src", rsrc, "imports", rimports, "origin", origin,
              "std", std, "pkgs", res_used);
}

/* Which file line `ln` of the spliced program came from (0, the program
 * itself, when the map does not cover it). */
long origin_file(Yv *o, long ln) {
    Yv *f = yr_get(o, "file");
    if (ln >= 1 && ln <= yv_len(f)) {
        return yv_l(ya_get(f, ln - 1));
    } else {
        return 0;
    }
}

/* Line `ln` of the spliced program as its file shows it: "path:line", or
 * just "line" in the program's own file when `bare` (error positions keep
 * the plain `line:col` form there). A line past the end of the map (the
 * end of the input) counts on from the last line it holds. */
Yv *origin_at(Yv *o, long ln, int bare) {
    Yv *f = yr_get(o, "file");
    Yv *l = yr_get(o, "line");
    long n = yv_len(f);
    if (ln < 1 || n == 0) {
        return ys_long(ln);
    } else {
        long k = ln;
        if (k > n) {
            k = n;
            ;
        }
        long fid = yv_l(ya_get(f, k - 1));
        Yv *at = ys_long(yv_l(ya_get(l, k - 1)) + ln - k);
        if (fid == 0 && bare) {
            return at;
        } else {
            return ys_cat(ys_cat(ya_get(yr_get(o, "files"), fid), ys(":")),
                          at);
        }
    }
}

/* Names std/prelude.y defines. A program that mentions none of them gets
 * no prelude at all, so a hello-world binary stays the size it was.
 * These are the TRIGGER names native_resolve_x searches the program for;
 * a file may define more -- std/exec.y also defines exit_status, which
 * only exec() calls. */
Yv *prelude_names(void) {
    Yv *out = yav(0);
    out = ya_push(out, ys("readline"));
    out = ya_push(out, ys("clear_eof"));
    out = ya_push(out, ys("y_stdin_sync"));
    return out;
}

Yv *exec_names(void) {
    return ya_push(yav(0), ys("exec"));
}

/* The string methods std/str.y implements (types.y str_method maps each
 * to its y_str_* helper). They count only in method-call form, `s.name(`
 * (words_seen). The builtin-backed ones (split, trim, ...) need no splice,
 * so they are not here. */
Yv *str_names(void) {
    Yv *out = yav(0);
    out = ya_push(out, ys("trim_start"));
    out = ya_push(out, ys("trim_end"));
    out = ya_push(out, ys("lstrip"));
    out = ya_push(out, ys("rstrip"));
    out = ya_push(out, ys("pad_left"));
    out = ya_push(out, ys("pad_right"));
    out = ya_push(out, ys("center"));
    out = ya_push(out, ys("starts_with"));
    out = ya_push(out, ys("ends_with"));
    out = ya_push(out, ys("contains"));
    out = ya_push(out, ys("count"));
    out = ya_push(out, ys("replace"));
    out = ya_push(out, ys("upper"));
    out = ya_push(out, ys("lower"));
    out = ya_push(out, ys("repeat"));
    out = ya_push(out, ys("lines"));
    return out;
}

/* An embedded std file, newline-terminated (as every source file the
 * compiler reads should be). */
Yv *std_text(Yv *s) {
    if (ys_eq_lit(ys_slice_from(s, yv_len(s) - 1), "\n")) {
        return s;
    } else {
        return ys_cat(s, ys("\n"));
    }
}

/* Which trigger names the program mentions, in ONE pass over its text
 * however many names there are. seen[k] is 0 when names[k] does not occur
 * as a word of code, 1 when it does, and 2 when it also occurs in
 * method-call form, `.name(` (blanks and comments allowed in between).
 *
 * Textual, deliberately: it runs before tokenizing. It skips what the
 * lexer skips -- blanks, line and non-nesting block comments --
 * and the insides of string literals: `"..."`, and `'...'`, since outside
 * a literal or a comment a `'` only ever opens `b'..'` or `c'..'`; a
 * backslash escapes the byte after it. Whole words only: `executable` is
 * not `exec`, nor `counter` `count`. Each of those rules fixed a real
 * failure of the scan it replaced (an index_of per name over the text
 * with comments stripped first):
 *   - a comment containing `exec` spliced the whole fork/execve chunk
 *     into the binary (the audit found /bin/sh rodata and ~9 extra uids
 *     in a program that never calls exec);
 *   - after a block comment the old strip dropped the rest of the text,
 *     and a `//` inside a string literal ("http://") the rest of its
 *     line, so a readline() there was missed: "undefined function
 *     'readline'";
 *   - 20 whole-text index_of scans were 10% of a self-compile.
 * A false positive still only costs compile time and an unused function
 * in the output; a miss is a compile error.
 *
 * One more slot than names: seen[len(names)] is 2 when an f-string has a
 * field with a format spec (words_scan). */
Yv *words_seen(Yv *code, Yv *names) {
    Yv *seen = yav(0);
    long k = 0;
    while (k <= yv_len(names)) {
        seen = ya_push(seen, yv_long(0));
        k = k + 1;
        ;
    }
    words_scan(code, 0, yv_len(code), names, seen);
    return seen;
}

/* words_seen's pass over code[lo:n], marking seen in place. The fields of
 * an f-string are code: lexer.y fstr_walk finds them as the lexer does,
 * and each is scanned on its own. */
long words_scan(Yv *code, long lo, long n, Yv *names, Yv *seen) {
    long i = lo;
    /* the first byte of the last token of code (blanks and comments skip),
     * and a name just seen after a `.`, waiting for its `(` */
    long prev = 0;
    long pend = 0 - 1;
    while (i < n) {
        long c = ys_byte_at(code, i);
        if (blank_byte(c)) {
            i = i + 1;
            ;
        } else if (c == 47 && i + 1 < n && ys_byte_at(code, i + 1) == 47) {
            /* `//`: up to the newline */
            i = i + 2;
            while (i < n && ys_byte_at(code, i) != 10) {
                i = i + 1;
                ;
            }
            ;
        } else if (c == 47 && i + 1 < n && ys_byte_at(code, i + 1) == 42) {
            /* Block comment: past its first closing marker */
            i = i + 2;
            int open = 1;
            while (open && i < n) {
                if (ys_byte_at(code, i) == 42 && i + 1 < n &&
                    ys_byte_at(code, i + 1) == 47) {
                    open = 0;
                    i = i + 1;
                    ;
                }
                i = i + 1;
                ;
            }
            ;
        } else {
            if (pend >= 0) {
                if (c == 40) {
                    ya_set(seen, pend, yv_long(2));
                    ;
                }
                pend = 0 - 1;
                ;
            }
            if (c == 34 || c == 39) {
                /* A string literal: past its closing quote */
                i = i + 1;
                int open = 1;
                while (open && i < n) {
                    long d = ys_byte_at(code, i);
                    if (d == 92) {
                        i = i + 2;
                        ;
                    } else if (d == c) {
                        open = 0;
                        i = i + 1;
                        ;
                    } else {
                        i = i + 1;
                        ;
                    }
                    ;
                }
                ;
            } else if (word_byte(c)) {
                long j = i + 1;
                while (j < n && word_byte(ys_byte_at(code, j))) {
                    j = j + 1;
                    ;
                }
                if (j == i + 1 && c == 102 && j < n &&
                    ys_byte_at(code, j) == 34) {
                    /* f"...": the fields, and whether one has a spec */
                    Yv *w = fstr_walk(code, j);
                    Yv *fs = yr_get(w, "fields");
                    long f = 0;
                    while (f < yv_len(fs)) {
                        words_scan(code, yv_l(ya_get(fs, f)),
                                   yv_l(ya_get(fs, f + 1)), names, seen);
                        if (yv_l(ya_get(fs, f + 3)) >
                            yv_l(ya_get(fs, f + 2))) {
                            ya_set(seen, yv_len(names), yv_long(2));
                            ;
                        }
                        f = f + 4;
                        ;
                    }
                    i = yv_l(yr_get(w, "end"));
                    ;
                } else {
                    long m = 0;
                    while (m < yv_len(names)) {
                        Yv *nm = ya_get(names, m);
                        if (yv_len(nm) == j - i && word_at(code, i, nm)) {
                            if (yv_l(ya_get(seen, m)) == 0) {
                                ya_set(seen, m, yv_long(1));
                                ;
                            }
                            if (prev == 46) {
                                pend = m;
                                ;
                            }
                            ;
                        }
                        m = m + 1;
                        ;
                    }
                    i = j;
                    ;
                }
                ;
            } else {
                i = i + 1;
                ;
            }
            prev = c;
            ;
        }
        ;
    }
    return 0;
}

/* A byte of an identifier-shaped word (the lexer's isalnum: letters,
 * digits, `_`). */
int word_byte(long c) {
    return (c >= 97 && c <= 122) || (c >= 65 && c <= 90) ||
           (c >= 48 && c <= 57) || c == 95;
}

/* A blank as the lexer skips it (its isspace: space, tab, LF, CR). */
int blank_byte(long c) {
    return c == 32 || c == 9 || c == 10 || c == 13;
}

/* Whether code[i:i + len(nm)] is nm (the caller checked the length). */
int word_at(Yv *code, long i, Yv *nm) {
    int ok = 1;
    long k = 0;
    while (ok && k < yv_len(nm)) {
        if (ys_byte_at(code, i + k) != ys_byte_at(nm, k)) {
            ok = 0;
            ;
        }
        k = k + 1;
        ;
    }
    return ok;
}

/* Whether any of seen[lo..hi) reaches `level` (see words_seen). */
int seen_any(Yv *seen, long lo, long hi, long level) {
    int r = 0;
    long i = lo;
    while (i < hi) {
        if (yv_l(ya_get(seen, i)) >= level) {
            r = 1;
            ;
        }
        i = i + 1;
        ;
    }
    return r;
}

/* Collapse "/./" segments so the same file resolves to one key no matter
 * how deep the import nesting is (base dirs accumulate "/." per level:
 * "ycc/././enc64.y" vs "ycc/./././enc64.y"). Deterministic, so same-file
 * inputs always yield the same key (sufficient for seen-dedup). */
Yv *norm_path(Yv *p) {
    Yv *parts = ys_split(p, ys("/"));
    Yv *out = yav(0);
    long i = 0;
    while (i < yv_len(parts)) {
        Yv *seg = ya_get(parts, i);
        if (ys_eq_lit(seg, ".")) {
            ;
        } else {
            out = ya_push(out, seg);
            ;
        }
        i = i + 1;
    }
    return ys_join(out, ys("/"));
}

/* Where full is in seen (-1: nowhere). */
long seen_index(Yv *seen, Yv *full) {
    long at = -1;
    long i = 0;
    while (at < 0 && i < yv_len(seen)) {
        if (ys_eq(ya_get(seen, i), full)) {
            at = i;
        }
        i = i + 1;
    }
    return at;
}

int seen_has(Yv *seen, Yv *full) {
    long i = 0;
    int found = 0;
    while (i < yv_len(seen)) {
        Yv *e = ya_get(seen, i);
        if (ys_eq(e, full)) {
            found = 1;
            ;
        }
        i = i + 1;
    }
    return found;
}

/* ── optional std modules ─────────────────────────────────────────────── */
/* `import net;` (no `from`) pulls in a module by NAME instead of by path:
 * an optional std library (net, ui, ...) or a project-local one. A file
 * next to the importer wins (so a project can vendor or shadow a module),
 * then the compiler's own std library:
 *     <importer dir>/<name>.y        <importer dir>/std/<name>.y
 *     ./std/<name>.y                 ./src/y/std/<name>.y
 *     <ycc dir>/std/<name>.y         <ycc dir>/src/y/std/<name>.y
 *     <ycc dir>/../src/y/std/<name>.y
 * The file found is spliced like `import x from "path"` and keeps its own
 * scope: its defs are `net.listen_tcp` and friends (rename.c). */

Yv *dir_of(Yv *p) {
    long s = ys_last_index_of(p, ys("/"));
    if (s < 0) {
        return ys("");
    } else {
        return ys_slice(p, 0, s);
    }
}

/* The directory this compiler runs from: /proc/self/exe (readlink), so a
 * compiler found through PATH still finds its std units next to itself --
 * argv()[0] is then just "ycc" and dir_of("ycc") is empty, which is how
 * `PATH=... ycc prog.y` failed to find fs with the units sitting beside the
 * binary. argv()[0] stays the fallback: a host with no /proc, and a binary
 * replaced while it runs (the link then names a path that may be gone, which
 * the candidates simply miss).
 *
 * The Y twin writes the link into a [byte; 4096] and reads it back with
 * from_bytes; a C buffer and ys_n are the same bytes read as a string. */
static Yv *self_dir(void) {
    Yv *by_argv = ys("");
    Yv *av = argv_();
    if (yv_len(av) > 0) { by_argv = dir_of(ya_get(av, 0)); }
    char buf[4096];
    long n = syscall(SYS_readlink, "/proc/self/exe", buf, sizeof(buf));
    if (n > 0) {
        Yv *d = dir_of(ys_n((const char *)buf, (size_t)n));
        if (yv_len(d) > 0) { return d; }
    }
    return by_argv;
}

Yv *std_resolve(Yv *name, Yv *base_dir) {
    Yv *cands = yav(0);
    cands = ya_push(cands,
                    ys_cat(ys_cat(ys_cat(base_dir, ys("/")), name), ys(".y")));
    cands = ya_push(
        cands, ys_cat(ys_cat(ys_cat(base_dir, ys("/std/")), name), ys(".y")));
    long ri = 0;
    while (ri < yv_len(res_roots)) {
        Yv *rr = ya_get(res_roots, ri);
        cands = ya_push(cands,
                        ys_cat(ys_cat(ys_cat(rr, ys("/")), name), ys(".y")));
        ri = ri + 1;
    }
    cands = ya_push(cands, ys_cat(ys_cat(ys("std/"), name), ys(".y")));
    cands = ya_push(cands, ys_cat(ys_cat(ys("src/y/std/"), name), ys(".y")));
    Yv *d = self_dir();
    if (yv_len(d) > 0) {
        cands = ya_push(
            cands, ys_cat(ys_cat(ys_cat(d, ys("/std/")), name), ys(".y")));
        cands = ya_push(cands, ys_cat(ys_cat(ys_cat(d, ys("/src/y/std/")), name),
                                      ys(".y")));
        cands = ya_push(cands, ys_cat(ys_cat(ys_cat(d, ys("/../src/y/std/")),
                                             name),
                                      ys(".y")));
        ;
    }
    Yv *found = ys("");
    long i = 0;
    while (i < yv_len(cands)) {
        if (yv_len(found) == 0) {
            Yv *c = ya_get(cands, i);
            if (yv_is_none(read_file(c))) {
                ;
            } else {
                found = norm_path(c);
                ;
            }
            ;
        }
        i = i + 1;
    }
    return found;
}

/* The program text `src` of file `fid` (its index in the origin map's
 * files: 0 for the program itself, k for seen[k - 1]) with its imports
 * spliced in, as lines; ofile/oline map each one back (see the origin map
 * above native_resolve), and smods[k] is the module seen[k] was imported
 * as by name ("" by path). */
Yv *native_resolve_seen(Yv *src, Yv *base_dir, long depth, Yv *seen,
                        Yv *smods, long fid) {
    if (depth > 32) {
        // Fatal, like a missing module: carrying on compiled the program
        // without the rest of the chain and exited 0.
        puts_(ys("error: native import depth exceeded (cycle?)\n"));
        exit_(1);
        return yr(6, "lines", yav(0), "imports", yav(0), "seen", seen,
                  "smods", smods, "ofile", yav(0), "oline", yav(0));
    } else {
        Yv *lines = ys_split(src, ys("\n"));
        Yv *out_lines = yav(0);
        Yv *ofile = yav(0);
        Yv *oline = yav(0);
        Yv *imports = yav(0);
        long i = 0;
        long n = yv_len(lines);
        while (i < n) {
            Yv *line = ya_get(lines, i);
            Yv *trimmed = ys_trim(line);
            if (ys_eq_lit(ys_slice(trimmed, 0, 7), "import ")) {
                Yv *rest = ys_slice_from(trimmed, 7);
                long from_idx = ys_index_of(rest, ys(" from "));
                Yv *name = ys("");
                Yv *full = ys("");
                Yv *path = ys("");
                int is_pkg = 0;
                if (from_idx >= 0) {
                    name = ys_trim(ys_slice(rest, 0, from_idx));
                    Yv *path_part = ys_trim(ys_slice_from(rest, from_idx + 6));
                    if (ys_eq_lit(ys_slice_from(path_part, yv_len(path_part) - 1),
                                  ";")) {
                        path_part = ys_slice(path_part, 0, yv_len(path_part) - 1);
                        ;
                    }
                    path = ys_slice(path_part, 1, yv_len(path_part) - 1);
                    /* NOTE: normalized (see norm_path): nested base dirs
                     * accumulate "/." segments, so raw joins of the same file
                     * differ per depth and seen-dedup would never hit. */
                    full = norm_path(ys_cat(ys_cat(base_dir, ys("/")), path));
                    if (ys_eq_lit(ys_slice(path, 0, 1), "/")) {
                        full = norm_path(path);
                        ;
                    }
                    ;
                } else {
                    /* bare `import name;`: an optional std module (net, ui,
                     * ...) or a project-local one — see std_resolve above. */
                    name = ys_trim(rest);
                    if (ys_eq_lit(ys_slice_from(name, yv_len(name) - 1), ";")) {
                        name = ys_trim(ys_slice(name, 0, yv_len(name) - 1));
                        ;
                    }
                    path = name;
                    if (name_in(res_pkgs, name)) {
                        is_pkg = 1;
                        if (!name_in(res_used, name)) {
                            res_used = ya_push(res_used, name);
                            ;
                        }
                        ;
                    } else {
                        full = std_resolve(name, base_dir);
                        ;
                    }
                    ;
                }
                if (is_pkg) {
                    ;
                } else if (yv_len(name) == 0) {
                    out_lines = ya_push(out_lines, line);
                    ofile = ya_push(ofile, yv_long(fid));
                    oline = ya_push(oline, yv_long(i + 1));
                    ;
                } else if (yv_len(full) == 0) {
                    puts_(ys_cat(
                        ys_cat(ys("error: cannot find module '"), name),
                        ys("' (import name; looks next to the importer and in std/)\n")));
                    exit_(1);
                    ;
                } else {
                    Yv *mod_src = read_file(full);
                    if (yv_is_none(mod_src)) {
                        puts_(ys_cat(
                            ys_cat(ys_cat(ys_cat(ys("error: cannot open import '"),
                                                path),
                                          ys("' (resolved to '")),
                                   full),
                            ys("')\n")));
                        exit_(1);
                        ;
                    } else if (seen_has(seen, full)) {
                        /* NOTE: already spliced (see native_resolve note):
                         * record the namespace name (strip_ns needs it,
                         * unless the file is a module with its own scope)
                         * but do NOT splice the text a second time. */
                        if (ys_eq_lit(ya_get(smods, seen_index(seen, full)), "")) {
                            imports = ya_push(imports, name);
                        }
                        ;
                    } else {
                        seen = ya_push(seen, full);
                        if (from_idx >= 0) {
                            smods = ya_push(smods, ys(""));
                        } else {
                            smods = ya_push(smods, name);
                        }
                        long last_slash = ys_last_index_of(full, ys("/"));
                        Yv *mod_dir = base_dir;
                        if (last_slash >= 0) {
                            mod_dir = ys_slice(full, 0, last_slash);
                            ;
                        }
                        /* mod_src is str? (read_file returns none on missing
                         * file); the none case exited above, so unwrap
                         * here. */
                        Yv *mod_src2 = yv_unwrap(mod_src);
                        Yv *sub =
                            native_resolve_seen(mod_src2, mod_dir, depth + 1,
                                                seen, smods, yv_len(seen));
                        Yv *subns = yr_get(sub, "imports");
                        Yv *subseen = yr_get(sub, "seen");
                        seen = subseen;
                        smods = yr_get(sub, "smods");
                        /* splice the module text inline (its own imports
                         * first), and its lines' origins with it */
                        Yv *sub_lines = yr_get(sub, "lines");
                        Yv *sub_ofile = yr_get(sub, "ofile");
                        Yv *sub_oline = yr_get(sub, "oline");
                        long k = 0;
                        while (k < yv_len(sub_lines)) {
                            out_lines = ya_push(out_lines,
                                                ya_get(sub_lines, k));
                            k = k + 1;
                        }
                        k = 0;
                        while (k < yv_len(sub_ofile)) {
                            ofile = ya_push(ofile, ya_get(sub_ofile, k));
                            k = k + 1;
                        }
                        k = 0;
                        while (k < yv_len(sub_oline)) {
                            oline = ya_push(oline, ya_get(sub_oline, k));
                            k = k + 1;
                        }
                        long m = 0;
                        while (m < yv_len(subns)) {
                            imports = ya_push(imports, ya_get(subns, m));
                            m = m + 1;
                        }
                        /* a module imported by name keeps its namespace
                         * (rename.y), one imported by path is flattened */
                        if (from_idx >= 0) {
                            imports = ya_push(imports, name);
                        }
                        ;
                    }
                    ;
                }
                ;
            } else if (is_embed_decl(trimmed)) {
                out_lines = ya_push(out_lines, embed_decl(trimmed, base_dir));
                ofile = ya_push(ofile, yv_long(fid));
                oline = ya_push(oline, yv_long(i + 1));
                ;
            } else {
                /* NOTE: no empty if-arms here — keep the `;` filler.
                 * Export lines are dropped (defs are spliced; uses are
                 * rewritten by strip_namespaces). */
                if (!ys_eq_lit(ys_slice(trimmed, 0, 7), "export ")) {
                    out_lines = ya_push(out_lines, line);
                    ofile = ya_push(ofile, yv_long(fid));
                    oline = ya_push(oline, yv_long(i + 1));
                    ;
                } else {
                    if (ys_index_of(line, ys("{")) >= 0) {
                        while (ys_index_of(ya_get(lines, i), ys("}")) < 0 &&
                               i + 1 < n) {
                            i = i + 1;
                            ;
                        }
                        ;
                    }
                }
                ;
            }
            i = i + 1;
        }
        return yr(6, "lines", out_lines, "imports", imports, "seen", seen,
                  "smods", smods, "ofile", ofile, "oline", oline);
    }
}

/* ── embed ──────────────────────────────────────────────────────────────
 * `embed NAME from "path";` declares `const NAME = "<the file's bytes>";`.
 * The file is read at compile time, like an import, and the literal stays
 * on the declaration's one line, so every line number below it holds. The
 * path is relative to the file that says it (an absolute path stays as
 * is). A line that only starts with the word (`embed = 1;`) is code. */
int is_embed_decl(Yv *trimmed) {
    if (ys_eq_lit(ys_slice(trimmed, 0, 6), "embed ")) {
        return ys_index_of(trimmed, ys(" from \"")) > 6;
    } else {
        return 0;
    }
}

Yv *embed_decl(Yv *trimmed, Yv *base_dir) {
    Yv *rest = ys_slice_from(trimmed, 6);
    long from_idx = ys_index_of(rest, ys(" from \""));
    Yv *name = ys_trim(ys_slice(rest, 0, from_idx));
    Yv *path_part = ys_trim(ys_slice_from(rest, from_idx + 6));
    if (ys_eq_lit(ys_slice_from(path_part, yv_len(path_part) - 1), ";")) {
        path_part = ys_trim(ys_slice(path_part, 0, yv_len(path_part) - 1));
        ;
    }
    if (yv_len(path_part) < 2 ||
        !ys_eq_lit(ys_slice_from(path_part, yv_len(path_part) - 1), "\"")) {
        puts_(ys_cat(ys_cat(ys("error: malformed embed (embed NAME from \"path\";): "),
                            trimmed),
                     ys("\n")));
        exit_(1);
        ;
    }
    Yv *path = ys_slice(path_part, 1, yv_len(path_part) - 1);
    Yv *full = norm_path(ys_cat(ys_cat(base_dir, ys("/")), path));
    if (ys_eq_lit(ys_slice(path, 0, 1), "/")) {
        full = norm_path(path);
        ;
    }
    Yv *data = read_file(full);
    if (yv_is_none(data)) {
        puts_(ys_cat(ys_cat(ys_cat(ys_cat(ys("error: cannot embed '"), path),
                                   ys("' (resolved to '")),
                            full),
                     ys("')\n")));
        exit_(1);
        ;
    }
    return ys_cat(ys_cat(ys_cat(ys_cat(ys("const "), name), ys(" = ")),
                         quote_text(yv_unwrap(data))),
                  ys(";"));
}

/* `s` as a Y string literal on one line: a backslash, a quote and the
 * control bytes are escaped (`\n`, `\r`, `\xHH`; a tab stays as is) and
 * every other byte is copied. */
Yv *quote_text(Yv *s) {
    Yv *b = bytes_of(s);
    long n = yv_len(b);
    Yv *hex = ys("0123456789abcdef");
    Yv *out = ya_push(yav(0), ys("\""));
    long run = 0;
    long i = 0;
    while (i < n) {
        long c = yv_l(ya_get(b, i));
        Yv *esc = ys("");
        if (c == 92) {
            esc = ys("\\\\");
            ;
        } else if (c == 34) {
            esc = ys("\\\"");
            ;
        } else if (c == 10) {
            esc = ys("\\n");
            ;
        } else if (c == 13) {
            esc = ys("\\r");
            ;
        } else if (c < 32 && c != 9) {
            esc = ys_cat(ys_cat(ys("\\x"), ys_slice(hex, c / 16, c / 16 + 1)),
                         ys_slice(hex, c % 16, c % 16 + 1));
            ;
        }
        if (yv_len(esc) > 0) {
            out = ya_push(out, ys_slice(s, run, i));
            out = ya_push(out, esc);
            run = i + 1;
            ;
        }
        i = i + 1;
    }
    out = ya_push(out, ys_slice_from(s, run));
    out = ya_push(out, ys("\""));
    return ys_join(out, ys(""));
}

int is_id_b(long c) {
    // letters, digits, `_`, `$` and `.` (a module's names are qualified:
    // `yfn_12_fs.exists$3`); most bytes are lowercase, decided first
    if (c >= 97) {
        return c <= 122;
    } else if (c >= 65) {
        return c <= 90 || c == 95;
    } else if (c >= 48) {
        return c <= 57;
    } else {
        return c == 36 || c == 46;
    }
}

/* First non-blank offset in [i, hi); blank means space (the asm dialect
 * indents with spaces) or end of range. */
long skip_sp(Yv *b, long i, long hi) {
    long p = i;
    int go = 1;
    while (go) {
        if (p >= hi) {
            go = 0;
            ;
        } else {
            if (yv_l(ya_get(b, p)) == 32) {
                p = p + 1;
                ;
            } else {
                go = 0;
                ;
            }
            ;
        }
    }
    return p;
}

/* End of the identifier at offset `i` (a leading `$` — an assembly
 * immediate like `$ystr_end-ystr` — is not part of the name). */
long tok_end_b(Yv *b, long i, long hi) {
    long p = i;
    if (p < hi) {
        if (yv_l(ya_get(b, p)) == 36) {
            p = p + 1;
            ;
        }
        ;
    }
    int go = 1;
    while (go) {
        if (p >= hi) {
            go = 0;
            ;
        } else {
            if (is_id_b(yv_l(ya_get(b, p)))) {
                p = p + 1;
                ;
            } else {
                go = 0;
                ;
            }
            ;
        }
    }
    return p;
}

/* The identifier at offset `i`, or "". */
Yv *tok_at_b(Yv *text, Yv *b, long i, long hi) {
    long s = i;
    if (s < hi) {
        if (yv_l(ya_get(b, s)) == 36) {
            s = s + 1;
            ;
        }
        ;
    }
    long e = tok_end_b(b, i, hi);
    if (e > s) {
        return ys_slice(text, s, e);
    } else {
        return ys("");
    }
}

Yv *tok_push(Yv *out, Yv *t) {
    if (yv_len(t) == 0) {
        return out;
    } else {
        return ya_push(out, t);
    }
}

/* Every symbol one line [lo, hi) references: call/lea/jump operands and
 * both labels of a computed immediate (`mov $A-B, ...`). Dispatch on the
 * mnemonic — this walks every line of the emitted text, so no searching. */
Yv *line_refs_b(Yv *text, Yv *b, long lo, long hi, Yv *out, int want_jumps) {
    long p = skip_sp(b, lo, hi);
    if (p >= hi) {
        return out;
    } else {
        Yv *w = tok_at_b(text, b, p, hi);
        long we = tok_end_b(b, p, hi);
        long op = skip_sp(b, we, hi);
        if (ys_eq_lit(w, "call")) {
            out = tok_push(out, tok_at_b(text, b, op, hi));
            ;
        } else if (ys_eq_lit(w, "lea")) {
            out = tok_push(out, tok_at_b(text, b, op, hi));
            ;
        } else if (ys_eq_lit(w, "mov")) {
            long q = p;
            int go = 1;
            while (go) {
                if (q >= hi) {
                    go = 0;
                    ;
                } else {
                    if (yv_l(ya_get(b, q)) == 36) {
                        go = 0;
                        ;
                    } else {
                        q = q + 1;
                        ;
                    }
                    ;
                }
            }
            if (q < hi) {
                Yv *t = tok_at_b(text, b, q, hi);
                out = tok_push(out, t);
                long after = tok_end_b(b, q, hi);
                if (after < hi) {
                    if (yv_l(ya_get(b, after)) == 45) {
                        out = tok_push(out, tok_at_b(text, b, after + 1, hi));
                        ;
                    }
                    ;
                }
                ;
            }
            ;
        } else {
            if (want_jumps) {
                if (ys_eq_lit(ys_slice(w, 0, 1), "j")) {
                    out = tok_push(out, tok_at_b(text, b, op, hi));
                    ;
                }
                ;
            }
            ;
        }
        return out;
    }
}

/* Every symbol a byte range references, line by line. */
Yv *refs_range(Yv *text, Yv *b, long lo, long hi, Yv *out, int want_jumps) {
    long ls = lo;
    long i = lo;
    Yv *res = out;
    while (i < hi) {
        if (yv_l(ya_get(b, i)) == 10) {
            res = line_refs_b(text, b, ls, i, res, want_jumps);
            ls = i + 1;
            ;
        }
        i = i + 1;
    }
    if (ls < hi) {
        res = line_refs_b(text, b, ls, hi, res, want_jumps);
        ;
    }
    return res;
}

/* The label a line [lo, hi) defines, or "". */
Yv *label_at(Yv *text, Yv *b, long lo, long hi) {
    long p = skip_sp(b, lo, hi);
    long e = tok_end_b(b, p, hi);
    Yv *lab = ys("");
    if (e > p) {
        if (e < hi) {
            if (yv_l(ya_get(b, e)) == 58) {
                long s = p;
                if (yv_l(ya_get(b, s)) == 36) {
                    s = s + 1;
                    ;
                }
                lab = ys_slice(text, s, e);
                ;
            }
            ;
        }
        ;
    }
    return lab;
}

/* A line that is data, not code: blank lines, directives, or a bare label
 * (possibly followed by data on the same line). */
int is_data_line_b(Yv *text, Yv *b, long lo, long hi) {
    Yv *lab = label_at(text, b, lo, hi);
    long p = skip_sp(b, lo, hi);
    if (yv_len(lab) > 0) {
        p = skip_sp(b, p + 1 + yv_len(lab), hi);
        ;
    }
    if (p >= hi) {
        return 1;
    } else {
        return yv_l(ya_get(b, p)) == 46;
    }
}

/* Does a block [lo, hi) run into the next one? Only when its last
 * instruction is not a transfer; `ret`/`jmp`/`syscall` end the block (the
 * trap stubs end in an exit syscall and must not drag the file along). */
int block_falls_b(Yv *text, Yv *b, long lo, long hi) {
    long end = hi;
    int falls = 1;
    int go = 1;
    while (go) {
        /* start of the last line in [lo, end) */
        long p = lo;
        long i = lo;
        while (i < end) {
            if (yv_l(ya_get(b, i)) == 10) {
                p = i + 1;
                ;
            }
            i = i + 1;
        }
        long s = skip_sp(b, p, end);
        if (s >= end) {
            /* blank line: drop it and look at the line before */
            if (p > lo) {
                end = p - 1;
                ;
            } else {
                go = 0;
                ;
            }
            ;
        } else {
            go = 0;
            Yv *w = tok_at_b(text, b, s, end);
            if (ys_eq_lit(w, "ret")) {
                falls = 0;
                ;
            } else if (ys_eq_lit(w, "jmp")) {
                falls = 0;
                ;
            } else if (ys_eq_lit(w, "syscall")) {
                falls = 0;
                ;
            }
            ;
        }
    }
    return falls;
}

/* ── the same three questions, asked of a body's ITEMS ──────────────────
 * A body is a list of IR items, and everything the text scans answered is in
 * them: the label operands (call, jmp, jcc), the label of a `lea lbl(%rip)`
 * (the only form that can name a rodata literal), and both labels of a
 * `mov $A-B`. line_refs_b answered exactly this set from the text, so the
 * shake keeps and drops what it did. */

/* Every symbol the items `ir` reference. A `mov lbl(%rip), %rax` names a
   label too, but it did not when the answer came out of the text (the `mov`
   arm only looks for `$A-B`), and the difference is what the shake prunes
   with -- so the mnemonic decides, as it did. */
static Yv *ir_refs(Yv *ir) {
    Yv *out = yav(0);
    long at = 0;
    while (at < yv_len(ir)) {
        long f = yv_l(ya_get(ir, at));
        if (f < IR_LABEL) {
            /* a form: walk its operands by kind */
            out = ir_refs_item(ir, at, out);
        };
        at = at + IR_W;
        ;
    };
    return out;
}

static Yv *ir_refs_item(Yv *ir, long at, Yv *out) {
    long f = yv_l(ya_get(ir, at));
    Yv *fo = ir_form(f);
    Yv *kinds = yr_get(fo, "kinds");
    long wp = at + 1;
    long i = 0;
    while (i < yv_len(kinds)) {
        long k = yv_l(ya_get(kinds, i));
        if (k == O_LBL) {
            out = ir_refs_push(out, lname(ya_get(ir, wp)));
        } else if (k == O_DIFF) {
            out = ir_refs_push(out, lname(ya_get(ir, wp)));
            out = ir_refs_push(out, lname(ya_get(ir, wp + 1)));
        } else if (k == O_MEM || k == O_MEM0) {
            if (ys_eq_lit(yr_get(fo, "mn"), "lea")) {
                out = ir_refs_push(out, lname(ya_get(ir, wp + 4)));
            };
        };
        wp = wp + ir_kind_words(k);
        i = i + 1;
        ;
    };
    return out;
}

/* tok_push's rule (an empty token is no name) -- which is how the text scans
   dropped the pseudo-operands a non-label `lea` used to contribute. */
static Yv *ir_refs_push(Yv *out, Yv *nm) {
    if (yv_len(nm) == 0) {
        return out;
    } else {
        return ya_push(out, nm);
    }
}

/* Point a body's `lea` at the label its literal's text ended up with (see
   rodata_intern). Only the `lea <label>(%rip)` form can name a literal, so
   that is the only field this rewrites -- the label of an O_MEM operand under
   a `lea`. (The text version walked the body line by line; relabel_dups.) */
static Yv *ir_relabel(Yv *ir, Yv *m, Yv *dup_new) {
    long at = 0;
    while (at < yv_len(ir)) {
        long f = yv_l(ya_get(ir, at));
        if (f < IR_LABEL) {
            Yv *fo = ir_form(f);
            Yv *kinds = yr_get(fo, "kinds");
            long wp = at + 1;
            long i = 0;
            while (i < yv_len(kinds)) {
                long k = yv_l(ya_get(kinds, i));
                if (k == O_LBL) {
                    ya_set(ir, wp, yv_long(ir_relabel_one(yv_l(ya_get(ir, wp)), m, dup_new)));
                } else if (k == O_DIFF) {
                    ya_set(ir, wp, yv_long(ir_relabel_one(yv_l(ya_get(ir, wp)), m, dup_new)));
                    ya_set(ir, wp + 1, yv_long(ir_relabel_one(yv_l(ya_get(ir, wp + 1)), m,
                                                     dup_new)));
                } else if (k == O_MEM || k == O_MEM0) {
                    if (ys_eq_lit(yr_get(fo, "mn"), "lea")) {
                        ya_set(ir, wp + 4,
                               yv_long(ir_relabel_one(yv_l(ya_get(ir, wp + 4)), m, dup_new)));
                    };
                };
                wp = wp + ir_kind_words(k);
                i = i + 1;
                ;
            };
        };
        at = at + IR_W;
        ;
    };
    return ir;
}

static long ir_relabel_one(long id, Yv *m, Yv *dup_new) {
    /* The label's own length is what is cut out: the winner's label is what
       gets longer or shorter. */
    Yv *g = labmap_get(m, lname(yv_long(id)));
    if (yv_l(yr_get(g, "sec")) > 0) {
        return yv_l(lbl_new(ya_get(dup_new, yv_l(yr_get(g, "off")))));
    } else {
        return id;
    }
}

/* ── name -> index, for the tree shaker ───────────────────────────────────
 * `shake_keep` resolves one name per reference, ~191k of them per compile
 * against a few hundred names, so scanning the names each time was 24% of
 * everything ycc executes (and grew with the program). These two are thin
 * wrappers over asm.c's labmap -- the open-addressing table ycc already has
 * -- not a second implementation of it.
 *
 * labmap marks an empty slot with the empty string, and an unnamed block's
 * name IS "" (shake_refs keys keep[k] on it), so "" is not inserted. That
 * costs nothing: every key the shaker looks up is a real identifier or
 * label, because tok_push drops empty tokens when refs/roots are built.
 * The index travels in labmap's `sec` field, which labmap_get leaves at -1
 * when the name is absent -- so one read answers both questions. */

Yv *namemap_build(Yv *names) {
    Yv *m = labmap_new(yv_len(names) * 2 + 16);
    long i = 0;
    while (i < yv_len(names)) {
        Yv *nm = ya_get(names, i);
        if (yv_len(nm) > 0) {
            /* First insert wins, as a scan for the first match did. */
            Yv *r = labmap_put(m, nm, i, 0);
            m = yr_get(r, "map");
            ;
        }
        i = i + 1;
    }
    return m;
}

/* Index of `name` among the names it was built from, or -1. */
long namemap_get(Yv *m, Yv *name) {
    Yv *r = labmap_get(m, name);
    return yv_l(yr_get(r, "sec"));
}

/* The defs a unit's bodies see (EmitSt.fns: the hoisted defs, then the
 * externs, then the globals) with an index by name. No env holds them:
 * env_find and the capture scans look a name up here, where every
 * function's env used to be pre-loaded with all of them (~1.6k entries
 * in the compiler) and scanned. Of entries sharing a name the last wins,
 * as the backward env scan had it, so the index is filled from the end
 * (labmap keeps the first). */
/* `ids` is parallel to `syms`: each def's label as an id, minted by the
 * CALLER (compile_unit, once per def, where it binds the def's env entry too)
 * and passed in here. env_find's miss path runs per identifier emitted, so
 * interning there would grow the table once per lookup; and this table is
 * built four times per unit as fix_fn_types retypes the defs, so interning
 * per build was five lookups per def where one will do (measured: +1.9% of a
 * compile, most of it hash_str). */
Yv *fntab_of(Yv *syms, Yv *ids) {
    Yv *m = labmap_new(yv_len(syms) * 2 + 16);
    long i = yv_len(syms) - 1;
    while (i >= 0) {
        Yv *e = ya_get(syms, i);
        if (yv_len(yr_get(e, "name")) > 0) {
            Yv *r = labmap_put(m, yr_get(e, "name"), i, 0);
            m = yr_get(r, "map");
        }
        i = i - 1;
    }
    return yr(3, "syms", syms, "ix", m, "ids", ids);
}

/* `ids` for a Sym list: intern each label, in order. */
Yv *fntab_ids(Yv *syms) {
    Yv *ids = yav(0);
    long i = 0;
    while (i < yv_len(syms)) {
        ids = ya_push(ids, lbl_new(yr_get(ya_get(syms, i), "label")));
        i = i + 1;
    }
    return ids;
}

/* Mark every names[i] some entry of `roots` points at, then close over kept
 * blocks: their own references and (for code that runs into the next block)
 * their successor. `falls[i]` says block i falls through to block i+1. */
Yv *shake_keep(Yv *names, Yv *refs, Yv *falls, Yv *keep, Yv *roots) {
    long n = yv_len(names);
    Yv *map = namemap_build(names);
    long r = 0;
    while (r < yv_len(roots)) {
        long idx = namemap_get(map, ya_get(roots, r));
        if (idx >= 0) {
            ya_set(keep, idx, yv_bool(1));
            ;
        }
        r = r + 1;
    }
    Yv *scanned = yav(0);
    long i = 0;
    while (i < n) {
        scanned = ya_push(scanned, yv_bool(0));
        i = i + 1;
    }
    int more = 1;
    while (more) {
        more = 0;
        long b = 0;
        while (b < n) {
            if (yv_b(ya_get(keep, b))) {
                if (!(yv_b(ya_get(scanned, b)))) {
                    ya_set(scanned, b, yv_bool(1));
                    more = 1;
                    if (yv_b(ya_get(falls, b))) {
                        if (b + 1 < n) {
                            if (!(yv_b(ya_get(keep, b + 1)))) {
                                ya_set(keep, b + 1, yv_bool(1));
                                ;
                            }
                            ;
                        }
                        ;
                    }
                    Yv *rs = ya_get(refs, b);
                    long j = 0;
                    while (j < yv_len(rs)) {
                        long idx = namemap_get(map, ya_get(rs, j));
                        if (idx >= 0) {
                            if (!(yv_b(ya_get(keep, idx)))) {
                                ya_set(keep, idx, yv_bool(1));
                                ;
                            }
                            ;
                        }
                        j = j + 1;
                    }
                    ;
                }
                ;
            }
            b = b + 1;
        }
    }
    return keep;
}

/* Keep only the blocks of `text` that `root_refs` (the program's own
 * references) or another kept block reaches. Output order matches input. */
Yv *shake_refs(Yv *text, Yv *root_refs) {
    Yv *b = bytes_of(text);
    long n = yv_len(b);
    /* every label starts a block; lines before the first label (directives)
     * form a head block that is always kept */
    Yv *names = yav(0);
    Yv *starts = yav(0);
    long i = 0;
    long ls = 0;
    while (i < n) {
        if (yv_l(ya_get(b, i)) == 10) {
            Yv *lab = label_at(text, b, ls, i);
            if (yv_len(lab) > 0) {
                names = ya_push(names, lab);
                starts = ya_push(starts, yv_long(ls));
                ;
            } else {
                if (yv_len(starts) == 0) {
                    names = ya_push(names, ys(""));
                    starts = ya_push(starts, yv_long(0));
                    ;
                }
                ;
            }
            ls = i + 1;
            ;
        }
        i = i + 1;
    }
    if (ls < n) {
        Yv *lab = label_at(text, b, ls, n);
        if (yv_len(lab) > 0) {
            names = ya_push(names, lab);
            starts = ya_push(starts, yv_long(ls));
            ;
        } else {
            if (yv_len(starts) == 0) {
                names = ya_push(names, ys(""));
                starts = ya_push(starts, yv_long(0));
                ;
            }
            ;
        }
        ;
    }
    long nb = yv_len(starts);
    if (nb == 0) {
        return text;
    } else {
        /* per-block references + fall-through flags */
        Yv *refs = yav(0);
        Yv *falls = yav(0);
        long k = 0;
        while (k < nb) {
            long lo = yv_l(ya_get(starts, k));
            long hi = n;
            if (k + 1 < nb) {
                hi = yv_l(ya_get(starts, k + 1));
                ;
            }
            refs = ya_push(refs, refs_range(text, b, lo, hi, yav(0), 1));
            if (block_falls_b(text, b, lo, hi)) {
                if (is_data_line_b(text, b, lo, hi)) {
                    falls = ya_push(falls, yv_bool(0));
                    ;
                } else {
                    falls = ya_push(falls, yv_bool(1));
                    ;
                }
                ;
            } else {
                falls = ya_push(falls, yv_bool(0));
                ;
            }
            k = k + 1;
        }
        Yv *keep = yav(0);
        k = 0;
        while (k < nb) {
            if (yv_len(ya_get(names, k)) == 0) {
                keep = ya_push(keep, yv_bool(1));
                ;
            } else {
                keep = ya_push(keep, yv_bool(0));
                ;
            }
            k = k + 1;
        }
        keep = shake_keep(names, refs, falls, keep, root_refs);
        /* reassemble kept blocks (their byte ranges), in order */
        Yv *pieces = yav(0);
        k = 0;
        while (k < nb) {
            if (yv_b(ya_get(keep, k))) {
                long lo = yv_l(ya_get(starts, k));
                long hi = n;
                if (k + 1 < nb) {
                    hi = yv_l(ya_get(starts, k + 1));
                    ;
                }
                pieces = ya_push(pieces, ys_slice(text, lo, hi));
                ;
            }
            k = k + 1;
        }
        return ys_join(pieces, ys(""));
    }
}

/* ── the arch prelude, shaken by lines ──────────────────────────────────
 * The prelude is ~1.7k lines of which a program keeps a few dozen, and
 * shaking it as text scanned all of it on every compile: two thirds of a
 * small program's compile. It comes as its lines (arch_prelude_lines):
 * labels alone at column 0, everything else indented, so its blocks are
 * found by each line's first byte, and only the blocks a program reaches
 * are scanned for references. Blocks and rules are shake_refs'.
 * PBlocks = { lines, starts, names, ix }; PShake = { text, refs }. */
Yv *prelude_blocks(Yv *lines) {
    Yv *starts = yav(0);
    Yv *names = yav(0);
    long i = 0;
    while (i < yv_len(lines)) {
        Yv *l = ya_get(lines, i);
        Yv *lab = ys("");
        if (yv_len(l) > 0 && ys_byte_at(l, 0) != 32) {
            Yv *lb = bytes_of(l);
            lab = label_at(l, lb, 0, yv_len(lb));
        }
        if (yv_len(lab) > 0) {
            names = ya_push(names, lab);
            starts = ya_push(starts, yv_long(i));
        } else if (yv_len(starts) == 0) {
            names = ya_push(names, ys(""));
            starts = ya_push(starts, yv_long(0));
        }
        i = i + 1;
    }
    return yr(4, "lines", lines, "starts", starts, "names", names, "ix",
              namemap_build(names));
}

/* Every reference the lines [lo, hi) make. */
Yv *lines_refs(Yv *lines, long lo, long hi) {
    Yv *out = yav(0);
    long i = lo;
    while (i < hi) {
        Yv *l = ya_get(lines, i);
        Yv *lb = bytes_of(l);
        out = line_refs_b(l, lb, 0, yv_len(lb), out, 1);
        i = i + 1;
    }
    return out;
}

/* Does the block of lines [lo, hi) run into the next one? block_falls_b
 * and is_data_line_b on its lines. */
int lines_fall(Yv *lines, long lo, long hi) {
    int falls = 1;
    long i = hi - 1;
    int go = 1;
    while (go && i >= lo) {
        Yv *l = ya_get(lines, i);
        Yv *lb = bytes_of(l);
        long s = skip_sp(lb, 0, yv_len(lb));
        if (s < yv_len(lb)) {
            go = 0;
            Yv *w = tok_at_b(l, lb, s, yv_len(lb));
            if (ys_eq_lit(w, "ret") || ys_eq_lit(w, "jmp") || ys_eq_lit(w, "syscall")) {
                falls = 0;
            }
        }
        i = i - 1;
    }
    if (falls) {
        Yv *l0 = ya_get(lines, lo);
        Yv *b0 = bytes_of(l0);
        Yv *lab = label_at(l0, b0, 0, yv_len(b0));
        long p = skip_sp(b0, 0, yv_len(b0));
        if (yv_len(lab) > 0) {
            p = skip_sp(b0, p + 1 + yv_len(lab), yv_len(b0));
        }
        if (p < yv_len(b0)) {
            if (yv_l(ya_get(b0, p)) == 46) {
                falls = 0;
            }
        }
    }
    return falls;
}

/* Keep the blocks `roots` (the kept bodies' references) or a kept block
 * reaches, as shake_keep does, scanning only those. */
Yv *shake_prelude(Yv *pb, Yv *roots) {
    Yv *lines = yr_get(pb, "lines");
    Yv *starts = yr_get(pb, "starts");
    Yv *names = yr_get(pb, "names");
    long nb = yv_len(starts);
    Yv *keep = yav(0);
    Yv *scanned = yav(0);
    Yv *brefs = yav(0);
    long k = 0;
    while (k < nb) {
        Yv *nm = ya_get(names, k);
        keep = ya_push(keep, yv_bool(yv_len(nm) == 0));
        scanned = ya_push(scanned, yv_bool(0));
        brefs = ya_push(brefs, yav(0));
        k = k + 1;
    }
    long r = 0;
    while (r < yv_len(roots)) {
        long idx = namemap_get(yr_get(pb, "ix"), ya_get(roots, r));
        if (idx >= 0) {
            ya_set(keep, idx, yv_bool(1));
        }
        r = r + 1;
    }
    int more = 1;
    while (more) {
        more = 0;
        long b = 0;
        while (b < nb) {
            if (yv_b(ya_get(keep, b)) && !yv_b(ya_get(scanned, b))) {
                ya_set(scanned, b, yv_bool(1));
                more = 1;
                long lo = yv_l(ya_get(starts, b));
                long hi = yv_len(lines);
                if (b + 1 < nb) {
                    hi = yv_l(ya_get(starts, b + 1));
                }
                Yv *rs = lines_refs(lines, lo, hi);
                ya_set(brefs, b, rs);
                if (b + 1 < nb && lines_fall(lines, lo, hi)) {
                    ya_set(keep, b + 1, yv_bool(1));
                }
                long j = 0;
                while (j < yv_len(rs)) {
                    long idx = namemap_get(yr_get(pb, "ix"), ya_get(rs, j));
                    if (idx >= 0) {
                        ya_set(keep, idx, yv_bool(1));
                    }
                    j = j + 1;
                }
            }
            b = b + 1;
        }
    }
    Yv *pieces = yav(0);
    Yv *out = yav(0);
    k = 0;
    while (k < nb) {
        if (yv_b(ya_get(keep, k))) {
            long lo = yv_l(ya_get(starts, k));
            long hi = yv_len(lines);
            if (k + 1 < nb) {
                hi = yv_l(ya_get(starts, k + 1));
            }
            long i = lo;
            while (i < hi) {
                pieces = ya_push(pieces, ya_get(lines, i));
                pieces = ya_push(pieces, ys("\n"));
                i = i + 1;
            }
            Yv *bk = ya_get(brefs, k);
            long j = 0;
            while (j < yv_len(bk)) {
                out = ya_push(out, ya_get(bk, j));
                j = j + 1;
            }
        }
        k = k + 1;
    }
    return yr(2, "text", ys_join(pieces, ys("")), "refs", out);
}

/* The prelude's lines, the thread runtime's after them when it is used. */
Yv *prelude_with(Yv *core, int threads) {
    if (threads) {
        Yv *out = ya_slice(core, 0, yv_len(core));
        Yv *t = arch_prelude_threads_lines();
        long i = 0;
        while (i < yv_len(t)) {
            out = ya_push(out, ya_get(t, i));
            i = i + 1;
        }
        return out;
    } else {
        return core;
    }
}

/* The references (a kept prelude's) that name a body not kept. */
Yv *unkept_refs(Yv *refs, Yv *bmap, Yv *keep) {
    Yv *out = yav(0);
    long i = 0;
    while (i < yv_len(refs)) {
        long idx = namemap_get(bmap, ya_get(refs, i));
        if (idx >= 0) {
            if (!yv_b(ya_get(keep, idx))) {
                out = ya_push(out, ya_get(refs, i));
            }
        }
        i = i + 1;
    }
    return out;
}

/* Drop function bodies nothing reaches: dead stdlib code the program never
 * calls. A body is given by its label and the labels it references
 * (body_meta). Bodies are referenced by label from other bodies AND from
 * the arch prelude (a prelude block may call a Y-side helper), so
 * `extra_roots` are the kept prelude's references to bodies (link_units).
 * Returns, per body, whether it was kept,
 * plus everything the kept ones reference — the roots for shaking the
 * arch prelude itself. */
Yv *prune_bodies(Yv *labels, Yv *refs, Yv *extra_roots) {
    long nb = yv_len(labels);
    Yv *keep = yav(0);
    Yv *falls = yav(0);
    long i = 0;
    while (i < nb) {
        keep = ya_push(keep, yv_bool(0));
        falls = ya_push(falls, yv_bool(0));
        i = i + 1;
    }
    Yv *roots = yav(0);
    long ri = 0;
    while (ri < yv_len(extra_roots)) {
        roots = ya_push(roots, ya_get(extra_roots, ri));
        ri = ri + 1;
    }
    long root = namemap_get(namemap_build(labels), ys("_start"));
    if (root >= 0) {
        roots = ya_push(roots, ys("_start"));
        ;
    }
    keep = shake_keep(labels, refs, falls, keep, roots);
    Yv *outrefs = yav(0);
    i = 0;
    while (i < nb) {
        if (yv_b(ya_get(keep, i))) {
            Yv *rs = ya_get(refs, i);
            long j = 0;
            while (j < yv_len(rs)) {
                outrefs = ya_push(outrefs, ya_get(rs, j));
                j = j + 1;
            }
            ;
        }
        i = i + 1;
    }
    return yr(2, "refs", outrefs, "keep", keep);
}

int is_all_digits(Yv *s) {
    if (yv_len(s) == 0) {
        return 0;
    } else {
        long i = 0;
        int ok = 1;
        while (i < yv_len(s)) {
            if (ys_index_of(ys("0123456789"), ys_slice(s, i, i + 1)) < 0) {
                ok = 0;
                ;
            }
            i = i + 1;
        }
        return ok;
    }
}

/* The bare runtime name behind `name`, or "" when it is not one. */
Yv *runtime_base(Yv *name) {
    if (yv_len(name) < 3) {
        return ys("");
    } else {
        if (!ys_eq_lit(ys_slice(name, 0, 2), "y_")) {
            return ys("");
        } else {
            long dollar = ys_index_of(name, ys("$"));
            if (dollar < 0) {
                return name;
            } else {
                if (is_all_digits(
                        ys_slice_from(name, dollar + 1))) {
                    return ys_slice(name, 0, dollar);
                } else {
                    return ys("");
                }
            }
        }
    }
}

Yv *fn_label_of(long uid, Yv *name) {
    Yv *base = runtime_base(name);
    if (yv_len(base) > 0) {
        return base;
    } else {
        return arch_fn_label(uid, name);
    }
}

int is_ns(Yv *name, Yv *imports) {
    long i = 0;
    int found = 0;
    while (i < yv_len(imports)) {
        if (ys_eq(ya_get(imports, i), name)) {
            found = 1;
            ;
        }
        i = i + 1;
    }
    return found;
}

/* Identity with a declared {k: str} return: normalizes multi-shape
 * expression arms (strip_*, infer rebuilds a different node kind per arm,
 * which strict branch-teq rejects) into unknown-shaped flows. Callers read
 * .k/.line/.col directly; deeper reads unify quietly (tcompat law). The
 * RUNTIME value passes through untouched (same node object). */
Yv *normnode(Yv *anode) { return anode; }

/* strip_namespaces: dot(NAME, key) with NAME an import namespace -> id(key).
 * Full AST rebuild (only dot nodes change, but uniform rebuild is
 * simplest). */

Yv *strip_list(Yv *nodes, Yv *imports) {
    Yv *out = yav(0);
    long i = 0;
    while (i < yv_len(nodes)) {
        out = ya_push(out, strip_ns(ya_get(nodes, i), imports));
        i = i + 1;
    }
    return out;
}

Yv *strip_ns(Yv *node, Yv *imports) {
    if (pkg_ns == NULL) {
        pkg_ns = yav(0);
    }
    Yv *k = yr_get(node, "k");
    if (yv_l(k) == K_dot) {
        Yv *dobj = yr_get(node, "obj");
        Yv *obj = strip_ns(dobj, imports);
        Yv *okey = yr_get(node, "key");
        Yv *oline = yr_get(node, "line");
        Yv *ocol = yr_get(node, "col");
        if (yv_l(yr_get(obj, "k")) == K_id) {
            Yv *ov = yr_get(obj, "v");
            if (is_ns(ov, imports)) {
                return normnode(yr(4, "k", yv_long(K_id), "v", okey, "line", oline,
                                   "col", ocol));
            } else if (is_ns(ov, pkg_ns)) {
                Yv *qname = ys_cat(ys_cat(ov, ys(".")), okey);
                return normnode(yr(4, "k", yv_long(K_id), "v", qname, "line",
                                  oline, "col", ocol));
            } else {
                return normnode(yr(5, "k", yv_long(K_dot), "obj", obj, "key", okey,
                                   "line", oline, "col", ocol));
            }
        } else {
            return normnode(yr(5, "k", yv_long(K_dot), "obj", obj, "key", okey,
                               "line", oline, "col", ocol));
        }
    } else if (yv_l(k) == K_un) {
        return normnode(yr(5, "k", yv_long(K_un), "op", yr_get(node, "op"), "e",
                           strip_ns(yr_get(node, "e"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (yv_l(k) == K_addr || yv_l(k) == K_deref) {
        return normnode(yr(4, "k", k, "e", strip_ns(yr_get(node, "e"), imports),
                           "line", yr_get(node, "line"), "col",
                           yr_get(node, "col")));
    } else if (yv_l(k) == K_bin) {
        return normnode(
            yr(6, "k", yv_long(K_bin), "op", yr_get(node, "op"), "l",
               strip_ns(yr_get(node, "l"), imports), "r",
               strip_ns(yr_get(node, "r"), imports), "line",
               yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (yv_l(k) == K_call) {
        return normnode(yr(5, "k", yv_long(K_call), "callee",
                           strip_ns(yr_get(node, "callee"), imports), "args",
                           strip_list(yr_get(node, "args"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (yv_l(k) == K_kw_if) {
        return normnode(yr(7, "k", yv_long(K_kw_if), "cond",
                           strip_ns(yr_get(node, "cond"), imports), "then",
                           strip_ns(yr_get(node, "then"), imports), "els",
                           strip_ns(yr_get(node, "els"), imports), "has_else",
                           yr_get(node, "has_else"), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (yv_l(k) == K_kw_while) {
        return normnode(yr(5, "k", yv_long(K_kw_while), "cond",
                           strip_ns(yr_get(node, "cond"), imports), "body",
                           strip_ns(yr_get(node, "body"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (yv_l(k) == K_block) {
        return normnode(yr(4, "k", yv_long(K_block), "stmts",
                           strip_list(yr_get(node, "stmts"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (yv_l(k) == K_decl) {
        return strip_decl(node, imports);
    } else if (yv_l(k) == K_func) {
        return normnode(yr(8, "k", yv_long(K_func), "params", yr_get(node, "params"),
                           "ptypes", yr_get(node, "ptypes"), "ret",
                           yr_get(node, "ret"), "body",
                           strip_ns(yr_get(node, "body"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col"),
                           "defs", yr_get(node, "defs")));
    } else if (yv_l(k) == K_assign) {
        return normnode(yr(5, "k", yv_long(K_assign), "name", yr_get(node, "name"),
                           "v", strip_ns(yr_get(node, "v"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (yv_l(k) == K_incdec) {
        return normnode(yr(6, "k", yv_long(K_incdec), "op", yr_get(node, "op"), "pre",
                           yr_get(node, "pre"), "tgt",
                           strip_ns(yr_get(node, "tgt"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (yv_l(k) == K_opassign) {
        return normnode(yr(6, "k", yv_long(K_opassign), "op", yr_get(node, "op"),
                           "tgt", strip_ns(yr_get(node, "tgt"), imports), "v",
                           strip_ns(yr_get(node, "v"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (yv_l(k) == K_store) {
        return normnode(yr(5, "k", yv_long(K_store), "p",
                           strip_ns(yr_get(node, "p"), imports), "v",
                           strip_ns(yr_get(node, "v"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (yv_l(k) == K_ret) {
        return normnode(yr(4, "k", yv_long(K_ret), "e",
                           strip_ns(yr_get(node, "e"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (yv_l(k) == K_array) {
        return normnode(yr(4, "k", yv_long(K_array), "elems",
                           strip_list(yr_get(node, "elems"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (yv_l(k) == K_arrrep) {
        return normnode(yr(5, "k", yv_long(K_arrrep), "v",
                           strip_ns(yr_get(node, "v"), imports), "n",
                           yr_get(node, "n"), "line", yr_get(node, "line"),
                           "col", yr_get(node, "col")));
    } else if (yv_l(k) == K_rec) {
        return normnode(yr(5, "k", yv_long(K_rec), "keys", yr_get(node, "keys"),
                           "vals", strip_list(yr_get(node, "vals"), imports),
                           "line", yr_get(node, "line"), "col",
                           yr_get(node, "col")));
    } else if (yv_l(k) == K_map) {
        return normnode(yr(5, "k", yv_long(K_map), "keys", yr_get(node, "keys"),
                           "vals", strip_list(yr_get(node, "vals"), imports),
                           "line", yr_get(node, "line"), "col",
                           yr_get(node, "col")));
    } else if (yv_l(k) == K_index) {
        return normnode(
            yr(5, "k", yv_long(K_index), "arr", strip_ns(yr_get(node, "arr"), imports),
               "idx", strip_ns(yr_get(node, "idx"), imports), "line",
               yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (yv_l(k) == K_slice) {
        return normnode(yr(6, "k", yv_long(K_slice), "arr",
                           strip_ns(yr_get(node, "arr"), imports), "lo",
                           strip_ns(yr_get(node, "lo"), imports), "hi",
                           strip_ns(yr_get(node, "hi"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (yv_l(k) == K_idxassign) {
        return normnode(yr(6, "k", yv_long(K_idxassign), "arr",
                           strip_ns(yr_get(node, "arr"), imports), "idx",
                           strip_ns(yr_get(node, "idx"), imports), "v",
                           strip_ns(yr_get(node, "v"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (yv_l(k) == K_dotassign) {
        Yv *dao = yr_get(node, "obj");
        if (yv_l(yr_get(dao, "k")) == K_id &&
            is_ns(yr_get(dao, "v"), pkg_ns)) {
            Yv *qname = ys_cat(ys_cat(yr_get(dao, "v"), ys(".")),
                               yr_get(node, "key"));
            return normnode(yr(5, "k", yv_long(K_assign), "name", qname, "v",
                               strip_ns(yr_get(node, "v"), imports), "line",
                               yr_get(node, "line"), "col",
                               yr_get(node, "col")));
        } else {
            return normnode(
                yr(6, "k", yv_long(K_dotassign), "obj", strip_ns(dao, imports),
                   "key", yr_get(node, "key"), "v",
                   strip_ns(yr_get(node, "v"), imports), "line",
                   yr_get(node, "line"), "col", yr_get(node, "col")));
        }
    } else if (yv_l(k) == K_kw_foreach) {
        return normnode(yr(6, "k", yv_long(K_kw_foreach), "name", yr_get(node, "name"),
                           "iter", strip_ns(yr_get(node, "iter"), imports),
                           "body", strip_ns(yr_get(node, "body"), imports),
                           "line", yr_get(node, "line"), "col",
                           yr_get(node, "col")));
    } else if (yv_l(k) == K_forrange) {
        return normnode(yr(7, "k", yv_long(K_forrange), "name", yr_get(node, "name"),
                           "lo", strip_ns(yr_get(node, "lo"), imports), "hi",
                           strip_ns(yr_get(node, "hi"), imports), "body",
                           strip_ns(yr_get(node, "body"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (yv_l(k) == K_kw_for) {
        return normnode(yr(7, "k", yv_long(K_kw_for), "init",
                           strip_ns(yr_get(node, "init"), imports), "cond",
                           strip_ns(yr_get(node, "cond"), imports), "step",
                           strip_ns(yr_get(node, "step"), imports), "body",
                           strip_ns(yr_get(node, "body"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (yv_l(k) == K_sliceassign) {
        return normnode(yr(7, "k", yv_long(K_sliceassign), "arr",
                           strip_ns(yr_get(node, "arr"), imports), "lo",
                           strip_ns(yr_get(node, "lo"), imports), "hi",
                           strip_ns(yr_get(node, "hi"), imports), "v",
                           strip_ns(yr_get(node, "v"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else {
        return normnode(node);
    }
}

Yv *strip_decl(Yv *node, Yv *imports) {
    if (ys_eq_lit(yr_get(node, "kind"), "def")) {
        return normnode(yr(6, "k", yv_long(K_decl), "kind", ys("def"), "name",
                           yr_get(node, "name"), "v",
                           strip_ns(yr_get(node, "v"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else {
        return normnode(yr(7, "k", yv_long(K_decl), "kind", yr_get(node, "kind"),
                           "name", yr_get(node, "name"), "typ",
                           yr_get(node, "typ"), "v",
                           strip_ns(yr_get(node, "v"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    }
}

/* ── emit state ─────────────────────────────────────────────────────────
 * st = { out, rodata, uid, fuid, loc, env, slots,
 *        self_label, end_label, fns, bodies, blabels }
 * env: FLAT list of {name, kind, off, label, mark, typ} — names are unique
 * post-rename, so no scopes or shadowing. kind: "local"|"param"|"func".
 * `label` is an id (see label identities); `mark` is the str a slot of kind
 * "boxmark"/"appmark" carries instead -- a name to match against -- and a
 * "capture"'s capture index (as text, see gen_addr). */

Yv *st_new(void) {
    return yr(15, "ir", yav(0), "txt", yav(0), "rodata", yav(0), "uid", yv_long(1), "fuid",
              yv_long(0), "loc", yv_long(1), "env", yav(0), "slots",
              yv_long(0), "temp", yv_long(0), "self_label", yv_long(-1), "end_label", yv_long(-1),
              "fns", fntab_of(yav(0), yav(0)), "bodies", yav(0), "btext", yav(0), "blabels",
              yav(0));
}

/* The state with its IR buffer (and, where it changes, its raw lines)
 * replaced: every append to a body goes through one of these, the way every
 * append to `out` went through emit. */
static Yv *st_with(Yv *st, Yv *b, Yv *txt) {
    return yr(15, "ir", b, "txt", txt, "rodata", yr_get(st, "rodata"), "uid",
              yr_get(st, "uid"), "fuid", yr_get(st, "fuid"), "loc",
              yr_get(st, "loc"), "env", yr_get(st, "env"), "slots",
              yr_get(st, "slots"), "temp", yr_get(st, "temp"), "self_label", yr_get(st, "self_label"),
              "end_label", yr_get(st, "end_label"), "fns", yr_get(st, "fns"),
              "bodies", yr_get(st, "bodies"), "btext", yr_get(st, "btext"), "blabels", yr_get(st, "blabels"));
}

static Yv *st_ir(Yv *st, Yv *b) {
    return st_with(st, b, yr_get(st, "txt"));
}

/* The DEEPEST frame the function being emitted ever needs: st.slots is a
 * stack of block depths (st_slots), so its value on the way out of a block is
 * a depth the frame has to cover whether or not the counter is there now.
 * Every allocation is either still counted when the function ends or released
 * by a block on the way, so this is the high-water mark; emit_one_fn resets it
 * and sizes the frame from it. */
static long frame_max = 0;

/* The state with the frame counter set: what a block does on the way out, so
 * the counter is a stack of depths (see gen_block_as) rather than a running
 * total of every slot the body ever took. */
static Yv *st_slots(Yv *st, long n) {
    /* A block that took no slot of its own has nothing to release, and the
     * depth it hands back is the one it was given -- which the mark already
     * covers (every allocation is marked where it is taken). */
    if (n == yv_l(yr_get(st, "slots"))) {
        return st;
    }
    long cur = yv_l(yr_get(st, "slots")) + yv_l(yr_get(st, "temp"));
    if (cur > frame_max) { frame_max = cur; }
    return yr(15, "ir", yr_get(st, "ir"), "txt", yr_get(st, "txt"), "rodata",
              yr_get(st, "rodata"), "uid", yr_get(st, "uid"), "fuid",
              yr_get(st, "fuid"), "loc", yr_get(st, "loc"), "env",
              yr_get(st, "env"), "slots", yv_long(n), "temp", yr_get(st, "temp"), "self_label",
              yr_get(st, "self_label"), "end_label", yr_get(st, "end_label"),
              "fns", yr_get(st, "fns"), "bodies", yr_get(st, "bodies"), "btext",
              yr_get(st, "btext"), "blabels", yr_get(st, "blabels"));
}

/* The state with a statement's temporaries released: they are dead once the
 * statement is (its value is in %rax or a local's slot), and the next statement
 * starts below them again -- but only as deep as the statement LIST started
 * (gen_block_as passes its own entry depth), so a block inside a statement
 * cannot free the statement's. The high-water mark goes with them, so the frame
 * still covers the deepest a single statement reached. */
static Yv *st_temp(Yv *st, long n) {
    /* a statement that took no temporary, as above */
    if (n == yv_l(yr_get(st, "temp"))) {
        return st;
    }
    long cur = yv_l(yr_get(st, "slots")) + yv_l(yr_get(st, "temp"));
    if (cur > frame_max) { frame_max = cur; }
    return yr(15, "ir", yr_get(st, "ir"), "txt", yr_get(st, "txt"), "rodata",
              yr_get(st, "rodata"), "uid", yr_get(st, "uid"), "fuid",
              yr_get(st, "fuid"), "loc", yr_get(st, "loc"), "env",
              yr_get(st, "env"), "slots", yr_get(st, "slots"), "temp",
              yv_long(n), "self_label", yr_get(st, "self_label"), "end_label",
              yr_get(st, "end_label"), "fns", yr_get(st, "fns"), "bodies",
              yr_get(st, "bodies"), "btext", yr_get(st, "btext"), "blabels",
              yr_get(st, "blabels"));
}

/* One instruction: form `f` and its seven field words (see ir.h). The shapes
 * are written out at the call sites, so a site reads as the instruction it
 * emits. */
static Yv *emit_insn(Yv *st, long f, long a, long b, long c, long d, long e,
                     long g, long h) {
    return st_ir(st, ir_push(yr_get(st, "ir"), f, a, b, c, d, e, g, h));
}

/* A label definition (`yfn_3_foo:`), as an item carrying the label's id: the
 * assembler takes the name from the table, and tree shaking compares ids. */
static Yv *emit_label(Yv *st, long id) {
    return emit_insn(st, IR_LABEL, id, 0, 0, 0, 0, 0, 0);
}

/* The five words of a memory operand that is a frame slot (lbl < 0: the
 * displacement is from %rbp) or a symbol at (%rip) (lbl >= 0) -- base, index,
 * scale, disp, label. For the operands whose shape the emitter only learns from
 * the variable: gen_sappend's variable and its companion cell are a local for
 * one program and a global for the next. */
static Yv *memop(Yv *lbl, long disp) {
    if (yv_l(lbl) >= 0) {
        return yav(5, yv_long(-1), yv_long(-1), yv_long(1), yv_long(0), lbl);
    } else {
        return yav(5, yv_long(R_RBP), yv_long(-1), yv_long(1), yv_long(disp),
                   yv_long(-1));
    }
}

/* A line the emitter still spells as text: the three comment lines it writes
 * (two `INTERNAL:` traps and the discarded bare self, which carries a
 * trailing comment of its own). It becomes an IR_TEXT item, so the body is one
 * ordered stream either way and ir_render_all puts the text back where it was. */
Yv *emit(Yv *st, Yv *line) {
    Yv *txt = ya_push(yr_get(st, "txt"), line);
    Yv *b = ir_push(yr_get(st, "ir"), IR_TEXT, yv_len(txt) - 1, 0, 0, 0, 0, 0, 0);
    return st_with(st, b, txt);
}

Yv *next_uid(Yv *st) {
    long u = yv_l(yr_get(st, "uid"));
    st = yr(15, "ir", yr_get(st, "ir"), "txt", yr_get(st, "txt"), "rodata", yr_get(st, "rodata"), "uid",
            yv_long(yv_l(yr_get(st, "uid")) + 1), "fuid", yr_get(st, "fuid"),
            "loc", yr_get(st, "loc"), "env", yr_get(st, "env"), "slots",
            yr_get(st, "slots"), "temp", yr_get(st, "temp"), "self_label", yr_get(st, "self_label"),
            "end_label", yr_get(st, "end_label"), "fns", yr_get(st, "fns"),
            "bodies", yr_get(st, "bodies"), "btext", yr_get(st, "btext"), "blabels", yr_get(st, "blabels"));
    return yr(2, "st", st, "uid", yv_long(u));
}

Yv *next_loc(Yv *st) {
    long n = yv_l(yr_get(st, "loc"));
    Yv *id = lbl_fresh(arch_loc_label(yv_l(yr_get(st, "fuid")), n));
    st = yr(15, "ir", yr_get(st, "ir"), "txt", yr_get(st, "txt"), "rodata", yr_get(st, "rodata"), "uid",
            yr_get(st, "uid"), "fuid", yr_get(st, "fuid"), "loc",
            yv_long(yv_l(yr_get(st, "loc")) + 1), "env", yr_get(st, "env"),
            "slots", yr_get(st, "slots"), "temp", yr_get(st, "temp"), "self_label",
            yr_get(st, "self_label"), "end_label", yr_get(st, "end_label"),
            "fns", yr_get(st, "fns"), "bodies", yr_get(st, "bodies"), "btext", yr_get(st, "btext"), "blabels", yr_get(st, "blabels"));
    return yr(2, "st", st, "label", id);
}

/* ── string escaping for GAS .string ──────────────────────────────────── */

/* Runs of plain bytes are copied as one slice and the pieces joined once:
 * appending a byte at a time was quadratic, and an embedded file is one
 * long literal (the compiler's own runtime text cost 100 MB that way). */
Yv *esc_asm(Yv *s) {
    Yv *b = bytes_of(s);
    long n = yv_len(b);
    Yv *out = yav(0);
    long run = 0;
    long i = 0;
    while (i < n) {
        long o = yv_l(ya_get(b, i));
        Yv *esc = ys("");
        if (o == 92) {
            esc = ys("\\\\");
            ;
        } else if (o == 34) {
            esc = ys("\\\"");
            ;
        } else if (o == 10) {
            esc = ys("\\n");
            ;
        } else if (o == 9) {
            esc = ys("\\t");
            ;
        } else if (o < 32 || o > 126) {
            esc = ys_cat(ys_cat(ys_cat(ys("\\"), ys_long(o / 64)),
                                ys_long((o / 8) % 8)),
                         ys_long(o % 8));
            ;
        }
        if (yv_len(esc) > 0) {
            out = ya_push(out, ys_slice(s, run, i));
            out = ya_push(out, esc);
            run = i + 1;
            ;
        }
        i = i + 1;
    }
    out = ya_push(out, ys_slice_from(s, run));
    return ys_join(out, ys(""));
}

/* ── flat environment ─────────────────────────────────────────────────── */

/* ── the flat environment ───────────────────────────────────────────────────
 *
 * The env is one array per function, appended to and never popped, and
 * env_find scans it from the END -- the newest binding of a name wins, and
 * most lookups are of the newest binding (a local just defined, a capture, a
 * name the emitter is binding right now), which a pointer compare settles in a
 * couple of instructions. So the scan gets a short prefix (ENV_SCAN_BACK) and
 * stays cheap.
 *
 * Past ENV_SCAN_MAX entries it stops being a scan. A wide env is real: a
 * function with 800 locals spent 96% of a compile scanning, and a unit with
 * 40 000 top-level defs spent 63% in env_find and the y_str_eq calls under it
 * (4.8 s, 562 MB). So a wide env is indexed by name with asm.y's labmap -- the
 * one hashed name table here, and the only one that can be filled
 * incrementally (a Y map is itself a linear scan: gen_map_get walks the keys).
 *
 * One index, many envs: the emitter's env is fresh per function, so every
 * env's FIRST slot is a sentinel -- name "", kind "env", off the env's own id
 * -- and the index remembers the id it was built for. The index is a hint,
 * never the truth: a hit is checked against the slot it names, and it is
 * rebuilt whenever it describes another env or the env has outgrown half its
 * table (labmap_put does not grow, and a full table drops entries). A miss on
 * an index that describes this env and still has room is final -- the index
 * holds every binding -- and skips the rest of the scan. */
#define ENV_SCAN_MAX 64
#define ENV_SCAN_BACK 8

/* The index (a labmap: name -> slot), and the env id it describes. */
static Yv *env_ix = NULL;
static long env_ix_id = 0;
static long env_id = 0;

/* Open a fresh env: the sentinel that carries its id (its off field). */
static Yv *env_open(Yv *env) {
    env_id = env_id + 1;
    ya_push(env, yr(6, "name", ys(""), "kind", ys("env"), "off",
                     yv_long(env_id), "label", yv_long(-1), "mark", ys(""),
                     "typ", yr(1, "k", yv_long(K_tnone))));
    return env;
}

/* Index every binding of env, walking it BACKWARDS: labmap_put keeps the
 * first insert for a name, and a name bound twice in one env (a boxed local
 * defined again) must read as the newest binding, which is what env_find's
 * scan-from-the-end gives -- so the first insert per name has to be the
 * highest slot.
 *
 * The table is sized for the env as it is now, and with `grow` (the rebuild
 * the env outgrowing its table makes) at least twice what it was, so the next
 * such rebuild is at least twice as far off: without that the size would track
 * the env one step at a time and every rebuild would be O(n) of a growing n.
 * A re-bound name rebuilds without growing -- those come in bursts (every
 * boxed local of a closure-heavy function), and a doubling cap per rebuild
 * reaches a million slots and out of memory on t89. */
static Yv *env_index_all(Yv *env, int grow) {
    long cap = yv_len(env) * 2 + 16;
    /* twice the old table, but only while it is this env's: a fresh env sizes
     * its own (or a unit with two wide units would inherit the first's) */
    if (grow && yv_l(yr_get(ya_get(env, 0), "off")) == env_ix_id &&
        cap < yv_len(env_ix) * 2) {
        cap = yv_len(env_ix) * 2;
    }
    Yv *m = labmap_new(cap);
    long i = yv_len(env) - 1;
    while (i >= 0) {
        Yv *e = ya_get(env, i);
        /* the unnamed entries (the sentinel, a function's frame/fnty/boxmark
         * marks) are no name and no lookup can ask for one -- and indexing
         * them would rebuild on every one of them, since they repeat */
        if (yv_len(yr_get(e, "name")) > 0) {
            m = yr_get(labmap_put(m, yr_get(e, "name"), i, 0), "map");
        }
        i = i - 1;
    }
    env_ix = m;
    env_ix_id = yv_l(yr_get(ya_get(env, 0), "off"));
    return yv_long(0);
}

/* Index the binding just appended to env, or rebuild. Four cases: a fresh env
 * (the id differs), the env crossing the threshold -- which is a rebuild and
 * not a put, or the entries below the threshold would never be indexed at all
 * -- the env outgrowing half its table, and a re-bound name (the table keeps
 * the first insert for a name, so the newest slot has to be put by a rebuild
 * that walks backwards). */
static Yv *env_index_add(Yv *env) {
    if (yv_l(yr_get(ya_get(env, 0), "off")) != env_ix_id ||
        yv_len(env) == ENV_SCAN_MAX + 1 ||
        yv_len(env) * 2 > yv_len(env_ix)) {
        return env_index_all(env, 1);
    } else if (yv_len(env) > ENV_SCAN_MAX) {
        Yv *e = ya_get(env, yv_len(env) - 1);
        Yv *g = labmap_get(env_ix, yr_get(e, "name"));
        if (yv_len(yr_get(e, "name")) == 0) {
            /* an unnamed entry: not a name, not indexed (see env_index_all) */
        } else if (yv_l(yr_get(g, "sec")) >= 0) {
            /* a re-bound name: the table keeps the first insert, so the
             * newest slot needs the rebuild (which walks backwards) */
            return env_index_all(env, 0);
        } else {
            env_ix = yr_get(labmap_put(env_ix, yr_get(e, "name"),
                                       yv_len(env) - 1, 0),
                            "map");
        }
    }
    return yv_long(0);
}

Yv *env_find(Yv *st, Yv *name) {
    /* Miss marker: kind "none". Real entries have name/kind/off/label/typ
     * but NO k field — never test e.k. */
    /* The function's own entries first — the newest binding of a name — then
     * the unit's defs (st.fns, by its index). */
    Yv *env = yr_get(st, "env");
    long n = yv_len(env);
    long at = -1;
    /* the newest bindings, by scan */
    long lo = n - ENV_SCAN_BACK;
    if (lo < 0) { lo = 0; }
    long i = n - 1;
    while (i >= lo && at < 0) {
        Yv *e = ya_get(env, i);
        if (ys_eq(yr_get(e, "name"), name)) { at = i; }
        i = i - 1;
    }
    /* the rest by index, once the env is wide and the index is this env's */
    if (at < 0 && n > ENV_SCAN_MAX &&
        yv_l(yr_get(ya_get(env, 0), "off")) == env_ix_id && n < yv_len(env_ix)) {
        long g = yv_l(yr_get(labmap_get(env_ix, name), "sec"));
        if (g >= 0 && g < n && ys_eq(yr_get(ya_get(env, g), "name"), name)) {
            at = g;
        } else if (g < 0) {
            at = -2;
        }
    }
    /* and by scan when there is no index to ask (at == -1; a final miss is -2) */
    if (at == -1 && lo > 0) {
        i = lo - 1;
        while (i >= 0 && at < 0) {
            Yv *e = ya_get(env, i);
            if (ys_eq(yr_get(e, "name"), name)) { at = i; }
            i = i - 1;
        }
    }
    if (at >= 0) {
        return ya_get(env, at);
    } else {
        Yv *found = yr(6, "name", ys(""), "kind", ys("none"), "off", yv_long(0),
                       "label", yv_long(-1), "mark", ys(""), "typ",
                       yr(1, "k", yv_long(K_tnone)));
        Yv *fns = yr_get(st, "fns");
        long j = namemap_get(yr_get(fns, "ix"), name);
        if (j >= 0) {
            Yv *fe = ya_get(yr_get(fns, "syms"), j);
            found = yr(6, "name", yr_get(fe, "name"), "kind",
                       fns_kind(yr_get(fe, "label")), "off", yv_long(0),
                       "label", ya_get(yr_get(fns, "ids"), j), "mark", ys(""),
                       "typ", yr_get(fe, "typ"));
        }
        return found;
    }
}

Yv *env_define(Yv *st, Yv *name, Yv *kind, long off, Yv *label, Yv *mark,
                Yv *typ) {
    Yv *env = yr_get(st, "env");
    if (yv_len(env) == 0) { env = env_open(env); }
    env = ya_push(env,
                  yr(6, "name", name, "kind", kind, "off", yv_long(off),
                     "label", label, "mark", mark, "typ", typ));
    env_index_add(env);
    return yr(15, "ir", yr_get(st, "ir"), "txt", yr_get(st, "txt"), "rodata", yr_get(st, "rodata"),
              "uid", yr_get(st, "uid"), "fuid", yr_get(st, "fuid"), "loc",
              yr_get(st, "loc"), "env", env, "slots", yr_get(st, "slots"), "temp", yr_get(st, "temp"),
              "self_label", yr_get(st, "self_label"), "end_label",
              yr_get(st, "end_label"), "fns", yr_get(st, "fns"), "bodies",
              yr_get(st, "bodies"), "btext", yr_get(st, "btext"), "blabels", yr_get(st, "blabels"));
}

/* ── mini type inference (for print dispatch) ───────────────────────────
 * The checker already validated everything; this mirrors it just enough to
 * pick y_print_long / y_print_bool / y_print_cstr. */

/* The static type of an expression (infer_go), a recursive alias unfolded
 * (types.y unfold): the emitter looks into it. */
Yv *infer(Yv *st, Yv *node) {
    Yv *t = infer_go(st, node);
    if (yv_l(yr_get(t, "k")) == K_tref) {
        return unfold(t);
    } else {
        return t;
    }
}

Yv *infer_go(Yv *st, Yv *node) {
    Yv *k = yr_get(node, "k");
    if (yv_l(k) == K_num) {
        if (lit_is_float(yr_get(node, "v"))) {
            return yr(1, "k", yv_long(K_tfloat));
        } else {
            return yr(1, "k", yv_long(K_tlong));
        }
    } else if (yv_l(k) == K_str) {
        return yr(1, "k", yv_long(K_tstr));
    } else if (yv_l(k) == K_bstr) {
        return yr(2, "k", yv_long(K_tarr), "of", yr(1, "k", yv_long(K_tbyte)));
    } else if (yv_l(k) == K_bool) {
        return yr(1, "k", yv_long(K_tbool));
    } else if (yv_l(k) == K_void) {
        return yr(1, "k", yv_long(K_tvoid));
    } else if (yv_l(k) == K_id) {
        if (ys_eq_lit(yr_get(node, "v"), "self")) {
            return cur_fn_type(st);
        } else {
            Yv *e = env_find(st, yr_get(node, "v"));
            if (ys_eq_lit(yr_get(e, "kind"), "none")) {
                if (ys_eq_lit(yr_get(node, "v"), "none")) {
                    return normnode(
                        yr(2, "k", yv_long(K_topt), "of", yr(1, "k", yv_long(K_tunk))));
                } else {
                    return yr(1, "k", yv_long(K_tunk));
                }
            } else {
                return yr_get(e, "typ");
            }
        }
    } else if (yv_l(k) == K_un) {
        if (ys_eq_lit(yr_get(node, "op"), "-")) {
            /* Negating a byte is long arithmetic (types.y): -b leaves 0..255. */
            Yv *ut = infer(st, yr_get(node, "e"));
            if (yv_l(yr_get(ut, "k")) == K_tbyte) {
                return yr(1, "k", yv_long(K_tlong));
            } else {
                return ut;
            }
        } else if (ys_eq_lit(yr_get(node, "op"), "~")) {
            return yr(1, "k", yv_long(K_tlong));
        } else {
            return yr(1, "k", yv_long(K_tbool));
        }
    } else if (yv_l(k) == K_bin) {
        Yv *op = yr_get(node, "op");
        if (ys_eq_lit(op, "+") || ys_eq_lit(op, "-") || ys_eq_lit(op, "*") ||
            ys_eq_lit(op, "/") || ys_eq_lit(op, "%") || ys_eq_lit(op, "::")) {
            Yv *bl = infer(st, yr_get(node, "l"));
            Yv *br = infer(st, yr_get(node, "r"));
            if (ys_eq_lit(op, "+") &&
                (yv_l(yr_get(bl, "k")) == K_tarr ||
                 yv_l(yr_get(bl, "k")) == K_tarrfix)) {
                /* array `+` builds a NEW heap array (types.y
                 * typeof_arith_arr) -- the element type survives, except
                 * that `[T] + [[T]]` prepends the left one as an element. */
                if ((yv_l(yr_get(br, "k")) == K_tarr ||
                     yv_l(yr_get(br, "k")) == K_tarrfix) &&
                    ys_eq_lit(arr_plus_kind(bl, br), "prepend")) {
                    return yr(2, "k", yv_long(K_tarr), "of", yr_get(br, "of"));
                } else {
                    return yr(2, "k", yv_long(K_tarr), "of", yr_get(bl, "of"));
                }
            } else if (ys_eq_lit(op, "+") &&
                (yv_l(yr_get(br, "k")) == K_tarr ||
                 yv_l(yr_get(br, "k")) == K_tarrfix)) {
                return yr(2, "k", yv_long(K_tarr), "of", yr_get(br, "of"));
            } else if (ys_eq_lit(op, "::")) {
                /* cons: one element prepended to the right's array */
                return yr(2, "k", yv_long(K_tarr), "of", yr_get(br, "of"));
            } else if (ys_eq_lit(op, "+") &&
                (yv_l(yr_get(bl, "k")) == K_tstr ||
                 yv_l(yr_get(br, "k")) == K_tstr)) {
                return yr(1, "k", yv_long(K_tstr));
            } else if (yv_l(yr_get(bl, "k")) == K_tfloat) {
                return yr(1, "k", yv_long(K_tfloat));
            } else if (yv_l(yr_get(br, "k")) == K_tfloat) {
                return yr(1, "k", yv_long(K_tfloat));
            } else {
                return yr(1, "k", yv_long(K_tlong));
            }
        } else if (is_bits_op(op)) {
            return yr(1, "k", yv_long(K_tlong));
        } else {
            return yr(1, "k", yv_long(K_tbool));
        }
    } else if (yv_l(k) == K_func) {
        return normnode(func_type_in(st, node));
    } else if (yv_l(k) == K_addr) {
        return normnode(
            yr(2, "k", yv_long(K_tptr), "to", infer(st, yr_get(node, "e"))));
    } else if (yv_l(k) == K_arrrep) {
        return normnode(yr(3, "k", yv_long(K_tarrfix), "of",
                           infer(st, yr_get(node, "v")), "n",
                           yr_get(node, "n")));
    } else if (yv_l(k) == K_array) {
        Yv *elems = yr_get(node, "elems");
        if (yv_len(elems) == 0) {
            return normnode(
                yr(2, "k", yv_long(K_tarr), "of", yr(1, "k", yv_long(K_tunk))));
        } else {
            return normnode(yr(2, "k", yv_long(K_tarr), "of",
                               infer(st, ya_get(elems, 0))));
        }
    } else if (yv_l(k) == K_index) {
        /* checker guarantees an array base (any expression); the element
         * type is the base type's `of`. */
        Yv *iarr = yr_get(node, "arr");
        Yv *bt = infer(st, iarr);
        if (yv_l(yr_get(bt, "k")) == K_tarrfix ||
            yv_l(yr_get(bt, "k")) == K_tarr) {
            return yr_get(bt, "of");
        } else if (yv_l(yr_get(bt, "k")) == K_tmap) {
            /* m[k] is always optional: V? for any V */
            return normnode(yr(2, "k", yv_long(K_topt), "of", yr_get(bt, "of")));
        } else if (yv_l(yr_get(bt, "k")) == K_tstr) {
            return yr(1, "k", yv_long(K_tbyte));
        } else {
            return yr(1, "k", yv_long(K_tunk));
        }
    } else if (yv_l(k) == K_slice) {
        /* arr[lo:hi] keeps the element type but is always a heap [T]. */
        Yv *ts = infer(st, yr_get(node, "arr"));
        if (yv_l(yr_get(ts, "k")) == K_tarr) {
            return yr(2, "k", yv_long(K_tarr), "of", yr_get(ts, "of"));
        } else if (yv_l(yr_get(ts, "k")) == K_tarrfix) {
            return yr(2, "k", yv_long(K_tarr), "of", yr_get(ts, "of"));
        } else if (yv_l(yr_get(ts, "k")) == K_tstr) {
            return yr(1, "k", yv_long(K_tstr));
        } else {
            return yr(1, "k", yv_long(K_tunk));
        }
    } else if (yv_l(k) == K_char) {
        return yr(1, "k", yv_long(K_tbyte));
    } else if (yv_l(k) == K_rectest) {
        return yr(1, "k", yv_long(K_tbool));
    } else if (yv_l(k) == K_narrow) {
        return narrow_type(infer(st, yr_get(node, "e")), yr_get(node, "typ"));
    } else if (yv_l(k) == K_sliceassign) {
        return yr(1, "k", yv_long(K_tvoid));
    } else if (yv_l(k) == K_deref) {
        Yv *t = infer(st, yr_get(node, "e"));
        if (yv_l(yr_get(t, "k")) == K_tptr) {
            return yr_get(t, "to");
        } else {
            return yr(1, "k", yv_long(K_tunk));
        }
    } else if (yv_l(k) == K_call) {
        return infer_call(st, node);
    } else if (yv_l(k) == K_kw_if) {
        return infer(st, yr_get(node, "then"));
    } else if (yv_l(k) == K_block) {
        return infer_block(st, node);
    } else if (yv_l(k) == K_decl) {
        return infer_decl(st, node);
    } else if (yv_l(k) == K_assign) {
        return infer(st, yr_get(node, "v"));
    } else if (yv_l(k) == K_incdec) {
        return infer(st, yr_get(node, "tgt"));
    } else if (yv_l(k) == K_opassign) {
        return infer(st, yr_get(node, "tgt"));
    } else if (yv_l(k) == K_rec) {
        /* record literal: field types from the values (checker validated). */
        Yv *melems = yr_get(node, "vals");
        Yv *mkeys = yr_get(node, "keys");
        if (yv_len(melems) == 0) {
            return normnode(yr(2, "k", yv_long(K_trec), "fields", yav(0)));
        } else {
            /* `...` spread entries merge the source's fields (static
             * union: first appearance keeps the position, later wins the
             * value) -- the same rule as types.y's rec arm. */
            Yv *mfields = yav(0);
            long mi = 0;
            while (mi < yv_len(melems)) {
                Yv *mf = infer(st, ya_get(melems, mi));
                /* mk is read twice: the `...` test, then the merge. */
                Yv *mk = ya_get(mkeys, mi);
                if (ys_eq_lit(mk, "...")) {
                    if (yv_l(yr_get(mf, "k")) == K_trec) {
                        Yv *msfs = yr_get(mf, "fields");
                        long msi = 0;
                        while (msi < yv_len(msfs)) {
                            Yv *msf = ya_get(msfs, msi);
                            mfields = field_merge(mfields, yr_get(msf, "name"),
                                                  yr_get(msf, "typ"));
                            msi = msi + 1;
                        }
                        ;
                    }
                    ;
                } else {
                    mfields = field_merge(mfields, mk, mf);
                    ;
                }
                mi = mi + 1;
            }
            return normnode(yr(2, "k", yv_long(K_trec), "fields", mfields));
        }
    } else if (yv_l(k) == K_map) {
        /* map literal: {keys, vals, boxes} record at runtime; the static
         * type is tmap (quoted keys are strings; the values share one type). */
        Yv *glvals = yr_get(node, "vals");
        if (yv_len(glvals) == 0) {
            return normnode(yr(3, "k", yv_long(K_tmap), "key", yr(1, "k", yv_long(K_tstr)), "of", yr(1, "k", yv_long(K_tunk))));
        } else {
            return normnode(yr(3, "k", yv_long(K_tmap), "key", yr(1, "k", yv_long(K_tstr)), "of", infer(st, ya_get(glvals, 0))));
        }
    } else if (yv_l(k) == K_dot) {
        /* field read: static index into the trec (checker validated). */
        Yv *dobj = yr_get(node, "obj");
        Yv *dt = infer(st, dobj);
        if (yv_l(yr_get(dt, "k")) == K_trec) {
            int found = 0;
            Yv *ftyp = yr(1, "k", yv_long(K_tunk));
            Yv *dfs = yr_get(dt, "fields");
            long di = 0;
            while (di < yv_len(dfs)) {
                Yv *df = ya_get(dfs, di);
                /* NOTE: :str binding (see teq note in types.y): df flows
                 * from bare values (tunk), so a direct `==` would compare
                 * string POINTERS; annotated let forces content compare. */
                Yv *dfn = yr_get(df, "name");
                if (ys_eq(dfn, yr_get(node, "key"))) {
                    found = 1;
                    ftyp = yr_get(df, "typ");
                    ;
                }
                di = di + 1;
            }
            if (found) {
                return ftyp;
            } else {
                return yr(1, "k", yv_long(K_tunk));
            }
        } else if (yv_l(yr_get(dt, "k")) == K_tunion) {
            /* types.y union_field: the type the field has in every member */
            Yv *uft = rec_field_type(dt, yr_get(node, "key"));
            if (yv_l(yr_get(uft, "k")) == K_tnone) {
                return yr(1, "k", yv_long(K_tunk));
            } else {
                return uft;
            }
        } else if (yv_l(yr_get(dt, "k")) == K_tmap) {
            /* the map lowering reads its {keys, vals, boxes} shape directly */
            if (ys_eq_lit(yr_get(node, "key"), "keys")) { return normnode(yr(2, "k", yv_long(K_tarr), "of", yr_get(dt, "key"))); }
            else if (ys_eq_lit(yr_get(node, "key"), "vals")) { return normnode(yr(2, "k", yv_long(K_tarr), "of", yr_get(dt, "of"))); }
            else if (ys_eq_lit(yr_get(node, "key"), "boxes")) { return normnode(yr(2, "k", yv_long(K_tarr), "of", normnode(yr(2, "k", yv_long(K_topt), "of", yr_get(dt, "of"))))); }
            else { return yr(1, "k", yv_long(K_tunk)); }
        } else if (yv_l(yr_get(dt, "k")) == K_tarr ||
                   yv_l(yr_get(dt, "k")) == K_tarrfix ||
                   yv_l(yr_get(dt, "k")) == K_tstr) {
            /* built-in properties (types.y typeof_prop; gen_prop) */
            if (ys_eq_lit(yr_get(node, "key"), "length")) {
                return yr(1, "k", yv_long(K_tlong));
            } else {
                return normnode(
                    yr(2, "k", yv_long(K_tptr), "to", yr_get(dt, "of")));
            }
        } else {
            return yr(1, "k", yv_long(K_tunk));
        }
    } else if (yv_l(k) == K_store) {
        return infer(st, yr_get(node, "v"));
    } else if (yv_l(k) == K_kw_while) {
        return yr(1, "k", yv_long(K_tvoid));
    } else if (yv_l(k) == K_ret) {
        return infer(st, yr_get(node, "e"));
    } else {
        return yr(1, "k", yv_long(K_tunk));
    }
}

Yv *infer_call(Yv *st, Yv *node) {
    if (yv_l(yr_get(yr_get(node, "callee"), "k")) != K_id) {
        /* Calling an expression (immediately-invoked literal, fs[0](x), ...)
         * or `s.m(...)` with s a str: a string method (types.str_method). */
        Yv *ical = yr_get(node, "callee");
        if (yv_l(yr_get(ical, "k")) == K_dot &&
            yv_l(yr_get(infer(st, yr_get(ical, "obj")), "k")) == K_tstr) {
            Yv *ism = str_method(yr_get(ical, "key"));
            return yr_get(ism, "ret");
        } else {
            Yv *cft = infer(st, ical);
            if (yv_l(yr_get(cft, "k")) == K_tfunc) {
                return yr_get(cft, "ret");
            } else {
                return yr(1, "k", yv_long(K_tunk));
            }
        }
    } else {
        Yv *name = yr_get(yr_get(node, "callee"), "v");
        if (ys_eq_lit(name, "print")) {
            return yr(1, "k", yv_long(K_tvoid));
        } else if (ys_eq_lit(name, "syscall")) {
            return yr(1, "k", yv_long(K_tlong));
        } else if (ys_eq_lit(name, "len")) {
            return yr(1, "k", yv_long(K_tlong));
        } else if (ys_eq_lit(name, "is_some")) {
            return yr(1, "k", yv_long(K_tbool));
        } else if (ys_eq_lit(name, "opt$test")) {
            return yr(1, "k", yv_long(K_tbool));
        } else if (ys_eq_lit(name, "opt$val")) {
            /* the payload in an option: what some() would give, and what the
               `?.` chain's own value is (types.y opt$val) */
            Yv *vargs = yr_get(node, "args");
            if (yv_len(vargs) != 1) {
                return yr(1, "k", yv_long(K_tunk));
            } else {
                Yv *vt = infer(st, ya_get(vargs, 0));
                long vk = yv_l(yr_get(vt, "k"));
                if (vk == K_tvoid || vk == K_tunk || vk == K_topt) {
                    return vt;
                } else {
                    return yr(2, "k", yv_long(K_topt), "of", vt);
                }
            }
        } else if (ys_eq_lit(name, "unwrap")) {
            /* unwrap(x): payload type when x is statically an option. */
            Yv *uargs = yr_get(node, "args");
            if (yv_len(uargs) != 1) {
                return yr(1, "k", yv_long(K_tunk));
            } else {
                Yv *ut = infer(st, ya_get(uargs, 0));
                if (yv_l(yr_get(ut, "k")) == K_topt) {
                    return yr_get(ut, "of");
                } else {
                    return yr(1, "k", yv_long(K_tunk));
                }
            }
        } else if (ys_eq_lit(name, "some")) {
            /* some(x): option of x's type. */
            Yv *sargs = yr_get(node, "args");
            if (yv_len(sargs) != 1) {
                return yr(2, "k", yv_long(K_topt), "of", yr(1, "k", yv_long(K_tunk)));
            } else {
                return yr(2, "k", yv_long(K_topt), "of",
                          infer(st, ya_get(sargs, 0)));
            }
        } else if ((ys_eq_lit(name, "join") && yv_len(yr_get(node, "args")) == 1) || ys_eq_lit(name, "lock")) {
            /* join t: t's value; lock m { b }: b's */
            Yv *ja = yr_get(node, "args");
            Yv *ft = infer(st, ya_get(ja, yv_len(ja) - 1));
            if (yv_l(yr_get(ft, "k")) == K_tfunc) {
                return yr_get(ft, "ret");
            } else {
                return yr(1, "k", yv_long(K_tunk));
            }
        } else if (ys_eq_lit(name, "spawn")) {
            return infer(st, ya_get(yr_get(node, "args"), 0));
        } else if (ys_eq_lit(name, "fork") || ys_eq_lit(name, "wait_pid")) {
            return yr(1, "k", yv_long(K_tlong));
        } else if (ys_eq_lit(name, "try_lock")) {
            return yr(1, "k", yv_long(K_tbool));
        } else if (ys_eq_lit(name, "post") || ys_eq_lit(name, "wait")) {
            return yr(1, "k", yv_long(K_tvoid));
        } else if (ys_eq_lit(name, "mutex")) {
            return t_mutex();
        } else if (ys_eq_lit(name, "sem")) {
            return t_sem();
        } else if (ys_eq_lit(name, "trim") ||
                   ys_eq_lit(name, "chr") || ys_eq_lit(name, "join") ||
                   ys_eq_lit(name, "tostring") || ys_eq_lit(name, "typeof") ||
                   ys_eq_lit(name, "#fmt")) {
            return yr(1, "k", yv_long(K_tstr));
        } else if (ys_eq_lit(name, "bytes")) {
            return yr(2, "k", yv_long(K_tarr), "of", yr(1, "k", yv_long(K_tbyte)));
        } else if (ys_eq_lit(name, "from_bytes")) {
            return yr(1, "k", yv_long(K_tstr));
        } else if (ys_eq_lit(name, "ptr_addr")) {
            return yr(1, "k", yv_long(K_tlong));
        } else if (ys_eq_lit(name, "tonum") || ys_eq_lit(name, "ord") ||
                   ys_eq_lit(name, "byte_at") || ys_eq_lit(name, "index_of") ||
                   ys_eq_lit(name, "last_index_of")) {
            return yr(1, "k", yv_long(K_tlong));
        } else if (ys_eq_lit(name, "clock_us") || ys_eq_lit(name, "time_us") || ys_eq_lit(name, "heap_used")) {
            return yr(1, "k", yv_long(K_tlong));
        } else if (ys_eq_lit(name, "keys")) {
            Yv *kt = infer(st, ya_get(yr_get(node, "args"), 0));
            if (yv_l(yr_get(kt, "k")) == K_tmap) {
                return yr(2, "k", yv_long(K_tarr), "of", yr_get(kt, "key"));
            } else {
                return yr(1, "k", yv_long(K_tunk));
            }
        } else if (ys_eq_lit(name, "sleep")) {
            return yr(1, "k", yv_long(K_tvoid));
        } else if (ys_eq_lit(name, "split") || ys_eq_lit(name, "argv")) {
            return yr(2, "k", yv_long(K_tarr), "of", yr(1, "k", yv_long(K_tstr)));
        } else if (ys_eq_lit(name, "range")) {
            return yr(2, "k", yv_long(K_tarr), "of", yr(1, "k", yv_long(K_tlong)));
        } else if (ys_eq_lit(name, "push") || ys_eq_lit(name, "prepend") ||
                   ys_eq_lit(name, "push$all")) {
            /* both yield the array they take (the header never moves, and
             * the type is the array's either way) */
            Yv *gargs = yr_get(node, "args");
            return infer(st, ya_get(gargs, 0));
        } else if (ys_eq_lit(name, "puts") || ys_eq_lit(name, "exit")) {
            return yr(1, "k", yv_long(K_tvoid));
        } else if (ys_eq_lit(name, "eputs")) {
            return yr(1, "k", yv_long(K_tvoid));
        } else if (ys_eq_lit(name, "self")) {
            /* The function's return type; one the checker could not infer
             * stays unknown here. */
            Yv *sft = cur_fn_type(st);
            Yv *sret = yr_get(sft, "ret");
            if (yv_l(yr_get(sret, "k")) == K_tnone) {
                return yr(1, "k", yv_long(K_tunk));
            } else {
                return sret;
            }
        } else {
            Yv *e = env_find(st, name);
            if (ys_eq_lit(yr_get(e, "kind"), "none")) {
                return yr(1, "k", yv_long(K_tunk));
            } else if (yv_l(yr_get(yr_get(e, "typ"), "k")) == K_tfunc) {
                return yr_get(yr_get(e, "typ"), "ret");
            } else {
                return yr(1, "k", yv_long(K_tunk));
            }
        }
    }
}

Yv *infer_block(Yv *st, Yv *node) {
    Yv *stmts = yr_get(node, "stmts");
    if (yv_len(stmts) == 0) {
        return yr(1, "k", yv_long(K_tvoid));
    } else {
        /* A binding made inside a block is read inside the very expression
           that makes it -- `{ let a = "x"; a }`, a match arm's pattern
           bindings -- and infer runs before gen binds it, so bind the
           block's own `let`s here or the block's value infers as unknown
           (print then reads a str option as a raw number, and a match arm's
           `v.f` as one). Only these: every other name is in scope after its
           own statement, which gen has run by the time anything asks. */
        long i = 0;
        while (i < yv_len(stmts)) {
            Yv *sn = ya_get(stmts, i);
            if (yv_l(yr_get(sn, "k")) == K_decl) {
                Yv *dname = yr_get(sn, "name");
                Yv *ge = env_find(st, dname);
                if (ys_eq_lit(yr_get(sn, "kind"), "let") &&
                    ys_eq_lit(yr_get(ge, "kind"), "none")) {
                    st = env_define(st, dname, ys("temp"), 0, yv_long(-1),
                                    ys(""), infer(st, yr_get(sn, "v")));
                }
            }
            i = i + 1;
        }
        return infer(st, ya_get(stmts, yv_len(stmts) - 1));
    }
}

Yv *infer_decl(Yv *st, Yv *node) {
    if (ys_eq_lit(yr_get(node, "kind"), "def")) {
        return yr(3, "k", yv_long(K_tfunc), "args", yav(0), "ret",
                  yr(1, "k", yv_long(K_tvoid)));
    } else {
        /* an annotated `let` takes the declared type; otherwise infer the
         * initializer's */
        if (yv_l(yr_get(yr_get(node, "typ"), "k")) == K_tnone) {
            return infer(st, yr_get(node, "v"));
        } else {
            return yr_get(node, "typ");
        }
    }
}

/* ── feature-use scan (for conditional prologue) ───────────────────────
 * Walk the renamed AST for calls the _start prologue must serve: argv()
 * needs y_argv_init to materialize the [str] array from the raw stack.
 * Everything else (y_alloc, y_print_*, ...) is position-independent.
 * Returns { argv: bool }. */

Yv *uses_scan_block(Yv *stmts, Yv *out) {
    long i = 0;
    while (i < yv_len(stmts)) {
        out = uses_scan_node(ya_get(stmts, i), out);
        i = i + 1;
    }
    return out;
}

Yv *uses_scan_node(Yv *node, Yv *out) {
    Yv *k = yr_get(node, "k");
    if (yv_l(k) == K_call) {
        /* scan callee + args (argv() could nest inside an argument).
         * ncallee is read three times: the argv test, the id test, the walk. */
        Yv *ncallee = yr_get(node, "callee");
        Yv *nargs = yr_get(node, "args");
        Yv *found = out;
        if (yv_l(yr_get(ncallee, "k")) == K_id) {
            if (ys_eq_lit(yr_get(ncallee, "v"), "argv")) {
                found = yr(1, "argv", yv_bool(1));
                ;
            }
            ;
        }
        Yv *o2 = uses_scan_node(ncallee, found);
        return uses_scan_block(nargs, o2);
    } else if (yv_l(k) == K_un) {
        return uses_scan_node(yr_get(node, "e"), out);
    } else if (yv_l(k) == K_bin) {
        return uses_scan_node(yr_get(node, "r"),
                              uses_scan_node(yr_get(node, "l"), out));
    } else if (yv_l(k) == K_addr || yv_l(k) == K_deref) {
        return uses_scan_node(yr_get(node, "e"), out);
    } else if (yv_l(k) == K_kw_if) {
        return uses_scan_node(yr_get(node, "els"),
                              uses_scan_node(yr_get(node, "then"),
                                             uses_scan_node(
                                                 yr_get(node, "cond"), out)));
    } else if (yv_l(k) == K_kw_while) {
        return uses_scan_node(yr_get(node, "body"),
                              uses_scan_node(yr_get(node, "cond"), out));
    } else if (yv_l(k) == K_block) {
        return uses_scan_block(yr_get(node, "stmts"), out);
    } else if (yv_l(k) == K_decl) {
        return uses_scan_node(yr_get(node, "v"), out);
    } else if (yv_l(k) == K_func) {
        return uses_scan_node(yr_get(node, "body"), out);
    } else if (yv_l(k) == K_assign) {
        return uses_scan_node(yr_get(node, "v"), out);
    } else if (yv_l(k) == K_incdec) {
        return uses_scan_node(yr_get(node, "tgt"), out);
    } else if (yv_l(k) == K_opassign) {
        return uses_scan_node(yr_get(node, "v"),
                              uses_scan_node(yr_get(node, "tgt"), out));
    } else if (yv_l(k) == K_store) {
        return uses_scan_node(yr_get(node, "v"),
                              uses_scan_node(yr_get(node, "p"), out));
    } else if (yv_l(k) == K_ret) {
        return uses_scan_node(yr_get(node, "e"), out);
    } else if (yv_l(k) == K_array) {
        return uses_scan_block(yr_get(node, "elems"), out);
    } else if (yv_l(k) == K_arrrep) {
        return uses_scan_node(yr_get(node, "v"), out);
    } else if (yv_l(k) == K_rec) {
        return uses_scan_block(yr_get(node, "vals"), out);
    } else if (yv_l(k) == K_map) {
        return uses_scan_block(yr_get(node, "vals"), out);
    } else if (yv_l(k) == K_index) {
        return uses_scan_node(yr_get(node, "idx"),
                              uses_scan_node(yr_get(node, "arr"), out));
    } else if (yv_l(k) == K_slice) {
        return uses_scan_node(yr_get(node, "hi"),
                              uses_scan_node(yr_get(node, "lo"),
                                             uses_scan_node(
                                                 yr_get(node, "arr"), out)));
    } else if (yv_l(k) == K_idxassign) {
        return uses_scan_node(yr_get(node, "v"),
                              uses_scan_node(yr_get(node, "idx"),
                                             uses_scan_node(
                                                 yr_get(node, "arr"), out)));
    } else if (yv_l(k) == K_dotassign) {
        return uses_scan_node(yr_get(node, "v"),
                              uses_scan_node(yr_get(node, "obj"), out));
    } else if (yv_l(k) == K_kw_foreach) {
        return uses_scan_node(yr_get(node, "body"),
                              uses_scan_node(yr_get(node, "iter"), out));
    } else if (yv_l(k) == K_forrange) {
        return uses_scan_node(yr_get(node, "body"),
                              uses_scan_node(yr_get(node, "hi"),
                                             uses_scan_node(
                                                 yr_get(node, "lo"), out)));
    } else if (yv_l(k) == K_kw_for) {
        return uses_scan_node(yr_get(node, "body"),
                              uses_scan_node(yr_get(node, "step"),
                                             uses_scan_node(
                                                 yr_get(node, "cond"),
                                                 uses_scan_node(
                                                     yr_get(node, "init"),
                                                     out))));
    } else if (yv_l(k) == K_sliceassign) {
        return uses_scan_node(yr_get(node, "v"),
                              uses_scan_node(yr_get(node, "hi"),
                                             uses_scan_node(yr_get(node, "lo"),
                                                            uses_scan_node(yr_get(node, "arr"), out))));
    } else if (yv_l(k) == K_rectest || yv_l(k) == K_narrow || yv_l(k) == K_matchend) {
        return uses_scan_node(yr_get(node, "e"), out);
    } else {
        return out;
    }
}

/* ── def collection (incl. hoisting) ────────────────────────────────────
 * Walk blocks/ifs/whiles/func-bodies; every named def and every let-bound
 * anonymous def becomes a top-level function (they capture nothing — the
 * checker proved it). Returns [{name, func}]. */

Yv *collect_from_block(Yv *stmts, Yv *out) {
    long i = 0;
    while (i < yv_len(stmts)) {
        out = collect_from_node(ya_get(stmts, i), out);
        i = i + 1;
    }
    return out;
}

Yv *collect_from_node(Yv *node, Yv *out) {
    Yv *k = yr_get(node, "k");
    if (yv_l(k) == K_decl) {
        if (ys_eq_lit(yr_get(node, "kind"), "def")) {
            out = ya_push(out, yr(2, "name", yr_get(node, "name"), "func",
                                  yr_get(node, "v")));
            out = collect_from_node(yr_get(node, "v"), out);
            ;
        } else {
            if (yv_l(yr_get(yr_get(node, "v"), "k")) == K_func) {
                out = ya_push(out, yr(2, "name", yr_get(node, "name"), "func",
                                      yr_get(node, "v")));
                ;
            }
            out = collect_from_node(yr_get(node, "v"), out);
            ;
        }
    } else if (yv_l(k) == K_func) {
        out = collect_from_block(yr_get(yr_get(node, "body"), "stmts"), out);
        ;
    } else if (yv_l(k) == K_kw_if) {
        out = collect_from_node(yr_get(node, "then"), out);
        if (yv_b(yr_get(node, "has_else"))) {
            out = collect_from_node(yr_get(node, "els"), out);
            ;
        }
        ;
    } else if (yv_l(k) == K_kw_while) {
        out = collect_from_node(yr_get(node, "body"), out);
        ;
    } else if (yv_l(k) == K_kw_for) {
        out = collect_from_node(yr_get(node, "init"), out);
        out = collect_from_node(yr_get(node, "body"), out);
        out = collect_from_node(yr_get(node, "step"), out);
        ;
    } else if (yv_l(k) == K_kw_foreach) {
        out = collect_from_node(yr_get(node, "body"), out);
        ;
    } else if (yv_l(k) == K_forrange) {
        out = collect_from_node(yr_get(node, "body"), out);
        ;
    } else if (yv_l(k) == K_block) {
        out = collect_from_block(yr_get(node, "stmts"), out);
        ;
    }
    return out;
}

/* ── free variables (closure conversion) ────────────────────────────────
 * A function that reads a name bound by an ENCLOSING function captures it.
 * The capture list is computed purely syntactically (rename.y has already
 * made every binding unique), so the creation site and the body emitter
 * derive the same ordered list independently. */

/* Whether kept code calls into the thread runtime: only then are
 * arch_prelude_threads_lines linked (every compile looks at each line of
 * the prelude it is given). */
int uses_threads(Yv *refs) {
    long i = 0;
    int found = 0;
    while (i < yv_len(refs) && !found) {
        Yv *r = ya_get(refs, i);
        long n = yv_len(r);
        /* the entry points (an unlock comes with a lock or a try), by
         * length first: the self-compile has ~50K references */
        found = (n == 6 && ys_eq_lit(r, "y_fork")) || (n == 7 && ys_eq_lit(r, "y_spawn")) || (n == 10 && (ys_eq_lit(r, "y_sem_wait") || ys_eq_lit(r, "y_sem_post"))) || (n == 12 && ys_eq_lit(r, "y_mutex_lock")) || (n == 15 && ys_eq_lit(r, "y_mutex_trylock"));
        i = i + 1;
    }
    return found;
}

int name_in(Yv *xs, Yv *n) {
    long i = 0;
    int found = 0;
    /* Stops at the first hit: the answer is a bool, so unlike types.y
     * lookup the order does not matter and the tail cannot change it. */
    while (i < yv_len(xs) && !found) {
        Yv *x = ya_get(xs, i);
        if (ys_eq(x, n)) {
            found = 1;
            ;
        }
        i = i + 1;
    }
    return found;
}

/* Builtins are resolved by name at the call site, never captured. */
int is_intrinsic_name(Yv *n) {
    return name_in(
        yav(46, ys("print"), ys("syscall"), ys("len"), ys("push"), ys("some"),
            ys("is_some"), ys("unwrap"), ys("opt$test"), ys("opt$val"), ys("trim"), ys("ord"),
            ys("byte_at"), ys("chr"), ys("tonum"), ys("tostring"),
            ys("index_of"), ys("prepend"), ys("last_index_of"), ys("join"),
            ys("split"), ys("puts"), ys("eputs"), ys("clock_us"), ys("time_us"), ys("sleep"),
            ys("heap_used"), ys("keys"), ys("spawn"), ys("fork"), ys("wait_pid"),
            ys("mutex"), ys("sem"), ys("lock"), ys("try_lock"), ys("post"), ys("wait"),
            ys("exit"), ys("argv"), ys("range"), ys("typeof"),
            ys("bytes"), ys("from_bytes"), ys("ptr_addr"), ys("self"),
            ys("none"), ys("#fmt")),
        n);
}

/* Every identifier READ in a subtree (callee names included: calling a
 * captured closure needs the name captured too). With `collect` false,
 * only the reads inside nested functions count (see box_names). */
Yv *fv_walk(Yv *node, Yv *out, int collect) {
    Yv *k = yr_get(node, "k");
    if (yv_l(k) == K_id) {
        if (collect) { out = ya_push(out, yr_get(node, "v")); ; }
        ;
    } else if (yv_l(k) == K_un) {
        out = fv_walk(yr_get(node, "e"), out, collect);
        ;
    } else if (yv_l(k) == K_addr) {
        out = fv_walk(yr_get(node, "e"), out, collect);
        ;
    } else if (yv_l(k) == K_deref) {
        out = fv_walk(yr_get(node, "e"), out, collect);
        ;
    } else if (yv_l(k) == K_ret) {
        out = fv_walk(yr_get(node, "e"), out, collect);
        ;
    } else if (yv_l(k) == K_bin) {
        out = fv_walk(yr_get(node, "l"), out, collect);
        out = fv_walk(yr_get(node, "r"), out, collect);
        ;
    } else if (yv_l(k) == K_array) {
        out = fv_walk_list(yr_get(node, "elems"), out, collect);
        ;
    } else if (yv_l(k) == K_rec) {
        out = fv_walk_list(yr_get(node, "vals"), out, collect);
        ;
    } else if (yv_l(k) == K_map) {
        out = fv_walk_list(yr_get(node, "vals"), out, collect);
        ;
    } else if (yv_l(k) == K_arrrep) {
        out = fv_walk(yr_get(node, "v"), out, collect);
        ;
    } else if (yv_l(k) == K_call) {
        out = fv_walk(yr_get(node, "callee"), out, collect);
        out = fv_walk_list(yr_get(node, "args"), out, collect);
        ;
    } else if (yv_l(k) == K_index) {
        out = fv_walk(yr_get(node, "arr"), out, collect);
        out = fv_walk(yr_get(node, "idx"), out, collect);
        ;
    } else if (yv_l(k) == K_slice) {
        out = fv_walk(yr_get(node, "arr"), out, collect);
        out = fv_walk(yr_get(node, "lo"), out, collect);
        out = fv_walk(yr_get(node, "hi"), out, collect);
        ;
    } else if (yv_l(k) == K_idxassign) {
        out = fv_walk(yr_get(node, "arr"), out, collect);
        out = fv_walk(yr_get(node, "idx"), out, collect);
        out = fv_walk(yr_get(node, "v"), out, collect);
        ;
    } else if (yv_l(k) == K_dot) {
        out = fv_walk(yr_get(node, "obj"), out, collect);
        ;
    } else if (yv_l(k) == K_dotassign) {
        out = fv_walk(yr_get(node, "obj"), out, collect);
        out = fv_walk(yr_get(node, "v"), out, collect);
        ;
    } else if (yv_l(k) == K_store) {
        out = fv_walk(yr_get(node, "p"), out, collect);
        out = fv_walk(yr_get(node, "v"), out, collect);
        ;
    } else if (yv_l(k) == K_assign) {
        if (collect) { out = ya_push(out, yr_get(node, "name")); ; }
        out = fv_walk(yr_get(node, "v"), out, collect);
        ;
    } else if (yv_l(k) == K_incdec) {
        out = fv_walk(yr_get(node, "tgt"), out, collect);
        ;
    } else if (yv_l(k) == K_opassign) {
        out = fv_walk(yr_get(node, "tgt"), out, collect);
        out = fv_walk(yr_get(node, "v"), out, collect);
        ;
    } else if (yv_l(k) == K_decl) {
        out = fv_walk(yr_get(node, "v"), out, collect);
        ;
    } else if (yv_l(k) == K_kw_if) {
        out = fv_walk(yr_get(node, "cond"), out, collect);
        out = fv_walk(yr_get(node, "then"), out, collect);
        if (yv_b(yr_get(node, "has_else"))) {
            out = fv_walk(yr_get(node, "els"), out, collect);
            ;
        }
        ;
    } else if (yv_l(k) == K_kw_while) {
        out = fv_walk(yr_get(node, "cond"), out, collect);
        out = fv_walk(yr_get(node, "body"), out, collect);
        ;
    } else if (yv_l(k) == K_kw_for) {
        out = fv_walk(yr_get(node, "init"), out, collect);
        out = fv_walk(yr_get(node, "cond"), out, collect);
        out = fv_walk(yr_get(node, "step"), out, collect);
        out = fv_walk(yr_get(node, "body"), out, collect);
        ;
    } else if (yv_l(k) == K_kw_foreach) {
        out = fv_walk(yr_get(node, "iter"), out, collect);
        out = fv_walk(yr_get(node, "body"), out, collect);
        ;
    } else if (yv_l(k) == K_forrange) {
        out = fv_walk(yr_get(node, "lo"), out, collect);
        out = fv_walk(yr_get(node, "hi"), out, collect);
        out = fv_walk(yr_get(node, "body"), out, collect);
        ;
    } else if (yv_l(k) == K_block) {
        out = fv_walk_list(yr_get(node, "stmts"), out, collect);
        ;
    } else if (yv_l(k) == K_func) {
        out = fv_walk(yr_get(node, "body"), out, 1);
        ;
    } else if (yv_l(k) == K_sliceassign) {
        out = fv_walk(yr_get(node, "arr"), out, collect);
        out = fv_walk(yr_get(node, "lo"), out, collect);
        out = fv_walk(yr_get(node, "hi"), out, collect);
        out = fv_walk(yr_get(node, "v"), out, collect);
    } else if (yv_l(k) == K_rectest || yv_l(k) == K_narrow || yv_l(k) == K_matchend) {
        out = fv_walk(yr_get(node, "e"), out, collect);
    }
    return out;
}

Yv *fv_walk_list(Yv *nodes, Yv *out, int collect) {
    long i = 0;
    while (i < yv_len(nodes)) {
        out = fv_walk(ya_get(nodes, i), out, collect);
        i = i + 1;
    }
    return out;
}

Yv *fv_ids(Yv *node, Yv *out) {
    return fv_walk(node, out, 1);
}

Yv *fv_binds(Yv *node, Yv *out) {
    Yv *k = yr_get(node, "k");
    if (yv_l(k) == K_decl) {
        out = ya_push(out, yr_get(node, "name"));
        out = fv_binds(yr_get(node, "v"), out);
        ;
    } else if (yv_l(k) == K_func) {
        out = fv_bind_params(yr_get(node, "params"), out);
        out = fv_binds(yr_get(node, "body"), out);
        ;
    } else if (yv_l(k) == K_block) {
        out = fv_binds_list(yr_get(node, "stmts"), out);
        ;
    } else if (yv_l(k) == K_kw_if) {
        out = fv_binds(yr_get(node, "cond"), out);
        out = fv_binds(yr_get(node, "then"), out);
        if (yv_b(yr_get(node, "has_else"))) {
            out = fv_binds(yr_get(node, "els"), out);
            ;
        }
        ;
    } else if (yv_l(k) == K_kw_while) {
        out = fv_binds(yr_get(node, "cond"), out);
        out = fv_binds(yr_get(node, "body"), out);
        ;
    } else if (yv_l(k) == K_kw_for) {
        out = fv_binds(yr_get(node, "init"), out);
        out = fv_binds(yr_get(node, "cond"), out);
        out = fv_binds(yr_get(node, "step"), out);
        out = fv_binds(yr_get(node, "body"), out);
        ;
    } else if (yv_l(k) == K_kw_foreach) {
        out = ya_push(out, yr_get(node, "name"));
        out = fv_binds(yr_get(node, "iter"), out);
        out = fv_binds(yr_get(node, "body"), out);
        ;
    } else if (yv_l(k) == K_forrange) {
        out = ya_push(out, yr_get(node, "name"));
        out = fv_binds(yr_get(node, "lo"), out);
        out = fv_binds(yr_get(node, "hi"), out);
        out = fv_binds(yr_get(node, "body"), out);
        ;
    } else if (yv_l(k) == K_ret) {
        out = fv_binds(yr_get(node, "e"), out);
        ;
    } else if (yv_l(k) == K_un) {
        out = fv_binds(yr_get(node, "e"), out);
        ;
    } else if (yv_l(k) == K_addr) {
        out = fv_binds(yr_get(node, "e"), out);
        ;
    } else if (yv_l(k) == K_deref) {
        out = fv_binds(yr_get(node, "e"), out);
        ;
    } else if (yv_l(k) == K_bin) {
        out = fv_binds(yr_get(node, "l"), out);
        out = fv_binds(yr_get(node, "r"), out);
        ;
    } else if (yv_l(k) == K_array) {
        out = fv_binds_list(yr_get(node, "elems"), out);
        ;
    } else if (yv_l(k) == K_rec) {
        out = fv_binds_list(yr_get(node, "vals"), out);
        ;
    } else if (yv_l(k) == K_map) {
        out = fv_binds_list(yr_get(node, "vals"), out);
        ;
    } else if (yv_l(k) == K_arrrep) {
        out = fv_binds(yr_get(node, "v"), out);
        ;
    } else if (yv_l(k) == K_call) {
        out = fv_binds(yr_get(node, "callee"), out);
        out = fv_binds_list(yr_get(node, "args"), out);
        ;
    } else if (yv_l(k) == K_index) {
        out = fv_binds(yr_get(node, "arr"), out);
        out = fv_binds(yr_get(node, "idx"), out);
        ;
    } else if (yv_l(k) == K_slice) {
        out = fv_binds(yr_get(node, "arr"), out);
        out = fv_binds(yr_get(node, "lo"), out);
        out = fv_binds(yr_get(node, "hi"), out);
        ;
    } else if (yv_l(k) == K_idxassign) {
        out = fv_binds(yr_get(node, "arr"), out);
        out = fv_binds(yr_get(node, "idx"), out);
        out = fv_binds(yr_get(node, "v"), out);
        ;
    } else if (yv_l(k) == K_dot) {
        out = fv_binds(yr_get(node, "obj"), out);
        ;
    } else if (yv_l(k) == K_dotassign) {
        out = fv_binds(yr_get(node, "obj"), out);
        out = fv_binds(yr_get(node, "v"), out);
        ;
    } else if (yv_l(k) == K_store) {
        out = fv_binds(yr_get(node, "p"), out);
        out = fv_binds(yr_get(node, "v"), out);
        ;
    } else if (yv_l(k) == K_assign) {
        out = fv_binds(yr_get(node, "v"), out);
        ;
    } else if (yv_l(k) == K_incdec) {
        out = fv_binds(yr_get(node, "tgt"), out);
        ;
    } else if (yv_l(k) == K_opassign) {
        out = fv_binds(yr_get(node, "tgt"), out);
        out = fv_binds(yr_get(node, "v"), out);
        ;
    } else if (yv_l(k) == K_sliceassign) {
        out = fv_binds(yr_get(node, "arr"), out);
        out = fv_binds(yr_get(node, "lo"), out);
        out = fv_binds(yr_get(node, "hi"), out);
        out = fv_binds(yr_get(node, "v"), out);
    }
    return out;
}

Yv *fv_binds_list(Yv *nodes, Yv *out) {
    long i = 0;
    while (i < yv_len(nodes)) {
        out = fv_binds(ya_get(nodes, i), out);
        i = i + 1;
    }
    return out;
}

/* Ordered capture list of a function literal: names it reads that it does
 * not bind, minus the hoisted top-level function names and the intrinsics.
 * NOTE: reads only `params` and `body`, never `func.k` — `_start` is a
 * synthesized record without a `k` field. */
/* The names a function body reads that it does not bind and that are
 * neither in `ex` (a namemap: the unit's defs, st.fns.ix) nor `extra`
 * (its own name, or "") nor an intrinsic: what it captures. */
Yv *fn_captures(Yv *func, Yv *ex, Yv *extra) {
    Yv *bound =
        fv_bind_params(yr_get(func, "params"), fv_binds(yr_get(func, "body"),
                                                       yav(0)));
    Yv *reads = fv_ids(yr_get(func, "body"), yav(0));
    Yv *caps = yav(0);
    long i = 0;
    while (i < yv_len(reads)) {
        Yv *n = ya_get(reads, i);
        if (name_in(bound, n)) {
            ;
        } else if (ys_eq(n, extra) || namemap_get(ex, n) >= 0) {
            ;
        } else if (is_intrinsic_name(n)) {
            ;
        } else if (name_in(caps, n)) {
            ;
        } else {
            caps = ya_push(caps, n);
            ;
        }
        i = i + 1;
    }
    return caps;
}

Yv *fv_bind_params(Yv *ps, Yv *out) {
    long i = 0;
    while (i < yv_len(ps)) {
        Yv *p = ya_get(ps, i);
        out = ya_push(out, p);
        i = i + 1;
    }
    return out;
}

Yv *fn_names_of(Yv *fns) {
    Yv *out = yav(0);
    long i = 0;
    while (i < yv_len(fns)) {
        Yv *e = ya_get(fns, i);
        out = ya_push(out, yr_get(e, "name"));
        i = i + 1;
    }
    return out;
}

/* st.fns holds the hoisted defs, then the externs (the top-level defs of
 * the units this one links against), then the globals (see compile_unit);
 * a global's label is its .bss cell. */
Yv *fns_kind(Yv *label) {
    /* starts_with, not label[:3] == "yg_": the slice allocated a throwaway
     * string on every call, and this runs once per identifier emitted. */
    if (ys_starts_with(label, ys("yg_"))) {
        return ys("global");
    } else {
        return ys("func");
    }
}

/* ── expression emission (value in %rax) ──────────────────────────────── */

Yv *gen(Yv *st, Yv *node) {
    yv_nest++;
    if (yv_nest > MAX_NEST) {
        too_deep(ys("an expression"), yr_get(node, "line"), yr_get(node, "col"));
    }
    Yv *r = gen_go(st, node);
    yv_nest--;
    return r;
}

Yv *gen_go(Yv *st, Yv *node) {
    Yv *k = yr_get(node, "k");
    if (yv_l(k) == K_num) {
        return gen_lit(st, node);
    } else if (yv_l(k) == K_bool) {
        if (ys_eq_lit(yr_get(node, "v"), "true")) {
            return emit_insn(st, F_MOV_I_R, 1, R_RAX, 64, 0, 0, 0, 0);
        } else {
            return emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
        }
    } else if (yv_l(k) == K_str) {
        return gen_str_const(st, yr_get(node, "v"));
    } else if (yv_l(k) == K_bstr) {
        return gen_bstr(st, node);
    } else if (yv_l(k) == K_void) {
        return emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
    } else if (yv_l(k) == K_id) {
        return gen_id(st, node);
    } else if (yv_l(k) == K_un) {
        return gen_un(st, node);
    } else if (yv_l(k) == K_addr) {
        return gen_addr(st, node);
    } else if (yv_l(k) == K_array) {
        return gen_array(st, node);
    } else if (yv_l(k) == K_deref) {
        long dw = ptr_width(infer(st, yr_get(node, "e")));
        st = gen(st, yr_get(node, "e"));
        if (dw == 1) {
            return emit_insn(st, F_MOVZBQ_0_R, R_RAX, -1, 1, -1, -1, R_RAX, 64);
        } else {
            return emit_insn(st, F_MOV_0_R, R_RAX, -1, 1, -1, -1, R_RAX, 64);
        }
    } else if (yv_l(k) == K_bin) {
        return gen_bin(st, node);
    } else if (yv_l(k) == K_call) {
        return gen_call(st, node);
    } else if (yv_l(k) == K_kw_if) {
        return gen_if(st, node);
    } else if (yv_l(k) == K_kw_while) {
        return gen_while(st, node);
    } else if (yv_l(k) == K_kw_for) {
        return gen_for(st, node);
    } else if (yv_l(k) == K_forrange) {
        return gen_forrange(st, node);
    } else if (yv_l(k) == K_kw_foreach) {
        return gen_foreach(st, node);
    } else if (yv_l(k) == K_block) {
        return gen_block(st, node);
    } else if (yv_l(k) == K_decl) {
        return gen_decl(st, node);
    } else if (yv_l(k) == K_assign) {
        return gen_assign(st, node);
    } else if (yv_l(k) == K_incdec) {
        return gen_incdec(st, node, 0);
    } else if (yv_l(k) == K_opassign) {
        return gen_opassign(st, node, 0);
    } else if (yv_l(k) == K_index) {
        /* maps scan their keys; strings read a byte; arrays index directly */
        Yv *kbt = infer(st, yr_get(node, "arr"));
        if (yv_l(yr_get(kbt, "k")) == K_tmap) {
            return gen_map_get(st, node, ys("opt"));
        } else if (yv_l(yr_get(kbt, "k")) == K_tstr) {
            return gen_byte_at(st, n_call2(ys("byte_at"), yr_get(node, "arr"), yr_get(node, "idx"), yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col"))));
        } else {
            return gen_index(st, node);
        }
    } else if (yv_l(k) == K_slice) {
        Yv *sbt = infer(st, yr_get(node, "arr"));
        if (yv_l(yr_get(sbt, "k")) == K_tstr) { return gen_str_slice(st, node); } else { return gen_slice(st, node); }
    } else if (yv_l(k) == K_char) {
        return gen_lit(st, yr(4, "k", yv_long(K_num), "v", yr_get(node, "v"), "line", yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (yv_l(k) == K_rectest) {
        return gen_rectest(st, node);
    } else if (yv_l(k) == K_narrow) {
        /* the value, converted into the narrowed type's layout (a match
         * arm's binding: rectest checked its tag) */
        Yv *src = infer(st, yr_get(node, "e"));
        st = gen(st, yr_get(node, "e"));
        return gen_convert(st, src, narrow_type(src, yr_get(node, "typ")), 0);
    } else if (yv_l(k) == K_matchend) {
        /* unreachable when the checker accepted the match */
        st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_match_fail"))), 0, 0, 0, 0, 0, 0);
        return emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
    } else if (yv_l(k) == K_sliceassign) {
        return gen_sliceassign(st, node);
    } else if (yv_l(k) == K_idxassign) {
        Yv *kbt = infer(st, yr_get(node, "arr"));
        if (yv_l(yr_get(kbt, "k")) == K_tmap) { return gen_map_set(st, node); } else { return gen_idxassign(st, node); }
    } else if (yv_l(k) == K_dotassign) {
        return gen_dotassign(st, node);
    } else if (yv_l(k) == K_dot) {
        return gen_dot(st, node);
    } else if (yv_l(k) == K_rec) {
        /* record literal anywhere (let/call-arg): heap address in %rax. */
        return gen_reclit(st, node, yr(1, "k", yv_long(K_tnone)));
    } else if (yv_l(k) == K_map) {
        /* map literal: the {keys, vals, boxes} record, heap address in %rax. */
        return gen_maplit(st, node);
    } else if (yv_l(k) == K_arrrep) {
        /* [v; n] anywhere (let/assign/call-arg): heap address in %rax. */
        return gen_arrrep(st, node);
    } else if (yv_l(k) == K_func) {
        /* Anonymous function literal in expression position. */
        return gen_func_literal(st, node);
    } else if (yv_l(k) == K_store) {
        return gen_store(st, node);
    } else if (yv_l(k) == K_ret) {
        st = gen_as(st, yr_get(node, "e"), cur_fn_ret(st));
        return emit_insn(st, F_JMP_L, yv_l(yr_get(st, "end_label")), 0, 0, 0, 0, 0, 0);
    } else {
        /* Unreachable: the checker rejects everything else. */
        return emit(st, ys_cat(ys_cat(ys("    # INTERNAL: unhandled "), ktag(yv_l(k))),
                              ys(" (checker drift)")));
    }
}

/* A string literal in .rodata: header object [len, data..., NUL]; the value
 * is the header's address. Used by `str` nodes and by every synthesised
 * constant (typeof, function/record formatting). */
/* b"..." / b'...' -- a packed [byte] literal: desugar to a
 * one-byte-per-element array literal and let gen_array_esz do the packing. */
Yv *gen_bstr(Yv *st, Yv *node) {
    Yv *bv = yr_get(node, "v");
    Yv *elems = yav(0);
    long bi = 0;
    long bn = yv_len(bv);
    while (bi < bn) {
        Yv *bnum = yr(4, "k", yv_long(K_num), "v",
                       ys_long(ys_ord(ys_slice(bv, bi, bi + 1))),
                       "line", yr_get(node, "line"), "col", yr_get(node, "col"));
        elems = ya_push(elems, bnum);
        bi = bi + 1;
    }
    Yv *barr = yr(4, "k", yv_long(K_array), "elems", elems, "line", yr_get(node, "line"),
                  "col", yr_get(node, "col"));
    return gen_array_esz(st, barr, 1L, yr(1, "k", yv_long(K_tnone)));
}

Yv *gen_str_const(Yv *st, Yv *s) {
    Yv *r = next_uid(st);
    st = yr_get(r, "st");
    Yv *lbl = arch_str_label(yv_l(yr_get(r, "uid")));
    Yv *id = lbl_new(lbl);
    /* NOTE: push-chain over a let-bound [] (not a literal). The checker
     * rejects heterogeneous array literals ([str, long, str]); these three
     * parts are all str, so a literal would check too — the push-chain is
     * just the shape the other node-list builders use. */
    Yv *rod0 = yav(0);
    rod0 = ya_push(rod0, lbl);
    rod0 = ya_push(rod0, ys_long(yv_len(s)));
    rod0 = ya_push(rod0, esc_asm(s));
    Yv *rod = ya_push(yr_get(st, "rodata"), rod0);
    st = yr(15, "ir", yr_get(st, "ir"), "txt", yr_get(st, "txt"), "rodata", rod, "uid",
            yr_get(st, "uid"), "fuid", yr_get(st, "fuid"), "loc",
            yr_get(st, "loc"), "env", yr_get(st, "env"), "slots",
            yr_get(st, "slots"), "temp", yr_get(st, "temp"), "self_label", yr_get(st, "self_label"),
            "end_label", yr_get(st, "end_label"), "fns", yr_get(st, "fns"),
            "bodies", yr_get(st, "bodies"), "btext", yr_get(st, "btext"), "blabels", yr_get(st, "blabels"));
    return emit_insn(st, F_LEA_P_R, -1, -1, 1, 0, yv_l(id), R_RAX, 64);
}

Yv *gen_id(Yv *st, Yv *node) {
    if (ys_eq_lit(yr_get(node, "v"), "self")) {
        /* Bare `self` as a value: only legal in discarded positions
         * (the checker rejects every typed use). Emit zero (none). */
        return emit(st, ys("    xor %eax, %eax  # bare self (discarded)"));
    } else if (ys_eq_lit(yr_get(node, "v"), "none")) {
        /* The empty option (checker gives it typeof from context). */
        return emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
    } else {
        Yv *e = env_find(st, yr_get(node, "v"));
        if (ys_eq_lit(yr_get(e, "kind"), "none")) {
            return emit(st, ys_cat(ys("    # INTERNAL: undefined "),
                                  yr_get(node, "v")));
        } else if (ys_eq_lit(yr_get(e, "kind"), "func")) {
            /* A hoisted def used as a VALUE: wrap it in a closure record
             * with no captures (hoisted defs capture nothing). A capturing
             * function naming itself hands out its own record instead. */
            long soff = -1;
            if (yv_eq(yr_get(e, "label"), yr_get(st, "self_label"))) {
                soff = capture_off(st);
                ;
            }
            if (soff >= 0) {
                return emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, soff, -1, R_RAX, 64);
            } else {
                return gen_make_closure(st, yr_get(e, "label"), yav(0));
            }
        } else if (ys_eq_lit(yr_get(e, "kind"), "global")) {
            /* An appendable global gives up its buffer on every read
             * (see gen_sappend). */
            if (yv_l(yr_get(yr_get(e, "typ"), "k")) == K_tstr) {
                Yv *oe = env_find(st, ys_cat(yr_get(node, "v"), ys("#o")));
                if (ys_eq_lit(yr_get(oe, "kind"), "none")) {
                    ;
                } else {
                    st = emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
                    st = emit_insn(st, F_MOV_R_P, R_RAX, 64, -1, -1, 1, 0,
                                   yv_l(yr_get(oe, "label")));
                }
            }
            return emit_insn(st, F_MOV_P_R, -1, -1, 1, 0,
                             yv_l(yr_get(e, "label")), R_RAX, 64);
        } else if (ys_eq_lit(yr_get(e, "kind"), "own")) {
            /* An appendable string: a read may let its buffer escape, so
             * the companion is cleared (see gen_sappend). */
            long off = yv_l(yr_get(e, "off"));
            st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, off, -1, R_RAX, 64);
            return emit_insn(st, F_MOV_I_D, 0, R_RBP, -1, 1, off - 8, -1, 0);
        } else if (ys_eq_lit(yr_get(e, "kind"), "capture")) {
            /* Captured by the enclosing closure: load the closure record
             * (at the frame offset recorded in `off`), read slot idx+1 —
             * the shared cell pointer — and deref it (see box_capture).
             * NOTE: the index rides in `label` — env entries have no spare
             * numeric field and adding one would touch every signature. */
            long idx = ys_tonum(yr_get(e, "mark"));
            st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, yv_l(yr_get(e, "off")), -1, R_RCX, 64);
            st = emit_insn(st, F_MOV_D_R, R_RCX, -1, 1, 8 * (idx + 1), -1, R_RAX, 64);
            return emit_insn(st, F_MOV_0_R, R_RAX, -1, 1, -1, -1, R_RAX, 64);
        } else if (ys_eq_lit(yr_get(e, "kind"), "box")) {
            /* A captured variable's shared cell; the slot holds its
             * pointer. */
            st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, yv_l(yr_get(e, "off")), -1, R_RAX, 64);
            return emit_insn(st, F_MOV_0_R, R_RAX, -1, 1, -1, -1, R_RAX, 64);
        } else {
            return emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, yv_l(yr_get(e, "off")), -1, R_RAX, 64);
        }
    }
}

/* ── closures ───────────────────────────────────────────────────────────
 * A closure is a heap record [code_addr, cap0, cap1, ...] and its VALUE is
 * that address (8 bytes, like every other value).
 *
 * Calling convention: the caller pushes the closure FIRST (deepest), then
 * the args left to right. Param offsets are therefore identical to a direct
 * call, and the closure pointer sits at rbp+16+8*nargs. That is why a
 * capture-free body works unchanged under both call forms: it simply never
 * reads that slot, and the caller cleans up either way. */

/* The cell pointer for a capture, in %rax. Every capture slot holds a
 * heap BOX pointer (see box_capture) — through a closure record or through
 * a "box" binding alike. */
Yv *gen_cap_ptr(Yv *st, Yv *name) {
    Yv *e = env_find(st, name);
    if (ys_eq_lit(yr_get(e, "kind"), "capture")) {
        /* NOTE: the index rides in `label` (see gen_id's capture arm). */
        long pidx = ys_tonum(yr_get(e, "mark"));
        st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, yv_l(yr_get(e, "off")), -1, R_RCX, 64);
        return emit_insn(st, F_MOV_D_R, R_RCX, -1, 1, 8 * (pidx + 1), -1, R_RAX, 64);
    } else {
        return emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, yv_l(yr_get(e, "off")), -1, R_RAX, 64);
    }
}

/* A captured variable lives in ONE heap cell shared by its binding and
 * every closure over it: writes through either are visible through both —
 * the scope is shared, exactly as in the C copy's value model (yv.c)
 * (the old native model copied the value at creation and could not even
 * write to a capture). The cell is allocated where the variable is BOUND
 * (box_bound: declaration, parameter entry, loop-variable refresh), so
 * every later read and write — before or after the closure exists, on
 * any path — goes through it. Boxing at the closure's creation site
 * instead would leave code emitted earlier (a loop's condition, the other
 * arm of an `if`) on the stale frame slot. box_capture allocates the cell
 * from the current value and re-binds the name to it (kind "box"); it is
 * a no-op for a name already boxed. A loop variable is bound once per
 * iteration, so each iteration's closures share one fresh cell; a
 * variable declared before a loop shares one cell across iterations. */
Yv *box_capture(Yv *st, Yv *name) {
    Yv *e = env_find(st, name);
    if (ys_eq_lit(yr_get(e, "kind"), "box") ||
        ys_eq_lit(yr_get(e, "kind"), "capture")) {
        return st;
    } else {
        st = gen_id(st, yr(4, "k", yv_long(K_id), "v", name, "line", yv_long(0),
                           "col", yv_long(0)));
        st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, F_MOV_I_R, 8, R_RDI, 64, 0, 0, 0, 0);
        st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_alloc"))), 0, 0, 0, 0, 0, 0);
        st = emit_insn(st, F_POP_R, R_RDX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, F_MOV_R_0, R_RDX, 64, R_RAX, -1, 1, -1, -1);
        long boff = (yv_l(yr_get(st, "slots")) + 1) * -8;
        st = emit_insn(st, F_MOV_R_D, R_RAX, 64, R_RBP, -1, 1, boff, -1);
        Yv *st2 =
           yr(15, "ir", yr_get(st, "ir"), "txt", yr_get(st, "txt"), "rodata", yr_get(st, "rodata"),
               "uid", yr_get(st, "uid"), "fuid", yr_get(st, "fuid"), "loc",
               yr_get(st, "loc"), "env", yr_get(st, "env"), "slots",
               yv_long(yv_l(yr_get(st, "slots")) + 1), "temp", yr_get(st, "temp"), "self_label",
               yr_get(st, "self_label"), "end_label", yr_get(st, "end_label"),
               "fns", yr_get(st, "fns"), "bodies", yr_get(st, "bodies"), "btext", yr_get(st, "btext"), "blabels", yr_get(st, "blabels"));
        return env_define(st2, name, ys("box"), boff, yv_long(-1), ys(""),
                          yr_get(e, "typ"));
    }
}

/* The names nested functions read: every binding of this body that a
 * closure can capture (names are unique after rename, so the others —
 * the nested functions' own locals, globals, defs — are never bound
 * here). emit_one_fn records them as "boxmark" entries past a "frame"
 * entry, named "" so no lookup can hit them, the marked name in `label`. */
Yv *box_names(Yv *func) {
    Yv *reads = fv_walk(yr_get(func, "body"), yav(0), 0);
    Yv *out = yav(0);
    long i = 0;
    while (i < yv_len(reads)) {
        Yv *n = ya_get(reads, i);
        if (name_in(out, n)) {
            ;
        } else {
            out = ya_push(out, n);
            ;
        }
        i = i + 1;
    }
    return out;
}

/* Called right after `name` is bound: a captured name moves into its
 * cell now (see box_capture). Scans back to this function's "frame". */
Yv *box_bound(Yv *st, Yv *name) {
    Yv *env = yr_get(st, "env");
    long i = yv_len(env) - 1;
    int want = 0;
    int more = 1;
    while (more && i >= 0) {
        Yv *e = ya_get(env, i);
        if (ys_eq_lit(yr_get(e, "kind"), "frame")) {
            more = 0;
            ;
        } else if (ys_eq_lit(yr_get(e, "kind"), "boxmark") &&
                   ys_eq(yr_get(e, "mark"), name)) {
            want = 1;
            more = 0;
            ;
        }
        i = i - 1;
    }
    if (want) {
        return box_capture(st, name);
    } else {
        return st;
    }
}

/* -- owned strings: `s += x` in place ----------------------------------
 * An append used to copy the whole string (s = s + x), so n appends in a
 * loop cost O(n^2) bytes. A str variable that `+=` targets now has a
 * companion word: an "own" local keeps it in the slot below its value, an
 * appendable global in a second .bss cell (app_cells). It holds 0, 1
 * (an append statement is running), or the buffer the variable's last
 * append statement produced, and every read of the variable clears it
 * (gen_id). So "companion == value" proves nobody else ever saw that
 * buffer, and the append may write into its spare room (y_str_app; its
 * buffers keep their capacity in the word before the length). A variable
 * whose address is taken, or that a closure captures, never qualifies. */

/* Every `+=` id target in a subtree, plus `&` + each name whose address
 * is taken. With `deep` false nested functions are skipped: each gets its
 * own walk, and a variable one of them touches is captured (boxed). */
Yv *app_walk(Yv *node, Yv *out, int deep) {
    Yv *k = yr_get(node, "k");
    /* Most common kinds first: a leaf costs one compare, not the chain. */
    if (yv_l(k) == K_id || yv_l(k) == K_num || yv_l(k) == K_str) {
        ;
    } else if (yv_l(k) == K_call) {
        out = app_walk(yr_get(node, "callee"), out, deep);
        out = app_walk_list(yr_get(node, "args"), out, deep);
        ;
    } else if (yv_l(k) == K_dot) {
        out = app_walk(yr_get(node, "obj"), out, deep);
        ;
    } else if (yv_l(k) == K_bin) {
        out = app_walk(yr_get(node, "l"), out, deep);
        out = app_walk(yr_get(node, "r"), out, deep);
        ;
    } else if (yv_l(k) == K_block) {
        out = app_walk_list(yr_get(node, "stmts"), out, deep);
        ;
    } else if (yv_l(k) == K_arrrep || yv_l(k) == K_decl ||
               yv_l(k) == K_assign) {
        out = app_walk(yr_get(node, "v"), out, deep);
        ;
    } else if (yv_l(k) == K_kw_if) {
        out = app_walk(yr_get(node, "cond"), out, deep);
        out = app_walk(yr_get(node, "then"), out, deep);
        if (yv_b(yr_get(node, "has_else"))) {
            out = app_walk(yr_get(node, "els"), out, deep);
            ;
        }
        ;
    } else if (yv_l(k) == K_opassign) {
        Yv *tg = yr_get(node, "tgt");
        if (ys_eq_lit(yr_get(node, "op"), "+") &&
            yv_l(yr_get(tg, "k")) == K_id) {
            out = ya_push(out, yr_get(tg, "v"));
            ;
        }
        out = app_walk(tg, out, deep);
        out = app_walk(yr_get(node, "v"), out, deep);
        ;
    } else if (yv_l(k) == K_index) {
        out = app_walk(yr_get(node, "arr"), out, deep);
        out = app_walk(yr_get(node, "idx"), out, deep);
        ;
    } else if (yv_l(k) == K_addr) {
        Yv *ae = yr_get(node, "e");
        if (yv_l(yr_get(ae, "k")) == K_id) {
            out = ya_push(out, ys_cat(ys("&"), yr_get(ae, "v")));
            ;
        }
        out = app_walk(ae, out, deep);
        ;
    } else if (yv_l(k) == K_un || yv_l(k) == K_deref ||
               yv_l(k) == K_ret || yv_l(k) == K_rectest ||
               yv_l(k) == K_narrow || yv_l(k) == K_matchend) {
        out = app_walk(yr_get(node, "e"), out, deep);
        ;
    } else if (yv_l(k) == K_array) {
        out = app_walk_list(yr_get(node, "elems"), out, deep);
        ;
    } else if (yv_l(k) == K_rec || yv_l(k) == K_map) {
        out = app_walk_list(yr_get(node, "vals"), out, deep);
        ;
    } else if (yv_l(k) == K_slice) {
        out = app_walk(yr_get(node, "arr"), out, deep);
        out = app_walk(yr_get(node, "lo"), out, deep);
        out = app_walk(yr_get(node, "hi"), out, deep);
        ;
    } else if (yv_l(k) == K_idxassign) {
        out = app_walk(yr_get(node, "arr"), out, deep);
        out = app_walk(yr_get(node, "idx"), out, deep);
        out = app_walk(yr_get(node, "v"), out, deep);
        ;
    } else if (yv_l(k) == K_dotassign) {
        out = app_walk(yr_get(node, "obj"), out, deep);
        out = app_walk(yr_get(node, "v"), out, deep);
        ;
    } else if (yv_l(k) == K_store) {
        out = app_walk(yr_get(node, "p"), out, deep);
        out = app_walk(yr_get(node, "v"), out, deep);
        ;
    } else if (yv_l(k) == K_incdec) {
        out = app_walk(yr_get(node, "tgt"), out, deep);
        ;
    } else if (yv_l(k) == K_kw_while) {
        out = app_walk(yr_get(node, "cond"), out, deep);
        out = app_walk(yr_get(node, "body"), out, deep);
        ;
    } else if (yv_l(k) == K_kw_for) {
        out = app_walk(yr_get(node, "init"), out, deep);
        out = app_walk(yr_get(node, "cond"), out, deep);
        out = app_walk(yr_get(node, "step"), out, deep);
        out = app_walk(yr_get(node, "body"), out, deep);
        ;
    } else if (yv_l(k) == K_kw_foreach) {
        out = app_walk(yr_get(node, "iter"), out, deep);
        out = app_walk(yr_get(node, "body"), out, deep);
        ;
    } else if (yv_l(k) == K_forrange) {
        out = app_walk(yr_get(node, "lo"), out, deep);
        out = app_walk(yr_get(node, "hi"), out, deep);
        out = app_walk(yr_get(node, "body"), out, deep);
        ;
    } else if (yv_l(k) == K_func) {
        if (deep) {
            out = app_walk(yr_get(node, "body"), out, deep);
            ;
        }
        ;
    } else if (yv_l(k) == K_sliceassign) {
        out = app_walk(yr_get(node, "arr"), out, deep);
        out = app_walk(yr_get(node, "lo"), out, deep);
        out = app_walk(yr_get(node, "hi"), out, deep);
        out = app_walk(yr_get(node, "v"), out, deep);
        ;
    }
    return out;
}

Yv *app_walk_list(Yv *nodes, Yv *out, int deep) {
    long i = 0;
    while (i < yv_len(nodes)) {
        out = app_walk(ya_get(nodes, i), out, deep);
        i = i + 1;
    }
    return out;
}

/* The names in a subtree (`deep`: a whole program) an append statement
 * may extend in place: `+=` targets whose address is never taken, minus
 * `skip` (the names closures capture). Only the str-typed ones are used. */
Yv *app_names(Yv *node, int deep, Yv *skip) {
    Yv *seen = app_walk(node, yav(0), deep);
    Yv *out = yav(0);
    long i = 0;
    while (i < yv_len(seen)) {
        Yv *n = ya_get(seen, i);
        if (ys_eq_lit(ys_slice(n, 0, 1), "&") || name_in(out, n) ||
            name_in(skip, n) || name_in(seen, ys_cat(ys("&"), n))) {
            ;
        } else {
            out = ya_push(out, n);
            ;
        }
        i = i + 1;
    }
    return out;
}

/* Before a str variable is bound: does this function append to it (an
 * "appmark" past its "frame", see emit_one_fn)? */
int own_wanted(Yv *st, Yv *name) {
    Yv *env = yr_get(st, "env");
    long i = yv_len(env) - 1;
    int want = 0;
    int more = 1;
    while (more && i >= 0) {
        Yv *e = ya_get(env, i);
        if (ys_eq_lit(yr_get(e, "kind"), "frame")) {
            more = 0;
            ;
        } else if (ys_eq_lit(yr_get(e, "kind"), "appmark") &&
                   ys_eq(yr_get(e, "mark"), name)) {
            want = 1;
            more = 0;
            ;
        }
        i = i - 1;
    }
    return want;
}

/* Bind an appendable str to the value in %rax: the value slot, and its
 * companion in the slot below, cleared. */
Yv *bind_own(Yv *st, Yv *name, Yv *t) {
    long off = (yv_l(yr_get(st, "slots")) + 1) * -8;
    st = emit_insn(st, F_MOV_R_D, R_RAX, 64, R_RBP, -1, 1, off, -1);
    st = emit_insn(st, F_MOV_I_D, 0, R_RBP, -1, 1, off - 8, -1, 0);
    Yv *st2 =
       yr(15, "ir", yr_get(st, "ir"), "txt", yr_get(st, "txt"), "rodata", yr_get(st, "rodata"),
           "uid", yr_get(st, "uid"), "fuid", yr_get(st, "fuid"), "loc",
           yr_get(st, "loc"), "env", yr_get(st, "env"), "slots",
           yv_long(yv_l(yr_get(st, "slots")) + 2), "temp", yr_get(st, "temp"), "self_label",
           yr_get(st, "self_label"), "end_label", yr_get(st, "end_label"),
           "fns", yr_get(st, "fns"), "bodies", yr_get(st, "bodies"), "btext", yr_get(st, "btext"), "blabels", yr_get(st, "blabels"));
    return env_define(st2, name, ys("own"), off, yv_long(-1), ys(""), t);
}

/* A statement nobody takes the value of. `s += x` on an appendable string
 * (an "own" local, or a global with a companion cell) goes through
 * gen_sappend (the checker made x a str); anything else is plain gen. */
Yv *gen_stmt(Yv *st, Yv *node) {
    /* A local read as a statement is one `mov %rbp`-relative nobody reads:
     * these are the temporaries the `x++` / `x op= v` desugar leaves behind
     * (the synthetic `let v` is a kind "local" slot). Only that kind is
     * dropped: "own" is an appendable string, whose read clears the companion
     * cell, "global" may have one, and "box"/"capture" read through a cell. */
    if (yv_l(yr_get(node, "k")) == K_id) {
        Yv *id = node;
        Yv *e = env_find(st, yr_get(id, "v"));
        if (ys_eq_lit(yr_get(e, "kind"), "local")) {
            return st;
        } else {
            return gen(st, node);
        }
    } else if (yv_l(yr_get(node, "k")) == K_incdec) {
        /* `x++` as a statement: the desugar's block value is the old x, and
         * nothing reads it (see gen_incdec's `dropped`). */
        return gen_incdec(st, node, 1);
    } else if (yv_l(yr_get(node, "k")) == K_opassign) {
        Yv *assign = node;
        if (ys_eq_lit(yr_get(assign, "op"), "+") &&
            yv_l(yr_get(yr_get(assign, "tgt"), "k")) == K_id) {
            Yv *tgt = yr_get(assign, "tgt");
            Yv *e = env_find(st, yr_get(tgt, "v"));
            if (ys_eq_lit(yr_get(e, "kind"), "own")) {
                long off = yv_l(yr_get(e, "off"));
                return gen_sappend(st, yr_get(assign, "v"), yv_long(-1), off,
                                   yv_long(-1), off - 8);
            } else if (ys_eq_lit(yr_get(e, "kind"), "global") &&
                       yv_l(yr_get(yr_get(e, "typ"), "k")) == K_tstr) {
                Yv *oe = env_find(st, ys_cat(yr_get(tgt, "v"), ys("#o")));
                if (ys_eq_lit(yr_get(oe, "kind"), "none")) {
                    return gen_opassign(st, assign, 1);
                } else {
                    return gen_sappend(st, yr_get(assign, "v"),
                                       yr_get(e, "label"), 0,
                                       yr_get(oe, "label"), 0);
                }
            } else {
                return gen_opassign(st, assign, 1);
            }
        } else {
            return gen_opassign(st, assign, 1);
        }
    } else {
        return gen(st, node);
    }
}

/* `s += v` as a statement on an appendable string; `var` and `cell` are
 * the operands of the variable and of its companion. Ownership is decided
 * before v runs (companion := 1 if it held the value, else 0); anything v
 * does to the variable (a read clears the companion, a nested append
 * stores its buffer there) leaves it != 1, and y_str_app copies. The
 * order is s = s + v's: the old value first, then v. */
Yv *gen_sappend(Yv *st, Yv *v, Yv *var_lbl, long var_disp, Yv *cell_lbl,
                 long cell_disp) {
    Yv *va = memop(var_lbl, var_disp);
    Yv *ca = memop(cell_lbl, cell_disp);
    st = emit_insn(st, F_MOV_P_R, yv_l(ya_get(va, 0)), yv_l(ya_get(va, 1)),
                   yv_l(ya_get(va, 2)), yv_l(ya_get(va, 3)),
                   yv_l(ya_get(va, 4)), R_RAX, 64);
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_MOV_P_R, yv_l(ya_get(ca, 0)), yv_l(ya_get(ca, 1)),
                   yv_l(ya_get(ca, 2)), yv_l(ya_get(ca, 3)),
                   yv_l(ya_get(ca, 4)), R_RDX, 64);
    st = emit_insn(st, F_CMP_R_R, R_RDX, 64, R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, F_SETE_R, R_RAX, 8, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_MOVZBQ_R_R, R_RAX, 8, R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, F_MOV_R_P, R_RAX, 64, yv_l(ya_get(ca, 0)),
                   yv_l(ya_get(ca, 1)), yv_l(ya_get(ca, 2)),
                   yv_l(ya_get(ca, 3)), yv_l(ya_get(ca, 4)));
    st = gen(st, v);
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_MOV_P_R, yv_l(ya_get(ca, 0)), yv_l(ya_get(ca, 1)),
                   yv_l(ya_get(ca, 2)), yv_l(ya_get(ca, 3)),
                   yv_l(ya_get(ca, 4)), R_RAX, 64);
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_str_app"))), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_ADD_I_R, 24, R_RSP, 64, 0, 0, 0, 0);
    st = emit_insn(st, F_MOV_R_P, R_RAX, 64, yv_l(ya_get(va, 0)),
                   yv_l(ya_get(va, 1)), yv_l(ya_get(va, 2)),
                   yv_l(ya_get(va, 3)), yv_l(ya_get(va, 4)));
    return emit_insn(st, F_MOV_R_P, R_RAX, 64, yv_l(ya_get(ca, 0)),
                     yv_l(ya_get(ca, 1)), yv_l(ya_get(ca, 2)),
                     yv_l(ya_get(ca, 3)), yv_l(ya_get(ca, 4)));
}

/* A loop body: its value is dropped, so a block body's last statement is
 * a statement too (gen_stmt). */
Yv *gen_discard(Yv *st, Yv *node) {
    if (yv_l(yr_get(node, "k")) == K_block) {
        return gen_block_as(st, node, 1);
    }
    return gen_stmt(st, node);
}

/* One companion cell (see gen_sappend) per str global an append statement
 * may extend in place, named `<global>#o` (`#` never occurs in a Y name)
 * so gen_id and gen_stmt find it beside the global. The program is walked
 * only when it has a str global at all. */
Yv *app_cells(Yv *gl, Yv *stmts) {
    int anystr = 0;
    long i = 0;
    while (i < yv_len(gl)) {
        Yv *ge = ya_get(gl, i);
        if (yv_l(yr_get(yr_get(ge, "typ"), "k")) == K_tstr) {
            anystr = 1;
            ;
        }
        i = i + 1;
    }
    if (anystr) {
        Yv *block = yr(4, "k", yv_long(K_block), "stmts", stmts, "line",
                       yv_long(1), "col", yv_long(1));
        Yv *names = app_names(block, 1, yav(0));
        Yv *out = yav(0);
        long j = 0;
        while (j < yv_len(gl)) {
            out = ya_push(out, ya_get(gl, j));
            j = j + 1;
        }
        j = 0;
        while (j < yv_len(gl)) {
            Yv *g2 = ya_get(gl, j);
            if (yv_l(yr_get(yr_get(g2, "typ"), "k")) == K_tstr &&
                name_in(names, yr_get(g2, "name"))) {
                Yv *oname = ys_cat(yr_get(g2, "name"), ys("#o"));
                Yv *olabel =
                    ys_cat(ys("ygo_"), ys_slice_from(yr_get(g2, "label"), 3));
                out = ya_push(out, yr(3, "name", oname, "label", olabel,
                                      "typ", yr(1, "k", yv_long(K_tnone))));
                ;
            }
            j = j + 1;
        }
        return out;
    }
    return gl;
}

Yv *gen_make_closure(Yv *st, Yv *label, Yv *caps) {
    long n = yv_len(caps);
    st = emit_insn(st, F_MOV_I_R, 8 + 8 * n, R_RDI, 64, 0, 0, 0, 0);
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_alloc"))), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_LEA_P_R, -1, -1, 1, 0, yv_l(label), R_RCX, 64);
    st = emit_insn(st, F_MOV_R_0, R_RCX, 64, R_RAX, -1, 1, -1, -1);
    long i = 0;
    while (i < n) {
        Yv *cn = ya_get(caps, i);
        /* Captured as a shared cell pointer (see box_capture). */
        st = gen_cap_ptr(st, cn);
        st = emit_insn(st, F_POP_R, R_RCX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, F_PUSH_R, R_RCX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, F_MOV_R_D, R_RAX, 64, R_RCX, -1, 1, 8 * (i + 1), -1);
        i = i + 1;
    }
    return emit_insn(st, F_POP_R, R_RAX, 64, 0, 0, 0, 0, 0);
}

/* range(n) -> [0, 1, ..., n-1] as a heap array (the loop-friendly builtin;
 * y_range in std/rt.y). */
Yv *gen_range(Yv *st, Yv *node) {
    st = gen_push_args(st, yr_get(node, "args"));
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_range"))), 0, 0, 0, 0, 0, 0);
    return emit_insn(st, F_ADD_I_R, 8, R_RSP, 64, 0, 0, 0, 0);
}

/* arr[lo:hi] — half-open, clamped, always a NEW heap array (the operands
 * are untouched, like `+` on arrays). A missing bound means 0 / len. */
Yv *gen_slice(Yv *st, Yv *node) {
    Yv *lo = yr_get(node, "lo");
    Yv *hi = yr_get(node, "hi");
    long slesz = arr_elem_bytes(infer(st, yr_get(node, "arr")));
    st = gen(st, yr_get(node, "arr"));
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    if (yv_l(yr_get(lo, "k")) == K_void) {
        st = emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
        ;
    } else {
        st = gen(st, lo);
        ;
    }
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    if (yv_l(yr_get(hi, "k")) == K_void) {
        /* default: the array's length (the header keeps it in slot 0);
         * the array pointer sits one slot below the pushed lo. */
        st = emit_insn(st, F_MOV_D_R, R_RSP, -1, 1, 8, -1, R_RAX, 64);
        st = emit_insn(st, F_MOV_0_R, R_RAX, -1, 1, -1, -1, R_RAX, 64);
        ;
    } else {
        st = gen(st, hi);
        ;
    }
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_MOV_I_R, slesz, R_RAX, 64, 0, 0, 0, 0);
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_arr_slice"))), 0, 0, 0, 0, 0, 0);
    return emit_insn(st, F_ADD_I_R, 32, R_RSP, 64, 0, 0, 0, 0);
}

// s[lo:hi] -- the substring, half-open and clamped like an array slice;
// a missing bound means 0 / len (the asm primitive y_str_slice).
Yv *gen_str_slice(Yv *st, Yv *node) {
    Yv *lo = yr_get(node, "lo");
    Yv *hi = yr_get(node, "hi");
    st = gen(st, yr_get(node, "arr"));
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    if (yv_l(yr_get(lo, "k")) == K_void) {
        st = emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
    } else {
        st = gen(st, lo);
    }
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    if (yv_l(yr_get(hi, "k")) == K_void) {
        st = emit_insn(st, F_MOV_D_R, R_RSP, -1, 1, 8, -1, R_RAX, 64);
        st = emit_insn(st, F_MOV_0_R, R_RAX, -1, 1, -1, -1, R_RAX, 64);
    } else {
        st = gen(st, hi);
    }
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_str_slice"))), 0, 0, 0, 0, 0, 0);
    return emit_insn(st, F_ADD_I_R, 24, R_RSP, 64, 0, 0, 0, 0);
}

// a[lo:hi] = src: y_arr_setslice{1,8} (rt.y) check the range and the
// length, then copy src's elements in. Evaluation order: a, lo, hi, src.
Yv *gen_sliceassign(Yv *st, Yv *node) {
    Yv *lo = yr_get(node, "lo");
    Yv *hi = yr_get(node, "hi");
    long esz = arr_elem_bytes(infer(st, yr_get(node, "arr")));
    st = gen(st, yr_get(node, "arr"));
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    if (yv_l(yr_get(lo, "k")) == K_void) {
        st = emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
    } else {
        st = gen(st, lo);
    }
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    if (yv_l(yr_get(hi, "k")) == K_void) {
        st = emit_insn(st, F_MOV_D_R, R_RSP, -1, 1, 8, -1, R_RAX, 64);
        st = emit_insn(st, F_MOV_0_R, R_RAX, -1, 1, -1, -1, R_RAX, 64);
    } else {
        st = gen(st, hi);
    }
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen(st, yr_get(node, "v"));
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys_cat(ys("y_arr_setslice"),
                                                     ys_long(esz)))),
                   0, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_ADD_I_R, 32, R_RSP, 64, 0, 0, 0, 0);
    return emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
}

// `T` / `{f: v}` pattern test (types.y typeof_rectest): 1 in %rax when the
// value of node.e matches. A union holds exactly one member: the test
// compares the value's descriptor with those of the members the pattern
// matches (rectest_members). A record matches by its static type (the
// checker rejected a pattern it cannot match).
Yv *gen_rectest(Yv *st, Yv *node) {
    Yv *s = infer(st, yr_get(node, "e"));
    Yv *sk = yr_get(s, "k");
    st = gen(st, yr_get(node, "e"));
    if (yv_l(sk) == K_tunion) {
        return gen_tag_in(st, rectest_members(s, yr_get(node, "typ")), s);
    } else {
        // a record: the checker took the pattern as its own type
        return emit_insn(st, F_MOV_I_R, 1, R_RAX, 64, 0, 0, 0, 0);
    }
}

// The members of union s (as written, types.y union_parts) the pattern t
// matches: t itself (a type pattern), or every member with the fields of
// a record pattern.
Yv *rectest_members(Yv *s, Yv *t) {
    Yv *tk = yr_get(t, "k");
    if (yv_l(tk) == K_tpat) {
        return pat_members(s, t);
    } else {
        Yv *out = yav(0);
        Yv *m = union_member(s, t);
        Yv *mk = yr_get(m, "k");
        if (yv_l(mk) != K_tnone) {
            out = ya_push(out, m);
        }
        return out;
    }
}

// Record in %rax -> 1 when its descriptor is that of one of the record
// types ts held where `inu` is declared (a union: its layout), else 0.
Yv *gen_tag_in(Yv *st, Yv *ts, Yv *inu) {
    Yv *rno = next_loc(st);
    st = yr_get(rno, "st");
    Yv *rdone = next_loc(st);
    st = yr_get(rdone, "st");
    st = emit_insn(st, F_TEST_R_R, R_RAX, 64, R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, F_JZ_L, yv_l(yr_get(rno, "label")), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_MOV_D_R, R_RAX, -1, 1, -8, -1, R_RCX, 64);
    Yv *yes = next_loc(st);
    st = yr_get(yes, "st");
    long i = 0;
    while (i < yv_len(ts)) {
        Yv *dr = ty_desc_in(st, ya_get(ts, i), inu);
        st = yr_get(dr, "st");
        st = emit_insn(st, F_LEA_P_R, -1, -1, 1, 0, yv_l(yr_get(dr, "label")), R_RDX, 64);
        st = emit_insn(st, F_CMP_R_R, R_RDX, 64, R_RCX, 64, 0, 0, 0);
        st = emit_insn(st, F_JE_L, yv_l(yr_get(yes, "label")), 0, 0, 0, 0, 0, 0);
        i = i + 1;
    }
    st = emit_label(st, yv_l(yr_get(rno, "label")));
    st = emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
    st = emit_insn(st, F_JMP_L, yv_l(yr_get(rdone, "label")), 0, 0, 0, 0, 0, 0);
    st = emit_label(st, yv_l(yr_get(yes, "label")));
    st = emit_insn(st, F_MOV_I_R, 1, R_RAX, 64, 0, 0, 0, 0);
    return emit_label(st, yv_l(yr_get(rdone, "label")));
}

// Union value in %rax -> its string form: the member its descriptor names
// ("<union>" for none).
Yv *gen_union_str_rax(Yv *st, Yv *t, Yv *path) {
    Yv *ms = union_parts(t);
    Yv *rdone = next_loc(st);
    st = yr_get(rdone, "st");
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    long m = 0;
    while (m < yv_len(ms)) {
        Yv *rnext = next_loc(st);
        st = yr_get(rnext, "st");
        Yv *mt = ya_get(ms, m);
        Yv *one = yav(0);
        one = ya_push(one, mt);
        st = emit_insn(st, F_MOV_0_R, R_RSP, -1, 1, -1, -1, R_RAX, 64);
        st = gen_tag_in(st, one, t);
        st = emit_insn(st, F_TEST_R_R, R_RAX, 64, R_RAX, 64, 0, 0, 0);
        st = emit_insn(st, F_JZ_L, yv_l(yr_get(rnext, "label")), 0, 0, 0, 0, 0, 0);
        st = emit_insn(st, F_POP_R, R_RAX, 64, 0, 0, 0, 0, 0);
        Yv *mu = unfold(mt);
        st = gen_rec_str_rax(st, mu, union_lay(mu, t), path_push(path, t));
        st = emit_insn(st, F_JMP_L, yv_l(yr_get(rdone, "label")), 0, 0, 0, 0, 0, 0);
        st = emit_label(st, yv_l(yr_get(rnext, "label")));
        m = m + 1;
    }
    st = emit_insn(st, F_POP_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen_str_const(st, ys("<union>"));
    return emit_label(st, yv_l(yr_get(rdone, "label")));
}

/* Indirect call through a closure value produced by `callee`. */
Yv *gen_indirect(Yv *st, Yv *node, Yv *callee) {
    Yv *args = yr_get(node, "args");
    long n = yv_len(args);
    Yv *iptypes = fn_args_of(infer(st, callee));
    st = gen(st, callee);
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen_push_args_as(st, args, iptypes);
    /* Reload the closure (it sits just below the n pushed args) and call
     * through its code pointer. */
    st = emit_insn(st, F_MOV_D_R, R_RSP, -1, 1, 8 * n, -1, R_RAX, 64);
    st = emit_insn(st, F_MOV_0_R, R_RAX, -1, 1, -1, -1, R_RAX, 64);
    st = emit_insn(st, F_CALL_IND, R_RAX, 64, 0, 0, 0, 0, 0);
    return emit_insn(st, F_ADD_I_R, 8 * (n + 1), R_RSP, 64, 0, 0, 0, 0);
}

Yv *gen_un(Yv *st, Yv *node) {
    Yv *ut = infer(st, yr_get(node, "e"));
    st = gen(st, yr_get(node, "e"));
    if (ys_eq_lit(yr_get(node, "op"), "-")) {
        if (yv_l(yr_get(ut, "k")) == K_tfloat) {
            /* flip the sign bit: -0.0 is a negative zero, -nan a nan */
            st = emit_insn(st, F_MOV_I_R, 1, R_RCX, 64, 0, 0, 0, 0);
            st = emit_insn(st, F_SHL_I_R, 63, R_RCX, 64, 0, 0, 0, 0);
            return emit_insn(st, F_XOR_R_R, R_RCX, 64, R_RAX, 64, 0, 0, 0);
        } else {
            return emit_insn(st, F_NEG_R, R_RAX, 64, 0, 0, 0, 0, 0);
        }
    } else if (ys_eq_lit(yr_get(node, "op"), "~")) {
        return emit_insn(st, F_NOT_R, R_RAX, 64, 0, 0, 0, 0, 0);
    } else {
        return emit_insn(st, F_XOR_I_R, 1, R_RAX, 64, 0, 0, 0, 0);
    }
}

Yv *gen_addr(Yv *st, Yv *node) {
    /* Checker guarantees plain ids, or id-rooted index into an array. */
    if (yv_l(yr_get(yr_get(node, "e"), "k")) == K_index) {
        return gen_elem_addr(st, yr_get(node, "e"));
    } else {
        Yv *e = env_find(st, yr_get(yr_get(node, "e"), "v"));
        if (ys_eq_lit(yr_get(e, "kind"), "box")) {
            /* the shared cell IS the variable's address */
            return emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, yv_l(yr_get(e, "off")), -1, R_RAX, 64);
        } else if (ys_eq_lit(yr_get(e, "kind"), "global")) {
            return emit_insn(st, F_LEA_P_R, -1, -1, 1, 0,
                             yv_l(yr_get(e, "label")), R_RAX, 64);
        } else if (ys_eq_lit(yr_get(e, "kind"), "capture")) {
            long aidx = ys_tonum(yr_get(e, "mark"));
            st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, yv_l(yr_get(e, "off")), -1, R_RCX, 64);
            return emit_insn(st, F_MOV_D_R, R_RCX, -1, 1, 8 * (aidx + 1), -1, R_RAX, 64);
        } else {
            return emit_insn(st, F_LEA_D_R, R_RBP, -1, 1, yv_l(yr_get(e, "off")), -1, R_RAX, 64);
        }
    }
}

/* Address of element arr[idx] in %rax (bounds-trapped). Works for both
 * array kinds: fixed (frame SIB) and heap (header load + SIB). */
Yv *gen_elem_addr(Yv *st, Yv *node) {
    /* &a[i] — an element's address. The base is any array expression
     * (`&grid[0][i]` too) and runs once, before the index (the same order
     * gen_index and the VM use). */
    Yv *earr = yr_get(node, "arr");
    Yv *bt = infer(st, earr);
    long eaesz = arr_elem_bytes(bt);
    long eascale = 8;
    if (eaesz == 1) {
        eascale = 1;
        ;
    }
    st = gen(st, earr);
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen(st, yr_get(node, "idx"));
    st = emit_insn(st, F_MOV_R_R, R_RAX, 64, R_RCX, 64, 0, 0, 0);
    st = emit_insn(st, F_POP_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_TEST_R_R, R_RCX, 64, R_RCX, 64, 0, 0, 0);
    st = emit_insn(st, F_JS_L, yv_l(lbl_new(ys("y_oob"))), 0, 0, 0, 0, 0, 0);
    if (yv_l(yr_get(bt, "k")) == K_tarrfix) {
        st = emit_insn(st, F_CMP_I_R, yv_l(yr_get(bt, "n")), R_RCX, 64, 0, 0, 0, 0);
        st = emit_insn(st, F_JGE_L, yv_l(lbl_new(ys("y_oob"))), 0, 0, 0, 0, 0, 0);
        ;
    } else {
        st = emit_insn(st, F_MOV_0_R, R_RAX, -1, 1, -1, -1, R_RDX, 64);
        st = emit_insn(st, F_CMP_R_R, R_RDX, 64, R_RCX, 64, 0, 0, 0);
        st = emit_insn(st, F_JGE_L, yv_l(lbl_new(ys("y_oob"))), 0, 0, 0, 0, 0, 0);
        ;
    }
    st = emit_insn(st, F_MOV_D_R, R_RAX, -1, 1, 16, -1, R_RAX, 64);
    return emit_insn(st, F_LEA_M_R, R_RAX, R_RCX, eascale, 0, -1, R_RAX, 64);
}

Yv *gen_bin(Yv *st, Yv *node) {
    Yv *op = yr_get(node, "op");
    /* Lazy &&/||: short-circuit jumps, not eager and/or (the right operand
     * must not run when the left already decides). */
    if (ys_eq_lit(op, "&&")) {
        return gen_logic(st, node, 0);
    } else if (ys_eq_lit(op, "||")) {
        return gen_logic(st, node, 1);
    } else if ((ys_eq_lit(op, "==") || ys_eq_lit(op, "!=")) && is_none_id(yr_get(node, "r")) && is_map_read(st, yr_get(node, "l"))) {
        /* m[k] == none, m[k] != none: the key scan decides, nothing is
         * boxed (gen_map_get) */
        if (ys_eq_lit(op, "==")) { return gen_map_get(st, yr_get(node, "l"), ys("none")); } else { return gen_map_get(st, yr_get(node, "l"), ys("has")); }
    } else if ((ys_eq_lit(op, "==") || ys_eq_lit(op, "!=")) && is_none_id(yr_get(node, "l")) && is_map_read(st, yr_get(node, "r"))) {
        if (ys_eq_lit(op, "==")) { return gen_map_get(st, yr_get(node, "r"), ys("none")); } else { return gen_map_get(st, yr_get(node, "r"), ys("has")); }
    } else {
        return gen_bin_rest(st, node);
    }
}

/* Short-circuit logic: value is 0/1; the right operand only evaluates when
 * the left operand does not already decide the result.
 *   a && b : test a -> jz F; test b -> jz F; 1; jmp E; F: 0; E:
 *   a || b : test a -> jnz T; test b -> jnz T; 0; jmp E; T: 1; E: */
Yv *gen_logic(Yv *st, Yv *node, int is_or) {
    Yv *rT = next_loc(st);
    st = yr_get(rT, "st");
    Yv *rF = next_loc(st);
    st = yr_get(rF, "st");
    Yv *rE = next_loc(st);
    st = yr_get(rE, "st");
    st = gen(st, yr_get(node, "l"));
    st = emit_insn(st, F_TEST_R_R, R_RAX, 64, R_RAX, 64, 0, 0, 0);
    if (is_or) {
        st = emit_insn(st, F_JNZ_L, yv_l(yr_get(rT, "label")), 0, 0, 0, 0, 0, 0);
        ;
    }
    if (is_or) {
        ;
    } else {
        st = emit_insn(st, F_JZ_L, yv_l(yr_get(rF, "label")), 0, 0, 0, 0, 0, 0);
        ;
    }
    st = gen(st, yr_get(node, "r"));
    st = emit_insn(st, F_TEST_R_R, R_RAX, 64, R_RAX, 64, 0, 0, 0);
    if (is_or) {
        st = emit_insn(st, F_JNZ_L, yv_l(yr_get(rT, "label")), 0, 0, 0, 0, 0, 0);
        ;
    }
    if (is_or) {
        ;
    } else {
        st = emit_insn(st, F_JZ_L, yv_l(yr_get(rF, "label")), 0, 0, 0, 0, 0, 0);
        ;
    }
    if (is_or) {
        ;
    } else {
        st = emit_insn(st, F_MOV_I_R, 1, R_RAX, 64, 0, 0, 0, 0);
        st = emit_insn(st, F_JMP_L, yv_l(yr_get(rE, "label")), 0, 0, 0, 0, 0, 0);
        ;
    }
    if (is_or) {
        st = emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
        st = emit_insn(st, F_JMP_L, yv_l(yr_get(rE, "label")), 0, 0, 0, 0, 0, 0);
        st = emit_label(st, yv_l(yr_get(rT, "label")));
        st = emit_insn(st, F_MOV_I_R, 1, R_RAX, 64, 0, 0, 0, 0);
        ;
    }
    if (is_or) {
        ;
    } else {
        st = emit_label(st, yv_l(yr_get(rF, "label")));
        st = emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
        ;
    }
    return emit_label(st, yv_l(yr_get(rE, "label")));
}

/* AUTO-STRINGIFY `+`: when a string meets a non-string, stringify the other
 * side (y_long_tostr / y_bool_tostr) and concatenate — the same semantics
 * types.y's typeof_arith gives. tstr+tstr is a plain concat; tstr+tunk falls
 * back to the raw pointer concat (the old behavior) since the runtime type
 * is unknown statically. */
Yv *gen_cat(Yv *st, Yv *node, Yv *lt, Yv *rt) {
    /* NOTE: y_long_tostr / y_bool_tostr take ONE STACK ARG (push; call;
     * add $8) — gen_tostring's pattern. y_str_cat takes two stack args. */
    if (yv_l(yr_get(lt, "k")) == K_tarr ||
        yv_l(yr_get(lt, "k")) == K_tarrfix ||
        yv_l(yr_get(rt, "k")) == K_tarr ||
        yv_l(yr_get(rt, "k")) == K_tarrfix) {
        return gen_cat_arr(st, node, lt, rt);
    }
    if (yv_l(yr_get(lt, "k")) == K_tstr) {
        if (yv_l(yr_get(rt, "k")) == K_tstr) {
            st = gen_push_args(st, yav(2, yr_get(node, "l"),
                                      yr_get(node, "r")));
            st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_str_cat"))), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_ADD_I_R, 16, R_RSP, 64, 0, 0, 0, 0);
        } else if (yv_l(yr_get(rt, "k")) == K_tlong) {
            st = gen(st, yr_get(node, "l"));
            st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
            st = gen(st, yr_get(node, "r"));
            st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_long_tostr"))), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_ADD_I_R, 8, R_RSP, 64, 0, 0, 0, 0);
            st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_str_cat"))), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_ADD_I_R, 16, R_RSP, 64, 0, 0, 0, 0);
        } else if (yv_l(yr_get(rt, "k")) == K_tbool) {
            st = gen(st, yr_get(node, "l"));
            st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
            st = gen(st, yr_get(node, "r"));
            st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_bool_tostr"))), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_ADD_I_R, 8, R_RSP, 64, 0, 0, 0, 0);
            st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_str_cat"))), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_ADD_I_R, 16, R_RSP, 64, 0, 0, 0, 0);
        } else if (yv_l(yr_get(rt, "k")) == K_tfloat) {
            st = gen(st, yr_get(node, "l"));
            st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
            st = gen(st, yr_get(node, "r"));
            st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_float_tostr"))), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_ADD_I_R, 8, R_RSP, 64, 0, 0, 0, 0);
            st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_str_cat"))), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_ADD_I_R, 16, R_RSP, 64, 0, 0, 0, 0);
        } else {
            /* Unknown right operand: treat it as a string. Most unknowns
             * here ARE strings (a field read through an untyped hole infers
             * as tunk — the compiler's own tstr() does exactly that), and
             * the return-type inference in emit_program now pins down the
             * long-returning calls that used to land in this arm. */
            st = gen_push_args(st, yav(2, yr_get(node, "l"),
                                      yr_get(node, "r")));
            st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_str_cat"))), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_ADD_I_R, 16, R_RSP, 64, 0, 0, 0, 0);
        }
        ;
    }
    if (yv_l(yr_get(lt, "k")) != K_tstr) {
        if (yv_l(yr_get(lt, "k")) == K_tlong) {
            st = gen(st, yr_get(node, "l"));
            st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_long_tostr"))), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_ADD_I_R, 8, R_RSP, 64, 0, 0, 0, 0);
            st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
            st = gen(st, yr_get(node, "r"));
            st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_str_cat"))), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_ADD_I_R, 16, R_RSP, 64, 0, 0, 0, 0);
        } else if (yv_l(yr_get(lt, "k")) == K_tbool) {
            st = gen(st, yr_get(node, "l"));
            st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_bool_tostr"))), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_ADD_I_R, 8, R_RSP, 64, 0, 0, 0, 0);
            st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
            st = gen(st, yr_get(node, "r"));
            st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_str_cat"))), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_ADD_I_R, 16, R_RSP, 64, 0, 0, 0, 0);
        } else if (yv_l(yr_get(lt, "k")) == K_tfloat) {
            st = gen(st, yr_get(node, "l"));
            st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_float_tostr"))), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_ADD_I_R, 8, R_RSP, 64, 0, 0, 0, 0);
            st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
            st = gen(st, yr_get(node, "r"));
            st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_str_cat"))), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_ADD_I_R, 16, R_RSP, 64, 0, 0, 0, 0);
        } else {
            /* Unknown left operand: treat it as a string (see the note on
             * the right-operand arm). */
            st = gen_push_args(st, yav(2, yr_get(node, "l"),
                                      yr_get(node, "r")));
            st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_str_cat"))), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_ADD_I_R, 16, R_RSP, 64, 0, 0, 0, 0);
        }
        ;
    }
    return st;
}

/* Float arithmetic and comparison. Operands arrive in %rax as raw bits;
 * a long operand is widened with cvtsi2sd first (the only coercion). */
Yv *gen_float_bin(Yv *st, Yv *node, Yv *lt, Yv *rt) {
    Yv *op = yr_get(node, "op");
    st = gen(st, yr_get(node, "l"));
    if (yv_l(yr_get(lt, "k")) == K_tfloat) {
        ;
    } else {
        st = emit_insn(st, F_CVTSI2SD_R_R, R_RAX, 64, R_XMM0, 128, 0, 0, 0);
        st = emit_insn(st, F_MOVQ_R_R, R_XMM0, 128, R_RAX, 64, 0, 0, 0);
        ;
    }
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen(st, yr_get(node, "r"));
    if (yv_l(yr_get(rt, "k")) == K_tfloat) {
        ;
    } else {
        st = emit_insn(st, F_CVTSI2SD_R_R, R_RAX, 64, R_XMM0, 128, 0, 0, 0);
        st = emit_insn(st, F_MOVQ_R_R, R_XMM0, 128, R_RAX, 64, 0, 0, 0);
        ;
    }
    st = emit_insn(st, F_MOVQ_R_R, R_RAX, 64, R_XMM1, 128, 0, 0, 0);
    st = emit_insn(st, F_POP_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_MOVQ_R_R, R_RAX, 64, R_XMM0, 128, 0, 0, 0);
    if (ys_eq_lit(op, "+")) {
        st = emit_insn(st, F_ADDSD_R_R, R_XMM1, 128, R_XMM0, 128, 0, 0, 0);
        return emit_insn(st, F_MOVQ_R_R, R_XMM0, 128, R_RAX, 64, 0, 0, 0);
    } else if (ys_eq_lit(op, "-")) {
        st = emit_insn(st, F_SUBSD_R_R, R_XMM1, 128, R_XMM0, 128, 0, 0, 0);
        return emit_insn(st, F_MOVQ_R_R, R_XMM0, 128, R_RAX, 64, 0, 0, 0);
    } else if (ys_eq_lit(op, "*")) {
        st = emit_insn(st, F_MULSD_R_R, R_XMM1, 128, R_XMM0, 128, 0, 0, 0);
        return emit_insn(st, F_MOVQ_R_R, R_XMM0, 128, R_RAX, 64, 0, 0, 0);
    } else if (ys_eq_lit(op, "/")) {
        st = emit_insn(st, F_DIVSD_R_R, R_XMM1, 128, R_XMM0, 128, 0, 0, 0);
        return emit_insn(st, F_MOVQ_R_R, R_XMM0, 128, R_RAX, 64, 0, 0, 0);
    } else if (ys_eq_lit(op, "%")) {
        /* The IEEE remainder truncated toward zero -- C's fmod, the one with
         * the dividend's sign. There is no x87-style bit twiddling for it on
         * SSE2 (fmod has no instruction), so the prelude does the reduction;
         * both operands are already in SSE registers. */
        st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_fmod"))), 0, 0, 0, 0, 0, 0);
        return emit_insn(st, F_MOVQ_R_R, R_XMM0, 128, R_RAX, 64, 0, 0, 0);
    } else {
        /* Comparisons. ucomisd sets ZF=PF=CF=1 when the operands are unordered
         * (a NaN anywhere), so every test has to look at the parity flag: the
         * unsigned conditions on their own (a/ae/b/be) read unordered as
         * ordered.
         *
         * `<` and `<=` compare the operands the other way round and take the
         * conditions that test CF=0, which unordered cannot satisfy; `>` and
         * `>=` already did. `==` and `!=` cannot be spelled out of CF/ZF at
         * all, so they test parity as well: two byte results and a combine,
         * since this assembler has no 8-bit `and`/`or`. */
        if (ys_eq_lit(op, "<")) {
            st = emit_insn(st, F_UCOMISD_R_R, R_XMM0, 128, R_XMM1, 128, 0, 0, 0);
            st = emit_insn(st, F_SETA_R, R_RAX, 8, 0, 0, 0, 0, 0);
            return emit_insn(st, F_MOVZBQ_R_R, R_RAX, 8, R_RAX, 64, 0, 0, 0);
        } else if (ys_eq_lit(op, "<=")) {
            st = emit_insn(st, F_UCOMISD_R_R, R_XMM0, 128, R_XMM1, 128, 0, 0, 0);
            st = emit_insn(st, F_SETAE_R, R_RAX, 8, 0, 0, 0, 0, 0);
            return emit_insn(st, F_MOVZBQ_R_R, R_RAX, 8, R_RAX, 64, 0, 0, 0);
        } else if (ys_eq_lit(op, ">")) {
            st = emit_insn(st, F_UCOMISD_R_R, R_XMM1, 128, R_XMM0, 128, 0, 0, 0);
            st = emit_insn(st, F_SETA_R, R_RAX, 8, 0, 0, 0, 0, 0);
            return emit_insn(st, F_MOVZBQ_R_R, R_RAX, 8, R_RAX, 64, 0, 0, 0);
        } else if (ys_eq_lit(op, ">=")) {
            st = emit_insn(st, F_UCOMISD_R_R, R_XMM1, 128, R_XMM0, 128, 0, 0, 0);
            st = emit_insn(st, F_SETAE_R, R_RAX, 8, 0, 0, 0, 0, 0);
            return emit_insn(st, F_MOVZBQ_R_R, R_RAX, 8, R_RAX, 64, 0, 0, 0);
        } else {
            st = emit_insn(st, F_UCOMISD_R_R, R_XMM1, 128, R_XMM0, 128, 0, 0, 0);
            if (ys_eq_lit(op, "==")) {
                st = emit_insn(st, F_SETE_R, R_RAX, 8, 0, 0, 0, 0, 0);
                st = emit_insn(st, F_SETNP_R, R_RCX, 8, 0, 0, 0, 0, 0);
            } else {
                st = emit_insn(st, F_SETNE_R, R_RAX, 8, 0, 0, 0, 0, 0);
                st = emit_insn(st, F_SETP_R, R_RCX, 8, 0, 0, 0, 0, 0);
            }
            st = emit_insn(st, F_MOVZBQ_R_R, R_RAX, 8, R_RAX, 64, 0, 0, 0);
            st = emit_insn(st, F_MOVZBQ_R_R, R_RCX, 8, R_RCX, 64, 0, 0, 0);
            if (ys_eq_lit(op, "==")) {
                st = emit_insn(st, F_AND_R_R, R_RCX, 64, R_RAX, 64, 0, 0, 0);
            } else {
                st = emit_insn(st, F_OR_R_R, R_RCX, 64, R_RAX, 64, 0, 0, 0);
            }
            return st;
        }
    }
}

Yv *gen_str_cmp(Yv *st, Yv *node, Yv *op) {
    st = gen_push_args(st, yav(2, yr_get(node, "l"), yr_get(node, "r")));
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_str_cmp"))), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_ADD_I_R, 16, R_RSP, 64, 0, 0, 0, 0);
    st = emit_insn(st, F_CMP_I_R, 0, R_RAX, 64, 0, 0, 0, 0);
    if (ys_eq_lit(op, "<")) {
        st = emit_insn(st, F_SETL_R, R_RAX, 8, 0, 0, 0, 0, 0);
        ;
    } else if (ys_eq_lit(op, ">")) {
        st = emit_insn(st, F_SETG_R, R_RAX, 8, 0, 0, 0, 0, 0);
        ;
    } else if (ys_eq_lit(op, "<=")) {
        st = emit_insn(st, F_SETLE_R, R_RAX, 8, 0, 0, 0, 0, 0);
        ;
    } else {
        st = emit_insn(st, F_SETGE_R, R_RAX, 8, 0, 0, 0, 0, 0);
        ;
    }
    return emit_insn(st, F_MOVZBQ_R_R, R_RAX, 8, R_RAX, 64, 0, 0, 0);
}

/* == on values whose equality looks inside them (NATIVE.md, "Equality"):
 * two options compare their payloads, and an array compares each pair of
 * elements with the element type's own ==, at any depth. Arrays of words
 * whose == is the bit pattern, and arrays of strings, keep the y_arr_eq /
 * y_arr_eq_str cores; the others loop here: options and arrays look
 * inside, and floats compare as numbers (0.0 == -0.0). */
int eq_elem_loop(Yv *t) {
    return yv_l(yr_get(t, "k")) == K_topt ||
           yv_l(yr_get(t, "k")) == K_tarr ||
           yv_l(yr_get(t, "k")) == K_tfloat;
}

/* The left operand pushed, the right one in %rax: pops the left and leaves
 * left == right (0 or 1) in %rax, compared as type t. */
Yv *gen_eq_vals(Yv *st, Yv *t) {
    if (yv_l(yr_get(t, "k")) == K_topt) {
        return gen_eq_opt(st, yr_get(t, "of"));
    } else if (yv_l(yr_get(t, "k")) == K_tarr) {
        if (eq_elem_loop(yr_get(t, "of"))) {
            return gen_eq_arr_deep(st, yr_get(t, "of"));
        } else if (yv_l(yr_get(yr_get(t, "of"), "k")) == K_tstr) {
            st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_arr_eq_str"))), 0, 0, 0, 0, 0, 0);
            return emit_insn(st, F_ADD_I_R, 16, R_RSP, 64, 0, 0, 0, 0);
        } else {
            st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_MOV_I_R, elem_bytes(yr_get(t, "of")), R_RAX, 64, 0, 0, 0, 0);
            st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_arr_eq"))), 0, 0, 0, 0, 0, 0);
            return emit_insn(st, F_ADD_I_R, 24, R_RSP, 64, 0, 0, 0, 0);
        }
    } else if (yv_l(yr_get(t, "k")) == K_tstr) {
        st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_str_eq"))), 0, 0, 0, 0, 0, 0);
        return emit_insn(st, F_ADD_I_R, 16, R_RSP, 64, 0, 0, 0, 0);
    } else if (yv_l(yr_get(t, "k")) == K_tfloat) {
        /* as gen_float_bin's ==: equal, and ordered -- NaN is equal to nothing,
         * itself included, which is what setnp is for */
        st = emit_insn(st, F_MOVQ_R_R, R_RAX, 64, R_XMM1, 128, 0, 0, 0);
        st = emit_insn(st, F_POP_R, R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, F_MOVQ_R_R, R_RAX, 64, R_XMM0, 128, 0, 0, 0);
        st = emit_insn(st, F_UCOMISD_R_R, R_XMM1, 128, R_XMM0, 128, 0, 0, 0);
        st = emit_insn(st, F_SETE_R, R_RAX, 8, 0, 0, 0, 0, 0);
        st = emit_insn(st, F_SETNP_R, R_RCX, 8, 0, 0, 0, 0, 0);
        st = emit_insn(st, F_MOVZBQ_R_R, R_RAX, 8, R_RAX, 64, 0, 0, 0);
        st = emit_insn(st, F_MOVZBQ_R_R, R_RCX, 8, R_RCX, 64, 0, 0, 0);
        return emit_insn(st, F_AND_R_R, R_RCX, 64, R_RAX, 64, 0, 0, 0);
    } else {
        /* one word: a scalar by value, a record or map by identity */
        st = emit_insn(st, F_POP_R, R_RCX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, F_CMP_R_R, R_RAX, 64, R_RCX, 64, 0, 0, 0);
        st = emit_insn(st, F_SETE_R, R_RAX, 8, 0, 0, 0, 0, 0);
        return emit_insn(st, F_MOVZBQ_R_R, R_RAX, 8, R_RAX, 64, 0, 0, 0);
    }
}

/* gen_eq_vals for two options of payload type pt: equal when both are
 * none, or both are some with equal payloads (a box holds one word). */
Yv *gen_eq_opt(Yv *st, Yv *pt) {
    Yv *lnone = next_loc(st);
    st = yr_get(lnone, "st");
    Yv *lne = next_loc(st);
    st = yr_get(lne, "st");
    Yv *ldone = next_loc(st);
    st = yr_get(ldone, "st");
    st = emit_insn(st, F_POP_R, R_RCX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_TEST_R_R, R_RCX, 64, R_RCX, 64, 0, 0, 0);
    st = emit_insn(st, F_JZ_L, yv_l(yr_get(lnone, "label")), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_TEST_R_R, R_RAX, 64, R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, F_JZ_L, yv_l(yr_get(lne, "label")), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_MOV_0_R, R_RCX, -1, 1, -1, -1, R_RCX, 64);
    st = emit_insn(st, F_PUSH_R, R_RCX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_MOV_0_R, R_RAX, -1, 1, -1, -1, R_RAX, 64);
    st = gen_eq_vals(st, pt);
    st = emit_insn(st, F_JMP_L, yv_l(yr_get(ldone, "label")), 0, 0, 0, 0, 0, 0);
    st = emit_label(st, yv_l(yr_get(lnone, "label")));
    st = emit_insn(st, F_TEST_R_R, R_RAX, 64, R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, F_SETE_R, R_RAX, 8, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_MOVZBQ_R_R, R_RAX, 8, R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, F_JMP_L, yv_l(yr_get(ldone, "label")), 0, 0, 0, 0, 0, 0);
    st = emit_label(st, yv_l(yr_get(lne, "label")));
    st = emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
    return emit_label(st, yv_l(yr_get(ldone, "label")));
}

/* gen_eq_vals for two arrays whose elements (of type et) need their own
 * == (eq_elem_loop): same length, then each pair compared as et. The loop
 * keeps its state on the stack, since an element compare may call the
 * string and array cores: from the top, the index, the right array, the
 * left. */
Yv *gen_eq_arr_deep(Yv *st, Yv *et) {
    Yv *lloop = next_loc(st);
    st = yr_get(lloop, "st");
    Yv *lsame = next_loc(st);
    st = yr_get(lsame, "st");
    Yv *ldiff = next_loc(st);
    st = yr_get(ldiff, "st");
    Yv *lne = next_loc(st);
    st = yr_get(lne, "st");
    Yv *ldone = next_loc(st);
    st = yr_get(ldone, "st");
    st = emit_insn(st, F_POP_R, R_RCX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_MOV_0_R, R_RCX, -1, 1, -1, -1, R_RDX, 64);
    st = emit_insn(st, F_MOV_0_R, R_RAX, -1, 1, -1, -1, R_RSI, 64);
    st = emit_insn(st, F_CMP_R_R, R_RSI, 64, R_RDX, 64, 0, 0, 0);
    st = emit_insn(st, F_JNE_L, yv_l(yr_get(lne, "label")), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_PUSH_R, R_RCX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_XOR_R_R, R_RDX, 32, R_RDX, 32, 0, 0, 0);
    st = emit_insn(st, F_PUSH_R, R_RDX, 64, 0, 0, 0, 0, 0);
    st = emit_label(st, yv_l(yr_get(lloop, "label")));
    st = emit_insn(st, F_MOV_0_R, R_RSP, -1, 1, -1, -1, R_RDX, 64);
    st = emit_insn(st, F_MOV_D_R, R_RSP, -1, 1, 16, -1, R_RCX, 64);
    st = emit_insn(st, F_MOV_0_R, R_RCX, -1, 1, -1, -1, R_RSI, 64);
    st = emit_insn(st, F_CMP_R_R, R_RSI, 64, R_RDX, 64, 0, 0, 0);
    st = emit_insn(st, F_JGE_L, yv_l(yr_get(lsame, "label")), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_MOV_D_R, R_RCX, -1, 1, 16, -1, R_RCX, 64);
    st = emit_insn(st, F_MOV_M_R, R_RCX, R_RDX, 8, 0, -1, R_RCX, 64);
    st = emit_insn(st, F_MOV_D_R, R_RSP, -1, 1, 8, -1, R_RAX, 64);
    st = emit_insn(st, F_MOV_D_R, R_RAX, -1, 1, 16, -1, R_RAX, 64);
    st = emit_insn(st, F_MOV_M_R, R_RAX, R_RDX, 8, 0, -1, R_RAX, 64);
    st = emit_insn(st, F_PUSH_R, R_RCX, 64, 0, 0, 0, 0, 0);
    st = gen_eq_vals(st, et);
    st = emit_insn(st, F_TEST_R_R, R_RAX, 64, R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, F_JZ_L, yv_l(yr_get(ldiff, "label")), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_MOV_0_R, R_RSP, -1, 1, -1, -1, R_RDX, 64);
    st = emit_insn(st, F_INC_R, R_RDX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_MOV_R_0, R_RDX, 64, R_RSP, -1, 1, -1, -1);
    st = emit_insn(st, F_JMP_L, yv_l(yr_get(lloop, "label")), 0, 0, 0, 0, 0, 0);
    st = emit_label(st, yv_l(yr_get(lsame, "label")));
    st = emit_insn(st, F_ADD_I_R, 24, R_RSP, 64, 0, 0, 0, 0);
    st = emit_insn(st, F_MOV_I_R, 1, R_RAX, 64, 0, 0, 0, 0);
    st = emit_insn(st, F_JMP_L, yv_l(yr_get(ldone, "label")), 0, 0, 0, 0, 0, 0);
    st = emit_label(st, yv_l(yr_get(ldiff, "label")));
    st = emit_insn(st, F_ADD_I_R, 24, R_RSP, 64, 0, 0, 0, 0);
    st = emit_label(st, yv_l(yr_get(lne, "label")));
    st = emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
    return emit_label(st, yv_l(yr_get(ldone, "label")));
}

Yv *gen_bin_rest(Yv *st, Yv *node) {
    Yv *op = yr_get(node, "op");
    Yv *lt = infer(st, yr_get(node, "l"));
    Yv *rt = infer(st, yr_get(node, "r"));
    if (ys_eq_lit(op, "+") &&
        (yv_l(yr_get(lt, "k")) == K_tstr ||
         yv_l(yr_get(rt, "k")) == K_tstr)) {
        return gen_cat(st, node, lt, rt);
    } else if (ys_eq_lit(op, "+") &&
               (yv_l(yr_get(lt, "k")) == K_tarr ||
                yv_l(yr_get(rt, "k")) == K_tarr ||
                yv_l(yr_get(lt, "k")) == K_tarrfix ||
                yv_l(yr_get(rt, "k")) == K_tarrfix)) {
        /* array `+` is the copy-concat form (gen_cat splits off the array
         * case first), not numeric add on the header pointers. */
        return gen_cat(st, node, lt, rt);
    } else if (ys_eq_lit(op, "::")) {
        return gen_cons(st, node);
    } else if (ys_eq_lit(op, "<<") || ys_eq_lit(op, ">>") ||
               ys_eq_lit(op, ">>>")) {
        return gen_shift(st, node, op);
    } else if (yv_l(yr_get(lt, "k")) == K_tfloat ||
               yv_l(yr_get(rt, "k")) == K_tfloat) {
        return gen_float_bin(st, node, lt, rt);
    } else if ((ys_eq_lit(op, "==") || ys_eq_lit(op, "!=")) &&
               (yv_l(yr_get(lt, "k")) == K_tstr ||
                yv_l(yr_get(rt, "k")) == K_tstr)) {
        /* Not folded on two literals, and not by design: measured over ycc's
         * own output, all 1,291 y_str_eq calls have at least one runtime
         * operand -- 1,209 of them compare a token's text or a ktag() result
         * against a literal, 82 compare two computed strings, and *zero*
         * compare two literals. Across the 442-program corpus 5 programs
         * concatenate two literals and 3 take len("literal"); a constant
         * folder for those shapes would be ~200 instructions of emitter (this
         * file) to save a handful of instructions in eight test fixtures. The
         * tag-name arms of the same shape -- ktag(K.x) == "x" in tags_agree --
         * would need interprocedural knowledge of a const record, and that
         * function is a self-check besides. */
        st = gen_push_args(st, yav(2, yr_get(node, "l"), yr_get(node, "r")));
        st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_str_eq"))), 0, 0, 0, 0, 0, 0);
        st = emit_insn(st, F_ADD_I_R, 16, R_RSP, 64, 0, 0, 0, 0);
        if (ys_eq_lit(op, "!=")) {
            return emit_insn(st, F_XOR_I_R, 1, R_RAX, 64, 0, 0, 0, 0);
        } else {
            return st;
        }
    } else if ((ys_eq_lit(op, "<") || ys_eq_lit(op, ">") ||
                ys_eq_lit(op, "<=") || ys_eq_lit(op, ">=")) &&
               yv_l(yr_get(lt, "k")) == K_tstr) {
        /* Lexicographic ordering: y_str_cmp returns the SIGN, so the normal
         * signed setcc forms work on its result against 0. */
        return gen_str_cmp(st, node, op);
    } else if ((ys_eq_lit(op, "==") || ys_eq_lit(op, "!=")) &&
               (yv_l(yr_get(lt, "k")) == K_tarr ||
                yv_l(yr_get(rt, "k")) == K_tarr)) {
        /* Arrays compare STRUCTURALLY (length then elements), matching
         * yv.c's yv_eq for Y_ARR — `arr == []` is an emptiness test, not a
         * pointer comparison. String elements compare by value, and
         * elements that are arrays, options or floats by their own ==
         * (gen_eq_vals). */
        Yv *elt = yr(1, "k", yv_long(K_tunk));
        if (yv_l(yr_get(lt, "k")) == K_tarr) {
            elt = yr_get(lt, "of");
            ;
        }
        if (yv_l(yr_get(elt, "k")) == K_tunk) {
            if (yv_l(yr_get(rt, "k")) == K_tarr) {
                elt = yr_get(rt, "of");
                ;
            }
            ;
        }
        if (eq_elem_loop(elt)) {
            st = gen(st, yr_get(node, "l"));
            st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
            st = gen(st, yr_get(node, "r"));
            st = gen_eq_arr_deep(st, elt);
            ;
        } else {
            st = gen_push_args(st, yav(2, yr_get(node, "l"), yr_get(node, "r")));
            if (yv_l(yr_get(elt, "k")) == K_tstr) {
                st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_arr_eq_str"))), 0, 0, 0, 0, 0, 0);
                st = emit_insn(st, F_ADD_I_R, 16, R_RSP, 64, 0, 0, 0, 0);
                ;
            } else {
                st = emit_insn(st, F_MOV_I_R, elem_bytes(elt), R_RAX, 64, 0, 0, 0, 0);
                st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
                st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_arr_eq"))), 0, 0, 0, 0, 0, 0);
                st = emit_insn(st, F_ADD_I_R, 24, R_RSP, 64, 0, 0, 0, 0);
                ;
            }
            ;
        }
        if (ys_eq_lit(op, "!=")) {
            return emit_insn(st, F_XOR_I_R, 1, R_RAX, 64, 0, 0, 0, 0);
        } else {
            return st;
        }
    } else if ((ys_eq_lit(op, "==") || ys_eq_lit(op, "!=")) &&
               (yv_l(yr_get(lt, "k")) == K_topt ||
                yv_l(yr_get(rt, "k")) == K_topt) &&
               !is_none_id(yr_get(node, "l")) &&
               !is_none_id(yr_get(node, "r"))) {
        /* Two options compare their payloads (gen_eq_opt); `x == none`
         * stays the one-word test below. */
        Yv *pt = yr(1, "k", yv_long(K_tunk));
        if (yv_l(yr_get(lt, "k")) == K_topt) {
            pt = yr_get(lt, "of");
            ;
        }
        if (yv_l(yr_get(pt, "k")) == K_tunk) {
            if (yv_l(yr_get(rt, "k")) == K_topt) {
                pt = yr_get(rt, "of");
                ;
            }
            ;
        }
        st = gen(st, yr_get(node, "l"));
        st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
        st = gen(st, yr_get(node, "r"));
        st = gen_eq_opt(st, pt);
        if (ys_eq_lit(op, "!=")) {
            return emit_insn(st, F_XOR_I_R, 1, R_RAX, 64, 0, 0, 0, 0);
        } else {
            return st;
        }
    } else {
        st = gen(st, yr_get(node, "l"));
        st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
        st = gen(st, yr_get(node, "r"));
        st = emit_insn(st, F_MOV_R_R, R_RAX, 64, R_RCX, 64, 0, 0, 0);
        st = emit_insn(st, F_POP_R, R_RAX, 64, 0, 0, 0, 0, 0);
        if (ys_eq_lit(op, "+")) {
            return emit_insn(st, F_ADD_R_R, R_RCX, 64, R_RAX, 64, 0, 0, 0);
        } else if (ys_eq_lit(op, "-")) {
            return emit_insn(st, F_SUB_R_R, R_RCX, 64, R_RAX, 64, 0, 0, 0);
        } else if (ys_eq_lit(op, "*")) {
            return emit_insn(st, F_IMUL_R_R, R_RCX, 64, R_RAX, 64, 0, 0, 0);
        } else if (ys_eq_lit(op, "/")) {
            /* idiv raises #DE on LONG_MIN / -1 (the quotient does not fit),
             * so divisor -1 is handled as a negation instead: neg of
             * LONG_MIN wraps back to LONG_MIN (the language's rule for the
             * whole long range, NATIVE.md), and every other value negates
             * exactly. */
            st = emit_insn(st, F_TEST_R_R, R_RCX, 64, R_RCX, 64, 0, 0, 0);
            st = emit_insn(st, F_JZ_L, yv_l(lbl_new(ys("y_div_zero"))), 0, 0, 0, 0, 0, 0);
            Yv *d1 = next_loc(st);
            st = yr_get(d1, "st");
            Yv *d2 = next_loc(st);
            st = yr_get(d2, "st");
            st = emit_insn(st, F_CMP_I_R, -1, R_RCX, 64, 0, 0, 0, 0);
            st = emit_insn(st, F_JNE_L, yv_l(yr_get(d1, "label")), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_NEG_R, R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_JMP_L, yv_l(yr_get(d2, "label")), 0, 0, 0, 0, 0, 0);
            st = emit_label(st, yv_l(yr_get(d1, "label")));
            st = emit_insn(st, F_CQO, 0, 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_IDIV_R, R_RCX, 64, 0, 0, 0, 0, 0);
            return emit_label(st, yv_l(yr_get(d2, "label")));
        } else if (ys_eq_lit(op, "%")) {
            /* Same #DE: x % -1 is 0 for every x (see the `/` note). */
            st = emit_insn(st, F_TEST_R_R, R_RCX, 64, R_RCX, 64, 0, 0, 0);
            st = emit_insn(st, F_JZ_L, yv_l(lbl_new(ys("y_div_zero"))), 0, 0, 0, 0, 0, 0);
            Yv *m1 = next_loc(st);
            st = yr_get(m1, "st");
            Yv *m2 = next_loc(st);
            st = yr_get(m2, "st");
            st = emit_insn(st, F_CMP_I_R, -1, R_RCX, 64, 0, 0, 0, 0);
            st = emit_insn(st, F_JNE_L, yv_l(yr_get(m1, "label")), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
            st = emit_insn(st, F_JMP_L, yv_l(yr_get(m2, "label")), 0, 0, 0, 0, 0, 0);
            st = emit_label(st, yv_l(yr_get(m1, "label")));
            st = emit_insn(st, F_CQO, 0, 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_IDIV_R, R_RCX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_MOV_R_R, R_RDX, 64, R_RAX, 64, 0, 0, 0);
            return emit_label(st, yv_l(yr_get(m2, "label")));
        } else if (ys_eq_lit(op, "<")) {
            st = emit_insn(st, F_CMP_R_R, R_RCX, 64, R_RAX, 64, 0, 0, 0);
            st = emit_insn(st, F_SETL_R, R_RAX, 8, 0, 0, 0, 0, 0);
            return emit_insn(st, F_MOVZBQ_R_R, R_RAX, 8, R_RAX, 64, 0, 0, 0);
        } else if (ys_eq_lit(op, ">")) {
            st = emit_insn(st, F_CMP_R_R, R_RCX, 64, R_RAX, 64, 0, 0, 0);
            st = emit_insn(st, F_SETG_R, R_RAX, 8, 0, 0, 0, 0, 0);
            return emit_insn(st, F_MOVZBQ_R_R, R_RAX, 8, R_RAX, 64, 0, 0, 0);
        } else if (ys_eq_lit(op, "<=")) {
            st = emit_insn(st, F_CMP_R_R, R_RCX, 64, R_RAX, 64, 0, 0, 0);
            st = emit_insn(st, F_SETLE_R, R_RAX, 8, 0, 0, 0, 0, 0);
            return emit_insn(st, F_MOVZBQ_R_R, R_RAX, 8, R_RAX, 64, 0, 0, 0);
        } else if (ys_eq_lit(op, ">=")) {
            st = emit_insn(st, F_CMP_R_R, R_RCX, 64, R_RAX, 64, 0, 0, 0);
            st = emit_insn(st, F_SETGE_R, R_RAX, 8, 0, 0, 0, 0, 0);
            return emit_insn(st, F_MOVZBQ_R_R, R_RAX, 8, R_RAX, 64, 0, 0, 0);
        } else if (ys_eq_lit(op, "==")) {
            st = emit_insn(st, F_CMP_R_R, R_RCX, 64, R_RAX, 64, 0, 0, 0);
            st = emit_insn(st, F_SETE_R, R_RAX, 8, 0, 0, 0, 0, 0);
            return emit_insn(st, F_MOVZBQ_R_R, R_RAX, 8, R_RAX, 64, 0, 0, 0);
        } else if (ys_eq_lit(op, "!=")) {
            st = emit_insn(st, F_CMP_R_R, R_RCX, 64, R_RAX, 64, 0, 0, 0);
            st = emit_insn(st, F_SETNE_R, R_RAX, 8, 0, 0, 0, 0, 0);
            return emit_insn(st, F_MOVZBQ_R_R, R_RAX, 8, R_RAX, 64, 0, 0, 0);
        } else if (ys_eq_lit(op, "&")) {
            return emit_insn(st, F_AND_R_R, R_RCX, 64, R_RAX, 64, 0, 0, 0);
        } else if (ys_eq_lit(op, "|")) {
            return emit_insn(st, F_OR_R_R, R_RCX, 64, R_RAX, 64, 0, 0, 0);
        } else if (ys_eq_lit(op, "^")) {
            return emit_insn(st, F_XOR_R_R, R_RCX, 64, R_RAX, 64, 0, 0, 0);
        }
        /* No &&/|| arms here: gen_bin routes those to gen_logic (lazy
           jumps) BEFORE calling this, so an eager and/or would be dead
           code. */
        return st;
    }
    return st;
}

/* `x << n`, `x >> n` (arithmetic: the sign fills in) and `x >>> n`
 * (logical: zeros fill in). x86 uses only the count's low 6 bits; Y does
 * not wrap: a count of 64 or more shifts every bit out (0, or all sign
 * bits for `>>`) and a negative count stops the program (y_shift_neg). A
 * literal count of 0 to 63 is the instruction's immediate and needs
 * neither check. */
Yv *gen_shift(Yv *st, Yv *node, Yv *op) {
    Yv *mn = ys("shl");
    long fi = F_SHL_I_R;
    long fr = F_SHL_R_R;
    if (ys_eq_lit(op, ">>")) {
        mn = ys("sar");
        fi = F_SAR_I_R;
        fr = F_SAR_R_R;
        ;
    } else if (ys_eq_lit(op, ">>>")) {
        mn = ys("shr");
        fi = F_SHR_I_R;
        fr = F_SHR_R_R;
        ;
    }
    long n = shift_imm(yr_get(node, "r"));
    st = gen(st, yr_get(node, "l"));
    if (n >= 0) {
        return emit_insn(st, fi, n, R_RAX, 64, 0, 0, 0, 0);
    } else {
        st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
        st = gen(st, yr_get(node, "r"));
        st = emit_insn(st, F_MOV_R_R, R_RAX, 64, R_RCX, 64, 0, 0, 0);
        st = emit_insn(st, F_POP_R, R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, F_TEST_R_R, R_RCX, 64, R_RCX, 64, 0, 0, 0);
        st = emit_insn(st, F_JS_L, yv_l(lbl_new(ys("y_shift_neg"))), 0, 0, 0, 0, 0, 0);
        Yv *ok = next_loc(st);
        st = yr_get(ok, "st");
        st = emit_insn(st, F_CMP_I_R, 64, R_RCX, 64, 0, 0, 0, 0);
        st = emit_insn(st, F_JB_L, yv_l(yr_get(ok, "label")), 0, 0, 0, 0, 0, 0);
        if (ys_eq_lit(mn, "sar")) {
            st = emit_insn(st, F_MOV_I_R, 63, R_RCX, 64, 0, 0, 0, 0);
            ;
        } else {
            st = emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
            ;
        }
        st = emit_label(st, yv_l(yr_get(ok, "label")));
        return emit_insn(st, fr, R_RCX, 8, R_RAX, 64, 0, 0, 0);
    }
}

/* The count of a shift when it is a literal from 0 to 63 (gen_shift), else
 * -1. A radix literal may wrap negative (0xFFFF_FFFF_FFFF_FFFF is -1). */
long shift_imm(Yv *r) {
    if (yv_l(yr_get(r, "k")) == K_num) {
        if (lit_is_float(yr_get(r, "v"))) {
            return -1;
        } else {
            Yv *s = norm_num(yr_get(r, "v"));
            if (yv_len(s) > 2 || ys_eq_lit(ys_slice(s, 0, 1), "-")) {
                return -1;
            } else if (ys_tonum(s) < 64) {
                return ys_tonum(s);
            } else {
                return -1;
            }
        }
    } else {
        return -1;
    }
}

/* ── calls ──────────────────────────────────────────────────────────────
 * Linux syscall arg regs (in order): rdi, rsi, rdx, r10, r8, r9. */

long syscall_reg(long i) {
    if (i == 0) {
        return R_RDI;
    } else if (i == 1) {
        return R_RSI;
    } else if (i == 2) {
        return R_RDX;
    } else if (i == 3) {
        return R_R10;
    } else if (i == 4) {
        return R_R8;
    } else {
        return R_R9;
    }
}

Yv *gen_push_args(Yv *st, Yv *args) {
    long i = 0;
    while (i < yv_len(args)) {
        st = gen(st, ya_get(args, i));
        st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
        i = i + 1;
    }
    return st;
}

/* gen_push_args, with argument i converted (gen_as) to ptypes[i], the
 * type of the parameter it binds; arguments past ptypes are pushed as is. */
Yv *gen_push_args_as(Yv *st, Yv *args, Yv *ptypes) {
    long i = 0;
    while (i < yv_len(args)) {
        if (i < yv_len(ptypes)) {
            st = gen_as(st, ya_get(args, i), ya_get(ptypes, i));
            ;
        } else {
            st = gen(st, ya_get(args, i));
            ;
        }
        st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
        i = i + 1;
    }
    return st;
}

/* The implicit numeric conversions (types.y tcompat admits them): a long
 * or byte stored where a float is declared becomes that float, and a long
 * stored where a byte is declared keeps its low 8 bits. The value is in
 * %rax with static type `got`; `want` is the declared type of the place it
 * goes to. A packed [byte] element store (movb) truncates by itself, so
 * those callers ask for no byte conversion. */
Yv *gen_conv(Yv *st, Yv *got, Yv *want) {
    Yv *gk = yr_get(got, "k");
    Yv *wk = yr_get(want, "k");
    if (yv_l(wk) == K_tfloat &&
        (yv_l(gk) == K_tlong || yv_l(gk) == K_tbyte)) {
        st = emit_insn(st, F_CVTSI2SD_R_R, R_RAX, 64, R_XMM0, 128, 0, 0, 0);
        return emit_insn(st, F_MOVQ_R_R, R_XMM0, 128, R_RAX, 64, 0, 0, 0);
    } else if (yv_l(wk) == K_tbyte && yv_l(gk) == K_tlong) {
        return emit_insn(st, F_MOVZBQ_R_R, R_RAX, 8, R_RAX, 64, 0, 0, 0);
    } else {
        return st;
    }
}

/* gen, then gen_conv to `want`: every place a value is stored under a
 * declared type (variable, parameter, return value, element, field,
 * pointee) goes through here. A record literal is created as the declared
 * record type (gen_reclit). A union value going where one of its members,
 * or a union of some of them, is declared is a cast: its tag is checked
 * (gen_cast_check), and a value holding another member stops the program. */
Yv *gen_as(Yv *st, Yv *node, Yv *want0) {
    Yv *want = unfold(want0);
    Yv *nk = yr_get(node, "k");
    Yv *wk = yr_get(want, "k");
    if (yv_l(nk) == K_rec &&
        (yv_l(wk) == K_trec || yv_l(wk) == K_tunion)) {
        /* want0 as declared: a recursive alias names the descriptor */
        st = gen_reclit(st, node, want0);
    } else if (yv_l(wk) == K_topt && some_of_lit(node)) {
        /* some({...}) where T? is declared: the literal made as T (types.c
         * typeof_want), then boxed */
        st = gen_as(st, ya_get(yr_get(node, "args"), 0), yr_get(want, "of"));
        st = gen_box_rax(st);
    } else {
        st = gen(st, node);
    }
    if (yv_l(wk) == K_tfloat || yv_l(wk) == K_tbyte) {
        return gen_conv(st, infer(st, node), want);
    } else if ((yv_l(wk) == K_trec || yv_l(wk) == K_tunion) &&
               yv_l(nk) != K_rec) {
        /* a record literal is made in the declared layout (gen_reclit) */
        return gen_convert(st, infer(st, node), want0, 1);
    } else {
        return st;
    }
}

/* node is `some({...})`: a record literal boxed (an optional argument
 * passed is one, rename.c). */
int some_of_lit(Yv *node) {
    if (yv_l(yr_get(node, "k")) != K_call) {
        return 0;
    }
    Yv *callee = yr_get(node, "callee");
    Yv *args = yr_get(node, "args");
    if (yv_l(yr_get(callee, "k")) != K_id || yv_len(args) != 1) {
        return 0;
    }
    return ys_eq_lit(yr_get(callee, "v"), "some") &&
           yv_l(yr_get(ya_get(args, 0), "k")) == K_rec;
}

/* Every member of union s is one of t's (t a union): s goes into t as it
 * is, with no check. */
int union_within(Yv *s, Yv *t) {
    Yv *u = unfold(t);
    if (yv_l(yr_get(u, "k")) != K_tunion) {
        return 0;
    }
    if (teq(unfold(s), u)) {
        return 1;
    }
    Yv *ss = union_parts(unfold(s));
    long i = 0;
    while (i < yv_len(ss)) {
        if (yv_l(yr_get(union_member(u, ya_get(ss, i)), "k")) == K_tnone) {
            return 0;
        }
        i = i + 1;
    }
    return 1;
}

/* The members of union s a cast to t keeps: t itself, a record (types.c
 * tcompat lets a union value go where one of its members is declared), or
 * each member of the union t. */
Yv *cast_members(Yv *s, Yv *t) {
    Yv *out = yav(0);
    Yv *ts = yav(0);
    Yv *su = unfold(s);
    if (yv_l(yr_get(unfold(t), "k")) == K_tunion) {
        ts = union_parts(unfold(t));
    } else {
        ts = ya_push(ts, t);
    }
    long i = 0;
    while (i < yv_len(ts)) {
        Yv *m = union_member(su, ya_get(ts, i));
        if (yv_l(yr_get(m, "k")) != K_tnone) {
            out = ya_push(out, m);
        }
        i = i + 1;
    }
    return out;
}

/* gen_convert's check of a cast from union u: the record in %rax (kept)
 * is one of its members ts, or the program stops (y_cast_trap). */
Yv *gen_cast_check(Yv *st, Yv *ts, Yv *u) {
    Yv *ok = next_loc(st);
    st = yr_get(ok, "st");
    st = emit_insn(st, F_MOV_D_R, R_RAX, -1, 1, -8, -1, R_RCX, 64);
    long i = 0;
    while (i < yv_len(ts)) {
        Yv *dr = ty_desc_in(st, ya_get(ts, i), u);
        st = yr_get(dr, "st");
        st = emit_insn(st, F_LEA_P_R, -1, -1, 1, 0, yv_l(yr_get(dr, "label")), R_RDX, 64);
        st = emit_insn(st, F_CMP_R_R, R_RDX, 64, R_RCX, 64, 0, 0, 0);
        st = emit_insn(st, F_JE_L, yv_l(yr_get(ok, "label")), 0, 0, 0, 0, 0, 0);
        i = i + 1;
    }
    st = emit_insn(st, F_JMP_L, yv_l(lbl_new(ys("y_cast_trap"))), 0, 0, 0, 0, 0, 0);
    return emit_label(st, yv_l(yr_get(ok, "label")));
}

/* The type of the function being emitted: emit_one_fn records it as a
 * nameless "fnty" entry (declared parameter types; the return type as
 * declared or as the checker inferred it, tnone when it could not --
 * see types.y set_inferred_ret). infer_fn_ret's scope has none. */
Yv *cur_fn_type(Yv *st) {
    Yv *env = yr_get(st, "env");
    long i = yv_len(env) - 1;
    Yv *ft = yr(3, "k", yv_long(K_tfunc), "args", yav(0),
                "ret", yr(1, "k", yv_long(K_tunk)));
    int looking = 1;
    while (looking && i >= 0) {
        Yv *e = ya_get(env, i);
        if (ys_eq_lit(yr_get(e, "kind"), "fnty")) {
            ft = yr_get(e, "typ");
            looking = 0;
            ;
        }
        i = i - 1;
    }
    return ft;
}

Yv *cur_fn_ret(Yv *st) {
    return yr_get(cur_fn_type(st), "ret");
}

/* Parameter types of a function type (none for anything else). */
Yv *fn_args_of(Yv *t) {
    Yv *none = yav(0);
    if (yv_l(yr_get(t, "k")) == K_tfunc) {
        return yr_get(t, "args");
    } else {
        return none;
    }
}

/* Element type of an array type (tnone for anything else). */
Yv *arr_elem_type(Yv *t) {
    Yv *k = yr_get(t, "k");
    if (yv_l(k) == K_tarr) {
        return yr_get(t, "of");
    } else if (yv_l(k) == K_tarrfix) {
        return yr_get(t, "of");
    } else {
        return yr(1, "k", yv_long(K_tnone));
    }
}

/* The element type a store converts to: none for a packed [byte] (esz 1),
 * whose movb store truncates by itself. */
Yv *store_elem_type(Yv *t, long esz) {
    if (esz == 1) {
        return yr(1, "k", yv_long(K_tnone));
    } else {
        return arr_elem_type(t);
    }
}

/* Call a one-argument runtime helper. The argument is in %rax and goes on
 * the stack — the Y convention every helper written in Y (std/rt.y) and
 * every asm helper shares; the caller cleans up. (Runtime helpers used to
 * take it in %rdi, which only hand-written asm could honour.) */
/* `name` is a runtime helper's fixed name (y_wait_pid): the reserved y_
 * prefix means it is the same name every time, so it is interned rather than
 * minted (there is nothing to identify). */
Yv *gen_helper1(Yv *st, Yv *name) {
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(name)), 0, 0, 0, 0, 0, 0);
    return emit_insn(st, F_ADD_I_R, 8, R_RSP, 64, 0, 0, 0, 0);
}

Yv *gen_call(Yv *st, Yv *node) {
    Yv *callee = yr_get(node, "callee");
    if (yv_l(yr_get(callee, "k")) != K_id) {
        if (yv_l(yr_get(callee, "k")) == K_dot &&
            yv_l(yr_get(infer(st, yr_get(callee, "obj")), "k")) == K_tstr) {
            return gen_method(st, node);
        } else {
            /* Calling the result of an expression (e.g. `fs[0](x)`): it is
             * a closure value, so go through its code pointer. */
            return gen_indirect(st, node, callee);
        }
    } else {
        Yv *name = yr_get(callee, "v");
        if (ys_eq_lit(name, "print")) {
            return gen_print(st, node);
        } else if (ys_eq_lit(name, "syscall")) {
            return gen_syscall(st, node);
        } else if (ys_eq_lit(name, "len")) {
            return gen_len(st, node);
        } else if (ys_eq_lit(name, "range")) {
            return gen_range(st, node);
        } else if (ys_eq_lit(name, "push")) {
            return gen_push(st, node);
        } else if (ys_eq_lit(name, "push$all")) {
            return gen_push_all(st, node);
        } else if (ys_eq_lit(name, "some")) {
            return gen_some(st, node);
        } else if (ys_eq_lit(name, "is_some")) {
            return gen_is_some(st, node);
        } else if (ys_eq_lit(name, "opt$test")) {
            /* `x is there` -- the test of a `?.` chain (parser.y) */
            return gen_is_some(st, node);
        } else if (ys_eq_lit(name, "opt$val")) {
            return gen_opt_val(st, node);
        } else if (ys_eq_lit(name, "unwrap")) {
            return gen_unwrap(st, node);
        } else if (ys_eq_lit(name, "trim")) {
            return gen_trim(st, node);
        } else if (ys_eq_lit(name, "prepend")) {
            return gen_prepend(st, node);
        } else if (ys_eq_lit(name, "byte_at")) {
            return gen_byte_at(st, node);
        } else if (ys_eq_lit(name, "ord")) {
            return gen_ord(st, node);
        } else if (ys_eq_lit(name, "chr")) {
            return gen_chr(st, node);
        } else if (ys_eq_lit(name, "tonum")) {
            return gen_tonum(st, node);
        } else if (ys_eq_lit(name, "tostring")) {
            return gen_tostring(st, node);
        } else if (ys_eq_lit(name, "#fmt")) {
            return gen_fmt(st, node);
        } else if (ys_eq_lit(name, "typeof")) {
            return gen_typeof(st, node);
        } else if (ys_eq_lit(name, "index_of")) {
            return gen_index_of(st, node, 0);
        } else if (ys_eq_lit(name, "last_index_of")) {
            return gen_index_of(st, node, 1);
        } else if (ys_eq_lit(name, "join") && yv_len(yr_get(node, "args")) == 1) {
            /* join t: t is a thread's function; calling it waits */
            Yv *ja = yr_get(node, "args");
            Yv *jc = yr(5, "k", yv_long(K_call), "callee", ya_get(ja, 0), "args", yav(0),
                        "line", yr_get(node, "line"), "col", yr_get(node, "col"));
            return gen_indirect(st, jc, ya_get(ja, 0));
        } else if (ys_eq_lit(name, "spawn") || ys_eq_lit(name, "fork")) {
            st = gen(st, ya_get(yr_get(node, "args"), 0));
            return emit_insn(st, F_CALL_L,
                              yv_l(lbl_new(ys_cat(ys("y_"), name))), 0, 0, 0, 0,
                              0, 0);
        } else if (ys_eq_lit(name, "wait_pid")) {
            st = gen(st, ya_get(yr_get(node, "args"), 0));
            return gen_helper1(st, ys("y_wait_pid"));
        } else if (ys_eq_lit(name, "post") || ys_eq_lit(name, "wait")) {
            st = gen(st, ya_get(yr_get(node, "args"), 0));
            return emit_insn(st, F_CALL_L,
                              yv_l(lbl_new(ys_cat(ys("y_sem_"), name))), 0, 0, 0,
                              0, 0, 0);
        } else if (ys_eq_lit(name, "mutex") || ys_eq_lit(name, "sem")) {
            return gen_sync_new(st, node);
        } else if (ys_eq_lit(name, "lock") || ys_eq_lit(name, "try_lock")) {
            return gen_lock(st, node, ys_eq_lit(name, "try_lock"));
        } else if (ys_eq_lit(name, "join")) {
            return gen_join(st, node);
        } else if (ys_eq_lit(name, "split")) {
            return gen_split(st, node);
        } else if (ys_eq_lit(name, "puts")) {
            return gen_puts(st, node);
        } else if (ys_eq_lit(name, "eputs")) {
            return gen_eputs(st, node);
        } else if (ys_eq_lit(name, "clock_us")) {
            return gen_clock_us(st, node);
        } else if (ys_eq_lit(name, "time_us")) {
            return emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_time_us"))), 0, 0, 0, 0, 0, 0);
        } else if (ys_eq_lit(name, "keys")) {
            /* a copy of the map's keys array (gen_maplit's {keys, vals, boxes}) */
            Yv *ln = yr_get(node, "line");
            Yv *cl = yr_get(node, "col");
            Yv *whole = yr(6, "k", yv_long(K_slice),
                           "arr", n_dot(ya_get(yr_get(node, "args"), 0), ys("keys"), yv_l(ln), yv_l(cl)),
                           "lo", yr(3, "k", yv_long(K_void), "line", ln, "col", cl),
                           "hi", yr(3, "k", yv_long(K_void), "line", ln, "col", cl),
                           "line", ln, "col", cl);
            return gen_slice(st, whole);
        } else if (ys_eq_lit(name, "sleep")) {
            return gen_sleep(st, node);
        } else if (ys_eq_lit(name, "heap_used")) {
            return gen_heap_used(st, node);
        } else if (ys_eq_lit(name, "exit")) {
            return gen_exit(st, node);
        } else if (ys_eq_lit(name, "argv")) {
            return gen_argv(st, node);
        } else if (ys_eq_lit(name, "bytes")) {
            st = gen_push_args(st, yr_get(node, "args"));
            st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_str_to_bytes"))), 0, 0, 0, 0, 0, 0);
            return emit_insn(st, F_ADD_I_R, 8, R_RSP, 64, 0, 0, 0, 0);
        } else if (ys_eq_lit(name, "from_bytes")) {
            st = gen_push_args(st, yr_get(node, "args"));
            st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_bytes_to_str"))), 0, 0, 0, 0, 0, 0);
            return emit_insn(st, F_ADD_I_R, 8, R_RSP, 64, 0, 0, 0, 0);
        } else if (ys_eq_lit(name, "ptr_addr")) {
            /* A pointer IS its numeric value at run time: nothing to emit
             * beyond evaluating the operand. This exists only so the type
             * system lets the value cross into long territory. */
            Yv *paargs = yr_get(node, "args");
            return gen(st, ya_get(paargs, 0));
        } else {
            return gen_direct(st, node, name);
        }
    }
}

/* `s.m(args)` with s a str (the checker validated it against
 * types.str_method): the receiver becomes the first argument (the last
 * for `sep.join(xs)`), a left-out optional argument its default, and
 * the call goes to the builtin's own lowering, or straight to the
 * std/str.y helper by label -- a Y function like any other, so the
 * arguments are pushed and the caller pops them. */
Yv *gen_method(Yv *st, Yv *node) {
    Yv *mcal = yr_get(node, "callee");
    Yv *mobj = yr_get(mcal, "obj");
    Yv *sm = str_method(yr_get(mcal, "key"));
    Yv *margs = yr_get(node, "args");
    Yv *args = yav(0);
    if (!yv_b(yr_get(sm, "last"))) {
        args = ya_push(args, mobj);
        ;
    }
    long i = 0;
    while (i < yv_len(margs)) {
        args = ya_push(args, ya_get(margs, i));
        i = i + 1;
    }
    if (yv_len(margs) < yv_len(yr_get(sm, "params"))) {
        args = ya_push(args,
                       n_str(yr_get(sm, "dflt"),
                             yv_l(yr_get(node, "line")),
                             yv_l(yr_get(node, "col"))));
        ;
    }
    if (yv_b(yr_get(sm, "last"))) {
        args = ya_push(args, mobj);
        ;
    }
    Yv *fname = yr_get(sm, "fn");
    if (yv_len(runtime_base(fname)) > 0) {
        st = gen_push_args(st, args);
        st = emit_insn(st, F_CALL_L, yv_l(lbl_new(fname)), 0, 0, 0, 0, 0, 0);
        return emit_insn(st, F_ADD_I_R, yv_len(args) * 8, R_RSP, 64, 0, 0, 0,
                         0);
    } else {
        return gen_call(
            st, yr(5, "k", yv_long(K_call), "callee",
                   yr(4, "k", yv_long(K_id), "v", fname,
                      "line", yr_get(node, "line"),
                      "col", yr_get(node, "col")),
                   "args", args, "line", yr_get(node, "line"),
                   "col", yr_get(node, "col")));
    }
}

Yv *gen_print(Yv *st, Yv *node) {
    Yv *args = yr_get(node, "args");
    Yv *pa0 = ya_get(args, 0);
    Yv *t = infer(st, pa0);
    if (yv_l(yr_get(t, "k")) == K_trec) {
        /* Records are formatted field by field from their static shape. */
        st = gen_rec_str(st, pa0, t);
        st = gen_helper1(st, ys("y_print_hstr"));
        return emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
    } else if (yv_l(yr_get(t, "k")) == K_tfunc) {
        /* A function value has no printable contents; show its signature
         * (`<function (params) -> ret>`, in the spelling types.y tstr gives,
         * the one every diagnostic uses). */
        st = gen(st, pa0);
        st = gen_str_const(
            st, ys_cat(ys_cat(ys("<function "), tstr(t)), ys(">")));
        st = gen_helper1(st, ys("y_print_hstr"));
        return emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
    } else if (yv_l(yr_get(t, "k")) == K_tarr ||
               yv_l(yr_get(t, "k")) == K_tarrfix) {
        /* Arrays print like tostring: "[e0, e1, ...]". */
        st = gen(st, pa0);
        if (yv_l(yr_get(yr_get(t, "of"), "k")) == K_tbyte) {
            /* [byte] prints Python-style: b'...' with escapes */
            st = gen_helper1(st, ys("y_bytes_repr"));
            ;
        } else {
            st = gen_arr_tostr_rax(st, yr_get(t, "of"), yav(0));
            ;
        }
        st = gen_helper1(st, ys("y_print_hstr"));
        return emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
    } else if (yv_l(yr_get(t, "k")) == K_topt) {
        st = gen(st, pa0);
        st = gen_opt_str_rax(st, t, yav(0));
        st = gen_helper1(st, ys("y_print_hstr"));
        return emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
    } else if (yv_l(yr_get(t, "k")) == K_tmap) {
        /* Maps format entry by entry: {"k": v, ...} (quoted keys). */
        st = gen_map_repr(st, pa0, t);
        st = gen_helper1(st, ys("y_print_hstr"));
        return emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
    } else if (yv_l(yr_get(t, "k")) == K_tunion) {
        st = gen(st, pa0);
        st = gen_union_str_rax(st, t, yav(0));
        st = gen_helper1(st, ys("y_print_hstr"));
        return emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
    } else {
        return gen_print_scalar(st, pa0, t);
    }
}

Yv *gen_print_scalar(Yv *st, Yv *arg, Yv *t) {
    st = gen(st, arg);
    if (yv_l(yr_get(t, "k")) == K_tbool) {
        st = gen_helper1(st, ys("y_print_bool"));
        return emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
    } else if (yv_l(yr_get(t, "k")) == K_tstr) {
        st = gen_helper1(st, ys("y_print_hstr"));
        return emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
    } else if (yv_l(yr_get(t, "k")) == K_tfloat) {
        st = gen_helper1(st, ys("y_print_float"));
        return emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
    } else {
        st = gen_helper1(st, ys("y_print_long"));
        return emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
    }
}

/* `typeof(e)` is resolved statically: the checker has already pinned e's
 * type, so this is a plain string constant. */
Yv *gen_typeof(Yv *st, Yv *node) {
    Yv *targs = yr_get(node, "args");
    return gen_str_const(st, tstr(infer(st, ya_get(targs, 0))));
}

/* ── record formatting ──────────────────────────────────────────────────
 * `{a: 1, b: "x"}` — the shape is static, so the walk is unrolled at
 * compile time. Stack layout while building: [record][accumulator], the
 * record pushed first (8(%rsp)), the accumulator on top (0(%rsp)). */

/* Option value in %rax (0 = none, else the box address): leave "none" or
 * the payload's string form in %rax. Options are 0-or-box (NATIVE.md). */
Yv *gen_opt_str_rax(Yv *st, Yv *t, Yv *path) {
    Yv *rdone = next_loc(st);
    st = yr_get(rdone, "st");
    Yv *rnul = next_loc(st);
    st = yr_get(rnul, "st");
    st = emit_insn(st, F_TEST_R_R, R_RAX, 64, R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, F_JZ_L, yv_l(yr_get(rnul, "label")), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_MOV_0_R, R_RAX, -1, 1, -1, -1, R_RAX, 64);
    st = gen_val_tostr_rax(st, yr_get(t, "of"), path_push(path, t));
    st = emit_insn(st, F_JMP_L, yv_l(yr_get(rdone, "label")), 0, 0, 0, 0, 0, 0);
    st = emit_label(st, yv_l(yr_get(rnul, "label")));
    st = gen_str_const(st, ys("none"));
    return emit_label(st, yv_l(yr_get(rdone, "label")));
}

Yv *gen_rec_str(Yv *st, Yv *arg, Yv *t) {
    st = gen(st, arg);
    return gen_rec_str_rax(st, t, lay_of(t, t), yav(0));
}

/* The record's address sits in %rax; leave "{a: 1, b: ...}" in %rax.
 * Values are formatted from the static shape (the walk is unrolled at
 * compile time). Stack layout while building: [record][accumulator], the
 * record pushed first (8(%rsp)), the accumulator on top (0(%rsp)). */
Yv *gen_rec_str_rax(Yv *st, Yv *t, Yv *lay, Yv *path) {
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen_str_const(st, ys("{"));
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    Yv *fs = yr_get(t, "fields");
    long i = 0;
    while (i < yv_len(fs)) {
        Yv *f = ya_get(fs, i);
        Yv *sep = ys("");
        if (i > 0) {
            sep = ys(", ");
            ;
        }
        Yv *fname = yr_get(f, "name");
        st = gen_acc_cat_const(st, ys_cat(ys_cat(sep, fname), ys(": ")));
        st = gen_rec_field_str(st, mfield_idx(lay, fname), yr_get(f, "typ"), path);
        i = i + 1;
    }
    st = gen_acc_cat_const(st, ys("}"));
    st = emit_insn(st, F_MOV_0_R, R_RSP, -1, 1, -1, -1, R_RAX, 64);
    return emit_insn(st, F_ADD_I_R, 16, R_RSP, 64, 0, 0, 0, 0);
}

/* `x :: a` -- cons: a NEW array with x prepended as exactly ONE element
 * (types.y typeof_cons keeps even array-typed elements whole). */
Yv *gen_cons(Yv *st, Yv *node) {
    Yv *ln = yr_get(node, "line");
    Yv *cl = yr_get(node, "col");
    Yv *crt = infer(st, yr_get(node, "r"));
    long cesz = arr_elem_bytes(crt);
    Yv *one = yr(4, "k", yv_long(K_array), "elems", args1(yr_get(node, "l")), "line",
                 ln, "col", cl);
    st = gen_array_esz(st, one, cesz, store_elem_type(crt, cesz));
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen(st, yr_get(node, "r"));
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_MOV_I_R, cesz, R_RAX, 64, 0, 0, 0, 0);
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_arr_cat"))), 0, 0, 0, 0, 0, 0);
    return emit_insn(st, F_ADD_I_R, 24, R_RSP, 64, 0, 0, 0, 0);
}

/* `l + r` on two arrays whose element types differ by an implicit numeric
 * conversion ([float] + [long], [long] + [byte], ...): y_arr_cat copies raw
 * elements, so build the result element by element instead --
 * { let a = l; let b = r; let c: [L] = []; c += a; c += b; c } -- where
 * each `+=` pushes through the element conversion (gen_push). */
Yv *gen_cat_conv(Yv *st, Yv *node, Yv *lt) {
    Yv *ln = yr_get(node, "line");
    Yv *cl = yr_get(node, "col");
    Yv *r = next_uid(st);
    st = yr_get(r, "st");
    Yv *t1 = ys_cat(ys("y_t"), ys_long(yv_l(yr_get(r, "uid"))));
    Yv *noelems = yav(0);
    Yv *da = yr(7, "k", yv_long(K_decl), "kind", ys("let"), "typ",
                yr(1, "k", yv_long(K_tnone)), "name", ys_cat(t1, ys("l")),
                "v", yr_get(node, "l"), "line", ln, "col", cl);
    Yv *db = yr(7, "k", yv_long(K_decl), "kind", ys("let"), "typ",
                yr(1, "k", yv_long(K_tnone)), "name", ys_cat(t1, ys("r")),
                "v", yr_get(node, "r"), "line", ln, "col", cl);
    Yv *dc = yr(7, "k", yv_long(K_decl), "kind", ys("let"), "typ",
                yr(2, "k", yv_long(K_tarr), "of", yr_get(lt, "of")),
                "name", ys_cat(t1, ys("c")),
                "v", yr(4, "k", yv_long(K_array), "elems", noelems,
                        "line", ln, "col", cl),
                "line", ln, "col", cl);
    Yv *pa = yr(6, "k", yv_long(K_opassign), "tgt", n_id(ys_cat(t1, ys("c")),
                                                       yv_l(ln), yv_l(cl)),
                "op", ys("+"), "v", n_id(ys_cat(t1, ys("l")),
                                         yv_l(ln), yv_l(cl)),
                "line", ln, "col", cl);
    Yv *pb = yr(6, "k", yv_long(K_opassign), "tgt", n_id(ys_cat(t1, ys("c")),
                                                       yv_l(ln), yv_l(cl)),
                "op", ys("+"), "v", n_id(ys_cat(t1, ys("r")),
                                         yv_l(ln), yv_l(cl)),
                "line", ln, "col", cl);
    return gen(st, block6(da, db, dc, pa, pb,
                          n_id(ys_cat(t1, ys("c")), yv_l(ln), yv_l(cl)),
                          yv_l(ln), yv_l(cl)));
}

/* Array `+`: always a NEW array (arr + arr, arr + elem, elem + arr).
 * y_arr_cat copies both sides; the one-element side is built with the
 * ordinary array literal emitter, so `arr + v` evaluates v exactly once.
 * Two array operands concatenate unless types.arr_plus_kind says one of
 * them is an element of the other ([[T]] + [T], [T] + [[T]]). */
Yv *gen_cat_arr(Yv *st, Yv *node, Yv *lt, Yv *rt) {
    Yv *ln = yr_get(node, "line");
    Yv *cl = yr_get(node, "col");
    Yv *lk = yr_get(lt, "k");
    Yv *rk = yr_get(rt, "k");
    int lisarr = yv_l(lk) == K_tarr || yv_l(lk) == K_tarrfix;
    int risarr = yv_l(rk) == K_tarr || yv_l(rk) == K_tarrfix;
    Yv *how = ys("elem");
    if (lisarr && risarr) {
        how = arr_plus_kind(lt, rt);
    }
    if (ys_eq_lit(how, "cat") &&
        !teq(yr_get(lt, "of"), yr_get(rt, "of"))) {
        return gen_cat_conv(st, node, lt);
    }
    int larr = lisarr && !ys_eq_lit(how, "prepend");
    long esz = 8;
    Yv *ety = yr(1, "k", yv_long(K_tnone));
    if (larr) {
        esz = arr_elem_bytes(lt);
        ety = store_elem_type(lt, esz);
    } else {
        esz = arr_elem_bytes(rt);
        ety = store_elem_type(rt, esz);
    }
    Yv *one = yr(4, "k", yv_long(K_array), "elems", args1(yr_get(node, "r")), "line",
                 ln, "col", cl);
    if (larr) {
        ;
    } else {
        one = yr(4, "k", yv_long(K_array), "elems", args1(yr_get(node, "l")), "line",
                 ln, "col", cl);
        ;
    }
    if (larr) {
        st = gen(st, yr_get(node, "l"));
        st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
        if (ys_eq_lit(how, "cat")) {
            st = gen(st, yr_get(node, "r"));
        } else {
            st = gen_array_esz(st, one, esz, ety);
        }
    } else {
        st = gen_array_esz(st, one, esz, ety);
        st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
        st = gen(st, yr_get(node, "r"));
    }
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_MOV_I_R, esz, R_RAX, 64, 0, 0, 0, 0);
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_arr_cat"))), 0, 0, 0, 0, 0, 0);
    return emit_insn(st, F_ADD_I_R, 24, R_RSP, 64, 0, 0, 0, 0);
}

/* acc = acc + <constant>, with the layout above still in place. */
Yv *gen_acc_cat_const(Yv *st, Yv *s) {
    st = emit_insn(st, F_MOV_0_R, R_RSP, -1, 1, -1, -1, R_RAX, 64);
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen_str_const(st, s);
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_str_cat"))), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_ADD_I_R, 16, R_RSP, 64, 0, 0, 0, 0);
    return emit_insn(st, F_MOV_R_0, R_RAX, 64, R_RSP, -1, 1, -1, -1);
}

/* Slot idx of the record in %rcx into register dst. */
Yv *gen_slot_load(Yv *st, long idx) {
    return emit_insn(st, F_MOV_D_R, R_RCX, -1, 1, 8 * idx, -1, R_RAX, 64);
}

/* acc = acc + <field in slot idx, rendered by its static type>. */
/* acc = acc + <field in slot idx, rendered by its static type>. Each arm ends
 * in the walk it ran, and every one of them must leave its EmitSt in `st`:
 * dropping it drops the uid counter with it, and the next string constant would
 * take a label already emitted (native.y gen_rec_field_str). */
Yv *gen_rec_field_str(Yv *st, long idx, Yv *ft, Yv *path) {
    Yv *fk = yr_get(ft, "k");
    if (yv_l(fk) == K_tstr) {
        /* a str is already its own form */
        st = emit_insn(st, F_MOV_D_R, R_RSP, -1, 1, 8, -1, R_RCX, 64);
        st = gen_slot_load(st, idx);
    } else if (yv_l(fk) == K_tlong) {
        st = emit_insn(st, F_MOV_D_R, R_RSP, -1, 1, 8, -1, R_RCX, 64);
        st = gen_slot_load(st, idx);
        st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_long_tostr"))), 0, 0, 0, 0, 0, 0);
        st = emit_insn(st, F_ADD_I_R, 8, R_RSP, 64, 0, 0, 0, 0);
    } else if (yv_l(fk) == K_tbool) {
        st = emit_insn(st, F_MOV_D_R, R_RSP, -1, 1, 8, -1, R_RCX, 64);
        st = gen_slot_load(st, idx);
        st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_bool_tostr"))), 0, 0, 0, 0, 0, 0);
        st = emit_insn(st, F_ADD_I_R, 8, R_RSP, 64, 0, 0, 0, 0);
    } else if (yv_l(fk) == K_tfloat) {
        st = emit_insn(st, F_MOV_D_R, R_RSP, -1, 1, 8, -1, R_RCX, 64);
        st = gen_slot_load(st, idx);
        st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_float_tostr"))), 0, 0, 0, 0, 0, 0);
        st = emit_insn(st, F_ADD_I_R, 8, R_RSP, 64, 0, 0, 0, 0);
    } else if (yv_l(fk) == K_tfunc) {
        st = gen_str_const(
            st, ys_cat(ys_cat(ys("<function "), tstr(ft)), ys(">")));
    } else {
        /* Arrays, options, maps, records and unions nested in a RECORD: the
         * value walk formats them, the same text tostring() gives. This used to
         * print the field's TYPE instead ("<{str => long}>") on the mistaken
         * belief that only gen_val_tostr_rax walked them -- it does, and it is
         * exactly what a field needs. */
        st = emit_insn(st, F_MOV_D_R, R_RSP, -1, 1, 8, -1, R_RCX, 64);
        st = gen_slot_load(st, idx);
        st = gen_val_tostr_rax(st, ft, path);
    }
    st = emit_insn(st, F_MOV_R_R, R_RAX, 64, R_RDX, 64, 0, 0, 0);
    st = emit_insn(st, F_MOV_0_R, R_RSP, -1, 1, -1, -1, R_RAX, 64);
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_PUSH_R, R_RDX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_str_cat"))), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_ADD_I_R, 16, R_RSP, 64, 0, 0, 0, 0);
    return emit_insn(st, F_MOV_R_0, R_RAX, 64, R_RSP, -1, 1, -1, -1);
}

Yv *gen_syscall(Yv *st, Yv *node) {
    Yv *args = yr_get(node, "args");
    /* args[0] is the number; rest are a1..a6. Push all, pop into regs. */
    st = gen_push_args(st, args);
    long n = yv_len(args) - 1;
    long i = n;
    while (i >= 1) {
        st = emit_insn(st, F_POP_R, syscall_reg(i - 1), 64, 0, 0, 0, 0, 0);
        /* a str flows in as its header; the kernel wants the data bytes. */
        Yv *at = infer(st, ya_get(args, i));
        if (yv_l(yr_get(at, "k")) == K_tstr) {
            st = emit_insn(st, F_ADD_I_R, 8, syscall_reg(i - 1), 64, 0, 0, 0,
                           0);
            ;
        }
        i = i - 1;
    }
    st = emit_insn(st, F_POP_R, R_RAX, 64, 0, 0, 0, 0, 0);
    return emit_insn(st, F_SYSCALL, 0, 0, 0, 0, 0, 0, 0);
}

/* The frame offset of the closure record of the body being emitted, or -1
 * when it captures nothing. Every "capture" env entry carries it (their
 * `off` is the record's slot offset) — used to pass the record along on
 * recursive `self` calls, which would otherwise reach the body without
 * one. */
long capture_off(Yv *st) {
    Yv *env = yr_get(st, "env");
    long i = 0;
    long res = -1;
    while (i < yv_len(env)) {
        Yv *e = ya_get(env, i);
        if (ys_eq_lit(yr_get(e, "kind"), "capture")) {
            res = yv_l(yr_get(e, "off"));
            ;
        }
        i = i + 1;
    }
    return res;
}

Yv *gen_direct(Yv *st, Yv *node, Yv *name) {
    Yv *label = yv_long(-1);
    int indirect = 0;
    Yv *dptypes = yav(0);
    if (ys_eq_lit(name, "self")) {
        label = yr_get(st, "self_label");
        dptypes = fn_args_of(cur_fn_type(st));
    } else {
        Yv *e = env_find(st, name);
        if (ys_eq_lit(yr_get(e, "kind"), "none")) {
            label = lbl_new(ys_cat(ys("y_missing_"), name));
        } else if (ys_eq_lit(yr_get(e, "kind"), "func")) {
            label = yr_get(e, "label");
            dptypes = fn_args_of(yr_get(e, "typ"));
        } else {
            /* A local/param/capture/global holding a closure value: call
             * through it. */
            indirect = 1;
        }
    }
    if (indirect) {
        return gen_indirect(st, node, yr_get(node, "callee"));
    } else {
        /* A recursive call (`self`, or a capturing function's own name)
         * reaches the same body, which reads its captures through the
         * closure record — pass this frame's record along, exactly as an
         * indirect call would. */
        long soff = -1;
        if (yv_eq(label, yr_get(st, "self_label"))) {
            soff = capture_off(st);
            ;
        }
        if (soff >= 0) {
            st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, soff, -1, R_RAX, 64);
            st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
            ;
        }
        st = gen_push_args_as(st, yr_get(node, "args"), dptypes);
        st = emit_insn(st, F_CALL_L, yv_l(label), 0, 0, 0, 0, 0, 0);
        long nbytes = yv_len(yr_get(node, "args")) * 8;
        if (soff >= 0) {
            nbytes = nbytes + 8;
            ;
        }
        if (nbytes == 0) {
            return st;
        } else {
            return emit_insn(st, F_ADD_I_R, nbytes, R_RSP, 64, 0, 0, 0, 0);
        }
    }
}

/* ── control flow ─────────────────────────────────────────────────────── */

/* Is `t` a type whose == / < / <= ... is one `cmp` of two machine words?
   The numeric fall-through in gen_bin_rest is what answers those, so this is
   the complement of the shapes it sends elsewhere: a float (ucomisd, where
   unordered decides the flags and a NaN must stay a NaN), a string
   (y_str_eq / y_str_cmp), an array or record (structural), a map, and an
   option whose payload is compared (gen_eq_opt -- `x == none` is a plain test
   and is left to the slow path rather than special-cased here). */
int cmp_word(Yv *t) {
    long k = yv_l(yr_get(t, "k"));
    return k == K_tlong || k == K_tbyte || k == K_tbool || k == K_tptr;
}

/* The jcc that takes the FALSE edge of `node` when it is a plain integer
   comparison -- the instruction a branch needs anyway -- or "" when the
   condition is anything else.

   Driven by the operator, never by matching the text of an emitted setcc: the
   materialisation and the branch can disagree (ucomisd sets ZF/PF/CF for an
   unordered compare, a structural == is a call), and the emitter may change how
   a bool is built without this going stale. Each jcc is the negation of its
   setcc form: `<` is setl, so its false edge is jge. */
long int_cmp_jcc(Yv *st, Yv *node) {
    long jcc = 0;
    if (yv_l(yr_get(node, "k")) == K_bin) {
        Yv *bin = node;
        Yv *op = yr_get(bin, "op");
        if (cmp_word(infer(st, yr_get(bin, "l")))
            && cmp_word(infer(st, yr_get(bin, "r")))) {
            if (ys_eq_lit(op, "<")) { jcc = F_JGE_L; }
            else if (ys_eq_lit(op, ">")) { jcc = F_JLE_L; }
            else if (ys_eq_lit(op, "<=")) { jcc = F_JG_L; }
            else if (ys_eq_lit(op, ">=")) { jcc = F_JL_L; }
            else if (ys_eq_lit(op, "==")) { jcc = F_JNE_L; }
            else if (ys_eq_lit(op, "!=")) { jcc = F_JE_L; }
            ;
        }
        ;
    }
    return jcc;
}

/* The operands the way the numeric path emits them -- left into %rax, right
   into %rcx -- so the `cmp %rcx, %rax` that follows reads left - right and the
   same setcc/jcc forms apply. */
Yv *gen_cmp_flags(Yv *st, Yv *node) {
    st = gen(st, yr_get(node, "l"));
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen(st, yr_get(node, "r"));
    st = emit_insn(st, F_MOV_R_R, R_RAX, 64, R_RCX, 64, 0, 0, 0);
    st = emit_insn(st, F_POP_R, R_RAX, 64, 0, 0, 0, 0, 0);
    return emit_insn(st, F_CMP_R_R, R_RCX, 64, R_RAX, 64, 0, 0, 0);
}

Yv *gen_if(Yv *st, Yv *node) {
    Yv *r1 = next_loc(st);
    st = yr_get(r1, "st");
    Yv *r2 = next_loc(st);
    st = yr_get(r2, "st");
    long jcc = int_cmp_jcc(st, yr_get(node, "cond"));
    if (jcc != 0) {
        /* A comparison branches on the flags it has just set: the bool is
           never built. `setcc; movzbq; test; jcc` (four instructions) becomes
           `cmp; jcc` (two) -- 3,049 such sites in ycc's own output. */
        st = gen_cmp_flags(st, yr_get(node, "cond"));
        st = emit_insn(st, jcc, yv_l(yr_get(r1, "label")), 0, 0, 0, 0, 0, 0);
    } else {
        st = gen(st, yr_get(node, "cond"));
        st = emit_insn(st, F_TEST_R_R, R_RAX, 64, R_RAX, 64, 0, 0, 0);
        st = emit_insn(st, F_JZ_L, yv_l(yr_get(r1, "label")), 0, 0, 0, 0, 0, 0);
    }
    st = gen(st, yr_get(node, "then"));
    if (yv_b(yr_get(node, "has_else"))) {
        st = emit_insn(st, F_JMP_L, yv_l(yr_get(r2, "label")), 0, 0, 0, 0, 0, 0);
        st = emit_label(st, yv_l(yr_get(r1, "label")));
        st = gen_loc_elif(st, yr_get(node, "els"));
        st = gen(st, yr_get(node, "els"));
        return emit_label(st, yv_l(yr_get(r2, "label")));
    } else {
        return emit_label(st, yv_l(yr_get(r1, "label")));
    }
}

/* A loop's value is void (types.y: every loop kind's typeof is
 * tvoid), so nothing can read what the merge label leaves in %rax:
 * `let x = while (...) {...}`, `print(while ...)`,
 * `let z: long = if (c) { while ... } else {2}` and a function
 * whose body's last statement is a loop are all checker errors
 * ("cannot bind a void value", "got void"). So the merge label
 * needs no `xor %eax, %eax` at all -- 1,235 of them in ycc's own
 * output, 586 of them in statement position. */
Yv *gen_while(Yv *st, Yv *node) {
    Yv *r1 = next_loc(st);
    st = yr_get(r1, "st");
    Yv *r2 = next_loc(st);
    st = yr_get(r2, "st");
    st = emit_label(st, yv_l(yr_get(r1, "label")));
    long jcc = int_cmp_jcc(st, yr_get(node, "cond"));
    if (jcc != 0) {
        st = gen_cmp_flags(st, yr_get(node, "cond"));
        st = emit_insn(st, jcc, yv_l(yr_get(r2, "label")), 0, 0, 0, 0, 0, 0);
    } else {
        st = gen(st, yr_get(node, "cond"));
        st = emit_insn(st, F_TEST_R_R, R_RAX, 64, R_RAX, 64, 0, 0, 0);
        st = emit_insn(st, F_JZ_L, yv_l(yr_get(r2, "label")), 0, 0, 0, 0, 0, 0);
    }
    st = gen_discard(st, yr_get(node, "body"));
    st = gen_loc_loop(st, node);
    st = emit_insn(st, F_JMP_L, yv_l(yr_get(r1, "label")), 0, 0, 0, 0, 0, 0);
    return emit_label(st, yv_l(yr_get(r2, "label")));
}

/* ── counted loops ──────────────────────────────────────────────────────
 * All three lower to the same shape as `while`: a head label, a test, the
 * body, a step, and a jump back. The loop variable is a normal local slot,
 * so nothing new is needed at runtime. */

/* A loop's value is void (types.y: every loop kind's typeof is
 * tvoid), so nothing can read what the merge label leaves in %rax:
 * `let x = while (...) {...}`, `print(while ...)`,
 * `let z: long = if (c) { while ... } else {2}` and a function
 * whose body's last statement is a loop are all checker errors
 * ("cannot bind a void value", "got void"). So the merge label
 * needs no `xor %eax, %eax` at all -- 1,235 of them in ycc's own
 * output, 586 of them in statement position. */
Yv *gen_for(Yv *st, Yv *node) {
    /* for (init; cond; step) body */
    st = gen(st, yr_get(node, "init"));
    Yv *r1 = next_loc(st);
    st = yr_get(r1, "st");
    Yv *r2 = next_loc(st);
    st = yr_get(r2, "st");
    st = emit_label(st, yv_l(yr_get(r1, "label")));
    long jcc = int_cmp_jcc(st, yr_get(node, "cond"));
    if (jcc != 0) {
        st = gen_cmp_flags(st, yr_get(node, "cond"));
        st = emit_insn(st, jcc, yv_l(yr_get(r2, "label")), 0, 0, 0, 0, 0, 0);
    } else {
        st = gen(st, yr_get(node, "cond"));
        st = emit_insn(st, F_TEST_R_R, R_RAX, 64, R_RAX, 64, 0, 0, 0);
        st = emit_insn(st, F_JZ_L, yv_l(yr_get(r2, "label")), 0, 0, 0, 0, 0, 0);
    }
    st = gen_discard(st, yr_get(node, "body"));
    st = gen_loc_loop(st, node);
    st = gen(st, yr_get(node, "step"));
    st = emit_insn(st, F_JMP_L, yv_l(yr_get(r1, "label")), 0, 0, 0, 0, 0, 0);
    return emit_label(st, yv_l(yr_get(r2, "label")));
}

/* A loop's value is void (types.y: every loop kind's typeof is
 * tvoid), so nothing can read what the merge label leaves in %rax:
 * `let x = while (...) {...}`, `print(while ...)`,
 * `let z: long = if (c) { while ... } else {2}` and a function
 * whose body's last statement is a loop are all checker errors
 * ("cannot bind a void value", "got void"). So the merge label
 * needs no `xor %eax, %eax` at all -- 1,235 of them in ycc's own
 * output, 586 of them in statement position. */
Yv *gen_forrange(Yv *st, Yv *node) {
    /* for (x in lo..hi) body — half-open: lo inclusive, hi exclusive.
     * Slot layout: [var][limit]; the limit is evaluated once. */
    long voff = (yv_l(yr_get(st, "slots")) + 1) * -8;
    long loff = (yv_l(yr_get(st, "slots")) + 2) * -8;
    st = yr(15, "ir", yr_get(st, "ir"), "txt", yr_get(st, "txt"), "rodata", yr_get(st, "rodata"), "uid",
            yr_get(st, "uid"), "fuid", yr_get(st, "fuid"), "loc",
            yr_get(st, "loc"), "env", yr_get(st, "env"), "slots",
            yv_long(yv_l(yr_get(st, "slots")) + 2), "temp", yr_get(st, "temp"), "self_label",
            yr_get(st, "self_label"), "end_label", yr_get(st, "end_label"),
            "fns", yr_get(st, "fns"), "bodies", yr_get(st, "bodies"), "btext", yr_get(st, "btext"), "blabels", yr_get(st, "blabels"));
    st = gen(st, yr_get(node, "hi"));
    st = emit_insn(st, F_MOV_R_D, R_RAX, 64, R_RBP, -1, 1, loff, -1);
    st = gen(st, yr_get(node, "lo"));
    st = emit_insn(st, F_MOV_R_D, R_RAX, 64, R_RBP, -1, 1, voff, -1);
    st = env_define(st, yr_get(node, "name"), ys("local"), voff, yv_long(-1),
                    ys(""), yr(1, "k", yv_long(K_tlong)));
    Yv *r1 = next_loc(st);
    st = yr_get(r1, "st");
    Yv *r2 = next_loc(st);
    st = yr_get(r2, "st");
    st = emit_label(st, yv_l(yr_get(r1, "label")));
    st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, voff, -1, R_RAX, 64);
    st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, loff, -1, R_RCX, 64);
    st = emit_insn(st, F_CMP_R_R, R_RCX, 64, R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, F_JGE_L, yv_l(yr_get(r2, "label")), 0, 0, 0, 0, 0, 0);
    /* a captured loop variable gets a fresh cell per iteration (the
     * counter itself stays in its raw slot) */
    st = box_bound(st, yr_get(node, "name"));
    st = gen_discard(st, yr_get(node, "body"));
    st = gen_loc_loop(st, node);
    /* the counter in place: one instruction, not a load, an inc and a store */
    st = emit_insn(st, F_INC_D, R_RBP, -1, 1, voff, -1, 0, 0);
    st = emit_insn(st, F_JMP_L, yv_l(yr_get(r1, "label")), 0, 0, 0, 0, 0, 0);
    return emit_label(st, yv_l(yr_get(r2, "label")));
}

/* A loop's value is void (types.y: every loop kind's typeof is
 * tvoid), so nothing can read what the merge label leaves in %rax:
 * `let x = while (...) {...}`, `print(while ...)`,
 * `let z: long = if (c) { while ... } else {2}` and a function
 * whose body's last statement is a loop are all checker errors
 * ("cannot bind a void value", "got void"). So the merge label
 * needs no `xor %eax, %eax` at all -- 1,235 of them in ycc's own
 * output, 586 of them in statement position. */
Yv *gen_foreach(Yv *st, Yv *node) {
    /* foreach (x in arr) body. Slots: [x][arr][i]. The array is evaluated
     * once; `x` is refreshed from arr[i] at the top of every iteration. */
    long voff = (yv_l(yr_get(st, "slots")) + 1) * -8;
    long aoff = (yv_l(yr_get(st, "slots")) + 2) * -8;
    long ioff = (yv_l(yr_get(st, "slots")) + 3) * -8;
    st = yr(15, "ir", yr_get(st, "ir"), "txt", yr_get(st, "txt"), "rodata", yr_get(st, "rodata"), "uid",
            yr_get(st, "uid"), "fuid", yr_get(st, "fuid"), "loc",
            yr_get(st, "loc"), "env", yr_get(st, "env"), "slots",
            yv_long(yv_l(yr_get(st, "slots")) + 3), "temp", yr_get(st, "temp"), "self_label",
            yr_get(st, "self_label"), "end_label", yr_get(st, "end_label"),
            "fns", yr_get(st, "fns"), "bodies", yr_get(st, "bodies"), "btext", yr_get(st, "btext"), "blabels", yr_get(st, "blabels"));
    Yv *elt = infer(st, yr_get(node, "iter"));
    Yv *eltyp = yr(1, "k", yv_long(K_tunk));
    if (yv_l(yr_get(elt, "k")) == K_tarr) {
        eltyp = yr_get(elt, "of");
        ;
    }
    if (yv_l(yr_get(elt, "k")) == K_tarrfix) {
        eltyp = yr_get(elt, "of");
        ;
    }
    st = gen(st, yr_get(node, "iter"));
    st = emit_insn(st, F_MOV_R_D, R_RAX, 64, R_RBP, -1, 1, aoff, -1);
    st = emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
    st = emit_insn(st, F_MOV_R_D, R_RAX, 64, R_RBP, -1, 1, ioff, -1);
    st = env_define(st, yr_get(node, "name"), ys("local"), voff, yv_long(-1),
                    ys(""), eltyp);
    Yv *r1 = next_loc(st);
    st = yr_get(r1, "st");
    Yv *r2 = next_loc(st);
    st = yr_get(r2, "st");
    st = emit_label(st, yv_l(yr_get(r1, "label")));
    /* i < len(arr) — the heap header keeps the length in slot 0. The length
     * is re-read on every iteration, not hoisted into a fourth slot: a body
     * that appends to the array it walks goes on seeing what it appended
     * (`foreach (x in a) { a += x }` never ends), which hoisting would
     * change. */
    st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, aoff, -1, R_RDX, 64);
    st = emit_insn(st, F_MOV_0_R, R_RDX, -1, 1, -1, -1, R_RCX, 64);
    st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, ioff, -1, R_RAX, 64);
    st = emit_insn(st, F_CMP_R_R, R_RCX, 64, R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, F_JGE_L, yv_l(yr_get(r2, "label")), 0, 0, 0, 0, 0, 0);
    /* x = arr[i] */
    st = elem_load(st, arr_elem_bytes(elt), R_RDX, R_RAX, R_RCX);
    st = emit_insn(st, F_MOV_R_D, R_RCX, 64, R_RBP, -1, 1, voff, -1);
    st = box_bound(st, yr_get(node, "name"));
    st = gen_discard(st, yr_get(node, "body"));
    st = gen_loc_loop(st, node);
    /* the counter in place: one instruction, not a load, an inc and a store */
    st = emit_insn(st, F_INC_D, R_RBP, -1, 1, ioff, -1, 0, 0);
    st = emit_insn(st, F_JMP_L, yv_l(yr_get(r1, "label")), 0, 0, 0, 0, 0, 0);
    return emit_label(st, yv_l(yr_get(r2, "label")));
}

/* ── tail calls ─────────────────────────────────────────────────────────
 * A self-call in tail position (the body's trailing value, a `return`'s
 * value, an if-arm's trailing value) recycles the frame instead of
 * growing the stack: every argument is evaluated into a fresh local
 * first (arguments may read parameters the copy below overwrites), the
 * locals are copied over the parameter slots, and the frame tears down
 * into a `jmp` back to the prologue. Tail recursion is then constant
 * space. */

int is_self_call(Yv *st, Yv *node) {
    /* `self(...)`, or a call naming the function being emitted (after
     * rename every def has a unique name, so the label decides). */
    if (yv_l(yr_get(node, "k")) != K_call) { return 0; }
    Yv *cal = yr_get(node, "callee");
    if (yv_l(yr_get(cal, "k")) != K_id) { return 0; }
    Yv *cv = yr_get(cal, "v");
    if (ys_eq_lit(cv, "self")) { return 1; }
    Yv *ee = env_find(st, cv);
    return ys_eq_lit(yr_get(ee, "kind"), "func") &&
           yv_eq(yr_get(ee, "label"), yr_get(st, "self_label"));
}

Yv *gen_tail_call(Yv *st, Yv *node) {
    Yv *targs = yr_get(node, "args");
    long n = yv_len(targs);
    Yv *tptypes = fn_args_of(cur_fn_type(st));
    /* evaluate each argument into a fresh local */
    Yv *offs = yav(0);
    long i = 0;
    while (i < n) {
        if (i < yv_len(tptypes)) {
            st = gen_as(st, ya_get(targs, i), ya_get(tptypes, i));
            ;
        } else {
            st = gen(st, ya_get(targs, i));
            ;
        }
        long off = (yv_l(yr_get(st, "slots")) + yv_l(yr_get(st, "temp")) + 1) * -8;
        st = st_temp(st, yv_l(yr_get(st, "temp")) + 1);
        st = emit_insn(st, F_MOV_R_D, R_RAX, 64, R_RBP, -1, 1, off, -1);
        offs = ya_push(offs, yv_long(off));
        i = i + 1;
    }
    /* copy the locals over the parameter slots (param k: 16 + 8*(n-1-k)) */
    long j = 0;
    while (j < n) {
        long po = 16 + 8 * (n - 1 - j);
        st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, yv_l(ya_get(offs, j)), -1, R_RAX, 64);
        st = emit_insn(st, F_MOV_R_D, R_RAX, 64, R_RBP, -1, 1, po, -1);
        j = j + 1;
    }
    /* tear down this frame and re-enter the prologue; the return address
     * of the original call stays where it is, so the caller sees a normal
     * return. */
    st = emit_insn(st, F_MOV_R_R, R_RBP, 64, R_RSP, 64, 0, 0, 0);
    st = emit_insn(st, F_POP_R, R_RBP, 64, 0, 0, 0, 0, 0);
    return emit_insn(st, F_JMP_L, yv_l(yr_get(st, "self_label")), 0, 0, 0, 0, 0,
                     0);
}

Yv *gen_tail(Yv *st, Yv *node) {
    Yv *k = yr_get(node, "k");
    if (yv_l(k) == K_ret) {
        Yv *e = yr_get(node, "e");
        if (is_self_call(st, e)) {
            return gen_tail_call(st, e);
        }
        st = gen_as(st, e, cur_fn_ret(st));
        return emit_insn(st, F_JMP_L, yv_l(yr_get(st, "end_label")), 0, 0, 0, 0, 0, 0);
    } else if (yv_l(k) == K_call) {
        if (is_self_call(st, node)) { return gen_tail_call(st, node); }
        return gen_as(st, node, cur_fn_ret(st));
    } else if (yv_l(k) == K_block) {
        Yv *tl = yr_get(node, "stmts");
        long m = yv_len(tl);
        /* a trailing `;` (void) leaves the statement before it in tail
         * position: the block's value is void either way */
        if (m > 1 && is_void_node(ya_get(tl, m - 1))) {
            m = m - 1;
        }
        long tdepth = yv_l(yr_get(st, "temp"));
        long ti = 0;
        while (ti < m - 1) {
            st = gen_loc_stmt(st, ya_get(tl, ti));
            st = gen_stmt(st, ya_get(tl, ti));
            st = st_temp(st, tdepth);
            ti = ti + 1;
        }
        if (m > 0) {
            Yv *lastn = ya_get(tl, m - 1);
            st = gen_loc_stmt(st, lastn);
            st = gen_tail(st, lastn);
            ;
        }
        return st;
    } else if (yv_l(k) == K_kw_if) {
        long jcc = int_cmp_jcc(st, yr_get(node, "cond"));
        if (jcc == 0) {
            st = gen(st, yr_get(node, "cond"));
        }
        Yv *rl1 = next_loc(st);
        st = yr_get(rl1, "st");
        Yv *lelse = yr_get(rl1, "label");
        Yv *rl2 = next_loc(st);
        st = yr_get(rl2, "st");
        Yv *lend = yr_get(rl2, "label");
        if (jcc != 0) {
            /* the flags come from the comparison itself (see int_cmp_jcc) */
            st = gen_cmp_flags(st, yr_get(node, "cond"));
            st = emit_insn(st, jcc, yv_l(lelse), 0, 0, 0, 0, 0, 0);
        } else {
            st = emit_insn(st, F_TEST_R_R, R_RAX, 64, R_RAX, 64, 0, 0, 0);
            st = emit_insn(st, F_JZ_L, yv_l(lelse), 0, 0, 0, 0, 0, 0);
        }
        st = gen_tail(st, yr_get(node, "then"));
        if (yv_b(yr_get(node, "has_else"))) {
            st = emit_insn(st, F_JMP_L, yv_l(lend), 0, 0, 0, 0, 0, 0);
            st = emit_label(st, yv_l(lelse));
            st = gen_loc_elif(st, yr_get(node, "els"));
            st = gen_tail(st, yr_get(node, "els"));
            return emit_label(st, yv_l(lend));
        }
        return emit_label(st, yv_l(lelse));
    }
    return gen_as(st, node, cur_fn_ret(st));
}

Yv *gen_block(Yv *st, Yv *node) {
    return gen_block_as(st, node, 0);
}

/* `dropped`: nobody takes the block's value (a loop body), so its last
 * statement is a statement (gen_stmt) as well as the ones before it. */
Yv *gen_block_as(Yv *st, Yv *node, int dropped) {
    /* No scope push: names are unique post-rename, so a block reuses the slots
     * of the blocks around it. */
    Yv *stmts = yr_get(node, "stmts");
    if (yv_len(stmts) == 0) {
        return emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
    } else {
        /* The frame is the DEEPEST block's slots, not the sum of them all: the
         * slots a block takes are released as it ends. Sound because nothing
         * outside reads them -- a name it declared is out of scope there (the
         * checker agrees), and a captured variable lives in a heap cell that a
         * closure reaches through its own captures, not through this slot. */
        long depth = yv_l(yr_get(st, "slots"));
        long tdepth = yv_l(yr_get(st, "temp"));
        /* A trailing `;` (void) computes nothing: nothing to emit. */
        long m = yv_len(stmts);
        if (m > 1 && is_void_node(ya_get(stmts, m - 1))) {
            m = m - 1;
        }
        long i = 0;
        while (i < m) {
            st = gen_loc_stmt(st, ya_get(stmts, i));
            if (dropped || i < yv_len(stmts) - 1) {
                st = gen_stmt(st, ya_get(stmts, i));
                ;
            } else {
                st = gen(st, ya_get(stmts, i));
                ;
            }
            /* this statement's own temporaries are dead; the ones of the
               statement this block sits in are not, hence tdepth and not 0 */
            st = st_temp(st, tdepth);
            i = i + 1;
        }
        return st_slots(st, depth);
    }
}

int is_void_node(Yv *n) {
    return yv_l(yr_get(n, "k")) == K_void;
}

/* ── -g: line markers (see dbg_lines) ────────────────────────────────── */

/* The marker for line `ln` of the spliced program: its origin file's
 * `.file` number (the index + 1) and its line there, counted on past the
 * end of the map like origin_at. Line 0 is DWARF's "no source line". */
Yv *loc_pos(long ln) {
    Yv *f = dbg_file;
    Yv *l = dbg_line;
    long n = yv_len(f);
    if (ln < 1 || n == 0) {
        return yr(2, "file", yv_long(1), "line", yv_long(ln));
    } else {
        long k = ln;
        if (k > n) { k = n; ; }
        long fid = yv_l(ya_get(f, k - 1));
        long line = yv_l(ya_get(l, k - 1)) + ln - k;
        return yr(2, "file", yv_long(fid + 1), "line", yv_long(line));
    }
}

/* The marker as an IR item: the line table reads (file, line) as fields, not
 * out of the text (link_locs renumbered a `.loc` per body by splitting the
 * string; that goes with stage 2b). */
static Yv *emit_loc(Yv *st, long ln) {
    Yv *p = loc_pos(ln);
    return emit_insn(st, IR_LOC, yv_l(yr_get(p, "file")),
                     yv_l(yr_get(p, "line")), 0, 0, 0, 0, 0);
}

/* The marker as an IR item appended to a buffer (the body assembled around the
 * function's own items, in emit_one_fn). */
static Yv *ir_loc(Yv *body, long ln) {
    Yv *p = loc_pos(ln);
    return ir_push(body, IR_LOC, yv_l(yr_get(p, "file")),
                   yv_l(yr_get(p, "line")), 0, 0, 0, 0, 0);
}

/* A statement's marker, before its code. A bare `;` has no position (and
 * no code). */
Yv *gen_loc_stmt(Yv *st, Yv *node) {
    if (dbg_lines) {
        if (is_void_node(node)) {
            return st;
        } else {
            return emit_loc(st, yv_l(yr_get(node, "line")));
        }
    } else {
        return st;
    }
}

/* An `else if` gets a marker of its own: its test would otherwise count
 * as the last line of the branch before it. */
Yv *gen_loc_elif(Yv *st, Yv *els) {
    if (dbg_lines) {
        Yv *k = yr_get(els, "k");
        if (yv_l(k) == K_kw_if) {
            return emit_loc(st, yv_l(yr_get(els, "line")));
        } else {
            return st;
        }
    } else {
        return st;
    }
}

/* A loop's back edge (its step, the counter's increment, the jump to the
 * test) belongs to the loop's own line, not to the body's last one. */
Yv *gen_loc_loop(Yv *st, Yv *node) {
    if (dbg_lines) {
        return emit_loc(st, yv_l(yr_get(node, "line")));
    } else {
        return st;
    }
}

/* The `.file N "path"` table the markers number into: one per origin
 * file, N = its index + 1. */
Yv *file_dirs(Yv *files) {
    Yv *pieces = yav(0);
    long i = 0;
    while (i < yv_len(files)) {
        Yv *fname = ya_get(files, i);
        Yv *piece = ys_cat(ys(".file "), ys_long(i + 1));
        piece = ys_cat(piece, ys(" \""));
        piece = ys_cat(piece, esc_asm(fname));
        piece = ys_cat(piece, ys("\"\n"));
        pieces = ya_push(pieces, piece);
        i = i + 1;
    }
    return ys_join(pieces, ys(""));
}

/* Position of `name` in a record literal's merged field list, or -1. */
long mfield_idx(Yv *names, Yv *name) {
    long i = 0;
    long out = -1;
    while (i < yv_len(names)) {
        Yv *nm = ya_get(names, i);
        if (ys_eq(nm, name)) {
            out = i;
            ;
        }
        i = i + 1;
    }
    return out;
}

/* ── records at run time ────────────────────────────────────────────────
 * A record is laid out by field name: its fields sorted, the one in slot
 * i at record+8i, whatever order a literal or a type writes them in --
 * but one held in a union value has the union's shared fields first
 * ("union layouts" below). The word at record-8 points to the descriptor of its type, `ytt_<hash>`:
 * one per structural type, named by a 64-bit FNV-1a hash of the type's
 * canonical form (tcanon). Each unit emits the descriptors its code uses
 * (ty_desc), and the link keeps one per label (link_units). The canonical
 * form travels with the descriptor, so two types with one hash are an
 * error, never a merge. A descriptor is one byte: its address is the tag
 * that `match`, a union's printer, a pattern's field read and a cast
 * compare. */

/* FNV-1a over the bytes of s, 64-bit (the multiply wraps). */
long fnv64(Yv *s) {
    unsigned long h = 14695981039346656037UL; /* -3750763034362895579 */
    long n = yv_len(s);
    long i = 0;
    while (i < n) {
        h = (h ^ (unsigned long)ys_byte_at(s, i)) * 1099511628211UL;
        i = i + 1;
    }
    return (long)h;
}

/* h as 16 lowercase hex digits. */
Yv *hex16(long h) {
    Yv *digits = ys("0123456789abcdef");
    Yv *out = ys("");
    long sh = 60;
    while (sh >= 0) {
        long d = (long)(((unsigned long)h >> sh) & 15);
        out = ys_cat(out, ys_slice(digits, d, d + 1));
        sh = sh - 4;
    }
    return out;
}

/* The slot of field `key` in a record of the fields fs: how many of their
 * names sort before it (-1 when there is no such field). */
long rec_slot(Yv *fs, Yv *key) {
    int found = 0;
    long below = 0;
    long i = 0;
    while (i < yv_len(fs)) {
        Yv *fname = yr_get(ya_get(fs, i), "name");
        if (ys_eq(fname, key)) {
            found = 1;
        } else if (ys_cmp(fname, key) < 0) {
            below = below + 1;
        }
        i = i + 1;
    }
    if (found) {
        return below;
    } else {
        return -1;
    }
}

/* Adds the descriptor label lbl, of canonical form `form`, to ty_seen: 1
 * when it is new, 0 when it is there with that form, -1 when it is there
 * with another (two types, one hash). */
long tyset_add(Yv *lbl, Yv *form) {
    if (2 * (ty_count + 1) > yv_len(ty_seen)) {
        tyset_grow();
    }
    long mask = yv_len(ty_seen) - 1;
    long i = fnv64(lbl) & mask;
    long out = 1;
    int looking = 1;
    while (looking) {
        Yv *cur = ya_get(ty_seen, i);
        if (yv_len(cur) == 0) {
            ya_set(ty_seen, i, lbl);
            ya_set(ty_forms, i, form);
            ty_count = ty_count + 1;
            looking = 0;
        } else if (ys_eq(cur, lbl)) {
            if (ys_eq(ya_get(ty_forms, i), form)) {
                out = 0;
            } else {
                out = -1;
            }
            looking = 0;
        } else {
            i = (i + 1) & mask;
        }
    }
    return out;
}

void tyset_grow(void) {
    Yv *old = ty_seen;
    Yv *oldf = ty_forms;
    long cap = 2 * yv_len(old);
    if (cap < 64) {
        cap = 64;
    }
    Yv *fresh = yav(0);
    Yv *freshf = yav(0);
    long i = 0;
    while (i < cap) {
        fresh = ya_push(fresh, ys(""));
        freshf = ya_push(freshf, ys(""));
        i = i + 1;
    }
    ty_seen = fresh;
    ty_forms = freshf;
    ty_count = 0;
    long j = 0;
    while (j < yv_len(old)) {
        Yv *lb = ya_get(old, j);
        if (yv_len(lb) > 0) {
            tyset_add(lb, ya_get(oldf, j));
        }
        j = j + 1;
    }
}

void tyset_reset(void) {
    ty_seen = yav(0);
    ty_forms = yav(0);
    ty_count = 0;
    /* the signature cache's buckets are made when first used (ty_sig_init) */
    ty_sig_bkts = yav(0);
    ush_nodes = yav(0);
    ush_vals = yav(0);
}

void ty_sig_init(void) {
    Yv *bkts = yav(0);
    long i = 0;
    while (i < 512) {
        bkts = ya_push(bkts, yav(0));
        i = i + 1;
    }
    ty_sig_keys = yav(0);
    ty_sig_ids = yav(0);
    ty_sig_bkts = bkts;
}

/* The canonical form of record type rt (types.c tcanon). A record type
 * spelled out that equals a recursive alias (alias_of) takes the alias's
 * form. */
Yv *ty_form(Yv *rt) {
    if (yv_l(yr_get(rt, "k")) == K_trec) {
        Yv *al = alias_of(rt);
        if (yv_l(yr_get(al, "k")) == K_tref) {
            return tcanon(al);
        } else {
            return tcanon(rt);
        }
    } else {
        return tcanon(rt);
    }
}

/* The recursive alias equal (types.c teq) to record type t, spelled out --
 * a record literal's inferred type, say ({k: str, to: Type} is the alias
 * TPtr) -- among the aliases reachable from t; tnone when none is. Equal
 * types must have one descriptor, or a read through a union holding the
 * record finds no member's tag. */
Yv *alias_of(Yv *t) {
    Yv *names = ys_join(rec_names(yr_get(t, "fields")), ys(","));
    Yv *seen = yav(0);
    Yv *todo = yav(0);
    todo = ya_push(todo, t);
    long i = 0;
    while (i < yv_len(todo)) {
        Yv *x = ya_get(todo, i);
        Yv *k = yr_get(x, "k");
        if (yv_l(k) == K_tref) {
            Yv *tmp = yr_get(x, "tmp");
            long j = 0;
            int met = 0;
            while (j < yv_len(seen)) {
                if (ys_eq(ya_get(seen, j), tmp)) {
                    met = 1;
                }
                j = j + 1;
            }
            if (!met) {
                seen = ya_push(seen, tmp);
                Yv *u = unfold(x);
                if (yv_l(yr_get(u, "k")) == K_trec &&
                    ys_eq(ys_join(rec_names(yr_get(u, "fields")), ys(",")), names) &&
                    teq(t, x)) {
                    return x;
                }
                todo = ya_push(todo, u);
            }
        } else if (yv_l(k) == K_trec) {
            Yv *fs = yr_get(x, "fields");
            long j = 0;
            while (j < yv_len(fs)) {
                todo = ya_push(todo, yr_get(ya_get(fs, j), "typ"));
                j = j + 1;
            }
        } else if (yv_l(k) == K_tunion) {
            Yv *ms = yr_get(x, "ts");
            long j = 0;
            while (j < yv_len(ms)) {
                todo = ya_push(todo, ya_get(ms, j));
                j = j + 1;
            }
        } else if (yv_l(k) == K_tfunc) {
            Yv *as = yr_get(x, "args");
            long j = 0;
            while (j < yv_len(as)) {
                todo = ya_push(todo, ya_get(as, j));
                j = j + 1;
            }
            todo = ya_push(todo, yr_get(x, "ret"));
        } else if (yv_l(k) == K_tmap) {
            todo = ya_push(todo, yr_get(x, "key"));
            todo = ya_push(todo, yr_get(x, "of"));
        } else if (yv_l(k) == K_tptr) {
            todo = ya_push(todo, yr_get(x, "to"));
        } else if (yv_l(k) == K_tarr || yv_l(k) == K_tarrfix ||
                   yv_l(k) == K_topt) {
            todo = ya_push(todo, yr_get(x, "of"));
        }
        i = i + 1;
    }
    return yr(1, "k", yv_long(K_tnone));
}

/* Two types with one descriptor label: stop (a 64-bit hash collision;
 * the program cannot be linked with this compiler). */
void ty_collision(Yv *lbl, Yv *form) {
    puts_(ys_cat(ys_cat(ys_cat(ys_cat(ys("ycc: two record types hash to "), lbl),
                               ys(" (")),
                        form),
                 ys("); cannot link this program\n")));
    exit_(1);
}

/* The descriptor label of record type rt; its rodata entry (label,
 * canonical form, quads) goes into the unit the first time the unit uses
 * it. */
Yv *ty_desc(Yv *st, Yv *rt) {
    return ty_desc_as(st, rt, ys(""));
}

/* ty_desc of record type rt laid out as `lay` says ("" for its own
 * order; else "@" and the field names in their slots: a member held in a
 * union, union_lay). */
Yv *ty_desc_as(Yv *st, Yv *rt, Yv *lay) {
    Yv *sig = ys_cat(tsig(rt), lay);
    if (!ty_sig_bkts || yv_len(ty_sig_bkts) == 0) {
        ty_sig_init();
    }
    long h = fnv64(sig) % 512;
    if (h < 0) {
        h = h + 512;
    }
    Yv *bkt = ya_get(ty_sig_bkts, h);
    Yv *known = yv_long(-1);
    long q = 0;
    while (q < yv_len(bkt)) {
        long ix = yv_l(ya_get(bkt, q));
        if (yv_l(known) < 0 && ys_eq(ya_get(ty_sig_keys, ix), sig)) {
            known = ya_get(ty_sig_ids, ix);
        }
        q = q + 1;
    }
    if (yv_l(known) >= 0) {
        return yr(2, "st", st, "label", known);
    }
    Yv *form = ys_cat(ty_form(rt), lay);
    Yv *lbl = ys_cat(ys("ytt_"), hex16(fnv64(form)));
    Yv *id = lbl_new(lbl);
    ty_sig_keys = ya_push(ty_sig_keys, sig);
    ty_sig_ids = ya_push(ty_sig_ids, id);
    ya_push(bkt, yv_long(yv_len(ty_sig_keys) - 1));
    long added = tyset_add(lbl, form);
    if (added < 0) {
        ty_collision(lbl, form);
    }
    if (added > 0) {
        /* [label, canonical form]: the form only travels for the link's
         * collision check; the descriptor is one byte (rodata_pieces) */
        Yv *te = yav(0);
        te = ya_push(te, lbl);
        te = ya_push(te, form);
        ya_push(yr_get(st, "rodata"), te);
    }
    return yr(2, "st", st, "label", id);
}

/* ── union layouts (CHOICES_MADE.md 25) ─────────────────────────────────
 * A record held in a union value is laid out with the union's shared
 * fields first -- the fields every member has, with one type, sorted --
 * then its other fields, sorted; a standalone record has all its fields
 * sorted. A shared field is then one load at one offset, whatever the
 * member. A value going from one layout to the other is a conversion
 * (gen_convert): the record is copied into the other layout where the
 * two differ, and its tag names its type in that layout (ty_desc_in). */

/* The shared fields of union u (unfolded), sorted. Remembered by the
 * union's node (ush_nodes, emptied for each unit): a recursive alias
 * unfolds to one union node, and every read of a shared field asks. */
Yv *union_shared(Yv *u) {
    long i = 0;
    while (i < yv_len(ush_nodes)) {
        if (ya_get(ush_nodes, i) == u) {
            return ya_get(ush_vals, i);
        }
        i = i + 1;
    }
    Yv *ms = members(u);
    Yv *out = yav(0);
    if (yv_len(ms) > 0) {
        Yv *fs = yr_get(ya_get(ms, 0), "fields");
        long j = 0;
        while (j < yv_len(fs)) {
            Yv *f = ya_get(fs, j);
            int ok = 1;
            long q = 0;
            while (q < yv_len(ms)) {
                Yv *ft = rec_field_type(ya_get(ms, q), yr_get(f, "name"));
                if (ok && (yv_l(yr_get(ft, "k")) == K_tnone ||
                           !teq(ft, yr_get(f, "typ")))) {
                    ok = 0;
                }
                q = q + 1;
            }
            if (ok) {
                out = ya_push(out, yr_get(f, "name"));
            }
            j = j + 1;
        }
    }
    Yv *sorted = str_sorted(out);
    ush_nodes = ya_push(ush_nodes, u);
    ush_vals = ya_push(ush_vals, sorted);
    return sorted;
}

/* The slots of member m (unfolded) held in union u (unfolded): the
 * field names in slot order. */
Yv *union_lay(Yv *m, Yv *u) {
    Yv *sh = union_shared(u);
    Yv *fs = yr_get(m, "fields");
    Yv *rest = yav(0);
    long i = 0;
    while (i < yv_len(fs)) {
        Yv *f = ya_get(fs, i);
        if (mfield_idx(sh, yr_get(f, "name")) < 0) {
            rest = ya_push(rest, yr_get(f, "name"));
        }
        i = i + 1;
    }
    Yv *out = yav(0);
    long j = 0;
    while (j < yv_len(sh)) {
        out = ya_push(out, ya_get(sh, j));
        j = j + 1;
    }
    Yv *rs = str_sorted(rest);
    j = 0;
    while (j < yv_len(rs)) {
        out = ya_push(out, ya_get(rs, j));
        j = j + 1;
    }
    return out;
}

/* The slots of a record of type t (unfolded) held where type `inu` is
 * declared: in a union, union_lay; else its own sorted fields. */
Yv *lay_of(Yv *t, Yv *inu) {
    if (yv_l(yr_get(inu, "k")) == K_tunion) {
        return union_lay(t, inu);
    } else {
        return rec_names(yr_get(t, "fields"));
    }
}

int same_lay(Yv *a, Yv *b) {
    int same = yv_len(a) == yv_len(b);
    long i = 0;
    while (same && i < yv_len(a)) {
        if (!ys_eq(ya_get(a, i), ya_get(b, i))) {
            same = 0;
        }
        i = i + 1;
    }
    return same;
}

/* The tag of member m (as written in the union, maybe a tref) held where
 * `inu` is declared: its own descriptor where its layout there is its own
 * order, else the descriptor of m in that layout. */
Yv *ty_desc_in(Yv *st, Yv *m, Yv *inu) {
    Yv *mu = unfold(m);
    Yv *lay = lay_of(mu, inu);
    if (same_lay(lay, rec_names(yr_get(mu, "fields")))) {
        return ty_desc(st, m);
    } else {
        return ty_desc_as(st, m, ys_cat(ys("@"), ys_join(lay, ys(","))));
    }
}

/* The record in %rax (slots `from`) copied into slots `to`, tagged
 * `tag`: a new record in %rax. */
Yv *gen_copy_rec(Yv *st, Yv *from, Yv *to, Yv *tag) {
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_MOV_I_R, 8 * yv_len(to) + 16, R_RDI, 64, 0, 0, 0, 0);
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_alloc"))), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_LEA_P_R, -1, -1, 1, 0, yv_l(tag), R_RCX, 64);
    st = emit_insn(st, F_MOV_R_D, R_RCX, 64, R_RAX, -1, 1, 0, -1);
    st = emit_insn(st, F_POP_R, R_RSI, 64, 0, 0, 0, 0, 0);
    long i = 0;
    while (i < yv_len(to)) {
        long s = mfield_idx(from, ya_get(to, i));
        st = emit_insn(st, F_MOV_D_R, R_RSI, -1, 1, 8 * s, -1, R_RCX, 64);
        st = emit_insn(st, F_MOV_R_D, R_RCX, 64, R_RAX, -1, 1, 8 + 8 * i, -1);
        i = i + 1;
    }
    return emit_insn(st, F_ADD_I_R, 8, R_RAX, 64, 0, 0, 0, 0);
}

/* The value in %rax, of static type src0, going where want0 is declared:
 * a member into a union, a union into one of its members (`check`: its
 * tag is checked first), or a union into another. Each member whose
 * layout differs on the two sides is copied (gen_copy_rec); a cast to
 * members the value does not hold stops the program (y_cast_trap). */
Yv *gen_convert(Yv *st, Yv *src0, Yv *want0, int check) {
    Yv *s = unfold(src0);
    Yv *w = unfold(want0);
    Yv *sk = yr_get(s, "k");
    Yv *wk = yr_get(w, "k");
    if (yv_l(sk) == K_trec && yv_l(wk) == K_tunion) {
        Yv *m = union_member(w, s);
        if (yv_l(yr_get(m, "k")) == K_tnone) {
            return st;
        } else {
            Yv *from = lay_of(s, src0);
            Yv *to = union_lay(unfold(m), w);
            if (same_lay(from, to)) {
                return st;
            } else {
                Yv *dr = ty_desc_in(st, m, w);
                st = yr_get(dr, "st");
                return gen_copy_rec(st, from, to, yr_get(dr, "label"));
            }
        }
    } else if (yv_l(sk) == K_tunion &&
               (yv_l(wk) == K_trec || yv_l(wk) == K_tunion)) {
        int within = union_within(s, want0);
        /* one union into another sharing the same fields: every member
         * keeps its layout and tag */
        if (within && yv_l(wk) == K_tunion &&
            same_lay(union_shared(s), union_shared(w))) {
            return st;
        }
        Yv *ms = yav(0);
        if (within) {
            ms = union_parts(s);
        } else {
            ms = cast_members(s, want0);
        }
        /* per member: its slots and tag here, its slots and tag there */
        Yv *froms = yav(0);
        Yv *tos = yav(0);
        Yv *tws = yav(0);
        int moves = 0;
        long q = 0;
        while (q < yv_len(ms)) {
            Yv *m = ya_get(ms, q);
            Yv *mu = unfold(m);
            Yv *from = union_lay(mu, s);
            Yv *tw = m;
            if (yv_l(wk) == K_tunion) {
                Yv *mw = union_member(w, m);
                if (yv_l(yr_get(mw, "k")) != K_tnone) {
                    tw = mw;
                }
            }
            Yv *to = lay_of(mu, w);
            froms = ya_push(froms, from);
            tos = ya_push(tos, to);
            tws = ya_push(tws, tw);
            if (!same_lay(from, to)) {
                moves = 1;
            }
            q = q + 1;
        }
        if (!moves) {
            if (within || !check) {
                return st;
            } else {
                return gen_cast_check(st, ms, s);
            }
        } else {
            Yv *done = next_loc(st);
            st = yr_get(done, "st");
            st = emit_insn(st, F_MOV_D_R, R_RAX, -1, 1, -8, -1, R_RCX, 64);
            Yv *lbls = yav(0);
            long i = 0;
            while (i < yv_len(ms)) {
                Yv *l = next_loc(st);
                st = yr_get(l, "st");
                lbls = ya_push(lbls, yr_get(l, "label"));
                Yv *dr = ty_desc_in(st, ya_get(ms, i), s);
                st = yr_get(dr, "st");
                st = emit_insn(st, F_LEA_P_R, -1, -1, 1, 0, yv_l(yr_get(dr, "label")), R_RDX, 64);
                st = emit_insn(st, F_CMP_R_R, R_RDX, 64, R_RCX, 64, 0, 0, 0);
                st = emit_insn(st, F_JE_L, yv_l(yr_get(l, "label")), 0, 0, 0, 0, 0, 0);
                i = i + 1;
            }
            st = emit_insn(st, F_JMP_L, yv_l(lbl_new(ys("y_cast_trap"))), 0, 0, 0, 0, 0, 0);
            i = 0;
            while (i < yv_len(ms)) {
                st = emit_label(st, yv_l(ya_get(lbls, i)));
                Yv *from = ya_get(froms, i);
                Yv *to = ya_get(tos, i);
                if (!same_lay(from, to)) {
                    Yv *dr = ty_desc_in(st, ya_get(tws, i), w);
                    st = yr_get(dr, "st");
                    st = gen_copy_rec(st, from, to, yr_get(dr, "label"));
                }
                /* not on the last arm: that one falls through into `done:` */
                if (i < yv_len(ms) - 1) {
                    st = emit_insn(st, F_JMP_L, yv_l(yr_get(done, "label")), 0, 0, 0, 0, 0, 0);
                    ;
                }
                i = i + 1;
            }
            return emit_label(st, yv_l(yr_get(done, "label")));
        }
    } else {
        return st;
    }
}

/* lt (a record literal's type) is the record type t: the same field names
 * and equal types. */
int same_rec(Yv *lt, Yv *t) {
    if (yv_l(yr_get(t, "k")) != K_trec ||
        yv_l(yr_get(lt, "k")) != K_trec) {
        return 0;
    } else {
        Yv *lfs = yr_get(lt, "fields");
        Yv *tfs = yr_get(t, "fields");
        if (yv_len(lfs) != yv_len(tfs)) {
            return 0;
        } else {
            return teq(lt, t);
        }
    }
}

/* The type a record literal of type lt is created as when it goes where
 * `want` is declared (gen_as): want itself when lt is that record type,
 * the first member of a union want that lt is; lt otherwise. */
Yv *rec_lit_type(Yv *lt, Yv *want) {
    Yv *w = unfold(want);
    Yv *wk = yr_get(w, "k");
    if (yv_l(wk) == K_trec) {
        if (same_rec(lt, w)) {
            return want;
        } else {
            return lt;
        }
    } else if (yv_l(wk) == K_tunion) {
        Yv *ms = union_parts(w);
        Yv *found = lt;
        int looking = 1;
        long i = 0;
        while (looking && i < yv_len(ms)) {
            if (same_rec(lt, unfold(ya_get(ms, i)))) {
                found = ya_get(ms, i);
                looking = 0;
            }
            i = i + 1;
        }
        return found;
    } else {
        return lt;
    }
}

/* Record literal { k: v, ... }: heap-allocate the descriptor word and the
 * fields, store the descriptor, then evaluate the values in the order they
 * are written, each into its field's slot (see "records at run time"; a
 * member of a declared union in the union's layout). The
 * VALUE is the record address (8 bytes, first-class: locals, params,
 * returns all just copy it). `want` is the type declared where the record
 * goes (gen_as; tnone for none): a literal of that record type, or of a
 * member of that union, is created as it (rec_lit_type), so its descriptor
 * names the declared type -- `{a: none}` stored as a {a: long?} is one.
 * (y_alloc(0) is fine — bump allocators return a valid, if empty, block;
 * empty maps are rejected by the checker anyway.) */
Yv *gen_reclit(Yv *st, Yv *node, Yv *want) {
    Yv *mvals = yr_get(node, "vals");
    Yv *mkeys = yr_get(node, "keys");
    long nent = yv_len(mvals);
    /* Static merge for `...` spread entries (the types.y field_merge
     * rule): a later entry wins the value. The value loop below stores
     * into the fields' slots in entry order, so a later store simply
     * overwrites -- no dynamic shape. */
    Yv *names = yav(0);
    long ni = 0;
    while (ni < nent) {
        Yv *nk = ya_get(mkeys, ni);
        if (ys_eq_lit(nk, "...")) {
            Yv *srec = infer(st, ya_get(mvals, ni));
            if (yv_l(yr_get(srec, "k")) == K_trec) {
                Yv *sfs = yr_get(srec, "fields");
                long si = 0;
                while (si < yv_len(sfs)) {
                    Yv *sf = ya_get(sfs, si);
                    if (mfield_idx(names, yr_get(sf, "name")) < 0) {
                        names = ya_push(names, yr_get(sf, "name"));
                    }
                    si = si + 1;
                }
            }
        } else {
            if (mfield_idx(names, nk) < 0) {
                names = ya_push(names, nk);
            }
        }
        ni = ni + 1;
    }
    Yv *rt = lit_target(node, want);
    if (yv_l(yr_get(rt, "k")) == K_tnone) {
        rt = rec_lit_type(infer(st, node), want);
    }
    Yv *rtu = unfold(rt);
    /* the declared type's optional fields the literal leaves out have their
     * slots too: none, which y_alloc's never-reused zeroed memory already is */
    if (yv_l(yr_get(rtu, "k")) == K_trec) {
        Yv *tfs = yr_get(rtu, "fields");
        for (long q = 0; q < yv_len(tfs); q++) {
            Yv *f = ya_get(tfs, q);
            if (mfield_idx(names, yr_get(f, "name")) < 0) {
                names = ya_push(names, yr_get(f, "name"));
            }
        }
    }
    long n = yv_len(names);
    Yv *slots = str_sorted(names);
    /* made as a member of a declared union: in the union's layout */
    Yv *wu = unfold(want);
    if (yv_l(yr_get(wu, "k")) == K_tunion && yv_l(yr_get(rtu, "k")) == K_trec) {
        slots = union_lay(rtu, wu);
    }
    Yv *dr = ty_desc_in(st, rt, wu);
    st = yr_get(dr, "st");
    st = emit_insn(st, F_MOV_I_R, 8 * n + 16, R_RDI, 64, 0, 0, 0, 0);
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_alloc"))), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_LEA_P_R, -1, -1, 1, 0, yv_l(yr_get(dr, "label")), R_RAX, 64);
    st = emit_insn(st, F_POP_R, R_RCX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_MOV_R_D, R_RAX, 64, R_RCX, -1, 1, 0, -1);
    st = emit_insn(st, F_PUSH_R, R_RCX, 64, 0, 0, 0, 0, 0);
    long i = 0;
    while (i < nent) {
        /* mv is walked twice (gen, then infer), so bind it once. */
        Yv *mv = ya_get(mvals, i);
        Yv *mk = ya_get(mkeys, i);
        if (ys_eq_lit(mk, "...")) {
            /* Spread: the source runs ONCE; copy each of its fields into
             * the slot it has here. A later entry's store overwrites. */
            st = gen(st, mv);
            st = emit_insn(st, F_POP_R, R_RCX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, F_MOV_R_R, R_RAX, 64, R_RDX, 64, 0, 0, 0);
            Yv *srec2 = infer(st, mv);
            if (yv_l(yr_get(srec2, "k")) == K_trec) {
                Yv *sfs2 = yr_get(srec2, "fields");
                long sj = 0;
                while (sj < yv_len(sfs2)) {
                    Yv *sf2 = ya_get(sfs2, sj);
                    long mi2 = mfield_idx(slots, yr_get(sf2, "name"));
                    /* %rdx is the source's record VALUE (slot 0 at +0);
                     * %rcx is the fresh record's ALLOC base (slots at +8). */
                    st = emit_insn(st, F_MOV_D_R, R_RDX, -1, 1, 8 * rec_slot(sfs2, yr_get(sf2, "name")), -1, R_RSI, 64);
                    st = emit_insn(st, F_MOV_R_D, R_RSI, 64, R_RCX, -1, 1, 8 + mi2 * 8, -1);
                    sj = sj + 1;
                }
            }
        } else {
            Yv *ft = rec_field_type(rtu, mk);
            if (lit_wraps(st, mv, rtu, mk, ft)) {
                /* a plain T for an optional field: some(v) */
                st = gen_as(st, mv, yr_get(ft, "of"));
                st = gen_box_rax(st);
            } else {
                st = gen_as(st, mv, ft);
            }
            st = emit_insn(st, F_POP_R, R_RCX, 64, 0, 0, 0, 0, 0);
            long mi = mfield_idx(slots, mk);
            st = emit_insn(st, F_MOV_R_D, R_RAX, 64, R_RCX, -1, 1, 8 + mi * 8, -1);
        }
        st = emit_insn(st, F_PUSH_R, R_RCX, 64, 0, 0, 0, 0, 0);
        i = i + 1;
    }
    st = emit_insn(st, F_POP_R, R_RAX, 64, 0, 0, 0, 0, 0);
    return emit_insn(st, F_ADD_I_R, 8, R_RAX, 64, 0, 0, 0, 0);
}

/* Value mv given for field mk of rtu, the record type a literal is created
 * as, is wrapped -- some(v) -- when the field is optional and mv a plain T
 * (types.c opt_wraps, as typeof_lit decides): its type as the checker
 * takes it, a record literal the type it is created as there. */
int lit_wraps(Yv *st, Yv *mv, Yv *rtu, Yv *mk, Yv *ft) {
    int opt = 0;
    if (yv_l(yr_get(rtu, "k")) == K_trec) {
        Yv *tfs = yr_get(rtu, "fields");
        for (long q = 0; q < yv_len(tfs); q++) {
            Yv *f = ya_get(tfs, q);
            if (ys_eq(yr_get(f, "name"), mk) && yv_b(yr_get(f, "opt"))) {
                opt = 1;
            }
        }
    }
    if (!opt || yv_l(yr_get(ft, "k")) != K_topt) {
        return 0;
    }
    Yv *vt = infer(st, mv);
    if (yv_l(yr_get(mv, "k")) == K_rec) {
        Yv *lt = lit_target(mv, yr_get(ft, "of"));
        if (yv_l(yr_get(lt, "k")) != K_tnone) {
            vt = lt;
        }
    }
    return opt_wraps(vt, ft);
}

/* An anonymous `def(...) {...}` used as a value: it has no entry in the
 * hoisted table, so give it a fresh label, emit the body here (where the
 * capture types are known) and hand back the closure record. */
Yv *gen_func_literal(Yv *st, Yv *node) {
    Yv *caps = fn_captures(node, yr_get(yr_get(st, "fns"), "ix"), ys(""));
    Yv *captypes = yav(0);
    long ci = 0;
    while (ci < yv_len(caps)) {
        Yv *cn = ya_get(caps, ci);
        Yv *ce = env_find(st, cn);
        captypes = ya_push(captypes, yr_get(ce, "typ"));
        ci = ci + 1;
    }
    Yv *rl = next_uid(st);
    st = yr_get(rl, "st");
    Yv *lbl = lbl_new(arch_fn_label(yv_l(yr_get(rl, "uid")), ys("anon")));
    Yv *ru = next_uid(st);
    st = yr_get(ru, "st");
    st = emit_one_fn(st, lbl, yv_l(yr_get(ru, "uid")), node, 0, 0, captypes,
                     ys(""));
    long bci = 0;
    while (bci < yv_len(caps)) {
        Yv *bcn = ya_get(caps, bci);
        st = box_capture(st, bcn);
        bci = bci + 1;
    }
    return gen_make_closure(st, lbl, caps);
}

/* Bind `name` to a closure over `func`: emit the body HERE (the enclosing
 * env still knows each captured name's type — emit_program deliberately
 * skips capturing functions), build the record, store it in a fresh slot.
 * Such a function (see capturing_defs) is not in the hoisted table, so it
 * gets its label here; its body knows its own name (emit_one_fn). */
Yv *gen_closure_binding(Yv *st, Yv *name, Yv *func, Yv *caps) {
    Yv *captypes = yav(0);
    long ci = 0;
    while (ci < yv_len(caps)) {
        Yv *cn2 = ya_get(caps, ci);
        Yv *ce = env_find(st, cn2);
        captypes = ya_push(captypes, yr_get(ce, "typ"));
        ci = ci + 1;
    }
    Yv *rl = next_uid(st);
    st = yr_get(rl, "st");
    Yv *lbl = lbl_new(fn_label_of(yv_l(yr_get(rl, "uid")), name));
    Yv *ru = next_uid(st);
    st = yr_get(ru, "st");
    st = emit_one_fn(st, lbl, yv_l(yr_get(ru, "uid")), func, 0, 0, captypes,
                     name);
    long bci = 0;
    while (bci < yv_len(caps)) {
        Yv *bcn = ya_get(caps, bci);
        st = box_capture(st, bcn);
        bci = bci + 1;
    }
    st = gen_make_closure(st, lbl, caps);
    /* a NAME (let f = ...), so its slot lives to the end of the block */
    long coff = (yv_l(yr_get(st, "slots")) + 1) * -8;
    st = emit_insn(st, F_MOV_R_D, R_RAX, 64, R_RBP, -1, 1, coff, -1);
    Yv *st3 =
        yr(15, "ir", yr_get(st, "ir"), "txt", yr_get(st, "txt"), "rodata",
           yr_get(st, "rodata"), "uid", yr_get(st, "uid"), "fuid",
           yr_get(st, "fuid"), "loc", yr_get(st, "loc"), "env",
           yr_get(st, "env"), "slots", yv_long(yv_l(yr_get(st, "slots")) + 1),
           "temp", yr_get(st, "temp"), "self_label", yr_get(st, "self_label"),
           "end_label", yr_get(st, "end_label"), "fns", yr_get(st, "fns"),
           "bodies", yr_get(st, "bodies"), "btext", yr_get(st, "btext"),
           "blabels", yr_get(st, "blabels"));
    st3 = env_define(st3, name, ys("closure"), coff, yv_long(-1), ys(""),
                     func_type_in(st3, func));
    return box_bound(st3, name);
}

Yv *gen_decl(Yv *st, Yv *node) {
    if (ys_eq_lit(yr_get(node, "kind"), "def")) {
        /* A nested `def` that captures is a closure just like a let-bound
         * literal; a capture-free one stays hoisted (emitted by
         * emit_program, env pre-bound, calls go direct). Its own name is
         * no capture: the body reaches itself through its own record. */
        Yv *dcaps = fn_captures(yr_get(node, "v"), yr_get(yr_get(st, "fns"), "ix"),
                                yr_get(node, "name"));
        if (yv_len(dcaps) == 0) {
            return st;
        } else {
            return gen_closure_binding(st, yr_get(node, "name"),
                                       yr_get(node, "v"), dcaps);
        }
    } else {
        if (yv_l(yr_get(yr_get(node, "v"), "k")) == K_func) {
            /* let-bound function. Capture-free ones stay pure labels (the
             * env already binds them, calls go direct). One that captures
             * becomes a closure record built HERE, where the captured
             * values are live, and the binding holds that record. Its own
             * name is no capture: the body reaches itself through its own
             * record. */
            Yv *caps = fn_captures(yr_get(node, "v"),
                                   yr_get(yr_get(st, "fns"), "ix"),
                                   yr_get(node, "name"));
            if (yv_len(caps) == 0) {
                return st;
            } else {
                return gen_closure_binding(st, yr_get(node, "name"),
                                           yr_get(node, "v"), caps);
            }
        } else if (yv_l(yr_get(yr_get(node, "v"), "k")) == K_arrrep) {
            /* heap array: [v; n] allocates a header {len, cap, data}.
             * Reference value like every other array: the binding holds
             * the header address. */
            Yv *t = yr_get(node, "typ");
            if (yv_l(yr_get(t, "k")) == K_tnone) {
                t = infer(st, yr_get(node, "v"));
            }
            long rsz = arr_elem_bytes(t);
            st = gen_arrrep_esz(st, yr_get(node, "v"), rsz,
                                store_elem_type(t, rsz));
            return bind_decl(st, yr_get(node, "name"), t);
        } else if (yv_l(yr_get(yr_get(node, "v"), "k")) == K_array) {
            /* Heap array literal. The DECLARED element type decides the
             * element width: `let b: [byte] = [104, 105]` packs, and the
             * literal's own elements only ever infer as long. */
            Yv *t = yr_get(node, "typ");
            if (yv_l(yr_get(t, "k")) == K_tnone) {
                t = infer(st, yr_get(node, "v"));
            }
            long asz = arr_elem_bytes(t);
            st = gen_array_esz(st, yr_get(node, "v"), asz,
                               store_elem_type(t, asz));
            return bind_decl(st, yr_get(node, "name"), t);
        } else if (yv_l(yr_get(yr_get(node, "v"), "k")) == K_rec) {
            /* record literal: heap address (first-class value, plain
             * slot). An empty literal under a map annotation is the map
             * itself (the {keys, vals, boxes} shape the map ops expect). */
            if (yv_l(yr_get(yr_get(node, "typ"), "k")) == K_tmap && yv_len(yr_get(yr_get(node, "v"), "keys")) == 0) {
                st = gen_maplit(st, yr_get(node, "v"));
            } else {
                /* created as the declared type (gen_as, gen_reclit) */
                st = gen_as(st, yr_get(node, "v"), yr_get(node, "typ"));
            }
            Yv *t = yr_get(node, "typ");
            if (yv_l(yr_get(t, "k")) == K_tnone) {
                t = infer(st, yr_get(node, "v"));
            }
            return bind_decl(st, yr_get(node, "name"), t);
        } else {
            st = gen_as(st, yr_get(node, "v"), yr_get(node, "typ"));
            /* Reference semantics: arrays and records are heap values and
             * bindings share them (no copy-on-store). Cloning here made
             * every `let x = <call returning [T]>` O(n), so threading an
             * accumulator through helpers was O(n^2) — the assembler's
             * patch loop spent 650MB on a 20KB output. The C copy's value
             * model aliases too (yv.c). */
            /* bind with annotation or inferred type */
            Yv *t = yr_get(node, "typ");
            if (yv_l(yr_get(t, "k")) == K_tnone) {
                t = infer(st, yr_get(node, "v"));
            }
            return bind_decl(st, yr_get(node, "name"), t);
        }
    }
}

/* Bind a declared name to the value in %rax: a top-level variable stores
 * to its global cell (see emit_program), any other takes a fresh slot. */
Yv *bind_decl(Yv *st, Yv *name, Yv *t) {
    Yv *ge = env_find(st, name);
    if (ys_eq_lit(yr_get(ge, "kind"), "global")) {
        st = emit_insn(st, F_MOV_R_P, R_RAX, 64, -1, -1, 1, 0, yv_l(yr_get(ge, "label")));
        return env_define(st, name, ys("global"), 0, yr_get(ge, "label"), ys(""),
                          t);
    } else if (yv_l(yr_get(t, "k")) == K_tstr && own_wanted(st, name)) {
        return bind_own(st, name, t);
    } else {
        long off = (yv_l(yr_get(st, "slots")) + 1) * -8;
        st = emit_insn(st, F_MOV_R_D, R_RAX, 64, R_RBP, -1, 1, off, -1);
        Yv *st2 =
           yr(15, "ir", yr_get(st, "ir"), "txt", yr_get(st, "txt"), "rodata", yr_get(st, "rodata"),
               "uid", yr_get(st, "uid"), "fuid", yr_get(st, "fuid"), "loc",
               yr_get(st, "loc"), "env", yr_get(st, "env"), "slots",
               yv_long(yv_l(yr_get(st, "slots")) + 1), "temp", yr_get(st, "temp"), "self_label",
               yr_get(st, "self_label"), "end_label", yr_get(st, "end_label"),
               "fns", yr_get(st, "fns"), "bodies", yr_get(st, "bodies"), "btext", yr_get(st, "btext"), "blabels", yr_get(st, "blabels"));
        st2 = env_define(st2, name, ys("local"), off, yv_long(-1), ys(""), t);
        return box_bound(st2, name);
    }
}

Yv *gen_assign(Yv *st, Yv *node) {
    Yv *e = env_find(st, yr_get(node, "name"));
    /* Reference semantics: arrays and records are heap values shared by
     * every binding that names them (no copy-on-store) — the same model
     * the C copy's value model uses (yv.c). A captured variable lives in
     * one shared heap cell (box_capture), so its store goes through the
     * cell and is visible in the capturing scope too. */
    st = gen_as(st, yr_get(node, "v"), yr_get(e, "typ"));
    if (ys_eq_lit(yr_get(e, "kind"), "capture")) {
        long idx = ys_tonum(yr_get(e, "mark"));
        st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, yv_l(yr_get(e, "off")), -1, R_RCX, 64);
        st = emit_insn(st, F_MOV_D_R, R_RCX, -1, 1, 8 * (idx + 1), -1, R_RDX, 64);
        st = emit_insn(st, F_MOV_R_0, R_RAX, 64, R_RDX, -1, 1, -1, -1);
        return st;
    } else if (ys_eq_lit(yr_get(e, "kind"), "box")) {
        st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, yv_l(yr_get(e, "off")), -1, R_RDX, 64);
        st = emit_insn(st, F_MOV_R_0, R_RAX, 64, R_RDX, -1, 1, -1, -1);
        return st;
    } else if (ys_eq_lit(yr_get(e, "kind"), "global")) {
        return emit_insn(st, F_MOV_R_P, R_RAX, 64, -1, -1, 1, 0, yv_l(yr_get(e, "label")));
    } else {
        return emit_insn(st, F_MOV_R_D, R_RAX, 64, R_RBP, -1, 1, yv_l(yr_get(e, "off")), -1);
    }
}

/* Fill n frame slots (base = lowest address) with the value in %rax. */
Yv *gen_fill(Yv *st, long base, long n) {
    if (n == 0) {
        return st;
    } else {
        Yv *r = next_loc(st);
        st = yr_get(r, "st");
        st = emit_insn(st, F_MOV_I_R, n, R_RCX, 64, 0, 0, 0, 0);
        st = emit_label(st, yv_l(yr_get(r, "label")));
        st = emit_insn(st, F_DEC_R, R_RCX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, F_MOV_R_M, R_RAX, 64, R_RBP, R_RCX, 8, base, -1);
        return emit_insn(st, F_JNZ_L, yv_l(yr_get(r, "label")), 0, 0, 0, 0, 0, 0);
    }
}

/* Heap-array fill: the header is in %rdx, the fill value in %rax. Writes
 * data[i] for i = n-1 .. 0 (data starts at header+16). */
Yv *gen_fill_heap(Yv *st, long n, long esz) {
    if (n == 0) {
        return st;
    } else {
        Yv *r = next_loc(st);
        st = yr_get(r, "st");
        st = emit_insn(st, F_MOV_R_R, R_RDX, 64, R_R10, 64, 0, 0, 0);
        st = emit_insn(st, F_MOV_R_R, R_RAX, 64, R_RDX, 64, 0, 0, 0);
        st = emit_insn(st, F_MOV_I_R, n, R_RCX, 64, 0, 0, 0, 0);
        st = emit_label(st, yv_l(yr_get(r, "label")));
        st = emit_insn(st, F_DEC_R, R_RCX, 64, 0, 0, 0, 0, 0);
        st = elem_store_rdx(st, esz, R_R10, R_RCX);
        st = emit_insn(st, F_JNZ_L, yv_l(yr_get(r, "label")), 0, 0, 0, 0, 0, 0);
        st = emit_insn(st, F_MOV_R_R, R_R10, 64, R_RDX, 64, 0, 0, 0);
        return st;
    }
}

/* [v; n] as a first-class expression: allocate a heap header
 * {len, cap, data...}, fill every slot with v, leave the address in %rax.
 * Usable anywhere (let, assign, call argument, return), not just `let`. */
Yv *gen_arrrep(Yv *st, Yv *node) {
    return gen_arrrep_esz(st, node,
                          elem_bytes(infer(st, yr_get(node, "v"))),
                          yr(1, "k", yv_long(K_tnone)));
}

/* Same, with the element width supplied by the declaration (`let b:
 * [byte; 4] = [0; 4]` — the literal's own elements infer as long), and
 * `ety` the element type the fill value converts to (store_elem_type). */
Yv *gen_arrrep_esz(Yv *st, Yv *node, long esz, Yv *ety) {
    long n = yv_l(yr_get(node, "n"));
    st = gen_as(st, yr_get(node, "v"), ety);
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_MOV_I_R, arr_alloc_size(esz, n), R_RDI, 64, 0, 0, 0, 0);
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_alloc"))), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_MOV_I_R, arr_header_size(), R_RDI, 64, 0, 0, 0, 0);
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_alloc"))), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_POP_R, R_RDX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_MOV_I_0, n, R_RAX, -1, 1, -1, -1, 0);
    st = emit_insn(st, F_MOV_I_D, n, R_RAX, -1, 1, 8, -1, 0);
    st = emit_insn(st, F_MOV_R_D, R_RDX, 64, R_RAX, -1, 1, 16, -1);
    st = emit_insn(st, F_MOV_R_R, R_RAX, 64, R_RDX, 64, 0, 0, 0);
    st = emit_insn(st, F_POP_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen_fill_heap(st, n, esz);
    return emit_insn(st, F_MOV_R_R, R_RDX, 64, R_RAX, 64, 0, 0, 0);
}

/* Radix literals (0x../0b..) reach the emitter as their source text; the
 * assembler only understands plain decimal immediates, so normalize here. */
long hexval_ch(Yv *c) {
    long o = ys_ord(c);
    long v = 0;
    if (o >= 48) {
        if (o <= 57) {
            v = o - 48;
            ;
        }
        ;
    }
    if (o >= 97) {
        if (o <= 102) {
            v = o - 87;
            ;
        }
        ;
    }
    if (o >= 65) {
        if (o <= 70) {
            v = o - 55;
            ;
        }
        ;
    }
    return v;
}

/* A numeric literal denotes a float when it has a fraction or an exponent.
 * Radix literals are checked first: 0xE1 and 0xbeef contain 'e'/'E'/'b'. */
int lit_is_float(Yv *s) {
    int radix = 0;
    if (yv_len(s) > 2) {
        Yv *p = ys_slice(s, 0, 2);
        if (ys_eq_lit(p, "0x")) {
            radix = 1;
            ;
        }
        if (ys_eq_lit(p, "0X")) {
            radix = 1;
            ;
        }
        if (ys_eq_lit(p, "0b")) {
            radix = 1;
            ;
        }
        if (ys_eq_lit(p, "0B")) {
            radix = 1;
            ;
        }
        ;
    }
    if (radix) {
        return 0;
    } else {
        int f = 0;
        if (ys_index_of(s, ys(".")) >= 0) {
            f = 1;
            ;
        }
        if (ys_index_of(s, ys("e")) >= 0) {
            f = 1;
            ;
        }
        if (ys_index_of(s, ys("E")) >= 0) {
            f = 1;
            ;
        }
        return f;
    }
}

Yv *norm_num(Yv *s) {
    long radix = 0;
    if (yv_len(s) > 2) {
        Yv *p = ys_slice(s, 0, 2);
        if (ys_eq_lit(p, "0x")) {
            radix = 16;
            ;
        }
        if (ys_eq_lit(p, "0X")) {
            radix = 16;
            ;
        }
        if (ys_eq_lit(p, "0b")) {
            radix = 2;
            ;
        }
        if (ys_eq_lit(p, "0B")) {
            radix = 2;
            ;
        }
        ;
    }
    if (radix == 0) {
        return s;
    } else {
        long v = 0;
        long i = 2;
        while (i < yv_len(s)) {
            Yv *c = ys_slice(s, i, i + 1);
            if (ys_eq_lit(c, "_")) {
                ;
            } else {
                /* Y's long arithmetic wraps: a literal with the top bit
                 * set (0xFFFF_FFFF_FFFF_FFFF is -1) is its 64 bits. In C
                 * that is unsigned arithmetic (see parse_num_go in asm.c). */
                v = (long)((unsigned long)v * (unsigned long)radix +
                           (unsigned long)hexval_ch(c));
                ;
            }
            i = i + 1;
        }
        return ys_long(v);
    }
}

/* ── float literals ────────────────────────────────────────────────────────
 *
 * A float literal's value is decided HERE, at compile time, and emitted as the
 * constant it is: its IEEE-754 bits, one `mov`. It used to be built by the
 * generated code instead -- the dotless digits as a long, then multiplied or
 * divided by a power of ten in chunks of 18 so each factor would be exact --
 * which is wrong four ways at once: a mantissa of more than 19 digits wraps,
 * one of more than 15 significant digits is already 1-2 ulp off before the
 * scaling starts, a net power of ten past 18 is rounded twice, and an exponent
 * in the thousands emitted millions of mul/div (a 19-byte source reached 402 MB
 * of compiler and a 1 MB binary; 1e10000000 killed it).
 *
 * The value is d x 10^dp with d the literal's digits. It is scaled up by 2^T
 * into an EXACT integer held in a small decimal bignum -- multiply by ten when
 * dp > 0, scale by 2^T and divide by ten when dp < 0 -- and the top 54 bits of
 * that integer are the significand and the round bit. Every step is exact and
 * every intermediate stays far inside 2^63 (a limb is 10^9, so limb x 2^32 <
 * 4.4e18). What the floor drops, and every bit shifted out below the
 * significand, is sticky; so the significand is rounded ONCE, at the end, to
 * nearest even -- which is what strtod, C's printf and Python all do.
 *
 * Checked against Python's float() on 120 000 literals (every exponent range,
 * the subnormal edges, DBL_MAX, exact ties, 30-digit mantissas, 2^53 and 2^63
 * boundaries): no mismatches. See test/y/native/t171_float_literal_rounding.y.
 *
 * The limbs are sized per literal (flit_size) rather than fixed, because the
 * loops over them are what the conversion costs: an ordinary literal needs nine
 * of them and a subnormal forty-five, out of the FLIT_LIMBS a runaway exponent
 * would need. */

#define FLIT_LIMBS 128 /* 128 limbs of 9 digits: 1152 digits */
/* (enough for the longest decimal that can still be a dyadic rational: a
 * literal sitting exactly on a rounding boundary below 2^-1000 needs 750-odd
 * digits, and the exactness of those digits is what decides the tie) */
#define FLIT_BASE 1000000000

/* The limbs a literal needs: its digits, a factor of ten per positive dp, the
 * 2^T scaling (a 2^32 is 10 digits), and room for the compare constants. */
long flit_size(long ndig, long dp, long t) {
    long g = dp;
    if (dp < 0) g = 0;
    long n = (ndig + g + (t / 32) * 10 + 24) / 9 + 2;
    if (n > FLIT_LIMBS) {
        return FLIT_LIMBS;
    } else {
        return n;
    }
}

/* acc *= m (m = 10 or 4294967296). false when it outgrows the limbs. */
int flit_dmul(Yv *a, long m, long n) {
    long carry = 0;
    long i = 0;
    while (i < n) {
        long p = yv_l(ya_get(a, i)) * m + carry;
        ya_set(a, i, yv_long(p % FLIT_BASE));
        carry = p / FLIT_BASE;
        i = i + 1;
    }
    return carry == 0;
}

/* acc /= m (m = 10 or 2), giving the remainder -- a dropped digit, or a bit. */
long flit_ddiv(Yv *a, long m, long n) {
    long rem = 0;
    long i = n - 1;
    while (i >= 0) {
        long cur = rem * FLIT_BASE + yv_l(ya_get(a, i));
        ya_set(a, i, yv_long(cur / m));
        rem = cur % m;
        i = i - 1;
    }
    return rem;
}

/* acc *= 10^9: every limb moves up one and the top one carries out. The limb
 * base is 10^9, so this is a shift, not a multiply -- and the exponent of a
 * literal is spent on exactly these steps. */
int flit_dmul_limb(Yv *a, long n) {
    long carry = 0;
    long i = 0;
    while (i < n) {
        long v = yv_l(ya_get(a, i));
        ya_set(a, i, yv_long(carry));
        carry = v;
        i = i + 1;
    }
    return carry == 0;
}

/* acc /= 10^9: the lowest limb drops out whole. What was in it is below the
 * significand, so the caller looks at it for sticky first. */
void flit_ddiv_limb(Yv *a, long n) {
    long i = 0;
    while (i < n - 1) {
        ya_set(a, i, ya_get(a, i + 1));
        i = i + 1;
    }
    ya_set(a, n - 1, yv_long(0));
}

/* a > c, both limb arrays. STRICTLY greater: equal limbs fall off the end with
 * the answer still false, which is what the name now says -- it used to claim
 * ">=" and the narrowing below believed it, which cost an exponent (and a
 * factor of two) on every literal that was an exact power of two, smallest
 * normal included. c may be more than one limb (2^62 is one, but the comparison
 * is written for any of them). */
int flit_dgt(Yv *a, Yv *c, long n) {
    long i = n - 1;
    int r = 0;
    int go = 1;
    while (i >= 0 && go) {
        if (yv_l(ya_get(a, i)) != yv_l(ya_get(c, i))) {
            r = yv_l(ya_get(a, i)) > yv_l(ya_get(c, i));
            go = 0;
        } else {
            i = i - 1;
        }
    }
    return r;
}

int flit_dlt(Yv *a, Yv *c, long n) {
    long i = n - 1;
    int r = 0;
    int go = 1;
    while (i >= 0 && go) {
        if (yv_l(ya_get(a, i)) != yv_l(ya_get(c, i))) {
            r = yv_l(ya_get(a, i)) < yv_l(ya_get(c, i));
            go = 0;
        } else {
            i = i - 1;
        }
    }
    return r;
}

int flit_dzero(Yv *a, long n) {
    long i = 0;
    int z = 1;
    while (i < n) {
        if (yv_l(ya_get(a, i)) != 0) z = 0;
        i = i + 1;
    }
    return z;
}

/* acc * 10 + one more digit (building the digits themselves). */
int flit_dpush(Yv *a, long dg, long n) {
    if (!flit_dmul(a, 10, n)) {
        return 0;
    } else {
        ya_set(a, 0, yv_long(yv_l(ya_get(a, 0)) + dg));
        return 1;
    }
}

/* A fresh copy, zero-padded to n limbs: the digits arrive with only the limbs
 * they needed, and the scale is retried with a bigger t, so they must survive
 * each attempt whole. */
Yv *flit_copy(Yv *a, long n) {
    Yv *out = yav(0);
    long i = 0;
    while (i < n) {
        if (i < yv_len(a)) {
            out = ya_push(out, yv_long(yv_l(ya_get(a, i))));
        } else {
            out = ya_push(out, yv_long(0));
        }
        i = i + 1;
    }
    return out;
}

/* The digits of d as n limbs (d fits a long). */
Yv *flit_dfrom(long d, long n) {
    Yv *a = yav(0);
    long rest = d;
    long i = 0;
    while (i < n) {
        a = ya_push(a, yv_long(rest % FLIT_BASE));
        rest = rest / FLIT_BASE;
        i = i + 1;
    }
    return a;
}

/* digits x 10^dp x 2^t, floored, as n limbs. flags[0] is set when the floor
 * dropped something -- that is the sticky -- and flags[1] when the value
 * outgrew the limbs, which means inf. */
Yv *flit_scaled(Yv *digs, long n, long dp, long t, Yv *flags) {
    Yv *a = flit_copy(digs, n);
    long j = 0;
    while (j < t / 32) {
        if (flit_dmul(a, 4294967296, n)) {
            j = j + 1;
        } else {
            ya_set(flags, 1, yv_bool(1));
            j = t / 32;
        }
    }
    /* Nine decades per pass: a limb is 10^9, so multiplying by it moves the
     * value up one limb and dividing drops the lowest limb outright (whatever
     * was in it is below the significand -- sticky). One pass per decade made
     * 1e300 cost 300 of them, and the exponent, not the digits, is what a
     * literal like that spends its time on. */
    if (dp > 0) {
        long k = dp;
        while (k >= 9) {
            if (flit_dmul_limb(a, n)) {
                k = k - 9;
            } else {
                ya_set(flags, 1, yv_bool(1));
                k = 0;
            }
        }
        while (k > 0) {
            if (flit_dmul(a, 10, n)) {
                k = k - 1;
            } else {
                ya_set(flags, 1, yv_bool(1));
                k = 0;
            }
        }
    } else {
        long k = 0 - dp;
        while (k >= 9) {
            if (yv_l(ya_get(a, 0)) != 0) ya_set(flags, 0, yv_bool(1));
            flit_ddiv_limb(a, n);
            k = k - 9;
        }
        while (k > 0) {
            if (flit_ddiv(a, 10, n) != 0) ya_set(flags, 0, yv_bool(1));
            k = k - 1;
        }
    }
    return a;
}

/* The significand, the round bit and the exponent, then ONE rounding. */
long flit_finish(Yv *digs, long ndig, long dp, int neg) {
    Yv *flags = yav(2, yv_bool(0), yv_bool(0));
    /* How big the value is, to pick the scale: D x 10^dp with D ndig digits
     * lies between 10^(ndig-1+dp) and 10^(ndig+dp), and log2(10) is 3.322, so
     * (ndig+dp)*33219/10000 puts the binary exponent within two of the truth.
     * Only the SIZE matters here -- a guess too low is caught by the loop below
     * and a guess too high costs a few passes -- so this is not where the
     * literal's value is decided. */
    long est = (ndig + dp) * 33219 / 10000;
    long t = 62 - est + 4;
    /* t must clear -dp, which is where dividing by ten stops being exact. A
     * literal that sits exactly on a rounding boundary is a dyadic rational --
     * v = (2^53+1) x 2^(e-53) -- so its decimal form is d x 10^-k with d
     * divisible by 5^k, and d x 2^t / 10^k comes out WHOLE for t >= k. Below
     * that the fractional bits a tie must not have turn into a sticky, and the
     * tie rounds up instead of to even (the scale above clears it by 13 bits on
     * its own; this makes it local instead of an argument about digits). */
    if (dp < 0 && t < -dp) t = -dp;
    if (t < 0) t = 0;
    /* whole 2^32 steps, the only way flit_scaled scales by a power of two */
    t = (t + 31) / 32 * 32;
    if (t > 1216) t = 1216;
    long n = flit_size(ndig, dp, t);
    Yv *a = flit_scaled(digs, n, dp, t, flags);
    /* p62 and p85 are rebuilt with the value below whenever the scale grows, so
     * a comparison always has n limbs on both sides. 2^62 is the largest power
     * of two a long holds (writing 2^64 wraps silently); 2^85 = 2^62 x 2^23. */
    Yv *p62 = flit_dfrom(4611686018427387904, n);
    Yv *p85 = flit_copy(p62, n);
    flit_dmul(p85, 8388608, n);
    /* The scale has to leave the scaled value above 2^85, so that narrowing it
     * to the significand 32 bits at a time cannot drop a bit of it -- the
     * narrowing stops at 2^85, and a whole pass below that could land anywhere
     * in [2^53, 2^85). One 32-bit step of growth is the most it can overshoot by.
     * 1216 is past what any subnormal needs (1074 + 85): past that a zero really
     * does mean the value is below the smallest double, and growing further would
     * only overflow the limbs and turn zero into inf. */
    while (!yv_truth(ya_get(flags, 1)) && flit_dlt(a, p85, n) && t < 1216) {
        t = t + 32;
        n = flit_size(ndig, dp, t);
        a = flit_scaled(digs, n, dp, t, flags);
        p62 = flit_dfrom(4611686018427387904, n);
        p85 = flit_copy(p62, n);
        flit_dmul(p85, 8388608, n);
    }
    if (yv_truth(ya_get(flags, 1))) {
        if (neg) {
            return (long)0xFFF0000000000000ULL;
        } else {
            return (long)0x7FF0000000000000ULL;
        }
    } else if (flit_dzero(a, n)) {
        /* below the smallest subnormal */
        if (neg) {
            return (long)0x8000000000000000ULL;
        } else {
            return 0;
        }
    } else {
        /* Narrow the scaled value to its significand, keeping every bit lost
         * below the significand.
         *
         * Scale up first if it is short: exact, and nothing has been dropped
         * yet, so it cannot lose anything. The constants are sized like the
         * value: one built at the full FLIT_LIMBS is 128 pushes per literal,
         * which is more than the rest of an ordinary literal costs. */
        Yv *p53 = flit_dfrom(9007199254740992, n);  /* 2^53 */
        Yv *p54 = flit_dfrom(18014398509481984, n); /* 2^54 */
        while (flit_dlt(a, p53, n)) {
            flit_dmul(a, 2, n);
        }
        /* Then 32 bits a pass while the value is over 2^85, which is where the
         * scale above leaves it: a whole pass there can only drop bits far
         * above the significand, so it lands in [2^53, 2^85). 1e300 is 2^997,
         * and a pass per bit wanted 935 of them -- two thirds of the whole
         * conversion. */
        long down = 0;
        while (flit_dgt(a, p85, n)) {
            if (flit_ddiv(a, 4294967296, n) != 0) ya_set(flags, 0, yv_bool(1));
            down = down + 32;
        }
        /* And then a bit at a time down to 2^54: what that leaves is the 53
         * significand bits AND the round bit above them, and everything it
         * dropped is below the round bit, so sticky is all that carries. */
        while (!flit_dlt(a, p54, n)) {
            if (flit_ddiv(a, 2, n) != 0) ya_set(flags, 0, yv_bool(1));
            down = down + 1;
        }
        /* 2^54 fits in two limbs, so the significand and the round bit are one
         * divide apart */
        long wide = yv_l(ya_get(a, 0));
        if (n > 1) wide = wide + yv_l(ya_get(a, 1)) * FLIT_BASE;
        long e = 53 + down - t; /* the value is in [2^e, 2^(e+1)) */
        /* A subnormal's significand is the value on the 2^-1074 grid: value is
         * a * 2^(down - t), so the fraction is a shifted right by t - down - 1074
         * -- which is one bit short of -e - 1022, and every subnormal literal
         * with an even significand came out halved when it was that. */
        long sh = 0;
        if (e < -1022) sh = t - down - 1074;
        long round = 0;
        long mant = 0;
        if (sh == 0) {
            /* bit 53 is the round bit and the 53 below it are the significand */
            round = wide % 2;
            mant = wide / 2;
        } else {
            /* a subnormal shifts the significand right, so the round bit moves
             * up with it and the one below it is sticky */
            if ((wide % 2) != 0) ya_set(flags, 0, yv_bool(1));
            long words = sh / 32;
            long bits = sh % 32;
            if (words > 0) {
                long rem = flit_ddiv(a, 4294967296, n);
                round = rem / 2147483648;
                if ((rem % 2147483648) != 0) ya_set(flags, 0, yv_bool(1));
            }
            if (bits > 0) {
                /* (long) on the shifts: 1 << 31 is INT_MIN in C, and the
                 * divisor would come out negative -- native.y shifts longs */
                long rem = flit_ddiv(a, (long)1 << bits, n);
                round = (rem / ((long)1 << (bits - 1))) % 2;
                if ((rem % ((long)1 << (bits - 1))) != 0) ya_set(flags, 0, yv_bool(1));
            }
            /* what is left is the fraction itself: no implicit leading bit */
            mant = yv_l(ya_get(a, 0));
            if (n > 1) mant = mant + yv_l(ya_get(a, 1)) * FLIT_BASE;
        }
        if (round != 0) {
            if (yv_truth(ya_get(flags, 0))) {
                mant = mant + 1;
            } else {
                if ((mant & 1) != 0) mant = mant + 1;
            }
        }
        long bits = 0;
        if (sh > 0) {
            /* SUBNORMAL: the significand was shifted right by sh, which lands
             * the value on 2^-1074 times a fraction with no implicit leading
             * bit, so the exponent field is zero and the bits are the fraction
             * itself. A carry out of it is the smallest normal. */
            if (mant >= 0x10000000000000LL) {
                bits = 0x10000000000000LL;
            } else {
                bits = mant;
            }
        } else {
            long e2 = e;
            if (mant >= 0x20000000000000LL) {
                mant = mant >> 1;
                e2 = e + 1;
            }
            if (e2 > 1023) {
                bits = (long)0x7FF0000000000000ULL; /* past the largest double */
            } else {
                bits = ((e2 + 1023) << 52) | (mant & 0xFFFFFFFFFFFFFLL);
            }
        }
        if (neg) {
            return (long)(bits | (unsigned long)0x8000000000000000ULL);
        } else {
            return bits;
        }
    }
}

/* Index of the 'e'/'E' that starts the exponent, or len(s) when absent. */
long flit_ebase(Yv *s) {
    long e = ys_index_of(s, ys("e"));
    if (e < 0) e = ys_index_of(s, ys("E"));
    if (e < 0) {
        return yv_len(s);
    } else {
        return e;
    }
}

/* The IEEE-754 bits a decimal float literal denotes, rounded once to nearest
 * even -- the same value strtod, C's printf and Python's float() give. */
long flit_bits(Yv *s) {
    long eb = flit_ebase(s);
    int neg = ys_eq_lit(ys_slice(s, 0, 1), "-");
    /* Two passes over the digits: one to count, one to fill. The bignum has to
     * be sized before the first digit goes in, and sizing it for the worst case
     * made every digit cost a pass over 128 limbs. ALL of the digits go in, not
     * a fixed count: keeping 18 in a long loses ~1e-18 of the value, which is
     * enough to flip a rounding that sits within 1% of its midpoint. */
    long ndig = 0;
    long nfrac = 0;
    int seen = 0;
    int past_dot = 0;
    long i = 0;
    if (ys_eq_lit(ys_slice(s, 0, 1), "-")) i = 1;
    if (ys_eq_lit(ys_slice(s, 0, 1), "+")) i = 1;
    while (i < eb) {
        Yv *c = ys_slice(s, i, i + 1);
        if (ys_eq_lit(c, ".")) {
            past_dot = 1;
        } else {
            if (past_dot) nfrac = nfrac + 1;
            if (seen || !ys_eq_lit(c, "0")) {
                seen = 1;
                ndig = ndig + 1;
            }
        }
        i = i + 1;
    }
    long n0 = flit_size(ndig, 0, 0);
    int over = n0 > FLIT_LIMBS;
    if (over) n0 = FLIT_LIMBS;
    Yv *a = yav(0);
    i = 0;
    while (i < n0) {
        a = ya_push(a, yv_long(0));
        i = i + 1;
    }
    seen = 0;
    past_dot = 0;
    i = 0;
    if (ys_eq_lit(ys_slice(s, 0, 1), "-")) i = 1;
    if (ys_eq_lit(ys_slice(s, 0, 1), "+")) i = 1;
    while (i < eb) {
        Yv *c = ys_slice(s, i, i + 1);
        if (ys_eq_lit(c, ".")) {
            past_dot = 1;
        } else {
            if (seen || !ys_eq_lit(c, "0")) {
                seen = 1;
                if (!flit_dpush(a, ys_byte_at(c, 0) - 48, n0)) over = 1;
            }
        }
        i = i + 1;
    }
    if (!seen) {
        /* 0.0, 0e999 -- zero, with the literal's sign */
        if (neg) {
            return (long)0x8000000000000000ULL;
        } else {
            return 0;
        }
    } else {
        /* the explicit exponent, clamped: a long digit run must not wrap, and
         * types.y rejects a literal whose magnitude is out of range before here */
        long ex = 0;
        int eneg = 0;
        if (eb < yv_len(s)) {
            long j = eb + 1;
            Yv *sc = ys_slice(s, j, j + 1);
            if (ys_eq_lit(sc, "-")) {
                eneg = 1;
                j = j + 1;
            }
            if (ys_eq_lit(sc, "+")) j = j + 1;
            int past = 0;
            while (j < yv_len(s)) {
                if (!past) {
                    ex = ex * 10 + (ys_byte_at(s, j) - 48);
                    if (ex > 5000) {
                        past = 1;
                        ex = 5001;
                    }
                }
                j = j + 1;
            }
            if (eneg) ex = 0 - ex;
        }
        if (over) {
            /* more digits than the limbs hold: nothing but inf or zero */
            if (ex - nfrac > 400) {
                if (neg) {
                    return (long)0xFFF0000000000000ULL;
                } else {
                    return (long)0x7FF0000000000000ULL;
                }
            } else {
                if (neg) {
                    return (long)0x8000000000000000ULL;
                } else {
                    return 0;
                }
            }
        } else {
            return flit_finish(a, ndig, ex - nfrac, neg);
        }
    }
}

/* The low 64 bits of a decimal literal, as the compiler runs it: the same wrap
 * as the runtime's tonum (rt.y, which is where an out-of-range literal becomes
 * a value), spelled out so the two agree on it rather than on whatever a C
 * library's strtoll clamps to (ys_tonum clamps: it answered
 * 9223372036854775807 where the Y twin's tonum answers 0, so the copies
 * emitted different code for the same literal). Unsigned arithmetic, because a
 * signed overflow is undefined in C where the Y arithmetic is defined to wrap.
 *
 * norm_num's output, which is decimal but can carry the sign its own radix
 * arithmetic wrapped to -- 0xFFFFFFFFFFFFFFFF comes out as "-1" -- and which
 * keeps any underscores a decimal literal may hold, so the sign is read
 * separately and anything that is not a digit is skipped. */
static long num_i64(Yv *s) {
    unsigned long long v = 0;
    size_t n = yv_len(s), i = 0;
    int neg = 0;
    while (i < n) {
        long c = (long)(unsigned char)s->u.s.p[i];
        if (c >= 48 && c <= 57) {
            v = v * 10ULL + (unsigned long long)(c - 48);
        } else if (c == 45 && i == 0) {
            neg = 1;
        }
        i = i + 1;
    }
    if (neg) { return -(long)v; }
    return (long)v;
}

Yv *gen_lit(Yv *st, Yv *node) {
    if (lit_is_float(yr_get(node, "v"))) {
        /* Float literal: its IEEE-754 bits, decided above. Floats live in %rax
         * as raw bits; only arithmetic and comparison use %xmm. */
        return emit_insn(st, F_MOV_I_R, flit_bits(yr_get(node, "v")), R_RAX, 64, 0, 0, 0, 0);
    } else {
        /* An integer literal is emitted as its VALUE, not its text: a literal
         * wider than 64 bits runs as its low 64 bits (which is what the
         * compiler has always done -- the checker accepts it and the runtime's
         * tonum wraps), and `mov $18446744073709551616` is not an instruction
         * GNU as can read, so a -S listing of such a program did not assemble
         * at all. norm_num has already turned hex and binary into decimal, so
         * an in-range literal emits exactly the text it did before. */
        return emit_insn(st, F_MOV_I_R, num_i64(norm_num(
                                          yr_get(node, "v"))), R_RAX, 64, 0, 0, 0, 0);
    }
}
Yv *gen_index(Yv *st, Yv *node) {
    /* Checker: an array expression — a plain variable or a nested place
     * (`grid[0][1]`, `rec.v[i]`); the base is evaluated once, here.
     * Bounds-trapped at runtime. Fixed arrays are heap headers now (same
     * layout as heap arrays); only the bound differs: static n for [T; N],
     * runtime len for [T]. */
    Yv *garr = yr_get(node, "arr");
    Yv *bt = infer(st, garr);
    long ixesz = arr_elem_bytes(bt);
    st = gen(st, garr);
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen(st, yr_get(node, "idx"));
    st = emit_insn(st, F_MOV_R_R, R_RAX, 64, R_RCX, 64, 0, 0, 0);
    st = emit_insn(st, F_POP_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_TEST_R_R, R_RCX, 64, R_RCX, 64, 0, 0, 0);
    st = emit_insn(st, F_JS_L, yv_l(lbl_new(ys("y_oob"))), 0, 0, 0, 0, 0, 0);
    if (yv_l(yr_get(bt, "k")) == K_tarrfix) {
        st = emit_insn(st, F_CMP_I_R, yv_l(yr_get(bt, "n")), R_RCX, 64, 0, 0, 0, 0);
        st = emit_insn(st, F_JGE_L, yv_l(lbl_new(ys("y_oob"))), 0, 0, 0, 0, 0, 0);
        return elem_load(st, ixesz, R_RAX, R_RCX, R_RAX);
    } else {
        st = emit_insn(st, F_MOV_0_R, R_RAX, -1, 1, -1, -1, R_RDX, 64);
        st = emit_insn(st, F_CMP_R_R, R_RDX, 64, R_RCX, 64, 0, 0, 0);
        st = emit_insn(st, F_JGE_L, yv_l(lbl_new(ys("y_oob"))), 0, 0, 0, 0, 0, 0);
        return elem_load(st, ixesz, R_RAX, R_RCX, R_RAX);
    }
}

/* s.f = v — in-place record field write, for any object expression: a
 * plain variable, a nested place (`a[0].f`), a chain (`x.y.f`). Records
 * are heap addresses; the field in slot i lives at addr+8i (same layout
 * the static gen_dot read uses), so the write is: value -> (rec + 8*idx).
 * The object runs first, then the value. Reference semantics: a field
 * write is observable through every binding (the C copy's value model
 * shares records the same way). */
Yv *gen_dotassign(Yv *st, Yv *node) {
    Yv *dobj = yr_get(node, "obj");
    Yv *dkey = yr_get(node, "key");
    Yv *dt = infer(st, dobj);
    long idx = rec_field_idx(dt, dkey);
    st = gen(st, dobj);
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen_as(st, yr_get(node, "v"), rec_field_type(dt, dkey));
    st = emit_insn(st, F_POP_R, R_RDX, 64, 0, 0, 0, 0, 0);
    if (yv_l(yr_get(dt, "k")) == K_tunion) {
        return gen_union_slot(st, dt, dkey, 1);
    } else {
        return emit_insn(st, F_MOV_R_D, R_RAX, 64, R_RDX, -1, 1, 8 * idx, -1);
    }
}

/* ── ++/-- and op= ──────────────────────────────────────────────────────
 * These desugar into ordinary statements before emitting: the arithmetic
 * then goes through gen_bin (whose division/modulo handle LONG_MIN and -1),
 * and a target like a[f()] is evaluated EXACTLY ONCE — the desugar binds
 * its index/base expression in a synthetic `let` first. Synthetic names
 * are `y_t<N>`: user names carry rename's `$`, and `y_` is reserved, so
 * they cannot collide with anything the program can write.
 *
 * Array forms are the in-place ones: `arr += v` becomes push (the header
 * never moves, so every alias sees the append), `arr += arr2` a push loop
 * over arr2, and `arr *= v` the prepend primitive. */

/* Synthetic AST pieces for the ++/-- and op= desugars. Node lists are
 * built with push chains over a let-bound [] — the checker rejects
 * heterogeneous array literals (see gen_str_const's note). */
/* The new value of `x op= v` / `++x` is bound under the place's type when
 * that is byte: binding it masks it (gen_as), so the value the expression
 * yields is the one stored. Any other type is left to inference. */
Yv *place_value_type(Yv *t) {
    if (yv_l(yr_get(t, "k")) == K_tbyte) {
        return t;
    } else {
        return yr(1, "k", yv_long(K_tnone));
    }
}

Yv *n_num(Yv *v, long line, long col) {
    return yr(4, "k", yv_long(K_num), "v", v, "line", yv_long(line), "col",
              yv_long(col));
}

Yv *n_id(Yv *v, long line, long col) {
    return yr(4, "k", yv_long(K_id), "v", v, "line", yv_long(line), "col",
              yv_long(col));
}

Yv *args1(Yv *a) {
    Yv *out = yav(0);
    out = ya_push(out, a);
    return out;
}

Yv *args2(Yv *a, Yv *b) {
    Yv *out = yav(0);
    out = ya_push(out, a);
    out = ya_push(out, b);
    return out;
}

Yv *n_call1(Yv *name, Yv *a0, long line, long col) {
    return yr(5, "k", yv_long(K_call), "callee", n_id(name, line, col), "args",
              args1(a0), "line", yv_long(line), "col", yv_long(col));
}

Yv *n_call2(Yv *name, Yv *a0, Yv *a1, long line, long col) {
    return yr(5, "k", yv_long(K_call), "callee", n_id(name, line, col), "args",
              args2(a0, a1), "line", yv_long(line), "col", yv_long(col));
}

Yv *block2(Yv *a, Yv *b, long ln, long cl) {
    Yv *st = yav(0);
    st = ya_push(st, a);
    st = ya_push(st, b);
    return yr(4, "k", yv_long(K_block), "stmts", st, "line", yv_long(ln), "col",
              yv_long(cl));
}

Yv *block3(Yv *a, Yv *b, Yv *c, long ln, long cl) {
    Yv *st = yav(0);
    st = ya_push(st, a);
    st = ya_push(st, b);
    st = ya_push(st, c);
    return yr(4, "k", yv_long(K_block), "stmts", st, "line", yv_long(ln), "col",
              yv_long(cl));
}

/* A statement list for block_bind (the C twin pushes; the Y twin spells it
 * out with +=). */
static Yv *arr_rest(Yv *a, Yv *b, Yv *c, Yv *d, Yv *e) {
    Yv *st = yav(0);
    st = ya_push(st, a);
    st = ya_push(st, b);
    st = ya_push(st, c);
    st = ya_push(st, d);
    st = ya_push(st, e);
    return st;
}

/* `first` (a place binding, which is a BLOCK for a nested place) then `rest`,
 * all in ONE block: the statements after it read the names the binding declares,
 * so a nested block would take their slots out of scope under them (frame slots
 * are released per block -- see gen_block_as). */
Yv *block_bind(Yv *first, Yv *rest, long ln, long cl) {
    Yv *st = yav(0);
    if (yv_l(yr_get(first, "k")) == K_block) {
        Yv *fs = yr_get(first, "stmts");
        long i = 0;
        while (i < yv_len(fs)) {
            st = ya_push(st, ya_get(fs, i));
            ;
            i = i + 1;
        }
    } else {
        st = ya_push(st, first);
        ;
    }
    long j = 0;
    while (j < yv_len(rest)) {
        st = ya_push(st, ya_get(rest, j));
        ;
        j = j + 1;
    }
    return yr(4, "k", yv_long(K_block), "stmts", st, "line", yv_long(ln), "col",
              yv_long(cl));
}

Yv *block4(Yv *a, Yv *b, Yv *c, Yv *d, long ln, long cl) {
    Yv *st = yav(0);
    st = ya_push(st, a);
    st = ya_push(st, b);
    st = ya_push(st, c);
    st = ya_push(st, d);
    return yr(4, "k", yv_long(K_block), "stmts", st, "line", yv_long(ln), "col",
              yv_long(cl));
}

Yv *block5(Yv *a, Yv *b, Yv *c, Yv *d, Yv *e, long ln, long cl) {
    Yv *st = yav(0);
    st = ya_push(st, a);
    st = ya_push(st, b);
    st = ya_push(st, c);
    st = ya_push(st, d);
    st = ya_push(st, e);
    return yr(4, "k", yv_long(K_block), "stmts", st, "line", yv_long(ln), "col",
              yv_long(cl));
}

Yv *block6(Yv *a, Yv *b, Yv *c, Yv *d, Yv *e, Yv *f, long ln, long cl) {
    Yv *st = yav(0);
    st = ya_push(st, a);
    st = ya_push(st, b);
    st = ya_push(st, c);
    st = ya_push(st, d);
    st = ya_push(st, e);
    st = ya_push(st, f);
    return yr(4, "k", yv_long(K_block), "stmts", st, "line", yv_long(ln), "col",
              yv_long(cl));
}

/* `dropped` is gen_stmt's: the desugar builds `{ bind; let v = <place>;
 * <target> = <v op e>; v }`, whose value is the place read -- the old x for
 * `x++`. As a statement nothing reads that load, and it is one instruction
 * per site (654 in ycc's own output). A statement context therefore runs the
 * block through gen_discard, whose last statement is a statement too, and
 * gen_stmt drops the local read. */
/* The frame offset of `node` when it names a plain long local that can be
   stepped or adjusted in place -- one `inc`/`dec`/`add $imm` on the slot, with
   no register and no frame slot of its own. Everything else is 0 (offsets grow
   downward from -8, so 0 is never a slot):
     - an index or field target has to evaluate its place once, which is what
       the desugar's synthetic bind is for;
     - an appendable string ("own"), a global, and a box/capture cell all need
       the desugar's path -- a string read clears its companion cell and a box
       write goes through the shared cell;
     - a byte slot must wrap at 128, which a 64-bit ALU op on the slot would
       not do (the desugar's movzbq/movb pair does). */
long inplace_slot(Yv *st, Yv *node) {
    long off = 0;
    if (yv_l(yr_get(node, "k")) == K_id) {
        Yv *id = node;
        Yv *e = env_find(st, yr_get(id, "v"));
        if (ys_eq_lit(yr_get(e, "kind"), "local") &&
            yv_l(yr_get(yr_get(e, "typ"), "k")) == K_tlong) {
            off = yv_l(yr_get(e, "off"));
            ;
        }
    }
    return off;
}

/* The immediate of an `add $imm, slot`: an integer literal the 83 /ext ib and
   81 /ext id forms can take (a signed byte, else a signed 32-bit word), and
   nothing else -- x86 has no ALU form with a memory *source*, so a computed
   right-hand side has to travel in a register. (AsmNum: asm.y's alias for
   {ok, v}.) */
Yv *int_imm(Yv *r) {
    int ok = 0;
    long v = 0;
    if (yv_l(yr_get(r, "k")) == K_num) {
        Yv *num = r;
        if (!lit_is_float(yr_get(num, "v"))) {
            long n = ys_tonum(norm_num(yr_get(num, "v")));
            if (n >= -2147483648L && n <= 2147483647L) {
                ok = 1;
                v = n;
                ;
            }
            ;
        }
        ;
    }
    return yr(2, "ok", yv_bool(ok), "v", yv_long(v));
}


Yv *gen_incdec(Yv *st, Yv *node, int dropped) {
    /* Where the target is a plain long local, all ten instructions of the
       desugar become one: `inc -8(%rbp)` where the desugar wrote a bind, a
       read, a copy in, an immediate, a copy back and a store -- and took a
       frame slot for it. See gen_incdec_desugar for the rest. */
    long slot = 0;
    if (dropped) {
        slot = inplace_slot(st, yr_get(node, "tgt"));
        ;
    }
    if (slot != 0) {
        long f = F_INC_D;
        if (ys_eq_lit(yr_get(node, "op"), "--")) {
            f = F_DEC_D;
            ;
        }
        return emit_insn(st, f, R_RBP, -1, 1, slot, -1, 0, 0);
    } else {
        return gen_incdec_desugar(st, node, dropped);
    }
}

Yv *gen_incdec_desugar(Yv *st, Yv *node, int dropped) {
    Yv *op = yr_get(node, "op");
    Yv *binop = ys("+");
    if (ys_eq_lit(op, "--")) {
        binop = ys("-");
        ;
    }
    Yv *tgt = yr_get(node, "tgt");
    long ln = yv_l(yr_get(node, "line"));
    long cl = yv_l(yr_get(node, "col"));
    Yv *one = n_num(ys("1"), ln, cl);
    Yv *r = next_uid(st);
    st = yr_get(r, "st");
    Yv *t1 = ys_cat(ys("y_t"), ys_long(yv_l(yr_get(r, "uid"))));
    /* One shape for every place: capture the base/index exactly once (a
     * no-op let for a plain variable), read the place, step it, write it
     * back. The arithmetic goes through gen_bin (LONG_MIN / -1 safe). */
    Yv *bind = gen_place_bind(tgt, t1, ln, cl);
    Yv *place = gen_place_read(tgt, t1, ln, cl);
    if (yv_b(yr_get(node, "pre"))) {
        /* ++x -> { bind; let v = x + 1; x = v; v } */
        Yv *nv = yr(6, "k", yv_long(K_bin), "op", binop, "l", place, "r", one,
                    "line", yv_long(ln), "col", yv_long(cl));
        Yv *d2 = yr(7, "k", yv_long(K_decl), "kind", ys("let"), "typ",
                    place_value_type(infer(st, tgt)), "name",
                    ys_cat(t1, ys("v")), "v", nv, "line", yv_long(ln),
                    "col", yv_long(cl));
        Yv *asg = gen_place_assign(tgt, n_id(ys_cat(t1, ys("v")), ln, cl), t1,
                                   ln, cl);
        return gen_incdec_end(st, bind, d2, asg, dropped, ln, cl);

    } else {
        /* x++ -> { bind; let v = x; x = v + 1; v } */
        Yv *d2 = yr(7, "k", yv_long(K_decl), "kind", ys("let"), "typ",
                    yr(1, "k", yv_long(K_tnone)), "name", ys_cat(t1, ys("v")), "v",
                    place, "line", yv_long(ln), "col", yv_long(cl));
        Yv *nv = yr(6, "k", yv_long(K_bin), "op", binop, "l",
                    n_id(ys_cat(t1, ys("v")), ln, cl), "r", one, "line",
                    yv_long(ln), "col", yv_long(cl));
        Yv *asg = gen_place_assign(tgt, nv, t1, ln, cl);
        return gen_incdec_end(st, bind, d2, asg, dropped, ln, cl);

    }
}

/* `{ bind; let v = ...; target = v; v }` -- both `++x` and `x++`, whose value
   is the trailing read of the temporary. As a statement that read is dead. */
Yv *gen_incdec_end(Yv *st, Yv *bind, Yv *d2, Yv *asg, int dropped, long ln,
                   long cl) {
    Yv *vid = n_id(yr_get(d2, "name"), ln, cl);
    Yv *rest = yav(0);
    rest = ya_push(rest, d2);
    rest = ya_push(rest, asg);
    rest = ya_push(rest, vid);
    if (dropped) {
        return gen_discard(st, block_bind(bind, rest, ln, cl));
    } else {
        return gen(st, block_bind(bind, rest, ln, cl));
    }
}


Yv *gen_opassign(Yv *st, Yv *node, int dropped) {
    Yv *t = infer(st, yr_get(node, "tgt"));
    if (yv_l(yr_get(t, "k")) == K_tarr ||
        yv_l(yr_get(t, "k")) == K_tarrfix) {
        return gen_opassign_arr(st, node, dropped);
    } else {
        return gen_opassign_arith(st, node, dropped);
    }
}

Yv *gen_opassign_arith(Yv *st, Yv *node, int dropped) {
    /* `x op= v` for numbers and strings -> `x = x op v`, with the target's
       index/base evaluated once through a synthetic let. The desugar is ten
       instructions and a frame slot; on a plain long local, as a statement, the
       operation is two to six and no slot at all:

         x += 2      add $2, -8(%rbp)                    (the 83 /ext ib form)
         x += e      mov -8(%rbp), %rax ; push %rax ; <e> ; mov %rax, %rcx ;
                     pop %rax ; add %rcx, %rax ; mov %rax, -8(%rbp)

       The place is read FIRST in the register form, exactly as the desugar
       orders it, so a right-hand side that writes the variable through a
       closure still sees the old value.

       The ops left to the desugar are the ones whose computation is more than
       the ALU instruction: `/` and `%` need its zero check and idiv, the
       shifts their count check, and a byte, float or non-local target a
       different instruction altogether (see inplace_slot). */
    long fr = 0;
    long fi = 0;
    long slot = 0;
    long imm = 0;
    int has_imm = 0;
    if (dropped) {
        slot = inplace_slot(st, yr_get(node, "tgt"));
        if (slot != 0) {
            Yv *op = yr_get(node, "op");
            if (ys_eq_lit(op, "+")) {
                fr = F_ADD_R_R;
                fi = F_ADD_I_D;
                ;
            } else if (ys_eq_lit(op, "-")) {
                fr = F_SUB_R_R;
                fi = F_SUB_I_D;
                ;
            } else if (ys_eq_lit(op, "*")) {
                fr = F_IMUL_R_R;
                fi = 0;
                ;
            } else if (ys_eq_lit(op, "|")) {
                fr = F_OR_R_R;
                fi = F_OR_I_D;
                ;
            } else if (ys_eq_lit(op, "&")) {
                fr = F_AND_R_R;
                fi = F_AND_I_D;
                ;
            } else if (ys_eq_lit(op, "^")) {
                fr = F_XOR_R_R;
                fi = F_XOR_I_D;
                ;
            }
            if (fi != 0) {
                Yv *im = int_imm(yr_get(node, "v"));
                if (yv_b(yr_get(im, "ok"))) {
                    has_imm = 1;
                    imm = yv_l(yr_get(im, "v"));
                    ;
                }
                ;
            }
            ;
        }
        ;
    }
    if (fr == 0) {
        return gen_opassign_desugar(st, node, dropped);
    } else if (has_imm) {
        return emit_insn(st, fi, imm, R_RBP, -1, 1, slot, -1, 0);
    } else {
        st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, slot, -1, R_RAX, 64);
        st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
        st = gen(st, yr_get(node, "v"));
        st = emit_insn(st, F_MOV_R_R, R_RAX, 64, R_RCX, 64, 0, 0, 0);
        st = emit_insn(st, F_POP_R, R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, fr, R_RCX, 64, R_RAX, 64, 0, 0, 0);
        return emit_insn(st, F_MOV_R_D, R_RAX, 64, R_RBP, -1, 1, slot, -1);
    }
}

Yv *gen_opassign_desugar(Yv *st, Yv *node, int dropped) {
    /* `x op= v` for numbers and strings -> `x = x op v`, with the target's
     * index/base evaluated once through a synthetic let. */
    Yv *tgt = yr_get(node, "tgt");
    Yv *op = yr_get(node, "op");
    long ln = yv_l(yr_get(node, "line"));
    long cl = yv_l(yr_get(node, "col"));
    Yv *r = next_uid(st);
    st = yr_get(r, "st");
    Yv *t1 = ys_cat(ys("y_t"), ys_long(yv_l(yr_get(r, "uid"))));
    Yv *bind = gen_place_bind(tgt, t1, ln, cl);
    Yv *rd = gen_place_read(tgt, t1, ln, cl);
    Yv *bin = yr(6, "k", yv_long(K_bin), "op", op, "l", rd, "r", yr_get(node, "v"),
                 "line", yv_long(ln), "col", yv_long(cl));
    Yv *d2 = yr(7, "k", yv_long(K_decl), "kind", ys("let"), "typ",
                place_value_type(infer(st, tgt)), "name", ys_cat(t1, ys("v")),
                "v", bin, "line", yv_long(ln), "col", yv_long(cl));
    Yv *asg = gen_place_assign(tgt, n_id(ys_cat(t1, ys("v")), ln, cl), t1, ln,
                               cl);
    Yv *rest = yav(0);
    rest = ya_push(rest, d2);
    rest = ya_push(rest, asg);
    rest = ya_push(rest, n_id(ys_cat(t1, ys("v")), ln, cl));
    if (dropped) {
        return gen_discard(st, block_bind(bind, rest, ln, cl));
    } else {
        return gen(st, block_bind(bind, rest, ln, cl));
    }
}


/* The place an opassign target names. `t1` is the synthetic name that
 * captured the target's index (a[i]) or base (o.f) — an id target needs
 * no capture (re-reading a variable has no side effects). Each target
 * shape gets its own arm (single-call dispatch, see normnode note). */
Yv *place_read_id(Yv *tgt, Yv *t1, long ln, long cl) {
    (void)t1; /* unused in native.y's def too */
    return n_id(yr_get(tgt, "v"), ln, cl);
}

/* The base array node for an index place: a plain variable is used
 * directly (re-reading it has no side effects); any other base expression
 * was captured in `t1 + "a"` (see place_bind_idx), so the desugared forms
 * read and write it through a plain variable and evaluate it exactly
 * once. */
Yv *place_arr(Yv *tgt, Yv *t1, long ln, long cl) {
    Yv *ba = yr_get(tgt, "arr");
    if (yv_l(yr_get(ba, "k")) == K_id) {
        return n_id(yr_get(ba, "v"), ln, cl);
    } else {
        return n_id(ys_cat(t1, ys("a")), ln, cl);
    }
}

Yv *place_read_idx(Yv *tgt, Yv *t1, long ln, long cl) {
    return yr(5, "k", yv_long(K_index), "arr", place_arr(tgt, t1, ln, cl), "idx",
              n_id(t1, ln, cl), "line", yv_long(ln), "col", yv_long(cl));
}

Yv *place_read_dot(Yv *tgt, Yv *t1, long ln, long cl) {
    return yr(5, "k", yv_long(K_dot), "obj", n_id(t1, ln, cl), "key",
              yr_get(tgt, "key"), "line", yv_long(ln), "col", yv_long(cl));
}

Yv *gen_place_read(Yv *tgt, Yv *t1, long ln, long cl) {
    if (yv_l(yr_get(tgt, "k")) == K_id) {
        return place_read_id(tgt, t1, ln, cl);
    } else if (yv_l(yr_get(tgt, "k")) == K_index) {
        return place_read_idx(tgt, t1, ln, cl);
    } else {
        return place_read_dot(tgt, t1, ln, cl);
    }
}

Yv *place_asg_id(Yv *tgt, Yv *valnode, Yv *t1, long ln, long cl) {
    (void)t1; /* unused in native.y's def too */
    return yr(5, "k", yv_long(K_assign), "name", yr_get(tgt, "v"), "v", valnode,
              "line", yv_long(ln), "col", yv_long(cl));
}

Yv *place_asg_idx(Yv *tgt, Yv *valnode, Yv *t1, long ln, long cl) {
    return yr(6, "k", yv_long(K_idxassign), "arr", place_arr(tgt, t1, ln, cl), "idx",
              n_id(t1, ln, cl), "v", valnode, "line", yv_long(ln), "col",
              yv_long(cl));
}

Yv *place_asg_dot(Yv *tgt, Yv *valnode, Yv *t1, long ln, long cl) {
    return yr(6, "k", yv_long(K_dotassign), "obj", n_id(t1, ln, cl), "key",
              yr_get(tgt, "key"), "v", valnode, "line", yv_long(ln), "col",
              yv_long(cl));
}

Yv *gen_place_assign(Yv *tgt, Yv *valnode, Yv *t1, long ln, long cl) {
    if (yv_l(yr_get(tgt, "k")) == K_id) {
        return place_asg_id(tgt, valnode, t1, ln, cl);
    } else if (yv_l(yr_get(tgt, "k")) == K_index) {
        return place_asg_idx(tgt, valnode, t1, ln, cl);
    } else {
        return place_asg_dot(tgt, valnode, t1, ln, cl);
    }
}

Yv *place_bind_id(Yv *tgt, Yv *t1, long ln, long cl) {
    (void)tgt; /* unused in native.y's def too */
    (void)t1;
    return yr(4, "k", yv_long(K_block), "stmts", yav(0), "line", yv_long(ln), "col",
              yv_long(cl));
}

Yv *place_bind_idx_id(Yv *tgt, Yv *t1, long ln, long cl) {
    return yr(7, "k", yv_long(K_decl), "kind", ys("let"), "typ",
              yr(1, "k", yv_long(K_tnone)), "name", t1, "v", yr_get(tgt, "idx"),
              "line", yv_long(ln), "col", yv_long(cl));
}

Yv *place_bind_idx_nest(Yv *tgt, Yv *t1, long ln, long cl) {
    /* nested base (`grid[0][1]`, `x.y[i]`, `f()[i]`): capture it in
     * `t1 + "a"` as well, so the place evaluates it exactly once. */
    Yv *tba = yr(7, "k", yv_long(K_decl), "kind", ys("let"), "typ",
                 yr(1, "k", yv_long(K_tnone)), "name", ys_cat(t1, ys("a")), "v",
                 yr_get(tgt, "arr"), "line", yv_long(ln), "col", yv_long(cl));
    Yv *tib = yr(7, "k", yv_long(K_decl), "kind", ys("let"), "typ",
                 yr(1, "k", yv_long(K_tnone)), "name", t1, "v",
                 yr_get(tgt, "idx"), "line", yv_long(ln), "col",
                 yv_long(cl));
    return block2(tba, tib, ln, cl);
}

Yv *place_bind_idx(Yv *tgt, Yv *t1, long ln, long cl) {
    Yv *ba = yr_get(tgt, "arr");
    if (yv_l(yr_get(ba, "k")) == K_id) {
        return place_bind_idx_id(tgt, t1, ln, cl);
    } else {
        return place_bind_idx_nest(tgt, t1, ln, cl);
    }
}

Yv *place_bind_dot(Yv *tgt, Yv *t1, long ln, long cl) {
    return yr(7, "k", yv_long(K_decl), "kind", ys("let"), "typ",
              yr(1, "k", yv_long(K_tnone)), "name", t1, "v", yr_get(tgt, "obj"),
              "line", yv_long(ln), "col", yv_long(cl));
}

/* The synthetic `let` that runs the target's index/base exactly once (a
 * no-op statement for id targets). */
Yv *gen_place_bind(Yv *tgt, Yv *t1, long ln, long cl) {
    if (yv_l(yr_get(tgt, "k")) == K_id) {
        return place_bind_id(tgt, t1, ln, cl);
    } else if (yv_l(yr_get(tgt, "k")) == K_index) {
        return place_bind_idx(tgt, t1, ln, cl);
    } else {
        return place_bind_dot(tgt, t1, ln, cl);
    }
}

/* `{ bind; target = <e>; place }` -- the array append forms' shape, whose value
   is the place read (the array, for `+=` / `*=`). As a statement that read is
   dead, unless it is a named local: reading one clears a string's companion
   cell (gen_id), which gen_stmt's local test deliberately leaves alone. */
Yv *gen_opassign_end(Yv *st, Yv *bind, Yv *asg, Yv *read, int dropped, long ln,
                     long cl) {
    Yv *rest = yav(0);
    rest = ya_push(rest, asg);
    rest = ya_push(rest, read);
    if (dropped) {
        return gen_discard(st, block_bind(bind, rest, ln, cl));
    } else {
        return gen(st, block_bind(bind, rest, ln, cl));
    }
}


Yv *gen_opassign_arr(Yv *st, Yv *node, int dropped) {
    /* In-place array forms. `*=` prepends one element. `+=` pushes one
     * element — or, when the VALUE is an array of the same element type
     * (types.arr_plus_kind "cat"), appends its elements: in bulk when the
     * element types are one (y_arr_extend), else one by one, each
     * converted (its length is captured first, so `a += a` is safe);
     * `[[T]] += [T]` pushes the [T] whole. The checker enforces matching
     * element types (types.y opassign_check). */
    Yv *tgt = yr_get(node, "tgt");
    Yv *op = yr_get(node, "op");
    Yv *v = yr_get(node, "v");
    long ln = yv_l(yr_get(node, "line"));
    long cl = yv_l(yr_get(node, "col"));
    Yv *r = next_uid(st);
    st = yr_get(r, "st");
    Yv *t1 = ys_cat(ys("y_t"), ys_long(yv_l(yr_get(r, "uid"))));
    Yv *tt = infer(st, tgt);
    Yv *mode = ys("push");
    int bulk = 0;
    if (ys_eq_lit(op, "*")) {
        mode = ys("prepend");
        ;
    } else {
        Yv *vt = infer(st, v);
        if ((yv_l(yr_get(vt, "k")) == K_tarr ||
             yv_l(yr_get(vt, "k")) == K_tarrfix) &&
            ys_eq_lit(arr_plus_kind(tt, vt), "cat")) {
            mode = ys("append");
            bulk = teq(yr_get(tt, "of"), yr_get(vt, "of"));
        }
    }
    if (ys_eq_lit(mode, "append") && bulk) {
        Yv *all = n_call2(ys("push$all"), gen_place_read(tgt, t1, ln, cl), v,
                          ln, cl);
        return gen_opassign_end(st, gen_place_bind(tgt, t1, ln, cl),
                                gen_place_assign(tgt, all, t1, ln, cl),
                                gen_place_read(tgt, t1, ln, cl), dropped, ln,
                                cl);
    } else if (ys_eq_lit(mode, "append")) {
        /* { let tv = v; let ti = 0; let tn = len(tv);
         *   while (ti < tn) { place = push(place, tv[ti]); ti = ti + 1 }
         *   place } */
        Yv *tv = yr(7, "k", yv_long(K_decl), "kind", ys("let"), "typ",
                    yr(1, "k", yv_long(K_tnone)), "name", ys_cat(t1, ys("v")), "v",
                    v, "line", yv_long(ln), "col", yv_long(cl));
        Yv *ti = yr(7, "k", yv_long(K_decl), "kind", ys("let"), "typ",
                    yr(1, "k", yv_long(K_tnone)), "name", ys_cat(t1, ys("i")), "v",
                    n_num(ys("0"), ln, cl), "line", yv_long(ln), "col",
                    yv_long(cl));
        Yv *tn = yr(7, "k", yv_long(K_decl), "kind", ys("let"), "typ",
                    yr(1, "k", yv_long(K_tnone)), "name", ys_cat(t1, ys("n")), "v",
                    n_call1(ys("len"), n_id(ys_cat(t1, ys("v")), ln, cl), ln,
                            cl),
                    "line", yv_long(ln), "col", yv_long(cl));
        Yv *elem = yr(5, "k", yv_long(K_index), "arr",
                      n_id(ys_cat(t1, ys("v")), ln, cl), "idx",
                      n_id(ys_cat(t1, ys("i")), ln, cl), "line", yv_long(ln),
                      "col", yv_long(cl));
        Yv *put = gen_place_assign(
            tgt,
            n_call2(ys("push"), gen_place_read(tgt, t1, ln, cl), elem, ln, cl),
            t1, ln, cl);
        Yv *step = yr(
            5, "k", yv_long(K_assign), "name", ys_cat(t1, ys("i")), "v",
            yr(6, "k", yv_long(K_bin), "op", ys("+"), "l",
               n_id(ys_cat(t1, ys("i")), ln, cl), "r", n_num(ys("1"), ln, cl),
               "line", yv_long(ln), "col", yv_long(cl)),
            "line", yv_long(ln), "col", yv_long(cl));
        Yv *loop = yr(
            5, "k", yv_long(K_kw_while), "cond",
            yr(6, "k", yv_long(K_bin), "op", ys("<"), "l",
               n_id(ys_cat(t1, ys("i")), ln, cl), "r",
               n_id(ys_cat(t1, ys("n")), ln, cl), "line", yv_long(ln), "col",
               yv_long(cl)),
            "body", block2(put, step, ln, cl), "line", yv_long(ln), "col",
            yv_long(cl));
        Yv *bnd = gen_place_bind(tgt, t1, ln, cl);
        Yv *rest = arr_rest(tv, ti, tn, loop, gen_place_read(tgt, t1, ln, cl));
        if (dropped) {
            return gen_discard(st, block_bind(bnd, rest, ln, cl));
        } else {
            return gen(st, block_bind(bnd, rest, ln, cl));
        }
    } else {
        Yv *fname = ys("push");
        if (ys_eq_lit(mode, "prepend")) {
            fname = ys("prepend");
            ;
        }
        Yv *call = n_call2(fname, gen_place_read(tgt, t1, ln, cl), v, ln, cl);
        return gen_opassign_end(st, gen_place_bind(tgt, t1, ln, cl),
                                gen_place_assign(tgt, call, t1, ln, cl),
                                gen_place_read(tgt, t1, ln, cl), dropped, ln,
                                cl);
    }
}

Yv *gen_idxassign(Yv *st, Yv *node) {
    /* Fixed arrays are heap headers now: one layout for both kinds.
     * Fixed uses the static bound n; heap uses the runtime len.
     * Reference semantics: `x[i] = v` writes through to the array every
     * binding shares — params included (the C copy's value model aliases
     * the same way). The base is any array expression and runs once, in
     * base/index/value order. No write-back to the base:
     * the header pointer never moves, so the store through it is already
     * visible through every binding. */
    Yv *garr = yr_get(node, "arr");
    Yv *bt = infer(st, garr);
    long iaesz = arr_elem_bytes(bt);
    st = gen(st, garr);
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen(st, yr_get(node, "idx"));
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen_as(st, yr_get(node, "v"), store_elem_type(bt, iaesz));
    st = emit_insn(st, F_POP_R, R_RCX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_POP_R, R_RDX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_TEST_R_R, R_RCX, 64, R_RCX, 64, 0, 0, 0);
    st = emit_insn(st, F_JS_L, yv_l(lbl_new(ys("y_oob"))), 0, 0, 0, 0, 0, 0);
    if (yv_l(yr_get(bt, "k")) == K_tarrfix) {
        st = emit_insn(st, F_CMP_I_R, yv_l(yr_get(bt, "n")), R_RCX, 64, 0, 0, 0, 0);
        st = emit_insn(st, F_JGE_L, yv_l(lbl_new(ys("y_oob"))), 0, 0, 0, 0, 0, 0);
        st = emit_insn(st, F_MOV_R_R, R_RDX, 64, R_R10, 64, 0, 0, 0);
        st = emit_insn(st, F_MOV_R_R, R_RAX, 64, R_RDX, 64, 0, 0, 0);
        st = elem_store_rdx(st, iaesz, R_R10, R_RCX);
        st = emit_insn(st, F_MOV_R_R, R_R10, 64, R_RDX, 64, 0, 0, 0);
        ;
    } else {
        st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, F_MOV_0_R, R_RDX, -1, 1, -1, -1, R_RAX, 64);
        st = emit_insn(st, F_CMP_R_R, R_RAX, 64, R_RCX, 64, 0, 0, 0);
        st = emit_insn(st, F_JGE_L, yv_l(lbl_new(ys("y_oob"))), 0, 0, 0, 0, 0, 0);
        st = emit_insn(st, F_POP_R, R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, F_MOV_R_R, R_RDX, 64, R_R10, 64, 0, 0, 0);
        st = emit_insn(st, F_MOV_R_R, R_RAX, 64, R_RDX, 64, 0, 0, 0);
        st = elem_store_rdx(st, iaesz, R_R10, R_RCX);
        st = emit_insn(st, F_MOV_R_R, R_R10, 64, R_RDX, 64, 0, 0, 0);
        ;
    }
    return st;
}

/* ── value formatting ───────────────────────────────────────────────────
 * A value of static type `t` sits in %rax; leave its string form in %rax.
 * The walk is unrolled at compile time (the type is static), so nested
 * arrays emit nested loops rather than needing a runtime type tag. */

/* Is this type one the walk is already inside? `path` holds the types being
 * formatted, outermost first, and a type that repeats is a recursive one
 * (04-types.tex, Type aliases: recursion through a record field). This walk is
 * unrolled at compile time, so a recursive type has no finite unrolling: the
 * compiler ran out of stack (test/y/native/t154_union_layout.y), and bounding
 * the DEPTH instead only traded that for an explosion -- the unrolling
 * multiplies with every level, and a recursive AST type took the compile over
 * the memory cap. Cutting where the type repeats costs one comparison per
 * level, formats a finite type as deep as it goes, and prints the repeated one
 * as its type, which is the text the record walk used to give every aggregate
 * field. A type that appears twice on DIFFERENT branches (a diamond) is not on
 * the path and is formatted both times, as it must be. */

/* path + t: a NEW array with t on the end (Y's `+` on arrays, which copies;
 * ya_push alone would append to the caller's list).
 * `yav(0)`, NOT `yav(yv_len(path))`: yav's arguments ARE variadic -- n of them
 * are read off the stack -- and this call passed none, so every level of a
 * nested type's walk read n words of uninitialized stack into the array (the
 * garbage prefix is harmless to the walk, which only compares identities, but
 * it doubles the array's length and, deep enough, reads off the top of the
 * stack: cycc died with a SIGSEGV on `print([[[...15 deep...]]])` where ycc
 * compiled it. */
static Yv *path_push(Yv *path, Yv *t) {
    Yv *p = yav(0);
    for (size_t i = 0; i < yv_len(path); i++) p = ya_push(p, ya_get(path, i));
    return ya_push(p, t);
}

static int type_on_path(Yv *t, Yv *path) {
    int found = 0;
    for (size_t i = 0; i < yv_len(path); i++) {
        /* the same node: a recursive alias is one shared node (teq) */
        if (ya_get(path, i) == t) found = 1;
    }
    return found;
}

Yv *gen_val_tostr_rax(Yv *st, Yv *t, Yv *path) {
    /* the walk compares the UNFOLDED type (a recursive alias and its
     * union are one node) but prints the type as the program wrote it */
    Yv *named = t;
    t = unfold(t);
    Yv *tk = yr_get(t, "k");
    if (type_on_path(t, path)) {
        return gen_str_const(st, ys_cat(ys_cat(ys("<"), tstr(named)), ys(">")));
    } else if (yv_l(tk) == K_tstr) {
        return st;
    } else if (yv_l(tk) == K_tbool) {
        st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_bool_tostr"))), 0, 0, 0, 0, 0, 0);
        return emit_insn(st, F_ADD_I_R, 8, R_RSP, 64, 0, 0, 0, 0);
    } else if (yv_l(tk) == K_tfloat) {
        st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_float_tostr"))), 0, 0, 0, 0, 0, 0);
        return emit_insn(st, F_ADD_I_R, 8, R_RSP, 64, 0, 0, 0, 0);
    } else if (yv_l(tk) == K_tarr) {
        if (yv_l(yr_get(yr_get(t, "of"), "k")) == K_tbyte) {
            /* [byte] stringifies Python-style: b'...' with escapes */
            return gen_helper1(st, ys("y_bytes_repr"));
        }
        return gen_arr_tostr_rax(st, yr_get(t, "of"), path_push(path, t));
    } else if (yv_l(tk) == K_tarrfix) {
        if (yv_l(yr_get(yr_get(t, "of"), "k")) == K_tbyte) {
            /* [byte] stringifies Python-style: b'...' with escapes */
            return gen_helper1(st, ys("y_bytes_repr"));
        }
        return gen_arr_tostr_rax(st, yr_get(t, "of"), path_push(path, t));
    } else if (yv_l(tk) == K_topt) {
        return gen_opt_str_rax(st, t, path_push(path, t));
    } else if (yv_l(tk) == K_trec) {
        return gen_rec_str_rax(st, t, lay_of(t, t), path_push(path, t));
    } else if (yv_l(tk) == K_tunion) {
        return gen_union_str_rax(st, t, path_push(path, t));
    } else if (yv_l(tk) == K_tmap) {
        return gen_map_repr_rax(st, t, path_push(path, t));
    } else {
        st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_long_tostr"))), 0, 0, 0, 0, 0, 0);
        return emit_insn(st, F_ADD_I_R, 8, R_RSP, 64, 0, 0, 0, 0);
    }
}

/* acc = acc + <the string in %rax>. */
Yv *gen_acc_cat_rax(Yv *st, long aoff) {
    st = emit_insn(st, F_MOV_R_R, R_RAX, 64, R_RDX, 64, 0, 0, 0);
    st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, aoff, -1, R_RAX, 64);
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_PUSH_R, R_RDX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_str_cat"))), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_ADD_I_R, 16, R_RSP, 64, 0, 0, 0, 0);
    return emit_insn(st, F_MOV_R_D, R_RAX, 64, R_RBP, -1, 1, aoff, -1);
}

/* The record address of a map sits in %rax; leave '{"k": v, ...}' -- the same
 * text tostring() gives it (gen_map_repr builds that loop from nodes; this one
 * walks the value in hand). A map is the {boxes, keys, vals} record
 * (gen_maplit), so its two arrays sit at 8 and 16. This arm is what
 * gen_val_tostr_rax was missing: with the long-to-string fallback there
 * instead, a map nested in an array, an option or a record printed as its heap
 * address, which differs every run. */
Yv *gen_map_repr_rax(Yv *st, Yv *t, Yv *path) {
    long moff = (yv_l(yr_get(st, "slots")) + yv_l(yr_get(st, "temp")) + 1) * -8;
    long aoff = (yv_l(yr_get(st, "slots")) + yv_l(yr_get(st, "temp")) + 2) * -8;
    long ioff = (yv_l(yr_get(st, "slots")) + yv_l(yr_get(st, "temp")) + 3) * -8;
    long koff = (yv_l(yr_get(st, "slots")) + yv_l(yr_get(st, "temp")) + 4) * -8;
    st = st_temp(st, yv_l(yr_get(st, "temp")) + 4);
    st = emit_insn(st, F_MOV_R_D, R_RAX, 64, R_RBP, -1, 1, moff, -1);
    st = gen_str_const(st, ys("{"));
    st = emit_insn(st, F_MOV_R_D, R_RAX, 64, R_RBP, -1, 1, aoff, -1);
    st = emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
    st = emit_insn(st, F_MOV_R_D, R_RAX, 64, R_RBP, -1, 1, ioff, -1);
    Yv *r1 = next_loc(st);
    st = yr_get(r1, "st");
    Yv *r2 = next_loc(st);
    st = yr_get(r2, "st");
    Yv *r3 = next_loc(st);
    st = yr_get(r3, "st");
    st = emit_label(st, yv_l(yr_get(r1, "label")));
    st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, moff, -1, R_RDX, 64);
    st = emit_insn(st, F_MOV_D_R, R_RDX, -1, 1, 8, -1, R_RDX, 64);
    st = emit_insn(st, F_MOV_0_R, R_RDX, -1, 1, -1, -1, R_RCX, 64);
    st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, ioff, -1, R_RAX, 64);
    st = emit_insn(st, F_CMP_R_R, R_RCX, 64, R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, F_JGE_L, yv_l(yr_get(r2, "label")), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_TEST_R_R, R_RAX, 64, R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, F_JZ_L, yv_l(yr_get(r3, "label")), 0, 0, 0, 0, 0, 0);
    st = gen_acc_cat_slot(st, aoff, ys(", "));
    st = emit_label(st, yv_l(yr_get(r3, "label")));
    /* the key, quoted when it is a str (map_key_repr's rule) */
    st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, moff, -1, R_RDX, 64);
    st = emit_insn(st, F_MOV_D_R, R_RDX, -1, 1, 8, -1, R_RDX, 64);
    st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, ioff, -1, R_RCX, 64);
    st = elem_load(st, elem_bytes(yr_get(t, "key")), R_RDX, R_RCX, R_RAX);
    if (yv_l(yr_get(yr_get(t, "key"), "k")) == K_tstr) {
        /* The key goes to a slot first: appending the opening quote is a call
         * that leaves its result in %rax, so a key still living there would be
         * appended twice over instead. */
        st = emit_insn(st, F_MOV_R_D, R_RAX, 64, R_RBP, -1, 1, koff, -1);
        st = gen_acc_cat_slot(st, aoff, ys("\""));
        st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, koff, -1, R_RAX, 64);
        st = gen_acc_cat_rax(st, aoff);
        st = gen_acc_cat_slot(st, aoff, ys("\""));
        ;
    } else {
        st = gen_val_tostr_rax(st, yr_get(t, "key"), path_push(path, t));
        st = gen_acc_cat_rax(st, aoff);
        ;
    }
    st = gen_acc_cat_slot(st, aoff, ys(": "));
    /* the value */
    st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, moff, -1, R_RDX, 64);
    st = emit_insn(st, F_MOV_D_R, R_RDX, -1, 1, 16, -1, R_RDX, 64);
    st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, ioff, -1, R_RCX, 64);
    st = elem_load(st, elem_bytes(yr_get(t, "of")), R_RDX, R_RCX, R_RAX);
    st = gen_val_tostr_rax(st, yr_get(t, "of"), path_push(path, t));
    st = gen_acc_cat_rax(st, aoff);
    /* the counter in place: one instruction, not a load, an inc and a store */
    st = emit_insn(st, F_INC_D, R_RBP, -1, 1, ioff, -1, 0, 0);
    st = emit_insn(st, F_JMP_L, yv_l(yr_get(r1, "label")), 0, 0, 0, 0, 0, 0);
    st = emit_label(st, yv_l(yr_get(r2, "label")));
    st = gen_acc_cat_slot(st, aoff, ys("}"));
    return emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, aoff, -1, R_RAX, 64);
}

/* Array header in %rax -> "[e0, e1, ...]" in %rax, the same form tostring()
 * gives. Slots: [src][acc][i]. */
Yv *gen_arr_tostr_rax(Yv *st, Yv *elty, Yv *path) {
    long soff = (yv_l(yr_get(st, "slots")) + yv_l(yr_get(st, "temp")) + 1) * -8;
    long aoff = (yv_l(yr_get(st, "slots")) + yv_l(yr_get(st, "temp")) + 2) * -8;
    long ioff = (yv_l(yr_get(st, "slots")) + yv_l(yr_get(st, "temp")) + 3) * -8;
    st = st_temp(st, yv_l(yr_get(st, "temp")) + 3);
    st = emit_insn(st, F_MOV_R_D, R_RAX, 64, R_RBP, -1, 1, soff, -1);
    st = gen_str_const(st, ys("["));
    st = emit_insn(st, F_MOV_R_D, R_RAX, 64, R_RBP, -1, 1, aoff, -1);
    st = emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
    st = emit_insn(st, F_MOV_R_D, R_RAX, 64, R_RBP, -1, 1, ioff, -1);
    Yv *r1 = next_loc(st);
    st = yr_get(r1, "st");
    Yv *r2 = next_loc(st);
    st = yr_get(r2, "st");
    Yv *r3 = next_loc(st);
    st = yr_get(r3, "st");
    st = emit_label(st, yv_l(yr_get(r1, "label")));
    st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, soff, -1, R_RDX, 64);
    st = emit_insn(st, F_MOV_0_R, R_RDX, -1, 1, -1, -1, R_RCX, 64);
    st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, ioff, -1, R_RAX, 64);
    st = emit_insn(st, F_CMP_R_R, R_RCX, 64, R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, F_JGE_L, yv_l(yr_get(r2, "label")), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_TEST_R_R, R_RAX, 64, R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, F_JZ_L, yv_l(yr_get(r3, "label")), 0, 0, 0, 0, 0, 0);
    st = gen_acc_cat_slot(st, aoff, ys(", "));
    st = emit_label(st, yv_l(yr_get(r3, "label")));
    st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, soff, -1, R_RDX, 64);
    st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, ioff, -1, R_RCX, 64);
    st = elem_load(st, elem_bytes(elty), R_RDX, R_RCX, R_RAX);
    st = gen_val_tostr_rax(st, elty, path);
    st = emit_insn(st, F_MOV_R_R, R_RAX, 64, R_RDX, 64, 0, 0, 0);
    st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, aoff, -1, R_RAX, 64);
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_PUSH_R, R_RDX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_str_cat"))), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_ADD_I_R, 16, R_RSP, 64, 0, 0, 0, 0);
    st = emit_insn(st, F_MOV_R_D, R_RAX, 64, R_RBP, -1, 1, aoff, -1);
    /* the counter in place: one instruction, not a load, an inc and a store */
    st = emit_insn(st, F_INC_D, R_RBP, -1, 1, ioff, -1, 0, 0);
    st = emit_insn(st, F_JMP_L, yv_l(yr_get(r1, "label")), 0, 0, 0, 0, 0, 0);
    st = emit_label(st, yv_l(yr_get(r2, "label")));
    st = gen_acc_cat_slot(st, aoff, ys("]"));
    return emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, aoff, -1, R_RAX, 64);
}

/* slot(%rbp) = slot(%rbp) + <constant>. */
Yv *gen_acc_cat_slot(Yv *st, long off, Yv *s) {
    st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, off, -1, R_RAX, 64);
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen_str_const(st, s);
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_str_cat"))), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_ADD_I_R, 16, R_RSP, 64, 0, 0, 0, 0);
    return emit_insn(st, F_MOV_R_D, R_RAX, 64, R_RBP, -1, 1, off, -1);
}

/* ── element size ───────────────────────────────────────────────────────
 * Byte arrays are PACKED: one byte per element, not eight. Every element
 * lives at base + 16 + i*esz, so the scale factor, the allocation size and
 * the load/store width all follow from the element type. Everything else
 * stays 8 bytes (one machine word per value). */

long elem_bytes(Yv *t) {
    if (yv_l(yr_get(t, "k")) == K_tbyte) {
        return 1;
    } else {
        return 8;
    }
}

long arr_elem_bytes(Yv *t) {
    if (yv_l(yr_get(t, "k")) == K_tarr) {
        return elem_bytes(yr_get(t, "of"));
    } else if (yv_l(yr_get(t, "k")) == K_tarrfix) {
        return elem_bytes(yr_get(t, "of"));
    } else {
        return 8;
    }
}

/* Width of what a pointer of static type `t` addresses: a *byte points into
 * a packed [byte] block (or at a byte local), so `*p` and `*p = v` move one
 * byte; every other pointee is a full 8-byte slot. */
long ptr_width(Yv *t) {
    if (yv_l(yr_get(t, "k")) == K_tptr) {
        return elem_bytes(yr_get(t, "to"));
    } else {
        return 8;
    }
}

/* Load element [idx] into `dst`. `base` is the ARRAY HEADER register, `idx`
 * the index register, `dst` the result. Headers are {len, cap, data} with
 * the elements in a separate block, so the data pointer rides through %dst. */
Yv *elem_load(Yv *st, long esz, long base, long idx, long dst) {
    st = emit_insn(st, F_MOV_D_R, base, -1, 1, 16, -1, dst, 64);
    if (esz == 1) {
        return emit_insn(st, F_MOVZBQ_M_R, dst, idx, 1, 0, -1, dst, 64);
    } else {
        return emit_insn(st, F_MOV_M_R, dst, idx, 8, 0, -1, dst, 64);
    }
}

/* Store %rdx into element [idx] of the array based at `base`. The value
 * always arrives in %rdx so the byte form can name %dl without a register
 * table; a packed store truncates to 8 bits, which is the narrowing.
 * %r11 is the scratch that carries the data pointer: no generated value
 * lives in it across a store (the syscall instruction clobbers it). */
Yv *elem_store_rdx(Yv *st, long esz, long base, long idx) {
    st = emit_insn(st, F_MOV_D_R, base, -1, 1, 16, -1, R_R11, 64);
    if (esz == 1) {
        return emit_insn(st, F_MOVB_R_M, R_RDX, 8, R_R11, idx, 1, 0, -1);
    } else {
        return emit_insn(st, F_MOV_R_M, R_RDX, 64, R_R11, idx, 8, 0, -1);
    }
}

/* Same, for a compile-time-constant index (array literals): fold the
 * offset into the displacement instead of using an index register. */
Yv *elem_store_rdx_const(Yv *st, long esz, long base, long k) {
    st = emit_insn(st, F_MOV_D_R, base, -1, 1, 16, -1, R_R11, 64);
    if (esz == 1) {
        return emit_insn(st, F_MOVB_R_D, R_RDX, 8, R_R11, -1, 1, k, -1);
    } else {
        return emit_insn(st, F_MOV_R_D, R_RDX, 64, R_R11, -1, 1, k * 8, -1);
    }
}

/* The array header is {len, cap, data, front} and NEVER moves: elements
 * live in a separate block, so growth keeps every alias valid (that is
 * what makes `arr += v` in-place). front, the free slots before data, is
 * the header's fourth word: y_alloc(arr_header_size()) hands out 32
 * zeroed bytes (NATIVE.md). This is the block size for n elements. */
long arr_alloc_size(long esz, long n) {
    long b = n * esz;
    if (b < 8) {
        return 8;
    } else {
        return b;
    }
}

/* Bytes to allocate for the header itself. */
long arr_header_size(void) { return 24; }

Yv *gen_dot(Yv *st, Yv *node) {
    /* dobj is read twice (infer, then gen). */
    Yv *dobj = yr_get(node, "obj");
    Yv *dkey = yr_get(node, "key");
    if (yv_l(yr_get(dobj, "k")) == K_narrow) {
        Yv *s = infer(st, yr_get(dobj, "e"));
        if (yv_l(yr_get(s, "k")) == K_tunion) {
            return gen_narrow_field(st, dobj, s, dkey);
        }
    }
    Yv *t = infer(st, dobj);
    Yv *tk = yr_get(t, "k");
    if (yv_l(tk) == K_tarr || yv_l(tk) == K_tarrfix ||
        yv_l(tk) == K_tstr) {
        return gen_prop(st, dobj, dkey, yv_l(yr_get(node, "line")),
                        yv_l(yr_get(node, "col")));
    } else if (yv_l(tk) == K_tunion) {
        st = gen(st, dobj);
        return gen_union_slot(st, t, dkey, 0);
    } else {
        return gen_dot_rec(st, dobj, dkey, t);
    }
}

/* Field `dkey` of a union value (types.y union_field: every member has
 * it, with one type): read into %rax from the record in %rax, or (store)
 * %rax written to the record in %rdx. A field every member shares sits at
 * one slot in every member held in the union (union_lay): one move. */
Yv *gen_union_slot(Yv *st, Yv *t, Yv *dkey, int store) {
    return gen_slot_move(st, mfield_idx(union_shared(unfold(t)), dkey), store);
}

/* A match pattern's field read (`T {f}`, `{f: v}`; parser.y: a dot on a
 * narrow of the subject, a union s): field `dkey` read in place, at its
 * slot in s's layout of each member the arm's test accepts -- the narrowed
 * record (a copy where the layouts differ, gen_convert) is never made. One
 * move when the field has one slot in every such member; else a compare
 * of the descriptor per member, a move per slot. */
Yv *gen_narrow_field(Yv *st, Yv *nar, Yv *s, Yv *dkey) {
    Yv *ms = rectest_members(s, yr_get(nar, "typ"));
    Yv *slots = yav(0);
    Yv *ds = yav(0);
    for (long i = 0; i < yv_len(ms); i++) {
        long sl = mfield_idx(union_lay(unfold(ya_get(ms, i)), s), dkey);
        slots = ya_push(slots, yv_long(sl));
        int seen = 0;
        for (long q = 0; q < yv_len(ds); q++) {
            if (yv_l(ya_get(ds, q)) == sl) {
                seen = 1;
            }
        }
        if (!seen) {
            ds = ya_push(ds, yv_long(sl));
        }
    }
    st = gen(st, yr_get(nar, "e"));
    if (yv_len(ds) == 0) {
        /* no member matches: the arm never runs */
        return emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
    } else if (yv_len(ds) == 1) {
        return gen_slot_move(st, yv_l(ya_get(ds, 0)), 0);
    } else {
        Yv *done = next_loc(st);
        st = yr_get(done, "st");
        st = emit_insn(st, F_MOV_D_R, R_RAX, -1, 1, -8, -1, R_RCX, 64);
        Yv *lbls = yav(0);
        long d = 0;
        while (d < yv_len(ds) - 1) {
            Yv *l = next_loc(st);
            st = yr_get(l, "st");
            lbls = ya_push(lbls, yr_get(l, "label"));
            long j = 0;
            while (j < yv_len(ms)) {
                if (yv_l(ya_get(slots, j)) == yv_l(ya_get(ds, d))) {
                    Yv *dr = ty_desc_in(st, ya_get(ms, j), s);
                    st = yr_get(dr, "st");
                    st = emit_insn(st, F_LEA_P_R, -1, -1, 1, 0, yv_l(yr_get(dr, "label")), R_RSI, 64);
                    st = emit_insn(st, F_CMP_R_R, R_RSI, 64, R_RCX, 64, 0, 0, 0);
                    st = emit_insn(st, F_JE_L, yv_l(yr_get(l, "label")), 0, 0, 0, 0, 0, 0);
                }
                j = j + 1;
            }
            d = d + 1;
        }
        st = gen_slot_move(st, yv_l(ya_get(ds, yv_len(ds) - 1)), 0);
        st = emit_insn(st, F_JMP_L, yv_l(yr_get(done, "label")), 0, 0, 0, 0, 0, 0);
        long e = 0;
        while (e < yv_len(lbls)) {
            st = emit_label(st, yv_l(ya_get(lbls, e)));
            st = gen_slot_move(st, yv_l(ya_get(ds, e)), 0);
            /* not on the last arm: that one falls through into `done:` */
            if (e < yv_len(lbls) - 1) {
                st = emit_insn(st, F_JMP_L, yv_l(yr_get(done, "label")), 0, 0, 0, 0, 0, 0);
                ;
            }
            e = e + 1;
        }
        return emit_label(st, yv_l(yr_get(done, "label")));
    }
}

/* gen_union_slot's move: slot sl of the record in %rax into %rax, or
 * (store) %rax into slot sl of the record in %rdx. */
Yv *gen_slot_move(Yv *st, long sl, int store) {
    if (store) {
        return emit_insn(st, F_MOV_R_D, R_RAX, 64, R_RDX, -1, 1, 8 * sl, -1);
    } else {
        return emit_insn(st, F_MOV_D_R, R_RAX, -1, 1, 8 * sl, -1, R_RAX, 64);
    }
}

/* Built-in properties (types.y typeof_prop): `.length` is len(x); `.ptr`
 * is the array header's data word -- the element block's address. */
Yv *gen_prop(Yv *st, Yv *obj, Yv *key, long line, long col) {
    if (ys_eq_lit(key, "length")) {
        return gen_len(st, n_call1(ys("len"), obj, line, col));
    } else {
        st = gen(st, obj);
        return emit_insn(st, F_MOV_D_R, R_RAX, -1, 1, 16, -1, R_RAX, 64);
    }
}

/* Record field read; `t` is the record's static type. */
Yv *gen_dot_rec(Yv *st, Yv *dobj, Yv *dkey, Yv *t) {
    long idx = rec_field_idx(t, dkey);
    st = gen(st, dobj);
    return emit_insn(st, F_MOV_D_R, R_RAX, -1, 1, idx * 8, -1, R_RAX, 64);
}

/* The slot of field `key` in a record of static type t (fields sorted by
 * name, see "records at run time"); -1 when t has no such field (the
 * checker rejects such a read). */
long rec_field_idx(Yv *t, Yv *key) {
    long idx = -1;
    if (yv_l(yr_get(t, "k")) == K_trec) {
        Yv *fs = yr_get(t, "fields");
        idx = rec_slot(fs, key);
        ;
    } else if (yv_l(yr_get(t, "k")) == K_tmap) {
        /* a map is lowered to the {keys, vals, boxes} record (see
         * gen_maplit), laid out boxes, keys, vals */
        if (ys_eq_lit(key, "boxes")) { idx = 0; ; } else if (ys_eq_lit(key, "keys")) { idx = 1; ; } else if (ys_eq_lit(key, "vals")) { idx = 2; ; }
    }
    return idx;
}

/* Static type of field `key` in trec type t (tnone when there is none). */
Yv *rec_field_type(Yv *t, Yv *key) {
    Yv *ft = yr(1, "k", yv_long(K_tnone));
    if (yv_l(yr_get(t, "k")) == K_tunion) {
        Yv *ms = members(t);
        if (yv_len(ms) > 0) {
            ft = rec_field_type(ya_get(ms, 0), key);
        }
        ;
    } else if (yv_l(yr_get(t, "k")) == K_trec) {
        Yv *fs = yr_get(t, "fields");
        long i = 0;
        while (i < yv_len(fs)) {
            Yv *f = ya_get(fs, i);
            if (ys_eq(yr_get(f, "name"), key)) {
                ft = yr_get(f, "typ");
                ;
            }
            i = i + 1;
        }
        ;
    }
    return ft;
}

/* Heap array literal [v, ...]: a data block of arr_alloc_size(esz, n) and a
 * separate arr_header_size() header {len, cap, data}; the values are stored
 * into the data block through the header's pointer. The header address (an
 * 8-byte value like any other) is the expression value. */
Yv *gen_array(Yv *st, Yv *node) {
    Yv *at = infer(st, node);
    long gsz = arr_elem_bytes(at);
    return gen_array_esz(st, node, gsz, store_elem_type(at, gsz));
}

/* Same, with the element width supplied by the declaration (`let b:
 * [byte] = [104, 105]` — the literal's own elements infer as long), and
 * `ety` the element type each value converts to (store_elem_type). */
Yv *gen_array_esz(Yv *st, Yv *node, long esz, Yv *ety) {
    Yv *elems = yr_get(node, "elems");
    long gi = 0;
    while (gi < yv_len(elems)) {
        st = gen_as(st, ya_get(elems, gi), ety);
        st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
        gi = gi + 1;
    }
    long n = yv_len(elems);
    st = emit_insn(st, F_MOV_I_R, arr_alloc_size(esz, n), R_RDI, 64, 0, 0, 0, 0);
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_alloc"))), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_MOV_I_R, arr_header_size(), R_RDI, 64, 0, 0, 0, 0);
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_alloc"))), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_MOV_R_R, R_RAX, 64, R_R10, 64, 0, 0, 0);
    st = emit_insn(st, F_POP_R, R_RDX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_MOV_I_0, n, R_R10, -1, 1, -1, -1, 0);
    st = emit_insn(st, F_MOV_I_D, n, R_R10, -1, 1, 8, -1, 0);
    st = emit_insn(st, F_MOV_R_D, R_RDX, 64, R_R10, -1, 1, 16, -1);
    long k = n - 1;
    while (k >= 0) {
        st = emit_insn(st, F_POP_R, R_RDX, 64, 0, 0, 0, 0, 0);
        st = elem_store_rdx_const(st, esz, R_R10, k);
        k = k - 1;
    }
    return emit_insn(st, F_MOV_R_R, R_R10, 64, R_RAX, 64, 0, 0, 0);
}

Yv *gen_len(Yv *st, Yv *node) {
    /* Checker: single array or string argument. Fixed size is immediate
     * (from the inferred type itself); heap length (array header or string
     * header) loads from address+0. NOTE: the argument is any array-typed
     * expression (id, dot like `a.args`, call result) — never assume a
     * plain id (no `.v` reads here); infer gives the static type. */
    Yv *args = yr_get(node, "args");
    Yv *at = infer(st, ya_get(args, 0));
    if (yv_l(yr_get(at, "k")) == K_tmap) {
        /* len(m) = len(m.keys): the entry count */
        return gen(st, n_call1(ys("len"), n_dot(ya_get(args, 0), ys("keys"), yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col"))), yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col"))));
    } else if (yv_l(yr_get(at, "k")) == K_tstr) {
        st = gen(st, ya_get(args, 0));
        return emit_insn(st, F_MOV_0_R, R_RAX, -1, 1, -1, -1, R_RAX, 64);
    } else {
        st = gen(st, ya_get(args, 0));
        return emit_insn(st, F_MOV_0_R, R_RAX, -1, 1, -1, -1, R_RAX, 64);
    }
}

/* push(arr, v): Y calling convention straight into the prelude helper.
 * Returns the (possibly reallocated) header — rebind it: `a = push(a, v)`. */
Yv *gen_push(Yv *st, Yv *node) {
    Yv *pargs = yr_get(node, "args");
    Yv *pat = infer(st, ya_get(pargs, 0));
    long pesz = arr_elem_bytes(pat);
    st = gen_push_args_as(st, yr_get(node, "args"),
                          args2(yr(1, "k", yv_long(K_tnone)),
                                store_elem_type(pat, pesz)));
    st = emit_insn(st, F_MOV_I_R, pesz, R_RAX, 64, 0, 0, 0, 0);
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_arr_push"))), 0, 0, 0, 0, 0, 0);
    long nbytes = yv_len(yr_get(node, "args")) * 8 + 8;
    return emit_insn(st, F_ADD_I_R, nbytes, R_RSP, 64, 0, 0, 0, 0);
}

/* `arr += other` with one element type (gen_opassign_arr makes the call,
 * a name no program can write): y_arr_extend appends other's elements in
 * bulk. */
Yv *gen_push_all(Yv *st, Yv *node) {
    Yv *pargs = yr_get(node, "args");
    long pesz = arr_elem_bytes(infer(st, ya_get(pargs, 0)));
    st = gen_push_args_as(st, yr_get(node, "args"), yav(0));
    st = emit_insn(st, F_MOV_I_R, pesz, R_RAX, 64, 0, 0, 0, 0);
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_arr_extend"))), 0, 0, 0, 0, 0, 0);
    return emit_insn(st, F_ADD_I_R, 24, R_RSP, 64, 0, 0, 0, 0);
}

/* The payload of a `?.` chain, back in an option box (parser.y). A payload
   that is already an option IS its box, so nothing to do; a void chain has
   nothing to hand back. Otherwise some(v). */
Yv *gen_opt_val(Yv *st, Yv *node) {
    Yv *args = yr_get(node, "args");
    Yv *at = infer(st, ya_get(args, 0));
    long ak = yv_l(yr_get(at, "k"));
    if (ak == K_topt || ak == K_tvoid) {
        return gen(st, ya_get(args, 0));
    } else {
        return gen_some(st, node);
    }
}
Yv *gen_some(Yv *st, Yv *node) {
    Yv *args = yr_get(node, "args");
    st = gen(st, ya_get(args, 0));
    return gen_box_rax(st);
}

/* The value in %rax boxed: some(v), the box in %rax. */
Yv *gen_box_rax(Yv *st) {
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_MOV_I_R, 8, R_RDI, 64, 0, 0, 0, 0);
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_alloc"))), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_POP_R, R_RCX, 64, 0, 0, 0, 0, 0);
    return emit_insn(st, F_MOV_R_0, R_RCX, 64, R_RAX, -1, 1, -1, -1);
}

Yv *gen_is_some(Yv *st, Yv *node) {
    Yv *args = yr_get(node, "args");
    if (is_map_read(st, ya_get(args, 0))) {
        /* is_some(m[k]): the key scan decides, nothing is boxed */
        return gen_map_get(st, ya_get(args, 0), ys("has"));
    } else {
        st = gen(st, ya_get(args, 0));
        st = emit_insn(st, F_TEST_R_R, R_RAX, 64, R_RAX, 64, 0, 0, 0);
        st = emit_insn(st, F_SETNE_R, R_RAX, 8, 0, 0, 0, 0, 0);
        return emit_insn(st, F_MOVZBQ_R_R, R_RAX, 8, R_RAX, 64, 0, 0, 0);
    }
}

Yv *gen_unwrap(Yv *st, Yv *node) {
    Yv *args = yr_get(node, "args");
    if (is_map_read(st, ya_get(args, 0))) {
        /* m[k]!: the entry's value itself, nothing is boxed */
        return gen_map_get(st, ya_get(args, 0), ys("val"));
    } else {
        st = gen(st, ya_get(args, 0));
        st = emit_insn(st, F_TEST_R_R, R_RAX, 64, R_RAX, 64, 0, 0, 0);
        st = emit_insn(st, F_JZ_L, yv_l(lbl_new(ys("y_opt_unwrap"))), 0, 0, 0, 0, 0, 0);
        return emit_insn(st, F_MOV_0_R, R_RAX, -1, 1, -1, -1, R_RAX, 64);
    }
}

/* ── string builtins (all on {len, data} header objects) ────────────────
 * Every helper takes header addresses via the Y calling convention
 * (args pushed left-to-right, first arg deepest) and returns a header
 * address (or long) in %rax. Caller cleans the stack. */

Yv *gen_trim(Yv *st, Yv *node) {
    st = gen_push_args(st, yr_get(node, "args"));
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_str_trim"))), 0, 0, 0, 0, 0, 0);
    return emit_insn(st, F_ADD_I_R, 8, R_RSP, 64, 0, 0, 0, 0);
}

/* prepend(arr, v) -> arr: in-place insert at the front (the header never
 * moves, so every alias sees it). The `*=` operator desugars to this. */
Yv *gen_prepend(Yv *st, Yv *node) {
    Yv *pargs = yr_get(node, "args");
    Yv *pat = infer(st, ya_get(pargs, 0));
    long pesz = arr_elem_bytes(pat);
    st = gen_push_args_as(st, yr_get(node, "args"),
                          args2(yr(1, "k", yv_long(K_tnone)),
                                store_elem_type(pat, pesz)));
    st = emit_insn(st, F_MOV_I_R, pesz, R_RAX, 64, 0, 0, 0, 0);
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_arr_prepend"))), 0, 0, 0, 0, 0, 0);
    long nbytes = yv_len(yr_get(node, "args")) * 8 + 8;
    return emit_insn(st, F_ADD_I_R, nbytes, R_RSP, 64, 0, 0, 0, 0);
}

/* byte_at(s, i): byte i of string s, trapped when out of bounds. This is
 * the primitive every string helper is built on — reading one byte must
 * not copy the string the way bytes() does. Inline, four instructions,
 * because scanning loops call it per character. */
Yv *gen_byte_at(Yv *st, Yv *node) {
    Yv *args = yr_get(node, "args");
    st = gen(st, ya_get(args, 0));
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen(st, ya_get(args, 1));
    st = emit_insn(st, F_POP_R, R_RCX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_MOV_0_R, R_RCX, -1, 1, -1, -1, R_RDX, 64);
    st = emit_insn(st, F_TEST_R_R, R_RAX, 64, R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, F_JS_L, yv_l(lbl_new(ys("y_oob"))), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_CMP_R_R, R_RDX, 64, R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, F_JGE_L, yv_l(lbl_new(ys("y_oob"))), 0, 0, 0, 0, 0, 0);
    return emit_insn(st, F_MOVZBQ_M_R, R_RCX, R_RAX, 1, 8, -1, R_RAX, 64);
}

Yv *gen_ord(Yv *st, Yv *node) {
    st = gen_push_args(st, yr_get(node, "args"));
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_str_ord"))), 0, 0, 0, 0, 0, 0);
    return emit_insn(st, F_ADD_I_R, 8, R_RSP, 64, 0, 0, 0, 0);
}

Yv *gen_chr(Yv *st, Yv *node) {
    st = gen_push_args(st, yr_get(node, "args"));
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_str_chr"))), 0, 0, 0, 0, 0, 0);
    return emit_insn(st, F_ADD_I_R, 8, R_RSP, 64, 0, 0, 0, 0);
}

Yv *gen_tonum(Yv *st, Yv *node) {
    st = gen_push_args(st, yr_get(node, "args"));
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_str_tonum"))), 0, 0, 0, 0, 0, 0);
    return emit_insn(st, F_ADD_I_R, 8, R_RSP, 64, 0, 0, 0, 0);
}

Yv *gen_tostring(Yv *st, Yv *node) {
    /* dispatch on the static type: long/bool need conversion, str is
     * identity */
    Yv *targs = yr_get(node, "args");
    Yv *a0 = ya_get(targs, 0);
    Yv *t = infer(st, a0);
    if (yv_l(yr_get(t, "k")) == K_tstr) {
        return gen(st, a0);
    } else if (yv_l(yr_get(t, "k")) == K_tbool) {
        st = gen_push_args(st, yr_get(node, "args"));
        st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_bool_tostr"))), 0, 0, 0, 0, 0, 0);
        return emit_insn(st, F_ADD_I_R, 8, R_RSP, 64, 0, 0, 0, 0);
    } else if (yv_l(yr_get(t, "k")) == K_tfloat) {
        st = gen_push_args(st, yr_get(node, "args"));
        st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_float_tostr"))), 0, 0, 0, 0, 0, 0);
        return emit_insn(st, F_ADD_I_R, 8, R_RSP, 64, 0, 0, 0, 0);
    } else if (yv_l(yr_get(t, "k")) == K_tarr) {
        st = gen(st, a0);
        if (yv_l(yr_get(yr_get(t, "of"), "k")) == K_tbyte) {
            /* [byte] stringifies Python-style: b'...' with escapes */
            return gen_helper1(st, ys("y_bytes_repr"));
        }
        return gen_arr_tostr_rax(st, yr_get(t, "of"), yav(0));
    } else if (yv_l(yr_get(t, "k")) == K_tarrfix) {
        st = gen(st, a0);
        if (yv_l(yr_get(yr_get(t, "of"), "k")) == K_tbyte) {
            /* [byte] stringifies Python-style: b'...' with escapes */
            return gen_helper1(st, ys("y_bytes_repr"));
        }
        return gen_arr_tostr_rax(st, yr_get(t, "of"), yav(0));
    } else if (yv_l(yr_get(t, "k")) == K_topt) {
        st = gen(st, a0);
        return gen_opt_str_rax(st, t, yav(0));
    } else if (yv_l(yr_get(t, "k")) == K_trec) {
        st = gen(st, a0);
        return gen_rec_str_rax(st, t, lay_of(t, t), yav(0));
    } else if (yv_l(yr_get(t, "k")) == K_tunion) {
        st = gen(st, a0);
        return gen_union_str_rax(st, t, yav(0));
    } else if (yv_l(yr_get(t, "k")) == K_tmap) {
        return gen_map_repr(st, a0, t);
    } else {
        st = gen_push_args(st, yr_get(node, "args"));
        st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_long_tostr"))), 0, 0, 0, 0, 0, 0);
        return emit_insn(st, F_ADD_I_R, 8, R_RSP, 64, 0, 0, 0, 0);
    }
}

/* An f-string field, #fmt(e, "spec") (lexer.y lex_fstring, checked by
 * types.y typeof_fmt). Without a spec it is tostring(e). With one, e goes
 * to a std/str.y helper with the spec read here, packed into one number
 * (fmt_code), and its width and precision: y_fmt_i for d x X o b c,
 * y_fmt_f for f F e E % (a long converted first, and a `%` multiplied by
 * 100 in floating point, as Python does it), y_fmt_s for the rest -- a
 * str, or the tostring of anything else. */
Yv *gen_fmt(Yv *st, Yv *node) {
    Yv *fargs = yr_get(node, "args");
    Yv *a0 = ya_get(fargs, 0);
    /* As in types.y's typeof_fmt: a spec argument that is an err node has
     * no spec to read. The checker rejects the program before here, so this
     * only keeps the emitter from casting a member it does not hold. */
    Yv *sp = leaf_of(ya_get(fargs, 1));
    Yv *spec = yv_is_none(sp) ? ys("") : yr_get(sp, "v");
    Yv *ts = n_call1(ys("tostring"), a0,
                     yv_l(yr_get(node, "line")),
                     yv_l(yr_get(node, "col")));
    if (ys_eq_lit(spec, "")) {
        return gen_tostring(st, ts);
    } else {
        Yv *t = infer(st, a0);
        Yv *f = fmt_spec(spec);
        long kind = fmt_kind(t);
        long ty = yv_l(yr_get(f, "ty"));
        if (ty == 0) {
            if (kind == 1) { ty = 100; ; }
            else if (kind == 2) { ty = 102; ; }
            else { ty = 115; ; }
            ;
        }
        long code = fmt_code(f, kind, ty);
        if (ty == 115) {
            st = gen_tostring(st, ts);
            st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
            st = fmt_push(st, code);
            st = fmt_push(st, yv_l(yr_get(f, "width")));
            st = fmt_push(st, yv_l(yr_get(f, "prec")));
            st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_fmt_s"))), 0, 0, 0, 0, 0, 0);
            return emit_insn(st, F_ADD_I_R, 32, R_RSP, 64, 0, 0, 0, 0);
        } else if (ty == 100 || ty == 120 || ty == 88 ||
                   ty == 111 || ty == 98 || ty == 99) {
            st = gen(st, a0);
            st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
            st = fmt_push(st, code);
            st = fmt_push(st, yv_l(yr_get(f, "width")));
            st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_fmt_i"))), 0, 0, 0, 0, 0, 0);
            return emit_insn(st, F_ADD_I_R, 24, R_RSP, 64, 0, 0, 0, 0);
        } else {
            st = gen(st, a0);
            if (kind == 1) {
                st = emit_insn(st, F_CVTSI2SD_R_R, R_RAX, 64, R_XMM0, 128, 0, 0, 0);
                st = emit_insn(st, F_MOVQ_R_R, R_XMM0, 128, R_RAX, 64, 0, 0, 0);
                ;
            }
            if (ty == 37) {
                st = emit_insn(st, F_MOVQ_R_R, R_RAX, 64, R_XMM0, 128, 0, 0, 0);
                st = emit_insn(st, F_MOV_I_R, 100, R_RAX, 64, 0, 0, 0, 0);
                st = emit_insn(st, F_CVTSI2SD_R_R, R_RAX, 64, R_XMM1, 128, 0, 0, 0);
                st = emit_insn(st, F_MULSD_R_R, R_XMM1, 128, R_XMM0, 128, 0, 0, 0);
                st = emit_insn(st, F_MOVQ_R_R, R_XMM0, 128, R_RAX, 64, 0, 0, 0);
                ;
            }
            long prec = yv_l(yr_get(f, "prec"));
            if (prec < 0) { prec = 6; ; }
            st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
            st = fmt_push(st, code);
            st = fmt_push(st, yv_l(yr_get(f, "width")));
            st = fmt_push(st, prec);
            st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_fmt_f"))), 0, 0, 0, 0, 0, 0);
            return emit_insn(st, F_ADD_I_R, 32, R_RSP, 64, 0, 0, 0, 0);
        }
    }
}

/* A spec as the y_fmt_* helpers take it (std/str.y), its defaults
 * resolved: the type letter + 256 * fill + 65536 * alignment + 16777216 *
 * (sign + 4 * `#` + 8 * grouping), sign 0 (`-`), 1 (`+`) or 2 (a space),
 * grouping 0, 1 (`,`) or 2 (`_`). A `0` is fill 0 unless a fill is given
 * and, for a number, alignment `=` unless one is; numbers go right,
 * everything else left. */
long fmt_code(Yv *f, long kind, long ty) {
    long fill = yv_l(yr_get(f, "fill"));
    long align = yv_l(yr_get(f, "align"));
    if (yv_b(yr_get(f, "zero")) && fill == 0) { fill = 48; ; }
    if (yv_b(yr_get(f, "zero")) && align == 0 && kind != 0) {
        align = 61;
        ;
    }
    if (fill == 0) { fill = 32; ; }
    if (align == 0) {
        if (kind != 0) { align = 62; ; } else { align = 60; ; }
        ;
    }
    long sg = 0;
    long sign = yv_l(yr_get(f, "sign"));
    if (sign == 43) { sg = 1; ; }
    else if (sign == 32) { sg = 2; ; }

    if (yv_b(yr_get(f, "alt"))) { sg = sg + 4; ; }
    long grp = yv_l(yr_get(f, "grp"));
    if (grp == 44) { sg = sg + 8; ; }
    else if (grp == 95) { sg = sg + 16; ; }

    return ty + 256 * fill + 65536 * align + 16777216 * sg;
}

/* Push the number v (an argument of a helper call). */
Yv *fmt_push(Yv *st, long v) {
    st = emit_insn(st, F_MOV_I_R, v, R_RAX, 64, 0, 0, 0, 0);
    return emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
}

Yv *gen_index_of(Yv *st, Yv *node, int last) {
    st = gen_push_args(st, yr_get(node, "args"));
    if (last) {
        st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_str_lastidx"))), 0, 0, 0, 0, 0, 0);
        return emit_insn(st, F_ADD_I_R, 16, R_RSP, 64, 0, 0, 0, 0);
    } else {
        st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_str_index"))), 0, 0, 0, 0, 0, 0);
        return emit_insn(st, F_ADD_I_R, 16, R_RSP, 64, 0, 0, 0, 0);
    }
}

/* join(arr, sep). y_str_join walks string HEADERS, so an array of longs,
 * bools or floats is stringified into a fresh [str] first — reading a raw
 * long as a header would fault. Unknown element types keep the old direct
 * path: most of them really are strings (the compiler's own arrays infer
 * as tunk through {k}-holes), and guessing wrong there would corrupt
 * output rather than crash. */
Yv *gen_join(Yv *st, Yv *node) {
    Yv *jargs = yr_get(node, "args");
    Yv *at = infer(st, ya_get(jargs, 0));
    Yv *eltyp = yr(1, "k", yv_long(K_tunk));
    if (yv_l(yr_get(at, "k")) == K_tarr) {
        eltyp = yr_get(at, "of");
        ;
    }
    if (yv_l(yr_get(at, "k")) == K_tarrfix) {
        eltyp = yr_get(at, "of");
        ;
    }
    Yv *ek = yr_get(eltyp, "k");
    if (yv_l(ek) == K_tlong) {
        return gen_join_conv(st, node, ys("y_long_tostr"), 8);
    } else if (yv_l(ek) == K_tbyte) {
        return gen_join_conv(st, node, ys("y_long_tostr"), 1);
    } else if (yv_l(ek) == K_tbool) {
        return gen_join_conv(st, node, ys("y_bool_tostr"), 8);
    } else if (yv_l(ek) == K_tfloat) {
        return gen_join_conv(st, node, ys("y_float_tostr"), 8);
    } else {
        st = gen_push_args(st, yr_get(node, "args"));
        st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_str_join"))), 0, 0, 0, 0, 0, 0);
        return emit_insn(st, F_ADD_I_R, 16, R_RSP, 64, 0, 0, 0, 0);
    }
}

/* Slots: [src][dst][i]. Builds dst = [tostr(src[0]), ...] then joins it. */
Yv *gen_join_conv(Yv *st, Yv *node, Yv *tostr_fn, long esz) {
    long soff = (yv_l(yr_get(st, "slots")) + yv_l(yr_get(st, "temp")) + 1) * -8;
    long doff = (yv_l(yr_get(st, "slots")) + yv_l(yr_get(st, "temp")) + 2) * -8;
    long ioff = (yv_l(yr_get(st, "slots")) + yv_l(yr_get(st, "temp")) + 3) * -8;
    st = st_temp(st, yv_l(yr_get(st, "temp")) + 3);
    Yv *jargs = yr_get(node, "args");
    st = gen(st, ya_get(jargs, 0));
    st = emit_insn(st, F_MOV_R_D, R_RAX, 64, R_RBP, -1, 1, soff, -1);
    st = emit_insn(st, F_MOV_0_R, R_RAX, -1, 1, -1, -1, R_RDI, 64);
    st = emit_insn(st, F_SHL_I_R, 3, R_RDI, 64, 0, 0, 0, 0);
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_alloc"))), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_MOV_I_R, 24, R_RDI, 64, 0, 0, 0, 0);
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_alloc"))), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_POP_R, R_RDX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_MOV_R_D, R_RAX, 64, R_RBP, -1, 1, doff, -1);
    st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, soff, -1, R_RCX, 64);
    st = emit_insn(st, F_MOV_0_R, R_RCX, -1, 1, -1, -1, R_RCX, 64);
    st = emit_insn(st, F_MOV_R_0, R_RCX, 64, R_RAX, -1, 1, -1, -1);
    st = emit_insn(st, F_MOV_R_D, R_RCX, 64, R_RAX, -1, 1, 8, -1);
    st = emit_insn(st, F_MOV_R_D, R_RDX, 64, R_RAX, -1, 1, 16, -1);
    st = emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
    st = emit_insn(st, F_MOV_R_D, R_RAX, 64, R_RBP, -1, 1, ioff, -1);
    Yv *r1 = next_loc(st);
    st = yr_get(r1, "st");
    Yv *r2 = next_loc(st);
    st = yr_get(r2, "st");
    st = emit_label(st, yv_l(yr_get(r1, "label")));
    st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, soff, -1, R_RDX, 64);
    st = emit_insn(st, F_MOV_0_R, R_RDX, -1, 1, -1, -1, R_RCX, 64);
    st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, ioff, -1, R_RAX, 64);
    st = emit_insn(st, F_CMP_R_R, R_RCX, 64, R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, F_JGE_L, yv_l(yr_get(r2, "label")), 0, 0, 0, 0, 0, 0);
    st = elem_load(st, esz, R_RDX, R_RAX, R_RCX);
    st = emit_insn(st, F_PUSH_R, R_RCX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(tostr_fn)), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_ADD_I_R, 8, R_RSP, 64, 0, 0, 0, 0);
    st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, ioff, -1, R_RCX, 64);
    st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, doff, -1, R_RDX, 64);
    st = emit_insn(st, F_MOV_D_R, R_RDX, -1, 1, 16, -1, R_RDX, 64);
    st = emit_insn(st, F_MOV_R_M, R_RAX, 64, R_RDX, R_RCX, 8, 0, -1);
    st = emit_insn(st, F_INC_R, R_RCX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_MOV_R_D, R_RCX, 64, R_RBP, -1, 1, ioff, -1);
    st = emit_insn(st, F_JMP_L, yv_l(yr_get(r1, "label")), 0, 0, 0, 0, 0, 0);
    st = emit_label(st, yv_l(yr_get(r2, "label")));
    st = emit_insn(st, F_MOV_D_R, R_RBP, -1, 1, doff, -1, R_RAX, 64);
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen(st, ya_get(jargs, 1));
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_str_join"))), 0, 0, 0, 0, 0, 0);
    return emit_insn(st, F_ADD_I_R, 16, R_RSP, 64, 0, 0, 0, 0);
}

Yv *gen_split(Yv *st, Yv *node) {
    st = gen_push_args(st, yr_get(node, "args"));
    st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_str_split"))), 0, 0, 0, 0, 0, 0);
    return emit_insn(st, F_ADD_I_R, 16, R_RSP, 64, 0, 0, 0, 0);
}

Yv *gen_puts(Yv *st, Yv *node) {
    /* puts(v): write the value WITHOUT trailing newline (C semantics:
     * fputs + flush). Like print but no newline; returns nothing (void). */
    Yv *pargs = yr_get(node, "args");
    Yv *pa = ya_get(pargs, 0);
    st = gen(st, pa);
    Yv *t = infer(st, pa);
    if (yv_l(yr_get(t, "k")) == K_tbool) {
        st = gen_helper1(st, ys("y_put_bool"));
        return emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
    } else if (yv_l(yr_get(t, "k")) == K_tstr) {
        st = gen_helper1(st, ys("y_put_hstr"));
        return emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
    } else {
        st = gen_helper1(st, ys("y_put_long"));
        return emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
    }
}

Yv *gen_eputs(Yv *st, Yv *node) {
    /* eputs(v): like puts, but on fd 2. Diagnostic output (`--time`) must
     * never land in stdout (where `-S` assembly and program output live). */
    Yv *pargs = yr_get(node, "args");
    Yv *pa = ya_get(pargs, 0);
    st = gen(st, pa);
    Yv *t = infer(st, pa);
    if (yv_l(yr_get(t, "k")) == K_tbool) {
        st = gen_helper1(st, ys("y_eput_bool"));
        return emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
    } else if (yv_l(yr_get(t, "k")) == K_tstr) {
        st = gen_helper1(st, ys("y_eput_hstr"));
        return emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
    } else {
        st = gen_helper1(st, ys("y_eput_long"));
        return emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
    }
}

Yv *gen_clock_us(Yv *st, Yv *node) {
    /* clock_us() -> long (monotonic microseconds, via clock_gettime). */
    (void)node; /* unused in native.y's def too */
    return emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_clock_us"))), 0, 0, 0, 0, 0, 0);
}

Yv *gen_heap_used(Yv *st, Yv *node) {
    /* heap_used() -> long (bytes the allocator has handed out so far). */
    (void)node; /* unused in native.y's def too */
    return emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_heap_used"))), 0, 0, 0, 0, 0, 0);
}

/* mutex() / sem(n): a record of the type (types.c t_mutex, t_sem), its
 * lock word 0 -- the runtime's view of it (arch_x64.c y_mutex_lock,
 * y_sem_wait). */
Yv *gen_sync_new(Yv *st, Yv *node) {
    Yv *ln = yr_get(node, "line");
    Yv *cl = yr_get(node, "col");
    Yv *callee = yr_get(node, "callee");
    Yv *keys = yav(0);
    Yv *vals = yav(0);
    if (ys_eq_lit(yr_get(callee, "v"), "mutex")) {
        /* the owner pid word, 0 = free (arch_x64.y y_mutex_lock) */
        keys = ya_push(keys, ys("$m"));
        vals = ya_push(vals, n_num(ys("0"), yv_l(ln), yv_l(cl)));
        keys = ya_push(keys, ys("$o"));
        vals = ya_push(vals, n_num(ys("0"), yv_l(ln), yv_l(cl)));
        Yv *rec = yr(5, "k", yv_long(K_rec), "keys", keys, "vals", vals, "line", ln, "col", cl);
        return gen_reclit(st, rec, t_mutex());
    } else {
        Yv *sargs = yr_get(node, "args");
        keys = ya_push(keys, ys("$n"));
        vals = ya_push(vals, ya_get(sargs, 0));
        keys = ya_push(keys, ys("$w"));
        vals = ya_push(vals, n_num(ys("0"), yv_l(ln), yv_l(cl)));
        keys = ya_push(keys, ys("$o"));
        vals = ya_push(vals, n_num(ys("0"), yv_l(ln), yv_l(cl)));
        Yv *rec = yr(5, "k", yv_long(K_rec), "keys", keys, "vals", vals, "line", ln, "col", cl);
        return gen_reclit(st, rec, t_sem());
    }
}

/* lock m { b }: b's closure run while m is held, its value kept; try_lock
 * runs it only when m is free, and is whether it did. */
Yv *gen_lock(Yv *st, Yv *node, int attempt) {
    Yv *largs = yr_get(node, "args");
    st = gen(st, ya_get(largs, 0));
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen(st, ya_get(largs, 1));
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    if (!attempt) {
        st = emit_insn(st, F_MOV_D_R, R_RSP, -1, 1, 8, -1, R_RAX, 64);
        st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_mutex_lock"))), 0, 0, 0, 0, 0, 0);
        st = gen_call_top(st);
        st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, F_MOV_D_R, R_RSP, -1, 1, 16, -1, R_RAX, 64);
        st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_mutex_unlock"))), 0, 0, 0, 0, 0, 0);
        st = emit_insn(st, F_POP_R, R_RAX, 64, 0, 0, 0, 0, 0);
        return emit_insn(st, F_ADD_I_R, 16, R_RSP, 64, 0, 0, 0, 0);
    } else {
        Yv *skip = next_loc(st);
        st = yr_get(skip, "st");
        Yv *done = next_loc(st);
        st = yr_get(done, "st");
        st = emit_insn(st, F_MOV_D_R, R_RSP, -1, 1, 8, -1, R_RAX, 64);
        st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_mutex_trylock"))), 0, 0, 0, 0, 0, 0);
        st = emit_insn(st, F_TEST_R_R, R_RAX, 64, R_RAX, 64, 0, 0, 0);
        st = emit_insn(st, F_JE_L, yv_l(yr_get(skip, "label")), 0, 0, 0, 0, 0, 0);
        st = gen_call_top(st);
        st = emit_insn(st, F_MOV_D_R, R_RSP, -1, 1, 8, -1, R_RAX, 64);
        st = emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_mutex_unlock"))), 0, 0, 0, 0, 0, 0);
        st = emit_insn(st, F_MOV_I_R, 1, R_RAX, 64, 0, 0, 0, 0);
        st = emit_insn(st, F_JMP_L, yv_l(yr_get(done, "label")), 0, 0, 0, 0, 0, 0);
        st = emit_label(st, yv_l(yr_get(skip, "label")));
        st = emit_insn(st, F_XOR_R_R, R_RAX, 32, R_RAX, 32, 0, 0, 0);
        st = emit_label(st, yv_l(yr_get(done, "label")));
        return emit_insn(st, F_ADD_I_R, 16, R_RSP, 64, 0, 0, 0, 0);
    }
}

/* Call the closure on top of the stack with no arguments (it stays there). */
Yv *gen_call_top(Yv *st) {
    st = emit_insn(st, F_MOV_D_R, R_RSP, -1, 1, 0, -1, R_RAX, 64);
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, F_MOV_D_R, R_RAX, -1, 1, 0, -1, R_RAX, 64);
    st = emit_insn(st, F_CALL_IND, R_RAX, 64, 0, 0, 0, 0, 0);
    return emit_insn(st, F_ADD_I_R, 8, R_RSP, 64, 0, 0, 0, 0);
}

Yv *gen_sleep(Yv *st, Yv *node) {
    /* sleep(ms): suspend the caller for ms milliseconds (nanosleep, EINTR
     * cannot happen in single-threaded code, so one syscall is enough). */
    Yv *sargs = yr_get(node, "args");
    Yv *sa = ya_get(sargs, 0);
    st = gen(st, sa);
    return gen_helper1(st, ys("y_sleep"));
}

Yv *gen_exit(Yv *st, Yv *node) {
    /* exit(code): terminate the process with the exit-code syscall. */
    Yv *eargs = yr_get(node, "args");
    Yv *ea = ya_get(eargs, 0);
    st = gen(st, ea);
    st = emit_insn(st, F_MOV_R_R, R_RAX, 64, R_RDI, 64, 0, 0, 0);
    st = emit_insn(st, F_MOV_I_R, 231, R_RAX, 64, 0, 0, 0, 0);
    st = emit_insn(st, F_SYSCALL, 0, 0, 0, 0, 0, 0, 0);
    /* exit() terminates the process; the epilogue (ret / exit(0)) is
     * unreachable. Emit a jump to the function end so the backend never
     * falls through into dead code (and exit codes are never masked). */
    return emit_insn(st, F_JMP_L, yv_l(yr_get(st, "end_label")), 0, 0, 0, 0, 0, 0);
}

/* ── process I/O (argv) ──────────────────────────────────────────────
 * argv MAY only appear as `main(argv())`'s argument feed: ycc.y's entry is
 * `let result = main(argv())`. The _start prologue (below) builds the argv
 * array and stashes it in r15; gen_argv emits the call that materializes
 * it. (Files are std/fs.y: `import fs;`.) */

Yv *gen_argv(Yv *st, Yv *node) {
    (void)node; /* native.y has no statement here; the node is unread */
    return emit_insn(st, F_CALL_L, yv_l(lbl_new(ys("y_argv"))), 0, 0, 0, 0, 0, 0);
}

Yv *gen_store(Yv *st, Yv *node) {
    Yv *spt = infer(st, yr_get(node, "p"));
    long sw = ptr_width(spt);
    Yv *sto = yr(1, "k", yv_long(K_tnone));
    if (sw == 8 && yv_l(yr_get(spt, "k")) == K_tptr) {
        sto = yr_get(spt, "to");
        ;
    }
    st = gen(st, yr_get(node, "p"));
    st = emit_insn(st, F_PUSH_R, R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen_as(st, yr_get(node, "v"), sto);
    st = emit_insn(st, F_POP_R, R_RCX, 64, 0, 0, 0, 0, 0);
    if (sw == 1) {
        return emit_insn(st, F_MOVB_R_0, R_RAX, 8, R_RCX, -1, 1, -1, -1);
    } else {
        return emit_insn(st, F_MOV_R_0, R_RAX, 64, R_RCX, -1, 1, -1, -1);
    }
}

/* ── functions ──────────────────────────────────────────────────────────
 * Frame: locals at rbp-8, rbp-16, ...; params at rbp+16, rbp+24, ....
 * Every emitted function gets: prologue, body, end_label, epilogue. */

Yv *emit_one_fn(Yv *st, Yv *label, long fuid, Yv *func, int is_main,
                int want_argv, Yv *captypes, Yv *selfname) {
    /* fresh per-function state; uid/rodata/fns flow through and back.
     * Bodies see every hoisted function and global through st.fns
     * (env_find), like the checker's fresh_func_scope. */
    /* frame_max is this function's: emit_one_fn nests (a hoisted def, a
     * closure literal), so the caller's mark is put back on the way out. */
    long prev_max = frame_max;
    frame_max = 0;
    Yv *f = yr(15, "ir", yav(0), "txt", yav(0), "rodata", yr_get(st, "rodata"), "uid",
               yr_get(st, "uid"), "fuid", yv_long(fuid), "loc", yv_long(1),
               "env", yav(0), "slots", yv_long(0), "temp", yv_long(0), "self_label", label,
               "end_label", lbl_new(arch_loc_label(fuid, 0)), "fns",
               yr_get(st, "fns"),
               "bodies", yr_get(st, "bodies"), "btext", yr_get(st, "btext"), "blabels", yr_get(st, "blabels"));
    /* The names nested functions capture (see box_names / box_bound). */
    f = env_define(f, ys(""), ys("frame"), 0, yv_long(-1), ys(""),
                   yr(1, "k", yv_long(K_tnone)));
    /* This function's type, for conversions at returns and self calls. */
    f = env_define(f, ys(""), ys("fnty"), 0, yv_long(-1), ys(""),
                   yr(3, "k", yv_long(K_tfunc), "args", yr_get(func, "ptypes"),
                       "ret", fn_ret(func)));
    Yv *bnames = box_names(func);
    long bi = 0;
    while (bi < yv_len(bnames)) {
        Yv *bnm = ya_get(bnames, bi);
        f = env_define(f, ys(""), ys("boxmark"), 0, yv_long(-1), bnm,
                       yr(1, "k", yv_long(K_tnone)));
        bi = bi + 1;
    }
    /* The names this body appends to (see own_wanted), the same way. */
    Yv *anames = app_names(yr_get(func, "body"), 0, bnames);
    long ai = 0;
    while (ai < yv_len(anames)) {
        Yv *anm = ya_get(anames, ai);
        f = env_define(f, ys(""), ys("appmark"), 0, yv_long(-1), anm,
                       yr(1, "k", yv_long(K_tnone)));
        ai = ai + 1;
    }
    /* A capturing named function is not in that table (see
     * capturing_defs): bind its own name to this body, so a call by name
     * passes the record along (gen_direct) and a value is the record. */
    if (!ys_eq_lit(selfname, "")) {
        f = env_define(f, selfname, ys("func"), 0, label, ys(""),
                       func_type_in(st, func));
        ;
    }
    /* bind params. Caller pushes args left-to-right, so the LAST arg sits
     * at rbp+16 and param k lives at rbp+16+8*(n-1-k) (arity-dependent). */
    Yv *params = yr_get(func, "params");
    Yv *ptypes = yr_get(func, "ptypes");
    long nargs = yv_len(params);
    long i = 0;
    while (i < nargs) {
        f = env_define(f, ya_get(params, i), ys("param"),
                       16 + (nargs - 1 - i) * 8, yv_long(-1), ys(""),
                       ya_get(ptypes, i));
        i = i + 1;
    }
    /* Captures: the caller pushed the closure record BEFORE the args, so
     * it lives just past them at rbp+16+8*nargs. Each capture reads slot
     * idx+1 of that record (slot 0 is the code pointer). A capture-free
     * function binds nothing here and never touches the slot, which is
     * what lets one body serve both direct and closure calls. `_start` has
     * no enclosing frame, so it never captures. */
    if (is_main) {
        ;
    } else {
        Yv *mycaps = fn_captures(func, yr_get(yr_get(st, "fns"), "ix"), selfname);
        long cloff = 16 + nargs * 8;
        long c = 0;
        while (c < yv_len(mycaps)) {
            Yv *cn = ya_get(mycaps, c);
            /* Capture types come from the creation site (the enclosing env
             * knows them); without one the emitter would pick long for a
             * captured string in print/puts and in `+`. */
            Yv *ct = yr(1, "k", yv_long(K_tnone));
            if (c < yv_len(captypes)) {
                ct = ya_get(captypes, c);
                ;
            }
            f = env_define(f, cn, ys("capture"), cloff, yv_long(-1), ys_long(c),
                           ct);
            c = c + 1;
        }
        ;
    }
    /* Captured parameters (and the own name) move into their cells
     * before the body; a tail call re-enters above this, so every
     * recycled frame gets fresh cells. */
    if (!ys_eq_lit(selfname, "")) {
        f = box_bound(f, selfname);
        ;
    }
    long pbi = 0;
    while (pbi < nargs) {
        Yv *pbn = ya_get(params, pbi);
        f = box_bound(f, pbn);
        pbi = pbi + 1;
    }
    /* An appended-to str parameter moves into an own pair (bind_own). */
    long opi = 0;
    while (opi < nargs) {
        Yv *opn = ya_get(params, opi);
        Yv *opt = ya_get(ptypes, opi);
        if (yv_l(yr_get(opt, "k")) == K_tstr && own_wanted(f, opn)) {
            Yv *ope = env_find(f, opn);
            f = emit_insn(f, F_MOV_D_R, R_RBP, -1, 1, yv_l(yr_get(ope, "off")), -1, R_RAX, 64);
            f = bind_own(f, opn, opt);
            ;
        }
        opi = opi + 1;
    }
    f = gen_tail(f, yr_get(func, "body"));
    long peak = yv_l(yr_get(f, "slots")) + yv_l(yr_get(f, "temp"));
    if (peak > frame_max) { frame_max = peak; }
    long frame = arch_frame(frame_max);
    frame_max = prev_max;
    /* The body is one IR stream: the prologue, what the body emitted, the
     * epilogue (see ir.h). The text the linker and -S read is rendered from
     * it, so nothing here is spelled twice. */
    Yv *body = yav(0);
    body = ir_push(body, IR_LABEL, yv_l(label), 0, 0, 0, 0, 0, 0);
    /* -g: the prologue is the def's line; `_start` has none (line 0) */
    if (dbg_lines) {
        if (is_main) {
            body = ir_loc(body, 0);
            ;
        } else {
            body = ir_loc(body, yv_l(yr_get(func, "line")));
            ;
        }
        ;
    }
    if (is_main) {
        if (want_argv) {
            /* _start prologue: at process entry %rsp -> [argc][argv0ptr]....
             * argv (char**) is the ADDRESS rsp+8 (lea, not a load!); argc
             * is [rsp]. y_argv_init copies every arg into a header string
             * and stashes the [str] array in r15 for y_argv. Skipped
             * entirely when the program never calls argv() (saves ~14s of
             * startup: y_cstr_to_str walks every byte of every arg).
             * NOTE: no bare (%rsp)/(%r12) — the encoder rejects rsp/r12
             * bases. */
            body = ir_push(body, F_MOV_R_R, R_RSP, 64, R_RAX, 64, 0, 0, 0);
            body = ir_push(body, F_MOV_0_R, R_RAX, -1, 1, 0, -1, R_R15, 64);
            body = ir_push(body, F_MOV_R_R, R_RAX, 64, R_R14, 64, 0, 0, 0);
            body = ir_push(body, F_ADD_I_R, 8, R_R14, 64, 0, 0, 0, 0);
            body = ir_push(body, F_PUSH_R, R_R14, 64, 0, 0, 0, 0, 0);
            body = ir_push(body, F_PUSH_R, R_R15, 64, 0, 0, 0, 0, 0);
            body = ir_push(body, F_CALL_L, yv_l(lbl_new(ys("y_argv_init"))), 0,
                           0, 0, 0, 0, 0);
            body = ir_push(body, F_ADD_I_R, 16, R_RSP, 64, 0, 0, 0, 0);
            ;
        }
        ;
    }
    body = ir_push(body, F_PUSH_R, R_RBP, 64, 0, 0, 0, 0, 0);
    body = ir_push(body, F_MOV_R_R, R_RSP, 64, R_RBP, 64, 0, 0, 0);
    if (frame > 0) {
        body = ir_push(body, F_SUB_I_R, frame, R_RSP, 64, 0, 0, 0, 0);
        ;
    }
    body = ir_cat(body, yr_get(f, "ir"));
    body = ir_push(body, IR_LABEL, yv_l(yr_get(f, "end_label")), 0, 0, 0, 0, 0,
                   0);
    if (is_main) {
        body = ir_push(body, F_MOV_I_R, 231, 0, 64, 0, 0, 0, 0);
        body = ir_push(body, F_XOR_R_R, R_RDI, 32, R_RDI, 32, 0, 0, 0);
        body = ir_push(body, F_SYSCALL, 0, 0, 0, 0, 0, 0, 0);
    } else {
        body = ir_push(body, F_MOV_R_R, R_RBP, 64, R_RSP, 64, 0, 0, 0);
        body = ir_push(body, F_POP_R, R_RBP, 64, 0, 0, 0, 0, 0);
        body = ir_push(body, F_RET, 0, 0, 0, 0, 0, 0, 0);
    }
    /* NOTE: append to f.bodies, NOT st.bodies. Emitting this body can add
     * bodies of its own (a nested capturing def is emitted at its creation
     * site), and those land in f.bodies. Using st.bodies dropped them
     * whenever push had to GROW the array: the C copy's value model shares
     * the grown buffer between the two record copies, the native backend
     * rebinds only f.bodies (see NATIVE.md "rebind: a = push(a, v)"), so the
     * two compilers disagreed and ycc emitted calls to labels it never
     * defined. */
    Yv *bodies = ya_push(yr_get(f, "bodies"), body);
    /* The raw lines this body's IR_TEXT items index are this function's own
       (f.txt is fresh per function), so they go with the body. */
    Yv *btext = ya_push(yr_get(f, "btext"), yr_get(f, "txt"));
    /* The body's own label, which the linker shakes by (Unit.labels): the
     * first line of the text, known here rather than scanned for (the old
     * body_label). Pushed onto f.blabels the way f.bodies is, for the same
     * reason (see above): a nested body's label has to land in the same array
     * as its body, or every label after it shifts by one and the linker
     * shakes by the wrong ones. */
    Yv *blabels = ya_push(yr_get(f, "blabels"), lname(label));
    return yr(15, "ir", yr_get(st, "ir"), "txt", yr_get(st, "txt"), "rodata", yr_get(f, "rodata"),
              "uid", yr_get(f, "uid"), "fuid", yr_get(st, "fuid"), "loc",
              yr_get(st, "loc"), "env", yr_get(st, "env"), "slots",
              yr_get(st, "slots"), "temp", yr_get(st, "temp"), "self_label", yr_get(st, "self_label"),
              "end_label", yr_get(st, "end_label"), "fns", yr_get(st, "fns"),
              "bodies", bodies, "btext", btext, "blabels", blabels);
}

/* Build a tfunc type from a func node (params have annotations — checked).
 * Return type of a function whose `-> T` was omitted and which the checker
 * could not type either (types.y records every other inferred return type
 * in the node: set_inferred_ret): the type of its body's tail, inferred in
 * a scope holding every known def plus the params. The emitter needs one,
 * because a call's result type decides e.g. whether `+` must stringify. */
Yv *infer_fn_ret(Yv *st, Yv *func) {
    Yv *f = yr(15, "ir", yav(0), "txt", yav(0), "rodata", yr_get(st, "rodata"), "uid",
               yr_get(st, "uid"), "fuid", yv_long(0), "loc", yv_long(1),
               "env", yav(0), "slots", yv_long(0), "temp", yv_long(0), "self_label",
               yv_long(-1), "end_label", yv_long(-1), "fns", yr_get(st, "fns"),
               "bodies", yr_get(st, "bodies"), "btext", yr_get(st, "btext"), "blabels",
               yr_get(st, "blabels"));
    Yv *params = yr_get(func, "params");
    Yv *ptypes = yr_get(func, "ptypes");
    long n = yv_len(params);
    long i = 0;
    while (i < n) {
        f = env_define(f, ya_get(params, i), ys("param"),
                       16 + (n - 1 - i) * 8, yv_long(-1), ys(""),
                       ya_get(ptypes, i));
        i = i + 1;
    }
    return infer(f, yr_get(func, "body"));
}

/* A def's return type: as written, or as the checker inferred it
 * (types.c inferred_ret); tnone when neither. */
Yv *fn_ret(Yv *func) {
    Yv *r = yr_get(func, "ret");
    if (yv_l(yr_get(r, "k")) == K_tnone) {
        return inferred_ret(yv_l(yr_get(func, "line")), yv_l(yr_get(func, "col")));
    } else {
        return r;
    }
}

Yv *func_type(Yv *func) {
    return yr(3, "k", yv_long(K_tfunc), "args", yr_get(func, "ptypes"), "ret",
              fn_ret(func));
}

/* Same, but with an unannotated return type resolved from the body — the
 * checker infers it too, so a literal's call sites must agree (whether `+`
 * stringifies, which print arm runs, ...). */
Yv *func_type_in(Yv *st, Yv *func) {
    Yv *r = fn_ret(func);
    if (yv_l(yr_get(r, "k")) == K_tnone) {
        r = infer_fn_ret(st, func);
        ;
    }
    return yr(3, "k", yv_long(K_tfunc), "args", yr_get(func, "ptypes"), "ret", r);
}

/* Files share one namespace. A later top-level def replaces an earlier one
 * of the same name (rename.c rn_shadow_dups): deliberate within a file, but
 * across files it silently hands every caller -- the first file's own
 * included -- the other file's function. So a def that replaces one from
 * another file is an error, at the later def. The std units are no part
 * of this namespace (they are linked, see std_units): a program may
 * define a std name, and its own `readline` wins. */
Yv *find_dup(Yv *stmts, Yv *origin) {
    Yv *names = yav(0);
    Yv *fids = yav(0);
    Yv *lines = yav(0);
    Yv *cols = yav(0);
    long i = 0;
    while (i < yv_len(stmts)) {
        Yv *s = ya_get(stmts, i);
        Yv *nm = top_name_in(s, origin);
        if (yv_len(nm) > 0) {
            long ln = yv_l(yr_get(s, "line"));
            names = ya_push(names, nm);
            fids = ya_push(fids, yv_long(origin_file(origin, ln)));
            lines = ya_push(lines, yv_long(ln));
            cols = ya_push(cols, yr_get(s, "col"));
            ;
        }
        i = i + 1;
    }
    /* A name's earlier definitions, not every statement's: with 20 000
     * top-level defs the scan of all earlier names was 75% of the compile
     * (10 billion instructions), and nothing in it but the name's own
     * repetitions was ever a candidate. So a name reaches only its own
     * definitions: labmap_new maps the name to a chain head, and each entry
     * holds its file, its position and the entry before it. Walking that chain
     * backwards gives the last definition from another file -- the same answer
     * the scan gave, since the chain is in the order the scan went. */
    Yv *ix = labmap_new(yv_len(names) * 2 + 16);
    Yv *top = yav(0);
    Yv *pfile = yav(0);
    Yv *ppos = yav(0);
    Yv *pnext = yav(0);
    Yv *errs = yav(0);
    long j = 0;
    while (j < yv_len(names)) {
        Yv *nj = ya_get(names, j);
        long fj = yv_l(ya_get(fids, j));
        long slot = -1;
        Yv *g = labmap_get(ix, nj);
        if (yv_l(yr_get(g, "sec")) >= 0) { slot = yv_l(yr_get(g, "sec")); }
        if (slot < 0) {
            top = ya_push(top, yv_long(-1));
            slot = yv_len(top) - 1;
            ix = yr_get(labmap_put(ix, nj, slot, 0), "map");
            ;
        }
        long other = -1;
        long q = yv_l(ya_get(top, slot));
        while (q >= 0 && other < 0) {
            if (yv_l(ya_get(pfile, q)) != fj) {
                other = yv_l(ya_get(ppos, q));
                ;
            }
            q = yv_l(ya_get(pnext, q));
        }
        if (other >= 0) {
            Yv *msg = ys_cat(ys_cat(ys("duplicate definition '"), nj),
                             ys("': "));
            msg = ys_cat(msg, origin_at(origin, yv_l(ya_get(lines, other)), 0));
            msg = ys_cat(msg, ys(" defines it too (imported files share one "
                                 "namespace; rename one)"));
            errs = ya_push(errs, yr(3, "msg", msg, "line", ya_get(lines, j),
                                    "col", ya_get(cols, j)));
            ;
        }
        pfile = ya_push(pfile, yv_long(fj));
        ppos = ya_push(ppos, yv_long(j));
        pnext = ya_push(pnext, ya_get(top, slot));
        ya_set(top, slot, yv_long(yv_len(pfile) - 1));
        j = j + 1;
    }
    return errs;
}

/* top_def_name of a top-level statement as rename.c binds it: a module's
 * (`import fs;`) qualified, `fs.exists` (rename.c rn_qualify). */
Yv *top_name_in(Yv *s, Yv *origin) {
    Yv *nm = top_def_name(s);
    if (yv_len(nm) == 0 || ys_starts_with(nm, ys("y_"))) {
        return nm;
    } else {
        long ln = yv_l(yr_get(s, "line"));
        long fid = origin_file(origin, ln);
        Yv *om = yr_get(origin, "mods");
        if (fid < yv_len(om) && !ys_eq_lit(ya_get(om, fid), "")) {
            return ys_cat(ys_cat(ya_get(om, fid), ys(".")), nm);
        } else {
            return nm;
        }
    }
}

/* The name a top-level statement defines as a function -- a def, or a let
 * bound to a function literal; both hoist -- or "" (rename.c
 * rn_decl_name). */
Yv *top_def_name(Yv *s) {
    if (yv_l(yr_get(s, "k")) == K_decl) {
        return top_def_name_go(s);
    } else {
        return ys("");
    }
}

Yv *top_def_name_go(Yv *s) {
    /* NOTE: one `s.v.k` read per body (see rename.c rn_prepass_decl
     * note). */
    if (ys_eq_lit(yr_get(s, "kind"), "def")) {
        return yr_get(s, "name");
    } else if (yv_l(yr_get(yr_get(s, "v"), "k")) == K_func) {
        return yr_get(s, "name");
    } else {
        return ys("");
    }
}

/* ── globals and hoisting ───────────────────────────────────────────────
 * Every variable bound directly in the program is a GLOBAL: one 8-byte
 * .bss cell, read and written by label from any function. So a def that
 * names one captures nothing, and every top-level def is hoisted: emitted
 * once, called directly by label, from anywhere (forward calls too). */

/* The program's top-level variable declarations, in order (function
 * bindings are defs, not variables). */
Yv *global_decls(Yv *stmts) {
    Yv *out = yav(0);
    long i = 0;
    while (i < yv_len(stmts)) {
        Yv *s = ya_get(stmts, i);
        if (yv_l(yr_get(s, "k")) == K_decl) {
            if (ys_eq_lit(yr_get(s, "kind"), "def")) {
                ;
            } else if (yv_l(yr_get(yr_get(s, "v"), "k")) == K_func) {
                ;
            } else {
                out = ya_push(out, s);
                ;
            }
            ;
        }
        i = i + 1;
    }
    return out;
}

Yv *decl_name(Yv *d) {
    return yr_get(d, "name");
}

/* Each global's cell label and type, in program order. A declared type
 * wins; otherwise the initializer is inferred in a scope holding the
 * hoisted defs and the globals before it (what main sees when it runs
 * the declaration). Labels count from the unit's `gbase` (compile_unit),
 * so two units' globals never share one. */
Yv *global_entries(Yv *st, Yv *gdecls, long gbase) {
    Yv *f = yr(15, "ir", yav(0), "txt", yav(0), "rodata", yr_get(st, "rodata"), "uid",
               yr_get(st, "uid"), "fuid", yv_long(0), "loc", yv_long(1),
               "env", yav(0), "slots", yv_long(0), "temp", yv_long(0), "self_label",
               yv_long(-1), "end_label", yv_long(-1), "fns", yr_get(st, "fns"),
               "bodies", yr_get(st, "bodies"), "btext", yr_get(st, "btext"), "blabels",
               yr_get(st, "blabels"));
    Yv *out = yav(0);
    long i = 0;
    while (i < yv_len(gdecls)) {
        Yv *d = ya_get(gdecls, i);
        Yv *gn = decl_name(d);
        Yv *t = decl_type(d);
        if (yv_l(yr_get(t, "k")) == K_tnone) {
            t = infer(f, decl_value(d));
            ;
        }
        Yv *lbl = arch_global_label(gbase + i, gn);
        out = ya_push(out, yr(3, "name", gn, "label", lbl, "typ", t));
        f = env_define(f, gn, ys("global"), 0, lbl_new(lbl), ys(""), t);
        i = i + 1;
    }
    return out;
}

Yv *decl_type(Yv *d) {
    return yr_get(d, "typ");
}

Yv *decl_value(Yv *d) {
    return yr_get(d, "v");
}

/* Named functions that need a closure record: a def reading a variable
 * that is neither a global nor a function, or naming a function that
 * needs one itself (a direct call could not hand that one its record).
 * Iterated to a fixpoint. A function's own name is no capture (its body
 * reaches itself through its own record, see emit_one_fn). */
Yv *capturing_defs(Yv *defs, Yv *gnames) {
    Yv *fnames = yav(0);
    long i = 0;
    while (i < yv_len(defs)) {
        Yv *d = ya_get(defs, i);
        fnames = ya_push(fnames, yr_get(d, "name"));
        i = i + 1;
    }
    Yv *caps = yav(0);
    Yv *out = yav(0);
    Yv *exm = namemap_build(gnames);
    Yv *fnm = namemap_build(fnames);
    i = 0;
    while (i < yv_len(defs)) {
        Yv *d = ya_get(defs, i);
        Yv *cs = fn_captures(yr_get(d, "func"), exm, yr_get(d, "name"));
        caps = ya_push(caps, cs);
        long j = 0;
        int reads_var = 0;
        while (j < yv_len(cs)) {
            Yv *cn = ya_get(cs, j);
            if (namemap_get(fnm, cn) >= 0) {
                ;
            } else {
                reads_var = 1;
                ;
            }
            j = j + 1;
        }
        if (reads_var) {
            out = ya_push(out, yr_get(d, "name"));
            ;
        }
        i = i + 1;
    }
    int changed = 1;
    while (changed) {
        changed = 0;
        i = 0;
        while (i < yv_len(defs)) {
            Yv *d = ya_get(defs, i);
            if (name_in(out, yr_get(d, "name"))) {
                ;
            } else {
                Yv *cs = ya_get(caps, i);
                long j = 0;
                int hit = 0;
                while (j < yv_len(cs)) {
                    Yv *cn = ya_get(cs, j);
                    if (name_in(out, cn)) {
                        hit = 1;
                        ;
                    }
                    j = j + 1;
                }
                if (hit) {
                    out = ya_push(out, yr_get(d, "name"));
                    changed = 1;
                    ;
                }
                ;
            }
            i = i + 1;
        }
    }
    return out;
}

/* The hoisted defs' types (st.fns order) with every omitted return type
 * inferred from the body (see infer_fn_ret). With `only` non-empty, just
 * the bodies reading one of those names are re-inferred; the rest keep
 * their st.fns entry. */
Yv *fix_fn_types(Yv *st, Yv *hdefs, Yv *only) {
    Yv *out = yav(0);
    Yv *ftab = yr_get(yr_get(st, "fns"), "syms");
    long fx = 0;
    while (fx < yv_len(hdefs)) {
        Yv *d = ya_get(hdefs, fx);
        Yv *fe0 = ya_get(ftab, fx);
        int redo = ret_omitted(yr_get(d, "func"));
        if (redo && yv_len(only) > 0) {
            redo = reads_any(yr_get(d, "func"), only);
            ;
        }
        if (redo) {
            out = ya_push(
                out,
                yr(3, "name", yr_get(fe0, "name"), "label",
                   yr_get(fe0, "label"), "typ",
                   yr(3, "k", yv_long(K_tfunc),
                      "args", fn_ptypes(yr_get(d, "func")),
                      "ret", infer_fn_ret(st, yr_get(d, "func")))));
            ;
        } else {
            out = ya_push(out, fe0);
            ;
        }
        fx = fx + 1;
    }
    return out;
}

int ret_omitted(Yv *func) {
    return yv_l(yr_get(fn_ret(func), "k")) == K_tnone;
}

Yv *fn_ptypes(Yv *func) {
    return yr_get(func, "ptypes");
}

int reads_any(Yv *func, Yv *names) {
    Yv *reads = fv_ids(yr_get(func, "body"), yav(0));
    long i = 0;
    int found = 0;
    while (i < yv_len(reads)) {
        Yv *n = ya_get(reads, i);
        if (name_in(names, n)) {
            found = 1;
            ;
        }
        i = i + 1;
    }
    return found;
}

/* ── phase timing ───────────────────────────────────────────────────────
 * Every phase records elapsed microseconds and heap bytes consumed, so
 * `ycc --time` can show where wall time AND memory go (the arena never
 * frees, so allocation volume is as interesting as elapsed time). */

Yv *phase_end(Yv *times, Yv *name, long t0, long h0) {
    long t1 = clock_us();
    long h1 = heap_used();
    return yr(3, "times",
              ya_push(times, yr(3, "name", name, "us", yv_long(t1 - t0),
                                "heap", yv_long(h1 - h0))),
              "t", yv_long(t1), "h", yv_long(h1));
}

/* ── compilation units ─────────────────────────────────────────────────
 * The program is linked from its own resolved source (native_resolve_x),
 * the std units it needs (std_units), and the package units it reaches.
 * compile_unit takes one unit from AST to assembly text, one body per
 * function; it sees another unit's exports and defaults bound as
 * externs. link_units joins and shakes the bodies, so unreachable
 * functions cost nothing.
 *
 * Labels cannot collide: a unit numbers its uids (function, string and
 * local labels) and its global cells from its own base (std_unit_base;
 * the program's is 0). A unit's top-level statements run in an INIT
 * function; the program's `_start` calls the linked units' inits first,
 * in link order.
 *
 * The program sees the exports of bound library units and packages;
 * runtime std units (rt, str) hold only `y_` helpers, called by fixed
 * label. A program or package def wearing a runtime label replaces the
 * std body of that label everywhere (link_units drops the std one). */

Yv *unit_empty(Yv *name) {
    Yv *fs = yav(0);
    Yv *xs = yav(0);
    Yv *bs = yav(0);
    Yv *bt = yav(0);
    Yv *ls = yav(0);
    Yv *fr = yav(0);
    Yv *rs = yav(0);
    Yv *gs = yav(0);
    Yv *ds = yav(0);
    return yr(12, "name", name, "files", fs, "exports", xs, "init", ys(""),
              "bodies", bs, "btext", bt, "blob", yav(0), "labels", ls, "refs",
              fr, "rodata", rs, "globals", gs, "dfl", ds);
}

Yv *externs_none(void) {
    return yr(5, "ext", yav(0), "dfl", yav(0), "pkgs", yav(0), "inits",
              yav(0), "argv", yv_bool(0));
}

Yv *std_unit_src(Yv *name) {
    if (ys_eq_lit(name, "prelude")) {
        return PRELUDE_SRC();
    } else if (ys_eq_lit(name, "exec")) {
        return EXEC_SRC();
    } else if (ys_eq_lit(name, "str")) {
        return STR_SRC();
    } else {
        return RT_SRC();
    }
}

long std_unit_base(Yv *name) {
    if (ys_eq_lit(name, "prelude")) {
        return 1000000000L;
    } else if (ys_eq_lit(name, "exec")) {
        return 2000000000L;
    } else if (ys_eq_lit(name, "str")) {
        return 3000000000L;
    } else {
        return 4000000000L;
    }
}

int std_unit_bound(Yv *name) {
    return ys_eq_lit(name, "prelude") || ys_eq_lit(name, "exec");
}

Yv *std_unit_names(void) {
    return yav(4, ys("prelude"), ys("exec"), ys("str"), ys("rt"));
}

Yv *std_units(Yv *names, Yv *pack) {
    Yv *out = yav(0);
    if (yv_len(pack) > 0) {
        out = std_unpack(pack, names);
        ;
    }
    if (yv_len(out) == 0) {
        long i = 0;
        while (i < yv_len(names)) {
            Yv *nm = ya_get(names, i);
            Yv *ext = yav(0);
            if (ys_eq_lit(nm, "exec")) {
                long j = 0;
                while (j < yv_len(out)) {
                    Yv *u = ya_get(out, j);
                    if (ys_eq_lit(yr_get(u, "name"), "prelude")) {
                        Yv *exports = yr_get(u, "exports");
                        long k = 0;
                        while (k < yv_len(exports)) {
                            ext = ya_push(ext, ya_get(exports, k));
                            k = k + 1;
                        }
                        ;
                    }
                    j = j + 1;
                }
                ;
            }
            out = ya_push(out, std_compile(nm, ext));
            i = i + 1;
        }
        ;
    }
    return out;
}

/* One std unit, from its embedded source. It always carries its `.loc`
 * markers (link_units strips them unless -g), so it compiles the same
 * for every program. A failure here is the compiler's own bug: reported
 * as one, and the run ends. */
Yv *std_compile(Yv *name, Yv *ext) {
    Yv *path = ys_cat(ys_cat(ys("std/"), name), ys(".y"));
    Yv *toks = tokenize(std_text(std_unit_src(name)));
    Yv *ast = parse_program(toks);
    Yv *noimports = yav(0);
    Yv *nolines = yav(0);
    Yv *origin = yr(5, "files", yav(1, path), "nuser", yv_long(1),
                    "file", nolines, "line", nolines, "mods", yav(1, ys("")));
    Yv *xt = externs_none();
    yr_set(xt, "ext", ext);
    Yv *r = compile_unit(ast, noimports, origin, 1, 0, name,
                         std_unit_base(name), xt);
    if (!yv_b(yr_get(r, "ok"))) {
        Yv *errs = yr_get(r, "errors");
        long k = 0;
        while (k < yv_len(errs)) {
            Yv *e = ya_get(errs, k);
            Yv *msg = ys_cat(ys_cat(ys("ycc: internal error: "), path),
                             ys(":"));
            msg = ys_cat(msg, ys_long(yv_l(yr_get(e, "line"))));
            msg = ys_cat(msg, ys(":"));
            msg = ys_cat(msg, ys_long(yv_l(yr_get(e, "col"))));
            msg = ys_cat(msg, ys(": "));
            msg = ys_cat(msg, yr_get(e, "msg"));
            puts_(ys_cat(msg, ys("\n")));
            k = k + 1;
        }
        exit_(1);
        ;
    }
    return yr_get(r, "unit");
}

/* The name a renamed top-level def was written with, or "" for one a
 * later def of the same name replaced (rename.y's `name$shadowK`). */
Yv *export_name(Yv *name) {
    long d = ys_index_of(name, ys("$"));
    if (ys_index_of(name, ys(".")) >= 0) {
        /* a module's (`fs.exists`): the unit's own import, not its export */
        return ys("");
    } else if (d < 0) {
        return name;
    } else if (is_all_digits(ys_slice_from(name, d + 1))) {
        return ys_slice(name, 0, d);
    } else {
        return ys("");
    }
}

/* A unit's exports: its top-level defs, by the names they were written
 * with, with the labels and types `fns` gives them. hdefs holds them in
 * statement order (a def's nested ones follow it), and fns starts with
 * hdefs' entries. */
Yv *unit_exports(Yv *stmts, Yv *hdefs, Yv *fns) {
    Yv *out = yav(0);
    long h = 0;
    long i = 0;
    while (i < yv_len(stmts)) {
        Yv *nm = top_def_name(ya_get(stmts, i));
        if (yv_len(nm) > 0) {
            long h0 = h;
            int found = 0;
            while (!found && h < yv_len(hdefs)) {
                Yv *hd = ya_get(hdefs, h);
                if (ys_eq(yr_get(hd, "name"), nm)) {
                    found = 1;
                    ;
                } else {
                    h = h + 1;
                    ;
                }
            }
            if (found) {
                Yv *xn = export_name(nm);
                if (yv_len(xn) > 0) {
                    Yv *fe = ya_get(fns, h);
                    out = ya_push(
                        out, yr(3, "name", xn, "label", yr_get(fe, "label"),
                                "typ", yr_get(fe, "typ")));
                    ;
                }
                h = h + 1;
                ;
            } else {
                h = h0;
                ;
            }
            ;
        }
        i = i + 1;
    }
    return out;
}

/* One unit, AST to assembly text (see the section note). `name` is ""
 * for the program's own unit, whose top-level statements are `_start`;
 * other units have an init function. `xt` holds externs, defaults,
 * imported package namespaces, init labels and the argv-use flag. */

Yv *compile_unit(Yv *ast, Yv *imports, Yv *origin, int debug, long wlevel,
                 Yv *name, long base, Yv *xt) {
    tyset_reset();
    dbg_lines = debug;
    dbg_file = yr_get(origin, "file");
    dbg_line = yr_get(origin, "line");
    Yv *ext = yr_get(xt, "ext");
    Yv *inits = yr_get(xt, "inits");
    pkg_ns = yr_get(xt, "pkgs");
    Yv *times = yav(0);
    long pt = clock_us();
    long ph = heap_used();
    Yv *ast2 = strip_ns(ast, imports);
    Yv *pr = phase_end(times, ys("strip_ns"), pt, ph);
    times = yr_get(pr, "times");
    pt = yv_l(yr_get(pr, "t"));
    ph = yv_l(yr_get(pr, "h"));
    /* Static name resolution: every binding gets a unique name, so neither
     * the checker nor the emitter deals with scopes or shadowing. */
    Yv *ast3 = rename_program_x(ast2, yr_get(xt, "dfl"), yr_get(origin, "file"),
                                yr_get(origin, "mods"));
    pr = phase_end(times, ys("rename"), pt, ph);
    times = yr_get(pr, "times");
    pt = yv_l(yr_get(pr, "t"));
    ph = yv_l(yr_get(pr, "h"));
    Yv *errors = check_program(ast3, ext);
    pr = phase_end(times, ys("typecheck"), pt, ph);
    times = yr_get(pr, "times");
    pt = yv_l(yr_get(pr, "t"));
    ph = yv_l(yr_get(pr, "h"));
    /* collect every named def (top-level, nested, let-bound) */
    Yv *defs = collect_from_block(yr_get(ast3, "stmts"), yav(0));
    /* A def that replaces another file's goes first: the checker's errors
     * may be only its consequences. */
    Yv *dups = find_dup(yr_get(ast, "stmts"), origin);
    if (yv_len(dups) > 0) {
        long di = 0;
        while (di < yv_len(errors)) {
            dups = ya_push(dups, ya_get(errors, di));
            di = di + 1;
        }
        errors = dups;
        ;
    }
    Yv *warnings = yav(0);
    if (yv_len(errors) > 0) {
        return yr(5, "ok", yv_bool(0), "errors", errors, "warnings",
                  warnings, "times", times, "unit", unit_empty(name));
    } else {
        /* The warnings (lint.c): the program's unit's and a package's,
         * never a std unit's. */
        if (yv_len(name) == 0 || pkg_base(base)) {
            warnings = lint_unit(ast, ast3, yr_get(origin, "file"),
                                yr_get(origin, "mods"), wlevel);
            pr = phase_end(times, ys("lint"), pt, ph);
            times = yr_get(pr, "times");
            pt = yv_l(yr_get(pr, "t"));
            ph = yv_l(yr_get(pr, "h"));
        }
        Yv *gdecls = global_decls(yr_get(ast3, "stmts"));
        Yv *gnames = yav(0);
        long gi = 0;
        while (gi < yv_len(gdecls)) {
            gnames = ya_push(gnames, decl_name(ya_get(gdecls, gi)));
            gi = gi + 1;
        }
        /* The externs, and the init functions `_start` calls by label. */
        Yv *xfns = yav(0);
        Yv *xids = fntab_ids(ext);
        long xi = 0;
        while (xi < yv_len(ext)) {
            xfns = ya_push(xfns, ya_get(ext, xi));
            xi = xi + 1;
        }
        long ii = 0;
        while (ii < yv_len(inits)) {
            Yv *il = ya_get(inits, ii);
            Yv *ityp = yr(3, "k", yv_long(K_tfunc), "args", yav(0),
                          "ret", yr(1, "k", yv_long(K_tvoid)));
            xfns = ya_push(xfns, yr(3, "name", il, "label", il, "typ", ityp));
            xids = ya_push(xids, lbl_new(il));
            ii = ii + 1;
        }
        /* A def needing a closure record is emitted where it is created
         * (gen_decl); every other one is hoisted: a label in st.fns. A
         * call to an extern is no capture either. */
        Yv *cexcl = yav(0);
        long ei = 0;
        while (ei < yv_len(gnames)) {
            cexcl = ya_push(cexcl, ya_get(gnames, ei));
            ei = ei + 1;
        }
        Yv *extnames = fn_names_of(ext);
        ei = 0;
        while (ei < yv_len(extnames)) {
            cexcl = ya_push(cexcl, ya_get(extnames, ei));
            ei = ei + 1;
        }
        Yv *capdefs = capturing_defs(defs, cexcl);
        Yv *hdefs = yav(0);
        /* assign labels + env entries (also pre-binds for calls); the
         * unit's uids count from its base */
        Yv *st = st_new();
        st = yr(15, "ir", yr_get(st, "ir"), "txt", yr_get(st, "txt"), "rodata", yr_get(st, "rodata"),
                "uid", yv_long(base + 1), "fuid", yr_get(st, "fuid"), "loc",
                yr_get(st, "loc"), "env", yr_get(st, "env"), "slots",
                yr_get(st, "slots"), "temp", yr_get(st, "temp"), "self_label", yr_get(st, "self_label"),
                "end_label", yr_get(st, "end_label"), "fns", yr_get(st, "fns"),
                "bodies", yr_get(st, "bodies"), "btext", yr_get(st, "btext"), "blabels", yr_get(st, "blabels"));
        Yv *r = next_uid(st);
        st = yr_get(r, "st");
        Yv *hsyms = yav(0);
        Yv *hids = yav(0);
        long i = 0;
        while (i < yv_len(defs)) {
            Yv *d = ya_get(defs, i);
            if (name_in(capdefs, yr_get(d, "name"))) {
                ;
            } else {
                hdefs = ya_push(hdefs, d);
                Yv *rl = next_uid(st);
                st = yr_get(rl, "st");
                Yv *label = fn_label_of(yv_l(yr_get(rl, "uid")),
                                        yr_get(d, "name"));
                Yv *lid = lbl_new(label);
                hsyms = ya_push(
                    hsyms,
                    yr(3, "name", yr_get(d, "name"), "label", label,
                       "typ", func_type(yr_get(d, "func"))));
                hids = ya_push(hids, lid);
                st = env_define(st, yr_get(d, "name"), ys("func"), 0, lid,
                                ys(""), func_type(yr_get(d, "func")));
                ;
            }
            i = i + 1;
        }
        /* The externs go after the hoisted defs (fix_fn_types and the
         * emission loop read those by position), the globals after both
         * (see fns_kind). */
        Yv *ids0 = yav(0);
        long id0i = 0;
        while (id0i < yv_len(hids)) {
            ids0 = ya_push(ids0, ya_get(hids, id0i));
            id0i = id0i + 1;
        }
        id0i = 0;
        while (id0i < yv_len(xids)) {
            ids0 = ya_push(ids0, ya_get(xids, id0i));
            id0i = id0i + 1;
        }
        Yv *fns0 = yav(0);
        long f0i = 0;
        while (f0i < yv_len(hsyms)) {
            fns0 = ya_push(fns0, ya_get(hsyms, f0i));
            f0i = f0i + 1;
        }
        f0i = 0;
        while (f0i < yv_len(xfns)) {
            fns0 = ya_push(fns0, ya_get(xfns, f0i));
            f0i = f0i + 1;
        }
        st = yr(15, "ir", yr_get(st, "ir"), "txt", yr_get(st, "txt"), "rodata", yr_get(st, "rodata"),
                "uid", yr_get(st, "uid"), "fuid", yr_get(st, "fuid"), "loc",
                yr_get(st, "loc"), "env", yr_get(st, "env"), "slots",
                yr_get(st, "slots"), "temp", yr_get(st, "temp"), "self_label", yr_get(st, "self_label"),
                "end_label", yr_get(st, "end_label"),
                "fns", fntab_of(fns0, ids0), "bodies", yr_get(st, "bodies"),
                "btext", yr_get(st, "btext"), "blabels", yr_get(st, "blabels"));
        Yv *fixed1 = fix_fn_types(st, hdefs, yav(0));
        Yv *fns1 = yav(0);
        long f1i = 0;
        while (f1i < yv_len(fixed1)) {
            fns1 = ya_push(fns1, ya_get(fixed1, f1i));
            f1i = f1i + 1;
        }
        f1i = 0;
        while (f1i < yv_len(xfns)) {
            fns1 = ya_push(fns1, ya_get(xfns, f1i));
            f1i = f1i + 1;
        }
        st = yr(15, "ir", yr_get(st, "ir"), "txt", yr_get(st, "txt"), "rodata", yr_get(st, "rodata"),
                "uid", yr_get(st, "uid"), "fuid", yr_get(st, "fuid"), "loc",
                yr_get(st, "loc"), "env", yr_get(st, "env"), "slots",
                yr_get(st, "slots"), "temp", yr_get(st, "temp"), "self_label", yr_get(st, "self_label"),
                "end_label", yr_get(st, "end_label"),
                "fns", fntab_of(fns1, ids0), "bodies", yr_get(st, "bodies"),
                "btext", yr_get(st, "btext"), "blabels", yr_get(st, "blabels"));
        Yv *gl = app_cells(global_entries(st, gdecls, base),
                           yr_get(ast3, "stmts"));
        Yv *fixedfns = yav(0);
        long fi = 0;
        while (fi < yv_len(fixed1)) {
            fixedfns = ya_push(fixedfns, ya_get(fixed1, fi));
            fi = fi + 1;
        }
        fi = 0;
        while (fi < yv_len(xfns)) {
            fixedfns = ya_push(fixedfns, ya_get(xfns, fi));
            fi = fi + 1;
        }
        fi = 0;
        while (fi < yv_len(gl)) {
            fixedfns = ya_push(fixedfns, ya_get(gl, fi));
            fi = fi + 1;
        }
        Yv *gids = fntab_ids(gl);
        Yv *idsA = ya_slice(ids0, 0, yv_len(ids0));
        long idai = 0;
        while (idai < yv_len(gids)) {
            idsA = ya_push(idsA, ya_get(gids, idai));
            idai = idai + 1;
        }
        if (yv_len(gl) > 0) {
            st = yr(15, "ir", yr_get(st, "ir"), "txt", yr_get(st, "txt"), "rodata",
                    yr_get(st, "rodata"), "uid", yr_get(st, "uid"), "fuid",
                    yr_get(st, "fuid"), "loc", yr_get(st, "loc"), "env",
                    yr_get(st, "env"), "slots", yr_get(st, "slots"), "temp", yr_get(st, "temp"),
                    "self_label", yr_get(st, "self_label"), "end_label",
                    yr_get(st, "end_label"),
                    "fns", fntab_of(fixedfns, idsA), "bodies",
                    yr_get(st, "bodies"), "btext", yr_get(st, "btext"), "blabels", yr_get(st, "blabels"));
            Yv *fixed2 = fix_fn_types(st, hdefs, gnames);
            fixedfns = yav(0);
            fi = 0;
            while (fi < yv_len(fixed2)) {
                fixedfns = ya_push(fixedfns, ya_get(fixed2, fi));
                fi = fi + 1;
            }
            fi = 0;
            while (fi < yv_len(xfns)) {
                fixedfns = ya_push(fixedfns, ya_get(xfns, fi));
                fi = fi + 1;
            }
            fi = 0;
            while (fi < yv_len(gl)) {
                fixedfns = ya_push(fixedfns, ya_get(gl, fi));
                fi = fi + 1;
            }
            ;
        }
        st = yr(15, "ir", yr_get(st, "ir"), "txt", yr_get(st, "txt"), "rodata", yr_get(st, "rodata"),
                "uid", yr_get(st, "uid"), "fuid", yr_get(st, "fuid"), "loc",
                yr_get(st, "loc"), "env", yr_get(st, "env"), "slots",
                yr_get(st, "slots"), "temp", yr_get(st, "temp"), "self_label", yr_get(st, "self_label"),
                "end_label", yr_get(st, "end_label"),
                "fns", fntab_of(fixedfns, idsA), "bodies",
                yr_get(st, "bodies"), "btext", yr_get(st, "btext"), "blabels", yr_get(st, "blabels"));
        /* emit each hoisted body */
        i = 0;
        while (i < yv_len(hdefs)) {
            Yv *d = ya_get(hdefs, i);
            Yv *fids = yr_get(yr_get(st, "fns"), "ids");
            Yv *rf = next_uid(st);
            st = yr_get(rf, "st");
            st = emit_one_fn(st, ya_get(fids, i), yv_l(yr_get(rf, "uid")),
                             yr_get(d, "func"), 0, 0, yav(0), ys(""));
            i = i + 1;
        }
        pr = phase_end(times, ys("emit_fns"), pt, ph);
        times = yr_get(pr, "times");
        pt = yv_l(yr_get(pr, "t"));
        ph = yv_l(yr_get(pr, "h"));
        Yv *exports = unit_exports(yr_get(ast3, "stmts"), hdefs,
                                   yr_get(yr_get(st, "fns"), "syms"));
        Yv *udfl = yav(0);
        if (pkg_base(base)) {
            exports = pkg_exports(exports, gl);
            udfl = unit_dfl(yr_get(ast2, "stmts"), origin);
            ;
        }
        /* The top-level statements with hoisted defs skipped (emitted
         * above, calls go direct to their labels). Variable declarations
         * store to their globals (bind_decl). A def needing a record would
         * be created here like a nested one — but a top-level def can only
         * read globals and functions, so none does. */
        Yv *main_stmts = yav(0);
        Yv *noargs = yav(0);
        long ci = 0;
        while (ci < yv_len(inits)) {
            Yv *cl = ya_get(inits, ci);
            Yv *callee = yr(4, "k", yv_long(K_id), "v", cl, "line", yv_long(0),
                            "col", yv_long(0));
            main_stmts = ya_push(
                main_stmts,
                yr(5, "k", yv_long(K_call), "callee", callee, "args", noargs,
                   "line", yv_long(0), "col", yv_long(0)));
            ci = ci + 1;
        }
        Yv *pstmts = yr_get(ast3, "stmts");
        i = 0; /* the Y source re-lets `i` here; same value, same scope */
        while (i < yv_len(pstmts)) {
            Yv *s = ya_get(pstmts, i);
            if (yv_l(yr_get(s, "k")) == K_decl) {
                if (ys_eq_lit(yr_get(s, "kind"), "def")) {
                    if (name_in(capdefs, yr_get(s, "name"))) {
                        main_stmts = ya_push(main_stmts, s);
                        ;
                    }
                    ;
                } else if (yv_l(yr_get(yr_get(s, "v"), "k")) == K_func) {
                    if (name_in(capdefs, yr_get(s, "name"))) {
                        main_stmts = ya_push(main_stmts, s);
                        ;
                    }
                    ;
                } else {
                    main_stmts = ya_push(main_stmts, s);
                    ;
                }
                ;
            } else {
                main_stmts = ya_push(main_stmts, s);
                ;
            }
            i = i + 1;
        }
        Yv *rm = next_uid(st);
        st = yr_get(rm, "st");
        Yv *init = ys("");
        if (yv_len(name) == 0) {
            /* Only pay for argv materialization when the program or one
             * of its linked units uses it. */
            Yv *want = uses_scan_block(yr_get(ast3, "stmts"),
                                       yr(1, "argv", yv_bool(0)));
            st = emit_one_fn(
                st, lbl_new(ys("_start")), yv_l(yr_get(rm, "uid")),
                yr(6, "params", yav(0), "ptypes", yav(0), "ret",
                   yr(1, "k", yv_long(K_tvoid)), "body",
                   yr(4, "k", yv_long(K_block), "stmts", main_stmts, "line",
                      yv_long(0), "col", yv_long(0)),
                   "line", yv_long(0), "col", yv_long(0)),
                1, yv_b(yr_get(want, "argv")) || yv_b(yr_get(xt, "argv")),
                yav(0), ys(""));
            ;
        } else if (yv_len(main_stmts) > 0) {
            init = arch_fn_label(yv_l(yr_get(rm, "uid")), ys("init"));
            st = emit_one_fn(
                st, lbl_new(init), yv_l(yr_get(rm, "uid")),
                yr(6, "params", yav(0), "ptypes", yav(0), "ret",
                   yr(1, "k", yv_long(K_tvoid)), "body",
                   yr(4, "k", yv_long(K_block), "stmts", main_stmts, "line",
                      yv_long(0), "col", yv_long(0)), "line",
                   yv_long(0), "col", yv_long(0)),
                0, 0, yav(0), ys(""));
            ;
        }
        pr = phase_end(times, ys("emit_start"), pt, ph);
        times = yr_get(pr, "times");
        pt = yv_l(yr_get(pr, "t"));
        ph = yv_l(yr_get(pr, "h"));
        Yv *glabels = yav(0);
        long gk = 0;
        while (gk < yv_len(gl)) {
            Yv *ge = ya_get(gl, gk);
            glabels = ya_push(glabels, yr_get(ge, "label"));
            gk = gk + 1;
        }
        /* Each body's label and the labels it references: what linking
         * shakes by (prune_bodies). The label the emitter recorded beside the
         * body (emit_one_fn); the references are read out of the ITEMS (the
         * same set line_refs_b found in the text: every label operand, the
         * label of a `lea lbl(%rip)`, both labels of a `mov $A-B`). */
        Yv *ubodies = yr_get(st, "bodies");
        Yv *ubtext = yr_get(st, "btext");
        Yv *blabels = yr_get(st, "blabels");
        Yv *brefs = yav(0);
        long bk = 0;
        while (bk < yv_len(ubodies)) {
            brefs = ya_push(brefs, ir_refs(ya_get(ubodies, bk)));
            bk = bk + 1;
        }
        Yv *unit = yr(12, "name", name, "files", yr_get(origin, "files"),
                      "exports", exports, "init", init, "bodies", ubodies,
                      "btext", ubtext, "blob", yav(0), "labels", blabels,
                      "refs", brefs,
                      "rodata", yr_get(st, "rodata"), "globals", glabels, "dfl",
                      udfl);
        return yr(5, "ok", yv_bool(1), "errors", errors, "warnings",
                  warnings, "times", times, "unit", unit);
    }
}

int pkg_base(long base) {
    return base >= 5000000000L;
}

/* A package exports its top-level defs and its globals (including the
 * companion option-cell labels of string globals). Later declarations of
 * the same source name replace earlier exports. */
Yv *pkg_exports(Yv *xs, Yv *gl) {
    Yv *all = yav(0);
    long i = 0;
    while (i < yv_len(xs)) {
        all = ya_push(all, ya_get(xs, i));
        i = i + 1;
    }
    i = 0;
    while (i < yv_len(gl)) {
        Yv *ge = ya_get(gl, i);
        Yv *gn = yr_get(ge, "name");
        Yv *xn = ys("");
        long n = yv_len(gn);
        if (n >= 2 && ys_eq_lit(ys_slice(gn, n - 2, n), "#o")) {
            Yv *bn = export_name(ys_slice(gn, 0, n - 2));
            if (yv_len(bn) > 0) {
                xn = ys_cat(bn, ys("#o"));
                ;
            }
            ;
        } else {
            xn = export_name(gn);
            ;
        }
        if (yv_len(xn) > 0) {
            all = ya_push(
                all, yr(3, "name", xn, "label", yr_get(ge, "label"), "typ",
                       yr_get(ge, "typ")));
            ;
        }
        i = i + 1;
    }
    Yv *out = yav(0);
    long j = 0;
    while (j < yv_len(all)) {
        Yv *e = ya_get(all, j);
        int later = 0;
        long m = j + 1;
        while (!later && m < yv_len(all)) {
            Yv *e2 = ya_get(all, m);
            if (ys_eq(yr_get(e2, "name"), yr_get(e, "name"))) {
                later = 1;
                ;
            }
            m = m + 1;
        }
        if (!later) {
            out = ya_push(out, e);
            ;
        }
        j = j + 1;
    }
    return out;
}

/* Parameter defaults by source-level top-level name; a later definition
 * replaces the earlier entry. */
Yv *unit_dfl(Yv *stmts, Yv *origin) {
    Yv *out = yav(0);
    long i = 0;
    while (i < yv_len(stmts)) {
        Yv *s = ya_get(stmts, i);
        Yv *nm = top_name_in(s, origin);
        /* (not an imported module's: see export_name) */
        if (yv_len(nm) > 0 && ys_index_of(nm, ys(".")) < 0) {
            Yv *keep = yav(0);
            long j = 0;
            while (j < yv_len(out)) {
                Yv *d = ya_get(out, j);
                if (!ys_eq(yr_get(d, "name"), nm)) {
                    keep = ya_push(keep, d);
                    ;
                }
                j = j + 1;
            }
            Yv *vals = dfl_codes(decl_value(s));
            if (yv_len(vals) > 0) {
                keep = ya_push(keep, yr(2, "name", nm, "vals", vals));
                ;
            }
            out = keep;
            ;
        }
        i = i + 1;
    }
    return out;
}

Yv *dfl_codes(Yv *func) {
    Yv *dv = yr_get(func, "defs");
    Yv *out = yav(0);
    int any = 0;
    long i = 0;
    while (i < yv_len(dv)) {
        Yv *d = ya_get(dv, i);
        if (yv_l(yr_get(d, "k")) != K_void) {
            any = 1;
            ;
        }
        out = ya_push(out, lit_code(d));
        i = i + 1;
    }
    if (any) {
        return out;
    } else {
        return yav(0);
    }
}

Yv *lit_code(Yv *d) {
    Yv *k = yr_get(d, "k");
    if (yv_l(k) == K_void) {
        return ys("v");
    } else if (yv_l(k) == K_optarg) {
        return ys("o");
    } else if (yv_l(k) == K_num) {
        return ys_cat(ys("n"), lit_text(d));
    } else if (yv_l(k) == K_str) {
        return ys_cat(ys("s"), lit_text(d));
    } else if (yv_l(k) == K_bool) {
        return ys_cat(ys("b"), lit_text(d));
    } else if (yv_l(k) == K_char) {
        return ys_cat(ys("c"), lit_text(d));
    } else {
        return ys_cat(ys("-"), lit_neg_text(d));
    }
}

Yv *lit_text(Yv *d) {
    return yr_get(d, "v");
}

Yv *lit_neg_text(Yv *d) {
    return yr_get(yr_get(d, "e"), "v");
}

Yv *lit_decode(Yv *c) {
    Yv *t = ys_slice(c, 0, 1);
    Yv *v = ys_slice_from(c, 1);
    if (ys_eq_lit(t, "v")) {
        return normnode(yr(3, "k", yv_long(K_void), "line", yv_long(0), "col",
                           yv_long(0)));
    } else if (ys_eq_lit(t, "o")) {
        return normnode(yr(3, "k", yv_long(K_optarg), "line", yv_long(0), "col",
                           yv_long(0)));
    } else if (ys_eq_lit(t, "n")) {
        return normnode(yr(4, "k", yv_long(K_num), "v", v, "line", yv_long(0),
                           "col", yv_long(0)));
    } else if (ys_eq_lit(t, "s")) {
        return normnode(yr(4, "k", yv_long(K_str), "v", v, "line", yv_long(0),
                           "col", yv_long(0)));
    } else if (ys_eq_lit(t, "b")) {
        return normnode(yr(4, "k", yv_long(K_bool), "v", v, "line", yv_long(0),
                           "col", yv_long(0)));
    } else if (ys_eq_lit(t, "c")) {
        return normnode(yr(4, "k", yv_long(K_char), "v", v, "line", yv_long(0),
                           "col", yv_long(0)));
    } else {
        Yv *num = yr(4, "k", yv_long(K_num), "v", v, "line", yv_long(0), "col",
                     yv_long(0));
        return normnode(yr(5, "k", yv_long(K_un), "op", ys("-"), "e", num, "line",
                           yv_long(0), "col", yv_long(0)));
    }
}

/* A linked unit's `.loc` markers are moved by its file-table offset
 * under -g, and dropped otherwise. */
Yv *link_locs(Yv *body, long off) {
    Yv *parts = ys_split(body, ys("\n.loc "));
    if (yv_len(parts) == 1) {
        return body;
    } else {
        Yv *out = yav(0);
        out = ya_push(out, ya_get(parts, 0));
        long i = 1;
        while (i < yv_len(parts)) {
            Yv *p = ya_get(parts, i);
            if (dbg_lines) {
                long sp = ys_index_of(p, ys(" "));
                Yv *n = ys_slice(p, 0, sp);
                Yv *tail = ys_slice_from(p, sp);
                Yv *loc = ys_cat(ys_cat(ys("\n.loc "),
                                        ys_long(ys_tonum(n) + off)),
                                 tail);
                out = ya_push(out, loc);
                ;
            } else {
                long nl = ys_index_of(p, ys("\n"));
                if (nl >= 0) {
                    out = ya_push(out, ys_slice_from(p, nl));
                    ;
                }
            }
            i = i + 1;
        }
        return ys_join(out, ys(""));
    }
}

/* One unit's rodata entries as text. String entries are exactly [label,
 * len, escaped]; record-type descriptors (ty_desc) are [label, canonical
 * form, quads...]: one per label in the program (ty_seen, emptied by
 * link_units), and two different forms under one label stop the link. */
/* One unit's rodata entries as text, keeping only the blocks a kept body
   reaches AND emitting each distinct literal text once. `refs` is the union
   `shake_refs` gets for arch_consts (the kept bodies' own references plus the
   kept prelude's), so a literal no `lea` names is dead -- measured at 29-92%
   of a program's rodata, and almost always the same 308 bytes, the std
   runtime's error strings and format tables, in every program that does not
   happen to call those functions.

   The interning is at link, not in gen_str_const: most duplicates are
   std-vs-program and std-vs-std, so a per-unit table would miss them, and
   putting one in EmitSt would mean touching all 21 rebuild sites plus the C
   twin for nothing. The FIRST block of a text in link order keeps its own
   label and is the one written; every later block of the same text is a loser,
   recorded in `dup_old`/`dup_new` so the body texts can be relabelled
   (relabel_dups).

   String entries are exactly [label, len, escaped]; record-type descriptors
   (ty_desc) are [label, canonical form, quads...]: one per label in the
   program (ty_seen, emptied by link_units), and two different forms under one
   label stop the link -- a check that stays over EVERY descriptor, reachable
   or not, since two shapes for one type is a program error either way.
   Descriptors need no interning: `tyset_add` already emits one block per
   distinct form.

   The membership tests are asm's hashed labmap, not name_in: 6,727 literals
   against ~30,000 refs would be 200 million string compares. Twice the size,
   because labmap probes linearly and a full table makes every insert walk half
   the slots -- and ONE map for all the units' rodata, because five or six
   builds of a 40,000-entry set at load factor 1 cost 4% of a self-compile. */
Yv *rodata_intern(Yv *pieces, Yv *allrod, Yv *refs) {
    Yv *m = labmap_new(yv_len(refs) * 2 + 64);
    long ri = 0;
    while (ri < yv_len(refs)) {
        m = yr_get(labmap_put(m, ya_get(refs, ri), 1, 0), "map");
        ri = ri + 1;
    }
    long nall = yv_len(allrod);
    /* text -> the index of the winner in `win`, plus loser pairs */
    Yv *texts = labmap_new(nall * 2 + 64);
    Yv *win = yav(0);
    Yv *dup_old = yav(0);
    Yv *dup_new = yav(0);
    long s2 = 0;
    while (s2 < nall) {
        Yv *pair = ya_get(allrod, s2);
        Yv *lbl = ya_get(pair, 0);
        if (yv_len(pair) == 3) {
            if (yv_l(yr_get(labmap_get(m, lbl), "sec")) > 0) {
                /* the key is the escaped text: the 8-byte length is derived
                   from it, so two blocks with one text are one block's worth
                   of bytes */
                Yv *text = ya_get(pair, 2);
                Yv *seen = labmap_get(texts, text);
                if (yv_l(yr_get(seen, "sec")) > 0) {
                    dup_old = ya_push(dup_old, lbl);
                    dup_new = ya_push(dup_new, ya_get(win, yv_l(yr_get(seen, "off"))));
                } else {
                    texts = yr_get(labmap_put(texts, text, 1, yv_len(win)), "map");
                    win = ya_push(win, lbl);
                    Yv *entry =
                        ys_cat(ys_cat(ys_cat(ys_cat(ys_cat(lbl, ys(":\n.quad ")),
                                                 ys_tostring(ya_get(pair, 1))),
                                          ys("\n.string \"")),
                                   text),
                               ys("\"\n"));
                    pieces = ya_push(pieces, entry);
                    ;
                }
            }
        } else {
            Yv *form = ya_get(pair, 1);
            long added = tyset_add(lbl, form);
            if (added < 0) {
                ty_collision(lbl, form);
            }
            if (added > 0 && yv_l(yr_get(labmap_get(m, lbl), "sec")) > 0) {
                /* a descriptor's address is its type's tag: one byte
                 * makes it an address of its own */
                pieces = ya_push(pieces, ys_cat(lbl, ys(":\n.zero 1\n")));
            }
            ;
        }
        s2 = s2 + 1;
    }
    return yr(3, "pieces", pieces, "dup_old", dup_old, "dup_new", dup_new);
}

/* Point a body's `lea` at the label its literal's text ended up with. Only the
   `lea <label>(%rip)` form can name a literal -- the other reference form,
   `mov $A-B`, is arch_consts' trap-string lengths -- so this is the whole job.

   Line by line, and the emitter writes one instruction per line, so a line
   holds at most one `lea`: split once, ask each line, put the body back
   together once. The two shapes before it were both quadratic in the body's
   size -- a `str.replace` per reference (490 ms and 345 MB in asm_text on
   ycc.y) and an index_of per reference over the whole body (+9.23% of every
   compile, 511 million instructions). A per-`lea` scan that re-sliced the
   remainder of the body each time allocated 600 MB for the same work. */
Yv *relabel_dups(Yv *body, Yv *m, Yv *dup_new) {
    Yv *lines = ys_split(body, ys("\n"));
    long i = 0;
    while (i < yv_len(lines)) {
        Yv *ln = ya_get(lines, i);
        long at = ys_index_of(ln, ys("lea "));
        if (at >= 0) {
            Yv *rest = ys_slice(ln, at + 4, yv_len(ln));
            long e = ys_index_of(rest, ys("(%rip)"));
            if (e >= 0) {
                Yv *lbl = ys_slice(rest, 0, e);
                Yv *g = labmap_get(m, lbl);
                if (yv_l(yr_get(g, "sec")) > 0) {
                    /* the label's own length is what is cut out: the winner's
                       label is what gets longer or shorter */
                    ya_set(lines, i,
                           ys_cat(ys_cat(ys_slice(ln, 0, at + 4),
                                         ya_get(dup_new, yv_l(yr_get(g, "off")))),
                                  ys_slice(rest, e, yv_len(rest))));
                }
            }
        }
        i = i + 1;
    }
    return ys_join(lines, ys("\n"));
}

/* The program's assembly text: std units, then its package dependencies
 * (each after those it imports), then the program, shaken together; the
 * arch prelude and constants the kept bodies reach; every unit's rodata
 * and globals. */
/* Two units defining the same `y_`-prefixed name: say so, or return.
 *
 * That prefix is not a namespace: such a def is emitted under its bare name
 * because generated code calls it by a fixed label, so the name IS the
 * interface. The linker keeps one body per label (namemap_build in
 * prune_bodies, and shake_keep with it) and drops the other, silently -- and
 * which one survives follows the order the packages were compiled in:
 *
 *   app depending on a then b:  a.who() and b.who() both printed "from a"
 *   app depending on b then a:  both printed "from b"
 *
 * std's own `y_` bodies are the exception and are meant to be replaced: a
 * program's (or a package's) replaces std's, and link_units drops std's. So
 * only the packages and the program are compared here, and a bin with no
 * package pays nothing for the check. */
static long dup_y_label(Yv *deps, Yv *prog) {
    long nu = yv_len(deps);
    if (nu > 0) {
        Yv *m = labmap_new((nu + 1) * 2 + 16);
        long i = 0;
        while (i <= nu) {
            Yv *u = i < nu ? ya_get(deps, i) : prog;
            Yv *labs = yr_get(u, "labels");
            long k = 0;
            while (k < yv_len(labs)) {
                Yv *lb = ya_get(labs, k);
                if (ys_eq_lit(ys_slice(lb, 0, 2), "y_")) {
                    Yv *g = labmap_get(m, lb);
                    if (yv_l(yr_get(g, "sec")) > 0) {
                        long f = yv_l(yr_get(g, "sec")) - 1;
                        Yv *first = f < nu ? yr_get(ya_get(deps, f), "name")
                                           : yr_get(prog, "name");
                        Yv *msg = ys("error: duplicate y_ name '");
                        msg = ys_cat(msg, lb);
                        msg = ys_cat(msg, ys("': '"));
                        msg = ys_cat(msg, first);
                        msg = ys_cat(msg, ys("' and '"));
                        msg = ys_cat(msg, yr_get(u, "name"));
                        msg = ys_cat(msg,
                                     ys("' both define it -- a y_ name is a "
                                        "fixed label generated code calls by, "
                                        "not a name in a namespace, so only "
                                        "one body could be linked; rename "
                                        "one\n"));
                        puts_(msg);
                        exit_(1);
                        ;
                    } else {
                        m = yr_get(labmap_put(m, lb, i + 1, 0), "map");
                        ;
                    }
                    ;
                }
                k = k + 1;
                ;
            }
            i = i + 1;
            ;
        }
        ;
    }
    return 0;
}

Yv *link_units(Yv *std, Yv *deps, Yv *prog) {
    Yv *units = yav(0);
    long j = 0;
    while (j < yv_len(std)) {
        units = ya_push(units, ya_get(std, j));
        j = j + 1;
    }
    j = 0;
    while (j < yv_len(deps)) {
        units = ya_push(units, ya_get(deps, j));
        j = j + 1;
    }
    long nstd = yv_len(std);
    long nu = yv_len(units);
    Yv *files = yav(0);
    Yv *progfiles = yr_get(prog, "files");
    long k = 0;
    while (k < yv_len(progfiles)) {
        files = ya_push(files, ya_get(progfiles, k));
        k = k + 1;
    }
    Yv *offs = yav(0);
    k = 0;
    while (k < nu) {
        offs = ya_push(offs, yv_long(0));
        k = k + 1;
    }
    k = nu - 1;
    while (k >= 0) {
        Yv *uk = ya_get(units, k);
        ya_set(offs, k, yv_long(yv_len(files)));
        Yv *ufiles = yr_get(uk, "files");
        long f = 0;
        while (f < yv_len(ufiles)) {
            files = ya_push(files, ya_get(ufiles, f));
            f = f + 1;
        }
        k = k - 1;
    }
    /* Package and program runtime labels replace std bodies. */
    Yv *plabels = yav(0);
    long ou = nstd;
    while (ou <= nu) {
        Yv *olab;
        if (ou < nu) {
            olab = yr_get(ya_get(units, ou), "labels");
            ;
        } else {
            olab = yr_get(prog, "labels");
            ;
        }
        long pi = 0;
        while (pi < yv_len(olab)) {
            Yv *pl = ya_get(olab, pi);
            if (ys_eq_lit(ys_slice(pl, 0, 2), "y_")) {
                plabels = ya_push(plabels, pl);
                ;
            }
            pi = pi + 1;
        }
        ou = ou + 1;
    }
    Yv *all = yav(0);
    Yv *alltxt = yav(0);
    /* A pack unit's body, still packed (empty items); decoded in the parts
     * loop below, once the shake has said it is kept. */
    Yv *allblob = yav(0);
    Yv *labels = yav(0);
    Yv *refs = yav(0);
    Yv *fno = yav(0);
    j = 0;
    while (j < nu) {
        Yv *u = ya_get(units, j);
        long f = yv_l(ya_get(offs, j));
        Yv *ub = yr_get(u, "bodies");
        Yv *ubl = yr_get(u, "blob");
        Yv *ul = yr_get(u, "labels");
        Yv *ur = yr_get(u, "refs");
        long b = 0;
        while (b < yv_len(ul)) {
            Yv *lb = ya_get(ul, b);
            int drop = 0;
            if (j < nstd && yv_len(plabels) > 0) {
                if (ys_eq_lit(ys_slice(lb, 0, 2), "y_")) {
                    drop = name_in(plabels, lb);
                    ;
                }
                ;
            }
            if (!drop) {
                if (yv_len(ub) > 0) {
                    all = ya_push(all, ya_get(ub, b));
                    allblob = ya_push(allblob, ys(""));
                } else {
                    all = ya_push(all, yav(0));
                    allblob = ya_push(allblob, ya_get(ubl, b));
                }
                alltxt = ya_push(alltxt, ya_get(yr_get(u, "btext"), b));
                labels = ya_push(labels, lb);
                refs = ya_push(refs, ya_get(ur, b));
                fno = ya_push(fno, yv_long(f));
                ;
            }
            b = b + 1;
        }
        j = j + 1;
    }
    Yv *plab = yr_get(prog, "labels");
    Yv *pbodies = yr_get(prog, "bodies");
    Yv *prefs = yr_get(prog, "refs");
    long pb2 = 0;
    while (pb2 < yv_len(pbodies)) {
        all = ya_push(all, ya_get(pbodies, pb2));
        allblob = ya_push(allblob, ys(""));
        alltxt = ya_push(alltxt, ya_get(yr_get(prog, "btext"), pb2));
        labels = ya_push(labels, ya_get(plab, pb2));
        refs = ya_push(refs, ya_get(prefs, pb2));
        fno = ya_push(fno, yv_long(-1));
        pb2 = pb2 + 1;
    }
    /* Body-level tree shaking comes first: its output is also the root
     * set for shaking the arch prelude, and the kept prelude's references
     * shake the rodata constants. */
    Yv *extra = yav(0);
    Yv *shaken = prune_bodies(labels, refs, extra);
    Yv *keep = yr_get(shaken, "keep");
    Yv *body_refs = yr_get(shaken, "refs");
    Yv *core_lines = arch_prelude_lines();
    int thr = uses_threads(body_refs);
    Yv *pb = prelude_blocks(prelude_with(core_lines, thr));
    Yv *ps = shake_prelude(pb, body_refs);
    /* A kept prelude block may call a Y helper (none does today): the
     * helper is kept too, and everything shaken again from there. */
    Yv *bmap = namemap_build(labels);
    Yv *more = unkept_refs(yr_get(ps, "refs"), bmap, keep);
    while (yv_len(more) > 0) {
        long mi = 0;
        while (mi < yv_len(more)) {
            extra = ya_push(extra, ya_get(more, mi));
            mi = mi + 1;
        }
        shaken = prune_bodies(labels, refs, extra);
        keep = yr_get(shaken, "keep");
        body_refs = yr_get(shaken, "refs");
        if (!thr && uses_threads(body_refs)) {
            thr = 1;
            pb = prelude_blocks(prelude_with(core_lines, thr));
        }
        ps = shake_prelude(pb, body_refs);
        more = unkept_refs(yr_get(ps, "refs"), bmap, keep);
    }
    /* Everything the kept code can reach: the kept bodies' own references plus
       the kept prelude's. Computed before the rodata, which uses it as its
       reachability set. */
    Yv *const_refs = yav(0);
    long cr = 0;
    while (cr < yv_len(yr_get(ps, "refs"))) {
        const_refs = ya_push(const_refs, ya_get(yr_get(ps, "refs"), cr));
        cr = cr + 1;
    }
    long ci = 0;
    while (ci < yv_len(body_refs)) {
        const_refs = ya_push(const_refs, ya_get(body_refs, ci));
        ci = ci + 1;
    }
    /* The rodata first, because it decides the labels the bodies use: one
       block per distinct literal text, the losers recorded. Every unit's
       rodata goes through ONE call: the reachability set is the same for all
       of them, and building the map per unit cost 4% of a self-compile (a
       hash map filled to load factor 1 probes linearly, so five or six builds
       of a 40,000-entry set are quadratic). */
    tyset_reset();
    Yv *allrod = yav(0);
    Yv *gls = yav(0);
    long ju = 0;
    while (ju < nu) {
        Yv *u = ya_get(units, ju);
        Yv *ur = yr_get(u, "rodata");
        long ri2 = 0;
        while (ri2 < yv_len(ur)) {
            allrod = ya_push(allrod, ya_get(ur, ri2));
            ri2 = ri2 + 1;
        }
        Yv *ug = yr_get(u, "globals");
        long gi = 0;
        while (gi < yv_len(ug)) {
            gls = ya_push(gls, ya_get(ug, gi));
            gi = gi + 1;
        }
        ju = ju + 1;
    }
    Yv *progrod = yr_get(prog, "rodata");
    long pri = 0;
    while (pri < yv_len(progrod)) {
        allrod = ya_push(allrod, ya_get(progrod, pri));
        pri = pri + 1;
    }
    Yv *pg = yr_get(prog, "globals");
    long pgi = 0;
    while (pgi < yv_len(pg)) {
        gls = ya_push(gls, ya_get(pg, pgi));
        pgi = pgi + 1;
    }
    Yv *interned = rodata_intern(yav(0), allrod, const_refs);
    Yv *rodpieces = yr_get(interned, "pieces");
    Yv *dup_old = yr_get(interned, "dup_old");
    /* loser label -> index into dup_new, so a body's refs can be relabelled in
       one probe each. */
    Yv *dupmap = labmap_new(yv_len(dup_old) * 2 + 64);
    long di = 0;
    while (di < yv_len(dup_old)) {
        dupmap = yr_get(labmap_put(dupmap, ya_get(dup_old, di), 1, di), "map");
        di = di + 1;
    }
    /* The header, then the prelude: the `.section .text` the bodies go in and
       the blocks they call. The bodies follow this part and precede the
       rodata, which is where they were in the text. */
    Yv *parts = yav(0);
    Yv *head = arch_header();
    if (dbg_lines) {
        head = ys_cat(file_dirs(files), head);
        ;
    }
    parts = ya_push(parts, part_text(ys_cat(ys_cat(head, arch_text()),
                                           yr_get(ps, "text"))));
    /* The bodies, kept, as parts: their items, with the `.loc` markers moved
       to the unit's place in the program's file table. Every body is items
       now -- a unit read from a pack came with them (pack_body). */
    long ab = 0;
    while (ab < yv_len(all)) {
        if (yv_b(ya_get(keep, ab))) {
            long kf = yv_l(ya_get(fno, ab));
            Yv *kb = ya_get(all, ab);
            if (yv_len(kb) == 0) { kb = unpack_body(ya_get(allblob, ab)); }
            if (yv_len(dup_old) > 0) {
                kb = ir_relabel(kb, dupmap, yr_get(interned, "dup_new"));
            }
            long off = 0;
            if (kf >= 0) { off = kf; }
            parts = ya_push(parts, part_ir(kb, ya_get(alltxt, ab), off,
                                           dbg_lines));
        }
        ab = ab + 1;
    }
    /* The rodata, then the .bss cells: text. */
    Yv *consts_text = shake_refs(arch_consts(), const_refs);
    parts = ya_push(parts, part_text(ys_cat(arch_rodata(), consts_text)));
    parts = ya_push(parts, part_text(ys_join(rodpieces, ys(""))));
    Yv *heap_text = shake_refs(arch_heap_cells(), const_refs);
    if (yv_len(gls) > 0 || yv_len(heap_text) > 0) {
        Yv *gpieces = yav(0);
        gpieces = ya_push(gpieces, arch_bss());
        gpieces = ya_push(gpieces, heap_text);
        long gk = 0;
        while (gk < yv_len(gls)) {
            gpieces = ya_push(gpieces, arch_global_cell(ya_get(gls, gk)));
            gk = gk + 1;
        }
        parts = ya_push(parts, part_text(ys_join(gpieces, ys(""))));
        ;
    }
    return parts;
}

/* The parts as assembly text, what -S prints: the items rendered back to the
   text they replace (ir_render_all), the text parts as they are. */
Yv *link_text(Yv *parts) {
    Yv *pieces = yav(0);
    long i = 0;
    while (i < yv_len(parts)) {
        Yv *p = ya_get(parts, i);
        if (yv_len(yr_get(p, "ir")) > 0) {
            /* the render has no newline of its own, so the line is closed
               here */
            pieces = ya_push(pieces, ir_render_all(yr_get(p, "ir"),
                                                   yr_get(p, "txt"),
                                                   yv_b(yr_get(p, "loc")),
                                                   yv_l(yr_get(p, "fno"))));
            pieces = ya_push(pieces, ys("\n"));
            ;
        } else {
            /* a text part already ends its lines (the arch text does; a body
               the pack carried does not, and gets one here) */
            Yv *t = yr_get(p, "text");
            Yv *last = ys_slice_from(t, yv_len(t) - 1);
            int nl = yv_len(t) > 0 && yv_len(last) == 1 && ys_eq_lit(last, "\n");
            if (yv_len(t) > 0 && !nl) {
                pieces = ya_push(pieces, ys_cat(t, ys("\n")));
            } else {
                pieces = ya_push(pieces, t);
            };
        };
        i = i + 1;
    }
    return ys_join(pieces, ys(""));
}

/* ── the std pack ───────────────────────────────────────────────────────
 * The std units, compiled ahead of time and carried by the ycc binary
 * itself (`ycc --std-pack FILE` writes them; the build appends that file
 * to the ycc that wrote it, see ycc.y self_pack): a program then links
 * them as they are instead of compiling the runtime from source every
 * time. A pack is text: a version line, the number of units, then each
 * unit as its name and its fields — every field a netstring
 * (`<len>:<bytes>`), every list its count followed by its items, and a
 * unit's fields one netstring together, so a reader steps over a unit it
 * does not want. Export types use tcode/tdecode, and package objects
 * reuse the same unit-field encoding. */

Yv *pack_version(void) {
    return ys("ycc-std-pack 6\n");
}

Yv *obj_version(void) {
    return ys("ycc-unit 5\n");
}

Yv *pack_put(Yv *out, Yv *s) {
    out = ya_push(out, ys_long(yv_len(s)));
    out = ya_push(out, ys(":"));
    out = ya_push(out, s);
    return out;
}

Yv *pack_strs(Yv *out, Yv *xs) {
    out = pack_put(out, ys_long(yv_len(xs)));
    long i = 0;
    while (i < yv_len(xs)) {
        out = pack_put(out, ya_get(xs, i));
        i = i + 1;
    }
    return out;
}

/* A list of lists (a unit's bodies' raw lines): each item a count and its
 * own items, so a reader walks one body's lines without another's. */
Yv *pack_strss(Yv *out, Yv *xss) {
    out = pack_put(out, ys_long(yv_len(xss)));
    long i = 0;
    while (i < yv_len(xss)) {
        out = pack_strs(out, ya_get(xss, i));
        i = i + 1;
    }
    return out;
}

/* ── a body's ITEMS, as a pack or an object carries them ──────────────────
 * A body used to travel as the assembly text it renders to (unit_body_text):
 * the pack was 146,681 bytes of it, and a program that linked one lexed it
 * back. Since stage 2c the emitter's items are what the assembler wants, so
 * the pack carries those. Two things cannot travel as they are:
 *
 *   a label id. Ids are minted per run (labels.y's counter), and a pack is
 *   written by one build and read by the next, so an id means nothing to the
 *   reader. A label field travels as its NAME and the reader mints the id for
 *   it -- what the text path did with `call y_alloc`, and the only thing both
 *   builds agree on.
 *   a raw-line index. IR_TEXT items index a body's own lines (emit_one_fn
 *   emits each function with a fresh `txt`), and those lines are the unit's
 *   `btext`, which travels beside the items.
 *
 * The encoding: per item a byte for the form, then each operand's field words
 * in the order the form table lists them -- a register's two, a memory
 * operand's five, a label's, an immediate's one. So the reader needs no width
 * of its own. A word is one byte when it is 0..125, three when it is a small
 * negative or a 126..65535 positive (a 126 or 127 tag, then two bytes little
 * endian), and nine for anything wider (a 255 tag, then eight). Registers,
 * sizes, scales and the small displacements of a frame are one byte each.
 * (125, not 126: 126 and 127 are the tags, and a 126 written as its own byte
 * would read back as one -- the `.loc 1 126` of a std body, which desynced
 * the whole body by two bytes when it did.) */
static Yv *pack_word(Yv *out, long v) {
    if (v >= 0 && v < 126) {
        out = ya_push(out, ys_chr(v));
    } else if (v < 0 && v > -65536) {
        long u = 65536 + v;
        out = ya_push(out, ys_chr(127));
        out = ya_push(out, ys_chr(u & 255));
        out = ya_push(out, ys_chr((u >> 8) & 255));
    } else if (v <= 65535) {
        out = ya_push(out, ys_chr(126));
        out = ya_push(out, ys_chr(v & 255));
        out = ya_push(out, ys_chr((v >> 8) & 255));
    } else {
        out = ya_push(out, ys_chr(255));
        long sh = 0;
        long i = 0;
        while (i < 8) {
            out = ya_push(out, ys_chr((v >> sh) & 255));
            sh = sh + 8;
            i = i + 1;
        }
    }
    return out;
}

static Yv *pack_lbl(Yv *out, long id) {
    if (id < 0) {
        out = ya_push(out, ys_chr(0));
    } else {
        Yv *nm = lname(yv_long(id));
        out = ya_push(out, ys_chr(1));
        out = pack_word(out, yv_len(nm));
        out = ya_push(out, nm);
    }
    return out;
}

/* One body as the pack carries it: the items above, item by item. */
static Yv *pack_body(Yv *u, long b) {
    Yv *ir = ya_get(yr_get(u, "bodies"), b);
    Yv *out = yav(0);
    long at = 0;
    while (at < yv_len(ir)) {
        long f = yv_l(ya_get(ir, at));
        out = ya_push(out, ys_chr(f & 255));
        if (f == IR_LABEL) {
            out = pack_lbl(out, yv_l(ya_get(ir, at + 1)));
        } else if (f == IR_LOC) {
            out = pack_word(out, yv_l(ya_get(ir, at + 1)));
            out = pack_word(out, yv_l(ya_get(ir, at + 2)));
        } else if (f == IR_TEXT) {
            out = pack_word(out, yv_l(ya_get(ir, at + 1)));
        } else {
            Yv *kinds = yr_get(ir_form(f), "kinds");
            long ki = 0;
            long wp = at + 1;
            while (ki < yv_len(kinds)) {
                long k = yv_l(ya_get(kinds, ki));
                if (k == O_LBL) {
                    out = pack_lbl(out, yv_l(ya_get(ir, wp)));
                } else if (k == O_DIFF) {
                    out = pack_lbl(out, yv_l(ya_get(ir, wp)));
                    out = pack_lbl(out, yv_l(ya_get(ir, wp + 1)));
                } else if (k == O_MEM || k == O_MEM0) {
                    out = pack_word(out, yv_l(ya_get(ir, wp)));
                    out = pack_word(out, yv_l(ya_get(ir, wp + 1)));
                    out = pack_word(out, yv_l(ya_get(ir, wp + 2)));
                    out = pack_word(out, yv_l(ya_get(ir, wp + 3)));
                    out = pack_lbl(out, yv_l(ya_get(ir, wp + 4)));
                } else {
                    out = pack_word(out, yv_l(ya_get(ir, wp)));
                    if (ir_kind_words(k) > 1) {
                        out = pack_word(out, yv_l(ya_get(ir, wp + 1)));
                    }
                }
                wp = wp + ir_kind_words(k);
                ki = ki + 1;
            }
        }
        at = at + IR_W;
    }
    return ys_join(out, ys(""));
}

/* A unit's bodies as the pack carries them: the items (pack_body), one blob
 * each. */
static Yv *pack_bodies(Yv *u) {
    Yv *bodies = yr_get(u, "bodies");
    Yv *out = yav(0);
    long b = 0;
    while (b < yv_len(bodies)) {
        out = ya_push(out, pack_body(u, b));
        b = b + 1;
    }
    return out;
}

static long word_w(Yv *b, long at);
static long unpack_word(Yv *b, long at);
static long unpack_lbl(Yv *b, long at);
static long lbl_w(Yv *b, long at);

/* One body read back (unit_read): the same items, with a label name minted to
 * an id of this run and every field word the item does not use left 0, which
 * is what the emitter wrote in it. */
static Yv *unpack_body(Yv *blob) {
    Yv *b = bytes_of(blob);
    long n = yv_len(b);
    Yv *ir = yav(0);
    long at = 0;
    while (at < n) {
        long f = yv_l(ya_get(b, at));
        at = at + 1;
        long w[7] = {0, 0, 0, 0, 0, 0, 0};
        if (f == IR_LABEL) {
            w[0] = unpack_lbl(b, at);
            at = at + lbl_w(b, at);
        } else if (f == IR_LOC) {
            w[0] = unpack_word(b, at);
            at = at + word_w(b, at);
            w[1] = unpack_word(b, at);
            at = at + word_w(b, at);
        } else if (f == IR_TEXT) {
            w[0] = unpack_word(b, at);
            at = at + word_w(b, at);
        } else {
            Yv *kinds = yr_get(ir_form(f), "kinds");
            long ki = 0;
            long wp = 0;
            while (ki < yv_len(kinds)) {
                long k = yv_l(ya_get(kinds, ki));
                long nw = ir_kind_words(k);
                if (k == O_LBL) {
                    w[wp] = unpack_lbl(b, at);
                    at = at + lbl_w(b, at);
                } else if (k == O_DIFF) {
                    w[wp] = unpack_lbl(b, at);
                    at = at + lbl_w(b, at);
                    w[wp + 1] = unpack_lbl(b, at);
                    at = at + lbl_w(b, at);
                } else if (k == O_MEM || k == O_MEM0) {
                    w[wp] = unpack_word(b, at);
                    at = at + word_w(b, at);
                    w[wp + 1] = unpack_word(b, at);
                    at = at + word_w(b, at);
                    w[wp + 2] = unpack_word(b, at);
                    at = at + word_w(b, at);
                    w[wp + 3] = unpack_word(b, at);
                    at = at + word_w(b, at);
                    w[wp + 4] = unpack_lbl(b, at);
                    at = at + lbl_w(b, at);
                } else {
                    w[wp] = unpack_word(b, at);
                    at = at + word_w(b, at);
                    if (nw > 1) {
                        w[wp + 1] = unpack_word(b, at);
                        at = at + word_w(b, at);
                    }
                }
                wp = wp + nw;
                ki = ki + 1;
            }
        }
        /* word by word into `ir`: ir_push would hand back a whole new array
         * per item, which for a pack's 7,713 items is 1.9GB of copying */
        ir = ya_push(ir, yv_long(f));
        ir = ya_push(ir, yv_long(w[0]));
        ir = ya_push(ir, yv_long(w[1]));
        ir = ya_push(ir, yv_long(w[2]));
        ir = ya_push(ir, yv_long(w[3]));
        ir = ya_push(ir, yv_long(w[4]));
        ir = ya_push(ir, yv_long(w[5]));
        ir = ya_push(ir, yv_long(w[6]));
    }
    return ir;
}

/* How many bytes the word at `at` takes: its tag byte says (see pack_word). */
static long word_w(Yv *b, long at) {
    long t = yv_l(ya_get(b, at));
    if (t < 126) { return 1; } else if (t == 255) { return 9; } else { return 3; }
}

static long unpack_word(Yv *b, long at) {
    long t = yv_l(ya_get(b, at));
    long v = 0;
    if (t < 126) {
        v = t;
    } else if (t == 255) {
        long sh = 0;
        long i = 0;
        while (i < 8) {
            v = v + yv_l(ya_get(b, at + 1 + i)) * (1 << sh);
            sh = sh + 8;
            i = i + 1;
        }
    } else {
        v = yv_l(ya_get(b, at + 1)) + yv_l(ya_get(b, at + 2)) * 256;
        if (t == 127) { v = v - 65536; }
    }
    return v;
}

/* A label field: none (tag 0) or a name -- an id of this run, interned as the
 * text path interned `call y_alloc`'s operand. */
static long unpack_lbl(Yv *b, long at) {
    if (yv_l(ya_get(b, at)) == 0) {
        return -1;
    } else {
        long n = unpack_word(b, at + 1);
        long p = at + 1 + word_w(b, at + 1);
        return yv_l(lbl_new(from_bytes(ya_slice(b, p, p + n))));
    }
}

/* How many bytes the label field at `at` takes. */
static long lbl_w(Yv *b, long at) {
    if (yv_l(ya_get(b, at)) == 0) {
        return 1;
    } else {
        return 1 + word_w(b, at + 1) + unpack_word(b, at + 1);
    }
}

/* A complete type encoding for std packs and package objects. It keeps
 * every type kind and record shape, unlike the user-facing tstr format. */
Yv *tcode(Yv *t) {
    if (tcode_refs == NULL) {
        tcode_refs = yav(0);
    }
    return ys_join(tcode_go(yav(0), t), ys(""));
}

Yv *tcode_go(Yv *out, Yv *t) {
    Yv *k = yr_get(t, "k");
    if (yv_l(k) == K_tlong) {
        return ya_push(out, ys("l"));
    } else if (yv_l(k) == K_tbyte) {
        return ya_push(out, ys("b"));
    } else if (yv_l(k) == K_tfloat) {
        return ya_push(out, ys("f"));
    } else if (yv_l(k) == K_tbool) {
        return ya_push(out, ys("o"));
    } else if (yv_l(k) == K_tstr) {
        return ya_push(out, ys("s"));
    } else if (yv_l(k) == K_tvoid) {
        return ya_push(out, ys("v"));
    } else if (yv_l(k) == K_tunk) {
        return ya_push(out, ys("u"));
    } else if (yv_l(k) == K_tnone) {
        return ya_push(out, ys("n"));
    } else if (yv_l(k) == K_tname) {
        out = ya_push(out, ys("N"));
        return pack_put(out, yr_get(t, "name"));
    } else if (yv_l(k) == K_tptr) {
        out = ya_push(out, ys("*"));
        return tcode_go(out, yr_get(t, "to"));
    } else if (yv_l(k) == K_tarr) {
        out = ya_push(out, ys("["));
        return tcode_go(out, yr_get(t, "of"));
    } else if (yv_l(k) == K_topt) {
        out = ya_push(out, ys("?"));
        return tcode_go(out, yr_get(t, "of"));
    } else if (yv_l(k) == K_tarrfix) {
        out = ya_push(out, ys("F"));
        out = pack_put(out, ys_long(yv_l(yr_get(t, "n"))));
        return tcode_go(out, yr_get(t, "of"));
    } else if (yv_l(k) == K_tmap) {
        out = ya_push(out, ys("M"));
        out = tcode_go(out, yr_get(t, "key"));
        return tcode_go(out, yr_get(t, "of"));
    } else if (yv_l(k) == K_tfunc) {
        out = ya_push(out, ys(">"));
        out = tcode_list(out, yr_get(t, "args"));
        return tcode_go(out, yr_get(t, "ret"));
    } else if (yv_l(k) == K_tunion) {
        out = ya_push(out, ys("U"));
        return tcode_list(out, yr_get(t, "ts"));
    } else if (yv_l(k) == K_tparams) {
        out = ya_push(out, ys("T"));
        return tcode_list(out, yr_get(t, "ts"));
    } else if (yv_l(k) == K_tpat) {
        out = ya_push(out, ys("P"));
        return pack_strs(out, yr_get(t, "names"));
    } else if (yv_l(k) == K_tref) {
        /* a recursive alias: spelled out where it is met first, "q" and
           its unit id inside (tcode_refs: the trefs being spelled out) */
        Yv *tmp = yr_get(t, "tmp");
        if (name_in(tcode_refs, tmp)) {
            out = ya_push(out, ys("q"));
            return pack_put(out, tmp);
        } else {
            out = ya_push(out, ys("Q"));
            out = pack_put(out, yr_get(t, "name"));
            out = pack_put(out, tmp);
            tcode_refs = ya_push(tcode_refs, tmp);
            out = tcode_go(out, yr_get(t, "to"));
            tcode_refs = ya_slice(tcode_refs, 0, yv_len(tcode_refs) - 1);
            return out;
        }
    } else if (yv_l(k) == K_trec) {
        out = ya_push(out, ys("R"));
        Yv *fs = yr_get(t, "fields");
        out = pack_put(out, ys_long(yv_len(fs)));
        long i = 0;
        while (i < yv_len(fs)) {
            Yv *f = ya_get(fs, i);
            /* an optional field is `name?` (tdecode_go) */
            Yv *fname = yr_get(f, "name");
            if (yv_b(yr_get(f, "opt"))) {
                fname = ys_cat(fname, ys("?"));
            }
            out = pack_put(out, fname);
            out = tcode_go(out, yr_get(f, "typ"));
            i = i + 1;
        }
        return out;
    } else {
        puts_(ys_cat(ys_cat(ys("ycc: internal error: no code for type kind "),
                            ktag(yv_l(k))),
                     ys("\n")));
        exit_(1);
        return out;
    }
}

Yv *tcode_list(Yv *out, Yv *ts) {
    out = pack_put(out, ys_long(yv_len(ts)));
    long i = 0;
    while (i < yv_len(ts)) {
        out = tcode_go(out, ya_get(ts, i));
        i = i + 1;
    }
    return out;
}

Yv *tdecode(Yv *s) {
    if (tdec_encs == NULL) {
        tdec_encs = yav(0);
        tdec_refs = yav(0);
    }
    return tdecode_go(yr(2, "s", s, "p", yv_long(0)));
}

Yv *tdecode_go(Yv *cur) {
    Yv *s = yr_get(cur, "s");
    long p = yv_l(yr_get(cur, "p"));
    Yv *c = ys_slice(s, p, p + 1);
    yr_set(cur, "p", yv_long(p + 1));
    if (ys_eq_lit(c, "l")) {
        return normnode(yr(1, "k", yv_long(K_tlong)));
    } else if (ys_eq_lit(c, "b")) {
        return normnode(yr(1, "k", yv_long(K_tbyte)));
    } else if (ys_eq_lit(c, "f")) {
        return normnode(yr(1, "k", yv_long(K_tfloat)));
    } else if (ys_eq_lit(c, "o")) {
        return normnode(yr(1, "k", yv_long(K_tbool)));
    } else if (ys_eq_lit(c, "s")) {
        return normnode(yr(1, "k", yv_long(K_tstr)));
    } else if (ys_eq_lit(c, "v")) {
        return normnode(yr(1, "k", yv_long(K_tvoid)));
    } else if (ys_eq_lit(c, "u")) {
        return normnode(yr(1, "k", yv_long(K_tunk)));
    } else if (ys_eq_lit(c, "n")) {
        return normnode(yr(1, "k", yv_long(K_tnone)));
    } else if (ys_eq_lit(c, "N")) {
        return normnode(yr(2, "k", yv_long(K_tname), "name", pack_get(cur)));
    } else if (ys_eq_lit(c, "*")) {
        return normnode(yr(2, "k", yv_long(K_tptr), "to", tdecode_go(cur)));
    } else if (ys_eq_lit(c, "[")) {
        return normnode(yr(2, "k", yv_long(K_tarr), "of", tdecode_go(cur)));
    } else if (ys_eq_lit(c, "?")) {
        return normnode(yr(2, "k", yv_long(K_topt), "of", tdecode_go(cur)));
    } else if (ys_eq_lit(c, "F")) {
        long n = pack_num(cur);
        return normnode(yr(3, "k", yv_long(K_tarrfix), "of", tdecode_go(cur), "n",
                          yv_long(n)));
    } else if (ys_eq_lit(c, "M")) {
        Yv *kt = tdecode_go(cur);
        return normnode(yr(3, "k", yv_long(K_tmap), "key", kt, "of",
                          tdecode_go(cur)));
    } else if (ys_eq_lit(c, ">")) {
        Yv *args = tdecode_list(cur);
        return normnode(yr(3, "k", yv_long(K_tfunc), "args", args, "ret",
                          tdecode_go(cur)));
    } else if (ys_eq_lit(c, "U")) {
        return normnode(yr(2, "k", yv_long(K_tunion), "ts", tdecode_list(cur)));
    } else if (ys_eq_lit(c, "T")) {
        return normnode(yr(2, "k", yv_long(K_tparams), "ts", tdecode_list(cur)));
    } else if (ys_eq_lit(c, "P")) {
        return normnode(yr(2, "k", yv_long(K_tpat), "names", pack_get_strs(cur)));
    } else if (ys_eq_lit(c, "Q")) {
        /* a tref (tcode): a fresh unit id, `to` read with the "q"s inside
           it pointing back at it (tdec_encs/tdec_refs) */
        Yv *name = pack_get(cur);
        Yv *enc = pack_get(cur);
        tdec_n = tdec_n + 1;
        Yv *r = yr(4, "k", yv_long(K_tref), "name", name, "tmp",
                   ys_cat(ys("~"), ys_long(tdec_n)), "to", yr(1, "k", yv_long(K_tnone)));
        tdec_encs = ya_push(tdec_encs, enc);
        tdec_refs = ya_push(tdec_refs, r);
        yr_set(r, "to", tdecode_go(cur));
        tdec_encs = ya_slice(tdec_encs, 0, yv_len(tdec_encs) - 1);
        tdec_refs = ya_slice(tdec_refs, 0, yv_len(tdec_refs) - 1);
        return normnode(r);
    } else if (ys_eq_lit(c, "q")) {
        Yv *enc = pack_get(cur);
        long i = yv_len(tdec_encs) - 1;
        while (i > 0 && !ys_eq(ya_get(tdec_encs, i), enc)) {
            i = i - 1;
        }
        return normnode(ya_get(tdec_refs, i));
    } else {
        Yv *fields = yav(0);
        long n = pack_num(cur);
        long i = 0;
        while (i < n) {
            Yv *fname = pack_get(cur);
            /* `name?`: an optional field (tcode_go) */
            int fopt = yv_len(fname) > 0 && ys_byte_at(fname, yv_len(fname) - 1) == '?';
            if (fopt) {
                fname = ys_slice(fname, 0, yv_len(fname) - 1);
            }
            Yv *typ = tdecode_go(cur);
            fields = ya_push(fields, yr(3, "name", fname, "opt", yv_bool(fopt), "typ", typ));
            i = i + 1;
        }
        return normnode(yr(2, "k", yv_long(K_trec), "fields", fields));
    }
}

Yv *tdecode_list(Yv *cur) {
    Yv *out = yav(0);
    long n = pack_num(cur);
    long i = 0;
    while (i < n) {
        out = ya_push(out, tdecode_go(cur));
        i = i + 1;
    }
    return out;
}

/* A unit's exports and parameter defaults: its public interface. */
Yv *pack_iface(Yv *out, Yv *unit) {
    Yv *xs = yr_get(unit, "exports");
    out = pack_put(out, ys_long(yv_len(xs)));
    long j = 0;
    while (j < yv_len(xs)) {
        Yv *x = ya_get(xs, j);
        out = pack_put(out, yr_get(x, "name"));
        out = pack_put(out, yr_get(x, "label"));
        out = pack_put(out, tcode(yr_get(x, "typ")));
        j = j + 1;
    }
    Yv *ds = yr_get(unit, "dfl");
    out = pack_put(out, ys_long(yv_len(ds)));
    j = 0;
    while (j < yv_len(ds)) {
        Yv *d = ya_get(ds, j);
        out = pack_put(out, yr_get(d, "name"));
        out = pack_strs(out, yr_get(d, "vals"));
        j = j + 1;
    }
    return out;
}

/* One unit's fields. */
Yv *pack_unit_fields(Yv *unit) {
    Yv *out = yav(0);
    out = pack_strs(out, yr_get(unit, "files"));
    out = pack_iface(out, unit);
    out = pack_put(out, yr_get(unit, "init"));
    out = pack_strs(out, pack_bodies(unit));
    out = pack_strss(out, yr_get(unit, "btext"));
    out = pack_strs(out, yr_get(unit, "labels"));
    Yv *rf = yr_get(unit, "refs");
    out = pack_put(out, ys_long(yv_len(rf)));
    long j = 0;
    while (j < yv_len(rf)) {
        out = pack_strs(out, ya_get(rf, j));
        j = j + 1;
    }
    Yv *rd = yr_get(unit, "rodata");
    out = pack_put(out, ys_long(yv_len(rd)));
    j = 0;
    while (j < yv_len(rd)) {
        out = pack_strs(out, ya_get(rd, j));
        j = j + 1;
    }
    out = pack_strs(out, yr_get(unit, "globals"));
    return ys_join(out, ys(""));
}

/* The pack of `units`. */
Yv *std_pack(Yv *units) {
    Yv *out = yav(0);
    out = ya_push(out, pack_version());
    out = pack_put(out, ys_long(yv_len(units)));
    long i = 0;
    while (i < yv_len(units)) {
        Yv *u = ya_get(units, i);
        out = pack_put(out, yr_get(u, "name"));
        out = pack_put(out, pack_unit_fields(u));
        i = i + 1;
    }
    return ys_join(out, ys(""));
}

/* Reading a pack: `cur` is the text and the position in it. pack_len
 * reads a netstring's length, leaving the cursor at its text. */
long pack_len(Yv *cur) {
    Yv *s = yr_get(cur, "s");
    long p = yv_l(yr_get(cur, "p"));
    long n = 0;
    long c = ys_byte_at(s, p);
    while (c != 58 && p < yv_len(s)) {
        n = n * 10 + c - 48;
        p = p + 1;
        c = ys_byte_at(s, p);
    }
    yr_set(cur, "p", yv_long(p + 1));
    return n;
}

Yv *pack_get(Yv *cur) {
    long n = pack_len(cur);
    long p = yv_l(yr_get(cur, "p"));
    Yv *s = yr_get(cur, "s");
    yr_set(cur, "p", yv_long(p + n));
    return ys_slice(s, p, p + n);
}

long pack_num(Yv *cur) {
    return ys_tonum(pack_get(cur));
}

Yv *pack_get_strs(Yv *cur) {
    long n = pack_num(cur);
    Yv *out = yav(0);
    long i = 0;
    while (i < n) {
        out = ya_push(out, pack_get(cur));
        i = i + 1;
    }
    return out;
}

/* The unit `name`, from its fields at the cursor. Only decode export
 * types when the unit is bound by a caller. */
Yv *unit_read(Yv *cur, Yv *name, int bound) {
    Yv *files = pack_get_strs(cur);
    Yv *xs = yav(0);
    long nx = pack_num(cur);
    long j = 0;
    while (j < nx) {
        Yv *xn = pack_get(cur);
        Yv *xl = pack_get(cur);
        Yv *tc = pack_get(cur);
        Yv *xt = yr(1, "k", yv_long(K_tnone));
        if (bound) {
            xt = tdecode(tc);
            ;
        }
        xs = ya_push(xs, yr(3, "name", xn, "label", xl, "typ", xt));
        j = j + 1;
    }
    Yv *dfl = yav(0);
    long nf = pack_num(cur);
    j = 0;
    while (j < nf) {
        Yv *dn = pack_get(cur);
        dfl = ya_push(dfl, yr(2, "name", dn, "vals", pack_get_strs(cur)));
        j = j + 1;
    }
    Yv *init = pack_get(cur);
    /* The bodies stay packed: a link decodes only the ones the shake keeps
     * (they are the only ones it assembles), which is what the text path did
     * by reading a body's text only when it kept it. */
    Yv *blob = pack_get_strs(cur);
    long nb = pack_num(cur);
    Yv *btext = yav(0);
    long bi = 0;
    while (bi < nb) {
        btext = ya_push(btext, pack_get_strs(cur));
        bi = bi + 1;
    }
    Yv *labels = pack_get_strs(cur);
    Yv *refs = yav(0);
    long nr = pack_num(cur);
    j = 0;
    while (j < nr) {
        refs = ya_push(refs, pack_get_strs(cur));
        j = j + 1;
    }
    Yv *rodata = yav(0);
    long nd = pack_num(cur);
    j = 0;
    while (j < nd) {
        rodata = ya_push(rodata, pack_get_strs(cur));
        j = j + 1;
    }
    Yv *globals = pack_get_strs(cur);
    return yr(12, "name", name, "files", files, "exports", xs, "init", init,
              "bodies", yav(0), "btext", btext, "blob", blob, "labels", labels,
              "refs", refs, "rodata", rodata, "globals", globals, "dfl", dfl);
}

/* The units `names` from a pack, in that order; [] for a pack of another
 * version, or one missing any of them. */
Yv *std_unpack(Yv *pack, Yv *names) {
    Yv *out = yav(0);
    Yv *ver = pack_version();
    if (ys_eq(ys_slice(pack, 0, yv_len(ver)), ver)) {
        Yv *cur = yr(2, "s", pack, "p", yv_long(yv_len(ver)));
        long n = pack_num(cur);
        Yv *got = yav(0);
        long i = 0;
        while (i < n) {
            Yv *nm = pack_get(cur);
            long ul = pack_len(cur);
            long at = yv_l(yr_get(cur, "p"));
            if (name_in(names, nm)) {
                got = ya_push(got,
                              unit_read(cur, nm, std_unit_bound(nm)));
                ;
            }
            yr_set(cur, "p", yv_long(at + ul));
            i = i + 1;
        }
        long k = 0;
        while (k < yv_len(names)) {
            Yv *want = ya_get(names, k);
            long a = 0;
            while (a < yv_len(got)) {
                Yv *u = ya_get(got, a);
                if (ys_eq(yr_get(u, "name"), want)) {
                    out = ya_push(out, u);
                    ;
                }
                a = a + 1;
            }
            k = k + 1;
        }
        if (yv_len(out) != yv_len(names)) {
            out = yav(0);
            ;
        }
        ;
    }
    return out;
}

/* An object carries a checksum over its own bytes, after them.
 *
 * The key covers what the unit was BUILT from -- its text, its flags, the
 * interfaces it was compiled against -- and the length check covered
 * truncation, but nothing covered the body: one flipped byte inside a string
 * constant or a table entry rode straight through the cache, and the rebuild
 * linked the corrupt unit (a m.yo with a single byte changed rebuilt into a
 * program printing "hello From m"). asm.y's hash_str is the hash the compiler
 * already runs over ~191k names per compile, so it is both strong enough for
 * this and free. */
Yv *unit_obj(Yv *unit, Yv *key) {
    Yv *out = yav(0);
    out = ya_push(out, obj_version());
    out = pack_put(out, key);
    long at_fields = yv_len(ys_join(out, ys("")));
    out = pack_put(out, yr_get(unit, "name"));
    out = pack_put(out, pack_unit_fields(unit));
    Yv *body = ys_join(out, ys(""));
    out = pack_put(out,
                   ys_long(hash_str(ys_slice(body, at_fields,
                                             yv_len(body)))));
    return ys_join(out, ys(""));
}

Yv *unit_unobj(Yv *text, Yv *key) {
    Yv *ver = obj_version();
    int ok = 0;
    Yv *unit = unit_empty(ys(""));
    if (ys_eq(ys_slice(text, 0, yv_len(ver)), ver)) {
        Yv *cur = yr(2, "s", text, "p", yv_long(yv_len(ver)));
        if (ys_eq(pack_get(cur), key)) {
            long body_at = yv_l(yr_get(cur, "p")); /* the name field starts
             * here, and the checksum covers it and the fields */
            Yv *name = pack_get(cur);
            long ul = pack_len(cur);
            /* where unit_read starts, once the checksum has been checked */
            long body_end = yv_l(yr_get(cur, "p")) + ul;
            /* the checksum field must be there (one byte at least), so an
             * object written before this one is rebuilt rather than read at a
             * byte past its end */
            if (body_end < yv_len(text)) {
                long sum = hash_str(ys_slice(text, body_at, body_end));
                yr_set(cur, "p", yv_long(body_end));
                if (pack_num(cur) == sum && yv_l(yr_get(cur, "p")) == yv_len(text)) {
                    yr_set(cur, "p", yv_long(body_end - ul));
                    unit = unit_read(cur, name, 1);
                    ok = yv_l(yr_get(cur, "p")) == body_end;
                    ;
                }
                ;
            }
            ;
        }
        ;
    }
    return yr(2, "ok", yv_bool(ok), "unit", unit);
}

Yv *unit_iface(Yv *unit) {
    return ys_join(pack_iface(yav(0), unit), ys(""));
}

/* Build the extern set for one unit: selected std exports, then the
 * exports/defaults of its directly imported package namespaces. */
Yv *unit_externs(Yv *std, Yv *snames, Yv *deps, Yv *pkgs) {
    Yv *xt = externs_none();
    Yv *ext = yav(0);
    long i = 0;
    while (i < yv_len(std)) {
        Yv *u = ya_get(std, i);
        Yv *un = yr_get(u, "name");
        if (std_unit_bound(un) && name_in(snames, un)) {
            Yv *exports = yr_get(u, "exports");
            long j = 0;
            while (j < yv_len(exports)) {
                ext = ya_push(ext, ya_get(exports, j));
                j = j + 1;
            }
            ;
        }
        i = i + 1;
    }
    Yv *dfl = yav(0);
    i = 0;
    while (i < yv_len(deps)) {
        Yv *u = ya_get(deps, i);
        Yv *un = yr_get(u, "name");
        if (name_in(pkgs, un)) {
            Yv *xs = yr_get(u, "exports");
            long j = 0;
            while (j < yv_len(xs)) {
                Yv *x = ya_get(xs, j);
                Yv *qname =
                    ys_cat(ys_cat(un, ys(".")), yr_get(x, "name"));
                ext = ya_push(
                    ext, yr(3, "name", qname, "label", yr_get(x, "label"),
                            "typ", yr_get(x, "typ")));
                j = j + 1;
            }
            Yv *ds = yr_get(u, "dfl");
            j = 0;
            while (j < yv_len(ds)) {
                Yv *d = ya_get(ds, j);
                Yv *dv = yr_get(d, "vals");
                Yv *vals = yav(0);
                long m = 0;
                while (m < yv_len(dv)) {
                    vals = ya_push(vals, lit_decode(ya_get(dv, m)));
                    m = m + 1;
                }
                Yv *qname =
                    ys_cat(ys_cat(un, ys(".")), yr_get(d, "name"));
                dfl = ya_push(dfl, yr(2, "name", qname, "vals", vals));
                j = j + 1;
            }
            ;
        }
        i = i + 1;
    }
    yr_set(xt, "ext", ext);
    yr_set(xt, "dfl", dfl);
    yr_set(xt, "pkgs", pkgs);
    return xt;
}

Yv *compile_package(Yv *ast, Yv *nr, Yv *name, long base, long wlevel,
                    Yv *std, Yv *deps) {
    Yv *xt = unit_externs(std, yr_get(nr, "std"), deps, yr_get(nr, "pkgs"));
    return compile_unit(ast, yr_get(nr, "imports"), yr_get(nr, "origin"), 1,
                        wlevel, name, base, xt);
}

/* ── entry points ──────────────────────────────────────────────────────
 *
 * The program's unit, compiled against the std units `std` and package
 * units `deps`, then linked with them. */
Yv *emit_program(Yv *ast, Yv *nr, int debug, long wlevel, Yv *std, Yv *deps) {
    Yv *xt = unit_externs(std, yr_get(nr, "std"), deps, yr_get(nr, "pkgs"));
    Yv *units = yav(0);
    long i = 0;
    while (i < yv_len(std)) {
        units = ya_push(units, ya_get(std, i));
        i = i + 1;
    }
    i = 0;
    while (i < yv_len(deps)) {
        units = ya_push(units, ya_get(deps, i));
        i = i + 1;
    }
    Yv *inits = yav(0);
    i = 0;
    while (i < yv_len(units)) {
        Yv *u = ya_get(units, i);
        Yv *init = yr_get(u, "init");
        if (yv_len(init) > 0) {
            inits = ya_push(inits, init);
            ;
        }
        i = i + 1;
    }
    yr_set(xt, "inits", inits);
    int wargv = 0;
    i = 0;
    while (i < yv_len(deps)) {
        Yv *u = ya_get(deps, i);
        Yv *rf = yr_get(u, "refs");
        long b = 0;
        while (!wargv && b < yv_len(rf)) {
            wargv = name_in(ya_get(rf, b), ys("y_argv"));
            b = b + 1;
        }
        i = i + 1;
    }
    yr_set(xt, "argv", yv_bool(wargv));
    Yv *r = compile_unit(ast, yr_get(nr, "imports"), yr_get(nr, "origin"),
                         debug, wlevel, ys(""), 0, xt);
    Yv *times = yr_get(r, "times");
    if (yv_b(yr_get(r, "ok"))) {
        dup_y_label(deps, yr_get(r, "unit"));
        long pt = clock_us();
        long ph = heap_used();
        Yv *asm_ = link_units(std, deps, yr_get(r, "unit"));
        Yv *pr = phase_end(times, ys("asm_parts"), pt, ph);
        return yr(5, "ok", yv_bool(1), "asm", asm_, "errors",
                  yr_get(r, "errors"), "warnings", yr_get(r, "warnings"),
                  "times", yr_get(pr, "times"));
    } else {
        return yr(5, "ok", yv_bool(0), "asm", ys(""), "errors",
                  yr_get(r, "errors"), "warnings", yr_get(r, "warnings"),
                  "times", times);
    }
}

/* ── maps: dynamic {K => V} ────────────────────────────────────────────
 * A map value is a two-field record -- {keys: [K], vals: [V]} -- and
 * every map operation lowers to synthetic AST over those arrays (the
 * emitter knows the static key and value types for comparison and
 * formatting), so maps need no runtime assembly of their own. Reads are
 * always optional: a hit boxes the value (some(v)), a miss leaves none. */

Yv *n_str(Yv *v, long line, long col) {
    return yr(4, "k", yv_long(K_str), "v", v, "line", yv_long(line), "col", yv_long(col));
}

Yv *n_bool(Yv *v, long line, long col) {
    return yr(4, "k", yv_long(K_bool), "v", v, "line", yv_long(line), "col", yv_long(col));
}

Yv *n_dot(Yv *obj, Yv *key, long line, long col) {
    return yr(5, "k", yv_long(K_dot), "obj", obj, "key", key, "line", yv_long(line), "col", yv_long(col));
}

Yv *n_idx(Yv *arr, Yv *idx, long line, long col) {
    return yr(5, "k", yv_long(K_index), "arr", arr, "idx", idx, "line", yv_long(line), "col", yv_long(col));
}

Yv *n_bin(Yv *op, Yv *l, Yv *r, long line, long col) {
    return yr(6, "k", yv_long(K_bin), "op", op, "l", l, "r", r, "line", yv_long(line), "col", yv_long(col));
}

Yv *n_not(Yv *e, long line, long col) {
    return yr(5, "k", yv_long(K_un), "op", ys("!"), "e", e, "line", yv_long(line), "col", yv_long(col));
}

Yv *n_if(Yv *c, Yv *t, Yv *e, long ln, long cl) {
    return yr(7, "k", yv_long(K_kw_if), "cond", c, "then", t, "els", e, "has_else", yv_bool(1), "line", yv_long(ln), "col", yv_long(cl));
}

Yv *n_while(Yv *c, Yv *b, long ln, long cl) {
    return yr(5, "k", yv_long(K_kw_while), "cond", c, "body", b, "line", yv_long(ln), "col", yv_long(cl));
}

Yv *n_decl(Yv *name, Yv *v, long ln, long cl) {
    return yr(7, "k", yv_long(K_decl), "kind", ys("let"), "typ", yr(1, "k", yv_long(K_tnone)), "name", name, "v", v, "line", yv_long(ln), "col", yv_long(cl));
}

Yv *n_assign(Yv *name, Yv *v, long ln, long cl) {
    return yr(5, "k", yv_long(K_assign), "name", name, "v", v, "line", yv_long(ln), "col", yv_long(cl));
}

Yv *block_of(Yv *sts, long ln, long cl) {
    return yr(4, "k", yv_long(K_block), "stmts", sts, "line", yv_long(ln), "col", yv_long(cl));
}

/* {"a": 1, "a": 2}: duplicate keys collapse at emit time -- the last
 * entry wins the value, the first appearance keeps the position (the
 * record spread rule). The result is the {keys, vals, boxes} record
 * literal: maps lower to {keys: [K], vals: [V], boxes: [V?]}. A read m[k]
 * is V?, and an option is a heap box, so boxes[i] caches the box of
 * vals[i]: the first read after the entry was written makes it, every
 * later read shares it, and a write clears it (a reader may still hold
 * the old box -- it is never mutated). Reads allocate at most once per
 * entry and write. */
Yv *gen_maplit(Yv *st, Yv *node) {
    long ln = yv_l(yr_get(node, "line"));
    long cl = yv_l(yr_get(node, "col"));
    Yv *mkeys = yr_get(node, "keys");
    Yv *mvals = yr_get(node, "vals");
    Yv *keys = yav(0);
    Yv *vals = yav(0);
    long mi = 0;
    while (mi < yv_len(mkeys)) {
        Yv *mk = ya_get(mkeys, mi);
        Yv *mv = ya_get(mvals, mi);
        int found = 0;
        long fi = 0;
        while (fi < yv_len(keys)) {
            Yv *kk = ya_get(keys, fi);
            if (ys_eq(kk, mk)) {
                ya_set(vals, fi, mv);
                found = 1;
                ;
            }
            fi = fi + 1;
        }
        if (found) {
            ;
        } else {
            keys = ya_push(keys, mk);
            vals = ya_push(vals, mv);
            ;
        }
        mi = mi + 1;
    }
    Yv *knodes = yav(0);
    Yv *bnodes = yav(0);
    long ki = 0;
    while (ki < yv_len(keys)) {
        Yv *ks = ya_get(keys, ki);
        knodes = ya_push(knodes, n_str(ks, ln, cl));
        bnodes = ya_push(bnodes, n_id(ys("none"), ln, cl));
        ki = ki + 1;
    }
    Yv *keysarr = yr(4, "k", yv_long(K_array), "elems", knodes, "line", yv_long(ln), "col", yv_long(cl));
    Yv *valsarr = yr(4, "k", yv_long(K_array), "elems", vals, "line", yv_long(ln), "col", yv_long(cl));
    Yv *boxesarr = yr(4, "k", yv_long(K_array), "elems", bnodes, "line", yv_long(ln), "col", yv_long(cl));
    Yv *rkeys = yav(0);
    rkeys = ya_push(rkeys, ys("keys"));
    rkeys = ya_push(rkeys, ys("vals"));
    rkeys = ya_push(rkeys, ys("boxes"));
    Yv *rvals = yav(0);
    rvals = ya_push(rvals, keysarr);
    rvals = ya_push(rvals, valsarr);
    rvals = ya_push(rvals, boxesarr);
    return gen(st, yr(5, "k", yv_long(K_rec), "keys", rkeys, "vals", rvals, "line", yv_long(ln), "col", yv_long(cl)));
}

/* m[k] read or test (is_map_read): m[k] on a map value. */
int is_map_read(Yv *st, Yv *e) {
    if (yv_l(yr_get(e, "k")) == K_index) { return yv_l(yr_get(infer(st, yr_get(e, "arr")), "k")) == K_tmap; } else { return 0; }
}

int is_none_id(Yv *e) {
    return yv_l(yr_get(e, "k")) == K_id && ys_eq_lit(yr_get(e, "v"), "none");
}

/* The key scan every map access shares: t+"i" stops at the entry whose
 * key equals t+"k", or at t+"n" (the entry count) on a miss. The caller
 * binds t+"m" (the map), t+"k", t+"ks" = m.keys (hoisted: push grows in
 * place, so the header never moves), t+"i" = 0, t+"n" = len(t+"ks") and
 * the loop bound t+"j" = t+"n". A hit pulls the bound in to i rather than
 * testing `i < n && keys[i] != k`, which materializes a bool every step. */
Yv *map_scan(Yv *t, long ln, long cl) {
    Yv *i = n_id(ys_cat(t, ys("i")), ln, cl);
    Yv *key = n_idx(n_id(ys_cat(t, ys("ks")), ln, cl), i, ln, cl);
    Yv *hit = yav(0);
    hit = ya_push(hit, n_assign(ys_cat(t, ys("j")), i, ln, cl));
    hit = ya_push(hit, n_num(ys("0"), ln, cl));
    Yv *step = yav(0);
    step = ya_push(step, n_assign(ys_cat(t, ys("i")), n_bin(ys("+"), i, n_num(ys("1"), ln, cl), ln, cl), ln, cl));
    step = ya_push(step, n_num(ys("0"), ln, cl));
    Yv *body = yav(0);
    body = ya_push(body, n_if(n_bin(ys("=="), key, n_id(ys_cat(t, ys("k")), ln, cl), ln, cl), block_of(hit, ln, cl), block_of(step, ln, cl), ln, cl));
    return n_while(n_bin(ys("<"), i, n_id(ys_cat(t, ys("j")), ln, cl), ln, cl), block_of(body, ln, cl), ln, cl);
}

/* m[k] read, by mode. "opt" is the read itself (V?): a hit hands out
 * boxes[i], boxing vals[i] first if no read since the last write has; a
 * miss is none. The reads whose option never escapes skip the box: "val"
 * is m[k]! (vals[i]; a miss traps like unwrap(none)), "has" is
 * is_some(m[k]) and m[k] != none, "none" is m[k] == none. */
Yv *gen_map_get(Yv *st, Yv *node, Yv *mode) {
    long ln = yv_l(yr_get(node, "line"));
    long cl = yv_l(yr_get(node, "col"));
    Yv *r = next_uid(st);
    st = yr_get(r, "st");
    Yv *t = ys_cat(ys("y_t"), ys_long(yv_l(yr_get(r, "uid"))));
    Yv *m = n_id(ys_cat(t, ys("m")), ln, cl);
    Yv *i = n_id(ys_cat(t, ys("i")), ln, cl);
    Yv *n = n_id(ys_cat(t, ys("n")), ln, cl);
    Yv *sts = yav(0);
    sts = ya_push(sts, n_decl(ys_cat(t, ys("m")), yr_get(node, "arr"), ln, cl));
    sts = ya_push(sts, n_decl(ys_cat(t, ys("k")), yr_get(node, "idx"), ln, cl));
    sts = ya_push(sts, n_decl(ys_cat(t, ys("ks")), n_dot(m, ys("keys"), ln, cl), ln, cl));
    sts = ya_push(sts, n_decl(ys_cat(t, ys("i")), n_num(ys("0"), ln, cl), ln, cl));
    sts = ya_push(sts, n_decl(ys_cat(t, ys("n")), n_call1(ys("len"), n_id(ys_cat(t, ys("ks")), ln, cl), ln, cl), ln, cl));
    sts = ya_push(sts, n_decl(ys_cat(t, ys("j")), n, ln, cl));
    sts = ya_push(sts, map_scan(t, ln, cl));
    if (ys_eq_lit(mode, "has")) {
        sts = ya_push(sts, n_bin(ys("<"), i, n, ln, cl));
        ;
    } else if (ys_eq_lit(mode, "none")) {
        sts = ya_push(sts, n_bin(ys("=="), i, n, ln, cl));
        ;
    } else if (ys_eq_lit(mode, "val")) {
        Yv *miss = yav(0);
        miss = ya_push(miss, n_call1(ys("unwrap"), n_id(ys("none"), ln, cl), ln, cl));
        Yv *hit = yav(0);
        hit = ya_push(hit, n_num(ys("0"), ln, cl));
        sts = ya_push(sts, n_if(n_bin(ys("=="), i, n, ln, cl), block_of(miss, ln, cl), block_of(hit, ln, cl), ln, cl));
        sts = ya_push(sts, n_idx(n_dot(m, ys("vals"), ln, cl), i, ln, cl));
        ;
    } else {
        Yv *b = n_id(ys_cat(t, ys("b")), ln, cl);
        Yv *fill = yav(0);
        fill = ya_push(fill, n_assign(ys_cat(t, ys("b")), n_call1(ys("some"), n_idx(n_dot(m, ys("vals"), ln, cl), i, ln, cl), ln, cl), ln, cl));
        fill = ya_push(fill, yr(6, "k", yv_long(K_idxassign), "arr", n_dot(m, ys("boxes"), ln, cl), "idx", i, "v", b, "line", yv_long(ln), "col", yv_long(cl)));
        fill = ya_push(fill, n_num(ys("0"), ln, cl));
        Yv *kept = yav(0);
        kept = ya_push(kept, n_num(ys("0"), ln, cl));
        Yv *hit = yav(0);
        hit = ya_push(hit, n_decl(ys_cat(t, ys("b")), n_idx(n_dot(m, ys("boxes"), ln, cl), i, ln, cl), ln, cl));
        hit = ya_push(hit, n_if(n_call1(ys("is_some"), b, ln, cl), block_of(kept, ln, cl), block_of(fill, ln, cl), ln, cl));
        hit = ya_push(hit, b);
        Yv *miss = yav(0);
        miss = ya_push(miss, n_id(ys("none"), ln, cl));
        sts = ya_push(sts, n_if(n_bin(ys("<"), i, n, ln, cl), block_of(hit, ln, cl), block_of(miss, ln, cl), ln, cl));
        ;
    }
    return gen(st, block_of(sts, ln, cl));
}

/* m[k] = v: scan for the key; a hit overwrites vals[i] and clears its
 * cached box, a miss pushes onto all three arrays (in place -- every alias
 * of the map sees the write; push, not `+=`, which would append the
 * elements of an array value whose type unifies with [V], such as []).
 * The value runs before the scan counts the entries, so a value that
 * itself adds keys is seen. */
Yv *gen_map_set(Yv *st, Yv *node) {
    long ln = yv_l(yr_get(node, "line"));
    long cl = yv_l(yr_get(node, "col"));
    Yv *r = next_uid(st);
    st = yr_get(r, "st");
    Yv *t = ys_cat(ys("y_t"), ys_long(yv_l(yr_get(r, "uid"))));
    Yv *m = n_id(ys_cat(t, ys("m")), ln, cl);
    Yv *k = n_id(ys_cat(t, ys("k")), ln, cl);
    Yv *i = n_id(ys_cat(t, ys("i")), ln, cl);
    Yv *n = n_id(ys_cat(t, ys("n")), ln, cl);
    Yv *v = n_id(ys_cat(t, ys("v")), ln, cl);
    Yv *sts = yav(0);
    sts = ya_push(sts, n_decl(ys_cat(t, ys("m")), yr_get(node, "arr"), ln, cl));
    sts = ya_push(sts, n_decl(ys_cat(t, ys("k")), yr_get(node, "idx"), ln, cl));
    sts = ya_push(sts, n_decl(ys_cat(t, ys("v")), yr_get(node, "v"), ln, cl));
    sts = ya_push(sts, n_decl(ys_cat(t, ys("ks")), n_dot(m, ys("keys"), ln, cl), ln, cl));
    sts = ya_push(sts, n_decl(ys_cat(t, ys("i")), n_num(ys("0"), ln, cl), ln, cl));
    sts = ya_push(sts, n_decl(ys_cat(t, ys("n")), n_call1(ys("len"), n_id(ys_cat(t, ys("ks")), ln, cl), ln, cl), ln, cl));
    sts = ya_push(sts, n_decl(ys_cat(t, ys("j")), n, ln, cl));
    sts = ya_push(sts, map_scan(t, ln, cl));
    Yv *hit = yav(0);
    hit = ya_push(hit, yr(6, "k", yv_long(K_idxassign), "arr", n_dot(m, ys("vals"), ln, cl), "idx", i, "v", v, "line", yv_long(ln), "col", yv_long(cl)));
    hit = ya_push(hit, yr(6, "k", yv_long(K_idxassign), "arr", n_dot(m, ys("boxes"), ln, cl), "idx", i, "v", n_id(ys("none"), ln, cl), "line", yv_long(ln), "col", yv_long(cl)));
    hit = ya_push(hit, n_num(ys("0"), ln, cl));
    Yv *grow = yav(0);
    grow = ya_push(grow, n_call2(ys("push"), n_dot(m, ys("keys"), ln, cl), k, ln, cl));
    grow = ya_push(grow, n_call2(ys("push"), n_dot(m, ys("vals"), ln, cl), v, ln, cl));
    grow = ya_push(grow, n_call2(ys("push"), n_dot(m, ys("boxes"), ln, cl), n_id(ys("none"), ln, cl), ln, cl));
    grow = ya_push(grow, n_num(ys("0"), ln, cl));
    sts = ya_push(sts, n_if(n_bin(ys("<"), i, n, ln, cl), block_of(hit, ln, cl), block_of(grow, ln, cl), ln, cl));
    sts = ya_push(sts, v);
    return gen(st, block_of(sts, ln, cl));
}

/* One key's repr inside a map: string keys quote (Python-style), the
 * other hashable keys stringify bare. */
Yv *map_key_repr(Yv *node, Yv *kt, long ln, long cl) {
    if (yv_l(yr_get(kt, "k")) == K_tstr) {
        return n_bin(ys("+"), n_bin(ys("+"), n_str(ys("\""), ln, cl), node, ln, cl), n_str(ys("\""), ln, cl), ln, cl);
    } else {
        return n_call1(ys("tostring"), node, ln, cl);
    }
}

/* {"k": v, ...}: a synthetic string-building loop -- the entry count is
 * dynamic, but every format decision (keys, values) is static. */
Yv *gen_map_repr(Yv *st, Yv *arg, Yv *t) {
    long ln = 0;
    long cl = 0;
    Yv *r = next_uid(st);
    st = yr_get(r, "st");
    Yv *g = ys_cat(ys("y_t"), ys_long(yv_l(yr_get(r, "uid"))));
    Yv *m = n_id(ys_cat(g, ys("m")), ln, cl);
    Yv *i = n_id(ys_cat(g, ys("i")), ln, cl);
    Yv *n = n_id(ys_cat(g, ys("n")), ln, cl);
    Yv *s = n_id(ys_cat(g, ys("s")), ln, cl);
    Yv *sts = yav(0);
    sts = ya_push(sts, n_decl(ys_cat(g, ys("m")), arg, ln, cl));
    sts = ya_push(sts, n_decl(ys_cat(g, ys("s")), n_str(ys("{"), ln, cl), ln, cl));
    sts = ya_push(sts, n_decl(ys_cat(g, ys("i")), n_num(ys("0"), ln, cl), ln, cl));
    sts = ya_push(sts, n_decl(ys_cat(g, ys("n")), n_call1(ys("len"), n_dot(m, ys("keys"), ln, cl), ln, cl), ln, cl));
    Yv *sep = yav(0);
    sep = ya_push(sep, n_assign(ys_cat(g, ys("s")), n_bin(ys("+"), s, n_str(ys(", "), ln, cl), ln, cl), ln, cl));
    sep = ya_push(sep, n_num(ys("0"), ln, cl));
    Yv *nosep = yav(0);
    nosep = ya_push(nosep, n_num(ys("0"), ln, cl));
    Yv *kpart = map_key_repr(n_idx(n_dot(m, ys("keys"), ln, cl), i, ln, cl), yr_get(t, "key"), ln, cl);
    Yv *vpart = n_call1(ys("tostring"), n_idx(n_dot(m, ys("vals"), ln, cl), i, ln, cl), ln, cl);
    Yv *put = n_assign(ys_cat(g, ys("s")), n_bin(ys("+"), n_bin(ys("+"), n_bin(ys("+"), s, kpart, ln, cl), n_str(ys(": "), ln, cl), ln, cl), vpart, ln, cl), ln, cl);
    Yv *step = n_assign(ys_cat(g, ys("i")), n_bin(ys("+"), i, n_num(ys("1"), ln, cl), ln, cl), ln, cl);
    Yv *body = yav(0);
    body = ya_push(body, n_if(n_bin(ys(">"), i, n_num(ys("0"), ln, cl), ln, cl), block_of(sep, ln, cl), block_of(nosep, ln, cl), ln, cl));
    body = ya_push(body, put);
    body = ya_push(body, step);
    sts = ya_push(sts, n_while(n_bin(ys("<"), i, n, ln, cl), block_of(body, ln, cl), ln, cl));
    sts = ya_push(sts, n_bin(ys("+"), s, n_str(ys("}"), ln, cl), ln, cl));
    return gen(st, block_of(sts, ln, cl));
}