// Allocation effects after escape.y has placed the proved regions.
// A caller's region discharges ordinary allocations, including repeated ones;
// heap blocks bypass it. Effects travel with Unit.fx in the std/package pack.
import tags from "./tags.y";
import parser from "./parser.y";
import types from "./types.y";
import lint from "./lint.y";
import escape from "./escape.y";

const L_ALLOC = 1;
const L_HEAP = 2;
const L_REPEAT = 4;
const L_HREPEAT = 8;
const L_THREAD = 16;
const L_UNKNOWN = 32;
const L_LOOP = 64; // repeated within one invocation, rather than recursion
const L_BAD = 60;
type LifeFn = { name: str, bits: long, body: bool, params: [str] };
type LifeCall = { name: str, args: [Node] };
type LifeUse = { from: long, name: str, bits: long, repeat: bool, region: bool, heap: bool, process: bool, line: long, col: long, what: str };
type LifeSt = { fns: [LifeFn], ix: NameIx, uses: [LifeUse], calls: [LifeCall], values: [str], cur: long, loops: long, regions: long, heap: bool, process: bool, closed: bool };
let life_state: LifeSt = { fns: [], ix: parser.nameix_new(2), uses: [], calls: [], values: [], cur: 0, loops: 0, regions: 0, heap: false, process: false, closed: false };
let life_init = 0;

// Audited runtime assembly primitives. All other ndefs require a proof the
// source checker cannot obtain from a signature alone.
def life_asm_bits(label: str) -> long {
    if (label == "y_bytes_zero") { L_ALLOC }
    else if (label in ["y_host_machine", "y_copy_fwd", "y_to_int", "y_fbits", "y_bitsf", "y_sqrt", "y_int_trap", "y_len_stop",
        "y_sum", "y_dot", "y_scale", "y_axpy", "y_min_of", "y_max_of", "y_exp", "y_log", "y_sin", "y_cos", "y_pow",
        "y_mem_gc_all", "y_mem_gc_live", "y_mem_gc_last"]) { 0 }
    else { L_UNKNOWN }
};

def life_type(node: Node) -> Type { types.unfold(types.heap_type(node.line, node.col, node.k)) };

def life_ref(t: Type) -> bool {
    let k = t.k;
    k == K.tstr || k == K.tarr || k == K.tarrfix || k == K.trec || k == K.tunion || k == K.tmap || k == K.topt || k == K.tbigint || k == K.tfunc
};

def life_use(st: LifeSt, node: Node, name: str, bits: long, what: str) -> void {
    st.uses += { from: st.cur, name: name, bits: bits, repeat: st.loops > 0, region: st.regions > 0, heap: st.heap, process: st.process, line: node.line, col: node.col, what: what };
};

def life_alloc(st: LifeSt, node: Node, what: str) -> void { life_use(st, node, "", L_ALLOC, what); };

def life_list(st: LifeSt, nodes: [Node]) -> void {
    foreach (n in nodes) { life_walk(st, n); };
};

def life_fn(st: LifeSt, func: Func, name: str) -> long {
    let fi = len(st.fns);
    let params: [str] = [];
    for pi in 0..len(func.params) {
        params += if (types.unfold(func.ptypes[pi]).k == K.tfunc) { func.params[pi] } else { "" };
    };
    st.fns += { name: name, bits: if (len(func.label) > 0) { life_asm_bits(func.label) } else { 0 }, body: len(func.label) == 0, params: params };
    if (len(name) > 0) { parser.nameix_put(st.ix, name, fi); };
    let cur = st.cur;
    let loops = st.loops;
    let regions = st.regions;
    let heap = st.heap;
    let process = st.process;
    st.cur = fi;
    st.loops = 0;
    st.regions = 0;
    st.heap = false;
    st.process = false;
    if (len(func.label) == 0) { life_walk(st, func.body); };
    // Defaults are evaluated at a call too.
    life_list(st, func.defs);
    st.cur = cur;
    st.loops = loops;
    st.regions = regions;
    st.heap = heap;
    st.process = process;
    fi
};

def life_lambda(node: Node) -> str { "$life" + tostring(node.line) + ":" + tostring(node.col) };

