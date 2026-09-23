// types.y — static type checker for the native backend.
// Usage: let errors = types.check_program(ast);  // [] means OK
// Each error: { msg: str, line: long, col: long }.
//
// Supported types: long, bool, str, null, *T (pointers), monomorphic
// (T, ...) -> R functions. Everything else (arrays, maps, floats,
// first-class function values in argument position, closures over locals)
// is rejected with a clear error, not silently miscompiled.
//
// Rules (native mode):
// - def params and return types REQUIRE annotations.
// - let/const without annotation is inferred from the initializer.
// - Nested defs see only their own params + top-level defs + intrinsics:
//   referring to an outer local/param is a capture error (closures are
//   planned, not present: no heap for envs yet).
// - `if` conditions must be bool; branches must agree; if-without-else
//   must have a null-typed body (expression-oriented, like the VM).
// - print takes exactly one long/bool/str. syscall takes 1-7 long/bool/str/*T.
// - Assignment targets keep their declared type. No implicit conversions.

def err_at(msg: str, line: long, col: long) -> { msg: str, line: long, col: long } {
    { msg: msg, line: line, col: col }
};

// ── types ────────────────────────────────────────────────────────────────
// Type nodes come from the parser: tlong/tbool/tstr/tnull/tnone/tname,
// tptr {to}, tarr {of}, tfunc {args, ret}, trec {fields: [{name, typ}]},
// tparams. Internal only: tunk (error poison, unifies with everything),
// trec (checked record type {fields: [{name, typ}]} — same shape as the
// parser's trec; teq/tstr compare field-by-field).

def t_unk() -> {k: str} { { k: "tunk" } };
def t_null() -> {k: str} { { k: "tnull" } };

def teq(a, b) -> bool {
    // NOTE: no `||` (see lexer.y isalnum note): the C VM evaluates both sides
    // eagerly AND the checker rejects `||` mixing map-field shapes with bools
    // through one gate — and teq's OWN first line was the worst offender
    // (a.k/t.k field reads poisoned through `||`). Nested ifs everywhere.
    // NOTE: bind kind tags with :str (see gen_bin note in native.y):
    // `a.k`/`b.k` infer tunk (bare params), which would make `!=` below
    // compare string POINTERS; annotated lets force content comparison.
    // Sound: kind tags are always strings (parser + checker construct
    // every type node with a string k).
    let ak: str = a.k;
    let bk: str = b.k;
    if (ak == "tunk") { true }
    else if (bk == "tunk") { true }
    else if (ak != bk) { false }
    else if (ak == "tnone") { true }
    else if (bk == "tnone") { true }
    else if (ak == "tname") { true }
    else if (bk == "tname") { true }
    else if (ak == "tparams") { true }
    else if (bk == "tparams") { true }
    else if (ak == "tptr") { teq(a.to, b.to) }
    else if (ak == "tarr") { teq(a.of, b.of) }
    else if (ak == "tarrfix") {
        if (a.n == b.n) { teq(a.of, b.of) } else { false }
    } else if (a.k == "topt") { teq(a.of, b.of) }
    else if (a.k == "trec") {
        // record types: same field names in order, pairwise-equal types.
        // (tunk fields unify — error poison never cascades.)
        // A single-[k] side is the unknown-shape marker: it unifies with
        // any record (the missing annotation errors once at its own site,
        // not again at every enclosing branch — same tcompat law as the
        // dot arm). Concrete mismatches still disagree (e11/e12 parity).
        // NOTE: each bound once — `x.y[i]` chains misparse on the C VM.
        let af = a.fields;
        let bf = b.fields;
        if (len(af) != len(bf)) {
            if (single_k(af)) { true }
            else if (single_k(bf)) { true }
            else { false }
        } else {
            let ok = true;
            let i = 0;
            // NOTE: no `&&` (see lexer.y note): the C VM evaluates both sides
            // eagerly, so af[i] runs past the end (clamped — safe here, but
            // the checker rejects the shape); flag-form loop instead.
            while (ok) {
                if (i < len(af)) {
                    // NOTE: each bound once — `x.y[i]` chains misparse on the C VM.
                    // NOTE: names bound with :str (see teq note): bare-param
                    // flows infer tunk, which would make `!=` below compare
                    // string POINTERS; annotated lets force content compare.
                    let fa = af[i];
                    let fb = bf[i];
                    let an: str = fa.name;
                    let bn: str = fb.name;
                    if (an != bn) {
                        ok = false;
                    } else {
                        ok = teq(fa.typ, fb.typ);
                    };
                    i = i + 1;
                    0
                } else { ok = false; 0 };
                0
            };
            // hmm — the loop above exits via ok=false BOTH on mismatch and on
            // exhaustion; recompute properly below (flag pair, no `&&`).
            teq_fields(af, bf, 0)
        }
    } else if (ak == "tfunc") {
        if (len(a.args) != len(b.args)) { false } else {
            let ok = teq(a.ret, b.ret);
            let aa = a.args;
            let bb = b.args;
            let i = 0;
            while (ok) {
                if (i < len(aa)) {
                    ok = teq(aa[i], bb[i]);
                    i = i + 1;
                    0
                } else { ok = false; 0 };
                0
            };
            teq_list(aa, bb, 0)
        }
    } else { true }
};

// Pairwise teq over record-field lists / type lists (index recursion keeps
// the loop-guard shapes checker-clean: no `&&`, no eager-OOB indexing).
def teq_fields(af, bf, i: long) -> bool {
    if (i >= len(af)) { true }
    else {
        let fa = af[i];
        let fb = bf[i];
        // NOTE: :str bindings (see teq note): fa/fb flow from bare params
        // (tunk), so a direct `!=` would compare string POINTERS.
        let an: str = fa.name;
        let bn: str = fb.name;
        if (an != bn) { false }
        else if (teq(fa.typ, fb.typ)) { teq_fields(af, bf, i + 1) }
        else { false }
    }
};

def teq_list(aa, bb, i: long) -> bool {
    if (i >= len(aa)) { true }
    else if (teq(aa[i], bb[i])) { teq_list(aa, bb, i + 1) }
    else { false }
};

// The unknown-shape marker as a value: the internal shape of a {k: str}
// annotation (cf. parser.y trec construction). Used to probe whether a
// subject type is unknown-shaped (single-[k]) without reading fields that
// might not exist (reading them IS the error). Concrete singletons
// ({x: long}) do NOT match (name differs) and stay strict (e11 parity).
def unk_shape() -> { k: str, fields: [{ name: str, typ: { k: str } }] } {
    { k: "trec", fields: [{ name: "k", typ: { k: "tstr" } }] }
};

// Single-[k] field list test for teq's trec arm (operates on real field
// arrays threaded through bare params — reads stay quiet statically and
// exact at runtime).
def single_k(fs) -> bool {
    if (len(fs) != 1) { false }
    else { fs[0].name == "k" }
};

// Field type by name in a trec; tnone marker when missing (dotassign uses
// it — the caller reports the error once at the assignment site).
def trec_field_type(rec, key: str) -> { k: str } {
    let found = { k: "tnone" };
    if (rec.k == "trec") {
        let fs = rec.fields;
        let i = 0;
        while (i < len(fs)) {
            let f = fs[i];
            if (f.name == key) {
                found = f.typ;
                0
            } else { 0; };
            i = i + 1;
        };
    };
    found
};

def tstr_go(t) -> str {
    if (t.k == "tlong") { "long" }
    else if (t.k == "tbyte") { "byte" }
    else if (t.k == "tfloat") { "float" }
    else if (t.k == "tbool") { "bool" }
    else if (t.k == "tstr") { "str" }
    else if (t.k == "tnull") { "null" }
    else if (t.k == "tvoid") { "void" }
    else if (t.k == "tunk") { "<error>" }
    else if (t.k == "tnone") { "<missing annotation>" }
    else if (t.k == "tname") { t.name }
    else if (t.k == "tptr") { "*" + tstr_go(t.to) }
    else if (t.k == "tarr") { "[" + tstr_go(t.of) + "]" }
    else if (t.k == "tarrfix") { "[" + tstr_go(t.of) + "; " + tostring(t.n) + "]" }
    else if (t.k == "topt") { tstr_go(t.of) + "?" }
    else if (t.k == "trec") {
        let parts = [];
        let fs = t.fields;
        let i = 0;
        while (i < len(fs)) {
            // NOTE: bound once — `x.y[i]` chains misparse on the C VM.
            let f = fs[i];
            parts = push(parts, f.name + ": " + tstr_go(f.typ));
            i = i + 1;
        };
        "{ " + join(parts, ", ") + " }"
    }
    else if (t.k == "tfunc") {
        let parts = [];
        let ta = t.args;
        let i = 0;
        while (i < len(ta)) {
            parts = push(parts, tstr_go(ta[i]));
            i = i + 1;
        };
        "(" + join(parts, ", ") + ") -> " + tstr_go(t.ret)
    } else { "<" + t.k + ">" }
};

def tstr(t) -> str { tstr_go(t) };

// A numeric literal denotes a float when it has a fraction or an exponent.
// Radix literals are checked first: 0xE1 and 0xbeef contain 'e'/'E'/'b'.
// (native.y keeps its own copy — the two modules never share helpers.)
def num_is_float(s: str) -> bool {
    let radix = false;
    if (len(s) > 2) {
        let p = substr(s, 0, 2);
        if (p == "0x") { radix = true; 0; } else { 0; };
        if (p == "0X") { radix = true; 0; } else { 0; };
        if (p == "0b") { radix = true; 0; } else { 0; };
        if (p == "0B") { radix = true; 0; } else { 0; };
        0
    } else { 0; };
    if (radix) { false } else {
        let f = false;
        if (index_of(s, ".") >= 0) { f = true; 0; } else { 0; };
        if (index_of(s, "e") >= 0) { f = true; 0; } else { 0; };
        if (index_of(s, "E") >= 0) { f = true; 0; } else { 0; };
        f
    }
};

// User-visible rendering (typeof / print of a function or record value).
// Matches the C VM's type_t_to_buf byte for byte for the types both
// engines have, so `typeof(x)` reads the same under either backend.
// tstr() stays as it is: compiler diagnostics (and the tests that match
// on them) use the roomier spacing.
def tdisp(t) -> str {
    if (t.k == "trec") {
        let parts = [];
        let fs = t.fields;
        let i = 0;
        while (i < len(fs)) {
            let f = fs[i];
            parts = push(parts, f.name + ": " + tdisp(f.typ));
            i = i + 1;
        };
        "{" + join(parts, ", ") + "}"
    } else if (t.k == "tfunc") {
        let parts = [];
        let ta = t.args;
        let i = 0;
        while (i < len(ta)) {
            parts = push(parts, tdisp(ta[i]));
            i = i + 1;
        };
        "(" + join(parts, ", ") + ")->" + tdisp(t.ret)
    } else if (t.k == "tarr") {
        "[" + tdisp(t.of) + "]"
    } else if (t.k == "tarrfix") {
        "[" + tdisp(t.of) + "; " + tostring(t.n) + "]"
    } else if (t.k == "tptr") {
        "*" + tdisp(t.to)
    } else if (t.k == "topt") {
        tdisp(t.of) + "?"
    } else {
        tstr_go(t)
    }
};

