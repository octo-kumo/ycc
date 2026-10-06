// types.y — static type checker for the native backend.
// Usage: let errors = types.check_program(ast, ext);  // [] means OK
// (ext: the externs, see check_program; [] for a self-contained program)
// Each error: { msg: str, line: long, col: long }.
//
// Supported types: long, byte, float, bool, str, void, options T? (the
// empty case is `none`), *T (pointers), arrays [T] / [T; N], records
// {f: T}, maps {K => V}, unions A | B (every member a record) and
// (T, ...) -> R functions. Anything else is rejected with a clear error,
// not silently miscompiled.
//
// Rules (native mode):
// - def param and return annotations are OPTIONAL: a missing one is the
//   poison tunk (typeof_def), and a missing return is inferred from the
//   body's tail value.
// - let/const without annotation is inferred from the initializer.
// - A nested def may read an enclosing local/param: that is a CAPTURE, and
//   the emitter closure-converts it into a heap cell shared by the binding
//   and every closure over it (native.y box_capture), so a write inside is
//   visible outside.
// - `if` conditions must be bool. Matching arms keep their value type;
//   mismatched arms make the `if` void. An `if` without `else` is void.
// - print takes exactly one long/bool/float/str/array/record/map/option/
//   union/function. syscall takes 1-7 long/bool/str/*T.
// - Assignment targets keep their declared type. The only implicit
//   conversions are the numeric widenings (see tcompat).

// For its aliases Field, Node and Type.
import tags from "./tags.y";
import parser from "./parser.y";

// A diagnostic: the checker's errors, lint.y's warnings.
type Diag = { msg: str, line: long, col: long };
// A top-level function or global as other code sees it: its name, asm
// label and type (a unit's exports, the externs check_program binds,
// native.y's functions).
type Sym = { name: str, label: str, typ: Type };

def err_at(msg: str, line: long, col: long) -> Diag {
    { msg: msg, line: line, col: col }
};

// ── types ────────────────────────────────────────────────────────────────
// Type nodes come from the parser: tlong/tbool/tstr/tvoid/tnone/tname,
// tptr {to}, tarr {of}, tfunc {args, ret}, trec {fields: [{name, typ}]},
// tparams. Internal only: tunk (error poison, unifies with everything),
// trec (checked record type {fields: [{name, typ}]} — same shape as the
// parser's trec; teq compares the fields as a set, by name), tref (a
// recursive alias, rename.y: see "recursive types" below).

def t_unk() -> Type { { k: K.tunk } };

// The types of a mutex and a semaphore (CHOICES_MADE.md 33): records no
// program can spell (a `$` in each field's name), written `mutex` and
// `sem` (parser.y parse_type_atom2, whose sync_type must agree with this).
//
// A mutex is two words: its first is 1 while held (2 when a thread may be
// waiting for it -- see arch_x64.y y_mutex_lock), its second the pid holding
// it, 0 exactly when it is free. That pid is what makes a fork fail fast
// instead of hanging: a child inherits the held word and nobody in the child
// will release it, so waiting on it waits on a futex nobody wakes. A
// semaphore is its count, its own lock word, and that lock word's owner pid --
// three contiguous words, because the lock reads the owner at +8.
def t_mutex() -> Type {
    let fs: [Field] = [];
    fs += { name: "$m", opt: false, typ: { k: K.tlong } };
    fs += { name: "$o", opt: false, typ: { k: K.tlong } };
    let t: TRec = { k: K.trec, fields: fs };
    let r: Type = t;
    r
};

def t_sem() -> Type {
    let fs: [Field] = [];
    fs += { name: "$n", opt: false, typ: { k: K.tlong } };
    fs += { name: "$w", opt: false, typ: { k: K.tlong } };
    fs += { name: "$o", opt: false, typ: { k: K.tlong } };
    let t: TRec = { k: K.trec, fields: fs };
    let r: Type = t;
    r
};

// The parameter types of a function type.
def fn_args(t: Type) -> [Type] {
    let func: TFunc = t;
    func.args
};

def type_node(t: Type) -> Type { t };

// `[]` or `none` where no type is declared: the element or payload is not
// known, so it unifies like tunk, but a binding or an inferred return of a
// type with one inside needs an annotation (has_free) -- error poison
// (plain tunk) stays quiet.
def t_free() -> Type {
    let f: TFree = { k: K.tunk, free: true };
    f
};

// A def's return type before it is known: a call to it then (a forward
// call) needs the return type annotated.
def t_pend() -> Type {
    let p: TPend = { k: K.tpend, self: false, used: false };
    p
};

// The return type of a def while its body is checked to infer it: a call
// to the def from its own body gives an unknown and notes itself
// (call_result), and typeof_def checks the body again with the type the
// rest of the body gave.
def t_pend_self() -> Type {
    let p: TPend = { k: K.tpend, self: true, used: false };
    p
};

def has_free(t: Type) -> bool {
    let k: long = t.k;
    if (k == K.tunk) {
        match t { TFree { free: fr } => fr, _ => false }
    } else if (k == K.tarr || k == K.topt) {
        let o: TOf = t;
        self(o.of)
    } else if (k == K.tarrfix) {
        let o: TFix = t;
        self(o.of)
    } else if (k == K.tptr) {
        let p: TPtr = t;
        self(p.to)
    } else if (k == K.tmap) {
        let m: TMap = t;
        self(m.key) || self(m.of)
    } else if (k == K.trec) {
        let r: TRec = t;
        let fs: [Field] = r.fields;
        let found = false;
        let i = 0;
        while (!found && i < len(fs)) {
            let f = fs[i];
            if (self(f.typ)) { found = true; };
            i = i + 1;
        };
        found
    } else if (k == K.tunion) {
        let u: TList = t;
        let ts: [Type] = u.ts;
        let found = false;
        let i = 0;
        while (!found && i < len(ts)) {
            if (self(ts[i])) { found = true; };
            i = i + 1;
        };
        found
    } else if (k == K.tfunc) {
        let ftype: TFunc = t;
        let as: [Type] = ftype.args;
        let found = false;
        let i = 0;
        while (!found && i < len(as)) {
            if (self(as[i])) { found = true; };
            i = i + 1;
        };
        found || self(ftype.ret)
    } else { false }
};

// A function type whose return type is not known yet (t_pend), and not
// the def being inferred (t_pend_self) calling itself.
def ret_pending(t: Type) -> bool {
    if (t.k != K.tfunc) { false } else {
        let ftype: TFunc = t;
        let r = ftype.ret;
        if (r.k != K.tpend) { false } else {
            let p: TPend = r;
            !p.self
        }
    }
};

// A function type whose return type is not known yet, the def being
// inferred included: its name (or `self`) used as a value.
def ret_unknown(t: Type) -> bool {
    if (t.k != K.tfunc) { false } else {
        let ftype: TFunc = t;
        let r = ftype.ret;
        r.k == K.tpend
    }
};

// The type of a call to ft: its return type; a def calling itself while
// its return type is inferred gets an unknown, and the def is checked
// again (typeof_def).
def call_result(ft: TFunc) -> Type {
    let r = ft.ret;
    if (r.k == K.tpend) {
        let p: TPend = r;
        p.used = true;
        t_unk()
    } else { r }
};

// A map type node ({K => V}). Returns through a {k: long} annotation so
// the value's flow type is the unknown-shape marker: typeof_expr's if
// arms only agree through such holes (see teq note), and a concrete
// {k, key, of} shape here would disagree with the rec arm's {k, fields}.
def map_type_of(v: Type) -> Type {
    { k: K.tmap, key: { k: K.tstr }, of: v }
};

def teq(a: Type, b: Type) -> bool {
    // NOTE: no `||` (see lexer.y isalnum note): the C VM evaluates both sides
    // eagerly AND the checker rejects `||` mixing map-field shapes with bools
    // through one gate — and teq's OWN first line was the worst offender
    // (a.k/t.k field reads poisoned through `||`). Nested ifs everywhere.
    // NOTE: bind kind tags with :str (see gen_bin note in native.y):
    // `a.k`/`b.k` infer tunk (bare params), which would make `!=` below
    // compare string POINTERS; annotated lets force content comparison.
    // Sound: kind tags are always strings (parser + checker construct
    // every type node with a string k).
    // The same type node (a recursive alias is one shared node, and unfolds
    // to one union every time): equal, without spelling out canonical forms
    // or comparing a big union member by member.
    if (a == b) { return true; };
    let ak: long = a.k;
    let bk: long = b.k;
    if (ak == K.tunk) { true }
    else if (bk == K.tunk) { true }
    else if (ak != bk) {
        if (ak == K.tref || bk == K.tref) { teq_ref(a, b) } else { false }
    }
    else if (ak == K.tnone) { true }
    else if (bk == K.tnone) { true }
    else if (ak == K.tname) { true }
    else if (bk == K.tname) { true }
    else if (ak == K.tparams) { true }
    else if (bk == K.tparams) { true }
    else if (ak == K.tptr) {
        let ap: TPtr = a;
        let bp: TPtr = b;
        teq(ap.to, bp.to)
    }
    else if (ak == K.tarr) {
        let aa: TOf = a;
        let ba: TOf = b;
        teq(aa.of, ba.of)
    }
    else if (ak == K.tarrfix) {
        let aa: TFix = a;
        let ba: TFix = b;
        if (aa.n == ba.n) { teq(aa.of, ba.of) } else { false }
    } else if (ak == K.tmap) {
        // map types: same key type, equal value types.
        let am: TMap = a;
        let bm: TMap = b;
        if (teq(am.key, bm.key)) { teq(am.of, bm.of) } else { false }
    } else if (ak == K.topt) {
        let ao: TOf = a;
        let bo: TOf = b;
        teq(ao.of, bo.of)
    }
    else if (a.k == K.trec) {
        // record types: the same set of fields with pairwise-equal types;
        // the order they are written in is not part of the type (a record
        // is laid out by field name, NATIVE.md "Records"). tunk fields
        // unify -- error poison never cascades.
        // NOTE: each bound once — the checker env is flow-INSENSITIVE (one
        // shape per name, last wins), so a name read inline here would merge
        // the `fields` shape of a, b and every other arm in teq.
        let ar: TRec = a;
        let br: TRec = b;
        let af: [Field] = ar.fields;
        let bf: [Field] = br.fields;
        if (len(af) != len(bf)) { false }
        else { teq_fields(af, bf, 0) }
    } else if (ak == K.tfunc) {
        let afunc: TFunc = a;
        let bfunc: TFunc = b;
        if (len(afunc.args) != len(bfunc.args)) { false } else {
            let ok = teq(afunc.ret, bfunc.ret);
            let aa: [Type] = afunc.args;
            let bb: [Type] = bfunc.args;
            let i = 0;
            while (ok) {
                if (i < len(aa)) {
                    ok = teq(aa[i], bb[i]);
                    i = i + 1;
                } else { ok = false; };
            };
            teq_list(aa, bb, 0)
        }
    } else if (ak == K.tunion) {
        // unions: the same members, in any order
        let ua = union_parts(a);
        let ub = union_parts(b);
        if (len(ua) != len(ub)) { false }
        else if (teq_members(ua, ub, 0)) { teq_members(ub, ua, 0) }
        else { false }
    } else if (ak == K.tref) { teq_ref(a, b) }
    else { true }
};

// ── recursive types and canonical forms ──────────────────────────────────
// A recursive alias reaches the checker spelled out once, its references
// back to itself trefs ({k: K.tref, name, tmp, to}, rename.y RnRef): `to`
// is the alias spelled out, `tmp` names the alias within the unit. Where a
// type is looked into, a tref is unfolded first: typeof_expr's results,
// tcompat's sides, a union's members (members).

// t, or the type a tref stands for.
def unfold(t: Type) -> Type {
    if (t.k == K.tref) {
        let ref: TRef = t;
        ref.to
    } else { t }
};

// A union's members as written -- a recursive alias that is a member
// stays its tref (its canonical form names the member, native.y ty_desc)
// -- with an alias of a union among them flattened in.
def union_parts(t: Type) -> [Type] {
    let out: [Type] = [];
    union_parts_go(out, t, 0);
    out
};

def union_parts_go(out: [Type], t: Type, depth: long) -> long {
    let union: TList = t;
    let ms: [Type] = union.ts;
    let i = 0;
    while (i < len(ms)) {
        let m = ms[i];
        let u = unfold(m);
        if (u.k == K.tunion && depth < 16) { union_parts_go(out, u, depth + 1); } else { out += m; };
        i = i + 1;
    };
    0
};

// A union's members, unfolded (union_parts).
def members(t: Type) -> [Type] {
    let ps = union_parts(t);
    let out: [Type] = [];
    let i = 0;
    while (i < len(ps)) {
        out += unfold(ps[i]);
        i = i + 1;
    };
    out
};

// The members of union s, as written, with every field of the record
// pattern t.
def pat_members(s: Type, t: Type) -> [Type] {
    let ps = union_parts(s);
    let pat: TPat = t;
    let names: [str] = pat.names;
    let out: [Type] = [];
    let i = 0;
    while (i < len(ps)) {
        if (rec_has_names(unfold(ps[i]), names)) { out += ps[i]; }
        i = i + 1;
    };
    out
};

// teq with a recursive alias on a side: two trefs are equal when their
// canonical forms are; a tref against a type written out (a literal of a
// recursive record type, say) is unfolded, at most 64 levels deep.
let teq_unfolds = 0;
// Two recursive aliases whose types visibly differ -- other kinds, or
// records of other field names -- have other canonical forms: teq_ref
// answers without spelling them out (long, for a big recursive union).
def ref_shapes_differ(a: Type, b: Type) -> bool {
    let ua = unfold(a);
    let ub = unfold(b);
    let uak: long = ua.k;
    let ubk: long = ub.k;
    if (uak != ubk) { true }
    else if (uak == K.trec) {
        let rb: TRec = ub;
        !same_names(ua, rec_names(rb.fields))
    } else { false }
};

def teq_ref(a: Type, b: Type) -> bool {
    let ak: long = a.k;
    let bk: long = b.k;
    if (ak == K.tref && bk == K.tref) {
        if (ref_shapes_differ(a, b)) { false } else { tcanon(a) == tcanon(b) }
    }
    else if (teq_unfolds >= 64) { false }
    else {
        teq_unfolds = teq_unfolds + 1;
        let r = teq(unfold(a), unfold(b));
        teq_unfolds = teq_unfolds - 1;
        r
    }
};

// xs sorted (insertion sort: field lists are short).
def str_sorted(xs: [str]) -> [str] {
    let out: [str] = [];
    let i = 0;
    while (i < len(xs)) {
        let x: str = xs[i];
        out += x;
        let j = len(out) - 1;
        while (j > 0 && x < out[j - 1]) {
            out[j] = out[j - 1];
            j = j - 1;
        };
        out[j] = x;
        i = i + 1;
    };
    out
};

// The field names of a record type's field list, sorted: its layout
// (native.y "records at run time").
def rec_names(fs: [Field]) -> [str] {
    let names: [str] = [];
    let i = 0;
    while (i < len(fs)) {
        let f = fs[i];
        names += f.name;
        i = i + 1;
    };
    str_sorted(names)
};

// The canonical form of a type (native.y names record descriptors by its
// hash; teq_ref compares recursive aliases by it): equal types give equal
// strings, record fields and union members in any order. What is unknown
// to the checker (tunk, a missing annotation, an unresolved name) is "u".
// A tref is spelled out where it is met first; inside, a reference back
// to it is `^N`, N counting the trefs entered since.
def tcanon(t: Type) -> str {
    let out: [str] = [];
    let none: [str] = [];
    out = tcanon_go(out, t, none);
    join(out, "")
};

// A type's signature (native.y ty_desc's key): its canonical form with each
// recursive alias written as its name in the unit (the tref's tmp) instead
// of spelled out -- short where a canonical form spells out a whole
// recursive union. Within one unit, equal signatures are one type.
let tcanon_named = false;
def tsig(t: Type) -> str {
    tcanon_named = true;
    let s = tcanon(t);
    tcanon_named = false;
    s
};

def tcanon_go(out: [str], t: Type, stack: [str]) -> [str] {
    let k: long = t.k;
    if (k == K.tlong) { out += "l"; out }
    else if (k == K.tbyte) { out += "b"; out }
    else if (k == K.tfloat) { out += "f"; out }
    else if (k == K.tbool) { out += "o"; out }
    else if (k == K.tstr) { out += "s"; out }
    else if (k == K.tvoid) { out += "v"; out }
    else if (k == K.tptr) {
        let ptr: TPtr = t;
        out += "*";
        tcanon_go(out, ptr.to, stack)
    }
    else if (k == K.tarr) {
        let arr: TOf = t;
        out += "[";
        tcanon_go(out, arr.of, stack)
    }
    else if (k == K.tarrfix) {
        let arr: TFix = t;
        out += "F" + tostring(arr.n) + ";";
        tcanon_go(out, arr.of, stack)
    }
    else if (k == K.topt) {
        let opt: TOf = t;
        out += "?";
        tcanon_go(out, opt.of, stack)
    }
    else if (k == K.tmap) {
        let map: TMap = t;
        out += "M";
        out = tcanon_go(out, map.key, stack);
        tcanon_go(out, map.of, stack)
    } else if (k == K.tfunc) {
        let func: TFunc = t;
        let args: [Type] = func.args;
        out += "(";
        let i = 0;
        while (i < len(args)) {
            out = tcanon_go(out, args[i], stack);
            out += ",";
            i = i + 1;
        };
        out += ")";
        tcanon_go(out, func.ret, stack)
    } else if (k == K.trec) {
        let rec: TRec = t;
        let fs: [Field] = rec.fields;
        let names = rec_names(fs);
        out += "{";
        let i = 0;
        while (i < len(names)) {
            let nm: str = names[i];
            let f = fs[field_pos(fs, nm, 0)];
            out += nm + ":";
            out = tcanon_go(out, f.typ, stack);
            out += ",";
            i = i + 1;
        };
        out += "}";
        out
    } else if (k == K.tunion) {
        let union: TList = t;
        let ms = union_parts(union);
        let forms: [str] = [];
        let i = 0;
        while (i < len(ms)) {
            let mout: [str] = [];
            let mf = join(tcanon_go(mout, ms[i], stack), "");
            if (!str_in(forms, mf)) { forms += mf; }
            i = i + 1;
        };
        out += "<" + join(str_sorted(forms), "|") + ">";
        out
    } else if (k == K.tref) {
        let ref: TRef = t;
        let tmp: str = ref.tmp;
        let d = -1;
        let i = len(stack) - 1;
        while (d < 0 && i >= 0) {
            let si: str = stack[i];
            if (si == tmp) { d = len(stack) - 1 - i; }
            i = i - 1;
        };
        if (tcanon_named) {
            out += "@" + tmp;
            out
        } else if (d >= 0) {
            out += "^" + tostring(d);
            out
        } else {
            let inner: [str] = [];
            inner += stack;
            inner += tmp;
            tcanon_go(out, ref.to, inner)
        }
    } else { out += "u"; out }
};

// s is one of xs.
def str_in(xs: [str], s: str) -> bool {
    let found = false;
    let i = 0;
    while (!found && i < len(xs)) {
        let x: str = xs[i];
        if (x == s) { found = true; }
        i = i + 1;
    };
    found
};

// Every field of af is in bf (by name) with an equal type: with the same
// count on both sides (teq checks it), the two are one set of fields.
// Index recursion (not a loop) so the shape stays checker-clean and
// out-of-range reads impossible.
def teq_fields(af: [Field], bf: [Field], i: long) -> bool {
    if (i >= len(af)) { true }
    else {
        let fa = af[i];
        // NOTE: :str binding (see teq note): fa flows from bare params
        // (tunk), so a direct `==` would compare string POINTERS.
        let an: str = fa.name;
        let j = field_pos(bf, an, i);
        if (j < 0) { false }
        else {
            let fb = bf[j];
            if (teq(fa.typ, fb.typ)) { teq_fields(af, bf, i + 1) } else { false }
        }
    }
};

// The index of the field named `name` in the field list fs, -1 when there
// is none. `hint` is tried first: records written in the same order find
// every field there.
def field_pos(fs: [Field], name: str, hint: long) -> long {
    let found = -1;
    if (hint < len(fs)) {
        let fh = fs[hint];
        let hn: str = fh.name;
        if (hn == name) { found = hint; }
    }
    let i = 0;
    while (found < 0 && i < len(fs)) {
        let f = fs[i];
        let fnm: str = f.name;
        if (fnm == name) { found = i; }
        i = i + 1;
    };
    found
};

// Every member of ua has an equal member in ub.
def teq_members(ua: [Type], ub: [Type], i: long) -> bool {
    if (i >= len(ua)) { true }
    else {
        let found = false;
        let j = 0;
        while (!found && j < len(ub)) {
            if (teq(ua[i], ub[j])) { found = true; }
            j = j + 1;
        };
        if (found) { teq_members(ua, ub, i + 1) } else { false }
    }
};

def teq_list(aa: [Type], bb: [Type], i: long) -> bool {
    if (i >= len(aa)) { true }
    else if (teq(aa[i], bb[i])) { teq_list(aa, bb, i + 1) }
    else { false }
};

// Field type by name in a trec; tnone marker when missing (dotassign uses
// it — the caller reports the error once at the assignment site).
def trec_field_type(rec: Type, key: str) -> Type {
    let found: Type = { k: K.tnone };
    if (rec.k == K.trec) {
        let record: TRec = rec;
        let fs: [Field] = record.fields;
        let i = 0;
        while (i < len(fs)) {
            let f = fs[i];
            if (f.name == key) {
                found = f.typ;
            }
            i = i + 1;
        };
    };
    found
};

// The one spelling of a type. Every diagnostic prints it, and so does
// `typeof`, a printed function value (`<function (long) -> long>`) and the
// `<...>` a recursive type prints as its own placeholder: a program can read a
// type out of an error message and type it back, and `typeof(x)` gives text
// the compiler itself would print. There used to be a second renderer, tdisp,
// with tighter spacing (`(long)->long`, `{a: long}`), used only by those four
// emitter sites; one type had two spellings and only one of them was in the
// diagnostics.
def tstr_go(t: Type) -> str {
    if (t.k == K.tlong) { "long" }
    else if (t.k == K.tbyte) { "byte" }
    else if (t.k == K.tfloat) { "float" }
    else if (t.k == K.tbool) { "bool" }
    else if (t.k == K.tstr) { "str" }
    else if (t.k == K.tvoid) { "void" }
    else if (t.k == K.tunk) { "<error>" }
    else if (t.k == K.tnone) { "<missing annotation>" }
    else if (t.k == K.tname) { let name: TName = t; name.name }
    else if (t.k == K.tref) { let ref: TRef = t; ref.name }
    else if (t.k == K.tunion) { let union: TList = t; tstr_union(union.ts, " | ") }
    else if (t.k == K.tpat) { let pat: TPat = t; let tn: [str] = pat.names; "{ " + join(tn, ", ") + " }" }
    else if (t.k == K.tptr) { let ptr: TPtr = t; "*" + tstr_go(ptr.to) }
    else if (t.k == K.tarr) { let arr: TOf = t; "[" + tstr_go(arr.of) + "]" }
    else if (t.k == K.tarrfix) { let arr: TFix = t; "[" + tstr_go(arr.of) + "; " + tostring(arr.n) + "]" }
    else if (t.k == K.topt) {
        // `none` alone is the option of nothing-known-yet
        let opt: TOf = t;
        let tof = opt.of;
        if (tof.k == K.tunk) { "none" } else { tstr_go(tof) + "?" }
    }
    else if (t.k == K.tmap) { let map: TMap = t; "{" + tstr_go(map.key) + " => " + tstr_go(map.of) + "}" }
    else if (t.k == K.trec && teq(t, t_mutex())) { "mutex" }
    else if (t.k == K.trec && teq(t, t_sem())) { "sem" }
    else if (t.k == K.trec) {
        let parts: [str] = [];
        let rec: TRec = t;
        let fs: [Field] = rec.fields;
        let i = 0;
        while (i < len(fs)) {
            // NOTE: bound once — `fields` is a bare param here, so an inline
            // `fs[i]` would merge shapes across arms (see teq note).
            let f = fs[i];
            let fname: str = f.name;
            let ft: Type = f.typ;
            if (f.opt && ft.k == K.topt) {
                let fo: TOf = ft;
                parts += fname + "?: " + tstr_go(fo.of);
            } else { parts += fname + ": " + tstr_go(ft); };
            i = i + 1;
        };
        "{ " + join(parts, ", ") + " }"
    }
    else if (t.k == K.tfunc) {
        let parts: [str] = [];
        let func: TFunc = t;
        let ta: [Type] = func.args;
        let i = 0;
        while (i < len(ta)) {
            parts += tstr_go(ta[i]);
            i = i + 1;
        };
        "(" + join(parts, ", ") + ") -> " + tstr_go(func.ret)
    } else { "<" + ktag(t.k) + ">" }
};

def tstr(t: Type) -> str { tstr_go(t) };

def tstr_union(ts: [Type], sep: str) -> str {
    let parts: [str] = [];
    let i = 0;
    while (i < len(ts)) {
        parts += tstr_go(ts[i]);
        i = i + 1;
    };
    join(parts, sep)
};

