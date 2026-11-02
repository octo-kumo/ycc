// dump.y — human-readable views of the compiler's intermediate stages.
//
// The compiler's real representations are compact on purpose: tokens carry
// numeric tags, AST nodes are one generated union, types are shared records,
// and the machine IR is a flat [long] with eight words per instruction. A
// reader (and a failing test) needs the same data spelled out, without
// changing any of those representations. This module is only that view.
//
// The entry points are called by the driver (ycc.y) and by native.y:
//
//   dump_tokens  source -> [Tok]
//   dump_ast     [Tok] -> AST
//   dump_types   renamed AST + checker bindings
//   dump_ir      emitted (and optionally optimized) machine IR
//
// Nothing here is on the compile path: a --dump run exits after printing.

import tags from "./tags.y";
import node_schema from "./ast_nodes.y";
import type_schema from "./type_nodes.y";
import types from "./types.y";
import insn from "./ir.y";
import optim from "./optimize.y";

// ── small text helpers ───────────────────────────────────────────────────

// A string as a Y literal: quotes and the escapes a reader can mistake for
// source text made visible. The lexer's tokens are already decoded, so the
// bytes are what the parser saw.
def dump_quote(s: str) -> str {
    let out = "\"";
    for i in 0..len(s) {
        let c = s[i];
        if (c == '\\') {
            out += "\\\\";
        } else if (c == '\"') {
            out += "\\\"";
        } else if (c == '\n') {
            out += "\\n";
        } else if (c == '\r') {
            out += "\\r";
        } else if (c == '\t') {
            out += "\\t";
        } else if (c < 32) {
            out += "\\x" + dump_hexbyte(c);
        } else {
            out += chr(c);
        };
    };
    out + "\""
};

def dump_hexbyte(c: long) -> str {
    let digits = "0123456789abcdef";
    "" + digits[(c >> 4) & 15] + digits[c & 15]
};

def dump_spaces(n: long) -> str {
    let out = "";
    for i in 0..n { out += " "; };
    out
};

def dump_pad_right(s: str, n: long) -> str {
    if (len(s) >= n) { s } else { s + dump_spaces(n - len(s)) }
};

def dump_at(n: Node) -> str {
    "@" + tostring(n.line) + ":" + tostring(n.col)
};

// ── tokens ───────────────────────────────────────────────────────────────

def dump_token_kind(t: long) -> str {
    if (t == K.kw) { "kw" }
    else if (t == K.id) { "id" }
    else if (t == K.num) { "num" }
    else if (t == K.str) { "str" }
    else if (t == K.bstr) { "bstr" }
    else if (t == K.char) { "char" }
    else if (t == K.bigint) { "bigint" }
    else if (t == K.punct) { "punct" }
    else if (t == K.op) { "op" }
    else if (t == K.eof) { "eof" }
    else if (t == K.ferr) { "error" }
    else { ktag(t) }
};

// The token stream the parser receives. Comments are already gone (the
// parser does not see them), f-strings have become their pieces, and a
// malformed literal is a `ferr` token carrying the diagnostic.
def dump_tokens(toks: [Tok]) -> void {
    puts("# stage: tokens (after meta expansion and import splicing)\n");
    puts("# line:col  kind    value\n");
    toks.foreach((t) => {
        let val = if (t.t == K.eof) { "<eof>" } else { dump_quote(t.v) };
        puts(tostring(t.line) + ":" + tostring(t.col) + "  " +
            dump_pad_right(dump_token_kind(t.t), 7) + " " + val + "\n");
    });
};

// ── AST ──────────────────────────────────────────────────────────────────

def dump_type_name(t: Type) -> str {
    if (t.k == K.tnone) { "" }
    else if (t.k == K.tunk) { "?" }
    else { types.tstr(t) }
};

// A function's header, with parameter names and their types together: the
// two arrays are parallel in a Func, and a dump reader should not have to
// pair them by hand.
def dump_func_header(f: Func) -> str {
    let ps: [str] = [];
    for i in 0..len(f.params) {
        let ty = "?";
        if (i < len(f.ptypes)) { ty = dump_type_name(f.ptypes[i]); };
        ps += f.params[i] + ": " + ty;
    };
    let ret = dump_type_name(f.ret);
    let tail = "";
    if (ret != "") { tail = " -> " + ret; };
    "(" + join(ps, ", ") + ")" + tail
};

