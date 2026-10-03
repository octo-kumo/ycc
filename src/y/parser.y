// parser.y — parse a token list into an AST of nested maps.
// Each parse function returns { node: <ast>, pos: <int> }.
// AST node kinds: num, str, bstr, char, id, bool, void (an absent
//   expression), err (a syntax error planted here for the checker to
//   report — this module has no error channel of its own),
//   bin, un, addr, deref, call, index, slice, dot, incdec,
//   assign, idxassign, dotassign, sliceassign, store, opassign,
//   decl, typedef, func, if, while, for, foreach, forrange,
//   block, array, arrrep, rec, map, ret,
//   plus the match lowering: narrow, rectest, matchend.
// Postfix `x!` is sugar for unwrap(x).
// Annotations parse into type nodes: tlong/tbool/tstr/tbyte/tfloat/tvoid/
//   tname/tnone/tptr/tarr/tarrfix/tparams/tfunc/trec/tmap/tunion/topt, and
//   tpat for a record pattern.

// For its alias Tok.
import tags from "./tags.y";
import lexer from "./lexer.y";

// AST nodes have one type per shape; kinds with a shared shape use one
// member and are distinguished by `k`.
type Leaf = { k: long, v: str, line: long, col: long };
type Bare = { k: long, line: long, col: long };
type Wrap = { k: long, e: Node, line: long, col: long };
type Un = { k: long, op: str, e: Node, line: long, col: long };
type Bin = { k: long, op: str, l: Node, r: Node, line: long, col: long };
type ArrLit = { k: long, elems: [Node], line: long, col: long };
type ArrRep = { k: long, v: Node, n: long, line: long, col: long };
type Assign = { k: long, name: str, v: Node, line: long, col: long };
type Block = { k: long, stmts: [Node], line: long, col: long };
type Call = { k: long, callee: Node, args: [Node], line: long, col: long };
type Decl = { k: long, kind: str, name: str, typ: Type, v: Node, line: long, col: long };
type Dot = { k: long, obj: Node, key: str, line: long, col: long };
type DotAssign = { k: long, obj: Node, key: str, v: Node, line: long, col: long };
type Err = { k: long, msg: str, line: long, col: long };
type For = { k: long, init: Node, cond: Node, step: Node, body: Node, line: long, col: long };
type Foreach = { k: long, name: str, iter: Node, body: Node, line: long, col: long };
type ForRange = { k: long, name: str, lo: Node, hi: Node, body: Node, line: long, col: long };
type Func = { k: long, params: [str], ptypes: [Type], ret: Type, body: Node, defs: [Node], line: long, col: long };
type IdxAssign = { k: long, arr: Node, idx: Node, v: Node, line: long, col: long };
type If = { k: long, cond: Node, then: Node, els: Node, has_else: bool, line: long, col: long };
type IncDec = { k: long, op: str, pre: bool, tgt: Node, line: long, col: long };
type Index = { k: long, arr: Node, idx: Node, line: long, col: long };
type RecLit = { k: long, keys: [str], vals: [Node], line: long, col: long };
type MatchEnd = { k: long, e: Node, cover: [Type], vals: long, line: long, col: long };
type Narrow = { k: long, e: Node, typ: Type, line: long, col: long };
type OpAssign = { k: long, op: str, tgt: Node, v: Node, line: long, col: long };
type Slice = { k: long, arr: Node, lo: Node, hi: Node, line: long, col: long };
type SliceAssign = { k: long, arr: Node, lo: Node, hi: Node, v: Node, line: long, col: long };
type Store = { k: long, p: Node, v: Node, line: long, col: long };
type TypeDef = { k: long, name: str, typ: Type, line: long, col: long };
type While = { k: long, cond: Node, body: Node, line: long, col: long };
type Node = Leaf | Bare | Wrap | Un | Bin | ArrLit | ArrRep | Assign | Block | Call | Decl | Dot | DotAssign | Err | For | Foreach | ForRange | Func | IdxAssign | If | IncDec | Index | RecLit | MatchEnd | Narrow | OpAssign | Slice | SliceAssign | Store | TypeDef | While;

// Type nodes are separate from AST nodes even though both carry `k`.
// A record field; `opt` for an optional one (`name?: T`, typ T?): a
// literal where its record type is declared may leave it out (none) or
// give a plain T (types.y lit_target, opt_wraps). Not part of the type:
// `{a?: long}` and `{a: long?}` are one type.
type Field = { name: str, opt: bool, typ: Type };
type TPrim = { k: long };
type TOf = { k: long, of: Type };
type TFix = { k: long, n: long, of: Type };
type TMap = { k: long, key: Type, of: Type };
type TRec = { k: long, fields: [Field] };
type TFunc = { k: long, args: [Type], ret: Type };
type TName = { k: long, name: str };
type TList = { k: long, ts: [Type] };
type TPat = { k: long, names: [str] };
type TPtr = { k: long, to: Type };
type TRef = { k: long, name: str, tmp: str, to: Type };
type TInfer = { k: long, rets: [RetNote] };
// A `return` noted while a def's return type is inferred (types.y ret_note).
type RetNote = { typ: Type, line: long, col: long };
// The checker's own markers (types.y): an unknown part nothing stated yet
// (`[]`, `none`: k "tunk", free), and a def's return type before it is
// known (k "tpend"; self: the def being checked; used: it called itself).
type TFree = { k: long, free: bool };
type TPend = { k: long, self: bool, used: bool };
type Type = TPrim | TOf | TFix | TMap | TRec | TFunc | TName | TList | TPat | TPtr | TRef | TInfer | TFree | TPend | Err;

// A parse result for expressions, and one for types.
type Parsed = { node: Node, pos: long };
type ParsedList = { node: [Node], pos: long };
type PType = { node: Type, pos: long };
type PatRes = { test: Node, binds: [Node], cover: Type, wild: bool, pos: long };
// One `?.` waiting for its chain to close (parse_postfix): the temp its
// receiver is bound to, that receiver, and the operator's position.
type PropCtx = { tmp: str, recv: Node, line: long, col: long };

// ── token helpers ────────────────────────────────────────────────────────

def tclamp(toks: [Tok], p: long) -> long {
    // Peeking past the end must not read out of bounds: the compiled
    // compiler traps there and the C copy's ya_get aborts with "index out
    // of bounds" (src/c/yv.c). Clamp every peek to the trailing "eof"
    // token (tokenize always appends one) so both copies agree.
    let n = len(toks);
    let q = p;
    if (q >= n) { q = n - 1; }
    q
};

def tt(toks: [Tok], p: long) -> str {
    // NOTE: bind the token, then read its field. The inline form
    // `toks[p].t` parses fine today (index-then-dot is an ordinary postfix
    // chain — see parse_postfix), but it is a one-read-per-peek either way,
    // so every helper below keeps this shape.
    let tok = toks[tclamp(toks, p)];
    tok.t
};
def tv(toks: [Tok], p: long) -> str {
    // NOTE: bound once (see tt note).
    let tok = toks[tclamp(toks, p)];
    tok.v
};
def tline(toks: [Tok], p: long) -> long {
    // NOTE: bound once (see tt note).
    let tok = toks[tclamp(toks, p)];
    tok.line
};
def tcol(toks: [Tok], p: long) -> long {
    // NOTE: bound once (see tt note).
    let tok = toks[tclamp(toks, p)];
    tok.col
};

def is_kw(toks: [Tok], p: long, w: str) -> bool {
    // Nested ifs, not `&&`: both spellings typecheck (types.y types `&&`
    // through typeof_logic, which takes any operand) and both short-circuit,
    // so this is style, not a rule.
    // NOTE: bound once (see tt note).
    let tok = toks[tclamp(toks, p)];
    if (tok.t == "kw") {
        if (tok.v == w) { true } else { false }
    } else { false }
};
def is_punct(toks: [Tok], p: long, w: str) -> bool {
    // NOTE: bound once (see tt note).
    let tok = toks[tclamp(toks, p)];
    if (tok.t == "punct") {
        if (tok.v == w) { true } else { false }
    } else { false }
};
def is_op(toks: [Tok], p: long, w: str) -> bool {
    // NOTE: bound once (see tt note).
    let tok = toks[tclamp(toks, p)];
    if (tok.t == "op") {
        if (tok.v == w) { true } else { false }
    } else { false }
};

def res(node: Node, p: long) -> Parsed {
    { node: node, pos: p }
};

def tres(node: Type, p: long) -> PType {
    { node: node, pos: p }
};

// ── malformed input ──────────────────────────────────────────────────────
// parser.y has no error channel: where the token stream stops making sense
// it plants an `err` node, which the checker reports at its position. A
// token the grammar does not expect is NEVER skipped silently -- that used
// to compile `a[1 2];` as `a[1];` and `def f( { 1 }` as a function.

// The token at p, for a message: 'x', or end of input.
def tok_desc(toks: [Tok], p: long) -> str {
    if (tt(toks, p) == "eof") { "end of input" } else { "'" + tv(toks, p) + "'" }
};

// "expected WHAT, got 'x'" at token p.
def expect_err(toks: [Tok], p: long, what: str) -> Err {
    { k: K.err, msg: "expected " + what + ", got " + tok_desc(toks, p), line: tline(toks, p), col: tcol(toks, p) }
};

// `node` followed by `closer` at p: the node, past the closer -- or, when
// something else stands there, an error in the node's place (and nothing
// skipped, so the stray token is seen by whatever parses next).
def close_res(toks: [Tok], p: long, closer: str, node: Node) -> Parsed {
    if (is_punct(toks, p, closer)) {
        res(node, p + 1)
    } else {
        res(expect_err(toks, p, "'" + closer + "'"), p)
    }
};

// Past `closer` at p when it is there (an error was planted otherwise).
def skip_close(toks: [Tok], p: long, closer: str) -> long {
    if (is_punct(toks, p, closer)) { p + 1 } else { p }
};

// A name token (identifiers; keywords too, as record keys and fields).
def is_name_tok(toks: [Tok], p: long) -> bool {
    let t = tt(toks, p);
    t == "id" || t == "kw"
};

// sep_by(one, close): parse a comma-separated list of `one(toks, pos)` results
// (each returning { node, pos }) until the `close` punct. Handles trailing
// commas. Returns { node: [nodes], pos } with pos AT the close punct (caller
// skips it). Replaces 6 copy-pasted comma-list loops.
// `one` is a production NAME ("expr" only, for now) and sep_by dispatches on
// it — a defunctionalized stub: extend the if-chain to add a production.
// NOTE: toks is the token list [{ t, v, line, col }]; param typed tarr of
// trec so the checker accepts plain token-list arguments (a real missing
// element type still errors at the empty-array use sites).
def sep_by(toks: [Tok], p: long, close: str, one: str) -> ParsedList {
    let xs: [Node] = [];
    let pos = p;
    let go = true;
    if (is_punct(toks, pos, close)) { go = false; }
    while (go) {
        // NOTE: `0;` tails — the while body must be void-typed (see note).
        let r: Parsed = { node: { k: K.void, line: tline(toks, pos), col: tcol(toks, pos) }, pos: pos };
        if (one == "expr") {
            r = parse_expr(toks, pos);
        };
        // NOTE: the result's two fields are read off its own name (see tt
        // note) — `one(toks, pos).node` inline is fine to parse, but the
        // call result is already bound here.
        let rnode = r.node;
        let rpos = r.pos;
        xs += rnode;
        pos = rpos;
        if (is_punct(toks, pos, ",")) {
            pos = pos + 1;
            if (is_punct(toks, pos, close)) { go = false; }
        } else {
            // Neither a separator nor the closer: the token stream is
            // malformed. parser.y has no error channel, so plant a node the
            // checker rejects — dropping the leftovers silently compiled
            // `print(1 zzz)` into `print(1)`.
            if (is_punct(toks, pos, close)) { } else {
                xs += { k: K.err, msg: "unexpected " + tok_desc(toks, pos) + " (expected ',' or '" + close + "')", line: tline(toks, pos), col: tcol(toks, pos) };
            };
            go = false;
        };
    };
    { node: xs, pos: pos }
};

