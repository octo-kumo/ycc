// codegen.y — emit C source from an AST (nested maps from parser.y).
// Targets the runtime.h ABI: YValue tagged union, y_mk_* constructors,
// y_scope_get/set, y_add/y_sub/... operators, GCC statement expressions.

// ── functional helpers ───────────────────────────────────────────────────
// (names avoid a leading underscore — Y identifiers can't start with '_')

def mapx_go(f, xs, i, acc) {
    if (i >= len(xs)) { acc } else { mapx_go(f, xs, i + 1, push(acc, f(xs[i]))) }
};
def mapx(f, xs) { mapx_go(f, xs, 0, []) };

def filterx_go(p, xs, i, acc) {
    if (i >= len(xs)) { acc }
    else if (p(xs[i])) { filterx_go(p, xs, i + 1, push(acc, xs[i])) }
    else { filterx_go(p, xs, i + 1, acc) }
};
def filterx(p, xs) { filterx_go(p, xs, 0, []) };

def mapix_go(f, n, i, acc) {
    if (i >= n) { acc } else { mapix_go(f, n, i + 1, push(acc, f(i))) }
};
def mapix(f, n) { mapix_go(f, n, 0, []) };

// ── C codegen string combinators ─────────────────────────────────────────

def gnu(body) -> str { "({ " + body + " })" };
def c_call(fn, args) -> str { fn + "(" + join(args, ", ") + ")" };
def fill(name, parts) -> str {
    join(mapix(def(i) { " " + name + "[" + tostring(i) + "] = " + parts[i] + ";" }, len(parts)), "")
};

// ── builtin registration table ───────────────────────────────────────────
// Each entry: [name, arity, closure]. closure is "NULL" for almost all;
// "scope" for global_get. The exec entry is filtered out when g_no_exec.
let BUILTINS = [
    ["print", 1, "NULL"], ["tostring", 1, "NULL"], ["typeof", 1, "NULL"],
    ["range", 1, "NULL"], ["readline", 0, "NULL"], ["puts", 1, "NULL"],
    ["split", 2, "NULL"], ["len", 1, "NULL"], ["trim", 1, "NULL"],
    ["exec", 1, "NULL"],
    ["tonum", 1, "NULL"], ["join", 2, "NULL"], ["push", 2, "NULL"],
    ["substr", 3, "NULL"], ["read_file", 1, "NULL"], ["write_file", 2, "NULL"],
    ["ord", 1, "NULL"], ["chr", 1, "NULL"],
    ["bytes_to_str", 1, "NULL"],
    ["ensure_runtime", 0, "NULL"], ["gen_embedded_runtime", 2, "NULL"],
    ["index_of", 2, "NULL"], ["arr_index_of", 2, "NULL"], ["last_index_of", 2, "NULL"],
    ["argv", 0, "NULL"], ["getenv", 1, "NULL"],
    ["tcp_listen", 1, "NULL"], ["tcp_accept", 1, "NULL"],
    ["tcp_read", 2, "NULL"], ["tcp_write", 2, "NULL"], ["tcp_close", 1, "NULL"],
    ["map_set", 3, "NULL"], ["map_get", 2, "NULL"],
    ["global_get", 1, "scope"],
    ["scope_new", 1, "NULL"], ["scope_def", 3, "NULL"], ["scope_find", 2, "NULL"],
    ["scope_get", 2, "NULL"], ["scope_set", 3, "NULL"],
];

def reg(b) -> str {
    "    y_scope_set(scope, \"" + b[0] + "\", y_mk_func(y_builtin_" + b[0] +
    ", " + tostring(b[1]) + ", " + b[2] + "));\n"
};

// ── helpers ──────────────────────────────────────────────────────────────

