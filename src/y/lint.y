// lint.y — warnings: what looks like a mistake in a program that
// compiles. native.y compile_unit runs lint_unit on the program's unit
// (and each package's, under `ycc build`) once it typechecked; the driver
// prints what comes back as `FILE:LINE:COL: warning: MSG` on stderr
// (ycc.y print_native_warnings), unless `-w`. A warning never changes the
// program: the unit compiles to the same bytes either way.
//
// Two walks:
// - the renamed tree (rename.y: every binding is `orig$N`, N unique in
//   the unit): a value computed and dropped, code after a `return`, a
//   local never read (or only written), `x = x`, `x < x`, a division by
//   a literal zero, a record or map literal giving one key twice;
// - the parse tree, where annotations read as written: a record or union
//   type written out in full more than once (`type` names it), or where
//   an alias already names it; two aliases naming one type; one alias
//   declared twice.
//
// `wlevel` is the warning level the driver was given (`ycc -W N`, 0 by
// default). Level 1 turns on the two optional checks that a dropped value
// can only be a mistake: a call whose result nobody reads, and the read
// forms (`x.f`, `a[i]`, `&x`, `*p`, a literal) used as a statement. They
// are off by default because a getter call or a bare `a[i]` is a habit,
// not a mistake, and turning them on for every build would drown the
// warnings that are. Nothing extra runs at level 0.
//
// Parameters, loop variables, top-level bindings and any name starting
// with `_` are exempt from the unused-binding rules. The C copy in src/c
// compiles this file (lint.c, PORTING.md).

import tags from "./tags.y";
import types from "./types.y";
import parser from "./parser.y";

type LintVar = { name: str, kind: str, num: long, line: long, col: long, scal: bool, fresh: bool, strf: bool, top: bool };
type LintRet = { name: str, ret: Type, line: long, col: long };
// Three fields say, in the emitter's terms, whether the statement being
// walked is generated through `gen` (a value is produced) or through
// `gen_stmt` (nothing reads one). `dropnext`: the statement list about to be
// walked is a loop body's, whose value the emitter drops (gen_discard ->
// gen_block_as with dropped true). `vused`: this statement is the last of a
// list that is not dropped, and every other block generates its last
// statement through `gen`. `loops`: how many loop bodies enclose it, so the
// one warning that wants them (a copying append inside a loop) does not fire
// on a single copy, which costs what any `+` costs. Which of the first two
// an expression sees decides whether a `+=` on a string appends in place or
// copies; see lint_opassign.
type LintSt = { warns: [Diag], vars: [LintVar], flags: [long], rets: [LintRet], ridx: NameIx, self: str, wlevel: long, dropnext: bool, vused: bool, loops: long };
type LintRoot = { typ: Type, line: long, col: long, alias: str, mod: str };
type LintOcc = { key: str, typ: Type, line: long, col: long, parent: long, decl: bool, alias: str, rep: bool };
type LintTy = { roots: [LintRoot], atyps: [Type], amods: [str], amap: NameIx, amemo: [str], abusy: [bool], occs: [LintOcc], line: long, col: long, mod: str };

// Which lines are a module's (rename.y rename_program_x): line i + 1 is in
// file lint_ofile[i], module lint_fmods of it ("" for none).
let lint_ofile: [long] = [];
let lint_fmods: [str] = [];

// The warnings for one unit: `ast` as parsed, `ast3` renamed (and
// checked), sorted by position; ofile and fmods say which lines are a
// module's.
def lint_unit(ast: Block, ast3: Block, ofile: [long], fmods: [str], wlevel: long) -> [Diag] {
    lint_ofile = ofile;
    lint_fmods = fmods;
    let warns: [Diag] = [];
    let vars: [LintVar] = [];
    let flags: [long] = [];
    let rets: [LintRet] = [];
    let st = { warns: warns, vars: vars, flags: flags, rets: rets, ridx: parser.nameix_new(64), self: "", wlevel: wlevel, dropnext: false, vused: false, loops: 0 };
    if (wlevel >= 1) {
        lint_rets(st, ast3.stmts)
    };
    lint_stmts(st, ast3.stmts, false, true);
    lint_vars(st);
    lint_types(st, ast.stmts);
    lint_sorted(st.warns)
};

// ── what each def returns (level 1 only) ──────────────────────────────────
//
// The renamed tree carries a def's written return type, so the checks can
// tell a call that hands back a value from one that hands back nothing.
// Collected before the walk, so a forward call knows too. `self` is a
// walk-time name: a def body calls itself through `self`, and the tree
// does not say which def that is.

// Every `def` in the tree, by its renamed name.
def lint_rets(st: LintSt, stmts: [Node]) -> long {
    let i = 0;
    while (i < len(stmts)) {
        lint_rets_node(st, stmts[i]);
        i = i + 1;
    };
    0
};

def lint_rets_node(st: LintSt, node: Node) -> long {
    let k: long = node.k;
    if (k == K.decl) {
        let decl: Decl = node;
        if (decl.kind == "def" && decl.v.k == K.func) {
            let func: Func = decl.v;
            let n = lint_num(decl.name);
            if (n > 0 && parser.nameix_get(st.ridx, decl.name) < 0) {
                parser.nameix_put(st.ridx, decl.name, len(st.rets));
                st.rets += { name: decl.name, ret: func.ret, line: node.line, col: node.col };
            };
            lint_rets(st, func.defs)
        } else {
            lint_rets_node(st, decl.v)
        }
    } else if (k == K.kw_if) {
        let branch: If = node;
        lint_rets_node(st, branch.then);
        lint_rets_node(st, branch.els)
    } else if (k == K.block) {
        let block: Block = node;
        lint_rets(st, block.stmts)
    } else if (k == K.kw_while) {
        let loop: While = node;
        lint_rets_node(st, loop.body)
    } else if (k == K.kw_for) {
        let loop: For = node;
        lint_rets_node(st, loop.body)
    } else if (k == K.kw_foreach) {
        let loop: Foreach = node;
        lint_rets_node(st, loop.body)
    } else if (k == K.forrange) {
        let loop: ForRange = node;
        lint_rets_node(st, loop.body)
    } else {
        0
    }
};

