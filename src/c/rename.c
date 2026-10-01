/* rename.c — static name resolution (uniquify) for the native pipeline.
 * 1:1 C twin of src/y/rename.y (see PORTING.md).
 *
 * rename_program(ast) -> ast' where every binding has a globally unique
 * name (`orig$N`; `$` is lexer-illegal, so generated names can never collide
 * with user code). After this pass there is no shadowing and no scopes for
 * later passes to resolve: types.y keeps one flat binding list, native.y one
 * flat env.
 *
 * Rules:
 * - let/const/def names, func params, foreach/forrange loop vars: bound.
 * - References (id, assign/store targets, call callees, addr/index roots):
 *   rewritten to the innermost binding; unbound names (intrinsics, `self`)
 *   are left alone (the checker reports truly-undefined ones).
 * - def names are pre-bound per block level (functions hoist, so mutual
 *   recursion and forward calls resolve); value bindings (let/const) do NOT
 *   hoist — use-before-def stays an error, like TDZ.
 * - Map keys, dot keys, strings: untouched (not variables).
 *
 * Type map (PORTING.md): str/records/arrays/holes -> Yv *, long -> long,
 * bool -> int. Records are insertion-ordered maps (yr), arrays are yav /
 * ya_get / ya_push / ya_set (reference semantics, as in Y).
 */

/* imported */ /* none: rename.y is self-contained — it calls only its own
 * defs and the string/array builtins (`+`, len, tostring, push ->
 * ys_cat/yv_len/ys_long/ya_push). */

#include "rename.h"

/* state = { scopes: [[{ orig: str, uniq: str }]], n: long,
 *           tys: [{ name, typ }], dfl: [{ name, vals }] } */
Yv *rn_fresh(Yv *st, Yv *orig) {
    Yv *u = ys_cat(ys_cat(orig, ys("$")), ys_long(yv_l(yr_get(st, "n"))));
    Yv *nst = yr(4, "scopes", yr_get(st, "scopes"), "n",
                 yv_long(yv_l(yr_get(st, "n")) + 1), "tys", yr_get(st, "tys"), "dfl", yr_get(st, "dfl"));
    return yr(2, "st", nst, "name", u);
}

Yv *rn_push(Yv *st) {
    Yv *scopes = ya_push(yr_get(st, "scopes"), yav(0));
    return yr(4, "scopes", scopes, "n", yr_get(st, "n"), "tys", yr_get(st, "tys"), "dfl", yr_get(st, "dfl"));
}

Yv *rn_pop(Yv *st) {
    Yv *scopes = yav(0);
    Yv *old = yr_get(st, "scopes");
    long i = 0;
    while (i < yv_len(old) - 1) {
        scopes = ya_push(scopes, ya_get(old, i));
        i = i + 1;
    }
    return yr(4, "scopes", scopes, "n", yr_get(st, "n"), "tys", yr_get(st, "tys"), "dfl", yr_get(st, "dfl"));
}

Yv *rn_define(Yv *st, Yv *orig, Yv *uniq) {
    Yv *scopes = yr_get(st, "scopes");
    Yv *top = ya_get(scopes, yv_len(scopes) - 1);
    top = ya_push(top, yr(2, "orig", orig, "uniq", uniq));
    ya_set(scopes, yv_len(scopes) - 1, top);
    return yr(4, "scopes", scopes, "n", yr_get(st, "n"), "tys", yr_get(st, "tys"), "dfl", yr_get(st, "dfl"));
}

Yv *rn_lookup(Yv *st, Yv *name) {
    /* Innermost scope first; within a frame, the NEWEST binding wins
     * (a later let shadows an earlier one). */
    Yv *all = yr_get(st, "scopes");
    long i = yv_len(all) - 1;
    Yv *found = ys("");
    while (i >= 0) {
        Yv *frame = ya_get(all, i);
        long j = yv_len(frame) - 1;
        while (j >= 0) {
            Yv *e = ya_get(frame, j);
            if (ys_eq(yr_get(e, "orig"), name)) {
                found = yr_get(e, "uniq");
                j = -1;
                i = -1;
                ;
            }
            j = j - 1;
            ;
        }
        i = i - 1;
        ;
    }
    return found;
}

/* Bind one name in the current scope, return {st, uniq}. */
Yv *rn_bind(Yv *st, Yv *orig) {
    Yv *r = rn_fresh(st, orig);
    st = rn_define(yr_get(r, "st"), orig, yr_get(r, "name"));
    return yr(2, "st", st, "uniq", yr_get(r, "name"));
}

Yv *rn_list(Yv *nodes, Yv *st) {
    Yv *out = yav(0);
    long i = 0;
    while (i < yv_len(nodes)) {
        Yv *r = rn_node(ya_get(nodes, i), st);
        st = yr_get(r, "st");
        out = ya_push(out, yr_get(r, "node"));
        i = i + 1;
    }
    return yr(2, "st", st, "nodes", out);
}

Yv *rn_id(Yv *st, Yv *name, long line, long col) {
    Yv *u = rn_lookup(st, name);
    if (ys_eq_lit(u, "")) {
        return yr(2, "st", st, "node",
                  yr(4, "k", ys("id"), "v", name, "line", yv_long(line), "col",
                     yv_long(col)));
    } else {
        return yr(2, "st", st, "node",
                  yr(4, "k", ys("id"), "v", u, "line", yv_long(line), "col",
                     yv_long(col)));
    }
}

/* Pre-bind all def names (named defs + let-bound anonymous defs) in a
 * statement list so mutual recursion resolves. */
Yv *rn_prepass(Yv *stmts, Yv *st) {
    /* NOTE: stmts elements are bare {k}-holes at the boundary (like res);
     * pass each element as a BARE value (rn_prepass_one takes unannotated
     * s) so field reads resolve via the tcompat law, not merged shapes. */
    long i = 0;
    while (i < yv_len(stmts)) {
        st = rn_prepass_one(ya_get(stmts, i), st);
        i = i + 1;
        ;
    }
    return st;
}

Yv *rn_prepass_one(Yv *s, Yv *st) {
    if (ys_eq_lit(yr_get(s, "k"), "decl")) {
        return rn_prepass_decl(s, st);
    } else if (ys_eq_lit(yr_get(s, "k"), "typedef")) {
        /* aliases hoist like defs: every annotation in the block sees them */
        ya_push(yr_get(st, "tys"), yr(2, "name", yr_get(s, "name"), "typ", yr_get(s, "typ")));
        return st;
    } else {
        return st;
    }
}

Yv *rn_prepass_decl(Yv *s, Yv *st) {
    /* decl shapes only (named def vs let-bound func): one `s.v.k` read in
     * this body (see parse_type_arrow note — two reads in one body merge). */
    if (ys_eq_lit(yr_get(s, "kind"), "def")) {
        Yv *r = rn_bind(st, yr_get(s, "name"));
        return rn_note_defaults(yr_get(r, "st"), yr_get(r, "uniq"), yr_get(s, "v"));
    } else if (ys_eq_lit(yr_get(yr_get(s, "v"), "k"), "func")) {
        Yv *r = rn_bind(st, yr_get(s, "name"));
        return rn_note_defaults(yr_get(r, "st"), yr_get(r, "uniq"), yr_get(s, "v"));
    } else {
        return st;
    }
}