def life_callback(st: LifeSt, arg: Node, at: Node, repeated: bool) -> void {
    let old = st.loops;
    if (repeated) { st.loops = old + 1; };
    let name = if (arg.k == K.func) { life_lambda(arg) } else if (arg.k == K.id) { let l: Leaf = arg; l.v } else { "" };
    life_use(st, at, name, if (len(name) == 0) { L_UNKNOWN } else { 0 }, "this callback");
    st.loops = old;
};

// Array lowering passes elements/indexes to the callback using its declared
// parameter types. Those calls may box or promote an argument per element.
def life_callback_args(st: LifeSt, arg: Node, actual: [Type], at: Node) -> void {
    let ft = life_type(arg);
    if (arg.k == K.func) {
        let f: Func = arg;
        ft = { k: K.tfunc, args: f.ptypes, ret: f.ret };
    };
    if (ft.k == K.tfunc) {
        let f: TFunc = ft;
        for i in 0..len(actual) {
            if (i < len(f.args) && types.alloc_conversion(actual[i], f.args[i], false)) {
                let old = st.loops;
                st.loops = old + 1;
                life_alloc(st, at, "this callback argument's conversion");
                st.loops = old;
            };
        };
    };
};

def life_loop(st: LifeSt, nodes: [Node]) -> void {
    st.loops = st.loops + 1;
    life_list(st, nodes);
    st.loops = st.loops - 1;
};

def life_walk(st: LifeSt, node: Node) -> void {
    if (types.heap_alloc(node)) { life_alloc(st, node, "this implicit allocating conversion"); };
    let k = node.k;
    if (k == K.decl) {
        let d: Decl = node;
        if (d.v.k == K.func) {
            let f: Func = d.v;
            life_fn(st, f, d.name);
            // A nested def may capture. A top-level def has a static label.
            if (st.cur > 0) { life_alloc(st, node, "this closure"); };
        } else { self(st, d.v); };
    } else if (k == K.func) {
        let f: Func = node;
        life_fn(st, f, life_lambda(node));
        st.values += life_lambda(node);
        life_alloc(st, node, "this closure");
    } else if (k == K.call) {
        let c: Call = node;
        life_call(st, c);
    } else if (k == K.kw_while) {
        let w: While = node;
        life_loop(st, [w.cond, w.body]);
    } else if (k == K.kw_for) {
        let f: For = node;
        self(st, f.init);
        life_loop(st, [f.cond, f.body, f.step]);
    } else if (k == K.kw_foreach) {
        let f: Foreach = node;
        self(st, f.iter);
        life_loop(st, [f.body]);
    } else if (k == K.forrange) {
        let f: ForRange = node;
        life_list(st, [f.lo, f.hi]);
        life_loop(st, [f.body]);
    } else {
        node_each_child(node, (child: Node) => life_walk(st, child));
        if (k == K.array || k == K.arrrep || k == K.rec || k == K.map || k == K.bstr || k == K.bignum || k == K.slice) {
            life_alloc(st, node, "this allocation");
        } else if (k == K.bin || k == K.un || k == K.narrow) {
            if (life_ref(life_type(node))) { life_alloc(st, node, "this allocating expression"); };
            if (k == K.bin) {
                let b: Bin = node;
                if ((life_type(b.l).k == K.tbigint) != (life_type(b.r).k == K.tbigint)) { life_alloc(st, node, "this bigint promotion"); };
                if (b.op == "in" && life_type(b.r).k == K.tstr) { life_alloc(st, node, "this string membership test"); };
            };
        } else if (k == K.incdec) {
            let a: IncDec = node;
            if (life_type(a.tgt).k == K.tbigint) { life_alloc(st, node, "this bigint increment"); };
        } else if (k == K.opassign) {
            let a: OpAssign = node;
            let t = life_type(a.tgt);
            // Array buffers double their capacity: all obsolete buffers
            // together are bounded by the live capacity. They need no GC.
            if (life_ref(t) && t.k != K.tarr && t.k != K.tarrfix) { life_alloc(st, node, "this growing or copying assignment"); };
        } else if (k == K.idxassign) {
            let a: IdxAssign = node;
            if (life_type(a.arr).k == K.tmap) { life_alloc(st, node, "this map insertion"); };
        } else if (k == K.index) {
            let a: Index = node;
            if (life_type(a.arr).k == K.tmap) { life_alloc(st, node, "this map read's option box"); };
        } else if (k == K.id) {
            if (life_type(node).k == K.tfunc) {
                let l: Leaf = node;
                st.values += l.v;
                life_alloc(st, node, "this function value");
            };
        };
    };
};

