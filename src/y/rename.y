// rename.y — static name resolution (uniquify) for the native pipeline.
// rename_program(ast) -> ast' where every binding has a globally unique
// name (`orig$N`; `$` is lexer-illegal, so generated names can never collide
// with user code). After this pass there is no shadowing and no scopes for
// later passes to resolve: types.y keeps one flat binding list, native.y
// one flat env.
//
// Rules:
// - let/const/def names, func params, foreach/forrange loop vars: bound.
// - References (id, assign/store targets, call callees, addr/index roots):
//   rewritten to the innermost binding; unbound names (intrinsics, `self`)
//   are left alone (the checker reports truly-undefined ones).
// - def names are pre-bound per block level (functions hoist, so mutual
//   recursion and forward calls resolve); value bindings (let/const) do NOT
//   hoist — use-before-def stays an error, like TDZ.
// - Map keys, dot keys, strings: untouched (not variables).
// - A module imported by name (`import fs;`) keeps its own scope: its
//   top-level defs and lets are bound as `fs.name`, which is how the
//   importer reaches them (`fs.read_file` is that one name, unless a
//   binding called `fs` is in scope), while the module's own code finds
//   them bare, before any program-level name (rn_top, rn_lookup).
//
// The C copy in src/c compiles this file, so every construct used here
// needs a twin there (PORTING.md).

// For its alias NamedTy.
import parser from "./parser.y";

// The renamer's state: the scopes, innermost last, each binding names
// to their unique names; n, the counter behind the `$N` suffixes; tys,
// the type aliases (rn_prepass_one); dfl, the default parameter values
// of the defs, by unique name (rn_note_defaults).
type Dfl = { name: str, vals: [{ k: str }] };
type RnSt = { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [NamedTy], dfl: [Dfl] };
type RnRes = { st: RnSt, node: { k: str } };
type RnStmts = { st: RnSt, stmts: [{ k: str }] };

// The modules imported by name (rename_program_x): each line's file
// (native.y's origin map), each file's module ("" for the program's own
// files), the module names, and the module of the top-level statement
// being renamed ("" for the program's own code).
let rn_ofile: [long] = [];
let rn_fmods: [str] = [];
let rn_mods: [str] = [];
let rn_mod = "";

def rn_fresh(st: RnSt, orig: str) -> { st: RnSt, name: str } {
    let u = orig + "$" + tostring(st.n);
    let nst = { scopes: st.scopes, n: st.n + 1, tys: st.tys, dfl: st.dfl };
    { st: nst, name: u }
};

def rn_push(st: RnSt) -> RnSt {
    st.scopes += [[]];
    let scopes = st.scopes;
    { scopes: scopes, n: st.n, tys: st.tys, dfl: st.dfl }
};

def rn_pop(st: RnSt) -> RnSt {
    let scopes = [];
    let old = st.scopes;
    let i = 0;
    while (i < len(old) - 1) {
        scopes += [old[i]];
        i = i + 1;
    };
    { scopes: scopes, n: st.n, tys: st.tys, dfl: st.dfl }
};

def rn_define(st: RnSt, orig: str, uniq: str) -> RnSt {
    let scopes = st.scopes;
    let top = scopes[len(scopes) - 1];
    top += { orig: orig, uniq: uniq };
    scopes[len(scopes) - 1] = top;
    { scopes: scopes, n: st.n, tys: st.tys, dfl: st.dfl }
};

def rn_lookup(st: RnSt, name: str) -> str {
    if (rn_mod == "") {
        rn_lookup_to(st, name, 0)
    } else {
        // a module's code: its locals (frames 2 up: 0 is empty, 1 holds
        // the top level), then its own top-level names, then the rest
        let u = rn_lookup_to(st, name, 2);
        if (u == "") { u = rn_lookup_to(st, rn_mod + "." + name, 1); 0; } else { 0; };
        if (u == "") { u = rn_lookup_to(st, name, 0); 0; } else { 0; };
        u
    }
};

// rn_lookup in the frames from the innermost down to frame `lo`.
def rn_lookup_to(st: RnSt, name: str, lo: long) -> str {
    // Innermost scope first; within a frame, the NEWEST binding wins
    // (a later let shadows an earlier one).
    let all = st.scopes;
    let i = len(all) - 1;
    let found = "";
    while (i >= lo) {
        let frame = all[i];
        let j = len(frame) - 1;
        while (j >= 0) {
            let e = frame[j];
            if (e.orig == name) {
                found = e.uniq;
                j = -1;
                i = -1;
                0
            };
            j = j - 1;
            0
        };
        i = i - 1;
        0
    };
    found
};

// Bind one name in the current scope, return {st, uniq}.
def rn_bind(st: RnSt, orig: str) -> { st: RnSt, uniq: str } {
    let r = rn_fresh(st, orig);
    st = rn_define(r.st, orig, r.name);
    { st: st, uniq: r.name }
};

def rn_list(nodes: [{k: str}], st: RnSt) -> { st: RnSt, nodes: [{k: str}] } {
    let out = [];
    let i = 0;
    while (i < len(nodes)) {
        let r = rn_node(nodes[i], st);
        st = r.st;
        out += r.node;
        i = i + 1;
    };
    { st: st, nodes: out }
};

def rn_id(st: RnSt, name: str, line: long, col: long) -> RnRes {
    let u = rn_lookup(st, name);
    if (u == "") {
        { st: st, node: { k: "id", v: name, line: line, col: col } }
    } else {
        { st: st, node: { k: "id", v: u, line: line, col: col } }
    }
};

// Pre-bind all def names (named defs + let-bound anonymous defs) in a
// statement list so mutual recursion resolves.
def rn_prepass(stmts: [{k: str}], st: RnSt) -> RnSt {
    // NOTE: stmts elements are bare {k}-holes at the boundary (like res);
    // pass each element as a BARE value (rn_prepass_one takes unannotated
    // s) so field reads resolve via the tcompat law, not merged shapes.
    let i = 0;
    while (i < len(stmts)) {
        st = rn_prepass_one(stmts[i], st);
        i = i + 1;
        0
    };
    st
};

def rn_prepass_one(s, st: RnSt) -> RnSt {
    if (s.k == "decl") {
        rn_prepass_decl(s, st)
    } else if (s.k == "typedef") {
        // aliases hoist like defs: every annotation in the block sees them
        st.tys += { name: s.name, typ: s.typ };
        st
    } else {
        st
    }
};