def esc(s: str) -> str {
    // escape a string for embedding in a C string literal.
    // Direct concatenation (one malloc+memcpy per char) — far cheaper than the
    // push-into-array-then-join approach, which is O(n^2) with high constants
    // (realloc without geometric growth + a substr allocation per char) and
    // hangs on large strings like the embedded runtime.c.
    let buf = "";
    let i = 0;
    let n = len(s);
    while (i < n) {
        let c = substr(s, i, 1);
        let o = ord(c);
        if (c == "\\") { buf = buf + "\\\\"; }
        else if (c == "\"") { buf = buf + "\\\""; }
        else if (c == "\n") { buf = buf + "\\n"; }
        else if (c == "\t") { buf = buf + "\\t"; }
        else if (c == "\r") { buf = buf + "\\r"; }
        else if (o < 32 || o > 126) {
            // octal escape
            let d2 = o / 64;
            let d1 = (o / 8) % 8;
            let d0 = o % 8;
            buf = buf + "\\" + tostring(d2) + tostring(d1) + tostring(d0);
        } else {
            buf = buf + c;
        };
        i = i + 1;
    };
    buf
};

def op_fn(op: str) -> str {
    if (op == "+") { "y_add" }
    else if (op == "-") { "y_sub" }
    else if (op == "*") { "y_mul" }
    else if (op == "/") { "y_div" }
    else if (op == "%") { "y_mod" }
    else if (op == "<") { "y_lt" }
    else if (op == ">") { "y_gt" }
    else if (op == "<=") { "y_lte" }
    else if (op == ">=") { "y_gte" }
    else if (op == "==") { "y_eq" }
    else if (op == "!=") { "y_neq" }
    else if (op == "&&") { "y_and" }
    else if (op == "||") { "y_or" }
    else if (op == "::") { "y_cons" }
    else { "NULL" }
};

// ── code generation state ────────────────────────────────────────────────
// We accumulate function definitions in a list and emit them before main.

let g_funcs = [];   // list of C function definition strings
let g_fid = 0;      // unique function id counter
let g_no_exec = false;  // when true, omit the exec() builtin from emitted C

def set_no_exec(v: bool) { g_no_exec = v; };

def next_fid() -> long {
    let id = g_fid;
    g_fid = g_fid + 1;
    id
};

// ── expression emission ──────────────────────────────────────────────────
// Each emit_* returns a C expression string (malloc'd by the runtime's
// string concat, but in Y we just build strings).

