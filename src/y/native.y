// native.y — typed AST -> x86_64 assembly (AT&T/GAS) for the native backend.
// Usage:
//   import types from "./types.y";
//   import native from "./native.y";
//   let r = native.emit_program(ast);  // { ok, asm, errors }
//   // r.ok: asm holds a complete .s file (cc-assemblable). else errors.
//
// Pipeline: types.check_program (fatal) -> collect defs (incl. hoisting of
// capture-free nested defs = baby lambda lifting) -> frame layout -> emit.
// Every value is 8 bytes (long/bool/ptr/str-address); expression values in
// %rax; locals at negative rbp offsets; Y-function args pushed on the stack.
//
// Portability: this file stays in the portable Y subset (parsed by the C
// compiler): no `x.y[i]` chains, no dot-assign, no `&&`-guarded field access,
// no variable named `self`.

import arch from "./arch_x64.y";
import types from "./types.y";
import rename from "./rename.y";

// ── native import resolution ───────────────────────────────────────────
// Unlike the C backend (which wraps modules in IIFEs returning maps —
// impossible without a heap), the native splicer INLINES module sources:
// `import io from "path"` splices the module's text in place and drops its
// `export` line. References `io.x` are rewritten to plain `x` by
// strip_namespaces (AST-level, so strings are untouched). Module top-levels
// must be defs; duplicate def names across the splice are a loud error.

def native_resolve(src: str, base_dir: str, depth: long) -> { src: str, imports: [str] } {
    // NOTE: seen-threading wrapper (see native_resolve_seen): asm.y imports
    // enc64 as `enc` AND elf.y imports enc64 as `elfenc`; without dedup the
    // encoder splices twice and every enc64 def collides (find_dup is fatal).
    let r = native_resolve_seen(src, base_dir, depth, []);
    { src: r.src, imports: r.imports }
};

// Collapse "/./" segments so the same file resolves to one key no matter
// how deep the import nesting is (base dirs accumulate "/." per level:
// "ycc/././enc64.y" vs "ycc/./././enc64.y"). Deterministic, so same-file
// inputs always yield the same key (sufficient for seen-dedup).
def norm_path(p: str) -> str {
    let parts = split(p, "/");
    let out = [];
    let i = 0;
    while (i < len(parts)) {
        // NOTE: bound once — `parts[i]` inline misparses on the C backend.
        let seg = parts[i];
        if (seg == ".") {
            0
        } else {
            out = push(out, seg);
            0
        };
        i = i + 1;
        0
    };
    join(out, "/")
};

def seen_has(seen: [str], full: str) -> bool {
    let i = 0;
    let found = false;
    while (i < len(seen)) {
        // NOTE: bound once — `seen[i]` inline misparses on the C backend.
        let e = seen[i];
        if (e == full) {
            found = true;
            0
        } else { 0 };
        i = i + 1;
        0
    };
    found
};

def native_resolve_seen(src: str, base_dir: str, depth: long, seen: [str]) -> { src: str, imports: [str], seen: [str] } {
    if (depth > 32) {
        puts("error: native import depth exceeded (cycle?)\n");
        { src: "", imports: [], seen: seen }
    } else {
        let lines = split(src, "\n");
        let out_lines = [];
        let imports = [];
        let i = 0;
        let n = len(lines);
        while (i < n) {
            let line = lines[i];
            let trimmed = trim(line);
            if (substr(trimmed, 0, 7) == "import ") {
                let rest = substr(trimmed, 7, len(trimmed) - 7);
                let from_idx = index_of(rest, " from ");
                if (from_idx >= 0) {
                    let name = trim(substr(rest, 0, from_idx));
                    let path_part = trim(substr(rest, from_idx + 6, len(rest) - from_idx - 6));
                    if (substr(path_part, len(path_part) - 1, 1) == ";") {
                        path_part = substr(path_part, 0, len(path_part) - 1);
                        0
                    } else { 0 };
                    let path = substr(path_part, 1, len(path_part) - 2);
                    // NOTE: normalized (see norm_path): nested base dirs
                    // accumulate "/." segments, so raw joins of the same file
                    // differ per depth and seen-dedup would never hit.
                    let full = norm_path(base_dir + "/" + path);
                    if (substr(path, 0, 1) == "/") { full = norm_path(path); 0; } else { 0 };
                    let mod_src = read_file(full);
                    if (mod_src == null) {
                        puts("error: cannot open import '" + path + "' (resolved to '" + full + "')\n");
                        out_lines = push(out_lines, line);
                        0
                    } else if (seen_has(seen, full)) {
                        // NOTE: already spliced (see native_resolve note):
                        // record the namespace name (strip_ns needs it) but
                        // do NOT splice the text a second time.
                        imports = push(imports, name);
                        0
                    } else {
                        seen = push(seen, full);
                        let last_slash = last_index_of(path, "/");
                        let mod_dir = base_dir;
                        if (last_slash >= 0) {
                            mod_dir = base_dir + "/" + substr(path, 0, last_slash);
                            0
                        } else { 0 };
                        // mod_src is str? (read_file returns null on missing
                        // file); the null case exited above, so unwrap here.
                        let mod_src2 = unwrap(mod_src);
                        let sub = native_resolve_seen(mod_src2, mod_dir, depth + 1, seen);
                        // NOTE: each bound once — `x.y` on a call result
                        // misparses on the C backend (it reads `f().y`
                        // as `f(.y)`).
                        let subsrc = sub.src;
                        let subns = sub.imports;
                        let subseen = sub.seen;
                        seen = subseen;
                        // splice the module text inline (its own imports first)
                        let sub_lines = split(subsrc, "\n");
                        let k = 0;
                        while (k < len(sub_lines)) {
                            out_lines = push(out_lines, sub_lines[k]);
                            k = k + 1;
                            0
                        };
                        let m = 0;
                        while (m < len(subns)) {
                            imports = push(imports, subns[m]);
                            m = m + 1;
                            0
                        };
                        imports = push(imports, name);
                        0
                    };
                    0
                } else {
                    out_lines = push(out_lines, line);
                    0
                };
                0
            } else {
                // NOTE: no empty if-arms here — the C backend corrupts the
                // heap on empty blocks. Export lines are dropped (defs are
                // spliced; uses are rewritten by strip_namespaces).
                if (substr(trimmed, 0, 7) != "export ") {
                    out_lines = push(out_lines, line);
                    0
                } else { 0 };
                0
            };
            i = i + 1;
            0
        };
        { src: join(out_lines, "\n"), imports: imports, seen: seen }
    }
};

def is_ns(name: str, imports: [str]) -> bool {
    let i = 0;
    let found = false;
    while (i < len(imports)) {
        if (imports[i] == name) { found = true; 0; } else { 0; };
        i = i + 1;
        0
    };
    found
};

// Identity with a declared {k: str} return: normalizes multi-shape
// expression arms (strip_*/infer rebuilds a different node kind per arm,
// which strict branch-teq rejects) into unknown-shaped flows. Callers read
// .k/.line/.col directly; deeper reads unify quietly (tcompat law). The
// RUNTIME value passes through untouched (same node object).
def normnode(anode) -> { k: str } { anode };

// strip_namespaces: dot(NAME, key) with NAME an import namespace -> id(key).
// Full AST rebuild (only dot nodes change, but uniform rebuild is simplest).

def strip_list(nodes: [{ k: str }], imports: [str]) -> [{ k: str }] {
    let out = [];
    let i = 0;
    while (i < len(nodes)) {
        out = push(out, strip_ns(nodes[i], imports));
        i = i + 1;
    };
    out
};