// A type is "first-class storable but not yet callable through": function
// values may live in let-bindings and be called directly, never passed around.
// NOTE: nested ifs, not `||` chains (see lexer.y isalnum note): the C VM
// evaluates both sides eagerly AND the checker rejects `||` mixing
// map-field shapes through the same gate.
def is_value_type(t) -> bool {
    if (t.k == "tlong") { true }
    else if (t.k == "tbyte") { true }
    else if (t.k == "tfloat") { true }
    else if (t.k == "tbool") { true }
    else if (t.k == "tstr") { true }
    else if (t.k == "tnull") { true }
    else if (t.k == "tptr") { true }
    else if (t.k == "tunk") { true }
    else if (t.k == "tnone") { true }
    else if (t.k == "tname") { true }
    else if (t.k == "tparams") { true }
    else if (t.k == "tfunc") { true }
    else if (t.k == "tarr") { true }
    else if (t.k == "tarrfix") { true }
    else if (t.k == "topt") { true }
    else { t.k == "trec" }
};

// A function VALUE prints as `<function (params)->(ret)>` — note the extra
// parens around the return type, which is how the C VM renders it.
def tdisp_fnval(t) -> str {
    let parts = [];
    let ta = t.args;
    let i = 0;
    while (i < len(ta)) {
        parts = push(parts, tdisp(ta[i]));
        i = i + 1;
    };
    "(" + join(parts, ", ") + ")->(" + tdisp(t.ret) + ")"
};

// ── checker state ────────────────────────────────────────────────────────
// No scopes: rename.y gave every binding a unique name, so one flat list
// suffices. bindings = [{name, typ, kind, fdepth}] (fdepth = function-nesting
// depth where bound; top level = 0). kind: "local" | "param" | "func"
// (any def) | "intrinsic". A local/param is visible only at its own fdepth —
// anything else is a capture (closures need heap envs — planned).

def lookup(bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], name: str) -> { typ: { k: str }, kind: str, fdepth: long } {
    let i = 0;
    // NOTE: NO shared `found` hole rebound across arms (see parser.y
    // parse_type_node note): the env keeps ONE shape per name, so a hole
    // rebound to e.typ then read as e.kind would resolve `kind` against the
    // TYPE shape. found* snapshots are bound once in their own arms.
    let found_typ = { k: "tnone" };
    let found_kind = "";
    let found_fd = 0;
    while (i < len(bindings)) {
        let e = bindings[i];
        if (e.name == name) {
            found_typ = e.typ;
            found_kind = e.kind;
            found_fd = e.fdepth;
            0
        } else { 0 };
        i = i + 1;
        0
    };
    { typ: found_typ, kind: found_kind, fdepth: found_fd }
};

def st_bind(st: { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long }, name: str, typ, kind: str) -> { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long } {
    let bindings = push(st.bindings, { name: name, typ: typ, kind: kind, fdepth: st.fdepth });
    { bindings: bindings, errors: st.errors, ret: st.ret, self: st.self, fdepth: st.fdepth }
};

// ── the checker ──────────────────────────────────────────────────────────
// Threaded state st = { bindings, errors, ret, self, fdepth }.
// typeof_* returns { typ, st }.

// The C compiler's parser has no dot-assign (`st.errors = ...`), so state
// updates are explicit map rebuilds (same style as the rest of ycc).
def st_errors(st: { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long }, errs: [{ msg: str, line: long, col: long }]) -> { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long } { { bindings: st.bindings, errors: errs, ret: st.ret, self: st.self, fdepth: st.fdepth } };
// NOTE: the parameter is NOT named `self`: the C VM binds `self` to the
// enclosing function in every scope, which would shadow it.
def st_self(st: { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long }, selfv) -> { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long } { { bindings: st.bindings, errors: st.errors, ret: st.ret, self: selfv, fdepth: st.fdepth } };
def st_ret(st: { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long }, ret) -> { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long } { { bindings: st.bindings, errors: st.errors, ret: ret, self: st.self, fdepth: st.fdepth } };

def fail(st: { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long }, msg: str, line: long, col: long) -> { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long } {
    st_errors(st, push(st.errors, err_at(msg, line, col)))
};

// Display name: strip the rename pass's `$N` suffix so errors read like
// the user's source (`$` is lexer-illegal, so it can only come from rename).
def disp(name: str) -> str {
    let i = index_of(name, "$");
    if (i < 0) { name } else { substr(name, 0, i) }
};

// A local/param binding from an enclosing function is a CAPTURE. Captures
// are legal now: the emitter closure-converts the function, copying each
// captured value into a heap closure record. (Captured values are copied
// at closure-creation time, so a closure sees the value as it was then.)
def check_visible(st: { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long }, got, name: str, line: long, col: long) -> { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long } {
    let unused = name;
    let unused2 = line;
    let unused3 = col;
    let unused4 = got;
    st
};

def expect_type(st: { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long }, got, want, what: str, line: long, col: long) -> { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long } {
    if (tcompat(got, want)) { st } else {
        fail(st, what + ": expected " + tstr(want) + ", got " + tstr(got), line, col)
    }
};

// Binary-operator result typing, split out so the `bin` arm needs no `||`
// chains at all (see lexer.y isalnum note).
def typeof_arith(st: { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long }, op: str, lt, rt, line: long, col: long) -> { typ: { k: str }, st: { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long } } {
    // "+" on strings concatenates (either side may be poison tunk, but at
    // least one side must be a real str — nested ifs, no `&&`/`||`).
    // AUTO-STRINGIFY: str + long/bool (and the mirror) stringify the
    // number and concat — same semantics as the C runtime's y_add.
    if (op == "+") {
        if (lt.k == "tstr") {
            if (rt.k == "tstr") { { typ: { k: "tstr" }, st: st } }
            else if (rt.k == "tunk") { { typ: { k: "tstr" }, st: st } }
            else if (rt.k == "tlong") { { typ: { k: "tstr" }, st: st } }
            else if (rt.k == "tbyte") { { typ: { k: "tstr" }, st: st } }
            else if (rt.k == "tfloat") { { typ: { k: "tstr" }, st: st } }
            else if (rt.k == "tbool") { { typ: { k: "tstr" }, st: st } }
            else { typeof_arith_long(st, op, lt, rt, line, col) }
        } else if (lt.k == "tunk") {
            if (rt.k == "tstr") { { typ: { k: "tstr" }, st: st } }
            else { typeof_arith_long(st, op, lt, rt, line, col) }
        } else if (lt.k == "tlong") {
            if (rt.k == "tstr") { { typ: { k: "tstr" }, st: st } }
            else { typeof_arith_long(st, op, lt, rt, line, col) }
        } else if (lt.k == "tbyte") {
            if (rt.k == "tstr") { { typ: { k: "tstr" }, st: st } }
            else { typeof_arith_long(st, op, lt, rt, line, col) }
        } else if (lt.k == "tfloat") {
            if (rt.k == "tstr") { { typ: { k: "tstr" }, st: st } }
            else { typeof_arith_long(st, op, lt, rt, line, col) }
        } else if (lt.k == "tbool") {
            if (rt.k == "tstr") { { typ: { k: "tstr" }, st: st } }
            else { typeof_arith_long(st, op, lt, rt, line, col) }
        } else { typeof_arith_long(st, op, lt, rt, line, col) }
    } else { typeof_arith_long(st, op, lt, rt, line, col) }
};

def typeof_arith_long(st: { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long }, op: str, lt, rt, line: long, col: long) -> { typ: { k: str }, st: { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long } } {
    // Numeric arithmetic. If either side is a float the result is a float
    // and the other side widens (long -> float, the only coercion).
    if (lt.k == "tfloat" || rt.k == "tfloat") {
        st = expect_type(st, lt, { k: "tfloat" }, "'" + op + "' left operand", line, col);
        st = expect_type(st, rt, { k: "tfloat" }, "'" + op + "' right operand", line, col);
        { typ: { k: "tfloat" }, st: st }
    } else {
        st = expect_type(st, lt, { k: "tlong" }, "'" + op + "' left operand", line, col);
        st = expect_type(st, rt, { k: "tlong" }, "'" + op + "' right operand", line, col);
        { typ: { k: "tlong" }, st: st }
    }
};

def typeof_cmp(st: { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long }, op: str, lt, rt, line: long, col: long) -> { typ: { k: str }, st: { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long } } {
    if (lt.k == "tstr") {
        // str < str is lexicographic ordering (byte by byte), matching the
        // VM and the compiled C runtime.
        st = expect_type(st, rt, { k: "tstr" }, "'" + op + "' right operand", line, col);
        { typ: { k: "tbool" }, st: st }
    } else if (lt.k == "tfloat" || rt.k == "tfloat") {
        st = expect_type(st, lt, { k: "tfloat" }, "'" + op + "' left operand", line, col);
        st = expect_type(st, rt, { k: "tfloat" }, "'" + op + "' right operand", line, col);
        { typ: { k: "tbool" }, st: st }
    } else {
        st = expect_type(st, lt, { k: "tlong" }, "'" + op + "' left operand", line, col);
        st = expect_type(st, rt, { k: "tlong" }, "'" + op + "' right operand", line, col);
        { typ: { k: "tbool" }, st: st }
    }
};

// Both sides numeric (long/byte/float): `==` and `!=` compare by value
// across widths, matching how the C engines treat these.
def is_num_kind(t) -> bool {
    if (t.k == "tlong") { true }
    else if (t.k == "tbyte") { true }
    else if (t.k == "tfloat") { true }
    else { false }
};

def num_eq_ok(lt, rt) -> bool {
    if (is_num_kind(lt)) { is_num_kind(rt) } else { false }
};

