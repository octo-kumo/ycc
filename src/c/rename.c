/* rename.c — static name resolution (uniquify) for the native pipeline.
 * 1:1 C twin of src/y/rename.y (see PORTING.md).
 *
 * rename_program(ast) -> ast' where every binding has a globally unique
 * name (`orig$N`; `$` is lexer-illegal, so generated names can never collide
 * with user code). After this pass there is no shadowing and no scopes for
 * later passes to resolve: types.y keeps one flat map + a function-depth
 * counter (for the capture law), native.y keeps one flat env.
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
 * bool -> int. Records are insertion-ordered maps (ym), arrays are yav /
 * ya_get / ya_push / ya_set (reference semantics, as in Y).
 */

/* imported */ /* none: rename.y is self-contained — it calls only its own
 * defs and the push/len/tostring builtins (ya_push/yv_len/ys_long). */

#include "rename.h"

/* state = { scopes: [[{ orig: str, uniq: str }]], n: long } */
Yv *rn_fresh(Yv *st, Yv *orig) {
    Yv *u = ys_cat(ys_cat(orig, ys("$")), ys_long(yv_l(ym_get(st, "n"))));
    Yv *nst = ym(2, "scopes", ym_get(st, "scopes"), "n",
                 yv_long(yv_l(ym_get(st, "n")) + 1));
    return ym(2, "st", nst, "name", u);
}

Yv *rn_push(Yv *st) {
    Yv *scopes = ya_push(ym_get(st, "scopes"), yav(0));
    return ym(2, "scopes", scopes, "n", ym_get(st, "n"));
}

Yv *rn_pop(Yv *st) {
    Yv *scopes = yav(0);
    Yv *old = ym_get(st, "scopes");
    long i = 0;
    while (i < yv_len(old) - 1) {
        scopes = ya_push(scopes, ya_get(old, i));
        i = i + 1;
    }
    return ym(2, "scopes", scopes, "n", ym_get(st, "n"));
}

Yv *rn_define(Yv *st, Yv *orig, Yv *uniq) {
    Yv *scopes = ym_get(st, "scopes");
    Yv *top = ya_get(scopes, yv_len(scopes) - 1);
    top = ya_push(top, ym(2, "orig", orig, "uniq", uniq));
    ya_set(scopes, yv_len(scopes) - 1, top);
    return ym(2, "scopes", scopes, "n", ym_get(st, "n"));
}

