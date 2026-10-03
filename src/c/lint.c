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
#include "lint.h"

#include <stdarg.h>

#include "types.h"

/* types.y's alias (lint.y imports types.y) */
typedef Yv *Diag;
typedef Yv *LintVar;
typedef Yv *LintSt;
typedef Yv *LintMap;
typedef Yv *LintRoot;
typedef Yv *LintOcc;
typedef Yv *LintTy;

/* ── module-local defs (forward) ─────────────────────────────────────── */
static Yv *lint_cat(size_t n, ...);
static long lint_warn(LintSt st, Yv *msg, long line, long col);
static Yv *lint_disp(Yv *name);
static long lint_num(Yv *name);
static long lint_mark(LintSt st, Yv *name, long bit);
static long lint_note(LintSt st, Yv *name, Yv *kind, long line, long col,
                      int scal, int fresh);
static long lint_stmts(LintSt st, Yv *stmts, int used, int top);
static long lint_warn_at(LintSt st, Yv *msg, Yv *node);
static long lint_warn_start(LintSt st, Yv *msg, Yv *node);
static long lint_stmt(LintSt st, Yv *s, int used, int top);
static int lint_code(Yv *s);
static int lint_diverges(Yv *s);
static int lint_any_diverges(Yv *stmts);
static long lint_node(LintSt st, Yv *node, int used);
static long lint_one(LintSt st, Yv *node, int used);
static long lint_list(LintSt st, Yv *nodes);
static long lint_two(LintSt st, Yv *a, Yv *b);
static long lint_id(LintSt st, Yv *node, int used);
static long lint_un(LintSt st, Yv *node, int used);
static long lint_bin(LintSt st, Yv *node, int used);
static int lint_same_id(Yv *l, Yv *r);
static int lint_effect(Yv *node);
static int lint_effect_logic(Yv *node);
static int lint_zero(Yv *node);
static int lint_zero_text(Yv *s);
static long lint_if(LintSt st, Yv *node, int used);
static long lint_for(LintSt st, Yv *node);
static long lint_func(LintSt st, Yv *node);
static long lint_decl(LintSt st, Yv *node);
static int lint_scal(Yv *typ, Yv *v);
static int lint_fresh(Yv *v);
static long lint_assign(LintSt st, Yv *node);
static long lint_incdec(LintSt st, Yv *node, int used);
static long lint_opassign(LintSt st, Yv *node, int used);
static long lint_lit(LintSt st, Yv *node, Yv *what, Yv *kind);
static int lint_seen(Yv *keys, long i);
static long lint_vars(LintSt st);
static Yv *lint_word(Yv *kind);
static long lint_types(LintSt st, Yv *stmts);
static long lint_tw_list(LintTy t, Yv *nodes);
static long lint_tw(LintTy t, Yv *node);
static long lint_tw_one(LintTy t, Yv *node);
static long lint_tw_decl(LintTy t, Yv *node);
static long lint_tw_func(LintTy t, Yv *node);
static long lint_root(LintTy t, Yv *typ, long line, long col, Yv *alias);
static Yv *lint_mod_of(long ln);
static int lint_cand(Yv *ty);
static Yv *lint_tk(LintTy t, Yv *ty, int rec, long parent);
static Yv *lint_tk_list(LintTy t, Yv *ts, int rec, long parent);
static Yv *lint_tk_name(LintTy t, Yv *name);
static Yv *lint_tk_rec(LintTy t, Yv *ty, int rec, long parent);
static Yv *lint_tk_union(LintTy t, Yv *ty, int rec, long parent);
static long lint_tk_members(LintTy t, Yv *u, int rec, long me, Yv *parts);
static long lint_union_alias(LintTy t, Yv *m);
static int lint_is_union(Yv *ty);
static long lint_occ(LintTy t, Yv *ty, long parent);
static long lint_occ_key(LintTy t, long i, Yv *key);
static Yv *lint_sort_uniq(Yv *xs);
static long lint_report(LintSt st, LintTy t);
static int lint_rep(Yv *occs, long i);
static LintMap lint_map_new(void);
static LintMap lint_map_alloc(long cap);
static long lint_hash(Yv *s);
static long lint_map_slot(LintMap m, Yv *key);
static long lint_map_get(LintMap m, Yv *key);
static long lint_map_put(LintMap m, Yv *key, long v);
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
static Yv *lint_fmods;

/* The warnings for one unit: `ast` as parsed, `ast3` renamed (and
 * checked), sorted by position; ofile and fmods say which lines are a
 * module's. */
Yv *lint_unit(Yv *ast, Yv *ast3, Yv *ofile, Yv *fmods) {
    lint_ofile = ofile;
    lint_fmods = fmods;
    Yv *warns = yav(0);
    Yv *vars = yav(0);
    Yv *flags = yav(0);
    LintSt st = yr(3, "warns", warns, "vars", vars, "flags", flags);
    (void)lint_stmts(st, yr_get(ast3, "stmts"), 0, 1);
    (void)lint_vars(st);
    (void)lint_types(st, yr_get(ast, "stmts"));
    return lint_sorted(yr_get(st, "warns"));
}

static long lint_warn(LintSt st, Yv *msg, long line, long col) {
    (void)ya_push(yr_get(st, "warns"), yr(3, "msg", msg, "line",
                                          yv_long(line), "col",
                                          yv_long(col)));
    return 0;
}