/* Remember a def's default parameter values under its unique name, so a
 * direct call that leaves trailing arguments out gets them filled in. */
Yv *rn_note_defaults(Yv *st, Yv *uniq, Yv *func) {
    Yv *dv = yr_get(func, "defs");
    long i = 0;
    int any = 0;
    while (i < yv_len(dv)) {
        if (!ys_eq_lit(yr_get(ya_get(dv, i), "k"), "void")) {
            any = 1;
        }
        i = i + 1;
    }
    if (any) {
        ya_push(yr_get(st, "dfl"), yr(2, "name", uniq, "vals", dv));
    }
    return st;
}

/* The defaults of the def a call names ([] for anything else). */
Yv *rn_find_defaults(Yv *st, Yv *name) {
    Yv *out = yav(0);
    Yv *ds = yr_get(st, "dfl");
    long i = 0;
    while (i < yv_len(ds)) {
        Yv *d = ya_get(ds, i);
        if (ys_eq(yr_get(d, "name"), name)) {
            out = yr_get(d, "vals");
        }
        i = i + 1;
    }
    return out;
}

/* args + the defaults of the missing trailing parameters -- only when
 * every one of them has a default. An optional parameter (`b?: T`, its
 * default marked `optarg`) gets some(arg) when the call passes it, none when not. */
Yv *rn_fill_defaults(Yv *vals, Yv *args, long line, long col) {
    long n = yv_len(args);
    if (yv_len(vals) == 0) {
        return args;
    } else {
        int ok = 1;
        long i = n;
        while (i < yv_len(vals)) {
            if (ys_eq_lit(yr_get(ya_get(vals, i), "k"), "void")) {
                ok = 0;
            }
            i = i + 1;
        }
        Yv *out = yav(0);
        long j = 0;
        while (j < n) {
            if (j < yv_len(vals) && rn_is_optarg(ya_get(vals, j))) {
                Yv *one = yav(0);
                one = ya_push(one, ya_get(args, j));
                out = ya_push(
                    out,
                    yr(5, "k", ys("call"), "callee",
                       yr(4, "k", ys("id"), "v", ys("some"), "line",
                          yv_long(line), "col", yv_long(col)),
                       "args", one, "line", yv_long(line), "col",
                       yv_long(col)));
            } else {
                out = ya_push(out, ya_get(args, j));
            }
            j = j + 1;
        }
        if (ok) {
            while (j < yv_len(vals)) {
                if (rn_is_optarg(ya_get(vals, j))) {
                    out = ya_push(
                        out, yr(4, "k", ys("id"), "v", ys("none"), "line",
                                yv_long(line), "col", yv_long(col)));
                } else {
                    out = ya_push(out, ya_get(vals, j));
                }
                j = j + 1;
            }
        }
        return out;
    }
}

int rn_is_optarg(Yv *d) {
    return ys_eq_lit(yr_get(d, "k"), "optarg");
}

/* ── type aliases ─────────────────────────────────────────────────────────
 * `type A = T` makes the name A stand for T in every annotation (and match
 * pattern) seen AFTER it; resolution rewrites the type nodes, so the checker
 * and emitter never see an alias. A union's members are flattened (an alias
 * of a union inside a union adds its members). NOTE: `tys` is never popped,
 * so an alias declared inside a block stays visible for the rest of the
 * traversal, siblings included — the alias table is not scoped like names. */

Yv *rn_type(Yv *st, Yv *t) {
    if (yv_len(yr_get(st, "tys")) == 0) {
        return t;
    } else {
        return rn_type_go(st, t, 0);
    }
}

Yv *rn_types(Yv *st, Yv *ts) {
    if (yv_len(yr_get(st, "tys")) == 0) {
        return ts;
    } else {
        Yv *out = yav(0);
        long i = 0;
        while (i < yv_len(ts)) {
            out = ya_push(out, rn_type(st, ya_get(ts, i)));
            i = i + 1;
        }
        return out;
    }
}

Yv *rn_type_go(Yv *st, Yv *t, long depth) {
    Yv *k = yr_get(t, "k");
    if (ys_eq_lit(k, "tname")) {
        return rn_type_name(st, yr_get(t, "name"), t, depth);
    } else if (ys_eq_lit(k, "tptr")) {
        return yr(2, "k", ys("tptr"), "to", rn_type_go(st, yr_get(t, "to"), depth));
    } else if (ys_eq_lit(k, "tarr")) {
        return yr(2, "k", ys("tarr"), "of", rn_type_go(st, yr_get(t, "of"), depth));
    } else if (ys_eq_lit(k, "tarrfix")) {
        return yr(3, "k", ys("tarrfix"), "of", rn_type_go(st, yr_get(t, "of"), depth), "n", yr_get(t, "n"));
    } else if (ys_eq_lit(k, "topt")) {
        return yr(2, "k", ys("topt"), "of", rn_type_go(st, yr_get(t, "of"), depth));
    } else if (ys_eq_lit(k, "tmap")) {
        return yr(3, "k", ys("tmap"), "key", rn_type_go(st, yr_get(t, "key"), depth), "of", rn_type_go(st, yr_get(t, "of"), depth));
    } else if (ys_eq_lit(k, "trec")) {
        return yr(2, "k", ys("trec"), "fields", rn_type_fields(st, yr_get(t, "fields"), depth));
    } else if (ys_eq_lit(k, "tfunc")) {
        return yr(3, "k", ys("tfunc"), "args", rn_type_list(st, yr_get(t, "args"), depth), "ret", rn_type_go(st, yr_get(t, "ret"), depth));
    } else if (ys_eq_lit(k, "tparams")) {
        return yr(2, "k", ys("tparams"), "ts", rn_type_list(st, yr_get(t, "ts"), depth));
    } else if (ys_eq_lit(k, "tunion")) {
        return yr(2, "k", ys("tunion"), "ts", rn_union_flat(rn_type_list(st, yr_get(t, "ts"), depth)));
    } else {
        return t;
    }
}

Yv *rn_type_name(Yv *st, Yv *name, Yv *t, long depth) {
    Yv *tys = yr_get(st, "tys");
    long i = yv_len(tys) - 1;
    long found = -1;
    while (i >= 0) {
        if (ys_eq(yr_get(ya_get(tys, i), "name"), name)) {
            found = i;
            i = -1;
        }
        i = i - 1;
    }
    /* (depth bounds a cyclic alias: `type L = {next: L?}` stops growing at
       depth 32 and leaves the innermost name a tname, which tcompat unifies
       with anything — so the alias resolves, it just does not recurse.) */
    if (found < 0 || depth > 32) {
        return t;
    } else {
        return rn_type_go(st, yr_get(ya_get(tys, found), "typ"), depth + 1);
    }
}

Yv *rn_type_list(Yv *st, Yv *ts, long depth) {
    Yv *out = yav(0);
    long i = 0;
    while (i < yv_len(ts)) {
        out = ya_push(out, rn_type_go(st, ya_get(ts, i), depth));
        i = i + 1;
    }
    return out;
}

