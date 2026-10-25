// escape.y -- what may outlive a region.

import tags from "./tags.y";
import types from "./types.y";
import parser from "./parser.y";

const E_FRESH = 1;   // made here: in the region, or by the def being summarised
const E_GLOB = 2;    // from outside: a global, a capture, an argument of a region's def
const E_HEAP = 4;    // made inside a `heap { .. }`: the collector's, kept
const E_PARAMS = 4294967288;   // bits 3..31

// A def's summary (see the header). `why` says what makes `g` true, for the
// diagnostic that names the call.
type Fx = { g: bool, p: long, r: long, a: bool, cp: long, why: str };
// A def to summarise: its name, its function, its summary's index.
type EDef = { name: str, func: Func, fx: long };
type ESt = { mode: long, ix: NameIx, vs: [long], vc: [long], rd: [bool], again: bool, heap: long, lit: long, me: str, allp: long,
    g: bool, p: long, r: long, a: bool, cp: long, why: str, esc: bool, explicit: bool, errs: [Diag], calls: [long], pl: [bool], anon: long, rec: bool, nobox: bool };

// The summaries by name: the defs of this unit and the externs it calls.
let ex_ix: NameIx = parser.nameix_new(2);
let ex_fx: [Fx] = [];
let ex_defs: [EDef] = [];
// The loops wrapped this run.
let ex_wrapped = 0;
let ex_rounds = 0;
// Whether the unit has a `region { .. }` at all (the checker notes it), so a
// unit with none skips the walk that looks for them.
let ex_has_region = false;
// The loops es_loop kept, and the def each is in.
let ex_loops: [Node] = [];
let ex_lme: [str] = [];
// The summaries the last fx_of_def read (summarise's dependencies), and per
// summary the def it belongs to (-1: an extern's).
let ex_calls: [long] = [];
let ex_dof: [long] = [];

// The few types ety answers with, made once.
let T_UNK: Type = { k: K.tunk };
let T_LONG: Type = { k: K.tlong };
let T_FLOAT: Type = { k: K.tfloat };
let T_STR: Type = { k: K.tstr };
let T_OPT: Type = { k: K.topt };

def pbit(i: long) -> long {
    if (i < 14) { 8 << i } else { E_GLOB }
};

// What parameter i reaches (its elements, its fields), apart from the value
// itself: so a def that writes into an array it was given's elements is told
// from one that grows the array.
def pcbit(i: long) -> long {
    if (i < 14) { 131072 << i } else { E_GLOB }
};

def ev0() -> long { 0 };

def evp(s: long, c: long) -> long { (s & 4294967295) | (c << 32) };

def evs(v: long) -> long { v & 4294967295 };

def evc(v: long) -> long { v >>> 32 };

def fx_new() -> Fx { { g: false, p: 0, r: 0, a: false, cp: 0, why: "" } };

def es_new(mode: long) -> ESt {
    { mode: mode, ix: parser.nameix_new(16), vs: [], vc: [], rd: [], again: false, heap: 0, lit: 0, me: "", allp: 0,
        g: false, p: 0, r: 0, a: false, cp: 0, why: "", esc: false, explicit: false, errs: [], calls: [], pl: [], anon: 0, rec: false, nobox: false }
};

// ── types: only "can a value of this type hold a reference" matters ──────

// A type whose values are plain words: nothing to free, nothing to keep.
def plain(t: Type) -> bool {
    let k = types.unfold(t).k;
    k == K.tlong || k == K.tbool || k == K.tbyte || k == K.tfloat || k == K.tvoid || k == K.tint
};

def esc_field_of(t: Type, key: str) -> Type {
    let u = types.unfold(t);
    let found = T_UNK;
    if (u.k == K.trec) {
        found = types.member_field_type(u, key);
    } else if (u.k == K.tunion) {
        let ms = types.members(u);
        let i = 0;
        while (i < len(ms)) {
            let ft = types.member_field_type(ms[i], key);
            if (ft.k != K.tnone) { found = ft; i = len(ms); } else { i++; };
        };
    };
    found
};

// The static type of a name, a member or element read, a dereference or a
// call -- enough to tell a plain value; tunk where it does not know.
def ety(node: Node) -> Type {
    let k = node.k;
    let unk = T_UNK;
    if (k == K.id) {
        let leaf: Leaf = node;
        types.bind_type(leaf.v)
    } else if (k == K.num) {
        let leaf: Leaf = node;
        if (index_of(leaf.v, ".") >= 0) { T_FLOAT } else { T_LONG }
    } else if (k == K.dot) {
        let dot: Dot = node;
        let ot = types.unfold(self(dot.obj));
        if (dot.key == "length" && (ot.k == K.tarr || ot.k == K.tarrfix || ot.k == K.tstr)) {
            T_LONG
        } else { esc_field_of(ot, dot.key) }
    } else if (k == K.index) {
        let ix: Index = node;
        let at = types.unfold(self(ix.arr));
        if (at.k == K.tarr) {
            let a: TOf = at;
            a.of
        } else if (at.k == K.tarrfix) {
            let a: TFix = at;
            a.of
        } else if (at.k == K.tstr) {
            T_LONG
        } else if (at.k == K.tmap) {
            T_OPT
        } else { unk }
    } else if (k == K.str) {
        T_STR
    } else if (k == K.bin) {
        let b: Bin = node;
        if (b.op == "+") {
            let lt = self(b.l);
            if (lt.k == K.tunk) { self(b.r) } else { lt }
        } else { unk }
    } else if (k == K.deref) {
        let w: Wrap = node;
        let pt = types.unfold(self(w.e));
        if (pt.k == K.tptr) {
            let p: TPtr = pt;
            p.to
        } else { unk }
    } else if (k == K.call) {
        let call: Call = node;
        let callee = call.callee;
        if (callee.k == K.id) {
            let leaf: Leaf = callee;
            let n = leaf.v;
            if (n == "len" || n == "ord" || n == "byte_at" || n == "index_of" || n == "last_index_of" || n == "clock_us"
                || n == "time_us" || n == "heap_used" || n == "wait_pid" || n == "sizeof" || n == "offsetof" || n == "is_some"
                || n == "ptr_addr" || n == "syscall" || n == "os_call" || n == "opt$test" || n == "mod" || n == "print"
                || n == "puts" || n == "eputs" || n == "sleep" || n == "exit" || n == "lock" || n == "try_lock" || n == "post"
                || n == "wait") {
                T_LONG
            } else {
                let ft = types.unfold(types.bind_type(n));
                if (ft.k == K.tfunc) {
                    let f: TFunc = ft;
                    f.ret
                } else { unk }
            }
        } else if (callee.k == K.dot) {
            let dot: Dot = callee;
            if (types.unfold(self(dot.obj)).k == K.tstr) {
                types.str_method(dot.key).ret
            } else { unk }
        } else { unk }
    } else { unk }
};