// The binding a call goes to, resolved: an id naming a def, or `self`,
// which is the def it is written in ("" when the callee is neither).
def lint_binding(st: LintSt, callee: Node) -> str {
    if (callee.k != K.id) {
        ""
    } else {
        let leaf: Leaf = callee;
        if (leaf.v == "self") { st.self } else { leaf.v }
    }
};

// Whether the call hands a value back. A name no def answers for -- a
// builtin, a package's qualified name, a name from another unit -- is
// taken to be void: the linter has no way to know, and a wrong warning is
// worse than a missing one.
def lint_returns(st: LintSt, callee: Node) -> bool {
    let nm = lint_binding(st, callee);
    if (nm == "") {
        false
    } else {
        let i = parser.nameix_get(st.ridx, nm);
        if (i < 0) {
            false
        } else {
            let ret = st.rets[i].ret;
            let rk: long = ret.k;
            !(rk == K.tvoid || rk == K.tunk || rk == K.tnone)
        }
    }
};

// A def's name while its body is walked, so `self` resolves; the one
// before, restored after.
def lint_self(st: LintSt, name: str) -> str {
    let was = st.self;
    st.self = name;
    was
};

// A def's value, walked with `self` bound to its name: a call to `self` is
// a call to the def it is written in, so it is named for it.
def lint_def_body(st: LintSt, name: str, v: Node) -> long {
    let was = lint_self(st, name);
    lint_node(st, v, true);
    st.self = was;
    0
};

def lint_warn(st: LintSt, msg: str, line: long, col: long) -> long {
    st.warns += { msg: msg, line: line, col: col };
    0
};

// ── the renamed tree ────────────────────────────────────────────────────

// The name a binding was written with: `orig$N` less `$N` (and a shadowed
// def's `$shadowI`); "" for one the parser made up (a match subject).
def lint_disp(name: str) -> str {
    let d = index_of(name, "$");
    if (d < 0) { name } else { name[:d] }
};

// N of a renamed binding `orig$N`, or 0 for a name rename.y left alone (a
// builtin, `self`, a package's qualified name). N counts from 1.
def lint_num(name: str) -> long {
    let i = len(name) - 1;
    let v = 0;
    let m = 1;
    let go = true;
    while (go && i >= 0) {
        let c = byte_at(name, i);
        if (c >= c'0' && c <= c'9') {
            v = v + (c - c'0') * m;
            m = m * 10;
            i = i - 1;
        } else {
            go = false;
        };
    };
    if (i >= 0 && m > 1 && byte_at(name, i) == 36) { v } else { 0 }
};

// What happened to a binding, by its N: 1 read, 2 assigned, 4 grown
// (`+=`/`*=`, which on an array is visible through every alias).
def lint_mark(st: LintSt, name: str, bit: long) -> long {
    let n = lint_num(name);
    if (n > 0) {
        let fl = st.flags;
        while (len(fl) <= n) {
            fl += 0;
        };
        fl[n] = fl[n] | bit;
    };
    0
};

// A local binding (let, const, nested def), checked for use at the end.
// `scal`: it holds a number, string or bool, whose `+=` makes a new value
// only it sees. `fresh`: it starts as an array literal no one else holds.
def lint_note(st: LintSt, name: str, kind: str, line: long, col: long, scal: bool, fresh: bool, strf: bool) -> long {
    let d = lint_disp(name);
    if (d != "" && byte_at(d, 0) != 95 && index_of(name, "$shadow") < 0) {
        st.vars += { name: d, kind: kind, num: lint_num(name), line: line, col: col, scal: scal, fresh: fresh, strf: strf, top: false };
    };
    0
};

// A top-level binding: a global. Recorded, because the value-used append
// check needs to know whether the name holds a string, and marked `top` so
// lint_vars leaves it alone -- a global that nothing in this unit reads is
// not an unused variable (another unit of the program may read it).
def lint_note_top(st: LintSt, node: Decl) -> long {
    let name = node.name;
    let d = lint_disp(name);
    if (d != "" && byte_at(d, 0) != 95 && index_of(name, "$shadow") < 0) {
        st.vars += { name: d, kind: node.kind, num: lint_num(name), line: node.line, col: node.col, scal: lint_scal(node.typ, node.v), fresh: lint_fresh(node.v), strf: lint_strheld(node.typ, node.v), top: true };
    };
    0
};

// A binding that holds a string, as far as the syntax shows: annotated
// `str`, or initialised with a string literal. Deliberately a syntactic
// question, not a type one -- lint never runs the checker -- so a binding
// whose string-ness is only visible from a call's return is simply not
// flagged. The check it feeds is advice, so a miss is a miss and never a
// wrong warning.
def lint_strheld(typ: Type, v: Node) -> bool {
    if (typ.k == K.tstr) {
        true
    } else {
        v.k == K.str
    }
};

// Whether the binding a name refers to was noted as holding a string (see
// lint_strheld). A renamed binding is matched on rename.y's number, which
// identifies the binding itself -- two locals spelled the same in two defs
// are two bindings, and a match on the written name would let one of them
// vouch for the other. A top-level binding is renamed to nothing (its name
// is unique in the unit already, and lint_mark leaves globals alone for the
// same reason: see the number), so those are matched on the name.
def lint_var_str(st: LintSt, name: str) -> bool {
    let n = lint_num(name);
    let d = lint_disp(name);
    let i = 0;
    while (i < len(st.vars)) {
        let v: LintVar = st.vars[i];
        if (v.strf && ((n > 0 && v.num == n) || (n == 0 && v.num == 0 && v.name == d))) {
            return true;
        };
        i = i + 1;
    };
    false
};

// A statement list: a block's, a function body's, the unit's. Only the
// last statement's value is used, and only when the list's is. The first
// statement after one that always returns never runs (a def there still
// does: defs hoist).
def lint_stmts(st: LintSt, stmts: [Node], used: bool, top: bool) -> long {
    let n = len(stmts);
    // a flag for this list, if lint_loop_body marked it a dropped one
    let drop = st.dropnext;
    st.dropnext = false;
    let dead = false;
    let told = false;
    let i = 0;
    while (i < n) {
        let s = stmts[i];
        if (dead && !told && lint_code(s)) {
            lint_warn_start(st, "unreachable code", s);
            told = true;
        };
        st.vused = !drop && i == n - 1;
        lint_stmt(st, s, used && i == n - 1, top);
        if (!dead && lint_diverges(s)) {
            dead = true;
        };
        i = i + 1;
    };
    0
};

