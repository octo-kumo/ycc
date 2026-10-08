/* lint.c — warnings, the 1:1 port of src/y/lint.y (see PORTING.md).
 *
 * What looks like a mistake in a program that compiles. native.c
 * compile_unit runs lint_unit on the program's unit (and each package's,
 * under `ycc build`) once it typechecked; the driver prints what comes
 * back as `FILE:LINE:COL: warning: MSG` on stderr (ycc.c
 * print_native_warnings), unless `-w`. A warning never changes the
 * program: the unit compiles to the same bytes either way.
 *
 * Two walks:
 * - the renamed tree (rename.c: every binding is `orig$N`, N unique in
 *   the unit): a value computed and dropped, code after a `return`, a
 *   local never read (or only written), `x = x`, `x < x`, a division by
 *   a literal zero, a record or map literal giving one key twice;
 * - the parse tree, where annotations read as written: a record or union
 *   type written out in full more than once (`type` names it), or where
 *   an alias already names it; two aliases naming one type; one alias
 *   declared twice.
 *
 * Parameters, loop variables, top-level bindings and any name starting
 * with `_` are exempt from the unused-binding rules. */
#include "ylong.h"
#include "lexer.h"
#include "lint.h"
#include "tags.h"

#include <stdarg.h>

#include "types.h"
#include "parser.h"

/* types.y's alias (lint.y imports types.y) */
typedef Yv *Diag;
typedef Yv *LintVar;
typedef Yv *LintSt;
typedef Yv *LintRoot;
typedef Yv *LintOcc;
typedef Yv *LintTy;

/* ── module-local defs (forward) ─────────────────────────────────────── */
static Yv *lint_cat(size_t n, ...);
static ylong lint_warn(LintSt st, Yv *msg, ylong line, ylong col);
static Yv *lint_disp(Yv *name);
static ylong lint_num(Yv *name);
static ylong lint_mark(LintSt st, Yv *name, ylong bit);
static ylong lint_note(LintSt st, Yv *name, Yv *kind, ylong line, ylong col,
                      int scal, int fresh, int strf, int vec, int untyped);
static ylong lint_note_top(LintSt st, Yv *node);
static ylong lint_top_first(LintSt st, Yv *d, ylong fid);
static ylong lint_file_of(ylong ln);
static int lint_strheld(Yv *typ, Yv *v);
static int lint_var_str(LintSt st, Yv *name);
static int lint_var_scal(LintSt st, Yv *name);
static int lint_tscal(Yv *typ);
static int lint_vec(Yv *typ, Yv *v);
static int lint_var_vec(LintSt st, Yv *name);
static ylong lint_note_param(LintSt st, Yv *name, Yv *typ, ylong line, ylong col);
static ylong lint_int_val(Yv *node);
static int lint_compound_op(Yv *op);
static int lint_same_node(Yv *a, Yv *b);
static int lint_slice_one(Yv *lo, Yv *hi);
static int lint_str_expr(LintSt st, Yv *node);
static Yv *lint_operand(Yv *node);
static ylong lint_short_assign(LintSt st, Yv *node, Yv *name, Yv *v);
static ylong lint_short_bin(LintSt st, Yv *node);
static ylong lint_short_call(LintSt st, Yv *call);
static int lint_short_ord(LintSt st, Yv *call);
static ylong lint_short_slice(LintSt st, Yv *node);
static ylong lint_short_chain(LintSt st, Yv *node);
static ylong lint_chain_leaves(Yv *node, Yv *out);
static Yv *lint_single_stmt(Yv *block);
static Yv *lint_first_stmt(Yv *block);
static ylong lint_bool_lit(Yv *node);
static int lint_pure(Yv *node);
static ylong lint_short_empty_if(LintSt st, Yv *node);
static ylong lint_short_if_ternary(LintSt st, Yv *node);
static ylong lint_short_if(LintSt st, Yv *node);
static ylong lint_short_if_chain(LintSt st, Yv *node);
static Yv *lint_eq_name(Yv *cond);
static int lint_is_lit(Yv *node);
static ylong lint_short_foreach_elem(LintSt st, Yv *call);
static ylong lint_short_none(LintSt st, Yv *stmts, ylong i);
static Yv *lint_none_test(Yv *cond);
static ylong lint_short_flag(LintSt st, Yv *stmts, ylong i);
static int lint_flag_cond(Yv *cond, Yv *name);
static Yv *lint_flat_body(Yv *body);
static ylong lint_alias_param(LintSt st, Yv *node);
static ylong lint_short_pair(LintSt st, Yv *stmts, ylong i);
static ylong lint_short_while(LintSt st, Yv *loop);
static int lint_find(Yv *node, Yv *name, ylong mask);
static int lint_find_list(Yv *nodes, Yv *name, ylong mask);
static int lint_resizes(Yv *node, Yv *name);
static int lint_unwraps(Yv *node, Yv *name);
static int lint_stores_index(Yv *node, Yv *name);
static int lint_index_of(Yv *tgt, Yv *name);
static int lint_resize_method(Yv *key);
static int lint_find_from(Yv *nodes, ylong from, Yv *name, ylong mask);
static int lint_step_one(Yv *body, Yv *iv);
static Yv *lint_len_of(Yv *node);
static ylong lint_short_index_loop(LintSt st, Yv *stmts, ylong i);
static ylong lint_short_range(LintSt st, Yv *fe);
static Yv *lint_range_arr(Yv *node);
static ylong lint_loop_body(LintSt st, Yv *body);
static ylong lint_stmts(LintSt st, Yv *stmts, int used, int top);
static ylong lint_warn_at(LintSt st, Yv *msg, Yv *node);
static ylong lint_warn_start(LintSt st, Yv *msg, Yv *node);
static ylong lint_meta_top(LintSt st, Yv *stmts, Yv *ogen);
static int meta_gen(Yv *s, Yv *ogen);
static ylong lint_stmt(LintSt st, Yv *s, int used, int top);
static int lint_const_node(Yv *s);
/* A void def's body drops its value, so the TAIL of it is a statement: the
 * level-1 "value not used" warnings stay quiet there. */
static int lint_droptail(LintSt st) {
    return yv_b(yr_get(st, "voidfn")) && yv_b(yr_get(st, "tailflow"));
}
static int lint_code(Yv *s);
static int lint_diverges(Yv *s);
static int lint_any_diverges(Yv *stmts);
static ylong lint_rets(LintSt st, Yv *stmts);
static ylong lint_rets_node(LintSt st, Yv *node);
static Yv *lint_binding(LintSt st, Yv *callee);
static int lint_returns(LintSt st, Yv *callee);
static Yv *lint_self(LintSt st, Yv *name);
static ylong lint_def_body(LintSt st, Yv *name, Yv *v);
static ylong lint_unused_call(LintSt st, Yv *node, int used, Yv *call);
static ylong lint_unused_expr(LintSt st, Yv *node, int used);
static ylong lint_node(LintSt st, Yv *node, int used);
static ylong lint_one(LintSt st, Yv *node, int used);
static ylong lint_list(LintSt st, Yv *nodes);
static ylong lint_two(LintSt st, Yv *a, Yv *b);
static ylong lint_id(LintSt st, Yv *node, int used);
static ylong lint_un(LintSt st, Yv *node, int used);
static ylong lint_bin(LintSt st, Yv *node, int used);
static int lint_same_id(Yv *l, Yv *r);
static int lint_effect(Yv *node);
static int lint_effect_logic(Yv *node);
static int lint_zero(Yv *node);
static int lint_zero_text(Yv *s);
static ylong lint_if(LintSt st, Yv *node, int used);
static ylong lint_if_conds(LintSt st, Yv *head);
static int lint_empty_arm(Yv *n);
static ylong lint_for(LintSt st, Yv *node);
static ylong lint_func(LintSt st, Yv *node);
static ylong lint_decl(LintSt st, Yv *node);
static int lint_scal(Yv *typ, Yv *v);
static int lint_fresh(Yv *v);
static ylong lint_assign(LintSt st, Yv *node);
static ylong lint_incdec(LintSt st, Yv *node, int used);
static ylong lint_opassign(LintSt st, Yv *node, int used);
static ylong lint_lit(LintSt st, Yv *node, Yv *what, Yv *kind);
static int lint_seen(Yv *keys, ylong i);
static ylong lint_vars(LintSt st);
static Yv *lint_word(Yv *kind);
static ylong lint_types(LintSt st, Yv *stmts);
static ylong lint_tw_list(LintTy t, Yv *nodes);
static ylong lint_tw(LintTy t, Yv *node);
static ylong lint_tw_one(LintTy t, Yv *node);
static ylong lint_tw_decl(LintTy t, Yv *node);
static ylong lint_tw_func(LintTy t, Yv *node);
static ylong lint_root(LintTy t, Yv *typ, ylong line, ylong col, Yv *alias);
static Yv *lint_mod_of(ylong ln);
static int lint_cand(Yv *ty);
static Yv *lint_tk(LintTy t, Yv *ty, int rec, ylong parent);
static Yv *lint_tk_list(LintTy t, Yv *ts, int rec, ylong parent);
static Yv *lint_tk_name(LintTy t, Yv *name);
static Yv *lint_tk_rec(LintTy t, Yv *ty, int rec, ylong parent);
static Yv *lint_tk_union(LintTy t, Yv *ty, int rec, ylong parent);
static ylong lint_tk_members(LintTy t, Yv *u, int rec, ylong me, Yv *parts);
static ylong lint_union_alias(LintTy t, Yv *m);
static int lint_is_union(Yv *ty);
static ylong lint_occ(LintTy t, Yv *ty, ylong parent);
static ylong lint_occ_key(LintTy t, ylong i, Yv *key);
static Yv *lint_sort_uniq(Yv *xs);
static ylong lint_report(LintSt st, LintTy t);
static int lint_rep(Yv *occs, ylong i);
static Yv *lint_sorted(Yv *ws);
static Yv *lint_msort(Yv *ws);
static int lint_before(Diag a, Diag b);

/* `a + b + ...` (C only: Y's `+` chains, left to right). */
static Yv *lint_cat(size_t n, ...) {
    va_list ap;
    va_start(ap, n);
    if (n == 0) {
        va_end(ap);
        return ys("");
    }
    Yv *out = va_arg(ap, Yv *);
    for (size_t i = 1; i < n; i++) {
        out = ys_cat(out, va_arg(ap, Yv *));
    }
    va_end(ap);
    return out;
}

/* Which lines are a module's (rename.c rename_program_x): line i + 1 is
 * in file lint_ofile[i], module lint_fmods of it ("" for none). */
static Yv *lint_ofile;
/* A call whose value is dropped; emitted after the walk (a def whose value
 * is read somewhere is a value-returning def, and ignoring it is a choice). */
static Yv *lint_drops;
static Yv *lint_fmods;

/* The warnings for one unit: `ast` as parsed, `ast3` renamed (and
 * checked), sorted by position; ofile and fmods say which lines are a
 * module's. */
/* The warnings for one unit: `ast` as parsed, `ast3` renamed (and
 * checked), sorted by position; ofile and fmods say which lines are a
 * module's. `ogen` says which lines a meta block generated (see
 * lint_meta_top); it is empty when the unit has no blocks. */
Yv *lint_unit(Yv *ast, Yv *ast3, Yv *ofile, Yv *fmods, ylong wlevel, Yv *ogen,
              Yv *unused) {
    lint_ofile = ofile;
    lint_fmods = fmods;
    lint_drops = yav(0);
    Yv *warns = yav(0);
    Yv *vars = yav(0);
    Yv *flags = yav(0);
    Yv *rets = yav(0);
    LintSt st = yr(18, "warns", warns, "vars", vars, "tops",
                   nameix_new(256), "flags", flags, "rets",
                   rets, "ridx", nameix_new(64), "self", ys(""), "wlevel",
                   yv_long(wlevel), "dropnext", yv_bool(0), "vused",
                   yv_bool(0), "loops", yv_long(0), "logic", yv_long(0),
                   "voidfn", yv_bool(0), "tailflow", yv_bool(0), "chain", yv_long(0),
                   "reads", yav(0), "rline", yav(0), "rcol", yav(0));
    if (wlevel >= 1) {
        (void)lint_rets(st, yr_get(ast3, "stmts"));
    }
    (void)lint_stmts(st, yr_get(ast3, "stmts"), 0, 1);
    if (yv_len(ogen) > 0) {
        (void)lint_meta_top(st, yr_get(ast3, "stmts"), ogen);
    };
    (void)lint_vars(st);
    /* Level 1: a bare import nothing uses (the resolver found it: it has the
     * text, and the import is gone from the spliced program). */
    if (wlevel >= 1) {
        for (ylong ui = 0; ui < yv_len(unused); ui++) {
            Yv *u = ya_get(unused, ui);
            (void)lint_warn(st, yr_get(u, "msg"), yv_l(yr_get(u, "line")),
                            yv_l(yr_get(u, "col")));
        }
    }
    (void)lint_types(st, yr_get(ast, "stmts"));
    /* Level 1: a dropped call, but only for a def no call reads. */
    for (ylong i = 0; i < yv_len(lint_drops); i++) {
        Yv *dr = ya_get(lint_drops, i);
        ylong ci = yv_l(yr_get(dr, "callee"));
        if (yv_l(yr_get(ya_get(rets, ci), "used")) == 0) {
            (void)lint_warn(st,
                            lint_cat(3, ys("the value of '"),
                                     yr_get(dr, "name"),
                                     ys("()' is not used")),
                            yv_l(yr_get(dr, "line")),
                            yv_l(yr_get(dr, "col")));
        }
    }
    return lint_sorted(yr_get(st, "warns"));
}

/* A statement starting on a line a meta block generated. Its line is the
 * `#{` line (every generated line carries it, see mg_splice), and the ORIGIN
 * map is what turns a program line back into a source line -- so `ogen` is
 * indexed by the source line, and lint's own map says which source line a
 * statement sits on. */
static int meta_gen(Yv *s, Yv *ogen) {
    ylong ln = yv_l(yr_get(s, "line")) - 1;
    if (ln < 0 || ln >= yv_len(ogen)) { return 0; }
    else { return yv_truth(ya_get(ogen, ln)); }
}

/* `ogen` is EMPTY for a unit with no meta blocks (see resolve_unit), so its
 * length is the answer to "is this file's top level also a generator's?", and
 * its entries say which lines a block generated. */

/* With blocks in the file, the top level IS the generator's program, so every
 * top-level statement there runs once in the generator and once in the program.
 * That is fine for a declaration -- a `def` hoists, and a `let` a block reads
 * should be pure (the manual says so) -- and for the text a block GENERATED,
 * which the program runs once and the generator never ran at all: `ogen`
 * (indexed by the statement's line) says which lines those are. Anything else
 * is a statement with side effects the reader cannot see running twice. */
static ylong lint_meta_top(LintSt st, Yv *stmts, Yv *ogen) {
    ylong i = 0;
    while (i < yv_len(stmts)) {
        Yv *s = ya_get(stmts, i);
        if (yv_l(yr_get(s, "k")) != K_decl && yv_l(yr_get(s, "k")) != K_void &&
            !meta_gen(s, ogen)) {
            (void)lint_warn_start(st, ys("a top-level statement runs once in the meta generator and once in the program, so with a meta block in the file it must be a declaration (a def, type, const or let) -- keep a top-level let initializer pure"), s);
        };
        i = i + 1;
    };
    return 0;
}

static ylong lint_warn(LintSt st, Yv *msg, ylong line, ylong col) {
    (void)ya_push(yr_get(st, "warns"), yr(3, "msg", msg, "line",
                                          yv_long(line), "col",
                                          yv_long(col)));
    return 0;
}

/* ── the renamed tree ────────────────────────────────────────────────── */

/* The name a binding was written with: `orig$N` less `$N` (and a shadowed
 * def's `$shadowI`); "" for one the parser made up (a match subject). */
static Yv *lint_disp(Yv *name) {
    ylong d = ys_index_of(name, ys("$"));
    if (d < 0) {
        return name;
    } else {
        return ys_slice(name, 0, d);
    }
}

/* N of a renamed binding `orig$N`, or 0 for a name rename.c left alone (a
 * builtin, `self`, a package's qualified name). N counts from 1. */
static ylong lint_num(Yv *name) {
    ylong i = yv_len(name) - 1;
    ylong v = 0;
    ylong m = 1;
    int go = 1;
    while (go && i >= 0) {
        ylong c = ys_byte_at(name, i);
        if (c >= 48 && c <= 57) {
            v = v + (c - '0') * m;
            m = m * 10;
            i = i - 1;
        } else {
            go = 0;
        }
    }
    if (i >= 0 && m > 1 && ys_byte_at(name, i) == 36) {
        return v;
    } else {
        return 0;
    }
}

/* What happened to a binding, by its N: 1 read, 2 assigned, 4 grown
 * (`+=`/`*=`, which on an array is visible through every alias). */
static ylong lint_mark(LintSt st, Yv *name, ylong bit) {
    ylong n = lint_num(name);
    if (n > 0) {
        Yv *fl = yr_get(st, "flags");
        while (yv_len(fl) <= n) {
            fl = ya_push(fl, yv_long(0));
        }
        ya_set(fl, n, yv_long(yv_l(ya_get(fl, n)) | bit));
    }
    return 0;
}

/* A local binding (let, const, nested def), checked for use at the end.
 * `scal`: it holds a number, string or bool, whose `+=` makes a new value
 * only it sees. `fresh`: it starts as an array literal no one else holds. */