def rn_prepass_decl(s, st: RnSt) -> RnSt {
    // decl shapes only (named def vs let-bound func): one `s.v.k` read in
    // this body (see parse_type_arrow note — two reads in one body merge).
    if (s.kind == "def") {
        let r = rn_bind(st, s.name);
        rn_note_defaults(r.st, r.uniq, s.v)
    } else if (s.v.k == "func") {
        let r = rn_bind(st, s.name);
        rn_note_defaults(r.st, r.uniq, s.v)
    } else {
        st
    }
};

// Remember a def's default parameter values under its unique name, so a
// direct call that leaves trailing arguments out gets them filled in.
def rn_note_defaults(st: RnSt, uniq: str, func) -> RnSt {
    let dv: [{k: str}] = func.defs;
    let i = 0;
    let any = false;
    while (i < len(dv)) {
        let d = dv[i];
        let dk: str = d.k;
        if (dk != "void") { any = true; 0 };
        i = i + 1;
    };
    if (any) {
        st.dfl += { name: uniq, vals: dv };
        0
    };
    st
};

// The defaults of the def a call names ([] for anything else).
def rn_find_defaults(st: RnSt, name: str) -> [{k: str}] {
    let out: [{k: str}] = [];
    let ds = st.dfl;
    let i = 0;
    while (i < len(ds)) {
        let d = ds[i];
        if (d.name == name) { out = d.vals; 0 };
        i = i + 1;
    };
    out
};

// args + the defaults of the missing trailing parameters -- only when
// every one of them has a default (otherwise the checker reports the
// arity mismatch as usual). An optional parameter (`b?: T`, its default
// marked `optarg`) gets some(arg) when the call passes it, none when not.
def rn_fill_defaults(vals: [{k: str}], args: [{k: str}], line: long, col: long) -> [{k: str}] {
    let n = len(args);
    if (len(vals) == 0) {
        args
    } else {
        let ok = true;
        let i = n;
        while (i < len(vals)) {
            let d = vals[i];
            let dk: str = d.k;
            if (dk == "void") { ok = false; 0 };
            i = i + 1;
        };
        let out: [{k: str}] = [];
        let j = 0;
        while (j < n) {
            if (j < len(vals) && rn_is_optarg(vals[j])) {
                let one: [{k: str}] = [];
                one += args[j];
                out += { k: "call", callee: { k: "id", v: "some", line: line, col: col }, args: one, line: line, col: col };
                0
            } else {
                out += args[j];
                0
            };
            j = j + 1;
        };
        if (ok) {
            while (j < len(vals)) {
                if (rn_is_optarg(vals[j])) {
                    out += { k: "id", v: "none", line: line, col: col };
                    0
                } else {
                    out += vals[j];
                    0
                };
                j = j + 1;
            };
            0
        };
        out
    }
};

def rn_is_optarg(d: {k: str}) -> bool { d.k == "optarg" };

// ── type aliases ─────────────────────────────────────────────────────────
// `type A = T` makes the name A stand for T in every annotation (and match
// pattern) seen AFTER it. Resolution rewrites the type nodes, so the checker
// and emitter never see an alias name. A union's members are flattened (an
// alias of a union inside a union adds its members). NOTE: `tys` is never
// popped, so an alias declared inside a block stays visible for the rest of
// the traversal, siblings included — the alias table is not scoped like
// names.
//
// An alias may refer to itself (or to one that refers back to it) when the
// reference sits inside a record's field or a function type: `type L =
// {head: long, tail: L?}`. Every reference to such a recursive alias is
// one tref (an RnRef) whose `to` is the alias spelled out, its own
// references in it the same tref again: the type tree is cyclic through
// trefs only, and a recursive alias is one node wherever it is used (its
// canonical form, types.y tcanon, does not depend on where it is met). The
// checker and the emitter unfold a tref where they look inside a type
// (types.y unfold). A cycle outside every record field and function type
// (`type T = [T]`, `type T = T | {a: long}`) stands for no type: a tref to
// the unknown type, and an error at its `type` (rn_typedef_err).
type RnRef = { k: str, name: str, tmp: str, to: { k: str } };

// The trefs made so far (rn_tref), by alias index in st.tys; emptied for
// each program (rename_program_x).
let rn_tref_ids: [long] = [];
let rn_tref_nodes: [RnRef] = [];

def rn_type(st: RnSt, t) -> {k: str} {
    if (len(st.tys) == 0) { t } else { rn_type_go(st, t, 0) }
};

def rn_types(st: RnSt, ts: [{k: str}]) -> [{k: str}] {
    if (len(st.tys) == 0) {
        ts
    } else {
        let out: [{k: str}] = [];
        let i = 0;
        while (i < len(ts)) {
            out += rn_type(st, ts[i]);
            i = i + 1;
        };
        out
    }
};

// Identity with a declared {k: str} return: launders a rebuilt type node's
// real shape into the unknown-shape flow type, so the arms of a type dispatch
// agree (the normnode trick in native.y strip_ns).
def rn_tn(t) -> {k: str} { t };

def rn_type_go(st: RnSt, t, depth: long) -> {k: str} {
    let k: str = t.k;
    if (k == "tname") { rn_type_name(st, t.name, t, depth) }
    else if (k == "tptr") { rn_tn({ k: "tptr", to: rn_type_go(st, t.to, depth) }) }
    else if (k == "tarr") { rn_tn({ k: "tarr", of: rn_type_go(st, t.of, depth) }) }
    else if (k == "tarrfix") { rn_tn({ k: "tarrfix", of: rn_type_go(st, t.of, depth), n: t.n }) }
    else if (k == "topt") { rn_tn({ k: "topt", of: rn_type_go(st, t.of, depth) }) }
    else if (k == "tmap") { rn_tn({ k: "tmap", key: rn_type_go(st, t.key, depth), of: rn_type_go(st, t.of, depth) }) }
    else if (k == "trec") { rn_tn({ k: "trec", fields: rn_type_fields(st, t.fields, depth) }) }
    else if (k == "tfunc") { rn_tn({ k: "tfunc", args: rn_type_list(st, t.args, depth), ret: rn_type_go(st, t.ret, depth) }) }
    else if (k == "tparams") { rn_tn({ k: "tparams", ts: rn_type_list(st, t.ts, depth) }) }
    else if (k == "tunion") { rn_tn({ k: "tunion", ts: rn_union_flat(rn_type_list(st, t.ts, depth)) }) }
    else { t }
};

def rn_type_name(st: RnSt, name: str, t, depth: long) -> {k: str} {
    let found = rn_alias_index(st, name);
    // (depth only guards against a bug: a recursive alias is a tref, never
    // spelled out inside itself)
    if (found < 0 || depth > 64) {
        t
    } else if (rn_reaches(st, found, false)) {
        rn_tref(st, found, name)
    } else {
        let e = st.tys[found];
        rn_type_go(st, e.typ, depth + 1)
    }
};

