// parser.c — 1:1 port of src/y/parser.y.
// parse a token list into an AST of nested maps.
// Each parse function returns { node: <ast>, pos: <int> }.
// AST node kinds: num, str, id, bool, void (an absent expression), bin,
//   un, call, index, slice,
//   dot, assign, idxassign, decl, func, if, while, for, foreach, forrange,
//   block, array, rec, map, ret. Postfix `x!` is sugar for unwrap(x).
//
// PORTING.md type map: toks is [Yv] (array of {t,v,line,col} token records),
// result records are Yv *, long -> long, bool -> int, str -> Yv *.
#include "parser.h"
#include "tags.h"

/* imported: lexer.y, for its alias Tok only (a record is a Yv * here);
 * otherwise only yv.h builtins: len -> yv_len, push -> ya_push, slicing
 * -> ys_slice, ord -> ys_ord. */

// ── token helpers ────────────────────────────────────────────────────────

long tclamp(Yv *toks, long p) {
    // The C VM wraps out-of-bounds indices modulo count (vm.c), so peeking
    // past EOF silently read toks[0] there. The native backend traps
    // instead — clamp every peek to the trailing "eof" token (lexer always
    // appends one) so both toolchains agree.
    long n = yv_len(toks);
    long q = p;
    if (q >= n) {
        q = n - 1;
        ;
    } else {
        ;
    }
    return q;
}

Yv *tt(Yv *toks, long p) {
    // NOTE: NEVER inline `toks[p].t` (dot-then-index): the Y parser.c
    // misparses `x.y[i]` as `x.(y[i])` (AGENTS.md) — always bind first,
    // then read.
    Yv *tok = ya_get(toks, tclamp(toks, p));
    return yr_get(tok, "t");
}
Yv *tv(Yv *toks, long p) {
    // NOTE: bound once (see tt note): `toks[p].v` inline would misparse.
    Yv *tok = ya_get(toks, tclamp(toks, p));
    return yr_get(tok, "v");
}
long tline(Yv *toks, long p) {
    // NOTE: bound once (see tt note).
    Yv *tok = ya_get(toks, tclamp(toks, p));
    return yv_l(yr_get(tok, "line"));
}
long tcol(Yv *toks, long p) {
    // NOTE: bound once (see tt note).
    Yv *tok = ya_get(toks, tclamp(toks, p));
    return yv_l(yr_get(tok, "col"));
}

int is_kw(Yv *toks, long p, Yv *w) {
    // NOTE: no `&&` — the C VM evaluates both sides eagerly AND the native
    // checker rejects `&&` mixing map-field shapes with bools (see lexer.y
    // isalnum note). Nested ifs keep both toolchains quiet.
    // NOTE: bound once — `toks[p].t` inline misparses (see tt note).
    Yv *tok = ya_get(toks, tclamp(toks, p));
    if (ys_eq_lit(yr_get(tok, "t"), "kw")) {
        if (ys_eq(yr_get(tok, "v"), w)) {
            return 1;
        } else {
            return 0;
        }
    } else {
        return 0;
    }
}
int is_punct(Yv *toks, long p, Yv *w) {
    // NOTE: bound once (see tt note).
    Yv *tok = ya_get(toks, tclamp(toks, p));
    if (ys_eq_lit(yr_get(tok, "t"), "punct")) {
        if (ys_eq(yr_get(tok, "v"), w)) {
            return 1;
        } else {
            return 0;
        }
    } else {
        return 0;
    }
}
int is_op(Yv *toks, long p, Yv *w) {
    // NOTE: bound once (see tt note).
    Yv *tok = ya_get(toks, tclamp(toks, p));
    if (ys_eq_lit(yr_get(tok, "t"), "op")) {
        if (ys_eq(yr_get(tok, "v"), w)) {
            return 1;
        } else {
            return 0;
        }
    } else {
        return 0;
    }
}

Yv *res(Yv *node, long p) {
    return yr(2, "node", node, "pos", yv_long(p));
}

Yv *tres(Yv *node, long p) {
    return yr(2, "node", node, "pos", yv_long(p));
}

Yv *tok_desc(Yv *toks, long p) {
    if (ys_eq_lit(tt(toks, p), "eof")) {
        return ys("end of input");
    } else {
        return ys_cat(ys_cat(ys("'"), tv(toks, p)), ys("'"));
    }
}

Yv *expect_err(Yv *toks, long p, Yv *what) {
    Yv *msg = ys_cat(ys_cat(ys("expected "), what),
                     ys_cat(ys(", got "), tok_desc(toks, p)));
    return yr(4, "k", yv_long(K_err), "msg", msg, "line", yv_long(tline(toks, p)),
              "col", yv_long(tcol(toks, p)));
}

Yv *close_res(Yv *toks, long p, Yv *closer, Yv *node) {
    if (is_punct(toks, p, closer)) {
        return res(node, p + 1);
    } else {
        Yv *what = ys_cat(ys_cat(ys("'"), closer), ys("'"));
        return res(expect_err(toks, p, what), p);
    }
}

long skip_close(Yv *toks, long p, Yv *closer) {
    if (is_punct(toks, p, closer)) {
        return p + 1;
    } else {
        return p;
    }
}

int is_name_tok(Yv *toks, long p) {
    if (ys_eq_lit(tt(toks, p), "id")) {
        return 1;
    } else {
        return ys_eq_lit(tt(toks, p), "kw");
    }
}

// sep_by(one, close): parse a comma-separated list of `one(toks, pos)` results
// (each returning { node, pos }) until the `close` punct. Handles trailing
// commas. Returns { node: [nodes], pos } with pos AT the close punct (caller
// skips it). Replaces 6 copy-pasted comma-list loops.
// `one` is a production NAME ("expr" only, for now) — Y has no first-class
// functions in native mode, so callers name the production and sep_by
// dispatches (a defunctionalized stub: extend the if-chain for more).
// NOTE: toks is the token list [{ t, v, line, col }]; param typed tarr of
// trec so the checker accepts plain token-list arguments (e03 parity: real
// missing element types still error at the empty-array use sites).
Yv *sep_by(Yv *toks, long p, Yv *close, Yv *one) {
    Yv *xs = yav(0);
    long pos = p;
    // NOTE: statement-form (not `let go = !(...)`): the `un` arm types
    // through the operand, and a call-shaped operand confuses inference.
    int go = 1;
    if (is_punct(toks, pos, close)) {
        go = 0;
        ;
    } else {
        ;
    }
    while (go) {
        // NOTE: bound once — `one(toks, pos)` inline misparses on the C VM.
        // NOTE: `0;` tails — the while body must be void-typed (see note).
        Yv *r = yr(2, "node", yr(3, "k", yv_long(K_void), "line",
                                 yv_long(tline(toks, pos)), "col",
                                 yv_long(tcol(toks, pos))),
                   "pos", yv_long(pos));
        if (ys_eq_lit(one, "expr")) {
            r = parse_expr(toks, pos);
            ;
        } else {
            ;
        }
        // NOTE: each bound once — `x.y` on a call result misparses on the
        // C backend (it reads `f().y` as `f(.y)`).
        Yv *rnode = yr_get(r, "node");
        long rpos = yv_l(yr_get(r, "pos"));
        xs = ya_push(xs, rnode);
        pos = rpos;
        if (is_punct(toks, pos, ys(","))) {
            pos = pos + 1;
            if (is_punct(toks, pos, close)) {
                go = 0;
                ;
            } else {
                ;
            }
            ;
        } else {
            // Neither a separator nor the closer: the token stream is
            // malformed. parser.y has no error channel, so plant a node the
            // checker rejects — dropping the leftovers silently compiled
            // `print(1 zzz)` into `print(1)`.
            if (is_punct(toks, pos, close)) {
                ;
            } else {
                xs = ya_push(xs, yr(4, "k", yv_long(K_err),
                                          "msg", ys_cat(ys_cat(ys_cat(ys_cat(ys("unexpected "), tok_desc(toks, pos)), ys(" (expected ',' or '")), close), ys("')")),
                                          "line", yv_long(tline(toks, pos)),
                                          "col", yv_long(tcol(toks, pos))));
                ;
            }
            go = 0;
            ;
        }
    }
    return yr(2, "node", xs, "pos", yv_long(pos));
}

// ── operator precedence ──────────────────────────────────────────────────

// The bitwise operators bind tighter than the comparisons (unlike C, where
// `a & m == 0` is `a & (m == 0)`): `|` < `^` < `&` < the shifts < `+ -`.
long op_prec(Yv *op) {
    if (ys_eq_lit(op, "||")) {
        return 1;
    } else if (ys_eq_lit(op, "&&")) {
        return 2;
    } else if (ys_eq_lit(op, "==")) {
        return 3;
    } else if (ys_eq_lit(op, "!=")) {
        return 3;
    } else if (ys_eq_lit(op, "<")) {
        return 4;
    } else if (ys_eq_lit(op, ">")) {
        return 4;
    } else if (ys_eq_lit(op, "<=")) {
        return 4;
    } else if (ys_eq_lit(op, ">=")) {
        return 4;
    } else if (ys_eq_lit(op, "::")) {
        return 5;
    } else if (ys_eq_lit(op, "|")) {
        return 6;
    } else if (ys_eq_lit(op, "^")) {
        return 7;
    } else if (ys_eq_lit(op, "&")) {
        return 8;
    } else if (ys_eq_lit(op, "<<")) {
        return 9;
    } else if (ys_eq_lit(op, ">>")) {
        return 9;
    } else if (ys_eq_lit(op, ">>>")) {
        return 9;
    } else if (ys_eq_lit(op, "+")) {
        return 10;
    } else if (ys_eq_lit(op, "-")) {
        return 10;
    } else if (ys_eq_lit(op, "*")) {
        return 11;
    } else if (ys_eq_lit(op, "/")) {
        return 11;
    } else if (ys_eq_lit(op, "%")) {
        return 11;
    } else {
        return 0;
    }
}

// ── primary expressions ──────────────────────────────────────────────────

Yv *parse_primary(Yv *toks, long p) {
    Yv *t = tt(toks, p);
    Yv *v = tv(toks, p);
    long ln = tline(toks, p);
    long cl = tcol(toks, p);
    if (ys_eq_lit(t, "num")) {
        return res(yr(4, "k", yv_long(K_num), "v", v, "line", yv_long(ln), "col", yv_long(cl)), p + 1);
    } else if (ys_eq_lit(t, "str")) {
        return res(yr(4, "k", yv_long(K_str), "v", v, "line", yv_long(ln), "col", yv_long(cl)), p + 1);
    } else if (ys_eq_lit(t, "bstr")) {
        // b"..." / b'...' -- a [byte] literal
        return res(yr(4, "k", yv_long(K_bstr), "v", v, "line", yv_long(ln), "col", yv_long(cl)), p + 1);
    } else if (ys_eq_lit(t, "char")) {
        // c'a' -- one byte, typed `byte`; v holds its code in decimal
        if (yv_len(v) == 1) {
            return res(yr(4, "k", yv_long(K_char), "v", ys_long(ys_ord(v)), "line", yv_long(ln), "col", yv_long(cl)), p + 1);
        } else {
            return res(yr(4, "k", yv_long(K_err), "msg", ys_cat(ys("character literal must be exactly one byte, got "), ys_long(yv_len(v))), "line", yv_long(ln), "col", yv_long(cl)), p + 1);
        }
    } else if (ys_eq_lit(t, "ferr")) {
        /* a malformed literal (a broken f-string, `0x` without digits):
         * the lexer's message, where it found the fault */
        return res(yr(4, "k", yv_long(K_err), "msg", v, "line", yv_long(ln), "col", yv_long(cl)), p + 1);
    } else if (ys_eq_lit(t, "id")) {
        if (ys_eq_lit(v, "match")) {
            return parse_match_try(toks, p);
        } else if ((ys_eq_lit(v, "spawn") || ys_eq_lit(v, "fork")) && is_punct(toks, p + 1, ys("{"))) {
            /* `spawn { ... }`, `fork { ... }`: the builtin on a function of
             * the block (CHOICES_MADE.md 33) */
            Yv *b = parse_block(toks, p + 1);
            Yv *args = yav(1, block_func(yr_get(b, "node"), ln, cl));
            return res(yr(5, "k", yv_long(K_call), "callee", yr(4, "k", yv_long(K_id), "v", v, "line", yv_long(ln), "col", yv_long(cl)),
                          "args", args, "line", yv_long(ln), "col", yv_long(cl)),
                       yv_l(yr_get(b, "pos")));
        } else if ((ys_eq_lit(v, "lock") || ys_eq_lit(v, "try_lock")) && ys_eq_lit(tt(toks, p + 1), "id")) {
            /* `lock m { ... }`: the mutex, then the block */
            Yv *m = parse_postfix(toks, p + 1);
            Yv *args = yav(1, yr_get(m, "node"));
            long mpos = yv_l(yr_get(m, "pos"));
            Yv *callee = yr(4, "k", yv_long(K_id), "v", v, "line", yv_long(ln), "col", yv_long(cl));
            if (!is_punct(toks, mpos, ys("{"))) {
                args = ya_push(args, expect_err(toks, mpos, ys_cat(ys_cat(ys("'{' (the block "), v), ys(" runs)"))));
                return res(yr(5, "k", yv_long(K_call), "callee", callee, "args", args, "line", yv_long(ln), "col", yv_long(cl)), mpos);
            } else {
                Yv *b = parse_block(toks, mpos);
                args = ya_push(args, block_func(yr_get(b, "node"), ln, cl));
                return res(yr(5, "k", yv_long(K_call), "callee", callee, "args", args, "line", yv_long(ln), "col", yv_long(cl)),
                           yv_l(yr_get(b, "pos")));
            }
        } else if ((ys_eq_lit(v, "join") || ys_eq_lit(v, "post") || ys_eq_lit(v, "wait")) && ys_eq_lit(tt(toks, p + 1), "id")) {
            /* `join t`, `post s`, `wait s`: the builtin on the operand */
            Yv *e = parse_postfix(toks, p + 1);
            Yv *args = yav(1, yr_get(e, "node"));
            return res(yr(5, "k", yv_long(K_call), "callee", yr(4, "k", yv_long(K_id), "v", v, "line", yv_long(ln), "col", yv_long(cl)),
                          "args", args, "line", yv_long(ln), "col", yv_long(cl)),
                       yv_l(yr_get(e, "pos")));
        } else {
            return res(yr(4, "k", yv_long(K_id), "v", v, "line", yv_long(ln), "col", yv_long(cl)), p + 1);
        }
    } else if (is_kw(toks, p, ys("true"))) {
        return res(yr(4, "k", yv_long(K_bool), "v", ys("true"), "line", yv_long(ln), "col", yv_long(cl)), p + 1);
    } else if (is_kw(toks, p, ys("false"))) {
        return res(yr(4, "k", yv_long(K_bool), "v", ys("false"), "line", yv_long(ln), "col", yv_long(cl)), p + 1);
    } else if (is_punct(toks, p, ys("("))) {
        if (is_punct(toks, p + 1, ys(")"))) {
            // `()` is the void value (nothing computed)
            return res(yr(3, "k", yv_long(K_void), "line", yv_long(ln), "col",
                          yv_long(cl)), p + 2);
        } else {
            Yv *inner = parse_expr(toks, p + 1);
            return close_res(toks, yv_l(yr_get(inner, "pos")), ys(")"),
                             yr_get(inner, "node"));
        }
    } else if (is_punct(toks, p, ys("["))) {
        return parse_array(toks, p);
    } else if (is_punct(toks, p, ys("{"))) {
        if (brace_is_map(toks, p)) {
            return parse_map(toks, p);
        } else {
            return parse_block(toks, p);
        }
    } else if (is_kw(toks, p, ys("def"))) {
        return parse_func(toks, p);
    } else if (is_kw(toks, p, ys("if"))) {
        return parse_if(toks, p);
    } else if (is_kw(toks, p, ys("while"))) {
        return parse_while(toks, p);
    } else if (is_kw(toks, p, ys("for"))) {
        return parse_for_or_range(toks, p);
    } else if (is_kw(toks, p, ys("foreach"))) {
        return parse_foreach(toks, p);
    } else {
        Yv *err = expect_err(toks, p, ys("an expression"));
        if (ys_eq_lit(t, "eof") || is_punct(toks, p, ys(")")) ||
            is_punct(toks, p, ys("]")) || is_punct(toks, p, ys("}")) ||
            is_punct(toks, p, ys(",")) || is_punct(toks, p, ys(";"))) {
            return res(err, p);
        } else {
            return res(err, p + 1);
        }
    }
}

