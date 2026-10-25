// rename.y — static name resolution (uniquify) for the native pipeline.

// For its AST and type aliases.
import tags from "./tags.y";
import parser from "./parser.y";
import rnshapes from "./rn_shapes.y";

// The renamer's state: the scopes, innermost last, each binding names
// to their unique names; n, the counter behind the `$N` suffixes; tys,
// the type aliases (rn_prepass_one); dfl, the default parameter values
// of the defs, by unique name (rn_note_defaults).
type Dfl = { name: str, vals: [Node] };
type RnBind = { orig: str, uniq: str };
type RnSt = { scopes: [[RnBind]], n: long, tys: [Field], dfl: [Dfl] };

let rn_types_seed: [Field] = [];
let rn_types_out: [Field] = [];

def rn_types_seed_set(xs: [Field]) {
    rn_types_seed = xs;
};

def rn_types_out_get() -> [Field] {
    rn_types_out
};
type RnRes = { st: RnSt, node: Node };
type RnStmts = { st: RnSt, stmts: [Node] };

// The modules imported by name (rename_program_x): each line's file
// (native.y's origin map), each file's module ("" for the program's own
// files), the module names, and the module of the top-level statement
// being renamed ("" for the program's own code).
let rn_ofile: [long] = [];
let rn_fmods: [str] = [];
let rn_mods: [str] = [];
// The aliases modules declare at their top level, as `m.T` (rn_top).
let rn_mod_types: [str] = [];
let rn_mod = "";

def rn_fresh(st: RnSt, orig: str) -> { st: RnSt, name: str } {
    { st: ({ scopes: st.scopes, n: st.n + 1, tys: st.tys, dfl: st.dfl }), name: (orig + "$" + tostring(st.n)) }
};

def rn_push(st: RnSt) -> RnSt {
    st.scopes += [[]];
    let scopes: [[RnBind]] = st.scopes;
    {...st, scopes: scopes}
};

// Copy the retained scope stack: nested renames may still share the old frames.
def rn_pop(st: RnSt) -> RnSt {
    let old = st.scopes;
    let scopes: [[RnBind]] = old[0:len(old) - 1];
    {...st, scopes: scopes}
};

def rn_define(st: RnSt, orig: str, uniq: str) -> RnSt {
    let scopes = st.scopes;
    let top = scopes[len(scopes) - 1];
    top += { orig: orig, uniq: uniq };
    scopes[len(scopes) - 1] = top;
    {...st, scopes: scopes}
};

def rn_lookup(st: RnSt, name: str) -> str {
    if (rn_mod == "") {
        rn_lookup_to(st, name, 0)
    } else {
        // a module's code: its locals (frames 2 up: 0 is empty, 1 holds
        // the top level), then its own top-level names, then the rest
        let u = rn_lookup_to(st, name, 2);
        if (u == "") { u = rn_lookup_to(st, rn_mod + "." + name, 1); }
        if (u == "") { u = rn_lookup_to(st, name, 0); }
        u
    }
};

let rn_ix: NameIx = parser.nameix_new(8);
let rn_ixn = 0;

// rn_lookup in the frames from the innermost down to frame `lo`.
def rn_lookup_to(st: RnSt, name: str, lo: long) -> str {
    let i = len(st.scopes) - 1;
    while (i >= lo) {
        let frame = st.scopes[i];
        if (i == 1 && len(frame) > 256 && name != "") {
            if (rn_ixn == 0) { rn_ix = parser.nameix_new(1024); };
            while (rn_ixn < len(frame)) {
                let b = frame[rn_ixn];
                if (b.orig != "") { parser.nameix_put(rn_ix, b.orig, rn_ixn); };
                rn_ixn++;
            };
            let at = parser.nameix_get(rn_ix, name);
            if (at >= 0) { return frame[at].uniq; };
        } else {
            let j = len(frame) - 1;
            while (j >= 0) {
                if (frame[j].orig == name) { return frame[j].uniq; };
                j--;
            };
        };
        i--;
    };
    ""
};

// ── the def sites ────────────────────────────────────────────────────────
let rn_defs: NameIx = parser.nameix_new(1024);
let rn_want_defs: bool = false;