// ── unions and match ─────────────────────────────────────────────────────
// A union `A | B` holds a record whose type is exactly one of its members.
// Every record carries its type's descriptor (native.y "records at run
// time"), so a match tells the member a value holds by comparing that, a
// compare per member (the first matching arm wins).

// The field names a match pattern tests: a record type's, or a record
// pattern's (tpat).
def type_names(t: Type) -> [str] {
    let out: [str] = [];
    let tk: long = t.k;
    if (tk == K.trec) {
        let rec: TRec = t;
        let fs: [Field] = rec.fields;
        let i = 0;
        while (i < len(fs)) {
            let f = fs[i];
            out += f.name;
            i = i + 1;
        };
    } else if (tk == K.tpat) {
        let pat: TPat = t;
        let ns: [str] = pat.names;
        out += ns;
    }
    out
};

def rec_has_names(r: Type, names: [str]) -> bool {
    let rk: long = r.k;
    if (rk != K.trec) { false } else {
        let have = type_names(r);
        let ok = true;
        let i = 0;
        while (i < len(names)) {
            let nm: str = names[i];
            let found = false;
            let j = 0;
            while (j < len(have)) {
                let hn: str = have[j];
                if (hn == nm) { found = true; }
                j = j + 1;
            };
            if (!found) { ok = false; }
            i = i + 1;
        };
        ok
    }
};

// The static type of `narrow(e, t)`: t itself for a record type; for a
// record pattern (tpat), the member of the subject's union that has those
// fields, or the union of the members that have them when there are
// several (the subject itself when it is a record). tunk when none.
def narrow_type(s: Type, t: Type) -> Type {
    let tk: long = t.k;
    let sk: long = s.k;
    if (tk != K.tpat) { t }
    else if (sk == K.trec) {
        let pat: TPat = t;
        if (rec_has_names(s, pat.names)) { s } else { t_unk() }
    } else if (sk == K.tunion) {
        let ms = members(s);
        let pat: TPat = t;
        let names: [str] = pat.names;
        let found: [Type] = [];
        let i = 0;
        while (i < len(ms)) {
            if (rec_has_names(ms[i], names)) { found += ms[i]; }
            i = i + 1;
        };
        if (len(found) == 0) { t_unk() }
        else if (len(found) == 1) { found[0] }
        else {
            let union: Type = { k: K.tunion, ts: found };
            union
        }
    } else { t_unk() }
};

// The member of union u that is the record type t (as u writes it,
// union_parts); tnone when there is none.
def union_member(u: Type, t: Type) -> Type {
    let ms = union_parts(u);
    let found: Type = { k: K.tnone };
    let i = len(ms) - 1;
    while (i >= 0) {
        if (teq(ms[i], t)) { found = ms[i]; }
        i = i - 1;
    };
    found
};

// `u.f` on a union: every member has f, with one type -- a field they do
// not share is read after a match.
def union_field(st: TcSt, t: Type, dkey: str, line: long, col: long) -> TcRes {
    let ms = members(t);
    let ft = t_unk();
    let ok = true;
    let i = 0;
    while (i < len(ms) && ok) {
        let mt = trec_field_type(ms[i], dkey);
        if (mt.k == K.tnone) {
            st = fail(st, "member " + tstr(ms[i]) + " of " + tstr(t) + " has no field '" + dkey + "' (match the member first)", line, col);
            ok = false;
        } else if (i == 0) {
            ft = mt;
        } else if (!teq(ft, mt)) {
            st = fail(st, "field '" + dkey + "' has a different type in each member of " + tstr(t) + " (match the member first)", line, col);
            ok = false;
        }
        i = i + 1;
    };
    if (ok) { { typ: ft, st: st } } else { { typ: t_unk(), st: st } }
};

// `u.f = v` on a union: f as a read finds it (union_field), then v must
// fit it.
def dotassign_union(st: TcSt, t: Type, node: DotAssign) -> TcRes {
    let key: str = node.key;
    let fr = union_field(st, t, key, node.line, node.col);
    st = fr.st;
    let v = typeof_want(st, node.v, fr.typ);
    st = expect_type(v.st, v.typ, fr.typ, "record field '" + key + "'", node.line, node.col);
    { typ: fr.typ, st: st }
};

// Every member of a union must be a record type (they are told apart by
// their field names).
def union_ok(t: Type) -> bool {
    let ms = members(t);
    let ok = true;
    let i = 0;
    while (i < len(ms)) {
        let m = ms[i];
        let mk: long = m.k;
        if (mk != K.trec) { ok = false; }
        i = i + 1;
    };
    ok
};

// got flows into the union want: a member does (a record equal to some
// member: membership is exact, `{a: 1, b: 2}` is no `{a: long}`), and so
// does a union whose every member does.
def union_accepts(got: Type, want: Type) -> bool {
    let gk: long = got.k;
    if (gk == K.tunion) {
        let gs = members(got);
        let ok = true;
        let i = 0;
        while (i < len(gs)) {
            if (!union_accepts(gs[i], want)) { ok = false; }
            i = i + 1;
        };
        ok
    } else {
        let ws = members(want);
        let any = false;
        let j = 0;
        while (j < len(ws)) {
            if (tcompat(got, ws[j])) { any = true; }
            j = j + 1;
        };
        any
    }
};

// A float literal's net power of ten: the explicit exponent minus the digits
// after the dot, clamped so a long digit run cannot wrap. |dp| past 100000 is
// nobody's magnitude -- a double holds 10^-308 to 10^308 -- and the conversion
// used to emit megabytes of mul/div for such a literal (1e10000000 killed the
// compiler), so the checker rejects it. A literal merely past the range is not
// an error: 1e400 and 1e40000 are inf, as IEEE says (t171). (native.y keeps its
// own copy of this scan -- the two modules never share helpers.)
def num_net_exp(s: str) -> long {
    let dot = index_of(s, ".");
    let eb = index_of(s, "e");
    if (eb < 0) { eb = index_of(s, "E"); };
    if (eb < 0) { eb = len(s); };
    let nfrac = 0;
    if (dot >= 0) { nfrac = eb - dot - 1; };
    let ex = 0;
    if (eb < len(s)) {
        let i = eb + 1;
        let neg = false;
        let sc = s[i:i + 1];
        if (sc == "-") { neg = true; i = i + 1; };
        if (sc == "+") { i = i + 1; };
        let past = false;
        while (i < len(s)) {
            if (!past) {
                ex = ex * 10 + (byte_at(s[i:i + 1], 0) - 48);
                if (ex > 100001) { past = true; ex = 100002; };
            };
            i = i + 1;
        };
        if (neg) { ex = 0 - ex; };
    };
    ex - nfrac
};

// A numeric literal denotes a float when it has a fraction or an exponent.
// Radix literals are checked first: 0xE1 and 0xbeef contain 'e'/'E'/'b'.
// (native.y keeps its own copy — the two modules never share helpers.)
def num_is_float(s: str) -> bool {
    let radix = false;
    if (len(s) > 2) {
        let p = s[0:2];
        if (p == "0x") { radix = true; }
        if (p == "0X") { radix = true; }
        if (p == "0b") { radix = true; }
        if (p == "0B") { radix = true; }
    }
    if (radix) { false } else {
        let f = false;
        if (index_of(s, ".") >= 0) { f = true; }
        if (index_of(s, "e") >= 0) { f = true; }
        if (index_of(s, "E") >= 0) { f = true; }
        f
    }
};

// Merge one field into a record literal's field list, in place: the array is
// the caller's (every call site assigns the result straight back) and Y arrays
// are references. A name the list does not have yet -- all but a repeated key
// or a spread that overlaps one -- is an append, O(1). Rebuilding the array
// per field was quadratic in the literal's field count in *copies*: 722 MB at
// 4 000 fields, every field copied once per field after it.
def field_merge(fields: [Field], name: str, typ: Type) -> [Field] {
    let i = 0;
    while (i < len(fields)) {
        if (fields[i].name == name) { return field_merge_dup(fields, name, typ); };
        i = i + 1;
    };
    fields += { name: name, opt: false, typ: typ };
    fields
};

// A later entry wins the value (and its type); the first appearance keeps the
// position. That is the static union rule for `{a: 1, ...obj}`: obj may
// overwrite a, and a later explicit key may overwrite what obj spread. The
// list is copied here because Y cannot remove an array element, so the later
// appearances of the name have to go -- rare enough that the copy is worth it.
def field_merge_dup(fields: [Field], name: str, typ: Type) -> [Field] {
    let out: [Field] = [];
    let i = 0;
    let seen = false;
    while (i < len(fields)) {
        let f = fields[i];
        let fnm: str = f.name;
        if (fnm == name) {
            if (seen) {
            } else {
                out += { name: name, opt: false, typ: typ };
                seen = true;
            };
        } else {
            out += f;
        };
        i = i + 1;
    };
    if (seen) {
    } else {
        out += { name: name, opt: false, typ: typ };
    };
    out
};

// Does this type carry an error that has already been reported, at any depth?
// `tunk` is the poison a failed check leaves behind, and it unifies with
// everything through teq. A container of it -- the type of `[[zzz]]` after zzz
// was reported undefined -- has to as well, or the enclosing literal reports
// the same failure a second time under a worse name ("expected [<error>]").
// tname/tnone/tparams already unify quietly in tcompat and are not poison.
def t_poisoned(t: Type) -> bool { t_poisoned_go(t, 0) };

def t_poisoned_go(t: Type, d: long) -> bool {
    if (t.k == K.tunk) { true }
    else if (d >= 16) { false }
    else if (t.k == K.tarr) { let a: TOf = t; t_poisoned_go(a.of, d + 1) }
    else if (t.k == K.tarrfix) { let a: TFix = t; t_poisoned_go(a.of, d + 1) }
    else if (t.k == K.topt) { let a: TOf = t; t_poisoned_go(a.of, d + 1) }
    else if (t.k == K.tmap) {
        let m: TMap = t;
        if (t_poisoned_go(m.key, d + 1)) { true } else { t_poisoned_go(m.of, d + 1) }
    }
    else { false }
};

def is_value_type(t: Type) -> bool {
    if (t.k == K.tlong) { true }
    else if (t.k == K.tbyte) { true }
    else if (t.k == K.tfloat) { true }
    else if (t.k == K.tbool) { true }
    else if (t.k == K.tstr) { true }
    else if (t.k == K.tptr) { true }
    else if (t.k == K.tunk) { true }
    else if (t.k == K.tnone) { true }
    else if (t.k == K.tname) { true }
    else if (t.k == K.tparams) { true }
    else if (t.k == K.tfunc) { true }
    else if (t.k == K.tarr) { true }
    else if (t.k == K.tarrfix) { true }
    else if (t.k == K.topt) { true }
    else if (t.k == K.tmap) { let map: TMap = t; is_hash_key(map.key) }
    else if (t.k == K.tunion) { union_ok(t) }
    else if (t.k == K.tref) { true }
    else { t.k == K.trec }
};

// Map keys must be hashable scalars: str, long, byte, bool, float.
def is_hash_key(t: Type) -> bool {
    if (t.k == K.tstr) { true }
    else if (t.k == K.tlong) { true }
    else if (t.k == K.tbyte) { true }
    else if (t.k == K.tbool) { true }
    else { t.k == K.tfloat }
};

// ── checker state ────────────────────────────────────────────────────────
// No scopes: rename.y gave every binding a unique name, so one flat list
// suffices. bindings = [{name, typ, kind, fdepth}] (fdepth = function-nesting
// depth where bound; top level = 0). kind: "local" | "param" | "func"
// (any def) | "intrinsic". fdepth is bookkeeping only — it is threaded but
// never tested: a nested def reading an enclosing local is a capture, and
// captures are legal (native.y box_capture).

// line/col are the NAME's, not the keyword's: a go-to-definition and a
// semantic-token highlight both want the name, and every diagnostic position
// wants the keyword. -1 means the binding has no position in the source at
// all -- an intrinsic, or a name the program links against from another unit.
type Binding = { name: str, typ: Type, kind: str, fdepth: long, line: long, col: long };
type Lookup = { typ: Type, kind: str, fdepth: long };
// The state the checker threads (ret: the def's return type, see
// typeof_def; self: what `self` is in it), and what the typeof_* return:
// a type and the state after it.
// `loops` is how many loops enclose this point, and `loop_fd` the function
// depth of the INNERMOST of them. Both are there for `break` and `continue`
// (2025): a jump is only legal if a loop encloses it AND that loop is in the
// same function, and `loop_fd` is what says so -- a `def` nested inside a loop
// bumps fdepth without changing `loops`, so a `break` inside the `def` sees
// loops > 0 and still knows it may not jump out of the function.
type TcSt = { bindings: [Binding], errors: [Diag], ret: Type, self: Type, fdepth: long, loops: long, loop_fd: long };
type TcRes = { typ: Type, st: TcSt };

def tc_res(typ: Type, st: TcSt) -> TcRes {
    { typ: typ, st: st }
};

// The bindings by name (lookup): the index of each name's last binding in
// the program's bindings list -- flat, append-only, one per check_program
// run (which resets this), ~7k entries in the compiler. Made once the
// list passes 256 entries (st_bind; a small unit scans faster than it
// hashes): tc_ixn bindings are in it, all of them from then on.
let tc_ix: NameIx = parser.nameix_new(8);
let tc_ixn = 0;

def lookup(bindings: [Binding], name: str) -> Lookup {
    // The newest binding of the name: the last few bindings first (a
    // local is almost always among them), then the index: scanning back
    // through the whole list cost every reference to a global thousands
    // of compares. "" is not indexed: it is scanned for.
    let i = len(bindings) - 1;
    let stop = i - 8;
    if (tc_ixn == 0) { stop = -1; };
    let at = -1;
    while (i >= 0 && i > stop) {
        let e = bindings[i];
        if (e.name == name) { at = i; i = -1; };
        i = i - 1;
    };
    if (at < 0 && i >= 0) {
        if (len(name) > 0) {
            at = parser.nameix_get(tc_ix, name);
        } else {
            while (i >= 0) {
                let e = bindings[i];
                if (e.name == name) { at = i; i = -1; };
                i = i - 1;
            };
        };
    };
    // NOTE: NO shared `found` hole rebound across arms (see parser.y
    // parse_type_node note): the env keeps ONE shape per name.
    if (at >= 0) {
        let e = bindings[at];
        { typ: e.typ, kind: e.kind, fdepth: e.fdepth }
    } else {
        let none: Type = { k: K.tnone };
        { typ: none, kind: "", fdepth: 0 }
    }
};

def st_bind(st: TcSt, name: str, typ: Type, kind: str, line: long, col: long) -> TcSt {
    st.bindings += { name: name, typ: typ, kind: kind, fdepth: st.fdepth, line: line, col: col };
    let bindings = st.bindings;
    if (len(bindings) > 256) {
        if (tc_ixn == 0) { tc_ix = parser.nameix_new(1024); };
        while (tc_ixn < len(bindings)) {
            let b = bindings[tc_ixn];
            if (len(b.name) > 0) { parser.nameix_put(tc_ix, b.name, tc_ixn); };
            tc_ixn = tc_ixn + 1;
        };
    };
    { bindings: bindings, errors: st.errors, ret: st.ret, self: st.self, fdepth: st.fdepth, loops: st.loops, loop_fd: st.loop_fd }
};

// ── the checker ──────────────────────────────────────────────────────────
// Threaded state st = { bindings, errors, ret, self, fdepth }.
// typeof_* returns { typ, st }.

// State is threaded by rebuilding the record, so a helper never mutates its
// caller's st (same style as the rest of ycc). `fail` is the one place that
// writes through: `st.errors += ...` appends to the LIVE array in place,
// because arrays are reference values, and hands the record back here.
def st_errors(st: TcSt, errs: [Diag]) -> TcSt { { bindings: st.bindings, errors: errs, ret: st.ret, self: st.self, fdepth: st.fdepth, loops: st.loops, loop_fd: st.loop_fd } };
// NOTE: the parameter is deliberately NOT named `self` — `self` is the
// language's own name for the enclosing function (see the `id` and `call`
// arms of typeof_expr/typeof_call), so the state field and the language's
// reserved word must not read alike.
def st_self(st: TcSt, selfv: Type) -> TcSt { { bindings: st.bindings, errors: st.errors, ret: st.ret, self: selfv, fdepth: st.fdepth, loops: st.loops, loop_fd: st.loop_fd } };
// Entering a loop: one deeper, and the innermost loop's function depth is
// this one's. `loop_fd: -1` means "no loop", so a stale depth can never be
// mistaken for a live one.
def st_loop(st: TcSt, n: long, fd: long) -> TcSt {
    { bindings: st.bindings, errors: st.errors, ret: st.ret, self: st.self, fdepth: st.fdepth, loops: n, loop_fd: fd }
};

// Leaving one: back to whatever enclosed it. The caller's own `loops`/`loop_fd`
// from before the loop are what it passes, so this is a plain restore.
def st_unloop(st: TcSt, n: long, fd: long) -> TcSt {
    { bindings: st.bindings, errors: st.errors, ret: st.ret, self: st.self, fdepth: st.fdepth, loops: n, loop_fd: fd }
};

def st_ret(st: TcSt, ret: Type) -> TcSt { { bindings: st.bindings, errors: st.errors, ret: ret, self: st.self, fdepth: st.fdepth, loops: st.loops, loop_fd: st.loop_fd } };

def fail(st: TcSt, msg: str, line: long, col: long) -> TcSt {
    st.errors += err_at(msg, line, col);
    st_errors(st, st.errors)
};

// Display name: strip the rename pass's `$N` suffix so errors read like
// the user's source (`$` is lexer-illegal, so it can only come from rename).
def disp(name: str) -> str {
    let i = index_of(name, "$");
    if (i < 0) { name } else { name[0:i] }
};

// A local/param binding from an enclosing function is a CAPTURE, and captures
// are legal: the emitter closure-converts the function and BOXES each captured
// variable in one heap cell shared by the binding and every closure over it
// (native.y box_capture), so a write inside the closure is visible outside.
// Nothing is left to check here, so this is a pass-through kept at every call
// site as the hook for a future capture rule.
def check_visible(st: TcSt, got: Lookup, name: str, line: long, col: long) -> TcSt {
    st
};

def expect_type(st: TcSt, got: Type, want: Type, what: str, line: long, col: long) -> TcSt {
    if (tcompat(got, want)) { st } else {
        fail(st, what + ": expected " + tstr(want) + ", got " + tstr(got), line, col)
    }
};

// A union value where one of its members, or a union of some of them, is
// written: a cast, checked when the program runs (native.y gen_as: a value
// holding another member stops the program).
def cast_ok(got: Type, want: Type) -> bool {
    let g = unfold(got);
    if (tcompat(got, want)) { true }
    else if (g.k == K.tunion) { union_accepts(unfold(want), g) }
    else { false }
};

// expect_type where the type is written at the site -- an annotated let, a
// parameter, a declared return type -- so a union value casts to it. Where
// the type was inferred (an assignment, a field, an element) a union value
// does not: a binding inferred too narrow is an error, not a trap.
def expect_cast(st: TcSt, got: Type, want: Type, what: str, line: long, col: long) -> TcSt {
    if (cast_ok(got, want)) { st } else { expect_type(st, got, want, what, line, col) }
};

// expect_type for a call argument. some(v) passed for a T? -- which is what
// the argument of an optional parameter `b?: T` becomes -- is reported as
// v against T: "expected long, got long?", not "expected long?, got long??".
def expect_arg(st: TcSt, got: Type, want: Type, arg: Node, what: str, line: long, col: long) -> TcSt {
    if (cast_ok(got, want)) {
        st
    } else if (got.k == K.topt && want.k == K.topt && is_some_call(arg)) {
        let optgot: TOf = got;
        let optwant: TOf = want;
        fail(st, what + ": expected " + tstr(optwant.of) + ", got " + tstr(optgot.of), line, col)
    } else {
        fail(st, what + ": expected " + tstr(want) + ", got " + tstr(got), line, col)
    }
};

def is_some_call(n: Node) -> bool {
    if (n.k == K.call) {
        let call: Call = n;
        let c = call.callee;
        if (c.k == K.id) {
            let id: Leaf = c;
            id.v == "some"
        } else { false }
    } else {
        false
    }
};

// Binary-operator result typing. Split out of the `bin` arm so the operator
// table there stays a flat `op == "..."` dispatch and each operator's rule
// lives in one named place.
def typeof_arith(st: TcSt, op: str, lt: Type, rt: Type, line: long, col: long) -> TcRes {
    // "+" on strings concatenates (either side may be poison tunk, but at
    // least one side must be a real str — hence the per-kind arms below).
    // AUTO-STRINGIFY: str + long/bool/float (and the mirror) stringify the
    // number and concat — the same lowering native.y gen_cat emits
    // (y_long_tostr / y_float_tostr, then y_str_cat).
    if (op == "+") {
        // Arrays win over strings (the arm order below IS that order):
        // arr + arr concatenates into a NEW array, arr + elem appends one
        // (same type only), elem + arr prepends one. In-place forms are
        // `+=` / `*=`.
        if (lt.k == K.tarr || lt.k == K.tarrfix) {
            typeof_arith_arr(st, op, lt, rt, line, col)
        } else if (rt.k == K.tarr || rt.k == K.tarrfix) {
            typeof_arith_arr(st, op, lt, rt, line, col)
        } else if (lt.k == K.tstr) {
            if (rt.k == K.tstr) { tc_res({ k: K.tstr }, st) }
            else if (rt.k == K.tunk) { tc_res({ k: K.tstr }, st) }
            else if (rt.k == K.tlong) { tc_res({ k: K.tstr }, st) }
            else if (rt.k == K.tbyte) { tc_res({ k: K.tstr }, st) }
            else if (rt.k == K.tfloat) { tc_res({ k: K.tstr }, st) }
            else if (rt.k == K.tbool) { tc_res({ k: K.tstr }, st) }
            else { typeof_arith_long(st, op, lt, rt, line, col) }
        } else if (lt.k == K.tunk) {
            if (rt.k == K.tstr) { tc_res({ k: K.tstr }, st) }
            else { typeof_arith_long(st, op, lt, rt, line, col) }
        } else if (lt.k == K.tlong) {
            if (rt.k == K.tstr) { tc_res({ k: K.tstr }, st) }
            else { typeof_arith_long(st, op, lt, rt, line, col) }
        } else if (lt.k == K.tbyte) {
            if (rt.k == K.tstr) { tc_res({ k: K.tstr }, st) }
            else { typeof_arith_long(st, op, lt, rt, line, col) }
        } else if (lt.k == K.tfloat) {
            if (rt.k == K.tstr) { tc_res({ k: K.tstr }, st) }
            else { typeof_arith_long(st, op, lt, rt, line, col) }
        } else if (lt.k == K.tbool) {
            if (rt.k == K.tstr) { tc_res({ k: K.tstr }, st) }
            else { typeof_arith_long(st, op, lt, rt, line, col) }
        } else { typeof_arith_long(st, op, lt, rt, line, col) }
    } else { typeof_arith_long(st, op, lt, rt, line, col) }
};

def typeof_arith_arr(st: TcSt, op: str, lt: Type, rt: Type, line: long, col: long) -> TcRes {
    // The array operand decides the result type. Two arrays CONCATENATE
    // (each side's elements are spliced in, so the ELEMENT types must
    // match — arrays are homogeneous by design); a non-array operand is
    // ONE element of the array's element type.
    let lk: long = lt.k;
    if (op != "+") {
        st = fail(st, "'" + op + "' is not defined on arrays (only '+' copies, '+='/'*=' mutate)", line, col);
        { typ: t_unk(), st: st }
    } else if (lk == K.tarr || lk == K.tarrfix) {
        if (rt.k == K.tarr || rt.k == K.tarrfix) {
            let how = arr_plus_kind(lt, rt);
            let ltype: Type = t_unk();
            let rtype: Type = t_unk();
            if (lk == K.tarr) { let arr: TOf = lt; ltype = arr.of; }
            else { let arr: TFix = lt; ltype = arr.of; };
            if (rt.k == K.tarr) { let arr: TOf = rt; rtype = arr.of; }
            else { let arr: TFix = rt; rtype = arr.of; };
            if (how == "append") {
                let typ: Type = { k: K.tarr, of: ltype };
                { typ: typ, st: st }
            } else if (how == "prepend") {
                let typ: Type = { k: K.tarr, of: rtype };
                { typ: typ, st: st }
            } else {
                st = expect_type(st, rtype, ltype, "'+' concatenated elements", line, col);
                let typ: Type = { k: K.tarr, of: ltype };
                { typ: typ, st: st }
            }
        } else {
            let ltype: Type = t_unk();
            if (lk == K.tarr) { let arr: TOf = lt; ltype = arr.of; }
            else { let arr: TFix = lt; ltype = arr.of; };
            st = expect_type(st, rt, ltype, "'+' element", line, col);
            let typ: Type = { k: K.tarr, of: ltype };
            { typ: typ, st: st }
        }
    } else {
        let rtype: Type = t_unk();
        if (rt.k == K.tarr) { let arr: TOf = rt; rtype = arr.of; }
        else { let arr: TFix = rt; rtype = arr.of; };
        st = expect_type(st, lt, rtype, "'+' element", line, col);
        let typ: Type = { k: K.tarr, of: rtype };
        { typ: typ, st: st }
    }
};