def strip_ns(node, imports: [str]) -> { k: str } {
    // NOTE: kind bound once — `node.k` inline in a call misparses on the
    // C backend (it reads `f(x.k)` as `f((x).k)`... actually as `f(.k)`).
    let k = node.k;
    if (k == "dot") {
        let dobj = node.obj;
        let obj = strip_ns(dobj, imports);
        let okey = node.key;
        let oline = node.line;
        let ocol = node.col;
        if (obj.k == "id") {
            let ov = obj.v;
            if (is_ns(ov, imports)) {
                normnode({ k: "id", v: okey, line: oline, col: ocol })
            } else {
                normnode({ k: "dot", obj: obj, key: okey, line: oline, col: ocol })
            }
        } else {
            normnode({ k: "dot", obj: obj, key: okey, line: oline, col: ocol })
        }
    } else if (k == "un") {
        normnode({ k: "un", op: node.op, e: strip_ns(node.e, imports), line: node.line, col: node.col })
    } else if (k == "addr" || k == "deref") {
        normnode({ k: k, e: strip_ns(node.e, imports), line: node.line, col: node.col })
    } else if (k == "bin") {
        normnode({ k: "bin", op: node.op, l: strip_ns(node.l, imports), r: strip_ns(node.r, imports), line: node.line, col: node.col })
    } else if (k == "call") {
        normnode({ k: "call", callee: strip_ns(node.callee, imports), args: strip_list(node.args, imports), line: node.line, col: node.col })
    } else if (k == "if") {
        normnode({ k: "if", cond: strip_ns(node.cond, imports), then: strip_ns(node.then, imports), els: strip_ns(node.els, imports), has_else: node.has_else, line: node.line, col: node.col })
    } else if (k == "while") {
        normnode({ k: "while", cond: strip_ns(node.cond, imports), body: strip_ns(node.body, imports), line: node.line, col: node.col })
    } else if (k == "block") {
        normnode({ k: "block", stmts: strip_list(node.stmts, imports), line: node.line, col: node.col })
    } else if (k == "decl") {
        strip_decl(node, imports)
    } else if (k == "func") {
        normnode({ k: "func", params: node.params, ptypes: node.ptypes, ret: node.ret, body: strip_ns(node.body, imports), line: node.line, col: node.col })
    } else if (k == "assign") {
        normnode({ k: "assign", name: node.name, v: strip_ns(node.v, imports), line: node.line, col: node.col })
    } else if (k == "store") {
        normnode({ k: "store", p: strip_ns(node.p, imports), v: strip_ns(node.v, imports), line: node.line, col: node.col })
    } else if (k == "ret") {
        normnode({ k: "ret", e: strip_ns(node.e, imports), line: node.line, col: node.col })
    } else if (k == "array") {
        normnode({ k: "array", elems: strip_list(node.elems, imports), line: node.line, col: node.col })
    } else if (k == "arrrep") {
        normnode({ k: "arrrep", v: strip_ns(node.v, imports), n: node.n, line: node.line, col: node.col })
    } else if (k == "map") {
        normnode({ k: "map", keys: node.keys, vals: strip_list(node.vals, imports), line: node.line, col: node.col })
    } else if (k == "index") {
        normnode({ k: "index", arr: strip_ns(node.arr, imports), idx: strip_ns(node.idx, imports), line: node.line, col: node.col })
    } else if (k == "slice") {
        normnode({ k: "slice", arr: strip_ns(node.arr, imports), lo: strip_ns(node.lo, imports), hi: strip_ns(node.hi, imports), line: node.line, col: node.col })
    } else if (k == "idxassign") {
        normnode({ k: "idxassign", arr: strip_ns(node.arr, imports), idx: strip_ns(node.idx, imports), v: strip_ns(node.v, imports), line: node.line, col: node.col })
    } else if (k == "dotassign") {
        normnode({ k: "dotassign", obj: strip_ns(node.obj, imports), key: node.key, v: strip_ns(node.v, imports), line: node.line, col: node.col })
    } else if (k == "foreach") {
        normnode({ k: "foreach", name: node.name, iter: strip_ns(node.iter, imports), body: strip_ns(node.body, imports), line: node.line, col: node.col })
    } else if (k == "forrange") {
        normnode({ k: "forrange", name: node.name, lo: strip_ns(node.lo, imports), hi: strip_ns(node.hi, imports), body: strip_ns(node.body, imports), line: node.line, col: node.col })
    } else if (k == "for") {
        normnode({ k: "for", init: strip_ns(node.init, imports), cond: strip_ns(node.cond, imports), step: strip_ns(node.step, imports), body: strip_ns(node.body, imports), line: node.line, col: node.col })
    } else {
        normnode(node)
    }
};

def strip_decl(node, imports: [str]) -> { k: str } {
    if (node.kind == "def") {
        normnode({ k: "decl", kind: "def", name: node.name, v: strip_ns(node.v, imports), line: node.line, col: node.col })
    } else {
        normnode({ k: "decl", kind: node.kind, name: node.name, typ: node.typ, v: strip_ns(node.v, imports), line: node.line, col: node.col })
    }
};

// ── emit state ─────────────────────────────────────────────────────────
// st = { out, rodata, uid, fuid, loc, env, slots,
//        self_label, end_label, fns, bodies }
// env: FLAT list of {name, kind, off, label, typ} — names are unique
// post-rename, so no scopes or shadowing. kind: "local"|"param"|"func".

def st_new() -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    { out: [], rodata: [], uid: 1, fuid: 0, loc: 1, env: [],
      slots: 0, self_label: "", end_label: "", fns: [], bodies: [] }
};

def emit(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, line: str) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    { out: push(st.out, line), rodata: st.rodata, uid: st.uid,
      fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots,
      self_label: st.self_label, end_label: st.end_label, fns: st.fns,
      bodies: st.bodies }
};

def next_uid(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }) -> { st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, uid: long } {
    let u = st.uid;
    st = { out: st.out, rodata: st.rodata, uid: st.uid + 1,
      fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots,
      self_label: st.self_label, end_label: st.end_label, fns: st.fns,
      bodies: st.bodies };
    { st: st, uid: u }
};

def next_loc(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }) -> { st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, lbl: str } {
    let n = st.loc;
    let lbl = arch.arch_loc_label(st.fuid, n);
    st = { out: st.out, rodata: st.rodata, uid: st.uid,
      fuid: st.fuid, loc: st.loc + 1, env: st.env, slots: st.slots,
      self_label: st.self_label, end_label: st.end_label, fns: st.fns,
      bodies: st.bodies };
    { st: st, lbl: lbl }
};

// ── string escaping for GAS .string ────────────────────────────────────