// ── postfix: call, index, slice, dot ─────────────────────────────────────

/* The types `mutex` and `sem` (types.c t_mutex, t_sem): records whose
 * fields no program can name. */
Yv *sync_type(Yv *nm) {
    Yv *fs = yav(0);
    if (ys_eq_lit(nm, "mutex")) {
        fs = ya_push(fs, yr(3, "name", ys("$m"), "opt", yv_bool(0), "typ", yr(1, "k", yv_long(K_tlong))));
    } else {
        fs = ya_push(fs, yr(3, "name", ys("$n"), "opt", yv_bool(0), "typ", yr(1, "k", yv_long(K_tlong))));
        fs = ya_push(fs, yr(3, "name", ys("$w"), "opt", yv_bool(0), "typ", yr(1, "k", yv_long(K_tlong))));
    }
    return yr(2, "k", yv_long(K_trec), "fields", fs);
}

/* A block as a function of no parameters, its return type inferred. */
Yv *block_func(Yv *body, long ln, long cl) {
    return yr(8, "k", yv_long(K_func), "params", yav(0), "ptypes", yav(0), "ret", yr(1, "k", yv_long(K_tnone)),
              "body", body, "defs", yav(0), "line", yv_long(ln), "col", yv_long(cl));
}

Yv *parse_postfix(Yv *toks, long p) {
    Yv *base = parse_primary(toks, p);
    Yv *node = yr_get(base, "node");
    long pos = yv_l(yr_get(base, "pos"));
    int go = 1;
    while (go) {
        if (is_punct(toks, pos, ys("("))) {
            Yv *a = parse_args(toks, pos + 1);
            node = mk_call(node, yr_get(a, "node"), tline(toks, pos), tcol(toks, pos));
            pos = skip_close(toks, yv_l(yr_get(a, "pos")), ys(")"));
        } else if (is_punct(toks, pos, ys("["))) {
            // index or slice: arr[i], arr[lo:hi], arr[lo:], arr[:hi], arr[:]
            long bln = tline(toks, pos);
            long bcl = tcol(toks, pos);
            if (is_punct(toks, pos + 1, ys(":"))) {
                if (is_punct(toks, pos + 2, ys("]"))) {
                    // arr[:] — full slice
                    node = yr(6, "k", yv_long(K_slice), "arr", node, "lo",
                              yr(3, "k", yv_long(K_void), "line", yv_long(bln),
                                 "col", yv_long(bcl)),
                              "hi", yr(3, "k", yv_long(K_void), "line",
                                       yv_long(bln), "col", yv_long(bcl)),
                              "line", yv_long(bln), "col", yv_long(bcl));
                    pos = pos + 3;  // skip '[', ':', ']'
                } else {
                    // arr[:hi] — no lo
                    Yv *second = parse_expr(toks, pos + 2);
                    Yv *close = close_res(
                        toks, yv_l(yr_get(second, "pos")), ys("]"),
                        yr(6, "k", yv_long(K_slice), "arr", node, "lo",
                           yr(3, "k", yv_long(K_void), "line", yv_long(bln),
                              "col", yv_long(bcl)),
                           "hi", yr_get(second, "node"),
                           "line", yv_long(bln), "col", yv_long(bcl)));
                    node = yr_get(close, "node");
                    pos = yv_l(yr_get(close, "pos"));
                }
            } else {
                Yv *first = parse_expr(toks, pos + 1);
                if (is_punct(toks, yv_l(yr_get(first, "pos")), ys(":"))) {
                    if (is_punct(toks, yv_l(yr_get(first, "pos")) + 1, ys("]"))) {
                        // arr[lo:] — no hi
                        node = yr(6, "k", yv_long(K_slice), "arr", node, "lo",
                                  yr_get(first, "node"), "hi",
                                  yr(3, "k", yv_long(K_void), "line",
                                     yv_long(bln), "col", yv_long(bcl)),
                                  "line", yv_long(bln), "col", yv_long(bcl));
                        pos = yv_l(yr_get(first, "pos")) + 2;  // skip ':' and ']'
                    } else {
                        // arr[lo:hi]
                        Yv *second = parse_expr(toks, yv_l(yr_get(first, "pos")) + 1);
                        Yv *close = close_res(
                            toks, yv_l(yr_get(second, "pos")), ys("]"),
                            yr(6, "k", yv_long(K_slice), "arr", node, "lo",
                               yr_get(first, "node"), "hi", yr_get(second, "node"),
                               "line", yv_long(bln), "col", yv_long(bcl)));
                        node = yr_get(close, "node");
                        pos = yv_l(yr_get(close, "pos"));
                    }
                } else {
                    // arr[i] — index
                    Yv *close = close_res(
                        toks, yv_l(yr_get(first, "pos")), ys("]"),
                        yr(5, "k", yv_long(K_index), "arr", node, "idx",
                           yr_get(first, "node"), "line", yv_long(bln),
                           "col", yv_long(bcl)));
                    node = yr_get(close, "node");
                    pos = yv_l(yr_get(close, "pos"));
                }
            }
            if (yv_l(yr_get(node, "k")) == K_err) {
                go = 0;
                ;
            } else {
                ;
            }
        } else if (is_op(toks, pos, ys("."))) {
            if (is_name_tok(toks, pos + 1)) {
                Yv *name = tv(toks, pos + 1);
                node = yr(5, "k", yv_long(K_dot), "obj", node, "key", name,
                          "line", yv_long(tline(toks, pos)),
                          "col", yv_long(tcol(toks, pos)));
                pos = pos + 2;
            } else {
                node = expect_err(toks, pos + 1,
                                  ys("a field name after '.'"));
                pos = pos + 1;
                go = 0;
            }
        } else if (is_op(toks, pos, ys("!"))) {
            // x! -- postfix unwrap, exactly unwrap(x) (traps on none).
            Yv *ua = yav(0);
            ua = ya_push(ua, node);
            node = yr(5, "k", yv_long(K_call), "callee", yr(4, "k", yv_long(K_id), "v", ys("unwrap"), "line", yv_long(tline(toks, pos)), "col", yv_long(tcol(toks, pos))), "args", ua, "line", yv_long(tline(toks, pos)), "col", yv_long(tcol(toks, pos)));
            pos = pos + 1;
        } else if (is_op(toks, pos, ys("++"))) {
            // x++ — postfix: the OLD value is the expression's value, and
            // the target is evaluated once (a[f()]++ calls f once).
            node = yr(6, "k", yv_long(K_incdec), "op", ys("++"), "pre", yv_bool(0), "tgt", node, "line", yv_long(tline(toks, pos)), "col", yv_long(tcol(toks, pos)));
            pos = pos + 1;
            go = 0;
            ;
        } else if (is_op(toks, pos, ys("--"))) {
            node = yr(6, "k", yv_long(K_incdec), "op", ys("--"), "pre", yv_bool(0), "tgt", node, "line", yv_long(tline(toks, pos)), "col", yv_long(tcol(toks, pos)));
            pos = pos + 1;
            go = 0;
            ;
        } else {
            go = 0;
            ;
        }
    }
    return res(node, pos);
}

Yv *parse_args(Yv *toks, long p) {
    return sep_by(toks, p, ys(")"), ys("expr"));
}

// A call node. `print(a, b, ...)` with several arguments prints them back
// to back on one line: it is print(tostring(a) + tostring(b) + ...).
Yv *mk_call(Yv *callee, Yv *args, long ln, long cl) {
    if (is_id_named(callee, ys("print")) && yv_len(args) > 1) {
        Yv *cat = tostring_call(ya_get(args, 0), ln, cl);
        long i = 1;
        while (i < yv_len(args)) {
            cat = yr(6, "k", yv_long(K_bin), "op", ys("+"), "l", cat, "r", tostring_call(ya_get(args, i), ln, cl), "line", yv_long(ln), "col", yv_long(cl));
            i = i + 1;
        }
        Yv *one = yav(0);
        one = ya_push(one, cat);
        return yr(5, "k", yv_long(K_call), "callee", callee, "args", one, "line", yv_long(ln), "col", yv_long(cl));
    } else {
        return yr(5, "k", yv_long(K_call), "callee", callee, "args", args, "line", yv_long(ln), "col", yv_long(cl));
    }
}

Yv *tostring_call(Yv *arg, long ln, long cl) {
    Yv *one = yav(0);
    one = ya_push(one, arg);
    return yr(5, "k", yv_long(K_call), "callee", yr(4, "k", yv_long(K_id), "v", ys("tostring"), "line", yv_long(ln), "col", yv_long(cl)), "args", one, "line", yv_long(ln), "col", yv_long(cl));
}

int is_id_named(Yv *node, Yv *name) {
    if (yv_l(yr_get(node, "k")) == K_id) {
        return ys_eq(yr_get(node, "v"), name);
    } else {
        return 0;
    }
}

// ── binary expressions (precedence climbing) ─────────────────────────────

Yv *parse_binary(Yv *toks, long p, long min_prec) {
    Yv *left_r = parse_unary(toks, p);
    Yv *left = yr_get(left_r, "node");
    long pos = yv_l(yr_get(left_r, "pos"));
    int go = 1;
    while (go) {
        Yv *op = tv(toks, pos);
        long prec = 0;
        if (ys_eq_lit(tt(toks, pos), "op")) {
            prec = op_prec(op);
            ;
        } else {
            ;
        }
        // NOTE: nested ifs, not `||` — the operands mix long (prec flags)
        // with bools and the checker rejects the joint gate (tcompat law:
        // only annotations unify, never branch conditions).
        // The explicit else arms end in long-valued `0`s, keeping their
        // types aligned; the terminating `;` discards the value.
        if (prec == 0) {
            go = 0;
            ;
        } else if (prec < min_prec) {
            go = 0;
            ;
        } else {
            /* `::` is right-associative: 1 :: 2 :: [3] is 1 :: (2 :: [3])
             * = [1, 2, 3]. Everything else is left-associative. */
            long next_min = prec + 1;
            if (ys_eq_lit(op, "::")) {
                next_min = prec;
                ;
            } else { ; }
            Yv *right_r = parse_binary(toks, pos + 1, next_min);
            left = yr(6, "k", yv_long(K_bin), "op", op, "l", left, "r", yr_get(right_r, "node"), "line", yv_long(tline(toks, pos)), "col", yv_long(tcol(toks, pos)));
            pos = yv_l(yr_get(right_r, "pos"));
            ;
        }
    }
    return res(left, pos);
}

Yv *parse_unary(Yv *toks, long p) {
    // NOTE: nested ifs, not `||` (see parse_binary note): bool-gated call
    // shapes poison the joint `||` gate.
    if (is_op(toks, p, ys("-"))) {
        Yv *inner = parse_unary(toks, p + 1);
        return res(yr(5, "k", yv_long(K_un), "op", tv(toks, p), "e", yr_get(inner, "node"), "line", yv_long(tline(toks, p)), "col", yv_long(tcol(toks, p))), yv_l(yr_get(inner, "pos")));
    } else if (is_op(toks, p, ys("!"))) {
        Yv *inner = parse_unary(toks, p + 1);
        return res(yr(5, "k", yv_long(K_un), "op", tv(toks, p), "e", yr_get(inner, "node"), "line", yv_long(tline(toks, p)), "col", yv_long(tcol(toks, p))), yv_l(yr_get(inner, "pos")));
    } else if (is_op(toks, p, ys("~"))) {
        // bitwise not: ~x
        Yv *inner = parse_unary(toks, p + 1);
        return res(yr(5, "k", yv_long(K_un), "op", tv(toks, p), "e", yr_get(inner, "node"), "line", yv_long(tline(toks, p)), "col", yv_long(tcol(toks, p))), yv_l(yr_get(inner, "pos")));
    } else if (is_op(toks, p, ys("&"))) {
        // address-of: &x
        Yv *inner = parse_unary(toks, p + 1);
        return res(yr(4, "k", yv_long(K_addr), "e", yr_get(inner, "node"), "line", yv_long(tline(toks, p)), "col", yv_long(tcol(toks, p))), yv_l(yr_get(inner, "pos")));
    } else if (is_op(toks, p, ys("*"))) {
        // dereference: *p
        Yv *inner = parse_unary(toks, p + 1);
        return res(yr(4, "k", yv_long(K_deref), "e", yr_get(inner, "node"), "line", yv_long(tline(toks, p)), "col", yv_long(tcol(toks, p))), yv_l(yr_get(inner, "pos")));
    } else if (is_op(toks, p, ys("++"))) {
        // ++x — prefix: the NEW value is the expression's value
        Yv *inner = parse_unary(toks, p + 1);
        return res(yr(6, "k", yv_long(K_incdec), "op", ys("++"), "pre", yv_bool(1), "tgt", yr_get(inner, "node"), "line", yv_long(tline(toks, p)), "col", yv_long(tcol(toks, p))), yv_l(yr_get(inner, "pos")));
    } else if (is_op(toks, p, ys("--"))) {
        Yv *inner = parse_unary(toks, p + 1);
        return res(yr(6, "k", yv_long(K_incdec), "op", ys("--"), "pre", yv_bool(1), "tgt", yr_get(inner, "node"), "line", yv_long(tline(toks, p)), "col", yv_long(tcol(toks, p))), yv_l(yr_get(inner, "pos")));
    } else {
        return parse_postfix(toks, p);
    }
}