// The index in st.tys of the alias `name` stands for (the last declared:
// -1 for none).
def rn_alias_index(st: RnSt, name: str) -> long {
    let tys = st.tys;
    let i = len(tys) - 1;
    let found = -1;
    while (i >= 0) {
        let e = tys[i];
        if (e.name == name) { found = i; i = -1; 0 };
        i = i - 1;
    };
    found
};

// The tref of recursive alias `id`: made, and the alias spelled out into
// it, the first time it is met.
def rn_tref(st: RnSt, id: long, name: str) -> {k: str} {
    let at = -1;
    let i = 0;
    while (at < 0 && i < len(rn_tref_ids)) {
        if (rn_tref_ids[i] == id) { at = i; 0 } else { 0 };
        i = i + 1;
    };
    if (at >= 0) {
        rn_tn(rn_tref_nodes[at])
    } else {
        let r: RnRef = { k: "tref", name: name, tmp: name + "$" + tostring(id), to: { k: "tnone" } };
        rn_tref_ids += id;
        rn_tref_nodes += r;
        if (rn_reaches(st, id, true)) {
            r.to = { k: "tunk" };
            0
        } else {
            let e = st.tys[id];
            r.to = rn_type_go(st, e.typ, 0);
            0
        };
        rn_tn(r)
    }
};

// Alias `id` refers to itself, through other aliases or not -- anywhere
// in it, or (`bare`) outside every record field and function type.
def rn_reaches(st: RnSt, id: long, bare: bool) -> bool {
    let seen: [long] = [];
    let e = st.tys[id];
    rn_reaches_go(st, e.typ, id, seen, bare)
};

def rn_reaches_go(st: RnSt, t, id: long, seen: [long], bare: bool) -> bool {
    let k: str = t.k;
    if (k == "tname") {
        let j = rn_alias_index(st, t.name);
        let walked = false;
        foreach (s in seen) { if (s == j) { walked = true; 0; } else { 0; }; };
        if (j < 0 || walked) { false }
        else if (j == id) { true }
        else {
            seen += j;
            let e = st.tys[j];
            rn_reaches_go(st, e.typ, id, seen, bare)
        }
    }
    else if (k == "tptr") { rn_reaches_go(st, t.to, id, seen, bare) }
    else if (k == "tarr" || k == "tarrfix" || k == "topt") { rn_reaches_go(st, t.of, id, seen, bare) }
    else if (k == "tmap") {
        if (rn_reaches_go(st, t.key, id, seen, bare)) { true } else { rn_reaches_go(st, t.of, id, seen, bare) }
    }
    else if (k == "trec") {
        let fs: [NamedTy] = t.fields;
        let hit = false;
        if (!bare) {
            foreach (f in fs) {
                if (!hit && rn_reaches_go(st, f.typ, id, seen, bare)) { hit = true; 0; } else { 0; };
            };
            0
        } else { 0; };
        hit
    }
    else if (k == "tfunc") {
        let hit = false;
        if (!bare) {
            let args: [{k: str}] = t.args;
            foreach (a in args) {
                if (!hit && rn_reaches_go(st, a, id, seen, bare)) { hit = true; 0; } else { 0; };
            };
            if (!hit) { hit = rn_reaches_go(st, t.ret, id, seen, bare); 0; } else { 0; };
            0
        } else { 0; };
        hit
    }
    else if (k == "tparams" || k == "tunion") {
        let ts: [{k: str}] = t.ts;
        let hit = false;
        foreach (m in ts) {
            if (!hit && rn_reaches_go(st, m, id, seen, bare)) { hit = true; 0; } else { 0; };
        };
        hit
    }
    else { false }
};

def rn_type_list(st: RnSt, ts: [{k: str}], depth: long) -> [{k: str}] {
    let out: [{k: str}] = [];
    let i = 0;
    while (i < len(ts)) {
        out += rn_type_go(st, ts[i], depth);
        i = i + 1;
    };
    out
};

def rn_type_fields(st: RnSt, fs: [NamedTy], depth: long) -> [NamedTy] {
    let out: [NamedTy] = [];
    let i = 0;
    while (i < len(fs)) {
        let f = fs[i];
        out += { name: f.name, typ: rn_type_go(st, f.typ, depth) };
        i = i + 1;
    };
    out
};

def rn_union_flat(ts: [{k: str}]) -> [{k: str}] {
    let out: [{k: str}] = [];
    let i = 0;
    while (i < len(ts)) {
        let t = ts[i];
        let tk: str = t.k;
        if (tk == "tunion") {
            let inner: [{k: str}] = t.ts;
            out += inner;
            0
        } else {
            out += t;
            0
        };
        i = i + 1;
    };
    out
};

def rn_drop_typedefs(stmts: [{k: str}], st: RnSt) -> [{k: str}] {
    let out: [{k: str}] = [];
    let i = 0;
    while (i < len(stmts)) {
        let s = stmts[i];
        let sk: str = s.k;
        if (sk == "typedef") {
            // Dropped -- unless its type names something undefined.
            let te = rn_typedef_err(s, st);
            if (te.k == "err") { out += te; 0; } else { 0; };
            0
        } else { out += s; 0 };
        i = i + 1;
    };
    out
};

def rn_typedef_err(s, st: RnSt) -> {k: str} {
    let un = rn_unknown_type(st, s.typ);
    let name: str = s.name;
    let id = rn_alias_index(st, name);
    if (un != "") { rn_unknown_err(un, s.line, s.col) }
    else if (id >= 0 && rn_reaches(st, id, true)) {
        rn_tn({ k: "err", msg: "type '" + name + "' refers to itself outside any record field or function type", line: s.line, col: s.col })
    } else { rn_tn({ k: "void" }) }
};

// ── unknown type names ───────────────────────────────────────────────────
// The parser turns the builtin names into their own kinds, so a `tname`
// left in an annotation must be an alias in scope. One that is not is an
// error -- the checker would otherwise unify it with anything, and
// `let s: strr = "x"` compiled with `s` silently untyped.

def rn_unknown_err(name: str, line: long, col: long) -> {k: str} {
    rn_tn({ k: "err", msg: "unknown type '" + name + "'", line: line, col: col })
};

