// parser.y — parse a token list into an AST of nested maps.
// Each parse function returns { node: <ast>, pos: <int> }.
// AST node kinds: num, str, id, bool, void (an absent expression), bin,
//   un, call, index, slice,
//   dot, assign, idxassign, decl, func, if, while, for, foreach, forrange,
//   block, array, rec, map, ret. Postfix `x!` is sugar for unwrap(x).

// ── token helpers ────────────────────────────────────────────────────────

def tclamp(toks: [{ t: str, v: str, line: long, col: long }], p: long) -> long {
    // The C VM wraps out-of-bounds indices modulo count (vm.c), so peeking
    // past EOF silently read toks[0] there. The native backend traps
    // instead — clamp every peek to the trailing "eof" token (lexer always
    // appends one) so both toolchains agree.
    let n = len(toks);
    let q = p;
    if (q >= n) { q = n - 1; 0; } else { 0; };
    q
};

def tt(toks: [{ t: str, v: str, line: long, col: long }], p: long) -> str {
    // NOTE: NEVER inline `toks[p].t` (dot-then-index): parser.c misparses
    // `x.y[i]` as `x.(y[i])` (AGENTS.md) — always bind first, then read.
    let tok = toks[tclamp(toks, p)];
    tok.t
};
def tv(toks: [{ t: str, v: str, line: long, col: long }], p: long) -> str {
    // NOTE: bound once (see tt note): `toks[p].v` inline would misparse.
    let tok = toks[tclamp(toks, p)];
    tok.v
};
def tline(toks: [{ t: str, v: str, line: long, col: long }], p: long) -> long {
    // NOTE: bound once (see tt note).
    let tok = toks[tclamp(toks, p)];
    tok.line
};
def tcol(toks: [{ t: str, v: str, line: long, col: long }], p: long) -> long {
    // NOTE: bound once (see tt note).
    let tok = toks[tclamp(toks, p)];
    tok.col
};

def is_kw(toks: [{ t: str, v: str, line: long, col: long }], p: long, w: str) -> bool {
    // NOTE: no `&&` — the C VM evaluates both sides eagerly AND the native
    // checker rejects `&&` mixing map-field shapes with bools (see lexer.y
    // isalnum note). Nested ifs keep both toolchains quiet.
    // NOTE: bound once — `toks[p].t` inline misparses (see tt note).
    let tok = toks[tclamp(toks, p)];
    if (tok.t == "kw") {
        if (tok.v == w) { true } else { false }
    } else { false }
};
def is_punct(toks: [{ t: str, v: str, line: long, col: long }], p: long, w: str) -> bool {
    // NOTE: bound once (see tt note).
    let tok = toks[tclamp(toks, p)];
    if (tok.t == "punct") {
        if (tok.v == w) { true } else { false }
    } else { false }
};
def is_op(toks: [{ t: str, v: str, line: long, col: long }], p: long, w: str) -> bool {
    // NOTE: bound once (see tt note).
    let tok = toks[tclamp(toks, p)];
    if (tok.t == "op") {
        if (tok.v == w) { true } else { false }
    } else { false }
};

// All AST nodes are maps; richer shapes (call, index, dot, map, func...)
// flow through one param typed as the TOP record shape {k:str, ...} —
// precisely: `{k:str}` would demand exactness, so res() takes an
// unannotated `node` and returns the same hole. The hole is filled by
// tcompat's tnone/tname/trec-unification (never by annotation-site
// strictness), so callers pass any literal shape cascade-free.
// (This comment documents WHY `res(node, ...)` stays bare: annotating it
// reintroduces the 225-error cascade at every call site.)
def res(node, p: long) -> { node: {k: str}, pos: long } {
    { node: node, pos: p }
};

// sep_by(one, close): parse a comma-separated list of `one(toks, pos)` results
// (each returning { node, pos }) until the `close` punct. Handles trailing
// commas. Returns { node: [nodes], pos } with pos AT the close punct (caller
// skips it). Replaces 6 copy-pasted comma-list loops.
// `one` is a production NAME ("expr" only, for now) — Y has no first-class
// functions in native mode, so callers name the production and sep_by
// dispatches (a defunctionalized stub: extend the if-chain for more).
// NOTE: toks is the token list [{ t, v, line, col }]; param typed tarr of
// trec so the checker accepts plain token-list arguments (e03 parity: real
// missing element types still error at the empty-array use sites).
def sep_by(toks: [{ t: str, v: str, line: long, col: long }], p: long, close: str, one: str) -> { node: [{k: str}], pos: long } {
    let xs: [{k: str}] = [];
    let pos = p;
    // NOTE: statement-form (not `let go = !(...)`): the `un` arm types
    // through the operand, and a call-shaped operand confuses inference.
    let go = true;
    if (is_punct(toks, pos, close)) { go = false; 0; } else { 0; };
    while (go) {
        // NOTE: bound once — `one(toks, pos)` inline misparses on the C VM.
        // NOTE: the seed hole `{node:{k:void},pos}` is tnone-typed; the
        // expr arm fills the SAME hole with a full node — the two shapes
        // unify via the tcompat law (never strict teq), so no branch error.
        // NOTE: `0;` tails — the while body must be void-typed (see note).
        let r = { node: { k: "void" }, pos: pos };
        if (one == "expr") {
            r = parse_expr(toks, pos);
            0
        } else { 0 };
        // NOTE: each bound once — `x.y` on a call result misparses on the
        // C backend (it reads `f().y` as `f(.y)`).
        let rnode = r.node;
        let rpos = r.pos;
        xs += rnode;
        pos = rpos;
        if (is_punct(toks, pos, ",")) {
            pos = pos + 1;
            if (is_punct(toks, pos, close)) { go = false; 0; } else { 0; };
            0
        } else {
            // Neither a separator nor the closer: the token stream is
            // malformed. parser.y has no error channel, so plant a node the
            // checker rejects — dropping the leftovers silently compiled
            // `print(1 zzz)` into `print(1)`.
            if (is_punct(toks, pos, close)) { 0; } else {
                xs += { k: "err", msg: "unexpected '" + tv(toks, pos) + "' (expected ',' or '" + close + "')", line: tline(toks, pos), col: tcol(toks, pos) };
                0;
            };
            go = false;
            0
        };
    };
    { node: xs, pos: pos }
};