// How `l + r` combines two ARRAY operands -- the one rule the checker and
// the emitter (native.y infer, gen_cat_arr, gen_opassign_arr) share:
//   "cat"      the element types match: both element lists are spliced
//   "append"   r is ONE element of l   ([[T]] + [T] -> [[T]])
//   "prepend"  l is ONE element of r   ([T] + [[T]] -> [[T]])
// Concatenation wins whenever it type-checks, so an unknown element type
// keeps the long-standing meaning; for known types at most one rule fits
// (a type is never its own element type). "cat" is also the answer when
// nothing fits, so the caller's concatenation check reports the mismatch.
def arr_plus_kind(lt: Type, rt: Type) -> str {
    let ltype: Type = t_unk();
    let rtype: Type = t_unk();
    if (lt.k == K.tarr) { let arr: TOf = lt; ltype = arr.of; }
    else { let arr: TFix = lt; ltype = arr.of; };
    if (rt.k == K.tarr) { let arr: TOf = rt; rtype = arr.of; }
    else { let arr: TFix = rt; rtype = arr.of; };
    if (tcompat(rtype, ltype)) { "cat" }
    else if (tcompat(rt, ltype)) { "append" }
    else if (tcompat(lt, rtype)) { "prepend" }
    else { "cat" }
};

// `x :: a` -- cons: a NEW array with x prepended as exactly ONE element
// (unlike `elem + a`, an array-typed element is never spliced). The right
// operand must be an array; the left must be its element type.
def typeof_cons(st: TcSt, lt: Type, rt: Type, line: long, col: long) -> TcRes {
    if (rt.k == K.tarr || rt.k == K.tarrfix) {
        let elem: Type = t_unk();
        if (rt.k == K.tarr) { let arr: TOf = rt; elem = arr.of; }
        else { let arr: TFix = rt; elem = arr.of; };
        st = expect_type(st, lt, elem, "'::' element", line, col);
        let typ: Type = { k: K.tarr, of: elem };
        { typ: typ, st: st }
    } else {
        st = fail(st, "'::' needs an array on the right, got " + tstr(rt), line, col);
        { typ: t_unk(), st: st }
    }
};

def typeof_arith_long(st: TcSt, op: str, lt: Type, rt: Type, line: long, col: long) -> TcRes {
    // Numeric arithmetic. If either side is a float the result is a float
    // and the other side widens (long -> float, the only coercion).
    if (lt.k == K.tfloat || rt.k == K.tfloat) {
        st = expect_type(st, lt, { k: K.tfloat }, "'" + op + "' left operand", line, col);
        st = expect_type(st, rt, { k: K.tfloat }, "'" + op + "' right operand", line, col);
        tc_res({ k: K.tfloat }, st)
    } else {
        st = expect_type(st, lt, { k: K.tlong }, "'" + op + "' left operand", line, col);
        st = expect_type(st, rt, { k: K.tlong }, "'" + op + "' right operand", line, col);
        tc_res({ k: K.tlong }, st)
    }
};

// The bitwise binary operators. (native.y asks too: their result is a long.)
def is_bits_op(op: str) -> bool {
    op == "&" || op == "|" || op == "^" || op == "<<" || op == ">>" || op == ">>>"
};

// `&` `|` `^` `<<` `>>` `>>>` take integers only: a byte operand widens and
// the result is a long. No float, no bool (`&&` and `||` are the logical
// forms).
def typeof_bits(st: TcSt, op: str, lt: Type, rt: Type, line: long, col: long) -> TcRes {
    st = expect_type(st, lt, { k: K.tlong }, "'" + op + "' left operand", line, col);
    st = expect_type(st, rt, { k: K.tlong }, "'" + op + "' right operand", line, col);
    tc_res({ k: K.tlong }, st)
};

def typeof_cmp(st: TcSt, op: str, lt: Type, rt: Type, line: long, col: long) -> TcRes {
    if (lt.k == K.tstr) {
        // str < str is lexicographic ordering (byte by byte), matching the
        // y_str_cmp helper native.y emits.
        st = expect_type(st, rt, { k: K.tstr }, "'" + op + "' right operand", line, col);
        tc_res({ k: K.tbool }, st)
    } else if (lt.k == K.tfloat || rt.k == K.tfloat) {
        st = expect_type(st, lt, { k: K.tfloat }, "'" + op + "' left operand", line, col);
        st = expect_type(st, rt, { k: K.tfloat }, "'" + op + "' right operand", line, col);
        tc_res({ k: K.tbool }, st)
    } else {
        st = expect_type(st, lt, { k: K.tlong }, "'" + op + "' left operand", line, col);
        st = expect_type(st, rt, { k: K.tlong }, "'" + op + "' right operand", line, col);
        tc_res({ k: K.tbool }, st)
    }
};

// Both sides numeric (long/byte/float): `==` and `!=` compare by value
// across widths, which is what the compiled code does (native.y gen_bin_rest
// emits a plain word compare).
def is_num_kind(t: Type) -> bool {
    if (t.k == K.tlong) { true }
    else if (t.k == K.tbyte) { true }
    else if (t.k == K.tfloat) { true }
    else { false }
};

def num_eq_ok(lt: Type, rt: Type) -> bool {
    if (is_num_kind(lt)) { is_num_kind(rt) } else { false }
};

def typeof_eq(st: TcSt, op: str, lt: Type, rt: Type, line: long, col: long) -> TcRes {
    // str compares by content. `x == none` is the option's is-none check.
    // Nested ifs throughout (house style — one kind per arm).
    if (teq(lt, rt)) { tc_res({ k: K.tbool }, st) }
    else if (num_eq_ok(lt, rt)) {
        // Numeric kinds compare across widths: a byte IS a small long, so
        // `c'\n'` needs no cast (and long/float already coerce in `<`).
        tc_res({ k: K.tbool }, st)
    }
    else if (lt.k == K.tstr) {
        if (rt.k == K.tstr) { tc_res({ k: K.tbool }, st) }
        else if (rt.k == K.tunk) { tc_res({ k: K.tbool }, st) }
        else {
            st = fail(st, "'" + op + "' compares " + tstr(lt) + " with " + tstr(rt), line, col);
            tc_res({ k: K.tbool }, st)
        }
    } else if (lt.k == K.tunk) {
        tc_res({ k: K.tbool }, st)
    } else if (lt.k == K.topt) {
        // options: the is-none check (`x == none`) plus same-option
        // comparison. Anything else is a type error (t10 parity).
        if (rt.k == K.tunk) { tc_res({ k: K.tbool }, st) }
        else if (teq(lt, rt)) { tc_res({ k: K.tbool }, st) }
        else {
            st = fail(st, "'" + op + "' compares " + tstr(lt) + " with " + tstr(rt), line, col);
            tc_res({ k: K.tbool }, st)
        }
    } else if (rt.k == K.topt) {
        if (lt.k == K.tunk) { tc_res({ k: K.tbool }, st) }
        else {
            st = fail(st, "'" + op + "' compares " + tstr(lt) + " with " + tstr(rt), line, col);
            tc_res({ k: K.tbool }, st)
        }
    } else {
        st = fail(st, "'" + op + "' compares " + tstr(lt) + " with " + tstr(rt), line, col);
        tc_res({ k: K.tbool }, st)
    }
};

def typeof_logic(st: TcSt, op: str, lt: Type, rt: Type, line: long, col: long) -> TcRes {
    // Truthiness: any 8-byte value decides (nonzero = true), like the C
    // runtime. The result is always a bool; operands keep their own types.
    tc_res({ k: K.tbool }, st)
};

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
def tcompat(got: Type, want: Type) -> bool {
    got = unfold(got);
    want = unfold(want);
    if (teq(got, want)) { true }
    else if (got.k == K.tnone) { true }
    else if (want.k == K.tnone) { true }
    else if (got.k == K.tname) { true }
    else if (want.k == K.tname) { true }
    else if (got.k == K.tparams) { true }
    else if (want.k == K.tparams) { true }
    else if (want.k == K.tunion) { union_accepts(got, want) }
    else if (got.k == K.tunion) {
        // a union is none of its members until a match says which, or a
        // cast where the member type is written (expect_cast)
        false
    }
    else if (want.k == K.topt) {
        // `none` (the option of tunk) widens to any T? through teq; a
        // plain T does NOT -- use some(v), which is the explicit box
        // (options are 0-or-box, so some(0) differs from none).
        // Option-to-option unifies payloads.
        if (got.k == K.topt) {
            let gopt: TOf = got;
            let wopt: TOf = want;
            teq(gopt.of, wopt.of)
        }
        else { false }
    }
    else if (got.k == K.trec) { false }
    else if (want.k == K.trec) { false }
    else if (got.k == K.tstr) {
        if (want.k == K.tptr) { true } else { false }
    } else if (got.k == K.tlong) {
        // long widens to float (the only numeric coercion: `2.0 * i` and
        // `x + 1` with a float x both work).
        // long also narrows to byte: there is no cast syntax, so an
        // annotated position is the only place the intent can be stated
        // (`let b: byte = 65`, `bs += n`, a byte-typed parameter).
        // The value is masked to 8 bits where it is stored.
        if (want.k == K.tfloat) { true }
        else if (want.k == K.tbyte) { true }
        else { false }
    } else if (got.k == K.tbyte) {
        // byte widens to long (and on to float) — it is an 8-bit unsigned
        // integer, so every value is representable.
        if (want.k == K.tlong) { true }
        else if (want.k == K.tfloat) { true }
        else { false }
    } else { false }
};

// An array/[v; n] LITERAL may adopt a narrower annotated element type
// (`let b: [byte] = [104, 105]`). Restricted to literals on purpose: the
// layouts differ (packed vs one word each), so reinterpreting an existing
// array would be a type pun.
// An array LITERAL adopts an annotated array type (`[1, 2]` under `[long; 2]`),
// so `n` is how many elements it actually has. That matters only for a fixed
// target: `let gx: [long; 5] = [1, 2]` must not be accepted, because the
// emitter bounds-checks a fixed array against the annotated N while the
// literal built a block of 2 -- every index from 2 up would read and write
// outside it, with no trap (06-arrays.tex: "allocated with exactly N slots",
// "bounds-trapped"). A `[T; N]` on the other side already carries its own
// count, so it is compared against n there.
def arr_lit_adopts(got: Type, want: Type, n: long) -> bool {
    if (got.k == K.tarr) { arr_lit_adopts_go(got, want, n) }
    else if (got.k == K.tarrfix) { arr_lit_adopts_go(got, want, n) }
    else { false }
};

def arr_lit_adopts_go(got: Type, want: Type, n: long) -> bool {
    if (want.k == K.tarr) {
        let warr: TOf = want;
        let ge: Type = t_unk();
        if (got.k == K.tarr) { let garr: TOf = got; ge = garr.of; }
        else { let garr: TFix = got; ge = garr.of; };
        tcompat(ge, warr.of)
    }
    else if (want.k == K.tarrfix) {
        let warr: TFix = want;
        if (got.k == K.tarrfix) {
            let garr: TFix = got;
            if (garr.n == warr.n) { tcompat(garr.of, warr.of) } else { false }
        } else {
            let garr: TOf = got;
            if (n != warr.n) { false } else { tcompat(garr.of, warr.of) }
        }
    }
    else { false }
};

// The type of an expression (typeof_expr_go), a recursive alias unfolded
// (unfold): the checker looks into it.
// The checker's walk counts its depth (tags.y MAX_NEST): a `+` chain is a
// loop in the parser and a recursion here.
// ── the expression type index (LSP.md 9.2 A2) ───────────────────────────
//
// The type the checker inferred for every EXPRESSION, keyed by position, for a
// caller that has to show one: the language server's hover, and the record-field
// lookup behind completion after a `.`. Both need exactly what `typeof_expr`
// computed and then dropped, so it is kept -- behind a flag, because the
// checker is the compiler's hottest loop and a normal compile has no use for it.
//
// The shape is inferred_ret's, deliberately: 1024 buckets of indices into
// parallel key/type arrays, keyed `line * 65536 + col`. That table is read by
// native.y on every compile, so the shape and the packing are proven at this
// scale in this codebase; a second design would be a second thing to get wrong.
//
// OFF by default. A module-level `bool` cannot be hoisted, so this costs the
// hot loop one predictable branch that is never taken in a real compile.
// bench/compile_ir.sh is what says what that is worth.
let tc_index: bool = false;
let tci_keys: [long] = [];
let tci_typs: [Type] = [];
let tci_bkts: [[long]] = [];

def tci_reset() {
    let keys: [long] = [];
    let typs: [Type] = [];
    let bkts: [[long]] = [];
    let i = 0;
    while (i < 1024) {
        let b: [long] = [];
        bkts += b;
        i = i + 1;
    };
    tci_keys = keys;
    tci_typs = typs;
    tci_bkts = bkts;
};

// Turn it on for one check_program, and start a fresh table. check_program
// resets it again on the way out, so two calls cannot see each other's types.
def type_index_on() -> void {
    tc_index = true;
    tci_reset();
};

def type_index_off() -> void { tc_index = false };

// One entry, unless the key is already there -- the FIRST type wins, as above.
def tci_note_key(key: long, t: Type) {
    let bkt: [long] = tci_bkts[key % 1024];
    let seen = false;
    let i = 0;
    while (i < len(bkt)) {
        if (tci_keys[bkt[i]] == key) { seen = true; i = len(bkt); }
        else { i = i + 1; };
    };
    if (!seen) {
        tci_keys += key;
        tci_typs += t;
        bkt += len(tci_keys) - 1;
    };
};

// Only ever called when tc_index is set: the flag is tested at the call site in
// typeof_expr rather than here, so the off path costs a load and a branch and
// not a call. Measured: testing it inside made the call itself the cost, and
// the call is per EXPRESSION, which is the checker's hottest path.
def tci_note(node: Node, t: Type) {
    if (len(tci_bkts) > 0) {
        if (node.line > 0 && node.col >= 0) {
            let key = node.line * 65536 + node.col;
            let bkt: [long] = tci_bkts[key % 1024];
            // FIRST wins. An expression is checked more than once when it is a
            // function literal's value (the checker infers, then re-checks with
            // the return type known), and the first type is the one the source
            // says rather than the one the second pass settled on.
            let seen = false;
            let i = 0;
            while (i < len(bkt)) {
                if (tci_keys[bkt[i]] == key) { seen = true; i = len(bkt); }
                else { i = i + 1; };
            };
            if (!seen) {
                tci_keys += key;
                tci_typs += t;
                bkt += len(tci_keys) - 1;
            };
        };
        // A member access records its type at the KEY's position too.
        //
        // `a.b` parses with the Dot at the `.`, so the table holds the FIELD's
        // type under the dot and nothing under the field's own name -- which is
        // where an editor puts the cursor and what go-to-highlight asks about. The
        // parser keeps the key's position for exactly this (Decl/Dot `nline`/
        // `ncol`, 9.2 A5), so it is recorded as well.
        //
        // Only when the index is on, so a real compile pays nothing: this is
        // inside tci_note, which typeof_expr does not even call.
        let nk = node.k;
        if (nk == K.decl) {
            // A `let`/`def` records its type at its NAME's position as well as the
            // keyword's, for the same reason a member access does: the keyword is
            // where the node sits and the name is where a cursor goes. Without this
            // a hover on `b` in `let b = 1` showed the name and nothing else, while
            // a hover on a USE of `b` showed `long` -- the same name, two answers.
            let d: Decl = node;
            if (d.nline > 0 && d.ncol > 0) { tci_note_key(d.nline * 65536 + d.ncol, t); };
        };
        if (nk == K.dot) {
            let d: Dot = node;
            if (d.nline > 0 && d.ncol > 0) { tci_note_key(d.nline * 65536 + d.ncol, t); };
        } else if (nk == K.dotassign) {
            let d: DotAssign = node;
            if (d.nline > 0 && d.ncol > 0) { tci_note_key(d.nline * 65536 + d.ncol, t); };
        };
    };
};

// The type inferred for the expression at (line, col), or tunk() when nothing
// was indexed there. tunk rather than tnone: tnone is a real type a program can
// write, and a consumer must be able to tell "the checker says none" from "there
// is nothing here", or it will print a type it did not get from the checker.
def expr_type(line: long, col: long) -> Type {
    let found: Type = t_unk();
    if (len(tci_bkts) > 0) {
        let key = line * 65536 + col;
        let bkt: [long] = tci_bkts[key % 1024];
        let i = 0;
        while (i < len(bkt)) {
            if (tci_keys[bkt[i]] == key) { found = tci_typs[bkt[i]]; i = len(bkt); }
            else { i = i + 1; };
        };
    };
    found
};

def typeof_expr(st: TcSt, node: Node) -> TcRes {
    nest = nest + 1;
    if (nest > MAX_NEST) { too_deep("an expression", node.line, node.col); };
    let r = typeof_expr_go(st, node);
    nest = nest - 1;
    let t: Type = r.typ;
    if (t.k == K.tref) {
        let out = tc_res(unfold(t), r.st);
        // the UNWRAPPED type: a tref is the checker's own recursive-alias
        // placeholder, and a hover that printed one would be showing the
        // implementation rather than the answer.
        if (tc_index) { tci_note(node, out.typ); };
        out
    } else {
        if (tc_index) { tci_note(node, t); };
        r
    }
};