/* ── the renamed tree ────────────────────────────────────────────────── */

/* The name a binding was written with: `orig$N` less `$N` (and a shadowed
 * def's `$shadowI`); "" for one the parser made up (a match subject). */
static Yv *lint_disp(Yv *name) {
    long d = ys_index_of(name, ys("$"));
    if (d < 0) {
        return name;
    } else {
        return ys_slice(name, 0, d);
    }
}

/* N of a renamed binding `orig$N`, or 0 for a name rename.c left alone (a
 * builtin, `self`, a package's qualified name). N counts from 1. */
static long lint_num(Yv *name) {
    long i = yv_len(name) - 1;
    long v = 0;
    long m = 1;
    int go = 1;
    while (go && i >= 0) {
        long c = ys_byte_at(name, i);
        if (c >= 48 && c <= 57) {
            v = v + (c - 48) * m;
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
static long lint_mark(LintSt st, Yv *name, long bit) {
    long n = lint_num(name);
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
static long lint_note(LintSt st, Yv *name, Yv *kind, long line, long col,
                      int scal, int fresh) {
    Yv *d = lint_disp(name);
    if (!ys_eq_lit(d, "") && ys_byte_at(d, 0) != 95 &&
        ys_index_of(name, ys("$shadow")) < 0) {
        (void)ya_push(yr_get(st, "vars"),
                      yr(7, "name", d, "kind", kind, "num",
                         yv_long(lint_num(name)), "line", yv_long(line),
                         "col", yv_long(col), "scal", yv_bool(scal),
                         "fresh", yv_bool(fresh)));
    }
    return 0;
}

/* A statement list: a block's, a function body's, the unit's. Only the
 * last statement's value is used, and only when the list's is. The first
 * statement after one that always returns never runs (a def there still
 * does: defs hoist). */
static long lint_stmts(LintSt st, Yv *stmts, int used, int top) {
    long n = yv_len(stmts);
    int dead = 0;
    int told = 0;
    long i = 0;
    while (i < n) {
        Yv *s = ya_get(stmts, i);
        if (dead && !told && lint_code(s)) {
            (void)lint_warn_start(st, ys("unreachable code"), s);
            told = 1;
        }
        (void)lint_stmt(st, s, used && i == n - 1, top);
        if (!dead && lint_diverges(s)) {
            dead = 1;
        }
        i = i + 1;
    }
    return 0;
}

static long lint_warn_at(LintSt st, Yv *msg, Yv *node) {
    return lint_warn(st, msg, yv_l(yr_get(node, "line")),
                     yv_l(yr_get(node, "col")));
}

/* At the first token of `node`: an operator's node sits at the operator,
 * a call's at its `(`. */
static long lint_warn_start(LintSt st, Yv *msg, Yv *node) {
    Yv *k = yr_get(node, "k");
    if (ys_eq_lit(k, "call")) {
        return lint_warn_start(st, msg, yr_get(node, "callee"));
    } else if (ys_eq_lit(k, "bin")) {
        return lint_warn_start(st, msg, yr_get(node, "l"));
    } else if (ys_eq_lit(k, "index") || ys_eq_lit(k, "slice")) {
        return lint_warn_start(st, msg, yr_get(node, "arr"));
    } else if (ys_eq_lit(k, "dot")) {
        return lint_warn_start(st, msg, yr_get(node, "obj"));
    } else if (ys_eq_lit(k, "opassign") ||
               (ys_eq_lit(k, "incdec") && !yv_b(yr_get(node, "pre")))) {
        return lint_warn_start(st, msg, yr_get(node, "tgt"));
    } else {
        return lint_warn_at(st, msg, node);
    }
}

/* A top-level binding is a global: not checked for use. */
static long lint_stmt(LintSt st, Yv *s, int used, int top) {
    if (top && ys_eq_lit(yr_get(s, "k"), "decl")) {
        return lint_node(st, yr_get(s, "v"), 1);
    } else {
        return lint_node(st, s, used);
    }
}

/* Not the parser's trailing void, and not a def. */
static int lint_code(Yv *s) {
    Yv *k = yr_get(s, "k");
    if (ys_eq_lit(k, "void")) {
        return 0;
    } else if (ys_eq_lit(k, "decl")) {
        return !ys_eq_lit(yr_get(s, "kind"), "def");
    } else {
        return 1;
    }
}

/* Whether a statement always leaves the function: a `return`, a block
 * holding one, an `if` whose two arms both do. */
static int lint_diverges(Yv *s) {
    Yv *k = yr_get(s, "k");
    if (ys_eq_lit(k, "ret")) {
        return 1;
    } else if (ys_eq_lit(k, "block")) {
        return lint_any_diverges(yr_get(s, "stmts"));
    } else if (ys_eq_lit(k, "if")) {
        return yv_b(yr_get(s, "has_else")) &&
               lint_diverges(yr_get(s, "then")) &&
               lint_diverges(yr_get(s, "els"));
    } else {
        return 0;
    }
}

static int lint_any_diverges(Yv *stmts) {
    int found = 0;
    long i = 0;
    while (!found && i < yv_len(stmts)) {
        found = lint_diverges(ya_get(stmts, i));
        i = i + 1;
    }
    return found;
}

/* One node; `used`: its value is consumed. The kinds most nodes have
 * come first. */
static long lint_node(LintSt st, Yv *node, int used) {
    Yv *k = yr_get(node, "k");
    if (ys_eq_lit(k, "id")) {
        return lint_id(st, node, used);
    } else if (ys_eq_lit(k, "call")) {
        (void)lint_node(st, yr_get(node, "callee"), 1);
        return lint_list(st, yr_get(node, "args"));
    } else if (ys_eq_lit(k, "dot")) {
        return lint_node(st, yr_get(node, "obj"), 1);
    } else if (ys_eq_lit(k, "str") || ys_eq_lit(k, "num")) {
        return 0;
    } else if (ys_eq_lit(k, "bin")) {
        return lint_bin(st, node, used);
    } else if (ys_eq_lit(k, "decl")) {
        return lint_decl(st, node);
    } else if (ys_eq_lit(k, "block")) {
        return lint_stmts(st, yr_get(node, "stmts"), used, 0);
    } else if (ys_eq_lit(k, "if")) {
        return lint_if(st, node, used);
    } else if (ys_eq_lit(k, "assign")) {
        return lint_assign(st, node);
    } else if (ys_eq_lit(k, "index")) {
        return lint_two(st, yr_get(node, "arr"), yr_get(node, "idx"));
    } else if (ys_eq_lit(k, "rec")) {
        return lint_lit(st, node, ys("field"), ys("record"));
    } else if (ys_eq_lit(k, "array")) {
        return lint_list(st, yr_get(node, "elems"));
    } else if (ys_eq_lit(k, "ret") || ys_eq_lit(k, "un") ||
               ys_eq_lit(k, "addr") || ys_eq_lit(k, "deref") ||
               ys_eq_lit(k, "rectest") || ys_eq_lit(k, "narrow") ||
               ys_eq_lit(k, "matchend")) {
        return lint_one(st, node, used);
    } else if (ys_eq_lit(k, "opassign")) {
        return lint_opassign(st, node, used);
    } else if (ys_eq_lit(k, "while")) {
        (void)lint_node(st, yr_get(node, "cond"), 1);
        return lint_node(st, yr_get(node, "body"), 0);
    } else if (ys_eq_lit(k, "func")) {
        return lint_func(st, node);
    } else if (ys_eq_lit(k, "incdec")) {
        return lint_incdec(st, node, used);
    } else if (ys_eq_lit(k, "idxassign")) {
        (void)lint_two(st, yr_get(node, "arr"), yr_get(node, "idx"));
        return lint_node(st, yr_get(node, "v"), 1);
    } else if (ys_eq_lit(k, "dotassign")) {
        return lint_two(st, yr_get(node, "obj"), yr_get(node, "v"));
    } else if (ys_eq_lit(k, "slice")) {
        (void)lint_two(st, yr_get(node, "arr"), yr_get(node, "lo"));
        return lint_node(st, yr_get(node, "hi"), 1);
    } else if (ys_eq_lit(k, "for")) {
        return lint_for(st, node);
    } else if (ys_eq_lit(k, "foreach")) {
        (void)lint_node(st, yr_get(node, "iter"), 1);
        return lint_node(st, yr_get(node, "body"), 0);
    } else if (ys_eq_lit(k, "forrange")) {
        (void)lint_two(st, yr_get(node, "lo"), yr_get(node, "hi"));
        return lint_node(st, yr_get(node, "body"), 0);
    } else if (ys_eq_lit(k, "map")) {
        return lint_lit(st, node, ys("key"), ys("map"));
    } else if (ys_eq_lit(k, "arrrep")) {
        return lint_node(st, yr_get(node, "v"), 1);
    } else if (ys_eq_lit(k, "store")) {
        return lint_two(st, yr_get(node, "p"), yr_get(node, "v"));
    } else if (ys_eq_lit(k, "sliceassign")) {
        (void)lint_two(st, yr_get(node, "arr"), yr_get(node, "lo"));
        return lint_two(st, yr_get(node, "hi"), yr_get(node, "v"));
    } else {
        return 0;
    }
}

/* The kinds with one operand, `e`; a unary operator's dropped result is
 * a mistake. */
static long lint_one(LintSt st, Yv *node, int used) {
    if (ys_eq_lit(yr_get(node, "k"), "un")) {
        return lint_un(st, node, used);
    } else {
        return lint_node(st, yr_get(node, "e"), 1);
    }
}

static long lint_list(LintSt st, Yv *nodes) {
    long i = 0;
    while (i < yv_len(nodes)) {
        (void)lint_node(st, ya_get(nodes, i), 1);
        i = i + 1;
    }
    return 0;
}

static long lint_two(LintSt st, Yv *a, Yv *b) {
    (void)lint_node(st, a, 1);
    return lint_node(st, b, 1);
}

static long lint_id(LintSt st, Yv *node, int used) {
    Yv *name = yr_get(node, "v");
    (void)lint_mark(st, name, 1);
    Yv *d = lint_disp(name);
    if (!used && !ys_eq_lit(d, "") && !ys_eq_lit(d, "none")) {
        (void)lint_warn_at(
            st, lint_cat(3, ys("the value of '"), d, ys("' is not used")),
            node);
    }
    return 0;
}

static long lint_un(LintSt st, Yv *node, int used) {
    Yv *e = yr_get(node, "e");
    (void)lint_node(st, e, 1);
    if (!used && !ys_eq_lit(yr_get(e, "k"), "num")) {
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
static long lint_bin(LintSt st, Yv *node, int used) {
    Yv *op = yr_get(node, "op");
    Yv *l = yr_get(node, "l");
    Yv *r = yr_get(node, "r");
    if ((ys_eq_lit(op, "&&") || ys_eq_lit(op, "||")) && !used &&
        lint_effect(r)) {
        (void)lint_node(st, l, 1);
        return lint_node(st, r, 0);
    } else {
        (void)lint_two(st, l, r);
        if (!used) {
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
        return 0;
    }
}

/* The names are compared as strings: `==` on two unannotated values
 * compares their words. */
static int lint_same_id(Yv *l, Yv *r) {
    if (ys_eq_lit(yr_get(l, "k"), "id") && ys_eq_lit(yr_get(r, "k"), "id")) {
        Yv *lv = yr_get(l, "v");
        Yv *rv = yr_get(r, "v");
        return ys_eq(lv, rv);
    } else {
        return 0;
    }
}

/* Whether evaluating a node can do more than compute its value. */
static int lint_effect(Yv *node) {
    Yv *k = yr_get(node, "k");
    if (ys_eq_lit(k, "call") || ys_eq_lit(k, "assign") ||
        ys_eq_lit(k, "opassign") || ys_eq_lit(k, "incdec") ||
        ys_eq_lit(k, "idxassign") || ys_eq_lit(k, "dotassign") ||
        ys_eq_lit(k, "sliceassign") || ys_eq_lit(k, "store")) {
        return 1;
    } else if (ys_eq_lit(k, "block") || ys_eq_lit(k, "if") ||
               ys_eq_lit(k, "while") || ys_eq_lit(k, "for") ||
               ys_eq_lit(k, "foreach") || ys_eq_lit(k, "forrange") ||
               ys_eq_lit(k, "ret")) {
        return 1;
    } else if (ys_eq_lit(k, "bin")) {
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
    if (ys_eq_lit(yr_get(node, "k"), "num")) {
        return lint_zero_text(yr_get(node, "v"));
    } else {
        return 0;
    }
}

static int lint_zero_text(Yv *s) {
    Yv *p = ys_slice(s, 0, 2);
    Yv *digits = s;
    if (ys_eq_lit(p, "0x") || ys_eq_lit(p, "0X") || ys_eq_lit(p, "0b") ||
        ys_eq_lit(p, "0B")) {
        digits = ys_slice_from(s, 2);
    } else if (ys_index_of(s, ys(".")) >= 0 || ys_index_of(s, ys("e")) >= 0 ||
               ys_index_of(s, ys("E")) >= 0) {
        digits = ys("");
    }
    int ok = yv_len(digits) > 0;
    long i = 0;
    while (ok && i < yv_len(digits)) {
        long c = ys_byte_at(digits, i);
        ok = c == 48 || c == 95;
        i = i + 1;
    }
    return ok;
}

/* An `if` gives its arms' values only when it has both arms. */
static long lint_if(LintSt st, Yv *node, int used) {
    (void)lint_node(st, yr_get(node, "cond"), 1);
    int arms = used && yv_b(yr_get(node, "has_else"));
    (void)lint_node(st, yr_get(node, "then"), arms);
    return lint_node(st, yr_get(node, "els"), arms);
}

static long lint_for(LintSt st, Yv *node) {
    (void)lint_node(st, yr_get(node, "init"), 0);
    (void)lint_node(st, yr_get(node, "cond"), 1);
    (void)lint_node(st, yr_get(node, "step"), 0);
    return lint_node(st, yr_get(node, "body"), 0);
}

static long lint_func(LintSt st, Yv *node) {
    Yv *body = yr_get(node, "body");
    return lint_stmts(st, yr_get(body, "stmts"), 1, 0);
}

static long lint_decl(LintSt st, Yv *node) {
    Yv *v = yr_get(node, "v");
    long line = yv_l(yr_get(node, "line"));
    long col = yv_l(yr_get(node, "col"));
    if (ys_eq_lit(yr_get(node, "kind"), "def")) {
        (void)lint_note(st, yr_get(node, "name"), ys("def"), line, col, 0, 0);
    } else {
        (void)lint_note(st, yr_get(node, "name"), yr_get(node, "kind"), line,
                        col, lint_scal(yr_get(node, "typ"), v),
                        lint_fresh(v));
    }
    return lint_node(st, v, 1);
}

static int lint_scal(Yv *typ, Yv *v) {
    Yv *tk = yr_get(typ, "k");
    Yv *vk = yr_get(v, "k");
    if (ys_eq_lit(tk, "tlong") || ys_eq_lit(tk, "tfloat") ||
        ys_eq_lit(tk, "tbyte") || ys_eq_lit(tk, "tstr") ||
        ys_eq_lit(tk, "tbool")) {
        return 1;
    } else {
        return ys_eq_lit(vk, "num") || ys_eq_lit(vk, "str") ||
               ys_eq_lit(vk, "char") || ys_eq_lit(vk, "bool");
    }
}

static int lint_fresh(Yv *v) {
    Yv *vk = yr_get(v, "k");
    return ys_eq_lit(vk, "array") || ys_eq_lit(vk, "arrrep");
}

static long lint_assign(LintSt st, Yv *node) {
    Yv *name = yr_get(node, "name");
    Yv *v = yr_get(node, "v");
    (void)lint_mark(st, name, 2);
    (void)lint_node(st, v, 1);
    if (ys_eq_lit(yr_get(v, "k"), "id") && ys_eq(yr_get(v, "v"), name)) {
        (void)lint_warn_at(st,
                           lint_cat(3, ys("'"), lint_disp(name),
                                    ys("' is assigned to itself")),
                           node);
    }
    return 0;
}

static long lint_incdec(LintSt st, Yv *node, int used) {
    Yv *t = yr_get(node, "tgt");
    if (ys_eq_lit(yr_get(t, "k"), "id")) {
        (void)lint_mark(st, yr_get(t, "v"), 2);
        if (used) {
            (void)lint_mark(st, yr_get(t, "v"), 1);
        }
        return 0;
    } else {
        return lint_node(st, t, 1);
    }
}

static long lint_opassign(LintSt st, Yv *node, int used) {
    Yv *t = yr_get(node, "tgt");
    Yv *op = yr_get(node, "op");
    Yv *v = yr_get(node, "v");
    (void)lint_node(st, v, 1);
    if (ys_eq_lit(yr_get(t, "k"), "id")) {
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
    return 0;
}

/* A record or map literal giving a key twice keeps the last value; the
 * earlier one is computed for nothing. */
static long lint_lit(LintSt st, Yv *node, Yv *what, Yv *kind) {
    Yv *keys = yr_get(node, "keys");
    (void)lint_list(st, yr_get(node, "vals"));
    long i = 0;
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

static int lint_seen(Yv *keys, long i) {
    Yv *key = ya_get(keys, i);
    int found = 0;
    long j = 0;
    while (!found && j < i) {
        found = ys_eq(ya_get(keys, j), key);
        j = j + 1;
    }
    return found;
}

/* Every noted binding: read is fine; grown is fine unless the growth is
 * only its own (a number's, or a fresh array's never reassigned). */
static long lint_vars(LintSt st) {
    Yv *flags = yr_get(st, "flags");
    Yv *vars = yr_get(st, "vars");
    long i = 0;
    while (i < yv_len(vars)) {
        LintVar v = ya_get(vars, i);
        long num = yv_l(yr_get(v, "num"));
        long f = 0;
        if (num < yv_len(flags)) {
            f = yv_l(ya_get(flags, num));
        }
        Yv *word = lint_word(yr_get(v, "kind"));
        Yv *name = yr_get(v, "name");
        long line = yv_l(yr_get(v, "line"));
        long col = yv_l(yr_get(v, "col"));
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

static long lint_types(LintSt st, Yv *stmts) {
    Yv *roots = yav(0);
    Yv *atyps = yav(0);
    Yv *amemo = yav(0);
    Yv *abusy = yav(0);
    Yv *occs = yav(0);
    Yv *amods = yav(0);
    LintTy t = yr(10, "roots", roots, "atyps", atyps, "amods", amods,
                  "amap", lint_map_new(), "amemo", amemo, "abusy", abusy,
                  "occs", occs, "line", yv_long(0), "col", yv_long(0),
                  "mod", ys(""));
    (void)lint_tw_list(t, stmts);
    /* The aliases: a name declared again is the last declaration's. */
    Yv *rs = yr_get(t, "roots");
    long i = 0;
    while (i < yv_len(rs)) {
        LintRoot r = ya_get(rs, i);
        Yv *alias = yr_get(r, "alias");
        if (!ys_eq_lit(alias, "")) {
            if (lint_map_get(yr_get(t, "amap"), alias) >= 0) {
                (void)lint_warn(
                    st,
                    lint_cat(3, ys("type '"), alias,
                             ys("' is declared more than once; the last "
                                "declaration counts")),
                    yv_l(yr_get(r, "line")), yv_l(yr_get(r, "col")));
            }
            (void)lint_map_put(yr_get(t, "amap"), alias,
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
    long tdi = 0;
    i = 0;
    while (i < yv_len(rs)) {
        LintRoot r = ya_get(rs, i);
        (void)yr_set(t, "line", yv_long(yv_l(yr_get(r, "line"))));
        (void)yr_set(t, "col", yv_long(yv_l(yr_get(r, "col"))));
        (void)yr_set(t, "mod", yr_get(r, "mod"));
        long first = yv_len(yr_get(t, "occs"));
        (void)lint_tk(t, yr_get(r, "typ"), 1, -1);
        Yv *alias = yr_get(r, "alias");
        if (!ys_eq_lit(alias, "")) {
            if (yv_len(yr_get(t, "occs")) > first &&
                lint_cand(yr_get(r, "typ"))) {
                LintOcc o = ya_get(yr_get(t, "occs"), first);
                (void)yr_set(o, "decl", yv_bool(1));
                if (lint_map_get(yr_get(t, "amap"), alias) == tdi) {
                    (void)yr_set(o, "alias", alias);
                }
            }
            tdi = tdi + 1;
        }
        i = i + 1;
    }
    return lint_report(st, t);
}

static long lint_tw_list(LintTy t, Yv *nodes) {
    long i = 0;
    while (i < yv_len(nodes)) {
        (void)lint_tw(t, ya_get(nodes, i));
        i = i + 1;
    }
    return 0;
}

static long lint_tw(LintTy t, Yv *node) {
    Yv *k = yr_get(node, "k");
    if (ys_eq_lit(k, "id") || ys_eq_lit(k, "str") || ys_eq_lit(k, "num")) {
        return 0;
    } else if (ys_eq_lit(k, "call")) {
        (void)lint_tw(t, yr_get(node, "callee"));
        return lint_tw_list(t, yr_get(node, "args"));
    } else if (ys_eq_lit(k, "dot")) {
        return lint_tw(t, yr_get(node, "obj"));
    } else if (ys_eq_lit(k, "bin")) {
        (void)lint_tw(t, yr_get(node, "l"));
        return lint_tw(t, yr_get(node, "r"));
    } else if (ys_eq_lit(k, "decl")) {
        return lint_tw_decl(t, node);
    } else if (ys_eq_lit(k, "block")) {
        return lint_tw_list(t, yr_get(node, "stmts"));
    } else if (ys_eq_lit(k, "if")) {
        (void)lint_tw(t, yr_get(node, "cond"));
        (void)lint_tw(t, yr_get(node, "then"));
        return lint_tw(t, yr_get(node, "els"));
    } else if (ys_eq_lit(k, "assign") || ys_eq_lit(k, "arrrep")) {
        return lint_tw(t, yr_get(node, "v"));
    } else if (ys_eq_lit(k, "index")) {
        (void)lint_tw(t, yr_get(node, "arr"));
        return lint_tw(t, yr_get(node, "idx"));
    } else if (ys_eq_lit(k, "rec") || ys_eq_lit(k, "map")) {
        return lint_tw_list(t, yr_get(node, "vals"));
    } else if (ys_eq_lit(k, "array")) {
        return lint_tw_list(t, yr_get(node, "elems"));
    } else if (ys_eq_lit(k, "ret") || ys_eq_lit(k, "un") ||
               ys_eq_lit(k, "addr") || ys_eq_lit(k, "deref") ||
               ys_eq_lit(k, "rectest") || ys_eq_lit(k, "narrow") ||
               ys_eq_lit(k, "matchend")) {
        return lint_tw_one(t, node);
    } else if (ys_eq_lit(k, "func")) {
        return lint_tw_func(t, node);
    } else if (ys_eq_lit(k, "typedef")) {
        return lint_root(t, yr_get(node, "typ"), yv_l(yr_get(node, "line")),
                         yv_l(yr_get(node, "col")), yr_get(node, "name"));
    } else if (ys_eq_lit(k, "opassign")) {
        (void)lint_tw(t, yr_get(node, "tgt"));
        return lint_tw(t, yr_get(node, "v"));
    } else if (ys_eq_lit(k, "while")) {
        (void)lint_tw(t, yr_get(node, "cond"));
        return lint_tw(t, yr_get(node, "body"));
    } else if (ys_eq_lit(k, "incdec")) {
        return lint_tw(t, yr_get(node, "tgt"));
    } else if (ys_eq_lit(k, "idxassign")) {
        (void)lint_tw(t, yr_get(node, "arr"));
        (void)lint_tw(t, yr_get(node, "idx"));
        return lint_tw(t, yr_get(node, "v"));
    } else if (ys_eq_lit(k, "dotassign")) {
        (void)lint_tw(t, yr_get(node, "obj"));
        return lint_tw(t, yr_get(node, "v"));
    } else if (ys_eq_lit(k, "slice")) {
        (void)lint_tw(t, yr_get(node, "arr"));
        (void)lint_tw(t, yr_get(node, "lo"));
        return lint_tw(t, yr_get(node, "hi"));
    } else if (ys_eq_lit(k, "for")) {
        (void)lint_tw(t, yr_get(node, "init"));
        (void)lint_tw(t, yr_get(node, "cond"));
        (void)lint_tw(t, yr_get(node, "step"));
        return lint_tw(t, yr_get(node, "body"));
    } else if (ys_eq_lit(k, "foreach")) {
        (void)lint_tw(t, yr_get(node, "iter"));
        return lint_tw(t, yr_get(node, "body"));
    } else if (ys_eq_lit(k, "forrange")) {
        (void)lint_tw(t, yr_get(node, "lo"));
        (void)lint_tw(t, yr_get(node, "hi"));
        return lint_tw(t, yr_get(node, "body"));
    } else if (ys_eq_lit(k, "store")) {
        (void)lint_tw(t, yr_get(node, "p"));
        return lint_tw(t, yr_get(node, "v"));
    } else if (ys_eq_lit(k, "sliceassign")) {
        (void)lint_tw(t, yr_get(node, "arr"));
        (void)lint_tw(t, yr_get(node, "lo"));
        (void)lint_tw(t, yr_get(node, "hi"));
        return lint_tw(t, yr_get(node, "v"));
    } else {
        return 0;
    }
}

static long lint_tw_one(LintTy t, Yv *node) {
    return lint_tw(t, yr_get(node, "e"));
}

static long lint_tw_decl(LintTy t, Yv *node) {
    if (!ys_eq_lit(yr_get(node, "kind"), "def")) {
        (void)lint_root(t, yr_get(node, "typ"), yv_l(yr_get(node, "line")),
                        yv_l(yr_get(node, "col")), ys(""));
    }
    return lint_tw(t, yr_get(node, "v"));
}

static long lint_tw_func(LintTy t, Yv *node) {
    long line = yv_l(yr_get(node, "line"));
    long col = yv_l(yr_get(node, "col"));
    Yv *ps = yr_get(node, "ptypes");
    long i = 0;
    while (i < yv_len(ps)) {
        (void)lint_root(t, ya_get(ps, i), line, col, ys(""));
        i = i + 1;
    }
    (void)lint_root(t, yr_get(node, "ret"), line, col, ys(""));
    return lint_tw(t, yr_get(node, "body"));
}

static long lint_root(LintTy t, Yv *typ, long line, long col, Yv *alias) {
    if (!ys_eq_lit(yr_get(typ, "k"), "tnone")) {
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
static Yv *lint_mod_of(long ln) {
    if (lint_ofile != NULL && ln >= 1 && ln <= yv_len(lint_ofile)) {
        long f = yv_l(ya_get(lint_ofile, ln - 1));
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
    if (ys_eq_lit(k, "trec")) {
        Yv *fs = yr_get(ty, "fields");
        return yv_len(fs) >= 2;
    } else {
        return ys_eq_lit(k, "tunion");
    }
}

/* The key of `ty`; with `rec`, its occurrences are noted (`parent`: the
 * one it is in, or -1). */
static Yv *lint_tk(LintTy t, Yv *ty, int rec, long parent) {
    Yv *k = yr_get(ty, "k");
    if (ys_eq_lit(k, "tname")) {
        return lint_tk_name(t, yr_get(ty, "name"));
    } else if (ys_eq_lit(k, "tptr")) {
        return ys_cat(ys("*"), lint_tk(t, yr_get(ty, "to"), rec, parent));
    } else if (ys_eq_lit(k, "tarr")) {
        return lint_cat(3, ys("["), lint_tk(t, yr_get(ty, "of"), rec, parent),
                        ys("]"));
    } else if (ys_eq_lit(k, "tarrfix")) {
        return lint_cat(5, ys("["), lint_tk(t, yr_get(ty, "of"), rec, parent),
                        ys(";"), ys_tostring(yr_get(ty, "n")), ys("]"));
    } else if (ys_eq_lit(k, "topt")) {
        return ys_cat(lint_tk(t, yr_get(ty, "of"), rec, parent), ys("?"));
    } else if (ys_eq_lit(k, "tmap")) {
        Yv *kk = lint_tk(t, yr_get(ty, "key"), rec, parent);
        return lint_cat(5, ys("{"), kk, ys("=>"),
                        lint_tk(t, yr_get(ty, "of"), rec, parent), ys("}"));
    } else if (ys_eq_lit(k, "tfunc")) {
        Yv *ak = lint_tk_list(t, yr_get(ty, "args"), rec, parent);
        return lint_cat(4, ys("("), ak, ys(")->"),
                        lint_tk(t, yr_get(ty, "ret"), rec, parent));
    } else if (ys_eq_lit(k, "tparams")) {
        return lint_cat(3, ys("("),
                        lint_tk_list(t, yr_get(ty, "ts"), rec, parent),
                        ys(")"));
    } else if (ys_eq_lit(k, "trec")) {
        return lint_tk_rec(t, ty, rec, parent);
    } else if (ys_eq_lit(k, "tunion")) {
        return lint_tk_union(t, ty, rec, parent);
    } else {
        return k;
    }
}

static Yv *lint_tk_list(LintTy t, Yv *ts, int rec, long parent) {
    Yv *parts = yav(0);
    long i = 0;
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
    long ai = -1;
    Yv *tm = yr_get(t, "mod");
    if (!ys_eq_lit(tm, "") && ys_index_of(name, ys(".")) < 0) {
        ai = lint_map_get(yr_get(t, "amap"), ys_cat(ys_cat(tm, ys(".")), name));
    }
    if (ai < 0) {
        ai = lint_map_get(yr_get(t, "amap"), name);
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

static Yv *lint_tk_rec(LintTy t, Yv *ty, int rec, long parent) {
    Yv *fs = yr_get(ty, "fields");
    long me = parent;
    if (rec && lint_cand(ty)) {
        me = lint_occ(t, ty, parent);
    }
    Yv *parts = yav(0);
    long i = 0;
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
static Yv *lint_tk_union(LintTy t, Yv *ty, int rec, long parent) {
    long me = parent;
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

static long lint_tk_members(LintTy t, Yv *u, int rec, long me, Yv *parts) {
    Yv *ts = yr_get(u, "ts");
    long i = 0;
    while (i < yv_len(ts)) {
        Yv *m = ya_get(ts, i);
        long ai = lint_union_alias(t, m);
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
static long lint_union_alias(LintTy t, Yv *m) {
    if (ys_eq_lit(yr_get(m, "k"), "tname")) {
        long ai = lint_map_get(yr_get(t, "amap"), yr_get(m, "name"));
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
    return ys_eq_lit(yr_get(ty, "k"), "tunion");
}

static long lint_occ(LintTy t, Yv *ty, long parent) {
    (void)ya_push(yr_get(t, "occs"),
                  yr(8, "key", ys(""), "typ", ty, "line",
                     yv_long(yv_l(yr_get(t, "line"))), "col",
                     yv_long(yv_l(yr_get(t, "col"))), "parent",
                     yv_long(parent), "decl", yv_bool(0), "alias", ys(""),
                     "rep", yv_bool(0)));
    return yv_len(yr_get(t, "occs")) - 1;
}

static long lint_occ_key(LintTy t, long i, Yv *key) {
    LintOcc o = ya_get(yr_get(t, "occs"), i);
    (void)yr_set(o, "key", key);
    return 0;
}

static Yv *lint_sort_uniq(Yv *xs) {
    Yv *out = yav(0);
    long i = 0;
    while (i < yv_len(xs)) {
        Yv *x = ya_get(xs, i);
        long j = yv_len(out);
        out = ya_push(out, x);
        while (j > 0 && ys_cmp(x, ya_get(out, j - 1)) < 0) {
            ya_set(out, j, ya_get(out, j - 1));
            j = j - 1;
        }
        ya_set(out, j, x);
        i = i + 1;
    }
    Yv *res = yav(0);
    long k = 0;
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
static long lint_report(LintSt st, LintTy t) {
    Yv *occs = yr_get(t, "occs");
    LintMap ids = lint_map_new();
    Yv *counts = yav(0);
    Yv *alias_of = yav(0);
    Yv *told = yav(0);
    Yv *occ_id = yav(0);
    long q = 0;
    while (q < yv_len(occs)) {
        LintOcc o = ya_get(occs, q);
        long id = lint_map_get(ids, yr_get(o, "key"));
        if (id < 0) {
            id = yv_len(counts);
            (void)lint_map_put(ids, yr_get(o, "key"), id);
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
    long i = 0;
    while (i < yv_len(occs)) {
        LintOcc o = ya_get(occs, i);
        long id = yv_l(ya_get(occ_id, i));
        long parent = yv_l(yr_get(o, "parent"));
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
        long id = yv_l(ya_get(occ_id, i));
        long parent = yv_l(yr_get(o, "parent"));
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

static int lint_rep(Yv *occs, long i) {
    LintOcc o = ya_get(occs, i);
    return yv_b(yr_get(o, "rep"));
}

/* ── maps: str -> long, open addressing ──────────────────────────────── */

static LintMap lint_map_new(void) {
    return lint_map_alloc(64);
}

static LintMap lint_map_alloc(long cap) {
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

static long lint_hash(Yv *s) {
    long h = 0;
    long i = 0;
    long n = yv_len(s);
    while (i < n) {
        h = (h * 31 + ys_byte_at(s, i)) % 1000000007;
        i = i + 1;
    }
    return h;
}

/* The slot holding `key`, or the empty one it would go in ("" marks an
 * empty slot: no key is ""). */
static long lint_map_slot(LintMap m, Yv *key) {
    Yv *keys = yr_get(m, "keys");
    long cap = yv_len(keys);
    long i = lint_hash(key) % cap;
    int go = 1;
    while (go) {
        Yv *e = ya_get(keys, i);
        if (ys_eq_lit(e, "") || ys_eq(e, key)) {
            go = 0;
        } else {
            i = i + 1;
            if (i == cap) {
                i = 0;
            }
        }
    }
    return i;
}

static long lint_map_get(LintMap m, Yv *key) {
    long i = lint_map_slot(m, key);
    Yv *keys = yr_get(m, "keys");
    if (ys_eq_lit(ya_get(keys, i), "")) {
        return -1;
    } else {
        Yv *vals = yr_get(m, "vals");
        return yv_l(ya_get(vals, i));
    }
}

/* Set `key` to `v`; the table stays at most half full. */
static long lint_map_put(LintMap m, Yv *key, long v) {
    if (2 * (yv_l(yr_get(m, "n")) + 1) > yv_len(yr_get(m, "keys"))) {
        LintMap big = lint_map_alloc(2 * yv_len(yr_get(m, "keys")));
        Yv *oks = yr_get(m, "keys");
        Yv *ovs = yr_get(m, "vals");
        long j = 0;
        while (j < yv_len(oks)) {
            if (!ys_eq_lit(ya_get(oks, j), "")) {
                (void)lint_map_put(big, ya_get(oks, j),
                                   yv_l(ya_get(ovs, j)));
            }
            j = j + 1;
        }
        (void)yr_set(m, "keys", yr_get(big, "keys"));
        (void)yr_set(m, "vals", yr_get(big, "vals"));
    }
    long i = lint_map_slot(m, key);
    Yv *keys = yr_get(m, "keys");
    if (ys_eq_lit(ya_get(keys, i), "")) {
        ya_set(keys, i, key);
        (void)yr_set(m, "n", yv_long(yv_l(yr_get(m, "n")) + 1));
    }
    Yv *vals = yr_get(m, "vals");
    ya_set(vals, i, yv_long(v));
    return 0;
}

/* ── output ──────────────────────────────────────────────────────────── */

/* By position, then message; a warning made twice is given once. */
static Yv *lint_sorted(Yv *ws) {
    Yv *all = lint_msort(ws);
    Yv *out = yav(0);
    long i = 0;
    while (i < yv_len(all)) {
        Diag w = ya_get(all, i);
        long n = yv_len(out);
        if (n == 0 || lint_before(ya_get(out, n - 1), w)) {
            out = ya_push(out, w);
        }
        i = i + 1;
    }
    return out;
}

static Yv *lint_msort(Yv *ws) {
    long n = yv_len(ws);
    if (n < 2) {
        return ws;
    } else {
        Yv *a = lint_msort(ya_slice(ws, 0, n / 2));
        Yv *b = lint_msort(ya_slice(ws, n / 2, n));
        Yv *out = yav(0);
        long i = 0;
        long j = 0;
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