Yv *parse_expr(Yv *toks, long p) {
    Yv *c = parse_binary(toks, p, 1);
    if (is_op(toks, yv_l(yr_get(c, "pos")), ys("?"))) {
        return parse_ternary(toks, yr_get(c, "node"), yv_l(yr_get(c, "pos")));
    } else {
        return c;
    }
}

// `c ? a : b` -- the lowest-precedence operator, right-associative. It IS
// `if (c) { a } else { b }`: arms that disagree make it void.
Yv *parse_ternary(Yv *toks, Yv *cond, long q) {
    long ln = tline(toks, q);
    long cl = tcol(toks, q);
    Yv *a = parse_expr(toks, q + 1);
    long apos = yv_l(yr_get(a, "pos"));
    if (is_punct(toks, apos, ys(":"))) {
        Yv *b = parse_expr(toks, apos + 1);
        return res(yr(7, "k", yv_long(K_kw_if), "cond", cond, "then", block1(yr_get(a, "node"), ln, cl), "els", block1(yr_get(b, "node"), ln, cl), "has_else", yv_bool(1), "line", yv_long(ln), "col", yv_long(cl)), yv_l(yr_get(b, "pos")));
    } else {
        return res(yr(4, "k", yv_long(K_err), "msg", ys_cat(ys_cat(ys("expected ':' in conditional expression, got '"), tv(toks, apos)), ys("'")), "line", yv_long(tline(toks, apos)), "col", yv_long(tcol(toks, apos))), apos);
    }
}

// A block holding one expression (its value).
Yv *block1(Yv *e, long ln, long cl) {
    Yv *one = yav(0);
    one = ya_push(one, e);
    return yr(4, "k", yv_long(K_block), "stmts", one, "line", yv_long(ln), "col", yv_long(cl));
}

// ── compound literals ────────────────────────────────────────────────────

// The size in `[v; n]` and `[T; n]`: a decimal or radix integer literal
// from 0 to 2147483647 (2^31 - 1). Its value, or -1 for any other num
// token (a float, a larger number).
long size_lit(Yv *s) {
    Yv *p = ys_slice(s, 0, 2);
    long radix = 10;
    long i = 0;
    if (ys_eq_lit(p, "0x") || ys_eq_lit(p, "0X")) { radix = 16; i = 2; }
    else if (ys_eq_lit(p, "0b") || ys_eq_lit(p, "0B")) { radix = 2; i = 2; }
    long v = 0;
    while (i < yv_len(s) && v >= 0) {
        long o = ys_ord(ys_slice(s, i, i + 1));
        // the digit's value: `.`, `e` (and a hex digit in a decimal) are
        // past the radix
        long d = 99;
        if (o >= 48 && o <= 57) { d = o - 48; }
        else if (o >= 97 && o <= 102) { d = o - 87; }
        else if (o >= 65 && o <= 70) { d = o - 55; }
        if (o == 95) {
            // a radix literal keeps its `_` separators
        } else if (d >= radix || v > (2147483647 - d) / radix) {
            v = -1;
        } else {
            v = v * radix + d;
        }
        i = i + 1;
    }
    return v;
}

Yv *parse_array(Yv *toks, long p) {
    // p is AT '['. Forms: [] and [a, b] (heap literals, later),
    // [v; n] (stack repeat: n copies of v — the native array form).
    long ln = tline(toks, p);
    long cl = tcol(toks, p);
    if (is_punct(toks, p + 1, ys("]"))) {
        return res(yr(4, "k", yv_long(K_array), "elems", yav(0), "line", yv_long(ln), "col", yv_long(cl)), p + 2);
    } else {
        Yv *first = parse_expr(toks, p + 1);
        long pos = yv_l(yr_get(first, "pos"));
        if (is_punct(toks, pos, ys(";"))) {
            // repeat: the size is an integer literal (size_lit); anything
            // else is parsed past and reported where it starts.
            long at = pos + 1;
            long n = -1;
            if (ys_eq_lit(tt(toks, at), "num")) { n = size_lit(tv(toks, at)); }
            if (n >= 0) {
                return close_res(
                    toks, at + 1, ys("]"),
                    yr(5, "k", yv_long(K_arrrep), "v", yr_get(first, "node"),
                       "n", yv_long(n), "line", yv_long(ln), "col", yv_long(cl)));
            } else {
                Yv *cnt = parse_expr(toks, at);
                return close_res(toks, yv_l(yr_get(cnt, "pos")), ys("]"),
                                 expect_err(toks, at, ys("an array size (an integer literal from 0 to 2147483647)")));
            }
        } else {
            // literal, with trailing-comma tolerance
            // NOTE: statement-form init (not `let go = is_punct(...)`): the
            // `un`-typed call shape confuses inference (see sep_by note).
            Yv *elems = yav(1, yr_get(first, "node"));
            int go = 1;
            if (is_punct(toks, pos, ys(","))) {
                ;
            } else {
                go = 0;
                ;
            }
            while (go) {
                pos = pos + 1;  // skip ','
                if (is_punct(toks, pos, ys("]"))) {
                    go = 0;
                    ;
                } else {
                    Yv *e = parse_expr(toks, pos);
                    elems = ya_push(elems, yr_get(e, "node"));
                    pos = yv_l(yr_get(e, "pos"));
                    go = is_punct(toks, pos, ys(","));
                    ;
                }
            }
            // Same guard as sep_by: a token that is neither ',' nor ']'
            // means the stream is malformed, and dropping it silently would
            // compile `[1, 2 zzz]` as `[1, 2]`.
            if (is_punct(toks, pos, ys("]"))) {
                ;
            } else {
                elems = ya_push(elems, yr(4, "k", yv_long(K_err),
                                          "msg", ys_cat(ys_cat(ys("unexpected "), tok_desc(toks, pos)), ys(" (expected ',' or ']')")),
                                          "line", yv_long(tline(toks, pos)),
                                          "col", yv_long(tcol(toks, pos))));
                ;
            }
            return res(yr(4, "k", yv_long(K_array), "elems", elems, "line", yv_long(ln), "col", yv_long(cl)), skip_close(toks, pos, ys("]")));
        }
    }
}

// `{` in expression position is ambiguous: a record literal (`{a: 1}`) or a
// block expression (`{ let t = 1; t + 1 }`). Only `{}`, `{key: ...}` and
// `{"key": ...}` and the shorthand `{x, ...}` are records; everything else
// (`{ x }` included) is a block.
int brace_is_map(Yv *toks, long p) {
    if (is_punct(toks, p + 1, ys("}"))) {
        return 1;
    } else {
        Yv *k = tt(toks, p + 1);
        if (ys_eq_lit(k, "id")) {
            return is_punct(toks, p + 2, ys(":")) ||
                   is_punct(toks, p + 2, ys(","));
        } else if (ys_eq_lit(k, "str")) {
            return is_punct(toks, p + 2, ys(":"));
        } else if (ys_eq_lit(k, "kw")) {
            return is_punct(toks, p + 2, ys(":"));
        } else if (ys_eq_lit(k, "num")) {
            return is_punct(toks, p + 2, ys(":"));
        } else if (is_op(toks, p + 1, ys(".."))) {
            // `...obj` (lexed as `..` + `.`) opens a record literal
            return 1;
        } else {
            return 0;
        }
    }
}

Yv *parse_map(Yv *toks, long p) {
    // p is AT '{'
    long ln = tline(toks, p);
    long cl = tcol(toks, p);
    Yv *keys = yav(0);
    Yv *vals = yav(0);
    int is_map = 0;
    long pos = p + 1;
    int bad = 0;
    if (is_punct(toks, pos, ys("}"))) {
        return res(maplit_node(is_map, keys, vals, ln, cl), pos + 1);
    } else {
        int go = 1;
        while (go) {
            // trailing comma: '}' right after ',' ends the map
            // NOTE: statement-form + `0;` tails — the while body must be
            // void-typed (see parse_binary note).
            if (is_punct(toks, pos, ys("}"))) {
                go = 0;
                ;
            } else {
                // A quoted key makes a MAP literal ({k: "map"}); identifier
                // keys stay record fields ({k: "rec"}).
                if (is_map) {
                    ;
                } else {
                    is_map = ys_eq_lit(tt(toks, pos), "str");
                    ;
                }
                // Spread `...obj` lexes as `..` + `.`; the entry is
                // recorded under the "..." key with the source record as
                // its value (the checker and emitter merge it statically).
                Yv *key = tv(toks, pos);
                Yv *kt = tt(toks, pos);
                if (ys_eq_lit(key, "..")) {
                    key = ys("...");
                    pos = pos + 2;  // the two dot tokens; there is no ':'
                    ;
                } else if (ys_eq_lit(kt, "id") || ys_eq_lit(kt, "str") ||
                           ys_eq_lit(kt, "kw") || ys_eq_lit(kt, "num")) {
                    if (is_punct(toks, pos + 1, ys(":"))) {
                        pos = pos + 2;  // skip key and ':'
                        ;
                    } else if (ys_eq_lit(kt, "id") &&
                               (is_punct(toks, pos + 1, ys(",")) ||
                                is_punct(toks, pos + 1, ys("}")))) {
                        // `{x, y}` is `{x: x, y: y}`: parse the name again
                        // below, as the value.
                        ;
                    } else {
                        keys = ya_push(keys, key);
                        vals = ya_push(
                            vals, expect_err(toks, pos + 1,
                                             ys("':' after the key")));
                        bad = 1;
                        ;
                    }
                    ;
                } else {
                    keys = ya_push(keys, key);
                    vals = ya_push(vals, expect_err(toks, pos, ys("a key")));
                    bad = 1;
                    ;
                }
                if (bad) {
                    go = 0;
                    ;
                } else {
                    Yv *e = parse_expr(toks, pos);
                    keys = ya_push(keys, key);
                    vals = ya_push(vals, yr_get(e, "node"));
                    pos = yv_l(yr_get(e, "pos"));
                    if (is_punct(toks, pos, ys(","))) {
                        pos = pos + 1;
                        ;
                    } else {
                        go = 0;
                        ;
                    }
                    ;
                }
                ;
            }
        }
        if (bad) {
            return res(maplit_node(is_map, keys, vals, ln, cl), pos);
        } else {
            return close_res(toks, pos, ys("}"),
                             maplit_node(is_map, keys, vals, ln, cl));
        }
    }
}

// `{a: 1}` is a record ({k: "rec"}), `{"a": 1}` a map ({k: "map"}).
Yv *maplit_node(int is_map, Yv *keys, Yv *vals, long ln, long cl) {
    if (is_map) { return yr(5, "k", yv_long(K_map), "keys", keys, "vals", vals, "line", yv_long(ln), "col", yv_long(cl)); }
    else { return yr(5, "k", yv_long(K_rec), "keys", keys, "vals", vals, "line", yv_long(ln), "col", yv_long(cl)); }
}

// ── type parsing ─────────────────────────────────────────────────────────
// Types are parsed into type-node maps (not just skipped): kinds tlong,
// tbool, tstr, tvoid, tname (unresolved name -> checker error), tptr {to},
// tarr {of}, tparams {ts} (parenthesized list, resolved by arrow context),
// tfunc {args, ret}, trec {fields: [{name, typ}]}, tmap {key, of},
// tnone (no annotation).
// Extra fields are ignored by the C backend, so this is additive.

Yv *parse_type_node(Yv *toks, long p) {
    // NOTE: NO `node`/`pos` locals shared across arms. Earlier this function
    // used one `node` name rebound in every arm; the checker env is
    // flow-INSENSITIVE (last shape wins), so `node.ts` in the arrow tail
    // resolved against the tfunc shape ("record has no field 'ts'") and
    // `target.arr` reads in parse_stmt resolved against rebound shapes.
    // The atom dispatches first, then ONE tail applies `?` + `->` with
    // fresh names only (parse_type_tail below).
    // (The C VM has no early return, but every arm's tail IS its res(),
    // so falling through is impossible — each arm is the last expression.)
    // NOTE: atom arms need parse_type_array/params/record/atom2 (defined
    // BELOW — forward refs are fine: defs hoist per block level in rename).
    if (is_op(toks, p, ys("*"))) {
        // pointer type: *T
        Yv *inner = parse_type_node(toks, p + 1);
        Yv *pin = yr(2, "k", yv_long(K_tptr), "to", yr_get(inner, "node"));
        return parse_type_tail(toks, yv_l(yr_get(inner, "pos")), pin);
    } else if (is_punct(toks, p, ys("["))) {
        // array type: [T] (heap, later) or [T; N] (stack repeat, native now).
        // N must be a num literal (else -1 sentinel, rejected by checker).
        return parse_type_array(toks, p);
    } else if (is_punct(toks, p, ys("("))) {
        // parenthesized / function-param list: (T, T)
        return parse_type_params(toks, p);
    } else if (is_punct(toks, p, ys("{"))) {
        // record type: { field: T, ... }
        return parse_type_record(toks, p);
    } else {
        return parse_type_atom2(toks, p);
    }
}