def lint_warn_at(st: LintSt, msg: str, node: Node) -> long {
    lint_warn(st, msg, node.line, node.col)
};

// At the first token of `node`: an operator's node sits at the operator,
// a call's at its `(`.
def lint_warn_start(st: LintSt, msg: str, node: Node) -> long {
    let k: long = node.k;
    if (k == K.call) {
        let call: Call = node;
        lint_warn_start(st, msg, call.callee)
    } else if (k == K.bin) {
        let bin: Bin = node;
        lint_warn_start(st, msg, bin.l)
    } else if (k == K.index) {
        let index: Index = node;
        lint_warn_start(st, msg, index.arr)
    } else if (k == K.slice) {
        let slice: Slice = node;
        lint_warn_start(st, msg, slice.arr)
    } else if (k == K.dot) {
        let dot: Dot = node;
        lint_warn_start(st, msg, dot.obj)
    } else if (k == K.opassign) {
        let opassign: OpAssign = node;
        lint_warn_start(st, msg, opassign.tgt)
    } else if (k == K.incdec) {
        let incdec: IncDec = node;
        if (!incdec.pre) { lint_warn_start(st, msg, incdec.tgt) }
        else { lint_warn_at(st, msg, node) }
    } else {
        lint_warn_at(st, msg, node)
    }
};

// A top-level binding is a global: not checked for use.
def lint_stmt(st: LintSt, s: Node, used: bool, top: bool) -> long {
    if (top && s.k == K.decl) {
        let decl: Decl = s;
        // a top-level binding is a global: its value is walked, not its
        // use, but a def's body still reaches itself through `self`
        if (decl.kind == "def") {
            lint_def_body(st, decl.name, decl.v)
        } else {
            lint_note_top(st, decl);
            lint_node(st, decl.v, true)
        }
    } else {
        lint_node(st, s, used)
    }
};

// Not the parser's trailing void, and not a def.
def lint_code(s: Node) -> bool {
    let k: long = s.k;
    if (k == K.void) {
        false
    } else if (k == K.decl) {
        let decl: Decl = s;
        decl.kind != "def"
    } else {
        true
    }
};

// Whether a statement always leaves the function: a `return`, a block
// holding one, an `if` whose two arms both do.
def lint_diverges(s: Node) -> bool {
    let k: long = s.k;
    if (k == K.ret) {
        true
    } else if (k == K.block) {
        let block: Block = s;
        lint_any_diverges(block.stmts)
    } else if (k == K.kw_if) {
        let branch: If = s;
        branch.has_else && lint_diverges(branch.then) && lint_diverges(branch.els)
    } else {
        false
    }
};

def lint_any_diverges(stmts: [Node]) -> bool {
    let found = false;
    let i = 0;
    while (!found && i < len(stmts)) {
        found = lint_diverges(stmts[i]);
        i = i + 1;
    };
    found
};

// One node; `used`: its value is consumed. The kinds most nodes have
// come first.
def lint_node(st: LintSt, node: Node, used: bool) -> long {
    let k: long = node.k;
    if (k == K.id) {
        let leaf: Leaf = node;
        lint_id(st, leaf, used)
    } else if (k == K.call) {
        let call: Call = node;
        lint_node(st, call.callee, true);
        lint_list(st, call.args);
        lint_unused_call(st, node, used, call)
    } else if (k == K.dot) {
        let dot: Dot = node;
        lint_node(st, dot.obj, true);
        lint_unused_expr(st, node, used)
    } else if (k == K.str || k == K.num) {
        0
    } else if (k == K.bin) {
        let bin: Bin = node;
        lint_bin(st, bin, used)
    } else if (k == K.decl) {
        let decl: Decl = node;
        lint_decl(st, decl)
    } else if (k == K.block) {
        let block: Block = node;
        lint_stmts(st, block.stmts, used, false)
    } else if (k == K.kw_if) {
        let branch: If = node;
        lint_if(st, branch, used)
    } else if (k == K.assign) {
        let assign: Assign = node;
        lint_assign(st, assign)
    } else if (k == K.index) {
        let index: Index = node;
        lint_two(st, index.arr, index.idx);
        lint_unused_expr(st, node, used)
    } else if (k == K.rec) {
        let rec: RecLit = node;
        lint_lit(st, rec, "field", "record");
        lint_unused_expr(st, node, used)
    } else if (k == K.array) {
        let array: ArrLit = node;
        lint_list(st, array.elems);
        lint_unused_expr(st, node, used)
    } else if (k == K.ret || k == K.un || k == K.addr || k == K.deref || k == K.rectest || k == K.narrow || k == K.matchend) {
        lint_one(st, node, used)
    } else if (k == K.opassign) {
        let opassign: OpAssign = node;
        lint_opassign(st, opassign, used)
    } else if (k == K.kw_while) {
        let loop: While = node;
        lint_node(st, loop.cond, true);
        lint_loop_body(st, loop.body)
    } else if (k == K.func) {
        let func: Func = node;
        lint_func(st, func);
        lint_unused_expr(st, node, used)
    } else if (k == K.incdec) {
        let incdec: IncDec = node;
        lint_incdec(st, incdec, used)
    } else if (k == K.idxassign) {
        let assign: IdxAssign = node;
        lint_two(st, assign.arr, assign.idx);
        lint_node(st, assign.v, true)
    } else if (k == K.dotassign) {
        let assign: DotAssign = node;
        lint_two(st, assign.obj, assign.v)
    } else if (k == K.slice) {
        let slice: Slice = node;
        lint_two(st, slice.arr, slice.lo);
        lint_node(st, slice.hi, true);
        lint_unused_expr(st, node, used)
    } else if (k == K.kw_for) {
        let loop: For = node;
        lint_for(st, loop)
    } else if (k == K.kw_foreach) {
        let loop: Foreach = node;
        lint_node(st, loop.iter, true);
        lint_loop_body(st, loop.body)
    } else if (k == K.forrange) {
        let loop: ForRange = node;
        lint_two(st, loop.lo, loop.hi);
        lint_loop_body(st, loop.body)
    } else if (k == K.map) {
        let map: RecLit = node;
        lint_lit(st, map, "key", "map");
        lint_unused_expr(st, node, used)
    } else if (k == K.arrrep) {
        let rep: ArrRep = node;
        lint_node(st, rep.v, true);
        lint_unused_expr(st, node, used)
    } else if (k == K.store) {
        let store: Store = node;
        lint_two(st, store.p, store.v)
    } else if (k == K.sliceassign) {
        let assign: SliceAssign = node;
        lint_two(st, assign.arr, assign.lo);
        lint_two(st, assign.hi, assign.v)
    } else {
        0
    }
};