// ── the scope's bindings ─────────────────────────────────────────────────

def es_local(es: ESt, name: str) -> long {
    parser.nameix_get(es.ix, name)
};

// Bind a name of the scope (a `let`, a parameter, a loop variable).
def es_bind(es: ESt, name: str, v: long) -> void {
    if (es_local(es, name) < 0) {
        parser.nameix_put(es.ix, name, len(es.vs));
        es.vs += 0;
        es.vc += 0;
        es.rd += false;
        es.pl += plain(types.bind_type(name));
    };
    es_join(es, name, v);
};

def es_join(es: ESt, name: str, v: long) -> void {
    let i = es_local(es, name);
    if (i >= 0 && !es.pl[i]) {
        let s = es.vs[i] | evs(v);
        let c = es.vc[i] | evc(v);
        if (s != es.vs[i] || c != es.vc[i]) {
            if (es.rd[i]) { es.again = true; };
            es.vs[i] = s;
            es.vc[i] = c;
        };
    };
};

// A name read: a binding of the scope, or something from outside.
def es_name(es: ESt, name: str) -> long {
    let i = es_local(es, name);
    if (i >= 0) {
        if (es.pl[i]) { 0 } else {
            es.rd[i] = true;
            evp(es.vs[i], es.vc[i])
        }
    } else if (name == "none" || plain(types.bind_type(name))) {
        ev0()
    } else {
        evp(E_GLOB, E_GLOB)
    }
};

// What an assignment changes in a place: the name at its root, when it is a
// binding of the scope, now reaches v as well.
def es_root(es: ESt, node: Node, v: long) -> void {
    let n = node;
    let go = true;
    while (go) {
        if (n.k == K.dot) {
            let d: Dot = n;
            n = d.obj;
        } else if (n.k == K.index) {
            let x: Index = n;
            n = x.arr;
        } else { go = false; };
    };
    if (n.k == K.id) {
        let leaf: Leaf = n;
        es_join(es, leaf.v, evp(0, evs(v) | evc(v)));
    };
};

// ── effects ──────────────────────────────────────────────────────────────

// Whether es_fail will use its message: the first reason a summary gets, and
// every report of an explicit region. A caller that builds a message out of
// names asks first.
def es_want(es: ESt) -> bool {
    if (es.mode == 0) { !es.g } else { es.explicit }
};

def es_fail(es: ESt, msg: str, node: Node) -> void {
    if (es.mode == 0) {
        if (!es.g) { es.why = msg; };
        es.g = true;
    } else {
        es.esc = true;
        if (es.explicit) {
            let n = len(es.errs);
            if (n == 0 || es.errs[n - 1].line != node.line || es.errs[n - 1].col != node.col) {
                es.errs += { msg: msg, line: node.line, col: node.col };
            };
        };
    };
};

// Memory `obj` comes from takes a reference or grows: an error unless it was
// all made here. No bits is no memory (a summary still being made reads as
// none, and the fixed point comes back to it).
def es_hit(es: ESt, obj: long, node: Node, msg: str) -> void {
    let bits = obj;
    if ((bits & ~E_FRESH) != 0) {
        if (es.mode == 0) {
            if ((bits & (E_GLOB | E_HEAP)) != 0) { es_fail(es, msg, node); };
            es.p = es.p | (bits & E_PARAMS);
        } else {
            es_fail(es, msg, node);
        };
    };
};

// What a value shares that the caller cannot vouch for: made here (a region
// value, or a summarised def's own), or a parameter.
def es_kept(es: ESt, v: long) -> bool {
    let b = evs(v) | evc(v);
    if (es.mode == 0) { (b & (E_FRESH | E_PARAMS)) != 0 } else { (b & E_FRESH) != 0 }
};

def es_store(es: ESt, obj: long, v: long, node: Node) -> void {
    if (es_kept(es, v)) {
        es_hit(es, obj, node, if (es.mode == 0) { "stores a reference into memory it was given or a global" } else { "a reference made in this region is stored into memory that outlives it" });
    };
};

// An array or map that grows takes its new block from where allocation goes:
// fine in a `heap { .. }`.
def es_grow(es: ESt, obj: long, node: Node) -> void {
    if (es.heap == 0) {
        es_hit(es, obj, node, if (es.mode == 0) { "grows memory it was given or a global" } else { "this grows a value made outside the region, and the new block would be the region's" });
    };
};

def es_outer(es: ESt, name: str, v: long, node: Node) -> void {
    if (es_kept(es, v)) {
        let msg = "";
        if (es_want(es)) {
            msg = if (es.mode == 0) { "stores into '" + edisp(name) + "', which outlives it" } else { "a reference made in this region escapes to '" + edisp(name) + "', which outlives it" };
        };
        es_fail(es, msg, node);
    };
};

// A fresh value: allocation goes to the region (or the def's caller's), or in
// a `heap { .. }` to the collector.
def es_alloc(es: ESt) -> long {
    if (es.heap > 0) { E_HEAP } else {
        es.a = true;
        E_FRESH
    }
};

// A function value the code calls, or hands to a def that calls it: a literal
// was walked in place, a def of the unit's has a summary, anything else is
// unknown (in a summary: a parameter's bit in `cp`).
def es_fnval(es: ESt, arg: Node, av: long, node: Node) -> void {
    if (arg.k == K.func) {
    } else if (arg.k == K.id && fx_named(es, arg) >= 0) {
        let leaf: Leaf = arg;
        let fi = fx_named(es, arg);
        es.calls += fi;
        fx_need(fi);
        let f = ex_fx[fi];
        if (f.g || f.p != 0 || f.cp != 0) {
            let msg = "";
            if (es_want(es)) {
                msg = if (es.mode == 0) { "passes '" + edisp(leaf.v) + "' on to be called" } else { "'" + edisp(leaf.v) + "' is called with values the compiler cannot see, and it may keep them" };
            };
            es_fail(es, msg, node);
        };
    } else if ((evs(av) & ~E_FRESH) != 0) {
        if (es.mode == 0) {
            es.cp = es.cp | (evs(av) & E_PARAMS);
            if ((evs(av) & (E_GLOB | E_HEAP)) != 0) { es_fail(es, "calls a function value", node); };
        } else {
            es_fail(es, "a call through a function value inside a region: the compiler cannot see what it keeps", node);
        };
    };
};

