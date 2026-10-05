/* types.c — static type checker for the native backend.
 * 1:1 port of src/y/types.y (PORTING.md is the contract).
 * Usage: Yv *errors = check_program(ast, ext);  // [] means OK
 * Each error: { msg: str, line: long, col: long }.
 *
 * Supported types: long, byte, float, bool, str, void, options T? (the
 * empty case is `none`), *T (pointers), arrays [T] / [T; N], records
 * {f: T}, maps {K => V}, unions A | B (every member a record) and
 * (T, ...) -> R functions. Anything else is rejected with a clear error,
 * not silently miscompiled.
 *
 * Rules (native mode):
 * - def param and return annotations are OPTIONAL: a missing one is the
 *   poison tunk (typeof_def), and a missing return is inferred from the
 *   body's tail value.
 * - let/const without annotation is inferred from the initializer.
 * - A nested def may read an enclosing local/param: that is a CAPTURE, and
 *   the emitter closure-converts it into a heap cell shared by the binding
 *   and every closure over it (native.y box_capture), so a write inside is
 *   visible outside.
 * - `if` conditions must be bool. Matching arms keep their value type;
 *   mismatched arms make the `if` void. An `if` without `else` is void.
 * - print takes exactly one long/bool/float/str/array/record/map/option/
 *   union/function. syscall takes 1-7 long/bool/str/\*T.
 * - Assignment targets keep their declared type. The only implicit
 *   conversions are the numeric widenings (see tcompat).
 *
 * Translation conventions (see PORTING.md): records are yr() maps read
 * with yr_get; type nodes are { k: "tarr", of: ... } maps; checker state
 * st = { bindings, errors, ret, self, fdepth } and typeof_* results
 * { typ, st } are Yv * maps; long/bool scalars cross the record boundary
 * boxed with yv_long()/yv_bool() and read out with yv_l()/yv_b(). The
 * `0;` value-tails of Y if-arms are `;` here; tail values of blocks in
 * return position are `return`. */
#include "types.h"
#include "target.h"
#include "yv.h"
#include "tags.h"

/* parser.c's name index (NameIx, lookup below) */
Yv *nameix_new(long cap);
void nameix_put(Yv *m, Yv *k, long v);
long nameix_get(Yv *m, Yv *k);

/* imported — types.y imports parser.y for its Field, Node and Type aliases
 * (a record is a Yv * here): every call below is a builtin
 * (len/push/index_of/join/tostring) or a def of this file. */

/* forward declarations (Y defs are mutually visible) */
static Yv *err_at(Yv *msg, long line, long col);
static Yv *t_unk(void);
static Yv *type_node(Yv *t);
static Yv *tc_res(Yv *typ, Yv *st);
static Yv *t_free(void);
static Yv *t_pend(void);
static Yv *t_pend_self(void);
static Yv *call_result(Yv *ft);
static int has_free(Yv *t);
static int ret_pending(Yv *t);
static int ret_unknown(Yv *t);
static Yv *map_type_of(Yv *v);
static int teq_fields(Yv *af, Yv *bf, long i);
static int teq_list(Yv *aa, Yv *bb, long i);
static int teq_members(Yv *ua, Yv *ub, long i);
static void union_parts_go(Yv *out, Yv *t, long depth);
static int teq_ref(Yv *a, Yv *b);
static Yv *tcanon_go(Yv *out, Yv *t, Yv *stack);
static int str_in(Yv *xs, Yv *s);
static Yv *trec_field_type(Yv *rec, Yv *key);
static Yv *tstr_go(Yv *t);
static int num_is_float(Yv *s);
static long num_net_exp(Yv *s);
static int is_value_type(Yv *t);
static int t_poisoned(Yv *t);
static int t_poisoned_go(Yv *t, long d);
static int is_hash_key(Yv *t);
static Yv *lookup(Yv *bindings, Yv *name);
static Yv *st_bind(Yv *st, Yv *name, Yv *typ, Yv *kind);
static Yv *st_errors(Yv *st, Yv *errs);
static Yv *st_self(Yv *st, Yv *selfv);
static Yv *st_ret(Yv *st, Yv *ret);
static Yv *fail(Yv *st, Yv *msg, long line, long col);
static Yv *disp(Yv *name);
static Yv *check_visible(Yv *st, Yv *got, Yv *name, long line, long col);
static Yv *expect_type(Yv *st, Yv *got, Yv *want, Yv *what, long line, long col);
static int cast_ok(Yv *got, Yv *want);
static Yv *expect_cast(Yv *st, Yv *got, Yv *want, Yv *what, long line, long col);
static Yv *expect_arg(Yv *st, Yv *got, Yv *want, Yv *arg, Yv *what, long line, long col);
static int is_some_call(Yv *n);
static Yv *typeof_arith(Yv *st, Yv *op, Yv *lt, Yv *rt, long line, long col);
static Yv *typeof_arith_arr(Yv *st, Yv *op, Yv *lt, Yv *rt, long line, long col);
Yv *arr_plus_kind(Yv *lt, Yv *rt);
/* `x :: a` -- cons: a NEW array with x prepended as exactly ONE element
 * (unlike `elem + a`, an array-typed element is never spliced). The right
 * operand must be an array; the left must be its element type. */
static Yv *typeof_cons(Yv *st, Yv *lt, Yv *rt, long line, long col) {
    if (yv_l(yr_get(rt, "k")) == K_tarr ||
        yv_l(yr_get(rt, "k")) == K_tarrfix) {
        st = expect_type(st, lt, yr_get(rt, "of"), ys("'::' element"), line, col);
        return yr(2, "typ", yr(2, "k", yv_long(K_tarr), "of", yr_get(rt, "of")),
                  "st", st);
    } else {
        st = fail(st,
                  ys_cat(ys_cat(ys("'::' needs an array on the right, got "),
                                tstr(rt)),
                         ys("")),
                  line, col);
        return yr(2, "typ", t_unk(), "st", st);
    }
}

static Yv *typeof_arith_long(Yv *st, Yv *op, Yv *lt, Yv *rt, long line, long col);
int is_bits_op(Yv *op);
static Yv *typeof_bits(Yv *st, Yv *op, Yv *lt, Yv *rt, long line, long col);
static Yv *typeof_cmp(Yv *st, Yv *op, Yv *lt, Yv *rt, long line, long col);
static int is_num_kind(Yv *t);
static int num_eq_ok(Yv *lt, Yv *rt);
static Yv *typeof_eq(Yv *st, Yv *op, Yv *lt, Yv *rt, long line, long col);
static Yv *typeof_logic(Yv *st, Yv *op, Yv *lt, Yv *rt, long line, long col);
static int tcompat(Yv *got, Yv *want);
static int arr_lit_adopts(Yv *got, Yv *want, Yv *n);
static int arr_lit_adopts_go(Yv *got, Yv *want, Yv *n);
static Yv *typeof_expr(Yv *st, Yv *node);
static Yv *incdec_check(Yv *st, Yv *node, Yv *tt);
static Yv *opassign_check(Yv *st, Yv *node, Yv *tt, Yv *vt);
/* The named syscall layer: the names std code may reach the kernel through,
   and the only list of them. `os_call` (the checker arm below, native.c's emit
   arm) resolves a call against this list and emits a `call` to the label; the
   bodies live in src/y/arch/prelude.s on Linux and in src/y/arch/wsys.s on
   Windows.

   ONE list, with no target branch, and that is the load-bearing property
   rather than a simplification. The four embedded std units (rt, prelude, exec,
   str) are compiled ONCE per compiler and serialized into a single std pack,
   so anything a std unit resolves at COMPILE time -- a syscall number, a struct
   layout, a branch on the target -- is baked for whichever target wrote that
   pack, and --target on the consuming compiler cannot undo it. A NAME is the one
   thing that survives: rt.y saying os_call("y_os_write", fd, s, len(s))
   compiles to the same bytes for both targets, and the arch module decides
   which kernel call that label is. Measured both ways, with a conditional in
   rt.y instead: a PE built from the pack carried the ELF inline write(2) and
   printed nothing, while --std-src (which recompiles the units) worked.

   The list lives here, beside the checker that enforces it, because types.y is
   the one module that must not import arch_x64.y: a path import is flattened
   into its importer, so both would define the same names and the second would
   win. native.c, which sees both, checks that every name here is a label the
   emitted arch lines actually define (native.c check_os_call_names). */
static int os_call_name(Yv *nm) {
    Yv *names = os_call_names();
    long i = 0;
    int found = 0;
    while (i < yv_len(names)) {
        if (ys_eq(ya_get(names, i), nm)) { found = 1; }
        i = i + 1;
    }
    return found;
}

Yv *os_call_names(void) {
    return yav(5, ys("y_os_write"), ys("y_os_read"), ys("y_os_wait4"),
               ys("y_os_fork"), ys("y_os_execve"));
}

static Yv *typeof_call(Yv *st, Yv *node);
static int os_call_name(Yv *nm);
Yv *os_call_names(void);
static Yv *typeof_block(Yv *st, Yv *node);
static Yv *typeof_block_want(Yv *st, Yv *node, Yv *want);
static Yv *typeof_want(Yv *st, Yv *node, Yv *want);
static int same_names(Yv *t, Yv *keys);
static int lit_fits(Yv *t, Yv *keys);
static int field_opt(Yv *t, Yv *key);
static Yv *typeof_lit(Yv *st, Yv *node, Yv *target);
static Yv *typeof_expr_go(Yv *st, Yv *node);
static Yv *typeof_decl(Yv *st, Yv *node);
static Yv *typeof_def(Yv *st, Yv *name, Yv *func, long line, long col);
static long ret_note(Yv *rl, Yv *typ, long line, long col);
static long set_inferred_ret(Yv *func, Yv *ret);
static Yv *st_fdepth(Yv *st, long d);
static Yv *def_sig(Yv *name, Yv *func);
static Yv *tstr_union(Yv *ts, Yv *sep);
static int rec_has_names(Yv *r, Yv *names);
static int union_ok(Yv *t);
static int union_accepts(Yv *got, Yv *want);
static Yv *typeof_rectest(Yv *st, Yv *node);
static int pattern_fits(Yv *s, Yv *t);
static Yv *typeof_narrow(Yv *st, Yv *node);
static Yv *typeof_matchend(Yv *st, Yv *node);
static int covered(Yv *m, Yv *cover);
static Yv *union_field(Yv *st, Yv *t, Yv *dkey, long line, long col);
static Yv *dotassign_union(Yv *st, Yv *t, Yv *node);
static Yv *typeof_sliceassign(Yv *st, Yv *node);
static Yv *typeof_prop(Yv *st, Yv *t, Yv *key, long line, long col);
static Yv *typeof_field(Yv *st, Yv *t, Yv *dkey, long line, long col);
static Yv *sm_mk(Yv *fn, Yv *params, long nreq, Yv *ret, Yv *dflt, int last);
static Yv *sm_t(Yv *k);
static Yv *sm_arr(Yv *of);
static Yv *sm_any(void);
static int sm_accepts(Yv *got, Yv *want);
static int fmt_align(long c);
static int fmt_digit(long c);
static int fmt_type(long c);
static long fmt_number(Yv *spec, long a, long b);
static Yv *fmt_check(Yv *f, long kind, Yv *tname);
static Yv *const_check(Yv *st, Yv *tgt, Yv *tt, Yv *op, long line, long col);
static Yv *place_check(Yv *st, Yv *tgt, Yv *tt, Yv *op, long line, long col);
static Yv *base_type(Yv *st, Yv *e);

static Yv *err_at(Yv *msg, long line, long col) {
    return yr(3, "msg", msg, "line", yv_long(line), "col", yv_long(col));
}

// ── types ────────────────────────────────────────────────────────────────
// Type nodes come from the parser: tlong/tbool/tstr/tvoid/tnone/tname,
// tptr {to}, tarr {of}, tfunc {args, ret}, trec {fields: [{name, typ}]},
// tparams. Internal only: tunk (error poison, unifies with everything),
// trec (checked record type {fields: [{name, typ}]} — same shape as the
// parser's trec; teq compares the fields as a set, by name), tref (a
// recursive alias, rename.y: see "recursive types" below).

static Yv *t_unk(void) {
    return yr(1, "k", yv_long(K_tunk));
}

/* The types of a mutex and a semaphore (CHOICES_MADE.md 33): records no
 * program can spell (a `$` in each field's name), written `mutex` and
 * `sem` (parser.c parse_type_atom2). A mutex's word is 1 while held; a
 * semaphore's count is guarded by its own lock word. */
Yv *t_mutex(void) {
    Yv *fs = yav(0);
    fs = ya_push(fs, yr(3, "name", ys("$m"), "opt", yv_bool(0), "typ", yr(1, "k", yv_long(K_tlong))));
    fs = ya_push(fs, yr(3, "name", ys("$o"), "opt", yv_bool(0), "typ", yr(1, "k", yv_long(K_tlong))));
    return yr(2, "k", yv_long(K_trec), "fields", fs);
}

Yv *t_sem(void) {
    Yv *fs = yav(0);
    fs = ya_push(fs, yr(3, "name", ys("$n"), "opt", yv_bool(0), "typ", yr(1, "k", yv_long(K_tlong))));
    fs = ya_push(fs, yr(3, "name", ys("$w"), "opt", yv_bool(0), "typ", yr(1, "k", yv_long(K_tlong))));
    fs = ya_push(fs, yr(3, "name", ys("$o"), "opt", yv_bool(0), "typ", yr(1, "k", yv_long(K_tlong))));
    return yr(2, "k", yv_long(K_trec), "fields", fs);
}

/* The parameter types of a function type. */
static Yv *fn_args(Yv *t) {
    return yr_get(t, "args");
}

static Yv *type_node(Yv *t) {
    return t;
}

static Yv *tc_res(Yv *typ, Yv *st) {
    return yr(2, "typ", typ, "st", st);
}

// `[]` or `none` where no type is declared: the element or payload is not
// known, so it unifies like tunk, but a binding or an inferred return of a
// type with one inside needs an annotation (has_free) -- error poison
// (plain tunk) stays quiet.
static Yv *t_free(void) {
    return yr(2, "k", yv_long(K_tunk), "free", yv_bool(1));
}

// A def's return type before it is known: a call to it then (a forward
// call) needs the return type annotated.
static Yv *t_pend(void) {
    return yr(3, "k", yv_long(K_tpend), "self", yv_bool(0), "used", yv_bool(0));
}

// The return type of a def while its body is checked to infer it: a call
// to the def from its own body gives an unknown and notes itself
// (call_result), and typeof_def checks the body again with the type the
// rest of the body gave.
static Yv *t_pend_self(void) {
    return yr(3, "k", yv_long(K_tpend), "self", yv_bool(1), "used", yv_bool(0));
}

static int has_free(Yv *t) {
    Yv *k = yr_get(t, "k");
    if (yv_l(k) == K_tunk) {
        return yr_has(t, "free");
    } else if (yv_l(k) == K_tarr || yv_l(k) == K_tarrfix ||
               yv_l(k) == K_topt) {
        return has_free(yr_get(t, "of"));
    } else if (yv_l(k) == K_tptr) {
        return has_free(yr_get(t, "to"));
    } else if (yv_l(k) == K_tmap) {
        return has_free(yr_get(t, "key")) || has_free(yr_get(t, "of"));
    } else if (yv_l(k) == K_trec) {
        Yv *fs = yr_get(t, "fields");
        long i = 0;
        while (i < yv_len(fs)) {
            if (has_free(yr_get(ya_get(fs, i), "typ"))) {
                return 1;
            }
            i = i + 1;
        }
        return 0;
    } else if (yv_l(k) == K_tunion) {
        Yv *ts = yr_get(t, "ts");
        long i = 0;
        while (i < yv_len(ts)) {
            if (has_free(ya_get(ts, i))) {
                return 1;
            }
            i = i + 1;
        }
        return 0;
    } else if (yv_l(k) == K_tfunc) {
        Yv *as = yr_get(t, "args");
        long i = 0;
        while (i < yv_len(as)) {
            if (has_free(ya_get(as, i))) {
                return 1;
            }
            i = i + 1;
        }
        return has_free(yr_get(t, "ret"));
    } else {
        return 0;
    }
}

// A function type whose return type is not known yet (t_pend), and not
// the def being inferred (t_pend_self) calling itself.
static int ret_pending(Yv *t) {
    return yv_l(yr_get(t, "k")) == K_tfunc &&
           yv_l(yr_get(yr_get(t, "ret"), "k")) == K_tpend &&
           !yv_b(yr_get(yr_get(t, "ret"), "self"));
}

// A function type whose return type is not known yet, the def being
// inferred included: its name (or `self`) used as a value.
static int ret_unknown(Yv *t) {
    return yv_l(yr_get(t, "k")) == K_tfunc &&
           yv_l(yr_get(yr_get(t, "ret"), "k")) == K_tpend;
}

// The type of a call to ft: its return type; a def calling itself while
// its return type is inferred gets an unknown, and the def is checked
// again (typeof_def).
static Yv *call_result(Yv *ft) {
    Yv *r = yr_get(ft, "ret");
    if (yv_l(yr_get(r, "k")) == K_tpend) {
        yr_set(r, "used", yv_bool(1));
        return t_unk();
    } else {
        return r;
    }
}