def typeof_eq(st: { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long }, op: str, lt, rt, line: long, col: long) -> { typ: { k: str }, st: { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long } } {
    // str compares by content (null-safe: str vs null is allowed).
    // Nested ifs throughout (see lexer.y isalnum note).
    if (teq(lt, rt)) { { typ: { k: "tbool" }, st: st } }
    else if (num_eq_ok(lt, rt)) {
        // Numeric kinds compare across widths: a byte IS a small long, so
        // `c == 10` needs no cast (and long/float already coerce in `<`).
        { typ: { k: "tbool" }, st: st }
    }
    else if (lt.k == "tstr") {
        if (rt.k == "tstr") { { typ: { k: "tbool" }, st: st } }
        else if (rt.k == "tunk") { { typ: { k: "tbool" }, st: st } }
        else if (rt.k == "tnull") { { typ: { k: "tbool" }, st: st } }
        else {
            st = fail(st, "'" + op + "' compares " + tstr(lt) + " with " + tstr(rt), line, col);
            { typ: { k: "tbool" }, st: st }
        }
    } else if (lt.k == "tunk") {
        { typ: { k: "tbool" }, st: st }
    } else if (lt.k == "tnull") {
        if (rt.k == "tstr") { { typ: { k: "tbool" }, st: st } }
        else {
            st = fail(st, "'" + op + "' compares " + tstr(lt) + " with " + tstr(rt), line, col);
            { typ: { k: "tbool" }, st: st }
        }
    } else if (lt.k == "topt") {
        // options null-check (`x == null`) plus same-option comparison.
        // Anything else is a type error (t10 parity for non-options).
        if (rt.k == "tnull") { { typ: { k: "tbool" }, st: st } }
        else if (rt.k == "tunk") { { typ: { k: "tbool" }, st: st } }
        else if (teq(lt, rt)) { { typ: { k: "tbool" }, st: st } }
        else {
            st = fail(st, "'" + op + "' compares " + tstr(lt) + " with " + tstr(rt), line, col);
            { typ: { k: "tbool" }, st: st }
        }
    } else if (rt.k == "topt") {
        if (lt.k == "tnull") { { typ: { k: "tbool" }, st: st } }
        else if (lt.k == "tunk") { { typ: { k: "tbool" }, st: st } }
        else {
            st = fail(st, "'" + op + "' compares " + tstr(lt) + " with " + tstr(rt), line, col);
            { typ: { k: "tbool" }, st: st }
        }
    } else {
        st = fail(st, "'" + op + "' compares " + tstr(lt) + " with " + tstr(rt), line, col);
        { typ: { k: "tbool" }, st: st }
    }
};

def typeof_logic(st: { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long }, op: str, lt, rt, line: long, col: long) -> { typ: { k: str }, st: { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long } } {
    // Truthiness: any 8-byte value decides (nonzero = true), like the C
    // runtime. The result is always a bool; operands keep their own types.
    { typ: { k: "tbool" }, st: st }
};

// Compatibility (stricter than equality): a `str` value IS a NUL-terminated
// address at runtime, so it flows into `*T` positions (explicit lengths come
// from the caller; byte-level access is future work). Everything else must
// match exactly — no other implicit conversions. Used for annotations,
// assignments, arguments and returns. Branch agreement (if/else) and ==/!=
// keep using strict teq.
// NOTE: unannotated shapes (tnone/tname from missing annotations) unify
// with anything HERE so one root cause yields one error at its site
// (the missing-annotation error), not a cascade at every use.
// NOTE: trec shapes unify STRUCTURALLY here (superset accepts subset —
// extra fields are ignored by the C backend AND by native codegen, which
// reads static indexes): parser.y's {k}-annotated node params accept call,
// index, dot, map, func literals without a cascade at every res() site.
// Branch agreement and ==/!= keep strict teq (e11/e12 parity).
def tcompat(got, want) -> bool {
    if (teq(got, want)) { true }
    else if (got.k == "tnone") { true }
    else if (want.k == "tnone") { true }
    else if (got.k == "tname") { true }
    else if (want.k == "tname") { true }
    else if (got.k == "tparams") { true }
    else if (want.k == "tparams") { true }
    else if (got.k == "trec") {
        if (want.k == "trec") { trec_compat(got, want) } else { false }
    } else if (want.k == "trec") {
        // GOT is a bare {k}-shaped node (e.g. parser.y's res() param flows a
        // call/index/dot/map/func literal into a {k:str} slot): accept — the
        // specific literal shape is validated at its own construction site.
        if (got.k == "tstr") { false } else { true }
    }
    else if (got.k == "tstr") {
        if (want.k == "tptr") { true } else { false }
    } else if (got.k == "tlong") {
        // long widens to float (the only numeric coercion, matching the
        // C engines: `2.0 * i` and `x + 1` with a float x).
        // long also narrows to byte: there is no cast syntax, so an
        // annotated position is the only place the intent can be stated
        // (`let b: byte = 65`, `push(bs, n)`, a byte-typed parameter).
        // The value is masked to 8 bits where it is stored.
        if (want.k == "tfloat") { true }
        else if (want.k == "tbyte") { true }
        else { false }
    } else if (got.k == "tbyte") {
        // byte widens to long (and on to float) — it is an 8-bit unsigned
        // integer, so every value is representable.
        if (want.k == "tlong") { true }
        else if (want.k == "tfloat") { true }
        else { false }
    } else { false }
};

// An array/[v; n] LITERAL may adopt a narrower annotated element type
// (`let b: [byte] = [104, 105]`). Restricted to literals on purpose: the
// layouts differ (packed vs one word each), so reinterpreting an existing
// array would be a type pun.
def arr_lit_adopts(got, want) -> bool {
    if (got.k == "tarr") { arr_lit_adopts_go(got, want) }
    else if (got.k == "tarrfix") { arr_lit_adopts_go(got, want) }
    else { false }
};

def arr_lit_adopts_go(got, want) -> bool {
    if (want.k == "tarr") { tcompat(got.of, want.of) }
    else if (want.k == "tarrfix") {
        if (got.k == "tarrfix") {
            if (got.n == want.n) { tcompat(got.of, want.of) } else { false }
        } else { tcompat(got.of, want.of) }
    }
    else { false }
};

// Every field WANT declares must exist in GOT with a compatible type;
// extra GOT fields are fine (structurally ignored downstream).
def trec_compat(got, want) -> bool {
    let wfs = want.fields;
    let gfs = got.fields;
    trec_compat_go(gfs, wfs, 0)
};

def trec_compat_go(gfs, wfs, i: long) -> bool {
    if (i >= len(wfs)) { true }
    else {
        let wf = wfs[i];
        if (trec_has(gfs, wf.name, wf.typ)) { trec_compat_go(gfs, wfs, i + 1) }
        else { false }
    }
};

def trec_has(gfs, name: str, typ) -> bool {
    let i = 0;
    let found = false;
    while (i < len(gfs)) {
        let gf = gfs[i];
        if (gf.name == name) {
            if (tcompat(gf.typ, typ)) { found = true; 0; } else { 0; };
            0
        } else { 0 };
        i = i + 1;
    };
    found
};

