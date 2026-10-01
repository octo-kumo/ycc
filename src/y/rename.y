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
//
// The C copy in src/c compiles this file, so every construct used here
// needs a twin there (PORTING.md).

def rn_fresh(st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, orig: str) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, name: str } {
    let u = orig + "$" + tostring(st.n);
    let nst = { scopes: st.scopes, n: st.n + 1, tys: st.tys, dfl: st.dfl };
    { st: nst, name: u }
};

def rn_push(st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] } {
    st.scopes += [[]];
    let scopes = st.scopes;
    { scopes: scopes, n: st.n, tys: st.tys, dfl: st.dfl }
};

def rn_pop(st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] } {
    let scopes = [];
    let old = st.scopes;
    let i = 0;
    while (i < len(old) - 1) {
        scopes += [old[i]];
        i = i + 1;
    };
    { scopes: scopes, n: st.n, tys: st.tys, dfl: st.dfl }
};

def rn_define(st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, orig: str, uniq: str) -> { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] } {
    let scopes = st.scopes;
    let top = scopes[len(scopes) - 1];
    top += { orig: orig, uniq: uniq };
    scopes[len(scopes) - 1] = top;
    { scopes: scopes, n: st.n, tys: st.tys, dfl: st.dfl }
};

def rn_lookup(st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, name: str) -> str {
    // Innermost scope first; within a frame, the NEWEST binding wins
    // (a later let shadows an earlier one).
    let all = st.scopes;
    let i = len(all) - 1;
    let found = "";
    while (i >= 0) {
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
def rn_bind(st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, orig: str) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, uniq: str } {
    let r = rn_fresh(st, orig);
    st = rn_define(r.st, orig, r.name);
    { st: st, uniq: r.name }
};

def rn_list(nodes: [{k: str}], st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, nodes: [{k: str}] } {
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

def rn_id(st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, name: str, line: long, col: long) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let u = rn_lookup(st, name);
    if (u == "") {
        { st: st, node: { k: "id", v: name, line: line, col: col } }
    } else {
        { st: st, node: { k: "id", v: u, line: line, col: col } }
    }
};

// Pre-bind all def names (named defs + let-bound anonymous defs) in a
// statement list so mutual recursion resolves.
def rn_prepass(stmts: [{k: str}], st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] } {
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

def rn_prepass_one(s, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] } {
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

def rn_prepass_decl(s, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] } {
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
def rn_note_defaults(st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, uniq: str, func) -> { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] } {
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
def rn_find_defaults(st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, name: str) -> [{k: str}] {
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
// arity mismatch as usual).
def rn_fill_defaults(vals: [{k: str}], args: [{k: str}]) -> [{k: str}] {
    let n = len(args);
    if (n >= len(vals)) {
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
        if (ok) {
            let out: [{k: str}] = [];
            out += args;
            let j = n;
            while (j < len(vals)) {
                out += vals[j];
                j = j + 1;
            };
            out
        } else {
            args
        }
    }
};

// ── type aliases ─────────────────────────────────────────────────────────
// `type A = T` makes the name A stand for T in every annotation (and match
// pattern) seen AFTER it. Resolution rewrites the type nodes, so the checker
// and emitter never see an alias. A union's members are flattened (an alias
// of a union inside a union adds its members). NOTE: `tys` is never popped,
// so an alias declared inside a block stays visible for the rest of the
// traversal, siblings included — the alias table is not scoped like names.

def rn_type(st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, t) -> {k: str} {
    if (len(st.tys) == 0) { t } else { rn_type_go(st, t, 0) }
};

def rn_types(st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, ts: [{k: str}]) -> [{k: str}] {
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

def rn_type_go(st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, t, depth: long) -> {k: str} {
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

def rn_type_name(st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, name: str, t, depth: long) -> {k: str} {
    let tys = st.tys;
    let i = len(tys) - 1;
    let found = -1;
    while (i >= 0) {
        let e = tys[i];
        if (e.name == name) { found = i; i = -1; 0 };
        i = i - 1;
    };
    // (depth bounds a cyclic alias: `type L = {next: L?}` stops growing at
    // depth 32 and leaves the innermost name a tname, which tcompat unifies
    // with anything — so the alias resolves, it just does not recurse.)
    if (found < 0 || depth > 32) {
        t
    } else {
        let e = tys[found];
        rn_type_go(st, e.typ, depth + 1)
    }
};

def rn_type_list(st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, ts: [{k: str}], depth: long) -> [{k: str}] {
    let out: [{k: str}] = [];
    let i = 0;
    while (i < len(ts)) {
        out += rn_type_go(st, ts[i], depth);
        i = i + 1;
    };
    out
};

def rn_type_fields(st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, fs: [{ name: str, typ: {k: str} }], depth: long) -> [{ name: str, typ: {k: str} }] {
    let out: [{ name: str, typ: {k: str} }] = [];
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

def rn_drop_typedefs(stmts: [{k: str}], st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> [{k: str}] {
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

def rn_typedef_err(s, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> {k: str} {
    let un = rn_unknown_type(st, s.typ);
    if (un == "") { rn_tn({ k: "void" }) } else { rn_unknown_err(un, s.line, s.col) }
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
def rn_unknown_type(st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, t) -> str {
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
def rn_alias_known(tys: [{ name: str, typ: { k: str } }], name: str) -> str {
    let found = false;
    foreach (e in tys) {
        if (e.name == name) { found = true; 0; } else { 0; };
    };
    if (found) { "" } else { name }
};

def rn_unknown_then(first: str, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, t) -> str {
    if (first != "") { first } else { rn_unknown_type(st, t) }
};

def rn_unknown_list(st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, ts: [{k: str}]) -> str {
    let out = "";
    foreach (t in ts) {
        if (out == "") { out = rn_unknown_type(st, t); 0; } else { 0; };
    };
    out
};

def rn_unknown_fields(st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, fs: [{ name: str, typ: {k: str} }]) -> str {
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
    let out: [{k: str}] = [];
    let i = 0;
    while (i < len(stmts)) {
        out += rn_shadow_one(stmts[i], stmts, i);
        i = i + 1;
        0
    };
    out
};

def rn_shadow_one(s, stmts: [{k: str}], i: long) -> {k: str} {
    if (s.k == "decl") {
        rn_shadow_decl(s, stmts, i)
    } else {
        s
    }
};

def rn_shadow_decl(s, stmts: [{k: str}], i: long) -> {k: str} {
    // NOTE: one `s.v.k` read per body (see rn_prepass_decl note).
    if (s.kind == "def") {
        rn_shadow_go(s, stmts, i)
    } else if (s.v.k == "func") {
        rn_shadow_go(s, stmts, i)
    } else {
        s
    }
};

def rn_shadow_go(s, stmts: [{k: str}], i: long) -> {k: str} {
    if (rn_redefined_later(stmts, i, s.name)) {
        rn_rebuild_decl(s, s.name + "$shadow" + tostring(i))
    } else {
        s
    }
};

def rn_redefined_later(stmts: [{k: str}], i: long, name: str) -> bool {
    let j = i + 1;
    let found = false;
    while (j < len(stmts)) {
        if (rn_decl_name(stmts[j]) == name) {
            found = true;
            0
        } else { 0; };
        j = j + 1;
        0
    };
    found
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

def rn_block(stmts: [{k: str}], st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, stmts: [{k: str}] } {
    stmts = rn_shadow_dups(stmts);
    st = rn_push(st);
    st = rn_prepass(stmts, st);
    let r = rn_list(rn_drop_typedefs(stmts, st), st);
    st = rn_pop(r.st);
    { st: st, stmts: r.nodes }
};

def rn_node(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
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
def rn_typed_e(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let e = rn_node(node.e, st);
    let un = rn_unknown_type(e.st, node.typ);
    if (un == "") {
        { st: e.st, node: rn_tn({ k: node.k, e: e.node, typ: rn_type(e.st, node.typ), line: node.line, col: node.col }) }
    } else {
        { st: e.st, node: rn_unknown_err(un, node.line, node.col) }
    }
};

def rn_matchend(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let e = rn_node(node.e, st);
    { st: e.st, node: { k: "matchend", e: e.node, cover: rn_types(e.st, node.cover), line: node.line, col: node.col } }
};

def rn_sliceassign(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
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
def rn_un(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let r = rn_node(node.e, st);
    { st: r.st, node: { k: "un", op: node.op, e: r.node, line: node.line, col: node.col } }
};

def rn_addrderef(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let k = node.k;
    let r = rn_node(node.e, st);
    { st: r.st, node: { k: k, e: r.node, line: node.line, col: node.col } }
};

def rn_bin(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let l = rn_node(node.l, st);
    let r = rn_node(node.r, l.st);
    { st: r.st, node: { k: "bin", op: node.op, l: l.node, r: r.node, line: node.line, col: node.col } }
};

def rn_call(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let c = rn_node(node.callee, st);
    let a = rn_list(node.args, c.st);
    let cn = c.node;
    let args = a.nodes;
    if (cn.k == "id") {
        args = rn_fill_defaults(rn_find_defaults(a.st, cn.v), args);
        0
    };
    { st: a.st, node: { k: "call", callee: cn, args: args, line: node.line, col: node.col } }
};

def rn_if(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let c = rn_node(node.cond, st);
    rn_if_then(node, c.node, c.st)
};

def rn_if_then(node, cond: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let tb = rn_block(node.then.stmts, st);
    rn_if_finish(node, cond, tb.stmts, tb.st)
};

def rn_if_finish(node, cond: {k: str}, tstmts: [{k: str}], st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    // NOTE: both arms build the SAME key set (cond/then/els/has_else);
    // els differs (renamed vs passthrough) but both unify — teq holds.
    if (node.has_else) {
        let e = rn_node(node.els, st);
        { st: e.st, node: { k: "if", cond: cond, then: { k: "block", stmts: tstmts, line: node.then.line, col: node.then.col }, els: e.node, has_else: true, line: node.line, col: node.col } }
    } else {
        { st: st, node: { k: "if", cond: cond, then: { k: "block", stmts: tstmts, line: node.then.line, col: node.then.col }, els: node.els, has_else: false, line: node.line, col: node.col } }
    }
};

def rn_while(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let c = rn_node(node.cond, st);
    rn_while_body(node, c.node, c.st)
};

def rn_while_body(node, cond: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let b = rn_block(node.body.stmts, st);
    { st: b.st, node: { k: "while", cond: cond, body: { k: "block", stmts: b.stmts, line: node.body.line, col: node.body.col }, line: node.line, col: node.col } }
};

def rn_blocknode(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let b = rn_block(node.stmts, st);
    { st: b.st, node: { k: "block", stmts: b.stmts, line: node.line, col: node.col } }
};

def rn_assign(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let r = rn_node(node.v, st);
    rn_assign_lookup(node, r.node, r.st)
};

def rn_assign_lookup(node, v: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let u = rn_lookup(st, node.name);
    rn_assign_finish(node, v, u, st)
};

def rn_assign_finish(node, v: {k: str}, u: str, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
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
def rn_incdec(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let r = rn_node(node.tgt, st);
    { st: r.st, node: { k: "incdec", op: node.op, pre: node.pre, tgt: r.node, line: node.line, col: node.col } }
};

def rn_opassign(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let t = rn_node(node.tgt, st);
    let v = rn_node(node.v, t.st);
    { st: v.st, node: { k: "opassign", op: node.op, tgt: t.node, v: v.node, line: node.line, col: node.col } }
};

def rn_store(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let p = rn_node(node.p, st);
    rn_store_val(node, p.node, p.st)
};

def rn_store_val(node, p: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let v = rn_node(node.v, st);
    { st: v.st, node: { k: "store", p: p, v: v.node, line: node.line, col: node.col } }
};

def rn_ret(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let r = rn_node(node.e, st);
    { st: r.st, node: { k: "ret", e: r.node, line: node.line, col: node.col } }
};

def rn_array(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let r = rn_list(node.elems, st);
    { st: r.st, node: { k: "array", elems: r.nodes, line: node.line, col: node.col } }
};

def rn_arrrep(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let r = rn_node(node.v, st);
    { st: r.st, node: { k: "arrrep", v: r.node, n: node.n, line: node.line, col: node.col } }
};

def rn_reclit(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let r = rn_list(node.vals, st);
    { st: r.st, node: { k: "rec", keys: node.keys, vals: r.nodes, line: node.line, col: node.col } }
};

def rn_maplit(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let r = rn_list(node.vals, st);
    { st: r.st, node: { k: "map", keys: node.keys, vals: r.nodes, line: node.line, col: node.col } }
};

def rn_index(node: {k: str, arr: {k: str}, idx: {k: str}}, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let a = rn_node(node.arr, st);
    rn_index_idx(node, a.node, a.st)
};

def rn_index_idx(node, a: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let x = rn_node(node.idx, st);
    { st: x.st, node: { k: "index", arr: a, idx: x.node, line: node.line, col: node.col } }
};

def rn_slice(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let a = rn_node(node.arr, st);
    rn_slice_lo(node, a.node, a.st)
};

def rn_slice_lo(node, a: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let l = rn_node(node.lo, st);
    rn_slice_hi(node, a, l.node, l.st)
};

def rn_slice_hi(node, a: {k: str}, lo: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let h = rn_node(node.hi, st);
    { st: h.st, node: { k: "slice", arr: a, lo: lo, hi: h.node, line: node.line, col: node.col } }
};

def rn_dot(node: {k: str, obj: {k: str}, key: str, line: long, col: long}, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let o = rn_node(node.obj, st);
    { st: o.st, node: { k: "dot", obj: o.node, key: node.key, line: node.line, col: node.col } }
};

def rn_idxassign(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let a = rn_node(node.arr, st);
    rn_idxassign_idx(node, a.node, a.st)
};

def rn_idxassign_idx(node, a: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let x = rn_node(node.idx, st);
    rn_idxassign_val(node, a, x.node, x.st)
};

def rn_idxassign_val(node, a: {k: str}, idx: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let v = rn_node(node.v, st);
    { st: v.st, node: { k: "idxassign", arr: a, idx: idx, v: v.node, line: node.line, col: node.col } }
};

def rn_dotassign(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let o = rn_node(node.obj, st);
    rn_dotassign_val(node, o.node, o.st)
};

def rn_dotassign_val(node, o: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let v = rn_node(node.v, st);
    { st: v.st, node: { k: "dotassign", obj: o, key: node.key, v: v.node, line: node.line, col: node.col } }
};

def rn_foreach(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let it = rn_node(node.iter, st);
    rn_foreach_body(node, it.node, it.st)
};

def rn_foreach_body(node, iter: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let st1 = rn_push(st);
    let nb = rn_bind(st1, node.name);
    rn_foreach_block(node, iter, nb.uniq, nb.st)
};

def rn_foreach_block(node, iter: {k: str}, uniq: str, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let b = rn_block(node.body.stmts, st);
    let st2 = rn_pop(b.st);
    { st: st2, node: { k: "foreach", name: uniq, iter: iter, body: { k: "block", stmts: b.stmts, line: node.body.line, col: node.body.col }, line: node.line, col: node.col } }
};

def rn_forrange(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let l = rn_node(node.lo, st);
    rn_forrange_hi(node, l.node, l.st)
};

def rn_forrange_hi(node, lo: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let h = rn_node(node.hi, st);
    rn_forrange_body(node, lo, h.node, h.st)
};

def rn_forrange_body(node, lo: {k: str}, hi: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let st1 = rn_push(st);
    let nb = rn_bind(st1, node.name);
    rn_forrange_block(node, lo, hi, nb.uniq, nb.st)
};

def rn_forrange_block(node, lo: {k: str}, hi: {k: str}, uniq: str, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let b = rn_block(node.body.stmts, st);
    let st2 = rn_pop(b.st);
    { st: st2, node: { k: "forrange", name: uniq, lo: lo, hi: hi, body: { k: "block", stmts: b.stmts, line: node.body.line, col: node.body.col }, line: node.line, col: node.col } }
};

def rn_for(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let ri = rn_node(node.init, st);
    rn_for_cond(node, ri.node, ri.st)
};

def rn_for_cond(node, init: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let rc = rn_node(node.cond, st);
    rn_for_step(node, init, rc.node, rc.st)
};

def rn_for_step(node, init: {k: str}, cond: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let rs = rn_node(node.step, st);
    rn_for_body(node, init, cond, rs.node, rs.st)
};

def rn_for_body(node, init: {k: str}, cond: {k: str}, step: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let b = rn_block(node.body.stmts, st);
    { st: b.st, node: { k: "for", init: init, cond: cond, step: step, body: { k: "block", stmts: b.stmts, line: node.body.line, col: node.body.col }, line: node.line, col: node.col } }
};

def rn_decl(node: {k: str, kind: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    // NOTE: dispatch by shape into dedicated callees (see rn_node note):
    // named-def vs let-bound-func vs plain value — each body reads ONLY
    // its own shape's fields.
    if (node.kind == "def") {
        rn_decl_def(node, st)
    } else {
        rn_decl_rest(node, st)
    }
};

def rn_decl_def(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    // name pre-bound by rn_prepass; look it up (the empty arm below is a
    // fallback for a decl that never went through the prepass)
    rn_decl_def_lookup(node, rn_lookup(st, node.name), st)
};

def rn_decl_def_lookup(node, u: str, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    // NOTE: both arms share the key set (kind/def/name/v) — teq holds.
    if (u == "") {
        let b = rn_bind(st, node.name);
        rn_decl_def_go(node, b.uniq, b.st)
    } else {
        rn_decl_def_go(node, u, st)
    }
};

def rn_decl_def_go(node, u: str, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let f = rn_func(node.v, st);
    { st: f.st, node: { k: "decl", kind: "def", name: u, v: f.node, line: node.line, col: node.col } }
};

def rn_decl_rest(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    if (node.v.k == "func") {
        rn_decl_func(node, st)
    } else {
        rn_decl_val(node, st)
    }
};

def rn_decl_func(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    rn_decl_func_lookup(node, rn_lookup(st, node.name), st)
};

def rn_decl_func_lookup(node, u: str, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    // NOTE: both arms share the key set — teq holds.
    if (u == "") {
        let b = rn_bind(st, node.name);
        rn_decl_func_go(node, b.uniq, b.st)
    } else {
        rn_decl_func_go(node, u, st)
    }
};

def rn_decl_func_go(node, u: str, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let f = rn_func(node.v, st);
    rn_decl_func_finish(node, u, f.node, f.st)
};

def rn_decl_func_finish(node, u: str, fv: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    { st: st, node: { k: "decl", kind: node.kind, name: u, typ: rn_type(st, node.typ), v: fv, line: node.line, col: node.col } }
};

def rn_decl_val(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let r = rn_node(node.v, st);
    rn_decl_val_bind(node, r.node, r.st)
};

def rn_decl_val_bind(node, v: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    let b = rn_bind(st, node.name);
    rn_decl_val_finish(node, v, b.uniq, b.st)
};

def rn_decl_val_finish(node, v: {k: str}, uniq: str, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
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

// Rename a func value. `func` is annotated with the full func shape, so its
// fields type-check against that shape; the rn_func_p* chain exists to pass
// each one on as a plain VALUE (params/ptypes/ret/body/line/col) so no callee
// carries a body full of `func.x` reads — rn_func_p4 is the one place with
// two, the two longs.
def rn_func(func: {k: str, params: [{k: str}], ptypes: [{k: str}], ret: {k: str}, body: {k: str}, line: long, col: long}, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    rn_func_p1(func, func.params, rn_push(st))
};

def rn_func_p1(func: {k: str, params: [{k: str}], ptypes: [{k: str}], ret: {k: str}, body: {k: str}, line: long, col: long}, fparams, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    rn_func_p2(func, fparams, func.ptypes, st)
};

def rn_func_p2(func: {k: str, params: [{k: str}], ptypes: [{k: str}], ret: {k: str}, body: {k: str}, line: long, col: long}, fparams, fptypes, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    rn_func_p3(func, fparams, fptypes, func.ret, st)
};

def rn_func_p3(func: {k: str, params: [{k: str}], ptypes: [{k: str}], ret: {k: str}, body: {k: str}, line: long, col: long}, fparams, fptypes, fret, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    rn_func_p4(func, fparams, fptypes, fret, func.body, st)
};

def rn_func_p4(func: {k: str, params: [{k: str}], ptypes: [{k: str}], ret: {k: str}, body: {k: str}, line: long, col: long}, fparams, fptypes, fret, fbody, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    rn_func_p5(fparams, fptypes, fret, fbody, func.line, func.col, st)
};

def rn_func_p5(fparams, fptypes, fret, fbody, fline: long, fcol: long, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    rn_func_params(fparams, fptypes, fret, fbody, fline, fcol, st)
};

def rn_func_params(fparams, fptypes, fret, fbody, fline: long, fcol: long, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    rn_func_go(fparams, fptypes, fret, fbody, fline, fcol, [], 0, st)
};

def rn_func_go(fparams, fptypes, fret, fbody, fline: long, fcol: long, params: [str], i: long, st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
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

def rn_func_body(fptypes, fret, fbody: {k: str, stmts: [{k: str}]}, fline: long, fcol: long, params: [str], st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
    // NOTE: fbody read ONCE here (one read site — no merge).
    let b = rn_block(fbody.stmts, st);
    rn_func_finish(fptypes, fret, fbody, fline, fcol, params, b.stmts, rn_pop(b.st))
};

def rn_func_finish(fptypes, fret, fbody, fline: long, fcol: long, params: [str], stmts: [{k: str}], st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long, tys: [{ name: str, typ: { k: str } }], dfl: [{ name: str, vals: [{ k: str }] }] }, node: {k: str} } {
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
    rename_program_go(ast.stmts, ast.line, ast.col)
};

def rename_program_go(stmts: [{k: str}], line: long, col: long) -> {k: str} {
    // NOTE: fields passed as values (see rn_func note).
    let st = { scopes: [[]], n: 1, tys: [], dfl: [] };
    let b = rn_block(stmts, st);
    { k: "block", stmts: b.stmts, line: line, col: col }
};

export { rename_program };