// The first unknown name in annotation t ("" when every name resolves).
def rn_unknown_type(st: RnSt, t) -> str {
    let k: str = t.k;
    if (k == "tname") { rn_alias_known(st.tys, t.name) }
    else if (k == "tptr") { rn_unknown_type(st, t.to) }
    else if (k == "tarr") { rn_unknown_type(st, t.of) }
    else if (k == "tarrfix") { rn_unknown_type(st, t.of) }
    else if (k == "topt") { rn_unknown_type(st, t.of) }
    else if (k == "tmap") { rn_unknown_then(rn_unknown_type(st, t.key), st, t.of) }
    else if (k == "trec") { rn_unknown_fields(st, t.fields) }
    else if (k == "tfunc") { rn_unknown_then(rn_unknown_list(st, t.args), st, t.ret) }
    else if (k == "tparams") { rn_unknown_list(st, t.ts) }
    else if (k == "tunion") { rn_unknown_list(st, t.ts) }
    else { "" }
};

// "" when `name` is an alias in scope, else the name itself.
def rn_alias_known(tys: [NamedTy], name: str) -> str {
    let found = false;
    foreach (e in tys) {
        if (e.name == name) { found = true; 0; } else { 0; };
    };
    if (found) { "" } else { name }
};

def rn_unknown_then(first: str, st: RnSt, t) -> str {
    if (first != "") { first } else { rn_unknown_type(st, t) }
};

def rn_unknown_list(st: RnSt, ts: [{k: str}]) -> str {
    let out = "";
    foreach (t in ts) {
        if (out == "") { out = rn_unknown_type(st, t); 0; } else { 0; };
    };
    out
};

def rn_unknown_fields(st: RnSt, fs: [NamedTy]) -> str {
    let out = "";
    foreach (f in fs) {
        if (out == "") { out = rn_unknown_type(st, f.typ); 0; } else { 0; };
    };
    out
};

// Redefinition shadows: `def f ... def f ...` keeps the LAST definition, and
// every reference (before or after, since defs hoist) binds to it. rename.y
// resolves def names through the prepass binding, so two same-named defs would
// otherwise collapse onto one unique name; give the earlier ones a dead name
// instead. They are still checked and emitted — only unreachable.
def rn_shadow_dups(stmts: [{k: str}]) -> [{k: str}] {
    let names: [str] = [];
    let ndefs = 0;
    foreach (s in stmts) {
        let nm = rn_decl_name(s);
        names += nm;
        if (nm != "") { ndefs = ndefs + 1; 0; } else { 0; };
    };
    if (ndefs < 2) {
        stmts
    } else {
        let later = rn_later(names);
        let out: [{k: str}] = [];
        let i = 0;
        while (i < len(stmts)) {
            if (later[i]) {
                out += rn_rebuild_decl(stmts[i], names[i] + "$shadow" + tostring(i));
                0
            } else { out += stmts[i]; 0; };
            i = i + 1;
        };
        out
    }
};

// later[i]: whether names[i] (a def's name, "" for none) is bound again
// by a later statement. One pass from the back over an open-addressing
// set of the names seen (comparing each def with every later statement
// was 3% of a self-compile).
def rn_later(names: [str]) -> [bool] {
    let n = len(names);
    let size = 16;
    while (size < 2 * n) { size = size * 2; };
    let slots: [str] = [];
    let k = 0;
    while (k < size) { slots += ""; k = k + 1; };
    let out: [bool] = [];
    k = 0;
    while (k < n) { out += false; k = k + 1; };
    let i = n - 1;
    while (i >= 0) {
        let nm = names[i];
        if (nm != "") {
            let h = rn_hash(nm) & (size - 1);
            let go = true;
            while (go) {
                let e = slots[h];
                if (e == "") { slots[h] = nm; go = false; }
                else if (e == nm) { out[i] = true; go = false; }
                else { h = (h + 1) & (size - 1); };
            };
        };
        i = i - 1;
    };
    out
};

// A 24-bit hash of s (rn_later's slots).
def rn_hash(s: str) -> long {
    let h = 0;
    let i = 0;
    while (i < len(s)) {
        h = (h * 33 + byte_at(s, i)) & 16777215;
        i = i + 1;
    };
    h
};

// The name a statement binds as a hoisted def, or "" when it binds none.
def rn_decl_name(s) -> str {
    if (s.k == "decl") {
        rn_decl_name_go(s)
    } else {
        ""
    }
};

def rn_decl_name_go(s) -> str {
    // NOTE: one `s.v.k` read per body (see rn_prepass_decl note).
    if (s.kind == "def") {
        s.name
    } else if (s.v.k == "func") {
        s.name
    } else {
        ""
    }
};

def rn_rebuild_decl(s, newname: str) -> {k: str} {
    // NOTE: one literal per arm would merge two key sets through the same
    // `if` (see parse_type_arrow note) — dispatch to single-call arms so
    // each shape unifies against the {k}-hole return type instead.
    if (s.kind == "def") {
        rn_rebuild_def(s, newname)
    } else {
        rn_rebuild_let(s, newname)
    }
};

def rn_rebuild_def(s, newname: str) -> {k: str} {
    { k: "decl", kind: "def", name: newname, v: s.v, line: s.line, col: s.col }
};

def rn_rebuild_let(s, newname: str) -> {k: str} {
    { k: "decl", kind: s.kind, name: newname, typ: s.typ, v: s.v, line: s.line, col: s.col }
};

def rn_block(stmts: [{k: str}], st: RnSt) -> RnStmts {
    stmts = rn_shadow_dups(stmts);
    st = rn_push(st);
    st = rn_prepass(stmts, st);
    let r = rn_list(rn_drop_typedefs(stmts, st), st);
    st = rn_pop(r.st);
    { st: st, stmts: r.nodes }
};