def typeof_expr(st: { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long }, node) -> { typ: { k: str }, st: { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long } } {
    let k = node.k;
    if (k == "num") {
        if (num_is_float(node.v)) {
            { typ: { k: "tfloat" }, st: st }
        } else {
            { typ: { k: "tlong" }, st: st }
        }
    } else if (k == "str") {
        { typ: { k: "tstr" }, st: st }
    } else if (k == "err") {
        // Planted by the parser where the token stream stopped making
        // sense (parser.y has no error channel of its own).
        st = fail(st, node.msg, node.line, node.col);
        { typ: t_unk(), st: st }
    } else if (k == "bool") {
        { typ: { k: "tbool" }, st: st }
    } else if (k == "null") {
        // NO null type: null IS the option-empty value (value-or-null
        // options on this toolchain — some() is identity, is_some is
        // (v != null)). The literal is the unknown option; `x == null`
        // is the is-none check and assignments require a T?.
        { typ: { k: "topt", of: t_unk() }, st: st }
    } else if (k == "id") {
        if (node.v == "self") {
            // resolved by the enclosing def pre-pass (stored as _self in st)
            if (st.self.k == "tnone") {
                st = fail(st, "'self' outside of a function", node.line, node.col);
                { typ: t_unk(), st: st }
            } else {
                { typ: st.self, st: st }
            }
        } else {
            let got = lookup(st.bindings, node.v);
            if (got.kind == "") {
                if (node.v == "none") {
                    // the empty option (type from context via unification)
                    { typ: { k: "topt", of: t_unk() }, st: st }
                } else {
                    st = fail(st, "undefined variable '" + node.v + "'", node.line, node.col);
                    { typ: t_unk(), st: st }
                }
            } else {
                st = check_visible(st, got, node.v, node.line, node.col);
                { typ: got.typ, st: st }
            }
        }
    } else if (k == "un") {
        let r = typeof_expr(st, node.e);
        st = r.st;
        if (node.op == "-") {
            if (r.typ.k == "tfloat") {
                { typ: { k: "tfloat" }, st: st }
            } else {
                st = expect_type(st, r.typ, { k: "tlong" }, "unary '-'", node.line, node.col);
                { typ: { k: "tlong" }, st: st }
            }
        } else {
            st = expect_type(st, r.typ, { k: "tbool" }, "unary '!'", node.line, node.col);
            { typ: { k: "tbool" }, st: st }
        }
    } else if (k == "addr") {
        // &x (plain local/param) or &a[i] (element address, either array).
        // NOTE: no `&&` guard here — the VM evaluates both sides eagerly,
        // so a missing field on the right would crash. Nested ifs instead.
        if (node.e.k == "id") {
            if (node.e.v != "self") {
                let got = lookup(st.bindings, node.e.v);
                if (got.kind == "") {
                    st = fail(st, "undefined variable '" + node.e.v + "'", node.line, node.col);
                    { typ: t_unk(), st: st }
            } else if (got.kind == "func" || got.kind == "intrinsic") {
                st = fail(st, "cannot take the address of function '" + node.e.v + "'", node.line, node.col);
                { typ: t_unk(), st: st }
            } else if (got.typ.k == "tarr") {
                st = fail(st, "cannot take the address of a whole heap array (use &" + disp(node.e.v) + "[i] for elements)", node.line, node.col);
                { typ: t_unk(), st: st }
            } else if (got.typ.k == "tarrfix") {
                st = check_visible(st, got, node.e.v, node.line, node.col);
                // address of the first element (e.g. read(fd, &buf, n))
                { typ: { k: "tptr", to: got.typ.of }, st: st }
            } else {
                st = check_visible(st, got, node.e.v, node.line, node.col);
                { typ: { k: "tptr", to: got.typ }, st: st }
            }
            } else {
                st = fail(st, "'&' needs a plain variable (only locals/params have addresses)", node.line, node.col);
                { typ: t_unk(), st: st }
            }
        } else if (node.e.k == "index") {
            let ix = node.e.idx;
            let arr = node.e.arr;
            if (arr.k == "id") {
                let got = lookup(st.bindings, arr.v);
                if (got.kind == "") {
                    st = fail(st, "undefined variable '" + arr.v + "'", node.line, node.col);
                    { typ: t_unk(), st: st }
                } else if (got.typ.k == "tarrfix" || got.typ.k == "tarr") {
                    st = check_visible(st, got, arr.v, node.line, node.col);
                    let r = typeof_expr(st, ix);
                    st = r.st;
                    st = expect_type(st, r.typ, { k: "tlong" }, "array index", node.line, node.col);
                    { typ: { k: "tptr", to: got.typ.of }, st: st }
                } else {
                    st = fail(st, "cannot index " + tstr(got.typ) + " (only arrays)", node.line, node.col);
                    { typ: t_unk(), st: st }
                }
            } else {
                st = fail(st, "'&' needs a plain variable element (&a[i])", node.line, node.col);
                { typ: t_unk(), st: st }
            }
        } else {
            st = fail(st, "'&' needs a plain variable (only locals/params have addresses)", node.line, node.col);
            { typ: t_unk(), st: st }
        }
    } else if (k == "deref") {
        let r = typeof_expr(st, node.e);
        st = r.st;
        if (r.typ.k == "tptr") {
            { typ: r.typ.to, st: st }
        } else if (r.typ.k == "tunk") {
            { typ: t_unk(), st: st }
        } else {
            st = fail(st, "cannot dereference " + tstr(r.typ) + " (need *T)", node.line, node.col);
            { typ: t_unk(), st: st }
        }
    } else if (k == "bin") {
        let l = typeof_expr(st, node.l);
        let r = typeof_expr(l.st, node.r);
        st = r.st;
        let op = node.op;
        // NOTE: nested ifs, not `||` chains (see lexer.y isalnum note): the
        // C VM evaluates both sides eagerly AND the checker rejects `||`
        // mixing comparison-bool with map-field shapes through one gate.
        if (op == "+") { typeof_arith(st, op, l.typ, r.typ, node.line, node.col) }
        else if (op == "-") { typeof_arith(st, op, l.typ, r.typ, node.line, node.col) }
        else if (op == "*") { typeof_arith(st, op, l.typ, r.typ, node.line, node.col) }
        else if (op == "/") { typeof_arith(st, op, l.typ, r.typ, node.line, node.col) }
        else if (op == "%") { typeof_arith(st, op, l.typ, r.typ, node.line, node.col) }
        else if (op == "<") { typeof_cmp(st, op, l.typ, r.typ, node.line, node.col) }
        else if (op == ">") { typeof_cmp(st, op, l.typ, r.typ, node.line, node.col) }
        else if (op == "<=") { typeof_cmp(st, op, l.typ, r.typ, node.line, node.col) }
        else if (op == ">=") { typeof_cmp(st, op, l.typ, r.typ, node.line, node.col) }
        else if (op == "==") { typeof_eq(st, op, l.typ, r.typ, node.line, node.col) }
        else if (op == "!=") { typeof_eq(st, op, l.typ, r.typ, node.line, node.col) }
        else if (op == "&&") { typeof_logic(st, op, l.typ, r.typ, node.line, node.col) }
        else if (op == "||") { typeof_logic(st, op, l.typ, r.typ, node.line, node.col) }
        else {
            st = fail(st, "operator '" + op + "' is unsupported in native mode", node.line, node.col);
            { typ: t_unk(), st: st }
        }
    } else if (k == "call") {
        typeof_call(st, node)
    } else if (k == "if") {
        let c = typeof_expr(st, node.cond);
        st = expect_type(c.st, c.typ, { k: "tbool" }, "'if' condition", node.line, node.col);
        // NOTE: typeof_expr, not typeof_block — `els` may be a nested `if`
        // (else-if chain), not a block.
        let t = typeof_expr(st, node.then);
        st = t.st;
        if (node.has_else) {
            let e = typeof_expr(st, node.els);
            st = e.st;
            if (!teq(t.typ, e.typ)) {
                // Void mixing: when either arm computes no value (void /
                // null statements), the whole if is a statement — no
                // disagreement error, the value arm's value is discarded.
                let tk: str = t.typ.k;
                let ek: str = e.typ.k;
                if (tk == "tvoid" || tk == "tnull" || ek == "tvoid" || ek == "tnull") {
                    0
                } else {
                    st = fail(st, "'if' branches disagree: " + tstr(t.typ) + " vs " + tstr(e.typ), node.line, node.col);
                    0
                };
                0
            } else { 0; };
            { typ: t.typ, st: st }
        } else {
            // VOID law: an `if` without `else` is a STATEMENT — its value is
            // nothing, whatever the then-branch computes. No forced else
            // branch, no forced `0;` tail in user programs.
            { typ: { k: "tvoid" }, st: st }
        }
    } else if (k == "while") {
        let c = typeof_expr(st, node.cond);
        st = expect_type(c.st, c.typ, { k: "tbool" }, "'while' condition", node.line, node.col);
        let b = typeof_block(st, node.body);
        { typ: { k: "tvoid" }, st: b.st }
    } else if (k == "for") {
        // for (init; cond; step) body — init/step are statements, and the
        // loop variable stays visible afterwards (same scope rule as `let`).
        let fi = typeof_expr(st, node.init);
        st = fi.st;
        let fc = typeof_expr(st, node.cond);
        st = expect_type(fc.st, fc.typ, { k: "tbool" }, "'for' condition", node.line, node.col);
        let fb = typeof_block(st, node.body);
        st = fb.st;
        let fs = typeof_expr(st, node.step);
        { typ: { k: "tvoid" }, st: fs.st }
    } else if (k == "foreach") {
        // foreach (x in arr) body — x takes the array's element type.
        let fe = typeof_expr(st, node.iter);
        st = fe.st;
        let elt = t_unk();
        if (fe.typ.k == "tarr") { elt = fe.typ.of; 0; }
        else if (fe.typ.k == "tarrfix") { elt = fe.typ.of; 0; }
        else if (fe.typ.k == "tunk") { 0; }
        else {
            st = fail(st, "'foreach' needs an array, got " + tstr(fe.typ), node.line, node.col);
            0
        };
        st = st_bind(st, node.name, elt, "local");
        let fbb = typeof_block(st, node.body);
        { typ: { k: "tvoid" }, st: fbb.st }
    } else if (k == "forrange") {
        // forrange (x in lo..hi) body — x is a long.
        let rl = typeof_expr(st, node.lo);
        st = expect_type(rl.st, rl.typ, { k: "tlong" }, "'for' range start", node.line, node.col);
        let rh = typeof_expr(st, node.hi);
        st = expect_type(rh.st, rh.typ, { k: "tlong" }, "'for' range end", node.line, node.col);
        st = st_bind(st, node.name, { k: "tlong" }, "local");
        let rb = typeof_block(st, node.body);
        { typ: { k: "tvoid" }, st: rb.st }
    } else if (k == "block") {
        typeof_block(st, node)
    } else if (k == "decl") {
        typeof_decl(st, node)
    } else if (k == "assign") {
        let r = typeof_expr(st, node.v);
        st = r.st;
        let got = lookup(st.bindings, node.name);
        if (got.kind == "") {
            st = fail(st, "undefined variable '" + disp(node.name) + "'", node.line, node.col);
            { typ: t_unk(), st: st }
        } else if (got.kind == "func" || got.kind == "intrinsic") {
            st = fail(st, "cannot assign to function '" + disp(node.name) + "'", node.line, node.col);
            { typ: t_unk(), st: st }
        } else if (got.typ.k == "tarrfix") {
            st = check_visible(st, got, node.name, node.line, node.col);
            st = expect_type(st, r.typ, got.typ, "assignment to '" + disp(node.name) + "'", node.line, node.col);
            { typ: got.typ, st: st }
        } else {
            st = check_visible(st, got, node.name, node.line, node.col);
            st = expect_type(st, r.typ, got.typ, "assignment to '" + disp(node.name) + "'", node.line, node.col);
            { typ: got.typ, st: st }
        }
    } else if (k == "store") {
        let p = typeof_expr(st, node.p);
        let v = typeof_expr(p.st, node.v);
        st = v.st;
        if (p.typ.k == "tptr") {
            st = expect_type(st, v.typ, p.typ.to, "store through pointer", node.line, node.col);
            { typ: p.typ.to, st: st }
        } else if (p.typ.k == "tunk" || v.typ.k == "tunk") {
            { typ: t_unk(), st: st }
        } else {
            st = fail(st, "store target must be *T, got " + tstr(p.typ), node.line, node.col);
            { typ: t_unk(), st: st }
        }
    } else if (k == "ret") {
        if (st.ret.k == "tnone") {
            st = fail(st, "'return' outside of a function", node.line, node.col);
            { typ: t_unk(), st: st }
        } else {
            let r = typeof_expr(st, node.e);
            st = expect_type(r.st, r.typ, st.ret, "'return'", node.line, node.col);
            { typ: st.ret, st: st }
        }
    } else if (k == "map") {
        // Record literal { k: v, ... }: every value checked, the type is a
        // trec with field names in order. Empty maps need an annotation
        // (nothing to infer — like []).
        let mkeys = node.keys;
        let mvals = node.vals;
        if (len(mkeys) == 0) {
            st = fail(st, "cannot infer record type: annotate the map", node.line, node.col);
            { typ: t_unk(), st: st }
        } else {
            let fields = [];
            let i = 0;
            let ok = true;
            while (i < len(mkeys)) {
                // NOTE: each bound once — `x.y[i]` chains misparse on the C VM.
                let mvv = mvals[i];
                let mkey = mkeys[i];
                let r = typeof_expr(st, mvv);
                st = r.st;
                if (r.typ.k == "tnone") {
                    // unannotated value shape (tcompat law): the missing
                    // annotation errors once at its own site; don't cascade
                    // here, but poison the record so uses don't mistype.
                    ok = false;
                    0
                } else if (r.typ.k == "tname") {
                    ok = false;
                    0
                } else if (!is_value_type(r.typ)) {
                    st = fail(st, "record field '" + mkey + "' has unsupported type " + tstr(r.typ), node.line, node.col);
                    ok = false;
                    0
                } else { 0; };
                fields = push(fields, { name: mkey, typ: r.typ });
                i = i + 1;
            };
            if (ok) {
                { typ: { k: "trec", fields: fields }, st: st }
            } else {
                { typ: t_unk(), st: st }
            }
        }
    } else if (k == "dot") {
        // Record field read: obj must be a trec with that field.
        // NOTE: each bound once — `node.obj` inline misparses on the C VM.
        // NOTE: flow-snapshot (dobj/dkey bound once, never rebound): the
        // checker env is flow-INSENSITIVE (last shape wins per name), so a
        // field read must go through a name bound to exactly one shape.
        // Re-reading `node.obj` after any `node = ...` rebind in the same
        // function would resolve against the rebound shape.
        let dobj = node.obj;
        let dkey = node.key;
        let r = typeof_expr(st, dobj);
        st = r.st;
        if (r.typ.k == "trec") {
            let found = false;
            let ftyp = t_unk();
            let fs = r.typ.fields;
            let j = 0;
            while (j < len(fs)) {
                // NOTE: bound once — `x.y[i]` chains misparse on the C VM.
                // NOTE: :str bindings (see teq note).
                let f = fs[j];
                let fn: str = f.name;
                if (fn == dkey) {
                    found = true;
                    ftyp = f.typ;
                    0
                } else { 0 };
                j = j + 1;
                0
            };
            if (found) {
                { typ: ftyp, st: st }
            } else if (teq(r.typ, unk_shape())) {
                // unknown-shape ({k}-only) reads unify quietly (tcompat
                // law) — the missing annotation errors once at its own
                // site, not again at every enclosing read. Concrete
                // records still error below (emitter rejects loudly).
                { typ: t_unk(), st: st }
            } else {
                st = fail(st, "record has no field '" + dkey + "'", node.line, node.col);
                { typ: t_unk(), st: st }
            }
        } else if (r.typ.k == "tunk") {
            { typ: t_unk(), st: st }
        } else if (r.typ.k == "tnone") {
            // bare-hole params (see typeof_def note): unify quietly.
            { typ: t_unk(), st: st }
        } else if (r.typ.k == "tname") {
            { typ: t_unk(), st: st }
        } else if (r.typ.k == "tparams") {
            { typ: t_unk(), st: st }
        } else if (r.typ.k == "tnull") {
            { typ: t_unk(), st: st }
        } else {
            st = fail(st, "cannot read field '" + node.key + "' of " + tstr(r.typ) + " (need a record)", node.line, node.col);
            { typ: t_unk(), st: st }
        }
    } else if (k == "func") {
        // Anonymous function literal in expression position. Check the body
        // like a named def would be, and give the expression its tfunc type;
        // the emitter closure-converts it with a generated label.
        let ra = typeof_def(st, "", node, node.line, node.col);
        { typ: ra.typ, st: ra.st }
    } else if (k == "arrrep") {
        // [v; n]: n stack slots filled with v (the native array form)
        let r = typeof_expr(st, node.v);
        st = r.st;
        if (!is_value_type(r.typ)) {
            st = fail(st, "array element type " + tstr(r.typ) + " is unsupported in native mode", node.line, node.col);
            { typ: t_unk(), st: st }
        } else if (node.n < 0) {
            st = fail(st, "array size must be a non-negative integer literal ([v; n])", node.line, node.col);
            { typ: t_unk(), st: st }
        } else {
            { typ: { k: "tarrfix", of: r.typ, n: node.n }, st: st }
        }
    } else if (k == "index") {
        // Indexing binds a name once (no x.y[i] chains — the C parser
        // misreads them; see teq note). Plain locals, params, AND function
        // params of array type alike: frames or heap headers address them
        // directly; bounds are checked at runtime. Fixed [T; N] and heap
        // [T] alike. Params of tunk (missing annotation) error elsewhere —
        // here they poison quietly to avoid cascades.
        if (node.arr.k == "id") {
            let got = lookup(st.bindings, node.arr.v);
            if (got.kind == "") {
                st = fail(st, "undefined variable '" + node.arr.v + "'", node.line, node.col);
                { typ: t_unk(), st: st }
            } else if (got.typ.k == "tarrfix" || got.typ.k == "tarr") {
                st = check_visible(st, got, node.arr.v, node.line, node.col);
                let r = typeof_expr(st, node.idx);
                st = r.st;
                st = expect_type(st, r.typ, { k: "tlong" }, "array index", node.line, node.col);
                { typ: got.typ.of, st: st }
            } else if (got.typ.k == "tunk" || got.typ.k == "tnone" || got.typ.k == "tname") {
                let r = typeof_expr(st, node.idx);
                st = r.st;
                { typ: t_unk(), st: st }
            } else {
                st = fail(st, "cannot index " + tstr(got.typ) + " (only arrays)", node.line, node.col);
                { typ: t_unk(), st: st }
            }
        } else {
            st = fail(st, "only plain variables can be indexed in native mode", node.line, node.col);
            { typ: t_unk(), st: st }
        }
    } else if (k == "slice") {
        // arr[lo:hi] -> a new array of the same element type. Missing
        // bounds default to 0 / len; the result is always a heap [T],
        // even when slicing a fixed [T; N].
        let sr = typeof_expr(st, node.arr);
        st = sr.st;
        let slo = node.lo;
        let shi = node.hi;
        if (slo.k == "null") { 0; } else {
            let rl = typeof_expr(st, slo);
            st = expect_type(rl.st, rl.typ, { k: "tlong" }, "slice start", node.line, node.col);
            0
        };
        if (shi.k == "null") { 0; } else {
            let rh = typeof_expr(st, shi);
            st = expect_type(rh.st, rh.typ, { k: "tlong" }, "slice end", node.line, node.col);
            0
        };
        if (sr.typ.k == "tarr") {
            { typ: { k: "tarr", of: sr.typ.of }, st: st }
        } else if (sr.typ.k == "tarrfix") {
            { typ: { k: "tarr", of: sr.typ.of }, st: st }
        } else if (sr.typ.k == "tunk") {
            { typ: t_unk(), st: st }
        } else {
            st = fail(st, "cannot slice " + tstr(sr.typ) + " (only arrays)", node.line, node.col);
            { typ: t_unk(), st: st }
        }
    } else if (k == "dotassign") {
        // s.f = v — in-place record field write. The object must be a plain
        // variable holding a record; the field must exist in its static
        // shape (checked at the map literal / annotation site).
        if (node.obj.k == "id") {
            let got = lookup(st.bindings, node.obj.v);
            if (got.kind == "") {
                st = fail(st, "undefined variable '" + node.obj.v + "'", node.line, node.col);
                { typ: t_unk(), st: st }
            } else if (got.typ.k == "trec") {
                let ft = trec_field_type(got.typ, node.key);
                if (ft.k == "tnone") {
                    st = fail(st, "record has no field '" + node.key + "'", node.line, node.col);
                    { typ: t_unk(), st: st }
                } else {
                    let v = typeof_expr(st, node.v);
                    st = v.st;
                    st = expect_type(st, v.typ, ft, "record field '" + node.key + "'", node.line, node.col);
                    { typ: ft, st: st }
                }
            } else {
                st = fail(st, "cannot field-assign " + tstr(got.typ) + " (only records)", node.line, node.col);
                { typ: t_unk(), st: st }
            }
        } else {
            st = fail(st, "only plain variables can be dot-assigned in native mode", node.line, node.col);
            { typ: t_unk(), st: st }
        }
    } else if (k == "idxassign") {
        if (node.arr.k == "id") {
            let got = lookup(st.bindings, node.arr.v);
            if (got.kind == "") {
                st = fail(st, "undefined variable '" + node.arr.v + "'", node.line, node.col);
                { typ: t_unk(), st: st }
            } else if (got.typ.k == "tarrfix" || got.typ.k == "tarr") {
                st = check_visible(st, got, node.arr.v, node.line, node.col);
                let ix = typeof_expr(st, node.idx);
                st = ix.st;
                st = expect_type(st, ix.typ, { k: "tlong" }, "array index", node.line, node.col);
                let v = typeof_expr(st, node.v);
                st = v.st;
                st = expect_type(st, v.typ, got.typ.of, "array element", node.line, node.col);
                { typ: got.typ.of, st: st }
            } else {
                st = fail(st, "cannot index " + tstr(got.typ) + " (only arrays)", node.line, node.col);
                { typ: t_unk(), st: st }
            }
        } else {
            st = fail(st, "only plain variables can be indexed in native mode", node.line, node.col);
            { typ: t_unk(), st: st }
        }
    } else if (k == "array") {
        // Heap dynamic array literal [v, ...]. Element type = first element;
        // [] needs an annotation ([T]) since there is nothing to infer from.
        // NOTE: tnone/tname element shapes (from unannotated subexpressions)
        // unify quietly here — the missing-annotation error fires once at
        // its own site, not again at every enclosing literal (tcompat law).
        let elems = node.elems;
        if (len(elems) == 0) {
            { typ: { k: "tarr", of: t_unk() }, st: st }
        } else {
            let e0 = elems[0];
            let r0 = typeof_expr(st, e0);
            st = r0.st;
            if (r0.typ.k == "tnone") {
                { typ: { k: "tarr", of: t_unk() }, st: st }
            } else if (r0.typ.k == "tname") {
                { typ: { k: "tarr", of: t_unk() }, st: st }
            } else if (r0.typ.k == "tarr") {
                // nested array literal [[..], ..]: inner element type unknown
                // yet (missing annotation inside) — unify quietly, report once.
                { typ: { k: "tarr", of: t_unk() }, st: st }
            } else if (r0.typ.k == "tnull") {
                // [null, ..]: option inference is future work — unify quietly.
                { typ: { k: "tarr", of: t_unk() }, st: st }
            } else if (!is_value_type(r0.typ)) {
                st = fail(st, "array element type " + tstr(r0.typ) + " is unsupported in native mode", node.line, node.col);
                { typ: t_unk(), st: st }
            } else {
                let i = 1;
                let elt = r0.typ;
                while (i < len(elems)) {
                    let r = typeof_expr(st, elems[i]);
                    st = r.st;
                    // NOTE: tnone/tname/poison shapes unify quietly (tcompat
                    // law) — the root cause errors once at its own site.
                    // A poisoned FIRST element (tunk) adopts the first known
                    // later element so [f(x), 1] reports only f's own error.
                    if (elt.k == "tunk") {
                        if (r.typ.k == "tlong") { elt = r.typ; 0; } else { 0; };
                        if (r.typ.k == "tbool") { elt = r.typ; 0; } else { 0; };
                        if (r.typ.k == "tstr") { elt = r.typ; 0; } else { 0; };
                        0
                    } else {
                        st = expect_type(st, r.typ, elt, "array element", node.line, node.col);
                        0
                    };
                    i = i + 1;
                };
                { typ: { k: "tarr", of: elt }, st: st }
            }
        }
    } else {
        st = fail(st, "'" + k + "' is unsupported in native mode (heap planned: maps, loops, strings ops)", node.line, node.col);
        { typ: t_unk(), st: st }
    }
};