// ── operator precedence ──────────────────────────────────────────────────

def op_prec(op: str) -> long {
    if (op == "||") { 1 }
    else if (op == "&&") { 2 }
    else if (op == "==") { 3 }
    else if (op == "!=") { 3 }
    else if (op == "<") { 4 }
    else if (op == ">") { 4 }
    else if (op == "<=") { 4 }
    else if (op == ">=") { 4 }
    else if (op == "::") { 5 }
    else if (op == "+") { 6 }
    else if (op == "-") { 6 }
    else if (op == "*") { 7 }
    else if (op == "/") { 7 }
    else if (op == "%") { 7 }
    else { 0 }
};

// ── primary expressions ──────────────────────────────────────────────────

def parse_primary(toks: [{ t: str, v: str, line: long, col: long }], p: long) -> { node: {k: str}, pos: long } {
    let t = tt(toks, p);
    let v = tv(toks, p);
    let ln = tline(toks, p);
    let cl = tcol(toks, p);
    if (t == "num") {
        res({ k: "num", v: v, line: ln, col: cl }, p + 1)
    } else if (t == "str") {
        res({ k: "str", v: v, line: ln, col: cl }, p + 1)
    } else if (t == "bstr") {
        // b"..." / b'...' -- a [byte] literal
        res({ k: "bstr", v: v, line: ln, col: cl }, p + 1)
    } else if (t == "id") {
        res({ k: "id", v: v, line: ln, col: cl }, p + 1)
    } else if (is_kw(toks, p, "true")) {
        res({ k: "bool", v: "true", line: ln, col: cl }, p + 1)
    } else if (is_kw(toks, p, "false")) {
        res({ k: "bool", v: "false", line: ln, col: cl }, p + 1)
    } else if (is_punct(toks, p, "(")) {
        let inner = parse_expr(toks, p + 1);
        res(inner.node, inner.pos + 1)  // skip ')'
    } else if (is_punct(toks, p, "[")) {
        parse_array(toks, p)
    } else if (is_punct(toks, p, "{")) {
        if (brace_is_map(toks, p)) { parse_map(toks, p) } else { parse_block(toks, p) }
    } else if (is_kw(toks, p, "def")) {
        parse_func(toks, p)
    } else if (is_kw(toks, p, "if")) {
        parse_if(toks, p)
    } else if (is_kw(toks, p, "while")) {
        parse_while(toks, p)
    } else if (is_kw(toks, p, "for")) {
        parse_for_or_range(toks, p)
    } else if (is_kw(toks, p, "foreach")) {
        parse_foreach(toks, p)
    } else {
        res({ k: "void" }, p + 1)
    }
};

// ── postfix: call, index, slice, dot ─────────────────────────────────────

def parse_postfix(toks: [{ t: str, v: str, line: long, col: long }], p: long) -> { node: {k: str}, pos: long } {
    let base = parse_primary(toks, p);
    let node = base.node;
    let pos = base.pos;
    let go = true;
    while (go) {
        if (is_punct(toks, pos, "(")) {
            let a = parse_args(toks, pos + 1);
            node = { k: "call", callee: node, args: a.node, line: tline(toks, pos), col: tcol(toks, pos) };
            pos = a.pos + 1;  // skip ')'
        } else if (is_punct(toks, pos, "[")) {
            // index or slice: arr[i], arr[lo:hi], arr[lo:], arr[:hi], arr[:]
            let bln = tline(toks, pos);
            let bcl = tcol(toks, pos);
            if (is_punct(toks, pos + 1, ":")) {
                if (is_punct(toks, pos + 2, "]")) {
                    // arr[:] — full slice
                    node = { k: "slice", arr: node, lo: { k: "void" }, hi: { k: "void" }, line: bln, col: bcl };
                    pos = pos + 3;  // skip '[', ':', ']'
                } else {
                    // arr[:hi] — no lo
                    let second = parse_expr(toks, pos + 2);
                    node = { k: "slice", arr: node, lo: { k: "void" }, hi: second.node, line: bln, col: bcl };
                    pos = second.pos + 1;  // skip ']'
                };
            } else {
                let first = parse_expr(toks, pos + 1);
                if (is_punct(toks, first.pos, ":")) {
                    if (is_punct(toks, first.pos + 1, "]")) {
                        // arr[lo:] — no hi
                        node = { k: "slice", arr: node, lo: first.node, hi: { k: "void" }, line: bln, col: bcl };
                        pos = first.pos + 2;  // skip ':' and ']'
                    } else {
                        // arr[lo:hi]
                        let second = parse_expr(toks, first.pos + 1);
                        node = { k: "slice", arr: node, lo: first.node, hi: second.node, line: bln, col: bcl };
                        pos = second.pos + 1;  // skip ']'
                    };
                } else {
                    // arr[i] — index
                    node = { k: "index", arr: node, idx: first.node, line: bln, col: bcl };
                    pos = first.pos + 1;  // skip ']'
                };
            };
        } else if (is_op(toks, pos, ".")) {
            let name = tv(toks, pos + 1);
            node = { k: "dot", obj: node, key: name, line: tline(toks, pos), col: tcol(toks, pos) };
            pos = pos + 2;
        } else if (is_op(toks, pos, "!")) {
            // x! -- postfix unwrap, exactly unwrap(x) (traps on none).
            let ua: [{k: str}] = [];
            ua += node;
            node = { k: "call", callee: { k: "id", v: "unwrap", line: tline(toks, pos), col: tcol(toks, pos) }, args: ua, line: tline(toks, pos), col: tcol(toks, pos) };
            pos = pos + 1;
        } else if (is_op(toks, pos, "++")) {
            // x++ — postfix: the OLD value is the expression's value, and
            // the target is evaluated once (a[f()]++ calls f once).
            node = { k: "incdec", op: "++", pre: false, tgt: node, line: tline(toks, pos), col: tcol(toks, pos) };
            pos = pos + 1;
            go = false;
            0
        } else if (is_op(toks, pos, "--")) {
            node = { k: "incdec", op: "--", pre: false, tgt: node, line: tline(toks, pos), col: tcol(toks, pos) };
            pos = pos + 1;
            go = false;
            0
        } else {
            go = false;
            0
        };
    };
    res(node, pos)
};