// The summary a name not bound in the scope names, or -1.
def fx_named(es: ESt, node: Node) -> long {
    let leaf: Leaf = node;
    if (es_local(es, leaf.v) >= 0) { -1 } else { parser.nameix_get(ex_ix, leaf.v) }
};

// A name as the source spells it (rename's `$N` dropped).
def edisp(name: str) -> str {
    let i = index_of(name, "$");
    if (i < 0) { name } else { name[0:i] }
};

// A loop the summary walk passes, kept as a candidate for an automatic region
// (auto_loop): once per def, and not from a named def walked inside another
// (that one is summarised, and its loops kept, on its own).
def es_loop(es: ESt, loop: Node) -> void {
    if (es.mode == 0 && es.rec && es.lit == es.anon) {
        ex_loops += loop;
        ex_lme += es.me;
    };
};

// ── the walk ─────────────────────────────────────────────────────────────

def ev_list(es: ESt, xs: [Node]) -> [long] {
    let out: [long] = [];
    let i = 0;
    while (i < len(xs)) {
        out += ev(es, xs[i]);
        i++;
    };
    out
};

def ev_all(avs: [long]) -> long {
    let b = 0;
    let i = 0;
    while (i < len(avs)) {
        b = b | evs(avs[i]) | evc(avs[i]);
        i++;
    };
    b
};

// A function literal (or a nested def) walked where it is written: its
// parameters may be given anything.
def ev_lit(es: ESt, func: Func, anon: bool) -> void {
    let any = E_FRESH | E_GLOB | es.allp;
    let ps = func.params;
    let i = 0;
    while (i < len(ps)) {
        es_bind(es, ps[i], evp(any, any));
        i++;
    };
    es.lit = es.lit + 1;
    if (anon) { es.anon = es.anon + 1; };
    ev(es, func.body);
    if (anon) { es.anon = es.anon - 1; };
    es.lit = es.lit - 1;
};

def ev(es: ESt, node: Node) -> long {
    let v = ev_node(es, node);
    if (types.heap_alloc(node)) { evp(es_alloc(es), evs(v) | evc(v)) } else { v }
};