def life_call(st: LifeSt, c: Call) -> void {
    let callee = c.callee;
    let name = if (callee.k == K.id) { let l: Leaf = callee; l.v } else { "" };
    if (name == "region$" || name == "region$auto" || name == "heap$") {
        let regions = st.regions;
        let heap = st.heap;
        let process = st.process;
        st.process = process || (st.cur == 0 && escape.esc_process_region(c));
        st.regions = if (name == "heap$") { 0 } else { regions + 1 };
        st.heap = if (name == "heap$") { true } else { false };
        life_list(st, c.args);
        st.regions = regions;
        st.heap = heap;
        st.process = process;
        return;
    };
    if (len(name) > 0) {
        st.calls += { name: if (name == "self") { st.fns[st.cur].name } else { name }, args: c.args };
    };
    life_list(st, c.args);
    if (callee.k == K.dot) {
        let d: Dot = callee;
        life_walk(st, d.obj);
        let t = life_type(d.obj);
        if (t.k == K.tstr) {
            // Scalar string methods can hide work (KMP's failure array).
            if (life_ref(life_type(c)) || d.key == "count" || d.key == "contains" || d.key == "index_of" || d.key == "last_index_of") {
                life_alloc(st, c, "the string method '" + d.key + "'");
            };
        } else if (t.k == K.tarr || t.k == K.tarrfix) {
            if (d.key != "pop" && d.key != "shift" && d.key != "remove" && d.key != "push" && d.key != "unshift" && d.key != "insert") { life_alloc(st, c, "the array method '" + d.key + "'"); };
            if (d.key == "remove" && len(c.args) == 2) { life_alloc(st, c, "this removed array"); };
            // Callbacks can run once per element, even if the result is scalar.
            foreach (a in c.args) {
                if (life_type(a).k == K.tfunc || a.k == K.func) {
                    life_callback(st, a, c, true);
                    let elem = if (t.k == K.tarr) { let ar: TOf = t; ar.of } else { let ar: TFix = t; ar.of };
                    let actual: [Type] = [elem, { k: K.tlong }];
                    if (d.key == "sort" || d.key == "sorted") { actual = [elem, elem]; };
                    if (d.key == "reduce" && len(c.args) > 1) { actual = [life_type(c.args[1]), elem]; };
                    life_callback_args(st, a, actual, c);
                };
            };
        } else { life_use(st, c, "", L_UNKNOWN, "this indirect call"); };
    } else if (callee.k == K.func) {
        life_walk(st, callee);
        life_callback(st, callee, c, false);
    } else if (len(name) == 0) {
        life_walk(st, callee);
        life_use(st, c, "", L_UNKNOWN, "this indirect call");
    } else if (name == "self") {
        life_use(st, c, st.fns[st.cur].name, 0, "this recursive call");
    } else if (types.bind_kind(name) == "intrinsic" || types.bind_kind(name) == "") {
        if (name == "spawn" || name == "fork") {
            if (name == "spawn") { life_use(st, c, "", L_THREAD, "this thread"); };
            foreach (a in c.args) { life_callback(st, a, c, false); };
        }
        else if (name == "lock" || (name == "join" && len(c.args) == 1)) {
            foreach (a in c.args) {
                if (a.k == K.func || life_type(a).k == K.tfunc) { life_callback(st, a, c, false); };
            };
        } else if (name == "jmp_at") { life_use(st, c, "", L_UNKNOWN, "this indirect jump"); }
        else if (name == "os_call" || name == "syscall") {
            // Raw pointers and OS resources have an explicit lifetime API;
            // they are not objects managed by the Y allocator.
        } else if (name == "mutex" || name == "sem" || name == "input" || name == "readline"
            || name == "tostring" || name == "#fmt" || name == "some" || name == "range" || name == "keys" || name == "values"
            || name == "bytes" || name == "from_bytes" || name == "join" || name == "split" || name == "chr" || name == "trim"
            || name == "tolong" || name == "tofloat" || name == "index_of" || name == "last_index_of") {
            life_alloc(st, c, "the call to '" + name + "'");
        } else if (name == "print" || name == "puts" || name == "eputs") {
            foreach (a in c.args) {
                let t = life_type(a);
                if (types.output_alloc(name, t)) {
                    life_alloc(st, c, "this value's formatting");
                };
            };
        } else if (life_ref(life_type(c)) && name != "unwrap" && name != "opt$val" && name != "argv" && name != "ptr_from" && name != "push" && name != "prepend") {
            life_alloc(st, c, "the call to '" + name + "'");
        };
    } else {
        life_use(st, c, name, 0, "the call to '" + life_disp(name) + "'");
    };
};