def parse_args(toks: [{ t: str, v: str, line: long, col: long }], p: long) -> { node: [{k: str}], pos: long } {
    sep_by(toks, p, ")", "expr")
};

// ── binary expressions (precedence climbing) ─────────────────────────────

def parse_binary(toks: [{ t: str, v: str, line: long, col: long }], p: long, min_prec: long) -> { node: {k: str}, pos: long } {
    let left_r = parse_unary(toks, p);
    let left = left_r.node;
    let pos = left_r.pos;
    let go = true;
    while (go) {
        let op = tv(toks, pos);
        let prec = 0;
        if (tt(toks, pos) == "op") { prec = op_prec(op); 0; } else { 0 };
        // NOTE: nested ifs, not `||` — the operands mix long (prec flags)
        // with bools and the checker rejects the joint gate (tcompat law:
        // only annotations unify, never branch conditions).
        // The explicit else arms end in long-valued `0`s, keeping their
        // types aligned; the terminating `;` discards the value.
        if (prec == 0) {
            go = false;
            0
        } else if (prec < min_prec) {
            go = false;
            0
        } else {
            // `::` is right-associative: 1 :: 2 :: [3] is 1 :: (2 :: [3])
            // = [1, 2, 3]. Everything else is left-associative.
            let next_min = prec + 1;
            if (op == "::") {
                next_min = prec;
                0
            } else { 0; };
            let right_r = parse_binary(toks, pos + 1, next_min);
            left = { k: "bin", op: op, l: left, r: right_r.node, line: tline(toks, pos), col: tcol(toks, pos) };
            pos = right_r.pos;
            0
        };
    };
    res(left, pos)
};

def parse_unary(toks: [{ t: str, v: str, line: long, col: long }], p: long) -> { node: {k: str}, pos: long } {
    // NOTE: nested ifs, not `||` (see parse_binary note): bool-gated call
    // shapes poison the joint `||` gate.
    if (is_op(toks, p, "-")) {
        let inner = parse_unary(toks, p + 1);
        res({ k: "un", op: tv(toks, p), e: inner.node, line: tline(toks, p), col: tcol(toks, p) }, inner.pos)
    } else if (is_op(toks, p, "!")) {
        let inner = parse_unary(toks, p + 1);
        res({ k: "un", op: tv(toks, p), e: inner.node, line: tline(toks, p), col: tcol(toks, p) }, inner.pos)
    } else if (is_op(toks, p, "&")) {
        // address-of: &x
        let inner = parse_unary(toks, p + 1);
        res({ k: "addr", e: inner.node, line: tline(toks, p), col: tcol(toks, p) }, inner.pos)
    } else if (is_op(toks, p, "*")) {
        // dereference: *p
        let inner = parse_unary(toks, p + 1);
        res({ k: "deref", e: inner.node, line: tline(toks, p), col: tcol(toks, p) }, inner.pos)
    } else if (is_op(toks, p, "++")) {
        // ++x — prefix: the NEW value is the expression's value
        let inner = parse_unary(toks, p + 1);
        res({ k: "incdec", op: "++", pre: true, tgt: inner.node, line: tline(toks, p), col: tcol(toks, p) }, inner.pos)
    } else if (is_op(toks, p, "--")) {
        let inner = parse_unary(toks, p + 1);
        res({ k: "incdec", op: "--", pre: true, tgt: inner.node, line: tline(toks, p), col: tcol(toks, p) }, inner.pos)
    } else {
        parse_postfix(toks, p)
    }
};

def parse_expr(toks: [{ t: str, v: str, line: long, col: long }], p: long) -> { node: {k: str}, pos: long } {
    parse_binary(toks, p, 1)
};

// ── compound literals ────────────────────────────────────────────────────

def parse_array(toks: [{ t: str, v: str, line: long, col: long }], p: long) -> { node: {k: str}, pos: long } {
    // p is AT '['. Forms: [] and [a, b] (heap literals, later),
    // [v; n] (stack repeat: n copies of v — the native array form).
    let ln = tline(toks, p);
    let cl = tcol(toks, p);
    if (is_punct(toks, p + 1, "]")) {
        res({ k: "array", elems: [], line: ln, col: cl }, p + 2)
    } else {
        let first = parse_expr(toks, p + 1);
        let pos = first.pos;
        if (is_punct(toks, pos, ";")) {
            // repeat: size must be a num literal (else n = -1 sentinel,
            // rejected with a clear error by the checker).
            // Both paths leave the optional count check with a long-valued
            // tail.
            let n = -1;
            pos = pos + 1;
            if (tt(toks, pos) == "num") {
                n = tonum(tv(toks, pos));
                pos = pos + 1;
                0
            } else { 0 };
            res({ k: "arrrep", v: first.node, n: n, line: ln, col: cl }, pos + 1)  // skip ']'
        } else {
            // literal, with trailing-comma tolerance
            // NOTE: statement-form init (not `let go = is_punct(...)`): the
            // `un`-typed call shape confuses inference (see sep_by note).
            let elems = [first.node];
            let go = true;
            if (is_punct(toks, pos, ",")) { 0; } else { go = false; 0; };
            while (go) {
                pos = pos + 1;  // skip ','
                if (is_punct(toks, pos, "]")) {
                    go = false;
                    0
                } else {
                    let e = parse_expr(toks, pos);
                    elems += e.node;
                    pos = e.pos;
                    go = is_punct(toks, pos, ",");
                    0
                };
            };
            // Same guard as sep_by: a token that is neither ',' nor ']'
            // means the stream is malformed, and dropping it silently would
            // compile `[1, 2 zzz]` as `[1, 2]`.
            if (is_punct(toks, pos, "]")) { 0; } else {
                elems += { k: "err", msg: "unexpected '" + tv(toks, pos) + "' (expected ',' or ']')", line: tline(toks, pos), col: tcol(toks, pos) };
                0;
            };
            res({ k: "array", elems: elems, line: ln, col: cl }, pos + 1)  // skip ']'
        }
    }
};