def typeof_call(st: { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long }, node) -> { typ: { k: str }, st: { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long } } {
    // callee must be a plain id (direct calls only — no func pointers yet)
    // NOTE: cargs bound once — `node.args[i]` inline misparses on the C VM.
    let cargs = node.args;
    if (node.callee.k != "id") {
        // Calling an expression: legal when it yields a function value
        // (an immediately-invoked literal, an element of an array of
        // functions, ...). The emitter goes through its code pointer.
        let cf = typeof_expr(st, node.callee);
        st = cf.st;
        if (cf.typ.k == "tfunc") {
            let cft = cf.typ;
            let cfargs = cft.args;
            if (len(cargs) != len(cfargs)) {
                st = fail(st, "call takes " + tostring(len(cfargs)) + " args, got " + tostring(len(cargs)), node.line, node.col);
                { typ: cft.ret, st: st }
            } else {
                let ci = 0;
                while (ci < len(cargs)) {
                    let ra = typeof_expr(st, cargs[ci]);
                    st = ra.st;
                    st = expect_type(st, ra.typ, cfargs[ci], "call arg " + tostring(ci), node.line, node.col);
                    ci = ci + 1;
                };
                { typ: cft.ret, st: st }
            }
        } else {
            st = fail(st, "cannot call " + tstr(cf.typ) + " (not a function)", node.line, node.col);
            let i = 0;
            while (i < len(node.args)) {
                let r = typeof_expr(st, cargs[i]);
                st = r.st;
                i = i + 1;
            };
            { typ: t_unk(), st: st }
        }
    } else {
        let name = node.callee.v;
        if (name == "print") {
            if (len(node.args) != 1) {
                st = fail(st, "print takes exactly 1 argument", node.line, node.col);
                { typ: { k: "tvoid" }, st: st }
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                if (r.typ.k == "tlong" || r.typ.k == "tbyte" || r.typ.k == "tbool" || r.typ.k == "tstr" || r.typ.k == "tfloat" || r.typ.k == "tunk" || r.typ.k == "trec" || r.typ.k == "tfunc") {
                    { typ: { k: "tvoid" }, st: st }
                } else {
                    st = fail(st, "print supports long/bool/float/str/record/function, got " + tstr(r.typ), node.line, node.col);
                    { typ: { k: "tvoid" }, st: st }
                }
            }
        } else if (name == "len") {
            if (len(cargs) != 1) {
                st = fail(st, "len takes exactly 1 argument", node.line, node.col);
                { typ: { k: "tlong" }, st: st }
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                if (r.typ.k == "tarrfix" || r.typ.k == "tarr" || r.typ.k == "tstr") {
                    { typ: { k: "tlong" }, st: st }
                } else if (r.typ.k == "tunk" || r.typ.k == "tnone" || r.typ.k == "tname") {
                    // poison/unannotated shape (tcompat law): root cause
                    // errors once at its own site; len() unifies quietly.
                    { typ: { k: "tlong" }, st: st }
                } else {
                    st = fail(st, "len supports arrays and strings, got " + tstr(r.typ), node.line, node.col);
                    { typ: { k: "tlong" }, st: st }
                }
            }
        } else if (name == "some") {
            // some(v) -> typeof(v)? (boxes v on the heap; 0 = none)
            if (len(cargs) != 1) {
                st = fail(st, "some takes exactly 1 argument", node.line, node.col);
                { typ: t_unk(), st: st }
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                if (!is_value_type(r.typ)) {
                    st = fail(st, "cannot put " + tstr(r.typ) + " in an option", node.line, node.col);
                    { typ: t_unk(), st: st }
                } else {
                    { typ: { k: "topt", of: r.typ }, st: st }
                }
            }
        } else if (name == "is_some") {
            if (len(cargs) != 1) {
                st = fail(st, "is_some takes exactly 1 argument", node.line, node.col);
                { typ: { k: "tbool" }, st: st }
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                if (r.typ.k == "topt" || r.typ.k == "tunk") {
                    { typ: { k: "tbool" }, st: st }
                } else {
                    st = fail(st, "is_some needs an option, got " + tstr(r.typ), node.line, node.col);
                    { typ: { k: "tbool" }, st: st }
                }
            }
        } else if (name == "unwrap") {
            if (len(cargs) != 1) {
                st = fail(st, "unwrap takes exactly 1 argument", node.line, node.col);
                { typ: t_unk(), st: st }
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                if (r.typ.k == "topt") {
                    { typ: r.typ.of, st: st }
                } else if (r.typ.k == "tunk") {
                    { typ: t_unk(), st: st }
                } else if (r.typ.k == "tnull") {
                    // hole shapes (see dot-arm note): unify quietly.
                    { typ: t_unk(), st: st }
                } else if (r.typ.k == "tnone") {
                    { typ: t_unk(), st: st }
                } else if (r.typ.k == "tname") {
                    { typ: t_unk(), st: st }
                } else if (r.typ.k == "tparams") {
                    { typ: t_unk(), st: st }
                } else {
                    st = fail(st, "unwrap needs an option, got " + tstr(r.typ), node.line, node.col);
                    { typ: t_unk(), st: st }
                }
            }
        } else if (name == "push") {            // push(arr, v) -> arr (possibly reallocated; rebind the result:
            // `a = push(a, v)`). Only heap arrays grow; fixed arrays reject.
            if (len(cargs) != 2) {
                st = fail(st, "push takes exactly 2 arguments (array, value)", node.line, node.col);
                { typ: t_unk(), st: st }
            } else {
                let r0 = typeof_expr(st, cargs[0]);
                st = r0.st;
                if (r0.typ.k == "tarrfix") {
                    // A fixed array's length is part of its type ([T; N]),
                    // so growing it would break every later bound check.
                    st = fail(st, "cannot push to fixed array " + tstr(r0.typ) + " (its length is part of its type; use [T] instead)", node.line, node.col);
                    let r1f = typeof_expr(st, cargs[1]);
                    st = r1f.st;
                    { typ: t_unk(), st: st }
                } else if (r0.typ.k != "tarr") {
                    st = fail(st, "push needs a heap array, got " + tstr(r0.typ), node.line, node.col);
                    { typ: t_unk(), st: st }
                } else if (r0.typ.of.k == "tunk") {
                    // push(x, v) where x's element type is poison/unknown:
                    // still check v for its own errors, but don't cascade
                    // a second "cannot infer" (the root cause errors once).
                    // NOTE: r1 bound once above? No — r1 not yet bound here;
                    // bind fresh (r1b) to avoid double-type of cargs[1].
                    let r1b = typeof_expr(st, cargs[1]);
                    st = r1b.st;
                    { typ: t_unk(), st: st }
                } else {
                    let r1c = typeof_expr(st, cargs[1]);
                    st = r1c.st;
                    st = expect_type(st, r1c.typ, r0.typ.of, "push value", node.line, node.col);
                    { typ: r0.typ, st: st }
                }
            }
        } else if (name == "substr") {
            // substr(s, start, count) -> str (C-clamped semantics)
            if (len(cargs) != 3) {
                st = fail(st, "substr takes exactly 3 arguments (string, start, count)", node.line, node.col);
                { typ: t_unk(), st: st }
            } else {
                let r0 = typeof_expr(st, cargs[0]);
                st = r0.st;
                let r1 = typeof_expr(st, cargs[1]);
                st = r1.st;
                let r2 = typeof_expr(st, cargs[2]);
                st = r2.st;
                st = expect_type(st, r0.typ, { k: "tstr" }, "substr string", node.line, node.col);
                st = expect_type(st, r1.typ, { k: "tlong" }, "substr start", node.line, node.col);
                st = expect_type(st, r2.typ, { k: "tlong" }, "substr count", node.line, node.col);
                { typ: { k: "tstr" }, st: st }
            }
        } else if (name == "trim") {
            if (len(cargs) != 1) {
                st = fail(st, "trim takes exactly 1 argument", node.line, node.col);
                { typ: t_unk(), st: st }
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                st = expect_type(st, r.typ, { k: "tstr" }, "trim string", node.line, node.col);
                { typ: { k: "tstr" }, st: st }
            }
        } else if (name == "ord") {
            // ord(s) -> long (first byte, -1 if empty)
            if (len(cargs) != 1) {
                st = fail(st, "ord takes exactly 1 argument", node.line, node.col);
                { typ: t_unk(), st: st }
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                st = expect_type(st, r.typ, { k: "tstr" }, "ord string", node.line, node.col);
                { typ: { k: "tlong" }, st: st }
            }
        } else if (name == "chr") {
            if (len(cargs) != 1) {
                st = fail(st, "chr takes exactly 1 argument", node.line, node.col);
                { typ: t_unk(), st: st }
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                st = expect_type(st, r.typ, { k: "tlong" }, "chr code", node.line, node.col);
                { typ: { k: "tstr" }, st: st }
            }
        } else if (name == "tonum") {
            if (len(cargs) != 1) {
                st = fail(st, "tonum takes exactly 1 argument", node.line, node.col);
                { typ: t_unk(), st: st }
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                st = expect_type(st, r.typ, { k: "tstr" }, "tonum string", node.line, node.col);
                { typ: { k: "tlong" }, st: st }
            }
        } else if (name == "tostring") {
            if (len(cargs) != 1) {
                st = fail(st, "tostring takes exactly 1 argument", node.line, node.col);
                { typ: t_unk(), st: st }
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                if (r.typ.k == "tlong" || r.typ.k == "tbyte" || r.typ.k == "tbool" || r.typ.k == "tstr" || r.typ.k == "tfloat" || r.typ.k == "tunk" || r.typ.k == "tarr" || r.typ.k == "tarrfix") {
                    { typ: { k: "tstr" }, st: st }
                } else {
                    st = fail(st, "tostring supports long/bool/float/str/array, got " + tstr(r.typ), node.line, node.col);
                    { typ: t_unk(), st: st }
                }
            }
        } else if (name == "typeof") {
            if (len(cargs) != 1) {
                st = fail(st, "typeof takes exactly 1 argument", node.line, node.col);
                { typ: t_unk(), st: st }
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                { typ: { k: "tstr" }, st: st }
            }
        } else if (name == "index_of" || name == "last_index_of") {
            if (len(cargs) != 2) {
                st = fail(st, name + " takes exactly 2 arguments (string, sub)", node.line, node.col);
                { typ: t_unk(), st: st }
            } else {
                let r0 = typeof_expr(st, cargs[0]);
                st = r0.st;
                let r1 = typeof_expr(st, cargs[1]);
                st = r1.st;
                st = expect_type(st, r0.typ, { k: "tstr" }, name + " string", node.line, node.col);
                st = expect_type(st, r1.typ, { k: "tstr" }, name + " sub", node.line, node.col);
                { typ: { k: "tlong" }, st: st }
            }
        } else if (name == "join") {
            // join(arr, delim) -> str (elements via tostring, like C)
            if (len(cargs) != 2) {
                st = fail(st, "join takes exactly 2 arguments (array, delimiter)", node.line, node.col);
                { typ: t_unk(), st: st }
            } else {
                let r0 = typeof_expr(st, cargs[0]);
                st = r0.st;
                let r1 = typeof_expr(st, cargs[1]);
                st = r1.st;
                if (r0.typ.k != "tarr" && r0.typ.k != "tunk") {
                    st = fail(st, "join needs an array, got " + tstr(r0.typ), node.line, node.col);
                    0
                } else { 0; };
                st = expect_type(st, r1.typ, { k: "tstr" }, "join delimiter", node.line, node.col);
                { typ: { k: "tstr" }, st: st }
            }
        } else if (name == "split") {
            // split(s, delim) -> [str]
            if (len(cargs) != 2) {
                st = fail(st, "split takes exactly 2 arguments (string, delimiter)", node.line, node.col);
                { typ: t_unk(), st: st }
            } else {
                let r0 = typeof_expr(st, cargs[0]);
                st = r0.st;
                let r1 = typeof_expr(st, cargs[1]);
                st = r1.st;
                st = expect_type(st, r0.typ, { k: "tstr" }, "split string", node.line, node.col);
                st = expect_type(st, r1.typ, { k: "tstr" }, "split delimiter", node.line, node.col);
                { typ: { k: "tarr", of: { k: "tstr" } }, st: st }
            }
        } else if (name == "range") {
            // range(n) -> [long]: 0, 1, ..., n-1
            if (len(cargs) != 1) {
                st = fail(st, "range takes exactly 1 argument", node.line, node.col);
                { typ: { k: "tarr", of: { k: "tlong" } }, st: st }
            } else {
                let rr = typeof_expr(st, cargs[0]);
                st = expect_type(rr.st, rr.typ, { k: "tlong" }, "range count", node.line, node.col);
                { typ: { k: "tarr", of: { k: "tlong" } }, st: st }
            }
        } else if (name == "eputs") {
            // eputs(v) -> void: like puts, but to stderr (fd 2), so
            // diagnostics never mix into program stdout or `-S` output.
            if (len(cargs) != 1) {
                st = fail(st, "eputs takes exactly 1 argument", node.line, node.col);
                { typ: { k: "tvoid" }, st: st }
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                if (r.typ.k == "tlong" || r.typ.k == "tbool" || r.typ.k == "tstr" || r.typ.k == "tfloat" || r.typ.k == "tunk") {
                    { typ: { k: "tvoid" }, st: st }
                } else {
                    st = fail(st, "eputs supports long/bool/str, got " + tstr(r.typ), node.line, node.col);
                    { typ: { k: "tvoid" }, st: st }
                }
            }
        } else if (name == "clock_us") {
            // clock_us() -> long: monotonic microseconds (differences only).
            if (len(cargs) != 0) {
                st = fail(st, "clock_us takes no arguments", node.line, node.col);
                { typ: { k: "tlong" }, st: st }
            } else {
                { typ: { k: "tlong" }, st: st }
            }
        } else if (name == "heap_used") {
            // heap_used() -> long: arena bytes handed out so far.
            if (len(cargs) != 0) {
                st = fail(st, "heap_used takes no arguments", node.line, node.col);
                { typ: { k: "tlong" }, st: st }
            } else {
                { typ: { k: "tlong" }, st: st }
            }
        } else if (name == "sleep") {
            // sleep(ms): suspend the caller for ms milliseconds.
            if (len(cargs) != 1) {
                st = fail(st, "sleep takes exactly 1 argument (milliseconds)", node.line, node.col);
                { typ: { k: "tnull" }, st: st }
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                st = expect_type(st, r.typ, { k: "tlong" }, "sleep duration", node.line, node.col);
                { typ: { k: "tnull" }, st: st }
            }
        } else if (name == "puts") {
            if (len(cargs) != 1) {
                st = fail(st, "puts takes exactly 1 argument", node.line, node.col);
                { typ: { k: "tvoid" }, st: st }
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                if (r.typ.k == "tlong" || r.typ.k == "tbool" || r.typ.k == "tstr" || r.typ.k == "tfloat" || r.typ.k == "tunk") {
                    { typ: { k: "tvoid" }, st: st }
                } else {
                    st = fail(st, "puts supports long/bool/str, got " + tstr(r.typ), node.line, node.col);
                    { typ: { k: "tvoid" }, st: st }
                }
            }
        } else if (name == "exit") {
            if (len(cargs) != 1) {
                st = fail(st, "exit takes exactly 1 argument", node.line, node.col);
                { typ: { k: "tvoid" }, st: st }
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                st = expect_type(st, r.typ, { k: "tlong" }, "exit code", node.line, node.col);
                { typ: { k: "tvoid" }, st: st }
            }
        } else if (name == "argv") {
            if (len(cargs) != 0) {
                st = fail(st, "argv takes no arguments", node.line, node.col);
                { typ: { k: "tarr", of: { k: "tstr" } }, st: st }
            } else {
                { typ: { k: "tarr", of: { k: "tstr" } }, st: st }
            }
        } else if (name == "read_file") {
            if (len(cargs) != 1) {
                st = fail(st, "read_file takes exactly 1 argument (path)", node.line, node.col);
                { typ: t_unk(), st: st }
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                st = expect_type(st, r.typ, { k: "tstr" }, "read_file path", node.line, node.col);
                // NOTE: typed str? (option): a missing file yields null at
                // RUNTIME on both toolchains (callers null-check with
                // `== null`, then unwrap). Matches native.y infer.
                { typ: { k: "topt", of: { k: "tstr" } }, st: st }
            }
        } else if (name == "bytes") {
            // bytes(s) -> [byte]: the string's raw bytes, packed.
            if (len(cargs) != 1) {
                st = fail(st, "bytes takes exactly 1 argument (string)", node.line, node.col);
                { typ: { k: "tarr", of: { k: "tbyte" } }, st: st }
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                st = expect_type(st, r.typ, { k: "tstr" }, "bytes argument", node.line, node.col);
                { typ: { k: "tarr", of: { k: "tbyte" } }, st: st }
            }
        } else if (name == "from_bytes") {
            // from_bytes(b) -> str: the inverse of bytes().
            if (len(cargs) != 1) {
                st = fail(st, "from_bytes takes exactly 1 argument (byte array)", node.line, node.col);
                { typ: { k: "tstr" }, st: st }
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                st = expect_type(st, r.typ, { k: "tarr", of: { k: "tbyte" } }, "from_bytes argument", node.line, node.col);
                { typ: { k: "tstr" }, st: st }
            }
        } else if (name == "write_file") {
            if (len(cargs) != 2) {
                st = fail(st, "write_file takes exactly 2 arguments (path, content)", node.line, node.col);
                { typ: t_unk(), st: st }
            } else {
                let r0 = typeof_expr(st, cargs[0]);
                st = r0.st;
                let r1 = typeof_expr(st, cargs[1]);
                st = r1.st;
                st = expect_type(st, r0.typ, { k: "tstr" }, "write_file path", node.line, node.col);
                st = expect_type(st, r1.typ, { k: "tstr" }, "write_file content", node.line, node.col);
                { typ: { k: "tbool" }, st: st }
            }
        } else if (name == "write_bytes") {
            // write_bytes(path, bytes, mode) -> bool: tinycc-style binary
            // emit (open/write/chmod over raw syscalls in native code).
            // bytes is a heap [long] array (elf.y output); mode is a long
            // (493 = 0755 executable, -1 = skip chmod).
            if (len(cargs) != 3) {
                st = fail(st, "write_bytes takes exactly 3 arguments (path, bytes, mode)", node.line, node.col);
                { typ: t_unk(), st: st }
            } else {
                let w0 = typeof_expr(st, cargs[0]);
                st = w0.st;
                let w1 = typeof_expr(st, cargs[1]);
                st = w1.st;
                let w2 = typeof_expr(st, cargs[2]);
                st = w2.st;
                st = expect_type(st, w0.typ, { k: "tstr" }, "write_bytes path", node.line, node.col);
                if (w1.typ.k != "tarr" && w1.typ.k != "tunk") {
                    st = fail(st, "write_bytes needs a byte array, got " + tstr(w1.typ), node.line, node.col);
                    0
                } else { 0; };
                st = expect_type(st, w2.typ, { k: "tlong" }, "write_bytes mode", node.line, node.col);
                { typ: { k: "tbool" }, st: st }
            }
        } else if (name == "ptr_addr") {
            // ptr_addr(p) -> long: a pointer's numeric value. Pointers ARE
            // longs at run time; this is the one place the type system lets
            // that through, so Y code can build a char** (an array of
            // addresses) without the backend growing a bespoke helper.
            if (len(cargs) != 1) {
                st = fail(st, "ptr_addr takes exactly 1 argument (pointer)", node.line, node.col);
                { typ: { k: "tlong" }, st: st }
            } else {
                let r = typeof_expr(st, cargs[0]);
                st = r.st;
                if (r.typ.k == "tptr" || r.typ.k == "tstr" || r.typ.k == "tunk") {
                    { typ: { k: "tlong" }, st: st }
                } else {
                    st = fail(st, "ptr_addr needs a pointer, got " + tstr(r.typ), node.line, node.col);
                    { typ: { k: "tlong" }, st: st }
                }
            }
        } else if (name == "syscall") {            if (len(node.args) < 1 || len(node.args) > 7) {
                st = fail(st, "syscall needs 1-7 arguments (number + up to 6 args)", node.line, node.col);
                { typ: { k: "tlong" }, st: st }
            } else {
                let i = 0;
                while (i < len(node.args)) {
                    let r = typeof_expr(st, cargs[i]);
                    st = r.st;
                    if (r.typ.k != "tlong" && r.typ.k != "tbool" && r.typ.k != "tstr" && r.typ.k != "tptr" && r.typ.k != "tunk") {
                        st = fail(st, "syscall arg " + tostring(i) + " must be long/bool/str/*T, got " + tstr(r.typ), node.line, node.col);
                        0
                    } else { 0; };
                    i = i + 1;
                };
                { typ: { k: "tlong" }, st: st }
            }
        } else {
            // resolve the callee to a function type: `self`, then scope
            let fterr = "";
            let ft = t_unk();
            if (name == "self") {
                if (st.self.k == "tnone" || st.self.k == "tunk") {
                    fterr = "'self' outside of a function";
                    0
                } else {
                    ft = st.self;
                    0
                };
            } else {
                let got = lookup(st.bindings, name);
                if (got.kind == "") {
                    fterr = "undefined function '" + disp(name) + "'";
                    0
                } else if (got.typ.k == "tfunc") {
                    // Either a hoisted `def` (kind "func") or a local/param
                    // holding a closure value — both are callable.
                    ft = got.typ;
                    0
                } else {
                    fterr = "'" + disp(name) + "' is not a function";
                    0
                };
            };
            if (fterr != "") {
                st = fail(st, fterr, node.line, node.col);
                { typ: t_unk(), st: st }
            } else if (ft.k != "tfunc") {
                // poisoned binding (tunk) from an earlier error — don't
                // cascade new errors, but still check the arguments for
                // their own errors.
                let i = 0;
                while (i < len(cargs)) {
                    let r = typeof_expr(st, cargs[i]);
                    st = r.st;
                    i = i + 1;
                };
                { typ: t_unk(), st: st }
            } else {
                let cargs_ft = ft.args;
                if (len(cargs) != len(cargs_ft)) {
                    st = fail(st, "'" + disp(name) + "' takes " + tostring(len(cargs_ft)) + " args, got " + tostring(len(cargs)), node.line, node.col);
                    { typ: ft.ret, st: st }
                } else {
                    let i = 0;
                    while (i < len(cargs)) {
                        let r = typeof_expr(st, cargs[i]);
                        st = r.st;
                        st = expect_type(st, r.typ, cargs_ft[i], "'" + disp(name) + "' arg " + tostring(i), node.line, node.col);
                        i = i + 1;
                    };
                    { typ: ft.ret, st: st }
                }
            }
        }
    }
};

