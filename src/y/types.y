// types.y — static type checker for the native backend.

// For its aliases Field, Node and Type.
import tags from "./tags.y";
import dispatch from "./check_dispatch.y";
import ktgt from "./target.y";
import parser from "./parser.y";
import tyrules from "./type_rules.y";
import builtins from "./builtin_shapes.y";
import methgen from "./method_shapes.y";

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

def t_unk() -> Type { { k: K.tunk } };

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
    if (t.k == K.tunk) { return match t { TFree { free: fr } => fr, _ => false }; };
    if (t.k == K.tref || t.k == K.tinfer || t.k == K.tparams) { return false; };
    type_any_child(t, (child: Type) => has_free(child))
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
        ftype.ret.k == K.tpend
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

// String-keyed map type used by map literals.
def map_type_of(v: Type) -> Type {
    { k: K.tmap, key: { k: K.tstr }, of: v }
};

def teq(a: Type, b: Type) -> bool {
    if (a == b || a.k == K.tunk || b.k == K.tunk) { return true; };
    if (a.k != b.k) { return (a.k == K.tref || b.k == K.tref) && teq_ref(a, b); };
    if (a.k == K.tref) { return teq_ref(a, b); };
    if (a.k == K.tunion) {
        let ua = union_parts(a);
        let ub = union_parts(b);
        return len(ua) == len(ub) && teq_members(ua, ub, 0) && teq_members(ub, ua, 0);
    };
    teq_shape(a, b)
};

// A packed type's fields compare in declaration order (type_rules' meta
// block generates the calls to this from its shape rows).
def teq_ordered(af: [Field], bf: [Field], start: long) -> bool {
    len(af) == len(bf) && af.all((f, i) => i < start || (f.name == bf[i].name && teq(f.typ, bf[i].typ)))
};

// ── recursive types and canonical forms ──────────────────────────────────

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

def union_parts_go(out: [Type], t: Type, depth: long) -> void {
    let union: TList = t;
    let ms: [Type] = union.ts;
    ms.foreach((m) => {
        let u = unfold(m);
        if (u.k == K.tunion && depth < 16) { union_parts_go(out, u, depth + 1); } else { out += m; };
    });
};

// A union's members, unfolded (union_parts).
def members(t: Type) -> [Type] {
    let ps = union_parts(t);
    let out: [Type] = [];
    ps.foreach((e) => {
        out += unfold(e);
    });
    out
};

// The members of union s, as written, with every field of the record
// pattern t.
def pat_members(s: Type, t: Type) -> [Type] {
    let ps = union_parts(s);
    let pat: TPat = t;
    let names: [str] = pat.names;
    let out: [Type] = [];
    ps.foreach((e) => {
        if (rec_has_names(unfold(e), names)) { out += e; }
    });
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
        teq_unfolds++;
        let r = teq(unfold(a), unfold(b));
        teq_unfolds--;
        r
    }
};

// xs sorted (insertion sort: field lists are short).
def str_sorted(xs: [str]) -> [str] {
    xs.sorted((a, b) => a < b ? -1 : a > b ? 1 : 0)
};

// The field names of a record type's field list, sorted: its layout
// (native.y "records at run time").
def rec_names(fields: [Field]) -> [str] { str_sorted(fields.map((f) => f.name))
};

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
    else if (k == K.tbigint) { out += "g"; out }
    else if (k == K.tbool) { out += "o"; out }
    else if (k == K.tstr) { out += "s"; out }
    else if (k == K.tvoid) { out += "v"; out }
    else if (k == K.tint) {
        let ti: TInt = t;
        let sg = "u";
        if (ti.sg) { sg = "s"; };
        let be = "l";
        if (ti.be) { be = "b"; };
        out += "I" + tostring(ti.w) + sg + be;
        out
    }
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
        for i in 0..len(args) {
            out = tcanon_go(out, args[i], stack);
            out += ",";
        };
        out += ")";
        tcanon_go(out, func.ret, stack)
    } else if (k == K.trec) {
        let rec: TRec = t;
        let fs: [Field] = rec.fields;
        let names = rec_names(fs);
        out += "{";
        names.foreach((e) => {
            let nm: str = e;
            let f = fs[field_pos(fs, nm, 0)];
            out += nm + ":";
            out = tcanon_go(out, f.typ, stack);
            out += ",";
        });
        out += "}";
        out
    } else if (k == K.tpack) {
        let pk: TPack = t;
        let pfs: [Field] = pk.fields;
        out += "P" + tostring(pk.bk) + "{";
        for i in 0..len(pfs) {
            let pf = pfs[i];
            let pn: str = pf.name;
            out += pn + ":";
            out = tcanon_go(out, pf.typ, stack);
            out += ",";
        };
        out += "}";
        out
    } else if (k == K.tunion) {
        let union: TList = t;
        let ms = union_parts(union);
        let forms: [str] = [];
        ms.foreach((e) => {
            let mout: [str] = [];
            let mf = join(tcanon_go(mout, e, stack), "");
            if (!(mf in forms)) { forms += mf; }
        });
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

// Records compare fields by name (type_rules' meta block generates the
// calls to this from its shape rows).
def teq_fields(af: [Field], bf: [Field], start: long) -> bool {
    if (len(af) != len(bf)) { return false; };
    af.all((f, i) => {
        if (i < start) { return true; };
        let j = field_pos(bf, f.name, i);
        j >= 0 && teq(f.typ, bf[j].typ)
    })
};

// The index of the field named `name` in the field list fs, -1 when there
// is none. `hint` is tried first: records written in the same order find
// every field there.
def field_pos(fs: [Field], name: str, hint: long) -> long {
    if (hint >= 0 && hint < len(fs) && fs[hint].name == name) { return hint; };
    for i in 0..len(fs) { if (fs[i].name == name) { return i; }; };
    -1
};

// Every member of ua has an equal member in ub.
def teq_members(ua: [Type], ub: [Type], start: long) -> bool {
    ua.all((a, i) => i < start || ub.some((b) => teq(a, b)))
};

def teq_list(aa: [Type], bb: [Type], start: long) -> bool {
    len(aa) == len(bb) && aa.all((a, i) => i < start || teq(a, bb[i]))
};

// Field type by name in a trec; tnone marker when missing (dotassign uses
// it — the caller reports the error once at the assignment site).
def type_field_lookup(fields: [Field], key: str) -> Type {
    let found: Type = {k: K.tnone};
    foreach (field in fields) { if (field.name == key) { found = field.typ; }; };
    found
};

def trec_field_type(rec: Type, key: str) -> Type {
    if (rec.k != K.trec) { return type_node({k: K.tnone}); };
    let record: TRec = rec;
    type_field_lookup(record.fields, key)
};

def tuple_field_no(name: str) -> long {
    if (len(name) < 2) { -1 }
    else if (name[0:1] != "$") { -1 }
    else {
        let v = 0;
        let i = 1;
        let ok = true;
        while (i < len(name) && ok) {
            let c = name[i:i + 1];
            if (c >= "0" && c <= "9") {
                v = v * 10 + (ord(c) - ord("0"));
                i++;
            } else {
                ok = false;
            };
        };
        if (ok) { v } else { -1 }
    }
};

// The tuple arity of a field list: n for a complete $0..$n-1 set, -1 for
// any ordinary record (including the empty record, which is not a tuple).
def tuple_n(fs: [Field]) -> long {
    let n = 0;
    let ok = len(fs) > 0;
    foreach (f in fs) {
        let ix = tuple_field_no(f.name);
        if (ix < 0 || f.opt) { ok = false; }
        else if (ix + 1 > n) { n = ix + 1; };
    };
    if (ok && n == len(fs)) { n } else { -1 }
};

def tuple_typs(fs: [Field]) -> [Type] {
    let n = tuple_n(fs);
    let out: [Type] = [];
    if (!(n < 0)) {
        for i in 0..n {
            out += { k: K.tunk };
        };
        foreach (f in fs) {
            out[tuple_field_no(f.name)] = f.typ;
        };
    };
    out
};

// i16, u32, u32be ...: the spelling of a sized integer.
def tint_name(t: TInt) -> str {
    let sg = "u";
    if (t.sg) { sg = "i"; };
    let be = "";
    if (t.be) { be = "be"; };
    sg + tostring(t.w * 8) + be
};

// What `*p` is when p points at a sized integer: a long (the width is the
// memory's, not the value's). Any other pointee is itself.
def pointee_value(t: Type) -> Type {
    if (t.k == K.tint) { type_node({ k: K.tlong }) } else { t }
};

def tstr_go(t: Type) -> str {
    if (t.k == K.tlong) { "long" }
    else if (t.k == K.tbyte) { "byte" }
    else if (t.k == K.tfloat) { "float" }
    else if (t.k == K.tbigint) { "bigint" }
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
    else if (t.k == K.tint) { let ti: TInt = t; tint_name(ti) }
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
        let rec: TRec = t;
        let fs: [Field] = rec.fields;
        if (tuple_n(fs) >= 0) {
            let tys = tuple_typs(fs);
            let tparts: [str] = [];
            tys.foreach((e) => {
                tparts += tstr_go(e);
            });
            "(" + join(tparts, ", ") + ")"
        } else {
            let parts: [str] = [];
            for i in 0..len(fs) {
                let f = fs[i];
                let fname: str = f.name;
                let ft: Type = f.typ;
                if (f.opt && ft.k == K.topt) {
                    let fo: TOf = ft;
                    parts += fname + "?: " + tstr_go(fo.of);
                } else { parts += fname + ": " + tstr_go(ft); };
            };
            "{ " + join(parts, ", ") + " }"
        }
    }
    else if (t.k == K.tpack) {
        let pk: TPack = t;
        let pfs: [Field] = pk.fields;
        let parts: [str] = [];
        for i in 0..len(pfs) {
            let pf = pfs[i];
            let pn: str = pf.name;
            let pt: Type = pf.typ;
            if (pk.bk > 0) {
                let bi: TInt = pt;
                parts += pn + ": " + tostring(bi.w);
            } else { parts += pn + ": " + tstr_go(pt); };
        };
        let head = "packed";
        if (pk.bk > 0) { head = "bits u" + tostring(pk.bk * 8); };
        head + " { " + join(parts, ", ") + " }"
    }
    else if (t.k == K.tfunc) {
        let parts: [str] = [];
        let func: TFunc = t;
        let ta: [Type] = func.args;
        ta.foreach((e) => {
            parts += tstr_go(e);
        });
        "(" + join(parts, ", ") + ") -> " + tstr_go(func.ret)
    } else { "<" + ktag(t.k) + ">" }
};

def tstr(t: Type) -> str { tstr_go(t) };

def tstr_union(ts: [Type], sep: str) -> str { join(ts.map((t) => tstr_go(t)), sep)
};

// ── unions and match ─────────────────────────────────────────────────────

// ── primitive union members ─────────────────────────────────────────────
def is_prim_type(t: Type) -> bool {
    t.k == K.tlong || t.k == K.tbyte || t.k == K.tstr || t.k == K.tbool || t.k == K.tfloat || t.k == K.tbigint
};

def prim_field_name(t: Type) -> str {
    if (t.k == K.tlong) { "$long" }
    else if (t.k == K.tbyte) { "$byte" }
    else if (t.k == K.tstr) { "$str" }
    else if (t.k == K.tbool) { "$bool" }
    else if (t.k == K.tfloat) { "$float" }
    else if (t.k == K.tbigint) { "$bigint" }
    else { "$?" }
};

// A primitive, array or map can be a union member. The value is boxed in a
// hidden one-field record; arrays and maps are already pointers, and the box
// gives them the descriptor tag union matching and printing need.
def is_boxable_type(t: Type) -> bool {
    is_prim_type(t) || t.k == K.tarr || t.k == K.tarrfix || t.k == K.tmap
};

def box_field_name(t: Type) -> str {
    if (t.k == K.tarr || t.k == K.tarrfix) { "$arr" }
    else if (t.k == K.tmap) { "$map" }
    else { prim_field_name(t) }
};

def prim_field(t: Type) -> Field {
    { name: box_field_name(t), opt: false, typ: t }
};

// The fields a member contributes to a union's layout: a record's own fields,
// or the one hidden field of a primitive's box. Any other type contributes
// nothing (the checker has already rejected it as a union member).
def member_fields(m: Type) -> [Field] {
    let u = unfold(m);
    if (u.k == K.trec) { let rec: TRec = u; rec.fields[:] }
    else if (is_boxable_type(u)) { [prim_field(u)] }
    else { [] }
};

def member_field_type(m: Type, key: str) -> Type { type_field_lookup(member_fields(m), key)
};

// The field names a match pattern tests: a record type's, or a record
// pattern's (tpat).
def type_names(t: Type) -> [str] {
    if (t.k == K.trec || is_boxable_type(unfold(t))) { member_fields(t).map((f) => f.name) }
    else if (t.k == K.tpat) { let pat: TPat = t; pat.names[:] }
    else { [] }
};

def rec_has_names(r: Type, names: [str]) -> bool {
    if (r.k != K.trec) { return false; };
    let have = type_names(r);
    names.all((name) => name in have)
};

// The static type of `narrow(e, t)`: t itself for a record type; for a
// record pattern (tpat), the member of the subject's union that has those
// fields, or the union of the members that have them when there are
// several (the subject itself when it is a record). tunk when none.
def narrow_type(s: Type, t: Type) -> Type {
    let tk: long = t.k;
    let sk: long = s.k;
    if (is_prim_type(unfold(t))) { unfold(t) }
    else if (tk != K.tpat) { t }
    else if (sk == K.trec) {
        let pat: TPat = t;
        if (rec_has_names(s, pat.names)) { s } else { t_unk() }
    } else if (sk == K.tunion) {
        let ms = members(s);
        let pat: TPat = t;
        let names: [str] = pat.names;
        let found: [Type] = [];
        ms.foreach((e) => {
            if (rec_has_names(e, names)) { found += e; }
        });
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
        i++;
    };
    if (ok) { { typ: ft, st: st } } else { { typ: t_unk(), st: st } }
};

// The two dot names a map keeps for itself, in the words a store needs:
// `.length` IS a property (the entry count), so it is a place nowhere, while
// `.ptr` is not one at all -- a map has no data block to point into, which is
// what the read says too (typeof_prop).
def map_dot_prop_msg(st: TcSt, t: Type, key: str, line: long, col: long) -> TcSt {
    if (key == "ptr") {
        fail(st, "cannot field-assign " + tstr(t) + ": it has no property '" + key + "' (it has '.length')", line, col)
    } else {
        fail(st, "cannot field-assign " + tstr(t) + " ('" + key + "' is a property, not an entry)", line, col)
    }
};