Yv *rn_lookup(Yv *st, Yv *name) {
    /* Innermost scope first; within a frame, the NEWEST binding wins
     * (a later let shadows an earlier one). */
    Yv *all = ym_get(st, "scopes");
    long i = yv_len(all) - 1;
    Yv *found = ys("");
    while (i >= 0) {
        Yv *frame = ya_get(all, i);
        long j = yv_len(frame) - 1;
        while (j >= 0) {
            Yv *e = ya_get(frame, j);
            if (ys_eq(ym_get(e, "orig"), name)) {
                found = ym_get(e, "uniq");
                j = -1;
                i = -1;
                ;
            } else {
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
    st = rn_define(ym_get(r, "st"), orig, ym_get(r, "name"));
    return ym(2, "st", st, "uniq", ym_get(r, "name"));
}

Yv *rn_list(Yv *nodes, Yv *st) {
    Yv *out = yav(0);
    long i = 0;
    while (i < yv_len(nodes)) {
        Yv *r = rn_node(ya_get(nodes, i), st);
        st = ym_get(r, "st");
        out = ya_push(out, ym_get(r, "node"));
        i = i + 1;
    }
    return ym(2, "st", st, "nodes", out);
}

Yv *rn_id(Yv *st, Yv *name, long line, long col) {
    Yv *u = rn_lookup(st, name);
    if (ys_eq_lit(u, "")) {
        return ym(2, "st", st, "node",
                  ym(4, "k", ys("id"), "v", name, "line", yv_long(line), "col",
                     yv_long(col)));
    } else {
        return ym(2, "st", st, "node",
                  ym(4, "k", ys("id"), "v", u, "line", yv_long(line), "col",
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
    if (ys_eq_lit(ym_get(s, "k"), "decl")) {
        return rn_prepass_decl(s, st);
    } else {
        return st;
    }
}

Yv *rn_prepass_decl(Yv *s, Yv *st) {
    /* decl shapes only (named def vs let-bound func): one `s.v.k` read in
     * this body (see parse_type_arrow note — two reads in one body merge). */
    if (ys_eq_lit(ym_get(s, "kind"), "def")) {
        Yv *r = rn_bind(st, ym_get(s, "name"));
        return ym_get(r, "st");
    } else if (ys_eq_lit(ym_get(ym_get(s, "v"), "k"), "func")) {
        Yv *r = rn_bind(st, ym_get(s, "name"));
        return ym_get(r, "st");
    } else {
        return st;
    }
}

/* Redefinition shadows, exactly as it does in the VM: `def f ... def f ...`
 * keeps the LAST definition, and every reference (before or after, since
 * defs hoist) binds to it. rename.y resolves def names through the prepass
 * binding, so two same-named defs would otherwise collapse onto one unique
 * name; give the earlier ones a dead name instead. They are still checked
 * and emitted — only unreachable. */
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
    if (ys_eq_lit(ym_get(s, "k"), "decl")) {
        return rn_shadow_decl(s, stmts, i);
    } else {
        return s;
    }
}

Yv *rn_shadow_decl(Yv *s, Yv *stmts, long i) {
    /* NOTE: one `s.v.k` read per body (see rn_prepass_decl note). */
    if (ys_eq_lit(ym_get(s, "kind"), "def")) {
        return rn_shadow_go(s, stmts, i);
    } else if (ys_eq_lit(ym_get(ym_get(s, "v"), "k"), "func")) {
        return rn_shadow_go(s, stmts, i);
    } else {
        return s;
    }
}

Yv *rn_shadow_go(Yv *s, Yv *stmts, long i) {
    if (rn_redefined_later(stmts, i, ym_get(s, "name"))) {
        return rn_rebuild_decl(
            s, ys_cat(ys_cat(ym_get(s, "name"), ys("$shadow")), ys_long(i)));
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
    if (ys_eq_lit(ym_get(s, "k"), "decl")) {
        return rn_decl_name_go(s);
    } else {
        return ys("");
    }
}

Yv *rn_decl_name_go(Yv *s) {
    /* NOTE: one `s.v.k` read per body (see rn_prepass_decl note). */
    if (ys_eq_lit(ym_get(s, "kind"), "def")) {
        return ym_get(s, "name");
    } else if (ys_eq_lit(ym_get(ym_get(s, "v"), "k"), "func")) {
        return ym_get(s, "name");
    } else {
        return ys("");
    }
}

Yv *rn_rebuild_decl(Yv *s, Yv *newname) {
    /* NOTE: one literal per arm would merge two key sets through the same
     * `if` (see parse_type_arrow note) — dispatch to single-call arms so
     * each shape unifies against the {k}-hole return type instead. */
    if (ys_eq_lit(ym_get(s, "kind"), "def")) {
        return rn_rebuild_def(s, newname);
    } else {
        return rn_rebuild_let(s, newname);
    }
}

Yv *rn_rebuild_def(Yv *s, Yv *newname) {
    return ym(6, "k", ys("decl"), "kind", ys("def"), "name", newname, "v",
              ym_get(s, "v"), "line", ym_get(s, "line"), "col",
              ym_get(s, "col"));
}

Yv *rn_rebuild_let(Yv *s, Yv *newname) {
    return ym(7, "k", ys("decl"), "kind", ym_get(s, "kind"), "name", newname,
              "typ", ym_get(s, "typ"), "v", ym_get(s, "v"), "line",
              ym_get(s, "line"), "col", ym_get(s, "col"));
}

Yv *rn_block(Yv *stmts, Yv *st) {
    stmts = rn_shadow_dups(stmts);
    st = rn_push(st);
    st = rn_prepass(stmts, st);
    Yv *r = rn_list(stmts, st);
    st = rn_pop(ym_get(r, "st"));
    return ym(2, "st", st, "stmts", ym_get(r, "nodes"));
}

Yv *rn_node(Yv *node, Yv *st) {
    /* NOTE: dispatch WITHOUT a shared-shape if-chain (see parser.y
     * parse_type_arrow note): a 25-arm chain on one name merges every arm's
     * node shape through the flow-insensitive env (each arm's return type
     * must teq ALL others). Each arm here is a SINGLE callee call (or leaf
     * literal) with the uniform return type R, so arms always agree.
     * Leaf shapes (num/str/bool/null) return the node untouched. */
    Yv *k = ym_get(node, "k");
    if (ys_eq_lit(k, "num")) {
        return ym(2, "st", st, "node", node);
    } else if (ys_eq_lit(k, "str")) {
        return ym(2, "st", st, "node", node);
    } else if (ys_eq_lit(k, "bstr")) {
        return ym(2, "st", st, "node", node);
    } else if (ys_eq_lit(k, "bool")) {
        return ym(2, "st", st, "node", node);
    } else if (ys_eq_lit(k, "null")) {
        return ym(2, "st", st, "node", node);
    } else if (ys_eq_lit(k, "id")) {
        return rn_id(st, ym_get(node, "v"), yv_l(ym_get(node, "line")),
                     yv_l(ym_get(node, "col")));
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
    } else if (ys_eq_lit(k, "map")) {
        return rn_map(node, st);
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
    } else {
        return ym(2, "st", st, "node", node);
    }
}

/* One def per AST shape (see rn_node note). Each takes the bare node hole
 * (param name `node` is exempt from annotation, like parser.y res) plus the
 * annotated scope state, and returns the uniform R. Field reads off the
 * bare hole unify quietly via the tcompat law (tnone); each body reads
 * ONLY its own shape's fields. */
Yv *rn_un(Yv *node, Yv *st) {
    Yv *r = rn_node(ym_get(node, "e"), st);
    return ym(2, "st", ym_get(r, "st"), "node",
              ym(5, "k", ys("un"), "op", ym_get(node, "op"), "e",
                 ym_get(r, "node"), "line", ym_get(node, "line"), "col",
                 ym_get(node, "col")));
}

Yv *rn_addrderef(Yv *node, Yv *st) {
    Yv *k = ym_get(node, "k");
    Yv *r = rn_node(ym_get(node, "e"), st);
    return ym(2, "st", ym_get(r, "st"), "node",
              ym(4, "k", k, "e", ym_get(r, "node"), "line",
                 ym_get(node, "line"), "col", ym_get(node, "col")));
}

Yv *rn_bin(Yv *node, Yv *st) {
    Yv *l = rn_node(ym_get(node, "l"), st);
    Yv *r = rn_node(ym_get(node, "r"), ym_get(l, "st"));
    return ym(2, "st", ym_get(r, "st"), "node",
              ym(6, "k", ys("bin"), "op", ym_get(node, "op"), "l",
                 ym_get(l, "node"), "r", ym_get(r, "node"), "line",
                 ym_get(node, "line"), "col", ym_get(node, "col")));
}

Yv *rn_call(Yv *node, Yv *st) {
    Yv *c = rn_node(ym_get(node, "callee"), st);
    Yv *a = rn_list(ym_get(node, "args"), ym_get(c, "st"));
    return ym(2, "st", ym_get(a, "st"), "node",
              ym(5, "k", ys("call"), "callee", ym_get(c, "node"), "args",
                 ym_get(a, "nodes"), "line", ym_get(node, "line"), "col",
                 ym_get(node, "col")));
}

Yv *rn_if(Yv *node, Yv *st) {
    Yv *c = rn_node(ym_get(node, "cond"), st);
    return rn_if_then(node, ym_get(c, "node"), ym_get(c, "st"));
}

Yv *rn_if_then(Yv *node, Yv *cond, Yv *st) {
    Yv *tb = rn_block(ym_get(ym_get(node, "then"), "stmts"), st);
    return rn_if_finish(node, cond, ym_get(tb, "stmts"), ym_get(tb, "st"));
}

Yv *rn_if_finish(Yv *node, Yv *cond, Yv *tstmts, Yv *st) {
    /* NOTE: both arms build the SAME key set (cond/then/els/has_else);
     * els differs (renamed vs passthrough) but both unify — teq holds.
     * NOTE: `0;` tails on bare-ifs (see parser.y parse_binary note). */
    if (yv_b(ym_get(node, "has_else"))) {
        Yv *e = rn_node(ym_get(node, "els"), st);
        return ym(
            2, "st", ym_get(e, "st"), "node",
            ym(7, "k", ys("if"), "cond", cond, "then",
               ym(4, "k", ys("block"), "stmts", tstmts, "line",
                  ym_get(ym_get(node, "then"), "line"), "col",
                  ym_get(ym_get(node, "then"), "col")),
               "els", ym_get(e, "node"), "has_else", yv_bool(1), "line",
               ym_get(node, "line"), "col", ym_get(node, "col")));
    } else {
        return ym(
            2, "st", st, "node",
            ym(7, "k", ys("if"), "cond", cond, "then",
               ym(4, "k", ys("block"), "stmts", tstmts, "line",
                  ym_get(ym_get(node, "then"), "line"), "col",
                  ym_get(ym_get(node, "then"), "col")),
               "els", ym_get(node, "els"), "has_else", yv_bool(0), "line",
               ym_get(node, "line"), "col", ym_get(node, "col")));
    }
}

Yv *rn_while(Yv *node, Yv *st) {
    Yv *c = rn_node(ym_get(node, "cond"), st);
    return rn_while_body(node, ym_get(c, "node"), ym_get(c, "st"));
}

Yv *rn_while_body(Yv *node, Yv *cond, Yv *st) {
    Yv *b = rn_block(ym_get(ym_get(node, "body"), "stmts"), st);
    return ym(2, "st", ym_get(b, "st"), "node",
              ym(5, "k", ys("while"), "cond", cond, "body",
                 ym(4, "k", ys("block"), "stmts", ym_get(b, "stmts"), "line",
                    ym_get(ym_get(node, "body"), "line"), "col",
                    ym_get(ym_get(node, "body"), "col")),
                 "line", ym_get(node, "line"), "col", ym_get(node, "col")));
}

Yv *rn_blocknode(Yv *node, Yv *st) {
    Yv *b = rn_block(ym_get(node, "stmts"), st);
    return ym(2, "st", ym_get(b, "st"), "node",
              ym(4, "k", ys("block"), "stmts", ym_get(b, "stmts"), "line",
                 ym_get(node, "line"), "col", ym_get(node, "col")));
}

Yv *rn_assign(Yv *node, Yv *st) {
    Yv *r = rn_node(ym_get(node, "v"), st);
    return rn_assign_lookup(node, ym_get(r, "node"), ym_get(r, "st"));
}

Yv *rn_assign_lookup(Yv *node, Yv *v, Yv *st) {
    Yv *u = rn_lookup(st, ym_get(node, "name"));
    return rn_assign_finish(node, v, u, st);
}

Yv *rn_assign_finish(Yv *node, Yv *v, Yv *u, Yv *st) {
    /* NOTE: both arms share the key set; name differs (passthrough vs
     * renamed) but str vs hole unifies — teq holds. */
    if (ys_eq_lit(u, "")) {
        return ym(2, "st", st, "node",
                  ym(5, "k", ys("assign"), "name", ym_get(node, "name"), "v",
                     v, "line", ym_get(node, "line"), "col",
                     ym_get(node, "col")));
    } else {
        return ym(2, "st", st, "node",
                  ym(5, "k", ys("assign"), "name", u, "v", v, "line",
                     ym_get(node, "line"), "col", ym_get(node, "col")));
    }
}

/* ++x / x++: the target is an expression (id, index, dot) and is renamed
 * like any other — it is evaluated exactly once at run time. */
Yv *rn_incdec(Yv *node, Yv *st) {
    Yv *r = rn_node(ym_get(node, "tgt"), st);
    return ym(2, "st", ym_get(r, "st"), "node",
              ym(6, "k", ys("incdec"), "op", ym_get(node, "op"), "pre",
                 ym_get(node, "pre"), "tgt", ym_get(r, "node"), "line",
                 ym_get(node, "line"), "col", ym_get(node, "col")));
}

Yv *rn_opassign(Yv *node, Yv *st) {
    Yv *t = rn_node(ym_get(node, "tgt"), st);
    Yv *v = rn_node(ym_get(node, "v"), ym_get(t, "st"));
    return ym(2, "st", ym_get(v, "st"), "node",
              ym(6, "k", ys("opassign"), "op", ym_get(node, "op"), "tgt",
                 ym_get(t, "node"), "v", ym_get(v, "node"), "line",
                 ym_get(node, "line"), "col", ym_get(node, "col")));
}

Yv *rn_store(Yv *node, Yv *st) {
    Yv *p = rn_node(ym_get(node, "p"), st);
    return rn_store_val(node, ym_get(p, "node"), ym_get(p, "st"));
}

Yv *rn_store_val(Yv *node, Yv *p, Yv *st) {
    Yv *v = rn_node(ym_get(node, "v"), st);
    return ym(2, "st", ym_get(v, "st"), "node",
              ym(5, "k", ys("store"), "p", p, "v", ym_get(v, "node"), "line",
                 ym_get(node, "line"), "col", ym_get(node, "col")));
}

Yv *rn_ret(Yv *node, Yv *st) {
    Yv *r = rn_node(ym_get(node, "e"), st);
    return ym(2, "st", ym_get(r, "st"), "node",
              ym(4, "k", ys("ret"), "e", ym_get(r, "node"), "line",
                 ym_get(node, "line"), "col", ym_get(node, "col")));
}

Yv *rn_array(Yv *node, Yv *st) {
    Yv *r = rn_list(ym_get(node, "elems"), st);
    return ym(2, "st", ym_get(r, "st"), "node",
              ym(4, "k", ys("array"), "elems", ym_get(r, "nodes"), "line",
                 ym_get(node, "line"), "col", ym_get(node, "col")));
}

Yv *rn_arrrep(Yv *node, Yv *st) {
    Yv *r = rn_node(ym_get(node, "v"), st);
    return ym(2, "st", ym_get(r, "st"), "node",
              ym(5, "k", ys("arrrep"), "v", ym_get(r, "node"), "n",
                 ym_get(node, "n"), "line", ym_get(node, "line"), "col",
                 ym_get(node, "col")));
}

Yv *rn_map(Yv *node, Yv *st) {
    Yv *r = rn_list(ym_get(node, "vals"), st);
    return ym(2, "st", ym_get(r, "st"), "node",
              ym(5, "k", ys("map"), "keys", ym_get(node, "keys"), "vals",
                 ym_get(r, "nodes"), "line", ym_get(node, "line"), "col",
                 ym_get(node, "col")));
}

Yv *rn_index(Yv *node, Yv *st) {
    Yv *a = rn_node(ym_get(node, "arr"), st);
    return rn_index_idx(node, ym_get(a, "node"), ym_get(a, "st"));
}

Yv *rn_index_idx(Yv *node, Yv *a, Yv *st) {
    Yv *x = rn_node(ym_get(node, "idx"), st);
    return ym(2, "st", ym_get(x, "st"), "node",
              ym(5, "k", ys("index"), "arr", a, "idx", ym_get(x, "node"),
                 "line", ym_get(node, "line"), "col", ym_get(node, "col")));
}

Yv *rn_slice(Yv *node, Yv *st) {
    Yv *a = rn_node(ym_get(node, "arr"), st);
    return rn_slice_lo(node, ym_get(a, "node"), ym_get(a, "st"));
}

Yv *rn_slice_lo(Yv *node, Yv *a, Yv *st) {
    Yv *l = rn_node(ym_get(node, "lo"), st);
    return rn_slice_hi(node, a, ym_get(l, "node"), ym_get(l, "st"));
}

Yv *rn_slice_hi(Yv *node, Yv *a, Yv *lo, Yv *st) {
    Yv *h = rn_node(ym_get(node, "hi"), st);
    return ym(2, "st", ym_get(h, "st"), "node",
              ym(6, "k", ys("slice"), "arr", a, "lo", lo, "hi",
                 ym_get(h, "node"), "line", ym_get(node, "line"), "col",
                 ym_get(node, "col")));
}

Yv *rn_dot(Yv *node, Yv *st) {
    Yv *o = rn_node(ym_get(node, "obj"), st);
    return ym(2, "st", ym_get(o, "st"), "node",
              ym(5, "k", ys("dot"), "obj", ym_get(o, "node"), "key",
                 ym_get(node, "key"), "line", ym_get(node, "line"), "col",
                 ym_get(node, "col")));
}

Yv *rn_idxassign(Yv *node, Yv *st) {
    Yv *a = rn_node(ym_get(node, "arr"), st);
    return rn_idxassign_idx(node, ym_get(a, "node"), ym_get(a, "st"));
}

Yv *rn_idxassign_idx(Yv *node, Yv *a, Yv *st) {
    Yv *x = rn_node(ym_get(node, "idx"), st);
    return rn_idxassign_val(node, a, ym_get(x, "node"), ym_get(x, "st"));
}

Yv *rn_idxassign_val(Yv *node, Yv *a, Yv *idx, Yv *st) {
    Yv *v = rn_node(ym_get(node, "v"), st);
    return ym(2, "st", ym_get(v, "st"), "node",
              ym(6, "k", ys("idxassign"), "arr", a, "idx", idx, "v",
                 ym_get(v, "node"), "line", ym_get(node, "line"), "col",
                 ym_get(node, "col")));
}

Yv *rn_dotassign(Yv *node, Yv *st) {
    Yv *o = rn_node(ym_get(node, "obj"), st);
    return rn_dotassign_val(node, ym_get(o, "node"), ym_get(o, "st"));
}

Yv *rn_dotassign_val(Yv *node, Yv *o, Yv *st) {
    Yv *v = rn_node(ym_get(node, "v"), st);
    return ym(2, "st", ym_get(v, "st"), "node",
              ym(6, "k", ys("dotassign"), "obj", o, "key",
                 ym_get(node, "key"), "v", ym_get(v, "node"), "line",
                 ym_get(node, "line"), "col", ym_get(node, "col")));
}

Yv *rn_foreach(Yv *node, Yv *st) {
    Yv *it = rn_node(ym_get(node, "iter"), st);
    return rn_foreach_body(node, ym_get(it, "node"), ym_get(it, "st"));
}

Yv *rn_foreach_body(Yv *node, Yv *iter, Yv *st) {
    Yv *st1 = rn_push(st);
    Yv *nb = rn_bind(st1, ym_get(node, "name"));
    return rn_foreach_block(node, iter, ym_get(nb, "uniq"), ym_get(nb, "st"));
}

Yv *rn_foreach_block(Yv *node, Yv *iter, Yv *uniq, Yv *st) {
    Yv *b = rn_block(ym_get(ym_get(node, "body"), "stmts"), st);
    Yv *st2 = rn_pop(ym_get(b, "st"));
    return ym(
        2, "st", st2, "node",
        ym(6, "k", ys("foreach"), "name", uniq, "iter", iter, "body",
           ym(4, "k", ys("block"), "stmts", ym_get(b, "stmts"), "line",
              ym_get(ym_get(node, "body"), "line"), "col",
              ym_get(ym_get(node, "body"), "col")),
           "line", ym_get(node, "line"), "col", ym_get(node, "col")));
}

Yv *rn_forrange(Yv *node, Yv *st) {
    Yv *l = rn_node(ym_get(node, "lo"), st);
    return rn_forrange_hi(node, ym_get(l, "node"), ym_get(l, "st"));
}

Yv *rn_forrange_hi(Yv *node, Yv *lo, Yv *st) {
    Yv *h = rn_node(ym_get(node, "hi"), st);
    return rn_forrange_body(node, lo, ym_get(h, "node"), ym_get(h, "st"));
}

Yv *rn_forrange_body(Yv *node, Yv *lo, Yv *hi, Yv *st) {
    Yv *st1 = rn_push(st);
    Yv *nb = rn_bind(st1, ym_get(node, "name"));
    return rn_forrange_block(node, lo, hi, ym_get(nb, "uniq"),
                             ym_get(nb, "st"));
}

Yv *rn_forrange_block(Yv *node, Yv *lo, Yv *hi, Yv *uniq, Yv *st) {
    Yv *b = rn_block(ym_get(ym_get(node, "body"), "stmts"), st);
    Yv *st2 = rn_pop(ym_get(b, "st"));
    return ym(
        2, "st", st2, "node",
        ym(7, "k", ys("forrange"), "name", uniq, "lo", lo, "hi", hi, "body",
           ym(4, "k", ys("block"), "stmts", ym_get(b, "stmts"), "line",
              ym_get(ym_get(node, "body"), "line"), "col",
              ym_get(ym_get(node, "body"), "col")),
           "line", ym_get(node, "line"), "col", ym_get(node, "col")));
}

Yv *rn_for(Yv *node, Yv *st) {
    Yv *ri = rn_node(ym_get(node, "init"), st);
    return rn_for_cond(node, ym_get(ri, "node"), ym_get(ri, "st"));
}

Yv *rn_for_cond(Yv *node, Yv *init, Yv *st) {
    Yv *rc = rn_node(ym_get(node, "cond"), st);
    return rn_for_step(node, init, ym_get(rc, "node"), ym_get(rc, "st"));
}

Yv *rn_for_step(Yv *node, Yv *init, Yv *cond, Yv *st) {
    Yv *rs = rn_node(ym_get(node, "step"), st);
    return rn_for_body(node, init, cond, ym_get(rs, "node"), ym_get(rs, "st"));
}

Yv *rn_for_body(Yv *node, Yv *init, Yv *cond, Yv *step, Yv *st) {
    Yv *b = rn_block(ym_get(ym_get(node, "body"), "stmts"), st);
    return ym(
        2, "st", ym_get(b, "st"), "node",
        ym(7, "k", ys("for"), "init", init, "cond", cond, "step", step,
           "body",
           ym(4, "k", ys("block"), "stmts", ym_get(b, "stmts"), "line",
              ym_get(ym_get(node, "body"), "line"), "col",
              ym_get(ym_get(node, "body"), "col")),
           "line", ym_get(node, "line"), "col", ym_get(node, "col")));
}

Yv *rn_decl(Yv *node, Yv *st) {
    /* NOTE: dispatch by shape into dedicated callees (see rn_node note):
     * named-def vs let-bound-func vs plain value — each body reads ONLY
     * its own shape's fields. */
    if (ys_eq_lit(ym_get(node, "kind"), "def")) {
        return rn_decl_def(node, st);
    } else {
        return rn_decl_rest(node, st);
    }
}

Yv *rn_decl_def(Yv *node, Yv *st) {
    /* name pre-bound by rn_prepass; look it up (must exist) */
    return rn_decl_def_lookup(node, rn_lookup(st, ym_get(node, "name")), st);
}

Yv *rn_decl_def_lookup(Yv *node, Yv *u, Yv *st) {
    /* NOTE: both arms share the key set (kind/def/name/v) — teq holds. */
    if (ys_eq_lit(u, "")) {
        Yv *b = rn_bind(st, ym_get(node, "name"));
        return rn_decl_def_go(node, ym_get(b, "uniq"), ym_get(b, "st"));
    } else {
        return rn_decl_def_go(node, u, st);
    }
}

Yv *rn_decl_def_go(Yv *node, Yv *u, Yv *st) {
    Yv *f = rn_func(ym_get(node, "v"), st);
    return ym(2, "st", ym_get(f, "st"), "node",
              ym(6, "k", ys("decl"), "kind", ys("def"), "name", u, "v",
                 ym_get(f, "node"), "line", ym_get(node, "line"), "col",
                 ym_get(node, "col")));
}

Yv *rn_decl_rest(Yv *node, Yv *st) {
    if (ys_eq_lit(ym_get(ym_get(node, "v"), "k"), "func")) {
        return rn_decl_func(node, st);
    } else {
        return rn_decl_val(node, st);
    }
}

Yv *rn_decl_func(Yv *node, Yv *st) {
    return rn_decl_func_lookup(node, rn_lookup(st, ym_get(node, "name")), st);
}

Yv *rn_decl_func_lookup(Yv *node, Yv *u, Yv *st) {
    /* NOTE: both arms share the key set — teq holds. */
    if (ys_eq_lit(u, "")) {
        Yv *b = rn_bind(st, ym_get(node, "name"));
        return rn_decl_func_go(node, ym_get(b, "uniq"), ym_get(b, "st"));
    } else {
        return rn_decl_func_go(node, u, st);
    }
}

Yv *rn_decl_func_go(Yv *node, Yv *u, Yv *st) {
    Yv *f = rn_func(ym_get(node, "v"), st);
    return rn_decl_func_finish(node, u, ym_get(f, "node"), ym_get(f, "st"));
}

Yv *rn_decl_func_finish(Yv *node, Yv *u, Yv *fv, Yv *st) {
    return ym(2, "st", st, "node",
              ym(7, "k", ys("decl"), "kind", ym_get(node, "kind"), "name", u,
                 "typ", ym_get(node, "typ"), "v", fv, "line",
                 ym_get(node, "line"), "col", ym_get(node, "col")));
}

Yv *rn_decl_val(Yv *node, Yv *st) {
    Yv *r = rn_node(ym_get(node, "v"), st);
    return rn_decl_val_bind(node, ym_get(r, "node"), ym_get(r, "st"));
}

Yv *rn_decl_val_bind(Yv *node, Yv *v, Yv *st) {
    Yv *b = rn_bind(st, ym_get(node, "name"));
    return rn_decl_val_finish(node, v, ym_get(b, "uniq"), ym_get(b, "st"));
}

Yv *rn_decl_val_finish(Yv *node, Yv *v, Yv *uniq, Yv *st) {
    return ym(2, "st", st, "node",
              ym(7, "k", ys("decl"), "kind", ym_get(node, "kind"), "name",
                 uniq, "typ", ym_get(node, "typ"), "v", v, "line",
                 ym_get(node, "line"), "col", ym_get(node, "col")));
}

/* Rename a func value. The func VALUE (params/ptypes/ret/body) is passed
 * as FIELDS (like parse_stmt_*_go): the checker merges same-named param
 * reads across defs, so reading func.params/func.body off a shared `func`
 * name resolves against every func-shaped call site at once. Fields are
 * plain values (params/pts/ret/body passed separately — no record reads). */
Yv *rn_func(Yv *func, Yv *st) {
    /* NOTE: ONE field read per callee (see note above): rn_func_p* chain
     * threads the fields as VALUES; no body reads 2+ fields off `func`. */
    return rn_func_p1(func, ym_get(func, "params"), rn_push(st));
}

Yv *rn_func_p1(Yv *func, Yv *fparams, Yv *st) {
    return rn_func_p2(func, fparams, ym_get(func, "ptypes"), st);
}

Yv *rn_func_p2(Yv *func, Yv *fparams, Yv *fptypes, Yv *st) {
    return rn_func_p3(func, fparams, fptypes, ym_get(func, "ret"), st);
}

Yv *rn_func_p3(Yv *func, Yv *fparams, Yv *fptypes, Yv *fret, Yv *st) {
    return rn_func_p4(func, fparams, fptypes, fret, ym_get(func, "body"), st);
}

Yv *rn_func_p4(Yv *func, Yv *fparams, Yv *fptypes, Yv *fret, Yv *fbody,
               Yv *st) {
    return rn_func_p5(fparams, fptypes, fret, fbody,
                      yv_l(ym_get(func, "line")), yv_l(ym_get(func, "col")),
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
                          ya_push(params, ym_get(b, "uniq")), i + 1,
                          ym_get(b, "st"));
    }
}

Yv *rn_func_body(Yv *fptypes, Yv *fret, Yv *fbody, long fline, long fcol,
                 Yv *params, Yv *st) {
    /* NOTE: fbody read ONCE here (one read site — no merge). */
    Yv *b = rn_block(ym_get(fbody, "stmts"), st);
    return rn_func_finish(fptypes, fret, fbody, fline, fcol, params,
                          ym_get(b, "stmts"), rn_pop(ym_get(b, "st")));
}

Yv *rn_func_finish(Yv *fptypes, Yv *fret, Yv *fbody, long fline, long fcol,
                   Yv *params, Yv *stmts, Yv *st) {
    /* NOTE: NO record reads here — all values are params already.
     * (fbody is kept for 1:1 signature parity but never read, as in Y.) */
    (void)fbody;
    return ym(2, "st", st, "node",
              ym(7, "k", ys("func"), "params", params, "ptypes", fptypes,
                 "ret", fret, "body",
                 ym(4, "k", ys("block"), "stmts", stmts, "line",
                    yv_long(fline), "col", yv_long(fcol)),
                 "line", yv_long(fline), "col", yv_long(fcol)));
}

Yv *rename_program(Yv *ast) {
    return rename_program_go(ym_get(ast, "stmts"), yv_l(ym_get(ast, "line")),
                             yv_l(ym_get(ast, "col")));
}

Yv *rename_program_go(Yv *stmts, long line, long col) {
    /* NOTE: fields passed as values (see rn_func note). */
    Yv *st = ym(2, "scopes", yav(1, yav(0)), "n", yv_long(1));
    Yv *b = rn_block(stmts, st);
    return ym(4, "k", ys("block"), "stmts", ym_get(b, "stmts"), "line",
              yv_long(line), "col", yv_long(col));
}