def rn_node(node, st: RnSt) -> RnRes {
    // NOTE: dispatch WITHOUT a shared-shape if-chain (see parser.y
    // parse_type_arrow note): a long arm chain on one name merges every
    // arm's node shape through the flow-insensitive env (each arm's return
    // type must teq ALL others). Each arm here is a SINGLE callee call (or
    // leaf literal) with the uniform return type R, so arms always agree.
    // Leaf shapes (num/str/bool/void) return the node untouched.
    let k = node.k;
    if (k == "num") {
        { st: st, node: node }
    } else if (k == "str") {
        { st: st, node: node }
    } else if (k == "bstr") {
        { st: st, node: node }
    } else if (k == "bool") {
        { st: st, node: node }
    } else if (k == "void") {
        { st: st, node: node }
    } else if (k == "id") {
        rn_id(st, node.v, node.line, node.col)
    } else if (k == "un") {
        rn_un(node, st)
    } else if (k == "addr") {
        rn_addrderef(node, st)
    } else if (k == "deref") {
        rn_addrderef(node, st)
    } else if (k == "bin") {
        rn_bin(node, st)
    } else if (k == "call") {
        rn_call(node, st)
    } else if (k == "if") {
        rn_if(node, st)
    } else if (k == "while") {
        rn_while(node, st)
    } else if (k == "block") {
        rn_blocknode(node, st)
    } else if (k == "decl") {
        rn_decl(node, st)
    } else if (k == "func") {
        rn_func(node, st)
    } else if (k == "assign") {
        rn_assign(node, st)
    } else if (k == "incdec") {
        rn_incdec(node, st)
    } else if (k == "opassign") {
        rn_opassign(node, st)
    } else if (k == "store") {
        rn_store(node, st)
    } else if (k == "ret") {
        rn_ret(node, st)
    } else if (k == "array") {
        rn_array(node, st)
    } else if (k == "arrrep") {
        rn_arrrep(node, st)
    } else if (k == "rec") {
        rn_reclit(node, st)
    } else if (k == "map") {
        rn_maplit(node, st)
    } else if (k == "index") {
        rn_index(node, st)
    } else if (k == "slice") {
        rn_slice(node, st)
    } else if (k == "dot") {
        rn_dot(node, st)
    } else if (k == "idxassign") {
        rn_idxassign(node, st)
    } else if (k == "dotassign") {
        rn_dotassign(node, st)
    } else if (k == "foreach") {
        rn_foreach(node, st)
    } else if (k == "forrange") {
        rn_forrange(node, st)
    } else if (k == "for") {
        rn_for(node, st)
    } else if (k == "sliceassign") {
        rn_sliceassign(node, st)
    } else if (k == "rectest") {
        rn_typed_e(node, st)
    } else if (k == "narrow") {
        rn_typed_e(node, st)
    } else if (k == "matchend") {
        rn_matchend(node, st)
    } else {
        { st: st, node: node }
    }
};

// rectest / narrow: an operand plus the (alias-resolved) type it tests.
def rn_typed_e(node, st: RnSt) -> RnRes {
    let e = rn_node(node.e, st);
    let un = rn_unknown_type(e.st, node.typ);
    if (un == "") {
        { st: e.st, node: rn_tn({ k: node.k, e: e.node, typ: rn_type(e.st, node.typ), line: node.line, col: node.col }) }
    } else {
        { st: e.st, node: rn_unknown_err(un, node.line, node.col) }
    }
};

def rn_matchend(node, st: RnSt) -> RnRes {
    let e = rn_node(node.e, st);
    { st: e.st, node: { k: "matchend", e: e.node, cover: rn_types(e.st, node.cover), vals: node.vals, line: node.line, col: node.col } }
};

def rn_sliceassign(node, st: RnSt) -> RnRes {
    let a = rn_node(node.arr, st);
    let l = rn_node(node.lo, a.st);
    let h = rn_node(node.hi, l.st);
    let v = rn_node(node.v, h.st);
    { st: v.st, node: { k: "sliceassign", arr: a.node, lo: l.node, hi: h.node, v: v.node, line: node.line, col: node.col } }
};

// One def per AST shape (see rn_node note). Each takes the bare node hole
// (param name `node` is exempt from annotation, like parser.y res) plus the
// annotated scope state, and returns the uniform R. Field reads off the
// bare hole unify quietly via the tcompat law (tnone); each body reads
// ONLY its own shape's fields.
def rn_un(node, st: RnSt) -> RnRes {
    let r = rn_node(node.e, st);
    { st: r.st, node: { k: "un", op: node.op, e: r.node, line: node.line, col: node.col } }
};

def rn_addrderef(node, st: RnSt) -> RnRes {
    let k = node.k;
    let r = rn_node(node.e, st);
    { st: r.st, node: { k: k, e: r.node, line: node.line, col: node.col } }
};

def rn_bin(node, st: RnSt) -> RnRes {
    let l = rn_node(node.l, st);
    let r = rn_node(node.r, l.st);
    { st: r.st, node: { k: "bin", op: node.op, l: l.node, r: r.node, line: node.line, col: node.col } }
};

def rn_call(node, st: RnSt) -> RnRes {
    let c = rn_node(node.callee, st);
    let a = rn_list(node.args, c.st);
    let cn = c.node;
    let args = a.nodes;
    if (cn.k == "id") {
        args = rn_fill_defaults(rn_find_defaults(a.st, cn.v), args, node.line, node.col);
        0
    };
    { st: a.st, node: { k: "call", callee: cn, args: args, line: node.line, col: node.col } }
};

def rn_if(node, st: RnSt) -> RnRes {
    let c = rn_node(node.cond, st);
    rn_if_then(node, c.node, c.st)
};

def rn_if_then(node, cond: {k: str}, st: RnSt) -> RnRes {
    let tb = rn_block(node.then.stmts, st);
    rn_if_finish(node, cond, tb.stmts, tb.st)
};

def rn_if_finish(node, cond: {k: str}, tstmts: [{k: str}], st: RnSt) -> RnRes {
    // NOTE: both arms build the SAME key set (cond/then/els/has_else);
    // els differs (renamed vs passthrough) but both unify — teq holds.
    if (node.has_else) {
        let e = rn_node(node.els, st);
        { st: e.st, node: { k: "if", cond: cond, then: { k: "block", stmts: tstmts, line: node.then.line, col: node.then.col }, els: e.node, has_else: true, line: node.line, col: node.col } }
    } else {
        { st: st, node: { k: "if", cond: cond, then: { k: "block", stmts: tstmts, line: node.then.line, col: node.then.col }, els: node.els, has_else: false, line: node.line, col: node.col } }
    }
};

def rn_while(node, st: RnSt) -> RnRes {
    let c = rn_node(node.cond, st);
    rn_while_body(node, c.node, c.st)
};

def rn_while_body(node, cond: {k: str}, st: RnSt) -> RnRes {
    let b = rn_block(node.body.stmts, st);
    { st: b.st, node: { k: "while", cond: cond, body: { k: "block", stmts: b.stmts, line: node.body.line, col: node.body.col }, line: node.line, col: node.col } }
};

def rn_blocknode(node, st: RnSt) -> RnRes {
    let b = rn_block(node.stmts, st);
    { st: b.st, node: { k: "block", stmts: b.stmts, line: node.line, col: node.col } }
};

def rn_assign(node, st: RnSt) -> RnRes {
    let r = rn_node(node.v, st);
    rn_assign_lookup(node, r.node, r.st)
};