// [T] / [T; N] tail of parse_type_node: parses the bracketed shape, then
// the shared postfix tail (fresh names per arm — see note).
Yv *parse_type_array(Yv *toks, long p) {
    Yv *inner = parse_type_node(toks, p + 1);
    if (is_punct(toks, yv_l(yr_get(inner, "pos")), ys(";"))) {
        long np = yv_l(yr_get(inner, "pos")) + 1;
        long n = -1;
        if (ys_eq_lit(tt(toks, np), "num")) { n = size_lit(tv(toks, np)); }
        if (n >= 0) {
            Yv *fc = tclose_res(
                toks, np + 1, ys("]"),
                yr(3, "k", yv_long(K_tarrfix), "of", yr_get(inner, "node"), "n",
                   yv_long(n)));
            return parse_type_tail(toks, yv_l(yr_get(fc, "pos")),
                                   yr_get(fc, "node"));
        } else {
            return tres(terr_at(toks, np, ys("an array size (an integer literal from 0 to 2147483647)")), np);
        }
    } else {
        Yv *ac = tclose_res(
            toks, yv_l(yr_get(inner, "pos")), ys("]"),
            yr(2, "k", yv_long(K_tarr), "of", yr_get(inner, "node")));
        return parse_type_tail(toks, yv_l(yr_get(ac, "pos")),
                               yr_get(ac, "node"));
    }
}

Yv *terr_at(Yv *toks, long p, Yv *what) {
    Yv *msg = ys_cat(
        ys_cat(ys_cat(ys("expected "), what),
               ys(" in a type, got ")),
        tok_desc(toks, p));
    return yr(4, "k", yv_long(K_terr), "msg", msg, "line", yv_long(tline(toks, p)),
              "col", yv_long(tcol(toks, p)));
}

Yv *tclose_res(Yv *toks, long p, Yv *closer, Yv *tnode) {
    if (is_punct(toks, p, closer)) {
        return tres(tnode, p + 1);
    } else {
        Yv *what = ys_cat(ys_cat(ys("'"), closer), ys("'"));
        return tres(terr_at(toks, p, what), p);
    }
}

Yv *type_err(Yv *t) {
    Yv *k = yr_get(t, "k");
    if (yv_l(k) == K_terr) {
        return yr(4, "k", yv_long(K_err), "msg", yr_get(t, "msg"), "line",
                  yr_get(t, "line"), "col", yr_get(t, "col"));
    } else if (yv_l(k) == K_tptr) {
        return type_err(yr_get(t, "to"));
    } else if (yv_l(k) == K_tarr) {
        return type_err(yr_get(t, "of"));
    } else if (yv_l(k) == K_tarrfix) {
        return type_err(yr_get(t, "of"));
    } else if (yv_l(k) == K_topt) {
        return type_err(yr_get(t, "of"));
    } else if (yv_l(k) == K_tmap) {
        return type_err_then(type_err(yr_get(t, "key")), yr_get(t, "of"));
    } else if (yv_l(k) == K_trec) {
        return type_err_fields(yr_get(t, "fields"));
    } else if (yv_l(k) == K_tfunc) {
        return type_err_then(type_err_list(yr_get(t, "args")),
                             yr_get(t, "ret"));
    } else if (yv_l(k) == K_tparams) {
        return type_err_list(yr_get(t, "ts"));
    } else if (yv_l(k) == K_tunion) {
        return type_err_list(yr_get(t, "ts"));
    } else {
        return yr(3, "k", yv_long(K_void), "line", yv_long(1), "col", yv_long(1));
    }
}

Yv *type_err_then(Yv *first, Yv *t) {
    if (yv_l(yr_get(first, "k")) == K_err) {
        return first;
    } else {
        return type_err(t);
    }
}

Yv *type_err_list(Yv *ts) {
    Yv *out = yr(3, "k", yv_long(K_void), "line", yv_long(1), "col", yv_long(1));
    long i = 0;
    while (i < yv_len(ts)) {
        if (yv_l(yr_get(out, "k")) == K_void) {
            out = type_err(ya_get(ts, i));
            ;
        } else {
            ;
        }
        i = i + 1;
    }
    return out;
}

Yv *type_err_fields(Yv *fs) {
    Yv *out = yr(3, "k", yv_long(K_void), "line", yv_long(1), "col", yv_long(1));
    long i = 0;
    while (i < yv_len(fs)) {
        Yv *f = ya_get(fs, i);
        if (yv_l(yr_get(out, "k")) == K_void) {
            out = type_err(yr_get(f, "typ"));
            ;
        } else {
            ;
        }
        i = i + 1;
    }
    return out;
}

// (T, T) tail of parse_type_node + shared postfix tail (fresh names — see note).
Yv *parse_type_params(Yv *toks, long p) {
    // NOTE: statement-form loops + `0;` tails — while bodies must be
    // void-typed (see parse_binary note).
    Yv *ts = yav(0);
    long pos = p + 1;  // skip '('
    if (!is_punct(toks, pos, ys(")"))) {
        int go = 1;
        while (go) {
            if (is_punct(toks, pos, ys(")"))) {
                go = 0;
                ;
            } else {
                Yv *t = parse_type_node(toks, pos);
                ts = ya_push(ts, yr_get(t, "node"));
                pos = yv_l(yr_get(t, "pos"));
                if (is_punct(toks, pos, ys(","))) {
                    pos = pos + 1;
                    ;
                } else {
                    go = 0;
                    ;
                }
                ;
            }
        }
        ;
    } else {
        ;
    }
    if (is_punct(toks, pos, ys(")"))) {
        return parse_type_tparams(toks, pos + 1, ts);
    } else {
        return tres(terr_at(toks, pos, ys("')'")), pos);
    }
}

// The key type of a map type ({K => V}): K must be hashable (str, long,
// byte, bool, float). Anything else stays a named type for the checker
// to reject.
Yv *map_key_type(Yv *name) {
    if (ys_eq_lit(name, "str")) { return yr(1, "k", yv_long(K_tstr)); }
    else if (ys_eq_lit(name, "long")) { return yr(1, "k", yv_long(K_tlong)); }
    else if (ys_eq_lit(name, "byte")) { return yr(1, "k", yv_long(K_tbyte)); }
    else if (ys_eq_lit(name, "bool")) { return yr(1, "k", yv_long(K_tbool)); }
    else if (ys_eq_lit(name, "float")) { return yr(1, "k", yv_long(K_tfloat)); }
    else { return yr(2, "k", yv_long(K_tname), "name", name); }
}

// { field: T, ... } tail of parse_type_node (fresh names — see note).
Yv *parse_type_record(Yv *toks, long p) {
    // `{ f: T, ... }` is a record shape; `{ K => V }` is a map type.
    Yv *fields = yav(0);
    long pos = p + 1;  // skip '{'
    if (!is_punct(toks, pos, ys("}"))) {
        int go = 1;
        while (go) {
            if (is_punct(toks, pos, ys("}"))) {
                go = 0;
                ;
            } else {
                Yv *fname = tv(toks, pos);
                if (!is_name_tok(toks, pos)) {
                    return tres(terr_at(toks, pos, ys("a field name")), pos);
                }
                if (is_op(toks, pos + 1, ys("=>"))) {
                    // map type: the key is a type name, then =>, then V
                    Yv *kt = map_key_type(fname);
                    Yv *vt = parse_type_node(toks, pos + 2);
                    Yv *mc = tclose_res(
                        toks, yv_l(yr_get(vt, "pos")), ys("}"),
                        yr(3, "k", yv_long(K_tmap), "key", kt, "of",
                           yr_get(vt, "node")));
                    return parse_type_tail(toks, yv_l(yr_get(mc, "pos")),
                                           yr_get(mc, "node"));
                }
                // `name?: T`: an optional field, of type T?
                int fopt = is_op(toks, pos + 1, ys("?"));
                long cpos = pos + 1;
                if (fopt) {
                    cpos = pos + 2;
                }
                if (!is_punct(toks, cpos, ys(":"))) {
                    return tres(terr_at(toks, cpos, ys("':'")), cpos);
                }
                Yv *ft = parse_type_node(toks, cpos + 1);  // skip name and ':'
                Yv *fty = yr_get(ft, "node");
                if (fopt) {
                    fty = topt_of(fty);
                }
                fields = ya_push(fields, yr(3, "name", fname, "opt", yv_bool(fopt), "typ", fty));
                pos = yv_l(yr_get(ft, "pos"));
                // fields are separated by `,` or `;` (a trailing one is fine)
                if (is_punct(toks, pos, ys(",")) || is_punct(toks, pos, ys(";"))) {
                    pos = pos + 1;
                    ;
                } else {
                    go = 0;
                    ;
                }
                ;
            }
        }
        ;
    } else {
        ;
    }
    Yv *rc = tclose_res(toks, pos, ys("}"),
                        yr(2, "k", yv_long(K_trec), "fields", fields));
    return parse_type_tail(toks, yv_l(yr_get(rc, "pos")),
                           yr_get(rc, "node"));
}

// Simple type-name atom tail of parse_type_node (fresh names — see note).
Yv *parse_type_atom2(Yv *toks, long p) {
    // simple type name (`int` is `long`) + shared postfix tail.
    Yv *nm = tv(toks, p);
    if (!ys_eq_lit(tt(toks, p), "id")) {
        return tres(terr_at(toks, p, ys("a type")), p);
    } else if (ys_eq_lit(nm, "long")) {
        return parse_type_tail(toks, p + 1, yr(1, "k", yv_long(K_tlong)));
    } else if (ys_eq_lit(nm, "int")) {
        return parse_type_tail(toks, p + 1, yr(1, "k", yv_long(K_tlong)));
    } else if (ys_eq_lit(nm, "byte")) {
        return parse_type_tail(toks, p + 1, yr(1, "k", yv_long(K_tbyte)));
    } else if (ys_eq_lit(nm, "bool")) {
        return parse_type_tail(toks, p + 1, yr(1, "k", yv_long(K_tbool)));
    } else if (ys_eq_lit(nm, "str")) {
        return parse_type_tail(toks, p + 1, yr(1, "k", yv_long(K_tstr)));
    } else if (ys_eq_lit(nm, "float")) {
        return parse_type_tail(toks, p + 1, yr(1, "k", yv_long(K_tfloat)));
    } else if (ys_eq_lit(nm, "void")) {
        return parse_type_tail(toks, p + 1, yr(1, "k", yv_long(K_tvoid)));
    } else if (ys_eq_lit(nm, "mutex") || ys_eq_lit(nm, "sem")) {
        return parse_type_tail(toks, p + 1, sync_type(nm));
    } else if (is_op(toks, p + 1, ys(".")) && ys_eq_lit(tt(toks, p + 2), "id")) {
        // `m.T`: alias T of the module imported as m
        return parse_type_tail(toks, p + 3,
                               yr(2, "k", yv_long(K_tname), "name",
                                  ys_cat(ys_cat(nm, ys(".")), tv(toks, p + 2))));
    } else {
        return parse_type_tail(toks, p + 1, yr(2, "k", yv_long(K_tname), "name", nm));
    }
}

// Postfix tail shared by ALL atom arms: `?` then `->` (fresh names — see
// note). Every atom arm above calls parse_type_tail(toks, apos, anode)
// instead of returning its shape directly, so `?`/`->` apply uniformly
// (previously only some arms applied them — the rest silently dropped
// option/arrow suffixes).
Yv *parse_type_tail(Yv *toks, long apos, Yv *anode) {
    // postfix `?`: option type (binds tighter than `->`)
    // Both paths return the same parser-result shape; `?` wraps the atom
    // before the shared arrow parser handles the suffix.
    if (is_op(toks, apos, ys("?"))) {
        // NOTE: `?` then re-check `->`: T? -> U must keep parsing the arrow
        // (right-assoc). The `?` shape feeds parse_type_arrow as its anode.
        return parse_type_arrow(toks, apos + 1, yr(2, "k", yv_long(K_topt), "of", anode));
    } else {
        return parse_type_arrow(toks, apos, anode);
    }
}

// Arrow tail: `->` B (right-assoc) or bare grouping (fresh names — see note).
Yv *parse_type_arrow(Yv *toks, long apos, Yv *anode) {
    // A parenthesized list becomes the parameter list; any other atom
    // becomes the single parameter. anode is bound ONCE (never rebound),
    // so anode.ts always reads the pre-arrow shape.
    // NOTE: NO eager `anode.ts` snapshot (ats): the C backend evaluates
    // record literals EAGERLY — `{k:topt,...}.ts` on a non-tparams shape is a
    // hard runtime error ("key 'ts' not found"), and the C VM has no
    // option/lazy field access. Read .ts ONLY inside the tparams arms.
    // NOTE: NO `let ak = anode.k` snapshot: the checker env is
    // flow-insensitive (LAST shape wins per name)... but ak is a STR (not a
    // record), and narrowing a let-bound str via if-chains is exact — EXCEPT
    // the env ALSO merges ak with every other `ak` in the function. There is
    // exactly one `ak` here, so the snapshot is sound; the rule is only that
    // no OTHER arm may rebind `ak`. (`node`/`tgt` snapshots broke this rule:
    // they were rebound across MANY arms, merging all shapes.)
    // `anode` itself is a PARAM (never rebound), so `anode.k`/`anode.ts`
    // reads are always the true call-site shape. Keep reads inline.
    // NOTE: split callee by SHAPE, not by re-reading anode.k per arm:
    // parse_type_tparams vs parse_type_plain are SEPARATE defs, so each
    // function body contains exactly ONE `anode.k` read site resolving
    // against exactly one call-site shape family. (Two `anode.k` reads in
    // one body merge through the flow-insensitive env.)
    // `?` shapes already returned via parse_type_tail (which handles `?`
    // BEFORE calling here), so anode is never topt at this point: tparams
    // (param list) or a plain atom. Dispatch by shape WITHOUT reading
    // anode.k twice in one body: tparams goes to parse_type_tparams, every
    // other shape stays inline. The dispatch reads anode.k ONCE (nested
    // ifs, not `||` — bool/call-shape gates poison joint conditions).
    // NOTE: dispatch WITHOUT reading anode.k here at all: the CALLER
    // (parse_type_tail) already knows the shape — tparams arms call
    // parse_type_tparams directly, all other arms call parse_type_plain.
    // Reading anode.k in this body reintroduces the merged-shape read
    // (this `anode` param name is shared across all call sites).
    return parse_type_plain(toks, apos, anode);
}