static ylong lint_note(LintSt st, Yv *name, Yv *kind, ylong line, ylong col,
                       int scal, int fresh, int strf, int vec, int untyped) {
    Yv *d = lint_disp(name);
    if (!ys_eq_lit(d, "") && ys_byte_at(d, 0) != 95 &&
        ys_index_of(name, ys("$shadow")) < 0) {
        (void)ya_push(yr_get(st, "vars"),
                      yr(11, "name", d, "kind", kind, "num",
                         yv_long(lint_num(name)), "line", yv_long(line),
                         "col", yv_long(col), "scal", yv_bool(scal),
                         "fresh", yv_bool(fresh), "strf", yv_bool(strf),
                         "top", yv_bool(0), "vec", yv_bool(vec),
                         "untyped", yv_bool(untyped)));
    }
    return 0;
}

/* A top-level binding: a global. Recorded, because the value-used append
 * check needs to know whether the name holds a string, and marked `top` so
 * lint_vars leaves it alone -- a global that nothing in this unit reads is
 * not an unused variable (another unit of the program may read it). */
static ylong lint_note_top(LintSt st, Yv *node) {
    Yv *name = yr_get(node, "name");
    Yv *v = yr_get(node, "v");
    Yv *d = lint_disp(name);
    ylong line = yv_l(yr_get(node, "line"));
    ylong col = yv_l(yr_get(node, "col"));
    if (!ys_eq_lit(d, "") && ys_byte_at(d, 0) != 95) {
        /* A name bound twice at the top level is legal -- the later
         * declaration shadows the earlier one, which t14_shadow, t30 and
         * t53 all pin -- and rename.y keeps the earlier one under its
         * `$shadow` name so a self call inside it still binds to itself.
         * What is not legal is not knowing which copy is running: a
         * copy-paste that leaves an old definition behind shadows the new
         * one silently, and every read of the source shows the copy that is
         * not the one called. A warning is the whole of it (the same shape
         * the duplicate type alias gets); find_dup still rejects the
         * cross-file case outright, where there is no shadowing to mean. */
        ylong fid = lint_file_of(line);
        ylong first = lint_top_first(st, d, fid);
        if (first > 0) {
            Yv *m1 = ys_cat(ys_cat(ys("'"), d),
                            ys("' is declared more than once; the last declaration counts (the earlier one at line "));
            Yv *m2 = ys_cat(m1, ys_fmt("%lld", (long long)first));
            (void)lint_warn(st, ys_cat(m2, ys(")")), line, col);
        }
        /* recorded either way: the map holds where each name was declared
         * LAST, so a third declaration names the second */
        nameix_put(yr_get(st, "tops"), d, line);
        if (first == 0) {
            (void)ya_push(yr_get(st, "vars"),
                          yr(10, "name", d, "kind", yr_get(node, "kind"), "num",
                             yv_long(lint_num(name)), "line", yv_long(line),
                             "col", yv_long(col), "scal",
                             yv_bool(lint_scal(yr_get(node, "typ"), v)), "fresh",
                             yv_bool(lint_fresh(v)), "strf",
                             yv_bool(lint_strheld(yr_get(node, "typ"), v)),
                             "top", yv_bool(1), "vec",
                             yv_bool(lint_vec(yr_get(node, "typ"), v))));
        }
    }
    return 0;
}

/* Where a top-level name was declared last, if that was in this file (0
 * otherwise). Only the names this check records count, so a local of the
 * same name never shadows a global's warning (different scopes, and lint
 * has no scope). The file matters: a path-imported unit shares the
 * program's namespace -- t134 pins that a module global may share the
 * program's name -- so only two declarations of one file are the
 * copy-paste this names. */
static ylong lint_top_first(LintSt st, Yv *d, ylong fid) {
    ylong prev = nameix_get(yr_get(st, "tops"), d);
    if (prev > 0 && lint_file_of(prev) == fid) {
        return prev;
    }
    return 0;
}

/* The file the line ln is in, 0 for the program's own text and for a line
 * past the origin table. */
static ylong lint_file_of(ylong ln) {
    if (ln >= 1 && ln <= yv_len(lint_ofile)) {
        return yv_l(ya_get(lint_ofile, ln - 1));
    }
    return 0;
}

/* A binding that holds a string, as far as the syntax shows: annotated
 * `str`, or initialised with a string literal. Deliberately a syntactic
 * question, not a type one -- lint never runs the checker -- so a binding
 * whose string-ness is only visible from a call's return is simply not
 * flagged. The check it feeds is advice, so a miss is a miss and never a
 * wrong warning. */
static int lint_strheld(Yv *typ, Yv *v) {
    if (yv_l(yr_get(typ, "k")) == K_tstr) {
        return 1;
    }
    return yv_l(yr_get(v, "k")) == K_str;
}

/* Whether the binding a name refers to was noted as holding a string (see
 * lint_strheld). A renamed binding is matched on rename.y's number, which
 * identifies the binding itself -- two locals spelled the same in two defs
 * are two bindings, and a match on the written name would let one of them
 * vouch for the other. A top-level binding is renamed to nothing (its name
 * is unique in the unit already, and lint_mark leaves globals alone for the
 * same reason: see the number), so those are matched on the name. */
static int lint_var_str(LintSt st, Yv *name) {
    ylong n = lint_num(name);
    Yv *d = lint_disp(name);
    Yv *vars = yr_get(st, "vars");
    ylong i = 0;
    while (i < yv_len(vars)) {
        Yv *v = ya_get(vars, i);
        if (yv_b(yr_get(v, "strf")) &&
            ((n > 0 && yv_l(yr_get(v, "num")) == n) ||
             (n == 0 && yv_l(yr_get(v, "num")) == 0 && ys_eq(yr_get(v, "name"), d)))) {
            return 1;
        }
        i = i + 1;
    }
    return 0;
}

/* Whether the binding holds a scalar (a number, string or bool). The
 * compound-assignment rule needs it: `x = x + e` is `x += e` only where
 * `+=` cannot be seen through an alias, and for an array it can. */
static int lint_var_scal(LintSt st, Yv *name) {
    ylong n = lint_num(name);
    Yv *d = lint_disp(name);
    Yv *vars = yr_get(st, "vars");
    ylong i = 0;
    while (i < yv_len(vars)) {
        Yv *v = ya_get(vars, i);
        if (yv_b(yr_get(v, "scal")) &&
            ((n > 0 && yv_l(yr_get(v, "num")) == n) ||
             (n == 0 && yv_l(yr_get(v, "num")) == 0 && ys_eq(yr_get(v, "name"), d)))) {
            return 1;
        }
        i = i + 1;
    }
    return 0;
}

/* Whether a type is a scalar, for a binding whose value the checker has
 * not been asked about (a parameter). */
static int lint_tscal(Yv *typ) {
    ylong k = yv_l(yr_get(typ, "k"));
    return k == K_tlong || k == K_tfloat || k == K_tbyte ||
           k == K_tstr || k == K_tbool;
}

/* Whether a type and initializer make a binding an array. A slice of a str
 * is not one, which is the case lint_var_str cannot see (it is not a str
 * literal): rules 3.1/3.5 need positive proof before they say `.foreach`. */
static int lint_vec(Yv *typ, Yv *v) {
    ylong k = yv_l(yr_get(typ, "k"));
    return k == K_tarr || k == K_tarrfix || lint_fresh(v);
}

/* Whether the binding a name refers to was noted as an array. */
static int lint_var_vec(LintSt st, Yv *name) {
    ylong n = lint_num(name);
    Yv *d = lint_disp(name);
    Yv *vars = yr_get(st, "vars");
    ylong i = 0;
    while (i < yv_len(vars)) {
        Yv *v = ya_get(vars, i);
        if (yv_b(yr_get(v, "vec")) &&
            ((n > 0 && yv_l(yr_get(v, "num")) == n) ||
             (n == 0 && yv_l(yr_get(v, "num")) == 0 && ys_eq(yr_get(v, "name"), d)))) {
            return 1;
        }
        i = i + 1;
    }
    return 0;
}

/* Note a parameter, so the shortening rules can tell a `str` or a number
 * from an array. `top` keeps lint_vars from calling it unused -- a
 * parameter is never that. */
static ylong lint_note_param(LintSt st, Yv *name, Yv *typ, ylong line, ylong col) {
    Yv *d = lint_disp(name);
    if (!ys_eq_lit(d, "") && ys_byte_at(d, 0) != 95) {
        (void)ya_push(yr_get(st, "vars"),
                      yr(10, "name", d, "kind", ys("param"), "num",
                         yv_long(lint_num(name)), "line", yv_long(line),
                         "col", yv_long(col), "scal", yv_bool(lint_tscal(typ)),
                         "fresh", yv_bool(0),
                         "strf", yv_bool(yv_l(yr_get(typ, "k")) == K_tstr),
                         "top", yv_bool(1), "vec",
                         yv_bool(yv_l(yr_get(typ, "k")) == K_tarr ||
                                 yv_l(yr_get(typ, "k")) == K_tarrfix)));
    }
    return 0;
}

/* A statement list: a block's, a function body's, the unit's. Only the
 * last statement's value is used, and only when the list's is. The first
 * statement after one that always returns never runs (a def there still
 * does: defs hoist). */
static ylong lint_stmts(LintSt st, Yv *stmts, int used, int top) {
    ylong n = yv_len(stmts);
    /* a flag for this list, if lint_loop_body marked it a dropped one */
    int drop = yv_b(yr_get(st, "dropnext"));
    (void)yr_set(st, "dropnext", yv_bool(0));
    int dead = 0;
    int told = 0;
    int wt = yv_b(yr_get(st, "tailflow"));
    ylong i = 0;
    while (i < n) {
        Yv *s = ya_get(stmts, i);
        if (dead && !told && lint_code(s)) {
            (void)lint_warn_start(st, ys("unreachable code"), s);
            told = 1;
        }
        (void)yr_set(st, "vused", yv_bool(!drop && i == n - 1));
        (void)yr_set(st, "tailflow", yv_bool(wt && i == n - 1));
        if (yv_l(yr_get(st, "wlevel")) >= 2) {
            (void)lint_short_pair(st, stmts, i);
        }
        /* Rule 2.13: the last statement of a list whose value is dropped is a
         * bare constant. It is dead -- the block's value goes nowhere. */
        if (i == n - 1 && n > 1 && !used && lint_const_node(s)) {
            (void)lint_warn_start(st,
                ys("the value of this block is not used; this constant does nothing"), s);
        }
        (void)lint_stmt(st, s, used && i == n - 1, top);
        if (!dead && lint_diverges(s)) {
            dead = 1;
        }
        i = i + 1;
    }
    (void)yr_set(st, "tailflow", yv_bool(wt));
    return 0;
}

static ylong lint_warn_at(LintSt st, Yv *msg, Yv *node) {
    return lint_warn(st, msg, yv_l(yr_get(node, "line")),
                     yv_l(yr_get(node, "col")));
}

/* At the first token of `node`: an operator's node sits at the operator,
 * a call's at its `(`. */
static ylong lint_warn_start(LintSt st, Yv *msg, Yv *node) {
    Yv *k = yr_get(node, "k");
    if (yv_l(k) == K_call) {
        return lint_warn_start(st, msg, yr_get(node, "callee"));
    } else if (yv_l(k) == K_bin) {
        return lint_warn_start(st, msg, yr_get(node, "l"));
    } else if (yv_l(k) == K_index || yv_l(k) == K_slice) {
        return lint_warn_start(st, msg, yr_get(node, "arr"));
    } else if (yv_l(k) == K_dot) {
        return lint_warn_start(st, msg, yr_get(node, "obj"));
    } else if (yv_l(k) == K_opassign ||
               (yv_l(k) == K_incdec && !yv_b(yr_get(node, "pre")))) {
        return lint_warn_start(st, msg, yr_get(node, "tgt"));
    } else {
        return lint_warn_at(st, msg, node);
    }
}

/* A top-level binding is a global: not checked for use. */
static ylong lint_stmt(LintSt st, Yv *s, int used, int top) {
    if (top && yv_l(yr_get(s, "k")) == K_decl) {
        /* a top-level binding is a global: its value is walked, not its
         * use, but a def's body still reaches itself through `self` */
        (void)lint_note_top(st, s);
        if (ys_eq_lit(yr_get(s, "kind"), "def")) {
            return lint_def_body(st, yr_get(s, "name"), yr_get(s, "v"));
        } else {
            return lint_node(st, yr_get(s, "v"), 1);
        }
    } else {
        return lint_node(st, s, used);
    }
}

/* Not the parser's trailing void, and not a def. */
/* A literal node: num, str, char, bool, bstr. A block that ends with one and
 * whose value is dropped computes nothing (rule 2.13). */
static int lint_const_node(Yv *s) {
    ylong k = yv_l(yr_get(s, "k"));
    return k == K_num || k == K_str || k == K_char || k == K_bool || k == K_bstr;
}

/* A constant array literal searched inside a loop (lint.y lint_loop_arr): a
 * new array every iteration. */
static void lint_loop_arr(LintSt st, Yv *n) {
    if (yv_l(yr_get(st, "loops")) > 0 && yv_l(yr_get(n, "k")) == K_array) {
        Yv *es = yr_get(n, "elems");
        int all = yv_len(es) > 0;
        ylong i = 0;
        while (all && i < yv_len(es)) {
            if (!lint_const_node(ya_get(es, i))) { all = 0; }
            i = i + 1;
        }
        if (all) { (void)lint_warn_at(st, ys("this array literal is built again on every iteration of the loop -- bind it once before the loop"), n); }
    }
}

/* A loop's condition or step: evaluated every iteration, like the body. */
static void lint_loop_head(LintSt st, Yv *n, int used) {
    (void)yr_set(st, "loops", yv_long(yv_l(yr_get(st, "loops")) + 1));
    (void)lint_node(st, n, used);
    (void)yr_set(st, "loops", yv_long(yv_l(yr_get(st, "loops")) - 1));
}

static int lint_code(Yv *s) {
    Yv *k = yr_get(s, "k");
    if (yv_l(k) == K_void) {
        return 0;
    } else if (yv_l(k) == K_decl) {
        return !ys_eq_lit(yr_get(s, "kind"), "def");
    } else {
        return 1;
    }
}

/* Whether a statement always leaves the function: a `return`, a block
 * holding one, an `if` whose two arms both do. */
static int lint_diverges(Yv *s) {
    Yv *k = yr_get(s, "k");
    if (yv_l(k) == K_ret) {
        return 1;
    } else if (yv_l(k) == K_block) {
        return lint_any_diverges(yr_get(s, "stmts"));
    } else if (yv_l(k) == K_kw_if) {
        return yv_b(yr_get(s, "has_else")) &&
               lint_diverges(yr_get(s, "then")) &&
               lint_diverges(yr_get(s, "els"));
    } else {
        return 0;
    }
}

static int lint_any_diverges(Yv *stmts) {
    int found = 0;
    ylong i = 0;
    while (!found && i < yv_len(stmts)) {
        found = lint_diverges(ya_get(stmts, i));
        i = i + 1;
    }
    return found;
}

/* One node; `used`: its value is consumed. The kinds most nodes have
 * come first. */
static ylong lint_node(LintSt st, Yv *node, int used) {
    Yv *k = yr_get(node, "k");
    if (yv_l(k) == K_id) {
        return lint_id(st, node, used);
    } else if (yv_l(k) == K_call) {
        (void)lint_node(st, yr_get(node, "callee"), 1);
        if (yv_l(yr_get(yr_get(node, "callee"), "k")) == K_dot) {
            lint_loop_arr(st, yr_get(yr_get(node, "callee"), "obj"));
        }
        if (yv_l(yr_get(st, "wlevel")) < 2 || !lint_short_ord(st, node)) {
            (void)lint_list(st, yr_get(node, "args"));
        }
        if (yv_l(yr_get(st, "wlevel")) >= 2) {
            (void)lint_short_call(st, node);
            (void)lint_short_foreach_elem(st, node);
        }
        return lint_unused_call(st, node, used, node);
    } else if (yv_l(k) == K_dot) {
        (void)lint_node(st, yr_get(node, "obj"), 1);
        return lint_unused_expr(st, node, used);
    } else if (yv_l(k) == K_str || yv_l(k) == K_num) {
        return 0;
    } else if (yv_l(k) == K_bin) {
        return lint_bin(st, node, used);
    } else if (yv_l(k) == K_decl) {
        return lint_decl(st, node);
    } else if (yv_l(k) == K_block) {
        return lint_stmts(st, yr_get(node, "stmts"), used, 0);
    } else if (yv_l(k) == K_kw_if) {
        return lint_if(st, node, used);
    } else if (yv_l(k) == K_assign) {
        return lint_assign(st, node);
    } else if (yv_l(k) == K_index) {
        (void)lint_two(st, yr_get(node, "arr"), yr_get(node, "idx"));
        return lint_unused_expr(st, node, used);
    } else if (yv_l(k) == K_rec) {
        (void)lint_lit(st, node, ys("field"), ys("record"));
        return lint_unused_expr(st, node, used);
    } else if (yv_l(k) == K_array) {
        (void)lint_list(st, yr_get(node, "elems"));
        return lint_unused_expr(st, node, used);
    } else if (yv_l(k) == K_ret || yv_l(k) == K_un ||
               yv_l(k) == K_addr || yv_l(k) == K_deref ||
               yv_l(k) == K_rectest || yv_l(k) == K_narrow ||
               yv_l(k) == K_matchend) {
        return lint_one(st, node, used);
    } else if (yv_l(k) == K_opassign) {
        return lint_opassign(st, node, used);
    } else if (yv_l(k) == K_kw_while) {
        lint_loop_head(st, yr_get(node, "cond"), 1);
        if (yv_l(yr_get(st, "wlevel")) >= 1 && lint_bool_lit(yr_get(node, "cond")) == 0) { (void)lint_warn_at(st, ys("the condition is always false, so the loop never runs"), yr_get(node, "cond")); }
        if (yv_l(yr_get(st, "wlevel")) >= 2) {
            (void)lint_short_while(st, node);
        }
        return lint_loop_body(st, yr_get(node, "body"));
    } else if (yv_l(k) == K_func) {
        (void)lint_func(st, node);
        return lint_unused_expr(st, node, used);
    } else if (yv_l(k) == K_incdec) {
        return lint_incdec(st, node, used);
    } else if (yv_l(k) == K_idxassign) {
        (void)lint_two(st, yr_get(node, "arr"), yr_get(node, "idx"));
        return lint_node(st, yr_get(node, "v"), 1);
    } else if (yv_l(k) == K_dotassign) {
        return lint_two(st, yr_get(node, "obj"), yr_get(node, "v"));
    } else if (yv_l(k) == K_slice) {
        (void)lint_two(st, yr_get(node, "arr"), yr_get(node, "lo"));
        (void)lint_node(st, yr_get(node, "hi"), 1);
        if (yv_l(yr_get(st, "wlevel")) >= 2) {
            (void)lint_short_slice(st, node);
        }
        return lint_unused_expr(st, node, used);
    } else if (yv_l(k) == K_kw_for) {
        return lint_for(st, node);
    } else if (yv_l(k) == K_kw_foreach) {
        (void)lint_node(st, yr_get(node, "iter"), 1);
        if (yv_l(yr_get(st, "wlevel")) >= 2) {
            (void)lint_short_range(st, node);
        }
        return lint_loop_body(st, yr_get(node, "body"));
    } else if (yv_l(k) == K_forrange) {
        (void)lint_two(st, yr_get(node, "lo"), yr_get(node, "hi"));
        return lint_loop_body(st, yr_get(node, "body"));
    } else if (yv_l(k) == K_map) {
        (void)lint_lit(st, node, ys("key"), ys("map"));
        return lint_unused_expr(st, node, used);
    } else if (yv_l(k) == K_arrrep) {
        (void)lint_node(st, yr_get(node, "v"), 1);
        return lint_unused_expr(st, node, used);
    } else if (yv_l(k) == K_store) {
        return lint_two(st, yr_get(node, "p"), yr_get(node, "v"));
    } else if (yv_l(k) == K_sliceassign) {
        (void)lint_two(st, yr_get(node, "arr"), yr_get(node, "lo"));
        return lint_two(st, yr_get(node, "hi"), yr_get(node, "v"));
    } else {
        return 0;
    }
}