def ev_node(es: ESt, node: Node) -> long {
    // a loop body that already failed is no candidate: nothing more to learn
    if (es.esc && !es.explicit) { return 0; };
    let k = node.k;
    if (k == K.num || k == K.char || k == K.bool || k == K.str || k == K.void || k == K.kw_break || k == K.kw_continue || k == K.typedef || k == K.err) {
        ev0()
    } else if (k == K.bstr || k == K.bignum) {
        evp(es_alloc(es), 0)
    } else if (k == K.id) {
        let leaf: Leaf = node;
        let n = leaf.v;
        if (es_local(es, n) < 0 && parser.nameix_get(ex_ix, n) >= 0) {
            // a def as a value: whoever calls it, with whatever
            es_fnval(es, node, evp(E_GLOB, 0), node);
            evp(es_alloc(es), 0)
        } else { es_name(es, n) }
    } else if (k == K.array) {
        let a: ArrLit = node;
        let b = ev_all(ev_list(es, a.elems));
        evp(es_alloc(es), b)
    } else if (k == K.arrrep) {
        let a: ArrRep = node;
        let v = ev(es, a.v);
        evp(es_alloc(es), evs(v) | evc(v))
    } else if (k == K.rec || k == K.map) {
        let r: RecLit = node;
        let b = ev_all(ev_list(es, r.vals));
        evp(es_alloc(es), b)
    } else if (k == K.bin) {
        let b: Bin = node;
        let op = b.op;
        // `m[k] == none` and `!= none` test the entry without a box
        let cmpn = (op == "==" || op == "!=") && (is_named(b.l, "none") || is_named(b.r, "none"));
        es.nobox = cmpn;
        let l = ev(es, b.l);
        es.nobox = cmpn;
        let r = ev(es, b.r);
        es.nobox = false;
        let lb = types.unfold(ety(b.l)).k == K.tbigint;
        let rb = types.unfold(ety(b.r)).k == K.tbigint;
        if (lb != rb) { es_alloc(es); };
        if (op == "in" && types.unfold(ety(b.r)).k == K.tstr) { es_alloc(es); };
        let tk = types.unfold(ety(node)).k;
        if (op == "==" || op == "!=" || op == "<" || op == ">" || op == "<=" || op == ">=" || op == "&&" || op == "||" || op == "in") {
            ev0()
        } else if (tk != K.tstr && tk != K.tarr && (evs(l) | evc(l) | evs(r) | evc(r)) == 0 && b.l.k != K.str && b.r.k != K.str) {
            ev0()
        } else if (tk == K.tstr) {
            // a string `+` copies the bytes
            evp(es_alloc(es), 0)
        } else {
            evp(es_alloc(es), evs(l) | evc(l) | evs(r) | evc(r))
        }
    } else if (k == K.un) {
        let u: Un = node;
        let v = ev(es, u.e);
        if (u.op == "!" || (evs(v) | evc(v)) == 0) { ev0() } else { evp(es_alloc(es), 0) }
    } else if (k == K.addr) {
        let w: Wrap = node;
        let v = ev(es, w.e);
        evp(E_FRESH | E_GLOB | evs(v) | evc(v), evc(v))
    } else if (k == K.deref) {
        let w: Wrap = node;
        ev(es, w.e);
        if (plain(ety(node))) { ev0() } else { evp(E_GLOB, E_GLOB) }
    } else if (k == K.dot) {
        let d: Dot = node;
        let o = ev(es, d.obj);
        if (plain(ety(node))) { ev0() } else if (d.key == "ptr") { evp(evs(o) | evc(o), evc(o)) } else { evp(evc(o), evc(o)) }
    } else if (k == K.index) {
        let x: Index = node;
        let nobox = es.nobox;
        es.nobox = false;
        let a = ev(es, x.arr);
        ev(es, x.idx);
        let at = types.unfold(ety(x.arr));
        if (at.k == K.tmap && !nobox) {
            // a read `m[k]` boxes the entry and keeps the box in the map
            // (native.y gen_map_get "opt"): a store into the map
            if (es_alloc(es) == E_FRESH) {
                es_hit(es, evs(a), node, if (es.mode == 0) { "keeps a map read's box in a map it was given or a global" } else { "this map read keeps a box of the entry in a map made outside the region (read it with '!' or test it with is_some)" });
            };
        };
        if (at.k == K.tmap) { evp(es_alloc(es) | evc(a), evc(a)) } else if (plain(ety(node))) { ev0() } else { evp(evc(a), evc(a)) }
    } else if (k == K.slice) {
        let x: Slice = node;
        // always a new array or string (native.y gen_slice)
        let a = ev(es, x.arr);
        ev(es, x.lo);
        ev(es, x.hi);
        evp(es_alloc(es), evc(a))
    } else if (k == K.call) {
        let call: Call = node;
        ev_call(es, call)
    } else if (k == K.func) {
        let func: Func = node;
        ev_lit(es, func, true);
        evp(es_alloc(es), 0)
    } else if (k == K.decl) {
        let d: Decl = node;
        if (d.v.k == K.func) {
            let func: Func = d.v;
            es_bind(es, d.name, evp(E_FRESH, 0));
            ev_lit(es, func, false);
        } else {
            let v = ev(es, d.v);
            es_bind(es, d.name, v);
        };
        ev0()
    } else if (k == K.assign) {
        let a: Assign = node;
        let v = ev(es, a.v);
        if (es_local(es, a.name) >= 0) {
            es_join(es, a.name, v);
        } else if (!plain(types.bind_type(a.name))) {
            es_outer(es, a.name, v, node);
        };
        v
    } else if (k == K.block) {
        let b: Block = node;
        let last = ev0();
        let i = 0;
        while (i < len(b.stmts)) {
            last = ev(es, b.stmts[i]);
            i++;
        };
        last
    } else if (k == K.kw_if) {
        let f: If = node;
        ev(es, f.cond);
        let t = ev(es, f.then);
        if (f.has_else) { t | ev(es, f.els) } else { t }
    } else if (k == K.kw_while) {
        let w: While = node;
        ev(es, w.cond);
        ev(es, w.body);
        es_loop(es, node);
        ev0()
    } else if (k == K.kw_for) {
        let f: For = node;
        ev(es, f.init);
        ev(es, f.cond);
        ev(es, f.step);
        ev(es, f.body);
        es_loop(es, node);
        ev0()
    } else if (k == K.kw_foreach) {
        let f: Foreach = node;
        let it = ev(es, f.iter);
        es_bind(es, f.name, evp(evc(it), evc(it)));
        ev(es, f.body);
        es_loop(es, node);
        ev0()
    } else if (k == K.forrange) {
        let f: ForRange = node;
        ev(es, f.lo);
        ev(es, f.hi);
        ev(es, f.body);
        es_loop(es, node);
        ev0()
    } else if (k == K.opassign) {
        let o: OpAssign = node;
        ev_opassign(es, o);
        // Compound assignment is a value too: ir_push and similar builders
        // return their array with a final `a += item`.
        ev(es, o.tgt)
    } else if (k == K.incdec) {
        let i: IncDec = node;
        let old = ev(es, i.tgt);
        if (types.unfold(ety(i.tgt)).k == K.tbigint) {
            let a: OpAssign = { k: K.opassign, tgt: i.tgt, op: if (i.op == "++") { "+" } else { "-" },
                v: { k: K.num, v: "1", line: i.line, col: i.col }, line: i.line, col: i.col };
            ev_opassign(es, a);
            if (i.pre) { evp(es_alloc(es), 0) } else { old }
        } else { ev0() }
    } else if (k == K.idxassign) {
        let a: IdxAssign = node;
        let o = ev(es, a.arr);
        ev(es, a.idx);
        let v = ev(es, a.v);
        let at = types.unfold(ety(a.arr));
        if (at.k == K.tmap) {
            es_grow(es, evs(o), node);
        };
        if (at.k == K.tptr) { es_store(es, E_GLOB, v, node); } else { es_store(es, evs(o), v, node); };
        es_root(es, a.arr, v);
        v
    } else if (k == K.dotassign) {
        let a: DotAssign = node;
        let o = ev(es, a.obj);
        let v = ev(es, a.v);
        es_store(es, evs(o), v, node);
        es_root(es, a.obj, v);
        v
    } else if (k == K.store) {
        let s: Store = node;
        ev(es, s.p);
        let v = ev(es, s.v);
        es_store(es, E_GLOB, v, node);
        v
    } else if (k == K.sliceassign) {
        let a: SliceAssign = node;
        let o = ev(es, a.arr);
        ev(es, a.lo);
        ev(es, a.hi);
        let v = ev(es, a.v);
        es_grow(es, evs(o), node);
        es_store(es, evs(o), v, node);
        es_root(es, a.arr, v);
        ev0()
    } else if (k == K.rectest) {
        let n: Narrow = node;
        ev(es, n.e);
        ev0()
    } else if (k == K.narrow) {
        let n: Narrow = node;
        let v = ev(es, n.e);
        // a cast copies when the layouts differ
        if ((evs(v) | evc(v)) == 0) { v } else { evp(evs(v) | es_alloc(es), evc(v)) }
    } else if (k == K.matchend) {
        let m: MatchEnd = node;
        ev(es, m.e)
    } else if (k == K.ret) {
        let w: Wrap = node;
        let v = ev(es, w.e);
        if (es.lit == 0) {
            if (es.mode == 0) {
                es.r = es.r | v;
            } else if (((evs(v) | evc(v)) & E_FRESH) != 0) {
                es_fail(es, "a reference made in this region is returned out of it", node);
            };
        };
        ev0()
    } else {
        ev0()
    }
};

