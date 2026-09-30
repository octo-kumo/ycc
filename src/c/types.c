/* types.c — static type checker for the native backend.
 * 1:1 port of src/y/types.y (PORTING.md is the contract).
 * Usage: Yv *errors = check_program(ast);  // [] means OK
 * Each error: { msg: str, line: long, col: long }.
 *
 * Supported types: long, bool, str, null, *T (pointers), monomorphic
 * (T, ...) -> R functions. Everything else (arrays, maps, floats,
 * first-class function values in argument position, closures over locals)
 * is rejected with a clear error, not silently miscompiled.
 *
 * Rules (native mode):
 * - def params and return types REQUIRE annotations.
 * - let/const without annotation is inferred from the initializer.
 * - Nested defs see only their own params + top-level defs + intrinsics:
 *   referring to an outer local/param is a capture error (closures are
 *   planned, not present: no heap for envs yet).
 * - `if` conditions must be bool; branches must agree; if-without-else
 *   must have a null-typed body (expression-oriented, like the VM).
 * - print takes exactly one long/bool/str. syscall takes 1-7 long/bool/str/\*T.
 * - Assignment targets keep their declared type. No implicit conversions.
 *
 * Translation conventions (see PORTING.md): records are ym() maps read
 * with ym_get; type nodes are { k: "tarr", of: ... } maps; checker state
 * st = { bindings, errors, ret, self, fdepth } and typeof_* results
 * { typ, st } are Yv * maps; long/bool scalars cross the record boundary
 * boxed with yv_long()/yv_bool() and read out with yv_l()/yv_b(). The
 * `0;` value-tails of Y if-arms are `;` here; tail values of blocks in
 * return position are `return`. */
#include "types.h"
#include "yv.h"

/* imported — types.y imports nothing: every call below is a builtin
 * (len/push/substr/index_of/join/tostring) or a def of this file. */

/* forward declarations (Y defs are mutually visible) */
static Yv *err_at(Yv *msg, long line, long col);
static Yv *t_unk(void);
static Yv *t_null(void) __attribute__((unused)); /* def kept 1:1; unused */
static int teq_fields(Yv *af, Yv *bf, long i);
static int teq_list(Yv *aa, Yv *bb, long i);
static Yv *unk_shape(void);
static int single_k(Yv *fs);
static Yv *trec_field_type(Yv *rec, Yv *key);
static Yv *tstr_go(Yv *t);
static int num_is_float(Yv *s);
static int is_value_type(Yv *t);
static Yv *lookup(Yv *bindings, Yv *name);
static Yv *st_bind(Yv *st, Yv *name, Yv *typ, Yv *kind);
static Yv *st_errors(Yv *st, Yv *errs);
static Yv *st_self(Yv *st, Yv *selfv);
static Yv *st_ret(Yv *st, Yv *ret);
static Yv *fail(Yv *st, Yv *msg, long line, long col);
static Yv *disp(Yv *name);
static Yv *check_visible(Yv *st, Yv *got, Yv *name, long line, long col);
static Yv *expect_type(Yv *st, Yv *got, Yv *want, Yv *what, long line, long col);
static Yv *typeof_arith(Yv *st, Yv *op, Yv *lt, Yv *rt, long line, long col);
static Yv *typeof_arith_arr(Yv *st, Yv *op, Yv *lt, Yv *rt, long line, long col);
/* `x :: a` -- cons: a NEW array with x prepended as exactly ONE element
 * (unlike `elem + a`, an array-typed element is never spliced). The right
 * operand must be an array; the left must be its element type. */
static Yv *typeof_cons(Yv *st, Yv *lt, Yv *rt, long line, long col) {
    if (ys_eq_lit(ym_get(rt, "k"), "tarr") ||
        ys_eq_lit(ym_get(rt, "k"), "tarrfix")) {
        st = expect_type(st, lt, ym_get(rt, "of"), ys("'::' element"), line, col);
        return ym(2, "typ", ym(2, "k", ys("tarr"), "of", ym_get(rt, "of")),
                  "st", st);
    } else {
        st = fail(st,
                  ys_cat(ys_cat(ys("'::' needs an array on the right, got "),
                                tstr(rt)),
                         ys("")),
                  line, col);
        return ym(2, "typ", t_unk(), "st", st);
    }
}

static Yv *typeof_arith_long(Yv *st, Yv *op, Yv *lt, Yv *rt, long line, long col);
static Yv *typeof_cmp(Yv *st, Yv *op, Yv *lt, Yv *rt, long line, long col);
static int is_num_kind(Yv *t);
static int num_eq_ok(Yv *lt, Yv *rt);
static Yv *typeof_eq(Yv *st, Yv *op, Yv *lt, Yv *rt, long line, long col);
static Yv *typeof_logic(Yv *st, Yv *op, Yv *lt, Yv *rt, long line, long col);
static int tcompat(Yv *got, Yv *want);
static int arr_lit_adopts(Yv *got, Yv *want);
static int arr_lit_adopts_go(Yv *got, Yv *want);
static int trec_compat(Yv *got, Yv *want);
static int trec_compat_go(Yv *gfs, Yv *wfs, long i);
static int trec_has(Yv *gfs, Yv *name, Yv *typ);
static Yv *typeof_expr(Yv *st, Yv *node);
static Yv *incdec_check(Yv *st, Yv *node, Yv *tt);
static Yv *opassign_check(Yv *st, Yv *node, Yv *tt, Yv *vt);
static Yv *typeof_call(Yv *st, Yv *node);
static Yv *typeof_block(Yv *st, Yv *node);
static Yv *typeof_decl(Yv *st, Yv *node);
static Yv *typeof_def(Yv *st, Yv *name, Yv *func, long line, long col);
static Yv *st_fdepth(Yv *st, long d);
static Yv *check_func_value(Yv *st, Yv *name, Yv *func, long line, long col) __attribute__((unused)); /* def kept 1:1; unused */
static Yv *def_sig(Yv *name, Yv *func);

static Yv *err_at(Yv *msg, long line, long col) {
    return ym(3, "msg", msg, "line", yv_long(line), "col", yv_long(col));
}

// ── types ────────────────────────────────────────────────────────────────
// Type nodes come from the parser: tlong/tbool/tstr/tnull/tnone/tname,
// tptr {to}, tarr {of}, tfunc {args, ret}, trec {fields: [{name, typ}]},
// tparams. Internal only: tunk (error poison, unifies with everything),
// trec (checked record type {fields: [{name, typ}]} — same shape as the
// parser's trec; teq/tstr compare field-by-field).

static Yv *t_unk(void) {
    return ym(1, "k", ys("tunk"));
}

static Yv *t_null(void) {
    return ym(1, "k", ys("tnull"));
}

// NOTE: no `||` (see lexer.y isalnum note): the C VM evaluates both sides
// eagerly AND the checker rejects `||` mixing map-field shapes with bools
// through one gate — and teq's OWN first line was the worst offender
// (a.k/t.k field reads poisoned through `||`). Nested ifs everywhere.
// NOTE: bind kind tags with :str (see gen_bin note in native.y):
// `a.k`/`b.k` infer tunk (bare params), which would make `!=` below
// compare string POINTERS; annotated lets force content comparison.
// Sound: kind tags are always strings (parser + checker construct
// every type node with a string k).
int teq(Yv *a, Yv *b) {
    Yv *ak = ym_get(a, "k");
    Yv *bk = ym_get(b, "k");
    if (ys_eq_lit(ak, "tunk")) {
        return 1;
    } else if (ys_eq_lit(bk, "tunk")) {
        return 1;
    } else if (!ys_eq(ak, bk)) {
        return 0;
    } else if (ys_eq_lit(ak, "tnone")) {
        return 1;
    } else if (ys_eq_lit(bk, "tnone")) {
        return 1;
    } else if (ys_eq_lit(ak, "tname")) {
        return 1;
    } else if (ys_eq_lit(bk, "tname")) {
        return 1;
    } else if (ys_eq_lit(ak, "tparams")) {
        return 1;
    } else if (ys_eq_lit(bk, "tparams")) {
        return 1;
    } else if (ys_eq_lit(ak, "tptr")) {
        return teq(ym_get(a, "to"), ym_get(b, "to"));
    } else if (ys_eq_lit(ak, "tarr")) {
        return teq(ym_get(a, "of"), ym_get(b, "of"));
    } else if (ys_eq_lit(ak, "tarrfix")) {
        if (yv_l(ym_get(a, "n")) == yv_l(ym_get(b, "n"))) {
            return teq(ym_get(a, "of"), ym_get(b, "of"));
        } else {
            return 0;
        }
    } else if (ys_eq_lit(ym_get(a, "k"), "topt")) {
        return teq(ym_get(a, "of"), ym_get(b, "of"));
    } else if (ys_eq_lit(ym_get(a, "k"), "trec")) {
        // record types: same field names in order, pairwise-equal types.
        // (tunk fields unify — error poison never cascades.)
        // A single-[k] side is the unknown-shape marker: it unifies with
        // any record (the missing annotation errors once at its own site,
        // not again at every enclosing branch — same tcompat law as the
        // dot arm). Concrete mismatches still disagree (e11/e12 parity).
        // NOTE: each bound once — `x.y[i]` chains misparse on the C VM.
        Yv *af = ym_get(a, "fields");
        Yv *bf = ym_get(b, "fields");
        if (yv_len(af) != yv_len(bf)) {
            if (single_k(af)) {
                return 1;
            } else if (single_k(bf)) {
                return 1;
            } else {
                return 0;
            }
        } else {
            int ok = 1;
            long i = 0;
            // NOTE: no `&&` (see lexer.y note): the C VM evaluates both sides
            // eagerly, so af[i] runs past the end (clamped — safe here, but
            // the checker rejects the shape); flag-form loop instead.
            while (ok) {
                if (i < yv_len(af)) {
                    // NOTE: each bound once — `x.y[i]` chains misparse on the C VM.
                    // NOTE: names bound with :str (see teq note): bare-param
                    // flows infer tunk, which would make `!=` below compare
                    // string POINTERS; annotated lets force content compare.
                    Yv *fa = ya_get(af, i);
                    Yv *fb = ya_get(bf, i);
                    Yv *an = ym_get(fa, "name");
                    Yv *bn = ym_get(fb, "name");
                    if (!ys_eq(an, bn)) {
                        ok = 0;
                    } else {
                        ok = teq(ym_get(fa, "typ"), ym_get(fb, "typ"));
                    }
                    i = i + 1;
                    ;
                } else {
                    ok = 0;
                    ;
                }
                ;
            }
            // hmm — the loop above exits via ok=false BOTH on mismatch and on
            // exhaustion; recompute properly below (flag pair, no `&&`).
            return teq_fields(af, bf, 0);
        }
    } else if (ys_eq_lit(ak, "tfunc")) {
        if (yv_len(ym_get(a, "args")) != yv_len(ym_get(b, "args"))) {
            return 0;
        } else {
            int ok = teq(ym_get(a, "ret"), ym_get(b, "ret"));
            Yv *aa = ym_get(a, "args");
            Yv *bb = ym_get(b, "args");
            long i = 0;
            while (ok) {
                if (i < yv_len(aa)) {
                    ok = teq(ya_get(aa, i), ya_get(bb, i));
                    i = i + 1;
                    ;
                } else {
                    ok = 0;
                    ;
                }
                ;
            }
            return teq_list(aa, bb, 0);
        }
    } else {
        return 1;
    }
}

// Pairwise teq over record-field lists / type lists (index recursion keeps
// the loop-guard shapes checker-clean: no `&&`, no eager-OOB indexing).
static int teq_fields(Yv *af, Yv *bf, long i) {
    if (i >= yv_len(af)) {
        return 1;
    } else {
        Yv *fa = ya_get(af, i);
        Yv *fb = ya_get(bf, i);
        // NOTE: :str bindings (see teq note): fa/fb flow from bare params
        // (tunk), so a direct `!=` would compare string POINTERS.
        Yv *an = ym_get(fa, "name");
        Yv *bn = ym_get(fb, "name");
        if (!ys_eq(an, bn)) {
            return 0;
        } else if (teq(ym_get(fa, "typ"), ym_get(fb, "typ"))) {
            return teq_fields(af, bf, i + 1);
        } else {
            return 0;
        }
    }
}

static int teq_list(Yv *aa, Yv *bb, long i) {
    if (i >= yv_len(aa)) {
        return 1;
    } else if (teq(ya_get(aa, i), ya_get(bb, i))) {
        return teq_list(aa, bb, i + 1);
    } else {
        return 0;
    }
}

// The unknown-shape marker as a value: the internal shape of a {k: str}
// annotation (cf. parser.y trec construction). Used to probe whether a
// subject type is unknown-shaped (single-[k]) without reading fields that
// might not exist (reading them IS the error). Concrete singletons
// ({x: long}) do NOT match (name differs) and stay strict (e11 parity).
static Yv *unk_shape(void) {
    return ym(2, "k", ys("trec"),
              "fields", yav(1, ym(2, "name", ys("k"), "typ", ym(1, "k", ys("tstr")))));
}

// Single-[k] field list test for teq's trec arm (operates on real field
// arrays threaded through bare params — reads stay quiet statically and
// exact at runtime).
static int single_k(Yv *fs) {
    if (yv_len(fs) != 1) {
        return 0;
    } else {
        return ys_eq_lit(ym_get(ya_get(fs, 0), "name"), "k");
    }
}

// Field type by name in a trec; tnone marker when missing (dotassign uses
// it — the caller reports the error once at the assignment site).
static Yv *trec_field_type(Yv *rec, Yv *key) {
    Yv *found = ym(1, "k", ys("tnone"));
    if (ys_eq_lit(ym_get(rec, "k"), "trec")) {
        Yv *fs = ym_get(rec, "fields");
        long i = 0;
        while (i < yv_len(fs)) {
            Yv *f = ya_get(fs, i);
            if (ys_eq(ym_get(f, "name"), key)) {
                found = ym_get(f, "typ");
                ;
            } else {
                ;
            }
            i = i + 1;
        }
    }
    return found;
}

static Yv *tstr_go(Yv *t) {
    if (ys_eq_lit(ym_get(t, "k"), "tlong")) {
        return ys("long");
    } else if (ys_eq_lit(ym_get(t, "k"), "tbyte")) {
        return ys("byte");
    } else if (ys_eq_lit(ym_get(t, "k"), "tfloat")) {
        return ys("float");
    } else if (ys_eq_lit(ym_get(t, "k"), "tbool")) {
        return ys("bool");
    } else if (ys_eq_lit(ym_get(t, "k"), "tstr")) {
        return ys("str");
    } else if (ys_eq_lit(ym_get(t, "k"), "tnull")) {
        return ys("null");
    } else if (ys_eq_lit(ym_get(t, "k"), "tvoid")) {
        return ys("void");
    } else if (ys_eq_lit(ym_get(t, "k"), "tunk")) {
        return ys("<error>");
    } else if (ys_eq_lit(ym_get(t, "k"), "tnone")) {
        return ys("<missing annotation>");
    } else if (ys_eq_lit(ym_get(t, "k"), "tname")) {
        return ym_get(t, "name");
    } else if (ys_eq_lit(ym_get(t, "k"), "tptr")) {
        return ys_cat(ys("*"), tstr_go(ym_get(t, "to")));
    } else if (ys_eq_lit(ym_get(t, "k"), "tarr")) {
        return ys_cat(ys_cat(ys("["), tstr_go(ym_get(t, "of"))), ys("]"));
    } else if (ys_eq_lit(ym_get(t, "k"), "tarrfix")) {
        return ys_cat(ys_cat(ys_cat(ys_cat(ys("["), tstr_go(ym_get(t, "of"))),
                                    ys("; ")),
                          ys_tostring(ym_get(t, "n"))),
                    ys("]"));
    } else if (ys_eq_lit(ym_get(t, "k"), "topt")) {
        return ys_cat(tstr_go(ym_get(t, "of")), ys("?"));
    } else if (ys_eq_lit(ym_get(t, "k"), "trec")) {
        Yv *parts = yav(0);
        Yv *fs = ym_get(t, "fields");
        long i = 0;
        while (i < yv_len(fs)) {
            // NOTE: bound once — `x.y[i]` chains misparse on the C VM.
            Yv *f = ya_get(fs, i);
            parts = ya_push(parts, ys_cat(ys_cat(ym_get(f, "name"), ys(": ")),
                                          tstr_go(ym_get(f, "typ"))));
            i = i + 1;
        }
        return ys_cat(ys_cat(ys("{ "), ys_join(parts, ys(", "))), ys(" }"));
    } else if (ys_eq_lit(ym_get(t, "k"), "tfunc")) {
        Yv *parts = yav(0);
        Yv *ta = ym_get(t, "args");
        long i = 0;
        while (i < yv_len(ta)) {
            parts = ya_push(parts, tstr_go(ya_get(ta, i)));
            i = i + 1;
        }
        return ys_cat(ys_cat(ys_cat(ys("("), ys_join(parts, ys(", "))),
                             ys(") -> ")),
                      tstr_go(ym_get(t, "ret")));
    } else {
        return ys_cat(ys_cat(ys("<"), ym_get(t, "k")), ys(">"));
    }
}

Yv *tstr(Yv *t) {
    return tstr_go(t);
}