def dotassign_map(st: TcSt, t: Type, node: DotAssign) -> TcRes {
    let key: str = node.key;
    if (key == "length" || key == "ptr") {
        st = map_dot_prop_msg(st, t, key, node.line, node.col);
        return tc_res(t_unk(), st)
    };
    let map: TMap = t;
    if (!map_key_is_str(t)) {
        st = fail(st, "cannot field-assign " + tstr(t) + ": a dot name is a string, so the map's keys must be too (use m[\"" + key + "\"] = v)", node.line, node.col);
        return tc_res(t_unk(), st)
    };
    let v = typeof_want(st, node.v, map.of);
    st = expect_type(v.st, v.typ, map.of, "map entry '" + key + "'", node.line, node.col);
    tc_res(map.of, st)
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

// Every member of a union must be a record or a primitive (primitive
// members are boxed in hidden one-field records at run time; they are told
// apart by their hidden field names).
def union_ok(t: Type) -> bool {
    members(t).all((m) => m.k == K.trec || is_boxable_type(m))
};

// got flows into the union want: a member does (a record equal to some
// member: membership is exact, `{a: 1, b: 2}` is no `{a: long}`), and so
// does a union whose every member does.
def union_accepts(got: Type, want: Type) -> bool {
    if (got.k == K.tunion) { members(got).all((m) => union_accepts(m, want)) }
    else { members(want).some((m) => tcompat(got, m)) }
};

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
                ex = ex * 10 + (s[i:i + 1][0] - 48);
                if (ex > 100001) { past = true; ex = 100002; };
            };
            i = i + 1;
        };
        if (neg) { ex = 0 - ex; };
    };
    ex - nfrac
};

def num_is_float(s: str) -> bool {
    radix_of(s) == 0 && (s.contains(".") || s.contains("e") || s.contains("E"))
};

def num_mantissa_zero(s: str) -> bool {
    let end = len(s);
    let eb = index_of(s, "e");
    if (eb < 0) { eb = index_of(s, "E"); };
    if (eb >= 0) { end = eb };
    let i = 0;
    if (s[0:1] == "-" || s[0:1] == "+") { i = 1 };
    let all = true;
    while (all && i < end) {
        let c = s[i:i + 1];
        if (c != "0" && c != ".") { all = false };
        i++
    };
    all
};

def field_merge(fields: [Field], name: str, typ: Type) -> [Field] {
    for i in 0..len(fields) {
        if (fields[i].name == name) { return field_merge_dup(fields, name, typ); };
    };
    fields += { name: name, opt: false, typ: typ };
    fields
};

def field_merge_dup(fields: [Field], name: str, typ: Type) -> [Field] {
    let out: [Field] = [];
    let i = 0;
    let seen = false;
    while (i < len(fields)) {
        let f = fields[i];
        let fnm: str = f.name;
        if (fnm == name) {
            if (!(seen)) {
                out += { name: name, opt: false, typ: typ };
                seen = true;
            };
        } else {
            out += f;
        };
        i++;
    };
    if (!(seen)) {
        out += { name: name, opt: false, typ: typ };
    };
    out
};

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
    else if (t.k == K.tbigint) { true }
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
    else if (t.k == K.tpack) { true }
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

// line/col are the NAME's, not the keyword's: a go-to-definition and a
// semantic-token highlight both want the name, and every diagnostic position
// wants the keyword. -1 means the binding has no position in the source at
// all -- an intrinsic, or a name the program links against from another unit.
type Binding = { name: str, typ: Type, kind: str, fdepth: long, line: long, col: long };
type Lookup = { typ: Type, kind: str, fdepth: long };
type TcSt = { bindings: [Binding], errors: [Diag], ret: Type, self: Type, fdepth: long, loops: long, loop_fd: long };
type TcRes = { typ: Type, st: TcSt };

def tc_res(typ: Type, st: TcSt) -> TcRes {
    { typ: typ, st: st }
};

let tc_ix: NameIx = parser.nameix_new(8);
let tc_ixn = 0;

// The consts the emitter may not fold (native.y fold_consts): a record const
// read as a whole value (it may then be aliased and written through) and any
// const whose address is taken. tc_dotbase is set while the object of a
// `name.field` read is checked, which is not such a read.
let tc_esc: [str] = [];
let tc_dotbase = false;

// Whether the program checked last has a `region { .. }` (escape.y skips the
// walk that checks them when it has none).
let tc_saw_region = false;

def saw_region() -> bool { tc_saw_region };

def escaped() -> [str] { tc_esc };

// `l in r` that the emitter compiles to compares, building no array (native.y
// in_chain): l a name or a literal, r an array literal of integer literals or
// of string literals. lint.y does not call such an `in` in a loop a rebuilt
// array.
def in_compares(l: Node, r: Node) -> bool {
    let lk = l.k;
    if (r.k != K.array || (lk != K.id && lk != K.num && lk != K.str)) { return false; };
    let a: ArrLit = r;
    let es = a.elems;
    if (len(es) == 0) { return false; };
    let k0 = es[0].k;
    if (k0 != K.num && k0 != K.str) { return false; };
    let ok = true;
    for i in 0..len(es) {
        let e = es[i];
        if (e.k != k0) { ok = false; } else if (k0 == K.num) {
            let lit: Leaf = e;
            if (num_is_float(lit.v)) { ok = false; };
        };
    };
    ok
};

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
        if (bindings[i].name == name) { at = i; i = -1; };
        i = i - 1;
    };
    if (at < 0 && i >= 0) {
        if (len(name) > 0) {
            at = parser.nameix_get(tc_ix, name);
        } else {
            while (i >= 0) {
                if (bindings[i].name == name) { at = i; i = -1; };
                i = i - 1;
            };
        };
    };
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
            tc_ixn++;
        };
    };
    {...st, bindings: bindings}
};

// ── the checker ──────────────────────────────────────────────────────────
// Threaded state st = { bindings, errors, ret, self, fdepth }.
// typeof_* returns { typ, st }.

// State records are copied; their binding and diagnostic arrays stay shared.
def st_errors(st: TcSt, errs: [Diag]) -> TcSt { {...st, errors: errs} };
def st_self(st: TcSt, selfv: Type) -> TcSt { {...st, self: selfv} };
// Entering a loop: one deeper, and the innermost loop's function depth is
// this one's. `loop_fd: -1` means "no loop", so a stale depth can never be
// mistaken for a live one.
def st_loop(st: TcSt, n: long, fd: long) -> TcSt {
    {...st, loops: n, loop_fd: fd}
};

def st_ret(st: TcSt, ret: Type) -> TcSt { {...st, ret: ret} };

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

/** `ptr_from(n)` written directly, as an operand? */
def is_ptr_from_call(n: Node) -> bool {
    if (n.k == K.call) {
        let call: Call = n;
        let c = call.callee;
        if (c.k == K.id) {
            let id: Leaf = c;
            id.v == "ptr_from"
        } else { false }
    } else {
        false
    }
};

/** ptr_from makes a pointer with no pointee type, which anything accepts; read
 *  or written through directly it would be silently unchecked. The type has to
 *  be written first, on a binding. */
def no_direct_ptr_from(st: TcSt, e: Node, line: long, col: long) -> TcSt {
    if (is_ptr_from_call(e)) {
        fail(st, "ptr_from has no pointee type to read or write through; bind it first: let p: *T = ptr_from(n)", line, col)
    } else { st }
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

def is_ptr_math_int(t: Type) -> bool {
    t.k == K.tlong || t.k == K.tbyte
};

def ptr_math_kind(op: str, lt: Type, rt: Type) -> str {
    let lu = unfold(lt);
    let ru = unfold(rt);
    if (op == "+") {
        if (lu.k == K.tptr && (ru.k == K.tlong || ru.k == K.tbyte)) { "ptr_int" }
        else if (ru.k == K.tptr && (lu.k == K.tlong || lu.k == K.tbyte)) { "int_ptr" }
        else { "" }
    } else if (op == "-") {
        if (lu.k == K.tptr && (ru.k == K.tlong || ru.k == K.tbyte)) { "ptr_int" }
        else if (lu.k == K.tptr && ru.k == K.tptr) { "ptr_ptr" }
        else { "" }
    } else { "" }
};

def typeof_ptr_arith(st: TcSt, op: str, lt: Type, rt: Type, line: long, col: long) -> TcRes {
    let lu = unfold(lt);
    let ru = unfold(rt);
    if (op == "+") {
        if (lu.k == K.tptr && is_ptr_math_int(ru)) { tc_res(lu, st) }
        else if (ru.k == K.tptr && is_ptr_math_int(lu)) { tc_res(ru, st) }
        else {
            st = fail(st, "cannot add " + tstr(lt) + " and " + tstr(rt) + " (pointer arithmetic needs a pointer and a long/byte offset)", line, col);
            tc_res(t_unk(), st)
        }
    } else if (op == "-") {
        if (lu.k == K.tptr && is_ptr_math_int(ru)) { tc_res(lu, st) }
        else if (lu.k == K.tptr && ru.k == K.tptr) {
            if (teq(lu, ru)) { tc_res(type_node({ k: K.tlong }), st) }
            else {
                st = fail(st, "pointer subtraction needs identical pointer types, got " + tstr(lu) + " and " + tstr(ru), line, col);
                tc_res(t_unk(), st)
            }
        } else {
            st = fail(st, "cannot subtract " + tstr(rt) + " from " + tstr(lt) + " (pointer arithmetic needs a pointer and a long/byte offset)", line, col);
            tc_res(t_unk(), st)
        }
    } else {
        st = fail(st, "operator '" + op + "' is not defined on pointers", line, col);
        tc_res(t_unk(), st)
    }
};

// Binary-operator result typing. Split out of the `bin` arm so the operator
// table there stays a flat `op == "..."` dispatch and each operator's rule
// lives in one named place.
def type_is_array(t: Type) -> bool { t.k == K.tarr || t.k == K.tarrfix };
def type_string_operand(t: Type) -> bool { is_prim_type(t) || t.k == K.tunk };

def type_array_sum(left: Type, right: Type) -> Type {
    let source = right;
    if (type_is_array(left) && !(type_is_array(right) && arr_plus_kind(left, right) == "prepend")) { source = left; };
    type_node({k: K.tarr, of: arr_elem_of(source)})
};

// Result typing shared with native inference; callers validate the operands.
def binary_result(op: str, lt: Type, rt: Type) -> Type {
    let left = unfold(lt);
    let right = unfold(rt);
    if (op in ["+", "-", "*", "/", "%", "::"]) {
        let ptr = ptr_math_kind(op, left, right);
        if (ptr == "ptr_int") { return left; };
        if (ptr == "int_ptr") { return right; };
        if (ptr == "ptr_ptr") { return type_node({k: K.tlong}); };
        if (op == "+" && (type_is_array(left) || type_is_array(right))) { return type_array_sum(left, right); };
        if (op == "::") { return type_node({k: K.tarr, of: arr_elem_of(right)}); };
        if (op == "+" && (left.k == K.tstr || right.k == K.tstr)) { return type_node({k: K.tstr}); };
        return type_numeric_result(left, right);
    };
    type_node({k: is_bits_op(op) ? K.tlong : K.tbool})
};

def typeof_arith(st: TcSt, op: str, lt: Type, rt: Type, line: long, col: long) -> TcRes {
    let lu = unfold(lt);
    let ru = unfold(rt);
    if ((op == "+" || op == "-") && (lu.k == K.tptr || ru.k == K.tptr)) {
        return typeof_ptr_arith(st, op, lt, rt, line, col);
    };
    if (op == "+") {
        if (type_is_array(lt) || type_is_array(rt)) { return typeof_arith_arr(st, op, lt, rt, line, col); };
        if ((lt.k == K.tstr && type_string_operand(rt)) || (rt.k == K.tstr && type_string_operand(lt))) {
            return tc_res(type_node({k: K.tstr}), st);
        };
    };
    typeof_arith_long(st, op, lt, rt, line, col)
};

def typeof_arith_arr(st: TcSt, op: str, lt: Type, rt: Type, line: long, col: long) -> TcRes {
    if (op != "+") {
        return tc_res(t_unk(), fail(st, "'" + op + "' is not defined on arrays (only '+' copies, '+='/'*=' mutate)", line, col));
    };
    let result = type_array_sum(lt, rt);
    let elem = arr_elem_of(result);
    if (type_is_array(lt) && type_is_array(rt)) {
        if (arr_plus_kind(lt, rt) == "cat") {
            st = expect_type(st, arr_elem_of(rt), arr_elem_of(lt), "'+' concatenated elements", line, col);
        };
    } else { st = expect_type(st, type_is_array(lt) ? rt : lt, elem, "'+' element", line, col); };
    tc_res(result, st)
};

def arr_plus_kind(lt: Type, rt: Type) -> str {
    let ltype: Type = t_unk();
    let rtype: Type = t_unk();
    ltype = arr_elem_of(lt);
    rtype = arr_elem_of(rt);
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
        let elem = arr_elem_of(rt);
        st = expect_type(st, lt, elem, "'::' element", line, col);
        let typ: Type = { k: K.tarr, of: elem };
        { typ: typ, st: st }
    } else {
        st = fail(st, "'::' needs an array on the right, got " + tstr(rt), line, col);
        { typ: t_unk(), st: st }
    }
};

def typeof_arith_long(st: TcSt, op: str, lt: Type, rt: Type, line: long, col: long) -> TcRes {
    let result = type_numeric_result(lt, rt);
    tc_res(result, type_operands(st, op, lt, rt, result, line, col))
};

def type_operands(st: TcSt, op: str, lt: Type, rt: Type, want: Type, line: long, col: long) -> TcSt {
    st = expect_type(st, lt, want, "'" + op + "' left operand", line, col);
    expect_type(st, rt, want, "'" + op + "' right operand", line, col)
};

// The bitwise binary operators. (native.y asks too: their result is a long.)
def is_bits_op(op: str) -> bool {
    op in ["&", "|", "^", "<<", ">>", ">>>"]
};

// `&` `|` `^` `<<` `>>` `>>>` take integers only: a byte operand widens and
// the result is a long. No float, no bool (`&&` and `||` are the logical
// forms).
def typeof_bits(st: TcSt, op: str, lt: Type, rt: Type, line: long, col: long) -> TcRes {
    tc_res(type_node({k: K.tlong}), type_operands(st, op, lt, rt, type_node({k: K.tlong}), line, col))
};

def typeof_cmp(st: TcSt, op: str, lt: Type, rt: Type, line: long, col: long) -> TcRes {
    let lu = unfold(lt);
    let ru = unfold(rt);
    if (lu.k == K.tptr || ru.k == K.tptr) {
        if (lu.k == K.tptr && ru.k == K.tptr && teq(lu, ru)) {
            tc_res(type_node({ k: K.tbool }), st)
        } else {
            st = fail(st, "'" + op + "' compares " + tstr(lt) + " with " + tstr(rt) + " (pointer ordering needs identical pointer types)", line, col);
            tc_res(t_unk(), st)
        }
    } else if (lt.k == K.tstr) {
        // str < str is lexicographic ordering (byte by byte), matching the
        // y_str_cmp helper native.y emits.
        st = expect_type(st, rt, { k: K.tstr }, "'" + op + "' right operand", line, col);
        tc_res({ k: K.tbool }, st)
    } else {
        tc_res(type_node({k: K.tbool}), type_operands(st, op, lt, rt, type_numeric_result(lt, rt), line, col))
    }
};

// Both sides numeric (long/byte/float): `==` and `!=` compare by value
// across widths, which is what the compiled code does (native.y gen_bin_rest
// emits a plain word compare).


def num_eq_ok(lt: Type, rt: Type) -> bool {
    if (is_num_kind(lt)) { is_num_kind(rt) } else { false }
};

