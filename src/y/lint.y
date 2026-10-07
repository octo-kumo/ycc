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
// warnings that are. Nothing extra runs at level 0. Level 2 adds the
// shortening suggestions collected in LINT_RULES.md (the `lint_short_*`
// checks); they are advice about form, so they stay above the level that
// is about mistakes.
//
// Parameters, loop variables, top-level bindings and any name starting
// with `_` are exempt from the unused-binding rules. The C copy in src/c
// compiles this file (lint.c, PORTING.md).

import tags from "./tags.y";
import types from "./types.y";
import parser from "./parser.y";

type LintVar = { name: str, kind: str, num: long, line: long, col: long, scal: bool, fresh: bool, strf: bool, top: bool };
// Where each top-level name was declared last: a name -> line map (the
// parser's NameIx, which lint already keeps one of). A walk of `vars` would
// do it too, but that list holds every local -- measured at +4.4% of a
// self-compile -- and a list of the top-level names in order is quadratic in
// them (+1.4%). The line says which file too (lint_file_of), so a module's
// name and the program's do not shadow each other's warning.
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
type LintSt = { warns: [Diag], vars: [LintVar], tops: NameIx, flags: [long], rets: [LintRet], ridx: NameIx, self: str, wlevel: long, dropnext: bool, vused: bool, loops: long, logic: long };
type LintRoot = { typ: Type, line: long, col: long, alias: str, mod: str };
type LintOcc = { key: str, typ: Type, line: long, col: long, parent: long, decl: bool, alias: str, rep: bool };
type LintTy = { roots: [LintRoot], atyps: [Type], amods: [str], amap: NameIx, amemo: [str], abusy: [bool], occs: [LintOcc], line: long, col: long, mod: str };

// Which lines are a module's (rename.y rename_program_x): line i + 1 is in
// file lint_ofile[i], module lint_fmods of it ("" for none).
let lint_ofile: [long] = [];
let lint_fmods: [str] = [];

// The warnings for one unit: `ast` as parsed, `ast3` renamed (and
// checked), sorted by position; ofile and fmods say which lines are a
// module's. `ogen` says which lines a meta block generated (see lint_meta_top);
// it is empty when the unit has no blocks.
def lint_unit(ast: Block, ast3: Block, ofile: [long], fmods: [str], wlevel: long, ogen: [bool]) -> [Diag] {
    lint_ofile = ofile;
    lint_fmods = fmods;
    let warns: [Diag] = [];
    let vars: [LintVar] = [];
    let flags: [long] = [];
    let rets: [LintRet] = [];
    let st = { warns: warns, vars: vars, tops: parser.nameix_new(256), flags: flags, rets: rets, ridx: parser.nameix_new(64), self: "", wlevel: wlevel, dropnext: false, vused: false, loops: 0, logic: 0 };
    if (wlevel >= 1) {
        lint_rets(st, ast3.stmts)
    };
    lint_stmts(st, ast3.stmts, false, true);
    if (len(ogen) > 0) { lint_meta_top(st, ast3.stmts, ogen) };
    lint_vars(st);
    lint_types(st, ast.stmts);
    lint_sorted(st.warns)
};

// With blocks in the file, the top level IS the generator's program, so every
// top-level statement there runs once in the generator and once in the program.
// That is fine for a declaration -- a `def` hoists, and a `let` a block reads
// should be pure (the manual says so) -- and for the text a block GENERATED,
// which the program runs once and the generator never ran at all: `ogen`
// (indexed by the statement's line) says which lines those are. Anything else
// is a statement with side effects the reader cannot see running twice.
def lint_meta_top(st: LintSt, stmts: [Node], ogen: [bool]) -> long {
    let i = 0;
    while (i < len(stmts)) {
        let s = stmts[i];
        if (s.k != K.decl && s.k != K.void && !meta_gen(s, ogen)) {
            lint_warn_start(st, "a top-level statement runs once in the meta generator and once in the program, so with a meta block in the file it must be a declaration (a def, type, const or let) -- keep a top-level let initializer pure", s);
        };
        i = i + 1;
    };
    0
};

// `ogen` is EMPTY for a unit with no meta blocks (see resolve_unit), so its
// length is the answer to "is this file's top level also a generator's?", and
// its entries say which lines a block generated.