Yv *parse_type_plain(Yv *toks, long apos, Yv *anode) {
    // Non-tparams atoms: `->` builds tfunc, else anode. This body contains
    // NO `anode.k`/`anode.ts` reads at all, so nothing merges here.
    if (is_op(toks, apos, ys("->"))) {
        Yv *rhs = parse_type_node(toks, apos + 1);
        return tres(yr(3, "k", yv_long(K_tfunc), "args", yav(1, anode), "ret", yr_get(rhs, "node")), yv_l(yr_get(rhs, "pos")));
    } else {
        return tres(anode, apos);
    }
}

Yv *parse_type_tparams(Yv *toks, long apos, Yv *tlist) {
    // tparams shape ONLY (dispatched by shape): the caller passes the TS
    // LIST itself (not a tparams record), so this body contains NO record
    // field reads at all — nothing to merge, nothing to mis-resolve.
    // `->` after a param list: (A, B) -> R. Else bare grouping: (T) = T.
    Yv *ts0 = tlist;
    if (is_op(toks, apos, ys("->"))) {
        Yv *rhs = parse_type_node(toks, apos + 1);
        return tres(yr(3, "k", yv_long(K_tfunc), "args", ts0, "ret", yr_get(rhs, "node")), yv_l(yr_get(rhs, "pos")));
    } else if (yv_len(ts0) == 1) {
        return tres(ya_get(ts0, 0), apos);
    } else {
        return tres(yr(2, "k", yv_long(K_tparams), "ts", ts0), apos);
    }
}

long parse_type_atom(Yv *toks, long p) {
    // Parse a single non-arrow type and return the position after it.
    // Atoms: long, str, bool, [T], (T, T), { field: T, ... }
    // NOTE: bound once — `parse_type_node(...).pos` inline misparses on the
    // C backend (it reads `f().y` as `f(.y)`).
    Yv *r = parse_type_node(toks, p);
    return yv_l(yr_get(r, "pos"));
}

long parse_type(Yv *toks, long p) {
    // Parse a type annotation and return the position after it.
    // Types: long, str, bool, [T], (T, T), { field: T }, and function types
    // A -> B (right-associative, so A -> B -> C = A -> (B -> C)).
    // The recursive arm only updates `pos`; this conditional's value is
    // discarded, so its VOID-law arm mismatch does not affect the result.
    long pos = parse_type_atom(toks, p);
    if (is_op(toks, pos, ys("->"))) {
        pos = parse_type(toks, pos + 1);
    } else {
        ;
    }
    return pos;
}

// ── function literal ─────────────────────────────────────────────────────

// `A | B | ...` -- a union of record types. Accepted where a whole
// annotation is parsed (let, params, returns, `type` declarations); a
// union nested inside another type goes through an alias.
Yv *parse_type_full(Yv *toks, long p) {
    Yv *first = parse_type_node(toks, p);
    if (is_op(toks, yv_l(yr_get(first, "pos")), ys("|"))) {
        Yv *ts = yav(0);
        ts = ya_push(ts, yr_get(first, "node"));
        long pos = yv_l(yr_get(first, "pos"));
        while (is_op(toks, pos, ys("|"))) {
            Yv *r = parse_type_node(toks, pos + 1);
            ts = ya_push(ts, yr_get(r, "node"));
            pos = yv_l(yr_get(r, "pos"));
        }
        return tres(yr(2, "k", yv_long(K_tunion), "ts", ts), pos);
    } else {
        return first;
    }
}

// The type a literal default value gives an unannotated parameter
// (`tnone` when the value is not a literal).
Yv *lit_type(Yv *node) {
    Yv *k = yr_get(node, "k");
    if (yv_l(k) == K_num) {
        return num_lit_type(yr_get(node, "v"));
    } else if (yv_l(k) == K_str) {
        return yr(1, "k", yv_long(K_tstr));
    } else if (yv_l(k) == K_bool) {
        return yr(1, "k", yv_long(K_tbool));
    } else if (yv_l(k) == K_char) {
        return yr(1, "k", yv_long(K_tbyte));
    } else if (yv_l(k) == K_un) {
        return lit_type_neg(node);
    } else {
        return yr(1, "k", yv_long(K_tnone));
    }
}

Yv *lit_type_neg(Yv *node) {
    Yv *e = yr_get(node, "e");
    if (ys_eq_lit(yr_get(node, "op"), "-") && yv_l(yr_get(e, "k")) == K_num) {
        return num_lit_type(yr_get(e, "v"));
    } else {
        return yr(1, "k", yv_long(K_tnone));
    }
}

/* T? -- the type an optional parameter `name?: T` has in the body. */
Yv *topt_of(Yv *t) {
    return yr(2, "k", yv_long(K_topt), "of", t);
}

// float when the literal has a fraction or an exponent (radix literals
// like 0xE1 never do).
Yv *num_lit_type(Yv *s) {
    Yv *p = ys_slice(s, 0, 2);
    if (ys_eq_lit(p, "0x") || ys_eq_lit(p, "0X") || ys_eq_lit(p, "0b") || ys_eq_lit(p, "0B")) {
        return yr(1, "k", yv_long(K_tlong));
    } else if (ys_index_of(s, ys(".")) >= 0 || ys_index_of(s, ys("e")) >= 0 || ys_index_of(s, ys("E")) >= 0) {
        return yr(1, "k", yv_long(K_tfloat));
    } else {
        return yr(1, "k", yv_long(K_tlong));
    }
}

Yv *parse_func(Yv *toks, long p) {
    // Named:    def name(params) -> ret { body }   (top-level declaration)
    // Anonymous: def(params) -> ret { body }        (function expression)
    long ln = tline(toks, p);
    long cl = tcol(toks, p);
    long pos = p + 1;  // skip 'def'
    Yv *fname = ys("");
    // A malformed header plants its errors here; they run first in the body.
    Yv *derrs = yav(0);
    // optional function name (present unless next token is '(')
    // Only the optional-name branch changes `fname` and `pos`; both are
    // consumed by the common parsing path below.
    if (!is_punct(toks, pos, ys("("))) {
        if (ys_eq_lit(tt(toks, pos), "id")) {
            fname = tv(toks, pos);
            pos = pos + 1;
            ;
        } else {
            derrs = ya_push(derrs,
                            expect_err(toks, pos,
                                       ys("a function name or '('")));
            ;
        }
        ;
    }
    int hbad = yv_len(derrs) > 0;
    if (is_punct(toks, pos, ys("("))) {
        pos = pos + 1;
        ;
    } else {
        if (!hbad) {
            derrs = ya_push(derrs, expect_err(toks, pos, ys("'('")));
            ;
        } else {
            ;
        }
        hbad = 1;
        ;
    }
    Yv *names = yav(0);
    Yv *ptypes = yav(0);
    // defs[i]: param i's default value (a literal), `void` when it has none,
    // `optarg` for an optional `name?: T` (none when left out, some(arg) when
    // passed -- rename.y fills both in)
    Yv *defs = yav(0);
    Yv *optname = ys("");
    if (!hbad && !is_punct(toks, pos, ys(")"))) {
        int go = 1;
        while (go) {
            if (!ys_eq_lit(tt(toks, pos), "id")) {
                derrs = ya_push(derrs,
                                expect_err(toks, pos,
                                           ys("a parameter name")));
                hbad = 1;
                go = 0;
                ;
            } else {
                Yv *nm = tv(toks, pos);
                names = ya_push(names, nm);
                pos = pos + 1;  // name
                int isopt = 0;
                if (is_op(toks, pos, ys("?"))) {
                    isopt = 1;
                    pos = pos + 1;
                    if (!is_punct(toks, pos, ys(":"))) {
                        derrs = ya_push(
                            derrs,
                            yr(4, "k", yv_long(K_err), "msg",
                               ys_cat(
                                   ys_cat(ys_cat(
                                              ys("optional parameter '"), nm),
                                          ys("' needs a type ('")),
                                   ys_cat(nm, ys("?: T')"))),
                               "line", yv_long(tline(toks, pos)),
                               "col", yv_long(tcol(toks, pos))));
                    }
                }
                Yv *pt = yr(1, "k", yv_long(K_tnone));
                if (is_punct(toks, pos, ys(":"))) {
                    Yv *tr = parse_type_full(toks, pos + 1);
                    pt = yr_get(tr, "node");
                    pos = yv_l(yr_get(tr, "pos"));
                    Yv *pte = type_err(pt);
                    if (yv_l(yr_get(pte, "k")) == K_err) {
                        derrs = ya_push(derrs, pte);
                        pt = yr(1, "k", yv_long(K_tnone));
                        hbad = 1;
                        ;
                    } else {
                        ;
                    }
                    ;
                } else {
                    ;
                }
                Yv *dv = yr(3, "k", yv_long(K_void), "line",
                            yv_long(tline(toks, pos)), "col",
                            yv_long(tcol(toks, pos)));
                if (is_op(toks, pos, ys("="))) {
                    // `name = literal`: callers may leave it out; without an
                    // annotation the literal also gives the parameter its type.
                    Yv *dr = parse_unary(toks, pos + 1);
                    pos = yv_l(yr_get(dr, "pos"));
                    Yv *dt = lit_type(yr_get(dr, "node"));
                    if (yv_l(yr_get(dt, "k")) == K_tnone) {
                        derrs = ya_push(
                            derrs,
                            yr(4, "k", yv_long(K_err), "msg",
                               ys_cat(ys_cat(
                                          ys("default value of parameter '"),
                                          nm),
                                      ys("' must be a literal")),
                               "line", yv_long(tline(toks, pos)),
                               "col", yv_long(tcol(toks, pos))));
                        ;
                    } else {
                        dv = yr_get(dr, "node");
                        if (yv_l(yr_get(pt, "k")) == K_tnone) {
                            pt = dt;
                            ;
                        } else {
                            ;
                        }
                        ;
                    }
                    if (isopt) {
                        derrs = ya_push(
                            derrs,
                            yr(4, "k", yv_long(K_err), "msg",
                               ys_cat(ys_cat(
                                          ys("optional parameter '"), nm),
                                      ys("' cannot have a default (it is none when left out)")),
                               "line", yv_long(tline(toks, pos)),
                               "col", yv_long(tcol(toks, pos))));
                    }
                    ;
                } else {
                    ;
                }
                if (isopt) {
                    if (yv_l(yr_get(pt, "k")) != K_tnone) {
                        pt = topt_of(pt);
                    }
                    dv = yr(3, "k", yv_long(K_optarg), "line",
                            yv_long(tline(toks, pos)), "col",
                            yv_long(tcol(toks, pos)));
                    optname = nm;
                } else if (!ys_eq_lit(optname, "") &&
                           yv_l(yr_get(dv, "k")) == K_void) {
                    derrs = ya_push(
                        derrs,
                        yr(4, "k", yv_long(K_err), "msg",
                           ys_cat(ys_cat(
                                      ys_cat(
                                          ys("required parameter '"), nm),
                                      ys("' cannot follow optional parameter '")),
                                  ys_cat(optname, ys("' (optional parameters come last)"))),
                           "line", yv_long(tline(toks, pos)),
                           "col", yv_long(tcol(toks, pos))));
                }
                ptypes = ya_push(ptypes, pt);
                defs = ya_push(defs, dv);
                if (is_punct(toks, pos, ys(","))) {
                    pos = pos + 1;
                    ;
                } else {
                    go = 0;
                    ;
                }
                ;
            }
            ;
        }
        ;
    }
    if (is_punct(toks, pos, ys(")"))) {
        pos = pos + 1;
        ;
    } else {
        if (!hbad) {
            derrs = ya_push(derrs,
                            expect_err(toks, pos, ys("',' or ')'")));
            ;
        } else {
            ;
        }
        ;
    }
    // optional return type '-> type'
    // The optional return annotation updates the local type and position.
    Yv *ret = yr(1, "k", yv_long(K_tnone));
    if (is_op(toks, pos, ys("->"))) {
        Yv *rr = parse_type_full(toks, pos + 1);
        ret = yr_get(rr, "node");
        pos = yv_l(yr_get(rr, "pos"));
        Yv *rte = type_err(ret);
        if (yv_l(yr_get(rte, "k")) == K_err) {
            derrs = ya_push(derrs, rte);
            ret = yr(1, "k", yv_long(K_tnone));
            ;
        } else {
            ;
        }
        ;
    } else {
        ;
    }
    Yv *body = parse_block(toks, pos);
    Yv *bnode = yr_get(body, "node");
    if (yv_len(derrs) > 0) {
        Yv *bst = yr_get(bnode, "stmts");
        Yv *nst = yav(0);
        for (long di = 0; di < yv_len(derrs); di++) nst = ya_push(nst, ya_get(derrs, di));
        for (long bi = 0; bi < yv_len(bst); bi++) nst = ya_push(nst, ya_get(bst, bi));
        bnode = yr(4, "k", yv_long(K_block), "stmts", nst, "line", yr_get(bnode, "line"), "col", yr_get(bnode, "col"));
    }
    Yv *func = yr(8, "k", yv_long(K_func), "params", names, "ptypes", ptypes, "ret", ret, "body", bnode, "line", yv_long(ln), "col", yv_long(cl), "defs", defs);
    if (ys_eq_lit(fname, "")) {
        return res(func, yv_l(yr_get(body, "pos")));
    } else {
        return res(yr(7, "k", yv_long(K_decl), "kind", ys("def"), "name", fname, "typ", yr(1, "k", yv_long(K_tnone)), "v", func, "line", yv_long(ln), "col", yv_long(cl)), yv_l(yr_get(body, "pos")));
    }
}

// ── block { stmt; stmt; ... } ────────────────────────────────────────────