// `{` in expression position is ambiguous: a record literal (`{a: 1}`) or a
// block expression (`{ let t = 1; t + 1 }`). Only `{}`, `{key: ...}` and
// `{"key": ...}` are records; everything else is a block.
def brace_is_map(toks: [{ t: str, v: str, line: long, col: long }], p: long) -> bool {
    if (is_punct(toks, p + 1, "}")) {
        true
    } else {
        let k = tt(toks, p + 1);
        if (k == "id") {
            is_punct(toks, p + 2, ":")
        } else if (k == "str") {
            is_punct(toks, p + 2, ":")
        } else if (k == "kw") {
            is_punct(toks, p + 2, ":")
        } else if (k == "num") {
            is_punct(toks, p + 2, ":")
        } else if (is_op(toks, p + 1, "..")) {
            // `...obj` (lexed as `..` + `.`) opens a record literal
            true
        } else {
            false
        }
    }
};

def parse_map(toks: [{ t: str, v: str, line: long, col: long }], p: long) -> { node: {k: str}, pos: long } {
    // p is AT '{'
    let ln = tline(toks, p);
    let cl = tcol(toks, p);
    let keys = [];
    let vals = [];
    let is_map = false;
    let pos = p + 1;
    if (is_punct(toks, pos, "}")) {
        res(maplit_node(is_map, keys, vals, ln, cl), pos + 1)
    } else {
        let go = true;
        while (go) {
            // trailing comma: '}' right after ',' ends the map
            // NOTE: statement-form + `0;` tails — the while body must be
            // void-typed (see parse_binary note).
            if (is_punct(toks, pos, "}")) {
                go = false;
                0
            } else {
                // A quoted key makes a MAP literal ({k: "map"}); identifier
                // keys stay record fields ({k: "rec"}).
                if (is_map) {
                    0
                } else {
                    is_map = tt(toks, pos) == "str";
                    0
                };
                // Spread `...obj` lexes as `..` + `.`; the entry is
                // recorded under the "..." key with the source record as
                // its value (the checker and emitter merge it statically).
                let key = tv(toks, pos);
                if (key == "..") {
                    key = "...";
                    pos = pos + 2;  // the two dot tokens; there is no ':'
                    0
                } else {
                    pos = pos + 2;  // skip key and ':'
                    0
                };
                let e = parse_expr(toks, pos);
                keys += key;
                vals += e.node;
                pos = e.pos;
                if (is_punct(toks, pos, ",")) { pos = pos + 1; 0; } else { go = false; 0; };
                0
            };
        };
        res(maplit_node(is_map, keys, vals, ln, cl), pos + 1)  // skip '}'
    }
};

// `{a: 1}` is a record ({k: "rec"}), `{"a": 1}` a map ({k: "map"}).
def maplit_node(is_map: bool, keys: [str], vals: [{k: str}], ln: long, cl: long) -> {k: str} {
    if (is_map) { { k: "map", keys: keys, vals: vals, line: ln, col: cl } }
    else { { k: "rec", keys: keys, vals: vals, line: ln, col: cl } }
};

// ── type parsing ─────────────────────────────────────────────────────────
// Types are parsed into type-node maps (not just skipped): kinds tlong,
// tbool, tstr, tvoid, tname (unresolved name -> checker error), tptr {to},
// tarr {of}, tparams {ts} (parenthesized list, resolved by arrow context),
// tfunc {args, ret}, trec {fields: [{name, typ}]}, tmap {key, of},
// tnone (no annotation).
// Extra fields are ignored by the C backend, so this is additive.

def parse_type_node(toks: [{ t: str, v: str, line: long, col: long }], p: long) -> { node: {k: str}, pos: long } {
    // NOTE: NO `node`/`pos` locals shared across arms. Earlier this function
    // used one `node` name rebound in every arm; the checker env is
    // flow-INSENSITIVE (last shape wins), so `node.ts` in the arrow tail
    // resolved against the tfunc shape ("record has no field 'ts'") and
    // `target.arr` reads in parse_stmt resolved against rebound shapes.
    // The atom dispatches first, then ONE tail applies `?` + `->` with
    // fresh names only (parse_type_tail below).
    // (The C VM has no early return, but every arm's tail IS its res(),
    // so falling through is impossible — each arm is the last expression.)
    // NOTE: atom arms need parse_type_array/params/record/atom2 (defined
    // BELOW — forward refs are fine: defs hoist per block level in rename).
    if (is_op(toks, p, "*")) {
        // pointer type: *T
        let inner = parse_type_node(toks, p + 1);
        let pin = { k: "tptr", to: inner.node };
        parse_type_tail(toks, inner.pos, pin)
    } else if (is_punct(toks, p, "[")) {
        // array type: [T] (heap, later) or [T; N] (stack repeat, native now).
        // N must be a num literal (else -1 sentinel, rejected by checker).
        parse_type_array(toks, p)
    } else if (is_punct(toks, p, "(")) {
        // parenthesized / function-param list: (T, T)
        parse_type_params(toks, p)
    } else if (is_punct(toks, p, "{")) {
        // record type: { field: T, ... }
        parse_type_record(toks, p)
    } else {
        parse_type_atom2(toks, p)
    }
};

// [T] / [T; N] tail of parse_type_node: parses the bracketed shape, then
// the shared postfix tail (fresh names per arm — see note).
def parse_type_array(toks: [{ t: str, v: str, line: long, col: long }], p: long) -> { node: {k: str}, pos: long } {
    let inner = parse_type_node(toks, p + 1);
    if (is_punct(toks, inner.pos, ";")) {
        let n = -1;
        let np = inner.pos + 1;
        if (tt(toks, np) == "num") {
            n = tonum(tv(toks, np));
            np = np + 1;
            0
        } else { 0 };
        parse_type_tail(toks, np + 1, { k: "tarrfix", of: inner.node, n: n })  // skip ']'
    } else {
        parse_type_tail(toks, inner.pos + 1, { k: "tarr", of: inner.node })  // skip ']'
    }
};

// (T, T) tail of parse_type_node + shared postfix tail (fresh names — see note).
def parse_type_params(toks: [{ t: str, v: str, line: long, col: long }], p: long) -> { node: {k: str}, pos: long } {
    // NOTE: statement-form loops + `0;` tails — while bodies must be
    // void-typed (see parse_binary note).
    let ts = [];
    let pos = p + 1;  // skip '('
    if (!is_punct(toks, pos, ")")) {
        let go = true;
        while (go) {
            if (is_punct(toks, pos, ")")) {
                go = false;
                0
            } else {
                let t = parse_type_node(toks, pos);
                ts += t.node;
                pos = t.pos;
                if (is_punct(toks, pos, ",")) { pos = pos + 1; 0; } else { go = false; 0; };
                0
            };
        };
        0
    } else { 0 };
    parse_type_tparams(toks, pos + 1, ts)  // skip ')'
};

