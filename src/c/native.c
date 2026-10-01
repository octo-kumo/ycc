/* native.c — typed AST -> x86_64 assembly (AT&T/GAS) for the native backend.
 * 1:1 copy of src/y/native.y (see PORTING.md): every def is one function,
 * same names, same parameter order, same control flow.
 *
 * Usage (the driver, ycc.y):
 *   let r = emit_program(ast, imports);  // { ok, asm, errors }
 *   // r.ok: asm holds a complete .s file (cc-assemblable). else errors.
 *
 * Pipeline: types.check_program (fatal) -> collect defs (incl. hoisting of
 * capture-free nested defs = baby lambda lifting) -> frame layout -> emit.
 * Every value is 8 bytes (long/bool/ptr/str-address); expression values in
 * %rax; locals at negative rbp offsets; Y-function args pushed on the stack.
 */
#include "native.h"

#include "yv.h"

/* `pow10` is a native.y def (integer powers of ten) and glibc claims the
 * name as a builtin; the 1:1 name wins, so silence the clash. */
#pragma GCC diagnostic ignored "-Wbuiltin-declaration-mismatch"

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
Yv *arch_prelude(void);
Yv *arch_consts(void);
/* src/y/types.y */
Yv *tdisp(Yv *t);
Yv *tdisp_fnval(Yv *t);
Yv *check_program(Yv *ast);
Yv *field_merge(Yv *fields, Yv *name, Yv *typ);
Yv *narrow_type(Yv *s, Yv *t);
Yv *type_names(Yv *t);
/* src/y/rename.y */
Yv *rename_program(Yv *ast);
/* src/y/std/prelude.y */
Yv *prelude_lines(void);
Yv *exec_lines(void);
Yv *prelude_names(void);
Yv *exec_names(void);
/* src/y/std/rt.y */
Yv *rt_lines(void);
/* src/y/std/prof_lines.y */
Yv *prof_lines(void);

/* ── forward declarations (native.y def order) ────────────────────────── */

Yv *native_resolve(Yv *src, Yv *base_dir, long depth);
Yv *native_resolve_x(Yv *src, Yv *base_dir, long depth, int allow_exec,
                     int prof);
int names_mentioned(Yv *src, Yv *names);
Yv *strip_comments(Yv *src);
Yv *norm_path(Yv *p);
int seen_has(Yv *seen, Yv *full);
Yv *dir_of(Yv *p);
Yv *std_resolve(Yv *name, Yv *base_dir);
Yv *native_resolve_seen(Yv *src, Yv *base_dir, long depth, Yv *seen);
int is_id_b(long c);
long skip_sp(Yv *b, long i, long hi);
long tok_end_b(Yv *b, long i, long hi);
Yv *tok_at_b(Yv *text, Yv *b, long i, long hi);
Yv *tok_push(Yv *out, Yv *t);
Yv *line_refs_b(Yv *text, Yv *b, long lo, long hi, Yv *out, int want_jumps);
Yv *refs_range(Yv *text, Yv *b, long lo, long hi, Yv *out, int want_jumps);
Yv *text_refs(Yv *text, int want_jumps);
Yv *label_at(Yv *text, Yv *b, long lo, long hi);
Yv *body_label(Yv *body);
int is_data_line_b(Yv *text, Yv *b, long lo, long hi);
int block_falls_b(Yv *text, Yv *b, long lo, long hi);
long name_index(Yv *names, Yv *tok);
Yv *shake_keep(Yv *names, Yv *refs, Yv *falls, Yv *keep, Yv *roots);
Yv *shake_refs(Yv *text, Yv *root_refs);
Yv *prune_bodies(Yv *bodies, Yv *asm_roots);
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
Yv *env_define(Yv *st, Yv *name, Yv *kind, long off, Yv *label, Yv *typ);
Yv *infer(Yv *st, Yv *node);
Yv *infer_call(Yv *st, Yv *node);
Yv *infer_block(Yv *st, Yv *node);
Yv *infer_decl(Yv *st, Yv *node);
Yv *uses_scan_block(Yv *stmts, Yv *out);
Yv *uses_scan_node(Yv *node, Yv *out);
Yv *collect_from_block(Yv *stmts, Yv *out);
Yv *collect_from_node(Yv *node, Yv *out);
int name_in(Yv *xs, Yv *n);
int is_intrinsic_name(Yv *n);
Yv *fv_walk(Yv *node, Yv *out, int collect);
Yv *fv_walk_list(Yv *nodes, Yv *out, int collect);
Yv *fv_ids(Yv *node, Yv *out);
Yv *fv_binds(Yv *node, Yv *out);
Yv *fv_binds_list(Yv *nodes, Yv *out);
Yv *fn_captures(Yv *func, Yv *fnnames);
Yv *fv_bind_params(Yv *ps, Yv *out);
Yv *fn_names_of(Yv *fns);
int fn_label_present(Yv *fns, Yv *label);
Yv *fns_kind(Yv *label);
Yv *gen(Yv *st, Yv *node);
Yv *gen_str_const(Yv *st, Yv *s);
Yv *gen_id(Yv *st, Yv *node);
Yv *gen_cap_ptr(Yv *st, Yv *name);
Yv *box_capture(Yv *st, Yv *name);
Yv *box_names(Yv *func);
Yv *box_bound(Yv *st, Yv *name);
Yv *gen_make_closure(Yv *st, Yv *label, Yv *caps);
Yv *gen_range(Yv *st, Yv *node);
Yv *gen_slice(Yv *st, Yv *node);
Yv *gen_indirect(Yv *st, Yv *node, Yv *callee);
Yv *gen_str_slice(Yv *st, Yv *node);
Yv *gen_sliceassign(Yv *st, Yv *node);
Yv *gen_rectest_rax(Yv *st, Yv *names);
Yv *gen_union_str_rax(Yv *st, Yv *t);
int is_void_node(Yv *n);
Yv *gen_un(Yv *st, Yv *node);
Yv *gen_addr(Yv *st, Yv *node);
Yv *gen_elem_addr(Yv *st, Yv *node);
Yv *gen_bin(Yv *st, Yv *node);
Yv *gen_logic(Yv *st, Yv *node, int is_or);
Yv *gen_cat(Yv *st, Yv *node, Yv *lt, Yv *rt);
Yv *gen_float_bin(Yv *st, Yv *node, Yv *lt, Yv *rt);
Yv *gen_str_cmp(Yv *st, Yv *node, Yv *op);
Yv *gen_bin_rest(Yv *st, Yv *node);
Yv *syscall_reg(long i);
Yv *gen_push_args(Yv *st, Yv *args);
Yv *gen_helper1(Yv *st, Yv *label);
Yv *gen_call(Yv *st, Yv *node);
Yv *gen_print(Yv *st, Yv *node);
Yv *gen_print_scalar(Yv *st, Yv *arg, Yv *t);
Yv *gen_typeof(Yv *st, Yv *node);
Yv *gen_opt_str_rax(Yv *st, Yv *t);
Yv *gen_rec_str(Yv *st, Yv *arg, Yv *t);
Yv *gen_rec_str_rax(Yv *st, Yv *t);
Yv *gen_cons(Yv *st, Yv *node);
Yv *gen_cat_arr(Yv *st, Yv *node, Yv *lt, Yv *rt);
Yv *gen_acc_cat_const(Yv *st, Yv *s);
Yv *gen_rec_field_str(Yv *st, long idx, Yv *ft);
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
long mfield_idx(Yv *names, Yv *name);
Yv *gen_reclit(Yv *st, Yv *node);
Yv *gen_func_literal(Yv *st, Yv *node);
Yv *gen_closure_binding(Yv *st, Yv *name, Yv *func, Yv *caps);
Yv *gen_decl(Yv *st, Yv *node);
Yv *bind_decl(Yv *st, Yv *name, Yv *t);
Yv *gen_assign(Yv *st, Yv *node);
Yv *gen_fill(Yv *st, long base, long n);
Yv *gen_fill_heap(Yv *st, long n, long esz);
Yv *gen_arrrep(Yv *st, Yv *node);
Yv *gen_arrrep_esz(Yv *st, Yv *node, long esz);
long hexval_ch(Yv *c);
int lit_is_float(Yv *s);
Yv *norm_num(Yv *s);
long flit_mant(Yv *s);
long flit_ebase(Yv *s);
long flit_exp(Yv *s);
long pow10(long k);
Yv *gen_lit(Yv *st, Yv *node);
Yv *gen_scale10(Yv *st, long n);
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
Yv *block4(Yv *a, Yv *b, Yv *c, Yv *d, long ln, long cl);
Yv *block5(Yv *a, Yv *b, Yv *c, Yv *d, Yv *e, long ln, long cl);
Yv *block6(Yv *a, Yv *b, Yv *c, Yv *d, Yv *e, Yv *f, long ln, long cl);
Yv *gen_incdec(Yv *st, Yv *node);
Yv *gen_opassign(Yv *st, Yv *node);
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
Yv *gen_map_get(Yv *st, Yv *node);
Yv *gen_map_set(Yv *st, Yv *node);
Yv *map_key_repr(Yv *node, Yv *kt, long ln, long cl);
Yv *gen_map_repr(Yv *st, Yv *arg, Yv *t);
Yv *gen_opassign_arith(Yv *st, Yv *node);
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
Yv *gen_opassign_arr(Yv *st, Yv *node);
Yv *gen_idxassign(Yv *st, Yv *node);
Yv *gen_val_tostr_rax(Yv *st, Yv *t);
Yv *gen_arr_tostr_rax(Yv *st, Yv *elty);
Yv *gen_acc_cat_slot(Yv *st, long off, Yv *s);
long elem_bytes(Yv *t);
long arr_elem_bytes(Yv *t);
Yv *elem_load(long esz, Yv *base, Yv *idx, Yv *dst);
Yv *elem_store_rdx(long esz, Yv *base, Yv *idx);
Yv *elem_store_rdx_const(long esz, Yv *base, long k);
long arr_alloc_size(long esz, long n);
long arr_header_size(void);
Yv *gen_dot(Yv *st, Yv *node);
long rec_field_idx(Yv *t, Yv *key);
Yv *gen_array(Yv *st, Yv *node);
Yv *gen_array_esz(Yv *st, Yv *node, long esz);
Yv *gen_len(Yv *st, Yv *node);
Yv *gen_push(Yv *st, Yv *node);
Yv *gen_some(Yv *st, Yv *node);
Yv *gen_is_some(Yv *st, Yv *node);
Yv *gen_unwrap(Yv *st, Yv *node);
Yv *gen_substr(Yv *st, Yv *node);
Yv *gen_trim(Yv *st, Yv *node);
Yv *gen_prepend(Yv *st, Yv *node);
Yv *gen_byte_at(Yv *st, Yv *node);
Yv *gen_ord(Yv *st, Yv *node);
Yv *gen_chr(Yv *st, Yv *node);
Yv *gen_tonum(Yv *st, Yv *node);
Yv *gen_tostring(Yv *st, Yv *node);
Yv *gen_index_of(Yv *st, Yv *node, int last);
Yv *gen_join(Yv *st, Yv *node);
Yv *gen_join_conv(Yv *st, Yv *node, Yv *tostr_fn, long esz);
Yv *gen_split(Yv *st, Yv *node);
Yv *gen_puts(Yv *st, Yv *node);
Yv *gen_eputs(Yv *st, Yv *node);
Yv *gen_clock_us(Yv *st, Yv *node);
Yv *gen_heap_used(Yv *st, Yv *node);
Yv *gen_sleep(Yv *st, Yv *node);
Yv *gen_exit(Yv *st, Yv *node);
Yv *gen_argv(Yv *st, Yv *node);
Yv *gen_read_file(Yv *st, Yv *node);
Yv *gen_write_file(Yv *st, Yv *node);
Yv *gen_write_bytes(Yv *st, Yv *node);
Yv *gen_store(Yv *st, Yv *node);
Yv *emit_one_fn(Yv *st, Yv *label, long fuid, Yv *func, int is_main,
                int want_argv, Yv *captypes, Yv *selfname);
Yv *infer_fn_ret(Yv *st, Yv *func);
Yv *func_type(Yv *func);
Yv *func_type_in(Yv *st, Yv *func);
Yv *ndisp(Yv *name);
Yv *find_dup(Yv *defs);
Yv *global_decls(Yv *stmts);
Yv *decl_name(Yv *d);
Yv *decl_type(Yv *d);
Yv *decl_value(Yv *d);
Yv *global_entries(Yv *st, Yv *gdecls);
Yv *capturing_defs(Yv *defs, Yv *gnames);
Yv *fix_fn_types(Yv *st, Yv *hdefs, Yv *only);
int ret_omitted(Yv *func);
Yv *fn_ptypes(Yv *func);
int reads_any(Yv *func, Yv *names);
Yv *phase_end(Yv *times, Yv *name, long t0, long h0);
Yv *emit_program(Yv *ast, Yv *imports);

/* ── native import resolution ───────────────────────────────────────────
 * An import is a COMPILE-TIME text splice, and both compilers splice the
 * same way: `import io from "path"` inlines the module's source in place and
 * drops its `export` line. References `io.x` are rewritten to plain `x` by
 * strip_namespaces (AST-level, so strings are untouched). Module top-levels
 * must be defs; duplicate def names across the splice are a loud error. */

Yv *native_resolve(Yv *src, Yv *base_dir, long depth) {
    return native_resolve_x(src, base_dir, depth, 1, 0);
}

/* allow_exec = false is `ycc --no-exec`: the exec chunk is not spliced, so
 * `exec(...)` fails with "undefined function" and the binary has no path
 * to a shell at all.
 *
 * prof = true is `ycc --prof`: the profiling runtime is spliced and the
 * emitter wraps every function with its enter/exit hooks (see std/prof.y).
 *
 * `pre` is how many lines the prelude added in FRONT of the user's text.
 * Prepending (rather than appending) is deliberate: defs hoist either way,
 * but a later def shadows an earlier one, so a user's own `readline` must
 * come after ours to win. The cost is that every position downstream is
 * shifted, which the driver undoes when it prints an error. */
Yv *native_resolve_x(Yv *src, Yv *base_dir, long depth, int allow_exec,
                     int prof) {
    /* NOTE: seen-threading wrapper (see native_resolve_seen): asm.y imports
     * enc64 as `enc` AND elf.y imports enc64 as `elfenc`; without dedup the
     * encoder splices twice and every enc64 def collides (find_dup is
     * fatal). */
    Yv *r = native_resolve_seen(src, base_dir, depth, yav(0));
    Yv *rsrc = yr_get(r, "src");
    Yv *rimports = yr_get(r, "imports");
    long pre = 0;
    /* The runtime library (std/rt.y) is spliced in front of EVERY program:
     * generated code calls into it by fixed label (`call y_print_long`), so
     * there is no name to test for. Unused helpers cost nothing in the
     * output — prune_bodies drops them at emit time. */
    Yv *rtl = rt_lines();
    rsrc = ys_cat(ys_cat(ys_join(rtl, ys("\n")), ys("\n")), rsrc);
    pre = pre + yv_len(rtl);
    /* `--prof` builds splice the profiling runtime the same way: generated
     * code calls y_prof_enter/y_prof_exit around every function and the
     * report prints at exit. Non-prof builds never mention it, so tree
     * shaking has nothing to keep. */
    if (prof) {
        Yv *pl = prof_lines();
        rsrc = ys_cat(ys_cat(ys_join(pl, ys("\n")), ys("\n")), rsrc);
        pre = pre + yv_len(pl);
        ;
    } else {
        ;
    }
    /* Prelude chunks go in front of the resolved text, but only when the
     * program actually mentions one of their names — otherwise every binary
     * would carry code it never calls (there is no dead-code pass). */
    if (allow_exec) {
        if (names_mentioned(rsrc, exec_names())) {
            Yv *xl = exec_lines();
            rsrc = ys_cat(ys_cat(ys_join(xl, ys("\n")), ys("\n")), rsrc);
            pre = pre + yv_len(xl);
            ;
        } else {
            ;
        }
        ;
    } else {
        ;
    }
    if (names_mentioned(rsrc, prelude_names())) {
        Yv *pl = prelude_lines();
        rsrc = ys_cat(ys_cat(ys_join(pl, ys("\n")), ys("\n")), rsrc);
        pre = pre + yv_len(pl);
        ;
    } else {
        ;
    }
    return yr(3, "src", rsrc, "imports", rimports, "pre", yv_long(pre));
}

/* Textual check, deliberately: it runs before tokenizing, and a false
 * positive only costs an unused function in the output.
 *
 * COMMENTS ARE STRIPPED first. They used to be searched too, which meant a
 * comment containing `exec` (the word "executables" was enough) spliced the
 * whole fork/execve chunk into the binary -- the audit caught this by
 * diffing binaries and finding /bin/sh rodata and ~9 extra uids in a
 * program that never calls exec. Comments cannot call anything, so dropping
 * them removes the false positives without adding a real lexer dependency. */
int names_mentioned(Yv *src, Yv *names) {
    Yv *code = strip_comments(src);
    long i = 0;
    int want = 0;
    while (i < yv_len(names)) {
        Yv *nm = ya_get(names, i);
        if (ys_index_of(code, nm) >= 0) {
            want = 1;
            ;
        } else {
            ;
        }
        i = i + 1;
    }
    return want;
}

/* Remove line and block comments from `src`, keeping the newlines so line
 * counts (and therefore error positions) do not shift. Returns a STRING (the
 * pieces are joined): callers feed it to ys_index_of, which rejects a non-str
 * value. String literals are NOT protected: a `//` inside a string is
 * vanishingly rare next to the cost of tracking quotes here, and getting it
 * wrong only costs an unused chunk. */
Yv *strip_comments(Yv *src) {
    long n = yv_len(src);
    Yv *out = yav(0);
    long i = 0;
    while (i < n) {
        Yv *c = ys_substr(src, i, 1);
        if (ys_eq(c, ys("/"))) {
            Yv *nxt = ys_substr(src, i + 1, 1);
            if (ys_eq(nxt, ys("/"))) {
                /* to end of line; keep the newline itself */
                int done = 0;
                while (!done) {
                    if (i >= n) {
                        done = 1;
                        ;
                    } else {
                        Yv *d = ys_substr(src, i, 1);
                        i = i + 1;
                        if (ys_eq(d, ys("\n"))) {
                            out = ya_push(out, ys("\n"));
                            done = 1;
                            ;
                        } else {
                            ;
                        }
                        ;
                    }
                    ;
                }
                ;
            } else if (ys_eq(nxt, ys("*"))) {
                i = i + 2;
                while (i < n) {
                    Yv *d = ys_substr(src, i, 1);
                    if (ys_eq(d, ys("*"))) {
                        if (ys_eq(ys_substr(src, i + 1, 1), ys("/"))) { i = i + 2; ; } else { i = i + 1; ; }
                        ;
                    } else {
                        if (ys_eq(d, ys("\n"))) { out = ya_push(out, ys("\n")); ; } else { ; }
                        i = i + 1;
                        ;
                    }
                    ;
                }
                ;
            } else {
                out = ya_push(out, c);
                i = i + 1;
                ;
            }
            ;
        } else {
            out = ya_push(out, c);
            i = i + 1;
            ;
        }
        ;
    }
    /* Y: `join(out, "")` — the pieces come back as one string, because
       ys_index_of (below) rejects a non-str value. */
    return ys_join(out, ys(""));
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

int seen_has(Yv *seen, Yv *full) {
    long i = 0;
    int found = 0;
    while (i < yv_len(seen)) {
        Yv *e = ya_get(seen, i);
        if (ys_eq(e, full)) {
            found = 1;
            ;
        } else {
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
 * The file found is spliced exactly like `import x from "path"` and its
 * defs are called through the namespace: `net.listen_tcp(...)` and
 * friends. */

Yv *dir_of(Yv *p) {
    long s = ys_last_index_of(p, ys("/"));
    if (s < 0) {
        return ys("");
    } else {
        return ys_substr(p, 0, s);
    }
}

Yv *std_resolve(Yv *name, Yv *base_dir) {
    Yv *cands = yav(0);
    cands = ya_push(cands,
                    ys_cat(ys_cat(ys_cat(base_dir, ys("/")), name), ys(".y")));
    cands = ya_push(
        cands, ys_cat(ys_cat(ys_cat(base_dir, ys("/std/")), name), ys(".y")));
    cands = ya_push(cands, ys_cat(ys_cat(ys("std/"), name), ys(".y")));
    cands = ya_push(cands, ys_cat(ys_cat(ys("src/y/std/"), name), ys(".y")));
    Yv *av = argv_();
    if (yv_len(av) > 0) {
        Yv *exe = ya_get(av, 0);
        Yv *d = dir_of(exe);
        if (yv_len(d) > 0) {
            cands = ya_push(
                cands, ys_cat(ys_cat(ys_cat(d, ys("/std/")), name), ys(".y")));
            cands = ya_push(cands, ys_cat(ys_cat(ys_cat(d, ys("/src/y/std/")),
                                                 name),
                                        ys(".y")));
            cands = ya_push(cands, ys_cat(ys_cat(ys_cat(d, ys("/../src/y/std/")),
                                                 name),
                                        ys(".y")));
            ;
        } else {
            ;
        }
        ;
    } else {
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
        } else {
            ;
        }
        i = i + 1;
    }
    return found;
}

Yv *native_resolve_seen(Yv *src, Yv *base_dir, long depth, Yv *seen) {
    if (depth > 32) {
        puts_(ys("error: native import depth exceeded (cycle?)\n"));
        return yr(3, "src", ys(""), "imports", yav(0), "seen", seen);
    } else {
        Yv *lines = ys_split(src, ys("\n"));
        Yv *out_lines = yav(0);
        Yv *imports = yav(0);
        long i = 0;
        long n = yv_len(lines);
        while (i < n) {
            Yv *line = ya_get(lines, i);
            Yv *trimmed = ys_trim(line);
            if (ys_eq_lit(ys_substr(trimmed, 0, 7), "import ")) {
                Yv *rest = ys_substr(trimmed, 7, yv_len(trimmed) - 7);
                long from_idx = ys_index_of(rest, ys(" from "));
                Yv *name = ys("");
                Yv *full = ys("");
                Yv *path = ys("");
                if (from_idx >= 0) {
                    name = ys_trim(ys_substr(rest, 0, from_idx));
                    Yv *path_part = ys_trim(
                        ys_substr(rest, from_idx + 6,
                                  yv_len(rest) - from_idx - 6));
                    if (ys_eq_lit(ys_substr(path_part, yv_len(path_part) - 1, 1),
                                  ";")) {
                        path_part =
                            ys_substr(path_part, 0, yv_len(path_part) - 1);
                        ;
                    } else {
                        ;
                    }
                    path = ys_substr(path_part, 1, yv_len(path_part) - 2);
                    /* NOTE: normalized (see norm_path): nested base dirs
                     * accumulate "/." segments, so raw joins of the same file
                     * differ per depth and seen-dedup would never hit. */
                    full = norm_path(ys_cat(ys_cat(base_dir, ys("/")), path));
                    if (ys_eq_lit(ys_substr(path, 0, 1), "/")) {
                        full = norm_path(path);
                        ;
                    } else {
                        ;
                    }
                    ;
                } else {
                    /* bare `import name;`: an optional std module (net, ui,
                     * ...) or a project-local one — see std_resolve above. */
                    name = ys_trim(rest);
                    if (ys_eq_lit(ys_substr(name, yv_len(name) - 1, 1), ";")) {
                        name = ys_trim(ys_substr(name, 0, yv_len(name) - 1));
                        ;
                    } else {
                        ;
                    }
                    path = name;
                    full = std_resolve(name, base_dir);
                    ;
                }
                if (yv_len(name) == 0) {
                    out_lines = ya_push(out_lines, line);
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
                         * record the namespace name (strip_ns needs it) but
                         * do NOT splice the text a second time. */
                        imports = ya_push(imports, name);
                        ;
                    } else {
                        seen = ya_push(seen, full);
                        long last_slash = ys_last_index_of(full, ys("/"));
                        Yv *mod_dir = base_dir;
                        if (last_slash >= 0) {
                            mod_dir = ys_substr(full, 0, last_slash);
                            ;
                        } else {
                            ;
                        }
                        /* mod_src is str? (read_file returns none on missing
                         * file); the none case exited above, so unwrap
                         * here. */
                        Yv *mod_src2 = yv_unwrap(mod_src);
                        Yv *sub =
                            native_resolve_seen(mod_src2, mod_dir, depth + 1,
                                                seen);
                        Yv *subsrc = yr_get(sub, "src");
                        Yv *subns = yr_get(sub, "imports");
                        Yv *subseen = yr_get(sub, "seen");
                        seen = subseen;
                        /* splice the module text inline (its own imports
                         * first) */
                        Yv *sub_lines = ys_split(subsrc, ys("\n"));
                        long k = 0;
                        while (k < yv_len(sub_lines)) {
                            out_lines = ya_push(out_lines,
                                                ya_get(sub_lines, k));
                            k = k + 1;
                        }
                        long m = 0;
                        while (m < yv_len(subns)) {
                            imports = ya_push(imports, ya_get(subns, m));
                            m = m + 1;
                        }
                        imports = ya_push(imports, name);
                        ;
                    }
                    ;
                }
                ;
            } else {
                /* NOTE: no empty if-arms here — keep the `;` filler.
                 * Export lines are dropped (defs are spliced; uses are
                 * rewritten by strip_namespaces). */
                if (!ys_eq_lit(ys_substr(trimmed, 0, 7), "export ")) {
                    out_lines = ya_push(out_lines, line);
                    ;
                } else {
                    if (ys_index_of(line, ys("{")) >= 0) {
                        while (ys_index_of(ya_get(lines, i), ys("}")) < 0 &&
                               i + 1 < n) {
                            i = i + 1;
                            ;
                        }
                        ;
                    } else {
                        ;
                    }
                }
                ;
            }
            i = i + 1;
        }
        return yr(3, "src", ys_join(out_lines, ys("\n")), "imports", imports,
                  "seen", seen);
    }
}

int is_id_b(long c) {
    int ok = 0;
    if (c >= 48) {
        if (c <= 57) {
            ok = 1;
            ;
        } else {
            ;
        }
        ;
    } else {
        ;
    }
    if (c >= 97) {
        if (c <= 122) {
            ok = 1;
            ;
        } else {
            ;
        }
        ;
    } else {
        ;
    }
    if (c >= 65) {
        if (c <= 90) {
            ok = 1;
            ;
        } else {
            ;
        }
        ;
    } else {
        ;
    }
    if (c == 95) {
        ok = 1;
        ;
    } else {
        ;
    }
    if (c == 36) {
        ok = 1;
        ;
    } else {
        ;
    }
    return ok;
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
        } else {
            ;
        }
        ;
    } else {
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
        } else {
            ;
        }
        ;
    } else {
        ;
    }
    long e = tok_end_b(b, i, hi);
    if (e > s) {
        return ys_substr(text, s, e - s);
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
                    } else {
                        ;
                    }
                    ;
                } else {
                    ;
                }
                ;
            } else {
                ;
            }
            ;
        } else {
            if (want_jumps) {
                if (ys_eq_lit(ys_substr(w, 0, 1), "j")) {
                    out = tok_push(out, tok_at_b(text, b, op, hi));
                    ;
                } else {
                    ;
                }
                ;
            } else {
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
        } else {
            ;
        }
        i = i + 1;
    }
    if (ls < hi) {
        res = line_refs_b(text, b, ls, hi, res, want_jumps);
        ;
    } else {
        ;
    }
    return res;
}

/* Every symbol a whole asm text references. */
Yv *text_refs(Yv *text, int want_jumps) {
    Yv *b = bytes_of(text);
    return refs_range(text, b, 0, yv_len(b), yav(0), want_jumps);
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
                } else {
                    ;
                }
                lab = ys_substr(text, s, e - s);
                ;
            } else {
                ;
            }
            ;
        } else {
            ;
        }
        ;
    } else {
        ;
    }
    return lab;
}

/* The label a body starts with (`label: ...`). */
Yv *body_label(Yv *body) {
    Yv *b = bytes_of(body);
    return label_at(body, b, 0, yv_len(b));
}

/* A line that is data, not code: blank lines, directives, or a bare label
 * (possibly followed by data on the same line). */
int is_data_line_b(Yv *text, Yv *b, long lo, long hi) {
    Yv *lab = label_at(text, b, lo, hi);
    long p = skip_sp(b, lo, hi);
    if (yv_len(lab) > 0) {
        p = skip_sp(b, p + 1 + yv_len(lab), hi);
        ;
    } else {
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
            } else {
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
            } else {
                ;
            }
            ;
        }
    }
    return falls;
}

/* Index of `tok` in `names`, or -1 (length first: most misses are free). */
long name_index(Yv *names, Yv *tok) {
    long tl = yv_len(tok);
    long i = 0;
    long found = -1;
    while (i < yv_len(names)) {
        if (found < 0) {
            Yv *nm = ya_get(names, i);
            if (yv_len(nm) == tl) {
                if (ys_eq(nm, tok)) {
                    found = i;
                    ;
                } else {
                    ;
                }
                ;
            } else {
                ;
            }
            ;
        } else {
            ;
        }
        i = i + 1;
    }
    return found;
}

/* Mark every names[i] some entry of `roots` points at, then close over kept
 * blocks: their own references and (for code that runs into the next block)
 * their successor. `falls[i]` says block i falls through to block i+1. */
Yv *shake_keep(Yv *names, Yv *refs, Yv *falls, Yv *keep, Yv *roots) {
    long n = yv_len(names);
    long r = 0;
    while (r < yv_len(roots)) {
        long idx = name_index(names, ya_get(roots, r));
        if (idx >= 0) {
            ya_set(keep, idx, yv_bool(1));
            ;
        } else {
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
                            } else {
                                ;
                            }
                            ;
                        } else {
                            ;
                        }
                        ;
                    } else {
                        ;
                    }
                    Yv *rs = ya_get(refs, b);
                    long j = 0;
                    while (j < yv_len(rs)) {
                        long idx = name_index(names, ya_get(rs, j));
                        if (idx >= 0) {
                            if (!(yv_b(ya_get(keep, idx)))) {
                                ya_set(keep, idx, yv_bool(1));
                                ;
                            } else {
                                ;
                            }
                            ;
                        } else {
                            ;
                        }
                        j = j + 1;
                    }
                    ;
                } else {
                    ;
                }
                ;
            } else {
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
                } else {
                    ;
                }
                ;
            }
            ls = i + 1;
            ;
        } else {
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
            } else {
                ;
            }
            ;
        }
        ;
    } else {
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
            } else {
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
                } else {
                    ;
                }
                pieces = ya_push(pieces, ys_substr(text, lo, hi - lo));
                ;
            } else {
                ;
            }
            k = k + 1;
        }
        return ys_join(pieces, ys(""));
    }
}

/* Drop function bodies nothing reaches: dead stdlib code the program never
 * calls. Bodies are referenced by label from other bodies AND from the arch
 * prelude (y_float_tostr's block calls the Y-side y_long_tostr), so
 * `asm_roots` is the prelude text. Returns the kept bodies plus everything
 * they reference — the roots for shaking the arch prelude itself. */
Yv *prune_bodies(Yv *bodies, Yv *asm_roots) {
    long nb = yv_len(bodies);
    Yv *labels = yav(0);
    Yv *refs = yav(0);
    long i = 0;
    while (i < nb) {
        Yv *b = ya_get(bodies, i);
        labels = ya_push(labels, body_label(b));
        refs = ya_push(refs, text_refs(b, 1));
        i = i + 1;
    }
    Yv *keep = yav(0);
    Yv *falls = yav(0);
    i = 0;
    while (i < nb) {
        keep = ya_push(keep, yv_bool(0));
        falls = ya_push(falls, yv_bool(0));
        i = i + 1;
    }
    Yv *roots = text_refs(asm_roots, 1);
    long root = name_index(labels, ys("_start"));
    if (root >= 0) {
        roots = ya_push(roots, ys("_start"));
        ;
    } else {
        ;
    }
    keep = shake_keep(labels, refs, falls, keep, roots);
    Yv *out = yav(0);
    Yv *outrefs = yav(0);
    i = 0;
    while (i < nb) {
        if (yv_b(ya_get(keep, i))) {
            Yv *b = ya_get(bodies, i);
            out = ya_push(out, b);
            Yv *rs = ya_get(refs, i);
            long j = 0;
            while (j < yv_len(rs)) {
                outrefs = ya_push(outrefs, ya_get(rs, j));
                j = j + 1;
            }
            ;
        } else {
            ;
        }
        i = i + 1;
    }
    return yr(2, "bodies", out, "refs", outrefs);
}

