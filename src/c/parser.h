/* parser.h — 1:1 port of src/y/parser.y (token list -> AST of nested maps).
 *
 * Each parse function returns { node: <ast>, pos: <int> } as a Yv record
 * (PORTING.md type map: str -> Yv *, records/arrays -> Yv *, long -> long,
 * bool -> int). This header exports exactly the top-level defs of parser.y.
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
Yv *parse_array(Yv *toks, long p);
int brace_is_map(Yv *toks, long p);
Yv *parse_map(Yv *toks, long p);

/* ── type parsing ───────────────────────────────────────────────────────── */
Yv *parse_type_node(Yv *toks, long p);
Yv *parse_type_array(Yv *toks, long p);
Yv *parse_type_params(Yv *toks, long p);
Yv *parse_type_record(Yv *toks, long p);
Yv *parse_type_atom2(Yv *toks, long p);
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

/* ── control flow ───────────────────────────────────────────────────────── */
Yv *parse_if(Yv *toks, long p);
Yv *parse_while(Yv *toks, long p);
Yv *parse_foreach(Yv *toks, long p);
Yv *parse_for_or_range(Yv *toks, long p);

/* ── top level: a program is a block of statements (no surrounding braces) ─ */
Yv *parse_program(Yv *toks);

#endif /* PARSER_H */