def esc_asm(s: str) -> str {
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
        else if (o < 32 || o > 126) {
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

// ── flat environment ───────────────────────────────────────────────────

def env_find(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, name: str) -> { name: str, kind: str, off: long, label: str, typ: { k: str } } {
    // Miss marker: kind "none". Real entries have name/kind/off/label/typ
    // but NO k field — never test e.k.
    let env = st.env;
    let i = 0;
    let found = { name: "", kind: "none", off: 0, label: "", typ: { k: "tnone" } };
    while (i < len(env)) {
        let e = env[i];
        if (e.name == name) {
            found = e;
            0
        } else { 0; };
        i = i + 1;
        0
    };
    found
};

def env_define(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, name: str, kind: str, off: long, label: str, typ) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let env = push(st.env, { name: name, kind: kind, off: off, label: label, typ: typ });
    { out: st.out, rodata: st.rodata, uid: st.uid,
      fuid: st.fuid, loc: st.loc, env: env, slots: st.slots,
      self_label: st.self_label, end_label: st.end_label, fns: st.fns,
      bodies: st.bodies }
};

// ── mini type inference (for print dispatch) ───────────────────────────
// The checker already validated everything; this mirrors it just enough to
// pick y_print_long / y_print_bool / y_print_cstr.

def infer(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { k: str } {
    let k = node.k;
    if (k == "num") { { k: "tlong" } }
    else if (k == "str") { { k: "tstr" } }
    else if (k == "bool") { { k: "tbool" } }
    else if (k == "null") { { k: "tnull" } }
    else if (k == "id") {
        if (node.v == "self") { { k: "tfunc" } } else {
            let e = env_find(st, node.v);
            if (e.kind == "none") {
                if (node.v == "none") { normnode({ k: "topt", of: { k: "tunk" } }) } else { { k: "tunk" } }
            } else { e.typ }
        }
    } else if (k == "un") {
        if (node.op == "-") { { k: "tlong" } } else { { k: "tbool" } }
    } else if (k == "bin") {
        let op = node.op;
        if (op == "+" || op == "-" || op == "*" || op == "/" || op == "%") {
            if (op == "+" && (infer(st, node.l).k == "tstr" || infer(st, node.r).k == "tstr")) {
                { k: "tstr" }
            } else {
                { k: "tlong" }
            }
        } else {
            { k: "tbool" }
        }
    } else if (k == "addr") {
        normnode({ k: "tptr", to: infer(st, node.e) })
    } else if (k == "arrrep") {
        normnode({ k: "tarrfix", of: infer(st, node.v), n: node.n })
    } else if (k == "array") {
        let elems = node.elems;
        if (len(elems) == 0) {
            normnode({ k: "tarr", of: { k: "tunk" } })
        } else {
            normnode({ k: "tarr", of: infer(st, elems[0]) })
        }
    } else if (k == "index") {
        // checker guarantees a plain array id; elem type from env
        if (node.arr.k == "id") {
            let e = env_find(st, node.arr.v);
            if (e.kind == "none") {
                { k: "tunk" }
            } else if (e.typ.k == "tarrfix" || e.typ.k == "tarr") {
                e.typ.of
            } else {
                { k: "tunk" }
            }
        } else {
            { k: "tunk" }
        }
    } else if (k == "deref") {
        let t = infer(st, node.e);
        if (t.k == "tptr") { t.to } else { { k: "tunk" } }
    } else if (k == "call") {
        infer_call(st, node)
    } else if (k == "if") {
        infer(st, node.then)
    } else if (k == "block") {
        infer_block(st, node)
    } else if (k == "decl") {
        infer_decl(st, node)
    } else if (k == "assign") {
        infer(st, node.v)
    } else if (k == "map") {
        // record literal: field types from the values (checker validated).
        // NOTE: each bound once — `x.y[i]` chains misparse on the C VM.
        let melems = node.vals;
        let mkeys = node.keys;
        if (len(melems) == 0) {
            normnode({ k: "trec", fields: [] })
        } else {
            let mfields = [];
            let mi = 0;
            while (mi < len(melems)) {
                let mf = infer(st, melems[mi]);
                // NOTE: bound once — `x.y[i]` chains misparse on the C VM.
                let mk = mkeys[mi];
                mfields = push(mfields, { name: mk, typ: mf });
                mi = mi + 1;
            };
            normnode({ k: "trec", fields: mfields })
        }
    } else if (k == "dot") {
        // field read: static index into the trec (checker validated).
        let dobj = node.obj;
        let dt = infer(st, dobj);
        if (dt.k == "trec") {
            let found = false;
            let ftyp = { k: "tunk" };
            let dfs = dt.fields;
            let di = 0;
            while (di < len(dfs)) {
                let df = dfs[di];
                // NOTE: :str binding (see teq note in types.y): df flows
                // from bare values (tunk), so a direct `==` would compare
                // string POINTERS; annotated let forces content compare.
                let dfn: str = df.name;
                if (dfn == node.key) {
                    found = true;
                    ftyp = df.typ;
                    0
                } else { 0; };
                di = di + 1;
            };
            if (found) { ftyp } else { { k: "tunk" } }
        } else {
            { k: "tunk" }
        }
    } else if (k == "store") {
        infer(st, node.v)
    } else if (k == "while") {
        { k: "tnull" }
    } else if (k == "ret") {
        infer(st, node.e)
    } else {
        { k: "tunk" }
    }
};

def infer_call(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { k: str } {
    if (node.callee.k != "id") {
        { k: "tunk" }
    } else {
        let name = node.callee.v;
        if (name == "print") {
            { k: "tnull" }
        } else if (name == "syscall") {
            { k: "tlong" }
        } else if (name == "len") {
            { k: "tlong" }
        } else if (name == "is_some") {
            { k: "tbool" }
        } else if (name == "unwrap") {
            // unwrap(x): payload type when x is statically an option.
            let uargs = node.args;
            if (len(uargs) != 1) { { k: "tunk" } } else {
                let ut = infer(st, uargs[0]);
                if (ut.k == "topt") { ut.of } else { { k: "tunk" } }
            }
        } else if (name == "some") {
            // some(x): option of x's type.
            let sargs = node.args;
            if (len(sargs) != 1) { { k: "topt", of: { k: "tunk" } } } else {
                { k: "topt", of: infer(st, sargs[0]) }
            }
        } else if (name == "substr" || name == "trim" || name == "chr" || name == "join" || name == "tostring") {
            { k: "tstr" }
        } else if (name == "read_file") {
            // str? (option): a missing file yields null at runtime
            // (callers null-check with `== null`, then unwrap).
            // Matches types.y (read_file -> str?).
            { k: "topt", of: { k: "tstr" } }
        } else if (name == "tonum" || name == "ord" || name == "index_of" || name == "last_index_of") {
            { k: "tlong" }
        } else if (name == "split" || name == "argv") {
            { k: "tarr", of: { k: "tstr" } }
        } else if (name == "write_file") {
            { k: "tbool" }
        } else if (name == "write_bytes") {
            { k: "tbool" }
        } else if (name == "puts" || name == "exit") {
            { k: "tnull" }
        } else {
            let e = env_find(st, name);
            if (e.kind == "none") {
                { k: "tunk" }
            } else if (e.typ.k == "tfunc") {
                e.typ.ret
            } else {
                { k: "tunk" }
            }
        }
    }
};

def infer_block(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { k: str } {
    let stmts = node.stmts;
    if (len(stmts) == 0) {
        { k: "tnull" }
    } else {
        infer(st, stmts[len(stmts) - 1])
    }
};

def infer_decl(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { k: str } {
    if (node.kind == "def") {
        { k: "tfunc", args: [], ret: { k: "tnull" } }
    } else {
        // NOTE: nested ifs — the C VM evaluates `&&` eagerly.
        if (node.typ.k == "tnone") {
            infer(st, node.v)
        } else {
            node.typ
        }
    }
};

// ── feature-use scan (for conditional prologue) ───────────────────────
// Walk the renamed AST for calls the _start prologue must serve: argv()
// needs y_argv_init to materialize the [str] array from the raw stack.
// Everything else (y_alloc, y_print_*, ...) is position-independent.
// Returns { argv: bool }.

def uses_scan_block(stmts: [{ k: str }], out: { argv: bool }) -> { argv: bool } {
    let i = 0;
    while (i < len(stmts)) {
        out = uses_scan_node(stmts[i], out);
        i = i + 1;
    };
    out
};

def uses_scan_node(node, out: { argv: bool }) -> { argv: bool } {
    let k = node.k;
    if (k == "call") {
        // scan callee + args (argv() could nest inside an argument).
        // NOTE: each bound once — `node.callee.k` inline misparses on the
        // C backend (reads `f(x.k)` as `f(.k)`).
        let ncallee = node.callee;
        let nargs = node.args;
        let found = out;
        if (ncallee.k == "id") {
            if (ncallee.v == "argv") {
                found = { argv: true };
                0
            } else { 0; };
            0
        } else { 0; };
        let o2 = uses_scan_node(ncallee, found);
        uses_scan_block(nargs, o2)
    } else if (k == "un") {
        uses_scan_node(node.e, out)
    } else if (k == "bin") {
        uses_scan_node(node.r, uses_scan_node(node.l, out))
    } else if (k == "addr" || k == "deref") {
        uses_scan_node(node.e, out)
    } else if (k == "if") {
        uses_scan_node(node.els, uses_scan_node(node.then, uses_scan_node(node.cond, out)))
    } else if (k == "while") {
        uses_scan_node(node.body, uses_scan_node(node.cond, out))
    } else if (k == "block") {
        uses_scan_block(node.stmts, out)
    } else if (k == "decl") {
        uses_scan_node(node.v, out)
    } else if (k == "func") {
        uses_scan_node(node.body, out)
    } else if (k == "assign") {
        uses_scan_node(node.v, out)
    } else if (k == "store") {
        uses_scan_node(node.v, uses_scan_node(node.p, out))
    } else if (k == "ret") {
        uses_scan_node(node.e, out)
    } else if (k == "array") {
        uses_scan_block(node.elems, out)
    } else if (k == "arrrep") {
        uses_scan_node(node.v, out)
    } else if (k == "map") {
        uses_scan_block(node.vals, out)
    } else if (k == "index") {
        uses_scan_node(node.idx, uses_scan_node(node.arr, out))
    } else if (k == "slice") {
        uses_scan_node(node.hi, uses_scan_node(node.lo, uses_scan_node(node.arr, out)))
    } else if (k == "idxassign") {
        uses_scan_node(node.v, uses_scan_node(node.idx, uses_scan_node(node.arr, out)))
    } else if (k == "dotassign") {
        uses_scan_node(node.v, uses_scan_node(node.obj, out))
    } else if (k == "foreach") {
        uses_scan_node(node.body, uses_scan_node(node.iter, out))
    } else if (k == "forrange") {
        uses_scan_node(node.body, uses_scan_node(node.hi, uses_scan_node(node.lo, out)))
    } else if (k == "for") {
        uses_scan_node(node.body, uses_scan_node(node.step, uses_scan_node(node.cond, uses_scan_node(node.init, out))))
    } else {
        out
    }
};

// ── def collection (incl. hoisting) ────────────────────────────────────
// Walk blocks/ifs/whiles/func-bodies; every named def and every let-bound
// anonymous def becomes a top-level function (they capture nothing — the
// checker proved it). Returns [{name, func}].

def collect_from_block(stmts: [{ k: str }], out: [{ name: str, func: { k: str } }]) -> [{ name: str, func: { k: str } }] {
    let i = 0;
    while (i < len(stmts)) {
        out = collect_from_node(stmts[i], out);
        i = i + 1;
    };
    out
};

def collect_from_node(node, out: [{ name: str, func: { k: str } }]) -> [{ name: str, func: { k: str } }] {
    let k = node.k;
    if (k == "decl") {
        if (node.kind == "def") {
            out = push(out, { name: node.name, func: node.v });
            out = collect_from_node(node.v, out);
            0
        } else {
            if (node.v.k == "func") {
                out = push(out, { name: node.name, func: node.v });
                0
            } else { 0; };
            out = collect_from_node(node.v, out);
            0
        }
    } else if (k == "func") {
        out = collect_from_block(node.body.stmts, out);
        0
    } else if (k == "if") {
        out = collect_from_node(node.then, out);
        if (node.has_else) {
            out = collect_from_node(node.els, out);
            0
        } else { 0; };
        0
    } else if (k == "while") {
        out = collect_from_node(node.body, out);
        0
    } else if (k == "block") {
        out = collect_from_block(node.stmts, out);
        0
    } else { 0; };
    out
};

// ── expression emission (value in %rax) ────────────────────────────────

def gen(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }],     bodies: [str] } {
    let k = node.k;
    if (k == "num") {
        emit(st, "    mov $" + node.v + ", %rax")
    } else if (k == "bool") {
        if (node.v == "true") {
            emit(st, "    mov $1, %rax")
        } else {
            emit(st, "    xor %eax, %eax")
        }
    } else if (k == "str") {
        let r = next_uid(st);
        st = r.st;
        let lbl = arch.arch_str_label(r.uid);
        // header object: [len, data..., NUL]; value = header address.
        // NOTE: push-chain over a let-bound [] (not a literal): the
        // checker rejects heterogeneous array literals ([str, long,
        // str]) AND pushes onto a direct [] literal; pushes onto a
        // let-bound [] unify quietly and the runtime value is identical.
        let rod0 = [];
        rod0 = push(rod0, lbl);
        rod0 = push(rod0, tostring(len(node.v)));
        rod0 = push(rod0, esc_asm(node.v));
        let rod = push(st.rodata, rod0);
        st = { out: st.out, rodata: rod, uid: st.uid,
          fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots,
          self_label: st.self_label, end_label: st.end_label, fns: st.fns,
          bodies: st.bodies };
        emit(st, "    lea " + lbl + "(%rip), %rax")
    } else if (k == "null") {
        emit(st, "    xor %eax, %eax")
    } else if (k == "id") {
        gen_id(st, node)
    } else if (k == "un") {
        gen_un(st, node)
    } else if (k == "addr") {
        gen_addr(st, node)
    } else if (k == "array") {
        gen_array(st, node)
    } else if (k == "deref") {
        st = gen(st, node.e);
        emit(st, "    mov (%rax), %rax")
    } else if (k == "bin") {
        gen_bin(st, node)
    } else if (k == "call") {
        gen_call(st, node)
    } else if (k == "if") {
        gen_if(st, node)
    } else if (k == "while") {
        gen_while(st, node)
    } else if (k == "block") {
        gen_block(st, node)
    } else if (k == "decl") {
        gen_decl(st, node)
    } else if (k == "assign") {
        gen_assign(st, node)
    } else if (k == "index") {
        gen_index(st, node)
    } else if (k == "idxassign") {
        gen_idxassign(st, node)
    } else if (k == "dotassign") {
        gen_dotassign(st, node)
    } else if (k == "dot") {
        gen_dot(st, node)
    } else if (k == "map") {
        // map literal anywhere (let/call-arg): heap address in %rax.
        gen_map(st, node)
    } else if (k == "store") {
        gen_store(st, node)
    } else if (k == "ret") {
        st = gen(st, node.e);
        emit(st, "    jmp " + st.end_label)
    } else {
        // Unreachable: the checker rejects everything else.
        emit(st, "    # INTERNAL: unhandled " + k + " (checker drift)")
    }
};

def gen_id(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    if (node.v == "self") {
        // Bare `self` as a value: only legal in discarded positions
        // (the checker rejects every typed use). Emit null-ish zero.
        emit(st, "    xor %eax, %eax  # bare self (discarded)")
    } else if (node.v == "none") {
        // The empty option (checker gives it typeof from context).
        emit(st, "    xor %eax, %eax")
    } else {
        let e = env_find(st, node.v);
        if (e.kind == "none") {
            emit(st, "    # INTERNAL: undefined " + node.v)
        } else if (e.kind == "func") {
            emit(st, "    # INTERNAL: bare function value " + node.v)
        } else {
            emit(st, "    mov " + tostring(e.off) + "(%rbp), %rax")
        }
    }
};

def gen_un(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    st = gen(st, node.e);
    if (node.op == "-") {
        emit(st, "    neg %rax")
    } else {
        emit(st, "    xor $1, %rax")
    }
};

def gen_addr(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    // Checker guarantees plain ids, or id-rooted index into an array.
    if (node.e.k == "index") {
        gen_elem_addr(st, node.e)
    } else {
        let e = env_find(st, node.e.v);
        emit(st, "    lea " + tostring(e.off) + "(%rbp), %rax")
    }
};

// Address of element arr[idx] in %rax (bounds-trapped). Works for both
// array kinds: fixed (frame SIB) and heap (header load + SIB).
def gen_elem_addr(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let e = env_find(st, node.arr.v);
    st = gen(st, node.idx);
    st = emit(st, "    push %rax");
    st = emit(st, "    mov " + tostring(e.off) + "(%rbp), %rax");
    st = emit(st, "    pop %rcx");
    st = emit(st, "    test %rcx, %rcx");
    st = emit(st, "    js y_oob");
    if (e.typ.k == "tarrfix") {
        st = emit(st, "    cmp $" + tostring(e.typ.n) + ", %rcx");
        st = emit(st, "    jge y_oob");
        emit(st, "    lea 16(%rax,%rcx,8), %rax")
    } else {
        st = emit(st, "    mov (%rax), %rdx");
        st = emit(st, "    cmp %rdx, %rcx");
        st = emit(st, "    jge y_oob");
        emit(st, "    lea 16(%rax,%rcx,8), %rax")
    }
};

def gen_bin(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let op = node.op;
    // Lazy &&/||: short-circuit jumps, not eager and/or (the right operand
    // must not run when the left already decides).
    if (op == "&&") {
        gen_logic(st, node, false)
    } else if (op == "||") {
        gen_logic(st, node, true)
    } else {
        gen_bin_rest(st, node)
    }
};

// Short-circuit logic: value is 0/1; the right operand only evaluates when
// the left operand does not already decide the result.
//   a && b : test a -> jz F; test b -> jz F; 1; jmp E; F: 0; E:
//   a || b : test a -> jnz T; test b -> jnz T; 0; jmp E; T: 1; E:
def gen_logic(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node, is_or: bool) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let rT = next_loc(st);
    st = rT.st;
    let rF = next_loc(st);
    st = rF.st;
    let rE = next_loc(st);
    st = rE.st;
    st = gen(st, node.l);
    st = emit(st, "    test %rax, %rax");
    if (is_or) {
        st = emit(st, "    jnz " + rT.lbl);
        0
    } else { 0; };
    if (is_or) {
        0
    } else {
        st = emit(st, "    jz " + rF.lbl);
        0
    };
    st = gen(st, node.r);
    st = emit(st, "    test %rax, %rax");
    if (is_or) {
        st = emit(st, "    jnz " + rT.lbl);
        0
    } else { 0; };
    if (is_or) {
        0
    } else {
        st = emit(st, "    jz " + rF.lbl);
        0
    };
    if (is_or) {
        0
    } else {
        st = emit(st, "    mov $1, %rax");
        st = emit(st, "    jmp " + rE.lbl);
        0
    };
    if (is_or) {
        st = emit(st, "    xor %eax, %eax");
        st = emit(st, "    jmp " + rE.lbl);
        st = emit(st, rT.lbl + ":");
        st = emit(st, "    mov $1, %rax");
        0
    } else { 0; };
    if (is_or) {
        0
    } else {
        st = emit(st, rF.lbl + ":");
        st = emit(st, "    xor %eax, %eax");
        0
    };
    st = emit(st, rE.lbl + ":")
};

// AUTO-STRINGIFY `+`: when a string meets a non-string, stringify the other
// side (y_long_tostr / y_bool_tostr) and concatenate — the same semantics
// the C runtime's y_add gives. tstr+tstr is a plain concat; tstr+tunk falls
// back to the raw pointer concat (the old behavior) since the runtime type
// is unknown statically.
def gen_cat(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node, lt: { k: str }, rt: { k: str }) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    // NOTE: y_long_tostr / y_bool_tostr take ONE STACK ARG (push; call;
    // add $8) — gen_tostring's pattern. y_str_cat takes two stack args.
    if (lt.k == "tstr") {
        if (rt.k == "tstr") {
            st = gen_push_args(st, [node.l, node.r]);
            st = emit(st, "    call y_str_cat");
            st = emit(st, "    add $16, %rsp")
        } else if (rt.k == "tlong") {
            st = gen(st, node.l);
            st = emit(st, "    push %rax");
            st = gen(st, node.r);
            st = emit(st, "    push %rax");
            st = emit(st, "    call y_long_tostr");
            st = emit(st, "    add $8, %rsp");
            st = emit(st, "    push %rax");
            st = emit(st, "    call y_str_cat");
            st = emit(st, "    add $16, %rsp")
        } else if (rt.k == "tbool") {
            st = gen(st, node.l);
            st = emit(st, "    push %rax");
            st = gen(st, node.r);
            st = emit(st, "    push %rax");
            st = emit(st, "    call y_bool_tostr");
            st = emit(st, "    add $8, %rsp");
            st = emit(st, "    push %rax");
            st = emit(st, "    call y_str_cat");
            st = emit(st, "    add $16, %rsp")
        } else {
            st = gen_push_args(st, [node.l, node.r]);
            st = emit(st, "    call y_str_cat");
            st = emit(st, "    add $16, %rsp")
        };
        0
    } else { 0; };
    if (!(lt.k == "tstr")) {
        if (lt.k == "tlong") {
            st = gen(st, node.l);
            st = emit(st, "    push %rax");
            st = emit(st, "    call y_long_tostr");
            st = emit(st, "    add $8, %rsp");
            st = emit(st, "    push %rax");
            st = gen(st, node.r);
            st = emit(st, "    push %rax");
            st = emit(st, "    call y_str_cat");
            st = emit(st, "    add $16, %rsp")
        } else if (lt.k == "tbool") {
            st = gen(st, node.l);
            st = emit(st, "    push %rax");
            st = emit(st, "    call y_bool_tostr");
            st = emit(st, "    add $8, %rsp");
            st = emit(st, "    push %rax");
            st = gen(st, node.r);
            st = emit(st, "    push %rax");
            st = emit(st, "    call y_str_cat");
            st = emit(st, "    add $16, %rsp")
        } else {
            st = gen_push_args(st, [node.l, node.r]);
            st = emit(st, "    call y_str_cat");
            st = emit(st, "    add $16, %rsp")
        };
        0
    } else { 0; };
    st
};

def gen_bin_rest(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let op = node.op;
    let lt = infer(st, node.l);
    let rt = infer(st, node.r);
    if (op == "+" && (lt.k == "tstr" || rt.k == "tstr")) {
        gen_cat(st, node, lt, rt)
    } else if ((op == "==" || op == "!=") && (lt.k == "tstr" || rt.k == "tstr")) {
        st = gen_push_args(st, [node.l, node.r]);
        st = emit(st, "    call y_str_eq");
        st = emit(st, "    add $16, %rsp");
        if (op == "!=") {
            emit(st, "    xor $1, %rax")
        } else {
            st
        }
    } else {
    st = gen(st, node.l);
    st = emit(st, "    push %rax");
    st = gen(st, node.r);
    st = emit(st, "    mov %rax, %rcx");
    st = emit(st, "    pop %rax");
    if (op == "+") {
        emit(st, "    add %rcx, %rax")
    } else if (op == "-") {
        emit(st, "    sub %rcx, %rax")
    } else if (op == "*") {
        emit(st, "    imul %rcx, %rax")
    } else if (op == "/") {
        st = emit(st, "    test %rcx, %rcx");
        st = emit(st, "    jz y_div_zero");
        st = emit(st, "    cqo");
        emit(st, "    idiv %rcx")
    } else if (op == "%") {
        st = emit(st, "    test %rcx, %rcx");
        st = emit(st, "    jz y_div_zero");
        st = emit(st, "    cqo");
        st = emit(st, "    idiv %rcx");
        emit(st, "    mov %rdx, %rax")
    } else if (op == "<") {
        st = emit(st, "    cmp %rcx, %rax");
        st = emit(st, "    setl %al");
        emit(st, "    movzbq %al, %rax")
    } else if (op == ">") {
        st = emit(st, "    cmp %rcx, %rax");
        st = emit(st, "    setg %al");
        emit(st, "    movzbq %al, %rax")
    } else if (op == "<=") {
        st = emit(st, "    cmp %rcx, %rax");
        st = emit(st, "    setle %al");
        emit(st, "    movzbq %al, %rax")
    } else if (op == ">=") {
        st = emit(st, "    cmp %rcx, %rax");
        st = emit(st, "    setge %al");
        emit(st, "    movzbq %al, %rax")
    } else if (op == "==") {
        st = emit(st, "    cmp %rcx, %rax");
        st = emit(st, "    sete %al");
        emit(st, "    movzbq %al, %rax")
    } else if (op == "!=") {
        st = emit(st, "    cmp %rcx, %rax");
        st = emit(st, "    setne %al");
        emit(st, "    movzbq %al, %rax")
    } else if (op == "&&") {
        emit(st, "    and %rcx, %rax")
    } else {
        emit(st, "    or %rcx, %rax")
    }
    }
};

// ── calls ──────────────────────────────────────────────────────────────
// Linux syscall arg regs (in order): rdi, rsi, rdx, r10, r8, r9.

def syscall_reg(i: long) -> str {
    if (i == 0) { "%rdi" }
    else if (i == 1) { "%rsi" }
    else if (i == 2) { "%rdx" }
    else if (i == 3) { "%r10" }
    else if (i == 4) { "%r8" }
    else { "%r9" }
};

def gen_push_args(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, args: [{ k: str }]) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let i = 0;
    while (i < len(args)) {
        st = gen(st, args[i]);
        st = emit(st, "    push %rax");
        i = i + 1;
    };
    st
};

