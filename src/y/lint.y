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

type LintVar = { name: str, kind: str, num: long, line: long, col: long, scal: bool, fresh: bool, strf: bool, top: bool, vec: bool };
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
type LintSt = { warns: [Diag], vars: [LintVar], tops: NameIx, flags: [long], rets: [LintRet], ridx: NameIx, self: str, wlevel: long, dropnext: bool, vused: bool, loops: long, logic: long, chain: long };
// A shortening the compiler can apply itself (`ycc -W 2 --fix`): `rule` is
// the section of LINT_RULES.md, `line`/`col` anchor it in the spliced
// program, and `a`/`b` are that rule's own operands (a name, an operator, a
// receiver). fix.y does the text rewrite; the emitted bytes never depend on
// whether a fix was recorded.
type LintFix = { rule: str, line: long, col: long, a: str, b: str };
type LintRoot = { typ: Type, line: long, col: long, alias: str, mod: str };
type LintOcc = { key: str, typ: Type, line: long, col: long, parent: long, decl: bool, alias: str, rep: bool };
type LintTy = { roots: [LintRoot], atyps: [Type], amods: [str], amap: NameIx, amemo: [str], abusy: [bool], occs: [LintOcc], line: long, col: long, mod: str };

// Which lines are a module's (rename.y rename_program_x): line i + 1 is in
// file lint_ofile[i], module lint_fmods of it ("" for none).
let lint_ofile: [long] = [];
let lint_fmods: [str] = [];

// The shortenings found in the unit being linted, for `--fix` (see lint_fix,
// fix.y). Cleared at the top of every lint_unit.
let lint_fixes: [LintFix] = [];

def lint_fixes_get() -> [LintFix] { lint_fixes };