// ── operator precedence ──────────────────────────────────────────────────

// The bitwise operators bind tighter than the comparisons (unlike C, where
// `a & m == 0` is `a & (m == 0)`): `|` < `^` < `&` < the shifts < `+ -`.
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
    else if (op == "|") { 6 }
    else if (op == "^") { 7 }
    else if (op == "&") { 8 }
    else if (op == "<<") { 9 }
    else if (op == ">>") { 9 }
    else if (op == ">>>") { 9 }
    else if (op == "+") { 10 }
    else if (op == "-") { 10 }
    else if (op == "*") { 11 }
    else if (op == "/") { 11 }
    else if (op == "%") { 11 }
    else { 0 }
};

// ── primary expressions ──────────────────────────────────────────────────

def parse_primary(toks: [Tok], p: long) -> Parsed {
    let t = tt(toks, p);
    let v = tv(toks, p);
    let ln = tline(toks, p);
    let cl = tcol(toks, p);
    if (t == "num") {
        res({ k: K.num, v: v, line: ln, col: cl }, p + 1)
    } else if (t == "str") {
        res({ k: K.str, v: v, line: ln, col: cl }, p + 1)
    } else if (t == "bstr") {
        // b"..." / b'...' -- a [byte] literal
        res({ k: K.bstr, v: v, line: ln, col: cl }, p + 1)
    } else if (t == "char") {
        // c'a' -- one byte, typed `byte`; v holds its code in decimal
        if (len(v) == 1) {
            res({ k: K.char, v: tostring(ord(v)), line: ln, col: cl }, p + 1)
        } else {
            res({ k: K.err, msg: "character literal must be exactly one byte, got " + tostring(len(v)), line: ln, col: cl }, p + 1)
        }
    } else if (t == "ferr") {
        // a malformed literal (a broken f-string, `0x` without digits):
        // the lexer's message, where it found the fault
        res({ k: K.err, msg: v, line: ln, col: cl }, p + 1)
    } else if (t == "id") {
        if (v == "match") {
            parse_match_try(toks, p)
        } else if ((v == "spawn" || v == "fork") && is_punct(toks, p + 1, "{")) {
            // `spawn { ... }`, `fork { ... }`: the builtin on a function of
            // the block (CHOICES_MADE.md 33)
            let b = parse_block(toks, p + 1);
            let args: [Node] = [];
            args += block_func(b.node, ln, cl);
            res({ k: K.call, callee: { k: K.id, v: v, line: ln, col: cl }, args: args, line: ln, col: cl }, b.pos)
        } else if ((v == "lock" || v == "try_lock") && tt(toks, p + 1) == "id") {
            // `lock m { ... }`: the mutex, then the block
            let m = parse_postfix(toks, p + 1);
            let args: [Node] = [];
            args += m.node;
            if (!is_punct(toks, m.pos, "{")) {
                args += expect_err(toks, m.pos, "'{' (the block " + v + " runs)");
                res({ k: K.call, callee: { k: K.id, v: v, line: ln, col: cl }, args: args, line: ln, col: cl }, m.pos)
            } else {
                let b = parse_block(toks, m.pos);
                args += block_func(b.node, ln, cl);
                res({ k: K.call, callee: { k: K.id, v: v, line: ln, col: cl }, args: args, line: ln, col: cl }, b.pos)
            }
        } else if ((v == "join" || v == "post" || v == "wait") && tt(toks, p + 1) == "id") {
            // `join t`, `post s`, `wait s`: the builtin on the operand
            let e = parse_postfix(toks, p + 1);
            let args: [Node] = [];
            args += e.node;
            res({ k: K.call, callee: { k: K.id, v: v, line: ln, col: cl }, args: args, line: ln, col: cl }, e.pos)
        } else {
            res({ k: K.id, v: v, line: ln, col: cl }, p + 1)
        }
    } else if (is_kw(toks, p, "true")) {
        res({ k: K.bool, v: "true", line: ln, col: cl }, p + 1)
    } else if (is_kw(toks, p, "false")) {
        res({ k: K.bool, v: "false", line: ln, col: cl }, p + 1)
    } else if (is_punct(toks, p, "(")) {
        if (is_punct(toks, p + 1, ")")) {
            // `()` is the void value (nothing computed)
            res({ k: K.void, line: ln, col: cl }, p + 2)
        } else {
            let inner = parse_expr(toks, p + 1);
            close_res(toks, inner.pos, ")", inner.node)
        }
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
        // Not an expression at all. A closer or separator is left for the
        // construct it belongs to (`f(1 +)` is one error, not two); any
        // other token is consumed, so every caller makes progress.
        let ce = expect_err(toks, p, "an expression");
        if (t == "eof" || is_punct(toks, p, ")") || is_punct(toks, p, "]") || is_punct(toks, p, "}") || is_punct(toks, p, ",") || is_punct(toks, p, ";")) {
            res(ce, p)
        } else {
            res(ce, p + 1)
        }
    }
};

// The types `mutex` and `sem` (types.y t_mutex, t_sem): records whose
// fields no program can name.
def sync_type(nm: str) -> Type {
    let fs: [Field] = [];
    if (nm == "mutex") {
        fs += { name: "$m", opt: false, typ: { k: K.tlong } };
    } else {
        fs += { name: "$n", opt: false, typ: { k: K.tlong } };
        fs += { name: "$w", opt: false, typ: { k: K.tlong } };
    };
    let t: TRec = { k: K.trec, fields: fs };
    let r: Type = t;
    r
};

// A block as a function of no parameters, its return type inferred.
def block_func(body: Node, ln: long, cl: long) -> Node {
    let f: Func = { k: K.func, params: [], ptypes: [], ret: { k: K.tnone }, body: body, defs: [], line: ln, col: cl };
    let node: Node = f;
    node
};

// ── postfix: call, index, slice, dot ─────────────────────────────────────

def parse_postfix(toks: [Tok], p: long) -> Parsed {
    let base = parse_primary(toks, p);
    let node = base.node;
    let pos = base.pos;
    let go = true;
    // The `?.`s open in this chain, innermost last: each binds its receiver
    // to a temp and wraps the rest of the chain in `if temp is some`. A chain
    // may hold several (`a?.b?.c`), so they stack and unwind LIFO.
    let props: [PropCtx] = [];
    while (go) {
        if (is_punct(toks, pos, "(")) {
            let a = parse_args(toks, pos + 1);
            node = mk_call(node, a.node, tline(toks, pos), tcol(toks, pos));
            pos = skip_close(toks, a.pos, ")");
        } else if (is_punct(toks, pos, "[")) {
            // index or slice: arr[i], arr[lo:hi], arr[lo:], arr[:hi], arr[:]
            let bln = tline(toks, pos);
            let bcl = tcol(toks, pos);
            if (is_punct(toks, pos + 1, ":")) {
                if (is_punct(toks, pos + 2, "]")) {
                    // arr[:] — full slice
                    node = { k: K.slice, arr: node, lo: { k: K.void, line: bln, col: bcl }, hi: { k: K.void, line: bln, col: bcl }, line: bln, col: bcl };
                    pos = pos + 3;  // skip '[', ':', ']'
                } else {
                    // arr[:hi] — no lo
                    let second = parse_expr(toks, pos + 2);
                    let c1 = close_res(toks, second.pos, "]", { k: K.slice, arr: node, lo: { k: K.void, line: bln, col: bcl }, hi: second.node, line: bln, col: bcl });
                    node = c1.node;
                    pos = c1.pos;
                };
            } else {
                let first = parse_expr(toks, pos + 1);
                if (is_punct(toks, first.pos, ":")) {
                    if (is_punct(toks, first.pos + 1, "]")) {
                        // arr[lo:] — no hi
                        node = { k: K.slice, arr: node, lo: first.node, hi: { k: K.void, line: bln, col: bcl }, line: bln, col: bcl };
                        pos = first.pos + 2;  // skip ':' and ']'
                    } else {
                        // arr[lo:hi]
                        let second = parse_expr(toks, first.pos + 1);
                        let c2 = close_res(toks, second.pos, "]", { k: K.slice, arr: node, lo: first.node, hi: second.node, line: bln, col: bcl });
                        node = c2.node;
                        pos = c2.pos;
                    };
                } else {
                    // arr[i] — index
                    let c3 = close_res(toks, first.pos, "]", { k: K.index, arr: node, idx: first.node, line: bln, col: bcl });
                    node = c3.node;
                    pos = c3.pos;
                };
            };
            // A broken subscript ends the chain: what follows is unparsed.
            if (node.k == K.err) { go = false; }
        } else if (is_op(toks, pos, ".")) {
            if (is_name_tok(toks, pos + 1)) {
                let name = tv(toks, pos + 1);
                node = { k: K.dot, obj: node, key: name, line: tline(toks, pos), col: tcol(toks, pos) };
                pos = pos + 2;
            } else {
                node = expect_err(toks, pos + 1, "a field name after '.'");
                pos = pos + 1;
                go = false;
            };
        } else if (is_op(toks, pos, "!")) {
            // x! -- postfix unwrap, exactly unwrap(x) (traps on none).
            let ua: [Node] = [];
            ua += node;
            node = { k: K.call, callee: { k: K.id, v: "unwrap", line: tline(toks, pos), col: tcol(toks, pos) }, args: ua, line: tline(toks, pos), col: tcol(toks, pos) };
            pos = pos + 1;
        } else if (is_op(toks, pos, "?.") && (is_name_tok(toks, pos + 1) || is_punct(toks, pos + 1, "["))) {
            // `x?.y`, `x?.[i]` -- option propagation (PropCtx above). Bind x
            // once, then read the rest of the chain off the bound copy: the
            // chain below is ordinary, unwrapped code that only runs where x
            // is there, so EVERY link after the `?.` propagates x's none --
            // `a?.b.c` as much as `a?.b` -- and a subscript is an ordinary
            // index under it. The wrapping `if` waits for the chain to end.
            let pln = tline(toks, pos);
            let pcl = tcol(toks, pos);
            let tmp = "$p" + tostring(pln) + "_" + tostring(pcl);
            let ua: [Node] = [];
            props += { tmp: tmp, recv: node, line: pln, col: pcl };
            ua += { k: K.id, v: tmp, line: pln, col: pcl };
            node = { k: K.call, callee: { k: K.id, v: "unwrap", line: pln, col: pcl }, args: ua, line: pln, col: pcl };
            if (is_name_tok(toks, pos + 1)) {
                // The name belongs to the `?.`, not to the loop's own `.`
                // branch: `x?.y` is one operator, like `x[y]`.
                node = { k: K.dot, obj: node, key: tv(toks, pos + 1), line: pln, col: pcl };
                pos = pos + 2;
            } else {
                pos = pos + 1;  // the loop's `[` branch takes the subscript
            };
        } else if (is_op(toks, pos, "?.")) {
            // A `?.` with neither a field name nor `[` after it.
            node = expect_err(toks, pos + 1, "a field name or '[' after '?.'");
            pos = pos + 1;
            go = false;
        } else if (is_op(toks, pos, "++")) {
            // x++ — postfix: the OLD value is the expression's value, and
            // the target is evaluated once (a[f()]++ calls f once).
            node = { k: K.incdec, op: "++", pre: false, tgt: node, line: tline(toks, pos), col: tcol(toks, pos) };
            pos = pos + 1;
            go = false;
        } else if (is_op(toks, pos, "--")) {
            node = { k: K.incdec, op: "--", pre: false, tgt: node, line: tline(toks, pos), col: tcol(toks, pos) };
            pos = pos + 1;
            go = false;
        } else {
            go = false;
        };
    };
    // Close the `?.`s the chain opened, innermost first:
    //   { let $p = <recv>;
    //     if opt$test($p) { opt$val(<chain>) } else { none } }
    // The two `opt$` names are intrinsics only the parser emits -- a `$` is
    // not an identifier character, so no program can write one, and the
    // diagnostic can name `?.` instead. The chain is rooted at `unwrap($p)`,
    // so it only runs where $p is there; `opt$val` puts its result back in
    // an option box, which is what makes the whole `if` one. A broken chain
    // is left alone: the error it carries is the one to report.
    if (len(props) > 0 && node.k != K.err) {
        let pi = len(props) - 1;
        while (pi >= 0) {
            let pc: PropCtx = props[pi];
            let cargs: [Node] = [];
            cargs += { k: K.id, v: pc.tmp, line: pc.line, col: pc.col };
            let test: Node = { k: K.call, callee: { k: K.id, v: "opt$test", line: pc.line, col: pc.col }, args: cargs, line: pc.line, col: pc.col };
            let vargs: [Node] = [];
            vargs += node;
            let val: Node = { k: K.call, callee: { k: K.id, v: "opt$val", line: pc.line, col: pc.col }, args: vargs, line: pc.line, col: pc.col };
            let stmts: [Node] = [];
            stmts += let_node(pc.tmp, pc.recv, pc.line, pc.col);
            stmts += { k: K.kw_if, cond: test, then: block1(val, pc.line, pc.col), els: block1({ k: K.id, v: "none", line: pc.line, col: pc.col }, pc.line, pc.col), has_else: true, line: pc.line, col: pc.col };
            node = { k: K.block, stmts: stmts, line: pc.line, col: pc.col };
            pi = pi - 1;
        };
    };
    res(node, pos)
};