Yv *parse_block(Yv *toks, long p) {
    long ln = tline(toks, p);
    long cl = tcol(toks, p);
    if (!is_punct(toks, p, ys("{"))) {
        // A body was required here. Nothing is consumed: the stray token is
        // parsed by whatever comes next.
        Yv *one = yav(0);
        one = ya_push(one, expect_err(toks, p, ys("'{'")));
        return res(yr(4, "k", yv_long(K_block), "stmts", one, "line",
                      yv_long(ln), "col", yv_long(cl)), p);
    }
    long pos = p + 1;  // skip '{'
    Yv *stmts = yav(0);
    // NOTE: no `&&` (see lexer.y line-comment note): the C VM evaluates both
    // sides eagerly, so tt()/toks[pos] runs past "}" (clamped — safe here,
    // but the native checker rejects the shape); nested-if form instead.
    int go = 1;
    // A block whose last statement ends in `;` is void: `{ f(); }` computes
    // nothing, `{ f() }` is f's value. A trailing `return x;` (or a branch
    // that always returns) keeps its meaning -- control never gets past it.
    int last_semi = 0;
    while (go) {
        // NOTE: statement-form + `0;` tails — the while body must be
        // void-typed (see parse_binary note).
        if (is_punct(toks, pos, ys("}"))) {
            go = 0;
            ;
        } else if (ys_eq_lit(tt(toks, pos), "eof")) {
            stmts = ya_push(
                stmts,
                yr(4, "k", yv_long(K_err), "msg",
                   ys("unclosed '{' (no matching '}' before end of input)"),
                   "line", yv_long(ln), "col", yv_long(cl)));
            go = 0;
            ;
        } else {
            Yv *s = parse_stmt(toks, pos);
            Yv *snode = yr_get(s, "node");
            stmts = ya_push(stmts, snode);
            pos = stmt_end(toks, pos, yv_l(yr_get(s, "pos")), snode, stmts);
            last_semi = is_punct(toks, pos - 1, ys(";"));
            ;
        }
    }
    if (last_semi && !stmt_diverges(ya_get(stmts, yv_len(stmts) - 1))) {
        stmts = ya_push(stmts, yr(3, "k", yv_long(K_void), "line",
                                  yv_long(tline(toks, pos)), "col",
                                  yv_long(tcol(toks, pos))));
    }
    return res(yr(4, "k", yv_long(K_block), "stmts", stmts, "line", yv_long(ln), "col", yv_long(cl)), skip_close(toks, pos, ys("}")));
}

long stmt_end(Yv *toks, long start, long pos, Yv *sn, Yv *stmts) {
    if (is_punct(toks, pos, ys(";"))) {
        return pos + 1;
    } else if (is_punct(toks, pos, ys("}")) ||
               ys_eq_lit(tt(toks, pos), "eof")) {
        return pos;
    } else if (pos > start && is_punct(toks, pos - 1, ys("}"))) {
        return pos;
    } else {
        if (yv_l(yr_get(sn, "k")) != K_err) {
            stmts = ya_push(stmts, expect_err(toks, pos, ys("';'")));
            ;
        } else {
            ;
        }
        return skip_close(toks, sync_stmt(toks, pos), ys(";"));
    }
}

// Does control never continue past this statement? `return`, and an
// if/else (or block) whose every path ends in one.
int stmt_diverges(Yv *s) {
    Yv *k = yr_get(s, "k");
    if (yv_l(k) == K_ret) {
        return 1;
    } else if (yv_l(k) == K_block) {
        return block_diverges(yr_get(s, "stmts"));
    } else if (yv_l(k) == K_kw_if) {
        return if_diverges(s);
    } else {
        return 0;
    }
}

int block_diverges(Yv *stmts) {
    if (yv_len(stmts) == 0) {
        return 0;
    } else {
        return stmt_diverges(ya_get(stmts, yv_len(stmts) - 1));
    }
}

int if_diverges(Yv *s) {
    if (yv_b(yr_get(s, "has_else"))) {
        return stmt_diverges(yr_get(s, "then")) && stmt_diverges(yr_get(s, "els"));
    } else {
        return 0;
    }
}

// ── statements ───────────────────────────────────────────────────────────

Yv *parse_stmt(Yv *toks, long p) {
    if (is_punct(toks, p, ys(";"))) {
        // An empty statement; the caller steps over the `;`.
        return res(yr(3, "k", yv_long(K_void), "line", yv_long(tline(toks, p)),
                              "col", yv_long(tcol(toks, p))), p);
    } else if (is_kw(toks, p, ys("let"))) {
        return parse_decl(toks, p);
    } else if (is_kw(toks, p, ys("const"))) {
        return parse_decl(toks, p);
    } else if (is_typedef_start(toks, p)) {
        return parse_typedef(toks, p);
    } else if (is_kw(toks, p, ys("return"))) {
        if (is_punct(toks, p + 1, ys(";")) ||
            is_punct(toks, p + 1, ys("}")) ||
            ys_eq_lit(tt(toks, p + 1), "eof")) {
            return res(yr(4, "k", yv_long(K_ret), "e",
                          yr(3, "k", yv_long(K_void), "line",
                             yv_long(tline(toks, p)), "col",
                             yv_long(tcol(toks, p))),
                          "line", yv_long(tline(toks, p)), "col",
                          yv_long(tcol(toks, p))),
                       p + 1);
        } else {
            Yv *e = parse_expr(toks, p + 1);
            return res(yr(4, "k", yv_long(K_ret), "e", yr_get(e, "node"), "line",
                          yv_long(tline(toks, p)), "col", yv_long(tcol(toks, p))),
                       yv_l(yr_get(e, "pos")));
        }
    } else {
        // expression, possibly an assignment: id = expr, arr[i] = expr, or obj.key = expr
        // NOTE: dispatch by SHAPE into separate defs (like parse_type_tail):
        // parse_stmt_assign splits index/dot/deref/plain-id into callees
        // that each read ONLY their own shape's fields. Reading tgt.arr +
        // tgt.obj + tgt.e + tgt.v in ONE body merges all shapes through the
        // flow-insensitive env ("record has no field 'arr'").
        Yv *e = parse_expr(toks, p);
        if (is_op(toks, yv_l(yr_get(e, "pos")), ys("="))) {
            return parse_stmt_assign(toks, p, yr_get(e, "node"), yv_l(yr_get(e, "pos")));
        } else if (is_compound_assign(toks, yv_l(yr_get(e, "pos")))) {
            return parse_stmt_opassign(toks, p, yr_get(e, "node"), yv_l(yr_get(e, "pos")));
        } else {
            return e;
        }
    }
}

// `type Name = T;` -- a type alias (`type` is a keyword only here, so it
// stays usable as an ordinary name everywhere else).
int is_typedef_start(Yv *toks, long p) {
    return ys_eq_lit(tt(toks, p), "id") && ys_eq_lit(tv(toks, p), "type") && ys_eq_lit(tt(toks, p + 1), "id") && is_op(toks, p + 2, ys("="));
}

Yv *parse_typedef(Yv *toks, long p) {
    Yv *r = parse_type_full(toks, p + 3);
    Yv *te = type_err(yr_get(r, "node"));
    if (yv_l(yr_get(te, "k")) == K_err) {
        return res(te, sync_stmt(toks, yv_l(yr_get(r, "pos"))));
    } else {
        return res(yr(5, "k", yv_long(K_typedef), "name", tv(toks, p + 1),
                      "typ", yr_get(r, "node"), "line", yv_long(tline(toks, p)),
                      "col", yv_long(tcol(toks, p))),
                   yv_l(yr_get(r, "pos")));
    }
}

// `x op= e`. The target keeps its expression form — a[f()] += 1 evaluates
// f() once. Array targets reinterpret `+=` (push/append) and `*=` (prepend
// an element) in the emitter; everywhere else `*=` is multiply-assign.
int is_compound_assign(Yv *toks, long p) {
    if (is_op(toks, p, ys("+="))) {
        return 1;
    } else if (is_op(toks, p, ys("-="))) {
        return 1;
    } else if (is_op(toks, p, ys("*="))) {
        return 1;
    } else if (is_op(toks, p, ys("/="))) {
        return 1;
    } else if (is_op(toks, p, ys("%="))) {
        return 1;
    } else if (is_op(toks, p, ys("&="))) {
        return 1;
    } else if (is_op(toks, p, ys("|="))) {
        return 1;
    } else if (is_op(toks, p, ys("^="))) {
        return 1;
    } else if (is_op(toks, p, ys("<<="))) {
        return 1;
    } else if (is_op(toks, p, ys(">>="))) {
        return 1;
    } else {
        return is_op(toks, p, ys(">>>="));
    }
}

Yv *parse_stmt_opassign(Yv *toks, long p, Yv *tgt, long epos) {
    (void)p;  // unused in the Y source too (line/col come from epos)
    Yv *op = tv(toks, epos);
    Yv *rhs = parse_expr(toks, epos + 1);
    // Every compound op is `X=`, so the binary op is all but its last
    // character (`>>>=` is `>>>`).
    Yv *binop = ys_slice(op, 0, yv_len(op) - 1);
    return res(yr(6, "k", yv_long(K_opassign), "op", binop, "tgt", tgt, "v", yr_get(rhs, "node"), "line", yv_long(tline(toks, epos)), "col", yv_long(tcol(toks, epos))), yv_l(yr_get(rhs, "pos")));
}

// Assignment dispatch: one def per target shape (see parse_stmt note).
// Each body reads ONLY its own shape's fields — no merged-shape reads.
Yv *parse_stmt_assign(Yv *toks, long p, Yv *tgt, long epos) {
    // NOTE: dispatch WITHOUT reading tgt.k twice in one body (see
    // parse_type_arrow note): index/dot go to dedicated callees; deref and
    // plain-id stay inline (disjoint fields e vs v — but read each once).
    if (yv_l(yr_get(tgt, "k")) == K_index) {
        return parse_stmt_idxassign(toks, p, tgt, epos);
    } else {
        return parse_stmt_rest(toks, p, tgt, epos);
    }
}

Yv *parse_stmt_idxassign(Yv *toks, long p, Yv *tgt, long epos) {
    // NOTE: pass the WHOLE target + a KIND tag; the callee re-reads fields
    // off its OWN param (one shape per callee — no cross-callee merge).
    // Reading tgt.arr HERE would merge with tgt.obj/tgt.e/tgt.v reads in
    // sibling callees (same param name `tgt` across defs shares one env
    // entry). The _go callee's param is a DIFFERENT name (itgt), read once.
    return parse_stmt_idxassign_go(toks, p, tgt, epos);
}

Yv *parse_stmt_idxassign_go(Yv *toks, long p, Yv *itgt, long epos) {
    // NOTE: param DECLARED with the full shape: the env entry for `itgt`
    // carries arr/idx (not the merged {k}-only hole), so the reads below
    // resolve. tcompat's structural trec rule accepts the richer call-site
    // literal at the call (superset accepts subset).
    Yv *rhs = parse_expr(toks, epos + 1);
    return res(yr(6, "k", yv_long(K_idxassign), "arr", yr_get(itgt, "arr"), "idx", yr_get(itgt, "idx"), "v", yr_get(rhs, "node"), "line", yv_long(tline(toks, p)), "col", yv_long(tcol(toks, p))), yv_l(yr_get(rhs, "pos")));
}



Yv *parse_stmt_rest(Yv *toks, long p, Yv *tgt, long epos) {
    if (yv_l(yr_get(tgt, "k")) == K_dot) {
        return parse_stmt_dotassign(toks, p, tgt, epos);
    } else {
        return parse_stmt_simple(toks, p, tgt, epos);
    }
}

Yv *parse_stmt_dotassign(Yv *toks, long p, Yv *tgt, long epos) {
    // NOTE: same whole-record handoff as idxassign (see note above).
    return parse_stmt_dotassign_go(toks, p, tgt, epos);
}

Yv *parse_stmt_dotassign_go(Yv *toks, long p, Yv *dtgt, long epos) {
    // NOTE: full-shape param (see idxassign_go note).
    Yv *rhs = parse_expr(toks, epos + 1);
    return res(yr(6, "k", yv_long(K_dotassign), "obj", yr_get(dtgt, "obj"), "key", yr_get(dtgt, "key"), "v", yr_get(rhs, "node"), "line", yv_long(tline(toks, p)), "col", yv_long(tcol(toks, p))), yv_l(yr_get(rhs, "pos")));
}



Yv *parse_stmt_simple(Yv *toks, long p, Yv *tgt, long epos) {
    // deref (*p = v) vs plain id (x = v): separate callees per shape, fields
    // passed as VALUES (see parse_stmt_idxassign note).
    if (yv_l(yr_get(tgt, "k")) == K_deref) {
        return parse_stmt_store(toks, p, tgt, epos);
    } else {
        return parse_stmt_simple2(toks, p, tgt, epos);
    }
}

Yv *parse_stmt_simple2(Yv *toks, long p, Yv *tgt, long epos) {
    if (yv_l(yr_get(tgt, "k")) == K_slice) {
        return parse_stmt_sliceassign(toks, p, tgt, epos);
    } else {
        return parse_stmt_plainassign(toks, p, tgt, epos);
    }
}

// `a[lo:hi] = src`: overwrite that range of a with src's elements (the
// lengths must agree; checked at run time).
Yv *parse_stmt_sliceassign(Yv *toks, long p, Yv *ltgt, long epos) {
    Yv *rhs = parse_expr(toks, epos + 1);
    return res(yr(7, "k", yv_long(K_sliceassign), "arr", yr_get(ltgt, "arr"), "lo", yr_get(ltgt, "lo"), "hi", yr_get(ltgt, "hi"), "v", yr_get(rhs, "node"), "line", yv_long(tline(toks, p)), "col", yv_long(tcol(toks, p))), yv_l(yr_get(rhs, "pos")));
}

Yv *parse_stmt_store(Yv *toks, long p, Yv *stgt, long epos) {
    // NOTE: full-shape param (see idxassign_go note).
    Yv *rhs = parse_expr(toks, epos + 1);
    return res(yr(5, "k", yv_long(K_store), "p", yr_get(stgt, "e"), "v", yr_get(rhs, "node"), "line", yv_long(tline(toks, p)), "col", yv_long(tcol(toks, p))), yv_l(yr_get(rhs, "pos")));
}

Yv *parse_stmt_plainassign(Yv *toks, long p, Yv *atgt, long epos) {
    // NOTE: full-shape param (see idxassign_go note).
    Yv *rhs = parse_expr(toks, epos + 1);
    if (yv_l(yr_get(atgt, "k")) == K_id) {
        return res(yr(5, "k", yv_long(K_assign), "name", yr_get(atgt, "v"),
                      "v", yr_get(rhs, "node"), "line", yv_long(tline(toks, p)),
                      "col", yv_long(tcol(toks, p))),
                   yv_l(yr_get(rhs, "pos")));
    } else if (yv_l(yr_get(atgt, "k")) == K_err) {
        return res(atgt, yv_l(yr_get(rhs, "pos")));
    } else {
        return res(yr(4, "k", yv_long(K_err),
                      "msg", ys("cannot assign to this expression"),
                      "line", yv_long(tline(toks, p)),
                      "col", yv_long(tcol(toks, p))),
                   yv_l(yr_get(rhs, "pos")));
    }
}