// Record a fixable shortening beside the warning it names. `a`/`b` are the
// rule's operands; fix.y reads them, so adding a fix is a call here and a
// case there, never a second search of the tree.
def lint_fix(st: LintSt, rule: str, line: long, col: long, a: str, b: str) {
    if (st.wlevel >= 2) {
        lint_fixes += { rule: rule, line: line, col: col, a: a, b: b };
    };
};

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
    lint_fixes = [];
    let st = { warns: warns, vars: vars, tops: parser.nameix_new(256), flags: flags, rets: rets, ridx: parser.nameix_new(64), self: "", wlevel: wlevel, dropnext: false, vused: false, loops: 0, logic: 0, chain: 0 };
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
    stmts.foreach((e) => {
        let s = e;
        if (s.k != K.decl && s.k != K.void && !meta_gen(s, ogen)) {
            lint_warn_start(st, "a top-level statement runs once in the meta generator and once in the program, so with a meta block in the file it must be a declaration (a def, type, const or let) -- keep a top-level let initializer pure", s);
        };
    });
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
    stmts.foreach((e) => {
        lint_rets_node(st, e);
    });
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
        let c = name[i];
        if (c >= '0' && c <= '9') {
            v += (c - '0') * m;
            m *= 10;
            i = i - 1;
        } else {
            go = false;
        };
    };
    if (i >= 0 && m > 1 && name[i] == 36) { v } else { 0 }
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
def lint_note(st: LintSt, name: str, kind: str, line: long, col: long, scal: bool, fresh: bool, strf: bool, vec: bool) -> long {
    let d = lint_disp(name);
    if (d != "" && d[0] != 95 && index_of(name, "$shadow") < 0) {
        st.vars += { name: d, kind: kind, num: lint_num(name), line: line, col: col, scal: scal, fresh: fresh, strf: strf, top: false, vec: vec };
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
    if (d != "" && d[0] != 95) {
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
            st.vars += { name: d, kind: node.kind, num: lint_num(name), line: node.line, col: node.col, scal: lint_scal(node.typ, node.v), fresh: lint_fresh(node.v), strf: lint_strheld(node.typ, node.v), top: true, vec: lint_vec(node.typ, node.v) };
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
    for i in 0..len(st.vars) {
        let v: LintVar = st.vars[i];
        if (v.strf && ((n > 0 && v.num == n) || (n == 0 && v.num == 0 && v.name == d))) {
            return true;
        };
    };
    false
};

// Whether the binding holds a scalar (a number, string or bool). The
// compound-assignment rule needs it: `x = x + e` is `x += e` only where
// `+=` cannot be seen through an alias, and for an array it can.
def lint_var_scal(st: LintSt, name: str) -> bool {
    let n = lint_num(name);
    let d = lint_disp(name);
    for i in 0..len(st.vars) {
        let v: LintVar = st.vars[i];
        if (v.scal && ((n > 0 && v.num == n) || (n == 0 && v.num == 0 && v.name == d))) {
            return true;
        };
    };
    false
};

// Whether a type is a scalar, for a binding whose value the checker has
// not been asked about (a parameter).
def lint_tscal(typ: Type) -> bool {
    let k: long = typ.k;
    k == K.tlong || k == K.tfloat || k == K.tbyte || k == K.tstr || k == K.tbool
};

// Whether a type and initializer make a binding an array. A slice of a str
// is not one, which is the case `lint_var_str` cannot see (it is not a str
// literal): rules 3.1/3.5 need positive proof before they say `.foreach`.
def lint_vec(typ: Type, v: Node) -> bool {
    typ.k == K.tarr || typ.k == K.tarrfix || lint_fresh(v)
};

// Whether the binding a name refers to was noted as an array.
def lint_var_vec(st: LintSt, name: str) -> bool {
    let n = lint_num(name);
    let d = lint_disp(name);
    for i in 0..len(st.vars) {
        let v: LintVar = st.vars[i];
        if (v.vec && ((n > 0 && v.num == n) || (n == 0 && v.num == 0 && v.name == d))) {
            return true;
        };
    };
    false
};

// Note a parameter, so the shortening rules can tell a `str` or a number
// from an array. `top` keeps lint_vars from calling it unused -- a
// parameter is never that.
def lint_note_param(st: LintSt, name: str, typ: Type, line: long, col: long) -> long {
    let d = lint_disp(name);
    if (d != "" && d[0] != 95) {
        st.vars += { name: d, kind: "param", num: lint_num(name), line: line, col: col, scal: lint_tscal(typ), fresh: false, strf: typ.k == K.tstr, top: true, vec: typ.k == K.tarr || typ.k == K.tarrfix };
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
    for i in 0..n {
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
        i++;
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
        if (st.wlevel >= 2) { lint_short_call(st, call); lint_short_foreach_elem(st, call); };
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
    nodes.foreach((e) => {
        lint_node(st, e, true);
    });
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
        let c = s[i];
        if (c == '_') {
        } else if (c >= '0' && c <= '9') { v = v * base + (c - '0'); }
        else if (base == 16 && c >= 'a' && c <= 'f') { v = v * 16 + (c - 'a' + 10); }
        else if (base == 16 && c >= 'A' && c <= 'F') { v = v * 16 + (c - 'A' + 10); }
        else { ok = false; };
        i++;
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
    if (op == "+" && lint_int_val(b.r) == 1 && lint_var_scal(st, name)) {
        lint_warn_at(st, "'" + d + " = " + d + " + 1' can be written '" + d + "++'", node);
        lint_fix(st, "1.2", node.line, node.col, d, "+");
        0
    } else if (op == "-" && lint_int_val(b.r) == 1 && lint_var_scal(st, name)) {
        lint_warn_at(st, "'" + d + " = " + d + " - 1' can be written '" + d + "--'", node);
        lint_fix(st, "1.2", node.line, node.col, d, "-");
        0
    } else if (lint_compound_op(op) && lint_var_scal(st, name)) {
        lint_warn_at(st, "'" + d + " = " + d + " " + op + " <expr>' can be written '" + d + " " + op + "= <expr>'", node);
        lint_fix(st, "1.1", node.line, node.col, d, op);
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
        if (node.r.k == K.bool) { lint_fix(st, "1.9", node.line, node.col, op, lb.v); };
    } else {
        lint_warn_at(st, "'" + d + " " + op + " " + lb.v + "' can be written '" + d + "'", node);
        if (node.r.k == K.bool) { lint_fix(st, "1.9", node.line, node.col, op, lb.v); };
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
        lint_fix(st, "1.3", callee.line, callee.col, "", "");
    };
    0
};

// Rule 3.6: a `foreach` closure whose element parameter is unused while the
// body indexes the array again: `a.foreach((e, i) => { let x = a[i]; })` is
// `a.foreach((e2, i) => { let x = e2; })`, and the index goes when nothing
// else needs it.
def lint_short_foreach_elem(st: LintSt, call: Call) -> long {
    if (call.callee.k != K.dot || len(call.args) != 1) { return 0; };
    let d: Dot = call.callee;
    if (d.key != "foreach" || d.obj.k != K.id || call.args[0].k != K.func) { return 0; };
    let arr: Leaf = d.obj;
    let f: Func = call.args[0];
    if (len(f.params) < 2) { return 0; };
    let el = f.params[0];
    let ix = f.params[1];
    if (lint_find(f.body, el, 0)) { return 0; };
    if (!lint_find(f.body, arr.v, 64)) { return 0; };
    // the element is not `a[i]` if the body writes a[i]: a store must keep
    // the index
    if (lint_find(f.body, arr.v, 128)) { return 0; };
    lint_warn_at(st, "the element parameter of this 'foreach' is unused; use it instead of indexing '" + lint_disp(arr.v) + "' again", call);
    lint_fix(st, "3.6", call.line, call.col, lint_disp(arr.v), lint_disp(ix));
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
            lint_fix(st, "1.5", callee.line, callee.col, "", "");
            true
        }
    }
};

// Rule 1.4: a one-character slice of a str is `s[E]`.
def lint_short_slice(st: LintSt, slice: Slice) -> long {
    if (lint_slice_one(slice.lo, slice.hi) && lint_str_expr(st, slice.arr)) {
        lint_warn_at(st, "a one-character slice can be written as an index (a byte)", slice);
        // Not offered as a fix: the byte is not the 1-char string, and the
        // consumer (a comparison, a concat) must change too.
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
    for i in 0..len(leaves) {
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
    };
    if (allint) {
        let lo = vals[0];
        let hi = vals[0];
        vals.foreach((e) => {
            if (e < lo) { lo = e; };
            if (e > hi) { hi = e; };
        });
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
        for i in 0..len(b.stmts) {
            if (b.stmts[i].k != K.void) {
                found = b.stmts[i];
                n++;
            };
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
    if (st.chain != 0) { return 0; };
    let te = lint_empty_arm(node.then);
    let ee = node.has_else && lint_empty_arm(node.els);
    if (te && ee) {
        lint_warn_at(st, "both branches of this 'if' are empty; it does nothing", node);
    } else if (te) {
        // An `else if` chain has no shorter form here: the arm being dropped
        // is the then, but what follows it is another condition.
        if (node.has_else && node.els.k == K.kw_if) { return 0; };
        lint_warn_at(st, "the 'if' branch is empty; invert the condition and drop the arm", node);
        // Only the invert is safe to apply: deleting the arm (or the whole
        // `if`) can leave the condition's names unused, a new warning.
        if (node.has_else) { lint_fix(st, "2.1", node.line, node.col, "", "inv"); };
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
            lint_fix(st, "2.3", node.line, node.col, "", "");
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
                    lint_fix(st, "2.2", d.line, d.col, "", "");
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
        for i in 0..len(b.stmts) {
            if (b.stmts[i].k != K.void) { return b.stmts[i]; };
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
    if (mask & 8 != 0 && lint_resizes(node, name)) { return true; };
    if (mask & 64 != 0 && k == K.index) {
        let mx: Index = node;
        if (mx.arr.k == K.id) { let ma: Leaf = mx.arr; if (ma.v == name) { return true; }; };
    };
    if (mask & 128 != 0 && lint_stores_index(node, name)) { return true; };
    if (k == K.id) {
        if (name == "" || mask & 8 != 0 || mask & 64 != 0 || mask & 128 != 0) { return false; };
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
    for i in 0..len(nodes) {
        if (lint_find(nodes[i], name, mask)) { return true; };
    };
    false
};

// Whether this node stores through `name[...]` (a written element). The
// element form of 3.6 is wrong there: the closure's parameter is a copy
// while the store writes the array.
def lint_stores_index(node: Node, name: str) -> bool {
    let k: long = node.k;
    if (k == K.idxassign) {
        let a: IdxAssign = node;
        if (a.arr.k != K.id) { return false; };
        let al: Leaf = a.arr;
        al.v == name
    } else if (k == K.opassign) {
        let o: OpAssign = node;
        lint_index_of(o.tgt, name)
    } else if (k == K.incdec) {
        let o: IncDec = node;
        lint_index_of(o.tgt, name)
    } else { false }
};

def lint_index_of(tgt: Node, name: str) -> bool {
    if (tgt.k != K.index) { return false; };
    let ix: Index = tgt;
    if (ix.arr.k != K.id) { return false; };
    let al: Leaf = ix.arr;
    al.v == name
};

// Whether this node changes what `name` holds as a whole (mask bit 8): a
// whole-array assign or `op=`, `++`, or a length-changing method call. An
// element store (`a[i] = x`) is not one.
def lint_resizes(node: Node, name: str) -> bool {
    let k: long = node.k;
    if (k == K.assign) {
        let a: Assign = node;
        a.name == name
    } else if (k == K.opassign) {
        let o: OpAssign = node;
        if (o.tgt.k != K.id) { false } else { let t: Leaf = o.tgt; t.v == name }
    } else if (k == K.incdec) {
        let o: IncDec = node;
        if (o.tgt.k != K.id) { false } else { let t: Leaf = o.tgt; t.v == name }
    } else if (k == K.call) {
        let c: Call = node;
        if (c.callee.k != K.dot) {
            false
        } else {
            let d: Dot = c.callee;
            if (d.obj.k != K.id) { false } else { let o: Leaf = d.obj; o.v == name && lint_resize_method(d.key) }
        }
    } else { false }
};

def lint_resize_method(key: str) -> bool {
    key == "push" || key == "pop" || key == "remove" || key == "insert" ||
    key == "shift" || key == "unshift" || key == "sort"
};

// Whether the last real statement of a loop body is `iv = iv + 1` (also
// `iv++`, `iv += 1`).
def lint_step_one(body: Node, iv: str) -> bool {
    if (body.k != K.block) { return false; };
    let b: Block = body;
    let last: Node = { k: K.void, line: body.line, col: body.col };
    for i in 0..len(b.stmts) {
        if (b.stmts[i].k != K.void) { last = b.stmts[i]; };
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
    // `foreach` starts at element 0 and needs an array, so the array form
    // is offered only for a start of 0 on a receiver not known to be a str,
    // with no jump and no resize of the receiver in the body.
    let can_foreach = cb.op == "<" && arr != "" && lint_int_val(decl.v) == 0 && lint_var_vec(st, arr) && !lint_find(loop.body, "", 7) && !lint_find(loop.body, arr, 8);
    if (can_foreach) {
        lint_warn_at(st, "this index loop can be '" + lint_disp(arr) + ".foreach((e, i) => { ... })'", d);
        lint_fix(st, "3.1", d.line, d.col, lint_disp(iv), lint_disp(arr));
    } else {
        if (lint_find(loop.body, "", 4)) { return 0; };
        lint_warn_at(st, "this index loop can be 'for " + lint_disp(iv) + " in <lo>..<hi> { ... }'", d);
        lint_fix(st, "2.8", d.line, d.col, lint_disp(iv), "");
    };
    0
};

// Rule 3.5: `foreach (i in range(len(a)))` can iterate the array directly.
def lint_short_range(st: LintSt, fe: Foreach) -> long {
    let arr = lint_range_arr(fe.iter);
    if (arr == "" || !lint_var_vec(st, arr) || lint_find(fe.body, "", 7) || lint_find(fe.body, arr, 8)) { return 0; };
    lint_warn_at(st, "this range loop over an array's indices can be '<a>.foreach((e, i) => { ... })'", fe);
    lint_fix(st, "3.5", fe.line, fe.col, lint_disp(arr), "");
    0
};

// The name inside `range(len(a))`, or "".
def lint_range_arr(node: Node) -> str {
    if (node.k != K.call) { return ""; };
    let c: Call = node;
    if (c.callee.k != K.id || len(c.args) != 1) { return ""; };
    let id: Leaf = c.callee;
    if (id.v != "range") { return ""; };
    lint_len_of(c.args[0])
};

// ── --fix: apply the level-2 shortenings to the source ───────────────────
// The rules above say what is shortenable; these say how to write it. A fix
// never changes what the program means, so a fix that cannot find the text
// it expected leaves the line alone and the warning stands. The C copy is
// lint.c (PORTING.md).

def fx_ident(c: long) -> bool {
    (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
};

// Does `line` hold `w` as a whole word at `i`?
def fx_word(line: str, i: long, w: str) -> bool {
    if (i < 0 || i + len(w) > len(line)) { return false; };
    if (line[i:i + len(w)] != w) { return false; };
    let b = i == 0 || !fx_ident(line[i - 1]);
    let a = i + len(w) >= len(line) || !fx_ident(line[i + len(w)]);
    b && a
};

def fx_ws(line: str, i: long) -> long {
    let j = i;
    while (j < len(line) && (line[j] == 32 || line[j] == 9)) { j++; };
    j
};

// The index of `w` as a word at or after `from`, or -1.
def fx_find(line: str, w: str, from: long) -> long {
    for i in from..len(line) {
        if (fx_word(line, i, w)) { return i; };
    };
    -1
};

def fx_strip(s: str) -> str {
    let a = 0;
    while (a < len(s) && (s[a] == 32 || s[a] == 9)) { a++; };
    let b = len(s);
    while (b > a && (s[b - 1] == 32 || s[b - 1] == 9)) { b--; };
    s[a:b]
};

def fx_indent(s: str) -> str {
    let a = 0;
    while (a < len(s) && (s[a] == 32 || s[a] == 9)) { a++; };
    s[:a]
};

// The index of the `cc` matching the `oc` at `i`, skipping quoted text, or
// -1. Comments do not nest brackets that matter in the lines this reads.
def fx_match(line: str, i: long, oc: long, cc: long) -> long {
    let d = 0;
    let q = 0;
    let j = i;
    while (j < len(line)) {
        let c = line[j];
        if (q != 0) {
            if (c == 92) { j = j + 2; }
            else { if (c == q) { q = 0; }; j = j + 1; };
        } else if (c == 34 || c == 39) {
            q = c;
            j = j + 1;
        } else if (c == oc) {
            d++;
            j = j + 1;
        } else if (c == cc) {
            d--;
            if (d == 0) { return j; };
            j = j + 1;
        } else { j = j + 1; };
    };
    -1
};

// Split `s` at its top-level commas.
def fx_split_comma(s: str) -> [str] {
    let out: [str] = [];
    let d = 0;
    let cur = "";
    for i in 0..len(s) {
        let c = s[i];
        if (c == 40 || c == 91 || c == 123) { d++; };
        if (c == 41 || c == 93 || c == 125) { d--; };
        if (c == 44 && d == 0) { out += cur; cur = ""; } else { cur += s[i:i + 1]; };
    };
    out += cur;
    out
};

// 1.1: `name = name op e` -> `name op= e`.
def fx_compound(line: str, name: str, op: str, col: long) -> str {
    let i = col - 1;
    if (!fx_word(line, i, name)) { return line; };
    let j = fx_ws(line, i + len(name));
    if (j >= len(line) || line[j] != 61 || (j + 1 < len(line) && line[j + 1] == 61)) { return line; };
    let k = fx_ws(line, j + 1);
    if (!fx_word(line, k, name)) { return line; };
    let m = fx_ws(line, k + len(name));
    if (m + len(op) > len(line) || line[m:m + len(op)] != op) { return line; };
    let e = fx_ws(line, m + len(op));
    line[:i] + name + " " + op + "= " + line[e:]
};

// 1.2: `name = name op 1` and `name op= 1` -> `name++` / `name--`.
def fx_incdec(line: str, name: str, op: str, col: long) -> str {
    let inc = "++";
    if (op == "-") { inc = "--"; };
    let i = col - 1;
    if (!fx_word(line, i, name)) { return line; };
    let j = fx_ws(line, i + len(name));
    // `name op= 1`
    if (j + 1 < len(line) && line[j] == fx_ident_of(op) && line[j + 1] == 61) {
        let e = fx_ws(line, j + 2);
        if (e < len(line) && line[e] == 49 && (e + 1 >= len(line) || !fx_ident(line[e + 1]))) {
            return line[:i] + name + inc + line[e + 1:];
        };
    };
    // `name = name op 1`
    if (j >= len(line) || line[j] != 61 || (j + 1 < len(line) && line[j + 1] == 61)) { return line; };
    let k = fx_ws(line, j + 1);
    if (!fx_word(line, k, name)) { return line; };
    let m = fx_ws(line, k + len(name));
    if (m + len(op) > len(line) || line[m:m + len(op)] != op) { return line; };
    let e = fx_ws(line, m + len(op));
    if (e < len(line) && line[e] == 49 && (e + 1 >= len(line) || !fx_ident(line[e + 1]))) {
        return line[:i] + name + inc + line[e + 1:];
    };
    line
};

def fx_ident_of(op: str) -> long {
    op[0]
};

// 1.3: `byte_at(A, B)` -> `A[B]`.
def fx_byte_at(line: str, col: long) -> str {
    let i = col - 1;
    if (!fx_word(line, i, "byte_at")) { return line; };
    let o = fx_ws(line, i + 7);
    if (o >= len(line) || line[o] != 40) { return line; };
    let c = fx_match(line, o, 40, 41);
    if (c < 0) { return line; };
    let parts = fx_split_comma(line[o + 1:c]);
    if (len(parts) != 2) { return line; };
    line[:i] + fx_strip(parts[0]) + "[" + fx_strip(parts[1]) + "]" + line[c + 1:]
};

// 1.9: `A == true` / `A != false` -> `A`, and the negated pair -> `!A`.
def fx_bool(line: str, op: str, lit: str, col: long) -> str {
    let i = fx_find(line, op, col - 1);
    if (i < 0) { return line; };
    let j = fx_ws(line, i + len(op));
    if (j + len(lit) > len(line) || line[j:j + len(lit)] != lit) { return line; };
    let neg = (op == "!=") == (lit == "true");
    let a = fx_strip(line[:i]);
    let head = fx_indent(line);
    if (neg) { head + "!" + a + line[j + len(lit):] } else { head + a + line[j + len(lit):] }
};

// The `lo` of `let var = lo;`, or "".
def fx_let_lo(line: str, var: str) -> str {
    let i = fx_find(line, "let", 0);
    if (i < 0) { return ""; };
    let v = fx_find(line, var, i + 3);
    if (v < 0) { return ""; };
    let e = fx_ws(line, v + len(var));
    if (e >= len(line) || line[e] != 61) { return ""; };
    let s = fx_ws(line, e + 1);
    let c = index_of(line, ";");
    if (c < 0 || c < s) { return ""; };
    fx_strip(line[s:c])
};

// The `hi` of `while (var < hi) {`, or "".
def fx_while_hi(line: str, var: str) -> str {
    let i = fx_find(line, "while", 0);
    if (i < 0) { return ""; };
    let o = fx_ws(line, i + 5);
    if (o >= len(line) || line[o] != 40) { return ""; };
    let c = fx_match(line, o, 40, 41);
    if (c < 0) { return ""; };
    let cond = line[o + 1:c];
    let v = fx_find(cond, var, 0);
    if (v < 0) { return ""; };
    let lt = fx_ws(cond, v + len(var));
    if (lt >= len(cond)) { return ""; };
    let s = fx_ws(cond, lt + 1);
    if (cond[lt] == 60 && lt + 1 < len(cond) && cond[lt + 1] == 61) { s = fx_ws(cond, lt + 2); };
    let out = fx_strip(cond[s:]);
    // `while (i <= hi)` keeps hi + 1.
    if (cond[lt] == 60 && lt + 1 < len(cond) && cond[lt + 1] == 61) { out = out + " + 1"; };
    out
};

// Is this line the loop's own step?
def fx_is_step(line: str, var: str) -> bool {
    let t = fx_strip(line);
    if (t == var + "++;") { return true; };
    if (t == var + "--;") { return true; };
    let j = fx_ws(t, len(var));
    if (!fx_word(t, 0, var)) { return false; };
    if (j + 1 < len(t) && (t[j] == 43 || t[j] == 45) && t[j + 1] == 61) { return true; };
    if (j < len(t) && t[j] == 61) {
        let k = fx_ws(t, j + 1);
        if (fx_word(t, k, var)) {
            let m = fx_ws(t, k + len(var));
            if (m < len(t) && (t[m] == 43 || t[m] == 45)) { return true; };
        };
    };
    false
};

def fx_drop(a: [str], k: long) -> [str] {
    a[:k] + a[k + 1:]
};

def fx_join(a: [str]) -> str {
    let out = "";
    let i = 0;
    while (i < len(a)) { out = out + a[i] + "\n"; i++; };
    out
};

// `arr[var]` -> the element name.
def fx_sub_index(line: str, arr: str, var: str, el: str) -> str {
    let i = 0;
    let out = "";
    while (i < len(line)) {
        if (fx_word(line, i, arr)) {
            let j = fx_ws(line, i + len(arr));
            if (j < len(line) && line[j] == 91) {
                let k = fx_ws(line, j + 1);
                if (fx_word(line, k, var)) {
                    let m = fx_ws(line, k + len(var));
                    if (m < len(line) && line[m] == 93) {
                        out += el;
                        i = m + 1;
                        continue;
                    };
                };
            };
        };
        out += line[i:i + 1];
        i++;
    };
    out
};

// 2.8/3.1: `let var = lo; while (var < hi) { B; var++; };` at line `ln`.
def fx_loop(rule: str, arr: str, var: str, ln: long, lines: [str]) -> [str] {
    if (ln < 1 || ln >= len(lines)) { return lines; };
    let dline = lines[ln - 1];
    let wline = lines[ln];
    // A one-line `while (c) { B; i++; };` has its body on the header line;
    // the close scan below would run past it.
    let wt = fx_strip(wline);
    if (len(wt) == 0 || wt[len(wt) - 1:len(wt)] != "{") { return lines; };
    let lo = fx_let_lo(dline, var);
    if (lo == "") { return lines; };
    let hi = fx_while_hi(wline, var);
    if (hi == "") { return lines; };
    let indent = fx_indent(dline);
    let close = -1;
    let j = ln + 1;
    while (j < len(lines)) {
        if (fx_strip(lines[j]) == "};" && fx_indent(lines[j]) == indent) { close = j; break; };
        j = j + 1;
    };
    if (close < 0) { return lines; };
    let body: [str] = [];
    j = ln + 1;
    while (j < close) { body += lines[j]; j = j + 1; };
    let k = len(body) - 1;
    while (k >= 0 && fx_strip(body[k]) == "") { k = k - 1; };
    if (k < 0 || !fx_is_step(body[k], var)) { return lines; };
    body = fx_drop(body, k);
    if (rule == "3.1") {
        let el = "e";
        if (fx_find(fx_join(body), "e", 0) >= 0) { el = "el"; };
        let nb: [str] = [];
        j = 0;
        while (j < len(body)) { nb += fx_sub_index(body[j], arr, var, el); j = j + 1; };
        body = nb;
        let keep = fx_find(fx_join(body), var, 0) >= 0;
        let params = "(" + el + ")";
        if (keep) { params = "(" + el + ", " + var + ")"; };
        lines = lines[:ln - 1] + [indent + arr + ".foreach(" + params + " => {"] + body + [indent + "});"] + lines[close + 1:];
    } else {
        lines = lines[:ln - 1] + [indent + "for " + var + " in " + lo + ".." + hi + " {"] + body + [indent + "};"] + lines[close + 1:];
    };
    lines
};

// 3.5: `foreach (i in range(len(a))) { B }` -> `a.foreach((e, i) => { B })`.
def fx_range(arr: str, ln: long, lines: [str]) -> [str] {
    if (ln < 1 || ln > len(lines)) { return lines; };
    let h = lines[ln - 1];
    let ht = fx_strip(h);
    if (len(ht) == 0 || ht[len(ht) - 1:len(ht)] != "{") { return lines; };
    let indent = fx_indent(h);
    let i = fx_find(h, "foreach", 0);
    if (i < 0) { return lines; };
    let o = fx_ws(h, i + 7);
    if (o >= len(h) || h[o] != 40) { return lines; };
    let c = fx_match(h, o, 40, 41);
    if (c < 0) { return lines; };
    let inner = fx_strip(h[o + 1:c]);
    let inw = fx_find(inner, "in", 0);
    if (inw < 0) { return lines; };
    let var = fx_strip(inner[:inw]);
    if (var == "") { return lines; };
    // the body: to the matching `};`
    let close = -1;
    let j = ln;
    while (j < len(lines)) {
        if (fx_strip(lines[j]) == "};" && fx_indent(lines[j]) == indent) { close = j; break; };
        j = j + 1;
    };
    if (close < 0) { return lines; };
    let body: [str] = [];
    j = ln;
    while (j < close) { body += lines[j]; j = j + 1; };
    let el = "e";
    if (fx_find(fx_join(body), "e", 0) >= 0) { el = "el"; };
    let nb: [str] = [];
    j = 0;
    while (j < len(body)) { nb += fx_sub_index(body[j], arr, var, el); j = j + 1; };
    body = nb;
    let keep = fx_find(fx_join(body), var, 0) >= 0;
    let params = "(" + el + ")";
    if (keep) { params = "(" + el + ", " + var + ")"; };
    lines = lines[:ln - 1] + [indent + arr + ".foreach(" + params + " => {"] + body + [indent + "});"] + lines[close + 1:];
    lines
};

// `x = A;` -> `x|A`, or "" when it is not a plain assignment to a name.
def fx_assign(s: str) -> str {
    let t = fx_strip(s);
    let e = fx_find(t, "=", 0);
    if (e < 0) { return ""; };
    if (e > 0 && (t[e - 1] == 33 || t[e - 1] == 60 || t[e - 1] == 62 || t[e - 1] == 61)) { return ""; };
    if (e + 1 < len(t) && t[e + 1] == 61) { return ""; };
    let name = fx_strip(t[:e]);
    if (!fx_is_name(name)) { return ""; };
    let v = fx_strip(t[e + 1:]);
    if (len(v) > 0 && v[len(v) - 1:len(v)] == ";") { v = fx_strip(v[:len(v) - 1]); };
    if (v == "") { return ""; };
    name + "|" + v
};

def fx_is_name(s: str) -> bool {
    if (len(s) == 0) { return false; };
    let c0 = s[0];
    if (!((c0 >= 97 && c0 <= 122) || (c0 >= 65 && c0 <= 90) || c0 == 95)) { return false; };
    let i = 1;
    while (i < len(s)) { if (!fx_ident(s[i])) { return false; }; i++; };
    true
};

def fx_pipe_name(s: str) -> str {
    let i = index_of(s, "|");
    if (i < 0) { "" } else { s[:i] }
};

def fx_pipe_val(s: str) -> str {
    let i = index_of(s, "|");
    if (i < 0) { "" } else { s[i + 1:] }
};

def fx_semi(tail: str) -> str {
    if (len(tail) > 0 && tail[0] == 59) { ";" } else { "" }
};

// The position fx_scan last matched: 1-based line, 0-based column.
let fx_sline: long = 0;
let fx_scol: long = 0;

// Find the `cc` matching the `oc` at (ln, col), scanning whole lines. The
// answer is in fx_sline/fx_scol; false when there is none.
def fx_scan(lines: [str], ln: long, col: long, oc: long, cc: long) -> bool {
    let d = 0;
    let q = 0;
    let l = ln;
    let j = col;
    while (l <= len(lines)) {
        let line = lines[l - 1];
        while (j < len(line)) {
            let c = line[j];
            if (q != 0) {
                if (c == 92) { j = j + 2; continue; };
                if (c == q) { q = 0; };
                j = j + 1;
            } else if (c == 34 || c == 39) {
                q = c;
                j = j + 1;
            } else if (c == oc) {
                d++;
                j = j + 1;
            } else if (c == cc) {
                d--;
                if (d == 0) { fx_sline = l; fx_scol = j; return true; };
                j = j + 1;
            } else { j = j + 1; };
        };
        l = l + 1;
        j = 0;
    };
    false
};

// `s` up to a `//` comment (quotes respected).
def fx_nocomment(s: str) -> str {
    let q = 0;
    let i = 0;
    while (i < len(s)) {
        let c = s[i];
        if (q != 0) {
            if (c == 92) { i += 2; continue; };
            if (c == q) { q = 0; };
            i++;
        } else if (c == 34 || c == 39) {
            q = c;
            i++;
        } else if (c == 47 && i + 1 < len(s) && s[i + 1] == 47) {
            return s[:i];
        } else { i++; };
    };
    s
};

// The text between just after (l1,c1) and just before (l2,c2), lines joined
// with a space. A block's value is one statement, so joining is safe here.
def fx_text(lines: [str], l1: long, c1: long, l2: long, c2: long) -> str {
    if (l1 == l2) { return fx_strip(fx_nocomment(lines[l1 - 1][c1 + 1:c2])); };
    let out = fx_strip(fx_nocomment(lines[l1 - 1][c1 + 1:]));
    let k = l1 + 1;
    while (k < l2) { out = out + " " + fx_strip(fx_nocomment(lines[k - 1])); k = k + 1; };
    fx_strip(out + " " + fx_strip(fx_nocomment(lines[l2 - 1][:c2])))
};

// 2.1/2.3: an `if`/`else` written on one line. `b` is the 2.1 case (inv,
// del, both); a multi-line arm is left for a later pass.
def fx_if_line(rule: str, b: str, ln: long, lines: [str]) -> [str] {
    if (ln < 1 || ln > len(lines)) { return lines; };
    let line = lines[ln - 1];
    let i = fx_find(line, "if", 0);
    if (i < 0) { return lines; };
    // Dropping or inverting an `else if` arm changes which branch runs.
    let pre = fx_strip(line[:i]);
    if (len(pre) >= 4 && pre[len(pre) - 4:len(pre)] == "else") { return lines; };
    let o = fx_ws(line, i + 2);
    if (o >= len(line) || line[o] != 40) { return lines; };
    let c = fx_match(line, o, 40, 41);
    if (c < 0) { return lines; };
    let cond = fx_strip(line[o + 1:c]);
    let b1 = fx_ws(line, c + 1);
    if (b1 >= len(line) || line[b1] != 123) { return lines; };
    let indent = fx_indent(line);
    let e1 = fx_match(line, b1, 123, 125);
    if (e1 < 0 && rule == "2.3") {
        // `if (C) { x = a; } else { x = b; }` spread over lines
        if (!fx_scan(lines, ln, b1, 123, 125)) { return lines; };
        let l1 = fx_sline;
        let c1 = fx_scol;
        let cline = lines[l1 - 1];
        let rest = cline[c1 + 1:];
        let el = fx_find(rest, "else", 0);
        if (el < 0) { return lines; };
        let b2r = fx_ws(rest, el + 4);
        if (b2r >= len(rest) || rest[b2r] != 123) { return lines; };
        let b2 = c1 + 1 + b2r;
        if (!fx_scan(lines, l1, b2, 123, 125)) { return lines; };
        let l2 = fx_sline;
        let c2 = fx_scol;
        let av = fx_assign(fx_text(lines, ln, b1, l1, c1));
        let bv = fx_assign(fx_text(lines, l1, b2, l2, c2));
        if (av == "" || bv == "" || fx_pipe_name(av) != fx_pipe_name(bv)) { return lines; };
        let composed = indent + fx_pipe_name(av) + " = " + cond + " ? " + fx_pipe_val(av) + " : " + fx_pipe_val(bv) + ";";
        lines = lines[:ln - 1] + [composed] + lines[l2:];
        return lines;
    };
    if (e1 < 0) {
        // the then block runs on to a later line; its close must be a plain
        // `}` (or `};`) or a plain `} else {` -- never a `} else if`
        let j = ln + 1;
        while (j <= len(lines)) {
            let t = fx_strip(lines[j - 1]);
            if (fx_indent(lines[j - 1]) == indent && t[:1] == "}") { break; };
            j = j + 1;
        };
        if (j > len(lines)) { return lines; };
        let t = fx_strip(lines[j - 1]);
        if (rule == "2.1" && b == "inv" && t[:8] == "} else {") {
            lines[ln - 1] = indent + "if (!(" + cond + ")) {";
            lines = lines[:ln] + lines[j:];
        } else if (rule == "2.1" && b == "del" && (t == "}" || t == "};")) {
            lines = lines[:ln - 1] + lines[j:];
        };
        return lines;
    };
    let then = fx_strip(fx_nocomment(line[b1 + 1:e1]));
    let after = line[e1 + 1:];
    let el = fx_ws(after, 0);
    if (el < len(after) && fx_word(after, el, "else")) {
        let b2 = fx_ws(after, el + 4);
        if (b2 >= len(after) || after[b2] != 123) { return lines; };
        let e2 = fx_match(after, b2, 123, 125);
        if (e2 < 0) {
            // `if (C) { } else {` with the else body on the lines that follow
            if (rule == "2.1" && b == "inv" && then == "") {
                lines[ln - 1] = indent + "if (!(" + cond + ")) {";
            };
            return lines;
        };
        let els = fx_strip(fx_nocomment(after[b2 + 1:e2]));
        let tail = fx_strip(after[e2 + 1:]);
        if (rule == "2.3") {
            let av = fx_assign(then);
            let bv = fx_assign(els);
            if (av == "" || bv == "" || fx_pipe_name(av) != fx_pipe_name(bv)) { return lines; };
            lines[ln - 1] = indent + fx_pipe_name(av) + " = " + cond + " ? " + fx_pipe_val(av) + " : " + fx_pipe_val(bv) + ";";
        } else if (rule == "2.1") {
            if (tail != "" && tail != ";") { return lines; };
            if (b == "inv" && then == "" && els != "") {
                lines[ln - 1] = indent + "if (!(" + cond + ")) { " + els + " }" + fx_semi(tail);
            } else if (b == "both" && then == "" && els == "") {
                lines = fx_drop(lines, ln - 1);
            } else if (b == "del" && then != "" && els == "") {
                lines[ln - 1] = indent + "if (" + cond + ") { " + then + " }" + fx_semi(tail);
            };
        };
    } else if (rule == "2.1" && b == "del" && then == "") {
        // no else on this line: the whole `if` does nothing, and nothing
        // else may share the line
        let tail = fx_strip(line[e1 + 1:]);
        if (tail == "" || tail == ";") { lines = fx_drop(lines, ln - 1); };
    };
    lines
};


// 3.6: drop the unused element parameter and put the element name on the
// `arr[ix]` the body kept writing.
def fx_foreach_elem(arr: str, idx: str, ln: long, col: long, lines: [str]) -> [str] {
    if (ln < 1 || ln > len(lines)) { return lines; };
    let line = lines[ln - 1];
    let i = fx_find(line, "foreach", 0);
    if (i < 0) { return lines; };
    let o = fx_ws(line, i + 7);
    if (o >= len(line) || line[o] != 40) { return lines; };
    // the params are the closure's own parens inside the call's, and the
    // call's own `)` is on the `});` line, so match the inner one
    let p = fx_ws(line, o + 1);
    if (p >= len(line) || line[p] != 40) { return lines; };
    let c = fx_match(line, p, 40, 41);
    if (c < 0) { return lines; };
    let ht = fx_strip(line);
    if (len(ht) == 0 || ht[len(ht) - 1:len(ht)] != "{") {
        // a one-line `X.foreach((_el, i) => { B });`: rewrite text in place
        let ob = index_of(line[c:], "{");
        let cb = last_index_of(line, "}");
        if (ob < 0 || cb < 0 || cb <= c + ob) { return lines; };
        ob = c + ob;
        let body = line[ob + 1:cb];
        let el = "e";
        if (fx_find(body, "e", 0) >= 0) { el = "el"; };
        let nb = fx_sub_index(body, arr, idx, el);
        if (nb == body) { return lines; };
        let keep = fx_find(nb, idx, 0) >= 0;
        let params = "(" + el + ")";
        if (keep) { params = "(" + el + ", " + idx + ")"; };
        lines[ln - 1] = line[:p] + params + line[c + 1:ob + 1] + nb + line[cb:];
        return lines;
    };
    let indent = fx_indent(line);
    let close = -1;
    let j = ln + 1;
    while (j <= len(lines)) {
        if (fx_strip(lines[j - 1]) == "});" && fx_indent(lines[j - 1]) == indent) { close = j; break; };
        j = j + 1;
    };
    if (close < 0) { return lines; };
    let body: [str] = [];
    j = ln + 1;
    while (j < close) { body += lines[j - 1]; j = j + 1; };
    let el = "e";
    if (fx_find(fx_join(body), "e", 0) >= 0) { el = "el"; };
    let nb: [str] = [];
    let hit = false;
    j = 0;
    while (j < len(body)) {
        let x = fx_sub_index(body[j], arr, idx, el);
        if (x != body[j]) { hit = true; };
        nb += x;
        j = j + 1;
    };
    if (!hit) { return lines; };
    let keep = fx_find(fx_join(nb), idx, 0) >= 0;
    let params = "(" + el + ")";
    if (keep) { params = "(" + el + ", " + idx + ")"; };
    lines[ln - 1] = line[:p] + params + line[c + 1:];
    lines = lines[:ln] + nb + lines[close - 1:];
    lines
};

def fx_let_name(line: str) -> str {
    let i = fx_find(line, "let", 0);
    if (i < 0) { return ""; };
    let j = fx_ws(line, i + 3);
    let k = j;
    while (k < len(line) && fx_ident(line[k])) { k = k + 1; };
    if (k == j) { return ""; };
    let name = line[j:k];
    if (!fx_is_name(name)) { return ""; };
    name
};

def fx_let_init(line: str) -> str {
    let i = fx_find(line, "let", 0);
    if (i < 0) { return ""; };
    let e = index_of(line[i:], "=");
    if (e < 0) { return ""; };
    e = i + e;
    let s = fx_ws(line, e + 1);
    let c = index_of(line, ";");
    if (c < 0 || c < s) { return ""; };
    fx_strip(line[s:c])
};

// 2.2: `let x = a; if (c) { x = b; };` -> `let x = c ? b : a;`.
def fx_let_cond(ln: long, lines: [str]) -> [str] {
    if (ln < 1 || ln >= len(lines)) { return lines; };
    let dline = lines[ln - 1];
    let name = fx_let_name(dline);
    let init = fx_let_init(dline);
    if (name == "" || init == "") { return lines; };
    let ifline = lines[ln];
    let i = fx_find(ifline, "if", 0);
    if (i < 0) { return lines; };
    let o = fx_ws(ifline, i + 2);
    if (o >= len(ifline) || ifline[o] != 40) { return lines; };
    let c = fx_match(ifline, o, 40, 41);
    if (c < 0) { return lines; };
    let cond = fx_strip(ifline[o + 1:c]);
    let indent = fx_indent(dline);
    let b1 = fx_ws(ifline, c + 1);
    if (b1 >= len(ifline) || ifline[b1] != 123) { return lines; };
    if (!fx_scan(lines, ln + 1, b1, 123, 125)) { return lines; };
    let l1 = fx_sline;
    let c1 = fx_scol;
    let av = fx_assign(fx_text(lines, ln + 1, b1, l1, c1));
    if (av == "" || fx_pipe_name(av) != name) { return lines; };
    let tail = fx_strip(lines[l1 - 1][c1 + 1:]);
    if (tail != "" && tail != ";") { return lines; };
    lines = lines[:ln - 1] + [indent + "let " + name + " = " + cond + " ? " + fx_pipe_val(av) + " : " + init + ";"] + lines[l1:];
    lines
};

// 1.4: `s[E:E + 1]` -> `s[E]`; the `[` is at (ln, col).
def fx_slice_index(line: str, col: long) -> str {
    let i = col - 1;
    if (i < 0 || i >= len(line) || line[i] != 91) { return line; };
    let c = fx_match(line, i, 91, 93);
    if (c < 0) { return line; };
    let inner = line[i + 1:c];
    let k = index_of(inner, ":");
    if (k < 0) { return line; };
    let lo = fx_strip(inner[:k]);
    if (lo == "") { return line; };
    line[:i] + "[" + lo + "]" + line[c + 1:]
};

// 1.5: `ord(s[E:E + 1])` -> `s[E]`; the `ord` is at (ln, col).
def fx_ord_index(line: str, col: long) -> str {
    let i = col - 1;
    if (!fx_word(line, i, "ord")) { return line; };
    let o = fx_ws(line, i + 3);
    if (o >= len(line) || line[o] != 40) { return line; };
    let c = fx_match(line, o, 40, 41);
    if (c < 0) { return line; };
    let inner = line[o + 1:c];
    let br = index_of(inner, "[");
    if (br < 0 || inner[len(inner) - 1:len(inner)] != "]") { return line; };
    let k = index_of(inner, ":");
    if (k < 0) { return line; };
    let lo = fx_strip(inner[br + 1:k]);
    if (lo == "") { return line; };
    line[:i] + inner[:br] + "[" + lo + "]" + line[c + 1:]
};

// The fixers, by rule. A rule with no case here stays a warning.
def fx_one(rule: str, a: str, b: str, ln: long, col: long, lines: [str]) -> [str] {
    if (ln < 1 || ln > len(lines)) { return lines; };
    if (rule == "1.1") { lines[ln - 1] = fx_compound(lines[ln - 1], a, b, col); }
    else if (rule == "1.2") { lines[ln - 1] = fx_incdec(lines[ln - 1], a, b, col); }
    else if (rule == "1.3") { lines[ln - 1] = fx_byte_at(lines[ln - 1], col); }
    else if (rule == "1.9") { lines[ln - 1] = fx_bool(lines[ln - 1], a, b, col); }
    else if (rule == "1.4") { lines[ln - 1] = fx_slice_index(lines[ln - 1], col); }
    else if (rule == "1.5") { lines[ln - 1] = fx_ord_index(lines[ln - 1], col); }
    else if (rule == "2.8") { lines = fx_loop(rule, b, a, ln, lines); }
    else if (rule == "3.1") { lines = fx_loop(rule, b, a, ln, lines); }
    else if (rule == "3.5") { lines = fx_range(a, ln, lines); }
    else if (rule == "2.1") { lines = fx_if_line(rule, b, ln, lines); }
    else if (rule == "2.3") { lines = fx_if_line(rule, b, ln, lines); }
    else if (rule == "2.2") { lines = fx_let_cond(ln, lines); }
    else if (rule == "3.6") { lines = fx_foreach_elem(a, b, ln, col, lines); };
    lines
};

// The file id a spliced-program line came from (origin_at's own math).
def fx_fid(line: long, nmap: long, fmap: [long]) -> long {
    if (nmap == 0 || line < 1) { return 0; };
    let k = line;
    if (k > nmap) { k = nmap; };
    fmap[k - 1]
};

def fx_local(line: long, nmap: long, lmap: [long]) -> long {
    if (nmap == 0 || line < 1) { return line; };
    let k = line;
    if (k > nmap) { k = nmap; };
    lmap[k - 1] + line - k
};

// A wrapping rule runs before the expression rules on the line it wraps
// (2.3 reads its arms as assignments, and 1.1 would have rewritten them
// first), and later positions before earlier ones so an edit never moves
// the text a later fix anchors on.
def fx_prio(rule: str) -> long {
    if (rule == "2.1" || rule == "2.2" || rule == "2.3" || rule == "2.8" || rule == "3.1" || rule == "3.5" || rule == "3.6") { 0 } else { 1 }
};

def fx_before(x: LintFix, y: LintFix, nmap: long, lmap: [long]) -> bool {
    let xp = fx_prio(x.rule);
    let yp = fx_prio(y.rule);
    if (xp != yp) { return xp < yp; };
    let xl = fx_local(x.line, nmap, lmap);
    let yl = fx_local(y.line, nmap, lmap);
    if (xl != yl) { return xl > yl; };
    x.col > y.col
};

// Sort descending by (line, col): a fix never moves the text a later one
// anchors on.
def fx_sort(a: [LintFix], nmap: long, lmap: [long]) -> long {
    for i in 1..len(a) {
        let cur = a[i];
        let j = i - 1;
        while (j >= 0 && fx_before(cur, a[j], nmap, lmap)) { a[j + 1] = a[j]; j = j - 1; };
        a[j + 1] = cur;
    };
    0
};

def fx_has(a: [long], v: long) -> bool {
    let i = 0;
    while (i < len(a)) { if (a[i] == v) { return true; }; i++; };
    false
};

// Rewrite one file's fixes in place.
def fx_file(fid: long, fixes: [LintFix], src: str, nmap: long, fmap: [long], lmap: [long]) -> str {
    let lines = split(src, "\n");
    let mine: [LintFix] = [];
    let i = 0;
    while (i < len(fixes)) {
        let f = fixes[i];
        if (fx_fid(f.line, nmap, fmap) == fid) { mine += f; };
        i++;
    };
    fx_sort(mine, nmap, lmap);
    i = 0;
    while (i < len(mine)) {
        let f = mine[i];
        lines = fx_one(f.rule, f.a, f.b, fx_local(f.line, nmap, lmap), f.col, lines);
        i++;
    };
    let out = "\n".join(lines);
    // split drops a trailing empty field, so put the file's own final
    // newline back.
    if (len(src) > 0 && src[len(src) - 1:len(src)] == "\n" && (len(out) == 0 || out[len(out) - 1:len(out)] != "\n")) {
        out = out + "\n";
    };
    out
};

// The file ids a fix list names, in first-seen order.
def lint_fix_ids(fixes: [LintFix], fmap: [long]) -> [long] {
    let nmap = len(fmap);
    let fids: [long] = [];
    fixes.foreach((e) => {
        let fid = fx_fid(e.line, nmap, fmap);
        if (!fx_has(fids, fid)) { fids += fid; };
    });
    fids
};

// One file's fixes applied to its own text: the driver reads and writes the
// file, the linter owns what changes.
def lint_fix_text(fid: long, fixes: [LintFix], fmap: [long], lmap: [long], src: str) -> str {
    fx_file(fid, fixes, src, len(fmap), fmap, lmap)
};

// The statements from index `from` on, walked without copying the list.
def lint_find_from(nodes: [Node], from: long, name: str, mask: long) -> bool {
    for i in from..len(nodes) {
        if (lint_find(nodes[i], name, mask)) { return true; };
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
        let c = digits[i];
        ok = c == '0' || c == '_';
        i++;
    };
    ok
};

// An `if` gives its arms' values only when it has both arms.
def lint_if(st: LintSt, node: If, used: bool) -> long {
    lint_node(st, node.cond, true);
    let arms = used && node.has_else;
    lint_node(st, node.then, arms);
    // An `else if` is an arm of the chain, not an arm of its own: its empty
    // then cannot be dropped (that would make the next `else` the head).
    let wc = st.chain;
    if (node.els.k == K.kw_if) { st.chain = 1; };
    lint_node(st, node.els, arms);
    st.chain = wc;
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
        i++;
    };
    let body: Block = node.body;
    lint_stmts(st, body.stmts, true, false)
};

def lint_decl(st: LintSt, node: Decl) -> long {
    let v = node.v;
    if (node.kind == "def") {
        lint_note(st, node.name, "def", node.line, node.col, false, false, false, false);
        lint_def_body(st, node.name, v)
    } else {
        lint_note(st, node.name, node.kind, node.line, node.col, lint_scal(node.typ, v), lint_fresh(v), lint_strheld(node.typ, v), lint_vec(node.typ, v));
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
        if (lint_var_scal(st, tid.v)) {
            lint_warn_at(st, "'" + d + " " + op + "= 1' can be written '" + d + rs + "'", node);
        };
    };
    0
};

// A record or map literal giving a key twice keeps the last value; the
// earlier one is computed for nothing.
def lint_lit(st: LintSt, node: RecLit, what: str, kind: str) -> long {
    let keys: [str] = node.keys;
    lint_list(st, node.vals);
    keys.foreach((e, i) => {
        let key = e;
        if (key != "..." && lint_seen(keys, i)) {
            lint_warn_at(st, "duplicate " + what + " '" + key + "' in a " + kind + " literal; the last one wins", node);
        };
    });
    0
};

def lint_seen(keys: [str], i: long) -> bool {
    let key = keys[i];
    let found = false;
    let j = 0;
    while (!found && j < i) {
        found = keys[j] == key;
        j++;
    };
    found
};

// Every noted binding: read is fine; grown is fine unless the growth is
// only its own (a number's, or a fresh array's never reassigned).
def lint_vars(st: LintSt) -> long {
    let flags = st.flags;
    foreach (v in st.vars) {
        if (!(v.top)) {
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
            tdi++;
        };
    };
    lint_report(st, t)
};

def lint_tw_list(t: LintTy, nodes: [Node]) -> long {
    nodes.foreach((e) => {
        lint_tw(t, e);
    });
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
    ps.foreach((e) => {
        lint_root(t, e, line, col, "");
    });
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
    ts.foreach((e) => {
        parts += lint_tk(t, e, rec, parent);
    });
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
    for i in 0..len(fs) {
        let f = fs[i];
        parts += f.name + ":" + lint_tk(t, f.typ, rec, me);
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
    let me = rec ? lint_occ(t, ty, parent) : parent;
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
    ts.foreach((e) => {
        let m = e;
        let ai = lint_union_alias(t, m);
        if (ai >= 0) {
            let union: TList = t.atyps[ai];
            t.abusy[ai] = true;
            lint_tk_members(t, union, false, me, parts);
            t.abusy[ai] = false;
        } else {
            parts += lint_tk(t, m, rec, me);
        };
    });
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
    xs.foreach((e) => {
        let x = e;
        let j = len(out);
        out += x;
        while (j > 0 && x < out[j - 1]) {
            out[j] = out[j - 1];
            j = j - 1;
        };
        out[j] = x;
    });
    let res: [str] = [];
    out.foreach((e, k) => {
        if (k == 0 || e != out[k - 1]) {
            res += e;
        };
    });
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
        i++;
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
        i++;
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
    all.foreach((e) => {
        let w = e;
        let n = len(out);
        if (n == 0 || lint_before(out[n - 1], w)) {
            out += w;
        };
    });
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
                i++;
            } else {
                out += b[j];
                j++;
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