def typeof_expr_go(st: TcSt, node: Node) -> TcRes {
    let k = node.k;
    if (k == K.num) {
        let lit: Leaf = node;
        if (num_is_float(lit.v)) {
            let dp = num_net_exp(lit.v);
            if (dp > 100000 || dp < 0 - 100000) {
                // out of range by thousands of decades: a mistake, not a
                // value. A literal merely past the double's range (1e400) is
                // still accepted and becomes inf, as IEEE says.
                st = fail(st, "float literal magnitude out of range (a double holds 10^-308 to 10^308)", lit.line, lit.col);
            };
            tc_res(type_node({ k: K.tfloat }), st)
        } else {
            tc_res(type_node({ k: K.tlong }), st)
        }
    } else if (k == K.str) {
        tc_res(type_node({ k: K.tstr }), st)
    } else if (k == K.bstr) {
        // b"..." is a [byte] literal (packed bytes, like a Python bytes)
        tc_res(type_node({ k: K.tarr, of: type_node({ k: K.tbyte }) }), st)
    } else if (k == K.err) {
        // Planted by the parser where the token stream stopped making
        // sense (parser.y has no error channel of its own).
        let err: Err = node;
        st = fail(st, err.msg, err.line, err.col);
        tc_res(t_unk(), st)
    } else if (k == K.bool) {
        tc_res(type_node({ k: K.tbool }), st)
    } else if (k == K.void) {
        // An absent expression (bare `return;`, a missing else, an empty
        // for-clause): it computes nothing. The empty option is `none`
        // (an id, see below), never this node.
        tc_res(type_node({ k: K.tvoid }), st)
    } else if (k == K.id) {
        let id: Leaf = node;
        if (id.v == "self") {
            // resolved by the enclosing def pre-pass (stored as _self in st)
            if (st.self.k == K.tnone) {
                st = fail(st, "'self' outside of a function", id.line, id.col);
                tc_res(t_unk(), st)
            } else if (ret_unknown(st.self)) {
                st = fail(st, "'self' is used before its return type is known (annotate it)", id.line, id.col);
                tc_res(t_unk(), st)
            } else {
                tc_res(st.self, st)
            }
        } else {
            let got = lookup(st.bindings, id.v);
            if (got.kind == "") {
                if (id.v == "none") {
                    // the empty option (type from context via unification)
                    tc_res(type_node({ k: K.topt, of: t_free() }), st)
                } else {
                    st = fail(st, "undefined variable '" + id.v + "'", id.line, id.col);
                    tc_res(t_unk(), st)
                }
            } else if (ret_unknown(got.typ)) {
                st = fail(st, "'" + disp(id.v) + "' is used before its return type is known (annotate it)", id.line, id.col);
                tc_res(t_unk(), st)
            } else {
                st = check_visible(st, got, id.v, id.line, id.col);
                tc_res(got.typ, st)
            }
        }
    } else if (k == K.un) {
        let un: Un = node;
        let r = typeof_expr(st, un.e);
        st = r.st;
        if (un.op == "-") {
            if (r.typ.k == K.tfloat) {
                tc_res(type_node({ k: K.tfloat }), st)
            } else {
                st = expect_type(st, r.typ, type_node({ k: K.tlong }), "unary '-'", un.line, un.col);
                tc_res(type_node({ k: K.tlong }), st)
            }
        } else if (un.op == "~") {
            st = expect_type(st, r.typ, type_node({ k: K.tlong }), "unary '~'", un.line, un.col);
            tc_res(type_node({ k: K.tlong }), st)
        } else {
            st = expect_type(st, r.typ, type_node({ k: K.tbool }), "unary '!'", un.line, un.col);
            tc_res(type_node({ k: K.tbool }), st)
        }
    } else if (k == K.addr) {
        let addr: Wrap = node;
        // &x (plain local/param) or &a[i] (element address, either array).
        // NOTE: nested ifs, not a `&&` guard (house style — one failure
        // message per shape, and `&&` would be short-circuit anyway).
        if (addr.e.k == K.id) {
            let id: Leaf = addr.e;
            if (id.v != "self") {
                let got = lookup(st.bindings, id.v);
                if (got.kind == "") {
                    st = fail(st, "undefined variable '" + id.v + "'", addr.line, addr.col);
                    tc_res(t_unk(), st)
            } else if (got.kind == "func" || got.kind == "intrinsic") {
                st = fail(st, "cannot take the address of function '" + id.v + "'", addr.line, addr.col);
                tc_res(t_unk(), st)
            } else if (got.typ.k == K.tarr || got.typ.k == K.tarrfix) {
                // One rule for BOTH array kinds: &a is not a data address.
                // A slot holds the {len,cap,data} header (fixed arrays are
                // heap blocks too), so `io.read(fd, &buf, n)` let the kernel
                // write over the frame -- the array's own header was the
                // first casualty and the next len(buf) died with SIGSEGV.
                // Use &a[0] (or &a[i]): gen_elem_addr resolves that through
                // header+16 to the data block.
                st = fail(st, "cannot take the address of a whole array (use &" + disp(id.v) + "[i] for elements)", addr.line, addr.col);
                tc_res(t_unk(), st)
            } else {
                st = check_visible(st, got, id.v, addr.line, addr.col);
                tc_res(type_node({ k: K.tptr, to: got.typ }), st)
            }
            } else {
                st = fail(st, "'&' needs a plain variable (only a local, a parameter or a global has an address)", addr.line, addr.col);
                tc_res(t_unk(), st)
            }
        } else if (addr.e.k == K.index) {
            let index: Index = addr.e;
            let ix = index.idx;
            let arr = index.arr;
            if (arr.k == K.id) {
                let id: Leaf = arr;
                let got = lookup(st.bindings, id.v);
                if (got.kind == "") {
                    st = fail(st, "undefined variable '" + id.v + "'", addr.line, addr.col);
                    tc_res(t_unk(), st)
                } else if (got.typ.k == K.tarrfix || got.typ.k == K.tarr) {
                    st = check_visible(st, got, id.v, addr.line, addr.col);
                    let r = typeof_expr(st, ix);
                    st = r.st;
                    st = expect_type(st, r.typ, type_node({ k: K.tlong }), "array index", addr.line, addr.col);
                    let elem: Type = t_unk();
                    if (got.typ.k == K.tarr) { let a: TOf = got.typ; elem = a.of; }
                    else { let a: TFix = got.typ; elem = a.of; };
                    tc_res(type_node({ k: K.tptr, to: elem }), st)
                } else {
                    st = fail(st, "cannot index " + tstr(got.typ) + " (only arrays)", addr.line, addr.col);
                    tc_res(t_unk(), st)
                }
            } else {
                // general base (`&grid[0][i]`, `&rec.v[i]`): an element
                // address of any array expression.
                let barr = arr;
                let br = typeof_expr(st, barr);
                st = br.st;
                if (br.typ.k == K.tarrfix || br.typ.k == K.tarr) {
                    let r = typeof_expr(st, ix);
                    st = r.st;
                    st = expect_type(st, r.typ, type_node({ k: K.tlong }), "array index", addr.line, addr.col);
                    let elem: Type = t_unk();
                    if (br.typ.k == K.tarr) { let a: TOf = br.typ; elem = a.of; }
                    else { let a: TFix = br.typ; elem = a.of; };
                    tc_res(type_node({ k: K.tptr, to: elem }), st)
                } else {
                    st = fail(st, "cannot index " + tstr(br.typ) + " (only arrays)", addr.line, addr.col);
                    tc_res(t_unk(), st)
                }
            }
        } else {
            st = fail(st, "'&' needs a plain variable (only a local, a parameter or a global has an address)", addr.line, addr.col);
            tc_res(t_unk(), st)
        }
    } else if (k == K.deref) {
        let deref: Wrap = node;
        let r = typeof_expr(st, deref.e);
        st = r.st;
        if (r.typ.k == K.tptr) {
            let ptr: TPtr = r.typ;
            tc_res(ptr.to, st)
        } else if (r.typ.k == K.tunk) {
            tc_res(t_unk(), st)
        } else {
            st = fail(st, "cannot dereference " + tstr(r.typ) + " (need *T)", deref.line, deref.col);
            tc_res(t_unk(), st)
        }
    } else if (k == K.bin) {
        let bin: Bin = node;
        let l = typeof_expr(st, bin.l);
        let r = typeof_expr(l.st, bin.r);
        st = r.st;
        let op = bin.op;
        // NOTE: one flat `op == "..."` table, deliberately not a `||`
        // chain: each row dispatches to a named helper, and only the two
        // comparison ops share one.
        if (op == "+") { typeof_arith(st, op, l.typ, r.typ, bin.line, bin.col) }
        else if (op == "-") { typeof_arith(st, op, l.typ, r.typ, bin.line, bin.col) }
        else if (op == "*") { typeof_arith(st, op, l.typ, r.typ, bin.line, bin.col) }
        else if (op == "/") { typeof_arith(st, op, l.typ, r.typ, bin.line, bin.col) }
        else if (op == "%") { typeof_arith(st, op, l.typ, r.typ, bin.line, bin.col) }
        else if (op == "<") { typeof_cmp(st, op, l.typ, r.typ, bin.line, bin.col) }
        else if (op == ">") { typeof_cmp(st, op, l.typ, r.typ, bin.line, bin.col) }
        else if (op == "<=") { typeof_cmp(st, op, l.typ, r.typ, bin.line, bin.col) }
        else if (op == ">=") { typeof_cmp(st, op, l.typ, r.typ, bin.line, bin.col) }
        else if (op == "==") { typeof_eq(st, op, l.typ, r.typ, bin.line, bin.col) }
        else if (op == "!=") { typeof_eq(st, op, l.typ, r.typ, bin.line, bin.col) }
        else if (op == "&&") { typeof_logic(st, op, l.typ, r.typ, bin.line, bin.col) }
        else if (op == "||") { typeof_logic(st, op, l.typ, r.typ, bin.line, bin.col) }
        else if (op == "::") { typeof_cons(st, l.typ, r.typ, bin.line, bin.col) }
        else if (op == "&") { typeof_bits(st, op, l.typ, r.typ, bin.line, bin.col) }
        else if (op == "|") { typeof_bits(st, op, l.typ, r.typ, bin.line, bin.col) }
        else if (op == "^") { typeof_bits(st, op, l.typ, r.typ, bin.line, bin.col) }
        else if (op == "<<") { typeof_bits(st, op, l.typ, r.typ, bin.line, bin.col) }
        else if (op == ">>") { typeof_bits(st, op, l.typ, r.typ, bin.line, bin.col) }
        else if (op == ">>>") { typeof_bits(st, op, l.typ, r.typ, bin.line, bin.col) }
        else {
            st = fail(st, "operator '" + op + "' is unsupported in native mode", bin.line, bin.col);
            tc_res(t_unk(), st)
        }
    } else if (k == K.call) {
        let call: Call = node;
        typeof_call(st, call)
    } else if (k == K.kw_if) {
        let branch: If = node;
        let c = typeof_expr(st, branch.cond);
        st = expect_type(c.st, c.typ, type_node({ k: K.tbool }), "'if' condition", branch.line, branch.col);
        // NOTE: typeof_expr, not typeof_block — `els` may be a nested `if`
        // (else-if chain), not a block.
        let t = typeof_expr(st, branch.then);
        st = t.st;
        if (branch.has_else) {
            let e = typeof_expr(st, branch.els);
            st = e.st;
            if (teq(t.typ, e.typ)) {
                // An arm of unknown type -- typically a self call, whose
                // type is the one being inferred -- takes the other's.
                let tt = t.typ;
                let et = e.typ;
                if (tt.k == K.tunk && et.k != K.tnone) { tc_res(et, st) } else { tc_res(tt, st) }
            } else {
                // VOID law: arms that disagree on a type (a value arm vs a
                // statement arm, or two different values) make the whole
                // `if` a statement -- void, not usable as a value. Using it
                // as one errors at that use (binding, argument, print...).
                tc_res(type_node({ k: K.tvoid }), st)
            }
        } else {
            // VOID law: an `if` without `else` is a STATEMENT — its value is
            // nothing, whatever the then-branch computes. No forced else
            // branch, no forced `0;` tail in user programs.
            tc_res(type_node({ k: K.tvoid }), st)
        }
    } else if (k == K.kw_while) {
        let loop: While = node;
        let c = typeof_expr(st, loop.cond);
        st = expect_type(c.st, c.typ, type_node({ k: K.tbool }), "'while' condition", loop.line, loop.col);
        // The BODY is what `break` may leave. The condition is checked outside
        // the loop context on purpose: `while break { }` is not a jump out of
        // this loop, it is a jump out of an enclosing one, and treating it as
        // this loop's would be a jump to a label that does not exist yet.
        let saved_loops = st.loops;
        let saved_fd = st.loop_fd;
        st = st_loop(st, saved_loops + 1, st.fdepth);
        let b = typeof_block(st, loop.body);
        st = st_unloop(b.st, saved_loops, saved_fd);
        tc_res(type_node({ k: K.tvoid }), st)
    } else if (k == K.kw_for) {
        let loop: For = node;
        // for (init; cond; step) body — init/step are statements, and the
        // loop variable stays visible afterwards (same scope rule as `let`).
        let fi = typeof_expr(st, loop.init);
        st = fi.st;
        let fc = typeof_expr(st, loop.cond);
        st = expect_type(fc.st, fc.typ, type_node({ k: K.tbool }), "'for' condition", loop.line, loop.col);
        let saved_loops = st.loops;
        let saved_fd = st.loop_fd;
        st = st_loop(st, saved_loops + 1, st.fdepth);
        let fb = typeof_block(st, loop.body);
        st = st_unloop(fb.st, saved_loops, saved_fd);
        let fs = typeof_expr(st, loop.step);
        tc_res(type_node({ k: K.tvoid }), fs.st)
    } else if (k == K.kw_foreach) {
        let loop: Foreach = node;
        // foreach (x in arr) body — x takes the array's element type.
        let fe = typeof_expr(st, loop.iter);
        st = fe.st;
        let elt: Type = t_unk();
        if (fe.typ.k == K.tarr) { let arr: TOf = fe.typ; elt = arr.of; }
        else if (fe.typ.k == K.tarrfix) { let arr: TFix = fe.typ; elt = arr.of; }
        else if (fe.typ.k == K.tunk) { }
        else {
            st = fail(st, "'foreach' needs an array, got " + tstr(fe.typ), loop.line, loop.col);
        };
        st = st_bind(st, loop.name, elt, "local", loop.line, loop.col);
        let saved_loops = st.loops;
        let saved_fd = st.loop_fd;
        st = st_loop(st, saved_loops + 1, st.fdepth);
        let fbb = typeof_block(st, loop.body);
        st = st_unloop(fbb.st, saved_loops, saved_fd);
        tc_res(type_node({ k: K.tvoid }), st)
    } else if (k == K.forrange) {
        let loop: ForRange = node;
        // for x in lo..hi { body } — x is a long.
        let rl = typeof_expr(st, loop.lo);
        st = expect_type(rl.st, rl.typ, type_node({ k: K.tlong }), "'for' range start", loop.line, loop.col);
        let rh = typeof_expr(st, loop.hi);
        st = expect_type(rh.st, rh.typ, type_node({ k: K.tlong }), "'for' range end", loop.line, loop.col);
        st = st_bind(st, loop.name, type_node({ k: K.tlong }), "local", loop.line, loop.col);
        let saved_loops = st.loops;
        let saved_fd = st.loop_fd;
        st = st_loop(st, saved_loops + 1, st.fdepth);
        let rb = typeof_block(st, loop.body);
        st = st_unloop(rb.st, saved_loops, saved_fd);
        tc_res(type_node({ k: K.tvoid }), st)
    } else if (k == K.block) {
        let block: Block = node;
        typeof_block(st, block)
    } else if (k == K.decl) {
        let decl: Decl = node;
        typeof_decl(st, decl)
    } else if (k == K.assign) {
        let assign: Assign = node;
        let got = lookup(st.bindings, assign.name);
        let r = typeof_want(st, assign.v, got.typ);
        st = r.st;
        if (got.kind == "") {
            st = fail(st, "undefined variable '" + disp(assign.name) + "'", assign.line, assign.col);
            tc_res(t_unk(), st)
        } else if (got.kind == "func" || got.kind == "intrinsic") {
            st = fail(st, "cannot assign to function '" + disp(assign.name) + "'", assign.line, assign.col);
            tc_res(t_unk(), st)
        } else if (got.kind == "const") {
            st = fail(st, "cannot assign to constant '" + disp(assign.name) + "'", assign.line, assign.col);
            tc_res(got.typ, st)
        } else if (got.typ.k == K.tarrfix) {
            st = check_visible(st, got, assign.name, assign.line, assign.col);
            st = expect_type(st, r.typ, got.typ, "assignment to '" + disp(assign.name) + "'", assign.line, assign.col);
            tc_res(got.typ, st)
        } else {
            st = check_visible(st, got, assign.name, assign.line, assign.col);
            st = expect_type(st, r.typ, got.typ, "assignment to '" + disp(assign.name) + "'", assign.line, assign.col);
            tc_res(got.typ, st)
        }
    } else if (k == K.incdec) {
        let incdec: IncDec = node;
        // ++x / x++: numbers only — `s++` on a string would silently
        // concatenate, so it is a type error instead.
        let t = typeof_expr(st, incdec.tgt);
        let pc = place_check(t.st, incdec.tgt, t.typ, incdec.op, incdec.line, incdec.col);
        st = const_check(pc.st, incdec.tgt, pc.typ, incdec.op, incdec.line, incdec.col);
        incdec_check(st, incdec, pc.typ)
    } else if (k == K.opassign) {
        let assign: OpAssign = node;
        // `x op= e`: the rules live in opassign_check.
        let t = typeof_expr(st, assign.tgt);
        st = t.st;
        // `arr += {...}` / `arr *= {...}`: a record literal is an element
        let tt: Type = t.typ;
        let vw: Type = type_node({ k: K.tnone });
        if (tt.k == K.tarr) { let arr: TOf = tt; vw = arr.of; }
        else if (tt.k == K.tarrfix) { let arr: TFix = tt; vw = arr.of; }

        let v = typeof_want(st, assign.v, vw);
        let pc = place_check(v.st, assign.tgt, t.typ, assign.op + "=", assign.line, assign.col);
        st = const_check(pc.st, assign.tgt, pc.typ, assign.op + "=", assign.line, assign.col);
        opassign_check(st, assign, pc.typ, v.typ)
    } else if (k == K.store) {
        let store: Store = node;
        let p = typeof_expr(st, store.p);
        let pt: Type = p.typ;
        let pw: Type = type_node({ k: K.tnone });
        if (pt.k == K.tptr) { let ptr: TPtr = pt; pw = ptr.to; }
        let v = typeof_want(p.st, store.v, pw);
        st = v.st;
        if (p.typ.k == K.tptr) {
            let ptr: TPtr = p.typ;
            st = expect_type(st, v.typ, ptr.to, "store through pointer", store.line, store.col);
            tc_res(ptr.to, st)
        } else if (p.typ.k == K.tunk || v.typ.k == K.tunk) {
            tc_res(t_unk(), st)
        } else {
            st = fail(st, "store target must be *T, got " + tstr(p.typ), store.line, store.col);
            tc_res(t_unk(), st)
        }
    } else if (k == K.kw_break || k == K.kw_continue) {
        // `break` / `continue`: legal only inside a loop AND in the same
        // function. Both are checked here rather than left to the emitter,
        // because the emitter's answer would be a jump to a label that belongs
        // to a different function -- which assembles, and then jumps into the
        // middle of an unrelated body.
        let word = "break";
        if (k == K.kw_continue) { word = "continue"; };
        if (st.loops <= 0) {
            st = fail(st, "'" + word + "' outside of a loop", node.line, node.col);
        } else if (st.loop_fd != st.fdepth) {
            st = fail(st, "'" + word + "' cannot cross a function boundary", node.line, node.col);
        };
        tc_res(type_node({ k: K.tvoid }), st)
    } else if (k == K.ret) {
        let ret: Wrap = node;
        if (st.ret.k == K.tnone) {
            st = fail(st, "'return' outside of a function", ret.line, ret.col);
            tc_res(t_unk(), st)
        } else {
            let r = typeof_want(st, ret.e, st.ret);
            let rk: long = st.ret.k;
            if (rk == K.tinfer) {
                // The def's return type is still being inferred: note the
                // value's type, which typeof_def checks once the body's
                // trailing type is known. A bare `return;` returns nothing,
                // so as the body's tail it makes the def void.
                ret_note(st.ret, r.typ, ret.line, ret.col);
                tc_res(r.typ, r.st)
            } else {
                st = expect_cast(r.st, r.typ, st.ret, "'return'", ret.line, ret.col);
                if (rk == K.tunk) { tc_res(r.typ, st) } else { tc_res(st.ret, st) }
            }
        }
    } else if (k == K.rec) {
        // Record literal { k: v, ... }: every value checked, the type is a
        // trec with field names in order.
        let rec: RecLit = node;
        let mkeys: [str] = rec.keys;
        let mvals: [Node] = rec.vals;
        if (len(mkeys) == 0) {
            // The empty literal `{}` is an empty record ({} prints as {}).
            // Under a map annotation it IS the map instead -- that adoption
            // happens in typeof_decl (and the emitter lowers it there).
            let empty: [Field] = [];
            tc_res(type_node({ k: K.trec, fields: empty }), st)
        } else {
            let fields: [Field] = [];
            let i = 0;
            let ok = true;
            while (i < len(mkeys)) {
                // NOTE: each bound once — flow-snapshot: `vals` is a bare
                // node field, so reading `mvals[i]` inline would re-read the
                // node through whatever shape the env holds for it.
                let mvv = mvals[i];
                let mkey = mkeys[i];
                let r = typeof_expr(st, mvv);
                st = r.st;
                if (mkey == "...") {
                    // Static spread `...obj`: the union of the two shapes
                    // (field_merge: later wins the value, first appearance
                    // keeps the position). No dynamic shape is involved.
                    if (r.typ.k == K.trec) {
                        let record: TRec = r.typ;
                        let sfs: [Field] = record.fields;
                        let si = 0;
                        while (si < len(sfs)) {
                            let sf = sfs[si];
                            fields = field_merge(fields, sf.name, sf.typ);
                            si = si + 1;
                        };
                    } else if (r.typ.k == K.tunk || r.typ.k == K.tnone || r.typ.k == K.tname) {
                        // poison quietly (tcompat law)
                        ok = false;
                    } else {
                        st = fail(st, "'...' spread needs a record, got " + tstr(r.typ), rec.line, rec.col);
                        ok = false;
                    };
                } else if (r.typ.k == K.tnone) {
                    // unannotated value shape (tcompat law): the missing
                    // annotation errors once at its own site; don't cascade
                    // here, but poison the record so uses don't mistype.
                    ok = false;
                } else if (r.typ.k == K.tname) {
                    ok = false;
                } else if (!is_value_type(r.typ)) {
                    st = fail(st, "record field '" + mkey + "' has unsupported type " + tstr(r.typ), rec.line, rec.col);
                    ok = false;
                }
                if (mkey == "...") {
                } else {
                    fields = field_merge(fields, mkey, r.typ);
                };
                i = i + 1;
            };
            if (ok) {
                tc_res(type_node({ k: K.trec, fields: fields }), st)
            } else {
                tc_res(t_unk(), st)
            }
        }
    } else if (k == K.map) {
        let map: RecLit = node;
        // Map literal { "k": v, ... }: quoted keys (so the key type is
        // str), homogeneous values -- the first entry's type wins and
        // later entries must match. Duplicate keys collapse at emit time
        // (last entry wins the value, first appearance the position).
        // Spread is record-only.
        let gkeys: [str] = map.keys;
        let gvals: [Node] = map.vals;
        let gok = true;
        let gi = 0;
        let gt: Type = t_unk();
        while (gi < len(gvals)) {
            let gk: str = gkeys[gi];
            let gr = typeof_expr(st, gvals[gi]);
            st = gr.st;
            if (gk == "...") {
                st = fail(st, "'...' spread is record-only (a map literal takes key: value entries)", map.line, map.col);
                gok = false;
            } else if (gi == 0) {
                gt = gr.typ;
            } else {
                st = expect_type(st, gr.typ, gt, "map value", map.line, map.col);
            };
            gi = gi + 1;
        };
        if (gok) {
            tc_res(map_type_of(gt), st)
        } else {
            tc_res(t_unk(), st)
        }
    } else if (k == K.dot) {
        let dot: Dot = node;
        // Record field read: obj must be a trec with that field.
        // NOTE: flow-snapshot (dobj/dkey bound once, never rebound): the
        // checker env is flow-INSENSITIVE (last shape wins per name), so a
        // field read must go through a name bound to exactly one shape.
        // Re-reading `node.obj` after any `node = ...` rebind in the same
        // function would resolve against the rebound shape.
        let dobj = dot.obj;
        let dkey = dot.key;
        let r = typeof_expr(st, dobj);
        typeof_field(r.st, r.typ, dkey, dot.line, dot.col)
    } else if (k == K.func) {
        let func: Func = node;
        // Anonymous function literal in expression position. Check the body
        // like a named def would be, and give the expression its tfunc type;
        // the emitter closure-converts it with a generated label.
        let ra = typeof_def(st, "", func, func.line, func.col, func.line, func.col, false);
        tc_res(ra.typ, ra.st)
    } else if (k == K.arrrep) {
        let rep: ArrRep = node;
        // [v; n]: n stack slots filled with v (the native array form)
        let r = typeof_expr(st, rep.v);
        st = r.st;
        if (!is_value_type(r.typ)) {
            st = fail(st, "array element type " + tstr(r.typ) + " is unsupported in native mode", rep.line, rep.col);
            tc_res(t_unk(), st)
        } else {
            // n is a literal from 0 to 2^31 - 1 (parser.y size_lit)
            tc_res(type_node({ k: K.tarrfix, of: r.typ, n: rep.n }), st)
        }
    } else if (k == K.index) {
        let index: Index = node;
        // A plain-variable base (the `id` arm) and an arbitrary expression
        // base (the else arm: `grid[0][1]`, `rec.v[i]`, `f()[i]`) both work.
        // Plain locals, params, AND function params of array type alike: the
        // frame slot or the heap header addresses them directly; bounds are
        // checked at runtime. Fixed [T; N] and heap [T] alike. Params of
        // tunk (missing annotation) error elsewhere — here they poison
        // quietly to avoid cascades.
        if (index.arr.k == K.id) {
            let id: Leaf = index.arr;
            let got = lookup(st.bindings, id.v);
            if (got.kind == "") {
                st = fail(st, "undefined variable '" + id.v + "'", index.line, index.col);
                tc_res(t_unk(), st)
            } else if (got.typ.k == K.tarrfix || got.typ.k == K.tarr) {
                st = check_visible(st, got, id.v, index.line, index.col);
                let r = typeof_expr(st, index.idx);
                st = r.st;
                st = expect_type(st, r.typ, type_node({ k: K.tlong }), "array index", index.line, index.col);
                let elem: Type = t_unk();
                if (got.typ.k == K.tarr) { let arr: TOf = got.typ; elem = arr.of; }
                else { let arr: TFix = got.typ; elem = arr.of; };
                tc_res(elem, st)
            } else if (got.typ.k == K.tmap) {
                // m[k]: the key must match K; a read is ALWAYS optional --
                // V? for any V (none when the key is missing).
                st = check_visible(st, got, id.v, index.line, index.col);
                let map: TMap = got.typ;
                let r = typeof_expr(st, index.idx);
                st = r.st;
                st = expect_type(st, r.typ, map.key, "map key", index.line, index.col);
                tc_res(type_node({ k: K.topt, of: map.of }), st)
            } else if (got.typ.k == K.tstr) {
                // s[i]: the byte at i (trapped when out of bounds)
                st = check_visible(st, got, id.v, index.line, index.col);
                let r = typeof_expr(st, index.idx);
                st = r.st;
                st = expect_type(st, r.typ, type_node({ k: K.tlong }), "string index", index.line, index.col);
                tc_res(type_node({ k: K.tbyte }), st)
            } else if (got.typ.k == K.tunk || got.typ.k == K.tnone || got.typ.k == K.tname) {
                let r = typeof_expr(st, index.idx);
                st = r.st;
                tc_res(t_unk(), st)
            } else {
                st = fail(st, "cannot index " + tstr(got.typ) + " (only arrays and maps)", index.line, index.col);
                tc_res(t_unk(), st)
            }
        } else {
            // Any expression of array type: `grid[0][1]`, `rec.v[i]`,
            // `f()[i]`. The base runs once at runtime; its static type
            // carries the element type.
            let barr = index.arr;
            let br = typeof_expr(st, barr);
            st = br.st;
            if (br.typ.k == K.tarrfix || br.typ.k == K.tarr) {
                let ri = typeof_expr(st, index.idx);
                st = ri.st;
                st = expect_type(st, ri.typ, type_node({ k: K.tlong }), "array index", index.line, index.col);
                let elem: Type = t_unk();
                if (br.typ.k == K.tarr) { let arr: TOf = br.typ; elem = arr.of; }
                else { let arr: TFix = br.typ; elem = arr.of; };
                tc_res(elem, st)
            } else if (br.typ.k == K.tmap) {
                let map: TMap = br.typ;
                let ri = typeof_expr(st, index.idx);
                st = ri.st;
                st = expect_type(st, ri.typ, map.key, "map key", index.line, index.col);
                tc_res(type_node({ k: K.topt, of: map.of }), st)
            } else if (br.typ.k == K.tstr) {
                let ri = typeof_expr(st, index.idx);
                st = ri.st;
                st = expect_type(st, ri.typ, type_node({ k: K.tlong }), "string index", index.line, index.col);
                tc_res(type_node({ k: K.tbyte }), st)
            } else if (br.typ.k == K.tunk || br.typ.k == K.tnone || br.typ.k == K.tname) {
                // poison quietly (tcompat law) — the missing annotation
                // reports at its own site.
                let ri = typeof_expr(st, index.idx);
                st = ri.st;
                tc_res(t_unk(), st)
            } else if (br.typ.k == K.tvoid && (barr.k == K.kw_if || barr.k == K.block)) {
                // An `if` or a block in expression position, with no value:
                // `if (c) { A }["k"]` indexes the `if`, and A's arms are
                // statements (or disagree, so the `if` is void), so there is
                // nothing there to index. As the ordinary message it names
                // neither the base nor the fix, and nothing near it in the
                // source shows an index of an `if` — the `[` reads as a
                // literal. Name the base and the `;`.
                st = fail(st, "cannot index this '" + ktag(barr.k) + "', which has no value: add a ';' after it to make it a statement", index.line, index.col);
                tc_res(t_unk(), st)
            } else {
                st = fail(st, "cannot index " + tstr(br.typ) + " (only arrays and maps)", index.line, index.col);
                tc_res(t_unk(), st)
            }
        }
    } else if (k == K.slice) {
        let slice: Slice = node;
        // arr[lo:hi] -> a new array of the same element type. Missing
        // bounds default to 0 / len; the result is always a heap [T],
        // even when slicing a fixed [T; N].
        let sr = typeof_expr(st, slice.arr);
        st = sr.st;
        let slo: Node = slice.lo;
        let shi: Node = slice.hi;
        if (slo.k == K.void) { } else {
            let rl = typeof_expr(st, slo);
            st = expect_type(rl.st, rl.typ, type_node({ k: K.tlong }), "slice start", slice.line, slice.col);
        };
        if (shi.k == K.void) { } else {
            let rh = typeof_expr(st, shi);
            st = expect_type(rh.st, rh.typ, type_node({ k: K.tlong }), "slice end", slice.line, slice.col);
        };
        if (sr.typ.k == K.tarr) {
            let arr: TOf = sr.typ;
            tc_res(type_node({ k: K.tarr, of: arr.of }), st)
        } else if (sr.typ.k == K.tarrfix) {
            let arr: TFix = sr.typ;
            tc_res(type_node({ k: K.tarr, of: arr.of }), st)
        } else if (sr.typ.k == K.tstr) {
            // s[lo:hi] -> the substring (bounds clamped, like an array slice)
            tc_res(type_node({ k: K.tstr }), st)
        } else if (sr.typ.k == K.tunk) {
            tc_res(t_unk(), st)
        } else {
            st = fail(st, "cannot slice " + tstr(sr.typ) + " (only arrays)", slice.line, slice.col);
            tc_res(t_unk(), st)
        }
    } else if (k == K.dotassign) {
        let assign: DotAssign = node;
        // s.f = v — in-place record field write. The object may be a plain
        // variable (`id` arm) or any record-valued expression (`a[0].f`,
        // `x.y.f` — else arm); the field must exist in its static shape
        // (checked at the record literal / annotation site).
        if (assign.obj.k == K.id) {
            let id: Leaf = assign.obj;
            let got = lookup(st.bindings, id.v);
            if (got.kind == "") {
                st = fail(st, "undefined variable '" + id.v + "'", assign.line, assign.col);
                tc_res(t_unk(), st)
            } else if (unfold(got.typ).k == K.trec) {
                let ft = trec_field_type(unfold(got.typ), assign.key);
                if (ft.k == K.tnone) {
                    st = fail(st, "record has no field '" + assign.key + "'", assign.line, assign.col);
                    tc_res(t_unk(), st)
                } else {
                    let v = typeof_want(st, assign.v, ft);
                    st = v.st;
                    st = expect_type(st, v.typ, ft, "record field '" + assign.key + "'", assign.line, assign.col);
                    tc_res(ft, st)
                }
            } else if (unfold(got.typ).k == K.tunion) {
                dotassign_union(st, unfold(got.typ), assign)
            } else {
                st = fail(st, "cannot field-assign " + tstr(got.typ) + " (only records)", assign.line, assign.col);
                tc_res(t_unk(), st)
            }
        } else {
            // General object (`a[0].f = v`, `x.y.f = v`): the object
            // expression's static type must be a record with the field.
            let dobj2 = assign.obj;
            let obr = typeof_expr(st, dobj2);
            st = obr.st;
            if (obr.typ.k == K.trec) {
                let ft = trec_field_type(obr.typ, assign.key);
                if (ft.k == K.tnone) {
                    st = fail(st, "record has no field '" + assign.key + "'", assign.line, assign.col);
                    tc_res(t_unk(), st)
                } else {
                    let v = typeof_want(st, assign.v, ft);
                    st = v.st;
                    st = expect_type(st, v.typ, ft, "record field '" + assign.key + "'", assign.line, assign.col);
                    tc_res(ft, st)
                }
            } else if (obr.typ.k == K.tunion) {
                dotassign_union(st, obr.typ, assign)
            } else {
                st = fail(st, "cannot field-assign " + tstr(obr.typ) + " (only records)", assign.line, assign.col);
                tc_res(t_unk(), st)
            }
        }
    } else if (k == K.idxassign) {
        let assign: IdxAssign = node;
        if (assign.arr.k == K.id) {
            let id: Leaf = assign.arr;
            let got = lookup(st.bindings, id.v);
            if (got.kind == "") {
                st = fail(st, "undefined variable '" + id.v + "'", assign.line, assign.col);
                tc_res(t_unk(), st)
            } else if (got.typ.k == K.tarrfix || got.typ.k == K.tarr) {
                st = check_visible(st, got, id.v, assign.line, assign.col);
                let ix = typeof_expr(st, assign.idx);
                st = ix.st;
                st = expect_type(st, ix.typ, type_node({ k: K.tlong }), "array index", assign.line, assign.col);
                let elem: Type = t_unk();
                if (got.typ.k == K.tarr) { let arr: TOf = got.typ; elem = arr.of; }
                else { let arr: TFix = got.typ; elem = arr.of; };
                let v = typeof_want(st, assign.v, elem);
                st = v.st;
                st = expect_type(st, v.typ, elem, "array element", assign.line, assign.col);
                tc_res(elem, st)
            } else if (got.typ.k == K.tmap) {
                let map: TMap = got.typ;
                // m[k] = v: the key matches K and the value V (the store is
                // in place -- every alias of the map sees it).
                st = check_visible(st, got, id.v, assign.line, assign.col);
                let ix = typeof_expr(st, assign.idx);
                st = ix.st;
                st = expect_type(st, ix.typ, map.key, "map key", assign.line, assign.col);
                let v = typeof_want(st, assign.v, map.of);
                st = v.st;
                st = expect_type(st, v.typ, map.of, "map value", assign.line, assign.col);
                tc_res(map.of, st)
            } else {
                st = fail(st, "cannot index " + tstr(got.typ) + " (only arrays and maps)", assign.line, assign.col);
                tc_res(t_unk(), st)
            }
        } else {
            // General base (`grid[0][1] = v`, `rec.v[i] = v`): the base
            // expression's static type must be an array of the value type.
            let barr = assign.arr;
            let br = typeof_expr(st, barr);
            st = br.st;
            if (br.typ.k == K.tarrfix || br.typ.k == K.tarr) {
                let ix = typeof_expr(st, assign.idx);
                st = ix.st;
                st = expect_type(st, ix.typ, type_node({ k: K.tlong }), "array index", assign.line, assign.col);
                let elem: Type = t_unk();
                if (br.typ.k == K.tarr) { let arr: TOf = br.typ; elem = arr.of; }
                else { let arr: TFix = br.typ; elem = arr.of; };
                let v = typeof_want(st, assign.v, elem);
                st = v.st;
                st = expect_type(st, v.typ, elem, "array element", assign.line, assign.col);
                tc_res(elem, st)
            } else if (br.typ.k == K.tmap) {
                let map: TMap = br.typ;
                let ix = typeof_expr(st, assign.idx);
                st = ix.st;
                st = expect_type(st, ix.typ, map.key, "map key", assign.line, assign.col);
                let v = typeof_want(st, assign.v, map.of);
                st = v.st;
                st = expect_type(st, v.typ, map.of, "map value", assign.line, assign.col);
                tc_res(map.of, st)
            } else if (br.typ.k == K.tunk || br.typ.k == K.tnone || br.typ.k == K.tname) {
                // poison quietly (tcompat law) — the missing annotation
                // reports at its own site.
                let ix = typeof_expr(st, assign.idx);
                st = ix.st;
                let v = typeof_expr(st, assign.v);
                st = v.st;
                tc_res(t_unk(), st)
            } else {
                st = fail(st, "cannot index " + tstr(br.typ) + " (only arrays and maps)", assign.line, assign.col);
                tc_res(t_unk(), st)
            }
        }
    } else if (k == K.array) {
        let array: ArrLit = node;
        // Heap dynamic array literal [v, ...]. Element type = first element;
        // [] needs an annotation ([T]) since there is nothing to infer from.
        // NOTE: tnone/tname element shapes (from unannotated subexpressions)
        // unify quietly here — the missing-annotation error fires once at
        // its own site, not again at every enclosing literal (tcompat law).
        let elems: [Node] = array.elems;
        if (len(elems) == 0) {
            tc_res(type_node({ k: K.tarr, of: t_free() }), st)
        } else {
            let e0 = elems[0];
            let r0 = typeof_expr(st, e0);
            st = r0.st;
            if (r0.typ.k == K.tnone) {
                tc_res(type_node({ k: K.tarr, of: t_unk() }), st)
            } else if (r0.typ.k == K.tname) {
                tc_res(type_node({ k: K.tarr, of: t_unk() }), st)
            } else if (r0.typ.k != K.tunk && t_poisoned(r0.typ)) {
                // A nested literal that already reported its own error: its
                // type is [[<error>]], and checking later elements against it
                // would only echo that error back. Report once, here.
                tc_res(type_node({ k: K.tarr, of: r0.typ }), st)
            } else if (!is_value_type(r0.typ)) {
                st = fail(st, "array element type " + tstr(r0.typ) + " is unsupported in native mode", array.line, array.col);
                tc_res(t_unk(), st)
            } else {
                let i = 1;
                // A nested literal [[..], ..] lands here too: the inner
                // literal type IS known, so it becomes the element type
                // ([[1], [2]] : [[long]]) and every later element is
                // checked against it. It used to return early with the
                // inner type and check nothing, so [[1], 2] compiled and
                // then read element 1 as an array.
                let elt = r0.typ;
                while (i < len(elems)) {
                    let r = typeof_expr(st, elems[i]);
                    st = r.st;
                    // NOTE: tnone/tname/poison shapes unify quietly (tcompat
                    // law) — the root cause errors once at its own site.
                    // A poisoned FIRST element (tunk) adopts the first later
                    // long/bool/str element so [f(x), 1] reports only f's own
                    // error (a float/byte/record there leaves the element type
                    // poison, which still unifies quietly downstream).
                    if (elt.k == K.tunk) {
                        if (r.typ.k == K.tlong) { elt = r.typ; }
                        if (r.typ.k == K.tbool) { elt = r.typ; }
                        if (r.typ.k == K.tstr) { elt = r.typ; }
                    } else {
                        st = expect_type(st, r.typ, elt, "array element", array.line, array.col);
                    };
                    i = i + 1;
                };
                tc_res(type_node({ k: K.tarr, of: elt }), st)
            }
        }
    } else if (k == K.char) {
        tc_res(type_node({ k: K.tbyte }), st)
    } else if (k == K.rectest) {
        let test: Narrow = node;
        typeof_rectest(st, test)
    } else if (k == K.narrow) {
        let narrow: Narrow = node;
        typeof_narrow(st, narrow)
    } else if (k == K.matchend) {
        let matchend: MatchEnd = node;
        typeof_matchend(st, matchend)
    } else if (k == K.sliceassign) {
        let assign: SliceAssign = node;
        typeof_sliceassign(st, assign)
    } else {
        st = fail(st, "'" + ktag(k) + "' is not a supported expression form", node.line, node.col);
        tc_res(t_unk(), st)
    }
};