def emit_expr(node) -> str {
    let k = node.k;
    if (k == "num") {
        // detect float: contains '.'
        if (index_of(node.v, ".") >= 0) {
            "y_mk_float(" + node.v + ")"
        } else {
            "y_mk_long(" + node.v + ")"
        }
    } else if (k == "str") {
        "y_mk_str(\"" + esc(node.v) + "\")"
    } else if (k == "id") {
        "y_clone(y_scope_get(scope, \"" + node.v + "\"))"
    } else if (k == "bool") {
        if (node.v == "true") { "y_mk_bool(1)" } else { "y_mk_bool(0)" }
    } else if (k == "null") {
        "y_mk_null()"
    } else if (k == "un") {
        let operand = emit_expr(node.e);
        if (node.op == "-") {
            // arithmetic negation
            "y_neg(" + operand + ")"
        } else {
            // logical NOT
            "({ YValue *_u = " + operand + "; " +
            "if (_u->type != Y_BOOL) { fprintf(stderr, \"runtime error: '!' requires bool\\n\"); exit(1); } " +
            "YValue *_r = y_mk_bool(!_u->data.b); y_free(_u); _r; })"
        }
    } else if (k == "bin") {
        let fn = op_fn(node.op);
        let l = emit_expr(node.l);
        let r = emit_expr(node.r);
        fn + "(" + l + ", " + r + ")"
    } else if (k == "call") {
        emit_call(node)
    } else if (k == "index") {
        let idx = emit_expr(node.idx);
        // Fast path: when indexing a plain identifier (e.g. toks[i] in a tight
        // parser loop), borrow the array from scope instead of cloning the
        // whole array on every access. y_arr_index_borrow does NOT free the
        // array (scope still owns it); it only frees idx and clones the elem.
        if (node.arr.k == "id") {
            "y_arr_index_borrow(y_scope_get(scope, \"" + node.arr.v + "\"), " + idx + ")"
        } else {
            let arr = emit_expr(node.arr);
            "y_arr_index(" + arr + ", " + idx + ")"
        }
    } else if (k == "slice") {
        let arr = emit_expr(node.arr);
        // null lo -> 0, null hi -> LONG_MIN (sentinel for "to the end")
        let lo = if (node.lo.k == "null") { "y_mk_long(0)" } else { emit_expr(node.lo) };
        let hi = if (node.hi.k == "null") { "y_mk_long(-9223372036854775807)" } else { emit_expr(node.hi) };
        "y_arr_slice(" + arr + ", " + lo + ", " + hi + ")"
    } else if (k == "array") {
        emit_array(node)
    } else if (k == "map") {
        emit_map(node)
    } else if (k == "func") {
        emit_func_expr(node)
    } else if (k == "if") {
        emit_if(node)
    } else if (k == "while") {
        emit_while(node)
    } else if (k == "for") {
        emit_for(node)
    } else if (k == "foreach") {
        emit_foreach(node)
    } else if (k == "forrange") {
        emit_forrange(node)
    } else if (k == "block") {
        emit_block(node)
    } else if (k == "decl") {
        emit_decl(node)
    } else if (k == "assign") {
        let v = emit_expr(node.v);
        "({ YValue *_v = " + v + "; y_scope_set(scope, \"" + node.name + "\", _v); y_clone(_v); })"
    } else if (k == "idxassign") {
        let idx = emit_expr(node.idx);
        let v = emit_expr(node.v);
        // For a simple variable target, mutate the scope's array in place
        // (non-cloned, refcount 1) so y_arr_set's COW writes through. A complex
        // target falls back to a clone (best-effort; rare in practice).
        if (node.arr.k == "id") {
            "({ YValue *_a = y_scope_get(scope, \"" + node.arr.v + "\"); YValue *_i = " + idx + "; YValue *_v = " + v + "; " +
            "y_arr_set(_a, _i, _v); y_mk_null(); })"
        } else {
            let arr = emit_expr(node.arr);
            "({ YValue *_a = " + arr + "; YValue *_i = " + idx + "; YValue *_v = " + v + "; " +
            "y_arr_set(_a, _i, _v); y_mk_null(); })"
        }
    } else if (k == "dotassign") {
        let v = emit_expr(node.v);
        // For a simple variable target, mutate the scope's map in place
        // (non-cloned, refcount 1) so map_set's COW writes through. A complex
        // target falls back to a clone (best-effort; rare in practice).
        if (node.obj.k == "id") {
            "({ YValue *_o = y_scope_get(scope, \"" + node.obj.v + "\"); YValue *_v = " + v + "; " +
            "y_builtin_map_set(NULL, (YValue *[]){ _o, y_mk_str(\"" + esc(node.key) + "\"), _v }, 3); y_mk_null(); })"
        } else {
            let obj = emit_expr(node.obj);
            "({ YValue *_o = " + obj + "; YValue *_v = " + v + "; " +
            "y_builtin_map_set(NULL, (YValue *[]){ _o, y_mk_str(\"" + esc(node.key) + "\"), _v }, 3); y_mk_null(); })"
        }
    } else if (k == "ret") {
        // return is handled by the block emitter wrapping in _result
        emit_expr(node.e)
    } else if (k == "dot") {
        emit_dot(node)
    } else {
        "y_mk_null() /* unknown: " + k + " */"
    }
};

def emit_dot(node) -> str {
    let obj = emit_expr(node.obj);
    let key = node.key;
    "({ YValue *_m = " + obj + "; " +
    "YValue *_v = y_map_get(_m, \"" + key + "\"); " +
    "if (!_v) { fprintf(stderr, \"runtime error: key '" + key + "' not found\\n\"); exit(1); } " +
    "YValue *_r = y_clone(_v); y_free(_m); _r; })"
};

def emit_call(node) -> str {
    let callee = emit_expr(node.callee);
    let n = len(node.args);
    if (n == 0) {
        c_call("y_call", [callee, "NULL", "0"])
    } else {
        let as = mapx(emit_expr, node.args);
        gnu("YValue *_a[" + tostring(n) + "];" + fill("_a", as) +
            " YValue *_r = y_call(" + callee + ", _a, " + tostring(n) + "); " +
            "for (int _i = 0; _i < " + tostring(n) + "; _i++) if (_a[_i]) y_free(_a[_i]); _r;")
    }
};