// In a complete source program, propagate the effects of actual callbacks
// into function parameters. A function used as a value can receive unseen
// arguments, so its callback parameters remain unknown. Packed interfaces
// keep the conservative summary: external callers are not a closed program.
def life_bind_callbacks(st: LifeSt, at: Node) -> void {
    if (!st.closed) { return; };
    let nf = len(st.fns);
    let owners: [long] = [];
    let supplied: [bool] = [];
    for fi in 0..nf {
        foreach (p in st.fns[fi].params) {
            if (len(p) > 0 && parser.nameix_get(st.ix, p) < 0) {
                parser.nameix_put(st.ix, p, len(st.fns));
                st.fns += { name: p, bits: 0, body: false, params: [] };
                owners += fi;
                supplied += false;
            };
        };
    };
    foreach (c in st.calls) {
        let t = parser.nameix_get(st.ix, c.name);
        if (t >= 0 && t < nf) {
            let ps = st.fns[t].params;
            for pi in 0..len(ps) {
                if (len(ps[pi]) > 0) {
                    let p = parser.nameix_get(st.ix, ps[pi]);
                    st.cur = p;
                    let a = if (pi < len(c.args)) { c.args[pi] } else { at };
                    let name = if (pi >= len(c.args)) { "" } else if (a.k == K.func) { life_lambda(a) }
                        else if (a.k == K.id) { let l: Leaf = a; l.v } else { "" };
                    life_use(st, at, name, if (len(name) == 0) { L_UNKNOWN } else { 0 }, "this callback argument");
                    supplied[p - nf] = true;
                };
            };
        };
    };
    let exposed: [bool] = [];
    for fi in 0..nf { exposed += false; };
    foreach (name in st.values) {
        let fi = parser.nameix_get(st.ix, name);
        if (fi >= 0 && fi < nf) { exposed[fi] = true; };
    };
    for pi in 0..len(owners) {
        if (!supplied[pi] || exposed[owners[pi]]) { st.fns[nf + pi].bits = L_UNKNOWN; };
    };
    st.cur = 0;
};

def life_disp(name: str) -> str {
    let p = index_of(name, "$");
    if (p < 0) { name } else { name[:p] }
};

def life_map(bits: long, u: LifeUse, recursive: bool) -> long {
    let b = bits;
    if (u.process) { return b & (L_THREAD | L_UNKNOWN); };
    if (u.region) { b = b & ~(L_ALLOC | L_REPEAT | L_LOOP); };
    if (u.heap) {
        if ((b & L_ALLOC) != 0) { b = b | L_HEAP; };
        if ((b & L_REPEAT) != 0) { b = b | L_HREPEAT; };
        b = b & ~(L_ALLOC | L_REPEAT);
    };
    if (u.repeat || recursive) {
        if (u.repeat && (b & (L_ALLOC | L_HEAP)) != 0) { b = b | L_LOOP; };
        if ((b & L_ALLOC) != 0) { b = b | L_REPEAT; };
        if ((b & L_HEAP) != 0) { b = b | L_HREPEAT; };
    };
    b
};

// Versions before L5 lack compound-assignment result provenance. An old pack must never silently
// make an unknown call safe. The first six fields remain escape.y's format.
def life_decode(s: str) -> long {
    let p = split(s, "\t");
    if (len(p) >= 9 && p[6] == "L5") { life_num(p[7]) } else { L_UNKNOWN }
};

def life_num(s: str) -> long {
    let n = tolong(s);
    if (n == none) { L_UNKNOWN } else { unwrap(n) }
};