// `T` / `{f: v}` pattern test: the subject must be a record or a union,
// and the pattern must be able to match one of its members.
def typeof_rectest(st: TcSt, node: Narrow) -> TcRes {
    let r = typeof_expr(st, node.e);
    st = r.st;
    let s = r.typ;
    let t = node.typ;
    let sk: long = s.k;
    let tu = unfold(t);
    let tk: long = tu.k;
    if (tk == K.tunk) {
        // an alias that stands for no type (rename.y reported it)
    } else if (tk != K.trec && tk != K.tpat) {
        st = fail(st, "match pattern type " + tstr(t) + " is not a record type", node.line, node.col);
    } else if (sk == K.tunk) {
    } else if (sk == K.trec || sk == K.tunion) {
        if (tk == K.tpat) {
            let nt = narrow_type(s, t);
            if (nt.k == K.tunk) {
                st = fail(st, "no record in " + tstr(s) + " has the fields of pattern " + tstr(t), node.line, node.col);
            }
        } else if (!pattern_fits(s, t)) {
            st = fail(st, "pattern type " + tstr(t) + " can never match " + tstr(s), node.line, node.col);
        }
    } else {
        st = fail(st, "cannot match a record pattern against " + tstr(s), node.line, node.col);
    };
    tc_res(type_node({ k: K.tbool }), st)
};

// The record type t is the subject s (a record) or one of its members (a
// union): membership is exact.
def pattern_fits(s: Type, t: Type) -> bool {
    let sk: long = s.k;
    if (sk == K.tunion) {
        let m = union_member(s, t);
        m.k != K.tnone
    } else {
        teq(s, t)
    }
};

def typeof_narrow(st: TcSt, node: Narrow) -> TcRes {
    // errors about the pattern itself are reported once, by its rectest
    let r = typeof_expr(st, node.e);
    let t = node.typ;
    let tu = unfold(t);
    let tk: long = tu.k;
    if (tk == K.trec || tk == K.tpat) {
        tc_res(narrow_type(r.typ, t), r.st)
    } else {
        tc_res(t_unk(), r.st)
    }
};

// The fall-through of a match without `_`: every member of the subject's
// union (or the subject's record type) must be covered by a type arm.
// Value arms (`({f: 1}) x`, `1`, `"s"`) never count: they match only the
// values they name, so when the match has any (`vals`), the error says so.
// Its type is the poison tunk, so it never disagrees with the arms.
def typeof_matchend(st: TcSt, node: MatchEnd) -> TcRes {
    let r = typeof_expr(st, node.e);
    st = r.st;
    let s = r.typ;
    let sk: long = s.k;
    let cover: [Type] = node.cover;
    let hint = "";
    if (node.vals > 0) { hint = "; value patterns match only the values they name and cover no type"; };
    if (sk == K.tunk) {
    } else if (sk == K.tunion) {
        let ms = members(s);
        let missing: [str] = [];
        let i = 0;
        while (i < len(ms)) {
            if (!covered(ms[i], cover)) { missing += tstr(ms[i]); }
            i = i + 1;
        };
        if (len(missing) > 0) {
            st = fail(st, "non-exhaustive match: nothing matches " + join(missing, ", ") + " (add an arm or '_'" + hint + ")", node.line, node.col);
        }
    } else if (sk == K.trec && covered(s, cover)) {
    } else {
        st = fail(st, "non-exhaustive match on " + tstr(s) + " (add a '_' arm" + hint + ")", node.line, node.col);
    };
    tc_res(t_unk(), st)
};

// A member is covered by a type arm of its type.
def covered(m: Type, cover: [Type]) -> bool {
    let any = false;
    let i = 0;
    while (i < len(cover)) {
        let c = unfold(cover[i]);
        let ck: long = c.k;
        if (ck == K.trec) {
            if (teq(m, c)) { any = true; }
        }
        i = i + 1;
    };
    any
};

// a[lo:hi] = src: a is an array, src an array of the same element type.
def typeof_sliceassign(st: TcSt, node: SliceAssign) -> TcRes {
    let ar = typeof_expr(st, node.arr);
    st = ar.st;
    let slo = node.lo;
    let shi = node.hi;
    if (slo.k == K.void) { } else {
        let rl = typeof_expr(st, slo);
        st = expect_type(rl.st, rl.typ, { k: K.tlong }, "slice start", node.line, node.col);
    };
    if (shi.k == K.void) { } else {
        let rh = typeof_expr(st, shi);
        st = expect_type(rh.st, rh.typ, { k: K.tlong }, "slice end", node.line, node.col);
    };
    let vr = typeof_expr(st, node.v);
    st = vr.st;
    let at: Type = ar.typ;
    let vt: Type = vr.typ;
    let akk: long = at.k;
    let vkk: long = vt.k;
    if (akk == K.tarr || akk == K.tarrfix) {
        if (vkk == K.tarr || vkk == K.tarrfix) {
            let ae: Type = t_unk();
            let ve: Type = t_unk();
            if (akk == K.tarr) { let arr: TOf = at; ae = arr.of; }
            else { let arr: TFix = at; ae = arr.of; };
            if (vkk == K.tarr) { let arr: TOf = vt; ve = arr.of; }
            else { let arr: TFix = vt; ve = arr.of; };
            if (teq(ve, ae)) { } else {
                st = fail(st, "slice assignment: cannot store " + tstr(vt) + " into " + tstr(at), node.line, node.col);
            };
        } else if (vkk == K.tunk) {
        } else {
            st = fail(st, "slice assignment needs an array on the right, got " + tstr(vt), node.line, node.col);
        };
    } else if (akk == K.tstr) {
        st = fail(st, "cannot assign to a slice of str (strings are immutable)", node.line, node.col);
    } else if (akk == K.tunk) {
    } else {
        st = fail(st, "cannot slice-assign " + tstr(at) + " (only arrays)", node.line, node.col);
    };
    tc_res(type_node({ k: K.tvoid }), st)
};

// The type of field `dkey` read from a value of type t: a record field,
// or a built-in property of an array or a str. The dot arm of typeof_expr
// is this after typing its object; typeof_call uses it directly for a
// callee `x.f(...)`, so the receiver is typed once whether or not it turns
// out to be a str (a string method) or a record (a field holding a
// function).
def typeof_field(st: TcSt, t: Type, dkey: str, line: long, col: long) -> TcRes {
    if (t.k == K.trec) {
        let found = false;
        let ftyp: Type = t_unk();
        let rec: TRec = t;
        let fs: [Field] = rec.fields;
        let j = 0;
        while (j < len(fs)) {
            // NOTE: bound once (flow-snapshot, see the dot arm's note).
            // NOTE: :str bindings (see teq note).
            let f = fs[j];
            let fn: str = f.name;
            if (fn == dkey) {
                found = true;
                ftyp = f.typ;
            };
            j = j + 1;
        };
        if (found) {
            tc_res(ftyp, st)
        } else {
            st = fail(st, "record has no field '" + dkey + "'", line, col);
            tc_res(t_unk(), st)
        }
    } else if (t.k == K.tunion) {
        union_field(st, t, dkey, line, col)
    } else if (t.k == K.tunk) {
        tc_res(t_unk(), st)
    } else if (t.k == K.tnone) {
        // bare-hole params (see typeof_def note): unify quietly.
        tc_res(t_unk(), st)
    } else if (t.k == K.tname) {
        tc_res(t_unk(), st)
    } else if (t.k == K.tparams) {
        tc_res(t_unk(), st)
    } else if (t.k == K.tarr || t.k == K.tarrfix || t.k == K.tstr) {
        typeof_prop(st, t, dkey, line, col)
    } else {
        st = fail(st, "cannot read field '" + dkey + "' of " + tstr(t) + " (need a record)", line, col);
        tc_res(t_unk(), st)
    }
};

// Built-in properties: `.length` of an array or a str is len(x); `.ptr` of
// an array is the address of element 0 as a *T -- the data block's address,
// so it is valid for an empty array too, where &a[0] traps. A str has no
// `.ptr`: its bytes can live in read-only .rodata, where a store through
// the pointer would fault.
def typeof_prop(st: TcSt, t: Type, key: str, line: long, col: long) -> TcRes {
    if (key == "length") {
        tc_res(type_node({ k: K.tlong }), st)
    } else if (key == "ptr" && t.k == K.tarr) {
        let arr: TOf = t;
        tc_res(type_node({ k: K.tptr, to: arr.of }), st)
    } else if (key == "ptr" && t.k == K.tarrfix) {
        let arr: TFix = t;
        tc_res(type_node({ k: K.tptr, to: arr.of }), st)
    } else {
        let have = "'.length' and '.ptr'";
        if (t.k == K.tstr) { have = "'.length'"; };
        st = fail(st, tstr(t) + " has no property '" + key + "' (it has " + have + ")", line, col);
        tc_res(t_unk(), st)
    }
};

// ── string methods ───────────────────────────────────────────────────────
// `s.m(args)` with s a str calls a string method: a builtin with the
// receiver as an argument (`s.split(",")` is split(s, ",")), or a helper
// in std/str.y called by label (`s.pad_left(8)` is
// y_str_pad_left(s, 8, " ")). This table is the whole definition; the
// checker (typeof_method) and the emitter (native.y gen_method and
// infer_call) both read it.
//   fn      the builtin, or the helper's label; "" = no such method
//   params  the argument types, receiver excluded
//   nreq    how many are required; the last one may be left out only
//           when nreq is one short, and then `dflt` (a str) is passed
//   ret     the result type
//   last    the receiver goes AFTER the arguments (`sep.join(xs)` is
//           join(xs, sep))
// A helper's method names must be in native.y str_names: that is what
// splices std/str.y into a program that calls one.
type StrMethod = { fn: str, params: [Type], nreq: long, ret: Type, dflt: str, last: bool };
def str_method(m: str) -> StrMethod {
    let s = sm_t(K.tstr);
    let l = sm_t(K.tlong);
    let b = sm_t(K.tbool);
    let no: [Type] = [];
    if (m == "split") { sm_mk("split", [s], 1, sm_arr(s), "", false) }
    else if (m == "join") { sm_mk("join", [sm_arr(sm_any())], 1, s, "", true) }
    else if (m == "trim" || m == "strip") { sm_mk("trim", no, 0, s, "", false) }
    else if (m == "trim_start" || m == "lstrip") { sm_mk("y_str_trim_start", no, 0, s, "", false) }
    else if (m == "trim_end" || m == "rstrip") { sm_mk("y_str_trim_end", no, 0, s, "", false) }
    else if (m == "pad_left") { sm_mk("y_str_pad_left", [l, s], 1, s, " ", false) }
    else if (m == "pad_right") { sm_mk("y_str_pad_right", [l, s], 1, s, " ", false) }
    else if (m == "center") { sm_mk("y_str_center", [l, s], 1, s, " ", false) }
    else if (m == "starts_with") { sm_mk("y_str_starts_with", [s], 1, b, "", false) }
    else if (m == "ends_with") { sm_mk("y_str_ends_with", [s], 1, b, "", false) }
    else if (m == "contains") { sm_mk("y_str_contains", [s], 1, b, "", false) }
    else if (m == "index_of") { sm_mk("index_of", [s], 1, l, "", false) }
    else if (m == "last_index_of") { sm_mk("last_index_of", [s], 1, l, "", false) }
    else if (m == "count") { sm_mk("y_str_count", [s], 1, l, "", false) }
    else if (m == "replace") { sm_mk("y_str_replace", [s, s], 2, s, "", false) }
    else if (m == "upper") { sm_mk("y_str_upper", no, 0, s, "", false) }
    else if (m == "lower") { sm_mk("y_str_lower", no, 0, s, "", false) }
    else if (m == "repeat") { sm_mk("y_str_repeat", [l], 1, s, "", false) }
    else if (m == "lines") { sm_mk("y_str_lines", no, 0, sm_arr(s), "", false) }
    else if (m == "bytes") { sm_mk("bytes", no, 0, sm_arr(sm_t(K.tbyte)), "", false) }
    else if (m == "tonum") { sm_mk("tonum", no, 0, l, "", false) }
    else if (m == "ord") { sm_mk("ord", no, 0, l, "", false) }
    else if (m == "byte_at") { sm_mk("byte_at", [l], 1, l, "", false) }
    else { sm_mk("", no, 0, t_unk(), "", false) }
};

def sm_mk(fn: str, params: [Type], nreq: long, ret: Type, dflt: str, last: bool) -> StrMethod {
    { fn: fn, params: params, nreq: nreq, ret: ret, dflt: dflt, last: last }
};

def sm_t(k: long) -> Type { { k: k } };

def sm_arr(of: Type) -> Type { { k: K.tarr, of: of } };

// join's array: any element type (sm_accepts; prints as `T`, so an error
// reads "expected [T]").
def sm_any() -> Type { { k: K.tname, name: "T" } };

// `node` is `s.m(args)` with s a str (typed already, by typeof_call).
def typeof_method(st: TcSt, node: Call, m: str) -> TcRes {
    let sm = str_method(m);
    let margs: [Node] = node.args;
    let na = len(margs);
    let ps = sm.params;
    let np = len(ps);
    let what = "'str." + m + "'";
    if (sm.fn == "") {
        let hint = "";
        if (m == "length") { hint = " ('.length' is a property: no parentheses)"; };
        st = fail(st, "str has no method '" + m + "'" + hint, node.line, node.col);
        let i = 0;
        while (i < na) {
            let r = typeof_expr(st, margs[i]);
            st = r.st;
            i = i + 1;
        };
        tc_res(t_unk(), st)
    } else if (na < sm.nreq || na > np) {
        let want = tostring(np);
        if (sm.nreq < np) { want = tostring(sm.nreq) + " or " + tostring(np); };
        st = fail(st, what + " takes " + want + " args, got " + tostring(na), node.line, node.col);
        let i = 0;
        while (i < na) {
            let r = typeof_expr(st, margs[i]);
            st = r.st;
            i = i + 1;
        };
        tc_res(sm.ret, st)
    } else {
        let i = 0;
        while (i < na) {
            let r = typeof_expr(st, margs[i]);
            st = r.st;
            let ak: long = r.typ.k;
            if (ak == K.tvoid) {
                st = fail(st, what + " arg " + tostring(i) + ": cannot pass a void value", node.line, node.col);
            } else if (!sm_accepts(r.typ, ps[i])) {
                st = fail(st, what + " arg " + tostring(i) + ": expected " + tstr(ps[i]) + ", got " + tstr(r.typ), node.line, node.col);
            }
            i = i + 1;
        };
        tc_res(sm.ret, st)
    }
};

// tcompat, except that join's [T] takes an array of any element type (as
// the join builtin does: a [T], or poison).
def sm_accepts(got: Type, want: Type) -> bool {
    if (want.k == K.tarr) {
        let arr: TOf = want;
        if (arr.of.k == K.tname) {
            got.k == K.tarr || got.k == K.tunk
        } else {
            tcompat(got, want)
        }
    } else {
        tcompat(got, want)
    }
};

// `const` fixes the BINDING, not the value (as in JS): `=`, `++`/`--` and
// the `op=` forms that rebind (numbers, strings) are errors on a const name,
// while the in-place array forms (`arr += v`, `arr *= v`) and element or
// field writes (`a[i] = v`, `r.f = v`) still mutate the shared value. Plain
// `=` is refused in the `assign` arm itself; this covers the other two.
def const_check(st: TcSt, tgt: Node, tt: Type, op: str, line: long, col: long) -> TcSt {
    if (tgt.k == K.id) {
        let id: Leaf = tgt;
        let got = lookup(st.bindings, id.v);
        let inplace = tt.k == K.tarr || tt.k == K.tarrfix || tt.k == K.tunk || tt.k == K.tnone;
        if (got.kind == "const" && !inplace) {
            fail(st, "cannot assign to constant '" + disp(id.v) + "' ('" + op + "')", line, col)
        } else { st }
    } else { st }
};

// `++`/`--` and `op=` store back into their target, so it must be a place
// `=` stores to: a variable, an array or map element, or a record field.
// A str's bytes and the `.length`/`.ptr` properties are read-only, as they
// are to `=`. Returns the target's type, or t_unk() after an error, so the
// operator's own rules stay quiet. (`*p = v` is a store of its own; `*p`
// is no target here.) Only a target that can be one of those -- a byte
// element, a `.length` or `.ptr` -- has its base looked at.
def place_check(st: TcSt, tgt: Node, tt: Type, op: str, line: long, col: long) -> TcRes {
    let k: long = tgt.k;
    let ok = true;
    if (k == K.index) {
        let index: Index = tgt;
        if (tt.k == K.tbyte && base_type(st, index.arr).k == K.tstr) {
            st = fail(st, "cannot index str (only arrays and maps)", line, col);
            ok = false;
        };
    } else if (k == K.dot) {
        let dot: Dot = tgt;
        let key: str = dot.key;
        if (tt.k != K.tunk && (key == "length" || key == "ptr")) {
            let bt = base_type(st, dot.obj);
            if (bt.k == K.tarr || bt.k == K.tarrfix || bt.k == K.tstr) {
                st = fail(st, "cannot field-assign " + tstr(bt) + " (only records)", line, col);
                ok = false;
            };
        };
    } else if (k != K.id && k != K.err) {
        st = fail(st, "cannot assign to this expression ('" + op + "')", line, col);
        ok = false;
    };
    if (ok) { tc_res(tt, st) } else { tc_res(t_unk(), st) }
};