/* ── what each def returns (level 1 only) ───────────────────────────────── */

/* Every `def` in the tree, by its renamed name. */
static ylong lint_rets(LintSt st, Yv *stmts) {
    ylong i = 0;
    while (i < yv_len(stmts)) {
        (void)lint_rets_node(st, ya_get(stmts, i));
        i = i + 1;
    }
    return 0;
}

static ylong lint_rets_node(LintSt st, Yv *node) {
    Yv *k = yr_get(node, "k");
    if (yv_l(k) == K_decl) {
        Yv *v = yr_get(node, "v");
        if (ys_eq_lit(yr_get(node, "kind"), "def") &&
            yv_l(yr_get(v, "k")) == K_func) {
            Yv *name = yr_get(node, "name");
            ylong n = lint_num(name);
            if (n > 0 && nameix_get(yr_get(st, "ridx"), name) < 0) {
                (void)nameix_put(yr_get(st, "ridx"), name,
                                 yv_len(yr_get(st, "rets")));
                (void)ya_push(yr_get(st, "rets"),
                              yr(5, "name", name, "ret", yr_get(v, "ret"),
                                 "line", yr_get(node, "line"), "col",
                                 yr_get(node, "col"), "used", yv_long(0)));
            }
            return lint_rets(st, yr_get(v, "defs"));
        } else {
            return lint_rets_node(st, v);
        }
    } else if (yv_l(k) == K_kw_if) {
        (void)lint_rets_node(st, yr_get(node, "then"));
        return lint_rets_node(st, yr_get(node, "els"));
    } else if (yv_l(k) == K_block) {
        return lint_rets(st, yr_get(node, "stmts"));
    } else if (yv_l(k) == K_kw_while) {
        return lint_rets_node(st, yr_get(node, "body"));
    } else if (yv_l(k) == K_kw_for) {
        return lint_rets_node(st, yr_get(node, "body"));
    } else if (yv_l(k) == K_kw_foreach) {
        return lint_rets_node(st, yr_get(node, "body"));
    } else if (yv_l(k) == K_forrange) {
        return lint_rets_node(st, yr_get(node, "body"));
    } else {
        return 0;
    }
}

/* Whether the call `callee` (an id naming a def, or `self`) hands back a
 * value. A name no def answers for -- a builtin, a package's qualified
 * name, a name from another unit -- is taken to be void: the linter has
 * no way to know, and a wrong warning is worse than a missing one. */
static Yv *lint_binding(LintSt st, Yv *callee) {
    if (yv_l(yr_get(callee, "k")) != K_id) {
        return ys("");
    } else {
        Yv *nm = yr_get(callee, "v");
        if (ys_eq_lit(nm, "self")) {
            nm = yr_get(st, "self");
        }
        return nm;
    }
}

static int lint_returns(LintSt st, Yv *callee) {
    Yv *nm = lint_binding(st, callee);
    if (ys_eq_lit(nm, "")) {
        return 0;
    } else {
        ylong i = nameix_get(yr_get(st, "ridx"), nm);
        if (i < 0) {
            return 0;
        } else {
            Yv *ret = yr_get(ya_get(yr_get(st, "rets"), i), "ret");
            ylong rk = yv_l(yr_get(ret, "k"));
            return !(rk == K_tvoid || rk == K_tunk || rk == K_tnone);
        }
    }
}

/* A def's name while its body is walked, so `self` resolves; the one
 * before, restored after. */
static Yv *lint_self(LintSt st, Yv *name) {
    Yv *was = yr_get(st, "self");
    (void)yr_set(st, "self", name);
    return was;
}

/* A def's value, walked with `self` bound to its name: a call to `self` is
 * a call to the def it is written in, so it is named for it. */
static ylong lint_def_body(LintSt st, Yv *name, Yv *v) {
    Yv *was = lint_self(st, name);
    int wv = yv_b(yr_get(st, "voidfn"));
    if (yv_l(yr_get(v, "k")) == K_func) {
        if (yv_l(yr_get(yr_get(v, "ret"), "k")) == K_tvoid) {
            (void)yr_set(st, "voidfn", yv_bool(1));
        }
    }
    (void)lint_node(st, v, 1);
    (void)yr_set(st, "voidfn", yv_bool(wv));
    (void)yr_set(st, "self", was);
    return 0;
}

/* Level 1: a call whose result nobody reads, when the callee hands one
 * back. The message names the function the way the source spells it. */
static ylong lint_unused_call(LintSt st, Yv *node, int used, Yv *call) {
    if (lint_droptail(st)) { return 0; }
    Yv *nm = lint_binding(st, yr_get(call, "callee"));
    if (!ys_eq_lit(nm, "")) {
        ylong ri = nameix_get(yr_get(st, "ridx"), nm);
        if (ri >= 0) {
            Yv *r = ya_get(yr_get(st, "rets"), ri);
            if (used) {
                (void)yr_set(r, "used", yv_long(1));
            } else if (yv_l(yr_get(st, "wlevel")) >= 1 &&
                       lint_returns(st, yr_get(call, "callee"))) {
                if (lint_drops == NULL) {
                    lint_drops = yav(0);
                }
                (void)ya_push(lint_drops,
                              yr(4, "callee", yv_long(ri), "line",
                                 yr_get(node, "line"), "col",
                                 yr_get(node, "col"), "name", lint_disp(nm)));
            }
        }
    }
    return 0;
}

/* Level 1: a read or a literal used as a statement -- `x.f`, `a[i]`,
 * `a[1:2]`, `&x`, `*p`, a record/array/map literal, `a is B`. Nothing
 * else can be meant by it, and the statement is easy to miss. The
 * position says which expression it is. */
static ylong lint_unused_expr(LintSt st, Yv *node, int used) {
    if (lint_droptail(st)) { return 0; }
    if (yv_l(yr_get(st, "wlevel")) >= 1 && !used) {
        (void)lint_warn_at(st, ys("the value computed here is not used"),
                           node);
    }
    return 0;
}

/* The kinds with one operand, `e`; a unary operator's dropped result is
 * a mistake. NOTE: the arms mirror lint.y's lint_one one for one, in the
 * same order. K_matchend is the compiler's own marker at the end of a match:
 * descend into the match as used and draw nothing -- it is not a value
 * anybody computed. It was missing here, so a `match` used as a statement
 * drew a spurious "the value computed here is not used" from the C copy
 * only, at the `match` keyword. The port gate could not see it: it compares
 * the two compilers' warnings at the default level, where every level-1
 * check draws nothing (src/tools/ytest/su_port.y now also runs a `-W 1` pass). */
static ylong lint_one(LintSt st, Yv *node, int used) {
    Yv *k = yr_get(node, "k");
    if (yv_l(k) == K_un) {
        return lint_un(st, node, used);
    } else if (yv_l(k) == K_rectest || yv_l(k) == K_narrow) {
        (void)lint_node(st, yr_get(node, "e"), 1);
        return lint_unused_expr(st, node, used);
    } else if (yv_l(k) == K_matchend) {
        return lint_node(st, yr_get(node, "e"), 1);
    } else if (yv_l(k) == K_ret) {
        return lint_node(st, yr_get(node, "e"), 1);
    } else {
        (void)lint_node(st, yr_get(node, "e"), 1);
        return lint_unused_expr(st, node, used);
    }
}

static ylong lint_list(LintSt st, Yv *nodes) {
    ylong i = 0;
    while (i < yv_len(nodes)) {
        (void)lint_node(st, ya_get(nodes, i), 1);
        i = i + 1;
    }
    return 0;
}

static ylong lint_two(LintSt st, Yv *a, Yv *b) {
    (void)lint_node(st, a, 1);
    return lint_node(st, b, 1);
}

static ylong lint_id(LintSt st, Yv *node, int used) {
    Yv *name = yr_get(node, "v");
    (void)lint_mark(st, name, 1);
    /* How many times, and where the first read is (rule 2.10). */
    ylong rn = lint_num(name);
    if (rn > 0) {
        Yv *rr = yr_get(st, "reads");
        while (yv_len(rr) <= rn) {
            (void)ya_push(rr, yv_long(0));
            (void)ya_push(yr_get(st, "rline"), yv_long(0));
            (void)ya_push(yr_get(st, "rcol"), yv_long(0));
        }
        ya_set(rr, rn, yv_long(yv_l(ya_get(rr, rn)) + 1));
        if (yv_l(ya_get(rr, rn)) == 1) {
            ya_set(yr_get(st, "rline"), rn, yr_get(node, "line"));
            ya_set(yr_get(st, "rcol"), rn, yr_get(node, "col"));
        }
    }
    if (lint_droptail(st)) { return 0; }
    Yv *d = lint_disp(name);
    if (!used && !ys_eq_lit(d, "") && !ys_eq_lit(d, "none")) {
        (void)lint_warn_at(
            st, lint_cat(3, ys("the value of '"), d, ys("' is not used")),
            node);
    }
    return 0;
}

static ylong lint_un(LintSt st, Yv *node, int used) {
    Yv *e = yr_get(node, "e");
    (void)lint_node(st, e, 1);
    if (lint_droptail(st)) { return 0; }
    if (!used && yv_l(yr_get(e, "k")) != K_num) {
        (void)lint_warn_at(st,
                           lint_cat(3, ys("the result of '"),
                                    yr_get(node, "op"),
                                    ys("' is not used")),
                           node);
    }
    return 0;
}

/* `ok && f()` dropping its value is control flow: f runs only when ok.
 * Any other operator's dropped value is a mistake. */
static ylong lint_bin(LintSt st, Yv *node, int used) {
    Yv *op = yr_get(node, "op");
    /* The chain check runs once, at the top of the `||` tree, and the flag
     * stays set while the operands are walked so a nested `||` does not
     * report the same chain again. */
    ylong was = yv_l(yr_get(st, "logic"));
    if (yv_l(yr_get(st, "wlevel")) >= 2 && ys_eq_lit(op, "||") && was == 0) {
        (void)yr_set(st, "logic", yv_long(1));
        (void)lint_short_chain(st, node);
    }
    Yv *l = yr_get(node, "l");
    Yv *r = yr_get(node, "r");
    if (ys_eq_lit(op, "in")) { lint_loop_arr(st, r); }
    if ((ys_eq_lit(op, "&&") || ys_eq_lit(op, "||")) && !used &&
        lint_effect(r)) {
        (void)lint_node(st, l, 1);
        ylong res = lint_node(st, r, 0);
        (void)yr_set(st, "logic", yv_long(was));
        return res;
    } else {
        (void)lint_two(st, l, r);
        if (!used && !lint_droptail(st)) {
            Yv *msg = lint_cat(3, ys("the result of '"), op,
                               ys("' is not used"));
            if (ys_eq_lit(op, "==")) {
                msg = ys_cat(msg, ys("; did you mean '='?"));
            }
            (void)lint_warn_at(st, msg, node);
        }
        if ((ys_eq_lit(op, "<") || ys_eq_lit(op, ">")) &&
            lint_same_id(l, r)) {
            Yv *d = lint_disp(yr_get(l, "v"));
            (void)lint_warn_at(st,
                               lint_cat(7, ys("'"), d, ys(" "), op, ys(" "),
                                        d, ys("' is always false")),
                               node);
        }
        if ((ys_eq_lit(op, "/") || ys_eq_lit(op, "%")) && lint_zero(r)) {
            (void)lint_warn_at(st, ys("division by zero"), node);
        }
        if (yv_l(yr_get(st, "wlevel")) >= 1 && (ys_eq_lit(op, "&") || ys_eq_lit(op, "|") || ys_eq_lit(op, "^") || ys_eq_lit(op, "&&") || ys_eq_lit(op, "||")) && lint_same_node(l, r)) {
            (void)lint_warn_at(st, lint_cat(3, ys("both operands of '"), op, ys("' are the same expression")), node);
        }
        if (yv_l(yr_get(st, "wlevel")) >= 2) {
            (void)lint_short_bin(st, node);
        }
        (void)yr_set(st, "logic", yv_long(was));
        return 0;
    }
}

/* The names are compared as strings: `==` on two unannotated values
 * compares their words. */
static int lint_same_id(Yv *l, Yv *r) {
    if (yv_l(yr_get(l, "k")) == K_id && yv_l(yr_get(r, "k")) == K_id) {
        Yv *lv = yr_get(l, "v");
        Yv *rv = yr_get(r, "v");
        return ys_eq(lv, rv);
    } else {
        return 0;
    }
}

/* ── shortening suggestions (level 2, LINT_RULES.md) ────────────────────
 * Advice about form, never about meaning: every check here fires only when
 * the rewrite it names is exactly the same program. */

/* The value of an integer literal, or -1 when the node is not one. A char
 * literal carries its byte as decimal text, so it reads here too. */
static ylong lint_int_val(Yv *node) {
    ylong k = yv_l(yr_get(node, "k"));
    if (k != K_num && k != K_char) { return -1; }
    Yv *s = yr_get(node, "v");
    if (yv_len(s) > 0 && ys_byte_at(s, yv_len(s) - 1) == 'n') {
        s = ys_slice(s, 0, yv_len(s) - 1);
    }
    ylong base = 10;
    ylong r = radix_of(s);
    if (r != 0) {
        base = r;
        s = ys_slice_from(s, 2);
    }
    if (base == 10 && (ys_index_of(s, ys(".")) >= 0 ||
                       ys_index_of(s, ys("e")) >= 0 ||
                       ys_index_of(s, ys("E")) >= 0)) {
        return -1;
    }
    ylong v = 0;
    int ok = yv_len(s) > 0;
    ylong i = 0;
    while (ok && i < yv_len(s)) {
        ylong c = ys_byte_at(s, i);
        if (c == '_') {
        } else if (c >= '0' && c <= '9') {
            v = v * base + (c - '0');
        } else if (base == 16 && c >= 'a' && c <= 'f') {
            v = v * 16 + (c - 'a' + 10);
        } else if (base == 16 && c >= 'A' && c <= 'F') {
            v = v * 16 + (c - 'A' + 10);
        } else {
            ok = 0;
        }
        i = i + 1;
    }
    return ok ? v : -1;
}

/* The operator set that has a compound assignment. */
static int lint_compound_op(Yv *op) {
    return ys_eq_lit(op, "+") || ys_eq_lit(op, "-") || ys_eq_lit(op, "*") ||
           ys_eq_lit(op, "/") || ys_eq_lit(op, "%") || ys_eq_lit(op, "&") ||
           ys_eq_lit(op, "|") || ys_eq_lit(op, "^") || ys_eq_lit(op, "<<") ||
           ys_eq_lit(op, ">>") || ys_eq_lit(op, ">>>");
}

/* Whether two written expressions are the same one. Only the shapes a
 * slice bound is written with: a name, a literal, a unary and a binary.
 * Commutativity is the caller's business. */
static int lint_same_node(Yv *a, Yv *b) {
    ylong ka = yv_l(yr_get(a, "k"));
    if (ka != yv_l(yr_get(b, "k"))) { return 0; }
    if (ka == K_id || ka == K_num || ka == K_str || ka == K_bool) {
        return ys_eq(yr_get(a, "v"), yr_get(b, "v"));
    } else if (ka == K_un) {
        return ys_eq(yr_get(a, "op"), yr_get(b, "op")) &&
               lint_same_node(yr_get(a, "e"), yr_get(b, "e"));
    } else if (ka == K_bin) {
        return ys_eq(yr_get(a, "op"), yr_get(b, "op")) &&
               lint_same_node(yr_get(a, "l"), yr_get(b, "l")) &&
               lint_same_node(yr_get(a, "r"), yr_get(b, "r"));
    }
    return 0;
}