def typeof_block(st: { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long }, node) -> { typ: { k: str }, st: { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long } } {
    // No scope push: names are unique post-rename, blocks share the frame.
    let last = { k: "tvoid" };
    let bstmts = node.stmts;
    let i = 0;
    while (i < len(bstmts)) {
        let r = typeof_expr(st, bstmts[i]);
        st = r.st;
        last = r.typ;
        i = i + 1;
    };
    { typ: last, st: st }
};


def typeof_decl(st: { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long }, node) -> { typ: { k: str }, st: { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long } } {
    if (node.kind == "def") {
        // named function: full check (signature + body)
        typeof_def(st, node.name, node.v, node.line, node.col)
    } else {
        // let/const. A literal def on the right names a function WITHOUT
        // going through typeof_expr (a bare func value is only legal bound).
        // Same for the `[v; n]` array literal (binds n frame slots).
        if (node.v.k == "func") {
            let fr = typeof_def(st, node.name, node.v, node.line, node.col);
            st = fr.st;
            if (node.typ.k != "tnone") {
                st = expect_type(st, fr.typ, node.typ, "let '" + disp(node.name) + "'", node.line, node.col);
                0
            } else { 0; };
            st = st_bind(st, node.name, fr.typ, "func");
            { typ: fr.typ, st: st }
        } else if (node.v.k == "arrrep") {
            let r = typeof_expr(st, node.v);
            st = r.st;
            if (r.typ.k == "tunk") {
                st = st_bind(st, node.name, t_unk(), "local");
                { typ: t_unk(), st: st }
            } else {
                let at = r.typ;
                if (node.typ.k != "tnone") {
                    if (arr_lit_adopts(r.typ, node.typ)) {
                        0
                    } else {
                        st = expect_type(st, r.typ, node.typ, "let '" + disp(node.name) + "'", node.line, node.col);
                        0
                    };
                    at = node.typ;
                    0
                } else { 0; };
                st = st_bind(st, node.name, at, "local");
                { typ: at, st: st }
            }
        } else {
            let r = typeof_expr(st, node.v);
            st = r.st;
            let t = r.typ;
            let vk = node.v.k;
            if (node.typ.k != "tnone") {
                if (!is_value_type(node.typ)) {
                    st = fail(st, "annotation '" + tstr(node.typ) + "' is not a native value type", node.line, node.col);
                    0
                } else if (vk == "array") {
                    // An array LITERAL adopts the annotated element type:
                    // `let b: [byte] = [104, 105]` packs those elements
                    // into one byte each. Only literals — assigning an
                    // existing [long] to a [byte] binding would reinterpret
                    // eight-byte slots as one, so that still errors.
                    if (arr_lit_adopts(r.typ, node.typ)) { 0; } else {
                        st = expect_type(st, r.typ, node.typ, "let '" + disp(node.name) + "'", node.line, node.col);
                        0;
                    };
                    t = node.typ;
                    0
                } else {
                    st = expect_type(st, r.typ, node.typ, "let '" + disp(node.name) + "'", node.line, node.col);
                    t = node.typ;
                    0
                };
                0
            } else { 0; };
            // NOTE: tnone/tname (unannotated initializer shapes) unify
            // quietly (tcompat law) — the missing annotation errors once at
            // its own site, not again at every enclosing let.
            if (t.k == "tnone") {
                t = t_unk();
                0
            } else if (t.k == "tname") {
                t = t_unk();
                0
            } else if (t.k == "tvoid") {
                st = fail(st, "cannot bind a void value to '" + disp(node.name) + "'", node.line, node.col);
                t = t_unk();
                0
            } else if (!is_value_type(t)) {
                st = fail(st, "'" + tstr(t) + "' is unsupported in native mode (heap planned)", node.line, node.col);
                t = t_unk();
                0
            } else { 0; };
            st = st_bind(st, node.name, t, "local");
            { typ: t, st: st }
        }
    }
};