def dump_node_head(n: Node) -> str {
    let k = n.k;
    if (k == K.block) {
        let b: Block = n;
        "Block " + tostring(len(b.stmts)) + " statement(s) " + dump_at(n)
    } else if (k == K.id) {
        let l: Leaf = n;
        "Identifier " + dump_quote(l.v) + " " + dump_at(n)
    } else if (k == K.num) {
        let l: Leaf = n;
        "Number " + dump_quote(l.v) + " " + dump_at(n)
    } else if (k == K.char) {
        let l: Leaf = n;
        "Byte literal " + dump_quote(l.v) + " " + dump_at(n)
    } else if (k == K.str) {
        let l: Leaf = n;
        "String " + dump_quote(l.v) + " " + dump_at(n)
    } else if (k == K.bstr) {
        let l: Leaf = n;
        "Byte string " + dump_quote(l.v) + " " + dump_at(n)
    } else if (k == K.bignum) {
        let l: Leaf = n;
        "Big integer " + dump_quote(l.v) + " " + dump_at(n)
    } else if (k == K.bool) {
        let l: Leaf = n;
        "Boolean " + l.v + " " + dump_at(n)
    } else if (k == K.void) {
        "Void " + dump_at(n)
    } else if (k == K.kw_break || k == K.kw_continue) {
        let l: Leaf = n;
        let what = if (k == K.kw_break) { "Break" } else { "Continue" };
        let labelled = if (l.v == "") { what + " " + dump_at(n) } else { what + " " + dump_quote(l.v) + " " + dump_at(n) };
        labelled
    } else if (k == K.addr) {
        "Address-of " + dump_at(n)
    } else if (k == K.deref) {
        "Dereference " + dump_at(n)
    } else if (k == K.ret) {
        "Return " + dump_at(n)
    } else if (k == K.un) {
        let u: Un = n;
        "Unary " + dump_quote(u.op) + " " + dump_at(n)
    } else if (k == K.bin) {
        let b: Bin = n;
        "Binary " + dump_quote(b.op) + " " + dump_at(n)
    } else if (k == K.array) {
        let a: ArrLit = n;
        "Array literal " + tostring(len(a.elems)) + " element(s) " + dump_at(n)
    } else if (k == K.arrrep) {
        let a: ArrRep = n;
        "Array repeat [" + dump_at(n) + "; " + tostring(a.n) + "]"
    } else if (k == K.assign) {
        let a: Assign = n;
        "Assign " + dump_quote(a.name) + " " + dump_at(n)
    } else if (k == K.call) {
        "Call " + dump_at(n)
    } else if (k == K.decl) {
        let d: Decl = n;
        let ty = dump_type_name(d.typ);
        let tail = if (ty == "") { "" } else { ": " + ty };
        "Decl " + d.kind + " " + dump_quote(d.name) + tail + " " + dump_at(n)
    } else if (k == K.dot) {
        let d: Dot = n;
        "Field " + dump_quote(d.key) + " " + dump_at(n)
    } else if (k == K.dotassign) {
        let d: DotAssign = n;
        "Assign field " + dump_quote(d.key) + " " + dump_at(n)
    } else if (k == K.err) {
        let e: Err = n;
        "Error " + dump_quote(e.msg) + " " + dump_at(n)
    } else if (k == K.kw_for) {
        "For " + dump_at(n)
    } else if (k == K.kw_foreach) {
        let f: Foreach = n;
        "Foreach " + dump_quote(f.name) + " " + dump_at(n)
    } else if (k == K.forrange) {
        let f: ForRange = n;
        "For range " + dump_quote(f.name) + " " + dump_at(n)
    } else if (k == K.func) {
        let f: Func = n;
        "Func " + dump_func_header(f) + " " + dump_at(n)
    } else if (k == K.idxassign) {
        "Assign index " + dump_at(n)
    } else if (k == K.kw_if) {
        let b: If = n;
        let tail = if (b.has_else) { " (with else)" } else { "" };
        "If" + tail + " " + dump_at(n)
    } else if (k == K.incdec) {
        let d: IncDec = n;
        let pre = if (d.pre) { "prefix" } else { "postfix" };
        "IncDec " + d.op + " (" + pre + ") " + dump_at(n)
    } else if (k == K.index) {
        "Index " + dump_at(n)
    } else if (k == K.map) {
        let r: RecLit = n;
        "Map literal " + tostring(len(r.keys)) + " entr(ies) " + dump_at(n)
    } else if (k == K.rec) {
        let r: RecLit = n;
        "Record literal " + tostring(len(r.keys)) + " field(s) " + dump_at(n)
    } else if (k == K.matchend) {
        let m: MatchEnd = n;
        "Match end " + tostring(m.vals) + " value arm(s) " + dump_at(n)
    } else if (k == K.narrow) {
        let nw: Narrow = n;
        "Narrow to " + dump_type_name(nw.typ) + " " + dump_at(n)
    } else if (k == K.rectest) {
        let nw: Narrow = n;
        "Union test for " + dump_type_name(nw.typ) + " " + dump_at(n)
    } else if (k == K.opassign) {
        let a: OpAssign = n;
        "Op-assign " + dump_quote(a.op) + " " + dump_at(n)
    } else if (k == K.slice) {
        "Slice " + dump_at(n)
    } else if (k == K.sliceassign) {
        "Assign slice " + dump_at(n)
    } else if (k == K.store) {
        "Store " + dump_at(n)
    } else if (k == K.typedef) {
        let t: TypeDef = n;
        "Type " + dump_quote(t.name) + " = " + dump_type_name(t.typ) + " " + dump_at(n)
    } else if (k == K.kw_while) {
        "While " + dump_at(n)
    } else if (k == K.optarg) {
        "Optional argument " + dump_at(n)
    } else {
        ktag(k) + " " + dump_at(n)
    }
};