// The kinds with one operand, `e`; a unary operator's dropped result is
// a mistake.
def lint_one(st: LintSt, node: Node, used: bool) -> long {
    if (node.k == K.un) {
        let un: Un = node;
        lint_un(st, un, used)
    } else if (node.k == K.rectest || node.k == K.narrow) {
        let narrow: Narrow = node;
        lint_node(st, narrow.e, true);
        lint_unused_expr(st, node, used)
    } else if (node.k == K.matchend) {
        let matchend: MatchEnd = node;
        lint_node(st, matchend.e, true)
    } else if (node.k == K.ret) {
        let wrap: Wrap = node;
        lint_node(st, wrap.e, true)
    } else {
        let wrap: Wrap = node;
        lint_node(st, wrap.e, true);
        lint_unused_expr(st, node, used)
    }
};

// Level 1: a call whose result nobody reads, when the callee hands one
// back. The message names the function the way the source spells it.
def lint_unused_call(st: LintSt, node: Node, used: bool, call: Call) -> long {
    if (st.wlevel >= 1 && !used && lint_returns(st, call.callee)) {
        // named for the def it calls: a recursive `self` is `f()`
        let nm = lint_binding(st, call.callee);
        lint_warn_at(st, "the value of '" + lint_disp(nm) + "()' is not used", node);
    };
    0
};

// Level 1: a read or a literal used as a statement -- `x.f`, `a[i]`,
// `a[1:2]`, `&x`, `*p`, a record/array/map literal, `a is B`. Nothing
// else can be meant by it, and the statement is easy to miss. The
// position says which expression it is.
def lint_unused_expr(st: LintSt, node: Node, used: bool) -> long {
    if (st.wlevel >= 1 && !used) {
        lint_warn_at(st, "the value computed here is not used", node);
    };
    0
};

def lint_list(st: LintSt, nodes: [Node]) -> long {
    let i = 0;
    while (i < len(nodes)) {
        lint_node(st, nodes[i], true);
        i = i + 1;
    };
    0
};

def lint_two(st: LintSt, a: Node, b: Node) -> long {
    lint_node(st, a, true);
    lint_node(st, b, true)
};

def lint_id(st: LintSt, node: Leaf, used: bool) -> long {
    let name: str = node.v;
    lint_mark(st, name, 1);
    let d = lint_disp(name);
    if (!used && d != "" && d != "none") {
        lint_warn_at(st, "the value of '" + d + "' is not used", node);
    };
    0
};

def lint_un(st: LintSt, node: Un, used: bool) -> long {
    let e = node.e;
    lint_node(st, e, true);
    if (!used && e.k != K.num) {
        lint_warn_at(st, "the result of '" + node.op + "' is not used", node);
    };
    0
};

// `ok && f()` dropping its value is control flow: f runs only when ok.
// Any other operator's dropped value is a mistake.
def lint_bin(st: LintSt, node: Bin, used: bool) -> long {
    let op: str = node.op;
    let l = node.l;
    let r = node.r;
    if ((op == "&&" || op == "||") && !used && lint_effect(r)) {
        lint_node(st, l, true);
        lint_node(st, r, false)
    } else {
        lint_two(st, l, r);
        if (!used) {
            let msg = "the result of '" + op + "' is not used";
            if (op == "==") {
                msg = msg + "; did you mean '='?";
            };
            lint_warn_at(st, msg, node);
        };
        if ((op == "<" || op == ">") && lint_same_id(l, r)) {
            let left: Leaf = l;
            let d = lint_disp(left.v);
            lint_warn_at(st, "'" + d + " " + op + " " + d + "' is always false", node);
        };
        if ((op == "/" || op == "%") && lint_zero(r)) {
            lint_warn_at(st, "division by zero", node);
        };
        0
    }
};

// The names are compared as strings: `==` on two unannotated values
// compares their words.
def lint_same_id(l: Node, r: Node) -> bool {
    if (l.k == K.id && r.k == K.id) {
        let left: Leaf = l;
        let right: Leaf = r;
        left.v == right.v
    } else {
        false
    }
};

// Whether evaluating a node can do more than compute its value.
def lint_effect(node: Node) -> bool {
    let k: long = node.k;
    if (k == K.call || k == K.assign || k == K.opassign || k == K.incdec || k == K.idxassign || k == K.dotassign || k == K.sliceassign || k == K.store) {
        true
    } else if (k == K.block || k == K.kw_if || k == K.kw_while || k == K.kw_for || k == K.kw_foreach || k == K.forrange || k == K.ret) {
        true
    } else if (k == K.bin) {
        let bin: Bin = node;
        lint_effect_logic(bin)
    } else {
        false
    }
};

def lint_effect_logic(node: Bin) -> bool {
    let op: str = node.op;
    (op == "&&" || op == "||") && lint_effect(node.r)
};

// A literal integer zero (`0`, `0x0`, `0b0_0`). Not `0.0`: a float
// division by zero is an infinity or a nan, not a trap.
def lint_zero(node: Node) -> bool {
    if (node.k == K.num) {
        let num: Leaf = node;
        lint_zero_text(num.v)
    } else {
        false
    }
};

def lint_zero_text(s: str) -> bool {
    let p = s[:2];
    let digits = s;
    if (p == "0x" || p == "0X" || p == "0b" || p == "0B") {
        digits = s[2:];
    } else if (index_of(s, ".") >= 0 || index_of(s, "e") >= 0 || index_of(s, "E") >= 0) {
        digits = "";
    };
    let ok = len(digits) > 0;
    let i = 0;
    while (ok && i < len(digits)) {
        let c = byte_at(digits, i);
        ok = c == c'0' || c == c'_';
        i = i + 1;
    };
    ok
};