// The key type of a map type ({K => V}): K must be hashable (str, long,
// byte, bool, float). Anything else stays a named type for the checker
// to reject.
def map_key_type(name: str) -> {k: str} {
    if (name == "str") { { k: "tstr" } }
    else if (name == "long") { { k: "tlong" } }
    else if (name == "byte") { { k: "tbyte" } }
    else if (name == "bool") { { k: "tbool" } }
    else if (name == "float") { { k: "tfloat" } }
    else { { k: "tname", name: name } }
};

// { field: T, ... } tail of parse_type_node (fresh names — see note).
def parse_type_record(toks: [{ t: str, v: str, line: long, col: long }], p: long) -> { node: {k: str}, pos: long } {
    // `{ f: T, ... }` is a record shape; `{ K => V }` is a map type.
    let fields = [];
    let pos = p + 1;  // skip '{'
    if (!is_punct(toks, pos, "}")) {
        let go = true;
        while (go) {
            if (is_punct(toks, pos, "}")) {
                go = false;
                0
            } else {
                let fname = tv(toks, pos);
                if (is_op(toks, pos + 1, "=>")) {
                    // map type: the key is a type name, then =>, then V
                    let kt = map_key_type(fname);
                    let vt = parse_type_node(toks, pos + 2);
                    return parse_type_tail(toks, vt.pos + 1, { k: "tmap", key: kt, of: vt.node });
                };
                let ft = parse_type_node(toks, pos + 2);  // skip name and ':'
                fields += { name: fname, typ: ft.node };
                pos = ft.pos;
                if (is_punct(toks, pos, ",")) { pos = pos + 1; 0; } else { go = false; 0; };
                0
            };
        };
        0
    } else { 0 };
    parse_type_tail(toks, pos + 1, { k: "trec", fields: fields })  // skip '}'
};

// Simple type-name atom tail of parse_type_node (fresh names — see note).
def parse_type_atom2(toks: [{ t: str, v: str, line: long, col: long }], p: long) -> { node: {k: str}, pos: long } {
    // simple type name (`int` is `long`) + shared postfix tail.
    let nm = tv(toks, p);
    if (nm == "long") { parse_type_tail(toks, p + 1, { k: "tlong" }) }
    else if (nm == "int") { parse_type_tail(toks, p + 1, { k: "tlong" }) }
    else if (nm == "byte") { parse_type_tail(toks, p + 1, { k: "tbyte" }) }
    else if (nm == "bool") { parse_type_tail(toks, p + 1, { k: "tbool" }) }
    else if (nm == "str") { parse_type_tail(toks, p + 1, { k: "tstr" }) }
    else if (nm == "float") { parse_type_tail(toks, p + 1, { k: "tfloat" }) }
    else if (nm == "void") { parse_type_tail(toks, p + 1, { k: "tvoid" }) }
    else { parse_type_tail(toks, p + 1, { k: "tname", name: nm }) }
};

// Postfix tail shared by ALL atom arms: `?` then `->` (fresh names — see
// note). Every atom arm above calls parse_type_tail(toks, apos, anode)
// instead of returning its shape directly, so `?`/`->` apply uniformly
// (previously only some arms applied them — the rest silently dropped
// option/arrow suffixes).
def parse_type_tail(toks: [{ t: str, v: str, line: long, col: long }], apos: long, anode) -> { node: {k: str}, pos: long } {
    // postfix `?`: option type (binds tighter than `->`)
    // Both paths return the same parser-result shape; `?` wraps the atom
    // before the shared arrow parser handles the suffix.
    if (is_op(toks, apos, "?")) {
        // NOTE: `?` then re-check `->`: T? -> U must keep parsing the arrow
        // (right-assoc). The `?` shape feeds parse_type_arrow as its anode.
        parse_type_arrow(toks, apos + 1, { k: "topt", of: anode })
    } else {
        parse_type_arrow(toks, apos, anode)
    }
};

// Arrow tail: `->` B (right-assoc) or bare grouping (fresh names — see note).
def parse_type_arrow(toks: [{ t: str, v: str, line: long, col: long }], apos: long, anode) -> { node: {k: str}, pos: long } {
    // A parenthesized list becomes the parameter list; any other atom
    // becomes the single parameter. anode is bound ONCE (never rebound),
    // so anode.ts always reads the pre-arrow shape.
    // NOTE: NO eager `anode.ts` snapshot (ats): the C backend evaluates
    // record literals EAGERLY — `{k:topt,...}.ts` on a non-tparams shape is a
    // hard runtime error ("key 'ts' not found"), and the C VM has no
    // option/lazy field access. Read .ts ONLY inside the tparams arms.
    // NOTE: NO `let ak = anode.k` snapshot: the checker env is
    // flow-insensitive (LAST shape wins per name)... but ak is a STR (not a
    // record), and narrowing a let-bound str via if-chains is exact — EXCEPT
    // the env ALSO merges ak with every other `ak` in the function. There is
    // exactly one `ak` here, so the snapshot is sound; the rule is only that
    // no OTHER arm may rebind `ak`. (`node`/`tgt` snapshots broke this rule:
    // they were rebound across MANY arms, merging all shapes.)
    // `anode` itself is a PARAM (never rebound), so `anode.k`/`anode.ts`
    // reads are always the true call-site shape. Keep reads inline.
    // NOTE: split callee by SHAPE, not by re-reading anode.k per arm:
    // parse_type_tparams vs parse_type_plain are SEPARATE defs, so each
    // function body contains exactly ONE `anode.k` read site resolving
    // against exactly one call-site shape family. (Two `anode.k` reads in
    // one body merge through the flow-insensitive env.)
    // `?` shapes already returned via parse_type_tail (which handles `?`
    // BEFORE calling here), so anode is never topt at this point: tparams
    // (param list) or a plain atom. Dispatch by shape WITHOUT reading
    // anode.k twice in one body: tparams goes to parse_type_tparams, every
    // other shape stays inline. The dispatch reads anode.k ONCE (nested
    // ifs, not `||` — bool/call-shape gates poison joint conditions).
    // NOTE: dispatch WITHOUT reading anode.k here at all: the CALLER
    // (parse_type_tail) already knows the shape — tparams arms call
    // parse_type_tparams directly, all other arms call parse_type_plain.
    // Reading anode.k in this body reintroduces the merged-shape read
    // (this `anode` param name is shared across all call sites).
    parse_type_plain(toks, apos, anode)
};