/* `lo` and `hi` are `E` and `E + 1` (either operand order). */
/* The `E` of `E + n`, or the whole node when it is not a sum. */
static Yv *lint_slice_base(Yv *node) {
    if (yv_l(yr_get(node, "k")) == K_bin &&
        ys_eq_lit(yr_get(node, "op"), "+")) {
        if (lint_int_val(yr_get(node, "r")) >= 0) { return yr_get(node, "l"); }
        if (lint_int_val(yr_get(node, "l")) >= 0) { return yr_get(node, "r"); }
    }
    return node;
}

/* The `n` of `E + n`, or 0. */
static ylong lint_slice_off(Yv *node) {
    if (yv_l(yr_get(node, "k")) == K_bin &&
        ys_eq_lit(yr_get(node, "op"), "+")) {
        if (lint_int_val(yr_get(node, "r")) >= 0) {
            return lint_int_val(yr_get(node, "r"));
        }
        if (lint_int_val(yr_get(node, "l")) >= 0) {
            return lint_int_val(yr_get(node, "l"));
        }
    }
    return 0;
}

/* `lo` and `hi` are `E + n` and `E + (n + 1)` (either operand order, and
 * `n` may be 0). */
static int lint_slice_one(Yv *lo, Yv *hi) {
    return lint_same_node(lint_slice_base(lo), lint_slice_base(hi)) &&
           lint_slice_off(hi) == lint_slice_off(lo) + 1;
}

/* Whether a written expression is a str (a literal, or a binding noted as
 * holding one). An unknown receiver is not a str: a warning that would
 * change a string into a byte had better be sure. */
static int lint_str_expr(LintSt st, Yv *node) {
    if (yv_l(yr_get(node, "k")) == K_str) { return 1; }
    if (yv_l(yr_get(node, "k")) == K_id) {
        return lint_var_str(st, yr_get(node, "v"));
    }
    return 0;
}

/* The name to put in a message, when the expression has one. */
static Yv *lint_operand(Yv *node) {
    if (yv_l(yr_get(node, "k")) == K_id) { return lint_disp(yr_get(node, "v")); }
    return ys("");
}

/* Rule 1.1/1.2: `x = x + e` is `x += e`. */
static ylong lint_short_assign(LintSt st, Yv *node, Yv *name, Yv *v) {
    if (yv_l(yr_get(v, "k")) != K_bin) { return 0; }
    Yv *op = yr_get(v, "op");
    Yv *l = yr_get(v, "l");
    if (yv_l(yr_get(l, "k")) != K_id) { return 0; }
    if (!ys_eq(yr_get(l, "v"), name)) { return 0; }
    Yv *d = lint_disp(name);
    if (ys_eq_lit(op, "+") && lint_int_val(yr_get(v, "r")) == 1 &&
        lint_var_scal(st, name)) {
        (void)lint_warn_at(st,
                           lint_cat(7, ys("'"), d, ys(" = "), d,
                                    ys(" + 1' can be written '"), d, ys("++'")),
                           node);
    } else if (ys_eq_lit(op, "-") && lint_int_val(yr_get(v, "r")) == 1 &&
               lint_var_scal(st, name)) {
        (void)lint_warn_at(st,
                           lint_cat(7, ys("'"), d, ys(" = "), d,
                                    ys(" - 1' can be written '"), d, ys("--'")),
                           node);
    } else if (lint_compound_op(op) && lint_var_scal(st, name)) {
        (void)lint_warn_at(st,
                           lint_cat(11, ys("'"), d, ys(" = "), d, ys(" "), op,
                                    ys(" <expr>' can be written '"), d, ys(" "),
                                    op, ys("= <expr>'")),
                           node);
    }
    return 0;
}

/* Rule 1.9: a comparison against a bool literal is the value or its not. */
static ylong lint_short_bin(LintSt st, Yv *node) {
    Yv *op = yr_get(node, "op");
    if (ys_eq_lit(op, "-") && yv_l(yr_get(yr_get(node, "l"), "k")) == K_num && yv_l(yr_get(yr_get(node, "r"), "k")) == K_num && lint_int_val(yr_get(node, "l")) == 0) {
        (void)lint_warn_at(st, ys("'0 - n' is a negative literal; write it '-n'"), node);
    }
    if (!ys_eq_lit(op, "==") && !ys_eq_lit(op, "!=")) { return 0; }
    Yv *lit = yr_get(node, "r");
    Yv *other = yr_get(node, "l");
    if (yv_l(yr_get(yr_get(node, "l"), "k")) == K_bool) {
        lit = yr_get(node, "l");
        other = yr_get(node, "r");
    } else if (yv_l(yr_get(yr_get(node, "r"), "k")) != K_bool) {
        return 0;
    }
    Yv *lb = yr_get(lit, "v");
    int neg = (ys_eq_lit(op, "!=") == ys_eq_lit(lb, "true"));
    Yv *d = lint_operand(other);
    if (ys_eq_lit(d, "")) {
        (void)lint_warn_at(st,
                           ys("a comparison against true or false is the value "
                              "itself, or its negation"),
                           node);
    } else if (neg) {
        (void)lint_warn_at(st,
                           lint_cat(9, ys("'"), d, ys(" "), op, ys(" "), lb,
                                    ys("' can be written '!"), d, ys("'")),
                           node);
    } else {
        (void)lint_warn_at(st,
                           lint_cat(9, ys("'"), d, ys(" "), op, ys(" "), lb,
                                    ys("' can be written '"), d, ys("'")),
                           node);
    }
    return 0;
}

/* Rule 1.3: `byte_at(s, i)` is `s[i]`. */
static ylong lint_short_call(LintSt st, Yv *call) {
    Yv *callee = yr_get(call, "callee");
    if (yv_l(yr_get(callee, "k")) != K_id) { return 0; }
    Yv *args = yr_get(call, "args");
    if (ys_eq_lit(yr_get(callee, "v"), "byte_at") && yv_len(args) == 2 &&
        nameix_get(yr_get(st, "ridx"), ys("byte_at")) < 0) {
        (void)lint_warn_at(st, ys("'byte_at(s, i)' can be written 's[i]'"),
                           call);
    }
    return 0;
}

/* Rule 1.5: `ord(s[E:E + 1])` is `s[E]`. Handled here, before the slice
 * node is walked, so the slice does not also get rule 1.4's warning. */
static int lint_short_ord(LintSt st, Yv *call) {
    Yv *callee = yr_get(call, "callee");
    if (yv_l(yr_get(callee, "k")) != K_id) { return 0; }
    Yv *args = yr_get(call, "args");
    if (!ys_eq_lit(yr_get(callee, "v"), "ord") || yv_len(args) != 1 ||
        yv_l(yr_get(ya_get(args, 0), "k")) != K_slice ||
        nameix_get(yr_get(st, "ridx"), ys("ord")) >= 0) {
        return 0;
    }
    Yv *sl = ya_get(args, 0);
    if (!lint_slice_one(yr_get(sl, "lo"), yr_get(sl, "hi"))) { return 0; }
    (void)lint_two(st, yr_get(sl, "arr"), yr_get(sl, "lo"));
    (void)lint_node(st, yr_get(sl, "hi"), 1);
    (void)lint_warn_at(
        st, ys("'ord' of a one-character slice can be written as an index (a byte)"),
        call);
    return 1;
}

/* Rule 1.4: a one-character slice of a str is `s[E]`. */
static ylong lint_short_slice(LintSt st, Yv *node) {
    if (lint_slice_one(yr_get(node, "lo"), yr_get(node, "hi")) &&
        lint_str_expr(st, yr_get(node, "arr"))) {
        (void)lint_warn_at(
            st, ys("a one-character slice can be written as an index (a byte)"),
            node);
    }
    return 0;
}

/* Rules 1.6/1.7: a `||` chain of equalities against the same value is one
 * range or one membership test. Called once per chain, from its top node. */
static ylong lint_short_chain(LintSt st, Yv *node) {
    Yv *leaves = yav(0);
    (void)lint_chain_leaves(node, leaves);
    if (yv_len(leaves) < 3) { return 0; }
    Yv *first = ya_get(leaves, 0);
    if (yv_l(yr_get(first, "k")) != K_bin ||
        !ys_eq_lit(yr_get(first, "op"), "==") ||
        !lint_pure(yr_get(first, "l"))) {
        return 0;
    }
    Yv *l0 = yr_get(first, "l");
    Yv *vals = yav(0);
    int allint = 1;
    int allstr = 1;
    ylong i = 0;
    while (i < yv_len(leaves)) {
        Yv *b = ya_get(leaves, i);
        if (yv_l(yr_get(b, "k")) != K_bin ||
            !ys_eq_lit(yr_get(b, "op"), "==") ||
            !lint_same_node(l0, yr_get(b, "l"))) {
            return 0;
        }
        Yv *r = yr_get(b, "r");
        if (yv_l(yr_get(r, "k")) == K_str) {
            allint = 0;
        } else {
            ylong v = lint_int_val(r);
            if (v < 0) { return 0; }
            (void)ya_push(vals, yv_long(v));
            allstr = 0;
        }
        i = i + 1;
    }
    if (allint) {
        ylong lo = yv_l(ya_get(vals, 0));
        ylong hi = lo;
        ylong j = 0;
        while (j < yv_len(vals)) {
            ylong v = yv_l(ya_get(vals, j));
            if (v < lo) { lo = v; }
            if (v > hi) { hi = v; }
            j = j + 1;
        }
        if (hi - lo + 1 == yv_len(vals)) {
            (void)lint_warn_at(
                st,
                ys("these equalities are a consecutive range; write a range "
                   "comparison"),
                node);
        } else {
            (void)lint_warn_at(
                st,
                ys("these equalities test one value against a set; write one "
                   "membership test"),
                node);
        }
    } else if (allstr) {
        (void)lint_warn_at(
            st,
            ys("these equalities test one value against a set of strings; "
               "write one membership test"),
            node);
    }
    return 0;
}

/* The `==` comparisons of a `||` chain, in order. */
static ylong lint_chain_leaves(Yv *node, Yv *out) {
    if (yv_l(yr_get(node, "k")) == K_bin &&
        ys_eq_lit(yr_get(node, "op"), "||")) {
        (void)lint_chain_leaves(yr_get(node, "l"), out);
        (void)lint_chain_leaves(yr_get(node, "r"), out);
        return 0;
    }
    (void)ya_push(out, node);
    return 0;
}

/* The one statement of a block, or a void node when the block holds none
 * or more than one. A trailing `;` leaves a void filler (parse_block), so
 * only the real statements are counted. */
static Yv *lint_single_stmt(Yv *block) {
    if (yv_l(yr_get(block, "k")) == K_block) {
        Yv *stmts = yr_get(block, "stmts");
        Yv *found = yr(3, "k", yv_long(K_void), "line", yr_get(block, "line"),
                       "col", yr_get(block, "col"));
        ylong n = 0;
        ylong i = 0;
        while (i < yv_len(stmts)) {
            if (yv_l(yr_get(ya_get(stmts, i), "k")) != K_void) {
                found = ya_get(stmts, i);
                n = n + 1;
            }
            i = i + 1;
        }
        if (n == 1) { return found; }
    }
    return yr(3, "k", yv_long(K_void), "line", yr_get(block, "line"), "col",
              yr_get(block, "col"));
}

static Yv *lint_first_stmt(Yv *block) {
    if (yv_l(yr_get(block, "k")) == K_block) {
        Yv *stmts = yr_get(block, "stmts");
        ylong i = 0;
        while (i < yv_len(stmts)) {
            if (yv_l(yr_get(ya_get(stmts, i), "k")) != K_void) {
                return ya_get(stmts, i);
            }
            i = i + 1;
        }
    }
    return yr(3, "k", yv_long(K_void), "line", yr_get(block, "line"), "col",
              yr_get(block, "col"));
}

/* 1 for `true`, 0 for `false`, -1 for anything else. */
static ylong lint_bool_lit(Yv *node) {
    if (yv_l(yr_get(node, "k")) == K_bool) {
        return ys_eq_lit(yr_get(node, "v"), "true") ? 1 : 0;
    }
    return -1;
}

/* A value whose evaluation is the same whenever it happens: a literal or a
 * name. Deliberately not a call, a field or an index. */
static int lint_pure(Yv *node) {
    ylong k = yv_l(yr_get(node, "k"));
    return k == K_num || k == K_str || k == K_bool || k == K_char ||
           k == K_id;
}

/* Rule 2.1: an empty `if` arm. */
static ylong lint_short_empty_if(LintSt st, Yv *node) {
    if (yv_l(yr_get(st, "chain")) != 0) { return 0; }
    int te = lint_empty_arm(yr_get(node, "then"));
    int ee = yv_b(yr_get(node, "has_else")) && lint_empty_arm(yr_get(node, "els"));
    if (te && ee) {
        (void)lint_warn_at(
            st, ys("both branches of this 'if' are empty; it does nothing"),
            node);
    } else if (te) {
        /* An `else if` chain has no shorter form here: the arm being dropped
         * is the then, but what follows it is another condition. */
        if (yv_b(yr_get(node, "has_else")) &&
            yv_l(yr_get(yr_get(node, "els"), "k")) == K_kw_if) {
            return 0;
        }
        (void)lint_warn_at(
            st,
            ys("the 'if' branch is empty; invert the condition and drop the arm"),
            node);
    }
    return 0;
}

/* Rules 2.3/2.4: an `if`/`else` that only chooses a value. */
static ylong lint_short_if_ternary(LintSt st, Yv *node) {
    /* An `else if` arm has no block of its own to hold the rewrite. */
    if (yv_l(yr_get(st, "chain")) != 0) { return 0; }
    if (!yv_b(yr_get(node, "has_else"))) { return 0; }
    Yv *a = lint_single_stmt(yr_get(node, "then"));
    Yv *b = lint_single_stmt(yr_get(node, "els"));
    if (yv_l(yr_get(a, "k")) == K_assign && yv_l(yr_get(b, "k")) == K_assign) {
        if (ys_eq(yr_get(a, "name"), yr_get(b, "name"))) {
            (void)lint_warn_at(
                st,
                lint_cat(3, ys("'"), lint_disp(yr_get(a, "name")),
                         ys("' is chosen by a condition in both arms; write one "
                            "conditional assignment")),
                node);
        }
    } else if (yv_l(yr_get(a, "k")) == K_ret && yv_l(yr_get(b, "k")) == K_ret) {
        ylong la = lint_bool_lit(yr_get(a, "e"));
        ylong lb = lint_bool_lit(yr_get(b, "e"));
        if (la >= 0 && lb >= 0 && la != lb) {
            (void)lint_warn_at(
                st, ys("an 'if' returning true and false can return the condition"),
                node);
        } else {
            (void)lint_warn_at(
                st,
                ys("an 'if' returning a value from both arms can return a conditional"),
                node);
        }
    }
    return 0;
}

static ylong lint_short_if(LintSt st, Yv *node) {
    (void)lint_short_empty_if(st, node);
    (void)lint_short_if_ternary(st, node);
    (void)lint_short_if_chain(st, node);
    return 0;
}

/* Rule 1.8: `if (x == A) { v } else if (x == B) { v } ... else { !v }` is
 * one membership test, `x in [A, B, C]` (or the range of 1.7). */
static ylong lint_short_if_chain(LintSt st, Yv *node) {
    if (yv_l(yr_get(st, "chain")) != 0) { return 0; }
    Yv *x = lint_eq_name(yr_get(node, "cond"));
    if (ys_eq_lit(x, "")) { return 0; }
    ylong v0 = lint_bool_lit(lint_single_stmt(yr_get(node, "then")));
    if (v0 < 0) { return 0; }
    ylong n = 1;
    Yv *cur = node;
    while (yv_b(yr_get(cur, "has_else")) &&
           yv_l(yr_get(yr_get(cur, "els"), "k")) == K_kw_if) {
        Yv *nx = yr_get(cur, "els");
        if (!ys_eq(lint_eq_name(yr_get(nx, "cond")), x)) { return 0; }
        if (lint_bool_lit(lint_single_stmt(yr_get(nx, "then"))) != v0) {
            return 0;
        }
        cur = nx;
        n++;
    }
    if (n < 2) { return 0; }
    if (yv_b(yr_get(cur, "has_else"))) {
        if (lint_bool_lit(lint_single_stmt(yr_get(cur, "els"))) == v0) {
            return 0;
        }
    }
    (void)lint_warn_at(
        st,
        ys("this 'if' chain tests one value against a set; write one "
           "membership test"),
        node);
    return 0;
}

/* The name `L == <literal>` (either order), or "". */
static Yv *lint_eq_name(Yv *cond) {
    if (yv_l(yr_get(cond, "k")) != K_bin) { return ys(""); }
    if (!ys_eq_lit(yr_get(cond, "op"), "==")) { return ys(""); }
    Yv *l = yr_get(cond, "l");
    Yv *r = yr_get(cond, "r");
    if (yv_l(yr_get(r, "k")) == K_id && lint_is_lit(l)) { return yr_get(r, "v"); }
    if (yv_l(yr_get(l, "k")) == K_id && lint_is_lit(r)) { return yr_get(l, "v"); }
    return ys("");
}

static int lint_is_lit(Yv *node) {
    ylong k = yv_l(yr_get(node, "k"));
    return k == K_num || k == K_str || k == K_char || k == K_bool;
}