// The name's position, or none. -1 is the sentinel and a consumer must treat it
// as "no site in the source", never as line -1.
def rn_def_site(uniq: str) -> long {
    let out = -1;
    if (rn_want_defs) {
        let packed = parser.nameix_get(rn_defs, uniq);
        if (packed >= 0) { out = packed; };
    };
    out
}

// The line of a def site, and its column. Two readers rather than one tuple so
// the packing stays private to this file.
def rn_def_line(st: long) -> long { st / 65536 }
def rn_def_col(st: long) -> long { st % 65536 }

// Only ever called when rn_want_defs is set: the flag is tested at rn_bind's
// call site, for the same reason as tci_note -- a call on the path of every
// binding in every compile is the cost, not the work inside it.
def rn_note_def(uniq: str, line: long, col: long) -> void {
    if (line > 0 && col >= 0) {
        parser.nameix_put(rn_defs, uniq, line * 65536 + col);
    };
};

// Bind one name in the current scope, return {st, uniq}.
//
// `line`/`col` are the NAME's, not the keyword's, so they differ from the
// declaration node's own position by however much whitespace followed `let`/`def`.
def rn_bind(st: RnSt, orig: str, line: long, col: long) -> { st: RnSt, uniq: str } {
    let r = rn_fresh(st, orig);
    st = rn_define(r.st, orig, r.name);
    if (rn_want_defs) { rn_note_def(r.name, line, col); };
    { st: st, uniq: r.name }
};

def rn_list(nodes: [Node], st: RnSt) -> { st: RnSt, nodes: [Node] } {
    let out: [Node] = [];
    nodes.foreach((e) => {
        let r = rn_node(e, st);
        st = r.st;
        out += r.node;
    });
    { st: st, nodes: out }
};

def rn_id(st: RnSt, name: str, line: long, col: long) -> RnRes {
    let u = rn_lookup(st, name);
    {st: st, node: {k: K.id, v: u == "" ? name : u, line: line, col: col}}
};

// Pre-bind all def names (named defs + let-bound anonymous defs) in a
// statement list so mutual recursion resolves.
def rn_prepass(stmts: [Node], st: RnSt) -> RnSt {
    // NOTE: stmts elements are bare {k}-holes at the boundary (like res);
    // pass each element as a BARE value (rn_prepass_one takes unannotated
    // s) so field reads resolve via the tcompat law, not merged shapes.
    stmts.foreach((e) => {
        st = rn_prepass_one(e, st);
    });
    st
};

def rn_prepass_one(s: Node, st: RnSt) -> RnSt {
    if (s.k == K.decl) {
        let decl: Decl = s;
        rn_prepass_decl(decl, st)
    } else if (s.k == K.typedef) {
        // aliases hoist like defs: every annotation in the block sees them.
        // A module's are its own: `m.T`, the names of its aliases in T
        // qualified the same way (rn_qual_type).
        let td: TypeDef = s;
        let m = "";
        if (len(rn_mods) > 0) { m = rn_stmt_mod(s); };
        if (m == "") {
            st.tys += { name: td.name, opt: false, typ: td.typ };
        } else {
            st.tys += { name: m + "." + td.name, opt: false, typ: rn_qual_type(td.typ, m) };
        };
        st
    } else {
        st
    }
};

def rn_prepass_decl(s: Decl, st: RnSt) -> RnSt {
    // decl shapes only (named def vs let-bound func): one `s.v.k` read in
    // this body (see parse_type_arrow note — two reads in one body merge).
    if (s.kind == "def") {
        let r = rn_bind(st, s.name, s.nline, s.ncol);
        rn_note_defaults(r.st, r.uniq, s.v)
    } else if (s.v.k == K.func) {
        let r = rn_bind(st, s.name, s.nline, s.ncol);
        rn_note_defaults(r.st, r.uniq, s.v)
    } else {
        st
    }
};

// Remember a def's default parameter values under its unique name, so a
// direct call that leaves trailing arguments out gets them filled in.
def rn_note_defaults(st: RnSt, uniq: str, func: Func) -> RnSt {
    if (func.defs.some((d) => d.k != K.void)) { st.dfl += {name: uniq, vals: func.defs}; };
    st
};