def parse_args(toks: [Tok], p: long) -> ParsedList {
    sep_by(toks, p, ")", "expr")
};

// A call node. `print(a, b, ...)` with several arguments prints them back
// to back on one line: it is print(tostring(a) + tostring(b) + ...).
def mk_call(callee: Node, args: [Node], ln: long, cl: long) -> Call {
    if (is_id_named(callee, "print") && len(args) > 1) {
        let cat: Node = tostring_call(args[0], ln, cl);
        let i = 1;
        while (i < len(args)) {
            cat = { k: K.bin, op: "+", l: cat, r: tostring_call(args[i], ln, cl), line: ln, col: cl };
            i = i + 1;
        };
        let one: [Node] = [];
        one += cat;
        { k: K.call, callee: callee, args: one, line: ln, col: cl }
    } else {
        { k: K.call, callee: callee, args: args, line: ln, col: cl }
    }
};

def tostring_call(arg: Node, ln: long, cl: long) -> Call {
    let one: [Node] = [];
    one += arg;
    { k: K.call, callee: { k: K.id, v: "tostring", line: ln, col: cl }, args: one, line: ln, col: cl }
};

def is_id_named(node: Node, name: str) -> bool {
    if (node.k == K.id) {
        let leaf: Leaf = node;
        leaf.v == name
    } else { false }
};

// ── binary expressions (precedence climbing) ─────────────────────────────

def parse_binary(toks: [Tok], p: long, min_prec: long) -> Parsed {
    let left_r = parse_unary(toks, p);
    let left = left_r.node;
    let pos = left_r.pos;
    let go = true;
    while (go) {
        let op = tv(toks, pos);
        let prec = 0;
        if (tt(toks, pos) == "op") { prec = op_prec(op); };
        // Nested ifs, not one `prec != 0 || prec < min_prec` gate: a mixed
        // long/bool gate reads worse, and `||` would type fine anyway
        // (typeof_logic takes any operand) — this is shape, not a rule.
        // The explicit else arms end in long-valued `0`s, keeping their
        // types aligned; the terminating `;` discards the value.
        if (prec == 0) {
            go = false;
        } else if (prec < min_prec) {
            go = false;
        } else {
            // `::` is right-associative: 1 :: 2 :: [3] is 1 :: (2 :: [3])
            // = [1, 2, 3]. Everything else is left-associative.
            let next_min = prec + 1;
            if (op == "::") {
                next_min = prec;
            }
            let right_r = parse_binary(toks, pos + 1, next_min);
            left = { k: K.bin, op: op, l: left, r: right_r.node, line: tline(toks, pos), col: tcol(toks, pos) };
            pos = right_r.pos;
        };
    };
    res(left, pos)
};

def parse_unary(toks: [Tok], p: long) -> Parsed {
    if (is_op(toks, p, "-")) {
        let inner = parse_unary(toks, p + 1);
        res({ k: K.un, op: tv(toks, p), e: inner.node, line: tline(toks, p), col: tcol(toks, p) }, inner.pos)
    } else if (is_op(toks, p, "!")) {
        let inner = parse_unary(toks, p + 1);
        res({ k: K.un, op: tv(toks, p), e: inner.node, line: tline(toks, p), col: tcol(toks, p) }, inner.pos)
    } else if (is_op(toks, p, "~")) {
        // bitwise not: ~x
        let inner = parse_unary(toks, p + 1);
        res({ k: K.un, op: tv(toks, p), e: inner.node, line: tline(toks, p), col: tcol(toks, p) }, inner.pos)
    } else if (is_op(toks, p, "&")) {
        // address-of: &x
        let inner = parse_unary(toks, p + 1);
        res({ k: K.addr, e: inner.node, line: tline(toks, p), col: tcol(toks, p) }, inner.pos)
    } else if (is_op(toks, p, "*")) {
        // dereference: *p
        let inner = parse_unary(toks, p + 1);
        res({ k: K.deref, e: inner.node, line: tline(toks, p), col: tcol(toks, p) }, inner.pos)
    } else if (is_op(toks, p, "++")) {
        // ++x — prefix: the NEW value is the expression's value
        let inner = parse_unary(toks, p + 1);
        res({ k: K.incdec, op: "++", pre: true, tgt: inner.node, line: tline(toks, p), col: tcol(toks, p) }, inner.pos)
    } else if (is_op(toks, p, "--")) {
        let inner = parse_unary(toks, p + 1);
        res({ k: K.incdec, op: "--", pre: true, tgt: inner.node, line: tline(toks, p), col: tcol(toks, p) }, inner.pos)
    } else {
        parse_postfix(toks, p)
    }
};

def parse_expr(toks: [Tok], p: long) -> Parsed {
    let c = parse_binary(toks, p, 1);
    if (is_op(toks, c.pos, "?")) {
        parse_ternary(toks, c.node, c.pos)
    } else {
        c
    }
};

// `c ? a : b` -- the lowest-precedence operator, right-associative. It IS
// `if (c) { a } else { b }`: arms that disagree make it void.
def parse_ternary(toks: [Tok], cond: Node, q: long) -> Parsed {
    let ln = tline(toks, q);
    let cl = tcol(toks, q);
    let a = parse_expr(toks, q + 1);
    let apos = a.pos;
    if (is_punct(toks, apos, ":")) {
        let b = parse_expr(toks, apos + 1);
        res({ k: K.kw_if, cond: cond, then: block1(a.node, ln, cl), els: block1(b.node, ln, cl), has_else: true, line: ln, col: cl }, b.pos)
    } else {
        res({ k: K.err, msg: "expected ':' in conditional expression, got '" + tv(toks, apos) + "'", line: tline(toks, apos), col: tcol(toks, apos) }, apos)
    }
};

// A block holding one expression (its value).
def block1(e: Node, ln: long, cl: long) -> Block {
    let one: [Node] = [];
    one += e;
    { k: K.block, stmts: one, line: ln, col: cl }
};

// ── compound literals ────────────────────────────────────────────────────

// The size in `[v; n]` and `[T; n]`: a decimal or radix integer literal
// from 0 to 2147483647 (2^31 - 1). Its value, or -1 for any other num
// token (a float, a larger number).
def size_lit(s: str) -> long {
    let p = s[0:2];
    let radix = 10;
    let i = 0;
    if (p == "0x" || p == "0X") { radix = 16; i = 2; }
    else if (p == "0b" || p == "0B") { radix = 2; i = 2; };
    let v = 0;
    while (i < len(s) && v >= 0) {
        let o = ord(s[i:i + 1]);
        // the digit's value: `.`, `e` (and a hex digit in a decimal) are
        // past the radix
        let d = 99;
        if (o >= c'0' && o <= c'9') { d = o - c'0'; }
        else if (o >= c'a' && o <= c'f') { d = o - c'a' + 10; }
        else if (o >= c'A' && o <= c'F') { d = o - c'A' + 10; };
        if (o == c'_') {
            // a radix literal keeps its `_` separators
        } else if (d >= radix || v > (2147483647 - d) / radix) {
            v = -1;
        } else {
            v = v * radix + d;
        };
        i = i + 1;
    };
    v
};

def parse_array(toks: [Tok], p: long) -> Parsed {
    // p is AT '['. Forms: [] and [a, b] (heap literals, later),
    // [v; n] (stack repeat: n copies of v — the native array form).
    let ln = tline(toks, p);
    let cl = tcol(toks, p);
    if (is_punct(toks, p + 1, "]")) {
        res({ k: K.array, elems: [], line: ln, col: cl }, p + 2)
    } else {
        let first = parse_expr(toks, p + 1);
        let pos = first.pos;
        if (is_punct(toks, pos, ";")) {
            // repeat: the size is an integer literal (size_lit); anything
            // else is parsed past and reported where it starts.
            let at = pos + 1;
            let n = -1;
            if (tt(toks, at) == "num") { n = size_lit(tv(toks, at)); };
            if (n >= 0) {
                close_res(toks, at + 1, "]", { k: K.arrrep, v: first.node, n: n, line: ln, col: cl })
            } else {
                let cnt = parse_expr(toks, at);
                close_res(toks, cnt.pos, "]", expect_err(toks, at, "an array size (an integer literal from 0 to 2147483647)"))
            }
        } else {
            // literal, with trailing-comma tolerance
            let elems = [first.node];
            let go = true;
            if (is_punct(toks, pos, ",")) { } else { go = false; };
            while (go) {
                pos = pos + 1;  // skip ','
                if (is_punct(toks, pos, "]")) {
                    go = false;
                } else {
                    let e = parse_expr(toks, pos);
                    elems += e.node;
                    pos = e.pos;
                    go = is_punct(toks, pos, ",");
                };
            };
            // Same guard as sep_by: a token that is neither ',' nor ']'
            // means the stream is malformed, and dropping it silently would
            // compile `[1, 2 zzz]` as `[1, 2]`.
            if (is_punct(toks, pos, "]")) { } else {
                elems += { k: K.err, msg: "unexpected " + tok_desc(toks, pos) + " (expected ',' or ']')", line: tline(toks, pos), col: tcol(toks, pos) };
            };
            res({ k: K.array, elems: elems, line: ln, col: cl }, skip_close(toks, pos, "]"))
        }
    }
};

// `{` in expression position is ambiguous: a record literal (`{a: 1}`) or a
// block expression (`{ let t = 1; t + 1 }`). Only `{}`, `{key: ...}`,
// `{"key": ...}` and the shorthand `{x, ...}` are records; everything else
// (`{ x }` included) is a block.
def brace_is_map(toks: [Tok], p: long) -> bool {
    if (is_punct(toks, p + 1, "}")) {
        true
    } else {
        let k = tt(toks, p + 1);
        if (k == "id") {
            is_punct(toks, p + 2, ":") || is_punct(toks, p + 2, ",")
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

def parse_map(toks: [Tok], p: long) -> Parsed {
    // p is AT '{'
    let ln = tline(toks, p);
    let cl = tcol(toks, p);
    let keys: [str] = [];
    let vals: [Node] = [];
    let is_map = false;
    let pos = p + 1;
    let bad = false;
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
            } else {
                // A quoted key makes a MAP literal ({k: K.map}); identifier
                // keys stay record fields ({k: K.rec}).
                if (is_map) {
                } else {
                    is_map = tt(toks, pos) == "str";
                };
                // Spread `...obj` lexes as `..` + `.`; the entry is
                // recorded under the "..." key with the source record as
                // its value (the checker and emitter merge it statically).
                let key = tv(toks, pos);
                let kt = tt(toks, pos);
                if (key == "..") {
                    key = "...";
                    pos = pos + 2;
                } else if (kt == "id" || kt == "str" || kt == "kw" || kt == "num") {
                    if (is_punct(toks, pos + 1, ":")) {
                        pos = pos + 2;
                    } else if (kt == "id" && (is_punct(toks, pos + 1, ",") || is_punct(toks, pos + 1, "}"))) {
                        // `{x, y}` is `{x: x, y: y}`: the name is parsed
                        // again below, as the value.
                    } else {
                        keys += key;
                        vals += expect_err(toks, pos + 1, "':' after the key");
                        bad = true;
                    };
                } else {
                    keys += key;
                    vals += expect_err(toks, pos, "a key");
                    bad = true;
                };
                if (bad) {
                    go = false;
                } else {
                    let e = parse_expr(toks, pos);
                    keys += key;
                    vals += e.node;
                    pos = e.pos;
                    if (is_punct(toks, pos, ",")) { pos = pos + 1; } else { go = false; };
                };
            };
        };
        if (bad) {
            res(maplit_node(is_map, keys, vals, ln, cl), pos)
        } else {
            close_res(toks, pos, "}", maplit_node(is_map, keys, vals, ln, cl))
        }
    }
};