def gen_call(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let callee = node.callee;
    if (callee.k != "id") {
        emit(st, "    # INTERNAL: indirect call (checker drift)")
    } else {
        let name = callee.v;
        if (name == "print") {
            gen_print(st, node)
        } else if (name == "syscall") {
            gen_syscall(st, node)
        } else if (name == "len") {
            gen_len(st, node)
        } else if (name == "push") {
            gen_push(st, node)
        } else if (name == "some") {
            gen_some(st, node)
        } else if (name == "is_some") {
            gen_is_some(st, node)
        } else if (name == "unwrap") {
            gen_unwrap(st, node)
        } else if (name == "substr") {
            gen_substr(st, node)
        } else if (name == "trim") {
            gen_trim(st, node)
        } else if (name == "ord") {
            gen_ord(st, node)
        } else if (name == "chr") {
            gen_chr(st, node)
        } else if (name == "tonum") {
            gen_tonum(st, node)
        } else if (name == "tostring") {
            gen_tostring(st, node)
        } else if (name == "index_of") {
            gen_index_of(st, node, false)
        } else if (name == "last_index_of") {
            gen_index_of(st, node, true)
        } else if (name == "join") {
            gen_join(st, node)
        } else if (name == "split") {
            gen_split(st, node)
        } else if (name == "puts") {
            gen_puts(st, node)
        } else if (name == "exit") {
            gen_exit(st, node)
        } else if (name == "argv") {
            gen_argv(st, node)
        } else if (name == "read_file") {
            gen_read_file(st, node)
        } else if (name == "write_file") {
            gen_write_file(st, node)
        } else if (name == "write_bytes") {
            gen_write_bytes(st, node)
        } else {
            gen_direct(st, node, name)
        }
    }
};

