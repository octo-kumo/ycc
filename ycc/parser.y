// parser.y — parse a token list into an AST of nested maps.
// Each parse function returns { node: <ast>, pos: <int> }.
// AST node kinds: num, str, id, bool, null, bin, un, call, index, slice,
//   dot, assign, idxassign, decl, func, if, while, for, foreach, forrange,
//   block, array, map, ret.

// ── token helpers ────────────────────────────────────────────────────────

def tt(toks: [{ t: str, v: str }], p: long) -> str { toks[p].t };
def tv(toks: [{ t: str, v: str }], p: long) -> str { toks[p].v };

def is_kw(toks: [{ t: str, v: str }], p: long, w: str) -> bool {
    toks[p].t == "kw" && toks[p].v == w
};
def is_punct(toks: [{ t: str, v: str }], p: long, w: str) -> bool {
    toks[p].t == "punct" && toks[p].v == w
};
def is_op(toks: [{ t: str, v: str }], p: long, w: str) -> bool {
    toks[p].t == "op" && toks[p].v == w
};

def res(node: {k: str}, p: long) -> { node: {k: str}, pos: long } {
    { node: node, pos: p }
};

// ── operator precedence ──────────────────────────────────────────────────

def op_prec(op: str) -> long {
    if (op == "||") { 1 }
    else if (op == "&&") { 2 }
    else if (op == "==" || op == "!=") { 3 }
    else if (op == "<" || op == ">" || op == "<=" || op == ">=") { 4 }
    else if (op == "::") { 5 }
    else if (op == "+" || op == "-") { 6 }
    else if (op == "*" || op == "/" || op == "%") { 7 }
    else { 0 }
};

// ── primary expressions ──────────────────────────────────────────────────

def parse_primary(toks: [{ t: str, v: str }], p: long) -> { node: {k: str}, pos: long } {
    let t = tt(toks, p);
    let v = tv(toks, p);
    if (t == "num") {
        res({ k: "num", v: v }, p + 1)
    } else if (t == "str") {
        res({ k: "str", v: v }, p + 1)
    } else if (t == "id") {
        res({ k: "id", v: v }, p + 1)
    } else if (is_kw(toks, p, "true")) {
        res({ k: "bool", v: "true" }, p + 1)
    } else if (is_kw(toks, p, "false")) {
        res({ k: "bool", v: "false" }, p + 1)
    } else if (is_kw(toks, p, "null")) {
        res({ k: "null" }, p + 1)
    } else if (is_punct(toks, p, "(")) {
        let inner = parse_expr(toks, p + 1);
        res(inner.node, inner.pos + 1)  // skip ')'
    } else if (is_punct(toks, p, "[")) {
        parse_array(toks, p + 1)
    } else if (is_punct(toks, p, "{")) {
        parse_map(toks, p + 1)
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
        res({ k: "null" }, p + 1)
    }
};

// ── postfix: call, index, slice, dot ─────────────────────────────────────

def parse_postfix(toks: [{ t: str, v: str }], p: long) -> { node: {k: str}, pos: long } {
    let base = parse_primary(toks, p);
    let node = base.node;
    let pos = base.pos;
    let go = true;
    while (go) {
        if (is_punct(toks, pos, "(")) {
            let a = parse_args(toks, pos + 1);
            node = { k: "call", callee: node, args: a.node };
            pos = a.pos + 1;  // skip ')'
        } else if (is_punct(toks, pos, "[")) {
            // index or slice
            let first = parse_expr(toks, pos + 1);
            if (is_op(toks, first.pos, ":")) {
                let second = parse_expr(toks, first.pos + 1);
                node = { k: "slice", arr: node, lo: first.node, hi: second.node };
                pos = second.pos + 1;  // skip ']'
            } else {
                node = { k: "index", arr: node, idx: first.node };
                pos = first.pos + 1;  // skip ']'
            };
        } else if (is_op(toks, pos, ".")) {
            let name = tv(toks, pos + 1);
            node = { k: "dot", obj: node, key: name };
            pos = pos + 2;
        } else {
            go = false;
        };
    };
    res(node, pos)
};

def parse_args(toks: [{ t: str, v: str }], p: long) -> { node: [{k: str}], pos: long } {
    let args = [];
    let pos = p;
    if (is_punct(toks, pos, ")")) {
        { node: args, pos: pos }
    } else {
        let go = true;
        while (go) {
            let e = parse_expr(toks, pos);
            args = push(args, e.node);
            pos = e.pos;
            if (is_punct(toks, pos, ",")) {
                pos = pos + 1;
            } else {
                go = false;
            };
        };
        { node: args, pos: pos }
    }
};

// ── binary expressions (precedence climbing) ─────────────────────────────