// `{a: 1}` is a record ({k: K.rec}), `{"a": 1}` a map ({k: K.map}).
def maplit_node(is_map: bool, keys: [str], vals: [Node], ln: long, cl: long) -> RecLit {
    if (is_map) { { k: K.map, keys: keys, vals: vals, line: ln, col: cl } }
    else { { k: K.rec, keys: keys, vals: vals, line: ln, col: cl } }
};

// ── type parsing ─────────────────────────────────────────────────────────
// Types are parsed into type-node maps (not just skipped): kinds tlong,
// tbool, tstr, tvoid, tname (unresolved name -> checker error), tptr {to},
// tarr {of}, tparams {ts} (parenthesized list, resolved by arrow context),
// tfunc {args, ret}, trec {fields: [{name, typ}]}, tmap {key, of},
// tnone (no annotation).
// Extra fields are ignored by the checker and the emitter, so this is
// additive.

def parse_type_node(toks: [Tok], p: long) -> PType {
    // NOTE: NO `node`/`pos` locals shared across arms. Earlier this function
    // used one `node` name rebound in every arm; the checker env is
    // flow-INSENSITIVE (last shape wins), so `node.ts` in the arrow tail
    // resolved against the tfunc shape ("record has no field 'ts'") and
    // `target.arr` reads in parse_stmt resolved against rebound shapes.
    // The atom dispatches first, then ONE tail applies `?` + `->` with
    // fresh names only (parse_type_tail below).
    // (Every arm's tail IS its tres(), so no arm can fall through into the
    // next — each one is the last expression in its body.)
    // NOTE: atom arms need parse_type_array/params/record/atom2 (defined
    // BELOW — forward refs are fine: defs hoist per block level in rename).
    if (is_op(toks, p, "*")) {
        // pointer type: *T
        let inner = parse_type_node(toks, p + 1);
        let pin = { k: K.tptr, to: inner.node };
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
def parse_type_array(toks: [Tok], p: long) -> PType {
    let inner = parse_type_node(toks, p + 1);
    if (is_punct(toks, inner.pos, ";")) {
        let np = inner.pos + 1;
        let n = -1;
        if (tt(toks, np) == "num") { n = size_lit(tv(toks, np)); };
        if (n >= 0) {
            let fc = tclose_res(toks, np + 1, "]", { k: K.tarrfix, of: inner.node, n: n });
            parse_type_tail(toks, fc.pos, fc.node)
        } else {
            tres(terr_at(toks, np, "an array size (an integer literal from 0 to 2147483647)"), np)
        }
    } else {
        let ac = tclose_res(toks, inner.pos, "]", { k: K.tarr, of: inner.node });
        parse_type_tail(toks, ac.pos, ac.node)
    }
};

// A malformed type: the parser plants `terr` and the declaration that owns
// the annotation turns it into an `err` node (type_err below), so the
// checker never sees a terr.
def terr_at(toks: [Tok], p: long, what: str) -> Err {
    { k: K.terr, msg: "expected " + what + " in a type, got " + tok_desc(toks, p), line: tline(toks, p), col: tcol(toks, p) }
};

// close_res for types.
def tclose_res(toks: [Tok], p: long, closer: str, tnode: Type) -> PType {
    if (is_punct(toks, p, closer)) {
        tres(tnode, p + 1)
    } else {
        tres(terr_at(toks, p, "'" + closer + "'"), p)
    }
};

// The first `terr` in a parsed annotation, as an `err` node at its
// position -- `void` when the type is well formed.
def type_err(t: Type) -> Node {
    let k: long = t.k;
    if (k == K.terr) {
        let e: Err = t;
        let node: Node = { k: K.err, msg: e.msg, line: e.line, col: e.col };
        node
    }
    else if (k == K.tptr) {
        let ptr: TPtr = t;
        type_err(ptr.to)
    }
    else if (k == K.tarr) {
        let arr: TOf = t;
        type_err(arr.of)
    }
    else if (k == K.tarrfix) {
        let arr: TFix = t;
        type_err(arr.of)
    }
    else if (k == K.topt) {
        let opt: TOf = t;
        type_err(opt.of)
    }
    else if (k == K.tmap) {
        let map: TMap = t;
        type_err_then(type_err(map.key), map.of)
    }
    else if (k == K.trec) {
        let rec: TRec = t;
        type_err_fields(rec.fields)
    }
    else if (k == K.tfunc) {
        let func: TFunc = t;
        type_err_then(type_err_list(func.args), func.ret)
    }
    else if (k == K.tparams || k == K.tunion) {
        let list: TList = t;
        type_err_list(list.ts)
    }
    else {
        let node: Node = { k: K.void, line: 1, col: 1 };
        node
    }
};

// `first` when it is an error, else the first error in `t`.
def type_err_then(first: Node, t: Type) -> Node {
    if (first.k == K.err) { first } else { type_err(t) }
};

def type_err_list(ts: [Type]) -> Node {
    let out: Node = { k: K.void, line: 1, col: 1 };
    let i = 0;
    while (i < len(ts)) {
        if (out.k == K.void) { out = type_err(ts[i]); }
        i = i + 1;
    };
    out
};

def type_err_fields(fs: [Field]) -> Node {
    let out: Node = { k: K.void, line: 1, col: 1 };
    let i = 0;
    while (i < len(fs)) {
        let f = fs[i];
        if (out.k == K.void) { out = type_err(f.typ); }
        i = i + 1;
    };
    out
};

// (T, T) tail of parse_type_node + shared postfix tail (fresh names — see note).
def parse_type_params(toks: [Tok], p: long) -> PType {
    // NOTE: statement-form loops + `0;` tails — while bodies must be
    // void-typed (see parse_binary note).
    let ts: [Type] = [];
    let pos = p + 1;  // skip '('
    if (!is_punct(toks, pos, ")")) {
        let go = true;
        while (go) {
            if (is_punct(toks, pos, ")")) {
                go = false;
            } else {
                let t = parse_type_node(toks, pos);
                ts += t.node;
                pos = t.pos;
                if (is_punct(toks, pos, ",")) { pos = pos + 1; } else { go = false; };
            };
        };
    };
    if (is_punct(toks, pos, ")")) {
        parse_type_tparams(toks, pos + 1, ts)
    } else {
        tres(terr_at(toks, pos, "')'"), pos)
    }
};

// The key type of a map type ({K => V}): K must be hashable (str, long,
// byte, bool, float). Anything else stays a named type for the checker
// to reject.
def map_key_type(name: str) -> Type {
    if (name == "str") { let ty: Type = { k: K.tstr }; ty }
    else if (name == "long") { let ty: Type = { k: K.tlong }; ty }
    else if (name == "byte") { let ty: Type = { k: K.tbyte }; ty }
    else if (name == "bool") { let ty: Type = { k: K.tbool }; ty }
    else if (name == "float") { let ty: Type = { k: K.tfloat }; ty }
    else { let ty: Type = { k: K.tname, name: name }; ty }
};

// { field: T, ... } tail of parse_type_node (fresh names — see note).
def parse_type_record(toks: [Tok], p: long) -> PType {
    // `{ f: T, ... }` is a record shape; `{ K => V }` is a map type.
    let fields: [Field] = [];
    let pos = p + 1;  // skip '{'
    if (!is_punct(toks, pos, "}")) {
        let go = true;
        while (go) {
            if (is_punct(toks, pos, "}")) {
                go = false;
            } else {
                let fname = tv(toks, pos);
                if (!is_name_tok(toks, pos)) {
                    return tres(terr_at(toks, pos, "a field name"), pos);
                };
                if (is_op(toks, pos + 1, "=>")) {
                    // map type: the key is a type name, then =>, then V
                    let kt = map_key_type(fname);
                    let vt = parse_type_node(toks, pos + 2);
                    let mc = tclose_res(toks, vt.pos, "}", { k: K.tmap, key: kt, of: vt.node });
                    return parse_type_tail(toks, mc.pos, mc.node);
                };
                // `name?: T`: an optional field, of type T?
                let fopt = is_op(toks, pos + 1, "?");
                let cpos = pos + 1;
                if (fopt) { cpos = pos + 2; };
                if (!is_punct(toks, cpos, ":")) {
                    return tres(terr_at(toks, cpos, "':'"), cpos);
                };
                let ft = parse_type_node(toks, cpos + 1);  // skip name and ':'
                let fty: Type = ft.node;
                if (fopt) { fty = topt_of(fty); };
                fields += { name: fname, opt: fopt, typ: fty };
                pos = ft.pos;
                // fields are separated by `,` or `;` (a trailing one is fine)
                if (is_punct(toks, pos, ",") || is_punct(toks, pos, ";")) { pos = pos + 1; } else { go = false; };
            };
        };
    };
    let rc = tclose_res(toks, pos, "}", { k: K.trec, fields: fields });
    parse_type_tail(toks, rc.pos, rc.node)
};

// Simple type-name atom tail of parse_type_node (fresh names — see note).
def parse_type_atom2(toks: [Tok], p: long) -> PType {
    // simple type name (`int` is `long`) + shared postfix tail.
    let nm = tv(toks, p);
    if (tt(toks, p) != "id") { tres(terr_at(toks, p, "a type"), p) }
    else if (nm == "long") { parse_type_tail(toks, p + 1, { k: K.tlong }) }
    else if (nm == "int") { parse_type_tail(toks, p + 1, { k: K.tlong }) }
    else if (nm == "byte") { parse_type_tail(toks, p + 1, { k: K.tbyte }) }
    else if (nm == "bool") { parse_type_tail(toks, p + 1, { k: K.tbool }) }
    else if (nm == "str") { parse_type_tail(toks, p + 1, { k: K.tstr }) }
    else if (nm == "float") { parse_type_tail(toks, p + 1, { k: K.tfloat }) }
    else if (nm == "void") { parse_type_tail(toks, p + 1, { k: K.tvoid }) }
    else if (nm == "mutex" || nm == "sem") { parse_type_tail(toks, p + 1, sync_type(nm)) }
    else if (is_op(toks, p + 1, ".") && tt(toks, p + 2) == "id") {
        // `m.T`: alias T of the module imported as m
        parse_type_tail(toks, p + 3, { k: K.tname, name: nm + "." + tv(toks, p + 2) })
    }
    else { parse_type_tail(toks, p + 1, { k: K.tname, name: nm }) }
};

// Postfix tail shared by ALL atom arms: `?` then `->` (fresh names — see
// note). Every atom arm above calls parse_type_tail(toks, apos, anode)
// instead of returning its shape directly, so `?`/`->` apply uniformly
// (previously only some arms applied them — the rest silently dropped
// option/arrow suffixes).
def parse_type_tail(toks: [Tok], apos: long, anode: Type) -> PType {
    // postfix `?`: option type (binds tighter than `->`)
    // Both paths return the same parser-result shape; `?` wraps the atom
    // before the shared arrow parser handles the suffix.
    if (is_op(toks, apos, "?")) {
        // NOTE: `?` then re-check `->`: T? -> U must keep parsing the arrow
        // (right-assoc). The `?` shape feeds parse_type_arrow as its anode.
        parse_type_arrow(toks, apos + 1, { k: K.topt, of: anode })
    } else {
        parse_type_arrow(toks, apos, anode)
    }
};

// Arrow tail: `->` B (right-assoc) or bare grouping (fresh names — see note).
def parse_type_arrow(toks: [Tok], apos: long, anode: Type) -> PType {
    // Every atom shape reaches here — plain atoms and the `{k:K.topt}`
    // wrapper parse_type_tail builds for `T?` — and this body reads NO
    // field of `anode` at all, it hands the node to parse_type_plain. That
    // is deliberate: `anode` is one PARAM name shared by every call site,
    // so any `anode.k`/`anode.ts` read here would resolve against the
    // MERGED shape family of all of them (a name's type is fixed at its
    // binding — rename.y uniquifies every let — and the checker keeps one
    // type per name). The tparams branch never comes through here:
    // parse_type_params calls parse_type_tparams directly with the TS
    // LIST.
    parse_type_plain(toks, apos, anode)
};

def parse_type_plain(toks: [Tok], apos: long, anode: Type) -> PType {
    // Every non-tparams atom (including the topt wrapper): `->` builds
    // tfunc, else the node itself. This body contains NO `anode.k`/
    // `anode.ts` reads at all, so nothing merges here.
    if (is_op(toks, apos, "->")) {
        let rhs = parse_type_node(toks, apos + 1);
        tres({ k: K.tfunc, args: [anode], ret: rhs.node }, rhs.pos)
    } else {
        tres(anode, apos)
    }
};

def parse_type_tparams(toks: [Tok], apos: long, tlist: [Type]) -> PType {
    // Reached only from parse_type_params (a parenthesized list), which
    // passes the TS LIST itself (not a tparams record), so this body
    // contains NO record field reads at all — nothing to merge, nothing to
    // mis-resolve.
    // `->` after a param list: (A, B) -> R. Else bare grouping: (T) = T.
    let ts0 = tlist;
    if (is_op(toks, apos, "->")) {
        let rhs = parse_type_node(toks, apos + 1);
        tres({ k: K.tfunc, args: ts0, ret: rhs.node }, rhs.pos)
    } else if (len(ts0) == 1) {
        tres(ts0[0], apos)
    } else {
        tres({ k: K.tparams, ts: ts0 }, apos)
    }
};

def parse_type_atom(toks: [Tok], p: long) -> long {
    // Parse a single non-arrow type and return the position after it.
    // Atoms: long, str, bool, [T], (T, T), { field: T, ... }
    // NOTE: no callers left — parse_type below is the only one, and nothing
    // calls that (annotations go through parse_type_full). Dead code: the
    // defs are not tree-shaken, so removing them changes the golden binary.
    let r = parse_type_node(toks, p);
    r.pos
};

def parse_type(toks: [Tok], p: long) -> long {
    // Parse a type annotation and return the position after it.
    // Types: long, str, bool, [T], (T, T), { field: T }, and function types
    // A -> B (right-associative, so A -> B -> C = A -> (B -> C)).
    // The recursive arm only updates `pos`; this conditional's value is
    // discarded, so its VOID-law arm mismatch does not affect the result.
    // NOTE: dead code — see parse_type_atom.
    let pos = parse_type_atom(toks, p);
    if (is_op(toks, pos, "->")) {
        pos = parse_type(toks, pos + 1);
    };
    pos
};

// ── function literal ─────────────────────────────────────────────────────

// `A | B | ...` -- a union of record types. Accepted where a whole
// annotation is parsed (let, params, returns, `type` declarations); a
// union nested inside another type goes through an alias.
def parse_type_full(toks: [Tok], p: long) -> PType {
    let first = parse_type_node(toks, p);
    if (is_op(toks, first.pos, "|")) {
        let ts: [Type] = [];
        ts += first.node;
        let pos = first.pos;
        while (is_op(toks, pos, "|")) {
            let r = parse_type_node(toks, pos + 1);
            ts += r.node;
            pos = r.pos;
        };
        tres({ k: K.tunion, ts: ts }, pos)
    } else {
        first
    }
};

// The type a literal default value gives an unannotated parameter
// (`tnone` when the value is not a literal).
def lit_type(node: Node) -> Type {
    let k: long = node.k;
    if (k == K.num) {
        let leaf: Leaf = node;
        num_lit_type(leaf.v)
    }
    else if (k == K.str) { let ty: Type = { k: K.tstr }; ty }
    else if (k == K.bool) { let ty: Type = { k: K.tbool }; ty }
    else if (k == K.char) { let ty: Type = { k: K.tbyte }; ty }
    else if (k == K.un) {
        let un: Un = node;
        lit_type_neg(un)
    }
    else { let ty: Type = { k: K.tnone }; ty }
};

def lit_type_neg(node: Un) -> Type {
    let e = node.e;
    if (node.op == "-" && e.k == K.num) {
        let leaf: Leaf = e;
        num_lit_type(leaf.v)
    } else { let ty: Type = { k: K.tnone }; ty }
};

// T? -- the type an optional parameter `name?: T` has in the body.
def topt_of(t: Type) -> TOf { { k: K.topt, of: t } };

// float when the literal has a fraction or an exponent (radix literals
// like 0xE1 never do).
def num_lit_type(s: str) -> Type {
    let p = s[0:2];
    if (p == "0x" || p == "0X" || p == "0b" || p == "0B") { { k: K.tlong } }
    else if (index_of(s, ".") >= 0 || index_of(s, "e") >= 0 || index_of(s, "E") >= 0) { { k: K.tfloat } }
    else { { k: K.tlong } }
};

def parse_func(toks: [Tok], p: long) -> Parsed {
    // Named:    def name(params) -> ret { body }   (top-level declaration)
    // Anonymous: def(params) -> ret { body }        (function expression)
    let ln = tline(toks, p);
    let cl = tcol(toks, p);
    let pos = p + 1;  // skip 'def'
    let fname = "";
    // A malformed header plants its errors here; they run first in the body.
    let derrs: [Node] = [];
    // optional function name (present unless next token is '(')
    // Only the optional-name branch changes `fname` and `pos`; both are
    // consumed by the common parsing path below.
    if (!is_punct(toks, pos, "(")) {
        if (tt(toks, pos) == "id") {
            fname = tv(toks, pos);
            pos = pos + 1;
        } else {
            derrs += expect_err(toks, pos, "a function name or '('");
        };
    };
    let hbad = len(derrs) > 0;
    if (is_punct(toks, pos, "(")) {
        pos = pos + 1;
    } else {
        if (!hbad) { derrs += expect_err(toks, pos, "'('"); }
        hbad = true;
    };
    let names: [str] = [];
    let ptypes: [Type] = [];
    // defs[i]: param i's default value (a literal), `void` when it has none,
    // `optarg` for an optional `name?: T` (none when left out, some(arg) when
    // passed -- rename.y fills both in)
    let defs: [Node] = [];
    let optname = "";
    if (!hbad && !is_punct(toks, pos, ")")) {
        let go = true;
        while (go) {
            if (tt(toks, pos) != "id") {
                derrs += expect_err(toks, pos, "a parameter name");
                hbad = true;
                go = false;
            } else {
                let nm = tv(toks, pos);
                names += nm;
                pos = pos + 1;  // name
                let isopt = false;
                if (is_op(toks, pos, "?")) {
                    isopt = true;
                    pos = pos + 1;
                    if (!is_punct(toks, pos, ":")) {
                        derrs += { k: K.err, msg: "optional parameter '" + nm + "' needs a type ('" + nm + "?: T')", line: tline(toks, pos), col: tcol(toks, pos) };
                    };
                };
                let pt: Type = { k: K.tnone };
                if (is_punct(toks, pos, ":")) {
                    let tr = parse_type_full(toks, pos + 1);
                    pt = tr.node;
                    pos = tr.pos;
                    let pte = type_err(pt);
                    if (pte.k == K.err) {
                        derrs += pte;
                        pt = { k: K.tnone };
                        hbad = true;
                    }
                };
                let dv: Node = { k: K.void, line: tline(toks, pos), col: tcol(toks, pos) };
                if (is_op(toks, pos, "=")) {
                    // `name = literal`: callers may leave it out; without an
                    // annotation the literal also gives the parameter its type.
                    let dr = parse_unary(toks, pos + 1);
                    pos = dr.pos;
                    let dt = lit_type(dr.node);
                    if (dt.k == K.tnone) {
                        derrs += { k: K.err, msg: "default value of parameter '" + nm + "' must be a literal", line: tline(toks, pos), col: tcol(toks, pos) };
                    } else {
                        dv = dr.node;
                        if (pt.k == K.tnone) { pt = dt; };
                    };
                    if (isopt) {
                        derrs += { k: K.err, msg: "optional parameter '" + nm + "' cannot have a default (it is none when left out)", line: tline(toks, pos), col: tcol(toks, pos) };
                    };
                };
                if (isopt) {
                    if (pt.k != K.tnone) { pt = topt_of(pt); };
                    dv = { k: K.optarg, line: tline(toks, pos), col: tcol(toks, pos) };
                    optname = nm;
                } else if (optname != "" && dv.k == K.void) {
                    derrs += { k: K.err, msg: "required parameter '" + nm + "' cannot follow optional parameter '" + optname + "' (optional parameters come last)", line: tline(toks, pos), col: tcol(toks, pos) };
                };
                ptypes += pt;
                defs += dv;
                if (is_punct(toks, pos, ",")) {
                    pos = pos + 1;
                } else {
                    go = false;
                };
            };
        };
    };
    if (is_punct(toks, pos, ")")) {
        pos = pos + 1;
    } else {
        if (!hbad) { derrs += expect_err(toks, pos, "',' or ')'"); }
    };
    // optional return type '-> type'
    // The optional return annotation updates the local type and position.
    let ret: Type = { k: K.tnone };
    if (is_op(toks, pos, "->")) {
        let rr = parse_type_full(toks, pos + 1);
        ret = rr.node;
        pos = rr.pos;
        let rte = type_err(ret);
        if (rte.k == K.err) {
            derrs += rte;
            ret = { k: K.tnone };
        }
    };
    let body = parse_block(toks, pos);
    let bnode: Block = body.node;
    if (len(derrs) > 0) {
        let bst: [Node] = bnode.stmts;
        let nst: [Node] = [];
        nst += derrs;
        nst += bst;
        bnode = { k: K.block, stmts: nst, line: bnode.line, col: bnode.col };
    };
    let func: Func = { k: K.func, params: names, ptypes: ptypes, ret: ret, body: bnode, line: ln, col: cl, defs: defs };
    if (fname == "") {
        res(func, body.pos)
    } else {
        res({ k: K.decl, kind: "def", name: fname, typ: { k: K.tnone }, v: func, line: ln, col: cl }, body.pos)
    }
};

// ── block { stmt; stmt; ... } ────────────────────────────────────────────

def parse_block(toks: [Tok], p: long) -> Parsed {
    let ln = tline(toks, p);
    let cl = tcol(toks, p);
    if (!is_punct(toks, p, "{")) {
        // A body was required here (if/while/for/def). Nothing is consumed:
        // the stray token is parsed by whatever comes next.
        let one: [Node] = [];
        one += expect_err(toks, p, "'{'");
        return res({ k: K.block, stmts: one, line: ln, col: cl }, p);
    };
    let pos = p + 1;  // skip '{'
    let stmts: [Node] = [];
    let go = true;
    // A block whose last statement ends in `;` is void: `{ f(); }` computes
    // nothing, `{ f() }` is f's value. A trailing `return x;` (or a branch
    // that always returns) keeps its meaning -- control never gets past it.
    let last_semi = false;
    while (go) {
        // NOTE: statement-form + `0;` tails — the while body must be
        // void-typed (see parse_binary note).
        if (is_punct(toks, pos, "}")) {
            go = false;
        } else if (tt(toks, pos) == "eof") {
            stmts += { k: K.err, msg: "unclosed '{' (no matching '}' before end of input)", line: ln, col: cl };
            go = false;
        } else {
            let s = parse_stmt(toks, pos);
            stmts += s.node;
            pos = stmt_end(toks, pos, s.pos, s.node, stmts);
            last_semi = is_punct(toks, pos - 1, ";");
        };
    };
    if (last_semi && !stmt_diverges(stmts[len(stmts) - 1])) {
        stmts += { k: K.void, line: tline(toks, pos), col: tcol(toks, pos) };
    }
    res({ k: K.block, stmts: stmts, line: ln, col: cl }, skip_close(toks, pos, "}"))
};

// After a statement that began at `start` and ended at pos: past its `;`.
// A statement not followed by `;` must end its block (`}`) or the input,
// or itself end in `}` (an if/while/def/block runs straight into the next
// statement). Anything else is two statements run together, `f() g()`: an
// error goes into `stmts` (unless the statement is itself one) and parsing
// resumes after the next `;`. A statement that consumed nothing (a stray
// `)` after `if c { }`) does not end in the `}` before it -- taking it
// for one would parse the same token forever.
def stmt_end(toks: [Tok], start: long, pos: long, sn: Node, stmts: [Node]) -> long {
    if (is_punct(toks, pos, ";")) {
        pos + 1
    } else if (is_punct(toks, pos, "}") || tt(toks, pos) == "eof") {
        pos
    } else if (pos > start && is_punct(toks, pos - 1, "}")) {
        pos
    } else {
        if (sn.k != K.err) { stmts += expect_err(toks, pos, "';'"); }
        skip_close(toks, sync_stmt(toks, pos), ";")
    }
};

// Does control never continue past this statement? `return`, and an
// if/else (or block) whose every path ends in one.
def stmt_diverges(s: Node) -> bool {
    let k: long = s.k;
    if (k == K.ret) { true }
    else if (k == K.block) {
        let block: Block = s;
        block_diverges(block.stmts)
    }
    else if (k == K.kw_if) {
        let branch: If = s;
        if_diverges(branch)
    }
    else { false }
};

def block_diverges(stmts: [Node]) -> bool {
    if (len(stmts) == 0) { false } else { stmt_diverges(stmts[len(stmts) - 1]) }
};

def if_diverges(s: If) -> bool {
    if (s.has_else) { stmt_diverges(s.then) && stmt_diverges(s.els) } else { false }
};

// ── statements ───────────────────────────────────────────────────────────

def parse_stmt(toks: [Tok], p: long) -> Parsed {
    if (is_punct(toks, p, ";")) {
        // An empty statement; the caller steps over the `;`.
        res({ k: K.void, line: tline(toks, p), col: tcol(toks, p) }, p)
    }
    else if (is_kw(toks, p, "let")) { parse_decl(toks, p) }
    else if (is_kw(toks, p, "const")) { parse_decl(toks, p) }
    else if (is_typedef_start(toks, p)) { parse_typedef(toks, p) }
    else if (is_kw(toks, p, "return")) {
        if (is_punct(toks, p + 1, ";") || is_punct(toks, p + 1, "}") || tt(toks, p + 1) == "eof") {
            res({ k: K.ret, e: { k: K.void, line: tline(toks, p), col: tcol(toks, p) }, line: tline(toks, p), col: tcol(toks, p) }, p + 1)
        } else {
            let e = parse_expr(toks, p + 1);
            res({ k: K.ret, e: e.node, line: tline(toks, p), col: tcol(toks, p) }, e.pos)
        }
    } else {
        // expression, possibly an assignment: id = expr, arr[i] = expr, or obj.key = expr
        // One def per target shape (see parse_stmt_assign): the callees
        // below each read ONLY their own shape's fields, because a name
        // carries ONE type — a param annotated `{k: long}` may read `.k`
        // and nothing else (types.y's dot arm: "record has no field 'arr'"),
        // and rename.y gives every binding a unique name, so a local's type
        // is the one from its own `let`, not the shapes assigned to it
        // later.
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

// `type Name = T;` -- a type alias (`type` is a keyword only here, so it
// stays usable as an ordinary name everywhere else).
def is_typedef_start(toks: [Tok], p: long) -> bool {
    tt(toks, p) == "id" && tv(toks, p) == "type" && tt(toks, p + 1) == "id" && is_op(toks, p + 2, "=")
};

def parse_typedef(toks: [Tok], p: long) -> Parsed {
    let r = parse_type_full(toks, p + 3);
    let te = type_err(r.node);
    if (te.k == K.err) {
        res(te, sync_stmt(toks, r.pos))
    } else {
        res({ k: K.typedef, name: tv(toks, p + 1), typ: r.node, line: tline(toks, p), col: tcol(toks, p) }, r.pos)
    }
};

// `x op= e`. The target keeps its expression form — a[f()] += 1 evaluates
// f() once. Array targets reinterpret `+=` (push/append) and `*=` (prepend
// an element) in the emitter; everywhere else `*=` is multiply-assign.
def is_compound_assign(toks: [Tok], p: long) -> bool {
    if (is_op(toks, p, "+=")) { true }
    else if (is_op(toks, p, "-=")) { true }
    else if (is_op(toks, p, "*=")) { true }
    else if (is_op(toks, p, "/=")) { true }
    else if (is_op(toks, p, "%=")) { true }
    else if (is_op(toks, p, "&=")) { true }
    else if (is_op(toks, p, "|=")) { true }
    else if (is_op(toks, p, "^=")) { true }
    else if (is_op(toks, p, "<<=")) { true }
    else if (is_op(toks, p, ">>=")) { true }
    else { is_op(toks, p, ">>>=") }
};

def parse_stmt_opassign(toks: [Tok], p: long, tgt: Node, epos: long) -> Parsed {
    // NOTE: `p` is unused — the operator token is at `epos`, and line/col
    // come from there too (the C twin marks it `(void)p;`).
    let op = tv(toks, epos);
    let rhs = parse_expr(toks, epos + 1);
    // Every compound op is `X=`, so the binary op is all but its last
    // character (`>>>=` is `>>>`).
    let binop = op[0:len(op) - 1];
    res({ k: K.opassign, op: binop, tgt: tgt, v: rhs.node, line: tline(toks, epos), col: tcol(toks, epos) }, rhs.pos)
};

// Assignment dispatch: one def per target shape (see parse_stmt note).
// Each body reads ONLY its own shape's fields — no merged-shape reads.
def parse_stmt_assign(toks: [Tok], p: long, tgt: Node, epos: long) -> Parsed {
    // ONE `tgt.k` read per body: `tgt` is annotated `{k: long}` here, so this
    // is the only field it may read. index gets a dedicated callee;
    // everything else (dot, deref, slice, plain id) goes to parse_stmt_rest.
    if (tgt.k == K.index) {
        parse_stmt_idxassign(toks, p, tgt, epos)
    } else {
        parse_stmt_rest(toks, p, tgt, epos)
    }
};

def parse_stmt_idxassign(toks: [Tok], p: long, tgt: Index, epos: long) -> Parsed {
    // NOTE: hand the WHOLE target to a callee whose param is a DIFFERENT
    // name (`itgt`): `tgt` is annotated `{k: long}` and cannot read
    // `tgt.arr` here at all (see parse_stmt note), so the fields must be
    // read in a body that takes the node unannotated.
    parse_stmt_idxassign_go(toks, p, tgt, epos)
};

def parse_stmt_idxassign_go(toks: [Tok], p: long, itgt: Index, epos: long) -> Parsed {
    let rhs = parse_expr(toks, epos + 1);
    res({ k: K.idxassign, arr: itgt.arr, idx: itgt.idx, v: rhs.node, line: tline(toks, p), col: tcol(toks, p) }, rhs.pos)
};



def parse_stmt_rest(toks: [Tok], p: long, tgt: Node, epos: long) -> Parsed {
    if (tgt.k == K.dot) {
        parse_stmt_dotassign(toks, p, tgt, epos)
    } else {
        parse_stmt_simple(toks, p, tgt, epos)
    }
};

def parse_stmt_dotassign(toks: [Tok], p: long, tgt: Dot, epos: long) -> Parsed {
    // NOTE: same whole-target handoff as idxassign (see note above).
    parse_stmt_dotassign_go(toks, p, tgt, epos)
};

def parse_stmt_dotassign_go(toks: [Tok], p: long, dtgt: Dot, epos: long) -> Parsed {
    let rhs = parse_expr(toks, epos + 1);
    res({ k: K.dotassign, obj: dtgt.obj, key: dtgt.key, v: rhs.node, line: tline(toks, p), col: tcol(toks, p) }, rhs.pos)
};



def parse_stmt_simple(toks: [Tok], p: long, tgt: Node, epos: long) -> Parsed {
    // deref (*p = v) vs plain id (x = v): separate callees per shape, the
    // whole target handed over unannotated (see parse_stmt_idxassign_go
    // note).
    if (tgt.k == K.deref) {
        parse_stmt_store(toks, p, tgt, epos)
    } else {
        parse_stmt_simple2(toks, p, tgt, epos)
    }
};

def parse_stmt_simple2(toks: [Tok], p: long, tgt: Node, epos: long) -> Parsed {
    if (tgt.k == K.slice) {
        parse_stmt_sliceassign(toks, p, tgt, epos)
    } else {
        parse_stmt_plainassign(toks, p, tgt, epos)
    }
};

// `a[lo:hi] = src`: overwrite that range of a with src's elements (the
// lengths must agree; checked at run time).
def parse_stmt_sliceassign(toks: [Tok], p: long, ltgt: Slice, epos: long) -> Parsed {
    let rhs = parse_expr(toks, epos + 1);
    res({ k: K.sliceassign, arr: ltgt.arr, lo: ltgt.lo, hi: ltgt.hi, v: rhs.node, line: tline(toks, p), col: tcol(toks, p) }, rhs.pos)
};

def parse_stmt_store(toks: [Tok], p: long, stgt: Wrap, epos: long) -> Parsed {
    let rhs = parse_expr(toks, epos + 1);
    res({ k: K.store, p: stgt.e, v: rhs.node, line: tline(toks, p), col: tcol(toks, p) }, rhs.pos)
};

def parse_stmt_plainassign(toks: [Tok], p: long, atgt: Node, epos: long) -> Parsed {
    let rhs = parse_expr(toks, epos + 1);
    if (atgt.k == K.id) {
        let leaf: Leaf = atgt;
        res({ k: K.assign, name: leaf.v, v: rhs.node, line: tline(toks, p), col: tcol(toks, p) }, rhs.pos)
    } else if (atgt.k == K.err) {
        res(atgt, rhs.pos)
    } else {
        res({ k: K.err, msg: "cannot assign to this expression", line: tline(toks, p), col: tcol(toks, p) }, rhs.pos)
    }
};

def parse_decl(toks: [Tok], p: long) -> Parsed {
    let kind = tv(toks, p);
    let name = tv(toks, p + 1);
    let ln = tline(toks, p);
    let cl = tcol(toks, p);
    if (tt(toks, p + 1) != "id") {
        return res(expect_err(toks, p + 1, "a name after '" + kind + "'"), sync_stmt(toks, p + 1));
    };
    let pos = p + 2;
    // optional ': type' (kept as a type node for the static checker)
    // The optional annotation updates the local type and position.
    let typ: Type = { k: K.tnone };
    if (is_punct(toks, pos, ":")) {
        let tr = parse_type_full(toks, pos + 1);
        typ = tr.node;
        pos = tr.pos;
        let te = type_err(typ);
        if (te.k == K.err) {
            // The name stays bound (untyped), so its later uses do not
            // pile up "undefined" errors behind this one.
            return res({ k: K.decl, kind: kind, name: name, typ: { k: K.tnone }, v: te, line: ln, col: cl }, sync_stmt(toks, pos));
        };
    };
    if (!is_op(toks, pos, "=")) {
        return res({ k: K.decl, kind: kind, name: name, typ: { k: K.tnone }, v: expect_err(toks, pos, "'='"), line: ln, col: cl }, sync_stmt(toks, pos));
    };
    let e = parse_expr(toks, pos + 1);
    res({ k: K.decl, kind: kind, name: name, typ: typ, v: e.node, line: ln, col: cl }, e.pos)
};

// Past a broken statement: to the next `;` or the `}` closing the
// enclosing block (neither consumed), or the end of input, stepping over
// bracketed groups -- so one mistake is one error, not a cascade.
def sync_stmt(toks: [Tok], p: long) -> long {
    let pos = p;
    let depth = 0;
    let go = true;
    while (go) {
        let t = tt(toks, pos);
        if (t == "eof") {
            go = false;
        } else if (t == "punct") {
            let v = tv(toks, pos);
            if (depth == 0 && (v == ";" || v == "}")) {
                go = false;
            } else {
                if (v == "(" || v == "[" || v == "{") {
                    depth = depth + 1;
                } else if (v == ")" || v == "]" || v == "}") {
                    if (depth > 0) { depth = depth - 1; }
                }
                pos = pos + 1;
            }
        } else {
            pos = pos + 1;
        };
    };
    pos
};

// ── control flow ─────────────────────────────────────────────────────────

def parse_if(toks: [Tok], p: long) -> Parsed {
    let ln = tline(toks, p);
    let cl = tcol(toks, p);
    // `if let` is its own form, not an `if` whose condition starts with a
    // keyword: `let` is a whole word, so nothing else can reach here.
    if (is_kw(toks, p + 1, "let")) { return parse_if_let(toks, p) };
    let cond = parse_expr(toks, p + 1);
    let then_b = parse_block(toks, cond.pos);
    let pos = then_b.pos;
    let else_b: Node = { k: K.void, line: ln, col: cl };
    let has_else = false;
    // The optional else branch updates the AST bookkeeping.
    if (is_kw(toks, pos, "else")) {
        if (is_kw(toks, pos + 1, "if")) {
            let ei = parse_if(toks, pos + 1);
            else_b = ei.node;
            pos = ei.pos;
        } else {
            let eb = parse_block(toks, pos + 1);
            else_b = eb.node;
            pos = eb.pos;
        };
        has_else = true;
    };
    res({ k: K.kw_if, cond: cond.node, then: then_b.node, els: else_b, has_else: has_else, line: ln, col: cl }, pos)
};

// `if let PATTERN = EXPR { ... } else { ... }`: run the block when EXPR
// matches PATTERN, with the pattern's names bound, and the else when it does
// not. It is the two-arm match (see parse_match) with the else as the
// wildcard, so the pattern need not be exhaustive -- that is what the else
// is for -- and it lowers the same way:
//     { let $l = EXPR; if <test> { <binds>; ... } else { ... } }
// A missing else is an `if` with none: a statement, no value.
def parse_if_let(toks: [Tok], p: long) -> Parsed {
    let ln = tline(toks, p);
    let cl = tcol(toks, p);
    let tmp = "$l" + tostring(ln) + "_" + tostring(cl);
    let pr = parse_pattern(toks, p + 2, tmp);
    let pos = pr.pos;
    if (!is_op(toks, pos, "=")) {
        return res({ k: K.err, msg: "expected '=' after the pattern of 'if let', got '" + tv(toks, pos) + "'", line: tline(toks, pos), col: tcol(toks, pos) }, pos);
    };
    let subj = parse_expr(toks, pos + 1);
    let then_b = parse_block(toks, subj.pos);
    pos = then_b.pos;
    let else_b: Node = { k: K.void, line: ln, col: cl };
    let has_else = false;
    if (is_kw(toks, pos, "else")) {
        let eb = parse_block(toks, pos + 1);
        else_b = eb.node;
        pos = eb.pos;
        has_else = true;
    };
    let pb: [Node] = pr.binds;
    let ts: [Node] = [];
    ts += pb;
    ts += then_b.node;
    let stmts: [Node] = [];
    stmts += let_node(tmp, subj.node, ln, cl);
    stmts += { k: K.kw_if, cond: pr.test, then: { k: K.block, stmts: ts, line: ln, col: cl }, els: else_b, has_else: has_else, line: ln, col: cl };
    res({ k: K.block, stmts: stmts, line: ln, col: cl }, pos)
};

def parse_while(toks: [Tok], p: long) -> Parsed {
    let cond = parse_expr(toks, p + 1);
    let body = parse_block(toks, cond.pos);
    res({ k: K.kw_while, cond: cond.node, body: body.node, line: tline(toks, p), col: tcol(toks, p) }, body.pos)
};

def parse_foreach(toks: [Tok], p: long) -> Parsed {
    // foreach ( x in iterable ) { body }
    if (!is_punct(toks, p + 1, "(")) {
        return res(expect_err(toks, p + 1, "'(' after 'foreach'"), sync_stmt(toks, p + 1));
    };
    if (tt(toks, p + 2) != "id") {
        return res(expect_err(toks, p + 2, "a loop variable name"), sync_stmt(toks, p + 1));
    };
    if (!is_kw(toks, p + 3, "in")) {
        return res(expect_err(toks, p + 3, "'in'"), sync_stmt(toks, p + 1));
    };
    let name = tv(toks, p + 2);
    let it = parse_expr(toks, p + 4);  // skip 'foreach' '(' name 'in'
    if (!is_punct(toks, it.pos, ")")) {
        return res(expect_err(toks, it.pos, "')'"), sync_stmt(toks, p + 1));
    };
    let body = parse_block(toks, it.pos + 1);  // skip ')'
    res({ k: K.kw_foreach, name: name, iter: it.node, body: body.node, line: tline(toks, p), col: tcol(toks, p) }, body.pos)
};

def parse_for_or_range(toks: [Tok], p: long) -> Parsed {
    // for i in a..b { body }   OR   for (init; cond; step) { body }
    let ln = tline(toks, p);
    let cl = tcol(toks, p);
    if (is_kw(toks, p + 2, "in")) {
        if (tt(toks, p + 1) != "id") {
            return res(expect_err(toks, p + 1, "a loop variable name"), sync_stmt(toks, p + 1));
        };
        let name = tv(toks, p + 1);
        let lo = parse_expr(toks, p + 3);
        if (!is_op(toks, lo.pos, "..")) {
            return res(expect_err(toks, lo.pos, "'..'"), sync_stmt(toks, p + 1));
        };
        let hi = parse_expr(toks, lo.pos + 1);
        let body = parse_block(toks, hi.pos);
        res({ k: K.forrange, name: name, lo: lo.node, hi: hi.node, body: body.node, line: ln, col: cl }, body.pos)
    } else {
        // C-style for
        // The init and step clauses are optional; only present clauses
        // update their local parser state.
        if (!is_punct(toks, p + 1, "(")) {
            return res(expect_err(toks, p + 1, "'(' or a loop variable after 'for'"), sync_stmt(toks, p + 1));
        };
        let pos = p + 2;  // skip 'for' '('
        let init: Node = { k: K.void, line: tline(toks, pos), col: tcol(toks, pos) };
        if (!is_punct(toks, pos, ";")) {
            let ir = parse_stmt(toks, pos);
            init = ir.node;
            pos = ir.pos;
        };
        if (!is_punct(toks, pos, ";")) {
            return res(clause_err(toks, pos, init, "';'"), sync_stmt(toks, p + 1));
        };
        pos = pos + 1;  // ';'
        // No condition loops forever, as in C (a `return` leaves).
        let cond: Node = { k: K.bool, v: "true", line: tline(toks, pos), col: tcol(toks, pos) };
        if (!is_punct(toks, pos, ";")) {
            let cr = parse_expr(toks, pos);
            cond = cr.node;
            pos = cr.pos;
        };
        if (!is_punct(toks, pos, ";")) {
            return res(clause_err(toks, pos, cond, "';'"), sync_stmt(toks, p + 1));
        };
        pos = pos + 1;  // ';'
        let step: Node = { k: K.void, line: tline(toks, pos), col: tcol(toks, pos) };
        if (!is_punct(toks, pos, ")")) {
            let sr = parse_stmt(toks, pos);
            step = sr.node;
            pos = sr.pos;
        };
        if (!is_punct(toks, pos, ")")) {
            return res(clause_err(toks, pos, step, "')'"), sync_stmt(toks, p + 1));
        };
        pos = pos + 1;  // ')'
        let body = parse_block(toks, pos);
        res({ k: K.kw_for, init: init, cond: cond, step: step, body: body.node, line: ln, col: cl }, body.pos)
    }
};

// A for-header clause not followed by its separator: the clause's own
// error when it has one (that is the cause), else "expected SEP".
def clause_err(toks: [Tok], pos: long, clause: Node, sep: str) -> Node {
    if (clause.k == K.err) { clause }
    else {
        let e: Node = expect_err(toks, pos, sep);
        e
    }
};

// ── match ────────────────────────────────────────────────────────────────
// `match e { pattern => arm, ... }` is lowered right here to what it means:
//     { let $m = e; if (test1) { binds1; arm1 } else if ... else { last } }
// so the arms follow the `if` law: they agree on a type, or the match is
// void. Patterns:
//     _                     anything (the last arm; later arms never run)
//     T x | T {f, g: y} | T a member T (a record type) of the subject's
//                           union: bind it / some of its fields / nothing
//     {f: v, ...} x         a record whose fields f equal v (also written
//                           ({f: v, ...}) x); the binding is optional
//     1, "s", c'a', true, none, -2, (expr)   equal to that value
// Three node kinds carry what only the checker can decide: rectest (does
// the value have T's fields?), narrow (the value, typed as T), and
// matchend (the fall-through: unreachable when the arms cover every case,
// otherwise the match is rejected as non-exhaustive).

def parse_match_try(toks: [Tok], p: long) -> Parsed {
    // `match` is a keyword only when an expression and `{` follow it.
    let ln = tline(toks, p);
    let cl = tcol(toks, p);
    let nt = tt(toks, p + 1);
    let plain = { k: K.id, v: "match", line: ln, col: cl };
    if (nt == "op" || nt == "eof") {
        res(plain, p + 1)
    } else if (nt == "punct" && !is_punct(toks, p + 1, "(") && !is_punct(toks, p + 1, "[") && !is_punct(toks, p + 1, "{")) {
        res(plain, p + 1)
    } else {
        let subj = parse_expr(toks, p + 1);
        if (is_punct(toks, subj.pos, "{")) {
            parse_match(toks, subj.node, subj.pos, ln, cl)
        } else {
            res(plain, p + 1)
        }
    }
};

def parse_match(toks: [Tok], subj: Node, bpos: long, ln: long, cl: long) -> Parsed {
    let tmp = "$m" + tostring(ln) + "_" + tostring(cl);
    let tests: [Node] = [];
    let thens: [Node] = [];
    let covers: [Type] = [];
    let nvals = 0;
    let fallback: Node = { k: K.void, line: ln, col: cl };
    let has_wild = false;
    let pos = bpos + 1;
    let go = true;
    while (go) {
        if (is_punct(toks, pos, "}")) {
            go = false;
        } else if (tt(toks, pos) == "eof") {
            tests += { k: K.err, msg: "unclosed match (no '}' before end of input)", line: ln, col: cl };
            thens += block1({ k: K.void, line: ln, col: cl }, ln, cl);
            go = false;
        } else {
            let pr = parse_pattern(toks, pos, tmp);
            pos = pr.pos;
            let body: Node = { k: K.void, line: tline(toks, pos), col: tcol(toks, pos) };
            if (is_op(toks, pos, "=>")) {
                let br = parse_arm_body(toks, pos + 1);
                pos = br.pos;
                body = br.node;
            } else {
                body = { k: K.err, msg: "expected '=>' after a match pattern, got '" + tv(toks, pos) + "'", line: tline(toks, pos), col: tcol(toks, pos) };
                go = false;
            };
            if (has_wild) {
            } else if (pr.wild) {
                has_wild = true;
                fallback = body;
            } else {
                tests += pr.test;
                let pb: [Node] = pr.binds;
                let ts: [Node] = [];
                ts += pb;
                ts += body;
                thens += { k: K.block, stmts: ts, line: ln, col: cl };
                let pc = pr.cover;
                if (pc.k == K.tnone) { nvals = nvals + 1; } else { covers += pc; };
            };
            if (go) {
                if (is_punct(toks, pos, ",")) {
                    pos = pos + 1;
                } else if (is_punct(toks, pos, "}")) {
                } else {
                    tests += { k: K.err, msg: "expected ',' or '}' after a match arm, got '" + tv(toks, pos) + "'", line: tline(toks, pos), col: tcol(toks, pos) };
                    thens += block1({ k: K.void, line: ln, col: cl }, ln, cl);
                    go = false;
                };
            };
        };
    };
    let chain: Node = block1({ k: K.matchend, e: { k: K.id, v: tmp, line: ln, col: cl }, cover: covers, vals: nvals, line: ln, col: cl }, ln, cl);
    if (has_wild) {
        chain = block1(fallback, ln, cl);
    };
    let i = len(tests) - 1;
    while (i >= 0) {
        chain = { k: K.kw_if, cond: tests[i], then: thens[i], els: chain, has_else: true, line: ln, col: cl };
        i = i - 1;
    };
    let stmts: [Node] = [];
    stmts += { k: K.decl, kind: "let", name: tmp, typ: { k: K.tnone }, v: subj, line: ln, col: cl };
    stmts += chain;
    let endp = pos;
    if (is_punct(toks, pos, "}")) { endp = pos + 1; };
    res({ k: K.block, stmts: stmts, line: ln, col: cl }, endp)
};

// An arm is any expression; `{}` there is the empty block (void), not an
// empty record.
def parse_arm_body(toks: [Tok], p: long) -> Parsed {
    if (is_punct(toks, p, "{") && is_punct(toks, p + 1, "}")) {
        let none: [Node] = [];
        res({ k: K.block, stmts: none, line: tline(toks, p), col: tcol(toks, p) }, p + 2)
    } else {
        parse_expr(toks, p)
    }
};

def pat_res(test: Node, binds: [Node], cover: Type, wild: bool, pos: long) -> PatRes {
    { test: test, binds: binds, cover: cover, wild: wild, pos: pos }
};

def let_node(name: str, v: Node, ln: long, cl: long) -> Decl {
    { k: K.decl, kind: "let", name: name, typ: { k: K.tnone }, v: v, line: ln, col: cl }
};

def parse_pattern(toks: [Tok], p: long, tmp: str) -> PatRes {
    let ln = tline(toks, p);
    let cl = tcol(toks, p);
    let t = tt(toks, p);
    let v = tv(toks, p);
    let subj = { k: K.id, v: tmp, line: ln, col: cl };
    let nob: [Node] = [];
    if (t == "id" && v == "_") {
        pat_res({ k: K.void, line: ln, col: cl }, nob, { k: K.tnone }, true, p + 1)
    } else if (t == "id" && v == "some" && is_punct(toks, p + 1, "(")) {
        parse_some_pattern(toks, p, tmp)
    } else if (t == "id" && v != "none") {
        parse_type_pattern(toks, p, tmp)
    } else if (is_punct(toks, p, "{")) {
        let rm = parse_map(toks, p);
        parse_value_pattern(toks, rm.node, rm.pos, tmp, ln, cl)
    } else if (is_punct(toks, p, "(")) {
        let rp = parse_primary(toks, p);
        parse_value_pattern(toks, rp.node, rp.pos, tmp, ln, cl)
    } else {
        let ru = parse_unary(toks, p);
        pat_res({ k: K.bin, op: "==", l: subj, r: ru.node, line: ln, col: cl }, nob, { k: K.tnone }, false, ru.pos)
    }
};

// `some(x)`: an option that holds a value, the payload bound to x. The test
// is is_some and the binding unwraps -- the two halves of `x!` -- so a
// non-exhaustive pattern like this one needs no wildcard of its own in an
// `if let` (the else is it). `some()` matches any option and binds nothing.
def parse_some_pattern(toks: [Tok], p: long, tmp: str) -> PatRes {
    let ln = tline(toks, p);
    let cl = tcol(toks, p);
    let subj = { k: K.id, v: tmp, line: ln, col: cl };
    let cargs: [Node] = [];
    cargs += subj;
    let test: Node = { k: K.call, callee: { k: K.id, v: "is_some", line: ln, col: cl }, args: cargs, line: ln, col: cl };
    let binds: [Node] = [];
    let pos = p + 2;  // past `some` and `(`
    if (!is_punct(toks, pos, ")")) {
        if (tt(toks, pos) == "id") {
            let uargs: [Node] = [];
            uargs += subj;
            binds += let_node(tv(toks, pos), { k: K.call, callee: { k: K.id, v: "unwrap", line: ln, col: cl }, args: uargs, line: ln, col: cl }, ln, cl);
            pos = pos + 1;
        } else {
            binds += { k: K.err, msg: "expected a name to bind in 'some(', got '" + tv(toks, pos) + "'", line: tline(toks, pos), col: tcol(toks, pos) };
            pos = pos + 1;
        };
        if (is_punct(toks, pos, ",")) {
            // One payload fits: name it once and skip the rest of the list,
            // so the ')' below closes the pattern instead of reporting a
            // second error on the same mistake.
            binds += { k: K.err, msg: "'some' binds exactly one name", line: tline(toks, pos), col: tcol(toks, pos) };
            while (!is_punct(toks, pos, ")") && tt(toks, pos) != "eof") { pos = pos + 1; };
        };
    };
    if (is_punct(toks, pos, ")")) {
        pos = pos + 1;
    } else {
        binds += { k: K.err, msg: "expected ')' to close 'some(', got '" + tv(toks, pos) + "'", line: tline(toks, pos), col: tcol(toks, pos) };
    };
    pat_res(test, binds, { k: K.tnone }, false, pos)
};

// T / T x / T {f, g: y}: T names a record type (an alias; `m.T` one of
// module m's).
def parse_type_pattern(toks: [Tok], p: long, tmp: str) -> PatRes {
    let ln = tline(toks, p);
    let cl = tcol(toks, p);
    let tname = tv(toks, p);
    let pos = p + 1;
    if (is_op(toks, pos, ".") && tt(toks, pos + 1) == "id") {
        tname = tname + "." + tv(toks, pos + 1);
        pos = pos + 2;
    };
    let ty = { k: K.tname, name: tname };
    let subj = { k: K.id, v: tmp, line: ln, col: cl };
    let binds: [Node] = [];
    if (is_punct(toks, pos, "{")) {
        pos = pos + 1;
        let go = !is_punct(toks, pos, "}");
        while (go) {
            let fname = tv(toks, pos);
            let bname = fname;
            pos = pos + 1;
            if (is_punct(toks, pos, ":")) {
                bname = tv(toks, pos + 1);
                pos = pos + 2;
            };
            let fread: Node = { k: K.dot, obj: { k: K.narrow, e: subj, typ: ty, line: ln, col: cl }, key: fname, line: ln, col: cl };
            binds += let_node(bname, fread, ln, cl);
            if (is_punct(toks, pos, ",")) { pos = pos + 1; go = !is_punct(toks, pos, "}"); } else { go = false; };
        };
        if (is_punct(toks, pos, "}")) { pos = pos + 1; } else {
            binds += { k: K.err, msg: "expected '}' to close the field list, got '" + tv(toks, pos) + "'", line: tline(toks, pos), col: tcol(toks, pos) };
        };
    } else if (tt(toks, pos) == "id") {
        binds += let_node(tv(toks, pos), { k: K.narrow, e: subj, typ: ty, line: ln, col: cl }, ln, cl);
        pos = pos + 1;
    };
    pat_res({ k: K.rectest, e: subj, typ: ty, line: ln, col: cl }, binds, ty, false, pos)
};

// A parsed value pattern: a record literal matches by its fields, any
// other expression by equality. An identifier after it binds the subject.
def parse_value_pattern(toks: [Tok], node: Node, pos: long, tmp: str, ln: long, cl: long) -> PatRes {
    let subj = { k: K.id, v: tmp, line: ln, col: cl };
    let binds: [Node] = [];
    let k: long = node.k;
    if (k == K.rec) {
        let rec: RecLit = node;
        let keys: [str] = rec.keys;
        let vals: [Node] = rec.vals;
        let ty: Type = { k: K.tpat, names: keys };
        let test: Node = { k: K.rectest, e: subj, typ: ty, line: ln, col: cl };
        let i = 0;
        while (i < len(keys)) {
            let key = keys[i];
            if (key == "...") {
                test = { k: K.err, msg: "'...' is not allowed in a match pattern", line: ln, col: cl };
            } else {
                let fread: Node = { k: K.dot, obj: { k: K.narrow, e: subj, typ: ty, line: ln, col: cl }, key: key, line: ln, col: cl };
                test = { k: K.bin, op: "&&", l: test, r: { k: K.bin, op: "==", l: fread, r: vals[i], line: ln, col: cl }, line: ln, col: cl };
            };
            i = i + 1;
        };
        let np = pos;
        if (tt(toks, pos) == "id") {
            binds += let_node(tv(toks, pos), { k: K.narrow, e: subj, typ: ty, line: ln, col: cl }, ln, cl);
            np = pos + 1;
        };
        pat_res(test, binds, { k: K.tnone }, false, np)
    } else {
        let np = pos;
        if (tt(toks, pos) == "id") {
            binds += let_node(tv(toks, pos), subj, ln, cl);
            np = pos + 1;
        };
        pat_res({ k: K.bin, op: "==", l: subj, r: node, line: ln, col: cl }, binds, { k: K.tnone }, false, np)
    }
};

// ── top level: a program is a block of statements (no surrounding braces) ─

def parse_program(toks: [Tok]) -> Block {
    let stmts: [Node] = [];
    let pos = 0;
    while (tt(toks, pos) != "eof") {
        let before = pos;
        let s = parse_stmt(toks, pos);
        stmts += s.node;
        pos = stmt_end(toks, before, s.pos, s.node, stmts);
        // safety: if a statement made no progress, bail to avoid infinite loop
        // NOTE: `0;` tail — the while body must be void-typed (see the
        // parse_block note).
        if (pos == before) {
            pos = pos + 1;
        };
    };
    { k: K.block, stmts: stmts, line: 1, col: 1 }
};

export { parse_program, parse_type_full, nameix_new, nameix_put, nameix_get };

// ── a name index (types.y lookup, lint.y) ─────────────────────────────────
// str -> long, the last put of a name wins: open addressing over a power
// of two, doubled at half full ("" is no key: it marks a free slot).
type NameIx = { keys: [str], vals: [long], n: long };

def nameix_new(cap: long) -> NameIx {
    let keys: [str] = [];
    let vals: [long] = [];
    let i = 0;
    while (i < cap) {
        keys += "";
        vals += 0;
        i = i + 1;
    };
    { keys: keys, vals: vals, n: 0 }
};

// The slot of k in keys: where it is, or the free one it would take.
def nameix_slot(keys: [str], k: str) -> long {
    let mask = len(keys) - 1;
    let h = 0;
    let i = 0;
    while (i < len(k)) {
        h = (h * 31 + byte_at(k, i)) & 1073741823;
        i = i + 1;
    };
    let s = (h ^ (h >> 15)) & mask;
    let go = true;
    while (go) {
        let e: str = keys[s];
        if (e == "" || e == k) { go = false; } else { s = (s + 1) & mask; };
    };
    s
};

def nameix_put(m: NameIx, k: str, v: long) -> void {
    if ((m.n + 1) * 2 > len(m.keys)) {
        let ok = m.keys;
        let ov = m.vals;
        let big = nameix_new(len(ok) * 2);
        let bk = big.keys;
        let bv = big.vals;
        let i = 0;
        while (i < len(ok)) {
            let e: str = ok[i];
            if (e != "") {
                let s = nameix_slot(bk, e);
                bk[s] = e;
                bv[s] = ov[i];
            };
            i = i + 1;
        };
        m.keys = bk;
        m.vals = bv;
    };
    let keys = m.keys;
    let vals = m.vals;
    let s = nameix_slot(keys, k);
    let e: str = keys[s];
    if (e == "") { m.n = m.n + 1; };
    keys[s] = k;
    vals[s] = v;
};

// The value put last for k, or -1.
def nameix_get(m: NameIx, k: str) -> long {
    let keys = m.keys;
    let s = nameix_slot(keys, k);
    let e: str = keys[s];
    if (e == "") { -1 } else { let vals = m.vals; vals[s] }
};