def gen_print(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let args = node.args;
    st = gen(st, args[0]);
    let t = infer(st, args[0]);
    st = emit(st, "    mov %rax, %rdi");
    if (t.k == "tbool") {
        st = emit(st, "    call y_print_bool");
        emit(st, "    xor %eax, %eax")
    } else if (t.k == "tstr") {
        st = emit(st, "    call y_print_hstr");
        emit(st, "    xor %eax, %eax")
    } else {
        st = emit(st, "    call y_print_long");
        emit(st, "    xor %eax, %eax")
    }
};

def gen_syscall(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let args = node.args;
    // args[0] is the number; rest are a1..a6. Push all, pop into regs.
    st = gen_push_args(st, args);
    let n = len(args) - 1;
    let i = n;
    while (i >= 1) {
        st = emit(st, "    pop " + syscall_reg(i - 1));
        // a str flows in as its header; the kernel wants the data bytes.
        let at = infer(st, args[i]);
        if (at.k == "tstr") {
            st = emit(st, "    add $8, " + syscall_reg(i - 1));
            0
        } else { 0; };
        i = i - 1;
    };
    st = emit(st, "    pop %rax");
    emit(st, "    syscall")
};

def gen_direct(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node, name: str) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let label = "";
    if (name == "self") {
        label = st.self_label;
    } else {
        let e = env_find(st, name);
        if (e.kind == "none") {
            label = "y_missing_" + name;
        } else {
            label = e.label;
        };
    };
    st = gen_push_args(st, node.args);
    st = emit(st, "    call " + label);
    let nbytes = len(node.args) * 8;
    if (nbytes == 0) {
        st
    } else {
        emit(st, "    add $" + tostring(nbytes) + ", %rsp")
    }
};

// ── control flow ───────────────────────────────────────────────────────

def gen_if(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let r1 = next_loc(st);
    st = r1.st;
    let r2 = next_loc(st);
    st = r2.st;
    st = gen(st, node.cond);
    st = emit(st, "    test %rax, %rax");
    st = emit(st, "    jz " + r1.lbl);
    st = gen(st, node.then);
    if (node.has_else) {
        st = emit(st, "    jmp " + r2.lbl);
        st = emit(st, r1.lbl + ":");
        st = gen(st, node.els);
        emit(st, r2.lbl + ":")
    } else {
        emit(st, r1.lbl + ":")
    }
};

def gen_while(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let r1 = next_loc(st);
    st = r1.st;
    let r2 = next_loc(st);
    st = r2.st;
    st = emit(st, r1.lbl + ":");
    st = gen(st, node.cond);
    st = emit(st, "    test %rax, %rax");
    st = emit(st, "    jz " + r2.lbl);
    st = gen(st, node.body);
    st = emit(st, "    jmp " + r1.lbl);
    st = emit(st, r2.lbl + ":");
    emit(st, "    xor %eax, %eax")
};

def gen_block(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    // No scope push: names are unique post-rename, blocks share the frame.
    let stmts = node.stmts;
    if (len(stmts) == 0) {
        emit(st, "    xor %eax, %eax")
    } else {
        let i = 0;
        while (i < len(stmts)) {
            st = gen(st, stmts[i]);
            i = i + 1;
        };
        st
    }
};

// Record literal { k: v, ... }: heap-allocate 8*n bytes (arena, static
// size — like a dynamic array without the header) and store each value.
// The VALUE is the heap address (8 bytes, first-class: locals, params,
// returns all just copy the address). Field k lives at addr+8k.
// (y_alloc(0) is fine — bump allocators return a valid, if empty, block;
// empty maps are rejected by the checker anyway.)
def gen_map(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    // NOTE: bound once — `node.vals[i]` inline misparses on the C VM.
    let mvals = node.vals;
    let mkeys = node.keys;
    let n = len(mvals);
    // Shape tag for dynamic field reads (see y_dot_lookup note in
    // arch_x64.y): every record carries its field table; field i lives
    // at tag_base+8+i*8 and the value (base+8) keeps today's offsets,
    // so statically-precise reads are bit-identical. Table label per
    // site (uid); table rows are decimal quads (both assemblers take
    // `.quad N`; no pointers, so no fixup-kind gaps).
    let ru = next_uid(st);
    st = ru.st;
    let tlbl = "ytd_" + tostring(ru.uid);
    let te = [];
    te = push(te, tlbl);
    te = push(te, "TABLE");
    te = push(te, "1498307412");
    te = push(te, tostring(n));
    let j = 0;
    while (j < n) {
        let nm: str = mkeys[j];
        te = push(te, tostring(8 * j));
        let nl = len(nm);
        te = push(te, tostring(nl));
        let c = 0;
        while (c < nl) {
            let ch = substr(nm, c, 1);
            let co = ord(ch);
            te = push(te, tostring(co));
            c = c + 1;
        };
        j = j + 1;
    };
    let trod = push(st.rodata, te);
    st = { out: st.out, rodata: trod, uid: st.uid,
      fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots,
      self_label: st.self_label, end_label: st.end_label, fns: st.fns,
      bodies: st.bodies };
    st = emit(st, "    mov $" + tostring(8 * n + 16) + ", %rdi");
    st = emit(st, "    call y_alloc");
    st = emit(st, "    push %rax");
    st = emit(st, "    lea " + tlbl + "(%rip), %rax");
    st = emit(st, "    pop %rcx");
    st = emit(st, "    mov %rax, 0(%rcx)");
    st = emit(st, "    push %rcx");
    let i = 0;
    while (i < n) {
        // NOTE: bound once — `x.y[i]` chains misparse on the C VM.
        let mv = mvals[i];
        st = gen(st, mv);
        st = emit(st, "    pop %rcx");
        st = emit(st, "    mov %rax, " + tostring(8 + i * 8) + "(%rcx)");
        st = emit(st, "    push %rcx");
        i = i + 1;
    };
    st = emit(st, "    pop %rax");
    emit(st, "    add $8, %rax")
};