// `t op= v`. On a name: an array grows in place (its memory takes the
// element); a string, a bigint is a new value bound to the name. On a member
// or an element: the same, with the container taking the new value.
def ev_opassign(es: ESt, node: OpAssign) -> void {
    let tgt = node.tgt;
    let v = ev(es, node.v);
    let t = ety(tgt);
    if (tgt.k == K.id) {
        let leaf: Leaf = tgt;
        let n = leaf.v;
        if (!plain(t)) {
            let uk = types.unfold(t).k;
            let loc = es_local(es, n) >= 0;
            if (uk == K.tarr) {
                let o = if (loc) { evs(es_name(es, n)) } else { E_GLOB };
                es_grow(es, o, node);
                es_store(es, o, v, node);
                es_join(es, n, evp(0, evs(v) | evc(v)));
            } else {
                let nv: long = evp(es_alloc(es), 0);
                if (loc) { es_join(es, n, nv); } else { es_outer(es, n, nv, node); };
            };
        };
    } else {
        let tv = ev(es, tgt);
        let cont = E_GLOB;
        if (tgt.k == K.dot) {
            let d: Dot = tgt;
            cont = evs(ev(es, d.obj));
        } else if (tgt.k == K.index) {
            let x: Index = tgt;
            cont = evs(ev(es, x.arr));
        };
        if (!plain(t)) {
            if (types.unfold(t).k == K.tarr) {
                es_grow(es, evs(tv), node);
                es_store(es, evs(tv), v, node);
            } else {
                es_store(es, cont, evp(es_alloc(es), 0), node);
            };
            es_root(es, tgt, v);
        };
    };
};

// What a call's result shares, from the callee's summary: `r` is the result
// as a value (evp: itself, what it reaches), in the callee's bits.
def fx_result(f: Fx, avs: [long], es: ESt) -> long {
    if (f.a) { es_alloc(es); };
    evp(fx_map(f.r & 4294967295, avs, es), fx_map(f.r >>> 32, avs, es))
};

// The callee's bits as the caller's: what it made lands where the caller
// allocates, a parameter is the argument (or what the argument reaches).
def fx_map(bits: long, avs: [long], es: ESt) -> long {
    let b = 0;
    if ((bits & E_FRESH) != 0) { b = es_alloc(es); };
    if ((bits & (E_GLOB | E_HEAP)) != 0) { b = b | E_GLOB; };
    let i = 0;
    while (i < len(avs)) {
        if ((bits & pbit(i)) != 0) { b = b | evs(avs[i]); };
        if ((bits & pcbit(i)) != 0) { b = b | evc(avs[i]); };
        i++;
    };
    // a parameter left to its default: a literal, made at the call
    while (i < 14) {
        if ((bits & (pbit(i) | pcbit(i))) != 0) { b = b | es_alloc(es); };
        i++;
    };
    b
};

// A call to a def with a summary.
def ev_apply(es: ESt, f: Fx, fname: str, args: [Node], avs: [long], node: Node) -> long {
    if (f.g) {
        let msg = "";
        if (es_want(es)) {
            msg = if (es.mode == 0) { "calls '" + edisp(fname) + "'" } else { "'" + edisp(fname) + "' may keep a reference or grow memory outside the region (it " + f.why + ")" };
        };
        es_fail(es, msg, node);
    };
    let i = 0;
    while (i < len(avs)) {
        let bit = pbit(i);
        let cbit = pcbit(i);
        if ((f.p & (bit | cbit)) != 0 && es.heap == 0) {
            let msg = "";
            if (es_want(es)) {
                msg = if (es.mode == 0) { "hands memory to '" + edisp(fname) + "', which grows or stores into it" } else { "'" + edisp(fname) + "' may grow or store into its argument " + tostring(i + 1) + ", which was made outside the region" };
            };
            let obj = 0;
            if ((f.p & bit) != 0) { obj = evs(avs[i]); };
            if ((f.p & cbit) != 0) { obj = obj | evc(avs[i]); };
            es_hit(es, obj, node, msg);
        };
        if ((f.cp & (bit | cbit)) != 0) { es_fnval(es, args[i], avs[i], node); };
        i++;
    };
    fx_result(f, avs, es)
};

def ev_call(es: ESt, call: Call) -> long {
    let callee = call.callee;
    let args = call.args;
    if (callee.k == K.dot) {
        let dot: Dot = callee;
        let ok = types.unfold(ety(dot.obj)).k;
        let o = ev(es, dot.obj);
        let avs = ev_list(es, args);
        let key = dot.key;
        if (ok == K.tstr) {
            if (key == "contains" || key == "count" || key == "index_of" || key == "last_index_of") { es_alloc(es); };
            let rt = types.str_method(key).ret;
            if (plain(rt)) { ev0() } else if (types.unfold(rt).k == K.tstr) { evp(es_alloc(es), 0) } else {
                let b = es_alloc(es);
                evp(b, b)
            }
        } else if (ok == K.tarr || ok == K.tarrfix) {
            if (key == "push" || key == "unshift" || key == "insert") {
                let b = ev_all(avs);
                es_grow(es, evs(o), call);
                es_store(es, evs(o), evp(b, 0), call);
                es_root(es, dot.obj, evp(b, 0));
                ev0()
            } else if (key == "pop" || key == "shift" || key == "remove") {
                if (key == "remove" && len(args) == 2) { evp(es_alloc(es), evc(o)) }
                else if (plain(ety(call))) { ev0() } else { evp(evc(o), evc(o)) }
            } else {
                // the iterating methods call what they are given
                let i = 0;
                while (i < len(args)) {
                    es_fnval(es, args[i], avs[i], call);
                    i++;
                };
                let b = es_alloc(es);
                evp(b | evc(o), b | evc(o) | ev_all(avs))
            }
        } else {
            // a function kept in a field: whatever the object reaches
            let fv = evc(o);
            if (fv == 0) { fv = E_GLOB; };
            es_fnval(es, callee, evp(fv, 0), call);
            evp(E_FRESH | E_GLOB, E_FRESH | E_GLOB)
        }
    } else if (callee.k != K.id) {
        let cv = ev(es, callee);
        ev_list(es, args);
        es_fnval(es, callee, evp(evs(cv) | E_GLOB, 0), call);
        evp(E_FRESH | E_GLOB, E_FRESH | E_GLOB)
    } else {
        let leaf: Leaf = callee;
        let n = leaf.v;
        if (n == "region$" || n == "region$auto") {
            ev_list(es, args);
            ev0()
        } else if (n == "heap$") {
            es.heap = es.heap + 1;
            ev_list(es, args);
            es.heap = es.heap - 1;
            ev0()
        } else {
            // `m[k]!` and `is_some(m[k])` read the entry without a box
            if ((n == "unwrap" || n == "is_some") && len(args) == 1) { es.nobox = true; };
            let avs = ev_list(es, args);
            es.nobox = false;
            if (es_local(es, n) >= 0) {
                // a closure of the scope: walked where it was written
                let cv = es_name(es, n);
                es_fnval(es, callee, cv, call);
                let any = E_FRESH | E_GLOB | es.allp;
                if (plain(ety(call))) { ev0() } else { evp(any, any) }
            } else if (n == "self") {
                let si = parser.nameix_get(ex_ix, es.me);
                if (si >= 0) { es.calls += si; };
                if (es.lit > 0 || si < 0) {
                    let any = E_FRESH | E_GLOB | es.allp;
                    if (plain(ety(call))) { ev0() } else { evp(any, any) }
                } else {
                    let r = ev_apply(es, ex_fx[si], es.me, args, avs, call);
                    if (plain(ety(call))) { ev0() } else { r }
                }
            } else if (parser.nameix_get(ex_ix, n) >= 0) {
                let fi = parser.nameix_get(ex_ix, n);
                es.calls += fi;
                fx_need(fi);
                let r = ev_apply(es, ex_fx[fi], n, args, avs, call);
                if (plain(ety(call))) { ev0() } else { r }
            } else if (types.bind_kind(n) == "intrinsic" || types.bind_kind(n) == "" ) {
                ev_intrinsic(es, n, args, avs, call)
            } else {
                es_fnval(es, callee, evp(E_GLOB, 0), call);
                if (plain(ety(call))) { ev0() } else { evp(E_FRESH | E_GLOB, E_FRESH | E_GLOB) }
            }
        }
    }
};