// The static type of a place's base (`a` in `a[i]`, `o` in `o.f`). The
// whole target was typed already, its errors reported: a base other than
// a name is typed again on a scratch error list.
def base_type(st: TcSt, e: Node) -> Type {
    if (e.k == K.id) {
        let id: Leaf = e;
        lookup(st.bindings, id.v).typ
    } else {
        let none: [Diag] = [];
        typeof_expr(st_errors(st, none), e).typ
    }
};

// ++/-- target rule: numbers (long/byte/float) only.
def incdec_check(st: TcSt, node: IncDec, tt: Type) -> TcRes {
    let op = node.op;
    if (tt.k == K.tlong || tt.k == K.tbyte || tt.k == K.tfloat) {
        tc_res(tt, st)
    } else if (tt.k == K.tunk || tt.k == K.tnone) {
        tc_res(t_unk(), st)
    } else {
        st = fail(st, "'" + op + "' needs a number target, got " + tstr(tt), node.line, node.col);
        tc_res(t_unk(), st)
    }
};

// `x op= e` rules by target type:
//   numbers  -> the arithmetic family (+ - * / %), result the target type
//   integers -> the bitwise family (& | ^ << >> >>>) too: a long or byte
//               target, an integer value (a byte target keeps the low 8
//               bits, like every byte store)
//   str      -> `+=` concatenates; the rest are errors
//   arrays   -> in place only: `+=` pushes one element (or appends another
//               array of the same type; `[[T]] += [T]` pushes it whole),
//               `*=` prepends one element. `+`
//               itself is the copy form; `-=`, `/=`, `%=` are errors.
// The result is always the target's type (the new value).
def opassign_check(st: TcSt, node: OpAssign, tt: Type, vt: Type) -> TcRes {
    let op = node.op;
    if (is_bits_op(op)) {
        if (tt.k == K.tlong || tt.k == K.tbyte) {
            st = expect_type(st, vt, type_node({ k: K.tlong }), "'" + op + "=' value", node.line, node.col);
            tc_res(tt, st)
        } else if (tt.k == K.tunk || tt.k == K.tnone) {
            tc_res(t_unk(), st)
        } else {
            st = fail(st, "'" + op + "=' needs an integer target, got " + tstr(tt), node.line, node.col);
            tc_res(t_unk(), st)
        }
    } else if (tt.k == K.tarrfix) {
        // A fixed array's length is part of its type: growth is a type
        // error (the old push-on-fixed rejection, now on the operators).
        st = fail(st, "cannot grow fixed array " + tstr(tt) + " with '" + op + "=' (its length is part of its type; use [T] instead)", node.line, node.col);
        tc_res(tt, st)
    } else if (tt.k == K.tarr) {
        if (op == "*") {
            // `*= ` prepends ONE item — its type must be the element type.
            let target: TOf = tt;
            st = expect_type(st, vt, target.of, "'*=' element", node.line, node.col);
            tc_res(tt, st)
        } else if (op == "+") {
            if (vt.k == K.tarr || vt.k == K.tarrfix) {
                if (arr_plus_kind(tt, vt) == "append") {
                    // `[[T]] += [T]` pushes the array as ONE element (the
                    // same rule as `+`, see arr_plus_kind).
                    tc_res(tt, st)
                } else {
                    // `arr += arr2` appends arr2's ELEMENTS in place, so
                    // the element types must match (homogeneity).
                    let target: TOf = tt;
                    let value: Type = t_unk();
                    if (vt.k == K.tarr) { let arr: TOf = vt; value = arr.of; }
                    else { let fixed: TFix = vt; value = fixed.of; };
                    st = expect_type(st, value, target.of, "'+=' appended elements", node.line, node.col);
                    tc_res(tt, st)
                }
            } else if (vt.k == K.tunk || vt.k == K.tnone) {
                tc_res(tt, st)
            } else {
                let target: TOf = tt;
                st = expect_type(st, vt, target.of, "'+=' element", node.line, node.col);
                tc_res(tt, st)
            }
        } else {
            st = fail(st, "arrays support only '+=' and '*=' (in place), not '" + op + "='", node.line, node.col);
            tc_res(tt, st)
        }
    } else if (tt.k == K.tstr) {
        if (op == "+") {
            st = expect_type(st, vt, type_node({ k: K.tstr }), "'+=' string", node.line, node.col);
            tc_res(tt, st)
        } else {
            st = fail(st, "strings support only '+=' (concatenate), not '" + op + "='", node.line, node.col);
            tc_res(tt, st)
        }
    } else if (tt.k == K.tlong || tt.k == K.tbyte || tt.k == K.tfloat) {
        st = expect_type(st, vt, tt, "'" + op + "=' value", node.line, node.col);
        tc_res(tt, st)
    } else if (tt.k == K.tunk || tt.k == K.tnone) {
        tc_res(t_unk(), st)
    } else {
        st = fail(st, "'" + op + "=' needs a number, string or array target, got " + tstr(tt), node.line, node.col);
        { typ: t_unk(), st: st }
    }
};

// ── f-string fields ──────────────────────────────────────────────────────
// lexer.y lex_fstring makes each field of an f-string a call of `#fmt`, a
// name no program can bind: f"{e:spec}" is #fmt(e, "spec"), and f"{e}"
// #fmt(e, "").

// A format spec, Python's mini-language without nested fields:
//   [[fill]align][sign][#][0][width][grouping][.precision][type]
// align < > ^ =, sign + - or a space, grouping `,` or `_`, type one of
// s d x X o b c f F e E %. Bytes, 0 when absent (-1 for the two numbers);
// err is "" when the spec reads.
type FmtSpec = { err: str, fill: long, align: long, sign: long, alt: bool, zero: bool, width: long, grp: long, prec: long, ty: long };
def fmt_spec(spec: str) -> FmtSpec {
    let n = len(spec);
    let i = 0;
    let fill = 0;
    let align = 0;
    if (n >= 2 && fmt_align(byte_at(spec, 1))) {
        fill = byte_at(spec, 0);
        align = byte_at(spec, 1);
        i = 2;
    } else if (n >= 1 && fmt_align(byte_at(spec, 0))) {
        align = byte_at(spec, 0);
        i = 1;
    }
    let sign = 0;
    if (i < n && (byte_at(spec, i) == 43 || byte_at(spec, i) == 45 || byte_at(spec, i) == 32)) {
        sign = byte_at(spec, i);
        i = i + 1;
    }
    let alt = false;
    if (i < n && byte_at(spec, i) == 35) { alt = true; i = i + 1; }
    let zero = false;
    if (i < n && byte_at(spec, i) == 48) { zero = true; i = i + 1; }
    let ws = i;
    while (i < n && fmt_digit(byte_at(spec, i))) { i = i + 1; };
    let width = 0 - 1;
    if (i > ws) { width = fmt_number(spec, ws, i); }
    let grp = 0;
    if (i < n && (byte_at(spec, i) == 44 || byte_at(spec, i) == 95)) {
        grp = byte_at(spec, i);
        i = i + 1;
    }
    let err = "";
    let prec = 0 - 1;
    if (i < n && byte_at(spec, i) == 46) {
        i = i + 1;
        let ps = i;
        while (i < n && fmt_digit(byte_at(spec, i))) { i = i + 1; };
        if (i > ps) { prec = fmt_number(spec, ps, i); } else { err = "'.' without a precision"; };
    }
    let ty = 0;
    if (i < n && fmt_type(byte_at(spec, i))) { ty = byte_at(spec, i); i = i + 1; }
    if (err != "") { }
    else if (i == n - 1) { err = "unknown type '" + spec[i:n] + "'"; }
    else if (i < n) { err = "cannot read '" + spec[i:n] + "'"; }
    else if (width > 99999 || prec > 99999) { err = "width and precision stop at 99999"; }

    { err: err, fill: fill, align: align, sign: sign, alt: alt, zero: zero, width: width, grp: grp, prec: prec, ty: ty }
};

def fmt_align(c: long) -> bool {
    c == c'<' || c == c'>' || c == c'^' || c == c'='
};

def fmt_digit(c: long) -> bool {
    c >= c'0' && c <= c'9'
};

// s d x X o b c f F e E %
def fmt_type(c: long) -> bool {
    c == c's' || c == c'd' || c == c'x' || c == c'X' || c == c'o' || c == c'b'
    || c == c'c' || c == c'f' || c == c'F' || c == c'e' || c == c'E' || c == c'%'
};

// The digits spec[a:b] as a number, stopping short of overflow (a value
// that large is over fmt_spec's limit anyway).
def fmt_number(spec: str, a: long, b: long) -> long {
    let v = 0;
    let i = a;
    while (i < b) {
        if (v < 1000000) { v = v * 10 + byte_at(spec, i) - c'0'; }
        i = i + 1;
    };
    v
};

// How a value formats under a spec: 1 an integer (long, byte), 2 a float,
// 0 anything else -- its tostring text, like a str. NOTE: the parameter is
// the whole Type, not a `{ k: long }` view of it: a record parameter is
// exact, so passing a union-typed `t` would ask the emitter to cast it to
// the one member with a `k` field, and the cast checks at run time -- which
// trapped on every type whose member is not that one (`f"{a:x}"` for an
// array, a record or an option crashed the compiler).
def fmt_kind(t: Type) -> long {
    if (t.k == K.tlong || t.k == K.tbyte) { 1 } else if (t.k == K.tfloat) { 2 } else { 0 }
};

// What is wrong with the spec f for a value of kind `kind` (fmt_kind) and
// type tname: "" when nothing is. Python's rules: a sign, `#`, grouping
// and `=` need a number, a precision is no integer type's, `c` takes no
// sign, `#` or grouping, and `,` groups decimals only.
def fmt_check(f: FmtSpec, kind: long, tname: str) -> str {
    let ty = f.ty;
    let ints = ty == c'd' || ty == c'x' || ty == c'X' || ty == c'o' || ty == c'b' || ty == c'c';
    if (f.err != "") {
        f.err
    } else if (kind == 0) {
        if (ty != 0 && ty != c's') { "type '" + chr(ty) + "' needs a number, not " + tname }
        else if (f.sign != 0) { "a sign needs a number, not " + tname }
        else if (f.alt) { "'#' needs a number, not " + tname }
        else if (f.grp != 0) { "'" + chr(f.grp) + "' needs a number, not " + tname }
        else if (f.align == c'=') { "'=' alignment needs a number, not " + tname }
        else { "" }
    } else if (ty == c's') {
        "type 's' needs a string, not " + tname
    } else if (kind == 2 && ints) {
        "type '" + chr(ty) + "' needs an integer, not " + tname
    } else if (kind == 1 && f.prec >= 0 && (ty == 0 || ints)) {
        "a precision needs a float type (f, e or %), not an integer one"
    } else if (ty == c'c' && (f.sign != 0 || f.alt || f.grp != 0)) {
        "type 'c' takes no sign, '#' or grouping"
    } else if (f.grp == c',' && (ty == c'x' || ty == c'X' || ty == c'o' || ty == c'b')) {
        "',' does not group type '" + chr(ty) + "' (use '_')"
    } else {
        ""
    }
};

// node as a Leaf, or none when it is the err node the parser plants where
// the token stream stopped making sense. Casting one blindly is a CHECKED
// cast and traps, which is how `1 f"{a b}"` killed ycc (a malformed field
// drops the spec argument and leaves the error in its place): the C twin
// reads a field that is simply not there and carries on to three proper
// diagnostics, and so must this side.
def leaf_of(node: Node) -> Leaf? {
    if (node.k == K.err) {
        none
    } else {
        let leaf: Leaf = node;
        some(leaf)
    }
};

// #fmt(e, spec) is a str. Without a spec e is whatever tostring takes;
// with one, the spec has to read and to suit e's type (fmt_check). A spec
// argument that is an err node is reported here -- typeof_expr's own K.err
// arm would have reported it, had the argument gone through it -- and the
// spec itself left alone.
def typeof_fmt(st: TcSt, node: Call) -> TcRes {
    let fargs: [Node] = node.args;
    let r = typeof_expr(st, fargs[0]);
    st = r.st;
    let t: Type = r.typ;
    let sp = leaf_of(fargs[1]);
    let spec: str = if (sp == none) { "" } else { sp!.v };
    if (sp == none) {
        let e: Err = fargs[1];
        st = fail(st, e.msg, e.line, e.col);
    } else if (!(t.k == K.tlong || t.k == K.tbyte || t.k == K.tbool || t.k == K.tstr || t.k == K.tfloat || t.k == K.tunk || t.k == K.tarr || t.k == K.tarrfix || t.k == K.trec || t.k == K.tmap || t.k == K.topt || t.k == K.tunion)) {
        st = fail(st, "an f-string field takes long/bool/float/str/array/record/map/option, got " + tstr(t), node.line, node.col);
    } else if (spec != "") {
        let e = fmt_check(fmt_spec(spec), fmt_kind(t), tstr(t));
        if (e != "") { st = fail(st, "format spec '" + spec + "': " + e, node.line, node.col); }
    }
    tc_res(type_node({ k: K.tstr }), st)
};

// ── the named syscall layer ─────────────────────────────────────────────
// The names std code may reach the kernel through, and the only list of them.
// `os_call` (the checker arm below, native.y's emit arm) resolves a call
// against this list and emits a `call` to the label; the bodies live in
// src/y/arch/prelude.s on Linux and in src/y/arch/wsys.s on Windows.
//
// ONE list, with no target branch, and that is the load-bearing property
// rather than a simplification. The four embedded std units (rt, prelude, exec,
// str) are compiled ONCE per compiler and serialized into a single std pack,
// so anything a std unit resolves at COMPILE time -- a syscall number, a struct
// layout, a branch on the target -- is baked for whichever target wrote that
// pack, and --target on the consuming compiler cannot undo it. A NAME is the one
// thing that survives: rt.y saying os_call("y_os_write", fd, s, len(s))
// compiles to the same bytes for both targets, and the arch module decides
// which kernel call that label is. Measured both ways, with a conditional in
// rt.y instead: a PE built from the pack carried the ELF inline write(2) and
// printed nothing, while --std-src (which recompiles the units) worked.
//
// The list lives here, beside the checker that enforces it, because types.y is
// the one module that must not import arch_x64.y: a path import is flattened
// into its importer, so both would define the same names and the second would
// win. native.y, which sees both, checks that every name here is a label the
// emitted arch lines actually define (native.y check_os_call_names).
def os_call_name(nm: str) -> bool {
    let names = os_call_names();
    let i = 0;
    let found = false;
    while (i < len(names)) {
        if (names[i] == nm) { found = true; };
        i = i + 1;
    };
    found
};

def os_call_names() -> [str] {
    ["y_os_write", "y_os_read", "y_os_lseek", "y_os_clock_gettime",
     "y_os_nanosleep", "y_os_wait4", "y_os_fork", "y_os_execve",
     "y_os_openat", "y_os_close"]
};


// The call's own type, recorded at the CALLEE's position when the index is on.
//
// An intrinsic is matched by name inside the body below, so its callee identifier
// is never an expression and `typeof_expr` never visits it -- which is why hovering
// `clock_us` showed nothing at all while hovering a call's RESULT showed its type
// perfectly. The return type is what is recorded, because that is what the name
// means to a reader at that position; the argument types are in the manual and in
// the compiler, and inventing a signature string here would be a second copy of
// knowledge that already exists.
def typeof_call(st: TcSt, node: Call) -> TcRes {
    let r = typeof_call_go(st, node);
    if (tc_index) {
        let callee: Node = node.callee;
        // A DOT callee records its own function type at the key's position in the
        // `!id` arm below, where the signature is known; here only an id is filled
        // in, so the two do not fight over one key.
        if (callee.k == K.id) {
            let leaf: Leaf = callee;
            if (leaf.line > 0 && leaf.col > 0) { tci_note_key(leaf.line * 65536 + leaf.col, r.typ); };
        };
    };
    r
}