// Check a func value bound to `name` (def decl or let-bound anonymous def).
// Returns updated st; binds name as kind "func" with its tfunc type.
def typeof_def(st: { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long }, name: str, func, line: long, col: long) -> { typ: { k: str }, st: { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long } } {
    if (len(func.params) != len(func.ptypes)) {
        st = fail(st, "internal: params/ptypes length mismatch", line, col);
        { typ: t_unk(), st: st }
    } else {
        let args = [];
        // NOTE: bound once — `func.params[i]` inline misparses on the C VM.
        let fparams = func.params;
        let fptypes = func.ptypes;
        let i = 0;
        let ok = true;
        while (i < len(fparams)) {
            let pt = fptypes[i];
            if (pt.k == "tnone") {
                // OPTIONAL ANNOTATIONS v1: a missing param annotation is a
                // poison-tolerant unknown (t_unk). This covers BOTH the ycc
                // pipeline's bare-hole plumbing params (the C parser cannot
                // annotate record shapes on them) AND user-written defs
                // without annotations — holes and user params now type
                // identically. Caveat: the emitter has no runtime tag, so a
                // richer value (str/record) flowing into an unannotated
                // param behaves as a plain long there; annotate those sites.
                pt = t_unk();
                0
            } else if (!is_value_type(pt) && pt.k != "tfunc") {
                st = fail(st, "parameter '" + disp(fparams[i]) + "' has unpassable type " + tstr(pt) + " (arrays cannot cross function boundaries — pass &a plus a length)", line, col);
                ok = false;
                0
            } else { 0; };
            args = push(args, pt);
            i = i + 1;
        };
        let ret = func.ret;
        let ret_inferred = false;
        if (ret.k == "tnone") {
            // OPTIONAL ANNOTATIONS + inference v1: the return type comes
            // from the body's tail value once the body has been checked.
            // Until then the signature carries poison tunk so recursion
            // and forward calls still unify.
            ret_inferred = true;
            ret = t_unk();
            0
        } else { 0; };
        let ft = { k: "tfunc", args: args, ret: ret };
        // bind early so recursion via `self`/name works
        st = st_bind(st, name, ft, "func");
        // check the body one level deeper. Outer locals/params stay in the
        // flat map but with a smaller fdepth: touching one is a capture
        // (there is no heap for environments yet).
        let saved_self = st.self;
        let saved_ret = st.ret;
        let saved_depth = st.fdepth;
        st = st_fdepth(st, saved_depth + 1);
        let j = 0;
        while (j < len(fparams)) {
            st = st_bind(st, fparams[j], args[j], "param");
            j = j + 1;
        };
        st = st_self(st, ft);
        st = st_ret(st, ret);
        let b = typeof_block(st, func.body);
        st = b.st;
        if (ret_inferred) {
            // INFERENCE: the def's return type is the body's tail value.
            // Unannotated sub-shapes (tnone) stay poison; tunk stays tunk.
            let br = b.typ;
            if (br.k == "tnone") {
                br = t_unk();
                0
            } else { 0; };
            ft = { k: "tfunc", args: args, ret: br };
            st = st_bind(st, name, ft, "func");
            0
        } else { 0; };
        if (!(ret_inferred)) {
            st = expect_type(st, b.typ, ret, "'" + disp(name) + "' body", line, col);
            0
        } else { 0; };
        st = st_fdepth(st, saved_depth);
        st = st_self(st, saved_self);
        st = st_ret(st, saved_ret);
        if (ok) {
            { typ: ft, st: st }
        } else {
            // poison the binding so follow-on errors don't cascade weirdly
            st = st_bind(st, name, t_unk(), "func");
            { typ: t_unk(), st: st }
        }
    }
};