// The builtins (native.y INTRINSICS) and anything else bound to no def.
def ev_intrinsic(es: ESt, n: str, args: [Node], avs: [long], call: Call) -> long {
    if (n == "spawn" || n == "fork") {
        es_fail(es, if (es.mode == 0) { "starts a thread or a process" } else if (es.explicit) { "'" + n + "' inside a region (a region is one thread's, and a forked child would not have it)" } else { "" }, call);
        ev0()
    } else if (n == "push" || n == "prepend") {
        if (len(avs) > 1) {
            es_grow(es, evs(avs[0]), call);
            es_store(es, evs(avs[0]), avs[1], call);
            es_root(es, args[0], avs[1]);
        };
        ev0()
    } else if (n == "argv") {
        evp(E_GLOB, E_GLOB)
    } else if (n == "unwrap" || n == "opt$val") {
        if (len(avs) > 0 && !plain(ety(call))) { evp(evc(avs[0]), evc(avs[0])) } else { ev0() }
    } else if (n == "some") {
        let b = ev_all(avs);
        evp(es_alloc(es), b)
    } else if (n == "print" || n == "puts" || n == "eputs") {
        foreach (arg in args) { if (types.output_alloc(n, ety(arg))) { es_alloc(es); }; };
        ev0()
    } else if (n == "index_of" || n == "last_index_of") {
        es_alloc(es);
        ev0()
    } else if (plain(ety(call))) {
        ev0()
    } else if (n == "ptr_from" || n == "jmp_at") {
        evp(E_GLOB | E_FRESH, E_GLOB | E_FRESH)
    } else if (types.bind_kind(n) == "" && !(n == "trim" || n == "tostring" || n == "join" || n == "split" || n == "keys"
        || n == "values" || n == "bytes" || n == "from_bytes" || n == "range" || n == "typeof" || n == "#fmt" || n == "mutex"
        || n == "sem" || n == "tofloat" || n == "tolong" || n == "chr")) {
        // not a builtin this pass knows: anything
        es_fnval(es, call.callee, evp(E_GLOB, 0), call);
        evp(E_FRESH | E_GLOB, E_FRESH | E_GLOB)
    } else {
        // what it makes may be inside what it returns (split's strings)
        let b = ev_all(avs) | es_alloc(es);
        evp(b, b)
    }
};

// ── 1. summaries ─────────────────────────────────────────────────────────

// Walk a scope until no binding changed after it was read (at most a few
// times: the bit sets only grow).
def es_run(es: ESt, body: Node) -> long {
    let v = ev(es, body);
    let n = 0;
    while (es.again && n < 20) {
        es.again = false;
        let i = 0;
        while (i < len(es.rd)) {
            es.rd[i] = false;
            i++;
        };
        es.errs = [];
        es.esc = false;
        es.rec = false;
        v = ev(es, body);
        n++;
    };
    if (es.again) { es_fail(es, "is too tangled for the region check", body); };
    v
};

def fx_of_def(d: EDef, rec: bool) -> Fx {
    let es = es_new(0);
    es.rec = rec;
    let func = d.func;
    es.me = d.name;
    let ps = func.params;
    let i = 0;
    while (i < len(ps)) {
        es.allp = es.allp | pbit(i) | pcbit(i);
        i++;
    };
    i = 0;
    while (i < len(ps)) {
        es_bind(es, ps[i], evp(pbit(i), pcbit(i)));
        i++;
    };
    let v = es_run(es, func.body);
    ex_calls = es.calls;
    let r = es.r | v;
    if (plain(func.ret) && func.ret.k != K.tinfer && func.ret.k != K.tunk) { r = 0; };
    { g: es.g, p: es.p, r: r, a: es.a, cp: es.cp, why: es.why }
};

// A def written in assembly (`ndef`): its body is not here to read. It may
// allocate and return what it is given; it keeps nothing.  `y_bytes_zero` is
// the one audited exception: it returns a new pointer-free buffer and cannot
// share anything with its scalar argument.
def fx_ndef(label: str) -> Fx {
    if (label == "y_bytes_zero") {
        { g: false, p: 0, r: E_FRESH, a: true, cp: 0, why: "" }
    } else {
        { g: false, p: 0, r: evp(E_FRESH | E_GLOB | E_PARAMS, E_FRESH | E_GLOB | E_PARAMS), a: true, cp: 0, why: "" }
    }
};

def fx_same(a: Fx, b: Fx) -> bool {
    a.g == b.g && a.p == b.p && a.r == b.r && a.a == b.a && a.cp == b.cp
};

// Every child of a node, for the walks that look for something (what = 1:
// check_regions, 2: auto_loops). Visited in place: a list of
// children per node was most of what these walks allocated.
def wk(node: Node, what: long) -> void {
    if (what == 1) { check_regions(node); } else { auto_loops(node); };
};