// An `if` gives its arms' values only when it has both arms.
def lint_if(st: LintSt, node: If, used: bool) -> long {
    lint_node(st, node.cond, true);
    let arms = used && node.has_else;
    lint_node(st, node.then, arms);
    lint_node(st, node.els, arms);
    if (st.wlevel >= 1 && node.has_else && lint_empty_arm(node.els)) {
        lint_warn_at(st, "the 'else' branch is empty", node)
    } else { 0 }
};

// An arm holding nothing at all: an empty block. Only an `else` is worth a
// word -- `else { }` is what the void redesign made unnecessary, and the
// branch can go. A block with even a `;` in it was written on purpose.
def lint_empty_arm(n: Node) -> bool {
    if (n.k == K.block) {
        let block: Block = n;
        len(block.stmts) == 0
    } else { false }
};

def lint_for(st: LintSt, node: For) -> long {
    lint_node(st, node.init, false);
    lint_node(st, node.cond, true);
    lint_node(st, node.step, false);
    lint_loop_body(st, node.body)
};

// A loop body: its value is dropped, so a block body's last statement is a
// statement like the ones before it. Only a block -- gen_discard sends a
// bare statement through gen_stmt anyway -- and only that block's own list:
// a block nested inside it (an if arm, say) is generated through `gen`, so
// its last statement does produce a value.
def lint_loop_body(st: LintSt, body: Node) -> long {
    let was = st.dropnext;
    let wv = st.vused;
    let wl = st.loops;
    st.dropnext = body.k == K.block;
    st.vused = false;
    st.loops = st.loops + 1;
    lint_node(st, body, false);
    st.dropnext = was;
    st.vused = wv;
    st.loops = wl;
    0
};

def lint_func(st: LintSt, node: Func) -> long {
    let body: Block = node.body;
    lint_stmts(st, body.stmts, true, false)
};

def lint_decl(st: LintSt, node: Decl) -> long {
    let v = node.v;
    if (node.kind == "def") {
        lint_note(st, node.name, "def", node.line, node.col, false, false, false);
        lint_def_body(st, node.name, v)
    } else {
        lint_note(st, node.name, node.kind, node.line, node.col, lint_scal(node.typ, v), lint_fresh(v), lint_strheld(node.typ, v));
        lint_node(st, v, true)
    }
};

def lint_scal(typ: Type, v: Node) -> bool {
    let tk: long = typ.k;
    let vk: long = v.k;
    if (tk == K.tlong || tk == K.tfloat || tk == K.tbyte || tk == K.tstr || tk == K.tbool) {
        true
    } else {
        vk == K.num || vk == K.str || vk == K.char || vk == K.bool
    }
};

def lint_fresh(v: Node) -> bool {
    let vk: long = v.k;
    vk == K.array || vk == K.arrrep
};

def lint_assign(st: LintSt, node: Assign) -> long {
    let name: str = node.name;
    let v = node.v;
    lint_mark(st, name, 2);
    lint_node(st, v, true);
    if (v.k == K.id) {
        let id: Leaf = v;
        if (id.v == name) {
            lint_warn_at(st, "'" + lint_disp(name) + "' is assigned to itself", node);
        };
    };
    0
};

def lint_incdec(st: LintSt, node: IncDec, used: bool) -> long {
    let t = node.tgt;
    if (t.k == K.id) {
        let id: Leaf = t;
        lint_mark(st, id.v, 2);
        if (used) {
            lint_mark(st, id.v, 1);
        };
        0
    } else {
        lint_node(st, t, true)
    }
};

def lint_opassign(st: LintSt, node: OpAssign, used: bool) -> long {
    let t = node.tgt;
    let op: str = node.op;
    let v = node.v;
    lint_node(st, v, true);
    if (t.k == K.id) {
        let id: Leaf = t;
        if (op == "+" || op == "*") {
            lint_mark(st, id.v, 4);
        } else {
            lint_mark(st, id.v, 2);
        };
        if (used) {
            lint_mark(st, id.v, 1);
        };
    } else {
        lint_node(st, t, true);
    };
    if ((op == "/" || op == "%") && lint_zero(v)) {
        lint_warn_at(st, "division by zero", node);
    };
    // A value-used `+=` on a string is `s = s + t`: the ownership cell is
    // dropped, so the buffer is exactly as long as the result and nothing
    // can append to it in place again. That is what keeps a string already
    // read from `s` stable -- but it also means the whole string is copied
    // here, and a loop of these copies it once per iteration: 10,000 of
    // them building 120 KB allocate 1.2 GB. An append statement is O(1)
    // amortised instead (see gen_sappend), so the one-character difference
    // is worth naming. It is advice rather than an error because the value
    // may well be wanted.
    if (st.loops > 0 && (used || st.vused) && op == "+" && t.k == K.id) {
        let tid: Leaf = t;
        if (lint_var_str(st, tid.v)) {
            lint_warn_at(st, "this `+=` on a string copies the whole string, so a loop of them is quadratic -- add a `;` if nothing reads the value", node);
        };
    };
    0
};

// A record or map literal giving a key twice keeps the last value; the
// earlier one is computed for nothing.
def lint_lit(st: LintSt, node: RecLit, what: str, kind: str) -> long {
    let keys: [str] = node.keys;
    lint_list(st, node.vals);
    let i = 0;
    while (i < len(keys)) {
        let key = keys[i];
        if (key != "..." && lint_seen(keys, i)) {
            lint_warn_at(st, "duplicate " + what + " '" + key + "' in a " + kind + " literal; the last one wins", node);
        };
        i = i + 1;
    };
    0
};

def lint_seen(keys: [str], i: long) -> bool {
    let key = keys[i];
    let found = false;
    let j = 0;
    while (!found && j < i) {
        found = keys[j] == key;
        j = j + 1;
    };
    found
};

// Every noted binding: read is fine; grown is fine unless the growth is
// only its own (a number's, or a fresh array's never reassigned).
def lint_vars(st: LintSt) -> long {
    let flags = st.flags;
    foreach (v in st.vars) {
        if (v.top) {
        } else {
            let f = 0;
            if (v.num < len(flags)) {
                f = flags[v.num];
            };
            let word = lint_word(v.kind);
            if (f & 1 != 0) {
            } else if (f & 4 != 0 && !(v.scal || (v.fresh && f & 2 == 0))) {
            } else if (f & 6 != 0) {
                lint_warn(st, word + " '" + v.name + "' is assigned but never read", v.line, v.col)
            } else {
                lint_warn(st, "unused " + word + " '" + v.name + "'", v.line, v.col)
            };
        };
    };
    0
};

