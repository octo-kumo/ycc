/* rename.h — static name resolution (uniquify) for the native pipeline.
 *
 * 1:1 C twin of src/y/rename.y (see PORTING.md). rename_program(ast) -> ast'
 * where every binding has a globally unique name (`orig$N`; `$` is
 * lexer-illegal, so generated names can never collide with user code).
 * Exports exactly rename.y's top-level defs.
 *
 * Type map (PORTING.md): state { scopes: [[{ orig, uniq }]], n: long } and
 * every record/array/shape-hole/str is Yv *; line/col/i counters are long.
 * The uniform node-renamer result R = { st: state, node: {k: str} } is a
 * Yv * record too.
 */
#ifndef RENAME_H
#define RENAME_H

#include "yv.h"

/* scope state ({ scopes: [[{ orig: str, uniq: str }]], n: long }) */
Yv *rn_fresh(Yv *st, Yv *orig);
Yv *rn_push(Yv *st);
Yv *rn_pop(Yv *st);
Yv *rn_define(Yv *st, Yv *orig, Yv *uniq);
Yv *rn_lookup(Yv *st, Yv *name);
Yv *rn_lookup_to(Yv *st, Yv *name, long lo);
Yv *rn_bind(Yv *st, Yv *orig);

/* node lists and ids */
Yv *rn_list(Yv *nodes, Yv *st);
Yv *rn_id(Yv *st, Yv *name, long line, long col);

/* def pre-pass and redefinition shadowing */
Yv *rn_prepass(Yv *stmts, Yv *st);
Yv *rn_prepass_one(Yv *s, Yv *st);
Yv *rn_prepass_decl(Yv *s, Yv *st);
Yv *rn_shadow_dups(Yv *stmts);
Yv *rn_later(Yv *names);
long rn_hash(Yv *s);
Yv *rn_decl_name(Yv *s);
Yv *rn_decl_name_go(Yv *s);
Yv *rn_rebuild_decl(Yv *s, Yv *newname);
Yv *rn_rebuild_def(Yv *s, Yv *newname);
Yv *rn_rebuild_let(Yv *s, Yv *newname);
Yv *rn_block(Yv *stmts, Yv *st);

/* one def per AST shape (see rn_node note in rename.c) */
Yv *rn_node(Yv *node, Yv *st);
Yv *rn_un(Yv *node, Yv *st);
Yv *rn_addrderef(Yv *node, Yv *st);
Yv *rn_bin(Yv *node, Yv *st);
Yv *rn_call(Yv *node, Yv *st);
Yv *rn_if(Yv *node, Yv *st);
Yv *rn_if_then(Yv *node, Yv *cond, Yv *st);
Yv *rn_if_finish(Yv *node, Yv *cond, Yv *tstmts, Yv *st);
Yv *rn_while(Yv *node, Yv *st);
Yv *rn_while_body(Yv *node, Yv *cond, Yv *st);
Yv *rn_blocknode(Yv *node, Yv *st);
Yv *rn_assign(Yv *node, Yv *st);
Yv *rn_assign_lookup(Yv *node, Yv *v, Yv *st);
Yv *rn_assign_finish(Yv *node, Yv *v, Yv *u, Yv *st);
Yv *rn_incdec(Yv *node, Yv *st);
Yv *rn_opassign(Yv *node, Yv *st);
Yv *rn_store(Yv *node, Yv *st);
Yv *rn_store_val(Yv *node, Yv *p, Yv *st);
Yv *rn_ret(Yv *node, Yv *st);
Yv *rn_array(Yv *node, Yv *st);
Yv *rn_arrrep(Yv *node, Yv *st);
Yv *rn_reclit(Yv *node, Yv *st);
Yv *rn_maplit(Yv *node, Yv *st);
Yv *rn_index(Yv *node, Yv *st);
Yv *rn_index_idx(Yv *node, Yv *a, Yv *st);
Yv *rn_slice(Yv *node, Yv *st);
Yv *rn_slice_lo(Yv *node, Yv *a, Yv *st);
Yv *rn_slice_hi(Yv *node, Yv *a, Yv *lo, Yv *st);
Yv *rn_dot(Yv *node, Yv *st);
Yv *rn_qualified(Yv *st, Yv *obj, Yv *key);
int rn_in(Yv *xs, Yv *x);
Yv *rn_idxassign(Yv *node, Yv *st);
Yv *rn_idxassign_idx(Yv *node, Yv *a, Yv *st);
Yv *rn_idxassign_val(Yv *node, Yv *a, Yv *idx, Yv *st);
Yv *rn_dotassign(Yv *node, Yv *st);
Yv *rn_dotassign_val(Yv *node, Yv *o, Yv *st);
Yv *rn_foreach(Yv *node, Yv *st);
Yv *rn_foreach_body(Yv *node, Yv *iter, Yv *st);
Yv *rn_foreach_block(Yv *node, Yv *iter, Yv *uniq, Yv *st);
Yv *rn_forrange(Yv *node, Yv *st);
Yv *rn_forrange_hi(Yv *node, Yv *lo, Yv *st);
Yv *rn_forrange_body(Yv *node, Yv *lo, Yv *hi, Yv *st);
Yv *rn_forrange_block(Yv *node, Yv *lo, Yv *hi, Yv *uniq, Yv *st);
Yv *rn_for(Yv *node, Yv *st);
Yv *rn_for_cond(Yv *node, Yv *init, Yv *st);
Yv *rn_for_step(Yv *node, Yv *init, Yv *cond, Yv *st);
Yv *rn_for_body(Yv *node, Yv *init, Yv *cond, Yv *step, Yv *st);
Yv *rn_decl(Yv *node, Yv *st);
Yv *rn_decl_def(Yv *node, Yv *st);
Yv *rn_decl_def_lookup(Yv *node, Yv *u, Yv *st);
Yv *rn_decl_def_go(Yv *node, Yv *u, Yv *st);
Yv *rn_decl_rest(Yv *node, Yv *st);
Yv *rn_decl_func(Yv *node, Yv *st);
Yv *rn_decl_func_lookup(Yv *node, Yv *u, Yv *st);
Yv *rn_decl_func_go(Yv *node, Yv *u, Yv *st);
Yv *rn_decl_func_finish(Yv *node, Yv *u, Yv *fv, Yv *st);
Yv *rn_decl_val(Yv *node, Yv *st);
Yv *rn_decl_val_bind(Yv *node, Yv *v, Yv *st);
Yv *rn_decl_val_finish(Yv *node, Yv *v, Yv *uniq, Yv *st);