Yv *parse_decl(Yv *toks, long p) {
    Yv *kind = tv(toks, p);
    Yv *name = tv(toks, p + 1);
    long ln = tline(toks, p);
    long cl = tcol(toks, p);
    if (!ys_eq_lit(tt(toks, p + 1), "id")) {
        Yv *what = ys_cat(ys_cat(ys("a name after '"), kind), ys("'"));
        return res(expect_err(toks, p + 1, what),
                   sync_stmt(toks, p + 1));
    }
    long pos = p + 2;
    // optional ': type' (kept as a type node for the static checker)
    // The optional annotation updates the local type and position.
    Yv *typ = yr(1, "k", yv_long(K_tnone));
    if (is_punct(toks, pos, ys(":"))) {
        Yv *tr = parse_type_full(toks, pos + 1);
        typ = yr_get(tr, "node");
        pos = yv_l(yr_get(tr, "pos"));
        Yv *te = type_err(typ);
        if (yv_l(yr_get(te, "k")) == K_err) {
            return res(yr(7, "k", yv_long(K_decl), "kind", kind, "name", name,
                          "typ", yr(1, "k", yv_long(K_tnone)), "v", te,
                          "line", yv_long(ln), "col", yv_long(cl)),
                       sync_stmt(toks, pos));
        }
        ;
    } else {
        ;
    }
    if (!is_op(toks, pos, ys("="))) {
        Yv *err = expect_err(toks, pos, ys("'='"));
        return res(yr(7, "k", yv_long(K_decl), "kind", kind, "name", name,
                      "typ", yr(1, "k", yv_long(K_tnone)), "v", err,
                      "line", yv_long(ln), "col", yv_long(cl)),
                   sync_stmt(toks, pos));
    }
    Yv *e = parse_expr(toks, pos + 1);
    return res(yr(7, "k", yv_long(K_decl), "kind", kind, "name", name, "typ", typ, "v", yr_get(e, "node"), "line", yv_long(ln), "col", yv_long(cl)), yv_l(yr_get(e, "pos")));
}

long sync_stmt(Yv *toks, long p) {
    long pos = p;
    long depth = 0;
    int go = 1;
    while (go) {
        Yv *t = tt(toks, pos);
        if (ys_eq_lit(t, "eof")) {
            go = 0;
            ;
        } else if (ys_eq_lit(t, "punct")) {
            Yv *v = tv(toks, pos);
            if (depth == 0 &&
                (ys_eq_lit(v, ";") || ys_eq_lit(v, "}"))) {
                go = 0;
                ;
            } else {
                if (ys_eq_lit(v, "(") || ys_eq_lit(v, "[") ||
                    ys_eq_lit(v, "{")) {
                    depth = depth + 1;
                    ;
                } else if (ys_eq_lit(v, ")") || ys_eq_lit(v, "]") ||
                           ys_eq_lit(v, "}")) {
                    if (depth > 0) {
                        depth = depth - 1;
                        ;
                    } else {
                        ;
                    }
                    ;
                } else {
                    ;
                }
                pos = pos + 1;
                ;
            }
        } else {
            pos = pos + 1;
            ;
        }
    }
    return pos;
}

// ── control flow ─────────────────────────────────────────────────────────

Yv *parse_if(Yv *toks, long p) {
    long ln = tline(toks, p);
    long cl = tcol(toks, p);
    Yv *cond = parse_expr(toks, p + 1);
    Yv *then_b = parse_block(toks, yv_l(yr_get(cond, "pos")));
    long pos = yv_l(yr_get(then_b, "pos"));
    Yv *else_b = yr(3, "k", yv_long(K_void), "line", yv_long(ln), "col",
                    yv_long(cl));
    int has_else = 0;
    // The optional else branch updates the AST bookkeeping.
    if (is_kw(toks, pos, ys("else"))) {
        if (is_kw(toks, pos + 1, ys("if"))) {
            Yv *ei = parse_if(toks, pos + 1);
            else_b = yr_get(ei, "node");
            pos = yv_l(yr_get(ei, "pos"));
            ;
        } else {
            Yv *eb = parse_block(toks, pos + 1);
            else_b = yr_get(eb, "node");
            pos = yv_l(yr_get(eb, "pos"));
            ;
        }
        has_else = 1;
        ;
    } else {
        ;
    }
    return res(yr(7, "k", yv_long(K_kw_if), "cond", yr_get(cond, "node"), "then", yr_get(then_b, "node"), "els", else_b, "has_else", yv_bool(has_else), "line", yv_long(ln), "col", yv_long(cl)), pos);
}

Yv *parse_while(Yv *toks, long p) {
    Yv *cond = parse_expr(toks, p + 1);
    Yv *body = parse_block(toks, yv_l(yr_get(cond, "pos")));
    return res(yr(5, "k", yv_long(K_kw_while), "cond", yr_get(cond, "node"), "body", yr_get(body, "node"), "line", yv_long(tline(toks, p)), "col", yv_long(tcol(toks, p))), yv_l(yr_get(body, "pos")));
}

Yv *parse_foreach(Yv *toks, long p) {
    // foreach ( x in iterable ) { body }
    if (!is_punct(toks, p + 1, ys("("))) {
        return res(expect_err(toks, p + 1,
                              ys("'(' after 'foreach'")),
                   sync_stmt(toks, p + 1));
    }
    if (!ys_eq_lit(tt(toks, p + 2), "id")) {
        return res(expect_err(toks, p + 2,
                              ys("a loop variable name")),
                   sync_stmt(toks, p + 1));
    }
    if (!is_kw(toks, p + 3, ys("in"))) {
        return res(expect_err(toks, p + 3, ys("'in'")),
                   sync_stmt(toks, p + 1));
    }
    Yv *name = tv(toks, p + 2);
    Yv *it = parse_expr(toks, p + 4);  // skip 'foreach' '(' name 'in'
    if (!is_punct(toks, yv_l(yr_get(it, "pos")), ys(")"))) {
        return res(expect_err(toks, yv_l(yr_get(it, "pos")), ys("')'")),
                   sync_stmt(toks, p + 1));
    }
    Yv *body = parse_block(toks, yv_l(yr_get(it, "pos")) + 1);  // skip ')'
    return res(yr(6, "k", yv_long(K_kw_foreach), "name", name, "iter", yr_get(it, "node"), "body", yr_get(body, "node"), "line", yv_long(tline(toks, p)), "col", yv_long(tcol(toks, p))), yv_l(yr_get(body, "pos")));
}

Yv *parse_for_or_range(Yv *toks, long p) {
    // for i in a..b { body }   OR   for (init; cond; step) { body }
    long ln = tline(toks, p);
    long cl = tcol(toks, p);
    if (is_kw(toks, p + 2, ys("in"))) {
        if (!ys_eq_lit(tt(toks, p + 1), "id")) {
            return res(expect_err(toks, p + 1,
                                  ys("a loop variable name")),
                       sync_stmt(toks, p + 1));
        }
        Yv *name = tv(toks, p + 1);
        Yv *lo = parse_expr(toks, p + 3);
        if (!is_op(toks, yv_l(yr_get(lo, "pos")), ys(".."))) {
            return res(expect_err(toks, yv_l(yr_get(lo, "pos")),
                                  ys("'..'")),
                       sync_stmt(toks, p + 1));
        }
        Yv *hi = parse_expr(toks, yv_l(yr_get(lo, "pos")) + 1);
        Yv *body = parse_block(toks, yv_l(yr_get(hi, "pos")));
        return res(yr(7, "k", yv_long(K_forrange), "name", name, "lo", yr_get(lo, "node"), "hi", yr_get(hi, "node"), "body", yr_get(body, "node"), "line", yv_long(ln), "col", yv_long(cl)), yv_l(yr_get(body, "pos")));
    } else {
        // C-style for
        // The init and step clauses are optional; only present clauses
        // update their local parser state.
        if (!is_punct(toks, p + 1, ys("("))) {
            return res(expect_err(
                           toks, p + 1,
                           ys("'(' or a loop variable after 'for'")),
                       sync_stmt(toks, p + 1));
        }
        long pos = p + 2;  // skip 'for' '('
        Yv *init = yr(3, "k", yv_long(K_void), "line",
                      yv_long(tline(toks, pos)), "col",
                      yv_long(tcol(toks, pos)));
        if (!is_punct(toks, pos, ys(";"))) {
            Yv *ir = parse_stmt(toks, pos);
            init = yr_get(ir, "node");
            pos = yv_l(yr_get(ir, "pos"));
            ;
        } else {
            ;
        }
        if (!is_punct(toks, pos, ys(";"))) {
            Yv *err = clause_err(toks, pos, init, ys("';'"));
            return res(err, sync_stmt(toks, p + 1));
        }
        pos = pos + 1;  // ';'
        Yv *cond = yr(4, "k", yv_long(K_bool), "v", ys("true"), "line",
                      yv_long(tline(toks, pos)), "col", yv_long(tcol(toks, pos)));
        if (!is_punct(toks, pos, ys(";"))) {
            Yv *cr = parse_expr(toks, pos);
            cond = yr_get(cr, "node");
            pos = yv_l(yr_get(cr, "pos"));
            ;
        } else {
            ;
        }
        if (!is_punct(toks, pos, ys(";"))) {
            Yv *err = clause_err(toks, pos, cond, ys("';'"));
            return res(err, sync_stmt(toks, p + 1));
        }
        pos = pos + 1;  // ';'
        Yv *step = yr(3, "k", yv_long(K_void), "line",
                      yv_long(tline(toks, pos)), "col",
                      yv_long(tcol(toks, pos)));
        if (!is_punct(toks, pos, ys(")"))) {
            Yv *sr = parse_stmt(toks, pos);
            step = yr_get(sr, "node");
            pos = yv_l(yr_get(sr, "pos"));
            ;
        } else {
            ;
        }
        if (!is_punct(toks, pos, ys(")"))) {
            Yv *err = clause_err(toks, pos, step, ys("')'"));
            return res(err, sync_stmt(toks, p + 1));
        }
        pos = pos + 1;  // ')'
        Yv *body = parse_block(toks, pos);
        return res(yr(7, "k", yv_long(K_kw_for), "init", init, "cond", cond,
                      "step", step, "body", yr_get(body, "node"), "line",
                      yv_long(ln), "col", yv_long(cl)),
                   yv_l(yr_get(body, "pos")));
    }
}

Yv *clause_err(Yv *toks, long pos, Yv *clause, Yv *sep) {
    if (yv_l(yr_get(clause, "k")) == K_err) {
        return clause;
    } else {
        return expect_err(toks, pos, sep);
    }
}

// ── match ────────────────────────────────────────────────────────────────
// (see parser.y: `match` is lowered here to a block + if-chain over the
// rectest / narrow / matchend nodes.)

Yv *parse_match_try(Yv *toks, long p) {
    // `match` is a keyword only when an expression and `{` follow it.
    long ln = tline(toks, p);
    long cl = tcol(toks, p);
    Yv *nt = tt(toks, p + 1);
    Yv *plain = yr(4, "k", yv_long(K_id), "v", ys("match"), "line", yv_long(ln), "col", yv_long(cl));
    if (ys_eq_lit(nt, "op") || ys_eq_lit(nt, "eof")) {
        return res(plain, p + 1);
    } else if (ys_eq_lit(nt, "punct") && !is_punct(toks, p + 1, ys("(")) && !is_punct(toks, p + 1, ys("[")) && !is_punct(toks, p + 1, ys("{"))) {
        return res(plain, p + 1);
    } else {
        Yv *subj = parse_expr(toks, p + 1);
        if (is_punct(toks, yv_l(yr_get(subj, "pos")), ys("{"))) {
            return parse_match(toks, yr_get(subj, "node"), yv_l(yr_get(subj, "pos")), ln, cl);
        } else {
            return res(plain, p + 1);
        }
    }
}