def lint_word(kind: str) -> str {
    if (kind == "let") {
        "variable"
    } else if (kind == "const") {
        "constant"
    } else {
        "function"
    }
};

// ── the parse tree: types ───────────────────────────────────────────────
// Every annotation (a let's or const's, a parameter's, a return type, an
// alias's) is a root. A type's key is one string per type: aliases
// expanded, a union's members sorted. The records of two or more fields
// and the unions in a root are its occurrences, outer before inner, each
// at its root's position.

def lint_types(st: LintSt, stmts: [Node]) -> long {
    let roots: [LintRoot] = [];
    let atyps: [Type] = [];
    let amemo: [str] = [];
    let abusy: [bool] = [];
    let occs: [LintOcc] = [];
    let amods: [str] = [];
    let t = { roots: roots, atyps: atyps, amods: amods, amap: parser.nameix_new(64), amemo: amemo, abusy: abusy, occs: occs, line: 0, col: 0, mod: "" };
    lint_tw_list(t, stmts);
    // The aliases: a name declared again is the last declaration's.
    foreach (r in t.roots) {
        if (r.alias != "") {
            if (parser.nameix_get(t.amap, r.alias) >= 0) {
                lint_warn(st, "type '" + r.alias + "' is declared more than once; the last declaration counts", r.line, r.col);
            };
            parser.nameix_put(t.amap, r.alias, len(t.atyps));
            t.atyps += r.typ;
            t.amods += r.mod;
            t.amemo += "";
            t.abusy += false;
        };
    };
    // An alias's own type is its declaration, not a use; only the last
    // declaration of a name names a type.
    let tdi = 0;
    foreach (r in t.roots) {
        t.line = r.line;
        t.col = r.col;
        t.mod = r.mod;
        let first = len(t.occs);
        lint_tk(t, r.typ, true, -1);
        if (r.alias != "") {
            if (len(t.occs) > first && lint_cand(r.typ)) {
                let o = t.occs[first];
                o.decl = true;
                if (parser.nameix_get(t.amap, r.alias) == tdi) {
                    o.alias = r.alias;
                };
            };
            tdi = tdi + 1;
        };
    };
    lint_report(st, t)
};

def lint_tw_list(t: LintTy, nodes: [Node]) -> long {
    let i = 0;
    while (i < len(nodes)) {
        lint_tw(t, nodes[i]);
        i = i + 1;
    };
    0
};

def lint_tw(t: LintTy, node: Node) -> long {
    let k: long = node.k;
    if (k == K.id || k == K.str || k == K.num) {
        0
    } else if (k == K.call) {
        let call: Call = node;
        lint_tw(t, call.callee);
        lint_tw_list(t, call.args)
    } else if (k == K.dot) {
        let dot: Dot = node;
        lint_tw(t, dot.obj)
    } else if (k == K.bin) {
        let bin: Bin = node;
        lint_tw(t, bin.l);
        lint_tw(t, bin.r)
    } else if (k == K.decl) {
        let decl: Decl = node;
        lint_tw_decl(t, decl)
    } else if (k == K.block) {
        let block: Block = node;
        lint_tw_list(t, block.stmts)
    } else if (k == K.kw_if) {
        let branch: If = node;
        lint_tw(t, branch.cond);
        lint_tw(t, branch.then);
        lint_tw(t, branch.els)
    } else if (k == K.assign) {
        let assign: Assign = node;
        lint_tw(t, assign.v)
    } else if (k == K.arrrep) {
        let rep: ArrRep = node;
        lint_tw(t, rep.v)
    } else if (k == K.index) {
        let index: Index = node;
        lint_tw(t, index.arr);
        lint_tw(t, index.idx)
    } else if (k == K.rec || k == K.map) {
        let rec: RecLit = node;
        lint_tw_list(t, rec.vals)
    } else if (k == K.array) {
        let array: ArrLit = node;
        lint_tw_list(t, array.elems)
    } else if (k == K.ret || k == K.un || k == K.addr || k == K.deref || k == K.rectest || k == K.narrow || k == K.matchend) {
        lint_tw_one(t, node)
    } else if (k == K.func) {
        let func: Func = node;
        lint_tw_func(t, func)
    } else if (k == K.typedef) {
        let tdef: TypeDef = node;
        lint_root(t, tdef.typ, tdef.line, tdef.col, tdef.name)
    } else if (k == K.opassign) {
        let assign: OpAssign = node;
        lint_tw(t, assign.tgt);
        lint_tw(t, assign.v)
    } else if (k == K.kw_while) {
        let loop: While = node;
        lint_tw(t, loop.cond);
        lint_tw(t, loop.body)
    } else if (k == K.incdec) {
        let incdec: IncDec = node;
        lint_tw(t, incdec.tgt)
    } else if (k == K.idxassign) {
        let assign: IdxAssign = node;
        lint_tw(t, assign.arr);
        lint_tw(t, assign.idx);
        lint_tw(t, assign.v)
    } else if (k == K.dotassign) {
        let assign: DotAssign = node;
        lint_tw(t, assign.obj);
        lint_tw(t, assign.v)
    } else if (k == K.slice) {
        let slice: Slice = node;
        lint_tw(t, slice.arr);
        lint_tw(t, slice.lo);
        lint_tw(t, slice.hi)
    } else if (k == K.kw_for) {
        let loop: For = node;
        lint_tw(t, loop.init);
        lint_tw(t, loop.cond);
        lint_tw(t, loop.step);
        lint_tw(t, loop.body)
    } else if (k == K.kw_foreach) {
        let loop: Foreach = node;
        lint_tw(t, loop.iter);
        lint_tw(t, loop.body)
    } else if (k == K.forrange) {
        let loop: ForRange = node;
        lint_tw(t, loop.lo);
        lint_tw(t, loop.hi);
        lint_tw(t, loop.body)
    } else if (k == K.store) {
        let store: Store = node;
        lint_tw(t, store.p);
        lint_tw(t, store.v)
    } else if (k == K.sliceassign) {
        let assign: SliceAssign = node;
        lint_tw(t, assign.arr);
        lint_tw(t, assign.lo);
        lint_tw(t, assign.hi);
        lint_tw(t, assign.v)
    } else {
        0
    }
};