Yv *rn_type_fields(Yv *st, Yv *fs, long depth) {
    Yv *out = yav(0);
    long i = 0;
    while (i < yv_len(fs)) {
        Yv *f = ya_get(fs, i);
        out = ya_push(out, yr(2, "name", yr_get(f, "name"), "typ", rn_type_go(st, yr_get(f, "typ"), depth)));
        i = i + 1;
    }
    return out;
}

Yv *rn_union_flat(Yv *ts) {
    Yv *out = yav(0);
    long i = 0;
    while (i < yv_len(ts)) {
        Yv *t = ya_get(ts, i);
        if (ys_eq_lit(yr_get(t, "k"), "tunion")) {
            Yv *inner = yr_get(t, "ts");
            /* Y: `out += inner` — one push per element (see rn_fill_defaults). */
            for (long j = 0; j < yv_len(inner); j++) out = ya_push(out, ya_get(inner, j));
        } else {
            out = ya_push(out, t);
        }
        i = i + 1;
    }
    return out;
}

Yv *rn_typedef_err(Yv *s, Yv *st) {
    Yv *un = rn_unknown_type(st, yr_get(s, "typ"));
    if (ys_eq_lit(un, "")) {
        return yr(1, "k", ys("void"));
    } else {
        return rn_unknown_err(un, yv_l(yr_get(s, "line")),
                              yv_l(yr_get(s, "col")));
    }
}

Yv *rn_unknown_err(Yv *name, long line, long col) {
    Yv *msg = ys_cat(ys_cat(ys("unknown type '"), name), ys("'"));
    return yr(4, "k", ys("err"), "msg", msg, "line", yv_long(line),
              "col", yv_long(col));
}

Yv *rn_unknown_type(Yv *st, Yv *t) {
    Yv *k = yr_get(t, "k");
    if (ys_eq_lit(k, "tname")) {
        return rn_alias_known(yr_get(st, "tys"), yr_get(t, "name"));
    } else if (ys_eq_lit(k, "tptr")) {
        return rn_unknown_type(st, yr_get(t, "to"));
    } else if (ys_eq_lit(k, "tarr")) {
        return rn_unknown_type(st, yr_get(t, "of"));
    } else if (ys_eq_lit(k, "tarrfix")) {
        return rn_unknown_type(st, yr_get(t, "of"));
    } else if (ys_eq_lit(k, "topt")) {
        return rn_unknown_type(st, yr_get(t, "of"));
    } else if (ys_eq_lit(k, "tmap")) {
        Yv *first = rn_unknown_type(st, yr_get(t, "key"));
        return rn_unknown_then(first, st, yr_get(t, "of"));
    } else if (ys_eq_lit(k, "trec")) {
        return rn_unknown_fields(st, yr_get(t, "fields"));
    } else if (ys_eq_lit(k, "tfunc")) {
        Yv *first = rn_unknown_list(st, yr_get(t, "args"));
        return rn_unknown_then(first, st, yr_get(t, "ret"));
    } else if (ys_eq_lit(k, "tparams")) {
        return rn_unknown_list(st, yr_get(t, "ts"));
    } else if (ys_eq_lit(k, "tunion")) {
        return rn_unknown_list(st, yr_get(t, "ts"));
    } else {
        return ys("");
    }
}

Yv *rn_alias_known(Yv *tys, Yv *name) {
    int found = 0;
    long i = 0;
    while (i < yv_len(tys)) {
        Yv *e = ya_get(tys, i);
        if (ys_eq(yr_get(e, "name"), name)) {
            found = 1;
            ;
        } else {
            ;
        }
        i = i + 1;
    }
    if (found) {
        return ys("");
    } else {
        return name;
    }
}

Yv *rn_unknown_then(Yv *first, Yv *st, Yv *t) {
    if (!ys_eq_lit(first, "")) {
        return first;
    } else {
        return rn_unknown_type(st, t);
    }
}

Yv *rn_unknown_list(Yv *st, Yv *ts) {
    Yv *out = ys("");
    long i = 0;
    while (i < yv_len(ts)) {
        if (ys_eq_lit(out, "")) {
            out = rn_unknown_type(st, ya_get(ts, i));
            ;
        } else {
            ;
        }
        i = i + 1;
    }
    return out;
}

Yv *rn_unknown_fields(Yv *st, Yv *fs) {
    Yv *out = ys("");
    long i = 0;
    while (i < yv_len(fs)) {
        Yv *f = ya_get(fs, i);
        if (ys_eq_lit(out, "")) {
            out = rn_unknown_type(st, yr_get(f, "typ"));
            ;
        } else {
            ;
        }
        i = i + 1;
    }
    return out;
}

Yv *rn_drop_typedefs(Yv *stmts, Yv *st) {
    Yv *out = yav(0);
    long i = 0;
    while (i < yv_len(stmts)) {
        Yv *s = ya_get(stmts, i);
        if (ys_eq_lit(yr_get(s, "k"), "typedef")) {
            Yv *te = rn_typedef_err(s, st);
            if (ys_eq_lit(yr_get(te, "k"), "err")) {
                out = ya_push(out, te);
                ;
            } else {
                ;
            }
            ;
        } else {
            out = ya_push(out, s);
        }
        i = i + 1;
    }
    return out;
}

/* Redefinition shadows: `def f ... def f ...` keeps the LAST definition, and
 * every reference (before or after, since defs hoist) binds to it. rename.y
 * resolves def names through the prepass binding, so two same-named defs would
 * otherwise collapse onto one unique name; give the earlier ones a dead name
 * instead. They are still checked and emitted — only unreachable. */
Yv *rn_shadow_dups(Yv *stmts) {
    Yv *out = yav(0);
    long i = 0;
    while (i < yv_len(stmts)) {
        out = ya_push(out, rn_shadow_one(ya_get(stmts, i), stmts, i));
        i = i + 1;
        ;
    }
    return out;
}

Yv *rn_shadow_one(Yv *s, Yv *stmts, long i) {
    if (ys_eq_lit(yr_get(s, "k"), "decl")) {
        return rn_shadow_decl(s, stmts, i);
    } else {
        return s;
    }
}

Yv *rn_shadow_decl(Yv *s, Yv *stmts, long i) {
    /* NOTE: one `s.v.k` read per body (see rn_prepass_decl note). */
    if (ys_eq_lit(yr_get(s, "kind"), "def")) {
        return rn_shadow_go(s, stmts, i);
    } else if (ys_eq_lit(yr_get(yr_get(s, "v"), "k"), "func")) {
        return rn_shadow_go(s, stmts, i);
    } else {
        return s;
    }
}

Yv *rn_shadow_go(Yv *s, Yv *stmts, long i) {
    if (rn_redefined_later(stmts, i, yr_get(s, "name"))) {
        return rn_rebuild_decl(
            s, ys_cat(ys_cat(yr_get(s, "name"), ys("$shadow")), ys_long(i)));
    } else {
        return s;
    }
}

int rn_redefined_later(Yv *stmts, long i, Yv *name) {
    long j = i + 1;
    int found = 0;
    while (j < yv_len(stmts)) {
        if (ys_eq(rn_decl_name(ya_get(stmts, j)), name)) {
            found = 1;
            ;
        } else {
            ;
        }
        j = j + 1;
        ;
    }
    return found;
}