def parse_type_plain(toks: [{ t: str, v: str, line: long, col: long }], apos: long, anode) -> { node: {k: str}, pos: long } {
    // Non-tparams atoms: `->` builds tfunc, else anode. This body contains
    // NO `anode.k`/`anode.ts` reads at all, so nothing merges here.
    if (is_op(toks, apos, "->")) {
        let rhs = parse_type_node(toks, apos + 1);
        res({ k: "tfunc", args: [anode], ret: rhs.node }, rhs.pos)
    } else {
        res(anode, apos)
    }
};

def parse_type_tparams(toks: [{ t: str, v: str, line: long, col: long }], apos: long, tlist: [{k: str}]) -> { node: {k: str}, pos: long } {
    // tparams shape ONLY (dispatched by shape): the caller passes the TS
    // LIST itself (not a tparams record), so this body contains NO record
    // field reads at all — nothing to merge, nothing to mis-resolve.
    // `->` after a param list: (A, B) -> R. Else bare grouping: (T) = T.
    let ts0 = tlist;
    if (is_op(toks, apos, "->")) {
        let rhs = parse_type_node(toks, apos + 1);
        res({ k: "tfunc", args: ts0, ret: rhs.node }, rhs.pos)
    } else if (len(ts0) == 1) {
        res(ts0[0], apos)
    } else {
        res({ k: "tparams", ts: ts0 }, apos)
    }
};

def parse_type_atom(toks: [{ t: str, v: str, line: long, col: long }], p: long) -> long {
    // Parse a single non-arrow type and return the position after it.
    // Atoms: long, str, bool, [T], (T, T), { field: T, ... }
    // NOTE: bound once — `parse_type_node(...).pos` inline misparses on the
    // C backend (it reads `f().y` as `f(.y)`).
    let r = parse_type_node(toks, p);
    r.pos
};

def parse_type(toks: [{ t: str, v: str, line: long, col: long }], p: long) -> long {
    // Parse a type annotation and return the position after it.
    // Types: long, str, bool, [T], (T, T), { field: T }, and function types
    // A -> B (right-associative, so A -> B -> C = A -> (B -> C)).
    // The recursive arm only updates `pos`; this conditional's value is
    // discarded, so its VOID-law arm mismatch does not affect the result.
    let pos = parse_type_atom(toks, p);
    if (is_op(toks, pos, "->")) {
        pos = parse_type(toks, pos + 1);
    } else { 0 };
    pos
};

// ── function literal ─────────────────────────────────────────────────────

def parse_func(toks: [{ t: str, v: str, line: long, col: long }], p: long) -> { node: {k: str}, pos: long } {
    // Named:    def name(params) -> ret { body }   (top-level declaration)
    // Anonymous: def(params) -> ret { body }        (function expression)
    let ln = tline(toks, p);
    let cl = tcol(toks, p);
    let pos = p + 1;  // skip 'def'
    let fname = "";
    // optional function name (present unless next token is '(')
    // Only the optional-name branch changes `fname` and `pos`; both are
    // consumed by the common parsing path below.
    if (!is_punct(toks, pos, "(")) {
        fname = tv(toks, pos);
        pos = pos + 1;
        0
    } else { 0 };
    pos = pos + 1;  // skip '('
    let names = [];
    let ptypes = [];
    if (!is_punct(toks, pos, ")")) {
        let go = true;
        while (go) {
            let nm = tv(toks, pos);
            names += nm;
            pos = pos + 1;  // name
            let pt = { k: "tnone" };
            if (is_punct(toks, pos, ":")) {
                let tr = parse_type_node(toks, pos + 1);
                pt = tr.node;
                pos = tr.pos;
                0
            } else { 0 };
            ptypes += pt;
            if (is_punct(toks, pos, ",")) {
                pos = pos + 1;
                0
            } else {
                go = false;
                0
            };
            0
        };
        0
    } else { 0 };
    pos = pos + 1;  // skip ')'
    // optional return type '-> type'
    // The optional return annotation updates the local type and position.
    let ret = { k: "tnone" };
    if (is_op(toks, pos, "->")) {
        let rr = parse_type_node(toks, pos + 1);
        ret = rr.node;
        pos = rr.pos;
        0
    } else { 0 };
    let body = parse_block(toks, pos);
    let func = { k: "func", params: names, ptypes: ptypes, ret: ret, body: body.node, line: ln, col: cl };
    if (fname == "") {
        res(func, body.pos)
    } else {
        res({ k: "decl", kind: "def", name: fname, v: func, line: ln, col: cl }, body.pos)
    }
};

// ── block { stmt; stmt; ... } ────────────────────────────────────────────

def parse_block(toks: [{ t: str, v: str, line: long, col: long }], p: long) -> { node: {k: str}, pos: long } {
    let ln = tline(toks, p);
    let cl = tcol(toks, p);
    let pos = p + 1;  // skip '{'
    let stmts: [{k: str}] = [];
    // NOTE: no `&&` (see lexer.y line-comment note): the C VM evaluates both
    // sides eagerly, so tt()/toks[pos] runs past "}" (clamped — safe here,
    // but the native checker rejects the shape); nested-if form instead.
    let go = true;
    while (go) {
        // NOTE: statement-form + `0;` tails — the while body must be
        // void-typed (see parse_binary note).
        if (is_punct(toks, pos, "}")) {
            go = false;
            0
        } else if (tt(toks, pos) == "eof") {
            go = false;
            0
        } else {
            let s = parse_stmt(toks, pos);
            stmts += s.node;
            pos = s.pos;
            if (is_punct(toks, pos, ";")) { pos = pos + 1; 0; } else { 0 };
            0
        };
    };
    res({ k: "block", stmts: stmts, line: ln, col: cl }, pos + 1)  // skip '}'
};