def typeof_call_go(st: TcSt, node: Call) -> TcRes {
    // Two callee shapes: a plain id (the `else` arm below — a hoisted def,
    // an intrinsic, `self`, or a local holding a closure) and an arbitrary
    // expression (the `if` arm — an immediately-invoked literal, an element
    // of an array of functions, ...).
    let cargs: [Node] = node.args;
    let callee: Node = node.callee;
    if (callee.k != K.id) {
        // Calling an expression: legal when it yields a function value
        // (an immediately-invoked literal, an element of an array of
        // functions, a record field holding one, ...). The emitter goes
        // through its code pointer. `x.m(...)` with x a str is a string
        // method instead (typeof_method); either way the receiver is
        // typed once, here.
        let ccal: Node = callee;
        let cf: TcRes = { typ: t_unk(), st: st };
        let smeth = false;
        if (ccal.k == K.dot) {
            let dot: Dot = ccal;
            let crt = typeof_expr(st, dot.obj);
            if (crt.typ.k == K.tstr) {
                smeth = true;
                cf = { typ: t_unk(), st: crt.st };
            } else {
                cf = typeof_field(crt.st, crt.typ, dot.key, dot.line, dot.col);
            };
        } else {
            cf = typeof_expr(st, ccal);
        };
        st = cf.st;
        // A member call's own type, at the member NAME's position -- so hovering
        // `exp` in `math.exp(0.0)` answers rather than showing nothing. Before this,
        // `math.pi` answered `float` (a constant needs no extern) while every
        // imported FUNCTION answered nothing, which is the shape of a bug that reads
        // as "imports are not typed" and is really "calls are not indexed".
        //
        // The SIGNATURE, because the field's own type IS the function type here and
        // it is what the name means. Recording the call's RETURN type instead made
        // `mk` hover as `{ a: long, b: str }` -- the record `mk(1, "x")` produces --
        // which reads as though `mk` were that record. An intrinsic has no such
        // object (it is matched by name), so the id arm in `typeof_call` records its
        // return type, which is the whole of what the checker knows about it; the
        // asymmetry is the honest one and both are the checker's own answer.
        if (tc_index && ccal.k == K.dot && !smeth) {
            let cdot: Dot = ccal;
            if (cdot.nline > 0 && cdot.ncol > 0) { tci_note_key(cdot.nline * 65536 + cdot.ncol, cf.typ); };
        };
        if (smeth) {
            let dot: Dot = ccal;
            typeof_method(st, node, dot.key)
        } else if (cf.typ.k == K.tfunc) {
            let cft: TFunc = cf.typ;
            let cfargs: [Type] = cft.args;
            if (len(cargs) != len(cfargs)) {
                st = fail(st, "call takes " + tostring(len(cfargs)) + " args, got " + tostring(len(cargs)), node.line, node.col);
                tc_res(cft.ret, st)
            } else {
                let ci = 0;
                while (ci < len(cargs)) {
                    let ra = typeof_want(st, cargs[ci], cfargs[ci]);
                    st = ra.st;
                    st = expect_cast(st, ra.typ, cfargs[ci], "call arg " + tostring(ci), node.line, node.col);
                    ci = ci + 1;
                };
                tc_res(cft.ret, st)
            }
        } else {
            st = fail(st, "cannot call " + tstr(cf.typ) + " (not a function)", node.line, node.col);
            let i = 0;
            while (i < len(node.args)) {
                let r = typeof_expr(st, cargs[i]);
                st = r.st;
                i = i + 1;
            };
            tc_res(t_unk(), st)
        }
    } else {
        let id: Leaf = callee;
        let name = id.v;
        if (name == "#fmt") {
            typeof_fmt(st, node)
        } else if (name == "print") {
            if (len(node.args) != 1) {
                st = fail(st, "print takes exactly 1 argument", node.line, node.col);
                tc_res(type_node({ k: K.tvoid }), st)
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                if (r.typ.k == K.tlong || r.typ.k == K.tbyte || r.typ.k == K.tbool || r.typ.k == K.tstr || r.typ.k == K.tfloat || r.typ.k == K.tunk || r.typ.k == K.trec || r.typ.k == K.tmap || r.typ.k == K.tfunc || r.typ.k == K.tarr || r.typ.k == K.tarrfix || r.typ.k == K.topt || r.typ.k == K.tunion) {
                    tc_res(type_node({ k: K.tvoid }), st)
                } else {
                    st = fail(st, "print supports long/bool/float/str/array/record/map/option, got " + tstr(r.typ), node.line, node.col);
                    tc_res(type_node({ k: K.tvoid }), st)
                }
            }
        } else if (name == "keys") {
            // keys(m) -> [K]: the keys of map m in insertion order, a copy
            if (len(cargs) != 1) {
                st = fail(st, "keys takes exactly 1 argument", node.line, node.col);
                tc_res(t_unk(), st)
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                let mt = unfold(r.typ);
                if (mt.k == K.tmap) {
                    let map: TMap = mt;
                    tc_res(type_node({ k: K.tarr, of: map.key }), st)
                } else if (mt.k == K.tunk) {
                    tc_res(t_unk(), st)
                } else {
                    st = fail(st, "keys needs a map, got " + tstr(r.typ), node.line, node.col);
                    tc_res(t_unk(), st)
                }
            }
        } else if (name == "len") {
            if (len(cargs) != 1) {
                st = fail(st, "len takes exactly 1 argument", node.line, node.col);
                tc_res(type_node({ k: K.tlong }), st)
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                if (r.typ.k == K.tarrfix || r.typ.k == K.tarr || r.typ.k == K.tstr || r.typ.k == K.tmap) {
                    tc_res(type_node({ k: K.tlong }), st)
                } else if (r.typ.k == K.tunk || r.typ.k == K.tnone || r.typ.k == K.tname) {
                    // poison/unannotated shape (tcompat law): root cause
                    // errors once at its own site; len() unifies quietly.
                    tc_res(type_node({ k: K.tlong }), st)
                } else {
                    st = fail(st, "len supports arrays, strings and maps, got " + tstr(r.typ), node.line, node.col);
                    tc_res(type_node({ k: K.tlong }), st)
                }
            }
        } else if (name == "some") {
            // some(v) -> typeof(v)? (boxes v on the heap; 0 = none)
            if (len(cargs) != 1) {
                st = fail(st, "some takes exactly 1 argument", node.line, node.col);
                tc_res(t_unk(), st)
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                if (!is_value_type(r.typ)) {
                    st = fail(st, "cannot put " + tstr(r.typ) + " in an option", node.line, node.col);
                    tc_res(t_unk(), st)
                } else {
                    tc_res(type_node({ k: K.topt, of: r.typ }), st)
                }
            }
        } else if (name == "is_some") {
            if (len(cargs) != 1) {
                st = fail(st, "is_some takes exactly 1 argument", node.line, node.col);
                tc_res(type_node({ k: K.tbool }), st)
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                if (r.typ.k == K.topt || r.typ.k == K.tunk) {
                    tc_res(type_node({ k: K.tbool }), st)
                } else {
                    st = fail(st, "is_some needs an option, got " + tstr(r.typ), node.line, node.col);
                    tc_res(type_node({ k: K.tbool }), st)
                }
            }
        } else if (name == "opt$test") {
            // The test `?.` lowers to (parser.y parse_postfix): `x is
            // there`. Only the parser emits the name -- `$` is not an
            // identifier character -- so the diagnostic names the operator
            // the program wrote, and there is no arity to check.
            let tr = typeof_expr(st, cargs[0]);
            st = tr.st;
            if (tr.typ.k == K.topt || tr.typ.k == K.tunk || tr.typ.k == K.tname) {
                tc_res(type_node({ k: K.tbool }), st)
            } else {
                st = fail(st, "'?.' needs an option, got " + tstr(tr.typ), node.line, node.col);
                tc_res(type_node({ k: K.tbool }), st)
            }
        } else if (name == "opt$val") {
            // The value side of a `?.` chain (parser.y parse_postfix):
            // `some` for a payload that needs a box, except that a chain
            // ending in a void call stays void -- `obj?.cleanup();` runs the
            // method when the object is there and hands nothing back.
            let vr = typeof_expr(st, cargs[0]);
            st = vr.st;
            if (vr.typ.k == K.tvoid || vr.typ.k == K.tunk) {
                tc_res(vr.typ, st)
            } else if (vr.typ.k == K.topt) {
                // A payload that is an option IS its box, so the chain ends
                // in one option, not two: `a?.b` (b: T?) is `T?`, and none
                // means "a was none, or b was". Flat is what lets the next
                // link carry its own `?.` -- and what the emitter's
                // gen_opt_val assumes to skip the box.
                tc_res(vr.typ, st)
            } else if (!is_value_type(vr.typ)) {
                st = fail(st, "cannot put " + tstr(vr.typ) + " after '?.'", node.line, node.col);
                tc_res(t_unk(), st)
            } else {
                tc_res(type_node({ k: K.topt, of: vr.typ }), st)
            }
        } else if (name == "unwrap") {
            if (len(cargs) != 1) {
                st = fail(st, "unwrap takes exactly 1 argument", node.line, node.col);
                tc_res(t_unk(), st)
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                if (r.typ.k == K.topt) {
                    let opt: TOf = r.typ;
                    tc_res(opt.of, st)
                } else if (r.typ.k == K.tunk) {
                    tc_res(t_unk(), st)
                } else if (r.typ.k == K.tnone) {
                    tc_res(t_unk(), st)
                } else if (r.typ.k == K.tname) {
                    tc_res(t_unk(), st)
                } else if (r.typ.k == K.tparams) {
                    tc_res(t_unk(), st)
                } else {
                    st = fail(st, "unwrap needs an option, got " + tstr(r.typ), node.line, node.col);
                    tc_res(t_unk(), st)
                }
            }
        } else if (name == "trim") {
            if (len(cargs) != 1) {
                st = fail(st, "trim takes exactly 1 argument", node.line, node.col);
                tc_res(t_unk(), st)
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                st = expect_type(st, r.typ, { k: K.tstr }, "trim string", node.line, node.col);
                tc_res(type_node({ k: K.tstr }), st)
            }
        } else if (name == "ord") {
            // ord(s) -> long (first byte, -1 if empty)
            if (len(cargs) != 1) {
                st = fail(st, "ord takes exactly 1 argument", node.line, node.col);
                tc_res(t_unk(), st)
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                st = expect_type(st, r.typ, { k: K.tstr }, "ord string", node.line, node.col);
                tc_res(type_node({ k: K.tlong }), st)
            }
        } else if (name == "byte_at") {
            // byte_at(s, i) -> long (byte i of s, trapped out of bounds)
            if (len(cargs) != 2) {
                st = fail(st, "byte_at takes exactly 2 arguments", node.line, node.col);
                tc_res(t_unk(), st)
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                st = expect_type(st, r.typ, { k: K.tstr }, "byte_at string", node.line, node.col);
                let r2 = typeof_expr(st, cargs[1]);
                st = r2.st;
                st = expect_type(st, r2.typ, { k: K.tlong }, "byte_at index", node.line, node.col);
                tc_res(type_node({ k: K.tlong }), st)
            }
        } else if (name == "chr") {
            if (len(cargs) != 1) {
                st = fail(st, "chr takes exactly 1 argument", node.line, node.col);
                tc_res(t_unk(), st)
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                st = expect_type(st, r.typ, { k: K.tlong }, "chr code", node.line, node.col);
                tc_res(type_node({ k: K.tstr }), st)
            }
        } else if (name == "tonum") {
            if (len(cargs) != 1) {
                st = fail(st, "tonum takes exactly 1 argument", node.line, node.col);
                tc_res(t_unk(), st)
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                st = expect_type(st, r.typ, { k: K.tstr }, "tonum string", node.line, node.col);
                tc_res(type_node({ k: K.tlong }), st)
            }
        } else if (name == "tostring") {
            if (len(cargs) != 1) {
                st = fail(st, "tostring takes exactly 1 argument", node.line, node.col);
                tc_res(t_unk(), st)
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                if (r.typ.k == K.tlong || r.typ.k == K.tbyte || r.typ.k == K.tbool || r.typ.k == K.tstr || r.typ.k == K.tfloat || r.typ.k == K.tunk || r.typ.k == K.tarr || r.typ.k == K.tarrfix || r.typ.k == K.trec || r.typ.k == K.tmap || r.typ.k == K.topt || r.typ.k == K.tunion) {
                    tc_res(type_node({ k: K.tstr }), st)
                } else {
                    st = fail(st, "tostring supports long/bool/float/str/array/record/map/option, got " + tstr(r.typ), node.line, node.col);
                    tc_res(t_unk(), st)
                }
            }
        } else if (name == "typeof") {
            if (len(cargs) != 1) {
                st = fail(st, "typeof takes exactly 1 argument", node.line, node.col);
                tc_res(t_unk(), st)
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                tc_res(type_node({ k: K.tstr }), st)
            }
        } else if (name == "index_of" || name == "last_index_of") {
            if (len(cargs) != 2) {
                st = fail(st, name + " takes exactly 2 arguments (string, sub)", node.line, node.col);
                tc_res(t_unk(), st)
            } else {
                let r0 = typeof_expr(st, cargs[0]);
                st = r0.st;
                let r1 = typeof_expr(st, cargs[1]);
                st = r1.st;
                st = expect_type(st, r0.typ, { k: K.tstr }, name + " string", node.line, node.col);
                st = expect_type(st, r1.typ, { k: K.tstr }, name + " sub", node.line, node.col);
                tc_res(type_node({ k: K.tlong }), st)
            }
        } else if (name == "join" && len(cargs) == 1) {
            // join t: wait for thread t (spawn's function) and take its value
            let r = typeof_expr(st, cargs[0]);
            st = r.st;
            let ft = unfold(r.typ);
            if (ft.k == K.tfunc && len(fn_args(ft)) == 0) {
                let func: TFunc = ft;
                tc_res(func.ret, st)
            } else if (ft.k == K.tunk) {
                tc_res(t_unk(), st)
            } else {
                st = fail(st, "join takes a thread (a spawn's value), got " + tstr(r.typ), node.line, node.col);
                tc_res(t_unk(), st)
            }
        } else if (name == "spawn" || name == "fork") {
            // spawn { b } / fork { b }: b as a function of no parameters
            if (len(cargs) != 1) {
                st = fail(st, name + " takes a block", node.line, node.col);
                tc_res(t_unk(), st)
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                let ft = unfold(r.typ);
                if (ft.k == K.tfunc && len(fn_args(ft)) == 0) {
                    if (name == "spawn") { tc_res(ft, st) } else { tc_res(type_node({ k: K.tlong }), st) }
                } else if (ft.k == K.tunk) {
                    tc_res(t_unk(), st)
                } else {
                    st = fail(st, name + " takes a block (a function of no parameters), got " + tstr(r.typ), node.line, node.col);
                    tc_res(t_unk(), st)
                }
            }
        } else if (name == "wait_pid") {
            // wait_pid(pid) -> long: the exit status of a forked child
            if (len(cargs) != 1) {
                st = fail(st, "wait_pid takes exactly 1 argument (a pid)", node.line, node.col);
                tc_res(type_node({ k: K.tlong }), st)
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = expect_type(r.st, r.typ, type_node({ k: K.tlong }), "wait_pid's pid", node.line, node.col);
                tc_res(type_node({ k: K.tlong }), st)
            }
        } else if (name == "mutex") {
            if (len(cargs) != 0) {
                st = fail(st, "mutex takes no arguments", node.line, node.col);
            };
            tc_res(t_mutex(), st)
        } else if (name == "sem") {
            // sem(n): a semaphore counting n
            if (len(cargs) != 1) {
                st = fail(st, "sem takes exactly 1 argument (its count)", node.line, node.col);
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = expect_type(r.st, r.typ, type_node({ k: K.tlong }), "sem's count", node.line, node.col);
            };
            tc_res(t_sem(), st)
        } else if (name == "lock" || name == "try_lock") {
            // lock m { b } -> b's value; try_lock m { b } -> whether b ran
            if (len(cargs) != 2) {
                st = fail(st, name + " takes a mutex and a block", node.line, node.col);
                tc_res(t_unk(), st)
            } else {
                let rm = typeof_expr(st, cargs[0]);
                st = expect_type(rm.st, rm.typ, t_mutex(), name + "'s mutex", node.line, node.col);
                let r = typeof_expr(st, cargs[1]);
                st = r.st;
                let ft = unfold(r.typ);
                if (ft.k == K.tfunc && len(fn_args(ft)) == 0) {
                    let func: TFunc = ft;
                    if (name == "lock") { tc_res(func.ret, st) } else { tc_res(type_node({ k: K.tbool }), st) }
                } else if (ft.k == K.tunk) {
                    tc_res(t_unk(), st)
                } else {
                    st = fail(st, name + " takes a block (a function of no parameters), got " + tstr(r.typ), node.line, node.col);
                    tc_res(t_unk(), st)
                }
            }
        } else if (name == "post" || name == "wait") {
            // post s / wait s: a semaphore up, or down (waiting while 0)
            if (len(cargs) != 1) {
                st = fail(st, name + " takes exactly 1 argument (a sem)", node.line, node.col);
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = expect_type(r.st, r.typ, t_sem(), name + "'s semaphore", node.line, node.col);
            };
            tc_res(type_node({ k: K.tvoid }), st)
        } else if (name == "join") {
            // join(arr, delim) -> str (elements via tostring, like C)
            if (len(cargs) != 2) {
                st = fail(st, "join takes exactly 2 arguments (array, delimiter)", node.line, node.col);
                tc_res(t_unk(), st)
            } else {
                let r0 = typeof_expr(st, cargs[0]);
                st = r0.st;
                let r1 = typeof_expr(st, cargs[1]);
                st = r1.st;
                if (r0.typ.k != K.tarr && r0.typ.k != K.tunk) {
                    st = fail(st, "join needs an array, got " + tstr(r0.typ), node.line, node.col);
                }
                st = expect_type(st, r1.typ, { k: K.tstr }, "join delimiter", node.line, node.col);
                tc_res(type_node({ k: K.tstr }), st)
            }
        } else if (name == "split") {
            // split(s, delim) -> [str]
            if (len(cargs) != 2) {
                st = fail(st, "split takes exactly 2 arguments (string, delimiter)", node.line, node.col);
                tc_res(t_unk(), st)
            } else {
                let r0 = typeof_expr(st, cargs[0]);
                st = r0.st;
                let r1 = typeof_expr(st, cargs[1]);
                st = r1.st;
                st = expect_type(st, r0.typ, { k: K.tstr }, "split string", node.line, node.col);
                st = expect_type(st, r1.typ, { k: K.tstr }, "split delimiter", node.line, node.col);
                tc_res(type_node({ k: K.tarr, of: type_node({ k: K.tstr }) }), st)
            }
        } else if (name == "range") {
            // range(n) -> [long]: 0, 1, ..., n-1
            if (len(cargs) != 1) {
                st = fail(st, "range takes exactly 1 argument", node.line, node.col);
                tc_res(type_node({ k: K.tarr, of: type_node({ k: K.tlong }) }), st)
            } else {
                let rr = typeof_expr(st, cargs[0]);
                st = expect_type(rr.st, rr.typ, { k: K.tlong }, "range count", node.line, node.col);
                tc_res(type_node({ k: K.tarr, of: type_node({ k: K.tlong }) }), st)
            }
        } else if (name == "eputs") {
            // eputs(v) -> void: like puts, but to stderr (fd 2), so
            // diagnostics never mix into program stdout or `-S` output.
            if (len(cargs) != 1) {
                st = fail(st, "eputs takes exactly 1 argument", node.line, node.col);
                tc_res(type_node({ k: K.tvoid }), st)
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                if (r.typ.k == K.tlong || r.typ.k == K.tbool || r.typ.k == K.tstr || r.typ.k == K.tfloat || r.typ.k == K.tunk) {
                    tc_res(type_node({ k: K.tvoid }), st)
                } else {
                    st = fail(st, "eputs supports long/bool/str, got " + tstr(r.typ), node.line, node.col);
                    tc_res(type_node({ k: K.tvoid }), st)
                }
            }
        } else if (name == "clock_us") {
            // clock_us() -> long: monotonic microseconds (differences only).
            if (len(cargs) != 0) {
                st = fail(st, "clock_us takes no arguments", node.line, node.col);
                tc_res(type_node({ k: K.tlong }), st)
            } else {
                tc_res(type_node({ k: K.tlong }), st)
            }
        } else if (name == "time_us") {
            // time_us() -> long: wall-clock microseconds since the Unix epoch.
            if (len(cargs) != 0) {
                st = fail(st, "time_us takes no arguments", node.line, node.col);
                tc_res(type_node({ k: K.tlong }), st)
            } else {
                tc_res(type_node({ k: K.tlong }), st)
            }
        } else if (name == "heap_used") {
            // heap_used() -> long: arena bytes handed out so far.
            if (len(cargs) != 0) {
                st = fail(st, "heap_used takes no arguments", node.line, node.col);
                tc_res(type_node({ k: K.tlong }), st)
            } else {
                tc_res(type_node({ k: K.tlong }), st)
            }
        } else if (name == "sleep") {
            // sleep(ms): suspend the caller for ms milliseconds.
            if (len(cargs) != 1) {
                st = fail(st, "sleep takes exactly 1 argument (milliseconds)", node.line, node.col);
                tc_res(type_node({ k: K.tvoid }), st)
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                st = expect_type(st, r.typ, { k: K.tlong }, "sleep duration", node.line, node.col);
                tc_res(type_node({ k: K.tvoid }), st)
            }
        } else if (name == "puts") {
            if (len(cargs) != 1) {
                st = fail(st, "puts takes exactly 1 argument", node.line, node.col);
                tc_res(type_node({ k: K.tvoid }), st)
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                if (r.typ.k == K.tlong || r.typ.k == K.tbool || r.typ.k == K.tstr || r.typ.k == K.tfloat || r.typ.k == K.tunk) {
                    tc_res(type_node({ k: K.tvoid }), st)
                } else {
                    st = fail(st, "puts supports long/bool/str, got " + tstr(r.typ), node.line, node.col);
                    tc_res(type_node({ k: K.tvoid }), st)
                }
            }
        } else if (name == "exit") {
            if (len(cargs) != 1) {
                st = fail(st, "exit takes exactly 1 argument", node.line, node.col);
                tc_res(type_node({ k: K.tvoid }), st)
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                st = expect_type(st, r.typ, { k: K.tlong }, "exit code", node.line, node.col);
                tc_res(type_node({ k: K.tvoid }), st)
            }
        } else if (name == "argv") {
            if (len(cargs) != 0) {
                st = fail(st, "argv takes no arguments", node.line, node.col);
                tc_res(type_node({ k: K.tarr, of: type_node({ k: K.tstr }) }), st)
            } else {
                tc_res(type_node({ k: K.tarr, of: type_node({ k: K.tstr }) }), st)
            }
        } else if (name == "bytes") {
            // bytes(s) -> [byte]: the string's raw bytes, packed.
            if (len(cargs) != 1) {
                st = fail(st, "bytes takes exactly 1 argument (string)", node.line, node.col);
                tc_res(type_node({ k: K.tarr, of: type_node({ k: K.tbyte }) }), st)
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                st = expect_type(st, r.typ, { k: K.tstr }, "bytes argument", node.line, node.col);
                tc_res(type_node({ k: K.tarr, of: type_node({ k: K.tbyte }) }), st)
            }
        } else if (name == "from_bytes") {
            // from_bytes(b) -> str: the inverse of bytes(). A fixed
            // [byte; N] has the same {len, cap, data} header, so it is
            // accepted as is.
            if (len(cargs) != 1) {
                st = fail(st, "from_bytes takes exactly 1 argument (byte array)", node.line, node.col);
                tc_res(type_node({ k: K.tstr }), st)
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                let fbt: Type = r.typ;
                let fbw: Type = type_node({ k: K.tarr, of: type_node({ k: K.tbyte }) });
                if (fbt.k == K.tarrfix) {
                    let fixed: TFix = fbt;
                    if (tcompat(type_node({ k: K.tarr, of: fixed.of }), fbw)) { } else {
                        st = fail(st, "from_bytes argument: expected [byte] or [byte; N], got " + tstr(fbt), node.line, node.col);
                    };
                } else {
                    st = expect_type(st, fbt, fbw, "from_bytes argument", node.line, node.col);
                };
                tc_res(type_node({ k: K.tstr }), st)
            }
        } else if (name == "ptr_addr") {
            // ptr_addr(p) -> long: a pointer's numeric value. Pointers ARE
            // longs at run time; this is the one place the type system lets
            // that through, so Y code can build a char** (an array of
            // addresses) without the emitter growing a bespoke helper.
            if (len(cargs) != 1) {
                st = fail(st, "ptr_addr takes exactly 1 argument (pointer)", node.line, node.col);
                tc_res(type_node({ k: K.tlong }), st)
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                if (r.typ.k == K.tptr || r.typ.k == K.tstr || r.typ.k == K.tunk) {
                    tc_res(type_node({ k: K.tlong }), st)
                } else {
                    st = fail(st, "ptr_addr needs a pointer, got " + tstr(r.typ), node.line, node.col);
                    tc_res(type_node({ k: K.tlong }), st)
                }
            }
        } else if (name == "os_call") {
            // os_call("y_os_read", fd, buf, len) -> long: the NAMED syscall
            // layer. The first argument is a name from os_call_names (the only
            // list of them), the rest are the
            // arguments the named block takes -- at most six, pushed on the
            // stack in order, so the block reads them the way every Y function
            // does (the last pushed is the first parameter, lowest).
            //
            // Why a NAME and not a syscall number: the four embedded std units
            // are compiled once per compiler and serialized into one std pack,
            // so anything they resolve at compile time is baked for whichever
            // target wrote that pack and --target on the consuming compiler
            // cannot undo it. A number, a struct layout or a branch on the
            // target are all baked; a name is not, because `call y_os_read` is
            // the same instruction on both and the arch module decides what
            // that label is (read(2) on Linux, NtReadFile on Windows).
            // Measured, both ways, with a conditional in rt.y instead: a PE
            // built from the pack carried the ELF inline write(2) and printed
            // nothing, while --std-src (which recompiles) worked.
            if (len(cargs) < 1 || len(cargs) > 7) {
                st = fail(st, "os_call takes a name and 0-6 arguments",
                          node.line, node.col);
                tc_res(type_node({ k: K.tlong }), st)
            } else if (cargs[0].k != K.str) {
                st = fail(st, "os_call needs a literal call name",
                          node.line, node.col);
                tc_res(type_node({ k: K.tlong }), st)
            } else {
                // The name is a str LITERAL, matched after a cast to the
                // literal's own member (`Leaf`, which is exactly this record):
                // `.v` is not a field every Node has, and reading it through
                // one is what the union layout rules forbid.
                let nm: Leaf = cargs[0];
                let r0 = typeof_expr(st, cargs[0]);
                st = r0.st;
                if (!os_call_name(nm.v)) {
                    st = fail(st, "os_call: '" + nm.v + "' is not a call name (see os_call_names)",
                              node.line, node.col);
                };
                let i = 1;
                while (i < len(cargs)) {
                    let r = typeof_expr(st, cargs[i]);
                    st = r.st;
                    // The same argument types `syscall` takes after its
                    // number: a long, a bool, a str (whose +8 header adjustment
                    // the emitter does), or a *T for a buffer the block fills
                    // (rt.y's and prelude.y's timespec and status words).
                    if (r.typ.k != K.tlong && r.typ.k != K.tbool && r.typ.k != K.tstr
                        && r.typ.k != K.tptr && r.typ.k != K.tunk) {
                        st = fail(st, "os_call arg " + tostring(i) + " must be long/bool/str/*T, got " + tstr(r.typ),
                                  node.line, node.col);
                    };
                    i = i + 1;
                };
                tc_res(type_node({ k: K.tlong }), st)
            }
        } else if (name == "syscall") {
            // Up to six arguments on SysV (rdi..r9), up to NINE on Win64:
            // its `syscall` takes FOUR in registers (r10, rdx, r8, r9) and
            // the fifth and after at 40(%rsp), 48(%rsp), ... -- and
            // NtWriteFile, the only way to put a byte on the standard output,
            // takes nine. gen_syscall reserves that room itself on the
            // Windows side. (An earlier version of this comment said six in
            // registers and 32(%rsp); both were wrong -- see w_syscall_reg in
            // native.y for the proof that four registers at 40(%rsp) is the
            // real layout.)
            let maxargs = 7;
            if (target_is_windows()) { maxargs = 10; };
            if (len(cargs) < 1 || len(cargs) > maxargs) {
                let m = tostring(maxargs - 1);
                st = fail(st, "syscall needs 1-" + tostring(maxargs) + " arguments (number + up to " + m + " args)", node.line, node.col);
                tc_res(type_node({ k: K.tlong }), st)
            } else {
                let i = 0;
                while (i < len(cargs)) {
                    let r = typeof_expr(st, cargs[i]);
                    st = r.st;
                    if (i == 0) {
                        // The number lands in %rax. A str there is a heap
                        // pointer, so the kernel would take its address as
                        // the call number -- with every argument register
                        // still holding whatever the stack held.
                        if (r.typ.k != K.tlong && r.typ.k != K.tbyte && r.typ.k != K.tunk) {
                            st = fail(st, "syscall needs a number first, got " + tstr(r.typ), node.line, node.col);
                        }
                    } else if (r.typ.k != K.tlong && r.typ.k != K.tbool && r.typ.k != K.tstr && r.typ.k != K.tptr && r.typ.k != K.tunk) {
                        st = fail(st, "syscall arg " + tostring(i) + " must be long/bool/str/*T, got " + tstr(r.typ), node.line, node.col);
                    };
                    i = i + 1;
                };
                tc_res(type_node({ k: K.tlong }), st)
            }
        } else if (name == "jmp_at") {
            // jmp_at(addr): jump to the code at that address, leaving %rsp
            // alone (a `call` would push a return address where a process
            // entry point reads its argc). Nothing after it in the enclosing
            // function runs, and it only returns if the target does.
            if (len(cargs) != 1) {
                st = fail(st, "jmp_at needs 1 argument (the address)", node.line, node.col);
                tc_res(type_node({ k: K.tvoid }), st)
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                let ak: long = r.typ.k;
                if (ak != K.tlong && ak != K.tunk && ak != K.tptr) {
                    st = fail(st, "jmp_at needs an address, got " + tstr(r.typ), node.line, node.col);
                };
                tc_res(type_node({ k: K.tvoid }), st)
            }
        } else {
            // resolve the callee to a function type: `self`, then scope
            let fterr = "";
            let ft: Type = t_unk();
            if (name == "self") {
                if (st.self.k == K.tnone || st.self.k == K.tunk) {
                    fterr = "'self' outside of a function";
                } else {
                    ft = st.self;
                };
            } else {
                let got = lookup(st.bindings, name);
                if (got.kind == "") {
                    fterr = "undefined function '" + disp(name) + "'";
                    if (name == "substr") {
                        fterr = fterr + " (slice instead: s[start:end])";
                    }
                } else if (got.typ.k == K.tfunc) {
                    // Either a hoisted `def` (kind "func") or a local/param
                    // holding a closure value — both are callable.
                    ft = got.typ;
                } else {
                    fterr = "'" + disp(name) + "' is not a function";
                };
            };
            if (fterr != "") {
                st = fail(st, fterr, node.line, node.col);
                tc_res(t_unk(), st)
            } else if (ret_pending(ft)) {
                st = fail(st, "'" + disp(name) + "' is used before its return type is known (annotate it)", node.line, node.col);
                let i = 0;
                while (i < len(cargs)) {
                    let r = typeof_expr(st, cargs[i]);
                    st = r.st;
                    i = i + 1;
                };
                tc_res(t_unk(), st)
            } else if (ft.k != K.tfunc) {
                // poisoned binding (tunk) from an earlier error — don't
                // cascade new errors, but still check the arguments for
                // their own errors.
                let i = 0;
                while (i < len(cargs)) {
                    let r = typeof_expr(st, cargs[i]);
                    st = r.st;
                    i = i + 1;
                };
                tc_res(t_unk(), st)
            } else {
                let func: TFunc = ft;
                let cargs_ft: [Type] = func.args;
                if (len(cargs) != len(cargs_ft)) {
                    st = fail(st, "'" + disp(name) + "' takes " + tostring(len(cargs_ft)) + " args, got " + tostring(len(cargs)), node.line, node.col);
                    tc_res(call_result(func), st)
                } else {
                    let i = 0;
                    while (i < len(cargs)) {
                        let r = typeof_want(st, cargs[i], cargs_ft[i]);
                        st = r.st;
                        let ak: long = r.typ.k;
                        if (ak == K.tvoid) {
                            // void is not a value (an unannotated param
                            // would otherwise accept it quietly)
                            st = fail(st, "'" + disp(name) + "' arg " + tostring(i) + ": cannot pass a void value", node.line, node.col);
                        } else {
                            st = expect_arg(st, r.typ, cargs_ft[i], cargs[i], "'" + disp(name) + "' arg " + tostring(i), node.line, node.col);
                        };
                        i = i + 1;
                    };
                    tc_res(call_result(func), st)
                }
            }
        }
    }
};

def typeof_block(st: TcSt, node: Block) -> TcRes {
    // No scope push: names are unique post-rename, blocks share the frame.
    let last: Type = type_node({ k: K.tvoid });
    let bstmts: [Node] = node.stmts;
    let i = 0;
    while (i < len(bstmts)) {
        let r = typeof_expr(st, bstmts[i]);
        st = r.st;
        last = r.typ;
        i = i + 1;
    };
    tc_res(last, st)
};

// typeof_block with the block's value going where `want` is declared (a
// def's body, typeof_def): its last statement through typeof_want.
def typeof_block_want(st: TcSt, node: Block, want: Type) -> TcRes {
    let last: Type = type_node({ k: K.tvoid });
    let bstmts: [Node] = node.stmts;
    let i = 0;
    while (i < len(bstmts)) {
        let w: Type = type_node({ k: K.tnone });
        if (i == len(bstmts) - 1) { w = want; }
        let rr = typeof_want(st, bstmts[i], w);
        st = rr.st;
        last = rr.typ;
        i = i + 1;
    };
    tc_res(last, st)
};

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
def typeof_want(st: TcSt, node: Node, want: Type) -> TcRes {
    let nk: long = node.k;
    if (nk == K.rec) {
        let target = lit_target(node, want);
        if (target.k == K.tnone) { typeof_expr(st, node) } else { typeof_lit(st, node, target) }
    } else if (nk == K.call && is_some_call(node) && unfold(want).k == K.topt) {
        // some({...}) where T? is declared -- an optional argument passed
        // is one (rename.y) -- creates the literal as T
        let call: Call = node;
        let args: [Node] = call.args;
        let wo: TOf = unfold(want);
        let target: Type = type_node({ k: K.tnone });
        if (len(args) == 1 && args[0].k == K.rec) { target = lit_target(args[0], wo.of); };
        if (target.k == K.tnone) { typeof_expr(st, node) } else {
            let r = typeof_lit(st, args[0], target);
            tc_res(type_node({ k: K.topt, of: r.typ }), r.st)
        }
    } else { typeof_expr(st, node) }
};