def dump_line(out: [str], pre: str, last: bool, text: str) -> void {
    out += pre + (last ? "└─ " : "├─ ") + text;
};

// One node, with its children indented below it. `role` labels the edge
// (`cond: `, `callee: `); the root passes "". The tree characters are UTF-8
// on purpose: the output is for people, not for `diff` (tokens and IR stay
// plain ASCII so tests can pin them).
def dump_node(n: Node, pre: str, last: bool, role: str, out: [str]) -> void {
    dump_line(out, pre, last, role + dump_node_head(n));
    let cp = pre + (last ? "   " : "│  ");
    let k = n.k;
    if (k == K.block) {
        let b: Block = n;
        let xs = b.stmts;
        for i in 0..len(xs) {
            dump_node(xs[i], cp, i == len(xs) - 1, "", out);
        };
    } else if (k == K.addr || k == K.deref || k == K.ret) {
        let w: Wrap = n;
        dump_node(w.e, cp, true, "e: ", out);
    } else if (k == K.un) {
        let u: Un = n;
        dump_node(u.e, cp, true, "e: ", out);
    } else if (k == K.bin) {
        let b: Bin = n;
        dump_node(b.l, cp, false, "left: ", out);
        dump_node(b.r, cp, true, "right: ", out);
    } else if (k == K.array) {
        let a: ArrLit = n;
        for i in 0..len(a.elems) {
            dump_node(a.elems[i], cp, i == len(a.elems) - 1, "elem " + tostring(i) + ": ", out);
        };
    } else if (k == K.arrrep) {
        let a: ArrRep = n;
        dump_node(a.v, cp, false, "value: ", out);
        dump_line(out, cp, true, "count: " + tostring(a.n));
    } else if (k == K.assign) {
        let a: Assign = n;
        dump_node(a.v, cp, true, "value: ", out);
    } else if (k == K.call) {
        let c: Call = n;
        dump_node(c.callee, cp, len(c.args) == 0, "callee: ", out);
        for i in 0..len(c.args) {
            dump_node(c.args[i], cp, i == len(c.args) - 1, "arg " + tostring(i) + ": ", out);
        };
    } else if (k == K.decl) {
        let d: Decl = n;
        let has_type = d.typ.k != K.tnone;
        if (has_type) { dump_line(out, cp, false, "type: " + dump_type_name(d.typ)); };
        dump_node(d.v, cp, true, "value: ", out);
    } else if (k == K.dot) {
        let d: Dot = n;
        dump_node(d.obj, cp, true, "object: ", out);
    } else if (k == K.dotassign) {
        let d: DotAssign = n;
        dump_node(d.obj, cp, false, "object: ", out);
        dump_node(d.v, cp, true, "value: ", out);
    } else if (k == K.kw_for) {
        let f: For = n;
        if (f.init.k != K.void) { dump_node(f.init, cp, false, "init: ", out); };
        if (f.cond.k != K.void) { dump_node(f.cond, cp, false, "cond: ", out); };
        if (f.step.k != K.void) { dump_node(f.step, cp, false, "step: ", out); };
        dump_node(f.body, cp, true, "body: ", out);
    } else if (k == K.kw_foreach) {
        let f: Foreach = n;
        dump_node(f.iter, cp, false, "iter: ", out);
        dump_node(f.body, cp, true, "body: ", out);
    } else if (k == K.forrange) {
        let f: ForRange = n;
        dump_node(f.lo, cp, false, "lo: ", out);
        dump_node(f.hi, cp, false, "hi: ", out);
        dump_node(f.body, cp, true, "body: ", out);
    } else if (k == K.func) {
        let f: Func = n;
        // defs is parallel to params: each entry is that parameter's default
        // value, or a void/optional marker (parser.y's parse_func). Nested
        // defs are ordinary Decl statements in the body, not entries here.
        let ndefaults = 0;
        for i in 0..len(f.defs) {
            if (f.defs[i].k != K.void && f.defs[i].k != K.optarg) { ndefaults++; };
        };
        let nkids = len(f.params) + 1 + ndefaults;
        let dump_at = 0;
        for i in 0..len(f.params) {
            let ty = "?";
            if (i < len(f.ptypes)) { ty = dump_type_name(f.ptypes[i]); };
            dump_line(out, cp, dump_at + 1 == nkids, "param " + f.params[i] + ": " + ty);
            dump_at++;
        };
        dump_node(f.body, cp, dump_at + 1 == nkids, "body: ", out);
        dump_at++;
        for i in 0..len(f.defs) {
            let dv = f.defs[i];
            if (dv.k != K.void && dv.k != K.optarg) {
                let pn = if (i < len(f.params)) { f.params[i] } else { tostring(i) };
                dump_node(dv, cp, dump_at + 1 == nkids, "default " + pn + ": ", out);
                dump_at++;
            };
        };
    } else if (k == K.idxassign) {
        let a: IdxAssign = n;
        dump_node(a.arr, cp, false, "array: ", out);
        dump_node(a.idx, cp, false, "index: ", out);
        dump_node(a.v, cp, true, "value: ", out);
    } else if (k == K.kw_if) {
        let b: If = n;
        dump_node(b.cond, cp, false, "cond: ", out);
        dump_node(b.then, cp, !b.has_else, "then: ", out);
        if (b.has_else) { dump_node(b.els, cp, true, "else: ", out); };
    } else if (k == K.incdec) {
        let d: IncDec = n;
        dump_node(d.tgt, cp, true, "target: ", out);
    } else if (k == K.index) {
        let x: Index = n;
        dump_node(x.arr, cp, false, "array: ", out);
        dump_node(x.idx, cp, true, "index: ", out);
    } else if (k == K.map || k == K.rec) {
        let r: RecLit = n;
        for i in 0..len(r.keys) {
            dump_node(r.vals[i], cp, i == len(r.keys) - 1, dump_quote(r.keys[i]) + ": ", out);
        };
    } else if (k == K.matchend) {
        let m: MatchEnd = n;
        dump_node(m.e, cp, len(m.cover) == 0, "subject: ", out);
        for i in 0..len(m.cover) {
            dump_line(out, cp, i == len(m.cover) - 1, "covers: " + dump_type_name(m.cover[i]));
        };
    } else if (k == K.narrow || k == K.rectest) {
        let nw: Narrow = n;
        dump_node(nw.e, cp, true, "subject: ", out);
    } else if (k == K.opassign) {
        let a: OpAssign = n;
        dump_node(a.tgt, cp, false, "target: ", out);
        dump_node(a.v, cp, true, "value: ", out);
    } else if (k == K.slice) {
        let s: Slice = n;
        let has_hi = s.hi.k != K.void;
        let has_lo = s.lo.k != K.void;
        dump_node(s.arr, cp, !has_lo && !has_hi, "array: ", out);
        if (has_lo) { dump_node(s.lo, cp, !has_hi, "lo: ", out); };
        if (has_hi) { dump_node(s.hi, cp, true, "hi: ", out); };
    } else if (k == K.sliceassign) {
        let s: SliceAssign = n;
        dump_node(s.arr, cp, false, "array: ", out);
        if (s.lo.k != K.void) { dump_node(s.lo, cp, false, "lo: ", out); };
        if (s.hi.k != K.void) { dump_node(s.hi, cp, false, "hi: ", out); };
        dump_node(s.v, cp, true, "value: ", out);
    } else if (k == K.store) {
        let s: Store = n;
        dump_node(s.p, cp, false, "pointer: ", out);
        dump_node(s.v, cp, true, "value: ", out);
    } else if (k == K.typedef) {
        // the type was printed in the node's own line
    } else if (k == K.kw_while) {
        let w: While = n;
        dump_node(w.cond, cp, false, "cond: ", out);
        dump_node(w.body, cp, true, "body: ", out);
    };
};