// ── statements ───────────────────────────────────────────────────────────

def parse_stmt(toks: [{ t: str, v: str, line: long, col: long }], p: long) -> { node: {k: str}, pos: long } {
    // NOTE: no `||` (see lexer.y isalnum note): the C VM evaluates both sides
    // eagerly AND the native checker rejects `||` mixing map-field shapes.
    if (is_kw(toks, p, "let")) { parse_decl(toks, p) }
    else if (is_kw(toks, p, "const")) { parse_decl(toks, p) }
    else if (is_kw(toks, p, "return")) {
        let e = parse_expr(toks, p + 1);
        res({ k: "ret", e: e.node, line: tline(toks, p), col: tcol(toks, p) }, e.pos)
    } else {
        // expression, possibly an assignment: id = expr, arr[i] = expr, or obj.key = expr
        // NOTE: dispatch by SHAPE into separate defs (like parse_type_tail):
        // parse_stmt_assign splits index/dot/deref/plain-id into callees
        // that each read ONLY their own shape's fields. Reading tgt.arr +
        // tgt.obj + tgt.e + tgt.v in ONE body merges all shapes through the
        // flow-insensitive env ("record has no field 'arr'").
        let e = parse_expr(toks, p);
        if (is_op(toks, e.pos, "=")) {
            parse_stmt_assign(toks, p, e.node, e.pos)
        } else if (is_compound_assign(toks, e.pos)) {
            parse_stmt_opassign(toks, p, e.node, e.pos)
        } else {
            e
        }
    }
};

// `x op= e`. The target keeps its expression form — a[f()] += 1 evaluates
// f() once. Array targets reinterpret `+=` (push/append) and `*=` (prepend
// an element) in the emitter; everywhere else `*=` is multiply-assign.
def is_compound_assign(toks: [{ t: str, v: str, line: long, col: long }], p: long) -> bool {
    if (is_op(toks, p, "+=")) { true }
    else if (is_op(toks, p, "-=")) { true }
    else if (is_op(toks, p, "*=")) { true }
    else if (is_op(toks, p, "/=")) { true }
    else { is_op(toks, p, "%=") }
};

def parse_stmt_opassign(toks: [{ t: str, v: str, line: long, col: long }], p: long, tgt: {k: str}, epos: long) -> { node: {k: str}, pos: long } {
    let op = tv(toks, epos);
    let rhs = parse_expr(toks, epos + 1);
    // Every compound op is `X=`, so the binary op is its first character.
    let binop = substr(op, 0, 1);
    res({ k: "opassign", op: binop, tgt: tgt, v: rhs.node, line: tline(toks, epos), col: tcol(toks, epos) }, rhs.pos)
};

// Assignment dispatch: one def per target shape (see parse_stmt note).
// Each body reads ONLY its own shape's fields — no merged-shape reads.
def parse_stmt_assign(toks: [{ t: str, v: str, line: long, col: long }], p: long, tgt: {k: str}, epos: long) -> { node: {k: str}, pos: long } {
    // NOTE: dispatch WITHOUT reading tgt.k twice in one body (see
    // parse_type_arrow note): index/dot go to dedicated callees; deref and
    // plain-id stay inline (disjoint fields e vs v — but read each once).
    if (tgt.k == "index") {
        parse_stmt_idxassign(toks, p, tgt, epos)
    } else {
        parse_stmt_rest(toks, p, tgt, epos)
    }
};

def parse_stmt_idxassign(toks: [{ t: str, v: str, line: long, col: long }], p: long, tgt: {k: str}, epos: long) -> { node: {k: str}, pos: long } {
    // NOTE: pass the WHOLE target + a KIND tag; the callee re-reads fields
    // off its OWN param (one shape per callee — no cross-callee merge).
    // Reading tgt.arr HERE would merge with tgt.obj/tgt.e/tgt.v reads in
    // sibling callees (same param name `tgt` across defs shares one env
    // entry). The _go callee's param is a DIFFERENT name (itgt), read once.
    parse_stmt_idxassign_go(toks, p, tgt, epos)
};

def parse_stmt_idxassign_go(toks: [{ t: str, v: str, line: long, col: long }], p: long, itgt, epos: long) -> { node: {k: str}, pos: long } {
    // NOTE: param DECLARED with the full shape: the env entry for `itgt`
    // carries arr/idx (not the merged {k}-only hole), so the reads below
    // resolve. tcompat's structural trec rule accepts the richer call-site
    // literal at the call (superset accepts subset).
    let rhs = parse_expr(toks, epos + 1);
    res({ k: "idxassign", arr: itgt.arr, idx: itgt.idx, v: rhs.node, line: tline(toks, p), col: tcol(toks, p) }, rhs.pos)
};



def parse_stmt_rest(toks: [{ t: str, v: str, line: long, col: long }], p: long, tgt: {k: str}, epos: long) -> { node: {k: str}, pos: long } {
    if (tgt.k == "dot") {
        parse_stmt_dotassign(toks, p, tgt, epos)
    } else {
        parse_stmt_simple(toks, p, tgt, epos)
    }
};

def parse_stmt_dotassign(toks: [{ t: str, v: str, line: long, col: long }], p: long, tgt: {k: str}, epos: long) -> { node: {k: str}, pos: long } {
    // NOTE: same whole-record handoff as idxassign (see note above).
    parse_stmt_dotassign_go(toks, p, tgt, epos)
};

def parse_stmt_dotassign_go(toks: [{ t: str, v: str, line: long, col: long }], p: long, dtgt, epos: long) -> { node: {k: str}, pos: long } {
    // NOTE: full-shape param (see idxassign_go note).
    let rhs = parse_expr(toks, epos + 1);
    res({ k: "dotassign", obj: dtgt.obj, key: dtgt.key, v: rhs.node, line: tline(toks, p), col: tcol(toks, p) }, rhs.pos)
};



def parse_stmt_simple(toks: [{ t: str, v: str, line: long, col: long }], p: long, tgt: {k: str}, epos: long) -> { node: {k: str}, pos: long } {
    // deref (*p = v) vs plain id (x = v): separate callees per shape, fields
    // passed as VALUES (see parse_stmt_idxassign note).
    if (tgt.k == "deref") {
        parse_stmt_store(toks, p, tgt, epos)
    } else {
        parse_stmt_plainassign(toks, p, tgt, epos)
    }
};

