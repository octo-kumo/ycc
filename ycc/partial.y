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
export { parse_primary };