// The defaults of the def a call names ([] for anything else).
def rn_find_defaults(st: RnSt, name: str) -> [Node] {
    let out: [Node] = [];
    st.dfl.foreach((d) => {
        if (d.name == name) { out = d.vals; };
    });
    out
};

// args + the defaults of the missing trailing parameters -- only when
// every one of them has a default (otherwise the checker reports the
// arity mismatch as usual). An optional parameter (`b?: T`, its default
// marked `optarg`) gets some(arg) when the call passes it, none when not.
def rn_fill_defaults(vals: [Node], args: [Node], line: long, col: long) -> [Node] {
    let n = len(args);
    if (len(vals) == 0) {
        args
    } else {
        let ok = true;
        for i in n..len(vals) {
            let dk: long = vals[i].k;
            if (dk == K.void) { ok = false; };
        };
        let out: [Node] = [];
        let j = 0;
        while (j < n) {
            if (j < len(vals) && rn_is_optarg(vals[j])) {
                let one: [Node] = [];
                one += args[j];
                out += { k: K.call, callee: { k: K.id, v: "some", line: line, col: col }, args: one, line: line, col: col };
            } else {
                out += args[j];
            };
            j++;
        };
        if (ok) {
            while (j < len(vals)) {
                if (rn_is_optarg(vals[j])) {
                    out += { k: K.id, v: "none", line: line, col: col };
                } else {
                    out += vals[j];
                };
                j++;
            };
        };
        out
    }
};

def rn_is_optarg(d: Node) -> bool { d.k == K.optarg };

// ── type aliases ─────────────────────────────────────────────────────────
let rn_tref_ids: [long] = [];
let rn_tref_nodes: [TRef] = [];
let rn_reach_memo: [long] = [];
let rn_reach_n = -1;

// t with each name of an alias module m declares at its top level
// written `m.T` (a module's alias is registered under that name).
def rn_qual_type(t: Type, m: str) -> Type {
    if (t.k == K.tname) {
        let name: TName = t;
        let qualified = m + "." + name.name;
        if (qualified in rn_mod_types) {
            let result: Type = { k: K.tname, name: qualified };
            result
        } else { t }
    } else if (t.k == K.tref || t.k == K.tinfer) { t }
    else { type_map_children(t, (child: Type) => rn_qual_type(child, m)) }
};

def rn_type(st: RnSt, t: Type) -> Type {
    if (len(st.tys) == 0) { t } else { rn_type_go(st, t, 0) }
};

def rn_types(st: RnSt, ts: [Type]) -> [Type] {
    if (len(st.tys) == 0) {
        ts
    } else {
        let out: [Type] = [];
        ts.foreach((e) => {
            out += rn_type(st, e);
        });
        out
    }
};

def rn_type_go(st: RnSt, t: Type, depth: long) -> Type {
    if (t.k == K.tname) {
        let name: TName = t;
        return rn_type_name(st, name.name, t, depth);
    };
    if (t.k == K.tref || t.k == K.tinfer) { return t; };
    let mapped = type_map_children(t, (child: Type) => rn_type_go(st, child, depth));
    if (mapped.k == K.tunion) {
        let list: TList = mapped;
        let result: Type = { k: K.tunion, ts: rn_union_flat(list.ts) };
        result
    } else { mapped }
};

def rn_type_name(st: RnSt, name: str, t: Type, depth: long) -> Type {
    let found = rn_alias_index(st, name);
    // (depth only guards against a bug: a recursive alias is a tref, never
    // spelled out inside itself)
    if (found < 0 || depth > 64) {
        t
    } else if (rn_reaches_any(st, found)) {
        rn_tref(st, found, name)
    } else {
        let e: Field = st.tys[found];
        rn_type_go(st, e.typ, depth + 1)
    }
};

// rn_reaches(st, id, false), remembered (rn_reach_memo).
def rn_reaches_any(st: RnSt, id: long) -> bool {
    let n = len(st.tys);
    if (n != rn_reach_n) {
        let fresh: [long] = [];
        for i in 0..n { fresh += 0; };
        rn_reach_memo = fresh;
        rn_reach_n = n;
    };
    if (rn_reach_memo[id] == 0) {
        if (rn_reaches(st, id, false)) { rn_reach_memo[id] = 2; } else { rn_reach_memo[id] = 1; };
    };
    rn_reach_memo[id] == 2
};