/* Rule 3.6: a `foreach` closure whose element parameter is unused while the
 * body indexes the array again: `a.foreach((e, i) => { let x = a[i]; })` is
 * `a.foreach((e2, i) => { let x = e2; })`, and the index goes when nothing
 * else needs it. */
static ylong lint_short_foreach_elem(LintSt st, Yv *call) {
    Yv *callee = yr_get(call, "callee");
    Yv *args = yr_get(call, "args");
    if (yv_l(yr_get(callee, "k")) != K_dot || yv_len(args) != 1) { return 0; }
    Yv *obj = yr_get(callee, "obj");
    if (!ys_eq_lit(yr_get(callee, "key"), "foreach") ||
        yv_l(yr_get(obj, "k")) != K_id ||
        yv_l(yr_get(ya_get(args, 0), "k")) != K_func) {
        return 0;
    }
    Yv *arr = yr_get(obj, "v");
    Yv *f = ya_get(args, 0);
    Yv *params = yr_get(f, "params");
    if (yv_len(params) < 2) { return 0; }
    Yv *el = ya_get(params, 0);
    if (lint_find(yr_get(f, "body"), el, 0)) { return 0; }
    if (!lint_find(yr_get(f, "body"), arr, 64)) { return 0; }
    /* the element is not `a[i]` if the body writes a[i]: a store must keep
     * the index */
    if (lint_find(yr_get(f, "body"), arr, 128)) { return 0; }
    (void)lint_warn_at(
        st,
        lint_cat(3,
                 ys("the element parameter of this 'foreach' is unused; use it "
                    "instead of indexing '"),
                 lint_disp(arr), ys("' again")),
        call);
    return 0;
}

/* Rule 2.11: `let x = E; if (x == none) { A } else { B(x!) }` is
 * `if let some(x) = E { B } else { A }`. */
static ylong lint_short_none(LintSt st, Yv *stmts, ylong i) {
    Yv *d = ya_get(stmts, i);
    Yv *n = ya_get(stmts, i + 1);
    if (!ys_eq_lit(yr_get(d, "kind"), "let") ||
        yv_l(yr_get(yr_get(d, "typ"), "k")) != K_tnone) {
        return 0;
    }
    if (!yv_b(yr_get(n, "has_else"))) { return 0; }
    Yv *x = lint_none_test(yr_get(n, "cond"));
    if (ys_eq_lit(x, "") || !ys_eq(x, yr_get(d, "name"))) { return 0; }
    int tw = lint_find(yr_get(n, "then"), x, 16);
    int ew = lint_find(yr_get(n, "els"), x, 16);
    if (tw == ew) { return 0; }
    Yv *some_arm = yr_get(n, "then");
    Yv *none_arm = yr_get(n, "els");
    if (ew) {
        some_arm = yr_get(n, "els");
        none_arm = yr_get(n, "then");
    }
    if (lint_find(some_arm, x, 32)) { return 0; }
    if (lint_find(none_arm, x, 0)) { return 0; }
    if (lint_find_from(stmts, i + 2, x, 0)) { return 0; }
    (void)lint_warn_at(
        st,
        lint_cat(5, ys("'"), lint_disp(x),
                 ys("' is tested for 'none' and unwrapped; write 'if let "
                    "some("),
                 lint_disp(x), ys(") = <expr> { ... } else { ... }'")),
        d);
    return 0;
}

/* The name compared against `none`, or "". */
static Yv *lint_none_test(Yv *cond) {
    if (yv_l(yr_get(cond, "k")) != K_bin) { return ys(""); }
    Yv *op = yr_get(cond, "op");
    if (!ys_eq_lit(op, "==") && !ys_eq_lit(op, "!=")) { return ys(""); }
    Yv *l = yr_get(cond, "l");
    Yv *r = yr_get(cond, "r");
    if (yv_l(yr_get(l, "k")) == K_id && yv_l(yr_get(r, "k")) == K_id) {
        if (ys_eq_lit(yr_get(r, "v"), "none")) { return yr_get(l, "v"); }
        if (ys_eq_lit(yr_get(l, "v"), "none")) { return yr_get(r, "v"); }
    }
    return ys("");
}

/* Rule 2.5: a bool local that exists only to stop the loop.
 *   `let f = true; while (f) { ...; f = false; ... };`
 * is `while (true) { ...; break; ... };`. The flag must be written inside
 * the loop, never read there (a read makes it real state), and never
 * written after it. */
static ylong lint_short_flag(LintSt st, Yv *stmts, ylong i) {
    Yv *d = ya_get(stmts, i);
    Yv *loop = ya_get(stmts, i + 1);
    if (!ys_eq_lit(yr_get(d, "kind"), "let") ||
        yv_l(yr_get(yr_get(d, "typ"), "k")) != K_tnone) {
        return 0;
    }
    if (lint_bool_lit(yr_get(d, "v")) < 0) { return 0; }
    Yv *f = yr_get(d, "name");
    if (!lint_flag_cond(yr_get(loop, "cond"), f)) { return 0; }
    if (lint_find(yr_get(loop, "body"), f, 0)) { return 0; }
    if (!lint_find(yr_get(loop, "body"), f, 8)) { return 0; }
    if (lint_find_from(stmts, i + 2, f, 8)) { return 0; }
    (void)lint_warn_at(
        st,
        lint_cat(3, ys("'"), lint_disp(f),
                 ys("' only stops this loop; write 'while (true)' and 'break' "
                    "where it is set")),
        d);
    return 0;
}

/* The loop condition is `f`, `f == <bool>` or `f != <bool>`. */
static int lint_flag_cond(Yv *cond, Yv *name) {
    ylong k = yv_l(yr_get(cond, "k"));
    if (k == K_id) { return ys_eq(yr_get(cond, "v"), name); }
    if (k == K_un) {
        if (ys_eq_lit(yr_get(cond, "op"), "!")) {
            return lint_flag_cond(yr_get(cond, "e"), name);
        }
        return 0;
    }
    if (k == K_bin) {
        Yv *op = yr_get(cond, "op");
        if (ys_eq_lit(op, "==") || ys_eq_lit(op, "!=")) {
            Yv *l = yr_get(cond, "l");
            Yv *r = yr_get(cond, "r");
            if (yv_l(yr_get(l, "k")) == K_id && ys_eq(yr_get(l, "v"), name)) {
                return lint_bool_lit(r) >= 0;
            }
            if (yv_l(yr_get(r, "k")) == K_id && ys_eq(yr_get(r, "v"), name)) {
                return lint_bool_lit(l) >= 0;
            }
        }
    }
    return 0;
}

/* The statement list of a function body. An arrow closure's body is
 * `block1(parse_expr(...))`, so `{ ... }` lands as a block holding the
 * block: unwrap those. */
static Yv *lint_flat_body(Yv *body) {
    Yv *sts = yr_get(body, "stmts");
    while (yv_len(sts) == 1 &&
           yv_l(yr_get(ya_get(sts, 0), "k")) == K_block) {
        sts = yr_get(ya_get(sts, 0), "stmts");
    }
    return sts;
}

/* Rule 2.12: a closure that opens by renaming its own parameter.
 *   `a.foreach((e) => { let l = e; BODY(l) });`
 * is `a.foreach((l) => { BODY(l) });` -- the parameter carries the name. */
static ylong lint_alias_param(LintSt st, Yv *node) {
    Yv *params = yr_get(node, "params");
    if (yv_len(params) == 0) { return 0; }
    Yv *b = lint_flat_body(yr_get(node, "body"));
    ylong di = -1;
    ylong i = 0;
    while (i < yv_len(b)) {
        if (yv_l(yr_get(ya_get(b, i), "k")) != K_void) {
            di = i;
            break;
        }
        i = i + 1;
    }
    if (di < 0) { return 0; }
    Yv *d = ya_get(b, di);
    if (yv_l(yr_get(d, "k")) != K_decl) { return 0; }
    /* an unwritten `let` only: `let f: TFunc = t;` is a cast, not an alias */
    if (!ys_eq_lit(yr_get(d, "kind"), "let") ||
        yv_l(yr_get(yr_get(d, "v"), "k")) != K_id ||
        yv_l(yr_get(yr_get(d, "typ"), "k")) != K_tnone) {
        return 0;
    }
    Yv *src = yr_get(d, "v");
    Yv *p = ys("");
    i = 0;
    while (i < yv_len(params)) {
        if (ys_eq(ya_get(params, i), yr_get(src, "v"))) { p = ya_get(params, i); }
        i = i + 1;
    }
    if (ys_eq_lit(p, "") || ys_eq(yr_get(d, "name"), p)) { return 0; }
    /* the new name must not be another parameter (it would collide) */
    i = 0;
    while (i < yv_len(params)) {
        if (ys_eq(ya_get(params, i), yr_get(d, "name"))) { return 0; }
        i = i + 1;
    }
    /* the parameter must not be mentioned after the alias, and the alias
     * must never be written (that is a real copy, and 2.3's business) */
    i = di + 1;
    while (i < yv_len(b)) {
        if (lint_find(ya_get(b, i), p, 0)) { return 0; }
        if (lint_find(ya_get(b, i), yr_get(d, "name"), 8)) { return 0; }
        i = i + 1;
    }
    /* and the alias must be read, or this is the unused-local rule's job */
    if (!lint_find_list(ya_slice(b, di + 1, yv_len(b)), yr_get(d, "name"), 0)) {
        return 0;
    }
    (void)lint_warn_at(
        st,
        lint_cat(5, ys("'"), lint_disp(yr_get(d, "name")),
                 ys("' is only another name for the parameter '"),
                 lint_disp(p), ys("'; rename the parameter")),
        d);
    return 0;
}

/* A name set once after its `let`, under a condition (rule 2.2), or a
 * return chosen by a condition (rule 2.4's tail form). */
static ylong lint_short_pair(LintSt st, Yv *stmts, ylong i) {
    if (i + 1 >= yv_len(stmts)) { return 0; }
    Yv *d = ya_get(stmts, i);
    Yv *n = ya_get(stmts, i + 1);
    if (yv_l(yr_get(d, "k")) == K_decl && yv_l(yr_get(n, "k")) == K_kw_while) {
        (void)lint_short_index_loop(st, stmts, i);
        (void)lint_short_flag(st, stmts, i);
    } else if (yv_l(yr_get(d, "k")) == K_decl && yv_l(yr_get(n, "k")) == K_kw_if) {
        (void)lint_short_none(st, stmts, i);
        if (ys_eq_lit(yr_get(d, "kind"), "let") &&
            yv_l(yr_get(yr_get(d, "typ"), "k")) == K_tnone &&
            lint_pure(yr_get(d, "v")) && !yv_b(yr_get(n, "has_else")) &&
            yv_l(yr_get(yr_get(n, "cond"), "k")) == K_id) {
            Yv *body = lint_single_stmt(yr_get(n, "then"));
            if (yv_l(yr_get(body, "k")) == K_assign &&
                !ys_eq(yr_get(yr_get(n, "cond"), "v"), yr_get(d, "name")) &&
                ys_eq(yr_get(body, "name"), yr_get(d, "name"))) {
                Yv *dn = lint_disp(yr_get(d, "name"));
                (void)lint_warn_at(
                    st,
                    lint_cat(5, ys("'"), dn,
                             ys("' is set once under a condition; write 'let "),
                             dn, ys(" = <cond> ? <then> : <initial>'")),
                    d);
            }
        }
    } else if (yv_l(yr_get(d, "k")) == K_kw_if && yv_l(yr_get(n, "k")) == K_ret) {
        if (!yv_b(yr_get(d, "has_else")) &&
            yv_l(yr_get(yr_get(d, "cond"), "k")) == K_id) {
            Yv *a = lint_single_stmt(yr_get(d, "then"));
            if (yv_l(yr_get(a, "k")) == K_ret) {
                ylong la = lint_bool_lit(yr_get(a, "e"));
                ylong lb = lint_bool_lit(yr_get(n, "e"));
                if (la >= 0 && lb >= 0 && la != lb) {
                    (void)lint_warn_at(
                        st,
                        ys("an 'if' returning true and then false can return the "
                           "condition"),
                        d);
                } else {
                    (void)lint_warn_at(
                        st,
                        ys("an 'if' returning a value and a following return can be "
                           "one conditional return"),
                        d);
                }
            }
        }
    }
    return 0;
}

/* Rule 2.6: `while (true) { if (!c) { break; } ... }` is `while (c) ...`. */
static ylong lint_short_while(LintSt st, Yv *loop) {
    if (lint_bool_lit(yr_get(loop, "cond")) != 1) { return 0; }
    Yv *b = lint_first_stmt(yr_get(loop, "body"));
    if (yv_l(yr_get(b, "k")) != K_kw_if) { return 0; }
    if (yv_b(yr_get(b, "has_else"))) { return 0; }
    Yv *s = lint_single_stmt(yr_get(b, "then"));
    if (yv_l(yr_get(s, "k")) == K_kw_break) {
        (void)lint_warn_at(
            st,
            ys("'while (true)' with a leading 'break' guard can test the guard "
               "instead"),
            b);
    }
    return 0;
}

/* Walk a tree for one of two questions: is the name read, or does the body
 * jump? `mask` is a bit set -- 1 a return, 2 a break, 4 a continue -- and
 * `name` is "" when only the jumps matter. */
static int lint_find(Yv *node, Yv *name, ylong mask) {
    ylong k = yv_l(yr_get(node, "k"));
    if (k == K_ret && (mask & 1) != 0) { return 1; }
    if (k == K_ret && (mask & 256) != 0) {
        if (yv_l(yr_get(yr_get(node, "e"), "k")) != K_void) { return 1; }
    }
    if (k == K_kw_break && (mask & 2) != 0) { return 1; }
    if (k == K_kw_continue && (mask & 4) != 0) { return 1; }
    if ((mask & 8) != 0 && lint_resizes(node, name)) { return 1; }
    if ((mask & 64) != 0 && k == K_index) {
        Yv *ma = yr_get(node, "arr");
        if (yv_l(yr_get(ma, "k")) == K_id && ys_eq(yr_get(ma, "v"), name)) {
            return 1;
        }
    }
    if ((mask & 128) != 0 && lint_stores_index(node, name)) { return 1; }
    if (k == K_func && (mask & 1024) != 0) { return 1; }
    if (k == K_func && (mask & 2048) != 0) {
        if (lint_find(yr_get(node, "body"), ys(""), 256) ||
            lint_find_list(yr_get(node, "defs"), ys(""), 256)) {
            return 1;
        }
    }
    if ((mask & 16) != 0 && lint_unwraps(node, name)) { return 1; }
    if (k == K_id) {
        if (ys_eq_lit(name, "") || (mask & 8) != 0 || (mask & 64) != 0 ||
            (mask & 128) != 0) {
            return 0;
        }
        return ys_eq(yr_get(node, "v"), name);
    } else if (k == K_bin) {
        return lint_find(yr_get(node, "l"), name, mask) ||
               lint_find(yr_get(node, "r"), name, mask);
    } else if (k == K_un) {
        return lint_find(yr_get(node, "e"), name, mask);
    } else if (k == K_call) {
        /* `x!` is `unwrap(x)`: with mask 32 the argument is not a bare read */
        if ((mask & 32) != 0 && lint_unwraps(node, name)) { return 0; }
        return lint_find(yr_get(node, "callee"), name, mask) ||
               lint_find_list(yr_get(node, "args"), name, mask);
    } else if (k == K_dot) {
        return lint_find(yr_get(node, "obj"), name, mask);
    } else if (k == K_index) {
        return lint_find(yr_get(node, "arr"), name, mask) ||
               lint_find(yr_get(node, "idx"), name, mask);
    } else if (k == K_slice) {
        return lint_find(yr_get(node, "arr"), name, mask) ||
               lint_find(yr_get(node, "lo"), name, mask) ||
               lint_find(yr_get(node, "hi"), name, mask);
    } else if (k == K_assign) {
        return lint_find(yr_get(node, "v"), name, mask);
    } else if (k == K_opassign) {
        return lint_find(yr_get(node, "tgt"), name, mask) ||
               lint_find(yr_get(node, "v"), name, mask);
    } else if (k == K_incdec) {
        return lint_find(yr_get(node, "tgt"), name, mask);
    } else if (k == K_idxassign) {
        return lint_find(yr_get(node, "arr"), name, mask) ||
               lint_find(yr_get(node, "idx"), name, mask) ||
               lint_find(yr_get(node, "v"), name, mask);
    } else if (k == K_dotassign) {
        return lint_find(yr_get(node, "obj"), name, mask) ||
               lint_find(yr_get(node, "v"), name, mask);
    } else if (k == K_sliceassign) {
        return lint_find(yr_get(node, "arr"), name, mask) ||
               lint_find(yr_get(node, "lo"), name, mask) ||
               lint_find(yr_get(node, "hi"), name, mask) ||
               lint_find(yr_get(node, "v"), name, mask);
    } else if (k == K_store) {
        return lint_find(yr_get(node, "p"), name, mask) ||
               lint_find(yr_get(node, "v"), name, mask);
    } else if (k == K_array) {
        return lint_find_list(yr_get(node, "elems"), name, mask);
    } else if (k == K_rec || k == K_map) {
        return lint_find_list(yr_get(node, "vals"), name, mask);
    } else if (k == K_arrrep) {
        return lint_find(yr_get(node, "v"), name, mask);
    } else if (k == K_rectest || k == K_narrow) {
        return lint_find(yr_get(node, "e"), name, mask);
    } else if (k == K_ret || k == K_matchend) {
        return lint_find(yr_get(node, "e"), name, mask);
    } else if (k == K_block) {
        return lint_find_list(yr_get(node, "stmts"), name, mask);
    } else if (k == K_kw_if) {
        return lint_find(yr_get(node, "cond"), name, mask) ||
               lint_find(yr_get(node, "then"), name, mask) ||
               lint_find(yr_get(node, "els"), name, mask);
    } else if (k == K_kw_while) {
        return lint_find(yr_get(node, "cond"), name, mask) ||
               lint_find(yr_get(node, "body"), name, mask);
    } else if (k == K_kw_for) {
        return lint_find(yr_get(node, "init"), name, mask) ||
               lint_find(yr_get(node, "cond"), name, mask) ||
               lint_find(yr_get(node, "step"), name, mask) ||
               lint_find(yr_get(node, "body"), name, mask);
    } else if (k == K_kw_foreach) {
        return lint_find(yr_get(node, "iter"), name, mask) ||
               lint_find(yr_get(node, "body"), name, mask);
    } else if (k == K_forrange) {
        return lint_find(yr_get(node, "lo"), name, mask) ||
               lint_find(yr_get(node, "hi"), name, mask) ||
               lint_find(yr_get(node, "body"), name, mask);
    } else if (k == K_func) {
        return lint_find(yr_get(node, "body"), name, mask) ||
               lint_find_list(yr_get(node, "defs"), name, mask);
    } else if (k == K_decl) {
        return lint_find(yr_get(node, "v"), name, mask);
    }
    return 0;
}

