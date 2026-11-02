// infer_params.y — fill parameter types that are implied by the program.
//
// ycc lets a def omit a parameter's type:
//
//     def add(a, b) -> long { a + b };
//     print(add(2, 3));
//
// The parser used to do this while it was still reading tokens: it kept a
// table of call-site literal types and a table of the defs it had built, then
// patched the Func.ptypes arrays at the end of parse_program. That worked, but
// it put type inference in the middle of the parser and made the parser's
// entry point mean two things. This module is that inference as its own
// post-parse phase: the parser now returns a syntax tree, and infer_program
// reads the tree and fills the same arrays.
//
// The rules are unchanged:
//
//   1. A missing parameter type may come from a call site: if an argument is
//      a literal, its type is a candidate. Calls are applied in source order.
//   2. It may also come from the body: `a + 1` implies long for `a`, and
//      `a + "x"` implies str. The hint is recorded only when the other
//      operand is a literal and only for a parameter that is still untyped.
//   3. Body hints are applied before call-site hints. A call whose argument
//      type disagrees with an already-filled parameter is left to the type
//      checker to diagnose; this pass never overwrites a type.
//
// A Func.ptypes array is a reference shared by every copy of the Func record,
// so filling an entry here is visible to the caller that already holds the
// tree. That is why infer_program can return the same Block it was given.

import tags from "./tags.y";
import node_schema from "./ast_nodes.y";
import type_schema from "./type_nodes.y";
import litt from "./literal_type.y";

// A named def, in the order it was found. Only `def` declarations are here:
// a `let f = def ...` function has no name at parse time, and the parser never
// offered it to call-site inference.
type InferFunc = { name: str, fn: Func };

// One literal argument at one call site, retained in source order.
type CallNote = { name: str, idx: long, typ: Type };

// A hash chain of same-named funcs. A call to `f` fills the matching parameter
// of every `f` (a later duplicate shadows at check time), which is what the
// parser's one-pass table did.
type FuncIx = { heads: [long], next: [long], size: long };

// ── the hint itself ──────────────────────────────────────────────────────

// The type a binary operator implies for a missing parameter on one side when
// the other side is a primitive literal. This is parser-era logic moved
// verbatim; the checker still has the final say about whether the expression
// is legal.
def bin_hint(op: str, other: Node) -> Type {
    let out: Type = { k: K.tnone };
    let ht = litt.lit_type(other);
    if (ht.k != K.tnone) {
        if (op == "+" && ht.k == K.tstr) { out = { k: K.tstr }; }
        else if (index_of("+-*/%", op) >= 0) {
            if (ht.k == K.tlong || ht.k == K.tbyte || ht.k == K.tfloat || ht.k == K.tbigint) {
                if (ht.k == K.tfloat) { out = { k: K.tfloat }; }
                else { out = { k: K.tlong }; };
            };
        }
        else if (op in ["<", ">", "<=", ">="]) { out = ht; }
        else if (op == "==" || op == "!=") { out = ht; }
        else if (op in ["&", "|", "^", "<<", ">>", ">>>"]) { out = { k: K.tlong }; }
        else if ((op == "&&" || op == "||") && ht.k == K.tbool) { out = { k: K.tbool }; };
    };
    out
};

// Record a hint for `name` in the parallel names/hints arrays. The last hint
// wins (the parser did the same); a non-hint does nothing.
def hint_put(names: [str], hints: [Type], name: str, t: Type) -> void {
    if (t.k == K.tnone) { return; };
    for i in 0..len(names) {
        if (names[i] == name) {
            hints[i] = t;
            return;
        };
    };
};

// ── call sites ───────────────────────────────────────────────────────────

// A call's note is recorded after its callee and arguments, because the parser
// recorded it after parsing the argument list. That order matters only for
// nested calls that name the same function, but preserving it costs nothing.
def note_call(c: Call, calls: [CallNote]) -> void {
    if (c.callee.k != K.id) { return; };
    let id: Leaf = c.callee;
    for i in 0..len(c.args) {
        let lt = litt.lit_type(c.args[i]);
        if (lt.k != K.tnone) {
            calls += { name: id.v, idx: i, typ: lt };
        };
    };
};