def gen_decl(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    if (node.kind == "def") {
        // Hoisted: body emitted separately; env pre-bound. Nothing here.
        st
    } else {
        if (node.v.k == "func") {
            // let-bound function: no slot, just bind the hoisted label.
            // (Checker guarantees a literal def here.)
            st
        } else if (node.v.k == "arrrep") {
            // heap array: [v; n] allocates a header {len, cap, data} like
            // the C runtime's val_arr. First-class: the value is the
            // header (one slot); copies are made at store time so two
            // bindings never alias (see y_arr_clone).
            st = gen(st, node.v.v);
            st = emit(st, "    push %rax");
            st = emit(st, "    mov $" + tostring(16 + 8 * node.v.n) + ", %rdi");
            st = emit(st, "    call y_alloc");
            st = emit(st, "    mov %rax, %rdx");
            st = emit(st, "    mov $" + tostring(node.v.n) + ", (%rdx)");
            st = emit(st, "    mov $" + tostring(node.v.n) + ", 8(%rdx)");
            st = emit(st, "    pop %rax");
            st = gen_fill_heap(st, node.v.n);
            let off = (st.slots + 1) * -8;
            st = emit(st, "    mov %rdx, " + tostring(off) + "(%rbp)");
            let t = node.typ;
            if (t.k == "tnone") {
                t = infer(st, node.v);
            };
            let st2 = { out: st.out, rodata: st.rodata, uid: st.uid,
              fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots + 1,
              self_label: st.self_label, end_label: st.end_label, fns: st.fns,
              bodies: st.bodies };
            env_define(st2, node.name, "local", off, "", t)
        } else if (node.v.k == "map") {
            // record literal: heap address (first-class value, plain slot).
            st = gen(st, node.v);
            let off = (st.slots + 1) * -8;
            st = emit(st, "    mov %rax, " + tostring(off) + "(%rbp)");
            let t = node.typ;
            if (t.k == "tnone") {
                t = infer(st, node.v);
            };
            let st2 = { out: st.out, rodata: st.rodata, uid: st.uid,
              fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots + 1,
              self_label: st.self_label, end_label: st.end_label, fns: st.fns,
              bodies: st.bodies };
            env_define(st2, node.name, "local", off, "", t)
        } else {
            st = gen(st, node.v);
            let vt = infer(st, node.v);
            if (vt.k == "tarr" || vt.k == "tarrfix") {
                st = emit(st, "    mov %rax, %rdi");
                st = emit(st, "    call y_arr_clone");
                0
            } else { 0; };
            if (vt.k == "trec") {
                st = emit(st, "    mov %rax, %rdi");
                st = emit(st, "    call y_rec_clone");
                0
            } else { 0; };
            let off = (st.slots + 1) * -8;
            st = emit(st, "    mov %rax, " + tostring(off) + "(%rbp)");
            // bind with annotation or inferred type
            let t = node.typ;
            if (t.k == "tnone") {
                t = infer(st, node.v);
            };
            let st2 = { out: st.out, rodata: st.rodata, uid: st.uid,
              fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots + 1,
              self_label: st.self_label, end_label: st.end_label, fns: st.fns,
              bodies: st.bodies };
            env_define(st2, node.name, "local", off, "", t)
        }
    }
};

def gen_assign(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let e = env_find(st, node.name);
    // Arrays and records are first-class now: one slot per binding, and
    // every store deep-copies (copy-on-store) so bindings never alias —
    // index/dot assignment is observable, matching the C runtime's
    // val_clone. The old [v; n] refill arm is gone: a = anything goes.
    st = gen(st, node.v);
    let vt = infer(st, node.v);
    if (vt.k == "tarr" || vt.k == "tarrfix") {
        st = emit(st, "    mov %rax, %rdi");
        st = emit(st, "    call y_arr_clone");
        0
    } else { 0; };
    if (vt.k == "trec") {
        st = emit(st, "    mov %rax, %rdi");
        st = emit(st, "    call y_rec_clone");
        0
    } else { 0; };
    st = emit(st, "    mov %rax, " + tostring(e.off) + "(%rbp)");
    st
};

// Fill n frame slots (base = lowest address) with the value in %rax.
def gen_fill(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, base: long, n: long) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    if (n == 0) {
        st
    } else {
        let r = next_loc(st);
        st = r.st;
        st = emit(st, "    mov $" + tostring(n) + ", %rcx");
        st = emit(st, r.lbl + ":");
        st = emit(st, "    dec %rcx");
        st = emit(st, "    mov %rax, " + tostring(base) + "(%rbp,%rcx,8)");
        emit(st, "    jnz " + r.lbl)
    }
};

// Heap-array fill: the header is in %rdx, the fill value in %rax. Writes
// data[i] for i = n-1 .. 0 (data starts at header+16).
def gen_fill_heap(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, n: long) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    if (n == 0) {
        st
    } else {
        let r = next_loc(st);
        st = r.st;
        st = emit(st, "    mov $" + tostring(n) + ", %rcx");
        st = emit(st, r.lbl + ":");
        st = emit(st, "    dec %rcx");
        st = emit(st, "    mov %rax, 16(%rdx,%rcx,8)");
        st = emit(st, "    jnz " + r.lbl);
        st
    }
};

def gen_index(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    // Checker: plain id of fixed or heap array. Bounds-trapped at runtime.
    // Fixed arrays are heap headers now (same layout as heap arrays);
    // only the bound differs: static n for [T; N], runtime len for [T].
    let e = env_find(st, node.arr.v);
    st = gen(st, node.arr);
    st = emit(st, "    push %rax");
    st = gen(st, node.idx);
    st = emit(st, "    mov %rax, %rcx");
    st = emit(st, "    pop %rax");
    st = emit(st, "    test %rcx, %rcx");
    st = emit(st, "    js y_oob");
    if (e.typ.k == "tarrfix") {
        st = emit(st, "    cmp $" + tostring(e.typ.n) + ", %rcx");
        st = emit(st, "    jge y_oob");
        emit(st, "    mov 16(%rax,%rcx,8), %rax")
    } else {
        st = emit(st, "    mov (%rax), %rdx");
        st = emit(st, "    cmp %rdx, %rcx");
        st = emit(st, "    jge y_oob");
        emit(st, "    mov 16(%rax,%rcx,8), %rax")
    }
};

// s.f = v — in-place record field write. The checker guarantees the object
// is a plain variable holding a record whose static shape has the field.
// Records are heap addresses; field i lives at addr+8i (same layout the
// static gen_dot read uses), so the write is: value -> (rec + 8*idx).
def gen_dotassign(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let e = env_find(st, node.obj.v);
    if (e.kind == "param") {
        // functional record mutation for params (alias-safety, see
        // gen_idxassign): clone, then write into the clone.
        st = gen(st, node.obj);
        st = emit(st, "    mov %rax, %rdi");
        st = emit(st, "    call y_rec_clone");
        st = emit(st, "    mov %rax, " + tostring(e.off) + "(%rbp)");
        0
    } else { 0; };
    let idx = rec_field_idx(e.typ, node.key);
    st = gen(st, node.v);
    st = emit(st, "    push %rax");
    st = emit(st, "    mov " + tostring(e.off) + "(%rbp), %rdx");
    st = emit(st, "    pop %rax");
    st = emit(st, "    mov %rax, " + tostring(8 * idx) + "(%rdx)")
};

def gen_idxassign(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    // Fixed arrays are heap headers now: one layout for both kinds.
    // Fixed uses the static bound n; heap uses the runtime len.
    // PARAMS mutate FUNCTIONALLY: `x[i] = v` clones the array, writes
    // into the clone and rebinds the param slot — a param may alias the
    // caller's array (the C runtime clones call args), so the caller's
    // array must not change. Owned locals mutate in place (copy-on-store
    // keeps them private).
    let e = env_find(st, node.arr.v);
    if (e.kind == "param") {
        st = gen(st, node.arr);
        st = emit(st, "    mov %rax, %rdi");
        st = emit(st, "    call y_arr_clone");
        st = emit(st, "    mov %rax, " + tostring(e.off) + "(%rbp)");
        0
    } else { 0; };
    st = gen(st, node.arr);
    st = emit(st, "    push %rax");
    st = gen(st, node.idx);
    st = emit(st, "    push %rax");
    st = gen(st, node.v);
    st = emit(st, "    pop %rcx");
    st = emit(st, "    pop %rdx");
    st = emit(st, "    test %rcx, %rcx");
    st = emit(st, "    js y_oob");
    if (e.typ.k == "tarrfix") {
        st = emit(st, "    cmp $" + tostring(e.typ.n) + ", %rcx");
        st = emit(st, "    jge y_oob");
        st = emit(st, "    mov %rax, 16(%rdx,%rcx,8)");
        0
    } else {
        st = emit(st, "    push %rax");
        st = emit(st, "    mov (%rdx), %rax");
        st = emit(st, "    cmp %rax, %rcx");
        st = emit(st, "    jge y_oob");
        st = emit(st, "    pop %rax");
        st = emit(st, "    mov %rax, 16(%rdx,%rcx,8)");
        0
    };
    st = emit(st, "    mov %rdx, " + tostring(e.off) + "(%rbp)");
    st
};