// A statement starting on a line a meta block generated. Its line is the
// `#{` line (every generated line carries it, see mg_splice), and the ORIGIN
// map is what turns a program line back into a source line -- so `ogen` is
// indexed by the source line, and lint's own map says which source line a
// statement sits on.
def meta_gen(s: Node, ogen: [bool]) -> bool {
    let ln = s.line - 1;
    if (ln < 0 || ln >= len(ogen)) { false } else { ogen[ln] }
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
        if (c >= '0' && c <= '9') {
            v = v + (c - '0') * m;
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
    if (d != "" && byte_at(d, 0) != 95) {
        // A name bound twice at the top level is legal -- the later
        // declaration shadows the earlier one, which t14_shadow, t30 and
        // t53 all pin -- and rename.y keeps the earlier one under its
        // `$shadow` name so a self call inside it still binds to itself.
        // What is not legal is not knowing which copy is running: a
        // copy-paste that leaves an old definition behind shadows the new
        // one silently, and every read of the source shows the copy that is
        // not the one called. A warning is the whole of it (the same shape
        // the duplicate type alias gets); find_dup still rejects the
        // cross-file case outright, where there is no shadowing to mean.
        let fid = lint_file_of(node.line);
        let first = lint_top_first(st, d, fid);
        if (first > 0) {
            lint_warn(st, "'" + d + "' is declared more than once; the last declaration counts (the earlier one at line " + tostring(first) + ")", node.line, node.col);
        };
        // recorded either way: the map holds where each name was declared
        // LAST, so a third declaration names the second
        parser.nameix_put(st.tops, d, node.line);
        if (first == 0) {
            st.vars += { name: d, kind: node.kind, num: lint_num(name), line: node.line, col: node.col, scal: lint_scal(node.typ, node.v), fresh: lint_fresh(node.v), strf: lint_strheld(node.typ, node.v), top: true };
        };
    };
    0
};

// Where a top-level name was declared last, if that was in this file (0
// otherwise). Only the names this check records count, so a local of the
// same name never shadows a global's warning (different scopes, and lint
// has no scope). The file matters: a path-imported unit shares the
// program's namespace -- t134 pins that a module global may share the
// program's name -- so only two declarations of one file are the
// copy-paste this names.
def lint_top_first(st: LintSt, d: str, fid: long) -> long {
    let prev = parser.nameix_get(st.tops, d);
    if (prev > 0 && lint_file_of(prev) == fid) { prev } else { 0 }
};

// The file the line ln is in, 0 for the program's own text and for a line
// past the origin table.
def lint_file_of(ln: long) -> long {
    if (ln >= 1 && ln <= len(lint_ofile)) { lint_ofile[ln - 1] } else { 0 }
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

// Whether the binding holds a scalar (a number, string or bool). The
// compound-assignment rule needs it: `x = x + e` is `x += e` only where
// `+=` cannot be seen through an alias, and for an array it can.
def lint_var_scal(st: LintSt, name: str) -> bool {
    let n = lint_num(name);
    let d = lint_disp(name);
    let i = 0;
    while (i < len(st.vars)) {
        let v: LintVar = st.vars[i];
        if (v.scal && ((n > 0 && v.num == n) || (n == 0 && v.num == 0 && v.name == d))) {
            return true;
        };
        i = i + 1;
    };
    false
};

// Whether a type is a scalar, for a binding whose value the checker has
// not been asked about (a parameter).
def lint_tscal(typ: Type) -> bool {
    let k: long = typ.k;
    k == K.tlong || k == K.tfloat || k == K.tbyte || k == K.tstr || k == K.tbool
};

// Note a parameter, so the shortening rules can tell a `str` or a number
// from an array. `top` keeps lint_vars from calling it unused -- a
// parameter is never that.
def lint_note_param(st: LintSt, name: str, typ: Type, line: long, col: long) -> long {
    let d = lint_disp(name);
    if (d != "" && byte_at(d, 0) != 95) {
        st.vars += { name: d, kind: "param", num: lint_num(name), line: line, col: col, scal: lint_tscal(typ), fresh: false, strf: typ.k == K.tstr, top: true };
    };
    0
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
        if (st.wlevel >= 2) { lint_short_pair(st, stmts, i); };
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
        lint_note_top(st, decl);
        if (decl.kind == "def") {
            lint_def_body(st, decl.name, decl.v)
        } else {
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
        if (st.wlevel < 2 || !lint_short_ord(st, call)) {
            lint_list(st, call.args);
        };
        if (st.wlevel >= 2) { lint_short_call(st, call); };
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
        if (st.wlevel >= 2) { lint_short_while(st, loop); };
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
        if (st.wlevel >= 2) { lint_short_slice(st, slice); };
        lint_unused_expr(st, node, used)
    } else if (k == K.kw_for) {
        let loop: For = node;
        lint_for(st, loop)
    } else if (k == K.kw_foreach) {
        let loop: Foreach = node;
        lint_node(st, loop.iter, true);
        if (st.wlevel >= 2) { lint_short_range(st, loop); };
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
    // The chain check runs once, at the top of the `||` tree, and the flag
    // stays set while the operands are walked so a nested `||` does not
    // report the same chain again.
    let was = st.logic;
    if (st.wlevel >= 2 && op == "||" && was == 0) {
        st.logic = 1;
        lint_short_chain(st, node);
    };
    let l = node.l;
    let r = node.r;
    if ((op == "&&" || op == "||") && !used && lint_effect(r)) {
        lint_node(st, l, true);
        let res = lint_node(st, r, false);
        st.logic = was;
        res
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
        if (st.wlevel >= 2) { lint_short_bin(st, node); };
        st.logic = was;
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

// ── shortening suggestions (level 2, LINT_RULES.md) ──────────────────────
// Advice about form, never about meaning: every check here fires only when
// the rewrite it names is exactly the same program. They run above level 1
// because a dropped value can be a bug while a longer spelling is a habit.

// The value of an integer literal, or -1 when the node is not one. A char
// literal carries its byte as decimal text, so it reads here too.
def lint_int_val(node: Node) -> long {
    if (node.k != K.num && node.k != K.char) { return -1; };
    let num: Leaf = node;
    let s = num.v;
    if (len(s) > 0 && s[len(s) - 1:len(s)] == "n") { s = s[:len(s) - 1]; };
    let base = 10;
    let r = radix_of(s);
    if (r != 0) { base = r; s = s[2:]; };
    if (base == 10 && (index_of(s, ".") >= 0 || index_of(s, "e") >= 0 || index_of(s, "E") >= 0)) { return -1; };
    let v = 0;
    let ok = len(s) > 0;
    let i = 0;
    while (ok && i < len(s)) {
        let c = byte_at(s, i);
        if (c == '_') {
        } else if (c >= '0' && c <= '9') { v = v * base + (c - '0'); }
        else if (base == 16 && c >= 'a' && c <= 'f') { v = v * 16 + (c - 'a' + 10); }
        else if (base == 16 && c >= 'A' && c <= 'F') { v = v * 16 + (c - 'A' + 10); }
        else { ok = false; };
        i = i + 1;
    };
    if (ok) { v } else { -1 }
};

// The operator set that has a compound assignment.
def lint_compound_op(op: str) -> bool {
    op == "+" || op == "-" || op == "*" || op == "/" || op == "%" ||
    op == "&" || op == "|" || op == "^" || op == "<<" || op == ">>" || op == ">>>"
};

// Whether two written expressions are the same one. Only the shapes a
// slice bound is written with: a name, a literal, a unary and a binary.
// Commutativity is the caller's business.
def lint_same_node(a: Node, b: Node) -> bool {
    if (a.k != b.k) {
        false
    } else if (a.k == K.id || a.k == K.num || a.k == K.str || a.k == K.bool) {
        let x: Leaf = a;
        let y: Leaf = b;
        x.v == y.v
    } else if (a.k == K.un) {
        let x: Un = a;
        let y: Un = b;
        x.op == y.op && lint_same_node(x.e, y.e)
    } else if (a.k == K.bin) {
        let x: Bin = a;
        let y: Bin = b;
        x.op == y.op && lint_same_node(x.l, y.l) && lint_same_node(x.r, y.r)
    } else {
        false
    }
};

// `lo` and `hi` are `E + n` and `E + (n + 1)` (either operand order, and
// `n` may be 0), so `raw[k + 1:k + 2]` counts as well as `s[i:i + 1]`.
def lint_slice_one(lo: Node, hi: Node) -> bool {
    lint_same_node(lint_slice_base(lo), lint_slice_base(hi)) && lint_slice_off(hi) == lint_slice_off(lo) + 1
};

// The `E` of `E + n`, or the whole node when it is not a sum.
def lint_slice_base(node: Node) -> Node {
    if (node.k == K.bin) {
        let b: Bin = node;
        if (b.op == "+") {
            if (lint_int_val(b.r) >= 0) { return b.l; };
            if (lint_int_val(b.l) >= 0) { return b.r; };
        };
    };
    node
};

// The `n` of `E + n`, or 0.
def lint_slice_off(node: Node) -> long {
    if (node.k == K.bin) {
        let b: Bin = node;
        if (b.op == "+") {
            if (lint_int_val(b.r) >= 0) { return lint_int_val(b.r); };
            if (lint_int_val(b.l) >= 0) { return lint_int_val(b.l); };
        };
    };
    0
};

// Whether a written expression is a str (a literal, or a binding noted as
// holding one). An unknown receiver is not a str: a warning that would
// change a string into a byte had better be sure.
def lint_str_expr(st: LintSt, node: Node) -> bool {
    if (node.k == K.str) {
        true
    } else if (node.k == K.id) {
        let l: Leaf = node;
        lint_var_str(st, l.v)
    } else {
        false
    }
};

// The name to put in a message, when the expression has one.
def lint_operand(node: Node) -> str {
    if (node.k == K.id) { let l: Leaf = node; lint_disp(l.v) } else { "" }
};

// Rule 1.1/1.2: `x = x + e` is `x += e`.
def lint_short_assign(st: LintSt, node: Assign, name: str, v: Node) -> long {
    if (v.k != K.bin) { return 0; };
    let b: Bin = v;
    let op: str = b.op;
    if (b.l.k != K.id) { return 0; };
    let lid: Leaf = b.l;
    if (lid.v != name) { return 0; };
    let d = lint_disp(name);
    if (op == "+" && lint_int_val(b.r) == 1) {
        lint_warn_at(st, "'" + d + " = " + d + " + 1' can be written '" + d + "++'", node);
        0
    } else if (op == "-" && lint_int_val(b.r) == 1) {
        lint_warn_at(st, "'" + d + " = " + d + " - 1' can be written '" + d + "--'", node);
        0
    } else if (lint_compound_op(op) && lint_var_scal(st, name)) {
        lint_warn_at(st, "'" + d + " = " + d + " " + op + " <expr>' can be written '" + d + " " + op + "= <expr>'", node);
        0
    } else {
        0
    }
};

// Rule 1.9: a comparison against a bool literal is the value or its not.
def lint_short_bin(st: LintSt, node: Bin) -> long {
    let op: str = node.op;
    if (op != "==" && op != "!=") { return 0; };
    let lit = node.r;
    let other = node.l;
    if (node.l.k == K.bool) {
        lit = node.l;
        other = node.r;
    } else if (node.r.k != K.bool) {
        return 0;
    };
    let lb: Leaf = lit;
    let neg = (op == "!=") == (lb.v == "true");
    let d = lint_operand(other);
    if (d == "") {
        lint_warn_at(st, "a comparison against true or false is the value itself, or its negation", node);
    } else if (neg) {
        lint_warn_at(st, "'" + d + " " + op + " " + lb.v + "' can be written '!" + d + "'", node);
    } else {
        lint_warn_at(st, "'" + d + " " + op + " " + lb.v + "' can be written '" + d + "'", node);
    };
    0
};

// Rule 1.3: `byte_at(s, i)` is `s[i]`.
def lint_short_call(st: LintSt, call: Call) -> long {
    let callee = call.callee;
    if (callee.k != K.id) { return 0; };
    let id: Leaf = callee;
    if (id.v == "byte_at" && len(call.args) == 2 && parser.nameix_get(st.ridx, "byte_at") < 0) {
        lint_warn_at(st, "'byte_at(s, i)' can be written 's[i]'", call);
    };
    0
};

// Rule 1.5: `ord(s[E:E + 1])` is `s[E]`. Handled here, before the slice
// node is walked, so the slice does not also get rule 1.4's warning.
def lint_short_ord(st: LintSt, call: Call) -> bool {
    let callee = call.callee;
    if (callee.k != K.id) { return false; };
    let id: Leaf = callee;
    let args = call.args;
    if (id.v != "ord" || len(args) != 1 || args[0].k != K.slice || parser.nameix_get(st.ridx, "ord") >= 0) {
        false
    } else {
        let sl: Slice = args[0];
        if (!lint_slice_one(sl.lo, sl.hi)) {
            false
        } else {
            lint_two(st, sl.arr, sl.lo);
            lint_node(st, sl.hi, true);
            lint_warn_at(st, "'ord' of a one-character slice can be written as an index (a byte)", call);
            true
        }
    }
};

// Rule 1.4: a one-character slice of a str is `s[E]`.
def lint_short_slice(st: LintSt, slice: Slice) -> long {
    if (lint_slice_one(slice.lo, slice.hi) && lint_str_expr(st, slice.arr)) {
        lint_warn_at(st, "a one-character slice can be written as an index (a byte)", slice);
    };
    0
};

// Rules 1.6/1.7: a `||` chain of equalities against the same value is one
// range or one membership test. Called once per chain, from its top node.
def lint_short_chain(st: LintSt, node: Bin) -> long {
    let leaves: [Node] = [];
    lint_chain_leaves(node, leaves);
    if (len(leaves) < 3) { return 0; };
    let first = leaves[0];
    if (first.k != K.bin) { return 0; };
    let fb: Bin = first;
    if (fb.op != "==" || !lint_pure(fb.l)) { return 0; };
    let l0 = fb.l;
    let vals: [long] = [];
    let allint = true;
    let allstr = true;
    let i = 0;
    while (i < len(leaves)) {
        let leaf = leaves[i];
        if (leaf.k != K.bin) { return 0; };
        let b: Bin = leaf;
        if (b.op != "==" || !lint_same_node(l0, b.l)) { return 0; };
        if (b.r.k == K.str) {
            allint = false;
        } else {
            let v = lint_int_val(b.r);
            if (v < 0) { return 0; };
            vals += v;
            allstr = false;
        };
        i = i + 1;
    };
    if (allint) {
        let lo = vals[0];
        let hi = vals[0];
        let j = 0;
        while (j < len(vals)) {
            if (vals[j] < lo) { lo = vals[j]; };
            if (vals[j] > hi) { hi = vals[j]; };
            j = j + 1;
        };
        if (hi - lo + 1 == len(vals)) {
            lint_warn_at(st, "these equalities are a consecutive range; write a range comparison", node);
        } else {
            lint_warn_at(st, "these equalities test one value against a set; write one membership test", node);
        };
    } else if (allstr) {
        lint_warn_at(st, "these equalities test one value against a set of strings; write one membership test", node);
    };
    0
};

// The `==` comparisons of a `||` chain, in order.
def lint_chain_leaves(node: Node, out: [Node]) -> long {
    if (node.k == K.bin) {
        let b: Bin = node;
        if (b.op == "||") {
            lint_chain_leaves(b.l, out);
            lint_chain_leaves(b.r, out);
            return 0;
        };
    };
    out += node;
    0
};

// The one statement of a block, or a void node when the block holds none
// or more than one. A trailing `;` leaves a void filler (parse_block), so
// only the real statements are counted.
def lint_single_stmt(block: Node) -> Node {
    if (block.k == K.block) {
        let b: Block = block;
        let found: Node = { k: K.void, line: block.line, col: block.col };
        let n = 0;
        let i = 0;
        while (i < len(b.stmts)) {
            if (b.stmts[i].k != K.void) {
                found = b.stmts[i];
                n = n + 1;
            };
            i = i + 1;
        };
        if (n == 1) { return found; };
    };
    { k: K.void, line: block.line, col: block.col }
};

// 1 for `true`, 0 for `false`, -1 for anything else.
def lint_bool_lit(node: Node) -> long {
    if (node.k == K.bool) {
        let l: Leaf = node;
        if (l.v == "true") { 1 } else { 0 }
    } else { -1 }
};

// A value whose evaluation is the same whenever it happens: a literal or a
// name. Deliberately not a call, a field or an index -- those can observe a
// write between the two positions a rewrite moves them across.
def lint_pure(node: Node) -> bool {
    let k: long = node.k;
    k == K.num || k == K.str || k == K.bool || k == K.char || k == K.id
};

// Rule 2.1: an empty `if` arm.
def lint_short_empty_if(st: LintSt, node: If) -> long {
    let te = lint_empty_arm(node.then);
    let ee = node.has_else && lint_empty_arm(node.els);
    if (te && ee) {
        lint_warn_at(st, "both branches of this 'if' are empty; it does nothing", node);
    } else if (te) {
        lint_warn_at(st, "the 'if' branch is empty; invert the condition and drop the arm", node);
    };
    0
};

// Rules 2.3/2.4: an `if`/`else` that only chooses a value.
def lint_short_if_ternary(st: LintSt, node: If) -> long {
    if (!node.has_else) { return 0; };
    let a = lint_single_stmt(node.then);
    let b = lint_single_stmt(node.els);
    if (a.k == K.assign && b.k == K.assign) {
        let aa: Assign = a;
        let bb: Assign = b;
        if (aa.name == bb.name) {
            lint_warn_at(st, "'" + lint_disp(aa.name) + "' is chosen by a condition in both arms; write one conditional assignment", node);
        };
    } else if (a.k == K.ret && b.k == K.ret) {
        let wa: Wrap = a;
        let wb: Wrap = b;
        if (lint_bool_lit(wa.e) >= 0 && lint_bool_lit(wb.e) >= 0 && lint_bool_lit(wa.e) != lint_bool_lit(wb.e)) {
            lint_warn_at(st, "an 'if' returning true and false can return the condition", node);
        } else {
            lint_warn_at(st, "an 'if' returning a value from both arms can return a conditional", node);
        };
    };
    0
};

def lint_short_if(st: LintSt, node: If) -> long {
    lint_short_empty_if(st, node);
    lint_short_if_ternary(st, node);
    0
};

// A name set once after its `let`, under a condition (rule 2.2), or a
// return chosen by a condition (rule 2.4's tail form).
def lint_short_pair(st: LintSt, stmts: [Node], i: long) -> long {
    if (i + 1 >= len(stmts)) { return 0; };
    let d = stmts[i];
    let n = stmts[i + 1];
    if (d.k == K.decl && n.k == K.kw_while) {
        lint_short_index_loop(st, stmts, i);
    } else if (d.k == K.decl && n.k == K.kw_if) {
        let decl: Decl = d;
        let iff: If = n;
        if (decl.kind == "let" && decl.typ.k == K.tnone && lint_pure(decl.v) && !iff.has_else && iff.cond.k == K.id) {
            let cid: Leaf = iff.cond;
            let body = lint_single_stmt(iff.then);
            if (body.k == K.assign && cid.v != decl.name) {
                let as: Assign = body;
                if (as.name == decl.name) {
                    lint_warn_at(st, "'" + lint_disp(decl.name) + "' is set once under a condition; write 'let " + lint_disp(decl.name) + " = <cond> ? <then> : <initial>'", d);
                };
            };
        };
    } else if (d.k == K.kw_if && n.k == K.ret) {
        let iff: If = d;
        let r: Wrap = n;
        if (!iff.has_else && iff.cond.k == K.id) {
            let a = lint_single_stmt(iff.then);
            if (a.k == K.ret) {
                let ra: Wrap = a;
                if (lint_bool_lit(ra.e) >= 0 && lint_bool_lit(r.e) >= 0 && lint_bool_lit(ra.e) != lint_bool_lit(r.e)) {
                    lint_warn_at(st, "an 'if' returning true and then false can return the condition", d);
                } else {
                    lint_warn_at(st, "an 'if' returning a value and a following return can be one conditional return", d);
                };
            };
        };
    };
    0
};

// Rule 2.6: `while (true) { if (!c) { break; } ... }` is `while (c) ...`.
def lint_short_while(st: LintSt, loop: While) -> long {
    if (lint_bool_lit(loop.cond) != 1) { return 0; };
    let b = lint_first_stmt(loop.body);
    if (b.k != K.kw_if) { return 0; };
    let iff: If = b;
    if (iff.has_else) { return 0; };
    let s = lint_single_stmt(iff.then);
    if (s.k == K.kw_break) {
        lint_warn_at(st, "'while (true)' with a leading 'break' guard can test the guard instead", b);
    };
    0
};

def lint_first_stmt(block: Node) -> Node {
    if (block.k == K.block) {
        let b: Block = block;
        let i = 0;
        while (i < len(b.stmts)) {
            if (b.stmts[i].k != K.void) { return b.stmts[i]; };
            i = i + 1;
        };
    };
    { k: K.void, line: block.line, col: block.col }
};

// Walk a tree for one of two questions: is the name read, or does the body
// jump? `mask` is a bit set -- 1 a return, 2 a break, 4 a continue -- and
// `name` is "" when only the jumps matter. One walker because the rules
// that come next all need "is this index used after the loop" or "can this
// body be a closure", and a second copy of the descent would drift.
def lint_find(node: Node, name: str, mask: long) -> bool {
    let k: long = node.k;
    if (k == K.ret && mask & 1 != 0) { return true; };
    if (k == K.kw_break && mask & 2 != 0) { return true; };
    if (k == K.kw_continue && mask & 4 != 0) { return true; };
    if (k == K.id) {
        if (name == "") { return false; };
        let l: Leaf = node;
        l.v == name
    } else if (k == K.bin) {
        let b: Bin = node;
        lint_find(b.l, name, mask) || lint_find(b.r, name, mask)
    } else if (k == K.un) {
        let u: Un = node;
        lint_find(u.e, name, mask)
    } else if (k == K.call) {
        let c: Call = node;
        lint_find(c.callee, name, mask) || lint_find_list(c.args, name, mask)
    } else if (k == K.dot) {
        let d: Dot = node;
        lint_find(d.obj, name, mask)
    } else if (k == K.index) {
        let ix: Index = node;
        lint_find(ix.arr, name, mask) || lint_find(ix.idx, name, mask)
    } else if (k == K.slice) {
        let s: Slice = node;
        lint_find(s.arr, name, mask) || lint_find(s.lo, name, mask) || lint_find(s.hi, name, mask)
    } else if (k == K.assign) {
        let a: Assign = node;
        lint_find(a.v, name, mask)
    } else if (k == K.opassign) {
        let o: OpAssign = node;
        lint_find(o.tgt, name, mask) || lint_find(o.v, name, mask)
    } else if (k == K.incdec) {
        let o: IncDec = node;
        lint_find(o.tgt, name, mask)
    } else if (k == K.idxassign) {
        let a: IdxAssign = node;
        lint_find(a.arr, name, mask) || lint_find(a.idx, name, mask) || lint_find(a.v, name, mask)
    } else if (k == K.dotassign) {
        let a: DotAssign = node;
        lint_find(a.obj, name, mask) || lint_find(a.v, name, mask)
    } else if (k == K.sliceassign) {
        let a: SliceAssign = node;
        lint_find(a.arr, name, mask) || lint_find(a.lo, name, mask) || lint_find(a.hi, name, mask) || lint_find(a.v, name, mask)
    } else if (k == K.store) {
        let s: Store = node;
        lint_find(s.p, name, mask) || lint_find(s.v, name, mask)
    } else if (k == K.array) {
        let a: ArrLit = node;
        lint_find_list(a.elems, name, mask)
    } else if (k == K.rec || k == K.map) {
        let r: RecLit = node;
        lint_find_list(r.vals, name, mask)
    } else if (k == K.arrrep) {
        let a: ArrRep = node;
        lint_find(a.v, name, mask)
    } else if (k == K.rectest || k == K.narrow) {
        let n: Narrow = node;
        lint_find(n.e, name, mask)
    } else if (k == K.ret) {
        let w: Wrap = node;
        lint_find(w.e, name, mask)
    } else if (k == K.matchend) {
        let m: MatchEnd = node;
        lint_find(m.e, name, mask)
    } else if (k == K.block) {
        let b: Block = node;
        lint_find_list(b.stmts, name, mask)
    } else if (k == K.kw_if) {
        let i2: If = node;
        lint_find(i2.cond, name, mask) || lint_find(i2.then, name, mask) || lint_find(i2.els, name, mask)
    } else if (k == K.kw_while) {
        let w: While = node;
        lint_find(w.cond, name, mask) || lint_find(w.body, name, mask)
    } else if (k == K.kw_for) {
        let f: For = node;
        lint_find(f.init, name, mask) || lint_find(f.cond, name, mask) || lint_find(f.step, name, mask) || lint_find(f.body, name, mask)
    } else if (k == K.kw_foreach) {
        let f: Foreach = node;
        lint_find(f.iter, name, mask) || lint_find(f.body, name, mask)
    } else if (k == K.forrange) {
        let f: ForRange = node;
        lint_find(f.lo, name, mask) || lint_find(f.hi, name, mask) || lint_find(f.body, name, mask)
    } else if (k == K.func) {
        let f: Func = node;
        lint_find(f.body, name, mask) || lint_find_list(f.defs, name, mask)
    } else if (k == K.decl) {
        let d: Decl = node;
        lint_find(d.v, name, mask)
    } else { false }
};

def lint_find_list(nodes: [Node], name: str, mask: long) -> bool {
    let i = 0;
    while (i < len(nodes)) {
        if (lint_find(nodes[i], name, mask)) { return true; };
        i = i + 1;
    };
    false
};

// Whether the last real statement of a loop body is `iv = iv + 1` (also
// `iv++`, `iv += 1`).
def lint_step_one(body: Node, iv: str) -> bool {
    if (body.k != K.block) { return false; };
    let b: Block = body;
    let last: Node = { k: K.void, line: body.line, col: body.col };
    let i = 0;
    while (i < len(b.stmts)) {
        if (b.stmts[i].k != K.void) { last = b.stmts[i]; };
        i = i + 1;
    };
    if (last.k == K.assign) {
        let a: Assign = last;
        if (a.name != iv || a.v.k != K.bin) { return false; };
        let ab: Bin = a.v;
        if (ab.op != "+" || ab.l.k != K.id) { return false; };
        let al: Leaf = ab.l;
        al.v == iv && lint_int_val(ab.r) == 1
    } else if (last.k == K.opassign) {
        let o: OpAssign = last;
        if (o.op != "+" || o.tgt.k != K.id) { return false; };
        let ot: Leaf = o.tgt;
        ot.v == iv && lint_int_val(o.v) == 1
    } else if (last.k == K.incdec) {
        let inc: IncDec = last;
        if (inc.tgt.k != K.id || inc.op != "++") { return false; };
        let it: Leaf = inc.tgt;
        it.v == iv
    } else { false }
};

// The name inside `len(a)`, or "".
def lint_len_of(node: Node) -> str {
    if (node.k != K.call) { return ""; };
    let c: Call = node;
    if (c.callee.k != K.id || len(c.args) != 1) { return ""; };
    let id: Leaf = c.callee;
    if (id.v != "len" || c.args[0].k != K.id) { return ""; };
    let a: Leaf = c.args[0];
    a.v
};

// Rules 2.8/3.1: an index loop that is a `for` range or an array method.
def lint_short_index_loop(st: LintSt, stmts: [Node], i: long) -> long {
    if (i + 1 >= len(stmts)) { return 0; };
    let d = stmts[i];
    let n = stmts[i + 1];
    if (d.k != K.decl || n.k != K.kw_while) { return 0; };
    let decl: Decl = d;
    if (decl.kind != "let" || decl.typ.k != K.tnone) { return 0; };
    let loop: While = n;
    let iv = decl.name;
    if (loop.cond.k != K.bin) { return 0; };
    let cb: Bin = loop.cond;
    if ((cb.op != "<" && cb.op != "<=") || cb.l.k != K.id) { return 0; };
    let cl: Leaf = cb.l;
    if (cl.v != iv || !lint_step_one(loop.body, iv)) { return 0; };
    // The loop variable must not be read after the loop: the rewrite
    // scopes it to the loop, so a later read would not compile.
    if (lint_find_from(stmts, i + 2, iv, 0)) { return 0; };
    let arr = lint_len_of(cb.r);
    if (cb.op == "<" && arr != "") {
        if (lint_find(loop.body, "", 7)) { return 0; };
        lint_warn_at(st, "this index loop can be '" + lint_disp(arr) + ".foreach((e, i) => { ... })'", d);
    } else {
        if (lint_find(loop.body, "", 4)) { return 0; };
        lint_warn_at(st, "this index loop can be 'for " + lint_disp(iv) + " in <lo>..<hi> { ... }'", d);
    };
    0
};

// Rule 3.5: `foreach (i in range(len(a)))` can iterate the array directly.
def lint_short_range(st: LintSt, fe: Foreach) -> long {
    if (!lint_range_len(fe.iter)) { return 0; };
    if (lint_find(fe.body, "", 7)) { return 0; };
    lint_warn_at(st, "this range loop over an array's indices can be '<a>.foreach((e, i) => { ... })'", fe);
    0
};

// Whether the node is `range(len(a))`.
def lint_range_len(node: Node) -> bool {
    if (node.k != K.call) { return false; };
    let c: Call = node;
    if (c.callee.k != K.id || len(c.args) != 1) { return false; };
    let id: Leaf = c.callee;
    if (id.v != "range") { return false; };
    lint_len_of(c.args[0]) != ""
};

// The statements from index `from` on, walked without copying the list.
def lint_find_from(nodes: [Node], from: long, name: str, mask: long) -> bool {
    let i = from;
    while (i < len(nodes)) {
        if (lint_find(nodes[i], name, mask)) { return true; };
        i = i + 1;
    };
    false
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
    let digits = s;
    if (radix_of(s) != 0) {
        digits = s[2:];
    } else if (index_of(s, ".") >= 0 || index_of(s, "e") >= 0 || index_of(s, "E") >= 0) {
        digits = "";
    };
    let ok = len(digits) > 0;
    let i = 0;
    while (ok && i < len(digits)) {
        let c = byte_at(digits, i);
        ok = c == '0' || c == '_';
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
    } else { 0 };
    if (st.wlevel >= 2) { lint_short_if(st, node); };
    0
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
    // Note the parameters first: the shortening rules ask whether a name is
    // a str or an array, and one of those names is usually a parameter.
    let i = 0;
    while (i < len(node.params) && i < len(node.ptypes)) {
        lint_note_param(st, node.params[i], node.ptypes[i], node.line, node.col);
        i = i + 1;
    };
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
    if (st.wlevel >= 2) { lint_short_assign(st, node, name, v); };
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
    if (st.wlevel >= 2 && t.k == K.id && (op == "+" || op == "-") && lint_int_val(v) == 1) {
        let tid: Leaf = t;
        let d = lint_disp(tid.v);
        let rs = "++";
        if (op == "-") { rs = "--"; };
        lint_warn_at(st, "'" + d + " " + op + "= 1' can be written '" + d + rs + "'", node);
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