// Walk the program once. Each Func gets its own parameter context; calls are
// recorded from every context, including calls inside nested or anonymous
// functions.
def infer_scan(n: Node, names: [str], hints: [Type], calls: [CallNote]) -> void {
    if (n.k == K.func) {
        let f: Func = n;
        // Defaults are parsed before the function's parameter table exists;
        // they can contain calls, but they do not hint this function's body.
        let none: [str] = [];
        let none_t: [Type] = [];
        for i in 0..len(f.defs) {
            infer_scan(f.defs[i], none, none_t, calls);
        };
        let pnames: [str] = [];
        let phints: [Type] = [];
        for i in 0..len(f.params) {
            let pt: Type = { k: K.tnone };
            if (i < len(f.ptypes)) { pt = f.ptypes[i]; };
            if (pt.k == K.tnone) {
                pnames += f.params[i];
                phints += { k: K.tnone };
            };
        };
        infer_scan(f.body, pnames, phints, calls);
        // A `=>` arrow's parameters are typed by its call context, not by
        // literal hints in the body; the old parser never gave arrows a
        // parameter table, and filling one here changed code generation for
        // callbacks without changing behavior. `def` literals and blocks keep
        // the old hint behaviour.
        if (!f.arrow) {
            for i in 0..len(pnames) {
                if (i < len(f.ptypes) && f.ptypes[i].k == K.tnone && phints[i].k != K.tnone) {
                    f.ptypes[i] = phints[i];
                };
            };
        };
        return;
    };
    node_each_child(n, (child: Node) => infer_scan(child, names, hints, calls));
    if (n.k == K.bin) {
        let b: Bin = n;
        if (b.l.k == K.id) {
            let left: Leaf = b.l;
            hint_put(names, hints, left.v, bin_hint(b.op, b.r));
        };
        if (b.r.k == K.id) {
            let right: Leaf = b.r;
            hint_put(names, hints, right.v, bin_hint(b.op, b.l));
        };
    } else if (n.k == K.call) {
        let c: Call = n;
        note_call(c, calls);
    };
};

// Collect every named `def` (top-level or nested) for call-site inference.
// The parser registered a nested def before its enclosing def, but this order
// does not change the answer: a call updates every same-named def.
def collect_named(n: Node, out: [InferFunc]) -> void {
    if (n.k == K.decl) {
        let d: Decl = n;
        if (d.kind == "def" && d.v.k == K.func) {
            let f: Func = d.v;
            out += { name: d.name, fn: f };
        };
    };
    node_each_child(n, (child: Node) => collect_named(child, out));
};

// ── the same-named-func index ────────────────────────────────────────────

def ix_hash(s: str) -> long {
    let n = len(s);
    let h = (n + 1) * 2654435761;
    if (n > 0) {
        h = (h * 16777619 + s[0]) & 1073741823;
        h = (h * 16777619 + s[n - 1]) & 1073741823;
        h = (h * 16777619 + s[n >> 1]) & 1073741823;
    };
    if (n > 3) {
        h = (h * 16777619 + s[1]) & 1073741823;
        h = (h * 16777619 + s[n - 2]) & 1073741823;
    };
    h & 1073741823
};

def ix_build(fs: [InferFunc]) -> FuncIx {
    let size = 16;
    while (size < 2 * len(fs)) { size = size * 2; };
    let heads: [long] = [];
    for i in 0..size { heads += -1; };
    let next: [long] = [];
    for i in 0..len(fs) { next += -1; };
    for i in 0..len(fs) {
        let h = ix_hash(fs[i].name) & (size - 1);
        next[i] = heads[h];
        heads[h] = i;
    };
    { heads: heads, next: next, size: size }
};

def ix_get(ix: FuncIx, fs: [InferFunc], name: str) -> long {
    let h = ix_hash(name) & (ix.size - 1);
    let j = ix.heads[h];
    let out = -1;
    while (j >= 0 && out < 0) {
        if (fs[j].name == name) { out = j; };
        j = ix.next[j];
    };
    out
};

// ── entry point ──────────────────────────────────────────────────────────

// Fill every parameter type the program implies. The tree is returned for the
// caller's convenience; the Func.ptypes arrays are the mutable part.
def infer_program(ast: Block) -> Block {
    let fs: [InferFunc] = [];
    for i in 0..len(ast.stmts) {
        collect_named(ast.stmts[i], fs);
    };
    let ix = ix_build(fs);
    let calls: [CallNote] = [];
    let none: [str] = [];
    let none_t: [Type] = [];
    for i in 0..len(ast.stmts) {
        infer_scan(ast.stmts[i], none, none_t, calls);
    };
    // Body hints have already been applied by infer_scan; now apply call-site types
    // to whatever is still missing, in source order. First call wins.
    let c = 0;
    while (c < len(calls)) {
        let note = calls[c];
        let j = ix_get(ix, fs, note.name);
        while (j >= 0) {
            let f = fs[j].fn;
            if (note.idx < len(f.ptypes) && f.ptypes[note.idx].k == K.tnone) {
                f.ptypes[note.idx] = note.typ;
            };
            j = ix.next[j];
        };
        c++;
    };
    ast
};

export { infer_program };
