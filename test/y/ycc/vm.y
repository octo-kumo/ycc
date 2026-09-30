// vm.y — a tree-walking interpreter for Y, written in Y.
//
// Evaluates the AST produced by ycc's parser (see parser.y for node shapes).
// Values are native Y values passed around as-is, so the VM reuses Y's own
// operator semantics by construction. Closures are maps capturing their
// defining scope ID.
//
// Entry point: vm_run(ast, names, vals) — runs a parsed program block.

// ── scopes ───────────────────────────────────────────────────────────────
// Scopes are managed by the C runtime (scope_new/scope_def/scope_get/scope_set
// builtins), which use real mutable YScopes. This avoids Y's COW semantics
// making nested-structure mutation unreliable. Scopes are referenced by
// integer ID; closures capture their defining scope ID. The VM calls these
// builtins directly (no Y wrappers, to avoid name-shadowing recursion).

// ── return signalling ────────────────────────────────────────────────────
// A `return` sets these globals; the enclosing function call consumes them.

let g_ret = false;
let g_retval = null;

// ── truthiness ───────────────────────────────────────────────────────────

def truthy(v) -> bool {
    let t = typeof(v);
    if (t == "bool") { v }
    else if (t == "null") { false }
    else if (t == "long") { v != 0 }
    else if (t == "float") { v != 0.0 }
    else { true }
};

// ── evaluation ───────────────────────────────────────────────────────────

def eval(node, scope) {
    let k = node.k;
    if (k == "num") {
        tonum(node.v)
    } else if (k == "str") {
        node.v
    } else if (k == "bool") {
        node.v == "true"
    } else if (k == "null") {
        null
    } else if (k == "id") {
        let v = scope_get(scope, node.v);
        if (v == null) {
            print("runtime error: undefined variable '" + node.v + "'");
        };
        v
    } else if (k == "array") {
        let out = [];
        let i = 0;
        let elems = node.elems;
        while (i < len(elems)) {
            out += eval(elems[i], scope);
            i = i + 1;
        };
        out
    } else if (k == "map") {
        let m = {};
        let i = 0;
        let keys = node.keys;
        let vals = node.vals;
        while (i < len(keys)) {
            m = map_set(m, keys[i], eval(vals[i], scope));
            i = i + 1;
        };
        m
    } else if (k == "func") {
        { k: "closure", params: node.params, body: node.body, env: scope }
    } else if (k == "un") {
        eval_un(node, scope)
    } else if (k == "bin") {
        eval_bin(node, scope)
    } else if (k == "call") {
        eval_call(node, scope)
    } else if (k == "index") {
        let arr = eval(node.arr, scope);
        let idx = eval(node.idx, scope);
        arr[idx]
    } else if (k == "slice") {
        eval_slice(node, scope)
    } else if (k == "dot") {
        let obj = eval(node.obj, scope);
        map_get(obj, node.key)
    } else if (k == "if") {
        eval_if(node, scope)
    } else {
        exec(node, scope)
    }
};

def eval_un(node, scope) {
    let v = eval(node.e, scope);
    if (node.op == "-") { 0 - v } else { !truthy(v) }
};

def eval_bin(node, scope) {
    let op = node.op;
    if (op == "&&") {
        let l = eval(node.l, scope);
        if (truthy(l)) { eval(node.r, scope) } else { l }
    } else if (op == "||") {
        let l = eval(node.l, scope);
        if (truthy(l)) { l } else { eval(node.r, scope) }
    } else {
        let l = eval(node.l, scope);
        let r = eval(node.r, scope);
        if (op == "+") { l + r }
        else if (op == "-") { l - r }
        else if (op == "*") { l * r }
        else if (op == "/") { l / r }
        else if (op == "%") { l % r }
        else if (op == "==") { l == r }
        else if (op == "!=") { l != r }
        else if (op == "<") { l < r }
        else if (op == ">") { l > r }
        else if (op == "<=") { l <= r }
        else if (op == ">=") { l >= r }
        else { print("runtime error: unknown operator '" + op + "'"); null }
    }
};

def eval_slice(node, scope) {
    let arr = eval(node.arr, scope);
    let n = len(arr);
    let lo = 0;
    let hi = n;
    if (node.lo.k != "null") { lo = eval(node.lo, scope); };
    if (node.hi.k != "null") { hi = eval(node.hi, scope); };
    if (lo < 0) { lo = 0; };
    if (hi > n) { hi = n; };
    let out = [];
    let i = lo;
    while (i < hi) {
        out += arr[i];
        i = i + 1;
    };
    out
};