/* func values: params/ptypes/ret/body threaded as fields (see rn_func note) */
Yv *rn_func(Yv *func, Yv *st);
Yv *rn_func_p1(Yv *func, Yv *fparams, Yv *st);
Yv *rn_func_p2(Yv *func, Yv *fparams, Yv *fptypes, Yv *st);
Yv *rn_func_p3(Yv *func, Yv *fparams, Yv *fptypes, Yv *fret, Yv *st);
Yv *rn_func_p4(Yv *func, Yv *fparams, Yv *fptypes, Yv *fret, Yv *fbody,
               Yv *st);
Yv *rn_func_p5(Yv *fparams, Yv *fptypes, Yv *fret, Yv *fbody, long fline,
               long fcol, Yv *st);
Yv *rn_func_params(Yv *fparams, Yv *fptypes, Yv *fret, Yv *fbody, long fline,
                   long fcol, Yv *st);
Yv *rn_func_go(Yv *fparams, Yv *fptypes, Yv *fret, Yv *fbody, long fline,
               long fcol, Yv *params, long i, Yv *st);
Yv *rn_func_body(Yv *fptypes, Yv *fret, Yv *fbody, long fline, long fcol,
                 Yv *params, Yv *st);
Yv *rn_func_finish(Yv *fptypes, Yv *fret, Yv *fbody, long fline, long fcol,
                   Yv *params, Yv *stmts, Yv *st);

/* the module entry points (rename.y: export { rename_program,
 * rename_program_x }) */
Yv *rename_program(Yv *ast);
Yv *rename_program_x(Yv *ast, Yv *dfl, Yv *ofile, Yv *fmods);
Yv *rn_stmt_mod(Yv *s);
Yv *rn_qualify(Yv *s);
Yv *rn_top(Yv *stmts, Yv *st);
Yv *rename_program_go(Yv *stmts, long line, long col, Yv *dfl);

/* defaults, type aliases, match / slice-assign nodes */
Yv *rn_note_defaults(Yv *st, Yv *uniq, Yv *func);
Yv *rn_find_defaults(Yv *st, Yv *name);
Yv *rn_fill_defaults(Yv *vals, Yv *args, long line, long col);
int rn_is_optarg(Yv *d);
Yv *rn_type(Yv *st, Yv *t);
Yv *rn_types(Yv *st, Yv *ts);
Yv *rn_type_go(Yv *st, Yv *t, long depth);
Yv *rn_type_name(Yv *st, Yv *name, Yv *t, long depth);
long rn_alias_index(Yv *st, Yv *name);
long rn_alias_index_go(Yv *st, Yv *name);
Yv *rn_qual_type(Yv *t, Yv *m);
Yv *rn_qual_list(Yv *ts, Yv *m);
Yv *rn_tref(Yv *st, long id, Yv *name);
int rn_reaches(Yv *st, long id, int bare);
int rn_reaches_any(Yv *st, long id);
int rn_reaches_go(Yv *st, Yv *t, long id, Yv *seen, int bare);
Yv *rn_type_list(Yv *st, Yv *ts, long depth);
Yv *rn_type_fields(Yv *st, Yv *fs, long depth);
Yv *rn_union_flat(Yv *ts);
Yv *rn_typedef_err(Yv *s, Yv *st);
Yv *rn_unknown_err(Yv *name, long line, long col);
Yv *rn_unknown_type(Yv *st, Yv *t);
Yv *rn_alias_known(Yv *st, Yv *name);
Yv *rn_unknown_then(Yv *first, Yv *st, Yv *t);
Yv *rn_unknown_list(Yv *st, Yv *ts);
Yv *rn_unknown_fields(Yv *st, Yv *fs);
Yv *rn_drop_typedefs(Yv *stmts, Yv *st);
Yv *rn_typed_e(Yv *node, Yv *st);
Yv *rn_matchend(Yv *node, Yv *st);
Yv *rn_sliceassign(Yv *node, Yv *st);

#endif /* RENAME_H */