def rn_assign_lookup(node, v: {k: str}, st: RnSt) -> RnRes {
    let u = rn_lookup(st, node.name);
    rn_assign_finish(node, v, u, st)
};

def rn_assign_finish(node, v: {k: str}, u: str, st: RnSt) -> RnRes {
    // NOTE: both arms share the key set; name differs (passthrough vs
    // renamed) but str vs hole unifies — teq holds.
    if (u == "") {
        { st: st, node: { k: "assign", name: node.name, v: v, line: node.line, col: node.col } }
    } else {
        { st: st, node: { k: "assign", name: u, v: v, line: node.line, col: node.col } }
    }
};

// ++x / x++: the target is an expression (id, index, dot) and is renamed
// like any other — it is evaluated exactly once at run time.
def rn_incdec(node, st: RnSt) -> RnRes {
    let r = rn_node(node.tgt, st);
    { st: r.st, node: { k: "incdec", op: node.op, pre: node.pre, tgt: r.node, line: node.line, col: node.col } }
};

def rn_opassign(node, st: RnSt) -> RnRes {
    let t = rn_node(node.tgt, st);
    let v = rn_node(node.v, t.st);
    { st: v.st, node: { k: "opassign", op: node.op, tgt: t.node, v: v.node, line: node.line, col: node.col } }
};

def rn_store(node, st: RnSt) -> RnRes {
    let p = rn_node(node.p, st);
    rn_store_val(node, p.node, p.st)
};

def rn_store_val(node, p: {k: str}, st: RnSt) -> RnRes {
    let v = rn_node(node.v, st);
    { st: v.st, node: { k: "store", p: p, v: v.node, line: node.line, col: node.col } }
};

def rn_ret(node, st: RnSt) -> RnRes {
    let r = rn_node(node.e, st);
    { st: r.st, node: { k: "ret", e: r.node, line: node.line, col: node.col } }
};

def rn_array(node, st: RnSt) -> RnRes {
    let r = rn_list(node.elems, st);
    { st: r.st, node: { k: "array", elems: r.nodes, line: node.line, col: node.col } }
};

def rn_arrrep(node, st: RnSt) -> RnRes {
    let r = rn_node(node.v, st);
    { st: r.st, node: { k: "arrrep", v: r.node, n: node.n, line: node.line, col: node.col } }
};

def rn_reclit(node, st: RnSt) -> RnRes {
    let r = rn_list(node.vals, st);
    { st: r.st, node: { k: "rec", keys: node.keys, vals: r.nodes, line: node.line, col: node.col } }
};

def rn_maplit(node, st: RnSt) -> RnRes {
    let r = rn_list(node.vals, st);
    { st: r.st, node: { k: "map", keys: node.keys, vals: r.nodes, line: node.line, col: node.col } }
};

def rn_index(node: {k: str, arr: {k: str}, idx: {k: str}, line: long, col: long}, st: RnSt) -> RnRes {
    let a = rn_node(node.arr, st);
    rn_index_idx(node, a.node, a.st)
};

def rn_index_idx(node, a: {k: str}, st: RnSt) -> RnRes {
    let x = rn_node(node.idx, st);
    { st: x.st, node: { k: "index", arr: a, idx: x.node, line: node.line, col: node.col } }
};

def rn_slice(node, st: RnSt) -> RnRes {
    let a = rn_node(node.arr, st);
    rn_slice_lo(node, a.node, a.st)
};

def rn_slice_lo(node, a: {k: str}, st: RnSt) -> RnRes {
    let l = rn_node(node.lo, st);
    rn_slice_hi(node, a, l.node, l.st)
};

def rn_slice_hi(node, a: {k: str}, lo: {k: str}, st: RnSt) -> RnRes {
    let h = rn_node(node.hi, st);
    { st: h.st, node: { k: "slice", arr: a, lo: lo, hi: h.node, line: node.line, col: node.col } }
};

def rn_dot(node: {k: str, obj: {k: str}, key: str, line: long, col: long}, st: RnSt) -> RnRes {
    let q = rn_qualified(st, node.obj, node.key);
    if (q != "") {
        rn_id(st, q, node.line, node.col)
    } else {
        let o = rn_node(node.obj, st);
        { st: o.st, node: { k: "dot", obj: o.node, key: node.key, line: node.line, col: node.col } }
    }
};

// `m.key` naming a module's top-level binding: "m.key" when obj is the
// name of a module imported by name and no binding of that name is in
// scope, "" otherwise.
def rn_qualified(st: RnSt, obj: {k: str}, key: str) -> str {
    if (obj.k == "id" && len(rn_mods) > 0) {
        let m: str = obj.v;
        if (rn_in(rn_mods, m) && rn_lookup(st, m) == "") { m + "." + key } else { "" }
    } else { "" }
};

def rn_in(xs: [str], x: str) -> bool {
    let found = false;
    foreach (e in xs) {
        if (e == x) { found = true; 0; } else { 0; };
    };
    found
};

def rn_idxassign(node, st: RnSt) -> RnRes {
    let a = rn_node(node.arr, st);
    rn_idxassign_idx(node, a.node, a.st)
};

def rn_idxassign_idx(node, a: {k: str}, st: RnSt) -> RnRes {
    let x = rn_node(node.idx, st);
    rn_idxassign_val(node, a, x.node, x.st)
};

def rn_idxassign_val(node, a: {k: str}, idx: {k: str}, st: RnSt) -> RnRes {
    let v = rn_node(node.v, st);
    { st: v.st, node: { k: "idxassign", arr: a, idx: idx, v: v.node, line: node.line, col: node.col } }
};

def rn_dotassign(node, st: RnSt) -> RnRes {
    let q = rn_qualified(st, node.obj, node.key);
    if (q != "") {
        // `fs.x = v`: an assignment to the module's global
        rn_assign({ k: "assign", name: q, v: node.v, line: node.line, col: node.col }, st)
    } else {
        let o = rn_node(node.obj, st);
        rn_dotassign_val(node, o.node, o.st)
    }
};

def rn_dotassign_val(node, o: {k: str}, st: RnSt) -> RnRes {
    let v = rn_node(node.v, st);
    { st: v.st, node: { k: "dotassign", obj: o, key: node.key, v: v.node, line: node.line, col: node.col } }
};

def rn_foreach(node, st: RnSt) -> RnRes {
    let it = rn_node(node.iter, st);
    rn_foreach_body(node, it.node, it.st)
};

def rn_foreach_body(node, iter: {k: str}, st: RnSt) -> RnRes {
    let st1 = rn_push(st);
    let nb = rn_bind(st1, node.name);
    rn_foreach_block(node, iter, nb.uniq, nb.st)
};