def walk_kids(node: Node, what: long) -> void {
    if (node.k == K.func) {
        let func: Func = node;
        wk(func.body, what);
    } else {
        node_each_child(node, (child: Node) => wk(child, what));
    };
};

let ex_state: [long] = [];     // per def: 0 not yet, 1 being made, 2 made
let ex_callers: [[long]] = [];
let ex_queued: [bool] = [];
let ex_queue: [long] = [];

def fx_need(fi: long) -> void {
    let d = ex_dof[fi];
    if (d >= 0 && ex_state[d] == 0) { fx_make(d); };
};

def fx_make(d: long) -> void {
    let first = ex_state[d] == 0;
    ex_state[d] = 1;
    let def0 = ex_defs[d];
    let f = fx_of_def(def0, first);
    let cs = ex_calls;
    let j = 0;
    while (j < len(cs)) {
        let dd = ex_dof[cs[j]];
        if (dd >= 0) {
            let cl = ex_callers[dd];
            if (len(cl) == 0 || cl[len(cl) - 1] != d) { cl += d; };
        };
        j++;
    };
    ex_state[d] = 2;
    ex_rounds++;
    if (!fx_same(f, ex_fx[def0.fx])) {
        ex_fx[def0.fx] = f;
        let cl = ex_callers[d];
        j = 0;
        while (j < len(cl)) {
            if (!ex_queued[cl[j]]) {
                ex_queued[cl[j]] = true;
                ex_queue += cl[j];
            };
            j++;
        };
    };
};

def summarise() -> void {
    let n = len(ex_defs);
    ex_state = [];
    ex_callers = [];
    ex_queued = [];
    ex_queue = [];
    ex_rounds = 0;
    let i = 0;
    while (i < n) {
        let none: [long] = [];
        ex_callers += none;
        let nd = len(ex_defs[i].func.label) == 0;
        ex_state += if (nd) { 0 } else { 2 };
        ex_queued += false;
        i++;
    };
    i = 0;
    while (i < n) {
        if (ex_state[i] == 0) { fx_make(i); };
        i++;
    };
    let qi = 0;
    let budget = 30 * n + 100;
    while (qi < len(ex_queue) && ex_rounds < budget) {
        let d = ex_queue[qi];
        qi++;
        ex_queued[d] = false;
        fx_make(d);
    };
    if (qi < len(ex_queue)) {
        // did not settle: nothing is vouched for
        i = 0;
        while (i < n) {
            let f = ex_fx[ex_defs[i].fx];
            f.g = true;
            f.why = "is too tangled for the region check";
            i++;
        };
    };
};

// ── 2. the explicit regions ──────────────────────────────────────────────

let ex_errs: [Diag] = [];
let ex_self = "";

def region_check(body: Node, explicit: bool) -> ESt {
    let es = es_new(1);
    es.explicit = explicit;
    es.me = ex_self;
    es_run(es, body);
    es
};

def is_named(node: Node, n: str) -> bool {
    if (node.k == K.id) {
        let leaf: Leaf = node;
        leaf.v == n
    } else { false }
};

// A region whose only statement exits the process has no observer after its
// lifetime ends. Its callees may keep scratch in globals until that exit.
// Keep this syntactic: a user function named exit may return normally.
def esc_process_arg(node: Node) -> bool {
    if (node.k == K.func) { return true; };
    if (node.k == K.ret || node.k == K.kw_break || node.k == K.kw_continue) { return false; };
    let safe = true;
    node_each_child(node, (child: Node) => { if (!esc_process_arg(child)) { safe = false; }; });
    safe
};

def esc_process_region(node: Node, bound: bool = true) -> bool {
    if (node.k != K.call) { return false; };
    let c: Call = node;
    if (!is_named(c.callee, "region$") || len(c.args) != 1 || c.args[0].k != K.block) { return false; };
    let b: Block = c.args[0];
    if (len(b.stmts) == 0 || len(b.stmts) > 2 || b.stmts[0].k != K.call) { return false; };
    if (len(b.stmts) == 2 && b.stmts[1].k != K.void) { return false; };
    let e: Call = b.stmts[0];
    let kind = types.bind_kind("exit");
    is_named(e.callee, "exit") && (!bound || kind == "intrinsic" || kind == "")
        && len(e.args) == 1 && esc_process_arg(e.args[0])
};

def check_regions(node: Node, top: bool = false) -> void {
    if (node.k == K.decl) {
        let d: Decl = node;
        if (d.v.k == K.func && d.kind == "def") {
            let saved = ex_self;
            ex_self = d.name;
            self(d.v, false);
            ex_self = saved;
        } else { self(d.v, false); };
    } else if (node.k == K.call) {
        let c: Call = node;
        if (is_named(c.callee, "region$") && len(c.args) == 1) {
            if (!top || !esc_process_region(node)) {
                let es = region_check(c.args[0], true);
                ex_errs += es.errs;
            };
        };
        walk_kids(node, 1);
    } else {
        walk_kids(node, 1);
    };
};

// ── 3. automatic regions ─────────────────────────────────────────────────

def block_len(node: Node) -> long {
    if (node.k == K.block) {
        let b: Block = node;
        len(b.stmts)
    } else { -1 }
};

def auto_loop(loop: Node) -> void {
    let k = loop.k;
    let parts: [Node] = [];
    let body = loop;
    if (k == K.kw_while) {
        let w: While = loop;
        parts += w.cond;
        body = w.body;
    } else if (k == K.kw_for) {
        let f: For = loop;
        parts += f.cond;
        parts += f.step;
        body = f.body;
    } else if (k == K.kw_foreach) {
        let f: Foreach = loop;
        body = f.body;
    } else if (k == K.forrange) {
        let f: ForRange = loop;
        body = f.body;
    };
    // an empty body has no statement to put the region in (the condition may
    // still allocate: it stays the collector's)
    if (block_len(body) > 0) {
        parts += body;
        let all: Node = { k: K.block, stmts: parts, line: body.line, col: body.col };
        let es = region_check(all, false);
        if (!es.esc && es.a) {
            ex_wrapped++;
            let blk: Block = body;
            let xs = blk.stmts;
            let inner: [Node] = [];
            inner += xs;
            let ib: Node = { k: K.block, stmts: inner, line: body.line, col: body.col };
            let args: [Node] = [ib];
            let c: Node = { k: K.call, callee: { k: K.id, v: "region$auto", line: body.line, col: body.col }, args: args, line: body.line, col: body.col };
            // the region where the first statement was, and the rest emptied
            xs[0] = c;
            let i = 1;
            while (i < len(xs)) {
                let vd: Node = { k: K.void, line: body.line, col: body.col };
                xs[i] = vd;
                i++;
            };
        };
    };
};