// A numeric literal denotes a float when it has a fraction or an exponent.
// Radix literals are checked first: 0xE1 and 0xbeef contain 'e'/'E'/'b'.
// (native.y keeps its own copy — the two modules never share helpers.)
static int num_is_float(Yv *s) {
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

// User-visible rendering (typeof / print of a function or record value).
// Matches the C VM's type_t_to_buf byte for byte for the types both
// engines have, so `typeof(x)` reads the same under either backend.
// tstr() stays as it is: compiler diagnostics (and the tests that match
// on them) use the roomier spacing.
Yv *tdisp(Yv *t) {
    if (ys_eq_lit(ym_get(t, "k"), "trec")) {
        Yv *parts = yav(0);
        Yv *fs = ym_get(t, "fields");
        long i = 0;
        while (i < yv_len(fs)) {
            Yv *f = ya_get(fs, i);
            parts = ya_push(parts, ys_cat(ys_cat(ym_get(f, "name"), ys(": ")),
                                          tdisp(ym_get(f, "typ"))));
            i = i + 1;
        }
        return ys_cat(ys_cat(ys("{"), ys_join(parts, ys(", "))), ys("}"));
    } else if (ys_eq_lit(ym_get(t, "k"), "tfunc")) {
        Yv *parts = yav(0);
        Yv *ta = ym_get(t, "args");
        long i = 0;
        while (i < yv_len(ta)) {
            parts = ya_push(parts, tdisp(ya_get(ta, i)));
            i = i + 1;
        }
        return ys_cat(ys_cat(ys_cat(ys("("), ys_join(parts, ys(", "))),
                             ys(")->")),
                      tdisp(ym_get(t, "ret")));
    } else if (ys_eq_lit(ym_get(t, "k"), "tarr")) {
        return ys_cat(ys_cat(ys("["), tdisp(ym_get(t, "of"))), ys("]"));
    } else if (ys_eq_lit(ym_get(t, "k"), "tarrfix")) {
        return ys_cat(ys_cat(ys_cat(ys_cat(ys("["), tdisp(ym_get(t, "of"))),
                                    ys("; ")),
                          ys_tostring(ym_get(t, "n"))),
                    ys("]"));
    } else if (ys_eq_lit(ym_get(t, "k"), "tptr")) {
        return ys_cat(ys("*"), tdisp(ym_get(t, "to")));
    } else if (ys_eq_lit(ym_get(t, "k"), "topt")) {
        return ys_cat(tdisp(ym_get(t, "of")), ys("?"));
    } else {
        return tstr_go(t);
    }
}

// A type is "first-class storable but not yet callable through": function
// values may live in let-bindings and be called directly, never passed around.
// NOTE: nested ifs, not `||` chains (see lexer.y isalnum note): the C VM
// evaluates both sides eagerly AND the checker rejects `||` mixing
// map-field shapes through the same gate.
// Merge one field into a record literal's field list. A later entry wins
// the value (and its type); the first appearance keeps the position. That
// is the static union rule for `{a: 1, ...obj}`: obj may overwrite a, and
// a later explicit key may overwrite what obj spread.
Yv *field_merge(Yv *fields, Yv *name, Yv *typ) {
    Yv *out = yav(0);
    long i = 0;
    int seen = 0;
    while (i < yv_len(fields)) {
        Yv *f = ya_get(fields, i);
        Yv *fnm = ym_get(f, "name");
        if (ys_eq(fnm, name)) {
            if (seen) {
                ;
            } else {
                out = ya_push(out, ym(2, "name", name, "typ", typ));
                seen = 1;
                ;
            }
            ;
        } else {
            out = ya_push(out, f);
            ;
        }
        i = i + 1;
    }
    if (seen) {
        ;
    } else {
        out = ya_push(out, ym(2, "name", name, "typ", typ));
        ;
    }
    return out;
}

static int is_value_type(Yv *t) {
    if (ys_eq_lit(ym_get(t, "k"), "tlong")) {
        return 1;
    } else if (ys_eq_lit(ym_get(t, "k"), "tbyte")) {
        return 1;
    } else if (ys_eq_lit(ym_get(t, "k"), "tfloat")) {
        return 1;
    } else if (ys_eq_lit(ym_get(t, "k"), "tbool")) {
        return 1;
    } else if (ys_eq_lit(ym_get(t, "k"), "tstr")) {
        return 1;
    } else if (ys_eq_lit(ym_get(t, "k"), "tnull")) {
        return 1;
    } else if (ys_eq_lit(ym_get(t, "k"), "tptr")) {
        return 1;
    } else if (ys_eq_lit(ym_get(t, "k"), "tunk")) {
        return 1;
    } else if (ys_eq_lit(ym_get(t, "k"), "tnone")) {
        return 1;
    } else if (ys_eq_lit(ym_get(t, "k"), "tname")) {
        return 1;
    } else if (ys_eq_lit(ym_get(t, "k"), "tparams")) {
        return 1;
    } else if (ys_eq_lit(ym_get(t, "k"), "tfunc")) {
        return 1;
    } else if (ys_eq_lit(ym_get(t, "k"), "tarr")) {
        return 1;
    } else if (ys_eq_lit(ym_get(t, "k"), "tarrfix")) {
        return 1;
    } else if (ys_eq_lit(ym_get(t, "k"), "topt")) {
        return 1;
    } else {
        return ys_eq_lit(ym_get(t, "k"), "trec");
    }
}

// A function VALUE prints as `<function (params)->(ret)>` — note the extra
// parens around the return type, which is how the C VM renders it.
Yv *tdisp_fnval(Yv *t) {
    Yv *parts = yav(0);
    Yv *ta = ym_get(t, "args");
    long i = 0;
    while (i < yv_len(ta)) {
        parts = ya_push(parts, tdisp(ya_get(ta, i)));
        i = i + 1;
    }
    return ys_cat(ys_cat(ys_cat(ys_cat(ys("("), ys_join(parts, ys(", "))),
                                 ys(")->(")),
                          tdisp(ym_get(t, "ret"))),
                  ys(")"));
}

// ── checker state ────────────────────────────────────────────────────────
// No scopes: rename.y gave every binding a unique name, so one flat list
// suffices. bindings = [{name, typ, kind, fdepth}] (fdepth = function-nesting
// depth where bound; top level = 0). kind: "local" | "param" | "func"
// (any def) | "intrinsic". A local/param is visible only at its own fdepth —
// anything else is a capture (closures need heap envs — planned).

static Yv *lookup(Yv *bindings, Yv *name) {
    long i = 0;
    // NOTE: NO shared `found` hole rebound across arms (see parser.y
    // parse_type_node note): the env keeps ONE shape per name, so a hole
    // rebound to e.typ then read as e.kind would resolve `kind` against the
    // TYPE shape. found* snapshots are bound once in their own arms.
    Yv *found_typ = ym(1, "k", ys("tnone"));
    Yv *found_kind = ys("");
    long found_fd = 0;
    while (i < yv_len(bindings)) {
        Yv *e = ya_get(bindings, i);
        if (ys_eq(ym_get(e, "name"), name)) {
            found_typ = ym_get(e, "typ");
            found_kind = ym_get(e, "kind");
            found_fd = yv_l(ym_get(e, "fdepth"));
            ;
        } else {
            ;
        }
        i = i + 1;
        ;
    }
    return ym(3, "typ", found_typ, "kind", found_kind, "fdepth",
              yv_long(found_fd));
}

static Yv *st_bind(Yv *st, Yv *name, Yv *typ, Yv *kind) {
    Yv *bindings = ya_push(ym_get(st, "bindings"),
                           ym(4, "name", name, "typ", typ, "kind", kind,
                              "fdepth", yv_long(yv_l(ym_get(st, "fdepth")))));
    return ym(5, "bindings", bindings, "errors", ym_get(st, "errors"),
              "ret", ym_get(st, "ret"), "self", ym_get(st, "self"),
              "fdepth", yv_long(yv_l(ym_get(st, "fdepth"))));
}

// ── the checker ──────────────────────────────────────────────────────────
// Threaded state st = { bindings, errors, ret, self, fdepth }.
// typeof_* returns { typ, st }.

// The C compiler's parser has no dot-assign (`st.errors = ...`), so state
// updates are explicit map rebuilds (same style as the rest of ycc).
static Yv *st_errors(Yv *st, Yv *errs) {
    return ym(5, "bindings", ym_get(st, "bindings"), "errors", errs,
              "ret", ym_get(st, "ret"), "self", ym_get(st, "self"),
              "fdepth", yv_long(yv_l(ym_get(st, "fdepth"))));
}

// NOTE: the parameter is NOT named `self`: the C VM binds `self` to the
// enclosing function in every scope, which would shadow it.
static Yv *st_self(Yv *st, Yv *selfv) {
    return ym(5, "bindings", ym_get(st, "bindings"), "errors", ym_get(st, "errors"),
              "ret", ym_get(st, "ret"), "self", selfv,
              "fdepth", yv_long(yv_l(ym_get(st, "fdepth"))));
}

static Yv *st_ret(Yv *st, Yv *ret) {
    return ym(5, "bindings", ym_get(st, "bindings"), "errors", ym_get(st, "errors"),
              "ret", ret, "self", ym_get(st, "self"),
              "fdepth", yv_long(yv_l(ym_get(st, "fdepth"))));
}

static Yv *fail(Yv *st, Yv *msg, long line, long col) {
    return st_errors(st, ya_push(ym_get(st, "errors"), err_at(msg, line, col)));
}

// Display name: strip the rename pass's `$N` suffix so errors read like
// the user's source (`$` is lexer-illegal, so it can only come from rename).
static Yv *disp(Yv *name) {
    long i = ys_index_of(name, ys("$"));
    if (i < 0) {
        return name;
    } else {
        return ys_substr(name, 0, i);
    }
}

// A local/param binding from an enclosing function is a CAPTURE. Captures
// are legal now: the emitter closure-converts the function, copying each
// captured value into a heap closure record. (Captured values are copied
// at closure-creation time, so a closure sees the value as it was then.)
static Yv *check_visible(Yv *st, Yv *got, Yv *name, long line, long col) {
    __attribute__((unused)) Yv *unused = name;
    __attribute__((unused)) long unused2 = line;
    __attribute__((unused)) long unused3 = col;
    __attribute__((unused)) Yv *unused4 = got;
    return st;
}

static Yv *expect_type(Yv *st, Yv *got, Yv *want, Yv *what, long line, long col) {
    if (tcompat(got, want)) {
        return st;
    } else {
        return fail(st, ys_cat(ys_cat(ys_cat(ys_cat(what, ys(": expected ")),
                                            tstr(want)),
                                      ys(", got ")),
                               tstr(got)),
                    line, col);
    }
}

// Binary-operator result typing, split out so the `bin` arm needs no `||`
// chains at all (see lexer.y isalnum note).
static Yv *typeof_arith(Yv *st, Yv *op, Yv *lt, Yv *rt, long line, long col) {
    // "+" on strings concatenates (either side may be poison tunk, but at
    // least one side must be a real str — nested ifs, no `&&`/`||`).
    // AUTO-STRINGIFY: str + long/bool (and the mirror) stringify the
    // number and concat — same semantics as the C runtime's y_add.
    if (ys_eq_lit(op, "+")) {
        // Arrays win over strings (the VM's O_ADD order): arr + arr
        // concatenates into a NEW array, arr + elem appends one (same type
        // only), elem + arr prepends one. In-place forms are `+=` / `*=`.
        if (ys_eq_lit(ym_get(lt, "k"), "tarr") ||
            ys_eq_lit(ym_get(lt, "k"), "tarrfix")) {
            return typeof_arith_arr(st, op, lt, rt, line, col);
        } else if (ys_eq_lit(ym_get(rt, "k"), "tarr") ||
                   ys_eq_lit(ym_get(rt, "k"), "tarrfix")) {
            return typeof_arith_arr(st, op, lt, rt, line, col);
        } else if (ys_eq_lit(ym_get(lt, "k"), "tstr")) {
            if (ys_eq_lit(ym_get(rt, "k"), "tstr")) {
                return ym(2, "typ", ym(1, "k", ys("tstr")), "st", st);
            } else if (ys_eq_lit(ym_get(rt, "k"), "tunk")) {
                return ym(2, "typ", ym(1, "k", ys("tstr")), "st", st);
            } else if (ys_eq_lit(ym_get(rt, "k"), "tlong")) {
                return ym(2, "typ", ym(1, "k", ys("tstr")), "st", st);
            } else if (ys_eq_lit(ym_get(rt, "k"), "tbyte")) {
                return ym(2, "typ", ym(1, "k", ys("tstr")), "st", st);
            } else if (ys_eq_lit(ym_get(rt, "k"), "tfloat")) {
                return ym(2, "typ", ym(1, "k", ys("tstr")), "st", st);
            } else if (ys_eq_lit(ym_get(rt, "k"), "tbool")) {
                return ym(2, "typ", ym(1, "k", ys("tstr")), "st", st);
            } else {
                return typeof_arith_long(st, op, lt, rt, line, col);
            }
        } else if (ys_eq_lit(ym_get(lt, "k"), "tunk")) {
            if (ys_eq_lit(ym_get(rt, "k"), "tstr")) {
                return ym(2, "typ", ym(1, "k", ys("tstr")), "st", st);
            } else {
                return typeof_arith_long(st, op, lt, rt, line, col);
            }
        } else if (ys_eq_lit(ym_get(lt, "k"), "tlong")) {
            if (ys_eq_lit(ym_get(rt, "k"), "tstr")) {
                return ym(2, "typ", ym(1, "k", ys("tstr")), "st", st);
            } else {
                return typeof_arith_long(st, op, lt, rt, line, col);
            }
        } else if (ys_eq_lit(ym_get(lt, "k"), "tbyte")) {
            if (ys_eq_lit(ym_get(rt, "k"), "tstr")) {
                return ym(2, "typ", ym(1, "k", ys("tstr")), "st", st);
            } else {
                return typeof_arith_long(st, op, lt, rt, line, col);
            }
        } else if (ys_eq_lit(ym_get(lt, "k"), "tfloat")) {
            if (ys_eq_lit(ym_get(rt, "k"), "tstr")) {
                return ym(2, "typ", ym(1, "k", ys("tstr")), "st", st);
            } else {
                return typeof_arith_long(st, op, lt, rt, line, col);
            }
        } else if (ys_eq_lit(ym_get(lt, "k"), "tbool")) {
            if (ys_eq_lit(ym_get(rt, "k"), "tstr")) {
                return ym(2, "typ", ym(1, "k", ys("tstr")), "st", st);
            } else {
                return typeof_arith_long(st, op, lt, rt, line, col);
            }
        } else {
            return typeof_arith_long(st, op, lt, rt, line, col);
        }
    } else {
        return typeof_arith_long(st, op, lt, rt, line, col);
    }
}

static Yv *typeof_arith_arr(Yv *st, Yv *op, Yv *lt, Yv *rt, long line, long col) {
    // The array operand decides the result type. Two arrays CONCATENATE
    // (each side's elements are spliced in, so the ELEMENT types must
    // match — arrays are homogeneous by design); a non-array operand is
    // ONE element of the array's element type.
    Yv *lk = ym_get(lt, "k");
    if (!ys_eq_lit(op, "+")) {
        st = fail(st, ys_cat(ys_cat(ys("'"), op),
                             ys("' is not defined on arrays (only '+' copies, '+='/'*=' mutate)")),
                  line, col);
        return ym(2, "typ", t_unk(), "st", st);
    } else if (ys_eq_lit(lk, "tarr") || ys_eq_lit(lk, "tarrfix")) {
        if (ys_eq_lit(ym_get(rt, "k"), "tarr") ||
            ys_eq_lit(ym_get(rt, "k"), "tarrfix")) {
            st = expect_type(st, ym_get(rt, "of"), ym_get(lt, "of"),
                             ys("'+' concatenated elements"), line, col);
            return ym(2, "typ", ym(2, "k", ys("tarr"), "of", ym_get(lt, "of")),
                      "st", st);
        } else {
            st = expect_type(st, rt, ym_get(lt, "of"), ys("'+' element"), line,
                             col);
            return ym(2, "typ", ym(2, "k", ys("tarr"), "of", ym_get(lt, "of")),
                      "st", st);
        }
    } else {
        st = expect_type(st, lt, ym_get(rt, "of"), ys("'+' element"), line, col);
        return ym(2, "typ", ym(2, "k", ys("tarr"), "of", ym_get(rt, "of")), "st",
                  st);
    }
}

static Yv *typeof_arith_long(Yv *st, Yv *op, Yv *lt, Yv *rt, long line,
                             long col) {
    // Numeric arithmetic. If either side is a float the result is a float
    // and the other side widens (long -> float, the only coercion).
    if (ys_eq_lit(ym_get(lt, "k"), "tfloat") ||
        ys_eq_lit(ym_get(rt, "k"), "tfloat")) {
        st = expect_type(st, lt, ym(1, "k", ys("tfloat")),
                         ys_cat(ys_cat(ys("'"), op), ys("' left operand")), line,
                         col);
        st = expect_type(st, rt, ym(1, "k", ys("tfloat")),
                         ys_cat(ys_cat(ys("'"), op), ys("' right operand")),
                         line, col);
        return ym(2, "typ", ym(1, "k", ys("tfloat")), "st", st);
    } else {
        st = expect_type(st, lt, ym(1, "k", ys("tlong")),
                         ys_cat(ys_cat(ys("'"), op), ys("' left operand")), line,
                         col);
        st = expect_type(st, rt, ym(1, "k", ys("tlong")),
                         ys_cat(ys_cat(ys("'"), op), ys("' right operand")),
                         line, col);
        return ym(2, "typ", ym(1, "k", ys("tlong")), "st", st);
    }
}

static Yv *typeof_cmp(Yv *st, Yv *op, Yv *lt, Yv *rt, long line, long col) {
    if (ys_eq_lit(ym_get(lt, "k"), "tstr")) {
        // str < str is lexicographic ordering (byte by byte), matching the
        // VM and the compiled C runtime.
        st = expect_type(st, rt, ym(1, "k", ys("tstr")),
                         ys_cat(ys_cat(ys("'"), op), ys("' right operand")),
                         line, col);
        return ym(2, "typ", ym(1, "k", ys("tbool")), "st", st);
    } else if (ys_eq_lit(ym_get(lt, "k"), "tfloat") ||
               ys_eq_lit(ym_get(rt, "k"), "tfloat")) {
        st = expect_type(st, lt, ym(1, "k", ys("tfloat")),
                         ys_cat(ys_cat(ys("'"), op), ys("' left operand")), line,
                         col);
        st = expect_type(st, rt, ym(1, "k", ys("tfloat")),
                         ys_cat(ys_cat(ys("'"), op), ys("' right operand")),
                         line, col);
        return ym(2, "typ", ym(1, "k", ys("tbool")), "st", st);
    } else {
        st = expect_type(st, lt, ym(1, "k", ys("tlong")),
                         ys_cat(ys_cat(ys("'"), op), ys("' left operand")), line,
                         col);
        st = expect_type(st, rt, ym(1, "k", ys("tlong")),
                         ys_cat(ys_cat(ys("'"), op), ys("' right operand")),
                         line, col);
        return ym(2, "typ", ym(1, "k", ys("tbool")), "st", st);
    }
}

// Both sides numeric (long/byte/float): `==` and `!=` compare by value
// across widths, matching how the C engines treat these.
static int is_num_kind(Yv *t) {
    if (ys_eq_lit(ym_get(t, "k"), "tlong")) {
        return 1;
    } else if (ys_eq_lit(ym_get(t, "k"), "tbyte")) {
        return 1;
    } else if (ys_eq_lit(ym_get(t, "k"), "tfloat")) {
        return 1;
    } else {
        return 0;
    }
}

static int num_eq_ok(Yv *lt, Yv *rt) {
    if (is_num_kind(lt)) {
        return is_num_kind(rt);
    } else {
        return 0;
    }
}

static Yv *typeof_eq(Yv *st, Yv *op, Yv *lt, Yv *rt, long line, long col) {
    // str compares by content (null-safe: str vs null is allowed).
    // Nested ifs throughout (see lexer.y isalnum note).
    if (teq(lt, rt)) {
        return ym(2, "typ", ym(1, "k", ys("tbool")), "st", st);
    } else if (num_eq_ok(lt, rt)) {
        // Numeric kinds compare across widths: a byte IS a small long, so
        // `c == 10` needs no cast (and long/float already coerce in `<`).
        return ym(2, "typ", ym(1, "k", ys("tbool")), "st", st);
    } else if (ys_eq_lit(ym_get(lt, "k"), "tstr")) {
        if (ys_eq_lit(ym_get(rt, "k"), "tstr")) {
            return ym(2, "typ", ym(1, "k", ys("tbool")), "st", st);
        } else if (ys_eq_lit(ym_get(rt, "k"), "tunk")) {
            return ym(2, "typ", ym(1, "k", ys("tbool")), "st", st);
        } else if (ys_eq_lit(ym_get(rt, "k"), "tnull")) {
            return ym(2, "typ", ym(1, "k", ys("tbool")), "st", st);
        } else {
            st = fail(st, ys_cat(ys_cat(ys_cat(ys_cat(ys_cat(ys("'"), op),
                                                       ys("' compares ")),
                                              tstr(lt)),
                                        ys(" with ")),
                                 tstr(rt)),
                      line, col);
            return ym(2, "typ", ym(1, "k", ys("tbool")), "st", st);
        }
    } else if (ys_eq_lit(ym_get(lt, "k"), "tunk")) {
        return ym(2, "typ", ym(1, "k", ys("tbool")), "st", st);
    } else if (ys_eq_lit(ym_get(lt, "k"), "tnull")) {
        if (ys_eq_lit(ym_get(rt, "k"), "tstr")) {
            return ym(2, "typ", ym(1, "k", ys("tbool")), "st", st);
        } else {
            st = fail(st, ys_cat(ys_cat(ys_cat(ys_cat(ys_cat(ys("'"), op),
                                                       ys("' compares ")),
                                              tstr(lt)),
                                        ys(" with ")),
                                 tstr(rt)),
                      line, col);
            return ym(2, "typ", ym(1, "k", ys("tbool")), "st", st);
        }
    } else if (ys_eq_lit(ym_get(lt, "k"), "topt")) {
        // options null-check (`x == null`) plus same-option comparison.
        // Anything else is a type error (t10 parity for non-options).
        if (ys_eq_lit(ym_get(rt, "k"), "tnull")) {
            return ym(2, "typ", ym(1, "k", ys("tbool")), "st", st);
        } else if (ys_eq_lit(ym_get(rt, "k"), "tunk")) {
            return ym(2, "typ", ym(1, "k", ys("tbool")), "st", st);
        } else if (teq(lt, rt)) {
            return ym(2, "typ", ym(1, "k", ys("tbool")), "st", st);
        } else {
            st = fail(st, ys_cat(ys_cat(ys_cat(ys_cat(ys_cat(ys("'"), op),
                                                       ys("' compares ")),
                                              tstr(lt)),
                                        ys(" with ")),
                                 tstr(rt)),
                      line, col);
            return ym(2, "typ", ym(1, "k", ys("tbool")), "st", st);
        }
    } else if (ys_eq_lit(ym_get(rt, "k"), "topt")) {
        if (ys_eq_lit(ym_get(lt, "k"), "tnull")) {
            return ym(2, "typ", ym(1, "k", ys("tbool")), "st", st);
        } else if (ys_eq_lit(ym_get(lt, "k"), "tunk")) {
            return ym(2, "typ", ym(1, "k", ys("tbool")), "st", st);
        } else {
            st = fail(st, ys_cat(ys_cat(ys_cat(ys_cat(ys_cat(ys("'"), op),
                                                       ys("' compares ")),
                                              tstr(lt)),
                                        ys(" with ")),
                                 tstr(rt)),
                      line, col);
            return ym(2, "typ", ym(1, "k", ys("tbool")), "st", st);
        }
    } else {
        st = fail(st, ys_cat(ys_cat(ys_cat(ys_cat(ys_cat(ys("'"), op),
                                                   ys("' compares ")),
                                          tstr(lt)),
                                    ys(" with ")),
                             tstr(rt)),
                  line, col);
        return ym(2, "typ", ym(1, "k", ys("tbool")), "st", st);
    }
}

static Yv *typeof_logic(Yv *st, Yv *op __attribute__((unused)),
                        Yv *lt __attribute__((unused)),
                        Yv *rt __attribute__((unused)),
                        long line __attribute__((unused)),
                        long col __attribute__((unused))) {
    // Truthiness: any 8-byte value decides (nonzero = true), like the C
    // runtime. The result is always a bool; operands keep their own types.
    return ym(2, "typ", ym(1, "k", ys("tbool")), "st", st);
}

// Compatibility (stricter than equality): a `str` value IS a NUL-terminated
// address at runtime, so it flows into `*T` positions (explicit lengths come
// from the caller; byte-level access is future work). Everything else must
// match exactly — no other implicit conversions. Used for annotations,
// assignments, arguments and returns. Branch agreement (if/else) and ==/!=
// keep using strict teq.
// NOTE: unannotated shapes (tnone/tname from missing annotations) unify
// with anything HERE so one root cause yields one error at its site
// (the missing-annotation error), not a cascade at every use.
// NOTE: trec shapes unify STRUCTURALLY here (superset accepts subset —
// extra fields are ignored by the C backend AND by native codegen, which
// reads static indexes): parser.y's {k}-annotated node params accept call,
// index, dot, map, func literals without a cascade at every res() site.
// Branch agreement and ==/!= keep strict teq (e11/e12 parity).
static int tcompat(Yv *got, Yv *want) {
    if (teq(got, want)) {
        return 1;
    } else if (ys_eq_lit(ym_get(got, "k"), "tnone")) {
        return 1;
    } else if (ys_eq_lit(ym_get(want, "k"), "tnone")) {
        return 1;
    } else if (ys_eq_lit(ym_get(got, "k"), "tname")) {
        return 1;
    } else if (ys_eq_lit(ym_get(want, "k"), "tname")) {
        return 1;
    } else if (ys_eq_lit(ym_get(got, "k"), "tparams")) {
        return 1;
    } else if (ys_eq_lit(ym_get(want, "k"), "tparams")) {
        return 1;
    } else if (ys_eq_lit(ym_get(want, "k"), "topt")) {
        // The empty value widens to any T?; a plain T does NOT -- use
        // some(v), which is the explicit box (options are 0-or-box, so
        // some(0) differs from null). Option-to-option unifies payloads.
        if (ys_eq_lit(ym_get(got, "k"), "tnull")) {
            return 1;
        } else if (ys_eq_lit(ym_get(got, "k"), "topt")) {
            return teq(ym_get(got, "of"), ym_get(want, "of"));
        } else {
            return 0;
        }
    } else if (ys_eq_lit(ym_get(got, "k"), "trec")) {
        if (ys_eq_lit(ym_get(want, "k"), "trec")) {
            return trec_compat(got, want);
        } else {
            return 0;
        }
    } else if (ys_eq_lit(ym_get(want, "k"), "trec")) {
        // GOT is a bare {k}-shaped node (e.g. parser.y's res() param flows a
        // call/index/dot/map/func literal into a {k:str} slot): accept — the
        // specific literal shape is validated at its own construction site.
        if (ys_eq_lit(ym_get(got, "k"), "tstr")) {
            return 0;
        } else {
            return 1;
        }
    } else if (ys_eq_lit(ym_get(got, "k"), "tstr")) {
        if (ys_eq_lit(ym_get(want, "k"), "tptr")) {
            return 1;
        } else {
            return 0;
        }
    } else if (ys_eq_lit(ym_get(got, "k"), "tlong")) {
        // long widens to float (the only numeric coercion, matching the
        // C engines: `2.0 * i` and `x + 1` with a float x).
        // long also narrows to byte: there is no cast syntax, so an
        // annotated position is the only place the intent can be stated
        // (`let b: byte = 65`, `push(bs, n)`, a byte-typed parameter).
        // The value is masked to 8 bits where it is stored.
        if (ys_eq_lit(ym_get(want, "k"), "tfloat")) {
            return 1;
        } else if (ys_eq_lit(ym_get(want, "k"), "tbyte")) {
            return 1;
        } else {
            return 0;
        }
    } else if (ys_eq_lit(ym_get(got, "k"), "tbyte")) {
        // byte widens to long (and on to float) — it is an 8-bit unsigned
        // integer, so every value is representable.
        if (ys_eq_lit(ym_get(want, "k"), "tlong")) {
            return 1;
        } else if (ys_eq_lit(ym_get(want, "k"), "tfloat")) {
            return 1;
        } else {
            return 0;
        }
    } else {
        return 0;
    }
}

// An array/[v; n] LITERAL may adopt a narrower annotated element type
// (`let b: [byte] = [104, 105]`). Restricted to literals on purpose: the
// layouts differ (packed vs one word each), so reinterpreting an existing
// array would be a type pun.
static int arr_lit_adopts(Yv *got, Yv *want) {
    if (ys_eq_lit(ym_get(got, "k"), "tarr")) {
        return arr_lit_adopts_go(got, want);
    } else if (ys_eq_lit(ym_get(got, "k"), "tarrfix")) {
        return arr_lit_adopts_go(got, want);
    } else {
        return 0;
    }
}

static int arr_lit_adopts_go(Yv *got, Yv *want) {
    if (ys_eq_lit(ym_get(want, "k"), "tarr")) {
        return tcompat(ym_get(got, "of"), ym_get(want, "of"));
    } else if (ys_eq_lit(ym_get(want, "k"), "tarrfix")) {
        if (ys_eq_lit(ym_get(got, "k"), "tarrfix")) {
            if (yv_l(ym_get(got, "n")) == yv_l(ym_get(want, "n"))) {
                return tcompat(ym_get(got, "of"), ym_get(want, "of"));
            } else {
                return 0;
            }
        } else {
            return tcompat(ym_get(got, "of"), ym_get(want, "of"));
        }
    } else {
        return 0;
    }
}

// Every field WANT declares must exist in GOT with a compatible type;
// extra GOT fields are fine (structurally ignored downstream).
static int trec_compat(Yv *got, Yv *want) {
    Yv *wfs = ym_get(want, "fields");
    Yv *gfs = ym_get(got, "fields");
    return trec_compat_go(gfs, wfs, 0);
}

static int trec_compat_go(Yv *gfs, Yv *wfs, long i) {
    if (i >= yv_len(wfs)) {
        return 1;
    } else {
        Yv *wf = ya_get(wfs, i);
        if (trec_has(gfs, ym_get(wf, "name"), ym_get(wf, "typ"))) {
            return trec_compat_go(gfs, wfs, i + 1);
        } else {
            return 0;
        }
    }
}

static int trec_has(Yv *gfs, Yv *name, Yv *typ) {
    long i = 0;
    int found = 0;
    while (i < yv_len(gfs)) {
        Yv *gf = ya_get(gfs, i);
        if (ys_eq(ym_get(gf, "name"), name)) {
            if (tcompat(ym_get(gf, "typ"), typ)) {
                found = 1;
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

static Yv *typeof_expr(Yv *st, Yv *node) {
    Yv *k = ym_get(node, "k");
    if (ys_eq_lit(k, "num")) {
        if (num_is_float(ym_get(node, "v"))) {
            return ym(2, "typ", ym(1, "k", ys("tfloat")), "st", st);
        } else {
            return ym(2, "typ", ym(1, "k", ys("tlong")), "st", st);
        }
    } else if (ys_eq_lit(k, "str")) {
        return ym(2, "typ", ym(1, "k", ys("tstr")), "st", st);
    } else if (ys_eq_lit(k, "bstr")) {
        // b"..." is a [byte] literal (packed bytes, like a Python bytes)
        return ym(2, "typ", ym(2, "k", ys("tarr"), "of", ym(1, "k", ys("tbyte"))), "st", st);
    } else if (ys_eq_lit(k, "err")) {
        // Planted by the parser where the token stream stopped making
        // sense (parser.y has no error channel of its own).
        st = fail(st, ym_get(node, "msg"), yv_l(ym_get(node, "line")),
                  yv_l(ym_get(node, "col")));
        return ym(2, "typ", t_unk(), "st", st);
    } else if (ys_eq_lit(k, "bool")) {
        return ym(2, "typ", ym(1, "k", ys("tbool")), "st", st);
    } else if (ys_eq_lit(k, "null")) {
        // NO null type: null IS the option-empty value (value-or-null
        // options on this toolchain — some() is identity, is_some is
        // (v != null)). The literal is the unknown option; `x == null`
        // is the is-none check and assignments require a T?.
        return ym(2, "typ", ym(2, "k", ys("topt"), "of", t_unk()), "st", st);
    } else if (ys_eq_lit(k, "id")) {
        if (ys_eq_lit(ym_get(node, "v"), "self")) {
            // resolved by the enclosing def pre-pass (stored as _self in st)
            if (ys_eq_lit(ym_get(ym_get(st, "self"), "k"), "tnone")) {
                st = fail(st, ys("'self' outside of a function"),
                          yv_l(ym_get(node, "line")), yv_l(ym_get(node, "col")));
                return ym(2, "typ", t_unk(), "st", st);
            } else {
                return ym(2, "typ", ym_get(st, "self"), "st", st);
            }
        } else {
            Yv *got = lookup(ym_get(st, "bindings"), ym_get(node, "v"));
            if (ys_eq_lit(ym_get(got, "kind"), "")) {
                if (ys_eq_lit(ym_get(node, "v"), "none")) {
                    // the empty option (type from context via unification)
                    return ym(2, "typ", ym(2, "k", ys("topt"), "of", t_unk()),
                              "st", st);
                } else {
                    st = fail(st,
                              ys_cat(ys_cat(ys("undefined variable '"),
                                            ym_get(node, "v")),
                                     ys("'")),
                              yv_l(ym_get(node, "line")),
                              yv_l(ym_get(node, "col")));
                    return ym(2, "typ", t_unk(), "st", st);
                }
            } else {
                st = check_visible(st, got, ym_get(node, "v"),
                                   yv_l(ym_get(node, "line")),
                                   yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym_get(got, "typ"), "st", st);
            }
        }
    } else if (ys_eq_lit(k, "un")) {
        Yv *r = typeof_expr(st, ym_get(node, "e"));
        st = ym_get(r, "st");
        if (ys_eq_lit(ym_get(node, "op"), "-")) {
            if (ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tfloat")) {
                return ym(2, "typ", ym(1, "k", ys("tfloat")), "st", st);
            } else {
                st = expect_type(st, ym_get(r, "typ"), ym(1, "k", ys("tlong")),
                                 ys("unary '-'"), yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym(1, "k", ys("tlong")), "st", st);
            }
        } else {
            st = expect_type(st, ym_get(r, "typ"), ym(1, "k", ys("tbool")),
                             ys("unary '!'"), yv_l(ym_get(node, "line")),
                             yv_l(ym_get(node, "col")));
            return ym(2, "typ", ym(1, "k", ys("tbool")), "st", st);
        }
    } else if (ys_eq_lit(k, "addr")) {
        // &x (plain local/param) or &a[i] (element address, either array).
        // NOTE: no `&&` guard here — the VM evaluates both sides eagerly,
        // so a missing field on the right would crash. Nested ifs instead.
        if (ys_eq_lit(ym_get(ym_get(node, "e"), "k"), "id")) {
            if (!ys_eq_lit(ym_get(ym_get(node, "e"), "v"), "self")) {
                Yv *got = lookup(ym_get(st, "bindings"),
                                 ym_get(ym_get(node, "e"), "v"));
                if (ys_eq_lit(ym_get(got, "kind"), "")) {
                    st = fail(st,
                              ys_cat(ys_cat(ys("undefined variable '"),
                                            ym_get(ym_get(node, "e"), "v")),
                                     ys("'")),
                              yv_l(ym_get(node, "line")),
                              yv_l(ym_get(node, "col")));
                    return ym(2, "typ", t_unk(), "st", st);
                } else if (ys_eq_lit(ym_get(got, "kind"), "func") ||
                           ys_eq_lit(ym_get(got, "kind"), "intrinsic")) {
                    st = fail(st,
                              ys_cat(ys_cat(ys("cannot take the address of function '"),
                                            ym_get(ym_get(node, "e"), "v")),
                                     ys("'")),
                              yv_l(ym_get(node, "line")),
                              yv_l(ym_get(node, "col")));
                    return ym(2, "typ", t_unk(), "st", st);
                } else if (ys_eq_lit(ym_get(ym_get(got, "typ"), "k"), "tarr")) {
                    st = fail(st,
                              ys_cat(ys_cat(ys("cannot take the address of a whole heap array (use &"),
                                            disp(ym_get(ym_get(node, "e"), "v"))),
                                     ys("[i] for elements)")),
                              yv_l(ym_get(node, "line")),
                              yv_l(ym_get(node, "col")));
                    return ym(2, "typ", t_unk(), "st", st);
                } else if (ys_eq_lit(ym_get(ym_get(got, "typ"), "k"),
                                     "tarrfix")) {
                    st = check_visible(st, got, ym_get(ym_get(node, "e"), "v"),
                                       yv_l(ym_get(node, "line")),
                                       yv_l(ym_get(node, "col")));
                    // address of the first element (e.g. read(fd, &buf, n))
                    return ym(2, "typ",
                              ym(2, "k", ys("tptr"), "to",
                                 ym_get(ym_get(got, "typ"), "of")),
                              "st", st);
                } else {
                    st = check_visible(st, got, ym_get(ym_get(node, "e"), "v"),
                                       yv_l(ym_get(node, "line")),
                                       yv_l(ym_get(node, "col")));
                    return ym(2, "typ",
                              ym(2, "k", ys("tptr"), "to", ym_get(got, "typ")),
                              "st", st);
                }
            } else {
                st = fail(st,
                          ys("'&' needs a plain variable (only locals/params have addresses)"),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", t_unk(), "st", st);
            }
        } else if (ys_eq_lit(ym_get(ym_get(node, "e"), "k"), "index")) {
            Yv *ix = ym_get(ym_get(node, "e"), "idx");
            Yv *arr = ym_get(ym_get(node, "e"), "arr");
            if (ys_eq_lit(ym_get(arr, "k"), "id")) {
                Yv *got = lookup(ym_get(st, "bindings"), ym_get(arr, "v"));
                if (ys_eq_lit(ym_get(got, "kind"), "")) {
                    st = fail(st,
                              ys_cat(ys_cat(ys("undefined variable '"),
                                            ym_get(arr, "v")),
                                     ys("'")),
                              yv_l(ym_get(node, "line")),
                              yv_l(ym_get(node, "col")));
                    return ym(2, "typ", t_unk(), "st", st);
                } else if (ys_eq_lit(ym_get(ym_get(got, "typ"), "k"), "tarrfix") ||
                           ys_eq_lit(ym_get(ym_get(got, "typ"), "k"), "tarr")) {
                    st = check_visible(st, got, ym_get(arr, "v"),
                                       yv_l(ym_get(node, "line")),
                                       yv_l(ym_get(node, "col")));
                    Yv *r = typeof_expr(st, ix);
                    st = ym_get(r, "st");
                    st = expect_type(st, ym_get(r, "typ"), ym(1, "k", ys("tlong")),
                                     ys("array index"), yv_l(ym_get(node, "line")),
                                     yv_l(ym_get(node, "col")));
                    return ym(2, "typ",
                              ym(2, "k", ys("tptr"), "to",
                                 ym_get(ym_get(got, "typ"), "of")),
                              "st", st);
                } else {
                    st = fail(st,
                              ys_cat(ys_cat(ys("cannot index "),
                                            tstr(ym_get(got, "typ"))),
                                     ys(" (only arrays)")),
                              yv_l(ym_get(node, "line")),
                              yv_l(ym_get(node, "col")));
                    return ym(2, "typ", t_unk(), "st", st);
                }
            } else {
                // general base (`&grid[0][i]`, `&rec.v[i]`): an element
                // address of any array expression.
                Yv *barr = arr;
                Yv *br = typeof_expr(st, barr);
                st = ym_get(br, "st");
                if (ys_eq_lit(ym_get(ym_get(br, "typ"), "k"), "tarrfix") ||
                    ys_eq_lit(ym_get(ym_get(br, "typ"), "k"), "tarr")) {
                    Yv *r = typeof_expr(st, ix);
                    st = ym_get(r, "st");
                    st = expect_type(st, ym_get(r, "typ"), ym(1, "k", ys("tlong")),
                                     ys("array index"), yv_l(ym_get(node, "line")),
                                     yv_l(ym_get(node, "col")));
                    return ym(2, "typ",
                              ym(2, "k", ys("tptr"), "to",
                                 ym_get(ym_get(br, "typ"), "of")),
                              "st", st);
                } else {
                    st = fail(st,
                              ys_cat(ys_cat(ys("cannot index "),
                                            tstr(ym_get(br, "typ"))),
                                     ys(" (only arrays)")),
                              yv_l(ym_get(node, "line")),
                              yv_l(ym_get(node, "col")));
                    return ym(2, "typ", t_unk(), "st", st);
                }
            }
        } else {
            st = fail(st,
                      ys("'&' needs a plain variable (only locals/params have addresses)"),
                      yv_l(ym_get(node, "line")), yv_l(ym_get(node, "col")));
            return ym(2, "typ", t_unk(), "st", st);
        }
    } else if (ys_eq_lit(k, "deref")) {
        Yv *r = typeof_expr(st, ym_get(node, "e"));
        st = ym_get(r, "st");
        if (ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tptr")) {
            return ym(2, "typ", ym_get(ym_get(r, "typ"), "to"), "st", st);
        } else if (ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tunk")) {
            return ym(2, "typ", t_unk(), "st", st);
        } else {
            st = fail(st,
                      ys_cat(ys_cat(ys("cannot dereference "),
                                    tstr(ym_get(r, "typ"))),
                             ys(" (need *T)")),
                      yv_l(ym_get(node, "line")), yv_l(ym_get(node, "col")));
            return ym(2, "typ", t_unk(), "st", st);
        }
    } else if (ys_eq_lit(k, "bin")) {
        Yv *l = typeof_expr(st, ym_get(node, "l"));
        Yv *r = typeof_expr(ym_get(l, "st"), ym_get(node, "r"));
        st = ym_get(r, "st");
        Yv *op = ym_get(node, "op");
        // NOTE: nested ifs, not `||` chains (see lexer.y isalnum note): the
        // C VM evaluates both sides eagerly AND the checker rejects `||`
        // mixing comparison-bool with map-field shapes through one gate.
        if (ys_eq_lit(op, "+")) {
            return typeof_arith(st, op, ym_get(l, "typ"), ym_get(r, "typ"),
                                yv_l(ym_get(node, "line")),
                                yv_l(ym_get(node, "col")));
        } else if (ys_eq_lit(op, "-")) {
            return typeof_arith(st, op, ym_get(l, "typ"), ym_get(r, "typ"),
                                yv_l(ym_get(node, "line")),
                                yv_l(ym_get(node, "col")));
        } else if (ys_eq_lit(op, "*")) {
            return typeof_arith(st, op, ym_get(l, "typ"), ym_get(r, "typ"),
                                yv_l(ym_get(node, "line")),
                                yv_l(ym_get(node, "col")));
        } else if (ys_eq_lit(op, "/")) {
            return typeof_arith(st, op, ym_get(l, "typ"), ym_get(r, "typ"),
                                yv_l(ym_get(node, "line")),
                                yv_l(ym_get(node, "col")));
        } else if (ys_eq_lit(op, "%")) {
            return typeof_arith(st, op, ym_get(l, "typ"), ym_get(r, "typ"),
                                yv_l(ym_get(node, "line")),
                                yv_l(ym_get(node, "col")));
        } else if (ys_eq_lit(op, "<")) {
            return typeof_cmp(st, op, ym_get(l, "typ"), ym_get(r, "typ"),
                              yv_l(ym_get(node, "line")),
                              yv_l(ym_get(node, "col")));
        } else if (ys_eq_lit(op, ">")) {
            return typeof_cmp(st, op, ym_get(l, "typ"), ym_get(r, "typ"),
                              yv_l(ym_get(node, "line")),
                              yv_l(ym_get(node, "col")));
        } else if (ys_eq_lit(op, "<=")) {
            return typeof_cmp(st, op, ym_get(l, "typ"), ym_get(r, "typ"),
                              yv_l(ym_get(node, "line")),
                              yv_l(ym_get(node, "col")));
        } else if (ys_eq_lit(op, ">=")) {
            return typeof_cmp(st, op, ym_get(l, "typ"), ym_get(r, "typ"),
                              yv_l(ym_get(node, "line")),
                              yv_l(ym_get(node, "col")));
        } else if (ys_eq_lit(op, "==")) {
            return typeof_eq(st, op, ym_get(l, "typ"), ym_get(r, "typ"),
                             yv_l(ym_get(node, "line")),
                             yv_l(ym_get(node, "col")));
        } else if (ys_eq_lit(op, "!=")) {
            return typeof_eq(st, op, ym_get(l, "typ"), ym_get(r, "typ"),
                             yv_l(ym_get(node, "line")),
                             yv_l(ym_get(node, "col")));
        } else if (ys_eq_lit(op, "&&")) {
            return typeof_logic(st, op, ym_get(l, "typ"), ym_get(r, "typ"),
                                yv_l(ym_get(node, "line")),
                                yv_l(ym_get(node, "col")));
        } else if (ys_eq_lit(op, "||")) {
            return typeof_logic(st, op, ym_get(l, "typ"), ym_get(r, "typ"),
                                yv_l(ym_get(node, "line")),
                                yv_l(ym_get(node, "col")));
        } else if (ys_eq_lit(op, "::")) {
            return typeof_cons(st, ym_get(l, "typ"), ym_get(r, "typ"),
                               yv_l(ym_get(node, "line")),
                               yv_l(ym_get(node, "col")));
        } else {
            st = fail(st,
                      ys_cat(ys_cat(ys("operator '"), op),
                             ys("' is unsupported in native mode")),
                      yv_l(ym_get(node, "line")), yv_l(ym_get(node, "col")));
            return ym(2, "typ", t_unk(), "st", st);
        }
    } else if (ys_eq_lit(k, "call")) {
        return typeof_call(st, node);
    } else if (ys_eq_lit(k, "if")) {
        Yv *c = typeof_expr(st, ym_get(node, "cond"));
        st = expect_type(ym_get(c, "st"), ym_get(c, "typ"), ym(1, "k", ys("tbool")),
                         ys("'if' condition"), yv_l(ym_get(node, "line")),
                         yv_l(ym_get(node, "col")));
        // NOTE: typeof_expr, not typeof_block — `els` may be a nested `if`
        // (else-if chain), not a block.
        Yv *t = typeof_expr(st, ym_get(node, "then"));
        st = ym_get(t, "st");
        if (yv_truth(ym_get(node, "has_else"))) {
            Yv *e = typeof_expr(st, ym_get(node, "els"));
            st = ym_get(e, "st");
            if (!teq(ym_get(t, "typ"), ym_get(e, "typ"))) {
                // Void mixing: when either arm computes no value (void /
                // null statements), the whole if is a statement — no
                // disagreement error, the value arm's value is discarded.
                Yv *tk = ym_get(ym_get(t, "typ"), "k");
                Yv *ek = ym_get(ym_get(e, "typ"), "k");
                if (ys_eq_lit(tk, "tvoid") || ys_eq_lit(tk, "tnull") ||
                    ys_eq_lit(ek, "tvoid") || ys_eq_lit(ek, "tnull")) {
                    ;
                } else {
                    st = fail(st,
                              ys_cat(ys_cat(ys_cat(ys("'if' branches disagree: "),
                                                  tstr(ym_get(t, "typ"))),
                                            ys(" vs ")),
                                     tstr(ym_get(e, "typ"))),
                              yv_l(ym_get(node, "line")),
                              yv_l(ym_get(node, "col")));
                    ;
                }
                ;
            } else {
                ;
            }
            return ym(2, "typ", ym_get(t, "typ"), "st", st);
        } else {
            // VOID law: an `if` without `else` is a STATEMENT — its value is
            // nothing, whatever the then-branch computes. No forced else
            // branch, no forced `0;` tail in user programs.
            return ym(2, "typ", ym(1, "k", ys("tvoid")), "st", st);
        }
    } else if (ys_eq_lit(k, "while")) {
        Yv *c = typeof_expr(st, ym_get(node, "cond"));
        st = expect_type(ym_get(c, "st"), ym_get(c, "typ"), ym(1, "k", ys("tbool")),
                         ys("'while' condition"), yv_l(ym_get(node, "line")),
                         yv_l(ym_get(node, "col")));
        Yv *b = typeof_block(st, ym_get(node, "body"));
        return ym(2, "typ", ym(1, "k", ys("tvoid")), "st", ym_get(b, "st"));
    } else if (ys_eq_lit(k, "for")) {
        // for (init; cond; step) body — init/step are statements, and the
        // loop variable stays visible afterwards (same scope rule as `let`).
        Yv *fi = typeof_expr(st, ym_get(node, "init"));
        st = ym_get(fi, "st");
        Yv *fc = typeof_expr(st, ym_get(node, "cond"));
        st = expect_type(ym_get(fc, "st"), ym_get(fc, "typ"),
                         ym(1, "k", ys("tbool")), ys("'for' condition"),
                         yv_l(ym_get(node, "line")), yv_l(ym_get(node, "col")));
        Yv *fb = typeof_block(st, ym_get(node, "body"));
        st = ym_get(fb, "st");
        Yv *fs = typeof_expr(st, ym_get(node, "step"));
        return ym(2, "typ", ym(1, "k", ys("tvoid")), "st", ym_get(fs, "st"));
    } else if (ys_eq_lit(k, "foreach")) {
        // foreach (x in arr) body — x takes the array's element type.
        Yv *fe = typeof_expr(st, ym_get(node, "iter"));
        st = ym_get(fe, "st");
        Yv *elt = t_unk();
        if (ys_eq_lit(ym_get(ym_get(fe, "typ"), "k"), "tarr")) {
            elt = ym_get(ym_get(fe, "typ"), "of");
            ;
        } else if (ys_eq_lit(ym_get(ym_get(fe, "typ"), "k"), "tarrfix")) {
            elt = ym_get(ym_get(fe, "typ"), "of");
            ;
        } else if (ys_eq_lit(ym_get(ym_get(fe, "typ"), "k"), "tunk")) {
            ;
        } else {
            st = fail(st,
                      ys_cat(ys("'foreach' needs an array, got "),
                             tstr(ym_get(fe, "typ"))),
                      yv_l(ym_get(node, "line")), yv_l(ym_get(node, "col")));
            ;
        }
        st = st_bind(st, ym_get(node, "name"), elt, ys("local"));
        Yv *fbb = typeof_block(st, ym_get(node, "body"));
        return ym(2, "typ", ym(1, "k", ys("tvoid")), "st", ym_get(fbb, "st"));
    } else if (ys_eq_lit(k, "forrange")) {
        // forrange (x in lo..hi) body — x is a long.
        Yv *rl = typeof_expr(st, ym_get(node, "lo"));
        st = expect_type(ym_get(rl, "st"), ym_get(rl, "typ"),
                         ym(1, "k", ys("tlong")), ys("'for' range start"),
                         yv_l(ym_get(node, "line")), yv_l(ym_get(node, "col")));
        Yv *rh = typeof_expr(st, ym_get(node, "hi"));
        st = expect_type(ym_get(rh, "st"), ym_get(rh, "typ"),
                         ym(1, "k", ys("tlong")), ys("'for' range end"),
                         yv_l(ym_get(node, "line")), yv_l(ym_get(node, "col")));
        st = st_bind(st, ym_get(node, "name"), ym(1, "k", ys("tlong")),
                     ys("local"));
        Yv *rb = typeof_block(st, ym_get(node, "body"));
        return ym(2, "typ", ym(1, "k", ys("tvoid")), "st", ym_get(rb, "st"));
    } else if (ys_eq_lit(k, "block")) {
        return typeof_block(st, node);
    } else if (ys_eq_lit(k, "decl")) {
        return typeof_decl(st, node);
    } else if (ys_eq_lit(k, "assign")) {
        Yv *r = typeof_expr(st, ym_get(node, "v"));
        st = ym_get(r, "st");
        Yv *got = lookup(ym_get(st, "bindings"), ym_get(node, "name"));
        if (ys_eq_lit(ym_get(got, "kind"), "")) {
            st = fail(st,
                      ys_cat(ys_cat(ys("undefined variable '"),
                                    disp(ym_get(node, "name"))),
                             ys("'")),
                      yv_l(ym_get(node, "line")), yv_l(ym_get(node, "col")));
            return ym(2, "typ", t_unk(), "st", st);
        } else if (ys_eq_lit(ym_get(got, "kind"), "func") ||
                   ys_eq_lit(ym_get(got, "kind"), "intrinsic")) {
            st = fail(st,
                      ys_cat(ys_cat(ys("cannot assign to function '"),
                                    disp(ym_get(node, "name"))),
                             ys("'")),
                      yv_l(ym_get(node, "line")), yv_l(ym_get(node, "col")));
            return ym(2, "typ", t_unk(), "st", st);
        } else if (ys_eq_lit(ym_get(ym_get(got, "typ"), "k"), "tarrfix")) {
            st = check_visible(st, got, ym_get(node, "name"),
                               yv_l(ym_get(node, "line")),
                               yv_l(ym_get(node, "col")));
            st = expect_type(st, ym_get(r, "typ"), ym_get(got, "typ"),
                             ys_cat(ys_cat(ys("assignment to '"),
                                           disp(ym_get(node, "name"))),
                                    ys("'")),
                             yv_l(ym_get(node, "line")),
                             yv_l(ym_get(node, "col")));
            return ym(2, "typ", ym_get(got, "typ"), "st", st);
        } else {
            st = check_visible(st, got, ym_get(node, "name"),
                               yv_l(ym_get(node, "line")),
                               yv_l(ym_get(node, "col")));
            st = expect_type(st, ym_get(r, "typ"), ym_get(got, "typ"),
                             ys_cat(ys_cat(ys("assignment to '"),
                                           disp(ym_get(node, "name"))),
                                    ys("'")),
                             yv_l(ym_get(node, "line")),
                             yv_l(ym_get(node, "col")));
            return ym(2, "typ", ym_get(got, "typ"), "st", st);
        }
    } else if (ys_eq_lit(k, "incdec")) {
        // ++x / x++: numbers only — `s++` on a string would silently
        // concatenate, so it is a type error instead.
        Yv *t = typeof_expr(st, ym_get(node, "tgt"));
        st = ym_get(t, "st");
        return incdec_check(st, node, ym_get(t, "typ"));
    } else if (ys_eq_lit(k, "opassign")) {
        // `x op= e`: the rules live in opassign_check.
        Yv *t = typeof_expr(st, ym_get(node, "tgt"));
        st = ym_get(t, "st");
        Yv *v = typeof_expr(st, ym_get(node, "v"));
        st = ym_get(v, "st");
        return opassign_check(st, node, ym_get(t, "typ"), ym_get(v, "typ"));
    } else if (ys_eq_lit(k, "store")) {
        Yv *p = typeof_expr(st, ym_get(node, "p"));
        Yv *v = typeof_expr(ym_get(p, "st"), ym_get(node, "v"));
        st = ym_get(v, "st");
        if (ys_eq_lit(ym_get(ym_get(p, "typ"), "k"), "tptr")) {
            st = expect_type(st, ym_get(v, "typ"),
                             ym_get(ym_get(p, "typ"), "to"),
                             ys("store through pointer"),
                             yv_l(ym_get(node, "line")),
                             yv_l(ym_get(node, "col")));
            return ym(2, "typ", ym_get(ym_get(p, "typ"), "to"), "st", st);
        } else if (ys_eq_lit(ym_get(ym_get(p, "typ"), "k"), "tunk") ||
                   ys_eq_lit(ym_get(ym_get(v, "typ"), "k"), "tunk")) {
            return ym(2, "typ", t_unk(), "st", st);
        } else {
            st = fail(st,
                      ys_cat(ys("store target must be *T, got "),
                             tstr(ym_get(p, "typ"))),
                      yv_l(ym_get(node, "line")), yv_l(ym_get(node, "col")));
            return ym(2, "typ", t_unk(), "st", st);
        }
    } else if (ys_eq_lit(k, "ret")) {
        if (ys_eq_lit(ym_get(ym_get(st, "ret"), "k"), "tnone")) {
            st = fail(st, ys("'return' outside of a function"),
                      yv_l(ym_get(node, "line")), yv_l(ym_get(node, "col")));
            return ym(2, "typ", t_unk(), "st", st);
        } else {
            Yv *r = typeof_expr(st, ym_get(node, "e"));
            st = expect_type(ym_get(r, "st"), ym_get(r, "typ"),
                             ym_get(st, "ret"), ys("'return'"),
                             yv_l(ym_get(node, "line")),
                             yv_l(ym_get(node, "col")));
            return ym(2, "typ", ym_get(st, "ret"), "st", st);
        }
    } else if (ys_eq_lit(k, "map")) {
        // Record literal { k: v, ... }: every value checked, the type is a
        // trec with field names in order. Empty maps need an annotation
        // (nothing to infer — like []).
        Yv *mkeys = ym_get(node, "keys");
        Yv *mvals = ym_get(node, "vals");
        if (yv_len(mkeys) == 0) {
            st = fail(st, ys("cannot infer record type: annotate the map"),
                      yv_l(ym_get(node, "line")), yv_l(ym_get(node, "col")));
            return ym(2, "typ", t_unk(), "st", st);
        } else {
            Yv *fields = yav(0);
            long i = 0;
            int ok = 1;
            while (i < yv_len(mkeys)) {
                // NOTE: each bound once — `x.y[i]` chains misparse on the C VM.
                Yv *mvv = ya_get(mvals, i);
                Yv *mkey = ya_get(mkeys, i);
                Yv *r = typeof_expr(st, mvv);
                st = ym_get(r, "st");
                if (ys_eq_lit(mkey, "...")) {
                    // Static spread `...obj`: the union of the two shapes
                    // (field_merge: later wins the value, first appearance
                    // keeps the position). No dynamic shape is involved.
                    if (ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "trec")) {
                        Yv *sfs = ym_get(ym_get(r, "typ"), "fields");
                        long si = 0;
                        while (si < yv_len(sfs)) {
                            Yv *sf = ya_get(sfs, si);
                            fields = field_merge(fields, ym_get(sf, "name"),
                                                 ym_get(sf, "typ"));
                            si = si + 1;
                        }
                        ;
                    } else if (ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tunk") ||
                               ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tnone") ||
                               ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tname")) {
                        // poison quietly (tcompat law)
                        ok = 0;
                        ;
                    } else {
                        st = fail(st,
                                  ys_cat(ys("'...' spread needs a record, got "),
                                         tstr(ym_get(r, "typ"))),
                                  yv_l(ym_get(node, "line")),
                                  yv_l(ym_get(node, "col")));
                        ok = 0;
                        ;
                    }
                    ;
                } else if (ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tnone")) {
                    // unannotated value shape (tcompat law): the missing
                    // annotation errors once at its own site; don't cascade
                    // here, but poison the record so uses don't mistype.
                    ok = 0;
                    ;
                } else if (ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tname")) {
                    ok = 0;
                    ;
                } else if (!is_value_type(ym_get(r, "typ"))) {
                    st = fail(st,
                              ys_cat(ys_cat(ys_cat(ys("record field '"), mkey),
                                            ys("' has unsupported type ")),
                                     tstr(ym_get(r, "typ"))),
                              yv_l(ym_get(node, "line")),
                              yv_l(ym_get(node, "col")));
                    ok = 0;
                    ;
                } else {
                    ;
                }
                if (ys_eq_lit(mkey, "...")) {
                    ;
                } else {
                    fields = field_merge(fields, mkey, ym_get(r, "typ"));
                    ;
                }
                i = i + 1;
            }
            if (ok) {
                return ym(2, "typ", ym(2, "k", ys("trec"), "fields", fields),
                          "st", st);
            } else {
                return ym(2, "typ", t_unk(), "st", st);
            }
        }
    } else if (ys_eq_lit(k, "dot")) {
        // Record field read: obj must be a trec with that field.
        // NOTE: each bound once — `node.obj` inline misparses on the C VM.
        // NOTE: flow-snapshot (dobj/dkey bound once, never rebound): the
        // checker env is flow-INSENSITIVE (last shape wins per name), so a
        // field read must go through a name bound to exactly one shape.
        // Re-reading `node.obj` after any `node = ...` rebind in the same
        // function would resolve against the rebound shape.
        Yv *dobj = ym_get(node, "obj");
        Yv *dkey = ym_get(node, "key");
        Yv *r = typeof_expr(st, dobj);
        st = ym_get(r, "st");
        if (ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "trec")) {
            int found = 0;
            Yv *ftyp = t_unk();
            Yv *fs = ym_get(ym_get(r, "typ"), "fields");
            long j = 0;
            while (j < yv_len(fs)) {
                // NOTE: bound once — `x.y[i]` chains misparse on the C VM.
                // NOTE: :str bindings (see teq note).
                Yv *f = ya_get(fs, j);
                Yv *fn = ym_get(f, "name");
                if (ys_eq(fn, dkey)) {
                    found = 1;
                    ftyp = ym_get(f, "typ");
                    ;
                } else {
                    ;
                }
                j = j + 1;
                ;
            }
            if (found) {
                return ym(2, "typ", ftyp, "st", st);
            } else if (teq(ym_get(r, "typ"), unk_shape())) {
                // unknown-shape ({k}-only) reads unify quietly (tcompat
                // law) — the missing annotation errors once at its own
                // site, not again at every enclosing read. Concrete
                // records still error below (emitter rejects loudly).
                return ym(2, "typ", t_unk(), "st", st);
            } else {
                st = fail(st,
                          ys_cat(ys_cat(ys("record has no field '"), dkey),
                                 ys("'")),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", t_unk(), "st", st);
            }
        } else if (ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tunk")) {
            return ym(2, "typ", t_unk(), "st", st);
        } else if (ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tnone")) {
            // bare-hole params (see typeof_def note): unify quietly.
            return ym(2, "typ", t_unk(), "st", st);
        } else if (ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tname")) {
            return ym(2, "typ", t_unk(), "st", st);
        } else if (ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tparams")) {
            return ym(2, "typ", t_unk(), "st", st);
        } else if (ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tnull")) {
            return ym(2, "typ", t_unk(), "st", st);
        } else {
            st = fail(st,
                      ys_cat(ys_cat(ys_cat(ys_cat(ys("cannot read field '"),
                                                  ym_get(node, "key")),
                                            ys("' of ")),
                                     tstr(ym_get(r, "typ"))),
                             ys(" (need a record)")),
                      yv_l(ym_get(node, "line")), yv_l(ym_get(node, "col")));
            return ym(2, "typ", t_unk(), "st", st);
        }
    } else if (ys_eq_lit(k, "func")) {
        // Anonymous function literal in expression position. Check the body
        // like a named def would be, and give the expression its tfunc type;
        // the emitter closure-converts it with a generated label.
        Yv *ra = typeof_def(st, ys(""), node, yv_l(ym_get(node, "line")),
                            yv_l(ym_get(node, "col")));
        return ym(2, "typ", ym_get(ra, "typ"), "st", ym_get(ra, "st"));
    } else if (ys_eq_lit(k, "arrrep")) {
        // [v; n]: n stack slots filled with v (the native array form)
        Yv *r = typeof_expr(st, ym_get(node, "v"));
        st = ym_get(r, "st");
        if (!is_value_type(ym_get(r, "typ"))) {
            st = fail(st,
                      ys_cat(ys_cat(ys("array element type "),
                                    tstr(ym_get(r, "typ"))),
                             ys(" is unsupported in native mode")),
                      yv_l(ym_get(node, "line")), yv_l(ym_get(node, "col")));
            return ym(2, "typ", t_unk(), "st", st);
        } else if (yv_l(ym_get(node, "n")) < 0) {
            st = fail(st,
                      ys("array size must be a non-negative integer literal ([v; n])"),
                      yv_l(ym_get(node, "line")), yv_l(ym_get(node, "col")));
            return ym(2, "typ", t_unk(), "st", st);
        } else {
            return ym(2, "typ",
                      ym(3, "k", ys("tarrfix"), "of", ym_get(r, "typ"), "n",
                         ym_get(node, "n")),
                      "st", st);
        }
    } else if (ys_eq_lit(k, "index")) {
        // Indexing binds a name once (no x.y[i] chains — the C parser
        // misreads them; see teq note). Plain locals, params, AND function
        // params of array type alike: frames or heap headers address them
        // directly; bounds are checked at runtime. Fixed [T; N] and heap
        // [T] alike. Params of tunk (missing annotation) error elsewhere —
        // here they poison quietly to avoid cascades.
        if (ys_eq_lit(ym_get(ym_get(node, "arr"), "k"), "id")) {
            Yv *got = lookup(ym_get(st, "bindings"),
                             ym_get(ym_get(node, "arr"), "v"));
            if (ys_eq_lit(ym_get(got, "kind"), "")) {
                st = fail(st,
                          ys_cat(ys_cat(ys("undefined variable '"),
                                        ym_get(ym_get(node, "arr"), "v")),
                                 ys("'")),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", t_unk(), "st", st);
            } else if (ys_eq_lit(ym_get(ym_get(got, "typ"), "k"), "tarrfix") ||
                       ys_eq_lit(ym_get(ym_get(got, "typ"), "k"), "tarr")) {
                st = check_visible(st, got, ym_get(ym_get(node, "arr"), "v"),
                                   yv_l(ym_get(node, "line")),
                                   yv_l(ym_get(node, "col")));
                Yv *r = typeof_expr(st, ym_get(node, "idx"));
                st = ym_get(r, "st");
                st = expect_type(st, ym_get(r, "typ"), ym(1, "k", ys("tlong")),
                                 ys("array index"), yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym_get(ym_get(got, "typ"), "of"), "st", st);
            } else if (ys_eq_lit(ym_get(ym_get(got, "typ"), "k"), "tunk") ||
                       ys_eq_lit(ym_get(ym_get(got, "typ"), "k"), "tnone") ||
                       ys_eq_lit(ym_get(ym_get(got, "typ"), "k"), "tname")) {
                Yv *r = typeof_expr(st, ym_get(node, "idx"));
                st = ym_get(r, "st");
                return ym(2, "typ", t_unk(), "st", st);
            } else {
                st = fail(st,
                          ys_cat(ys_cat(ys("cannot index "),
                                        tstr(ym_get(got, "typ"))),
                                 ys(" (only arrays)")),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", t_unk(), "st", st);
            }
        } else {
            // Any expression of array type: `grid[0][1]`, `rec.v[i]`,
            // `f()[i]`. The base runs once at runtime; its static type
            // carries the element type.
            Yv *barr = ym_get(node, "arr");
            Yv *br = typeof_expr(st, barr);
            st = ym_get(br, "st");
            if (ys_eq_lit(ym_get(ym_get(br, "typ"), "k"), "tarrfix") ||
                ys_eq_lit(ym_get(ym_get(br, "typ"), "k"), "tarr")) {
                Yv *ri = typeof_expr(st, ym_get(node, "idx"));
                st = ym_get(ri, "st");
                st = expect_type(st, ym_get(ri, "typ"), ym(1, "k", ys("tlong")),
                                 ys("array index"), yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym_get(ym_get(br, "typ"), "of"), "st", st);
            } else if (ys_eq_lit(ym_get(ym_get(br, "typ"), "k"), "tunk") ||
                       ys_eq_lit(ym_get(ym_get(br, "typ"), "k"), "tnone") ||
                       ys_eq_lit(ym_get(ym_get(br, "typ"), "k"), "tname")) {
                // poison quietly (tcompat law) — the missing annotation
                // reports at its own site.
                Yv *ri = typeof_expr(st, ym_get(node, "idx"));
                st = ym_get(ri, "st");
                return ym(2, "typ", t_unk(), "st", st);
            } else {
                st = fail(st,
                          ys_cat(ys_cat(ys("cannot index "),
                                        tstr(ym_get(br, "typ"))),
                                 ys(" (only arrays)")),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", t_unk(), "st", st);
            }
        }
    } else if (ys_eq_lit(k, "slice")) {
        // arr[lo:hi] -> a new array of the same element type. Missing
        // bounds default to 0 / len; the result is always a heap [T],
        // even when slicing a fixed [T; N].
        Yv *sr = typeof_expr(st, ym_get(node, "arr"));
        st = ym_get(sr, "st");
        Yv *slo = ym_get(node, "lo");
        Yv *shi = ym_get(node, "hi");
        if (ys_eq_lit(ym_get(slo, "k"), "null")) {
            ;
        } else {
            Yv *rl = typeof_expr(st, slo);
            st = expect_type(ym_get(rl, "st"), ym_get(rl, "typ"),
                             ym(1, "k", ys("tlong")), ys("slice start"),
                             yv_l(ym_get(node, "line")),
                             yv_l(ym_get(node, "col")));
            ;
        }
        if (ys_eq_lit(ym_get(shi, "k"), "null")) {
            ;
        } else {
            Yv *rh = typeof_expr(st, shi);
            st = expect_type(ym_get(rh, "st"), ym_get(rh, "typ"),
                             ym(1, "k", ys("tlong")), ys("slice end"),
                             yv_l(ym_get(node, "line")),
                             yv_l(ym_get(node, "col")));
            ;
        }
        if (ys_eq_lit(ym_get(ym_get(sr, "typ"), "k"), "tarr")) {
            return ym(2, "typ",
                      ym(2, "k", ys("tarr"), "of",
                         ym_get(ym_get(sr, "typ"), "of")),
                      "st", st);
        } else if (ys_eq_lit(ym_get(ym_get(sr, "typ"), "k"), "tarrfix")) {
            return ym(2, "typ",
                      ym(2, "k", ys("tarr"), "of",
                         ym_get(ym_get(sr, "typ"), "of")),
                      "st", st);
        } else if (ys_eq_lit(ym_get(ym_get(sr, "typ"), "k"), "tunk")) {
            return ym(2, "typ", t_unk(), "st", st);
        } else {
            st = fail(st,
                      ys_cat(ys_cat(ys("cannot slice "), tstr(ym_get(sr, "typ"))),
                             ys(" (only arrays)")),
                      yv_l(ym_get(node, "line")), yv_l(ym_get(node, "col")));
            return ym(2, "typ", t_unk(), "st", st);
        }
    } else if (ys_eq_lit(k, "dotassign")) {
        // s.f = v — in-place record field write. The object must be a plain
        // variable holding a record; the field must exist in its static
        // shape (checked at the map literal / annotation site).
        if (ys_eq_lit(ym_get(ym_get(node, "obj"), "k"), "id")) {
            Yv *got = lookup(ym_get(st, "bindings"),
                             ym_get(ym_get(node, "obj"), "v"));
            if (ys_eq_lit(ym_get(got, "kind"), "")) {
                st = fail(st,
                          ys_cat(ys_cat(ys("undefined variable '"),
                                        ym_get(ym_get(node, "obj"), "v")),
                                 ys("'")),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", t_unk(), "st", st);
            } else if (ys_eq_lit(ym_get(ym_get(got, "typ"), "k"), "trec")) {
                Yv *ft = trec_field_type(ym_get(got, "typ"),
                                         ym_get(node, "key"));
                if (ys_eq_lit(ym_get(ft, "k"), "tnone")) {
                    st = fail(st,
                              ys_cat(ys_cat(ys("record has no field '"),
                                            ym_get(node, "key")),
                                     ys("'")),
                              yv_l(ym_get(node, "line")),
                              yv_l(ym_get(node, "col")));
                    return ym(2, "typ", t_unk(), "st", st);
                } else {
                    Yv *v = typeof_expr(st, ym_get(node, "v"));
                    st = ym_get(v, "st");
                    st = expect_type(st, ym_get(v, "typ"), ft,
                                     ys_cat(ys_cat(ys("record field '"),
                                                   ym_get(node, "key")),
                                            ys("'")),
                                     yv_l(ym_get(node, "line")),
                                     yv_l(ym_get(node, "col")));
                    return ym(2, "typ", ft, "st", st);
                }
            } else {
                st = fail(st,
                          ys_cat(ys_cat(ys("cannot field-assign "),
                                        tstr(ym_get(got, "typ"))),
                                 ys(" (only records)")),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", t_unk(), "st", st);
            }
        } else {
            // General object (`a[0].f = v`, `x.y.f = v`): the object
            // expression's static type must be a record with the field.
            Yv *dobj2 = ym_get(node, "obj");
            Yv *obr = typeof_expr(st, dobj2);
            st = ym_get(obr, "st");
            if (ys_eq_lit(ym_get(ym_get(obr, "typ"), "k"), "trec")) {
                Yv *ft = trec_field_type(ym_get(obr, "typ"), ym_get(node, "key"));
                if (ys_eq_lit(ym_get(ft, "k"), "tnone")) {
                    st = fail(st,
                              ys_cat(ys_cat(ys("record has no field '"),
                                            ym_get(node, "key")),
                                     ys("'")),
                              yv_l(ym_get(node, "line")),
                              yv_l(ym_get(node, "col")));
                    return ym(2, "typ", t_unk(), "st", st);
                } else {
                    Yv *v = typeof_expr(st, ym_get(node, "v"));
                    st = ym_get(v, "st");
                    st = expect_type(st, ym_get(v, "typ"), ft,
                                     ys_cat(ys_cat(ys("record field '"),
                                                   ym_get(node, "key")),
                                            ys("'")),
                                     yv_l(ym_get(node, "line")),
                                     yv_l(ym_get(node, "col")));
                    return ym(2, "typ", ft, "st", st);
                }
            } else {
                st = fail(st,
                          ys_cat(ys_cat(ys("cannot field-assign "),
                                        tstr(ym_get(obr, "typ"))),
                                 ys(" (only records)")),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", t_unk(), "st", st);
            }
        }
    } else if (ys_eq_lit(k, "idxassign")) {
        if (ys_eq_lit(ym_get(ym_get(node, "arr"), "k"), "id")) {
            Yv *got = lookup(ym_get(st, "bindings"),
                             ym_get(ym_get(node, "arr"), "v"));
            if (ys_eq_lit(ym_get(got, "kind"), "")) {
                st = fail(st,
                          ys_cat(ys_cat(ys("undefined variable '"),
                                        ym_get(ym_get(node, "arr"), "v")),
                                 ys("'")),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", t_unk(), "st", st);
            } else if (ys_eq_lit(ym_get(ym_get(got, "typ"), "k"), "tarrfix") ||
                       ys_eq_lit(ym_get(ym_get(got, "typ"), "k"), "tarr")) {
                st = check_visible(st, got, ym_get(ym_get(node, "arr"), "v"),
                                   yv_l(ym_get(node, "line")),
                                   yv_l(ym_get(node, "col")));
                Yv *ix = typeof_expr(st, ym_get(node, "idx"));
                st = ym_get(ix, "st");
                st = expect_type(st, ym_get(ix, "typ"), ym(1, "k", ys("tlong")),
                                 ys("array index"), yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                Yv *v = typeof_expr(st, ym_get(node, "v"));
                st = ym_get(v, "st");
                st = expect_type(st, ym_get(v, "typ"),
                                 ym_get(ym_get(got, "typ"), "of"),
                                 ys("array element"), yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym_get(ym_get(got, "typ"), "of"), "st", st);
            } else {
                st = fail(st,
                          ys_cat(ys_cat(ys("cannot index "),
                                        tstr(ym_get(got, "typ"))),
                                 ys(" (only arrays)")),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", t_unk(), "st", st);
            }
        } else {
            // General base (`grid[0][1] = v`, `rec.v[i] = v`): the base
            // expression's static type must be an array of the value type.
            Yv *barr = ym_get(node, "arr");
            Yv *br = typeof_expr(st, barr);
            st = ym_get(br, "st");
            if (ys_eq_lit(ym_get(ym_get(br, "typ"), "k"), "tarrfix") ||
                ys_eq_lit(ym_get(ym_get(br, "typ"), "k"), "tarr")) {
                Yv *ix = typeof_expr(st, ym_get(node, "idx"));
                st = ym_get(ix, "st");
                st = expect_type(st, ym_get(ix, "typ"), ym(1, "k", ys("tlong")),
                                 ys("array index"), yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                Yv *v = typeof_expr(st, ym_get(node, "v"));
                st = ym_get(v, "st");
                st = expect_type(st, ym_get(v, "typ"),
                                 ym_get(ym_get(br, "typ"), "of"),
                                 ys("array element"), yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym_get(ym_get(br, "typ"), "of"), "st", st);
            } else if (ys_eq_lit(ym_get(ym_get(br, "typ"), "k"), "tunk") ||
                       ys_eq_lit(ym_get(ym_get(br, "typ"), "k"), "tnone") ||
                       ys_eq_lit(ym_get(ym_get(br, "typ"), "k"), "tname")) {
                // poison quietly (tcompat law) — the missing annotation
                // reports at its own site.
                Yv *ix = typeof_expr(st, ym_get(node, "idx"));
                st = ym_get(ix, "st");
                Yv *v = typeof_expr(st, ym_get(node, "v"));
                st = ym_get(v, "st");
                return ym(2, "typ", t_unk(), "st", st);
            } else {
                st = fail(st,
                          ys_cat(ys_cat(ys("cannot index "),
                                        tstr(ym_get(br, "typ"))),
                                 ys(" (only arrays)")),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", t_unk(), "st", st);
            }
        }
    } else if (ys_eq_lit(k, "array")) {
        // Heap dynamic array literal [v, ...]. Element type = first element;
        // [] needs an annotation ([T]) since there is nothing to infer from.
        // NOTE: tnone/tname element shapes (from unannotated subexpressions)
        // unify quietly here — the missing-annotation error fires once at
        // its own site, not again at every enclosing literal (tcompat law).
        Yv *elems = ym_get(node, "elems");
        if (yv_len(elems) == 0) {
            return ym(2, "typ", ym(2, "k", ys("tarr"), "of", t_unk()), "st", st);
        } else {
            Yv *e0 = ya_get(elems, 0);
            Yv *r0 = typeof_expr(st, e0);
            st = ym_get(r0, "st");
            if (ys_eq_lit(ym_get(ym_get(r0, "typ"), "k"), "tnone")) {
                return ym(2, "typ", ym(2, "k", ys("tarr"), "of", t_unk()), "st",
                          st);
            } else if (ys_eq_lit(ym_get(ym_get(r0, "typ"), "k"), "tname")) {
                return ym(2, "typ", ym(2, "k", ys("tarr"), "of", t_unk()), "st",
                          st);
            } else if (ys_eq_lit(ym_get(ym_get(r0, "typ"), "k"), "tarr")) {
                // nested array literal [[..], ..]: the inner literal's type
                // IS known, so keep it as the element type ([[1], [2]] :
                // [[long]]) -- that is what lets the checker enforce
                // homogeneity through `+=` / `*=` / `+`. A poisoned inner
                // (tunk inside) still unifies quietly through teq, so the
                // report-once law holds.
                return ym(2, "typ", ym(2, "k", ys("tarr"), "of", ym_get(r0, "typ")),
                          "st", st);
            } else if (ys_eq_lit(ym_get(ym_get(r0, "typ"), "k"), "tnull")) {
                // [null, ..]: option inference is future work — unify quietly.
                return ym(2, "typ", ym(2, "k", ys("tarr"), "of", t_unk()), "st",
                          st);
            } else if (!is_value_type(ym_get(r0, "typ"))) {
                st = fail(st,
                          ys_cat(ys_cat(ys("array element type "),
                                        tstr(ym_get(r0, "typ"))),
                                 ys(" is unsupported in native mode")),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", t_unk(), "st", st);
            } else {
                long i = 1;
                Yv *elt = ym_get(r0, "typ");
                while (i < yv_len(elems)) {
                    Yv *r = typeof_expr(st, ya_get(elems, i));
                    st = ym_get(r, "st");
                    // NOTE: tnone/tname/poison shapes unify quietly (tcompat
                    // law) — the root cause errors once at its own site.
                    // A poisoned FIRST element (tunk) adopts the first known
                    // later element so [f(x), 1] reports only f's own error.
                    if (ys_eq_lit(ym_get(elt, "k"), "tunk")) {
                        if (ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tlong")) {
                            elt = ym_get(r, "typ");
                            ;
                        } else {
                            ;
                        }
                        if (ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tbool")) {
                            elt = ym_get(r, "typ");
                            ;
                        } else {
                            ;
                        }
                        if (ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tstr")) {
                            elt = ym_get(r, "typ");
                            ;
                        } else {
                            ;
                        }
                        ;
                    } else {
                        st = expect_type(st, ym_get(r, "typ"), elt,
                                         ys("array element"),
                                         yv_l(ym_get(node, "line")),
                                         yv_l(ym_get(node, "col")));
                        ;
                    }
                    i = i + 1;
                }
                return ym(2, "typ", ym(2, "k", ys("tarr"), "of", elt), "st", st);
            }
        }
    } else {
        st = fail(st,
                  ys_cat(ys_cat(ys("'"), k),
                         ys("' is unsupported in native mode (heap planned: maps, loops, strings ops)")),
                  yv_l(ym_get(node, "line")), yv_l(ym_get(node, "col")));
        return ym(2, "typ", t_unk(), "st", st);
    }
}

// ++/-- target rule: numbers (long/byte/float) only.
static Yv *incdec_check(Yv *st, Yv *node, Yv *tt) {
    Yv *op = ym_get(node, "op");
    if (ys_eq_lit(ym_get(tt, "k"), "tlong") ||
        ys_eq_lit(ym_get(tt, "k"), "tbyte") ||
        ys_eq_lit(ym_get(tt, "k"), "tfloat")) {
        return ym(2, "typ", tt, "st", st);
    } else if (ys_eq_lit(ym_get(tt, "k"), "tunk") ||
               ys_eq_lit(ym_get(tt, "k"), "tnone")) {
        return ym(2, "typ", t_unk(), "st", st);
    } else {
        st = fail(st,
                  ys_cat(ys_cat(ys_cat(ys("'"), op),
                               ys("' needs a number target, got ")),
                         tstr(tt)),
                  yv_l(ym_get(node, "line")), yv_l(ym_get(node, "col")));
        return ym(2, "typ", t_unk(), "st", st);
    }
}

// `x op= e` rules by target type:
//   numbers  -> the arithmetic family (+ - * / %), result the target type
//   str      -> `+=` concatenates; the rest are errors
//   arrays   -> in place only: `+=` pushes one element (or appends another
//               array of the same type), `*=` prepends one element. `+`
//               itself is the copy form; `-=`, `/=`, `%=` are errors.
// The result is always the target's type (the new value).
static Yv *opassign_check(Yv *st, Yv *node, Yv *tt, Yv *vt) {
    Yv *op = ym_get(node, "op");
    if (ys_eq_lit(ym_get(tt, "k"), "tarrfix")) {
        /* A fixed array's length is part of its type: growth is a type
         * error (the old push-on-fixed rejection, now on the operators). */
        st = fail(st,
                  ys_cat(ys_cat(ys_cat(ys_cat(ys("cannot grow fixed array "),
                                             tstr(tt)),
                                       ys(" with '")),
                                op),
                         ys("' (its length is part of its type; use [T] instead)")),
                  yv_l(ym_get(node, "line")), yv_l(ym_get(node, "col")));
        return ym(2, "typ", tt, "st", st);
    } else if (ys_eq_lit(ym_get(tt, "k"), "tarr")) {
        if (ys_eq_lit(op, "*")) {
            // `*= ` prepends ONE item — its type must be the element type.
            st = expect_type(st, vt, ym_get(tt, "of"), ys("'*=' element"),
                             yv_l(ym_get(node, "line")),
                             yv_l(ym_get(node, "col")));
            return ym(2, "typ", tt, "st", st);
        } else if (ys_eq_lit(op, "+")) {
            if (ys_eq_lit(ym_get(vt, "k"), "tarr") ||
                ys_eq_lit(ym_get(vt, "k"), "tarrfix")) {
                // `arr += arr2` appends arr2's ELEMENTS in place, so the
                // element types must match (homogeneity).
                st = expect_type(st, ym_get(vt, "of"), ym_get(tt, "of"),
                                 ys("'+=' appended elements"),
                                 yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                return ym(2, "typ", tt, "st", st);
            } else if (ys_eq_lit(ym_get(vt, "k"), "tunk") ||
                       ys_eq_lit(ym_get(vt, "k"), "tnone")) {
                return ym(2, "typ", tt, "st", st);
            } else {
                st = expect_type(st, vt, ym_get(tt, "of"), ys("'+=' element"),
                                 yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                return ym(2, "typ", tt, "st", st);
            }
        } else {
            st = fail(st,
                      ys_cat(ys_cat(ys("arrays support only '+=' and '*=' (in place), not '"),
                                    op),
                             ys("='")),
                      yv_l(ym_get(node, "line")), yv_l(ym_get(node, "col")));
            return ym(2, "typ", tt, "st", st);
        }
    } else if (ys_eq_lit(ym_get(tt, "k"), "tstr")) {
        if (ys_eq_lit(op, "+")) {
            st = expect_type(st, vt, ym(1, "k", ys("tstr")), ys("'+=' string"),
                             yv_l(ym_get(node, "line")),
                             yv_l(ym_get(node, "col")));
            return ym(2, "typ", tt, "st", st);
        } else {
            st = fail(st,
                      ys_cat(ys_cat(ys("strings support only '+=' (concatenate), not '"),
                                    op),
                             ys("='")),
                      yv_l(ym_get(node, "line")), yv_l(ym_get(node, "col")));
            return ym(2, "typ", tt, "st", st);
        }
    } else if (ys_eq_lit(ym_get(tt, "k"), "tlong") ||
               ys_eq_lit(ym_get(tt, "k"), "tbyte") ||
               ys_eq_lit(ym_get(tt, "k"), "tfloat")) {
        st = expect_type(st, vt, tt, ys_cat(ys_cat(ys("'"), op), ys("=' value")),
                         yv_l(ym_get(node, "line")),
                         yv_l(ym_get(node, "col")));
        return ym(2, "typ", tt, "st", st);
    } else if (ys_eq_lit(ym_get(tt, "k"), "tunk") ||
               ys_eq_lit(ym_get(tt, "k"), "tnone")) {
        return ym(2, "typ", t_unk(), "st", st);
    } else {
        st = fail(st,
                  ys_cat(ys_cat(ys_cat(ys("'"), op),
                               ys("=' needs a number, string or array target, got ")),
                         tstr(tt)),
                  yv_l(ym_get(node, "line")), yv_l(ym_get(node, "col")));
        return ym(2, "typ", t_unk(), "st", st);
    }
}

static Yv *typeof_call(Yv *st, Yv *node) {
    // callee must be a plain id (direct calls only — no func pointers yet)
    // NOTE: cargs bound once — `node.args[i]` inline misparses on the C VM.
    Yv *cargs = ym_get(node, "args");
    if (!ys_eq_lit(ym_get(ym_get(node, "callee"), "k"), "id")) {
        // Calling an expression: legal when it yields a function value
        // (an immediately-invoked literal, an element of an array of
        // functions, ...). The emitter goes through its code pointer.
        Yv *cf = typeof_expr(st, ym_get(node, "callee"));
        st = ym_get(cf, "st");
        if (ys_eq_lit(ym_get(ym_get(cf, "typ"), "k"), "tfunc")) {
            Yv *cft = ym_get(cf, "typ");
            Yv *cfargs = ym_get(cft, "args");
            if (yv_len(cargs) != yv_len(cfargs)) {
                st = fail(st,
                          ys_cat(ys_cat(ys_cat(ys("call takes "),
                                               ys_long(yv_len(cfargs))),
                                         ys(" args, got ")),
                                ys_long(yv_len(cargs))),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym_get(cft, "ret"), "st", st);
            } else {
                long ci = 0;
                while (ci < yv_len(cargs)) {
                    Yv *ra = typeof_expr(st, ya_get(cargs, ci));
                    st = ym_get(ra, "st");
                    st = expect_type(st, ym_get(ra, "typ"), ya_get(cfargs, ci),
                                     ys_cat(ys("call arg "), ys_long(ci)),
                                     yv_l(ym_get(node, "line")),
                                     yv_l(ym_get(node, "col")));
                    ci = ci + 1;
                }
                return ym(2, "typ", ym_get(cft, "ret"), "st", st);
            }
        } else {
            st = fail(st,
                      ys_cat(ys_cat(ys("cannot call "), tstr(ym_get(cf, "typ"))),
                             ys(" (not a function)")),
                      yv_l(ym_get(node, "line")), yv_l(ym_get(node, "col")));
            long i = 0;
            while (i < yv_len(ym_get(node, "args"))) {
                Yv *r = typeof_expr(st, ya_get(cargs, i));
                st = ym_get(r, "st");
                i = i + 1;
            }
            return ym(2, "typ", t_unk(), "st", st);
        }
    } else {
        Yv *name = ym_get(ym_get(node, "callee"), "v");
        if (ys_eq_lit(name, "print")) {
            if (yv_len(ym_get(node, "args")) != 1) {
                st = fail(st, ys("print takes exactly 1 argument"),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym(1, "k", ys("tvoid")), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = ym_get(r, "st");
                if (ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tlong") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tbyte") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tbool") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tstr") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tfloat") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tunk") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "trec") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tfunc") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tarr") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tarrfix") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tnull") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "topt")) {
                    return ym(2, "typ", ym(1, "k", ys("tvoid")), "st", st);
                } else {
                    st = fail(st,
                              ys_cat(ys("print supports long/bool/float/str/array/record/option, got "),
                                     tstr(ym_get(r, "typ"))),
                              yv_l(ym_get(node, "line")),
                              yv_l(ym_get(node, "col")));
                    return ym(2, "typ", ym(1, "k", ys("tvoid")), "st", st);
                }
            }
        } else if (ys_eq_lit(name, "len")) {
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("len takes exactly 1 argument"),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym(1, "k", ys("tlong")), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = ym_get(r, "st");
                if (ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tarrfix") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tarr") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tstr")) {
                    return ym(2, "typ", ym(1, "k", ys("tlong")), "st", st);
                } else if (ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tunk") ||
                           ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tnone") ||
                           ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tname")) {
                    // poison/unannotated shape (tcompat law): root cause
                    // errors once at its own site; len() unifies quietly.
                    return ym(2, "typ", ym(1, "k", ys("tlong")), "st", st);
                } else {
                    st = fail(st,
                              ys_cat(ys("len supports arrays and strings, got "),
                                     tstr(ym_get(r, "typ"))),
                              yv_l(ym_get(node, "line")),
                              yv_l(ym_get(node, "col")));
                    return ym(2, "typ", ym(1, "k", ys("tlong")), "st", st);
                }
            }
        } else if (ys_eq_lit(name, "some")) {
            // some(v) -> typeof(v)? (boxes v on the heap; 0 = none)
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("some takes exactly 1 argument"),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", t_unk(), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = ym_get(r, "st");
                if (!is_value_type(ym_get(r, "typ"))) {
                    st = fail(st,
                              ys_cat(ys_cat(ys("cannot put "),
                                            tstr(ym_get(r, "typ"))),
                                     ys(" in an option")),
                              yv_l(ym_get(node, "line")),
                              yv_l(ym_get(node, "col")));
                    return ym(2, "typ", t_unk(), "st", st);
                } else {
                    return ym(2, "typ",
                              ym(2, "k", ys("topt"), "of", ym_get(r, "typ")),
                              "st", st);
                }
            }
        } else if (ys_eq_lit(name, "is_some")) {
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("is_some takes exactly 1 argument"),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym(1, "k", ys("tbool")), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = ym_get(r, "st");
                if (ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "topt") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tunk")) {
                    return ym(2, "typ", ym(1, "k", ys("tbool")), "st", st);
                } else {
                    st = fail(st,
                              ys_cat(ys("is_some needs an option, got "),
                                     tstr(ym_get(r, "typ"))),
                              yv_l(ym_get(node, "line")),
                              yv_l(ym_get(node, "col")));
                    return ym(2, "typ", ym(1, "k", ys("tbool")), "st", st);
                }
            }
        } else if (ys_eq_lit(name, "unwrap")) {
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("unwrap takes exactly 1 argument"),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", t_unk(), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = ym_get(r, "st");
                if (ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "topt")) {
                    return ym(2, "typ", ym_get(ym_get(r, "typ"), "of"), "st",
                              st);
                } else if (ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tunk")) {
                    return ym(2, "typ", t_unk(), "st", st);
                } else if (ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tnull")) {
                    // hole shapes (see dot-arm note): unify quietly.
                    return ym(2, "typ", t_unk(), "st", st);
                } else if (ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tnone")) {
                    return ym(2, "typ", t_unk(), "st", st);
                } else if (ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tname")) {
                    return ym(2, "typ", t_unk(), "st", st);
                } else if (ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tparams")) {
                    return ym(2, "typ", t_unk(), "st", st);
                } else {
                    st = fail(st,
                              ys_cat(ys("unwrap needs an option, got "),
                                     tstr(ym_get(r, "typ"))),
                              yv_l(ym_get(node, "line")),
                              yv_l(ym_get(node, "col")));
                    return ym(2, "typ", t_unk(), "st", st);
                }
            }
        } else if (ys_eq_lit(name, "substr")) {
            // substr(s, start, count) -> str (C-clamped semantics)
            if (yv_len(cargs) != 3) {
                st = fail(st,
                          ys("substr takes exactly 3 arguments (string, start, count)"),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", t_unk(), "st", st);
            } else {
                Yv *r0 = typeof_expr(st, ya_get(cargs, 0));
                st = ym_get(r0, "st");
                Yv *r1 = typeof_expr(st, ya_get(cargs, 1));
                st = ym_get(r1, "st");
                Yv *r2 = typeof_expr(st, ya_get(cargs, 2));
                st = ym_get(r2, "st");
                st = expect_type(st, ym_get(r0, "typ"), ym(1, "k", ys("tstr")),
                                 ys("substr string"), yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                st = expect_type(st, ym_get(r1, "typ"), ym(1, "k", ys("tlong")),
                                 ys("substr start"), yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                st = expect_type(st, ym_get(r2, "typ"), ym(1, "k", ys("tlong")),
                                 ys("substr count"), yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym(1, "k", ys("tstr")), "st", st);
            }
        } else if (ys_eq_lit(name, "trim")) {
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("trim takes exactly 1 argument"),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", t_unk(), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = ym_get(r, "st");
                st = expect_type(st, ym_get(r, "typ"), ym(1, "k", ys("tstr")),
                                 ys("trim string"), yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym(1, "k", ys("tstr")), "st", st);
            }
        } else if (ys_eq_lit(name, "ord")) {
            // ord(s) -> long (first byte, -1 if empty)
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("ord takes exactly 1 argument"),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", t_unk(), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = ym_get(r, "st");
                st = expect_type(st, ym_get(r, "typ"), ym(1, "k", ys("tstr")),
                                 ys("ord string"), yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym(1, "k", ys("tlong")), "st", st);
            }
        } else if (ys_eq_lit(name, "byte_at")) {
            // byte_at(s, i) -> long (byte i of s, trapped out of bounds)
            if (yv_len(cargs) != 2) {
                st = fail(st, ys("byte_at takes exactly 2 arguments"),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", t_unk(), "st", st);
            } else {
                Yv *r0 = typeof_expr(st, ya_get(cargs, 0));
                st = ym_get(r0, "st");
                st = expect_type(st, ym_get(r0, "typ"), ym(1, "k", ys("tstr")),
                                 ys("byte_at string"), yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                Yv *r2 = typeof_expr(st, ya_get(cargs, 1));
                st = ym_get(r2, "st");
                st = expect_type(st, ym_get(r2, "typ"), ym(1, "k", ys("tlong")),
                                 ys("byte_at index"), yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym(1, "k", ys("tlong")), "st", st);
            }
        } else if (ys_eq_lit(name, "chr")) {
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("chr takes exactly 1 argument"),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", t_unk(), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = ym_get(r, "st");
                st = expect_type(st, ym_get(r, "typ"), ym(1, "k", ys("tlong")),
                                 ys("chr code"), yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym(1, "k", ys("tstr")), "st", st);
            }
        } else if (ys_eq_lit(name, "tonum")) {
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("tonum takes exactly 1 argument"),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", t_unk(), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = ym_get(r, "st");
                st = expect_type(st, ym_get(r, "typ"), ym(1, "k", ys("tstr")),
                                 ys("tonum string"), yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym(1, "k", ys("tlong")), "st", st);
            }
        } else if (ys_eq_lit(name, "tostring")) {
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("tostring takes exactly 1 argument"),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", t_unk(), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = ym_get(r, "st");
                if (ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tlong") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tbyte") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tbool") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tstr") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tfloat") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tunk") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tarr") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tarrfix") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "trec") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tnull") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "topt")) {
                    return ym(2, "typ", ym(1, "k", ys("tstr")), "st", st);
                } else {
                    st = fail(st,
                              ys_cat(ys("tostring supports long/bool/float/str/array/record/option, got "),
                                     tstr(ym_get(r, "typ"))),
                              yv_l(ym_get(node, "line")),
                              yv_l(ym_get(node, "col")));
                    return ym(2, "typ", t_unk(), "st", st);
                }
            }
        } else if (ys_eq_lit(name, "typeof")) {
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("typeof takes exactly 1 argument"),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", t_unk(), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = ym_get(r, "st");
                return ym(2, "typ", ym(1, "k", ys("tstr")), "st", st);
            }
        } else if (ys_eq_lit(name, "index_of") ||
                   ys_eq_lit(name, "last_index_of")) {
            if (yv_len(cargs) != 2) {
                st = fail(st,
                          ys_cat(name, ys(" takes exactly 2 arguments (string, sub)")),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", t_unk(), "st", st);
            } else {
                Yv *r0 = typeof_expr(st, ya_get(cargs, 0));
                st = ym_get(r0, "st");
                Yv *r1 = typeof_expr(st, ya_get(cargs, 1));
                st = ym_get(r1, "st");
                st = expect_type(st, ym_get(r0, "typ"), ym(1, "k", ys("tstr")),
                                 ys_cat(name, ys(" string")),
                                 yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                st = expect_type(st, ym_get(r1, "typ"), ym(1, "k", ys("tstr")),
                                 ys_cat(name, ys(" sub")),
                                 yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym(1, "k", ys("tlong")), "st", st);
            }
        } else if (ys_eq_lit(name, "join")) {
            // join(arr, delim) -> str (elements via tostring, like C)
            if (yv_len(cargs) != 2) {
                st = fail(st,
                          ys("join takes exactly 2 arguments (array, delimiter)"),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", t_unk(), "st", st);
            } else {
                Yv *r0 = typeof_expr(st, ya_get(cargs, 0));
                st = ym_get(r0, "st");
                Yv *r1 = typeof_expr(st, ya_get(cargs, 1));
                st = ym_get(r1, "st");
                if (!ys_eq_lit(ym_get(ym_get(r0, "typ"), "k"), "tarr") &&
                    !ys_eq_lit(ym_get(ym_get(r0, "typ"), "k"), "tunk")) {
                    st = fail(st,
                              ys_cat(ys("join needs an array, got "),
                                     tstr(ym_get(r0, "typ"))),
                              yv_l(ym_get(node, "line")),
                              yv_l(ym_get(node, "col")));
                    ;
                } else {
                    ;
                }
                st = expect_type(st, ym_get(r1, "typ"), ym(1, "k", ys("tstr")),
                                 ys("join delimiter"), yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym(1, "k", ys("tstr")), "st", st);
            }
        } else if (ys_eq_lit(name, "split")) {
            // split(s, delim) -> [str]
            if (yv_len(cargs) != 2) {
                st = fail(st,
                          ys("split takes exactly 2 arguments (string, delimiter)"),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", t_unk(), "st", st);
            } else {
                Yv *r0 = typeof_expr(st, ya_get(cargs, 0));
                st = ym_get(r0, "st");
                Yv *r1 = typeof_expr(st, ya_get(cargs, 1));
                st = ym_get(r1, "st");
                st = expect_type(st, ym_get(r0, "typ"), ym(1, "k", ys("tstr")),
                                 ys("split string"), yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                st = expect_type(st, ym_get(r1, "typ"), ym(1, "k", ys("tstr")),
                                 ys("split delimiter"), yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym(2, "k", ys("tarr"), "of", ym(1, "k", ys("tstr"))),
                          "st", st);
            }
        } else if (ys_eq_lit(name, "range")) {
            // range(n) -> [long]: 0, 1, ..., n-1
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("range takes exactly 1 argument"),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym(2, "k", ys("tarr"), "of", ym(1, "k", ys("tlong"))),
                          "st", st);
            } else {
                Yv *rr = typeof_expr(st, ya_get(cargs, 0));
                st = expect_type(ym_get(rr, "st"), ym_get(rr, "typ"),
                                 ym(1, "k", ys("tlong")), ys("range count"),
                                 yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym(2, "k", ys("tarr"), "of", ym(1, "k", ys("tlong"))),
                          "st", st);
            }
        } else if (ys_eq_lit(name, "eputs")) {
            // eputs(v) -> void: like puts, but to stderr (fd 2), so
            // diagnostics never mix into program stdout or `-S` output.
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("eputs takes exactly 1 argument"),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym(1, "k", ys("tvoid")), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = ym_get(r, "st");
                if (ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tlong") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tbool") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tstr") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tfloat") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tunk")) {
                    return ym(2, "typ", ym(1, "k", ys("tvoid")), "st", st);
                } else {
                    st = fail(st,
                              ys_cat(ys("eputs supports long/bool/str, got "),
                                     tstr(ym_get(r, "typ"))),
                              yv_l(ym_get(node, "line")),
                              yv_l(ym_get(node, "col")));
                    return ym(2, "typ", ym(1, "k", ys("tvoid")), "st", st);
                }
            }
        } else if (ys_eq_lit(name, "clock_us")) {
            // clock_us() -> long: monotonic microseconds (differences only).
            if (yv_len(cargs) != 0) {
                st = fail(st, ys("clock_us takes no arguments"),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym(1, "k", ys("tlong")), "st", st);
            } else {
                return ym(2, "typ", ym(1, "k", ys("tlong")), "st", st);
            }
        } else if (ys_eq_lit(name, "heap_used")) {
            // heap_used() -> long: arena bytes handed out so far.
            if (yv_len(cargs) != 0) {
                st = fail(st, ys("heap_used takes no arguments"),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym(1, "k", ys("tlong")), "st", st);
            } else {
                return ym(2, "typ", ym(1, "k", ys("tlong")), "st", st);
            }
        } else if (ys_eq_lit(name, "sleep")) {
            // sleep(ms): suspend the caller for ms milliseconds.
            if (yv_len(cargs) != 1) {
                st = fail(st,
                          ys("sleep takes exactly 1 argument (milliseconds)"),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym(1, "k", ys("tnull")), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = ym_get(r, "st");
                st = expect_type(st, ym_get(r, "typ"), ym(1, "k", ys("tlong")),
                                 ys("sleep duration"), yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym(1, "k", ys("tnull")), "st", st);
            }
        } else if (ys_eq_lit(name, "puts")) {
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("puts takes exactly 1 argument"),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym(1, "k", ys("tvoid")), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = ym_get(r, "st");
                if (ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tlong") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tbool") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tstr") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tfloat") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tunk")) {
                    return ym(2, "typ", ym(1, "k", ys("tvoid")), "st", st);
                } else {
                    st = fail(st,
                              ys_cat(ys("puts supports long/bool/str, got "),
                                     tstr(ym_get(r, "typ"))),
                              yv_l(ym_get(node, "line")),
                              yv_l(ym_get(node, "col")));
                    return ym(2, "typ", ym(1, "k", ys("tvoid")), "st", st);
                }
            }
        } else if (ys_eq_lit(name, "exit")) {
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("exit takes exactly 1 argument"),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym(1, "k", ys("tvoid")), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = ym_get(r, "st");
                st = expect_type(st, ym_get(r, "typ"), ym(1, "k", ys("tlong")),
                                 ys("exit code"), yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym(1, "k", ys("tvoid")), "st", st);
            }
        } else if (ys_eq_lit(name, "argv")) {
            if (yv_len(cargs) != 0) {
                st = fail(st, ys("argv takes no arguments"),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym(2, "k", ys("tarr"), "of", ym(1, "k", ys("tstr"))),
                          "st", st);
            } else {
                return ym(2, "typ", ym(2, "k", ys("tarr"), "of", ym(1, "k", ys("tstr"))),
                          "st", st);
            }
        } else if (ys_eq_lit(name, "read_file")) {
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("read_file takes exactly 1 argument (path)"),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", t_unk(), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = ym_get(r, "st");
                st = expect_type(st, ym_get(r, "typ"), ym(1, "k", ys("tstr")),
                                 ys("read_file path"), yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                // NOTE: typed str? (option): a missing file yields null at
                // RUNTIME on both toolchains (callers null-check with
                // `== null`, then unwrap). Matches native.y infer.
                return ym(2, "typ",
                          ym(2, "k", ys("topt"), "of", ym(1, "k", ys("tstr"))),
                          "st", st);
            }
        } else if (ys_eq_lit(name, "bytes")) {
            // bytes(s) -> [byte]: the string's raw bytes, packed.
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("bytes takes exactly 1 argument (string)"),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym(2, "k", ys("tarr"), "of", ym(1, "k", ys("tbyte"))),
                          "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = ym_get(r, "st");
                st = expect_type(st, ym_get(r, "typ"), ym(1, "k", ys("tstr")),
                                 ys("bytes argument"), yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym(2, "k", ys("tarr"), "of", ym(1, "k", ys("tbyte"))),
                          "st", st);
            }
        } else if (ys_eq_lit(name, "from_bytes")) {
            // from_bytes(b) -> str: the inverse of bytes().
            if (yv_len(cargs) != 1) {
                st = fail(st,
                          ys("from_bytes takes exactly 1 argument (byte array)"),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym(1, "k", ys("tstr")), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = ym_get(r, "st");
                st = expect_type(st, ym_get(r, "typ"),
                                 ym(2, "k", ys("tarr"), "of", ym(1, "k", ys("tbyte"))),
                                 ys("from_bytes argument"),
                                 yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym(1, "k", ys("tstr")), "st", st);
            }
        } else if (ys_eq_lit(name, "write_file")) {
            if (yv_len(cargs) != 2) {
                st = fail(st,
                          ys("write_file takes exactly 2 arguments (path, content)"),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", t_unk(), "st", st);
            } else {
                Yv *r0 = typeof_expr(st, ya_get(cargs, 0));
                st = ym_get(r0, "st");
                Yv *r1 = typeof_expr(st, ya_get(cargs, 1));
                st = ym_get(r1, "st");
                st = expect_type(st, ym_get(r0, "typ"), ym(1, "k", ys("tstr")),
                                 ys("write_file path"), yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                st = expect_type(st, ym_get(r1, "typ"), ym(1, "k", ys("tstr")),
                                 ys("write_file content"),
                                 yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym(1, "k", ys("tbool")), "st", st);
            }
        } else if (ys_eq_lit(name, "write_bytes")) {
            // write_bytes(path, bytes, mode) -> bool: tinycc-style binary
            // emit (open/write/chmod over raw syscalls in native code).
            // bytes is a heap [long] array (elf.y output); mode is a long
            // (493 = 0755 executable, -1 = skip chmod).
            if (yv_len(cargs) != 3) {
                st = fail(st,
                          ys("write_bytes takes exactly 3 arguments (path, bytes, mode)"),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", t_unk(), "st", st);
            } else {
                Yv *w0 = typeof_expr(st, ya_get(cargs, 0));
                st = ym_get(w0, "st");
                Yv *w1 = typeof_expr(st, ya_get(cargs, 1));
                st = ym_get(w1, "st");
                Yv *w2 = typeof_expr(st, ya_get(cargs, 2));
                st = ym_get(w2, "st");
                st = expect_type(st, ym_get(w0, "typ"), ym(1, "k", ys("tstr")),
                                 ys("write_bytes path"), yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                if (!ys_eq_lit(ym_get(ym_get(w1, "typ"), "k"), "tarr") &&
                    !ys_eq_lit(ym_get(ym_get(w1, "typ"), "k"), "tunk")) {
                    st = fail(st,
                              ys_cat(ys("write_bytes needs a byte array, got "),
                                     tstr(ym_get(w1, "typ"))),
                              yv_l(ym_get(node, "line")),
                              yv_l(ym_get(node, "col")));
                    ;
                } else {
                    ;
                }
                st = expect_type(st, ym_get(w2, "typ"), ym(1, "k", ys("tlong")),
                                 ys("write_bytes mode"), yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym(1, "k", ys("tbool")), "st", st);
            }
        } else if (ys_eq_lit(name, "ptr_addr")) {
            // ptr_addr(p) -> long: a pointer's numeric value. Pointers ARE
            // longs at run time; this is the one place the type system lets
            // that through, so Y code can build a char** (an array of
            // addresses) without the backend growing a bespoke helper.
            if (yv_len(cargs) != 1) {
                st = fail(st,
                          ys("ptr_addr takes exactly 1 argument (pointer)"),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym(1, "k", ys("tlong")), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = ym_get(r, "st");
                if (ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tptr") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tstr") ||
                    ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tunk")) {
                    return ym(2, "typ", ym(1, "k", ys("tlong")), "st", st);
                } else {
                    st = fail(st,
                              ys_cat(ys("ptr_addr needs a pointer, got "),
                                     tstr(ym_get(r, "typ"))),
                              yv_l(ym_get(node, "line")),
                              yv_l(ym_get(node, "col")));
                    return ym(2, "typ", ym(1, "k", ys("tlong")), "st", st);
                }
            }
        } else if (ys_eq_lit(name, "syscall")) {
            if (yv_len(ym_get(node, "args")) < 1 ||
                yv_len(ym_get(node, "args")) > 7) {
                st = fail(st,
                          ys("syscall needs 1-7 arguments (number + up to 6 args)"),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", ym(1, "k", ys("tlong")), "st", st);
            } else {
                long i = 0;
                while (i < yv_len(ym_get(node, "args"))) {
                    Yv *r = typeof_expr(st, ya_get(cargs, i));
                    st = ym_get(r, "st");
                    if (!ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tlong") &&
                        !ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tbool") &&
                        !ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tstr") &&
                        !ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tptr") &&
                        !ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tunk")) {
                        st = fail(st,
                                  ys_cat(ys_cat(ys_cat(ys("syscall arg "),
                                                     ys_long(i)),
                                               ys(" must be long/bool/str/*T, got ")),
                                        tstr(ym_get(r, "typ"))),
                                  yv_l(ym_get(node, "line")),
                                  yv_l(ym_get(node, "col")));
                        ;
                    } else {
                        ;
                    }
                    i = i + 1;
                }
                return ym(2, "typ", ym(1, "k", ys("tlong")), "st", st);
            }
        } else {
            // resolve the callee to a function type: `self`, then scope
            Yv *fterr = ys("");
            Yv *ft = t_unk();
            if (ys_eq_lit(name, "self")) {
                if (ys_eq_lit(ym_get(ym_get(st, "self"), "k"), "tnone") ||
                    ys_eq_lit(ym_get(ym_get(st, "self"), "k"), "tunk")) {
                    fterr = ys("'self' outside of a function");
                    ;
                } else {
                    ft = ym_get(st, "self");
                    ;
                }
            } else {
                Yv *got = lookup(ym_get(st, "bindings"), name);
                if (ys_eq_lit(ym_get(got, "kind"), "")) {
                    fterr = ys_cat(ys_cat(ys("undefined function '"), disp(name)),
                                   ys("'"));
                    ;
                } else if (ys_eq_lit(ym_get(ym_get(got, "typ"), "k"), "tfunc")) {
                    // Either a hoisted `def` (kind "func") or a local/param
                    // holding a closure value — both are callable.
                    ft = ym_get(got, "typ");
                    ;
                } else {
                    fterr = ys_cat(ys_cat(ys("'"), disp(name)),
                                   ys("' is not a function"));
                    ;
                }
            }
            if (!ys_eq_lit(fterr, "")) {
                st = fail(st, fterr, yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                return ym(2, "typ", t_unk(), "st", st);
            } else if (!ys_eq_lit(ym_get(ft, "k"), "tfunc")) {
                // poisoned binding (tunk) from an earlier error — don't
                // cascade new errors, but still check the arguments for
                // their own errors.
                long i = 0;
                while (i < yv_len(cargs)) {
                    Yv *r = typeof_expr(st, ya_get(cargs, i));
                    st = ym_get(r, "st");
                    i = i + 1;
                }
                return ym(2, "typ", t_unk(), "st", st);
            } else {
                Yv *cargs_ft = ym_get(ft, "args");
                if (yv_len(cargs) != yv_len(cargs_ft)) {
                    st = fail(st,
                              ys_cat(ys_cat(ys_cat(ys_cat(ys_cat(ys("'"),
                                                                 disp(name)),
                                                           ys("' takes ")),
                                                ys_long(yv_len(cargs_ft))),
                                         ys(" args, got ")),
                                ys_long(yv_len(cargs))),
                              yv_l(ym_get(node, "line")),
                              yv_l(ym_get(node, "col")));
                    return ym(2, "typ", ym_get(ft, "ret"), "st", st);
                } else {
                    long i = 0;
                    while (i < yv_len(cargs)) {
                        Yv *r = typeof_expr(st, ya_get(cargs, i));
                        st = ym_get(r, "st");
                        st = expect_type(st, ym_get(r, "typ"),
                                         ya_get(cargs_ft, i),
                                         ys_cat(ys_cat(ys_cat(ys("'"), disp(name)),
                                                       ys("' arg ")),
                                                ys_long(i)),
                                         yv_l(ym_get(node, "line")),
                                         yv_l(ym_get(node, "col")));
                        i = i + 1;
                    }
                    return ym(2, "typ", ym_get(ft, "ret"), "st", st);
                }
            }
        }
    }
}

static Yv *typeof_block(Yv *st, Yv *node) {
    // No scope push: names are unique post-rename, blocks share the frame.
    Yv *last = ym(1, "k", ys("tvoid"));
    Yv *bstmts = ym_get(node, "stmts");
    long i = 0;
    while (i < yv_len(bstmts)) {
        Yv *r = typeof_expr(st, ya_get(bstmts, i));
        st = ym_get(r, "st");
        last = ym_get(r, "typ");
        i = i + 1;
    }
    return ym(2, "typ", last, "st", st);
}

static Yv *typeof_decl(Yv *st, Yv *node) {
    if (ys_eq_lit(ym_get(node, "kind"), "def")) {
        // named function: full check (signature + body)
        return typeof_def(st, ym_get(node, "name"), ym_get(node, "v"),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
    } else {
        // let/const. A literal def on the right names a function WITHOUT
        // going through typeof_expr (a bare func value is only legal bound).
        // Same for the `[v; n]` array literal (binds n frame slots).
        if (ys_eq_lit(ym_get(ym_get(node, "v"), "k"), "func")) {
            Yv *fr = typeof_def(st, ym_get(node, "name"), ym_get(node, "v"),
                                yv_l(ym_get(node, "line")),
                                yv_l(ym_get(node, "col")));
            st = ym_get(fr, "st");
            if (!ys_eq_lit(ym_get(ym_get(node, "typ"), "k"), "tnone")) {
                st = expect_type(st, ym_get(fr, "typ"), ym_get(node, "typ"),
                                 ys_cat(ys_cat(ys("let '"),
                                               disp(ym_get(node, "name"))),
                                        ys("'")),
                                 yv_l(ym_get(node, "line")),
                                 yv_l(ym_get(node, "col")));
                ;
            } else {
                ;
            }
            st = st_bind(st, ym_get(node, "name"), ym_get(fr, "typ"),
                         ys("func"));
            return ym(2, "typ", ym_get(fr, "typ"), "st", st);
        } else if (ys_eq_lit(ym_get(ym_get(node, "v"), "k"), "arrrep")) {
            Yv *r = typeof_expr(st, ym_get(node, "v"));
            st = ym_get(r, "st");
            if (ys_eq_lit(ym_get(ym_get(r, "typ"), "k"), "tunk")) {
                st = st_bind(st, ym_get(node, "name"), t_unk(), ys("local"));
                return ym(2, "typ", t_unk(), "st", st);
            } else {
                Yv *at = ym_get(r, "typ");
                if (!ys_eq_lit(ym_get(ym_get(node, "typ"), "k"), "tnone")) {
                    if (arr_lit_adopts(ym_get(r, "typ"), ym_get(node, "typ"))) {
                        ;
                    } else {
                        st = expect_type(st, ym_get(r, "typ"),
                                         ym_get(node, "typ"),
                                         ys_cat(ys_cat(ys("let '"),
                                                       disp(ym_get(node, "name"))),
                                                ys("'")),
                                         yv_l(ym_get(node, "line")),
                                         yv_l(ym_get(node, "col")));
                        ;
                    }
                    at = ym_get(node, "typ");
                    ;
                } else {
                    ;
                }
                st = st_bind(st, ym_get(node, "name"), at, ys("local"));
                return ym(2, "typ", at, "st", st);
            }
        } else {
            Yv *r = typeof_expr(st, ym_get(node, "v"));
            st = ym_get(r, "st");
            Yv *t = ym_get(r, "typ");
            Yv *vk = ym_get(ym_get(node, "v"), "k");
            if (!ys_eq_lit(ym_get(ym_get(node, "typ"), "k"), "tnone")) {
                if (!is_value_type(ym_get(node, "typ"))) {
                    st = fail(st,
                              ys_cat(ys_cat(ys("annotation '"),
                                            tstr(ym_get(node, "typ"))),
                                     ys("' is not a native value type")),
                              yv_l(ym_get(node, "line")),
                              yv_l(ym_get(node, "col")));
                    ;
                } else if (ys_eq_lit(vk, "array")) {
                    // An array LITERAL adopts the annotated element type:
                    // `let b: [byte] = [104, 105]` packs those elements
                    // into one byte each. Only literals — assigning an
                    // existing [long] to a [byte] binding would reinterpret
                    // eight-byte slots as one, so that still errors.
                    if (arr_lit_adopts(ym_get(r, "typ"), ym_get(node, "typ"))) {
                        ;
                    } else {
                        st = expect_type(st, ym_get(r, "typ"),
                                         ym_get(node, "typ"),
                                         ys_cat(ys_cat(ys("let '"),
                                                       disp(ym_get(node, "name"))),
                                                ys("'")),
                                         yv_l(ym_get(node, "line")),
                                         yv_l(ym_get(node, "col")));
                        ;
                    }
                    t = ym_get(node, "typ");
                    ;
                } else {
                    st = expect_type(st, ym_get(r, "typ"), ym_get(node, "typ"),
                                     ys_cat(ys_cat(ys("let '"),
                                                   disp(ym_get(node, "name"))),
                                            ys("'")),
                                     yv_l(ym_get(node, "line")),
                                     yv_l(ym_get(node, "col")));
                    t = ym_get(node, "typ");
                    ;
                }
                ;
            } else {
                ;
            }
            // NOTE: tnone/tname (unannotated initializer shapes) unify
            // quietly (tcompat law) — the missing annotation errors once at
            // its own site, not again at every enclosing let.
            if (ys_eq_lit(ym_get(t, "k"), "tnone")) {
                t = t_unk();
                ;
            } else if (ys_eq_lit(ym_get(t, "k"), "tname")) {
                t = t_unk();
                ;
            } else if (ys_eq_lit(ym_get(t, "k"), "tvoid")) {
                st = fail(st,
                          ys_cat(ys_cat(ys("cannot bind a void value to '"),
                                        disp(ym_get(node, "name"))),
                                 ys("'")),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                t = t_unk();
                ;
            } else if (!is_value_type(t)) {
                st = fail(st,
                          ys_cat(ys_cat(ys("'"), tstr(t)),
                                 ys("' is unsupported in native mode (heap planned)")),
                          yv_l(ym_get(node, "line")),
                          yv_l(ym_get(node, "col")));
                t = t_unk();
                ;
            } else {
                ;
            }
            st = st_bind(st, ym_get(node, "name"), t, ys("local"));
            return ym(2, "typ", t, "st", st);
        }
    }
}

// Check a func value bound to `name` (def decl or let-bound anonymous def).
// Returns updated st; binds name as kind "func" with its tfunc type.
static Yv *typeof_def(Yv *st, Yv *name, Yv *func, long line, long col) {
    if (yv_len(ym_get(func, "params")) != yv_len(ym_get(func, "ptypes"))) {
        st = fail(st, ys("internal: params/ptypes length mismatch"), line, col);
        return ym(2, "typ", t_unk(), "st", st);
    } else {
        Yv *args = yav(0);
        // NOTE: bound once — `func.params[i]` inline misparses on the C VM.
        Yv *fparams = ym_get(func, "params");
        Yv *fptypes = ym_get(func, "ptypes");
        long i = 0;
        int ok = 1;
        while (i < yv_len(fparams)) {
            Yv *pt = ya_get(fptypes, i);
            if (ys_eq_lit(ym_get(pt, "k"), "tnone")) {
                // OPTIONAL ANNOTATIONS v1: a missing param annotation is a
                // poison-tolerant unknown (t_unk). This covers BOTH the ycc
                // pipeline's bare-hole plumbing params (the C parser cannot
                // annotate record shapes on them) AND user-written defs
                // without annotations — holes and user params now type
                // identically. Caveat: the emitter has no runtime tag, so a
                // richer value (str/record) flowing into an unannotated
                // param behaves as a plain long there; annotate those sites.
                pt = t_unk();
                ;
            } else if (!is_value_type(pt) &&
                       !ys_eq_lit(ym_get(pt, "k"), "tfunc")) {
                st = fail(st,
                          ys_cat(ys_cat(ys_cat(ys_cat(ys("parameter '"),
                                                      disp(ya_get(fparams, i))),
                                                ys("' has unpassable type ")),
                                         tstr(pt)),
                                ys(" (arrays cannot cross function boundaries — pass &a plus a length)")),
                          line, col);
                ok = 0;
                ;
            } else {
                ;
            }
            args = ya_push(args, pt);
            i = i + 1;
        }
        Yv *ret = ym_get(func, "ret");
        int ret_inferred = 0;
        if (ys_eq_lit(ym_get(ret, "k"), "tnone")) {
            // OPTIONAL ANNOTATIONS + inference v1: the return type comes
            // from the body's tail value once the body has been checked.
            // Until then the signature carries poison tunk so recursion
            // and forward calls still unify.
            ret_inferred = 1;
            ret = t_unk();
            ;
        } else {
            ;
        }
        Yv *ft = ym(3, "k", ys("tfunc"), "args", args, "ret", ret);
        // bind early so recursion via `self`/name works
        st = st_bind(st, name, ft, ys("func"));
        // check the body one level deeper. Outer locals/params stay in the
        // flat map but with a smaller fdepth: touching one is a capture
        // (there is no heap for environments yet).
        Yv *saved_self = ym_get(st, "self");
        Yv *saved_ret = ym_get(st, "ret");
        long saved_depth = yv_l(ym_get(st, "fdepth"));
        st = st_fdepth(st, saved_depth + 1);
        long j = 0;
        while (j < yv_len(fparams)) {
            st = st_bind(st, ya_get(fparams, j), ya_get(args, j), ys("param"));
            j = j + 1;
        }
        st = st_self(st, ft);
        st = st_ret(st, ret);
        Yv *b = typeof_block(st, ym_get(func, "body"));
        st = ym_get(b, "st");
        if (ret_inferred) {
            // INFERENCE: the def's return type is the body's tail value.
            // Unannotated sub-shapes (tnone) stay poison; tunk stays tunk.
            Yv *br = ym_get(b, "typ");
            if (ys_eq_lit(ym_get(br, "k"), "tnone")) {
                br = t_unk();
                ;
            } else {
                ;
            }
            ft = ym(3, "k", ys("tfunc"), "args", args, "ret", br);
            st = st_bind(st, name, ft, ys("func"));
            ;
        } else {
            ;
        }
        if (!(ret_inferred)) {
            st = expect_type(st, ym_get(b, "typ"), ret,
                             ys_cat(ys_cat(ys("'"), disp(name)), ys("' body")),
                             line, col);
            ;
        } else {
            ;
        }
        st = st_fdepth(st, saved_depth);
        st = st_self(st, saved_self);
        st = st_ret(st, saved_ret);
        if (ok) {
            return ym(2, "typ", ft, "st", st);
        } else {
            // poison the binding so follow-on errors don't cascade weirdly
            st = st_bind(st, name, t_unk(), ys("func"));
            return ym(2, "typ", t_unk(), "st", st);
        }
    }
}

static Yv *st_fdepth(Yv *st, long d) {
    return ym(5, "bindings", ym_get(st, "bindings"), "errors", ym_get(st, "errors"),
              "ret", ym_get(st, "ret"), "self", ym_get(st, "self"),
              "fdepth", yv_long(d));
}

static Yv *check_func_value(Yv *st, Yv *name, Yv *func, long line, long col) {
    // let-bound anonymous def: same rules as a named def
    Yv *r = typeof_def(st, name, func, line, col);
    return ym_get(r, "st");
}

// ── entry point ──────────────────────────────────────────────────────────

Yv *check_program(Yv *ast) {
    // pass 1: collect top-level def signatures (allows mutual recursion).
    Yv *defs = yav(0);
    Yv *pstmts = ym_get(ast, "stmts");
    long i = 0;
    while (i < yv_len(pstmts)) {
        Yv *s = ya_get(pstmts, i);
        // NOTE: nested ifs, not `&&`: the VM evaluates both sides eagerly,
        // so `s.kind`/`s.v.k` on a non-decl node would crash.
        if (ys_eq_lit(ym_get(s, "k"), "decl")) {
            if (ys_eq_lit(ym_get(s, "kind"), "def")) {
                defs = ya_push(defs, def_sig(ym_get(s, "name"), ym_get(s, "v")));
                ;
            } else if (ys_eq_lit(ym_get(ym_get(s, "v"), "k"), "func")) {
                // top-level let f = def... : also hoisted for mutual recursion
                defs = ya_push(defs, def_sig(ym_get(s, "name"), ym_get(s, "v")));
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
    // pass 2: check everything in order (depth 0 = top level)
    Yv *st = ym(5, "bindings", yav(0), "errors", yav(0), "ret",
                ym(1, "k", ys("tnone")), "self", ym(1, "k", ys("tnone")),
                "fdepth", yv_long(0));
    // intrinsics + top-level defs are visible at top level
    st = st_bind(st, ys("print"),
                 ym(3, "k", ys("tfunc"), "args", yav(1, ym(1, "k", ys("tlong"))),
                    "ret", ym(1, "k", ys("tvoid"))),
                 ys("intrinsic"));
    st = st_bind(st, ys("syscall"), ym(1, "k", ys("tlong")), ys("intrinsic"));
    // (len/syscall specials are matched by name in typeof_call)
    long d = 0;
    while (d < yv_len(defs)) {
        st = st_bind(st, ym_get(ya_get(defs, d), "name"),
                     ym_get(ya_get(defs, d), "typ"), ys("func"));
        d = d + 1;
    }
    Yv *r = typeof_block(st, ast);
    return ym_get(ym_get(r, "st"), "errors");
}

static Yv *def_sig(Yv *name, Yv *func) {
    // Signature for the pre-pass. Missing annotations are poison (tunk);
    // pass 2 (typeof_def) reports each exactly once.
    Yv *args = yav(0);
    Yv *fpt = ym_get(func, "ptypes");
    long i = 0;
    while (i < yv_len(ym_get(func, "params"))) {
        Yv *pt = ya_get(fpt, i);
        if (ys_eq_lit(ym_get(pt, "k"), "tnone")) {
            pt = t_unk();
        }
        args = ya_push(args, pt);
        i = i + 1;
    }
    Yv *ret = ym_get(func, "ret");
    if (ys_eq_lit(ym_get(ret, "k"), "tnone")) {
        ret = t_unk();
    }
    return ym(2, "name", name,
              "typ", ym(3, "k", ys("tfunc"), "args", args, "ret", ret));
}