/* The name a statement binds as a hoisted def, or "" when it binds none. */
Yv *rn_decl_name(Yv *s) {
    if (ys_eq_lit(yr_get(s, "k"), "decl")) {
        return rn_decl_name_go(s);
    } else {
        return ys("");
    }
}

Yv *rn_decl_name_go(Yv *s) {
    /* NOTE: one `s.v.k` read per body (see rn_prepass_decl note). */
    if (ys_eq_lit(yr_get(s, "kind"), "def")) {
        return yr_get(s, "name");
    } else if (ys_eq_lit(yr_get(yr_get(s, "v"), "k"), "func")) {
        return yr_get(s, "name");
    } else {
        return ys("");
    }
}

Yv *rn_rebuild_decl(Yv *s, Yv *newname) {
    /* NOTE: one literal per arm would merge two key sets through the same
     * `if` (see parse_type_arrow note) — dispatch to single-call arms so
     * each shape unifies against the {k}-hole return type instead. */
    if (ys_eq_lit(yr_get(s, "kind"), "def")) {
        return rn_rebuild_def(s, newname);
    } else {
        return rn_rebuild_let(s, newname);
    }
}

Yv *rn_rebuild_def(Yv *s, Yv *newname) {
    return yr(6, "k", ys("decl"), "kind", ys("def"), "name", newname, "v",
              yr_get(s, "v"), "line", yr_get(s, "line"), "col",
              yr_get(s, "col"));
}

Yv *rn_rebuild_let(Yv *s, Yv *newname) {
    return yr(7, "k", ys("decl"), "kind", yr_get(s, "kind"), "name", newname,
              "typ", yr_get(s, "typ"), "v", yr_get(s, "v"), "line",
              yr_get(s, "line"), "col", yr_get(s, "col"));
}

Yv *rn_block(Yv *stmts, Yv *st) {
    stmts = rn_shadow_dups(stmts);
    st = rn_push(st);
    st = rn_prepass(stmts, st);
    Yv *r = rn_list(rn_drop_typedefs(stmts, st), st);
    st = rn_pop(yr_get(r, "st"));
    return yr(2, "st", st, "stmts", yr_get(r, "nodes"));
}

Yv *rn_node(Yv *node, Yv *st) {
    /* NOTE: dispatch WITHOUT a shared-shape if-chain (see parser.y
     * parse_type_arrow note): a long arm chain on one name merges every
     * arm's node shape through the flow-insensitive env (each arm's return
     * type must teq ALL others). Each arm here is a SINGLE callee call (or
     * leaf literal) with the uniform return type R, so arms always agree.
     * Leaf shapes (num/str/bool/void) return the node untouched. */
    Yv *k = yr_get(node, "k");
    if (ys_eq_lit(k, "num")) {
        return yr(2, "st", st, "node", node);
    } else if (ys_eq_lit(k, "str")) {
        return yr(2, "st", st, "node", node);
    } else if (ys_eq_lit(k, "bstr")) {
        return yr(2, "st", st, "node", node);
    } else if (ys_eq_lit(k, "bool")) {
        return yr(2, "st", st, "node", node);
    } else if (ys_eq_lit(k, "void")) {
        return yr(2, "st", st, "node", node);
    } else if (ys_eq_lit(k, "id")) {
        return rn_id(st, yr_get(node, "v"), yv_l(yr_get(node, "line")),
                     yv_l(yr_get(node, "col")));
    } else if (ys_eq_lit(k, "un")) {
        return rn_un(node, st);
    } else if (ys_eq_lit(k, "addr")) {
        return rn_addrderef(node, st);
    } else if (ys_eq_lit(k, "deref")) {
        return rn_addrderef(node, st);
    } else if (ys_eq_lit(k, "bin")) {
        return rn_bin(node, st);
    } else if (ys_eq_lit(k, "call")) {
        return rn_call(node, st);
    } else if (ys_eq_lit(k, "if")) {
        return rn_if(node, st);
    } else if (ys_eq_lit(k, "while")) {
        return rn_while(node, st);
    } else if (ys_eq_lit(k, "block")) {
        return rn_blocknode(node, st);
    } else if (ys_eq_lit(k, "decl")) {
        return rn_decl(node, st);
    } else if (ys_eq_lit(k, "func")) {
        return rn_func(node, st);
    } else if (ys_eq_lit(k, "assign")) {
        return rn_assign(node, st);
    } else if (ys_eq_lit(k, "incdec")) {
        return rn_incdec(node, st);
    } else if (ys_eq_lit(k, "opassign")) {
        return rn_opassign(node, st);
    } else if (ys_eq_lit(k, "store")) {
        return rn_store(node, st);
    } else if (ys_eq_lit(k, "ret")) {
        return rn_ret(node, st);
    } else if (ys_eq_lit(k, "array")) {
        return rn_array(node, st);
    } else if (ys_eq_lit(k, "arrrep")) {
        return rn_arrrep(node, st);
    } else if (ys_eq_lit(k, "rec")) {
        return rn_reclit(node, st);
    } else if (ys_eq_lit(k, "map")) {
        return rn_maplit(node, st);
    } else if (ys_eq_lit(k, "index")) {
        return rn_index(node, st);
    } else if (ys_eq_lit(k, "slice")) {
        return rn_slice(node, st);
    } else if (ys_eq_lit(k, "dot")) {
        return rn_dot(node, st);
    } else if (ys_eq_lit(k, "idxassign")) {
        return rn_idxassign(node, st);
    } else if (ys_eq_lit(k, "dotassign")) {
        return rn_dotassign(node, st);
    } else if (ys_eq_lit(k, "foreach")) {
        return rn_foreach(node, st);
    } else if (ys_eq_lit(k, "forrange")) {
        return rn_forrange(node, st);
    } else if (ys_eq_lit(k, "for")) {
        return rn_for(node, st);
    } else if (ys_eq_lit(k, "sliceassign")) {
        return rn_sliceassign(node, st);
    } else if (ys_eq_lit(k, "rectest")) {
        return rn_typed_e(node, st);
    } else if (ys_eq_lit(k, "narrow")) {
        return rn_typed_e(node, st);
    } else if (ys_eq_lit(k, "matchend")) {
        return rn_matchend(node, st);
    } else {
        return yr(2, "st", st, "node", node);
    }
}