def typeof_eq(st: TcSt, op: str, lt: Type, rt: Type, line: long, col: long) -> TcRes {
    // str compares by content. `x == none` is the option's is-none check.
    // Nested ifs throughout (house style — one kind per arm).
    if (teq(lt, rt)) { tc_res({ k: K.tbool }, st) }
    else if (num_eq_ok(lt, rt)) {
        // Numeric kinds compare across widths: a byte IS a small long, so
        // `'\n'` needs no cast (and long/float already coerce in `<`).
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

def in_int_ok(lt: Type, of: Type) -> bool {
    let l = unfold(lt);
    let o = unfold(of);
    if (l.k == K.tbyte && o.k == K.tlong) { true }
    else if (l.k == K.tlong && o.k == K.tbyte) { true }
    else { false }
};

// `"k" in m` -- is that key in the map. A boolean, and the
// scan a map read is (native.y gen_map_get's "has" mode), so it costs what a
// read costs. Only called with a map on the right (the caller tests).
def typeof_in_map(st: TcSt, lt: Type, rt: Type, line: long, col: long) -> TcRes {
    let map: TMap = unfold(rt);
    st = expect_type(st, lt, map.key, "'in' left operand", line, col);
    tc_res(type_node({ k: K.tbool }), st)
};

def typeof_in(st: TcSt, lt: Type, rt: Type, line: long, col: long) -> TcRes {
    let r = unfold(rt);
    if (r.k == K.tstr) {
        if (lt.k == K.tbyte || lt.k == K.tstr || lt.k == K.tunk) {
            tc_res(type_node({ k: K.tbool }), st)
        } else {
            tc_res(t_unk(), fail(st, "'in' on a str needs a byte or a str on the left, got " + tstr(lt), line, col))
        }
    } else if (r.k == K.tarr) {
        let a: TOf = r;
        if (lt.k == K.tunk || teq(unfold(lt), unfold(a.of)) || in_int_ok(lt, a.of)) {
            tc_res(type_node({ k: K.tbool }), st)
        } else {
            tc_res(t_unk(), fail(st, "'in' on an array needs one of its elements on the left, got " + tstr(lt), line, col))
        }
    } else if (r.k == K.tarrfix) {
        let a: TFix = r;
        if (lt.k == K.tunk || teq(unfold(lt), unfold(a.of)) || in_int_ok(lt, a.of)) {
            tc_res(type_node({ k: K.tbool }), st)
        } else {
            tc_res(t_unk(), fail(st, "'in' on an array needs one of its elements on the left, got " + tstr(lt), line, col))
        }
    } else {
        tc_res(t_unk(), fail(st, "'in' needs a str, an array or a map on the right, got " + tstr(rt), line, col))
    }
};

def typeof_logic(st: TcSt, op: str, lt: Type, rt: Type, line: long, col: long) -> TcRes {
    // Truthiness: any 8-byte value decides (nonzero = true), like the C
    // runtime. The result is always a bool; operands keep their own types.
    tc_res({ k: K.tbool }, st)
};

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
    else if (got.k == K.tfunc && want.k == K.tfunc) {
        let g: TFunc = got;
        let w: TFunc = want;
        w.ret.k == K.tvoid && teq_list(g.args, w.args, 0)
    }
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
    else if (got.k == K.tpack) { pack_to_ptr_ok(got, want) }
    else if (want.k == K.tpack) { ptr_to_pack_ok(got, want) }
    else if (got.k == K.trec) { false }
    else if (want.k == K.trec) { false }
    else if (got.k == K.tstr) {
        if (want.k == K.tptr) { true } else { false }
    } else if (got.k == K.tlong) {
        if (want.k == K.tfloat) { true }
        else if (want.k == K.tbyte) { true }
        else if (want.k == K.tbigint) { true }
        else { false }
    } else if (got.k == K.tbyte) {
        // byte widens to long (and on to float) — it is an 8-bit unsigned
        // integer, so every value is representable.
        if (want.k == K.tlong) { true }
        else if (want.k == K.tfloat) { true }
        else if (want.k == K.tbigint) { true }
        else { false }
    } else if (want.k == K.tbigint) {
        // long, byte and float convert to bigint silently: from long/byte
        // exactly, from float by truncating toward zero. The reverse needs
        // tolong()/tofloat().
        got.k == K.tlong || got.k == K.tbyte || got.k == K.tfloat
    } else { false }
};

def arr_lit_adopts(got: Type, want: Type, n: long) -> bool {
    if (got.k == K.tarr) { arr_lit_adopts_go(got, want, n) }
    else if (got.k == K.tarrfix) { arr_lit_adopts_go(got, want, n) }
    else { false }
};

def arr_lit_adopts_go(got: Type, want: Type, n: long) -> bool {
    if (want.k == K.tarr) {
        let warr: TOf = want;
        let ge = arr_elem_of(got);
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

let tc_index: bool = false;
let tci_keys: [long] = [];
let tci_typs: [Type] = [];
let tci_bkts: [[long]] = [];

def tci_reset() -> void {
    let keys: [long] = [];
    let typs: [Type] = [];
    let bkts: [[long]] = [];
    for i in 0..1024 {
        let b: [long] = [];
        bkts += b;
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

let tc_heap: bool = false;
let tch_ix: NameIx = parser.nameix_new(2);
let tch_typs: [Type] = [];
let tch_alloc: [[long]] = [];

def heap_index_on() -> void {
    tc_heap = true;
    tc_index = true;
    tch_ix = parser.nameix_new(1024);
    tch_typs = [];
    // Not the position table: its buckets are sized for one file in an editor.
    let none: [[long]] = [];
    tci_bkts = none;
};

def heap_index_off() -> void {
    tc_heap = false;
    tc_index = false;
};

def tch_key(line: long, col: long, k: long) -> str {
    tostring((line * 65536 + col) * 128 + k)
};

def tch_note(node: Node, t: Type) -> void {
    let k = node.k;
    if (k == K.call || k == K.bin || k == K.id || k == K.dot || k == K.index || k == K.un || k == K.narrow
        || k == K.array || k == K.arrrep || k == K.str || k == K.num || k == K.bool || k == K.char || k == K.func) {
        let key = tch_key(node.line, node.col, k);
        if (parser.nameix_get(tch_ix, key) < 0) {
            parser.nameix_put(tch_ix, key, len(tch_typs));
            tch_typs += t;
        };
    };
};

// The type the checker gave the node of kind k at (line, col), or tunk().
def heap_type(line: long, col: long, k: long) -> Type {
    let i = parser.nameix_get(tch_ix, tch_key(line, col, k));
    if (i < 0) { t_unk() } else { tch_typs[i] }
};

// A contextual conversion can allocate although its source is a plain word:
// bigint promotion, primitive union boxing, or a record layout conversion.
def heap_alloc(node: Node) -> bool {
    if (len(tch_alloc) == 0) { false } else {
        let key = (node.line * 65536 + node.col) * 128 + node.k;
        key in tch_alloc[key % 1021]
    }
};

def alloc_conversion(got0: Type, want0: Type, literal: bool) -> bool {
    if (got0 == want0) { return false; };
    let got = unfold(got0);
    let want = unfold(want0);
    (want.k == K.tbigint && got.k != K.tbigint && got.k != K.tvoid && got.k != K.tnone && got.k != K.tunk)
        || (!literal && (want.k == K.tunion || (want.k == K.trec && got.k == K.tunion)) && !teq(got, want)
            && (is_boxable_type(got) || got.k == K.trec || got.k == K.tunion))
};

def heap_context(node: Node, got: Type, want: Type) -> void {
    if (alloc_conversion(got, want, node.k == K.rec)) {
        if (len(tch_alloc) == 0) {
            for i in 0..1021 { let b: [long] = []; tch_alloc += b; };
        };
        let key = (node.line * 65536 + node.col) * 128 + node.k;
        let b = tch_alloc[key % 1021];
        if (!(key in b)) { b += key; };
    };
};

def output_alloc(name: str, t: Type) -> bool {
    let k = unfold(t).k;
    k != K.tstr && k != K.tbool && !(name == "print" && (k == K.tlong || k == K.tbyte || k == K.tfunc))
};

// One entry, unless the key is already there -- the FIRST type wins, as above.
def tci_note_key(key: long, t: Type) -> void {
    if (len(tci_bkts) > 0) {
        let bkt: [long] = tci_bkts[key % 1024];
        let seen = false;
        let i = 0;
        while (i < len(bkt)) {
            if (tci_keys[bkt[i]] == key) { seen = true; i = len(bkt); }
            else { i++; };
        };
        if (!seen) {
            tci_keys += key;
            tci_typs += t;
            bkt += len(tci_keys) - 1;
        };
    };
};

// Only ever called when tc_index is set: the flag is tested at the call site in
// typeof_expr rather than here, so the off path costs a load and a branch and
// not a call. Measured: testing it inside made the call itself the cost, and
// the call is per EXPRESSION, which is the checker's hottest path.
def tci_note(node: Node, t: Type) -> void {
    if (tc_heap) { tch_note(node, t) };
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
                else { i++; };
            };
            if (!seen) {
                tci_keys += key;
                tci_typs += t;
                bkt += len(tci_keys) - 1;
            };
        };
        let nk = node.k;
        if (nk == K.decl) {
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
            else { i++; };
        };
    };
    found
};

def typeof_expr(st: TcSt, node: Node) -> TcRes {
    nest++;
    if (nest > MAX_NEST) { too_deep("an expression", node.line, node.col); };
    let r = typeof_expr_go(st, node);
    nest--;
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

def typeof_special_node(st: TcSt, node: Node) -> TcRes {
    let k = node.k;
    if (k == K.bignum) {
        // 1000n always has the built-in bigint type; the value is built at
        // run time (native.y gen_biglit).
        tc_res(type_node({ k: K.tbigint }), st)
    } else if (k == K.num) {
        let lit: Leaf = node;
        if (num_is_float(lit.v)) {
            let dp = num_net_exp(lit.v);
            if (dp > 100000 || dp < 0 - 100000) {
                if (!num_mantissa_zero(lit.v)) {
                    st = fail(st, "float literal magnitude out of range (a double holds 10^-308 to 10^308)", lit.line, lit.col);
                }
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
        let db = tc_dotbase;
        tc_dotbase = false;
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
                if (!db && got.kind == "const" && !is_prim_type(got.typ)) { tc_esc += id.v; };
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
            } else if (r.typ.k == K.tbigint) {
                tc_res(type_node({ k: K.tbigint }), st)
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
                if (got.kind == "const") { tc_esc += id.v; };
                if (got.kind == "") {
                    st = fail(st, "undefined variable '" + id.v + "'", addr.line, addr.col);
                    tc_res(t_unk(), st)
                } else if (got.kind == "func" || got.kind == "intrinsic") {
                    st = fail(st, "cannot take the address of function '" + id.v + "'", addr.line, addr.col);
                    tc_res(t_unk(), st)
                } else if (got.typ.k == K.tarr || got.typ.k == K.tarrfix) {
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
                    let elem = arr_elem_of(got.typ);
                    tc_res(type_node({ k: K.tptr, to: elem }), st)
                } else {
                    st = fail(st, "cannot index " + tstr(got.typ) + " (only arrays)", addr.line, addr.col);
                    tc_res(t_unk(), st)
                }
            } else {
                // general base (`&grid[0][i]`, `&rec.v[i]`): an element
                // address of any array expression.
                let br = typeof_expr(st, arr);
                st = br.st;
                if (br.typ.k == K.tarrfix || br.typ.k == K.tarr) {
                    let r = typeof_expr(st, ix);
                    st = r.st;
                    st = expect_type(st, r.typ, type_node({ k: K.tlong }), "array index", addr.line, addr.col);
                    let elem = arr_elem_of(br.typ);
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
        st = no_direct_ptr_from(st, deref.e, deref.line, deref.col);
        let r = typeof_expr(st, deref.e);
        st = r.st;
        if (r.typ.k == K.tptr) {
            let ptr: TPtr = r.typ;
            tc_res(pointee_value(ptr.to), st)
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
        else if (op == "in") {
            if (unfold(r.typ).k == K.tmap) {
                typeof_in_map(st, l.typ, r.typ, bin.line, bin.col)
            } else {
                typeof_in(st, l.typ, r.typ, bin.line, bin.col)
            }
        }
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
        st = st_loop((typeof_block(st, loop.body)).st, saved_loops, saved_fd);
        tc_res(type_node({ k: K.tvoid }), st)
    } else if (k == K.kw_for) {
        let loop: For = node;
        // for (init; cond; step) body — init/step are statements, and the
        // loop variable stays visible afterwards (same scope rule as `let`).
        st = (typeof_expr(st, loop.init)).st;
        let fc = typeof_expr(st, loop.cond);
        st = expect_type(fc.st, fc.typ, type_node({ k: K.tbool }), "'for' condition", loop.line, loop.col);
        let saved_loops = st.loops;
        let saved_fd = st.loop_fd;
        st = st_loop(st, saved_loops + 1, st.fdepth);
        st = st_loop((typeof_block(st, loop.body)).st, saved_loops, saved_fd);
        tc_res(type_node({ k: K.tvoid }), (typeof_expr(st, loop.step)).st)
    } else if (k == K.kw_foreach) {
        let loop: Foreach = node;
        // foreach (x in arr) body — x takes the array's element type.
        let fe = typeof_expr(st, loop.iter);
        st = fe.st;
        let elt: Type = t_unk();
        // A recursive alias used as a variable's OWN type is a tref (`type Ids = [Ids]` is legal),
        // so what the iterable IS has to
        // be read through the alias -- as the emitter's own infer does, and as
        // every other shape test here already does.
        let fu = unfold(fe.typ);
        if (fu.k == K.tarr) { let arr: TOf = fu; elt = arr.of; }
        else if (fu.k == K.tarrfix) { let arr: TFix = fu; elt = arr.of; }
        else if (fu.k == K.tmap) { let mp: TMap = fu; elt = mp.key; }
        else if (fu.k == K.tstr) { elt = type_node({ k: K.tbyte }); }
        else if (fu.k == K.tunk) { }
        else {
            st = fail(st, "'foreach' needs an array, a map or a string, got " + tstr(fe.typ), loop.line, loop.col);
        };
        st = st_bind(st, loop.name, elt, "local", loop.line, loop.col);
        let saved_loops = st.loops;
        let saved_fd = st.loop_fd;
        st = st_loop(st, saved_loops + 1, st.fdepth);
        st = st_loop((typeof_block(st, loop.body)).st, saved_loops, saved_fd);
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
        st = st_loop((typeof_block(st, loop.body)).st, saved_loops, saved_fd);
        tc_res(type_node({ k: K.tvoid }), st)
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
        st = no_direct_ptr_from(st, store.p, store.line, store.col);
        let p = typeof_expr(st, store.p);
        let pt: Type = p.typ;
        let pw: Type = type_node({ k: K.tnone });
        if (pt.k == K.tptr) { let ptr: TPtr = pt; pw = pointee_value(ptr.to); }
        let v = typeof_want(p.st, store.v, pw);
        st = v.st;
        if (p.typ.k == K.tptr) {
            let ptr: TPtr = p.typ;
            st = expect_type(st, v.typ, pointee_value(ptr.to), "store through pointer", store.line, store.col);
            tc_res(pointee_value(ptr.to), st)
        } else if (p.typ.k == K.tunk || v.typ.k == K.tunk) {
            tc_res(t_unk(), st)
        } else {
            st = fail(st, "store target must be *T, got " + tstr(p.typ), store.line, store.col);
            tc_res(t_unk(), st)
        }
    } else if (k == K.kw_break || k == K.kw_continue) {
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
                        sfs.foreach((sf) => {
                            fields = field_merge(fields, sf.name, sf.typ);
                        });
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
                i++;
            };
            if (ok) {
                tc_res(type_node({ k: K.trec, fields: fields }), st)
            } else {
                tc_res(t_unk(), st)
            }
        }
    } else if (k == K.map) {
        let map: RecLit = node;
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
            gi++;
        };
        if (gok) {
            tc_res(map_type_of(gt), st)
        } else {
            tc_res(t_unk(), st)
        }
    } else if (k == K.dot) {
        let dot: Dot = node;
        let dobj = dot.obj;
        let dkey = dot.key;
        tc_dotbase = dobj.k == K.id;
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
        if (index.arr.k == K.id) {
            let id: Leaf = index.arr;
            let got = lookup(st.bindings, id.v);
            if (got.kind == "") {
                st = fail(st, "undefined variable '" + id.v + "'", index.line, index.col);
                tc_res(t_unk(), st)
            } else if (unfold(got.typ).k == K.tarrfix || unfold(got.typ).k == K.tarr) {
                st = check_visible(st, got, id.v, index.line, index.col);
                let r = typeof_expr(st, index.idx);
                st = r.st;
                st = expect_type(st, r.typ, type_node({ k: K.tlong }), "array index", index.line, index.col);
                let elem = arr_elem_of(unfold(got.typ));
                tc_res(elem, st)
            } else if (unfold(got.typ).k == K.tmap) {
                // m[k]: the key must match K; a read is ALWAYS optional --
                // V? for any V (none when the key is missing).
                st = check_visible(st, got, id.v, index.line, index.col);
                let map: TMap = unfold(got.typ);
                let r = typeof_expr(st, index.idx);
                st = r.st;
                st = expect_type(st, r.typ, map.key, "map key", index.line, index.col);
                tc_res(type_node({ k: K.topt, of: map.of }), st)
            } else if (unfold(got.typ).k == K.tstr) {
                // s[i]: the byte at i (trapped when out of bounds)
                st = check_visible(st, got, id.v, index.line, index.col);
                let r = typeof_expr(st, index.idx);
                st = r.st;
                st = expect_type(st, r.typ, type_node({ k: K.tlong }), "string index", index.line, index.col);
                tc_res(type_node({ k: K.tbyte }), st)
            } else if (unfold(got.typ).k == K.tunk || unfold(got.typ).k == K.tnone || unfold(got.typ).k == K.tname) {
                st = (typeof_expr(st, index.idx)).st;
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
            if (unfold(br.typ).k == K.tarrfix || unfold(br.typ).k == K.tarr) {
                let ri = typeof_expr(st, index.idx);
                st = ri.st;
                st = expect_type(st, ri.typ, type_node({ k: K.tlong }), "array index", index.line, index.col);
                let elem = arr_elem_of(unfold(br.typ));
                tc_res(elem, st)
            } else if (unfold(br.typ).k == K.tmap) {
                let map: TMap = unfold(br.typ);
                let ri = typeof_expr(st, index.idx);
                st = ri.st;
                st = expect_type(st, ri.typ, map.key, "map key", index.line, index.col);
                tc_res(type_node({ k: K.topt, of: map.of }), st)
            } else if (unfold(br.typ).k == K.tstr) {
                let ri = typeof_expr(st, index.idx);
                st = ri.st;
                st = expect_type(st, ri.typ, type_node({ k: K.tlong }), "string index", index.line, index.col);
                tc_res(type_node({ k: K.tbyte }), st)
            } else if (unfold(br.typ).k == K.tunk || unfold(br.typ).k == K.tnone || unfold(br.typ).k == K.tname) {
                // poison quietly (tcompat law) — the missing annotation
                // reports at its own site.
                st = (typeof_expr(st, index.idx)).st;
                tc_res(t_unk(), st)
            } else if (unfold(br.typ).k == K.tvoid && (barr.k == K.kw_if || barr.k == K.block)) {
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
        st = const_store(st, assign.obj, assign.line, assign.col);
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
            } else if (pack_of(got.typ).k == K.tpack) {
                dotassign_pack(st, pack_of(got.typ), assign)
            } else if (unfold(got.typ).k == K.tunion) {
                dotassign_union(st, unfold(got.typ), assign)
            } else if (unfold(got.typ).k == K.tmap) {
                dotassign_map(st, unfold(got.typ), assign)
            } else {
                st = fail(st, "cannot field-assign " + tstr(got.typ) + " (only records)", assign.line, assign.col);
                tc_res(t_unk(), st)
            }
        } else {
            // General object (`a[0].f = v`, `x.y.f = v`): the object
            // expression's static type must be a record with the field.
            let obr = typeof_expr(st, assign.obj);
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
            } else if (pack_of(obr.typ).k == K.tpack) {
                dotassign_pack(st, pack_of(obr.typ), assign)
            } else if (obr.typ.k == K.tunion) {
                dotassign_union(st, obr.typ, assign)
            } else if (obr.typ.k == K.tmap) {
                dotassign_map(st, obr.typ, assign)
            } else {
                st = fail(st, "cannot field-assign " + tstr(obr.typ) + " (only records)", assign.line, assign.col);
                tc_res(t_unk(), st)
            }
        }
    } else if (k == K.idxassign) {
        let assign: IdxAssign = node;
        st = const_store(st, assign.arr, assign.line, assign.col);
        if (assign.arr.k == K.id) {
            let id: Leaf = assign.arr;
            let got = lookup(st.bindings, id.v);
            if (got.kind == "") {
                st = fail(st, "undefined variable '" + id.v + "'", assign.line, assign.col);
                tc_res(t_unk(), st)
            } else if (unfold(got.typ).k == K.tarrfix || unfold(got.typ).k == K.tarr) {
                st = check_visible(st, got, id.v, assign.line, assign.col);
                let ix = typeof_expr(st, assign.idx);
                st = ix.st;
                st = expect_type(st, ix.typ, type_node({ k: K.tlong }), "array index", assign.line, assign.col);
                let elem = arr_elem_of(unfold(got.typ));
                let v = typeof_want(st, assign.v, elem);
                st = v.st;
                st = expect_type(st, v.typ, elem, "array element", assign.line, assign.col);
                tc_res(elem, st)
            } else if (unfold(got.typ).k == K.tmap) {
                let map: TMap = unfold(got.typ);
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
            let br = typeof_expr(st, assign.arr);
            st = br.st;
            if (unfold(br.typ).k == K.tarrfix || unfold(br.typ).k == K.tarr) {
                let ix = typeof_expr(st, assign.idx);
                st = ix.st;
                st = expect_type(st, ix.typ, type_node({ k: K.tlong }), "array index", assign.line, assign.col);
                let elem = arr_elem_of(unfold(br.typ));
                let v = typeof_want(st, assign.v, elem);
                st = v.st;
                st = expect_type(st, v.typ, elem, "array element", assign.line, assign.col);
                tc_res(elem, st)
            } else if (unfold(br.typ).k == K.tmap) {
                let map: TMap = unfold(br.typ);
                let ix = typeof_expr(st, assign.idx);
                st = ix.st;
                st = expect_type(st, ix.typ, map.key, "map key", assign.line, assign.col);
                let v = typeof_want(st, assign.v, map.of);
                st = v.st;
                st = expect_type(st, v.typ, map.of, "map value", assign.line, assign.col);
                tc_res(map.of, st)
            } else if (unfold(br.typ).k == K.tunk || unfold(br.typ).k == K.tnone || unfold(br.typ).k == K.tname) {
                // poison quietly (tcompat law) — the missing annotation
                // reports at its own site.
                st = (typeof_expr(st, assign.idx)).st;
                st = (typeof_expr(st, assign.v)).st;
                tc_res(t_unk(), st)
            } else {
                st = fail(st, "cannot index " + tstr(br.typ) + " (only arrays and maps)", assign.line, assign.col);
                tc_res(t_unk(), st)
            }
        }
    } else if (k == K.array) {
        let array: ArrLit = node;
        let elems: [Node] = array.elems;
        if (len(elems) == 0) {
            tc_res(type_node({ k: K.tarr, of: t_free() }), st)
        } else {
            let r0 = typeof_expr(st, elems[0]);
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
                let elt = r0.typ;
                while (i < len(elems)) {
                    let r = typeof_expr(st, elems[i]);
                    st = r.st;
                    if (elt.k == K.tunk) {
                        if (r.typ.k == K.tlong) { elt = r.typ; }
                        if (r.typ.k == K.tbool) { elt = r.typ; }
                        if (r.typ.k == K.tstr) { elt = r.typ; }
                    } else {
                        st = expect_type(st, r.typ, elt, "array element", array.line, array.col);
                    };
                    i++;
                };
                tc_res(type_node({ k: K.tarr, of: elt }), st)
            }
        }
    } else if (k == K.char) {
        tc_res(type_node({ k: K.tbyte }), st)
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
    let t = node.typ;
    let s = pat_subject(r.typ, t);
    let sk: long = s.k;
    let tu = unfold(t);
    let tk: long = tu.k;
    if (tk == K.tunk) {
        // an alias that stands for no type (rename.y reported it)
    } else if (is_prim_type(tu)) {
        if (sk == K.tunk) {
        } else if (sk == K.tunion) {
            if (!pattern_fits(s, t)) {
                st = fail(st, "pattern type " + tstr(t) + " can never match " + tstr(s), node.line, node.col);
            };
        } else if (sk == K.trec) {
            st = fail(st, "match pattern type " + tstr(t) + " is not a record type", node.line, node.col);
        } else if (sk == K.topt) {
            // `if let long n = v`: the subject is an option, so the test is
            // the option's own and the type is its payload's.
            let inner = scalar_pat_narrow(s);
            let iu = unfold(inner);
            if (iu.k != K.tunk && !tcompat(iu, t) && !teq(iu, t)) {
                st = fail(st, "pattern type " + tstr(t) + " can never match " + tstr(s), node.line, node.col);
            };
        } else {
            if (!pattern_fits(s, t)) {
                st = fail(st, "pattern type " + tstr(t) + " can never match " + tstr(s), node.line, node.col);
            };
        };
    } else if (tk != K.trec && tk != K.tpat) {
        st = fail(st, "match pattern type " + tstr(t) + " is not a record or primitive type", node.line, node.col);
    } else if (sk == K.tunk) {
    } else if (sk == K.trec || sk == K.tunion) {
        if (tk == K.tpat) {
            if ((narrow_type(s, t)).k == K.tunk) {
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

// The type a pattern is tested against. A record pattern on an option whose
// payload is a record tests the payload (`if let Lvl c = o`, `o: Lvl?`: the
// option's own none test, then the record), as a scalar pattern does
// (scalar_pat_narrow); any other subject is itself.
def pat_subject(s: Type, t: Type) -> Type {
    let su = unfold(s);
    if (su.k == K.topt && !is_prim_type(unfold(t))) {
        let inner = scalar_pat_narrow(su);
        if (unfold(inner).k == K.trec) { unfold(inner) } else { s }
    } else {
        s
    }
};

def scalar_pat_narrow(s: Type) -> Type {
    let u = unfold(s);
    if (u.k == K.topt) { let opt: TOf = u; opt.of } else { s }
};

// The record type t is the subject s (a record) or one of its members (a
// union): membership is exact.
def pattern_fits(s: Type, t: Type) -> bool {
    let sk: long = s.k;
    if (sk == K.tunion) {
        (union_member(s, t)).k != K.tnone
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
    if (is_prim_type(tu)) {
        // The PATTERN's type is what is bound, not the subject's: for a union
        // subject (a primitive member is boxed in a hidden one-field record) the
        // member is `long`, and for an option subject the payload is. Taking
        // the subject instead would bind the whole union.
        tc_res(tu, r.st)
    } else if (tk == K.trec || tk == K.tpat) {
        tc_res(narrow_type(pat_subject(r.typ, t), t), r.st)
    } else {
        tc_res(t_unk(), r.st)
    }
};

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
        ms.foreach((e) => {
            if (!covered(e, cover)) { missing += tstr(e); }
        });
        if (len(missing) > 0) {
            st = fail(st, "non-exhaustive match: nothing matches " + join(missing, ", ") + " (add an arm or '_'" + hint + ")", node.line, node.col);
        }
    } else if (sk == K.trec && covered(s, cover)) {
    } else if (sk == K.topt && option_covered(s, cover)) {
    } else {
        st = fail(st, "non-exhaustive match on " + tstr(s) + " (add a '_' arm" + hint + ")", node.line, node.col);
    };
    tc_res(t_unk(), st)
};

// An option is covered by a `none` arm (cover marker void) together with
// either a `some(x)` arm (marker unk: any payload) or type arms that cover the
// payload: a record, every member of a union, or the payload's own type.
def option_covered(s: Type, cover: [Type]) -> bool {
    let has_none = false;
    let has_some = false;
    let exact = false;
    let opt: TOf = s;
    let inner = unfold(opt.of);
    for i in 0..len(cover) {
        let c = unfold(cover[i]);
        if (c.k == K.tvoid) { has_none = true; }
        else if (c.k == K.tunk) { has_some = true; }
        else if (teq(inner, c)) { exact = true; };
    };
    if (!has_none) { return false; };
    if (has_some || exact) { return true; };
    if (inner.k == K.trec) { return covered(inner, cover); };
    if (inner.k == K.tunion) {
        let ms = members(inner);
        for i in 0..len(ms) {
            if (!covered(ms[i], cover)) { return false; };
        };
        return true;
    };
    false
};

// A member is covered by a type arm of its type.
def covered(m: Type, cover: [Type]) -> bool {
    let any = false;
    cover.foreach((e) => {
        let c = unfold(e);
        let ck: long = c.k;
        if (ck == K.trec) {
            if (teq(m, c)) { any = true; }
        }
    });
    any
};

// a[lo:hi] = src: a is an array, src an array of the same element type.
def typeof_sliceassign(st: TcSt, node: SliceAssign) -> TcRes {
    st = const_store(st, node.arr, node.line, node.col);
    let ar = typeof_expr(st, node.arr);
    st = ar.st;
    let slo = node.lo;
    let shi = node.hi;
    if (!(slo.k == K.void)) {
        let rl = typeof_expr(st, slo);
        st = expect_type(rl.st, rl.typ, { k: K.tlong }, "slice start", node.line, node.col);
    };
    if (!(shi.k == K.void)) {
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
            ae = arr_elem_of(at);
            ve = arr_elem_of(vt);
            if (!(teq(ve, ae))) {
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

// The tpack under t: t itself, or the target of a pointer to one. Anything else
// answers some node that is not a tpack (callers test `.k == K.tpack`), so the
// common case, a field of an ordinary record, allocates nothing.
def pack_of(t: Type) -> Type {
    let u = unfold(t);
    if (u.k == K.tpack) { u }
    else if (u.k == K.tptr) {
        let p: TPtr = u;
        let v = unfold(p.to);
        if (v.k == K.tpack) { v } else { u }
    } else { u }
};

// A pack converts to a pointer to an identical pack: the same address.
def pack_to_ptr_ok(got: Type, want: Type) -> bool {
    if (want.k == K.tptr) {
        let wp: TPtr = want;
        teq(unfold(wp.to), got)
    } else { false }
};

// ... and a pointer to an identical pack converts back to the pack.
def ptr_to_pack_ok(got: Type, want: Type) -> bool {
    if (got.k == K.tptr) {
        let gp: TPtr = got;
        teq(unfold(gp.to), want)
    } else { false }
};

// Bytes a scalar field takes in memory; -1 when the type cannot be one.
def pack_scalar_size(t: Type) -> long {
    let u = unfold(t);
    if (u.k == K.tint) { let ti: TInt = u; ti.w }
    else if (u.k == K.tbyte || u.k == K.tbool) { 1 }
    else if (u.k == K.tlong || u.k == K.tfloat || u.k == K.tptr) { 8 }
    else { -1 }
};

def pack_field_size(t: Type) -> long {
    let u = unfold(t);
    if (u.k == K.tpack) { pack_size(u) }
    else if (u.k == K.tarrfix) {
        let a: TFix = u;
        let es = pack_scalar_size(a.of);
        if (es < 0) { -1 } else { es * a.n }
    }
    else { pack_scalar_size(u) }
};

// Bytes of a packed record or bitmap; -1 when a field cannot live in one.
def pack_size(t: Type) -> long {
    let pk: TPack = t;
    if (pk.bk > 0) { pk.bk } else {
        let fs: [Field] = pk.fields;
        let n = 0;
        let ok = true;
        for i in 0..len(fs) {
            let s = pack_field_size(fs[i].typ);
            if (s < 0) { ok = false; } else { n = n + s; };
        };
        if (ok) { n } else { -1 }
    }
};

// Where field `key` starts: a byte offset, or for a bitmap a bit offset. -1 when
// there is no such field (`_` is padding, never a field).
def pack_offset(t: Type, key: str) -> long {
    let pk: TPack = t;
    let fs: [Field] = pk.fields;
    let at = 0;
    let found = -1;
    for i in 0..len(fs) {
        let f = fs[i];
        let fname: str = f.name;
        if (found < 0 && fname == key && key != "_") { found = at; };
        if (pk.bk > 0) { let bi: TInt = f.typ; at = at + bi.w; }
        else { at = at + pack_field_size(f.typ); };
    };
    found
};

// The declared type of field `key` (tnone when missing).
def pack_ftype(t: Type, key: str) -> Type {
    let pk: TPack = t;
    let fs: [Field] = pk.fields;
    let out: Type = type_node({ k: K.tnone });
    for i in 0..len(fs) {
        let f = fs[i];
        let fname: str = f.name;
        if (fname == key && key != "_") { out = f.typ; };
    };
    out
};

// What reading field `ft` of pack `t` gives: a number or bool for a scalar or a bit
// field, the address (a view) for a nested pack, a pointer for a fixed array.
def pack_value_type(t: Type, ft: Type) -> Type {
    let pk: TPack = t;
    if (pk.bk > 0) {
        let bi: TInt = ft;
        if (bi.w == 1) { type_node({ k: K.tbool }) } else { type_node({ k: K.tlong }) }
    } else {
        let u = unfold(ft);
        if (u.k == K.tint) { type_node({ k: K.tlong }) }
        else if (u.k == K.tarrfix) { let a: TFix = u; type_node({ k: K.tptr, to: a.of }) }
        else { u }
    }
};

// "" when every field fits in a packed record, else why not.
def pack_bad(t: Type) -> str {
    let pk: TPack = t;
    let out = "";
    if (pk.bk == 0) {
        let fs: [Field] = pk.fields;
        for i in 0..len(fs) {
            let f = fs[i];
            let fname: str = f.name;
            if (out == "" && pack_field_size(f.typ) < 0) {
                out = "field '" + fname + "' of type " + tstr(f.typ) + " cannot live in a packed record (integers, bool, float, pointers, fixed arrays of those, and other packed records can)";
            };
        };
    };
    out
};

def typeof_pack_field(st: TcSt, pk: Type, key: str, line: long, col: long) -> TcRes {
    let bad = pack_bad(pk);
    let ft = pack_ftype(pk, key);
    if (bad != "") {
        st = fail(st, "packed record: " + bad, line, col);
        tc_res(t_unk(), st)
    } else if (ft.k == K.tnone) {
        st = fail(st, "packed record has no field '" + key + "'", line, col);
        tc_res(t_unk(), st)
    } else {
        tc_res(pack_value_type(pk, ft), st)
    }
};

// obj.key = v on a packed record: a scalar or a bit field only -- a nested pack
// or an array is written through its own fields.
def dotassign_pack(st: TcSt, pk: Type, assign: DotAssign) -> TcRes {
    let bad = pack_bad(pk);
    let ft = pack_ftype(pk, assign.key);
    if (bad != "") {
        st = fail(st, "packed record: " + bad, assign.line, assign.col);
        tc_res(t_unk(), st)
    } else if (ft.k == K.tnone) {
        st = fail(st, "packed record has no field '" + assign.key + "'", assign.line, assign.col);
        tc_res(t_unk(), st)
    } else {
        let vt = pack_value_type(pk, ft);
        if (vt.k == K.tpack || unfold(ft).k == K.tarrfix) {
            st = fail(st, "cannot assign the whole of field '" + assign.key + "' (" + tstr(ft) + "): write its parts", assign.line, assign.col);
            tc_res(t_unk(), st)
        } else {
            let v = typeof_want(st, assign.v, vt);
            st = v.st;
            st = expect_type(st, v.typ, vt, "packed field '" + assign.key + "'", assign.line, assign.col);
            tc_res(vt, st)
        }
    }
};

// A record literal where a packed record is expected: fields by name, in any
// order, the rest zero; a nested pack or bitmap is a literal in turn.
def typeof_packlit(st: TcSt, node: Node, target: Type) -> TcRes {
    let lit: RecLit = node;
    let bad = pack_bad(target);
    if (bad != "") {
        st = fail(st, "packed record: " + bad, lit.line, lit.col);
    };
    let seen: [str] = [];
    let keys: [str] = lit.keys;
    let vals: [Node] = lit.vals;
    for i in 0..len(keys) {
        let key: str = keys[i];
        let val: Node = vals[i];
        let ft = pack_ftype(target, key);
        if (key == "...") {
            st = fail(st, "a packed record literal cannot spread", lit.line, lit.col);
        } else if (key in seen) {
            st = fail(st, "field '" + key + "' is given twice", lit.line, lit.col);
        } else if (ft.k == K.tnone) {
            st = fail(st, "packed record has no field '" + key + "'", lit.line, lit.col);
        } else if (bad == "") {
            seen += key;
            let vt = pack_value_type(target, ft);
            if (vt.k == K.tpack) {
                if (val.k == K.rec) {
                    let r = typeof_packlit(st, val, vt);
                    st = r.st;
                } else {
                    st = fail(st, "field '" + key + "' is a packed record: give it a literal { .. }", lit.line, lit.col);
                };
            } else if (unfold(ft).k == K.tarrfix) {
                st = fail(st, "field '" + key + "' is an array: set its elements through the pointer after creating the record", lit.line, lit.col);
            } else {
                let v = typeof_want(st, val, vt);
                st = v.st;
                st = expect_type(st, v.typ, vt, "packed field '" + key + "'", lit.line, lit.col);
            };
        };
    };
    tc_res(target, st)
};

// sizeof(T) and offsetof(T, field): T is a packed record or bitmap type (the
// parser keeps it as a Narrow in argument 0), the answer a constant long -- bytes,
// and for offsetof the field's byte offset.
def typeof_sizeof(st: TcSt, node: Call, name: str, cargs: [Node]) -> TcRes {
    let want = 1;
    if (name == "offsetof") { want = 2; };
    let lt = type_node({ k: K.tlong });
    if (len(cargs) != want || cargs[0].k != K.narrow) {
        st = fail(st, "sizeof takes a type, and offsetof a type and a field name: sizeof(Header), offsetof(Header, len)", node.line, node.col);
    } else {
        let nar: Narrow = cargs[0];
        let pk = unfold(nar.typ);
        if (pk.k != K.tpack) {
            st = fail(st, name + " needs a packed record or bitmap type, got " + tstr(nar.typ), node.line, node.col);
        } else if (pack_bad(pk) != "") {
            st = fail(st, "packed record: " + pack_bad(pk), node.line, node.col);
        } else if (want == 2) {
            let kn: Leaf = cargs[1];
            let pkt: TPack = pk;
            if (pkt.bk > 0) {
                st = fail(st, "offsetof of a bitmap field is a bit offset: not supported", node.line, node.col);
            } else if (pack_offset(pk, kn.v) < 0) {
                st = fail(st, "packed record has no field '" + kn.v + "'", node.line, node.col);
            };
        };
    };
    tc_res(lt, st)
};

def typeof_field(st: TcSt, t: Type, dkey: str, line: long, col: long) -> TcRes {
    let pkt = pack_of(t);
    if (pkt.k == K.tpack) {
        typeof_pack_field(st, pkt, dkey, line, col)
    } else if (t.k == K.trec) {
        let found = false;
        let ftyp: Type = t_unk();
        let rec: TRec = t;
        let fs: [Field] = rec.fields;
        for j in 0..len(fs) {
            let f = fs[j];
            let fn: str = f.name;
            if (fn == dkey) {
                found = true;
                ftyp = f.typ;
            };
        };
        if (found) {
            tc_res(ftyp, st)
        } else {
            st = fail(st, "record has no field '" + dkey + "'", line, col);
            tc_res(t_unk(), st)
        }
    } else if (t.k == K.tunion) {
        union_field(st, t, dkey, line, col)
    } else if (t.k == K.tmap) {
        if (dkey == "length" || dkey == "ptr") {
            typeof_prop(st, t, dkey, line, col)
        } else if (map_key_is_str(t)) {
            let map: TMap = t;
            tc_res(map.of, st)
        } else {
            st = fail(st, "cannot read field '" + dkey + "' of " + tstr(t) + ": a dot name is a string, so the map's keys must be too (use m[\"" + dkey + "\"])", line, col);
            tc_res(t_unk(), st)
        }
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

def map_key_is_str(t: Type) -> bool {
    if (t.k == K.tmap) {
        let map: TMap = t;
        map.key.k == K.tstr
    } else { false }
};

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
        if (t.k == K.tmap) { have = "'.length'"; };
        st = fail(st, tstr(t) + " has no property '" + key + "' (it has " + have + ")", line, col);
        tc_res(t_unk(), st)
    }
};

// ── string methods ───────────────────────────────────────────────────────
type StrMethod = { fn: str, params: [Type], nreq: long, ret: Type, dflt: str, last: bool };

def str_method(m: str) -> StrMethod { str_method_shape(m) };

def sm_mk(fn: str, params: [Type], nreq: long, ret: Type, dflt: str, last: bool) -> StrMethod {
    { fn: fn, params: params, nreq: nreq, ret: ret, dflt: dflt, last: last }
};

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
        for i in 0..na {
            st = (typeof_expr(st, margs[i])).st;
        };
        tc_res(t_unk(), st)
    } else if (na < sm.nreq || na > np) {
        let want = tostring(np);
        if (sm.nreq < np) { want = tostring(sm.nreq) + " or " + tostring(np); };
        st = fail(st, what + " takes " + want + " args, got " + tostring(na), node.line, node.col);
        for i in 0..na {
            st = (typeof_expr(st, margs[i])).st;
        };
        tc_res(sm.ret, st)
    } else {
        for i in 0..na {
            let r = typeof_expr(st, margs[i]);
            st = r.st;
            let ak: long = r.typ.k;
            if (ak == K.tvoid) {
                st = fail(st, what + " arg " + tostring(i) + ": cannot pass a void value", node.line, node.col);
            } else if (!sm_accepts(r.typ, ps[i])) {
                st = fail(st, what + " arg " + tostring(i) + ": expected " + tstr(ps[i]) + ", got " + tstr(r.typ), node.line, node.col);
            }
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

def const_root(st: TcSt, tgt: Node) -> str {
    let k: long = tgt.k;
    if (k == K.id) {
        let id: Leaf = tgt;
        if ((lookup(st.bindings, id.v)).kind == "const") { id.v } else { "" }
    } else if (k == K.index) {
        let index: Index = tgt;
        const_root(st, index.arr)
    } else if (k == K.dot) {
        let dot: Dot = tgt;
        const_root(st, dot.obj)
    } else { "" }
};

// A store through a const name, refused where the store happens.
def const_store(st: TcSt, tgt: Node, line: long, col: long) -> TcSt {
    let root = const_root(st, tgt);
    if (len(root) > 0) {
        fail(st, "cannot modify '" + disp(root) + "': it is a constant", line, col)
    } else { st }
};

// `++`/`--` and `op=` store back into their target. A plain const name keeps
// the message it always had (a package's globals are consts, and
// src/tools/ytest/su_pkg.y pins all three forms); a name reached through a place says
// which name it was.
def const_check(st: TcSt, tgt: Node, tt: Type, op: str, line: long, col: long) -> TcSt {
    let root = const_root(st, tgt);
    if (len(root) == 0) {
        st
    } else if (tgt.k == K.id) {
        fail(st, "cannot assign to constant '" + disp(root) + "' ('" + op + "')", line, col)
    } else {
        fail(st, "cannot modify '" + disp(root) + "': it is a constant ('" + op + "')", line, col)
    }
};

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
            if (bt.k == K.tmap) {
                // a map's `.length` is its entry count and `.ptr` has no data
                // block to give, so neither is an entry -- the same words the
                // plain store gets (map_dot_prop_msg)
                st = map_dot_prop_msg(st, bt, key, line, col);
                ok = false;
            } else if (bt.k == K.tarr || bt.k == K.tarrfix || bt.k == K.tstr) {
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
    if (tt.k == K.tlong || tt.k == K.tbyte || tt.k == K.tfloat || tt.k == K.tbigint || tt.k == K.tptr) {
        tc_res(tt, st)
    } else if (tt.k == K.tunk || tt.k == K.tnone) {
        tc_res(t_unk(), st)
    } else {
        st = fail(st, "'" + op + "' needs a number target, got " + tstr(tt), node.line, node.col);
        tc_res(t_unk(), st)
    }
};

def opassign_check(st: TcSt, node: OpAssign, tt: Type, vt: Type) -> TcRes {
    let op = node.op;
    if (tt.k == K.tptr) {
        if (op == "+" || op == "-") {
            st = expect_type(st, vt, type_node({ k: K.tlong }), "'" + op + "=' offset", node.line, node.col);
            tc_res(tt, st)
        } else {
            st = fail(st, "pointers support only '+=' and '-=' offsets, not '" + op + "='", node.line, node.col);
            tc_res(t_unk(), st)
        }
    } else if (is_bits_op(op) && tt.k != K.tbigint) {
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
                    let value = arr_elem_of(vt);
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
            // a byte appends as a character, like `s + b`
            if (vt.k != K.tbyte) {
                st = expect_type(st, vt, type_node({ k: K.tstr }), "'+=' string", node.line, node.col);
            };
            tc_res(tt, st)
        } else {
            st = fail(st, "strings support only '+=' (concatenate), not '" + op + "='", node.line, node.col);
            tc_res(tt, st)
        }
    } else if (tt.k == K.tbigint) {
        if (index_of("+-*/%", op) >= 0) {
            st = expect_type(st, vt, tt, "'" + op + "=' value", node.line, node.col);
            tc_res(tt, st)
        } else {
            st = fail(st, "bigints support only '+', '-', '*', '/' and '%' with '='", node.line, node.col);
            tc_res(t_unk(), st)
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

type FmtSpec = { err: str, fill: long, align: long, sign: long, alt: bool, zero: bool, width: long, grp: long, prec: long, ty: long };
def fmt_spec(spec: str) -> FmtSpec {
    let n = len(spec);
    let i = 0;
    let fill = 0;
    let align = 0;
    if (n >= 2 && fmt_align(spec[1])) {
        fill = spec[0];
        align = spec[1];
        i = 2;
    } else if (n >= 1 && fmt_align(spec[0])) {
        align = spec[0];
        i = 1;
    }
    let sign = 0;
    if (i < n && (spec[i] == 43 || spec[i] == 45 || spec[i] == 32)) {
        sign = spec[i];
        i++;
    }
    let alt = false;
    if (i < n && spec[i] == 35) { alt = true; i++; }
    let zero = false;
    if (i < n && spec[i] == 48) { zero = true; i++; }
    let ws = i;
    while (i < n && fmt_digit(spec[i])) { i++; };
    let width = 0 - 1;
    if (i > ws) { width = fmt_number(spec, ws, i); }
    let grp = 0;
    if (i < n && (spec[i] == 44 || spec[i] == 95)) {
        grp = spec[i];
        i++;
    }
    let err = "";
    let prec = 0 - 1;
    if (i < n && spec[i] == 46) {
        i++;
        let ps = i;
        while (i < n && fmt_digit(spec[i])) { i++; };
        if (i > ps) { prec = fmt_number(spec, ps, i); } else { err = "'.' without a precision"; };
    }
    let ty = 0;
    if (i < n && fmt_type(spec[i])) { ty = spec[i]; i++; }
    if (err != "") { }
    else if (i == n - 1) { err = "unknown type '" + spec[i:n] + "'"; }
    else if (i < n) { err = "cannot read '" + spec[i:n] + "'"; }
    else if (width > 99999 || prec > 99999) { err = "width and precision stop at 99999"; }

    { err: err, fill: fill, align: align, sign: sign, alt: alt, zero: zero, width: width, grp: grp, prec: prec, ty: ty }
};

def fmt_align(c: long) -> bool {
    ['<', '>', '^', '='].index(c) >= 0
};

def fmt_digit(c: long) -> bool {
    c >= '0' && c <= '9'
};

// s d x X o b c f F e E %
def fmt_type(c: long) -> bool {
    ['s', 'd', 'x', 'X', 'o', 'b'].index(c) >= 0
    || c == 'c' || c == 'f' || c == 'F' || c == 'e' || c == 'E' || c == '%'
};

// The digits spec[a:b] as a number, stopping short of overflow (a value
// that large is over fmt_spec's limit anyway).
def fmt_number(spec: str, a: long, b: long) -> long {
    let v = 0;
    for i in a..b {
        if (v < 1000000) { v = v * 10 + spec[i] - '0'; }
    };
    v
};

def fmt_kind(t: Type) -> long {
    if (t.k == K.tlong || t.k == K.tbyte) { 1 } else if (t.k == K.tfloat) { 2 } else { 0 }
};

// What is wrong with the spec f for a value of kind `kind` (fmt_kind) and
// type tname: "" when nothing is. Python's rules: a sign, `#`, grouping
// and `=` need a number, a precision is no integer type's, `c` takes no
// sign, `#` or grouping, and `,` groups decimals only.
def fmt_check(f: FmtSpec, kind: long, tname: str) -> str {
    let ty = f.ty;
    let ints = ['d', 'x', 'X', 'o', 'b', 'c'].index(ty) >= 0;
    if (f.err != "") {
        f.err
    } else if (kind == 0) {
        if (ty != 0 && ty != 's') { "type '" + chr(ty) + "' needs a number, not " + tname }
        else if (f.sign != 0) { "a sign needs a number, not " + tname }
        else if (f.alt) { "'#' needs a number, not " + tname }
        else if (f.grp != 0) { "'" + chr(f.grp) + "' needs a number, not " + tname }
        else if (f.align == '=') { "'=' alignment needs a number, not " + tname }
        else { "" }
    } else if (ty == 's') {
        "type 's' needs a string, not " + tname
    } else if (kind == 2 && ints) {
        "type '" + chr(ty) + "' needs an integer, not " + tname
    } else if (kind == 1 && f.prec >= 0 && (ty == 0 || ints)) {
        "a precision needs a float type (f, e or %), not an integer one"
    } else if (ty == 'c' && (f.sign != 0 || f.alt || f.grp != 0)) {
        "type 'c' takes no sign, '#' or grouping"
    } else if (f.grp == ',' && (['x', 'X', 'o', 'b'].index(ty) >= 0)) {
        "',' does not group type '" + chr(ty) + "' (use '_')"
    } else {
        ""
    }
};

def leaf_of(node: Node) -> Leaf? {
    if (node.k == K.err) {
        none
    } else {
        let leaf: Leaf = node;
        some(leaf)
    }
};

def typeof_fmt(st: TcSt, node: Call) -> TcRes {
    let fargs: [Node] = node.args;
    let r = typeof_expr(st, fargs[0]);
    st = r.st;
    let t: Type = r.typ;
    let sp = leaf_of(fargs[1]);
    let spec: str = if (sp == none) { "" } else { sp !.v };
    if (sp == none) {
        let e: Err = fargs[1];
        st = fail(st, e.msg, e.line, e.col);
    } else if (!(t.k == K.tlong || t.k == K.tbyte || t.k == K.tbool || t.k == K.tstr || t.k == K.tfloat || t.k == K.tbigint || t.k == K.tunk || t.k == K.tarr || t.k == K.tarrfix || t.k == K.trec || t.k == K.tmap || t.k == K.topt || t.k == K.tunion)) {
        st = fail(st, "an f-string field takes long/bool/float/bigint/str/array/record/map/option, got " + tstr(t), node.line, node.col);
    } else if (spec != "") {
        let e = fmt_check(fmt_spec(spec), fmt_kind(t), tstr(t));
        if (e != "") { st = fail(st, "format spec '" + spec + "': " + e, node.line, node.col); }
    }
    tc_res(type_node({ k: K.tstr }), st)
};

// ── the named syscall layer ─────────────────────────────────────────────
def os_call_name(nm: str) -> bool {
    let names = os_call_names();
    let i = 0;
    let found = false;
    while (i < len(names)) {
        if (names[i] == nm) { found = true; };
        i++;
    };
    found
};

def os_call_names() -> [str] {
    ["y_os_write", "y_os_print_int", "y_os_read", "y_os_lseek", "y_os_clock_gettime",
        "y_os_nanosleep", "y_os_wait4", "y_os_fork", "y_os_execve",
        "y_os_openat", "y_os_stat", "y_os_mkdir", "y_os_unlink",
        "y_os_rename", "y_os_getcwd", "y_os_chdir", "y_os_list",
        "y_os_set_mode", "y_os_close", "y_os_pipe", "y_os_dup2",
        "y_os_random", "y_os_cmdline_ptr", "y_os_cmdline_len", "y_os_spawn",
        "y_os_socket", "y_os_connect", "y_os_bind", "y_os_listen", "y_os_accept", "y_os_getsockname", "y_os_setsockopt", "y_os_send", "y_os_recv", "y_os_closesocket", "y_os_poll", "y_os_getuid", "y_os_dns_servers",
        "y_os_ioctl", "y_os_tty_read", "y_os_setsid",
        "y_os_audio_devs", "y_os_audio_open", "y_os_audio_write", "y_os_audio_close", "y_os_environ",
        "y_os_gui_sym", "y_os_gui_call", "y_os_gui_wndproc", "y_os_host_sym", "y_os_host_call"]
};

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

// ── array methods ────────────────────────────────────────────────────────
// `arr.m(args)` with arr an array is a builtin method. The checker owns the
// signatures; native.y emits each one inline (the receiver's element type is
// static there too), so no runtime helper needs to be polymorphic.
def arr_elem_of(t: Type) -> Type {
    if (t.k == K.tarr) { let arr: TOf = t; arr.of }
    else if (t.k == K.tarrfix) { let fix: TFix = t; fix.of }
    else { t_unk() }
};

def arr_is_heap(t: Type) -> bool { t.k == K.tarr };

// A method that changes the length of its receiver needs a heap `[T]`.
// A fixed `[T; N]` has its length in its type, which the same rule that
// rejects `+=`/`*=` on one (opassign_check) rejects here.
def arr_fixed_guard(st: TcSt, at: Type, key: str, line: long, col: long) -> TcSt {
    if (arr_is_heap(at)) { st }
    else { fail(st, "cannot resize fixed array " + tstr(at) + " with '." + key + "' (its length is part of its type; use [T] instead)", line, col) }
};

// Type a closure argument under the parameter types the method will call it
// with. A literal's missing annotations are filled in place (the emitter
// reads the same ptypes); an annotated parameter must accept the expected
// type. A non-literal closure is checked as an ordinary function value.
def typeof_closure_want(st: TcSt, node: Node, ptypes: [Type]) -> TcRes {
    if (node.k == K.func) {
        let f: Func = node;
        let i = 0;
        while (i < len(f.params) && i < len(ptypes)) {
            if (f.ptypes[i].k == K.tnone) {
                f.ptypes[i] = ptypes[i];
            } else if (!tcompat(ptypes[i], f.ptypes[i])) {
                st = fail(st, "closure parameter " + tostring(i + 1) + ": expected " + tstr(ptypes[i]) + ", got " + tstr(f.ptypes[i]), node.line, node.col);
            };
            i++;
        };
        typeof_expr(st, node)
    } else {
        let r = typeof_expr(st, node);
        let ft = unfold(r.typ);
        if (ft.k == K.tfunc) {
            let tf: TFunc = ft;
            let i = 0;
            while (i < len(tf.args) && i < len(ptypes)) {
                if (!tcompat(ptypes[i], tf.args[i])) {
                    st = fail(st, "closure argument " + tostring(i + 1) + ": expected " + tstr(ptypes[i]) + ", got " + tstr(tf.args[i]), node.line, node.col);
                };
                i++;
            };
        } else if (ft.k != K.tunk) {
            st = fail(st, "expected a closure, got " + tstr(r.typ), node.line, node.col);
        };
        tc_res(r.typ, st)
    }
};

def closure_ret(t: Type) -> Type {
    if (t.k == K.tfunc) { let f: TFunc = t; f.ret } else { t_unk() }
};

// `arr.m(...)`; `at` is the already-checked receiver type.
def typeof_arr_method(st: TcSt, node: Call, key: str, at: Type) -> TcRes {
    let dot: Dot = node.callee;
    let elem = arr_elem_of(at);
    let args: [Node] = node.args;
    let na = len(args);
    let what = "'array." + key + "'";
    if (key == "pop" || key == "shift") {
        st = const_store(st, dot.obj, node.line, node.col);
        st = arr_fixed_guard(st, at, key, node.line, node.col);
        if (na != 0) {
            st = fail(st, what + " takes no args, got " + tostring(na), node.line, node.col);
        };
        tc_res(elem, st)
    } else if (key == "push" || key == "unshift") {
        st = const_store(st, dot.obj, node.line, node.col);
        st = arr_fixed_guard(st, at, key, node.line, node.col);
        if (na != 1) {
            st = fail(st, what + " takes 1 arg, got " + tostring(na), node.line, node.col);
        } else {
            let r = typeof_expr(st, args[0]);
            st = r.st;
            heap_context(args[0], r.typ, elem);
            st = expect_type(st, r.typ, elem, what + " arg", node.line, node.col);
        };
        tc_res(type_node({ k: K.tlong }), st)
    } else if (key == "insert") {
        st = const_store(st, dot.obj, node.line, node.col);
        st = arr_fixed_guard(st, at, key, node.line, node.col);
        if (na != 2) {
            st = fail(st, what + " takes 2 args, got " + tostring(na), node.line, node.col);
        } else {
            let ri = typeof_expr(st, args[0]);
            st = ri.st;
            st = expect_type(st, ri.typ, type_node({ k: K.tlong }), what + " index", node.line, node.col);
            let rv = typeof_expr(st, args[1]);
            st = rv.st;
            heap_context(args[1], rv.typ, elem);
            st = expect_type(st, rv.typ, elem, what + " value", node.line, node.col);
        };
        tc_res(type_node({ k: K.tvoid }), st)
    } else if (key == "remove") {
        st = const_store(st, dot.obj, node.line, node.col);
        st = arr_fixed_guard(st, at, key, node.line, node.col);
        if (na < 1 || na > 2) {
            st = fail(st, what + " takes 1 or 2 args, got " + tostring(na), node.line, node.col);
        } else {
            let ri = typeof_expr(st, args[0]);
            st = ri.st;
            st = expect_type(st, ri.typ, type_node({ k: K.tlong }), what + " index", node.line, node.col);
            if (na == 2) {
                let rl = typeof_expr(st, args[1]);
                st = rl.st;
                st = expect_type(st, rl.typ, type_node({ k: K.tlong }), what + " count", node.line, node.col);
            };
        };
        if (na == 2) { tc_res(type_node({ k: K.tarr, of: elem }), st) } else { tc_res(elem, st) }
    } else if (key == "flat") {
        if (na != 0) {
            st = fail(st, what + " takes no args, got " + tostring(na), node.line, node.col);
        };
        let inner = arr_elem_of(elem);
        if (elem.k != K.tarr && elem.k != K.tarrfix) {
            st = fail(st, what + " needs an array of arrays, got " + tstr(at), node.line, node.col);
        };
        tc_res(type_node({ k: K.tarr, of: inner }), st)
    } else if (key == "index") {
        if (na != 1) {
            st = fail(st, what + " takes 1 arg, got " + tostring(na), node.line, node.col);
        } else {
            let r = typeof_expr(st, args[0]);
            st = r.st;
            heap_context(args[0], r.typ, elem);
            st = expect_type(st, r.typ, elem, what + " value", node.line, node.col);
        };
        tc_res(type_node({ k: K.tlong }), st)
    } else if (key in ["foreach", "map", "filter", "all", "some", "find"]) {
        if (na != 1) {
            st = fail(st, what + " takes 1 arg, got " + tostring(na), node.line, node.col);
            tc_res(t_unk(), st)
        } else {
            let ptypes: [Type] = [];
            ptypes += elem;
            ptypes += type_node({ k: K.tlong });
            let rf = typeof_closure_want(st, args[0], ptypes);
            st = rf.st;
            let rt = closure_ret(rf.typ);
            if (key == "map") {
                tc_res(type_node({ k: K.tarr, of: rt }), st)
            } else if (key == "filter") {
                st = expect_type(st, rt, type_node({ k: K.tbool }), what + " predicate", node.line, node.col);
                tc_res(at, st)
            } else if (key == "all" || key == "some") {
                st = expect_type(st, rt, type_node({ k: K.tbool }), what + " predicate", node.line, node.col);
                tc_res(type_node({ k: K.tbool }), st)
            } else if (key == "find") {
                st = expect_type(st, rt, type_node({ k: K.tbool }), what + " predicate", node.line, node.col);
                tc_res(type_node({ k: K.topt, of: elem }), st)
            } else {
                tc_res(type_node({ k: K.tvoid }), st)
            }
        }
    } else if (key == "reduce") {
        if (na != 2) {
            st = fail(st, what + " takes 2 args, got " + tostring(na), node.line, node.col);
            tc_res(t_unk(), st)
        } else {
            let ri = typeof_expr(st, args[1]);
            st = ri.st;
            let acc = ri.typ;
            let ptypes: [Type] = [];
            ptypes += acc;
            ptypes += elem;
            let rf = typeof_closure_want(st, args[0], ptypes);
            st = rf.st;
            st = expect_type(st, closure_ret(rf.typ), acc, what + " reducer", node.line, node.col);
            tc_res(acc, st)
        }
    } else if (key == "sort" || key == "sorted") {
        if (key == "sort") { st = const_store(st, dot.obj, node.line, node.col); };
        if (na != 1) {
            st = fail(st, what + " takes 1 arg, got " + tostring(na), node.line, node.col);
            tc_res(t_unk(), st)
        } else {
            let ptypes: [Type] = [];
            ptypes += elem;
            ptypes += elem;
            let rf = typeof_closure_want(st, args[0], ptypes);
            st = rf.st;
            st = expect_type(st, closure_ret(rf.typ), type_node({ k: K.tlong }), what + " comparator", node.line, node.col);
        };
        tc_res(at, st)
    } else {
        st = fail(st, "array has no method '" + key + "'", node.line, node.col);
        for i in 0..na {
            st = (typeof_expr(st, args[i])).st;
        };
        tc_res(t_unk(), st)
    }
};

// Fixed signatures share arity checks, ordered evaluation and type checking.
// Most validate each argument immediately; split historically evaluates both first.
def typeof_fixed(st: TcSt, node: Call, spec: BuiltinSpec) -> TcRes {
    if (len(node.args) != len(spec.args)) {
        return tc_res(spec.bad, fail(st, spec.arity, node.line, node.col));
    };
    let actual: [Type] = [];
    for i in 0..len(node.args) {
        let result = typeof_expr(st, node.args[i]);
        st = result.st;
        if (spec.deferred) { actual += result.typ; }
        else if (spec.args[i].k != K.tnone) {
            st = expect_type(st, result.typ, spec.args[i], spec.contexts[i], node.line, node.col);
        };
    };
    if (spec.deferred) {
        for i in 0..len(actual) {
            st = expect_type(st, actual[i], spec.args[i], spec.contexts[i], node.line, node.col);
        };
    };
    tc_res(spec.ret, st)
};

def typeof_call_go(st: TcSt, node: Call) -> TcRes {
    // Two callee shapes: a plain id (the `else` arm below — a hoisted def,
    // an intrinsic, `self`, or a local holding a closure) and an arbitrary
    // expression (the `if` arm — an immediately-invoked literal, an element
    // of an array of functions, ...).
    let cargs: [Node] = node.args;
    let callee: Node = node.callee;
    if (callee.k != K.id) {
        let ccal: Node = callee;
        let cf: TcRes = { typ: t_unk(), st: st };
        let smeth = false;
        let ameth = false;
        let arecv: Type = t_unk();
        if (ccal.k == K.dot) {
            let dot: Dot = ccal;
            let crt = typeof_expr(st, dot.obj);
            if (crt.typ.k == K.tstr) {
                smeth = true;
                cf = { typ: t_unk(), st: crt.st };
            } else if (crt.typ.k == K.tarr || crt.typ.k == K.tarrfix) {
                ameth = true;
                arecv = crt.typ;
                cf = { typ: t_unk(), st: crt.st };
            } else {
                cf = typeof_field(crt.st, crt.typ, dot.key, dot.line, dot.col);
            };
        } else {
            cf = typeof_expr(st, ccal);
        };
        st = cf.st;
        if (tc_index && ccal.k == K.dot && !smeth) {
            let cdot: Dot = ccal;
            if (cdot.nline > 0 && cdot.ncol > 0) { tci_note_key(cdot.nline * 65536 + cdot.ncol, cf.typ); };
        };
        if (smeth) {
            let dot: Dot = ccal;
            typeof_method(st, node, dot.key)
        } else if (ameth) {
            let dot: Dot = ccal;
            typeof_arr_method(st, node, dot.key, arecv)
        } else if (cf.typ.k == K.tfunc) {
            let cft: TFunc = cf.typ;
            let cfargs: [Type] = cft.args;
            if (len(cargs) != len(cfargs)) {
                st = fail(st, "call takes " + tostring(len(cfargs)) + " args, got " + tostring(len(cargs)), node.line, node.col);
                tc_res(cft.ret, st)
            } else {
                cargs.foreach((e, ci) => {
                    let ra = typeof_want(st, e, cfargs[ci]);
                    st = ra.st;
                    st = expect_cast(st, ra.typ, cfargs[ci], "call arg " + tostring(ci), node.line, node.col);
                });
                tc_res(cft.ret, st)
            }
        } else {
            st = fail(st, "cannot call " + tstr(cf.typ) + " (not a function)", node.line, node.col);
            for i in 0..len(node.args) {
                st = (typeof_expr(st, cargs[i])).st;
            };
            tc_res(t_unk(), st)
        }
    } else {
        let id: Leaf = callee;
        let name = id.v;
        let spec = builtin_spec(name);
        if (spec.valid) { return typeof_fixed(st, node, spec); };
        if (name == "#fmt") {
            typeof_fmt(st, node)
        } else if (name == "print") {
            if (len(node.args) != 1) {
                st = fail(st, "print takes exactly 1 argument", node.line, node.col);
                tc_res(type_node({ k: K.tvoid }), st)
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                if (r.typ.k == K.tlong || r.typ.k == K.tbyte || r.typ.k == K.tbool || r.typ.k == K.tstr || r.typ.k == K.tfloat || r.typ.k == K.tbigint || r.typ.k == K.tunk || r.typ.k == K.trec || r.typ.k == K.tmap || r.typ.k == K.tfunc || r.typ.k == K.tarr || r.typ.k == K.tarrfix || r.typ.k == K.topt || r.typ.k == K.tunion) {
                    tc_res(type_node({ k: K.tvoid }), st)
                } else {
                    st = fail(st, "print supports long/bool/float/bigint/str/array/record/map/option, got " + tstr(r.typ), node.line, node.col);
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
        } else if (name == "values") {
            // values(m) -> [V]: the entries of map m, in the same insertion
            // order as keys(m) -- so keys(m)[i] and values(m)[i] are the same
            // entry (the answer to the reserved-names question:
            // no reserved names, the pair is the API)
            if (len(cargs) != 1) {
                st = fail(st, "values takes exactly 1 argument", node.line, node.col);
                tc_res(t_unk(), st)
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                let mt = unfold(r.typ);
                if (mt.k == K.tmap) {
                    let map: TMap = mt;
                    tc_res(type_node({ k: K.tarr, of: map.of }), st)
                } else if (mt.k == K.tunk) {
                    tc_res(t_unk(), st)
                } else {
                    st = fail(st, "values needs a map, got " + tstr(r.typ), node.line, node.col);
                    tc_res(t_unk(), st)
                }
            }
        } else if (name == "sizeof" || name == "offsetof") {
            typeof_sizeof(st, node, name, cargs)
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
        } else if (name == "region$" || name == "heap$") {
            if (name == "region$") { tc_saw_region = true; };
            let br = typeof_expr(st, cargs[0]);
            st = br.st;
            tc_res(type_node({ k: K.tvoid }), st)
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
        } else if (name == "tolong") {
            if (len(cargs) != 1) {
                st = fail(st, "tolong takes exactly 1 argument", node.line, node.col);
                tc_res(t_unk(), st)
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                // A str is parsed; a float is truncated. Two types rather than
                // one is what makes the name worth changing.
                if (r.typ.k != K.tstr && r.typ.k != K.tfloat && r.typ.k != K.tbigint) {
                    st = fail(st, "tolong needs a str to parse, a float to truncate or a bigint to narrow, got "
                        + tstr(r.typ), node.line, node.col);
                    tc_res(t_unk(), st)
                } else {
                    tc_res(type_node({ k: K.topt, of: type_node({ k: K.tlong }) }), st)
                }
            }
        } else if (name == "tofloat") {
            if (len(cargs) != 1) {
                st = fail(st, "tofloat takes exactly 1 argument", node.line, node.col);
                tc_res(t_unk(), st)
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                // A str is parsed; a long is widened, which the language already
                // does implicitly -- so this arm exists for SYMMETRY with
                // tolong, not because it needs to.
                if (r.typ.k != K.tstr && r.typ.k != K.tlong && r.typ.k != K.tbigint) {
                    st = fail(st, "tofloat needs a str to parse, a long to widen or a bigint to convert, got "
                        + tstr(r.typ), node.line, node.col);
                    tc_res(t_unk(), st)
                } else {
                    tc_res(type_node({ k: K.topt, of: type_node({ k: K.tfloat }) }), st)
                }
            }
        } else if (name == "tostring") {
            if (len(cargs) != 1) {
                st = fail(st, "tostring takes exactly 1 argument", node.line, node.col);
                tc_res(t_unk(), st)
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                if (r.typ.k == K.tlong || r.typ.k == K.tbyte || r.typ.k == K.tbool || r.typ.k == K.tstr || r.typ.k == K.tfloat || r.typ.k == K.tbigint || r.typ.k == K.tunk || r.typ.k == K.tarr || r.typ.k == K.tarrfix || r.typ.k == K.trec || r.typ.k == K.tmap || r.typ.k == K.topt || r.typ.k == K.tunion) {
                    tc_res(type_node({ k: K.tstr }), st)
                } else {
                    st = fail(st, "tostring supports long/bool/float/bigint/str/array/record/map/option, got " + tstr(r.typ), node.line, node.col);
                    tc_res(t_unk(), st)
                }
            }
        } else if (name == "index_of" || name == "last_index_of") {
            if (len(cargs) < 2 || len(cargs) > 3) {
                st = fail(st, name + " takes 2 or 3 arguments (string, sub, start)", node.line, node.col);
                tc_res(t_unk(), st)
            } else {
                let r0 = typeof_expr(st, cargs[0]);
                st = r0.st;
                let r1 = typeof_expr(st, cargs[1]);
                st = r1.st;
                st = expect_type(st, r0.typ, { k: K.tstr }, name + " string", node.line, node.col);
                st = expect_type(st, r1.typ, { k: K.tstr }, name + " sub", node.line, node.col);
                if (len(cargs) == 3) {
                    let r2 = typeof_expr(st, cargs[2]);
                    st = r2.st;
                    st = expect_type(st, r2.typ, { k: K.tlong }, name + " start", node.line, node.col);
                };
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
                if (r.typ.k == K.tptr || r.typ.k == K.tstr || r.typ.k == K.tunk || unfold(r.typ).k == K.tpack) {
                    tc_res(type_node({ k: K.tlong }), st)
                } else {
                    st = fail(st, "ptr_addr needs a pointer, got " + tstr(r.typ), node.line, node.col);
                    tc_res(type_node({ k: K.tlong }), st)
                }
            }
        } else if (name == "ptr_from") {
            if (len(cargs) != 1) {
                st = fail(st, "ptr_from takes exactly 1 argument (an integer)", node.line, node.col);
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                if (r.typ.k == K.tlong || r.typ.k == K.tbyte || r.typ.k == K.tunk) { } else {
                    st = fail(st, "ptr_from needs an integer, got " + tstr(r.typ), node.line, node.col);
                };
            };
            tc_res(type_node({ k: K.tptr, to: t_unk() }), st)
        } else if (name == "os_call") {
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
                st = (typeof_expr(st, cargs[0])).st;
                if (!os_call_name(nm.v)) {
                    st = fail(st, "os_call: '" + nm.v + "' is not a call name (see os_call_names)",
                        node.line, node.col);
                };
                for i in 1..len(cargs) {
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
                };
                tc_res(type_node({ k: K.tlong }), st)
            }
        } else if (name == "syscall") {
            let maxargs = 7;
            if (target_is_windows()) { maxargs = 10; };
            if (len(cargs) < 1 || len(cargs) > maxargs) {
                st = fail(st, "syscall needs 1-" + tostring(maxargs) + " arguments (number + up to " + (tostring(maxargs - 1)) + " args)", node.line, node.col);
                tc_res(type_node({ k: K.tlong }), st)
            } else {
                cargs.foreach((e, i) => {
                    let r = typeof_expr(st, e);
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
                });
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
                        fterr += " (slice instead: s[start:end])";
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
                cargs.foreach((e) => {
                    st = (typeof_expr(st, e)).st;
                });
                tc_res(t_unk(), st)
            } else if (ft.k != K.tfunc) {
                // poisoned binding (tunk) from an earlier error — don't
                // cascade new errors, but still check the arguments for
                // their own errors.
                cargs.foreach((e) => {
                    st = (typeof_expr(st, e)).st;
                });
                tc_res(t_unk(), st)
            } else {
                let func: TFunc = ft;
                let cargs_ft: [Type] = func.args;
                if (len(cargs) != len(cargs_ft)) {
                    st = fail(st, "'" + disp(name) + "' takes " + tostring(len(cargs_ft)) + " args, got " + tostring(len(cargs)), node.line, node.col);
                    tc_res(call_result(func), st)
                } else {
                    cargs.foreach((e, i) => {
                        let r = typeof_want(st, e, cargs_ft[i]);
                        st = r.st;
                        let ak: long = r.typ.k;
                        st = ak == K.tvoid ? fail(st, "'" + disp(name) + "' arg " + tostring(i) + ": cannot pass a void value", node.line, node.col) : expect_arg(st, r.typ, cargs_ft[i], e, "'" + disp(name) + "' arg " + tostring(i), node.line, node.col);
                    });
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
    bstmts.foreach((e) => {
        let r = typeof_expr(st, e);
        st = r.st;
        last = r.typ;
    });
    tc_res(last, st)
};

// typeof_block with the block's value going where `want` is declared (a
// def's body, typeof_def): its last statement through typeof_want.
def typeof_block_want(st: TcSt, node: Block, want: Type) -> TcRes {
    let last: Type = type_node({ k: K.tvoid });
    let bstmts: [Node] = node.stmts;
    bstmts.foreach((e, i) => {
        let w: Type = type_node({ k: K.tnone });
        if (i == len(bstmts) - 1) { w = want; }
        let rr = typeof_want(st, e, w);
        st = rr.st;
        last = rr.typ;
    });
    tc_res(last, st)
};

// ── record literals where a type is declared ─────────────────────────────

// The type of `node` going where `want` is declared: a record literal
// with a target (lit_target) is checked against it (typeof_lit); anything
// else is typeof_expr.
def typeof_want(st: TcSt, node: Node, want: Type) -> TcRes {
    let r = typeof_want_go(st, node, want);
    heap_context(node, r.typ, want);
    r
};

def typeof_want_go(st: TcSt, node: Node, want: Type) -> TcRes {
    let nk: long = node.k;
    if (nk == K.rec && unfold(want).k == K.tpack) {
        typeof_packlit(st, node, unfold(want))
    } else if (nk == K.rec) {
        let target = lit_target(node, want);
        if (target.k == K.tnone) { typeof_expr(st, node) } else { typeof_lit(st, node, target) }
    } else if (nk == K.array && lit_elems_take(node, want)) {
        // [{...}, ...] where [T] or [T; N] is declared and T holds record
        // literals: each element is created as T (arr_lit_adopts then
        // compares the length against a [T; N])
        let array: ArrLit = node;
        let elems: [Node] = array.elems;
        let et = lit_elem_want(want);
        elems.foreach((e, i) => {
            let r = typeof_want(st, e, et);
            st = r.st;
            let en: Node = e;
            if (en.k == K.array && lit_elem_want(et).k != K.tnone) {
                let inner: ArrLit = en;
                if (!arr_lit_adopts(r.typ, unfold(et), len(inner.elems))) {
                    st = expect_type(st, r.typ, et, "array element", en.line, en.col);
                };
            } else {
                st = expect_type(st, r.typ, et, "array element", en.line, en.col);
            };
        });
        tc_res(type_node({ k: K.tarr, of: et }), st)
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

// Some element of the array literal is a literal that takes its type from the
// element type of want (lit_elem_want): a record literal under a record or
// union, an array literal under an array. Anything else (a variable, a call:
// `a += [x]` may append [x] wholesale) keeps its own type.
def lit_elems_take(node: ArrLit, want: Type) -> bool {
    let et = lit_elem_want(want);
    let hit = false;
    if (et.k != K.tnone) {
        let u = unfold(et);
        let arr = u.k == K.tarr || u.k == K.tarrfix;
        let elems: [Node] = node.elems;
        foreach (e in elems) {
            let en: Node = e;
            if (arr) { if (en.k == K.array) { hit = true; }; }
            else if (en.k == K.rec) { hit = true; };
        };
    };
    hit
};

// The element type T of a declared [T] / [T; N] when a literal element can
// take its type from T: a record or union (lit_target), or an array of
// those. tnone otherwise.
def lit_elem_want(want: Type) -> Type { lit_elem_want_go(want, 0) };

// (depth: a recursive alias such as `type Ids = [Ids]` never bottoms out)
def lit_elem_want_go(want: Type, depth: long) -> Type {
    let w = unfold(want);
    let et: Type = type_node({ k: K.tnone });
    if (w.k == K.tarr) { let a: TOf = w; et = a.of; }
    else if (w.k == K.tarrfix) { let a: TFix = w; et = a.of; };
    if (et.k != K.tnone) {
        let u = unfold(et);
        let uk: long = u.k;
        if (uk == K.trec || uk == K.tunion) { }
        else if ((uk == K.tarr || uk == K.tarrfix) && depth < 8 && lit_elem_want_go(u, depth + 1).k != K.tnone) { }
        else { et = type_node({ k: K.tnone }); };
    };
    et
};

def lit_target(node: RecLit, want: Type) -> Type {
    let keys: [str] = node.keys;
    let w = unfold(want);
    let wk: long = w.k;
    let found: Type = type_node({ k: K.tnone });
    if ("..." in keys) {
    } else if (wk == K.trec) {
        if (lit_fits(w, keys)) { found = want; }
    } else if (wk == K.tmap) {
        if (len(keys) == 0) { found = want; };
    } else if (wk == K.tunion) {
        let ps = union_parts(w);
        let exact: Type = type_node({ k: K.tnone });
        let nexact = 0;
        let fit: Type = type_node({ k: K.tnone });
        let nfit = 0;
        foreach (p in ps) {
            if (lit_fits(unfold(p), keys)) {
                fit = p;
                nfit++;
                if (same_names(unfold(p), keys)) { exact = p; nexact++; };
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
        foreach (f in fs) { if (!f.opt && !(f.name in keys)) { ok = false; }; };
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
        keys.foreach((e) => {
            let key: str = e;
            if (!(key in distinct)) { distinct += key; }
            if (field_pos(fs, key, 0) < 0) { ok = false; }
        });
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
    keys.foreach((e, i) => {
        let key: str = e;
        let ft = trec_field_type(tu, key);
        let what = "record field '" + key + "'";
        if (field_opt(tu, key) && ft.k == K.topt) {
            let fo: TOf = ft;
            let r = typeof_want(st, vals[i], fo.of);
            st = opt_wraps(r.typ, ft) ? expect_type(r.st, r.typ, fo.of, what, node.line, node.col) : expect_type(r.st, r.typ, ft, what, node.line, node.col);
        } else {
            let r = typeof_want(st, vals[i], ft);
            st = expect_type(r.st, r.typ, ft, what, node.line, node.col);
        };
    });
    tc_res(target, st)
};

def check_irq_def(st: TcSt, node: Decl, ret: Type) -> TcSt {
    let line = kernel_irq_line(disp(node.name));
    if (line < 0) {
        st
    } else {
        let f: Func = node.v;
        if (st.fdepth != 0) {
            st = fail(st, "an irq handler must be declared at the top level", node.line, node.col);
        };
        if (len(f.params) > 0) {
            st = fail(st, "an irq handler takes no parameters (it is called from the interrupt entry)", node.line, node.col);
        };
        // The result: the annotation, or what the body inferred (typeof_def
        // records an omitted return type in the side table rather than on
        // the Func).  `ret` here is the FUNCTION type, so it is not read.
        let rt = f.ret;
        if (rt.k == K.tnone) { rt = inferred_ret(f.line, f.col); };
        if (rt.k != K.tvoid) {
            st = fail(st, "an irq handler returns void", node.line, node.col);
        };
        st
    }
};

def typeof_decl(st: TcSt, node: Decl) -> TcRes {
    if (node.kind == "def") {
        // named function: full check (signature + body)
        let r = typeof_def(st, node.name, node.v, node.line, node.col, node.nline, node.ncol, false);
        // An `irq N def` is a def with a meaning the signature has to match
        // (target.y's KernelIrq): no parameters, void.  It is checked here,
        // where the checked return type is in hand, rather than in the
        // parser, so an omitted `-> void` whose body is void passes.
        let st2 = check_irq_def(r.st, node, r.typ);
        { typ: r.typ, st: st2 }
    } else if (node.kind == "native") {
        // ndef: the signature, and three rules of its own
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
            if (node.typ.k == K.tnone && t.k == K.tptr) {
                let pt: TPtr = t;
                if (pt.to.k == K.tunk) {
                    st = fail(st, "ptr_from does not say which pointer type it makes; write it: let " + disp(node.name) + ": *T = ptr_from(n)", node.line, node.col);
                };
            };
            if (node.typ.k != K.tnone) {
                if (!is_value_type(node.typ)) {
                    st = fail(st, "annotation '" + tstr(node.typ) + "' is not a native value type", node.line, node.col);
                } else if (vk == K.array) {
                    let lit: ArrLit = node.v;
                    if (arr_lit_adopts(r.typ, node.typ, len(lit.elems))) { } else {
                        st = expect_type(st, r.typ, node.typ, "let '" + disp(node.name) + "'", node.line, node.col);
                    };
                    t = node.typ;
                } else if (vk == K.rec) {
                    let rec: RecLit = node.v;
                    if (len(rec.keys) == 0 && unfold(node.typ).k == K.tmap) {
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
def ret_note(rl: TInfer, typ: Type, line: long, col: long) -> void {
    let rets: [RetNote] = rl.rets;
    rets += { typ: typ, line: line, col: col };
};

let inf_keys: [long] = [];
let inf_typs: [Type] = [];
let inf_bkts: [[long]] = [];

def inf_reset() -> void {
    let keys: [long] = [];
    let typs: [Type] = [];
    let bkts: [[long]] = [];
    for i in 0..1024 {
        let b: [long] = [];
        bkts += b;
    };
    inf_keys = keys;
    inf_typs = typs;
    inf_bkts = bkts;
};

def set_inferred_ret(func: Func, ret: Type) -> void {
    if (len(inf_bkts) == 0) { inf_reset(); };
    let key = func.line * 65536 + func.col;
    let bkt: [long] = inf_bkts[key % 1024];
    inf_keys += key;
    inf_typs += ret;
    bkt += len(inf_keys) - 1;
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
    // `isnat` is a `ndef`: the signature is checked exactly as a def's
    // is, but there is no body -- the return type must be written, the label
    // must be a `y_` one, and the declaration must be at the top level.
    if (len(func.params) != len(func.ptypes)) {
        st = fail(st, "internal: params/ptypes length mismatch", line, col);
        tc_res(t_unk(), st)
    } else {
        let args: [Type] = [];
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
            i++;
        };
        let ret: Type = func.ret;
        if (isnat) {
            // A native's body holds no code, so the return type has nothing to
            // be inferred from and has to be written. A body that is NOT empty
            // means the parser planted errors in it, which say better than this
            // would -- so wait for them rather than piling on.
            let nbody: Block = func.body;
            if (ret.k == K.tnone && len(nbody.stmts) == 0) {
                st = fail(st, "ndef '" + disp(name) + "' needs a return type (there is no body to infer it from)", line, col);
                ret = t_unk();
            };
            if (!func.label.starts_with("y_")) {
                st = fail(st, "ndef label '" + disp(func.label) + "' must start with 'y_' (generated code calls it by that prefix)", line, col);
            };
            if (st.fdepth > 0) {
                st = fail(st, "ndef '" + disp(name) + "' must be at the top level (an assembly label has no place inside a function)", line, col);
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
        fparams.foreach((e, j) => {
            let pl = nline;
            let pc = ncol;
            if (j < len(fpos) && fpos[j] > 0) {
                pl = fpos[j] / 65536;
                pc = fpos[j] % 65536;
            };
            st = st_bind(st, e, args[j], "param", pl, pc);
            if (tc_index) { tci_note_key(pl * 65536 + pc, args[j]); };
        });
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
                let rt = rets[ri].typ;
                if (br.k == K.tunk && rt.k != K.tunk && rt.k != K.tnone) {
                    br = rt;
                    rsrc = "the first 'return'";
                }
                ri++;
            };
            // Every `return` must conform to it, as to a written type.
            ri = 0;
            while (ri < len(rets)) {
                let rn = rets[ri];
                if (!tcompat(rn.typ, br)) {
                    st = fail(st, "'return': expected " + tstr(br) + ", got " + tstr(rn.typ) + " (the return type is inferred from " + rsrc + ret_inferred_hint(rn.typ), rn.line, rn.col);
                }
                ri++;
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
                rets2.foreach((rn2) => {
                    if (!tcompat(rn2.typ, br)) {
                        st = fail(st, "'return': expected " + tstr(br) + ", got " + tstr(rn2.typ) + " (the return type is inferred from " + rsrc + ret_inferred_hint(rn2.typ), rn2.line, rn2.col);
                    }
                });
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

def st_fdepth(st: TcSt, d: long) -> TcSt { {...st, fdepth: d} };

// ── entry point ──────────────────────────────────────────────────────────

let tc_final: [Binding] = [];
let tc_none: Type = { k: K.tnone };

def check_program(ast: Block, ext: [Sym]) -> [Diag] {
    // Escape checking needs implicit conversions even with GC enabled:
    // an explicit or automatic region must not free a boxed return value.
    tch_alloc = [];
    tc_saw_region = false;
    // the inferred-return table is made when first written (inf_reset)
    let nobkts: [[long]] = [];
    inf_bkts = nobkts;
    // Only when it is on: emptying 1024 buckets on every compile of every
    // program would be a cost paid for a feature no compiler run uses.
    if (tc_index && !tc_heap) { tci_reset(); };
    tc_ixn = 0;
    tc_esc = [];
    // pass 1: collect top-level def signatures (allows mutual recursion).
    let defs: [Field] = [];
    let pstmts: [Node] = ast.stmts;
    pstmts.foreach((e) => {
        let s: Node = e;
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
    });
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
    ext.foreach((xe) => {
        // a package's global (its cell label, native.y arch_global_label)
        // is read-only to its importers
        let xk = "func";
        if (xe.label.starts_with("yg_")) { xk = "const"; }
        st = st_bind(st, xe.name, xe.typ, xk, 0 - 1, 0 - 1);
    });
    defs.foreach((e) => {
        st = st_bind(st, e.name, e.typ, "func", 0 - 1, 0 - 1);
    });
    let errs = (typeof_block(st, ast)).st.errors;
    tc_final = st.bindings;
    errs
};

def bind_at(name: str) -> long {
    let at = -1;
    if (tc_ixn > 0) {
        at = parser.nameix_get(tc_ix, name);
    } else {
        let i = len(tc_final) - 1;
        while (i >= 0) {
            if (tc_final[i].name == name) { at = i; i = -1; };
            i = i - 1;
        };
    };
    at
};

def bind_type(name: str) -> Type {
    let i = bind_at(name);
    if (i < 0) { tc_none } else { tc_final[i].typ }
};

def bind_kind(name: str) -> str {
    let i = bind_at(name);
    if (i < 0) { "" } else { tc_final[i].kind }
};

def def_sig(name: str, func: Func) -> Field {
    // Signature for the pre-pass. Missing annotations are poison (tunk);
    // pass 2 (typeof_def) reports each exactly once.
    let args: [Type] = [];
    let fpt: [Type] = func.ptypes;
    for i in 0..len(func.params) {
        let pt: Type = fpt[i];
        if (pt.k == K.tnone) { pt = t_unk(); };
        args += pt;
    };
    let ret: Type = func.ret;
    if (ret.k == K.tnone) { ret = t_pend(); };
    { name: name, opt: false, typ: type_node({ k: K.tfunc, args: args, ret: ret }) }
};

export { binary_result, ptr_math_kind, bind_type, bind_kind, saw_region, pointee_value, pack_of, pack_size, pack_offset, pack_ftype, pack_value_type, pack_scalar_size, pack_field_size, pack_bad, check_program, escaped, in_compares, os_call_names, tstr, teq, leaf_of, field_pos, field_merge, narrow_type, pat_subject, union_member, unfold, members, union_parts, pat_members, lit_target, lit_elems_take, opt_wraps, t_mutex, t_sem, tcanon, tsig, inferred_ret, str_sorted, rec_names, type_names, member_fields, member_field_type, is_prim_type, is_boxable_type, box_field_name, str_method, fmt_spec, fmt_kind, expr_type, type_index_on, type_index_off, heap_index_on, heap_index_off, heap_type, heap_alloc, output_alloc, alloc_conversion, Sym };