// The record type a record literal is created as where `want` is declared:
// want itself when it is a record type the literal fits (lit_fits: its
// field names, but for optional fields it leaves out), or the member of a
// union want it fits -- the one with exactly its field names, else the
// only one it fits (as the union writes it, union_parts); tnone
// otherwise, and for a literal with a spread.
def lit_target(node: RecLit, want: Type) -> Type {
    let keys: [str] = node.keys;
    let w = unfold(want);
    let wk: long = w.k;
    let found: Type = type_node({ k: K.tnone });
    if (str_in(keys, "...")) {
    } else if (wk == K.trec) {
        if (lit_fits(w, keys)) { found = want; }
    } else if (wk == K.tunion) {
        let ps = union_parts(w);
        let exact: Type = type_node({ k: K.tnone });
        let nexact = 0;
        let fit: Type = type_node({ k: K.tnone });
        let nfit = 0;
        foreach (p in ps) {
            if (lit_fits(unfold(p), keys)) {
                fit = p;
                nfit = nfit + 1;
                if (same_names(unfold(p), keys)) { exact = p; nexact = nexact + 1; };
            };
        };
        if (nexact == 1) { found = exact; } else if (nexact == 0 && nfit == 1) { found = fit; };
    }
    found
};

// Record type t takes a literal with the field names keys: each is a
// field of t, and every field of t but an optional one is among them.
def lit_fits(t: Type, keys: [str]) -> bool {
    let tk: long = t.k;
    if (tk != K.trec) { false }
    else {
        let rec: TRec = t;
        let fs: [Field] = rec.fields;
        let ok = true;
        foreach (key in keys) { if (field_pos(fs, key, 0) < 0) { ok = false; }; };
        foreach (f in fs) { if (!f.opt && !str_in(keys, f.name)) { ok = false; }; };
        ok
    }
};

// Field `key` of record type t is optional (`key?: T`).
def field_opt(t: Type, key: str) -> bool {
    let opt = false;
    if (t.k == K.trec) {
        let rec: TRec = t;
        let fs: [Field] = rec.fields;
        foreach (f in fs) { if (f.name == key && f.opt) { opt = true; }; };
    };
    opt
};

// A value of type vt given for an optional field of type ft (T?) is
// wrapped -- some(v) -- when it is a T and not already a T? (or none).
// native.y gen_reclit decides by it too.
def opt_wraps(vt: Type, ft: Type) -> bool {
    let fu = unfold(ft);
    if (fu.k != K.topt) { false }
    else {
        let fo: TOf = fu;
        !tcompat(vt, fu) && tcompat(vt, fo.of)
    }
};

// Record type t has exactly the field names keys (a name written twice
// counts once).
def same_names(t: Type, keys: [str]) -> bool {
    let tk: long = t.k;
    if (tk != K.trec) { false }
    else {
        let rec: TRec = t;
        let fs: [Field] = rec.fields;
        let distinct: [str] = [];
        let ok = true;
        let i = 0;
        while (i < len(keys)) {
            let key: str = keys[i];
            if (!str_in(distinct, key)) { distinct += key; }
            if (field_pos(fs, key, 0) < 0) { ok = false; }
            i = i + 1;
        };
        ok && len(distinct) == len(fs)
    }
};

// A record literal checked against the record type target (lit_target):
// each value against its field's type (typeof_want); an optional field's
// against T when it is a plain T (opt_wraps). Its type is target.
def typeof_lit(st: TcSt, node: RecLit, target: Type) -> TcRes {
    let tu = unfold(target);
    let keys: [str] = node.keys;
    let vals: [Node] = node.vals;
    let i = 0;
    while (i < len(keys)) {
        let key: str = keys[i];
        let ft = trec_field_type(tu, key);
        let what = "record field '" + key + "'";
        if (field_opt(tu, key) && ft.k == K.topt) {
            let fo: TOf = ft;
            let r = typeof_want(st, vals[i], fo.of);
            if (opt_wraps(r.typ, ft)) {
                st = expect_type(r.st, r.typ, fo.of, what, node.line, node.col);
            } else {
                st = expect_type(r.st, r.typ, ft, what, node.line, node.col);
            };
        } else {
            let r = typeof_want(st, vals[i], ft);
            st = expect_type(r.st, r.typ, ft, what, node.line, node.col);
        };
        i = i + 1;
    };
    tc_res(target, st)
};


def typeof_decl(st: TcSt, node: Decl) -> TcRes {
    if (node.kind == "def") {
        // named function: full check (signature + body)
        typeof_def(st, node.name, node.v, node.line, node.col, node.nline, node.ncol, false)
    } else if (node.kind == "native") {
        // native def: the signature, and three rules of its own
        typeof_def(st, node.name, node.v, node.line, node.col, node.nline, node.ncol, true)
    } else {
        // let/const. A literal def on the right names a function WITHOUT
        // going through typeof_expr (a bare func value is only legal bound).
        // Same for the `[v; n]` array literal (binds n frame slots).
        // A const binds as kind "const": const_check refuses to rebind it.
        let bk = "local";
        if (node.kind == "const") { bk = "const"; };
        if (node.v.k == K.func) {
            let fr = typeof_def(st, node.name, node.v, node.line, node.col, node.nline, node.ncol, false);
            st = fr.st;
            if (node.typ.k != K.tnone) {
                st = expect_type(st, fr.typ, node.typ, "let '" + disp(node.name) + "'", node.line, node.col);
            }
            st = st_bind(st, node.name, fr.typ, "func", node.nline, node.ncol);
            { typ: fr.typ, st: st }
        } else if (node.v.k == K.arrrep) {
            let r = typeof_expr(st, node.v);
            st = r.st;
            if (r.typ.k == K.tunk) {
                st = st_bind(st, node.name, t_unk(), bk, node.nline, node.ncol);
                { typ: t_unk(), st: st }
            } else {
                let at = r.typ;
                if (node.typ.k != K.tnone) {
                    let rep: ArrRep = node.v;
                    if (arr_lit_adopts(r.typ, node.typ, rep.n)) {
                    } else {
                        st = expect_type(st, r.typ, node.typ, "let '" + disp(node.name) + "'", node.line, node.col);
                    };
                    at = node.typ;
                }
                st = st_bind(st, node.name, at, bk, node.nline, node.ncol);
                { typ: at, st: st }
            }
        } else {
            let r = typeof_want(st, node.v, node.typ);
            st = r.st;
            let t = r.typ;
            let vk = node.v.k;
            if (node.typ.k != K.tnone) {
                if (!is_value_type(node.typ)) {
                    st = fail(st, "annotation '" + tstr(node.typ) + "' is not a native value type", node.line, node.col);
                } else if (vk == K.array) {
                    // An array LITERAL adopts the annotated element type:
                    // `let b: [byte] = [104, 105]` packs those elements
                    // into one byte each. Only literals — assigning an
                    // existing [long] to a [byte] binding would reinterpret
                    // eight-byte slots as one, so that still errors.
                    let lit: ArrLit = node.v;
                    if (arr_lit_adopts(r.typ, node.typ, len(lit.elems))) { } else {
                        st = expect_type(st, r.typ, node.typ, "let '" + disp(node.name) + "'", node.line, node.col);
                    };
                    t = node.typ;
                } else if (vk == K.rec) {
                    let rec: RecLit = node.v;
                    if (len(rec.keys) == 0 && node.typ.k == K.tmap) {
                        // The empty literal `{}` under a map annotation IS
                        // the map (the emitter lowers it to the {keys, vals,
                        // boxes} shape).
                        t = node.typ;
                    } else {
                        st = expect_cast(st, r.typ, node.typ, "let '" + disp(node.name) + "'", node.line, node.col);
                        t = node.typ;
                    };
                } else {
                    st = expect_cast(st, r.typ, node.typ, "let '" + disp(node.name) + "'", node.line, node.col);
                    t = node.typ;
                };
            }
            // NOTE: tnone/tname (unannotated initializer shapes) unify
            // quietly (tcompat law) — the missing annotation errors once at
            // its own site, not again at every enclosing let.
            if (t.k == K.tnone) {
                t = t_unk();
            } else if (t.k == K.tname) {
                t = t_unk();
            } else if (t.k == K.tvoid) {
                st = fail(st, "cannot bind a void value to '" + disp(node.name) + "'", node.line, node.col);
                t = t_unk();
            } else if (!is_value_type(t)) {
                st = fail(st, "'" + tstr(t) + "' cannot be bound to a variable", node.line, node.col);
                t = t_unk();
            } else if (has_free(t)) {
                st = fail(st, "the type of '" + disp(node.name) + "' is not fully known (annotate it)", node.line, node.col);
            }
            st = st_bind(st, node.name, t, bk, node.nline, node.ncol);
            { typ: t, st: st }
        }
    }
};

// A `return` in a def whose return type is still being inferred: its type
// and position go into the marker typeof_def put in st.ret (`rl`, a record
// shared by reference), to be checked once the body's type is known.
def ret_note(rl: TInfer, typ: Type, line: long, col: long) -> long {
    let rets: [RetNote] = rl.rets;
    rets += { typ: typ, line: line, col: col };
    0
};

// The return types typeof_def inferred, by the def's position: the
// emitter types calls, `self` and every `return` with them, as the checker
// did (native.y fn_ret), instead of re-inferring from the trailing
// expression alone (which cannot see the body's locals). They are not
// written into the def node: a node read through a cast from a union may
// be a copy (CHOICES_MADE.md 25), and lint reads the node for the types
// the program writes. 1024 buckets of indices into inf_keys/inf_typs
// (key: line * 65536 + col); check_program empties them.
let inf_keys: [long] = [];
let inf_typs: [Type] = [];
let inf_bkts: [[long]] = [];

def inf_reset() {
    let keys: [long] = [];
    let typs: [Type] = [];
    let bkts: [[long]] = [];
    let i = 0;
    while (i < 1024) {
        let b: [long] = [];
        bkts += b;
        i = i + 1;
    };
    inf_keys = keys;
    inf_typs = typs;
    inf_bkts = bkts;
};

def set_inferred_ret(func: Func, ret: Type) -> long {
    if (len(inf_bkts) == 0) { inf_reset(); };
    let key = func.line * 65536 + func.col;
    let bkt: [long] = inf_bkts[key % 1024];
    inf_keys += key;
    inf_typs += ret;
    bkt += len(inf_keys) - 1;
    0
};

// The return type inferred for the def at (line, col); tnone for none.
def inferred_ret(line: long, col: long) -> Type {
    let found: Type = { k: K.tnone };
    if (len(inf_bkts) > 0) {
        let key = line * 65536 + col;
        let bkt: [long] = inf_bkts[key % 1024];
        foreach (ix in bkt) { if (inf_keys[ix] == key) { found = inf_typs[ix]; }; };
    };
    found
};

// Check a func value bound to `name` (def decl, let-bound anonymous def, or
// an anonymous literal). Returns { typ, st }: `typ` is the def's tfunc (with
// an inferred return filled in), and `name` ends up bound as kind "func".
// The tail of the inferred-return diagnostic, for a `return` with no value.
// The type the message quotes is one the reader never wrote -- it comes
// from the body's tail -- so this case says what does resolve it: one word
// on the def's head makes the inferred type a written one, and the void
// return then is what the def says it does. Every other disagreement is an
// ordinary type error and closes the parenthesis as before.
def ret_inferred_hint(rt: Type) -> str {
    if (rt.k == K.tvoid) {
        "; write '-> void' on the def to return nothing)"
    } else {
        ")"
    }
};

// `line`/`col` are the KEYWORD's, for the diagnostics inside; `nline`/`ncol` are
// the NAME's, and are what st_bind records. They differ by however much
// whitespace `let`/`def` was followed by.
def typeof_def(st: TcSt, name: str, func: Func, line: long, col: long, nline: long, ncol: long, isnat: bool) -> TcRes {
    // `isnat` is a `native def`: the signature is checked exactly as a def's
    // is, but there is no body -- the return type must be written, the label
    // must be a `y_` one, and the declaration must be at the top level.
    if (len(func.params) != len(func.ptypes)) {
        st = fail(st, "internal: params/ptypes length mismatch", line, col);
        tc_res(t_unk(), st)
    } else {
        let args: [Type] = [];
        // NOTE: bound once (flow-snapshot: `params`/`ptypes` are bare node
        // fields; an inline `func.params[i]` would re-read the node through
        // whatever shape the env holds for `func`).
        let fparams: [str] = func.params;
        let fptypes: [Type] = func.ptypes;
        // Each parameter NAME's own position, when the parser recorded it. Empty
        // for a hand-built Func, and then the binding falls back to the def's own
        // position -- which is the imprecision, not a silent wrong answer, because
        // the name is still bound and every use still resolves.
        let fpos: [long] = func.ppos;
        let i = 0;
        let ok = true;
        while (i < len(fparams)) {
            let pt: Type = fptypes[i];
            if (pt.k == K.tnone) {
                // No value of unknown type: a parameter says its type.
                st = fail(st, "parameter '" + disp(fparams[i]) + "' has no type (annotate it)", line, col);
                pt = t_unk();
            } else if (!is_value_type(pt) && pt.k != K.tfunc) {
                st = fail(st, "parameter '" + disp(fparams[i]) + "' has unpassable type " + tstr(pt) + " (a void value has no representation, and a type pattern cannot be passed by value)", line, col);
                ok = false;
            }
            args += pt;
            i = i + 1;
        };
        let ret: Type = func.ret;
        if (isnat) {
            // A native's body holds no code, so the return type has nothing to
            // be inferred from and has to be written. A body that is NOT empty
            // means the parser planted errors in it, which say better than this
            // would -- so wait for them rather than piling on.
            let nbody: Block = func.body;
            if (ret.k == K.tnone && len(nbody.stmts) == 0) {
                st = fail(st, "native def '" + disp(name) + "' needs a return type (there is no body to infer it from)", line, col);
                ret = t_unk();
            };
            if (!func.label.starts_with("y_")) {
                st = fail(st, "native label '" + disp(func.label) + "' must start with 'y_' (generated code calls it by that prefix)", line, col);
            };
            if (st.fdepth > 0) {
                st = fail(st, "native def '" + disp(name) + "' must be at the top level (an assembly label has no place inside a function)", line, col);
            };
        };
        let ret_inferred = false;
        // An inferred def's `return`s are checked once its type is known:
        // while the body is checked, st.ret is a marker that notes each one
        // (ret_note) in `rets`.
        let rets: [RetNote] = [];
        let body_ret: Type = ret;
        if (ret.k == K.tnone) {
            // The return type comes from the body's tail value once the
            // body has been checked; a call before then (the def calling
            // itself) needs it annotated (t_pend).
            ret_inferred = true;
            ret = t_pend_self();
            body_ret = type_node({ k: K.tinfer, rets: rets });
        }
        let ft: Type = type_node({ k: K.tfunc, args: args, ret: ret });
        // bind early so recursion via `self`/name works
        st = st_bind(st, name, ft, "func", nline, ncol);
        // check the body one level deeper. Outer locals/params stay in the
        // flat map (one shape per name), so a nested def reading one is a
        // capture — legal, and closure-converted by the emitter.
        let saved_self = st.self;
        let saved_ret = st.ret;
        let saved_depth = st.fdepth;
        st = st_fdepth(st, saved_depth + 1);
        let j = 0;
        while (j < len(fparams)) {
            // The binding's position is the FUNCTION's, because a parameter has no
            // node of its own -- but the parser does now keep each name's own
            // position (`Func.ppos`), and that is where a hover, a semantic token
            // and a go-to-definition all need to point. Binding at `nline`/`ncol`
            // was the one thing `Binding.line/col` could not answer, and it is why
            // hovering a parameter's own name showed nothing.
            let pl = nline;
            let pc = ncol;
            if (j < len(fpos) && fpos[j] > 0) {
                pl = fpos[j] / 65536;
                pc = fpos[j] % 65536;
            };
            st = st_bind(st, fparams[j], args[j], "param", pl, pc);
            // And into the type index, at the name's own position. A parameter is
            // a bare string in `Func.params`, so there is no node for `typeof_expr`
            // to visit and nothing else would ever record it -- which is why
            // hovering the `p` in `def g(p: P)` showed nothing while hovering a USE
            // of `p` showed `P`.
            if (tc_index) { tci_note_key(pl * 65536 + pc, args[j]); };
            j = j + 1;
        };
        st = st_self(st, ft);
        st = st_ret(st, body_ret);
        let nerr = len(st.errors);
        let body: Block = func.body;
        let b = typeof_block_want(st, body, body_ret);
        st = b.st;
        if (ret_inferred) {
            // INFERENCE: the def's return type is the body's tail value.
            // Unannotated sub-shapes (tnone) stay poison; tunk stays tunk.
            let br = b.typ;
            if (br.k == K.tnone) {
                br = t_unk();
            }
            // A trailing value of unknown type -- typically a self call,
            // whose type is the one being inferred -- leaves the type to the
            // first `return` that knows its own.
            let rsrc = "the end of the body";
            let ri = 0;
            while (ri < len(rets)) {
                let rn = rets[ri];
                let rt = rn.typ;
                if (br.k == K.tunk && rt.k != K.tunk && rt.k != K.tnone) {
                    br = rt;
                    rsrc = "the first 'return'";
                }
                ri = ri + 1;
            };
            // Every `return` must conform to it, as to a written type.
            ri = 0;
            while (ri < len(rets)) {
                let rn = rets[ri];
                if (!tcompat(rn.typ, br)) {
                    st = fail(st, "'return': expected " + tstr(br) + ", got " + tstr(rn.typ) + " (the return type is inferred from " + rsrc + ret_inferred_hint(rn.typ), rn.line, rn.col);
                }
                ri = ri + 1;
            };
            let pend: TPend = ret;
            if ((has_free(br) || (pend.used && br.k == K.tunk)) && len(st.errors) == nerr) {
                st = fail(st, "the return type of '" + disp(name) + "' is not fully known (annotate it)", line, col);
                br = t_unk();
            } else if (pend.used && br.k != K.tunk) {
                // The body calls the def itself, so it was checked with
                // that call's type unknown: check it again, the call now
                // typed br, its `return`s and tail as before (the first
                // pass's errors go; this one reports them).
                let kept: [Diag] = st.errors;
                st = st_errors(st, kept[0:nerr]);
                let ft2: Type = type_node({ k: K.tfunc, args: args, ret: br });
                st = st_bind(st, name, ft2, "func", nline, ncol);
                st = st_self(st, ft2);
                let rets2: [RetNote] = [];
                st = st_ret(st, type_node({ k: K.tinfer, rets: rets2 }));
                let b2 = typeof_block_want(st, body, br);
                st = b2.st;
                st = expect_type(st, b2.typ, br, "'" + disp(name) + "' body", line, col);
                let ri2 = 0;
                while (ri2 < len(rets2)) {
                    let rn2 = rets2[ri2];
                    if (!tcompat(rn2.typ, br)) {
                        st = fail(st, "'return': expected " + tstr(br) + ", got " + tstr(rn2.typ) + " (the return type is inferred from " + rsrc + ret_inferred_hint(rn2.typ), rn2.line, rn2.col);
                    }
                    ri2 = ri2 + 1;
                };
            }
            ft = type_node({ k: K.tfunc, args: args, ret: br });
            st = st_bind(st, name, ft, "func", nline, ncol);
            if (br.k != K.tunk) {
                set_inferred_ret(func, br);
            }
        }
        if (isnat) {
            // nothing to check: there is no body, only the header's errors
        } else if (!(ret_inferred)) {
            // `-> void` discards the body's tail value (no value returns)
            let rtk: long = ret.k;
            if (rtk == K.tvoid) { } else {
                st = expect_cast(st, b.typ, ret, "'" + disp(name) + "' body", line, col);
            };
        }
        st = st_fdepth(st, saved_depth);
        st = st_self(st, saved_self);
        st = st_ret(st, saved_ret);
        if (ok) {
            tc_res(ft, st)
        } else {
            // poison the binding so follow-on errors don't cascade weirdly
            st = st_bind(st, name, t_unk(), "func", nline, ncol);
            tc_res(t_unk(), st)
        }
    }
};

def st_fdepth(st: TcSt, d: long) -> TcSt { { bindings: st.bindings, errors: st.errors, ret: st.ret, self: st.self, fdepth: d, loops: st.loops, loop_fd: st.loop_fd } };

// ── entry point ──────────────────────────────────────────────────────────

// `ext`: the externs -- top-level defs of the units this one links
// against (native.y compile_unit), visible by name like the unit's own.
def check_program(ast: Block, ext: [Sym]) -> [Diag] {
    // the inferred-return table is made when first written (inf_reset)
    let nobkts: [[long]] = [];
    inf_bkts = nobkts;
    // Only when it is on: emptying 1024 buckets on every compile of every
    // program would be a cost paid for a feature no compiler run uses.
    if (tc_index) { tci_reset(); };
    tc_ixn = 0;
    // pass 1: collect top-level def signatures (allows mutual recursion).
    let defs: [Field] = [];
    let pstmts: [Node] = ast.stmts;
    let i = 0;
    while (i < len(pstmts)) {
        let s: Node = pstmts[i];
        // NOTE: nested ifs, not `&&` (house style — the `s.v.k` read is
        // only reached once `s` is known to be a decl; `&&` would
        // short-circuit to the same place).
        if (s.k == K.decl) {
            let decl: Decl = s;
            if (decl.kind == "def") {
                let func: Func = decl.v;
                defs += def_sig(decl.name, func);
            } else if (decl.v.k == K.func) {
                // top-level let f = def... : also hoisted for mutual recursion
                let func: Func = decl.v;
                defs += def_sig(decl.name, func);
            }
        }
        i = i + 1;
    };
    // pass 2: check everything in order (depth 0 = top level)
    let st: TcSt = { bindings: [], errors: [], ret: type_node({ k: K.tnone }), self: type_node({ k: K.tnone }), fdepth: 0, loops: 0, loop_fd: -1 };
    // top-level defs are visible at top level
    let print_type: Type = type_node({ k: K.tfunc, args: [type_node({ k: K.tlong })], ret: type_node({ k: K.tvoid }) });
// The intrinsics and the externs below have no position: the first two are the
    // language's own, the rest are names the program links against from another
    // unit. -1 is the honest answer and no consumer may read it as line 1.
    st = st_bind(st, "print", print_type, "intrinsic", 0 - 1, 0 - 1);
    st = st_bind(st, "syscall", type_node({ k: K.tlong }), "intrinsic", 0 - 1, 0 - 1);
    // (name: str, args...) -> long. The binding exists only so `os_call` reads
    // as defined when it appears as a value; typeof_call matches it by name and
    // checks the arity and the argument types itself (os_call takes a varying
    // number of arguments, so there is no single function type to bind).
    st = st_bind(st, "os_call", type_node({ k: K.tlong }), "intrinsic", 0 - 1, 0 - 1);
    // Every intrinsic is matched BY NAME in typeof_call (print, len, some,
    // ... syscall), so these two bindings are never consulted by a call; they
    // exist only so `print`/`syscall` read as defined when they appear as
    // values (e.g. `let p = print;`).
    let x = 0;
    while (x < len(ext)) {
        let xe = ext[x];
        // a package's global (its cell label, native.y arch_global_label)
        // is read-only to its importers
        let xk = "func";
        if (xe.label.starts_with("yg_")) { xk = "const"; }
        st = st_bind(st, xe.name, xe.typ, xk, 0 - 1, 0 - 1);
        x = x + 1;
    };
    let d = 0;
    while (d < len(defs)) {
        st = st_bind(st, defs[d].name, defs[d].typ, "func", 0 - 1, 0 - 1);
        d = d + 1;
    };
    let r = typeof_block(st, ast);
    r.st.errors
};

def def_sig(name: str, func: Func) -> Field {
    // Signature for the pre-pass. Missing annotations are poison (tunk);
    // pass 2 (typeof_def) reports each exactly once.
    let args: [Type] = [];
    let fpt: [Type] = func.ptypes;
    let i = 0;
    while (i < len(func.params)) {
        let pt: Type = fpt[i];
        if (pt.k == K.tnone) { pt = t_unk(); };
        args += pt;
        i = i + 1;
    };
    let ret: Type = func.ret;
    if (ret.k == K.tnone) { ret = t_pend(); };
    { name: name, opt: false, typ: type_node({ k: K.tfunc, args: args, ret: ret }) }
};

export { check_program, os_call_names, tstr, teq, leaf_of, field_pos, field_merge, narrow_type, union_member, unfold, members, union_parts, pat_members, lit_target, opt_wraps, t_mutex, t_sem, tcanon, tsig, inferred_ret, str_sorted, rec_names, type_names, str_method, fmt_spec, fmt_kind, expr_type, type_index_on, type_index_off, Sym };