def rn_foreach_block(node, iter: {k: str}, uniq: str, st: RnSt) -> RnRes {
    let b = rn_block(node.body.stmts, st);
    let st2 = rn_pop(b.st);
    { st: st2, node: { k: "foreach", name: uniq, iter: iter, body: { k: "block", stmts: b.stmts, line: node.body.line, col: node.body.col }, line: node.line, col: node.col } }
};

def rn_forrange(node, st: RnSt) -> RnRes {
    let l = rn_node(node.lo, st);
    rn_forrange_hi(node, l.node, l.st)
};

def rn_forrange_hi(node, lo: {k: str}, st: RnSt) -> RnRes {
    let h = rn_node(node.hi, st);
    rn_forrange_body(node, lo, h.node, h.st)
};

def rn_forrange_body(node, lo: {k: str}, hi: {k: str}, st: RnSt) -> RnRes {
    let st1 = rn_push(st);
    let nb = rn_bind(st1, node.name);
    rn_forrange_block(node, lo, hi, nb.uniq, nb.st)
};

def rn_forrange_block(node, lo: {k: str}, hi: {k: str}, uniq: str, st: RnSt) -> RnRes {
    let b = rn_block(node.body.stmts, st);
    let st2 = rn_pop(b.st);
    { st: st2, node: { k: "forrange", name: uniq, lo: lo, hi: hi, body: { k: "block", stmts: b.stmts, line: node.body.line, col: node.body.col }, line: node.line, col: node.col } }
};

def rn_for(node, st: RnSt) -> RnRes {
    let ri = rn_node(node.init, st);
    rn_for_cond(node, ri.node, ri.st)
};

def rn_for_cond(node, init: {k: str}, st: RnSt) -> RnRes {
    let rc = rn_node(node.cond, st);
    rn_for_step(node, init, rc.node, rc.st)
};

def rn_for_step(node, init: {k: str}, cond: {k: str}, st: RnSt) -> RnRes {
    let rs = rn_node(node.step, st);
    rn_for_body(node, init, cond, rs.node, rs.st)
};

def rn_for_body(node, init: {k: str}, cond: {k: str}, step: {k: str}, st: RnSt) -> RnRes {
    let b = rn_block(node.body.stmts, st);
    { st: b.st, node: { k: "for", init: init, cond: cond, step: step, body: { k: "block", stmts: b.stmts, line: node.body.line, col: node.body.col }, line: node.line, col: node.col } }
};

def rn_decl(node: {k: str}, st: RnSt) -> RnRes {
    // NOTE: dispatch by shape into dedicated callees (see rn_node note):
    // named-def vs let-bound-func vs plain value — each body reads ONLY
    // its own shape's fields.
    if (node.kind == "def") {
        rn_decl_def(node, st)
    } else {
        rn_decl_rest(node, st)
    }
};

def rn_decl_def(node, st: RnSt) -> RnRes {
    // name pre-bound by rn_prepass; look it up (the empty arm below is a
    // fallback for a decl that never went through the prepass)
    rn_decl_def_lookup(node, rn_lookup(st, node.name), st)
};

def rn_decl_def_lookup(node, u: str, st: RnSt) -> RnRes {
    // NOTE: both arms share the key set (kind/def/name/v) — teq holds.
    if (u == "") {
        let b = rn_bind(st, node.name);
        rn_decl_def_go(node, b.uniq, b.st)
    } else {
        rn_decl_def_go(node, u, st)
    }
};

def rn_decl_def_go(node, u: str, st: RnSt) -> RnRes {
    let f = rn_func(node.v, st);
    { st: f.st, node: { k: "decl", kind: "def", name: u, v: f.node, line: node.line, col: node.col } }
};

def rn_decl_rest(node, st: RnSt) -> RnRes {
    if (node.v.k == "func") {
        rn_decl_func(node, st)
    } else {
        rn_decl_val(node, st)
    }
};

def rn_decl_func(node, st: RnSt) -> RnRes {
    rn_decl_func_lookup(node, rn_lookup(st, node.name), st)
};

def rn_decl_func_lookup(node, u: str, st: RnSt) -> RnRes {
    // NOTE: both arms share the key set — teq holds.
    if (u == "") {
        let b = rn_bind(st, node.name);
        rn_decl_func_go(node, b.uniq, b.st)
    } else {
        rn_decl_func_go(node, u, st)
    }
};

def rn_decl_func_go(node, u: str, st: RnSt) -> RnRes {
    let f = rn_func(node.v, st);
    rn_decl_func_finish(node, u, f.node, f.st)
};

def rn_decl_func_finish(node, u: str, fv: {k: str}, st: RnSt) -> RnRes {
    { st: st, node: { k: "decl", kind: node.kind, name: u, typ: rn_type(st, node.typ), v: fv, line: node.line, col: node.col } }
};

def rn_decl_val(node, st: RnSt) -> RnRes {
    let r = rn_node(node.v, st);
    rn_decl_val_bind(node, r.node, r.st)
};

def rn_decl_val_bind(node, v: {k: str}, st: RnSt) -> RnRes {
    let b = rn_bind(st, node.name);
    rn_decl_val_finish(node, v, b.uniq, b.st)
};

def rn_decl_val_finish(node, v: {k: str}, uniq: str, st: RnSt) -> RnRes {
    let un = rn_unknown_type(st, node.typ);
    let v2 = v;
    if (un != "") {
        // The value is still checked, after the error: `{ err; v }`.
        let es: [{k: str}] = [];
        es += rn_unknown_err(un, node.line, node.col);
        es += v;
        v2 = rn_tn({ k: "block", stmts: es, line: node.line, col: node.col });
        0
    } else { 0; };
    { st: st, node: { k: "decl", kind: node.kind, name: uniq, typ: rn_type(st, node.typ), v: v2, line: node.line, col: node.col } }
};

// Rename a func value. `func` is annotated with the full func shape (the
// parser's, parser.y parse_def: `defs` holds the parameter defaults), so
// its fields type-check against that shape; the rn_func_p* chain exists to
// pass each one on as a plain VALUE (params/ptypes/ret/body/line/col) so no
// callee carries a body full of `func.x` reads — rn_func_p4 is the one
// place with two, the two longs.
type RnFunc = { k: str, params: [{ k: str }], ptypes: [{ k: str }], ret: { k: str }, body: { k: str }, line: long, col: long, defs: [{ k: str }] };
def rn_func(func: RnFunc, st: RnSt) -> RnRes {
    rn_func_p1(func, func.params, rn_push(st))
};