def parse_binary(toks: [{ t: str, v: str }], p: long, min_prec: long) -> { node: {k: str}, pos: long } {
    let left_r = parse_unary(toks, p);
    let left = left_r.node;
    let pos = left_r.pos;
    let go = true;
    while (go) {
        let op = tv(toks, pos);
        let prec = 0;
        if (tt(toks, pos) == "op") { prec = op_prec(op); };
        if (prec == 0 || prec < min_prec) {
            go = false;
        } else {
            let right_r = parse_binary(toks, pos + 1, prec + 1);
            left = { k: "bin", op: op, l: left, r: right_r.node };
            pos = right_r.pos;
        };
    };
    res(left, pos)
};

def parse_unary(toks: [{ t: str, v: str }], p: long) -> { node: {k: str}, pos: long } {
    if (is_op(toks, p, "-") || is_op(toks, p, "!")) {
        let inner = parse_unary(toks, p + 1);
        res({ k: "un", op: tv(toks, p), e: inner.node }, inner.pos)
    } else {
        parse_postfix(toks, p)
    }
};

def parse_expr(toks: [{ t: str, v: str }], p: long) -> { node: {k: str}, pos: long } {
    parse_binary(toks, p, 1)
};

// ── compound literals ────────────────────────────────────────────────────

def parse_array(toks: [{ t: str, v: str }], p: long) -> { node: {k: str}, pos: long } {
    let elems = [];
    let pos = p;
    if (is_punct(toks, pos, "]")) {
        res({ k: "array", elems: elems }, pos + 1)
    } else {
        let go = true;
        while (go) {
            let e = parse_expr(toks, pos);
            elems = push(elems, e.node);
            pos = e.pos;
            if (is_punct(toks, pos, ",")) { pos = pos + 1; } else { go = false; };
        };
        res({ k: "array", elems: elems }, pos + 1)  // skip ']'
    }
};

def parse_map(toks: [{ t: str, v: str }], p: long) -> { node: {k: str}, pos: long } {
    let keys = [];
    let vals = [];
    let pos = p;
    if (is_punct(toks, pos, "}")) {
        res({ k: "map", keys: keys, vals: vals }, pos + 1)
    } else {
        let go = true;
        while (go) {
            let key = tv(toks, pos);
            pos = pos + 2;  // skip key and ':'
            let e = parse_expr(toks, pos);
            keys = push(keys, key);
            vals = push(vals, e.node);
            pos = e.pos;
            if (is_punct(toks, pos, ",")) { pos = pos + 1; } else { go = false; };
        };
        res({ k: "map", keys: keys, vals: vals }, pos + 1)  // skip '}'
    }
};

// ── function literal ─────────────────────────────────────────────────────

def parse_func(toks: [{ t: str, v: str }], p: long) -> { node: {k: str}, pos: long } {
    // Named:    def name(params) -> ret { body }   (top-level declaration)
    // Anonymous: def(params) -> ret { body }        (function expression)
    let pos = p + 1;  // skip 'def'
    let fname = "";
    // optional function name (present unless next token is '(')
    if (!is_punct(toks, pos, "(")) {
        fname = tv(toks, pos);
        pos = pos + 1;
    };
    pos = pos + 1;  // skip '('
    let names = [];
    if (!is_punct(toks, pos, ")")) {
        let go = true;
        while (go) {
            let nm = tv(toks, pos);
            names = push(names, nm);
            pos = pos + 1;  // name
            if (is_punct(toks, pos, ":")) {
                pos = pos + 2;  // skip ':' and type
            };
            if (is_punct(toks, pos, ",")) { pos = pos + 1; } else { go = false; };
        };
    };
    pos = pos + 1;  // skip ')'
    // optional return type '-> type'
    if (is_op(toks, pos, "->")) { pos = pos + 2; };
    let body = parse_block(toks, pos);
    let func = { k: "func", params: names, body: body.node };
    if (fname == "") {
        res(func, body.pos)
    } else {
        res({ k: "decl", kind: "def", name: fname, v: func }, body.pos)
    }
};

// ── block { stmt; stmt; ... } ────────────────────────────────────────────

def parse_block(toks: [{ t: str, v: str }], p: long) -> { node: {k: str}, pos: long } {
    let pos = p + 1;  // skip '{'
    let stmts = [];
    while (!is_punct(toks, pos, "}") && tt(toks, pos) != "eof") {
        let s = parse_stmt(toks, pos);
        stmts = push(stmts, s.node);
        pos = s.pos;
        if (is_punct(toks, pos, ";")) { pos = pos + 1; };
    };
    res({ k: "block", stmts: stmts }, pos + 1)  // skip '}'
};