/* rectest / narrow: an operand plus the (alias-resolved) type it tests. */
Yv *rn_typed_e(Yv *node, Yv *st) {
    Yv *e = rn_node(yr_get(node, "e"), st);
    Yv *est = yr_get(e, "st");
    Yv *un = rn_unknown_type(est, yr_get(node, "typ"));
    if (ys_eq_lit(un, "")) {
        return yr(2, "st", est, "node",
                  yr(5, "k", yr_get(node, "k"), "e", yr_get(e, "node"),
                     "typ", rn_type(est, yr_get(node, "typ")), "line",
                     yr_get(node, "line"), "col", yr_get(node, "col")));
    } else {
        return yr(2, "st", est, "node",
                  rn_unknown_err(un, yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col"))));
    }
}

Yv *rn_matchend(Yv *node, Yv *st) {
    Yv *e = rn_node(yr_get(node, "e"), st);
    return yr(2, "st", yr_get(e, "st"), "node",
              yr(6, "k", ys("matchend"), "e", yr_get(e, "node"), "cover",
                 rn_types(yr_get(e, "st"), yr_get(node, "cover")), "vals",
                 yr_get(node, "vals"), "line", yr_get(node, "line"), "col",
                 yr_get(node, "col")));
}

Yv *rn_sliceassign(Yv *node, Yv *st) {
    Yv *a = rn_node(yr_get(node, "arr"), st);
    Yv *l = rn_node(yr_get(node, "lo"), yr_get(a, "st"));
    Yv *h = rn_node(yr_get(node, "hi"), yr_get(l, "st"));
    Yv *v = rn_node(yr_get(node, "v"), yr_get(h, "st"));
    return yr(2, "st", yr_get(v, "st"), "node",
              yr(7, "k", ys("sliceassign"), "arr", yr_get(a, "node"), "lo",
                 yr_get(l, "node"), "hi", yr_get(h, "node"), "v",
                 yr_get(v, "node"), "line", yr_get(node, "line"), "col",
                 yr_get(node, "col")));
}

/* One def per AST shape (see rn_node note). Each takes the bare node hole
 * (param name `node` is exempt from annotation, like parser.y res) plus the
 * annotated scope state, and returns the uniform R. Field reads off the
 * bare hole unify quietly via the tcompat law (tnone); each body reads
 * ONLY its own shape's fields. */
Yv *rn_un(Yv *node, Yv *st) {
    Yv *r = rn_node(yr_get(node, "e"), st);
    return yr(2, "st", yr_get(r, "st"), "node",
              yr(5, "k", ys("un"), "op", yr_get(node, "op"), "e",
                 yr_get(r, "node"), "line", yr_get(node, "line"), "col",
                 yr_get(node, "col")));
}

Yv *rn_addrderef(Yv *node, Yv *st) {
    Yv *k = yr_get(node, "k");
    Yv *r = rn_node(yr_get(node, "e"), st);
    return yr(2, "st", yr_get(r, "st"), "node",
              yr(4, "k", k, "e", yr_get(r, "node"), "line",
                 yr_get(node, "line"), "col", yr_get(node, "col")));
}

Yv *rn_bin(Yv *node, Yv *st) {
    Yv *l = rn_node(yr_get(node, "l"), st);
    Yv *r = rn_node(yr_get(node, "r"), yr_get(l, "st"));
    return yr(2, "st", yr_get(r, "st"), "node",
              yr(6, "k", ys("bin"), "op", yr_get(node, "op"), "l",
                 yr_get(l, "node"), "r", yr_get(r, "node"), "line",
                 yr_get(node, "line"), "col", yr_get(node, "col")));
}

Yv *rn_call(Yv *node, Yv *st) {
    Yv *c = rn_node(yr_get(node, "callee"), st);
    Yv *a = rn_list(yr_get(node, "args"), yr_get(c, "st"));
    Yv *cn = yr_get(c, "node");
    Yv *args = yr_get(a, "nodes");
    if (ys_eq_lit(yr_get(cn, "k"), "id")) {
        args = rn_fill_defaults(rn_find_defaults(yr_get(a, "st"), yr_get(cn, "v")),
                                args, yv_l(yr_get(node, "line")),
                                yv_l(yr_get(node, "col")));
    }
    return yr(2, "st", yr_get(a, "st"), "node",
              yr(5, "k", ys("call"), "callee", cn, "args",
                 args, "line", yr_get(node, "line"), "col",
                 yr_get(node, "col")));
}

Yv *rn_if(Yv *node, Yv *st) {
    Yv *c = rn_node(yr_get(node, "cond"), st);
    return rn_if_then(node, yr_get(c, "node"), yr_get(c, "st"));
}

Yv *rn_if_then(Yv *node, Yv *cond, Yv *st) {
    Yv *tb = rn_block(yr_get(yr_get(node, "then"), "stmts"), st);
    return rn_if_finish(node, cond, yr_get(tb, "stmts"), yr_get(tb, "st"));
}

Yv *rn_if_finish(Yv *node, Yv *cond, Yv *tstmts, Yv *st) {
    /* NOTE: both arms build the SAME key set (cond/then/els/has_else);
     * els differs (renamed vs passthrough) but both unify — teq holds. */
    if (yv_b(yr_get(node, "has_else"))) {
        Yv *e = rn_node(yr_get(node, "els"), st);
        return yr(
            2, "st", yr_get(e, "st"), "node",
            yr(7, "k", ys("if"), "cond", cond, "then",
               yr(4, "k", ys("block"), "stmts", tstmts, "line",
                  yr_get(yr_get(node, "then"), "line"), "col",
                  yr_get(yr_get(node, "then"), "col")),
               "els", yr_get(e, "node"), "has_else", yv_bool(1), "line",
               yr_get(node, "line"), "col", yr_get(node, "col")));
    } else {
        return yr(
            2, "st", st, "node",
            yr(7, "k", ys("if"), "cond", cond, "then",
               yr(4, "k", ys("block"), "stmts", tstmts, "line",
                  yr_get(yr_get(node, "then"), "line"), "col",
                  yr_get(yr_get(node, "then"), "col")),
               "els", yr_get(node, "els"), "has_else", yv_bool(0), "line",
               yr_get(node, "line"), "col", yr_get(node, "col")));
    }
}

Yv *rn_while(Yv *node, Yv *st) {
    Yv *c = rn_node(yr_get(node, "cond"), st);
    return rn_while_body(node, yr_get(c, "node"), yr_get(c, "st"));
}

Yv *rn_while_body(Yv *node, Yv *cond, Yv *st) {
    Yv *b = rn_block(yr_get(yr_get(node, "body"), "stmts"), st);
    return yr(2, "st", yr_get(b, "st"), "node",
              yr(5, "k", ys("while"), "cond", cond, "body",
                 yr(4, "k", ys("block"), "stmts", yr_get(b, "stmts"), "line",
                    yr_get(yr_get(node, "body"), "line"), "col",
                    yr_get(yr_get(node, "body"), "col")),
                 "line", yr_get(node, "line"), "col", yr_get(node, "col")));
}

Yv *rn_blocknode(Yv *node, Yv *st) {
    Yv *b = rn_block(yr_get(node, "stmts"), st);
    return yr(2, "st", yr_get(b, "st"), "node",
              yr(4, "k", ys("block"), "stmts", yr_get(b, "stmts"), "line",
                 yr_get(node, "line"), "col", yr_get(node, "col")));
}

Yv *rn_assign(Yv *node, Yv *st) {
    Yv *r = rn_node(yr_get(node, "v"), st);
    return rn_assign_lookup(node, yr_get(r, "node"), yr_get(r, "st"));
}

Yv *rn_assign_lookup(Yv *node, Yv *v, Yv *st) {
    Yv *u = rn_lookup(st, yr_get(node, "name"));
    return rn_assign_finish(node, v, u, st);
}

Yv *rn_assign_finish(Yv *node, Yv *v, Yv *u, Yv *st) {
    /* NOTE: both arms share the key set; name differs (passthrough vs
     * renamed) but str vs hole unifies — teq holds. */
    if (ys_eq_lit(u, "")) {
        return yr(2, "st", st, "node",
                  yr(5, "k", ys("assign"), "name", yr_get(node, "name"), "v",
                     v, "line", yr_get(node, "line"), "col",
                     yr_get(node, "col")));
    } else {
        return yr(2, "st", st, "node",
                  yr(5, "k", ys("assign"), "name", u, "v", v, "line",
                     yr_get(node, "line"), "col", yr_get(node, "col")));
    }
}

/* ++x / x++: the target is an expression (id, index, dot) and is renamed
 * like any other — it is evaluated exactly once at run time. */
Yv *rn_incdec(Yv *node, Yv *st) {
    Yv *r = rn_node(yr_get(node, "tgt"), st);
    return yr(2, "st", yr_get(r, "st"), "node",
              yr(6, "k", ys("incdec"), "op", yr_get(node, "op"), "pre",
                 yr_get(node, "pre"), "tgt", yr_get(r, "node"), "line",
                 yr_get(node, "line"), "col", yr_get(node, "col")));
}

Yv *rn_opassign(Yv *node, Yv *st) {
    Yv *t = rn_node(yr_get(node, "tgt"), st);
    Yv *v = rn_node(yr_get(node, "v"), yr_get(t, "st"));
    return yr(2, "st", yr_get(v, "st"), "node",
              yr(6, "k", ys("opassign"), "op", yr_get(node, "op"), "tgt",
                 yr_get(t, "node"), "v", yr_get(v, "node"), "line",
                 yr_get(node, "line"), "col", yr_get(node, "col")));
}

Yv *rn_store(Yv *node, Yv *st) {
    Yv *p = rn_node(yr_get(node, "p"), st);
    return rn_store_val(node, yr_get(p, "node"), yr_get(p, "st"));
}

Yv *rn_store_val(Yv *node, Yv *p, Yv *st) {
    Yv *v = rn_node(yr_get(node, "v"), st);
    return yr(2, "st", yr_get(v, "st"), "node",
              yr(5, "k", ys("store"), "p", p, "v", yr_get(v, "node"), "line",
                 yr_get(node, "line"), "col", yr_get(node, "col")));
}

Yv *rn_ret(Yv *node, Yv *st) {
    Yv *r = rn_node(yr_get(node, "e"), st);
    return yr(2, "st", yr_get(r, "st"), "node",
              yr(4, "k", ys("ret"), "e", yr_get(r, "node"), "line",
                 yr_get(node, "line"), "col", yr_get(node, "col")));
}

Yv *rn_array(Yv *node, Yv *st) {
    Yv *r = rn_list(yr_get(node, "elems"), st);
    return yr(2, "st", yr_get(r, "st"), "node",
              yr(4, "k", ys("array"), "elems", yr_get(r, "nodes"), "line",
                 yr_get(node, "line"), "col", yr_get(node, "col")));
}

Yv *rn_arrrep(Yv *node, Yv *st) {
    Yv *r = rn_node(yr_get(node, "v"), st);
    return yr(2, "st", yr_get(r, "st"), "node",
              yr(5, "k", ys("arrrep"), "v", yr_get(r, "node"), "n",
                 yr_get(node, "n"), "line", yr_get(node, "line"), "col",
                 yr_get(node, "col")));
}

Yv *rn_reclit(Yv *node, Yv *st) {
    Yv *r = rn_list(yr_get(node, "vals"), st);
    return yr(2, "st", yr_get(r, "st"), "node",
              yr(5, "k", ys("rec"), "keys", yr_get(node, "keys"), "vals",
                 yr_get(r, "nodes"), "line", yr_get(node, "line"), "col",
                 yr_get(node, "col")));
}

Yv *rn_maplit(Yv *node, Yv *st) {
    Yv *r = rn_list(yr_get(node, "vals"), st);
    return yr(2, "st", yr_get(r, "st"), "node",
              yr(5, "k", ys("map"), "keys", yr_get(node, "keys"), "vals",
                 yr_get(r, "nodes"), "line", yr_get(node, "line"), "col",
                 yr_get(node, "col")));
}

Yv *rn_index(Yv *node, Yv *st) {
    Yv *a = rn_node(yr_get(node, "arr"), st);
    return rn_index_idx(node, yr_get(a, "node"), yr_get(a, "st"));
}

Yv *rn_index_idx(Yv *node, Yv *a, Yv *st) {
    Yv *x = rn_node(yr_get(node, "idx"), st);
    return yr(2, "st", yr_get(x, "st"), "node",
              yr(5, "k", ys("index"), "arr", a, "idx", yr_get(x, "node"),
                 "line", yr_get(node, "line"), "col", yr_get(node, "col")));
}

Yv *rn_slice(Yv *node, Yv *st) {
    Yv *a = rn_node(yr_get(node, "arr"), st);
    return rn_slice_lo(node, yr_get(a, "node"), yr_get(a, "st"));
}

Yv *rn_slice_lo(Yv *node, Yv *a, Yv *st) {
    Yv *l = rn_node(yr_get(node, "lo"), st);
    return rn_slice_hi(node, a, yr_get(l, "node"), yr_get(l, "st"));
}

Yv *rn_slice_hi(Yv *node, Yv *a, Yv *lo, Yv *st) {
    Yv *h = rn_node(yr_get(node, "hi"), st);
    return yr(2, "st", yr_get(h, "st"), "node",
              yr(6, "k", ys("slice"), "arr", a, "lo", lo, "hi",
                 yr_get(h, "node"), "line", yr_get(node, "line"), "col",
                 yr_get(node, "col")));
}

Yv *rn_dot(Yv *node, Yv *st) {
    Yv *o = rn_node(yr_get(node, "obj"), st);
    return yr(2, "st", yr_get(o, "st"), "node",
              yr(5, "k", ys("dot"), "obj", yr_get(o, "node"), "key",
                 yr_get(node, "key"), "line", yr_get(node, "line"), "col",
                 yr_get(node, "col")));
}

Yv *rn_idxassign(Yv *node, Yv *st) {
    Yv *a = rn_node(yr_get(node, "arr"), st);
    return rn_idxassign_idx(node, yr_get(a, "node"), yr_get(a, "st"));
}

Yv *rn_idxassign_idx(Yv *node, Yv *a, Yv *st) {
    Yv *x = rn_node(yr_get(node, "idx"), st);
    return rn_idxassign_val(node, a, yr_get(x, "node"), yr_get(x, "st"));
}

Yv *rn_idxassign_val(Yv *node, Yv *a, Yv *idx, Yv *st) {
    Yv *v = rn_node(yr_get(node, "v"), st);
    return yr(2, "st", yr_get(v, "st"), "node",
              yr(6, "k", ys("idxassign"), "arr", a, "idx", idx, "v",
                 yr_get(v, "node"), "line", yr_get(node, "line"), "col",
                 yr_get(node, "col")));
}

Yv *rn_dotassign(Yv *node, Yv *st) {
    Yv *o = rn_node(yr_get(node, "obj"), st);
    return rn_dotassign_val(node, yr_get(o, "node"), yr_get(o, "st"));
}

Yv *rn_dotassign_val(Yv *node, Yv *o, Yv *st) {
    Yv *v = rn_node(yr_get(node, "v"), st);
    return yr(2, "st", yr_get(v, "st"), "node",
              yr(6, "k", ys("dotassign"), "obj", o, "key",
                 yr_get(node, "key"), "v", yr_get(v, "node"), "line",
                 yr_get(node, "line"), "col", yr_get(node, "col")));
}

Yv *rn_foreach(Yv *node, Yv *st) {
    Yv *it = rn_node(yr_get(node, "iter"), st);
    return rn_foreach_body(node, yr_get(it, "node"), yr_get(it, "st"));
}

Yv *rn_foreach_body(Yv *node, Yv *iter, Yv *st) {
    Yv *st1 = rn_push(st);
    Yv *nb = rn_bind(st1, yr_get(node, "name"));
    return rn_foreach_block(node, iter, yr_get(nb, "uniq"), yr_get(nb, "st"));
}

Yv *rn_foreach_block(Yv *node, Yv *iter, Yv *uniq, Yv *st) {
    Yv *b = rn_block(yr_get(yr_get(node, "body"), "stmts"), st);
    Yv *st2 = rn_pop(yr_get(b, "st"));
    return yr(
        2, "st", st2, "node",
        yr(6, "k", ys("foreach"), "name", uniq, "iter", iter, "body",
           yr(4, "k", ys("block"), "stmts", yr_get(b, "stmts"), "line",
              yr_get(yr_get(node, "body"), "line"), "col",
              yr_get(yr_get(node, "body"), "col")),
           "line", yr_get(node, "line"), "col", yr_get(node, "col")));
}

Yv *rn_forrange(Yv *node, Yv *st) {
    Yv *l = rn_node(yr_get(node, "lo"), st);
    return rn_forrange_hi(node, yr_get(l, "node"), yr_get(l, "st"));
}

Yv *rn_forrange_hi(Yv *node, Yv *lo, Yv *st) {
    Yv *h = rn_node(yr_get(node, "hi"), st);
    return rn_forrange_body(node, lo, yr_get(h, "node"), yr_get(h, "st"));
}

Yv *rn_forrange_body(Yv *node, Yv *lo, Yv *hi, Yv *st) {
    Yv *st1 = rn_push(st);
    Yv *nb = rn_bind(st1, yr_get(node, "name"));
    return rn_forrange_block(node, lo, hi, yr_get(nb, "uniq"),
                             yr_get(nb, "st"));
}

Yv *rn_forrange_block(Yv *node, Yv *lo, Yv *hi, Yv *uniq, Yv *st) {
    Yv *b = rn_block(yr_get(yr_get(node, "body"), "stmts"), st);
    Yv *st2 = rn_pop(yr_get(b, "st"));
    return yr(
        2, "st", st2, "node",
        yr(7, "k", ys("forrange"), "name", uniq, "lo", lo, "hi", hi, "body",
           yr(4, "k", ys("block"), "stmts", yr_get(b, "stmts"), "line",
              yr_get(yr_get(node, "body"), "line"), "col",
              yr_get(yr_get(node, "body"), "col")),
           "line", yr_get(node, "line"), "col", yr_get(node, "col")));
}

Yv *rn_for(Yv *node, Yv *st) {
    Yv *ri = rn_node(yr_get(node, "init"), st);
    return rn_for_cond(node, yr_get(ri, "node"), yr_get(ri, "st"));
}

Yv *rn_for_cond(Yv *node, Yv *init, Yv *st) {
    Yv *rc = rn_node(yr_get(node, "cond"), st);
    return rn_for_step(node, init, yr_get(rc, "node"), yr_get(rc, "st"));
}

Yv *rn_for_step(Yv *node, Yv *init, Yv *cond, Yv *st) {
    Yv *rs = rn_node(yr_get(node, "step"), st);
    return rn_for_body(node, init, cond, yr_get(rs, "node"), yr_get(rs, "st"));
}

Yv *rn_for_body(Yv *node, Yv *init, Yv *cond, Yv *step, Yv *st) {
    Yv *b = rn_block(yr_get(yr_get(node, "body"), "stmts"), st);
    return yr(
        2, "st", yr_get(b, "st"), "node",
        yr(7, "k", ys("for"), "init", init, "cond", cond, "step", step,
           "body",
           yr(4, "k", ys("block"), "stmts", yr_get(b, "stmts"), "line",
              yr_get(yr_get(node, "body"), "line"), "col",
              yr_get(yr_get(node, "body"), "col")),
           "line", yr_get(node, "line"), "col", yr_get(node, "col")));
}

Yv *rn_decl(Yv *node, Yv *st) {
    /* NOTE: dispatch by shape into dedicated callees (see rn_node note):
     * named-def vs let-bound-func vs plain value — each body reads ONLY
     * its own shape's fields. */
    if (ys_eq_lit(yr_get(node, "kind"), "def")) {
        return rn_decl_def(node, st);
    } else {
        return rn_decl_rest(node, st);
    }
}

Yv *rn_decl_def(Yv *node, Yv *st) {
    /* name pre-bound by rn_prepass; look it up (must exist) */
    return rn_decl_def_lookup(node, rn_lookup(st, yr_get(node, "name")), st);
}

Yv *rn_decl_def_lookup(Yv *node, Yv *u, Yv *st) {
    /* NOTE: both arms share the key set (kind/def/name/v) — teq holds. */
    if (ys_eq_lit(u, "")) {
        Yv *b = rn_bind(st, yr_get(node, "name"));
        return rn_decl_def_go(node, yr_get(b, "uniq"), yr_get(b, "st"));
    } else {
        return rn_decl_def_go(node, u, st);
    }
}

Yv *rn_decl_def_go(Yv *node, Yv *u, Yv *st) {
    Yv *f = rn_func(yr_get(node, "v"), st);
    return yr(2, "st", yr_get(f, "st"), "node",
              yr(6, "k", ys("decl"), "kind", ys("def"), "name", u, "v",
                 yr_get(f, "node"), "line", yr_get(node, "line"), "col",
                 yr_get(node, "col")));
}

Yv *rn_decl_rest(Yv *node, Yv *st) {
    if (ys_eq_lit(yr_get(yr_get(node, "v"), "k"), "func")) {
        return rn_decl_func(node, st);
    } else {
        return rn_decl_val(node, st);
    }
}

Yv *rn_decl_func(Yv *node, Yv *st) {
    return rn_decl_func_lookup(node, rn_lookup(st, yr_get(node, "name")), st);
}

Yv *rn_decl_func_lookup(Yv *node, Yv *u, Yv *st) {
    /* NOTE: both arms share the key set — teq holds. */
    if (ys_eq_lit(u, "")) {
        Yv *b = rn_bind(st, yr_get(node, "name"));
        return rn_decl_func_go(node, yr_get(b, "uniq"), yr_get(b, "st"));
    } else {
        return rn_decl_func_go(node, u, st);
    }
}

Yv *rn_decl_func_go(Yv *node, Yv *u, Yv *st) {
    Yv *f = rn_func(yr_get(node, "v"), st);
    return rn_decl_func_finish(node, u, yr_get(f, "node"), yr_get(f, "st"));
}

Yv *rn_decl_func_finish(Yv *node, Yv *u, Yv *fv, Yv *st) {
    return yr(2, "st", st, "node",
              yr(7, "k", ys("decl"), "kind", yr_get(node, "kind"), "name", u,
                 "typ", rn_type(st, yr_get(node, "typ")), "v", fv, "line",
                 yr_get(node, "line"), "col", yr_get(node, "col")));
}

Yv *rn_decl_val(Yv *node, Yv *st) {
    Yv *r = rn_node(yr_get(node, "v"), st);
    return rn_decl_val_bind(node, yr_get(r, "node"), yr_get(r, "st"));
}

Yv *rn_decl_val_bind(Yv *node, Yv *v, Yv *st) {
    Yv *b = rn_bind(st, yr_get(node, "name"));
    return rn_decl_val_finish(node, v, yr_get(b, "uniq"), yr_get(b, "st"));
}

Yv *rn_decl_val_finish(Yv *node, Yv *v, Yv *uniq, Yv *st) {
    Yv *un = rn_unknown_type(st, yr_get(node, "typ"));
    Yv *v2 = v;
    if (!ys_eq_lit(un, "")) {
        Yv *es = yav(0);
        es = ya_push(es, rn_unknown_err(un, yv_l(yr_get(node, "line")),
                                        yv_l(yr_get(node, "col"))));
        es = ya_push(es, v);
        v2 = yr(4, "k", ys("block"), "stmts", es, "line",
                yr_get(node, "line"), "col", yr_get(node, "col"));
        ;
    } else {
        ;
    }
    return yr(2, "st", st, "node",
              yr(7, "k", ys("decl"), "kind", yr_get(node, "kind"), "name",
                 uniq, "typ", rn_type(st, yr_get(node, "typ")), "v", v2,
                 "line", yr_get(node, "line"), "col", yr_get(node, "col")));
}

/* Rename a func value. `func` is annotated with the full func shape, so its
 * fields type-check against that shape; the rn_func_p* chain exists to pass
 * each one on as a plain VALUE (params/ptypes/ret/body/line/col) so no callee
 * carries a body full of `func.x` reads — rn_func_p4 is the one place with
 * two, the two longs. */
Yv *rn_func(Yv *func, Yv *st) {
    return rn_func_p1(func, yr_get(func, "params"), rn_push(st));
}

Yv *rn_func_p1(Yv *func, Yv *fparams, Yv *st) {
    return rn_func_p2(func, fparams, yr_get(func, "ptypes"), st);
}

Yv *rn_func_p2(Yv *func, Yv *fparams, Yv *fptypes, Yv *st) {
    return rn_func_p3(func, fparams, fptypes, yr_get(func, "ret"), st);
}

Yv *rn_func_p3(Yv *func, Yv *fparams, Yv *fptypes, Yv *fret, Yv *st) {
    return rn_func_p4(func, fparams, fptypes, fret, yr_get(func, "body"), st);
}

Yv *rn_func_p4(Yv *func, Yv *fparams, Yv *fptypes, Yv *fret, Yv *fbody,
               Yv *st) {
    return rn_func_p5(fparams, fptypes, fret, fbody,
                      yv_l(yr_get(func, "line")), yv_l(yr_get(func, "col")),
                      st);
}

Yv *rn_func_p5(Yv *fparams, Yv *fptypes, Yv *fret, Yv *fbody, long fline,
               long fcol, Yv *st) {
    return rn_func_params(fparams, fptypes, fret, fbody, fline, fcol, st);
}

Yv *rn_func_params(Yv *fparams, Yv *fptypes, Yv *fret, Yv *fbody, long fline,
                   long fcol, Yv *st) {
    return rn_func_go(fparams, fptypes, fret, fbody, fline, fcol, yav(0), 0,
                      st);
}

Yv *rn_func_go(Yv *fparams, Yv *fptypes, Yv *fret, Yv *fbody, long fline,
               long fcol, Yv *params, long i, Yv *st) {
    /* NOTE: recursion over the param list (replaces the while loop): the
     * loop's `st = b.st` rebind poisoned the merged-shape read of st.
     * fparams stays BARE (like res(node)): the single `fparams[i]` read
     * unifies via the tcompat law (tnone). */
    if (i >= yv_len(fparams)) {
        return rn_func_body(fptypes, fret, fbody, fline, fcol, params, st);
    } else {
        Yv *b = rn_bind(st, ya_get(fparams, i));
        return rn_func_go(fparams, fptypes, fret, fbody, fline, fcol,
                          ya_push(params, yr_get(b, "uniq")), i + 1,
                          yr_get(b, "st"));
    }
}

Yv *rn_func_body(Yv *fptypes, Yv *fret, Yv *fbody, long fline, long fcol,
                 Yv *params, Yv *st) {
    /* NOTE: fbody read ONCE here (one read site — no merge). */
    Yv *b = rn_block(yr_get(fbody, "stmts"), st);
    return rn_func_finish(fptypes, fret, fbody, fline, fcol, params,
                          yr_get(b, "stmts"), rn_pop(yr_get(b, "st")));
}

Yv *rn_func_finish(Yv *fptypes, Yv *fret, Yv *fbody, long fline, long fcol,
                   Yv *params, Yv *stmts, Yv *st) {
    /* NOTE: NO record reads here — all values are params already.
     * (fbody is kept for 1:1 signature parity but never read, as in Y.) */
    (void)fbody;
    Yv *un = rn_unknown_list(st, fptypes);
    if (ys_eq_lit(un, "")) {
        un = rn_unknown_type(st, fret);
        ;
    } else {
        ;
    }
    Yv *body = yav(0);
    if (!ys_eq_lit(un, "")) {
        body = ya_push(body, rn_unknown_err(un, fline, fcol));
        ;
    } else {
        ;
    }
    long i = 0;
    while (i < yv_len(stmts)) {
        body = ya_push(body, ya_get(stmts, i));
        i = i + 1;
    }
    return yr(2, "st", st, "node",
              yr(7, "k", ys("func"), "params", params, "ptypes", rn_types(st, fptypes),
                 "ret", rn_type(st, fret), "body",
                 yr(4, "k", ys("block"), "stmts", body, "line",
                    yv_long(fline), "col", yv_long(fcol)),
                 "line", yv_long(fline), "col", yv_long(fcol)));
}

Yv *rename_program(Yv *ast) {
    return rename_program_go(yr_get(ast, "stmts"), yv_l(yr_get(ast, "line")),
                             yv_l(yr_get(ast, "col")));
}

Yv *rename_program_go(Yv *stmts, long line, long col) {
    /* NOTE: fields passed as values (see rn_func note). */
    Yv *st = yr(4, "scopes", yav(1, yav(0)), "n", yv_long(1), "tys", yav(0), "dfl", yav(0));
    Yv *b = rn_block(stmts, st);
    return yr(4, "k", ys("block"), "stmts", yr_get(b, "stmts"), "line",
              yv_long(line), "col", yv_long(col));
}