def life_analyze(stmts: [Node], names: [str], fx: [str], checked: bool, overrides: bool, closed: bool = false) -> [Diag] {
    let st: LifeSt = { fns: [{ name: "", bits: 0, body: false, params: [] }], ix: parser.nameix_new(256), uses: [], calls: [], values: [], cur: 0, loops: 0, regions: 0, heap: false, process: false, closed: closed };
    life_init = 0;
    for i in 0..len(names) {
        parser.nameix_put(st.ix, names[i], len(st.fns));
        st.fns += { name: names[i], bits: life_decode(fx[i]), body: false, params: [] };
        let p = split(fx[i], "\t");
        life_init = life_init | (if (len(p) >= 9 && p[6] == "L5") { life_num(p[8]) } else { L_UNKNOWN });
    };
    life_list(st, stmts);
    if (len(stmts) > 0) { life_bind_callbacks(st, stmts[0]); };
    if (overrides) {
        // A reserved y_ body may replace a runtime call hidden in an
        // intrinsic or another packed unit. Treat its invocation as repeated
        // rather than trusting the replaced primitive's allocation contract.
        for fi in len(names) + 1..len(st.fns) {
            let f = st.fns[fi];
            if (f.body && f.name[:2] == "y_" && len(stmts) > 0) {
                st.loops = 1;
                life_use(st, stmts[0], f.name, 0, "the runtime replacement '" + life_disp(f.name) + "'");
                st.loops = 0;
            };
        };
    };
    let outs: [[long]] = [];
    for i in 0..len(st.fns) { let a: [long] = []; outs += a; };
    let targets: [long] = [];
    foreach (u in st.uses) {
        let t = if (len(u.name) > 0) { parser.nameix_get(st.ix, u.name) } else { -1 };
        targets += t;
        if (t >= 0) { outs[u.from] += t; };
    };
    let cyc = lint.heap_sccs(outs);
    // Monotone bit sets: work backwards through the caller graph.
    let rev: [[long]] = [];
    let queue: [long] = [];
    let queued: [bool] = [];
    for i in 0..len(st.fns) { let a: [long] = []; rev += a; queue += i; queued += true; };
    for i in 0..len(st.uses) { if (targets[i] >= 0) { rev[targets[i]] += i; }; };
    // Seed each caller with its own sites, then revisit its callers on change.
    for i in 0..len(st.uses) {
        let u = st.uses[i];
        if (targets[i] < 0) {
            let b = if (len(u.name) > 0) { L_UNKNOWN } else { u.bits };
            st.fns[u.from].bits = st.fns[u.from].bits | life_map(b, u, cyc[u.from]);
        };
    };
    let qi = 0;
    while (qi < len(queue)) {
        let t = queue[qi];
        qi++;
        queued[t] = false;
        foreach (i in rev[t]) {
            let u = st.uses[i];
            let f = st.fns[u.from];
            let b = f.bits | life_map(st.fns[t].bits, u, cyc[u.from] && cyc[t]);
            if (b != f.bits) {
                f.bits = b;
                if (!queued[u.from]) { queued[u.from] = true; queue += u.from; };
            };
        };
    };
    let errors: [Diag] = [];
    foreach (u in st.uses) {
        if (u.from == 0 && (checked || u.process)) {
            let t = if (len(u.name) > 0) { parser.nameix_get(st.ix, u.name) } else { -1 };
            let bits = if (t >= 0) { st.fns[t].bits } else if (len(u.name) > 0) { L_UNKNOWN } else { u.bits };
            if ((life_map(bits, u, false) & L_BAD) != 0) {
                errors += { msg: "lifetime: cannot prove reclamation for " + u.what + "; use a region for temporary allocations or opt in with --gc=auto", line: u.line, col: u.col };
            };
        };
    };
    if (checked) {
        if ((life_init & L_BAD) != 0) {
            errors += { msg: "lifetime: cannot prove reclamation for an imported initializer (rebuild old packs); opt in with --gc=auto", line: 1, col: 1 };
        };
    };
    life_init = life_init | st.fns[0].bits;
    life_state = st;
    errors
};

def life_export(name: str) -> str {
    let i = parser.nameix_get(life_state.ix, name);
    "\tL5\t" + tostring(if (i >= 0) { life_state.fns[i].bits } else { L_UNKNOWN }) + "\t" + tostring(life_init)
};

def life_scratch() -> [str] {
    let names: [str] = [];
    foreach (f in life_state.fns) { if ((f.bits & L_LOOP) == 0) { names += f.name; }; };
    names
};

export { life_analyze, life_export, life_scratch };