def emit_array(node) -> str {
    let n = len(node.elems);
    if (n == 0) {
        "y_mk_arr(NULL, 0)"
    } else {
        gnu("YValue **_e = malloc(sizeof(YValue*) * " + tostring(n) + ");" +
            fill("_e", mapx(emit_expr, node.elems)) + " y_mk_arr(_e, " + tostring(n) + ");")
    }
};

def emit_map(node) -> str {
    let keys = node.keys;
    let vals = node.vals;
    let n = len(keys);
    if (n == 0) {
        "y_mk_map(NULL, 0)"
    } else {
        let init = "";
        let i = 0;
        while (i < n) {
            let ki = keys[i];
            let vi = vals[i];
            let ve = emit_expr(vi);
            init = init + " _m[" + tostring(i) + "].key = \"" + esc(ki) + "\"; " +
                   "_m[" + tostring(i) + "].value = " + ve + ";";
            i = i + 1;
        };
        "({ YMapEntry *_m = malloc(sizeof(YMapEntry) * " + tostring(n) + ");" + init + " " +
        "y_mk_map(_m, " + tostring(n) + "); })"
    }
};

def emit_func_expr(node) -> str {
    // emit a function definition into g_funcs, return a reference to it
    let fid = next_fid();
    let cname = "yfn_" + tostring(fid);
    let params = node.params;
    let nparams = len(params);
    let body = emit_block(node.body);
    // build the C function
    let param_bind = "";
    let i = 0;
    while (i < nparams) {
        let pi = params[i];
        // bind arg into the function's OWN scope (set_local, not set — set
        // walks up the scope chain and would overwrite a recursive caller's
        // parameter of the same name, corrupting self-recursion).
        // NULL the slot so the call site's y_free is a no-op.
        param_bind = param_bind + "    y_scope_set_local(scope, \"" + pi + "\", args[" + tostring(i) + "]); args[" + tostring(i) + "] = NULL;\n";
        i = i + 1;
    };
    let fdef = "static YValue *" + cname + "(YScope *closure, YValue **args, size_t argc) {\n" +
        "    (void)argc;\n" +
        "    YScope *scope = malloc(sizeof(YScope));\n" +
        "    y_scope_init(scope, closure);\n" +
        param_bind +
        "    y_scope_set_local(scope, \"self\", y_mk_func(" + cname + ", " + tostring(nparams) + ", scope));\n" +
        "    YValue *_result = " + body + ";\n" +
        "    y_scope_release(scope);\n" +
        "    return _result;\n" +
        "}\n";
    g_funcs = push(g_funcs, fdef);
    "y_mk_func(" + cname + ", " + tostring(nparams) + ", scope)"
};

def emit_if(node) -> str {
    let c = emit_expr(node.cond);
    let tb = emit_block(node.then);
    let has_else = node.has_else;
    if (has_else == true) {
        let eb = emit_expr(node.els);
        "({ YValue *_c = " + c + "; YValue *_r; " +
        "if (_c->data.b) { _r = " + tb + "; } else { _r = " + eb + "; } _r; })"
    } else {
        "({ YValue *_c = " + c + "; YValue *_r = y_mk_null(); " +
        "if (_c->data.b) { _r = " + tb + "; } _r; })"
    }
};

def emit_while(node) -> str {
    let c = emit_expr(node.cond);
    let b = emit_block(node.body);
    "({ YValue *_last = y_mk_null(); " +
    "while (1) { YValue *_c = " + c + "; " +
    "if (!_c->data.b) { y_free(_c); break; } y_free(_c); " +
    "y_free(_last); _last = " + b + "; } _last; })"
};

def emit_for(node) -> str {
    let init = emit_expr(node.init);
    let c = emit_expr(node.cond);
    let step = emit_expr(node.step);
    let b = emit_block(node.body);
    "({ " + init + "; YValue *_last = y_mk_null(); " +
    "while (1) { YValue *_c = " + c + "; " +
    "if (!_c->data.b) { y_free(_c); break; } y_free(_c); " +
    "y_free(_last); _last = " + b + "; " + step + "; } _last; })"
};