// The index in st.tys of the alias `name` stands for (the last declared:
// -1 for none). In a module's code (rn_mod) a bare name is the module's
// own alias first.
def rn_alias_index(st: RnSt, name: str) -> long {
    if (rn_mod != "" && index_of(name, ".") < 0) {
        let own = rn_alias_index_go(st, rn_mod + "." + name);
        if (own >= 0) { return own; };
    };
    rn_alias_index_go(st, name)
};

def rn_alias_index_go(st: RnSt, name: str) -> long {
    let tys = st.tys;
    let i = len(tys) - 1;
    let found = -1;
    while (i >= 0) {
        if (tys[i].name == name) { found = i; i = -1; };
        i = i - 1;
    };
    found
};

// The tref of recursive alias `id`: made, and the alias spelled out into
// it, the first time it is met.
def rn_tref(st: RnSt, id: long, name: str) -> Type {
    let at = -1;
    let i = 0;
    while (at < 0 && i < len(rn_tref_ids)) {
        if (rn_tref_ids[i] == id) { at = i; }
        i++;
    };
    if (at >= 0) {
        rn_tref_nodes[at]
    } else {
        let tref: TRef = { k: K.tref, name: name, tmp: name + "$" + tostring(id), to: { k: K.tnone } };
        rn_tref_ids += id;
        rn_tref_nodes += tref;
        if (rn_reaches(st, id, true)) {
            tref.to = { k: K.tunk };
        } else {
            let e: Field = st.tys[id];
            tref.to = rn_type_go(st, e.typ, 0);
        };
        tref
    }
};

// Alias `id` refers to itself, through other aliases or not -- anywhere
// in it, or (`bare`) outside every record field and function type.
def rn_reaches(st: RnSt, id: long, bare: bool) -> bool {
    let seen: [long] = [];
    rn_reaches_go(st, st.tys[id].typ, id, seen, bare)
};

def rn_reaches_go(st: RnSt, t: Type, id: long, seen: [long], bare: bool) -> bool {
    let k: long = t.k;
    if (k == K.tname) {
        let name: TName = t;
        let j = rn_alias_index(st, name.name);
        if (j < 0 || j in seen) { false }
        else if (j == id) { true }
        else {
            seen += j;
            rn_reaches_go(st, st.tys[j].typ, id, seen, bare)
        }
    }
    // Containers guard recursive aliases; only unions and parameter lists
    // can carry an unguarded cycle. Already-resolved references are leaves.
    else if (k == K.tref || k == K.tinfer) { false }
    else if (bare && k != K.tparams && k != K.tunion) { false }
    else { type_any_child(t, (child: Type) => rn_reaches_go(st, child, id, seen, bare)) }
};

def rn_union_flat(ts: [Type]) -> [Type] {
    let out: [Type] = [];
    ts.foreach((t) => {
        let tk: long = t.k;
        if (tk == K.tunion) {
            let list: TList = t;
            let inner: [Type] = list.ts;
            out += inner;
        } else {
            out += t;
        };
    });
    out
};

def rn_drop_typedefs(stmts: [Node], st: RnSt) -> [Node] {
    let out: [Node] = [];
    stmts.foreach((s) => {
        let sk: long = s.k;
        if (sk == K.typedef) {
            // Dropped -- unless its type names something undefined.
            let td: TypeDef = s;
            let mod0 = rn_mod;
            if (len(rn_mods) > 0) { rn_mod = rn_stmt_mod(s); };
            let te = rn_typedef_err(td, st);
            rn_mod = mod0;
            if (te.k == K.err) { out += te; }
        } else { out += s; };
    });
    out
};

def rn_typedef_err(s: TypeDef, st: RnSt) -> Node {
    let un = rn_unknown_type(st, s.typ);
    let name: str = s.name;
    let id = rn_alias_index(st, name);
    if (un != "") { rn_unknown_err(un, s.line, s.col) }
    else if (id >= 0 && rn_reaches(st, id, true)) {
        let err: Err = { k: K.err, msg: "type '" + name + "' refers to itself outside any record field, function type, array, option, map or pointer", line: s.line, col: s.col };
        let node: Node = err;
        node
    } else {
        let bare: Bare = { k: K.void, line: s.line, col: s.col };
        let node: Node = bare;
        node
    }
};