def lint_tw_one(t: LintTy, node: Node) -> long {
    if (node.k == K.un) {
        let un: Un = node;
        lint_tw(t, un.e)
    } else if (node.k == K.rectest || node.k == K.narrow) {
        let narrow: Narrow = node;
        lint_tw(t, narrow.e)
    } else if (node.k == K.matchend) {
        let matchend: MatchEnd = node;
        lint_tw(t, matchend.e)
    } else {
        let wrap: Wrap = node;
        lint_tw(t, wrap.e)
    }
};

def lint_tw_decl(t: LintTy, node: Decl) -> long {
    if (node.kind != "def") {
        lint_root(t, node.typ, node.line, node.col, "");
    };
    lint_tw(t, node.v)
};

def lint_tw_func(t: LintTy, node: Func) -> long {
    let line: long = node.line;
    let col: long = node.col;
    let ps = node.ptypes;
    let i = 0;
    while (i < len(ps)) {
        lint_root(t, ps[i], line, col, "");
        i = i + 1;
    };
    lint_root(t, node.ret, line, col, "");
    lint_tw(t, node.body)
};

def lint_root(t: LintTy, typ: Type, line: long, col: long, alias: str) -> long {
    if (typ.k != K.tnone) {
        // a module's alias is its own: `m.T` (rename.y rn_prepass_one)
        let m = lint_mod_of(line);
        let name = alias;
        if (m != "" && alias != "") { name = m + "." + alias; };
        t.roots += { typ: typ, line: line, col: col, alias: name, mod: m };
    };
    0
};

// The module line ln is in ("" for none).
def lint_mod_of(ln: long) -> str {
    if (ln >= 1 && ln <= len(lint_ofile)) {
        let f = lint_ofile[ln - 1];
        if (f < len(lint_fmods)) { lint_fmods[f] } else { "" }
    } else { "" }
};

// An occurrence: a record of two or more fields, or a union.
def lint_cand(ty: Type) -> bool {
    let k: long = ty.k;
    if (k == K.trec) {
        let rec: TRec = ty;
        let fs: [Field] = rec.fields;
        // mutex and sem are records too, but named ones (parser.y sync_type)
        len(fs) >= 2 && !fs[0].name.starts_with("$")
    } else {
        k == K.tunion
    }
};

// The key of `ty`; with `rec`, its occurrences are noted (`parent`: the
// one it is in, or -1).
def lint_tk(t: LintTy, ty: Type, rec: bool, parent: long) -> str {
    let k: long = ty.k;
    if (k == K.tname) {
        let name: TName = ty;
        lint_tk_name(t, name.name)
    } else if (k == K.tptr) {
        let ptr: TPtr = ty;
        "*" + lint_tk(t, ptr.to, rec, parent)
    } else if (k == K.tarr) {
        let arr: TOf = ty;
        "[" + lint_tk(t, arr.of, rec, parent) + "]"
    } else if (k == K.tarrfix) {
        let arr: TFix = ty;
        "[" + lint_tk(t, arr.of, rec, parent) + ";" + tostring(arr.n) + "]"
    } else if (k == K.topt) {
        let opt: TOf = ty;
        lint_tk(t, opt.of, rec, parent) + "?"
    } else if (k == K.tmap) {
        let map: TMap = ty;
        let kk = lint_tk(t, map.key, rec, parent);
        "{" + kk + "=>" + lint_tk(t, map.of, rec, parent) + "}"
    } else if (k == K.tfunc) {
        let func: TFunc = ty;
        let ak = lint_tk_list(t, func.args, rec, parent);
        "(" + ak + ")->" + lint_tk(t, func.ret, rec, parent)
    } else if (k == K.tparams || k == K.tunion) {
        let list: TList = ty;
        if (k == K.tparams) { "(" + lint_tk_list(t, list.ts, rec, parent) + ")" }
        else { lint_tk_union(t, list, rec, parent) }
    } else if (k == K.trec) {
        let record: TRec = ty;
        lint_tk_rec(t, record, rec, parent)
    } else {
        ktag(k)
    }
};

def lint_tk_list(t: LintTy, ts: [Type], rec: bool, parent: long) -> str {
    let parts: [str] = [];
    let i = 0;
    while (i < len(ts)) {
        parts += lint_tk(t, ts[i], rec, parent);
        i = i + 1;
    };
    join(parts, ",")
};

// An alias is expanded once (rec off: its own occurrences are its
// declaration's); one met again inside itself stays `@Name`, as does a
// name no alias declares.
def lint_tk_name(t: LintTy, name: str) -> str {
    // in a module's code a bare name is the module's own alias first
    let ai = -1;
    if (t.mod != "" && index_of(name, ".") < 0) { ai = parser.nameix_get(t.amap, t.mod + "." + name); };
    if (ai < 0) { ai = parser.nameix_get(t.amap, name); };
    if (ai < 0) {
        "@" + name
    } else if (t.abusy[ai]) {
        "@" + name
    } else if (t.amemo[ai] != "") {
        t.amemo[ai]
    } else {
        t.abusy[ai] = true;
        // an alias's type reads in its own module
        let mod0 = t.mod;
        t.mod = t.amods[ai];
        let key = lint_tk(t, t.atyps[ai], false, -1);
        t.mod = mod0;
        t.abusy[ai] = false;
        t.amemo[ai] = key;
        key
    }
};

def lint_tk_rec(t: LintTy, ty: TRec, rec: bool, parent: long) -> str {
    let fs = ty.fields;
    let me = parent;
    if (rec && lint_cand(ty)) {
        me = lint_occ(t, ty, parent);
    };
    let parts: [str] = [];
    let i = 0;
    while (i < len(fs)) {
        let f = fs[i];
        parts += f.name + ":" + lint_tk(t, f.typ, rec, me);
        i = i + 1;
    };
    let key = "{" + join(parts, ",") + "}";
    if (me != parent) {
        lint_occ_key(t, me, key);
    };
    key
};