// ── statements ───────────────────────────────────────────────────────────

def parse_stmt(toks: [{ t: str, v: str }], p: long) -> { node: {k: str}, pos: long } {
    if (is_kw(toks, p, "let") || is_kw(toks, p, "const")) {
        parse_decl(toks, p)
    } else if (is_kw(toks, p, "return")) {
        let e = parse_expr(toks, p + 1);
        res({ k: "ret", e: e.node }, e.pos)
    } else {
        // expression, possibly an assignment: id = expr  or  arr[i] = expr
        let e = parse_expr(toks, p);
        if (is_op(toks, e.pos, "=")) {
            let rhs = parse_expr(toks, e.pos + 1);
            let target = e.node;
            if (target.k == "index") {
                res({ k: "idxassign", arr: target.arr, idx: target.idx, v: rhs.node }, rhs.pos)
            } else {
                res({ k: "assign", name: target.v, v: rhs.node }, rhs.pos)
            }
        } else {
            e
        }
    }
};

def parse_decl(toks: [{ t: str, v: str }], p: long) -> { node: {k: str}, pos: long } {
    let kind = tv(toks, p);
    let name = tv(toks, p + 1);
    let pos = p + 2;
    // optional ': type'
    if (is_punct(toks, pos, ":")) { pos = pos + 2; };
    // '='
    pos = pos + 1;
    let e = parse_expr(toks, pos);
    res({ k: "decl", kind: kind, name: name, v: e.node }, e.pos)
};

// ── control flow ─────────────────────────────────────────────────────────

def parse_if(toks: [{ t: str, v: str }], p: long) -> { node: {k: str}, pos: long } {
    let cond = parse_expr(toks, p + 1);
    let then_b = parse_block(toks, cond.pos);
    let pos = then_b.pos;
    let else_b = { k: "null" };
    let has_else = false;
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
    res({ k: "if", cond: cond.node, then: then_b.node, els: else_b, has_else: has_else }, pos)
};

def parse_while(toks: [{ t: str, v: str }], p: long) -> { node: {k: str}, pos: long } {
    let cond = parse_expr(toks, p + 1);
    let body = parse_block(toks, cond.pos);
    res({ k: "while", cond: cond.node, body: body.node }, body.pos)
};

def parse_foreach(toks: [{ t: str, v: str }], p: long) -> { node: {k: str}, pos: long } {
    // foreach ( x in iterable ) { body }
    let name = tv(toks, p + 2);
    let it = parse_expr(toks, p + 4);  // skip 'foreach' '(' name 'in'
    let body = parse_block(toks, it.pos + 1);  // skip ')'
    res({ k: "foreach", name: name, iter: it.node, body: body.node }, body.pos)
};

def parse_for_or_range(toks: [{ t: str, v: str }], p: long) -> { node: {k: str}, pos: long } {
    // for i in a..b { body }   OR   for (init; cond; step) { body }
    if (is_kw(toks, p + 2, "in")) {
        let name = tv(toks, p + 1);
        let lo = parse_expr(toks, p + 3);
        // '..'
        let hi = parse_expr(toks, lo.pos + 1);
        let body = parse_block(toks, hi.pos);
        res({ k: "forrange", name: name, lo: lo.node, hi: hi.node, body: body.node }, body.pos)
    } else {
        // C-style for
        let pos = p + 2;  // skip 'for' '('
        let init = { k: "null" };
        if (!is_punct(toks, pos, ";")) {
            let ir = parse_stmt(toks, pos);
            init = ir.node;
            pos = ir.pos;
        };
        pos = pos + 1;  // ';'
        let cond = parse_expr(toks, pos);
        pos = cond.pos + 1;  // ';'
        let step = { k: "null" };
        if (!is_punct(toks, pos, ")")) {
            let sr = parse_stmt(toks, pos);
            step = sr.node;
            pos = sr.pos;
        };
        pos = pos + 1;  // ')'
        let body = parse_block(toks, pos);
        res({ k: "for", init: init, cond: cond.node, step: step, body: body.node }, body.pos)
    }
};

// ── top level: a program is a block of statements (no surrounding braces) ─

def parse_program(toks: [{ t: str, v: str }]) -> {k: str} {
    let stmts = [];
    let pos = 0;
    while (tt(toks, pos) != "eof") {
        let before = pos;
        let s = parse_stmt(toks, pos);
        stmts = push(stmts, s.node);
        pos = s.pos;
        if (is_punct(toks, pos, ";")) { pos = pos + 1; };
        // safety: if a statement made no progress, bail to avoid infinite loop
        if (pos == before) { pos = pos + 1; };
    };
    { k: "block", stmts: stmts }
};

export { parse_program };