// The top level's loops (a def's are kept by es_loop), not into the defs.
def auto_loops(node: Node) -> void {
    let k = node.k;
    if (k == K.decl) {
        let d: Decl = node;
        if (d.v.k != K.func) { self(d.v); };
    } else if (k == K.func) {
    } else if (k == K.kw_while) {
        let w: While = node;
        self(w.body);
        auto_loop(node);
    } else if (k == K.kw_for) {
        let f: For = node;
        self(f.body);
        auto_loop(node);
    } else if (k == K.kw_foreach) {
        let f: Foreach = node;
        self(f.body);
        auto_loop(node);
    } else if (k == K.forrange) {
        let f: ForRange = node;
        self(f.body);
        auto_loop(node);
    } else {
        walk_kids(node, 2);
    };
};

// ── the unit ─────────────────────────────────────────────────────────────

// One unit: `xnames`/`xfx` are the externs the unit calls and their summaries
// (fx_decode), `tops` the names of its top-level defs. Returns the errors of
// its explicit regions; when `auto` is on, the loop bodies that qualify are
// wrapped in place; esc_exports then gives the top-level defs' summaries.
def esc_unit(stmts: [Node], dnames: [str], dfuncs: [Func], has_region: bool, xnames: [str], xfx: [str], auto: bool) -> [Diag] {
    ex_ix = parser.nameix_new(256);
    ex_fx = [];
    ex_defs = [];
    ex_has_region = has_region;
    ex_loops = [];
    ex_lme = [];
    ex_dof = [];
    ex_errs = [];
    ex_self = "";
    ex_wrapped = 0;
    let i = 0;
    while (i < len(xnames)) {
        parser.nameix_put(ex_ix, xnames[i], len(ex_fx));
        ex_fx += fx_decode(xfx[i]);
        ex_dof += -1;
        i++;
    };
    i = 0;
    while (i < len(dnames)) {
        let func = dfuncs[i];
        ex_dof += len(ex_defs);
        ex_defs += { name: dnames[i], func: func, fx: len(ex_fx) };
        parser.nameix_put(ex_ix, dnames[i], len(ex_fx));
        ex_fx += if (len(func.label) > 0) { fx_ndef(func.label) } else { fx_new() };
        i++;
    };
    summarise();
    i = 0;
    while (ex_has_region && i < len(stmts)) {
        check_regions(stmts[i], true);
        i++;
    };
    if (auto && len(ex_errs) == 0) {
        // the loops of the defs (es_loop), then those of the top level
        i = 0;
        while (i < len(ex_loops)) {
            ex_self = ex_lme[i];
            auto_loop(ex_loops[i]);
            i++;
        };
        ex_self = "";
        i = 0;
        while (i < len(stmts)) {
            let st = stmts[i];
            let isfn = false;
            if (st.k == K.decl) {
                let d: Decl = st;
                isfn = d.v.k == K.func;
            };
            if (!isfn) { auto_loops(st); };
            i++;
        };
    };
    ex_errs
};

// The summary of the unit's def `name` as the pack stores it, or "" for none.
def esc_export(name: str) -> str {
    let i = parser.nameix_get(ex_ix, name);
    if (i < 0) { "" } else { fx_encode(ex_fx[i]) }
};

def esc_wrapped() -> long { ex_wrapped };

// A call can have a shorter lifetime than its enclosing loop. In checked
// builds, reclaim a def's scratch space on every return when its summary
// proves that neither its result nor any outside memory can retain it. This
// also handles allocating loop conditions and scalar-returning helpers.
def esc_functions(eligible: [str]) -> void {
    foreach (d in ex_defs) {
        let f = ex_fx[d.fx];
        let body = d.func.body;
        if (d.name in eligible && len(d.func.label) == 0 && body.k == K.block && f.a && !f.g && f.p == 0 && f.cp == 0
            && ((evs(f.r) | evc(f.r)) & E_FRESH) == 0) {
            let b: Block = body;
            let xs = b.stmts;
            if (len(xs) > 0) {
                let inner: [Node] = [];
                inner += xs;
                let ib: Node = { k: K.block, stmts: inner, line: body.line, col: body.col };
                let rt = d.func.ret;
                if (rt.k == K.tnone || rt.k == K.tinfer || rt.k == K.tunk) { rt = types.inferred_ret(d.func.line, d.func.col); };
                let value: Node = ib;
                if (rt.k != K.tvoid) { value = { k: K.ret, e: ib, line: body.line, col: body.col }; };
                let args: [Node] = [value];
                xs[0] = { k: K.call, callee: { k: K.id, v: "region$auto", line: body.line, col: body.col }, args: args, line: body.line, col: body.col };
                for i in 1..len(xs) { xs[i] = { k: K.void, line: body.line, col: body.col }; };
            };
        };
    };
};

// g, p, r, a, cp and why, tab-separated.
def fx_encode(f: Fx) -> str {
    (if (f.g) { "1" } else { "0" }) + "\t" + tostring(f.p) + "\t" + tostring(f.r) + "\t" + (if (f.a) { "1" } else { "0" }) + "\t" + tostring(f.cp) + "\t" + f.why
};

def num_of(s: str) -> long {
    let v = tolong(s);
    if (v == none) { 0 } else { unwrap(v) }
};

def fx_decode(s: str) -> Fx {
    // split drops a trailing empty field: an empty `why`
    let ps = split(s, "\t");
    if (len(ps) == 5) { ps += ""; };
    // Older result proofs must not justify an arena even in a GC-enabled
    // caller: their assignment results may have lost reference provenance.
    if (len(ps) < 9 || ps[6] != "L5") {
        { g: true, p: 0, r: evp(E_GLOB, E_GLOB), a: true, cp: 0, why: "is not known to the region check" }
    } else {
        { g: ps[0] == "1", p: num_of(ps[1]), r: num_of(ps[2]), a: ps[3] == "1", cp: num_of(ps[4]), why: ps[5] }
    }
};

export { esc_unit, esc_export, esc_wrapped, esc_functions, esc_process_region, fx_encode, fx_decode };
