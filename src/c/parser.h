/* parser.h — 1:1 port of src/y/parser.y (token list -> AST of nested maps).
 *
 * Each parse function returns { node: <ast>, pos: <int> } as a Yv record
 * (PORTING.md type map: str -> Yv *, records/arrays -> Yv *, long -> long,
 * bool -> int). The public exports are parse_program and parse_type_full;
 * the remaining declarations expose parser helpers to the C modules.
 */
#ifndef PARSER_H
#define PARSER_H

#include "ylong.h"
#include "yv.h"

/* ── token helpers ──────────────────────────────────────────────────────── */
ylong tclamp(Yv *toks, ylong p);
Yv *tt(Yv *toks, ylong p);
Yv *tv(Yv *toks, ylong p);
ylong tline(Yv *toks, ylong p);
ylong tcol(Yv *toks, ylong p);
int is_kw(Yv *toks, ylong p, Yv *w);
int is_punct(Yv *toks, ylong p, Yv *w);
int is_op(Yv *toks, ylong p, Yv *w);
Yv *loop_push(Yv *nm);
Yv *loop_pop(void);
Yv *loop_resolve(Yv *label);
Yv *tok_desc(Yv *toks, ylong p);
Yv *expect_err(Yv *toks, ylong p, Yv *what);
Yv *close_res(Yv *toks, ylong p, Yv *closer, Yv *node);
ylong skip_close(Yv *toks, ylong p, Yv *closer);
int is_name_tok(Yv *toks, ylong p);

Yv *res(Yv *node, ylong p);
Yv *tuple_key(ylong i);
Yv *sep_by(Yv *toks, ylong p, Yv *close, Yv *one);

/* ── operator precedence ────────────────────────────────────────────────── */
ylong op_prec(Yv *op);

/* ── primary expressions ────────────────────────────────────────────────── */
Yv *parse_primary(Yv *toks, ylong p);
Yv *parse_arrow_func(Yv *toks, ylong p);
int json_sigil_at(Yv *toks, ylong p, Yv *opener);
Yv *json_callee(Yv *name, ylong ln, ylong cl);
Yv *json_call_name(Yv *name, Yv *args, ylong ln, ylong cl);
Yv *json_call0(Yv *name, ylong ln, ylong cl);
Yv *json_call1(Yv *name, Yv *arg, ylong ln, ylong cl);
Yv *json_err(Yv *msg, ylong ln, ylong cl);
Yv *parse_json_value(Yv *toks, ylong p, int top);
Yv *parse_json_object(Yv *toks, ylong p);
Yv *parse_json_array(Yv *toks, ylong p);
Yv *parse_json_primary(Yv *toks, ylong p, int top);

/* ── postfix: call, index, slice, dot ───────────────────────────────────── */
Yv *parse_postfix(Yv *toks, ylong p);
Yv *parse_args(Yv *toks, ylong p);

/* ── binary expressions (precedence climbing) ───────────────────────────── */
Yv *parse_binary(Yv *toks, ylong p, ylong min_prec);
Yv *parse_unary(Yv *toks, ylong p);
Yv *parse_expr(Yv *toks, ylong p);
Yv *parse_expr_go(Yv *toks, ylong p);

/* ── compound literals ──────────────────────────────────────────────────── */
ylong size_lit(Yv *s);
Yv *parse_array(Yv *toks, ylong p);
int brace_is_map(Yv *toks, ylong p);
Yv *parse_map(Yv *toks, ylong p);
Yv *maplit_node(int is_map, Yv *keys, Yv *vals, ylong ln, ylong cl);

/* ── type parsing ───────────────────────────────────────────────────────── */
Yv *parse_type_node(Yv *toks, ylong p);
Yv *parse_type_node_go(Yv *toks, ylong p);
Yv *parse_type_array(Yv *toks, ylong p);
Yv *parse_type_params(Yv *toks, ylong p);
Yv *map_key_type(Yv *name);
Yv *parse_type_record(Yv *toks, ylong p);
Yv *parse_type_atom2(Yv *toks, ylong p);
Yv *terr_at(Yv *toks, ylong p, Yv *what);
Yv *tclose_res(Yv *toks, ylong p, Yv *closer, Yv *tnode);
Yv *type_err(Yv *t);
Yv *type_err_then(Yv *first, Yv *t);
Yv *type_err_list(Yv *ts);
Yv *type_err_fields(Yv *fs);
Yv *parse_type_tail(Yv *toks, ylong apos, Yv *anode);
Yv *parse_type_arrow(Yv *toks, ylong apos, Yv *anode);
Yv *parse_type_plain(Yv *toks, ylong apos, Yv *anode);
Yv *parse_type_tparams(Yv *toks, ylong apos, Yv *tlist);
ylong parse_type_atom(Yv *toks, ylong p);
ylong parse_type(Yv *toks, ylong p);