def parse_stmt_store(toks: [{ t: str, v: str, line: long, col: long }], p: long, stgt, epos: long) -> { node: {k: str}, pos: long } {
    // NOTE: full-shape param (see idxassign_go note).
    let rhs = parse_expr(toks, epos + 1);
    res({ k: "store", p: stgt.e, v: rhs.node, line: tline(toks, p), col: tcol(toks, p) }, rhs.pos)
};

def parse_stmt_plainassign(toks: [{ t: str, v: str, line: long, col: long }], p: long, atgt, epos: long) -> { node: {k: str}, pos: long } {
    // NOTE: full-shape param (see idxassign_go note).
    let rhs = parse_expr(toks, epos + 1);
    res({ k: "assign", name: atgt.v, v: rhs.node, line: tline(toks, p), col: tcol(toks, p) }, rhs.pos)
};

def parse_decl(toks: [{ t: str, v: str, line: long, col: long }], p: long) -> { node: {k: str}, pos: long } {
    let kind = tv(toks, p);
    let name = tv(toks, p + 1);
    let ln = tline(toks, p);
    let cl = tcol(toks, p);
    let pos = p + 2;
    // optional ': type' (kept as a type node for the static checker)
    // The optional annotation updates the local type and position.
    let typ = { k: "tnone" };
    if (is_punct(toks, pos, ":")) {
        let tr = parse_type_node(toks, pos + 1);
        typ = tr.node;
        pos = tr.pos;
        0
    } else { 0 };
    // '='
    pos = pos + 1;
    let e = parse_expr(toks, pos);
    res({ k: "decl", kind: kind, name: name, typ: typ, v: e.node, line: ln, col: cl }, e.pos)
};

// ── control flow ─────────────────────────────────────────────────────────

def parse_if(toks: [{ t: str, v: str, line: long, col: long }], p: long) -> { node: {k: str}, pos: long } {
    let ln = tline(toks, p);
    let cl = tcol(toks, p);
    let cond = parse_expr(toks, p + 1);
    let then_b = parse_block(toks, cond.pos);
    let pos = then_b.pos;
    let else_b = { k: "void" };
    let has_else = false;
    // The optional else branch updates the AST bookkeeping.
    if (is_kw(toks, pos, "else")) {
        if (is_kw(toks, pos + 1, "if")) {
            let ei = parse_if(toks, pos + 1);
            else_b = ei.node;
            pos = ei.pos;
            0
        } else {
            let eb = parse_block(toks, pos + 1);
            else_b = eb.node;
            pos = eb.pos;
            0
        };
        has_else = true;
        0
    } else { 0 };
    res({ k: "if", cond: cond.node, then: then_b.node, els: else_b, has_else: has_else, line: ln, col: cl }, pos)
};

def parse_while(toks: [{ t: str, v: str, line: long, col: long }], p: long) -> { node: {k: str}, pos: long } {
    let cond = parse_expr(toks, p + 1);
    let body = parse_block(toks, cond.pos);
    res({ k: "while", cond: cond.node, body: body.node, line: tline(toks, p), col: tcol(toks, p) }, body.pos)
};

def parse_foreach(toks: [{ t: str, v: str, line: long, col: long }], p: long) -> { node: {k: str}, pos: long } {
    // foreach ( x in iterable ) { body }
    let name = tv(toks, p + 2);
    let it = parse_expr(toks, p + 4);  // skip 'foreach' '(' name 'in'
    let body = parse_block(toks, it.pos + 1);  // skip ')'
    res({ k: "foreach", name: name, iter: it.node, body: body.node, line: tline(toks, p), col: tcol(toks, p) }, body.pos)
};

def parse_for_or_range(toks: [{ t: str, v: str, line: long, col: long }], p: long) -> { node: {k: str}, pos: long } {
    // for i in a..b { body }   OR   for (init; cond; step) { body }
    let ln = tline(toks, p);
    let cl = tcol(toks, p);
    if (is_kw(toks, p + 2, "in")) {
        let name = tv(toks, p + 1);
        let lo = parse_expr(toks, p + 3);
        // '..'
        let hi = parse_expr(toks, lo.pos + 1);
        let body = parse_block(toks, hi.pos);
        res({ k: "forrange", name: name, lo: lo.node, hi: hi.node, body: body.node, line: ln, col: cl }, body.pos)
    } else {
        // C-style for
        // The init and step clauses are optional; only present clauses
        // update their local parser state.
        let pos = p + 2;  // skip 'for' '('
        let init = { k: "void" };
        if (!is_punct(toks, pos, ";")) {
            let ir = parse_stmt(toks, pos);
            init = ir.node;
            pos = ir.pos;
            0
        } else { 0 };
        pos = pos + 1;  // ';'
        let cond = parse_expr(toks, pos);
        pos = cond.pos + 1;  // ';'
        let step = { k: "void" };
        if (!is_punct(toks, pos, ")")) {
            let sr = parse_stmt(toks, pos);
            step = sr.node;
            pos = sr.pos;
            0
        } else { 0 };
        pos = pos + 1;  // ')'
        let body = parse_block(toks, pos);
        res({ k: "for", init: init, cond: cond.node, step: step, body: body.node, line: ln, col: cl }, body.pos)
    }
};

// ── top level: a program is a block of statements (no surrounding braces) ─

def parse_program(toks: [{ t: str, v: str, line: long, col: long }]) -> {k: str} {
    let stmts: [{k: str}] = [];
    let pos = 0;
    while (tt(toks, pos) != "eof") {
        let before = pos;
        let s = parse_stmt(toks, pos);
        stmts += s.node;
        pos = s.pos;
        if (is_punct(toks, pos, ";")) { pos = pos + 1; 0; } else { 0 };
        // safety: if a statement made no progress, bail to avoid infinite loop
        // NOTE: `0;` tail — the while body must be void-typed (see note).
        if (pos == before) {
            pos = pos + 1;
            0
        } else { 0 };
        0
    };
    { k: "block", stmts: stmts, line: 1, col: 1 }
};

export { parse_program };