def dump_ast_go(ast: Block, renamed: bool) -> void {
    if (renamed) {
        puts("# stage: renamed AST (after strip_ns and rename.rename_program_x)\n");
        puts("# positions are line:col in the spliced source; every binding has a unique $N name\n");
    } else {
        puts("# stage: AST (after meta expansion, import splicing and parsing)\n");
        puts("# positions are line:col in the spliced source; names are source names\n");
    };
    let out: [str] = [];
    out += "Block " + tostring(len(ast.stmts)) + " statement(s)";
    let pre = "";
    for i in 0..len(ast.stmts) {
        dump_node(ast.stmts[i], pre, i == len(ast.stmts) - 1, "", out);
    };
    puts(join(out, "\n") + "\n");
};

def dump_ast(ast: Block) -> void {
    dump_ast_go(ast, false)
};

def dump_renamed(ast: Block) -> void {
    dump_ast_go(ast, true)
};

// ── types ────────────────────────────────────────────────────────────────

// The checker leaves its final flat binding table in place after
// check_program; bind_type reads one name out of it. That table is exactly
// what a reader wants here: the renamed name, its inferred type, and no
// source scopes left to reconstruct.
def dump_type_line(out: [str], seen: [str], name: str) -> void {
    if (name == "" || name in seen) { return; };
    let t = types.bind_type(name);
    if (t.k == K.tnone) { return; };
    seen += name;
    out += name + " : " + dump_type_name(t);
};