def st_fdepth(st: { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long }, d: long) -> { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long } { { bindings: st.bindings, errors: st.errors, ret: st.ret, self: st.self, fdepth: d } };

def check_func_value(st: { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long }, name: str, func, line: long, col: long) -> { bindings: [{ name: str, typ: { k: str }, kind: str, fdepth: long }], errors: [{ msg: str, line: long, col: long }], ret: { k: str }, self: { k: str }, fdepth: long } {
    // let-bound anonymous def: same rules as a named def
    let r = typeof_def(st, name, func, line, col);
    r.st
};

// ── entry point ──────────────────────────────────────────────────────────

def check_program(ast) -> [{ msg: str, line: long, col: long }] {
    // pass 1: collect top-level def signatures (allows mutual recursion).
    let defs = [];
    let pstmts = ast.stmts;
    let i = 0;
    while (i < len(pstmts)) {
        let s = pstmts[i];
        // NOTE: nested ifs, not `&&`: the VM evaluates both sides eagerly,
        // so `s.kind`/`s.v.k` on a non-decl node would crash.
        if (s.k == "decl") {
            if (s.kind == "def") {
                defs = push(defs, def_sig(s.name, s.v));
                0
            } else if (s.v.k == "func") {
                // top-level let f = def... : also hoisted for mutual recursion
                defs = push(defs, def_sig(s.name, s.v));
                0
            } else { 0; };
            0
        } else { 0; };
        i = i + 1;
    };
    // pass 2: check everything in order (depth 0 = top level)
    let st = { bindings: [], errors: [], ret: { k: "tnone" }, self: { k: "tnone" }, fdepth: 0 };
    // intrinsics + top-level defs are visible at top level
    st = st_bind(st, "print", { k: "tfunc", args: [{ k: "tlong" }], ret: { k: "tvoid" } }, "intrinsic");
    st = st_bind(st, "syscall", { k: "tlong" }, "intrinsic");
    // (len/syscall specials are matched by name in typeof_call)
    let d = 0;
    while (d < len(defs)) {
        st = st_bind(st, defs[d].name, defs[d].typ, "func");
        d = d + 1;
    };
    let r = typeof_block(st, ast);
    r.st.errors
};

def def_sig(name: str, func) -> { name: str, typ: { k: str } } {
    // Signature for the pre-pass. Missing annotations are poison (tunk);
    // pass 2 (typeof_def) reports each exactly once.
    let args = [];
    let fpt = func.ptypes;
    let i = 0;
    while (i < len(func.params)) {
        let pt = fpt[i];
        if (pt.k == "tnone") { pt = t_unk(); };
        args = push(args, pt);
        i = i + 1;
    };
    let ret = func.ret;
    if (ret.k == "tnone") { ret = t_unk(); };
    { name: name, typ: { k: "tfunc", args: args, ret: ret } }
};

export { check_program, tstr, tdisp, tdisp_fnval };