static int lint_find_list(Yv *nodes, Yv *name, ylong mask) {
    ylong i = 0;
    while (i < yv_len(nodes)) {
        if (lint_find(ya_get(nodes, i), name, mask)) { return 1; }
        i = i + 1;
    }
    return 0;
}

/* `x!` is `unwrap(x)`. */
static int lint_unwraps(Yv *node, Yv *name) {
    if (yv_l(yr_get(node, "k")) != K_call) { return 0; }
    Yv *callee = yr_get(node, "callee");
    Yv *args = yr_get(node, "args");
    if (yv_l(yr_get(callee, "k")) != K_id || yv_len(args) != 1) { return 0; }
    if (!ys_eq_lit(yr_get(callee, "v"), "unwrap")) { return 0; }
    Yv *a = ya_get(args, 0);
    if (yv_l(yr_get(a, "k")) != K_id) { return 0; }
    return ys_eq(yr_get(a, "v"), name);
}

/* Whether this node stores through `name[...]` (a written element). The
 * element form of 3.6 is wrong there: the closure's parameter is a copy
 * while the store writes the array. */
static int lint_stores_index(Yv *node, Yv *name) {
    ylong k = yv_l(yr_get(node, "k"));
    if (k == K_idxassign) {
        Yv *arr = yr_get(node, "arr");
        if (yv_l(yr_get(arr, "k")) != K_id) { return 0; }
        return ys_eq(yr_get(arr, "v"), name);
    } else if (k == K_opassign) {
        return lint_index_of(yr_get(node, "tgt"), name);
    } else if (k == K_incdec) {
        return lint_index_of(yr_get(node, "tgt"), name);
    }
    return 0;
}

static int lint_index_of(Yv *tgt, Yv *name) {
    if (yv_l(yr_get(tgt, "k")) != K_index) { return 0; }
    Yv *arr = yr_get(tgt, "arr");
    if (yv_l(yr_get(arr, "k")) != K_id) { return 0; }
    return ys_eq(yr_get(arr, "v"), name);
}

static int lint_resize_method(Yv *key) {
    return ys_eq_lit(key, "push") || ys_eq_lit(key, "pop") ||
           ys_eq_lit(key, "remove") || ys_eq_lit(key, "insert") ||
           ys_eq_lit(key, "shift") || ys_eq_lit(key, "unshift") ||
           ys_eq_lit(key, "sort");
}

/* Whether this node changes what `name` holds as a whole (mask bit 8): a
 * whole-array assign or `op=`, `++`, or a length-changing method call. An
 * element store (`a[i] = x`) is not one. */
static int lint_resizes(Yv *node, Yv *name) {
    ylong k = yv_l(yr_get(node, "k"));
    if (k == K_assign) {
        return ys_eq(yr_get(node, "name"), name);
    } else if (k == K_opassign) {
        Yv *tgt = yr_get(node, "tgt");
        if (yv_l(yr_get(tgt, "k")) != K_id) { return 0; }
        return ys_eq(yr_get(tgt, "v"), name);
    } else if (k == K_incdec) {
        Yv *tgt = yr_get(node, "tgt");
        if (yv_l(yr_get(tgt, "k")) != K_id) { return 0; }
        return ys_eq(yr_get(tgt, "v"), name);
    } else if (k == K_call) {
        Yv *callee = yr_get(node, "callee");
        if (yv_l(yr_get(callee, "k")) != K_dot) { return 0; }
        Yv *obj = yr_get(callee, "obj");
        if (yv_l(yr_get(obj, "k")) != K_id) { return 0; }
        Yv *key = yr_get(callee, "key");
        return ys_eq(yr_get(obj, "v"), name) && lint_resize_method(key);
    }
    return 0;
}

static int lint_find_from(Yv *nodes, ylong from, Yv *name, ylong mask) {
    ylong i = from;
    while (i < yv_len(nodes)) {
        if (lint_find(ya_get(nodes, i), name, mask)) { return 1; }
        i = i + 1;
    }
    return 0;
}

/* Rule 3.5: `foreach (i in range(len(a)))` can iterate the array directly. */
static ylong lint_short_range(LintSt st, Yv *fe) {
    Yv *arr = lint_range_arr(yr_get(fe, "iter"));
    if (ys_eq_lit(arr, "") || !lint_var_vec(st, arr) ||
        lint_find(yr_get(fe, "body"), ys(""), 7) ||
        lint_find(yr_get(fe, "body"), arr, 8)) {
        return 0;
    }
    (void)lint_warn_at(
        st,
        ys("this range loop over an array's indices can be '<a>.foreach((e, i) "
           "=> { ... })'"),
        fe);
    return 0;
}

/* The name inside `range(len(a))`, or "". */
static Yv *lint_range_arr(Yv *node) {
    if (yv_l(yr_get(node, "k")) != K_call) { return ys(""); }
    Yv *args = yr_get(node, "args");
    if (yv_l(yr_get(yr_get(node, "callee"), "k")) != K_id ||
        yv_len(args) != 1) {
        return ys("");
    }
    if (!ys_eq_lit(yr_get(yr_get(node, "callee"), "v"), "range")) {
        return ys("");
    }
    return lint_len_of(ya_get(args, 0));
}

/* Whether the last real statement of a loop body is `iv = iv + 1` (also
 * `iv++`, `iv += 1`). */
static int lint_step_one(Yv *body, Yv *iv) {
    if (yv_l(yr_get(body, "k")) != K_block) { return 0; }
    Yv *stmts = yr_get(body, "stmts");
    Yv *last = yr(3, "k", yv_long(K_void), "line", yr_get(body, "line"),
                  "col", yr_get(body, "col"));
    ylong i = 0;
    while (i < yv_len(stmts)) {
        if (yv_l(yr_get(ya_get(stmts, i), "k")) != K_void) {
            last = ya_get(stmts, i);
        }
        i = i + 1;
    }
    ylong lk = yv_l(yr_get(last, "k"));
    if (lk == K_assign) {
        Yv *v = yr_get(last, "v");
        if (!ys_eq(yr_get(last, "name"), iv) ||
            yv_l(yr_get(v, "k")) != K_bin) {
            return 0;
        }
        if (!ys_eq_lit(yr_get(v, "op"), "+") ||
            yv_l(yr_get(yr_get(v, "l"), "k")) != K_id) {
            return 0;
        }
        return ys_eq(yr_get(yr_get(v, "l"), "v"), iv) &&
               lint_int_val(yr_get(v, "r")) == 1;
    } else if (lk == K_opassign) {
        if (!ys_eq_lit(yr_get(last, "op"), "+") ||
            yv_l(yr_get(yr_get(last, "tgt"), "k")) != K_id) {
            return 0;
        }
        return ys_eq(yr_get(yr_get(last, "tgt"), "v"), iv) &&
               lint_int_val(yr_get(last, "v")) == 1;
    } else if (lk == K_incdec) {
        if (yv_l(yr_get(yr_get(last, "tgt"), "k")) != K_id ||
            !ys_eq_lit(yr_get(last, "op"), "++")) {
            return 0;
        }
        return ys_eq(yr_get(yr_get(last, "tgt"), "v"), iv);
    }
    return 0;
}

/* The name inside `len(a)`, or "". */
static Yv *lint_len_of(Yv *node) {
    if (yv_l(yr_get(node, "k")) != K_call) { return ys(""); }
    Yv *args = yr_get(node, "args");
    if (yv_l(yr_get(yr_get(node, "callee"), "k")) != K_id ||
        yv_len(args) != 1) {
        return ys("");
    }
    if (!ys_eq_lit(yr_get(yr_get(node, "callee"), "v"), "len")) {
        return ys("");
    }
    if (yv_l(yr_get(ya_get(args, 0), "k")) != K_id) { return ys(""); }
    return yr_get(ya_get(args, 0), "v");
}

/* Rules 2.8/3.1: an index loop that is a `for` range or an array method. */
static ylong lint_short_index_loop(LintSt st, Yv *stmts, ylong i) {
    if (i + 1 >= yv_len(stmts)) { return 0; }
    Yv *d = ya_get(stmts, i);
    Yv *n = ya_get(stmts, i + 1);
    if (yv_l(yr_get(d, "k")) != K_decl ||
        yv_l(yr_get(n, "k")) != K_kw_while) {
        return 0;
    }
    if (!ys_eq_lit(yr_get(d, "kind"), "let") ||
        yv_l(yr_get(yr_get(d, "typ"), "k")) != K_tnone) {
        return 0;
    }
    Yv *iv = yr_get(d, "name");
    Yv *cond = yr_get(n, "cond");
    if (yv_l(yr_get(cond, "k")) != K_bin) { return 0; }
    Yv *op = yr_get(cond, "op");
    if ((!ys_eq_lit(op, "<") && !ys_eq_lit(op, "<=")) ||
        yv_l(yr_get(yr_get(cond, "l"), "k")) != K_id) {
        return 0;
    }
    if (!ys_eq(yr_get(yr_get(cond, "l"), "v"), iv) ||
        !lint_step_one(yr_get(n, "body"), iv)) {
        return 0;
    }
    if (lint_find_from(stmts, i + 2, iv, 0)) { return 0; }
    Yv *arr = lint_len_of(yr_get(cond, "r"));
    /* `foreach` starts at element 0 and needs an array, so the array form
     * is offered only for a start of 0 on a receiver not known to be a str,
     * with no jump and no resize of the receiver in the body. */
    int can_foreach = ys_eq_lit(op, "<") && !ys_eq_lit(arr, "") &&
                      lint_int_val(yr_get(d, "v")) == 0 &&
                      lint_var_vec(st, arr) &&
                      !lint_find(yr_get(n, "body"), ys(""), 7) &&
                      !lint_find(yr_get(n, "body"), arr, 8);
    if (can_foreach) {
        (void)lint_warn_at(st,
                           lint_cat(3, ys("this index loop can be '"),
                                    lint_disp(arr),
                                    ys(".foreach((e, i) => { ... })'")),
                           d);
    } else {
        if (lint_find(yr_get(n, "body"), ys(""), 4)) { return 0; }
        (void)lint_warn_at(st,
                           lint_cat(3, ys("this index loop can be 'for "),
                                    lint_disp(iv),
                                    ys(" in <lo>..<hi> { ... }'")),
                           d);
    }
    return 0;
}

/* Whether evaluating a node can do more than compute its value. */
static int lint_effect(Yv *node) {
    Yv *k = yr_get(node, "k");
    if (yv_l(k) == K_call || yv_l(k) == K_assign ||
        yv_l(k) == K_opassign || yv_l(k) == K_incdec ||
        yv_l(k) == K_idxassign || yv_l(k) == K_dotassign ||
        yv_l(k) == K_sliceassign || yv_l(k) == K_store) {
        return 1;
    } else if (yv_l(k) == K_block || yv_l(k) == K_kw_if ||
               yv_l(k) == K_kw_while || yv_l(k) == K_kw_for ||
               yv_l(k) == K_kw_foreach || yv_l(k) == K_forrange ||
               yv_l(k) == K_ret) {
        return 1;
    } else if (yv_l(k) == K_bin) {
        return lint_effect_logic(node);
    } else {
        return 0;
    }
}

static int lint_effect_logic(Yv *node) {
    Yv *op = yr_get(node, "op");
    return (ys_eq_lit(op, "&&") || ys_eq_lit(op, "||")) &&
           lint_effect(yr_get(node, "r"));
}

/* A literal integer zero (`0`, `0x0`, `0b0_0`). Not `0.0`: a float
 * division by zero is an infinity or a nan, not a trap. */
static int lint_zero(Yv *node) {
    if (yv_l(yr_get(node, "k")) == K_num) {
        return lint_zero_text(yr_get(node, "v"));
    } else {
        return 0;
    }
}

static int lint_zero_text(Yv *s) {
    Yv *digits = s;
    if (radix_of(s) != 0) {
        digits = ys_slice_from(s, 2);
    } else if (ys_index_of(s, ys(".")) >= 0 || ys_index_of(s, ys("e")) >= 0 ||
               ys_index_of(s, ys("E")) >= 0) {
        digits = ys("");
    }
    int ok = yv_len(digits) > 0;
    ylong i = 0;
    while (ok && i < yv_len(digits)) {
        ylong c = ys_byte_at(digits, i);
        ok = c == '0' || c == '_';
        i = i + 1;
    }
    return ok;
}

/* An `if` gives its arms' values only when it has both arms. */
static ylong lint_if(LintSt st, Yv *node, int used) {
    (void)lint_node(st, yr_get(node, "cond"), 1);
    if (yv_l(yr_get(st, "chain")) == 0) { (void)lint_if_conds(st, node); }
    int arms = used && yv_b(yr_get(node, "has_else"));
    (void)lint_node(st, yr_get(node, "then"), arms);
    /* An `else if` is an arm of the chain, not an arm of its own: its empty
     * then cannot be dropped (that would make the next `else` the head). */
    ylong wc = yv_l(yr_get(st, "chain"));
    if (yv_l(yr_get(yr_get(node, "els"), "k")) == K_kw_if) { (void)yr_set(st, "chain", yv_long(1)); }
    (void)lint_node(st, yr_get(node, "els"), arms);
    (void)yr_set(st, "chain", yv_long(wc));
    if (yv_l(yr_get(st, "wlevel")) >= 1 && yv_b(yr_get(node, "has_else")) &&
        lint_empty_arm(yr_get(node, "els"))) {
        (void)lint_warn_at(st, ys("the 'else' branch is empty"), node);
    }
    if (yv_l(yr_get(st, "wlevel")) >= 2) {
        (void)lint_short_if(st, node);
    }
    return 0;
}

/* The conditions of a whole `if`/`else if` chain (checked once, at its head): a
 * constant one decides the branch at compile time, and one that repeats an
 * earlier condition of the chain can never be reached -- the earlier one took
 * every case it would. */
static ylong lint_if_conds(LintSt st, Yv *head) {
    Yv *seen = yav(0);
    Yv *cur = head;
    while (yv_l(yr_get(cur, "k")) == K_kw_if) {
        Yv *cond = yr_get(cur, "cond");
        ylong c = lint_bool_lit(cond);
        if (c >= 0) {
            if (yv_l(yr_get(st, "wlevel")) >= 1) { (void)lint_warn_at(st, ys_cat(ys("the condition is always "), c == 1 ? ys("true") : ys("false")), cond); }
        } else {
            for (ylong i = 0; i < yv_len(seen); i++) {
                if (lint_same_node(ya_get(seen, i), cond)) {
                    (void)lint_warn_at(st, ys("this condition repeats an earlier one of the chain, so this branch never runs"), cond);
                }
            }
        }
        seen = ya_push(seen, cond);
        cur = yr_get(cur, "els");
    }
    return 0;
}

/* An arm holding nothing at all: an empty block. Only an `else` is worth a
   word -- `else { }` is what the void redesign made unnecessary, and the
   branch can go. A block with even a `;` in it was written on purpose. */
static int lint_empty_arm(Yv *n) {
    if (yv_l(yr_get(n, "k")) == K_block) {
        return yv_len(yr_get(n, "stmts")) == 0;
    } else {
        return 0;
    }
}

static ylong lint_for(LintSt st, Yv *node) {
    (void)lint_node(st, yr_get(node, "init"), 0);
    lint_loop_head(st, yr_get(node, "cond"), 1);
    lint_loop_head(st, yr_get(node, "step"), 0);
    return lint_loop_body(st, yr_get(node, "body"));
}

/* A loop body: its value is dropped, so a block body's last statement is a
 * statement like the ones before it. Only a block -- gen_discard sends a
 * bare statement through gen_stmt anyway -- and only that block's own list:
 * a block nested inside it (an if arm, say) is generated through gen, so
 * its last statement does produce a value. */
static ylong lint_loop_body(LintSt st, Yv *body) {
    Yv *was = yr_get(st, "dropnext");
    Yv *wv = yr_get(st, "vused");
    Yv *wl = yr_get(st, "loops");
    (void)yr_set(st, "dropnext", yv_bool(yv_l(yr_get(body, "k")) == K_block));
    (void)yr_set(st, "vused", yv_bool(0));
    (void)yr_set(st, "loops", yv_long(yv_l(wl) + 1));
    (void)lint_node(st, body, 0);
    (void)yr_set(st, "dropnext", was);
    (void)yr_set(st, "vused", wv);
    (void)yr_set(st, "loops", wl);
    return 0;
}