// A union's key lists its members sorted, without repeats, an alias of a
// union replaced by its members: `A | B`, `B | A` and `AB | A` agree.
def lint_tk_union(t: LintTy, ty: TList, rec: bool, parent: long) -> str {
    let me = parent;
    if (rec) {
        me = lint_occ(t, ty, parent);
    };
    let parts: [str] = [];
    lint_tk_members(t, ty, rec, me, parts);
    let key = "(" + join(lint_sort_uniq(parts), "|") + ")";
    if (me != parent) {
        lint_occ_key(t, me, key);
    };
    key
};

def lint_tk_members(t: LintTy, u: TList, rec: bool, me: long, parts: [str]) -> long {
    let ts = u.ts;
    let i = 0;
    while (i < len(ts)) {
        let m = ts[i];
        let ai = lint_union_alias(t, m);
        if (ai >= 0) {
            let union: TList = t.atyps[ai];
            t.abusy[ai] = true;
            lint_tk_members(t, union, false, me, parts);
            t.abusy[ai] = false;
        } else {
            parts += lint_tk(t, m, rec, me);
        };
        i = i + 1;
    };
    0
};

// The alias a union member names when it is a union (and not one being
// expanded), or -1.
def lint_union_alias(t: LintTy, m: Type) -> long {
    if (m.k == K.tname) {
        let name: TName = m;
        let ai = parser.nameix_get(t.amap, name.name);
        if (ai < 0) {
            -1
        } else if (t.abusy[ai]) {
            -1
        } else if (lint_is_union(t.atyps[ai])) {
            ai
        } else {
            -1
        }
    } else {
        -1
    }
};

def lint_is_union(ty: Type) -> bool {
    ty.k == K.tunion
};

def lint_occ(t: LintTy, ty: Type, parent: long) -> long {
    t.occs += { key: "", typ: ty, line: t.line, col: t.col, parent: parent, decl: false, alias: "", rep: false };
    len(t.occs) - 1
};

def lint_occ_key(t: LintTy, i: long, key: str) -> long {
    let o = t.occs[i];
    o.key = key;
    0
};

def lint_sort_uniq(xs: [str]) -> [str] {
    let out: [str] = [];
    let i = 0;
    while (i < len(xs)) {
        let x = xs[i];
        let j = len(out);
        out += x;
        while (j > 0 && x < out[j - 1]) {
            out[j] = out[j - 1];
            j = j - 1;
        };
        out[j] = x;
        i = i + 1;
    };
    let res: [str] = [];
    let k = 0;
    while (k < len(out)) {
        if (k == 0 || out[k] != out[k - 1]) {
            res += out[k];
        };
        k = k + 1;
    };
    res
};

// Every occurrence by its key. One an alias names (other than that
// alias's declaration) says so; then one written out twice or more is
// reported once, at its first place. An occurrence inside one reported is
// not reported again, and inside one an alias names it does not count:
// the alias replaces it. So the counting comes first, and the reporting
// goes outer before inner.
def lint_report(st: LintSt, t: LintTy) -> long {
    let occs = t.occs;
    let ids = parser.nameix_new(64);
    let counts: [long] = [];
    let alias_of: [str] = [];
    let told: [bool] = [];
    let occ_id: [long] = [];
    foreach (o in occs) {
        let id = parser.nameix_get(ids, o.key);
        if (id < 0) {
            id = len(counts);
            parser.nameix_put(ids, o.key, id);
            counts += 0;
            alias_of += "";
            told += false;
        };
        occ_id += id;
        if (o.alias != "") {
            if (alias_of[id] == "") {
                alias_of[id] = o.alias;
            } else if (alias_of[id] != o.alias) {
                lint_warn(st, "type '" + o.alias + "' is the same type as '" + alias_of[id] + "'", o.line, o.col);
                o.rep = true;
            };
        };
    };
    // `gone`: inside one an alias names (or a repeated declaration).
    let gone: [bool] = [];
    let i = 0;
    while (i < len(occs)) {
        let o = occs[i];
        let id = occ_id[i];
        let g = o.rep || (o.parent >= 0 && gone[o.parent]);
        if (!g && !o.decl) {
            if (alias_of[id] != "") {
                g = true;
            } else {
                counts[id] = counts[id] + 1;
            };
        };
        gone += g;
        i = i + 1;
    };
    i = 0;
    while (i < len(occs)) {
        let o = occs[i];
        let id = occ_id[i];
        if (o.parent >= 0 && lint_rep(occs, o.parent)) {
            o.rep = true;
        } else if (o.decl) {
        } else if (alias_of[id] != "") {
            lint_warn(st, "the type " + types.tstr(o.typ) + " is already declared as '" + alias_of[id] + "'; use the alias", o.line, o.col);
            o.rep = true;
        } else if (counts[id] >= 2) {
            if (!told[id]) {
                lint_warn(st, "the type " + types.tstr(o.typ) + " is written out " + tostring(counts[id]) + " times; name it with `type`", o.line, o.col);
                told[id] = true;
            };
            o.rep = true;
        };
        i = i + 1;
    };
    0
};

def lint_rep(occs: [LintOcc], i: long) -> bool {
    let o = occs[i];
    o.rep
};

// ── output ──────────────────────────────────────────────────────────────

// By position, then message; a warning made twice is given once.
def lint_sorted(ws: [Diag]) -> [Diag] {
    let all = lint_msort(ws);
    let out: [Diag] = [];
    let i = 0;
    while (i < len(all)) {
        let w = all[i];
        let n = len(out);
        if (n == 0 || lint_before(out[n - 1], w)) {
            out += w;
        };
        i = i + 1;
    };
    out
};

def lint_msort(ws: [Diag]) -> [Diag] {
    let n = len(ws);
    if (n < 2) {
        ws
    } else {
        let a = lint_msort(ws[:n / 2]);
        let b = lint_msort(ws[n / 2:]);
        let out: [Diag] = [];
        let i = 0;
        let j = 0;
        while (i < len(a) || j < len(b)) {
            if (j >= len(b) || (i < len(a) && !lint_before(b[j], a[i]))) {
                out += a[i];
                i = i + 1;
            } else {
                out += b[j];
                j = j + 1;
            };
        };
        out
    }
};

def lint_before(a: Diag, b: Diag) -> bool {
    if (a.line != b.line) {
        a.line < b.line
    } else if (a.col != b.col) {
        a.col < b.col
    } else {
        a.msg < b.msg
    }
};

export { lint_unit };