// Field read rec.field: the checker guarantees a trec with that field.
// Records are heap addresses; field k lives at addr+8k. Static index via
// infer (checker validated). Works for locals, params, and call results
// alike — every record value is just an address in %rax.
def gen_dot(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    // NOTE: bound once — `node.obj` inline misparses on the C VM.
    let dobj = node.obj;
    let dkey = node.key;
    let t = infer(st, dobj);
    let idx = rec_field_idx(t, dkey);
    if (idx < 0) {
        // unknown static shape ({k}-holes, bare params): dynamic field
        // lookup. The record carries its shape table (see gen_map note);
        // the key goes through the regular string rodata channel.
        let r = next_uid(st);
        st = r.st;
        let klbl = arch.arch_str_label(r.uid);
        let krod = [];
        krod = push(krod, klbl);
        krod = push(krod, tostring(len(dkey)));
        krod = push(krod, esc_asm(dkey));
        let rod = push(st.rodata, krod);
        st = { out: st.out, rodata: rod, uid: st.uid,
          fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots,
          self_label: st.self_label, end_label: st.end_label, fns: st.fns,
          bodies: st.bodies };
        st = gen(st, dobj);
        st = emit(st, "    push %rax");
        st = emit(st, "    lea " + klbl + "(%rip), %rax");
        st = emit(st, "    push %rax");
        st = emit(st, "    call y_dot_lookup");
        st = emit(st, "    add $16, %rsp");
        0
    } else {
        st = gen(st, dobj);
        st = emit(st, "    mov " + tostring(idx * 8) + "(%rax), %rax");
        0
    };
    st
};

// Static field index of `key` in trec type t (-1 = checker drift;
// the checker rejects unknown fields, so this is unreachable).
def rec_field_idx(t, key: str) -> long {
    let idx = -1;
    if (t.k == "trec") {
        let fs = t.fields;
        let i = 0;
        while (i < len(fs)) {
            // NOTE: bound once — `x.y[i]` chains misparse on the C VM.
            let f = fs[i];
            if (f.name == key) {
                idx = i;
                0
            } else { 0; };
            i = i + 1;
        };
    };
    idx
};

// Heap array literal [v, ...]: alloc 16+8n, store len/cap/elems. The header
// pointer (an 8-byte value like any other) is the expression value.
def gen_array(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let elems = node.elems;
    st = gen_push_args(st, elems);
    let n = len(elems);
    st = emit(st, "    mov $" + tostring(16 + n * 8) + ", %rdi");
    st = emit(st, "    call y_alloc");
    st = emit(st, "    mov %rax, %r10");
    st = emit(st, "    mov $" + tostring(n) + ", (%r10)");
    st = emit(st, "    mov $" + tostring(n) + ", 8(%r10)");
    let k = n - 1;
    while (k >= 0) {
        st = emit(st, "    pop %rcx");
        st = emit(st, "    mov %rcx, " + tostring(16 + k * 8) + "(%r10)");
        k = k - 1;
    };
    emit(st, "    mov %r10, %rax")
};

def gen_len(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    // Checker: single array or string argument. Fixed size is immediate
    // (from the inferred type itself); heap length (array header or string
    // header) loads from address+0. NOTE: the argument is any array-typed
    // expression (id, dot like `a.args`, call result) — never assume a
    // plain id (no `.v` reads here); infer gives the static type.
    let args = node.args;
    let at = infer(st, args[0]);
    if (at.k == "tstr") {
        st = gen(st, args[0]);
        emit(st, "    mov (%rax), %rax")
    } else {
        st = gen(st, args[0]);
        emit(st, "    mov (%rax), %rax")
    }
};

// push(arr, v): Y calling convention straight into the prelude helper.
// Returns the (possibly reallocated) header — rebind it: `a = push(a, v)`.
def gen_push(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    st = gen_push_args(st, node.args);
    st = emit(st, "    call y_arr_push");
    let nbytes = len(node.args) * 8;
    emit(st, "    add $" + tostring(nbytes) + ", %rsp")
};

// some(v): box v in 8 heap bytes; the box address (nonzero) is the value.
def gen_some(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let args = node.args;
    st = gen(st, args[0]);
    st = emit(st, "    push %rax");
    st = emit(st, "    mov $8, %rdi");
    st = emit(st, "    call y_alloc");
    st = emit(st, "    pop %rcx");
    st = emit(st, "    mov %rcx, (%rax)");
    st
};

def gen_is_some(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let args = node.args;
    st = gen(st, args[0]);
    st = emit(st, "    test %rax, %rax");
    st = emit(st, "    setne %al");
    emit(st, "    movzbq %al, %rax")
};

def gen_unwrap(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let args = node.args;
    st = gen(st, args[0]);
    st = emit(st, "    test %rax, %rax");
    st = emit(st, "    jz y_opt_unwrap");
    emit(st, "    mov (%rax), %rax")
};

// ── string builtins (all on {len, data} header objects) ────────────────
// Every helper takes header addresses via the Y calling convention
// (args pushed left-to-right, first arg deepest) and returns a header
// address (or long) in %rax. Caller cleans the stack.

def gen_substr(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    st = gen_push_args(st, node.args);
    st = emit(st, "    call y_str_substr");
    emit(st, "    add $24, %rsp")
};

def gen_trim(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    st = gen_push_args(st, node.args);
    st = emit(st, "    call y_str_trim");
    emit(st, "    add $8, %rsp")
};

def gen_ord(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    st = gen_push_args(st, node.args);
    st = emit(st, "    call y_str_ord");
    emit(st, "    add $8, %rsp")
};

def gen_chr(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    st = gen_push_args(st, node.args);
    st = emit(st, "    call y_str_chr");
    emit(st, "    add $8, %rsp")
};

def gen_tonum(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    st = gen_push_args(st, node.args);
    st = emit(st, "    call y_str_tonum");
    emit(st, "    add $8, %rsp")
};

def gen_tostring(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    // dispatch on the static type: long/bool need conversion, str is identity
    // NOTE: bind args once — `node.args[0]` inline misparses on the C VM.
    let targs = node.args;
    let a0 = targs[0];
    let t = infer(st, a0);
    if (t.k == "tstr") {
        gen(st, a0)
    } else if (t.k == "tbool") {
        st = gen_push_args(st, node.args);
        st = emit(st, "    call y_bool_tostr");
        emit(st, "    add $8, %rsp")
    } else {
        st = gen_push_args(st, node.args);
        st = emit(st, "    call y_long_tostr");
        emit(st, "    add $8, %rsp")
    }
};

def gen_index_of(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node, last: bool) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    st = gen_push_args(st, node.args);
    if (last) {
        st = emit(st, "    call y_str_lastidx");
        emit(st, "    add $16, %rsp")
    } else {
        st = emit(st, "    call y_str_index");
        emit(st, "    add $16, %rsp")
    }
};

def gen_join(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    st = gen_push_args(st, node.args);
    st = emit(st, "    call y_str_join");
    emit(st, "    add $16, %rsp")
};

def gen_split(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    st = gen_push_args(st, node.args);
    st = emit(st, "    call y_str_split");
    emit(st, "    add $16, %rsp")
};

def gen_puts(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    // puts(v): write the value WITHOUT trailing newline (C semantics:
    // fputs + flush). Like print but no newline; returns null.
    // NOTE: bind args once — `node.args[0]` inline misparses on the C VM.
    let pargs = node.args;
    let pa = pargs[0];
    st = gen(st, pa);
    let t = infer(st, pa);
    st = emit(st, "    mov %rax, %rdi");
    if (t.k == "tbool") {
        st = emit(st, "    call y_put_bool");
        emit(st, "    xor %eax, %eax")
    } else if (t.k == "tstr") {
        st = emit(st, "    call y_put_hstr");
        emit(st, "    xor %eax, %eax")
    } else {
        st = emit(st, "    call y_put_long");
        emit(st, "    xor %eax, %eax")
    }
};

def gen_exit(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    // NOTE: bind args once — `node.args[0]` inline misparses on the C VM.
    let eargs = node.args;
    let ea = eargs[0];
    st = gen(st, ea);
    st = emit(st, "    mov %rax, %rdi");
    st = emit(st, "    mov $60, %rax");
    st = emit(st, "    syscall");
    // exit() terminates the process; the epilogue (ret / exit(0)) is
    // unreachable. Emit a jump to the function end so the backend never
    // falls through into dead code (and exit codes are never masked).
    emit(st, "    jmp " + st.end_label)
};

// ── process I/O + files (argv, read_file, write_file) ───────────────
// argv MAY only appear as `main(argv())`'s argument feed: ycc.y's entry is
// `let result = main(argv())`. The _start prologue (below) builds the argv
// array and stashes it in r15; gen_argv emits the call that materializes it.
// read_file(path): openat+read loop into a heap string; null (0) on error,
// else a some()-style heap box holding the string header (options are
// 0-or-box per NATIVE.md, so unwrap() derefs uniformly).
// write_file(path, content): openat(O_WRONLY|O_CREAT|O_TRUNC, 0644)+write;
// returns bool. Both are straight-line syscalls, no libc.

def gen_argv(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    emit(st, "    call y_argv")
};

def gen_read_file(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    st = gen_push_args(st, node.args);
    st = emit(st, "    call y_read_file");
    emit(st, "    add $8, %rsp")
};

def gen_write_file(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    st = gen_push_args(st, node.args);
    st = emit(st, "    call y_write_file");
    emit(st, "    add $16, %rsp")
};

// write_bytes(path, bytes, mode): binary-safe emit (tinycc's
// tcc_write_elf_file output step, minus buffering): openat + write loop
// over the heap array's data + close + chmod. Args arrive left-to-right
// (path deepest); the helper takes the same Y convention.
def gen_write_bytes(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    st = gen_push_args(st, node.args);
    st = emit(st, "    call y_write_bytes");
    emit(st, "    add $24, %rsp")
};

