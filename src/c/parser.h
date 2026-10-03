/* parser.h — 1:1 port of src/y/parser.y (token list -> AST of nested maps).
 *
 * Each parse function returns { node: <ast>, pos: <int> } as a Yv record
 * (PORTING.md type map: str -> Yv *, records/arrays -> Yv *, long -> long,
 * bool -> int). The public exports are parse_program and parse_type_full;
 * the remaining declarations expose parser helpers to the C modules.
 */
#ifndef PARSER_H
#define PARSER_H

#include "yv.h"

/* ── token helpers ──────────────────────────────────────────────────────── */
long tclamp(Yv *toks, long p);
Yv *tt(Yv *toks, long p);
Yv *tv(Yv *toks, long p);
long tline(Yv *toks, long p);
long tcol(Yv *toks, long p);
int is_kw(Yv *toks, long p, Yv *w);
int is_punct(Yv *toks, long p, Yv *w);
int is_op(Yv *toks, long p, Yv *w);
Yv *tok_desc(Yv *toks, long p);
Yv *expect_err(Yv *toks, long p, Yv *what);
Yv *close_res(Yv *toks, long p, Yv *closer, Yv *node);
long skip_close(Yv *toks, long p, Yv *closer);
int is_name_tok(Yv *toks, long p);

Yv *res(Yv *node, long p);
Yv *sep_by(Yv *toks, long p, Yv *close, Yv *one);

/* ── operator precedence ────────────────────────────────────────────────── */
long op_prec(Yv *op);

/* ── primary expressions ────────────────────────────────────────────────── */
Yv *parse_primary(Yv *toks, long p);

/* ── postfix: call, index, slice, dot ───────────────────────────────────── */
Yv *parse_postfix(Yv *toks, long p);
Yv *parse_args(Yv *toks, long p);

/* ── binary expressions (precedence climbing) ───────────────────────────── */
Yv *parse_binary(Yv *toks, long p, long min_prec);
Yv *parse_unary(Yv *toks, long p);
Yv *parse_expr(Yv *toks, long p);

/* ── compound literals ──────────────────────────────────────────────────── */
long size_lit(Yv *s);
Yv *parse_array(Yv *toks, long p);
int brace_is_map(Yv *toks, long p);
Yv *parse_map(Yv *toks, long p);
Yv *maplit_node(int is_map, Yv *keys, Yv *vals, long ln, long cl);

/* ── type parsing ───────────────────────────────────────────────────────── */
Yv *parse_type_node(Yv *toks, long p);
Yv *parse_type_array(Yv *toks, long p);
Yv *parse_type_params(Yv *toks, long p);
Yv *map_key_type(Yv *name);
Yv *parse_type_record(Yv *toks, long p);
Yv *parse_type_atom2(Yv *toks, long p);
Yv *terr_at(Yv *toks, long p, Yv *what);
Yv *tclose_res(Yv *toks, long p, Yv *closer, Yv *tnode);
Yv *type_err(Yv *t);
Yv *type_err_then(Yv *first, Yv *t);
Yv *type_err_list(Yv *ts);
Yv *type_err_fields(Yv *fs);
Yv *parse_type_tail(Yv *toks, long apos, Yv *anode);
Yv *parse_type_arrow(Yv *toks, long apos, Yv *anode);
Yv *parse_type_plain(Yv *toks, long apos, Yv *anode);
Yv *parse_type_tparams(Yv *toks, long apos, Yv *tlist);
long parse_type_atom(Yv *toks, long p);
long parse_type(Yv *toks, long p);

/* ── function literal ───────────────────────────────────────────────────── */
Yv *parse_func(Yv *toks, long p);

/* ── block { stmt; stmt; ... } ──────────────────────────────────────────── */
Yv *parse_block(Yv *toks, long p);
long stmt_end(Yv *toks, long start, long pos, Yv *sn, Yv *stmts);

/* ── statements ─────────────────────────────────────────────────────────── */
Yv *parse_stmt(Yv *toks, long p);
int is_compound_assign(Yv *toks, long p);
Yv *parse_stmt_opassign(Yv *toks, long p, Yv *tgt, long epos);
Yv *parse_stmt_assign(Yv *toks, long p, Yv *tgt, long epos);
Yv *parse_stmt_idxassign(Yv *toks, long p, Yv *tgt, long epos);
Yv *parse_stmt_idxassign_go(Yv *toks, long p, Yv *itgt, long epos);
Yv *parse_stmt_rest(Yv *toks, long p, Yv *tgt, long epos);
Yv *parse_stmt_dotassign(Yv *toks, long p, Yv *tgt, long epos);
Yv *parse_stmt_dotassign_go(Yv *toks, long p, Yv *dtgt, long epos);
Yv *parse_stmt_simple(Yv *toks, long p, Yv *tgt, long epos);
Yv *parse_stmt_store(Yv *toks, long p, Yv *stgt, long epos);
Yv *parse_stmt_plainassign(Yv *toks, long p, Yv *atgt, long epos);
Yv *parse_decl(Yv *toks, long p);
long sync_stmt(Yv *toks, long p);

/* ── control flow ───────────────────────────────────────────────────────── */
Yv *parse_if(Yv *toks, long p);
Yv *parse_while(Yv *toks, long p);
Yv *parse_foreach(Yv *toks, long p);
Yv *parse_for_or_range(Yv *toks, long p);
Yv *clause_err(Yv *toks, long pos, Yv *clause, Yv *sep);

/* ── top level: a program is a block of statements (no surrounding braces) ─ */
Yv *parse_program(Yv *toks);

/* ── new syntax: calls, ternary, unions, defaults, match ────────────────── */
Yv *mk_call(Yv *callee, Yv *args, long ln, long cl);
Yv *tostring_call(Yv *arg, long ln, long cl);
int is_id_named(Yv *node, Yv *name);
Yv *parse_ternary(Yv *toks, Yv *cond, long q);
Yv *block1(Yv *e, long ln, long cl);
Yv *parse_type_full(Yv *toks, long p);
Yv *lit_type(Yv *node);
Yv *lit_type_neg(Yv *node);
Yv *topt_of(Yv *t);
Yv *num_lit_type(Yv *s);
int stmt_diverges(Yv *s);
int block_diverges(Yv *stmts);
int if_diverges(Yv *s);
int is_typedef_start(Yv *toks, long p);
Yv *parse_typedef(Yv *toks, long p);
Yv *parse_stmt_simple2(Yv *toks, long p, Yv *tgt, long epos);
Yv *parse_stmt_sliceassign(Yv *toks, long p, Yv *ltgt, long epos);
Yv *parse_match_try(Yv *toks, long p);
Yv *parse_match(Yv *toks, Yv *subj, long bpos, long ln, long cl);
Yv *parse_arm_body(Yv *toks, long p);
Yv *pat_res(Yv *test, Yv *binds, Yv *cover, int wild, long pos);
Yv *let_node(Yv *name, Yv *v, long ln, long cl);
Yv *parse_pattern(Yv *toks, long p, Yv *tmp);
Yv *parse_type_pattern(Yv *toks, long p, Yv *tmp);
Yv *parse_value_pattern(Yv *toks, Yv *node, long pos, Yv *tmp, long ln, long cl);

#endif /* PARSER_H */