// Every binding the checker saw, in source order. `seen` also makes the
// function's own name appear once (the Decl and its Func carry it).
def dump_types_walk(n: Node, out: [str], seen: [str]) -> void {
    let k = n.k;
    if (k == K.decl) {
        let d: Decl = n;
        dump_type_line(out, seen, d.name);
        dump_types_walk(d.v, out, seen);
    } else if (k == K.func) {
        let f: Func = n;
        for i in 0..len(f.params) {
            dump_type_line(out, seen, f.params[i]);
        };
        dump_types_walk(f.body, out, seen);
        for i in 0..len(f.defs) {
            dump_types_walk(f.defs[i], out, seen);
        };
    } else if (k == K.typedef) {
        let t: TypeDef = n;
        if (!(t.name in seen)) {
            seen += t.name;
            out += "type " + t.name + " = " + dump_type_name(t.typ);
        };
    } else if (k == K.block) {
        let b: Block = n;
        for i in 0..len(b.stmts) { dump_types_walk(b.stmts[i], out, seen); };
    } else if (k == K.kw_foreach) {
        let f: Foreach = n;
        dump_type_line(out, seen, f.name);
        dump_types_walk(f.iter, out, seen);
        dump_types_walk(f.body, out, seen);
    } else if (k == K.forrange) {
        let f: ForRange = n;
        dump_type_line(out, seen, f.name);
        dump_types_walk(f.lo, out, seen);
        dump_types_walk(f.hi, out, seen);
        dump_types_walk(f.body, out, seen);
    } else if (k == K.kw_if) {
        let b: If = n;
        dump_types_walk(b.cond, out, seen);
        dump_types_walk(b.then, out, seen);
        if (b.has_else) { dump_types_walk(b.els, out, seen); };
    } else if (k == K.kw_while) {
        let w: While = n;
        dump_types_walk(w.cond, out, seen);
        dump_types_walk(w.body, out, seen);
    } else if (k == K.kw_for) {
        let f: For = n;
        dump_types_walk(f.init, out, seen);
        dump_types_walk(f.cond, out, seen);
        dump_types_walk(f.step, out, seen);
        dump_types_walk(f.body, out, seen);
    } else if (k == K.bin) {
        let b: Bin = n;
        dump_types_walk(b.l, out, seen);
        dump_types_walk(b.r, out, seen);
    } else if (k == K.un) {
        let u: Un = n;
        dump_types_walk(u.e, out, seen);
    } else if (k == K.addr || k == K.deref || k == K.ret) {
        let w: Wrap = n;
        dump_types_walk(w.e, out, seen);
    } else if (k == K.call) {
        let c: Call = n;
        dump_types_walk(c.callee, out, seen);
        for i in 0..len(c.args) { dump_types_walk(c.args[i], out, seen); };
    } else if (k == K.assign) {
        let a: Assign = n;
        dump_types_walk(a.v, out, seen);
    } else if (k == K.opassign) {
        let a: OpAssign = n;
        dump_types_walk(a.tgt, out, seen);
        dump_types_walk(a.v, out, seen);
    } else if (k == K.incdec) {
        let d: IncDec = n;
        dump_types_walk(d.tgt, out, seen);
    } else if (k == K.index) {
        let x: Index = n;
        dump_types_walk(x.arr, out, seen);
        dump_types_walk(x.idx, out, seen);
    } else if (k == K.idxassign) {
        let a: IdxAssign = n;
        dump_types_walk(a.arr, out, seen);
        dump_types_walk(a.idx, out, seen);
        dump_types_walk(a.v, out, seen);
    } else if (k == K.slice) {
        let s: Slice = n;
        dump_types_walk(s.arr, out, seen);
        dump_types_walk(s.lo, out, seen);
        dump_types_walk(s.hi, out, seen);
    } else if (k == K.sliceassign) {
        let s: SliceAssign = n;
        dump_types_walk(s.arr, out, seen);
        dump_types_walk(s.lo, out, seen);
        dump_types_walk(s.hi, out, seen);
        dump_types_walk(s.v, out, seen);
    } else if (k == K.dot) {
        let d: Dot = n;
        dump_types_walk(d.obj, out, seen);
    } else if (k == K.dotassign) {
        let d: DotAssign = n;
        dump_types_walk(d.obj, out, seen);
        dump_types_walk(d.v, out, seen);
    } else if (k == K.array) {
        let a: ArrLit = n;
        for i in 0..len(a.elems) { dump_types_walk(a.elems[i], out, seen); };
    } else if (k == K.arrrep) {
        let a: ArrRep = n;
        dump_types_walk(a.v, out, seen);
    } else if (k == K.map || k == K.rec) {
        let r: RecLit = n;
        for i in 0..len(r.vals) { dump_types_walk(r.vals[i], out, seen); };
    } else if (k == K.matchend) {
        let m: MatchEnd = n;
        dump_types_walk(m.e, out, seen);
    } else if (k == K.narrow || k == K.rectest) {
        let nw: Narrow = n;
        dump_types_walk(nw.e, out, seen);
    } else if (k == K.store) {
        let s: Store = n;
        dump_types_walk(s.p, out, seen);
        dump_types_walk(s.v, out, seen);
    };
};

