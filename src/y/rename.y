// rename.y — static name resolution (uniquify) for the native pipeline.
// rename_program(ast) -> ast' where every binding has a globally unique
// name (`orig$N`; `$` is lexer-illegal, so generated names can never collide
// with user code). After this pass there is no shadowing and no scopes for
// later passes to resolve: types.y keeps one flat map + a function-depth
// counter (for the capture law), native.y keeps one flat env.
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
// Portable-subset Y only (runs inside ycc on the C toolchain).

def rn_fresh(st: { scopes: [[{ orig: str, uniq: str }]], n: long }, orig: str) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, name: str } {
    let u = orig + "$" + tostring(st.n);
    let nst = { scopes: st.scopes, n: st.n + 1 };
    { st: nst, name: u }
};

def rn_push(st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { scopes: [[{ orig: str, uniq: str }]], n: long } {
    st.scopes += [[]];
    let scopes = st.scopes
    { scopes: scopes, n: st.n }
};

def rn_pop(st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { scopes: [[{ orig: str, uniq: str }]], n: long } {
    let scopes = [];
    let old = st.scopes;
    let i = 0;
    while (i < len(old) - 1) {
        scopes += [old[i]];
        i = i + 1;
    };
    { scopes: scopes, n: st.n }
};

def rn_define(st: { scopes: [[{ orig: str, uniq: str }]], n: long }, orig: str, uniq: str) -> { scopes: [[{ orig: str, uniq: str }]], n: long } {
    let scopes = st.scopes;
    let top = scopes[len(scopes) - 1];
    top += { orig: orig, uniq: uniq };
    scopes[len(scopes) - 1] = top;
    { scopes: scopes, n: st.n }
};

def rn_lookup(st: { scopes: [[{ orig: str, uniq: str }]], n: long }, name: str) -> str {
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
            } else { 0 };
            j = j - 1;
            0
        };
        i = i - 1;
        0
    };
    found
};

// Bind one name in the current scope, return {st, uniq}.
def rn_bind(st: { scopes: [[{ orig: str, uniq: str }]], n: long }, orig: str) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, uniq: str } {
    let r = rn_fresh(st, orig);
    st = rn_define(r.st, orig, r.name);
    { st: st, uniq: r.name }
};

def rn_list(nodes: [{k: str}], st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, nodes: [{k: str}] } {
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

def rn_id(st: { scopes: [[{ orig: str, uniq: str }]], n: long }, name: str, line: long, col: long) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let u = rn_lookup(st, name);
    if (u == "") {
        { st: st, node: { k: "id", v: name, line: line, col: col } }
    } else {
        { st: st, node: { k: "id", v: u, line: line, col: col } }
    }
};