/* ── function literal ───────────────────────────────────────────────────── */
Yv *parse_func(Yv *toks, ylong p, int isnat);

/* ── block { stmt; stmt; ... } ──────────────────────────────────────────── */
Yv *parse_block(Yv *toks, ylong p);
Yv *parse_block_go(Yv *toks, ylong p);
ylong stmt_end(Yv *toks, ylong start, ylong pos, Yv *sn, Yv *stmts);

/* ── statements ─────────────────────────────────────────────────────────── */
Yv *parse_stmt(Yv *toks, ylong p);
int is_compound_assign(Yv *toks, ylong p);
Yv *parse_stmt_opassign(Yv *toks, ylong p, Yv *tgt, ylong epos);
Yv *parse_stmt_assign(Yv *toks, ylong p, Yv *tgt, ylong epos);
Yv *parse_stmt_idxassign(Yv *toks, ylong p, Yv *tgt, ylong epos);
Yv *parse_stmt_idxassign_go(Yv *toks, ylong p, Yv *itgt, ylong epos);
Yv *parse_stmt_rest(Yv *toks, ylong p, Yv *tgt, ylong epos);
Yv *parse_stmt_dotassign(Yv *toks, ylong p, Yv *tgt, ylong epos);
Yv *parse_stmt_dotassign_go(Yv *toks, ylong p, Yv *dtgt, ylong epos);
Yv *parse_stmt_simple(Yv *toks, ylong p, Yv *tgt, ylong epos);
Yv *parse_stmt_store(Yv *toks, ylong p, Yv *stgt, ylong epos);
Yv *parse_stmt_plainassign(Yv *toks, ylong p, Yv *atgt, ylong epos);
Yv *parse_decl(Yv *toks, ylong p);
ylong sync_stmt(Yv *toks, ylong p);

/* ── control flow ───────────────────────────────────────────────────────── */
Yv *parse_if(Yv *toks, ylong p);
Yv *parse_while(Yv *toks, ylong p);
Yv *parse_foreach(Yv *toks, ylong p);
Yv *parse_for_or_range(Yv *toks, ylong p);
Yv *clause_err(Yv *toks, ylong pos, Yv *clause, Yv *sep);

/* ── top level: a program is a block of statements (no surrounding braces) ─ */
Yv *parse_program(Yv *toks);

/* ── new syntax: calls, ternary, unions, defaults, match ────────────────── */
Yv *mk_call(Yv *callee, Yv *args, ylong ln, ylong cl);
Yv *tostring_call(Yv *arg, ylong ln, ylong cl);
int is_id_named(Yv *node, Yv *name);
Yv *parse_ternary(Yv *toks, Yv *cond, ylong q);
Yv *block1(Yv *e, ylong ln, ylong cl);
Yv *parse_type_full(Yv *toks, ylong p);
Yv *type_word_names(void);
Yv *lit_type(Yv *node);
Yv *lit_type_neg(Yv *node);
Yv *topt_of(Yv *t);
Yv *sync_type(Yv *nm);
Yv *block_func(Yv *body, ylong ln, ylong cl);
Yv *num_lit_type(Yv *s);
int stmt_diverges(Yv *s);
int block_diverges(Yv *stmts);
int if_diverges(Yv *s);
int is_typedef_start(Yv *toks, ylong p);
Yv *parse_typedef(Yv *toks, ylong p);
Yv *parse_stmt_simple2(Yv *toks, ylong p, Yv *tgt, ylong epos);
Yv *parse_stmt_sliceassign(Yv *toks, ylong p, Yv *ltgt, ylong epos);
Yv *parse_match_try(Yv *toks, ylong p);
Yv *parse_match(Yv *toks, Yv *subj, ylong bpos, ylong ln, ylong cl);
Yv *parse_arm_body(Yv *toks, ylong p);
Yv *pat_res(Yv *test, Yv *binds, Yv *cover, int wild, ylong pos);
Yv *let_node(Yv *name, Yv *v, ylong ln, ylong cl);
Yv *parse_pattern(Yv *toks, ylong p, Yv *tmp);
Yv *parse_type_pattern(Yv *toks, ylong p, Yv *tmp);
Yv *pattern_type(Yv *nm);
Yv *parse_value_pattern(Yv *toks, Yv *node, ylong pos, Yv *tmp, ylong ln, ylong cl);

/* a name index (types.c lookup): NameIx = { keys, vals, n } */
Yv *nameix_new(ylong cap);
void nameix_put(Yv *m, Yv *k, ylong v);
ylong nameix_get(Yv *m, Yv *k);

#endif /* PARSER_H */
