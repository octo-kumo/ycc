// tags.y — the compiler's one vocabulary of tags.
//
// A tagged union's discriminant was a str, so `node.k == "call"` compiled
// to a call to y_str_eq. String equality was 23% of every instruction ycc
// executed, and this single test was most of it: the 82 names below are
// compared some 35 million times per self-compile, each time paying a call,
// two pushed arguments and a byte loop over a handful of bytes. A tag is a
// number here, so the same test is an integer compare against a word in
// this table.
//
// One table for every tag the compiler tests: the Node and Type unions
// (parser.y), the assembler's operand forms (enc64.y), pkg's entry kinds
// (pkg.y) and the lexer's token kinds. Sharing the table means a name can
// never quietly mean two things in two unions and no number is ever reused.
// A tag is only ever compared with another tag of the same field, so
// vocabularies that happen to share a name ("str" is both a Node kind and
// nothing else; "s" is pkg's) share a number harmlessly.
//
// Four of the names are Y keywords and cannot be record fields; they are
// spelled kw_* here and nothing outside this file knows, because every use
// goes through K. Numbers are positions in one alphabetical list, so a new
// tag goes at the end and no existing number moves.
//
// K is the only place a tag's number is written. KTAGS is the same list in
// the same order, for the four places a tag reaches a diagnostic text;
// `ktag` reads it and `tags_agree` (run once at startup, by ycc.y) refuses
// to compile if the two tables have drifted.

const K = {
    a: 1, addr: 2, array: 3, arrrep: 4, assign: 5, bad: 6, bin: 7, block: 8,
    bool: 9, bstr: 10, call: 11, char: 12, decl: 13, deref: 14, diff: 15,
    dot: 16, dotassign: 17, err: 18, file: 19, kw_for: 20, kw_foreach: 21,
    forrange: 22, fs: 23, func: 24, git: 25, h: 26, id: 27, idxassign: 28,
    kw_if: 29, imm: 30, incdec: 31, ind: 32, index: 33, kw: 34, lbl: 35,
    loc: 36, map: 37, matchend: 38, mem: 39, narrow: 40, num: 41,
    opassign: 42, optarg: 43, path: 44, rec: 45, rectest: 46, reg: 47,
    ret: 48, rev: 49, s: 50, slice: 51, sliceassign: 52, store: 53, str: 54,
    t: 55, tarr: 56, tarrfix: 57, tbool: 58, tbyte: 59, terr: 60,
    tfloat: 61, tfunc: 62, tinfer: 63, tlong: 64, tmap: 65, tname: 66,
    tnone: 67, topt: 68, tparams: 69, tpat: 70, tpend: 71, tptr: 72,
    trec: 73, tref: 74, tstr: 75, tunion: 76, tunk: 77, tvoid: 78,
    typedef: 79, un: 80, void: 81, kw_while: 82
};

const KTAGS: [str] = [
    "a", "addr", "array", "arrrep", "assign", "bad", "bin", "block", "bool",
    "bstr", "call", "char", "decl", "deref", "diff", "dot", "dotassign",
    "err", "file", "for", "foreach", "forrange", "fs", "func", "git", "h",
    "id", "idxassign", "if", "imm", "incdec", "ind", "index", "kw", "lbl",
    "loc", "map", "matchend", "mem", "narrow", "num", "opassign", "optarg",
    "path", "rec", "rectest", "reg", "ret", "rev", "s", "slice",
    "sliceassign", "store", "str", "t", "tarr", "tarrfix", "tbool", "tbyte",
    "terr", "tfloat", "tfunc", "tinfer", "tlong", "tmap", "tname", "tnone",
    "topt", "tparams", "tpat", "tpend", "tptr", "trec", "tref", "tstr",
    "tunion", "tunk", "tvoid", "typedef", "un", "void", "while"
];

// The name of a tag, for a diagnostic. The argument is always a tag the
// compiler produced itself, so it is in range.
def ktag(n: long) -> str {
    KTAGS[n - 1]
};

// ── how deep the recursive walks may nest ────────────────────────────────
// Every walk that follows the tree -- the parser, the renamer, the checker,
// the emitter -- used to recurse as deep as the input nested, with nothing
// counting: deep nesting ended in a raw SIGSEGV when the stack ran out, and
// at a DIFFERENT depth in each copy (with the default 8 MB stack, 5397
// levels for ycc against 7975 for cycc on `1+1+1+...` or `!!!...`, and 8912
// against 12661 on `((((...))))`). One limit, here, so the two copies
// cannot disagree about where the cliff is (as with the tag tables below:
// MAX_NEST_agree is the same kind of check).
//
// 1000 is Python's own default recursion limit, five times below the
// shallowest cliff measured here, and far deeper than any program that
// means anything: a thousand nested parens, or a thousand terms in one
// expression. Past it the compiler stops with the position that was too
// deep instead of dying.
const MAX_NEST = 1000;