static ylong lint_func(LintSt st, Yv *node) {
    /* Note the parameters first: the shortening rules ask whether a name is
     * a str or an array, and one of those names is usually a parameter. */
    Yv *params = yr_get(node, "params");
    Yv *ptypes = yr_get(node, "ptypes");
    ylong line = yv_l(yr_get(node, "line"));
    ylong col = yv_l(yr_get(node, "col"));
    ylong i = 0;
    while (i < yv_len(params) && i < yv_len(ptypes)) {
        (void)lint_note_param(st, ya_get(params, i), ya_get(ptypes, i), line, col);
        i = i + 1;
    }
    if (yv_l(yr_get(st, "wlevel")) >= 2) { (void)lint_alias_param(st, node); }
    Yv *body = yr_get(node, "body");
    int wt = yv_b(yr_get(st, "tailflow"));
    (void)yr_set(st, "tailflow", yv_bool(1));
    ylong r = lint_stmts(st, yr_get(body, "stmts"),
                         !yv_b(yr_get(st, "voidfn")), 0);
    (void)yr_set(st, "tailflow", yv_bool(wt));
    return r;
}

static ylong lint_decl(LintSt st, Yv *node) {
    Yv *v = yr_get(node, "v");
    ylong line = yv_l(yr_get(node, "line"));
    ylong col = yv_l(yr_get(node, "col"));
    if (ys_eq_lit(yr_get(node, "kind"), "def")) {
        (void)lint_note(st, yr_get(node, "name"), ys("def"), line, col, 0, 0,
                        0, 0, 0);
        return lint_def_body(st, yr_get(node, "name"), v);
    } else {
        (void)lint_note(st, yr_get(node, "name"), yr_get(node, "kind"), line,
                        col, lint_scal(yr_get(node, "typ"), v),
                        lint_fresh(v),
                        lint_strheld(yr_get(node, "typ"), v),
                        lint_vec(yr_get(node, "typ"), v),
                        yv_l(yr_get(yr_get(node, "typ"), "k")) == K_tnone);
        return lint_node(st, v, 1);
    }
}

static int lint_scal(Yv *typ, Yv *v) {
    Yv *tk = yr_get(typ, "k");
    Yv *vk = yr_get(v, "k");
    if (yv_l(tk) == K_tlong || yv_l(tk) == K_tfloat ||
        yv_l(tk) == K_tbyte || yv_l(tk) == K_tstr ||
        yv_l(tk) == K_tbool) {
        return 1;
    } else {
        return yv_l(vk) == K_num || yv_l(vk) == K_str ||
               yv_l(vk) == K_char || yv_l(vk) == K_bool;
    }
}

static int lint_fresh(Yv *v) {
    Yv *vk = yr_get(v, "k");
    return yv_l(vk) == K_array || yv_l(vk) == K_arrrep;
}

static ylong lint_assign(LintSt st, Yv *node) {
    Yv *name = yr_get(node, "name");
    Yv *v = yr_get(node, "v");
    (void)lint_mark(st, name, 2);
    (void)lint_node(st, v, 1);
    if (yv_l(yr_get(v, "k")) == K_id && ys_eq(yr_get(v, "v"), name)) {
        (void)lint_warn_at(st,
                           lint_cat(3, ys("'"), lint_disp(name),
                                    ys("' is assigned to itself")),
                           node);
    }
    if (yv_l(yr_get(st, "wlevel")) >= 2) {
        (void)lint_short_assign(st, node, name, v);
    }
    return 0;
}

static ylong lint_incdec(LintSt st, Yv *node, int used) {
    Yv *t = yr_get(node, "tgt");
    if (yv_l(yr_get(t, "k")) == K_id) {
        (void)lint_mark(st, yr_get(t, "v"), 2);
        if (used) {
            (void)lint_mark(st, yr_get(t, "v"), 1);
        }
        return 0;
    } else {
        return lint_node(st, t, 1);
    }
}

static ylong lint_opassign(LintSt st, Yv *node, int used) {
    Yv *t = yr_get(node, "tgt");
    Yv *op = yr_get(node, "op");
    Yv *v = yr_get(node, "v");
    (void)lint_node(st, v, 1);
    if (yv_l(yr_get(t, "k")) == K_id) {
        if (ys_eq_lit(op, "+") || ys_eq_lit(op, "*")) {
            (void)lint_mark(st, yr_get(t, "v"), 4);
        } else {
            (void)lint_mark(st, yr_get(t, "v"), 2);
        }
        if (used) {
            (void)lint_mark(st, yr_get(t, "v"), 1);
        }
    } else {
        (void)lint_node(st, t, 1);
    }
    if ((ys_eq_lit(op, "/") || ys_eq_lit(op, "%")) && lint_zero(v)) {
        (void)lint_warn_at(st, ys("division by zero"), node);
    }
    /* A value-used `+=` on a string is `s = s + t`: the ownership cell is
     * dropped, so the buffer is exactly as long as the result and nothing
     * can append to it in place again. That is what keeps a string already
     * read from `s` stable -- but it also means the whole string is copied
     * here, and a loop of these copies it once per iteration: 10,000 of
     * them building 120 KB allocate 1.2 GB. An append statement is O(1)
     * amortised instead (see gen_sappend), so the one-character difference
     * is worth naming. It is advice rather than an error because the value
     * may well be wanted. */
    if (yv_l(yr_get(st, "loops")) > 0 &&
        (used || yv_b(yr_get(st, "vused"))) && ys_eq_lit(op, "+") && yv_l(yr_get(t, "k")) == K_id &&
        lint_var_str(st, yr_get(t, "v"))) {
        (void)lint_warn_at(
            st,
            ys("this `+=` on a string copies the whole string, so a loop of "
               "them is quadratic -- add a `;` if nothing reads the value"),
            node);
    }
    if (yv_l(yr_get(st, "wlevel")) >= 2 && yv_l(yr_get(t, "k")) == K_id &&
        (ys_eq_lit(op, "+") || ys_eq_lit(op, "-")) && lint_int_val(v) == 1 &&
        lint_var_scal(st, yr_get(t, "v"))) {
        Yv *d = lint_disp(yr_get(t, "v"));
        Yv *rs = ys_eq_lit(op, "+") ? ys("++") : ys("--");
        (void)lint_warn_at(st,
                           lint_cat(8, ys("'"), d, ys(" "), op,
                                    ys("= 1' can be written '"), d, rs, ys("'")),
                           node);
    }
    return 0;
}

/* A record or map literal giving a key twice keeps the last value; the
 * earlier one is computed for nothing. */
static ylong lint_lit(LintSt st, Yv *node, Yv *what, Yv *kind) {
    Yv *keys = yr_get(node, "keys");
    (void)lint_list(st, yr_get(node, "vals"));
    ylong i = 0;
    while (i < yv_len(keys)) {
        Yv *key = ya_get(keys, i);
        if (!ys_eq_lit(key, "...") && lint_seen(keys, i)) {
            (void)lint_warn_at(st,
                               lint_cat(7, ys("duplicate "), what, ys(" '"),
                                        key, ys("' in a "), kind,
                                        ys(" literal; the last one wins")),
                               node);
        }
        i = i + 1;
    }
    return 0;
}

static int lint_seen(Yv *keys, ylong i) {
    Yv *key = ya_get(keys, i);
    int found = 0;
    ylong j = 0;
    while (!found && j < i) {
        found = ys_eq(ya_get(keys, j), key);
        j = j + 1;
    }
    return found;
}

/* Every noted binding: read is fine; grown is fine unless the growth is
 * only its own (a number's, or a fresh array's never reassigned). */
static ylong lint_vars(LintSt st) {
    Yv *flags = yr_get(st, "flags");
    Yv *vars = yr_get(st, "vars");
    ylong i = 0;
    while (i < yv_len(vars)) {
        LintVar v = ya_get(vars, i);
        ylong num = yv_l(yr_get(v, "num"));
        ylong f = 0;
        Yv *word;
        Yv *name;
        ylong line;
        ylong col;
        if (yv_b(yr_get(v, "top"))) {
            i = i + 1;
            continue;
        }
        if (num < yv_len(flags)) {
            f = yv_l(ya_get(flags, num));
        }
        word = lint_word(yr_get(v, "kind"));
        name = yr_get(v, "name");
        line = yv_l(yr_get(v, "line"));
        col = yv_l(yr_get(v, "col"));
        /* Rule 2.10: read exactly once, in the statement after its `let`, and
         * never assigned again. Inline it there. */
        if (yv_l(yr_get(st, "wlevel")) >= 2 &&
            ys_eq_lit(yr_get(v, "kind"), "let") &&
            yv_b(yr_get(v, "untyped")) && (f & 1) != 0 && (f & 6) == 0 &&
            num < yv_len(yr_get(st, "reads")) &&
            yv_l(ya_get(yr_get(st, "reads"), num)) == 1 &&
            yv_l(ya_get(yr_get(st, "rline"), num)) == line + 1) {
            Yv *at = yr(4, "k", yv_long(K_err), "msg", ys(""), "line",
                        yv_long(line), "col", yv_long(col));
            (void)lint_warn_at(
                st,
                lint_cat(3, ys("'"), name,
                         ys("' is read once; write its value where it is used")),
                at);
        }
        if ((f & 1) != 0) {
            ;
        } else if ((f & 4) != 0 &&
                   !(yv_b(yr_get(v, "scal")) ||
                     (yv_b(yr_get(v, "fresh")) && (f & 2) == 0))) {
            ;
        } else if ((f & 6) != 0) {
            (void)lint_warn(st,
                            lint_cat(4, word, ys(" '"), name,
                                     ys("' is assigned but never read")),
                            line, col);
        } else {
            (void)lint_warn(st,
                            lint_cat(5, ys("unused "), word, ys(" '"), name,
                                     ys("'")),
                            line, col);
        }
        i = i + 1;
    }
    return 0;
}

static Yv *lint_word(Yv *kind) {
    if (ys_eq_lit(kind, "let")) {
        return ys("variable");
    } else if (ys_eq_lit(kind, "const")) {
        return ys("constant");
    } else {
        return ys("function");
    }
}

/* ── the parse tree: types ───────────────────────────────────────────────
 * Every annotation (a let's or const's, a parameter's, a return type, an
 * alias's) is a root. A type's key is one string per type: aliases
 * expanded, a union's members sorted. The records of two or more fields
 * and the unions in a root are its occurrences, outer before inner, each
 * at its root's position. */

static ylong lint_types(LintSt st, Yv *stmts) {
    Yv *roots = yav(0);
    Yv *atyps = yav(0);
    Yv *amemo = yav(0);
    Yv *abusy = yav(0);
    Yv *occs = yav(0);
    Yv *amods = yav(0);
    LintTy t = yr(10, "roots", roots, "atyps", atyps, "amods", amods,
                  "amap", nameix_new(64), "amemo", amemo, "abusy", abusy,
                  "occs", occs, "line", yv_long(0), "col", yv_long(0),
                  "mod", ys(""));
    (void)lint_tw_list(t, stmts);
    /* The aliases: a name declared again is the last declaration's. */
    Yv *rs = yr_get(t, "roots");
    ylong i = 0;
    while (i < yv_len(rs)) {
        LintRoot r = ya_get(rs, i);
        Yv *alias = yr_get(r, "alias");
        if (!ys_eq_lit(alias, "")) {
            if (nameix_get(yr_get(t, "amap"), alias) >= 0) {
                (void)lint_warn(
                    st,
                    lint_cat(3, ys("type '"), alias,
                             ys("' is declared more than once; the last "
                                "declaration counts")),
                    yv_l(yr_get(r, "line")), yv_l(yr_get(r, "col")));
            }
            nameix_put(yr_get(t, "amap"), alias,
                               yv_len(yr_get(t, "atyps")));
            (void)ya_push(yr_get(t, "atyps"), yr_get(r, "typ"));
            (void)ya_push(yr_get(t, "amods"), yr_get(r, "mod"));
            (void)ya_push(yr_get(t, "amemo"), ys(""));
            (void)ya_push(yr_get(t, "abusy"), yv_bool(0));
        }
        i = i + 1;
    }
    /* An alias's own type is its declaration, not a use; only the last
     * declaration of a name names a type. */
    ylong tdi = 0;
    i = 0;
    while (i < yv_len(rs)) {
        LintRoot r = ya_get(rs, i);
        (void)yr_set(t, "line", yv_long(yv_l(yr_get(r, "line"))));
        (void)yr_set(t, "col", yv_long(yv_l(yr_get(r, "col"))));
        (void)yr_set(t, "mod", yr_get(r, "mod"));
        ylong first = yv_len(yr_get(t, "occs"));
        (void)lint_tk(t, yr_get(r, "typ"), 1, -1);
        Yv *alias = yr_get(r, "alias");
        if (!ys_eq_lit(alias, "")) {
            if (yv_len(yr_get(t, "occs")) > first &&
                lint_cand(yr_get(r, "typ"))) {
                LintOcc o = ya_get(yr_get(t, "occs"), first);
                (void)yr_set(o, "decl", yv_bool(1));
                if (nameix_get(yr_get(t, "amap"), alias) == tdi) {
                    (void)yr_set(o, "alias", alias);
                }
            }
            tdi = tdi + 1;
        }
        i = i + 1;
    }
    return lint_report(st, t);
}

static ylong lint_tw_list(LintTy t, Yv *nodes) {
    ylong i = 0;
    while (i < yv_len(nodes)) {
        (void)lint_tw(t, ya_get(nodes, i));
        i = i + 1;
    }
    return 0;
}

static ylong lint_tw(LintTy t, Yv *node) {
    Yv *k = yr_get(node, "k");
    if (yv_l(k) == K_id || yv_l(k) == K_str || yv_l(k) == K_num) {
        return 0;
    } else if (yv_l(k) == K_call) {
        (void)lint_tw(t, yr_get(node, "callee"));
        return lint_tw_list(t, yr_get(node, "args"));
    } else if (yv_l(k) == K_dot) {
        return lint_tw(t, yr_get(node, "obj"));
    } else if (yv_l(k) == K_bin) {
        (void)lint_tw(t, yr_get(node, "l"));
        return lint_tw(t, yr_get(node, "r"));
    } else if (yv_l(k) == K_decl) {
        return lint_tw_decl(t, node);
    } else if (yv_l(k) == K_block) {
        return lint_tw_list(t, yr_get(node, "stmts"));
    } else if (yv_l(k) == K_kw_if) {
        (void)lint_tw(t, yr_get(node, "cond"));
        (void)lint_tw(t, yr_get(node, "then"));
        return lint_tw(t, yr_get(node, "els"));
    } else if (yv_l(k) == K_assign || yv_l(k) == K_arrrep) {
        return lint_tw(t, yr_get(node, "v"));
    } else if (yv_l(k) == K_index) {
        (void)lint_tw(t, yr_get(node, "arr"));
        return lint_tw(t, yr_get(node, "idx"));
    } else if (yv_l(k) == K_rec || yv_l(k) == K_map) {
        return lint_tw_list(t, yr_get(node, "vals"));
    } else if (yv_l(k) == K_array) {
        return lint_tw_list(t, yr_get(node, "elems"));
    } else if (yv_l(k) == K_ret || yv_l(k) == K_un ||
               yv_l(k) == K_addr || yv_l(k) == K_deref ||
               yv_l(k) == K_rectest || yv_l(k) == K_narrow ||
               yv_l(k) == K_matchend) {
        return lint_tw_one(t, node);
    } else if (yv_l(k) == K_func) {
        return lint_tw_func(t, node);
    } else if (yv_l(k) == K_typedef) {
        return lint_root(t, yr_get(node, "typ"), yv_l(yr_get(node, "line")),
                         yv_l(yr_get(node, "col")), yr_get(node, "name"));
    } else if (yv_l(k) == K_opassign) {
        (void)lint_tw(t, yr_get(node, "tgt"));
        return lint_tw(t, yr_get(node, "v"));
    } else if (yv_l(k) == K_kw_while) {
        (void)lint_tw(t, yr_get(node, "cond"));
        return lint_tw(t, yr_get(node, "body"));
    } else if (yv_l(k) == K_incdec) {
        return lint_tw(t, yr_get(node, "tgt"));
    } else if (yv_l(k) == K_idxassign) {
        (void)lint_tw(t, yr_get(node, "arr"));
        (void)lint_tw(t, yr_get(node, "idx"));
        return lint_tw(t, yr_get(node, "v"));
    } else if (yv_l(k) == K_dotassign) {
        (void)lint_tw(t, yr_get(node, "obj"));
        return lint_tw(t, yr_get(node, "v"));
    } else if (yv_l(k) == K_slice) {
        (void)lint_tw(t, yr_get(node, "arr"));
        (void)lint_tw(t, yr_get(node, "lo"));
        return lint_tw(t, yr_get(node, "hi"));
    } else if (yv_l(k) == K_kw_for) {
        (void)lint_tw(t, yr_get(node, "init"));
        (void)lint_tw(t, yr_get(node, "cond"));
        (void)lint_tw(t, yr_get(node, "step"));
        return lint_tw(t, yr_get(node, "body"));
    } else if (yv_l(k) == K_kw_foreach) {
        (void)lint_tw(t, yr_get(node, "iter"));
        return lint_tw(t, yr_get(node, "body"));
    } else if (yv_l(k) == K_forrange) {
        (void)lint_tw(t, yr_get(node, "lo"));
        (void)lint_tw(t, yr_get(node, "hi"));
        return lint_tw(t, yr_get(node, "body"));
    } else if (yv_l(k) == K_store) {
        (void)lint_tw(t, yr_get(node, "p"));
        return lint_tw(t, yr_get(node, "v"));
    } else if (yv_l(k) == K_sliceassign) {
        (void)lint_tw(t, yr_get(node, "arr"));
        (void)lint_tw(t, yr_get(node, "lo"));
        (void)lint_tw(t, yr_get(node, "hi"));
        return lint_tw(t, yr_get(node, "v"));
    } else {
        return 0;
    }
}