Yv *parse_match(Yv *toks, Yv *subj, long bpos, long ln, long cl) {
    Yv *tmp = ys_cat(ys_cat(ys_cat(ys("$m"), ys_long(ln)), ys("_")), ys_long(cl));
    Yv *tests = yav(0);
    Yv *thens = yav(0);
    Yv *covers = yav(0);
    long nvals = 0;
    Yv *fallback = yr(3, "k", yv_long(K_void), "line", yv_long(ln), "col",
                      yv_long(cl));
    int has_wild = 0;
    long pos = bpos + 1;
    int go = 1;
    while (go) {
        if (is_punct(toks, pos, ys("}"))) {
            go = 0;
        } else if (ys_eq_lit(tt(toks, pos), "eof")) {
            tests = ya_push(
                tests,
                yr(4, "k", yv_long(K_err), "msg",
                   ys("unclosed match (no '}' before end of input)"),
                   "line", yv_long(ln), "col", yv_long(cl)));
            thens = ya_push(
                thens,
                block1(yr(3, "k", yv_long(K_void), "line", yv_long(ln), "col",
                         yv_long(cl)),
                       ln, cl));
            go = 0;
        } else {
            Yv *pr = parse_pattern(toks, pos, tmp);
            pos = yv_l(yr_get(pr, "pos"));
            Yv *body = yr(3, "k", yv_long(K_void), "line",
                          yv_long(tline(toks, pos)), "col",
                          yv_long(tcol(toks, pos)));
            if (is_op(toks, pos, ys("=>"))) {
                Yv *br = parse_arm_body(toks, pos + 1);
                pos = yv_l(yr_get(br, "pos"));
                body = yr_get(br, "node");
            } else {
                body = yr(4, "k", yv_long(K_err), "msg", ys_cat(ys_cat(ys("expected '=>' after a match pattern, got '"), tv(toks, pos)), ys("'")), "line", yv_long(tline(toks, pos)), "col", yv_long(tcol(toks, pos)));
                go = 0;
            }
            if (has_wild) {
                ;
            } else if (yv_b(yr_get(pr, "wild"))) {
                has_wild = 1;
                fallback = body;
            } else {
                tests = ya_push(tests, yr_get(pr, "test"));
                Yv *pb = yr_get(pr, "binds");
                Yv *ts = yav(0);
                for (long bi = 0; bi < yv_len(pb); bi++) ts = ya_push(ts, ya_get(pb, bi));
                ts = ya_push(ts, body);
                thens = ya_push(thens, yr(4, "k", yv_long(K_block), "stmts", ts, "line", yv_long(ln), "col", yv_long(cl)));
                Yv *pc = yr_get(pr, "cover");
                if (yv_l(yr_get(pc, "k")) != K_tnone) {
                    covers = ya_push(covers, pc);
                } else {
                    nvals = nvals + 1;
                }
            }
            if (go) {
                if (is_punct(toks, pos, ys(","))) {
                    pos = pos + 1;
                } else if (is_punct(toks, pos, ys("}"))) {
                    ;
                } else {
                    tests = ya_push(tests, yr(4, "k", yv_long(K_err), "msg", ys_cat(ys_cat(ys("expected ',' or '}' after a match arm, got '"), tv(toks, pos)), ys("'")), "line", yv_long(tline(toks, pos)), "col", yv_long(tcol(toks, pos))));
                    thens = ya_push(
                        thens,
                        block1(yr(3, "k", yv_long(K_void), "line", yv_long(ln),
                                 "col", yv_long(cl)),
                               ln, cl));
                    go = 0;
                }
            }
        }
    }
    Yv *chain = block1(yr(6, "k", yv_long(K_matchend), "e", yr(4, "k", yv_long(K_id), "v", tmp, "line", yv_long(ln), "col", yv_long(cl)), "cover", covers, "vals", yv_long(nvals), "line", yv_long(ln), "col", yv_long(cl)), ln, cl);
    if (has_wild) {
        chain = block1(fallback, ln, cl);
    }
    long i = yv_len(tests) - 1;
    while (i >= 0) {
        chain = yr(7, "k", yv_long(K_kw_if), "cond", ya_get(tests, i), "then", ya_get(thens, i), "els", chain, "has_else", yv_bool(1), "line", yv_long(ln), "col", yv_long(cl));
        i = i - 1;
    }
    Yv *stmts = yav(0);
    stmts = ya_push(stmts, yr(7, "k", yv_long(K_decl), "kind", ys("let"), "name", tmp, "typ", yr(1, "k", yv_long(K_tnone)), "v", subj, "line", yv_long(ln), "col", yv_long(cl)));
    stmts = ya_push(stmts, chain);
    long endp = pos;
    if (is_punct(toks, pos, ys("}"))) {
        endp = pos + 1;
    }
    return res(yr(4, "k", yv_long(K_block), "stmts", stmts, "line", yv_long(ln), "col", yv_long(cl)), endp);
}

// An arm is any expression; `{}` there is the empty block (void), not an
// empty record.
Yv *parse_arm_body(Yv *toks, long p) {
    if (is_punct(toks, p, ys("{")) && is_punct(toks, p + 1, ys("}"))) {
        return res(yr(4, "k", yv_long(K_block), "stmts", yav(0), "line", yv_long(tline(toks, p)), "col", yv_long(tcol(toks, p))), p + 2);
    } else {
        return parse_expr(toks, p);
    }
}

Yv *pat_res(Yv *test, Yv *binds, Yv *cover, int wild, long pos) {
    return yr(5, "test", test, "binds", binds, "cover", cover, "wild", yv_bool(wild), "pos", yv_long(pos));
}

Yv *let_node(Yv *name, Yv *v, long ln, long cl) {
    return yr(7, "k", yv_long(K_decl), "kind", ys("let"), "name", name, "typ", yr(1, "k", yv_long(K_tnone)), "v", v, "line", yv_long(ln), "col", yv_long(cl));
}

static Yv *subj_id(Yv *tmp, long ln, long cl) {
    return yr(4, "k", yv_long(K_id), "v", tmp, "line", yv_long(ln), "col", yv_long(cl));
}

Yv *parse_pattern(Yv *toks, long p, Yv *tmp) {
    long ln = tline(toks, p);
    long cl = tcol(toks, p);
    Yv *t = tt(toks, p);
    Yv *v = tv(toks, p);
    Yv *subj = subj_id(tmp, ln, cl);
    Yv *nob = yav(0);
    if (ys_eq_lit(t, "id") && ys_eq_lit(v, "_")) {
        return pat_res(yr(3, "k", yv_long(K_void), "line", yv_long(ln), "col",
                          yv_long(cl)),
                       nob, yr(1, "k", yv_long(K_tnone)), 1, p + 1);
    } else if (ys_eq_lit(t, "id") && !ys_eq_lit(v, "none")) {
        return parse_type_pattern(toks, p, tmp);
    } else if (is_punct(toks, p, ys("{"))) {
        Yv *rm = parse_map(toks, p);
        return parse_value_pattern(toks, yr_get(rm, "node"), yv_l(yr_get(rm, "pos")), tmp, ln, cl);
    } else if (is_punct(toks, p, ys("("))) {
        Yv *rp = parse_primary(toks, p);
        return parse_value_pattern(toks, yr_get(rp, "node"), yv_l(yr_get(rp, "pos")), tmp, ln, cl);
    } else {
        Yv *ru = parse_unary(toks, p);
        return pat_res(yr(6, "k", yv_long(K_bin), "op", ys("=="), "l", subj, "r", yr_get(ru, "node"), "line", yv_long(ln), "col", yv_long(cl)), nob, yr(1, "k", yv_long(K_tnone)), 0, yv_l(yr_get(ru, "pos")));
    }
}

static Yv *narrow_node(Yv *subj, Yv *ty, long ln, long cl) {
    return yr(5, "k", yv_long(K_narrow), "e", subj, "typ", ty, "line", yv_long(ln), "col", yv_long(cl));
}

// T / T x / T {f, g: y}: T names a record type (an alias).
Yv *parse_type_pattern(Yv *toks, long p, Yv *tmp) {
    long ln = tline(toks, p);
    long cl = tcol(toks, p);
    Yv *tname = tv(toks, p);
    long pos = p + 1;
    if (is_op(toks, pos, ys(".")) && ys_eq_lit(tt(toks, pos + 1), "id")) {
        tname = ys_cat(ys_cat(tname, ys(".")), tv(toks, pos + 1));
        pos = pos + 2;
    }
    Yv *ty = yr(2, "k", yv_long(K_tname), "name", tname);
    Yv *subj = subj_id(tmp, ln, cl);
    Yv *binds = yav(0);
    if (is_punct(toks, pos, ys("{"))) {
        pos = pos + 1;
        int go = !is_punct(toks, pos, ys("}"));
        while (go) {
            Yv *fname = tv(toks, pos);
            Yv *bname = fname;
            pos = pos + 1;
            if (is_punct(toks, pos, ys(":"))) {
                bname = tv(toks, pos + 1);
                pos = pos + 2;
            }
            Yv *fread = yr(5, "k", yv_long(K_dot), "obj", narrow_node(subj, ty, ln, cl), "key", fname, "line", yv_long(ln), "col", yv_long(cl));
            binds = ya_push(binds, let_node(bname, fread, ln, cl));
            if (is_punct(toks, pos, ys(","))) {
                pos = pos + 1;
                go = !is_punct(toks, pos, ys("}"));
            } else {
                go = 0;
            }
        }
        if (is_punct(toks, pos, ys("}"))) {
            pos = pos + 1;
        } else {
            binds = ya_push(binds, yr(4, "k", yv_long(K_err), "msg", ys_cat(ys_cat(ys("expected '}' to close the field list, got '"), tv(toks, pos)), ys("'")), "line", yv_long(tline(toks, pos)), "col", yv_long(tcol(toks, pos))));
        }
    } else if (ys_eq_lit(tt(toks, pos), "id")) {
        binds = ya_push(binds, let_node(tv(toks, pos), narrow_node(subj, ty, ln, cl), ln, cl));
        pos = pos + 1;
    }
    return pat_res(yr(5, "k", yv_long(K_rectest), "e", subj, "typ", ty, "line", yv_long(ln), "col", yv_long(cl)), binds, ty, 0, pos);
}

// A parsed value pattern: a record literal matches by its fields, any
// other expression by equality. An identifier after it binds the subject.
Yv *parse_value_pattern(Yv *toks, Yv *node, long pos, Yv *tmp, long ln, long cl) {
    Yv *subj = subj_id(tmp, ln, cl);
    Yv *binds = yav(0);
    Yv *k = yr_get(node, "k");
    if (yv_l(k) == K_rec) {
        Yv *keys = yr_get(node, "keys");
        Yv *vals = yr_get(node, "vals");
        Yv *ty = yr(2, "k", yv_long(K_tpat), "names", keys);
        Yv *test = yr(5, "k", yv_long(K_rectest), "e", subj, "typ", ty, "line", yv_long(ln), "col", yv_long(cl));
        long i = 0;
        while (i < yv_len(keys)) {
            Yv *key = ya_get(keys, i);
            if (ys_eq_lit(key, "...")) {
                test = yr(4, "k", yv_long(K_err), "msg", ys("'...' is not allowed in a match pattern"), "line", yv_long(ln), "col", yv_long(cl));
            } else {
                Yv *fread = yr(5, "k", yv_long(K_dot), "obj", narrow_node(subj, ty, ln, cl), "key", key, "line", yv_long(ln), "col", yv_long(cl));
                test = yr(6, "k", yv_long(K_bin), "op", ys("&&"), "l", test, "r", yr(6, "k", yv_long(K_bin), "op", ys("=="), "l", fread, "r", ya_get(vals, i), "line", yv_long(ln), "col", yv_long(cl)), "line", yv_long(ln), "col", yv_long(cl));
            }
            i = i + 1;
        }
        long np = pos;
        if (ys_eq_lit(tt(toks, pos), "id")) {
            binds = ya_push(binds, let_node(tv(toks, pos), narrow_node(subj, ty, ln, cl), ln, cl));
            np = pos + 1;
        }
        return pat_res(test, binds, yr(1, "k", yv_long(K_tnone)), 0, np);
    } else {
        long np = pos;
        if (ys_eq_lit(tt(toks, pos), "id")) {
            binds = ya_push(binds, let_node(tv(toks, pos), subj, ln, cl));
            np = pos + 1;
        }
        return pat_res(yr(6, "k", yv_long(K_bin), "op", ys("=="), "l", subj, "r", node, "line", yv_long(ln), "col", yv_long(cl)), binds, yr(1, "k", yv_long(K_tnone)), 0, np);
    }
}

// ── top level: a program is a block of statements (no surrounding braces) ─

Yv *parse_program(Yv *toks) {
    Yv *stmts = yav(0);
    long pos = 0;
    while (!ys_eq_lit(tt(toks, pos), "eof")) {
        long before = pos;
        Yv *s = parse_stmt(toks, pos);
        Yv *snode = yr_get(s, "node");
        stmts = ya_push(stmts, snode);
        pos = stmt_end(toks, before, yv_l(yr_get(s, "pos")), snode, stmts);
        // safety: if a statement made no progress, bail to avoid infinite loop
        // NOTE: `0;` tail — the while body must be void-typed (see note).
        if (pos == before) {
            pos = pos + 1;
            ;
        } else {
            ;
        }
        ;
    }
    return yr(4, "k", yv_long(K_block), "stmts", stmts, "line", yv_long(1), "col", yv_long(1));
}

// export { parse_program, parse_type_full, nameix_new, nameix_put,
//          nameix_get };  (exported via parser.h)

// ── a name index (types.y lookup, lint.y) ─────────────────────────────────
// str -> long, the last put of a name wins: open addressing over a power
// of two, doubled at half full ("" is no key: it marks a free slot).
// NameIx = { keys: [str], vals: [long], n: long }.
Yv *nameix_new(long cap) {
    Yv *keys = yav(0);
    Yv *vals = yav(0);
    long i = 0;
    while (i < cap) {
        keys = ya_push(keys, ys(""));
        vals = ya_push(vals, yv_long(0));
        i = i + 1;
    }
    return yr(3, "keys", keys, "vals", vals, "n", yv_long(0));
}

// The slot of k in keys: where it is, or the free one it would take.
static long nameix_slot(Yv *keys, Yv *k) {
    long mask = yv_len(keys) - 1;
    long h = 0;
    long i = 0;
    while (i < yv_len(k)) {
        h = (h * 31 + ys_byte_at(k, i)) & 1073741823;
        i = i + 1;
    }
    long s = (h ^ (h >> 15)) & mask;
    int go = 1;
    while (go) {
        Yv *e = ya_get(keys, s);
        if (ys_eq_lit(e, "") || ys_eq(e, k)) {
            go = 0;
        } else {
            s = (s + 1) & mask;
        }
    }
    return s;
}

void nameix_put(Yv *m, Yv *k, long v) {
    if ((yv_l(yr_get(m, "n")) + 1) * 2 > yv_len(yr_get(m, "keys"))) {
        Yv *ok = yr_get(m, "keys");
        Yv *ov = yr_get(m, "vals");
        Yv *big = nameix_new(yv_len(ok) * 2);
        Yv *bk = yr_get(big, "keys");
        Yv *bv = yr_get(big, "vals");
        long i = 0;
        while (i < yv_len(ok)) {
            Yv *e = ya_get(ok, i);
            if (!ys_eq_lit(e, "")) {
                long s = nameix_slot(bk, e);
                ya_set(bk, s, e);
                ya_set(bv, s, ya_get(ov, i));
            }
            i = i + 1;
        }
        yr_set(m, "keys", bk);
        yr_set(m, "vals", bv);
    }
    Yv *keys = yr_get(m, "keys");
    Yv *vals = yr_get(m, "vals");
    long s = nameix_slot(keys, k);
    Yv *e = ya_get(keys, s);
    if (ys_eq_lit(e, "")) {
        yr_set(m, "n", yv_long(yv_l(yr_get(m, "n")) + 1));
    }
    ya_set(keys, s, k);
    ya_set(vals, s, yv_long(v));
}

// The value put last for k, or -1.
long nameix_get(Yv *m, Yv *k) {
    Yv *keys = yr_get(m, "keys");
    long s = nameix_slot(keys, k);
    Yv *e = ya_get(keys, s);
    if (ys_eq_lit(e, "")) {
        return -1;
    } else {
        return yv_l(ya_get(yr_get(m, "vals"), s));
    }
}