int is_all_digits(Yv *s) {
    if (yv_len(s) == 0) {
        return 0;
    } else {
        long i = 0;
        int ok = 1;
        while (i < yv_len(s)) {
            if (ys_index_of(ys("0123456789"), ys_substr(s, i, 1)) < 0) {
                ok = 0;
                ;
            } else {
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
        if (!ys_eq_lit(ys_substr(name, 0, 2), "y_")) {
            return ys("");
        } else {
            long dollar = ys_index_of(name, ys("$"));
            if (dollar < 0) {
                return name;
            } else {
                if (is_all_digits(
                        ys_substr(name, dollar + 1, yv_len(name) - dollar - 1))) {
                    return ys_substr(name, 0, dollar);
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
        } else {
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
    Yv *k = yr_get(node, "k");
    if (ys_eq_lit(k, "dot")) {
        Yv *dobj = yr_get(node, "obj");
        Yv *obj = strip_ns(dobj, imports);
        Yv *okey = yr_get(node, "key");
        Yv *oline = yr_get(node, "line");
        Yv *ocol = yr_get(node, "col");
        if (ys_eq_lit(yr_get(obj, "k"), "id")) {
            Yv *ov = yr_get(obj, "v");
            if (is_ns(ov, imports)) {
                return normnode(yr(4, "k", ys("id"), "v", okey, "line", oline,
                                   "col", ocol));
            } else {
                return normnode(yr(5, "k", ys("dot"), "obj", obj, "key", okey,
                                   "line", oline, "col", ocol));
            }
        } else {
            return normnode(yr(5, "k", ys("dot"), "obj", obj, "key", okey,
                               "line", oline, "col", ocol));
        }
    } else if (ys_eq_lit(k, "un")) {
        return normnode(yr(5, "k", ys("un"), "op", yr_get(node, "op"), "e",
                           strip_ns(yr_get(node, "e"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (ys_eq_lit(k, "addr") || ys_eq_lit(k, "deref")) {
        return normnode(yr(4, "k", k, "e", strip_ns(yr_get(node, "e"), imports),
                           "line", yr_get(node, "line"), "col",
                           yr_get(node, "col")));
    } else if (ys_eq_lit(k, "bin")) {
        return normnode(
            yr(6, "k", ys("bin"), "op", yr_get(node, "op"), "l",
               strip_ns(yr_get(node, "l"), imports), "r",
               strip_ns(yr_get(node, "r"), imports), "line",
               yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (ys_eq_lit(k, "call")) {
        return normnode(yr(5, "k", ys("call"), "callee",
                           strip_ns(yr_get(node, "callee"), imports), "args",
                           strip_list(yr_get(node, "args"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (ys_eq_lit(k, "if")) {
        return normnode(yr(7, "k", ys("if"), "cond",
                           strip_ns(yr_get(node, "cond"), imports), "then",
                           strip_ns(yr_get(node, "then"), imports), "els",
                           strip_ns(yr_get(node, "els"), imports), "has_else",
                           yr_get(node, "has_else"), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (ys_eq_lit(k, "while")) {
        return normnode(yr(5, "k", ys("while"), "cond",
                           strip_ns(yr_get(node, "cond"), imports), "body",
                           strip_ns(yr_get(node, "body"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (ys_eq_lit(k, "block")) {
        return normnode(yr(4, "k", ys("block"), "stmts",
                           strip_list(yr_get(node, "stmts"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (ys_eq_lit(k, "decl")) {
        return strip_decl(node, imports);
    } else if (ys_eq_lit(k, "func")) {
        return normnode(yr(8, "k", ys("func"), "params", yr_get(node, "params"),
                           "ptypes", yr_get(node, "ptypes"), "ret",
                           yr_get(node, "ret"), "body",
                           strip_ns(yr_get(node, "body"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col"),
                           "defs", yr_get(node, "defs")));
    } else if (ys_eq_lit(k, "assign")) {
        return normnode(yr(5, "k", ys("assign"), "name", yr_get(node, "name"),
                           "v", strip_ns(yr_get(node, "v"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (ys_eq_lit(k, "incdec")) {
        return normnode(yr(6, "k", ys("incdec"), "op", yr_get(node, "op"), "pre",
                           yr_get(node, "pre"), "tgt",
                           strip_ns(yr_get(node, "tgt"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (ys_eq_lit(k, "opassign")) {
        return normnode(yr(6, "k", ys("opassign"), "op", yr_get(node, "op"),
                           "tgt", strip_ns(yr_get(node, "tgt"), imports), "v",
                           strip_ns(yr_get(node, "v"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (ys_eq_lit(k, "store")) {
        return normnode(yr(5, "k", ys("store"), "p",
                           strip_ns(yr_get(node, "p"), imports), "v",
                           strip_ns(yr_get(node, "v"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (ys_eq_lit(k, "ret")) {
        return normnode(yr(4, "k", ys("ret"), "e",
                           strip_ns(yr_get(node, "e"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (ys_eq_lit(k, "array")) {
        return normnode(yr(4, "k", ys("array"), "elems",
                           strip_list(yr_get(node, "elems"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (ys_eq_lit(k, "arrrep")) {
        return normnode(yr(5, "k", ys("arrrep"), "v",
                           strip_ns(yr_get(node, "v"), imports), "n",
                           yr_get(node, "n"), "line", yr_get(node, "line"),
                           "col", yr_get(node, "col")));
    } else if (ys_eq_lit(k, "rec")) {
        return normnode(yr(5, "k", ys("rec"), "keys", yr_get(node, "keys"),
                           "vals", strip_list(yr_get(node, "vals"), imports),
                           "line", yr_get(node, "line"), "col",
                           yr_get(node, "col")));
    } else if (ys_eq_lit(k, "map")) {
        return normnode(yr(5, "k", ys("map"), "keys", yr_get(node, "keys"),
                           "vals", strip_list(yr_get(node, "vals"), imports),
                           "line", yr_get(node, "line"), "col",
                           yr_get(node, "col")));
    } else if (ys_eq_lit(k, "index")) {
        return normnode(
            yr(5, "k", ys("index"), "arr", strip_ns(yr_get(node, "arr"), imports),
               "idx", strip_ns(yr_get(node, "idx"), imports), "line",
               yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (ys_eq_lit(k, "slice")) {
        return normnode(yr(6, "k", ys("slice"), "arr",
                           strip_ns(yr_get(node, "arr"), imports), "lo",
                           strip_ns(yr_get(node, "lo"), imports), "hi",
                           strip_ns(yr_get(node, "hi"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (ys_eq_lit(k, "idxassign")) {
        return normnode(yr(6, "k", ys("idxassign"), "arr",
                           strip_ns(yr_get(node, "arr"), imports), "idx",
                           strip_ns(yr_get(node, "idx"), imports), "v",
                           strip_ns(yr_get(node, "v"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (ys_eq_lit(k, "dotassign")) {
        return normnode(yr(6, "k", ys("dotassign"), "obj",
                           strip_ns(yr_get(node, "obj"), imports), "key",
                           yr_get(node, "key"), "v",
                           strip_ns(yr_get(node, "v"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (ys_eq_lit(k, "foreach")) {
        return normnode(yr(6, "k", ys("foreach"), "name", yr_get(node, "name"),
                           "iter", strip_ns(yr_get(node, "iter"), imports),
                           "body", strip_ns(yr_get(node, "body"), imports),
                           "line", yr_get(node, "line"), "col",
                           yr_get(node, "col")));
    } else if (ys_eq_lit(k, "forrange")) {
        return normnode(yr(7, "k", ys("forrange"), "name", yr_get(node, "name"),
                           "lo", strip_ns(yr_get(node, "lo"), imports), "hi",
                           strip_ns(yr_get(node, "hi"), imports), "body",
                           strip_ns(yr_get(node, "body"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (ys_eq_lit(k, "for")) {
        return normnode(yr(7, "k", ys("for"), "init",
                           strip_ns(yr_get(node, "init"), imports), "cond",
                           strip_ns(yr_get(node, "cond"), imports), "step",
                           strip_ns(yr_get(node, "step"), imports), "body",
                           strip_ns(yr_get(node, "body"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (ys_eq_lit(k, "sliceassign")) {
        return normnode(yr(7, "k", ys("sliceassign"), "arr",
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
        return normnode(yr(6, "k", ys("decl"), "kind", ys("def"), "name",
                           yr_get(node, "name"), "v",
                           strip_ns(yr_get(node, "v"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    } else {
        return normnode(yr(7, "k", ys("decl"), "kind", yr_get(node, "kind"),
                           "name", yr_get(node, "name"), "typ",
                           yr_get(node, "typ"), "v",
                           strip_ns(yr_get(node, "v"), imports), "line",
                           yr_get(node, "line"), "col", yr_get(node, "col")));
    }
}

/* ── emit state ─────────────────────────────────────────────────────────
 * st = { out, rodata, uid, fuid, loc, env, slots,
 *        self_label, end_label, fns, bodies }
 * env: FLAT list of {name, kind, off, label, typ} — names are unique
 * post-rename, so no scopes or shadowing. kind: "local"|"param"|"func". */

Yv *st_new(void) {
    return yr(11, "out", yav(0), "rodata", yav(0), "uid", yv_long(1), "fuid",
              yv_long(0), "loc", yv_long(1), "env", yav(0), "slots",
              yv_long(0), "self_label", ys(""), "end_label", ys(""), "fns",
              yav(0), "bodies", yav(0));
}

Yv *emit(Yv *st, Yv *line) {
    return yr(11, "out", ya_push(yr_get(st, "out"), line), "rodata",
              yr_get(st, "rodata"), "uid", yr_get(st, "uid"), "fuid",
              yr_get(st, "fuid"), "loc", yr_get(st, "loc"), "env",
              yr_get(st, "env"), "slots", yr_get(st, "slots"), "self_label",
              yr_get(st, "self_label"), "end_label", yr_get(st, "end_label"),
              "fns", yr_get(st, "fns"), "bodies", yr_get(st, "bodies"));
}

Yv *next_uid(Yv *st) {
    long u = yv_l(yr_get(st, "uid"));
    st = yr(11, "out", yr_get(st, "out"), "rodata", yr_get(st, "rodata"), "uid",
            yv_long(yv_l(yr_get(st, "uid")) + 1), "fuid", yr_get(st, "fuid"),
            "loc", yr_get(st, "loc"), "env", yr_get(st, "env"), "slots",
            yr_get(st, "slots"), "self_label", yr_get(st, "self_label"),
            "end_label", yr_get(st, "end_label"), "fns", yr_get(st, "fns"),
            "bodies", yr_get(st, "bodies"));
    return yr(2, "st", st, "uid", yv_long(u));
}

Yv *next_loc(Yv *st) {
    long n = yv_l(yr_get(st, "loc"));
    Yv *lbl = arch_loc_label(yv_l(yr_get(st, "fuid")), n);
    st = yr(11, "out", yr_get(st, "out"), "rodata", yr_get(st, "rodata"), "uid",
            yr_get(st, "uid"), "fuid", yr_get(st, "fuid"), "loc",
            yv_long(yv_l(yr_get(st, "loc")) + 1), "env", yr_get(st, "env"),
            "slots", yr_get(st, "slots"), "self_label",
            yr_get(st, "self_label"), "end_label", yr_get(st, "end_label"),
            "fns", yr_get(st, "fns"), "bodies", yr_get(st, "bodies"));
    return yr(2, "st", st, "lbl", lbl);
}

/* ── string escaping for GAS .string ──────────────────────────────────── */

Yv *esc_asm(Yv *s) {
    Yv *buf = ys("");
    long i = 0;
    long n = yv_len(s);
    while (i < n) {
        Yv *c = ys_substr(s, i, 1);
        long o = ys_ord(c);
        if (ys_eq_lit(c, "\\")) {
            buf = ys_cat(buf, ys("\\\\"));
        } else if (ys_eq_lit(c, "\"")) {
            buf = ys_cat(buf, ys("\\\""));
        } else if (ys_eq_lit(c, "\n")) {
            buf = ys_cat(buf, ys("\\n"));
        } else if (ys_eq_lit(c, "\t")) {
            buf = ys_cat(buf, ys("\\t"));
        } else if (o < 32 || o > 126) {
            long d2 = o / 64;
            long d1 = (o / 8) % 8;
            long d0 = o % 8;
            buf = ys_cat(ys_cat(ys_cat(ys_cat(buf, ys("\\")), ys_long(d2)),
                                ys_long(d1)),
                         ys_long(d0));
        } else {
            buf = ys_cat(buf, c);
        }
        i = i + 1;
    }
    return buf;
}

/* ── flat environment ─────────────────────────────────────────────────── */

Yv *env_find(Yv *st, Yv *name) {
    /* Miss marker: kind "none". Real entries have name/kind/off/label/typ
     * but NO k field — never test e.k. */
    Yv *env = yr_get(st, "env");
    long i = 0;
    Yv *found = yr(5, "name", ys(""), "kind", ys("none"), "off", yv_long(0),
                   "label", ys(""), "typ", yr(1, "k", ys("tnone")));
    while (i < yv_len(env)) {
        Yv *e = ya_get(env, i);
        if (ys_eq(yr_get(e, "name"), name)) {
            found = e;
            ;
        } else {
            ;
        }
        i = i + 1;
    }
    return found;
}

Yv *env_define(Yv *st, Yv *name, Yv *kind, long off, Yv *label, Yv *typ) {
    Yv *env = ya_push(
        yr_get(st, "env"),
        yr(5, "name", name, "kind", kind, "off", yv_long(off), "label", label,
           "typ", typ));
    return yr(11, "out", yr_get(st, "out"), "rodata", yr_get(st, "rodata"),
              "uid", yr_get(st, "uid"), "fuid", yr_get(st, "fuid"), "loc",
              yr_get(st, "loc"), "env", env, "slots", yr_get(st, "slots"),
              "self_label", yr_get(st, "self_label"), "end_label",
              yr_get(st, "end_label"), "fns", yr_get(st, "fns"), "bodies",
              yr_get(st, "bodies"));
}

/* ── mini type inference (for print dispatch) ───────────────────────────
 * The checker already validated everything; this mirrors it just enough to
 * pick y_print_long / y_print_bool / y_print_cstr. */

Yv *infer(Yv *st, Yv *node) {
    Yv *k = yr_get(node, "k");
    if (ys_eq_lit(k, "num")) {
        if (lit_is_float(yr_get(node, "v"))) {
            return yr(1, "k", ys("tfloat"));
        } else {
            return yr(1, "k", ys("tlong"));
        }
    } else if (ys_eq_lit(k, "str")) {
        return yr(1, "k", ys("tstr"));
    } else if (ys_eq_lit(k, "bstr")) {
        return yr(2, "k", ys("tarr"), "of", yr(1, "k", ys("tbyte")));
    } else if (ys_eq_lit(k, "bool")) {
        return yr(1, "k", ys("tbool"));
    } else if (ys_eq_lit(k, "void")) {
        return yr(1, "k", ys("tvoid"));
    } else if (ys_eq_lit(k, "id")) {
        if (ys_eq_lit(yr_get(node, "v"), "self")) {
            return yr(1, "k", ys("tfunc"));
        } else {
            Yv *e = env_find(st, yr_get(node, "v"));
            if (ys_eq_lit(yr_get(e, "kind"), "none")) {
                if (ys_eq_lit(yr_get(node, "v"), "none")) {
                    return normnode(
                        yr(2, "k", ys("topt"), "of", yr(1, "k", ys("tunk"))));
                } else {
                    return yr(1, "k", ys("tunk"));
                }
            } else {
                return yr_get(e, "typ");
            }
        }
    } else if (ys_eq_lit(k, "un")) {
        if (ys_eq_lit(yr_get(node, "op"), "-")) {
            return infer(st, yr_get(node, "e"));
        } else {
            return yr(1, "k", ys("tbool"));
        }
    } else if (ys_eq_lit(k, "bin")) {
        Yv *op = yr_get(node, "op");
        if (ys_eq_lit(op, "+") || ys_eq_lit(op, "-") || ys_eq_lit(op, "*") ||
            ys_eq_lit(op, "/") || ys_eq_lit(op, "%") || ys_eq_lit(op, "::")) {
            Yv *bl = infer(st, yr_get(node, "l"));
            Yv *br = infer(st, yr_get(node, "r"));
            if (ys_eq_lit(op, "+") &&
                (ys_eq_lit(yr_get(bl, "k"), "tarr") ||
                 ys_eq_lit(yr_get(bl, "k"), "tarrfix"))) {
                /* array `+` concatenates into a NEW heap array (types.y
                 * typeof_arith_arr) -- the element type survives. */
                return yr(2, "k", ys("tarr"), "of", yr_get(bl, "of"));
            } else if (ys_eq_lit(op, "+") &&
                (ys_eq_lit(yr_get(br, "k"), "tarr") ||
                 ys_eq_lit(yr_get(br, "k"), "tarrfix"))) {
                return yr(2, "k", ys("tarr"), "of", yr_get(br, "of"));
            } else if (ys_eq_lit(op, "::")) {
                /* cons: one element prepended to the right's array */
                return yr(2, "k", ys("tarr"), "of", yr_get(br, "of"));
            } else if (ys_eq_lit(op, "+") &&
                (ys_eq_lit(yr_get(bl, "k"), "tstr") ||
                 ys_eq_lit(yr_get(br, "k"), "tstr"))) {
                return yr(1, "k", ys("tstr"));
            } else if (ys_eq_lit(yr_get(bl, "k"), "tfloat")) {
                return yr(1, "k", ys("tfloat"));
            } else if (ys_eq_lit(yr_get(br, "k"), "tfloat")) {
                return yr(1, "k", ys("tfloat"));
            } else {
                return yr(1, "k", ys("tlong"));
            }
        } else {
            return yr(1, "k", ys("tbool"));
        }
    } else if (ys_eq_lit(k, "func")) {
        return normnode(func_type_in(st, node));
    } else if (ys_eq_lit(k, "addr")) {
        return normnode(
            yr(2, "k", ys("tptr"), "to", infer(st, yr_get(node, "e"))));
    } else if (ys_eq_lit(k, "arrrep")) {
        return normnode(yr(3, "k", ys("tarrfix"), "of",
                           infer(st, yr_get(node, "v")), "n",
                           yr_get(node, "n")));
    } else if (ys_eq_lit(k, "array")) {
        Yv *elems = yr_get(node, "elems");
        if (yv_len(elems) == 0) {
            return normnode(
                yr(2, "k", ys("tarr"), "of", yr(1, "k", ys("tunk"))));
        } else {
            return normnode(yr(2, "k", ys("tarr"), "of",
                               infer(st, ya_get(elems, 0))));
        }
    } else if (ys_eq_lit(k, "index")) {
        /* checker guarantees an array base (any expression); the element
         * type is the base type's `of`. */
        Yv *iarr = yr_get(node, "arr");
        Yv *bt = infer(st, iarr);
        if (ys_eq_lit(yr_get(bt, "k"), "tarrfix") ||
            ys_eq_lit(yr_get(bt, "k"), "tarr")) {
            return yr_get(bt, "of");
        } else if (ys_eq_lit(yr_get(bt, "k"), "tmap")) {
            /* m[k] is always optional: V? for any V */
            return normnode(yr(2, "k", ys("topt"), "of", yr_get(bt, "of")));
        } else if (ys_eq_lit(yr_get(bt, "k"), "tstr")) {
            return yr(1, "k", ys("tbyte"));
        } else {
            return yr(1, "k", ys("tunk"));
        }
    } else if (ys_eq_lit(k, "slice")) {
        /* arr[lo:hi] keeps the element type but is always a heap [T]. */
        Yv *ts = infer(st, yr_get(node, "arr"));
        if (ys_eq_lit(yr_get(ts, "k"), "tarr")) {
            return yr(2, "k", ys("tarr"), "of", yr_get(ts, "of"));
        } else if (ys_eq_lit(yr_get(ts, "k"), "tarrfix")) {
            return yr(2, "k", ys("tarr"), "of", yr_get(ts, "of"));
        } else if (ys_eq_lit(yr_get(ts, "k"), "tstr")) {
            return yr(1, "k", ys("tstr"));
        } else {
            return yr(1, "k", ys("tunk"));
        }
    } else if (ys_eq_lit(k, "char")) {
        return yr(1, "k", ys("tbyte"));
    } else if (ys_eq_lit(k, "rectest")) {
        return yr(1, "k", ys("tbool"));
    } else if (ys_eq_lit(k, "narrow")) {
        return narrow_type(infer(st, yr_get(node, "e")), yr_get(node, "typ"));
    } else if (ys_eq_lit(k, "sliceassign")) {
        return yr(1, "k", ys("tvoid"));
    } else if (ys_eq_lit(k, "deref")) {
        Yv *t = infer(st, yr_get(node, "e"));
        if (ys_eq_lit(yr_get(t, "k"), "tptr")) {
            return yr_get(t, "to");
        } else {
            return yr(1, "k", ys("tunk"));
        }
    } else if (ys_eq_lit(k, "call")) {
        return infer_call(st, node);
    } else if (ys_eq_lit(k, "if")) {
        return infer(st, yr_get(node, "then"));
    } else if (ys_eq_lit(k, "block")) {
        return infer_block(st, node);
    } else if (ys_eq_lit(k, "decl")) {
        return infer_decl(st, node);
    } else if (ys_eq_lit(k, "assign")) {
        return infer(st, yr_get(node, "v"));
    } else if (ys_eq_lit(k, "incdec")) {
        return infer(st, yr_get(node, "tgt"));
    } else if (ys_eq_lit(k, "opassign")) {
        return infer(st, yr_get(node, "tgt"));
    } else if (ys_eq_lit(k, "rec")) {
        /* record literal: field types from the values (checker validated). */
        Yv *melems = yr_get(node, "vals");
        Yv *mkeys = yr_get(node, "keys");
        if (yv_len(melems) == 0) {
            return normnode(yr(2, "k", ys("trec"), "fields", yav(0)));
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
                    if (ys_eq_lit(yr_get(mf, "k"), "trec")) {
                        Yv *msfs = yr_get(mf, "fields");
                        long msi = 0;
                        while (msi < yv_len(msfs)) {
                            Yv *msf = ya_get(msfs, msi);
                            mfields = field_merge(mfields, yr_get(msf, "name"),
                                                  yr_get(msf, "typ"));
                            msi = msi + 1;
                        }
                        ;
                    } else {
                        ;
                    }
                    ;
                } else {
                    mfields = field_merge(mfields, mk, mf);
                    ;
                }
                mi = mi + 1;
            }
            return normnode(yr(2, "k", ys("trec"), "fields", mfields));
        }
    } else if (ys_eq_lit(k, "map")) {
        /* map literal: {keys, vals} record at runtime; the static type is
         * tmap (quoted keys are strings; the values share one type). */
        Yv *glvals = yr_get(node, "vals");
        if (yv_len(glvals) == 0) {
            return normnode(yr(3, "k", ys("tmap"), "key", yr(1, "k", ys("tstr")), "of", yr(1, "k", ys("tunk"))));
        } else {
            return normnode(yr(3, "k", ys("tmap"), "key", yr(1, "k", ys("tstr")), "of", infer(st, ya_get(glvals, 0))));
        }
    } else if (ys_eq_lit(k, "dot")) {
        /* field read: static index into the trec (checker validated). */
        Yv *dobj = yr_get(node, "obj");
        Yv *dt = infer(st, dobj);
        if (ys_eq_lit(yr_get(dt, "k"), "trec")) {
            int found = 0;
            Yv *ftyp = yr(1, "k", ys("tunk"));
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
                } else {
                    ;
                }
                di = di + 1;
            }
            if (found) {
                return ftyp;
            } else {
                return yr(1, "k", ys("tunk"));
            }
        } else if (ys_eq_lit(yr_get(dt, "k"), "tmap")) {
            /* the map lowering reads its {keys, vals} shape directly */
            if (ys_eq_lit(yr_get(node, "key"), "keys")) { return normnode(yr(2, "k", ys("tarr"), "of", yr_get(dt, "key"))); }
            else if (ys_eq_lit(yr_get(node, "key"), "vals")) { return normnode(yr(2, "k", ys("tarr"), "of", yr_get(dt, "of"))); }
            else { return yr(1, "k", ys("tunk")); }
        } else {
            return yr(1, "k", ys("tunk"));
        }
    } else if (ys_eq_lit(k, "store")) {
        return infer(st, yr_get(node, "v"));
    } else if (ys_eq_lit(k, "while")) {
        return yr(1, "k", ys("tvoid"));
    } else if (ys_eq_lit(k, "ret")) {
        return infer(st, yr_get(node, "e"));
    } else {
        return yr(1, "k", ys("tunk"));
    }
}

Yv *infer_call(Yv *st, Yv *node) {
    if (!ys_eq_lit(yr_get(yr_get(node, "callee"), "k"), "id")) {
        /* Calling an expression (immediately-invoked literal, fs[0](x), ...)
         */
        Yv *cft = infer(st, yr_get(node, "callee"));
        if (ys_eq_lit(yr_get(cft, "k"), "tfunc")) {
            return yr_get(cft, "ret");
        } else {
            return yr(1, "k", ys("tunk"));
        }
    } else {
        Yv *name = yr_get(yr_get(node, "callee"), "v");
        if (ys_eq_lit(name, "print")) {
            return yr(1, "k", ys("tvoid"));
        } else if (ys_eq_lit(name, "syscall")) {
            return yr(1, "k", ys("tlong"));
        } else if (ys_eq_lit(name, "len")) {
            return yr(1, "k", ys("tlong"));
        } else if (ys_eq_lit(name, "is_some")) {
            return yr(1, "k", ys("tbool"));
        } else if (ys_eq_lit(name, "unwrap")) {
            /* unwrap(x): payload type when x is statically an option. */
            Yv *uargs = yr_get(node, "args");
            if (yv_len(uargs) != 1) {
                return yr(1, "k", ys("tunk"));
            } else {
                Yv *ut = infer(st, ya_get(uargs, 0));
                if (ys_eq_lit(yr_get(ut, "k"), "topt")) {
                    return yr_get(ut, "of");
                } else {
                    return yr(1, "k", ys("tunk"));
                }
            }
        } else if (ys_eq_lit(name, "some")) {
            /* some(x): option of x's type. */
            Yv *sargs = yr_get(node, "args");
            if (yv_len(sargs) != 1) {
                return yr(2, "k", ys("topt"), "of", yr(1, "k", ys("tunk")));
            } else {
                return yr(2, "k", ys("topt"), "of",
                          infer(st, ya_get(sargs, 0)));
            }
        } else if (ys_eq_lit(name, "substr") || ys_eq_lit(name, "trim") ||
                   ys_eq_lit(name, "chr") || ys_eq_lit(name, "join") ||
                   ys_eq_lit(name, "tostring") || ys_eq_lit(name, "typeof")) {
            return yr(1, "k", ys("tstr"));
        } else if (ys_eq_lit(name, "read_file")) {
            /* str? (option): a missing file yields none at runtime
             * (callers none-check with `== none`, then unwrap).
             * Matches types.y (read_file -> str?). */
            return yr(2, "k", ys("topt"), "of", yr(1, "k", ys("tstr")));
        } else if (ys_eq_lit(name, "bytes")) {
            return yr(2, "k", ys("tarr"), "of", yr(1, "k", ys("tbyte")));
        } else if (ys_eq_lit(name, "from_bytes")) {
            return yr(1, "k", ys("tstr"));
        } else if (ys_eq_lit(name, "ptr_addr")) {
            return yr(1, "k", ys("tlong"));
        } else if (ys_eq_lit(name, "tonum") || ys_eq_lit(name, "ord") ||
                   ys_eq_lit(name, "byte_at") || ys_eq_lit(name, "index_of") ||
                   ys_eq_lit(name, "last_index_of")) {
            return yr(1, "k", ys("tlong"));
        } else if (ys_eq_lit(name, "clock_us") || ys_eq_lit(name, "heap_used")) {
            return yr(1, "k", ys("tlong"));
        } else if (ys_eq_lit(name, "sleep")) {
            return yr(1, "k", ys("tvoid"));
        } else if (ys_eq_lit(name, "split") || ys_eq_lit(name, "argv")) {
            return yr(2, "k", ys("tarr"), "of", yr(1, "k", ys("tstr")));
        } else if (ys_eq_lit(name, "range")) {
            return yr(2, "k", ys("tarr"), "of", yr(1, "k", ys("tlong")));
        } else if (ys_eq_lit(name, "write_file")) {
            return yr(1, "k", ys("tbool"));
        } else if (ys_eq_lit(name, "write_bytes")) {
            return yr(1, "k", ys("tbool"));
        } else if (ys_eq_lit(name, "push") || ys_eq_lit(name, "prepend")) {
            /* both yield the array they take (the header never moves, and
             * the type is the array's either way) */
            Yv *gargs = yr_get(node, "args");
            return infer(st, ya_get(gargs, 0));
        } else if (ys_eq_lit(name, "puts") || ys_eq_lit(name, "exit")) {
            return yr(1, "k", ys("tvoid"));
        } else if (ys_eq_lit(name, "eputs")) {
            return yr(1, "k", ys("tvoid"));
        } else {
            Yv *e = env_find(st, name);
            if (ys_eq_lit(yr_get(e, "kind"), "none")) {
                return yr(1, "k", ys("tunk"));
            } else if (ys_eq_lit(yr_get(yr_get(e, "typ"), "k"), "tfunc")) {
                return yr_get(yr_get(e, "typ"), "ret");
            } else {
                return yr(1, "k", ys("tunk"));
            }
        }
    }
}

Yv *infer_block(Yv *st, Yv *node) {
    Yv *stmts = yr_get(node, "stmts");
    if (yv_len(stmts) == 0) {
        return yr(1, "k", ys("tvoid"));
    } else {
        return infer(st, ya_get(stmts, yv_len(stmts) - 1));
    }
}

Yv *infer_decl(Yv *st, Yv *node) {
    if (ys_eq_lit(yr_get(node, "kind"), "def")) {
        return yr(3, "k", ys("tfunc"), "args", yav(0), "ret",
                  yr(1, "k", ys("tvoid")));
    } else {
        /* an annotated `let` takes the declared type; otherwise infer the
         * initializer's */
        if (ys_eq_lit(yr_get(yr_get(node, "typ"), "k"), "tnone")) {
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
    if (ys_eq_lit(k, "call")) {
        /* scan callee + args (argv() could nest inside an argument).
         * ncallee is read three times: the argv test, the id test, the walk. */
        Yv *ncallee = yr_get(node, "callee");
        Yv *nargs = yr_get(node, "args");
        Yv *found = out;
        if (ys_eq_lit(yr_get(ncallee, "k"), "id")) {
            if (ys_eq_lit(yr_get(ncallee, "v"), "argv")) {
                found = yr(1, "argv", yv_bool(1));
                ;
            } else {
                ;
            }
            ;
        } else {
            ;
        }
        Yv *o2 = uses_scan_node(ncallee, found);
        return uses_scan_block(nargs, o2);
    } else if (ys_eq_lit(k, "un")) {
        return uses_scan_node(yr_get(node, "e"), out);
    } else if (ys_eq_lit(k, "bin")) {
        return uses_scan_node(yr_get(node, "r"),
                              uses_scan_node(yr_get(node, "l"), out));
    } else if (ys_eq_lit(k, "addr") || ys_eq_lit(k, "deref")) {
        return uses_scan_node(yr_get(node, "e"), out);
    } else if (ys_eq_lit(k, "if")) {
        return uses_scan_node(yr_get(node, "els"),
                              uses_scan_node(yr_get(node, "then"),
                                             uses_scan_node(
                                                 yr_get(node, "cond"), out)));
    } else if (ys_eq_lit(k, "while")) {
        return uses_scan_node(yr_get(node, "body"),
                              uses_scan_node(yr_get(node, "cond"), out));
    } else if (ys_eq_lit(k, "block")) {
        return uses_scan_block(yr_get(node, "stmts"), out);
    } else if (ys_eq_lit(k, "decl")) {
        return uses_scan_node(yr_get(node, "v"), out);
    } else if (ys_eq_lit(k, "func")) {
        return uses_scan_node(yr_get(node, "body"), out);
    } else if (ys_eq_lit(k, "assign")) {
        return uses_scan_node(yr_get(node, "v"), out);
    } else if (ys_eq_lit(k, "incdec")) {
        return uses_scan_node(yr_get(node, "tgt"), out);
    } else if (ys_eq_lit(k, "opassign")) {
        return uses_scan_node(yr_get(node, "v"),
                              uses_scan_node(yr_get(node, "tgt"), out));
    } else if (ys_eq_lit(k, "store")) {
        return uses_scan_node(yr_get(node, "v"),
                              uses_scan_node(yr_get(node, "p"), out));
    } else if (ys_eq_lit(k, "ret")) {
        return uses_scan_node(yr_get(node, "e"), out);
    } else if (ys_eq_lit(k, "array")) {
        return uses_scan_block(yr_get(node, "elems"), out);
    } else if (ys_eq_lit(k, "arrrep")) {
        return uses_scan_node(yr_get(node, "v"), out);
    } else if (ys_eq_lit(k, "rec")) {
        return uses_scan_block(yr_get(node, "vals"), out);
    } else if (ys_eq_lit(k, "map")) {
        return uses_scan_block(yr_get(node, "vals"), out);
    } else if (ys_eq_lit(k, "index")) {
        return uses_scan_node(yr_get(node, "idx"),
                              uses_scan_node(yr_get(node, "arr"), out));
    } else if (ys_eq_lit(k, "slice")) {
        return uses_scan_node(yr_get(node, "hi"),
                              uses_scan_node(yr_get(node, "lo"),
                                             uses_scan_node(
                                                 yr_get(node, "arr"), out)));
    } else if (ys_eq_lit(k, "idxassign")) {
        return uses_scan_node(yr_get(node, "v"),
                              uses_scan_node(yr_get(node, "idx"),
                                             uses_scan_node(
                                                 yr_get(node, "arr"), out)));
    } else if (ys_eq_lit(k, "dotassign")) {
        return uses_scan_node(yr_get(node, "v"),
                              uses_scan_node(yr_get(node, "obj"), out));
    } else if (ys_eq_lit(k, "foreach")) {
        return uses_scan_node(yr_get(node, "body"),
                              uses_scan_node(yr_get(node, "iter"), out));
    } else if (ys_eq_lit(k, "forrange")) {
        return uses_scan_node(yr_get(node, "body"),
                              uses_scan_node(yr_get(node, "hi"),
                                             uses_scan_node(
                                                 yr_get(node, "lo"), out)));
    } else if (ys_eq_lit(k, "for")) {
        return uses_scan_node(yr_get(node, "body"),
                              uses_scan_node(yr_get(node, "step"),
                                             uses_scan_node(
                                                 yr_get(node, "cond"),
                                                 uses_scan_node(
                                                     yr_get(node, "init"),
                                                     out))));
    } else if (ys_eq_lit(k, "sliceassign")) {
        return uses_scan_node(yr_get(node, "v"),
                              uses_scan_node(yr_get(node, "hi"),
                                             uses_scan_node(yr_get(node, "lo"),
                                                            uses_scan_node(yr_get(node, "arr"), out))));
    } else if (ys_eq_lit(k, "rectest") || ys_eq_lit(k, "narrow") || ys_eq_lit(k, "matchend")) {
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
    if (ys_eq_lit(k, "decl")) {
        if (ys_eq_lit(yr_get(node, "kind"), "def")) {
            out = ya_push(out, yr(2, "name", yr_get(node, "name"), "func",
                                  yr_get(node, "v")));
            out = collect_from_node(yr_get(node, "v"), out);
            ;
        } else {
            if (ys_eq_lit(yr_get(yr_get(node, "v"), "k"), "func")) {
                out = ya_push(out, yr(2, "name", yr_get(node, "name"), "func",
                                      yr_get(node, "v")));
                ;
            } else {
                ;
            }
            out = collect_from_node(yr_get(node, "v"), out);
            ;
        }
    } else if (ys_eq_lit(k, "func")) {
        out = collect_from_block(yr_get(yr_get(node, "body"), "stmts"), out);
        ;
    } else if (ys_eq_lit(k, "if")) {
        out = collect_from_node(yr_get(node, "then"), out);
        if (yv_b(yr_get(node, "has_else"))) {
            out = collect_from_node(yr_get(node, "els"), out);
            ;
        } else {
            ;
        }
        ;
    } else if (ys_eq_lit(k, "while")) {
        out = collect_from_node(yr_get(node, "body"), out);
        ;
    } else if (ys_eq_lit(k, "for")) {
        out = collect_from_node(yr_get(node, "init"), out);
        out = collect_from_node(yr_get(node, "body"), out);
        out = collect_from_node(yr_get(node, "step"), out);
        ;
    } else if (ys_eq_lit(k, "foreach")) {
        out = collect_from_node(yr_get(node, "body"), out);
        ;
    } else if (ys_eq_lit(k, "forrange")) {
        out = collect_from_node(yr_get(node, "body"), out);
        ;
    } else if (ys_eq_lit(k, "block")) {
        out = collect_from_block(yr_get(node, "stmts"), out);
        ;
    } else {
        ;
    }
    return out;
}

/* ── free variables (closure conversion) ────────────────────────────────
 * A function that reads a name bound by an ENCLOSING function captures it.
 * The capture list is computed purely syntactically (rename.y has already
 * made every binding unique), so the creation site and the body emitter
 * derive the same ordered list independently. */

int name_in(Yv *xs, Yv *n) {
    long i = 0;
    int found = 0;
    while (i < yv_len(xs)) {
        Yv *x = ya_get(xs, i);
        if (ys_eq(x, n)) {
            found = 1;
            ;
        } else {
            ;
        }
        i = i + 1;
    }
    return found;
}

/* Builtins are resolved by name at the call site, never captured. */
int is_intrinsic_name(Yv *n) {
    return name_in(
        yav(36, ys("print"), ys("syscall"), ys("len"), ys("push"), ys("some"),
            ys("is_some"), ys("unwrap"), ys("substr"), ys("trim"), ys("ord"),
            ys("byte_at"), ys("chr"), ys("tonum"), ys("tostring"),
            ys("index_of"), ys("prepend"), ys("last_index_of"), ys("join"),
            ys("split"), ys("puts"), ys("eputs"), ys("clock_us"), ys("sleep"),
            ys("heap_used"), ys("exit"), ys("argv"), ys("read_file"),
            ys("write_file"), ys("write_bytes"), ys("range"), ys("typeof"),
            ys("bytes"), ys("from_bytes"), ys("ptr_addr"), ys("self"),
            ys("none")),
        n);
}

/* Every identifier READ in a subtree (callee names included: calling a
 * captured closure needs the name captured too). With `collect` false,
 * only the reads inside nested functions count (see box_names). */
Yv *fv_walk(Yv *node, Yv *out, int collect) {
    Yv *k = yr_get(node, "k");
    if (ys_eq_lit(k, "id")) {
        if (collect) { out = ya_push(out, yr_get(node, "v")); ; } else { ; };
        ;
    } else if (ys_eq_lit(k, "un")) {
        out = fv_walk(yr_get(node, "e"), out, collect);
        ;
    } else if (ys_eq_lit(k, "addr")) {
        out = fv_walk(yr_get(node, "e"), out, collect);
        ;
    } else if (ys_eq_lit(k, "deref")) {
        out = fv_walk(yr_get(node, "e"), out, collect);
        ;
    } else if (ys_eq_lit(k, "ret")) {
        out = fv_walk(yr_get(node, "e"), out, collect);
        ;
    } else if (ys_eq_lit(k, "bin")) {
        out = fv_walk(yr_get(node, "l"), out, collect);
        out = fv_walk(yr_get(node, "r"), out, collect);
        ;
    } else if (ys_eq_lit(k, "array")) {
        out = fv_walk_list(yr_get(node, "elems"), out, collect);
        ;
    } else if (ys_eq_lit(k, "rec")) {
        out = fv_walk_list(yr_get(node, "vals"), out, collect);
        ;
    } else if (ys_eq_lit(k, "map")) {
        out = fv_walk_list(yr_get(node, "vals"), out, collect);
        ;
    } else if (ys_eq_lit(k, "arrrep")) {
        out = fv_walk(yr_get(node, "v"), out, collect);
        ;
    } else if (ys_eq_lit(k, "call")) {
        out = fv_walk(yr_get(node, "callee"), out, collect);
        out = fv_walk_list(yr_get(node, "args"), out, collect);
        ;
    } else if (ys_eq_lit(k, "index")) {
        out = fv_walk(yr_get(node, "arr"), out, collect);
        out = fv_walk(yr_get(node, "idx"), out, collect);
        ;
    } else if (ys_eq_lit(k, "slice")) {
        out = fv_walk(yr_get(node, "arr"), out, collect);
        out = fv_walk(yr_get(node, "lo"), out, collect);
        out = fv_walk(yr_get(node, "hi"), out, collect);
        ;
    } else if (ys_eq_lit(k, "idxassign")) {
        out = fv_walk(yr_get(node, "arr"), out, collect);
        out = fv_walk(yr_get(node, "idx"), out, collect);
        out = fv_walk(yr_get(node, "v"), out, collect);
        ;
    } else if (ys_eq_lit(k, "dot")) {
        out = fv_walk(yr_get(node, "obj"), out, collect);
        ;
    } else if (ys_eq_lit(k, "dotassign")) {
        out = fv_walk(yr_get(node, "obj"), out, collect);
        out = fv_walk(yr_get(node, "v"), out, collect);
        ;
    } else if (ys_eq_lit(k, "store")) {
        out = fv_walk(yr_get(node, "p"), out, collect);
        out = fv_walk(yr_get(node, "v"), out, collect);
        ;
    } else if (ys_eq_lit(k, "assign")) {
        if (collect) { out = ya_push(out, yr_get(node, "name")); ; } else { ; };
        out = fv_walk(yr_get(node, "v"), out, collect);
        ;
    } else if (ys_eq_lit(k, "incdec")) {
        out = fv_walk(yr_get(node, "tgt"), out, collect);
        ;
    } else if (ys_eq_lit(k, "opassign")) {
        out = fv_walk(yr_get(node, "tgt"), out, collect);
        out = fv_walk(yr_get(node, "v"), out, collect);
        ;
    } else if (ys_eq_lit(k, "decl")) {
        out = fv_walk(yr_get(node, "v"), out, collect);
        ;
    } else if (ys_eq_lit(k, "if")) {
        out = fv_walk(yr_get(node, "cond"), out, collect);
        out = fv_walk(yr_get(node, "then"), out, collect);
        if (yv_b(yr_get(node, "has_else"))) {
            out = fv_walk(yr_get(node, "els"), out, collect);
            ;
        } else {
            ;
        }
        ;
    } else if (ys_eq_lit(k, "while")) {
        out = fv_walk(yr_get(node, "cond"), out, collect);
        out = fv_walk(yr_get(node, "body"), out, collect);
        ;
    } else if (ys_eq_lit(k, "for")) {
        out = fv_walk(yr_get(node, "init"), out, collect);
        out = fv_walk(yr_get(node, "cond"), out, collect);
        out = fv_walk(yr_get(node, "step"), out, collect);
        out = fv_walk(yr_get(node, "body"), out, collect);
        ;
    } else if (ys_eq_lit(k, "foreach")) {
        out = fv_walk(yr_get(node, "iter"), out, collect);
        out = fv_walk(yr_get(node, "body"), out, collect);
        ;
    } else if (ys_eq_lit(k, "forrange")) {
        out = fv_walk(yr_get(node, "lo"), out, collect);
        out = fv_walk(yr_get(node, "hi"), out, collect);
        out = fv_walk(yr_get(node, "body"), out, collect);
        ;
    } else if (ys_eq_lit(k, "block")) {
        out = fv_walk_list(yr_get(node, "stmts"), out, collect);
        ;
    } else if (ys_eq_lit(k, "func")) {
        out = fv_walk(yr_get(node, "body"), out, 1);
        ;
    } else if (ys_eq_lit(k, "sliceassign")) {
        out = fv_walk(yr_get(node, "arr"), out, collect);
        out = fv_walk(yr_get(node, "lo"), out, collect);
        out = fv_walk(yr_get(node, "hi"), out, collect);
        out = fv_walk(yr_get(node, "v"), out, collect);
    } else if (ys_eq_lit(k, "rectest") || ys_eq_lit(k, "narrow") || ys_eq_lit(k, "matchend")) {
        out = fv_walk(yr_get(node, "e"), out, collect);
    } else {
        ;
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
    if (ys_eq_lit(k, "decl")) {
        out = ya_push(out, yr_get(node, "name"));
        out = fv_binds(yr_get(node, "v"), out);
        ;
    } else if (ys_eq_lit(k, "func")) {
        out = fv_bind_params(yr_get(node, "params"), out);
        out = fv_binds(yr_get(node, "body"), out);
        ;
    } else if (ys_eq_lit(k, "block")) {
        out = fv_binds_list(yr_get(node, "stmts"), out);
        ;
    } else if (ys_eq_lit(k, "if")) {
        out = fv_binds(yr_get(node, "cond"), out);
        out = fv_binds(yr_get(node, "then"), out);
        if (yv_b(yr_get(node, "has_else"))) {
            out = fv_binds(yr_get(node, "els"), out);
            ;
        } else {
            ;
        }
        ;
    } else if (ys_eq_lit(k, "while")) {
        out = fv_binds(yr_get(node, "cond"), out);
        out = fv_binds(yr_get(node, "body"), out);
        ;
    } else if (ys_eq_lit(k, "for")) {
        out = fv_binds(yr_get(node, "init"), out);
        out = fv_binds(yr_get(node, "cond"), out);
        out = fv_binds(yr_get(node, "step"), out);
        out = fv_binds(yr_get(node, "body"), out);
        ;
    } else if (ys_eq_lit(k, "foreach")) {
        out = ya_push(out, yr_get(node, "name"));
        out = fv_binds(yr_get(node, "iter"), out);
        out = fv_binds(yr_get(node, "body"), out);
        ;
    } else if (ys_eq_lit(k, "forrange")) {
        out = ya_push(out, yr_get(node, "name"));
        out = fv_binds(yr_get(node, "lo"), out);
        out = fv_binds(yr_get(node, "hi"), out);
        out = fv_binds(yr_get(node, "body"), out);
        ;
    } else if (ys_eq_lit(k, "ret")) {
        out = fv_binds(yr_get(node, "e"), out);
        ;
    } else if (ys_eq_lit(k, "un")) {
        out = fv_binds(yr_get(node, "e"), out);
        ;
    } else if (ys_eq_lit(k, "addr")) {
        out = fv_binds(yr_get(node, "e"), out);
        ;
    } else if (ys_eq_lit(k, "deref")) {
        out = fv_binds(yr_get(node, "e"), out);
        ;
    } else if (ys_eq_lit(k, "bin")) {
        out = fv_binds(yr_get(node, "l"), out);
        out = fv_binds(yr_get(node, "r"), out);
        ;
    } else if (ys_eq_lit(k, "array")) {
        out = fv_binds_list(yr_get(node, "elems"), out);
        ;
    } else if (ys_eq_lit(k, "rec")) {
        out = fv_binds_list(yr_get(node, "vals"), out);
        ;
    } else if (ys_eq_lit(k, "map")) {
        out = fv_binds_list(yr_get(node, "vals"), out);
        ;
    } else if (ys_eq_lit(k, "arrrep")) {
        out = fv_binds(yr_get(node, "v"), out);
        ;
    } else if (ys_eq_lit(k, "call")) {
        out = fv_binds(yr_get(node, "callee"), out);
        out = fv_binds_list(yr_get(node, "args"), out);
        ;
    } else if (ys_eq_lit(k, "index")) {
        out = fv_binds(yr_get(node, "arr"), out);
        out = fv_binds(yr_get(node, "idx"), out);
        ;
    } else if (ys_eq_lit(k, "slice")) {
        out = fv_binds(yr_get(node, "arr"), out);
        out = fv_binds(yr_get(node, "lo"), out);
        out = fv_binds(yr_get(node, "hi"), out);
        ;
    } else if (ys_eq_lit(k, "idxassign")) {
        out = fv_binds(yr_get(node, "arr"), out);
        out = fv_binds(yr_get(node, "idx"), out);
        out = fv_binds(yr_get(node, "v"), out);
        ;
    } else if (ys_eq_lit(k, "dot")) {
        out = fv_binds(yr_get(node, "obj"), out);
        ;
    } else if (ys_eq_lit(k, "dotassign")) {
        out = fv_binds(yr_get(node, "obj"), out);
        out = fv_binds(yr_get(node, "v"), out);
        ;
    } else if (ys_eq_lit(k, "store")) {
        out = fv_binds(yr_get(node, "p"), out);
        out = fv_binds(yr_get(node, "v"), out);
        ;
    } else if (ys_eq_lit(k, "assign")) {
        out = fv_binds(yr_get(node, "v"), out);
        ;
    } else if (ys_eq_lit(k, "incdec")) {
        out = fv_binds(yr_get(node, "tgt"), out);
        ;
    } else if (ys_eq_lit(k, "opassign")) {
        out = fv_binds(yr_get(node, "tgt"), out);
        out = fv_binds(yr_get(node, "v"), out);
        ;
    } else if (ys_eq_lit(k, "sliceassign")) {
        out = fv_binds(yr_get(node, "arr"), out);
        out = fv_binds(yr_get(node, "lo"), out);
        out = fv_binds(yr_get(node, "hi"), out);
        out = fv_binds(yr_get(node, "v"), out);
    } else {
        ;
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
Yv *fn_captures(Yv *func, Yv *fnnames) {
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
        } else if (name_in(fnnames, n)) {
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

/* Is some function emitted under exactly this label? Used to detect a
 * --prof build (the spliced std/prof.y defines y_prof_enter) without
 * threading the flag through every emitter signature. */
int fn_label_present(Yv *fns, Yv *label) {
    long i = 0;
    int found = 0;
    while (i < yv_len(fns)) {
        Yv *e = ya_get(fns, i);
        if (ys_eq(yr_get(e, "label"), label)) {
            found = 1;
            ;
        } else {
            ;
        }
        i = i + 1;
    }
    return found;
}

/* st.fns holds the hoisted defs and, after them, the globals (see
 * emit_program); a global's label is its .bss cell. */
Yv *fns_kind(Yv *label) {
    if (ys_eq_lit(ys_substr(label, 0, 3), "yg_")) {
        return ys("global");
    } else {
        return ys("func");
    }
}

/* ── expression emission (value in %rax) ──────────────────────────────── */

Yv *gen(Yv *st, Yv *node) {
    Yv *k = yr_get(node, "k");
    if (ys_eq_lit(k, "num")) {
        return gen_lit(st, node);
    } else if (ys_eq_lit(k, "bool")) {
        if (ys_eq_lit(yr_get(node, "v"), "true")) {
            return emit(st, ys("    mov $1, %rax"));
        } else {
            return emit(st, ys("    xor %eax, %eax"));
        }
    } else if (ys_eq_lit(k, "str")) {
        return gen_str_const(st, yr_get(node, "v"));
    } else if (ys_eq_lit(k, "bstr")) {
        return gen_bstr(st, node);
    } else if (ys_eq_lit(k, "void")) {
        return emit(st, ys("    xor %eax, %eax"));
    } else if (ys_eq_lit(k, "id")) {
        return gen_id(st, node);
    } else if (ys_eq_lit(k, "un")) {
        return gen_un(st, node);
    } else if (ys_eq_lit(k, "addr")) {
        return gen_addr(st, node);
    } else if (ys_eq_lit(k, "array")) {
        return gen_array(st, node);
    } else if (ys_eq_lit(k, "deref")) {
        st = gen(st, yr_get(node, "e"));
        return emit(st, ys("    mov (%rax), %rax"));
    } else if (ys_eq_lit(k, "bin")) {
        return gen_bin(st, node);
    } else if (ys_eq_lit(k, "call")) {
        return gen_call(st, node);
    } else if (ys_eq_lit(k, "if")) {
        return gen_if(st, node);
    } else if (ys_eq_lit(k, "while")) {
        return gen_while(st, node);
    } else if (ys_eq_lit(k, "for")) {
        return gen_for(st, node);
    } else if (ys_eq_lit(k, "forrange")) {
        return gen_forrange(st, node);
    } else if (ys_eq_lit(k, "foreach")) {
        return gen_foreach(st, node);
    } else if (ys_eq_lit(k, "block")) {
        return gen_block(st, node);
    } else if (ys_eq_lit(k, "decl")) {
        return gen_decl(st, node);
    } else if (ys_eq_lit(k, "assign")) {
        return gen_assign(st, node);
    } else if (ys_eq_lit(k, "incdec")) {
        return gen_incdec(st, node);
    } else if (ys_eq_lit(k, "opassign")) {
        return gen_opassign(st, node);
    } else if (ys_eq_lit(k, "index")) {
        /* maps scan their keys; strings read a byte; arrays index directly */
        Yv *kbt = infer(st, yr_get(node, "arr"));
        if (ys_eq_lit(yr_get(kbt, "k"), "tmap")) {
            return gen_map_get(st, node);
        } else if (ys_eq_lit(yr_get(kbt, "k"), "tstr")) {
            return gen_byte_at(st, n_call2(ys("byte_at"), yr_get(node, "arr"), yr_get(node, "idx"), yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col"))));
        } else {
            return gen_index(st, node);
        }
    } else if (ys_eq_lit(k, "slice")) {
        Yv *sbt = infer(st, yr_get(node, "arr"));
        if (ys_eq_lit(yr_get(sbt, "k"), "tstr")) { return gen_str_slice(st, node); } else { return gen_slice(st, node); }
    } else if (ys_eq_lit(k, "char")) {
        return gen_lit(st, yr(4, "k", ys("num"), "v", yr_get(node, "v"), "line", yr_get(node, "line"), "col", yr_get(node, "col")));
    } else if (ys_eq_lit(k, "rectest")) {
        st = gen(st, yr_get(node, "e"));
        return gen_rectest_rax(st, type_names(yr_get(node, "typ")));
    } else if (ys_eq_lit(k, "narrow")) {
        /* the value itself; only its static type changes */
        return gen(st, yr_get(node, "e"));
    } else if (ys_eq_lit(k, "matchend")) {
        /* unreachable when the checker accepted the match */
        st = emit(st, ys("    call y_match_fail"));
        return emit(st, ys("    xor %eax, %eax"));
    } else if (ys_eq_lit(k, "sliceassign")) {
        return gen_sliceassign(st, node);
    } else if (ys_eq_lit(k, "idxassign")) {
        Yv *kbt = infer(st, yr_get(node, "arr"));
        if (ys_eq_lit(yr_get(kbt, "k"), "tmap")) { return gen_map_set(st, node); } else { return gen_idxassign(st, node); }
    } else if (ys_eq_lit(k, "dotassign")) {
        return gen_dotassign(st, node);
    } else if (ys_eq_lit(k, "dot")) {
        return gen_dot(st, node);
    } else if (ys_eq_lit(k, "rec")) {
        /* record literal anywhere (let/call-arg): heap address in %rax. */
        return gen_reclit(st, node);
    } else if (ys_eq_lit(k, "map")) {
        /* map literal: the {keys, vals} record, heap address in %rax. */
        return gen_maplit(st, node);
    } else if (ys_eq_lit(k, "arrrep")) {
        /* [v; n] anywhere (let/assign/call-arg): heap address in %rax. */
        return gen_arrrep(st, node);
    } else if (ys_eq_lit(k, "func")) {
        /* Anonymous function literal in expression position. */
        return gen_func_literal(st, node);
    } else if (ys_eq_lit(k, "store")) {
        return gen_store(st, node);
    } else if (ys_eq_lit(k, "ret")) {
        st = gen(st, yr_get(node, "e"));
        return emit(st, ys_cat(ys("    jmp "), yr_get(st, "end_label")));
    } else {
        /* Unreachable: the checker rejects everything else. */
        return emit(st, ys_cat(ys_cat(ys("    # INTERNAL: unhandled "), k),
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
        Yv *bnum = yr(4, "k", ys("num"), "v",
                       ys_long(ys_ord(ys_substr(bv, bi, 1))),
                       "line", yr_get(node, "line"), "col", yr_get(node, "col"));
        elems = ya_push(elems, bnum);
        bi = bi + 1;
    }
    Yv *barr = yr(4, "k", ys("array"), "elems", elems, "line", yr_get(node, "line"),
                  "col", yr_get(node, "col"));
    return gen_array_esz(st, barr, 1L);
}

Yv *gen_str_const(Yv *st, Yv *s) {
    Yv *r = next_uid(st);
    st = yr_get(r, "st");
    Yv *lbl = arch_str_label(yv_l(yr_get(r, "uid")));
    /* NOTE: push-chain over a let-bound [] (not a literal). The checker
     * rejects heterogeneous array literals ([str, long, str]); these three
     * parts are all str, so a literal would check too — the push-chain is
     * just the shape the other node-list builders use. */
    Yv *rod0 = yav(0);
    rod0 = ya_push(rod0, lbl);
    rod0 = ya_push(rod0, ys_long(yv_len(s)));
    rod0 = ya_push(rod0, esc_asm(s));
    Yv *rod = ya_push(yr_get(st, "rodata"), rod0);
    st = yr(11, "out", yr_get(st, "out"), "rodata", rod, "uid",
            yr_get(st, "uid"), "fuid", yr_get(st, "fuid"), "loc",
            yr_get(st, "loc"), "env", yr_get(st, "env"), "slots",
            yr_get(st, "slots"), "self_label", yr_get(st, "self_label"),
            "end_label", yr_get(st, "end_label"), "fns", yr_get(st, "fns"),
            "bodies", yr_get(st, "bodies"));
    return emit(st, ys_cat(ys_cat(ys("    lea "), lbl), ys("(%rip), %rax")));
}

Yv *gen_id(Yv *st, Yv *node) {
    if (ys_eq_lit(yr_get(node, "v"), "self")) {
        /* Bare `self` as a value: only legal in discarded positions
         * (the checker rejects every typed use). Emit zero (none). */
        return emit(st, ys("    xor %eax, %eax  # bare self (discarded)"));
    } else if (ys_eq_lit(yr_get(node, "v"), "none")) {
        /* The empty option (checker gives it typeof from context). */
        return emit(st, ys("    xor %eax, %eax"));
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
            if (ys_eq(yr_get(e, "label"), yr_get(st, "self_label"))) {
                soff = capture_off(st);
                ;
            } else {
                ;
            }
            if (soff >= 0) {
                return emit(st, ys_cat(ys_cat(ys("    mov "), ys_long(soff)),
                                       ys("(%rbp), %rax")));
            } else {
                return gen_make_closure(st, yr_get(e, "label"), yav(0));
            }
        } else if (ys_eq_lit(yr_get(e, "kind"), "global")) {
            return emit(st, ys_cat(ys_cat(ys("    mov "), yr_get(e, "label")),
                                   ys("(%rip), %rax")));
        } else if (ys_eq_lit(yr_get(e, "kind"), "capture")) {
            /* Captured by the enclosing closure: load the closure record
             * (at the frame offset recorded in `off`), read slot idx+1 —
             * the shared cell pointer — and deref it (see box_capture).
             * NOTE: the index rides in `label` — env entries have no spare
             * numeric field and adding one would touch every signature. */
            long idx = ys_tonum(yr_get(e, "label"));
            st = emit(st, ys_cat(ys_cat(ys("    mov "),
                                       ys_long(yv_l(yr_get(e, "off")))),
                                ys("(%rbp), %rcx")));
            st = emit(st, ys_cat(ys_cat(ys("    mov "),
                                       ys_long(8 * (idx + 1))),
                                ys("(%rcx), %rax")));
            return emit(st, ys("    mov (%rax), %rax"));
        } else if (ys_eq_lit(yr_get(e, "kind"), "box")) {
            /* A captured variable's shared cell; the slot holds its
             * pointer. */
            st = emit(st, ys_cat(ys_cat(ys("    mov "),
                                       ys_long(yv_l(yr_get(e, "off")))),
                                ys("(%rbp), %rax")));
            return emit(st, ys("    mov (%rax), %rax"));
        } else {
            return emit(st, ys_cat(ys_cat(ys("    mov "),
                                         ys_long(yv_l(yr_get(e, "off")))),
                                  ys("(%rbp), %rax")));
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
        long pidx = ys_tonum(yr_get(e, "label"));
        st = emit(st, ys_cat(ys_cat(ys("    mov "),
                                   ys_long(yv_l(yr_get(e, "off")))),
                            ys("(%rbp), %rcx")));
        return emit(st, ys_cat(ys_cat(ys("    mov "),
                                      ys_long(8 * (pidx + 1))),
                               ys("(%rcx), %rax")));
    } else {
        return emit(st, ys_cat(ys_cat(ys("    mov "),
                                      ys_long(yv_l(yr_get(e, "off")))),
                               ys("(%rbp), %rax")));
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
        st = gen_id(st, yr(4, "k", ys("id"), "v", name, "line", yv_long(0),
                           "col", yv_long(0)));
        st = emit(st, ys("    push %rax"));
        st = emit(st, ys("    mov $8, %rdi"));
        st = emit(st, ys("    call y_alloc"));
        st = emit(st, ys("    pop %rdx"));
        st = emit(st, ys("    mov %rdx, (%rax)"));
        long boff = (yv_l(yr_get(st, "slots")) + 1) * -8;
        st = emit(st, ys_cat(ys_cat(ys("    mov %rax, "), ys_long(boff)),
                             ys("(%rbp)")));
        Yv *st2 =
            yr(11, "out", yr_get(st, "out"), "rodata", yr_get(st, "rodata"),
               "uid", yr_get(st, "uid"), "fuid", yr_get(st, "fuid"), "loc",
               yr_get(st, "loc"), "env", yr_get(st, "env"), "slots",
               yv_long(yv_l(yr_get(st, "slots")) + 1), "self_label",
               yr_get(st, "self_label"), "end_label", yr_get(st, "end_label"),
               "fns", yr_get(st, "fns"), "bodies", yr_get(st, "bodies"));
        return env_define(st2, name, ys("box"), boff, ys(""), yr_get(e, "typ"));
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
                   ys_eq(yr_get(e, "label"), name)) {
            want = 1;
            more = 0;
            ;
        } else {
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

Yv *gen_make_closure(Yv *st, Yv *label, Yv *caps) {
    long n = yv_len(caps);
    st = emit(st, ys_cat(ys_cat(ys("    mov $"), ys_long(8 + 8 * n)),
                         ys(", %rdi")));
    st = emit(st, ys("    call y_alloc"));
    st = emit(st, ys("    push %rax"));
    st = emit(st, ys_cat(ys_cat(ys("    lea "), label), ys("(%rip), %rcx")));
    st = emit(st, ys("    mov %rcx, (%rax)"));
    long i = 0;
    while (i < n) {
        Yv *cn = ya_get(caps, i);
        /* Captured as a shared cell pointer (see box_capture). */
        st = gen_cap_ptr(st, cn);
        st = emit(st, ys("    pop %rcx"));
        st = emit(st, ys("    push %rcx"));
        st = emit(st, ys_cat(ys_cat(ys("    mov %rax, "),
                                    ys_long(8 * (i + 1))),
                             ys("(%rcx)")));
        i = i + 1;
    }
    return emit(st, ys("    pop %rax"));
}

/* range(n) -> [0, 1, ..., n-1] as a heap array (the loop-friendly builtin;
 * y_range in std/rt.y). */
Yv *gen_range(Yv *st, Yv *node) {
    st = gen_push_args(st, yr_get(node, "args"));
    st = emit(st, ys("    call y_range"));
    return emit(st, ys("    add $8, %rsp"));
}

/* arr[lo:hi] — half-open, clamped, always a NEW heap array (the operands
 * are untouched, like `+` on arrays). A missing bound means 0 / len. */
Yv *gen_slice(Yv *st, Yv *node) {
    Yv *lo = yr_get(node, "lo");
    Yv *hi = yr_get(node, "hi");
    long slesz = arr_elem_bytes(infer(st, yr_get(node, "arr")));
    st = gen(st, yr_get(node, "arr"));
    st = emit(st, ys("    push %rax"));
    if (ys_eq_lit(yr_get(lo, "k"), "void")) {
        st = emit(st, ys("    xor %eax, %eax"));
        ;
    } else {
        st = gen(st, lo);
        ;
    }
    st = emit(st, ys("    push %rax"));
    if (ys_eq_lit(yr_get(hi, "k"), "void")) {
        /* default: the array's length (the header keeps it in slot 0);
         * the array pointer sits one slot below the pushed lo. */
        st = emit(st, ys("    mov 8(%rsp), %rax"));
        st = emit(st, ys("    mov (%rax), %rax"));
        ;
    } else {
        st = gen(st, hi);
        ;
    }
    st = emit(st, ys("    push %rax"));
    st = emit(st, ys_cat(ys_cat(ys("    mov $"), ys_long(slesz)), ys(", %rax")));
    st = emit(st, ys("    push %rax"));
    st = emit(st, ys("    call y_arr_slice"));
    return emit(st, ys("    add $32, %rsp"));
}

// s[lo:hi] -- the substring, half-open and clamped like an array slice;
// a missing bound means 0 / len (y_str_slice in rt.y).
Yv *gen_str_slice(Yv *st, Yv *node) {
    Yv *lo = yr_get(node, "lo");
    Yv *hi = yr_get(node, "hi");
    st = gen(st, yr_get(node, "arr"));
    st = emit(st, ys("    push %rax"));
    if (ys_eq_lit(yr_get(lo, "k"), "void")) {
        st = emit(st, ys("    xor %eax, %eax"));
    } else {
        st = gen(st, lo);
    }
    st = emit(st, ys("    push %rax"));
    if (ys_eq_lit(yr_get(hi, "k"), "void")) {
        st = emit(st, ys("    mov 8(%rsp), %rax"));
        st = emit(st, ys("    mov (%rax), %rax"));
    } else {
        st = gen(st, hi);
    }
    st = emit(st, ys("    push %rax"));
    st = emit(st, ys("    call y_str_slice"));
    return emit(st, ys("    add $24, %rsp"));
}

// a[lo:hi] = src: y_arr_setslice{1,8} (rt.y) check the range and the
// length, then copy src's elements in. Evaluation order: a, lo, hi, src.
Yv *gen_sliceassign(Yv *st, Yv *node) {
    Yv *lo = yr_get(node, "lo");
    Yv *hi = yr_get(node, "hi");
    long esz = arr_elem_bytes(infer(st, yr_get(node, "arr")));
    st = gen(st, yr_get(node, "arr"));
    st = emit(st, ys("    push %rax"));
    if (ys_eq_lit(yr_get(lo, "k"), "void")) {
        st = emit(st, ys("    xor %eax, %eax"));
    } else {
        st = gen(st, lo);
    }
    st = emit(st, ys("    push %rax"));
    if (ys_eq_lit(yr_get(hi, "k"), "void")) {
        st = emit(st, ys("    mov 8(%rsp), %rax"));
        st = emit(st, ys("    mov (%rax), %rax"));
    } else {
        st = gen(st, hi);
    }
    st = emit(st, ys("    push %rax"));
    st = gen(st, yr_get(node, "v"));
    st = emit(st, ys("    push %rax"));
    st = emit(st, ys_cat(ys("    call y_arr_setslice"), ys_long(esz)));
    st = emit(st, ys("    add $32, %rsp"));
    return emit(st, ys("    xor %eax, %eax"));
}

// Record in %rax -> 1 when it has every field in names, else 0 (the
// record's own field table answers, through y_rec_has).
Yv *gen_rectest_rax(Yv *st, Yv *names) {
    if (yv_len(names) == 0) {
        return emit(st, ys("    mov $1, %rax"));
    } else {
        Yv *rfail = next_loc(st);
        st = yr_get(rfail, "st");
        Yv *rdone = next_loc(st);
        st = yr_get(rdone, "st");
        st = emit(st, ys("    push %rax"));
        long i = 0;
        while (i < yv_len(names)) {
            st = emit(st, ys("    mov (%rsp), %rax"));
            st = emit(st, ys("    push %rax"));
            st = gen_str_const(st, ya_get(names, i));
            st = emit(st, ys("    push %rax"));
            st = emit(st, ys("    call y_rec_has"));
            st = emit(st, ys("    add $16, %rsp"));
            st = emit(st, ys("    test %rax, %rax"));
            st = emit(st, ys_cat(ys("    jz "), yr_get(rfail, "lbl")));
            i = i + 1;
        }
        st = emit(st, ys("    add $8, %rsp"));
        st = emit(st, ys("    mov $1, %rax"));
        st = emit(st, ys_cat(ys("    jmp "), yr_get(rdone, "lbl")));
        st = emit(st, ys_cat(yr_get(rfail, "lbl"), ys(":")));
        st = emit(st, ys("    add $8, %rsp"));
        st = emit(st, ys("    xor %eax, %eax"));
        return emit(st, ys_cat(yr_get(rdone, "lbl"), ys(":")));
    }
}

// Union value in %rax -> its string form: the member it matches, tried
// from the one with the most fields down (the most specific shape wins).
Yv *gen_union_str_rax(Yv *st, Yv *t) {
    Yv *ms = yr_get(t, "ts");
    Yv *order = yav(0);
    long most = 0;
    long i = 0;
    while (i < yv_len(ms)) {
        long n = yv_len(type_names(ya_get(ms, i)));
        if (n > most) {
            most = n;
        }
        i = i + 1;
    }
    long want = most;
    while (want >= 0) {
        long j = 0;
        while (j < yv_len(ms)) {
            if (yv_len(type_names(ya_get(ms, j))) == want) {
                order = ya_push(order, ya_get(ms, j));
            }
            j = j + 1;
        }
        want = want - 1;
    }
    Yv *rdone = next_loc(st);
    st = yr_get(rdone, "st");
    st = emit(st, ys("    push %rax"));
    long m = 0;
    while (m < yv_len(order)) {
        Yv *rnext = next_loc(st);
        st = yr_get(rnext, "st");
        Yv *mt = ya_get(order, m);
        st = emit(st, ys("    mov (%rsp), %rax"));
        st = gen_rectest_rax(st, type_names(mt));
        st = emit(st, ys("    test %rax, %rax"));
        st = emit(st, ys_cat(ys("    jz "), yr_get(rnext, "lbl")));
        st = emit(st, ys("    pop %rax"));
        st = gen_rec_str_rax(st, mt);
        st = emit(st, ys_cat(ys("    jmp "), yr_get(rdone, "lbl")));
        st = emit(st, ys_cat(yr_get(rnext, "lbl"), ys(":")));
        m = m + 1;
    }
    st = emit(st, ys("    pop %rax"));
    st = gen_str_const(st, ys("<union>"));
    return emit(st, ys_cat(yr_get(rdone, "lbl"), ys(":")));
}

/* Indirect call through a closure value produced by `callee`. */
Yv *gen_indirect(Yv *st, Yv *node, Yv *callee) {
    Yv *args = yr_get(node, "args");
    long n = yv_len(args);
    st = gen(st, callee);
    st = emit(st, ys("    push %rax"));
    st = gen_push_args(st, args);
    /* Reload the closure (it sits just below the n pushed args) and call
     * through its code pointer. */
    st = emit(st, ys_cat(ys_cat(ys("    mov "), ys_long(8 * n)),
                         ys("(%rsp), %rax")));
    st = emit(st, ys("    mov (%rax), %rax"));
    st = emit(st, ys("    call *%rax"));
    return emit(st, ys_cat(ys_cat(ys("    add $"), ys_long(8 * (n + 1))),
                          ys(", %rsp")));
}

Yv *gen_un(Yv *st, Yv *node) {
    Yv *ut = infer(st, yr_get(node, "e"));
    st = gen(st, yr_get(node, "e"));
    if (ys_eq_lit(yr_get(node, "op"), "-")) {
        if (ys_eq_lit(yr_get(ut, "k"), "tfloat")) {
            /* 0.0 - x (no SSE negate form emitted by this backend) */
            st = emit(st, ys("    movq %rax, %xmm1"));
            st = emit(st, ys("    xor %ecx, %ecx"));
            st = emit(st, ys("    movq %rcx, %xmm0"));
            st = emit(st, ys("    subsd %xmm1, %xmm0"));
            return emit(st, ys("    movq %xmm0, %rax"));
        } else {
            return emit(st, ys("    neg %rax"));
        }
    } else {
        return emit(st, ys("    xor $1, %rax"));
    }
}

Yv *gen_addr(Yv *st, Yv *node) {
    /* Checker guarantees plain ids, or id-rooted index into an array. */
    if (ys_eq_lit(yr_get(yr_get(node, "e"), "k"), "index")) {
        return gen_elem_addr(st, yr_get(node, "e"));
    } else {
        Yv *e = env_find(st, yr_get(yr_get(node, "e"), "v"));
        if (ys_eq_lit(yr_get(e, "kind"), "box")) {
            /* the shared cell IS the variable's address */
            return emit(st, ys_cat(ys_cat(ys("    mov "),
                                         ys_long(yv_l(yr_get(e, "off")))),
                                  ys("(%rbp), %rax")));
        } else if (ys_eq_lit(yr_get(e, "kind"), "global")) {
            return emit(st, ys_cat(ys_cat(ys("    lea "),
                                         yr_get(e, "label")),
                                  ys("(%rip), %rax")));
        } else if (ys_eq_lit(yr_get(e, "kind"), "capture")) {
            long aidx = ys_tonum(yr_get(e, "label"));
            st = emit(st, ys_cat(ys_cat(ys("    mov "),
                                       ys_long(yv_l(yr_get(e, "off")))),
                                ys("(%rbp), %rcx")));
            return emit(st, ys_cat(ys_cat(ys("    mov "),
                                         ys_long(8 * (aidx + 1))),
                                  ys("(%rcx), %rax")));
        } else {
            return emit(st, ys_cat(ys_cat(ys("    lea "),
                                         ys_long(yv_l(yr_get(e, "off")))),
                                  ys("(%rbp), %rax")));
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
    Yv *eascale = ys("8");
    if (eaesz == 1) {
        eascale = ys("1");
        ;
    } else {
        ;
    }
    st = gen(st, earr);
    st = emit(st, ys("    push %rax"));
    st = gen(st, yr_get(node, "idx"));
    st = emit(st, ys("    mov %rax, %rcx"));
    st = emit(st, ys("    pop %rax"));
    st = emit(st, ys("    test %rcx, %rcx"));
    st = emit(st, ys("    js y_oob"));
    if (ys_eq_lit(yr_get(bt, "k"), "tarrfix")) {
        st = emit(st, ys_cat(ys_cat(ys("    cmp $"),
                                    ys_long(yv_l(yr_get(bt, "n")))),
                             ys(", %rcx")));
        st = emit(st, ys("    jge y_oob"));
        ;
    } else {
        st = emit(st, ys("    mov (%rax), %rdx"));
        st = emit(st, ys("    cmp %rdx, %rcx"));
        st = emit(st, ys("    jge y_oob"));
        ;
    }
    st = emit(st, ys("    mov 16(%rax), %rax"));
    return emit(st, ys_cat(ys_cat(ys("    lea (%rax,%rcx,"), eascale),
                           ys("), %rax")));
}

Yv *gen_bin(Yv *st, Yv *node) {
    Yv *op = yr_get(node, "op");
    /* Lazy &&/||: short-circuit jumps, not eager and/or (the right operand
     * must not run when the left already decides). */
    if (ys_eq_lit(op, "&&")) {
        return gen_logic(st, node, 0);
    } else if (ys_eq_lit(op, "||")) {
        return gen_logic(st, node, 1);
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
    st = emit(st, ys("    test %rax, %rax"));
    if (is_or) {
        st = emit(st, ys_cat(ys("    jnz "), yr_get(rT, "lbl")));
        ;
    } else {
        ;
    }
    if (is_or) {
        ;
    } else {
        st = emit(st, ys_cat(ys("    jz "), yr_get(rF, "lbl")));
        ;
    }
    st = gen(st, yr_get(node, "r"));
    st = emit(st, ys("    test %rax, %rax"));
    if (is_or) {
        st = emit(st, ys_cat(ys("    jnz "), yr_get(rT, "lbl")));
        ;
    } else {
        ;
    }
    if (is_or) {
        ;
    } else {
        st = emit(st, ys_cat(ys("    jz "), yr_get(rF, "lbl")));
        ;
    }
    if (is_or) {
        ;
    } else {
        st = emit(st, ys("    mov $1, %rax"));
        st = emit(st, ys_cat(ys("    jmp "), yr_get(rE, "lbl")));
        ;
    }
    if (is_or) {
        st = emit(st, ys("    xor %eax, %eax"));
        st = emit(st, ys_cat(ys("    jmp "), yr_get(rE, "lbl")));
        st = emit(st, ys_cat(yr_get(rT, "lbl"), ys(":")));
        st = emit(st, ys("    mov $1, %rax"));
        ;
    } else {
        ;
    }
    if (is_or) {
        ;
    } else {
        st = emit(st, ys_cat(yr_get(rF, "lbl"), ys(":")));
        st = emit(st, ys("    xor %eax, %eax"));
        ;
    }
    return emit(st, ys_cat(yr_get(rE, "lbl"), ys(":")));
}

/* AUTO-STRINGIFY `+`: when a string meets a non-string, stringify the other
 * side (y_long_tostr / y_bool_tostr) and concatenate — the same semantics
 * types.y's typeof_arith gives. tstr+tstr is a plain concat; tstr+tunk falls
 * back to the raw pointer concat (the old behavior) since the runtime type
 * is unknown statically. */
Yv *gen_cat(Yv *st, Yv *node, Yv *lt, Yv *rt) {
    /* NOTE: y_long_tostr / y_bool_tostr take ONE STACK ARG (push; call;
     * add $8) — gen_tostring's pattern. y_str_cat takes two stack args. */
    if (ys_eq_lit(yr_get(lt, "k"), "tarr") ||
        ys_eq_lit(yr_get(lt, "k"), "tarrfix") ||
        ys_eq_lit(yr_get(rt, "k"), "tarr") ||
        ys_eq_lit(yr_get(rt, "k"), "tarrfix")) {
        return gen_cat_arr(st, node, lt, rt);
    }
    if (ys_eq_lit(yr_get(lt, "k"), "tstr")) {
        if (ys_eq_lit(yr_get(rt, "k"), "tstr")) {
            st = gen_push_args(st, yav(2, yr_get(node, "l"),
                                      yr_get(node, "r")));
            st = emit(st, ys("    call y_str_cat"));
            st = emit(st, ys("    add $16, %rsp"));
        } else if (ys_eq_lit(yr_get(rt, "k"), "tlong")) {
            st = gen(st, yr_get(node, "l"));
            st = emit(st, ys("    push %rax"));
            st = gen(st, yr_get(node, "r"));
            st = emit(st, ys("    push %rax"));
            st = emit(st, ys("    call y_long_tostr"));
            st = emit(st, ys("    add $8, %rsp"));
            st = emit(st, ys("    push %rax"));
            st = emit(st, ys("    call y_str_cat"));
            st = emit(st, ys("    add $16, %rsp"));
        } else if (ys_eq_lit(yr_get(rt, "k"), "tbool")) {
            st = gen(st, yr_get(node, "l"));
            st = emit(st, ys("    push %rax"));
            st = gen(st, yr_get(node, "r"));
            st = emit(st, ys("    push %rax"));
            st = emit(st, ys("    call y_bool_tostr"));
            st = emit(st, ys("    add $8, %rsp"));
            st = emit(st, ys("    push %rax"));
            st = emit(st, ys("    call y_str_cat"));
            st = emit(st, ys("    add $16, %rsp"));
        } else if (ys_eq_lit(yr_get(rt, "k"), "tfloat")) {
            st = gen(st, yr_get(node, "l"));
            st = emit(st, ys("    push %rax"));
            st = gen(st, yr_get(node, "r"));
            st = emit(st, ys("    push %rax"));
            st = emit(st, ys("    call y_float_tostr"));
            st = emit(st, ys("    add $8, %rsp"));
            st = emit(st, ys("    push %rax"));
            st = emit(st, ys("    call y_str_cat"));
            st = emit(st, ys("    add $16, %rsp"));
        } else {
            /* Unknown right operand: treat it as a string. Most unknowns
             * here ARE strings (a field read through an untyped hole infers
             * as tunk — the compiler's own tstr() does exactly that), and
             * the return-type inference in emit_program now pins down the
             * long-returning calls that used to land in this arm. */
            st = gen_push_args(st, yav(2, yr_get(node, "l"),
                                      yr_get(node, "r")));
            st = emit(st, ys("    call y_str_cat"));
            st = emit(st, ys("    add $16, %rsp"));
        }
        ;
    } else {
        ;
    }
    if (!ys_eq_lit(yr_get(lt, "k"), "tstr")) {
        if (ys_eq_lit(yr_get(lt, "k"), "tlong")) {
            st = gen(st, yr_get(node, "l"));
            st = emit(st, ys("    push %rax"));
            st = emit(st, ys("    call y_long_tostr"));
            st = emit(st, ys("    add $8, %rsp"));
            st = emit(st, ys("    push %rax"));
            st = gen(st, yr_get(node, "r"));
            st = emit(st, ys("    push %rax"));
            st = emit(st, ys("    call y_str_cat"));
            st = emit(st, ys("    add $16, %rsp"));
        } else if (ys_eq_lit(yr_get(lt, "k"), "tbool")) {
            st = gen(st, yr_get(node, "l"));
            st = emit(st, ys("    push %rax"));
            st = emit(st, ys("    call y_bool_tostr"));
            st = emit(st, ys("    add $8, %rsp"));
            st = emit(st, ys("    push %rax"));
            st = gen(st, yr_get(node, "r"));
            st = emit(st, ys("    push %rax"));
            st = emit(st, ys("    call y_str_cat"));
            st = emit(st, ys("    add $16, %rsp"));
        } else if (ys_eq_lit(yr_get(lt, "k"), "tfloat")) {
            st = gen(st, yr_get(node, "l"));
            st = emit(st, ys("    push %rax"));
            st = emit(st, ys("    call y_float_tostr"));
            st = emit(st, ys("    add $8, %rsp"));
            st = emit(st, ys("    push %rax"));
            st = gen(st, yr_get(node, "r"));
            st = emit(st, ys("    push %rax"));
            st = emit(st, ys("    call y_str_cat"));
            st = emit(st, ys("    add $16, %rsp"));
        } else {
            /* Unknown left operand: treat it as a string (see the note on
             * the right-operand arm). */
            st = gen_push_args(st, yav(2, yr_get(node, "l"),
                                      yr_get(node, "r")));
            st = emit(st, ys("    call y_str_cat"));
            st = emit(st, ys("    add $16, %rsp"));
        }
        ;
    } else {
        ;
    }
    return st;
}

/* Float arithmetic and comparison. Operands arrive in %rax as raw bits;
 * a long operand is widened with cvtsi2sd first (the only coercion). */
Yv *gen_float_bin(Yv *st, Yv *node, Yv *lt, Yv *rt) {
    Yv *op = yr_get(node, "op");
    st = gen(st, yr_get(node, "l"));
    if (ys_eq_lit(yr_get(lt, "k"), "tfloat")) {
        ;
    } else {
        st = emit(st, ys("    cvtsi2sd %rax, %xmm0"));
        st = emit(st, ys("    movq %xmm0, %rax"));
        ;
    }
    st = emit(st, ys("    push %rax"));
    st = gen(st, yr_get(node, "r"));
    if (ys_eq_lit(yr_get(rt, "k"), "tfloat")) {
        ;
    } else {
        st = emit(st, ys("    cvtsi2sd %rax, %xmm0"));
        st = emit(st, ys("    movq %xmm0, %rax"));
        ;
    }
    st = emit(st, ys("    movq %rax, %xmm1"));
    st = emit(st, ys("    pop %rax"));
    st = emit(st, ys("    movq %rax, %xmm0"));
    if (ys_eq_lit(op, "+")) {
        st = emit(st, ys("    addsd %xmm1, %xmm0"));
        return emit(st, ys("    movq %xmm0, %rax"));
    } else if (ys_eq_lit(op, "-")) {
        st = emit(st, ys("    subsd %xmm1, %xmm0"));
        return emit(st, ys("    movq %xmm0, %rax"));
    } else if (ys_eq_lit(op, "*")) {
        st = emit(st, ys("    mulsd %xmm1, %xmm0"));
        return emit(st, ys("    movq %xmm0, %rax"));
    } else if (ys_eq_lit(op, "/")) {
        st = emit(st, ys("    divsd %xmm1, %xmm0"));
        return emit(st, ys("    movq %xmm0, %rax"));
    } else {
        /* Comparisons: ucomisd sets CF/ZF, so the UNSIGNED conditions are
         * the right ones (a/ae/b/be), not the signed g/ge/l/le. */
        st = emit(st, ys("    ucomisd %xmm1, %xmm0"));
        if (ys_eq_lit(op, "<")) {
            st = emit(st, ys("    setb %al"));
            ;
        } else if (ys_eq_lit(op, "<=")) {
            st = emit(st, ys("    setbe %al"));
            ;
        } else if (ys_eq_lit(op, ">")) {
            st = emit(st, ys("    seta %al"));
            ;
        } else if (ys_eq_lit(op, ">=")) {
            st = emit(st, ys("    setae %al"));
            ;
        } else if (ys_eq_lit(op, "==")) {
            st = emit(st, ys("    sete %al"));
            ;
        } else {
            st = emit(st, ys("    setne %al"));
            ;
        }
        return emit(st, ys("    movzbq %al, %rax"));
    }
}

Yv *gen_str_cmp(Yv *st, Yv *node, Yv *op) {
    st = gen_push_args(st, yav(2, yr_get(node, "l"), yr_get(node, "r")));
    st = emit(st, ys("    call y_str_cmp"));
    st = emit(st, ys("    add $16, %rsp"));
    st = emit(st, ys("    cmp $0, %rax"));
    if (ys_eq_lit(op, "<")) {
        st = emit(st, ys("    setl %al"));
        ;
    } else if (ys_eq_lit(op, ">")) {
        st = emit(st, ys("    setg %al"));
        ;
    } else if (ys_eq_lit(op, "<=")) {
        st = emit(st, ys("    setle %al"));
        ;
    } else {
        st = emit(st, ys("    setge %al"));
        ;
    }
    return emit(st, ys("    movzbq %al, %rax"));
}

Yv *gen_bin_rest(Yv *st, Yv *node) {
    Yv *op = yr_get(node, "op");
    Yv *lt = infer(st, yr_get(node, "l"));
    Yv *rt = infer(st, yr_get(node, "r"));
    if (ys_eq_lit(op, "+") &&
        (ys_eq_lit(yr_get(lt, "k"), "tstr") ||
         ys_eq_lit(yr_get(rt, "k"), "tstr"))) {
        return gen_cat(st, node, lt, rt);
    } else if (ys_eq_lit(op, "+") &&
               (ys_eq_lit(yr_get(lt, "k"), "tarr") ||
                ys_eq_lit(yr_get(rt, "k"), "tarr") ||
                ys_eq_lit(yr_get(lt, "k"), "tarrfix") ||
                ys_eq_lit(yr_get(rt, "k"), "tarrfix"))) {
        /* array `+` is the copy-concat form (gen_cat splits off the array
         * case first), not numeric add on the header pointers. */
        return gen_cat(st, node, lt, rt);
    } else if (ys_eq_lit(op, "::")) {
        return gen_cons(st, node);
    } else if (ys_eq_lit(yr_get(lt, "k"), "tfloat") ||
               ys_eq_lit(yr_get(rt, "k"), "tfloat")) {
        return gen_float_bin(st, node, lt, rt);
    } else if ((ys_eq_lit(op, "==") || ys_eq_lit(op, "!=")) &&
               (ys_eq_lit(yr_get(lt, "k"), "tstr") ||
                ys_eq_lit(yr_get(rt, "k"), "tstr"))) {
        st = gen_push_args(st, yav(2, yr_get(node, "l"), yr_get(node, "r")));
        st = emit(st, ys("    call y_str_eq"));
        st = emit(st, ys("    add $16, %rsp"));
        if (ys_eq_lit(op, "!=")) {
            return emit(st, ys("    xor $1, %rax"));
        } else {
            return st;
        }
    } else if ((ys_eq_lit(op, "<") || ys_eq_lit(op, ">") ||
                ys_eq_lit(op, "<=") || ys_eq_lit(op, ">=")) &&
               ys_eq_lit(yr_get(lt, "k"), "tstr")) {
        /* Lexicographic ordering: y_str_cmp returns the SIGN, so the normal
         * signed setcc forms work on its result against 0. */
        return gen_str_cmp(st, node, op);
    } else if ((ys_eq_lit(op, "==") || ys_eq_lit(op, "!=")) &&
               (ys_eq_lit(yr_get(lt, "k"), "tarr") ||
                ys_eq_lit(yr_get(rt, "k"), "tarr"))) {
        /* Arrays compare STRUCTURALLY (length then elements), matching
         * yv.c's yv_eq for Y_ARR — `arr == []` is an emptiness test, not a
         * pointer comparison. String elements compare by value. */
        Yv *elt = yr(1, "k", ys("tunk"));
        if (ys_eq_lit(yr_get(lt, "k"), "tarr")) {
            elt = yr_get(lt, "of");
            ;
        } else {
            ;
        }
        if (ys_eq_lit(yr_get(elt, "k"), "tunk")) {
            if (ys_eq_lit(yr_get(rt, "k"), "tarr")) {
                elt = yr_get(rt, "of");
                ;
            } else {
                ;
            }
            ;
        } else {
            ;
        }
        st = gen_push_args(st, yav(2, yr_get(node, "l"), yr_get(node, "r")));
        if (ys_eq_lit(yr_get(elt, "k"), "tstr")) {
            st = emit(st, ys("    call y_arr_eq_str"));
            st = emit(st, ys("    add $16, %rsp"));
            ;
        } else {
            st = emit(st, ys_cat(ys_cat(ys("    mov $"),
                                        ys_long(elem_bytes(elt))),
                                 ys(", %rax")));
            st = emit(st, ys("    push %rax"));
            st = emit(st, ys("    call y_arr_eq"));
            st = emit(st, ys("    add $24, %rsp"));
            ;
        }
        if (ys_eq_lit(op, "!=")) {
            return emit(st, ys("    xor $1, %rax"));
        } else {
            return st;
        }
    } else {
        st = gen(st, yr_get(node, "l"));
        st = emit(st, ys("    push %rax"));
        st = gen(st, yr_get(node, "r"));
        st = emit(st, ys("    mov %rax, %rcx"));
        st = emit(st, ys("    pop %rax"));
        if (ys_eq_lit(op, "+")) {
            return emit(st, ys("    add %rcx, %rax"));
        } else if (ys_eq_lit(op, "-")) {
            return emit(st, ys("    sub %rcx, %rax"));
        } else if (ys_eq_lit(op, "*")) {
            return emit(st, ys("    imul %rcx, %rax"));
        } else if (ys_eq_lit(op, "/")) {
            /* idiv raises #DE on LONG_MIN / -1 (the quotient does not fit),
             * so divisor -1 is handled as a negation instead: neg of
             * LONG_MIN wraps back to LONG_MIN (the language's rule for the
             * whole long range, NATIVE.md), and every other value negates
             * exactly. */
            st = emit(st, ys("    test %rcx, %rcx"));
            st = emit(st, ys("    jz y_div_zero"));
            Yv *d1 = next_loc(st);
            st = yr_get(d1, "st");
            Yv *d2 = next_loc(st);
            st = yr_get(d2, "st");
            st = emit(st, ys("    cmp $-1, %rcx"));
            st = emit(st, ys_cat(ys("    jne "), yr_get(d1, "lbl")));
            st = emit(st, ys("    neg %rax"));
            st = emit(st, ys_cat(ys("    jmp "), yr_get(d2, "lbl")));
            st = emit(st, ys_cat(yr_get(d1, "lbl"), ys(":")));
            st = emit(st, ys("    cqo"));
            st = emit(st, ys("    idiv %rcx"));
            return emit(st, ys_cat(yr_get(d2, "lbl"), ys(":")));
        } else if (ys_eq_lit(op, "%")) {
            /* Same #DE: x % -1 is 0 for every x (see the `/` note). */
            st = emit(st, ys("    test %rcx, %rcx"));
            st = emit(st, ys("    jz y_div_zero"));
            Yv *m1 = next_loc(st);
            st = yr_get(m1, "st");
            Yv *m2 = next_loc(st);
            st = yr_get(m2, "st");
            st = emit(st, ys("    cmp $-1, %rcx"));
            st = emit(st, ys_cat(ys("    jne "), yr_get(m1, "lbl")));
            st = emit(st, ys("    xor %eax, %eax"));
            st = emit(st, ys_cat(ys("    jmp "), yr_get(m2, "lbl")));
            st = emit(st, ys_cat(yr_get(m1, "lbl"), ys(":")));
            st = emit(st, ys("    cqo"));
            st = emit(st, ys("    idiv %rcx"));
            st = emit(st, ys("    mov %rdx, %rax"));
            return emit(st, ys_cat(yr_get(m2, "lbl"), ys(":")));
        } else if (ys_eq_lit(op, "<")) {
            st = emit(st, ys("    cmp %rcx, %rax"));
            st = emit(st, ys("    setl %al"));
            return emit(st, ys("    movzbq %al, %rax"));
        } else if (ys_eq_lit(op, ">")) {
            st = emit(st, ys("    cmp %rcx, %rax"));
            st = emit(st, ys("    setg %al"));
            return emit(st, ys("    movzbq %al, %rax"));
        } else if (ys_eq_lit(op, "<=")) {
            st = emit(st, ys("    cmp %rcx, %rax"));
            st = emit(st, ys("    setle %al"));
            return emit(st, ys("    movzbq %al, %rax"));
        } else if (ys_eq_lit(op, ">=")) {
            st = emit(st, ys("    cmp %rcx, %rax"));
            st = emit(st, ys("    setge %al"));
            return emit(st, ys("    movzbq %al, %rax"));
        } else if (ys_eq_lit(op, "==")) {
            st = emit(st, ys("    cmp %rcx, %rax"));
            st = emit(st, ys("    sete %al"));
            return emit(st, ys("    movzbq %al, %rax"));
        } else if (ys_eq_lit(op, "!=")) {
            st = emit(st, ys("    cmp %rcx, %rax"));
            st = emit(st, ys("    setne %al"));
            return emit(st, ys("    movzbq %al, %rax"));
        }
        /* No &&/|| arms here: gen_bin routes those to gen_logic (lazy
           jumps) BEFORE calling this, so an eager and/or would be dead
           code. */
        return st;
    }
    return st;
}

/* ── calls ──────────────────────────────────────────────────────────────
 * Linux syscall arg regs (in order): rdi, rsi, rdx, r10, r8, r9. */

Yv *syscall_reg(long i) {
    if (i == 0) {
        return ys("%rdi");
    } else if (i == 1) {
        return ys("%rsi");
    } else if (i == 2) {
        return ys("%rdx");
    } else if (i == 3) {
        return ys("%r10");
    } else if (i == 4) {
        return ys("%r8");
    } else {
        return ys("%r9");
    }
}

Yv *gen_push_args(Yv *st, Yv *args) {
    long i = 0;
    while (i < yv_len(args)) {
        st = gen(st, ya_get(args, i));
        st = emit(st, ys("    push %rax"));
        i = i + 1;
    }
    return st;
}

/* Call a one-argument runtime helper. The argument is in %rax and goes on
 * the stack — the Y convention every helper written in Y (std/rt.y) and
 * every asm helper shares; the caller cleans up. (Runtime helpers used to
 * take it in %rdi, which only hand-written asm could honour.) */
Yv *gen_helper1(Yv *st, Yv *label) {
    st = emit(st, ys("    push %rax"));
    st = emit(st, ys_cat(ys("    call "), label));
    return emit(st, ys("    add $8, %rsp"));
}

Yv *gen_call(Yv *st, Yv *node) {
    Yv *callee = yr_get(node, "callee");
    if (!ys_eq_lit(yr_get(callee, "k"), "id")) {
        /* Calling the result of an expression (e.g. `fs[0](x)`): it is a
         * closure value, so go through its code pointer. */
        return gen_indirect(st, node, callee);
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
        } else if (ys_eq_lit(name, "some")) {
            return gen_some(st, node);
        } else if (ys_eq_lit(name, "is_some")) {
            return gen_is_some(st, node);
        } else if (ys_eq_lit(name, "unwrap")) {
            return gen_unwrap(st, node);
        } else if (ys_eq_lit(name, "substr")) {
            return gen_substr(st, node);
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
        } else if (ys_eq_lit(name, "typeof")) {
            return gen_typeof(st, node);
        } else if (ys_eq_lit(name, "index_of")) {
            return gen_index_of(st, node, 0);
        } else if (ys_eq_lit(name, "last_index_of")) {
            return gen_index_of(st, node, 1);
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
        } else if (ys_eq_lit(name, "sleep")) {
            return gen_sleep(st, node);
        } else if (ys_eq_lit(name, "heap_used")) {
            return gen_heap_used(st, node);
        } else if (ys_eq_lit(name, "exit")) {
            return gen_exit(st, node);
        } else if (ys_eq_lit(name, "argv")) {
            return gen_argv(st, node);
        } else if (ys_eq_lit(name, "read_file")) {
            return gen_read_file(st, node);
        } else if (ys_eq_lit(name, "bytes")) {
            st = gen_push_args(st, yr_get(node, "args"));
            st = emit(st, ys("    call y_str_to_bytes"));
            return emit(st, ys("    add $8, %rsp"));
        } else if (ys_eq_lit(name, "from_bytes")) {
            st = gen_push_args(st, yr_get(node, "args"));
            st = emit(st, ys("    call y_bytes_to_str"));
            return emit(st, ys("    add $8, %rsp"));
        } else if (ys_eq_lit(name, "ptr_addr")) {
            /* A pointer IS its numeric value at run time: nothing to emit
             * beyond evaluating the operand. This exists only so the type
             * system lets the value cross into long territory. */
            Yv *paargs = yr_get(node, "args");
            return gen(st, ya_get(paargs, 0));
        } else if (ys_eq_lit(name, "write_file")) {
            return gen_write_file(st, node);
        } else if (ys_eq_lit(name, "write_bytes")) {
            return gen_write_bytes(st, node);
        } else {
            return gen_direct(st, node, name);
        }
    }
}

Yv *gen_print(Yv *st, Yv *node) {
    Yv *args = yr_get(node, "args");
    Yv *pa0 = ya_get(args, 0);
    Yv *t = infer(st, pa0);
    if (ys_eq_lit(yr_get(t, "k"), "trec")) {
        /* Records are formatted field by field from their static shape. */
        st = gen_rec_str(st, pa0, t);
        st = gen_helper1(st, ys("y_print_hstr"));
        return emit(st, ys("    xor %eax, %eax"));
    } else if (ys_eq_lit(yr_get(t, "k"), "tfunc")) {
        /* A function value has no printable contents; show its signature
         * (`<function (params)->(ret)>`, types.y tdisp_fnval). */
        st = gen(st, pa0);
        st = gen_str_const(
            st, ys_cat(ys_cat(ys("<function "), tdisp_fnval(t)), ys(">")));
        st = gen_helper1(st, ys("y_print_hstr"));
        return emit(st, ys("    xor %eax, %eax"));
    } else if (ys_eq_lit(yr_get(t, "k"), "tarr") ||
               ys_eq_lit(yr_get(t, "k"), "tarrfix")) {
        /* Arrays print like tostring: "[e0, e1, ...]". */
        st = gen(st, pa0);
        if (ys_eq_lit(yr_get(yr_get(t, "of"), "k"), "tbyte")) {
            /* [byte] prints Python-style: b'...' with escapes */
            st = gen_helper1(st, ys("y_bytes_repr"));
            ;
        } else {
            st = gen_arr_tostr_rax(st, yr_get(t, "of"));
            ;
        }
        st = gen_helper1(st, ys("y_print_hstr"));
        return emit(st, ys("    xor %eax, %eax"));
    } else if (ys_eq_lit(yr_get(t, "k"), "topt")) {
        st = gen(st, pa0);
        st = gen_opt_str_rax(st, t);
        st = gen_helper1(st, ys("y_print_hstr"));
        return emit(st, ys("    xor %eax, %eax"));
    } else if (ys_eq_lit(yr_get(t, "k"), "tmap")) {
        /* Maps format entry by entry: {"k": v, ...} (quoted keys). */
        st = gen_map_repr(st, pa0, t);
        st = gen_helper1(st, ys("y_print_hstr"));
        return emit(st, ys("    xor %eax, %eax"));
    } else if (ys_eq_lit(yr_get(t, "k"), "tunion")) {
        st = gen(st, pa0);
        st = gen_union_str_rax(st, t);
        st = gen_helper1(st, ys("y_print_hstr"));
        return emit(st, ys("    xor %eax, %eax"));
    } else {
        return gen_print_scalar(st, pa0, t);
    }
}

Yv *gen_print_scalar(Yv *st, Yv *arg, Yv *t) {
    st = gen(st, arg);
    if (ys_eq_lit(yr_get(t, "k"), "tbool")) {
        st = gen_helper1(st, ys("y_print_bool"));
        return emit(st, ys("    xor %eax, %eax"));
    } else if (ys_eq_lit(yr_get(t, "k"), "tstr")) {
        st = gen_helper1(st, ys("y_print_hstr"));
        return emit(st, ys("    xor %eax, %eax"));
    } else if (ys_eq_lit(yr_get(t, "k"), "tfloat")) {
        st = gen_helper1(st, ys("y_print_float"));
        return emit(st, ys("    xor %eax, %eax"));
    } else {
        st = gen_helper1(st, ys("y_print_long"));
        return emit(st, ys("    xor %eax, %eax"));
    }
}

/* `typeof(e)` is resolved statically: the checker has already pinned e's
 * type, so this is a plain string constant. */
Yv *gen_typeof(Yv *st, Yv *node) {
    Yv *targs = yr_get(node, "args");
    return gen_str_const(st, tdisp(infer(st, ya_get(targs, 0))));
}

/* ── record formatting ──────────────────────────────────────────────────
 * `{a: 1, b: "x"}` — the shape is static, so the walk is unrolled at
 * compile time. Stack layout while building: [record][accumulator], the
 * record pushed first (8(%rsp)), the accumulator on top (0(%rsp)). */

/* Option value in %rax (0 = none, else the box address): leave "none" or
 * the payload's string form in %rax. Options are 0-or-box (NATIVE.md). */
Yv *gen_opt_str_rax(Yv *st, Yv *t) {
    Yv *rdone = next_loc(st);
    st = yr_get(rdone, "st");
    Yv *rnul = next_loc(st);
    st = yr_get(rnul, "st");
    st = emit(st, ys("    test %rax, %rax"));
    st = emit(st, ys_cat(ys("    jz "), yr_get(rnul, "lbl")));
    st = emit(st, ys("    mov (%rax), %rax"));
    st = gen_val_tostr_rax(st, yr_get(t, "of"));
    st = emit(st, ys_cat(ys("    jmp "), yr_get(rdone, "lbl")));
    st = emit(st, ys_cat(yr_get(rnul, "lbl"), ys(":")));
    st = gen_str_const(st, ys("none"));
    return emit(st, ys_cat(yr_get(rdone, "lbl"), ys(":")));
}

Yv *gen_rec_str(Yv *st, Yv *arg, Yv *t) {
    st = gen(st, arg);
    return gen_rec_str_rax(st, t);
}

/* The record's address sits in %rax; leave "{a: 1, b: ...}" in %rax.
 * Values are formatted from the static shape (the walk is unrolled at
 * compile time). Stack layout while building: [record][accumulator], the
 * record pushed first (8(%rsp)), the accumulator on top (0(%rsp)). */
Yv *gen_rec_str_rax(Yv *st, Yv *t) {
    st = emit(st, ys("    push %rax"));
    st = gen_str_const(st, ys("{"));
    st = emit(st, ys("    push %rax"));
    Yv *fs = yr_get(t, "fields");
    long i = 0;
    while (i < yv_len(fs)) {
        Yv *f = ya_get(fs, i);
        Yv *sep = ys("");
        if (i > 0) {
            sep = ys(", ");
            ;
        } else {
            ;
        }
        st = gen_acc_cat_const(
            st, ys_cat(ys_cat(sep, yr_get(f, "name")), ys(": ")));
        st = gen_rec_field_str(st, i, yr_get(f, "typ"));
        i = i + 1;
    }
    st = gen_acc_cat_const(st, ys("}"));
    st = emit(st, ys("    mov (%rsp), %rax"));
    return emit(st, ys("    add $16, %rsp"));
}

/* `x :: a` -- cons: a NEW array with x prepended as exactly ONE element
 * (types.y typeof_cons keeps even array-typed elements whole). */
Yv *gen_cons(Yv *st, Yv *node) {
    Yv *ln = yr_get(node, "line");
    Yv *cl = yr_get(node, "col");
    long cesz = arr_elem_bytes(infer(st, yr_get(node, "r")));
    Yv *one = yr(4, "k", ys("array"), "elems", args1(yr_get(node, "l")), "line",
                 ln, "col", cl);
    st = gen_array_esz(st, one, cesz);
    st = emit(st, ys("    push %rax"));
    st = gen(st, yr_get(node, "r"));
    st = emit(st, ys("    push %rax"));
    st = emit(st, ys_cat(ys("    mov $"), ys_cat(ys_long(cesz), ys(", %rax"))));
    st = emit(st, ys("    push %rax"));
    st = emit(st, ys("    call y_arr_cat"));
    return emit(st, ys("    add $24, %rsp"));
}

/* Array `+`: always a NEW array (arr + arr, arr + elem, elem + arr).
 * y_arr_cat copies both sides; the one-element side is built with the
 * ordinary array literal emitter, so `arr + v` evaluates v exactly once. */
Yv *gen_cat_arr(Yv *st, Yv *node, Yv *lt, Yv *rt) {
    Yv *ln = yr_get(node, "line");
    Yv *cl = yr_get(node, "col");
    Yv *lk = yr_get(lt, "k");
    Yv *rk = yr_get(rt, "k");
    long esz = 8;
    int larr = 1;
    if (ys_eq_lit(lk, "tarr")) {
        esz = arr_elem_bytes(lt);
        ;
    } else if (ys_eq_lit(lk, "tarrfix")) {
        esz = arr_elem_bytes(lt);
        ;
    } else {
        larr = 0;
        esz = arr_elem_bytes(rt);
        ;
    }
    Yv *one = yr(4, "k", ys("array"), "elems", args1(yr_get(node, "r")), "line",
                 ln, "col", cl);
    if (larr) {
        ;
    } else {
        one = yr(4, "k", ys("array"), "elems", args1(yr_get(node, "l")), "line",
                 ln, "col", cl);
        ;
    }
    if (larr) {
        st = gen(st, yr_get(node, "l"));
        st = emit(st, ys("    push %rax"));
        if (ys_eq_lit(rk, "tarr")) {
            st = gen(st, yr_get(node, "r"));
            ;
        } else {
            if (ys_eq_lit(rk, "tarrfix")) {
                st = gen(st, yr_get(node, "r"));
                ;
            } else {
                st = gen_array_esz(st, one, esz);
                ;
            }
            ;
        }
        ;
    } else {
        st = gen_array_esz(st, one, esz);
        st = emit(st, ys("    push %rax"));
        st = gen(st, yr_get(node, "r"));
        ;
    }
    st = emit(st, ys("    push %rax"));
    st = emit(st, ys_cat(ys_cat(ys("    mov $"), ys_long(esz)), ys(", %rax")));
    st = emit(st, ys("    push %rax"));
    st = emit(st, ys("    call y_arr_cat"));
    return emit(st, ys("    add $24, %rsp"));
}

/* acc = acc + <constant>, with the layout above still in place. */
Yv *gen_acc_cat_const(Yv *st, Yv *s) {
    st = emit(st, ys("    mov (%rsp), %rax"));
    st = emit(st, ys("    push %rax"));
    st = gen_str_const(st, s);
    st = emit(st, ys("    push %rax"));
    st = emit(st, ys("    call y_str_cat"));
    st = emit(st, ys("    add $16, %rsp"));
    return emit(st, ys("    mov %rax, (%rsp)"));
}

/* acc = acc + <field idx, rendered by its static type>. */
Yv *gen_rec_field_str(Yv *st, long idx, Yv *ft) {
    Yv *fk = yr_get(ft, "k");
    if (ys_eq_lit(fk, "tstr")) {
        st = emit(st, ys("    mov 8(%rsp), %rcx"));
        st = emit(st, ys_cat(ys_cat(ys("    mov "), ys_long(8 * idx)),
                             ys("(%rcx), %rdx")));
    } else if (ys_eq_lit(fk, "tlong")) {
        st = emit(st, ys("    mov 8(%rsp), %rcx"));
        st = emit(st, ys_cat(ys_cat(ys("    mov "), ys_long(8 * idx)),
                             ys("(%rcx), %rax")));
        st = emit(st, ys("    push %rax"));
        st = emit(st, ys("    call y_long_tostr"));
        st = emit(st, ys("    add $8, %rsp"));
        st = emit(st, ys("    mov %rax, %rdx"));
    } else if (ys_eq_lit(fk, "tbool")) {
        st = emit(st, ys("    mov 8(%rsp), %rcx"));
        st = emit(st, ys_cat(ys_cat(ys("    mov "), ys_long(8 * idx)),
                             ys("(%rcx), %rax")));
        st = emit(st, ys("    push %rax"));
        st = emit(st, ys("    call y_bool_tostr"));
        st = emit(st, ys("    add $8, %rsp"));
        st = emit(st, ys("    mov %rax, %rdx"));
    } else if (ys_eq_lit(fk, "tfloat")) {
        st = emit(st, ys("    mov 8(%rsp), %rcx"));
        st = emit(st, ys_cat(ys_cat(ys("    mov "), ys_long(8 * idx)),
                             ys("(%rcx), %rax")));
        st = emit(st, ys("    push %rax"));
        st = emit(st, ys("    call y_float_tostr"));
        st = emit(st, ys("    add $8, %rsp"));
        st = emit(st, ys("    mov %rax, %rdx"));
    } else if (ys_eq_lit(fk, "tfunc")) {
        st = gen_str_const(
            st, ys_cat(ys_cat(ys("<function "), tdisp_fnval(ft)), ys(">")));
        st = emit(st, ys("    mov %rax, %rdx"));
    } else {
        /* Arrays, options, maps and records nested in a RECORD: printed as
         * their type name — only gen_val_tostr_rax (the value formatter)
         * walks them recursively. */
        st = gen_str_const(st, ys_cat(ys_cat(ys("<"), tdisp(ft)), ys(">")));
        st = emit(st, ys("    mov %rax, %rdx"));
    }
    st = emit(st, ys("    mov (%rsp), %rax"));
    st = emit(st, ys("    push %rax"));
    st = emit(st, ys("    push %rdx"));
    st = emit(st, ys("    call y_str_cat"));
    st = emit(st, ys("    add $16, %rsp"));
    return emit(st, ys("    mov %rax, (%rsp)"));
}

Yv *gen_syscall(Yv *st, Yv *node) {
    Yv *args = yr_get(node, "args");
    /* args[0] is the number; rest are a1..a6. Push all, pop into regs. */
    st = gen_push_args(st, args);
    long n = yv_len(args) - 1;
    long i = n;
    while (i >= 1) {
        st = emit(st, ys_cat(ys("    pop "), syscall_reg(i - 1)));
        /* a str flows in as its header; the kernel wants the data bytes. */
        Yv *at = infer(st, ya_get(args, i));
        if (ys_eq_lit(yr_get(at, "k"), "tstr")) {
            st = emit(st, ys_cat(ys("    add $8, "), syscall_reg(i - 1)));
            ;
        } else {
            ;
        }
        i = i - 1;
    }
    st = emit(st, ys("    pop %rax"));
    return emit(st, ys("    syscall"));
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
        } else {
            ;
        }
        i = i + 1;
    }
    return res;
}

Yv *gen_direct(Yv *st, Yv *node, Yv *name) {
    Yv *label = ys("");
    int indirect = 0;
    if (ys_eq_lit(name, "self")) {
        label = yr_get(st, "self_label");
    } else {
        Yv *e = env_find(st, name);
        if (ys_eq_lit(yr_get(e, "kind"), "none")) {
            label = ys_cat(ys("y_missing_"), name);
        } else if (ys_eq_lit(yr_get(e, "kind"), "func")) {
            label = yr_get(e, "label");
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
        if (ys_eq(label, yr_get(st, "self_label"))) {
            soff = capture_off(st);
            ;
        } else {
            ;
        }
        if (soff >= 0) {
            st = emit(st, ys_cat(ys_cat(ys("    mov "), ys_long(soff)),
                                 ys("(%rbp), %rax")));
            st = emit(st, ys("    push %rax"));
            ;
        } else {
            ;
        }
        st = gen_push_args(st, yr_get(node, "args"));
        st = emit(st, ys_cat(ys("    call "), label));
        long nbytes = yv_len(yr_get(node, "args")) * 8;
        if (soff >= 0) {
            nbytes = nbytes + 8;
            ;
        } else {
            ;
        }
        if (nbytes == 0) {
            return st;
        } else {
            return emit(st, ys_cat(ys_cat(ys("    add $"), ys_long(nbytes)),
                                   ys(", %rsp")));
        }
    }
}

/* ── control flow ─────────────────────────────────────────────────────── */

Yv *gen_if(Yv *st, Yv *node) {
    Yv *r1 = next_loc(st);
    st = yr_get(r1, "st");
    Yv *r2 = next_loc(st);
    st = yr_get(r2, "st");
    st = gen(st, yr_get(node, "cond"));
    st = emit(st, ys("    test %rax, %rax"));
    st = emit(st, ys_cat(ys("    jz "), yr_get(r1, "lbl")));
    st = gen(st, yr_get(node, "then"));
    if (yv_b(yr_get(node, "has_else"))) {
        st = emit(st, ys_cat(ys("    jmp "), yr_get(r2, "lbl")));
        st = emit(st, ys_cat(yr_get(r1, "lbl"), ys(":")));
        st = gen(st, yr_get(node, "els"));
        return emit(st, ys_cat(yr_get(r2, "lbl"), ys(":")));
    } else {
        return emit(st, ys_cat(yr_get(r1, "lbl"), ys(":")));
    }
}

Yv *gen_while(Yv *st, Yv *node) {
    Yv *r1 = next_loc(st);
    st = yr_get(r1, "st");
    Yv *r2 = next_loc(st);
    st = yr_get(r2, "st");
    st = emit(st, ys_cat(yr_get(r1, "lbl"), ys(":")));
    st = gen(st, yr_get(node, "cond"));
    st = emit(st, ys("    test %rax, %rax"));
    st = emit(st, ys_cat(ys("    jz "), yr_get(r2, "lbl")));
    st = gen(st, yr_get(node, "body"));
    st = emit(st, ys_cat(ys("    jmp "), yr_get(r1, "lbl")));
    st = emit(st, ys_cat(yr_get(r2, "lbl"), ys(":")));
    return emit(st, ys("    xor %eax, %eax"));
}

/* ── counted loops ──────────────────────────────────────────────────────
 * All three lower to the same shape as `while`: a head label, a test, the
 * body, a step, and a jump back. The loop variable is a normal local slot,
 * so nothing new is needed at runtime. */

Yv *gen_for(Yv *st, Yv *node) {
    /* for (init; cond; step) body */
    st = gen(st, yr_get(node, "init"));
    Yv *r1 = next_loc(st);
    st = yr_get(r1, "st");
    Yv *r2 = next_loc(st);
    st = yr_get(r2, "st");
    st = emit(st, ys_cat(yr_get(r1, "lbl"), ys(":")));
    st = gen(st, yr_get(node, "cond"));
    st = emit(st, ys("    test %rax, %rax"));
    st = emit(st, ys_cat(ys("    jz "), yr_get(r2, "lbl")));
    st = gen(st, yr_get(node, "body"));
    st = gen(st, yr_get(node, "step"));
    st = emit(st, ys_cat(ys("    jmp "), yr_get(r1, "lbl")));
    st = emit(st, ys_cat(yr_get(r2, "lbl"), ys(":")));
    return emit(st, ys("    xor %eax, %eax"));
}

Yv *gen_forrange(Yv *st, Yv *node) {
    /* for (x in lo..hi) body — half-open: lo inclusive, hi exclusive.
     * Slot layout: [var][limit]; the limit is evaluated once. */
    long voff = (yv_l(yr_get(st, "slots")) + 1) * -8;
    long loff = (yv_l(yr_get(st, "slots")) + 2) * -8;
    st = yr(11, "out", yr_get(st, "out"), "rodata", yr_get(st, "rodata"), "uid",
            yr_get(st, "uid"), "fuid", yr_get(st, "fuid"), "loc",
            yr_get(st, "loc"), "env", yr_get(st, "env"), "slots",
            yv_long(yv_l(yr_get(st, "slots")) + 2), "self_label",
            yr_get(st, "self_label"), "end_label", yr_get(st, "end_label"),
            "fns", yr_get(st, "fns"), "bodies", yr_get(st, "bodies"));
    st = gen(st, yr_get(node, "hi"));
    st = emit(st, ys_cat(ys_cat(ys("    mov %rax, "), ys_long(loff)),
                         ys("(%rbp)")));
    st = gen(st, yr_get(node, "lo"));
    st = emit(st, ys_cat(ys_cat(ys("    mov %rax, "), ys_long(voff)),
                         ys("(%rbp)")));
    st = env_define(st, yr_get(node, "name"), ys("local"), voff, ys(""),
                    yr(1, "k", ys("tlong")));
    Yv *r1 = next_loc(st);
    st = yr_get(r1, "st");
    Yv *r2 = next_loc(st);
    st = yr_get(r2, "st");
    st = emit(st, ys_cat(yr_get(r1, "lbl"), ys(":")));
    st = emit(st, ys_cat(ys_cat(ys("    mov "), ys_long(voff)),
                         ys("(%rbp), %rax")));
    st = emit(st, ys_cat(ys_cat(ys("    mov "), ys_long(loff)),
                         ys("(%rbp), %rcx")));
    st = emit(st, ys("    cmp %rcx, %rax"));
    st = emit(st, ys_cat(ys("    jge "), yr_get(r2, "lbl")));
    /* a captured loop variable gets a fresh cell per iteration (the
     * counter itself stays in its raw slot) */
    st = box_bound(st, yr_get(node, "name"));
    st = gen(st, yr_get(node, "body"));
    st = emit(st, ys_cat(ys_cat(ys("    mov "), ys_long(voff)),
                         ys("(%rbp), %rax")));
    st = emit(st, ys("    inc %rax"));
    st = emit(st, ys_cat(ys_cat(ys("    mov %rax, "), ys_long(voff)),
                         ys("(%rbp)")));
    st = emit(st, ys_cat(ys("    jmp "), yr_get(r1, "lbl")));
    st = emit(st, ys_cat(yr_get(r2, "lbl"), ys(":")));
    return emit(st, ys("    xor %eax, %eax"));
}

Yv *gen_foreach(Yv *st, Yv *node) {
    /* foreach (x in arr) body. Slots: [x][arr][i]. The array is evaluated
     * once; `x` is refreshed from arr[i] at the top of every iteration. */
    long voff = (yv_l(yr_get(st, "slots")) + 1) * -8;
    long aoff = (yv_l(yr_get(st, "slots")) + 2) * -8;
    long ioff = (yv_l(yr_get(st, "slots")) + 3) * -8;
    st = yr(11, "out", yr_get(st, "out"), "rodata", yr_get(st, "rodata"), "uid",
            yr_get(st, "uid"), "fuid", yr_get(st, "fuid"), "loc",
            yr_get(st, "loc"), "env", yr_get(st, "env"), "slots",
            yv_long(yv_l(yr_get(st, "slots")) + 3), "self_label",
            yr_get(st, "self_label"), "end_label", yr_get(st, "end_label"),
            "fns", yr_get(st, "fns"), "bodies", yr_get(st, "bodies"));
    Yv *elt = infer(st, yr_get(node, "iter"));
    Yv *eltyp = yr(1, "k", ys("tunk"));
    if (ys_eq_lit(yr_get(elt, "k"), "tarr")) {
        eltyp = yr_get(elt, "of");
        ;
    } else {
        ;
    }
    if (ys_eq_lit(yr_get(elt, "k"), "tarrfix")) {
        eltyp = yr_get(elt, "of");
        ;
    } else {
        ;
    }
    st = gen(st, yr_get(node, "iter"));
    st = emit(st, ys_cat(ys_cat(ys("    mov %rax, "), ys_long(aoff)),
                         ys("(%rbp)")));
    st = emit(st, ys("    xor %eax, %eax"));
    st = emit(st, ys_cat(ys_cat(ys("    mov %rax, "), ys_long(ioff)),
                         ys("(%rbp)")));
    st = env_define(st, yr_get(node, "name"), ys("local"), voff, ys(""),
                    eltyp);
    Yv *r1 = next_loc(st);
    st = yr_get(r1, "st");
    Yv *r2 = next_loc(st);
    st = yr_get(r2, "st");
    st = emit(st, ys_cat(yr_get(r1, "lbl"), ys(":")));
    /* i < len(arr) — the heap header keeps the length in slot 0. */
    st = emit(st, ys_cat(ys_cat(ys("    mov "), ys_long(aoff)),
                         ys("(%rbp), %rdx")));
    st = emit(st, ys("    mov (%rdx), %rcx"));
    st = emit(st, ys_cat(ys_cat(ys("    mov "), ys_long(ioff)),
                         ys("(%rbp), %rax")));
    st = emit(st, ys("    cmp %rcx, %rax"));
    st = emit(st, ys_cat(ys("    jge "), yr_get(r2, "lbl")));
    /* x = arr[i] */
    st = emit(st, elem_load(arr_elem_bytes(elt), ys("%rdx"), ys("%rax"),
                            ys("%rcx")));
    st = emit(st, ys_cat(ys_cat(ys("    mov %rcx, "), ys_long(voff)),
                         ys("(%rbp)")));
    st = box_bound(st, yr_get(node, "name"));
    st = gen(st, yr_get(node, "body"));
    st = emit(st, ys_cat(ys_cat(ys("    mov "), ys_long(ioff)),
                         ys("(%rbp), %rax")));
    st = emit(st, ys("    inc %rax"));
    st = emit(st, ys_cat(ys_cat(ys("    mov %rax, "), ys_long(ioff)),
                         ys("(%rbp)")));
    st = emit(st, ys_cat(ys("    jmp "), yr_get(r1, "lbl")));
    st = emit(st, ys_cat(yr_get(r2, "lbl"), ys(":")));
    return emit(st, ys("    xor %eax, %eax"));
}

/* ── tail calls ─────────────────────────────────────────────────────────
 * A self-call in tail position (the body's trailing value, a `return`'s
 * value, an if-arm's trailing value) recycles the frame instead of
 * growing the stack: every argument is evaluated into a fresh local
 * first (arguments may read parameters the copy below overwrites), the
 * locals are copied over the parameter slots, and the frame tears down
 * into a `jmp` back to the prologue. Tail recursion is then constant
 * space. Instrumented builds (--prof) keep plain calls so every entry
 * stays paired with its exit. */

int is_self_call(Yv *st, Yv *node) {
    /* `self(...)`, or a call naming the function being emitted (after
     * rename every def has a unique name, so the label decides). */
    if (!ys_eq_lit(yr_get(node, "k"), "call")) { return 0; }
    Yv *cal = yr_get(node, "callee");
    if (!ys_eq_lit(yr_get(cal, "k"), "id")) { return 0; }
    Yv *cv = yr_get(cal, "v");
    if (ys_eq_lit(cv, "self")) { return 1; }
    Yv *ee = env_find(st, cv);
    return ys_eq_lit(yr_get(ee, "kind"), "func") &&
           ys_eq(yr_get(ee, "label"), yr_get(st, "self_label"));
}

Yv *gen_tail_call(Yv *st, Yv *node) {
    Yv *targs = yr_get(node, "args");
    long n = yv_len(targs);
    /* evaluate each argument into a fresh local */
    Yv *offs = yav(0);
    long i = 0;
    while (i < n) {
        st = gen(st, ya_get(targs, i));
        long off = (yv_l(yr_get(st, "slots")) + 1) * -8;
        st = emit(st, ys_cat(ys("    mov %rax, "), ys_cat(ys_long(off), ys("(%rbp)"))));
        offs = ya_push(offs, yv_long(off));
        st = yr(11, "out", yr_get(st, "out"), "rodata", yr_get(st, "rodata"),
                "uid", yr_get(st, "uid"), "fuid", yr_get(st, "fuid"),
                "loc", yr_get(st, "loc"), "env", yr_get(st, "env"),
                "slots", yv_long(yv_l(yr_get(st, "slots")) + 1),
                "self_label", yr_get(st, "self_label"),
                "end_label", yr_get(st, "end_label"),
                "fns", yr_get(st, "fns"), "bodies", yr_get(st, "bodies"));
        i = i + 1;
    }
    /* copy the locals over the parameter slots (param k: 16 + 8*(n-1-k)) */
    long j = 0;
    while (j < n) {
        long po = 16 + 8 * (n - 1 - j);
        st = emit(st, ys_cat(ys("    mov "), ys_cat(ys_long(yv_l(ya_get(offs, j))), ys("(%rbp), %rax"))));
        st = emit(st, ys_cat(ys("    mov %rax, "), ys_cat(ys_long(po), ys("(%rbp)"))));
        j = j + 1;
    }
    /* tear down this frame and re-enter the prologue; the return address
     * of the original call stays where it is, so the caller sees a normal
     * return. */
    st = emit(st, ys("    mov %rbp, %rsp"));
    st = emit(st, ys("    pop %rbp"));
    return emit(st, ys_cat(ys("    jmp "), yr_get(st, "self_label")));
}

Yv *gen_tail(Yv *st, Yv *node) {
    Yv *k = yr_get(node, "k");
    if (ys_eq_lit(k, "ret")) {
        Yv *e = yr_get(node, "e");
        if (is_self_call(st, e)) {
            return gen_tail_call(st, e);
        }
        st = gen(st, e);
        return emit(st, ys_cat(ys("    jmp "), yr_get(st, "end_label")));
    } else if (ys_eq_lit(k, "call")) {
        if (is_self_call(st, node)) { return gen_tail_call(st, node); }
        return gen(st, node);
    } else if (ys_eq_lit(k, "block")) {
        Yv *tl = yr_get(node, "stmts");
        long m = yv_len(tl);
        /* a trailing `;` (void) leaves the statement before it in tail
         * position: the block's value is void either way */
        if (m > 1 && is_void_node(ya_get(tl, m - 1))) {
            m = m - 1;
        }
        long ti = 0;
        while (ti < m - 1) {
            st = gen(st, ya_get(tl, ti));
            ti = ti + 1;
        }
        if (m > 0) {
            Yv *lastn = ya_get(tl, m - 1);
            st = gen_tail(st, lastn);
            ;
        } else {
            ;
        }
        return st;
    } else if (ys_eq_lit(k, "if")) {
        st = gen(st, yr_get(node, "cond"));
        st = emit(st, ys("    test %rax, %rax"));
        Yv *rl1 = next_loc(st);
        st = yr_get(rl1, "st");
        Yv *lelse = yr_get(rl1, "lbl");
        Yv *rl2 = next_loc(st);
        st = yr_get(rl2, "st");
        Yv *lend = yr_get(rl2, "lbl");
        st = emit(st, ys_cat(ys("    jz "), lelse));
        st = gen_tail(st, yr_get(node, "then"));
        if (yv_b(yr_get(node, "has_else"))) {
            st = emit(st, ys_cat(ys("    jmp "), lend));
            st = emit(st, ys_cat(lelse, ys(":")));
            st = gen_tail(st, yr_get(node, "els"));
            return emit(st, ys_cat(lend, ys(":")));
        }
        return emit(st, ys_cat(lelse, ys(":")));
    }
    return gen(st, node);
}

Yv *gen_block(Yv *st, Yv *node) {
    /* No scope push: names are unique post-rename, blocks share the
     * frame. */
    Yv *stmts = yr_get(node, "stmts");
    if (yv_len(stmts) == 0) {
        return emit(st, ys("    xor %eax, %eax"));
    } else {
        /* A trailing `;` (void) computes nothing: nothing to emit. */
        long m = yv_len(stmts);
        if (m > 1 && is_void_node(ya_get(stmts, m - 1))) {
            m = m - 1;
        }
        long i = 0;
        while (i < m) {
            st = gen(st, ya_get(stmts, i));
            i = i + 1;
        }
        return st;
    }
}

int is_void_node(Yv *n) {
    return ys_eq_lit(yr_get(n, "k"), "void");
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
        } else {
            ;
        }
        i = i + 1;
    }
    return out;
}

/* Record literal { k: v, ... }: heap-allocate a block for the values + the
 * shape table, then store each value. The VALUE is the record address
 * (8 bytes, first-class: locals, params, returns all just copy it). Field k
 * lives at record+8k; the table pointer sits at record-8, which is what
 * y_dot_lookup reads (`mov -8(%rbx), %r14`).
 * (y_alloc(0) is fine — bump allocators return a valid, if empty, block;
 * empty maps are rejected by the checker anyway.) */
Yv *gen_reclit(Yv *st, Yv *node) {
    Yv *mvals = yr_get(node, "vals");
    Yv *mkeys = yr_get(node, "keys");
    long nent = yv_len(mvals);
    /* Static merge for `...` spread entries (the types.y field_merge
     * rule): first appearance keeps the position, a later entry wins the
     * value. The value loop below stores into merged slots in entry
     * order, so a later store simply overwrites -- no dynamic shape. */
    Yv *names = yav(0);
    long ni = 0;
    while (ni < nent) {
        Yv *nk = ya_get(mkeys, ni);
        if (ys_eq_lit(nk, "...")) {
            Yv *srec = infer(st, ya_get(mvals, ni));
            if (ys_eq_lit(yr_get(srec, "k"), "trec")) {
                Yv *sfs = yr_get(srec, "fields");
                long si = 0;
                while (si < yv_len(sfs)) {
                    Yv *sf = ya_get(sfs, si);
                    if (mfield_idx(names, yr_get(sf, "name")) < 0) {
                        names = ya_push(names, yr_get(sf, "name"));
                        ;
                    } else {
                        ;
                    }
                    si = si + 1;
                }
                ;
            } else {
                ;
            }
            ;
        } else {
            if (mfield_idx(names, nk) < 0) {
                names = ya_push(names, nk);
                ;
            } else {
                ;
            }
            ;
        }
        ni = ni + 1;
    }
    long n = yv_len(names);
    /* Shape tag for dynamic field reads (y_dot_lookup in arch_x64.y reads
     * it): every record carries its field table; field i lives
     * at tag_base+8+i*8 and the value (base+8) keeps today's offsets,
     * so statically-precise reads are bit-identical. Table label per
     * site (uid); table rows are decimal quads (both assemblers take
     * `.quad N`; no pointers, so no fixup-kind gaps). */
    Yv *ru = next_uid(st);
    st = yr_get(ru, "st");
    Yv *tlbl = ys_cat(ys("ytd_"), ys_long(yv_l(yr_get(ru, "uid"))));
    Yv *te = yav(0);
    te = ya_push(te, tlbl);
    te = ya_push(te, ys("TABLE"));
    te = ya_push(te, ys("1498307412"));
    te = ya_push(te, ys_long(n));
    long j = 0;
    while (j < n) {
        Yv *nm = ya_get(names, j);
        te = ya_push(te, ys_long(8 * j));
        long nl = yv_len(nm);
        te = ya_push(te, ys_long(nl));
        long c = 0;
        while (c < nl) {
            Yv *ch = ys_substr(nm, c, 1);
            long co = ys_ord(ch);
            te = ya_push(te, ys_long(co));
            c = c + 1;
        }
        j = j + 1;
    }
    Yv *trod = ya_push(yr_get(st, "rodata"), te);
    st = yr(11, "out", yr_get(st, "out"), "rodata", trod, "uid",
            yr_get(st, "uid"), "fuid", yr_get(st, "fuid"), "loc",
            yr_get(st, "loc"), "env", yr_get(st, "env"), "slots",
            yr_get(st, "slots"), "self_label", yr_get(st, "self_label"),
            "end_label", yr_get(st, "end_label"), "fns", yr_get(st, "fns"),
            "bodies", yr_get(st, "bodies"));
    st = emit(st, ys_cat(ys_cat(ys("    mov $"), ys_long(8 * n + 16)),
                         ys(", %rdi")));
    st = emit(st, ys("    call y_alloc"));
    st = emit(st, ys("    push %rax"));
    st = emit(st, ys_cat(ys_cat(ys("    lea "), tlbl), ys("(%rip), %rax")));
    st = emit(st, ys("    pop %rcx"));
    st = emit(st, ys("    mov %rax, 0(%rcx)"));
    st = emit(st, ys("    push %rcx"));
    long i = 0;
    while (i < nent) {
        /* mv is walked twice (gen, then infer), so bind it once. */
        Yv *mv = ya_get(mvals, i);
        Yv *mk = ya_get(mkeys, i);
        st = gen(st, mv);
        st = emit(st, ys("    pop %rcx"));
        if (ys_eq_lit(mk, "...")) {
            /* Spread: the source ran ONCE (just above); copy its fields
             * into their merged slots. A later entry's store overwrites. */
            st = emit(st, ys("    mov %rax, %rdx"));
            Yv *srec2 = infer(st, mv);
            if (ys_eq_lit(yr_get(srec2, "k"), "trec")) {
                Yv *sfs2 = yr_get(srec2, "fields");
                long sj = 0;
                while (sj < yv_len(sfs2)) {
                    Yv *sf2 = ya_get(sfs2, sj);
                    long mi2 = mfield_idx(names, yr_get(sf2, "name"));
                    /* %rdx is the source's record VALUE (field 0 at +0);
                     * %rcx is the fresh record's ALLOC base (fields at +8). */
                    st = emit(st, ys_cat(ys_cat(ys("    mov "), ys_long(sj * 8)),
                                         ys("(%rdx), %rsi")));
                    st = emit(st, ys_cat(ys_cat(ys("    mov %rsi, "),
                                                ys_long(8 + mi2 * 8)),
                                         ys("(%rcx)")));
                    sj = sj + 1;
                }
                ;
            } else {
                ;
            }
            ;
        } else {
            long mi = mfield_idx(names, mk);
            st = emit(st, ys_cat(ys_cat(ys("    mov %rax, "),
                                        ys_long(8 + mi * 8)),
                                 ys("(%rcx)")));
            ;
        }
        st = emit(st, ys("    push %rcx"));
        i = i + 1;
    }
    st = emit(st, ys("    pop %rax"));
    return emit(st, ys("    add $8, %rax"));
}

/* An anonymous `def(...) {...}` used as a value: it has no entry in the
 * hoisted table, so give it a fresh label, emit the body here (where the
 * capture types are known) and hand back the closure record. */
Yv *gen_func_literal(Yv *st, Yv *node) {
    Yv *caps = fn_captures(node, fn_names_of(yr_get(st, "fns")));
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
    Yv *lbl = arch_fn_label(yv_l(yr_get(rl, "uid")), ys("anon"));
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
    Yv *lbl = fn_label_of(yv_l(yr_get(rl, "uid")), name);
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
    long coff = (yv_l(yr_get(st, "slots")) + 1) * -8;
    st = emit(st, ys_cat(ys_cat(ys("    mov %rax, "), ys_long(coff)),
                         ys("(%rbp)")));
    Yv *st3 =
        yr(11, "out", yr_get(st, "out"), "rodata", yr_get(st, "rodata"), "uid",
           yr_get(st, "uid"), "fuid", yr_get(st, "fuid"), "loc",
           yr_get(st, "loc"), "env", yr_get(st, "env"), "slots",
           yv_long(yv_l(yr_get(st, "slots")) + 1), "self_label",
           yr_get(st, "self_label"), "end_label", yr_get(st, "end_label"),
           "fns", yr_get(st, "fns"), "bodies", yr_get(st, "bodies"));
    st3 = env_define(st3, name, ys("closure"), coff, ys(""),
                     func_type_in(st3, func));
    return box_bound(st3, name);
}

Yv *gen_decl(Yv *st, Yv *node) {
    if (ys_eq_lit(yr_get(node, "kind"), "def")) {
        /* A nested `def` that captures is a closure just like a let-bound
         * literal; a capture-free one stays hoisted (emitted by
         * emit_program, env pre-bound, calls go direct). Its own name is
         * no capture: the body reaches itself through its own record. */
        Yv *dex = fn_names_of(yr_get(st, "fns"));
        dex = ya_push(dex, yr_get(node, "name"));
        Yv *dcaps = fn_captures(yr_get(node, "v"), dex);
        if (yv_len(dcaps) == 0) {
            return st;
        } else {
            return gen_closure_binding(st, yr_get(node, "name"),
                                       yr_get(node, "v"), dcaps);
        }
    } else {
        if (ys_eq_lit(yr_get(yr_get(node, "v"), "k"), "func")) {
            /* let-bound function. Capture-free ones stay pure labels (the
             * env already binds them, calls go direct). One that captures
             * becomes a closure record built HERE, where the captured
             * values are live, and the binding holds that record. Its own
             * name is no capture: the body reaches itself through its own
             * record. */
            Yv *lex = fn_names_of(yr_get(st, "fns"));
            lex = ya_push(lex, yr_get(node, "name"));
            Yv *caps = fn_captures(yr_get(node, "v"), lex);
            if (yv_len(caps) == 0) {
                return st;
            } else {
                return gen_closure_binding(st, yr_get(node, "name"),
                                           yr_get(node, "v"), caps);
            }
        } else if (ys_eq_lit(yr_get(yr_get(node, "v"), "k"), "arrrep")) {
            /* heap array: [v; n] allocates a header {len, cap, data}.
             * Reference value like every other array: the binding holds
             * the header address. */
            Yv *t = yr_get(node, "typ");
            if (ys_eq_lit(yr_get(t, "k"), "tnone")) {
                t = infer(st, yr_get(node, "v"));
            }
            st = gen_arrrep_esz(st, yr_get(node, "v"), arr_elem_bytes(t));
            return bind_decl(st, yr_get(node, "name"), t);
        } else if (ys_eq_lit(yr_get(yr_get(node, "v"), "k"), "array")) {
            /* Heap array literal. The DECLARED element type decides the
             * element width: `let b: [byte] = [104, 105]` packs, and the
             * literal's own elements only ever infer as long. */
            Yv *t = yr_get(node, "typ");
            if (ys_eq_lit(yr_get(t, "k"), "tnone")) {
                t = infer(st, yr_get(node, "v"));
            }
            st = gen_array_esz(st, yr_get(node, "v"), arr_elem_bytes(t));
            return bind_decl(st, yr_get(node, "name"), t);
        } else if (ys_eq_lit(yr_get(yr_get(node, "v"), "k"), "rec")) {
            /* record literal: heap address (first-class value, plain
             * slot). An empty literal under a map annotation is the map
             * itself (the {keys, vals} shape the map ops expect). */
            if (ys_eq_lit(yr_get(yr_get(node, "typ"), "k"), "tmap") && yv_len(yr_get(yr_get(node, "v"), "keys")) == 0) {
                st = gen_maplit(st, yr_get(node, "v"));
            } else {
                st = gen(st, yr_get(node, "v"));
            }
            Yv *t = yr_get(node, "typ");
            if (ys_eq_lit(yr_get(t, "k"), "tnone")) {
                t = infer(st, yr_get(node, "v"));
            }
            return bind_decl(st, yr_get(node, "name"), t);
        } else {
            st = gen(st, yr_get(node, "v"));
            /* Reference semantics: arrays and records are heap values and
             * bindings share them (no copy-on-store). Cloning here made
             * every `let x = <call returning [T]>` O(n), so threading an
             * accumulator through helpers was O(n^2) — the assembler's
             * patch loop spent 650MB on a 20KB output. The C copy's value
             * model aliases too (yv.c). */
            /* bind with annotation or inferred type */
            Yv *t = yr_get(node, "typ");
            if (ys_eq_lit(yr_get(t, "k"), "tnone")) {
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
        st = emit(st, ys_cat(ys_cat(ys("    mov %rax, "),
                                   yr_get(ge, "label")),
                            ys("(%rip)")));
        return env_define(st, name, ys("global"), 0, yr_get(ge, "label"), t);
    } else {
        long off = (yv_l(yr_get(st, "slots")) + 1) * -8;
        st = emit(st, ys_cat(ys_cat(ys("    mov %rax, "), ys_long(off)),
                             ys("(%rbp)")));
        Yv *st2 =
            yr(11, "out", yr_get(st, "out"), "rodata", yr_get(st, "rodata"),
               "uid", yr_get(st, "uid"), "fuid", yr_get(st, "fuid"), "loc",
               yr_get(st, "loc"), "env", yr_get(st, "env"), "slots",
               yv_long(yv_l(yr_get(st, "slots")) + 1), "self_label",
               yr_get(st, "self_label"), "end_label", yr_get(st, "end_label"),
               "fns", yr_get(st, "fns"), "bodies", yr_get(st, "bodies"));
        st2 = env_define(st2, name, ys("local"), off, ys(""), t);
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
    st = gen(st, yr_get(node, "v"));
    if (ys_eq_lit(yr_get(e, "kind"), "capture")) {
        long idx = ys_tonum(yr_get(e, "label"));
        st = emit(st, ys_cat(ys_cat(ys("    mov "),
                                   ys_long(yv_l(yr_get(e, "off")))),
                            ys("(%rbp), %rcx")));
        st = emit(st, ys_cat(ys_cat(ys("    mov "),
                                   ys_long(8 * (idx + 1))),
                            ys("(%rcx), %rdx")));
        st = emit(st, ys("    mov %rax, (%rdx)"));
        return st;
    } else if (ys_eq_lit(yr_get(e, "kind"), "box")) {
        st = emit(st, ys_cat(ys_cat(ys("    mov "),
                                   ys_long(yv_l(yr_get(e, "off")))),
                            ys("(%rbp), %rdx")));
        st = emit(st, ys("    mov %rax, (%rdx)"));
        return st;
    } else if (ys_eq_lit(yr_get(e, "kind"), "global")) {
        return emit(st, ys_cat(ys_cat(ys("    mov %rax, "),
                                      yr_get(e, "label")),
                               ys("(%rip)")));
    } else {
        return emit(st, ys_cat(ys_cat(ys("    mov %rax, "),
                                      ys_long(yv_l(yr_get(e, "off")))),
                               ys("(%rbp)")));
    }
}

/* Fill n frame slots (base = lowest address) with the value in %rax. */
Yv *gen_fill(Yv *st, long base, long n) {
    if (n == 0) {
        return st;
    } else {
        Yv *r = next_loc(st);
        st = yr_get(r, "st");
        st = emit(st, ys_cat(ys_cat(ys("    mov $"), ys_long(n)), ys(", %rcx")));
        st = emit(st, ys_cat(yr_get(r, "lbl"), ys(":")));
        st = emit(st, ys("    dec %rcx"));
        st = emit(st, ys_cat(ys_cat(ys("    mov %rax, "), ys_long(base)),
                             ys("(%rbp,%rcx,8)")));
        return emit(st, ys_cat(ys("    jnz "), yr_get(r, "lbl")));
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
        st = emit(st, ys("    mov %rdx, %r10"));
        st = emit(st, ys("    mov %rax, %rdx"));
        st = emit(st, ys_cat(ys_cat(ys("    mov $"), ys_long(n)), ys(", %rcx")));
        st = emit(st, ys_cat(yr_get(r, "lbl"), ys(":")));
        st = emit(st, ys("    dec %rcx"));
        st = emit(st, elem_store_rdx(esz, ys("%r10"), ys("%rcx")));
        st = emit(st, ys_cat(ys("    jnz "), yr_get(r, "lbl")));
        st = emit(st, ys("    mov %r10, %rdx"));
        return st;
    }
}

/* [v; n] as a first-class expression: allocate a heap header
 * {len, cap, data...}, fill every slot with v, leave the address in %rax.
 * Usable anywhere (let, assign, call argument, return), not just `let`. */
Yv *gen_arrrep(Yv *st, Yv *node) {
    return gen_arrrep_esz(st, node, elem_bytes(infer(st, yr_get(node, "v"))));
}

/* Same, with the element width supplied by the declaration (`let b:
 * [byte; 4] = [0; 4]` — the literal's own elements infer as long). */
Yv *gen_arrrep_esz(Yv *st, Yv *node, long esz) {
    long n = yv_l(yr_get(node, "n"));
    st = gen(st, yr_get(node, "v"));
    st = emit(st, ys("    push %rax"));
    st = emit(st, ys_cat(ys_cat(ys("    mov $"), ys_long(arr_alloc_size(esz, n))),
                         ys(", %rdi")));
    st = emit(st, ys("    call y_alloc"));
    st = emit(st, ys("    push %rax"));
    st = emit(st, ys_cat(ys_cat(ys("    mov $"), ys_long(arr_header_size())),
                         ys(", %rdi")));
    st = emit(st, ys("    call y_alloc"));
    st = emit(st, ys("    pop %rdx"));
    st = emit(st, ys_cat(ys_cat(ys("    mov $"), ys_long(n)), ys(", (%rax)")));
    st = emit(st, ys_cat(ys_cat(ys("    mov $"), ys_long(n)), ys(", 8(%rax)")));
    st = emit(st, ys("    mov %rdx, 16(%rax)"));
    st = emit(st, ys("    mov %rax, %rdx"));
    st = emit(st, ys("    pop %rax"));
    st = gen_fill_heap(st, n, esz);
    return emit(st, ys("    mov %rdx, %rax"));
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
        } else {
            ;
        }
        ;
    } else {
        ;
    }
    if (o >= 97) {
        if (o <= 102) {
            v = o - 87;
            ;
        } else {
            ;
        }
        ;
    } else {
        ;
    }
    if (o >= 65) {
        if (o <= 70) {
            v = o - 55;
            ;
        } else {
            ;
        }
        ;
    } else {
        ;
    }
    return v;
}

/* A numeric literal denotes a float when it has a fraction or an exponent.
 * Radix literals are checked first: 0xE1 and 0xbeef contain 'e'/'E'/'b'. */
int lit_is_float(Yv *s) {
    int radix = 0;
    if (yv_len(s) > 2) {
        Yv *p = ys_substr(s, 0, 2);
        if (ys_eq_lit(p, "0x")) {
            radix = 1;
            ;
        } else {
            ;
        }
        if (ys_eq_lit(p, "0X")) {
            radix = 1;
            ;
        } else {
            ;
        }
        if (ys_eq_lit(p, "0b")) {
            radix = 1;
            ;
        } else {
            ;
        }
        if (ys_eq_lit(p, "0B")) {
            radix = 1;
            ;
        } else {
            ;
        }
        ;
    } else {
        ;
    }
    if (radix) {
        return 0;
    } else {
        int f = 0;
        if (ys_index_of(s, ys(".")) >= 0) {
            f = 1;
            ;
        } else {
            ;
        }
        if (ys_index_of(s, ys("e")) >= 0) {
            f = 1;
            ;
        } else {
            ;
        }
        if (ys_index_of(s, ys("E")) >= 0) {
            f = 1;
            ;
        } else {
            ;
        }
        return f;
    }
}

Yv *norm_num(Yv *s) {
    long radix = 0;
    if (yv_len(s) > 2) {
        Yv *p = ys_substr(s, 0, 2);
        if (ys_eq_lit(p, "0x")) {
            radix = 16;
            ;
        } else {
            ;
        }
        if (ys_eq_lit(p, "0X")) {
            radix = 16;
            ;
        } else {
            ;
        }
        if (ys_eq_lit(p, "0b")) {
            radix = 2;
            ;
        } else {
            ;
        }
        if (ys_eq_lit(p, "0B")) {
            radix = 2;
            ;
        } else {
            ;
        }
        ;
    } else {
        ;
    }
    if (radix == 0) {
        return s;
    } else {
        long v = 0;
        long i = 2;
        while (i < yv_len(s)) {
            Yv *c = ys_substr(s, i, 1);
            if (ys_eq_lit(c, "_")) {
                ;
            } else {
                v = v * radix + hexval_ch(c);
                ;
            }
            i = i + 1;
        }
        return ys_long(v);
    }
}

/* Digits of a float literal with the dot and exponent removed
 * (e.g. "3.25" -> 325, "1.5e-2" -> 15) and the matching net power of ten
 * (-> -2 and -3). Building the double at runtime as mantissa * 10^n lets
 * IEEE arithmetic do the rounding, which is exactly the value the literal
 * denotes — no float parser needed in the compiler. */
long flit_mant(Yv *s) {
    long v = 0;
    long i = 0;
    long n = flit_ebase(s);
    while (i < n) {
        Yv *c = ys_substr(s, i, 1);
        if (ys_eq_lit(c, ".")) {
            ;
        } else {
            v = v * 10 + hexval_ch(c);
            ;
        }
        i = i + 1;
    }
    return v;
}

/* Index of the 'e'/'E' that starts the exponent, or len(s) when absent. */
long flit_ebase(Yv *s) {
    long e = ys_index_of(s, ys("e"));
    if (e < 0) {
        e = ys_index_of(s, ys("E"));
        ;
    } else {
        ;
    }
    if (e < 0) {
        return yv_len(s);
    } else {
        return e;
    }
}

/* Net power of ten: the explicit exponent minus the fraction digit
 * count. */
long flit_exp(Yv *s) {
    long eb = flit_ebase(s);
    long dot = ys_index_of(s, ys("."));
    long frac = 0;
    if (dot >= 0) {
        frac = eb - dot - 1;
        ;
    } else {
        ;
    }
    long ex = 0;
    if (eb < yv_len(s)) {
        long i = eb + 1;
        int neg = 0;
        Yv *sc = ys_substr(s, i, 1);
        if (ys_eq_lit(sc, "-")) {
            neg = 1;
            i = i + 1;
            ;
        } else {
            ;
        }
        if (ys_eq_lit(sc, "+")) {
            i = i + 1;
            ;
        } else {
            ;
        }
        while (i < yv_len(s)) {
            ex = ex * 10 + hexval_ch(ys_substr(s, i, 1));
            i = i + 1;
        }
        if (neg) {
            ex = 0 - ex;
            ;
        } else {
            ;
        }
        ;
    } else {
        ;
    }
    return ex - frac;
}



/* 10^k for 0 <= k <= 18 (the largest power of ten a long holds exactly). */
long pow10(long k) {
    long d = 1;
    long i = 0;
    while (i < k) {
        d = d * 10;
        i = i + 1;
    }
    return d;
}

Yv *gen_lit(Yv *st, Yv *node) {
    if (lit_is_float(yr_get(node, "v"))) {
        /* Float literal: mantissa scaled by 10^n, where n folds together
         * the fraction length and any explicit exponent. Floats live in
         * %rax as raw IEEE754 bits; only arithmetic and comparison use
         * %xmm. */
        st = emit(st, ys_cat(ys_cat(ys("    mov $"),
                                    ys_long(flit_mant(yr_get(node, "v")))),
                             ys(", %rax")));
        st = emit(st, ys("    cvtsi2sd %rax, %xmm0"));
        return gen_scale10(st, flit_exp(yr_get(node, "v")));
    } else {
        return emit(st, ys_cat(ys_cat(ys("    mov $"),
                                      norm_num(yr_get(node, "v"))),
                               ys(", %rax")));
    }
}

/* %xmm0 *= 10^n (n may be negative). Applied in chunks of 18 so every
 * factor fits a long exactly; |n| <= 18 is therefore one correctly-rounded
 * operation, which is every literal anyone writes. */
Yv *gen_scale10(Yv *st, long n) {
    int up = n > 0;
    long left = n;
    if (!(up)) {
        left = 0 - n;
        ;
    } else {
        ;
    }
    while (left > 0) {
        long chunk = left;
        if (chunk > 18) {
            chunk = 18;
            ;
        } else {
            ;
        }
        st = emit(st, ys_cat(ys_cat(ys("    mov $"), ys_long(pow10(chunk))),
                             ys(", %rax")));
        st = emit(st, ys("    cvtsi2sd %rax, %xmm1"));
        if (up) {
            st = emit(st, ys("    mulsd %xmm1, %xmm0"));
            ;
        } else {
            st = emit(st, ys("    divsd %xmm1, %xmm0"));
            ;
        }
        left = left - chunk;
    }
    return emit(st, ys("    movq %xmm0, %rax"));
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
    st = emit(st, ys("    push %rax"));
    st = gen(st, yr_get(node, "idx"));
    st = emit(st, ys("    mov %rax, %rcx"));
    st = emit(st, ys("    pop %rax"));
    st = emit(st, ys("    test %rcx, %rcx"));
    st = emit(st, ys("    js y_oob"));
    if (ys_eq_lit(yr_get(bt, "k"), "tarrfix")) {
        st = emit(st, ys_cat(ys_cat(ys("    cmp $"),
                                    ys_long(yv_l(yr_get(bt, "n")))),
                             ys(", %rcx")));
        st = emit(st, ys("    jge y_oob"));
        return emit(st, elem_load(ixesz, ys("%rax"), ys("%rcx"), ys("%rax")));
    } else {
        st = emit(st, ys("    mov (%rax), %rdx"));
        st = emit(st, ys("    cmp %rdx, %rcx"));
        st = emit(st, ys("    jge y_oob"));
        return emit(st, elem_load(ixesz, ys("%rax"), ys("%rcx"), ys("%rax")));
    }
}

/* s.f = v — in-place record field write, for any object expression: a
 * plain variable, a nested place (`a[0].f`), a chain (`x.y.f`). Records
 * are heap addresses; field i lives at addr+8i (same layout the static
 * gen_dot read uses), so the write is: value -> (rec + 8*idx). The object
 * runs first, then the value. Reference semantics: a field write is
 * observable through every binding (the C copy's value model shares records
 * the same way). */
Yv *gen_dotassign(Yv *st, Yv *node) {
    Yv *dobj = yr_get(node, "obj");
    Yv *dkey = yr_get(node, "key");
    Yv *dt = infer(st, dobj);
    long idx = rec_field_idx(dt, dkey);
    st = gen(st, dobj);
    st = emit(st, ys("    push %rax"));
    st = gen(st, yr_get(node, "v"));
    st = emit(st, ys("    pop %rdx"));
    return emit(st, ys_cat(ys_cat(ys("    mov %rax, "), ys_long(8 * idx)),
                           ys("(%rdx)")));
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
Yv *n_num(Yv *v, long line, long col) {
    return yr(4, "k", ys("num"), "v", v, "line", yv_long(line), "col",
              yv_long(col));
}

Yv *n_id(Yv *v, long line, long col) {
    return yr(4, "k", ys("id"), "v", v, "line", yv_long(line), "col",
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
    return yr(5, "k", ys("call"), "callee", n_id(name, line, col), "args",
              args1(a0), "line", yv_long(line), "col", yv_long(col));
}

Yv *n_call2(Yv *name, Yv *a0, Yv *a1, long line, long col) {
    return yr(5, "k", ys("call"), "callee", n_id(name, line, col), "args",
              args2(a0, a1), "line", yv_long(line), "col", yv_long(col));
}

Yv *block2(Yv *a, Yv *b, long ln, long cl) {
    Yv *st = yav(0);
    st = ya_push(st, a);
    st = ya_push(st, b);
    return yr(4, "k", ys("block"), "stmts", st, "line", yv_long(ln), "col",
              yv_long(cl));
}

Yv *block3(Yv *a, Yv *b, Yv *c, long ln, long cl) {
    Yv *st = yav(0);
    st = ya_push(st, a);
    st = ya_push(st, b);
    st = ya_push(st, c);
    return yr(4, "k", ys("block"), "stmts", st, "line", yv_long(ln), "col",
              yv_long(cl));
}

Yv *block4(Yv *a, Yv *b, Yv *c, Yv *d, long ln, long cl) {
    Yv *st = yav(0);
    st = ya_push(st, a);
    st = ya_push(st, b);
    st = ya_push(st, c);
    st = ya_push(st, d);
    return yr(4, "k", ys("block"), "stmts", st, "line", yv_long(ln), "col",
              yv_long(cl));
}

Yv *block5(Yv *a, Yv *b, Yv *c, Yv *d, Yv *e, long ln, long cl) {
    Yv *st = yav(0);
    st = ya_push(st, a);
    st = ya_push(st, b);
    st = ya_push(st, c);
    st = ya_push(st, d);
    st = ya_push(st, e);
    return yr(4, "k", ys("block"), "stmts", st, "line", yv_long(ln), "col",
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
    return yr(4, "k", ys("block"), "stmts", st, "line", yv_long(ln), "col",
              yv_long(cl));
}

Yv *gen_incdec(Yv *st, Yv *node) {
    Yv *op = yr_get(node, "op");
    Yv *binop = ys("+");
    if (ys_eq_lit(op, "--")) {
        binop = ys("-");
        ;
    } else {
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
        Yv *nv = yr(6, "k", ys("bin"), "op", binop, "l", place, "r", one,
                    "line", yv_long(ln), "col", yv_long(cl));
        Yv *d2 = yr(7, "k", ys("decl"), "kind", ys("let"), "typ",
                    yr(1, "k", ys("tnone")), "name", ys_cat(t1, ys("v")), "v",
                    nv, "line", yv_long(ln), "col", yv_long(cl));
        Yv *asg = gen_place_assign(tgt, n_id(ys_cat(t1, ys("v")), ln, cl), t1,
                                   ln, cl);
        return gen(st, block4(bind, d2, asg,
                              n_id(ys_cat(t1, ys("v")), ln, cl), ln, cl));
    } else {
        /* x++ -> { bind; let v = x; x = v + 1; v } */
        Yv *d2 = yr(7, "k", ys("decl"), "kind", ys("let"), "typ",
                    yr(1, "k", ys("tnone")), "name", ys_cat(t1, ys("v")), "v",
                    place, "line", yv_long(ln), "col", yv_long(cl));
        Yv *nv = yr(6, "k", ys("bin"), "op", binop, "l",
                    n_id(ys_cat(t1, ys("v")), ln, cl), "r", one, "line",
                    yv_long(ln), "col", yv_long(cl));
        Yv *asg = gen_place_assign(tgt, nv, t1, ln, cl);
        return gen(st, block4(bind, d2, asg,
                              n_id(ys_cat(t1, ys("v")), ln, cl), ln, cl));
    }
}

Yv *gen_opassign(Yv *st, Yv *node) {
    Yv *t = infer(st, yr_get(node, "tgt"));
    if (ys_eq_lit(yr_get(t, "k"), "tarr") ||
        ys_eq_lit(yr_get(t, "k"), "tarrfix")) {
        return gen_opassign_arr(st, node);
    } else {
        return gen_opassign_arith(st, node);
    }
}

Yv *gen_opassign_arith(Yv *st, Yv *node) {
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
    Yv *bin = yr(6, "k", ys("bin"), "op", op, "l", rd, "r", yr_get(node, "v"),
                 "line", yv_long(ln), "col", yv_long(cl));
    Yv *d2 = yr(7, "k", ys("decl"), "kind", ys("let"), "typ",
                yr(1, "k", ys("tnone")), "name", ys_cat(t1, ys("v")), "v", bin,
                "line", yv_long(ln), "col", yv_long(cl));
    Yv *asg = gen_place_assign(tgt, n_id(ys_cat(t1, ys("v")), ln, cl), t1, ln,
                               cl);
    return gen(st, block4(bind, d2, asg, n_id(ys_cat(t1, ys("v")), ln, cl), ln,
                          cl));
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
    if (ys_eq_lit(yr_get(ba, "k"), "id")) {
        return n_id(yr_get(ba, "v"), ln, cl);
    } else {
        return n_id(ys_cat(t1, ys("a")), ln, cl);
    }
}

Yv *place_read_idx(Yv *tgt, Yv *t1, long ln, long cl) {
    return yr(5, "k", ys("index"), "arr", place_arr(tgt, t1, ln, cl), "idx",
              n_id(t1, ln, cl), "line", yv_long(ln), "col", yv_long(cl));
}

Yv *place_read_dot(Yv *tgt, Yv *t1, long ln, long cl) {
    return yr(5, "k", ys("dot"), "obj", n_id(t1, ln, cl), "key",
              yr_get(tgt, "key"), "line", yv_long(ln), "col", yv_long(cl));
}

Yv *gen_place_read(Yv *tgt, Yv *t1, long ln, long cl) {
    if (ys_eq_lit(yr_get(tgt, "k"), "id")) {
        return place_read_id(tgt, t1, ln, cl);
    } else if (ys_eq_lit(yr_get(tgt, "k"), "index")) {
        return place_read_idx(tgt, t1, ln, cl);
    } else {
        return place_read_dot(tgt, t1, ln, cl);
    }
}

Yv *place_asg_id(Yv *tgt, Yv *valnode, Yv *t1, long ln, long cl) {
    (void)t1; /* unused in native.y's def too */
    return yr(5, "k", ys("assign"), "name", yr_get(tgt, "v"), "v", valnode,
              "line", yv_long(ln), "col", yv_long(cl));
}

Yv *place_asg_idx(Yv *tgt, Yv *valnode, Yv *t1, long ln, long cl) {
    return yr(6, "k", ys("idxassign"), "arr", place_arr(tgt, t1, ln, cl), "idx",
              n_id(t1, ln, cl), "v", valnode, "line", yv_long(ln), "col",
              yv_long(cl));
}

Yv *place_asg_dot(Yv *tgt, Yv *valnode, Yv *t1, long ln, long cl) {
    return yr(6, "k", ys("dotassign"), "obj", n_id(t1, ln, cl), "key",
              yr_get(tgt, "key"), "v", valnode, "line", yv_long(ln), "col",
              yv_long(cl));
}

Yv *gen_place_assign(Yv *tgt, Yv *valnode, Yv *t1, long ln, long cl) {
    if (ys_eq_lit(yr_get(tgt, "k"), "id")) {
        return place_asg_id(tgt, valnode, t1, ln, cl);
    } else if (ys_eq_lit(yr_get(tgt, "k"), "index")) {
        return place_asg_idx(tgt, valnode, t1, ln, cl);
    } else {
        return place_asg_dot(tgt, valnode, t1, ln, cl);
    }
}

Yv *place_bind_id(Yv *tgt, Yv *t1, long ln, long cl) {
    (void)tgt; /* unused in native.y's def too */
    (void)t1;
    return yr(4, "k", ys("block"), "stmts", yav(0), "line", yv_long(ln), "col",
              yv_long(cl));
}

Yv *place_bind_idx_id(Yv *tgt, Yv *t1, long ln, long cl) {
    return yr(7, "k", ys("decl"), "kind", ys("let"), "typ",
              yr(1, "k", ys("tnone")), "name", t1, "v", yr_get(tgt, "idx"),
              "line", yv_long(ln), "col", yv_long(cl));
}

Yv *place_bind_idx_nest(Yv *tgt, Yv *t1, long ln, long cl) {
    /* nested base (`grid[0][1]`, `x.y[i]`, `f()[i]`): capture it in
     * `t1 + "a"` as well, so the place evaluates it exactly once. */
    Yv *tba = yr(7, "k", ys("decl"), "kind", ys("let"), "typ",
                 yr(1, "k", ys("tnone")), "name", ys_cat(t1, ys("a")), "v",
                 yr_get(tgt, "arr"), "line", yv_long(ln), "col", yv_long(cl));
    Yv *tib = yr(7, "k", ys("decl"), "kind", ys("let"), "typ",
                 yr(1, "k", ys("tnone")), "name", t1, "v",
                 yr_get(tgt, "idx"), "line", yv_long(ln), "col",
                 yv_long(cl));
    return block2(tba, tib, ln, cl);
}

Yv *place_bind_idx(Yv *tgt, Yv *t1, long ln, long cl) {
    Yv *ba = yr_get(tgt, "arr");
    if (ys_eq_lit(yr_get(ba, "k"), "id")) {
        return place_bind_idx_id(tgt, t1, ln, cl);
    } else {
        return place_bind_idx_nest(tgt, t1, ln, cl);
    }
}

Yv *place_bind_dot(Yv *tgt, Yv *t1, long ln, long cl) {
    return yr(7, "k", ys("decl"), "kind", ys("let"), "typ",
              yr(1, "k", ys("tnone")), "name", t1, "v", yr_get(tgt, "obj"),
              "line", yv_long(ln), "col", yv_long(cl));
}

/* The synthetic `let` that runs the target's index/base exactly once (a
 * no-op statement for id targets). */
Yv *gen_place_bind(Yv *tgt, Yv *t1, long ln, long cl) {
    if (ys_eq_lit(yr_get(tgt, "k"), "id")) {
        return place_bind_id(tgt, t1, ln, cl);
    } else if (ys_eq_lit(yr_get(tgt, "k"), "index")) {
        return place_bind_idx(tgt, t1, ln, cl);
    } else {
        return place_bind_dot(tgt, t1, ln, cl);
    }
}

Yv *gen_opassign_arr(Yv *st, Yv *node) {
    /* In-place array forms. `*=` prepends one element. `+=` pushes one
     * element — or, when the VALUE is an array, appends its elements one
     * by one (its length is captured first, so `a += a` is safe). The
     * checker enforces matching element types (types.y opassign_check). */
    Yv *tgt = yr_get(node, "tgt");
    Yv *op = yr_get(node, "op");
    Yv *v = yr_get(node, "v");
    long ln = yv_l(yr_get(node, "line"));
    long cl = yv_l(yr_get(node, "col"));
    Yv *r = next_uid(st);
    st = yr_get(r, "st");
    Yv *t1 = ys_cat(ys("y_t"), ys_long(yv_l(yr_get(r, "uid"))));
    Yv *tt = infer(st, tgt);
    Yv *et = yr_get(tt, "of");
    (void)et; /* bound in native.y too; unused there */
    Yv *mode = ys("push");
    if (ys_eq_lit(op, "*")) {
        mode = ys("prepend");
        ;
    } else {
        Yv *vt = infer(st, v);
        if (ys_eq_lit(yr_get(vt, "k"), "tarr") ||
            ys_eq_lit(yr_get(vt, "k"), "tarrfix")) {
            mode = ys("append");
            ;
        } else {
            ;
        }
        ;
    }
    if (ys_eq_lit(mode, "append")) {
        /* { let tv = v; let ti = 0; let tn = len(tv);
         *   while (ti < tn) { place = push(place, tv[ti]); ti = ti + 1 }
         *   place } */
        Yv *tv = yr(7, "k", ys("decl"), "kind", ys("let"), "typ",
                    yr(1, "k", ys("tnone")), "name", ys_cat(t1, ys("v")), "v",
                    v, "line", yv_long(ln), "col", yv_long(cl));
        Yv *ti = yr(7, "k", ys("decl"), "kind", ys("let"), "typ",
                    yr(1, "k", ys("tnone")), "name", ys_cat(t1, ys("i")), "v",
                    n_num(ys("0"), ln, cl), "line", yv_long(ln), "col",
                    yv_long(cl));
        Yv *tn = yr(7, "k", ys("decl"), "kind", ys("let"), "typ",
                    yr(1, "k", ys("tnone")), "name", ys_cat(t1, ys("n")), "v",
                    n_call1(ys("len"), n_id(ys_cat(t1, ys("v")), ln, cl), ln,
                            cl),
                    "line", yv_long(ln), "col", yv_long(cl));
        Yv *elem = yr(5, "k", ys("index"), "arr",
                      n_id(ys_cat(t1, ys("v")), ln, cl), "idx",
                      n_id(ys_cat(t1, ys("i")), ln, cl), "line", yv_long(ln),
                      "col", yv_long(cl));
        Yv *put = gen_place_assign(
            tgt,
            n_call2(ys("push"), gen_place_read(tgt, t1, ln, cl), elem, ln, cl),
            t1, ln, cl);
        Yv *step = yr(
            5, "k", ys("assign"), "name", ys_cat(t1, ys("i")), "v",
            yr(6, "k", ys("bin"), "op", ys("+"), "l",
               n_id(ys_cat(t1, ys("i")), ln, cl), "r", n_num(ys("1"), ln, cl),
               "line", yv_long(ln), "col", yv_long(cl)),
            "line", yv_long(ln), "col", yv_long(cl));
        Yv *loop = yr(
            5, "k", ys("while"), "cond",
            yr(6, "k", ys("bin"), "op", ys("<"), "l",
               n_id(ys_cat(t1, ys("i")), ln, cl), "r",
               n_id(ys_cat(t1, ys("n")), ln, cl), "line", yv_long(ln), "col",
               yv_long(cl)),
            "body", block2(put, step, ln, cl), "line", yv_long(ln), "col",
            yv_long(cl));
        return gen(st, block6(gen_place_bind(tgt, t1, ln, cl), tv, ti, tn, loop,
                              gen_place_read(tgt, t1, ln, cl), ln, cl));
    } else {
        Yv *fname = ys("push");
        if (ys_eq_lit(mode, "prepend")) {
            fname = ys("prepend");
            ;
        } else {
            ;
        }
        Yv *call = n_call2(fname, gen_place_read(tgt, t1, ln, cl), v, ln, cl);
        return gen(st,
                   block3(gen_place_bind(tgt, t1, ln, cl),
                          gen_place_assign(tgt, call, t1, ln, cl),
                          gen_place_read(tgt, t1, ln, cl), ln, cl));
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
    st = emit(st, ys("    push %rax"));
    st = gen(st, yr_get(node, "idx"));
    st = emit(st, ys("    push %rax"));
    st = gen(st, yr_get(node, "v"));
    st = emit(st, ys("    pop %rcx"));
    st = emit(st, ys("    pop %rdx"));
    st = emit(st, ys("    test %rcx, %rcx"));
    st = emit(st, ys("    js y_oob"));
    if (ys_eq_lit(yr_get(bt, "k"), "tarrfix")) {
        st = emit(st, ys_cat(ys_cat(ys("    cmp $"),
                                    ys_long(yv_l(yr_get(bt, "n")))),
                             ys(", %rcx")));
        st = emit(st, ys("    jge y_oob"));
        st = emit(st, ys("    mov %rdx, %r10"));
        st = emit(st, ys("    mov %rax, %rdx"));
        st = emit(st, elem_store_rdx(iaesz, ys("%r10"), ys("%rcx")));
        st = emit(st, ys("    mov %r10, %rdx"));
        ;
    } else {
        st = emit(st, ys("    push %rax"));
        st = emit(st, ys("    mov (%rdx), %rax"));
        st = emit(st, ys("    cmp %rax, %rcx"));
        st = emit(st, ys("    jge y_oob"));
        st = emit(st, ys("    pop %rax"));
        st = emit(st, ys("    mov %rdx, %r10"));
        st = emit(st, ys("    mov %rax, %rdx"));
        st = emit(st, elem_store_rdx(iaesz, ys("%r10"), ys("%rcx")));
        st = emit(st, ys("    mov %r10, %rdx"));
        ;
    }
    return st;
}

/* ── value formatting ───────────────────────────────────────────────────
 * A value of static type `t` sits in %rax; leave its string form in %rax.
 * The walk is unrolled at compile time (the type is static), so nested
 * arrays emit nested loops rather than needing a runtime type tag. */

Yv *gen_val_tostr_rax(Yv *st, Yv *t) {
    Yv *tk = yr_get(t, "k");
    if (ys_eq_lit(tk, "tstr")) {
        return st;
    } else if (ys_eq_lit(tk, "tbool")) {
        st = emit(st, ys("    push %rax"));
        st = emit(st, ys("    call y_bool_tostr"));
        return emit(st, ys("    add $8, %rsp"));
    } else if (ys_eq_lit(tk, "tfloat")) {
        st = emit(st, ys("    push %rax"));
        st = emit(st, ys("    call y_float_tostr"));
        return emit(st, ys("    add $8, %rsp"));
    } else if (ys_eq_lit(tk, "tarr")) {
        if (ys_eq_lit(yr_get(yr_get(t, "of"), "k"), "tbyte")) {
            /* [byte] stringifies Python-style: b'...' with escapes */
            return gen_helper1(st, ys("y_bytes_repr"));
        }
        return gen_arr_tostr_rax(st, yr_get(t, "of"));
    } else if (ys_eq_lit(tk, "tarrfix")) {
        if (ys_eq_lit(yr_get(yr_get(t, "of"), "k"), "tbyte")) {
            /* [byte] stringifies Python-style: b'...' with escapes */
            return gen_helper1(st, ys("y_bytes_repr"));
        }
        return gen_arr_tostr_rax(st, yr_get(t, "of"));
    } else if (ys_eq_lit(tk, "topt")) {
        return gen_opt_str_rax(st, t);
    } else if (ys_eq_lit(tk, "trec")) {
        return gen_rec_str_rax(st, t);
    } else if (ys_eq_lit(tk, "tunion")) {
        return gen_union_str_rax(st, t);
    } else {
        st = emit(st, ys("    push %rax"));
        st = emit(st, ys("    call y_long_tostr"));
        return emit(st, ys("    add $8, %rsp"));
    }
}

/* Array header in %rax -> "[e0, e1, ...]" in %rax, the same form tostring()
 * gives. Slots: [src][acc][i]. */
Yv *gen_arr_tostr_rax(Yv *st, Yv *elty) {
    long soff = (yv_l(yr_get(st, "slots")) + 1) * -8;
    long aoff = (yv_l(yr_get(st, "slots")) + 2) * -8;
    long ioff = (yv_l(yr_get(st, "slots")) + 3) * -8;
    st = yr(11, "out", yr_get(st, "out"), "rodata", yr_get(st, "rodata"), "uid",
            yr_get(st, "uid"), "fuid", yr_get(st, "fuid"), "loc",
            yr_get(st, "loc"), "env", yr_get(st, "env"), "slots",
            yv_long(yv_l(yr_get(st, "slots")) + 3), "self_label",
            yr_get(st, "self_label"), "end_label", yr_get(st, "end_label"),
            "fns", yr_get(st, "fns"), "bodies", yr_get(st, "bodies"));
    st = emit(st, ys_cat(ys_cat(ys("    mov %rax, "), ys_long(soff)),
                         ys("(%rbp)")));
    st = gen_str_const(st, ys("["));
    st = emit(st, ys_cat(ys_cat(ys("    mov %rax, "), ys_long(aoff)),
                         ys("(%rbp)")));
    st = emit(st, ys("    xor %eax, %eax"));
    st = emit(st, ys_cat(ys_cat(ys("    mov %rax, "), ys_long(ioff)),
                         ys("(%rbp)")));
    Yv *r1 = next_loc(st);
    st = yr_get(r1, "st");
    Yv *r2 = next_loc(st);
    st = yr_get(r2, "st");
    Yv *r3 = next_loc(st);
    st = yr_get(r3, "st");
    st = emit(st, ys_cat(yr_get(r1, "lbl"), ys(":")));
    st = emit(st, ys_cat(ys_cat(ys("    mov "), ys_long(soff)),
                         ys("(%rbp), %rdx")));
    st = emit(st, ys("    mov (%rdx), %rcx"));
    st = emit(st, ys_cat(ys_cat(ys("    mov "), ys_long(ioff)),
                         ys("(%rbp), %rax")));
    st = emit(st, ys("    cmp %rcx, %rax"));
    st = emit(st, ys_cat(ys("    jge "), yr_get(r2, "lbl")));
    st = emit(st, ys("    test %rax, %rax"));
    st = emit(st, ys_cat(ys("    jz "), yr_get(r3, "lbl")));
    st = gen_acc_cat_slot(st, aoff, ys(", "));
    st = emit(st, ys_cat(yr_get(r3, "lbl"), ys(":")));
    st = emit(st, ys_cat(ys_cat(ys("    mov "), ys_long(soff)),
                         ys("(%rbp), %rdx")));
    st = emit(st, ys_cat(ys_cat(ys("    mov "), ys_long(ioff)),
                         ys("(%rbp), %rcx")));
    st = emit(st, elem_load(elem_bytes(elty), ys("%rdx"), ys("%rcx"),
                            ys("%rax")));
    st = gen_val_tostr_rax(st, elty);
    st = emit(st, ys("    mov %rax, %rdx"));
    st = emit(st, ys_cat(ys_cat(ys("    mov "), ys_long(aoff)),
                         ys("(%rbp), %rax")));
    st = emit(st, ys("    push %rax"));
    st = emit(st, ys("    push %rdx"));
    st = emit(st, ys("    call y_str_cat"));
    st = emit(st, ys("    add $16, %rsp"));
    st = emit(st, ys_cat(ys_cat(ys("    mov %rax, "), ys_long(aoff)),
                         ys("(%rbp)")));
    st = emit(st, ys_cat(ys_cat(ys("    mov "), ys_long(ioff)),
                         ys("(%rbp), %rax")));
    st = emit(st, ys("    inc %rax"));
    st = emit(st, ys_cat(ys_cat(ys("    mov %rax, "), ys_long(ioff)),
                         ys("(%rbp)")));
    st = emit(st, ys_cat(ys("    jmp "), yr_get(r1, "lbl")));
    st = emit(st, ys_cat(yr_get(r2, "lbl"), ys(":")));
    st = gen_acc_cat_slot(st, aoff, ys("]"));
    return emit(st, ys_cat(ys_cat(ys("    mov "), ys_long(aoff)),
                           ys("(%rbp), %rax")));
}

/* slot(%rbp) = slot(%rbp) + <constant>. */
Yv *gen_acc_cat_slot(Yv *st, long off, Yv *s) {
    st = emit(st, ys_cat(ys_cat(ys("    mov "), ys_long(off)), ys("(%rbp), %rax")));
    st = emit(st, ys("    push %rax"));
    st = gen_str_const(st, s);
    st = emit(st, ys("    push %rax"));
    st = emit(st, ys("    call y_str_cat"));
    st = emit(st, ys("    add $16, %rsp"));
    return emit(st, ys_cat(ys_cat(ys("    mov %rax, "), ys_long(off)),
                           ys("(%rbp)")));
}

/* ── element size ───────────────────────────────────────────────────────
 * Byte arrays are PACKED: one byte per element, not eight. Every element
 * lives at base + 16 + i*esz, so the scale factor, the allocation size and
 * the load/store width all follow from the element type. Everything else
 * stays 8 bytes (one machine word per value). */

long elem_bytes(Yv *t) {
    if (ys_eq_lit(yr_get(t, "k"), "tbyte")) {
        return 1;
    } else {
        return 8;
    }
}

long arr_elem_bytes(Yv *t) {
    if (ys_eq_lit(yr_get(t, "k"), "tarr")) {
        return elem_bytes(yr_get(t, "of"));
    } else if (ys_eq_lit(yr_get(t, "k"), "tarrfix")) {
        return elem_bytes(yr_get(t, "of"));
    } else {
        return 8;
    }
}

/* Load element [idx] into `dst`. `base` is the ARRAY HEADER register, `idx`
 * the index register, `dst` the result. Headers are {len, cap, data} with
 * the elements in a separate block, so the data pointer rides through %dst. */
Yv *elem_load(long esz, Yv *base, Yv *idx, Yv *dst) {
    if (esz == 1) {
        return ys_cat(
            ys_cat(ys_cat(ys_cat(ys_cat(ys("    mov 16("), base), ys("), ")),
                          dst),
                   ys("\n")),
            ys_cat(ys_cat(ys_cat(ys_cat(ys_cat(ys("    movzbq ("), dst),
                                          ys(",")),
                                   idx),
                            ys(",1), ")),
                   dst));
    } else {
        return ys_cat(
            ys_cat(ys_cat(ys_cat(ys_cat(ys("    mov 16("), base), ys("), ")),
                          dst),
                   ys("\n")),
            ys_cat(ys_cat(ys_cat(ys_cat(ys_cat(ys("    mov ("), dst),
                                          ys(",")),
                                   idx),
                            ys(",8), ")),
                   dst));
    }
}

/* Store %rdx into element [idx] of the array based at `base`. The value
 * always arrives in %rdx so the byte form can name %dl without a register
 * table; a packed store truncates to 8 bits, which is the narrowing.
 * %r11 is the scratch that carries the data pointer: no generated value
 * lives in it across a store (the syscall instruction clobbers it). */
Yv *elem_store_rdx(long esz, Yv *base, Yv *idx) {
    if (esz == 1) {
        return ys_cat(ys_cat(ys_cat(ys_cat(ys("    mov 16("), base),
                                    ys("), %r11\n    movb %dl, (%r11,")),
                             idx),
                      ys(",1)"));
    } else {
        return ys_cat(ys_cat(ys_cat(ys_cat(ys("    mov 16("), base),
                                    ys("), %r11\n    mov %rdx, (%r11,")),
                             idx),
                      ys(",8)"));
    }
}

/* Same, for a compile-time-constant index (array literals): fold the
 * offset into the displacement instead of using an index register. */
Yv *elem_store_rdx_const(long esz, Yv *base, long k) {
    if (esz == 1) {
        return ys_cat(ys_cat(ys_cat(ys("    mov 16("), base),
                                    ys("), %r11\n    movb %dl, ")),
                      ys_cat(ys_long(k), ys("(%r11)")));
    } else {
        return ys_cat(ys_cat(ys_cat(ys("    mov 16("), base),
                                    ys("), %r11\n    mov %rdx, ")),
                      ys_cat(ys_long(k * 8), ys("(%r11)")));
    }
}

/* The array header is {len, cap, data} and NEVER moves: elements live in a
 * separate block, so growth keeps every alias valid (that is what makes
 * `arr += v` in-place). This is the block size for n elements. */
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
    Yv *t = infer(st, dobj);
    long idx = rec_field_idx(t, dkey);
    if (idx < 0) {
        /* unknown static shape ({k}-holes, bare params): dynamic field
         * lookup. The record carries its shape table (see gen_reclit note);
         * the key goes through the regular string rodata channel. */
        Yv *r = next_uid(st);
        st = yr_get(r, "st");
        Yv *klbl = arch_str_label(yv_l(yr_get(r, "uid")));
        Yv *krod = yav(0);
        krod = ya_push(krod, klbl);
        krod = ya_push(krod, ys_long(yv_len(dkey)));
        krod = ya_push(krod, esc_asm(dkey));
        Yv *rod = ya_push(yr_get(st, "rodata"), krod);
        st = yr(11, "out", yr_get(st, "out"), "rodata", rod, "uid",
                yr_get(st, "uid"), "fuid", yr_get(st, "fuid"), "loc",
                yr_get(st, "loc"), "env", yr_get(st, "env"), "slots",
                yr_get(st, "slots"), "self_label", yr_get(st, "self_label"),
                "end_label", yr_get(st, "end_label"), "fns",
                yr_get(st, "fns"), "bodies", yr_get(st, "bodies"));
        st = gen(st, dobj);
        st = emit(st, ys("    push %rax"));
        st = emit(st, ys_cat(ys_cat(ys("    lea "), klbl), ys("(%rip), %rax")));
        st = emit(st, ys("    push %rax"));
        st = emit(st, ys("    call y_dot_lookup"));
        st = emit(st, ys("    add $16, %rsp"));
        ;
    } else {
        st = gen(st, dobj);
        st = emit(st, ys_cat(ys_cat(ys("    mov "), ys_long(idx * 8)),
                             ys("(%rax), %rax")));
        ;
    }
    return st;
}

/* Static field index of `key` in trec type t (-1 = checker drift;
 * the checker rejects unknown fields, so this is unreachable). */
long rec_field_idx(Yv *t, Yv *key) {
    long idx = -1;
    if (ys_eq_lit(yr_get(t, "k"), "trec")) {
        Yv *fs = yr_get(t, "fields");
        long i = 0;
        while (i < yv_len(fs)) {
            /* f is read twice: the name compare, then the field's type. */
            Yv *f = ya_get(fs, i);
            if (ys_eq(yr_get(f, "name"), key)) {
                idx = i;
                ;
            } else {
                ;
            }
            i = i + 1;
        }
    } else if (ys_eq_lit(yr_get(t, "k"), "tmap")) {
        /* a map is lowered to the fixed {keys, vals} record (see "maps") */
        if (ys_eq_lit(key, "keys")) { idx = 0; ; } else if (ys_eq_lit(key, "vals")) { idx = 1; ; } else { ; }
    }
    return idx;
}

/* Heap array literal [v, ...]: a data block of arr_alloc_size(esz, n) and a
 * separate arr_header_size() header {len, cap, data}; the values are stored
 * into the data block through the header's pointer. The header address (an
 * 8-byte value like any other) is the expression value. */
Yv *gen_array(Yv *st, Yv *node) {
    return gen_array_esz(st, node, arr_elem_bytes(infer(st, node)));
}

/* Same, with the element width supplied by the declaration (`let b:
 * [byte] = [104, 105]` — the literal's own elements infer as long). */
Yv *gen_array_esz(Yv *st, Yv *node, long esz) {
    Yv *elems = yr_get(node, "elems");
    st = gen_push_args(st, elems);
    long n = yv_len(elems);
    st = emit(st, ys_cat(ys_cat(ys("    mov $"),
                                ys_long(arr_alloc_size(esz, n))),
                         ys(", %rdi")));
    st = emit(st, ys("    call y_alloc"));
    st = emit(st, ys("    push %rax"));
    st = emit(st, ys_cat(ys_cat(ys("    mov $"), ys_long(arr_header_size())),
                         ys(", %rdi")));
    st = emit(st, ys("    call y_alloc"));
    st = emit(st, ys("    mov %rax, %r10"));
    st = emit(st, ys("    pop %rdx"));
    st = emit(st, ys_cat(ys_cat(ys("    mov $"), ys_long(n)), ys(", (%r10)")));
    st = emit(st, ys_cat(ys_cat(ys("    mov $"), ys_long(n)), ys(", 8(%r10)")));
    st = emit(st, ys("    mov %rdx, 16(%r10)"));
    long k = n - 1;
    while (k >= 0) {
        st = emit(st, ys("    pop %rdx"));
        st = emit(st, elem_store_rdx_const(esz, ys("%r10"), k));
        k = k - 1;
    }
    return emit(st, ys("    mov %r10, %rax"));
}

Yv *gen_len(Yv *st, Yv *node) {
    /* Checker: single array or string argument. Fixed size is immediate
     * (from the inferred type itself); heap length (array header or string
     * header) loads from address+0. NOTE: the argument is any array-typed
     * expression (id, dot like `a.args`, call result) — never assume a
     * plain id (no `.v` reads here); infer gives the static type. */
    Yv *args = yr_get(node, "args");
    Yv *at = infer(st, ya_get(args, 0));
    if (ys_eq_lit(yr_get(at, "k"), "tmap")) {
        /* len(m) = len(m.keys): the entry count */
        return gen(st, n_call1(ys("len"), n_dot(ya_get(args, 0), ys("keys"), yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col"))), yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col"))));
    } else if (ys_eq_lit(yr_get(at, "k"), "tstr")) {
        st = gen(st, ya_get(args, 0));
        return emit(st, ys("    mov (%rax), %rax"));
    } else {
        st = gen(st, ya_get(args, 0));
        return emit(st, ys("    mov (%rax), %rax"));
    }
}

/* push(arr, v): Y calling convention straight into the prelude helper.
 * Returns the (possibly reallocated) header — rebind it: `a = push(a, v)`. */
Yv *gen_push(Yv *st, Yv *node) {
    Yv *pargs = yr_get(node, "args");
    long pesz = arr_elem_bytes(infer(st, ya_get(pargs, 0)));
    st = gen_push_args(st, yr_get(node, "args"));
    st = emit(st, ys_cat(ys_cat(ys("    mov $"), ys_long(pesz)), ys(", %rax")));
    st = emit(st, ys("    push %rax"));
    st = emit(st, ys("    call y_arr_push"));
    long nbytes = yv_len(yr_get(node, "args")) * 8 + 8;
    return emit(st, ys_cat(ys_cat(ys("    add $"), ys_long(nbytes)),
                           ys(", %rsp")));
}

Yv *gen_some(Yv *st, Yv *node) {
    Yv *args = yr_get(node, "args");
    st = gen(st, ya_get(args, 0));
    st = emit(st, ys("    push %rax"));
    st = emit(st, ys("    mov $8, %rdi"));
    st = emit(st, ys("    call y_alloc"));
    st = emit(st, ys("    pop %rcx"));
    st = emit(st, ys("    mov %rcx, (%rax)"));
    return st;
}

Yv *gen_is_some(Yv *st, Yv *node) {
    Yv *args = yr_get(node, "args");
    st = gen(st, ya_get(args, 0));
    st = emit(st, ys("    test %rax, %rax"));
    st = emit(st, ys("    setne %al"));
    return emit(st, ys("    movzbq %al, %rax"));
}

Yv *gen_unwrap(Yv *st, Yv *node) {
    Yv *args = yr_get(node, "args");
    st = gen(st, ya_get(args, 0));
    st = emit(st, ys("    test %rax, %rax"));
    st = emit(st, ys("    jz y_opt_unwrap"));
    return emit(st, ys("    mov (%rax), %rax"));
}

/* ── string builtins (all on {len, data} header objects) ────────────────
 * Every helper takes header addresses via the Y calling convention
 * (args pushed left-to-right, first arg deepest) and returns a header
 * address (or long) in %rax. Caller cleans the stack. */

Yv *gen_substr(Yv *st, Yv *node) {
    st = gen_push_args(st, yr_get(node, "args"));
    st = emit(st, ys("    call y_str_substr"));
    return emit(st, ys("    add $24, %rsp"));
}

Yv *gen_trim(Yv *st, Yv *node) {
    st = gen_push_args(st, yr_get(node, "args"));
    st = emit(st, ys("    call y_str_trim"));
    return emit(st, ys("    add $8, %rsp"));
}

/* prepend(arr, v) -> arr: in-place insert at the front (the header never
 * moves, so every alias sees it). The `*=` operator desugars to this. */
Yv *gen_prepend(Yv *st, Yv *node) {
    Yv *pargs = yr_get(node, "args");
    long pesz = arr_elem_bytes(infer(st, ya_get(pargs, 0)));
    st = gen_push_args(st, yr_get(node, "args"));
    st = emit(st, ys_cat(ys_cat(ys("    mov $"), ys_long(pesz)), ys(", %rax")));
    st = emit(st, ys("    push %rax"));
    st = emit(st, ys("    call y_arr_prepend"));
    long nbytes = yv_len(yr_get(node, "args")) * 8 + 8;
    return emit(st, ys_cat(ys_cat(ys("    add $"), ys_long(nbytes)),
                           ys(", %rsp")));
}

/* byte_at(s, i): byte i of string s, trapped when out of bounds. This is
 * the primitive every string helper is built on — reading one byte must
 * not copy the string the way bytes() does. Inline, four instructions,
 * because scanning loops call it per character. */
Yv *gen_byte_at(Yv *st, Yv *node) {
    Yv *args = yr_get(node, "args");
    st = gen(st, ya_get(args, 0));
    st = emit(st, ys("    push %rax"));
    st = gen(st, ya_get(args, 1));
    st = emit(st, ys("    pop %rcx"));
    st = emit(st, ys("    mov (%rcx), %rdx"));
    st = emit(st, ys("    test %rax, %rax"));
    st = emit(st, ys("    js y_oob"));
    st = emit(st, ys("    cmp %rdx, %rax"));
    st = emit(st, ys("    jge y_oob"));
    return emit(st, ys("    movzbq 8(%rcx,%rax,1), %rax"));
}

Yv *gen_ord(Yv *st, Yv *node) {
    st = gen_push_args(st, yr_get(node, "args"));
    st = emit(st, ys("    call y_str_ord"));
    return emit(st, ys("    add $8, %rsp"));
}

Yv *gen_chr(Yv *st, Yv *node) {
    st = gen_push_args(st, yr_get(node, "args"));
    st = emit(st, ys("    call y_str_chr"));
    return emit(st, ys("    add $8, %rsp"));
}

Yv *gen_tonum(Yv *st, Yv *node) {
    st = gen_push_args(st, yr_get(node, "args"));
    st = emit(st, ys("    call y_str_tonum"));
    return emit(st, ys("    add $8, %rsp"));
}

Yv *gen_tostring(Yv *st, Yv *node) {
    /* dispatch on the static type: long/bool need conversion, str is
     * identity */
    Yv *targs = yr_get(node, "args");
    Yv *a0 = ya_get(targs, 0);
    Yv *t = infer(st, a0);
    if (ys_eq_lit(yr_get(t, "k"), "tstr")) {
        return gen(st, a0);
    } else if (ys_eq_lit(yr_get(t, "k"), "tbool")) {
        st = gen_push_args(st, yr_get(node, "args"));
        st = emit(st, ys("    call y_bool_tostr"));
        return emit(st, ys("    add $8, %rsp"));
    } else if (ys_eq_lit(yr_get(t, "k"), "tfloat")) {
        st = gen_push_args(st, yr_get(node, "args"));
        st = emit(st, ys("    call y_float_tostr"));
        return emit(st, ys("    add $8, %rsp"));
    } else if (ys_eq_lit(yr_get(t, "k"), "tarr")) {
        st = gen(st, a0);
        if (ys_eq_lit(yr_get(yr_get(t, "of"), "k"), "tbyte")) {
            /* [byte] stringifies Python-style: b'...' with escapes */
            return gen_helper1(st, ys("y_bytes_repr"));
        }
        return gen_arr_tostr_rax(st, yr_get(t, "of"));
    } else if (ys_eq_lit(yr_get(t, "k"), "tarrfix")) {
        st = gen(st, a0);
        if (ys_eq_lit(yr_get(yr_get(t, "of"), "k"), "tbyte")) {
            /* [byte] stringifies Python-style: b'...' with escapes */
            return gen_helper1(st, ys("y_bytes_repr"));
        }
        return gen_arr_tostr_rax(st, yr_get(t, "of"));
    } else if (ys_eq_lit(yr_get(t, "k"), "topt")) {
        st = gen(st, a0);
        return gen_opt_str_rax(st, t);
    } else if (ys_eq_lit(yr_get(t, "k"), "trec")) {
        st = gen(st, a0);
        return gen_rec_str_rax(st, t);
    } else if (ys_eq_lit(yr_get(t, "k"), "tunion")) {
        st = gen(st, a0);
        return gen_union_str_rax(st, t);
    } else if (ys_eq_lit(yr_get(t, "k"), "tmap")) {
        return gen_map_repr(st, a0, t);
    } else {
        st = gen_push_args(st, yr_get(node, "args"));
        st = emit(st, ys("    call y_long_tostr"));
        return emit(st, ys("    add $8, %rsp"));
    }
}

Yv *gen_index_of(Yv *st, Yv *node, int last) {
    st = gen_push_args(st, yr_get(node, "args"));
    if (last) {
        st = emit(st, ys("    call y_str_lastidx"));
        return emit(st, ys("    add $16, %rsp"));
    } else {
        st = emit(st, ys("    call y_str_index"));
        return emit(st, ys("    add $16, %rsp"));
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
    Yv *eltyp = yr(1, "k", ys("tunk"));
    if (ys_eq_lit(yr_get(at, "k"), "tarr")) {
        eltyp = yr_get(at, "of");
        ;
    } else {
        ;
    }
    if (ys_eq_lit(yr_get(at, "k"), "tarrfix")) {
        eltyp = yr_get(at, "of");
        ;
    } else {
        ;
    }
    Yv *ek = yr_get(eltyp, "k");
    if (ys_eq_lit(ek, "tlong")) {
        return gen_join_conv(st, node, ys("y_long_tostr"), 8);
    } else if (ys_eq_lit(ek, "tbyte")) {
        return gen_join_conv(st, node, ys("y_long_tostr"), 1);
    } else if (ys_eq_lit(ek, "tbool")) {
        return gen_join_conv(st, node, ys("y_bool_tostr"), 8);
    } else if (ys_eq_lit(ek, "tfloat")) {
        return gen_join_conv(st, node, ys("y_float_tostr"), 8);
    } else {
        st = gen_push_args(st, yr_get(node, "args"));
        st = emit(st, ys("    call y_str_join"));
        return emit(st, ys("    add $16, %rsp"));
    }
}

/* Slots: [src][dst][i]. Builds dst = [tostr(src[0]), ...] then joins it. */
Yv *gen_join_conv(Yv *st, Yv *node, Yv *tostr_fn, long esz) {
    long soff = (yv_l(yr_get(st, "slots")) + 1) * -8;
    long doff = (yv_l(yr_get(st, "slots")) + 2) * -8;
    long ioff = (yv_l(yr_get(st, "slots")) + 3) * -8;
    st = yr(11, "out", yr_get(st, "out"), "rodata", yr_get(st, "rodata"), "uid",
            yr_get(st, "uid"), "fuid", yr_get(st, "fuid"), "loc",
            yr_get(st, "loc"), "env", yr_get(st, "env"), "slots",
            yv_long(yv_l(yr_get(st, "slots")) + 3), "self_label",
            yr_get(st, "self_label"), "end_label", yr_get(st, "end_label"),
            "fns", yr_get(st, "fns"), "bodies", yr_get(st, "bodies"));
    Yv *jargs = yr_get(node, "args");
    st = gen(st, ya_get(jargs, 0));
    st = emit(st, ys_cat(ys_cat(ys("    mov %rax, "), ys_long(soff)),
                         ys("(%rbp)")));
    st = emit(st, ys("    mov (%rax), %rdi"));
    st = emit(st, ys("    shl $3, %rdi"));
    st = emit(st, ys("    call y_alloc"));
    st = emit(st, ys("    push %rax"));
    st = emit(st, ys("    mov $24, %rdi"));
    st = emit(st, ys("    call y_alloc"));
    st = emit(st, ys("    pop %rdx"));
    st = emit(st, ys_cat(ys_cat(ys("    mov %rax, "), ys_long(doff)),
                         ys("(%rbp)")));
    st = emit(st, ys_cat(ys_cat(ys("    mov "), ys_long(soff)),
                         ys("(%rbp), %rcx")));
    st = emit(st, ys("    mov (%rcx), %rcx"));
    st = emit(st, ys("    mov %rcx, (%rax)"));
    st = emit(st, ys("    mov %rcx, 8(%rax)"));
    st = emit(st, ys("    mov %rdx, 16(%rax)"));
    st = emit(st, ys("    xor %eax, %eax"));
    st = emit(st, ys_cat(ys_cat(ys("    mov %rax, "), ys_long(ioff)),
                         ys("(%rbp)")));
    Yv *r1 = next_loc(st);
    st = yr_get(r1, "st");
    Yv *r2 = next_loc(st);
    st = yr_get(r2, "st");
    st = emit(st, ys_cat(yr_get(r1, "lbl"), ys(":")));
    st = emit(st, ys_cat(ys_cat(ys("    mov "), ys_long(soff)),
                         ys("(%rbp), %rdx")));
    st = emit(st, ys("    mov (%rdx), %rcx"));
    st = emit(st, ys_cat(ys_cat(ys("    mov "), ys_long(ioff)),
                         ys("(%rbp), %rax")));
    st = emit(st, ys("    cmp %rcx, %rax"));
    st = emit(st, ys_cat(ys("    jge "), yr_get(r2, "lbl")));
    st = emit(st, elem_load(esz, ys("%rdx"), ys("%rax"), ys("%rcx")));
    st = emit(st, ys("    push %rcx"));
    st = emit(st, ys_cat(ys("    call "), tostr_fn));
    st = emit(st, ys("    add $8, %rsp"));
    st = emit(st, ys_cat(ys_cat(ys("    mov "), ys_long(ioff)),
                         ys("(%rbp), %rcx")));
    st = emit(st, ys_cat(ys_cat(ys("    mov "), ys_long(doff)),
                         ys("(%rbp), %rdx")));
    st = emit(st, ys("    mov 16(%rdx), %rdx"));
    st = emit(st, ys("    mov %rax, (%rdx,%rcx,8)"));
    st = emit(st, ys("    inc %rcx"));
    st = emit(st, ys_cat(ys_cat(ys("    mov %rcx, "), ys_long(ioff)),
                         ys("(%rbp)")));
    st = emit(st, ys_cat(ys("    jmp "), yr_get(r1, "lbl")));
    st = emit(st, ys_cat(yr_get(r2, "lbl"), ys(":")));
    st = emit(st, ys_cat(ys_cat(ys("    mov "), ys_long(doff)),
                         ys("(%rbp), %rax")));
    st = emit(st, ys("    push %rax"));
    st = gen(st, ya_get(jargs, 1));
    st = emit(st, ys("    push %rax"));
    st = emit(st, ys("    call y_str_join"));
    return emit(st, ys("    add $16, %rsp"));
}

Yv *gen_split(Yv *st, Yv *node) {
    st = gen_push_args(st, yr_get(node, "args"));
    st = emit(st, ys("    call y_str_split"));
    return emit(st, ys("    add $16, %rsp"));
}

Yv *gen_puts(Yv *st, Yv *node) {
    /* puts(v): write the value WITHOUT trailing newline (C semantics:
     * fputs + flush). Like print but no newline; returns nothing (void). */
    Yv *pargs = yr_get(node, "args");
    Yv *pa = ya_get(pargs, 0);
    st = gen(st, pa);
    Yv *t = infer(st, pa);
    if (ys_eq_lit(yr_get(t, "k"), "tbool")) {
        st = gen_helper1(st, ys("y_put_bool"));
        return emit(st, ys("    xor %eax, %eax"));
    } else if (ys_eq_lit(yr_get(t, "k"), "tstr")) {
        st = gen_helper1(st, ys("y_put_hstr"));
        return emit(st, ys("    xor %eax, %eax"));
    } else {
        st = gen_helper1(st, ys("y_put_long"));
        return emit(st, ys("    xor %eax, %eax"));
    }
}

Yv *gen_eputs(Yv *st, Yv *node) {
    /* eputs(v): like puts, but on fd 2. Profiling/diagnostic output must
     * never land in stdout (where `-S` assembly and program output live). */
    Yv *pargs = yr_get(node, "args");
    Yv *pa = ya_get(pargs, 0);
    st = gen(st, pa);
    Yv *t = infer(st, pa);
    if (ys_eq_lit(yr_get(t, "k"), "tbool")) {
        st = gen_helper1(st, ys("y_eput_bool"));
        return emit(st, ys("    xor %eax, %eax"));
    } else if (ys_eq_lit(yr_get(t, "k"), "tstr")) {
        st = gen_helper1(st, ys("y_eput_hstr"));
        return emit(st, ys("    xor %eax, %eax"));
    } else {
        st = gen_helper1(st, ys("y_eput_long"));
        return emit(st, ys("    xor %eax, %eax"));
    }
}

Yv *gen_clock_us(Yv *st, Yv *node) {
    /* clock_us() -> long (monotonic microseconds, via clock_gettime). */
    Yv *unused = node;
    (void)unused;
    return emit(st, ys("    call y_clock_us"));
}

Yv *gen_heap_used(Yv *st, Yv *node) {
    /* heap_used() -> long (bytes the allocator has handed out so far). */
    Yv *unused = node;
    (void)unused;
    return emit(st, ys("    call y_heap_used"));
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
    if (fn_label_present(yr_get(st, "fns"), ys("y_prof_report"))) {
        /* --prof: exit() never returns, so the epilogue's report would
         * never run — print it here. The exit code stays in %rax. */
        st = emit(st, ys("    push %rax"));
        st = emit(st, ys("    mov %r13, %rax"));
        st = emit(st, ys("    push %rax"));
        st = emit(st, ys("    call y_prof_report"));
        st = emit(st, ys("    add $8, %rsp"));
        st = emit(st, ys("    pop %rax"));
        ;
    } else {
        ;
    }
    st = emit(st, ys("    mov %rax, %rdi"));
    st = emit(st, ys("    mov $60, %rax"));
    st = emit(st, ys("    syscall"));
    /* exit() terminates the process; the epilogue (ret / exit(0)) is
     * unreachable. Emit a jump to the function end so the backend never
     * falls through into dead code (and exit codes are never masked). */
    return emit(st, ys_cat(ys("    jmp "), yr_get(st, "end_label")));
}

/* ── process I/O + files (argv, read_file, write_file) ───────────────
 * argv MAY only appear as `main(argv())`'s argument feed: ycc.y's entry is
 * `let result = main(argv())`. The _start prologue (below) builds the argv
 * array and stashes it in r15; gen_argv emits the call that materializes
 * it. read_file(path): openat+read loop into a heap string; none (0) on
 * error, else a some()-style heap box holding the string header (options
 * are 0-or-box per NATIVE.md, so unwrap() derefs uniformly).
 * write_file(path, content): openat(O_WRONLY|O_CREAT|O_TRUNC, 0644)+write;
 * returns bool. Both are straight-line syscalls, no libc. */

Yv *gen_argv(Yv *st, Yv *node) {
    (void)node; /* native.y has no statement here; the node is unread */
    return emit(st, ys("    call y_argv"));
}

Yv *gen_read_file(Yv *st, Yv *node) {
    st = gen_push_args(st, yr_get(node, "args"));
    st = emit(st, ys("    call y_read_file"));
    return emit(st, ys("    add $8, %rsp"));
}

Yv *gen_write_file(Yv *st, Yv *node) {
    st = gen_push_args(st, yr_get(node, "args"));
    st = emit(st, ys("    call y_write_file"));
    return emit(st, ys("    add $16, %rsp"));
}

Yv *gen_write_bytes(Yv *st, Yv *node) {
    st = gen_push_args(st, yr_get(node, "args"));
    st = emit(st, ys("    call y_write_bytes"));
    return emit(st, ys("    add $24, %rsp"));
}

Yv *gen_store(Yv *st, Yv *node) {
    st = gen(st, yr_get(node, "p"));
    st = emit(st, ys("    push %rax"));
    st = gen(st, yr_get(node, "v"));
    st = emit(st, ys("    pop %rcx"));
    return emit(st, ys("    mov %rax, (%rcx)"));
}

/* ── functions ──────────────────────────────────────────────────────────
 * Frame: locals at rbp-8, rbp-16, ...; params at rbp+16, rbp+24, ....
 * Every emitted function gets: prologue, body, end_label, epilogue. */

Yv *emit_one_fn(Yv *st, Yv *label, long fuid, Yv *func, int is_main,
                int want_argv, Yv *captypes, Yv *selfname) {
    /* fresh per-function state; uid/rodata/fns flow through and back.
     * The scope is pre-loaded with every known def (like the checker's
     * fresh_func_scope): bodies see all hoisted functions and globals. */
    Yv *f = yr(11, "out", yav(0), "rodata", yr_get(st, "rodata"), "uid",
               yr_get(st, "uid"), "fuid", yv_long(fuid), "loc", yv_long(1),
               "env", yav(0), "slots", yv_long(0), "self_label", label,
               "end_label", arch_loc_label(fuid, 0), "fns", yr_get(st, "fns"),
               "bodies", yr_get(st, "bodies"));
    Yv *fnsall = yr_get(st, "fns");
    long g = 0;
    while (g < yv_len(fnsall)) {
        Yv *fe = ya_get(fnsall, g);
        f = env_define(f, yr_get(fe, "name"), fns_kind(yr_get(fe, "label")), 0,
                       yr_get(fe, "label"), yr_get(fe, "typ"));
        g = g + 1;
    }
    /* The names nested functions capture (see box_names / box_bound). */
    f = env_define(f, ys(""), ys("frame"), 0, ys(""), yr(1, "k", ys("tnone")));
    Yv *bnames = box_names(func);
    long bi = 0;
    while (bi < yv_len(bnames)) {
        Yv *bnm = ya_get(bnames, bi);
        f = env_define(f, ys(""), ys("boxmark"), 0, bnm, yr(1, "k", ys("tnone")));
        bi = bi + 1;
    }
    /* A capturing named function is not in that table (see
     * capturing_defs): bind its own name to this body, so a call by name
     * passes the record along (gen_direct) and a value is the record. */
    if (!ys_eq_lit(selfname, "")) {
        f = env_define(f, selfname, ys("func"), 0, label,
                       func_type_in(st, func));
        ;
    } else {
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
                       16 + (nargs - 1 - i) * 8, ys(""), ya_get(ptypes, i));
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
        Yv *excl = fn_names_of(yr_get(st, "fns"));
        if (!ys_eq_lit(selfname, "")) {
            excl = ya_push(excl, selfname);
            ;
        } else {
            ;
        }
        Yv *mycaps = fn_captures(func, excl);
        long cloff = 16 + nargs * 8;
        long c = 0;
        while (c < yv_len(mycaps)) {
            Yv *cn = ya_get(mycaps, c);
            /* Capture types come from the creation site (the enclosing env
             * knows them); without one the emitter would pick long for a
             * captured string in print/puts and in `+`. */
            Yv *ct = yr(1, "k", ys("tnone"));
            if (c < yv_len(captypes)) {
                ct = ya_get(captypes, c);
                ;
            } else {
                ;
            }
            f = env_define(f, cn, ys("capture"), cloff, ys_long(c), ct);
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
    } else {
        ;
    }
    long pbi = 0;
    while (pbi < nargs) {
        Yv *pbn = ya_get(params, pbi);
        f = box_bound(f, pbn);
        pbi = pbi + 1;
    }
    /* ── profiling (ycc --prof) ───────────────────────────────────────
     * Wrap the body with y_prof_enter/y_prof_exit. The stats table lives
     * in %r13 (callee-saved; generated code never touches it) and _start
     * allocates it. The function's own label is the row name. The
     * profiler's own functions are exempt: their calls run the
     * instrumentation itself (std/prof.y guards the rest).
     * (Computed before the body: tail-call recycling stays off under
     * --prof so every enter keeps its matching exit.) */
    int prof_on = fn_label_present(yr_get(st, "fns"), ys("y_prof_enter"));
    if (prof_on) {
        if (ys_eq_lit(ys_substr(label, 0, 7), "y_prof_")) {
            prof_on = 0;
            ;
        } else {
            ;
        }
        ;
    } else {
        ;
    }
    if (prof_on) {
        f = gen_block(f, yr_get(func, "body"));
    } else {
        f = gen_tail(f, yr_get(func, "body"));
    }
    long frame = arch_frame(yv_l(yr_get(f, "slots")));
    Yv *pname = ys("");
    Yv *prodata = yr_get(f, "rodata");
    long puid = yv_l(yr_get(f, "uid"));
    if (prof_on) {
        Yv *ru = next_uid(f);
        f = yr_get(ru, "st");
        Yv *nlbl = arch_str_label(yv_l(yr_get(ru, "uid")));
        Yv *ne = yav(0);
        ne = ya_push(ne, nlbl);
        ne = ya_push(ne, ys_long(yv_len(label)));
        ne = ya_push(ne, esc_asm(label));
        prodata = ya_push(yr_get(f, "rodata"), ne);
        pname = nlbl;
        puid = yv_l(yr_get(f, "uid"));
        ;
    } else {
        ;
    }
    Yv *code = yav(0);
    code = ya_push(code, ys_cat(label, ys(":")));
    if (is_main) {
        if (prof_on) {
            /* the table first: every later call (argv init included) is
             * measured against it */
            code = ya_push(code, ys_cat(ys_cat(ys("    mov $"),
                                               ys_long(puid + 8)),
                                        ys(", %rax")));
            code = ya_push(code, ys("    push %rax"));
            code = ya_push(code, ys("    call y_prof_init"));
            code = ya_push(code, ys("    add $8, %rsp"));
            code = ya_push(code, ys("    mov %rax, %r13"));
            ;
        } else {
            ;
        }
        if (want_argv) {
            /* _start prologue: at process entry %rsp -> [argc][argv0ptr]....
             * argv (char**) is the ADDRESS rsp+8 (lea, not a load!); argc
             * is [rsp]. y_argv_init copies every arg into a header string
             * and stashes the [str] array in r15 for y_argv. Skipped
             * entirely when the program never calls argv() (saves ~14s of
             * startup: y_cstr_to_str walks every byte of every arg).
             * NOTE: no bare (%rsp)/(%r12) — the encoder rejects rsp/r12
             * bases. */
            code = ya_push(code, ys("    mov %rsp, %rax"));
            code = ya_push(code, ys("    mov (%rax), %r15"));
            code = ya_push(code, ys("    mov %rax, %r14"));
            code = ya_push(code, ys("    add $8, %r14"));
            code = ya_push(code, ys("    push %r14"));
            code = ya_push(code, ys("    push %r15"));
            code = ya_push(code, ys("    call y_argv_init"));
            code = ya_push(code, ys("    add $16, %rsp"));
            ;
        } else {
            ;
        }
        ;
    } else {
        ;
    }
    code = ya_push(code, ys("    push %rbp"));
    code = ya_push(code, ys("    mov %rsp, %rbp"));
    if (frame > 0) {
        code = ya_push(code, ys_cat(ys_cat(ys("    sub $"), ys_long(frame)),
                                    ys(", %rsp")));
        ;
    } else {
        ;
    }
    if (prof_on) {
        /* y_prof_enter(table, slot, name) — args left to right, like any
         * Y call; slot is the function's uid (unique per body). */
        code = ya_push(code, ys("    mov %r13, %rax"));
        code = ya_push(code, ys("    push %rax"));
        code = ya_push(code, ys_cat(ys_cat(ys("    mov $"), ys_long(fuid)),
                                    ys(", %rax")));
        code = ya_push(code, ys("    push %rax"));
        code = ya_push(code, ys_cat(ys_cat(ys("    lea "), pname),
                                    ys("(%rip), %rax")));
        code = ya_push(code, ys("    push %rax"));
        code = ya_push(code, ys("    call y_prof_enter"));
        code = ya_push(code, ys("    add $24, %rsp"));
        ;
    } else {
        ;
    }
    Yv *fout = yr_get(f, "out");
    long j = 0;
    while (j < yv_len(fout)) {
        code = ya_push(code, ya_get(fout, j));
        j = j + 1;
    }
    code = ya_push(code, ys_cat(yr_get(f, "end_label"), ys(":")));
    if (prof_on) {
        /* every `return` funnels through end_label, so one exit hook sees
         * them all. _start gets the report instead (which books anything
         * still in flight); the epilogue below must still find the return
         * value in %rax, hence the push/pop around the call. */
        if (is_main) {
            code = ya_push(code, ys("    mov %r13, %rax"));
            code = ya_push(code, ys("    push %rax"));
            code = ya_push(code, ys("    call y_prof_report"));
            code = ya_push(code, ys("    add $8, %rsp"));
            ;
        } else {
            code = ya_push(code, ys("    push %rax"));
            code = ya_push(code, ys("    mov %r13, %rax"));
            code = ya_push(code, ys("    push %rax"));
            code = ya_push(code, ys("    call y_prof_exit"));
            code = ya_push(code, ys("    add $8, %rsp"));
            code = ya_push(code, ys("    pop %rax"));
            ;
        }
        ;
    } else {
        ;
    }
    if (is_main) {
        code = ya_push(code, ys("    mov $60, %rax"));
        code = ya_push(code, ys("    xor %edi, %edi"));
        code = ya_push(code, ys("    syscall"));
    } else {
        code = ya_push(code, ys("    mov %rbp, %rsp"));
        code = ya_push(code, ys("    pop %rbp"));
        code = ya_push(code, ys("    ret"));
    }
    /* NOTE: append to f.bodies, NOT st.bodies. Emitting this body can add
     * bodies of its own (a nested capturing def is emitted at its creation
     * site), and those land in f.bodies. Using st.bodies dropped them
     * whenever push had to GROW the array: the C copy's value model shares
     * the grown buffer between the two record copies, the native backend
     * rebinds only f.bodies (see NATIVE.md "rebind: a = push(a, v)"), so the
     * two compilers disagreed and ycc emitted calls to labels it never
     * defined. */
    Yv *bodies =
        ya_push(yr_get(f, "bodies"), ys_join(code, ys("\n")));
    return yr(11, "out", yr_get(st, "out"), "rodata", prodata, "uid",
              yv_long(puid), "fuid", yr_get(st, "fuid"), "loc",
              yr_get(st, "loc"), "env", yr_get(st, "env"), "slots",
              yr_get(st, "slots"), "self_label", yr_get(st, "self_label"),
              "end_label", yr_get(st, "end_label"), "fns", yr_get(st, "fns"),
              "bodies", bodies);
}

/* Build a tfunc type from a func node (params have annotations — checked).
 * Return type of a function whose `-> T` was omitted: the type of its
 * body's tail, inferred in a scope holding every known def plus the
 * params. types.y does the same for checking; the emitter needs it too,
 * because a call's result type decides e.g. whether `+` must stringify. */
Yv *infer_fn_ret(Yv *st, Yv *func) {
    Yv *f = yr(11, "out", yav(0), "rodata", yr_get(st, "rodata"), "uid",
               yr_get(st, "uid"), "fuid", yv_long(0), "loc", yv_long(1),
               "env", yav(0), "slots", yv_long(0), "self_label", ys(""),
               "end_label", ys(""), "fns", yr_get(st, "fns"), "bodies",
               yr_get(st, "bodies"));
    Yv *fnsall = yr_get(st, "fns");
    long g = 0;
    while (g < yv_len(fnsall)) {
        Yv *fe = ya_get(fnsall, g);
        f = env_define(f, yr_get(fe, "name"), fns_kind(yr_get(fe, "label")), 0,
                       yr_get(fe, "label"), yr_get(fe, "typ"));
        g = g + 1;
    }
    Yv *params = yr_get(func, "params");
    Yv *ptypes = yr_get(func, "ptypes");
    long n = yv_len(params);
    long i = 0;
    while (i < n) {
        f = env_define(f, ya_get(params, i), ys("param"),
                       16 + (n - 1 - i) * 8, ys(""), ya_get(ptypes, i));
        i = i + 1;
    }
    return infer(f, yr_get(func, "body"));
}

Yv *func_type(Yv *func) {
    return yr(3, "k", ys("tfunc"), "args", yr_get(func, "ptypes"), "ret",
              yr_get(func, "ret"));
}

/* Same, but with an unannotated return type resolved from the body — the
 * checker infers it too, so a literal's call sites must agree (whether `+`
 * stringifies, which print arm runs, ...). */
Yv *func_type_in(Yv *st, Yv *func) {
    Yv *r = yr_get(func, "ret");
    if (ys_eq_lit(yr_get(r, "k"), "tnone")) {
        r = infer_fn_ret(st, func);
        ;
    } else {
        ;
    }
    return yr(3, "k", ys("tfunc"), "args", yr_get(func, "ptypes"), "ret", r);
}

/* Display name: strip rename's `$N` suffix (see types.y disp). */
Yv *ndisp(Yv *name) {
    long i = ys_index_of(name, ys("$"));
    if (i < 0) {
        return name;
    } else {
        return ys_substr(name, 0, i);
    }
}

/* Two spliced modules may define the same name: shadowing would silently
 * pick one, so duplicates are a loud error (at the second def's
 * position). */
Yv *find_dup(Yv *defs) {
    Yv *seen = yav(0);
    long i = 0;
    Yv *out = yr(2, "found", yv_bool(0), "err",
                 yr(3, "msg", ys(""), "line", yv_long(1), "col", yv_long(1)));
    while (i < yv_len(defs)) {
        Yv *d = ya_get(defs, i);
        long j = 0;
        while (j < yv_len(seen)) {
            /* NOTE: :str binding (see teq note in types.y): seen elements
             * infer tunk (pushed into bare []), so compare via annotated
             * let to force content (not pointer) comparison. */
            Yv *sn = ya_get(seen, j);
            if (ys_eq(sn, yr_get(d, "name"))) {
                out = yr(2, "found", yv_bool(1), "err",
                         yr(3, "msg",
                            ys_cat(ys_cat(ys("duplicate definition '"),
                                          ndisp(yr_get(d, "name"))),
                                   ys("' (native imports splice; rename one)")),
                            "line",
                            yv_long(yv_l(yr_get(yr_get(d, "func"), "line"))),
                            "col",
                            yv_long(yv_l(yr_get(yr_get(d, "func"), "col")))));
                ;
            } else {
                ;
            }
            j = j + 1;
        }
        seen = ya_push(seen, yr_get(d, "name"));
        i = i + 1;
    }
    return out;
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
        if (ys_eq_lit(yr_get(s, "k"), "decl")) {
            if (ys_eq_lit(yr_get(s, "kind"), "def")) {
                ;
            } else if (ys_eq_lit(yr_get(yr_get(s, "v"), "k"), "func")) {
                ;
            } else {
                out = ya_push(out, s);
                ;
            }
            ;
        } else {
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
 * the declaration). */
Yv *global_entries(Yv *st, Yv *gdecls) {
    Yv *f = yr(11, "out", yav(0), "rodata", yr_get(st, "rodata"), "uid",
               yr_get(st, "uid"), "fuid", yv_long(0), "loc", yv_long(1),
               "env", yav(0), "slots", yv_long(0), "self_label", ys(""),
               "end_label", ys(""), "fns", yr_get(st, "fns"), "bodies",
               yr_get(st, "bodies"));
    Yv *fnsall = yr_get(st, "fns");
    long g = 0;
    while (g < yv_len(fnsall)) {
        Yv *fe = ya_get(fnsall, g);
        f = env_define(f, yr_get(fe, "name"),
                       fns_kind(yr_get(fe, "label")), 0,
                       yr_get(fe, "label"), yr_get(fe, "typ"));
        g = g + 1;
    }
    Yv *out = yav(0);
    long i = 0;
    while (i < yv_len(gdecls)) {
        Yv *d = ya_get(gdecls, i);
        Yv *gn = decl_name(d);
        Yv *t = decl_type(d);
        if (ys_eq_lit(yr_get(t, "k"), "tnone")) {
            t = infer(f, decl_value(d));
            ;
        } else {
            ;
        }
        Yv *lbl = arch_global_label(i, gn);
        out = ya_push(out, yr(3, "name", gn, "label", lbl, "typ", t));
        f = env_define(f, gn, ys("global"), 0, lbl, t);
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
    i = 0;
    while (i < yv_len(defs)) {
        Yv *d = ya_get(defs, i);
        Yv *excl = yav(0);
        long g = 0;
        while (g < yv_len(gnames)) {
            excl = ya_push(excl, ya_get(gnames, g));
            g = g + 1;
        }
        excl = ya_push(excl, yr_get(d, "name"));
        Yv *cs = fn_captures(yr_get(d, "func"), excl);
        caps = ya_push(caps, cs);
        long j = 0;
        int reads_var = 0;
        while (j < yv_len(cs)) {
            Yv *cn = ya_get(cs, j);
            if (name_in(fnames, cn)) {
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
        } else {
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
                    } else {
                        ;
                    }
                    j = j + 1;
                }
                if (hit) {
                    out = ya_push(out, yr_get(d, "name"));
                    changed = 1;
                    ;
                } else {
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
    Yv *ftab = yr_get(st, "fns");
    long fx = 0;
    while (fx < yv_len(hdefs)) {
        Yv *d = ya_get(hdefs, fx);
        Yv *fe0 = ya_get(ftab, fx);
        int redo = ret_omitted(yr_get(d, "func"));
        if (redo && yv_len(only) > 0) {
            redo = reads_any(yr_get(d, "func"), only);
            ;
        } else {
            ;
        }
        if (redo) {
            out = ya_push(
                out,
                yr(3, "name", yr_get(fe0, "name"), "label",
                   yr_get(fe0, "label"), "typ",
                   yr(3, "k", ys("tfunc"),
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
    return ys_eq_lit(yr_get(yr_get(func, "ret"), "k"), "tnone");
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
        } else {
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

/* ── entry point ──────────────────────────────────────────────────────── */

Yv *emit_program(Yv *ast, Yv *imports) {
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
    Yv *ast3 = rename_program(ast2);
    pr = phase_end(times, ys("rename"), pt, ph);
    times = yr_get(pr, "times");
    pt = yv_l(yr_get(pr, "t"));
    ph = yv_l(yr_get(pr, "h"));
    Yv *errors = check_program(ast3);
    pr = phase_end(times, ys("typecheck"), pt, ph);
    times = yr_get(pr, "times");
    pt = yv_l(yr_get(pr, "t"));
    ph = yv_l(yr_get(pr, "h"));
    /* collect every named def (top-level, nested, let-bound) */
    Yv *defs = collect_from_block(yr_get(ast3, "stmts"), yav(0));
    Yv *dup = find_dup(defs);
    if (yv_b(yr_get(dup, "found"))) {
        errors = ya_push(errors, yr_get(dup, "err"));
        ;
    } else {
        ;
    }
    if (yv_len(errors) > 0) {
        return yr(4, "ok", yv_bool(0), "asm", ys(""), "errors", errors, "times",
                  times);
    } else {
        Yv *gdecls = global_decls(yr_get(ast3, "stmts"));
        Yv *gnames = yav(0);
        long gi = 0;
        while (gi < yv_len(gdecls)) {
            gnames = ya_push(gnames, decl_name(ya_get(gdecls, gi)));
            gi = gi + 1;
        }
        /* A def needing a closure record is emitted where it is created
         * (gen_decl); every other one is hoisted: a label in st.fns. */
        Yv *capdefs = capturing_defs(defs, gnames);
        Yv *hdefs = yav(0);
        /* assign labels + env entries (also pre-binds for calls) */
        Yv *st = st_new();
        Yv *r = next_uid(st);
        st = yr_get(r, "st");
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
                Yv *fns = ya_push(
                    yr_get(st, "fns"),
                    yr(3, "name", yr_get(d, "name"), "label", label,
                       "typ", func_type(yr_get(d, "func"))));
                st = yr(11, "out", yr_get(st, "out"), "rodata",
                        yr_get(st, "rodata"), "uid", yr_get(st, "uid"),
                        "fuid", yr_get(st, "fuid"), "loc", yr_get(st, "loc"),
                        "env", yr_get(st, "env"), "slots", yr_get(st, "slots"),
                        "self_label", yr_get(st, "self_label"), "end_label",
                        yr_get(st, "end_label"), "fns", fns, "bodies",
                        yr_get(st, "bodies"));
                st = env_define(st, yr_get(d, "name"), ys("func"), 0, label,
                                func_type(yr_get(d, "func")));
                ;
            }
            i = i + 1;
        }
        /* Fill in return types of unannotated defs, then type the globals
         * with those, and redo defs that read a global (they now know its
         * type). The globals sit after the defs in st.fns (see fns_kind). */
        Yv *fixed1 = fix_fn_types(st, hdefs, yav(0));
        st = yr(11, "out", yr_get(st, "out"), "rodata", yr_get(st, "rodata"),
                "uid", yr_get(st, "uid"), "fuid", yr_get(st, "fuid"), "loc",
                yr_get(st, "loc"), "env", yr_get(st, "env"), "slots",
                yr_get(st, "slots"), "self_label", yr_get(st, "self_label"),
                "end_label", yr_get(st, "end_label"), "fns", fixed1,
                "bodies", yr_get(st, "bodies"));
        Yv *gl = global_entries(st, gdecls);
        Yv *fixedfns = yav(0);
        long fi = 0;
        while (fi < yv_len(fixed1)) {
            fixedfns = ya_push(fixedfns, ya_get(fixed1, fi));
            fi = fi + 1;
        }
        fi = 0;
        while (fi < yv_len(gl)) {
            fixedfns = ya_push(fixedfns, ya_get(gl, fi));
            fi = fi + 1;
        }
        if (yv_len(gl) > 0) {
            st = yr(11, "out", yr_get(st, "out"), "rodata",
                    yr_get(st, "rodata"), "uid", yr_get(st, "uid"), "fuid",
                    yr_get(st, "fuid"), "loc", yr_get(st, "loc"), "env",
                    yr_get(st, "env"), "slots", yr_get(st, "slots"),
                    "self_label", yr_get(st, "self_label"), "end_label",
                    yr_get(st, "end_label"), "fns", fixedfns, "bodies",
                    yr_get(st, "bodies"));
            Yv *fixed2 = fix_fn_types(st, hdefs, gnames);
            fixedfns = yav(0);
            fi = 0;
            while (fi < yv_len(fixed2)) {
                fixedfns = ya_push(fixedfns, ya_get(fixed2, fi));
                fi = fi + 1;
            }
            fi = 0;
            while (fi < yv_len(gl)) {
                fixedfns = ya_push(fixedfns, ya_get(gl, fi));
                fi = fi + 1;
            }
            ;
        } else {
            ;
        }
        st = yr(11, "out", yr_get(st, "out"), "rodata", yr_get(st, "rodata"),
                "uid", yr_get(st, "uid"), "fuid", yr_get(st, "fuid"), "loc",
                yr_get(st, "loc"), "env", yr_get(st, "env"), "slots",
                yr_get(st, "slots"), "self_label", yr_get(st, "self_label"),
                "end_label", yr_get(st, "end_label"), "fns", fixedfns,
                "bodies", yr_get(st, "bodies"));
        /* emit each hoisted body */
        i = 0;
        while (i < yv_len(hdefs)) {
            Yv *d = ya_get(hdefs, i);
            Yv *fns = yr_get(st, "fns");
            Yv *f = ya_get(fns, i);
            Yv *rf = next_uid(st);
            st = yr_get(rf, "st");
            st = emit_one_fn(st, yr_get(f, "label"),
                             yv_l(yr_get(rf, "uid")), yr_get(d, "func"), 0, 0,
                             yav(0), ys(""));
            i = i + 1;
        }
        pr = phase_end(times, ys("emit_fns"), pt, ph);
        times = yr_get(pr, "times");
        pt = yv_l(yr_get(pr, "t"));
        ph = yv_l(yr_get(pr, "h"));
        /* main = program with hoisted defs skipped (emitted above, calls go
         * direct to their labels). Variable declarations store to their
         * globals (bind_decl). A def needing a record would be created
         * here like a nested one — but a top-level def can only read
         * globals and functions, so none does. */
        Yv *main_stmts = yav(0);
        Yv *pstmts = yr_get(ast3, "stmts");
        i = 0; /* the Y source re-lets `i` here; same value, same scope */
        while (i < yv_len(pstmts)) {
            Yv *s = ya_get(pstmts, i);
            if (ys_eq_lit(yr_get(s, "k"), "decl")) {
                if (ys_eq_lit(yr_get(s, "kind"), "def")) {
                    if (name_in(capdefs, yr_get(s, "name"))) {
                        main_stmts = ya_push(main_stmts, s);
                        ;
                    } else {
                        ;
                    }
                    ;
                } else if (ys_eq_lit(yr_get(yr_get(s, "v"), "k"), "func")) {
                    if (name_in(capdefs, yr_get(s, "name"))) {
                        main_stmts = ya_push(main_stmts, s);
                        ;
                    } else {
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
        /* Only pay for argv materialization when the program uses it. */
        Yv *want = uses_scan_block(yr_get(ast3, "stmts"),
                                   yr(1, "argv", yv_bool(0)));
        st = emit_one_fn(
            st, ys("_start"), yv_l(yr_get(rm, "uid")),
            yr(4, "params", yav(0), "ptypes", yav(0), "ret",
               yr(1, "k", ys("tvoid")), "body",
               yr(2, "k", ys("block"), "stmts", main_stmts)),
            1, yv_b(yr_get(want, "argv")), yav(0), ys(""));
        pr = phase_end(times, ys("emit_start"), pt, ph);
        times = yr_get(pr, "times");
        pt = yv_l(yr_get(pr, "t"));
        ph = yv_l(yr_get(pr, "h"));
        /* assemble the file. Body-level tree shaking comes first: its
         * output is also the root set for shaking the arch prelude, and
         * the kept prelude's references shake the rodata constants. */
        Yv *allbodies = yr_get(st, "bodies");
        Yv *shaken = prune_bodies(allbodies, arch_prelude());
        Yv *bodies = yr_get(shaken, "bodies");
        Yv *body_refs = yr_get(shaken, "refs");
        /* Piece-list + single join: `asm = asm + piece` per iteration is
         * quadratic (each concat re-copies the whole 1.4MB+ accumulator —
         * the arena never frees), which OOMs on self-compilation. */
        Yv *pieces = yav(0);
        long b = 0;
        while (b < yv_len(bodies)) {
            pieces = ya_push(pieces, ya_get(bodies, b));
            pieces = ya_push(pieces, ys("\n"));
            b = b + 1;
        }
        Yv *body_text = ys_join(pieces, ys(""));
        /* `asm` is a C keyword (GNU basic asm) — the Y local is renamed
         * `asm_` here; it is a local name, not part of the API. */
        Yv *asm_ = arch_header();
        Yv *prelude_text = shake_refs(arch_prelude(), body_refs);
        asm_ = ys_cat(ys_cat(asm_, arch_text()), prelude_text);
        asm_ = ys_cat(asm_, body_text);
        Yv *const_refs = text_refs(prelude_text, 1);
        long ci = 0;
        while (ci < yv_len(body_refs)) {
            const_refs = ya_push(const_refs, ya_get(body_refs, ci));
            ci = ci + 1;
        }
        Yv *consts_text = shake_refs(arch_consts(), const_refs);
        asm_ = ys_cat(ys_cat(asm_, arch_rodata()), consts_text);
        Yv *allrod = yr_get(st, "rodata");
        long s2 = 0;
        Yv *rodpieces = yav(0);
        while (s2 < yv_len(allrod)) {
            Yv *pair = ya_get(allrod, s2);
            /* String entries are exactly [label, len, escaped]; shape
             * tables (see gen_reclit note) are longer and all-strings. */
            if (yv_len(pair) == 3) {
                rodpieces = ya_push(
                    rodpieces,
                    ys_cat(ys_cat(ys_cat(ys_cat(ys_cat(ya_get(pair, 0),
                                                       ys(":\n.quad ")),
                                               ys_tostring(ya_get(pair, 1))),
                                        ys("\n.string \"")),
                                 ya_get(pair, 2)),
                           ys("\"\n")));
                ;
            } else {
                rodpieces = ya_push(rodpieces,
                                    ys_cat(ya_get(pair, 0), ys(":\n")));
                long q = 2;
                while (q < yv_len(pair)) {
                    rodpieces = ya_push(rodpieces,
                                        ys_cat(ys_cat(ys(".quad "),
                                                      ya_get(pair, q)),
                                               ys("\n")));
                    q = q + 1;
                }
                ;
            }
            s2 = s2 + 1;
        }
        asm_ = ys_cat(asm_, ys_join(rodpieces, ys("")));
        /* .bss: the allocator's cells when the kept prelude still uses
           them, then one cell per global. */
        Yv *heap_text = shake_refs(arch_heap_cells(), const_refs);
        if (yv_len(gl) > 0 || yv_len(heap_text) > 0) {
            Yv *gpieces = yav(0);
            gpieces = ya_push(gpieces, arch_bss());
            gpieces = ya_push(gpieces, heap_text);
            long gk = 0;
            while (gk < yv_len(gl)) {
                Yv *ge = ya_get(gl, gk);
                gpieces = ya_push(gpieces,
                                  arch_global_cell(yr_get(ge, "label")));
                gk = gk + 1;
            }
            asm_ = ys_cat(asm_, ys_join(gpieces, ys("")));
            ;
        } else {
            ;
        }
        pr = phase_end(times, ys("asm_text"), pt, ph);
        times = yr_get(pr, "times");
        pt = yv_l(yr_get(pr, "t"));
        ph = yv_l(yr_get(pr, "h"));
        return yr(4, "ok", yv_bool(1), "asm", asm_, "errors", errors, "times",
                  times);
    }
}

/* ── maps: dynamic {K => V} ────────────────────────────────────────────
 * A map value is a two-field record -- {keys: [K], vals: [V]} -- and
 * every map operation lowers to synthetic AST over those arrays (the
 * emitter knows the static key and value types for comparison and
 * formatting), so maps need no runtime assembly of their own. Reads are
 * always optional: a hit boxes the value (some(v)), a miss leaves none. */

Yv *n_str(Yv *v, long line, long col) {
    return yr(4, "k", ys("str"), "v", v, "line", yv_long(line), "col", yv_long(col));
}

Yv *n_bool(Yv *v, long line, long col) {
    return yr(4, "k", ys("bool"), "v", v, "line", yv_long(line), "col", yv_long(col));
}

Yv *n_dot(Yv *obj, Yv *key, long line, long col) {
    return yr(5, "k", ys("dot"), "obj", obj, "key", key, "line", yv_long(line), "col", yv_long(col));
}

Yv *n_idx(Yv *arr, Yv *idx, long line, long col) {
    return yr(5, "k", ys("index"), "arr", arr, "idx", idx, "line", yv_long(line), "col", yv_long(col));
}

Yv *n_bin(Yv *op, Yv *l, Yv *r, long line, long col) {
    return yr(6, "k", ys("bin"), "op", op, "l", l, "r", r, "line", yv_long(line), "col", yv_long(col));
}

Yv *n_not(Yv *e, long line, long col) {
    return yr(5, "k", ys("un"), "op", ys("!"), "e", e, "line", yv_long(line), "col", yv_long(col));
}

Yv *n_if(Yv *c, Yv *t, Yv *e, long ln, long cl) {
    return yr(7, "k", ys("if"), "cond", c, "then", t, "els", e, "has_else", yv_bool(1), "line", yv_long(ln), "col", yv_long(cl));
}

Yv *n_while(Yv *c, Yv *b, long ln, long cl) {
    return yr(5, "k", ys("while"), "cond", c, "body", b, "line", yv_long(ln), "col", yv_long(cl));
}

Yv *n_decl(Yv *name, Yv *v, long ln, long cl) {
    return yr(7, "k", ys("decl"), "kind", ys("let"), "typ", yr(1, "k", ys("tnone")), "name", name, "v", v, "line", yv_long(ln), "col", yv_long(cl));
}

Yv *n_assign(Yv *name, Yv *v, long ln, long cl) {
    return yr(5, "k", ys("assign"), "name", name, "v", v, "line", yv_long(ln), "col", yv_long(cl));
}

Yv *block_of(Yv *sts, long ln, long cl) {
    return yr(4, "k", ys("block"), "stmts", sts, "line", yv_long(ln), "col", yv_long(cl));
}

/* {"a": 1, "a": 2}: duplicate keys collapse at emit time -- the last
 * entry wins the value, the first appearance keeps the position (the
 * record spread rule). The result is the {keys, vals} record literal. */
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
            } else {
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
    long ki = 0;
    while (ki < yv_len(keys)) {
        Yv *ks = ya_get(keys, ki);
        knodes = ya_push(knodes, n_str(ks, ln, cl));
        ki = ki + 1;
    }
    Yv *keysarr = yr(4, "k", ys("array"), "elems", knodes, "line", yv_long(ln), "col", yv_long(cl));
    Yv *valsarr = yr(4, "k", ys("array"), "elems", vals, "line", yv_long(ln), "col", yv_long(cl));
    Yv *rkeys = yav(0);
    rkeys = ya_push(rkeys, ys("keys"));
    rkeys = ya_push(rkeys, ys("vals"));
    Yv *rvals = yav(0);
    rvals = ya_push(rvals, keysarr);
    rvals = ya_push(rvals, valsarr);
    return gen(st, yr(5, "k", ys("rec"), "keys", rkeys, "vals", rvals, "line", yv_long(ln), "col", yv_long(cl)));
}

/* m[k] read: scan the keys; a hit boxes the value (some(vals[i]) -- the
 * read's V? type), a miss leaves the starting 0 (none). */
Yv *gen_map_get(Yv *st, Yv *node) {
    long ln = yv_l(yr_get(node, "line"));
    long cl = yv_l(yr_get(node, "col"));
    Yv *r = next_uid(st);
    st = yr_get(r, "st");
    Yv *t = ys_cat(ys("y_t"), ys_long(yv_l(yr_get(r, "uid"))));
    Yv *m = n_id(ys_cat(t, ys("m")), ln, cl);
    Yv *k = n_id(ys_cat(t, ys("k")), ln, cl);
    Yv *i = n_id(ys_cat(t, ys("i")), ln, cl);
    Yv *n = n_id(ys_cat(t, ys("n")), ln, cl);
    Yv *sts = yav(0);
    sts = ya_push(sts, n_decl(ys_cat(t, ys("m")), yr_get(node, "arr"), ln, cl));
    sts = ya_push(sts, n_decl(ys_cat(t, ys("k")), yr_get(node, "idx"), ln, cl));
    sts = ya_push(sts, n_decl(ys_cat(t, ys("i")), n_num(ys("0"), ln, cl), ln, cl));
    sts = ya_push(sts, n_decl(ys_cat(t, ys("n")), n_call1(ys("len"), n_dot(m, ys("keys"), ln, cl), ln, cl), ln, cl));
    sts = ya_push(sts, n_decl(ys_cat(t, ys("r")), n_num(ys("0"), ln, cl), ln, cl));
    Yv *cmp = n_bin(ys("=="), n_idx(n_dot(m, ys("keys"), ln, cl), i, ln, cl), k, ln, cl);
    Yv *hit = yav(0);
    hit = ya_push(hit, n_assign(ys_cat(t, ys("r")), n_call1(ys("some"), n_idx(n_dot(m, ys("vals"), ln, cl), i, ln, cl), ln, cl), ln, cl));
    hit = ya_push(hit, n_assign(ys_cat(t, ys("i")), n, ln, cl));
    hit = ya_push(hit, n_num(ys("0"), ln, cl));
    Yv *miss = yav(0);
    miss = ya_push(miss, n_num(ys("0"), ln, cl));
    Yv *step = n_assign(ys_cat(t, ys("i")), n_bin(ys("+"), i, n_num(ys("1"), ln, cl), ln, cl), ln, cl);
    Yv *body = yav(0);
    body = ya_push(body, n_if(cmp, block_of(hit, ln, cl), block_of(miss, ln, cl), ln, cl));
    body = ya_push(body, step);
    sts = ya_push(sts, n_while(n_bin(ys("<"), i, n, ln, cl), block_of(body, ln, cl), ln, cl));
    sts = ya_push(sts, n_id(ys_cat(t, ys("r")), ln, cl));
    return gen(st, block_of(sts, ln, cl));
}

/* m[k] = v: scan for the key; a hit overwrites vals[i], a miss appends to
 * both arrays (in place -- every alias of the map sees the write). */
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
    Yv *sts = yav(0);
    sts = ya_push(sts, n_decl(ys_cat(t, ys("m")), yr_get(node, "arr"), ln, cl));
    sts = ya_push(sts, n_decl(ys_cat(t, ys("k")), yr_get(node, "idx"), ln, cl));
    sts = ya_push(sts, n_decl(ys_cat(t, ys("v")), yr_get(node, "v"), ln, cl));
    sts = ya_push(sts, n_decl(ys_cat(t, ys("i")), n_num(ys("0"), ln, cl), ln, cl));
    sts = ya_push(sts, n_decl(ys_cat(t, ys("n")), n_call1(ys("len"), n_dot(m, ys("keys"), ln, cl), ln, cl), ln, cl));
    sts = ya_push(sts, n_decl(ys_cat(t, ys("f")), n_bool(ys("false"), ln, cl), ln, cl));
    Yv *cmp = n_bin(ys("=="), n_idx(n_dot(m, ys("keys"), ln, cl), i, ln, cl), k, ln, cl);
    Yv *hit = yav(0);
    hit = ya_push(hit, yr(6, "k", ys("idxassign"), "arr", n_dot(m, ys("vals"), ln, cl), "idx", i, "v", n_id(ys_cat(t, ys("v")), ln, cl), "line", yv_long(ln), "col", yv_long(cl)));
    hit = ya_push(hit, n_assign(ys_cat(t, ys("f")), n_bool(ys("true"), ln, cl), ln, cl));
    hit = ya_push(hit, n_assign(ys_cat(t, ys("i")), n, ln, cl));
    hit = ya_push(hit, n_num(ys("0"), ln, cl));
    Yv *miss = yav(0);
    miss = ya_push(miss, n_num(ys("0"), ln, cl));
    Yv *step = n_assign(ys_cat(t, ys("i")), n_bin(ys("+"), i, n_num(ys("1"), ln, cl), ln, cl), ln, cl);
    Yv *body = yav(0);
    body = ya_push(body, n_if(cmp, block_of(hit, ln, cl), block_of(miss, ln, cl), ln, cl));
    body = ya_push(body, step);
    sts = ya_push(sts, n_while(n_bin(ys("<"), i, n, ln, cl), block_of(body, ln, cl), ln, cl));
    Yv *grow = yav(0);
    grow = ya_push(grow, yr(6, "k", ys("opassign"), "tgt", n_dot(m, ys("keys"), ln, cl), "op", ys("+"), "v", k, "line", yv_long(ln), "col", yv_long(cl)));
    grow = ya_push(grow, yr(6, "k", ys("opassign"), "tgt", n_dot(m, ys("vals"), ln, cl), "op", ys("+"), "v", n_id(ys_cat(t, ys("v")), ln, cl), "line", yv_long(ln), "col", yv_long(cl)));
    grow = ya_push(grow, n_num(ys("0"), ln, cl));
    Yv *nogrow = yav(0);
    nogrow = ya_push(nogrow, n_num(ys("0"), ln, cl));
    sts = ya_push(sts, n_if(n_not(n_id(ys_cat(t, ys("f")), ln, cl), ln, cl), block_of(grow, ln, cl), block_of(nogrow, ln, cl), ln, cl));
    sts = ya_push(sts, n_id(ys_cat(t, ys("v")), ln, cl));
    return gen(st, block_of(sts, ln, cl));
}

/* One key's repr inside a map: string keys quote (Python-style), the
 * other hashable keys stringify bare. */
Yv *map_key_repr(Yv *node, Yv *kt, long ln, long cl) {
    if (ys_eq_lit(yr_get(kt, "k"), "tstr")) {
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