// Pre-bind all def names (named defs + let-bound anonymous defs) in a
// statement list so mutual recursion resolves.
def rn_prepass(stmts: [{k: str}], st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { scopes: [[{ orig: str, uniq: str }]], n: long } {
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

def rn_prepass_one(s, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { scopes: [[{ orig: str, uniq: str }]], n: long } {
    if (s.k == "decl") {
        rn_prepass_decl(s, st)
    } else {
        st
    }
};

def rn_prepass_decl(s, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { scopes: [[{ orig: str, uniq: str }]], n: long } {
    // decl shapes only (named def vs let-bound func): one `s.v.k` read in
    // this body (see parse_type_arrow note — two reads in one body merge).
    if (s.kind == "def") {
        let r = rn_bind(st, s.name);
        r.st
    } else if (s.v.k == "func") {
        let r = rn_bind(st, s.name);
        r.st
    } else {
        st
    }
};

// Redefinition shadows, exactly as it does in the VM: `def f ... def f ...`
// keeps the LAST definition, and every reference (before or after, since
// defs hoist) binds to it. rename.y resolves def names through the prepass
// binding, so two same-named defs would otherwise collapse onto one unique
// name; give the earlier ones a dead name instead. They are still checked
// and emitted — only unreachable.
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

def rn_block(stmts: [{k: str}], st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, stmts: [{k: str}] } {
    stmts = rn_shadow_dups(stmts);
    st = rn_push(st);
    st = rn_prepass(stmts, st);
    let r = rn_list(stmts, st);
    st = rn_pop(r.st);
    { st: st, stmts: r.nodes }
};

def rn_node(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    // NOTE: dispatch WITHOUT a shared-shape if-chain (see parser.y
    // parse_type_arrow note): a 25-arm chain on one name merges every arm's
    // node shape through the flow-insensitive env (each arm's return type
    // must teq ALL others). Each arm here is a SINGLE callee call (or leaf
    // literal) with the uniform return type R, so arms always agree.
    // Leaf shapes (num/str/bool/null) return the node untouched.
    let k = node.k;
    if (k == "num") {
        { st: st, node: node }
    } else if (k == "str") {
        { st: st, node: node }
    } else if (k == "bstr") {
        { st: st, node: node }
    } else if (k == "bool") {
        { st: st, node: node }
    } else if (k == "null") {
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
    } else {
        { st: st, node: node }
    }
};

// One def per AST shape (see rn_node note). Each takes the bare node hole
// (param name `node` is exempt from annotation, like parser.y res) plus the
// annotated scope state, and returns the uniform R. Field reads off the
// bare hole unify quietly via the tcompat law (tnone); each body reads
// ONLY its own shape's fields.
def rn_un(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let r = rn_node(node.e, st);
    { st: r.st, node: { k: "un", op: node.op, e: r.node, line: node.line, col: node.col } }
};

def rn_addrderef(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let k = node.k;
    let r = rn_node(node.e, st);
    { st: r.st, node: { k: k, e: r.node, line: node.line, col: node.col } }
};

def rn_bin(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let l = rn_node(node.l, st);
    let r = rn_node(node.r, l.st);
    { st: r.st, node: { k: "bin", op: node.op, l: l.node, r: r.node, line: node.line, col: node.col } }
};

def rn_call(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let c = rn_node(node.callee, st);
    let a = rn_list(node.args, c.st);
    { st: a.st, node: { k: "call", callee: c.node, args: a.nodes, line: node.line, col: node.col } }
};

def rn_if(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let c = rn_node(node.cond, st);
    rn_if_then(node, c.node, c.st)
};

def rn_if_then(node, cond: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let tb = rn_block(node.then.stmts, st);
    rn_if_finish(node, cond, tb.stmts, tb.st)
};

def rn_if_finish(node, cond: {k: str}, tstmts: [{k: str}], st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    // NOTE: both arms build the SAME key set (cond/then/els/has_else);
    // els differs (renamed vs passthrough) but both unify — teq holds.
    // NOTE: `0;` tails on bare-ifs (see parser.y parse_binary note).
    if (node.has_else) {
        let e = rn_node(node.els, st);
        { st: e.st, node: { k: "if", cond: cond, then: { k: "block", stmts: tstmts, line: node.then.line, col: node.then.col }, els: e.node, has_else: true, line: node.line, col: node.col } }
    } else {
        { st: st, node: { k: "if", cond: cond, then: { k: "block", stmts: tstmts, line: node.then.line, col: node.then.col }, els: node.els, has_else: false, line: node.line, col: node.col } }
    }
};

def rn_while(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let c = rn_node(node.cond, st);
    rn_while_body(node, c.node, c.st)
};

def rn_while_body(node, cond: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let b = rn_block(node.body.stmts, st);
    { st: b.st, node: { k: "while", cond: cond, body: { k: "block", stmts: b.stmts, line: node.body.line, col: node.body.col }, line: node.line, col: node.col } }
};

def rn_blocknode(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let b = rn_block(node.stmts, st);
    { st: b.st, node: { k: "block", stmts: b.stmts, line: node.line, col: node.col } }
};

def rn_assign(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let r = rn_node(node.v, st);
    rn_assign_lookup(node, r.node, r.st)
};

def rn_assign_lookup(node, v: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let u = rn_lookup(st, node.name);
    rn_assign_finish(node, v, u, st)
};

def rn_assign_finish(node, v: {k: str}, u: str, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
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
def rn_incdec(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let r = rn_node(node.tgt, st);
    { st: r.st, node: { k: "incdec", op: node.op, pre: node.pre, tgt: r.node, line: node.line, col: node.col } }
};

def rn_opassign(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let t = rn_node(node.tgt, st);
    let v = rn_node(node.v, t.st);
    { st: v.st, node: { k: "opassign", op: node.op, tgt: t.node, v: v.node, line: node.line, col: node.col } }
};

def rn_store(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let p = rn_node(node.p, st);
    rn_store_val(node, p.node, p.st)
};

def rn_store_val(node, p: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let v = rn_node(node.v, st);
    { st: v.st, node: { k: "store", p: p, v: v.node, line: node.line, col: node.col } }
};

def rn_ret(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let r = rn_node(node.e, st);
    { st: r.st, node: { k: "ret", e: r.node, line: node.line, col: node.col } }
};

def rn_array(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let r = rn_list(node.elems, st);
    { st: r.st, node: { k: "array", elems: r.nodes, line: node.line, col: node.col } }
};

def rn_arrrep(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let r = rn_node(node.v, st);
    { st: r.st, node: { k: "arrrep", v: r.node, n: node.n, line: node.line, col: node.col } }
};

def rn_reclit(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let r = rn_list(node.vals, st);
    { st: r.st, node: { k: "rec", keys: node.keys, vals: r.nodes, line: node.line, col: node.col } }
};

def rn_index(node: {k: str, arr: {k: str}, idx: {k: str}}, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let a = rn_node(node.arr, st);
    rn_index_idx(node, a.node, a.st)
};

def rn_index_idx(node, a: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let x = rn_node(node.idx, st);
    { st: x.st, node: { k: "index", arr: a, idx: x.node, line: node.line, col: node.col } }
};

def rn_slice(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let a = rn_node(node.arr, st);
    rn_slice_lo(node, a.node, a.st)
};

def rn_slice_lo(node, a: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let l = rn_node(node.lo, st);
    rn_slice_hi(node, a, l.node, l.st)
};

def rn_slice_hi(node, a: {k: str}, lo: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let h = rn_node(node.hi, st);
    { st: h.st, node: { k: "slice", arr: a, lo: lo, hi: h.node, line: node.line, col: node.col } }
};

def rn_dot(node: {k: str, obj: {k: str}, key: str, line: long, col: long}, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let o = rn_node(node.obj, st);
    { st: o.st, node: { k: "dot", obj: o.node, key: node.key, line: node.line, col: node.col } }
};

def rn_idxassign(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let a = rn_node(node.arr, st);
    rn_idxassign_idx(node, a.node, a.st)
};

def rn_idxassign_idx(node, a: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let x = rn_node(node.idx, st);
    rn_idxassign_val(node, a, x.node, x.st)
};

def rn_idxassign_val(node, a: {k: str}, idx: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let v = rn_node(node.v, st);
    { st: v.st, node: { k: "idxassign", arr: a, idx: idx, v: v.node, line: node.line, col: node.col } }
};

def rn_dotassign(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let o = rn_node(node.obj, st);
    rn_dotassign_val(node, o.node, o.st)
};

def rn_dotassign_val(node, o: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let v = rn_node(node.v, st);
    { st: v.st, node: { k: "dotassign", obj: o, key: node.key, v: v.node, line: node.line, col: node.col } }
};

def rn_foreach(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let it = rn_node(node.iter, st);
    rn_foreach_body(node, it.node, it.st)
};

def rn_foreach_body(node, iter: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let st1 = rn_push(st);
    let nb = rn_bind(st1, node.name);
    rn_foreach_block(node, iter, nb.uniq, nb.st)
};

def rn_foreach_block(node, iter: {k: str}, uniq: str, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let b = rn_block(node.body.stmts, st);
    let st2 = rn_pop(b.st);
    { st: st2, node: { k: "foreach", name: uniq, iter: iter, body: { k: "block", stmts: b.stmts, line: node.body.line, col: node.body.col }, line: node.line, col: node.col } }
};

def rn_forrange(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let l = rn_node(node.lo, st);
    rn_forrange_hi(node, l.node, l.st)
};

def rn_forrange_hi(node, lo: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let h = rn_node(node.hi, st);
    rn_forrange_body(node, lo, h.node, h.st)
};

def rn_forrange_body(node, lo: {k: str}, hi: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let st1 = rn_push(st);
    let nb = rn_bind(st1, node.name);
    rn_forrange_block(node, lo, hi, nb.uniq, nb.st)
};

def rn_forrange_block(node, lo: {k: str}, hi: {k: str}, uniq: str, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let b = rn_block(node.body.stmts, st);
    let st2 = rn_pop(b.st);
    { st: st2, node: { k: "forrange", name: uniq, lo: lo, hi: hi, body: { k: "block", stmts: b.stmts, line: node.body.line, col: node.body.col }, line: node.line, col: node.col } }
};

def rn_for(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let ri = rn_node(node.init, st);
    rn_for_cond(node, ri.node, ri.st)
};

def rn_for_cond(node, init: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let rc = rn_node(node.cond, st);
    rn_for_step(node, init, rc.node, rc.st)
};

def rn_for_step(node, init: {k: str}, cond: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let rs = rn_node(node.step, st);
    rn_for_body(node, init, cond, rs.node, rs.st)
};

def rn_for_body(node, init: {k: str}, cond: {k: str}, step: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let b = rn_block(node.body.stmts, st);
    { st: b.st, node: { k: "for", init: init, cond: cond, step: step, body: { k: "block", stmts: b.stmts, line: node.body.line, col: node.body.col }, line: node.line, col: node.col } }
};

def rn_decl(node: {k: str, kind: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    // NOTE: dispatch by shape into dedicated callees (see rn_node note):
    // named-def vs let-bound-func vs plain value — each body reads ONLY
    // its own shape's fields.
    if (node.kind == "def") {
        rn_decl_def(node, st)
    } else {
        rn_decl_rest(node, st)
    }
};

def rn_decl_def(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    // name pre-bound by rn_prepass; look it up (must exist)
    rn_decl_def_lookup(node, rn_lookup(st, node.name), st)
};

def rn_decl_def_lookup(node, u: str, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    // NOTE: both arms share the key set (kind/def/name/v) — teq holds.
    if (u == "") {
        let b = rn_bind(st, node.name);
        rn_decl_def_go(node, b.uniq, b.st)
    } else {
        rn_decl_def_go(node, u, st)
    }
};

def rn_decl_def_go(node, u: str, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let f = rn_func(node.v, st);
    { st: f.st, node: { k: "decl", kind: "def", name: u, v: f.node, line: node.line, col: node.col } }
};

def rn_decl_rest(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    if (node.v.k == "func") {
        rn_decl_func(node, st)
    } else {
        rn_decl_val(node, st)
    }
};

def rn_decl_func(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    rn_decl_func_lookup(node, rn_lookup(st, node.name), st)
};

def rn_decl_func_lookup(node, u: str, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    // NOTE: both arms share the key set — teq holds.
    if (u == "") {
        let b = rn_bind(st, node.name);
        rn_decl_func_go(node, b.uniq, b.st)
    } else {
        rn_decl_func_go(node, u, st)
    }
};

def rn_decl_func_go(node, u: str, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let f = rn_func(node.v, st);
    rn_decl_func_finish(node, u, f.node, f.st)
};

def rn_decl_func_finish(node, u: str, fv: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    { st: st, node: { k: "decl", kind: node.kind, name: u, typ: node.typ, v: fv, line: node.line, col: node.col } }
};

def rn_decl_val(node, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let r = rn_node(node.v, st);
    rn_decl_val_bind(node, r.node, r.st)
};

def rn_decl_val_bind(node, v: {k: str}, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    let b = rn_bind(st, node.name);
    rn_decl_val_finish(node, v, b.uniq, b.st)
};

def rn_decl_val_finish(node, v: {k: str}, uniq: str, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    { st: st, node: { k: "decl", kind: node.kind, name: uniq, typ: node.typ, v: v, line: node.line, col: node.col } }
};

// Rename a func value. The func VALUE (params/ptypes/ret/body) is passed
// as FIELDS (like parse_stmt_*_go): the checker merges same-named param
// reads across defs, so reading func.params/func.body off a shared `func`
// name resolves against every func-shaped call site at once. Fields are
// plain values (params/pts/ret/body passed separately — no record reads).
def rn_func(func: {k: str, params: [{k: str}], ptypes: [{k: str}], ret: {k: str}, body: {k: str}, line: long, col: long}, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    // NOTE: ONE field read per callee (see note above): rn_func_p* chain
    // threads the fields as VALUES; no body reads 2+ fields off `func`.
    rn_func_p1(func, func.params, rn_push(st))
};

def rn_func_p1(func: {k: str, params: [{k: str}], ptypes: [{k: str}], ret: {k: str}, body: {k: str}, line: long, col: long}, fparams, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    rn_func_p2(func, fparams, func.ptypes, st)
};

def rn_func_p2(func: {k: str, params: [{k: str}], ptypes: [{k: str}], ret: {k: str}, body: {k: str}, line: long, col: long}, fparams, fptypes, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    rn_func_p3(func, fparams, fptypes, func.ret, st)
};

def rn_func_p3(func: {k: str, params: [{k: str}], ptypes: [{k: str}], ret: {k: str}, body: {k: str}, line: long, col: long}, fparams, fptypes, fret, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    rn_func_p4(func, fparams, fptypes, fret, func.body, st)
};

def rn_func_p4(func: {k: str, params: [{k: str}], ptypes: [{k: str}], ret: {k: str}, body: {k: str}, line: long, col: long}, fparams, fptypes, fret, fbody, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    rn_func_p5(fparams, fptypes, fret, fbody, func.line, func.col, st)
};

def rn_func_p5(fparams, fptypes, fret, fbody, fline: long, fcol: long, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    rn_func_params(fparams, fptypes, fret, fbody, fline, fcol, st)
};

def rn_func_params(fparams, fptypes, fret, fbody, fline: long, fcol: long, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    rn_func_go(fparams, fptypes, fret, fbody, fline, fcol, [], 0, st)
};

def rn_func_go(fparams, fptypes, fret, fbody, fline: long, fcol: long, params: [str], i: long, st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
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

def rn_func_body(fptypes, fret, fbody: {k: str, stmts: [{k: str}]}, fline: long, fcol: long, params: [str], st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    // NOTE: fbody read ONCE here (one read site — no merge).
    let b = rn_block(fbody.stmts, st);
    rn_func_finish(fptypes, fret, fbody, fline, fcol, params, b.stmts, rn_pop(b.st))
};

def rn_func_finish(fptypes, fret, fbody, fline: long, fcol: long, params: [str], stmts: [{k: str}], st: { scopes: [[{ orig: str, uniq: str }]], n: long }) -> { st: { scopes: [[{ orig: str, uniq: str }]], n: long }, node: {k: str} } {
    // NOTE: NO record reads here — all values are params already.
    { st: st, node: { k: "func", params: params, ptypes: fptypes, ret: fret, body: { k: "block", stmts: stmts, line: fline, col: fcol }, line: fline, col: fcol } }
};



def rename_program(ast) -> {k: str} {
    rename_program_go(ast.stmts, ast.line, ast.col)
};

def rename_program_go(stmts: [{k: str}], line: long, col: long) -> {k: str} {
    // NOTE: fields passed as values (see rn_func note).
    let st = { scopes: [[]], n: 1 };
    let b = rn_block(stmts, st);
    { k: "block", stmts: b.stmts, line: line, col: col }
};

export { rename_program };