// ── unknown type names ───────────────────────────────────────────────────

def rn_unknown_err(name: str, line: long, col: long) -> Node {
    { k: K.err, msg: "unknown type '" + name + "'", line: line, col: col }
};

// The first unknown name in annotation t ("" when every name resolves).
def rn_unknown_type(st: RnSt, t: Type) -> str {
    if (t.k == K.tname) { let name: TName = t; return rn_alias_known(st, name.name); };
    if (t.k == K.tref || t.k == K.tinfer) { return ""; };
    let unknown = "";
    if (type_any_child(t, (child: Type) => {
        unknown = rn_unknown_type(st, child);
        unknown != ""
    })) { unknown } else { "" }
};

// "" when `name` is an alias in scope, else the name itself.
def rn_alias_known(st: RnSt, name: str) -> str {
    if (rn_alias_index(st, name) >= 0) { "" } else { name }
};

def rn_unknown_list(st: RnSt, ts: [Type]) -> str {
    let out = "";
    foreach (t in ts) {
        if (out == "") { out = rn_unknown_type(st, t); }
    };
    out
};

def rn_shadow_dups(stmts: [Node]) -> [Node] {
    let names: [str] = [];
    let ndefs = 0;
    foreach (s in stmts) {
        let nm = rn_decl_name(s);
        names += nm;
        if (nm != "") { ndefs++; }
    };
    if (ndefs < 2) {
        stmts
    } else {
        let later = rn_later(names);
        let out: [Node] = [];
        stmts.foreach((e, i) => {
            if (later[i]) {
                let decl: Decl = e;
                out += rn_rebuild_decl(decl, names[i] + "$shadow" + tostring(i));
            } else { out += e; };
        });
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
    while (size < 2 * n) { size *= 2; };
    let slots: [str] = [];
    let k = 0;
    while (k < size) { slots += ""; k++; };
    let out: [bool] = [];
    k = 0;
    while (k < n) { out += false; k++; };
    let i = n - 1;
    while (i >= 0) {
        let nm = names[i];
        if (nm != "") {
            let h = rn_hash(nm) & (size - 1);
            while (true) {
                let e = slots[h];
                if (e == "") { slots[h] = nm; break; }
                else if (e == nm) { out[i] = true; break; }
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
    for i in 0..len(s) {
        h = (h * 33 + s[i]) & 16777215;
    };
    h
};

// The name a statement binds as a hoisted def, or "" when it binds none.
def rn_decl_name(s: Node) -> str {
    if (s.k == K.decl) {
        let decl: Decl = s;
        rn_decl_name_go(decl)
    } else {
        ""
    }
};

def rn_decl_name_go(s: Decl) -> str {
    // NOTE: one `s.v.k` read per body (see rn_prepass_decl note).
    if (s.kind == "def") {
        s.name
    } else if (s.v.k == K.func) {
        s.name
    } else {
        ""
    }
};

def rn_rebuild_decl(s: Decl, newname: str) -> Decl {
    // NOTE: one literal per arm would merge two key sets through the same
    // `if` (see parse_type_arrow note) — dispatch to single-call arms so
    // each shape unifies against the {k}-hole return type instead.
    if (s.kind == "def") {
        rn_rebuild_def(s, newname)
    } else {
        rn_rebuild_let(s, newname)
    }
};

def rn_rebuild_def(s: Decl, newname: str) -> Decl {
    { k: K.decl, kind: "def", name: newname, typ: s.typ, v: s.v, line: s.line, col: s.col, nline: s.nline, ncol: s.ncol }
};

def rn_rebuild_let(s: Decl, newname: str) -> Decl {
    { k: K.decl, kind: s.kind, name: newname, typ: s.typ, v: s.v, line: s.line, col: s.col, nline: s.nline, ncol: s.ncol }
};

def rn_block(stmts: [Node], st: RnSt) -> RnStmts {
    stmts = rn_shadow_dups(stmts);
    st = rn_push(st);
    st = rn_prepass(stmts, st);
    let r = rn_list(rn_drop_typedefs(stmts, st), st);
    st = rn_pop(r.st);
    { st: st, stmts: r.nodes }
};

// The renamer's walk counts its depth (tags.y MAX_NEST) like the parser's:
// a `+` chain parses in a loop but renames recursively, so a chain of a few
// thousand terms would run the stack out here even with the parser's guard.
def rn_node(node: Node, st: RnSt) -> RnRes {
    nest++;
    if (nest > MAX_NEST) { too_deep("an expression", node.line, node.col); };
    let r = rn_node_go(node, st);
    nest--;
    r
};

// rectest / narrow: an operand plus the (alias-resolved) type it tests.
def rn_typed_e(node: Narrow, st: RnSt) -> RnRes {
    let e = rn_node(node.e, st);
    let un = rn_unknown_type(e.st, node.typ);
    if (un == "") {
        let narrowed: Narrow = { k: node.k, e: e.node, typ: rn_type(e.st, node.typ), line: node.line, col: node.col };
        let result: Node = narrowed;
        { st: e.st, node: result }
    } else {
        { st: e.st, node: rn_unknown_err(un, node.line, node.col) }
    }
};

def rn_matchend(node: MatchEnd, st: RnSt) -> RnRes {
    let e = rn_node(node.e, st);
    { st: e.st, node: { k: K.matchend, e: e.node, cover: rn_types(e.st, node.cover), vals: node.vals, line: node.line, col: node.col } }
};

def rn_call(node: Call, st: RnSt) -> RnRes {
    let c = rn_node(node.callee, st);
    let a = rn_list(node.args, c.st);
    let cn = c.node;
    let args = a.nodes;
    if (cn.k == K.id) {
        let id: Leaf = cn;
        args = rn_fill_defaults(rn_find_defaults(a.st, id.v), args, node.line, node.col);
    };
    { st: a.st, node: { k: K.call, callee: cn, args: args, line: node.line, col: node.col } }
};

def rn_if(node: If, st: RnSt) -> RnRes {
    let c = rn_node(node.cond, st);
    let t = rn_node(node.then, c.st);
    let e: RnRes = {st: t.st, node: node.els};
    if (node.has_else) { e = rn_node(node.els, t.st); };
    {st: e.st, node: {k: K.kw_if, cond: c.node, then: t.node, els: e.node, has_else: node.has_else, line: node.line, col: node.col}}
};

def rn_blocknode(node: Block, st: RnSt) -> RnRes {
    let b = rn_block(node.stmts, st);
    { st: b.st, node: { k: K.block, stmts: b.stmts, line: node.line, col: node.col } }
};

def rn_assign(node: Assign, st: RnSt) -> RnRes {
    let value = rn_node(node.v, st);
    let name = rn_lookup(value.st, node.name);
    if (name == "") { name = node.name; };
    {st: value.st, node: {k: K.assign, name: name, v: value.node, line: node.line, col: node.col}}
};

// A module reference is qualified before its object is renamed.

def rn_dot(node: Dot, st: RnSt) -> RnRes {
    let q = rn_qualified(st, node.obj, node.key);
    if (q != "") {
        rn_id(st, q, node.line, node.col)
    } else {
        let o = rn_node(node.obj, st);
        let dot: Dot = { k: K.dot, obj: o.node, key: node.key, line: node.line, col: node.col, nline: node.nline, ncol: node.ncol };
        let out: Node = dot;
        { st: o.st, node: out }
    }
};

// `m.key` naming a module's top-level binding: "m.key" when obj is the
// name of a module imported by name and no binding of that name is in
// scope, "" otherwise.
def rn_qualified(st: RnSt, obj: Node, key: str) -> str {
    if (obj.k == K.id && len(rn_mods) > 0) {
        let id: Leaf = obj;
        let m: str = id.v;
        if ((m in rn_mods) && rn_lookup(st, m) == "") { m + "." + key } else { "" }
    } else { "" }
};



def rn_dotassign(node: DotAssign, st: RnSt) -> RnRes {
    let q = rn_qualified(st, node.obj, node.key);
    if (q != "") {
        return rn_assign({k: K.assign, name: q, v: node.v, line: node.line, col: node.col}, st);
    } else {
        let obj = rn_node(node.obj, st);
        let value = rn_node(node.v, obj.st);
        return {st: value.st, node: {k: K.dotassign, obj: obj.node, key: node.key, v: value.node, line: node.line, col: node.col, nline: node.nline, ncol: node.ncol}};
    }
};

// Loop bindings enter scope after the iterable or bounds have been renamed.
def rn_foreach(node: Foreach, st: RnSt) -> RnRes {
    let iter = rn_node(node.iter, st);
    let binding = rn_bind(rn_push(iter.st), node.name, node.line, node.col);
    let body = rn_node(node.body, binding.st);
    {st: rn_pop(body.st), node: {k: K.kw_foreach, name: binding.uniq, iter: iter.node, body: body.node, line: node.line, col: node.col}}
};

def rn_forrange(node: ForRange, st: RnSt) -> RnRes {
    let lo = rn_node(node.lo, st);
    let hi = rn_node(node.hi, lo.st);
    let binding = rn_bind(rn_push(hi.st), node.name, node.line, node.col);
    let body = rn_node(node.body, binding.st);
    {st: rn_pop(body.st), node: {k: K.forrange, name: binding.uniq, lo: lo.node, hi: hi.node, body: body.node, line: node.line, col: node.col}}
};

// Function names are visible in their own body; value bindings start after
// their initializer. Prebound functions retain the name assigned by rn_prepass.
def rn_decl(node: Decl, st: RnSt) -> RnRes {
    let value: Node = node.v;
    let typ = node.typ;
    let name = "";
    if (node.kind == "native" || node.kind == "def" || value.k == K.func) {
        name = rn_lookup(st, node.name);
        if (name == "") {
            let binding = rn_bind(st, node.name, node.nline, node.ncol);
            name = binding.uniq;
            st = binding.st;
        };
        if (node.kind == "native") {
            let f: Func = value;
            value = {k: K.func, params: f.params, ptypes: rn_types(st, f.ptypes), ret: rn_type(st, f.ret), body: f.body, defs: f.defs, label: f.label, line: f.line, col: f.col, ppos: f.ppos};
        } else {
            if (node.kind == "def") { typ = rn_type(st, typ); };
            let renamed = rn_func(value, st);
            value = renamed.node;
            st = renamed.st;
        };
    } else {
        let renamed = rn_node(value, st);
        let binding = rn_bind(renamed.st, node.name, node.nline, node.ncol);
        st = binding.st;
        name = binding.uniq;
        value = renamed.node;
        let unknown = rn_unknown_type(st, typ);
        if (unknown != "") {
            let errors: [Node] = [rn_unknown_err(unknown, node.line, node.col), value];
            value = {k: K.block, stmts: errors, line: node.line, col: node.col};
        };
    };
    if (node.kind != "def") { typ = rn_type(st, typ); };
    {st: st, node: {k: K.decl, kind: node.kind, name: name, typ: typ, v: value, line: node.line, col: node.col, nline: node.nline, ncol: node.ncol}}
};

// Rename a function, preserving parameter positions and binding order.

def rn_func(node: Func, st: RnSt) -> RnRes {
    st = rn_push(st);
    let params: [str] = [];
    for i in 0..len(node.params) {
        let pl = node.line;
        let pc = node.col;
        if (i < len(node.ppos) && node.ppos[i] > 0) {
            pl = node.ppos[i] / 65536;
            pc = node.ppos[i] % 65536;
        };
        let b = rn_bind(st, node.params[i], pl, pc);
        params += b.uniq;
        st = b.st;
    };
    let fbody: Block = node.body;
    let b = rn_block(fbody.stmts, st);
    st = rn_pop(b.st);
    let un = rn_unknown_list(st, node.ptypes);
    if (un == "") { un = rn_unknown_type(st, node.ret); };
    let body: [Node] = [];
    if (un != "") { body += rn_unknown_err(un, node.line, node.col); };
    body += b.stmts;
    { st: st, node: { k: K.func, params: params, ptypes: rn_types(st, node.ptypes), ret: rn_type(st, node.ret), body: { k: K.block, stmts: body, line: node.line, col: node.col }, line: node.line, col: node.col, defs: [], label: "", ppos: node.ppos } }
};

def rename_program(ast: Block) -> Block {
    let none: [Dfl] = [];
    let nofile: [long] = [];
    let nomods: [str] = [];
    rename_program_x(ast, none, nofile, nomods)
};

def rename_program_x(ast: Block, dfl: [Dfl], ofile: [long], fmods: [str]) -> Block {
    let noids: [long] = [];
    let nonodes: [TRef] = [];
    rn_tref_ids = noids;
    rn_tref_nodes = nonodes;
    rn_reach_n = -1;
    rn_ofile = ofile;
    rn_fmods = fmods;
    let mods: [str] = [];
    foreach (m in fmods) {
        if (m != "" && !(m in mods)) { mods += m; }
    };
    rn_mods = mods;
    rn_mod = "";
    let nomt: [str] = [];
    rn_mod_types = nomt;
    rename_program_go(ast.stmts, ast.line, ast.col, dfl)
};

// The module top-level statement s belongs to ("" for none).
def rn_stmt_mod(s: Node) -> str {
    if (s.k == K.void) {
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
def rn_qualify(s: Node) -> Node {
    let m = rn_stmt_mod(s);
    if (m == "" || s.k != K.decl) {
        s
    } else {
        let decl: Decl = s;
        let nm: str = decl.name;
        if (nm.starts_with("y_")) {
            s
        } else {
            let rebuilt: Decl = rn_rebuild_decl(decl, m + "." + nm);
            let node: Node = rebuilt;
            node
        }
    }
};

// The unit's top level: rn_block, with a module's names qualified and
// each statement renamed in its own module's scope (rn_mod).
def rn_top(stmts: [Node], st: RnSt) -> RnStmts {
    let q: [Node] = [];
    if (len(rn_mods) > 0) {
        foreach (s in stmts) { q += rn_qualify(s); };
    } else { q = stmts; };
    q = rn_shadow_dups(q);
    // the aliases each module declares at its top level, as `m.T`
    let mt: [str] = [];
    if (len(rn_mods) > 0) {
        foreach (s in q) {
            if (s.k == K.typedef) {
                let m = rn_stmt_mod(s);
                let td: TypeDef = s;
                if (m != "") { mt += m + "." + td.name; };
            };
        };
    };
    rn_mod_types = mt;
    st = rn_push(st);
    st = rn_prepass(q, st);
    let kept = rn_drop_typedefs(q, st);
    let out: [Node] = [];
    foreach (s in kept) {
        if (len(rn_mods) > 0) { rn_mod = rn_stmt_mod(s); }
        let r = rn_node(s, st);
        st = r.st;
        out += r.node;
    };
    rn_mod = "";
    st = rn_pop(st);
    { st: st, stmts: out }
};

def rename_program_go(stmts: [Node], line: long, col: long, dfl: [Dfl]) -> Block {
    // NOTE: fields passed as values (see rn_func note). dfl is copied:
    // rn_note_defaults appends to the list in place.
    let d0: [Dfl] = [];
    d0 += dfl;
    let st: RnSt = { scopes: [[]], n: 1, tys: [], dfl: d0 };
    // The aliases of the units this one was compiled against first: an alias is
    // visible to every annotation of the block (rn_prepass_one hoists them).
    let seed_n = len(rn_types_seed);
    let si = 0;
    while (si < len(rn_types_seed)) {
        st.tys += rn_types_seed[si];
        si = si + 1;
    };
    rn_types_seed = [];
    rn_ixn = 0;
    let top = rn_top(stmts, st);
    let mine: [Field] = [];
    let mod0 = rn_mod;
    rn_mod = "";
    let mi = seed_n;
    while (mi < len(top.st.tys)) {
        let e: Field = top.st.tys[mi];
        let tn: TName = { k: K.tname, name: e.name };
        let named: Type = tn;
        mine += { name: e.name, opt: false, typ: rn_type_name(top.st, e.name, named, 0) };
        mi = mi + 1;
    };
    rn_mod = mod0;
    rn_types_out = mine;
    { k: K.block, stmts: top.stmts, line: line, col: col }
};

def rename_program_x2(ast: Block, dfl: [Dfl], ofile: [long], fmods: [str]) -> { ast: Block, defs: NameIx } {
    rn_defs = parser.nameix_new(1024);
    rn_want_defs = true;
    let block = rename_program_x(ast, dfl, ofile, fmods);
    rn_want_defs = false;
    { ast: block, defs: rn_defs }
};

export { rename_program, rename_program_x, rename_program_x2, rn_def_site, rn_def_line, rn_def_col };