// How deep the walk in hand is. A walk's entry counts it and its one return
// path counts it back (a wrapper, so no early return leaks a level), and the
// counter needs no reset between phases because every walk that enters also
// leaves.
//
// The count and the test are written out at each of those entries rather than
// called: it runs once per node of every program, in four phases, and a call
// per node cost up to 0.7% of every compile. Only the failure is a call.
// `nest` is a global, so the test is a load, an add, a compare and a store.
let nest = 0;

def nest_reset() { nest = 0; 0 };

// Past the limit: say what was too deep and stop. `what` names the walk
// ("an expression", "a type", "a statement"), since a program can be too deep
// in more than one way.
def too_deep(what: str, line: long, col: long) -> long {
    puts(tostring(line) + ":" + tostring(col) + ": error: " + what +
         " nests deeper than " + tostring(MAX_NEST) + ", the compiler's limit");
    exit(1);
    0
};

// K and KTAGS are written out twice because a record has fields named by
// name and an array is indexed by number, and Y has nothing that reads a
// record's field table. This is the check that the two agree: ycc.y runs it
// once at startup and treats a disagreement as the bug it is.
def tags_agree() -> bool {
    ktag(K.a) == "a" && ktag(K.addr) == "addr" && ktag(K.array) == "array" &&
    ktag(K.arrrep) == "arrrep" && ktag(K.assign) == "assign" && ktag(K.bad) == "bad" &&
    ktag(K.bin) == "bin" && ktag(K.block) == "block" && ktag(K.bool) == "bool" &&
    ktag(K.bstr) == "bstr" && ktag(K.call) == "call" && ktag(K.char) == "char" &&
    ktag(K.decl) == "decl" && ktag(K.deref) == "deref" && ktag(K.diff) == "diff" &&
    ktag(K.dot) == "dot" && ktag(K.dotassign) == "dotassign" && ktag(K.err) == "err" &&
    ktag(K.file) == "file" && ktag(K.kw_for) == "for" && ktag(K.kw_foreach) == "foreach" &&
    ktag(K.forrange) == "forrange" && ktag(K.fs) == "fs" && ktag(K.func) == "func" &&
    ktag(K.git) == "git" && ktag(K.h) == "h" && ktag(K.id) == "id" &&
    ktag(K.idxassign) == "idxassign" && ktag(K.kw_if) == "if" && ktag(K.imm) == "imm" &&
    ktag(K.incdec) == "incdec" && ktag(K.ind) == "ind" && ktag(K.index) == "index" &&
    ktag(K.kw) == "kw" && ktag(K.lbl) == "lbl" && ktag(K.loc) == "loc" &&
    ktag(K.map) == "map" && ktag(K.matchend) == "matchend" && ktag(K.mem) == "mem" &&
    ktag(K.narrow) == "narrow" && ktag(K.num) == "num" && ktag(K.opassign) == "opassign" &&
    ktag(K.optarg) == "optarg" && ktag(K.path) == "path" && ktag(K.rec) == "rec" &&
    ktag(K.rectest) == "rectest" && ktag(K.reg) == "reg" && ktag(K.ret) == "ret" &&
    ktag(K.rev) == "rev" && ktag(K.s) == "s" && ktag(K.slice) == "slice" &&
    ktag(K.sliceassign) == "sliceassign" && ktag(K.store) == "store" && ktag(K.str) == "str" &&
    ktag(K.t) == "t" && ktag(K.tarr) == "tarr" && ktag(K.tarrfix) == "tarrfix" &&
    ktag(K.tbool) == "tbool" && ktag(K.tbyte) == "tbyte" && ktag(K.terr) == "terr" &&
    ktag(K.tfloat) == "tfloat" && ktag(K.tfunc) == "tfunc" && ktag(K.tinfer) == "tinfer" &&
    ktag(K.tlong) == "tlong" && ktag(K.tmap) == "tmap" && ktag(K.tname) == "tname" &&
    ktag(K.tnone) == "tnone" && ktag(K.topt) == "topt" && ktag(K.tparams) == "tparams" &&
    ktag(K.tpat) == "tpat" && ktag(K.tpend) == "tpend" && ktag(K.tptr) == "tptr" &&
    ktag(K.trec) == "trec" && ktag(K.tref) == "tref" && ktag(K.tstr) == "tstr" &&
    ktag(K.tunion) == "tunion" && ktag(K.tunk) == "tunk" && ktag(K.tvoid) == "tvoid" &&
    ktag(K.typedef) == "typedef" && ktag(K.un) == "un" && ktag(K.void) == "void" &&
    ktag(K.kw_while) == "while"
};

// MAX_NEST is the other number the two copies must hold the same: a limit
// they disagreed about would put the cliff back on one side only.
def max_nest_agree() -> bool { MAX_NEST == 1000 };

export { K, KTAGS, ktag, tags_agree, MAX_NEST, nest, nest_reset, too_deep, max_nest_agree };