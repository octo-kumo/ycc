// native.y — typed AST -> x86_64 assembly (AT&T/GAS) for the native backend.
// Usage:
//   import types from "./types.y";
//   import native from "./native.y";
//   let nr = native.native_resolve_x(src, dir, 0, allow_exec, path);
//   let su = native.std_units(nr.std, pack);  // the std units it links
//   // (pack: ycc's std pack, or "" to compile them from source)
//   let r = native.emit_program(ast, nr, debug, wlevel, su, []);
//   // { ok, asm, errors }. debug is `-g`, which adds `.file`/`.loc`
//   // line markers -- see dbg_lines. The last argument holds the
//   // package units the program links (`ycc build`: native_resolve_pk,
//   // compile_package).
//   // r.ok: asm holds a complete .s file (cc-assemblable). else errors.
//
// Pipeline: types.check_program (fatal) -> collect defs (incl. hoisting of
// capture-free nested defs = baby lambda lifting) -> frame layout -> emit.
// Every value is 8 bytes (long/bool/ptr/str-address); expression values in
// %rax; locals at negative rbp offsets; Y-function args pushed on the stack.
//
// Portability: no special subset is required of this file any more. The C
// copy (src/c/native.c) is hand-maintained C, not a machine translation, so
// both compilers see the same constructs — dot chains, dot-assign and
// short-circuit `&&` all work. What still binds is PORTING.md's 1:1 contract:
// same defs, same order, same arms.
//
// House style here: a subexpression read more than once is bound to a local
// (`let k = node.k;`) instead of re-read inline. The binds are not free to
// remove either: every `let` costs a frame slot, so dropping one changes the
// emitted `sub $N, %rsp`.

import tags from "./tags.y";
import arch from "./arch_x64.y";
// For its aliases AsmLabel and AsmNum.
import asm from "./asm.y";
// nasm: ycc_assemble, for the generator's own image (meta_compile_gen).
import nasm from "./asm.y";
import insn from "./ir.y";
import labels from "./labels.y";
import types from "./types.y";
import rename from "./rename.y";
import lexer from "./lexer.y";
import parser from "./parser.y";
import lint from "./lint.y";
// meta.y imports this one back, for the generator's own compile. The cycle is
// not an import cycle in the splicer (dedup stops at the second `meta.y`) but
// two modules that name each other's defs, which `def` hoisting handles -- and
// the direction matters: native.y owns the pass's position (the top of
// native_resolve_seen) and meta.y owns everything the pass needs to know.
import meta from "./meta.y";
import fs;

// The std units' sources (see std_units). `embed` (see embed_decl) makes
// each file a str const when the compiler is BUILT: the shipped ycc is a
// standalone static ELF and cannot read support files at run time. The C
// copy embeds the same files (Y_EMBED in src/c/yv.h).
embed RT_SRC from "./std/rt.y";
embed PRELUDE_SRC from "./std/prelude.y";
embed EXEC_SRC from "./std/exec.y";
embed STR_SRC from "./std/str.y";

// `ycc -g` line markers, set by compile_unit for each unit. With
// dbg_lines on, the text opens with a `.file N "path"` per origin file
// and every statement (gen_loc_stmt) and function entry (emit_one_fn)
// gets a `.loc FILE LINE` before its code -- GNU as's own line-number
// directives, which asm.y turns into DWARF. dbg_file/dbg_line are the
// origin map's (native_resolve_x): the way back from a line of the
// spliced program to its file. Off, nothing is emitted.
let dbg_lines = false;
let dbg_file: [long] = [];
let dbg_line: [long] = [];

// Packages (`ycc build`, native_resolve_pk): the names a bare `import
// name;` may give a dependency by (res_pkgs -- such an import is not
// spliced: the package is a unit of its own, linked), the package's
// source roots (res_roots, searched by std_resolve), and the packages
// the text imports (res_used: the resolution's `pkgs`).
let res_pkgs: [str] = [];
let res_roots: [str] = [];
let res_used: [str] = [];
// The packages the unit being compiled imports (compile_unit): strip_ns
// turns `json.parse` into the QUALIFIED name `json.parse` -- an id no Y
// source can spell, bound to the package's export -- not into `parse`.
let pkg_ns: [str] = [];
// tcode's and tdecode's recursive aliases (trefs) being spelled out and
// read back, and the count behind the unit ids tdecode gives them.
let tcode_refs: [str] = [];
let tdec_encs: [str] = [];
let tdec_refs: [TRef] = [];
let tdec_n = 0;
// The record-type descriptors emitted so far (ty_desc; link_units reuses
// it for the whole program): an open-addressing set of their labels, with
// each label's canonical form beside it ("" = an empty slot). compile_unit
// empties it for each unit.
let ty_seen: [str] = [];
let ty_forms: [str] = [];
let ty_count = 0;
// ty_desc's labels in this unit, by type signature (types.y tsig): a type
// named again needs no canonical form spelled out and hashed (a recursive
// union's is long, and a read through a union asks for every member's).
// 512 buckets of indices into ty_sig_keys/ty_sig_ids, made when first
// used (ty_sig_init); tyset_reset empties them.
let ty_sig_keys: [str] = [];
let ty_sig_ids: [long] = [];
let ty_sig_bkts: [[long]] = [];
// union_shared's answers in this unit, by the union's node.
let ush_nodes: [Type] = [];
let ush_vals: [[str]] = [];
// The innermost enclosing loop's `break` and `continue` targets, -1 outside any
// loop (2025). Labels are ids from labels.y, so -1 is the "none" marker and 0
// would not do: it is a real id. Module state rather than an EmitSt field, for the same reason
// the globals above are: EmitSt is rebuilt field by field at a dozen sites and
// another pair would have to be threaded through all of them.
//
// Set by the four loop generators just before the body and restored after, so
// nesting works -- an inner loop's targets are in force while its body is
// generated and the outer loop's are back for whatever follows.
//
// types.y has already refused a `break` that would cross a function boundary,
// so these are only ever read inside the function that set them; gen_func clears
// them regardless, because relying on a check in another file to keep these two
// consistent is how a jump ends up in an unrelated body.
let brk_label: long = 0 - 1;
let cont_label: long = 0 - 1;
// One entry per enclosing loop while a body is emitted: the loop variable's
// name ("" for `while`/C-style `for`), and the jump targets `break` and
// `continue` name. A labelled break searches this from the innermost outward;
// an unknown label falls back to the outermost loop (TODO.md item 5).
let loop_names: [str] = [];
let loop_brks: [long] = [];
let loop_conts: [long] = [];

// ── native import resolution ───────────────────────────────────────────
// An import is a COMPILE-TIME text splice, and the C copy splices the same
// way: `import io from "path"` inlines the module's source in place and drops
// its `export` line. References `io.x` are rewritten to plain `x` by
// strip_namespaces (AST-level, so strings are untouched). Module top-levels
// must be defs; a def that replaces one from another file is a loud error
// (find_dup). A module imported by NAME (`import fs;`, std_resolve) keeps
// its own scope instead: rename.y binds its top-level names as `fs.x`,
// which is how the importer spells them (the origin map's `mods`).
//
// The ORIGIN MAP says where each line of the spliced program came from:
// line i + 1 is line `line[i]` of file `files[file[i]]`. files[0] is the
// program itself (`root`, the path the driver was given), then the
// imported modules in splice order; `nuser` counts them all (the std
// library is no part of the text any more -- it is linked as separate
// units, see std_units). Error positions are printed through it (ycc.y
// print_native_errors), and find_dup tells files apart by it. mods[k]
// is the module files[k] was imported as by name (`import fs;`: "fs"),
// "" for the program and the files imported by path.

type Origin = { files: [str], nuser: long, file: [long], line: [long], mods: [str] };
// A resolved unit's text: `imports` are the spliced modules' namespaces
// (strip_ns), `std` the std units it links (see resolve_unit), `pkgs`
// the packages it imports (native_resolve_pk; [] otherwise).
// ogen[i] says line i of src is wholly GENERATED by a meta block's piece,
// not the user's own text. It is the one fact lint needs that the tree does
// not carry: with blocks present the top level is also the generator's
// program, so a top-level statement runs once per round (ideas/meta.md, "The
// cost: the top level runs once per round") -- and a statement the pass
// generated is not one of the user's, so it must not draw that warning.
type Resolved = { src: str, imports: [str], origin: Origin, std: [str], pkgs: [str], ogen: [bool] };

def native_resolve(src: str, base_dir: str, depth: long) -> Resolved {
    native_resolve_x(src, base_dir, depth, true, "")
};

def native_resolve_x(src: str, base_dir: str, depth: long, allow_exec: bool, root: str) -> Resolved {
    res_pkgs = [];
    res_roots = [];
    resolve_unit(src, base_dir, depth, allow_exec, root)
};

// One unit of a project (`ycc build`): a bare `import name;` with
// `name` in `pkgs` (the package's dependencies) imports that package
// instead of splicing a file -- see res_pkgs -- and one naming a module
// looks in the package's source roots `roots` too (std_resolve).
def native_resolve_pk(src: str, base_dir: str, allow_exec: bool, root: str, pkgs: [str], roots: [str]) -> Resolved {
    res_pkgs = pkgs;
    res_roots = roots;
    resolve_unit(src, base_dir, 0, allow_exec, root)
};

// `std` lists the std units the program links, in link order: prelude,
// exec, str, rt (std_units compiles them). allow_exec = false is
// `ycc --no-exec`: exec is left out, so `exec(...)` fails with
// "undefined function" and the binary has no path to a shell at all.
def resolve_unit(src: str, base_dir: str, depth: long, allow_exec: bool, root: str) -> Resolved {
    res_used = [];
    // The program itself is de-duplicated by `self_path` and NOT by putting it in
    // `seen`. `seen` is also the file-id counter -- a nested call is handed
    // `len(seen)` -- so seeding it would shift every module's id in
    // `origin.file` by one and mis-attribute whole files. It was done that way
    // first and `origin.file` then gave `bn.y` zero lines at id 1 while its text
    // landed past the end of `files`, which stopped ycc.y and bignum.y compiling.
    // `self_path` costs one string comparison per import and shifts nothing.
    //
    // Normalised, because the comparison is against what `std_resolve` returns and
    // that is `norm_path`ed: `ycc src/y/asm.y` passes `src/y/asm.y`, and
    // `std_resolve("./asm.y", "src/y")` answers `src/y/asm.y` after dropping the
    // `.`. Comparing the raw spelling would simply never match.
    let self_path = "";
    if (root != "") { self_path = norm_path(root); };
    // NOTE: seen-threading wrapper (see native_resolve_seen): asm.y imports
    // enc64 as `enc` AND elf.y imports enc64 as `elfenc`; without dedup the
    // encoder splices twice and every enc64 def collides (find_dup).
    let r = meta_prepare(src, base_dir, depth, allow_exec, root, self_path);
    let rsrc = join(r.lines, "\n");
    let rimports = r.imports;
    let files: [str] = [root];
    files += r.seen;
    let mods: [str] = [""];
    mods += r.smods;
    let origin = { files: files, nuser: len(files), file: r.ofile, line: r.oline, mods: mods };
    // What the name checks below search: the program's own text, in one
    // pass for all three name lists (words_seen). No std unit is
    // searched: rt and str.y call none of the trigger names, and exec.y's
    // one call into another unit (y_stdin_sync, a prelude def) is why
    // linking exec also links the prelude.
    let pn = prelude_names();
    let xn = exec_names();
    let seen = words_seen(rsrc, pn + xn + str_names());
    let px = len(pn) + len(xn);
    // std/prelude.y, std/exec.y and std/str.y are linked only when the
    // program actually mentions one of their names -- otherwise every
    // binary would carry code it never calls. str.y's names count only
    // in method-call form, `.name(`: a helper-backed string method cannot
    // be reached any other way, so a variable called `lines` or a field
    // `r.count` links nothing. The last slot of seen stands for the
    // y_fmt_* helpers: an f-string field with a format spec sets it to 2
    // (words_scan).
    let want_prelude = seen_any(seen, 0, len(pn), 1);
    let want_exec = false;
    if (allow_exec) {
        if (seen_any(seen, len(pn), px, 1)) {
            want_exec = true;
            want_prelude = true;
        }
    }
    let std: [str] = [];
    if (want_prelude) { std += "prelude"; }
    if (want_exec) { std += "exec"; }
    // str is linked into EVERY program too, for the same reason rt is:
    // y_float_tostr (the runtime's float printer, arch_x64.y) calls std's
    // y_fmt_f, which writes a double's exact decimal value and rounds half to
    // even, so print(x) and f"{x:.6f}" give the same text as C's printf. The
    // link costs nothing in the output -- prune_bodies drops whatever the
    // program does not reach (hello.y is 8312 bytes either way) -- and with
    // the std pack it is one precompiled unit.
    std += "str";
    // The runtime library (std/rt.y) is linked into EVERY program:
    // generated code calls into it by fixed label (`call y_print_long`),
    // so there is no name to test for. Unused helpers cost nothing in the
    // output -- prune_bodies drops them at link time.
    std += "rt";
    // ogen is EMPTY for a unit with no blocks, which is what tells lint there is
    // no generator whose top level is this one (see lint_meta_top): a file with
    // blocks whose pieces happen to add no lines is still such a file.
    let og: [bool] = [];
    if (meta.mg_n > 0) { og = r.ogen; };
    { src: rsrc, imports: rimports, origin: origin, std: std, pkgs: res_used,
        ogen: og }
};

// Which file line `ln` of the spliced program came from (0, the program
// itself, when the map does not cover it).
def origin_file(o: Origin, ln: long) -> long {
    let f = o.file;
    if (ln >= 1 && ln <= len(f)) { f[ln - 1] } else { 0 }
};

// Line `ln` of the spliced program as its file shows it: "path:line", or
// just "line" in the program's own file when `bare` (error positions keep
// the plain `line:col` form there). A line past the end of the map (the
// end of the input) counts on from the last line it holds.
def origin_at(o: Origin, ln: long, bare: bool) -> str {
    let f = o.file;
    let l = o.line;
    let n = len(f);
    if (ln < 1 || n == 0) {
        tostring(ln)
    } else {
        let k = ln;
        if (k > n) { k = n; }
        let fid = f[k - 1];
        let at = tostring(l[k - 1] + ln - k);
        if (fid == 0 && bare) { at } else { o.files[fid] + ":" + at }
    }
};

// Names std/prelude.y defines. A program that mentions none of them gets
// no prelude at all, so a hello-world binary stays the size it was.
// These are the TRIGGER names native_resolve_x searches the program for;
// a file may define more -- std/exec.y also defines exit_status, which
// only exec() calls.
def prelude_names() -> [str] {
    ["readline", "clear_eof", "y_stdin_sync"]
};

def exec_names() -> [str] {
    ["exec", "popen", "pwrite", "pread", "pclose", "pclose_in", "exec_capture", "exec_capture_in"]
};

// The string methods std/str.y implements (types.y str_method maps each
// to its y_str_* helper). They count only in method-call form, `s.name(`
// (words_seen). The builtin-backed ones (split, trim, ...) need no splice,
// so they are not here.
def str_names() -> [str] {
    ["trim_start", "trim_end", "lstrip", "rstrip", "pad_left", "pad_right",
        "center", "starts_with", "ends_with", "contains", "count", "replace",
        "upper", "lower", "repeat", "lines"]
};

// An embedded std file, newline-terminated (as every source file the
// compiler reads should be).
def std_text(s: str) -> str {
    if (s[len(s) - 1:] == "\n") { s } else { s + "\n" }
};

// Which trigger names the program mentions, in ONE pass over its text
// however many names there are. seen[k] is 0 when names[k] does not occur
// as a word of code, 1 when it does, and 2 when it also occurs in
// method-call form, `.name(` (blanks and comments allowed in between).
//
// Textual, deliberately: it runs before tokenizing. It skips what the
// lexer skips -- blanks, `//` and `/* */` comments (which do not nest) --
// and the insides of string literals: `"..."`, and `'...'`, since outside
// a literal or a comment a `'` only ever opens `b'..'` or `'..'`; a
// backslash escapes the byte after it. Whole words only: `executable` is
// not `exec`, nor `counter` `count`. Each of those rules fixed a real
// failure of the scan it replaced (an index_of per name over the text
// with comments stripped first):
//   - a comment containing `exec` spliced the whole fork/execve chunk
//     into the binary (the audit found /bin/sh rodata and ~9 extra uids
//     in a program that never calls exec);
//   - after a `/* */` comment the strip dropped the rest of the text, and
//     a `//` inside a string literal ("http://") the rest of its line, so
//     a readline() there was missed: "undefined function 'readline'";
//   - 20 whole-text index_of scans were 10% of a self-compile.
// A false positive still only costs compile time and an unused function
// in the output; a miss is a compile error.
//
// One more slot than names: seen[len(names)] is 2 when an f-string has a
// field with a format spec (words_scan).
def words_seen(code: str, names: [str]) -> [long] {
    let seen: [long] = [];
    for k in 0..len(names) + 1 {
        seen += 0;
    };
    words_scan(code, 0, len(code), names, seen);
    seen
};

// words_seen's pass over code[lo:n], marking seen in place. The fields of
// an f-string are code: lexer.y fstr_walk finds them as the lexer does,
// and each is scanned on its own.
def words_scan(code: str, lo: long, n: long, names: [str], seen: [long]) -> void {
    let i = lo;
    // the first byte of the last token of code (blanks and comments skip),
    // and a name just seen after a `.`, waiting for its `(`
    let prev = 0;
    let pend = 0 - 1;
    while (i < n) {
        let c = code[i];
        if (blank_byte(c)) {
            i = i + 1;
        } else if (c == '/' && i + 1 < n && code[i + 1] == '/') {
            // `//`: up to the newline
            i = i + 2;
            while (i < n && code[i] != '\n') {
                i = i + 1;
            };
        } else if (c == '/' && i + 1 < n && code[i + 1] == '*') {
            // `/*`: past the first `*/`
            i = i + 2;
            let open = true;
            while (open && i < n) {
                if (code[i] == '*' && i + 1 < n && code[i + 1] == '/') {
                    open = false;
                    i = i + 1;
                }
                i = i + 1;
            };
        } else {
            if (pend >= 0) {
                if (c == '(') { seen[pend] = 2; }
                pend = 0 - 1;
            }
            if (c == '\"' || c == '\'') {
                // a string literal: past its closing quote (lit_end, the
                // lexer.y scanner -- one scanner, so the lexer and this
                // cannot disagree about where a literal ends)
                i = lexer.lit_end(code, i, [0]);
            } else if (word_byte(c)) {
                let j = i + 1;
                while (j < n && word_byte(code[j])) {
                    j = j + 1;
                };
                if (j == i + 1 && c == 'f' && j < n && code[j] == '\"') {
                    // f"...": the fields, and whether one has a spec
                    let w = lexer.fstr_walk(code, j);
                    let fs = w.fields;
                    let f = 0;
                    while (f < len(fs)) {
                        words_scan(code, fs[f], fs[f + 1], names, seen);
                        if (fs[f + 3] > fs[f + 2]) { seen[len(names)] = 2; }
                        f += 4;
                    };
                    i = w.end;
                } else {
                    names.foreach((e, m) => {
                        let nm: str = e;
                        if (len(nm) == j - i && word_at(code, i, nm)) {
                            if (seen[m] == 0) { seen[m] = 1; }
                            if (prev == '.') { pend = m; }
                        }
                    });
                    i = j;
                };
            } else {
                i = i + 1;
            };
            prev = c;
        };
    };
};

// A byte of an identifier-shaped word (the lexer's isalnum: letters,
// digits, `_`).
def word_byte(c: long) -> bool {
    isalpha(c)
};

// A blank as the lexer skips it (its isspace: space, tab, LF, CR).
def blank_byte(c: long) -> bool {
    isspace(c)
};

// Whether code[i:i + len(nm)] is nm (the caller checked the length).
def word_at(code: str, i: long, nm: str) -> bool {
    let ok = true;
    let k = 0;
    while (ok && k < len(nm)) {
        if (code[i + k] != nm[k]) { ok = false; }
        k++;
    };
    ok
};

// Whether any of seen[lo..hi) reaches `level` (see words_seen).
def seen_any(seen: [long], lo: long, hi: long, level: long) -> bool {
    let r = false;
    for i in lo..hi {
        if (seen[i] >= level) { r = true; }
    };
    r
};

// Collapse "/./" segments so the same file resolves to one key no matter
// how deep the import nesting is (base dirs accumulate "/." per level:
// "ycc/././enc64.y" vs "ycc/./././enc64.y"), and "/../" segments so one file
// reached by two spellings is one key: without the fold, a tool outside
// src/y/ that imports a std module by name and a sibling by a path with a
// ".." in it splices that module twice -- once per spelling -- and every
// name in it is reported as a duplicate definition against itself.
// Deterministic, so same-file inputs always yield the same key (sufficient
// for seen-dedup). Purely lexical, as the rest of it is: a ".." that would
// leave the root is kept, because whether it exists is the filesystem's
// answer and this runs before any file is read.
def norm_path(p: str) -> str {
    let parts = split(p, "/");
    let out: [str] = [];
    parts.foreach((seg) => {
        let n = len(out);
        if (seg == ".") {
        } else if (seg == ".." && n > 0 && out[n - 1] != "..") {
            out = out[:n - 1];
        } else {
            out += seg;
        };
    });
    join(out, "/")
};

// Where full is in seen (-1: nowhere).
def seen_index(seen: [str], full: str) -> long {
    let at = -1;
    let i = 0;
    while (at < 0 && i < len(seen)) {
        if (seen[i] == full) { at = i; }
        i++;
    };
    at
};

def seen_has(seen: [str], full: str) -> bool {
    let i = 0;
    let found = false;
    while (i < len(seen)) {
        if (seen[i] == full) {
            found = true;
        };
        i++;
    };
    found
};

// The scan for one file: meta.y's when the pass is on, and the file's own
// lines when it is off. The off case is not a special case anywhere else: P is
// then the file verbatim and a line's origin is its own line number, which is
// what meta.y's scan_none produces.
def gen_at(g: [bool], i: long) -> bool {
    if (i < len(g)) { g[i] } else { false }
}

def meta_meta_scan(src: str, base_dir: str, fid: long) -> Scan {
    if (!meta.mg_on) {
        meta.scan_none(src, fid)
    } else {
        meta.meta_scan(src, fid, base_dir)
    }
};

// ── the meta pass ──────────────────────────────────────────────────────
// One resolve, in three steps, when the program has blocks (meta.y):
//
//   1. a COLLECTING resolve with the pass on: every file is scanned, the
//      blocks are found and G is built, and the result is thrown away;
//   2. G is compiled (pass off) and run in a forked child (meta.y
//      run_image), and the pieces come back over a pipe;
//   3. the ordinary resolve again, with the pass on and the pieces known, so
//      each file's scanner splices them into P as it goes and the splicer's
//      line loop -- which is where imports, `export` and `embed` are handled --
//      never sees a block.
//
// Steps 1 and 3 walk the imports with the SAME code, so the block order -- and
// therefore the slot a piece is matched by -- is the same in both. The cost is
// one extra resolve, and only for a program that HAS blocks: `meta_scan` finds
// nothing and `mg_n` stays 0, which skips step 2 and, when the pass was never
// on, step 1 as well.
//
// The passes are why the pass lives in its own module with its own driver:
// `native_resolve_seen` is recursive and its return value is consumed by this
// function, so there is nowhere else the loop could go without threading the
// piece table through the recursion.
//
// Everything the generator's own compile touches is saved and put back: it is
// a full compile of another program inside this one, and the globals below
// (native.y's, so only native.y can do it) are the outer compile's state.
def meta_prepare(src: str, base_dir: str, depth: long, allow_exec: bool, root: str, self_path: str) -> SrcLines {
    if (!meta.mg_on) {
        return native_resolve_seen(src, base_dir, depth, [], [], 0, self_path);
    };
    // step 1: find the blocks. The result is thrown away; only the scanner's
    // accumulators survive.
    let first = native_resolve_seen(src, base_dir, depth, [], [], 0, self_path);
    if (meta.mg_n == 0) {
        // no blocks: the collecting pass's own result is the real one, and it
        // is byte for byte what the pass-off path returns
        first
    } else {
        meta_resolve(src, base_dir, depth, allow_exec, root, first, self_path)
    }
};

// Steps 2 and 3 as a loop, which is the whole cost of nesting. A nested block's
// text is spliced into the source of the block AROUND it (meta.y sg_splice),
// and a source has to be compiled before it can run -- so the enclosing block
// cannot produce its text until the nested one has produced its, and that is one
// more compile and run of G per level.
//
// So: run the generator, and while any block is still without its text
// (mg_pending) do it again. The round that resolves a nested block finds its
// enclosing block waiting; the round after that finds the enclosing one. A chain
// of depth d costs d+1 rounds and a program with NO nesting costs exactly one,
// because nothing is ever pending when there is no nesting.
//
// A round is a whole extra compile of the program-as-generator, which is the
// reason MG_NEST is 8 rather than the parser's ~333 -- see the cap's diagnostic.
def meta_resolve(src: str, base_dir: str, depth: long, allow_exec: bool,
    root: str, first: SrcLines, self_path: str) -> SrcLines {
    if (meta.mg_nest > 0) {
        // A round in which a block cannot produce its text leaves a stand-in
        // where its call goes, so a statement naming something that block was
        // going to define would not compile. The reduction leaves those
        // statements out of G, and they declare nothing, so no name is lost.
        meta.mg_reduce_on();
    };
    // The collecting pass found nesting, so its G is NOT the one to compile: it
    // was built before anything was known, with every block's call in place where
    // the block stood, and for a nested block that source does not compile (the
    // inner text is missing). Start the rounds from a fresh pass, which holds
    // what it may have to give up and reduces.
    meta.mg_pass();
    native_resolve_seen(src, base_dir, depth, [], [], 0, self_path);
    let rounds = 0;
    let done = false;
    while (!done) {
        meta_run_generator(src, base_dir, allow_exec, root, first);
        rounds++;
        if (!meta.mg_pending()) {
            done = true
        } else if (rounds >= meta.MG_ROUND) {
            meta.mg_report("the meta generator still had a block without its text after " + tostring(meta.MG_ROUND) + " rounds, more than the nesting depth allows: this is the pass's own bookkeeping and is a bug")
        } else {
            // another round: the block table starts over, so the next resolve
            // hands out the same slots (mg_pass) and finds the pieces
            meta.mg_pass();
            native_resolve_seen(src, base_dir, depth, [], [], 0, self_path)
        };
    };
    // step 3: the ordinary resolve, with every piece known. Its G is built and
    // not run -- nothing is pending, so there is nothing left to compute.
    meta.mg_pass();
    native_resolve_seen(src, base_dir, depth, [], [], 0, self_path)
};

// Compile and run G, with every global it disturbs saved and put back.
def meta_run_generator(src: str, base_dir: str, allow_exec: bool, root: str,
    first: SrcLines) -> long {
    let spk = res_pkgs;
    let sro = res_roots;
    let su = res_used;
    let sdl = dbg_lines;
    let sdf: [long] = dbg_file;
    let sdn: [long] = dbg_line;
    let sns = pkg_ns;
    let mf: [str] = [root];
    mf += first.seen;
    meta.mg_setup(root, mf, base_dir, allow_exec, spk, sro);
    let img = meta_compile_gen();
    let av: [str] = [root + ".meta"];
    let rr = meta.run_image(img, av, true);
    if (!rr.ok) {
        meta.mg_report("cannot run the meta generator: " + rr.err);
    };
    meta.mg_take_pieces(rr.status, rr.sig, rr.out);
    res_pkgs = spk;
    res_roots = sro;
    res_used = su;
    dbg_lines = sdl;
    dbg_file = sdf;
    dbg_line = sdn;
    pkg_ns = sns;
    0
};

// Compile G the way ycc compiles a program, with the pass OFF, and hand back
// its image. G's errors are reported with G's own origin map, so they read
// `<file>.meta:<source line>` -- visibly about the synthesized text and not
// about the user's file, and still carrying a line through the line map.
def meta_compile_gen() -> [byte] {
    let gt = meta.meta_gtext();
    let go = meta_gorigin(meta.mg_glines());
    meta.mg_set(false);
    let nr = native_resolve_pk(gt, meta.mg_gbase, meta.mg_gexec,
        meta.mg_root + ".meta", meta.mg_pkgs, meta.mg_roots);
    if (meta.mg_probe(nr.src, meta.mg_gbase)) {
        meta.mg_report("a meta block cannot appear in a module imported into the meta generator: the generator's text is compiled with the pass off, so nothing in it is scanned");
    };
    let su = std_units(nr.std, "");
    // nr.src, not gt: the hoisted imports were spliced in by the resolve above,
    // and tokenizing gt would hand the parser a literal `import` line
    let ast = parser.parse_program(lexer.tokenize(nr.src));
    // THE GENERATOR'S IMAGE IS BUILT FOR THE HOST, NOT FOR THE PROGRAM'S
    // TARGET. A meta block's generator is EXECUTED -- meta.y forks it and runs
    // it -- and the host can only run an ELF, so with --target=windows the
    // emitter and the linker produced a PE and every meta fixture died with
    // "the image is not an ELF file". BOTH read the target (asm.y picks the
    // object writer), so it is put back only after the assemble. Both failure
    // paths inside this function exit(1), which is why the restore can sit
    // where it does: nothing returns with the target still changed.
    //
    // "linux" is the host by construction: the compiler in src/y is a Linux
    // binary, and src/c's cycc is too except for cycc.exe, whose meta gap is
    // already recorded (AGENTS.md, cycc-win.sh).
    let saved_target = res_target;
    res_target = "linux";
    let r = emit_program(ast, nr, false, 0, su, []);
    if (!r.ok) {
        let seen: [str] = [];
        for i in 0..len(r.errors) {
            let e = r.errors[i];
            let at = origin_at(go, e.line, false) + ":" + tostring(e.col);
            if (!dup_at(seen, at)) {
                seen += at;
                puts(at + ": error: " + e.msg + "\n");
            };
        };
        meta.mg_set(true);
        meta.mg_report("the meta generator did not compile");
    };
    let ab = nasm.ycc_assemble(r.asm, false);
    res_target = saved_target;
    meta.mg_set(true);
    if (!ab.ok) {
        puts("error: the meta generator does not assemble: " + ab.error + "\n");
        exit(1);
    };
    ab.bytes
};

def dup_at(seen: [str], at: str) -> bool {
    let hit = false;
    seen.foreach((e) => {
        if (e == at) { hit = true; };
    });
    hit
};

// G's origin map: one file, `<root>.meta`, so a diagnostic in G is visibly not
// the user's; each line carries the SOURCE line its text came from, which the
// line map already knows. Line numbers in G are MAPPED, not preserved -- the
// helpers and the hoisted imports shift everything below them.
def meta_gorigin(nbody: long) -> Origin {
    let hs = meta.mg_ghead();
    let n = hs + nbody;
    let f: [long] = [];
    let l: [long] = [];
    let m: [str] = [];
    for i in 0..n {
        f += 0;
        l += 1;
        m += "";
    };
    let gol = meta.mg_gol;
    for k in 0..nbody {
        let ln = 1;
        if (k < len(gol)) { ln = gol[k]; };
        l[hs + k] = ln;
    };
    { files: [meta.mg_root + ".meta"], nuser: 1, file: f, line: l, mods: m }
};
// ── optional std modules ───────────────────────────────────────────────
// `import net;` (no `from`) pulls in a module by NAME instead of by path:
// an optional std library (net, ui, ...) or a project-local one. A file
// next to the importer wins (so a project can vendor or shadow a module),
// then the compiler's own std library:
//     <importer dir>/<name>.y        <importer dir>/std/<name>.y
//     ./std/<name>.y                 ./src/y/std/<name>.y
//     <ycc dir>/std/<name>.y         <ycc dir>/src/y/std/<name>.y
//     <ycc dir>/../src/y/std/<name>.y
// The file found is spliced like `import x from "path"` and keeps its own
// scope: its defs are `net.listen_tcp` and friends (rename.y).

def dir_of(p: str) -> str {
    let s = last_index_of(p, "/");
    if (s < 0) { "" } else { p[:s] }
};

// The directory this compiler runs from: /proc/self/exe (readlink), so a
// compiler found through PATH still finds its std units next to itself --
// argv()[0] is then just "ycc" and dir_of("ycc") is empty, which is how
// `PATH=... ycc prog.y` failed to find fs with the units sitting beside the
// binary. argv()[0] stays the fallback: a host with no /proc, and a binary
// replaced while it runs (the link then names a path that may be gone, which
// the candidates simply miss).
def self_dir() -> str {
    let by_argv = "";
    let av = argv();
    if (len(av) > 0) { by_argv = dir_of(av[0]); };
    let buf: [byte; 4096] = [0; 4096];
    let n = syscall(89, "/proc/self/exe", &buf[0], len(buf));
    if (n > 0) {
        let d = dir_of(from_bytes(buf[0:n]));
        if (len(d) > 0) { d } else { by_argv }
    } else { by_argv }
};

def std_resolve(name: str, base_dir: str) -> str {
    let cands: [str] = [];
    cands += base_dir + "/" + name + ".y";
    cands += base_dir + "/std/" + name + ".y";
    // a package's source roots (native_resolve_pk)
    res_roots.foreach((e) => {
        let rr: str = e;
        cands += rr + "/" + name + ".y";
    });
    cands += "std/" + name + ".y";
    cands += "src/y/std/" + name + ".y";
    let d = self_dir();
    if (len(d) > 0) {
        cands += d + "/std/" + name + ".y";
        cands += d + "/src/y/std/" + name + ".y";
        cands += d + "/../src/y/std/" + name + ".y";
    }
    let found = "";
    cands.foreach((e) => {
        if (len(found) == 0) {
            let c: str = e;
            if (!(fs.read_file(c) == none)) {
                found = norm_path(c);
            };
        }
    });
    found
};

// What the program text of file `fid` is, with its imports spliced in, as
// lines, and where each of those lines came from (see native_resolve_seen).
// ofile/oline are the origins this function emits; the pass's own scan maps
// its INPUT lines back (sc.pf/sc.pol), which is a different map once a block
// has added lines.
type SrcLines = { lines: [str], imports: [str], seen: [str], smods: [str], ofile: [long], oline: [long], ogen: [bool] };

// The program text `src` of file `fid` (its index in the origin map's
// files: 0 for the program itself, k for seen[k - 1]) with its imports
// spliced in, as lines; ofile/oline map each one back (see the origin map
// above native_resolve), and smods[k] is the module seen[k] was imported
// as by name ("" by path).
// `self_path` is the normalised path of the PROGRAM being compiled, or "" when
// there is no single file (native_resolve, and a synthesized unit). It is passed
// separately from `seen` on purpose -- see resolve_unit -- because a module may
// import the program back, and that must not splice it a second time.
def native_resolve_seen(src: str, base_dir: str, depth: long, seen: [str], smods: [str], fid: long, self_path: str) -> SrcLines {
    if (depth > 32) {
        // Fatal, like a missing module: carrying on compiled the program
        // without the rest of the chain and exited 0.
        puts("error: native import depth exceeded (cycle?)\n");
        exit(1);
        { lines: [], imports: [], seen: seen, smods: smods, ofile: [], oline: [], ogen: [] }
    } else {
        // The meta pass's scan, BEFORE the line loop: `embed` is expanded
        // inside that loop, so a file with blocks has its embedded bytes
        // already inside a string literal by then and nothing in them can be
        // read as a block; each file's own base_dir is in scope here, so a
        // hoisted import path normalizes against the file the block came from;
        // and the whole thing runs before words_seen (resolve_unit), so
        // std-unit selection sees the GENERATED text.
        let sc = meta_meta_scan(src, base_dir, fid);
        if (!sc.ok) {
            // Fatal, like every other diagnostic the resolve raises: a pass
            // error with no message is a program compiled from nothing and
            // exited 0.
            let where = tostring(sc.eline) + ":" + tostring(sc.ecol);
            if (fid > 0 && fid - 1 < len(seen)) { where = seen[fid - 1] + ":" + where; };
            puts(where + ": error: " + sc.err + "\n");
            exit(1);
        };
        let lines = sc.p;
        // The scan's OWN origins, read by input line number (a block's piece
        // may add lines, so they are not the output's), and the origins this
        // function emits, one per output line.
        let inf: [long] = sc.pf;
        let inl: [long] = sc.pol;
        let inf_gen: [bool] = sc.gen;
        let out_lines: [str] = [];
        let ofile: [long] = [];
        let oline: [long] = [];
        let ogen: [bool] = [];
        let imports: [str] = [];
        let i = 0;
        let n = len(lines);
        while (i < n) {
            let line = lines[i];
            let lf = 0;
            if (i < len(inf)) { lf = inf[i]; };
            let ln = 0;
            if (i < len(inl)) { ln = inl[i]; };
            let trimmed = trim(line);
            if (trimmed[:7] == "import ") {
                let rest = trimmed[7:];
                let from_idx = index_of(rest, " from ");
                let name = "";
                let full = "";
                let path = "";
                let is_pkg = false;
                if (from_idx >= 0) {
                    name = trim(rest[:from_idx]);
                    let path_part = trim(rest[from_idx + 6:]);
                    if (path_part[len(path_part) - 1:] == ";") {
                        path_part = path_part[:len(path_part) - 1];
                    };
                    path = path_part[1:len(path_part) - 1];
                    // NOTE: normalized (see norm_path): nested base dirs
                    // accumulate "/." segments, so raw joins of the same file
                    // differ per depth and seen-dedup would never hit.
                    full = norm_path(base_dir + "/" + path);
                    if (path[:1] == "/") { full = norm_path(path); };
                } else {
                    // bare `import name;`: an optional std module (net, ui,
                    // ...) or a project-local one — see std_resolve above.
                    name = trim(rest);
                    if (name[len(name) - 1:] == ";") {
                        name = trim(name[:len(name) - 1]);
                    };
                    path = name;
                    if (name_in(res_pkgs, name)) {
                        // a dependency (ycc build): a unit of its own,
                        // linked -- strip_ns qualifies its names
                        is_pkg = true;
                        if (!name_in(res_used, name)) { res_used += name; }
                    } else {
                        full = std_resolve(name, base_dir);
                    };
                };
                if (is_pkg) {
                } else if (len(name) == 0) {
                    out_lines += line;
                    ofile += lf;
                    oline += ln;
                    ogen += gen_at(inf_gen, i);
                } else if (len(full) == 0) {
                    // Fatal: carrying on only reported the module's names as
                    // undefined further down, after this message scrolled by.
                    puts("error: cannot find module '" + name + "' (import name; looks next to the importer and in std/)\n");
                    exit(1);
                } else {
                    let mod_src = fs.read_file(full);
                    if (mod_src == none) {
                        puts("error: cannot open import '" + path + "' (resolved to '" + full + "')\n");
                        exit(1);
                    } else if (seen_has(seen, full) || (self_path != "" && full == self_path)) {
                        // NOTE: already spliced (see native_resolve note):
                        // record the namespace name (strip_ns needs it,
                        // unless the file is a module with its own scope)
                        // but do NOT splice the text a second time.
                        //
                        // The program itself counts as already spliced: it is, by
                        // the line above this walk started. `asm.y` imports `ir.y`
                        // and `ir.y` imports `asm.y` back, which is legal -- they
                        // are separate units, and a unit may be imported by more
                        // than one -- and before this test existed the program was
                        // spliced a second time inside its own module. Every one of
                        // its declarations then stood in the tree twice, so
                        // `ycc src/y/asm.y` reported "duplicate definition
                        // 'is_digit_ch' ... defines it too" for each, and the
                        // checker reported `type 'AsmLabel' is declared more than
                        // once` -- thirty-two errors that `ycc ycc.y` never
                        // produced, because there the program is ycc.y and nothing
                        // imports ycc.y back.
                        //
                        // `smods` has no entry for the program -- it is not a
                        // spliced module -- so its smod is "" , which is right:
                        // the program's own copy IS the flattened one, so
                        // strip_ns must strip whatever qualifier a module used.
                        let smod = "";
                        if (full != self_path) { smod = smods[seen_index(seen, full)]; };
                        if (smod == "") { imports += name; }
                    } else {
                        seen += full;
                        if (from_idx >= 0) { smods += ""; } else { smods += name; };
                        let last_slash = last_index_of(full, "/");
                        let mod_dir = base_dir;
                        if (last_slash >= 0) {
                            mod_dir = full[:last_slash];
                        };
                        // mod_src is str? (read_file returns none on missing
                        // file); the none case exited above, so unwrap here.
                        let sub = native_resolve_seen(unwrap(mod_src), mod_dir, depth + 1, seen, smods, len(seen), self_path);
                        let subns = sub.imports;
                        seen = sub.seen;
                        smods = sub.smods;
                        // splice the module text inline (its own imports
                        // first), and its lines' origins with it
                        out_lines += sub.lines;
                        ofile += sub.ofile;
                        oline += sub.oline;
                        ogen += sub.ogen;
                        subns.foreach((e) => {
                            imports += e;
                        });
                        // a module imported by name keeps its namespace
                        // (rename.y), one imported by path is flattened
                        if (from_idx >= 0) { imports += name; }
                    };
                };
            } else if (is_embed_decl(trimmed)) {
                out_lines += embed_decl(trimmed, base_dir);
                ofile += lf;
                oline += ln;
                ogen += false;
            } else {
                // NOTE: no empty if-arms here — keep the `0;` filler.
                // Export lines are dropped (defs are spliced; uses are
                // rewritten by strip_namespaces).
                if (trimmed[:7] != "export ") {
                    out_lines += line;
                    ofile += lf;
                    oline += ln;
                    ogen += gen_at(inf_gen, i);
                } else {
                    // `export { a, b,` may run on over several lines: drop
                    // them through the one that closes the list.
                    if (index_of(line, "{") >= 0) {
                        while (index_of(lines[i], "}") < 0 && i + 1 < n) {
                            i++;
                        };
                    };
                };
            };
            i++;
        };
        { lines: out_lines, imports: imports, seen: seen, smods: smods,
            ofile: ofile, oline: oline, ogen: ogen }
    }
};

// ── embed ──────────────────────────────────────────────────────────────
// `embed NAME from "path";` declares `const NAME = "<the file's bytes>";`.
// The file is read at compile time, like an import, and the literal stays
// on the declaration's one line, so every line number below it holds. The
// path is relative to the file that says it (an absolute path stays as
// is). A line that only starts with the word (`embed = 1;`) is code.
def is_embed_decl(trimmed: str) -> bool {
    if (trimmed[:6] == "embed ") {
        index_of(trimmed, " from \"") > 6
    } else {
        false
    }
};

def embed_decl(trimmed: str, base_dir: str) -> str {
    let rest = trimmed[6:];
    let from_idx = index_of(rest, " from \"");
    let name = trim(rest[:from_idx]);
    let path_part = trim(rest[from_idx + 6:]);
    if (path_part[len(path_part) - 1:] == ";") {
        path_part = trim(path_part[:len(path_part) - 1]);
    }
    if (len(path_part) < 2 || path_part[len(path_part) - 1:] != "\"") {
        puts("error: malformed embed (embed NAME from \"path\";): " + trimmed + "\n");
        exit(1);
    }
    let path = path_part[1:len(path_part) - 1];
    let full = norm_path(base_dir + "/" + path);
    if (path[:1] == "/") { full = norm_path(path); }
    let data = fs.read_file(full);
    if (data == none) {
        puts("error: cannot embed '" + path + "' (resolved to '" + full + "')\n");
        exit(1);
    }
    "const " + name + " = " + quote_text(unwrap(data)) + ";"
};

// `s` as a Y string literal on one line: a backslash, a quote and the
// control bytes are escaped (`\n`, `\r`, `\xHH`; a tab stays as is) and
// every other byte is copied.
def quote_text(s: str) -> str {
    let b = bytes(s);
    let n = len(b);
    let hex = "0123456789abcdef";
    let out: [str] = ["\""];
    let run = 0;
    for i in 0..n {
        let c: long = b[i];
        let esc = "";
        if (c == '\\') {
            esc = "\\\\";
        } else if (c == '\"') {
            esc = "\\\"";
        } else if (c == '\n') {
            esc = "\\n";
        } else if (c == '\r') {
            esc = "\\r";
        } else if (c < ' ' && c != '\t') {
            esc = "\\x" + hex[c / 16:c / 16 + 1] + hex[c % 16:c % 16 + 1];
        }
        if (len(esc) > 0) {
            out += s[run:i];
            out += esc;
            run = i + 1;
        }
    };
    out += s[run:];
    out += "\"";
    join(out, "")
};

// ── tree shaking ────────────────────────────────────────────────────────
// The arch prelude is a pile of labelled blocks (helpers + rodata blobs) of
// which a typical program uses a handful. Shake keeps exactly the blocks a
// program reaches and drops the rest, so a hello world stops carrying the
// string splitter. Reachability is the obvious one:
//
//   - a block is entered when a kept block (or the program's own code)
//     references its label — `call`, `lea`, a jump, or an immediate like
//     `$ystr_end-ystr` (which names both), and
//   - when the previous block FALLS THROUGH into it: a block whose last
//     instruction is not a transfer (`ret`, `jmp`, `syscall` — the traps
//     end in an exit syscall) runs into the next one.
//
// Labels therefore never merge blocks: an internal loop label is a block
// kept by its own jump references, unreferenced dead code is dropped even
// in the middle of a function, and `ystr_*` rodata comes along exactly when
// some kept block names it. prune_bodies applies the same rule one level
// up, to whole function bodies.
//
// The scanners walk a `bytes()` COPY of the text and only materialize the
// symbols they reference: a per-character slice would cost an allocation
// (two syscalls in y_alloc) per character, which dominated compiles.

def is_id_b(c: long) -> bool {
    // letters, digits, `_`, `$` and `.` (a module's names are qualified:
    // `yfn_12_fs.exists$3`); most bytes are lowercase, decided first
    if (c >= 'a') { c <= 'z' }
    else if (c >= 'A') { c <= 'Z' || c == '_' }
    else if (c >= '0') { c <= '9' }
    else { c == '$' || c == '.' }
};

// First non-blank offset in [i, hi); blank means space (the asm dialect
// indents with spaces) or end of range.
def skip_sp(b: [byte], i: long, hi: long) -> long {
    let p = i;
    while (true) {
        if (p >= hi) {
            break;
        } else {
            if (b[p] == ' ') {
                p = p + 1;
            } else {
                break;
            };
        };
    };
    p
};

// End of the identifier at offset `i` (a leading `$` — an assembly
// immediate like `$ystr_end-ystr` — is not part of the name).
def tok_end_b(b: [byte], i: long, hi: long) -> long {
    let p = i;
    if (p < hi) {
        if (b[p] == '$') { p = p + 1; }
    }
    while (true) {
        if (p >= hi) {
            break;
        } else {
            if (is_id_b(b[p])) {
                p = p + 1;
            } else {
                break;
            };
        };
    };
    p
};

// The identifier at offset `i`, or "".
def tok_at_b(text: str, b: [byte], i: long, hi: long) -> str {
    let s = i;
    if (s < hi) {
        if (b[s] == '$') { s = s + 1; }
    }
    let e = tok_end_b(b, i, hi);
    if (e > s) { text[s:e] } else { "" }
};

def tok_push(out: [str], t: str) -> [str] {
    if (len(t) == 0) { out } else { out += t }
};

// Is this mnemonic one whose operands may name a label, other than `mov`? The
// answer is every SSE form -- `mulsd c7(%rip), %xmm0` is the only mention of a
// coefficient-table entry a kernel has, and without it the shaker drops the
// table and the label comes back undefined at link time.
//
// Naming the ten forms instead costs a dozen string comparisons on EVERY line
// of the emitted text, which measured +1.3% of compile instructions on its own.
// They all end in "sd" or "ss" and nothing else in the language does, so two
// byte reads replace those comparisons. A false match would be harmless in any
// case -- the two tokens this pushes match no label -- so it is a speed gate,
// not a correctness one.
def sse_mnemonic(w: str) -> bool {
    let n = len(w);
    if (n < 5) {
        false
    } else {
        let a = w[n - 2];
        let b = w[n - 1];
        (a == 115 && b == 100) || (a == 100 && b == 115)
    }
};

// Every symbol one line [lo, hi) references: call/lea/jump operands and
// both labels of a computed immediate (`mov $A-B, ...`). Dispatch on the
// mnemonic — this walks every line of the emitted text, so no searching.
def line_refs_b(text: str, b: [byte], lo: long, hi: long, out: [str], want_jumps: bool) -> [str] {
    let p = skip_sp(b, lo, hi);
    if (p >= hi) {
        out
    } else {
        let w = tok_at_b(text, b, p, hi);
        let op = skip_sp(b, (tok_end_b(b, p, hi)), hi);
        if (w == "call") {
            out = tok_push(out, tok_at_b(text, b, op, hi));
        } else if (w == "lea") {
            out = tok_push(out, tok_at_b(text, b, op, hi));
        } else if (w == "mov" || sse_mnemonic(w)) {
            let q = p;
            while (true) {
                if (q >= hi) {
                    break;
                } else {
                    if (b[q] == '$') {
                        break;
                    } else {
                        q = q + 1;
                    };
                };
            };
            if (q < hi) {
                out = tok_push(out, (tok_at_b(text, b, q, hi)));
                let after = tok_end_b(b, q, hi);
                if (after < hi) {
                    if (b[after] == '-') {
                        out = tok_push(out, tok_at_b(text, b, after + 1, hi));
                    }
                }
            };
            // The `mov` scan above only looks at a `$`-immediate, so an SSE
            // form's operand was invisible here and the coefficient table was
            // shaken away. Both operands are pushed: the syntax is AT&T, so the
            // source is the FIRST one and `movsd`'s store form puts the memory
            // SECOND, and a register name matches no label, so the extra token
            // costs nothing.
            if (w != "mov") {
                let t1 = tok_at_b(text, b, op, hi);
                if (t1 != "") {
                    out = tok_push(out, t1);
                };
                let q2 = op;
                let seen = false;
                while (q2 < hi && !seen) {
                    if (b[q2] == ',' || b[q2] == '$') {
                        seen = true;
                    } else {
                        q2 = q2 + 1;
                    };
                };
                if (seen && b[q2] == ',') {
                    let t2 = tok_at_b(text, b, skip_sp(b, q2 + 1, hi), hi);
                    if (t2 != "") {
                        out = tok_push(out, t2);
                    }
                }
            }
        } else {
            if (want_jumps) {
                if (w[:1] == "j") {
                    out = tok_push(out, tok_at_b(text, b, op, hi));
                }
            }
        };
        out
    }
};

// Every symbol a byte range references, line by line.
def refs_range(text: str, b: [byte], lo: long, hi: long, out: [str], want_jumps: bool) -> [str] {
    let ls = lo;
    let i = lo;
    let res = out;
    while (i < hi) {
        if (b[i] == '\n') {
            if (!directive_line_b(b, ls)) {
                res = line_refs_b(text, b, ls, i, res, want_jumps);
            };
            ls = i + 1;
        }
        i = i + 1;
    };
    if (ls < hi) {
        if (!directive_line_b(b, ls)) {
            res = line_refs_b(text, b, ls, hi, res, want_jumps);
        };
    }
    res
};

// A line that opens with `.` is a directive, and no directive this assembler
// has names a label: `.text`/`.data`/`.bss`/`.section`/`.globl` take a section,
// `.quad`/`.zero` a number, `.string`/`.ascii` text, and `.file`/`.loc` a DWARF
// file and line -- the path in a `.file` goes in a fixup's label FIELD, which is
// not a code reference and matches no label. Scanning them was pure cost, and
// arch_consts is nearly all directives: a `.quad` of a float constant costs ~27
// instructions per byte to scan, which is ~33K instructions on every compile of
// a program that does not use math at all. The coefficient tables are the reason
// that matters (P4's five tables are ~1 KB), and it is why the skip is worth a
// measured 0.85% rather than a guess.
def directive_line_b(b: [byte], ls: long) -> bool {
    if (ls < len(b)) { b[ls] == '.' } else { false }
};

// `text_refs` (the text scan that answered this over a body's text) is gone:
// the items say all of it, and asking twice was the same answer twice. The
// text scans below stay, because arch_consts and the arch asm are still text.

// ── the same three questions, asked of a body's ITEMS ────────────────────
// A body is a list of IR items, and everything the text scans answered is in
// them: the label operands (call, jmp, jcc), the label of a `lea lbl(%rip)`
// (the only form that can name a rodata literal), and both labels of a
// `mov $A-B`. line_refs_b answered exactly this set from the text, so the
// shake keeps and drops what it did.

// Every symbol the items `ir` reference. A `mov lbl(%rip), %rax` names a
// label too, but it did not when the answer came out of the text (the `mov`
// arm only looks for `$A-B`), and the difference is what the shake prunes
// with -- so the mnemonic decides, as it did.
def ir_refs(ir: [long]) -> [str] {
    let out: [str] = [];
    let at = 0;
    while (at < len(ir)) {
        if (ir[at] < insn.IR_LABEL) {
            // a form: walk its operands by kind
            out = ir_refs_item(ir, at, out);
        };
        at += insn.IR_W;
    };
    out
};

def ir_refs_item(ir: [long], at: long, out: [str]) -> [str] {
    let f = ir[at];
    let kinds = insn.ir_form(f).kinds;
    let wp = at + 1;
    kinds.foreach((k) => {
        if (k == insn.O_LBL) {
            out = ir_refs_push(out, lname(ir[wp]));
        } else if (k == insn.O_DIFF) {
            out = ir_refs_push(out, lname(ir[wp]));
            out = ir_refs_push(out, lname(ir[wp + 1]));
        } else if (k == insn.O_MEM || k == insn.O_MEM0) {
            // A label a memory operand names is a reference whether the
            // instruction loads or stores: dropping the cell (or the rodata)
            // while the instruction that names it stays emitted is an
            // undefined label at assembly. cell_reads is the other half --
            // it decides whether that name is a READ, for the dead-global
            // initializer pass.
            let nm = lname(ir[wp + 4]);
            if (len(nm) > 0) { out = ir_refs_push(out, nm); };
        };
        wp = wp + insn.ir_kind_words(k);
    });
    out
};

// ── dead global initializers ────────────────────────────────────────────
// A global cell nothing READS does not need its initialization, and for a
// table or a record constant that is a whole RANGE of instructions (built
// element by element at startup). The emitter brackets each global's
// initializer with `ygiS_<cell>` / `ygiE_<cell>` marks (gen_decl_marked), and
// this deletes the range for a dead cell; the shake after it drops whatever
// only that range called.
//
// Reads are what keeps a cell: a load from it, an in-place op on it
// (`add %r, cell`) and a `lea cell` (someone may read it through the pointer)
// all count, so only a plain `mov <src>, <cell>` is not a read. That is what
// an unused `import math;` costs -- 6705 bytes of `const pi` and coefficient
// tables, spliced into the program's own unit, built at startup and read by
// nobody (test/sh/test_treeshake.sh is the gate, test/treeshake/costs.txt the
// ratchet).
def cell_reads(ir: [long], out: [str]) -> [str] {
    let at = 0;
    while (at < len(ir)) {
        let f = ir[at];
        if (f < insn.IR_LABEL) {
            let form = insn.ir_form(f);
            let kinds = form.kinds;
            let wp = at + 1;
            kinds.foreach((k, i) => {
                if (k == insn.O_MEM || k == insn.O_MEM0) {
                    if (!((i == len(kinds) - 1) && form.mn == "mov")) {
                        let nm = lname(ir[wp + 4]);
                        if (len(nm) > 0) { out += nm; };
                    };
                } else if (k == insn.O_LBL) {
                    // A global read is a LABEL operand, not a memory one
                    // (gen_id: `mov <cell>(%rip), %rax` is F_MOV_P_R). Only
                    // the store forms (`mov <src>, <cell>`) name a cell
                    // without reading it, and they are all `mov` with the
                    // label last.
                    if (!((i == len(kinds) - 1) && form.mn == "mov")) {
                        let nm = lname(ir[wp]);
                        if (len(nm) > 0) { out += nm; };
                    };
                };
                wp = wp + insn.ir_kind_words(k);
            });
        };
        at += insn.IR_W;
    };
    out
};

// The cell an initializer mark names, or "" for a label that is not a mark.
// `start` picks the opening one.
def mark_cell(nm: str, start: bool) -> str {
    let pre = start ? "ygiS_" : "ygiE_";
    if (len(nm) > len(pre) && nm[:len(pre)] == pre) { nm[len(pre):] } else { "" }
};

// The body's items without the initializers of `dead` cells: everything from
// an opening mark through its closing one, marks included.
// The offset of the closing mark for the range opened at `a`, or -1. Marks do
// not nest (gen_decl_marked emits one pair around one declaration), so the
// first closing mark with the same cell is the one.
def mark_end(ir: [long], a: long, cell: str) -> long {
    let at = a + insn.IR_W;
    let out = -1;
    while (at < len(ir) && out < 0) {
        if (ir[at] == insn.IR_LABEL) {
            if (mark_cell(lname(ir[at + 1]), false) == cell) { out = at; };
        };
        at = at + insn.IR_W;
    };
    out
};

// Does the range hold nothing but VALUE? `let result = main(...)` is the
// counterexample that made this necessary: the cell `result` is read by
// nobody, and the CALL inside its initializer is the entire program. So a
// range is droppable only when it makes no call (except the allocator, whose
// only effect is the memory an unread table would have held), writes no other
// cell, and holds no raw text.
def range_is_pure(ir: [long], a: long, b: long, cell: str) -> bool {
    let ok = true;
    let at = a;
    while (at <= b && ok) {
        let f = ir[at];
        if (f == insn.IR_TEXT) { ok = false; }
        else if (f < insn.IR_LABEL) {
            let form = insn.ir_form(f);
            let kinds = form.kinds;
            if (form.mn == "call") {
                if (lname(ir[at + 1]) != "y_alloc") { ok = false; };
            } else if (len(kinds) > 0 && form.mn == "mov" && kinds[len(kinds) - 1] == insn.O_MEM) {
                let wp = at + 1;
                for i in 0..len(kinds) - 1 { wp = wp + insn.ir_kind_words(kinds[i]); };
                let nm = lname(ir[wp + 4]);
                if (len(nm) > 0 && nm != cell) { ok = false; };
            } else if (len(kinds) > 0 && form.mn == "mov" && kinds[len(kinds) - 1] == insn.O_LBL) {
                let wp = at + 1;
                for i in 0..len(kinds) - 1 { wp = wp + insn.ir_kind_words(kinds[i]); };
                let nm = lname(ir[wp]);
                if (len(nm) > 0 && nm != cell) { ok = false; };
            };
        };
        at = at + insn.IR_W;
    };
    ok
};

def ir_drop_inits(ir: [long], dead: [str]) -> [long] {
    let out: [long] = [];
    let at = 0;
    let keep_from = 0;
    let skipping = "";
    // Whether anything was actually dropped. Most bodies have no dead cell in
    // them at all, and the answer for those must be the SAME array: building
    // `out` copies every item in the body, and the bench-ir run of the first
    // version showed exactly that as +1-2% compile instructions (maps.y
    // +2.28%) on programs with nothing to delete.
    let dropped = false;
    while (at < len(ir)) {
        if (ir[at] == insn.IR_LABEL) {
            let nm = lname(ir[at + 1]);
            let s0 = mark_cell(nm, true);
            let e0 = mark_cell(nm, false);
            if (len(s0) > 0 && len(skipping) == 0 && name_in(dead, s0)) {
                let e_at = mark_end(ir, at, s0);
                if (e_at >= 0 && range_is_pure(ir, at, e_at, s0)) {
                    // keep the run before the mark, then skip to its pair
                    out += ir[keep_from:at];
                    skipping = s0;
                    dropped = true;
                };
            } else if (len(e0) > 0 && e0 == skipping) {
                skipping = "";
                keep_from = at + insn.IR_W;
            };
        };
        at += insn.IR_W;
    };
    // The runs are copied by SLICE and appended with `+=`: appending word by
    // word is what the rodata comment above calls out -- each append copies
    // the whole accumulator, and on a self-compilation that is 1.4MB of items
    // copied 175,000 times, which runs the compiler out of memory.
    if (len(skipping) == 0) { out += ir[keep_from:len(ir)]; };
    if (dropped) { out } else { ir }
};

// tok_push's rule (an empty token is no name) -- which is how the text scans
// dropped the pseudo-operands a non-label `lea` used to contribute.
def ir_refs_push(out: [str], nm: str) -> [str] {
    if (len(nm) == 0) { out } else { out += nm }
};

// Point a body's `lea` at the label its literal's text ended up with (see
// rodata_intern). Only the `lea <label>(%rip)` form can name a literal, so
// that is the only field this rewrites -- the label of an O_MEM operand under
// a `lea`.
def ir_relabel(ir: [long], m: [AsmLabel], dup_new: [str]) -> [long] {
    let at = 0;
    while (at < len(ir)) {
        let f = ir[at];
        if (f < insn.IR_LABEL) {
            let kinds = insn.ir_form(f).kinds;
            let wp = at + 1;
            kinds.foreach((k) => {
                if (k == insn.O_LBL) {
                    ir[wp] = ir_relabel_one(ir[wp], m, dup_new);
                } else if (k == insn.O_DIFF) {
                    ir[wp] = ir_relabel_one(ir[wp], m, dup_new);
                    ir[wp + 1] = ir_relabel_one(ir[wp + 1], m, dup_new);
                } else if (k == insn.O_MEM || k == insn.O_MEM0) {
                    if (insn.ir_form(f).mn == "lea") {
                        ir[wp + 4] = ir_relabel_one(ir[wp + 4], m, dup_new);
                    };
                };
                wp = wp + insn.ir_kind_words(k);
            });
        };
        at += insn.IR_W;
    };
    ir
};

def ir_relabel_one(id: long, m: [AsmLabel], dup_new: [str]) -> long {
    // The label's own length is what is cut out: the winner's label is what
    // gets longer or shorter.
    let g = asm.labmap_get(m, lname(id));
    if (g.sec > 0) { lbl_new(dup_new[g.off]) } else { id }
};

// A unit's bodies as the pack carries them: the items (pack_body), one
// blob each.
def pack_bodies(u: Unit) -> [str] {
    let out: [str] = [];
    for b in 0..len(u.bodies) {
        out += pack_body(u, b);
    };
    out
};

// The label a line [lo, hi) defines, or "".
def label_at(text: str, b: [byte], lo: long, hi: long) -> str {
    let p = skip_sp(b, lo, hi);
    let e = tok_end_b(b, p, hi);
    let lab = "";
    if (e > p) {
        if (e < hi) {
            if (b[e] == ':') {
                let s = p;
                if (b[s] == '$') { s = s + 1; }
                lab = text[s:e];
            }
        }
    }
    lab
};

// A line that is data, not code: blank lines, directives, or a bare label
// (possibly followed by data on the same line).
def is_data_line_b(text: str, b: [byte], lo: long, hi: long) -> bool {
    let lab = label_at(text, b, lo, hi);
    let p = skip_sp(b, lo, hi);
    if (len(lab) > 0) {
        p = skip_sp(b, p + 1 + len(lab), hi);
    }
    if (p >= hi) {
        true
    } else {
        b[p] == '.'
    }
};

// Does a block [lo, hi) run into the next one? Only when its last
// instruction is not a transfer; `ret`/`jmp`/`syscall` end the block (the
// trap stubs end in an exit syscall and must not drag the file along).
def block_falls_b(text: str, b: [byte], lo: long, hi: long) -> bool {
    let end = hi;
    let falls = true;
    let go = true;
    while (go) {
        // start of the last line in [lo, end)
        let p = lo;
        for i in lo..end {
            if (b[i] == '\n') {
                p = i + 1;
            }
        };
        let s = skip_sp(b, p, end);
        if (s >= end) {
            // blank line: drop it and look at the line before
            if (p > lo) {
                end = p - 1;
            } else {
                go = false;
            };
        } else {
            go = false;
            let w = tok_at_b(text, b, s, end);
            if (w == "ret") { falls = false; }
            else if (w == "jmp") { falls = false; }
            else if (w == "syscall") { falls = false; }

        };
    };
    falls
};

// ── name -> index, for the tree shaker ───────────────────────────────────
// `shake_keep` resolves one name per reference, ~191k of them per compile
// against a few hundred names, so scanning the names each time was 24% of
// everything ycc executes (and grew with the program). These two are thin
// wrappers over asm.y's labmap -- the open-addressing table ycc already has
// -- not a second implementation of it.
//
// labmap marks an empty slot with the empty string, and an unnamed block's
// name IS "" (shake_refs keys keep[k] on it), so "" is not inserted. That
// costs nothing: every key the shaker looks up is a real identifier or
// label, because tok_push drops empty tokens when refs/roots are built.
// The index travels in labmap's `sec` field, which labmap_get leaves at -1
// when the name is absent -- so one read answers both questions.

def namemap_build(names: [str]) -> [AsmLabel] {
    let m = asm.labmap_new(len(names) * 2 + 16);
    names.foreach((e, i) => {
        let nm: str = e;
        if (len(nm) > 0) {
            // First insert wins, as a scan for the first match did.
            m = (asm.labmap_put(m, nm, i, 0)).map;
        }
    });
    m
};

// Index of `name` among the names it was built from, or -1.
def namemap_get(m: [AsmLabel], name: str) -> long {
    (asm.labmap_get(m, name)).sec
};

// The defs a unit's bodies see (EmitSt.fns: the hoisted defs, then the
// externs, then the globals) with an index by name. No env holds them:
// env_find and the capture scans look a name up here, where every
// function's env used to be pre-loaded with all of them (~1.6k entries
// in the compiler) and scanned. Of entries sharing a name the last wins,
// as the backward env scan had it, so the index is filled from the end
// (labmap keeps the first).
// `ids` is parallel to `syms`: each def's label as an id, minted by the
// CALLER (compile_unit, once per def, where it binds the def's env entry too)
// and passed in here. env_find's miss path runs per identifier emitted, so
// interning there would grow the table once per lookup; and this table is
// built four times per unit as fix_fn_types retypes the defs, so interning
// per build was five lookups per def where one will do (measured: +1.9% of a
// compile, most of it hash_str).
type FnTab = { syms: [Sym], ix: [AsmLabel], ids: [long] };

def fntab_of(syms: [Sym], ids: [long]) -> FnTab {
    let m = asm.labmap_new(len(syms) * 2 + 16);
    let i = len(syms) - 1;
    while (i >= 0) {
        let e = syms[i];
        if (len(e.name) > 0) {
            m = (asm.labmap_put(m, e.name, i, 0)).map;
        };
        i = i - 1;
    };
    { syms: syms, ix: m, ids: ids }
};

// `ids` for a Sym list: intern each label, in order.
def fntab_ids(syms: [Sym]) -> [long] {
    let ids: [long] = [];
    syms.foreach((e) => {
        ids += lbl_new(e.label);
    });
    ids
};

// Mark every names[i] some entry of `roots` points at, then close over kept
// blocks: their own references and (for code that runs into the next block)
// their successor. `falls[i]` says block i falls through to block i+1.
def shake_keep(names: [str], refs: [[str]], falls: [bool], keep: [bool], roots: [str]) -> [bool] {
    let n = len(names);
    let map = namemap_build(names);
    roots.foreach((e) => {
        let idx = namemap_get(map, e);
        if (idx >= 0) { keep[idx] = true; }
    });
    let scanned: [bool] = [];
    for i in 0..n {
        scanned += false;
    };
    let more = true;
    while (more) {
        more = false;
        for b in 0..n {
            if (keep[b]) {
                if (!(scanned[b])) {
                    scanned[b] = true;
                    more = true;
                    if (falls[b]) {
                        if (b + 1 < n) {
                            if (!(keep[b + 1])) { keep[b + 1] = true; }
                        }
                    }
                    refs[b].foreach((e) => {
                        let idx = namemap_get(map, e);
                        if (idx >= 0) {
                            if (!(keep[idx])) { keep[idx] = true; }
                        }
                    });
                }
            }
        };
    };
    keep
};

// Keep only the blocks of `text` that `root_refs` (the program's own
// references) or another kept block reaches. Output order matches input.
def shake_refs(text: str, root_refs: [str]) -> str {
    let b = bytes(text);
    let n = len(b);
    // every label starts a block; lines before the first label (directives)
    // form a head block that is always kept
    let names: [str] = [];
    let starts: [long] = [];
    let i = 0;
    let ls = 0;
    while (i < n) {
        if (b[i] == '\n') {
            let lab = label_at(text, b, ls, i);
            if (len(lab) > 0) {
                names += lab;
                starts += ls;
            } else {
                if (len(starts) == 0) {
                    names += "";
                    starts += 0;
                }
            };
            ls = i + 1;
        }
        i++;
    };
    if (ls < n) {
        let lab = label_at(text, b, ls, n);
        if (len(lab) > 0) {
            names += lab;
            starts += ls;
        } else {
            if (len(starts) == 0) {
                names += "";
                starts += 0;
            }
        };
    }
    let nb = len(starts);
    if (nb == 0) {
        text
    } else {
        // per-block references + fall-through flags
        let refs: [[str]] = [];
        let falls: [bool] = [];
        let k = 0;
        while (k < nb) {
            let lo = starts[k];
            let hi = n;
            if (k + 1 < nb) { hi = starts[k + 1]; }
            refs += [refs_range(text, b, lo, hi, [], true)];
            if (block_falls_b(text, b, lo, hi)) {
                if (is_data_line_b(text, b, lo, hi)) {
                    falls += false;
                } else {
                    falls += true;
                };
            } else {
                falls += false;
            };
            k++;
        };
        let keep: [bool] = [];
        k = 0;
        while (k < nb) {
            if (len(names[k]) == 0) {
                keep += true;
            } else {
                keep += false;
            };
            k++;
        };
        keep = shake_keep(names, refs, falls, keep, root_refs);
        // reassemble kept blocks (their byte ranges), in order
        let pieces: [str] = [];
        k = 0;
        while (k < nb) {
            if (keep[k]) {
                let lo = starts[k];
                let hi = n;
                if (k + 1 < nb) { hi = starts[k + 1]; }
                pieces += text[lo:hi];
            }
            k++;
        };
        join(pieces, "")
    }
};

// ── the arch prelude, shaken by lines ────────────────────────────────────
// The prelude is ~1.7k lines of which a program keeps a few dozen, and
// shaking it as text scanned all of it on every compile: two thirds of a
// small program's compile. It comes as its lines (arch_prelude_lines):
// labels alone at column 0, everything else indented, so its blocks are
// found by each line's first byte, and only the blocks a program reaches
// are scanned for references. Blocks and rules are shake_refs'.
type PBlocks = { lines: [str], starts: [long], names: [str], ix: [AsmLabel] };
// The kept text, and every reference the kept blocks make.
// The kept prelude: its text, every reference the kept blocks make, and the
// per-block [name, direct refs] the --gc analysis closes over.
type PShake = { text: str, refs: [str], bnames: [str], brefs: [[str]] };

// Every name in types.y's os_call_names must be a label in the arch lines
// that were actually emitted. This runs on both targets, and it is here rather
// than in the checker because this is the one module that sees BOTH the list
// (types.y) and the arch module's output -- types.y must not import
// arch_x64.y, because a path import is flattened into its importer and the two
// would define the same names twice.
//
// Without it, a name added to one arch half and not the other is a LINK error,
// on one target only, and only in a program whose std units happen to call it:
// the most expensive kind of bug to find and the easiest to make. A name in the
// list with no block behind it is a compile error with a message naming it.
// Every name in types.y's os_call_names must be a label of the arch lines this
// target assembles. ONE pass: collect the column-0 labels, then look each name
// up in them. The first cut was names x lines -- every name scanned every line
// with a string compare -- and when y_os_stat made that 13 names over a
// ~1900-line prelude it cost 2.59% of a small compile (bench-ir, hello.y) for a
// check that runs once. The C copy did not have the check at all; PORTING.md
// says it must, so it is here twice now.
def check_os_call_names(lines: [str]) -> [str] {
    let labels: [str] = [];
    lines.foreach((e) => {
        let nm = arch_label_name(e);
        if (nm != "") { labels += nm; };
    });
    types.os_call_names().foreach((e) => {
        let found = false;
        for k in 0..len(labels) {
            if (labels[k] == e) { found = true; };
        };
        if (!found) {
            puts("error: os_call_names lists '" + e
            + "', which the arch lines do not define ("
            + (if (target_is_windows()) { "src/y/arch/wsys.s" } else { "src/y/arch/prelude.s" })
            + ")\n");
            exit(1);
        };
    });
    lines
};

// The name of a column-0 `label:` line and NOTHING else, or "" -- an indented
// label (wsys.s has several), a line with data after the label
// (`ystr_divzero: .ascii "..."`), and a line that does not end in a colon are
// all "". The arch module's own marker (arch_is_label_line) is a different,
// laxer test; native.y cannot reach into arch_x64.y's non-exported defs, and a
// whole-line '#' comment has already been dropped by then.
def arch_label_name(l: str) -> str {
    if (len(l) < 2) { "" }
    else if (l[len(l) - 1] != 58) { "" }
    else {
        let nm = l[0:len(l) - 1];
        let ok = true;
        for i in 0..len(nm) {
            let c = nm[i];
            if (c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) { } else { ok = false; };
        };
        if (ok) { nm } else { "" }
    }
};

def prelude_blocks(lines: [str]) -> PBlocks {
    let starts: [long] = [];
    let names: [str] = [];
    lines.foreach((e, i) => {
        let l: str = e;
        let lab = "";
        if (len(l) > 0 && l[0] != 32) {
            let lb = bytes(l);
            lab = label_at(l, lb, 0, len(lb));
        };
        if (len(lab) > 0) {
            names += lab;
            starts += i;
        } else if (len(starts) == 0) {
            names += "";
            starts += 0;
        };
    });
    { lines: lines, starts: starts, names: names, ix: namemap_build(names) }
};

// Every reference the lines [lo, hi) make.
def lines_refs(lines: [str], lo: long, hi: long) -> [str] {
    let out: [str] = [];
    for i in lo..hi {
        let l: str = lines[i];
        let lb = bytes(l);
        out = line_refs_b(l, lb, 0, len(lb), out, true);
    };
    out
};

// Does the block of lines [lo, hi) run into the next one? block_falls_b
// and is_data_line_b on its lines.
def lines_fall(lines: [str], lo: long, hi: long) -> bool {
    let falls = true;
    let i = hi - 1;
    let go = true;
    while (go && i >= lo) {
        let l: str = lines[i];
        let lb = bytes(l);
        let s = skip_sp(lb, 0, len(lb));
        if (s < len(lb)) {
            go = false;
            if ((tok_at_b(l, lb, s, len(lb))) in ["ret", "jmp", "syscall"]) { falls = false; };
        };
        i = i - 1;
    };
    if (falls) {
        let l0: str = lines[lo];
        let b0 = bytes(l0);
        let lab = label_at(l0, b0, 0, len(b0));
        let p = skip_sp(b0, 0, len(b0));
        if (len(lab) > 0) { p = skip_sp(b0, p + 1 + len(lab), len(b0)); };
        if (p < len(b0)) {
            if (b0[p] == '.') { falls = false; }
        };
    };
    falls
};

// Keep the blocks `roots` (the kept bodies' references) or a kept block
// reaches, as shake_keep does, scanning only those.
def shake_prelude(pb: PBlocks, roots: [str]) -> PShake {
    let lines = pb.lines;
    let starts = pb.starts;
    let names = pb.names;
    let nb = len(starts);
    let keep: [bool] = [];
    let scanned: [bool] = [];
    let brefs: [[str]] = [];
    let k = 0;
    while (k < nb) {
        let nm: str = names[k];
        keep += len(nm) == 0;
        scanned += false;
        let none: [str] = [];
        brefs += [none];
        k++;
    };
    roots.foreach((e) => {
        let idx = namemap_get(pb.ix, e);
        if (idx >= 0) { keep[idx] = true; };
    });
    let more = true;
    while (more) {
        more = false;
        for b in 0..nb {
            if (keep[b] && !(scanned[b])) {
                scanned[b] = true;
                more = true;
                let lo = starts[b];
                let hi = len(lines);
                if (b + 1 < nb) { hi = starts[b + 1]; };
                let rs = lines_refs(lines, lo, hi);
                brefs[b] = rs;
                if (b + 1 < nb && lines_fall(lines, lo, hi)) { keep[b + 1] = true; };
                rs.foreach((e) => {
                    let idx = namemap_get(pb.ix, e);
                    if (idx >= 0) { keep[idx] = true; };
                });
            };
        };
    };
    let pieces: [str] = [];
    let out: [str] = [];
    let knames: [str] = [];
    let krefs: [[str]] = [];
    k = 0;
    while (k < nb) {
        if (keep[k]) {
            let lo = starts[k];
            let hi = len(lines);
            if (k + 1 < nb) { hi = starts[k + 1]; };
            for i in lo..hi {
                pieces += lines[i];
                pieces += "\n";
            };
            out += brefs[k];
            knames += names[k];
            krefs += brefs[k];
        };
        k++;
    };
    { text: join(pieces, ""), refs: out, bnames: knames, brefs: krefs }
};

// The prelude's lines, then the thread runtime's and the float primitives'
// after them when a program's code calls into them.
//
// Appending one at a time is not just tidier: `+` on an array makes a NEW one,
// so concatenating unconditionally copied the prelude's ~1500 lines for every
// compile that wanted neither -- 52K instructions on hello.y, which is 99.9%
// of what this module cost before the branches (callgrind, bench/compile_ir.sh).
def prelude_with(core: [str], threads: bool, mathasm: bool) -> [str] {
    let out: [str] = core;
    if (threads) { out = out + arch.arch_prelude_threads_lines(); };
    if (mathasm) { out = out + arch.arch_math_lines(); };
    out
};

// The references (a kept prelude's) that name a body not kept.
def unkept_refs(refs: [str], bmap: [AsmLabel], keep: [bool]) -> [str] {
    let out: [str] = [];
    refs.foreach((e) => {
        let idx = namemap_get(bmap, e);
        if (idx >= 0) {
            if (!(keep[idx])) { out += e; };
        };
    });
    out
};

// Drop function bodies nothing reaches: dead stdlib code the program never
// calls. A body is given by its label and the labels it references
// (body_meta). Bodies are referenced by label from other bodies AND from
// the arch prelude (a prelude block may call a Y-side helper), so
// `extra_roots` are the kept prelude's references to bodies (link_units).
// Returns, per body, whether it was kept,
// plus everything the kept ones reference — the roots for shaking the
// arch prelude itself.
def prune_bodies(labels: [str], refs: [[str]], extra_roots: [str]) -> { refs: [str], keep: [bool] } {
    let nb = len(labels);
    let keep: [bool] = [];
    let falls: [bool] = [];
    let i = 0;
    while (i < nb) {
        keep += false;
        falls += false;
        i++;
    };
    let roots: [str] = [];
    roots += extra_roots;
    if ((namemap_get(namemap_build(labels), "_start")) >= 0) {
        roots += "_start";
    }
    keep = shake_keep(labels, refs, falls, keep, roots);
    let outrefs: [str] = [];
    i = 0;
    while (i < nb) {
        if (keep[i]) {
            refs[i].foreach((e) => {
                outrefs += e;
            });
        }
        i++;
    };
    { refs: outrefs, keep: keep }
};

// ── runtime helper labels ──────────────────────────────────────────────
// Generated code calls the runtime by FIXED label (`call y_print_long`), so
// a helper defined in std/rt.y must be emitted under its bare name even
// though rename suffixes every binding with `$N`. `y_` is therefore
// reserved for the runtime: a `y_*` def whose name is `base` or `base$N`
// (rename's uniquifier) is labelled `base`, and one shadowed by a later
// def (`base$shadowK`) falls back to a normal uid label — the later def
// wins the bare name, so a program may override any runtime helper.

def is_all_digits(s: str) -> bool {
    if (len(s) == 0) {
        false
    } else {
        let i = 0;
        let ok = true;
        while (i < len(s)) {
            if (index_of("0123456789", s[i:i + 1]) < 0) { ok = false; }
            i++;
        };
        ok
    }
};

// The bare runtime name behind `name`, or "" when it is not one.
def runtime_base(name: str) -> str {
    if (len(name) < 3) {
        ""
    } else {
        if (name[:2] != "y_") {
            ""
        } else {
            let dollar = index_of(name, "$");
            if (dollar < 0) {
                name
            } else {
                if (is_all_digits(name[dollar + 1:])) {
                    name[:dollar]
                } else {
                    ""
                }
            }
        }
    }
};

def fn_label_of(uid: long, name: str) -> str {
    let base = runtime_base(name);
    if (len(base) > 0) {
        base
    } else {
        arch.arch_fn_label(uid, name)
    }
};

def is_ns(name: str, imports: [str]) -> bool {
    let i = 0;
    let found = false;
    while (i < len(imports)) {
        if (imports[i] == name) { found = true; }
        i++;
    };
    found
};

// Identity helper giving rebuilt expression arms the shared AST union type.
def normnode(anode: Node) -> Node { anode };

// Type constructors flow through their separate type-node union.
def normtype(ty: Type) -> Type { ty };

// strip_namespaces: dot(NAME, key) with NAME an import namespace -> id(key).
// Full AST rebuild (only dot nodes change, but uniform rebuild is simplest).

// `m.T` -> `T`, when `m` names a path import. Anything else unchanged: a
// primitive name, a bare name, or a PACKAGE-qualified one, which `strip_ns`'s
// own Dot arm keeps on purpose (pkg_ns) because a package is linked as a unit of
// its own and its names stay qualified.
def strip_ns_name(q: str, imports: [str]) -> str {
    let out = q;
    let dot = index_of(q, ".");
    if (dot > 0) {
        if (is_ns((q[0:dot]), imports)) { out = q[dot + 1:len(q)]; };
    };
    out
}

// A type with a path-import namespace stripped.
//
// strip_ns has always done this for EXPRESSIONS -- `m.f(x)` is a call to `f` --
// and the origin map documents the consequence: a file imported BY PATH
// contributes no module name, because everything of its is already flat. That
// was true of expressions and false of TYPES, and the asymmetry was a bug rather
// than a decision.
//
// A `type` alias in a path-imported module is registered by rename under its
// BARE name: rn_prepass_one qualifies a statement only when rn_stmt_mod names its
// module, and rn_stmt_mod reads `mods`, which native_resolve fills with "" for
// every path import (native.y 623, and the note above `type Origin` says so).
// A reference to that alias is written `m.T`, which the parser keeps as a tname
// spelled "m.T" (parser.y 1128) and which nothing had rewritten. So:
//
//     import m from "./mod.y";
//     let p: m.Pair = m.mk(1, 2);      error: unknown type 'm.Pair'
//     let p: Pair = m.mk(1, 2);        compiles
//
// Two spellings of one declaration in a language that documents a path import as
// flattened. Stripping the prefix here makes a type behave like an expression,
// which is what the ORIGIN MAP's own note already claimed.
def strip_type(t: Type, imports: [str]) -> Type {
    let k = t.k;
    if (k == K.tname) {
        let nm: TName = t;
        let out: TName = { k: K.tname, name: strip_ns_name(nm.name, imports) };
        let result: Type = out;
        result
    } else if (k == K.tptr) {
        let ptr: TPtr = t;
        let out: TPtr = { k: K.tptr, to: strip_type(ptr.to, imports) };
        let result: Type = out;
        result
    } else if (k == K.tarr) {
        let arr: TOf = t;
        let out: TOf = { k: K.tarr, of: strip_type(arr.of, imports) };
        let result: Type = out;
        result
    } else if (k == K.tarrfix) {
        let arr: TFix = t;
        let out: TFix = { k: K.tarrfix, of: strip_type(arr.of, imports), n: arr.n };
        let result: Type = out;
        result
    } else if (k == K.topt) {
        let opt: TOf = t;
        let out: TOf = { k: K.topt, of: strip_type(opt.of, imports) };
        let result: Type = out;
        result
    } else if (k == K.tmap) {
        let map: TMap = t;
        let out: TMap = { k: K.tmap, key: strip_type(map.key, imports), of: strip_type(map.of, imports) };
        let result: Type = out;
        result
    } else if (k == K.tparams) {
        let list: TList = t;
        let out: TList = { k: K.tparams, ts: strip_type_list(list.ts, imports) };
        let result: Type = out;
        result
    } else if (k == K.tunion) {
        let list: TList = t;
        let out: TList = { k: K.tunion, ts: strip_type_list(list.ts, imports) };
        let result: Type = out;
        result
    } else if (k == K.tfunc) {
        let func: TFunc = t;
        let out: TFunc = { k: K.tfunc, args: strip_type_list(func.args, imports), ret: strip_type(func.ret, imports) };
        let result: Type = out;
        result
    } else if (k == K.trec) {
        let rec: TRec = t;
        let fs: [Field] = [];
        foreach (f in rec.fields) { fs += { name: f.name, opt: f.opt, typ: strip_type(f.typ, imports) }; };
        let out: TRec = { k: K.trec, fields: fs };
        let result: Type = out;
        result
    } else { t }
}

def strip_type_list(ts: [Type], imports: [str]) -> [Type] {
    let out: [Type] = [];
    ts.foreach((e) => {
        out += strip_type(e, imports);
    });
    out
}

def strip_list(nodes: [Node], imports: [str]) -> [Node] {
    let out: [Node] = [];
    nodes.foreach((e) => {
        out += strip_ns(e, imports);
    });
    out
};

def strip_ns(node: Node, imports: [str]) -> Node {
    let k = node.k;
    if (k == K.dot) {
        let dot: Dot = node;
        let obj = strip_ns(dot.obj, imports);
        let okey = dot.key;
        let oline = dot.line;
        let ocol = dot.col;
        if (obj.k == K.id) {
            let id: Leaf = obj;
            let ov = id.v;
            if (is_ns(ov, imports)) {
                normnode({ k: K.id, v: okey, line: oline, col: ocol })
            } else if (is_ns(ov, pkg_ns)) {
                normnode({ k: K.id, v: ov + "." + okey, line: oline, col: ocol })
            } else {
                normnode({ k: K.dot, obj: obj, key: okey, line: oline, col: ocol, nline: oline, ncol: ocol })
            }
        } else {
            normnode({ k: K.dot, obj: obj, key: okey, line: oline, col: ocol, nline: oline, ncol: ocol })
        }
    } else if (k == K.un) {
        let un: Un = node;
        normnode({ k: K.un, op: un.op, e: strip_ns(un.e, imports), line: un.line, col: un.col })
    } else if (k == K.addr || k == K.deref) {
        let wrap: Wrap = node;
        normnode({ k: k, e: strip_ns(wrap.e, imports), line: wrap.line, col: wrap.col })
    } else if (k == K.bin) {
        let bin: Bin = node;
        normnode({ k: K.bin, op: bin.op, l: strip_ns(bin.l, imports), r: strip_ns(bin.r, imports), line: bin.line, col: bin.col })
    } else if (k == K.call) {
        let call: Call = node;
        normnode({ k: K.call, callee: strip_ns(call.callee, imports), args: strip_list(call.args, imports), line: call.line, col: call.col })
    } else if (k == K.kw_if) {
        let branch: If = node;
        normnode({ k: K.kw_if, cond: strip_ns(branch.cond, imports), then: strip_ns(branch.then, imports), els: strip_ns(branch.els, imports), has_else: branch.has_else, line: branch.line, col: branch.col })
    } else if (k == K.kw_while) {
        let loop: While = node;
        normnode({ k: K.kw_while, cond: strip_ns(loop.cond, imports), body: strip_ns(loop.body, imports), line: loop.line, col: loop.col })
    } else if (k == K.block) {
        let block: Block = node;
        normnode({ k: K.block, stmts: strip_list(block.stmts, imports), line: block.line, col: block.col })
    } else if (k == K.decl) {
        let decl: Decl = node;
        strip_decl(decl, imports)
    } else if (k == K.func) {
        let func: Func = node;
        // `ppos` through: stripping a namespace rewrites names and types, never
        // positions, and a parameter's position is where an editor points at it.
        normnode({ k: K.func, params: func.params, ptypes: strip_type_list(func.ptypes, imports), ret: strip_type(func.ret, imports), body: strip_ns(func.body, imports), line: func.line, col: func.col, defs: func.defs, label: func.label, ppos: func.ppos })
    } else if (k == K.assign) {
        let assign: Assign = node;
        normnode({ k: K.assign, name: assign.name, v: strip_ns(assign.v, imports), line: assign.line, col: assign.col })
    } else if (k == K.incdec) {
        let incdec: IncDec = node;
        normnode({ k: K.incdec, op: incdec.op, pre: incdec.pre, tgt: strip_ns(incdec.tgt, imports), line: incdec.line, col: incdec.col })
    } else if (k == K.opassign) {
        let assign: OpAssign = node;
        normnode({ k: K.opassign, op: assign.op, tgt: strip_ns(assign.tgt, imports), v: strip_ns(assign.v, imports), line: assign.line, col: assign.col })
    } else if (k == K.store) {
        let store: Store = node;
        normnode({ k: K.store, p: strip_ns(store.p, imports), v: strip_ns(store.v, imports), line: store.line, col: store.col })
    } else if (k == K.ret) {
        let ret: Wrap = node;
        normnode({ k: K.ret, e: strip_ns(ret.e, imports), line: ret.line, col: ret.col })
    } else if (k == K.array) {
        let array: ArrLit = node;
        normnode({ k: K.array, elems: strip_list(array.elems, imports), line: array.line, col: array.col })
    } else if (k == K.arrrep) {
        let rep: ArrRep = node;
        normnode({ k: K.arrrep, v: strip_ns(rep.v, imports), n: rep.n, line: rep.line, col: rep.col })
    } else if (k == K.rec) {
        let rec: RecLit = node;
        normnode({ k: K.rec, keys: rec.keys, vals: strip_list(rec.vals, imports), line: rec.line, col: rec.col })
    } else if (k == K.map) {
        let map: RecLit = node;
        normnode({ k: K.map, keys: map.keys, vals: strip_list(map.vals, imports), line: map.line, col: map.col })
    } else if (k == K.index) {
        let index: Index = node;
        normnode({ k: K.index, arr: strip_ns(index.arr, imports), idx: strip_ns(index.idx, imports), line: index.line, col: index.col })
    } else if (k == K.slice) {
        let slice: Slice = node;
        normnode({ k: K.slice, arr: strip_ns(slice.arr, imports), lo: strip_ns(slice.lo, imports), hi: strip_ns(slice.hi, imports), line: slice.line, col: slice.col })
    } else if (k == K.idxassign) {
        let assign: IdxAssign = node;
        normnode({ k: K.idxassign, arr: strip_ns(assign.arr, imports), idx: strip_ns(assign.idx, imports), v: strip_ns(assign.v, imports), line: assign.line, col: assign.col })
    } else if (k == K.dotassign) {
        let assign: DotAssign = node;
        let dao = assign.obj;
        if (dao.k == K.id) {
            let id: Leaf = dao;
            if (is_ns(id.v, pkg_ns)) {
                // `json.limit = v`: a package's global, which is read-only
                // (the checker says so of the qualified name)
                normnode({ k: K.assign, name: id.v + "." + assign.key, v: strip_ns(assign.v, imports), line: assign.line, col: assign.col })
            } else {
                normnode({ k: K.dotassign, obj: strip_ns(dao, imports), key: assign.key, v: strip_ns(assign.v, imports), line: assign.line, col: assign.col, nline: assign.nline, ncol: assign.ncol })
            }
        } else {
            normnode({ k: K.dotassign, obj: strip_ns(dao, imports), key: assign.key, v: strip_ns(assign.v, imports), line: assign.line, col: assign.col, nline: assign.nline, ncol: assign.ncol })
        }
    } else if (k == K.kw_foreach) {
        let loop: Foreach = node;
        normnode({ k: K.kw_foreach, name: loop.name, iter: strip_ns(loop.iter, imports), body: strip_ns(loop.body, imports), line: loop.line, col: loop.col })
    } else if (k == K.forrange) {
        let loop: ForRange = node;
        normnode({ k: K.forrange, name: loop.name, lo: strip_ns(loop.lo, imports), hi: strip_ns(loop.hi, imports), body: strip_ns(loop.body, imports), line: loop.line, col: loop.col })
    } else if (k == K.kw_for) {
        let loop: For = node;
        normnode({ k: K.kw_for, init: strip_ns(loop.init, imports), cond: strip_ns(loop.cond, imports), step: strip_ns(loop.step, imports), body: strip_ns(loop.body, imports), line: loop.line, col: loop.col })
    } else if (k == K.sliceassign) {
        let assign: SliceAssign = node;
        normnode({ k: K.sliceassign, arr: strip_ns(assign.arr, imports), lo: strip_ns(assign.lo, imports), hi: strip_ns(assign.hi, imports), v: strip_ns(assign.v, imports), line: assign.line, col: assign.col })
    } else {
        normnode(node)
    }
};

def strip_decl(node: Decl, imports: [str]) -> Node {
    if (node.kind == "def") {
        normnode({ k: K.decl, kind: "def", name: node.name, typ: normtype({ k: K.tnone }), v: strip_ns(node.v, imports), line: node.line, col: node.col, nline: node.nline, ncol: node.ncol })
    } else {
        normnode({ k: K.decl, kind: node.kind, name: node.name, typ: strip_type(node.typ, imports), v: strip_ns(node.v, imports), line: node.line, col: node.col, nline: node.nline, ncol: node.ncol })
    }
};

// ── emit state ─────────────────────────────────────────────────────────
// st: an EmitSt. env: FLAT list of Slots — names are unique
// post-rename, so no scopes or shadowing. kind: "local"|"param" (frame
// slot at off), "func" (label), "global" (.bss cell at label),
// "closure" (slot holding a record), "box"/"capture" (shared cells).
// `label` is an id (see label identities); `mark` is the str a slot of kind
// "boxmark"/"appmark" carries instead -- a name to match against -- and a
// "capture"'s capture index (as text, see gen_addr).
type Slot = { name: str, kind: str, off: long, label: long, mark: str, typ: Type };
type ArrTy = TOf | TFix;
type NodeE = Wrap | Un | Narrow | MatchEnd;
type NodeV = ArrRep | Assign | Decl;
type EmitMain = { params: [str], ptypes: [Type], ret: Type, body: Node, line: long, col: long };
type EmitFunc = Func | EmitMain;
// `blabels` is parallel to `bodies`: the name each body's text opens with,
// which the linker shakes by (Unit.labels). The emitter knows both -- it wrote
// them -- so no scan of the text is needed to recover them.
// `bodies` is each body's IR items (ir.y) and `txt` the raw lines their
// IR_TEXT items index -- the whole unit's, since the items index into it.
// `bodies` is each body's IR items (ir.y), `btext` the raw lines its
// IR_TEXT items index -- that body's own, since a function is emitted with a
// fresh `txt` (emit_one_fn) -- and `txt` the lines the body being emitted now
// writes to.
// `slots` counts the frame slots a block's NAMES and loop state hold (a
// stack of block depths: see gen_block_as); `temp` counts the slots ONE
// statement's temporaries hold, released as that statement ends. Locals come
// first, so a temporary sits below every local of the block -- which is what
// keeps a statement's temporaries safe from the blocks inside it.
type EmitSt = { ir: [long], txt: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [Slot], slots: long, temp: long, self_label: long, end_label: long, fns: FnTab, bodies: [[long]], btext: [[str]], blabels: [str] };
// The state after making a label (next_loc, ty_desc), and the label's id.
type StLbl = { st: EmitSt, label: long };

def st_new() -> EmitSt {
    { ir: [], txt: [], rodata: [], uid: 1, fuid: 0, loc: 1, env: [],
        slots: 0, temp: 0, self_label: -1, end_label: -1, fns: fntab_of([], []), bodies: [], btext: [],
        blabels: [] }
};

// The state with its IR buffer (and, where it changes, its raw lines)
// replaced: every append to a body goes through one of these, the way every
// append to `out` went through emit.
// The DEEPEST frame the function being emitted ever needs: st.slots is a
// stack of block depths (st_slots), so its value on the way out of a block is
// a depth the frame has to cover whether or not the counter is there now.
// Every allocation is either still counted when the function ends or released
// by a block on the way, so this is the high-water mark; emit_one_fn resets it
// and sizes the frame from it.
let frame_max = 0;
// The label of the last literal closure gen_func_literal emitted. The array
// methods read it right after gen(st, fnode) to call the body DIRECTLY when
// the closure captures nothing -- the callee never looks at the record, so
// the per-element indirect load and the closure push are pure overhead.
let lit_label: long = -1;

def st_with(st: EmitSt, b: [long], txt: [str]) -> EmitSt {
    { ir: b, txt: txt, rodata: st.rodata, uid: st.uid,
        fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots, temp: st.temp,
        self_label: st.self_label, end_label: st.end_label, fns: st.fns,
        bodies: st.bodies, btext: st.btext, blabels: st.blabels }
};

def st_ir(st: EmitSt, b: [long]) -> EmitSt {
    st_with(st, b, st.txt)
};

// The state with the frame counter set: what a block does on the way out, so
// the counter is a stack of depths (see gen_block_as) rather than a running
// total of every slot the body ever took.
def st_slots(st: EmitSt, n: long) -> EmitSt {
    // A block that took no slot of its own has nothing to release, and the
    // depth it hands back is the one it was given -- which the mark already
    // covers (every allocation is marked where it is taken).
    if (n == st.slots) {
        st
    } else {
        let deep = st.slots + st.temp;
        if (deep > frame_max) { frame_max = deep; };
        { ir: st.ir, txt: st.txt, rodata: st.rodata, uid: st.uid,
            fuid: st.fuid, loc: st.loc, env: st.env, slots: n, temp: st.temp,
            self_label: st.self_label, end_label: st.end_label, fns: st.fns,
            bodies: st.bodies, btext: st.btext, blabels: st.blabels }
    }
};

// The state with a statement's temporaries released: they are dead once the
// statement is (its value is in %rax or a local's slot), and the next
// statement starts below them again. The high-water mark goes with them, so
// the frame still covers the deepest a single statement reached.
def st_temp(st: EmitSt, n: long) -> EmitSt {
    // a statement that took no temporary, as above
    if (n == st.temp) {
        st
    } else {
        let deep = st.slots + st.temp;
        if (deep > frame_max) { frame_max = deep; };
        { ir: st.ir, txt: st.txt, rodata: st.rodata, uid: st.uid,
            fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots, temp: n,
            self_label: st.self_label, end_label: st.end_label, fns: st.fns,
            bodies: st.bodies, btext: st.btext, blabels: st.blabels }
    }
};

// One instruction: form `f` and its seven field words (see ir.y). The shapes
// are written out at the call sites, so a site reads as the instruction it
// emits -- `emit_insn(st, insn.F_MOV_0_R, insn.R_RBP, -1, 1, -24, -1, insn.R_RAX, 64)`
// is `mov -24(%rbp), %rax`.
def emit_insn(st: EmitSt, f: long, a: long, b: long, c: long, d: long, e: long, g: long, h: long) -> EmitSt {
    st_ir(st, insn.ir_push(st.ir, f, a, b, c, d, e, g, h))
};

// A label definition (`yfn_3_foo:`), as an item carrying the label's id: the
// assembler takes the name from the table, and tree shaking compares ids.
def emit_label(st: EmitSt, id: long) -> EmitSt {
    emit_insn(st, insn.IR_LABEL, id, 0, 0, 0, 0, 0, 0)
};

// The five words of a memory operand that is a frame slot (lbl < 0: the
// displacement is from %rbp) or a symbol at (%rip) (lbl >= 0) -- base, index,
// scale, disp, label. For the operands whose shape the emitter only learns from
// the variable: gen_sappend's variable and its companion cell are a local for
// one program and a global for the next.
def memop(lbl: long, disp: long) -> [long] {
    if (lbl >= 0) {[-1, -1, 1, 0, lbl] } else {[insn.R_RBP, -1, 1, disp, -1] }
};

// A line the emitter still spells as text: the three comment lines it writes
// (two `INTERNAL:` traps and the discarded bare self, which carries a
// trailing comment of its own). It becomes an IR_TEXT item, so the body is one
// ordered stream either way and ir_render_all puts the text back where it was.
def emit(st: EmitSt, line: str) -> EmitSt {
    let txt = st.txt;
    txt += line;
    st_with(st, insn.ir_push(st.ir, insn.IR_TEXT, len(txt) - 1, 0, 0, 0, 0, 0, 0), txt)
};

def next_uid(st: EmitSt) -> { st: EmitSt, uid: long } {
    let u = st.uid;
    st = { ir: st.ir, txt: st.txt, rodata: st.rodata, uid: st.uid + 1,
        fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots, temp: st.temp,
        self_label: st.self_label, end_label: st.end_label, fns: st.fns,
        bodies: st.bodies, btext: st.btext, blabels: st.blabels };
    { st: st, uid: u }
};

def next_loc(st: EmitSt) -> StLbl {
    let id = lbl_fresh(arch.arch_loc_label(st.fuid, st.loc));
    st = { ir: st.ir, txt: st.txt, rodata: st.rodata, uid: st.uid,
        fuid: st.fuid, loc: st.loc + 1, env: st.env, slots: st.slots, temp: st.temp,
        self_label: st.self_label, end_label: st.end_label, fns: st.fns,
        bodies: st.bodies, btext: st.btext, blabels: st.blabels };
    { st: st, label: id }
};

// ── string escaping for GAS .string ────────────────────────────────────

// Runs of plain bytes are copied as one slice and the pieces joined once:
// appending a byte at a time was quadratic, and an embedded file is one
// long literal (the compiler's own runtime text cost 100 MB that way).
def esc_asm(s: str) -> str {
    let b = bytes(s);
    let n = len(b);
    let out: [str] = [];
    let run = 0;
    for i in 0..n {
        let o: long = b[i];
        let esc = "";
        if (o == '\\') {
            esc = "\\\\";
        } else if (o == '\"') {
            esc = "\\\"";
        } else if (o == '\n') {
            esc = "\\n";
        } else if (o == '\t') {
            esc = "\\t";
        } else if (o < ' ' || o > '~') {
            esc = "\\" + tostring(o / 64) + tostring((o / 8) % 8) + tostring(o % 8);
        }
        if (len(esc) > 0) {
            out += s[run:i];
            out += esc;
            run = i + 1;
        }
    };
    out += s[run:];
    join(out, "")
};

// ── flat environment ───────────────────────────────────────────────────
//
// The env is one array per function, appended to and never popped, and
// env_find scans it from the END -- the newest binding of a name wins, and
// most lookups are of the newest binding (a local just defined, a capture, a
// name the emitter is binding right now), which a pointer compare settles in a
// couple of instructions. So the scan gets a short prefix (ENV_SCAN_BACK) and
// stays cheap.
//
// Past ENV_SCAN_MAX entries it stops being a scan. A wide env is real: a
// function with 800 locals spent 96% of a compile scanning, and a unit with
// 40 000 top-level defs spent 63% in env_find and the y_str_eq calls under it
// (4.8 s, 562 MB). So a wide env is indexed by name with asm.y's labmap -- the
// one hashed name table here, and the only one that can be filled
// incrementally (a Y map is itself a linear scan: gen_map_get walks the keys).
//
// One index, many envs: the emitter's env is fresh per function, so every
// env's FIRST slot is a sentinel -- name "", kind "env", off the env's own id
// -- and the index remembers the id it was built for. The index is a hint,
// never the truth: a hit is checked against the slot it names, and it is
// rebuilt whenever it describes another env or the env has outgrown half its
// table (labmap_put does not grow, and a full table drops entries). A miss on
// an index that describes this env and still has room is final -- the index
// holds every binding -- and skips the rest of the scan.
const ENV_SCAN_MAX = 64;
const ENV_SCAN_BACK = 8;

// The index (a labmap: name -> slot), and the env id it describes.
let env_ix: [AsmLabel] = [];
let env_ix_id = 0;
let env_id = 0;

// Open a fresh env: the sentinel that carries its id (its off field).
def env_open(env: [Slot]) -> [Slot] {
    env_id++;
    env += { name: "", kind: "env", off: env_id, label: -1, mark: "", typ: normtype({ k: K.tnone }) };
    env
};

// Index every binding of env, walking it BACKWARDS: labmap_put keeps the
// first insert for a name, and a name bound twice in one env (a boxed local
// defined again) must read as the newest binding, which is what env_find's
// scan-from-the-end gives -- so the first insert per name has to be the
// highest slot.
//
// The table is sized for the env as it is now, and with `grow` (the rebuild
// the env outgrowing its table makes) at least twice what it was, so the next
// such rebuild is at least twice as far off: without that the size would track
// the env one step at a time and every rebuild would be O(n) of a growing n.
// A re-bound name rebuilds without growing -- those come in bursts (every
// boxed local of a closure-heavy function), and a doubling cap per rebuild
// reaches a million slots and out of memory on t89.
def env_index_all(env: [Slot], grow: bool) -> void {
    let cap = len(env) * 2 + 16;
    // twice the old table, but only while it is this env's: a fresh env sizes
    // its own (or a unit with two wide units would inherit the first's)
    if (grow && env[0].off == env_ix_id && cap < len(env_ix) * 2) { cap = len(env_ix) * 2; };
    let m = asm.labmap_new(cap);
    let i = len(env) - 1;
    while (i >= 0) {
        let e = env[i];
        // the unnamed entries (the sentinel, a function's frame/fnty/boxmark
        // marks) are no name and no lookup can ask for one -- and indexing
        // them would rebuild on every one of them, since they repeat
        if (len(e.name) > 0) {
            m = (asm.labmap_put(m, e.name, i, 0)).map;
        };
        i = i - 1;
    };
    env_ix = m;
    env_ix_id = env[0].off;
};

// Index the binding just appended to env, or rebuild. Four cases: a fresh env
// (the id differs), the env crossing the threshold -- which is a rebuild and
// not a put, or the entries below the threshold would never be indexed at all
// -- the env outgrowing half its table, and a re-bound name (the table keeps
// the first insert for a name, so the newest slot has to be put by a rebuild
// that walks backwards).
def env_index_add(env: [Slot]) -> void {
    if (env[0].off != env_ix_id || len(env) == ENV_SCAN_MAX + 1 || len(env) * 2 > len(env_ix)) {
        env_index_all(env, true);
    } else if (len(env) > ENV_SCAN_MAX) {
        let e = env[len(env) - 1];
        let g = asm.labmap_get(env_ix, e.name);
        if (len(e.name) == 0) {
            0
        } else if (g.sec >= 0) {
            // a re-bound name: the table keeps the first insert, so the
            // newest slot needs the rebuild (which walks backwards)
            env_index_all(env, false)
        } else {
            env_ix = (asm.labmap_put(env_ix, e.name, len(env) - 1, 0)).map;
        };
    };
};

def env_find(st: EmitSt, name: str) -> Slot {
    // Miss marker: kind "none". Real entries have name/kind/off/label/typ
    // but NO k field — never test e.k.
    // The function's own entries first — the newest binding of a name — then
    // the unit's defs (st.fns, by its index).
    let env = st.env;
    let n = len(env);
    let at = -1;
    // the newest bindings, by scan
    let lo = n - ENV_SCAN_BACK;
    if (lo < 0) { lo = 0; };
    let i = n - 1;
    while (i >= lo && at < 0) {
        if (env[i].name == name) { at = i; };
        i = i - 1;
    };
    // the rest by index, once the env is wide and the index is this env's
    if (at < 0 && n > ENV_SCAN_MAX && env[0].off == env_ix_id && n < len(env_ix)) {
        let g = asm.labmap_get(env_ix, name);
        if (g.sec >= 0 && g.sec < n && env[g.sec].name == name) {
            at = g.sec;
        } else if (g.sec < 0) {
            at = -2;
        };
    };
    // and by scan when there is no index to ask (at == -1; a final miss is -2)
    if (at == -1 && lo > 0) {
        i = lo - 1;
        while (i >= 0 && at < 0) {
            if (env[i].name == name) { at = i; };
            i = i - 1;
        };
    };
    if (at >= 0) {
        env[at]
    } else {
        let found: Slot = { name: "", kind: "none", off: 0, label: -1, mark: "", typ: normtype({ k: K.tnone }) };
        let fns = st.fns;
        let j = namemap_get(fns.ix, name);
        if (j >= 0) {
            let fe = fns.syms[j];
            found = { name: fe.name, kind: fns_kind(fe.label), off: 0, label: fns.ids[j], mark: "", typ: fe.typ };
        };
        found
    }
};

def env_define(st: EmitSt, name: str, kind: str, off: long, label: long, mark: str, typ: Type) -> EmitSt {
    let env = st.env;
    if (len(env) == 0) { env = env_open(env); };
    st.env += { name: name, kind: kind, off: off, label: label, mark: mark, typ: typ };
    env_index_add(env);
    let env = st.env;
    { ir: st.ir, txt: st.txt, rodata: st.rodata, uid: st.uid,
        fuid: st.fuid, loc: st.loc, env: env, slots: st.slots, temp: st.temp,
        self_label: st.self_label, end_label: st.end_label, fns: st.fns,
        bodies: st.bodies, btext: st.btext, blabels: st.blabels }
};

// ── mini type inference (for print dispatch) ───────────────────────────
// The checker already validated everything; this mirrors it just enough to
// pick y_print_long / y_print_bool / y_print_cstr.

// The static type of an expression (infer_go), a recursive alias unfolded
// (types.y unfold): the emitter looks into it.
def infer(st: EmitSt, node: Node) -> Type {
    let t = infer_go(st, node);
    if (t.k == K.tref) {
        let unfolded: Type = types.unfold(t);
        unfolded
    } else { t }
};

def infer_go(st: EmitSt, node: Node) -> Type {
    let k = node.k;
    if (k == K.bignum) {
        normtype({ k: K.tbigint })
    }
    else if (k == K.num) {
        let leaf: Leaf = node;
        if (lit_is_float(leaf.v)) { normtype({ k: K.tfloat }) } else { normtype({ k: K.tlong }) }
    }
    else if (k == K.str) { normtype({ k: K.tstr }) }
    else if (k == K.bstr) { normtype({ k: K.tarr, of: normtype({ k: K.tbyte }) }) }
    else if (k == K.bool) { normtype({ k: K.tbool }) }
    else if (k == K.void) { normtype({ k: K.tvoid }) }
    else if (k == K.id) {
        let id: Leaf = node;
        if (id.v == "self") { normtype(cur_fn_type(st)) } else {
            let e = env_find(st, id.v);
            if (e.kind == "none") {
                if (id.v == "none") { normtype({ k: K.topt, of: normtype({ k: K.tunk }) }) } else { normtype({ k: K.tunk }) }
            } else { e.typ }
        }
    } else if (k == K.un) {
        let un: Un = node;
        if (un.op == "-") {
            // negating a byte is long arithmetic (types.y): -b leaves 0..255
            let ut = infer(st, un.e);
            if (ut.k == K.tbyte) { normtype({ k: K.tlong }) } else { ut }
        } else if (un.op == "~") { normtype({ k: K.tlong }) }
        else { normtype({ k: K.tbool }) }
    } else if (k == K.bin) {
        let bin: Bin = node;
        let op = bin.op;
        if (op in ["+", "-", "*", "/", "%", "::"]) {
            let bl = infer(st, bin.l);
            let br = infer(st, bin.r);
            let blu = unfold(bl);
            let bru = unfold(br);
            if ((op == "+" || op == "-") && (blu.k == K.tptr || bru.k == K.tptr)) {
                // Pointer arithmetic: p +/- long keeps the pointer type,
                // p - q is an element count (long). Invalid combinations
                // are already checker errors; infer_go still has to pick
                // some type for the emitter's width decisions.
                if (op == "+" && blu.k == K.tptr && (bru.k == K.tlong || bru.k == K.tbyte)) {
                    blu
                } else if (op == "+" && bru.k == K.tptr && (blu.k == K.tlong || blu.k == K.tbyte)) {
                    bru
                } else if (op == "-" && blu.k == K.tptr && (bru.k == K.tlong || bru.k == K.tbyte)) {
                    blu
                } else {
                    normtype({ k: K.tlong })
                }
            } else if (op == "+" && (bl.k == K.tarr || bl.k == K.tarrfix)) {
                // array `+` builds a NEW heap array (types.y
                // typeof_arith_arr) -- the element type survives, except
                // that `[T] + [[T]]` prepends the left one as an element.
                if ((br.k == K.tarr || br.k == K.tarrfix) && types.arr_plus_kind(bl, br) == "prepend") {
                    let right: ArrTy = br;
                    normtype({ k: K.tarr, of: right.of })
                } else {
                    let left: ArrTy = bl;
                    normtype({ k: K.tarr, of: left.of })
                }
            } else if (op == "+" && (br.k == K.tarr || br.k == K.tarrfix)) {
                let right: ArrTy = br;
                normtype({ k: K.tarr, of: right.of })
            } else if (op == "::") {
                // cons: one element prepended to the right's array
                let right: ArrTy = br;
                normtype({ k: K.tarr, of: right.of })
            } else if (op == "+" && (bl.k == K.tstr || br.k == K.tstr)) {
                normtype({ k: K.tstr })
            } else if (bl.k == K.tbigint || br.k == K.tbigint) {
                normtype({ k: K.tbigint })
            } else if (bl.k == K.tfloat) {
                normtype({ k: K.tfloat })
            } else if (br.k == K.tfloat) {
                normtype({ k: K.tfloat })
            } else {
                normtype({ k: K.tlong })
            }
        } else if (types.is_bits_op(op)) {
            normtype({ k: K.tlong })
        } else {
            normtype({ k: K.tbool })
        }
    } else if (k == K.func) {
        let func: Func = node;
        normtype(func_type_in(st, func))
    } else if (k == K.addr) {
        let addr: Wrap = node;
        normtype({ k: K.tptr, to: infer(st, addr.e) })
    } else if (k == K.arrrep) {
        let rep: ArrRep = node;
        normtype({ k: K.tarrfix, of: infer(st, rep.v), n: rep.n })
    } else if (k == K.array) {
        let array: ArrLit = node;
        let elems: [Node] = array.elems;
        if (len(elems) == 0) {
            normtype({ k: K.tarr, of: normtype({ k: K.tunk }) })
        } else {
            normtype({ k: K.tarr, of: infer(st, elems[0]) })
        }
    } else if (k == K.index) {
        // checker guarantees an array base (any expression); the element
        // type is the base type's `of`.
        let index: Index = node;
        let bt = infer(st, index.arr);
        if (bt.k == K.tarrfix || bt.k == K.tarr) {
            let arr: ArrTy = bt;
            arr.of
        } else if (unfold(bt).k == K.tmap) {
            // m[k] is always optional: V? for any V
            let map: TMap = bt;
            normtype({ k: K.topt, of: map.of })
        } else if (bt.k == K.tstr) {
            normtype({ k: K.tbyte })
        } else {
            normtype({ k: K.tunk })
        }
    } else if (k == K.slice) {
        // arr[lo:hi] keeps the element type but is always a heap [T].
        let slice: Slice = node;
        let ts = infer(st, slice.arr);
        if (ts.k == K.tarr) {
            let arr: TOf = ts;
            normtype({ k: K.tarr, of: arr.of })
        }
        else if (ts.k == K.tarrfix) {
            let arr: TFix = ts;
            normtype({ k: K.tarr, of: arr.of })
        }
        else if (ts.k == K.tstr) { normtype({ k: K.tstr }) }
        else { normtype({ k: K.tunk }) }
    } else if (k == K.char) {
        normtype({ k: K.tbyte })
    } else if (k == K.rectest) {
        normtype({ k: K.tbool })
    } else if (k == K.narrow) {
        let narrow: Narrow = node;
        types.narrow_type(infer(st, narrow.e), narrow.typ)
    } else if (k == K.sliceassign) {
        normtype({ k: K.tvoid })
    } else if (k == K.deref) {
        let deref: Wrap = node;
        let t = infer(st, deref.e);
        if (t.k == K.tptr) {
            let ptr: TPtr = t;
            ptr.to
        } else { normtype({ k: K.tunk }) }
    } else if (k == K.call) {
        let call: Call = node;
        infer_call(st, call)
    } else if (k == K.kw_if) {
        let branch: If = node;
        infer(st, branch.then)
    } else if (k == K.block) {
        let block: Block = node;
        infer_block(st, block)
    } else if (k == K.decl) {
        let decl: Decl = node;
        infer_decl(st, decl)
    } else if (k == K.assign) {
        let assign: Assign = node;
        infer(st, assign.v)
    } else if (k == K.incdec) {
        let incdec: IncDec = node;
        infer(st, incdec.tgt)
    } else if (k == K.opassign) {
        let assign: OpAssign = node;
        infer(st, assign.tgt)
    } else if (k == K.rec) {
        // record literal: field types from the values (checker validated).
        let rec: RecLit = node;
        let melems: [Node] = rec.vals;
        let mkeys: [str] = rec.keys;
        if (len(melems) == 0) {
            let fields: [Field] = [];
            normtype({ k: K.trec, fields: fields })
        } else {
            // `...` spread entries merge the source's fields (static
            // union: first appearance keeps the position, later wins the
            // value) -- the same rule as types.y's rec arm.
            let mfields: [Field] = [];
            melems.foreach((el, mi) => {
                let mf = infer(st, el);
                // mk is read twice: the `...` test, then the merge.
                let mk = mkeys[mi];
                if (mk == "...") {
                    if (mf.k == K.trec) {
                        let rec: TRec = mf;
                        let msfs: [Field] = rec.fields;
                        msfs.foreach((msf) => {
                            mfields = types.field_merge(mfields, msf.name, msf.typ);
                        });
                    }
                } else {
                    mfields = types.field_merge(mfields, mk, mf);
                };
            });
            normtype({ k: K.trec, fields: mfields })
        }
    } else if (k == K.map) {
        // map literal: {keys, vals, boxes} record at runtime; the static
        // type is tmap (quoted keys are strings; the values share one type).
        let map: RecLit = node;
        let glvals: [Node] = map.vals;
        if (len(glvals) == 0) {
            normtype({ k: K.tmap, key: normtype({ k: K.tstr }), of: normtype({ k: K.tunk }) })
        } else {
            normtype({ k: K.tmap, key: normtype({ k: K.tstr }), of: infer(st, glvals[0]) })
        }
    } else if (k == K.dot) {
        // field read: static index into the trec (checker validated).
        let dot: Dot = node;
        let dt = infer(st, dot.obj);
        if (dt.k == K.trec) {
            let found = false;
            let ftyp: Type = normtype({ k: K.tunk });
            let rec: TRec = dt;
            let dfs: [Field] = rec.fields;
            dfs.foreach((df) => {
                // NOTE: :str binding (see teq note in types.y): df flows
                // from bare values (tunk), so a direct `==` would compare
                // string POINTERS; annotated let forces content compare.
                let dfn: str = df.name;
                if (dfn == dot.key) {
                    found = true;
                    ftyp = df.typ;
                }
            });
            if (found) { ftyp } else { normtype({ k: K.tunk }) }
        } else if (dt.k == K.tunion) {
            // types.y union_field: the type the field has in every member
            let uft = rec_field_type(dt, dot.key);
            if (uft.k == K.tnone) { normtype({ k: K.tunk }) } else { uft }
        } else if (unfold(dt).k == K.tmap) {
            let map: TMap = dt;
            // the map lowering reads its {keys, vals, boxes} shape directly
            if (dot.key == "keys") { normtype({ k: K.tarr, of: map.key }) }
            else if (dot.key == "vals") { normtype({ k: K.tarr, of: map.of }) }
            else if (dot.key == "boxes") { normtype({ k: K.tarr, of: normtype({ k: K.topt, of: map.of }) }) }
            else { normtype({ k: K.tunk }) }
        } else if (dt.k == K.tarr || dt.k == K.tarrfix) {
            // built-in properties (types.y typeof_prop; gen_prop)
            if (dot.key == "length") { normtype({ k: K.tlong }) }
            else {
                let arr: ArrTy = dt;
                normtype({ k: K.tptr, to: arr.of })
            }
        } else if (dt.k == K.tstr) {
            if (dot.key == "length") { normtype({ k: K.tlong }) }
            else { normtype({ k: K.tptr, to: normtype({ k: K.tbyte }) }) }
        } else {
            normtype({ k: K.tunk })
        }
    } else if (k == K.store) {
        let store: Store = node;
        infer(st, store.v)
    } else if (k == K.kw_while) {
        normtype({ k: K.tvoid })
    } else if (k == K.kw_break || k == K.kw_continue) {
        normtype({ k: K.tvoid })
    } else if (k == K.ret) {
        let ret: Wrap = node;
        infer(st, ret.e)
    } else {
        normtype({ k: K.tunk })
    }
};

def infer_arr_method(st: EmitSt, node: Call, key: str, at: Type) -> Type {
    let elem = arr_elem_type(at);
    let args: [Node] = node.args;
    if (key == "pop" || key == "shift") { elem }
    else if (key == "remove") {
        if (len(args) == 2) { normtype({ k: K.tarr, of: elem }) } else { elem }
    }
    else if (key == "push" || key == "unshift") { normtype({ k: K.tlong }) }
    else if (key == "insert") { normtype({ k: K.tvoid }) }
    else if (key == "flat") { normtype({ k: K.tarr, of: arr_elem_type(elem) }) }
    else if (key == "index") { normtype({ k: K.tlong }) }
    else if (key == "map") {
        let ft = infer(st, args[0]);
        if (ft.k == K.tfunc) { let f: TFunc = ft; normtype({ k: K.tarr, of: f.ret }) }
        else { normtype({ k: K.tunk }) }
    }
    else if (key == "filter") { at }
    else if (key == "all" || key == "some") { normtype({ k: K.tbool }) }
    else if (key == "find") { normtype({ k: K.topt, of: elem }) }
    else if (key == "reduce") { infer(st, args[1]) }
    else if (key == "sort" || key == "sorted") { at }
    else { normtype({ k: K.tunk }) }
};

def infer_call(st: EmitSt, node: Call) -> Type {
    let callee: Node = node.callee;
    if (callee.k != K.id) {
        // Calling an expression (immediately-invoked literal, fs[0](x), ...),
        // or `s.m(...)` with s a str: a string method (types.str_method).
        if (callee.k == K.dot) {
            let dot: Dot = callee;
            let rt = infer(st, dot.obj);
            if (rt.k == K.tstr) {
                types.str_method(dot.key).ret
            } else if (rt.k == K.tarr || rt.k == K.tarrfix) {
                infer_arr_method(st, node, dot.key, rt)
            } else {
                let cft = infer(st, callee);
                if (cft.k == K.tfunc) {
                    let func: TFunc = cft;
                    func.ret
                } else { normtype({ k: K.tunk }) }
            }
        } else {
            let cft = infer(st, callee);
            if (cft.k == K.tfunc) {
                let func: TFunc = cft;
                func.ret
            } else { normtype({ k: K.tunk }) }
        }
    } else {
        let id: Leaf = callee;
        let name = id.v;
        if (name == "print") {
            normtype({ k: K.tvoid })
        } else if (name == "syscall") {
            normtype({ k: K.tlong })
        } else if (name == "len") {
            normtype({ k: K.tlong })
        } else if (name == "is_some") {
            normtype({ k: K.tbool })
        } else if (name == "opt$test") {
            normtype({ k: K.tbool })
        } else if (name == "opt$val") {
            // the payload in an option: what some() would give, and what the
            // `?.` chain's own value is (types.y opt$val)
            let vargs: [Node] = node.args;
            if (len(vargs) != 1) { normtype({ k: K.tunk }) } else {
                let vt = infer(st, vargs[0]);
                if (vt.k == K.tvoid || vt.k == K.tunk) { vt }
                else if (vt.k == K.topt) { vt }
                else { normtype({ k: K.topt, of: vt }) }
            }
        } else if (name == "unwrap") {
            // unwrap(x): payload type when x is statically an option.
            let uargs: [Node] = node.args;
            if (len(uargs) != 1) { normtype({ k: K.tunk }) } else {
                let ut = infer(st, uargs[0]);
                if (ut.k == K.topt) {
                    let opt: TOf = ut;
                    opt.of
                } else { normtype({ k: K.tunk }) }
            }
        } else if (name == "some") {
            // some(x): option of x's type.
            let sargs: [Node] = node.args;
            if (len(sargs) != 1) {
                normtype({ k: K.topt, of: normtype({ k: K.tunk }) })
            } else {
                normtype({ k: K.topt, of: infer(st, sargs[0]) })
            }
        } else if ((name == "join" && len(node.args) == 1) || name == "lock") {
            // join t: t's value; lock m { b }: b's
            let ja: [Node] = node.args;
            let ft = infer(st, ja[len(ja) - 1]);
            if (ft.k == K.tfunc) {
                let func: TFunc = ft;
                func.ret
            } else { normtype({ k: K.tunk }) }
        } else if (name == "spawn") {
            let sa: [Node] = node.args;
            infer(st, sa[0])
        } else if (name == "fork" || name == "wait_pid") {
            normtype({ k: K.tlong })
        } else if (name == "try_lock") {
            normtype({ k: K.tbool })
        } else if (name == "post" || name == "wait") {
            normtype({ k: K.tvoid })
        } else if (name == "mutex") {
            types.t_mutex()
        } else if (name == "sem") {
            types.t_sem()
        } else if (name in ["trim", "chr", "join", "tostring", "typeof", "#fmt"]) {
            normtype({ k: K.tstr })
        } else if (name == "bytes") {
            normtype({ k: K.tarr, of: normtype({ k: K.tbyte }) })
        } else if (name == "from_bytes") {
            normtype({ k: K.tstr })
        } else if (name == "ptr_addr") {
            normtype({ k: K.tlong })
        } else if (name == "os_call") {
            // os_call's result is whatever the named block returns, which is a
            // long on every name in os_call_names (types.y owns the list and
            // the checker; native.y check_os_call_names makes sure each name is
            // a label the arch lines really define).
            type_node({ k: K.tlong })
        } else if (name == "tolong") {
            // tolong returns an OPTION: a fully valid input is required, and a
            // value outside the long range or a float with no long answer is
            // none rather than a wrap or a trap.
            normtype({ k: K.topt, of: normtype({ k: K.tlong }) })
        } else if (name == "tofloat") {
            normtype({ k: K.topt, of: normtype({ k: K.tfloat }) })
        } else if (name in ["ord", "byte_at", "mod", "index_of", "last_index_of"]) {
            normtype({ k: K.tlong })
        } else if (name in ["clock_us", "time_us", "heap_used"]) {
            type_node({ k: K.tlong })
        } else if (name == "keys") {
            let kt = infer(st, node.args[0]);
            if (unfold(kt).k == K.tmap) {
                let km: TMap = kt;
                normtype({ k: K.tarr, of: km.key })
            } else { normtype({ k: K.tarr, of: normtype({ k: K.tunk }) }) }
        } else if (name == "sleep") {
            normtype({ k: K.tvoid })
        } else if (name == "split" || name == "argv") {
            normtype({ k: K.tarr, of: normtype({ k: K.tstr }) })
        } else if (name == "range") {
            normtype({ k: K.tarr, of: normtype({ k: K.tlong }) })
        } else if (name in ["push", "prepend", "push$all"]) {
            // all yield the array they take (the header never moves, and
            // the type is the array's either way)
            let gargs: [Node] = node.args;
            infer(st, gargs[0])
        } else if (name == "puts" || name == "exit") {
            normtype({ k: K.tvoid })
        } else if (name == "eputs") {
            normtype({ k: K.tvoid })
        } else if (name == "self") {
            // the function's return type; one the checker could not infer
            // stays unknown here
            let sft: TFunc = cur_fn_type(st);
            let sret: Type = sft.ret;
            if (sret.k == K.tnone) { normtype({ k: K.tunk }) } else { sret }
        } else {
            let e = env_find(st, name);
            if (e.kind == "none") {
                normtype({ k: K.tunk })
            } else if (e.typ.k == K.tfunc) {
                let func: TFunc = e.typ;
                func.ret
            } else {
                normtype({ k: K.tunk })
            }
        }
    }
};

def infer_block(st: EmitSt, node: Block) -> Type {
    let stmts: [Node] = node.stmts;
    if (len(stmts) == 0) {
        normtype({ k: K.tvoid })
    } else {
        // A binding made inside a block is read inside the very expression
        // that makes it -- `{ let a = "x"; a }`, a match arm's pattern
        // bindings -- and infer runs before gen binds it, so bind the
        // block's own `let`s here or the block's value infers as unknown
        // (print then reads a str option as a raw number, and a match arm's
        // `v.f` as one). Only these: every other name is in scope after its
        // own statement, which gen has run by the time anything asks.
        stmts.foreach((s) => {
            if (s.k == K.decl) {
                let d: Decl = s;
                if (d.kind == "let" && env_find(st, d.name).kind == "none") {
                    if (len(st.env) == 0) { st.env = env_open(st.env); };
                    st.env += { name: d.name, kind: "temp", off: 0, label: -1, mark: "", typ: infer(st, d.v) };
                    env_index_add(st.env);
                };
            };
        });
        infer(st, stmts[len(stmts) - 1])
    }
};

def infer_decl(st: EmitSt, node: Decl) -> Type {
    if (node.kind == "def") {
        normtype({ k: K.tfunc, args: [], ret: normtype({ k: K.tvoid }) })
    } else {
        // an annotated `let` takes the declared type; otherwise infer the
        // initializer's
        if (node.typ.k == K.tnone) {
            infer(st, node.v)
        } else {
            node.typ
        }
    }
};

// ── feature-use scan (for conditional prologue) ───────────────────────
// Whether the _start prologue has to serve argv(): argv() needs
// y_argv_init to materialize the [str] array from the raw stack. Everything
// else (y_alloc, y_print_*, ...) is position-independent.
//
// The walk is `fv_walk` -- the one that collects the names a closure must
// capture -- so no node kind can hide a call behind a gap in a second ladder.
// The one this replaces had no arm for a `K.dot`, so `argv().length` (a
// field read on a call) left this false: the prologue's y_argv_init was never
// emitted, `y_argv` returned an untouched %r15, and the program died on
// SIGSEGV with no output whenever the length was the only read of argv.
// Matching the *name* rather than a call to it is the safe direction: a false
// positive costs the prologue (a few hundred bytes), a false negative crashes.
def uses_argv(stmts: [Node]) -> bool {
    let reads: [str] = [];
    stmts.foreach((e) => {
        reads = fv_walk(e, reads, true);
    });
    name_in(reads, "argv")
};

// ── def collection (incl. hoisting) ────────────────────────────────────
// Every named def and every let-bound anonymous def becomes a top-level
// function (the capture-free ones — the checker proved the rest capture).
// Returns [FnDef].
//
// The walk below covers EVERY node kind, in the same order and shape as
// fv_walk's (see "free variables" below), because a `def` is a statement and
// a statement can live in a block, and a block is an expression: the two
// walks disagreeing is what let `if ({ def g() -> bool { true }; g() })`
// and a def in a call argument, an array element, a record value, an
// operand, an index or a loop head reach the assembler unhoisted, which
// then failed with `undefined label 'y_missing_...'`. Keep the two in step:
// one is free variables, the other definitions, and both need every arm.
type FnDef = { name: str, func: Func };

def collect_from_list(nodes: [Node], out: [FnDef]) -> [FnDef] {
    nodes.foreach((e) => {
        out = collect_from_node(e, out);
    });
    out
};

def collect_from_block(stmts: [Node], out: [FnDef]) -> [FnDef] {
    collect_from_list(stmts, out)
};

// A `def` declaration, and a `let` bound to a function literal: both are a
// name a call can resolve, so both are collected here and both recurse into
// the function body (a def nested in it is hoisted the same way).
def collect_decl(decl: Decl, out: [FnDef]) -> [FnDef] {
    if (decl.v.k == K.func) {
        let func: Func = decl.v;
        out += { name: decl.name, func: func };
    };
    collect_from_node(decl.v, out)
};

def collect_from_node(node: Node, out: [FnDef]) -> [FnDef] {
    let k = node.k;
    if (k == K.decl) {
        let decl: Decl = node;
        out = collect_decl(decl, out);
    } else if (k == K.un) {
        let child: NodeE = node;
        out = collect_from_node(child.e, out);
    } else if (k == K.addr) {
        let child: NodeE = node;
        out = collect_from_node(child.e, out);
    } else if (k == K.deref) {
        let child: NodeE = node;
        out = collect_from_node(child.e, out);
    } else if (k == K.ret) {
        let child: NodeE = node;
        out = collect_from_node(child.e, out);
    } else if (k == K.bin) {
        let bin: Bin = node;
        out = collect_from_node(bin.l, out);
        out = collect_from_node(bin.r, out);
    } else if (k == K.array) {
        let array: ArrLit = node;
        out = collect_from_list(array.elems, out);
    } else if (k == K.rec) {
        let rec: RecLit = node;
        out = collect_from_list(rec.vals, out);
    } else if (k == K.map) {
        let map: RecLit = node;
        out = collect_from_list(map.vals, out);
    } else if (k == K.arrrep) {
        let rep: ArrRep = node;
        out = collect_from_node(rep.v, out);
    } else if (k == K.call) {
        let call: Call = node;
        out = collect_from_node(call.callee, out);
        out = collect_from_list(call.args, out);
    } else if (k == K.index) {
        let index: Index = node;
        out = collect_from_node(index.arr, out);
        out = collect_from_node(index.idx, out);
    } else if (k == K.slice) {
        let slice: Slice = node;
        out = collect_from_node(slice.arr, out);
        out = collect_from_node(slice.lo, out);
        out = collect_from_node(slice.hi, out);
    } else if (k == K.idxassign) {
        let assign: IdxAssign = node;
        out = collect_from_node(assign.arr, out);
        out = collect_from_node(assign.idx, out);
        out = collect_from_node(assign.v, out);
    } else if (k == K.dot) {
        let dot: Dot = node;
        out = collect_from_node(dot.obj, out);
    } else if (k == K.dotassign) {
        let assign: DotAssign = node;
        out = collect_from_node(assign.obj, out);
        out = collect_from_node(assign.v, out);
    } else if (k == K.store) {
        let store: Store = node;
        out = collect_from_node(store.p, out);
        out = collect_from_node(store.v, out);
    } else if (k == K.assign) {
        let assign: Assign = node;
        out = collect_from_node(assign.v, out);
    } else if (k == K.incdec) {
        let incdec: IncDec = node;
        out = collect_from_node(incdec.tgt, out);
    } else if (k == K.opassign) {
        let assign: OpAssign = node;
        out = collect_from_node(assign.tgt, out);
        out = collect_from_node(assign.v, out);
    } else if (k == K.kw_if) {
        let branch: If = node;
        out = collect_from_node(branch.cond, out);
        out = collect_from_node(branch.then, out);
        if (branch.has_else) {
            out = collect_from_node(branch.els, out);
        }
    } else if (k == K.kw_while) {
        let loop: While = node;
        out = collect_from_node(loop.cond, out);
        out = collect_from_node(loop.body, out);
    } else if (k == K.kw_for) {
        let loop: For = node;
        out = collect_from_node(loop.init, out);
        out = collect_from_node(loop.cond, out);
        out = collect_from_node(loop.step, out);
        out = collect_from_node(loop.body, out);
    } else if (k == K.kw_foreach) {
        let loop: Foreach = node;
        out = collect_from_node(loop.iter, out);
        out = collect_from_node(loop.body, out);
    } else if (k == K.forrange) {
        let loop: ForRange = node;
        out = collect_from_node(loop.lo, out);
        out = collect_from_node(loop.hi, out);
        out = collect_from_node(loop.body, out);
    } else if (k == K.block) {
        let block: Block = node;
        out = collect_from_block(block.stmts, out);
    } else if (k == K.func) {
        let func: Func = node;
        out = collect_from_node(func.body, out);
    } else if (k == K.sliceassign) {
        let assign: SliceAssign = node;
        out = collect_from_node(assign.arr, out);
        out = collect_from_node(assign.lo, out);
        out = collect_from_node(assign.hi, out);
        out = collect_from_node(assign.v, out);
    } else if (k == K.rectest || k == K.narrow || k == K.matchend) {
        let child: NodeE = node;
        out = collect_from_node(child.e, out);
    }
    out
};

// ── free variables (closure conversion) ────────────────────────────────
// A function that reads a name bound by an ENCLOSING function captures it.
// The capture list is computed purely syntactically (rename.y has already
// made every binding unique), so the creation site and the body emitter
// derive the same ordered list independently.

// Whether kept code calls into the thread runtime: only then are
// arch_prelude_threads_lines linked (every compile looks at each line of
// the prelude it is given).
def uses_threads(refs: [str]) -> bool {
    let i = 0;
    let found = false;
    while ((i < len(refs)) && (!found)) {
        let r: str = refs[i];
        let n = len(r);
        // the entry points (an unlock comes with a lock or a try), by
        // length first: the self-compile has ~50K references
        found = (n == 6 && r == "y_fork") || (n == 7 && r == "y_spawn") || (n == 10 && (r == "y_sem_wait" || r == "y_sem_post")) || (n == 12 && r == "y_mutex_lock") || (n == 15 && r == "y_mutex_trylock");
        i++;
    };
    found
};

// The float primitives (src/y/arch/math.s), by the same rule as the thread
// runtime: a `ndef` names one as its body, so the call is a reference
// like any other and the block stays. Looking first is what makes this cheap
// -- split()ing the lines for every compile measured +2.6% instructions on
// hello.y, against a few dozen lines (bench/compile_ir.sh).
def uses_math(refs: [str]) -> bool {
    let i = 0;
    let found = false;
    while ((i < len(refs)) && (!found)) {
        let r: str = refs[i];
        let n = len(r);
        // y_sqrt 6, y_fbits 7, y_bitsf 7, y_to_int 8, y_int_trap 10, and the
        // length-first names of the bulk kernels: y_dot/y_sum 5, y_exp/y_log/
        // y_pow/y_sin/y_cos 5, y_min_of/y_max_of/y_scale/y_axpy 8
        found = (n == 5 && (r == "y_exp" || r == "y_log" || r == "y_pow"
            || r == "y_sin" || r == "y_cos" || r == "y_dot"
            || r == "y_sum"))
        || (n == 6 && r == "y_sqrt")
        || (n == 7 && (r == "y_fbits" || r == "y_bitsf"))
        || (n == 8 && (r == "y_to_int" || r == "y_min_of" || r == "y_max_of"
            || r == "y_scale" || r == "y_axpy"))
        || (n == 10 && (r == "y_int_trap" || r == "y_len_stop"))
        // the encoder's own form probes: y_sse_forms, y_sse_flags,
        // y_test_imm
        || (n == 11 && (r == "y_sse_forms" || r == "y_sse_flags"))
        || (n == 10 && r == "y_test_imm");
        i++;
    };
    found
};

def name_in(xs: [str], n: str) -> bool {
    let i = 0;
    let found = false;
    // Stops at the first hit: the answer is a bool, so unlike types.y
    // lookup the order does not matter and the tail cannot change it.
    while ((i < len(xs)) && (!found)) {
        let x: str = xs[i];
        if (x == n) { found = true; }
        i++;
    };
    found
};

// The builtins, as a list rather than an inline argument, so that the ONE copy
// can be handed out. The language server's completion list used to be its own
// transcription of this, which is exactly the kind of copy that rots: adding a
// builtin here would leave the server offering the old set, and nothing would
// fail. `opt$test`/`opt$val` and `#fmt` are the compiler's own halves of the
// option operators and the `#fmt` builtin -- internal, but they are what
// is_intrinsic_name tests, so they are in the list.
let INTRINSICS: [str] = ["print", "syscall", "len", "push", "some", "is_some", "unwrap",
    "opt$test", "opt$val",
    "trim", "ord", "byte_at", "chr", "tolong", "tofloat", "tostring", "index_of",
    "mod",
    "prepend",
    "last_index_of", "join", "split", "puts", "eputs", "clock_us",
    "time_us", "sleep", "heap_used", "keys", "spawn", "fork", "wait_pid",
    "mutex", "sem", "lock", "try_lock", "post", "wait", "exit", "argv", "range", "typeof", "bytes",
    "from_bytes", "ptr_addr", "os_call", "jmp_at", "self", "none", "#fmt"];

// Builtins are resolved by name at the call site, never captured.
def is_intrinsic_name(n: str) -> bool {
    name_in(INTRINSICS, n)
};

// The same list, for a caller that needs to enumerate it rather than test one
// name (the language server's completion list -- see LSP.md R5.3). Returns the
// live array, so a caller must not modify it.
def intrinsic_names() -> [str] {
    INTRINSICS
};

// Every identifier READ in a subtree (callee names included: calling a
// captured closure needs the name captured too). With `collect` false,
// only the reads inside nested functions count (see box_names).
def fv_walk(node: Node, out: [str], collect: bool) -> [str] {
    let k = node.k;
    if (k == K.id) {
        let id: Leaf = node;
        if (collect) { out += id.v; }
    } else if (k == K.un) {
        let child: NodeE = node;
        out = fv_walk(child.e, out, collect);
    } else if (k == K.addr) {
        let child: NodeE = node;
        out = fv_walk(child.e, out, collect);
    } else if (k == K.deref) {
        let child: NodeE = node;
        out = fv_walk(child.e, out, collect);
    } else if (k == K.ret) {
        let child: NodeE = node;
        out = fv_walk(child.e, out, collect);
    } else if (k == K.bin) {
        let bin: Bin = node;
        out = fv_walk(bin.l, out, collect);
        out = fv_walk(bin.r, out, collect);
    } else if (k == K.array) {
        let array: ArrLit = node;
        out = fv_walk_list(array.elems, out, collect);
    } else if (k == K.rec) {
        let rec: RecLit = node;
        out = fv_walk_list(rec.vals, out, collect);
    } else if (k == K.map) {
        let map: RecLit = node;
        out = fv_walk_list(map.vals, out, collect);
    } else if (k == K.arrrep) {
        let rep: ArrRep = node;
        out = fv_walk(rep.v, out, collect);
    } else if (k == K.call) {
        let call: Call = node;
        out = fv_walk(call.callee, out, collect);
        out = fv_walk_list(call.args, out, collect);
    } else if (k == K.index) {
        let index: Index = node;
        out = fv_walk(index.arr, out, collect);
        out = fv_walk(index.idx, out, collect);
    } else if (k == K.slice) {
        let slice: Slice = node;
        out = fv_walk(slice.arr, out, collect);
        out = fv_walk(slice.lo, out, collect);
        out = fv_walk(slice.hi, out, collect);
    } else if (k == K.idxassign) {
        let assign: IdxAssign = node;
        out = fv_walk(assign.arr, out, collect);
        out = fv_walk(assign.idx, out, collect);
        out = fv_walk(assign.v, out, collect);
    } else if (k == K.dot) {
        let dot: Dot = node;
        out = fv_walk(dot.obj, out, collect);
    } else if (k == K.dotassign) {
        let assign: DotAssign = node;
        out = fv_walk(assign.obj, out, collect);
        out = fv_walk(assign.v, out, collect);
    } else if (k == K.store) {
        let store: Store = node;
        out = fv_walk(store.p, out, collect);
        out = fv_walk(store.v, out, collect);
    } else if (k == K.assign) {
        let assign: Assign = node;
        if (collect) { out += assign.name; }
        out = fv_walk(assign.v, out, collect);
    } else if (k == K.incdec) {
        let incdec: IncDec = node;
        out = fv_walk(incdec.tgt, out, collect);
    } else if (k == K.opassign) {
        let assign: OpAssign = node;
        out = fv_walk(assign.tgt, out, collect);
        out = fv_walk(assign.v, out, collect);
    } else if (k == K.decl) {
        let decl: Decl = node;
        out = fv_walk(decl.v, out, collect);
    } else if (k == K.kw_if) {
        let branch: If = node;
        out = fv_walk(branch.cond, out, collect);
        out = fv_walk(branch.then, out, collect);
        if (branch.has_else) {
            out = fv_walk(branch.els, out, collect);
        }
    } else if (k == K.kw_while) {
        let loop: While = node;
        out = fv_walk(loop.cond, out, collect);
        out = fv_walk(loop.body, out, collect);
    } else if (k == K.kw_for) {
        let loop: For = node;
        out = fv_walk(loop.init, out, collect);
        out = fv_walk(loop.cond, out, collect);
        out = fv_walk(loop.step, out, collect);
        out = fv_walk(loop.body, out, collect);
    } else if (k == K.kw_foreach) {
        let loop: Foreach = node;
        out = fv_walk(loop.iter, out, collect);
        out = fv_walk(loop.body, out, collect);
    } else if (k == K.forrange) {
        let loop: ForRange = node;
        out = fv_walk(loop.lo, out, collect);
        out = fv_walk(loop.hi, out, collect);
        out = fv_walk(loop.body, out, collect);
    } else if (k == K.block) {
        let block: Block = node;
        out = fv_walk_list(block.stmts, out, collect);
    } else if (k == K.func) {
        let func: Func = node;
        out = fv_walk(func.body, out, true);
    } else if (k == K.sliceassign) {
        let assign: SliceAssign = node;
        out = fv_walk(assign.arr, out, collect);
        out = fv_walk(assign.lo, out, collect);
        out = fv_walk(assign.hi, out, collect);
        out = fv_walk(assign.v, out, collect);
    } else if (k == K.rectest || k == K.narrow || k == K.matchend) {
        let child: NodeE = node;
        out = fv_walk(child.e, out, collect);
    }
    out
};

def fv_walk_list(nodes: [Node], out: [str], collect: bool) -> [str] {
    nodes.foreach((e) => {
        out = fv_walk(e, out, collect);
    });
    out
};

def fv_ids(node: Node, out: [str]) -> [str] {
    fv_walk(node, out, true)
};

// Every name BOUND anywhere in a subtree (params of nested funcs included:
// they are not free in the enclosing function either). Must traverse the
// same positions as fv_ids — a function literal can appear in any
// expression, e.g. `apply(def(x: long) -> long { ... }, 1)`, and its
// params must not leak out as captures of the enclosing function.
def fv_binds(node: Node, out: [str]) -> [str] {
    let k = node.k;
    if (k == K.decl) {
        let decl: Decl = node;
        out += decl.name;
        out = fv_binds(decl.v, out);
    } else if (k == K.func) {
        let func: Func = node;
        out = fv_bind_params(func.params, out);
        out = fv_binds(func.body, out);
    } else if (k == K.block) {
        let block: Block = node;
        out = fv_binds_list(block.stmts, out);
    } else if (k == K.kw_if) {
        let branch: If = node;
        out = fv_binds(branch.cond, out);
        out = fv_binds(branch.then, out);
        if (branch.has_else) {
            out = fv_binds(branch.els, out);
        }
    } else if (k == K.kw_while) {
        let loop: While = node;
        out = fv_binds(loop.cond, out);
        out = fv_binds(loop.body, out);
    } else if (k == K.kw_for) {
        let loop: For = node;
        out = fv_binds(loop.init, out);
        out = fv_binds(loop.cond, out);
        out = fv_binds(loop.step, out);
        out = fv_binds(loop.body, out);
    } else if (k == K.kw_foreach) {
        let loop: Foreach = node;
        out += loop.name;
        out = fv_binds(loop.iter, out);
        out = fv_binds(loop.body, out);
    } else if (k == K.forrange) {
        let loop: ForRange = node;
        out += loop.name;
        out = fv_binds(loop.lo, out);
        out = fv_binds(loop.hi, out);
        out = fv_binds(loop.body, out);
    } else if (k == K.ret) {
        let child: NodeE = node;
        out = fv_binds(child.e, out);
    } else if (k == K.un) {
        let child: NodeE = node;
        out = fv_binds(child.e, out);
    } else if (k == K.addr) {
        let child: NodeE = node;
        out = fv_binds(child.e, out);
    } else if (k == K.deref) {
        let child: NodeE = node;
        out = fv_binds(child.e, out);
    } else if (k == K.bin) {
        let bin: Bin = node;
        out = fv_binds(bin.l, out);
        out = fv_binds(bin.r, out);
    } else if (k == K.array) {
        let array: ArrLit = node;
        out = fv_binds_list(array.elems, out);
    } else if (k == K.rec) {
        let rec: RecLit = node;
        out = fv_binds_list(rec.vals, out);
    } else if (k == K.map) {
        let map: RecLit = node;
        out = fv_binds_list(map.vals, out);
    } else if (k == K.arrrep) {
        let rep: ArrRep = node;
        out = fv_binds(rep.v, out);
    } else if (k == K.call) {
        let call: Call = node;
        out = fv_binds(call.callee, out);
        out = fv_binds_list(call.args, out);
    } else if (k == K.index) {
        let index: Index = node;
        out = fv_binds(index.arr, out);
        out = fv_binds(index.idx, out);
    } else if (k == K.slice) {
        let slice: Slice = node;
        out = fv_binds(slice.arr, out);
        out = fv_binds(slice.lo, out);
        out = fv_binds(slice.hi, out);
    } else if (k == K.idxassign) {
        let assign: IdxAssign = node;
        out = fv_binds(assign.arr, out);
        out = fv_binds(assign.idx, out);
        out = fv_binds(assign.v, out);
    } else if (k == K.dot) {
        let dot: Dot = node;
        out = fv_binds(dot.obj, out);
    } else if (k == K.dotassign) {
        let assign: DotAssign = node;
        out = fv_binds(assign.obj, out);
        out = fv_binds(assign.v, out);
    } else if (k == K.store) {
        let store: Store = node;
        out = fv_binds(store.p, out);
        out = fv_binds(store.v, out);
    } else if (k == K.assign) {
        let assign: Assign = node;
        out = fv_binds(assign.v, out);
    } else if (k == K.incdec) {
        let incdec: IncDec = node;
        out = fv_binds(incdec.tgt, out);
    } else if (k == K.opassign) {
        let assign: OpAssign = node;
        out = fv_binds(assign.tgt, out);
        out = fv_binds(assign.v, out);
    } else if (k == K.sliceassign) {
        let assign: SliceAssign = node;
        out = fv_binds(assign.arr, out);
        out = fv_binds(assign.lo, out);
        out = fv_binds(assign.hi, out);
        out = fv_binds(assign.v, out);
    }
    out
};

def fv_binds_list(nodes: [Node], out: [str]) -> [str] {
    nodes.foreach((e) => {
        out = fv_binds(e, out);
    });
    out
};

// Ordered capture list of a function literal: names it reads that it does
// not bind, minus the hoisted top-level function names and the intrinsics.
// NOTE: reads only `params` and `body`, never `func.k` — `_start` is a
// synthesized record without a `k` field.
// The names a function body reads that it does not bind and that are
// neither in `ex` (a namemap: the unit's defs, st.fns.ix) nor `extra`
// (its own name, or "") nor an intrinsic: what it captures.
def fn_captures(func: EmitFunc, ex: [AsmLabel], extra: str) -> [str] {
    let bound = fv_bind_params(func.params, fv_binds(func.body, []));
    let reads = fv_ids(func.body, []);
    let caps: [str] = [];
    reads.foreach((e) => {
        let n: str = e;
        if (name_in(bound, n)) { }
        else if (n == extra || namemap_get(ex, n) >= 0) { }
        else if (is_intrinsic_name(n)) { }
        else if (name_in(caps, n)) { }
        else {
            caps += n;
        };
    });
    caps
};

def fv_bind_params(ps: [str], out: [str]) -> [str] {
    ps.foreach((e) => {
        let p: str = e;
        out += p;
    });
    out
};

def fn_names_of(fns: [Sym]) -> [str] {
    let out: [str] = [];
    fns.foreach((e) => {
        out += e.name;
    });
    out
};

// st.fns holds the hoisted defs, then the externs (the top-level defs of
// the units this one links against), then the globals (see
// compile_unit); a global's label is its .bss cell.
def fns_kind(label: str) -> str {
    // starts_with, not label[:3] == "yg_": the slice allocated a throwaway
    // string on every call, and this runs once per identifier emitted.
    if (label.starts_with("yg_")) { "global" } else { "func" }
};

// ── expression emission (value in %rax) ────────────────────────────────

// The emitter's walk counts its depth (tags.y MAX_NEST) like the others'.
def gen(st: EmitSt, node: Node) -> EmitSt {
    nest++;
    if (nest > MAX_NEST) { too_deep("an expression", node.line, node.col); };
    let r = gen_go(st, node);
    nest--;
    r
};

def gen_go(st: EmitSt, node: Node) -> EmitSt {
    let k = node.k;
    if (k == K.num) {
        let lit: Leaf = node;
        gen_lit(st, lit)
    } else if (k == K.bignum) {
        let lit: Leaf = node;
        gen_biglit(st, lit)
    } else if (k == K.bool) {
        let lit: Leaf = node;
        if (lit.v == "true") {
            emit_insn(st, insn.F_MOV_I_R, 1, insn.R_RAX, 64, 0, 0, 0, 0)
        } else {
            emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0)
        }
    } else if (k == K.str) {
        let lit: Leaf = node;
        gen_str_const(st, lit.v)
    } else if (k == K.bstr) {
        let lit: Leaf = node;
        gen_bstr(st, lit)
    } else if (k == K.void) {
        emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0)
    } else if (k == K.id) {
        let id: Leaf = node;
        gen_id(st, id)
    } else if (k == K.un) {
        let un: Un = node;
        gen_un(st, un)
    } else if (k == K.addr) {
        let addr: Wrap = node;
        gen_addr(st, addr)
    } else if (k == K.array) {
        let array: ArrLit = node;
        gen_array(st, array)
    } else if (k == K.deref) {
        let deref: Wrap = node;
        let dw = ptr_width(infer(st, deref.e));
        st = gen(st, deref.e);
        if (dw == 1) { emit_insn(st, insn.F_MOVZBQ_0_R, insn.R_RAX, -1, 1, -1, -1, insn.R_RAX, 64) } else { emit_insn(st, insn.F_MOV_0_R, insn.R_RAX, -1, 1, -1, -1, insn.R_RAX, 64) }
    } else if (k == K.bin) {
        let bin: Bin = node;
        gen_bin(st, bin)
    } else if (k == K.call) {
        let call: Call = node;
        gen_call(st, call)
    } else if (k == K.kw_if) {
        let branch: If = node;
        gen_if(st, branch)
    } else if (k == K.kw_while) {
        let loop: While = node;
        gen_while(st, loop)
    } else if (k == K.kw_for) {
        let loop: For = node;
        gen_for(st, loop)
    } else if (k == K.forrange) {
        let loop: ForRange = node;
        gen_forrange(st, loop)
    } else if (k == K.kw_foreach) {
        let loop: Foreach = node;
        gen_foreach(st, loop)
    } else if (k == K.block) {
        let block: Block = node;
        gen_block(st, block)
    } else if (k == K.decl) {
        let decl: Decl = node;
        gen_decl_marked(st, decl)
    } else if (k == K.assign) {
        let assign: Assign = node;
        gen_assign(st, assign)
    } else if (k == K.incdec) {
        let incdec: IncDec = node;
        gen_incdec(st, incdec, false)
    } else if (k == K.opassign) {
        let assign: OpAssign = node;
        gen_opassign(st, assign, false)
    } else if (k == K.index) {
        let index: Index = node;
        // maps scan their keys; strings read a byte; arrays index directly
        let kbt = infer(st, index.arr);
        if (unfold(kbt).k == K.tmap) { gen_map_get(st, index, "opt") }
        else if (unfold(kbt).k == K.tstr) { gen_byte_at(st, n_call2("byte_at", index.arr, index.idx, index.line, index.col)) }
        else { gen_index(st, index) }
    } else if (k == K.slice) {
        let slice: Slice = node;
        if ((infer(st, slice.arr)).k == K.tstr) { gen_str_slice(st, slice) } else { gen_slice(st, slice) }
    } else if (k == K.char) {
        let lit: Leaf = node;
        gen_lit(st, { k: K.num, v: lit.v, line: lit.line, col: lit.col })
    } else if (k == K.rectest) {
        let test: Narrow = node;
        gen_rectest(st, test)
    } else if (k == K.narrow) {
        // the value, converted into the narrowed type's layout (a match
        // arm's binding: rectest checked its tag)
        let narrow: Narrow = node;
        let src = infer(st, narrow.e);
        st = gen(st, narrow.e);
        let dst = types.narrow_type(src, narrow.typ);
        if (src.k == K.topt && dst.k != K.topt) {
            // `if let long n = v`: the binding is the option's payload -- the
            // deref `unwrap` does, trap and all (rectest proved it is there).
            // The box holds the payload in the destination type's own layout,
            // so there is no conversion to do afterwards.
            st = emit_insn(st, insn.F_JZ_L, lbl_new("y_opt_unwrap"), 0, 0, 0, 0, 0, 0);
            emit_insn(st, insn.F_MOV_0_R, insn.R_RAX, -1, 1, -1, -1, insn.R_RAX, 64)
        } else {
            gen_convert(st, src, dst, false)
        }
    } else if (k == K.matchend) {
        // unreachable when the checker accepted the match
        st = emit_insn(st, insn.F_CALL_L, lbl_new("y_match_fail"), 0, 0, 0, 0, 0, 0);
        emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0)
    } else if (k == K.sliceassign) {
        let assign: SliceAssign = node;
        gen_sliceassign(st, assign)
    } else if (k == K.idxassign) {
        let assign: IdxAssign = node;
        if (unfold((infer(st, assign.arr))).k == K.tmap) { gen_map_set(st, assign) } else { gen_idxassign(st, assign) }
    } else if (k == K.dotassign) {
        let assign: DotAssign = node;
        gen_dotassign(st, assign)
    } else if (k == K.dot) {
        let dot: Dot = node;
        gen_dot(st, dot)
    } else if (k == K.rec) {
        // record literal anywhere (let/call-arg): heap address in %rax.
        let rec: RecLit = node;
        gen_reclit(st, rec, { k: K.tnone })
    } else if (k == K.map) {
        // map literal: the {keys, vals, boxes} record, heap address in %rax.
        let map: RecLit = node;
        gen_maplit(st, map)
    } else if (k == K.arrrep) {
        // [v; n] anywhere (let/assign/call-arg): heap address in %rax.
        let rep: ArrRep = node;
        gen_arrrep(st, rep)
    } else if (k == K.func) {
        // Anonymous function literal in expression position.
        let func: Func = node;
        gen_func_literal(st, func)
    } else if (k == K.store) {
        let store: Store = node;
        gen_store(st, store)
    } else if (k == K.kw_break || k == K.kw_continue) {
        // types.y has already refused a bare `break`/`continue` with no loop
        // to leave and one that would cross a function boundary, so the
        // innermost target is live here. Nothing is left in %rax: the merge
        // label that follows needs no value (the same reason a loop's own
        // does not -- see gen_while).
        let leaf: Leaf = node;
        let label: str = leaf.v;
        let target = cont_label;
        if (k == K.kw_break) { target = brk_label; };
        if (label != "") {
            // The parser resolved the label to a loop depth (outermost is 0)
            // before rename.y could change the variable's name. A malformed
            // label only reaches here in a program the checker rejects.
            let depth = tolong(label) !;
            if (depth >= 0 && depth < len(loop_brks)) {
                if (k == K.kw_break) { target = loop_brks[depth]; }
                else { target = loop_conts[depth]; };
            };
        };
        emit_insn(st, insn.F_JMP_L, target, 0, 0, 0, 0, 0, 0)
    } else if (k == K.ret) {
        let ret: Wrap = node;
        st = gen_as(st, ret.e, cur_fn_ret(st));
        emit_insn(st, insn.F_JMP_L, st.end_label, 0, 0, 0, 0, 0, 0)
    } else {
        // Unreachable: the checker rejects everything else.
        emit(st, "    # INTERNAL: unhandled " + ktag(k) + " (checker drift)")
    }
};

// A string literal in .rodata: header object [len, data..., NUL]; the value
// is the header's address. Used by `str` nodes and by every synthesised
// constant (typeof, function/record formatting).
// b"..." / b'...' -- a packed [byte] literal: desugar to a
// one-byte-per-element array literal and let gen_array_esz do the packing.
def gen_bstr(st: EmitSt, node: Leaf) -> EmitSt {
    let bv: str = node.v;
    let elems: [Node] = [];
    for bi in 0..len(bv) {
        let bnum: Leaf = { k: K.num, v: tostring(bv[bi]), line: node.line, col: node.col };
        elems += bnum;
    };
    let barr: ArrLit = { k: K.array, elems: elems, line: node.line, col: node.col };
    gen_array_esz(st, barr, 1, { k: K.tnone })
};

def gen_str_const(st: EmitSt, s: str) -> EmitSt {
    let r = next_uid(st);
    st = r.st;
    let lbl = arch.arch_str_label(r.uid);
    let id = lbl_new(lbl);
    // NOTE: push-chain over a let-bound [] (not a literal). The checker
    // rejects heterogeneous array literals ([str, long, str]); these three
    // parts are all str, so a literal would check too — the push-chain is
    // just the shape the other node-list builders use.
    let rod0: [str] = [];
    rod0 += lbl;
    rod0 += tostring(len(s));
    rod0 += esc_asm(s);
    st.rodata += [rod0];
    st = { ir: st.ir, txt: st.txt, rodata: st.rodata, uid: st.uid,
        fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots, temp: st.temp,
        self_label: st.self_label, end_label: st.end_label, fns: st.fns,
        bodies: st.bodies, btext: st.btext, blabels: st.blabels };
    emit_insn(st, insn.F_LEA_P_R, -1, -1, 1, 0, id, insn.R_RAX, 64)
};

def gen_id(st: EmitSt, node: Leaf) -> EmitSt {
    if (node.v == "self") {
        // Bare `self` as a value: only legal in discarded positions
        // (the checker rejects every typed use). Emit zero (none).
        emit(st, "    xor %eax, %eax  # bare self (discarded)")
    } else if (node.v == "none") {
        // The empty option (checker gives it typeof from context).
        emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0)
    } else {
        let e = env_find(st, node.v);
        if (e.kind == "none") {
            emit(st, "    # INTERNAL: undefined " + node.v)
        } else if (e.kind == "func") {
            // A hoisted def used as a VALUE: wrap it in a closure record
            // with no captures (hoisted defs capture nothing). A capturing
            // function naming itself hands out its own record instead.
            let soff = -1;
            if (e.label == st.self_label) {
                soff = capture_off(st);
            }
            if (soff >= 0) {
                emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, soff, -1, insn.R_RAX, 64)
            } else {
                gen_make_closure(st, e.label, [])
            }
        } else if (e.kind == "global") {
            // An appendable global gives up its buffer on every read
            // (see gen_sappend).
            if (e.typ.k == K.tstr) {
                let oe = env_find(st, node.v + "#o");
                if (oe.kind == "none") { } else {
                    st = emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
                    st = emit_insn(st, insn.F_MOV_R_P, insn.R_RAX, 64, -1, -1, 1, 0, oe.label);
                };
            }
            emit_insn(st, insn.F_MOV_P_R, -1, -1, 1, 0, e.label, insn.R_RAX, 64)
        } else if (e.kind == "own") {
            // an appendable string: a read may let its buffer escape, so
            // the companion is cleared (see gen_sappend)
            st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, e.off, -1, insn.R_RAX, 64);
            emit_insn(st, insn.F_MOV_I_D, 0, insn.R_RBP, -1, 1, e.off - 8, -1, 0)
        } else if (e.kind == "capture") {
            // Captured by the enclosing closure: load the closure record
            // (at the frame offset recorded in `off`), read slot idx+1 —
            // the shared cell pointer — and deref it (see box_capture).
            // NOTE: the index rides in `label` — env entries have no spare
            // numeric field and adding one would touch every signature.
            let idx = leading_long(e.mark);
            st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, e.off, -1, insn.R_RCX, 64);
            st = emit_insn(st, insn.F_MOV_D_R, insn.R_RCX, -1, 1, 8 * (idx + 1), -1, insn.R_RAX, 64);
            emit_insn(st, insn.F_MOV_0_R, insn.R_RAX, -1, 1, -1, -1, insn.R_RAX, 64)
        } else if (e.kind == "box") {
            // A captured variable's shared cell; the slot holds its pointer.
            st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, e.off, -1, insn.R_RAX, 64);
            emit_insn(st, insn.F_MOV_0_R, insn.R_RAX, -1, 1, -1, -1, insn.R_RAX, 64)
        } else {
            emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, e.off, -1, insn.R_RAX, 64)
        }
    }
};

// ── closures ───────────────────────────────────────────────────────────
// A closure is a heap record [code_addr, cap0, cap1, ...] and its VALUE is
// that address (8 bytes, like every other value).
//
// Calling convention: the caller pushes the closure FIRST (deepest), then
// the args left to right. Param offsets are therefore identical to a direct
// call, and the closure pointer sits at rbp+16+8*nargs. That is why a
// capture-free body works unchanged under both call forms: it simply never
// reads that slot, and the caller cleans up either way.

// The cell pointer for a capture, in %rax. Every capture slot holds a
// heap BOX pointer (see box_capture) — through a closure record or through
// a "box" binding alike.
def gen_cap_ptr(st: EmitSt, name: str) -> EmitSt {
    let e = env_find(st, name);
    if (e.kind == "capture") {
        // NOTE: the index rides in `label` (see gen_id's capture arm).
        let pidx = leading_long(e.mark);
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, e.off, -1, insn.R_RCX, 64);
        emit_insn(st, insn.F_MOV_D_R, insn.R_RCX, -1, 1, 8 * (pidx + 1), -1, insn.R_RAX, 64)
    } else {
        emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, e.off, -1, insn.R_RAX, 64)
    }
};

// A captured variable lives in ONE heap cell shared by its binding and
// every closure over it: writes through either are visible through both —
// the scope is shared, exactly as in the C copy's value model (yv.c)
// (the old native model copied the value at creation and could not even
// write to a capture). The cell is allocated where the variable is BOUND
// (box_bound: declaration, parameter entry, loop-variable refresh), so
// every later read and write — before or after the closure exists, on
// any path — goes through it. Boxing at the closure's creation site
// instead would leave code emitted earlier (a loop's condition, the other
// arm of an `if`) on the stale frame slot. box_capture allocates the cell
// from the current value and re-binds the name to it (kind "box"); it is
// a no-op for a name already boxed. A loop variable is bound once per
// iteration, so each iteration's closures share one fresh cell; a
// variable declared before a loop shares one cell across iterations.
def box_capture(st: EmitSt, name: str) -> EmitSt {
    let e = env_find(st, name);
    if (e.kind == "box" || e.kind == "capture") {
        st
    } else {
        st = gen_id(st, { k: K.id, v: name, line: 0, col: 0 });
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_I_R, 8, insn.R_RDI, 64, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_CALL_L, lbl_new("y_alloc"), 0, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_POP_R, insn.R_RDX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_R_0, insn.R_RDX, 64, insn.R_RAX, -1, 1, -1, -1);
        let boff = (st.slots + 1) * -8;
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, boff, -1);
        let st2 = { ir: st.ir, txt: st.txt, rodata: st.rodata, uid: st.uid,
            fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots + 1, temp: st.temp,
            self_label: st.self_label, end_label: st.end_label, fns: st.fns,
            bodies: st.bodies, btext: st.btext, blabels: st.blabels };
        env_define(st2, name, "box", boff, -1, "", e.typ)
    }
};

// The names nested functions read: every binding of this body that a
// closure can capture (names are unique after rename, so the others —
// the nested functions' own locals, globals, defs — are never bound
// here). emit_one_fn records them as "boxmark" entries past a "frame"
// entry, named "" so no lookup can hit them, the marked name in `label`.
def box_names(func: EmitFunc) -> [str] {
    let reads = fv_walk(func.body, [], false);
    let out: [str] = [];
    reads.foreach((e) => {
        let n: str = e;
        if (!(name_in(out, n))) {
            out += n;
        };
    });
    out
};

// Called right after `name` is bound: a captured name moves into its
// cell now (see box_capture). Scans back to this function's "frame".
def box_bound(st: EmitSt, name: str) -> EmitSt {
    let env = st.env;
    let i = len(env) - 1;
    let want = false;
    let more = true;
    while (more && i >= 0) {
        let e = env[i];
        if (e.kind == "frame") {
            more = false;
        } else if (e.kind == "boxmark" && e.mark == name) {
            want = true;
            more = false;
        }
        i = i - 1;
    };
    if (want) { box_capture(st, name) } else { st }
};

// ── owned strings: `s += x` in place ──────────────────────────────────
// An append used to copy the whole string (s = s + x), so n appends in a
// loop cost O(n^2) bytes. A str variable that `+=` targets now has a
// companion word: an "own" local keeps it in the slot below its value, an
// appendable global in a second .bss cell (app_cells). It holds 0, 1
// (an append statement is running), or the buffer the variable's last
// append statement produced, and every read of the variable clears it
// (gen_id). So "companion == value" proves nobody else ever saw that
// buffer, and the append may write into its spare room (y_str_app; its
// buffers keep their capacity in the word before the length). A variable
// whose address is taken, or that a closure captures, never qualifies.

// Every `+=` id target in a subtree, plus "&" + each name whose address
// is taken. With `deep` false nested functions are skipped: each gets its
// own walk, and a variable one of them touches is captured (boxed).
def app_walk(node: Node, out: [str], deep: bool) -> [str] {
    let k = node.k;
    // Most common kinds first: a leaf costs one compare, not the chain.
    if (k == K.id || k == K.num || k == K.str) {
    } else if (k == K.call) {
        let call: Call = node;
        out = app_walk(call.callee, out, deep);
        out = app_walk_list(call.args, out, deep);
    } else if (k == K.dot) {
        let dot: Dot = node;
        out = app_walk(dot.obj, out, deep);
    } else if (k == K.bin) {
        let bin: Bin = node;
        out = app_walk(bin.l, out, deep);
        out = app_walk(bin.r, out, deep);
    } else if (k == K.block) {
        let block: Block = node;
        out = app_walk_list(block.stmts, out, deep);
    } else if (k == K.arrrep || k == K.decl || k == K.assign) {
        let with_v: NodeV = node;
        out = app_walk(with_v.v, out, deep);
    } else if (k == K.kw_if) {
        let branch: If = node;
        out = app_walk(branch.cond, out, deep);
        out = app_walk(branch.then, out, deep);
        if (branch.has_else) {
            out = app_walk(branch.els, out, deep);
        }
    } else if (k == K.opassign) {
        let assign: OpAssign = node;
        let tg = assign.tgt;
        if (assign.op == "+" && tg.k == K.id) {
            let id: Leaf = tg;
            out += id.v;
        }
        out = app_walk(tg, out, deep);
        out = app_walk(assign.v, out, deep);
    } else if (k == K.index) {
        let index: Index = node;
        out = app_walk(index.arr, out, deep);
        out = app_walk(index.idx, out, deep);
    } else if (k == K.addr) {
        let addr: Wrap = node;
        let ae = addr.e;
        if (ae.k == K.id) {
            let id: Leaf = ae;
            out += "&" + id.v;
        }
        out = app_walk(ae, out, deep);
    } else if (k == K.un || k == K.deref || k == K.ret || k == K.rectest || k == K.narrow || k == K.matchend) {
        let child: NodeE = node;
        out = app_walk(child.e, out, deep);
    } else if (k == K.array) {
        let array: ArrLit = node;
        out = app_walk_list(array.elems, out, deep);
    } else if (k == K.rec || k == K.map) {
        let rec: RecLit = node;
        out = app_walk_list(rec.vals, out, deep);
    } else if (k == K.slice) {
        let slice: Slice = node;
        out = app_walk(slice.arr, out, deep);
        out = app_walk(slice.lo, out, deep);
        out = app_walk(slice.hi, out, deep);
    } else if (k == K.idxassign) {
        let assign: IdxAssign = node;
        out = app_walk(assign.arr, out, deep);
        out = app_walk(assign.idx, out, deep);
        out = app_walk(assign.v, out, deep);
    } else if (k == K.dotassign) {
        let assign: DotAssign = node;
        out = app_walk(assign.obj, out, deep);
        out = app_walk(assign.v, out, deep);
    } else if (k == K.store) {
        let store: Store = node;
        out = app_walk(store.p, out, deep);
        out = app_walk(store.v, out, deep);
    } else if (k == K.incdec) {
        let incdec: IncDec = node;
        out = app_walk(incdec.tgt, out, deep);
    } else if (k == K.kw_while) {
        let loop: While = node;
        out = app_walk(loop.cond, out, deep);
        out = app_walk(loop.body, out, deep);
    } else if (k == K.kw_for) {
        let loop: For = node;
        out = app_walk(loop.init, out, deep);
        out = app_walk(loop.cond, out, deep);
        out = app_walk(loop.step, out, deep);
        out = app_walk(loop.body, out, deep);
    } else if (k == K.kw_foreach) {
        let loop: Foreach = node;
        out = app_walk(loop.iter, out, deep);
        out = app_walk(loop.body, out, deep);
    } else if (k == K.forrange) {
        let loop: ForRange = node;
        out = app_walk(loop.lo, out, deep);
        out = app_walk(loop.hi, out, deep);
        out = app_walk(loop.body, out, deep);
    } else if (k == K.func) {
        let func: Func = node;
        if (deep) { out = app_walk(func.body, out, deep); }
    } else if (k == K.sliceassign) {
        let assign: SliceAssign = node;
        out = app_walk(assign.arr, out, deep);
        out = app_walk(assign.lo, out, deep);
        out = app_walk(assign.hi, out, deep);
        out = app_walk(assign.v, out, deep);
    }
    out
};

def app_walk_list(nodes: [Node], out: [str], deep: bool) -> [str] {
    nodes.foreach((e) => {
        out = app_walk(e, out, deep);
    });
    out
};

// The names in a subtree (`deep`: a whole program) an append statement
// may extend in place: `+=` targets whose address is never taken, minus
// `skip` (the names closures capture). Only the str-typed ones are used.
def app_names(node: Node, deep: bool, skip: [str]) -> [str] {
    let seen = app_walk(node, [], deep);
    let out: [str] = [];
    seen.foreach((e) => {
        let n: str = e;
        if (!(n[:1] == "&" || name_in(out, n) || name_in(skip, n) || name_in(seen, "&" + n))) {
            out += n;
        };
    });
    out
};

// Before a str variable is bound: does this function append to it (an
// "appmark" past its "frame", see emit_one_fn)?
def own_wanted(st: EmitSt, name: str) -> bool {
    let env = st.env;
    let i = len(env) - 1;
    let want = false;
    let more = true;
    while (more && i >= 0) {
        let e = env[i];
        if (e.kind == "frame") {
            more = false;
        } else if (e.kind == "appmark" && e.mark == name) {
            want = true;
            more = false;
        }
        i = i - 1;
    };
    want
};

// Bind an appendable str to the value in %rax: the value slot, and its
// companion in the slot below, cleared.
def bind_own(st: EmitSt, name: str, t: Type) -> EmitSt {
    let off = (st.slots + 1) * -8;
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, off, -1);
    st = emit_insn(st, insn.F_MOV_I_D, 0, insn.R_RBP, -1, 1, off - 8, -1, 0);
    let st2 = { ir: st.ir, txt: st.txt, rodata: st.rodata, uid: st.uid,
        fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots + 2, temp: st.temp,
        self_label: st.self_label, end_label: st.end_label, fns: st.fns,
        bodies: st.bodies, btext: st.btext, blabels: st.blabels };
    env_define(st2, name, "own", off, -1, "", t)
};

// A statement nobody takes the value of. `s += x` on an appendable string
// (an "own" local, or a global with a companion cell) goes through
// gen_sappend (the checker made x a str); anything else is plain gen.
def gen_stmt(st: EmitSt, node: Node) -> EmitSt {
    if (node.k == K.id) {
        // A local read as a statement is one `mov %rbp`-relative nobody reads:
        // these are the temporaries the `x++` / `x op= v` desugar leaves
        // behind (the synthetic `let v` is a kind "local" slot). Only that
        // kind is dropped: "own" is an appendable string, whose read clears
        // the companion cell, "global" may have one, and "box"/"capture" read
        // through a cell.
        let id: Leaf = node;
        if ((env_find(st, id.v)).kind == "local") { st } else { gen(st, node) }
    } else if (node.k == K.incdec) {
        // `x++` as a statement: the desugar's block value is the old x, and
        // nothing reads it (see gen_incdec's `dropped`).
        let inc: IncDec = node;
        gen_incdec(st, inc, true)
    } else if (node.k == K.opassign) {
        let assign: OpAssign = node;
        if (assign.op == "+" && assign.tgt.k == K.id) {
            let id: Leaf = assign.tgt;
            let e = env_find(st, id.v);
            if (e.kind == "own") {
                gen_sappend(st, assign.v, -1, e.off, -1, e.off - 8)
            } else if (e.kind == "global" && e.typ.k == K.tstr) {
                let oe = env_find(st, id.v + "#o");
                if (oe.kind == "none") {
                    gen_opassign(st, assign, true)
                } else {
                    gen_sappend(st, assign.v, e.label, 0, oe.label, 0)
                }
            } else {
                gen_opassign(st, assign, true)
            }
        } else {
            gen_opassign(st, assign, true)
        }
    } else {
        gen(st, node)
    }
};

// `s += v` as a statement on an appendable string; `var` and `cell` are
// the operands of the variable and of its companion. Ownership is decided
// before v runs (companion := 1 if it held the value, else 0); anything v
// does to the variable (a read clears the companion, a nested append
// stores its buffer there) leaves it != 1, and y_str_app copies. The
// order is s = s + v's: the old value first, then v.
def gen_sappend(st: EmitSt, v: Node, var_lbl: long, var_disp: long,
    cell_lbl: long, cell_disp: long) -> EmitSt {
    let va = memop(var_lbl, var_disp);
    let ca = memop(cell_lbl, cell_disp);
    st = emit_insn(st, insn.F_MOV_P_R, va[0], va[1], va[2], va[3], va[4],
        insn.R_RAX, 64);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_P_R, ca[0], ca[1], ca[2], ca[3], ca[4],
        insn.R_RDX, 64);
    st = emit_insn(st, insn.F_CMP_R_R, insn.R_RDX, 64, insn.R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_SETE_R, insn.R_RAX, 8, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOVZBQ_R_R, insn.R_RAX, 8, insn.R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_R_P, insn.R_RAX, 64, ca[0], ca[1], ca[2],
        ca[3], ca[4]);
    st = gen(st, v);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_P_R, ca[0], ca[1], ca[2], ca[3], ca[4],
        insn.R_RAX, 64);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_str_app"), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_ADD_I_R, 24, insn.R_RSP, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_R_P, insn.R_RAX, 64, va[0], va[1], va[2],
        va[3], va[4]);
    emit_insn(st, insn.F_MOV_R_P, insn.R_RAX, 64, ca[0], ca[1], ca[2], ca[3],
        ca[4])
};

// A loop body: its value is dropped, so a block body's last statement is
// a statement too (gen_stmt).
def gen_discard(st: EmitSt, node: Node) -> EmitSt {
    if (node.k == K.block) {
        let block: Block = node;
        gen_block_as(st, block, true)
    } else {
        gen_stmt(st, node)
    }
};

// One companion cell (see gen_sappend) per str global an append statement
// may extend in place, named `<global>#o` (`#` never occurs in a Y name)
// so gen_id and gen_stmt find it beside the global. The program is walked
// only when it has a str global at all.
def app_cells(gl: [Sym], stmts: [Node]) -> [Sym] {
    let anystr = false;
    gl.foreach((ge) => {
        if (ge.typ.k == K.tstr) { anystr = true; }
    });
    if (anystr) {
        let names = app_names({ k: K.block, stmts: stmts, line: 1, col: 1 }, true, []);
        let out: [Sym] = [];
        out += gl;
        gl.foreach((g2) => {
            if (g2.typ.k == K.tstr && name_in(names, g2.name)) {
                out += { name: g2.name + "#o", label: "ygo_" + g2.label[3:], typ: normtype({ k: K.tnone }) };
            }
        });
        out
    } else {
        gl
    }
};

def gen_make_closure(st: EmitSt, label: long, caps: [str]) -> EmitSt {
    let n = len(caps);
    st = emit_insn(st, insn.F_MOV_I_R, 8 + 8 * n, insn.R_RDI, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_alloc"), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_LEA_P_R, -1, -1, 1, 0, label, insn.R_RCX, 64);
    st = emit_insn(st, insn.F_MOV_R_0, insn.R_RCX, 64, insn.R_RAX, -1, 1, -1, -1);
    for i in 0..n {
        let cn: str = caps[i];
        // Captured as a shared cell pointer (see box_capture).
        st = gen_cap_ptr(st, cn);
        st = emit_insn(st, insn.F_POP_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RCX, -1, 1, 8 * (i + 1), -1);
    };
    emit_insn(st, insn.F_POP_R, insn.R_RAX, 64, 0, 0, 0, 0, 0)
};

// range(n) -> [0, 1, ..., n-1] as a heap array (the loop-friendly builtin;
// y_range in std/rt.y).
def gen_range(st: EmitSt, node: Call) -> EmitSt {
    st = gen_push_args(st, node.args);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_range"), 0, 0, 0, 0, 0, 0);
    emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0)
};

// arr[lo:hi] — half-open, clamped, always a NEW heap array (the operands
// are untouched, like `+` on arrays). A missing bound means 0 / len.
def gen_slice(st: EmitSt, node: Slice) -> EmitSt {
    let lo = node.lo;
    let hi = node.hi;
    let slesz = arr_elem_bytes(infer(st, node.arr));
    st = gen(st, node.arr);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = lo.k == K.void ? emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0) : gen(st, lo);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    if (hi.k == K.void) {
        // default: the array's length (the header keeps it in slot 0);
        // the array pointer sits one slot below the pushed lo.
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RSP, -1, 1, 8, -1, insn.R_RAX, 64);
        st = emit_insn(st, insn.F_MOV_0_R, insn.R_RAX, -1, 1, -1, -1, insn.R_RAX, 64);
    } else {
        st = gen(st, hi);
    };
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_I_R, slesz, insn.R_RAX, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_arr_slice"), 0, 0, 0, 0, 0, 0);
    emit_insn(st, insn.F_ADD_I_R, 32, insn.R_RSP, 64, 0, 0, 0, 0)
};

// s[lo:hi] -- the substring, half-open and clamped like an array slice;
// a missing bound means 0 / len (the asm primitive y_str_slice).
def gen_str_slice(st: EmitSt, node: Slice) -> EmitSt {
    let lo = node.lo;
    let hi = node.hi;
    st = gen(st, node.arr);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = lo.k == K.void ? emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0) : gen(st, lo);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    if (hi.k == K.void) {
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RSP, -1, 1, 8, -1, insn.R_RAX, 64);
        st = emit_insn(st, insn.F_MOV_0_R, insn.R_RAX, -1, 1, -1, -1, insn.R_RAX, 64);
    } else {
        st = gen(st, hi);
    };
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_str_slice"), 0, 0, 0, 0, 0, 0);
    emit_insn(st, insn.F_ADD_I_R, 24, insn.R_RSP, 64, 0, 0, 0, 0)
};

// a[lo:hi] = src: y_arr_setslice{1,8} (rt.y) check the range and the
// length, then copy src's elements in. Evaluation order: a, lo, hi, src.
def gen_sliceassign(st: EmitSt, node: SliceAssign) -> EmitSt {
    let lo = node.lo;
    let hi = node.hi;
    let esz = arr_elem_bytes(infer(st, node.arr));
    st = gen(st, node.arr);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = lo.k == K.void ? emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0) : gen(st, lo);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    if (hi.k == K.void) {
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RSP, -1, 1, 8, -1, insn.R_RAX, 64);
        st = emit_insn(st, insn.F_MOV_0_R, insn.R_RAX, -1, 1, -1, -1, insn.R_RAX, 64);
    } else {
        st = gen(st, hi);
    };
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen(st, node.v);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_arr_setslice" + tostring(esz)),
        0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_ADD_I_R, 32, insn.R_RSP, 64, 0, 0, 0, 0);
    emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0)
};

// `T` / `{f: v}` pattern test (types.y typeof_rectest): 1 in %rax when the
// value of node.e matches. A union holds exactly one member: the test
// compares the value's descriptor with those of the members the pattern
// matches (rectest_members). A record matches by its static type (the
// checker rejected a pattern it cannot match).
def gen_rectest(st: EmitSt, node: Narrow) -> EmitSt {
    let s = infer(st, node.e);
    let sk: long = s.k;
    st = gen(st, node.e);
    if (sk == K.tunion) {
        gen_tag_in(st, rectest_members(s, node.typ), s)
    } else if (sk == K.topt) {
        // `if let long n = v` where v is an option (TODO.md item 13; `some(m)`
        // lowers to exactly this). The checker only lets a scalar pattern
        // reach here, so the test is the option's own: %rax is 0 for none.
        st = emit_insn(st, insn.F_TEST_R_R, insn.R_RAX, 64, insn.R_RAX, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_SETNE_R, insn.R_RAX, 8, 0, 0, 0, 0, 0);
        emit_insn(st, insn.F_MOVZBQ_R_R, insn.R_RAX, 8, insn.R_RAX, 64, 0, 0, 0)
    } else {
        // a record, or the scalar itself: the checker took the pattern as its
        // own type, so it always matches
        emit_insn(st, insn.F_MOV_I_R, 1, insn.R_RAX, 64, 0, 0, 0, 0)
    }
};

// The members of union s (as written, types.y union_parts) the pattern t
// matches: t itself (a type pattern), or every member with the fields of
// a record pattern.
def rectest_members(s: Type, t: Type) -> [Type] {
    let tk: long = t.k;
    if (tk == K.tpat) {
        types.pat_members(s, t)
    } else {
        let out: [Type] = [];
        let m = types.union_member(s, t);
        let mk: long = m.k;
        if (mk != K.tnone) { out += m; }
        out
    }
};

// Record in %rax -> 1 when its descriptor is that of one of the record
// types ts held where `inu` is declared (a union: its layout), else 0.
def gen_tag_in(st: EmitSt, ts: [Type], inu: Type) -> EmitSt {
    let rno = next_loc(st);
    st = rno.st;
    let rdone = next_loc(st);
    st = rdone.st;
    st = emit_insn(st, insn.F_TEST_R_R, insn.R_RAX, 64, insn.R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JZ_L, rno.label, 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RAX, -1, 1, -8, -1, insn.R_RCX, 64);
    let yes = next_loc(st);
    st = yes.st;
    ts.foreach((e) => {
        let dr = ty_desc_in(st, e, inu);
        st = dr.st;
        st = emit_insn(st, insn.F_LEA_P_R, -1, -1, 1, 0, dr.label, insn.R_RDX, 64);
        st = emit_insn(st, insn.F_CMP_R_R, insn.R_RDX, 64, insn.R_RCX, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_JE_L, yes.label, 0, 0, 0, 0, 0, 0);
    });
    st = emit_label(st, rno.label);
    st = emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
    st = emit_insn(st, insn.F_JMP_L, rdone.label, 0, 0, 0, 0, 0, 0);
    st = emit_label(st, yes.label);
    st = emit_insn(st, insn.F_MOV_I_R, 1, insn.R_RAX, 64, 0, 0, 0, 0);
    emit_label(st, rdone.label)
};

// Union value in %rax -> its string form: the member its descriptor names
// ("<union>" for none).
def gen_union_str_rax(st: EmitSt, t: Type, path: [Type]) -> EmitSt {
    let ms = types.union_parts(t);
    let rdone = next_loc(st);
    st = rdone.st;
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    ms.foreach((e) => {
        let rnext = next_loc(st);
        st = rnext.st;
        let mt = e;
        let one: [Type] = [];
        one += mt;
        st = emit_insn(st, insn.F_MOV_0_R, insn.R_RSP, -1, 1, -1, -1, insn.R_RAX, 64);
        st = gen_tag_in(st, one, t);
        st = emit_insn(st, insn.F_TEST_R_R, insn.R_RAX, 64, insn.R_RAX, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_JZ_L, rnext.label, 0, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_POP_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        let mu = types.unfold(mt);
        if (types.is_boxable_type(mu)) {
            st = gen_slot_move(st, (mfield_idx((union_lay(mu, t)), types.box_field_name(mu))), false);
            st = gen_val_tostr_rax(st, mu, path + t);
        } else {
            st = gen_rec_str_rax(st, mu, union_lay(mu, t), path + t);
        };
        st = emit_insn(st, insn.F_JMP_L, rdone.label, 0, 0, 0, 0, 0, 0);
        st = emit_label(st, rnext.label);
    });
    st = emit_insn(st, insn.F_POP_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen_str_const(st, "<union>");
    emit_label(st, rdone.label)
};

// Indirect call through a closure value produced by `callee`.
def gen_indirect(st: EmitSt, node: Call, callee: Node) -> EmitSt {
    let args: [Node] = node.args;
    let n = len(args);
    let iptypes = fn_args_of(infer(st, callee));
    st = gen(st, callee);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen_push_args_as(st, args, iptypes);
    // Reload the closure (it sits just below the n pushed args) and call
    // through its code pointer.
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RSP, -1, 1, 8 * n, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RAX, -1, 1, -1, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_CALL_IND, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    emit_insn(st, insn.F_ADD_I_R, 8 * (n + 1), insn.R_RSP, 64, 0, 0, 0, 0)
};

def gen_un(st: EmitSt, node: Un) -> EmitSt {
    let ut = infer(st, node.e);
    st = gen(st, node.e);
    if (node.op == "-") {
        if (ut.k == K.tbigint) {
            st = gen_helper1(st, "y_bigint_neg");
            st
        } else if (ut.k == K.tfloat) {
            // flip the sign bit: -0.0 is a negative zero, -nan a nan
            st = emit_insn(st, insn.F_MOV_I_R, 1, insn.R_RCX, 64, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_SHL_I_R, 63, insn.R_RCX, 64, 0, 0, 0, 0);
            emit_insn(st, insn.F_XOR_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0)
        } else {
            emit_insn(st, insn.F_NEG_R, insn.R_RAX, 64, 0, 0, 0, 0, 0)
        }
    } else if (node.op == "~") {
        emit_insn(st, insn.F_NOT_R, insn.R_RAX, 64, 0, 0, 0, 0, 0)
    } else {
        emit_insn(st, insn.F_XOR_I_R, 1, insn.R_RAX, 64, 0, 0, 0, 0)
    }
};

def gen_addr(st: EmitSt, node: Wrap) -> EmitSt {
    // Checker guarantees plain ids, or id-rooted index into an array.
    if (node.e.k == K.index) {
        let index: Index = node.e;
        gen_elem_addr(st, index)
    } else {
        let id: Leaf = node.e;
        let e = env_find(st, id.v);
        if (e.kind == "box") {
            // the shared cell IS the variable's address
            emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, e.off, -1, insn.R_RAX, 64)
        } else if (e.kind == "global") {
            emit_insn(st, insn.F_LEA_P_R, -1, -1, 1, 0, e.label, insn.R_RAX, 64)
        } else if (e.kind == "capture") {
            let aidx = leading_long(e.mark);
            st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, e.off, -1, insn.R_RCX, 64);
            emit_insn(st, insn.F_MOV_D_R, insn.R_RCX, -1, 1, 8 * (aidx + 1), -1, insn.R_RAX, 64)
        } else {
            emit_insn(st, insn.F_LEA_D_R, insn.R_RBP, -1, 1, e.off, -1, insn.R_RAX, 64)
        }
    }
};

// Address of element arr[idx] in %rax (bounds-trapped). Works for both
// array kinds: fixed (frame SIB) and heap (header load + SIB).
def gen_elem_addr(st: EmitSt, node: Index) -> EmitSt {
    // &a[i] — an element's address. The base is any array expression
    // (`&grid[0][i]` too) and runs once, before the index (the same order
    // gen_index and the VM use).
    let earr = node.arr;
    let bt = infer(st, earr);
    let eaesz = arr_elem_bytes(bt);
    let eascale = 8;
    if (eaesz == 1) { eascale = 1; }
    st = gen(st, earr);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen(st, node.idx);
    st = emit_insn(st, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_RCX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_POP_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_TEST_R_R, insn.R_RCX, 64, insn.R_RCX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JS_L, lbl_new("y_oob"), 0, 0, 0, 0, 0, 0);
    if (bt.k == K.tarrfix) {
        let arr: TFix = bt;
        st = emit_insn(st, insn.F_CMP_I_R, arr.n, insn.R_RCX, 64, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_JGE_L, lbl_new("y_oob"), 0, 0, 0, 0, 0, 0);
    } else {
        st = emit_insn(st, insn.F_MOV_0_R, insn.R_RAX, -1, 1, -1, -1, insn.R_RDX, 64);
        st = emit_insn(st, insn.F_CMP_R_R, insn.R_RDX, 64, insn.R_RCX, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_JGE_L, lbl_new("y_oob"), 0, 0, 0, 0, 0, 0);
    };
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RAX, -1, 1, 16, -1, insn.R_RAX, 64);
    emit_insn(st, insn.F_LEA_M_R, insn.R_RAX, insn.R_RCX, eascale, 0, -1,
        insn.R_RAX, 64)
};

def gen_bin(st: EmitSt, node: Bin) -> EmitSt {
    let op = node.op;
    // Lazy &&/||: short-circuit jumps, not eager and/or (the right operand
    // must not run when the left already decides).
    if (op == "&&") {
        gen_logic(st, node, false)
    } else if (op == "||") {
        gen_logic(st, node, true)
    } else if ((op == "==" || op == "!=") && is_none_id(node.r) && is_map_read(st, node.l)) {
        // m[k] == none, m[k] != none: the key scan decides, nothing is
        // boxed (gen_map_get)
        if (op == "==") { gen_map_get(st, node.l, "none") } else { gen_map_get(st, node.l, "has") }
    } else if (op == "in") {
        gen_in(st, node)
    } else if ((op == "==" || op == "!=") && is_none_id(node.l) && is_map_read(st, node.r)) {
        if (op == "==") { gen_map_get(st, node.r, "none") } else { gen_map_get(st, node.r, "has") }
    } else {
        gen_bin_rest(st, node)
    }
};

// `x in s` / `e in a` (LINT_RULES.md 5.1): one pass, no short-circuit.
def gen_in(st: EmitSt, node: Bin) -> EmitSt {
    let ln = node.line;
    let cl = node.col;
    let zero = n_num("0", ln, cl);
    if ((unfold(infer(st, node.r))).k == K.tstr) {
        let needle = node.l;
        if (unfold(infer(st, node.l)).k == K.tbyte) {
            needle = { k: K.call, callee: n_id("chr", ln, cl), args: [node.l], line: ln, col: cl };
        };
        let call: Bin = { k: K.bin, op: ">=", l: n_call2("index_of", node.r, needle, ln, cl), r: zero, line: ln, col: cl };
        gen_bin(st, call)
    } else {
        let call: Bin = { k: K.bin, op: ">=", l: { k: K.call, callee: n_dot(node.r, "index", ln, cl), args: [node.l], line: ln, col: cl }, r: zero, line: ln, col: cl };
        gen_bin(st, call)
    }
};

// Short-circuit logic: value is 0/1; the right operand only evaluates when
// the left operand does not already decide the result.
//   a && b : test a -> jz F; test b -> jz F; 1; jmp E; F: 0; E:
//   a || b : test a -> jnz T; test b -> jnz T; 0; jmp E; T: 1; E:
def gen_logic(st: EmitSt, node: Bin, is_or: bool) -> EmitSt {
    let rT = next_loc(st);
    st = rT.st;
    let rF = next_loc(st);
    st = rF.st;
    let rE = next_loc(st);
    st = rE.st;
    st = gen(st, node.l);
    st = emit_insn(st, insn.F_TEST_R_R, insn.R_RAX, 64, insn.R_RAX, 64, 0, 0, 0);
    if (is_or) {
        st = emit_insn(st, insn.F_JNZ_L, rT.label, 0, 0, 0, 0, 0, 0);
    }
    if (!(is_or)) {
        st = emit_insn(st, insn.F_JZ_L, rF.label, 0, 0, 0, 0, 0, 0);
    };
    st = gen(st, node.r);
    st = emit_insn(st, insn.F_TEST_R_R, insn.R_RAX, 64, insn.R_RAX, 64, 0, 0, 0);
    if (is_or) {
        st = emit_insn(st, insn.F_JNZ_L, rT.label, 0, 0, 0, 0, 0, 0);
    }
    if (!(is_or)) {
        st = emit_insn(st, insn.F_JZ_L, rF.label, 0, 0, 0, 0, 0, 0);
    };
    if (!(is_or)) {
        st = emit_insn(st, insn.F_MOV_I_R, 1, insn.R_RAX, 64, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_JMP_L, rE.label, 0, 0, 0, 0, 0, 0);
    };
    if (is_or) {
        st = emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
        st = emit_insn(st, insn.F_JMP_L, rE.label, 0, 0, 0, 0, 0, 0);
        st = emit_label(st, rT.label);
        st = emit_insn(st, insn.F_MOV_I_R, 1, insn.R_RAX, 64, 0, 0, 0, 0);
    }
    if (!(is_or)) {
        st = emit_label(st, rF.label);
        st = emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
    };
    st = emit_label(st, rE.label)
};

// AUTO-STRINGIFY `+`: when a string meets a non-string, stringify the other
// side (y_long_tostr / y_bool_tostr) and concatenate — the same semantics
// types.y's typeof_arith gives. tstr+tstr is a plain concat; tstr+tunk falls
// back to the raw pointer concat (the old behavior) since the runtime type
// is unknown statically.
def gen_cat(st: EmitSt, node: Bin, lt: Type, rt: Type) -> EmitSt {
    // NOTE: y_long_tostr / y_bool_tostr take ONE STACK ARG (push; call;
    // add $8) — gen_tostring's pattern. y_str_cat takes two stack args.
    if (lt.k == K.tarr || lt.k == K.tarrfix || rt.k == K.tarr || rt.k == K.tarrfix) {
        return gen_cat_arr(st, node, lt, rt);
    };
    if (lt.k == K.tstr) {
        if (rt.k == K.tstr) {
            st = gen_push_args(st, [node.l, node.r]);
            st = emit_insn(st, insn.F_CALL_L, lbl_new("y_str_cat"), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0)
        } else if (rt.k == K.tlong) {
            st = gen(st, node.l);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = gen(st, node.r);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_CALL_L, lbl_new("y_long_tostr"), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_CALL_L, lbl_new("y_str_cat"), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0)
        } else if (rt.k == K.tbool) {
            st = gen(st, node.l);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = gen(st, node.r);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_CALL_L, lbl_new("y_bool_tostr"), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_CALL_L, lbl_new("y_str_cat"), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0)
        } else if (rt.k == K.tbyte) {
            // A byte stringifies as the number it holds: `s[i]` is a byte, so
            // this is the shape a glyph ramp or a lookup table builds a string
            // with. Without the arm a byte fell through to the unknown-
            // operand arm below, which pushes the VALUE where y_str_cat
            // wants a pointer -- a dereference of 65, and SIGSEGV. `gen` leaves
            // a byte zero-extended in %rax, so y_long_tostr takes it as it is.
            st = gen(st, node.l);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = gen(st, node.r);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_CALL_L, lbl_new("y_long_tostr"), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_CALL_L, lbl_new("y_str_cat"), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0)
        } else if (rt.k == K.tfloat) {
            st = gen(st, node.l);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = gen(st, node.r);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_CALL_L, lbl_new("y_float_tostr"), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_CALL_L, lbl_new("y_str_cat"), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0)
        } else if (rt.k == K.tbigint) {
            st = gen(st, node.l);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = gen(st, node.r);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_CALL_L, lbl_new("y_bigint_tostr"), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_CALL_L, lbl_new("y_str_cat"), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0)
        } else {
            // Unknown right operand: treat it as a string. Most unknowns
            // here ARE strings (a field read through an untyped hole infers
            // as tunk — the compiler's own tstr() does exactly that), and
            // the return-type inference in emit_program now pins down the
            // long-returning calls that used to land in this arm.
            st = gen_push_args(st, [node.l, node.r]);
            st = emit_insn(st, insn.F_CALL_L, lbl_new("y_str_cat"), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0)
        };
    }
    if (!(lt.k == K.tstr)) {
        if (lt.k == K.tlong) {
            st = gen(st, node.l);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_CALL_L, lbl_new("y_long_tostr"), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = gen(st, node.r);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_CALL_L, lbl_new("y_str_cat"), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0)
        } else if (lt.k == K.tbool) {
            st = gen(st, node.l);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_CALL_L, lbl_new("y_bool_tostr"), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = gen(st, node.r);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_CALL_L, lbl_new("y_str_cat"), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0)
        } else if (lt.k == K.tbyte) {
            // the mirror of the right-operand byte arm
            st = gen(st, node.l);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_CALL_L, lbl_new("y_long_tostr"), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = gen(st, node.r);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_CALL_L, lbl_new("y_str_cat"), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0)
        } else if (lt.k == K.tfloat) {
            st = gen(st, node.l);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_CALL_L, lbl_new("y_float_tostr"), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = gen(st, node.r);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_CALL_L, lbl_new("y_str_cat"), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0)
        } else if (lt.k == K.tbigint) {
            st = gen(st, node.l);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_CALL_L, lbl_new("y_bigint_tostr"), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = gen(st, node.r);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_CALL_L, lbl_new("y_str_cat"), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0)
        } else {
            // Unknown left operand: treat it as a string (see the note on
            // the right-operand arm).
            st = gen_push_args(st, [node.l, node.r]);
            st = emit_insn(st, insn.F_CALL_L, lbl_new("y_str_cat"), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0)
        };
    }
    st
};

// Whether generating `n` does nothing but leave a value in %rax.
//
// It answers two questions that happen to have the same answer, which is why it
// is one predicate and not two.
//
// For a FLOAT binary operator the question is "can this write an SSE register?",
// because the left operand has to be held across the right one's evaluation and
// the general answer is the stack -- a push and a pop per operator. If the right
// operand writes no SSE register at all, the left can sit in %xmm0 across it and
// the pair is two instructions of pure waste.
//
// For an INTEGER comparison that branches on flags (gen_cmp_flags) the question
// is "can this clobber %rcx, or call?", and a leaf does neither -- so the left
// can sit in %rcx and the push and pop go too.
//
// What qualifies: a numeric literal, which is one `mov $bits, %rax`; an
// identifier, which is one load -- from the frame, from a global, or through a
// closure's cell, and all three are GPR-only; and a unary operator over either,
// which generates its operand and then flips the sign bit or negates in a GPR
// (gen_un's float arm is `mov $1, %rcx; shl $63, %rcx; xor %rcx, %rax`, with no
// xmm in it at all). Everything else may write a register or call: a call
// clobbers every xmm and every GPR, a nested float operator uses %xmm0 and
// %xmm1 itself, a comparison uses them too, and an index expression can call
// y_oob on its bounds check. Guessing wrong here would not make a slow program,
// it would make a wrong one, so the predicate stays short of anything it cannot
// prove.
//
// The unary arm is not a small extension: it is the difference between a fitted
// polynomial losing half its saving and not, because every second coefficient in
// a Horner chain is negative and `-1.2` is a unary minus over a literal rather
// than a literal. Twelve of a chain's twenty-four operators were going the slow
// way on that alone.
def leaf_expr(n: Node) -> bool {
    if (n.k == K.num || n.k == K.id) {
        true
    } else if (n.k == K.un) {
        let un: Un = n;
        leaf_expr(un.e)
    } else {
        false
    }
};

// Float arithmetic and comparison. Operands arrive in %rax as raw bits;
// a long operand is widened with cvtsi2sd first (the only coercion).
//
// The two operand loads end in the same place (%xmm0 left, %xmm1 right) whichever
// way round they are done, and the operator dispatch below does not know or care
// which. The saving is not in the arithmetic: it is that a twelve-step Horner
// chain -- what every fitted polynomial kernel in std/math.y is -- went through
// 48 push/pop instructions out of 192, one pair per multiply-add, and now goes
// through none.
def gen_float_bin(st: EmitSt, node: Bin, lt: Type, rt: Type) -> EmitSt {
    let op = node.op;
    st = gen(st, node.l);
    if (!(lt.k == K.tfloat)) {
        st = emit_insn(st, insn.F_CVTSI2SD_R_R, insn.R_RAX, 64, insn.R_XMM0, 128, 0, 0, 0);
        st = emit_insn(st, insn.F_MOVQ_R_R, insn.R_XMM0, 128, insn.R_RAX, 64, 0, 0, 0);
    };
    // A long on the right needs the widening cvtsi2sd, and that writes %xmm0 --
    // which is where the left would be living. So this arm requires the right to
    // be a float already; the slow arm below handles the rest.
    if (leaf_expr(node.r) && rt.k == K.tfloat) {
        st = emit_insn(st, insn.F_MOVQ_R_R, insn.R_RAX, 64, insn.R_XMM0, 128, 0, 0, 0);
        st = gen(st, node.r);
        emit_insn(st, insn.F_MOVQ_R_R, insn.R_RAX, 64, insn.R_XMM1, 128, 0, 0, 0)
    } else {
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = gen(st, node.r);
        if (!(rt.k == K.tfloat)) {
            st = emit_insn(st, insn.F_CVTSI2SD_R_R, insn.R_RAX, 64, insn.R_XMM0, 128, 0, 0, 0);
            st = emit_insn(st, insn.F_MOVQ_R_R, insn.R_XMM0, 128, insn.R_RAX, 64, 0, 0, 0);
        };
        st = emit_insn(st, insn.F_MOVQ_R_R, insn.R_RAX, 64, insn.R_XMM1, 128, 0, 0, 0);
        st = emit_insn(st, insn.F_POP_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOVQ_R_R, insn.R_RAX, 64, insn.R_XMM0, 128, 0, 0, 0)
    };
    if (op == "+") {
        st = emit_insn(st, insn.F_ADDSD_R_R, insn.R_XMM1, 128, insn.R_XMM0, 128, 0, 0, 0);
        emit_insn(st, insn.F_MOVQ_R_R, insn.R_XMM0, 128, insn.R_RAX, 64, 0, 0, 0)
    } else if (op == "-") {
        st = emit_insn(st, insn.F_SUBSD_R_R, insn.R_XMM1, 128, insn.R_XMM0, 128, 0, 0, 0);
        emit_insn(st, insn.F_MOVQ_R_R, insn.R_XMM0, 128, insn.R_RAX, 64, 0, 0, 0)
    } else if (op == "*") {
        st = emit_insn(st, insn.F_MULSD_R_R, insn.R_XMM1, 128, insn.R_XMM0, 128, 0, 0, 0);
        emit_insn(st, insn.F_MOVQ_R_R, insn.R_XMM0, 128, insn.R_RAX, 64, 0, 0, 0)
    } else if (op == "/") {
        st = emit_insn(st, insn.F_DIVSD_R_R, insn.R_XMM1, 128, insn.R_XMM0, 128, 0, 0, 0);
        emit_insn(st, insn.F_MOVQ_R_R, insn.R_XMM0, 128, insn.R_RAX, 64, 0, 0, 0)
    } else if (op == "%") {
        // The IEEE remainder truncated toward zero -- C's fmod, the one with
        // the dividend's sign. There is no x87-style bit twiddling for it on
        // SSE2 (fmod has no instruction), so the prelude does the reduction;
        // both operands are already in SSE registers.
        st = emit_insn(st, insn.F_CALL_L, lbl_new("y_fmod"), 0, 0, 0, 0, 0, 0);
        emit_insn(st, insn.F_MOVQ_R_R, insn.R_XMM0, 128, insn.R_RAX, 64, 0, 0, 0)
    } else {
        // Comparisons. ucomisd sets ZF=PF=CF=1 when the operands are unordered
        // (a NaN anywhere), so every test has to look at the parity flag: the
        // unsigned conditions on their own (a/ae/b/be) read unordered as
        // ordered.
        //
        // `<` and `<=` compare the operands the other way round and take the
        // conditions that test CF=0, which unordered cannot satisfy; `>` and
        // `>=` already did. `==` and `!=` cannot be spelled out of CF/ZF at
        // all, so they test parity as well: two byte results and a combine,
        // since this assembler has no 8-bit `and`/`or`.
        if (op == "<") {
            st = emit_insn(st, insn.F_UCOMISD_R_R, insn.R_XMM0, 128, insn.R_XMM1, 128, 0, 0, 0);
            st = emit_insn(st, insn.F_SETA_R, insn.R_RAX, 8, 0, 0, 0, 0, 0);
            emit_insn(st, insn.F_MOVZBQ_R_R, insn.R_RAX, 8, insn.R_RAX, 64, 0, 0, 0)
        } else if (op == "<=") {
            st = emit_insn(st, insn.F_UCOMISD_R_R, insn.R_XMM0, 128, insn.R_XMM1, 128, 0, 0, 0);
            st = emit_insn(st, insn.F_SETAE_R, insn.R_RAX, 8, 0, 0, 0, 0, 0);
            emit_insn(st, insn.F_MOVZBQ_R_R, insn.R_RAX, 8, insn.R_RAX, 64, 0, 0, 0)
        } else if (op == ">") {
            st = emit_insn(st, insn.F_UCOMISD_R_R, insn.R_XMM1, 128, insn.R_XMM0, 128, 0, 0, 0);
            st = emit_insn(st, insn.F_SETA_R, insn.R_RAX, 8, 0, 0, 0, 0, 0);
            emit_insn(st, insn.F_MOVZBQ_R_R, insn.R_RAX, 8, insn.R_RAX, 64, 0, 0, 0)
        } else if (op == ">=") {
            st = emit_insn(st, insn.F_UCOMISD_R_R, insn.R_XMM1, 128, insn.R_XMM0, 128, 0, 0, 0);
            st = emit_insn(st, insn.F_SETAE_R, insn.R_RAX, 8, 0, 0, 0, 0, 0);
            emit_insn(st, insn.F_MOVZBQ_R_R, insn.R_RAX, 8, insn.R_RAX, 64, 0, 0, 0)
        } else {
            st = emit_insn(st, insn.F_UCOMISD_R_R, insn.R_XMM1, 128, insn.R_XMM0, 128, 0, 0, 0);
            if (op == "==") {
                st = emit_insn(st, insn.F_SETE_R, insn.R_RAX, 8, 0, 0, 0, 0, 0);
                st = emit_insn(st, insn.F_SETNP_R, insn.R_RCX, 8, 0, 0, 0, 0, 0);
            } else {
                st = emit_insn(st, insn.F_SETNE_R, insn.R_RAX, 8, 0, 0, 0, 0, 0);
                st = emit_insn(st, insn.F_SETP_R, insn.R_RCX, 8, 0, 0, 0, 0, 0);
            };
            st = emit_insn(st, insn.F_MOVZBQ_R_R, insn.R_RAX, 8, insn.R_RAX, 64, 0, 0, 0);
            st = emit_insn(st, insn.F_MOVZBQ_R_R, insn.R_RCX, 8, insn.R_RCX, 64, 0, 0, 0);
            st = op == "==" ? emit_insn(st, insn.F_AND_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0) : emit_insn(st, insn.F_OR_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0);
            st
        }
    }
};

def gen_str_cmp(st: EmitSt, node: Bin, op: str) -> EmitSt {
    st = gen_push_args(st, [node.l, node.r]);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_str_cmp"), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CMP_I_R, 0, insn.R_RAX, 64, 0, 0, 0, 0);
    if (op == "<") {
        st = emit_insn(st, insn.F_SETL_R, insn.R_RAX, 8, 0, 0, 0, 0, 0);
    } else if (op == ">") {
        st = emit_insn(st, insn.F_SETG_R, insn.R_RAX, 8, 0, 0, 0, 0, 0);
    } else if (op == "<=") {
        st = emit_insn(st, insn.F_SETLE_R, insn.R_RAX, 8, 0, 0, 0, 0, 0);
    } else {
        st = emit_insn(st, insn.F_SETGE_R, insn.R_RAX, 8, 0, 0, 0, 0, 0);
    };
    emit_insn(st, insn.F_MOVZBQ_R_R, insn.R_RAX, 8, insn.R_RAX, 64, 0, 0, 0)
};

// == on values whose equality looks inside them (NATIVE.md, "Equality"):
// two options compare their payloads, and an array compares each pair of
// elements with the element type's own ==, at any depth. Arrays of words
// whose == is the bit pattern, and arrays of strings, keep the y_arr_eq /
// y_arr_eq_str cores; the others loop here: options and arrays look
// inside, and floats compare as numbers (0.0 == -0.0).
def eq_elem_loop(t: Type) -> bool {
    t.k == K.topt || t.k == K.tarr || t.k == K.tfloat || t.k == K.tbigint
};

// The left operand pushed, the right one in %rax: pops the left and leaves
// left == right (0 or 1) in %rax, compared as type t.
def gen_eq_vals(st: EmitSt, t: Type) -> EmitSt {
    if (t.k == K.topt) {
        let opt: TOf = t;
        gen_eq_opt(st, opt.of)
    } else if (t.k == K.tarr) {
        let arr: TOf = t;
        if (eq_elem_loop(arr.of)) {
            gen_eq_arr_deep(st, arr.of)
        } else if (arr.of.k == K.tstr) {
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_CALL_L, lbl_new("y_arr_eq_str"), 0, 0, 0, 0, 0, 0);
            emit_insn(st, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0)
        } else {
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_MOV_I_R, elem_bytes(arr.of), insn.R_RAX, 64, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_CALL_L, lbl_new("y_arr_eq"), 0, 0, 0, 0, 0, 0);
            emit_insn(st, insn.F_ADD_I_R, 24, insn.R_RSP, 64, 0, 0, 0, 0)
        }
    } else if (t.k == K.tbigint) {
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_CALL_L, lbl_new("y_bigint_cmp"), 0, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_CMP_I_R, 0, insn.R_RAX, 64, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_SETE_R, insn.R_RAX, 8, 0, 0, 0, 0, 0);
        emit_insn(st, insn.F_MOVZBQ_R_R, insn.R_RAX, 8, insn.R_RAX, 64, 0, 0, 0)
    } else if (t.k == K.tstr) {
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_CALL_L, lbl_new("y_str_eq"), 0, 0, 0, 0, 0, 0);
        emit_insn(st, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0)
    } else if (t.k == K.tfloat) {
        // as gen_float_bin's ==: equal, and ordered -- NaN is equal to nothing,
        // itself included, which is what setnp is for
        st = emit_insn(st, insn.F_MOVQ_R_R, insn.R_RAX, 64, insn.R_XMM1, 128, 0, 0, 0);
        st = emit_insn(st, insn.F_POP_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOVQ_R_R, insn.R_RAX, 64, insn.R_XMM0, 128, 0, 0, 0);
        st = emit_insn(st, insn.F_UCOMISD_R_R, insn.R_XMM1, 128, insn.R_XMM0, 128, 0, 0, 0);
        st = emit_insn(st, insn.F_SETE_R, insn.R_RAX, 8, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_SETNP_R, insn.R_RCX, 8, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOVZBQ_R_R, insn.R_RAX, 8, insn.R_RAX, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_MOVZBQ_R_R, insn.R_RCX, 8, insn.R_RCX, 64, 0, 0, 0);
        emit_insn(st, insn.F_AND_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0)
    } else {
        // one word: a scalar by value, a record or map by identity
        st = emit_insn(st, insn.F_POP_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_CMP_R_R, insn.R_RAX, 64, insn.R_RCX, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_SETE_R, insn.R_RAX, 8, 0, 0, 0, 0, 0);
        emit_insn(st, insn.F_MOVZBQ_R_R, insn.R_RAX, 8, insn.R_RAX, 64, 0, 0, 0)
    }
};

// gen_eq_vals for two options of payload type pt: equal when both are
// none, or both are some with equal payloads (a box holds one word).
def gen_eq_opt(st: EmitSt, pt: Type) -> EmitSt {
    let lnone = next_loc(st);
    st = lnone.st;
    let lne = next_loc(st);
    st = lne.st;
    let ldone = next_loc(st);
    st = ldone.st;
    st = emit_insn(st, insn.F_POP_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_TEST_R_R, insn.R_RCX, 64, insn.R_RCX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JZ_L, lnone.label, 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_TEST_R_R, insn.R_RAX, 64, insn.R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JZ_L, lne.label, 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RCX, -1, 1, -1, -1, insn.R_RCX, 64);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RAX, -1, 1, -1, -1, insn.R_RAX, 64);
    st = gen_eq_vals(st, pt);
    st = emit_insn(st, insn.F_JMP_L, ldone.label, 0, 0, 0, 0, 0, 0);
    st = emit_label(st, lnone.label);
    st = emit_insn(st, insn.F_TEST_R_R, insn.R_RAX, 64, insn.R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_SETE_R, insn.R_RAX, 8, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOVZBQ_R_R, insn.R_RAX, 8, insn.R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JMP_L, ldone.label, 0, 0, 0, 0, 0, 0);
    st = emit_label(st, lne.label);
    st = emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
    emit_label(st, ldone.label)
};

// gen_eq_vals for two arrays whose elements (of type et) need their own
// == (eq_elem_loop): same length, then each pair compared as et. The loop
// keeps its state on the stack, since an element compare may call the
// string and array cores: from the top, the index, the right array, the
// left.
def gen_eq_arr_deep(st: EmitSt, et: Type) -> EmitSt {
    let lloop = next_loc(st);
    st = lloop.st;
    let lsame = next_loc(st);
    st = lsame.st;
    let ldiff = next_loc(st);
    st = ldiff.st;
    let lne = next_loc(st);
    st = lne.st;
    let ldone = next_loc(st);
    st = ldone.st;
    st = emit_insn(st, insn.F_POP_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RCX, -1, 1, -1, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RAX, -1, 1, -1, -1, insn.R_RSI, 64);
    st = emit_insn(st, insn.F_CMP_R_R, insn.R_RSI, 64, insn.R_RDX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JNE_L, lne.label, 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_XOR_R_R, insn.R_RDX, 32, insn.R_RDX, 32, 0, 0, 0);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RDX, 64, 0, 0, 0, 0, 0);
    st = emit_label(st, lloop.label);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RSP, -1, 1, -1, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RSP, -1, 1, 16, -1, insn.R_RCX, 64);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RCX, -1, 1, -1, -1, insn.R_RSI, 64);
    st = emit_insn(st, insn.F_CMP_R_R, insn.R_RSI, 64, insn.R_RDX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JGE_L, lsame.label, 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RCX, -1, 1, 16, -1, insn.R_RCX, 64);
    st = emit_insn(st, insn.F_MOV_M_R, insn.R_RCX, insn.R_RDX, 8, 0, -1, insn.R_RCX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RSP, -1, 1, 8, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RAX, -1, 1, 16, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_MOV_M_R, insn.R_RAX, insn.R_RDX, 8, 0, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
    st = gen_eq_vals(st, et);
    st = emit_insn(st, insn.F_TEST_R_R, insn.R_RAX, 64, insn.R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JZ_L, ldiff.label, 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RSP, -1, 1, -1, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_INC_R, insn.R_RDX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_R_0, insn.R_RDX, 64, insn.R_RSP, -1, 1, -1, -1);
    st = emit_insn(st, insn.F_JMP_L, lloop.label, 0, 0, 0, 0, 0, 0);
    st = emit_label(st, lsame.label);
    st = emit_insn(st, insn.F_ADD_I_R, 24, insn.R_RSP, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_I_R, 1, insn.R_RAX, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_JMP_L, ldone.label, 0, 0, 0, 0, 0, 0);
    st = emit_label(st, ldiff.label);
    st = emit_insn(st, insn.F_ADD_I_R, 24, insn.R_RSP, 64, 0, 0, 0, 0);
    st = emit_label(st, lne.label);
    st = emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
    emit_label(st, ldone.label)
};

// Pointer arithmetic emission (types.y is the law). A pointer moves by
// whole elements: `p + n` scales n by the pointee width, and `p - q`
// subtracts the addresses and divides by that width. byte pointers scale by
// one; every other pointee is an 8-byte slot, which is elem_bytes' rule.
def ptr_math_kind(op: str, lt: Type, rt: Type) -> str {
    let lu = unfold(lt);
    let ru = unfold(rt);
    if (op == "+") {
        if (lu.k == K.tptr && (ru.k == K.tlong || ru.k == K.tbyte)) { "ptr_int" }
        else if (ru.k == K.tptr && (lu.k == K.tlong || lu.k == K.tbyte)) { "int_ptr" }
        else { "" }
    } else if (op == "-") {
        if (lu.k == K.tptr && (ru.k == K.tlong || ru.k == K.tbyte)) { "ptr_int" }
        else if (lu.k == K.tptr && ru.k == K.tptr) { "ptr_ptr" }
        else { "" }
    } else { "" }
};

def ptr_elem_width(t: Type) -> long {
    let p: TPtr = unfold(t);
    elem_bytes(p.to)
};

def ptr_scale_rax(st: EmitSt, esz: long) -> EmitSt {
    if (esz == 8) {
        emit_insn(st, insn.F_SHL_I_R, 3, insn.R_RAX, 64, 0, 0, 0, 0)
    } else {
        st
    }
};

def gen_ptr_arith(st: EmitSt, node: Bin, lt: Type, rt: Type) -> EmitSt {
    let op = node.op;
    let kind = ptr_math_kind(op, lt, rt);
    if (kind == "ptr_int") {
        let esz = ptr_elem_width(lt);
        st = gen(st, node.l);
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = gen(st, node.r);
        st = ptr_scale_rax(st, esz);
        st = emit_insn(st, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_RCX, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_POP_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        if (op == "+") {
            emit_insn(st, insn.F_ADD_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0)
        } else {
            emit_insn(st, insn.F_SUB_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0)
        }
    } else if (kind == "int_ptr") {
        let esz = ptr_elem_width(rt);
        st = gen(st, node.l);
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = gen(st, node.r);
        st = emit_insn(st, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_RCX, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_POP_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = ptr_scale_rax(st, esz);
        emit_insn(st, insn.F_ADD_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0)
    } else {
        let esz = ptr_elem_width(lt);
        st = gen(st, node.l);
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = gen(st, node.r);
        st = emit_insn(st, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_RCX, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_POP_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_SUB_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0);
        if (esz == 8) {
            emit_insn(st, insn.F_SAR_I_R, 3, insn.R_RAX, 64, 0, 0, 0, 0)
        } else {
            st
        }
    }
};

def gen_bin_rest(st: EmitSt, node: Bin) -> EmitSt {
    let op = node.op;
    let lt = infer(st, node.l);
    let rt = infer(st, node.r);
    if (op == "+" && (lt.k == K.tstr || rt.k == K.tstr)) {
        gen_cat(st, node, lt, rt)
    } else if (op == "+" && (lt.k == K.tarr || rt.k == K.tarr || lt.k == K.tarrfix || rt.k == K.tarrfix)) {
        // array `+` is the copy-concat form (gen_cat splits off the array
        // case first), not numeric add on the header pointers.
        gen_cat(st, node, lt, rt)
    } else if ((op == "+" || op == "-") && ptr_math_kind(op, lt, rt) != "") {
        gen_ptr_arith(st, node, lt, rt)
    } else if (op == "::") {
        gen_cons(st, node)
    } else if (op in ["<<", ">>", ">>>"]) {
        gen_shift(st, node, op)
    } else if (lt.k == K.tbigint || rt.k == K.tbigint) {
        // + - * / % and every comparison go through the runtime bigint
        // helpers. Mixed long/byte/float operands convert silently.
        gen_bigint_bin(st, node, lt, rt)
    } else if (lt.k == K.tfloat || rt.k == K.tfloat) {
        gen_float_bin(st, node, lt, rt)
    } else if ((op == "==" || op == "!=") && (lt.k == K.tstr || rt.k == K.tstr)) {
        // Not folded on two literals, and not by design: measured over ycc's
        // own output, all 1,291 y_str_eq calls have at least one runtime
        // operand -- 1,209 of them compare a token's text or a ktag() result
        // against a literal, 82 compare two computed strings, and *zero*
        // compare two literals. Across the 442-program corpus 5 programs
        // concatenate two literals and 3 take len("literal"); a constant
        // folder for those shapes would be ~200 instructions of emitter (this
        // file) to save a handful of instructions in eight test fixtures. The
        // tag-name arms of the same shape -- ktag(K.x) == "x" in tags_agree --
        // would need interprocedural knowledge of a const record, and that
        // function is a self-check besides.
        st = gen_push_args(st, [node.l, node.r]);
        st = emit_insn(st, insn.F_CALL_L, lbl_new("y_str_eq"), 0, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0);
        if (op == "!=") {
            emit_insn(st, insn.F_XOR_I_R, 1, insn.R_RAX, 64, 0, 0, 0, 0)
        } else {
            st
        }
    } else if ((op in ["<", ">", "<=", ">="]) && lt.k == K.tstr) {
        // Lexicographic ordering: y_str_cmp returns the SIGN, so the normal
        // signed setcc forms work on its result against 0.
        gen_str_cmp(st, node, op)
    } else if ((op == "==" || op == "!=") && (lt.k == K.tarr || rt.k == K.tarr)) {
        // Arrays compare STRUCTURALLY (length then elements), matching
        // yv.c's yv_eq for Y_ARR — `arr == []` is an emptiness test, not a
        // pointer comparison. String elements compare by value, and
        // elements that are arrays, options or floats by their own ==
        // (gen_eq_vals).
        let elt: Type = normtype({ k: K.tunk });
        if (lt.k == K.tarr) {
            let larr: TOf = lt;
            elt = larr.of;
        }
        if (elt.k == K.tunk) {
            if (rt.k == K.tarr) {
                let rarr: TOf = rt;
                elt = rarr.of;
            }
        }
        if (eq_elem_loop(elt)) {
            st = gen(st, node.l);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = gen(st, node.r);
            st = gen_eq_arr_deep(st, elt);
        } else {
            st = gen_push_args(st, [node.l, node.r]);
            if (elt.k == K.tstr) {
                st = emit_insn(st, insn.F_CALL_L, lbl_new("y_arr_eq_str"), 0, 0, 0, 0, 0, 0);
                st = emit_insn(st, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0);
            } else {
                st = emit_insn(st, insn.F_MOV_I_R, elem_bytes(elt), insn.R_RAX, 64, 0, 0, 0, 0);
                st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
                st = emit_insn(st, insn.F_CALL_L, lbl_new("y_arr_eq"), 0, 0, 0, 0, 0, 0);
                st = emit_insn(st, insn.F_ADD_I_R, 24, insn.R_RSP, 64, 0, 0, 0, 0);
            };
        };
        if (op == "!=") {
            emit_insn(st, insn.F_XOR_I_R, 1, insn.R_RAX, 64, 0, 0, 0, 0)
        } else {
            st
        }
    } else if ((op == "==" || op == "!=") && (lt.k == K.topt || rt.k == K.topt) && !is_none_id(node.l) && !is_none_id(node.r)) {
        // Two options compare their payloads (gen_eq_opt); `x == none`
        // stays the one-word test below.
        let pt: Type = normtype({ k: K.tunk });
        if (lt.k == K.topt) {
            let lopt: TOf = lt;
            pt = lopt.of;
        }
        if (pt.k == K.tunk) {
            if (rt.k == K.topt) {
                let ropt: TOf = rt;
                pt = ropt.of;
            }
        }
        st = gen(st, node.l);
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = gen(st, node.r);
        st = gen_eq_opt(st, pt);
        if (op == "!=") {
            emit_insn(st, insn.F_XOR_I_R, 1, insn.R_RAX, 64, 0, 0, 0, 0)
        } else {
            st
        }
    } else {
        st = gen(st, node.l);
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = gen(st, node.r);
        st = emit_insn(st, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_RCX, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_POP_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        if (op == "+") {
            emit_insn(st, insn.F_ADD_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0)
        } else if (op == "-") {
            emit_insn(st, insn.F_SUB_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0)
        } else if (op == "*") {
            emit_insn(st, insn.F_IMUL_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0)
        } else if (op == "/") {
            // idiv raises #DE on LONG_MIN / -1 (the quotient does not fit), so
            // divisor -1 is handled as a negation instead: neg of LONG_MIN
            // wraps back to LONG_MIN (the language's rule for the whole long
            // range, NATIVE.md), and every other value negates exactly.
            st = emit_insn(st, insn.F_TEST_R_R, insn.R_RCX, 64, insn.R_RCX, 64, 0, 0, 0);
            st = emit_insn(st, insn.F_JZ_L, lbl_new("y_div_zero"), 0, 0, 0, 0, 0, 0);
            let d1 = next_loc(st);
            st = d1.st;
            let d2 = next_loc(st);
            st = d2.st;
            st = emit_insn(st, insn.F_CMP_I_R, -1, insn.R_RCX, 64, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_JNE_L, d1.label, 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_NEG_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_JMP_L, d2.label, 0, 0, 0, 0, 0, 0);
            st = emit_label(st, d1.label);
            st = emit_insn(st, insn.F_CQO, 0, 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_IDIV_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
            emit_label(st, d2.label)
        } else if (op == "%") {
            // Same #DE: x % -1 is 0 for every x (see the `/` note).
            st = emit_insn(st, insn.F_TEST_R_R, insn.R_RCX, 64, insn.R_RCX, 64, 0, 0, 0);
            st = emit_insn(st, insn.F_JZ_L, lbl_new("y_div_zero"), 0, 0, 0, 0, 0, 0);
            let m1 = next_loc(st);
            st = m1.st;
            let m2 = next_loc(st);
            st = m2.st;
            st = emit_insn(st, insn.F_CMP_I_R, -1, insn.R_RCX, 64, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_JNE_L, m1.label, 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
            st = emit_insn(st, insn.F_JMP_L, m2.label, 0, 0, 0, 0, 0, 0);
            st = emit_label(st, m1.label);
            st = emit_insn(st, insn.F_CQO, 0, 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_IDIV_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_MOV_R_R, insn.R_RDX, 64, insn.R_RAX, 64, 0, 0, 0);
            emit_label(st, m2.label)
        } else if (op == "<") {
            st = emit_insn(st, insn.F_CMP_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0);
            st = emit_insn(st, insn.F_SETL_R, insn.R_RAX, 8, 0, 0, 0, 0, 0);
            emit_insn(st, insn.F_MOVZBQ_R_R, insn.R_RAX, 8, insn.R_RAX, 64, 0, 0, 0)
        } else if (op == ">") {
            st = emit_insn(st, insn.F_CMP_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0);
            st = emit_insn(st, insn.F_SETG_R, insn.R_RAX, 8, 0, 0, 0, 0, 0);
            emit_insn(st, insn.F_MOVZBQ_R_R, insn.R_RAX, 8, insn.R_RAX, 64, 0, 0, 0)
        } else if (op == "<=") {
            st = emit_insn(st, insn.F_CMP_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0);
            st = emit_insn(st, insn.F_SETLE_R, insn.R_RAX, 8, 0, 0, 0, 0, 0);
            emit_insn(st, insn.F_MOVZBQ_R_R, insn.R_RAX, 8, insn.R_RAX, 64, 0, 0, 0)
        } else if (op == ">=") {
            st = emit_insn(st, insn.F_CMP_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0);
            st = emit_insn(st, insn.F_SETGE_R, insn.R_RAX, 8, 0, 0, 0, 0, 0);
            emit_insn(st, insn.F_MOVZBQ_R_R, insn.R_RAX, 8, insn.R_RAX, 64, 0, 0, 0)
        } else if (op == "==") {
            st = emit_insn(st, insn.F_CMP_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0);
            st = emit_insn(st, insn.F_SETE_R, insn.R_RAX, 8, 0, 0, 0, 0, 0);
            emit_insn(st, insn.F_MOVZBQ_R_R, insn.R_RAX, 8, insn.R_RAX, 64, 0, 0, 0)
        } else if (op == "!=") {
            st = emit_insn(st, insn.F_CMP_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0);
            st = emit_insn(st, insn.F_SETNE_R, insn.R_RAX, 8, 0, 0, 0, 0, 0);
            emit_insn(st, insn.F_MOVZBQ_R_R, insn.R_RAX, 8, insn.R_RAX, 64, 0, 0, 0)
        } else if (op == "&") {
            emit_insn(st, insn.F_AND_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0)
        } else if (op == "|") {
            emit_insn(st, insn.F_OR_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0)
        } else if (op == "^") {
            emit_insn(st, insn.F_XOR_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0)
        } else {
            st
        }
        // No &&/|| arms here: gen_bin routes those to gen_logic (lazy jumps)
        // BEFORE calling this, so an eager and/or would be dead code.
    }
};

// `x << n`, `x >> n` (arithmetic: the sign fills in) and `x >>> n`
// (logical: zeros fill in). x86 uses only the count's low 6 bits; Y does
// not wrap: a count of 64 or more shifts every bit out (0, or all sign
// bits for `>>`) and a negative count stops the program (y_shift_neg). A
// literal count of 0 to 63 is the instruction's immediate and needs
// neither check.
def gen_shift(st: EmitSt, node: Bin, op: str) -> EmitSt {
    let mn = "shl";
    let fi = insn.F_SHL_I_R;
    let fr = insn.F_SHL_R_R;
    if (op == ">>") { mn = "sar"; fi = insn.F_SAR_I_R; fr = insn.F_SAR_R_R; }
    else if (op == ">>>") { mn = "shr"; fi = insn.F_SHR_I_R; fr = insn.F_SHR_R_R; };
    let n = shift_imm(node.r);
    st = gen(st, node.l);
    if (n >= 0) {
        emit_insn(st, fi, n, insn.R_RAX, 64, 0, 0, 0, 0)
    } else {
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = gen(st, node.r);
        st = emit_insn(st, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_RCX, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_POP_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_TEST_R_R, insn.R_RCX, 64, insn.R_RCX, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_JS_L, lbl_new("y_shift_neg"), 0, 0, 0, 0, 0, 0);
        let ok = next_loc(st);
        st = ok.st;
        st = emit_insn(st, insn.F_CMP_I_R, 64, insn.R_RCX, 64, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_JB_L, ok.label, 0, 0, 0, 0, 0, 0);
        st = mn == "sar" ? emit_insn(st, insn.F_MOV_I_R, 63, insn.R_RCX, 64, 0, 0, 0, 0) : emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
        st = emit_label(st, ok.label);
        emit_insn(st, fr, insn.R_RCX, 8, insn.R_RAX, 64, 0, 0, 0)
    }
};

// The count of a shift when it is a literal from 0 to 63 (gen_shift), else
// -1. A radix literal may wrap negative (0xFFFF_FFFF_FFFF_FFFF is -1).
def shift_imm(r: Node) -> long {
    if (r.k == K.num) {
        let num: Leaf = r;
        if (lit_is_float(num.v)) { -1 } else {
            let s = norm_num(num.v);
            if (len(s) > 2 || s[0:1] == "-") { -1 }
            else if (leading_long(s) < 64) { leading_long(s) }
            else { -1 }
        }
    } else { -1 }
};

// ── calls ──────────────────────────────────────────────────────────────
// Syscall arg registers. SysV: rdi, rsi, rdx, r10, r8, r9. Win64 `syscall`:
// arg1 %r10, arg2 %rdx, arg3 %r8, arg4 %r9, and the FIFTH onward on the
// stack -- FOUR argument registers, not six, and the fifth argument (not the
// sixth or seventh) is the first that needs a slot.  `w_syscall_reg` below
// carries the proof and the two layouts this used to get wrong; read that
// before changing either arm.  That is the whole ABI delta for the `syscall`
// intrinsic: one ladder, the number still in %rax.

def syscall_reg(i: long) -> long {
    if (target_is_windows()) { w_syscall_reg(i) } else { l_syscall_reg(i) }
};

def l_syscall_reg(i: long) -> long {
    if (i == 0) { insn.R_RDI }
    else if (i == 1) { insn.R_RSI }
    else if (i == 2) { insn.R_RDX }
    else if (i == 3) { insn.R_R10 }
    else if (i == 4) { insn.R_R8 }
    else { insn.R_R9 }
};

// The Win64 `syscall` argument registers.  TWO of the values the previous
// revision had here were wrong, and the two wrong ones are the reason a PE
// could not allocate a single byte:
//
//   arg1 %r10   arg2 %rdx   arg3 %r8   arg4 %r9    arg5+ on the stack
//
// It is NOT r10/r9/r8/rdx (that is the Intel manual's syscall ordering for a
// *different* reason and costs a four-way shuffle), and NOT r10/r9/r8/rdx/
// rcx/r11 (which is what this used to say, and which is what the previous
// agent's wine measurements appeared to support).  The proof that it is the
// layout above is that ntdll's own generated stubs -- which is where the
// convention has to be honoured, because ntdll *is* the caller -- need
// exactly ONE instruction to prepare it.  Both a real Windows ntdll and
// ReactOS's build of the same stubs expand to
//
//     mov $number, %eax
//     mov %rcx, %r10
//     syscall
//
// i.e. arg2 in %rdx, arg3 in %r8, arg4 in %r9 are already in place and the
// fifth and later arguments are already in ntdll's own shadow space.  Only
// arg1 has to move, because `syscall` destroys %rcx.  Any other register set
// would require shuffling arguments ntdll has already placed correctly.
//
// So there are FOUR argument registers, not six, and gen_syscall puts the
// fifth and later on the stack itself.
def w_syscall_reg(i: long) -> long {
    if (i == 0) { insn.R_R10 }
    else if (i == 1) { insn.R_RDX }
    else if (i == 2) { insn.R_R8 }
    else { insn.R_R9 }
};

// How many arguments the Windows target passes in registers.  The rest go on
// the stack (gen_syscall).
def w_syscall_regargs() -> long { 4 };

// The same, for `_start`'s tail, which is built straight into the body's IR
// (emit_one_fn) rather than through an EmitSt. The status is 0: the Linux
// side zeroed %edi and the Windows side zeroes %rax before this.
def ir_terminate(body: [long]) -> [long] {
    if (target_is_windows()) {
        body = insn.ir_push(body, insn.F_MOV_I_R, 0 - 1, insn.R_R10, 64, 0, 0, 0, 0);
        body = insn.ir_push(body, insn.F_XOR_R_R, insn.R_RDX, 32, insn.R_RDX, 32, 0, 0, 0);
        body = insn.ir_push(body, insn.F_MOV_I_R, 44, 0, 64, 0, 0, 0, 0);
    } else {
        body = insn.ir_push(body, insn.F_MOV_I_R, 231, 0, 64, 0, 0, 0, 0);
        body = insn.ir_push(body, insn.F_XOR_R_R, insn.R_RDI, 32, insn.R_RDI, 32, 0, 0, 0);
    };
    insn.ir_push(body, insn.F_SYSCALL, 0, 0, 0, 0, 0, 0, 0)
};

// There is deliberately no EmitSt twin of ir_terminate here. `exit` reaches
// the kernel through the arch module's `y_os_exit` (gen_exit), because rt.y
// calls exit() and rt.y is serialized into the std pack, which is written for
// ONE target (see gen_exit's note); and `_start`'s tail, the one other place a
// process ends, builds its instructions straight into the body's IR and so has
// always wanted the IR-shaped ir_terminate. An EmitSt version would have had no
// caller: an earlier draft of this file carried one and it was never reachable.

def gen_push_args(st: EmitSt, args: [Node]) -> EmitSt {
    for i in 0..len(args) {
        st = gen(st, args[i]);
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    };
    st
};

// gen_push_args, with argument i converted (gen_as) to ptypes[i], the
// type of the parameter it binds; arguments past ptypes are pushed as is.
def gen_push_args_as(st: EmitSt, args: [Node], ptypes: [Type]) -> EmitSt {
    for i in 0..len(args) {
        st = i < len(ptypes) ? gen_as(st, args[i], ptypes[i]) : gen(st, args[i]);
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    };
    st
};

// The implicit numeric conversions (types.y tcompat admits them): a long
// or byte stored where a float is declared becomes that float, and a long
// stored where a byte is declared keeps its low 8 bits. The value is in
// %rax with static type `got`; `want` is the declared type of the place it
// goes to. A packed [byte] element store (movb) truncates by itself, so
// those callers ask for no byte conversion.
def gen_conv(st: EmitSt, got: Type, want: Type) -> EmitSt {
    let gk: long = got.k;
    let wk: long = want.k;
    if (gk == wk) {
        st
    } else if (wk == K.tfloat && (gk == K.tlong || gk == K.tbyte)) {
        st = emit_insn(st, insn.F_CVTSI2SD_R_R, insn.R_RAX, 64, insn.R_XMM0, 128, 0, 0, 0);
        emit_insn(st, insn.F_MOVQ_R_R, insn.R_XMM0, 128, insn.R_RAX, 64, 0, 0, 0)
    } else if (wk == K.tbyte && gk == K.tlong) {
        emit_insn(st, insn.F_MOVZBQ_R_R, insn.R_RAX, 8, insn.R_RAX, 64, 0, 0, 0)
    } else if (wk == K.tbigint && gk == K.tfloat) {
        gen_helper1(st, "y_bigint_from_float")
    } else if (wk == K.tbigint) {
        gen_helper1(st, "y_bigint_from_long")
    } else {
        st
    }
};

// gen, then gen_conv to `want`: every place a value is stored under a
// declared type (variable, parameter, return value, element, field,
// pointee) goes through here. A record literal is created as the declared
// record type (gen_reclit). A union value going where one of its members,
// or a union of some of them, is declared is a cast: its tag is checked
// (gen_cast_check), and a value holding another member stops the program.
def gen_as(st: EmitSt, node: Node, want0: Type) -> EmitSt {
    let want = types.unfold(want0);
    let nk: long = node.k;
    let wk: long = want.k;
    if (nk == K.rec && (wk == K.trec || wk == K.tunion)) {
        // want0 as declared: a recursive alias names the descriptor
        let rec: RecLit = node;
        st = gen_reclit(st, rec, want0);
    } else if (wk == K.topt && some_of_lit(node)) {
        // some({...}) where T? is declared: the literal made as T (types.y
        // typeof_want), then boxed
        let call: Call = node;
        let args: [Node] = call.args;
        let wo: TOf = want;
        st = gen_as(st, args[0], wo.of);
        st = gen_box_rax(st);
    } else {
        st = gen(st, node);
    };
    if (wk == K.tfloat || wk == K.tbyte || wk == K.tbigint) {
        gen_conv(st, infer(st, node), want)
    } else if ((wk == K.trec || wk == K.tunion) && nk != K.rec) {
        // a record literal is made in the declared layout (gen_reclit)
        gen_convert(st, infer(st, node), want0, true)
    } else {
        st
    }
};

// node is `some({...})`: a record literal boxed (an optional argument
// passed is one, rename.y).
def some_of_lit(node: Node) -> bool {
    if (node.k != K.call) { false } else {
        let call: Call = node;
        let callee = call.callee;
        let args: [Node] = call.args;
        if (callee.k != K.id || len(args) != 1) { false } else {
            let id: Leaf = callee;
            id.v == "some" && args[0].k == K.rec
        }
    }
};

// Every member of union s is one of t's (t a union): s goes into t as it
// is, with no check.
def union_within(s: Type, t: Type) -> bool {
    let u = types.unfold(t);
    if (u.k != K.tunion) { false }
    else if (types.teq(types.unfold(s), u)) { true }
    else {
        let ss = types.union_parts(types.unfold(s));
        let ok = true;
        let i = 0;
        while (ok && i < len(ss)) {
            if (types.union_member(u, ss[i]).k == K.tnone) { ok = false; };
            i++;
        };
        ok
    }
};

// The members of union s a cast to t keeps: t itself, a record (types.y
// cast_ok lets a union value go where one of its members is written), or
// each member of the union t.
def cast_members(s: Type, t: Type) -> [Type] {
    let out: [Type] = [];
    let ts: [Type] = [];
    let su = types.unfold(s);
    if (types.unfold(t).k == K.tunion) {
        ts = types.union_parts(types.unfold(t));
    } else {
        ts += t;
    };
    ts.foreach((e) => {
        let m = types.union_member(su, e);
        if (m.k != K.tnone) { out += m; };
    });
    out
};

// gen_convert's check of a cast from union u: the record in %rax (kept)
// is one of its members ts, or the program stops (y_cast_trap).
def gen_cast_check(st: EmitSt, ts: [Type], u: Type) -> EmitSt {
    let ok = next_loc(st);
    st = ok.st;
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RAX, -1, 1, -8, -1, insn.R_RCX, 64);
    ts.foreach((e) => {
        let dr = ty_desc_in(st, e, u);
        st = dr.st;
        st = emit_insn(st, insn.F_LEA_P_R, -1, -1, 1, 0, dr.label, insn.R_RDX, 64);
        st = emit_insn(st, insn.F_CMP_R_R, insn.R_RDX, 64, insn.R_RCX, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_JE_L, ok.label, 0, 0, 0, 0, 0, 0);
    });
    st = emit_insn(st, insn.F_JMP_L, lbl_new("y_cast_trap"), 0, 0, 0, 0, 0, 0);
    emit_label(st, ok.label)
};

// The type of the function being emitted: emit_one_fn records it as a
// nameless "fnty" entry (declared parameter types; the return type as
// declared or as the checker inferred it, tnone when it could not --
// see types.y set_inferred_ret). infer_fn_ret's scope has none.
def cur_fn_type(st: EmitSt) -> FuncTy {
    let env = st.env;
    let i = len(env) - 1;
    let ft: FuncTy = { k: K.tfunc, args: [], ret: { k: K.tunk } };
    let looking = true;
    while (looking && i >= 0) {
        let e = env[i];
        if (e.kind == "fnty") {
            let fty: FuncTy = e.typ;
            ft = fty;
            looking = false;
        }
        i = i - 1;
    };
    ft
};

def cur_fn_ret(st: EmitSt) -> Type {
    let ret: Type = cur_fn_type(st).ret;
    ret
};

// Parameter types of a function type (none for anything else).
def fn_args_of(t: Type) -> [Type] {
    let none: [Type] = [];
    if (t.k == K.tfunc) {
        let func: TFunc = t;
        func.args
    } else { none }
};

// Element type of an array type (tnone for anything else).
def arr_elem_type(t: Type) -> Type {
    if (t.k == K.tarr) {
        let arr: TOf = t;
        arr.of
    } else if (t.k == K.tarrfix) {
        let arr: TFix = t;
        arr.of
    } else { normtype({ k: K.tnone }) }
};

// The element type a store converts to: none for a packed [byte] (esz 1),
// whose movb store truncates by itself.
def store_elem_type(t: Type, esz: long) -> Type {
    if (esz == 1) { normtype({ k: K.tnone }) } else { arr_elem_type(t) }
};

// Call a one-argument runtime helper. The argument is in %rax and goes on
// the stack — the Y convention every helper written in Y (std/rt.y) and
// every asm helper shares; the caller cleans up. (Runtime helpers used to
// take it in %rdi, which only hand-written asm could honour.)
// `name` is a runtime helper's fixed name (y_wait_pid): the reserved y_
// prefix means it is the same name every time, so it is interned rather than
// minted (there is nothing to identify).
def gen_helper1(st: EmitSt, name: str) -> EmitSt {
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new(name), 0, 0, 0, 0, 0, 0);
    emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0)
};

def gen_call(st: EmitSt, node: Call) -> EmitSt {
    let callee: Node = node.callee;
    if (callee.k != K.id) {
        if (callee.k == K.dot) {
            let dot: Dot = callee;
            let rt = infer(st, dot.obj);
            if (rt.k == K.tstr) {
                gen_method(st, node)
            } else if (rt.k == K.tarr || rt.k == K.tarrfix) {
                gen_arr_method(st, node)
            } else {
                // Calling the result of an expression (e.g. `fs[0](x)`): it is a
                // closure value, so go through its code pointer.
                gen_indirect(st, node, callee)
            }
        } else {
            // Calling the result of an expression (e.g. `fs[0](x)`): it is a
            // closure value, so go through its code pointer.
            gen_indirect(st, node, callee)
        }
    } else {
        let id: Leaf = callee;
        let name = id.v;
        if (name == "print") {
            gen_print(st, node)
        } else if (name == "syscall") {
            gen_syscall(st, node)
        } else if (name == "len") {
            gen_len(st, node)
        } else if (name == "range") {
            gen_range(st, node)
        } else if (name == "push") {
            gen_push(st, node)
        } else if (name == "push$all") {
            gen_push_all(st, node)
        } else if (name == "some") {
            gen_some(st, node)
        } else if (name == "is_some") {
            gen_is_some(st, node)
        } else if (name == "opt$test") {
            // `x is there` -- the test of a `?.` chain (parser.y)
            gen_is_some(st, node)
        } else if (name == "opt$val") {
            gen_opt_val(st, node)
        } else if (name == "unwrap") {
            gen_unwrap(st, node)
        } else if (name == "trim") {
            gen_trim(st, node)
        } else if (name == "prepend") {
            gen_prepend(st, node)
        } else if (name == "mod") {
            gen_mod(st, node)
        } else if (name == "byte_at") {
            gen_byte_at(st, node)
        } else if (name == "ord") {
            gen_ord(st, node)
        } else if (name == "chr") {
            gen_chr(st, node)
        } else if (name == "tolong") {
            gen_tolong(st, node)
        } else if (name == "tofloat") {
            gen_tofloat(st, node)
        } else if (name == "tostring") {
            gen_tostring(st, node)
        } else if (name == "#fmt") {
            gen_fmt(st, node)
        } else if (name == "typeof") {
            gen_typeof(st, node)
        } else if (name == "index_of") {
            gen_index_of(st, node, false)
        } else if (name == "last_index_of") {
            gen_index_of(st, node, true)
        } else if (name == "join" && len(node.args) == 1) {
            // join t: t is a thread's function; calling it waits
            let ja: [Node] = node.args;
            let jc: Call = { k: K.call, callee: ja[0], args: [], line: node.line, col: node.col };
            gen_indirect(st, jc, ja[0])
        } else if (name == "spawn" || name == "fork") {
            let sa: [Node] = node.args;
            st = gen(st, sa[0]);
            emit_insn(st, insn.F_CALL_L, lbl_new("y_" + name), 0, 0, 0, 0, 0, 0)
        } else if (name == "jmp_at") {
            // jmp_at(addr): `jmp *%rax`, so the stack is exactly as it was --
            // which is what a process entry point needs, since it reads argc
            // from [rsp] (see meta.y run_image).
            let ja: [Node] = node.args;
            st = gen(st, ja[0]);
            emit_insn(st, insn.F_JMP_IND, insn.R_RAX, 64, 0, 0, 0, 0, 0)
        } else if (name == "wait_pid") {
            let wa: [Node] = node.args;
            st = gen(st, wa[0]);
            gen_helper1(st, "y_wait_pid")
        } else if (name == "post" || name == "wait") {
            let pa: [Node] = node.args;
            st = gen(st, pa[0]);
            emit_insn(st, insn.F_CALL_L, lbl_new("y_sem_" + name), 0, 0, 0, 0, 0, 0)
        } else if (name == "mutex" || name == "sem") {
            gen_sync_new(st, node)
        } else if (name == "lock" || name == "try_lock") {
            gen_lock(st, node, name == "try_lock")
        } else if (name == "join") {
            gen_join(st, node)
        } else if (name == "split") {
            gen_split(st, node)
        } else if (name == "puts") {
            gen_puts(st, node)
        } else if (name == "eputs") {
            gen_eputs(st, node)
        } else if (name == "clock_us") {
            gen_clock_us(st, node)
        } else if (name == "time_us") {
            emit_insn(st, insn.F_CALL_L, lbl_new("y_time_us"), 0, 0, 0, 0, 0, 0)
        } else if (name == "keys") {
            // a copy of the map's keys array (gen_maplit's {keys, vals, boxes})
            let kargs: [Node] = node.args;
            let ln = node.line;
            let cl = node.col;
            let whole: Slice = { k: K.slice, arr: n_dot(kargs[0], "keys", ln, cl), lo: { k: K.void, line: ln, col: cl }, hi: { k: K.void, line: ln, col: cl }, line: ln, col: cl };
            gen_slice(st, whole)
        } else if (name == "sleep") {
            gen_sleep(st, node)
        } else if (name == "heap_used") {
            gen_heap_used(st, node)
        } else if (name == "exit") {
            gen_exit(st, node)
        } else if (name == "argv") {
            gen_argv(st, node)
        } else if (name == "bytes") {
            let args: [Node] = node.args;
            st = gen_push_args(st, args);
            st = emit_insn(st, insn.F_CALL_L, lbl_new("y_str_to_bytes"), 0, 0, 0, 0, 0, 0);
            emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0)
        } else if (name == "from_bytes") {
            let args: [Node] = node.args;
            st = gen_push_args(st, args);
            st = emit_insn(st, insn.F_CALL_L, lbl_new("y_bytes_to_str"), 0, 0, 0, 0, 0, 0);
            emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0)
        } else if (name == "ptr_addr") {
            // A pointer IS its numeric value at run time: nothing to emit
            // beyond evaluating the operand. This exists only so the type
            // system lets the value cross into long territory.
            let paargs: [Node] = node.args;
            gen(st, paargs[0])
        } else if (name == "os_call") {
            // os_call("y_os_write", fd, s, len(s)) -> the block's own return
            // value. The NAME is a literal the checker already matched against
            // os_call_names (types.y), so it is emitted as a plain `call` to a
            // label: the same instruction on every target, which is what makes
            // the four embedded std units target-independent even though they
            // are compiled once and serialized into one pack.
            //
            // The arguments go on the stack left to right, so inside the block
            // the LAST one pushed is the FIRST parameter and sits lowest, just
            // above the return address -- the same rbp+16+8*(n-1-k) layout every
            // Y function uses, and what every y_os_* block reads (see
            // prelude.s's y_os_write). The caller pops, like every other call in
            // the emitter.
            //
            // A `str` argument flows in as its header and the block wants the
            // data bytes, so +8 first -- the same adjustment syscall's
            // arguments get.
            let oa: [Node] = node.args;
            let n = len(oa) - 1;
            for k in 1..n + 1 {
                st = gen(st, oa[k]);
                if ((infer(st, oa[k])).k == K.tstr) {
                    st = emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RAX, 64, 0, 0, 0, 0);
                };
                st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            };
            // The name is a str literal: the checker required one (a variable
            // holding a name would put the choice back in the program's hands,
            // and the arch module's list is the whole point of naming it).
            let onm: Leaf = oa[0];
            st = emit_insn(st, insn.F_CALL_L, lbl_new(onm.v), 0, 0, 0, 0, 0, 0);
            emit_insn(st, insn.F_ADD_I_R, 8 * n, insn.R_RSP, 64, 0, 0, 0, 0)
        } else { gen_direct(st, node, name) }

    }
};

// `s.m(args)` with s a str (the checker validated it against
// types.str_method): the receiver becomes the first argument (the last
// for `sep.join(xs)`), a left-out optional argument its default, and
// the call goes to the builtin's own lowering, or straight to the
// std/str.y helper by label -- a Y function like any other, so the
// arguments are pushed and the caller pops them.
// ── array methods ────────────────────────────────────────────────────────
// The checker types `arr.m(...)` in types.y; here each method is emitted
// inline. Element width comes from the receiver's static type, so packed
// [byte] and word-per-element arrays share one body per method.
// The body label of a literal closure the caller may call directly: it
// captures nothing, so the callee never reads the closure record and the
// call needs no indirect load (same stack layout, minus the pushed record).
// -1 when the callee must go through the record.
def arr_direct_label(st: EmitSt, fnode: Node) -> long {
    if (fnode.k != K.func) {
        -1
    } else {
        let f: Func = fnode;
        if (len(fn_captures(f, st.fns.ix, "")) > 0) { -1 } else { lit_label }
    }
};

// The per-element call for an array method: the body inlined when the literal
// allows it (arr_can_inline), a direct call when it captures nothing, and the
// closure record otherwise.
def gen_arr_call(st: EmitSt, foff: long, arg_regs: [long], direct: long, fnode: Node, inl: bool) -> EmitSt {
    if (inl) {
        gen_lambda_inline(st, fnode, arg_regs)
    } else if (direct < 0) {
        gen_closure_call(st, foff, arg_regs)
    } else {
        arg_regs.foreach((e) => {
            st = emit_insn(st, insn.F_PUSH_R, e, 64, 0, 0, 0, 0, 0);
        });
        st = emit_insn(st, insn.F_CALL_L, direct, 0, 0, 0, 0, 0, 0);
        emit_insn(st, insn.F_ADD_I_R, 8 * len(arg_regs), insn.R_RSP, 64, 0, 0, 0, 0)
    }
};

// Whether a literal closure's body can be emitted INSIDE the loop. It must not
// need anything a separate frame gives it: no captures, no `self`, no nested
// function literal, and no append to one of its own parameters (those move
// into an own copy at a function boundary, see bind_own).
def arr_can_inline(st: EmitSt, fnode: Node) -> bool {
    if (fnode.k != K.func) {
        false
    } else {
        let f: Func = fnode;
        if (name_in(fv_ids(f.body, []), "self")) { false }
        else if (len(box_names(f)) > 0) { false }
        else if (param_appended(f.params, app_names(f.body, false, []))) { false }
        else { true }
    }
};

// Captures of a literal that will be inlined: box each enclosing binding (the
// shared cell every closure sees, see box_capture). The record itself is built
// at the inline point, where the live temporaries have been promoted to block
// slots -- building it here would hand out slots in the temporaries' range,
// which is exactly the collision gen_lambda_inline's promotion exists to
// avoid.
def arr_box_caps(st: EmitSt, fnode: Node) -> EmitSt {
    let f: Func = fnode;
    let caps = fn_captures(f, st.fns.ix, "");
    caps.foreach((e) => {
        let cn: str = e;
        st = box_capture(st, cn);
    });
    st
};

def st_env(st: EmitSt, e: [Slot]) -> EmitSt {
    { ir: st.ir, txt: st.txt, rodata: st.rodata, uid: st.uid, fuid: st.fuid,
        loc: st.loc, env: e, slots: st.slots, temp: st.temp,
        self_label: st.self_label, end_label: st.end_label, fns: st.fns,
        bodies: st.bodies, btext: st.btext, blabels: st.blabels }
};

def param_appended(ps: [str], ap: [str]) -> bool {
    let out = false;
    ps.foreach((e) => {
        if (name_in(ap, e)) { out = true; };
    });
    out
};

// `return` inside an inlined body lands on this state's end_label.
def st_end_label(st: EmitSt, l: long) -> EmitSt {
    { ir: st.ir, txt: st.txt, rodata: st.rodata, uid: st.uid, fuid: st.fuid,
        loc: st.loc, env: st.env, slots: st.slots, temp: st.temp,
        self_label: st.self_label, end_label: l, fns: st.fns,
        bodies: st.bodies, btext: st.btext, blabels: st.blabels }
};

// Emit a literal closure's body inside the caller's loop, its parameters bound
// to the values the loop has in arg_regs. This is what makes
// `a.foreach((x) => ...)` cost what the raw loop costs: no record, no separate
// body, no call/ret and no frame per element. The body's value ends in %rax,
// exactly like the call it replaces.
def gen_lambda_inline(st: EmitSt, fnode: Node, arg_regs: [long]) -> EmitSt {
    let f: Func = fnode;
    let save_slots = st.slots;
    let save_temp = st.temp;
    let save_end = st.end_label;
    // The caller's live temporaries (the method's own slots) become block
    // slots first: the body's statements declare locals -- a compound
    // assignment's synthetic `let`, for one -- and those are allocated from
    // st.slots, which would otherwise land on top of them.
    st = st_slots(st, st.slots + st.temp);
    st = st_temp(st, 0);
    // The parameters first: the record below clobbers %rax/%rcx, which is
    // where the loop has the element and the index.
    let n = len(f.params);
    if (n > len(arg_regs)) { n = len(arg_regs); };
    let base = st.slots;
    st = st_slots(st, base + n);
    let rl = next_loc(st);
    st = rl.st;
    for i in 0..n {
        let off = (base + 1 + i) * -8;
        st = emit_insn(st, insn.F_MOV_R_D, arg_regs[i], 64, insn.R_RBP, -1, 1, off, -1);
        st = env_define(st, f.params[i], "param", off, -1, "", f.ptypes[i]);
    };
    // The stack closure record the captures read through: word j+1 is capture
    // j's cell pointer (word 0 is the code pointer, which an inlined body never
    // reads, so it is only reserved). Rebuilt each iteration, so a capture
    // whose cell was refreshed -- a loop variable -- is picked up.
    let caps = fn_captures(f, st.fns.ix, "");
    let m = len(caps);
    let origs: [Slot] = [];
    if (m > 0) {
        let rbase = st.slots;
        let rptr = (rbase + m + 1) * -8;
        let rsoff = (rbase + m + 2) * -8;
        st = st_slots(st, rbase + m + 2);
        st = emit_insn(st, insn.F_LEA_D_R, insn.R_RBP, -1, 1, rptr, -1, insn.R_RAX, 64);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, rsoff, -1);
        let ci = 0;
        while (ci < m) {
            st = gen_cap_ptr(st, caps[ci]);
            st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, rptr + 8 * (ci + 1), -1);
            ci++;
        };
        // The enclosing bindings, so they can be put back after the body:
        // env_define APPENDS to the env array in place (arrays are
        // references), so saving and restoring the array itself would restore
        // the capture entries too and let every later read of the name go
        // through a record that no longer exists.
        let cj = 0;
        while (cj < m) {
            let cn: str = caps[cj];
            let oe = env_find(st, cn);
            origs += oe;
            st = env_define(st, cn, "capture", rsoff, -1, tostring(cj), oe.typ);
            cj++;
        };
    };
    st = st_end_label(st, rl.label);
    st = gen_block(st, f.body);
    st = emit_label(st, rl.label);
    // Put the enclosing bindings back: env_define APPENDS to the env array in
    // place (arrays are references), so a saved copy of the array would carry
    // the capture entries with it, and every later read of the name would go
    // through a record that is gone by then.
    let ck = 0;
    while (ck < m) {
        let cn: str = caps[ck];
        let oe: Slot = origs[ck];
        st = env_define(st, cn, oe.kind, oe.off, oe.label, oe.mark, oe.typ);
        ck++;
    };
    st = st_end_label(st, save_end);
    st = st_slots(st, save_slots);
    st_temp(st, save_temp)
};

def gen_closure_call(st: EmitSt, foff: long, arg_regs: [long]) -> EmitSt {
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, foff, -1, insn.R_R10, 64);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_R10, 64, 0, 0, 0, 0, 0);
    arg_regs.foreach((e) => {
        st = emit_insn(st, insn.F_PUSH_R, e, 64, 0, 0, 0, 0, 0);
    });
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, foff, -1, insn.R_R10, 64);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_R10, -1, 1, -1, -1, insn.R_R10, 64);
    st = emit_insn(st, insn.F_CALL_IND, insn.R_R10, 64, 0, 0, 0, 0, 0);
    emit_insn(st, insn.F_ADD_I_R, 8 * (len(arg_regs) + 1), insn.R_RSP, 64, 0, 0, 0, 0)
};

def gen_arr_new_empty(st: EmitSt) -> EmitSt {
    st = emit_insn(st, insn.F_MOV_I_R, 32, insn.R_RDI, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_alloc"), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_XOR_R_R, insn.R_RCX, 32, insn.R_RCX, 32, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RCX, 64, insn.R_RAX, -1, 1, 0, -1);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RCX, 64, insn.R_RAX, -1, 1, 8, -1);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RCX, 64, insn.R_RAX, -1, 1, 16, -1);
    emit_insn(st, insn.F_MOV_R_D, insn.R_RCX, 64, insn.R_RAX, -1, 1, 24, -1)
};

// Append the value in %rax to the array whose header is in slot `roff`.
def gen_arr_push_slot(st: EmitSt, roff: long, esz: long) -> EmitSt {
    st = emit_insn(st, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_RDX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, roff, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RDX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_I_R, esz, insn.R_RAX, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_arr_push"), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_ADD_I_R, 24, insn.R_RSP, 64, 0, 0, 0, 0);
    emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, roff, -1)
};

def gen_mul_esz(st: EmitSt, reg: long, esz: long) -> EmitSt {
    if (esz == 8) {
        emit_insn(st, insn.F_SHL_I_R, 3, reg, 64, 0, 0, 0, 0)
    } else {
        st
    }
};

def gen_arr_pop_shift(st: EmitSt, node: Call, shift: bool) -> EmitSt {
    let dot: Dot = node.callee;
    let esz = arr_elem_bytes((infer(st, dot.obj)));
    let save = st.temp;
    let aoff = (st.slots + st.temp + 1) * -8;
    let voff = (st.slots + st.temp + 2) * -8;
    st = st_temp(st, st.temp + 2);
    st = gen(st, dot.obj);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, aoff, -1);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, aoff, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RDX, -1, 1, 0, -1, insn.R_RCX, 64);
    st = emit_insn(st, insn.F_TEST_R_R, insn.R_RCX, 64, insn.R_RCX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JZ_L, lbl_new("y_oob"), 0, 0, 0, 0, 0, 0);
    if (shift) {
        st = emit_insn(st, insn.F_XOR_R_R, insn.R_R8, 32, insn.R_R8, 32, 0, 0, 0);
        st = elem_load(st, esz, insn.R_RDX, insn.R_R8, insn.R_RAX);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, voff, -1);
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, aoff, -1, insn.R_RDX, 64);
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RDX, -1, 1, 16, -1, insn.R_RDI, 64);
        st = emit_insn(st, insn.F_MOV_R_R, insn.R_RDI, 64, insn.R_RSI, 64, 0, 0, 0);
        st = esz == 1 ? emit_insn(st, insn.F_ADD_I_R, 1, insn.R_RSI, 64, 0, 0, 0, 0) : emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSI, 64, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_0_R, insn.R_RDX, -1, 1, 0, -1, insn.R_RCX, 64);
        st = emit_insn(st, insn.F_DEC_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
        st = gen_mul_esz(st, insn.R_RCX, esz);
        st = emit_insn(st, insn.F_CALL_L, lbl_new("y_mem_copy"), 0, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, aoff, -1, insn.R_RDX, 64);
        st = emit_insn(st, insn.F_MOV_0_R, insn.R_RDX, -1, 1, 0, -1, insn.R_RCX, 64);
        st = emit_insn(st, insn.F_DEC_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RCX, 64, insn.R_RDX, -1, 1, 0, -1);
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, voff, -1, insn.R_RAX, 64);
    } else {
        st = emit_insn(st, insn.F_DEC_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RCX, 64, insn.R_RDX, -1, 1, 0, -1);
        st = elem_load(st, esz, insn.R_RDX, insn.R_RCX, insn.R_RAX);
    };
    st_temp(st, save)
};

def gen_arr_remove(st: EmitSt, node: Call) -> EmitSt {
    let dot: Dot = node.callee;
    let esz = arr_elem_bytes((infer(st, dot.obj)));
    let args: [Node] = node.args;
    let save = st.temp;
    let aoff = (st.slots + st.temp + 1) * -8;
    let ioff = (st.slots + st.temp + 2) * -8;
    let coff = (st.slots + st.temp + 3) * -8;
    let voff = (st.slots + st.temp + 4) * -8;
    let roff = (st.slots + st.temp + 5) * -8;
    st = st_temp(st, st.temp + 5);
    st = gen(st, dot.obj);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, aoff, -1);
    st = gen(st, args[0]);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, ioff, -1);
    if (len(args) == 2) {
        st = gen(st, args[1]);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, coff, -1);
        // roff = y_arr_slice(arr, idx, idx + count, esz)
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, aoff, -1, insn.R_RAX, 64);
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, ioff, -1, insn.R_RAX, 64);
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, ioff, -1, insn.R_RAX, 64);
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, coff, -1, insn.R_RCX, 64);
        st = emit_insn(st, insn.F_ADD_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_I_R, esz, insn.R_RAX, 64, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_CALL_L, lbl_new("y_arr_slice"), 0, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_ADD_I_R, 32, insn.R_RSP, 64, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, roff, -1);
    } else {
        // single: value first
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, aoff, -1, insn.R_RDX, 64);
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, ioff, -1, insn.R_RCX, 64);
        st = elem_load(st, esz, insn.R_RDX, insn.R_RCX, insn.R_RAX);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, voff, -1);
        st = emit_insn(st, insn.F_MOV_I_R, 1, insn.R_RAX, 64, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, coff, -1);
    };
    // Move the tail left by count elements.
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, aoff, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RDX, -1, 1, 16, -1, insn.R_RDI, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, ioff, -1, insn.R_RAX, 64);
    st = gen_mul_esz(st, insn.R_RAX, esz);
    st = emit_insn(st, insn.F_ADD_R_R, insn.R_RAX, 64, insn.R_RDI, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, aoff, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RDX, -1, 1, 16, -1, insn.R_RSI, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, ioff, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, coff, -1, insn.R_RCX, 64);
    st = emit_insn(st, insn.F_ADD_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0);
    st = gen_mul_esz(st, insn.R_RAX, esz);
    st = emit_insn(st, insn.F_ADD_R_R, insn.R_RAX, 64, insn.R_RSI, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, aoff, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RDX, -1, 1, 0, -1, insn.R_RCX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, ioff, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_SUB_R_R, insn.R_RAX, 64, insn.R_RCX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, coff, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_SUB_R_R, insn.R_RAX, 64, insn.R_RCX, 64, 0, 0, 0);
    st = gen_mul_esz(st, insn.R_RCX, esz);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_mem_copy"), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, aoff, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RDX, -1, 1, 0, -1, insn.R_RCX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, coff, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_SUB_R_R, insn.R_RAX, 64, insn.R_RCX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RCX, 64, insn.R_RDX, -1, 1, 0, -1);
    st = len(args) == 2 ? emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, roff, -1, insn.R_RAX, 64) : emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, voff, -1, insn.R_RAX, 64);
    st_temp(st, save)
};

def gen_arr_push_method(st: EmitSt, node: Call, prepend: bool) -> EmitSt {
    let dot: Dot = node.callee;
    let esz = arr_elem_bytes((infer(st, dot.obj)));
    let args: [Node] = node.args;
    st = gen(st, dot.obj);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen(st, args[0]);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_I_R, esz, insn.R_RAX, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = prepend ? emit_insn(st, insn.F_CALL_L, lbl_new("y_arr_prepend"), 0, 0, 0, 0, 0, 0) : emit_insn(st, insn.F_CALL_L, lbl_new("y_arr_push"), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_ADD_I_R, 24, insn.R_RSP, 64, 0, 0, 0, 0);
    emit_insn(st, insn.F_MOV_0_R, insn.R_RAX, -1, 1, 0, -1, insn.R_RAX, 64)
};

def arr_closure_nargs(st: EmitSt, fnode: Node) -> long {
    let ft = infer(st, fnode);
    if (ft.k == K.tfunc) { let f: TFunc = ft; len(f.args) } else { 0 }
};

def arr_closure_ret(st: EmitSt, fnode: Node) -> Type {
    let ft = infer(st, fnode);
    if (ft.k == K.tfunc) { let f: TFunc = ft; f.ret } else { t_unk() }
};

def gen_arr_loop_head(st: EmitSt, at: Type, aoff: long, ioff: long, done: long) -> EmitSt {
    let esz = arr_elem_bytes(at);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, aoff, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RDX, -1, 1, 0, -1, insn.R_RCX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, ioff, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_CMP_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JGE_L, done, 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, aoff, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, ioff, -1, insn.R_RCX, 64);
    elem_load(st, esz, insn.R_RDX, insn.R_RCX, insn.R_RAX)
};

def gen_arr_sort(st: EmitSt, node: Call, sorted: bool) -> EmitSt {
    let dot: Dot = node.callee;
    let esz = arr_elem_bytes((infer(st, dot.obj)));
    let args: [Node] = node.args;
    let save = st.temp;
    let aoff = (st.slots + st.temp + 1) * -8;
    let foff = (st.slots + st.temp + 2) * -8;
    let ioff = (st.slots + st.temp + 3) * -8;
    let joff = (st.slots + st.temp + 4) * -8;
    let koff = (st.slots + st.temp + 5) * -8;
    let ajoff = (st.slots + st.temp + 6) * -8;
    st = st_temp(st, st.temp + 6);
    st = gen(st, dot.obj);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, aoff, -1);
    if (sorted) {
        // New array = y_arr_slice(old, 0, len(old), esz)
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, aoff, -1, insn.R_RAX, 64);
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, aoff, -1, insn.R_RDX, 64);
        st = emit_insn(st, insn.F_MOV_0_R, insn.R_RDX, -1, 1, 0, -1, insn.R_RAX, 64);
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_I_R, esz, insn.R_RAX, 64, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_CALL_L, lbl_new("y_arr_slice"), 0, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_ADD_I_R, 32, insn.R_RSP, 64, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, aoff, -1);
    };
    let inl = arr_can_inline(st, args[0]);
    let adir = 0 - 1;
    if (inl) {
        st = arr_box_caps(st, args[0]);
    } else {
        st = gen(st, args[0]);
        adir = arr_direct_label(st, args[0]);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, foff, -1);
    };
    st = emit_insn(st, insn.F_MOV_I_R, 1, insn.R_RAX, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, ioff, -1);
    let loop_i = next_loc(st);
    st = loop_i.st;
    let done = next_loc(st);
    st = done.st;
    let loop_j = next_loc(st);
    st = loop_j.st;
    let shift_done = next_loc(st);
    st = shift_done.st;
    st = emit_label(st, loop_i.label);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, aoff, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RDX, -1, 1, 0, -1, insn.R_RCX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, ioff, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_CMP_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JGE_L, done.label, 0, 0, 0, 0, 0, 0);
    // key = a[i]
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, aoff, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, ioff, -1, insn.R_RCX, 64);
    st = elem_load(st, esz, insn.R_RAX, insn.R_RCX, insn.R_RDX);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RDX, 64, insn.R_RBP, -1, 1, koff, -1);
    // j = i - 1
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, ioff, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_SUB_I_R, 1, insn.R_RAX, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, joff, -1);
    st = emit_label(st, loop_j.label);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, joff, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_TEST_R_R, insn.R_RAX, 64, insn.R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JS_L, shift_done.label, 0, 0, 0, 0, 0, 0);
    // a_j = a[j]
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, aoff, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, joff, -1, insn.R_RCX, 64);
    st = elem_load(st, esz, insn.R_RAX, insn.R_RCX, insn.R_RDX);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RDX, 64, insn.R_RBP, -1, 1, ajoff, -1);
    // cmp(a_j, key)
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, ajoff, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, koff, -1, insn.R_RCX, 64);
    let regs: [long] = [];
    regs += insn.R_RAX;
    regs += insn.R_RCX;
    st = gen_arr_call(st, foff, regs, adir, args[0], inl);
    st = emit_insn(st, insn.F_CMP_I_R, 0, insn.R_RAX, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_JLE_L, shift_done.label, 0, 0, 0, 0, 0, 0);
    // a[j+1] = a_j
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, aoff, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, joff, -1, insn.R_RCX, 64);
    st = emit_insn(st, insn.F_ADD_I_R, 1, insn.R_RCX, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, ajoff, -1, insn.R_RDX, 64);
    st = elem_store_rdx(st, esz, insn.R_RAX, insn.R_RCX);
    st = emit_insn(st, insn.F_DEC_D, insn.R_RBP, -1, 1, joff, -1, 0, 0);
    st = emit_insn(st, insn.F_JMP_L, loop_j.label, 0, 0, 0, 0, 0, 0);
    st = emit_label(st, shift_done.label);
    // a[j+1] = key
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, aoff, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, joff, -1, insn.R_RCX, 64);
    st = emit_insn(st, insn.F_ADD_I_R, 1, insn.R_RCX, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, koff, -1, insn.R_RDX, 64);
    st = elem_store_rdx(st, esz, insn.R_RAX, insn.R_RCX);
    st = emit_insn(st, insn.F_INC_D, insn.R_RBP, -1, 1, ioff, -1, 0, 0);
    st = emit_insn(st, insn.F_JMP_L, loop_i.label, 0, 0, 0, 0, 0, 0);
    st = emit_label(st, done.label);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, aoff, -1, insn.R_RAX, 64);
    st_temp(st, save)
};

def gen_arr_iter_method(st: EmitSt, node: Call, key: str, at: Type) -> EmitSt {
    let dot: Dot = node.callee;
    let esz = arr_elem_bytes(at);
    let args: [Node] = node.args;
    if (key == "sort" || key == "sorted") {
        gen_arr_sort(st, node, key == "sorted")
    } else if (key == "flat") {
        let inneresz = elem_bytes(arr_elem_of(at));
        let save = st.temp;
        let aoff = (st.slots + st.temp + 1) * -8;
        let ioff = (st.slots + st.temp + 2) * -8;
        let roff = (st.slots + st.temp + 3) * -8;
        let nioff = (st.slots + st.temp + 4) * -8;
        st = st_temp(st, st.temp + 4);
        st = gen(st, dot.obj);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, aoff, -1);
        st = gen_arr_new_empty(st);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, roff, -1);
        st = emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, ioff, -1);
        let loop = next_loc(st);
        st = loop.st;
        let done = next_loc(st);
        st = done.st;
        st = emit_label(st, loop.label);
        st = gen_arr_loop_head(st, at, aoff, ioff, done.label);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, nioff, -1);
        // y_arr_extend(res, inner, inneresz)
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, roff, -1, insn.R_RAX, 64);
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, nioff, -1, insn.R_RAX, 64);
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_I_R, inneresz, insn.R_RAX, 64, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_CALL_L, lbl_new("y_arr_extend"), 0, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_ADD_I_R, 24, insn.R_RSP, 64, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, roff, -1);
        st = emit_insn(st, insn.F_INC_D, insn.R_RBP, -1, 1, ioff, -1, 0, 0);
        st = emit_insn(st, insn.F_JMP_L, loop.label, 0, 0, 0, 0, 0, 0);
        st = emit_label(st, done.label);
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, roff, -1, insn.R_RAX, 64);
        st_temp(st, save)
    } else if (key == "map" || key == "filter") {
        let fnode = args[0];
        let nargs = arr_closure_nargs(st, fnode);
        let resesz = elem_bytes((arr_closure_ret(st, fnode)));
        let save = st.temp;
        let aoff = (st.slots + st.temp + 1) * -8;
        let foff = (st.slots + st.temp + 2) * -8;
        let ioff = (st.slots + st.temp + 3) * -8;
        let roff = (st.slots + st.temp + 4) * -8;
        let eoff = (st.slots + st.temp + 5) * -8;
        st = st_temp(st, st.temp + 5);
        st = gen(st, dot.obj);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, aoff, -1);
        let inl = arr_can_inline(st, fnode);
        let adir = 0 - 1;
        if (inl) {
            st = arr_box_caps(st, fnode);
        } else {
            st = gen(st, fnode);
            adir = arr_direct_label(st, fnode);
            st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, foff, -1);
        };
        st = gen_arr_new_empty(st);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, roff, -1);
        st = emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, ioff, -1);
        let loop = next_loc(st);
        st = loop.st;
        let done = next_loc(st);
        st = done.st;
        let skip = next_loc(st);
        st = skip.st;
        st = emit_label(st, loop.label);
        st = gen_arr_loop_head(st, at, aoff, ioff, done.label);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, eoff, -1);
        let regs: [long] = [];
        if (nargs >= 1) { regs += insn.R_RAX; };
        if (nargs >= 2) { regs += insn.R_RCX; };
        st = gen_arr_call(st, foff, regs, adir, fnode, inl);
        if (key == "map") {
            st = gen_arr_push_slot(st, roff, resesz);
        } else {
            st = emit_insn(st, insn.F_TEST_R_R, insn.R_RAX, 64, insn.R_RAX, 64, 0, 0, 0);
            st = emit_insn(st, insn.F_JZ_L, skip.label, 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, eoff, -1, insn.R_RAX, 64);
            st = gen_arr_push_slot(st, roff, esz);
            st = emit_label(st, skip.label);
        };
        st = emit_insn(st, insn.F_INC_D, insn.R_RBP, -1, 1, ioff, -1, 0, 0);
        st = emit_insn(st, insn.F_JMP_L, loop.label, 0, 0, 0, 0, 0, 0);
        st = emit_label(st, done.label);
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, roff, -1, insn.R_RAX, 64);
        st_temp(st, save)
    } else if (key in ["foreach", "all", "some", "find"]) {
        let fnode = args[0];
        let nargs = arr_closure_nargs(st, fnode);
        let save = st.temp;
        let aoff = (st.slots + st.temp + 1) * -8;
        let foff = (st.slots + st.temp + 2) * -8;
        let ioff = (st.slots + st.temp + 3) * -8;
        let eoff = (st.slots + st.temp + 4) * -8;
        st = st_temp(st, st.temp + 4);
        st = gen(st, dot.obj);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, aoff, -1);
        let inl = arr_can_inline(st, fnode);
        let adir = 0 - 1;
        if (inl) {
            st = arr_box_caps(st, fnode);
        } else {
            st = gen(st, fnode);
            adir = arr_direct_label(st, fnode);
            st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, foff, -1);
        };
        st = emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, ioff, -1);
        let loop = next_loc(st);
        st = loop.st;
        let done = next_loc(st);
        st = done.st;
        let ret = next_loc(st);
        st = ret.st;
        let end = next_loc(st);
        st = end.st;
        st = emit_label(st, loop.label);
        st = gen_arr_loop_head(st, at, aoff, ioff, done.label);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, eoff, -1);
        let regs: [long] = [];
        if (nargs >= 1) { regs += insn.R_RAX; };
        if (nargs >= 2) { regs += insn.R_RCX; };
        st = gen_arr_call(st, foff, regs, adir, fnode, inl);
        if (key == "foreach") {
            st = emit_insn(st, insn.F_INC_D, insn.R_RBP, -1, 1, ioff, -1, 0, 0);
            st = emit_insn(st, insn.F_JMP_L, loop.label, 0, 0, 0, 0, 0, 0);
            st = emit_label(st, done.label);
            st = emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
        } else if (key == "all") {
            st = emit_insn(st, insn.F_TEST_R_R, insn.R_RAX, 64, insn.R_RAX, 64, 0, 0, 0);
            st = emit_insn(st, insn.F_JZ_L, ret.label, 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_INC_D, insn.R_RBP, -1, 1, ioff, -1, 0, 0);
            st = emit_insn(st, insn.F_JMP_L, loop.label, 0, 0, 0, 0, 0, 0);
            st = emit_label(st, done.label);
            st = emit_insn(st, insn.F_MOV_I_R, 1, insn.R_RAX, 64, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_JMP_L, end.label, 0, 0, 0, 0, 0, 0);
            st = emit_label(st, ret.label);
            st = emit_insn(st, insn.F_MOV_I_R, 0, insn.R_RAX, 64, 0, 0, 0, 0);
            st = emit_label(st, end.label);
        } else if (key == "some") {
            st = emit_insn(st, insn.F_TEST_R_R, insn.R_RAX, 64, insn.R_RAX, 64, 0, 0, 0);
            st = emit_insn(st, insn.F_JNZ_L, ret.label, 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_INC_D, insn.R_RBP, -1, 1, ioff, -1, 0, 0);
            st = emit_insn(st, insn.F_JMP_L, loop.label, 0, 0, 0, 0, 0, 0);
            st = emit_label(st, done.label);
            st = emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
            st = emit_insn(st, insn.F_JMP_L, end.label, 0, 0, 0, 0, 0, 0);
            st = emit_label(st, ret.label);
            st = emit_insn(st, insn.F_MOV_I_R, 1, insn.R_RAX, 64, 0, 0, 0, 0);
            st = emit_label(st, end.label);
        } else {
            st = emit_insn(st, insn.F_TEST_R_R, insn.R_RAX, 64, insn.R_RAX, 64, 0, 0, 0);
            st = emit_insn(st, insn.F_JNZ_L, ret.label, 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_INC_D, insn.R_RBP, -1, 1, ioff, -1, 0, 0);
            st = emit_insn(st, insn.F_JMP_L, loop.label, 0, 0, 0, 0, 0, 0);
            st = emit_label(st, done.label);
            st = emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
            st = emit_insn(st, insn.F_JMP_L, end.label, 0, 0, 0, 0, 0, 0);
            st = emit_label(st, ret.label);
            st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, eoff, -1, insn.R_RAX, 64);
            st = gen_box_rax(st);
            st = emit_label(st, end.label);
        };
        st_temp(st, save)
    } else if (key == "reduce") {
        let fnode = args[0];
        let save = st.temp;
        let aoff = (st.slots + st.temp + 1) * -8;
        let foff = (st.slots + st.temp + 2) * -8;
        let ioff = (st.slots + st.temp + 3) * -8;
        let acoff = (st.slots + st.temp + 4) * -8;
        st = st_temp(st, st.temp + 4);
        st = gen(st, dot.obj);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, aoff, -1);
        let inl = arr_can_inline(st, fnode);
        let adir = 0 - 1;
        if (inl) {
            st = arr_box_caps(st, fnode);
        } else {
            st = gen(st, fnode);
            adir = arr_direct_label(st, fnode);
            st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, foff, -1);
        };
        st = gen(st, args[1]);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, acoff, -1);
        st = emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, ioff, -1);
        let loop = next_loc(st);
        st = loop.st;
        let done = next_loc(st);
        st = done.st;
        st = emit_label(st, loop.label);
        st = gen_arr_loop_head(st, at, aoff, ioff, done.label);
        st = emit_insn(st, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_RCX, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, acoff, -1, insn.R_RAX, 64);
        let regs: [long] = [];
        regs += insn.R_RAX;
        regs += insn.R_RCX;
        st = gen_arr_call(st, foff, regs, adir, fnode, inl);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, acoff, -1);
        st = emit_insn(st, insn.F_INC_D, insn.R_RBP, -1, 1, ioff, -1, 0, 0);
        st = emit_insn(st, insn.F_JMP_L, loop.label, 0, 0, 0, 0, 0, 0);
        st = emit_label(st, done.label);
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, acoff, -1, insn.R_RAX, 64);
        st_temp(st, save)
    } else if (key == "index") {
        let target = args[0];
        let save = st.temp;
        let aoff = (st.slots + st.temp + 1) * -8;
        let voff = (st.slots + st.temp + 2) * -8;
        let ioff = (st.slots + st.temp + 3) * -8;
        let eoff = (st.slots + st.temp + 4) * -8;
        st = st_temp(st, st.temp + 4);
        st = gen(st, dot.obj);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, aoff, -1);
        st = gen(st, target);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, voff, -1);
        st = emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, ioff, -1);
        let loop = next_loc(st);
        st = loop.st;
        let done = next_loc(st);
        st = done.st;
        let found = next_loc(st);
        st = found.st;
        let end = next_loc(st);
        st = end.st;
        st = emit_label(st, loop.label);
        st = gen_arr_loop_head(st, at, aoff, ioff, done.label);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, eoff, -1);
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, voff, -1, insn.R_RAX, 64);
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, eoff, -1, insn.R_RAX, 64);
        st = gen_eq_vals(st, arr_elem_of(at));
        st = emit_insn(st, insn.F_TEST_R_R, insn.R_RAX, 64, insn.R_RAX, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_JNZ_L, found.label, 0, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_INC_D, insn.R_RBP, -1, 1, ioff, -1, 0, 0);
        st = emit_insn(st, insn.F_JMP_L, loop.label, 0, 0, 0, 0, 0, 0);
        st = emit_label(st, done.label);
        st = emit_insn(st, insn.F_MOV_I_R, -1, insn.R_RAX, 64, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_JMP_L, end.label, 0, 0, 0, 0, 0, 0);
        st = emit_label(st, found.label);
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, ioff, -1, insn.R_RAX, 64);
        st = emit_label(st, end.label);
        st_temp(st, save)
    } else {
        // sort/sorted emitted below in a later arm; keep a loud internal
        // marker rather than silently emitting nothing.
        st = emit(st, "    # INTERNAL: array method '" + key + "' has no emitter")
    }
};

def gen_arr_insert_method(st: EmitSt, node: Call) -> EmitSt {
    let dot: Dot = node.callee;
    let esz = arr_elem_bytes((infer(st, dot.obj)));
    let args: [Node] = node.args;
    st = gen(st, dot.obj);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen(st, args[0]);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen(st, args[1]);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_I_R, esz, insn.R_RAX, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_arr_insert"), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_ADD_I_R, 32, insn.R_RSP, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
    st
};

def gen_arr_method(st: EmitSt, node: Call) -> EmitSt {
    let dot: Dot = node.callee;
    let key = dot.key;
    let at = infer(st, dot.obj);
    if (key == "pop") { gen_arr_pop_shift(st, node, false) }
    else if (key == "shift") { gen_arr_pop_shift(st, node, true) }
    else if (key == "remove") { gen_arr_remove(st, node) }
    else if (key == "push") { gen_arr_push_method(st, node, false) }
    else if (key == "unshift") { gen_arr_push_method(st, node, true) }
    else if (key == "insert") { gen_arr_insert_method(st, node) }
    else { gen_arr_iter_method(st, node, key, at) }
};

def gen_method(st: EmitSt, node: Call) -> EmitSt {
    let mcal: Dot = node.callee;
    let mobj = mcal.obj;
    let sm = types.str_method(mcal.key);
    let margs: [Node] = node.args;
    let args: [Node] = [];
    if (!sm.last) { args += mobj; };
    margs.foreach((e) => {
        args += e;
    });
    if (len(margs) < len(sm.params)) {
        // The left-out optional argument's default: the table carries its
        // TEXT, and the parameter's type says what kind of literal to make.
        // A str default (`s.pad_left(n)` -> " ") is a string literal; a long
        // one (`s.index_of(p)` -> 0) is a numeric literal, and a string
        // literal holding "0" would be a type error.
        let want: Type = sm.params[len(margs)];
        if (want.k == K.tlong) {
            args += n_num(sm.dflt, node.line, node.col);
        } else {
            args += n_str(sm.dflt, node.line, node.col);
        };
    };
    if (sm.last) { args += mobj; };
    let fname = sm.fn;
    if (len(runtime_base(fname)) > 0) {
        st = gen_push_args(st, args);
        st = emit_insn(st, insn.F_CALL_L, lbl_new(fname), 0, 0, 0, 0, 0, 0);
        emit_insn(st, insn.F_ADD_I_R, len(args) * 8, insn.R_RSP, 64, 0, 0, 0, 0)
    } else {
        gen_call(st, { k: K.call, callee: { k: K.id, v: fname, line: node.line, col: node.col }, args: args, line: node.line, col: node.col })
    }
};

def gen_print(st: EmitSt, node: Call) -> EmitSt {
    let args: [Node] = node.args;
    let pa0 = args[0];
    let t: Type = infer(st, pa0);
    if (t.k == K.trec) {
        // Records are formatted field by field from their static shape.
        st = gen_rec_str(st, pa0, t);
        st = gen_helper1(st, "y_print_hstr");
        emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0)
    } else if (t.k == K.tfunc) {
        // A function value has no printable contents; show its signature
        // (`<function (params) -> ret>`, in the spelling types.y tstr gives,
        // the one every diagnostic uses).
        st = gen(st, pa0);
        st = gen_str_const(st, "<function " + types.tstr(t) + ">");
        st = gen_helper1(st, "y_print_hstr");
        emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0)
    } else if (t.k == K.tarr || t.k == K.tarrfix) {
        // Arrays print like tostring: "[e0, e1, ...]", or b'...' for
        // [byte] (Python-style byte strings).
        st = gen(st, pa0);
        let arr: ArrTy = t;
        st = arr.of.k == K.tbyte ? gen_helper1(st, "y_bytes_repr") : gen_arr_tostr_rax(st, arr.of, []);
        st = gen_helper1(st, "y_print_hstr");
        emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0)
    } else if (t.k == K.topt) {
        st = gen(st, pa0);
        st = gen_opt_str_rax(st, t, []);
        st = gen_helper1(st, "y_print_hstr");
        emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0)
    } else if (t.k == K.tmap) {
        // Maps format entry by entry: {"k": v, ...} (quoted keys).
        st = gen_map_repr(st, pa0, t);
        st = gen_helper1(st, "y_print_hstr");
        emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0)
    } else if (t.k == K.tunion) {
        st = gen(st, pa0);
        st = gen_union_str_rax(st, t, []);
        st = gen_helper1(st, "y_print_hstr");
        emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0)
    } else {
        gen_print_scalar(st, pa0, t)
    }
};

def gen_print_scalar(st: EmitSt, arg: Node, t: Type) -> EmitSt {
    st = gen(st, arg);
    if (t.k == K.tbool) {
        st = gen_helper1(st, "y_print_bool");
        emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0)
    } else if (t.k == K.tbigint) {
        st = gen_helper1(st, "y_bigint_print");
        emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0)
    } else if (t.k == K.tstr) {
        if (arg.k == K.str) {
            // print("literal"): one helper call writes the literal's own bytes
            // and the newline, so a program that only prints literals links
            // y_print_lit and not the string helpers. gen(st, arg) already put
            // the length HEADER in %rax; its bytes start eight bytes in.
            let lit: Leaf = arg;
            st = emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RAX, 64, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_MOV_I_R, len(lit.v), insn.R_RAX, 64, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_CALL_L, lbl_new("y_print_lit"), 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0);
            emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0)
        } else {
            st = gen_helper1(st, "y_print_hstr");
            emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0)
        }
    } else if (t.k == K.tfloat) {
        st = gen_helper1(st, "y_print_float");
        emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0)
    } else {
        st = gen_helper1(st, "y_print_long");
        emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0)
    }
};

// `typeof(e)` is resolved statically: the checker has already pinned e's
// type, so this is a plain string constant.
def gen_typeof(st: EmitSt, node: Call) -> EmitSt {
    let targs: [Node] = node.args;
    gen_str_const(st, types.tstr(infer(st, targs[0])))
};

// ── record formatting ──────────────────────────────────────────────────
// `{a: 1, b: "x"}` — the shape is static, so the walk is unrolled at
// compile time. Stack layout while building: [record][accumulator], the
// record pushed first (8(%rsp)), the accumulator on top (0(%rsp)).

// Option value in %rax (0 = none, else the box address): leave "none" or
// the payload's string form in %rax. Options are 0-or-box (NATIVE.md).
def gen_opt_str_rax(st: EmitSt, t: Type, path: [Type]) -> EmitSt {
    let rdone = next_loc(st);
    st = rdone.st;
    let rnul = next_loc(st);
    st = rnul.st;
    st = emit_insn(st, insn.F_TEST_R_R, insn.R_RAX, 64, insn.R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JZ_L, rnul.label, 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RAX, -1, 1, -1, -1, insn.R_RAX, 64);
    let opt: TOf = t;
    st = gen_val_tostr_rax(st, opt.of, path + t);
    st = emit_insn(st, insn.F_JMP_L, rdone.label, 0, 0, 0, 0, 0, 0);
    st = emit_label(st, rnul.label);
    st = gen_str_const(st, "none");
    emit_label(st, rdone.label)
};

def gen_rec_str(st: EmitSt, arg: Node, t: Type) -> EmitSt {
    st = gen(st, arg);
    gen_rec_str_rax(st, t, lay_of(t, t), [])
};

// The record's address sits in %rax; leave "{a: 1, b: ...}" in %rax.
// Values are formatted from the static shape (the walk is unrolled at
// compile time). Stack layout while building: [record][accumulator], the
// record pushed first (8(%rsp)), the accumulator on top (0(%rsp)).
def gen_rec_str_rax(st: EmitSt, t: Type, lay: [str], path: [Type]) -> EmitSt {
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen_str_const(st, "{");
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    let rec: TRec = t;
    let fs: [Field] = rec.fields;
    for i in 0..len(fs) {
        let f = fs[i];
        let fname: str = f.name;
        let sep = "";
        if (i > 0) { sep = ", "; }
        st = gen_acc_cat_const(st, sep + fname + ": ");
        st = gen_rec_field_str(st, mfield_idx(lay, fname), f.typ, path);
    };
    st = gen_acc_cat_const(st, "}");
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RSP, -1, 1, -1, -1, insn.R_RAX, 64);
    emit_insn(st, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0)
};

// `x :: a` -- cons: a NEW array with x prepended as exactly ONE element
// (types.y typeof_cons keeps even array-typed elements whole).
def gen_cons(st: EmitSt, node: Bin) -> EmitSt {
    let ln = node.line;
    let cl = node.col;
    let crt = infer(st, node.r);
    let cesz = arr_elem_bytes(crt);
    st = gen_array_esz(st, ({ k: K.array, elems: args1(node.l), line: ln, col: cl }), cesz, store_elem_type(crt, cesz));
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen(st, node.r);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_I_R, cesz, insn.R_RAX, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_arr_cat"), 0, 0, 0, 0, 0, 0);
    emit_insn(st, insn.F_ADD_I_R, 24, insn.R_RSP, 64, 0, 0, 0, 0)
};

// `l + r` on two arrays whose element types differ by an implicit numeric
// conversion ([float] + [long], [long] + [byte], ...): y_arr_cat copies raw
// elements, so build the result element by element instead --
// { let a = l; let b = r; let c: [L] = []; c += a; c += b; c } -- where
// each `+=` pushes through the element conversion (gen_push).
def gen_cat_conv(st: EmitSt, node: Bin, lt: Type) -> EmitSt {
    let ln = node.line;
    let cl = node.col;
    let r = next_uid(st);
    st = r.st;
    let t1 = "y_t" + tostring(r.uid);
    let noelems: [Node] = [];
    let da: Decl = { k: K.decl, kind: "let", typ: normtype({ k: K.tnone }), name: t1 + "l", v: node.l, line: ln, col: cl, nline: ln, ncol: cl };
    let db: Decl = { k: K.decl, kind: "let", typ: normtype({ k: K.tnone }), name: t1 + "r", v: node.r, line: ln, col: cl, nline: ln, ncol: cl };
    let arr_type: ArrTy = lt;
    let dc: Decl = { k: K.decl, kind: "let", typ: type_node({ k: K.tarr, of: arr_type.of }), name: t1 + "c", v: { k: K.array, elems: noelems, line: ln, col: cl }, line: ln, col: cl, nline: ln, ncol: cl };
    let pa: OpAssign = { k: K.opassign, tgt: n_id(t1 + "c", ln, cl), op: "+", v: n_id(t1 + "l", ln, cl), line: ln, col: cl };
    let pb: OpAssign = { k: K.opassign, tgt: n_id(t1 + "c", ln, cl), op: "+", v: n_id(t1 + "r", ln, cl), line: ln, col: cl };
    let panode: Node = pa;
    let pbnode: Node = pb;
    gen(st, block6(da, db, dc, panode, pbnode, n_id(t1 + "c", ln, cl), ln, cl))
};

// Array `+`: always a NEW array (arr + arr, arr + elem, elem + arr).
// y_arr_cat copies both sides; the one-element side is built with the
// ordinary array literal emitter, so `arr + v` evaluates v exactly once.
// Two array operands concatenate unless types.arr_plus_kind says one of
// them is an element of the other ([[T]] + [T], [T] + [[T]]).
def gen_cat_arr(st: EmitSt, node: Bin, lt: Type, rt: Type) -> EmitSt {
    let ln = node.line;
    let cl = node.col;
    let lk: long = lt.k;
    let rk: long = rt.k;
    let lisarr = lk == K.tarr || lk == K.tarrfix;
    let risarr = rk == K.tarr || rk == K.tarrfix;
    let how = "elem";
    if (lisarr && risarr) { how = types.arr_plus_kind(lt, rt); };
    if (how == "cat") {
        let la: ArrTy = lt;
        let ra: ArrTy = rt;
        if (!types.teq(la.of, ra.of)) {
            return gen_cat_conv(st, node, lt);
        };
    };
    let larr = lisarr && how != "prepend";
    let esz = 8;
    let ety: Type = { k: K.tnone };
    if (larr) {
        esz = arr_elem_bytes(lt);
        ety = store_elem_type(lt, esz);
    } else {
        esz = arr_elem_bytes(rt);
        ety = store_elem_type(rt, esz);
    };
    let one = { k: K.array, elems: args1(node.r), line: ln, col: cl };
    if (!(larr)) {
        one = { k: K.array, elems: args1(node.l), line: ln, col: cl };
    };
    if (larr) {
        st = gen(st, node.l);
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = how == "cat" ? gen(st, node.r) : gen_array_esz(st, one, esz, ety);
    } else {
        st = gen_array_esz(st, one, esz, ety);
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = gen(st, node.r);
    };
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_I_R, esz, insn.R_RAX, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_arr_cat"), 0, 0, 0, 0, 0, 0);
    emit_insn(st, insn.F_ADD_I_R, 24, insn.R_RSP, 64, 0, 0, 0, 0)
};

// acc = acc + <constant>, with the layout above still in place.
def gen_acc_cat_const(st: EmitSt, s: str) -> EmitSt {
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RSP, -1, 1, -1, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen_str_const(st, s);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_str_cat"), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0);
    emit_insn(st, insn.F_MOV_R_0, insn.R_RAX, 64, insn.R_RSP, -1, 1, -1, -1)
};

// Slot idx of the record in %rcx into %rax (every caller wants it there).
def gen_slot_load(st: EmitSt, idx: long) -> EmitSt {
    emit_insn(st, insn.F_MOV_D_R, insn.R_RCX, -1, 1, 8 * idx, -1, insn.R_RAX, 64)
};

// acc = acc + <field in slot idx, rendered by its static type>. The chain is
// ASSIGNED, not run as a statement: an arm's value is the EmitSt its walk
// returned, and dropping it drops the uid counter with it -- the next string
// constant would take a label already emitted, and the assembler would reject
// the duplicate.
def gen_rec_field_str(st: EmitSt, idx: long, ft: Type, path: [Type]) -> EmitSt {
    let fk = ft.k;
    st = if (fk == K.tstr) {
        // a str is already its own form
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RSP, -1, 1, 8, -1, insn.R_RCX, 64);
        gen_slot_load(st, idx)
    } else if (fk == K.tlong) {
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RSP, -1, 1, 8, -1, insn.R_RCX, 64);
        st = gen_slot_load(st, idx);
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_CALL_L, lbl_new("y_long_tostr"), 0, 0, 0, 0, 0, 0);
        emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0)
    } else if (fk == K.tbool) {
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RSP, -1, 1, 8, -1, insn.R_RCX, 64);
        st = gen_slot_load(st, idx);
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_CALL_L, lbl_new("y_bool_tostr"), 0, 0, 0, 0, 0, 0);
        emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0)
    } else if (fk == K.tfloat) {
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RSP, -1, 1, 8, -1, insn.R_RCX, 64);
        st = gen_slot_load(st, idx);
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_CALL_L, lbl_new("y_float_tostr"), 0, 0, 0, 0, 0, 0);
        emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0)
    } else if (fk == K.tfunc) {
        gen_str_const(st, "<function " + types.tstr(ft) + ">")
    } else {
        // Arrays, options, maps, records and unions nested in a RECORD: the
        // value walk formats them, the same text tostring() gives. This used
        // to print the field's TYPE instead ("<{str => long}>") on the
        // mistaken belief that only gen_val_tostr_rax walked them -- it does,
        // and it is exactly what a field needs.
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RSP, -1, 1, 8, -1, insn.R_RCX, 64);
        st = gen_slot_load(st, idx);
        gen_val_tostr_rax(st, ft, path)
    };
    st = emit_insn(st, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_RDX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RSP, -1, 1, -1, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RDX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_str_cat"), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0);
    emit_insn(st, insn.F_MOV_R_0, insn.R_RAX, 64, insn.R_RSP, -1, 1, -1, -1)
};

// The number of bytes gen_syscall reserves below %rsp on the Windows target
// when the call has a fifth argument or more.  The kernel reads those from
// 40(%rsp).. up (see w_syscall_reg), and the largest call the checker accepts
// is NtWriteFile's nine arguments, so the last slot is at 40 + 4*8 = 72 and
// the area has to reach 80.  96 covers it and keeps %rsp 16-aligned.
def w_arg_space() -> long { 96 };

// The offset of argument `i` (1-based, five or more) on the stack, measured
// from %rsp at the `syscall`.  Argument five is at 40: Win64 reserves 32
// bytes of shadow space at 0(%rsp)..32(%rsp) and a Win64 *call* passes its
// fifth argument at 40(%rsp), which is where a callee reads it -- and the
// kernel reads its arguments from exactly the place ntdll's own stub has
// them, which is that same shadow space.
def w_stack_arg_off(i: long) -> long {
    40 + 8 * (i - 5)
};

def gen_syscall(st: EmitSt, node: Call) -> EmitSt {
    let args: [Node] = node.args;
    // args[0] is the number; the rest are the call's arguments.
    let n = len(args) - 1;
    let regs = target_is_windows() ? w_syscall_regargs() : 6;
    // The stack arguments' room is reserved FIRST, because their slots are
    // ABOVE %rsp and every step of the argument sequence moves %rsp: reserved
    // afterwards, it would sit below the pushes rather than where the kernel
    // reads.  Nothing is reserved on Linux, whose six arguments are all
    // registers -- which is what keeps the ELF path byte-identical.
    let room = (target_is_windows() && n > regs) ? w_arg_space() : 0;
    let nreg = if (n < regs) { n } else { regs };
    if (room > 0) {
        st = emit_insn(st, insn.F_SUB_I_R, room, insn.R_RSP, 64, 0, 0, 0, 0);
        // The stack arguments go straight to their slots, evaluated here and
        // never pushed: a pushed one would have to be popped before %rsp could
        // be right for the next, and the registers the kernel wants them in are
        // the ones the register arguments are about to take.  Reverse order,
        // like the pops below.
        let i = n;
        while (i > regs) {
            st = gen(st, args[i]);
            if ((infer(st, args[i])).k == K.tstr) {
                st = emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RAX, 64, 0, 0, 0, 0);
            };
            st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RSP, -1, 1, w_stack_arg_off(i), -1);
            i = i - 1;
        };
    };
    // The number and the register arguments: push them all, pop them off the
    // top in reverse.
    st = gen(st, args[0]);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    for k in 1..nreg + 1 {
        st = gen(st, args[k]);
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    };
    let j = nreg;
    while (j >= 1) {
        st = emit_insn(st, insn.F_POP_R, syscall_reg(j - 1), 64, 0, 0, 0, 0, 0);
        // a str flows in as its header; the kernel wants the data bytes.
        if ((infer(st, args[j])).k == K.tstr) {
            st = emit_insn(st, insn.F_ADD_I_R, 8, syscall_reg(j - 1), 64, 0, 0, 0, 0);
        }
        j = j - 1;
    };
    st = emit_insn(st, insn.F_POP_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_SYSCALL, 0, 0, 0, 0, 0, 0, 0);
    if (room > 0) {
        st = emit_insn(st, insn.F_ADD_I_R, room, insn.R_RSP, 64, 0, 0, 0, 0);
    };
    st
};

// The frame offset of the closure record of the body being emitted, or -1
// when it captures nothing. Every "capture" env entry carries it (their
// `off` is the record's slot offset) — used to pass the record along on
// recursive `self` calls, which would otherwise reach the body without
// one.
def capture_off(st: EmitSt) -> long {
    let env = st.env;
    let i = 0;
    let res = -1;
    while (i < len(env)) {
        let e = env[i];
        if (e.kind == "capture") {
            res = e.off;
        }
        i++;
    };
    res
};

def gen_direct(st: EmitSt, node: Call, name: str) -> EmitSt {
    let label = -1;
    let indirect = false;
    let dptypes: [Type] = [];
    if (name == "self") {
        label = st.self_label;
        dptypes = fn_args_of(cur_fn_type(st));
    } else {
        let e = env_find(st, name);
        if (e.kind == "none") {
            label = lbl_new("y_missing_" + name);
        } else if (e.kind == "func") {
            label = e.label;
            dptypes = fn_args_of(e.typ);
        } else {
            // A local/param/capture/global holding a closure value: call
            // through it.
            indirect = true;
        };
    };
    if (indirect) {
        gen_indirect(st, node, node.callee)
    } else {
        // A recursive call (`self`, or a capturing function's own name)
        // reaches the same body, which reads its captures through the
        // closure record — pass this frame's record along, exactly as an
        // indirect call would.
        let soff = -1;
        if (label == st.self_label) {
            soff = capture_off(st);
        }
        if (soff >= 0) {
            st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, soff, -1, insn.R_RAX, 64);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        }
        st = gen_push_args_as(st, node.args, dptypes);
        st = emit_insn(st, insn.F_CALL_L, label, 0, 0, 0, 0, 0, 0);
        let nbytes = len(node.args) * 8;
        if (soff >= 0) {
            nbytes = nbytes + 8;
        }
        if (nbytes == 0) {
            st
        } else {
            emit_insn(st, insn.F_ADD_I_R, nbytes, insn.R_RSP, 64, 0, 0, 0, 0)
        }
    }
};

// ── control flow ───────────────────────────────────────────────────────

// Is `t` a type whose == / < / <= ... is one `cmp` of two machine words?
// The numeric fall-through in gen_bin_rest is what answers those, so this is
// the complement of the shapes it sends elsewhere: a float (ucomisd, where
// unordered decides the flags and a NaN must stay a NaN), a string
// (y_str_eq / y_str_cmp), an array or record (structural), a map, and an
// option whose payload is compared (gen_eq_opt -- `x == none` is a plain test
// and is left to the slow path rather than special-cased here).
def cmp_word(t: Type) -> bool {
    t.k == K.tlong || t.k == K.tbyte || t.k == K.tbool || t.k == K.tptr
};

// The jcc that takes the FALSE edge of `node` when it is a plain integer
// comparison -- the instruction a branch needs anyway -- or 0 when the
// condition is anything else. The form, not the mnemonic: the site emits it.
//
// Driven by the operator, never by matching the text of an emitted setcc: the
// materialisation and the branch can disagree (ucomisd sets ZF/PF/CF for an
// unordered compare, a structural == is a call), and the emitter may change how
// a bool is built without this going stale. Each jcc is the negation of its
// setcc form: `<` is setl, so its false edge is jge.
def int_cmp_jcc(st: EmitSt, node: Node) -> long {
    let jcc = 0;
    if (node.k == K.bin) {
        let bin: Bin = node;
        let op = bin.op;
        if (cmp_word(infer(st, bin.l)) && cmp_word(infer(st, bin.r))) {
            if (op == "<") { jcc = insn.F_JGE_L; }
            else if (op == ">") { jcc = insn.F_JLE_L; }
            else if (op == "<=") { jcc = insn.F_JG_L; }
            else if (op == ">=") { jcc = insn.F_JL_L; }
            else if (op == "==") { jcc = insn.F_JNE_L; }
            else if (op == "!=") { jcc = insn.F_JE_L; };
        };
    };
    jcc
};

// The operands the way the numeric path emits them -- left into %rax, right
// into %rcx -- so the `cmp %rcx, %rax` that follows reads left - right and the
// same setcc/jcc forms apply.
def gen_cmp_flags(st: EmitSt, node: Bin) -> EmitSt {
    // Same trade as gen_float_bin's, on the flags path: the left operand has to
    // survive the right one's evaluation, every GPR is caller-saved, and %rcx --
    // which is where the right one lands -- is caller-saved too, so the general
    // answer is the stack. When the right operand is a leaf it touches neither
    // %rcx nor the stack, so the left can go straight into %rcx.
    //
    // This is the hottest shape in the language: `if x < 1`, `if i < n`, `if k ==
    // K.something`. ycc's own output has 3660 comparisons of this form.
    //
    // The cmp is written dst-minus-src either way, so moving the operands
    // between the registers does not move the flags: left in %rcx and right in
    // %rax gives `cmp %rax, %rcx`, the same subtraction as `cmp %rcx, %rax`.
    st = gen(st, node.l);
    if (leaf_expr(node.r)) {
        st = emit_insn(st, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_RCX, 64, 0, 0, 0);
        st = gen(st, node.r);
        emit_insn(st, insn.F_CMP_R_R, insn.R_RAX, 64, insn.R_RCX, 64, 0, 0, 0)
    } else {
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = gen(st, node.r);
        st = emit_insn(st, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_RCX, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_POP_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        emit_insn(st, insn.F_CMP_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0)
    }
};

def gen_if(st: EmitSt, node: If) -> EmitSt {
    gen_if_go(st, node)
};

def gen_if_go(st: EmitSt, node: If) -> EmitSt {
    let r1 = next_loc(st);
    st = r1.st;
    let r2 = next_loc(st);
    st = r2.st;
    let jcc = int_cmp_jcc(st, node.cond);
    if (jcc != 0) {
        // A comparison branches on the flags it has just set: the bool is
        // never built. `setcc; movzbq; test; jcc` (four instructions) becomes
        // `cmp; jcc` (two) -- 3,049 such sites in ycc's own output.
        let cbin: Bin = node.cond;
        st = gen_cmp_flags(st, cbin);
        st = emit_insn(st, jcc, r1.label, 0, 0, 0, 0, 0, 0);
    } else {
        st = gen(st, node.cond);
        st = emit_insn(st, insn.F_TEST_R_R, insn.R_RAX, 64, insn.R_RAX, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_JZ_L, r1.label, 0, 0, 0, 0, 0, 0);
    };
    st = gen(st, node.then);
    if (node.has_else) {
        st = emit_insn(st, insn.F_JMP_L, r2.label, 0, 0, 0, 0, 0, 0);
        st = emit_label(st, r1.label);
        st = gen_loc_elif(st, node.els);
        st = gen(st, node.els);
        emit_label(st, r2.label)
    } else {
        emit_label(st, r1.label)
    }
};

// A loop's value is void (types.y: every loop kind's typeof is
// tvoid), so nothing can read what the merge label leaves in %rax:
// `let x = while (...) {...}`, `print(while ...)`,
// `let z: long = if (c) { while ... } else {2}` and a function
// whose body's last statement is a loop are all checker errors
// ("cannot bind a void value", "got void"). So the merge label
// needs no `xor %eax, %eax` at all -- 1,235 of them in ycc's own
// output, 586 of them in statement position.
def gen_while(st: EmitSt, node: While) -> EmitSt {
    let r1 = next_loc(st);
    st = r1.st;
    let r2 = next_loc(st);
    st = r2.st;
    st = emit_label(st, r1.label);
    let jcc = int_cmp_jcc(st, node.cond);
    if (jcc != 0) {
        let cbin: Bin = node.cond;
        st = gen_cmp_flags(st, cbin);
        st = emit_insn(st, jcc, r2.label, 0, 0, 0, 0, 0, 0);
    } else {
        st = gen(st, node.cond);
        st = emit_insn(st, insn.F_TEST_R_R, insn.R_RAX, 64, insn.R_RAX, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_JZ_L, r2.label, 0, 0, 0, 0, 0, 0);
    };
    // A `while` has no step, so "the next turn" IS the head: continue goes to
    // r1 and nothing else is needed.
    let saved_brk = brk_label;
    let saved_cont = cont_label;
    brk_label = r2.label;
    cont_label = r1.label;
    loop_names += "";
    loop_brks += brk_label;
    loop_conts += cont_label;
    st = gen_discard(st, node.body);
    loop_names = loop_names[0:len(loop_names) - 1];
    loop_brks = loop_brks[0:len(loop_brks) - 1];
    loop_conts = loop_conts[0:len(loop_conts) - 1];
    brk_label = saved_brk;
    cont_label = saved_cont;
    st = gen_loc_loop(st, node);
    st = emit_insn(st, insn.F_JMP_L, r1.label, 0, 0, 0, 0, 0, 0);
    emit_label(st, r2.label)
};

// ── counted loops ──────────────────────────────────────────────────────
// All three lower to the same shape as `while`: a head label, a test, the
// body, a step, and a jump back. The loop variable is a normal local slot,
// so nothing new is needed at runtime.

// A loop's value is void (types.y: every loop kind's typeof is
// tvoid), so nothing can read what the merge label leaves in %rax:
// `let x = while (...) {...}`, `print(while ...)`,
// `let z: long = if (c) { while ... } else {2}` and a function
// whose body's last statement is a loop are all checker errors
// ("cannot bind a void value", "got void"). So the merge label
// needs no `xor %eax, %eax` at all -- 1,235 of them in ycc's own
// output, 586 of them in statement position.
def gen_for(st: EmitSt, node: For) -> EmitSt {
    // for (init; cond; step) body
    st = gen(st, node.init);
    let r1 = next_loc(st);
    st = r1.st;
    let r2 = next_loc(st);
    st = r2.st;
    st = emit_label(st, r1.label);
    let jcc = int_cmp_jcc(st, node.cond);
    if (jcc != 0) {
        let cbin: Bin = node.cond;
        st = gen_cmp_flags(st, cbin);
        st = emit_insn(st, jcc, r2.label, 0, 0, 0, 0, 0, 0);
    } else {
        st = gen(st, node.cond);
        st = emit_insn(st, insn.F_TEST_R_R, insn.R_RAX, 64, insn.R_RAX, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_JZ_L, r2.label, 0, 0, 0, 0, 0, 0);
    };
    // `for` is the one loop where `continue` cannot go to the head: the step is
    // between the body and the head, and skipping it would leave the loop
    // variable where it was -- `for (i = 0; i < n; i++) { continue; }` would
    // never end. So a third label sits between the body and the step.
    let r3 = next_loc(st);
    st = r3.st;
    let saved_brk = brk_label;
    let saved_cont = cont_label;
    brk_label = r2.label;
    cont_label = r3.label;
    loop_names += "";
    loop_brks += brk_label;
    loop_conts += cont_label;
    st = gen_discard(st, node.body);
    loop_names = loop_names[0:len(loop_names) - 1];
    loop_brks = loop_brks[0:len(loop_brks) - 1];
    loop_conts = loop_conts[0:len(loop_conts) - 1];
    brk_label = saved_brk;
    cont_label = saved_cont;
    st = emit_label(st, r3.label);
    st = gen_loc_loop(st, node);
    st = gen(st, node.step);
    st = emit_insn(st, insn.F_JMP_L, r1.label, 0, 0, 0, 0, 0, 0);
    emit_label(st, r2.label)
};

// A loop's value is void (types.y: every loop kind's typeof is
// tvoid), so nothing can read what the merge label leaves in %rax:
// `let x = while (...) {...}`, `print(while ...)`,
// `let z: long = if (c) { while ... } else {2}` and a function
// whose body's last statement is a loop are all checker errors
// ("cannot bind a void value", "got void"). So the merge label
// needs no `xor %eax, %eax` at all -- 1,235 of them in ycc's own
// output, 586 of them in statement position.
def gen_forrange(st: EmitSt, node: ForRange) -> EmitSt {
    // for (x in lo..hi) body — half-open: lo inclusive, hi exclusive.
    // Slot layout: [var][limit]; the limit is evaluated once.
    let voff = (st.slots + 1) * -8;
    let loff = (st.slots + 2) * -8;
    st = { ir: st.ir, txt: st.txt, rodata: st.rodata, uid: st.uid,
        fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots + 2, temp: st.temp,
        self_label: st.self_label, end_label: st.end_label, fns: st.fns,
        bodies: st.bodies, btext: st.btext, blabels: st.blabels };
    st = gen(st, node.hi);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, loff, -1);
    st = gen(st, node.lo);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, voff, -1);
    st = env_define(st, node.name, "local", voff, -1, "", normtype({ k: K.tlong }));
    let r1 = next_loc(st);
    st = r1.st;
    let r2 = next_loc(st);
    st = r2.st;
    st = emit_label(st, r1.label);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, voff, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, loff, -1, insn.R_RCX, 64);
    st = emit_insn(st, insn.F_CMP_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JGE_L, r2.label, 0, 0, 0, 0, 0, 0);
    // `continue` goes to a label just BEFORE the increment, not to the head.
    //
    // Two mistakes are available here and both were made before this was right.
    // Jumping to the head looks right -- "the next turn" -- but the counter is
    // incremented at the BOTTOM of the loop, after the body, so a `continue`
    // that jumps to the head never advances it and the loop spins forever on one
    // value. (`for x in 0..10 { if x < 5 { continue; } ... }` hung.) Jumping to
    // the increment itself is correct, and the fresh per-turn cell is still
    // made: box_bound runs at the TOP of the next turn, which the `jmp r1` after
    // the increment reaches. So the label goes before the `inc`, and the reason
    // it is not simply the `inc` is that nothing may run between them.
    let r3 = next_loc(st);
    st = r3.st;
    let saved_brk = brk_label;
    let saved_cont = cont_label;
    brk_label = r2.label;
    cont_label = r3.label;
    loop_names += node.name;
    loop_brks += brk_label;
    loop_conts += cont_label;
    st = box_bound(st, node.name);
    st = gen_discard(st, node.body);
    loop_names = loop_names[0:len(loop_names) - 1];
    loop_brks = loop_brks[0:len(loop_brks) - 1];
    loop_conts = loop_conts[0:len(loop_conts) - 1];
    brk_label = saved_brk;
    cont_label = saved_cont;
    st = emit_label(st, r3.label);
    st = gen_loc_loop(st, node);
    // the counter in place: one instruction, not a load, an inc and a store
    st = emit_insn(st, insn.F_INC_D, insn.R_RBP, -1, 1, voff, -1, 0, 0);
    st = emit_insn(st, insn.F_JMP_L, r1.label, 0, 0, 0, 0, 0, 0);
    emit_label(st, r2.label)
};

// A loop's value is void (types.y: every loop kind's typeof is
// tvoid), so nothing can read what the merge label leaves in %rax:
// `let x = while (...) {...}`, `print(while ...)`,
// `let z: long = if (c) { while ... } else {2}` and a function
// whose body's last statement is a loop are all checker errors
// ("cannot bind a void value", "got void"). So the merge label
// needs no `xor %eax, %eax` at all -- 1,235 of them in ycc's own
// output, 586 of them in statement position.
def gen_foreach(st: EmitSt, node: Foreach) -> EmitSt {
    // foreach (x in arr) body. Slots: [x][arr][i]. The array is evaluated
    // once; `x` is refreshed from arr[i] at the top of every iteration.
    let voff = (st.slots + 1) * -8;
    let aoff = (st.slots + 2) * -8;
    let ioff = (st.slots + 3) * -8;
    st = { ir: st.ir, txt: st.txt, rodata: st.rodata, uid: st.uid,
        fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots + 3, temp: st.temp,
        self_label: st.self_label, end_label: st.end_label, fns: st.fns,
        bodies: st.bodies, btext: st.btext, blabels: st.blabels };
    let elt: Type = infer(st, node.iter);
    let eltyp: Type = normtype({ k: K.tunk });
    if (elt.k == K.tarr) {
        let arr: TOf = elt;
        eltyp = arr.of;
    }
    if (elt.k == K.tarrfix) {
        let arr: TFix = elt;
        eltyp = arr.of;
    }
    st = gen(st, node.iter);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, aoff, -1);
    st = emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, ioff, -1);
    st = env_define(st, node.name, "local", voff, -1, "", eltyp);
    let r1 = next_loc(st);
    st = r1.st;
    let r2 = next_loc(st);
    st = r2.st;
    st = emit_label(st, r1.label);
    // i < len(arr) — the heap header keeps the length in slot 0. The length
    // is re-read on every iteration, not hoisted into a fourth slot: a body
    // that appends to the array it walks goes on seeing what it appended
    // (`foreach (x in a) { a += x }` never ends), which hoisting would change.
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, aoff, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RDX, -1, 1, -1, -1, insn.R_RCX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, ioff, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_CMP_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JGE_L, r2.label, 0, 0, 0, 0, 0, 0);
    // x = arr[i]
    st = elem_load(st, arr_elem_bytes(elt), insn.R_RDX, insn.R_RAX, insn.R_RCX);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RCX, 64, insn.R_RBP, -1, 1, voff, -1);
    // continue -> just before the increment, for the reason in gen_forrange
    let r3 = next_loc(st);
    st = r3.st;
    let saved_brk = brk_label;
    let saved_cont = cont_label;
    brk_label = r2.label;
    cont_label = r3.label;
    loop_names += node.name;
    loop_brks += brk_label;
    loop_conts += cont_label;
    st = box_bound(st, node.name);
    st = gen_discard(st, node.body);
    loop_names = loop_names[0:len(loop_names) - 1];
    loop_brks = loop_brks[0:len(loop_brks) - 1];
    loop_conts = loop_conts[0:len(loop_conts) - 1];
    brk_label = saved_brk;
    cont_label = saved_cont;
    st = emit_label(st, r3.label);
    st = gen_loc_loop(st, node);
    // the counter in place: one instruction, not a load, an inc and a store
    st = emit_insn(st, insn.F_INC_D, insn.R_RBP, -1, 1, ioff, -1, 0, 0);
    st = emit_insn(st, insn.F_JMP_L, r1.label, 0, 0, 0, 0, 0, 0);
    emit_label(st, r2.label)
};

// ── tail calls ─────────────────────────────────────────────────────────
// A self-call in tail position (the body's trailing value, a `return`'s
// value, an if-arm's trailing value) recycles the frame instead of
// growing the stack: every argument is evaluated into a fresh local
// first (arguments may read parameters the copy below overwrites), the
// locals are copied over the parameter slots, and the frame tears down
// into a `jmp` back to the prologue. Tail recursion is then constant
// space.

def is_self_call(st: EmitSt, node: Call) -> bool {
    // `self(...)`, or a call naming the function being emitted (after
    // rename every def has a unique name, so the label decides).
    if (node.k == K.call) {
        let cal = node.callee;
        if (cal.k == K.id) {
            let id: Leaf = cal;
            let cv: str = id.v;
            if (cv == "self") {
                true
            } else {
                let ee = env_find(st, cv);
                ee.kind == "func" && ee.label == st.self_label
            }
        } else {
            false
        }
    } else {
        false
    }
};

def gen_tail_call(st: EmitSt, node: Call) -> EmitSt {
    let targs = node.args;
    let n = len(targs);
    let tptypes = fn_args_of(cur_fn_type(st));
    // evaluate each argument into a fresh local
    let offs: [long] = [];
    for i in 0..n {
        st = i < len(tptypes) ? gen_as(st, targs[i], tptypes[i]) : gen(st, targs[i]);
        let off = (st.slots + st.temp + 1) * -8;
        st = st_temp(st, st.temp + 1);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, off, -1);
        offs += off;
    };
    // copy the locals over the parameter slots (param k: 16 + 8*(n-1-k))
    for j in 0..n {
        let po = 16 + 8 * (n - 1 - j);
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, offs[j], -1, insn.R_RAX, 64);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, po, -1);
    };
    // tear down this frame and re-enter the prologue; the return address
    // of the original call stays where it is, so the caller sees a normal
    // return.
    st = emit_insn(st, insn.F_MOV_R_R, insn.R_RBP, 64, insn.R_RSP, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_POP_R, insn.R_RBP, 64, 0, 0, 0, 0, 0);
    emit_insn(st, insn.F_JMP_L, st.self_label, 0, 0, 0, 0, 0, 0)
};

def gen_tail(st: EmitSt, node: Node) -> EmitSt {
    let k = node.k;
    if (k == K.ret) {
        let ret: Wrap = node;
        let e: Node = ret.e;
        if (e.k == K.call) {
            let call: Call = e;
            if (is_self_call(st, call)) {
                gen_tail_call(st, call)
            } else {
                st = gen_as(st, e, cur_fn_ret(st));
                emit_insn(st, insn.F_JMP_L, st.end_label, 0, 0, 0, 0, 0, 0)
            }
        } else {
            st = gen_as(st, e, cur_fn_ret(st));
            emit_insn(st, insn.F_JMP_L, st.end_label, 0, 0, 0, 0, 0, 0)
        }
    } else if (k == K.call) {
        let call: Call = node;
        if (is_self_call(st, call)) {
            gen_tail_call(st, call)
        } else {
            gen_as(st, call, cur_fn_ret(st))
        }
    } else if (k == K.block) {
        let block: Block = node;
        let tl: [Node] = block.stmts;
        let m = len(tl);
        // a trailing `;` (void) leaves the statement before it in tail
        // position: the block's value is void either way
        if (m > 1 && is_void_node(tl[m - 1])) { m = m - 1; }
        let tdepth = st.temp;
        for ti in 0..m - 1 {
            st = gen_loc_stmt(st, tl[ti]);
            st = gen_stmt(st, tl[ti]);
            st = st_temp(st, tdepth);
        };
        if (m > 0) {
            let lastn = tl[m - 1];
            st = gen_loc_stmt(st, lastn);
            st = gen_tail(st, lastn);
        }
        st
    } else if (k == K.kw_if) {
        let branch: If = node;
        let jcc = int_cmp_jcc(st, branch.cond);
        if (jcc == 0) { st = gen(st, branch.cond); }
        let rl1 = next_loc(st);
        st = rl1.st;
        let lelse = rl1.label;
        let rl2 = next_loc(st);
        st = rl2.st;
        let lend = rl2.label;
        if (jcc != 0) {
            // the flags come from the comparison itself (see int_cmp_jcc)
            let cbin: Bin = branch.cond;
            st = gen_cmp_flags(st, cbin);
            st = emit_insn(st, jcc, lelse, 0, 0, 0, 0, 0, 0);
        } else {
            st = emit_insn(st, insn.F_TEST_R_R, insn.R_RAX, 64, insn.R_RAX, 64, 0, 0, 0);
            st = emit_insn(st, insn.F_JZ_L, lelse, 0, 0, 0, 0, 0, 0);
        };
        st = gen_tail(st, branch.then);
        if (branch.has_else) {
            st = emit_insn(st, insn.F_JMP_L, lend, 0, 0, 0, 0, 0, 0);
            st = emit_label(st, lelse);
            st = gen_loc_elif(st, branch.els);
            st = gen_tail(st, branch.els);
            emit_label(st, lend)
        } else {
            st = emit_label(st, lelse)
        }
    } else {
        gen_as(st, node, cur_fn_ret(st))
    }
};

def gen_block(st: EmitSt, node: Block) -> EmitSt {
    gen_block_as(st, node, false)
};

// `dropped`: nobody takes the block's value (a loop body), so its last
// statement is a statement (gen_stmt) as well as the ones before it.
def gen_block_as(st: EmitSt, node: Block, dropped: bool) -> EmitSt {    // No scope push: names are unique post-rename, so a block reuses the slots of the blocks around it.
    let stmts = node.stmts;
    if (len(stmts) == 0) {
        emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0)
    } else {
        // The frame is the DEEPEST block's slots, not the sum of them all: the
        // slots a block takes are released as it ends. Sound because nothing
        // outside reads them -- a name it declared is out of scope there (the
        // checker agrees), and a captured variable lives in a heap cell that a
        // closure reaches through its own captures, not through this slot.
        let depth = st.slots;
        let tdepth = st.temp;
        let m = len(stmts);
        if (m > 1 && is_void_node(stmts[m - 1])) { m = m - 1; }
        for i in 0..m {
            st = gen_loc_stmt(st, stmts[i]);
            st = dropped || i < len(stmts) - 1 ? gen_stmt(st, stmts[i]) : gen(st, stmts[i]);
            // this statement's own temporaries are dead; the ones of the
            // statement this block sits in are not, hence the depth and not 0.
            st = st_temp(st, tdepth);
        };
        st_slots(st, depth)
    }
};

def is_void_node(n: Node) -> bool {
    let k: long = n.k;
    k == K.void
};

// ── -g: line markers (see dbg_lines) ──────────────────────────────────

// The marker for line `ln` of the spliced program: its origin file's
// `.file` number (the index + 1) and its line there, counted on past the
// end of the map like origin_at. Line 0 is DWARF's "no source line".
def loc_pos(ln: long) -> { file: long, line: long } {
    let f = dbg_file;
    let l = dbg_line;
    let n = len(f);
    if (ln < 1 || n == 0) {
        { file: 1, line: ln }
    } else {
        let k = ln;
        if (k > n) { k = n; }
        { file: f[k - 1] + 1, line: l[k - 1] + ln - k }
    }
};

// The marker as an IR item: the line table reads (file, line) as fields, not
// out of the text (link_locs renumbered a `.loc` per body by splitting the
// string; that goes with stage 2b).
def emit_loc(st: EmitSt, ln: long) -> EmitSt {
    let p = loc_pos(ln);
    emit_insn(st, insn.IR_LOC, p.file, p.line, 0, 0, 0, 0, 0)
};

// The marker as an IR item appended to a buffer (the body assembled around the
// function's own items, in emit_one_fn).
def ir_loc(body: [long], ln: long) -> [long] {
    let p = loc_pos(ln);
    insn.ir_push(body, insn.IR_LOC, p.file, p.line, 0, 0, 0, 0, 0)
};

// A statement's marker, before its code. A bare `;` has no position (and
// no code).
def gen_loc_stmt(st: EmitSt, node: Node) -> EmitSt {
    if (dbg_lines) {
        if (is_void_node(node)) { st } else { emit_loc(st, node.line) }
    } else {
        st
    }
};

// An `else if` gets a marker of its own: its test would otherwise count
// as the last line of the branch before it.
def gen_loc_elif(st: EmitSt, els: Node) -> EmitSt {
    if (dbg_lines) {
        let k: long = els.k;
        if (k == K.kw_if) { emit_loc(st, els.line) } else { st }
    } else {
        st
    }
};

// A loop's back edge (its step, the counter's increment, the jump to the
// test) belongs to the loop's own line, not to the body's last one.
def gen_loc_loop(st: EmitSt, node: Node) -> EmitSt {
    if (dbg_lines) { emit_loc(st, node.line) } else { st }
};

// The `.file N "path"` table the markers number into: one per origin
// file, N = its index + 1.
def file_dirs(files: [str]) -> str {
    let pieces: [str] = [];
    files.foreach((e, i) => {
        let fname: str = e;
        pieces += ".file " + tostring(i + 1) + " \"" + esc_asm(fname) + "\"\n";
    });
    join(pieces, "")
};

// Position of `name` in a record literal's merged field list, or -1.
def mfield_idx(names: [str], name: str) -> long {
    let i = 0;
    let out = -1;
    while (i < len(names)) {
        let nm: str = names[i];
        if (nm == name) {
            out = i;
        }
        i++;
    };
    out
};

// ── records at run time ────────────────────────────────────────────────
// A record is laid out by field name: its fields sorted, the one in slot
// i at record+8i, whatever order a literal or a type writes them in --
// but one held in a union value has the union's shared fields first
// ("union layouts" below). The word at record-8 points to the descriptor of its type, `ytt_<hash>`:
// one per structural type, named by a 64-bit FNV-1a hash of the type's
// canonical form (tcanon). Each unit emits the descriptors its code uses
// (ty_desc), and the link keeps one per label (link_units). The canonical
// form travels with the descriptor, so two types with one hash are an
// error, never a merge. A descriptor is one byte: its address is the tag
// that `match`, a union's printer, a pattern's field read and a cast
// compare.

// FNV-1a over the bytes of s, 64-bit (the multiply wraps).
def fnv64(s: str) -> long {
    let h = -3750763034362895579;
    for i in 0..len(s) {
        h = (h ^ s[i]) * 1099511628211;
    };
    h
};

// h as 16 lowercase hex digits.
def hex16(h: long) -> str {
    let digits = "0123456789abcdef";
    let out = "";
    let sh = 60;
    while (sh >= 0) {
        let d = (h >>> sh) & 15;
        out += digits[d:d + 1];
        sh -= 4;
    };
    out
};

// The slot of field `key` in a record of the fields fs: how many of their
// names sort before it (-1 when there is no such field).
def rec_slot(fs: [Field], key: str) -> long {
    let found = false;
    let below = 0;
    for i in 0..len(fs) {
        let fname: str = fs[i].name;
        if (fname == key) { found = true; }
        else if (fname < key) { below++; }

    };
    if (found) { below } else { -1 }
};

// Adds the descriptor label lbl, of canonical form `form`, to ty_seen: 1
// when it is new, 0 when it is there with that form, -1 when it is there
// with another (two types, one hash).
def tyset_add(lbl: str, form: str) -> long {
    if (2 * (ty_count + 1) > len(ty_seen)) { tyset_grow(); };
    let mask = len(ty_seen) - 1;
    let i = fnv64(lbl) & mask;
    let out = 1;
    while (true) {
        let cur: str = ty_seen[i];
        if (len(cur) == 0) {
            ty_seen[i] = lbl;
            ty_forms[i] = form;
            ty_count++;
            break;
        } else if (cur == lbl) {
            let had: str = ty_forms[i];
            out = had == form ? 0 : -1;
            break;
        } else {
            i = (i + 1) & mask;
        };
    };
    out
};

def tyset_grow() -> void {
    let old = ty_seen;
    let oldf = ty_forms;
    let cap = 2 * len(old);
    if (cap < 64) { cap = 64; };
    let fresh: [str] = [];
    let freshf: [str] = [];
    for i in 0..cap {
        fresh += "";
        freshf += "";
    };
    ty_seen = fresh;
    ty_forms = freshf;
    ty_count = 0;
    old.foreach((e, j) => {
        let lb: str = e;
        if (len(lb) > 0) { tyset_add(lb, oldf[j]); };
    });
};

def tyset_reset() -> void {
    let none: [str] = [];
    let nonef: [str] = [];
    ty_seen = none;
    ty_forms = nonef;
    ty_count = 0;
    // the signature cache's buckets are made when first used (ty_sig_init)
    let nobkts: [[long]] = [];
    ty_sig_bkts = nobkts;
    let nonodes: [Type] = [];
    let novals: [[str]] = [];
    ush_nodes = nonodes;
    ush_vals = novals;
};

def ty_sig_init() -> void {
    let nokeys: [str] = [];
    let noids: [long] = [];
    let bkts: [[long]] = [];
    for i in 0..512 {
        let b: [long] = [];
        bkts += b;
    };
    ty_sig_keys = nokeys;
    ty_sig_ids = noids;
    ty_sig_bkts = bkts;
};

// The canonical form of record type rt (types.y tcanon). A record type
// spelled out that equals a recursive alias (alias_of) takes the alias's
// form.
def ty_form(rt: Type) -> str {
    let rk: long = rt.k;
    if (rk == K.trec) {
        let al = alias_of(rt);
        if (al.k == K.tref) { types.tcanon(al) } else { types.tcanon(rt) }
    } else {
        types.tcanon(rt)
    }
};

// The recursive alias equal (types.y teq) to record type t, spelled out --
// a record literal's inferred type, say ({k: long, to: Type} is the alias
// TPtr) -- among the aliases reachable from t; tnone when none is. Equal
// types must have one descriptor, or a read through a union holding the
// record finds no member's tag.
def alias_of(t: Type) -> Type {
    let trec: TRec = t;
    let names = join(types.rec_names(trec.fields), ",");
    let seen: [str] = [];
    let todo: [Type] = [];
    todo += t;
    let found: Type = { k: K.tnone };
    let looking = true;
    let i = 0;
    while (looking && i < len(todo)) {
        let x = todo[i];
        let k: long = x.k;
        if (k == K.tref) {
            let ref: TRef = x;
            let tmp: str = ref.tmp;
            let met = false;
            foreach (s in seen) { if (s == tmp) { met = true; }; };
            if (!met) {
                seen += tmp;
                let u = types.unfold(x);
                if (u.k == K.trec) {
                    let urec: TRec = u;
                    if (join(types.rec_names(urec.fields), ",") == names && types.teq(t, x)) {
                        found = x;
                        looking = false;
                    };
                };
                todo += u;
            };
        } else if (k == K.trec) {
            let r: TRec = x;
            foreach (f in r.fields) { todo += f.typ; };
        } else if (k == K.tunion) {
            let u: TList = x;
            foreach (m in u.ts) { todo += m; };
        } else if (k == K.tfunc) {
            let ftype: TFunc = x;
            foreach (a in ftype.args) { todo += a; };
            todo += ftype.ret;
        } else if (k == K.tmap) {
            let m: TMap = x;
            todo += m.key;
            todo += m.of;
        } else if (k == K.tptr) {
            let p: TPtr = x;
            todo += p.to;
        } else if (k == K.tarrfix) {
            let a: TFix = x;
            todo += a.of;
        } else if (k == K.tarr || k == K.topt) {
            let a: TOf = x;
            todo += a.of;
        };
        i++;
    };
    found
};

// Two types with one descriptor label: stop (a 64-bit hash collision;
// the program cannot be linked with this compiler).
def ty_collision(lbl: str, form: str) -> void {
    puts("ycc: two record types hash to " + lbl + " (" + form + "); cannot link this program\n");
    exit(1);
};

// The descriptor label of record type rt; its rodata entry (label,
// canonical form, quads) goes into the unit the first time the unit uses
// it.
def ty_desc(st: EmitSt, rt: Type) -> StLbl {
    ty_desc_as(st, rt, "")
};

// ty_desc of record type rt laid out as `lay` says ("" for its own
// order; else "@" and the field names in their slots: a member held in a
// union, union_lay).
def ty_desc_as(st: EmitSt, rt: Type, lay: str) -> StLbl {
    let sig = types.tsig(rt) + lay;
    if (len(ty_sig_bkts) == 0) { ty_sig_init(); };
    let h = fnv64(sig) % 512;
    if (h < 0) { h = h + 512; };
    let bkt: [long] = ty_sig_bkts[h];
    let known = -1;
    foreach (ix in bkt) {
        if (known < 0 && ty_sig_keys[ix] == sig) { known = ty_sig_ids[ix]; };
    };
    if (known >= 0) { return { st: st, label: known }; };
    let form = ty_form(rt) + lay;
    let lbl = "ytt_" + hex16(fnv64(form));
    let id = lbl_new(lbl);
    ty_sig_keys += sig;
    ty_sig_ids += id;
    bkt += len(ty_sig_keys) - 1;
    let added = tyset_add(lbl, form);
    if (added < 0) { ty_collision(lbl, form); };
    if (added > 0) {
        // [label, canonical form]: the form only travels for the link's
        // collision check; the descriptor is one byte (rodata_pieces)
        let te: [str] = [];
        te += lbl;
        te += form;
        st.rodata += [te];
    };
    { st: st, label: id }
};

// ── union layouts (CHOICES_MADE.md 25) ─────────────────────────────────
// A record held in a union value is laid out with the union's shared
// fields first -- the fields every member has, with one type, sorted --
// then its other fields, sorted; a standalone record has all its fields
// sorted. A shared field is then one load at one offset, whatever the
// member. A value going from one layout to the other is a conversion
// (gen_convert): the record is copied into the other layout where the
// two differ, and its tag names its type in that layout (ty_desc_in).

// The shared fields of union u (unfolded), sorted. Remembered by the
// union's node (ush_nodes, emptied for each unit): a recursive alias
// unfolds to one union node, and every read of a shared field asks.
def union_shared(u: Type) -> [str] {
    let found = -1;
    let i = 0;
    while (found < 0 && i < len(ush_nodes)) {
        if (ush_nodes[i] == u) { found = i; };
        i++;
    };
    if (found >= 0) { return ush_vals[found]; };
    let ms = types.members(u);
    let out: [str] = [];
    if (len(ms) > 0) {
        let fs: [Field] = types.member_fields(ms[0]);
        foreach (f in fs) {
            let ok = true;
            foreach (m in ms) {
                let ft = types.member_field_type(m, f.name);
                if (ok && (ft.k == K.tnone || !types.teq(ft, f.typ))) { ok = false; };
            };
            if (ok) { out += f.name; };
        };
    };
    let sorted = types.str_sorted(out);
    ush_nodes += u;
    ush_vals += [sorted];
    sorted
};

// The slots of member m (unfolded) held in union u (unfolded): the
// field names in slot order.
def union_lay(m: Type, u: Type) -> [str] {
    let sh = union_shared(u);
    let fs: [Field] = types.member_fields(m);
    let rest: [str] = [];
    foreach (f in fs) {
        if (mfield_idx(sh, f.name) < 0) { rest += f.name; };
    };
    let out: [str] = [];
    out += sh;
    out += types.str_sorted(rest);
    out
};

// The slots of a record of type t (unfolded) held where type `in` is
// declared: in a union, union_lay; else its own sorted fields.
def lay_of(t: Type, inu: Type) -> [str] {
    if (inu.k == K.tunion) { union_lay(t, inu) } else {
        types.rec_names(types.member_fields(t))
    }
};

def same_lay(a: [str], b: [str]) -> bool {
    let same = len(a) == len(b);
    let i = 0;
    while (same && i < len(a)) {
        if (a[i] != b[i]) { same = false; };
        i++;
    };
    same
};

// The tag of member m (as written in the union, maybe a tref) held where
// `inu` is declared: its own descriptor where its layout there is its own
// order, else the descriptor of m in that layout.
def ty_desc_in(st: EmitSt, m: Type, inu: Type) -> StLbl {
    let mu = types.unfold(m);
    let lay = lay_of(mu, inu);
    if (same_lay(lay, types.rec_names(types.member_fields(mu)))) { ty_desc(st, m) }
    else { ty_desc_as(st, m, "@" + join(lay, ",")) }
};

// The record in %rax (slots `from`) copied into slots `to`, tagged
// `tag`: a new record in %rax.
def gen_copy_rec(st: EmitSt, from: [str], to: [str], tag: long) -> EmitSt {
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_I_R, 8 * len(to) + 16, insn.R_RDI, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_alloc"), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_LEA_P_R, -1, -1, 1, 0, tag, insn.R_RCX, 64);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RCX, 64, insn.R_RAX, -1, 1, 0, -1);
    st = emit_insn(st, insn.F_POP_R, insn.R_RSI, 64, 0, 0, 0, 0, 0);
    to.foreach((e, i) => {
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RSI, -1, 1, 8 * (mfield_idx(from, e)), -1, insn.R_RCX, 64);
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RCX, 64, insn.R_RAX, -1, 1, 8 + 8 * i, -1);
    });
    emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RAX, 64, 0, 0, 0, 0)
};

// A primitive value in %rax being boxed as a union member: create the
// hidden one-field record (`{ $long: value }`) in the union's layout and
// tag it with the member's descriptor.
def gen_box_prim(st: EmitSt, p: Type, u: Type) -> EmitSt {
    // Tag with the member as the UNION writes it: a structurally equal
    // inferred type can have a different recursive-alias spelling, and the
    // descriptor's signature includes that spelling (tsig).
    let m = types.union_member(u, p);
    if (m.k == K.tnone) { m = p; };
    let mu = types.unfold(m);
    let dr = ty_desc_in(st, m, u);
    st = dr.st;
    let lay = union_lay(mu, u);
    let slot = mfield_idx(lay, types.box_field_name(mu));
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_I_R, 8 * len(lay) + 16, insn.R_RDI, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_alloc"), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_POP_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_LEA_P_R, -1, -1, 1, 0, dr.label, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RDX, 64, insn.R_RAX, -1, 1, 0, -1);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RCX, 64, insn.R_RAX, -1, 1, 8 + 8 * slot, -1);
    emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RAX, 64, 0, 0, 0, 0)
};

// The value in %rax, of static type src0, going where want0 is declared:
// a member into a union, a union into one of its members (`check`: its
// tag is checked first), or a union into another. Each member whose
// layout differs on the two sides is copied (gen_copy_rec); a cast to
// members the value does not hold stops the program (y_cast_trap).
def gen_convert(st: EmitSt, src0: Type, want0: Type, check: bool) -> EmitSt {
    let s = types.unfold(src0);
    let w = types.unfold(want0);
    let sk: long = s.k;
    let wk: long = w.k;
    if (types.is_boxable_type(s) && wk == K.tunion) {
        gen_box_prim(st, s, w)
    } else if (sk == K.tunion && types.is_boxable_type(w)) {
        let m = types.union_member(s, w);
        if (m.k == K.tnone) { m = w; };
        if (check) { st = gen_cast_check(st, [m], s); };
        let mu = types.unfold(m);
        gen_slot_move(st, (mfield_idx((union_lay(mu, s)), types.box_field_name(mu))), false)
    } else if (sk == K.trec && wk == K.tunion) {
        let m = types.union_member(w, s);
        if (m.k == K.tnone) { st } else {
            let from = lay_of(s, src0);
            let to = union_lay(types.unfold(m), w);
            if (same_lay(from, to)) { st } else {
                let dr = ty_desc_in(st, m, w);
                st = dr.st;
                gen_copy_rec(st, from, to, dr.label)
            }
        }
    } else if (sk == K.tunion && (wk == K.trec || wk == K.tunion)) {
        let within = union_within(s, want0);
        // one union into another sharing the same fields: every member
        // keeps its layout and tag
        if (within && wk == K.tunion && same_lay(union_shared(s), union_shared(w))) { return st; };
        let ms: [Type] = [];
        ms = within ? types.union_parts(s) : cast_members(s, want0);
        // per member: its slots and tag here, its slots and tag there
        let froms: [[str]] = [];
        let tos: [[str]] = [];
        let tws: [Type] = [];
        let moves = false;
        foreach (m in ms) {
            let mu = types.unfold(m);
            let from = union_lay(mu, s);
            let tw: Type = m;
            if (wk == K.tunion) {
                let mw = types.union_member(w, m);
                if (mw.k != K.tnone) { tw = mw; };
            };
            let to = lay_of(mu, w);
            froms += [from];
            tos += [to];
            tws += tw;
            if (!same_lay(from, to)) { moves = true; };
        };
        if (!moves) {
            if (within || !check) { st } else { gen_cast_check(st, ms, s) }
        } else {
            let done = next_loc(st);
            st = done.st;
            st = emit_insn(st, insn.F_MOV_D_R, insn.R_RAX, -1, 1, -8, -1, insn.R_RCX, 64);
            let lbls: [long] = [];
            let i = 0;
            while (i < len(ms)) {
                let l = next_loc(st);
                st = l.st;
                lbls += l.label;
                let dr = ty_desc_in(st, ms[i], s);
                st = dr.st;
                st = emit_insn(st, insn.F_LEA_P_R, -1, -1, 1, 0, dr.label, insn.R_RDX, 64);
                st = emit_insn(st, insn.F_CMP_R_R, insn.R_RDX, 64, insn.R_RCX, 64, 0, 0, 0);
                st = emit_insn(st, insn.F_JE_L, l.label, 0, 0, 0, 0, 0, 0);
                i++;
            };
            st = emit_insn(st, insn.F_JMP_L, lbl_new("y_cast_trap"), 0, 0, 0, 0, 0, 0);
            i = 0;
            while (i < len(ms)) {
                st = emit_label(st, lbls[i]);
                let from: [str] = froms[i];
                let to: [str] = tos[i];
                if (!same_lay(from, to)) {
                    let dr = ty_desc_in(st, tws[i], w);
                    st = dr.st;
                    st = gen_copy_rec(st, from, to, dr.label);
                };
                // not on the last arm: that one falls through into `done:`
                if (i < len(ms) - 1) { st = emit_insn(st, insn.F_JMP_L, done.label, 0, 0, 0, 0, 0, 0); };
                i++;
            };
            emit_label(st, done.label)
        }
    } else { st }
};

// lt (a record literal's type) is the record type t: the same field names
// and equal types.
def same_rec(lt: Type, t: Type) -> bool {
    let tk: long = t.k;
    let lk: long = lt.k;
    if (tk != K.trec || lk != K.trec) { false }
    else {
        let lrec: TRec = lt;
        let trec: TRec = t;
        let lfs: [Field] = lrec.fields;
        let tfs: [Field] = trec.fields;
        if (len(lfs) != len(tfs)) { false } else { types.teq(lt, t) }
    }
};

// The type a record literal of type lt is created as when it goes where
// `want` is declared (gen_as): want itself when lt is that record type,
// the first member of a union want that lt is; lt otherwise.
def rec_lit_type(lt: Type, want: Type) -> Type {
    let w: Type = types.unfold(want);
    let wk: long = w.k;
    if (wk == K.trec) {
        if (same_rec(lt, w)) { want } else { lt }
    } else if (wk == K.tunion) {
        let ms = types.union_parts(w);
        let found: Type = lt;
        let looking = true;
        let i = 0;
        while (looking && i < len(ms)) {
            if (same_rec(lt, types.unfold(ms[i]))) { found = ms[i]; looking = false; }
            i++;
        };
        found
    } else { lt }
};

// Record literal { k: v, ... }: heap-allocate the descriptor word and the
// fields, store the descriptor, then evaluate the values in the order they
// are written, each into its field's slot (see "records at run time"; a
// member of a declared union in the union's layout). The
// VALUE is the record address (8 bytes, first-class: locals, params,
// returns all just copy it). `want` is the type declared where the record
// goes (gen_as; tnone for none): a literal of that record type, or of a
// member of that union, is created as it (rec_lit_type), so its descriptor
// names the declared type -- `{a: none}` stored as a {a: long?} is one.
// (y_alloc(0) is fine — bump allocators return a valid, if empty, block;
// empty maps are rejected by the checker anyway.)
def gen_reclit(st: EmitSt, node: RecLit, want: Type) -> EmitSt {
    let mvals: [Node] = node.vals;
    let mkeys: [str] = node.keys;
    let nent = len(mvals);
    // Static merge for `...` spread entries (the types.y field_merge
    // rule): a later entry wins the value. The value loop below stores
    // into the fields' slots in entry order, so a later store simply
    // overwrites -- no dynamic shape.
    let names: [str] = [];
    for ni in 0..nent {
        let nk = mkeys[ni];
        if (nk == "...") {
            let srec = infer(st, mvals[ni]);
            if (srec.k == K.trec) {
                let spread: TRec = srec;
                let sfs: [Field] = spread.fields;
                sfs.foreach((sf) => {
                    if (mfield_idx(names, sf.name) < 0) {
                        names += sf.name;
                    }
                });
            }
        } else {
            if (mfield_idx(names, nk) < 0) {
                names += nk;
            }
        };
    };
    let rt: Type = types.lit_target(node, want);
    if (rt.k == K.tnone) { rt = rec_lit_type(infer(st, node), want); }
    let rtu: Type = types.unfold(rt);
    // the declared type's optional fields the literal leaves out have their
    // slots too: none, which y_alloc's never-reused zeroed memory already is
    if (rtu.k == K.trec) {
        let trec: TRec = rtu;
        let tfs: [Field] = trec.fields;
        foreach (f in tfs) {
            if (mfield_idx(names, f.name) < 0) { names += f.name; };
        };
    };
    let n = len(names);
    let slots = types.str_sorted(names);
    // made as a member of a declared union: in the union's layout
    let wu: Type = types.unfold(want);
    if (wu.k == K.tunion && rtu.k == K.trec) { slots = union_lay(rtu, wu); };
    let dr = ty_desc_in(st, rt, wu);
    st = dr.st;
    st = emit_insn(st, insn.F_MOV_I_R, 8 * n + 16, insn.R_RDI, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_alloc"), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_LEA_P_R, -1, -1, 1, 0, dr.label, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_POP_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RCX, -1, 1, 0, -1);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
    for i in 0..nent {
        // mv is walked twice (gen, then infer), so bind it once.
        let mv = mvals[i];
        let mk = mkeys[i];
        if (mk == "...") {
            // Spread: the source runs ONCE; copy each of its fields into
            // the slot it has here. A later entry's store overwrites.
            st = gen(st, mv);
            st = emit_insn(st, insn.F_POP_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_RDX, 64, 0, 0, 0);
            let srec2 = infer(st, mv);
            if (srec2.k == K.trec) {
                let spread: TRec = srec2;
                let sfs2: [Field] = spread.fields;
                sfs2.foreach((sf2) => {
                    let mi2 = mfield_idx(slots, sf2.name);
                    // %rdx is the source's record VALUE (slot 0 at +0);
                    // %rcx is the fresh record's ALLOC base (slots at +8).
                    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RDX, -1, 1, 8 * rec_slot(sfs2, sf2.name), -1, insn.R_RSI, 64);
                    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RSI, 64, insn.R_RCX, -1, 1, 8 + mi2 * 8, -1);
                });
            }
        } else {
            let ft = rec_field_type(rtu, mk);
            if (lit_wraps(st, mv, rtu, mk, ft)) {
                // a plain T for an optional field: some(v)
                let fo: TOf = ft;
                st = gen_as(st, mv, fo.of);
                st = gen_box_rax(st);
            } else {
                st = gen_as(st, mv, ft);
            };
            st = emit_insn(st, insn.F_POP_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RCX, -1, 1, 8 + (mfield_idx(slots, mk)) * 8, -1);
        };
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
    };
    st = emit_insn(st, insn.F_POP_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RAX, 64, 0, 0, 0, 0)
};

// Value mv given for field mk of rtu, the record type a literal is created
// as, is wrapped -- some(v) -- when the field is optional and mv a plain T
// (types.y opt_wraps, as typeof_lit decides): its type as the checker
// takes it, a record literal the type it is created as there.
def lit_wraps(st: EmitSt, mv: Node, rtu: Type, mk: str, ft: Type) -> bool {
    let opt = false;
    if (rtu.k == K.trec) {
        let trec: TRec = rtu;
        let tfs: [Field] = trec.fields;
        foreach (f in tfs) { if (f.name == mk && f.opt) { opt = true; }; };
    };
    if (!opt || ft.k != K.topt) { return false; };
    let fo: TOf = ft;
    let vt = infer(st, mv);
    if (mv.k == K.rec) {
        let lt = types.lit_target(mv, fo.of);
        if (lt.k != K.tnone) { vt = lt; };
    };
    types.opt_wraps(vt, ft)
};

// An anonymous `def(...) {...}` used as a value: it has no entry in the
// hoisted table, so give it a fresh label, emit the body here (where the
// capture types are known) and hand back the closure record.
def gen_func_literal(st: EmitSt, node: Func) -> EmitSt {
    let caps = fn_captures(node, st.fns.ix, "");
    let captypes: [Type] = [];
    caps.foreach((e) => {
        let cn: str = e;
        captypes += (env_find(st, cn)).typ;
    });
    let rl = next_uid(st);
    st = rl.st;
    let lbl = lbl_new(arch.arch_fn_label(rl.uid, "anon"));
    let ru = next_uid(st);
    st = ru.st;
    st = emit_one_fn(st, lbl, ru.uid, node, false, false, captypes, "");
    lit_label = lbl;
    caps.foreach((e) => {
        let bcn: str = e;
        st = box_capture(st, bcn);
    });
    gen_make_closure(st, lbl, caps)
};

// Bind `name` to a closure over `func`: emit the body HERE (the enclosing
// env still knows each captured name's type — emit_program deliberately
// skips capturing functions), build the record, store it in a fresh slot.
// Such a function (see capturing_defs) is not in the hoisted table, so it
// gets its label here; its body knows its own name (emit_one_fn).
def gen_closure_binding(st: EmitSt, name: str, func: Func, caps: [str]) -> EmitSt {
    let captypes: [Type] = [];
    caps.foreach((e) => {
        let cn2: str = e;
        captypes += (env_find(st, cn2)).typ;
    });
    let rl = next_uid(st);
    st = rl.st;
    let lbl = lbl_new(fn_label_of(rl.uid, name));
    let ru = next_uid(st);
    st = ru.st;
    st = emit_one_fn(st, lbl, ru.uid, func, false, false, captypes, name);
    caps.foreach((e) => {
        let bcn: str = e;
        st = box_capture(st, bcn);
    });
    st = gen_make_closure(st, lbl, caps);
    // a NAME (let f = ...), so its slot lives to the end of the block
    let coff = (st.slots + 1) * -8;
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, coff, -1);
    let st3 = { ir: st.ir, txt: st.txt, rodata: st.rodata, uid: st.uid,
        fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots + 1,
        temp: st.temp, self_label: st.self_label, end_label: st.end_label,
        fns: st.fns, bodies: st.bodies, btext: st.btext, blabels: st.blabels };
    st3 = env_define(st3, name, "closure", coff, -1, "", func_type_in(st3, func));
    box_bound(st3, name)
};

// ── a global's initializer, delimited ───────────────────────────────────
// A top-level declaration's initialization is a RANGE of instructions -- an
// array or record constant is built element by element -- and a global that
// nothing reads does not need any of it. The link step cannot find that range
// on its own, so the emitter brackets it with two labels named for the cell
// (`ygiS_<cell>` / `ygiE_<cell>`): the linker deletes the range for a dead
// cell and the shake after it drops whatever only that range called.
//
// Only declarations whose target is a GLOBAL get marks: a local `let` inside
// a function is not a global cell and nothing shakes it. The marks' labels are
// minted like any other; an unreferenced label emits nothing.
def gen_decl_marked(st: EmitSt, node: Decl) -> EmitSt {
    let ge = env_find(st, node.name);
    if (ge.kind != "global") {
        gen_decl(st, node)
    } else {
        let cell = lname(ge.label);
        st = emit_label(st, lbl_new("ygiS_" + cell));
        st = gen_decl(st, node);
        emit_label(st, lbl_new("ygiE_" + cell))
    }
};

def gen_decl(st: EmitSt, node: Decl) -> EmitSt {
    if (node.kind == "def") {
        // A nested `def` that captures is a closure just like a let-bound
        // literal; a capture-free one stays hoisted (emitted by
        // emit_program, env pre-bound, calls go direct). Its own name is
        // no capture: the body reaches itself through its own record.
        let func: Func = node.v;
        let dcaps = fn_captures(func, st.fns.ix, node.name);
        if (len(dcaps) == 0) {
            st
        } else {
            gen_closure_binding(st, node.name, func, dcaps)
        }
    } else {
        if (node.v.k == K.func) {
            // let-bound function. Capture-free ones stay pure labels (the
            // env already binds them, calls go direct). One that captures
            // becomes a closure record built HERE, where the captured
            // values are live, and the binding holds that record.
            let func: Func = node.v;
            let caps = fn_captures(func, st.fns.ix, node.name);
            if (len(caps) == 0) {
                st
            } else {
                gen_closure_binding(st, node.name, func, caps)
            }
        } else if (node.v.k == K.arrrep) {
            let rep: ArrRep = node.v;
            // heap array: [v; n] allocates a header {len, cap, data}.
            // Reference value like every other array: the binding holds
            // the header address.
            let t: Type = node.typ;
            if (t.k == K.tnone) {
                t = infer(st, rep);
            };
            let rsz = arr_elem_bytes(t);
            st = gen_arrrep_esz(st, rep, rsz, store_elem_type(t, rsz));
            if (types.unfold(t).k == K.tunion) {
                st = gen_convert(st, infer(st, rep), t, true);
            };
            bind_decl(st, node.name, t)
        } else if (node.v.k == K.array) {
            let array: ArrLit = node.v;
            // Heap array literal. The DECLARED element type decides the
            // element width: `let b: [byte] = [104, 105]` packs, and the
            // literal's own elements only ever infer as long.
            let t: Type = node.typ;
            if (t.k == K.tnone) {
                t = infer(st, array);
            };
            let asz = arr_elem_bytes(t);
            st = gen_array_esz(st, array, asz, store_elem_type(t, asz));
            if (types.unfold(t).k == K.tunion) {
                st = gen_convert(st, infer(st, array), t, true);
            };
            bind_decl(st, node.name, t)
        } else if (node.v.k == K.rec) {
            let rec: RecLit = node.v;
            // record literal: heap address (first-class value, plain slot).
            // An empty literal under a map annotation is the map itself
            // (the {keys, vals, boxes} shape the map ops expect).
            st = unfold(node.typ).k == K.tmap && len(rec.keys) == 0 ? gen_maplit(st, rec) : gen_as(st, rec, node.typ);
            let t: Type = node.typ;
            if (t.k == K.tnone) {
                t = infer(st, rec);
            };
            bind_decl(st, node.name, t)
        } else {
            st = gen_as(st, node.v, node.typ);
            // Reference semantics: arrays and records are heap values and
            // bindings share them (no copy-on-store). Cloning here made
            // every `let x = <call returning [T]>` O(n), so threading an
            // accumulator through helpers was O(n^2) — the assembler's
            // patch loop spent 650MB on a 20KB output. The VM and the C
            // runtime alias too, so all three engines agree.
            // bind with annotation or inferred type
            let t: Type = node.typ;
            if (t.k == K.tnone) {
                t = infer(st, node.v);
            };
            bind_decl(st, node.name, t)
        }
    }
};

// Bind a declared name to the value in %rax: a top-level variable stores
// to its global cell (see emit_program), any other takes a fresh slot.
def bind_decl(st: EmitSt, name: str, t: Type) -> EmitSt {
    let ge = env_find(st, name);
    if (ge.kind == "global") {
        st = emit_insn(st, insn.F_MOV_R_P, insn.R_RAX, 64, -1, -1, 1, 0, ge.label);
        env_define(st, name, "global", 0, ge.label, "", t)
    } else if (t.k == K.tstr && own_wanted(st, name)) {
        bind_own(st, name, t)
    } else {
        let off = (st.slots + 1) * -8;
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, off, -1);
        let st2 = { ir: st.ir, txt: st.txt, rodata: st.rodata, uid: st.uid,
            fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots + 1, temp: st.temp,
            self_label: st.self_label, end_label: st.end_label, fns: st.fns,
            bodies: st.bodies, btext: st.btext, blabels: st.blabels };
        st2 = env_define(st2, name, "local", off, -1, "", t);
        box_bound(st2, name)
    }
};

def gen_assign(st: EmitSt, node: Assign) -> EmitSt {
    let e = env_find(st, node.name);
    // Reference semantics: arrays and records are heap values shared by
    // every binding that names them (no copy-on-store) — the same model
    // the C copy's value model uses (yv.c). A captured variable lives in
    // one shared heap cell (box_capture), so its store goes through the
    // cell and is visible in the capturing scope too.
    st = gen_as(st, node.v, e.typ);
    if (e.kind == "capture") {
        let idx = leading_long(e.mark);
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, e.off, -1, insn.R_RCX, 64);
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RCX, -1, 1, 8 * (idx + 1), -1, insn.R_RDX, 64);
        st = emit_insn(st, insn.F_MOV_R_0, insn.R_RAX, 64, insn.R_RDX, -1, 1, -1, -1);
        st
    } else if (e.kind == "box") {
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, e.off, -1, insn.R_RDX, 64);
        st = emit_insn(st, insn.F_MOV_R_0, insn.R_RAX, 64, insn.R_RDX, -1, 1, -1, -1);
        st
    } else if (e.kind == "global") {
        emit_insn(st, insn.F_MOV_R_P, insn.R_RAX, 64, -1, -1, 1, 0, e.label)
    } else {
        emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, e.off, -1)
    }
};

// Fill n frame slots (base = lowest address) with the value in %rax.
def gen_fill(st: EmitSt, base: long, n: long) -> EmitSt {
    if (n == 0) {
        st
    } else {
        let r = next_loc(st);
        st = r.st;
        st = emit_insn(st, insn.F_MOV_I_R, n, insn.R_RCX, 64, 0, 0, 0, 0);
        st = emit_label(st, r.label);
        st = emit_insn(st, insn.F_DEC_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_R_M, insn.R_RAX, 64, insn.R_RBP, insn.R_RCX, 8, base, -1);
        emit_insn(st, insn.F_JNZ_L, r.label, 0, 0, 0, 0, 0, 0)
    }
};

// Heap-array fill: the header is in %rdx, the fill value in %rax. Writes
// data[i] for i = n-1 .. 0 (data starts at header+16).
def gen_fill_heap(st: EmitSt, n: long, esz: long) -> EmitSt {
    if (n == 0) {
        st
    } else {
        let r = next_loc(st);
        st = r.st;
        st = emit_insn(st, insn.F_MOV_R_R, insn.R_RDX, 64, insn.R_R10, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_RDX, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_I_R, n, insn.R_RCX, 64, 0, 0, 0, 0);
        st = emit_label(st, r.label);
        st = emit_insn(st, insn.F_DEC_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
        st = elem_store_rdx(st, esz, insn.R_R10, insn.R_RCX);
        st = emit_insn(st, insn.F_JNZ_L, r.label, 0, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_R_R, insn.R_R10, 64, insn.R_RDX, 64, 0, 0, 0);
        st
    }
};

// [v; n] as a first-class expression: allocate a heap header
// {len, cap, data...}, fill every slot with v, leave the address in %rax.
// Usable anywhere (let, assign, call argument, return), not just `let`.
def gen_arrrep(st: EmitSt, node: ArrRep) -> EmitSt {
    gen_arrrep_esz(st, node, elem_bytes(infer(st, node.v)), type_node({ k: K.tnone }))
};

// Same, with the element width supplied by the declaration (`let b:
// [byte; 4] = [0; 4]` — the literal's own elements infer as long), and
// `ety` the element type the fill value converts to (store_elem_type).
def gen_arrrep_esz(st: EmitSt, node: ArrRep, esz: long, ety: Type) -> EmitSt {
    let n = node.n;
    st = gen_as(st, node.v, ety);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_I_R, arr_alloc_size(esz, n), insn.R_RDI, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_alloc"), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_I_R, arr_header_size(), insn.R_RDI, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_alloc"), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_POP_R, insn.R_RDX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_I_0, n, insn.R_RAX, -1, 1, -1, -1, 0);
    st = emit_insn(st, insn.F_MOV_I_D, n, insn.R_RAX, -1, 1, 8, -1, 0);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RDX, 64, insn.R_RAX, -1, 1, 16, -1);
    st = emit_insn(st, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_RDX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_POP_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen_fill_heap(st, n, esz);
    emit_insn(st, insn.F_MOV_R_R, insn.R_RDX, 64, insn.R_RAX, 64, 0, 0, 0)
};

// Radix literals (0x../0b..) reach the emitter as their source text; the
// assembler only understands plain decimal immediates, so normalize here.
def hexval_ch(c: str) -> long {
    let o = ord(c);
    let v = 0;
    if (o >= '0') {
        if (o <= '9') { v = o - '0'; }
    }
    if (o >= 'a') {
        if (o <= 'f') { v = o - 'a' + 10; }
    }
    if (o >= 'A') {
        if (o <= 'F') { v = o - 'A' + 10; }
    }
    v
};

// A numeric literal denotes a float when it has a fraction or an exponent.
// Radix literals are checked first: 0xE1 and 0xbeef contain 'e'/'E'/'b'.
def lit_is_float(s: str) -> bool {
    // the one prefix test (lexer.y radix_of); this was a copy of types.y's
    if (radix_of(s) != 0) { false } else {
        let f = false;
        if (index_of(s, ".") >= 0) { f = true; }
        if (index_of(s, "e") >= 0) { f = true; }
        if (index_of(s, "E") >= 0) { f = true; }
        f
    }
};

def norm_num(s: str) -> str {
    let radix = radix_of(s);
    if (radix == 0) {
        s
    } else {
        let v = 0;
        for i in 2..len(s) {
            let c = s[i:i + 1];
            if (!(c == "_")) {
                v = v * radix + hexval_ch(c);
            };
        };
        tostring(v)
    }
};

// ── float literals ──────────────────────────────────────────────────────
//
// A float literal's value is decided HERE, at compile time, and emitted as the
// constant it is: its IEEE-754 bits, one `mov`. It used to be built by the
// generated code instead -- the dotless digits as a long, then multiplied or
// divided by a power of ten in chunks of 18 so each factor would be exact --
// which is wrong four ways at once: a mantissa of more than 19 digits wraps,
// one of more than 15 significant digits is already 1-2 ulp off before the
// scaling starts, a net power of ten past 18 is rounded twice, and an exponent
// in the thousands emitted millions of mul/div (a 19-byte source reached
// 402 MB of compiler and a 1 MB binary; 1e10000000 killed it).
//
// The value is d x 10^dp with d the literal's digits. It is scaled up by 2^T
// into an EXACT integer held in a small decimal bignum -- multiply by ten when
// dp > 0, scale by 2^T and divide by ten when dp < 0 -- and the top 54 bits of
// that integer are the significand and the round bit. Every step is exact and
// every intermediate stays far inside 2^63 (a limb is 10^9, so limb x 2^32 <
// 4.4e18). What the floor drops, and every bit shifted out below the
// significand, is `sticky`; so the significand is rounded ONCE, at the end, to
// nearest even -- which is what strtod, C's printf and Python all do.
//
// Checked against Python's float() on 120 000 literals (every exponent range,
// the subnormal edges, DBL_MAX, exact ties, 30-digit mantissas, 2^53 and 2^63
// boundaries): no mismatches. See test/y/native/t171_float_literal_rounding.y.
//
// The limbs are sized per literal (flit_size) rather than fixed, because the
// loops over them are what the conversion costs: an ordinary literal needs
// nine of them and a subnormal forty-five, out of the FLIT_LIMBS a runaway
// exponent would need.

const FLIT_LIMBS = 128;                // 128 limbs of 9 digits: 1152 digits
// (enough for the longest decimal that can still be a dyadic rational: a
// literal sitting exactly on a rounding boundary below 2^-1000 needs 750-odd
// digits, and the exactness of those digits is what decides the tie)
const FLIT_BASE = 1000000000;

// The limbs a literal needs: its digits, a factor of ten per positive dp, the
// 2^T scaling (a 2^32 is 10 digits), and room for the compare constants.
def flit_size(ndig: long, dp: long, t: long) -> long {
    let g = dp;
    if (dp < 0) { g = 0; };
    let n = (ndig + g + (t / 32) * 10 + 24) / 9 + 2;
    if (n > FLIT_LIMBS) { FLIT_LIMBS } else { n }
};

// acc *= m (m = 10 or 4294967296). false when it outgrows the limbs.
def flit_dmul(a: [long], m: long, n: long) -> bool {
    let carry = 0;
    for i in 0..n {
        let p = a[i] * m + carry;
        a[i] = p % FLIT_BASE;
        carry = p / FLIT_BASE;
    };
    carry == 0
};

// acc /= m (m = 10 or 2), giving the remainder -- a dropped digit, or a bit.
def flit_ddiv(a: [long], m: long, n: long) -> long {
    let rem = 0;
    let i = n - 1;
    while (i >= 0) {
        let cur = rem * FLIT_BASE + a[i];
        a[i] = cur / m;
        rem = cur % m;
        i = i - 1;
    };
    rem
};

// acc *= 10^9: every limb moves up one and the top one carries out. The limb
// base is 10^9, so this is a shift, not a multiply -- and the exponent of a
// literal is spent on exactly these steps.
def flit_dmul_limb(a: [long], n: long) -> bool {
    let carry = 0;
    for i in 0..n {
        let v = a[i];
        a[i] = carry;
        carry = v;
    };
    carry == 0
};

// acc /= 10^9: the lowest limb drops out whole. What was in it is below the
// significand, so the caller looks at it for sticky first.
def flit_ddiv_limb(a: [long], n: long) -> void {
    for i in 0..n - 1 {
        a[i] = a[i + 1];
    };
    a[n - 1] = 0;
};

// a > c, both limb arrays. STRICTLY greater: equal limbs fall off the end with
// the answer still false, which is what the name now says -- it used to claim
// ">=" and the narrowing below believed it, which cost an exponent (and a
// factor of two) on every literal that was an exact power of two, smallest
// normal included. c may be more than one limb (2^62 is one, but the comparison
// is written for any of them).
def flit_dgt(a: [long], c: [long], n: long) -> bool {
    let i = n - 1;
    let r = false;
    let go = true;
    while (i >= 0 && go) {
        if (a[i] != c[i]) {
            r = a[i] > c[i];
            go = false;
        } else {
            i = i - 1;
        }
    };
    r
};

// a < c, the mirror. Written out rather than reusing dgt on the complement so
// the limb walk stays a single pass with no extra carry to reason about.
def flit_dlt(a: [long], c: [long], n: long) -> bool {
    let i = n - 1;
    let r = false;
    let go = true;
    while (i >= 0 && go) {
        if (a[i] != c[i]) {
            r = a[i] < c[i];
            go = false;
        } else {
            i = i - 1;
        }
    };
    r
};

def flit_dzero(a: [long], n: long) -> bool {
    let i = 0;
    let z = true;
    while (i < n) {
        if (a[i] != 0) { z = false; };
        i++;
    };
    z
};

// acc * 10 + one more digit. `n` is the limb count this literal needs, not
// FLIT_LIMBS: a pass over the whole bignum per digit is only expensive if the
// bignum is sized for the worst case, and a literal needs a handful of limbs.
def flit_dpush(a: [long], dg: long, n: long) -> bool {
    if (!flit_dmul(a, 10, n)) { false } else {
        a[0] = a[0] + dg;
        true
    }
};

// A fresh copy, zero-padded to n limbs: the digits arrive with only the limbs
// they needed, and the scale is retried with a bigger t, so they must survive
// each attempt whole.
def flit_copy(a: [long], n: long) -> [long] {
    let out: [long] = [];
    for i in 0..n {
        if (i < len(a)) { out += a[i]; } else { out += 0; };
    };
    out
};

// The digits of d as n limbs (d fits a long).
def flit_dfrom(d: long, n: long) -> [long] {
    let a: [long] = [];
    let rest = d;
    for i in 0..n {
        a += rest % FLIT_BASE;
        rest = rest / FLIT_BASE;
    };
    a
};

// digits x 10^dp x 2^t, floored, as n limbs. `flags[0]` is set when the floor
// dropped something -- that is the sticky -- and `flags[1]` when the value
// outgrew the limbs, which means inf.
def flit_scaled(digs: [long], n: long, dp: long, t: long, flags: [bool]) -> [long] {
    let a = flit_copy(digs, n);
    let j = 0;
    while (j < t / 32) {
        if (flit_dmul(a, 4294967296, n)) { j++; } else { flags[1] = true; j = t / 32; };
    };
    // Nine decades per pass: a limb is 10^9, so multiplying by it moves the
    // value up one limb and dividing drops the lowest limb outright (whatever
    // was in it is below the significand -- sticky). One pass per decade made
    // 1e300 cost 300 of them, and the exponent, not the digits, is what a
    // literal like that spends its time on.
    if (dp > 0) {
        let k = dp;
        while (k >= 9) {
            if (flit_dmul_limb(a, n)) { k = k - 9; } else { flags[1] = true; k = 0; };
        };
        while (k > 0) {
            if (flit_dmul(a, 10, n)) { k = k - 1; } else { flags[1] = true; k = 0; };
        };
    } else {
        let k = 0 - dp;
        while (k >= 9) {
            if (a[0] != 0) { flags[0] = true; };
            flit_ddiv_limb(a, n);
            k = k - 9;
        };
        while (k > 0) {
            if (flit_ddiv(a, 10, n) != 0) { flags[0] = true; };
            k = k - 1;
        };
    };
    a
};

// The significand, the round bit and the exponent, then ONE rounding.
def flit_finish(digs: [long], ndig: long, dp: long, neg: bool) -> long {
    let flags = [false, false];
    // How big the value is, to pick the scale: D x 10^dp with D ndig digits
    // lies between 10^(ndig-1+dp) and 10^(ndig+dp), and log2(10) is 3.322, so
    // (ndig+dp)*33219/10000 puts the binary exponent within two of the truth.
    // Only the SIZE matters here -- a guess too low is caught by the loop below
    // and a guess too high costs a few passes -- so this is not where the
    // literal's value is decided.
    let t = 62 - ((ndig + dp) * 33219 / 10000) + 4;
    // t must clear -dp, which is where dividing by ten stops being exact. A
    // literal that sits exactly on a rounding boundary is a dyadic rational --
    // v = (2^53+1) x 2^(e-53) -- so its decimal form is d x 10^-k with d
    // divisible by 5^k, and d x 2^t / 10^k comes out WHOLE for t >= k. Below
    // that the fractional bits a tie must not have turn into a sticky, and the
    // tie rounds up instead of to even (the scale above clears it by 13 bits on
    // its own; this makes it local instead of an argument about digits).
    if (dp < 0 && t < 0 - dp) { t = 0 - dp; };
    if (t < 0) { t = 0; };
    // whole 2^32 steps, the only way flit_scaled scales by a power of two
    t = (t + 31) / 32 * 32;
    if (t > 1216) { t = 1216; };
    let n = flit_size(ndig, dp, t);
    let a = flit_scaled(digs, n, dp, t, flags);
    // p62 and p85 are rebuilt with the value below whenever the scale grows, so
    // a comparison always has n limbs on both sides. 2^62 is the largest power
    // of two a long holds (writing 2^64 wraps silently); 2^85 = 2^62 x 2^23.
    let p62 = flit_dfrom(4611686018427387904, n);
    let p85 = flit_copy(p62, n);
    flit_dmul(p85, 8388608, n);
    // The scale has to leave the scaled value above 2^85, so that narrowing it
    // to the significand 32 bits at a time cannot drop a bit of it -- the
    // narrowing stops at 2^62, and a whole pass below that could land anywhere
    // in [2^30, 2^62). One 32-bit step of growth is the most it can overshoot by.
    // 1216 is past what any subnormal needs (1074 + 85): past that a zero really
    // does mean the value is below the smallest double, and growing further would
    // only overflow the limbs and turn zero into inf.
    while (!flags[1] && flit_dlt(a, p85, n) && t < 1216) {
        t = t + 32;
        n = flit_size(ndig, dp, t);
        a = flit_scaled(digs, n, dp, t, flags);
        p62 = flit_dfrom(4611686018427387904, n);
        p85 = flit_copy(p62, n);
        flit_dmul(p85, 8388608, n);
    };
    if (flags[1]) {
        if (neg) { 0xFFF0000000000000 } else { 0x7FF0000000000000 }
    } else if (flit_dzero(a, n)) {
        // below the smallest subnormal
        if (neg) { 0x8000000000000000 } else { 0 }
    } else {
        // Narrow the scaled value to its significand, keeping every bit lost
        // below the significand.
        //
        // Scale up first if it is short: exact, and nothing has been dropped
        // yet, so it cannot lose anything.
        // sized like the value itself: a compare constant built at the full
        // FLIT_LIMBS is 128 pushes per literal, which is more than the rest of
        // an ordinary literal costs
        let p53 = flit_dfrom(9007199254740992, n);               // 2^53
        let p54 = flit_dfrom(18014398509481984, n);              // 2^54
        while (flit_dlt(a, p53, n)) {
            flit_dmul(a, 2, n);
        };
        // Then 32 bits a pass while the value is over 2^85, which is where the
        // scale above leaves it: a whole pass there can only drop bits far
        // above the significand, so it lands in [2^53, 2^85). 1e300 is 2^997,
        // and a pass per bit wanted 935 of them -- two thirds of the whole
        // conversion.
        let down = 0;
        while (flit_dgt(a, p85, n)) {
            if (flit_ddiv(a, 4294967296, n) != 0) { flags[0] = true; };
            down += 32;
        };
        // And then a bit at a time down to 2^54: what that leaves is the 53
        // significand bits AND the round bit above them, and everything it
        // dropped is below the round bit, so sticky is all that carries.
        while (!flit_dlt(a, p54, n)) {
            if (flit_ddiv(a, 2, n) != 0) { flags[0] = true; };
            down++;
        };
        // 2^54 fits in two limbs, so the significand and the round bit are one
        // divide apart
        let wide = a[0];
        if (n > 1) { wide = wide + a[1] * FLIT_BASE; };
        let e = 53 + down - t;               // the value is in [2^e, 2^(e+1))
        // A subnormal's significand is the value on the 2^-1074 grid: value is
        // a * 2^(down - t), so the fraction is a shifted right by t - down - 1074
        // -- which is one bit short of -e - 1022, and every subnormal literal
        // with an even significand came out halved when it was that.
        let sh = 0;
        if (e < -1022) { sh = t - down - 1074; };
        let round = 0;
        let mant = 0;
        if (sh == 0) {
            // bit 53 is the round bit and the 53 below it are the significand
            round = wide % 2;
            mant = wide / 2;
        } else {
            // a subnormal shifts the significand right, so the round bit moves
            // up with it and the one below it is sticky
            if ((wide % 2) != 0) { flags[0] = true; };
            let words = sh / 32;
            let bits = sh % 32;
            if (words > 0) {
                let rem = flit_ddiv(a, 4294967296, n);
                round = rem / 2147483648;
                if ((rem % 2147483648) != 0) { flags[0] = true; };
            };
            if (bits > 0) {
                let rem = flit_ddiv(a, 1 << bits, n);
                round = (rem / (1 << (bits - 1))) % 2;
                if ((rem % (1 << (bits - 1))) != 0) { flags[0] = true; };
            };
            // what is left is the fraction itself: no implicit leading bit
            mant = a[0];
            if (n > 1) { mant += a[1] * FLIT_BASE; };
        };
        if (round != 0) {
            if (flags[0]) { mant++; }
            else {
                if ((mant & 1) != 0) { mant++; };
            };
        };
        let bits = 0;
        if (sh > 0) {
            // SUBNORMAL: the significand was shifted right by sh, which lands
            // the value on 2^-1074 times a fraction with no implicit leading
            // bit, so the exponent field is zero and the bits are the fraction
            // itself. A carry out of it is the smallest normal.
            if (mant >= 0x10000000000000) { bits = 0x10000000000000; }
            else { bits = mant; };
        } else {
            let e2 = e;
            if (mant >= 0x20000000000000) {
                mant >>= 1;
                e2 = e + 1;
            };
            bits = e2 > 1023 ? 0x7FF0000000000000 : ((e2 + 1023) << 52) | (mant & 0xFFFFFFFFFFFFF);
        };
        if (neg) { bits | 0x8000000000000000 } else { bits }
    }
};

// Index of the 'e'/'E' that starts the exponent, or len(s) when absent.
def flit_ebase(s: str) -> long {
    let e = index_of(s, "e");
    if (e < 0) { e = index_of(s, "E"); }
    if (e < 0) { len(s) } else { e }
};

// The IEEE-754 bits a decimal float literal denotes, rounded once to nearest
// even -- the same value strtod, C's printf and Python's float() give.
def flit_bits(s: str) -> long {
    let eb = flit_ebase(s);
    let neg = s[0:1] == "-";
    // One pass over the digits: leading zeros dropped, the rest into the
    // bignum. ALL of them, not a fixed count: keeping 18 in a long loses ~1e-18
    // of the value, which is enough to flip a rounding that sits within 1% of
    // its midpoint.
    // One pass to count, one to fill: the bignum has to be sized before the
    // first digit goes in, and sizing it for the worst case made every digit
    // cost a pass over 128 limbs.
    let ndig = 0;
    let nfrac = 0;
    let seen = false;
    let past_dot = false;
    let i = 0;
    if (s[0:1] == "-") { i = 1; };
    if (s[0:1] == "+") { i = 1; };
    while (i < eb) {
        let c = s[i:i + 1];
        if (c == ".") { past_dot = true; } else {
            if (past_dot) { nfrac++; };
            if (seen || c != "0") {
                seen = true;
                ndig++;
            };
        };
        i++;
    };
    let n0 = flit_size(ndig, 0, 0);
    let over = n0 > FLIT_LIMBS;
    if (over) { n0 = FLIT_LIMBS; };
    let a: [long] = [];
    i = 0;
    while (i < n0) { a += 0; i++; };
    seen = false;
    past_dot = false;
    i = 0;
    if (s[0:1] == "-") { i = 1; };
    if (s[0:1] == "+") { i = 1; };
    while (i < eb) {
        let c = s[i:i + 1];
        if (c == ".") { past_dot = true; } else {
            if (seen || c != "0") {
                seen = true;
                if (!flit_dpush(a, c[0] - 48, n0)) { over = true; };
            };
        };
        i++;
    };
    if (!seen) {
        // 0.0, 0e999 -- zero, with the literal's sign
        if (neg) { 0x8000000000000000 } else { 0 }
    } else {
        // the explicit exponent, clamped: a long digit run must not wrap, and
        // types.y rejects a literal whose magnitude is out of range before here
        let ex = 0;
        let eneg = false;
        if (eb < len(s)) {
            let j = eb + 1;
            let sc = s[j:j + 1];
            if (sc == "-") { eneg = true; j = j + 1; };
            if (sc == "+") { j = j + 1; };
            let past = false;
            while (j < len(s)) {
                if (!past) {
                    ex = ex * 10 + (s[j:j + 1][0] - 48);
                    if (ex > 5000) { past = true; ex = 5001; };
                };
                j = j + 1;
            };
            if (eneg) { ex = 0 - ex; };
        };
        if (over) {
            // more digits than the limbs hold: nothing but inf or zero
            if (ex - nfrac > 400) {
                if (neg) { 0xFFF0000000000000 } else { 0x7FF0000000000000 }
            } else {
                if (neg) { 0x8000000000000000 } else { 0 }
            }
        } else {
            flit_finish(a, ndig, ex - nfrac, neg)
        }
    }
};

// The low 64 bits of a decimal literal, as the compiler runs it: the same wrap
// as the runtime's tolong (rt.y, which is where an out-of-range literal becomes
// a value), spelled out so the two agree on it rather than on whatever a C
// library's strtoll clamps to.
//
// norm_num's output, which is decimal but can carry the sign its own radix
// arithmetic wrapped to -- 0xFFFFFFFFFFFFFFFF comes out as "-1" -- and which
// keeps any underscores a decimal literal may hold, so the sign is read
// separately and anything that is not a digit is skipped.
def num_i64(s: str) -> long {
    let v = 0;
    let neg = false;
    for i in 0..len(s) {
        let c = s[i];
        if (c >= '0' && c <= '9') {
            v = v * 10 + c - '0';
        } else {
            if (c == '-' && i == 0) { neg = true; };
        };
    };
    if (neg) { 0 - v } else { v }
};

def gen_lit(st: EmitSt, node: Leaf) -> EmitSt {
    if (lit_is_float(node.v)) {
        // Float literal: its IEEE-754 bits, decided above. Floats live in %rax
        // as raw bits; only arithmetic and comparison use %xmm.
        emit_insn(st, insn.F_MOV_I_R, flit_bits(node.v), insn.R_RAX, 64, 0, 0, 0, 0)
    } else {
        // An integer literal is emitted as its VALUE, not its text: a literal
        // wider than 64 bits runs as its low 64 bits (which is what the
        // compiler has always done -- the checker accepts it and the runtime's
        // tolong wraps), and `mov $18446744073709551616` is not an instruction
        // GNU as can read, so a -S listing of such a program did not assemble
        // at all. norm_num has already turned hex and binary into decimal, so
        // an in-range literal emits exactly the text it did before.
        emit_insn(st, insn.F_MOV_I_R, num_i64(norm_num(node.v)), insn.R_RAX, 64, 0, 0, 0, 0)
    }
};
// 1000n -- parse the literal text at run time into a bigint. The parser
// accepts decimal and 0x/0o/0b forms, so one helper covers every radix.
def gen_biglit(st: EmitSt, node: Leaf) -> EmitSt {
    st = gen_str_const(st, node.v);
    gen_helper1(st, "y_bigint_parse")
};

// Leave `node` in %rax as a bigint: a bigint is already one, a long/byte
// converts exactly, a float truncates toward zero.
def gen_bigint_to(st: EmitSt, node: Node) -> EmitSt {
    let t = infer(st, node);
    st = gen(st, node);
    if (t.k == K.tbigint) {
        st
    } else if (t.k == K.tfloat) {
        gen_helper1(st, "y_bigint_from_float")
    } else {
        gen_helper1(st, "y_bigint_from_long")
    }
};

// Bigint binary operations. The runtime helpers take two stack arguments in
// the ordinary Y order (left, then right) and return a bigint or, for cmp, a
// signed -1/0/1.
def gen_bigint_bin(st: EmitSt, node: Bin, lt: Type, rt: Type) -> EmitSt {
    let op = node.op;
    st = gen_bigint_to(st, node.l);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen_bigint_to(st, node.r);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    let helper = "";
    if (op == "+") { helper = "y_bigint_add"; }
    else if (op == "-") { helper = "y_bigint_sub"; }
    else if (op == "*") { helper = "y_bigint_mul"; }
    else if (op == "/") { helper = "y_bigint_div"; }
    else if (op == "%") { helper = "y_bigint_mod"; }
    else { helper = "y_bigint_cmp"; };
    st = emit_insn(st, insn.F_CALL_L, lbl_new(helper), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0);
    if (op == "<") {
        st = emit_insn(st, insn.F_CMP_I_R, 0, insn.R_RAX, 64, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_SETL_R, insn.R_RAX, 8, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOVZBQ_R_R, insn.R_RAX, 8, insn.R_RAX, 64, 0, 0, 0);
        st
    } else if (op == ">") {
        st = emit_insn(st, insn.F_CMP_I_R, 0, insn.R_RAX, 64, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_SETG_R, insn.R_RAX, 8, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOVZBQ_R_R, insn.R_RAX, 8, insn.R_RAX, 64, 0, 0, 0);
        st
    } else if (op == "<=") {
        st = emit_insn(st, insn.F_CMP_I_R, 0, insn.R_RAX, 64, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_SETLE_R, insn.R_RAX, 8, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOVZBQ_R_R, insn.R_RAX, 8, insn.R_RAX, 64, 0, 0, 0);
        st
    } else if (op == ">=") {
        st = emit_insn(st, insn.F_CMP_I_R, 0, insn.R_RAX, 64, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_SETGE_R, insn.R_RAX, 8, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOVZBQ_R_R, insn.R_RAX, 8, insn.R_RAX, 64, 0, 0, 0);
        st
    } else if (op == "==") {
        st = emit_insn(st, insn.F_CMP_I_R, 0, insn.R_RAX, 64, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_SETE_R, insn.R_RAX, 8, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOVZBQ_R_R, insn.R_RAX, 8, insn.R_RAX, 64, 0, 0, 0);
        st
    } else if (op == "!=") {
        st = emit_insn(st, insn.F_CMP_I_R, 0, insn.R_RAX, 64, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_SETNE_R, insn.R_RAX, 8, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOVZBQ_R_R, insn.R_RAX, 8, insn.R_RAX, 64, 0, 0, 0);
        st
    } else {
        st
    }
};

def gen_index(st: EmitSt, node: Index) -> EmitSt {
    // Checker: an array expression — a plain variable or a nested place
    // (`grid[0][1]`, `rec.v[i]`); the base is evaluated once, here.
    // Bounds-trapped at runtime. Fixed arrays are heap headers now (same
    // layout as heap arrays); only the bound differs: static n for [T; N],
    // runtime len for [T].
    let garr = node.arr;
    let bt = infer(st, garr);
    let ixesz = arr_elem_bytes(bt);
    st = gen(st, garr);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen(st, node.idx);
    st = emit_insn(st, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_RCX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_POP_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_TEST_R_R, insn.R_RCX, 64, insn.R_RCX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JS_L, lbl_new("y_oob"), 0, 0, 0, 0, 0, 0);
    if (bt.k == K.tarrfix) {
        let fixed: TFix = bt;
        st = emit_insn(st, insn.F_CMP_I_R, fixed.n, insn.R_RCX, 64, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_JGE_L, lbl_new("y_oob"), 0, 0, 0, 0, 0, 0);
        elem_load(st, ixesz, insn.R_RAX, insn.R_RCX, insn.R_RAX)
    } else {
        st = emit_insn(st, insn.F_MOV_0_R, insn.R_RAX, -1, 1, -1, -1, insn.R_RDX, 64);
        st = emit_insn(st, insn.F_CMP_R_R, insn.R_RDX, 64, insn.R_RCX, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_JGE_L, lbl_new("y_oob"), 0, 0, 0, 0, 0, 0);
        elem_load(st, ixesz, insn.R_RAX, insn.R_RCX, insn.R_RAX)
    }
};

// s.f = v — in-place record field write, for any object expression: a
// plain variable, a nested place (`a[0].f`), a chain (`x.y.f`). Records
// are heap addresses; the field in slot i lives at addr+8i (same layout
// the static gen_dot read uses), so the write is: value -> (rec + 8*idx).
// The object runs first, then the value. Reference semantics: a field
// write is observable through every binding (the C copy's value model
// shares records the same way).
def gen_dotassign(st: EmitSt, node: DotAssign) -> EmitSt {
    let dobj = node.obj;
    let dkey = node.key;
    let dt = infer(st, dobj);
    let idx = rec_field_idx(dt, dkey);
    st = gen(st, dobj);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen_as(st, node.v, rec_field_type(dt, dkey));
    st = emit_insn(st, insn.F_POP_R, insn.R_RDX, 64, 0, 0, 0, 0, 0);
    if (dt.k == K.tunion) {
        gen_union_slot(st, dt, dkey, true)
    } else {
        emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RDX, -1, 1, 8 * idx, -1)
    }
};

// ── ++/-- and op= ──────────────────────────────────────────────────────
// These desugar into ordinary statements before emitting: the arithmetic
// then goes through gen_bin (whose division/modulo handle LONG_MIN and -1),
// and a target like a[f()] is evaluated EXACTLY ONCE — the desugar binds
// its index/base expression in a synthetic `let` first. Synthetic names
// are `y_t<N>`: user names carry rename's `$`, and `y_` is reserved, so
// they cannot collide with anything the program can write.
//
// Array forms are the in-place ones: `arr += v` becomes push (the header
// never moves, so every alias sees the append), `arr += arr2` a push loop
// over arr2, and `arr *= v` the prepend primitive.

// Synthetic AST pieces for the ++/-- and op= desugars. Node lists are
// built with push chains over a let-bound [] — the checker rejects
// heterogeneous array literals (see gen_str_const's note).
// The new value of `x op= v` / `++x` is bound under the place's type when
// that is byte: binding it masks it (gen_as), so the value the expression
// yields is the one stored. Any other type is left to inference.
def place_value_type(t: Type) -> Type {
    if (t.k == K.tbyte) { t } else { normtype({ k: K.tnone }) }
};

def n_num(v: str, line: long, col: long) -> Leaf {
    { k: K.num, v: v, line: line, col: col }
};

def n_id(v: str, line: long, col: long) -> Leaf {
    { k: K.id, v: v, line: line, col: col }
};

def args1(a: Node) -> [Node] {
    let out: [Node] = [];
    out += a;
    out
};

def args2(a: Node, b: Node) -> [Node] {
    let out: [Node] = [];
    out += a;
    out += b;
    out
};

def n_call1(name: str, a0: Node, line: long, col: long) -> Call {
    { k: K.call, callee: n_id(name, line, col), args: args1(a0), line: line, col: col }
};

def n_call2(name: str, a0: Node, a1: Node, line: long, col: long) -> Call {
    { k: K.call, callee: n_id(name, line, col), args: args2(a0, a1), line: line, col: col }
};

def block2(a: Node, b: Node, ln: long, cl: long) -> Block {
    let st: [Node] = [];
    st += a;
    st += b;
    { k: K.block, stmts: st, line: ln, col: cl }
};

def block3(a: Node, b: Node, c: Node, ln: long, cl: long) -> Block {
    let st: [Node] = [];
    st += a;
    st += b;
    st += c;
    { k: K.block, stmts: st, line: ln, col: cl }
};

// `first` (a place binding, which is a BLOCK for a nested place) then
// `rest`, all in ONE block: the statements after it read the names the binding
// declares, so a nested block would take their slots out of scope under them
// (frame slots are released per block -- see gen_block_as).
def block_bind(first: Node, rest: [Node], ln: long, cl: long) -> Block {
    let st: [Node] = [];
    if (first.k == K.block) {
        let fb: Block = first;
        let fs = fb.stmts;
        for i in 0..len(fs) {
            st += [fs[i]];
        };
    } else {
        st += [first];
    };
    rest.foreach((e) => {
        st += [e];
    });
    { k: K.block, stmts: st, line: ln, col: cl }
};

def block4(a: Node, b: Node, c: Node, d: Node, ln: long, cl: long) -> Block {
    let st: [Node] = [];
    st += a;
    st += b;
    st += c;
    st += d;
    { k: K.block, stmts: st, line: ln, col: cl }
};

def block5(a: Node, b: Node, c: Node, d: Node, e: Node, ln: long, cl: long) -> Block {
    let st: [Node] = [];
    st += a;
    st += b;
    st += c;
    st += d;
    st += e;
    { k: K.block, stmts: st, line: ln, col: cl }
};

def block6(a: Node, b: Node, c: Node, d: Node, e: Node, f: Node, ln: long, cl: long) -> Block {
    let st: [Node] = [];
    st += a;
    st += b;
    st += c;
    st += d;
    st += e;
    st += f;
    { k: K.block, stmts: st, line: ln, col: cl }
};

// The frame offset of `node` when it names a plain long local that can be
// stepped or adjusted in place -- one `inc`/`dec`/`add $imm` on the slot, with
// no register and no frame slot of its own. Everything else is 0 (offsets grow
// downward from -8, so 0 is never a slot):
//   - an index or field target has to evaluate its place once, which is what
//     the desugar's synthetic bind is for;
//   - an appendable string ("own"), a global, and a box/capture cell all need
//     the desugar's path -- a string read clears its companion cell and a box
//     write goes through the shared cell;
//   - a byte slot must wrap at 128, which a 64-bit ALU op on the slot would
//     not do (the desugar's movzbq/movb pair does).
def inplace_slot(st: EmitSt, node: Node) -> long {
    let off = 0;
    if (node.k == K.id) {
        let id: Leaf = node;
        let e = env_find(st, id.v);
        if (e.kind == "local" && e.typ.k == K.tlong) { off = e.off; };
    };
    off
};

// The immediate of an `add $imm, slot`: an integer literal the 83 /ext ib and
// 81 /ext id forms can take (a signed byte, else a signed 32-bit word), and
// nothing else -- x86 has no ALU form with a memory *source*, so a computed
// right-hand side has to travel in a register and keeps the desugar.
def int_imm(r: Node) -> AsmNum {
    let ok = false;
    let v = 0;
    if (r.k == K.num) {
        let num: Leaf = r;
        if (!lit_is_float(num.v)) {
            let n = leading_long(norm_num(num.v));
            if (n >= -2147483648 && n <= 2147483647) {
                ok = true;
                v = n;
            };
        };
    };
    { ok: ok, v: v }
};

// `dropped` is gen_stmt's: the desugar builds `{ bind; let v = <place>;
// <target> = <v op e>; v }`, whose value is the place read -- the old x for
// `x++`. As a statement nothing reads that load (654 such reads in ycc's own
// output), so a statement context runs the block through gen_discard, whose
// last statement is a statement too, and gen_stmt drops the local read.
//
// Where the target is a plain long local, all ten instructions of the desugar
// become one: `inc -8(%rbp)` where the desugar wrote a bind, a read, a copy
// in, an immediate, a copy back and a store -- and took a frame slot for it.
def gen_incdec(st: EmitSt, node: IncDec, dropped: bool) -> EmitSt {
    let slot = dropped ? inplace_slot(st, node.tgt) : 0;
    if (slot != 0) {
        let f = insn.F_INC_D;
        if (node.op == "--") { f = insn.F_DEC_D; };
        emit_insn(st, f, insn.R_RBP, -1, 1, slot, -1, 0, 0)
    } else {
        gen_incdec_desugar(st, node, dropped)
    }
};

// The desugar gen_incdec's fast path skips (see its comment).
def gen_incdec_desugar(st: EmitSt, node: IncDec, dropped: bool) -> EmitSt {
    let op = node.op;
    let binop = "+";
    if (op == "--") { binop = "-"; }
    let tgt = node.tgt;
    let ln = node.line;
    let cl = node.col;
    let one = n_num("1", ln, cl);
    let r = next_uid(st);
    st = r.st;
    let t1 = "y_t" + tostring(r.uid);
    // One shape for every place: capture the base/index exactly once (a
    // no-op let for a plain variable), read the place, step it, write it
    // back. The arithmetic goes through gen_bin (LONG_MIN / -1 safe).
    let bind: Node = gen_place_bind(tgt, t1, ln, cl);
    let place: Node = gen_place_read(tgt, t1, ln, cl);
    if (node.pre) {
        // ++x -> { bind; let v = x + 1; x = v; v }
        let nv: Bin = { k: K.bin, op: binop, l: place, r: one, line: ln, col: cl };
        let d2: Decl = { k: K.decl, kind: "let", typ: place_value_type(infer(st, tgt)), name: t1 + "v", v: nv, line: ln, col: cl, nline: ln, ncol: cl };
        let asg: Node = gen_place_assign(tgt, n_id(t1 + "v", ln, cl), t1, ln, cl);
        gen_incdec_end(st, bind, d2, asg, dropped, ln, cl)
    } else {
        // x++ -> { bind; let v = x; x = v + 1; v }
        let d2: Decl = { k: K.decl, kind: "let", typ: normtype({ k: K.tnone }), name: t1 + "v", v: place, line: ln, col: cl, nline: ln, ncol: cl };
        let nv: Bin = { k: K.bin, op: binop, l: n_id(t1 + "v", ln, cl), r: one, line: ln, col: cl };
        let asg: Node = gen_place_assign(tgt, nv, t1, ln, cl);
        gen_incdec_end(st, bind, d2, asg, dropped, ln, cl)
    }
};

// `{ bind; let v = ...; target = v; v }` -- both `++x` and `x++`, whose value
// is the trailing read of the temporary. As a statement that read is dead.
def gen_incdec_end(st: EmitSt, bind: Node, d2: Node, asg: Node, dropped: bool, ln: long, cl: long) -> EmitSt {
    let rest: [Node] = [];
    rest += d2;
    rest += asg;
    rest += n_id_of(d2, ln, cl);
    if (dropped) {
        gen_discard(st, block_bind(bind, rest, ln, cl))
    } else {
        gen(st, block_bind(bind, rest, ln, cl))
    }
};

// The temporary's own name: `let v = ...` binds <t1>v, and the block's value
// reads it back.
def n_id_of(d2: Node, ln: long, cl: long) -> Node {
    let decl: Decl = d2;
    n_id(decl.name, ln, cl)
};

// `x op= v`: arrays take the in-place forms (`+=` push/append, `*=`
// prepend), everything else
// the arithmetic desugar. Arrays are homogeneous by design, so `+=` on an
// array is either a same-typed element (push) or a same-typed array
// (append) — never a mix.
// `{ bind; target = <e>; place }` -- the array append forms' shape, whose value
// is the place read (the array, for `+=` / `*=`). As a statement that read is
// dead, unless it is a named local: reading one clears a string's companion
// cell (gen_id), which gen_stmt's frame test deliberately leaves alone.
def gen_opassign_end(st: EmitSt, bind: Node, asg: Node, read: Node, dropped: bool, ln: long, cl: long) -> EmitSt {
    let rest: [Node] = [];
    rest += asg;
    rest += read;
    if (dropped) {
        gen_discard(st, block_bind(bind, rest, ln, cl))
    } else {
        gen(st, block_bind(bind, rest, ln, cl))
    }
};

def gen_opassign(st: EmitSt, node: OpAssign, dropped: bool) -> EmitSt {
    let t = infer(st, node.tgt);
    if (unfold(t).k == K.tptr) {
        // The arithmetic fast path adds a slot immediate directly; a pointer
        // offset must be scaled by the element width, which the desugar's
        // `p = p + n` gets from gen_bin.
        gen_opassign_desugar(st, node, dropped)
    } else if (t.k == K.tarr || t.k == K.tarrfix) {
        gen_opassign_arr(st, node, dropped)
    } else {
        gen_opassign_arith(st, node, dropped)
    }
};

// `x op= v` for numbers and strings -> `x = x op v`, with the target's
// index/base evaluated once through a synthetic let. The desugar is ten
// instructions and a frame slot; on a plain long local, as a statement, the
// operation is two to six and no slot at all:
//
//   x += 2      add $2, -8(%rbp)                       (the 83 /ext ib form)
//   x += e      mov -8(%rbp), %rax ; push %rax ; <e> ; mov %rax, %rcx ;
//               pop %rax ; add %rcx, %rax ; mov %rax, -8(%rbp)
//
// The place is read FIRST in the register form, exactly as the desugar orders
// it, so a right-hand side that writes the variable through a closure still
// sees the old value.
//
// The ops left to the desugar are the ones whose computation is more than the
// ALU instruction: `/` and `%` need its zero check and idiv, the shifts their
// count check, and a byte, float or non-local target a different instruction
// altogether (see inplace_slot).
def gen_opassign_arith(st: EmitSt, node: OpAssign, dropped: bool) -> EmitSt {
    let fr = 0;
    let fi = 0;
    let slot = 0;
    let imm = 0;
    let has_imm = false;
    if (dropped) {
        slot = inplace_slot(st, node.tgt);
        if (slot != 0) {
            let op = node.op;
            if (op == "+") { fr = insn.F_ADD_R_R; fi = insn.F_ADD_I_D; }
            else if (op == "-") { fr = insn.F_SUB_R_R; fi = insn.F_SUB_I_D; }
            else if (op == "*") { fr = insn.F_IMUL_R_R; fi = 0; }
            else if (op == "|") { fr = insn.F_OR_R_R; fi = insn.F_OR_I_D; }
            else if (op == "&") { fr = insn.F_AND_R_R; fi = insn.F_AND_I_D; }
            else if (op == "^") { fr = insn.F_XOR_R_R; fi = insn.F_XOR_I_D; };
            if (fi != 0) {
                let im = int_imm(node.v);
                if (im.ok) {
                    has_imm = true;
                    imm = im.v;
                };
            };
        };
    };
    if (fr == 0) {
        gen_opassign_desugar(st, node, dropped)
    } else if (has_imm) {
        emit_insn(st, fi, imm, insn.R_RBP, -1, 1, slot, -1, 0)
    } else {
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, slot, -1, insn.R_RAX, 64);
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = gen(st, node.v);
        st = emit_insn(st, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_RCX, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_POP_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, fr, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0);
        emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, slot, -1)
    }
};

// The desugar gen_opassign_arith's fast path skips (see its comment).
def gen_opassign_desugar(st: EmitSt, node: OpAssign, dropped: bool) -> EmitSt {
    let tgt = node.tgt;
    let op = node.op;
    let ln = node.line;
    let cl = node.col;
    let r = next_uid(st);
    st = r.st;
    let t1 = "y_t" + tostring(r.uid);
    let bind: Node = gen_place_bind(tgt, t1, ln, cl);
    let rd: Node = gen_place_read(tgt, t1, ln, cl);
    let bin: Bin = { k: K.bin, op: op, l: rd, r: node.v, line: ln, col: cl };
    let d2: Decl = { k: K.decl, kind: "let", typ: place_value_type(infer(st, tgt)), name: t1 + "v", v: bin, line: ln, col: cl, nline: ln, ncol: cl };
    let asg: Node = gen_place_assign(tgt, n_id(t1 + "v", ln, cl), t1, ln, cl);
    let rest: [Node] = [];
    rest += d2;
    rest += asg;
    rest += n_id(t1 + "v", ln, cl);
    if (dropped) {
        gen_discard(st, block_bind(bind, rest, ln, cl))
    } else {
        gen(st, block_bind(bind, rest, ln, cl))
    }
};

// `{ bind; let v = <place op e>; target = v; v }` -- the arithmetic `op=`
// shape, whose value is the same trailing read (see gen_incdec_end).

// The place an opassign target names. `t1` is the synthetic name that
// captured the target's index (a[i]) or base (o.f) — an id target needs
// no capture (re-reading a variable has no side effects). Each target
// shape gets its own arm (single-call dispatch, see normnode note).
def place_read_id(tgt: Leaf, t1: str, ln: long, cl: long) -> Leaf {
    n_id(tgt.v, ln, cl)
};

// The base array node for an index place: a plain variable is used
// directly (re-reading it has no side effects); any other base expression
// was captured in `t1 + "a"` (see place_bind_idx), so the desugared forms
// read and write it through a plain variable and evaluate it exactly once.
def place_arr(tgt: Index, t1: str, ln: long, cl: long) -> Leaf {
    let ba = tgt.arr;
    if (ba.k == K.id) {
        let id: Leaf = ba;
        n_id(id.v, ln, cl)
    } else { n_id(t1 + "a", ln, cl) }
};

def place_read_idx(tgt: Index, t1: str, ln: long, cl: long) -> Index {
    { k: K.index, arr: place_arr(tgt, t1, ln, cl), idx: n_id(t1, ln, cl), line: ln, col: cl }
};

def place_read_dot(tgt: Dot, t1: str, ln: long, cl: long) -> Dot {
    { k: K.dot, obj: n_id(t1, ln, cl), key: tgt.key, line: ln, col: cl, nline: ln, ncol: cl }
};

def gen_place_read(tgt: Node, t1: str, ln: long, cl: long) -> Node {
    if (tgt.k == K.id) {
        let id: Leaf = tgt;
        let node: Node = place_read_id(id, t1, ln, cl);
        node
    } else if (tgt.k == K.index) {
        let index: Index = tgt;
        let node: Node = place_read_idx(index, t1, ln, cl);
        node
    } else {
        let dot: Dot = tgt;
        let node: Node = place_read_dot(dot, t1, ln, cl);
        node
    }
};

def place_asg_id(tgt: Leaf, valnode: Node, t1: str, ln: long, cl: long) -> Assign {
    { k: K.assign, name: tgt.v, v: valnode, line: ln, col: cl }
};

def place_asg_idx(tgt: Index, valnode: Node, t1: str, ln: long, cl: long) -> IdxAssign {
    { k: K.idxassign, arr: place_arr(tgt, t1, ln, cl), idx: n_id(t1, ln, cl), v: valnode, line: ln, col: cl }
};

def place_asg_dot(tgt: Dot, valnode: Node, t1: str, ln: long, cl: long) -> DotAssign {
    { k: K.dotassign, obj: n_id(t1, ln, cl), key: tgt.key, v: valnode, line: ln, col: cl, nline: tgt.nline, ncol: tgt.ncol }
};

def gen_place_assign(tgt: Node, valnode: Node, t1: str, ln: long, cl: long) -> Node {
    if (tgt.k == K.id) {
        let id: Leaf = tgt;
        let node: Node = place_asg_id(id, valnode, t1, ln, cl);
        node
    } else if (tgt.k == K.index) {
        let index: Index = tgt;
        let node: Node = place_asg_idx(index, valnode, t1, ln, cl);
        node
    } else {
        let dot: Dot = tgt;
        let node: Node = place_asg_dot(dot, valnode, t1, ln, cl);
        node
    }
};

def place_bind_id(tgt: Leaf, t1: str, ln: long, cl: long) -> Block {
    { k: K.block, stmts: [], line: ln, col: cl }
};

def place_bind_idx_id(tgt: Index, t1: str, ln: long, cl: long) -> Decl {
    { k: K.decl, kind: "let", typ: normtype({ k: K.tnone }), name: t1, v: tgt.idx, line: ln, col: cl, nline: ln, ncol: cl }
};

def place_bind_idx_nest(tgt: Index, t1: str, ln: long, cl: long) -> Block {
    // nested base (`grid[0][1]`, `x.y[i]`, `f()[i]`): capture it in
    // `t1 + "a"` as well, so the place evaluates it exactly once.
    let tba: Decl = { k: K.decl, kind: "let", typ: normtype({ k: K.tnone }), name: t1 + "a", v: tgt.arr, line: ln, col: cl, nline: ln, ncol: cl };
    let tib: Decl = { k: K.decl, kind: "let", typ: normtype({ k: K.tnone }), name: t1, v: tgt.idx, line: ln, col: cl, nline: ln, ncol: cl };
    block2(tba, tib, ln, cl)
};

def place_bind_idx(tgt: Index, t1: str, ln: long, cl: long) -> Node {
    if (tgt.arr.k == K.id) {
        let node: Node = place_bind_idx_id(tgt, t1, ln, cl);
        node
    } else {
        let node: Node = place_bind_idx_nest(tgt, t1, ln, cl);
        node
    }
};

def place_bind_dot(tgt: Dot, t1: str, ln: long, cl: long) -> Decl {
    { k: K.decl, kind: "let", typ: normtype({ k: K.tnone }), name: t1, v: tgt.obj, line: ln, col: cl, nline: ln, ncol: cl }
};

// The synthetic `let` that runs the target's index/base exactly once (a
// no-op statement for id targets).
def gen_place_bind(tgt: Node, t1: str, ln: long, cl: long) -> Node {
    if (tgt.k == K.id) {
        let id: Leaf = tgt;
        let node: Node = place_bind_id(id, t1, ln, cl);
        node
    } else if (tgt.k == K.index) {
        let index: Index = tgt;
        place_bind_idx(index, t1, ln, cl)
    } else {
        let dot: Dot = tgt;
        let node: Node = place_bind_dot(dot, t1, ln, cl);
        node
    }
};

def gen_opassign_arr(st: EmitSt, node: OpAssign, dropped: bool) -> EmitSt {
    // In-place array forms. `*=` prepends one element. `+=` pushes one
    // element — or, when the VALUE is an array of the same element type
    // (types.arr_plus_kind "cat"), appends its elements: in bulk when the
    // element types are one (y_arr_extend), else one by one, each
    // converted (its length is captured first, so `a += a` is safe);
    // `[[T]] += [T]` pushes the [T] whole. The checker enforces matching
    // element types (types.y opassign_check).
    let tgt = node.tgt;
    let op = node.op;
    let v = node.v;
    let ln = node.line;
    let cl = node.col;
    let r = next_uid(st);
    st = r.st;
    let t1 = "y_t" + tostring(r.uid);
    let tt = infer(st, tgt);
    let mode = "push";
    let bulk = false;
    if (op == "*") {
        mode = "prepend";
    } else {
        let vt = infer(st, v);
        if ((vt.k == K.tarr || vt.k == K.tarrfix) && types.arr_plus_kind(tt, vt) == "cat") {
            mode = "append";
            let ta: ArrTy = tt;
            let va: ArrTy = vt;
            bulk = types.teq(ta.of, va.of);
        }
    };
    if (mode == "append" && bulk) {
        gen_opassign_end(st, gen_place_bind(tgt, t1, ln, cl), gen_place_assign(tgt, (n_call2("push$all", gen_place_read(tgt, t1, ln, cl), v, ln, cl)), t1, ln, cl), gen_place_read(tgt, t1, ln, cl), dropped, ln, cl)
    } else if (mode == "append") {
        // { let tv = v; let ti = 0; let tn = len(tv);
        //   while (ti < tn) { place += tv[ti]; ti = ti + 1 }
        //   place }
        let tv: Decl = { k: K.decl, kind: "let", typ: normtype({ k: K.tnone }), name: t1 + "v", v: v, line: ln, col: cl, nline: ln, ncol: cl };
        let ti: Decl = { k: K.decl, kind: "let", typ: normtype({ k: K.tnone }), name: t1 + "i", v: n_num("0", ln, cl), line: ln, col: cl, nline: ln, ncol: cl };
        let tn: Decl = { k: K.decl, kind: "let", typ: normtype({ k: K.tnone }), name: t1 + "n", v: n_call1("len", n_id(t1 + "v", ln, cl), ln, cl), line: ln, col: cl, nline: ln, ncol: cl };
        let elem: Index = { k: K.index, arr: n_id(t1 + "v", ln, cl), idx: n_id(t1 + "i", ln, cl), line: ln, col: cl };
        let put: Node = gen_place_assign(tgt, n_call2("push", gen_place_read(tgt, t1, ln, cl), elem, ln, cl), t1, ln, cl);
        let step: Assign = { k: K.assign, name: t1 + "i", v: { k: K.bin, op: "+", l: n_id(t1 + "i", ln, cl), r: n_num("1", ln, cl), line: ln, col: cl }, line: ln, col: cl };
        let loop: While = { k: K.kw_while, cond: { k: K.bin, op: "<", l: n_id(t1 + "i", ln, cl), r: n_id(t1 + "n", ln, cl), line: ln, col: cl }, body: block2(put, step, ln, cl), line: ln, col: cl };
        let rest: [Node] = [];
        rest += tv;
        rest += ti;
        rest += tn;
        rest += loop;
        rest += gen_place_read(tgt, t1, ln, cl);
        let bnd: Node = gen_place_bind(tgt, t1, ln, cl);
        if (dropped) {
            gen_discard(st, block_bind(bnd, rest, ln, cl))
        } else {
            gen(st, block_bind(bnd, rest, ln, cl))
        }
    } else {
        let fname = "push";
        if (mode == "prepend") { fname = "prepend"; }
        gen_opassign_end(st, gen_place_bind(tgt, t1, ln, cl), gen_place_assign(tgt, (n_call2(fname, gen_place_read(tgt, t1, ln, cl), v, ln, cl)), t1, ln, cl), gen_place_read(tgt, t1, ln, cl), dropped, ln, cl)
    }
};

def gen_idxassign(st: EmitSt, node: IdxAssign) -> EmitSt {
    // Fixed arrays are heap headers now: one layout for both kinds.
    // Fixed uses the static bound n; heap uses the runtime len.
    // Reference semantics: `x[i] = v` writes through to the array every
    // binding shares — params included (the C copy's value model aliases
    // the same way). The base is any array expression and runs once, in
    // base/index/value order. No write-back to the base:
    // the header pointer never moves, so the store through it is already
    // visible through every binding.
    let garr = node.arr;
    let bt: Type = infer(st, garr);
    let iaesz = arr_elem_bytes(bt);
    st = gen(st, garr);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen(st, node.idx);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen_as(st, node.v, store_elem_type(bt, iaesz));
    st = emit_insn(st, insn.F_POP_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_POP_R, insn.R_RDX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_TEST_R_R, insn.R_RCX, 64, insn.R_RCX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JS_L, lbl_new("y_oob"), 0, 0, 0, 0, 0, 0);
    if (bt.k == K.tarrfix) {
        let fixed: TFix = bt;
        st = emit_insn(st, insn.F_CMP_I_R, fixed.n, insn.R_RCX, 64, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_JGE_L, lbl_new("y_oob"), 0, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_R_R, insn.R_RDX, 64, insn.R_R10, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_RDX, 64, 0, 0, 0);
        st = elem_store_rdx(st, iaesz, insn.R_R10, insn.R_RCX);
        st = emit_insn(st, insn.F_MOV_R_R, insn.R_R10, 64, insn.R_RDX, 64, 0, 0, 0);
    } else {
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_0_R, insn.R_RDX, -1, 1, -1, -1, insn.R_RAX, 64);
        st = emit_insn(st, insn.F_CMP_R_R, insn.R_RAX, 64, insn.R_RCX, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_JGE_L, lbl_new("y_oob"), 0, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_POP_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_R_R, insn.R_RDX, 64, insn.R_R10, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_RDX, 64, 0, 0, 0);
        st = elem_store_rdx(st, iaesz, insn.R_R10, insn.R_RCX);
        st = emit_insn(st, insn.F_MOV_R_R, insn.R_R10, 64, insn.R_RDX, 64, 0, 0, 0);
    };
    st
};

// ── value formatting ───────────────────────────────────────────────────
// A value of static type `t` sits in %rax; leave its string form in %rax.
// The walk is unrolled at compile time (the type is static), so nested
// arrays emit nested loops rather than needing a runtime type tag.

// Is this type one the walk is already inside? `path` holds the types being
// formatted, outermost first, and a type that repeats is a recursive one
// (04-types.tex, Type aliases: recursion through a record field). This walk is
// unrolled at compile time, so a recursive type has no finite unrolling: the
// compiler ran out of stack (test/y/native/t154_union_layout.y), and bounding
// the DEPTH instead only traded that for an explosion -- the unrolling
// multiplies with every level, and a recursive AST type took the compile over
// the memory cap. Cutting where the type repeats costs one comparison per
// level, formats a finite type as deep as it goes, and prints the repeated one
// as its type, which is the text the record walk used to give every aggregate
// field. A type that appears twice on DIFFERENT branches (a diamond) is not on
// the path and is formatted both times, as it must be.
def type_on_path(t: Type, path: [Type]) -> bool {
    let i = 0;
    let found = false;
    while (i < len(path)) {
        // the same node: a recursive alias is one shared node (teq)
        if (path[i] == t) { found = true; };
        i++;
    };
    found
};

def gen_val_tostr_rax(st: EmitSt, t: Type, path: [Type]) -> EmitSt {
    // the walk compares the UNFOLDED type (a recursive alias and its
    // union are one node) but prints the type as the program wrote it
    let named = t;
    t = types.unfold(t);
    let tk = t.k;
    if (type_on_path(t, path)) {
        gen_str_const(st, "<" + types.tstr(named) + ">")
    } else if (tk == K.tstr) {
        st
    } else if (tk == K.tbigint) {
        gen_helper1(st, "y_bigint_tostr")
    } else if (tk == K.tbool) {
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_CALL_L, lbl_new("y_bool_tostr"), 0, 0, 0, 0, 0, 0);
        emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0)
    } else if (tk == K.tfloat) {
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_CALL_L, lbl_new("y_float_tostr"), 0, 0, 0, 0, 0, 0);
        emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0)
    } else if (tk == K.tarr) {
        // every aggregate arm below puts ITS OWN type on the path and hands
        // `path + t` to the walk it starts; a scalar type is never recursion
        // and stays off it
        let arr: TOf = t;
        if (arr.of.k == K.tbyte) {
            // [byte] stringifies Python-style: b'...' with escapes
            gen_helper1(st, "y_bytes_repr")
        } else {
            gen_arr_tostr_rax(st, arr.of, path + t)
        }
    } else if (tk == K.tarrfix) {
        let arr: TFix = t;
        if (arr.of.k == K.tbyte) {
            gen_helper1(st, "y_bytes_repr")
        } else {
            gen_arr_tostr_rax(st, arr.of, path + t)
        }
    } else if (tk == K.topt) {
        gen_opt_str_rax(st, t, path + t)
    } else if (tk == K.trec) {
        gen_rec_str_rax(st, t, lay_of(t, t), path + t)
    } else if (tk == K.tunion) {
        gen_union_str_rax(st, t, path + t)
    } else if (tk == K.tmap) {
        gen_map_repr_rax(st, t, path + t)
    } else {
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_CALL_L, lbl_new("y_long_tostr"), 0, 0, 0, 0, 0, 0);
        emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0)
    }
};

// acc = acc + <the string in %rax>.
def gen_acc_cat_rax(st: EmitSt, aoff: long) -> EmitSt {
    st = emit_insn(st, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_RDX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, aoff, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RDX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_str_cat"), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0);
    emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, aoff, -1)
};

// The record address of a map sits in %rax; leave '{"k": v, ...}' -- the same
// text tostring() gives it (gen_map_repr builds that loop from nodes; this one
// walks the value in hand). A map is the {boxes, keys, vals} record
// (gen_maplit), so its two arrays sit at 8 and 16. This arm is what
// gen_val_tostr_rax was missing: with the long-to-string fallback there
// instead, a map nested in an array, an option or a record printed as its heap
// address, which differs every run.
def gen_map_repr_rax(st: EmitSt, t: Type, path: [Type]) -> EmitSt {
    let moff = (st.slots + st.temp + 1) * -8;
    let aoff = (st.slots + st.temp + 2) * -8;
    let ioff = (st.slots + st.temp + 3) * -8;
    let koff = (st.slots + st.temp + 4) * -8;
    st = st_temp(st, st.temp + 4);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, moff, -1);
    st = gen_str_const(st, "{");
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, aoff, -1);
    st = emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, ioff, -1);
    let r1 = next_loc(st);
    st = r1.st;
    let r2 = next_loc(st);
    st = r2.st;
    let r3 = next_loc(st);
    st = r3.st;
    let map: TMap = t;
    st = emit_label(st, r1.label);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, moff, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RDX, -1, 1, 8, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RDX, -1, 1, -1, -1, insn.R_RCX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, ioff, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_CMP_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JGE_L, r2.label, 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_TEST_R_R, insn.R_RAX, 64, insn.R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JZ_L, r3.label, 0, 0, 0, 0, 0, 0);
    st = gen_acc_cat_slot(st, aoff, ", ");
    st = emit_label(st, r3.label);
    // the key, quoted when it is a str (map_key_repr's rule)
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, moff, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RDX, -1, 1, 8, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, ioff, -1, insn.R_RCX, 64);
    st = elem_load(st, elem_bytes(map.key), insn.R_RDX, insn.R_RCX, insn.R_RAX);
    if (map.key.k == K.tstr) {
        // The key goes to a slot first: appending the opening quote is a call
        // that leaves its result in %rax, so a key still living there would be
        // appended twice over instead.
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, koff, -1);
        st = gen_acc_cat_slot(st, aoff, "\"");
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, koff, -1, insn.R_RAX, 64);
        st = gen_acc_cat_rax(st, aoff);
        st = gen_acc_cat_slot(st, aoff, "\"");
    } else {
        st = gen_val_tostr_rax(st, map.key, path + t);
        st = gen_acc_cat_rax(st, aoff);
    };
    st = gen_acc_cat_slot(st, aoff, ": ");
    // the value
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, moff, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RDX, -1, 1, 16, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, ioff, -1, insn.R_RCX, 64);
    st = elem_load(st, elem_bytes(map.of), insn.R_RDX, insn.R_RCX, insn.R_RAX);
    st = gen_val_tostr_rax(st, map.of, path + t);
    st = gen_acc_cat_rax(st, aoff);
    // the counter in place: one instruction, not a load, an inc and a store
    st = emit_insn(st, insn.F_INC_D, insn.R_RBP, -1, 1, ioff, -1, 0, 0);
    st = emit_insn(st, insn.F_JMP_L, r1.label, 0, 0, 0, 0, 0, 0);
    st = emit_label(st, r2.label);
    st = gen_acc_cat_slot(st, aoff, "}");
    emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, aoff, -1, insn.R_RAX, 64)
};

// Array header in %rax -> "[e0, e1, ...]" in %rax, the same form tostring()
// gives. Slots: [src][acc][i].
def gen_arr_tostr_rax(st: EmitSt, elty: Type, path: [Type]) -> EmitSt {
    let soff = (st.slots + st.temp + 1) * -8;
    let aoff = (st.slots + st.temp + 2) * -8;
    let ioff = (st.slots + st.temp + 3) * -8;
    st = st_temp(st, st.temp + 3);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, soff, -1);
    st = gen_str_const(st, "[");
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, aoff, -1);
    st = emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, ioff, -1);
    let r1 = next_loc(st);
    st = r1.st;
    let r2 = next_loc(st);
    st = r2.st;
    let r3 = next_loc(st);
    st = r3.st;
    st = emit_label(st, r1.label);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, soff, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RDX, -1, 1, -1, -1, insn.R_RCX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, ioff, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_CMP_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JGE_L, r2.label, 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_TEST_R_R, insn.R_RAX, 64, insn.R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JZ_L, r3.label, 0, 0, 0, 0, 0, 0);
    st = gen_acc_cat_slot(st, aoff, ", ");
    st = emit_label(st, r3.label);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, soff, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, ioff, -1, insn.R_RCX, 64);
    st = elem_load(st, elem_bytes(elty), insn.R_RDX, insn.R_RCX, insn.R_RAX);
    st = gen_val_tostr_rax(st, elty, path);
    st = emit_insn(st, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_RDX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, aoff, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RDX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_str_cat"), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, aoff, -1);
    // the counter in place: one instruction, not a load, an inc and a store
    st = emit_insn(st, insn.F_INC_D, insn.R_RBP, -1, 1, ioff, -1, 0, 0);
    st = emit_insn(st, insn.F_JMP_L, r1.label, 0, 0, 0, 0, 0, 0);
    st = emit_label(st, r2.label);
    st = gen_acc_cat_slot(st, aoff, "]");
    emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, aoff, -1, insn.R_RAX, 64)
};

// slot(%rbp) = slot(%rbp) + <constant>.
def gen_acc_cat_slot(st: EmitSt, off: long, s: str) -> EmitSt {
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, off, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen_str_const(st, s);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_str_cat"), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0);
    emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, off, -1)
};

// ── element size ───────────────────────────────────────────────────────
// Byte arrays are PACKED: one byte per element, not eight. Every element
// lives at base + 16 + i*esz, so the scale factor, the allocation size and
// the load/store width all follow from the element type. Everything else
// stays 8 bytes (one machine word per value).

def elem_bytes(t: Type) -> long {
    if (t.k == K.tbyte) { 1 } else { 8 }
};

def arr_elem_bytes(t: Type) -> long {
    if (t.k == K.tarr) {
        let arr: TOf = t;
        elem_bytes(arr.of)
    } else if (t.k == K.tarrfix) {
        let arr: TFix = t;
        elem_bytes(arr.of)
    }
    else { 8 }
};

// Width of what a pointer of static type `t` addresses: a *byte points into
// a packed [byte] block (or at a byte local), so `*p` and `*p = v` move one
// byte; every other pointee is a full 8-byte slot.
def ptr_width(t: Type) -> long {
    if (t.k == K.tptr) {
        let ptr: TPtr = t;
        elem_bytes(ptr.to)
    } else { 8 }
};

// Load element [idx] into `dst`. `base` is the ARRAY HEADER register, `idx`
// the index register, `dst` the result (all register numbers). Headers are
// {len, cap, data} with the elements in a separate block, so the data pointer
// rides through %dst.
def elem_load(st: EmitSt, esz: long, base: long, idx: long, dst: long) -> EmitSt {
    st = emit_insn(st, insn.F_MOV_D_R, base, -1, 1, 16, -1, dst, 64);
    if (esz == 1) {
        emit_insn(st, insn.F_MOVZBQ_M_R, dst, idx, 1, 0, -1, dst, 64)
    } else {
        emit_insn(st, insn.F_MOV_M_R, dst, idx, 8, 0, -1, dst, 64)
    }
};

// Store %rdx into element [idx] of the array based at `base` (register
// numbers). The value always arrives in %rdx so the byte form can name %dl
// without a register table; a packed store truncates to 8 bits, which is the
// narrowing. %r11 is the scratch that carries the data pointer: no generated
// value lives in it across a store (the syscall instruction clobbers it).
def elem_store_rdx(st: EmitSt, esz: long, base: long, idx: long) -> EmitSt {
    st = emit_insn(st, insn.F_MOV_D_R, base, -1, 1, 16, -1, insn.R_R11, 64);
    if (esz == 1) {
        emit_insn(st, insn.F_MOVB_R_M, insn.R_RDX, 8, insn.R_R11, idx, 1, 0, -1)
    } else {
        emit_insn(st, insn.F_MOV_R_M, insn.R_RDX, 64, insn.R_R11, idx, 8, 0, -1)
    }
};

// Same, for a compile-time-constant index (array literals): fold the
// offset into the displacement instead of using an index register.
def elem_store_rdx_const(st: EmitSt, esz: long, base: long, k: long) -> EmitSt {
    st = emit_insn(st, insn.F_MOV_D_R, base, -1, 1, 16, -1, insn.R_R11, 64);
    if (esz == 1) {
        emit_insn(st, insn.F_MOVB_R_D, insn.R_RDX, 8, insn.R_R11, -1, 1, k, -1)
    } else {
        emit_insn(st, insn.F_MOV_R_D, insn.R_RDX, 64, insn.R_R11, -1, 1,
            k * 8, -1)
    }
};

// The array header is {len, cap, data, front} and NEVER moves: elements
// live in a separate block, so growth keeps every alias valid (that is
// what makes `arr += v` in-place). front, the free slots before data, is
// the header's fourth word: the header is all four words (NATIVE.md), and
// the request must cover them, since y_alloc hands out at most the bytes
// asked for (the collector's 8-byte block header sits in what used to be
// the allocator's spare). This is the block size for n elements.
def arr_alloc_size(esz: long, n: long) -> long {
    let b = n * esz;
    if (b < 8) { 8 } else { b }
};

// Bytes to allocate for the header itself: {len, cap, data, front}.
def arr_header_size() -> long {
    32
};

// Field read rec.field: the checker guarantees a trec with that field.
// Records are heap addresses; field k lives at addr+8k. Static index via
// infer (checker validated). Works for locals, params, and call results
// alike — every record value is just an address in %rax.
def gen_dot(st: EmitSt, node: Dot) -> EmitSt {
    // dobj is read twice (infer, then gen).
    let dobj = node.obj;
    let dkey = node.key;
    if (dobj.k == K.narrow) {
        let nar: Narrow = dobj;
        let s = infer(st, nar.e);
        if (s.k == K.tunion) { return gen_narrow_field(st, nar, s, dkey); };
    };
    let t = infer(st, dobj);
    let tk = t.k;
    if (tk == K.tarr || tk == K.tarrfix || tk == K.tstr) {
        gen_prop(st, dobj, dkey, node.line, node.col)
    } else if (tk == K.tunion) {
        st = gen(st, dobj);
        gen_union_slot(st, t, dkey, false)
    } else {
        gen_dot_rec(st, dobj, dkey, t)
    }
};

// Field `dkey` of a union value (types.y union_field: every member has
// it, with one type): read into %rax from the record in %rax, or (store)
// %rax written to the record in %rdx. A field every member shares sits at
// one slot in every member held in the union (union_lay): one move.
def gen_union_slot(st: EmitSt, t: Type, dkey: str, store: bool) -> EmitSt {
    gen_slot_move(st, mfield_idx(union_shared(types.unfold(t)), dkey), store)
};

// A match pattern's field read (`T {f}`, `{f: v}`; parser.y: a dot on a
// narrow of the subject, a union s): field `dkey` read in place, at its
// slot in s's layout of each member the arm's test accepts -- the narrowed
// record (a copy where the layouts differ, gen_convert) is never made. One
// move when the field has one slot in every such member; else a compare
// of the descriptor per member, a move per slot.
def gen_narrow_field(st: EmitSt, nar: Narrow, s: Type, dkey: str) -> EmitSt {
    let ms = rectest_members(s, nar.typ);
    let slots: [long] = [];
    let ds: [long] = [];
    foreach (m in ms) {
        let sl = mfield_idx(union_lay(types.unfold(m), s), dkey);
        slots += sl;
        let seen = false;
        foreach (d in ds) { if (d == sl) { seen = true; }; };
        if (!seen) { ds += sl; };
    };
    st = gen(st, nar.e);
    if (len(ds) == 0) {
        // no member matches: the arm never runs
        emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0)
    } else if (len(ds) == 1) {
        gen_slot_move(st, ds[0], false)
    } else {
        let done = next_loc(st);
        st = done.st;
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RAX, -1, 1, -8, -1, insn.R_RCX, 64);
        let lbls: [long] = [];
        for d in 0..len(ds) - 1 {
            let l = next_loc(st);
            st = l.st;
            lbls += l.label;
            ms.foreach((e, j) => {
                if (slots[j] == ds[d]) {
                    let dr = ty_desc_in(st, e, s);
                    st = dr.st;
                    st = emit_insn(st, insn.F_LEA_P_R, -1, -1, 1, 0, dr.label, insn.R_RSI, 64);
                    st = emit_insn(st, insn.F_CMP_R_R, insn.R_RSI, 64, insn.R_RCX, 64, 0, 0, 0);
                    st = emit_insn(st, insn.F_JE_L, l.label, 0, 0, 0, 0, 0, 0);
                };
            });
        };
        st = gen_slot_move(st, ds[len(ds) - 1], false);
        st = emit_insn(st, insn.F_JMP_L, done.label, 0, 0, 0, 0, 0, 0);
        lbls.foreach((el, e) => {
            st = emit_label(st, el);
            st = gen_slot_move(st, ds[e], false);
            // not on the last arm: that one falls through into `done:`
            if (e < len(lbls) - 1) { st = emit_insn(st, insn.F_JMP_L, done.label, 0, 0, 0, 0, 0, 0); };
        });
        emit_label(st, done.label)
    }
};

// gen_union_slot's move: slot sl of the record in %rax into %rax, or
// (store) %rax into slot sl of the record in %rdx.
def gen_slot_move(st: EmitSt, sl: long, store: bool) -> EmitSt {
    if (store) {
        emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RDX, -1, 1, 8 * sl, -1)
    } else {
        emit_insn(st, insn.F_MOV_D_R, insn.R_RAX, -1, 1, 8 * sl, -1, insn.R_RAX, 64)
    }
};

// Built-in properties (types.y typeof_prop): `.length` is len(x); `.ptr`
// is the array header's data word — the element block's address.
def gen_prop(st: EmitSt, obj: Node, key: str, line: long, col: long) -> EmitSt {
    if (key == "length") {
        gen_len(st, n_call1("len", obj, line, col))
    } else {
        st = gen(st, obj);
        emit_insn(st, insn.F_MOV_D_R, insn.R_RAX, -1, 1, 16, -1, insn.R_RAX, 64)
    }
};

// Record field read; `t` is the record's static type.
def gen_dot_rec(st: EmitSt, dobj: Node, dkey: str, t: Type) -> EmitSt {
    let idx = rec_field_idx(t, dkey);
    st = gen(st, dobj);
    emit_insn(st, insn.F_MOV_D_R, insn.R_RAX, -1, 1, idx * 8, -1, insn.R_RAX, 64)
};

// The slot of field `key` in a record of static type t (fields sorted by
// name, see "records at run time"); -1 when t has no such field (the
// checker rejects such a read).
def rec_field_idx(t: Type, key: str) -> long {
    let idx = -1;
    if (t.k == K.trec) {
        let rec: TRec = t;
        let fs: [Field] = rec.fields;
        idx = rec_slot(fs, key);
    } else if (t.k == K.tmap) {
        // a map is lowered to the {keys, vals, boxes} record (see
        // gen_maplit), laid out boxes, keys, vals
        if (key == "boxes") { idx = 0; } else if (key == "keys") { idx = 1; } else if (key == "vals") { idx = 2; };
    };
    idx
};

// Static type of field `key` in trec type t (tnone when there is none);
// in a union, the type the field has in every member (types.y
// union_field).
def rec_field_type(t: Type, key: str) -> Type {
    let ft: Type = { k: K.tnone };
    if (t.k == K.tunion) {
        let ms = types.members(t);
        if (len(ms) > 0) { ft = rec_field_type(ms[0], key); }
    } else if (t.k == K.trec) {
        let rec: TRec = t;
        let fs: [Field] = rec.fields;
        for i in 0..len(fs) {
            let f = fs[i];
            if (f.name == key) {
                ft = f.typ;
            }
        };
    }
    ft
};

// Heap array literal [v, ...]: a data block of arr_alloc_size(esz, n) and a
// separate arr_header_size() header {len, cap, data}; the values are stored
// into the data block through the header's pointer. The header address (an
// 8-byte value like any other) is the expression value.
def gen_array(st: EmitSt, node: ArrLit) -> EmitSt {
    let at = infer(st, node);
    let gsz = arr_elem_bytes(at);
    gen_array_esz(st, node, gsz, store_elem_type(at, gsz))
};

// Same, with the element width supplied by the declaration (`let b:
// [byte] = [104, 105]` — the literal's own elements infer as long), and
// `ety` the element type each value converts to (store_elem_type).
def gen_array_esz(st: EmitSt, node: ArrLit, esz: long, ety: Type) -> EmitSt {
    let elems: [Node] = node.elems;
    elems.foreach((e) => {
        st = gen_as(st, e, ety);
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    });
    let n = len(elems);
    st = emit_insn(st, insn.F_MOV_I_R, arr_alloc_size(esz, n), insn.R_RDI, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_alloc"), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_I_R, arr_header_size(), insn.R_RDI, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_alloc"), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_R10, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_POP_R, insn.R_RDX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_I_0, n, insn.R_R10, -1, 1, -1, -1, 0);
    st = emit_insn(st, insn.F_MOV_I_D, n, insn.R_R10, -1, 1, 8, -1, 0);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RDX, 64, insn.R_R10, -1, 1, 16, -1);
    let k = n - 1;
    while (k >= 0) {
        st = emit_insn(st, insn.F_POP_R, insn.R_RDX, 64, 0, 0, 0, 0, 0);
        st = elem_store_rdx_const(st, esz, insn.R_R10, k);
        k = k - 1;
    };
    emit_insn(st, insn.F_MOV_R_R, insn.R_R10, 64, insn.R_RAX, 64, 0, 0, 0)
};

def gen_len(st: EmitSt, node: Call) -> EmitSt {
    // Checker: single array or string argument. Fixed size is immediate
    // (from the inferred type itself); heap length (array header or string
    // header) loads from address+0. NOTE: the argument is any array-typed
    // expression (id, dot like `a.args`, call result) — never assume a
    // plain id (no `.v` reads here); infer gives the static type.
    let args = node.args;
    let at = infer(st, args[0]);
    if (at.k == K.tmap) {
        // len(m) = len(m.keys): the entry count
        gen(st, n_call1("len", n_dot(args[0], "keys", node.line, node.col), node.line, node.col))
    } else if (at.k == K.tstr) {
        st = gen(st, args[0]);
        emit_insn(st, insn.F_MOV_0_R, insn.R_RAX, -1, 1, -1, -1, insn.R_RAX, 64)
    } else {
        st = gen(st, args[0]);
        emit_insn(st, insn.F_MOV_0_R, insn.R_RAX, -1, 1, -1, -1, insn.R_RAX, 64)
    }
};

// arr += v: Y calling convention straight into the prelude helper.
// Returns the (possibly reallocated) header — rebind it: `a += v`.
def gen_push(st: EmitSt, node: Call) -> EmitSt {
    let pargs: [Node] = node.args;
    let pat = infer(st, pargs[0]);
    let pesz = arr_elem_bytes(pat);
    let ptypes: [Type] = [];
    ptypes += type_node({ k: K.tnone });
    ptypes += store_elem_type(pat, pesz);
    st = gen_push_args_as(st, node.args, ptypes);
    st = emit_insn(st, insn.F_MOV_I_R, pesz, insn.R_RAX, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_arr_push"), 0, 0, 0, 0, 0, 0);
    emit_insn(st, insn.F_ADD_I_R, (len(node.args) * 8 + 8), insn.R_RSP, 64, 0, 0, 0, 0)
};

// `arr += other` with one element type (gen_opassign_arr makes the call,
// a name no program can write): y_arr_extend appends other's elements in
// bulk.
def gen_push_all(st: EmitSt, node: Call) -> EmitSt {
    let pargs: [Node] = node.args;
    let pesz = arr_elem_bytes(infer(st, pargs[0]));
    st = gen_push_args_as(st, node.args, []);
    st = emit_insn(st, insn.F_MOV_I_R, pesz, insn.R_RAX, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_arr_extend"), 0, 0, 0, 0, 0, 0);
    emit_insn(st, insn.F_ADD_I_R, 24, insn.R_RSP, 64, 0, 0, 0, 0)
};

// some(v): box v in 8 heap bytes; the box address (nonzero) is the value.
// The payload of a `?.` chain, back in an option box (parser.y). A payload
// that is already an option IS its box, so nothing to do; a void chain has
// nothing to hand back. Otherwise some(v).
def gen_opt_val(st: EmitSt, node: Call) -> EmitSt {
    let args: [Node] = node.args;
    let at = infer(st, args[0]);
    if (at.k == K.topt || at.k == K.tvoid) {
        gen(st, args[0])
    } else {
        gen_some(st, node)
    }
};

def gen_some(st: EmitSt, node: Call) -> EmitSt {
    let args: [Node] = node.args;
    st = gen(st, args[0]);
    gen_box_rax(st)
};

// The value in %rax boxed: some(v), the box in %rax.
def gen_box_rax(st: EmitSt) -> EmitSt {
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_I_R, 8, insn.R_RDI, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_alloc"), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_POP_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
    emit_insn(st, insn.F_MOV_R_0, insn.R_RCX, 64, insn.R_RAX, -1, 1, -1, -1)
};

def gen_is_some(st: EmitSt, node: Call) -> EmitSt {
    let args: [Node] = node.args;
    if (is_map_read(st, args[0])) {
        // is_some(m[k]): the key scan decides, nothing is boxed
        gen_map_get(st, args[0], "has")
    } else {
        st = gen(st, args[0]);
        st = emit_insn(st, insn.F_TEST_R_R, insn.R_RAX, 64, insn.R_RAX, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_SETNE_R, insn.R_RAX, 8, 0, 0, 0, 0, 0);
        emit_insn(st, insn.F_MOVZBQ_R_R, insn.R_RAX, 8, insn.R_RAX, 64, 0, 0, 0)
    }
};

def gen_unwrap(st: EmitSt, node: Call) -> EmitSt {
    let args: [Node] = node.args;
    if (is_map_read(st, args[0])) {
        // m[k]!: the entry's value itself, nothing is boxed
        gen_map_get(st, args[0], "val")
    } else {
        st = gen(st, args[0]);
        st = emit_insn(st, insn.F_TEST_R_R, insn.R_RAX, 64, insn.R_RAX, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_JZ_L, lbl_new("y_opt_unwrap"), 0, 0, 0, 0, 0, 0);
        emit_insn(st, insn.F_MOV_0_R, insn.R_RAX, -1, 1, -1, -1, insn.R_RAX, 64)
    }
};

// ── string builtins (all on {len, data} header objects) ────────────────
// Every helper takes header addresses via the Y calling convention
// (args pushed left-to-right, first arg deepest) and returns a header
// address (or long) in %rax. Caller cleans the stack.

def gen_trim(st: EmitSt, node: Call) -> EmitSt {
    st = gen_push_args(st, node.args);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_str_trim"), 0, 0, 0, 0, 0, 0);
    emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0)
};

// arr *= v -> arr: in-place insert at the front (the header never
// moves, so every alias sees it). The `*=` operator desugars to this.
def gen_prepend(st: EmitSt, node: Call) -> EmitSt {
    let pargs: [Node] = node.args;
    let pat = infer(st, pargs[0]);
    let pesz = arr_elem_bytes(pat);
    let ptypes: [Type] = [];
    ptypes += type_node({ k: K.tnone });
    ptypes += store_elem_type(pat, pesz);
    st = gen_push_args_as(st, node.args, ptypes);
    st = emit_insn(st, insn.F_MOV_I_R, pesz, insn.R_RAX, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_arr_prepend"), 0, 0, 0, 0, 0, 0);
    emit_insn(st, insn.F_ADD_I_R, (len(node.args) * 8 + 8), insn.R_RSP, 64, 0, 0, 0, 0)
};

// byte_at(s, i): byte i of string s, trapped when out of bounds. This is
// the primitive every string helper is built on — reading one byte must
// not copy the string the way bytes() does. Inline, four instructions,
// because scanning loops call it per character.
def gen_byte_at(st: EmitSt, node: Call) -> EmitSt {
    let args: [Node] = node.args;
    st = gen(st, args[0]);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen(st, args[1]);
    st = emit_insn(st, insn.F_POP_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RCX, -1, 1, -1, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_TEST_R_R, insn.R_RAX, 64, insn.R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JS_L, lbl_new("y_oob"), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CMP_R_R, insn.R_RDX, 64, insn.R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JGE_L, lbl_new("y_oob"), 0, 0, 0, 0, 0, 0);
    emit_insn(st, insn.F_MOVZBQ_M_R, insn.R_RCX, insn.R_RAX, 1, 8, -1, insn.R_RAX, 64)
};

// mod(a, b): the FLOORED remainder -- the sign of the DIVISOR, where `%` is
// C's truncating one. The `%` sequence is emitted first (with its
// divide-by-zero trap and its `x % -1` case, both of which mod needs for the
// same reason), and then the one adjustment that makes it floor: when the
// remainder is NON-ZERO and its sign differs from the divisor's, add the
// divisor. `(r ^ b) < 0` is that sign test in one xor -- the two signs differ
// exactly when the xor's top bit is set. The `-1` case is why the remainder
// is tested for zero first: `x % -1` is 0 for every x, and 0 needs no
// adjustment whatever the divisor's sign.
def gen_mod(st: EmitSt, node: Call) -> EmitSt {
    let args: [Node] = node.args;
    st = gen(st, args[0]);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen(st, args[1]);
    // F_MOV_R_R and F_ADD_R_R take their operands the way the assembler
    // writes them, SOURCE first (the in-tree assembler is AT&T): `mov %rax,
    // %rcx` is RCX <- RAX, and the `+` case adds with F_ADD_R_R, R_RCX,
    // R_RAX for the same reason. Written the other way round the three
    // register moves below put the divisor's garbage in RCX and mod(5, 3)
    // trapped with "division by zero".
    st = emit_insn(st, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_RCX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_POP_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_TEST_R_R, insn.R_RCX, 64, insn.R_RCX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JZ_L, lbl_new("y_div_zero"), 0, 0, 0, 0, 0, 0);
    let m1 = next_loc(st);
    st = m1.st;
    let m2 = next_loc(st);
    st = m2.st;
    st = emit_insn(st, insn.F_CMP_I_R, -1, insn.R_RCX, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_JNE_L, m1.label, 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
    st = emit_insn(st, insn.F_JMP_L, m2.label, 0, 0, 0, 0, 0, 0);
    st = emit_label(st, m1.label);
    st = emit_insn(st, insn.F_CQO, 0, 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_IDIV_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_R_R, insn.R_RDX, 64, insn.R_RAX, 64, 0, 0, 0);
    st = emit_label(st, m2.label);
    let m3 = next_loc(st);
    st = m3.st;
    st = emit_insn(st, insn.F_TEST_R_R, insn.R_RAX, 64, insn.R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JZ_L, m3.label, 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_RDX, 64, 0, 0, 0);
    // xor %rcx, %rdx: the divisor is in RCX and the adjustment below still
    // needs it, so the SIGN TEST goes into RDX (written the other way round
    // RCX was overwritten by the test itself, and mod(-949, 100) came out
    // -134 instead of 51)
    st = emit_insn(st, insn.F_XOR_R_R, insn.R_RCX, 64, insn.R_RDX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JNS_L, m3.label, 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_ADD_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0);
    emit_label(st, m3.label)
};

def gen_ord(st: EmitSt, node: Call) -> EmitSt {
    st = gen_push_args(st, node.args);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_str_ord"), 0, 0, 0, 0, 0, 0);
    emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0)
};

def gen_chr(st: EmitSt, node: Call) -> EmitSt {
    st = gen_push_args(st, node.args);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_str_chr"), 0, 0, 0, 0, 0, 0);
    emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0)
};

// tolong(x): a str is parsed by the runtime, a float is truncated by the
// runtime too -- y_f2l, which checks the range, because a float with no long
// answer should say so rather than arrive as the machine's "integer indefinite"
// value. The static type picks the arm, so neither costs a test at run time.
def gen_tolong(st: EmitSt, node: Call) -> EmitSt {
    let targs: [Node] = node.args;
    let t = infer(st, targs[0]);
    let lbl = if (t.k == K.tfloat) { "y_f2l" }
    else if (t.k == K.tbigint) { "y_bigint_to_long" }
    else { "y_str_tolong" };
    st = gen_push_args(st, node.args);
    st = emit_insn(st, insn.F_CALL_L, lbl_new(lbl), 0, 0, 0, 0, 0, 0);
    emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0)
};

// tofloat(x): a str is parsed; a long is widened, which is one instruction and
// no call -- the emitter already knows how, because it is the only coercion the
// language has. So this arm exists for the symmetry of the pair, not because it
// needs to.
def gen_tofloat(st: EmitSt, node: Call) -> EmitSt {
    let targs: [Node] = node.args;
    let a0 = targs[0];
    let t = infer(st, a0);
    if (t.k == K.tlong) {
        st = gen(st, a0);
        st = emit_insn(st, insn.F_CVTSI2SD_R_R, insn.R_RAX, 64, insn.R_XMM0, 128, 0, 0, 0);
        st = emit_insn(st, insn.F_MOVQ_R_R, insn.R_XMM0, 128, insn.R_RAX, 64, 0, 0, 0);
        // tofloat answers an OPTION now, so the widened value is boxed the same
        // way some(v) is: a pointer with the value at offset 0. A bigint
        // conversion is already boxed by its runtime helper.
        gen_box_rax(st)
    } else if (t.k == K.tbigint) {
        st = gen_push_args(st, node.args);
        st = emit_insn(st, insn.F_CALL_L, lbl_new("y_bigint_to_float"), 0, 0, 0, 0, 0, 0);
        emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0)
    } else {
        st = gen_push_args(st, node.args);
        st = emit_insn(st, insn.F_CALL_L, lbl_new("y_str_tofloat"), 0, 0, 0, 0, 0, 0);
        emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0)
    }
};

def gen_tostring(st: EmitSt, node: Call) -> EmitSt {
    // dispatch on the static type: long/bool need conversion, str is identity
    let targs: [Node] = node.args;
    let a0 = targs[0];
    let t = infer(st, a0);
    if (t.k == K.tstr) {
        gen(st, a0)
    } else if (t.k == K.tbool) {
        st = gen_push_args(st, node.args);
        st = emit_insn(st, insn.F_CALL_L, lbl_new("y_bool_tostr"), 0, 0, 0, 0, 0, 0);
        emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0)
    } else if (t.k == K.tfloat) {
        st = gen_push_args(st, node.args);
        st = emit_insn(st, insn.F_CALL_L, lbl_new("y_float_tostr"), 0, 0, 0, 0, 0, 0);
        emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0)
    } else if (t.k == K.tarr) {
        st = gen(st, a0);
        let arr: TOf = t;
        if (arr.of.k == K.tbyte) { gen_helper1(st, "y_bytes_repr") } else { gen_arr_tostr_rax(st, arr.of, []) }
    } else if (t.k == K.tarrfix) {
        st = gen(st, a0);
        let arr: TFix = t;
        if (arr.of.k == K.tbyte) { gen_helper1(st, "y_bytes_repr") } else { gen_arr_tostr_rax(st, arr.of, []) }
    } else if (t.k == K.topt) {
        st = gen(st, a0);
        gen_opt_str_rax(st, t, [])
    } else if (t.k == K.trec) {
        st = gen(st, a0);
        gen_rec_str_rax(st, t, lay_of(t, t), [])
    } else if (t.k == K.tunion) {
        st = gen(st, a0);
        gen_union_str_rax(st, t, [])
    } else if (t.k == K.tmap) {
        gen_map_repr(st, a0, t)
    } else if (t.k == K.tbigint) {
        st = gen_push_args(st, node.args);
        st = emit_insn(st, insn.F_CALL_L, lbl_new("y_bigint_tostr"), 0, 0, 0, 0, 0, 0);
        emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0)
    } else {
        st = gen_push_args(st, node.args);
        st = emit_insn(st, insn.F_CALL_L, lbl_new("y_long_tostr"), 0, 0, 0, 0, 0, 0);
        emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0)
    }
};

// An f-string field, #fmt(e, "spec") (lexer.y lex_fstring, checked by
// types.y typeof_fmt). Without a spec it is tostring(e). With one, e goes
// to a std/str.y helper with the spec read here, packed into one number
// (fmt_code), and its width and precision: y_fmt_i for d x X o b c,
// y_fmt_f for f F e E % (a long converted first, and a `%` multiplied by
// 100 in floating point, as Python does it), y_fmt_s for the rest -- a
// str, or the tostring of anything else.
def gen_fmt(st: EmitSt, node: Call) -> EmitSt {
    let fargs: [Node] = node.args;
    let a0 = fargs[0];
    // As in types.y's typeof_fmt: a spec argument that is an err node has
    // no spec to read. The checker rejects the program before here, so this
    // only keeps the emitter from casting a member it does not hold.
    let sp = types.leaf_of(fargs[1]);
    let spec: str = if (sp == none) { "" } else { sp !.v };
    let ts = n_call1("tostring", a0, node.line, node.col);
    if (spec == "") {
        gen_tostring(st, ts)
    } else {
        let t = infer(st, a0);
        let f = types.fmt_spec(spec);
        let kind = types.fmt_kind(t);
        let ty = f.ty;
        if (ty == 0) {
            if (kind == 1) { ty = 100; } else if (kind == 2) { ty = 102; } else { ty = 115; };
        }
        let code = fmt_code(f, kind, ty);
        if (ty == 's') {
            st = gen_tostring(st, ts);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = fmt_push(st, code);
            st = fmt_push(st, f.width);
            st = fmt_push(st, f.prec);
            st = emit_insn(st, insn.F_CALL_L, lbl_new("y_fmt_s"), 0, 0, 0, 0, 0, 0);
            emit_insn(st, insn.F_ADD_I_R, 32, insn.R_RSP, 64, 0, 0, 0, 0)
        } else if (['d', 'x', 'X', 'o', 'b', 'c'].index(ty) >= 0) {
            st = gen(st, a0);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = fmt_push(st, code);
            st = fmt_push(st, f.width);
            st = emit_insn(st, insn.F_CALL_L, lbl_new("y_fmt_i"), 0, 0, 0, 0, 0, 0);
            emit_insn(st, insn.F_ADD_I_R, 24, insn.R_RSP, 64, 0, 0, 0, 0)
        } else {
            st = gen(st, a0);
            if (kind == 1) {
                st = emit_insn(st, insn.F_CVTSI2SD_R_R, insn.R_RAX, 64, insn.R_XMM0, 128, 0, 0, 0);
                st = emit_insn(st, insn.F_MOVQ_R_R, insn.R_XMM0, 128, insn.R_RAX, 64, 0, 0, 0);
            }
            if (ty == '%') {
                st = emit_insn(st, insn.F_MOVQ_R_R, insn.R_RAX, 64, insn.R_XMM0, 128, 0, 0, 0);
                st = emit_insn(st, insn.F_MOV_I_R, 100, insn.R_RAX, 64, 0, 0, 0, 0);
                st = emit_insn(st, insn.F_CVTSI2SD_R_R, insn.R_RAX, 64, insn.R_XMM1, 128, 0, 0, 0);
                st = emit_insn(st, insn.F_MULSD_R_R, insn.R_XMM1, 128, insn.R_XMM0, 128, 0, 0, 0);
                st = emit_insn(st, insn.F_MOVQ_R_R, insn.R_XMM0, 128, insn.R_RAX, 64, 0, 0, 0);
            }
            let prec = f.prec;
            if (prec < 0) { prec = 6; }
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = fmt_push(st, code);
            st = fmt_push(st, f.width);
            st = fmt_push(st, prec);
            st = emit_insn(st, insn.F_CALL_L, lbl_new("y_fmt_f"), 0, 0, 0, 0, 0, 0);
            emit_insn(st, insn.F_ADD_I_R, 32, insn.R_RSP, 64, 0, 0, 0, 0)
        }
    }
};

// A spec as the y_fmt_* helpers take it (std/str.y), its defaults
// resolved: the type letter + 256 * fill + 65536 * alignment + 16777216 *
// (sign + 4 * `#` + 8 * grouping), sign 0 (`-`), 1 (`+`) or 2 (a space),
// grouping 0, 1 (`,`) or 2 (`_`). A `0` is fill 0 unless a fill is given
// and, for a number, alignment `=` unless one is; numbers go right,
// everything else left.
def fmt_code(f: FmtSpec, kind: long, ty: long) -> long {
    let fill = f.fill;
    let align = f.align;
    if (f.zero && fill == 0) { fill = 48; }
    if (f.zero && align == 0 && kind != 0) { align = 61; }
    if (fill == 0) { fill = 32; }
    if (align == 0) {
        align = kind != 0 ? 62 : 60;
    }
    let sg = 0;
    if (f.sign == '+') { sg = 1; } else if (f.sign == ' ') { sg = 2; }
    if (f.alt) { sg += 4; }
    if (f.grp == ',') { sg += 8; } else if (f.grp == '_') { sg += 16; }
    ty + 256 * fill + 65536 * align + 16777216 * sg
};

// Push the number v (an argument of a helper call).
def fmt_push(st: EmitSt, v: long) -> EmitSt {
    st = emit_insn(st, insn.F_MOV_I_R, v, insn.R_RAX, 64, 0, 0, 0, 0);
    emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0)
};

def gen_index_of(st: EmitSt, node: Call, last: bool) -> EmitSt {
    // The runtime helper always takes (string, sub, offset): 2-argument calls
    // synthesize the offset they mean, so there is ONE helper per direction
    // rather than a duplicate with an offset (SUGGESTIONS.md #18: "the next
    // ) from here" without slicing the tail, which allocates a copy and
    // returns an index into the copy).
    st = gen_push_args(st, node.args);
    if (len(node.args) < 3) {
        st = gen(st, n_num(default_offset(last), node.line, node.col));
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    };
    st = last ? emit_insn(st, insn.F_CALL_L, lbl_new("y_str_lastidx"), 0, 0, 0, 0, 0, 0) : emit_insn(st, insn.F_CALL_L, lbl_new("y_str_index"), 0, 0, 0, 0, 0, 0);
    emit_insn(st, insn.F_ADD_I_R, 24, insn.R_RSP, 64, 0, 0, 0, 0)
};

// The offset a two-argument index_of/last_index_of means: 0 for the forward
// scan (at or after the start) and LONG_MAX for the backward one, which the
// runtime clamps to the last place a match can begin -- "search anywhere".
def default_offset(last: bool) -> str {
    if (last) { "9223372036854775807" } else { "0" }
};

// join(arr, sep). y_str_join walks string HEADERS, so an array of longs,
// bools or floats is stringified into a fresh [str] first — reading a raw
// long as a header would fault. Unknown element types keep the old direct
// path: most of them really are strings (the compiler's own arrays infer
// as tunk through {k}-holes), and guessing wrong there would corrupt
// output rather than crash.
def gen_join(st: EmitSt, node: Call) -> EmitSt {
    let jargs: [Node] = node.args;
    let at: Type = infer(st, jargs[0]);
    let eltyp: Type = type_node({ k: K.tunk });
    if (at.k == K.tarr) { let arr: TOf = at; eltyp = arr.of; }
    if (at.k == K.tarrfix) { let arr: TFix = at; eltyp = arr.of; }
    let ek = eltyp.k;
    if (ek == K.tlong) {
        gen_join_conv(st, node, "y_long_tostr", 8)
    } else if (ek == K.tbyte) {
        gen_join_conv(st, node, "y_long_tostr", 1)
    } else if (ek == K.tbool) {
        gen_join_conv(st, node, "y_bool_tostr", 8)
    } else if (ek == K.tfloat) {
        gen_join_conv(st, node, "y_float_tostr", 8)
    } else {
        st = gen_push_args(st, node.args);
        st = emit_insn(st, insn.F_CALL_L, lbl_new("y_str_join"), 0, 0, 0, 0, 0, 0);
        emit_insn(st, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0)
    }
};

// Slots: [src][dst][i]. Builds dst = [tostr(src[0]), ...] then joins it.
def gen_join_conv(st: EmitSt, node: Call, tostr_fn: str, esz: long) -> EmitSt {
    let soff = (st.slots + st.temp + 1) * -8;
    let doff = (st.slots + st.temp + 2) * -8;
    let ioff = (st.slots + st.temp + 3) * -8;
    st = st_temp(st, st.temp + 3);
    let jargs: [Node] = node.args;
    st = gen(st, jargs[0]);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, soff, -1);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RAX, -1, 1, -1, -1, insn.R_RDI, 64);
    st = emit_insn(st, insn.F_SHL_I_R, 3, insn.R_RDI, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_alloc"), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_I_R, arr_header_size(), insn.R_RDI, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_alloc"), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_POP_R, insn.R_RDX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, doff, -1);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, soff, -1, insn.R_RCX, 64);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RCX, -1, 1, -1, -1, insn.R_RCX, 64);
    st = emit_insn(st, insn.F_MOV_R_0, insn.R_RCX, 64, insn.R_RAX, -1, 1, -1, -1);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RCX, 64, insn.R_RAX, -1, 1, 8, -1);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RDX, 64, insn.R_RAX, -1, 1, 16, -1);
    st = emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, ioff, -1);
    let r1 = next_loc(st);
    st = r1.st;
    let r2 = next_loc(st);
    st = r2.st;
    st = emit_label(st, r1.label);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, soff, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RDX, -1, 1, -1, -1, insn.R_RCX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, ioff, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_CMP_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JGE_L, r2.label, 0, 0, 0, 0, 0, 0);
    st = elem_load(st, esz, insn.R_RDX, insn.R_RAX, insn.R_RCX);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new(tostr_fn), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, ioff, -1, insn.R_RCX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, doff, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RDX, -1, 1, 16, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_MOV_R_M, insn.R_RAX, 64, insn.R_RDX, insn.R_RCX, 8, 0, -1);
    st = emit_insn(st, insn.F_INC_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RCX, 64, insn.R_RBP, -1, 1, ioff, -1);
    st = emit_insn(st, insn.F_JMP_L, r1.label, 0, 0, 0, 0, 0, 0);
    st = emit_label(st, r2.label);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, doff, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen(st, jargs[1]);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_str_join"), 0, 0, 0, 0, 0, 0);
    emit_insn(st, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0)
};

def gen_split(st: EmitSt, node: Call) -> EmitSt {
    st = gen_push_args(st, node.args);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_str_split"), 0, 0, 0, 0, 0, 0);
    emit_insn(st, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0)
};

def gen_puts(st: EmitSt, node: Call) -> EmitSt {
    // puts(v): write the value WITHOUT trailing newline (C semantics:
    // fputs + flush). Like print but no newline; returns nothing (void).
    let pargs: [Node] = node.args;
    let pa = pargs[0];
    st = gen(st, pa);
    let t = infer(st, pa);
    if (t.k == K.tbool) {
        st = gen_helper1(st, "y_put_bool");
        emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0)
    } else if (t.k == K.tstr) {
        st = gen_helper1(st, "y_put_hstr");
        emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0)
    } else {
        st = gen_helper1(st, "y_put_long");
        emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0)
    }
};

def gen_eputs(st: EmitSt, node: Call) -> EmitSt {
    // eputs(v): like puts, but on fd 2. Diagnostic output (`--time`) must
    // never land in stdout (where `-S` assembly and program output live).
    let pargs: [Node] = node.args;
    let pa = pargs[0];
    st = gen(st, pa);
    let t = infer(st, pa);
    if (t.k == K.tbool) {
        st = gen_helper1(st, "y_eput_bool");
        emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0)
    } else if (t.k == K.tstr) {
        st = gen_helper1(st, "y_eput_hstr");
        emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0)
    } else {
        st = gen_helper1(st, "y_eput_long");
        emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0)
    }
};

def gen_clock_us(st: EmitSt, node: Call) -> EmitSt {
    // clock_us() -> long (monotonic microseconds, via clock_gettime).
    emit_insn(st, insn.F_CALL_L, lbl_new("y_clock_us"), 0, 0, 0, 0, 0, 0)
};

def gen_heap_used(st: EmitSt, node: Call) -> EmitSt {
    // heap_used() -> long (bytes the allocator has handed out so far).
    emit_insn(st, insn.F_CALL_L, lbl_new("y_heap_used"), 0, 0, 0, 0, 0, 0)
};

// mutex() / sem(n): a record of the type (types.y t_mutex, t_sem), its
// lock word 0 -- the runtime's view of it (arch_x64.y y_mutex_lock,
// y_sem_wait).
def gen_sync_new(st: EmitSt, node: Call) -> EmitSt {
    let ln = node.line;
    let cl = node.col;
    let callee: Leaf = node.callee;
    let keys: [str] = [];
    let vals: [Node] = [];
    if (callee.v == "mutex") {
        // the owner pid word, 0 = free (arch_x64.y y_mutex_lock)
        keys += "$m";
        vals += n_num("0", ln, cl);
        keys += "$o";
        vals += n_num("0", ln, cl);
        let rec: RecLit = { k: K.rec, keys: keys, vals: vals, line: ln, col: cl };
        gen_reclit(st, rec, types.t_mutex())
    } else {
        let sargs: [Node] = node.args;
        keys += "$n";
        vals += sargs[0];
        keys += "$w";
        vals += n_num("0", ln, cl);
        keys += "$o";
        vals += n_num("0", ln, cl);
        let rec: RecLit = { k: K.rec, keys: keys, vals: vals, line: ln, col: cl };
        gen_reclit(st, rec, types.t_sem())
    }
};

// lock m { b }: b's closure run while m is held, its value kept; try_lock
// runs it only when m is free, and is whether it did.
def gen_lock(st: EmitSt, node: Call, attempt: bool) -> EmitSt {
    let largs: [Node] = node.args;
    st = gen(st, largs[0]);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen(st, largs[1]);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    if (!attempt) {
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RSP, -1, 1, 8, -1, insn.R_RAX, 64);
        st = emit_insn(st, insn.F_CALL_L, lbl_new("y_mutex_lock"), 0, 0, 0, 0, 0, 0);
        st = gen_call_top(st);
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RSP, -1, 1, 16, -1, insn.R_RAX, 64);
        st = emit_insn(st, insn.F_CALL_L, lbl_new("y_mutex_unlock"), 0, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_POP_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        emit_insn(st, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0)
    } else {
        let skip = next_loc(st);
        st = skip.st;
        let done = next_loc(st);
        st = done.st;
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RSP, -1, 1, 8, -1, insn.R_RAX, 64);
        st = emit_insn(st, insn.F_CALL_L, lbl_new("y_mutex_trylock"), 0, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_TEST_R_R, insn.R_RAX, 64, insn.R_RAX, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_JE_L, skip.label, 0, 0, 0, 0, 0, 0);
        st = gen_call_top(st);
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RSP, -1, 1, 8, -1, insn.R_RAX, 64);
        st = emit_insn(st, insn.F_CALL_L, lbl_new("y_mutex_unlock"), 0, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_I_R, 1, insn.R_RAX, 64, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_JMP_L, done.label, 0, 0, 0, 0, 0, 0);
        st = emit_label(st, skip.label);
        st = emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
        st = emit_label(st, done.label);
        emit_insn(st, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0)
    }
};

// Call the closure on top of the stack with no arguments (it stays there).
def gen_call_top(st: EmitSt) -> EmitSt {
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RSP, -1, 1, 0, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RAX, -1, 1, 0, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_CALL_IND, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0)
};

def gen_sleep(st: EmitSt, node: Call) -> EmitSt {
    // sleep(ms): suspend the caller for ms milliseconds (nanosleep, EINTR
    // cannot happen in single-threaded code, so one syscall is enough).
    let sargs: [Node] = node.args;
    st = gen(st, sargs[0]);
    gen_helper1(st, "y_sleep")
};

def gen_exit(st: EmitSt, node: Call) -> EmitSt {
    // exit(code): terminate the process with the exit-code syscall, THROUGH the
    // arch module's y_os_exit rather than inlined.
    //
    // A `call` and not an inline `mov $231,%rax; syscall`, and that is the
    // whole point. `exit` reaches std code: rt.y's own runtime-error paths call
    // it (y_setslice_check, y_match_fail, the shift check), and rt.y is one of
    // the four units serialized into the std pack. The pack is written by ONE
    // compiler with ONE res_target -- `ycc --std-pack` never passes a target --
    // so a target test made while COMPILING rt.y is baked into every program
    // built from that pack. Measured: with exit inlined, a PE's rt.y carried
    // Linux's exit_group (syscall 231, whose NT counterpart is some unrelated
    // function), so every runtime error in every program printed its message
    // and then fell through into whatever followed -- t80_slice_bounds printed
    // "index out of bounds" as well, and three tests exited 0 where they must
    // exit 1. Naming a label defers the choice to the arch module and makes
    // rt.y's compiled body the same bytes for both targets.
    //
    // The argument goes on the stack like every other call, and y_os_exit reads
    // it at 16(%rbp) -- pushed last, so lowest -- and the caller pops.
    let eargs: [Node] = node.args;
    st = gen(st, eargs[0]);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_os_exit"), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0);
    // exit() terminates the process; the epilogue (ret / exit(0)) is
    // unreachable. Emit a jump to the function end so the backend never
    // falls through into dead code (and exit codes are never masked).
    emit_insn(st, insn.F_JMP_L, st.end_label, 0, 0, 0, 0, 0, 0)
};

// ── process I/O (argv) ──────────────────────────────────────────────
// argv MAY only appear as `main(argv())`'s argument feed: ycc.y's entry is
// `let result = main(argv())`. The _start prologue (below) builds the argv
// array and stashes it in r15; gen_argv emits the call that materializes it.
// (Files are std/fs.y: `import fs;`.)

def gen_argv(st: EmitSt, node: Call) -> EmitSt {
    emit_insn(st, insn.F_CALL_L, lbl_new("y_argv"), 0, 0, 0, 0, 0, 0)
};

def gen_store(st: EmitSt, node: Store) -> EmitSt {
    let spt = infer(st, node.p);
    let sw = ptr_width(spt);
    let sto: Type = type_node({ k: K.tnone });
    if (sw == 8 && spt.k == K.tptr) { let ptr: TPtr = spt; sto = ptr.to; }
    st = gen(st, node.p);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen_as(st, node.v, sto);
    st = emit_insn(st, insn.F_POP_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
    if (sw == 1) { emit_insn(st, insn.F_MOVB_R_0, insn.R_RAX, 8, insn.R_RCX, -1, 1, -1, -1) } else { emit_insn(st, insn.F_MOV_R_0, insn.R_RAX, 64, insn.R_RCX, -1, 1, -1, -1) }
};

// ── functions ──────────────────────────────────────────────────────────
// Frame: locals at rbp-8, rbp-16, ...; params at rbp+16, rbp+24, ....
// Every emitted function gets: prologue, body, end_label, epilogue.

def emit_one_fn(st: EmitSt, label: long, fuid: long, func: EmitFunc, is_main: bool, want_argv: bool, captypes: [Type], selfname: str) -> EmitSt {
    // fresh per-function state; uid/rodata/fns flow through and back.
    // Bodies see every hoisted function and global through st.fns
    // (env_find), like the checker's fresh_func_scope.
    // frame_max is this function's: emit_one_fn nests (a hoisted def, a
    // closure literal), so the caller's mark is put back on the way out.
    let prev_max = frame_max;
    frame_max = 0;
    // No loop encloses this body: any loop the closure was made inside is in
    // the CALLER's function, and a jump out of one into another is what the
    // checker's function-boundary rule refuses. Clearing here makes the emitter
    // right on its own terms rather than relying on that check in another file.
    let prev_brk = brk_label;
    let prev_cont = cont_label;
    let prev_loop_names = loop_names;
    let prev_loop_brks = loop_brks;
    let prev_loop_conts = loop_conts;
    brk_label = 0 - 1;
    cont_label = 0 - 1;
    let no_names: [str] = [];
    let no_brks: [long] = [];
    let no_conts: [long] = [];
    loop_names = no_names;
    loop_brks = no_brks;
    loop_conts = no_conts;
    let f: EmitSt = { ir: [], txt: [], rodata: st.rodata, uid: st.uid,
        fuid: fuid, loc: 1, env: [], slots: 0, temp: 0,
        self_label: label, end_label: lbl_new(arch.arch_loc_label(fuid, 0)),
        fns: st.fns, bodies: st.bodies, btext: st.btext, blabels: st.blabels };
    // The names nested functions capture (see box_names / box_bound).
    f = env_define(f, "", "frame", 0, -1, "", type_node({ k: K.tnone }));
    // This function's type, for the conversions at its returns and its
    // self calls (cur_fn_type).
    let ftype: Type = type_node({ k: K.tfunc, args: func.ptypes, ret: fn_ret(func) });
    f = env_define(f, "", "fnty", 0, -1, "", ftype);
    let bnames = box_names(func);
    bnames.foreach((e) => {
        let bnm: str = e;
        f = env_define(f, "", "boxmark", 0, -1, bnm, type_node({ k: K.tnone }));
    });
    // The names this body appends to (see own_wanted), the same way.
    (app_names(func.body, false, bnames)).foreach((e) => {
        let anm: str = e;
        f = env_define(f, "", "appmark", 0, -1, anm, type_node({ k: K.tnone }));
    });
    // A capturing named function is not in that table (see
    // capturing_defs): bind its own name to this body, so a call by name
    // passes the record along (gen_direct) and a value is the record.
    if (selfname != "") {
        let func_node: Func = func;
        f = env_define(f, selfname, "func", 0, label, "", func_type_in(st, func_node));
    }
    // bind params. Caller pushes args left-to-right, so the LAST arg sits
    // at rbp+16 and param k lives at rbp+16+8*(n-1-k) (arity-dependent).
    let params: [str] = func.params;
    let ptypes: [Type] = func.ptypes;
    let nargs = len(params);
    for i in 0..nargs {
        f = env_define(f, params[i], "param", 16 + (nargs - 1 - i) * 8, -1, "", ptypes[i]);
    };
    // Captures: the caller pushed the closure record BEFORE the args, so it
    // lives just past them at rbp+16+8*nargs. Each capture reads slot idx+1
    // of that record (slot 0 is the code pointer). A capture-free function
    // binds nothing here and never touches the slot, which is what lets one
    // body serve both direct and closure calls. `_start` has no enclosing
    // frame, so it never captures.
    if (!(is_main)) {
        let mycaps = fn_captures(func, st.fns.ix, selfname);
        let cloff = 16 + nargs * 8;
        mycaps.foreach((e, c) => {
            let cn: str = e;
            // Capture types come from the creation site (the enclosing env
            // knows them); without one the emitter would pick long for a
            // captured string in print/puts and in `+`.
            let ct: Type = type_node({ k: K.tnone });
            if (c < len(captypes)) {
                ct = captypes[c];
            }
            f = env_define(f, cn, "capture", cloff, -1, tostring(c), ct);
        });
    };
    // Captured parameters (and the own name) move into their cells
    // before the body; a tail call re-enters above this, so every
    // recycled frame gets fresh cells.
    if (selfname != "") {
        f = box_bound(f, selfname);
    }
    for pbi in 0..nargs {
        let pbn: str = params[pbi];
        f = box_bound(f, pbn);
    };
    // An appended-to str parameter moves into an own pair (bind_own).
    for opi in 0..nargs {
        let opn: str = params[opi];
        let opt = ptypes[opi];
        if (opt.k == K.tstr && own_wanted(f, opn)) {
            f = emit_insn(f, insn.F_MOV_D_R, insn.R_RBP, -1, 1, (env_find(f, opn)).off, -1, insn.R_RAX, 64);
            f = bind_own(f, opn, opt);
        }
    };
    f = gen_tail(f, func.body);
    if (f.slots + f.temp > frame_max) { frame_max = f.slots + f.temp; };
    let frame = arch.arch_frame(frame_max);
    frame_max = prev_max;
    brk_label = prev_brk;
    cont_label = prev_cont;
    loop_names = prev_loop_names;
    loop_brks = prev_loop_brks;
    loop_conts = prev_loop_conts;
    // The body is one IR stream: the prologue, what the body emitted, the
    // epilogue (see ir.y). The text the linker and -S read is rendered from
    // it, so nothing here is spelled twice.
    let body: [long] = [];
    body = insn.ir_push(body, insn.IR_LABEL, label, 0, 0, 0, 0, 0, 0);
    // -g: the prologue is the def's line; `_start` has none (line 0)
    if (dbg_lines) {
        body = is_main ? ir_loc(body, 0) : ir_loc(body, func.line);
    }
    if (is_main) {
        // The collector scans the stack for roots, so the process entry has to
        // remember where the stack began: every live value sits below it. This
        // is the first instruction, before any allocation can happen.
        body = insn.ir_push(body, insn.F_MOV_R_P, insn.R_RSP, 64, -1, -1, 1, 0,
            lbl_new("y_gc_stack_top"));
        // The Windows syscall self-test runs BEFORE anything else: its whole
        // point is that a drifted w_sysno number is caught in the first
        // instruction rather than in the first wrong write.
        if (target_is_windows()) {
            body = insn.ir_push(body, insn.F_CALL_L, lbl_new("y_w_self_test"), 0, 0, 0, 0, 0, 0);
        };
        if (want_argv) {
            // _start prologue: at process entry %rsp -> [argc][argv0ptr]....
            // argv (char**) is the ADDRESS rsp+8 (lea, not a load!); argc is
            // [rsp]. y_argv_init copies every arg into a header string and
            // stashes the [str] array in r15 for y_argv. Skipped entirely
            // when the program never calls argv() (saves ~14s of startup:
            // y_cstr_to_str walks every byte of every arg).
            // NOTE: no bare (%rsp)/(%r12) — the encoder rejects rsp/r12 bases.
            body = insn.ir_push(body, insn.F_MOV_R_R, insn.R_RSP, 64, insn.R_RAX, 64, 0, 0, 0);
            body = insn.ir_push(body, insn.F_MOV_0_R, insn.R_RAX, -1, 1, 0, -1, insn.R_R15, 64);
            body = insn.ir_push(body, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_R14, 64, 0, 0, 0);
            body = insn.ir_push(body, insn.F_ADD_I_R, 8, insn.R_R14, 64, 0, 0, 0, 0);
            body = insn.ir_push(body, insn.F_PUSH_R, insn.R_R14, 64, 0, 0, 0, 0, 0);
            body = insn.ir_push(body, insn.F_PUSH_R, insn.R_R15, 64, 0, 0, 0, 0, 0);
            body = insn.ir_push(body, insn.F_CALL_L, lbl_new("y_argv_init"), 0, 0, 0, 0, 0, 0);
            // The arena baseline is taken AFTER the argument vector is copied
            // (and only when the vector was wanted at all): heap_used()
            // subtracts it, so an absolute figure stops moving with the length
            // of the command line (SUGGESTIONS.md 24).
            body = insn.ir_push(body, insn.F_CALL_L, lbl_new("y_heap_base_set"), 0, 0, 0, 0, 0, 0);
            body = insn.ir_push(body, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0);
        }
    }
    body = insn.ir_push(body, insn.F_PUSH_R, insn.R_RBP, 64, 0, 0, 0, 0, 0);
    body = insn.ir_push(body, insn.F_MOV_R_R, insn.R_RSP, 64, insn.R_RBP, 64, 0, 0, 0);
    if (frame > 0) {
        body = insn.ir_push(body, insn.F_SUB_I_R, frame, insn.R_RSP, 64, 0, 0, 0, 0);
    }
    body = body + f.ir;
    body = insn.ir_push(body, insn.IR_LABEL, f.end_label, 0, 0, 0, 0, 0, 0);
    if (is_main) {
        body = ir_terminate(body);
    } else {
        body = insn.ir_push(body, insn.F_MOV_R_R, insn.R_RBP, 64, insn.R_RSP, 64, 0, 0, 0);
        body = insn.ir_push(body, insn.F_POP_R, insn.R_RBP, 64, 0, 0, 0, 0, 0);
        body = insn.ir_push(body, insn.F_RET, 0, 0, 0, 0, 0, 0, 0);
    };
    // NOTE: append to f.bodies, NOT st.bodies. Emitting this body can add
    // bodies of its own (a nested capturing def is emitted at its creation
    // site), and those land in f.bodies. Using st.bodies dropped them
    // whenever push had to GROW the array: the C copy's value model shares
    // the grown buffer between the two record copies, the native backend
    // rebinds only f.bodies (see NATIVE.md "rebind: a = push(a, v)"), so the
    // two compilers disagreed and ycc emitted calls to labels it never
    // defined.
    f.bodies += body;
    // The raw lines this body's IR_TEXT items index are this function's own
    // (f.txt is fresh per function), so they go with the body.
    f.btext += f.txt;
    let bodies = f.bodies;
    let btext = f.btext;
    // The body's own label, which the linker shakes by (Unit.labels): the
    // first line of the text, known here rather than scanned for (the old
    // body_label). Appended to f.blabels the way f.bodies is, for the same
    // reason (see above): a local rebind would leave the field behind in the
    // C copy's value model, and a nested body's label would land in a
    // different array than its body -- every label after it shifted by one,
    // and the linker shook by the wrong ones.
    f.blabels += lname(label);
    let blabels = f.blabels;
    { ir: st.ir, txt: st.txt, rodata: f.rodata, uid: f.uid,
        fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots, temp: st.temp,
        self_label: st.self_label, end_label: st.end_label, fns: st.fns,
        bodies: bodies, btext: btext, blabels: blabels }
};

// Build a tfunc type from a func node (params have annotations — checked).
// Return type of a function whose `-> T` was omitted and which the checker
// could not type either (types.y records every other inferred return type
// in the node: set_inferred_ret): the type of its body's tail, inferred in
// a scope holding every known def plus the params. The emitter needs one,
// because a call's result type decides e.g. whether `+` must stringify.
def infer_fn_ret(st: EmitSt, func: Func) -> Type {
    let f: EmitSt = { ir: [], txt: [], rodata: st.rodata, uid: st.uid,
        fuid: 0, loc: 1, env: [], slots: 0, temp: 0,
        self_label: -1, end_label: -1, fns: st.fns, bodies: st.bodies,
        btext: st.btext, blabels: st.blabels };
    let params: [str] = func.params;
    let ptypes: [Type] = func.ptypes;
    let n = len(params);
    for i in 0..n {
        f = env_define(f, params[i], "param", 16 + (n - 1 - i) * 8, -1, "", ptypes[i]);
    };
    infer(f, func.body)
};

// A function's type node.
type FuncTy = TFunc;

// A def's return type: as written, or as the checker inferred it
// (types.y inferred_ret); tnone when neither.
def fn_ret(func: EmitFunc) -> Type {
    let r: Type = func.ret;
    if (r.k == K.tnone) { types.inferred_ret(func.line, func.col) } else { r }
};

def func_type(func: Func) -> FuncTy {
    { k: K.tfunc, args: func.ptypes, ret: fn_ret(func) }
};

// Same, but with an unannotated return type resolved from the body — the
// checker infers it too, so a literal's call sites must agree (whether `+`
// stringifies, which print arm runs, ...).
def func_type_in(st: EmitSt, func: Func) -> FuncTy {
    let r: Type = fn_ret(func);
    if (r.k == K.tnone) {
        r = infer_fn_ret(st, func);
    }
    { k: K.tfunc, args: func.ptypes, ret: r }
};

// Files share one namespace. A later top-level def replaces an earlier one
// of the same name (rename.y rn_shadow_dups): deliberate within a file, but
// across files it silently hands every caller -- the first file's own
// included -- the other file's function. So a def that replaces one from
// another file is an error, at the later def. The std units are no part
// of this namespace (they are linked, see std_units): a program may
// define a std name, and its own `readline` wins.
def find_dup(stmts: [Node], origin: Origin) -> [Diag] {
    let names: [str] = [];
    let fids: [long] = [];
    let lines: [long] = [];
    let cols: [long] = [];
    stmts.foreach((e) => {
        let s: Node = e;
        let nm = top_name_in(s, origin);
        if (len(nm) > 0) {
            let ln: long = s.line;
            names += nm;
            fids += origin_file(origin, ln);
            lines += ln;
            cols += s.col;
        }
    });
    // A name's earlier definitions, not every statement's: with 20 000
    // top-level defs the scan of all earlier names was 75% of the compile
    // (10 billion instructions), and nothing in it but the name's own
    // repetitions was ever a candidate. So a name reaches only its own
    // definitions: labmap_new maps the name to a chain head, and each entry
    // holds its file, its position and the entry before it. Walking that chain
    // backwards gives the last definition from another file -- the same answer
    // the scan gave, since the chain is in the order the scan went.
    let ix = asm.labmap_new(len(names) * 2 + 16);
    let top: [long] = [];
    let pfile: [long] = [];
    let ppos: [long] = [];
    let pnext: [long] = [];
    let errs: [Diag] = [];
    names.foreach((nj, j) => {
        let fj = fids[j];
        let slot = -1;
        let g = asm.labmap_get(ix, nj);
        if (g.sec >= 0) { slot = g.sec; };
        if (slot < 0) {
            top += -1;
            slot = len(top) - 1;
            ix = (asm.labmap_put(ix, nj, slot, 0)).map;
        };
        let other = -1;
        let q = top[slot];
        while (q >= 0 && other < 0) {
            if (pfile[q] != fj) { other = ppos[q]; };
            q = pnext[q];
        };
        if (other >= 0) {
            errs += { msg: "duplicate definition '" + nj + "': " + origin_at(origin, lines[other], false) + " defines it too (imported files share one namespace; rename one)", line: lines[j], col: cols[j] };
        };
        pfile += fj;
        ppos += j;
        pnext += top[slot];
        top[slot] = len(pfile) - 1;
    });
    errs
};

// top_def_name of a top-level statement as rename.y binds it: a module's
// (`import fs;`) qualified, `fs.exists` (rename.y rn_qualify).
def top_name_in(s: Node, origin: Origin) -> str {
    let nm = top_def_name(s);
    if (len(nm) == 0 || nm.starts_with("y_")) {
        nm
    } else {
        let ln: long = s.line;
        let fid = origin_file(origin, ln);
        let om = origin.mods;
        if (fid < len(om) && om[fid] != "") { om[fid] + "." + nm } else { nm }
    }
};

// The name a top-level statement defines as a function -- a def, or a let
// bound to a function literal; both hoist -- or "" (rename.y rn_decl_name).
def top_def_name(s: Node) -> str {
    if (s.k == K.decl) {
        let decl: Decl = s;
        top_def_name_go(decl)
    } else {
        ""
    }
};

def top_def_name_go(s: Decl) -> str {
    // NOTE: one `s.v.k` read per body (see rename.y rn_prepass_decl note).
    if (s.kind == "def") {
        s.name
    } else if (s.v.k == K.func) {
        s.name
    } else {
        ""
    }
};

// ── globals and hoisting ───────────────────────────────────────────────
// Every variable bound directly in the program is a GLOBAL: one 8-byte
// .bss cell, read and written by label from any function. So a def that
// names one captures nothing, and every top-level def is hoisted: emitted
// once, called directly by label, from anywhere (forward calls too).

// The program's top-level variable declarations, in order (function
// bindings are defs, not variables).
def global_decls(stmts: [Node]) -> [Node] {
    let out: [Node] = [];
    stmts.foreach((e) => {
        let s: Node = e;
        if (s.k == K.decl) {
            let decl: Decl = s;
            if (decl.kind == "def") { }
            else if (decl.v.k == K.func) { }
            else { out += decl; };
        }
    });
    out
};

def decl_name(d: Decl) -> str {
    d.name
};

// Each global's cell label and type, in program order. A declared type
// wins; otherwise the initializer is inferred in a scope holding the
// hoisted defs and the globals before it (what main sees when it runs
// the declaration). Labels count from the unit's `gbase` (compile_unit),
// so two units' globals never share one.
def global_entries(st: EmitSt, gdecls: [Node], gbase: long) -> [Sym] {
    let f: EmitSt = { ir: [], txt: [], rodata: st.rodata, uid: st.uid,
        fuid: 0, loc: 1, env: [], slots: 0, temp: 0,
        self_label: -1, end_label: -1, fns: st.fns, bodies: st.bodies,
        btext: st.btext, blabels: st.blabels };
    let out: [Sym] = [];
    gdecls.foreach((e, i) => {
        let d: Decl = e;
        let gn = decl_name(d);
        let t: Type = decl_type(d);
        if (t.k == K.tnone) {
            t = infer(f, decl_value(d));
        }
        let lbl = arch.arch_global_label(gbase + i, gn);
        out += { name: gn, label: lbl, typ: t };
        f = env_define(f, gn, "global", 0, lbl_new(lbl), "", t);
    });
    out
};

def decl_type(d: Decl) -> Type {
    d.typ
};

def decl_value(d: Decl) -> Node {
    d.v
};

// Named functions that need a closure record: a def reading a variable
// that is neither a global nor a function, or naming a function that
// needs one itself (a direct call could not hand that one its record).
// Iterated to a fixpoint. A function's own name is no capture (its body
// reaches itself through its own record, see emit_one_fn).
def capturing_defs(defs: [FnDef], gnames: [str]) -> [str] {
    let fnames: [str] = [];
    let i = 0;
    while (i < len(defs)) {
        fnames += defs[i].name;
        i++;
    };
    let caps: [[str]] = [];
    let out: [str] = [];
    let exm = namemap_build(gnames);
    let fnm = namemap_build(fnames);
    i = 0;
    while (i < len(defs)) {
        let d = defs[i];
        let cs = fn_captures(d.func, exm, d.name);
        caps += [cs];
        let j = 0;
        let reads_var = false;
        while (j < len(cs)) {
            let cn: str = cs[j];
            if (!(namemap_get(fnm, cn) >= 0)) { reads_var = true; };
            j++;
        };
        if (reads_var) { out += d.name; }
        i++;
    };
    let changed = true;
    while (changed) {
        changed = false;
        i = 0;
        while (i < len(defs)) {
            let d = defs[i];
            if (!(name_in(out, d.name))) {
                let cs = caps[i];
                let j = 0;
                let hit = false;
                while (j < len(cs)) {
                    let cn: str = cs[j];
                    if (name_in(out, cn)) { hit = true; }
                    j++;
                };
                if (hit) {
                    out += d.name;
                    changed = true;
                }
            };
            i++;
        };
    };
    out
};

// The hoisted defs' types (st.fns order) with every omitted return type
// inferred from the body (see infer_fn_ret). With `only` non-empty, just
// the bodies reading one of those names are re-inferred; the rest keep
// their st.fns entry.
def fix_fn_types(st: EmitSt, hdefs: [FnDef], only: [str]) -> [Sym] {
    let out: [Sym] = [];
    let ftab = st.fns.syms;
    hdefs.foreach((d, fx) => {
        let fe0 = ftab[fx];
        let redo = ret_omitted(d.func);
        if (redo && len(only) > 0) {
            redo = reads_any(d.func, only);
        }
        if (redo) {
            out += { name: fe0.name, label: fe0.label,
                typ: type_node({ k: K.tfunc, args: fn_ptypes(d.func), ret: infer_fn_ret(st, d.func) }) };
        } else {
            out += fe0;
        };
    });
    out
};

def ret_omitted(func: Func) -> bool {
    fn_ret(func).k == K.tnone
};

def fn_ptypes(func: Func) -> [Type] {
    func.ptypes
};

def reads_any(func: Func, names: [str]) -> bool {
    let reads = fv_ids(func.body, []);
    let i = 0;
    let found = false;
    while (i < len(reads)) {
        let n: str = reads[i];
        if (name_in(names, n)) { found = true; }
        i++;
    };
    found
};

// ── phase timing ───────────────────────────────────────────────────────
// Every phase records elapsed microseconds and heap bytes consumed, so
// `ycc --time` can show where wall time AND memory go (the arena never
// frees, so allocation volume is as interesting as elapsed time).

def phase_end(times: [Timing], name: str, t0: long, h0: long) -> { times: [Timing], t: long, h: long } {
    let t1 = clock_us();
    let h1 = heap_used();
    times += { name: name, us: t1 - t0, heap: h1 - h0 };
    { times: times, t: t1, h: h1 }
};

// ── compilation units ──────────────────────────────────────────────────
// A program is LINKED from units: its own -- the program file and the
// files it imports, spliced into one text (native_resolve_x) -- and the
// std units it needs (std_units: std/prelude.y, std/exec.y, std/str.y,
// std/rt.y). compile_unit takes one unit from AST to assembly text, one
// body per function; what it sees of another unit is that unit's
// EXPORTS -- the names, labels and types of its top-level defs -- bound
// as externs. link_units joins the bodies of all units and shakes them
// together (prune_bodies), so a std function the program never reaches
// costs nothing.
//
// Labels cannot collide: a unit numbers its uids (function, string and
// local labels) and its global cells from its own base (std_unit_base;
// the program's is 0). A unit's top-level statements run in an INIT
// function; the program's `_start` calls the linked units' inits first,
// in link order.
//
// The program sees the exports of the LIBRARY units (prelude, exec),
// whose defs are its API. The RUNTIME units (rt, str) hold only `y_`
// helpers, which generated code calls by fixed label (runtime_base), so
// they are linked but never bound: the program's checker and emitter
// scopes stay free of a hundred-odd helper names. A program def wearing
// a runtime label (a `y_` def of its own) replaces the std body of that
// label everywhere, std-internal calls included (link_units drops the
// std one).
//
// A PACKAGE (`ycc build`) is a unit too: its lib file and the files it
// imports, compiled once (compile_package) and kept as an object
// (unit_obj). A program or package importing it sees its exports under
// qualified names (`json.parse`, see pkg_ns) -- its top-level defs, and
// its globals, read-only -- and the default values of its defs'
// parameters (dfl), so a call may leave them out as at home.
//
// exports: Syms (types.y). dfl: per top-level def with defaults,
// rename.y's list of them (one lit_code per parameter, see lit_code).
type DflCode = { name: str, vals: [str] };
// `bodies` is each body's IR items and `btext` the raw lines its IR_TEXT
// items index. A unit read from the std pack or an object cache carries them
// PACKED instead: `blob` one blob per body (pack_body) and `btext` the lines,
// and link_units decodes the bodies it keeps (unpack_body).
type Unit = { name: str, files: [str], exports: [Sym], init: str, bodies: [[long]], btext: [[str]], blob: [str], labels: [str], refs: [[str]], rodata: [[str]], globals: [str], dfl: [DflCode] };
// What compile_unit binds besides the unit's own names: the externs
// (`ext`) and their parameter defaults (`dfl`, as rename.y takes them),
// the package namespaces the unit imports (`pkgs`, see pkg_ns), the
// init labels `_start` calls first (`inits`), and whether a linked unit
// reads argv() (`argv`: `_start` must materialize it then).
type Externs = { ext: [Sym], dfl: [Dfl], pkgs: [str], inits: [str], argv: bool };

def unit_empty(name: str) -> Unit {
    let fs: [str] = [];
    let xs: [Sym] = [];
    let bs: [[long]] = [];
    let bt: [[str]] = [];
    let ls: [str] = [];
    let fr: [[str]] = [];
    let rs: [[str]] = [];
    let gs: [str] = [];
    let ds: [DflCode] = [];
    { name: name, files: fs, exports: xs, init: "", bodies: bs, btext: bt,
        blob: [], labels: ls, refs: fr, rodata: rs, globals: gs, dfl: ds }
};

// No externs at all (a std unit compiled on its own).
def externs_none() -> Externs {
    let xs: [Sym] = [];
    let ds: [Dfl] = [];
    let ps: [str] = [];
    let ins: [str] = [];
    { ext: xs, dfl: ds, pkgs: ps, inits: ins, argv: false }
};

def std_unit_src(name: str) -> str {
    if (name == "prelude") {
        PRELUDE_SRC
    } else if (name == "exec") {
        EXEC_SRC
    } else if (name == "str") {
        STR_SRC
    } else {
        RT_SRC
    }
};

// Where a std unit's uids and global cells start counting (see the
// section note): far past anything one program numbers -- ycc itself
// stays under a million.
def std_unit_base(name: str) -> long {
    if (name == "prelude") {
        1000000000
    } else if (name == "exec") {
        2000000000
    } else if (name == "str") {
        3000000000
    } else {
        4000000000
    }
};

// A library unit: the program sees its exports (see the section note).
def std_unit_bound(name: str) -> bool {
    name == "prelude" || name == "exec"
};

// Every std unit, in link order (see native_resolve_x).
def std_unit_names() -> [str] {
    ["prelude", "exec", "str", "rt"]
};

// The std units `names` (link order, see native_resolve_x): from `pack`
// (std_pack) when it has them, else compiled from the embedded sources.
// exec calls into the prelude (y_stdin_sync), so it sees the prelude's
// exports -- linked, and so compiled, before it.
def std_units(names: [str], pack: str) -> [Unit] {
    let out: [Unit] = [];
    if (len(pack) > 0) {
        out = std_unpack(pack, names);
    }
    if (len(out) == 0) {
        names.foreach((el) => {
            let nm: str = el;
            let ext: [Sym] = [];
            if (nm == "exec") {
                out.foreach((u) => {
                    if (u.name == "prelude") { ext += u.exports; }
                });
            }
            out += std_compile(nm, ext);
        });
    }
    out
};

// One std unit, from its embedded source. It always carries its `.loc`
// markers (link_units strips them unless -g), so it compiles the same
// for every program. A failure here is the compiler's own bug: reported
// as one, and the run ends.
def std_compile(name: str, ext: [Sym]) -> Unit {
    let path = "std/" + name + ".y";
    let ssrc = std_text(std_unit_src(name));
    // A std unit is tokenized straight from its embedded bytes, so it never
    // goes through meta_scan: a `#{` here would reach the lexer as a bare `#`
    // and be reported as an expression error. A block in a std source is a
    // diagnostic (ideas/meta.md, "std sources"): it would run after the
    // program's own pass, with no origin to point at.
    if (meta.mg_on && index_of(ssrc, "#{") >= 0) {
        puts("error: " + path + ": a meta block cannot appear in a std source: std units are compiled from their embedded text after the program's own pass, so a block there has no generator to run in\n");
        exit(1);
    };
    let ast = parser.parse_program(lexer.tokenize(ssrc));
    let noimports: [str] = [];
    let nolines: [long] = [];
    let xt = externs_none();
    xt.ext = ext;
    let r = compile_unit(ast, noimports, { files: [path], nuser: 1, file: nolines, line: nolines, mods: [""] }, true, 0, name, std_unit_base(name), xt, []);
    if (!r.ok) {
        r.errors.foreach((e) => {
            puts("ycc: internal error: " + path + ":" + tostring(e.line) + ":" + tostring(e.col) + ": " + e.msg + "\n");
        });
        exit(1);
    }
    r.unit
};

// The name a renamed top-level def was written with, or "" for one a
// later def of the same name replaced (rename.y's `name$shadowK`).
def export_name(n: str) -> str {
    let d = index_of(n, "$");
    if (index_of(n, ".") >= 0) {
        // a module's (`fs.exists`): the unit's own import, not its export
        ""
    } else if (d < 0) {
        n
    } else if (is_all_digits(n[d + 1:])) {
        n[:d]
    } else {
        ""
    }
};

// A unit's exports: its top-level defs, by the names they were written
// with, with the labels and types `fns` gives them. hdefs holds them in
// statement order (a def's nested ones follow it), and fns starts with
// hdefs' entries.
def unit_exports(stmts: [Node], hdefs: [FnDef], fns: [Sym]) -> [Sym] {
    let out: [Sym] = [];
    let h = 0;
    stmts.foreach((e) => {
        let nm = top_def_name(e);
        if (len(nm) > 0) {
            let h0 = h;
            let found = false;
            while (!found && h < len(hdefs)) {
                if (hdefs[h].name == nm) { found = true; } else { h++; };
            };
            if (found) {
                let xn = export_name(nm);
                if (len(xn) > 0) {
                    let fe = fns[h];
                    out += { name: xn, label: fe.label, typ: fe.typ };
                }
                h++;
            } else {
                h = h0;
            };
        }
    });
    out
};

// What compile_unit gives: ok, or the errors; the warnings (lint.y); the
// phase times; the unit.
type UnitRes = { ok: bool, errors: [Diag], warnings: [Diag], times: [Timing], unit: Unit };

// One unit, AST to assembly text (see the section note). `name` is ""
// for the program's own unit, whose top-level statements are `_start`,
// preceded by calls to `xt.inits` (the linked units' init labels); any
// other unit's are its init function. `xt.ext` holds the externs, bound
// by name in the checker and the emitter (see Externs).
def compile_unit(ast: Block, imports: [str], origin: Origin, debug: bool, wlevel: long, name: str, base: long, xt: Externs, ogen: [bool]) -> UnitRes {
    tyset_reset();
    dbg_lines = debug;
    dbg_file = origin.file;
    dbg_line = origin.line;
    let ext = xt.ext;
    let inits = xt.inits;
    pkg_ns = xt.pkgs;
    let times: [Timing] = [];
    let pt = clock_us();
    let ph = heap_used();
    let ast2: Block = strip_ns(ast, imports);
    let pr = phase_end(times, "strip_ns", pt, ph);
    times = pr.times; pt = pr.t; ph = pr.h;
    // Static name resolution: every binding gets a unique name, so neither
    // the checker nor the emitter deals with scopes or shadowing.
    let ast3: Block = rename.rename_program_x(ast2, xt.dfl, origin.file, origin.mods);
    pr = phase_end(times, "rename", pt, ph);
    times = pr.times; pt = pr.t; ph = pr.h;
    let errors = types.check_program(ast3, ext);
    pr = phase_end(times, "typecheck", pt, ph);
    times = pr.times; pt = pr.t; ph = pr.h;
    // collect every named def (top-level, nested, let-bound)
    let defs = collect_from_block(ast3.stmts, []);
    // A def that replaces another file's goes first: the checker's errors
    // may be only its consequences.
    let dups = find_dup(ast.stmts, origin);
    if (len(dups) > 0) {
        dups += errors;
        errors = dups;
    }
    let warnings: [Diag] = [];
    if (len(errors) > 0) {
        { ok: false, errors: errors, warnings: warnings, times: times, unit: unit_empty(name) }
    } else {
        // The warnings (lint.y): the program's unit's and a package's,
        // never a std unit's.
        if (len(name) == 0 || pkg_base(base)) {
            warnings = lint.lint_unit(ast, ast3, origin.file, origin.mods, wlevel, ogen);
            pr = phase_end(times, "lint", pt, ph);
            times = pr.times; pt = pr.t; ph = pr.h;
        };
        let gdecls = global_decls(ast3.stmts);
        let gnames: [str] = [];
        gdecls.foreach((e) => {
            let gdecl: Decl = e;
            gnames += decl_name(gdecl);
        });
        // The externs, and the init functions `_start` calls (by their
        // labels: no Y name has that shape, and the checker never sees
        // these).
        let xfns: [Sym] = [];
        xfns += ext;
        let xids = fntab_ids(ext);
        inits.foreach((e) => {
            let il: str = e;
            xfns += { name: il, label: il, typ: { k: K.tfunc, args: [], ret: { k: K.tvoid } } };
            xids += lbl_new(il);
        });
        // A def needing a closure record is emitted where it is created
        // (gen_decl); every other one is hoisted: a label in st.fns. A
        // call to an extern is no capture either.
        let cexcl: [str] = [];
        cexcl += gnames;
        cexcl += fn_names_of(ext);
        let capdefs = capturing_defs(defs, cexcl);
        let hdefs: [FnDef] = [];
        // assign labels + env entries (also pre-binds for calls); the
        // unit's uids count from its base
        let st = st_new();
        st = { ir: st.ir, txt: st.txt, rodata: st.rodata, uid: base + 1,
            fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots, temp: st.temp,
            self_label: st.self_label, end_label: st.end_label, fns: st.fns,
            bodies: st.bodies, btext: st.btext, blabels: st.blabels };
        st = next_uid(st).st;
        let hsyms: [Sym] = [];
        let hids: [long] = [];
        let i = 0;
        while (i < len(defs)) {
            let d = defs[i];
            if (!(name_in(capdefs, d.name))) {
                hdefs += d;
                let rl = next_uid(st);
                st = rl.st;
                // A ndef's label is the one it named -- the assembly it
                // calls into. Everything else gets a generated label.
                let label = "";
                label = len(d.func.label) > 0 ? d.func.label : fn_label_of(rl.uid, d.name);
                let lid = lbl_new(label);
                hsyms += { name: d.name, label: label, typ: func_type(d.func) };
                hids += lid;
                st = env_define(st, d.name, "func", 0, lid, "", func_type(d.func));
            };
            i++;
        };
        // The externs go after the hoisted defs (fix_fn_types and the
        // emission loop read those by position), the globals after both
        // (see fns_kind).
        let fns0: [Sym] = [];
        fns0 += hsyms;
        fns0 += xfns;
        let ids0: [long] = [];
        ids0 += hids;
        ids0 += xids;
        st = { ir: st.ir, txt: st.txt, rodata: st.rodata, uid: st.uid,
            fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots, temp: st.temp,
            self_label: st.self_label, end_label: st.end_label,
            fns: fntab_of(fns0, ids0), bodies: st.bodies, btext: st.btext, blabels: st.blabels };
        // Fill in the return type of every unannotated def, so call sites
        // know what a call yields; then type the globals with those, and
        // redo the defs that read a global (they now know its type).
        let fixed1 = fix_fn_types(st, hdefs, []);
        let fns1: [Sym] = [];
        fns1 += fixed1;
        fns1 += xfns;
        st = { ir: st.ir, txt: st.txt, rodata: st.rodata, uid: st.uid,
            fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots, temp: st.temp,
            self_label: st.self_label, end_label: st.end_label,
            fns: fntab_of(fns1, ids0), bodies: st.bodies, btext: st.btext, blabels: st.blabels };
        let gl = app_cells(global_entries(st, gdecls, base), ast3.stmts);
        let fixedfns: [Sym] = [];
        fixedfns += fixed1;
        fixedfns += xfns;
        fixedfns += gl;
        let gids = fntab_ids(gl);
        let idsA: [long] = [];
        idsA += ids0;
        idsA += gids;
        if (len(gl) > 0) {
            st = { ir: st.ir, txt: st.txt, rodata: st.rodata, uid: st.uid,
                fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots, temp: st.temp,
                self_label: st.self_label, end_label: st.end_label,
                fns: fntab_of(fixedfns, idsA), bodies: st.bodies,
                btext: st.btext, blabels: st.blabels };
            let fixed2 = fix_fn_types(st, hdefs, gnames);
            fixedfns = [];
            fixedfns += fixed2;
            fixedfns += xfns;
            fixedfns += gl;
        }
        st = { ir: st.ir, txt: st.txt, rodata: st.rodata, uid: st.uid,
            fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots, temp: st.temp,
            self_label: st.self_label, end_label: st.end_label,
            fns: fntab_of(fixedfns, idsA), bodies: st.bodies,
            btext: st.btext, blabels: st.blabels };
        // emit each hoisted body. A ndef has none: its label names
        // assembly that is already in the output, so emitting anything under
        // that label would duplicate it.
        i = 0;
        while (i < len(hdefs)) {
            let d = hdefs[i];
            if (len(d.func.label) == 0) {
                let rf = next_uid(st);
                st = rf.st;
                st = emit_one_fn(st, st.fns.ids[i], rf.uid, d.func, false, false, [], "");
            };
            i++;
        };
        pr = phase_end(times, "emit_fns", pt, ph);
        times = pr.times; pt = pr.t; ph = pr.h;
        let exports = unit_exports(ast3.stmts, hdefs, st.fns.syms);
        let udfl: [DflCode] = [];
        if (pkg_base(base)) {
            exports = pkg_exports(exports, gl);
            udfl = unit_dfl(ast2.stmts, origin);
        }
        // The top-level statements with hoisted defs skipped (emitted
        // above, calls go direct to their labels). Variable declarations
        // store to their globals (bind_decl). A def needing a record would
        // be created here like a nested one — but a top-level def can only
        // read globals and functions, so none does.
        let main_stmts: [Node] = [];
        let noargs: [Node] = [];
        inits.foreach((e) => {
            let cl: str = e;
            let call: Call = { k: K.call, callee: { k: K.id, v: cl, line: 0, col: 0 }, args: noargs, line: 0, col: 0 };
            main_stmts += call;
        });
        let pstmts: [Node] = ast3.stmts;
        pstmts.foreach((e) => {
            let s: Node = e;
            if (s.k == K.decl) {
                let decl: Decl = s;
                if (decl.kind == "def") {
                    if (name_in(capdefs, decl.name)) {
                        main_stmts += decl;
                    }
                } else if (decl.v.k == K.func) {
                    if (name_in(capdefs, decl.name)) {
                        main_stmts += decl;
                    }
                } else {
                    main_stmts += decl;
                };
            } else {
                main_stmts += s;
            };
        });
        let rm = next_uid(st);
        st = rm.st;
        let init = "";
        if (len(name) == 0) {
            // Only pay for argv materialization when the program uses it
            // (or a package it links does).
            let want_argv = uses_argv(ast3.stmts) || xt.argv;
            let main_body: Block = { k: K.block, stmts: main_stmts, line: 0, col: 0 };
            let start_fn: EmitMain = { params: [], ptypes: [], ret: type_node({ k: K.tvoid }), body: main_body, line: 0, col: 0 };
            st = emit_one_fn(st, lbl_new("_start"), rm.uid, start_fn, true, want_argv, [], "");
        } else if (len(main_stmts) > 0) {
            init = arch.arch_fn_label(rm.uid, "init");
            let init_body: Block = { k: K.block, stmts: main_stmts, line: 0, col: 0 };
            let init_fn: EmitMain = { params: [], ptypes: [], ret: type_node({ k: K.tvoid }), body: init_body, line: 0, col: 0 };
            st = emit_one_fn(st, lbl_new(init), rm.uid, init_fn, false, false, [], "");
        }
        pr = phase_end(times, "emit_start", pt, ph);
        times = pr.times; pt = pr.t; ph = pr.h;
        let glabels: [str] = [];
        gl.foreach((ge) => {
            glabels += ge.label;
        });
        // Each body's label and the labels it references: what linking
        // shakes by (prune_bodies). The label the emitter recorded beside
        // the body (emit_one_fn); the references are read out of the ITEMS
        // (the same set line_refs_b found in the text: every label operand,
        // the label of a `lea lbl(%rip)`, both labels of a `mov $A-B`).
        let ubodies = st.bodies;
        let ubtext: [[str]] = st.btext;
        let blabels: [str] = st.blabels;
        let brefs: [[str]] = [];
        ubodies.foreach((e) => {
            let ub: [long] = e;
            brefs += [ir_refs(ub)];
        });
        let unit: Unit = { name: name, files: origin.files, exports: exports,
            init: init, bodies: ubodies, btext: ubtext, blob: [],
            labels: blabels, refs: brefs, rodata: st.rodata, globals: glabels,
            dfl: udfl };
        { ok: true, errors: errors, warnings: warnings, times: times, unit: unit }
    }
};

// A package's unit (compile_package): its base follows the std units'.
def pkg_base(base: long) -> bool {
    base >= 5000000000
};

// A package's exports: its top-level defs (`xs`, unit_exports), then its
// globals -- each str global's companion cell (app_cells) beside it, so
// an importer's reads clear it too (gen_id). A name a later global of the
// same name replaces is dropped.
def pkg_exports(xs: [Sym], gl: [Sym]) -> [Sym] {
    let all: [Sym] = [];
    all += xs;
    gl.foreach((ge) => {
        let gn: str = ge.name;
        let xn = "";
        if (gn[len(gn) - 2:] == "#o") {
            let bn = export_name(gn[:len(gn) - 2]);
            if (len(bn) > 0) { xn = bn + "#o"; }
        } else {
            xn = export_name(gn);
        };
        if (len(xn) > 0) { all += { name: xn, label: ge.label, typ: ge.typ }; }
    });
    let out: [Sym] = [];
    all.foreach((e, j) => {
        let later = false;
        let m = j + 1;
        while (!later && m < len(all)) {
            if (all[m].name == e.name) { later = true; }
            m = m + 1;
        };
        if (!later) { out += e; }
    });
    out
};

// The parameter defaults of a unit's top-level defs, by the names they
// were written with (see Unit): a later def of a name replaces an
// earlier one's.
def unit_dfl(stmts: [Node], origin: Origin) -> [DflCode] {
    let out: [DflCode] = [];
    stmts.foreach((el) => {
        let s: Node = el;
        let nm = top_name_in(s, origin);
        // (not an imported module's: see export_name)
        if (len(nm) > 0 && index_of(nm, ".") < 0) {
            let keep: [DflCode] = [];
            out.foreach((d) => {
                if (d.name != nm) { keep += d; }
            });
            let decl: Decl = s;
            let func: Func = decl.v;
            let vals = dfl_codes(func);
            if (len(vals) > 0) { keep += { name: nm, vals: vals }; }
            out = keep;
        }
    });
    out
};

// A def's parameter defaults (rename.y rn_note_defaults) as lit_codes,
// or [] when it has none.
def dfl_codes(func: Func) -> [str] {
    let dv: [Node] = func.defs;
    let out: [str] = [];
    let any = false;
    dv.foreach((d) => {
        let dk: long = d.k;
        if (dk != K.void) { any = true; }
        out += lit_code(d);
    });
    if (any) { out } else { let nd: [str] = []; nd }
};

// A parameter default as text: `v` none, `o` optional, else a kind
// letter and the literal's text (parser.y lit_type has the kinds).
def lit_code(d: Node) -> str {
    let k: long = d.k;
    if (k == K.void) { "v" }
    else if (k == K.optarg) { "o" }
    else if (k == K.num) { let leaf: Leaf = d; "n" + lit_text(leaf) }
    else if (k == K.str) { let leaf: Leaf = d; "s" + lit_text(leaf) }
    else if (k == K.bool) { let leaf: Leaf = d; "b" + lit_text(leaf) }
    else if (k == K.char) { let leaf: Leaf = d; "c" + lit_text(leaf) }
    else { let un: Un = d; "-" + lit_neg_text(un) }
};

def lit_text(d: Leaf) -> str {
    d.v
};

def lit_neg_text(d: Un) -> str {
    let e: Leaf = d.e;
    e.v
};

def lit_decode(c: str) -> Node {
    let t = c[:1];
    let v = c[1:];
    if (t == "v") { normnode({ k: K.void, line: 0, col: 0 }) }
    else if (t == "o") { normnode({ k: K.optarg, line: 0, col: 0 }) }
    else if (t == "n") { normnode({ k: K.num, v: v, line: 0, col: 0 }) }
    else if (t == "s") { normnode({ k: K.str, v: v, line: 0, col: 0 }) }
    else if (t == "b") { normnode({ k: K.bool, v: v, line: 0, col: 0 }) }
    else if (t == "c") { normnode({ k: K.char, v: v, line: 0, col: 0 }) }
    else { normnode({ k: K.un, op: "-", e: { k: K.num, v: v, line: 0, col: 0 }, line: 0, col: 0 }) }
};

// A linked unit's body's `.loc` markers (std_compile and compile_package
// always emit them, numbering the unit's own files from 1) moved by
// `off` to the unit's place in the program's `.file` table under -g,
// dropped otherwise.
def link_locs(b: str, off: long) -> str {
    let parts = split(b, "\n.loc ");
    if (len(parts) == 1) {
        b
    } else {
        let out: [str] = [];
        out += parts[0];
        for i in 1..len(parts) {
            let p: str = parts[i];
            if (dbg_lines) {
                let sp = index_of(p, " ");
                out += "\n.loc " + tostring(leading_long(p[:sp]) + off) + p[sp:];
            } else {
                let nl = index_of(p, "\n");
                if (nl >= 0) { out += p[nl:]; }
            };
        };
        join(out, "")
    }
};

// One unit's rodata entries as text, keeping only the blocks a kept body
// reaches AND emitting each distinct literal text once. `refs` is the union
// `shake_refs` gets for arch_consts (the kept bodies' own references plus the
// kept prelude's), so a literal no `lea` names is dead -- measured at 29-92%
// of a program's rodata, and almost always the same 308 bytes, the std
// runtime's error strings and format tables, in every program that does not
// happen to call those functions.
//
// The interning is at link, not in gen_str_const: most duplicates are
// std-vs-program and std-vs-std, so a per-unit table would miss them, and
// putting one in EmitSt would mean touching all 21 rebuild sites plus the C
// twin for nothing. The FIRST block of a text in link order keeps its own
// label and is the one written; every later block of the same text is a loser,
// recorded in `dup_old`/`dup_new` so the body texts can be relabelled
// (relabel_dups).
//
// String entries are exactly [label, len, escaped]; record-type descriptors
// (ty_desc) are [label, canonical form, quads...]: one per label in the
// program (ty_seen, emptied by link_units), and two different forms under one
// label stop the link -- a check that stays over EVERY descriptor, reachable
// or not, since two shapes for one type is a program error either way.
// Descriptors need no interning: `tyset_add` already emits one block per
// distinct form.
//
// The membership tests are asm's hashed labmap, not name_in: 6,727 literals
// against ~30,000 refs would be 200 million string compares. Twice the size,
// because labmap probes linearly and a full table makes every insert walk half
// the slots -- and ONE map for all the units' rodata, because five or six
// builds of a 40,000-entry set at load factor 1 cost 4% of a self-compile.
def rodata_intern(pieces: [str], allrod: [[str]], refs: [str]) -> { pieces: [str], dup_old: [str], dup_new: [str] } {
    let m = asm.labmap_new(len(refs) * 2 + 64);
    refs.foreach((e) => {
        m = (asm.labmap_put(m, e, 1, 0)).map;
    });
    let nall = len(allrod);
    // text -> the index of the winner in `win`, plus loser pairs
    let texts = asm.labmap_new(nall * 2 + 64);
    let win: [str] = [];
    let dup_old: [str] = [];
    let dup_new: [str] = [];
    for s2 in 0..nall {
        let pair = allrod[s2];
        let lbl: str = pair[0];
        if (len(pair) == 3) {
            if (asm.labmap_get(m, lbl).sec > 0) {
                // the key is the escaped text: the 8-byte length is derived
                // from it, so two blocks with one text are one block's worth
                // of bytes
                let text: str = pair[2];
                let seen = asm.labmap_get(texts, text);
                if (seen.sec > 0) {
                    dup_old += lbl;
                    dup_new += win[seen.off];
                } else {
                    texts = (asm.labmap_put(texts, text, 1, len(win))).map;
                    win += lbl;
                    pieces += lbl + ":\n.quad " + tostring(pair[1]) + "\n.string \"" + text + "\"\n";
                };
            }
        } else {
            let form: str = pair[1];
            let added = tyset_add(lbl, form);
            if (added < 0) { ty_collision(lbl, form); };
            if (added > 0 && asm.labmap_get(m, lbl).sec > 0) {
                // a descriptor's address is its type's tag: one byte
                // makes it an address of its own
                pieces += lbl + ":\n.zero 1\n";
            }
        };
    };
    { pieces: pieces, dup_old: dup_old, dup_new: dup_new }
};

// Point a body's `lea` at the label its literal's text ended up with. Only the
// `lea <label>(%rip)` form can name a literal -- the other reference form,
// `mov $A-B`, is arch_consts' trap-string lengths -- so this is the whole job.
//
// Line by line, and the emitter writes one instruction per line, so a line
// holds at most one `lea`: split once, ask each line, put the body back
// together once. The two shapes before it were both quadratic in the body's
// size -- a `str.replace` per reference (490 ms and 345 MB in asm_text on
// ycc.y) and an index_of per reference over the whole body (+9.23% of every
// compile, 511 million instructions). A per-`lea` scan that re-sliced the
// remainder of the body each time allocated 600 MB for the same work.
def relabel_dups(body: str, m: [AsmLabel], dup_new: [str]) -> str {
    let lines = split(body, "\n");
    lines.foreach((_el, i) => {
        let ln: str = lines[i];
        let at = index_of(ln, "lea ");
        if (at >= 0) {
            let rest = ln[at + 4:len(ln)];
            let e = index_of(rest, "(%rip)");
            if (e >= 0) {
                let g = asm.labmap_get(m, (rest[0:e]));
                if (g.sec > 0) {
                    // the label's own length is what is cut out: the winner's
                    // label is what gets longer or shorter
                    lines[i] = ln[0:at + 4] + dup_new[g.off] + rest[e:len(rest)];
                };
            };
        };
    });
    join(lines, "\n")
};

// The program's assembly, as parts to assemble: the bodies of the std units
// and of the packages (`deps`, link order: each after those it imports) and
// then the program's, shaken together, as the emitter's items; then the arch
// prelude and constants the kept bodies reach, every unit's rodata and the
// .bss cells, as text (what asm.y still lexes). Two units defining the same
// `y_`-prefixed name: say so, or return.
//
// That prefix is not a namespace: such a def is emitted under its bare name
// because generated code calls it by a fixed label, so the name IS the
// interface. The linker keeps one body per label (namemap_build in
// prune_bodies, and shake_keep with it) and drops the other, silently -- and
// which one survives follows the order the packages were compiled in:
//
//   app depending on a then b:  a.who() and b.who() both printed "from a"
//   app depending on b then a:  both printed "from b"
//
// std's own `y_` bodies are the exception and are meant to be replaced: a
// program's (or a package's) replaces std's, and link_units drops std's. So
// only the packages and the program are compared here, and a bin with no
// package pays nothing for the check.
def dup_y_label(deps: [Unit], prog: Unit) -> void {
    let nu = len(deps);
    if (nu > 0) {
        let m = asm.labmap_new((nu + 1) * 2 + 16);
        for i in 0..nu + 1 {
            let u: Unit = if (i < nu) { deps[i] } else { prog };
            let labs = u.labels;
            for k in 0..len(labs) {
                let lb: str = labs[k];
                if (lb[:2] == "y_") {
                    let g = asm.labmap_get(m, lb);
                    if (g.sec > 0) {
                        let f = g.sec - 1;
                        let first: str = if (f < nu) { deps[f].name } else { prog.name };
                        puts("error: duplicate y_ name '" + lb + "': '" + first + "' and '" + u.name + "' both define it -- a y_ name is a fixed label generated code calls by, not a name in a namespace, so only one body could be linked; rename one\n");
                        exit(1);
                    } else {
                        m = (asm.labmap_put(m, lb, i + 1, 0)).map;
                    };
                };
            };
        };
    };
};

// 0 = auto (decide from the program), 1 = always, 2 = never: the --gc switch,
// set by the driver before compiling. Auto keeps the collector whenever an
// allocation could happen more than once -- a loop or a recursion that
// reaches the allocator -- because a wrong "no" is an unbounded heap.
let gc_mode: long = 0;

def set_gc_mode(m: long) -> void { gc_mode = m; };

// ── the --gc decision ───────────────────────────────────────────────────
// The collector is needed exactly when an allocation site can run more than
// once: a loop or a recursion that can reach y_alloc. Everything here errs
// toward keeping it -- a wrong "no" is an unbounded heap, a wrong "yes" is a
// few KB of runtime.
//
// A backward jump inside one body's IR (a jump to a label defined earlier in
// the same body) is a loop.
def ir_has_loop(ir: [long]) -> bool {
    let lid: [long] = [];
    let lpos: [long] = [];
    let at = 0;
    while (at < len(ir)) {
        if (ir[at] == insn.IR_LABEL) {
            lid += ir[at + 1];
            lpos += at;
        };
        at += insn.IR_W;
    };
    let found = false;
    at = 0;
    while (at < len(ir)) {
        let f = ir[at];
        if (f < insn.IR_LABEL) {
            let form = insn.ir_form(f);
            if (form.mn[0:1] == "j") {
                let wp = at + 1;
                form.kinds.foreach((k) => {
                    if (k == insn.O_LBL) {
                        let t = ir[wp];
                        let i = 0;
                        while (i < len(lid)) {
                            if (lid[i] == t && lpos[i] < at) { found = true; };
                            i++;
                        };
                    };
                    wp = wp + insn.ir_kind_words(k);
                });
            };
        };
        at += insn.IR_W;
    };
    found
};

// Every label that can reach y_alloc, over kept bodies and kept prelude
// blocks: the reverse closure of y_alloc. Plain loops, not closures: a lambda
// here captures a dozen bindings, and this file is compiler source.
def gc_users(labels: [str], refs: [[str]], keep: [bool], ps: PShake) -> [str] {
    let names: [str] = [];
    let edges: [[str]] = [];
    let i = 0;
    while (i < len(labels)) {
        if (keep[i]) {
            names += labels[i];
            edges += refs[i];
        };
        i++;
    };
    let bn = ps.bnames;
    let br = ps.brefs;
    i = 0;
    while (i < len(bn)) {
        names += bn[i];
        edges += br[i];
        i++;
    };
    let rev: [[str]] = [];
    i = 0;
    while (i < len(names)) {
        let none: [str] = [];
        rev += [none];
        i++;
    };
    let ix = namemap_build(names);
    i = 0;
    while (i < len(names)) {
        let es = edges[i];
        let j = 0;
        while (j < len(es)) {
            let k = namemap_get(ix, es[j]);
            if (k >= 0) { rev[k] += names[i]; };
            j++;
        };
        i++;
    };
    let out: [str] = [];
    let work: [str] = [];
    if (namemap_get(ix, "y_alloc") >= 0) {
        out += "y_alloc";
        work += "y_alloc";
        while (len(work) > 0) {
            let w = work[0];
            work = work[1:len(work)];
            let j = namemap_get(ix, w);
            if (j >= 0) {
                let rs = rev[j];
                let k = 0;
                while (k < len(rs)) {
                    if (!(name_in(out, rs[k]))) {
                        out += rs[k];
                        work += rs[k];
                    };
                    k++;
                };
            };
        };
    };
    out
};

// A body that calls back into itself, directly or through a cycle, and can
// reach y_alloc. Only consulted when nothing has a loop, so the walk is over
// a handful of nodes.
def gc_recursive(labels: [str], refs: [[str]], keep: [bool], users: [str]) -> bool {
    let ix = namemap_build(labels);
    let found = false;
    let i = 0;
    while (i < len(labels) && !found) {
        if (keep[i] && name_in(users, labels[i])) {
            let stack: [str] = [];
            let rs = refs[i];
            let j = 0;
            while (j < len(rs)) { stack += rs[j]; j++; };
            let seen: [str] = [];
            while (len(stack) > 0 && !found) {
                let w = stack[len(stack) - 1];
                stack = stack[0:len(stack) - 1];
                if (w == labels[i]) {
                    found = true;
                } else if (!(name_in(seen, w))) {
                    seen += w;
                    let k = namemap_get(ix, w);
                    if (k >= 0 && keep[k]) {
                        let ks = refs[k];
                        let m = 0;
                        while (m < len(ks)) { stack += ks[m]; m++; };
                    };
                };
            };
        };
        i++;
    };
    found
};

// auto (0): link the collector only when an allocation can repeat. always (1)
// and never (2) say so outright.
def gc_decide(mode: long, labels: [str], refs: [[str]], keep: [bool], all: [[long]], allblob: [str], ps: PShake, threads: bool) -> bool {
    if (mode == 1) { true }
    else if (mode == 2) { false }
    else if (threads) { true }
    else {
        let users = gc_users(labels, refs, keep, ps);
        // a kept body with a loop that can reach y_alloc
        let loops = false;
        let i = 0;
        while (i < len(labels) && !loops) {
            if (keep[i] && name_in(users, labels[i])) {
                let bd: [long] = all[i];
                if (len(bd) == 0) { bd = unpack_body(allblob[i]); };
                if (len(bd) > 0 && ir_has_loop(bd)) { loops = true; };
            };
            i++;
        };
        if (loops) { true } else {
            // a kept prelude block other than the allocator's own that can
            // reach y_alloc: the helpers loop, and their asm is not parsed
            let pu = false;
            let bn = ps.bnames;
            i = 0;
            while (i < len(bn) && !pu) {
                if (!(bn[i][0:7] == "y_alloc") && name_in(users, bn[i])) { pu = true; };
                i++;
            };
            if (pu) { true } else { gc_recursive(labels, refs, keep, users) }
        }
    }
};

def link_units(std: [Unit], deps: [Unit], prog: Unit, gcmode: long) -> [LinkPart] {
    let units: [Unit] = [];
    units += std;
    units += deps;
    let nu = len(units);
    // -g: the program's files, then the linked units' -- the last linked
    // first (the order the std chunks were numbered in when they were
    // spliced into the program's text). offs[j]: what unit j's own file
    // numbers (from 1) move by.
    let files: [str] = [];
    files += prog.files;
    let offs: [long] = [];
    let k = 0;
    while (k < nu) {
        offs += 0;
        k++;
    };
    k = nu - 1;
    while (k >= 0) {
        let uk = units[k];
        offs[k] = len(files);
        files += uk.files;
        k--;
    };
    // The runtime labels the program and the packages define (every
    // runtime label starts `y_`): they replace the std units' own.
    let plabels: [str] = [];
    for ou in len(std)..nu + 1 {
        let olab: [str] = [];
        if (ou < nu) { let du = units[ou]; olab = du.labels; } else { olab = prog.labels; };
        olab.foreach((e) => {
            let pl: str = e;
            if (pl[:2] == "y_") { plabels += pl; }
        });
    };
    // Every body, with its label, its references, and the `.loc` offset
    // of its unit (-1: the program's own, numbered as they are). A body's
    // ITEMS for a unit compiled in this run (and the raw lines they index),
    // or the TEXT a pack carries, in `btext`.
    let all: [[long]] = [];
    let alltxt: [[str]] = [];
    // A pack unit's body, still packed (empty items); decoded in the parts
    // loop below, once the shake has said it is kept.
    let allblob: [str] = [];
    let labels: [str] = [];
    let refs: [[str]] = [];
    let fno: [long] = [];
    for j in 0..nu {
        let u = units[j];
        let f = offs[j];
        let ub = u.bodies;
        let ubl = u.blob;
        let ul = u.labels;
        let ur = u.refs;
        ul.foreach((e, b) => {
            let lb: str = e;
            let drop = false;
            if (j < len(std) && len(plabels) > 0) {
                if (lb[:2] == "y_") { drop = name_in(plabels, lb); }
            }
            if (!drop) {
                if (len(ub) > 0) {
                    all += [ub[b]];
                    allblob += "";
                } else {
                    all += [[]];
                    allblob += ubl[b];
                };
                alltxt += [u.btext[b]];
                labels += lb;
                refs += [ur[b]];
                fno += f;
            }
        });
    };
    let plab = prog.labels;
    let pbodies = prog.bodies;
    let prefs = prog.refs;
    pbodies.foreach((e, pb2) => {
        all += [e];
        allblob += "";
        alltxt += [prog.btext[pb2]];
        labels += plab[pb2];
        refs += [prefs[pb2]];
        fno += -1;
    });
    // Body-level tree shaking comes first: its output is also the root
    // set for shaking the arch prelude, and the kept prelude's references
    // shake the rodata constants.
    let extra: [str] = [];
    let shaken = prune_bodies(labels, refs, extra);
    let keep = shaken.keep;
    let body_refs = shaken.refs;
    let core_lines = check_os_call_names(arch.arch_prelude_lines());
    // The Windows syscall self-test (arch/wselftest.s): no lines off Windows,
    // and on Windows the _start prologue below calls the label it defines. It
    // goes through the prelude so the shaker sees what it references.
    core_lines += arch.w_self_test_lines();
    let thr = uses_threads(body_refs);
    let mth = uses_math(body_refs);
    let pb = prelude_blocks(prelude_with(core_lines, thr, mth));
    let ps = shake_prelude(pb, body_refs);
    // A cell no kept code reads, whose initializer only allocates, is dead:
    // dropping that range is what keeps the allocator -- and with it the whole
    // collector -- out of a program that never allocates. Every unit's cells
    // count, not just the program's (rt.y's CLK_TS is `[0; 2]`, and its
    // initializer was the only thing naming y_alloc in hello.y), and a packed
    // body's items are decoded so a cell is read only if a body really reads
    // it. The prelude is then shaken again, because the drop can remove the
    // last reference to a prelude block.
    let reads: [str] = [];
    all.foreach((e, ri) => {
        if (keep[ri]) {
            let bd: [long] = e;
            if (len(bd) == 0) { bd = unpack_body(allblob[ri]); };
            if (len(bd) > 0) {
                reads = cell_reads(bd, reads)
            } else {
                // No blob: the refs are all that can be seen and they include
                // the stores, so this body's cells look read. Conservative on
                // purpose -- a cell dropped while a body reads it is an
                // undefined label at assembly.
                reads += refs[ri]
            };
        };
    });
    reads += ps.refs;
    let cells: [str] = [];
    units.foreach((u) => {
        cells += u.globals;
    });
    cells += prog.globals;
    let dead_cells: [str] = [];
    cells.foreach((cell) => {
        if (!name_in(reads, cell)) { dead_cells += [cell]; };
    });
    if (len(dead_cells) > 0) {
        all.foreach((_el, dj) => {
            if (keep[dj]) {
                let bd: [long] = all[dj];
                if (len(bd) == 0) { bd = unpack_body(allblob[dj]); };
                if (len(bd) > 0) {
                    let ni = ir_drop_inits(bd, dead_cells);
                    if (len(ni) != len(bd)) {
                        all[dj] = ni;
                        refs[dj] = ir_refs(ni);
                    };
                };
            };
        });
        // The CELLS stay: a dead cell is one `.bss` slot, which costs no file
        // bytes, and keeping it is the conservative half of this pass.
        shaken = prune_bodies(labels, refs, extra);
        keep = shaken.keep;
        body_refs = shaken.refs;
        pb = prelude_blocks(prelude_with(core_lines, thr, mth));
        ps = shake_prelude(pb, body_refs);
    };
    // A kept prelude block may call a Y helper (none does today): the
    // helper is kept too, and everything shaken again from there.
    let bmap = namemap_build(labels);
    let more = unkept_refs(ps.refs, bmap, keep);
    while (len(more) > 0) {
        extra += more;
        shaken = prune_bodies(labels, refs, extra);
        keep = shaken.keep;
        body_refs = shaken.refs;
        if ((!thr && uses_threads(body_refs)) || (!mth && uses_math(body_refs))) {
            if (uses_threads(body_refs)) { thr = true; };
            if (uses_math(body_refs)) { mth = true; };
            pb = prelude_blocks(prelude_with(core_lines, thr, mth));
        };
        ps = shake_prelude(pb, body_refs);
        more = unkept_refs(ps.refs, bmap, keep);
    };
    // --gc: when the collector cannot be needed, its three entry points become
    // stubs, so the registry, metadata arena, marker, sweeper and free lists go
    // unreachable and shake out. The allocator and heap_used() are untouched.
    if (!(gc_decide(gcmode, labels, refs, keep, all, allblob, ps, thr))) {
        core_lines = arch.arch_nogc_lines(core_lines);
        pb = prelude_blocks(prelude_with(core_lines, thr, mth));
        ps = shake_prelude(pb, body_refs);
    };
    // Everything the kept code can reach: the kept bodies' own references
    // plus the kept prelude's. Computed before the rodata, which uses it as
    // its reachability set.
    let const_refs: [str] = [];
    const_refs += ps.refs;
    body_refs.foreach((e) => {
        const_refs += [e];
    });
    // The rodata first, because it decides the labels the bodies use: one
    // block per distinct literal text, the losers recorded.
    tyset_reset();
    let allrod: [[str]] = [];
    let gls: [str] = [];
    for ju in 0..nu {
        let u = units[ju];
        allrod += u.rodata;
        gls += u.globals;
    };
    // Which cells the kept code reads, and the drop of a dead cell's
    // initializer range, ran above -- before the prelude was shaken, because
    // the range's own references (y_alloc, and through it the collector) are
    // what the prelude's roots are built from.
    allrod += prog.rodata;
    gls += prog.globals;
    let interned = rodata_intern([], allrod, const_refs);
    let dup_old = interned.dup_old;
    let rodpieces = interned.pieces;
    // loser label -> index into dup_new, so a body's refs can be relabelled
    // in one probe each.
    let dupmap = asm.labmap_new(len(dup_old) * 2 + 64);
    dup_old.foreach((e, di) => {
        dupmap = (asm.labmap_put(dupmap, e, 1, di)).map;
    });
    // Piece-list + single join: `asm = asm + piece` per iteration is
    // quadratic (each concat re-copies the whole 1.4MB+ accumulator —
    // the arena never frees), which OOMs on self-compilation.
    // The header, then the prelude: the `.section .text` the bodies go in and
    // the blocks they call. The bodies follow this part and precede the
    // rodata, which is where they were in the text.
    let parts: [LinkPart] = [];
    let head = arch.arch_header();
    if (dbg_lines) {
        head = file_dirs(files) + head;
    }
    parts += [part_text(head + arch.arch_text() + ps.text)];
    // The bodies, kept, as parts: their items, with the `.loc` markers moved
    // to the unit's place in the program's file table. Every body is items
    // now -- a unit read from a pack came with them (pack_body).
    all.foreach((e, ab) => {
        if (keep[ab]) {
            let kb: [long] = e;
            if (len(kb) == 0) { kb = unpack_body(allblob[ab]); };
            let kf = fno[ab];
            if (len(dup_old) > 0) {
                kb = ir_relabel(kb, dupmap, interned.dup_new);
            };
            let off = 0;
            if (kf >= 0) { off = kf; };
            parts += [part_ir(kb, alltxt[ab], off, dbg_lines)];
        }
    });
    // The rodata, then the .bss cells: text.
    parts += [part_text(arch.arch_rodata() + (shake_refs(arch.arch_consts(), const_refs)))];
    parts += [part_text(join(rodpieces, ""))];
    // .bss: the allocator's cells when the kept prelude still uses
    // them, then one cell per global.
    let heap_text = shake_refs(arch.arch_heap_cells(), const_refs);
    if (len(gls) > 0 || len(heap_text) > 0 || target_is_windows()) {
        let gpieces: [str] = [];
        gpieces += arch.arch_bss();
        // The Windows import cells come FIRST in .bss, so their offsets are
        // 0, 8, 16, ... in the import table's order and the PE writer computes
        // FirstThunk from the spec rather than asking the assembler's label
        // map. That matters: an offset that is merely WRONG (rather than
        // obviously absent) makes the loader write the resolved addresses over
        // whatever is at that address instead -- .pdata, or code.
        if (target_is_windows()) {
            let wl = arch.w_iat_bss_lines();
            for wj in 0..len(wl) { gpieces += wl[wj]; };
        };
        gpieces += heap_text;
        gls.foreach((e) => {
            gpieces += arch.arch_global_cell(e);
        });
        parts += [part_text(join(gpieces, ""))];
    }
    parts
};

// The parts as assembly text, what -S prints: the items rendered back to the
// text they replace (ir_render_all), the text parts as they are.
def link_text(parts: [LinkPart]) -> str {
    let pieces: [str] = [];
    parts.foreach((p) => {
        if (len(p.ir) > 0) {
            // the render has no newline of its own, so the line is closed here
            pieces += insn.ir_render_all(p.ir, p.txt, p.loc, p.fno);
            pieces += "\n";
        } else {
            // a text part already ends its lines (the arch text does; a body
            // the pack carried does not, and gets one here)
            let t = p.text;
            if (len(t) > 0 && t[len(t) - 1:] != "\n") {
                pieces += t + "\n";
            } else {
                pieces += t;
            };
        };
    });
    join(pieces, "")
};

// ── the std pack and package objects ──────────────────────────────────
// The std units, compiled ahead of time and carried by the ycc binary
// itself (`ycc --std-pack FILE` writes them; the build appends that file
// to the ycc that wrote it, see ycc.y self_pack): a program then links
// them as they are instead of compiling the runtime from source every
// time. A pack is netstrings: a version line, the number of units, then each
// unit as its name and its fields. A body's fields are its ITEMS (the codec
// below), not the assembly text they render to: the pack used to carry the
// text, 146,681 bytes of it, and a program that linked one lexed it back.
// An export's type travels as its tcode, decoded only for
// the units a program binds (std_unit_bound): nobody reads the types of
// rt's or str's. A package's object (`ycc build`, unit_obj) holds one
// unit's fields the same way.

def pack_version() -> str {
    "ycc-std-pack 6\n"
};

def pack_put(out: [str], s: str) -> [str] {
    out += tostring(len(s));
    out += ":";
    out += s;
    out
};

def pack_strs(out: [str], xs: [str]) -> [str] {
    out = pack_put(out, tostring(len(xs)));
    xs.foreach((e) => {
        out = pack_put(out, e);
    });
    out
};

// A list of lists (a unit's bodies' raw lines): each item a count and its
// own items, so a reader walks one body's lines without another's.
def pack_strss(out: [str], xss: [[str]]) -> [str] {
    out = pack_put(out, tostring(len(xss)));
    xss.foreach((e) => {
        out = pack_strs(out, e);
    });
    out
};

// ── a body's ITEMS, as a pack or an object carries them ──────────────────
// A body used to travel as the assembly text it renders to (unit_body_text):
// the pack was 146,681 bytes of it, and a program that linked one lexed it
// back. Since stage 2c the emitter's items are what the assembler wants, so
// the pack carries those. Two things cannot travel as they are:
//
//   a label id. Ids are minted per run (labels.y's counter), and a pack is
//   written by one build and read by the next, so an id means nothing to the
//   reader. A label field travels as its NAME and the reader mints the id for
//   it -- what the text path did with `call y_alloc`, and the only thing both
//   builds agree on.
//   a raw-line index. IR_TEXT items index a body's own lines (emit_one_fn
//   emits each function with a fresh `txt`), and those lines are the unit's
//   `btext`, which travels beside the items.
//
// The encoding: per item a byte for the form, then each operand's field words
// in the order the form table lists them -- a register's two, a memory
// operand's five, a label's, an immediate's one. So the reader needs no width
// of its own. A word is one byte when it is 0..125, three when it is a small
// negative or a 126..65535 positive (a 126 or 127 tag, then two bytes little
// endian), and nine for anything wider (a 255 tag, then eight). Registers,
// sizes, scales and the small displacements of a frame are one byte each.
// (125, not 126: 126 and 127 are the tags, and a 126 written as its own byte
// would read back as one -- the `.loc 1 126` of a std body, which desynced
// the whole body by two bytes when it did.)
def pack_word(out: [str], v: long) -> [str] {
    if (v >= 0 && v < 126) {
        out += chr(v);
    } else if (v < 0 && v > -65536) {
        let u = 65536 + v;
        out += chr(127);
        out += chr(u & 255);
        out += chr((u >> 8) & 255);
    } else if (v <= 65535) {
        out += chr(126);
        out += chr(v & 255);
        out += chr((v >> 8) & 255);
    } else {
        out += chr(255);
        let sh = 0;
        for i in 0..8 {
            out += chr((v >> sh) & 255);
            sh += 8;
        };
    };
    out
};

def pack_lbl(out: [str], id: long) -> [str] {
    if (id < 0) {
        out += chr(0);
    } else {
        let nm = lname(id);
        out += chr(1);
        out = pack_word(out, len(nm));
        out += nm;
    };
    out
};

// One body as the pack carries it: the items above, item by item.
def pack_body(u: Unit, b: long) -> str {
    let ir = u.bodies[b];
    let out: [str] = [];
    let at = 0;
    while (at < len(ir)) {
        let f = ir[at];
        out += chr(f & 255);
        if (f == insn.IR_LABEL) {
            out = pack_lbl(out, ir[at + 1]);
        } else if (f == insn.IR_LOC) {
            out = pack_word(out, ir[at + 1]);
            out = pack_word(out, ir[at + 2]);
        } else if (f == insn.IR_TEXT) {
            out = pack_word(out, ir[at + 1]);
        } else {
            let kinds = insn.ir_form(f).kinds;
            let ki = 0;
            let wp = at + 1;
            while (ki < len(kinds)) {
                let k = kinds[ki];
                if (k == insn.O_LBL) {
                    out = pack_lbl(out, ir[wp]);
                } else if (k == insn.O_DIFF) {
                    out = pack_lbl(out, ir[wp]);
                    out = pack_lbl(out, ir[wp + 1]);
                } else if (k == insn.O_MEM || k == insn.O_MEM0) {
                    out = pack_word(out, ir[wp]);
                    out = pack_word(out, ir[wp + 1]);
                    out = pack_word(out, ir[wp + 2]);
                    out = pack_word(out, ir[wp + 3]);
                    out = pack_lbl(out, ir[wp + 4]);
                } else {
                    out = pack_word(out, ir[wp]);
                    if (insn.ir_kind_words(k) > 1) { out = pack_word(out, ir[wp + 1]); };
                };
                wp = wp + insn.ir_kind_words(k);
                ki++;
            };
        };
        at += insn.IR_W;
    };
    join(out, "")
};

// One body read back (unit_read): the same items, with a label name minted to
// an id of this run and every field word the item does not use left 0, which
// is what the emitter wrote in it.
def unpack_body(blob: str) -> [long] {
    let b = bytes(blob);
    let n = len(b);
    let ir: [long] = [];
    let at = 0;
    while (at < n) {
        let f = b[at];
        at++;
        let w: [long] = [0, 0, 0, 0, 0, 0, 0];
        if (f == insn.IR_LABEL) {
            w[0] = unpack_lbl(b, at);
            at += lbl_w(b, at);
        } else if (f == insn.IR_LOC) {
            w[0] = unpack_word(b, at);
            at += word_w(b, at);
            w[1] = unpack_word(b, at);
            at += word_w(b, at);
        } else if (f == insn.IR_TEXT) {
            w[0] = unpack_word(b, at);
            at += word_w(b, at);
        } else {
            let kinds = insn.ir_form(f).kinds;
            let ki = 0;
            let wp = 0;
            while (ki < len(kinds)) {
                let k = kinds[ki];
                let nw = insn.ir_kind_words(k);
                if (k == insn.O_LBL) {
                    w[wp] = unpack_lbl(b, at);
                    at += lbl_w(b, at);
                } else if (k == insn.O_DIFF) {
                    w[wp] = unpack_lbl(b, at);
                    at += lbl_w(b, at);
                    w[wp + 1] = unpack_lbl(b, at);
                    at += lbl_w(b, at);
                } else if (k == insn.O_MEM || k == insn.O_MEM0) {
                    w[wp] = unpack_word(b, at);
                    at += word_w(b, at);
                    w[wp + 1] = unpack_word(b, at);
                    at += word_w(b, at);
                    w[wp + 2] = unpack_word(b, at);
                    at += word_w(b, at);
                    w[wp + 3] = unpack_word(b, at);
                    at += word_w(b, at);
                    w[wp + 4] = unpack_lbl(b, at);
                    at += lbl_w(b, at);
                } else {
                    w[wp] = unpack_word(b, at);
                    at += word_w(b, at);
                    if (nw > 1) {
                        w[wp + 1] = unpack_word(b, at);
                        at += word_w(b, at);
                    };
                };
                wp += nw;
                ki++;
            };
        };
        // word by word into `ir`: ir_push would hand back a whole new array
        // per item, which for a pack's 7,713 items is 1.9GB of copying
        ir += f;
        ir += w[0];
        ir += w[1];
        ir += w[2];
        ir += w[3];
        ir += w[4];
        ir += w[5];
        ir += w[6];
    };
    ir
};

// How many bytes the word at `at` takes: its tag byte says (see pack_word).
def word_w(b: [byte], at: long) -> long {
    let t = b[at];
    if (t < 126) { 1 } else if (t == 255) { 9 } else { 3 }
};

def unpack_word(b: [byte], at: long) -> long {
    let t = b[at];
    let v = 0;
    if (t < 126) {
        v = t;
    } else if (t == 255) {
        let sh = 0;
        for i in 0..8 {
            v += b[at + 1 + i] * (1 << sh);
            sh += 8;
        };
    } else {
        v = b[at + 1] + b[at + 2] * 256;
        if (t == 127) { v -= 65536; };
    };
    v
};

// A label field: none (tag 0) or a name -- an id of this run, interned as the
// text path interned `call y_alloc`'s operand.
def unpack_lbl(b: [byte], at: long) -> long {
    if (b[at] == 0) {
        -1
    } else {
        lbl_new(from_bytes(b[at + 1 + word_w(b, at + 1):at + 1 + word_w(b, at + 1) + (unpack_word(b, at + 1))]))
    }
};

// How many bytes the label field at `at` takes.
def lbl_w(b: [byte], at: long) -> long {
    if (b[at] == 0) { 1 } else { 1 + word_w(b, at + 1) + unpack_word(b, at + 1) }
};

// A type as text (for a pack or an object): a letter per kind, then its
// parts -- names as netstrings, lists as a count and their items. Unlike
// types.tstr it spells every type a unit may export (none, unknown and
// the like too) and reads back exactly (tdecode).
def tcode(t: Type) -> str {
    let out: [str] = [];
    out = tcode_go(out, t);
    join(out, "")
};

def tcode_go(out: [str], t: Type) -> [str] {
    let k: long = t.k;
    if (k == K.tlong) { out += "l"; out }
    else if (k == K.tbyte) { out += "b"; out }
    else if (k == K.tfloat) { out += "f"; out }
    else if (k == K.tbigint) { out += "g"; out }
    else if (k == K.tbool) { out += "o"; out }
    else if (k == K.tstr) { out += "s"; out }
    else if (k == K.tvoid) { out += "v"; out }
    else if (k == K.tunk) { out += "u"; out }
    else if (k == K.tnone) { out += "n"; out }
    else if (k == K.tname) { let name: TName = t; out += "N"; pack_put(out, name.name) }
    else if (k == K.tptr) { let ptr: TPtr = t; out += "*"; tcode_go(out, ptr.to) }
    else if (k == K.tarr) { let arr: TOf = t; out += "["; tcode_go(out, arr.of) }
    else if (k == K.topt) { let opt: TOf = t; out += "?"; tcode_go(out, opt.of) }
    else if (k == K.tarrfix) {
        let arr: TFix = t;
        out += "F";
        out = pack_put(out, tostring(arr.n));
        tcode_go(out, arr.of)
    }
    else if (k == K.tmap) {
        let map: TMap = t;
        out += "M";
        out = tcode_go(out, map.key);
        tcode_go(out, map.of)
    }
    else if (k == K.tfunc) {
        let func: TFunc = t;
        out += ">";
        out = tcode_list(out, func.args);
        tcode_go(out, func.ret)
    }
    else if (k == K.tunion) { let list: TList = t; out += "U"; tcode_list(out, list.ts) }
    else if (k == K.tparams) { let list: TList = t; out += "T"; tcode_list(out, list.ts) }
    else if (k == K.tpat) { let pat: TPat = t; out += "P"; pack_strs(out, pat.names) }
    else if (k == K.tref) {
        let ref: TRef = t;
        // a recursive alias: spelled out where it is met first, "q" and
        // its unit id inside (tcode_refs: the trefs being spelled out)
        let tmp: str = ref.tmp;
        if (name_in(tcode_refs, tmp)) {
            out += "q";
            pack_put(out, tmp)
        } else {
            out += "Q";
            out = pack_put(out, ref.name);
            out = pack_put(out, tmp);
            tcode_refs += tmp;
            out = tcode_go(out, ref.to);
            tcode_refs = tcode_refs[0:len(tcode_refs) - 1];
            out
        }
    }
    else if (k == K.trec) {
        let rec: TRec = t;
        out += "R";
        let fs: [Field] = rec.fields;
        out = pack_put(out, tostring(len(fs)));
        for i in 0..len(fs) {
            // NOTE: bound once (see types.y tstr_go).
            let f = fs[i];
            // an optional field is `name?` (tdecode_go)
            let fname: str = f.name;
            if (f.opt) { fname += "?"; };
            out = pack_put(out, fname);
            out = tcode_go(out, f.typ);
        };
        out
    }
    else {
        puts("ycc: internal error: no code for type kind " + ktag(k) + "\n");
        exit(1);
        out
    }
};

def tcode_list(out: [str], ts: [Type]) -> [str] {
    out = pack_put(out, tostring(len(ts)));
    ts.foreach((e) => {
        out = tcode_go(out, e);
    });
    out
};

def tdecode(s: str) -> Type {
    tdecode_go({ s: s, p: 0 })
};

def tdecode_go(cur: Cursor) -> Type {
    let s = cur.s;
    let p = cur.p;
    let c = s[p:p + 1];
    cur.p = p + 1;
    if (c == "l") { normtype({ k: K.tlong }) }
    else if (c == "b") { normtype({ k: K.tbyte }) }
    else if (c == "f") { normtype({ k: K.tfloat }) }
    else if (c == "g") { normtype({ k: K.tbigint }) }
    else if (c == "o") { normtype({ k: K.tbool }) }
    else if (c == "s") { normtype({ k: K.tstr }) }
    else if (c == "v") { normtype({ k: K.tvoid }) }
    else if (c == "u") { normtype({ k: K.tunk }) }
    else if (c == "n") { normtype({ k: K.tnone }) }
    else if (c == "N") { normtype({ k: K.tname, name: pack_get(cur) }) }
    else if (c == "*") { normtype({ k: K.tptr, to: tdecode_go(cur) }) }
    else if (c == "[") { normtype({ k: K.tarr, of: tdecode_go(cur) }) }
    else if (c == "?") { normtype({ k: K.topt, of: tdecode_go(cur) }) }
    else if (c == "F") {
        normtype({ k: K.tarrfix, of: tdecode_go(cur), n: pack_num(cur) })
    }
    else if (c == "M") {
        normtype({ k: K.tmap, key: tdecode_go(cur), of: tdecode_go(cur) })
    }
    else if (c == ">") {
        normtype({ k: K.tfunc, args: tdecode_list(cur), ret: tdecode_go(cur) })
    }
    else if (c == "U") { normtype({ k: K.tunion, ts: tdecode_list(cur) }) }
    else if (c == "T") { normtype({ k: K.tparams, ts: tdecode_list(cur) }) }
    else if (c == "P") { normtype({ k: K.tpat, names: pack_get_strs(cur) }) }
    else if (c == "Q") {
        // a tref (tcode): a fresh unit id, `to` read with the "q"s inside
        // it pointing back at it (tdec_encs/tdec_refs)
        let name = pack_get(cur);
        let enc = pack_get(cur);
        tdec_n++;
        let tref: TRef = { k: K.tref, name: name, tmp: "~" + tostring(tdec_n), to: type_node({ k: K.tnone }) };
        tdec_encs += enc;
        tdec_refs += tref;
        tref.to = tdecode_go(cur);
        tdec_encs = tdec_encs[0:len(tdec_encs) - 1];
        tdec_refs = tdec_refs[0:len(tdec_refs) - 1];
        normtype(tref)
    }
    else if (c == "q") {
        let enc = pack_get(cur);
        let i = len(tdec_encs) - 1;
        while (i > 0 && tdec_encs[i] != enc) { i = i - 1; };
        normtype(tdec_refs[i])
    }
    else {
        let fields: [Field] = [];
        for i in 0..pack_num(cur) {
            let fname = pack_get(cur);
            // `name?`: an optional field (tcode_go)
            let fopt = len(fname) > 0 && fname[len(fname) - 1] == '?';
            if (fopt) { fname = fname[0:len(fname) - 1]; };
            fields += { name: fname, opt: fopt, typ: tdecode_go(cur) };
        };
        normtype({ k: K.trec, fields: fields })
    }
};

def tdecode_list(cur: Cursor) -> [Type] {
    let out: [Type] = [];
    for i in 0..pack_num(cur) {
        out += tdecode_go(cur);
    };
    out
};

// A unit's exports and its parameter defaults: what a unit importing it
// is compiled against (unit_iface).
def pack_iface(out: [str], u: Unit) -> [str] {
    let xs = u.exports;
    out = pack_put(out, tostring(len(xs)));
    let j = 0;
    while (j < len(xs)) {
        let x = xs[j];
        out = pack_put(out, x.name);
        out = pack_put(out, x.label);
        out = pack_put(out, tcode(x.typ));
        j++;
    };
    let ds = u.dfl;
    out = pack_put(out, tostring(len(ds)));
    j = 0;
    while (j < len(ds)) {
        let d = ds[j];
        out = pack_put(out, d.name);
        out = pack_strs(out, d.vals);
        j++;
    };
    out
};

// One unit's fields.
def pack_unit_fields(u: Unit) -> str {
    let out: [str] = [];
    out = pack_strs(out, u.files);
    out = pack_iface(out, u);
    out = pack_put(out, u.init);
    out = pack_strs(out, pack_bodies(u));
    out = pack_strss(out, u.btext);
    out = pack_strs(out, u.labels);
    let rf = u.refs;
    out = pack_put(out, tostring(len(rf)));
    let j = 0;
    while (j < len(rf)) {
        out = pack_strs(out, rf[j]);
        j++;
    };
    let rd = u.rodata;
    out = pack_put(out, tostring(len(rd)));
    j = 0;
    while (j < len(rd)) {
        out = pack_strs(out, rd[j]);
        j++;
    };
    out = pack_strs(out, u.globals);
    join(out, "")
};

// The pack of `units`.
def std_pack(units: [Unit]) -> str {
    let out: [str] = [];
    out += pack_version();
    out = pack_put(out, tostring(len(units)));
    units.foreach((u) => {
        out = pack_put(out, u.name);
        out = pack_put(out, pack_unit_fields(u));
    });
    join(out, "")
};

// Reading a pack: `cur` is the text and the position in it. pack_len
// reads a netstring's length, leaving the cursor at its text.
def pack_len(cur: Cursor) -> long {
    let s = cur.s;
    let p = cur.p;
    let n = 0;
    let c = s[p];
    while (c != ':' && p < len(s)) {
        n = n * 10 + c - '0';
        p = p + 1;
        c = s[p];
    };
    cur.p = p + 1;
    n
};

def pack_get(cur: Cursor) -> str {
    let n = pack_len(cur);
    let p = cur.p;
    let s = cur.s;
    cur.p = p + n;
    s[p:p + n]
};

def pack_num(cur: Cursor) -> long {
    leading_long(pack_get(cur))
};

def pack_get_strs(cur: Cursor) -> [str] {
    let n = pack_num(cur);
    let out: [str] = [];
    for i in 0..n {
        out += pack_get(cur);
    };
    out
};

// The unit `name`, from its fields at the cursor (see pack_unit_fields);
// its exports' types decoded when `bound` (else tnone: never read).
def unit_read(cur: Cursor, name: str, bound: bool) -> Unit {
    let files = pack_get_strs(cur);
    let xs: [Sym] = [];
    let nx = pack_num(cur);
    let j = 0;
    while (j < nx) {
        let xn = pack_get(cur);
        let xl = pack_get(cur);
        let tc = pack_get(cur);
        let xt: Type = { k: K.tnone };
        if (bound) { xt = tdecode(tc); }
        xs += { name: xn, label: xl, typ: xt };
        j++;
    };
    let dfl: [DflCode] = [];
    let nf = pack_num(cur);
    j = 0;
    while (j < nf) {
        dfl += { name: pack_get(cur), vals: pack_get_strs(cur) };
        j++;
    };
    let init = pack_get(cur);
    // The bodies stay packed: a link decodes only the ones the shake keeps
    // (they are the only ones it assembles), which is what the text path did
    // by reading a body's text only when it kept it.
    let blob = pack_get_strs(cur);
    let nb = pack_num(cur);
    let btext: [[str]] = [];
    for bi in 0..nb {
        btext += [pack_get_strs(cur)];
    };
    let labels = pack_get_strs(cur);
    let refs: [[str]] = [];
    let nr = pack_num(cur);
    j = 0;
    while (j < nr) {
        refs += [pack_get_strs(cur)];
        j++;
    };
    let rodata: [[str]] = [];
    let nd = pack_num(cur);
    j = 0;
    while (j < nd) {
        rodata += [pack_get_strs(cur)];
        j++;
    };
    let globals = pack_get_strs(cur);
    { name: name, files: files, exports: xs, init: init, bodies: [],
        btext: btext, blob: blob, labels: labels, refs: refs, rodata: rodata,
        globals: globals, dfl: dfl }
};

// The units `names` from a pack, in that order; [] for a pack of another
// version, or one missing any of them.
def std_unpack(pack: str, names: [str]) -> [Unit] {
    let out: [Unit] = [];
    let ver = pack_version();
    if (pack[:len(ver)] == ver) {
        let cur = { s: pack, p: len(ver) };
        let n = pack_num(cur);
        let got: [Unit] = [];
        for i in 0..n {
            let nm = pack_get(cur);
            let ul = pack_len(cur);
            let at = cur.p;
            if (name_in(names, nm)) { got += unit_read(cur, nm, std_unit_bound(nm)); }
            cur.p = at + ul;
        };
        names.foreach((el) => {
            let want: str = el;
            got.foreach((u) => {
                if (u.name == want) { out += u; }
            });
        });
        if (len(out) != len(names)) { out = []; }
    }
    out
};

// A package's object (`ycc build` keeps one per package): its unit's
// fields, after a version line and the key it was compiled under (ycc.y
// build_key) -- an object of another key, or a cut-off one, is no hit.
def obj_version() -> str {
    "ycc-unit 5\n"
};

// An object carries a checksum over its own bytes, after them.
//
// The key covers what the unit was BUILT from -- its text, its flags, the
// interfaces it was compiled against -- and the length check covered
// truncation, but nothing covered the body: one flipped byte inside a string
// constant or a table entry rode straight through the cache, and the rebuild
// linked the corrupt unit (a m.yo with a single byte changed rebuilt into a
// program printing "hello From m"). asm.y's hash_str is the hash the compiler
// already runs over ~191k names per compile, so it is both strong enough for
// this and free.
def unit_obj(u: Unit, key: str) -> str {
    let out: [str] = [];
    out += obj_version();
    out = pack_put(out, key);
    let at_fields = len(join(out, ""));
    out = pack_put(out, u.name);
    out = pack_put(out, pack_unit_fields(u));
    let body = join(out, "");
    out = pack_put(out, tostring(asm.hash_str(body[at_fields:len(body)])));
    join(out, "")
};

def unit_unobj(text: str, key: str) -> { ok: bool, unit: Unit } {
    let ver = obj_version();
    let ok = false;
    let u = unit_empty("");
    if (text[:len(ver)] == ver) {
        let cur = { s: text, p: len(ver) };
        if (pack_get(cur) == key) {
            let body_at = cur.p;   // the name field starts here, and the
            let nm = pack_get(cur);  // checksum covers it and the fields
            let ul = pack_len(cur);
            let body_end = cur.p + ul;   // where unit_read starts, once the
            // checksum has been checked
            // the checksum field must be there (one byte at least), so an
            // object written before this one is rebuilt rather than read at a
            // byte past its end
            if (body_end < len(text)) {
                let sum = asm.hash_str(text[body_at:body_end]);
                cur.p = body_end;
                if (pack_num(cur) == sum && cur.p == len(text)) {
                    cur.p = body_end - ul;
                    u = unit_read(cur, nm, true);
                    ok = cur.p == body_end;
                }
            }
        }
    }
    { ok: ok, unit: u }
};

// What a unit importing `u` is compiled against: its exports (labels and
// types) and their parameter defaults. A change elsewhere in `u` leaves
// its importers' objects as they are.
def unit_iface(u: Unit) -> str {
    let out: [str] = [];
    out = pack_iface(out, u);
    join(out, "")
};

// ── entry points ───────────────────────────────────────────────────────

// What a unit is compiled against: the exports of the bound std units
// among `snames` (the std units it links itself, its resolution's
// `std`), and of the packages among `deps` it imports (`pkgs`), under
// qualified names (see pkg_ns) -- with their defs' parameter defaults.
def unit_externs(std: [Unit], snames: [str], deps: [Unit], pkgs: [str]) -> Externs {
    let xt = externs_none();
    let ext: [Sym] = [];
    let i = 0;
    while (i < len(std)) {
        let u = std[i];
        if (std_unit_bound(u.name) && name_in(snames, u.name)) { ext += u.exports; }
        i++;
    };
    let dfl: [Dfl] = [];
    i = 0;
    while (i < len(deps)) {
        let u = deps[i];
        if (name_in(pkgs, u.name)) {
            let xs = u.exports;
            let j = 0;
            while (j < len(xs)) {
                let x = xs[j];
                ext += { name: u.name + "." + x.name, label: x.label, typ: x.typ };
                j++;
            };
            let ds = u.dfl;
            j = 0;
            while (j < len(ds)) {
                let d = ds[j];
                let dv = d.vals;
                let vals: [Node] = [];
                dv.foreach((e) => {
                    vals += lit_decode(e);
                });
                dfl += { name: u.name + "." + d.name, vals: vals };
                j++;
            };
        }
        i++;
    };
    xt.ext = ext;
    xt.dfl = dfl;
    xt.pkgs = pkgs;
    xt
};

// A package's unit (`ycc build`): its text as native_resolve_pk resolved
// it (`nr`), compiled against the std units and the packages it imports
// (`deps` holds them, and maybe more). Always with its `.loc` markers
// (link_units keeps them for -g only), so one object serves every build.
def compile_package(ast: Block, nr: Resolved, name: str, base: long, wlevel: long, std: [Unit], deps: [Unit]) -> UnitRes {
    compile_unit(ast, nr.imports, nr.origin, true, wlevel, name, base, unit_externs(std, nr.std, deps, nr.pkgs), nr.ogen)
};

// The program's unit, compiled against the std units `std` (std_units)
// and the packages `deps` (`ycc build`: every package it links, each
// after those it imports) and linked with them. `nr` is the program's
// resolution: the std units it binds itself, the packages it imports.
def emit_program(ast: Block, nr: Resolved, debug: bool, wlevel: long, std: [Unit], deps: [Unit]) -> { ok: bool, asm: [LinkPart], errors: [Diag], warnings: [Diag], times: [Timing] } {
    let xt = unit_externs(std, nr.std, deps, nr.pkgs);
    let inits: [str] = [];
    let units: [Unit] = [];
    units += std;
    units += deps;
    let i = 0;
    while (i < len(units)) {
        let u = units[i];
        if (len(u.init) > 0) { inits += u.init; }
        i++;
    };
    xt.inits = inits;
    // a package reading argv() needs `_start` to materialize it
    let wargv = false;
    i = 0;
    while (i < len(deps)) {
        let rf = deps[i].refs;
        let b = 0;
        while (!wargv && b < len(rf)) {
            wargv = name_in(rf[b], "y_argv");
            b++;
        };
        i++;
    };
    xt.argv = wargv;
    let r = compile_unit(ast, nr.imports, nr.origin, debug, wlevel, "", 0, xt, nr.ogen);
    let times = r.times;
    if (r.ok) {
        dup_y_label(deps, r.unit);
        let pt = clock_us();
        let ph = heap_used();
        let parts = link_units(std, deps, r.unit, gc_mode);
        let pr = phase_end(times, "asm_parts", pt, ph);
        { ok: true, asm: parts, errors: r.errors, warnings: r.warnings,
            times: pr.times }
    } else {
        { ok: false, asm: [], errors: r.errors, warnings: r.warnings,
            times: times }
    }
};

// is_intrinsic_name is exported for the language server's completion list: it
// needs to KNOW whether a word is a builtin, and the list it keeps of them is
// the one this predicate tests. Inert like the rest of the names here -- the
// splicer deletes the export line, so nothing reaches codegen (LSP.md 9.1).
export { emit_program, compile_package, std_units, std_unit_names, std_pack, unit_obj, unit_unobj, unit_iface, native_resolve, native_resolve_x, native_resolve_pk, origin_at, strip_ns, strip_list, strip_decl, phase_end, link_text, is_intrinsic_name, intrinsic_names };

// ── maps: dynamic {K => V} ────────────────────────────────────────────
// A map value is a two-field record -- {keys: [K], vals: [V]} -- and
// every map operation lowers to synthetic AST over those arrays (the
// emitter knows the static key and value types for comparison and
// formatting), so maps need no runtime assembly of their own. Reads are
// always optional: a hit boxes the value (some(v)), a miss leaves none.

def n_str(v: str, line: long, col: long) -> Leaf {
    { k: K.str, v: v, line: line, col: col }
};

def n_bool(v: str, line: long, col: long) -> Leaf {
    { k: K.bool, v: v, line: line, col: col }
};

def n_dot(obj: Node, key: str, line: long, col: long) -> Dot {
    { k: K.dot, obj: obj, key: key, line: line, col: col, nline: line, ncol: col }
};

def n_idx(arr: Node, idx: Node, line: long, col: long) -> Index {
    { k: K.index, arr: arr, idx: idx, line: line, col: col }
};

def n_bin(op: str, l: Node, r: Node, line: long, col: long) -> Bin {
    { k: K.bin, op: op, l: l, r: r, line: line, col: col }
};

def n_not(e: Node, line: long, col: long) -> Un {
    { k: K.un, op: "!", e: e, line: line, col: col }
};

def n_if(c: Node, t: Node, e: Node, ln: long, cl: long) -> If {
    { k: K.kw_if, cond: c, then: t, els: e, has_else: true, line: ln, col: cl }
};

def n_while(c: Node, b: Node, ln: long, cl: long) -> While {
    { k: K.kw_while, cond: c, body: b, line: ln, col: cl }
};

def n_decl(name: str, v: Node, ln: long, cl: long) -> Decl {
    { k: K.decl, kind: "let", typ: type_node({ k: K.tnone }), name: name, v: v, line: ln, col: cl, nline: ln, ncol: cl }
};

// n_decl with a declared type, for a synthetic binding whose value needs the
// context to be created right (an EMPTY `{}` under a map type is the map, not
// an empty record -- gen_decl's rule; see gen_map_set).
def n_decl_typ(name: str, v: Node, typ: Type, ln: long, cl: long) -> Decl {
    { k: K.decl, kind: "let", typ: typ, name: name, v: v, line: ln, col: cl, nline: ln, ncol: cl }
};

def n_assign(name: str, v: Node, ln: long, cl: long) -> Assign {
    { k: K.assign, name: name, v: v, line: ln, col: cl }
};

def block_of(sts: [Node], ln: long, cl: long) -> Block {
    { k: K.block, stmts: sts, line: ln, col: cl }
};

// {"a": 1, "a": 2}: duplicate keys collapse at emit time -- the last
// entry wins the value, the first appearance keeps the position (the
// record spread rule). The result is the {keys, vals, boxes} record
// literal: maps lower to {keys: [K], vals: [V], boxes: [V?]}. A read m[k]
// is V?, and an option is a heap box, so boxes[i] caches the box of
// vals[i]: the first read after the entry was written makes it, every
// later read shares it, and a write clears it (a reader may still hold
// the old box -- it is never mutated). Reads allocate at most once per
// entry and write.
def gen_maplit(st: EmitSt, node: RecLit) -> EmitSt {
    let ln = node.line;
    let cl = node.col;
    let mkeys: [str] = node.keys;
    let mvals: [Node] = node.vals;
    let keys: [str] = [];
    let vals: [Node] = [];
    mkeys.foreach((el, mi) => {
        let mk: str = el;
        let mv = mvals[mi];
        let found = false;
        keys.foreach((e, fi) => {
            let kk: str = e;
            if (kk == mk) {
                vals[fi] = mv;
                found = true;
            }
        });
        if (!(found)) {
            keys += mk;
            vals += mv;
        };
    });
    let knodes: [Node] = [];
    let bnodes: [Node] = [];
    keys.foreach((e) => {
        let ks: str = e;
        knodes += n_str(ks, ln, cl);
        bnodes += n_id("none", ln, cl);
    });
    let keysarr: ArrLit = { k: K.array, elems: knodes, line: ln, col: cl };
    let valsarr: ArrLit = { k: K.array, elems: vals, line: ln, col: cl };
    let boxesarr: ArrLit = { k: K.array, elems: bnodes, line: ln, col: cl };
    let rkeys: [str] = [];
    rkeys += "keys";
    rkeys += "vals";
    rkeys += "boxes";
    let rvals: [Node] = [];
    rvals += keysarr;
    rvals += valsarr;
    rvals += boxesarr;
    let rec: RecLit = { k: K.rec, keys: rkeys, vals: rvals, line: ln, col: cl };
    gen(st, rec)
};

// m[k] read or test (is_map_read): m[k] on a map value.
def is_map_read(st: EmitSt, e: Node) -> bool {
    if (e.k == K.index) { let index: Index = e; unfold(infer(st, index.arr)).k == K.tmap } else { false }
};

def is_none_id(e: Node) -> bool {
    if (e.k == K.id) { let id: Leaf = e; id.v == "none" } else { false }
};

// The key scan every map access shares: t+"i" stops at the entry whose
// key equals t+"k", or at t+"n" (the entry count) on a miss. The caller
// binds t+"m" (the map), t+"k", t+"ks" = m.keys (hoisted: push grows in
// place, so the header never moves), t+"i" = 0, t+"n" = len(t+"ks") and
// the loop bound t+"j" = t+"n". A hit pulls the bound in to i rather than
// testing `i < n && keys[i] != k`, which materializes a bool every step.
def map_scan(t: str, ln: long, cl: long) -> While {
    let i: Node = n_id(t + "i", ln, cl);
    let key: Node = n_idx(n_id(t + "ks", ln, cl), i, ln, cl);
    let hit: [Node] = [];
    hit += n_assign(t + "j", i, ln, cl);
    hit += n_num("0", ln, cl);
    let step: [Node] = [];
    step += n_assign(t + "i", n_bin("+", i, n_num("1", ln, cl), ln, cl), ln, cl);
    step += n_num("0", ln, cl);
    let body: [Node] = [];
    body += n_if(n_bin("==", key, n_id(t + "k", ln, cl), ln, cl), block_of(hit, ln, cl), block_of(step, ln, cl), ln, cl);
    n_while(n_bin("<", i, n_id(t + "j", ln, cl), ln, cl), block_of(body, ln, cl), ln, cl)
};

// m[k] read, by mode. "opt" is the read itself (V?): a hit hands out
// boxes[i], boxing vals[i] first if no read since the last write has; a
// miss is none. The reads whose option never escapes skip the box: "val"
// is m[k]! (vals[i]; a miss traps like unwrap(none)), "has" is
// is_some(m[k]) and m[k] != none, "none" is m[k] == none.
def gen_map_get(st: EmitSt, node: Index, mode: str) -> EmitSt {
    let ln = node.line;
    let cl = node.col;
    let r = next_uid(st);
    st = r.st;
    let t = "y_t" + tostring(r.uid);
    let m: Node = n_id(t + "m", ln, cl);
    let i: Node = n_id(t + "i", ln, cl);
    let n: Node = n_id(t + "n", ln, cl);
    let sts: [Node] = [];
    sts += n_decl(t + "m", node.arr, ln, cl);
    sts += n_decl(t + "k", node.idx, ln, cl);
    sts += n_decl(t + "ks", n_dot(m, "keys", ln, cl), ln, cl);
    sts += n_decl(t + "i", n_num("0", ln, cl), ln, cl);
    sts += n_decl(t + "n", n_call1("len", n_id(t + "ks", ln, cl), ln, cl), ln, cl);
    sts += n_decl(t + "j", n, ln, cl);
    sts += map_scan(t, ln, cl);
    if (mode == "has") {
        sts += n_bin("<", i, n, ln, cl);
    } else if (mode == "none") {
        sts += n_bin("==", i, n, ln, cl);
    } else if (mode == "val") {
        let miss: [Node] = [];
        miss += n_call1("unwrap", n_id("none", ln, cl), ln, cl);
        let hit: [Node] = [];
        hit += n_num("0", ln, cl);
        sts += n_if(n_bin("==", i, n, ln, cl), block_of(miss, ln, cl), block_of(hit, ln, cl), ln, cl);
        sts += n_idx(n_dot(m, "vals", ln, cl), i, ln, cl);
    } else {
        let b: Node = n_id(t + "b", ln, cl);
        let fill: [Node] = [];
        fill += n_assign(t + "b", n_call1("some", n_idx(n_dot(m, "vals", ln, cl), i, ln, cl), ln, cl), ln, cl);
        fill += { k: K.idxassign, arr: n_dot(m, "boxes", ln, cl), idx: i, v: b, line: ln, col: cl };
        fill += n_num("0", ln, cl);
        let kept: [Node] = [];
        kept += n_num("0", ln, cl);
        let hit: [Node] = [];
        hit += n_decl(t + "b", n_idx(n_dot(m, "boxes", ln, cl), i, ln, cl), ln, cl);
        hit += n_if(n_call1("is_some", b, ln, cl), block_of(kept, ln, cl), block_of(fill, ln, cl), ln, cl);
        hit += b;
        let miss: [Node] = [];
        miss += n_id("none", ln, cl);
        sts += n_if(n_bin("<", i, n, ln, cl), block_of(hit, ln, cl), block_of(miss, ln, cl), ln, cl);
    };
    gen(st, block_of(sts, ln, cl))
};

// m[k] = v: scan for the key; a hit overwrites vals[i] and clears its
// cached box, a miss pushes onto all three arrays (in place -- every alias
// of the map sees the write; push, not `+=`, which would append the
// elements of an array value whose type unifies with [V], such as []).
// The value runs before the scan counts the entries, so a value that
// itself adds keys is seen.
def gen_map_set(st: EmitSt, node: IdxAssign) -> EmitSt {
    let ln = node.line;
    let cl = node.col;
    let r = next_uid(st);
    st = r.st;
    let t = "y_t" + tostring(r.uid);
    let m: Node = n_id(t + "m", ln, cl);
    let k: Node = n_id(t + "k", ln, cl);
    let i: Node = n_id(t + "i", ln, cl);
    let n: Node = n_id(t + "n", ln, cl);
    let v: Node = n_id(t + "v", ln, cl);
    // The value is declared WITH the map's value type, so an empty literal
    // `{}` is created as the map it is (gen_decl's empty-under-a-map rule).
    // With no type it was an empty RECORD, and storing that into a map of
    // maps left a value whose `!` dereferenced a record as a map -- measured
    // as a SIGSEGV in "map of map, empty store, read back".
    let mt = unfold(infer(st, node.arr));
    let vt: Type = type_node({ k: K.tunk });
    if (mt.k == K.tmap) { let mm: TMap = mt; vt = mm.of; };
    let sts: [Node] = [];
    sts += n_decl(t + "m", node.arr, ln, cl);
    sts += n_decl(t + "k", node.idx, ln, cl);
    sts += n_decl_typ(t + "v", node.v, vt, ln, cl);
    sts += n_decl(t + "ks", n_dot(m, "keys", ln, cl), ln, cl);
    sts += n_decl(t + "i", n_num("0", ln, cl), ln, cl);
    sts += n_decl(t + "n", n_call1("len", n_id(t + "ks", ln, cl), ln, cl), ln, cl);
    sts += n_decl(t + "j", n, ln, cl);
    sts += map_scan(t, ln, cl);
    let hit: [Node] = [];
    hit += { k: K.idxassign, arr: n_dot(m, "vals", ln, cl), idx: i, v: v, line: ln, col: cl };
    hit += { k: K.idxassign, arr: n_dot(m, "boxes", ln, cl), idx: i, v: n_id("none", ln, cl), line: ln, col: cl };
    hit += n_num("0", ln, cl);
    let grow: [Node] = [];
    grow += n_call2("push", n_dot(m, "keys", ln, cl), k, ln, cl);
    grow += n_call2("push", n_dot(m, "vals", ln, cl), v, ln, cl);
    grow += n_call2("push", n_dot(m, "boxes", ln, cl), n_id("none", ln, cl), ln, cl);
    grow += n_num("0", ln, cl);
    sts += n_if(n_bin("<", i, n, ln, cl), block_of(hit, ln, cl), block_of(grow, ln, cl), ln, cl);
    sts += v;
    gen(st, block_of(sts, ln, cl))
};

// One key's repr inside a map: string keys quote (Python-style), the
// other hashable keys stringify bare.
def map_key_repr(node: Node, kt: Type, ln: long, cl: long) -> Node {
    if (kt.k == K.tstr) {
        let out: Node = n_bin("+", n_bin("+", n_str("\"", ln, cl), node, ln, cl), n_str("\"", ln, cl), ln, cl);
        out
    } else {
        let out: Node = n_call1("tostring", node, ln, cl);
        out
    }
};

// {"k": v, ...}: a synthetic string-building loop -- the entry count is
// dynamic, but every format decision (keys, values) is static.
def gen_map_repr(st: EmitSt, arg: Node, t: Type) -> EmitSt {
    let ln = 0;
    let cl = 0;
    let r = next_uid(st);
    st = r.st;
    let g = "y_t" + tostring(r.uid);
    let m: Node = n_id(g + "m", ln, cl);
    let i: Node = n_id(g + "i", ln, cl);
    let n: Node = n_id(g + "n", ln, cl);
    let s: Node = n_id(g + "s", ln, cl);
    let sts: [Node] = [];
    sts += n_decl(g + "m", arg, ln, cl);
    sts += n_decl(g + "s", n_str("{", ln, cl), ln, cl);
    sts += n_decl(g + "i", n_num("0", ln, cl), ln, cl);
    sts += n_decl(g + "n", n_call1("len", n_dot(m, "keys", ln, cl), ln, cl), ln, cl);
    let sep: [Node] = [];
    sep += n_assign(g + "s", n_bin("+", s, n_str(", ", ln, cl), ln, cl), ln, cl);
    sep += n_num("0", ln, cl);
    let nosep: [Node] = [];
    nosep += n_num("0", ln, cl);
    let map: TMap = t;
    let kpart: Node = map_key_repr(n_idx(n_dot(m, "keys", ln, cl), i, ln, cl), map.key, ln, cl);
    let vpart: Node = n_call1("tostring", n_idx(n_dot(m, "vals", ln, cl), i, ln, cl), ln, cl);
    let put: Node = n_assign(g + "s", n_bin("+", n_bin("+", n_bin("+", s, kpart, ln, cl), n_str(": ", ln, cl), ln, cl), vpart, ln, cl), ln, cl);
    let step: Node = n_assign(g + "i", n_bin("+", i, n_num("1", ln, cl), ln, cl), ln, cl);
    let body: [Node] = [];
    body += n_if(n_bin(">", i, n_num("0", ln, cl), ln, cl), block_of(sep, ln, cl), block_of(nosep, ln, cl), ln, cl);
    body += put;
    body += step;
    sts += n_while(n_bin("<", i, n, ln, cl), block_of(body, ln, cl), ln, cl);
    sts += n_bin("+", s, n_str("}", ln, cl), ln, cl);
    gen(st, block_of(sts, ln, cl))
};