def eval_if(node, scope) {
    if (truthy(eval(node.cond, scope))) {
        eval(node.then, scope)
    } else if (node.has_else) {
        eval(node.els, scope)
    } else {
        null
    }
};

def eval_call(node, scope) {
    let callee = eval(node.callee, scope);
    let argv = [];
    let cargs = node.args;
    let i = 0;
    while (i < len(cargs)) {
        argv += eval(cargs[i], scope);
        i = i + 1;
    };
    let ct = typeof(callee);
    if (substr(ct, 0, 1) == "{") {
        // Map type — check if it's a closure
        if (callee.k == "closure") { call_closure(callee, argv) }
        else { print("runtime error: calling a non-function"); null }
    } else if (index_of(ct, "->") >= 0) {
        // Function type: (<inferred>)-><inferred> or similar
        call_native(callee, argv)
    } else {
        print("runtime error: calling a non-function (typeof = " + ct + ")");
        null
    }
};

def call_closure(clos, argv) {
    let scope = scope_new(clos.env);
    let i = 0;
    let np = len(clos.params);
    let cparams = clos.params;
    while (i < np) {
        let arg = null;
        if (i < len(argv)) { arg = argv[i]; };
        scope_def(scope, cparams[i], arg);
        i = i + 1;
    };
    scope_def(scope, "self", clos);
    g_ret = false;
    g_retval = null;
    let last = exec(clos.body, scope);
    let result = last;
    if (g_ret) { result = g_retval; };
    g_ret = false;
    g_retval = null;
    result
};

// Native builtins are real Y functions; dispatch by arg count.
def call_native(fn, argv) {
    let n = len(argv);
    if (n == 0) { fn() }
    else if (n == 1) { fn(argv[0]) }
    else if (n == 2) { fn(argv[0], argv[1]) }
    else if (n == 3) { fn(argv[0], argv[1], argv[2]) }
    else { print("runtime error: too many args to builtin"); null }
};

// ── statement execution ──────────────────────────────────────────────────

def exec(node, scope) {
    let k = node.k;
    if (k == "block") {
        let last = null;
        let i = 0;
        let ns = len(node.stmts);
        let bstmts = node.stmts;
        while (i < ns) {
            if (!g_ret) {
                last = exec(bstmts[i], scope);
            };
            i = i + 1;
        };
        last
    } else if (k == "decl") {
        let v = eval(node.v, scope);
        scope_def(scope, node.name, v);
        v
    } else if (k == "assign") {
        let v = eval(node.v, scope);
        scope_set(scope, node.name, v);
        v
    } else if (k == "idxassign") {
        let arr = eval(node.arr, scope);
        let idx = eval(node.idx, scope);
        let v = eval(node.v, scope);
        arr[idx] = v;
        v
    } else if (k == "ret") {
        g_retval = eval(node.e, scope);
        g_ret = true;
        g_retval
    } else if (k == "while") {
        let last = null;
        while (truthy(eval(node.cond, scope))) {
            if (!g_ret) { last = exec(node.body, scope); } else { last = null; };
            if (g_ret) { last = null; };
        };
        last
    } else if (k == "forrange") {
        let lo = eval(node.lo, scope);
        let hi = eval(node.hi, scope);
        let inner = scope_new(scope);
        scope_def(inner, node.name, lo);
        let last = null;
        let i = lo;
        while (i < hi) {
            if (!g_ret) {
                scope_set(inner, node.name, i);
                last = exec(node.body, inner);
            };
            i = i + 1;
        };
        last
    } else if (k == "foreach") {
        let coll = eval(node.iter, scope);
        let inner = scope_new(scope);
        scope_def(inner, node.name, null);
        let last = null;
        let i = 0;
        let n = len(coll);
        while (i < n) {
            if (!g_ret) {
                scope_set(inner, node.name, coll[i]);
                last = exec(node.body, inner);
            };
            i = i + 1;
        };
        last
    } else if (k == "for") {
        let inner = scope_new(scope);
        if (node.init.k != "null") { exec(node.init, inner); };
        let last = null;
        let go = true;
        while (go) {
            if (node.cond.k != "null") { go = truthy(eval(node.cond, inner)); };
            if (go) {
                if (!g_ret) {
                    last = exec(node.body, inner);
                    if (node.step.k != "null") { exec(node.step, inner); };
                } else { go = false; };
            };
        };
        last
    } else {
        eval(node, scope)
    }
};

// ── entry point ──────────────────────────────────────────────────────────

def vm_run(ast, names, vals) {
    let scope = scope_new(-1);
    let i = 0;
    while (i < len(names)) {
        scope_def(scope, names[i], vals[i]);
        i = i + 1;
    };
    exec(ast, scope);
    null
};

export { vm_run, eval, exec };