def dump_types(ast: Block) -> void {
    puts("# stage: types (after strip_ns, rename and check_program)\n");
    puts("# name : type — the checker's final flat bindings; $N names are rename's\n");
    let out: [str] = [];
    let seen: [str] = [];
    for i in 0..len(ast.stmts) { dump_types_walk(ast.stmts[i], out, seen); };
    puts(join(out, "\n") + "\n");
};

// ── machine IR ───────────────────────────────────────────────────────────

// One emitted function body, rendered from the packed eight-word stream by
// ir.y's own printer (the same text `--emit=asm` would consume). `opt` runs
// the final-link optimizer first, so `ir` and `ir-opt` differ only by that
// pass.
def dump_ir(bodies: [[long]], btext: [[str]], labels: [str], opt: bool) -> void {
    if (opt) {
        puts("# stage: machine IR (after optimize.optimize, before final link)\n");
    } else {
        puts("# stage: machine IR (after emit_fns, before final-link optimization)\n");
    };
    puts("# each instruction is eight words internally: a form id and seven operands;\n");
    puts("# this listing uses ir.y's mnemonic renderer, not the packed numbers.\n");
    for i in 0..len(bodies) {
        let body = bodies[i];
        if (opt) { body = optim.optimize(body, optim.goal()); };
        let txt: [str] = [];
        if (i < len(btext)) { txt = btext[i]; };
        let name = "?";
        if (i < len(labels)) { name = labels[i]; };
        puts("\n# function " + name + "\n");
        puts(insn.ir_render_all(body, txt, false, 0) + "\n");
    };
};

export { dump_tokens, dump_ast, dump_renamed, dump_types, dump_ir };