def rn_func_p1(func: RnFunc, fparams, st: RnSt) -> RnRes {
    rn_func_p2(func, fparams, func.ptypes, st)
};

def rn_func_p2(func: RnFunc, fparams, fptypes, st: RnSt) -> RnRes {
    rn_func_p3(func, fparams, fptypes, func.ret, st)
};

def rn_func_p3(func: RnFunc, fparams, fptypes, fret, st: RnSt) -> RnRes {
    rn_func_p4(func, fparams, fptypes, fret, func.body, st)
};

def rn_func_p4(func: RnFunc, fparams, fptypes, fret, fbody, st: RnSt) -> RnRes {
    rn_func_p5(fparams, fptypes, fret, fbody, func.line, func.col, st)
};

def rn_func_p5(fparams, fptypes, fret, fbody, fline: long, fcol: long, st: RnSt) -> RnRes {
    rn_func_params(fparams, fptypes, fret, fbody, fline, fcol, st)
};

def rn_func_params(fparams, fptypes, fret, fbody, fline: long, fcol: long, st: RnSt) -> RnRes {
    rn_func_go(fparams, fptypes, fret, fbody, fline, fcol, [], 0, st)
};

def rn_func_go(fparams, fptypes, fret, fbody, fline: long, fcol: long, params: [str], i: long, st: RnSt) -> RnRes {
    // NOTE: recursion over the param list (replaces the while loop): the
    // loop's `st = b.st` rebind poisoned the merged-shape read of st.
    // fparams stays BARE (like res(node)): the single `fparams[i]` read
    // unifies via the tcompat law (tnone).
    if (i >= len(fparams)) {
        rn_func_body(fptypes, fret, fbody, fline, fcol, params, st)
    } else {
        let b = rn_bind(st, fparams[i]);
        params += b.uniq;
        rn_func_go(fparams, fptypes, fret, fbody, fline, fcol, params, i + 1, b.st)
    }
};

def rn_func_body(fptypes, fret, fbody: {k: str, stmts: [{k: str}], line: long, col: long}, fline: long, fcol: long, params: [str], st: RnSt) -> RnRes {
    // NOTE: fbody read ONCE here (one read site — no merge).
    let b = rn_block(fbody.stmts, st);
    rn_func_finish(fptypes, fret, fbody, fline, fcol, params, b.stmts, rn_pop(b.st))
};

def rn_func_finish(fptypes, fret, fbody, fline: long, fcol: long, params: [str], stmts: [{k: str}], st: RnSt) -> RnRes {
    // NOTE: NO record reads here — all values are params already. `fbody`
    // rides along for signature parity with the C twin and is never read.
    let un = rn_unknown_list(st, fptypes);
    if (un == "") { un = rn_unknown_type(st, fret); 0; } else { 0; };
    let body: [{k: str}] = [];
    if (un != "") { body += rn_unknown_err(un, fline, fcol); 0; } else { 0; };
    body += stmts;
    { st: st, node: { k: "func", params: params, ptypes: rn_types(st, fptypes), ret: rn_type(st, fret), body: { k: "block", stmts: body, line: fline, col: fcol }, line: fline, col: fcol } }
};



def rename_program(ast) -> {k: str} {
    let none: [Dfl] = [];
    let nofile: [long] = [];
    let nomods: [str] = [];
    rename_program_x(ast, none, nofile, nomods)
};

// A unit importing packages (native.y compile_unit): `dfl` holds their
// defs' parameter defaults under the qualified names calls use. ofile
// and fmods say which lines belong to a module imported by name: line
// i + 1 is in file ofile[i], and that file is module fmods[ofile[i]]
// ("" for none).
def rename_program_x(ast, dfl: [Dfl], ofile: [long], fmods: [str]) -> {k: str} {
    let noids: [long] = [];
    let nonodes: [RnRef] = [];
    rn_tref_ids = noids;
    rn_tref_nodes = nonodes;
    rn_ofile = ofile;
    rn_fmods = fmods;
    let mods: [str] = [];
    foreach (m in fmods) {
        if (m != "" && !rn_in(mods, m)) { mods += m; 0; } else { 0; };
    };
    rn_mods = mods;
    rn_mod = "";
    rename_program_go(ast.stmts, ast.line, ast.col, dfl)
};

// The module top-level statement s belongs to ("" for none).
def rn_stmt_mod(s: {k: str}) -> str {
    if (s.k == "void") {
        // (the one statement with no line)
        ""
    } else {
        let ln: long = s.line;
        if (ln >= 1 && ln <= len(rn_ofile)) {
            let f = rn_ofile[ln - 1];
            if (f < len(rn_fmods)) { rn_fmods[f] } else { "" }
        } else { "" }
    }
};

// A module's top-level def or let, under its qualified name (`fs.exists`);
// a `y_` name stays as it is (generated code calls those by label).
def rn_qualify(s) -> {k: str} {
    let m = rn_stmt_mod(s);
    if (m == "" || s.k != "decl") {
        s
    } else {
        let nm: str = s.name;
        if (nm.starts_with("y_")) { s } else { rn_rebuild_decl(s, m + "." + nm) }
    }
};

// The unit's top level: rn_block, with a module's names qualified and
// each statement renamed in its own module's scope (rn_mod).
def rn_top(stmts: [{k: str}], st: RnSt) -> RnStmts {
    let q: [{k: str}] = [];
    if (len(rn_mods) > 0) {
        foreach (s in stmts) { q += rn_qualify(s); };
        0
    } else { q = stmts; 0; };
    q = rn_shadow_dups(q);
    st = rn_push(st);
    st = rn_prepass(q, st);
    let kept = rn_drop_typedefs(q, st);
    let out: [{k: str}] = [];
    foreach (s in kept) {
        if (len(rn_mods) > 0) { rn_mod = rn_stmt_mod(s); 0; } else { 0; };
        let r = rn_node(s, st);
        st = r.st;
        out += r.node;
    };
    rn_mod = "";
    st = rn_pop(st);
    { st: st, stmts: out }
};

def rename_program_go(stmts: [{k: str}], line: long, col: long, dfl: [Dfl]) -> {k: str} {
    // NOTE: fields passed as values (see rn_func note). dfl is copied:
    // rn_note_defaults appends to the list in place.
    let d0: [Dfl] = [];
    d0 += dfl;
    let st = { scopes: [[]], n: 1, tys: [], dfl: d0 };
    let b = rn_top(stmts, st);
    { k: "block", stmts: b.stmts, line: line, col: col }
};

export { rename_program, rename_program_x };