// A map type node ({K => V}). Returns through a {k: str} annotation so
// the value's flow type is the unknown-shape marker: typeof_expr's if
// arms only agree through such holes (see teq note), and a concrete
// {k, key, of} shape here would disagree with the rec arm's {k, fields}.
static Yv *map_type_of(Yv *v) {
    return yr(3, "k", yv_long(K_tmap), "key", yr(1, "k", yv_long(K_tstr)), "of", v);
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
    // the same type node (a recursive alias is one shared node, and unfolds
    // to one union every time): equal, without spelling out canonical forms
    // or comparing a big union member by member
    if (a == b) {
        return 1;
    }
    Yv *ak = yr_get(a, "k");
    Yv *bk = yr_get(b, "k");
    if (yv_l(ak) == K_tunk) {
        return 1;
    } else if (yv_l(bk) == K_tunk) {
        return 1;
    } else if (yv_l(ak) != yv_l(bk)) {
        if (yv_l(ak) == K_tref || yv_l(bk) == K_tref) {
            return teq_ref(a, b);
        } else {
            return 0;
        }
    } else if (yv_l(ak) == K_tnone) {
        return 1;
    } else if (yv_l(bk) == K_tnone) {
        return 1;
    } else if (yv_l(ak) == K_tname) {
        return 1;
    } else if (yv_l(bk) == K_tname) {
        return 1;
    } else if (yv_l(ak) == K_tparams) {
        return 1;
    } else if (yv_l(bk) == K_tparams) {
        return 1;
    } else if (yv_l(ak) == K_tptr) {
        return teq(yr_get(a, "to"), yr_get(b, "to"));
    } else if (yv_l(ak) == K_tarr) {
        return teq(yr_get(a, "of"), yr_get(b, "of"));
    } else if (yv_l(ak) == K_tarrfix) {
        if (yv_l(yr_get(a, "n")) == yv_l(yr_get(b, "n"))) {
            return teq(yr_get(a, "of"), yr_get(b, "of"));
        } else {
            return 0;
        }
    } else if (yv_l(ak) == K_tmap) {
        // map types: same key type, equal value types.
        if (teq(yr_get(a, "key"), yr_get(b, "key"))) { return teq(yr_get(a, "of"), yr_get(b, "of")); } else { return 0; }
    } else if (yv_l(yr_get(a, "k")) == K_topt) {
        return teq(yr_get(a, "of"), yr_get(b, "of"));
    } else if (yv_l(yr_get(a, "k")) == K_trec) {
        // record types: the same set of fields with pairwise-equal types;
        // the order they are written in is not part of the type (a record
        // is laid out by field name, NATIVE.md "Records"). tunk fields
        // unify -- error poison never cascades.
        // NOTE: each bound once — the checker env is flow-INSENSITIVE (one
        // shape per name, last wins), so a name read inline here would merge
        // the `fields` shape of a, b and every other arm in teq.
        Yv *af = yr_get(a, "fields");
        Yv *bf = yr_get(b, "fields");
        if (yv_len(af) != yv_len(bf)) {
            return 0;
        } else {
            return teq_fields(af, bf, 0);
        }
    } else if (yv_l(ak) == K_tfunc) {
        if (yv_len(yr_get(a, "args")) != yv_len(yr_get(b, "args"))) {
            return 0;
        } else {
            int ok = teq(yr_get(a, "ret"), yr_get(b, "ret"));
            Yv *aa = yr_get(a, "args");
            Yv *bb = yr_get(b, "args");
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
    } else if (yv_l(ak) == K_tunion) {
        // unions: the same members, in any order
        Yv *ua = union_parts(a);
        Yv *ub = union_parts(b);
        if (yv_len(ua) != yv_len(ub)) {
            return 0;
        } else if (teq_members(ua, ub, 0)) {
            return teq_members(ub, ua, 0);
        } else {
            return 0;
        }
    } else if (yv_l(ak) == K_tref) {
        return teq_ref(a, b);
    } else {
        return 1;
    }
}

// ── recursive types and canonical forms ──────────────────────────────────
// A recursive alias reaches the checker spelled out once, its references
// back to itself trefs ({k: "tref", name, tmp, to}, rename.y RnRef): `to`
// is the alias spelled out, `tmp` names the alias within the unit. Where a
// type is looked into, a tref is unfolded first: typeof_expr's results,
// tcompat's sides, a union's members (members).

// t, or the type a tref stands for.
Yv *unfold(Yv *t) {
    if (yv_l(yr_get(t, "k")) == K_tref) {
        return yr_get(t, "to");
    } else {
        return t;
    }
}

// A union's members as written -- a recursive alias that is a member
// stays its tref (its canonical form names the member, native.y ty_desc)
// -- with an alias of a union among them flattened in.
Yv *union_parts(Yv *t) {
    Yv *out = yav(0);
    union_parts_go(out, t, 0);
    return out;
}

static void union_parts_go(Yv *out, Yv *t, long depth) {
    Yv *ms = yr_get(t, "ts");
    long i = 0;
    while (i < yv_len(ms)) {
        Yv *m = ya_get(ms, i);
        Yv *u = unfold(m);
        if (yv_l(yr_get(u, "k")) == K_tunion && depth < 16) {
            union_parts_go(out, u, depth + 1);
        } else {
            ya_push(out, m);
        }
        i = i + 1;
    }
}

// A union's members, unfolded (union_parts).
Yv *members(Yv *t) {
    Yv *ps = union_parts(t);
    Yv *out = yav(0);
    long i = 0;
    while (i < yv_len(ps)) {
        out = ya_push(out, unfold(ya_get(ps, i)));
        i = i + 1;
    }
    return out;
}

// The members of union s, as written, with every field of the record
// pattern t.
Yv *pat_members(Yv *s, Yv *t) {
    Yv *ps = union_parts(s);
    Yv *names = yr_get(t, "names");
    Yv *out = yav(0);
    long i = 0;
    while (i < yv_len(ps)) {
        if (rec_has_names(unfold(ya_get(ps, i)), names)) {
            out = ya_push(out, ya_get(ps, i));
        }
        i = i + 1;
    }
    return out;
}

// teq with a recursive alias on a side: two trefs are equal when their
// canonical forms are; a tref against a type written out (a literal of a
// recursive record type, say) is unfolded, at most 64 levels deep.
static long teq_unfolds;
// Two recursive aliases whose types visibly differ -- other kinds, or
// records of other field names -- have other canonical forms: teq_ref
// answers without spelling them out (long, for a big recursive union).
static int ref_shapes_differ(Yv *a, Yv *b) {
    Yv *ua = unfold(a);
    Yv *ub = unfold(b);
    Yv *uak = yr_get(ua, "k");
    Yv *ubk = yr_get(ub, "k");
    if (yv_l(uak) != yv_l(ubk)) {
        return 1;
    } else if (yv_l(uak) == K_trec) {
        return !same_names(ua, rec_names(yr_get(ub, "fields")));
    } else {
        return 0;
    }
}

static int teq_ref(Yv *a, Yv *b) {
    if (yv_l(yr_get(a, "k")) == K_tref && yv_l(yr_get(b, "k")) == K_tref) {
        if (ref_shapes_differ(a, b)) {
            return 0;
        } else {
            return ys_eq(tcanon(a), tcanon(b));
        }
    } else if (teq_unfolds >= 64) {
        return 0;
    } else {
        teq_unfolds = teq_unfolds + 1;
        int r = teq(unfold(a), unfold(b));
        teq_unfolds = teq_unfolds - 1;
        return r;
    }
}

// xs sorted (insertion sort: field lists are short).
Yv *str_sorted(Yv *xs) {
    Yv *out = yav(0);
    long i = 0;
    while (i < yv_len(xs)) {
        Yv *x = ya_get(xs, i);
        out = ya_push(out, x);
        long j = yv_len(out) - 1;
        while (j > 0 && ys_cmp(x, ya_get(out, j - 1)) < 0) {
            ya_set(out, j, ya_get(out, j - 1));
            j = j - 1;
        }
        ya_set(out, j, x);
        i = i + 1;
    }
    return out;
}

// The field names of a record type's field list, sorted: its layout
// (native.y "records at run time").
Yv *rec_names(Yv *fs) {
    Yv *names = yav(0);
    long i = 0;
    while (i < yv_len(fs)) {
        names = ya_push(names, yr_get(ya_get(fs, i), "name"));
        i = i + 1;
    }
    return str_sorted(names);
}

// The canonical form of a type (native.y names record descriptors by its
// hash; teq_ref compares recursive aliases by it): equal types give equal
// strings, record fields and union members in any order. What is unknown
// to the checker (tunk, a missing annotation, an unresolved name) is "u".
// A tref is spelled out where it is met first; inside, a reference back
// to it is `^N`, N counting the trefs entered since.
Yv *tcanon(Yv *t) {
    Yv *out = yav(0);
    out = tcanon_go(out, t, yav(0));
    return ys_join(out, ys(""));
}

// A type's signature (native.c ty_desc's key): its canonical form with each
// recursive alias written as its name in the unit (the tref's tmp) instead
// of spelled out -- short where a canonical form spells out a whole
// recursive union. Within one unit, equal signatures are one type.
static int tcanon_named = 0;
Yv *tsig(Yv *t) {
    tcanon_named = 1;
    Yv *s = tcanon(t);
    tcanon_named = 0;
    return s;
}

static Yv *tcanon_go(Yv *out, Yv *t, Yv *stack) {
    Yv *k = yr_get(t, "k");
    if (yv_l(k) == K_tlong) {
        return ya_push(out, ys("l"));
    } else if (yv_l(k) == K_tbyte) {
        return ya_push(out, ys("b"));
    } else if (yv_l(k) == K_tfloat) {
        return ya_push(out, ys("f"));
    } else if (yv_l(k) == K_tbool) {
        return ya_push(out, ys("o"));
    } else if (yv_l(k) == K_tstr) {
        return ya_push(out, ys("s"));
    } else if (yv_l(k) == K_tvoid) {
        return ya_push(out, ys("v"));
    } else if (yv_l(k) == K_tptr) {
        out = ya_push(out, ys("*"));
        return tcanon_go(out, yr_get(t, "to"), stack);
    } else if (yv_l(k) == K_tarr) {
        out = ya_push(out, ys("["));
        return tcanon_go(out, yr_get(t, "of"), stack);
    } else if (yv_l(k) == K_tarrfix) {
        out = ya_push(out, ys_cat(ys_cat(ys("F"), ys_long(yv_l(yr_get(t, "n")))),
                                  ys(";")));
        return tcanon_go(out, yr_get(t, "of"), stack);
    } else if (yv_l(k) == K_topt) {
        out = ya_push(out, ys("?"));
        return tcanon_go(out, yr_get(t, "of"), stack);
    } else if (yv_l(k) == K_tmap) {
        out = ya_push(out, ys("M"));
        out = tcanon_go(out, yr_get(t, "key"), stack);
        return tcanon_go(out, yr_get(t, "of"), stack);
    } else if (yv_l(k) == K_tfunc) {
        Yv *args = yr_get(t, "args");
        out = ya_push(out, ys("("));
        long i = 0;
        while (i < yv_len(args)) {
            out = tcanon_go(out, ya_get(args, i), stack);
            out = ya_push(out, ys(","));
            i = i + 1;
        }
        out = ya_push(out, ys(")"));
        return tcanon_go(out, yr_get(t, "ret"), stack);
    } else if (yv_l(k) == K_trec) {
        Yv *fs = yr_get(t, "fields");
        Yv *names = rec_names(fs);
        out = ya_push(out, ys("{"));
        long i = 0;
        while (i < yv_len(names)) {
            Yv *nm = ya_get(names, i);
            Yv *f = ya_get(fs, field_pos(fs, nm, 0));
            out = ya_push(out, ys_cat(nm, ys(":")));
            out = tcanon_go(out, yr_get(f, "typ"), stack);
            out = ya_push(out, ys(","));
            i = i + 1;
        }
        out = ya_push(out, ys("}"));
        return out;
    } else if (yv_l(k) == K_tunion) {
        Yv *ms = union_parts(t);
        Yv *forms = yav(0);
        long i = 0;
        while (i < yv_len(ms)) {
            Yv *mf = ys_join(tcanon_go(yav(0), ya_get(ms, i), stack), ys(""));
            if (!str_in(forms, mf)) {
                forms = ya_push(forms, mf);
            }
            i = i + 1;
        }
        out = ya_push(out, ys_cat(ys_cat(ys("<"), ys_join(str_sorted(forms), ys("|"))),
                                  ys(">")));
        return out;
    } else if (yv_l(k) == K_tref) {
        Yv *tmp = yr_get(t, "tmp");
        long d = -1;
        long i = yv_len(stack) - 1;
        while (d < 0 && i >= 0) {
            if (ys_eq(ya_get(stack, i), tmp)) {
                d = yv_len(stack) - 1 - i;
            }
            i = i - 1;
        }
        if (tcanon_named) {
            return ya_push(out, ys_cat(ys("@"), tmp));
        } else if (d >= 0) {
            return ya_push(out, ys_cat(ys("^"), ys_long(d)));
        } else {
            Yv *inner = yav(0);
            for (long q = 0; q < yv_len(stack); q++) {
                inner = ya_push(inner, ya_get(stack, q));
            }
            inner = ya_push(inner, tmp);
            return tcanon_go(out, yr_get(t, "to"), inner);
        }
    } else {
        return ya_push(out, ys("u"));
    }
}

// s is one of xs.
static int str_in(Yv *xs, Yv *s) {
    int found = 0;
    long i = 0;
    while (!found && i < yv_len(xs)) {
        if (ys_eq(ya_get(xs, i), s)) {
            found = 1;
        }
        i = i + 1;
    }
    return found;
}

// Every field of af is in bf (by name) with an equal type: with the same
// count on both sides (teq checks it), the two are one set of fields.
// Index recursion (not a loop) so the shape stays checker-clean and
// out-of-range reads impossible.
static int teq_fields(Yv *af, Yv *bf, long i) {
    if (i >= yv_len(af)) {
        return 1;
    } else {
        Yv *fa = ya_get(af, i);
        // NOTE: :str binding (see teq note): fa flows from bare params
        // (tunk), so a direct `==` would compare string POINTERS.
        Yv *an = yr_get(fa, "name");
        long j = field_pos(bf, an, i);
        if (j < 0) {
            return 0;
        } else {
            Yv *fb = ya_get(bf, j);
            if (teq(yr_get(fa, "typ"), yr_get(fb, "typ"))) {
                return teq_fields(af, bf, i + 1);
            } else {
                return 0;
            }
        }
    }
}

// The index of the field named `name` in the field list fs, -1 when there
// is none. `hint` is tried first: records written in the same order find
// every field there.
long field_pos(Yv *fs, Yv *name, long hint) {
    long found = -1;
    if (hint < yv_len(fs)) {
        if (ys_eq(yr_get(ya_get(fs, hint), "name"), name)) {
            found = hint;
        }
    }
    long i = 0;
    while (found < 0 && i < yv_len(fs)) {
        if (ys_eq(yr_get(ya_get(fs, i), "name"), name)) {
            found = i;
        }
        i = i + 1;
    }
    return found;
}

// Every member of ua has an equal member in ub.
static int teq_members(Yv *ua, Yv *ub, long i) {
    if (i >= yv_len(ua)) {
        return 1;
    } else {
        int found = 0;
        long j = 0;
        while (!found && j < yv_len(ub)) {
            if (teq(ya_get(ua, i), ya_get(ub, j))) {
                found = 1;
            }
            j = j + 1;
        }
        if (found) {
            return teq_members(ua, ub, i + 1);
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

// Field type by name in a trec; tnone marker when missing (dotassign uses
// it — the caller reports the error once at the assignment site).
static Yv *trec_field_type(Yv *rec, Yv *key) {
    Yv *found = yr(1, "k", yv_long(K_tnone));
    if (yv_l(yr_get(rec, "k")) == K_trec) {
        Yv *fs = yr_get(rec, "fields");
        long i = 0;
        while (i < yv_len(fs)) {
            Yv *f = ya_get(fs, i);
            if (ys_eq(yr_get(f, "name"), key)) {
                found = yr_get(f, "typ");
                ;
            }
            i = i + 1;
        }
    }
    return found;
}

static Yv *tstr_go(Yv *t) {
    if (yv_l(yr_get(t, "k")) == K_tlong) {
        return ys("long");
    } else if (yv_l(yr_get(t, "k")) == K_tbyte) {
        return ys("byte");
    } else if (yv_l(yr_get(t, "k")) == K_tfloat) {
        return ys("float");
    } else if (yv_l(yr_get(t, "k")) == K_tbool) {
        return ys("bool");
    } else if (yv_l(yr_get(t, "k")) == K_tstr) {
        return ys("str");
    } else if (yv_l(yr_get(t, "k")) == K_tvoid) {
        return ys("void");
    } else if (yv_l(yr_get(t, "k")) == K_tunk) {
        return ys("<error>");
    } else if (yv_l(yr_get(t, "k")) == K_tnone) {
        return ys("<missing annotation>");
    } else if (yv_l(yr_get(t, "k")) == K_tname) {
        return yr_get(t, "name");
    } else if (yv_l(yr_get(t, "k")) == K_tref) {
        return yr_get(t, "name");
    } else if (yv_l(yr_get(t, "k")) == K_tunion) {
        return tstr_union(yr_get(t, "ts"), ys(" | "));
    } else if (yv_l(yr_get(t, "k")) == K_tpat) {
        return ys_cat(ys_cat(ys("{ "), ys_join(yr_get(t, "names"), ys(", "))), ys(" }"));
    } else if (yv_l(yr_get(t, "k")) == K_tptr) {
        return ys_cat(ys("*"), tstr_go(yr_get(t, "to")));
    } else if (yv_l(yr_get(t, "k")) == K_tarr) {
        return ys_cat(ys_cat(ys("["), tstr_go(yr_get(t, "of"))), ys("]"));
    } else if (yv_l(yr_get(t, "k")) == K_tarrfix) {
        return ys_cat(ys_cat(ys_cat(ys_cat(ys("["), tstr_go(yr_get(t, "of"))),
                                    ys("; ")),
                          ys_tostring(yr_get(t, "n"))),
                    ys("]"));
    } else if (yv_l(yr_get(t, "k")) == K_topt) {
        // `none` alone is the option of nothing-known-yet
        Yv *tof = yr_get(t, "of");
        if (yv_l(yr_get(tof, "k")) == K_tunk) { return ys("none"); } else { return ys_cat(tstr_go(tof), ys("?")); }
    } else if (yv_l(yr_get(t, "k")) == K_tmap) {
        return ys_cat(ys_cat(ys_cat(ys_cat(ys("{"), tstr_go(yr_get(t, "key"))), ys(" => ")), tstr_go(yr_get(t, "of"))), ys("}"));
    } else if (yv_l(yr_get(t, "k")) == K_trec && teq(t, t_mutex())) {
        return ys("mutex");
    } else if (yv_l(yr_get(t, "k")) == K_trec && teq(t, t_sem())) {
        return ys("sem");
    } else if (yv_l(yr_get(t, "k")) == K_trec) {
        Yv *parts = yav(0);
        Yv *fs = yr_get(t, "fields");
        long i = 0;
        while (i < yv_len(fs)) {
            // NOTE: bound once — `fields` is a bare param here, so an inline
            // `fs[i]` would merge shapes across arms (see teq note).
            Yv *f = ya_get(fs, i);
            Yv *fname = yr_get(f, "name");
            Yv *ft = yr_get(f, "typ");
            if (yv_b(yr_get(f, "opt")) && yv_l(yr_get(ft, "k")) == K_topt) {
                parts = ya_push(parts, ys_cat(ys_cat(fname, ys("?: ")),
                                              tstr_go(yr_get(ft, "of"))));
            } else {
                parts = ya_push(parts, ys_cat(ys_cat(fname, ys(": ")),
                                              tstr_go(ft)));
            }
            i = i + 1;
        }
        return ys_cat(ys_cat(ys("{ "), ys_join(parts, ys(", "))), ys(" }"));
    } else if (yv_l(yr_get(t, "k")) == K_tfunc) {
        Yv *parts = yav(0);
        Yv *ta = yr_get(t, "args");
        long i = 0;
        while (i < yv_len(ta)) {
            parts = ya_push(parts, tstr_go(ya_get(ta, i)));
            i = i + 1;
        }
        return ys_cat(ys_cat(ys_cat(ys("("), ys_join(parts, ys(", "))),
                             ys(") -> ")),
                      tstr_go(yr_get(t, "ret")));
    } else {
        return ys_cat(ys_cat(ys("<"), ktag(yv_l(yr_get(t, "k")))), ys(">"));
    }
}

Yv *tstr(Yv *t) {
    return tstr_go(t);
}

static Yv *tstr_union(Yv *ts, Yv *sep) {
    Yv *parts = yav(0);
    long i = 0;
    while (i < yv_len(ts)) {
        parts = ya_push(parts, tstr_go(ya_get(ts, i)));
        i = i + 1;
    }
    return ys_join(parts, sep);
}

// ── unions and match ─────────────────────────────────────────────────────
// A union `A | B` holds a record whose type is exactly one of its members.
// Every record carries its type's descriptor (native.y "records at run
// time"), so a match tells the member a value holds by comparing that, a
// compare per member (the first matching arm wins).

// The field names a match pattern tests: a record type's, or a record
// pattern's (tpat).
Yv *type_names(Yv *t) {
    Yv *out = yav(0);
    Yv *tk = yr_get(t, "k");
    if (yv_l(tk) == K_trec) {
        Yv *fs = yr_get(t, "fields");
        long i = 0;
        while (i < yv_len(fs)) {
            out = ya_push(out, yr_get(ya_get(fs, i), "name"));
            i = i + 1;
        }
    } else if (yv_l(tk) == K_tpat) {
        Yv *ns = yr_get(t, "names");
        for (long j = 0; j < yv_len(ns); j++) out = ya_push(out, ya_get(ns, j));
    }
    return out;
}

static int rec_has_names(Yv *r, Yv *names) {
    if (yv_l(yr_get(r, "k")) != K_trec) {
        return 0;
    } else {
        Yv *have = type_names(r);
        int ok = 1;
        long i = 0;
        while (i < yv_len(names)) {
            Yv *nm = ya_get(names, i);
            int found = 0;
            long j = 0;
            while (j < yv_len(have)) {
                if (ys_eq(ya_get(have, j), nm)) {
                    found = 1;
                }
                j = j + 1;
            }
            if (!found) {
                ok = 0;
            }
            i = i + 1;
        }
        return ok;
    }
}

// The static type of `narrow(e, t)`: t itself for a record type; for a
// record pattern (tpat), the member of the subject's union that has those
// fields, or the union of the members that have them when there are
// several (the subject itself when it is a record). tunk when none.
Yv *narrow_type(Yv *s, Yv *t) {
    Yv *tk = yr_get(t, "k");
    Yv *sk = yr_get(s, "k");
    if (yv_l(tk) != K_tpat) {
        return t;
    } else if (yv_l(sk) == K_trec) {
        if (rec_has_names(s, yr_get(t, "names"))) {
            return s;
        } else {
            return t_unk();
        }
    } else if (yv_l(sk) == K_tunion) {
        Yv *ms = members(s);
        Yv *names = yr_get(t, "names");
        Yv *found = yav(0);
        long i = 0;
        while (i < yv_len(ms)) {
            if (rec_has_names(ya_get(ms, i), names)) {
                found = ya_push(found, ya_get(ms, i));
            }
            i = i + 1;
        }
        if (yv_len(found) == 0) {
            return t_unk();
        } else if (yv_len(found) == 1) {
            return ya_get(found, 0);
        } else {
            return yr(2, "k", yv_long(K_tunion), "ts", found);
        }
    } else {
        return t_unk();
    }
}

// The member of union u that is the record type t (as u writes it,
// union_parts); tnone when there is none.
Yv *union_member(Yv *u, Yv *t) {
    Yv *ms = union_parts(u);
    Yv *found = yr(1, "k", yv_long(K_tnone));
    long i = yv_len(ms) - 1;
    while (i >= 0) {
        if (teq(ya_get(ms, i), t)) {
            found = ya_get(ms, i);
        }
        i = i - 1;
    }
    return found;
}

// `u.f` on a union: every member has f, with one type -- a field they do
// not share is read after a match.
static Yv *union_field(Yv *st, Yv *t, Yv *dkey, long line, long col) {
    Yv *ms = members(t);
    Yv *ft = t_unk();
    int ok = 1;
    long i = 0;
    while (i < yv_len(ms) && ok) {
        Yv *mt = trec_field_type(ya_get(ms, i), dkey);
        if (yv_l(yr_get(mt, "k")) == K_tnone) {
            st = fail(st, ys_cat(ys_cat(ys_cat(ys_cat(ys_cat(ys_cat(ys("member "), tstr(ya_get(ms, i))),
                                                        ys(" of ")),
                                                 tstr(t)),
                                          ys(" has no field '")),
                                   dkey),
                         ys("' (match the member first)")),
                      line, col);
            ok = 0;
        } else if (i == 0) {
            ft = mt;
        } else if (!teq(ft, mt)) {
            st = fail(st, ys_cat(ys_cat(ys_cat(ys_cat(ys("field '"), dkey),
                                               ys("' has a different type in each member of ")),
                                        tstr(t)),
                                 ys(" (match the member first)")),
                      line, col);
            ok = 0;
        }
        i = i + 1;
    }
    if (ok) {
        return yr(2, "typ", ft, "st", st);
    } else {
        return yr(2, "typ", t_unk(), "st", st);
    }
}

// `u.f = v` on a union: f as a read finds it (union_field), then v must
// fit it.
static Yv *dotassign_union(Yv *st, Yv *t, Yv *node) {
    Yv *key = yr_get(node, "key");
    Yv *fr = union_field(st, t, key, yv_l(yr_get(node, "line")),
                         yv_l(yr_get(node, "col")));
    st = yr_get(fr, "st");
    Yv *v = typeof_want(st, yr_get(node, "v"), yr_get(fr, "typ"));
    st = expect_type(yr_get(v, "st"), yr_get(v, "typ"), yr_get(fr, "typ"),
                     ys_cat(ys_cat(ys("record field '"), key), ys("'")),
                     yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
    return yr(2, "typ", yr_get(fr, "typ"), "st", st);
}

// Every member of a union must be a record type (they are told apart by
// their field names).
static int union_ok(Yv *t) {
    Yv *ms = members(t);
    int ok = 1;
    long i = 0;
    while (i < yv_len(ms)) {
        if (yv_l(yr_get(ya_get(ms, i), "k")) != K_trec) {
            ok = 0;
        }
        i = i + 1;
    }
    return ok;
}

// got flows into the union want: a member does (a record equal to some
// member: membership is exact, `{a: 1, b: 2}` is no `{a: long}`), and so
// does a union whose every member does.
static int union_accepts(Yv *got, Yv *want) {
    if (yv_l(yr_get(got, "k")) == K_tunion) {
        Yv *gs = members(got);
        int ok = 1;
        long i = 0;
        while (i < yv_len(gs)) {
            if (!union_accepts(ya_get(gs, i), want)) {
                ok = 0;
            }
            i = i + 1;
        }
        return ok;
    } else {
        Yv *ws = members(want);
        int any = 0;
        long j = 0;
        while (j < yv_len(ws)) {
            if (tcompat(got, ya_get(ws, j))) {
                any = 1;
            }
            j = j + 1;
        }
        return any;
    }
}

/* A float literal's net power of ten: the explicit exponent minus the digits
 * after the dot, clamped so a long digit run cannot wrap. |dp| past 100000 is
 * nobody's magnitude -- a double holds 10^-308 to 10^308 -- and the conversion
 * used to emit megabytes of mul/div for such a literal (1e10000000 killed the
 * compiler), so the checker rejects it. A literal merely past the range is not
 * an error: 1e400 and 1e40000 are inf, as IEEE says (t171). (native.y keeps its
 * own copy of this scan -- the two modules never share helpers.) */
static long num_net_exp(Yv *s) {
    long dot = ys_index_of(s, ys("."));
    long eb = ys_index_of(s, ys("e"));
    if (eb < 0) eb = ys_index_of(s, ys("E"));
    if (eb < 0) eb = yv_len(s);
    long nfrac = 0;
    if (dot >= 0) nfrac = eb - dot - 1;
    long ex = 0;
    if (eb < yv_len(s)) {
        long i = eb + 1;
        int neg = 0;
        Yv *sc = ys_slice(s, i, i + 1);
        if (ys_eq_lit(sc, "-")) { neg = 1; i = i + 1; }
        if (ys_eq_lit(sc, "+")) { i = i + 1; }
        int past = 0;
        while (i < yv_len(s)) {
            if (!past) {
                ex = ex * 10 + (ys_byte_at(s, i) - 48);
                if (ex > 100001) { past = 1; ex = 100002; }
            }
            i = i + 1;
        }
        if (neg) ex = 0 - ex;
    }
    return ex - nfrac;
}

/* A numeric literal denotes a float when it has a fraction or an exponent.
 * Radix literals are checked first: 0xE1 and 0xbeef contain 'e'/'E'/'b'.
 * (native.y keeps its own copy -- the two modules never share helpers.) */
static int num_is_float(Yv *s) {
    int radix = 0;
    if (yv_len(s) > 2) {
        Yv *p = ys_slice(s, 0, 2);
        if (ys_eq_lit(p, "0x")) {
            radix = 1;
            ;
        }
        if (ys_eq_lit(p, "0X")) {
            radix = 1;
            ;
        }
        if (ys_eq_lit(p, "0b")) {
            radix = 1;
            ;
        }
        if (ys_eq_lit(p, "0B")) {
            radix = 1;
            ;
        }
        ;
    }
    if (radix) {
        return 0;
    } else {
        int f = 0;
        if (ys_index_of(s, ys(".")) >= 0) {
            f = 1;
            ;
        }
        if (ys_index_of(s, ys("e")) >= 0) {
            f = 1;
            ;
        }
        if (ys_index_of(s, ys("E")) >= 0) {
            f = 1;
            ;
        }
        return f;
    }
}

static Yv *field_merge_dup(Yv *fields, Yv *name, Yv *typ);

// Merge one field into a record literal's field list, in place: the array is
// the caller's (every call site assigns the result straight back) and Y arrays
// are references. A name the list does not have yet -- all but a repeated key
// or a spread that overlaps one -- is an append, O(1). Rebuilding the array per
// field was quadratic in the literal's field count in *copies*: 722 MB at 4 000
// fields, every field copied once per field after it.
Yv *field_merge(Yv *fields, Yv *name, Yv *typ) {
    long i = 0;
    while (i < yv_len(fields)) {
        if (ys_eq(yr_get(ya_get(fields, i), "name"), name)) {
            return field_merge_dup(fields, name, typ);
        }
        i = i + 1;
    }
    return ya_push(fields, yr(3, "name", name, "opt", yv_bool(0), "typ", typ));
}

// A later entry wins the value (and its type); the first appearance keeps the
// position. That is the static union rule for `{a: 1, ...obj}`: obj may
// overwrite a, and a later explicit key may overwrite what obj spread. The
// list is copied here because Y cannot remove an array element, so the later
// appearances of the name have to go -- rare enough that the copy is worth it.
static Yv *field_merge_dup(Yv *fields, Yv *name, Yv *typ) {
    Yv *out = yav(0);
    long i = 0;
    int seen = 0;
    while (i < yv_len(fields)) {
        Yv *f = ya_get(fields, i);
        Yv *fnm = yr_get(f, "name");
        if (ys_eq(fnm, name)) {
            if (seen) {
                ;
            } else {
                out = ya_push(out, yr(3, "name", name, "opt", yv_bool(0), "typ", typ));
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
        out = ya_push(out, yr(3, "name", name, "opt", yv_bool(0), "typ", typ));
        ;
    }
    return out;
}

/* Does this type carry an error that has already been reported, at any depth?
 * tunk is the poison a failed check leaves behind, and it unifies with
 * everything through teq. A container of it -- the type of [[zzz]] after zzz
 * was reported undefined -- has to as well, or the enclosing literal reports
 * the same failure a second time under a worse name ("expected [<error>]").
 * tname/tnone/tparams already unify quietly in tcompat and are not poison. */
static int t_poisoned(Yv *t) { return t_poisoned_go(t, 0); }

static int t_poisoned_go(Yv *t, long d) {
    Yv *k = yr_get(t, "k");
    if (yv_l(k) == K_tunk) {
        return 1;
    } else if (d >= 16) {
        return 0;
    } else if (yv_l(k) == K_tarr) {
        return t_poisoned_go(yr_get(t, "of"), d + 1);
    } else if (yv_l(k) == K_tarrfix) {
        return t_poisoned_go(yr_get(t, "of"), d + 1);
    } else if (yv_l(k) == K_topt) {
        return t_poisoned_go(yr_get(t, "of"), d + 1);
    } else if (yv_l(k) == K_tmap) {
        if (t_poisoned_go(yr_get(t, "key"), d + 1)) {
            return 1;
        }
        return t_poisoned_go(yr_get(t, "of"), d + 1);
    } else {
        return 0;
    }
}

static int is_value_type(Yv *t) {
    if (yv_l(yr_get(t, "k")) == K_tlong) {
        return 1;
    } else if (yv_l(yr_get(t, "k")) == K_tbyte) {
        return 1;
    } else if (yv_l(yr_get(t, "k")) == K_tfloat) {
        return 1;
    } else if (yv_l(yr_get(t, "k")) == K_tbool) {
        return 1;
    } else if (yv_l(yr_get(t, "k")) == K_tstr) {
        return 1;
    } else if (yv_l(yr_get(t, "k")) == K_tptr) {
        return 1;
    } else if (yv_l(yr_get(t, "k")) == K_tunk) {
        return 1;
    } else if (yv_l(yr_get(t, "k")) == K_tnone) {
        return 1;
    } else if (yv_l(yr_get(t, "k")) == K_tname) {
        return 1;
    } else if (yv_l(yr_get(t, "k")) == K_tparams) {
        return 1;
    } else if (yv_l(yr_get(t, "k")) == K_tfunc) {
        return 1;
    } else if (yv_l(yr_get(t, "k")) == K_tarr) {
        return 1;
    } else if (yv_l(yr_get(t, "k")) == K_tarrfix) {
        return 1;
    } else if (yv_l(yr_get(t, "k")) == K_topt) {
        return 1;
    } else if (yv_l(yr_get(t, "k")) == K_tmap) {
        return is_hash_key(yr_get(t, "key"));
    } else if (yv_l(yr_get(t, "k")) == K_tunion) {
        return union_ok(t);
    } else if (yv_l(yr_get(t, "k")) == K_tref) {
        return 1;
    } else {
        return yv_l(yr_get(t, "k")) == K_trec;
    }
}

// Map keys must be hashable scalars: str, long, byte, bool, float.
static int is_hash_key(Yv *t) {
    if (yv_l(yr_get(t, "k")) == K_tstr) { return 1; }
    else if (yv_l(yr_get(t, "k")) == K_tlong) { return 1; }
    else if (yv_l(yr_get(t, "k")) == K_tbyte) { return 1; }
    else if (yv_l(yr_get(t, "k")) == K_tbool) { return 1; }
    else { return yv_l(yr_get(t, "k")) == K_tfloat; }
}

// ── checker state ────────────────────────────────────────────────────────
// No scopes: rename.y gave every binding a unique name, so one flat list
// suffices. bindings = [{name, typ, kind, fdepth}] (fdepth = function-nesting
// depth where bound; top level = 0). kind: "local" | "param" | "func"
// (any def) | "intrinsic". fdepth is bookkeeping only — it is threaded but
// never tested: a nested def reading an enclosing local is a capture, and
// captures are legal (native.y box_capture).

// The bindings by name (lookup): the index of each name's last binding in
// the program's bindings list -- flat, append-only, one per check_program
// run (which resets this), ~7k entries in the compiler. Made once the
// list passes 256 entries (st_bind; a small unit scans faster than it
// hashes): tc_ixn bindings are in it, all of them from then on.
static Yv *tc_ix;
static long tc_ixn;

static Yv *lookup(Yv *bindings, Yv *name) {
    /* The newest binding of the name: the last few bindings first (a
     * local is almost always among them), then the index: scanning back
     * through the whole list cost every reference to a global thousands
     * of compares. "" is not indexed: it is scanned for. */
    long i = yv_len(bindings) - 1;
    long stop = i - 8;
    if (tc_ixn == 0) {
        stop = -1;
    }
    long at = -1;
    while (i >= 0 && i > stop) {
        Yv *e = ya_get(bindings, i);
        if (ys_eq(yr_get(e, "name"), name)) {
            at = i;
            i = -1;
        }
        i = i - 1;
    }
    if (at < 0 && i >= 0) {
        if (yv_len(name) > 0) {
            at = nameix_get(tc_ix, name);
        } else {
            while (i >= 0) {
                Yv *e = ya_get(bindings, i);
                if (ys_eq(yr_get(e, "name"), name)) {
                    at = i;
                    i = -1;
                }
                i = i - 1;
            }
        }
    }
    // NOTE: NO shared `found` hole rebound across arms (see parser.y
    // parse_type_node note): the env keeps ONE shape per name.
    if (at >= 0) {
        Yv *e = ya_get(bindings, at);
        return yr(3, "typ", yr_get(e, "typ"), "kind", yr_get(e, "kind"),
                  "fdepth", yv_long(yv_l(yr_get(e, "fdepth"))));
    } else {
        return yr(3, "typ", yr(1, "k", yv_long(K_tnone)), "kind", ys(""), "fdepth",
                  yv_long(0));
    }
}

static Yv *st_bind(Yv *st, Yv *name, Yv *typ, Yv *kind) {
    Yv *bindings = ya_push(yr_get(st, "bindings"),
                           yr(4, "name", name, "typ", typ, "kind", kind,
                              "fdepth", yv_long(yv_l(yr_get(st, "fdepth")))));
    if (yv_len(bindings) > 256) {
        if (tc_ixn == 0) {
            tc_ix = nameix_new(1024);
        }
        while (tc_ixn < yv_len(bindings)) {
            Yv *b = ya_get(bindings, tc_ixn);
            if (yv_len(yr_get(b, "name")) > 0) {
                nameix_put(tc_ix, yr_get(b, "name"), tc_ixn);
            }
            tc_ixn = tc_ixn + 1;
        }
    }
    return yr(5, "bindings", bindings, "errors", yr_get(st, "errors"),
              "ret", yr_get(st, "ret"), "self", yr_get(st, "self"),
              "fdepth", yv_long(yv_l(yr_get(st, "fdepth"))));
}

// ── the checker ──────────────────────────────────────────────────────────
// Threaded state st = { bindings, errors, ret, self, fdepth }.
// typeof_* returns { typ, st }.

// State is threaded by rebuilding the record, so a helper never mutates its
// caller's st (same style as the rest of ycc). `fail` is the one place that
// writes through: `st.errors += ...` appends to the LIVE array in place,
// because arrays are reference values, and hands the record back here.
static Yv *st_errors(Yv *st, Yv *errs) {
    return yr(5, "bindings", yr_get(st, "bindings"), "errors", errs,
              "ret", yr_get(st, "ret"), "self", yr_get(st, "self"),
              "fdepth", yv_long(yv_l(yr_get(st, "fdepth"))));
}

// NOTE: the parameter is deliberately NOT named `self` — `self` is the
// language's own name for the enclosing function (see the `id` and `call`
// arms of typeof_expr/typeof_call), so the state field and the language's
// reserved word must not read alike.
static Yv *st_self(Yv *st, Yv *selfv) {
    return yr(5, "bindings", yr_get(st, "bindings"), "errors", yr_get(st, "errors"),
              "ret", yr_get(st, "ret"), "self", selfv,
              "fdepth", yv_long(yv_l(yr_get(st, "fdepth"))));
}

static Yv *st_ret(Yv *st, Yv *ret) {
    return yr(5, "bindings", yr_get(st, "bindings"), "errors", yr_get(st, "errors"),
              "ret", ret, "self", yr_get(st, "self"),
              "fdepth", yv_long(yv_l(yr_get(st, "fdepth"))));
}

static Yv *fail(Yv *st, Yv *msg, long line, long col) {
    return st_errors(st, ya_push(yr_get(st, "errors"), err_at(msg, line, col)));
}

// Display name: strip the rename pass's `$N` suffix so errors read like
// the user's source (`$` is lexer-illegal, so it can only come from rename).
static Yv *disp(Yv *name) {
    long i = ys_index_of(name, ys("$"));
    if (i < 0) {
        return name;
    } else {
        return ys_slice(name, 0, i);
    }
}

// A local/param binding from an enclosing function is a CAPTURE, and captures
// are legal: the emitter closure-converts the function and BOXES each captured
// variable in one heap cell shared by the binding and every closure over it
// (native.y box_capture), so a write inside the closure is visible outside.
// Nothing is left to check here, so this is a pass-through kept at every call
// site as the hook for a future capture rule.
static Yv *check_visible(Yv *st, Yv *got, Yv *name, long line, long col) {
    (void)got;
    (void)name;
    (void)line;
    (void)col; /* unused in types.y's def too */
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

// A union value where one of its members, or a union of some of them, is
// written: a cast, checked when the program runs (native.c gen_as: a value
// holding another member stops the program).
static int cast_ok(Yv *got, Yv *want) {
    Yv *g = unfold(got);
    if (tcompat(got, want)) {
        return 1;
    } else if (yv_l(yr_get(g, "k")) == K_tunion) {
        return union_accepts(unfold(want), g);
    } else {
        return 0;
    }
}

// expect_type where the type is written at the site -- an annotated let, a
// parameter, a declared return type -- so a union value casts to it. Where
// the type was inferred (an assignment, a field, an element) a union value
// does not: a binding inferred too narrow is an error, not a trap.
static Yv *expect_cast(Yv *st, Yv *got, Yv *want, Yv *what, long line, long col) {
    if (cast_ok(got, want)) {
        return st;
    } else {
        return expect_type(st, got, want, what, line, col);
    }
}

/* expect_type for a call argument. some(v) passed for a T? -- which is what
 * the argument of an optional parameter `b?: T` becomes -- is reported as
 * v against T: "expected long, got long?", not "expected long?, got long??". */
static Yv *expect_arg(Yv *st, Yv *got, Yv *want, Yv *arg, Yv *what,
                      long line, long col) {
    if (cast_ok(got, want)) {
        return st;
    } else if (yv_l(yr_get(got, "k")) == K_topt &&
               yv_l(yr_get(want, "k")) == K_topt && is_some_call(arg)) {
        return fail(st,
                    ys_cat(ys_cat(ys_cat(ys_cat(what, ys(": expected ")),
                                        tstr(yr_get(want, "of"))),
                                  ys(", got ")),
                            tstr(yr_get(got, "of"))),
                    line, col);
    } else {
        return fail(st, ys_cat(ys_cat(ys_cat(ys_cat(what, ys(": expected ")),
                                             tstr(want)),
                                       ys(", got ")),
                                tstr(got)),
                    line, col);
    }
}

static int is_some_call(Yv *n) {
    if (yv_l(yr_get(n, "k")) == K_call) {
        Yv *c = yr_get(n, "callee");
        return yv_l(yr_get(c, "k")) == K_id &&
               ys_eq_lit(yr_get(c, "v"), "some");
    } else {
        return 0;
    }
}

// Binary-operator result typing. Split out of the `bin` arm so the operator
// table there stays a flat `op == "..."` dispatch and each operator's rule
// lives in one named place.
static Yv *typeof_arith(Yv *st, Yv *op, Yv *lt, Yv *rt, long line, long col) {
    // "+" on strings concatenates (either side may be poison tunk, but at
    // least one side must be a real str — hence the per-kind arms below).
    // AUTO-STRINGIFY: str + long/bool/float (and the mirror) stringify the
    // number and concat — the same lowering native.y gen_cat emits
    // (y_long_tostr / y_float_tostr, then y_str_cat).
    if (ys_eq_lit(op, "+")) {
        // Arrays win over strings (the arm order below IS that order):
        // arr + arr concatenates into a NEW array, arr + elem appends one
        // (same type only), elem + arr prepends one. In-place forms are
        // `+=` / `*=`.
        if (yv_l(yr_get(lt, "k")) == K_tarr ||
            yv_l(yr_get(lt, "k")) == K_tarrfix) {
            return typeof_arith_arr(st, op, lt, rt, line, col);
        } else if (yv_l(yr_get(rt, "k")) == K_tarr ||
                   yv_l(yr_get(rt, "k")) == K_tarrfix) {
            return typeof_arith_arr(st, op, lt, rt, line, col);
        } else if (yv_l(yr_get(lt, "k")) == K_tstr) {
            if (yv_l(yr_get(rt, "k")) == K_tstr) {
                return yr(2, "typ", yr(1, "k", yv_long(K_tstr)), "st", st);
            } else if (yv_l(yr_get(rt, "k")) == K_tunk) {
                return yr(2, "typ", yr(1, "k", yv_long(K_tstr)), "st", st);
            } else if (yv_l(yr_get(rt, "k")) == K_tlong) {
                return yr(2, "typ", yr(1, "k", yv_long(K_tstr)), "st", st);
            } else if (yv_l(yr_get(rt, "k")) == K_tbyte) {
                return yr(2, "typ", yr(1, "k", yv_long(K_tstr)), "st", st);
            } else if (yv_l(yr_get(rt, "k")) == K_tfloat) {
                return yr(2, "typ", yr(1, "k", yv_long(K_tstr)), "st", st);
            } else if (yv_l(yr_get(rt, "k")) == K_tbool) {
                return yr(2, "typ", yr(1, "k", yv_long(K_tstr)), "st", st);
            } else {
                return typeof_arith_long(st, op, lt, rt, line, col);
            }
        } else if (yv_l(yr_get(lt, "k")) == K_tunk) {
            if (yv_l(yr_get(rt, "k")) == K_tstr) {
                return yr(2, "typ", yr(1, "k", yv_long(K_tstr)), "st", st);
            } else {
                return typeof_arith_long(st, op, lt, rt, line, col);
            }
        } else if (yv_l(yr_get(lt, "k")) == K_tlong) {
            if (yv_l(yr_get(rt, "k")) == K_tstr) {
                return yr(2, "typ", yr(1, "k", yv_long(K_tstr)), "st", st);
            } else {
                return typeof_arith_long(st, op, lt, rt, line, col);
            }
        } else if (yv_l(yr_get(lt, "k")) == K_tbyte) {
            if (yv_l(yr_get(rt, "k")) == K_tstr) {
                return yr(2, "typ", yr(1, "k", yv_long(K_tstr)), "st", st);
            } else {
                return typeof_arith_long(st, op, lt, rt, line, col);
            }
        } else if (yv_l(yr_get(lt, "k")) == K_tfloat) {
            if (yv_l(yr_get(rt, "k")) == K_tstr) {
                return yr(2, "typ", yr(1, "k", yv_long(K_tstr)), "st", st);
            } else {
                return typeof_arith_long(st, op, lt, rt, line, col);
            }
        } else if (yv_l(yr_get(lt, "k")) == K_tbool) {
            if (yv_l(yr_get(rt, "k")) == K_tstr) {
                return yr(2, "typ", yr(1, "k", yv_long(K_tstr)), "st", st);
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
    Yv *lk = yr_get(lt, "k");
    if (!ys_eq_lit(op, "+")) {
        st = fail(st, ys_cat(ys_cat(ys("'"), op),
                             ys("' is not defined on arrays (only '+' copies, '+='/'*=' mutate)")),
                  line, col);
        return yr(2, "typ", t_unk(), "st", st);
    } else if (yv_l(lk) == K_tarr || yv_l(lk) == K_tarrfix) {
        if (yv_l(yr_get(rt, "k")) == K_tarr ||
            yv_l(yr_get(rt, "k")) == K_tarrfix) {
            Yv *how = arr_plus_kind(lt, rt);
            if (ys_eq_lit(how, "append")) {
                return yr(2, "typ",
                          yr(2, "k", yv_long(K_tarr), "of", yr_get(lt, "of")),
                          "st", st);
            } else if (ys_eq_lit(how, "prepend")) {
                return yr(2, "typ",
                          yr(2, "k", yv_long(K_tarr), "of", yr_get(rt, "of")),
                          "st", st);
            } else {
                st = expect_type(st, yr_get(rt, "of"), yr_get(lt, "of"),
                                 ys("'+' concatenated elements"), line, col);
                return yr(2, "typ",
                          yr(2, "k", yv_long(K_tarr), "of", yr_get(lt, "of")),
                          "st", st);
            }
        } else {
            st = expect_type(st, rt, yr_get(lt, "of"), ys("'+' element"), line,
                             col);
            return yr(2, "typ", yr(2, "k", yv_long(K_tarr), "of", yr_get(lt, "of")),
                      "st", st);
        }
    } else {
        st = expect_type(st, lt, yr_get(rt, "of"), ys("'+' element"), line, col);
        return yr(2, "typ", yr(2, "k", yv_long(K_tarr), "of", yr_get(rt, "of")), "st",
                  st);
    }
}

/* How `l + r` combines two ARRAY operands -- the one rule the checker and
 * the emitter (native.y infer, gen_cat_arr, gen_opassign_arr) share:
 *   "cat"      the element types match: both element lists are spliced
 *   "append"   r is ONE element of l   ([[T]] + [T] -> [[T]])
 *   "prepend"  l is ONE element of r   ([T] + [[T]] -> [[T]])
 * Concatenation wins whenever it type-checks, so an unknown element type
 * keeps the long-standing meaning; for known types at most one rule fits
 * (a type is never its own element type). "cat" is also the answer when
 * nothing fits, so the caller's concatenation check reports the mismatch. */
Yv *arr_plus_kind(Yv *lt, Yv *rt) {
    if (tcompat(yr_get(rt, "of"), yr_get(lt, "of"))) {
        return ys("cat");
    } else if (tcompat(rt, yr_get(lt, "of"))) {
        return ys("append");
    } else if (tcompat(lt, yr_get(rt, "of"))) {
        return ys("prepend");
    } else {
        return ys("cat");
    }
}

static Yv *typeof_arith_long(Yv *st, Yv *op, Yv *lt, Yv *rt, long line,
                             long col) {
    // Numeric arithmetic. If either side is a float the result is a float
    // and the other side widens (long -> float, the only coercion).
    if (yv_l(yr_get(lt, "k")) == K_tfloat ||
        yv_l(yr_get(rt, "k")) == K_tfloat) {
        st = expect_type(st, lt, yr(1, "k", yv_long(K_tfloat)),
                         ys_cat(ys_cat(ys("'"), op), ys("' left operand")), line,
                         col);
        st = expect_type(st, rt, yr(1, "k", yv_long(K_tfloat)),
                         ys_cat(ys_cat(ys("'"), op), ys("' right operand")),
                         line, col);
        return yr(2, "typ", yr(1, "k", yv_long(K_tfloat)), "st", st);
    } else {
        st = expect_type(st, lt, yr(1, "k", yv_long(K_tlong)),
                         ys_cat(ys_cat(ys("'"), op), ys("' left operand")), line,
                         col);
        st = expect_type(st, rt, yr(1, "k", yv_long(K_tlong)),
                         ys_cat(ys_cat(ys("'"), op), ys("' right operand")),
                         line, col);
        return yr(2, "typ", yr(1, "k", yv_long(K_tlong)), "st", st);
    }
}

// The bitwise binary operators. (native.y asks too: their result is a long.)
int is_bits_op(Yv *op) {
    return ys_eq_lit(op, "&") || ys_eq_lit(op, "|") || ys_eq_lit(op, "^") ||
           ys_eq_lit(op, "<<") || ys_eq_lit(op, ">>") || ys_eq_lit(op, ">>>");
}

// `&` `|` `^` `<<` `>>` `>>>` take integers only: a byte operand widens and
// the result is a long. No float, no bool (`&&` and `||` are the logical
// forms).
static Yv *typeof_bits(Yv *st, Yv *op, Yv *lt, Yv *rt, long line, long col) {
    st = expect_type(st, lt, yr(1, "k", yv_long(K_tlong)),
                     ys_cat(ys_cat(ys("'"), op), ys("' left operand")), line,
                     col);
    st = expect_type(st, rt, yr(1, "k", yv_long(K_tlong)),
                     ys_cat(ys_cat(ys("'"), op), ys("' right operand")), line,
                     col);
    return yr(2, "typ", yr(1, "k", yv_long(K_tlong)), "st", st);
}

static Yv *typeof_cmp(Yv *st, Yv *op, Yv *lt, Yv *rt, long line, long col) {
    if (yv_l(yr_get(lt, "k")) == K_tstr) {
        // str < str is lexicographic ordering (byte by byte), matching the
        // y_str_cmp helper native.y emits.
        st = expect_type(st, rt, yr(1, "k", yv_long(K_tstr)),
                         ys_cat(ys_cat(ys("'"), op), ys("' right operand")),
                         line, col);
        return tc_res(type_node(yr(1, "k", yv_long(K_tbool))), st);
    } else if (yv_l(yr_get(lt, "k")) == K_tfloat ||
               yv_l(yr_get(rt, "k")) == K_tfloat) {
        st = expect_type(st, lt, yr(1, "k", yv_long(K_tfloat)),
                         ys_cat(ys_cat(ys("'"), op), ys("' left operand")), line,
                         col);
        st = expect_type(st, rt, yr(1, "k", yv_long(K_tfloat)),
                         ys_cat(ys_cat(ys("'"), op), ys("' right operand")),
                         line, col);
        return yr(2, "typ", yr(1, "k", yv_long(K_tbool)), "st", st);
    } else {
        st = expect_type(st, lt, yr(1, "k", yv_long(K_tlong)),
                         ys_cat(ys_cat(ys("'"), op), ys("' left operand")), line,
                         col);
        st = expect_type(st, rt, yr(1, "k", yv_long(K_tlong)),
                         ys_cat(ys_cat(ys("'"), op), ys("' right operand")),
                         line, col);
        return yr(2, "typ", yr(1, "k", yv_long(K_tbool)), "st", st);
    }
}

// Both sides numeric (long/byte/float): `==` and `!=` compare by value
// across widths, which is what the compiled code does (native.y gen_bin_rest
// emits a plain word compare).
static int is_num_kind(Yv *t) {
    if (yv_l(yr_get(t, "k")) == K_tlong) {
        return 1;
    } else if (yv_l(yr_get(t, "k")) == K_tbyte) {
        return 1;
    } else if (yv_l(yr_get(t, "k")) == K_tfloat) {
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
    // str compares by content. `x == none` is the option's is-none check.
    // Nested ifs throughout (house style — one kind per arm).
    if (teq(lt, rt)) {
        return yr(2, "typ", yr(1, "k", yv_long(K_tbool)), "st", st);
    } else if (num_eq_ok(lt, rt)) {
        // Numeric kinds compare across widths: a byte IS a small long, so
        // `c == 10` needs no cast (and long/float already coerce in `<`).
        return yr(2, "typ", yr(1, "k", yv_long(K_tbool)), "st", st);
    } else if (yv_l(yr_get(lt, "k")) == K_tstr) {
        if (yv_l(yr_get(rt, "k")) == K_tstr) {
            return yr(2, "typ", yr(1, "k", yv_long(K_tbool)), "st", st);
        } else if (yv_l(yr_get(rt, "k")) == K_tunk) {
            return yr(2, "typ", yr(1, "k", yv_long(K_tbool)), "st", st);
        } else {
            st = fail(st, ys_cat(ys_cat(ys_cat(ys_cat(ys_cat(ys("'"), op),
                                                       ys("' compares ")),
                                              tstr(lt)),
                                        ys(" with ")),
                                 tstr(rt)),
                      line, col);
            return yr(2, "typ", yr(1, "k", yv_long(K_tbool)), "st", st);
        }
    } else if (yv_l(yr_get(lt, "k")) == K_tunk) {
        return yr(2, "typ", yr(1, "k", yv_long(K_tbool)), "st", st);
    } else if (yv_l(yr_get(lt, "k")) == K_topt) {
        // options: the is-none check (`x == none`) plus same-option
        // comparison. Anything else is a type error (t10 parity).
        if (yv_l(yr_get(rt, "k")) == K_tunk) {
            return yr(2, "typ", yr(1, "k", yv_long(K_tbool)), "st", st);
        } else if (teq(lt, rt)) {
            return yr(2, "typ", yr(1, "k", yv_long(K_tbool)), "st", st);
        } else {
            st = fail(st, ys_cat(ys_cat(ys_cat(ys_cat(ys_cat(ys("'"), op),
                                                       ys("' compares ")),
                                              tstr(lt)),
                                        ys(" with ")),
                                 tstr(rt)),
                      line, col);
            return yr(2, "typ", yr(1, "k", yv_long(K_tbool)), "st", st);
        }
    } else if (yv_l(yr_get(rt, "k")) == K_topt) {
        if (yv_l(yr_get(lt, "k")) == K_tunk) {
            return yr(2, "typ", yr(1, "k", yv_long(K_tbool)), "st", st);
        } else {
            st = fail(st, ys_cat(ys_cat(ys_cat(ys_cat(ys_cat(ys("'"), op),
                                                       ys("' compares ")),
                                              tstr(lt)),
                                        ys(" with ")),
                                 tstr(rt)),
                      line, col);
            return yr(2, "typ", yr(1, "k", yv_long(K_tbool)), "st", st);
        }
    } else {
        st = fail(st, ys_cat(ys_cat(ys_cat(ys_cat(ys_cat(ys("'"), op),
                                                   ys("' compares ")),
                                          tstr(lt)),
                                    ys(" with ")),
                             tstr(rt)),
                  line, col);
        return yr(2, "typ", yr(1, "k", yv_long(K_tbool)), "st", st);
    }
}

static Yv *typeof_logic(Yv *st, Yv *op __attribute__((unused)),
                        Yv *lt __attribute__((unused)),
                        Yv *rt __attribute__((unused)),
                        long line __attribute__((unused)),
                        long col __attribute__((unused))) {
    // Truthiness: any 8-byte value decides (nonzero = true), like the C
    // runtime. The result is always a bool; operands keep their own types.
    return yr(2, "typ", yr(1, "k", yv_long(K_tbool)), "st", st);
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
// NOTE: records are exact: a record goes only where its own type (teq:
// the same fields, in any order) or a union holding it is expected. With
// fields at fixed offsets and records shared by reference there is no
// sound width rule. Branch agreement and ==/!= keep strict teq (e11/e12 parity).
static int tcompat(Yv *got, Yv *want) {
    got = unfold(got);
    want = unfold(want);
    if (teq(got, want)) {
        return 1;
    } else if (yv_l(yr_get(got, "k")) == K_tnone) {
        return 1;
    } else if (yv_l(yr_get(want, "k")) == K_tnone) {
        return 1;
    } else if (yv_l(yr_get(got, "k")) == K_tname) {
        return 1;
    } else if (yv_l(yr_get(want, "k")) == K_tname) {
        return 1;
    } else if (yv_l(yr_get(got, "k")) == K_tparams) {
        return 1;
    } else if (yv_l(yr_get(want, "k")) == K_tparams) {
        return 1;
    } else if (yv_l(yr_get(want, "k")) == K_tunion) {
        return union_accepts(got, want);
    } else if (yv_l(yr_get(got, "k")) == K_tunion) {
        // a union is none of its members until a match says which, or a
        // cast where the member type is written (expect_cast)
        return 0;
    } else if (yv_l(yr_get(want, "k")) == K_topt) {
        // `none` (the option of tunk) widens to any T? through teq; a
        // plain T does NOT -- use some(v), which is the explicit box
        // (options are 0-or-box, so some(0) differs from none).
        // Option-to-option unifies payloads.
        if (yv_l(yr_get(got, "k")) == K_topt) {
            return teq(yr_get(got, "of"), yr_get(want, "of"));
        } else {
            return 0;
        }
    } else if (yv_l(yr_get(got, "k")) == K_trec) {
        return 0;
    } else if (yv_l(yr_get(want, "k")) == K_trec) {
        return 0;
    } else if (yv_l(yr_get(got, "k")) == K_tstr) {
        if (yv_l(yr_get(want, "k")) == K_tptr) {
            return 1;
        } else {
            return 0;
        }
    } else if (yv_l(yr_get(got, "k")) == K_tlong) {
        // long widens to float (the only numeric coercion: `2.0 * i` and
        // `x + 1` with a float x both work).
        // long also narrows to byte: there is no cast syntax, so an
        // annotated position is the only place the intent can be stated
        // (`let b: byte = 65`, `bs += n`, a byte-typed parameter).
        // The value is masked to 8 bits where it is stored.
        if (yv_l(yr_get(want, "k")) == K_tfloat) {
            return 1;
        } else if (yv_l(yr_get(want, "k")) == K_tbyte) {
            return 1;
        } else {
            return 0;
        }
    } else if (yv_l(yr_get(got, "k")) == K_tbyte) {
        // byte widens to long (and on to float) — it is an 8-bit unsigned
        // integer, so every value is representable.
        if (yv_l(yr_get(want, "k")) == K_tlong) {
            return 1;
        } else if (yv_l(yr_get(want, "k")) == K_tfloat) {
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
static int arr_lit_adopts(Yv *got, Yv *want, Yv *n) {
    if (yv_l(yr_get(got, "k")) == K_tarr) {
        return arr_lit_adopts_go(got, want, n);
    } else if (yv_l(yr_get(got, "k")) == K_tarrfix) {
        return arr_lit_adopts_go(got, want, n);
    } else {
        return 0;
    }
}

static int arr_lit_adopts_go(Yv *got, Yv *want, Yv *n) {
    if (yv_l(yr_get(want, "k")) == K_tarr) {
        return tcompat(yr_get(got, "of"), yr_get(want, "of"));
    } else if (yv_l(yr_get(want, "k")) == K_tarrfix) {
        if (yv_l(yr_get(got, "k")) == K_tarrfix) {
            if (yv_l(yr_get(got, "n")) == yv_l(yr_get(want, "n"))) {
                return tcompat(yr_get(got, "of"), yr_get(want, "of"));
            } else {
                return 0;
            }
        } else {
            /* A literal of n elements under a [T; N] annotation: n must be N,
             * or the emitter bounds-checks a fixed array against N over a
             * block of n (types.y arr_lit_adopts_go). */
            if (yv_l(n) != yv_l(yr_get(want, "n"))) {
                return 0;
            }
            return tcompat(yr_get(got, "of"), yr_get(want, "of"));
        }
    } else {
        return 0;
    }
}

// The type of an expression (typeof_expr_go), a recursive alias unfolded
// (unfold): the checker looks into it.
static Yv *typeof_expr(Yv *st, Yv *node) {
    yv_nest++;
    if (yv_nest > MAX_NEST) {
        too_deep(ys("an expression"), yr_get(node, "line"), yr_get(node, "col"));
    }
    Yv *r = typeof_expr_go(st, node);
    yv_nest--;
    Yv *t = yr_get(r, "typ");
    if (yv_l(yr_get(t, "k")) == K_tref) {
        return yr(2, "typ", unfold(t), "st", yr_get(r, "st"));
    } else {
        return r;
    }
}

static Yv *typeof_expr_go(Yv *st, Yv *node) {
    Yv *k = yr_get(node, "k");
    if (yv_l(k) == K_num) {
        if (num_is_float(yr_get(node, "v"))) {
            long dp = num_net_exp(yr_get(node, "v"));
            if (dp > 100000 || dp < -100000) {
                /* out of range by thousands of decades: a mistake, not a value.
                 * A literal merely past the double's range (1e400) is still
                 * accepted and becomes inf, as IEEE says. */
                st = fail(st,
                          ys("float literal magnitude out of range (a double holds 10^-308 to 10^308)"),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
            }
            return yr(2, "typ", yr(1, "k", yv_long(K_tfloat)), "st", st);
        } else {
            return yr(2, "typ", yr(1, "k", yv_long(K_tlong)), "st", st);
        }
    } else if (yv_l(k) == K_str) {
        return yr(2, "typ", yr(1, "k", yv_long(K_tstr)), "st", st);
    } else if (yv_l(k) == K_bstr) {
        // b"..." is a [byte] literal (packed bytes, like a Python bytes)
        return yr(2, "typ", yr(2, "k", yv_long(K_tarr), "of", yr(1, "k", yv_long(K_tbyte))), "st", st);
    } else if (yv_l(k) == K_err) {
        // Planted by the parser where the token stream stopped making
        // sense (parser.y has no error channel of its own).
        st = fail(st, yr_get(node, "msg"), yv_l(yr_get(node, "line")),
                  yv_l(yr_get(node, "col")));
        return yr(2, "typ", t_unk(), "st", st);
    } else if (yv_l(k) == K_bool) {
        return yr(2, "typ", yr(1, "k", yv_long(K_tbool)), "st", st);
    } else if (yv_l(k) == K_void) {
        // An absent expression (bare `return;`, a missing else, an empty
        // for-clause): it computes nothing. The empty option is `none`
        // (an id, see below), never this node.
        return yr(2, "typ", yr(1, "k", yv_long(K_tvoid)), "st", st);
    } else if (yv_l(k) == K_id) {
        if (ys_eq_lit(yr_get(node, "v"), "self")) {
            // resolved by the enclosing def pre-pass (stored as _self in st)
            if (yv_l(yr_get(yr_get(st, "self"), "k")) == K_tnone) {
                st = fail(st, ys("'self' outside of a function"),
                          yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
                return yr(2, "typ", t_unk(), "st", st);
            } else if (ret_unknown(yr_get(st, "self"))) {
                st = fail(st, ys("'self' is used before its return type is known (annotate it)"),
                          yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
                return yr(2, "typ", t_unk(), "st", st);
            } else {
                return yr(2, "typ", yr_get(st, "self"), "st", st);
            }
        } else {
            Yv *got = lookup(yr_get(st, "bindings"), yr_get(node, "v"));
            if (ys_eq_lit(yr_get(got, "kind"), "")) {
                if (ys_eq_lit(yr_get(node, "v"), "none")) {
                    // the empty option (type from context via unification)
                    return yr(2, "typ", yr(2, "k", yv_long(K_topt), "of", t_free()),
                              "st", st);
                } else {
                    st = fail(st,
                              ys_cat(ys_cat(ys("undefined variable '"),
                                            yr_get(node, "v")),
                                     ys("'")),
                              yv_l(yr_get(node, "line")),
                              yv_l(yr_get(node, "col")));
                    return yr(2, "typ", t_unk(), "st", st);
                }
            } else if (ret_unknown(yr_get(got, "typ"))) {
                st = fail(st,
                          ys_cat(ys_cat(ys("'"), disp(yr_get(node, "v"))),
                                 ys("' is used before its return type is known (annotate it)")),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", t_unk(), "st", st);
            } else {
                st = check_visible(st, got, yr_get(node, "v"),
                                   yv_l(yr_get(node, "line")),
                                   yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr_get(got, "typ"), "st", st);
            }
        }
    } else if (yv_l(k) == K_un) {
        Yv *r = typeof_expr(st, yr_get(node, "e"));
        st = yr_get(r, "st");
        if (ys_eq_lit(yr_get(node, "op"), "-")) {
            if (yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tfloat) {
                return yr(2, "typ", yr(1, "k", yv_long(K_tfloat)), "st", st);
            } else {
                st = expect_type(st, yr_get(r, "typ"), yr(1, "k", yv_long(K_tlong)),
                                 ys("unary '-'"), yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(1, "k", yv_long(K_tlong)), "st", st);
            }
        } else if (ys_eq_lit(yr_get(node, "op"), "~")) {
            st = expect_type(st, yr_get(r, "typ"), yr(1, "k", yv_long(K_tlong)),
                             ys("unary '~'"), yv_l(yr_get(node, "line")),
                             yv_l(yr_get(node, "col")));
            return yr(2, "typ", yr(1, "k", yv_long(K_tlong)), "st", st);
        } else {
            st = expect_type(st, yr_get(r, "typ"), yr(1, "k", yv_long(K_tbool)),
                             ys("unary '!'"), yv_l(yr_get(node, "line")),
                             yv_l(yr_get(node, "col")));
            return yr(2, "typ", yr(1, "k", yv_long(K_tbool)), "st", st);
        }
    } else if (yv_l(k) == K_addr) {
        // &x (plain local/param) or &a[i] (element address, either array).
        // NOTE: nested ifs, not a `&&` guard (house style — one failure
        // message per shape, and `&&` would be short-circuit anyway).
        if (yv_l(yr_get(yr_get(node, "e"), "k")) == K_id) {
            if (!ys_eq_lit(yr_get(yr_get(node, "e"), "v"), "self")) {
                Yv *got = lookup(yr_get(st, "bindings"),
                                 yr_get(yr_get(node, "e"), "v"));
                if (ys_eq_lit(yr_get(got, "kind"), "")) {
                    st = fail(st,
                              ys_cat(ys_cat(ys("undefined variable '"),
                                            yr_get(yr_get(node, "e"), "v")),
                                     ys("'")),
                              yv_l(yr_get(node, "line")),
                              yv_l(yr_get(node, "col")));
                    return yr(2, "typ", t_unk(), "st", st);
                } else if (ys_eq_lit(yr_get(got, "kind"), "func") ||
                           ys_eq_lit(yr_get(got, "kind"), "intrinsic")) {
                    st = fail(st,
                              ys_cat(ys_cat(ys("cannot take the address of function '"),
                                            yr_get(yr_get(node, "e"), "v")),
                                     ys("'")),
                              yv_l(yr_get(node, "line")),
                              yv_l(yr_get(node, "col")));
                    return yr(2, "typ", t_unk(), "st", st);
                } else if (yv_l(yr_get(yr_get(got, "typ"), "k")) == K_tarr ||
                           yv_l(yr_get(yr_get(got, "typ"), "k")) == K_tarrfix) {
                    /* One rule for BOTH array kinds: &a is not a data address.
                       A slot holds the {len,cap,data} header (fixed arrays are
                       heap blocks too), so `io.read(fd, &buf, n)` let the
                       kernel write over the frame -- the array's own header
                       was the first casualty and the next len(buf) died with
                       SIGSEGV. Use &a[0] (or &a[i]): gen_elem_addr resolves
                       that through header+16 to the data block. */
                    st = fail(st,
                              ys_cat(ys_cat(ys("cannot take the address of a whole array (use &"),
                                            disp(yr_get(yr_get(node, "e"), "v"))),
                                     ys("[i] for elements)")),
                              yv_l(yr_get(node, "line")),
                              yv_l(yr_get(node, "col")));
                    return yr(2, "typ", t_unk(), "st", st);
                } else {
                    st = check_visible(st, got, yr_get(yr_get(node, "e"), "v"),
                                       yv_l(yr_get(node, "line")),
                                       yv_l(yr_get(node, "col")));
                    return yr(2, "typ",
                              yr(2, "k", yv_long(K_tptr), "to", yr_get(got, "typ")),
                              "st", st);
                }
            } else {
                st = fail(st,
                          ys("'&' needs a plain variable (only a local, a parameter or a global has an address)"),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", t_unk(), "st", st);
            }
        } else if (yv_l(yr_get(yr_get(node, "e"), "k")) == K_index) {
            Yv *ix = yr_get(yr_get(node, "e"), "idx");
            Yv *arr = yr_get(yr_get(node, "e"), "arr");
            if (yv_l(yr_get(arr, "k")) == K_id) {
                Yv *got = lookup(yr_get(st, "bindings"), yr_get(arr, "v"));
                if (ys_eq_lit(yr_get(got, "kind"), "")) {
                    st = fail(st,
                              ys_cat(ys_cat(ys("undefined variable '"),
                                            yr_get(arr, "v")),
                                     ys("'")),
                              yv_l(yr_get(node, "line")),
                              yv_l(yr_get(node, "col")));
                    return yr(2, "typ", t_unk(), "st", st);
                } else if (yv_l(yr_get(yr_get(got, "typ"), "k")) == K_tarrfix ||
                           yv_l(yr_get(yr_get(got, "typ"), "k")) == K_tarr) {
                    st = check_visible(st, got, yr_get(arr, "v"),
                                       yv_l(yr_get(node, "line")),
                                       yv_l(yr_get(node, "col")));
                    Yv *r = typeof_expr(st, ix);
                    st = yr_get(r, "st");
                    st = expect_type(st, yr_get(r, "typ"), yr(1, "k", yv_long(K_tlong)),
                                     ys("array index"), yv_l(yr_get(node, "line")),
                                     yv_l(yr_get(node, "col")));
                    return yr(2, "typ",
                              yr(2, "k", yv_long(K_tptr), "to",
                                 yr_get(yr_get(got, "typ"), "of")),
                              "st", st);
                } else {
                    st = fail(st,
                              ys_cat(ys_cat(ys("cannot index "),
                                            tstr(yr_get(got, "typ"))),
                                     ys(" (only arrays)")),
                              yv_l(yr_get(node, "line")),
                              yv_l(yr_get(node, "col")));
                    return yr(2, "typ", t_unk(), "st", st);
                }
            } else {
                // general base (`&grid[0][i]`, `&rec.v[i]`): an element
                // address of any array expression.
                Yv *barr = arr;
                Yv *br = typeof_expr(st, barr);
                st = yr_get(br, "st");
                if (yv_l(yr_get(yr_get(br, "typ"), "k")) == K_tarrfix ||
                    yv_l(yr_get(yr_get(br, "typ"), "k")) == K_tarr) {
                    Yv *r = typeof_expr(st, ix);
                    st = yr_get(r, "st");
                    st = expect_type(st, yr_get(r, "typ"), yr(1, "k", yv_long(K_tlong)),
                                     ys("array index"), yv_l(yr_get(node, "line")),
                                     yv_l(yr_get(node, "col")));
                    return yr(2, "typ",
                              yr(2, "k", yv_long(K_tptr), "to",
                                 yr_get(yr_get(br, "typ"), "of")),
                              "st", st);
                } else {
                    st = fail(st,
                              ys_cat(ys_cat(ys("cannot index "),
                                            tstr(yr_get(br, "typ"))),
                                     ys(" (only arrays)")),
                              yv_l(yr_get(node, "line")),
                              yv_l(yr_get(node, "col")));
                    return yr(2, "typ", t_unk(), "st", st);
                }
            }
        } else {
            st = fail(st,
                      ys("'&' needs a plain variable (only a local, a parameter or a global has an address)"),
                      yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
            return yr(2, "typ", t_unk(), "st", st);
        }
    } else if (yv_l(k) == K_deref) {
        Yv *r = typeof_expr(st, yr_get(node, "e"));
        st = yr_get(r, "st");
        if (yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tptr) {
            return yr(2, "typ", yr_get(yr_get(r, "typ"), "to"), "st", st);
        } else if (yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tunk) {
            return yr(2, "typ", t_unk(), "st", st);
        } else {
            st = fail(st,
                      ys_cat(ys_cat(ys("cannot dereference "),
                                    tstr(yr_get(r, "typ"))),
                             ys(" (need *T)")),
                      yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
            return yr(2, "typ", t_unk(), "st", st);
        }
    } else if (yv_l(k) == K_bin) {
        Yv *l = typeof_expr(st, yr_get(node, "l"));
        Yv *r = typeof_expr(yr_get(l, "st"), yr_get(node, "r"));
        st = yr_get(r, "st");
        Yv *op = yr_get(node, "op");
        // NOTE: one flat `op == "..."` table, deliberately not a `||`
        // chain: each row dispatches to a named helper, and only the two
        // comparison ops share one.
        if (ys_eq_lit(op, "+")) {
            return typeof_arith(st, op, yr_get(l, "typ"), yr_get(r, "typ"),
                                yv_l(yr_get(node, "line")),
                                yv_l(yr_get(node, "col")));
        } else if (ys_eq_lit(op, "-")) {
            return typeof_arith(st, op, yr_get(l, "typ"), yr_get(r, "typ"),
                                yv_l(yr_get(node, "line")),
                                yv_l(yr_get(node, "col")));
        } else if (ys_eq_lit(op, "*")) {
            return typeof_arith(st, op, yr_get(l, "typ"), yr_get(r, "typ"),
                                yv_l(yr_get(node, "line")),
                                yv_l(yr_get(node, "col")));
        } else if (ys_eq_lit(op, "/")) {
            return typeof_arith(st, op, yr_get(l, "typ"), yr_get(r, "typ"),
                                yv_l(yr_get(node, "line")),
                                yv_l(yr_get(node, "col")));
        } else if (ys_eq_lit(op, "%")) {
            return typeof_arith(st, op, yr_get(l, "typ"), yr_get(r, "typ"),
                                yv_l(yr_get(node, "line")),
                                yv_l(yr_get(node, "col")));
        } else if (ys_eq_lit(op, "<")) {
            return typeof_cmp(st, op, yr_get(l, "typ"), yr_get(r, "typ"),
                              yv_l(yr_get(node, "line")),
                              yv_l(yr_get(node, "col")));
        } else if (ys_eq_lit(op, ">")) {
            return typeof_cmp(st, op, yr_get(l, "typ"), yr_get(r, "typ"),
                              yv_l(yr_get(node, "line")),
                              yv_l(yr_get(node, "col")));
        } else if (ys_eq_lit(op, "<=")) {
            return typeof_cmp(st, op, yr_get(l, "typ"), yr_get(r, "typ"),
                              yv_l(yr_get(node, "line")),
                              yv_l(yr_get(node, "col")));
        } else if (ys_eq_lit(op, ">=")) {
            return typeof_cmp(st, op, yr_get(l, "typ"), yr_get(r, "typ"),
                              yv_l(yr_get(node, "line")),
                              yv_l(yr_get(node, "col")));
        } else if (ys_eq_lit(op, "==")) {
            return typeof_eq(st, op, yr_get(l, "typ"), yr_get(r, "typ"),
                             yv_l(yr_get(node, "line")),
                             yv_l(yr_get(node, "col")));
        } else if (ys_eq_lit(op, "!=")) {
            return typeof_eq(st, op, yr_get(l, "typ"), yr_get(r, "typ"),
                             yv_l(yr_get(node, "line")),
                             yv_l(yr_get(node, "col")));
        } else if (ys_eq_lit(op, "&&")) {
            return typeof_logic(st, op, yr_get(l, "typ"), yr_get(r, "typ"),
                                yv_l(yr_get(node, "line")),
                                yv_l(yr_get(node, "col")));
        } else if (ys_eq_lit(op, "||")) {
            return typeof_logic(st, op, yr_get(l, "typ"), yr_get(r, "typ"),
                                yv_l(yr_get(node, "line")),
                                yv_l(yr_get(node, "col")));
        } else if (ys_eq_lit(op, "::")) {
            return typeof_cons(st, yr_get(l, "typ"), yr_get(r, "typ"),
                               yv_l(yr_get(node, "line")),
                               yv_l(yr_get(node, "col")));
        } else if (ys_eq_lit(op, "&")) {
            return typeof_bits(st, op, yr_get(l, "typ"), yr_get(r, "typ"),
                               yv_l(yr_get(node, "line")),
                               yv_l(yr_get(node, "col")));
        } else if (ys_eq_lit(op, "|")) {
            return typeof_bits(st, op, yr_get(l, "typ"), yr_get(r, "typ"),
                               yv_l(yr_get(node, "line")),
                               yv_l(yr_get(node, "col")));
        } else if (ys_eq_lit(op, "^")) {
            return typeof_bits(st, op, yr_get(l, "typ"), yr_get(r, "typ"),
                               yv_l(yr_get(node, "line")),
                               yv_l(yr_get(node, "col")));
        } else if (ys_eq_lit(op, "<<")) {
            return typeof_bits(st, op, yr_get(l, "typ"), yr_get(r, "typ"),
                               yv_l(yr_get(node, "line")),
                               yv_l(yr_get(node, "col")));
        } else if (ys_eq_lit(op, ">>")) {
            return typeof_bits(st, op, yr_get(l, "typ"), yr_get(r, "typ"),
                               yv_l(yr_get(node, "line")),
                               yv_l(yr_get(node, "col")));
        } else if (ys_eq_lit(op, ">>>")) {
            return typeof_bits(st, op, yr_get(l, "typ"), yr_get(r, "typ"),
                               yv_l(yr_get(node, "line")),
                               yv_l(yr_get(node, "col")));
        } else {
            st = fail(st,
                      ys_cat(ys_cat(ys("operator '"), op),
                             ys("' is unsupported in native mode")),
                      yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
            return yr(2, "typ", t_unk(), "st", st);
        }
    } else if (yv_l(k) == K_call) {
        return typeof_call(st, node);
    } else if (yv_l(k) == K_kw_if) {
        Yv *c = typeof_expr(st, yr_get(node, "cond"));
        st = expect_type(yr_get(c, "st"), yr_get(c, "typ"), yr(1, "k", yv_long(K_tbool)),
                         ys("'if' condition"), yv_l(yr_get(node, "line")),
                         yv_l(yr_get(node, "col")));
        // NOTE: typeof_expr, not typeof_block — `els` may be a nested `if`
        // (else-if chain), not a block.
        Yv *t = typeof_expr(st, yr_get(node, "then"));
        st = yr_get(t, "st");
        if (yv_truth(yr_get(node, "has_else"))) {
            Yv *e = typeof_expr(st, yr_get(node, "els"));
            st = yr_get(e, "st");
            if (teq(yr_get(t, "typ"), yr_get(e, "typ"))) {
                // An arm of unknown type -- typically a self call, whose
                // type is the one being inferred -- takes the other's.
                Yv *tt = yr_get(t, "typ");
                Yv *et = yr_get(e, "typ");
                if (yv_l(yr_get(tt, "k")) == K_tunk && yv_l(yr_get(et, "k")) != K_tnone) { return yr(2, "typ", et, "st", st); } else { return yr(2, "typ", tt, "st", st); }
            } else {
                // VOID law: arms that disagree on a type (a value arm vs a
                // statement arm, or two different values) make the whole
                // `if` a statement -- void, not usable as a value. Using it
                // as one errors at that use (binding, argument, print...).
                return yr(2, "typ", yr(1, "k", yv_long(K_tvoid)), "st", st);
            }
        } else {
            // VOID law: an `if` without `else` is a STATEMENT — its value is
            // nothing, whatever the then-branch computes. No forced else
            // branch, no forced `0;` tail in user programs.
            return yr(2, "typ", yr(1, "k", yv_long(K_tvoid)), "st", st);
        }
    } else if (yv_l(k) == K_kw_while) {
        Yv *c = typeof_expr(st, yr_get(node, "cond"));
        st = expect_type(yr_get(c, "st"), yr_get(c, "typ"), yr(1, "k", yv_long(K_tbool)),
                         ys("'while' condition"), yv_l(yr_get(node, "line")),
                         yv_l(yr_get(node, "col")));
        Yv *b = typeof_block(st, yr_get(node, "body"));
        return yr(2, "typ", yr(1, "k", yv_long(K_tvoid)), "st", yr_get(b, "st"));
    } else if (yv_l(k) == K_kw_for) {
        // for (init; cond; step) body — init/step are statements, and the
        // loop variable stays visible afterwards (same scope rule as `let`).
        Yv *fi = typeof_expr(st, yr_get(node, "init"));
        st = yr_get(fi, "st");
        Yv *fc = typeof_expr(st, yr_get(node, "cond"));
        st = expect_type(yr_get(fc, "st"), yr_get(fc, "typ"),
                         yr(1, "k", yv_long(K_tbool)), ys("'for' condition"),
                         yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
        Yv *fb = typeof_block(st, yr_get(node, "body"));
        st = yr_get(fb, "st");
        Yv *fs = typeof_expr(st, yr_get(node, "step"));
        return yr(2, "typ", yr(1, "k", yv_long(K_tvoid)), "st", yr_get(fs, "st"));
    } else if (yv_l(k) == K_kw_foreach) {
        // foreach (x in arr) body — x takes the array's element type.
        Yv *fe = typeof_expr(st, yr_get(node, "iter"));
        st = yr_get(fe, "st");
        Yv *elt = t_unk();
        if (yv_l(yr_get(yr_get(fe, "typ"), "k")) == K_tarr) {
            elt = yr_get(yr_get(fe, "typ"), "of");
            ;
        } else if (yv_l(yr_get(yr_get(fe, "typ"), "k")) == K_tarrfix) {
            elt = yr_get(yr_get(fe, "typ"), "of");
            ;
        } else if (yv_l(yr_get(yr_get(fe, "typ"), "k")) == K_tunk) {
            ;
        } else {
            st = fail(st,
                      ys_cat(ys("'foreach' needs an array, got "),
                             tstr(yr_get(fe, "typ"))),
                      yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
            ;
        }
        st = st_bind(st, yr_get(node, "name"), elt, ys("local"));
        Yv *fbb = typeof_block(st, yr_get(node, "body"));
        return yr(2, "typ", yr(1, "k", yv_long(K_tvoid)), "st", yr_get(fbb, "st"));
    } else if (yv_l(k) == K_forrange) {
        // for x in lo..hi { body } — x is a long.
        Yv *rl = typeof_expr(st, yr_get(node, "lo"));
        st = expect_type(yr_get(rl, "st"), yr_get(rl, "typ"),
                         yr(1, "k", yv_long(K_tlong)), ys("'for' range start"),
                         yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
        Yv *rh = typeof_expr(st, yr_get(node, "hi"));
        st = expect_type(yr_get(rh, "st"), yr_get(rh, "typ"),
                         yr(1, "k", yv_long(K_tlong)), ys("'for' range end"),
                         yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
        st = st_bind(st, yr_get(node, "name"), yr(1, "k", yv_long(K_tlong)),
                     ys("local"));
        Yv *rb = typeof_block(st, yr_get(node, "body"));
        return yr(2, "typ", yr(1, "k", yv_long(K_tvoid)), "st", yr_get(rb, "st"));
    } else if (yv_l(k) == K_block) {
        return typeof_block(st, node);
    } else if (yv_l(k) == K_decl) {
        return typeof_decl(st, node);
    } else if (yv_l(k) == K_assign) {
        Yv *got = lookup(yr_get(st, "bindings"), yr_get(node, "name"));
        Yv *r = typeof_want(st, yr_get(node, "v"), yr_get(got, "typ"));
        st = yr_get(r, "st");
        if (ys_eq_lit(yr_get(got, "kind"), "")) {
            st = fail(st,
                      ys_cat(ys_cat(ys("undefined variable '"),
                                    disp(yr_get(node, "name"))),
                             ys("'")),
                      yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
            return yr(2, "typ", t_unk(), "st", st);
        } else if (ys_eq_lit(yr_get(got, "kind"), "func") ||
                   ys_eq_lit(yr_get(got, "kind"), "intrinsic")) {
            st = fail(st,
                      ys_cat(ys_cat(ys("cannot assign to function '"),
                                    disp(yr_get(node, "name"))),
                             ys("'")),
                      yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
            return yr(2, "typ", t_unk(), "st", st);
        } else if (ys_eq_lit(yr_get(got, "kind"), "const")) {
            st = fail(st,
                      ys_cat(ys_cat(ys("cannot assign to constant '"),
                                    disp(yr_get(node, "name"))),
                             ys("'")),
                      yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
            return yr(2, "typ", yr_get(got, "typ"), "st", st);
        } else if (yv_l(yr_get(yr_get(got, "typ"), "k")) == K_tarrfix) {
            st = check_visible(st, got, yr_get(node, "name"),
                               yv_l(yr_get(node, "line")),
                               yv_l(yr_get(node, "col")));
            st = expect_type(st, yr_get(r, "typ"), yr_get(got, "typ"),
                             ys_cat(ys_cat(ys("assignment to '"),
                                           disp(yr_get(node, "name"))),
                                    ys("'")),
                             yv_l(yr_get(node, "line")),
                             yv_l(yr_get(node, "col")));
            return yr(2, "typ", yr_get(got, "typ"), "st", st);
        } else {
            st = check_visible(st, got, yr_get(node, "name"),
                               yv_l(yr_get(node, "line")),
                               yv_l(yr_get(node, "col")));
            st = expect_type(st, yr_get(r, "typ"), yr_get(got, "typ"),
                             ys_cat(ys_cat(ys("assignment to '"),
                                           disp(yr_get(node, "name"))),
                                    ys("'")),
                             yv_l(yr_get(node, "line")),
                             yv_l(yr_get(node, "col")));
            return yr(2, "typ", yr_get(got, "typ"), "st", st);
        }
    } else if (yv_l(k) == K_incdec) {
        // ++x / x++: numbers only — `s++` on a string would silently
        // concatenate, so it is a type error instead.
        Yv *t = typeof_expr(st, yr_get(node, "tgt"));
        Yv *pc = place_check(yr_get(t, "st"), yr_get(node, "tgt"),
                             yr_get(t, "typ"), yr_get(node, "op"),
                             yv_l(yr_get(node, "line")),
                             yv_l(yr_get(node, "col")));
        st = const_check(yr_get(pc, "st"), yr_get(node, "tgt"),
                         yr_get(pc, "typ"), yr_get(node, "op"),
                         yv_l(yr_get(node, "line")),
                         yv_l(yr_get(node, "col")));
        return incdec_check(st, node, yr_get(pc, "typ"));
    } else if (yv_l(k) == K_opassign) {
        // `x op= e`: the rules live in opassign_check.
        Yv *t = typeof_expr(st, yr_get(node, "tgt"));
        st = yr_get(t, "st");
        // `arr += {...}` / `arr *= {...}`: a record literal is an element
        Yv *tt = yr_get(t, "typ");
        Yv *vw = yr(1, "k", yv_long(K_tnone));
        if (yv_l(yr_get(tt, "k")) == K_tarr || yv_l(yr_get(tt, "k")) == K_tarrfix) {
            vw = yr_get(tt, "of");
        }
        Yv *v = typeof_want(st, yr_get(node, "v"), vw);
        Yv *pc = place_check(yr_get(v, "st"), yr_get(node, "tgt"),
                             yr_get(t, "typ"),
                             ys_cat(yr_get(node, "op"), ys("=")),
                             yv_l(yr_get(node, "line")),
                             yv_l(yr_get(node, "col")));
        st = const_check(yr_get(pc, "st"), yr_get(node, "tgt"),
                         yr_get(pc, "typ"),
                         ys_cat(yr_get(node, "op"), ys("=")),
                         yv_l(yr_get(node, "line")),
                         yv_l(yr_get(node, "col")));
        return opassign_check(st, node, yr_get(pc, "typ"), yr_get(v, "typ"));
    } else if (yv_l(k) == K_store) {
        Yv *p = typeof_expr(st, yr_get(node, "p"));
        Yv *pt = yr_get(p, "typ");
        Yv *pw = yr(1, "k", yv_long(K_tnone));
        if (yv_l(yr_get(pt, "k")) == K_tptr) {
            pw = yr_get(pt, "to");
        }
        Yv *v = typeof_want(yr_get(p, "st"), yr_get(node, "v"), pw);
        st = yr_get(v, "st");
        if (yv_l(yr_get(yr_get(p, "typ"), "k")) == K_tptr) {
            st = expect_type(st, yr_get(v, "typ"),
                             yr_get(yr_get(p, "typ"), "to"),
                             ys("store through pointer"),
                             yv_l(yr_get(node, "line")),
                             yv_l(yr_get(node, "col")));
            return yr(2, "typ", yr_get(yr_get(p, "typ"), "to"), "st", st);
        } else if (yv_l(yr_get(yr_get(p, "typ"), "k")) == K_tunk ||
                   yv_l(yr_get(yr_get(v, "typ"), "k")) == K_tunk) {
            return yr(2, "typ", t_unk(), "st", st);
        } else {
            st = fail(st,
                      ys_cat(ys("store target must be *T, got "),
                             tstr(yr_get(p, "typ"))),
                      yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
            return yr(2, "typ", t_unk(), "st", st);
        }
    } else if (yv_l(k) == K_ret) {
        if (yv_l(yr_get(yr_get(st, "ret"), "k")) == K_tnone) {
            st = fail(st, ys("'return' outside of a function"),
                      yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
            return yr(2, "typ", t_unk(), "st", st);
        } else {
            Yv *r = typeof_want(st, yr_get(node, "e"), yr_get(st, "ret"));
            Yv *rk = yr_get(yr_get(st, "ret"), "k");
            if (yv_l(rk) == K_tinfer) {
                // The def's return type is still being inferred: note the
                // value's type, which typeof_def checks once the body's
                // trailing type is known. A bare `return;` returns nothing,
                // so as the body's tail it makes the def void.
                ret_note(yr_get(st, "ret"), yr_get(r, "typ"),
                         yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr_get(r, "typ"), "st", yr_get(r, "st"));
            } else {
                st = expect_cast(yr_get(r, "st"), yr_get(r, "typ"),
                                 yr_get(st, "ret"), ys("'return'"),
                                 yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col")));
                if (yv_l(rk) == K_tunk) { return yr(2, "typ", yr_get(r, "typ"), "st", st); } else { return yr(2, "typ", yr_get(st, "ret"), "st", st); }
            }
        }
    } else if (yv_l(k) == K_rec) {
        // Record literal { k: v, ... }: every value checked, the type is a
        // trec with field names in order.
        Yv *mkeys = yr_get(node, "keys");
        Yv *mvals = yr_get(node, "vals");
        if (yv_len(mkeys) == 0) {
            // The empty literal `{}` is an empty record ({} prints as {}).
            // Under a map annotation it IS the map instead -- that adoption
            // happens in typeof_decl (and the emitter lowers it there).
            return yr(2, "typ", yr(2, "k", yv_long(K_trec), "fields", yav(0)), "st", st);
        } else {
            Yv *fields = yav(0);
            long i = 0;
            int ok = 1;
            while (i < yv_len(mkeys)) {
                // NOTE: each bound once — flow-snapshot: `vals` is a bare
                // node field, so reading `mvals[i]` inline would re-read the
                // node through whatever shape the env holds for it.
                Yv *mvv = ya_get(mvals, i);
                Yv *mkey = ya_get(mkeys, i);
                Yv *r = typeof_expr(st, mvv);
                st = yr_get(r, "st");
                if (ys_eq_lit(mkey, "...")) {
                    // Static spread `...obj`: the union of the two shapes
                    // (field_merge: later wins the value, first appearance
                    // keeps the position). No dynamic shape is involved.
                    if (yv_l(yr_get(yr_get(r, "typ"), "k")) == K_trec) {
                        Yv *sfs = yr_get(yr_get(r, "typ"), "fields");
                        long si = 0;
                        while (si < yv_len(sfs)) {
                            Yv *sf = ya_get(sfs, si);
                            fields = field_merge(fields, yr_get(sf, "name"),
                                                 yr_get(sf, "typ"));
                            si = si + 1;
                        }
                        ;
                    } else if (yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tunk ||
                               yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tnone ||
                               yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tname) {
                        // poison quietly (tcompat law)
                        ok = 0;
                        ;
                    } else {
                        st = fail(st,
                                  ys_cat(ys("'...' spread needs a record, got "),
                                         tstr(yr_get(r, "typ"))),
                                  yv_l(yr_get(node, "line")),
                                  yv_l(yr_get(node, "col")));
                        ok = 0;
                        ;
                    }
                    ;
                } else if (yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tnone) {
                    // unannotated value shape (tcompat law): the missing
                    // annotation errors once at its own site; don't cascade
                    // here, but poison the record so uses don't mistype.
                    ok = 0;
                    ;
                } else if (yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tname) {
                    ok = 0;
                    ;
                } else if (!is_value_type(yr_get(r, "typ"))) {
                    st = fail(st,
                              ys_cat(ys_cat(ys_cat(ys("record field '"), mkey),
                                            ys("' has unsupported type ")),
                                     tstr(yr_get(r, "typ"))),
                              yv_l(yr_get(node, "line")),
                              yv_l(yr_get(node, "col")));
                    ok = 0;
                    ;
                }
                if (ys_eq_lit(mkey, "...")) {
                    ;
                } else {
                    fields = field_merge(fields, mkey, yr_get(r, "typ"));
                    ;
                }
                i = i + 1;
            }
            if (ok) {
                return yr(2, "typ", yr(2, "k", yv_long(K_trec), "fields", fields),
                          "st", st);
            } else {
                return yr(2, "typ", t_unk(), "st", st);
            }
        }
    } else if (yv_l(k) == K_map) {
        // Map literal { "k": v, ... }: quoted keys (so the key type is
        // str), homogeneous values -- the first entry's type wins and
        // later entries must match. Duplicate keys collapse at emit time
        // (last entry wins the value, first appearance the position).
        // Spread is record-only.
        Yv *gkeys = yr_get(node, "keys");
        Yv *gvals = yr_get(node, "vals");
        int gok = 1;
        long gi = 0;
        Yv *gt = t_unk();
        while (gi < yv_len(gvals)) {
            Yv *gk = ya_get(gkeys, gi);
            Yv *gr = typeof_expr(st, ya_get(gvals, gi));
            st = yr_get(gr, "st");
            if (ys_eq_lit(gk, "...")) {
                st = fail(st, ys("'...' spread is record-only (a map literal takes key: value entries)"), yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
                gok = 0;
                ;
            } else if (gi == 0) {
                gt = yr_get(gr, "typ");
                ;
            } else {
                st = expect_type(st, yr_get(gr, "typ"), gt, ys("map value"), yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
                ;
            }
            gi = gi + 1;
        }
        if (gok) {
            return yr(2, "typ", map_type_of(gt), "st", st);
        } else {
            return yr(2, "typ", t_unk(), "st", st);
        }
    } else if (yv_l(k) == K_dot) {
        // The object type is bound once: the checker env is flow-insensitive,
        // so re-reading node.obj after a rebind could resolve against the
        // wrong shape.
        Yv *dobj = yr_get(node, "obj");
        Yv *dkey = yr_get(node, "key");
        Yv *r = typeof_expr(st, dobj);
        return typeof_field(yr_get(r, "st"), yr_get(r, "typ"), dkey,
                            yv_l(yr_get(node, "line")),
                            yv_l(yr_get(node, "col")));
    } else if (yv_l(k) == K_func) {
        // Anonymous function literal in expression position. Check the body
        // like a named def would be, and give the expression its tfunc type;
        // the emitter closure-converts it with a generated label.
        Yv *ra = typeof_def(st, ys(""), node, yv_l(yr_get(node, "line")),
                            yv_l(yr_get(node, "col")));
        return yr(2, "typ", yr_get(ra, "typ"), "st", yr_get(ra, "st"));
    } else if (yv_l(k) == K_arrrep) {
        // [v; n]: n stack slots filled with v (the native array form)
        Yv *r = typeof_expr(st, yr_get(node, "v"));
        st = yr_get(r, "st");
        if (!is_value_type(yr_get(r, "typ"))) {
            st = fail(st,
                      ys_cat(ys_cat(ys("array element type "),
                                    tstr(yr_get(r, "typ"))),
                             ys(" is unsupported in native mode")),
                      yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
            return yr(2, "typ", t_unk(), "st", st);
        } else {
            // n is a literal from 0 to 2^31 - 1 (parser.c size_lit)
            return yr(2, "typ",
                      yr(3, "k", yv_long(K_tarrfix), "of", yr_get(r, "typ"), "n",
                         yr_get(node, "n")),
                      "st", st);
        }
    } else if (yv_l(k) == K_index) {
        // A plain-variable base (the `id` arm) and an arbitrary expression
        // base (the else arm: `grid[0][1]`, `rec.v[i]`, `f()[i]`) both work.
        // Plain locals, params, AND function params of array type alike: the
        // frame slot or the heap header addresses them directly; bounds are
        // checked at runtime. Fixed [T; N] and heap [T] alike. Params of
        // tunk (missing annotation) error elsewhere — here they poison
        // quietly to avoid cascades.
        if (yv_l(yr_get(yr_get(node, "arr"), "k")) == K_id) {
            Yv *got = lookup(yr_get(st, "bindings"),
                             yr_get(yr_get(node, "arr"), "v"));
            if (ys_eq_lit(yr_get(got, "kind"), "")) {
                st = fail(st,
                          ys_cat(ys_cat(ys("undefined variable '"),
                                        yr_get(yr_get(node, "arr"), "v")),
                                 ys("'")),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", t_unk(), "st", st);
            } else if (yv_l(yr_get(yr_get(got, "typ"), "k")) == K_tarrfix ||
                       yv_l(yr_get(yr_get(got, "typ"), "k")) == K_tarr) {
                st = check_visible(st, got, yr_get(yr_get(node, "arr"), "v"),
                                   yv_l(yr_get(node, "line")),
                                   yv_l(yr_get(node, "col")));
                Yv *r = typeof_expr(st, yr_get(node, "idx"));
                st = yr_get(r, "st");
                st = expect_type(st, yr_get(r, "typ"), yr(1, "k", yv_long(K_tlong)),
                                 ys("array index"), yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr_get(yr_get(got, "typ"), "of"), "st", st);
            } else if (yv_l(yr_get(yr_get(got, "typ"), "k")) == K_tmap) {
                // m[k]: the key must match K; a read is ALWAYS optional --
                // V? for any V (none when the key is missing).
                st = check_visible(st, got, yr_get(yr_get(node, "arr"), "v"),
                                   yv_l(yr_get(node, "line")),
                                   yv_l(yr_get(node, "col")));
                Yv *r = typeof_expr(st, yr_get(node, "idx"));
                st = yr_get(r, "st");
                st = expect_type(st, yr_get(r, "typ"), yr_get(yr_get(got, "typ"), "key"),
                                 ys("map key"), yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(2, "k", yv_long(K_topt), "of", yr_get(yr_get(got, "typ"), "of")), "st", st);
            } else if (yv_l(yr_get(yr_get(got, "typ"), "k")) == K_tstr) {
                // s[i]: the byte at i (trapped when out of bounds)
                st = check_visible(st, got, yr_get(yr_get(node, "arr"), "v"),
                                   yv_l(yr_get(node, "line")),
                                   yv_l(yr_get(node, "col")));
                Yv *r = typeof_expr(st, yr_get(node, "idx"));
                st = yr_get(r, "st");
                st = expect_type(st, yr_get(r, "typ"), yr(1, "k", yv_long(K_tlong)),
                                 ys("string index"), yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(1, "k", yv_long(K_tbyte)), "st", st);
            } else if (yv_l(yr_get(yr_get(got, "typ"), "k")) == K_tunk ||
                       yv_l(yr_get(yr_get(got, "typ"), "k")) == K_tnone ||
                       yv_l(yr_get(yr_get(got, "typ"), "k")) == K_tname) {
                Yv *r = typeof_expr(st, yr_get(node, "idx"));
                st = yr_get(r, "st");
                return yr(2, "typ", t_unk(), "st", st);
            } else {
                st = fail(st,
                          ys_cat(ys_cat(ys("cannot index "),
                                        tstr(yr_get(got, "typ"))),
                                 ys(" (only arrays and maps)")),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", t_unk(), "st", st);
            }
        } else {
            // Any expression of array type: `grid[0][1]`, `rec.v[i]`,
            // `f()[i]`. The base runs once at runtime; its static type
            // carries the element type.
            Yv *barr = yr_get(node, "arr");
            Yv *br = typeof_expr(st, barr);
            st = yr_get(br, "st");
            if (yv_l(yr_get(yr_get(br, "typ"), "k")) == K_tarrfix ||
                yv_l(yr_get(yr_get(br, "typ"), "k")) == K_tarr) {
                Yv *ri = typeof_expr(st, yr_get(node, "idx"));
                st = yr_get(ri, "st");
                st = expect_type(st, yr_get(ri, "typ"), yr(1, "k", yv_long(K_tlong)),
                                 ys("array index"), yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr_get(yr_get(br, "typ"), "of"), "st", st);
            } else if (yv_l(yr_get(yr_get(br, "typ"), "k")) == K_tmap) {
                Yv *ri = typeof_expr(st, yr_get(node, "idx"));
                st = yr_get(ri, "st");
                st = expect_type(st, yr_get(ri, "typ"), yr_get(yr_get(br, "typ"), "key"),
                                 ys("map key"), yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(2, "k", yv_long(K_topt), "of", yr_get(yr_get(br, "typ"), "of")), "st", st);
            } else if (yv_l(yr_get(yr_get(br, "typ"), "k")) == K_tstr) {
                Yv *ri = typeof_expr(st, yr_get(node, "idx"));
                st = yr_get(ri, "st");
                st = expect_type(st, yr_get(ri, "typ"), yr(1, "k", yv_long(K_tlong)),
                                 ys("string index"), yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(1, "k", yv_long(K_tbyte)), "st", st);
            } else if (yv_l(yr_get(yr_get(br, "typ"), "k")) == K_tunk ||
                       yv_l(yr_get(yr_get(br, "typ"), "k")) == K_tnone ||
                       yv_l(yr_get(yr_get(br, "typ"), "k")) == K_tname) {
                // poison quietly (tcompat law) — the missing annotation
                // reports at its own site.
                Yv *ri = typeof_expr(st, yr_get(node, "idx"));
                st = yr_get(ri, "st");
                return yr(2, "typ", t_unk(), "st", st);
            } else {
                st = fail(st,
                          ys_cat(ys_cat(ys("cannot index "),
                                        tstr(yr_get(br, "typ"))),
                                 ys(" (only arrays and maps)")),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", t_unk(), "st", st);
            }
        }
    } else if (yv_l(k) == K_slice) {
        // arr[lo:hi] -> a new array of the same element type. Missing
        // bounds default to 0 / len; the result is always a heap [T],
        // even when slicing a fixed [T; N].
        Yv *sr = typeof_expr(st, yr_get(node, "arr"));
        st = yr_get(sr, "st");
        Yv *slo = yr_get(node, "lo");
        Yv *shi = yr_get(node, "hi");
        if (yv_l(yr_get(slo, "k")) == K_void) {
            ;
        } else {
            Yv *rl = typeof_expr(st, slo);
            st = expect_type(yr_get(rl, "st"), yr_get(rl, "typ"),
                             yr(1, "k", yv_long(K_tlong)), ys("slice start"),
                             yv_l(yr_get(node, "line")),
                             yv_l(yr_get(node, "col")));
            ;
        }
        if (yv_l(yr_get(shi, "k")) == K_void) {
            ;
        } else {
            Yv *rh = typeof_expr(st, shi);
            st = expect_type(yr_get(rh, "st"), yr_get(rh, "typ"),
                             yr(1, "k", yv_long(K_tlong)), ys("slice end"),
                             yv_l(yr_get(node, "line")),
                             yv_l(yr_get(node, "col")));
            ;
        }
        if (yv_l(yr_get(yr_get(sr, "typ"), "k")) == K_tarr) {
            return yr(2, "typ",
                      yr(2, "k", yv_long(K_tarr), "of",
                         yr_get(yr_get(sr, "typ"), "of")),
                      "st", st);
        } else if (yv_l(yr_get(yr_get(sr, "typ"), "k")) == K_tarrfix) {
            return yr(2, "typ",
                      yr(2, "k", yv_long(K_tarr), "of",
                         yr_get(yr_get(sr, "typ"), "of")),
                      "st", st);
        } else if (yv_l(yr_get(yr_get(sr, "typ"), "k")) == K_tstr) {
            // s[lo:hi] -> the substring (bounds clamped, like an array slice)
            return yr(2, "typ", yr(1, "k", yv_long(K_tstr)), "st", st);
        } else if (yv_l(yr_get(yr_get(sr, "typ"), "k")) == K_tunk) {
            return yr(2, "typ", t_unk(), "st", st);
        } else {
            st = fail(st,
                      ys_cat(ys_cat(ys("cannot slice "), tstr(yr_get(sr, "typ"))),
                             ys(" (only arrays)")),
                      yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
            return yr(2, "typ", t_unk(), "st", st);
        }
    } else if (yv_l(k) == K_dotassign) {
        // s.f = v — in-place record field write. The object may be a plain
        // variable (`id` arm) or any record-valued expression (`a[0].f`,
        // `x.y.f` — else arm); the field must exist in its static shape
        // (checked at the record literal / annotation site).
        if (yv_l(yr_get(yr_get(node, "obj"), "k")) == K_id) {
            Yv *got = lookup(yr_get(st, "bindings"),
                             yr_get(yr_get(node, "obj"), "v"));
            if (ys_eq_lit(yr_get(got, "kind"), "")) {
                st = fail(st,
                          ys_cat(ys_cat(ys("undefined variable '"),
                                        yr_get(yr_get(node, "obj"), "v")),
                                 ys("'")),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", t_unk(), "st", st);
            } else if (yv_l(yr_get(unfold(yr_get(got, "typ")), "k")) == K_trec) {
                Yv *ft = trec_field_type(unfold(yr_get(got, "typ")),
                                         yr_get(node, "key"));
                if (yv_l(yr_get(ft, "k")) == K_tnone) {
                    st = fail(st,
                              ys_cat(ys_cat(ys("record has no field '"),
                                            yr_get(node, "key")),
                                     ys("'")),
                              yv_l(yr_get(node, "line")),
                              yv_l(yr_get(node, "col")));
                    return yr(2, "typ", t_unk(), "st", st);
                } else {
                    Yv *v = typeof_want(st, yr_get(node, "v"), ft);
                    st = yr_get(v, "st");
                    st = expect_type(st, yr_get(v, "typ"), ft,
                                     ys_cat(ys_cat(ys("record field '"),
                                                   yr_get(node, "key")),
                                            ys("'")),
                                     yv_l(yr_get(node, "line")),
                                     yv_l(yr_get(node, "col")));
                    return yr(2, "typ", ft, "st", st);
                }
            } else if (yv_l(yr_get(unfold(yr_get(got, "typ")), "k")) == K_tunion) {
                return dotassign_union(st, unfold(yr_get(got, "typ")), node);
            } else {
                st = fail(st,
                          ys_cat(ys_cat(ys("cannot field-assign "),
                                        tstr(yr_get(got, "typ"))),
                                 ys(" (only records)")),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", t_unk(), "st", st);
            }
        } else {
            // General object (`a[0].f = v`, `x.y.f = v`): the object
            // expression's static type must be a record with the field.
            Yv *dobj2 = yr_get(node, "obj");
            Yv *obr = typeof_expr(st, dobj2);
            st = yr_get(obr, "st");
            if (yv_l(yr_get(yr_get(obr, "typ"), "k")) == K_trec) {
                Yv *ft = trec_field_type(yr_get(obr, "typ"), yr_get(node, "key"));
                if (yv_l(yr_get(ft, "k")) == K_tnone) {
                    st = fail(st,
                              ys_cat(ys_cat(ys("record has no field '"),
                                            yr_get(node, "key")),
                                     ys("'")),
                              yv_l(yr_get(node, "line")),
                              yv_l(yr_get(node, "col")));
                    return yr(2, "typ", t_unk(), "st", st);
                } else {
                    Yv *v = typeof_want(st, yr_get(node, "v"), ft);
                    st = yr_get(v, "st");
                    st = expect_type(st, yr_get(v, "typ"), ft,
                                     ys_cat(ys_cat(ys("record field '"),
                                                   yr_get(node, "key")),
                                            ys("'")),
                                     yv_l(yr_get(node, "line")),
                                     yv_l(yr_get(node, "col")));
                    return yr(2, "typ", ft, "st", st);
                }
            } else if (yv_l(yr_get(yr_get(obr, "typ"), "k")) == K_tunion) {
                return dotassign_union(st, yr_get(obr, "typ"), node);
            } else {
                st = fail(st,
                          ys_cat(ys_cat(ys("cannot field-assign "),
                                        tstr(yr_get(obr, "typ"))),
                                 ys(" (only records)")),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", t_unk(), "st", st);
            }
        }
    } else if (yv_l(k) == K_idxassign) {
        if (yv_l(yr_get(yr_get(node, "arr"), "k")) == K_id) {
            Yv *got = lookup(yr_get(st, "bindings"),
                             yr_get(yr_get(node, "arr"), "v"));
            if (ys_eq_lit(yr_get(got, "kind"), "")) {
                st = fail(st,
                          ys_cat(ys_cat(ys("undefined variable '"),
                                        yr_get(yr_get(node, "arr"), "v")),
                                 ys("'")),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", t_unk(), "st", st);
            } else if (yv_l(yr_get(yr_get(got, "typ"), "k")) == K_tarrfix ||
                       yv_l(yr_get(yr_get(got, "typ"), "k")) == K_tarr) {
                st = check_visible(st, got, yr_get(yr_get(node, "arr"), "v"),
                                   yv_l(yr_get(node, "line")),
                                   yv_l(yr_get(node, "col")));
                Yv *ix = typeof_expr(st, yr_get(node, "idx"));
                st = yr_get(ix, "st");
                st = expect_type(st, yr_get(ix, "typ"), yr(1, "k", yv_long(K_tlong)),
                                 ys("array index"), yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col")));
                Yv *v = typeof_want(st, yr_get(node, "v"), yr_get(yr_get(got, "typ"), "of"));
                st = yr_get(v, "st");
                st = expect_type(st, yr_get(v, "typ"),
                                 yr_get(yr_get(got, "typ"), "of"),
                                 ys("array element"), yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr_get(yr_get(got, "typ"), "of"), "st", st);
            } else if (yv_l(yr_get(yr_get(got, "typ"), "k")) == K_tmap) {
                // m[k] = v: the key matches K and the value V (the store is
                // in place -- every alias of the map sees it).
                st = check_visible(st, got, yr_get(yr_get(node, "arr"), "v"),
                                   yv_l(yr_get(node, "line")),
                                   yv_l(yr_get(node, "col")));
                Yv *ix = typeof_expr(st, yr_get(node, "idx"));
                st = yr_get(ix, "st");
                st = expect_type(st, yr_get(ix, "typ"), yr_get(yr_get(got, "typ"), "key"),
                                 ys("map key"), yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col")));
                Yv *v = typeof_want(st, yr_get(node, "v"), yr_get(yr_get(got, "typ"), "of"));
                st = yr_get(v, "st");
                st = expect_type(st, yr_get(v, "typ"),
                                 yr_get(yr_get(got, "typ"), "of"),
                                 ys("map value"), yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr_get(yr_get(got, "typ"), "of"), "st", st);
            } else {
                st = fail(st,
                          ys_cat(ys_cat(ys("cannot index "),
                                        tstr(yr_get(got, "typ"))),
                                 ys(" (only arrays and maps)")),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", t_unk(), "st", st);
            }
        } else {
            // General base (`grid[0][1] = v`, `rec.v[i] = v`): the base
            // expression's static type must be an array of the value type.
            Yv *barr = yr_get(node, "arr");
            Yv *br = typeof_expr(st, barr);
            st = yr_get(br, "st");
            if (yv_l(yr_get(yr_get(br, "typ"), "k")) == K_tarrfix ||
                yv_l(yr_get(yr_get(br, "typ"), "k")) == K_tarr) {
                Yv *ix = typeof_expr(st, yr_get(node, "idx"));
                st = yr_get(ix, "st");
                st = expect_type(st, yr_get(ix, "typ"), yr(1, "k", yv_long(K_tlong)),
                                 ys("array index"), yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col")));
                Yv *v = typeof_want(st, yr_get(node, "v"), yr_get(yr_get(br, "typ"), "of"));
                st = yr_get(v, "st");
                st = expect_type(st, yr_get(v, "typ"),
                                 yr_get(yr_get(br, "typ"), "of"),
                                 ys("array element"), yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr_get(yr_get(br, "typ"), "of"), "st", st);
            } else if (yv_l(yr_get(yr_get(br, "typ"), "k")) == K_tmap) {
                Yv *ix = typeof_expr(st, yr_get(node, "idx"));
                st = yr_get(ix, "st");
                st = expect_type(st, yr_get(ix, "typ"), yr_get(yr_get(br, "typ"), "key"),
                                 ys("map key"), yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col")));
                Yv *v = typeof_want(st, yr_get(node, "v"), yr_get(yr_get(br, "typ"), "of"));
                st = yr_get(v, "st");
                st = expect_type(st, yr_get(v, "typ"),
                                 yr_get(yr_get(br, "typ"), "of"),
                                 ys("map value"), yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr_get(yr_get(br, "typ"), "of"), "st", st);
            } else if (yv_l(yr_get(yr_get(br, "typ"), "k")) == K_tunk ||
                       yv_l(yr_get(yr_get(br, "typ"), "k")) == K_tnone ||
                       yv_l(yr_get(yr_get(br, "typ"), "k")) == K_tname) {
                // poison quietly (tcompat law) — the missing annotation
                // reports at its own site.
                Yv *ix = typeof_expr(st, yr_get(node, "idx"));
                st = yr_get(ix, "st");
                Yv *v = typeof_expr(st, yr_get(node, "v"));
                st = yr_get(v, "st");
                return yr(2, "typ", t_unk(), "st", st);
            } else {
                st = fail(st,
                          ys_cat(ys_cat(ys("cannot index "),
                                        tstr(yr_get(br, "typ"))),
                                 ys(" (only arrays and maps)")),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", t_unk(), "st", st);
            }
        }
    } else if (yv_l(k) == K_array) {
        // Heap dynamic array literal [v, ...]. Element type = first element;
        // [] needs an annotation ([T]) since there is nothing to infer from.
        // NOTE: tnone/tname element shapes (from unannotated subexpressions)
        // unify quietly here — the missing-annotation error fires once at
        // its own site, not again at every enclosing literal (tcompat law).
        Yv *elems = yr_get(node, "elems");
        if (yv_len(elems) == 0) {
            return yr(2, "typ", yr(2, "k", yv_long(K_tarr), "of", t_free()), "st", st);
        } else {
            Yv *e0 = ya_get(elems, 0);
            Yv *r0 = typeof_expr(st, e0);
            st = yr_get(r0, "st");
            if (yv_l(yr_get(yr_get(r0, "typ"), "k")) == K_tnone) {
                return yr(2, "typ", yr(2, "k", yv_long(K_tarr), "of", t_unk()), "st",
                          st);
            } else if (yv_l(yr_get(yr_get(r0, "typ"), "k")) == K_tname) {
                return yr(2, "typ", yr(2, "k", yv_long(K_tarr), "of", t_unk()), "st",
                          st);
            } else if (yv_l(yr_get(yr_get(r0, "typ"), "k")) != K_tunk &&
                       t_poisoned(yr_get(r0, "typ"))) {
                /* A nested literal that already reported its own error: its
                 * type is [[<error>]], and checking later elements against it
                 * would only echo that error back. Report once, here. */
                return yr(2, "typ", yr(2, "k", yv_long(K_tarr),
                                       "of", yr_get(r0, "typ")), "st", st);
            } else if (!is_value_type(yr_get(r0, "typ"))) {
                st = fail(st,
                          ys_cat(ys_cat(ys("array element type "),
                                        tstr(yr_get(r0, "typ"))),
                                 ys(" is unsupported in native mode")),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", t_unk(), "st", st);
            } else {
                long i = 1;
                /* A nested literal [[..], ..] lands here too: the inner
                 * literal type IS known, so it becomes the element type
                 * ([[1], [2]] : [[long]]) and every later element is
                 * checked against it. It used to return early with the
                 * inner type and check nothing, so [[1], 2] compiled and
                 * then read element 1 as an array. */
                Yv *elt = yr_get(r0, "typ");
                while (i < yv_len(elems)) {
                    Yv *r = typeof_expr(st, ya_get(elems, i));
                    st = yr_get(r, "st");
                    // NOTE: tnone/tname/poison shapes unify quietly (tcompat
                    // law) — the root cause errors once at its own site.
                    // A poisoned FIRST element (tunk) adopts the first later
                    // long/bool/str element so [f(x), 1] reports only f's own
                    // error (a float/byte/record there leaves the element type
                    // poison, which still unifies quietly downstream).
                    if (yv_l(yr_get(elt, "k")) == K_tunk) {
                        if (yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tlong) {
                            elt = yr_get(r, "typ");
                            ;
                        }
                        if (yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tbool) {
                            elt = yr_get(r, "typ");
                            ;
                        }
                        if (yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tstr) {
                            elt = yr_get(r, "typ");
                            ;
                        }
                        ;
                    } else {
                        st = expect_type(st, yr_get(r, "typ"), elt,
                                         ys("array element"),
                                         yv_l(yr_get(node, "line")),
                                         yv_l(yr_get(node, "col")));
                        ;
                    }
                    i = i + 1;
                }
                return yr(2, "typ", yr(2, "k", yv_long(K_tarr), "of", elt), "st", st);
            }
        }
    } else if (yv_l(k) == K_char) {
        return yr(2, "typ", yr(1, "k", yv_long(K_tbyte)), "st", st);
    } else if (yv_l(k) == K_rectest) {
        return typeof_rectest(st, node);
    } else if (yv_l(k) == K_narrow) {
        return typeof_narrow(st, node);
    } else if (yv_l(k) == K_matchend) {
        return typeof_matchend(st, node);
    } else if (yv_l(k) == K_sliceassign) {
        return typeof_sliceassign(st, node);
    } else {
        st = fail(st,
                  ys_cat(ys_cat(ys("'"), ktag(yv_l(k))),
                         ys("' is not a supported expression form")),
                  yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
        return yr(2, "typ", t_unk(), "st", st);
    }
}

#define NLINE yv_l(yr_get(node, "line"))
#define NCOL yv_l(yr_get(node, "col"))

// `T` / `{f: v}` pattern test: the subject must be a record or a union,
// and the pattern must be able to match one of its members.
static Yv *typeof_rectest(Yv *st, Yv *node) {
    Yv *r = typeof_expr(st, yr_get(node, "e"));
    st = yr_get(r, "st");
    Yv *s = yr_get(r, "typ");
    Yv *t = yr_get(node, "typ");
    Yv *sk = yr_get(s, "k");
    Yv *tu = unfold(t);
    Yv *tk = yr_get(tu, "k");
    if (yv_l(tk) == K_tunk) {
        // an alias that stands for no type (rename.y reported it)
        ;
    } else if (yv_l(tk) != K_trec && yv_l(tk) != K_tpat) {
        st = fail(st, ys_cat(ys_cat(ys("match pattern type "), tstr(t)), ys(" is not a record type")), NLINE, NCOL);
    } else if (yv_l(sk) == K_tunk) {
        ;
    } else if (yv_l(sk) == K_trec || yv_l(sk) == K_tunion) {
        if (yv_l(tk) == K_tpat) {
            Yv *nt = narrow_type(s, t);
            if (yv_l(yr_get(nt, "k")) == K_tunk) {
                st = fail(st, ys_cat(ys_cat(ys_cat(ys("no record in "), tstr(s)), ys(" has the fields of pattern ")), tstr(t)), NLINE, NCOL);
            }
        } else if (!pattern_fits(s, t)) {
            st = fail(st, ys_cat(ys_cat(ys_cat(ys("pattern type "), tstr(t)), ys(" can never match ")), tstr(s)), NLINE, NCOL);
        }
    } else {
        st = fail(st, ys_cat(ys("cannot match a record pattern against "), tstr(s)), NLINE, NCOL);
    }
    return yr(2, "typ", yr(1, "k", yv_long(K_tbool)), "st", st);
}

// The record type t is the subject s (a record) or one of its members (a
// union): membership is exact.
static int pattern_fits(Yv *s, Yv *t) {
    if (yv_l(yr_get(s, "k")) == K_tunion) {
        Yv *m = union_member(s, t);
        return yv_l(yr_get(m, "k")) != K_tnone;
    } else {
        return teq(s, t);
    }
}

static Yv *typeof_narrow(Yv *st, Yv *node) {
    // errors about the pattern itself are reported once, by its rectest
    Yv *r = typeof_expr(st, yr_get(node, "e"));
    Yv *t = yr_get(node, "typ");
    Yv *tu = unfold(t);
    Yv *tk = yr_get(tu, "k");
    if (yv_l(tk) == K_trec || yv_l(tk) == K_tpat) {
        return yr(2, "typ", narrow_type(yr_get(r, "typ"), t), "st", yr_get(r, "st"));
    } else {
        return yr(2, "typ", t_unk(), "st", yr_get(r, "st"));
    }
}

// The fall-through of a match without `_`: every member of the subject's
// union (or the subject's record type) must be covered by a type arm.
// Its type is the poison tunk, so it never disagrees with the arms.
static Yv *typeof_matchend(Yv *st, Yv *node) {
    Yv *r = typeof_expr(st, yr_get(node, "e"));
    st = yr_get(r, "st");
    Yv *s = yr_get(r, "typ");
    Yv *sk = yr_get(s, "k");
    Yv *cover = yr_get(node, "cover");
    Yv *hint = ys("");
    if (yv_l(yr_get(node, "vals")) > 0) {
        hint = ys("; value patterns match only the values they name and cover no type");
    }
    if (yv_l(sk) == K_tunk) {
        ;
    } else if (yv_l(sk) == K_tunion) {
        Yv *ms = members(s);
        Yv *missing = yav(0);
        long i = 0;
        while (i < yv_len(ms)) {
            if (!covered(ya_get(ms, i), cover)) {
                missing = ya_push(missing, tstr(ya_get(ms, i)));
            }
            i = i + 1;
        }
        if (yv_len(missing) > 0) {
            st = fail(st, ys_cat(ys_cat(ys_cat(ys("non-exhaustive match: nothing matches "),
                                                ys_join(missing, ys(", "))),
                                          ys(" (add an arm or '_'")),
                                   ys_cat(hint, ys(")"))),
                      NLINE, NCOL);
        }
    } else if (yv_l(sk) == K_trec && covered(s, cover)) {
        ;
    } else {
        st = fail(st, ys_cat(ys_cat(ys_cat(ys("non-exhaustive match on "),
                                          tstr(s)),
                                   ys(" (add a '_' arm")),
                            ys_cat(hint, ys(")"))),
                  NLINE, NCOL);
    }
    return yr(2, "typ", t_unk(), "st", st);
}

// A member is covered by a type arm of its type.
static int covered(Yv *m, Yv *cover) {
    int any = 0;
    long i = 0;
    while (i < yv_len(cover)) {
        Yv *c = unfold(ya_get(cover, i));
        if (yv_l(yr_get(c, "k")) == K_trec) {
            if (teq(m, c)) {
                any = 1;
            }
        }
        i = i + 1;
    }
    return any;
}

// a[lo:hi] = src: a is an array, src an array of the same element type.
static Yv *typeof_sliceassign(Yv *st, Yv *node) {
    Yv *ar = typeof_expr(st, yr_get(node, "arr"));
    st = yr_get(ar, "st");
    Yv *slo = yr_get(node, "lo");
    Yv *shi = yr_get(node, "hi");
    if (yv_l(yr_get(slo, "k")) != K_void) {
        Yv *rl = typeof_expr(st, slo);
        st = expect_type(yr_get(rl, "st"), yr_get(rl, "typ"), yr(1, "k", yv_long(K_tlong)), ys("slice start"), NLINE, NCOL);
    }
    if (yv_l(yr_get(shi, "k")) != K_void) {
        Yv *rh = typeof_expr(st, shi);
        st = expect_type(yr_get(rh, "st"), yr_get(rh, "typ"), yr(1, "k", yv_long(K_tlong)), ys("slice end"), NLINE, NCOL);
    }
    Yv *vr = typeof_expr(st, yr_get(node, "v"));
    st = yr_get(vr, "st");
    Yv *at = yr_get(ar, "typ");
    Yv *vt = yr_get(vr, "typ");
    Yv *akk = yr_get(at, "k");
    Yv *vkk = yr_get(vt, "k");
    if (yv_l(akk) == K_tarr || yv_l(akk) == K_tarrfix) {
        if (yv_l(vkk) == K_tarr || yv_l(vkk) == K_tarrfix) {
            if (!teq(yr_get(vt, "of"), yr_get(at, "of"))) {
                st = fail(st, ys_cat(ys_cat(ys_cat(ys("slice assignment: cannot store "), tstr(vt)), ys(" into ")), tstr(at)), NLINE, NCOL);
            }
        } else if (yv_l(vkk) == K_tunk) {
            ;
        } else {
            st = fail(st, ys_cat(ys("slice assignment needs an array on the right, got "), tstr(vt)), NLINE, NCOL);
        }
    } else if (yv_l(akk) == K_tstr) {
        st = fail(st, ys("cannot assign to a slice of str (strings are immutable)"), NLINE, NCOL);
    } else if (yv_l(akk) == K_tunk) {
        ;
    } else {
        st = fail(st, ys_cat(ys_cat(ys("cannot slice-assign "), tstr(at)), ys(" (only arrays)")), NLINE, NCOL);
    }
    return yr(2, "typ", yr(1, "k", yv_long(K_tvoid)), "st", st);
}

#undef NLINE
#undef NCOL

/* The type of field `dkey` read from a value of type t: a record field,
 * or a built-in property of an array or a str. The dot arm of typeof_expr
 * is this after typing its object; typeof_call uses it directly for a
 * callee `x.f(...)`, so the receiver is typed once whether or not it turns
 * out to be a str (a string method) or a record (a field holding a
 * function). */
static Yv *typeof_field(Yv *st, Yv *t, Yv *dkey, long line, long col) {
    if (yv_l(yr_get(t, "k")) == K_trec) {
        int found = 0;
        Yv *ftyp = t_unk();
        Yv *fs = yr_get(t, "fields");
        long j = 0;
        while (j < yv_len(fs)) {
            // NOTE: bound once (flow-snapshot, see the dot arm's note).
            // NOTE: :str bindings (see teq note).
            Yv *f = ya_get(fs, j);
            Yv *fn = yr_get(f, "name");
            if (ys_eq(fn, dkey)) {
                found = 1;
                ftyp = yr_get(f, "typ");
                ;
            }
            j = j + 1;
            ;
        }
        if (found) {
            return yr(2, "typ", ftyp, "st", st);
        } else {
            st = fail(st,
                      ys_cat(ys_cat(ys("record has no field '"), dkey),
                             ys("'")),
                      line, col);
            return yr(2, "typ", t_unk(), "st", st);
        }
    } else if (yv_l(yr_get(t, "k")) == K_tunion) {
        return union_field(st, t, dkey, line, col);
    } else if (yv_l(yr_get(t, "k")) == K_tunk) {
        return yr(2, "typ", t_unk(), "st", st);
    } else if (yv_l(yr_get(t, "k")) == K_tnone) {
        // bare-hole params (see typeof_def note): unify quietly.
        return yr(2, "typ", t_unk(), "st", st);
    } else if (yv_l(yr_get(t, "k")) == K_tname) {
        return yr(2, "typ", t_unk(), "st", st);
    } else if (yv_l(yr_get(t, "k")) == K_tparams) {
        return yr(2, "typ", t_unk(), "st", st);
    } else if (yv_l(yr_get(t, "k")) == K_tarr ||
               yv_l(yr_get(t, "k")) == K_tarrfix ||
               yv_l(yr_get(t, "k")) == K_tstr) {
        return typeof_prop(st, t, dkey, line, col);
    } else {
        st = fail(st,
                  ys_cat(ys_cat(ys_cat(ys_cat(ys("cannot read field '"),
                                              dkey),
                                        ys("' of ")),
                                 tstr(t)),
                         ys(" (need a record)")),
                  line, col);
        return yr(2, "typ", t_unk(), "st", st);
    }
}

/* Built-in properties: `.length` of an array or a str is len(x); `.ptr` of
 * an array is the address of element 0 as a *T -- the data block's address,
 * so it is valid for an empty array too, where &a[0] traps. A str has no
 * `.ptr`: its bytes can live in read-only .rodata, where a store through
 * the pointer would fault. */
static Yv *typeof_prop(Yv *st, Yv *t, Yv *key, long line, long col) {
    if (ys_eq_lit(key, "length")) {
        return yr(2, "typ", yr(1, "k", yv_long(K_tlong)), "st", st);
    } else if (ys_eq_lit(key, "ptr") &&
               yv_l(yr_get(t, "k")) != K_tstr) {
        return yr(2, "typ",
                  yr(2, "k", yv_long(K_tptr), "to", yr_get(t, "of")), "st", st);
    } else {
        Yv *have = ys("'.length' and '.ptr'");
        if (yv_l(yr_get(t, "k")) == K_tstr) {
            have = ys("'.length'");
        }
        st = fail(st,
                  ys_cat(ys_cat(ys_cat(ys_cat(tstr(t), ys(" has no property '")),
                                       key),
                                ys("' (it has ")),
                         ys_cat(have, ys(")"))),
                  line, col);
        return yr(2, "typ", t_unk(), "st", st);
    }
}

/* `s.m(args)` with s a str calls a string method: a builtin with the
 * receiver as an argument (`s.split(",")` is split(s, ",")), or a helper
 * in std/str.y called by label (`s.pad_left(8)` is
 * y_str_pad_left(s, 8, " ")). This table is the whole definition; the
 * checker (typeof_method) and the emitter (native.y gen_method and
 * infer_call) both read it.
 *   fn      the builtin, or the helper's label; "" = no such method
 *   params  the argument types, receiver excluded
 *   nreq    how many are required; the last one may be left out only
 *           when nreq is one short, and then `dflt` (a str) is passed
 *   ret     the result type
 *   last    the receiver goes AFTER the arguments (`sep.join(xs)` is
 *           join(xs, sep))
 * A helper's method names must be in native.y str_names: that is what
 * splices std/str.y into a program that calls one. */
Yv *str_method(Yv *m) {
    Yv *s = sm_t(yv_long(K_tstr));
    Yv *l = sm_t(yv_long(K_tlong));
    Yv *b = sm_t(yv_long(K_tbool));
    Yv *no = yav(0);
    if (ys_eq_lit(m, "split")) {
        return sm_mk(ys("split"), yav(1, s), 1, sm_arr(s), ys(""), 0);
    } else if (ys_eq_lit(m, "join")) {
        return sm_mk(ys("join"), yav(1, sm_arr(sm_any())), 1, s, ys(""), 1);
    } else if (ys_eq_lit(m, "trim") || ys_eq_lit(m, "strip")) {
        return sm_mk(ys("trim"), no, 0, s, ys(""), 0);
    } else if (ys_eq_lit(m, "trim_start") || ys_eq_lit(m, "lstrip")) {
        return sm_mk(ys("y_str_trim_start"), no, 0, s, ys(""), 0);
    } else if (ys_eq_lit(m, "trim_end") || ys_eq_lit(m, "rstrip")) {
        return sm_mk(ys("y_str_trim_end"), no, 0, s, ys(""), 0);
    } else if (ys_eq_lit(m, "pad_left")) {
        return sm_mk(ys("y_str_pad_left"), yav(2, l, s), 1, s, ys(" "), 0);
    } else if (ys_eq_lit(m, "pad_right")) {
        return sm_mk(ys("y_str_pad_right"), yav(2, l, s), 1, s, ys(" "), 0);
    } else if (ys_eq_lit(m, "center")) {
        return sm_mk(ys("y_str_center"), yav(2, l, s), 1, s, ys(" "), 0);
    } else if (ys_eq_lit(m, "starts_with")) {
        return sm_mk(ys("y_str_starts_with"), yav(1, s), 1, b, ys(""), 0);
    } else if (ys_eq_lit(m, "ends_with")) {
        return sm_mk(ys("y_str_ends_with"), yav(1, s), 1, b, ys(""), 0);
    } else if (ys_eq_lit(m, "contains")) {
        return sm_mk(ys("y_str_contains"), yav(1, s), 1, b, ys(""), 0);
    } else if (ys_eq_lit(m, "index_of")) {
        return sm_mk(ys("index_of"), yav(1, s), 1, l, ys(""), 0);
    } else if (ys_eq_lit(m, "last_index_of")) {
        return sm_mk(ys("last_index_of"), yav(1, s), 1, l, ys(""), 0);
    } else if (ys_eq_lit(m, "count")) {
        return sm_mk(ys("y_str_count"), yav(1, s), 1, l, ys(""), 0);
    } else if (ys_eq_lit(m, "replace")) {
        return sm_mk(ys("y_str_replace"), yav(2, s, s), 2, s, ys(""), 0);
    } else if (ys_eq_lit(m, "upper")) {
        return sm_mk(ys("y_str_upper"), no, 0, s, ys(""), 0);
    } else if (ys_eq_lit(m, "lower")) {
        return sm_mk(ys("y_str_lower"), no, 0, s, ys(""), 0);
    } else if (ys_eq_lit(m, "repeat")) {
        return sm_mk(ys("y_str_repeat"), yav(1, l), 1, s, ys(""), 0);
    } else if (ys_eq_lit(m, "lines")) {
        return sm_mk(ys("y_str_lines"), no, 0, sm_arr(s), ys(""), 0);
    } else if (ys_eq_lit(m, "bytes")) {
        return sm_mk(ys("bytes"), no, 0,
                     sm_arr(sm_t(yv_long(K_tbyte))), ys(""), 0);
    } else if (ys_eq_lit(m, "tonum")) {
        return sm_mk(ys("tonum"), no, 0, l, ys(""), 0);
    } else if (ys_eq_lit(m, "ord")) {
        return sm_mk(ys("ord"), no, 0, l, ys(""), 0);
    } else if (ys_eq_lit(m, "byte_at")) {
        return sm_mk(ys("byte_at"), yav(1, l), 1, l, ys(""), 0);
    } else {
        return sm_mk(ys(""), no, 0, t_unk(), ys(""), 0);
    }
}

static Yv *sm_mk(Yv *fn, Yv *params, long nreq, Yv *ret, Yv *dflt,
                 int last) {
    return yr(6, "fn", fn, "params", params, "nreq", yv_long(nreq),
              "ret", ret, "dflt", dflt, "last", yv_bool(last));
}

static Yv *sm_t(Yv *k) {
    return yr(1, "k", k);
}

static Yv *sm_arr(Yv *of) {
    return yr(2, "k", yv_long(K_tarr), "of", of);
}

// join's array: any element type (sm_accepts; prints as `T`, so an error
// reads "expected [T]").
static Yv *sm_any(void) {
    return yr(2, "k", yv_long(K_tname), "name", ys("T"));
}

/* `node` is `s.m(args)` with s a str (typed already, by typeof_call). */
static Yv *typeof_method(Yv *st, Yv *node, Yv *m) {
    Yv *sm = str_method(m);
    Yv *margs = yr_get(node, "args");
    long na = yv_len(margs);
    Yv *ps = yr_get(sm, "params");
    long np = yv_len(ps);
    Yv *what = ys_cat(ys_cat(ys("'str."), m), ys("'"));
    if (ys_eq_lit(yr_get(sm, "fn"), "")) {
        Yv *hint = ys("");
        if (ys_eq_lit(m, "length")) {
            hint = ys(" ('.length' is a property: no parentheses)");
            ;
        }
        st = fail(st,
                  ys_cat(ys_cat(ys_cat(ys("str has no method '"), m),
                                ys("'")),
                         hint),
                  yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
        long i = 0;
        while (i < na) {
            Yv *r = typeof_expr(st, ya_get(margs, i));
            st = yr_get(r, "st");
            i = i + 1;
        }
        return yr(2, "typ", t_unk(), "st", st);
    } else if (na < yv_l(yr_get(sm, "nreq")) || na > np) {
        Yv *want = ys_long(np);
        if (yv_l(yr_get(sm, "nreq")) < np) {
            want = ys_cat(ys_cat(ys_long(yv_l(yr_get(sm, "nreq"))),
                                 ys(" or ")),
                          ys_long(np));
            ;
        }
        st = fail(st,
                  ys_cat(ys_cat(ys_cat(ys_cat(what, ys(" takes ")), want),
                                ys(" args, got ")),
                         ys_long(na)),
                  yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
        long i = 0;
        while (i < na) {
            Yv *r = typeof_expr(st, ya_get(margs, i));
            st = yr_get(r, "st");
            i = i + 1;
        }
        return yr(2, "typ", yr_get(sm, "ret"), "st", st);
    } else {
        long i = 0;
        while (i < na) {
            Yv *r = typeof_expr(st, ya_get(margs, i));
            st = yr_get(r, "st");
            Yv *ak = yr_get(yr_get(r, "typ"), "k");
            if (yv_l(ak) == K_tvoid) {
                st = fail(st,
                          ys_cat(ys_cat(ys_cat(what, ys(" arg ")), ys_long(i)),
                                 ys(": cannot pass a void value")),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                ;
            } else if (!sm_accepts(yr_get(r, "typ"), ya_get(ps, i))) {
                st = fail(st,
                          ys_cat(ys_cat(ys_cat(ys_cat(ys_cat(
                                                              what,
                                                              ys(" arg ")),
                                                    ys_long(i)),
                                              ys(": expected ")),
                                      tstr(ya_get(ps, i))),
                                 ys_cat(ys(", got "),
                                        tstr(yr_get(r, "typ")))),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                ;
            }
            i = i + 1;
        }
        return yr(2, "typ", yr_get(sm, "ret"), "st", st);
    }
}

// tcompat, except that join's [T] takes an array of any element type (as
// the join builtin does: a [T], or poison).
static int sm_accepts(Yv *got, Yv *want) {
    if (yv_l(yr_get(want, "k")) == K_tarr &&
        yv_l(yr_get(yr_get(want, "of"), "k")) == K_tname) {
        return yv_l(yr_get(got, "k")) == K_tarr ||
               yv_l(yr_get(got, "k")) == K_tunk;
    } else {
        return tcompat(got, want);
    }
}

/* `const` fixes the BINDING, not the value (as in JS): `=`, `++`/`--` and
 * the `op=` forms that rebind (numbers, strings) are errors on a const name,
 * while the in-place array forms (`arr += v`, `arr *= v`) and element or
 * field writes (`a[i] = v`, `r.f = v`) still mutate the shared value. Plain
 * `=` is refused in the `assign` arm itself; this covers the other two. */
static Yv *const_check(Yv *st, Yv *tgt, Yv *tt, Yv *op, long line, long col) {
    if (yv_l(yr_get(tgt, "k")) == K_id) {
        Yv *got = lookup(yr_get(st, "bindings"), yr_get(tgt, "v"));
        int inplace = yv_l(yr_get(tt, "k")) == K_tarr ||
                      yv_l(yr_get(tt, "k")) == K_tarrfix ||
                      yv_l(yr_get(tt, "k")) == K_tunk ||
                      yv_l(yr_get(tt, "k")) == K_tnone;
        if (ys_eq_lit(yr_get(got, "kind"), "const") && !inplace) {
            return fail(st,
                        ys_cat(ys_cat(ys_cat(ys_cat(
                                                   ys("cannot assign to constant '"),
                                                   disp(yr_get(tgt, "v"))),
                                             ys("' ('")),
                                      op),
                               ys("')")),
                        line, col);
        } else {
            return st;
        }
    } else {
        return st;
    }
}

/* `++`/`--` and `op=` store back into their target, so it must be a place
 * `=` stores to: a variable, an array or map element, or a record field.
 * A str's bytes and the `.length`/`.ptr` properties are read-only, as they
 * are to `=`. Returns the target's type, or t_unk() after an error, so the
 * operator's own rules stay quiet. (`*p = v` is a store of its own; `*p`
 * is no target here.) Only a target that can be one of those -- a byte
 * element, a `.length` or `.ptr` -- has its base looked at. */
static Yv *place_check(Yv *st, Yv *tgt, Yv *tt, Yv *op, long line, long col) {
    Yv *k = yr_get(tgt, "k");
    int ok = 1;
    if (yv_l(k) == K_index) {
        if (yv_l(yr_get(tt, "k")) == K_tbyte &&
            yv_l(yr_get(base_type(st, yr_get(tgt, "arr")), "k")) == K_tstr) {
            st = fail(st, ys("cannot index str (only arrays and maps)"), line, col);
            ok = 0;
        }
    } else if (yv_l(k) == K_dot) {
        Yv *key = yr_get(tgt, "key");
        if (yv_l(yr_get(tt, "k")) != K_tunk &&
            (ys_eq_lit(key, "length") || ys_eq_lit(key, "ptr"))) {
            Yv *bt = base_type(st, yr_get(tgt, "obj"));
            if (yv_l(yr_get(bt, "k")) == K_tarr ||
                yv_l(yr_get(bt, "k")) == K_tarrfix ||
                yv_l(yr_get(bt, "k")) == K_tstr) {
                st = fail(st,
                          ys_cat(ys_cat(ys("cannot field-assign "), tstr(bt)),
                                 ys(" (only records)")),
                          line, col);
                ok = 0;
            }
        }
    } else if (yv_l(k) != K_id && yv_l(k) != K_err) {
        st = fail(st,
                  ys_cat(ys_cat(ys("cannot assign to this expression ('"), op),
                         ys("')")),
                  line, col);
        ok = 0;
    }
    if (ok) { return yr(2, "typ", tt, "st", st); } else { return yr(2, "typ", t_unk(), "st", st); }
}

/* The static type of a place's base (`a` in `a[i]`, `o` in `o.f`). The
 * whole target was typed already, its errors reported: a base other than
 * a name is typed again on a scratch error list. */
static Yv *base_type(Yv *st, Yv *e) {
    if (yv_l(yr_get(e, "k")) == K_id) {
        return yr_get(lookup(yr_get(st, "bindings"), yr_get(e, "v")), "typ");
    } else {
        Yv *none = yav(0);
        return yr_get(typeof_expr(st_errors(st, none), e), "typ");
    }
}

// ++/-- target rule: numbers (long/byte/float) only.
static Yv *incdec_check(Yv *st, Yv *node, Yv *tt) {
    Yv *op = yr_get(node, "op");
    if (yv_l(yr_get(tt, "k")) == K_tlong ||
        yv_l(yr_get(tt, "k")) == K_tbyte ||
        yv_l(yr_get(tt, "k")) == K_tfloat) {
        return yr(2, "typ", tt, "st", st);
    } else if (yv_l(yr_get(tt, "k")) == K_tunk ||
               yv_l(yr_get(tt, "k")) == K_tnone) {
        return yr(2, "typ", t_unk(), "st", st);
    } else {
        st = fail(st,
                  ys_cat(ys_cat(ys_cat(ys("'"), op),
                               ys("' needs a number target, got ")),
                         tstr(tt)),
                  yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
        return yr(2, "typ", t_unk(), "st", st);
    }
}

// `x op= e` rules by target type:
//   numbers  -> the arithmetic family (+ - * / %), result the target type
//   integers -> the bitwise family (& | ^ << >> >>>) too: a long or byte
//               target, an integer value (a byte target keeps the low 8
//               bits, like every byte store)
//   str      -> `+=` concatenates; the rest are errors
//   arrays   -> in place only: `+=` pushes one element (or appends another
//               array of the same element type; `[[T]] += [T]` pushes the
//               [T] whole), `*=` prepends one element. `+`
//               itself is the copy form; `-=`, `/=`, `%=` are errors.
// The result is always the target's type (the new value).
static Yv *opassign_check(Yv *st, Yv *node, Yv *tt, Yv *vt) {
    Yv *op = yr_get(node, "op");
    if (is_bits_op(op)) {
        if (yv_l(yr_get(tt, "k")) == K_tlong ||
            yv_l(yr_get(tt, "k")) == K_tbyte) {
            st = expect_type(st, vt, yr(1, "k", yv_long(K_tlong)),
                             ys_cat(ys_cat(ys("'"), op), ys("=' value")),
                             yv_l(yr_get(node, "line")),
                             yv_l(yr_get(node, "col")));
            return yr(2, "typ", tt, "st", st);
        } else if (yv_l(yr_get(tt, "k")) == K_tunk ||
                   yv_l(yr_get(tt, "k")) == K_tnone) {
            return yr(2, "typ", t_unk(), "st", st);
        } else {
            st = fail(st,
                      ys_cat(ys_cat(ys_cat(ys("'"), op),
                                   ys("=' needs an integer target, got ")),
                             tstr(tt)),
                      yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
            return yr(2, "typ", t_unk(), "st", st);
        }
    } else if (yv_l(yr_get(tt, "k")) == K_tarrfix) {
        /* A fixed array's length is part of its type: growth is a type
         * error (the old push-on-fixed rejection, now on the operators). */
        st = fail(st,
                  ys_cat(ys_cat(ys_cat(ys_cat(ys("cannot grow fixed array "),
                                             tstr(tt)),
                                       ys(" with '")),
                                op),
                         ys("=' (its length is part of its type; use [T] instead)")),
                  yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
        return yr(2, "typ", tt, "st", st);
    } else if (yv_l(yr_get(tt, "k")) == K_tarr) {
        if (ys_eq_lit(op, "*")) {
            // `*= ` prepends ONE item — its type must be the element type.
            st = expect_type(st, vt, yr_get(tt, "of"), ys("'*=' element"),
                             yv_l(yr_get(node, "line")),
                             yv_l(yr_get(node, "col")));
            return yr(2, "typ", tt, "st", st);
        } else if (ys_eq_lit(op, "+")) {
            if (yv_l(yr_get(vt, "k")) == K_tarr ||
                yv_l(yr_get(vt, "k")) == K_tarrfix) {
                if (ys_eq_lit(arr_plus_kind(tt, vt), "append")) {
                    // `[[T]] += [T]` pushes the array as ONE element (the
                    // same rule as `+`, see arr_plus_kind).
                    return yr(2, "typ", tt, "st", st);
                } else {
                    // `arr += arr2` appends arr2's ELEMENTS in place, so
                    // the element types must match (homogeneity).
                    st = expect_type(st, yr_get(vt, "of"), yr_get(tt, "of"),
                                     ys("'+=' appended elements"),
                                     yv_l(yr_get(node, "line")),
                                     yv_l(yr_get(node, "col")));
                    return yr(2, "typ", tt, "st", st);
                }
            } else if (yv_l(yr_get(vt, "k")) == K_tunk ||
                       yv_l(yr_get(vt, "k")) == K_tnone) {
                return yr(2, "typ", tt, "st", st);
            } else {
                st = expect_type(st, vt, yr_get(tt, "of"), ys("'+=' element"),
                                 yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col")));
                return yr(2, "typ", tt, "st", st);
            }
        } else {
            st = fail(st,
                      ys_cat(ys_cat(ys("arrays support only '+=' and '*=' (in place), not '"),
                                    op),
                             ys("='")),
                      yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
            return yr(2, "typ", tt, "st", st);
        }
    } else if (yv_l(yr_get(tt, "k")) == K_tstr) {
        if (ys_eq_lit(op, "+")) {
            st = expect_type(st, vt, yr(1, "k", yv_long(K_tstr)), ys("'+=' string"),
                             yv_l(yr_get(node, "line")),
                             yv_l(yr_get(node, "col")));
            return yr(2, "typ", tt, "st", st);
        } else {
            st = fail(st,
                      ys_cat(ys_cat(ys("strings support only '+=' (concatenate), not '"),
                                    op),
                             ys("='")),
                      yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
            return yr(2, "typ", tt, "st", st);
        }
    } else if (yv_l(yr_get(tt, "k")) == K_tlong ||
               yv_l(yr_get(tt, "k")) == K_tbyte ||
               yv_l(yr_get(tt, "k")) == K_tfloat) {
        st = expect_type(st, vt, tt, ys_cat(ys_cat(ys("'"), op), ys("=' value")),
                         yv_l(yr_get(node, "line")),
                         yv_l(yr_get(node, "col")));
        return yr(2, "typ", tt, "st", st);
    } else if (yv_l(yr_get(tt, "k")) == K_tunk ||
               yv_l(yr_get(tt, "k")) == K_tnone) {
        return yr(2, "typ", t_unk(), "st", st);
    } else {
        st = fail(st,
                  ys_cat(ys_cat(ys_cat(ys("'"), op),
                               ys("=' needs a number, string or array target, got ")),
                         tstr(tt)),
                  yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
        return yr(2, "typ", t_unk(), "st", st);
    }
}

/* align < > ^ =, sign + - or a space, grouping `,` or `_`, type one of
 * s d x X o b c f F e E %. Bytes, 0 when absent (-1 for the two numbers);
 * err is "" when the spec reads. */
Yv *fmt_spec(Yv *spec) {
    long n = yv_len(spec);
    long i = 0;
    long fill = 0;
    long align = 0;
    if (n >= 2 && fmt_align(ys_byte_at(spec, 1))) {
        fill = ys_byte_at(spec, 0);
        align = ys_byte_at(spec, 1);
        i = 2;
        ;
    } else if (n >= 1 && fmt_align(ys_byte_at(spec, 0))) {
        align = ys_byte_at(spec, 0);
        i = 1;
        ;
    }
    long sign = 0;
    if (i < n && (ys_byte_at(spec, i) == 43 ||
                  ys_byte_at(spec, i) == 45 ||
                  ys_byte_at(spec, i) == 32)) {
        sign = ys_byte_at(spec, i);
        i = i + 1;
        ;
    }
    int alt = 0;
    if (i < n && ys_byte_at(spec, i) == 35) { alt = 1; i = i + 1; ; }
    int zero = 0;
    if (i < n && ys_byte_at(spec, i) == '0') { zero = 1; i = i + 1; ; }
    long ws = i;
    while (i < n && fmt_digit(ys_byte_at(spec, i))) {
        i = i + 1;
        ;
    }
    long width = 0 - 1;
    if (i > ws) { width = fmt_number(spec, ws, i); ; }
    long grp = 0;
    if (i < n && (ys_byte_at(spec, i) == 44 || ys_byte_at(spec, i) == 95)) {
        grp = ys_byte_at(spec, i);
        i = i + 1;
        ;
    }
    Yv *err = ys("");
    long prec = 0 - 1;
    if (i < n && ys_byte_at(spec, i) == 46) {
        i = i + 1;
        long ps = i;
        while (i < n && fmt_digit(ys_byte_at(spec, i))) {
            i = i + 1;
            ;
        }
        if (i > ps) { prec = fmt_number(spec, ps, i); ; }
        else { err = ys("'.' without a precision"); ; }
        ;
    }
    long ty = 0;
    if (i < n && fmt_type(ys_byte_at(spec, i))) {
        ty = ys_byte_at(spec, i);
        i = i + 1;
        ;
    }
    if (!ys_eq_lit(err, "")) {
        ;
    } else if (i == n - 1) {
        err = ys_cat(ys_cat(ys("unknown type '"), ys_slice(spec, i, n)),
                     ys("'"));
        ;
    } else if (i < n) {
        err = ys_cat(ys("cannot read '"), ys_cat(ys_slice(spec, i, n), ys("'")));
        ;
    } else if (width > 99999 || prec > 99999) {
        err = ys("width and precision stop at 99999");
        ;
    }
    return yr(10, "err", err, "fill", yv_long(fill), "align", yv_long(align),
              "sign", yv_long(sign), "alt", yv_bool(alt), "zero",
              yv_bool(zero), "width", yv_long(width), "grp", yv_long(grp),
              "prec", yv_long(prec), "ty", yv_long(ty));
}

static int fmt_align(long c) {
    return c == 60 || c == 62 || c == 94 || c == 61;
}

static int fmt_digit(long c) {
    return c >= 48 && c <= 57;
}

/* s d x X o b c f F e E % */
static int fmt_type(long c) {
    return c == 115 || c == 100 || c == 120 || c == 88 || c == 111 ||
           c == 98 || c == 99 || c == 102 || c == 70 || c == 101 ||
           c == 69 || c == 37;
}

/* The digits spec[a:b] as a number, stopping short of overflow (a value
 * that large is over fmt_spec's limit anyway). */
static long fmt_number(Yv *spec, long a, long b) {
    long v = 0;
    long i = a;
    while (i < b) {
        if (v < 1000000) { v = v * 10 + ys_byte_at(spec, i) - '0'; ; }
        i = i + 1;
        ;
    }
    return v;
}

/* How a value formats under a spec: 1 an integer (long, byte), 2 a float,
 * 0 anything else -- its tostring text, like a str. */
long fmt_kind(Yv *t) {
    Yv *k = yr_get(t, "k");
    if (yv_l(k) == K_tlong || yv_l(k) == K_tbyte) {
        return 1;
    } else if (yv_l(k) == K_tfloat) {
        return 2;
    } else {
        return 0;
    }
}

/* What is wrong with the spec f for a value of kind `kind` (fmt_kind) and
 * type tname: "" when nothing is. Python's rules: a sign, `#`, grouping
 * and `=` need a number, a precision is no integer type's, `c` takes no
 * sign, `#` or grouping, and `,` groups decimals only. */
static Yv *fmt_check(Yv *f, long kind, Yv *tname) {
    long ty = yv_l(yr_get(f, "ty"));
    int ints = ty == 100 || ty == 120 || ty == 88 || ty == 111 ||
               ty == 98 || ty == 99;
    if (!ys_eq_lit(yr_get(f, "err"), "")) {
        return yr_get(f, "err");
    } else if (kind == 0) {
        if (ty != 0 && ty != 115) {
            return ys_cat(ys_cat(ys_cat(ys("type '"), ys_chr(ty)),
                                 ys("' needs a number, not ")),
                          tname);
        } else if (yv_l(yr_get(f, "sign")) != 0) {
            return ys_cat(ys("a sign needs a number, not "), tname);
        } else if (yv_b(yr_get(f, "alt"))) {
            return ys_cat(ys("'#' needs a number, not "), tname);
        } else if (yv_l(yr_get(f, "grp")) != 0) {
            return ys_cat(ys_cat(ys_cat(ys("'"), ys_chr(yv_l(yr_get(f, "grp")))),
                                 ys("' needs a number, not ")),
                          tname);
        } else if (yv_l(yr_get(f, "align")) == 61) {
            return ys_cat(ys("'=' alignment needs a number, not "), tname);
        } else {
            return ys("");
        }
    } else if (ty == 115) {
        return ys_cat(ys_cat(ys_cat(ys("type '"), ys_chr(ty)),
                             ys("' needs a string, not ")),
                      tname);
    } else if (kind == 2 && ints) {
        return ys_cat(ys_cat(ys_cat(ys("type '"), ys_chr(ty)),
                             ys("' needs an integer, not ")),
                      tname);
    } else if (kind == 1 && yv_l(yr_get(f, "prec")) >= 0 &&
               (ty == 0 || ints)) {
        return ys("a precision needs a float type (f, e or %), not an integer one");
    } else if (ty == 99 &&
               (yv_l(yr_get(f, "sign")) != 0 ||
                yv_b(yr_get(f, "alt")) ||
                yv_l(yr_get(f, "grp")) != 0)) {
        return ys("type 'c' takes no sign, '#' or grouping");
    } else if (yv_l(yr_get(f, "grp")) == 44 &&
               (ty == 120 || ty == 88 || ty == 111 || ty == 98)) {
        return ys_cat(ys_cat(ys("',' does not group type '"), ys_chr(ty)),
                      ys("' (use '_')"));
    } else {
        return ys("");
    }
}

/* node as a Leaf, or none when it is the err node the parser plants where
 * the token stream stopped making sense. Casting one blindly is a CHECKED
 * cast and traps, which is how `1 f"{a b}"` killed ycc (a malformed field
 * drops the spec argument and leaves the error in its place): the C twin
 * reads a field that is simply not there and carries on to three proper
 * diagnostics, and so must this side. */
Yv *leaf_of(Yv *node) {
    if (yv_l(yr_get(node, "k")) == K_err) { return yv_none(); }
    Yv *leaf = yr(4, "k", yr_get(node, "k"), "v", yr_get(node, "v"),
                  "line", yr_get(node, "line"), "col", yr_get(node, "col"));
    return leaf;
}

/* #fmt(e, spec) is a str. Without a spec e is whatever tostring takes;
 * with one, the spec has to read and to suit e's type (fmt_check). A spec
 * argument that is an err node is reported here -- typeof_expr's own K.err
 * arm would have reported it, had the argument gone through it -- and the
 * spec itself left alone. */
static Yv *typeof_fmt(Yv *st, Yv *node) {
    Yv *fargs = yr_get(node, "args");
    Yv *r = typeof_expr(st, ya_get(fargs, 0));
    st = yr_get(r, "st");
    Yv *t = yr_get(r, "typ");
    Yv *sp = leaf_of(ya_get(fargs, 1));
    Yv *spec = yv_is_none(sp) ? ys("") : yr_get(sp, "v");
    Yv *k = yr_get(t, "k");
    if (yv_is_none(sp)) {
        Yv *e = ya_get(fargs, 1);
        st = fail(st, yr_get(e, "msg"), yv_l(yr_get(e, "line")),
                  yv_l(yr_get(e, "col")));
        ;
    } else if (!(yv_l(k) == K_tlong || yv_l(k) == K_tbyte ||
                 yv_l(k) == K_tbool || yv_l(k) == K_tstr ||
                 yv_l(k) == K_tfloat || yv_l(k) == K_tunk ||
                 yv_l(k) == K_tarr || yv_l(k) == K_tarrfix ||
                 yv_l(k) == K_trec || yv_l(k) == K_tmap ||
                 yv_l(k) == K_topt || yv_l(k) == K_tunion)) {
        st = fail(st,
                  ys_cat(ys("an f-string field takes long/bool/float/str/array/record/map/option, got "),
                        tstr(t)),
                  yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
        ;
    } else if (!ys_eq_lit(spec, "")) {
        Yv *e = fmt_check(fmt_spec(spec), fmt_kind(t), tstr(t));
        if (!ys_eq_lit(e, "")) {
            st = fail(st,
                      ys_cat(ys_cat(ys_cat(ys("format spec '"), spec), ys("': ")),
                             e),
                      yv_l(yr_get(node, "line")),
                      yv_l(yr_get(node, "col")));
            ;
        }
        ;
    }
    return yr(2, "typ", yr(1, "k", yv_long(K_tstr)), "st", st);
}

static Yv *typeof_call(Yv *st, Yv *node) {
    // Two callee shapes: a plain id (the `else` arm below — a hoisted def,
    // an intrinsic, `self`, or a local holding a closure) and an arbitrary
    // expression (the `if` arm — an immediately-invoked literal, an element
    // of an array of functions, ...).
    Yv *cargs = yr_get(node, "args");
    if (yv_l(yr_get(yr_get(node, "callee"), "k")) != K_id) {
        // Calling an expression: legal when it yields a function value,
        // or a string method. Type a dot receiver once, then resolve it as
        // a method or as a field of a record.
        Yv *ccal = yr_get(node, "callee");
        Yv *cf = yr(2, "typ", t_unk(), "st", st);
        int smeth = 0;
        if (yv_l(yr_get(ccal, "k")) == K_dot) {
            Yv *crt = typeof_expr(st, yr_get(ccal, "obj"));
            if (yv_l(yr_get(yr_get(crt, "typ"), "k")) == K_tstr) {
                smeth = 1;
                cf = yr(2, "typ", t_unk(), "st", yr_get(crt, "st"));
                ;
            } else {
                cf = typeof_field(yr_get(crt, "st"), yr_get(crt, "typ"),
                                  yr_get(ccal, "key"),
                                  yv_l(yr_get(ccal, "line")),
                                  yv_l(yr_get(ccal, "col")));
                ;
            }
            ;
        } else {
            cf = typeof_expr(st, ccal);
            ;
        }
        st = yr_get(cf, "st");
        if (smeth) {
            return typeof_method(st, node, yr_get(ccal, "key"));
        } else if (yv_l(yr_get(yr_get(cf, "typ"), "k")) == K_tfunc) {
            Yv *cft = yr_get(cf, "typ");
            Yv *cfargs = yr_get(cft, "args");
            if (yv_len(cargs) != yv_len(cfargs)) {
                st = fail(st,
                          ys_cat(ys_cat(ys_cat(ys("call takes "),
                                               ys_long(yv_len(cfargs))),
                                         ys(" args, got ")),
                                ys_long(yv_len(cargs))),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr_get(cft, "ret"), "st", st);
            } else {
                long ci = 0;
                while (ci < yv_len(cargs)) {
                    Yv *ra = typeof_want(st, ya_get(cargs, ci), ya_get(cfargs, ci));
                    st = yr_get(ra, "st");
                    st = expect_cast(st, yr_get(ra, "typ"), ya_get(cfargs, ci),
                                     ys_cat(ys("call arg "), ys_long(ci)),
                                     yv_l(yr_get(node, "line")),
                                     yv_l(yr_get(node, "col")));
                    ci = ci + 1;
                }
                return yr(2, "typ", yr_get(cft, "ret"), "st", st);
            }
        } else {
            st = fail(st,
                      ys_cat(ys_cat(ys("cannot call "), tstr(yr_get(cf, "typ"))),
                             ys(" (not a function)")),
                      yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
            long i = 0;
            while (i < yv_len(yr_get(node, "args"))) {
                Yv *r = typeof_expr(st, ya_get(cargs, i));
                st = yr_get(r, "st");
                i = i + 1;
            }
            return yr(2, "typ", t_unk(), "st", st);
        }
    } else {
        Yv *name = yr_get(yr_get(node, "callee"), "v");
        if (ys_eq_lit(name, "#fmt")) {
            return typeof_fmt(st, node);
        } else if (ys_eq_lit(name, "print")) {
            if (yv_len(yr_get(node, "args")) != 1) {
                st = fail(st, ys("print takes exactly 1 argument"),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(1, "k", yv_long(K_tvoid)), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = yr_get(r, "st");
                if (yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tlong ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tbyte ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tbool ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tstr ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tfloat ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tunk ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_trec ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tmap ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tfunc ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tarr ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tarrfix ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_topt ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tunion) {
                    return yr(2, "typ", yr(1, "k", yv_long(K_tvoid)), "st", st);
                } else {
                    st = fail(st,
                              ys_cat(ys("print supports long/bool/float/str/array/record/map/option, got "),
                                     tstr(yr_get(r, "typ"))),
                              yv_l(yr_get(node, "line")),
                              yv_l(yr_get(node, "col")));
                    return yr(2, "typ", yr(1, "k", yv_long(K_tvoid)), "st", st);
                }
            }
        } else if (ys_eq_lit(name, "keys")) {
            // keys(m) -> [K]: the keys of map m in insertion order, a copy
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("keys takes exactly 1 argument"),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", t_unk(), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = yr_get(r, "st");
                Yv *mt = unfold(yr_get(r, "typ"));
                if (yv_l(yr_get(mt, "k")) == K_tmap) {
                    return yr(2, "typ", yr(2, "k", yv_long(K_tarr), "of", yr_get(mt, "key")), "st", st);
                } else if (yv_l(yr_get(mt, "k")) == K_tunk) {
                    return yr(2, "typ", t_unk(), "st", st);
                } else {
                    st = fail(st, ys_cat(ys("keys needs a map, got "), tstr(yr_get(r, "typ"))),
                              yv_l(yr_get(node, "line")),
                              yv_l(yr_get(node, "col")));
                    return yr(2, "typ", t_unk(), "st", st);
                }
            }
        } else if (ys_eq_lit(name, "len")) {
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("len takes exactly 1 argument"),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(1, "k", yv_long(K_tlong)), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = yr_get(r, "st");
                if (yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tarrfix ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tarr ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tstr ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tmap) {
                    return yr(2, "typ", yr(1, "k", yv_long(K_tlong)), "st", st);
                } else if (yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tunk ||
                           yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tnone ||
                           yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tname) {
                    // poison/unannotated shape (tcompat law): root cause
                    // errors once at its own site; len() unifies quietly.
                    return yr(2, "typ", yr(1, "k", yv_long(K_tlong)), "st", st);
                } else {
                    st = fail(st,
                              ys_cat(ys("len supports arrays, strings and maps, got "),
                                     tstr(yr_get(r, "typ"))),
                              yv_l(yr_get(node, "line")),
                              yv_l(yr_get(node, "col")));
                    return yr(2, "typ", yr(1, "k", yv_long(K_tlong)), "st", st);
                }
            }
        } else if (ys_eq_lit(name, "some")) {
            // some(v) -> typeof(v)? (boxes v on the heap; 0 = none)
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("some takes exactly 1 argument"),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", t_unk(), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = yr_get(r, "st");
                if (!is_value_type(yr_get(r, "typ"))) {
                    st = fail(st,
                              ys_cat(ys_cat(ys("cannot put "),
                                            tstr(yr_get(r, "typ"))),
                                     ys(" in an option")),
                              yv_l(yr_get(node, "line")),
                              yv_l(yr_get(node, "col")));
                    return yr(2, "typ", t_unk(), "st", st);
                } else {
                    return yr(2, "typ",
                              yr(2, "k", yv_long(K_topt), "of", yr_get(r, "typ")),
                              "st", st);
                }
            }
        } else if (ys_eq_lit(name, "is_some")) {
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("is_some takes exactly 1 argument"),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(1, "k", yv_long(K_tbool)), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = yr_get(r, "st");
                if (yv_l(yr_get(yr_get(r, "typ"), "k")) == K_topt ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tunk) {
                    return yr(2, "typ", yr(1, "k", yv_long(K_tbool)), "st", st);
                } else {
                    st = fail(st,
                              ys_cat(ys("is_some needs an option, got "),
                                     tstr(yr_get(r, "typ"))),
                              yv_l(yr_get(node, "line")),
                              yv_l(yr_get(node, "col")));
                    return yr(2, "typ", yr(1, "k", yv_long(K_tbool)), "st", st);
                }
            }
        } else if (ys_eq_lit(name, "opt$test")) {
            /* The test `?.` lowers to (parser.y parse_postfix): `x is
               there`. Only the parser emits the name -- `$` is not an
               identifier character -- so the diagnostic names the operator
               the program wrote, and there is no arity to check. */
            Yv *tr = typeof_expr(st, ya_get(cargs, 0));
            st = yr_get(tr, "st");
            if (yv_l(yr_get(yr_get(tr, "typ"), "k")) == K_topt ||
                yv_l(yr_get(yr_get(tr, "typ"), "k")) == K_tunk ||
                yv_l(yr_get(yr_get(tr, "typ"), "k")) == K_tname) {
                return yr(2, "typ", yr(1, "k", yv_long(K_tbool)), "st", st);
            } else {
                st = fail(st,
                          ys_cat(ys("'?.' needs an option, got "),
                                 tstr(yr_get(tr, "typ"))),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(1, "k", yv_long(K_tbool)), "st", st);
            }
        } else if (ys_eq_lit(name, "opt$val")) {
            /* The value side of a `?.` chain (parser.y parse_postfix):
               `some` for a payload that needs a box, except that a chain
               ending in a void call stays void -- `obj?.cleanup();` runs the
               method when the object is there and hands nothing back. */
            Yv *vr = typeof_expr(st, ya_get(cargs, 0));
            st = yr_get(vr, "st");
            if (yv_l(yr_get(yr_get(vr, "typ"), "k")) == K_tvoid ||
                yv_l(yr_get(yr_get(vr, "typ"), "k")) == K_tunk) {
                return yr(2, "typ", yr_get(vr, "typ"), "st", st);
            } else if (yv_l(yr_get(yr_get(vr, "typ"), "k")) == K_topt) {
                /* A payload that is an option IS its box, so the chain ends
                   in one option, not two: `a?.b` (b: T?) is `T?`, and none
                   means "a was none, or b was". Flat is what lets the next
                   link carry its own `?.` -- and what the emitter's
                   gen_opt_val assumes to skip the box. */
                return yr(2, "typ", yr_get(vr, "typ"), "st", st);
            } else if (!is_value_type(yr_get(vr, "typ"))) {
                st = fail(st,
                          ys_cat(ys_cat(ys("cannot put "),
                                        tstr(yr_get(vr, "typ"))),
                                 ys(" after '?.'")),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", t_unk(), "st", st);
            } else {
                return yr(2, "typ",
                          yr(2, "k", yv_long(K_topt), "of", yr_get(vr, "typ")),
                          "st", st);
            }
        } else if (ys_eq_lit(name, "unwrap")) {
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("unwrap takes exactly 1 argument"),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", t_unk(), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = yr_get(r, "st");
                if (yv_l(yr_get(yr_get(r, "typ"), "k")) == K_topt) {
                    return yr(2, "typ", yr_get(yr_get(r, "typ"), "of"), "st",
                              st);
                } else if (yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tunk) {
                    return yr(2, "typ", t_unk(), "st", st);
                } else if (yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tnone) {
                    return yr(2, "typ", t_unk(), "st", st);
                } else if (yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tname) {
                    return yr(2, "typ", t_unk(), "st", st);
                } else if (yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tparams) {
                    return yr(2, "typ", t_unk(), "st", st);
                } else {
                    st = fail(st,
                              ys_cat(ys("unwrap needs an option, got "),
                                     tstr(yr_get(r, "typ"))),
                              yv_l(yr_get(node, "line")),
                              yv_l(yr_get(node, "col")));
                    return yr(2, "typ", t_unk(), "st", st);
                }
            }
        } else if (ys_eq_lit(name, "trim")) {
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("trim takes exactly 1 argument"),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", t_unk(), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = yr_get(r, "st");
                st = expect_type(st, yr_get(r, "typ"), yr(1, "k", yv_long(K_tstr)),
                                 ys("trim string"), yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(1, "k", yv_long(K_tstr)), "st", st);
            }
        } else if (ys_eq_lit(name, "ord")) {
            // ord(s) -> long (first byte, -1 if empty)
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("ord takes exactly 1 argument"),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", t_unk(), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = yr_get(r, "st");
                st = expect_type(st, yr_get(r, "typ"), yr(1, "k", yv_long(K_tstr)),
                                 ys("ord string"), yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(1, "k", yv_long(K_tlong)), "st", st);
            }
        } else if (ys_eq_lit(name, "byte_at")) {
            // byte_at(s, i) -> long (byte i of s, trapped out of bounds)
            if (yv_len(cargs) != 2) {
                st = fail(st, ys("byte_at takes exactly 2 arguments"),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", t_unk(), "st", st);
            } else {
                Yv *r0 = typeof_expr(st, ya_get(cargs, 0));
                st = yr_get(r0, "st");
                st = expect_type(st, yr_get(r0, "typ"), yr(1, "k", yv_long(K_tstr)),
                                 ys("byte_at string"), yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col")));
                Yv *r2 = typeof_expr(st, ya_get(cargs, 1));
                st = yr_get(r2, "st");
                st = expect_type(st, yr_get(r2, "typ"), yr(1, "k", yv_long(K_tlong)),
                                 ys("byte_at index"), yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(1, "k", yv_long(K_tlong)), "st", st);
            }
        } else if (ys_eq_lit(name, "chr")) {
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("chr takes exactly 1 argument"),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", t_unk(), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = yr_get(r, "st");
                st = expect_type(st, yr_get(r, "typ"), yr(1, "k", yv_long(K_tlong)),
                                 ys("chr code"), yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(1, "k", yv_long(K_tstr)), "st", st);
            }
        } else if (ys_eq_lit(name, "tonum")) {
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("tonum takes exactly 1 argument"),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", t_unk(), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = yr_get(r, "st");
                st = expect_type(st, yr_get(r, "typ"), yr(1, "k", yv_long(K_tstr)),
                                 ys("tonum string"), yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(1, "k", yv_long(K_tlong)), "st", st);
            }
        } else if (ys_eq_lit(name, "tostring")) {
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("tostring takes exactly 1 argument"),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", t_unk(), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = yr_get(r, "st");
                if (yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tlong ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tbyte ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tbool ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tstr ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tfloat ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tunk ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tarr ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tarrfix ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_trec ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tmap ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_topt ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tunion) {
                    return yr(2, "typ", yr(1, "k", yv_long(K_tstr)), "st", st);
                } else {
                    st = fail(st,
                              ys_cat(ys("tostring supports long/bool/float/str/array/record/map/option, got "),
                                     tstr(yr_get(r, "typ"))),
                              yv_l(yr_get(node, "line")),
                              yv_l(yr_get(node, "col")));
                    return yr(2, "typ", t_unk(), "st", st);
                }
            }
        } else if (ys_eq_lit(name, "typeof")) {
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("typeof takes exactly 1 argument"),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", t_unk(), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = yr_get(r, "st");
                return yr(2, "typ", yr(1, "k", yv_long(K_tstr)), "st", st);
            }
        } else if (ys_eq_lit(name, "index_of") ||
                   ys_eq_lit(name, "last_index_of")) {
            if (yv_len(cargs) != 2) {
                st = fail(st,
                          ys_cat(name, ys(" takes exactly 2 arguments (string, sub)")),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", t_unk(), "st", st);
            } else {
                Yv *r0 = typeof_expr(st, ya_get(cargs, 0));
                st = yr_get(r0, "st");
                Yv *r1 = typeof_expr(st, ya_get(cargs, 1));
                st = yr_get(r1, "st");
                st = expect_type(st, yr_get(r0, "typ"), yr(1, "k", yv_long(K_tstr)),
                                 ys_cat(name, ys(" string")),
                                 yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col")));
                st = expect_type(st, yr_get(r1, "typ"), yr(1, "k", yv_long(K_tstr)),
                                 ys_cat(name, ys(" sub")),
                                 yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(1, "k", yv_long(K_tlong)), "st", st);
            }
        } else if (ys_eq_lit(name, "join") && yv_len(cargs) == 1) {
            // join t: wait for thread t (spawn's function) and take its value
            Yv *r = typeof_expr(st, ya_get(cargs, 0));
            st = yr_get(r, "st");
            Yv *ft = unfold(yr_get(r, "typ"));
            if (yv_l(yr_get(ft, "k")) == K_tfunc && yv_len(fn_args(ft)) == 0) {
                return yr(2, "typ", yr_get(ft, "ret"), "st", st);
            } else if (yv_l(yr_get(ft, "k")) == K_tunk) {
                return yr(2, "typ", t_unk(), "st", st);
            } else {
                st = fail(st, ys_cat(ys("join takes a thread (a spawn's value), got "), tstr(yr_get(r, "typ"))), yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
                return yr(2, "typ", t_unk(), "st", st);
            }
        } else if (ys_eq_lit(name, "spawn") || ys_eq_lit(name, "fork")) {
            // spawn { b } / fork { b }: b as a function of no parameters
            if (yv_len(cargs) != 1) {
                st = fail(st, ys_cat(name, ys(" takes a block")), yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
                return yr(2, "typ", t_unk(), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = yr_get(r, "st");
                Yv *ft = unfold(yr_get(r, "typ"));
                if (yv_l(yr_get(ft, "k")) == K_tfunc && yv_len(fn_args(ft)) == 0) {
                    if (ys_eq_lit(name, "spawn")) { return yr(2, "typ", ft, "st", st); } else { return yr(2, "typ", yr(1, "k", yv_long(K_tlong)), "st", st); }
                } else if (yv_l(yr_get(ft, "k")) == K_tunk) {
                    return yr(2, "typ", t_unk(), "st", st);
                } else {
                    st = fail(st, ys_cat(ys_cat(name, ys(" takes a block (a function of no parameters), got ")), tstr(yr_get(r, "typ"))), yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
                    return yr(2, "typ", t_unk(), "st", st);
                }
            }
        } else if (ys_eq_lit(name, "wait_pid")) {
            // wait_pid(pid) -> long: the exit status of a forked child
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("wait_pid takes exactly 1 argument (a pid)"), yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(1, "k", yv_long(K_tlong)), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = expect_type(yr_get(r, "st"), yr_get(r, "typ"), yr(1, "k", yv_long(K_tlong)), ys("wait_pid's pid"), yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(1, "k", yv_long(K_tlong)), "st", st);
            }
        } else if (ys_eq_lit(name, "mutex")) {
            if (yv_len(cargs) != 0) {
                st = fail(st, ys("mutex takes no arguments"), yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
            }
            return yr(2, "typ", t_mutex(), "st", st);
        } else if (ys_eq_lit(name, "sem")) {
            // sem(n): a semaphore counting n
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("sem takes exactly 1 argument (its count)"), yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = expect_type(yr_get(r, "st"), yr_get(r, "typ"), yr(1, "k", yv_long(K_tlong)), ys("sem's count"), yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
            }
            return yr(2, "typ", t_sem(), "st", st);
        } else if (ys_eq_lit(name, "lock") || ys_eq_lit(name, "try_lock")) {
            // lock m { b } -> b's value; try_lock m { b } -> whether b ran
            if (yv_len(cargs) != 2) {
                st = fail(st, ys_cat(name, ys(" takes a mutex and a block")), yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
                return yr(2, "typ", t_unk(), "st", st);
            } else {
                Yv *rm = typeof_expr(st, ya_get(cargs, 0));
                st = expect_type(yr_get(rm, "st"), yr_get(rm, "typ"), t_mutex(), ys_cat(name, ys("'s mutex")), yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
                Yv *r = typeof_expr(st, ya_get(cargs, 1));
                st = yr_get(r, "st");
                Yv *ft = unfold(yr_get(r, "typ"));
                if (yv_l(yr_get(ft, "k")) == K_tfunc && yv_len(fn_args(ft)) == 0) {
                    if (ys_eq_lit(name, "lock")) { return yr(2, "typ", yr_get(ft, "ret"), "st", st); } else { return yr(2, "typ", yr(1, "k", yv_long(K_tbool)), "st", st); }
                } else if (yv_l(yr_get(ft, "k")) == K_tunk) {
                    return yr(2, "typ", t_unk(), "st", st);
                } else {
                    st = fail(st, ys_cat(ys_cat(name, ys(" takes a block (a function of no parameters), got ")), tstr(yr_get(r, "typ"))), yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
                    return yr(2, "typ", t_unk(), "st", st);
                }
            }
        } else if (ys_eq_lit(name, "post") || ys_eq_lit(name, "wait")) {
            // post s / wait s: a semaphore up, or down (waiting while 0)
            if (yv_len(cargs) != 1) {
                st = fail(st, ys_cat(name, ys(" takes exactly 1 argument (a sem)")), yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = expect_type(yr_get(r, "st"), yr_get(r, "typ"), t_sem(), ys_cat(name, ys("'s semaphore")), yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
            }
            return yr(2, "typ", yr(1, "k", yv_long(K_tvoid)), "st", st);
        } else if (ys_eq_lit(name, "join")) {
            // join(arr, delim) -> str (elements via tostring, like C)
            if (yv_len(cargs) != 2) {
                st = fail(st,
                          ys("join takes exactly 2 arguments (array, delimiter)"),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", t_unk(), "st", st);
            } else {
                Yv *r0 = typeof_expr(st, ya_get(cargs, 0));
                st = yr_get(r0, "st");
                Yv *r1 = typeof_expr(st, ya_get(cargs, 1));
                st = yr_get(r1, "st");
                if (yv_l(yr_get(yr_get(r0, "typ"), "k")) != K_tarr &&
                    yv_l(yr_get(yr_get(r0, "typ"), "k")) != K_tunk) {
                    st = fail(st,
                              ys_cat(ys("join needs an array, got "),
                                     tstr(yr_get(r0, "typ"))),
                              yv_l(yr_get(node, "line")),
                              yv_l(yr_get(node, "col")));
                    ;
                }
                st = expect_type(st, yr_get(r1, "typ"), yr(1, "k", yv_long(K_tstr)),
                                 ys("join delimiter"), yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(1, "k", yv_long(K_tstr)), "st", st);
            }
        } else if (ys_eq_lit(name, "split")) {
            // split(s, delim) -> [str]
            if (yv_len(cargs) != 2) {
                st = fail(st,
                          ys("split takes exactly 2 arguments (string, delimiter)"),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", t_unk(), "st", st);
            } else {
                Yv *r0 = typeof_expr(st, ya_get(cargs, 0));
                st = yr_get(r0, "st");
                Yv *r1 = typeof_expr(st, ya_get(cargs, 1));
                st = yr_get(r1, "st");
                st = expect_type(st, yr_get(r0, "typ"), yr(1, "k", yv_long(K_tstr)),
                                 ys("split string"), yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col")));
                st = expect_type(st, yr_get(r1, "typ"), yr(1, "k", yv_long(K_tstr)),
                                 ys("split delimiter"), yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(2, "k", yv_long(K_tarr), "of", yr(1, "k", yv_long(K_tstr))),
                          "st", st);
            }
        } else if (ys_eq_lit(name, "range")) {
            // range(n) -> [long]: 0, 1, ..., n-1
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("range takes exactly 1 argument"),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(2, "k", yv_long(K_tarr), "of", yr(1, "k", yv_long(K_tlong))),
                          "st", st);
            } else {
                Yv *rr = typeof_expr(st, ya_get(cargs, 0));
                st = expect_type(yr_get(rr, "st"), yr_get(rr, "typ"),
                                 yr(1, "k", yv_long(K_tlong)), ys("range count"),
                                 yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(2, "k", yv_long(K_tarr), "of", yr(1, "k", yv_long(K_tlong))),
                          "st", st);
            }
        } else if (ys_eq_lit(name, "eputs")) {
            // eputs(v) -> void: like puts, but to stderr (fd 2), so
            // diagnostics never mix into program stdout or `-S` output.
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("eputs takes exactly 1 argument"),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(1, "k", yv_long(K_tvoid)), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = yr_get(r, "st");
                if (yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tlong ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tbool ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tstr ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tfloat ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tunk) {
                    return yr(2, "typ", yr(1, "k", yv_long(K_tvoid)), "st", st);
                } else {
                    st = fail(st,
                              ys_cat(ys("eputs supports long/bool/str, got "),
                                     tstr(yr_get(r, "typ"))),
                              yv_l(yr_get(node, "line")),
                              yv_l(yr_get(node, "col")));
                    return yr(2, "typ", yr(1, "k", yv_long(K_tvoid)), "st", st);
                }
            }
        } else if (ys_eq_lit(name, "clock_us")) {
            // clock_us() -> long: monotonic microseconds (differences only).
            if (yv_len(cargs) != 0) {
                st = fail(st, ys("clock_us takes no arguments"),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(1, "k", yv_long(K_tlong)), "st", st);
            } else {
                return yr(2, "typ", yr(1, "k", yv_long(K_tlong)), "st", st);
            }
        } else if (ys_eq_lit(name, "time_us")) {
            // time_us() -> long: wall-clock microseconds since the Unix epoch.
            if (yv_len(cargs) != 0) {
                st = fail(st, ys("time_us takes no arguments"),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(1, "k", yv_long(K_tlong)), "st", st);
            } else {
                return yr(2, "typ", yr(1, "k", yv_long(K_tlong)), "st", st);
            }
        } else if (ys_eq_lit(name, "heap_used")) {
            // heap_used() -> long: arena bytes handed out so far.
            if (yv_len(cargs) != 0) {
                st = fail(st, ys("heap_used takes no arguments"),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(1, "k", yv_long(K_tlong)), "st", st);
            } else {
                return yr(2, "typ", yr(1, "k", yv_long(K_tlong)), "st", st);
            }
        } else if (ys_eq_lit(name, "sleep")) {
            // sleep(ms): suspend the caller for ms milliseconds.
            if (yv_len(cargs) != 1) {
                st = fail(st,
                          ys("sleep takes exactly 1 argument (milliseconds)"),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(1, "k", yv_long(K_tvoid)), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = yr_get(r, "st");
                st = expect_type(st, yr_get(r, "typ"), yr(1, "k", yv_long(K_tlong)),
                                 ys("sleep duration"), yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(1, "k", yv_long(K_tvoid)), "st", st);
            }
        } else if (ys_eq_lit(name, "puts")) {
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("puts takes exactly 1 argument"),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(1, "k", yv_long(K_tvoid)), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = yr_get(r, "st");
                if (yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tlong ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tbool ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tstr ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tfloat ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tunk) {
                    return yr(2, "typ", yr(1, "k", yv_long(K_tvoid)), "st", st);
                } else {
                    st = fail(st,
                              ys_cat(ys("puts supports long/bool/str, got "),
                                     tstr(yr_get(r, "typ"))),
                              yv_l(yr_get(node, "line")),
                              yv_l(yr_get(node, "col")));
                    return yr(2, "typ", yr(1, "k", yv_long(K_tvoid)), "st", st);
                }
            }
        } else if (ys_eq_lit(name, "exit")) {
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("exit takes exactly 1 argument"),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(1, "k", yv_long(K_tvoid)), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = yr_get(r, "st");
                st = expect_type(st, yr_get(r, "typ"), yr(1, "k", yv_long(K_tlong)),
                                 ys("exit code"), yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(1, "k", yv_long(K_tvoid)), "st", st);
            }
        } else if (ys_eq_lit(name, "argv")) {
            if (yv_len(cargs) != 0) {
                st = fail(st, ys("argv takes no arguments"),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(2, "k", yv_long(K_tarr), "of", yr(1, "k", yv_long(K_tstr))),
                          "st", st);
            } else {
                return yr(2, "typ", yr(2, "k", yv_long(K_tarr), "of", yr(1, "k", yv_long(K_tstr))),
                          "st", st);
            }
        } else if (ys_eq_lit(name, "bytes")) {
            // bytes(s) -> [byte]: the string's raw bytes, packed.
            if (yv_len(cargs) != 1) {
                st = fail(st, ys("bytes takes exactly 1 argument (string)"),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(2, "k", yv_long(K_tarr), "of", yr(1, "k", yv_long(K_tbyte))),
                          "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = yr_get(r, "st");
                st = expect_type(st, yr_get(r, "typ"), yr(1, "k", yv_long(K_tstr)),
                                 ys("bytes argument"), yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(2, "k", yv_long(K_tarr), "of", yr(1, "k", yv_long(K_tbyte))),
                          "st", st);
            }
        } else if (ys_eq_lit(name, "from_bytes")) {
            // from_bytes(b) -> str: the inverse of bytes(). A fixed
            // [byte; N] has the same {len, cap, data} header, so it is
            // accepted as is.
            if (yv_len(cargs) != 1) {
                st = fail(st,
                          ys("from_bytes takes exactly 1 argument (byte array)"),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(1, "k", yv_long(K_tstr)), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = yr_get(r, "st");
                Yv *fbt = yr_get(r, "typ");
                Yv *fbw = yr(2, "k", yv_long(K_tarr), "of", yr(1, "k", yv_long(K_tbyte)));
                if (yv_l(yr_get(fbt, "k")) == K_tarrfix) {
                    if (tcompat(yr(2, "k", yv_long(K_tarr), "of", yr_get(fbt, "of")), fbw)) {
                        ;
                    } else {
                        st = fail(st,
                                  ys_cat(ys("from_bytes argument: expected [byte] or [byte; N], got "),
                                         tstr(fbt)),
                                  yv_l(yr_get(node, "line")),
                                  yv_l(yr_get(node, "col")));
                    }
                } else {
                    st = expect_type(st, fbt, fbw,
                                     ys("from_bytes argument"),
                                     yv_l(yr_get(node, "line")),
                                     yv_l(yr_get(node, "col")));
                }
                return yr(2, "typ", yr(1, "k", yv_long(K_tstr)), "st", st);
            }
        } else if (ys_eq_lit(name, "ptr_addr")) {
            // ptr_addr(p) -> long: a pointer's numeric value. Pointers ARE
            // longs at run time; this is the one place the type system lets
            // that through, so Y code can build a char** (an array of
            // addresses) without the emitter growing a bespoke helper.
            if (yv_len(cargs) != 1) {
                st = fail(st,
                          ys("ptr_addr takes exactly 1 argument (pointer)"),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(1, "k", yv_long(K_tlong)), "st", st);
            } else {
                Yv *r = typeof_expr(st, ya_get(cargs, 0));
                st = yr_get(r, "st");
                if (yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tptr ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tstr ||
                    yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tunk) {
                    return yr(2, "typ", yr(1, "k", yv_long(K_tlong)), "st", st);
                } else {
                    st = fail(st,
                              ys_cat(ys("ptr_addr needs a pointer, got "),
                                     tstr(yr_get(r, "typ"))),
                              yv_l(yr_get(node, "line")),
                              yv_l(yr_get(node, "col")));
                    return yr(2, "typ", yr(1, "k", yv_long(K_tlong)), "st", st);
                }
            }
        } else if (ys_eq_lit(name, "os_call")) {
            /* os_call("y_os_read", fd, buf, len) -> long: the NAMED syscall
               layer. The first argument is a name from os_call_names (the only
               list of them), the rest are the arguments the named block takes
               -- at most six, pushed on the stack in order, so the block reads
               them the way every Y function does (the last pushed is the first
               parameter, lowest).

               Why a NAME and not a syscall number: the four embedded std units
               are compiled once per compiler and serialized into one std pack,
               so anything they resolve at compile time is baked for whichever
               target wrote that pack and --target on the consuming compiler
               cannot undo it. A number, a struct layout or a branch on the
               target are all baked; a name is not, because `call y_os_read` is
               the same instruction on both and the arch module decides what
               that label is (read(2) on Linux, NtReadFile on Windows).
               Measured, both ways, with a conditional in rt.y instead: a PE
               built from the pack carried the ELF inline write(2) and printed
               nothing, while --std-src (which recompiles) worked. */
            if (yv_len(cargs) < 1 || yv_len(cargs) > 7) {
                st = fail(st, ys("os_call takes a name and 0-6 arguments"),
                          yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(1, "k", yv_long(K_tlong)), "st", st);
            } else if (yv_l(yr_get(ya_get(cargs, 0), "k")) != K_str) {
                st = fail(st, ys("os_call needs a literal call name"),
                          yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(1, "k", yv_long(K_tlong)), "st", st);
            } else {
                /* The name is a str LITERAL. The arm above proved that (`k` is
                   K.str, the only Node kind with a `v`), so reading `v` off it
                   is the same read the Y twin makes after its cast to the
                   member -- and in the C copy it is a direct field read, since
                   records are shared (yv.h) and there is no copy to write
                   through. */
                Yv *nmv = yr_get(ya_get(cargs, 0), "v");
                Yv *r0 = typeof_expr(st, ya_get(cargs, 0));
                st = yr_get(r0, "st");
                if (!os_call_name(nmv)) {
                    st = fail(st,
                              ys_cat(ys_cat(ys("os_call: '"), nmv),
                                     ys("' is not a call name (see os_call_names)")),
                              yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
                }
                long i = 1;
                while (i < yv_len(cargs)) {
                    Yv *r = typeof_expr(st, ya_get(cargs, i));
                    st = yr_get(r, "st");
                    /* The same argument types `syscall` takes after its number:
                       a long, a bool, a str (whose +8 header adjustment the
                       emitter does), or a *T for a buffer the block fills. */
                    if (yv_l(yr_get(yr_get(r, "typ"), "k")) != K_tlong
                        && yv_l(yr_get(yr_get(r, "typ"), "k")) != K_tbool
                        && yv_l(yr_get(yr_get(r, "typ"), "k")) != K_tstr
                        && yv_l(yr_get(yr_get(r, "typ"), "k")) != K_tptr
                        && yv_l(yr_get(yr_get(r, "typ"), "k")) != K_tunk) {
                        st = fail(st, ys_cat(ys_cat(ys("os_call arg "), ys_long(i)),
                                              ys_cat(ys(" must be long/bool/str/*T, got "),
                                                     tstr(yr_get(r, "typ")))),
                                  yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
                    }
                    i = i + 1;
                }
                return yr(2, "typ", yr(1, "k", yv_long(K_tlong)), "st", st);
            }
        } else if (ys_eq_lit(name, "syscall")) {
            /* Up to six arguments on SysV (rdi..r9), up to NINE on Win64:
               its `syscall` takes FOUR in registers (r10, rdx, r8, r9) and
               the fifth and after at 40(%rsp), 48(%rsp), ... -- and
               NtWriteFile, the only way to put a byte on the standard output,
               takes nine. gen_syscall reserves that room itself on the
               Windows side. (The old comment here said six in registers and
               32(%rsp); both wrong, and see w_syscall_reg in native.c for the
               proof that four registers at 40(%rsp) is the real layout.) */
            long maxargs = 7;
            if (target_is_windows()) { maxargs = 10; }
            if (yv_len(yr_get(node, "args")) < 1 ||
                yv_len(yr_get(node, "args")) > maxargs) {
                st = fail(st,
                          ys_cat(ys_cat(ys_cat(ys_cat(ys("syscall needs 1-"),
                                                    ys_long(maxargs)),
                                             ys(" arguments (number + up to ")),
                                          ys_long(maxargs - 1)),
                                       ys(" args)")),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", yr(1, "k", yv_long(K_tlong)), "st", st);
            } else {
                long i = 0;
                while (i < yv_len(yr_get(node, "args"))) {
                    Yv *r = typeof_expr(st, ya_get(cargs, i));
                    st = yr_get(r, "st");
                    if (i == 0) {
                        /* The number lands in %rax. A str there is a heap
                         * pointer, so the kernel would take its address as
                         * the call number -- with every argument register
                         * still holding whatever the stack held (types.y). */
                        if (yv_l(yr_get(yr_get(r, "typ"), "k")) != K_tlong &&
                            yv_l(yr_get(yr_get(r, "typ"), "k")) != K_tbyte &&
                            yv_l(yr_get(yr_get(r, "typ"), "k")) != K_tunk) {
                            st = fail(st,
                                      ys_cat(ys("syscall needs a number first, got "),
                                             tstr(yr_get(r, "typ"))),
                                      yv_l(yr_get(node, "line")),
                                      yv_l(yr_get(node, "col")));
                        }
                    } else if (yv_l(yr_get(yr_get(r, "typ"), "k")) != K_tlong &&
                               yv_l(yr_get(yr_get(r, "typ"), "k")) != K_tbool &&
                               yv_l(yr_get(yr_get(r, "typ"), "k")) != K_tstr &&
                               yv_l(yr_get(yr_get(r, "typ"), "k")) != K_tptr &&
                               yv_l(yr_get(yr_get(r, "typ"), "k")) != K_tunk) {
                        st = fail(st,
                                  ys_cat(ys_cat(ys_cat(ys("syscall arg "),
                                                     ys_long(i)),
                                               ys(" must be long/bool/str/*T, got ")),
                                        tstr(yr_get(r, "typ"))),
                                  yv_l(yr_get(node, "line")),
                                  yv_l(yr_get(node, "col")));
                        ;
                    }
                    i = i + 1;
                }
                return yr(2, "typ", yr(1, "k", yv_long(K_tlong)), "st", st);
            }
        } else {
            // resolve the callee to a function type: `self`, then scope
            Yv *fterr = ys("");
            Yv *ft = t_unk();
            if (ys_eq_lit(name, "self")) {
                if (yv_l(yr_get(yr_get(st, "self"), "k")) == K_tnone ||
                    yv_l(yr_get(yr_get(st, "self"), "k")) == K_tunk) {
                    fterr = ys("'self' outside of a function");
                    ;
                } else {
                    ft = yr_get(st, "self");
                    ;
                }
            } else {
                Yv *got = lookup(yr_get(st, "bindings"), name);
                if (ys_eq_lit(yr_get(got, "kind"), "")) {
                    fterr = ys_cat(ys_cat(ys("undefined function '"), disp(name)),
                                   ys("'"));
                    if (ys_eq_lit(name, "substr")) {
                        fterr = ys_cat(fterr, ys(" (slice instead: s[start:end])"));
                        ;
                    }
                    ;
                } else if (yv_l(yr_get(yr_get(got, "typ"), "k")) == K_tfunc) {
                    // Either a hoisted `def` (kind "func") or a local/param
                    // holding a closure value — both are callable.
                    ft = yr_get(got, "typ");
                    ;
                } else {
                    fterr = ys_cat(ys_cat(ys("'"), disp(name)),
                                   ys("' is not a function"));
                    ;
                }
            }
            if (!ys_eq_lit(fterr, "")) {
                st = fail(st, fterr, yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                return yr(2, "typ", t_unk(), "st", st);
            } else if (ret_pending(ft)) {
                st = fail(st,
                          ys_cat(ys_cat(ys("'"), disp(name)),
                                 ys("' is used before its return type is known (annotate it)")),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                long i = 0;
                while (i < yv_len(cargs)) {
                    Yv *r = typeof_expr(st, ya_get(cargs, i));
                    st = yr_get(r, "st");
                    i = i + 1;
                }
                return yr(2, "typ", t_unk(), "st", st);
            } else if (yv_l(yr_get(ft, "k")) != K_tfunc) {
                // poisoned binding (tunk) from an earlier error — don't
                // cascade new errors, but still check the arguments for
                // their own errors.
                long i = 0;
                while (i < yv_len(cargs)) {
                    Yv *r = typeof_expr(st, ya_get(cargs, i));
                    st = yr_get(r, "st");
                    i = i + 1;
                }
                return yr(2, "typ", t_unk(), "st", st);
            } else {
                Yv *cargs_ft = yr_get(ft, "args");
                if (yv_len(cargs) != yv_len(cargs_ft)) {
                    st = fail(st,
                              ys_cat(ys_cat(ys_cat(ys_cat(ys_cat(ys("'"),
                                                                 disp(name)),
                                                           ys("' takes ")),
                                                ys_long(yv_len(cargs_ft))),
                                         ys(" args, got ")),
                                ys_long(yv_len(cargs))),
                              yv_l(yr_get(node, "line")),
                              yv_l(yr_get(node, "col")));
                    return yr(2, "typ", call_result(ft), "st", st);
                } else {
                    long i = 0;
                    while (i < yv_len(cargs)) {
                        Yv *r = typeof_want(st, ya_get(cargs, i), ya_get(cargs_ft, i));
                        st = yr_get(r, "st");
                        Yv *ak = yr_get(yr_get(r, "typ"), "k");
                        if (yv_l(ak) == K_tvoid) {
                            // void is not a value (an unannotated param
                            // would otherwise accept it quietly)
                            st = fail(st, ys_cat(ys_cat(ys_cat(ys_cat(ys("'"), disp(name)), ys("' arg ")), ys_long(i)), ys(": cannot pass a void value")), yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
                            ;
                        } else {
                            st = expect_arg(st, yr_get(r, "typ"),
                                            ya_get(cargs_ft, i),
                                            ya_get(cargs, i),
                                            ys_cat(ys_cat(ys_cat(ys("'"), disp(name)),
                                                          ys("' arg ")),
                                                   ys_long(i)),
                                            yv_l(yr_get(node, "line")),
                                            yv_l(yr_get(node, "col")));
                            ;
                        }
                        i = i + 1;
                    }
                    return yr(2, "typ", call_result(ft), "st", st);
                }
            }
        }
    }
}

static Yv *typeof_block(Yv *st, Yv *node) {
    // No scope push: names are unique post-rename, blocks share the frame.
    Yv *last = yr(1, "k", yv_long(K_tvoid));
    Yv *bstmts = yr_get(node, "stmts");
    long i = 0;
    while (i < yv_len(bstmts)) {
        Yv *r = typeof_expr(st, ya_get(bstmts, i));
        st = yr_get(r, "st");
        last = yr_get(r, "typ");
        i = i + 1;
    }
    return yr(2, "typ", last, "st", st);
}

// typeof_block with the block's value going where `want` is declared (a
// def's body, typeof_def): its last statement through typeof_want.
static Yv *typeof_block_want(Yv *st, Yv *node, Yv *want) {
    Yv *last = yr(1, "k", yv_long(K_tvoid));
    Yv *bstmts = yr_get(node, "stmts");
    long i = 0;
    while (i < yv_len(bstmts)) {
        Yv *w = yr(1, "k", yv_long(K_tnone));
        if (i == yv_len(bstmts) - 1) {
            w = want;
        }
        Yv *rr = typeof_want(st, ya_get(bstmts, i), w);
        st = yr_get(rr, "st");
        last = yr_get(rr, "typ");
        i = i + 1;
    }
    return yr(2, "typ", last, "st", st);
}

// ── record literals where a type is declared ─────────────────────────────
// A record literal going where a type is declared -- a binding, an
// argument, a return value, a field, an element -- is checked against it
// (bidirectionally): it is created as that record type, or as the member
// of that union with its field names, each value checked against its
// field's type, a record literal there likewise. So `{l: {n: 1}, r: n2}`
// is an `Add` of `type Add = {l: Expr, r: Expr}`, its `l` an `Expr`
// holding a `{n: long}`. (Only a fresh record can be typed so: an existing
// one keeps its own type, a record being shared by reference.) native.y
// gen_reclit creates it as the same type (lit_target).

// The type of `node` going where `want` is declared: a record literal
// with a target (lit_target) is checked against it (typeof_lit); anything
// else is typeof_expr.
static Yv *typeof_want(Yv *st, Yv *node, Yv *want) {
    if (yv_l(yr_get(node, "k")) == K_call && is_some_call(node) &&
        yv_l(yr_get(unfold(want), "k")) == K_topt) {
        // some({...}) where T? is declared -- an optional argument passed
        // is one (rename.c) -- creates the literal as T
        Yv *args = yr_get(node, "args");
        Yv *wo = unfold(want);
        Yv *target = yr(1, "k", yv_long(K_tnone));
        if (yv_len(args) == 1 && yv_l(yr_get(ya_get(args, 0), "k")) == K_rec) {
            target = lit_target(ya_get(args, 0), yr_get(wo, "of"));
        }
        if (yv_l(yr_get(target, "k")) == K_tnone) {
            return typeof_expr(st, node);
        } else {
            Yv *r = typeof_lit(st, ya_get(args, 0), target);
            return yr(2, "typ", yr(2, "k", yv_long(K_topt), "of", yr_get(r, "typ")),
                      "st", yr_get(r, "st"));
        }
    }
    if (yv_l(yr_get(node, "k")) != K_rec) {
        return typeof_expr(st, node);
    } else {
        Yv *target = lit_target(node, want);
        if (yv_l(yr_get(target, "k")) == K_tnone) {
            return typeof_expr(st, node);
        } else {
            return typeof_lit(st, node, target);
        }
    }
}

// The record type a record literal is created as where `want` is declared:
// want itself when it is a record type the literal fits (lit_fits: its
// field names, but for optional fields it leaves out), or the member of a
// union want it fits -- the one with exactly its field names, else the
// only one it fits (as the union writes it, union_parts); tnone
// otherwise, and for a literal with a spread.
Yv *lit_target(Yv *node, Yv *want) {
    Yv *keys = yr_get(node, "keys");
    Yv *w = unfold(want);
    Yv *wk = yr_get(w, "k");
    Yv *found = yr(1, "k", yv_long(K_tnone));
    if (str_in(keys, ys("..."))) {
        ;
    } else if (yv_l(wk) == K_trec) {
        if (lit_fits(w, keys)) {
            found = want;
        }
    } else if (yv_l(wk) == K_tunion) {
        Yv *ps = union_parts(w);
        Yv *exact = yr(1, "k", yv_long(K_tnone));
        long nexact = 0;
        Yv *fit = yr(1, "k", yv_long(K_tnone));
        long nfit = 0;
        for (long i = 0; i < yv_len(ps); i++) {
            Yv *p = ya_get(ps, i);
            if (lit_fits(unfold(p), keys)) {
                fit = p;
                nfit = nfit + 1;
                if (same_names(unfold(p), keys)) {
                    exact = p;
                    nexact = nexact + 1;
                }
            }
        }
        if (nexact == 1) {
            found = exact;
        } else if (nexact == 0 && nfit == 1) {
            found = fit;
        }
    }
    return found;
}

// Record type t takes a literal with the field names keys: each is a
// field of t, and every field of t but an optional one is among them.
static int lit_fits(Yv *t, Yv *keys) {
    if (yv_l(yr_get(t, "k")) != K_trec) {
        return 0;
    }
    Yv *fs = yr_get(t, "fields");
    int ok = 1;
    for (long i = 0; i < yv_len(keys); i++) {
        if (field_pos(fs, ya_get(keys, i), 0) < 0) {
            ok = 0;
        }
    }
    for (long i = 0; i < yv_len(fs); i++) {
        Yv *f = ya_get(fs, i);
        if (!yv_b(yr_get(f, "opt")) && !str_in(keys, yr_get(f, "name"))) {
            ok = 0;
        }
    }
    return ok;
}

// Field `key` of record type t is optional (`key?: T`).
static int field_opt(Yv *t, Yv *key) {
    int opt = 0;
    if (yv_l(yr_get(t, "k")) == K_trec) {
        Yv *fs = yr_get(t, "fields");
        for (long i = 0; i < yv_len(fs); i++) {
            Yv *f = ya_get(fs, i);
            if (ys_eq(yr_get(f, "name"), key) && yv_b(yr_get(f, "opt"))) {
                opt = 1;
            }
        }
    }
    return opt;
}

// A value of type vt given for an optional field of type ft (T?) is
// wrapped -- some(v) -- when it is a T and not already a T? (or none).
// native.c gen_reclit decides by it too.
int opt_wraps(Yv *vt, Yv *ft) {
    Yv *fu = unfold(ft);
    if (yv_l(yr_get(fu, "k")) != K_topt) {
        return 0;
    }
    return !tcompat(vt, fu) && tcompat(vt, yr_get(fu, "of"));
}

// Record type t has exactly the field names keys (a name written twice
// counts once).
static int same_names(Yv *t, Yv *keys) {
    if (yv_l(yr_get(t, "k")) != K_trec) {
        return 0;
    } else {
        Yv *fs = yr_get(t, "fields");
        Yv *distinct = yav(0);
        int ok = 1;
        long i = 0;
        while (i < yv_len(keys)) {
            Yv *key = ya_get(keys, i);
            if (!str_in(distinct, key)) {
                distinct = ya_push(distinct, key);
            }
            if (field_pos(fs, key, 0) < 0) {
                ok = 0;
            }
            i = i + 1;
        }
        return ok && yv_len(distinct) == yv_len(fs);
    }
}

// A record literal checked against the record type target (lit_target):
// each value against its field's type (typeof_want); an optional field's
// against T when it is a plain T (opt_wraps). Its type is target.
static Yv *typeof_lit(Yv *st, Yv *node, Yv *target) {
    Yv *tu = unfold(target);
    Yv *keys = yr_get(node, "keys");
    Yv *vals = yr_get(node, "vals");
    long i = 0;
    while (i < yv_len(keys)) {
        Yv *key = ya_get(keys, i);
        Yv *ft = trec_field_type(tu, key);
        Yv *what = ys_cat(ys_cat(ys("record field '"), key), ys("'"));
        if (field_opt(tu, key) && yv_l(yr_get(ft, "k")) == K_topt) {
            Yv *inner = yr_get(ft, "of");
            Yv *r = typeof_want(st, ya_get(vals, i), inner);
            if (opt_wraps(yr_get(r, "typ"), ft)) {
                st = expect_type(yr_get(r, "st"), yr_get(r, "typ"), inner, what,
                                 yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
            } else {
                st = expect_type(yr_get(r, "st"), yr_get(r, "typ"), ft, what,
                                 yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
            }
        } else {
            Yv *r = typeof_want(st, ya_get(vals, i), ft);
            st = expect_type(yr_get(r, "st"), yr_get(r, "typ"), ft, what,
                             yv_l(yr_get(node, "line")), yv_l(yr_get(node, "col")));
        }
        i = i + 1;
    }
    return yr(2, "typ", target, "st", st);
}

static Yv *typeof_decl(Yv *st, Yv *node) {
    if (ys_eq_lit(yr_get(node, "kind"), "def")) {
        // named function: full check (signature + body)
        return typeof_def(st, yr_get(node, "name"), yr_get(node, "v"),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
    } else {
        // let/const. A literal def on the right names a function WITHOUT
        // going through typeof_expr (a bare func value is only legal bound).
        // Same for the `[v; n]` array literal (binds n frame slots).
        // A const binds as kind "const": const_check refuses to rebind it.
        Yv *bk = ys("local");
        if (ys_eq_lit(yr_get(node, "kind"), "const")) {
            bk = ys("const");
        }
        if (yv_l(yr_get(yr_get(node, "v"), "k")) == K_func) {
            Yv *fr = typeof_def(st, yr_get(node, "name"), yr_get(node, "v"),
                                yv_l(yr_get(node, "line")),
                                yv_l(yr_get(node, "col")));
            st = yr_get(fr, "st");
            if (yv_l(yr_get(yr_get(node, "typ"), "k")) != K_tnone) {
                st = expect_type(st, yr_get(fr, "typ"), yr_get(node, "typ"),
                                 ys_cat(ys_cat(ys("let '"),
                                               disp(yr_get(node, "name"))),
                                        ys("'")),
                                 yv_l(yr_get(node, "line")),
                                 yv_l(yr_get(node, "col")));
                ;
            }
            st = st_bind(st, yr_get(node, "name"), yr_get(fr, "typ"),
                         ys("func"));
            return yr(2, "typ", yr_get(fr, "typ"), "st", st);
        } else if (yv_l(yr_get(yr_get(node, "v"), "k")) == K_arrrep) {
            Yv *r = typeof_expr(st, yr_get(node, "v"));
            st = yr_get(r, "st");
            if (yv_l(yr_get(yr_get(r, "typ"), "k")) == K_tunk) {
                st = st_bind(st, yr_get(node, "name"), t_unk(), bk);
                return yr(2, "typ", t_unk(), "st", st);
            } else {
                Yv *at = yr_get(r, "typ");
                if (yv_l(yr_get(yr_get(node, "typ"), "k")) != K_tnone) {
                    if (arr_lit_adopts(yr_get(r, "typ"), yr_get(node, "typ"),
                                       yr_get(yr_get(node, "v"), "n"))) {
                        ;
                    } else {
                        st = expect_type(st, yr_get(r, "typ"),
                                         yr_get(node, "typ"),
                                         ys_cat(ys_cat(ys("let '"),
                                                       disp(yr_get(node, "name"))),
                                                ys("'")),
                                         yv_l(yr_get(node, "line")),
                                         yv_l(yr_get(node, "col")));
                        ;
                    }
                    at = yr_get(node, "typ");
                    ;
                }
                st = st_bind(st, yr_get(node, "name"), at, bk);
                return yr(2, "typ", at, "st", st);
            }
        } else {
            Yv *r = typeof_want(st, yr_get(node, "v"), yr_get(node, "typ"));
            st = yr_get(r, "st");
            Yv *t = yr_get(r, "typ");
            Yv *vk = yr_get(yr_get(node, "v"), "k");
            if (yv_l(yr_get(yr_get(node, "typ"), "k")) != K_tnone) {
                if (!is_value_type(yr_get(node, "typ"))) {
                    st = fail(st,
                              ys_cat(ys_cat(ys("annotation '"),
                                            tstr(yr_get(node, "typ"))),
                                     ys("' is not a native value type")),
                              yv_l(yr_get(node, "line")),
                              yv_l(yr_get(node, "col")));
                    ;
                } else if (yv_l(vk) == K_array) {
                    // An array LITERAL adopts the annotated element type:
                    // `let b: [byte] = [104, 105]` packs those elements
                    // into one byte each. Only literals — assigning an
                    // existing [long] to a [byte] binding would reinterpret
                    // eight-byte slots as one, so that still errors.
                    if (arr_lit_adopts(yr_get(r, "typ"), yr_get(node, "typ"),
                                       yv_long(yv_len(yr_get(yr_get(node, "v"), "elems"))))) {
                        ;
                    } else {
                        st = expect_type(st, yr_get(r, "typ"),
                                         yr_get(node, "typ"),
                                         ys_cat(ys_cat(ys("let '"),
                                                       disp(yr_get(node, "name"))),
                                                ys("'")),
                                         yv_l(yr_get(node, "line")),
                                         yv_l(yr_get(node, "col")));
                        ;
                    }
                    t = yr_get(node, "typ");
                    ;
                } else if (yv_l(vk) == K_rec && yv_len(yr_get(yr_get(node, "v"), "keys")) == 0 && yv_l(yr_get(yr_get(node, "typ"), "k")) == K_tmap) {
                    // The empty literal `{}` under a map annotation IS the
                    // map (the emitter lowers it to the {keys, vals, boxes}
                    // shape).
                    t = yr_get(node, "typ");
                    ;
                } else {
                    st = expect_cast(st, yr_get(r, "typ"), yr_get(node, "typ"),
                                     ys_cat(ys_cat(ys("let '"),
                                                   disp(yr_get(node, "name"))),
                                            ys("'")),
                                     yv_l(yr_get(node, "line")),
                                     yv_l(yr_get(node, "col")));
                    t = yr_get(node, "typ");
                    ;
                }
                ;
            }
            // NOTE: tnone/tname (unannotated initializer shapes) unify
            // quietly (tcompat law) — the missing annotation errors once at
            // its own site, not again at every enclosing let.
            if (yv_l(yr_get(t, "k")) == K_tnone) {
                t = t_unk();
                ;
            } else if (yv_l(yr_get(t, "k")) == K_tname) {
                t = t_unk();
                ;
            } else if (yv_l(yr_get(t, "k")) == K_tvoid) {
                st = fail(st,
                          ys_cat(ys_cat(ys("cannot bind a void value to '"),
                                        disp(yr_get(node, "name"))),
                                 ys("'")),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                t = t_unk();
                ;
            } else if (!is_value_type(t)) {
                st = fail(st,
                          ys_cat(ys_cat(ys("'"), tstr(t)),
                                 ys("' cannot be bound to a variable")),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                t = t_unk();
                ;
            } else if (has_free(t)) {
                st = fail(st,
                          ys_cat(ys_cat(ys("the type of '"),
                                        disp(yr_get(node, "name"))),
                                 ys("' is not fully known (annotate it)")),
                          yv_l(yr_get(node, "line")),
                          yv_l(yr_get(node, "col")));
                ;
            }
            st = st_bind(st, yr_get(node, "name"), t, bk);
            return yr(2, "typ", t, "st", st);
        }
    }
}

// A `return` in a def whose return type is still being inferred: its type
// and position go into the marker typeof_def put in st.ret (`rl`, a record
// shared by reference), to be checked once the body's type is known.
static long ret_note(Yv *rl, Yv *typ, long line, long col) {
    Yv *rets = yr_get(rl, "rets");
    ya_push(rets, yr(3, "typ", typ, "line", yv_long(line), "col", yv_long(col)));
    return 0;
}

// The return types typeof_def inferred, by the def's position: the
// emitter types calls, `self` and every `return` with them, as the checker
// did (native.c fn_ret), instead of re-inferring from the trailing
// expression alone (which cannot see the body's locals). They are not
// written into the def node: a node read through a cast from a union may
// be a copy (CHOICES_MADE.md 25), and lint reads the node for the types
// the program writes. 1024 buckets of indices into inf_keys/inf_typs
// (key: line * 65536 + col); check_program empties them.
static Yv *inf_keys;
static Yv *inf_typs;
static Yv *inf_bkts;

static void inf_reset(void) {
    Yv *bkts = yav(0);
    long i = 0;
    while (i < 1024) {
        bkts = ya_push(bkts, yav(0));
        i = i + 1;
    }
    inf_keys = yav(0);
    inf_typs = yav(0);
    inf_bkts = bkts;
}

static long set_inferred_ret(Yv *func, Yv *ret) {
    if (!inf_bkts || yv_len(inf_bkts) == 0) {
        inf_reset();
    }
    long key = yv_l(yr_get(func, "line")) * 65536 + yv_l(yr_get(func, "col"));
    Yv *bkt = ya_get(inf_bkts, key % 1024);
    inf_keys = ya_push(inf_keys, yv_long(key));
    inf_typs = ya_push(inf_typs, ret);
    ya_push(bkt, yv_long(yv_len(inf_keys) - 1));
    return 0;
}

// The return type inferred for the def at (line, col); tnone for none.
Yv *inferred_ret(long line, long col) {
    Yv *found = yr(1, "k", yv_long(K_tnone));
    if (inf_bkts && yv_len(inf_bkts) > 0) {
        long key = line * 65536 + col;
        Yv *bkt = ya_get(inf_bkts, key % 1024);
        long q = 0;
        while (q < yv_len(bkt)) {
            long ix = yv_l(ya_get(bkt, q));
            if (yv_l(ya_get(inf_keys, ix)) == key) {
                found = ya_get(inf_typs, ix);
            }
            q = q + 1;
        }
    }
    return found;
}

// Check a func value bound to `name` (def decl, let-bound anonymous def, or
// an anonymous literal). Returns { typ, st }: `typ` is the def's tfunc (with
// an inferred return filled in), and `name` ends up bound as kind "func".
static Yv *typeof_def(Yv *st, Yv *name, Yv *func, long line, long col) {
    if (yv_len(yr_get(func, "params")) != yv_len(yr_get(func, "ptypes"))) {
        st = fail(st, ys("internal: params/ptypes length mismatch"), line, col);
        return yr(2, "typ", t_unk(), "st", st);
    } else {
        Yv *args = yav(0);
        // NOTE: bound once (flow-snapshot: `params`/`ptypes` are bare node
        // fields; an inline `func.params[i]` would re-read the node through
        // whatever shape the env holds for `func`).
        Yv *fparams = yr_get(func, "params");
        Yv *fptypes = yr_get(func, "ptypes");
        long i = 0;
        int ok = 1;
        while (i < yv_len(fparams)) {
            Yv *pt = ya_get(fptypes, i);
            if (yv_l(yr_get(pt, "k")) == K_tnone) {
                // No value of unknown type: a parameter says its type.
                st = fail(st,
                          ys_cat(ys_cat(ys("parameter '"),
                                        disp(ya_get(fparams, i))),
                                 ys("' has no type (annotate it)")),
                          line, col);
                pt = t_unk();
                ;
            } else if (!is_value_type(pt) &&
                       yv_l(yr_get(pt, "k")) != K_tfunc) {
                st = fail(st,
                          ys_cat(ys_cat(ys_cat(ys_cat(ys("parameter '"),
                                                      disp(ya_get(fparams, i))),
                                                ys("' has unpassable type ")),
                                         tstr(pt)),
                                ys(" (a void value has no representation, and a type pattern cannot be passed by value)")),
                          line, col);
                ok = 0;
                ;
            }
            args = ya_push(args, pt);
            i = i + 1;
        }
        Yv *ret = yr_get(func, "ret");
        int ret_inferred = 0;
        // An inferred def's `return`s are checked once its type is known:
        // while the body is checked, st.ret is a marker that notes each one
        // (ret_note) in `rets`.
        Yv *rets = yav(0);
        Yv *body_ret = ret;
        if (yv_l(yr_get(ret, "k")) == K_tnone) {
            // The return type comes from the body's tail value once the
            // body has been checked; a call before then (the def calling
            // itself) needs it annotated (t_pend).
            ret_inferred = 1;
            ret = t_pend_self();
            body_ret = yr(2, "k", yv_long(K_tinfer), "rets", rets);
            ;
        }
        Yv *ft = yr(3, "k", yv_long(K_tfunc), "args", args, "ret", ret);
        // bind early so recursion via `self`/name works
        st = st_bind(st, name, ft, ys("func"));
        // check the body one level deeper. Outer locals/params stay in the
        // flat map (one shape per name), so a nested def reading one is a
        // capture — legal, and closure-converted by the emitter.
        Yv *saved_self = yr_get(st, "self");
        Yv *saved_ret = yr_get(st, "ret");
        long saved_depth = yv_l(yr_get(st, "fdepth"));
        st = st_fdepth(st, saved_depth + 1);
        long j = 0;
        while (j < yv_len(fparams)) {
            st = st_bind(st, ya_get(fparams, j), ya_get(args, j), ys("param"));
            j = j + 1;
        }
        st = st_self(st, ft);
        st = st_ret(st, body_ret);
        long nerr = yv_len(yr_get(st, "errors"));
        Yv *b = typeof_block_want(st, yr_get(func, "body"), body_ret);
        st = yr_get(b, "st");
        if (ret_inferred) {
            // INFERENCE: the def's return type is the body's tail value.
            // Unannotated sub-shapes (tnone) stay poison; tunk stays tunk.
            Yv *br = yr_get(b, "typ");
            if (yv_l(yr_get(br, "k")) == K_tnone) {
                br = t_unk();
                ;
            }
            // A trailing value of unknown type -- typically a self call,
            // whose type is the one being inferred -- leaves the type to the
            // first `return` that knows its own.
            Yv *rsrc = ys("the end of the body");
            long ri = 0;
            while (ri < yv_len(rets)) {
                Yv *rn = ya_get(rets, ri);
                Yv *rt = yr_get(rn, "typ");
                if (yv_l(yr_get(br, "k")) == K_tunk && yv_l(yr_get(rt, "k")) != K_tunk && yv_l(yr_get(rt, "k")) != K_tnone) {
                    br = rt;
                    rsrc = ys("the first 'return'");
                    ;
                }
                ri = ri + 1;
            }
            // Every `return` must conform to it, as to a written type.
            ri = 0;
            while (ri < yv_len(rets)) {
                Yv *rn = ya_get(rets, ri);
                if (!tcompat(yr_get(rn, "typ"), br)) {
                    st = fail(st,
                              ys_cat(ys_cat(ys_cat(ys_cat(ys_cat(ys_cat(ys("'return': expected "), tstr(br)),
                                                                 ys(", got ")),
                                                          tstr(yr_get(rn, "typ"))),
                                                   ys(" (the return type is inferred from ")),
                                            rsrc),
                                     ys(")")),
                              yv_l(yr_get(rn, "line")), yv_l(yr_get(rn, "col")));
                    ;
                }
                ri = ri + 1;
            }
            int used = yv_b(yr_get(ret, "used"));
            if ((has_free(br) || (used &&
                                  yv_l(yr_get(br, "k")) == K_tunk)) &&
                yv_len(yr_get(st, "errors")) == nerr) {
                st = fail(st,
                          ys_cat(ys_cat(ys("the return type of '"), disp(name)),
                                 ys("' is not fully known (annotate it)")),
                          line, col);
                br = t_unk();
                ;
            } else if (used && yv_l(yr_get(br, "k")) != K_tunk) {
                // The body calls the def itself, so it was checked with
                // that call's type unknown: check it again, the call now
                // typed br, its `return`s and tail as before (the first
                // pass's errors go; this one reports them).
                st = st_errors(st, ya_slice(yr_get(st, "errors"), 0, nerr));
                Yv *ft2 = yr(3, "k", yv_long(K_tfunc), "args", args, "ret", br);
                st = st_bind(st, name, ft2, ys("func"));
                st = st_self(st, ft2);
                Yv *rets2 = yav(0);
                st = st_ret(st, yr(2, "k", yv_long(K_tinfer), "rets", rets2));
                Yv *b2 = typeof_block_want(st, yr_get(func, "body"), br);
                st = yr_get(b2, "st");
                st = expect_type(st, yr_get(b2, "typ"), br,
                                 ys_cat(ys_cat(ys("'"), disp(name)), ys("' body")),
                                 line, col);
                long ri2 = 0;
                while (ri2 < yv_len(rets2)) {
                    Yv *rn2 = ya_get(rets2, ri2);
                    if (!tcompat(yr_get(rn2, "typ"), br)) {
                        st = fail(st,
                                  ys_cat(ys_cat(ys_cat(ys_cat(ys_cat(ys_cat(ys("'return': expected "), tstr(br)),
                                                                     ys(", got ")),
                                                              tstr(yr_get(rn2, "typ"))),
                                                       ys(" (the return type is inferred from ")),
                                                rsrc),
                                         ys(")")),
                                  yv_l(yr_get(rn2, "line")), yv_l(yr_get(rn2, "col")));
                        ;
                    }
                    ri2 = ri2 + 1;
                }
                ;
            }
            ft = yr(3, "k", yv_long(K_tfunc), "args", args, "ret", br);
            st = st_bind(st, name, ft, ys("func"));
            if (yv_l(yr_get(br, "k")) != K_tunk) {
                set_inferred_ret(func, br);
                ;
            }
            ;
        }
        if (!(ret_inferred)) {
            // `-> void` discards the body's tail value (no value returns)
            Yv *rtk = yr_get(ret, "k");
            if (yv_l(rtk) == K_tvoid) { ; } else {
                st = expect_cast(st, yr_get(b, "typ"), ret,
                                 ys_cat(ys_cat(ys("'"), disp(name)), ys("' body")),
                                 line, col);
                ;
            }
            ;
        }
        st = st_fdepth(st, saved_depth);
        st = st_self(st, saved_self);
        st = st_ret(st, saved_ret);
        if (ok) {
            return yr(2, "typ", ft, "st", st);
        } else {
            // poison the binding so follow-on errors don't cascade weirdly
            st = st_bind(st, name, t_unk(), ys("func"));
            return yr(2, "typ", t_unk(), "st", st);
        }
    }
}

static Yv *st_fdepth(Yv *st, long d) {
    return yr(5, "bindings", yr_get(st, "bindings"), "errors", yr_get(st, "errors"),
              "ret", yr_get(st, "ret"), "self", yr_get(st, "self"),
              "fdepth", yv_long(d));
}

// ── entry point ──────────────────────────────────────────────────────────

Yv *check_program(Yv *ast, Yv *ext) {
    // the inferred-return table is made when first written (inf_reset)
    inf_bkts = yav(0);
    tc_ixn = 0;
    // pass 1: collect top-level def signatures (allows mutual recursion).
    Yv *defs = yav(0);
    Yv *pstmts = yr_get(ast, "stmts");
    long i = 0;
    while (i < yv_len(pstmts)) {
        Yv *s = ya_get(pstmts, i);
        // NOTE: nested ifs, not `&&` (house style — the `s.v.k` read is
        // only reached once `s` is known to be a decl; `&&` would
        // short-circuit to the same place).
        if (yv_l(yr_get(s, "k")) == K_decl) {
            if (ys_eq_lit(yr_get(s, "kind"), "def")) {
                defs = ya_push(defs, def_sig(yr_get(s, "name"), yr_get(s, "v")));
                ;
            } else if (yv_l(yr_get(yr_get(s, "v"), "k")) == K_func) {
                // top-level let f = def... : also hoisted for mutual recursion
                defs = ya_push(defs, def_sig(yr_get(s, "name"), yr_get(s, "v")));
                ;
            }
            ;
        }
        i = i + 1;
    }
    // pass 2: check everything in order (depth 0 = top level)
    Yv *st = yr(5, "bindings", yav(0), "errors", yav(0), "ret",
                yr(1, "k", yv_long(K_tnone)), "self", yr(1, "k", yv_long(K_tnone)),
                "fdepth", yv_long(0));
    // top-level defs are visible at top level
    st = st_bind(st, ys("print"),
                 yr(3, "k", yv_long(K_tfunc), "args", yav(1, yr(1, "k", yv_long(K_tlong))),
                    "ret", yr(1, "k", yv_long(K_tvoid))),
                 ys("intrinsic"));
    st = st_bind(st, ys("syscall"), yr(1, "k", yv_long(K_tlong)), ys("intrinsic"));
    /* (name: str, args...) -> long. The binding exists only so `os_call` reads
       as defined when it appears as a value; typeof_call matches it by name and
       checks the arity and the argument types itself (os_call takes a varying
       number of arguments, so there is no single function type to bind). */
    st = st_bind(st, ys("os_call"), yr(1, "k", yv_long(K_tlong)), ys("intrinsic"));
    // Every intrinsic is matched BY NAME in typeof_call (print, len, some,
    // ... syscall), so these two bindings are never consulted by a call; they
    // exist only so `print`/`syscall` read as defined when they appear as
    // values (e.g. `let p = print;`).
    long x = 0;
    while (x < yv_len(ext)) {
        Yv *xe = ya_get(ext, x);
        Yv *kind = ys("func");
        if (ys_starts_with(yr_get(xe, "label"), ys("yg_"))) {
            kind = ys("const");
            ;
        }
        st = st_bind(st, yr_get(xe, "name"), yr_get(xe, "typ"), kind);
        x = x + 1;
    }
    long d = 0;
    while (d < yv_len(defs)) {
        st = st_bind(st, yr_get(ya_get(defs, d), "name"),
                     yr_get(ya_get(defs, d), "typ"), ys("func"));
        d = d + 1;
    }
    Yv *r = typeof_block(st, ast);
    return yr_get(yr_get(r, "st"), "errors");
}

static Yv *def_sig(Yv *name, Yv *func) {
    // Signature for the pre-pass. Missing annotations are poison (tunk);
    // pass 2 (typeof_def) reports each exactly once.
    Yv *args = yav(0);
    Yv *fpt = yr_get(func, "ptypes");
    long i = 0;
    while (i < yv_len(yr_get(func, "params"))) {
        Yv *pt = ya_get(fpt, i);
        if (yv_l(yr_get(pt, "k")) == K_tnone) {
            pt = t_unk();
        }
        args = ya_push(args, pt);
        i = i + 1;
    }
    Yv *ret = yr_get(func, "ret");
    if (yv_l(yr_get(ret, "k")) == K_tnone) {
        ret = t_pend();
    }
    return yr(3, "name", name, "opt", yv_bool(0),
              "typ", yr(3, "k", yv_long(K_tfunc), "args", args, "ret", ret));
}