def emit_foreach(node) -> str {
    let iter = emit_expr(node.iter);
    let b = emit_block(node.body);
    let name = node.name;
    "({ YValue *_arr = " + iter + "; " +
    "YScope *_outer = scope; " +
    "YScope *scope = malloc(sizeof(YScope)); " +
    "y_scope_init(scope, _outer); " +
    "YValue *_last = y_mk_null(); " +
    "for (size_t _i = 0; _i < _arr->data.arr->count; _i++) { " +
    "y_scope_set(scope, \"" + name + "\", y_clone(_arr->data.arr->elements[_i])); " +
    "y_free(_last); _last = " + b + "; } y_scope_release(scope); _last; })"
};

def emit_forrange(node) -> str {
    let lo = emit_expr(node.lo);
    let hi = emit_expr(node.hi);
    let b = emit_block(node.body);
    let name = node.name;
    "({ YValue *_sv = " + lo + "; YValue *_ev = " + hi + "; " +
    "long _s = _sv->data.l; long _e = _ev->data.l; " +
    "y_free(_sv); y_free(_ev); " +
    "YScope *_outer = scope; " +
    "YScope *scope = malloc(sizeof(YScope)); " +
    "y_scope_init(scope, _outer); " +
    "YValue *_last = y_mk_null(); " +
    "for (long _i = _s; _i < _e; _i++) { " +
    "y_scope_set(scope, \"" + name + "\", y_mk_long(_i)); " +
    "y_free(_last); _last = " + b + "; } y_scope_release(scope); _last; })"
};

def emit_block(node) -> str {
    let n = len(node.stmts);
    if (n == 0) {
        "y_mk_null()"
    } else {
        let parts = mapx(emit_expr, node.stmts);
        // Non-final statements are freed; the block result is cloned out before
        // the scope is released (it may reference a scope value).
        let chunks = [];
        let j = 0;
        while (j < n - 1) {
            chunks = push(chunks, " y_free((YValue *)(" + parts[j] + "));");
            j = j + 1;
        };
        gnu("YScope *_outer = scope; YScope *scope = malloc(sizeof(YScope)); " +
            "y_scope_init(scope, _outer);" + join(chunks, "") + " YValue *_r = " + parts[n-1] + "; " +
            "YValue *_ret = y_clone(_r); y_scope_release(scope); _ret;")
    }
};

def emit_decl(node) -> str {
    let v = emit_expr(node.v);
    // Wrap so the declaration yields a value (y_scope_set is void; a block's
    // last statement must produce a value for the GCC statement expression).
    "({ YValue *_v = " + v + "; y_scope_set(scope, \"" + node.name + "\", _v); y_clone(_v); })"
};

// ── top-level program emission ───────────────────────────────────────────

def emit_program(ast) -> str {
    // reset state
    g_funcs = [];
    g_fid = 0;

    // emit the main body — accumulate chunks in a list, join once (O(n) not O(n^2))
    let body = join(mapx(def(s) { "    " + emit_expr(s) + ";\n" }, ast.stmts), "");

    // assemble the full C program as a chunk list
    let parts = [];
    parts = push(parts, "/* Generated by ycc — Y-lang to C compiler */\n");
    parts = push(parts, "#include \"runtime.h\"\n\n");

    // function definitions
    let nf = len(g_funcs);
    if (nf > 0) {
        parts = push(parts, "/* ── function definitions ── */\n\n");
        parts = push(parts, join(mapx(def(f) { f + "\n" }, g_funcs), ""));
    };

    // main
    parts = push(parts, "/* ── entry point ── */\n\n");
    parts = push(parts, "int main(int argc, char **argv) {\n");
    parts = push(parts, "    y_set_argv(argc, argv);\n");
    parts = push(parts, "    YScope *scope = malloc(sizeof(YScope));\n");
    parts = push(parts, "    y_scope_init(scope, NULL);\n\n");
    parts = push(parts, "    /* builtins */\n");
    let bs = if (g_no_exec) { filterx(def(b) { b[0] != "exec" }, BUILTINS) } else { BUILTINS };
    parts = push(parts, join(mapx(reg, bs), ""));
    parts = push(parts, "\n");
    parts = push(parts, body);
    parts = push(parts, "\n    return 0;\n");
    parts = push(parts, "}\n");
    join(parts, "")
};

export { emit_program, set_no_exec };