def gen_store(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    st = gen(st, node.p);
    st = emit(st, "    push %rax");
    st = gen(st, node.v);
    st = emit(st, "    pop %rcx");
    emit(st, "    mov %rax, (%rcx)")
};

// ── functions ──────────────────────────────────────────────────────────
// Frame: locals at rbp-8, rbp-16, ...; params at rbp+16, rbp+24, ....
// Every emitted function gets: prologue, body, end_label, epilogue.

def emit_one_fn(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, label: str, fuid: long, func, is_main: bool, want_argv: bool) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    // fresh per-function state; uid/rodata/fns flow through and back.
    // The scope is pre-loaded with every known def (like the checker's
    // fresh_func_scope): bodies see all top-level + hoisted functions.
    let f = { out: [], rodata: st.rodata, uid: st.uid,
      fuid: fuid, loc: 1, env: [], slots: 0,
      self_label: label, end_label: arch.arch_loc_label(fuid, 0),
      fns: st.fns, bodies: st.bodies };
    let fnsall = st.fns;
    let g = 0;
    while (g < len(fnsall)) {
        let fe = fnsall[g];
        f = env_define(f, fe.name, "func", 0, fe.label, fe.typ);
        g = g + 1;
    };
    // bind params. Caller pushes args left-to-right, so the LAST arg sits
    // at rbp+16 and param k lives at rbp+16+8*(n-1-k) (arity-dependent).
    let params = func.params;
    let ptypes = func.ptypes;
    let nargs = len(params);
    let i = 0;
    while (i < nargs) {
        f = env_define(f, params[i], "param", 16 + (nargs - 1 - i) * 8, "", ptypes[i]);
        i = i + 1;
    };
    f = gen_block(f, func.body);
    let frame = arch.arch_frame(f.slots);
    let code = [];
    code = push(code, label + ":");
    if (is_main) {
        if (want_argv) {
            // _start prologue: at process entry %rsp -> [argc][argv0ptr]....
            // argv (char**) is the ADDRESS rsp+8 (lea, not a load!); argc is
            // [rsp]. y_argv_init copies every arg into a header string and
            // stashes the [str] array in r15 for y_argv. Skipped entirely
            // when the program never calls argv() (saves ~14s of startup:
            // y_cstr_to_str walks every byte of every arg).
            // NOTE: no bare (%rsp)/(%r12) — the encoder rejects rsp/r12 bases.
            code = push(code, "    mov %rsp, %rax");
            code = push(code, "    mov (%rax), %r15");
            code = push(code, "    mov %rax, %r14");
            code = push(code, "    add $8, %r14");
            code = push(code, "    push %r14");
            code = push(code, "    push %r15");
            code = push(code, "    call y_argv_init");
            code = push(code, "    add $16, %rsp");
            0
        } else { 0; };
        0
    } else { 0; };
    code = push(code, "    push %rbp");
    code = push(code, "    mov %rsp, %rbp");
    if (frame > 0) {
        code = push(code, "    sub $" + tostring(frame) + ", %rsp");
        0
    } else { 0; };
    let fout = f.out;
    let j = 0;
    while (j < len(fout)) {
        code = push(code, fout[j]);
        j = j + 1;
    };
    code = push(code, f.end_label + ":");
    if (is_main) {
        code = push(code, "    mov $60, %rax");
        code = push(code, "    xor %edi, %edi");
        code = push(code, "    syscall");
    } else {
        code = push(code, "    mov %rbp, %rsp");
        code = push(code, "    pop %rbp");
        code = push(code, "    ret");
    };
    let bodies = push(st.bodies, join(code, "\n"));
    { out: st.out, rodata: f.rodata, uid: f.uid,
      fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots,
      self_label: st.self_label, end_label: st.end_label, fns: st.fns,
      bodies: bodies }
};

// Build a tfunc type from a func node (params have annotations — checked).
def func_type(func) -> { k: str, args: [{ k: str }], ret: { k: str } } {
    { k: "tfunc", args: func.ptypes, ret: func.ret }
};

// Display name: strip rename's `$N` suffix (see types.y disp).
def ndisp(name: str) -> str {
    let i = index_of(name, "$");
    if (i < 0) { name } else { substr(name, 0, i) }
};

// Two spliced modules may define the same name: shadowing would silently
// pick one, so duplicates are a loud error (at the second def's position).
def find_dup(defs: [{ name: str, func: { k: str } }]) -> { found: bool, err: { msg: str, line: long, col: long } } {
    let seen = [];
    let i = 0;
    let out = { found: false, err: { msg: "", line: 1, col: 1 } };
    while (i < len(defs)) {
        let d = defs[i];
        let j = 0;
        while (j < len(seen)) {
            // NOTE: :str binding (see teq note in types.y): seen elements
            // infer tunk (pushed into bare []), so compare via annotated
            // let to force content (not pointer) comparison.
            let sn: str = seen[j];
            if (sn == d.name) {
                out = { found: true, err: { msg: "duplicate definition '" + ndisp(d.name) + "' (native imports splice; rename one)", line: d.func.line, col: d.func.col } };
                0
            } else { 0; };
            j = j + 1;
        };
        seen = push(seen, d.name);
        i = i + 1;
    };
    out
};

// ── entry point ────────────────────────────────────────────────────────

def emit_program(ast, imports: [str]) -> { ok: bool, asm: str, errors: [{ msg: str, line: long, col: long }] } {
    let ast2 = strip_ns(ast, imports);
    // Static name resolution: every binding gets a unique name, so neither
    // the checker nor the emitter deals with scopes or shadowing.
    let ast3 = rename.rename_program(ast2);
    let errors = types.check_program(ast3);
    // collect every def (top-level + capture-free nested + let-bound)
    let defs = collect_from_block(ast3.stmts, []);
    let dup = find_dup(defs);
    if (dup.found) {
        errors = push(errors, dup.err);
        0
    } else { 0; };
    if (len(errors) > 0) {
        { ok: false, asm: "", errors: errors }
    } else {
        // assign labels + env entries (also pre-binds for calls)
        let st = st_new();
        let r = next_uid(st);
        st = r.st;
        let i = 0;
        while (i < len(defs)) {
            let d = defs[i];
            let rl = next_uid(st);
            st = rl.st;
            let label = arch.arch_fn_label(rl.uid, d.name);
            let fns = push(st.fns, { name: d.name, label: label, typ: func_type(d.func) });
            st = { out: st.out, rodata: st.rodata, uid: st.uid,
              fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots,
              self_label: st.self_label, end_label: st.end_label, fns: fns,
              bodies: st.bodies };
            st = env_define(st, d.name, "func", 0, label, func_type(d.func));
            i = i + 1;
        };
        // emit each function body
        i = 0;
        while (i < len(defs)) {
            let d = defs[i];
            let fns = st.fns;
            let f = fns[i];
            let rf = next_uid(st);
            st = rf.st;
            st = emit_one_fn(st, f.label, rf.uid, d.func, false, false);
            i = i + 1;
        };
        // main = program with defs skipped (they're hoisted)
        let main_stmts = [];
        let pstmts = ast3.stmts;
        let i = 0;
        while (i < len(pstmts)) {
            let s = pstmts[i];
            if (s.k == "decl") {
                if (s.kind == "def") {
                    0;
                } else if (s.v.k == "func") {
                    0;
                } else {
                    main_stmts = push(main_stmts, s);
                    0;
                };
                0
            } else {
                main_stmts = push(main_stmts, s);
                0;
            };
            i = i + 1;
        };
        let rm = next_uid(st);
        st = rm.st;
        // Only pay for argv materialization when the program uses it.
        let want = uses_scan_block(ast3.stmts, { argv: false });
        st = emit_one_fn(st, "_start", rm.uid, { params: [], ptypes: [], ret: { k: "tnull" }, body: { k: "block", stmts: main_stmts } }, true, want.argv);
        // assemble the file
        let asm = arch.arch_header();
        asm = asm + arch.arch_text() + arch.arch_prelude();
        let allbodies = st.bodies;
        // Piece-list + single join: `asm = asm + piece` per iteration is
        // quadratic (each concat re-copies the whole 1.4MB+ accumulator —
        // the arena never frees), which OOMs on self-compilation.
        let pieces: [str] = [];
        let b = 0;
        while (b < len(allbodies)) {
            pieces = push(pieces, allbodies[b]);
            pieces = push(pieces, "\n");
            b = b + 1;
        };
        asm = asm + join(pieces, "");
        asm = asm + arch.arch_rodata() + arch.arch_consts();
        let allrod = st.rodata;
        let s2 = 0;
        let rodpieces: [str] = [];
        while (s2 < len(allrod)) {
            let pair = allrod[s2];
            // String entries are exactly [label, len, escaped]; shape
            // tables (see gen_map note) are longer and all-strings.
            if (len(pair) == 3) {
                rodpieces = push(rodpieces, pair[0] + ":\n.quad " + tostring(pair[1]) + "\n.string \"" + pair[2] + "\"\n");
                0
            } else {
                rodpieces = push(rodpieces, pair[0] + ":\n");
                let q = 2;
                while (q < len(pair)) {
                    rodpieces = push(rodpieces, ".quad " + pair[q] + "\n");
                    q = q + 1;
                };
                0
            };
            s2 = s2 + 1;
        };
        asm = asm + join(rodpieces, "");
        { ok: true, asm: asm, errors: errors }
    }
};

export { emit_program, native_resolve, strip_ns, strip_list, strip_decl };