static ylong lint_tw_one(LintTy t, Yv *node) {
    return lint_tw(t, yr_get(node, "e"));
}

static ylong lint_tw_decl(LintTy t, Yv *node) {
    if (!ys_eq_lit(yr_get(node, "kind"), "def")) {
        (void)lint_root(t, yr_get(node, "typ"), yv_l(yr_get(node, "line")),
                        yv_l(yr_get(node, "col")), ys(""));
    }
    return lint_tw(t, yr_get(node, "v"));
}

static ylong lint_tw_func(LintTy t, Yv *node) {
    ylong line = yv_l(yr_get(node, "line"));
    ylong col = yv_l(yr_get(node, "col"));
    Yv *ps = yr_get(node, "ptypes");
    ylong i = 0;
    while (i < yv_len(ps)) {
        (void)lint_root(t, ya_get(ps, i), line, col, ys(""));
        i = i + 1;
    }
    (void)lint_root(t, yr_get(node, "ret"), line, col, ys(""));
    return lint_tw(t, yr_get(node, "body"));
}

static ylong lint_root(LintTy t, Yv *typ, ylong line, ylong col, Yv *alias) {
    if (yv_l(yr_get(typ, "k")) != K_tnone) {
        /* a module's alias is its own: `m.T` (rename.c rn_prepass_one) */
        Yv *m = lint_mod_of(line);
        Yv *name = alias;
        if (!ys_eq_lit(m, "") && !ys_eq_lit(alias, "")) {
            name = ys_cat(ys_cat(m, ys(".")), alias);
        }
        (void)ya_push(yr_get(t, "roots"),
                      yr(5, "typ", typ, "line", yv_long(line), "col",
                         yv_long(col), "alias", name, "mod", m));
    }
    return 0;
}

/* The module line ln is in ("" for none). */
static Yv *lint_mod_of(ylong ln) {
    if (lint_ofile != NULL && ln >= 1 && ln <= yv_len(lint_ofile)) {
        ylong f = yv_l(ya_get(lint_ofile, ln - 1));
        if (f < yv_len(lint_fmods)) {
            return ya_get(lint_fmods, f);
        } else {
            return ys("");
        }
    } else {
        return ys("");
    }
}

/* An occurrence: a record of two or more fields, or a union. */
static int lint_cand(Yv *ty) {
    Yv *k = yr_get(ty, "k");
    if (yv_l(k) == K_trec) {
        Yv *fs = yr_get(ty, "fields");
        /* mutex and sem are records too, but named ones (parser.c sync_type) */
        return yv_len(fs) >= 2 && !ys_starts_with(yr_get(ya_get(fs, 0), "name"), ys("$"));
    } else {
        return yv_l(k) == K_tunion;
    }
}

/* The key of `ty`; with `rec`, its occurrences are noted (`parent`: the
 * one it is in, or -1). */
static Yv *lint_tk(LintTy t, Yv *ty, int rec, ylong parent) {
    Yv *k = yr_get(ty, "k");
    if (yv_l(k) == K_tname) {
        return lint_tk_name(t, yr_get(ty, "name"));
    } else if (yv_l(k) == K_tptr) {
        return ys_cat(ys("*"), lint_tk(t, yr_get(ty, "to"), rec, parent));
    } else if (yv_l(k) == K_tarr) {
        return lint_cat(3, ys("["), lint_tk(t, yr_get(ty, "of"), rec, parent),
                        ys("]"));
    } else if (yv_l(k) == K_tarrfix) {
        return lint_cat(5, ys("["), lint_tk(t, yr_get(ty, "of"), rec, parent),
                        ys(";"), ys_tostring(yr_get(ty, "n")), ys("]"));
    } else if (yv_l(k) == K_topt) {
        return ys_cat(lint_tk(t, yr_get(ty, "of"), rec, parent), ys("?"));
    } else if (yv_l(k) == K_tmap) {
        Yv *kk = lint_tk(t, yr_get(ty, "key"), rec, parent);
        return lint_cat(5, ys("{"), kk, ys("=>"),
                        lint_tk(t, yr_get(ty, "of"), rec, parent), ys("}"));
    } else if (yv_l(k) == K_tfunc) {
        Yv *ak = lint_tk_list(t, yr_get(ty, "args"), rec, parent);
        return lint_cat(4, ys("("), ak, ys(")->"),
                        lint_tk(t, yr_get(ty, "ret"), rec, parent));
    } else if (yv_l(k) == K_tparams) {
        return lint_cat(3, ys("("),
                        lint_tk_list(t, yr_get(ty, "ts"), rec, parent),
                        ys(")"));
    } else if (yv_l(k) == K_trec) {
        return lint_tk_rec(t, ty, rec, parent);
    } else if (yv_l(k) == K_tunion) {
        return lint_tk_union(t, ty, rec, parent);
    } else {
        return ktag(yv_l(k));
    }
}

static Yv *lint_tk_list(LintTy t, Yv *ts, int rec, ylong parent) {
    Yv *parts = yav(0);
    ylong i = 0;
    while (i < yv_len(ts)) {
        parts = ya_push(parts, lint_tk(t, ya_get(ts, i), rec, parent));
        i = i + 1;
    }
    return ys_join(parts, ys(","));
}

/* An alias is expanded once (rec off: its own occurrences are its
 * declaration's); one met again inside itself stays `@Name`, as does a
 * name no alias declares. */
static Yv *lint_tk_name(LintTy t, Yv *name) {
    /* in a module's code a bare name is the module's own alias first */
    ylong ai = -1;
    Yv *tm = yr_get(t, "mod");
    if (!ys_eq_lit(tm, "") && ys_index_of(name, ys(".")) < 0) {
        ai = nameix_get(yr_get(t, "amap"), ys_cat(ys_cat(tm, ys(".")), name));
    }
    if (ai < 0) {
        ai = nameix_get(yr_get(t, "amap"), name);
    }
    if (ai < 0) {
        return ys_cat(ys("@"), name);
    } else if (yv_b(ya_get(yr_get(t, "abusy"), ai))) {
        return ys_cat(ys("@"), name);
    } else if (!ys_eq_lit(ya_get(yr_get(t, "amemo"), ai), "")) {
        return ya_get(yr_get(t, "amemo"), ai);
    } else {
        ya_set(yr_get(t, "abusy"), ai, yv_bool(1));
        /* an alias's type reads in its own module */
        Yv *mod0 = yr_get(t, "mod");
        (void)yr_set(t, "mod", ya_get(yr_get(t, "amods"), ai));
        Yv *key = lint_tk(t, ya_get(yr_get(t, "atyps"), ai), 0, -1);
        (void)yr_set(t, "mod", mod0);
        ya_set(yr_get(t, "abusy"), ai, yv_bool(0));
        ya_set(yr_get(t, "amemo"), ai, key);
        return key;
    }
}

static Yv *lint_tk_rec(LintTy t, Yv *ty, int rec, ylong parent) {
    Yv *fs = yr_get(ty, "fields");
    ylong me = parent;
    if (rec && lint_cand(ty)) {
        me = lint_occ(t, ty, parent);
    }
    Yv *parts = yav(0);
    ylong i = 0;
    while (i < yv_len(fs)) {
        Yv *f = ya_get(fs, i);
        parts = ya_push(parts, lint_cat(3, yr_get(f, "name"), ys(":"),
                                        lint_tk(t, yr_get(f, "typ"), rec,
                                                me)));
        i = i + 1;
    }
    Yv *key = lint_cat(3, ys("{"), ys_join(parts, ys(",")), ys("}"));
    if (me != parent) {
        (void)lint_occ_key(t, me, key);
    }
    return key;
}

/* A union's key lists its members sorted, without repeats, an alias of a
 * union replaced by its members: `A | B`, `B | A` and `AB | A` agree. */
static Yv *lint_tk_union(LintTy t, Yv *ty, int rec, ylong parent) {
    ylong me = parent;
    if (rec) {
        me = lint_occ(t, ty, parent);
    }
    Yv *parts = yav(0);
    (void)lint_tk_members(t, ty, rec, me, parts);
    Yv *key = lint_cat(3, ys("("), ys_join(lint_sort_uniq(parts), ys("|")),
                       ys(")"));
    if (me != parent) {
        (void)lint_occ_key(t, me, key);
    }
    return key;
}

static ylong lint_tk_members(LintTy t, Yv *u, int rec, ylong me, Yv *parts) {
    Yv *ts = yr_get(u, "ts");
    ylong i = 0;
    while (i < yv_len(ts)) {
        Yv *m = ya_get(ts, i);
        ylong ai = lint_union_alias(t, m);
        if (ai >= 0) {
            ya_set(yr_get(t, "abusy"), ai, yv_bool(1));
            (void)lint_tk_members(t, ya_get(yr_get(t, "atyps"), ai), 0, me,
                                  parts);
            ya_set(yr_get(t, "abusy"), ai, yv_bool(0));
        } else {
            (void)ya_push(parts, lint_tk(t, m, rec, me));
        }
        i = i + 1;
    }
    return 0;
}

/* The alias a union member names when it is a union (and not one being
 * expanded), or -1. */
static ylong lint_union_alias(LintTy t, Yv *m) {
    if (yv_l(yr_get(m, "k")) == K_tname) {
        ylong ai = nameix_get(yr_get(t, "amap"), yr_get(m, "name"));
        if (ai < 0) {
            return -1;
        } else if (yv_b(ya_get(yr_get(t, "abusy"), ai))) {
            return -1;
        } else if (lint_is_union(ya_get(yr_get(t, "atyps"), ai))) {
            return ai;
        } else {
            return -1;
        }
    } else {
        return -1;
    }
}

static int lint_is_union(Yv *ty) {
    return yv_l(yr_get(ty, "k")) == K_tunion;
}

static ylong lint_occ(LintTy t, Yv *ty, ylong parent) {
    (void)ya_push(yr_get(t, "occs"),
                  yr(8, "key", ys(""), "typ", ty, "line",
                     yv_long(yv_l(yr_get(t, "line"))), "col",
                     yv_long(yv_l(yr_get(t, "col"))), "parent",
                     yv_long(parent), "decl", yv_bool(0), "alias", ys(""),
                     "rep", yv_bool(0)));
    return yv_len(yr_get(t, "occs")) - 1;
}

static ylong lint_occ_key(LintTy t, ylong i, Yv *key) {
    LintOcc o = ya_get(yr_get(t, "occs"), i);
    (void)yr_set(o, "key", key);
    return 0;
}

static Yv *lint_sort_uniq(Yv *xs) {
    Yv *out = yav(0);
    ylong i = 0;
    while (i < yv_len(xs)) {
        Yv *x = ya_get(xs, i);
        ylong j = yv_len(out);
        out = ya_push(out, x);
        while (j > 0 && ys_cmp(x, ya_get(out, j - 1)) < 0) {
            ya_set(out, j, ya_get(out, j - 1));
            j = j - 1;
        }
        ya_set(out, j, x);
        i = i + 1;
    }
    Yv *res = yav(0);
    ylong k = 0;
    while (k < yv_len(out)) {
        if (k == 0 || !ys_eq(ya_get(out, k), ya_get(out, k - 1))) {
            res = ya_push(res, ya_get(out, k));
        }
        k = k + 1;
    }
    return res;
}

/* Every occurrence by its key. One an alias names (other than that
 * alias's declaration) says so; then one written out twice or more is
 * reported once, at its first place. An occurrence inside one reported is
 * not reported again, and inside one an alias names it does not count:
 * the alias replaces it. So the counting comes first, and the reporting
 * goes outer before inner. */
static ylong lint_report(LintSt st, LintTy t) {
    Yv *occs = yr_get(t, "occs");
    Yv *ids = nameix_new(64);
    Yv *counts = yav(0);
    Yv *alias_of = yav(0);
    Yv *told = yav(0);
    Yv *occ_id = yav(0);
    ylong q = 0;
    while (q < yv_len(occs)) {
        LintOcc o = ya_get(occs, q);
        ylong id = nameix_get(ids, yr_get(o, "key"));
        if (id < 0) {
            id = yv_len(counts);
            nameix_put(ids, yr_get(o, "key"), id);
            counts = ya_push(counts, yv_long(0));
            alias_of = ya_push(alias_of, ys(""));
            told = ya_push(told, yv_bool(0));
        }
        occ_id = ya_push(occ_id, yv_long(id));
        Yv *alias = yr_get(o, "alias");
        if (!ys_eq_lit(alias, "")) {
            if (ys_eq_lit(ya_get(alias_of, id), "")) {
                ya_set(alias_of, id, alias);
            } else if (!ys_eq(ya_get(alias_of, id), alias)) {
                (void)lint_warn(st,
                                lint_cat(5, ys("type '"), alias,
                                         ys("' is the same type as '"),
                                         ya_get(alias_of, id), ys("'")),
                                yv_l(yr_get(o, "line")),
                                yv_l(yr_get(o, "col")));
                (void)yr_set(o, "rep", yv_bool(1));
            }
        }
        q = q + 1;
    }
    /* `gone`: inside one an alias names (or a repeated declaration). */
    Yv *gone = yav(0);
    ylong i = 0;
    while (i < yv_len(occs)) {
        LintOcc o = ya_get(occs, i);
        ylong id = yv_l(ya_get(occ_id, i));
        ylong parent = yv_l(yr_get(o, "parent"));
        int g = yv_b(yr_get(o, "rep")) ||
                (parent >= 0 && yv_b(ya_get(gone, parent)));
        if (!g && !yv_b(yr_get(o, "decl"))) {
            if (!ys_eq_lit(ya_get(alias_of, id), "")) {
                g = 1;
            } else {
                ya_set(counts, id, yv_long(yv_l(ya_get(counts, id)) + 1));
            }
        }
        gone = ya_push(gone, yv_bool(g));
        i = i + 1;
    }
    i = 0;
    while (i < yv_len(occs)) {
        LintOcc o = ya_get(occs, i);
        ylong id = yv_l(ya_get(occ_id, i));
        ylong parent = yv_l(yr_get(o, "parent"));
        if (parent >= 0 && lint_rep(occs, parent)) {
            (void)yr_set(o, "rep", yv_bool(1));
        } else if (yv_b(yr_get(o, "decl"))) {
            ;
        } else if (!ys_eq_lit(ya_get(alias_of, id), "")) {
            (void)lint_warn(st,
                            lint_cat(5, ys("the type "),
                                     tstr(yr_get(o, "typ")),
                                     ys(" is already declared as '"),
                                     ya_get(alias_of, id),
                                     ys("'; use the alias")),
                            yv_l(yr_get(o, "line")), yv_l(yr_get(o, "col")));
            (void)yr_set(o, "rep", yv_bool(1));
        } else if (yv_l(ya_get(counts, id)) >= 2) {
            if (!yv_b(ya_get(told, id))) {
                (void)lint_warn(st,
                                lint_cat(5, ys("the type "),
                                         tstr(yr_get(o, "typ")),
                                         ys(" is written out "),
                                         ys_tostring(ya_get(counts, id)),
                                         ys(" times; name it with `type`")),
                                yv_l(yr_get(o, "line")),
                                yv_l(yr_get(o, "col")));
                ya_set(told, id, yv_bool(1));
            }
            (void)yr_set(o, "rep", yv_bool(1));
        }
        i = i + 1;
    }
    return 0;
}

static int lint_rep(Yv *occs, ylong i) {
    LintOcc o = ya_get(occs, i);
    return yv_b(yr_get(o, "rep"));
}

/* ── output ──────────────────────────────────────────────────────────── */

/* By position, then message; a warning made twice is given once. */
static Yv *lint_sorted(Yv *ws) {
    Yv *all = lint_msort(ws);
    Yv *out = yav(0);
    ylong i = 0;
    while (i < yv_len(all)) {
        Diag w = ya_get(all, i);
        ylong n = yv_len(out);
        if (n == 0 || lint_before(ya_get(out, n - 1), w)) {
            out = ya_push(out, w);
        }
        i = i + 1;
    }
    return out;
}

static Yv *lint_msort(Yv *ws) {
    ylong n = yv_len(ws);
    if (n < 2) {
        return ws;
    } else {
        Yv *a = lint_msort(ya_slice(ws, 0, n / 2));
        Yv *b = lint_msort(ya_slice(ws, n / 2, n));
        Yv *out = yav(0);
        ylong i = 0;
        ylong j = 0;
        while (i < yv_len(a) || j < yv_len(b)) {
            if (j >= yv_len(b) ||
                (i < yv_len(a) && !lint_before(ya_get(b, j), ya_get(a, i)))) {
                out = ya_push(out, ya_get(a, i));
                i = i + 1;
            } else {
                out = ya_push(out, ya_get(b, j));
                j = j + 1;
            }
        }
        return out;
    }
}

static int lint_before(Diag a, Diag b) {
    if (yv_l(yr_get(a, "line")) != yv_l(yr_get(b, "line"))) {
        return yv_l(yr_get(a, "line")) < yv_l(yr_get(b, "line"));
    } else if (yv_l(yr_get(a, "col")) != yv_l(yr_get(b, "col"))) {
        return yv_l(yr_get(a, "col")) < yv_l(yr_get(b, "col"));
    } else {
        return ys_cmp(yr_get(a, "msg"), yr_get(b, "msg")) < 0;
    }
}
