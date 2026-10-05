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
import types from "./types.y";
import rename from "./rename.y";
import lexer from "./lexer.y";
import parser from "./parser.y";
import lint from "./lint.y";
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
// 512 buckets of indices into ty_sig_keys/ty_sig_lbls, made when first
// used (ty_sig_init); tyset_reset empties them.
let ty_sig_keys: [str] = [];
let ty_sig_lbls: [str] = [];
let ty_sig_bkts: [[long]] = [];
// union_shared's answers in this unit, by the union's node.
let ush_nodes: [Type] = [];
let ush_vals: [[str]] = [];

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
type Resolved = { src: str, imports: [str], origin: Origin, std: [str], pkgs: [str] };

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
    // NOTE: seen-threading wrapper (see native_resolve_seen): asm.y imports
    // enc64 as `enc` AND elf.y imports enc64 as `elfenc`; without dedup the
    // encoder splices twice and every enc64 def collides (find_dup).
    let r = native_resolve_seen(src, base_dir, depth, [], [], 0);
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
    { src: rsrc, imports: rimports, origin: origin, std: std, pkgs: res_used }
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
    ["exec"]
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
// a literal or a comment a `'` only ever opens `b'..'` or `c'..'`; a
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
    let k = 0;
    while (k <= len(names)) {
        seen += 0;
        k = k + 1;
    };
    words_scan(code, 0, len(code), names, seen);
    seen
};

// words_seen's pass over code[lo:n], marking seen in place. The fields of
// an f-string are code: lexer.y fstr_walk finds them as the lexer does,
// and each is scanned on its own.
def words_scan(code: str, lo: long, n: long, names: [str], seen: [long]) -> long {
    let i = lo;
    // the first byte of the last token of code (blanks and comments skip),
    // and a name just seen after a `.`, waiting for its `(`
    let prev = 0;
    let pend = 0 - 1;
    while (i < n) {
        let c = byte_at(code, i);
        if (blank_byte(c)) {
            i = i + 1;
        } else if (c == c'/' && i + 1 < n && byte_at(code, i + 1) == c'/') {
            // `//`: up to the newline
            i = i + 2;
            while (i < n && byte_at(code, i) != c'\n') {
                i = i + 1;
            };
        } else if (c == c'/' && i + 1 < n && byte_at(code, i + 1) == c'*') {
            // `/*`: past the first `*/`
            i = i + 2;
            let open = true;
            while (open && i < n) {
                if (byte_at(code, i) == c'*' && i + 1 < n && byte_at(code, i + 1) == c'/') {
                    open = false;
                    i = i + 1;
                }
                i = i + 1;
            };
        } else {
            if (pend >= 0) {
                if (c == c'(') { seen[pend] = 2; }
                pend = 0 - 1;
            }
            if (c == c'\"' || c == c'\'') {
                // a string literal: past its closing quote
                i = i + 1;
                let open = true;
                while (open && i < n) {
                    let d = byte_at(code, i);
                    if (d == c'\\') { i = i + 2; }
                    else if (d == c) { open = false; i = i + 1; }
                    else { i = i + 1; };
                };
            } else if (word_byte(c)) {
                let j = i + 1;
                while (j < n && word_byte(byte_at(code, j))) {
                    j = j + 1;
                };
                if (j == i + 1 && c == c'f' && j < n && byte_at(code, j) == c'\"') {
                    // f"...": the fields, and whether one has a spec
                    let w = lexer.fstr_walk(code, j);
                    let fs = w.fields;
                    let f = 0;
                    while (f < len(fs)) {
                        words_scan(code, fs[f], fs[f + 1], names, seen);
                        if (fs[f + 3] > fs[f + 2]) { seen[len(names)] = 2; }
                        f = f + 4;
                    };
                    i = w.end;
                } else {
                    let m = 0;
                    while (m < len(names)) {
                        let nm: str = names[m];
                        if (len(nm) == j - i && word_at(code, i, nm)) {
                            if (seen[m] == 0) { seen[m] = 1; }
                            if (prev == c'.') { pend = m; }
                        }
                        m = m + 1;
                    };
                    i = j;
                };
            } else {
                i = i + 1;
            };
            prev = c;
        };
    };
    0
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
        if (byte_at(code, i + k) != byte_at(nm, k)) { ok = false; }
        k = k + 1;
    };
    ok
};

// Whether any of seen[lo..hi) reaches `level` (see words_seen).
def seen_any(seen: [long], lo: long, hi: long, level: long) -> bool {
    let r = false;
    let i = lo;
    while (i < hi) {
        if (seen[i] >= level) { r = true; }
        i = i + 1;
    };
    r
};

// Collapse "/./" segments so the same file resolves to one key no matter
// how deep the import nesting is (base dirs accumulate "/." per level:
// "ycc/././enc64.y" vs "ycc/./././enc64.y"). Deterministic, so same-file
// inputs always yield the same key (sufficient for seen-dedup).
def norm_path(p: str) -> str {
    let parts = split(p, "/");
    let out: [str] = [];
    let i = 0;
    while (i < len(parts)) {
        let seg = parts[i];
        if (seg == ".") {
        } else {
            out += seg;
        };
        i = i + 1;
    };
    join(out, "/")
};

// Where full is in seen (-1: nowhere).
def seen_index(seen: [str], full: str) -> long {
    let at = -1;
    let i = 0;
    while (at < 0 && i < len(seen)) {
        if (seen[i] == full) { at = i; }
        i = i + 1;
    };
    at
};

def seen_has(seen: [str], full: str) -> bool {
    let i = 0;
    let found = false;
    while (i < len(seen)) {
        let e = seen[i];
        if (e == full) {
            found = true;
        };
        i = i + 1;
    };
    found
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
    let ri = 0;
    while (ri < len(res_roots)) {
        let rr: str = res_roots[ri];
        cands += rr + "/" + name + ".y";
        ri = ri + 1;
    };
    cands += "std/" + name + ".y";
    cands += "src/y/std/" + name + ".y";
    let d = self_dir();
    if (len(d) > 0) {
        cands += d + "/std/" + name + ".y";
        cands += d + "/src/y/std/" + name + ".y";
        cands += d + "/../src/y/std/" + name + ".y";
    }
    let found = "";
    let i = 0;
    while (i < len(cands)) {
        if (len(found) == 0) {
            let c: str = cands[i];
            if (fs.read_file(c) == none) {
            } else {
                found = norm_path(c);
            };
        }
        i = i + 1;
    };
    found
};

// The program text `src` of file `fid` (its index in the origin map's
// files: 0 for the program itself, k for seen[k - 1]) with its imports
// spliced in, as lines; ofile/oline map each one back (see the origin map
// above native_resolve), and smods[k] is the module seen[k] was imported
// as by name ("" by path).
def native_resolve_seen(src: str, base_dir: str, depth: long, seen: [str], smods: [str], fid: long) -> { lines: [str], imports: [str], seen: [str], smods: [str], ofile: [long], oline: [long] } {
    if (depth > 32) {
        // Fatal, like a missing module: carrying on compiled the program
        // without the rest of the chain and exited 0.
        puts("error: native import depth exceeded (cycle?)\n");
        exit(1);
        { lines: [], imports: [], seen: seen, smods: smods, ofile: [], oline: [] }
    } else {
        let lines = split(src, "\n");
        let out_lines: [str] = [];
        let ofile: [long] = [];
        let oline: [long] = [];
        let imports: [str] = [];
        let i = 0;
        let n = len(lines);
        while (i < n) {
            let line = lines[i];
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
                    ofile += fid;
                    oline += i + 1;
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
                    } else if (seen_has(seen, full)) {
                        // NOTE: already spliced (see native_resolve note):
                        // record the namespace name (strip_ns needs it,
                        // unless the file is a module with its own scope)
                        // but do NOT splice the text a second time.
                        if (smods[seen_index(seen, full)] == "") { imports += name; }
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
                        let mod_src2 = unwrap(mod_src);
                        let sub = native_resolve_seen(mod_src2, mod_dir, depth + 1, seen, smods, len(seen));
                        let subns = sub.imports;
                        let subseen = sub.seen;
                        seen = subseen;
                        smods = sub.smods;
                        // splice the module text inline (its own imports
                        // first), and its lines' origins with it
                        out_lines += sub.lines;
                        ofile += sub.ofile;
                        oline += sub.oline;
                        let m = 0;
                        while (m < len(subns)) {
                            imports += subns[m];
                            m = m + 1;
                        };
                        // a module imported by name keeps its namespace
                        // (rename.y), one imported by path is flattened
                        if (from_idx >= 0) { imports += name; }
                    };
                };
            } else if (is_embed_decl(trimmed)) {
                out_lines += embed_decl(trimmed, base_dir);
                ofile += fid;
                oline += i + 1;
            } else {
                // NOTE: no empty if-arms here — keep the `0;` filler.
                // Export lines are dropped (defs are spliced; uses are
                // rewritten by strip_namespaces).
                if (trimmed[:7] != "export ") {
                    out_lines += line;
                    ofile += fid;
                    oline += i + 1;
                } else {
                    // `export { a, b,` may run on over several lines: drop
                    // them through the one that closes the list.
                    if (index_of(line, "{") >= 0) {
                        while (index_of(lines[i], "}") < 0 && i + 1 < n) {
                            i = i + 1;
                        };
                    };
                };
            };
            i = i + 1;
        };
        { lines: out_lines, imports: imports, seen: seen, smods: smods, ofile: ofile, oline: oline }
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
    let i = 0;
    while (i < n) {
        let c: long = b[i];
        let esc = "";
        if (c == c'\\') {
            esc = "\\\\";
        } else if (c == c'\"') {
            esc = "\\\"";
        } else if (c == c'\n') {
            esc = "\\n";
        } else if (c == c'\r') {
            esc = "\\r";
        } else if (c < c' ' && c != c'\t') {
            esc = "\\x" + hex[c / 16:c / 16 + 1] + hex[c % 16:c % 16 + 1];
        }
        if (len(esc) > 0) {
            out += s[run:i];
            out += esc;
            run = i + 1;
        }
        i = i + 1;
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
    if (c >= c'a') { c <= c'z' }
    else if (c >= c'A') { c <= c'Z' || c == c'_' }
    else if (c >= c'0') { c <= c'9' }
    else { c == c'$' || c == c'.' }
};

// First non-blank offset in [i, hi); blank means space (the asm dialect
// indents with spaces) or end of range.
def skip_sp(b: [byte], i: long, hi: long) -> long {
    let p = i;
    let go = true;
    while (go) {
        if (p >= hi) {
            go = false;
        } else {
            if (b[p] == c' ') {
                p = p + 1;
            } else {
                go = false;
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
        if (b[p] == c'$') { p = p + 1; }
    }
    let go = true;
    while (go) {
        if (p >= hi) {
            go = false;
        } else {
            if (is_id_b(b[p])) {
                p = p + 1;
            } else {
                go = false;
            };
        };
    };
    p
};

// The identifier at offset `i`, or "".
def tok_at_b(text: str, b: [byte], i: long, hi: long) -> str {
    let s = i;
    if (s < hi) {
        if (b[s] == c'$') { s = s + 1; }
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
        let a = byte_at(w, n - 2);
        let b = byte_at(w, n - 1);
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
        let we = tok_end_b(b, p, hi);
        let op = skip_sp(b, we, hi);
        if (w == "call") {
            out = tok_push(out, tok_at_b(text, b, op, hi));
        } else if (w == "lea") {
            out = tok_push(out, tok_at_b(text, b, op, hi));
        } else if (w == "mov" || sse_mnemonic(w)) {
            let q = p;
            let go = true;
            while (go) {
                if (q >= hi) {
                    go = false;
                } else {
                    if (b[q] == c'$') {
                        go = false;
                    } else {
                        q = q + 1;
                    };
                };
            };
            if (q < hi) {
                let t = tok_at_b(text, b, q, hi);
                out = tok_push(out, t);
                let after = tok_end_b(b, q, hi);
                if (after < hi) {
                    if (b[after] == c'-') {
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
                    if (b[q2] == c',' || b[q2] == c'$') {
                        seen = true;
                    } else {
                        q2 = q2 + 1;
                    };
                };
                if (seen && b[q2] == c',') {
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
        if (b[i] == c'\n') {
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
    if (ls < len(b)) { b[ls] == c'.' } else { false }
};

// Every symbol a whole asm text references.
def text_refs(text: str, want_jumps: bool) -> [str] {
    let b = bytes(text);
    refs_range(text, b, 0, len(b), [], want_jumps)
};

// The label a line [lo, hi) defines, or "".
def label_at(text: str, b: [byte], lo: long, hi: long) -> str {
    let p = skip_sp(b, lo, hi);
    let e = tok_end_b(b, p, hi);
    let lab = "";
    if (e > p) {
        if (e < hi) {
            if (b[e] == c':') {
                let s = p;
                if (b[s] == c'$') { s = s + 1; }
                lab = text[s:e];
            }
        }
    }
    lab
};

// The label a body starts with (`label: ...`).
def body_label(body: str) -> str {
    let b = bytes(body);
    label_at(body, b, 0, len(b))
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
        b[p] == c'.'
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
        let i = lo;
        while (i < end) {
            if (b[i] == c'\n') {
                p = i + 1;
            }
            i = i + 1;
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
    let i = 0;
    while (i < len(names)) {
        let nm: str = names[i];
        if (len(nm) > 0) {
            // First insert wins, as a scan for the first match did.
            let r = asm.labmap_put(m, nm, i, 0);
            m = r.map;
        }
        i = i + 1;
    };
    m
};

// Index of `name` among the names it was built from, or -1.
def namemap_get(m: [AsmLabel], name: str) -> long {
    let r = asm.labmap_get(m, name);
    r.sec
};

// The defs a unit's bodies see (EmitSt.fns: the hoisted defs, then the
// externs, then the globals) with an index by name. No env holds them:
// env_find and the capture scans look a name up here, where every
// function's env used to be pre-loaded with all of them (~1.6k entries
// in the compiler) and scanned. Of entries sharing a name the last wins,
// as the backward env scan had it, so the index is filled from the end
// (labmap keeps the first).
type FnTab = { syms: [Sym], ix: [AsmLabel] };

def fntab_of(syms: [Sym]) -> FnTab {
    let m = asm.labmap_new(len(syms) * 2 + 16);
    let i = len(syms) - 1;
    while (i >= 0) {
        let e = syms[i];
        if (len(e.name) > 0) {
            let r = asm.labmap_put(m, e.name, i, 0);
            m = r.map;
        };
        i = i - 1;
    };
    { syms: syms, ix: m }
};

// Mark every names[i] some entry of `roots` points at, then close over kept
// blocks: their own references and (for code that runs into the next block)
// their successor. `falls[i]` says block i falls through to block i+1.
def shake_keep(names: [str], refs: [[str]], falls: [bool], keep: [bool], roots: [str]) -> [bool] {
    let n = len(names);
    let map = namemap_build(names);
    let r = 0;
    while (r < len(roots)) {
        let idx = namemap_get(map, roots[r]);
        if (idx >= 0) { keep[idx] = true; }
        r = r + 1;
    };
    let scanned: [bool] = [];
    let i = 0;
    while (i < n) {
        scanned += false;
        i = i + 1;
    };
    let more = true;
    while (more) {
        more = false;
        let b = 0;
        while (b < n) {
            if (keep[b]) {
                if (!(scanned[b])) {
                    scanned[b] = true;
                    more = true;
                    if (falls[b]) {
                        if (b + 1 < n) {
                            if (!(keep[b + 1])) { keep[b + 1] = true; }
                        }
                    }
                    let rs = refs[b];
                    let j = 0;
                    while (j < len(rs)) {
                        let idx = namemap_get(map, rs[j]);
                        if (idx >= 0) {
                            if (!(keep[idx])) { keep[idx] = true; }
                        }
                        j = j + 1;
                    };
                }
            }
            b = b + 1;
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
        if (b[i] == c'\n') {
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
        i = i + 1;
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
            k = k + 1;
        };
        let keep: [bool] = [];
        k = 0;
        while (k < nb) {
            if (len(names[k]) == 0) {
                keep += true;
            } else {
                keep += false;
            };
            k = k + 1;
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
            k = k + 1;
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
type PShake = { text: str, refs: [str] };

def prelude_blocks(lines: [str]) -> PBlocks {
    let starts: [long] = [];
    let names: [str] = [];
    let i = 0;
    while (i < len(lines)) {
        let l: str = lines[i];
        let lab = "";
        if (len(l) > 0 && byte_at(l, 0) != 32) {
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
        i = i + 1;
    };
    { lines: lines, starts: starts, names: names, ix: namemap_build(names) }
};

// Every reference the lines [lo, hi) make.
def lines_refs(lines: [str], lo: long, hi: long) -> [str] {
    let out: [str] = [];
    let i = lo;
    while (i < hi) {
        let l: str = lines[i];
        let lb = bytes(l);
        out = line_refs_b(l, lb, 0, len(lb), out, true);
        i = i + 1;
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
            let w = tok_at_b(l, lb, s, len(lb));
            if (w == "ret" || w == "jmp" || w == "syscall") { falls = false; };
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
            if (b0[p] == c'.') { falls = false; }
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
        k = k + 1;
    };
    let r = 0;
    while (r < len(roots)) {
        let idx = namemap_get(pb.ix, roots[r]);
        if (idx >= 0) { keep[idx] = true; };
        r = r + 1;
    };
    let more = true;
    while (more) {
        more = false;
        let b = 0;
        while (b < nb) {
            if (keep[b] && !(scanned[b])) {
                scanned[b] = true;
                more = true;
                let lo = starts[b];
                let hi = len(lines);
                if (b + 1 < nb) { hi = starts[b + 1]; };
                let rs = lines_refs(lines, lo, hi);
                brefs[b] = rs;
                if (b + 1 < nb && lines_fall(lines, lo, hi)) { keep[b + 1] = true; };
                let j = 0;
                while (j < len(rs)) {
                    let idx = namemap_get(pb.ix, rs[j]);
                    if (idx >= 0) { keep[idx] = true; };
                    j = j + 1;
                };
            };
            b = b + 1;
        };
    };
    let pieces: [str] = [];
    let out: [str] = [];
    k = 0;
    while (k < nb) {
        if (keep[k]) {
            let lo = starts[k];
            let hi = len(lines);
            if (k + 1 < nb) { hi = starts[k + 1]; };
            let i = lo;
            while (i < hi) {
                pieces += lines[i];
                pieces += "\n";
                i = i + 1;
            };
            out += brefs[k];
        };
        k = k + 1;
    };
    { text: join(pieces, ""), refs: out }
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
    let i = 0;
    while (i < len(refs)) {
        let idx = namemap_get(bmap, refs[i]);
        if (idx >= 0) {
            if (!(keep[idx])) { out += refs[i]; };
        };
        i = i + 1;
    };
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
        i = i + 1;
    };
    let roots: [str] = [];
    roots += extra_roots;
    let root = namemap_get(namemap_build(labels), "_start");
    if (root >= 0) {
        roots += "_start";
    }
    keep = shake_keep(labels, refs, falls, keep, roots);
    let outrefs: [str] = [];
    i = 0;
    while (i < nb) {
        if (keep[i]) {
            let rs = refs[i];
            let j = 0;
            while (j < len(rs)) {
                outrefs += rs[j];
                j = j + 1;
            };
        }
        i = i + 1;
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
            i = i + 1;
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
        i = i + 1;
    };
    found
};

// Identity helper giving rebuilt expression arms the shared AST union type.
def normnode(anode: Node) -> Node { anode };

// Type constructors flow through their separate type-node union.
def normtype(ty: Type) -> Type { ty };

// strip_namespaces: dot(NAME, key) with NAME an import namespace -> id(key).
// Full AST rebuild (only dot nodes change, but uniform rebuild is simplest).

def strip_list(nodes: [Node], imports: [str]) -> [Node] {
    let out: [Node] = [];
    let i = 0;
    while (i < len(nodes)) {
        out += strip_ns(nodes[i], imports);
        i = i + 1;
    };
    out
};

def strip_ns(node: Node, imports: [str]) -> Node {
    let k = node.k;
    if (k == K.dot) {
        let dot: Dot = node;
        let dobj = dot.obj;
        let obj = strip_ns(dobj, imports);
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
                normnode({ k: K.dot, obj: obj, key: okey, line: oline, col: ocol })
            }
        } else {
            normnode({ k: K.dot, obj: obj, key: okey, line: oline, col: ocol })
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
        normnode({ k: K.func, params: func.params, ptypes: func.ptypes, ret: func.ret, body: strip_ns(func.body, imports), line: func.line, col: func.col, defs: func.defs, label: func.label })
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
                normnode({ k: K.dotassign, obj: strip_ns(dao, imports), key: assign.key, v: strip_ns(assign.v, imports), line: assign.line, col: assign.col })
            }
        } else {
            normnode({ k: K.dotassign, obj: strip_ns(dao, imports), key: assign.key, v: strip_ns(assign.v, imports), line: assign.line, col: assign.col })
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
        normnode({ k: K.decl, kind: "def", name: node.name, typ: normtype({ k: K.tnone }), v: strip_ns(node.v, imports), line: node.line, col: node.col })
    } else {
        normnode({ k: K.decl, kind: node.kind, name: node.name, typ: node.typ, v: strip_ns(node.v, imports), line: node.line, col: node.col })
    }
};

// ── emit state ─────────────────────────────────────────────────────────
// st: an EmitSt. env: FLAT list of Slots — names are unique
// post-rename, so no scopes or shadowing. kind: "local"|"param" (frame
// slot at off), "func" (label), "global" (.bss cell at label),
// "closure" (slot holding a record), "box"/"capture" (shared cells).
type Slot = { name: str, kind: str, off: long, label: str, typ: Type };
type ArrTy = TOf | TFix;
type NodeE = Wrap | Un | Narrow | MatchEnd;
type NodeV = ArrRep | Assign | Decl;
type EmitMain = { params: [str], ptypes: [Type], ret: Type, body: Node, line: long, col: long };
type EmitFunc = Func | EmitMain;
type EmitSt = { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [Slot], slots: long, self_label: str, end_label: str, fns: FnTab, bodies: [str] };
// The state after making a label (next_loc, ty_desc), and the label.
type StLbl = { st: EmitSt, lbl: str };

def st_new() -> EmitSt {
    { out: [], rodata: [], uid: 1, fuid: 0, loc: 1, env: [],
      slots: 0, self_label: "", end_label: "", fns: fntab_of([]), bodies: [] }
};

def emit(st: EmitSt, line: str) -> EmitSt {
    st.out += line;
    { out: st.out, rodata: st.rodata, uid: st.uid,
      fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots,
      self_label: st.self_label, end_label: st.end_label, fns: st.fns,
      bodies: st.bodies }
};

def next_uid(st: EmitSt) -> { st: EmitSt, uid: long } {
    let u = st.uid;
    st = { out: st.out, rodata: st.rodata, uid: st.uid + 1,
      fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots,
      self_label: st.self_label, end_label: st.end_label, fns: st.fns,
      bodies: st.bodies };
    { st: st, uid: u }
};

def next_loc(st: EmitSt) -> StLbl {
    let n = st.loc;
    let lbl = arch.arch_loc_label(st.fuid, n);
    st = { out: st.out, rodata: st.rodata, uid: st.uid,
      fuid: st.fuid, loc: st.loc + 1, env: st.env, slots: st.slots,
      self_label: st.self_label, end_label: st.end_label, fns: st.fns,
      bodies: st.bodies };
    { st: st, lbl: lbl }
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
    let i = 0;
    while (i < n) {
        let o: long = b[i];
        let esc = "";
        if (o == c'\\') {
            esc = "\\\\";
        } else if (o == c'\"') {
            esc = "\\\"";
        } else if (o == c'\n') {
            esc = "\\n";
        } else if (o == c'\t') {
            esc = "\\t";
        } else if (o < c' ' || o > c'~') {
            esc = "\\" + tostring(o / 64) + tostring((o / 8) % 8) + tostring(o % 8);
        }
        if (len(esc) > 0) {
            out += s[run:i];
            out += esc;
            run = i + 1;
        }
        i = i + 1;
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
    env_id = env_id + 1;
    env += { name: "", kind: "env", off: env_id, label: "", typ: normtype({ k: K.tnone }) };
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
def env_index_all(env: [Slot], grow: bool) -> long {
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
            let r = asm.labmap_put(m, e.name, i, 0);
            m = r.map;
        };
        i = i - 1;
    };
    env_ix = m;
    env_ix_id = env[0].off;
    0
};

// Index the binding just appended to env, or rebuild. Four cases: a fresh env
// (the id differs), the env crossing the threshold -- which is a rebuild and
// not a put, or the entries below the threshold would never be indexed at all
// -- the env outgrowing half its table, and a re-bound name (the table keeps
// the first insert for a name, so the newest slot has to be put by a rebuild
// that walks backwards).
def env_index_add(env: [Slot]) -> long {
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
            let r = asm.labmap_put(env_ix, e.name, len(env) - 1, 0);
            env_ix = r.map;
            0
        };
    };
    0
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
        let e = env[i];
        if (e.name == name) { at = i; };
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
            let e = env[i];
            if (e.name == name) { at = i; };
            i = i - 1;
        };
    };
    if (at >= 0) {
        env[at]
    } else {
        let found: Slot = { name: "", kind: "none", off: 0, label: "", typ: normtype({ k: K.tnone }) };
        let fns = st.fns;
        let j = namemap_get(fns.ix, name);
        if (j >= 0) {
            let syms = fns.syms;
            let fe = syms[j];
            found = { name: fe.name, kind: fns_kind(fe.label), off: 0, label: fe.label, typ: fe.typ };
        };
        found
    }
};

def env_define(st: EmitSt, name: str, kind: str, off: long, label: str, typ: Type) -> EmitSt {
    let env = st.env;
    if (len(env) == 0) { env = env_open(env); };
    st.env += { name: name, kind: kind, off: off, label: label, typ: typ };
    env_index_add(env);
    let env = st.env;
    { out: st.out, rodata: st.rodata, uid: st.uid,
      fuid: st.fuid, loc: st.loc, env: env, slots: st.slots,
      self_label: st.self_label, end_label: st.end_label, fns: st.fns,
      bodies: st.bodies }
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
    if (k == K.num) {
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
        if (op == "+" || op == "-" || op == "*" || op == "/" || op == "%" || op == "::") {
            let bl = infer(st, bin.l);
            let br = infer(st, bin.r);
            if (op == "+" && (bl.k == K.tarr || bl.k == K.tarrfix)) {
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
        let iarr = index.arr;
        let bt = infer(st, iarr);
        if (bt.k == K.tarrfix || bt.k == K.tarr) {
            let arr: ArrTy = bt;
            arr.of
        } else if (bt.k == K.tmap) {
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
            let mi = 0;
            while (mi < len(melems)) {
                let mf = infer(st, melems[mi]);
                // mk is read twice: the `...` test, then the merge.
                let mk = mkeys[mi];
                if (mk == "...") {
                    if (mf.k == K.trec) {
                        let rec: TRec = mf;
                        let msfs: [Field] = rec.fields;
                        let msi = 0;
                        while (msi < len(msfs)) {
                            let msf = msfs[msi];
                            mfields = types.field_merge(mfields, msf.name, msf.typ);
                            msi = msi + 1;
                        };
                    }
                } else {
                    mfields = types.field_merge(mfields, mk, mf);
                };
                mi = mi + 1;
            };
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
        let dobj = dot.obj;
        let dt = infer(st, dobj);
        if (dt.k == K.trec) {
            let found = false;
            let ftyp: Type = normtype({ k: K.tunk });
            let rec: TRec = dt;
            let dfs: [Field] = rec.fields;
            let di = 0;
            while (di < len(dfs)) {
                let df = dfs[di];
                // NOTE: :str binding (see teq note in types.y): df flows
                // from bare values (tunk), so a direct `==` would compare
                // string POINTERS; annotated let forces content compare.
                let dfn: str = df.name;
                if (dfn == dot.key) {
                    found = true;
                    ftyp = df.typ;
                }
                di = di + 1;
            };
            if (found) { ftyp } else { normtype({ k: K.tunk }) }
        } else if (dt.k == K.tunion) {
            // types.y union_field: the type the field has in every member
            let uft = rec_field_type(dt, dot.key);
            if (uft.k == K.tnone) { normtype({ k: K.tunk }) } else { uft }
        } else if (dt.k == K.tmap) {
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
    } else if (k == K.ret) {
        let ret: Wrap = node;
        infer(st, ret.e)
    } else {
        normtype({ k: K.tunk })
    }
};

def infer_call(st: EmitSt, node: Call) -> Type {
    let callee: Node = node.callee;
    if (callee.k != K.id) {
        // Calling an expression (immediately-invoked literal, fs[0](x), ...),
        // or `s.m(...)` with s a str: a string method (types.str_method).
        if (callee.k == K.dot) {
            let dot: Dot = callee;
            if (infer(st, dot.obj).k == K.tstr) {
                let method = types.str_method(dot.key);
                method.ret
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
        } else if (name == "trim" || name == "chr" || name == "join" || name == "tostring" || name == "typeof" || name == "#fmt") {
            normtype({ k: K.tstr })
        } else if (name == "bytes") {
            normtype({ k: K.tarr, of: normtype({ k: K.tbyte }) })
        } else if (name == "from_bytes") {
            normtype({ k: K.tstr })
        } else if (name == "ptr_addr") {
            normtype({ k: K.tlong })
        } else if (name == "tonum" || name == "ord" || name == "byte_at" || name == "index_of" || name == "last_index_of") {
            normtype({ k: K.tlong })
        } else if (name == "clock_us" || name == "time_us" || name == "heap_used") {
            normtype({ k: K.tlong })
        } else if (name == "keys") {
            let kargs: [Node] = node.args;
            let kt = infer(st, kargs[0]);
            if (kt.k == K.tmap) {
                let map: TMap = kt;
                normtype({ k: K.tarr, of: map.key })
            } else { normtype({ k: K.tunk }) }
        } else if (name == "sleep") {
            normtype({ k: K.tvoid })
        } else if (name == "split" || name == "argv") {
            normtype({ k: K.tarr, of: normtype({ k: K.tstr }) })
        } else if (name == "range") {
            normtype({ k: K.tarr, of: normtype({ k: K.tlong }) })
        } else if (name == "push" || name == "prepend" || name == "push$all") {
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
        let i = 0;
        while (i < len(stmts)) {
            let s = stmts[i];
            if (s.k == K.decl) {
                let d: Decl = s;
                if (d.kind == "let" && env_find(st, d.name).kind == "none") {
                    if (len(st.env) == 0) { st.env = env_open(st.env); };
                    st.env += { name: d.name, kind: "temp", off: 0, label: "", typ: infer(st, d.v) };
                    env_index_add(st.env);
                };
            };
            i = i + 1;
        };
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
// Walk the renamed AST for calls the _start prologue must serve: argv()
// needs y_argv_init to materialize the [str] array from the raw stack.
// Everything else (y_alloc, y_print_*, ...) is position-independent.
// Returns { argv: bool }.

def uses_scan_block(stmts: [Node], out: { argv: bool }) -> { argv: bool } {
    let i = 0;
    while (i < len(stmts)) {
        out = uses_scan_node(stmts[i], out);
        i = i + 1;
    };
    out
};

def uses_scan_node(node: Node, out: { argv: bool }) -> { argv: bool } {
    let k = node.k;
    if (k == K.call) {
        // scan callee + args (argv() could nest inside an argument).
        // ncallee is read three times: the argv test, the id test, the walk.
        let call: Call = node;
        let ncallee = call.callee;
        let nargs: [Node] = call.args;
        let found = out;
        if (ncallee.k == K.id) {
            let id: Leaf = ncallee;
            if (id.v == "argv") {
                found = { argv: true };
            }
        }
        let o2 = uses_scan_node(ncallee, found);
        uses_scan_block(nargs, o2)
    } else if (k == K.un) {
        let child: NodeE = node;
        uses_scan_node(child.e, out)
    } else if (k == K.bin) {
        let bin: Bin = node;
        uses_scan_node(bin.r, uses_scan_node(bin.l, out))
    } else if (k == K.addr || k == K.deref) {
        let child: NodeE = node;
        uses_scan_node(child.e, out)
    } else if (k == K.kw_if) {
        let branch: If = node;
        uses_scan_node(branch.els, uses_scan_node(branch.then, uses_scan_node(branch.cond, out)))
    } else if (k == K.kw_while) {
        let loop: While = node;
        uses_scan_node(loop.body, uses_scan_node(loop.cond, out))
    } else if (k == K.block) {
        let block: Block = node;
        uses_scan_block(block.stmts, out)
    } else if (k == K.decl) {
        let decl: Decl = node;
        uses_scan_node(decl.v, out)
    } else if (k == K.func) {
        let func: Func = node;
        uses_scan_node(func.body, out)
    } else if (k == K.assign) {
        let assign: Assign = node;
        uses_scan_node(assign.v, out)
    } else if (k == K.incdec) {
        let incdec: IncDec = node;
        uses_scan_node(incdec.tgt, out)
    } else if (k == K.opassign) {
        let assign: OpAssign = node;
        uses_scan_node(assign.v, uses_scan_node(assign.tgt, out))
    } else if (k == K.store) {
        let store: Store = node;
        uses_scan_node(store.v, uses_scan_node(store.p, out))
    } else if (k == K.ret) {
        let child: NodeE = node;
        uses_scan_node(child.e, out)
    } else if (k == K.array) {
        let array: ArrLit = node;
        uses_scan_block(array.elems, out)
    } else if (k == K.arrrep) {
        let rep: ArrRep = node;
        uses_scan_node(rep.v, out)
    } else if (k == K.rec) {
        let rec: RecLit = node;
        uses_scan_block(rec.vals, out)
    } else if (k == K.map) {
        let map: RecLit = node;
        uses_scan_block(map.vals, out)
    } else if (k == K.index) {
        let index: Index = node;
        uses_scan_node(index.idx, uses_scan_node(index.arr, out))
    } else if (k == K.slice) {
        let slice: Slice = node;
        uses_scan_node(slice.hi, uses_scan_node(slice.lo, uses_scan_node(slice.arr, out)))
    } else if (k == K.idxassign) {
        let assign: IdxAssign = node;
        uses_scan_node(assign.v, uses_scan_node(assign.idx, uses_scan_node(assign.arr, out)))
    } else if (k == K.dotassign) {
        let assign: DotAssign = node;
        uses_scan_node(assign.v, uses_scan_node(assign.obj, out))
    } else if (k == K.kw_foreach) {
        let loop: Foreach = node;
        uses_scan_node(loop.body, uses_scan_node(loop.iter, out))
    } else if (k == K.forrange) {
        let loop: ForRange = node;
        uses_scan_node(loop.body, uses_scan_node(loop.hi, uses_scan_node(loop.lo, out)))
    } else if (k == K.kw_for) {
        let loop: For = node;
        uses_scan_node(loop.body, uses_scan_node(loop.step, uses_scan_node(loop.cond, uses_scan_node(loop.init, out))))
    } else if (k == K.sliceassign) {
        let assign: SliceAssign = node;
        uses_scan_node(assign.v, uses_scan_node(assign.hi, uses_scan_node(assign.lo, uses_scan_node(assign.arr, out))))
    } else if (k == K.rectest || k == K.narrow || k == K.matchend) {
        let child: NodeE = node;
        uses_scan_node(child.e, out)
    } else {
        out
    }
};

// ── def collection (incl. hoisting) ────────────────────────────────────
// Walk blocks/ifs/whiles/func-bodies; every named def and every let-bound
// anonymous def becomes a top-level function (they capture nothing — the
// checker proved it). Returns [FnDef].
type FnDef = { name: str, func: Func };

def collect_from_block(stmts: [Node], out: [FnDef]) -> [FnDef] {
    let i = 0;
    while (i < len(stmts)) {
        out = collect_from_node(stmts[i], out);
        i = i + 1;
    };
    out
};

def collect_from_node(node: Node, out: [FnDef]) -> [FnDef] {
    let k = node.k;
    if (k == K.decl) {
        let decl: Decl = node;
        if (decl.kind == "def") {
            let func: Func = decl.v;
            out += { name: decl.name, func: func };
            out = collect_from_node(decl.v, out);
        } else {
            if (decl.v.k == K.func) {
                let func: Func = decl.v;
                out += { name: decl.name, func: func };
            }
            out = collect_from_node(decl.v, out);
        }
    } else if (k == K.func) {
        let func: Func = node;
        let body: Block = func.body;
        out = collect_from_block(body.stmts, out);
    } else if (k == K.kw_if) {
        let branch: If = node;
        out = collect_from_node(branch.then, out);
        if (branch.has_else) {
            out = collect_from_node(branch.els, out);
        }
    } else if (k == K.kw_while) {
        let loop: While = node;
        out = collect_from_node(loop.body, out);
    } else if (k == K.kw_for) {
        let loop: For = node;
        out = collect_from_node(loop.init, out);
        out = collect_from_node(loop.body, out);
        out = collect_from_node(loop.step, out);
    } else if (k == K.kw_foreach) {
        let loop: Foreach = node;
        out = collect_from_node(loop.body, out);
    } else if (k == K.forrange) {
        let loop: ForRange = node;
        out = collect_from_node(loop.body, out);
    } else if (k == K.block) {
        let block: Block = node;
        out = collect_from_block(block.stmts, out);
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
        i = i + 1;
    };
    found
};

// The float primitives (src/y/arch/math.s), by the same rule as the thread
// runtime: a `native def` names one as its body, so the call is a reference
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
            // the encoder's own form probes: y_sse_forms, y_sse_flags
            || (n == 11 && (r == "y_sse_forms" || r == "y_sse_flags"));
        i = i + 1;
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
        i = i + 1;
    };
    found
};

// Builtins are resolved by name at the call site, never captured.
def is_intrinsic_name(n: str) -> bool {
    name_in(["print", "syscall", "len", "push", "some", "is_some", "unwrap",
             "opt$test", "opt$val",
             "trim", "ord", "byte_at", "chr", "tonum", "tostring", "index_of",
             "prepend",
             "last_index_of", "join", "split", "puts", "eputs", "clock_us",
             "time_us", "sleep", "heap_used", "keys", "spawn", "fork", "wait_pid",
             "mutex", "sem", "lock", "try_lock", "post", "wait", "exit", "argv", "range", "typeof", "bytes",
             "from_bytes", "ptr_addr", "self", "none", "#fmt"], n)
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
    let i = 0;
    while (i < len(nodes)) {
        out = fv_walk(nodes[i], out, collect);
        i = i + 1;
    };
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
    let i = 0;
    while (i < len(nodes)) {
        out = fv_binds(nodes[i], out);
        i = i + 1;
    };
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
    let i = 0;
    while (i < len(reads)) {
        let n: str = reads[i];
        if (name_in(bound, n)) { }
        else if (n == extra || namemap_get(ex, n) >= 0) { }
        else if (is_intrinsic_name(n)) { }
        else if (name_in(caps, n)) { }
        else {
            caps += n;
        };
        i = i + 1;
    };
    caps
};

def fv_bind_params(ps: [str], out: [str]) -> [str] {
    let i = 0;
    while (i < len(ps)) {
        let p: str = ps[i];
        out += p;
        i = i + 1;
    };
    out
};

def fn_names_of(fns: [Sym]) -> [str] {
    let out: [str] = [];
    let i = 0;
    while (i < len(fns)) {
        let e = fns[i];
        out += e.name;
        i = i + 1;
    };
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
    nest = nest + 1;
    if (nest > MAX_NEST) { too_deep("an expression", node.line, node.col); };
    let r = gen_go(st, node);
    nest = nest - 1;
    r
};

def gen_go(st: EmitSt, node: Node) -> EmitSt {
    let k = node.k;
    if (k == K.num) {
        let lit: Leaf = node;
        gen_lit(st, lit)
    } else if (k == K.bool) {
        let lit: Leaf = node;
        if (lit.v == "true") {
            emit(st, "    mov $1, %rax")
        } else {
            emit(st, "    xor %eax, %eax")
        }
    } else if (k == K.str) {
        let lit: Leaf = node;
        gen_str_const(st, lit.v)
    } else if (k == K.bstr) {
        let lit: Leaf = node;
        gen_bstr(st, lit)
    } else if (k == K.void) {
        emit(st, "    xor %eax, %eax")
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
        if (dw == 1) { emit(st, "    movzbq (%rax), %rax") } else { emit(st, "    mov (%rax), %rax") }
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
        gen_decl(st, decl)
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
        if (kbt.k == K.tmap) { gen_map_get(st, index, "opt") }
        else if (kbt.k == K.tstr) { gen_byte_at(st, n_call2("byte_at", index.arr, index.idx, index.line, index.col)) }
        else { gen_index(st, index) }
    } else if (k == K.slice) {
        let slice: Slice = node;
        let sbt = infer(st, slice.arr);
        if (sbt.k == K.tstr) { gen_str_slice(st, slice) } else { gen_slice(st, slice) }
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
        gen_convert(st, src, types.narrow_type(src, narrow.typ), false)
    } else if (k == K.matchend) {
        // unreachable when the checker accepted the match
        st = emit(st, "    call y_match_fail");
        emit(st, "    xor %eax, %eax")
    } else if (k == K.sliceassign) {
        let assign: SliceAssign = node;
        gen_sliceassign(st, assign)
    } else if (k == K.idxassign) {
        let assign: IdxAssign = node;
        let kbt = infer(st, assign.arr);
        if (kbt.k == K.tmap) { gen_map_set(st, assign) } else { gen_idxassign(st, assign) }
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
    } else if (k == K.ret) {
        let ret: Wrap = node;
        st = gen_as(st, ret.e, cur_fn_ret(st));
        emit(st, "    jmp " + st.end_label)
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
    let bi = 0;
    let bn = len(bv);
    while (bi < bn) {
        let bnum: Leaf = { k: K.num, v: tostring(ord(bv[bi:bi + 1])), line: node.line, col: node.col };
        elems += bnum;
        bi = bi + 1;
    };
    let barr: ArrLit = { k: K.array, elems: elems, line: node.line, col: node.col };
    gen_array_esz(st, barr, 1, { k: K.tnone })
};

def gen_str_const(st: EmitSt, s: str) -> EmitSt {
    let r = next_uid(st);
    st = r.st;
    let lbl = arch.arch_str_label(r.uid);
    // NOTE: push-chain over a let-bound [] (not a literal). The checker
    // rejects heterogeneous array literals ([str, long, str]); these three
    // parts are all str, so a literal would check too — the push-chain is
    // just the shape the other node-list builders use.
    let rod0: [str] = [];
    rod0 += lbl;
    rod0 += tostring(len(s));
    rod0 += esc_asm(s);
    st.rodata += [rod0];
    let rod = st.rodata;
    st = { out: st.out, rodata: rod, uid: st.uid,
      fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots,
      self_label: st.self_label, end_label: st.end_label, fns: st.fns,
      bodies: st.bodies };
    emit(st, "    lea " + lbl + "(%rip), %rax")
};

def gen_id(st: EmitSt, node: Leaf) -> EmitSt {
    if (node.v == "self") {
        // Bare `self` as a value: only legal in discarded positions
        // (the checker rejects every typed use). Emit zero (none).
        emit(st, "    xor %eax, %eax  # bare self (discarded)")
    } else if (node.v == "none") {
        // The empty option (checker gives it typeof from context).
        emit(st, "    xor %eax, %eax")
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
                emit(st, "    mov " + tostring(soff) + "(%rbp), %rax")
            } else {
                gen_make_closure(st, e.label, [])
            }
        } else if (e.kind == "global") {
            // An appendable global gives up its buffer on every read
            // (see gen_sappend).
            if (e.typ.k == K.tstr) {
                let oe = env_find(st, node.v + "#o");
                if (oe.kind == "none") { } else {
                    st = emit(st, "    xor %eax, %eax");
                    st = emit(st, "    mov %rax, " + oe.label + "(%rip)");
                };
            }
            emit(st, "    mov " + e.label + "(%rip), %rax")
        } else if (e.kind == "own") {
            // an appendable string: a read may let its buffer escape, so
            // the companion is cleared (see gen_sappend)
            st = emit(st, "    mov " + tostring(e.off) + "(%rbp), %rax");
            emit(st, "    mov $0, " + tostring(e.off - 8) + "(%rbp)")
        } else if (e.kind == "capture") {
            // Captured by the enclosing closure: load the closure record
            // (at the frame offset recorded in `off`), read slot idx+1 —
            // the shared cell pointer — and deref it (see box_capture).
            // NOTE: the index rides in `label` — env entries have no spare
            // numeric field and adding one would touch every signature.
            let idx = tonum(e.label);
            st = emit(st, "    mov " + tostring(e.off) + "(%rbp), %rcx");
            st = emit(st, "    mov " + tostring(8 * (idx + 1)) + "(%rcx), %rax");
            emit(st, "    mov (%rax), %rax")
        } else if (e.kind == "box") {
            // A captured variable's shared cell; the slot holds its pointer.
            st = emit(st, "    mov " + tostring(e.off) + "(%rbp), %rax");
            emit(st, "    mov (%rax), %rax")
        } else {
            emit(st, "    mov " + tostring(e.off) + "(%rbp), %rax")
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
        let pidx = tonum(e.label);
        st = emit(st, "    mov " + tostring(e.off) + "(%rbp), %rcx");
        emit(st, "    mov " + tostring(8 * (pidx + 1)) + "(%rcx), %rax")
    } else {
        emit(st, "    mov " + tostring(e.off) + "(%rbp), %rax")
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
        st = emit(st, "    push %rax");
        st = emit(st, "    mov $8, %rdi");
        st = emit(st, "    call y_alloc");
        st = emit(st, "    pop %rdx");
        st = emit(st, "    mov %rdx, (%rax)");
        let boff = (st.slots + 1) * -8;
        st = emit(st, "    mov %rax, " + tostring(boff) + "(%rbp)");
        let st2 = { out: st.out, rodata: st.rodata, uid: st.uid,
          fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots + 1,
          self_label: st.self_label, end_label: st.end_label, fns: st.fns,
          bodies: st.bodies };
        env_define(st2, name, "box", boff, "", e.typ)
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
    let i = 0;
    while (i < len(reads)) {
        let n: str = reads[i];
        if (name_in(out, n)) { } else {
            out += n;
        };
        i = i + 1;
    };
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
        } else if (e.kind == "boxmark" && e.label == name) {
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
    let i = 0;
    while (i < len(nodes)) {
        out = app_walk(nodes[i], out, deep);
        i = i + 1;
    };
    out
};

// The names in a subtree (`deep`: a whole program) an append statement
// may extend in place: `+=` targets whose address is never taken, minus
// `skip` (the names closures capture). Only the str-typed ones are used.
def app_names(node: Node, deep: bool, skip: [str]) -> [str] {
    let seen = app_walk(node, [], deep);
    let out: [str] = [];
    let i = 0;
    while (i < len(seen)) {
        let n: str = seen[i];
        if (n[:1] == "&" || name_in(out, n) || name_in(skip, n) || name_in(seen, "&" + n)) { } else {
            out += n;
        };
        i = i + 1;
    };
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
        } else if (e.kind == "appmark" && e.label == name) {
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
    st = emit(st, "    mov %rax, " + tostring(off) + "(%rbp)");
    st = emit(st, "    mov $0, " + tostring(off - 8) + "(%rbp)");
    let st2 = { out: st.out, rodata: st.rodata, uid: st.uid,
      fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots + 2,
      self_label: st.self_label, end_label: st.end_label, fns: st.fns,
      bodies: st.bodies };
    env_define(st2, name, "own", off, "", t)
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
        let e = env_find(st, id.v);
        if (e.kind == "local") { st } else { gen(st, node) }
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
                gen_sappend(st, assign.v, tostring(e.off) + "(%rbp)", tostring(e.off - 8) + "(%rbp)")
            } else if (e.kind == "global" && e.typ.k == K.tstr) {
                let oe = env_find(st, id.v + "#o");
                if (oe.kind == "none") {
                    gen_opassign(st, assign, true)
                } else {
                    gen_sappend(st, assign.v, e.label + "(%rip)", oe.label + "(%rip)")
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
def gen_sappend(st: EmitSt, v: Node, var: str, cell: str) -> EmitSt {
    st = emit(st, "    mov " + var + ", %rax");
    st = emit(st, "    push %rax");
    st = emit(st, "    mov " + cell + ", %rdx");
    st = emit(st, "    cmp %rdx, %rax");
    st = emit(st, "    sete %al");
    st = emit(st, "    movzbq %al, %rax");
    st = emit(st, "    mov %rax, " + cell);
    st = gen(st, v);
    st = emit(st, "    push %rax");
    st = emit(st, "    mov " + cell + ", %rax");
    st = emit(st, "    push %rax");
    st = emit(st, "    call y_str_app");
    st = emit(st, "    add $24, %rsp");
    st = emit(st, "    mov %rax, " + var);
    emit(st, "    mov %rax, " + cell)
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
    let i = 0;
    while (i < len(gl)) {
        let ge = gl[i];
        if (ge.typ.k == K.tstr) { anystr = true; }
        i = i + 1;
    };
    if (anystr) {
        let names = app_names({ k: K.block, stmts: stmts, line: 1, col: 1 }, true, []);
        let out: [Sym] = [];
        out += gl;
        let j = 0;
        while (j < len(gl)) {
            let g2 = gl[j];
            if (g2.typ.k == K.tstr && name_in(names, g2.name)) {
                out += { name: g2.name + "#o", label: "ygo_" + g2.label[3:], typ: normtype({ k: K.tnone }) };
            }
            j = j + 1;
        };
        out
    } else {
        gl
    }
};

def gen_make_closure(st: EmitSt, label: str, caps: [str]) -> EmitSt {
    let n = len(caps);
    st = emit(st, "    mov $" + tostring(8 + 8 * n) + ", %rdi");
    st = emit(st, "    call y_alloc");
    st = emit(st, "    push %rax");
    st = emit(st, "    lea " + label + "(%rip), %rcx");
    st = emit(st, "    mov %rcx, (%rax)");
    let i = 0;
    while (i < n) {
        let cn: str = caps[i];
        // Captured as a shared cell pointer (see box_capture).
        st = gen_cap_ptr(st, cn);
        st = emit(st, "    pop %rcx");
        st = emit(st, "    push %rcx");
        st = emit(st, "    mov %rax, " + tostring(8 * (i + 1)) + "(%rcx)");
        i = i + 1;
    };
    emit(st, "    pop %rax")
};

// range(n) -> [0, 1, ..., n-1] as a heap array (the loop-friendly builtin;
// y_range in std/rt.y).
def gen_range(st: EmitSt, node: Call) -> EmitSt {
    st = gen_push_args(st, node.args);
    st = emit(st, "    call y_range");
    emit(st, "    add $8, %rsp")
};

// arr[lo:hi] — half-open, clamped, always a NEW heap array (the operands
// are untouched, like `+` on arrays). A missing bound means 0 / len.
def gen_slice(st: EmitSt, node: Slice) -> EmitSt {
    let lo = node.lo;
    let hi = node.hi;
    let slesz = arr_elem_bytes(infer(st, node.arr));
    st = gen(st, node.arr);
    st = emit(st, "    push %rax");
    if (lo.k == K.void) {
        st = emit(st, "    xor %eax, %eax");
    } else {
        st = gen(st, lo);
    };
    st = emit(st, "    push %rax");
    if (hi.k == K.void) {
        // default: the array's length (the header keeps it in slot 0);
        // the array pointer sits one slot below the pushed lo.
        st = emit(st, "    mov 8(%rsp), %rax");
        st = emit(st, "    mov (%rax), %rax");
    } else {
        st = gen(st, hi);
    };
    st = emit(st, "    push %rax");
    st = emit(st, "    mov $" + tostring(slesz) + ", %rax");
    st = emit(st, "    push %rax");
    st = emit(st, "    call y_arr_slice");
    emit(st, "    add $32, %rsp")
};

// s[lo:hi] -- the substring, half-open and clamped like an array slice;
// a missing bound means 0 / len (the asm primitive y_str_slice).
def gen_str_slice(st: EmitSt, node: Slice) -> EmitSt {
    let lo = node.lo;
    let hi = node.hi;
    st = gen(st, node.arr);
    st = emit(st, "    push %rax");
    if (lo.k == K.void) {
        st = emit(st, "    xor %eax, %eax");
    } else {
        st = gen(st, lo);
    };
    st = emit(st, "    push %rax");
    if (hi.k == K.void) {
        st = emit(st, "    mov 8(%rsp), %rax");
        st = emit(st, "    mov (%rax), %rax");
    } else {
        st = gen(st, hi);
    };
    st = emit(st, "    push %rax");
    st = emit(st, "    call y_str_slice");
    emit(st, "    add $24, %rsp")
};

// a[lo:hi] = src: y_arr_setslice{1,8} (rt.y) check the range and the
// length, then copy src's elements in. Evaluation order: a, lo, hi, src.
def gen_sliceassign(st: EmitSt, node: SliceAssign) -> EmitSt {
    let lo = node.lo;
    let hi = node.hi;
    let esz = arr_elem_bytes(infer(st, node.arr));
    st = gen(st, node.arr);
    st = emit(st, "    push %rax");
    if (lo.k == K.void) {
        st = emit(st, "    xor %eax, %eax");
    } else {
        st = gen(st, lo);
    };
    st = emit(st, "    push %rax");
    if (hi.k == K.void) {
        st = emit(st, "    mov 8(%rsp), %rax");
        st = emit(st, "    mov (%rax), %rax");
    } else {
        st = gen(st, hi);
    };
    st = emit(st, "    push %rax");
    st = gen(st, node.v);
    st = emit(st, "    push %rax");
    st = emit(st, "    call y_arr_setslice" + tostring(esz));
    st = emit(st, "    add $32, %rsp");
    emit(st, "    xor %eax, %eax")
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
    } else {
        // a record: the checker took the pattern as its own type
        emit(st, "    mov $1, %rax")
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
    st = emit(st, "    test %rax, %rax");
    st = emit(st, "    jz " + rno.lbl);
    st = emit(st, "    mov -8(%rax), %rcx");
    let yes = next_loc(st);
    st = yes.st;
    let i = 0;
    while (i < len(ts)) {
        let dr = ty_desc_in(st, ts[i], inu);
        st = dr.st;
        st = emit(st, "    lea " + dr.lbl + "(%rip), %rdx");
        st = emit(st, "    cmp %rdx, %rcx");
        st = emit(st, "    je " + yes.lbl);
        i = i + 1;
    };
    st = emit(st, rno.lbl + ":");
    st = emit(st, "    xor %eax, %eax");
    st = emit(st, "    jmp " + rdone.lbl);
    st = emit(st, yes.lbl + ":");
    st = emit(st, "    mov $1, %rax");
    emit(st, rdone.lbl + ":")
};

// Union value in %rax -> its string form: the member its descriptor names
// ("<union>" for none).
def gen_union_str_rax(st: EmitSt, t: Type, path: [Type]) -> EmitSt {
    let ms = types.union_parts(t);
    let rdone = next_loc(st);
    st = rdone.st;
    st = emit(st, "    push %rax");
    let m = 0;
    while (m < len(ms)) {
        let rnext = next_loc(st);
        st = rnext.st;
        let mt = ms[m];
        let one: [Type] = [];
        one += mt;
        st = emit(st, "    mov (%rsp), %rax");
        st = gen_tag_in(st, one, t);
        st = emit(st, "    test %rax, %rax");
        st = emit(st, "    jz " + rnext.lbl);
        st = emit(st, "    pop %rax");
        let mu = types.unfold(mt);
        st = gen_rec_str_rax(st, mu, union_lay(mu, t), path + t);
        st = emit(st, "    jmp " + rdone.lbl);
        st = emit(st, rnext.lbl + ":");
        m = m + 1;
    };
    st = emit(st, "    pop %rax");
    st = gen_str_const(st, "<union>");
    emit(st, rdone.lbl + ":")
};

// Indirect call through a closure value produced by `callee`.
def gen_indirect(st: EmitSt, node: Call, callee: Node) -> EmitSt {
    let args: [Node] = node.args;
    let n = len(args);
    let iptypes = fn_args_of(infer(st, callee));
    st = gen(st, callee);
    st = emit(st, "    push %rax");
    st = gen_push_args_as(st, args, iptypes);
    // Reload the closure (it sits just below the n pushed args) and call
    // through its code pointer.
    st = emit(st, "    mov " + tostring(8 * n) + "(%rsp), %rax");
    st = emit(st, "    mov (%rax), %rax");
    st = emit(st, "    call *%rax");
    emit(st, "    add $" + tostring(8 * (n + 1)) + ", %rsp")
};

def gen_un(st: EmitSt, node: Un) -> EmitSt {
    let ut = infer(st, node.e);
    st = gen(st, node.e);
    if (node.op == "-") {
        if (ut.k == K.tfloat) {
            // flip the sign bit: -0.0 is a negative zero, -nan a nan
            st = emit(st, "    mov $1, %rcx");
            st = emit(st, "    shl $63, %rcx");
            emit(st, "    xor %rcx, %rax")
        } else {
            emit(st, "    neg %rax")
        }
    } else if (node.op == "~") {
        emit(st, "    not %rax")
    } else {
        emit(st, "    xor $1, %rax")
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
            emit(st, "    mov " + tostring(e.off) + "(%rbp), %rax")
        } else if (e.kind == "global") {
            emit(st, "    lea " + e.label + "(%rip), %rax")
        } else if (e.kind == "capture") {
            let aidx = tonum(e.label);
            st = emit(st, "    mov " + tostring(e.off) + "(%rbp), %rcx");
            emit(st, "    mov " + tostring(8 * (aidx + 1)) + "(%rcx), %rax")
        } else {
            emit(st, "    lea " + tostring(e.off) + "(%rbp), %rax")
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
    let eascale = "8";
    if (eaesz == 1) { eascale = "1"; }
    st = gen(st, earr);
    st = emit(st, "    push %rax");
    st = gen(st, node.idx);
    st = emit(st, "    mov %rax, %rcx");
    st = emit(st, "    pop %rax");
    st = emit(st, "    test %rcx, %rcx");
    st = emit(st, "    js y_oob");
    if (bt.k == K.tarrfix) {
        let arr: TFix = bt;
        st = emit(st, "    cmp $" + tostring(arr.n) + ", %rcx");
        st = emit(st, "    jge y_oob");
    } else {
        st = emit(st, "    mov (%rax), %rdx");
        st = emit(st, "    cmp %rdx, %rcx");
        st = emit(st, "    jge y_oob");
    };
    st = emit(st, "    mov 16(%rax), %rax");
    emit(st, "    lea (%rax,%rcx," + eascale + "), %rax")
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
    } else if ((op == "==" || op == "!=") && is_none_id(node.l) && is_map_read(st, node.r)) {
        if (op == "==") { gen_map_get(st, node.r, "none") } else { gen_map_get(st, node.r, "has") }
    } else {
        gen_bin_rest(st, node)
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
    st = emit(st, "    test %rax, %rax");
    if (is_or) {
        st = emit(st, "    jnz " + rT.lbl);
    }
    if (is_or) {
    } else {
        st = emit(st, "    jz " + rF.lbl);
    };
    st = gen(st, node.r);
    st = emit(st, "    test %rax, %rax");
    if (is_or) {
        st = emit(st, "    jnz " + rT.lbl);
    }
    if (is_or) {
    } else {
        st = emit(st, "    jz " + rF.lbl);
    };
    if (is_or) {
    } else {
        st = emit(st, "    mov $1, %rax");
        st = emit(st, "    jmp " + rE.lbl);
    };
    if (is_or) {
        st = emit(st, "    xor %eax, %eax");
        st = emit(st, "    jmp " + rE.lbl);
        st = emit(st, rT.lbl + ":");
        st = emit(st, "    mov $1, %rax");
    }
    if (is_or) {
    } else {
        st = emit(st, rF.lbl + ":");
        st = emit(st, "    xor %eax, %eax");
    };
    st = emit(st, rE.lbl + ":")
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
            st = emit(st, "    call y_str_cat");
            st = emit(st, "    add $16, %rsp")
        } else if (rt.k == K.tlong) {
            st = gen(st, node.l);
            st = emit(st, "    push %rax");
            st = gen(st, node.r);
            st = emit(st, "    push %rax");
            st = emit(st, "    call y_long_tostr");
            st = emit(st, "    add $8, %rsp");
            st = emit(st, "    push %rax");
            st = emit(st, "    call y_str_cat");
            st = emit(st, "    add $16, %rsp")
        } else if (rt.k == K.tbool) {
            st = gen(st, node.l);
            st = emit(st, "    push %rax");
            st = gen(st, node.r);
            st = emit(st, "    push %rax");
            st = emit(st, "    call y_bool_tostr");
            st = emit(st, "    add $8, %rsp");
            st = emit(st, "    push %rax");
            st = emit(st, "    call y_str_cat");
            st = emit(st, "    add $16, %rsp")
        } else if (rt.k == K.tfloat) {
            st = gen(st, node.l);
            st = emit(st, "    push %rax");
            st = gen(st, node.r);
            st = emit(st, "    push %rax");
            st = emit(st, "    call y_float_tostr");
            st = emit(st, "    add $8, %rsp");
            st = emit(st, "    push %rax");
            st = emit(st, "    call y_str_cat");
            st = emit(st, "    add $16, %rsp")
        } else {
            // Unknown right operand: treat it as a string. Most unknowns
            // here ARE strings (a field read through an untyped hole infers
            // as tunk — the compiler's own tstr() does exactly that), and
            // the return-type inference in emit_program now pins down the
            // long-returning calls that used to land in this arm.
            st = gen_push_args(st, [node.l, node.r]);
            st = emit(st, "    call y_str_cat");
            st = emit(st, "    add $16, %rsp")
        };
    }
    if (!(lt.k == K.tstr)) {
        if (lt.k == K.tlong) {
            st = gen(st, node.l);
            st = emit(st, "    push %rax");
            st = emit(st, "    call y_long_tostr");
            st = emit(st, "    add $8, %rsp");
            st = emit(st, "    push %rax");
            st = gen(st, node.r);
            st = emit(st, "    push %rax");
            st = emit(st, "    call y_str_cat");
            st = emit(st, "    add $16, %rsp")
        } else if (lt.k == K.tbool) {
            st = gen(st, node.l);
            st = emit(st, "    push %rax");
            st = emit(st, "    call y_bool_tostr");
            st = emit(st, "    add $8, %rsp");
            st = emit(st, "    push %rax");
            st = gen(st, node.r);
            st = emit(st, "    push %rax");
            st = emit(st, "    call y_str_cat");
            st = emit(st, "    add $16, %rsp")
        } else if (lt.k == K.tfloat) {
            st = gen(st, node.l);
            st = emit(st, "    push %rax");
            st = emit(st, "    call y_float_tostr");
            st = emit(st, "    add $8, %rsp");
            st = emit(st, "    push %rax");
            st = gen(st, node.r);
            st = emit(st, "    push %rax");
            st = emit(st, "    call y_str_cat");
            st = emit(st, "    add $16, %rsp")
        } else {
            // Unknown left operand: treat it as a string (see the note on
            // the right-operand arm).
            st = gen_push_args(st, [node.l, node.r]);
            st = emit(st, "    call y_str_cat");
            st = emit(st, "    add $16, %rsp")
        };
    }
    st
};

// Float arithmetic and comparison. Operands arrive in %rax as raw bits;
// a long operand is widened with cvtsi2sd first (the only coercion).
def gen_float_bin(st: EmitSt, node: Bin, lt: Type, rt: Type) -> EmitSt {
    let op = node.op;
    st = gen(st, node.l);
    if (lt.k == K.tfloat) { } else {
        st = emit(st, "    cvtsi2sd %rax, %xmm0");
        st = emit(st, "    movq %xmm0, %rax");
    };
    st = emit(st, "    push %rax");
    st = gen(st, node.r);
    if (rt.k == K.tfloat) { } else {
        st = emit(st, "    cvtsi2sd %rax, %xmm0");
        st = emit(st, "    movq %xmm0, %rax");
    };
    st = emit(st, "    movq %rax, %xmm1");
    st = emit(st, "    pop %rax");
    st = emit(st, "    movq %rax, %xmm0");
    if (op == "+") {
        st = emit(st, "    addsd %xmm1, %xmm0");
        emit(st, "    movq %xmm0, %rax")
    } else if (op == "-") {
        st = emit(st, "    subsd %xmm1, %xmm0");
        emit(st, "    movq %xmm0, %rax")
    } else if (op == "*") {
        st = emit(st, "    mulsd %xmm1, %xmm0");
        emit(st, "    movq %xmm0, %rax")
    } else if (op == "/") {
        st = emit(st, "    divsd %xmm1, %xmm0");
        emit(st, "    movq %xmm0, %rax")
    } else if (op == "%") {
        // The IEEE remainder truncated toward zero -- C's fmod, the one with
        // the dividend's sign. There is no x87-style bit twiddling for it on
        // SSE2 (fmod has no instruction), so the prelude does the reduction;
        // both operands are already in SSE registers.
        st = emit(st, "    call y_fmod");
        emit(st, "    movq %xmm0, %rax")
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
            st = emit(st, "    ucomisd %xmm0, %xmm1");
            st = emit(st, "    seta %al");
            emit(st, "    movzbq %al, %rax")
        } else if (op == "<=") {
            st = emit(st, "    ucomisd %xmm0, %xmm1");
            st = emit(st, "    setae %al");
            emit(st, "    movzbq %al, %rax")
        } else if (op == ">") {
            st = emit(st, "    ucomisd %xmm1, %xmm0");
            st = emit(st, "    seta %al");
            emit(st, "    movzbq %al, %rax")
        } else if (op == ">=") {
            st = emit(st, "    ucomisd %xmm1, %xmm0");
            st = emit(st, "    setae %al");
            emit(st, "    movzbq %al, %rax")
        } else {
            st = emit(st, "    ucomisd %xmm1, %xmm0");
            if (op == "==") {
                st = emit(st, "    sete %al");
                st = emit(st, "    setnp %cl");
            } else {
                st = emit(st, "    setne %al");
                st = emit(st, "    setp %cl");
            };
            st = emit(st, "    movzbq %al, %rax");
            st = emit(st, "    movzbq %cl, %rcx");
            if (op == "==") {
                st = emit(st, "    and %rcx, %rax");
            } else {
                st = emit(st, "    or %rcx, %rax");
            };
            st
        }
    }
};

def gen_str_cmp(st: EmitSt, node: Bin, op: str) -> EmitSt {
    st = gen_push_args(st, [node.l, node.r]);
    st = emit(st, "    call y_str_cmp");
    st = emit(st, "    add $16, %rsp");
    st = emit(st, "    cmp $0, %rax");
    if (op == "<") {
        st = emit(st, "    setl %al");
    } else if (op == ">") {
        st = emit(st, "    setg %al");
    } else if (op == "<=") {
        st = emit(st, "    setle %al");
    } else {
        st = emit(st, "    setge %al");
    };
    emit(st, "    movzbq %al, %rax")
};

// == on values whose equality looks inside them (NATIVE.md, "Equality"):
// two options compare their payloads, and an array compares each pair of
// elements with the element type's own ==, at any depth. Arrays of words
// whose == is the bit pattern, and arrays of strings, keep the y_arr_eq /
// y_arr_eq_str cores; the others loop here: options and arrays look
// inside, and floats compare as numbers (0.0 == -0.0).
def eq_elem_loop(t: Type) -> bool {
    t.k == K.topt || t.k == K.tarr || t.k == K.tfloat
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
            st = emit(st, "    push %rax");
            st = emit(st, "    call y_arr_eq_str");
            emit(st, "    add $16, %rsp")
        } else {
            st = emit(st, "    push %rax");
            st = emit(st, "    mov $" + tostring(elem_bytes(arr.of)) + ", %rax");
            st = emit(st, "    push %rax");
            st = emit(st, "    call y_arr_eq");
            emit(st, "    add $24, %rsp")
        }
    } else if (t.k == K.tstr) {
        st = emit(st, "    push %rax");
        st = emit(st, "    call y_str_eq");
        emit(st, "    add $16, %rsp")
    } else if (t.k == K.tfloat) {
        // as gen_float_bin's ==: equal, and ordered -- NaN is equal to nothing,
        // itself included, which is what setnp is for
        st = emit(st, "    movq %rax, %xmm1");
        st = emit(st, "    pop %rax");
        st = emit(st, "    movq %rax, %xmm0");
        st = emit(st, "    ucomisd %xmm1, %xmm0");
        st = emit(st, "    sete %al");
        st = emit(st, "    setnp %cl");
        st = emit(st, "    movzbq %al, %rax");
        st = emit(st, "    movzbq %cl, %rcx");
        emit(st, "    and %rcx, %rax")
    } else {
        // one word: a scalar by value, a record or map by identity
        st = emit(st, "    pop %rcx");
        st = emit(st, "    cmp %rax, %rcx");
        st = emit(st, "    sete %al");
        emit(st, "    movzbq %al, %rax")
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
    st = emit(st, "    pop %rcx");
    st = emit(st, "    test %rcx, %rcx");
    st = emit(st, "    jz " + lnone.lbl);
    st = emit(st, "    test %rax, %rax");
    st = emit(st, "    jz " + lne.lbl);
    st = emit(st, "    mov (%rcx), %rcx");
    st = emit(st, "    push %rcx");
    st = emit(st, "    mov (%rax), %rax");
    st = gen_eq_vals(st, pt);
    st = emit(st, "    jmp " + ldone.lbl);
    st = emit(st, lnone.lbl + ":");
    st = emit(st, "    test %rax, %rax");
    st = emit(st, "    sete %al");
    st = emit(st, "    movzbq %al, %rax");
    st = emit(st, "    jmp " + ldone.lbl);
    st = emit(st, lne.lbl + ":");
    st = emit(st, "    xor %eax, %eax");
    emit(st, ldone.lbl + ":")
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
    st = emit(st, "    pop %rcx");
    st = emit(st, "    mov (%rcx), %rdx");
    st = emit(st, "    mov (%rax), %rsi");
    st = emit(st, "    cmp %rsi, %rdx");
    st = emit(st, "    jne " + lne.lbl);
    st = emit(st, "    push %rcx");
    st = emit(st, "    push %rax");
    st = emit(st, "    xor %edx, %edx");
    st = emit(st, "    push %rdx");
    st = emit(st, lloop.lbl + ":");
    st = emit(st, "    mov (%rsp), %rdx");
    st = emit(st, "    mov 16(%rsp), %rcx");
    st = emit(st, "    mov (%rcx), %rsi");
    st = emit(st, "    cmp %rsi, %rdx");
    st = emit(st, "    jge " + lsame.lbl);
    st = emit(st, "    mov 16(%rcx), %rcx");
    st = emit(st, "    mov (%rcx,%rdx,8), %rcx");
    st = emit(st, "    mov 8(%rsp), %rax");
    st = emit(st, "    mov 16(%rax), %rax");
    st = emit(st, "    mov (%rax,%rdx,8), %rax");
    st = emit(st, "    push %rcx");
    st = gen_eq_vals(st, et);
    st = emit(st, "    test %rax, %rax");
    st = emit(st, "    jz " + ldiff.lbl);
    st = emit(st, "    mov (%rsp), %rdx");
    st = emit(st, "    inc %rdx");
    st = emit(st, "    mov %rdx, (%rsp)");
    st = emit(st, "    jmp " + lloop.lbl);
    st = emit(st, lsame.lbl + ":");
    st = emit(st, "    add $24, %rsp");
    st = emit(st, "    mov $1, %rax");
    st = emit(st, "    jmp " + ldone.lbl);
    st = emit(st, ldiff.lbl + ":");
    st = emit(st, "    add $24, %rsp");
    st = emit(st, lne.lbl + ":");
    st = emit(st, "    xor %eax, %eax");
    emit(st, ldone.lbl + ":")
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
    } else if (op == "::") {
        gen_cons(st, node)
    } else if (op == "<<" || op == ">>" || op == ">>>") {
        gen_shift(st, node, op)
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
        st = emit(st, "    call y_str_eq");
        st = emit(st, "    add $16, %rsp");
        if (op == "!=") {
            emit(st, "    xor $1, %rax")
        } else {
            st
        }
    } else if ((op == "<" || op == ">" || op == "<=" || op == ">=") && lt.k == K.tstr) {
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
            st = emit(st, "    push %rax");
            st = gen(st, node.r);
            st = gen_eq_arr_deep(st, elt);
        } else {
            st = gen_push_args(st, [node.l, node.r]);
            if (elt.k == K.tstr) {
                st = emit(st, "    call y_arr_eq_str");
                st = emit(st, "    add $16, %rsp");
            } else {
                st = emit(st, "    mov $" + tostring(elem_bytes(elt)) + ", %rax");
                st = emit(st, "    push %rax");
                st = emit(st, "    call y_arr_eq");
                st = emit(st, "    add $24, %rsp");
            };
        };
        if (op == "!=") {
            emit(st, "    xor $1, %rax")
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
        st = emit(st, "    push %rax");
        st = gen(st, node.r);
        st = gen_eq_opt(st, pt);
        if (op == "!=") {
            emit(st, "    xor $1, %rax")
        } else {
            st
        }
    } else {
    st = gen(st, node.l);
    st = emit(st, "    push %rax");
    st = gen(st, node.r);
    st = emit(st, "    mov %rax, %rcx");
    st = emit(st, "    pop %rax");
    if (op == "+") {
        emit(st, "    add %rcx, %rax")
    } else if (op == "-") {
        emit(st, "    sub %rcx, %rax")
    } else if (op == "*") {
        emit(st, "    imul %rcx, %rax")
    } else if (op == "/") {
        // idiv raises #DE on LONG_MIN / -1 (the quotient does not fit), so
        // divisor -1 is handled as a negation instead: neg of LONG_MIN
        // wraps back to LONG_MIN (the language's rule for the whole long
        // range, NATIVE.md), and every other value negates exactly.
        st = emit(st, "    test %rcx, %rcx");
        st = emit(st, "    jz y_div_zero");
        let d1 = next_loc(st);
        st = d1.st;
        let d2 = next_loc(st);
        st = d2.st;
        st = emit(st, "    cmp $-1, %rcx");
        st = emit(st, "    jne " + d1.lbl);
        st = emit(st, "    neg %rax");
        st = emit(st, "    jmp " + d2.lbl);
        st = emit(st, d1.lbl + ":");
        st = emit(st, "    cqo");
        st = emit(st, "    idiv %rcx");
        emit(st, d2.lbl + ":")
    } else if (op == "%") {
        // Same #DE: x % -1 is 0 for every x (see the `/` note).
        st = emit(st, "    test %rcx, %rcx");
        st = emit(st, "    jz y_div_zero");
        let m1 = next_loc(st);
        st = m1.st;
        let m2 = next_loc(st);
        st = m2.st;
        st = emit(st, "    cmp $-1, %rcx");
        st = emit(st, "    jne " + m1.lbl);
        st = emit(st, "    xor %eax, %eax");
        st = emit(st, "    jmp " + m2.lbl);
        st = emit(st, m1.lbl + ":");
        st = emit(st, "    cqo");
        st = emit(st, "    idiv %rcx");
        st = emit(st, "    mov %rdx, %rax");
        emit(st, m2.lbl + ":")
    } else if (op == "<") {
        st = emit(st, "    cmp %rcx, %rax");
        st = emit(st, "    setl %al");
        emit(st, "    movzbq %al, %rax")
    } else if (op == ">") {
        st = emit(st, "    cmp %rcx, %rax");
        st = emit(st, "    setg %al");
        emit(st, "    movzbq %al, %rax")
    } else if (op == "<=") {
        st = emit(st, "    cmp %rcx, %rax");
        st = emit(st, "    setle %al");
        emit(st, "    movzbq %al, %rax")
    } else if (op == ">=") {
        st = emit(st, "    cmp %rcx, %rax");
        st = emit(st, "    setge %al");
        emit(st, "    movzbq %al, %rax")
    } else if (op == "==") {
        st = emit(st, "    cmp %rcx, %rax");
        st = emit(st, "    sete %al");
        emit(st, "    movzbq %al, %rax")
    } else if (op == "!=") {
        st = emit(st, "    cmp %rcx, %rax");
        st = emit(st, "    setne %al");
        emit(st, "    movzbq %al, %rax")
    } else if (op == "&") {
        emit(st, "    and %rcx, %rax")
    } else if (op == "|") {
        emit(st, "    or %rcx, %rax")
    } else if (op == "^") {
        emit(st, "    xor %rcx, %rax")
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
    if (op == ">>") { mn = "sar"; }
    else if (op == ">>>") { mn = "shr"; }
    let n = shift_imm(node.r);
    st = gen(st, node.l);
    if (n >= 0) {
        emit(st, "    " + mn + " $" + tostring(n) + ", %rax")
    } else {
        st = emit(st, "    push %rax");
        st = gen(st, node.r);
        st = emit(st, "    mov %rax, %rcx");
        st = emit(st, "    pop %rax");
        st = emit(st, "    test %rcx, %rcx");
        st = emit(st, "    js y_shift_neg");
        let ok = next_loc(st);
        st = ok.st;
        st = emit(st, "    cmp $64, %rcx");
        st = emit(st, "    jb " + ok.lbl);
        if (mn == "sar") {
            st = emit(st, "    mov $63, %rcx");
        } else {
            st = emit(st, "    xor %eax, %eax");
        };
        st = emit(st, ok.lbl + ":");
        emit(st, "    " + mn + " %cl, %rax")
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
            else if (tonum(s) < 64) { tonum(s) }
            else { -1 }
        }
    } else { -1 }
};

// ── calls ──────────────────────────────────────────────────────────────
// Linux syscall arg regs (in order): rdi, rsi, rdx, r10, r8, r9.

def syscall_reg(i: long) -> str {
    if (i == 0) { "%rdi" }
    else if (i == 1) { "%rsi" }
    else if (i == 2) { "%rdx" }
    else if (i == 3) { "%r10" }
    else if (i == 4) { "%r8" }
    else { "%r9" }
};

def gen_push_args(st: EmitSt, args: [Node]) -> EmitSt {
    let i = 0;
    while (i < len(args)) {
        st = gen(st, args[i]);
        st = emit(st, "    push %rax");
        i = i + 1;
    };
    st
};

// gen_push_args, with argument i converted (gen_as) to ptypes[i], the
// type of the parameter it binds; arguments past ptypes are pushed as is.
def gen_push_args_as(st: EmitSt, args: [Node], ptypes: [Type]) -> EmitSt {
    let i = 0;
    while (i < len(args)) {
        if (i < len(ptypes)) {
            st = gen_as(st, args[i], ptypes[i]);
        } else {
            st = gen(st, args[i]);
        };
        st = emit(st, "    push %rax");
        i = i + 1;
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
    if (wk == K.tfloat && (gk == K.tlong || gk == K.tbyte)) {
        st = emit(st, "    cvtsi2sd %rax, %xmm0");
        emit(st, "    movq %xmm0, %rax")
    } else if (wk == K.tbyte && gk == K.tlong) {
        emit(st, "    movzbq %al, %rax")
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
    if (wk == K.tfloat || wk == K.tbyte) {
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
            let a0 = args[0];
            id.v == "some" && a0.k == K.rec
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
            i = i + 1;
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
    let i = 0;
    while (i < len(ts)) {
        let m = types.union_member(su, ts[i]);
        if (m.k != K.tnone) { out += m; };
        i = i + 1;
    };
    out
};

// gen_convert's check of a cast from union u: the record in %rax (kept)
// is one of its members ts, or the program stops (y_cast_trap).
def gen_cast_check(st: EmitSt, ts: [Type], u: Type) -> EmitSt {
    let ok = next_loc(st);
    st = ok.st;
    st = emit(st, "    mov -8(%rax), %rcx");
    let i = 0;
    while (i < len(ts)) {
        let dr = ty_desc_in(st, ts[i], u);
        st = dr.st;
        st = emit(st, "    lea " + dr.lbl + "(%rip), %rdx");
        st = emit(st, "    cmp %rdx, %rcx");
        st = emit(st, "    je " + ok.lbl);
        i = i + 1;
    };
    st = emit(st, "    jmp y_cast_trap");
    emit(st, ok.lbl + ":")
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
    let ft = cur_fn_type(st);
    let ret: Type = ft.ret;
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
def gen_helper1(st: EmitSt, label: str) -> EmitSt {
    st = emit(st, "    push %rax");
    st = emit(st, "    call " + label);
    emit(st, "    add $8, %rsp")
};

def gen_call(st: EmitSt, node: Call) -> EmitSt {
    let callee: Node = node.callee;
    if (callee.k != K.id) {
        if (callee.k == K.dot) {
            let dot: Dot = callee;
            if (infer(st, dot.obj).k == K.tstr) {
                gen_method(st, node)
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
        } else if (name == "byte_at") {
            gen_byte_at(st, node)
        } else if (name == "ord") {
            gen_ord(st, node)
        } else if (name == "chr") {
            gen_chr(st, node)
        } else if (name == "tonum") {
            gen_tonum(st, node)
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
            emit(st, "    call y_" + name)
        } else if (name == "wait_pid") {
            let wa: [Node] = node.args;
            st = gen(st, wa[0]);
            gen_helper1(st, "y_wait_pid")
        } else if (name == "post" || name == "wait") {
            let pa: [Node] = node.args;
            st = gen(st, pa[0]);
            emit(st, "    call y_sem_" + name)
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
            emit(st, "    call y_time_us")
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
            st = emit(st, "    call y_str_to_bytes");
            emit(st, "    add $8, %rsp")
        } else if (name == "from_bytes") {
            let args: [Node] = node.args;
            st = gen_push_args(st, args);
            st = emit(st, "    call y_bytes_to_str");
            emit(st, "    add $8, %rsp")
        } else if (name == "ptr_addr") {
            // A pointer IS its numeric value at run time: nothing to emit
            // beyond evaluating the operand. This exists only so the type
            // system lets the value cross into long territory.
            let paargs: [Node] = node.args;
            gen(st, paargs[0])
        } else {
            gen_direct(st, node, name)
        }
    }
};

// `s.m(args)` with s a str (the checker validated it against
// types.str_method): the receiver becomes the first argument (the last
// for `sep.join(xs)`), a left-out optional argument its default, and
// the call goes to the builtin's own lowering, or straight to the
// std/str.y helper by label -- a Y function like any other, so the
// arguments are pushed and the caller pops them.
def gen_method(st: EmitSt, node: Call) -> EmitSt {
    let mcal: Dot = node.callee;
    let mobj = mcal.obj;
    let sm = types.str_method(mcal.key);
    let margs: [Node] = node.args;
    let args: [Node] = [];
    if (!sm.last) { args += mobj; };
    let i = 0;
    while (i < len(margs)) {
        args += margs[i];
        i = i + 1;
    };
    if (len(margs) < len(sm.params)) {
        args += n_str(sm.dflt, node.line, node.col);
    };
    if (sm.last) { args += mobj; };
    let fname = sm.fn;
    if (len(runtime_base(fname)) > 0) {
        st = gen_push_args(st, args);
        st = emit(st, "    call " + fname);
        emit(st, "    add $" + tostring(len(args) * 8) + ", %rsp")
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
        emit(st, "    xor %eax, %eax")
    } else if (t.k == K.tfunc) {
        // A function value has no printable contents; show its signature
        // (`<function (params) -> ret>`, in the spelling types.y tstr gives,
        // the one every diagnostic uses).
        st = gen(st, pa0);
        st = gen_str_const(st, "<function " + types.tstr(t) + ">");
        st = gen_helper1(st, "y_print_hstr");
        emit(st, "    xor %eax, %eax")
    } else if (t.k == K.tarr || t.k == K.tarrfix) {
        // Arrays print like tostring: "[e0, e1, ...]", or b'...' for
        // [byte] (Python-style byte strings).
        st = gen(st, pa0);
        let arr: ArrTy = t;
        if (arr.of.k == K.tbyte) {
            st = gen_helper1(st, "y_bytes_repr");
        } else {
            st = gen_arr_tostr_rax(st, arr.of, []);
        };
        st = gen_helper1(st, "y_print_hstr");
        emit(st, "    xor %eax, %eax")
    } else if (t.k == K.topt) {
        st = gen(st, pa0);
        st = gen_opt_str_rax(st, t, []);
        st = gen_helper1(st, "y_print_hstr");
        emit(st, "    xor %eax, %eax")
    } else if (t.k == K.tmap) {
        // Maps format entry by entry: {"k": v, ...} (quoted keys).
        st = gen_map_repr(st, pa0, t);
        st = gen_helper1(st, "y_print_hstr");
        emit(st, "    xor %eax, %eax")
    } else if (t.k == K.tunion) {
        st = gen(st, pa0);
        st = gen_union_str_rax(st, t, []);
        st = gen_helper1(st, "y_print_hstr");
        emit(st, "    xor %eax, %eax")
    } else {
        gen_print_scalar(st, pa0, t)
    }
};

def gen_print_scalar(st: EmitSt, arg: Node, t: Type) -> EmitSt {
    st = gen(st, arg);
    if (t.k == K.tbool) {
        st = gen_helper1(st, "y_print_bool");
        emit(st, "    xor %eax, %eax")
    } else if (t.k == K.tstr) {
        st = gen_helper1(st, "y_print_hstr");
        emit(st, "    xor %eax, %eax")
    } else if (t.k == K.tfloat) {
        st = gen_helper1(st, "y_print_float");
        emit(st, "    xor %eax, %eax")
    } else {
        st = gen_helper1(st, "y_print_long");
        emit(st, "    xor %eax, %eax")
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
    st = emit(st, "    test %rax, %rax");
    st = emit(st, "    jz " + rnul.lbl);
    st = emit(st, "    mov (%rax), %rax");
    let opt: TOf = t;
    st = gen_val_tostr_rax(st, opt.of, path + t);
    st = emit(st, "    jmp " + rdone.lbl);
    st = emit(st, rnul.lbl + ":");
    st = gen_str_const(st, "none");
    emit(st, rdone.lbl + ":")
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
    st = emit(st, "    push %rax");
    st = gen_str_const(st, "{");
    st = emit(st, "    push %rax");
    let rec: TRec = t;
    let fs: [Field] = rec.fields;
    let i = 0;
    while (i < len(fs)) {
        let f = fs[i];
        let fname: str = f.name;
        let sep = "";
        if (i > 0) { sep = ", "; }
        st = gen_acc_cat_const(st, sep + fname + ": ");
        st = gen_rec_field_str(st, mfield_idx(lay, fname), f.typ, path);
        i = i + 1;
    };
    st = gen_acc_cat_const(st, "}");
    st = emit(st, "    mov (%rsp), %rax");
    emit(st, "    add $16, %rsp")
};

// `x :: a` -- cons: a NEW array with x prepended as exactly ONE element
// (types.y typeof_cons keeps even array-typed elements whole).
def gen_cons(st: EmitSt, node: Bin) -> EmitSt {
    let ln = node.line;
    let cl = node.col;
    let crt = infer(st, node.r);
    let cesz = arr_elem_bytes(crt);
    let one = { k: K.array, elems: args1(node.l), line: ln, col: cl };
    st = gen_array_esz(st, one, cesz, store_elem_type(crt, cesz));
    st = emit(st, "    push %rax");
    st = gen(st, node.r);
    st = emit(st, "    push %rax");
    st = emit(st, "    mov $" + tostring(cesz) + ", %rax");
    st = emit(st, "    push %rax");
    st = emit(st, "    call y_arr_cat");
    emit(st, "    add $24, %rsp")
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
    let da: Decl = { k: K.decl, kind: "let", typ: normtype({ k: K.tnone }), name: t1 + "l", v: node.l, line: ln, col: cl };
    let db: Decl = { k: K.decl, kind: "let", typ: normtype({ k: K.tnone }), name: t1 + "r", v: node.r, line: ln, col: cl };
    let arr_type: ArrTy = lt;
    let dc: Decl = { k: K.decl, kind: "let", typ: type_node({ k: K.tarr, of: arr_type.of }), name: t1 + "c", v: { k: K.array, elems: noelems, line: ln, col: cl }, line: ln, col: cl };
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
    if (larr) {
    } else {
        one = { k: K.array, elems: args1(node.l), line: ln, col: cl };
    };
    if (larr) {
        st = gen(st, node.l);
        st = emit(st, "    push %rax");
        if (how == "cat") {
            st = gen(st, node.r);
        } else {
            st = gen_array_esz(st, one, esz, ety);
        };
    } else {
        st = gen_array_esz(st, one, esz, ety);
        st = emit(st, "    push %rax");
        st = gen(st, node.r);
    };
    st = emit(st, "    push %rax");
    st = emit(st, "    mov $" + tostring(esz) + ", %rax");
    st = emit(st, "    push %rax");
    st = emit(st, "    call y_arr_cat");
    emit(st, "    add $24, %rsp")
};

// acc = acc + <constant>, with the layout above still in place.
def gen_acc_cat_const(st: EmitSt, s: str) -> EmitSt {
    st = emit(st, "    mov (%rsp), %rax");
    st = emit(st, "    push %rax");
    st = gen_str_const(st, s);
    st = emit(st, "    push %rax");
    st = emit(st, "    call y_str_cat");
    st = emit(st, "    add $16, %rsp");
    emit(st, "    mov %rax, (%rsp)")
};

// Slot idx of the record in %rcx into register dst.
def gen_slot_load(st: EmitSt, idx: long, dst: str) -> EmitSt {
    emit(st, "    mov " + tostring(8 * idx) + "(%rcx), " + dst)
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
        st = emit(st, "    mov 8(%rsp), %rcx");
        gen_slot_load(st, idx, "%rax")
    } else if (fk == K.tlong) {
        st = emit(st, "    mov 8(%rsp), %rcx");
        st = gen_slot_load(st, idx, "%rax");
        st = emit(st, "    push %rax");
        st = emit(st, "    call y_long_tostr");
        emit(st, "    add $8, %rsp")
    } else if (fk == K.tbool) {
        st = emit(st, "    mov 8(%rsp), %rcx");
        st = gen_slot_load(st, idx, "%rax");
        st = emit(st, "    push %rax");
        st = emit(st, "    call y_bool_tostr");
        emit(st, "    add $8, %rsp")
    } else if (fk == K.tfloat) {
        st = emit(st, "    mov 8(%rsp), %rcx");
        st = gen_slot_load(st, idx, "%rax");
        st = emit(st, "    push %rax");
        st = emit(st, "    call y_float_tostr");
        emit(st, "    add $8, %rsp")
    } else if (fk == K.tfunc) {
        gen_str_const(st, "<function " + types.tstr(ft) + ">")
    } else {
        // Arrays, options, maps, records and unions nested in a RECORD: the
        // value walk formats them, the same text tostring() gives. This used
        // to print the field's TYPE instead ("<{str => long}>") on the
        // mistaken belief that only gen_val_tostr_rax walked them -- it does,
        // and it is exactly what a field needs.
        st = emit(st, "    mov 8(%rsp), %rcx");
        st = gen_slot_load(st, idx, "%rax");
        gen_val_tostr_rax(st, ft, path)
    };
    st = emit(st, "    mov %rax, %rdx");
    st = emit(st, "    mov (%rsp), %rax");
    st = emit(st, "    push %rax");
    st = emit(st, "    push %rdx");
    st = emit(st, "    call y_str_cat");
    st = emit(st, "    add $16, %rsp");
    emit(st, "    mov %rax, (%rsp)")
};

def gen_syscall(st: EmitSt, node: Call) -> EmitSt {
    let args: [Node] = node.args;
    // args[0] is the number; rest are a1..a6. Push all, pop into regs.
    st = gen_push_args(st, args);
    let n = len(args) - 1;
    let i = n;
    while (i >= 1) {
        st = emit(st, "    pop " + syscall_reg(i - 1));
        // a str flows in as its header; the kernel wants the data bytes.
        let at = infer(st, args[i]);
        if (at.k == K.tstr) {
            st = emit(st, "    add $8, " + syscall_reg(i - 1));
        }
        i = i - 1;
    };
    st = emit(st, "    pop %rax");
    emit(st, "    syscall")
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
        i = i + 1;
    };
    res
};

def gen_direct(st: EmitSt, node: Call, name: str) -> EmitSt {
    let label = "";
    let indirect = false;
    let dptypes: [Type] = [];
    if (name == "self") {
        label = st.self_label;
        dptypes = fn_args_of(cur_fn_type(st));
    } else {
        let e = env_find(st, name);
        if (e.kind == "none") {
            label = "y_missing_" + name;
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
            st = emit(st, "    mov " + tostring(soff) + "(%rbp), %rax");
            st = emit(st, "    push %rax");
        }
        st = gen_push_args_as(st, node.args, dptypes);
        st = emit(st, "    call " + label);
        let nbytes = len(node.args) * 8;
        if (soff >= 0) {
            nbytes = nbytes + 8;
        }
        if (nbytes == 0) {
            st
        } else {
            emit(st, "    add $" + tostring(nbytes) + ", %rsp")
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
// comparison -- the instruction a branch needs anyway -- or "" when the
// condition is anything else.
//
// Driven by the operator, never by matching the text of an emitted setcc: the
// materialisation and the branch can disagree (ucomisd sets ZF/PF/CF for an
// unordered compare, a structural == is a call), and the emitter may change how
// a bool is built without this going stale. Each jcc is the negation of its
// setcc form: `<` is setl, so its false edge is jge.
def int_cmp_jcc(st: EmitSt, node: Node) -> str {
    let jcc = "";
    if (node.k == K.bin) {
        let bin: Bin = node;
        let op = bin.op;
        if (cmp_word(infer(st, bin.l)) && cmp_word(infer(st, bin.r))) {
            if (op == "<") { jcc = "jge"; }
            else if (op == ">") { jcc = "jle"; }
            else if (op == "<=") { jcc = "jg"; }
            else if (op == ">=") { jcc = "jl"; }
            else if (op == "==") { jcc = "jne"; }
            else if (op == "!=") { jcc = "je"; };
        };
    };
    jcc
};

// The operands the way the numeric path emits them -- left into %rax, right
// into %rcx -- so the `cmp %rcx, %rax` that follows reads left - right and the
// same setcc/jcc forms apply.
def gen_cmp_flags(st: EmitSt, node: Bin) -> EmitSt {
    st = gen(st, node.l);
    st = emit(st, "    push %rax");
    st = gen(st, node.r);
    st = emit(st, "    mov %rax, %rcx");
    st = emit(st, "    pop %rax");
    emit(st, "    cmp %rcx, %rax")
};

def gen_if(st: EmitSt, node: If) -> EmitSt {
    let r1 = next_loc(st);
    st = r1.st;
    let r2 = next_loc(st);
    st = r2.st;
    let jcc = int_cmp_jcc(st, node.cond);
    if (jcc != "") {
        // A comparison branches on the flags it has just set: the bool is
        // never built. `setcc; movzbq; test; jcc` (four instructions) becomes
        // `cmp; jcc` (two) -- 3,049 such sites in ycc's own output.
        let cbin: Bin = node.cond;
        st = gen_cmp_flags(st, cbin);
        st = emit(st, "    " + jcc + " " + r1.lbl);
    } else {
        st = gen(st, node.cond);
        st = emit(st, "    test %rax, %rax");
        st = emit(st, "    jz " + r1.lbl);
    };
    st = gen(st, node.then);
    if (node.has_else) {
        st = emit(st, "    jmp " + r2.lbl);
        st = emit(st, r1.lbl + ":");
        st = gen_loc_elif(st, node.els);
        st = gen(st, node.els);
        emit(st, r2.lbl + ":")
    } else {
        emit(st, r1.lbl + ":")
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
    st = emit(st, r1.lbl + ":");
    let jcc = int_cmp_jcc(st, node.cond);
    if (jcc != "") {
        let cbin: Bin = node.cond;
        st = gen_cmp_flags(st, cbin);
        st = emit(st, "    " + jcc + " " + r2.lbl);
    } else {
        st = gen(st, node.cond);
        st = emit(st, "    test %rax, %rax");
        st = emit(st, "    jz " + r2.lbl);
    };
    st = gen_discard(st, node.body);
    st = gen_loc_loop(st, node);
    st = emit(st, "    jmp " + r1.lbl);
    emit(st, r2.lbl + ":")
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
    st = emit(st, r1.lbl + ":");
    let jcc = int_cmp_jcc(st, node.cond);
    if (jcc != "") {
        let cbin: Bin = node.cond;
        st = gen_cmp_flags(st, cbin);
        st = emit(st, "    " + jcc + " " + r2.lbl);
    } else {
        st = gen(st, node.cond);
        st = emit(st, "    test %rax, %rax");
        st = emit(st, "    jz " + r2.lbl);
    };
    st = gen_discard(st, node.body);
    st = gen_loc_loop(st, node);
    st = gen(st, node.step);
    st = emit(st, "    jmp " + r1.lbl);
    emit(st, r2.lbl + ":")
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
    st = { out: st.out, rodata: st.rodata, uid: st.uid,
      fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots + 2,
      self_label: st.self_label, end_label: st.end_label, fns: st.fns,
      bodies: st.bodies };
    st = gen(st, node.hi);
    st = emit(st, "    mov %rax, " + tostring(loff) + "(%rbp)");
    st = gen(st, node.lo);
    st = emit(st, "    mov %rax, " + tostring(voff) + "(%rbp)");
    st = env_define(st, node.name, "local", voff, "", normtype({ k: K.tlong }));
    let r1 = next_loc(st);
    st = r1.st;
    let r2 = next_loc(st);
    st = r2.st;
    st = emit(st, r1.lbl + ":");
    st = emit(st, "    mov " + tostring(voff) + "(%rbp), %rax");
    st = emit(st, "    mov " + tostring(loff) + "(%rbp), %rcx");
    st = emit(st, "    cmp %rcx, %rax");
    st = emit(st, "    jge " + r2.lbl);
    // a captured loop variable gets a fresh cell per iteration (the
    // counter itself stays in its raw slot)
    st = box_bound(st, node.name);
    st = gen_discard(st, node.body);
    st = gen_loc_loop(st, node);
    // the counter in place: one instruction, not a load, an inc and a store
    st = emit(st, "    inc " + tostring(voff) + "(%rbp)");
    st = emit(st, "    jmp " + r1.lbl);
    emit(st, r2.lbl + ":")
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
    st = { out: st.out, rodata: st.rodata, uid: st.uid,
      fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots + 3,
      self_label: st.self_label, end_label: st.end_label, fns: st.fns,
      bodies: st.bodies };
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
    st = emit(st, "    mov %rax, " + tostring(aoff) + "(%rbp)");
    st = emit(st, "    xor %eax, %eax");
    st = emit(st, "    mov %rax, " + tostring(ioff) + "(%rbp)");
    st = env_define(st, node.name, "local", voff, "", eltyp);
    let r1 = next_loc(st);
    st = r1.st;
    let r2 = next_loc(st);
    st = r2.st;
    st = emit(st, r1.lbl + ":");
    // i < len(arr) — the heap header keeps the length in slot 0. The length
    // is re-read on every iteration, not hoisted into a fourth slot: a body
    // that appends to the array it walks goes on seeing what it appended
    // (`foreach (x in a) { a += x }` never ends), which hoisting would change.
    st = emit(st, "    mov " + tostring(aoff) + "(%rbp), %rdx");
    st = emit(st, "    mov (%rdx), %rcx");
    st = emit(st, "    mov " + tostring(ioff) + "(%rbp), %rax");
    st = emit(st, "    cmp %rcx, %rax");
    st = emit(st, "    jge " + r2.lbl);
    // x = arr[i]
    st = emit(st, elem_load(arr_elem_bytes(elt), "%rdx", "%rax", "%rcx"));
    st = emit(st, "    mov %rcx, " + tostring(voff) + "(%rbp)");
    st = box_bound(st, node.name);
    st = gen_discard(st, node.body);
    st = gen_loc_loop(st, node);
    // the counter in place: one instruction, not a load, an inc and a store
    st = emit(st, "    inc " + tostring(ioff) + "(%rbp)");
    st = emit(st, "    jmp " + r1.lbl);
    emit(st, r2.lbl + ":")
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
    let i = 0;
    while (i < n) {
        if (i < len(tptypes)) {
            st = gen_as(st, targs[i], tptypes[i]);
        } else {
            st = gen(st, targs[i]);
        };
        let off = (st.slots + 1) * -8;
        st = emit(st, "    mov %rax, " + tostring(off) + "(%rbp)");
        offs += off;
        st = { out: st.out, rodata: st.rodata, uid: st.uid,
          fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots + 1,
          self_label: st.self_label, end_label: st.end_label, fns: st.fns,
          bodies: st.bodies };
        i = i + 1;
    };
    // copy the locals over the parameter slots (param k: 16 + 8*(n-1-k))
    let j = 0;
    while (j < n) {
        let po = 16 + 8 * (n - 1 - j);
        st = emit(st, "    mov " + tostring(offs[j]) + "(%rbp), %rax");
        st = emit(st, "    mov %rax, " + tostring(po) + "(%rbp)");
        j = j + 1;
    };
    // tear down this frame and re-enter the prologue; the return address
    // of the original call stays where it is, so the caller sees a normal
    // return.
    st = emit(st, "    mov %rbp, %rsp");
    st = emit(st, "    pop %rbp");
    emit(st, "    jmp " + st.self_label)
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
                emit(st, "    jmp " + st.end_label)
            }
        } else {
            st = gen_as(st, e, cur_fn_ret(st));
            emit(st, "    jmp " + st.end_label)
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
        let ti = 0;
        while (ti < m - 1) {
            st = gen_loc_stmt(st, tl[ti]);
            st = gen_stmt(st, tl[ti]);
            ti = ti + 1;
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
        if (jcc == "") { st = gen(st, branch.cond); }
        let rl1 = next_loc(st);
        st = rl1.st;
        let lelse = rl1.lbl;
        let rl2 = next_loc(st);
        st = rl2.st;
        let lend = rl2.lbl;
        if (jcc != "") {
            // the flags come from the comparison itself (see int_cmp_jcc)
            let cbin: Bin = branch.cond;
            st = gen_cmp_flags(st, cbin);
            st = emit(st, "    " + jcc + " " + lelse);
        } else {
            st = emit(st, "    test %rax, %rax");
            st = emit(st, "    jz " + lelse);
        };
        st = gen_tail(st, branch.then);
        if (branch.has_else) {
            st = emit(st, "    jmp " + lend);
            st = emit(st, lelse + ":");
            st = gen_loc_elif(st, branch.els);
            st = gen_tail(st, branch.els);
            emit(st, lend + ":")
        } else {
            st = emit(st, lelse + ":")
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
def gen_block_as(st: EmitSt, node: Block, dropped: bool) -> EmitSt {    // No scope push: names are unique post-rename, blocks share the frame.
    let stmts = node.stmts;
    if (len(stmts) == 0) {
        emit(st, "    xor %eax, %eax")
    } else {
        // A trailing `;` (void) computes nothing: nothing to emit.
        let m = len(stmts);
        if (m > 1 && is_void_node(stmts[m - 1])) { m = m - 1; }
        let i = 0;
        while (i < m) {
            st = gen_loc_stmt(st, stmts[i]);
            if (dropped || i < len(stmts) - 1) {
                st = gen_stmt(st, stmts[i]);
            } else {
                st = gen(st, stmts[i]);
            };
            i = i + 1;
        };
        st
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
def loc_dir(ln: long) -> str {
    let f = dbg_file;
    let l = dbg_line;
    let n = len(f);
    if (ln < 1 || n == 0) {
        ".loc 1 " + tostring(ln)
    } else {
        let k = ln;
        if (k > n) { k = n; }
        ".loc " + tostring(f[k - 1] + 1) + " " + tostring(l[k - 1] + ln - k)
    }
};

// A statement's marker, before its code. A bare `;` has no position (and
// no code).
def gen_loc_stmt(st: EmitSt, node: Node) -> EmitSt {
    if (dbg_lines) {
        if (is_void_node(node)) { st } else { emit(st, loc_dir(node.line)) }
    } else {
        st
    }
};

// An `else if` gets a marker of its own: its test would otherwise count
// as the last line of the branch before it.
def gen_loc_elif(st: EmitSt, els: Node) -> EmitSt {
    if (dbg_lines) {
        let k: long = els.k;
        if (k == K.kw_if) { emit(st, loc_dir(els.line)) } else { st }
    } else {
        st
    }
};

// A loop's back edge (its step, the counter's increment, the jump to the
// test) belongs to the loop's own line, not to the body's last one.
def gen_loc_loop(st: EmitSt, node: Node) -> EmitSt {
    if (dbg_lines) { emit(st, loc_dir(node.line)) } else { st }
};

// The `.file N "path"` table the markers number into: one per origin
// file, N = its index + 1.
def file_dirs(files: [str]) -> str {
    let pieces: [str] = [];
    let i = 0;
    while (i < len(files)) {
        let fname: str = files[i];
        pieces += ".file " + tostring(i + 1) + " \"" + esc_asm(fname) + "\"\n";
        i = i + 1;
    };
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
        i = i + 1;
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
    let n = len(s);
    let i = 0;
    while (i < n) {
        h = (h ^ s[i]) * 1099511628211;
        i = i + 1;
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
        sh = sh - 4;
    };
    out
};

// The slot of field `key` in a record of the fields fs: how many of their
// names sort before it (-1 when there is no such field).
def rec_slot(fs: [Field], key: str) -> long {
    let found = false;
    let below = 0;
    let i = 0;
    while (i < len(fs)) {
        let f = fs[i];
        let fname: str = f.name;
        if (fname == key) { found = true; }
        else if (fname < key) { below = below + 1; }

        i = i + 1;
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
    let looking = true;
    while (looking) {
        let cur: str = ty_seen[i];
        if (len(cur) == 0) {
            ty_seen[i] = lbl;
            ty_forms[i] = form;
            ty_count = ty_count + 1;
            looking = false;
        } else if (cur == lbl) {
            let had: str = ty_forms[i];
            if (had == form) { out = 0; } else { out = -1; };
            looking = false;
        } else {
            i = (i + 1) & mask;
        };
    };
    out
};

def tyset_grow() -> long {
    let old = ty_seen;
    let oldf = ty_forms;
    let cap = 2 * len(old);
    if (cap < 64) { cap = 64; };
    let fresh: [str] = [];
    let freshf: [str] = [];
    let i = 0;
    while (i < cap) {
        fresh += "";
        freshf += "";
        i = i + 1;
    };
    ty_seen = fresh;
    ty_forms = freshf;
    ty_count = 0;
    let j = 0;
    while (j < len(old)) {
        let lb: str = old[j];
        if (len(lb) > 0) { tyset_add(lb, oldf[j]); };
        j = j + 1;
    };
    0
};

def tyset_reset() {
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

def ty_sig_init() {
    let nokeys: [str] = [];
    let nolbls: [str] = [];
    let bkts: [[long]] = [];
    let i = 0;
    while (i < 512) {
        let b: [long] = [];
        bkts += b;
        i = i + 1;
    };
    ty_sig_keys = nokeys;
    ty_sig_lbls = nolbls;
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
        i = i + 1;
    };
    found
};

// Two types with one descriptor label: stop (a 64-bit hash collision;
// the program cannot be linked with this compiler).
def ty_collision(lbl: str, form: str) {
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
    let known = "";
    foreach (ix in bkt) {
        if (known == "" && ty_sig_keys[ix] == sig) { known = ty_sig_lbls[ix]; };
    };
    if (known != "") { return { st: st, lbl: known }; };
    let form = ty_form(rt) + lay;
    let lbl = "ytt_" + hex16(fnv64(form));
    ty_sig_keys += sig;
    ty_sig_lbls += lbl;
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
    { st: st, lbl: lbl }
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
        i = i + 1;
    };
    if (found >= 0) { return ush_vals[found]; };
    let ms = types.members(u);
    let out: [str] = [];
    if (len(ms) > 0) {
        let m0: TRec = ms[0];
        let fs: [Field] = m0.fields;
        foreach (f in fs) {
            let ok = true;
            foreach (m in ms) {
                let ft = rec_field_type(m, f.name);
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
    let rec: TRec = m;
    let fs: [Field] = rec.fields;
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
        let rec: TRec = t;
        types.rec_names(rec.fields)
    }
};

def same_lay(a: [str], b: [str]) -> bool {
    let same = len(a) == len(b);
    let i = 0;
    while (same && i < len(a)) {
        if (a[i] != b[i]) { same = false; };
        i = i + 1;
    };
    same
};

// The tag of member m (as written in the union, maybe a tref) held where
// `inu` is declared: its own descriptor where its layout there is its own
// order, else the descriptor of m in that layout.
def ty_desc_in(st: EmitSt, m: Type, inu: Type) -> StLbl {
    let mu = types.unfold(m);
    let lay = lay_of(mu, inu);
    let rec: TRec = mu;
    if (same_lay(lay, types.rec_names(rec.fields))) { ty_desc(st, m) }
    else { ty_desc_as(st, m, "@" + join(lay, ",")) }
};

// The record in %rax (slots `from`) copied into slots `to`, tagged
// `tag`: a new record in %rax.
def gen_copy_rec(st: EmitSt, from: [str], to: [str], tag: str) -> EmitSt {
    st = emit(st, "    push %rax");
    st = emit(st, "    mov $" + tostring(8 * len(to) + 16) + ", %rdi");
    st = emit(st, "    call y_alloc");
    st = emit(st, "    lea " + tag + "(%rip), %rcx");
    st = emit(st, "    mov %rcx, 0(%rax)");
    st = emit(st, "    pop %rsi");
    let i = 0;
    while (i < len(to)) {
        let s = mfield_idx(from, to[i]);
        st = emit(st, "    mov " + tostring(8 * s) + "(%rsi), %rcx");
        st = emit(st, "    mov %rcx, " + tostring(8 + 8 * i) + "(%rax)");
        i = i + 1;
    };
    emit(st, "    add $8, %rax")
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
    if (sk == K.trec && wk == K.tunion) {
        let m = types.union_member(w, s);
        if (m.k == K.tnone) { st } else {
            let from = lay_of(s, src0);
            let to = union_lay(types.unfold(m), w);
            if (same_lay(from, to)) { st } else {
                let dr = ty_desc_in(st, m, w);
                st = dr.st;
                gen_copy_rec(st, from, to, dr.lbl)
            }
        }
    } else if (sk == K.tunion && (wk == K.trec || wk == K.tunion)) {
        let within = union_within(s, want0);
        // one union into another sharing the same fields: every member
        // keeps its layout and tag
        if (within && wk == K.tunion && same_lay(union_shared(s), union_shared(w))) { return st; };
        let ms: [Type] = [];
        if (within) { ms = types.union_parts(s); } else { ms = cast_members(s, want0); };
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
            st = emit(st, "    mov -8(%rax), %rcx");
            let lbls: [str] = [];
            let i = 0;
            while (i < len(ms)) {
                let l = next_loc(st);
                st = l.st;
                lbls += l.lbl;
                let dr = ty_desc_in(st, ms[i], s);
                st = dr.st;
                st = emit(st, "    lea " + dr.lbl + "(%rip), %rdx");
                st = emit(st, "    cmp %rdx, %rcx");
                st = emit(st, "    je " + l.lbl);
                i = i + 1;
            };
            st = emit(st, "    jmp y_cast_trap");
            i = 0;
            while (i < len(ms)) {
                st = emit(st, lbls[i] + ":");
                let from: [str] = froms[i];
                let to: [str] = tos[i];
                if (!same_lay(from, to)) {
                    let dr = ty_desc_in(st, tws[i], w);
                    st = dr.st;
                    st = gen_copy_rec(st, from, to, dr.lbl);
                };
                // not on the last arm: that one falls through into `done:`
                if (i < len(ms) - 1) { st = emit(st, "    jmp " + done.lbl); };
                i = i + 1;
            };
            emit(st, done.lbl + ":")
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
            i = i + 1;
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
    let ni = 0;
    while (ni < nent) {
        let nk = mkeys[ni];
        if (nk == "...") {
            let srec = infer(st, mvals[ni]);
            if (srec.k == K.trec) {
                let spread: TRec = srec;
                let sfs: [Field] = spread.fields;
                let si = 0;
                while (si < len(sfs)) {
                    let sf = sfs[si];
                    if (mfield_idx(names, sf.name) < 0) {
                        names += sf.name;
                    }
                    si = si + 1;
                };
            }
        } else {
            if (mfield_idx(names, nk) < 0) {
                names += nk;
            }
        };
        ni = ni + 1;
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
    st = emit(st, "    mov $" + tostring(8 * n + 16) + ", %rdi");
    st = emit(st, "    call y_alloc");
    st = emit(st, "    push %rax");
    st = emit(st, "    lea " + dr.lbl + "(%rip), %rax");
    st = emit(st, "    pop %rcx");
    st = emit(st, "    mov %rax, 0(%rcx)");
    st = emit(st, "    push %rcx");
    let i = 0;
    while (i < nent) {
        // mv is walked twice (gen, then infer), so bind it once.
        let mv = mvals[i];
        let mk = mkeys[i];
        if (mk == "...") {
            // Spread: the source runs ONCE; copy each of its fields into
            // the slot it has here. A later entry's store overwrites.
            st = gen(st, mv);
            st = emit(st, "    pop %rcx");
            st = emit(st, "    mov %rax, %rdx");
            let srec2 = infer(st, mv);
            if (srec2.k == K.trec) {
                let spread: TRec = srec2;
                let sfs2: [Field] = spread.fields;
                let sj = 0;
                while (sj < len(sfs2)) {
                    let sf2 = sfs2[sj];
                    let mi2 = mfield_idx(slots, sf2.name);
                    // %rdx is the source's record VALUE (slot 0 at +0);
                    // %rcx is the fresh record's ALLOC base (slots at +8).
                    st = emit(st, "    mov " + tostring(8 * rec_slot(sfs2, sf2.name)) + "(%rdx), %rsi");
                    st = emit(st, "    mov %rsi, " + tostring(8 + mi2 * 8) + "(%rcx)");
                    sj = sj + 1;
                };
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
            st = emit(st, "    pop %rcx");
            let mi = mfield_idx(slots, mk);
            st = emit(st, "    mov %rax, " + tostring(8 + mi * 8) + "(%rcx)");
        };
        st = emit(st, "    push %rcx");
        i = i + 1;
    };
    st = emit(st, "    pop %rax");
    emit(st, "    add $8, %rax")
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
    let ci = 0;
    while (ci < len(caps)) {
        let cn: str = caps[ci];
        let ce = env_find(st, cn);
        captypes += ce.typ;
        ci = ci + 1;
    };
    let rl = next_uid(st);
    st = rl.st;
    let lbl = arch.arch_fn_label(rl.uid, "anon");
    let ru = next_uid(st);
    st = ru.st;
    st = emit_one_fn(st, lbl, ru.uid, node, false, false, captypes, "");
    let bci = 0;
    while (bci < len(caps)) {
        let bcn: str = caps[bci];
        st = box_capture(st, bcn);
        bci = bci + 1;
    };
    gen_make_closure(st, lbl, caps)
};

// Bind `name` to a closure over `func`: emit the body HERE (the enclosing
// env still knows each captured name's type — emit_program deliberately
// skips capturing functions), build the record, store it in a fresh slot.
// Such a function (see capturing_defs) is not in the hoisted table, so it
// gets its label here; its body knows its own name (emit_one_fn).
def gen_closure_binding(st: EmitSt, name: str, func: Func, caps: [str]) -> EmitSt {
    let captypes: [Type] = [];
    let ci = 0;
    while (ci < len(caps)) {
        let cn2: str = caps[ci];
        let ce = env_find(st, cn2);
        captypes += ce.typ;
        ci = ci + 1;
    };
    let rl = next_uid(st);
    st = rl.st;
    let lbl = fn_label_of(rl.uid, name);
    let ru = next_uid(st);
    st = ru.st;
    st = emit_one_fn(st, lbl, ru.uid, func, false, false, captypes, name);
    let bci = 0;
    while (bci < len(caps)) {
        let bcn: str = caps[bci];
        st = box_capture(st, bcn);
        bci = bci + 1;
    };
    st = gen_make_closure(st, lbl, caps);
    let coff = (st.slots + 1) * -8;
    st = emit(st, "    mov %rax, " + tostring(coff) + "(%rbp)");
    let st3 = { out: st.out, rodata: st.rodata, uid: st.uid,
      fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots + 1,
      self_label: st.self_label, end_label: st.end_label, fns: st.fns,
      bodies: st.bodies };
    st3 = env_define(st3, name, "closure", coff, "", func_type_in(st3, func));
    box_bound(st3, name)
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
            bind_decl(st, node.name, t)
        } else if (node.v.k == K.rec) {
            let rec: RecLit = node.v;
            // record literal: heap address (first-class value, plain slot).
            // An empty literal under a map annotation is the map itself
            // (the {keys, vals, boxes} shape the map ops expect).
            if (node.typ.k == K.tmap && len(rec.keys) == 0) {
                st = gen_maplit(st, rec)
            } else {
                // created as the declared type (gen_as, gen_reclit)
                st = gen_as(st, rec, node.typ)
            };
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
        st = emit(st, "    mov %rax, " + ge.label + "(%rip)");
        env_define(st, name, "global", 0, ge.label, t)
    } else if (t.k == K.tstr && own_wanted(st, name)) {
        bind_own(st, name, t)
    } else {
        let off = (st.slots + 1) * -8;
        st = emit(st, "    mov %rax, " + tostring(off) + "(%rbp)");
        let st2 = { out: st.out, rodata: st.rodata, uid: st.uid,
          fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots + 1,
          self_label: st.self_label, end_label: st.end_label, fns: st.fns,
          bodies: st.bodies };
        st2 = env_define(st2, name, "local", off, "", t);
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
        let idx = tonum(e.label);
        st = emit(st, "    mov " + tostring(e.off) + "(%rbp), %rcx");
        st = emit(st, "    mov " + tostring(8 * (idx + 1)) + "(%rcx), %rdx");
        st = emit(st, "    mov %rax, (%rdx)");
        st
    } else if (e.kind == "box") {
        st = emit(st, "    mov " + tostring(e.off) + "(%rbp), %rdx");
        st = emit(st, "    mov %rax, (%rdx)");
        st
    } else if (e.kind == "global") {
        emit(st, "    mov %rax, " + e.label + "(%rip)")
    } else {
        emit(st, "    mov %rax, " + tostring(e.off) + "(%rbp)")
    }
};

// Fill n frame slots (base = lowest address) with the value in %rax.
def gen_fill(st: EmitSt, base: long, n: long) -> EmitSt {
    if (n == 0) {
        st
    } else {
        let r = next_loc(st);
        st = r.st;
        st = emit(st, "    mov $" + tostring(n) + ", %rcx");
        st = emit(st, r.lbl + ":");
        st = emit(st, "    dec %rcx");
        st = emit(st, "    mov %rax, " + tostring(base) + "(%rbp,%rcx,8)");
        emit(st, "    jnz " + r.lbl)
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
        st = emit(st, "    mov %rdx, %r10");
        st = emit(st, "    mov %rax, %rdx");
        st = emit(st, "    mov $" + tostring(n) + ", %rcx");
        st = emit(st, r.lbl + ":");
        st = emit(st, "    dec %rcx");
        st = emit(st, elem_store_rdx(esz, "%r10", "%rcx"));
        st = emit(st, "    jnz " + r.lbl);
        st = emit(st, "    mov %r10, %rdx");
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
    st = emit(st, "    push %rax");
    st = emit(st, "    mov $" + tostring(arr_alloc_size(esz, n)) + ", %rdi");
    st = emit(st, "    call y_alloc");
    st = emit(st, "    push %rax");
    st = emit(st, "    mov $" + tostring(arr_header_size()) + ", %rdi");
    st = emit(st, "    call y_alloc");
    st = emit(st, "    pop %rdx");
    st = emit(st, "    mov $" + tostring(n) + ", (%rax)");
    st = emit(st, "    mov $" + tostring(n) + ", 8(%rax)");
    st = emit(st, "    mov %rdx, 16(%rax)");
    st = emit(st, "    mov %rax, %rdx");
    st = emit(st, "    pop %rax");
    st = gen_fill_heap(st, n, esz);
    emit(st, "    mov %rdx, %rax")
};

// Radix literals (0x../0b..) reach the emitter as their source text; the
// assembler only understands plain decimal immediates, so normalize here.
def hexval_ch(c: str) -> long {
    let o = ord(c);
    let v = 0;
    if (o >= c'0') {
        if (o <= c'9') { v = o - c'0'; }
    }
    if (o >= c'a') {
        if (o <= c'f') { v = o - c'a' + 10; }
    }
    if (o >= c'A') {
        if (o <= c'F') { v = o - c'A' + 10; }
    }
    v
};

// A numeric literal denotes a float when it has a fraction or an exponent.
// Radix literals are checked first: 0xE1 and 0xbeef contain 'e'/'E'/'b'.
def lit_is_float(s: str) -> bool {
    let radix = false;
    if (len(s) > 2) {
        let p = s[:2];
        if (p == "0x") { radix = true; }
        if (p == "0X") { radix = true; }
        if (p == "0b") { radix = true; }
        if (p == "0B") { radix = true; }
    }
    if (radix) { false } else {
        let f = false;
        if (index_of(s, ".") >= 0) { f = true; }
        if (index_of(s, "e") >= 0) { f = true; }
        if (index_of(s, "E") >= 0) { f = true; }
        f
    }
};

def norm_num(s: str) -> str {
    let radix = 0;
    if (len(s) > 2) {
        let p = s[:2];
        if (p == "0x") { radix = 16; }
        if (p == "0X") { radix = 16; }
        if (p == "0b") { radix = 2; }
        if (p == "0B") { radix = 2; }
    }
    if (radix == 0) {
        s
    } else {
        let v = 0;
        let i = 2;
        while (i < len(s)) {
            let c = s[i:i + 1];
            if (c == "_") { } else {
                v = v * radix + hexval_ch(c);
            };
            i = i + 1;
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
    let i = 0;
    while (i < n) {
        let p = a[i] * m + carry;
        a[i] = p % FLIT_BASE;
        carry = p / FLIT_BASE;
        i = i + 1;
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
    let i = 0;
    while (i < n) {
        let v = a[i];
        a[i] = carry;
        carry = v;
        i = i + 1;
    };
    carry == 0
};

// acc /= 10^9: the lowest limb drops out whole. What was in it is below the
// significand, so the caller looks at it for sticky first.
def flit_ddiv_limb(a: [long], n: long) {
    let i = 0;
    while (i < n - 1) {
        a[i] = a[i + 1];
        i = i + 1;
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
        i = i + 1;
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
    let i = 0;
    while (i < n) {
        if (i < len(a)) { out += a[i]; } else { out += 0; };
        i = i + 1;
    };
    out
};

// The digits of d as n limbs (d fits a long).
def flit_dfrom(d: long, n: long) -> [long] {
    let a: [long] = [];
    let rest = d;
    let i = 0;
    while (i < n) {
        a += rest % FLIT_BASE;
        rest = rest / FLIT_BASE;
        i = i + 1;
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
        if (flit_dmul(a, 4294967296, n)) { j = j + 1; } else { flags[1] = true; j = t / 32; };
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
    let est = (ndig + dp) * 33219 / 10000;
    let t = 62 - est + 4;
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
            down = down + 32;
        };
        // And then a bit at a time down to 2^54: what that leaves is the 53
        // significand bits AND the round bit above them, and everything it
        // dropped is below the round bit, so sticky is all that carries.
        while (!flit_dlt(a, p54, n)) {
            if (flit_ddiv(a, 2, n) != 0) { flags[0] = true; };
            down = down + 1;
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
            if (n > 1) { mant = mant + a[1] * FLIT_BASE; };
        };
        if (round != 0) {
            if (flags[0]) { mant = mant + 1; }
            else {
                if ((mant & 1) != 0) { mant = mant + 1; };
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
                mant = mant >> 1;
                e2 = e + 1;
            };
            if (e2 > 1023) {
                bits = 0x7FF0000000000000;      // past the largest double: inf
            } else {
                bits = ((e2 + 1023) << 52) | (mant & 0xFFFFFFFFFFFFF);
            };
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
            if (past_dot) { nfrac = nfrac + 1; };
            if (seen || c != "0") {
                seen = true;
                ndig = ndig + 1;
            };
        };
        i = i + 1;
    };
    let n0 = flit_size(ndig, 0, 0);
    let over = n0 > FLIT_LIMBS;
    if (over) { n0 = FLIT_LIMBS; };
    let a: [long] = [];
    i = 0;
    while (i < n0) { a += 0; i = i + 1; };
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
                if (!flit_dpush(a, byte_at(c, 0) - 48, n0)) { over = true; };
            };
        };
        i = i + 1;
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
                    ex = ex * 10 + (byte_at(s[j:j + 1], 0) - 48);
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
// as the runtime's tonum (rt.y, which is where an out-of-range literal becomes
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
    let i = 0;
    while (i < len(s)) {
        let c = ord(s[i:i + 1]);
        if (c >= c'0' && c <= c'9') {
            v = v * 10 + c - c'0';
        } else {
            if (c == c'-' && i == 0) { neg = true; };
        };
        i = i + 1;
    };
    if (neg) { 0 - v } else { v }
};

def gen_lit(st: EmitSt, node: Leaf) -> EmitSt {
    if (lit_is_float(node.v)) {
        // Float literal: its IEEE-754 bits, decided above. Floats live in %rax
        // as raw bits; only arithmetic and comparison use %xmm.
        emit(st, "    mov $" + tostring(flit_bits(node.v)) + ", %rax")
    } else {
        // An integer literal is emitted as its VALUE, not its text: a literal
        // wider than 64 bits runs as its low 64 bits (which is what the
        // compiler has always done -- the checker accepts it and the runtime's
        // tonum wraps), and `mov $18446744073709551616` is not an instruction
        // GNU as can read, so a -S listing of such a program did not assemble
        // at all. norm_num has already turned hex and binary into decimal, so
        // an in-range literal emits exactly the text it did before.
        emit(st, "    mov $" + tostring(num_i64(norm_num(node.v))) + ", %rax")
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
    st = emit(st, "    push %rax");
    st = gen(st, node.idx);
    st = emit(st, "    mov %rax, %rcx");
    st = emit(st, "    pop %rax");
    st = emit(st, "    test %rcx, %rcx");
    st = emit(st, "    js y_oob");
    if (bt.k == K.tarrfix) {
        let fixed: TFix = bt;
        st = emit(st, "    cmp $" + tostring(fixed.n) + ", %rcx");
        st = emit(st, "    jge y_oob");
        emit(st, elem_load(ixesz, "%rax", "%rcx", "%rax"))
    } else {
        st = emit(st, "    mov (%rax), %rdx");
        st = emit(st, "    cmp %rdx, %rcx");
        st = emit(st, "    jge y_oob");
        emit(st, elem_load(ixesz, "%rax", "%rcx", "%rax"))
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
    st = emit(st, "    push %rax");
    st = gen_as(st, node.v, rec_field_type(dt, dkey));
    st = emit(st, "    pop %rdx");
    if (dt.k == K.tunion) {
        gen_union_slot(st, dt, dkey, true)
    } else {
        emit(st, "    mov %rax, " + tostring(8 * idx) + "(%rdx)")
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
            let n = tonum(norm_num(num.v));
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
    let slot = 0;
    if (dropped) { slot = inplace_slot(st, node.tgt); };
    if (slot != 0) {
        let mn = "inc";
        if (node.op == "--") { mn = "dec"; };
        emit(st, "    " + mn + " " + tostring(slot) + "(%rbp)")
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
        let d2: Decl = { k: K.decl, kind: "let", typ: place_value_type(infer(st, tgt)), name: t1 + "v", v: nv, line: ln, col: cl };
        let asg: Node = gen_place_assign(tgt, n_id(t1 + "v", ln, cl), t1, ln, cl);
        gen_incdec_end(st, bind, d2, asg, dropped, ln, cl)
    } else {
        // x++ -> { bind; let v = x; x = v + 1; v }
        let d2: Decl = { k: K.decl, kind: "let", typ: normtype({ k: K.tnone }), name: t1 + "v", v: place, line: ln, col: cl };
        let nv: Bin = { k: K.bin, op: binop, l: n_id(t1 + "v", ln, cl), r: one, line: ln, col: cl };
        let asg: Node = gen_place_assign(tgt, nv, t1, ln, cl);
        gen_incdec_end(st, bind, d2, asg, dropped, ln, cl)
    }
};

// `{ bind; let v = ...; target = v; v }` -- both `++x` and `x++`, whose value
// is the trailing read of the temporary. As a statement that read is dead.
def gen_incdec_end(st: EmitSt, bind: Node, d2: Node, asg: Node, dropped: bool, ln: long, cl: long) -> EmitSt {
    if (dropped) {
        gen_discard(st, block4(bind, d2, asg, n_id_of(d2, ln, cl), ln, cl))
    } else {
        gen(st, block4(bind, d2, asg, n_id_of(d2, ln, cl), ln, cl))
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
    if (dropped) {
        gen_discard(st, block3(bind, asg, read, ln, cl))
    } else {
        gen(st, block3(bind, asg, read, ln, cl))
    }
};

def gen_opassign(st: EmitSt, node: OpAssign, dropped: bool) -> EmitSt {
    let t = infer(st, node.tgt);
    if (t.k == K.tarr || t.k == K.tarrfix) {
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
    let mn = "";
    let slot = 0;
    let imm = 0;
    let has_imm = false;
    if (dropped) {
        slot = inplace_slot(st, node.tgt);
        if (slot != 0) {
            let op = node.op;
            if (op == "+") { mn = "add"; }
            else if (op == "-") { mn = "sub"; }
            else if (op == "*") { mn = "imul"; }
            else if (op == "|") { mn = "or"; }
            else if (op == "&") { mn = "and"; }
            else if (op == "^") { mn = "xor"; };
            if (mn != "") {
                let im = int_imm(node.v);
                if (im.ok) {
                    has_imm = true;
                    imm = im.v;
                };
            };
        };
    };
    if (mn == "") {
        gen_opassign_desugar(st, node, dropped)
    } else if (has_imm) {
        emit(st, "    " + mn + " $" + tostring(imm) + ", " + tostring(slot) + "(%rbp)")
    } else {
        st = emit(st, "    mov " + tostring(slot) + "(%rbp), %rax");
        st = emit(st, "    push %rax");
        st = gen(st, node.v);
        st = emit(st, "    mov %rax, %rcx");
        st = emit(st, "    pop %rax");
        st = emit(st, "    " + mn + " %rcx, %rax");
        emit(st, "    mov %rax, " + tostring(slot) + "(%rbp)")
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
    let d2: Decl = { k: K.decl, kind: "let", typ: place_value_type(infer(st, tgt)), name: t1 + "v", v: bin, line: ln, col: cl };
    let asg: Node = gen_place_assign(tgt, n_id(t1 + "v", ln, cl), t1, ln, cl);
    if (dropped) {
        gen_discard(st, block4(bind, d2, asg, n_id(t1 + "v", ln, cl), ln, cl))
    } else {
        gen(st, block4(bind, d2, asg, n_id(t1 + "v", ln, cl), ln, cl))
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
    { k: K.dot, obj: n_id(t1, ln, cl), key: tgt.key, line: ln, col: cl }
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
    { k: K.dotassign, obj: n_id(t1, ln, cl), key: tgt.key, v: valnode, line: ln, col: cl }
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
    { k: K.decl, kind: "let", typ: normtype({ k: K.tnone }), name: t1, v: tgt.idx, line: ln, col: cl }
};

def place_bind_idx_nest(tgt: Index, t1: str, ln: long, cl: long) -> Block {
    // nested base (`grid[0][1]`, `x.y[i]`, `f()[i]`): capture it in
    // `t1 + "a"` as well, so the place evaluates it exactly once.
    let tba: Decl = { k: K.decl, kind: "let", typ: normtype({ k: K.tnone }), name: t1 + "a", v: tgt.arr, line: ln, col: cl };
    let tib: Decl = { k: K.decl, kind: "let", typ: normtype({ k: K.tnone }), name: t1, v: tgt.idx, line: ln, col: cl };
    block2(tba, tib, ln, cl)
};

def place_bind_idx(tgt: Index, t1: str, ln: long, cl: long) -> Node {
    let ba = tgt.arr;
    if (ba.k == K.id) {
        let node: Node = place_bind_idx_id(tgt, t1, ln, cl);
        node
    } else {
        let node: Node = place_bind_idx_nest(tgt, t1, ln, cl);
        node
    }
};

def place_bind_dot(tgt: Dot, t1: str, ln: long, cl: long) -> Decl {
    { k: K.decl, kind: "let", typ: normtype({ k: K.tnone }), name: t1, v: tgt.obj, line: ln, col: cl }
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
        let all = n_call2("push$all", gen_place_read(tgt, t1, ln, cl), v, ln, cl);
        gen_opassign_end(st, gen_place_bind(tgt, t1, ln, cl), gen_place_assign(tgt, all, t1, ln, cl), gen_place_read(tgt, t1, ln, cl), dropped, ln, cl)
    } else if (mode == "append") {
        // { let tv = v; let ti = 0; let tn = len(tv);
        //   while (ti < tn) { place += tv[ti]; ti = ti + 1 }
        //   place }
        let tv: Decl = { k: K.decl, kind: "let", typ: normtype({ k: K.tnone }), name: t1 + "v", v: v, line: ln, col: cl };
        let ti: Decl = { k: K.decl, kind: "let", typ: normtype({ k: K.tnone }), name: t1 + "i", v: n_num("0", ln, cl), line: ln, col: cl };
        let tn: Decl = { k: K.decl, kind: "let", typ: normtype({ k: K.tnone }), name: t1 + "n", v: n_call1("len", n_id(t1 + "v", ln, cl), ln, cl), line: ln, col: cl };
        let elem: Index = { k: K.index, arr: n_id(t1 + "v", ln, cl), idx: n_id(t1 + "i", ln, cl), line: ln, col: cl };
        let put: Node = gen_place_assign(tgt, n_call2("push", gen_place_read(tgt, t1, ln, cl), elem, ln, cl), t1, ln, cl);
        let step: Assign = { k: K.assign, name: t1 + "i", v: { k: K.bin, op: "+", l: n_id(t1 + "i", ln, cl), r: n_num("1", ln, cl), line: ln, col: cl }, line: ln, col: cl };
        let loop: While = { k: K.kw_while, cond: { k: K.bin, op: "<", l: n_id(t1 + "i", ln, cl), r: n_id(t1 + "n", ln, cl), line: ln, col: cl }, body: block2(put, step, ln, cl), line: ln, col: cl };
        if (dropped) {
            gen_discard(st, block6(gen_place_bind(tgt, t1, ln, cl), tv, ti, tn, loop, gen_place_read(tgt, t1, ln, cl), ln, cl))
        } else {
            gen(st, block6(gen_place_bind(tgt, t1, ln, cl), tv, ti, tn, loop, gen_place_read(tgt, t1, ln, cl), ln, cl))
        }
    } else {
        let fname = "push";
        if (mode == "prepend") { fname = "prepend"; }
        let call = n_call2(fname, gen_place_read(tgt, t1, ln, cl), v, ln, cl);
        gen_opassign_end(st, gen_place_bind(tgt, t1, ln, cl), gen_place_assign(tgt, call, t1, ln, cl), gen_place_read(tgt, t1, ln, cl), dropped, ln, cl)
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
    st = emit(st, "    push %rax");
    st = gen(st, node.idx);
    st = emit(st, "    push %rax");
    st = gen_as(st, node.v, store_elem_type(bt, iaesz));
    st = emit(st, "    pop %rcx");
    st = emit(st, "    pop %rdx");
    st = emit(st, "    test %rcx, %rcx");
    st = emit(st, "    js y_oob");
    if (bt.k == K.tarrfix) {
        let fixed: TFix = bt;
        st = emit(st, "    cmp $" + tostring(fixed.n) + ", %rcx");
        st = emit(st, "    jge y_oob");
        st = emit(st, "    mov %rdx, %r10");
        st = emit(st, "    mov %rax, %rdx");
        st = emit(st, elem_store_rdx(iaesz, "%r10", "%rcx"));
        st = emit(st, "    mov %r10, %rdx");
    } else {
        st = emit(st, "    push %rax");
        st = emit(st, "    mov (%rdx), %rax");
        st = emit(st, "    cmp %rax, %rcx");
        st = emit(st, "    jge y_oob");
        st = emit(st, "    pop %rax");
        st = emit(st, "    mov %rdx, %r10");
        st = emit(st, "    mov %rax, %rdx");
        st = emit(st, elem_store_rdx(iaesz, "%r10", "%rcx"));
        st = emit(st, "    mov %r10, %rdx");
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
        i = i + 1;
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
    } else if (tk == K.tbool) {
        st = emit(st, "    push %rax");
        st = emit(st, "    call y_bool_tostr");
        emit(st, "    add $8, %rsp")
    } else if (tk == K.tfloat) {
        st = emit(st, "    push %rax");
        st = emit(st, "    call y_float_tostr");
        emit(st, "    add $8, %rsp")
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
        st = emit(st, "    push %rax");
        st = emit(st, "    call y_long_tostr");
        emit(st, "    add $8, %rsp")
    }
};

// acc = acc + <the string in %rax>.
def gen_acc_cat_rax(st: EmitSt, aoff: long) -> EmitSt {
    st = emit(st, "    mov %rax, %rdx");
    st = emit(st, "    mov " + tostring(aoff) + "(%rbp), %rax");
    st = emit(st, "    push %rax");
    st = emit(st, "    push %rdx");
    st = emit(st, "    call y_str_cat");
    st = emit(st, "    add $16, %rsp");
    emit(st, "    mov %rax, " + tostring(aoff) + "(%rbp)")
};

// The record address of a map sits in %rax; leave '{"k": v, ...}' -- the same
// text tostring() gives it (gen_map_repr builds that loop from nodes; this one
// walks the value in hand). A map is the {boxes, keys, vals} record
// (gen_maplit), so its two arrays sit at 8 and 16. This arm is what
// gen_val_tostr_rax was missing: with the long-to-string fallback there
// instead, a map nested in an array, an option or a record printed as its heap
// address, which differs every run.
def gen_map_repr_rax(st: EmitSt, t: Type, path: [Type]) -> EmitSt {
    let moff = (st.slots + 1) * -8;
    let aoff = (st.slots + 2) * -8;
    let ioff = (st.slots + 3) * -8;
    let koff = (st.slots + 4) * -8;
    st = { out: st.out, rodata: st.rodata, uid: st.uid,
      fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots + 4,
      self_label: st.self_label, end_label: st.end_label, fns: st.fns,
      bodies: st.bodies };
    st = emit(st, "    mov %rax, " + tostring(moff) + "(%rbp)");
    st = gen_str_const(st, "{");
    st = emit(st, "    mov %rax, " + tostring(aoff) + "(%rbp)");
    st = emit(st, "    xor %eax, %eax");
    st = emit(st, "    mov %rax, " + tostring(ioff) + "(%rbp)");
    let r1 = next_loc(st);
    st = r1.st;
    let r2 = next_loc(st);
    st = r2.st;
    let r3 = next_loc(st);
    st = r3.st;
    let map: TMap = t;
    st = emit(st, r1.lbl + ":");
    st = emit(st, "    mov " + tostring(moff) + "(%rbp), %rdx");
    st = emit(st, "    mov 8(%rdx), %rdx");
    st = emit(st, "    mov (%rdx), %rcx");
    st = emit(st, "    mov " + tostring(ioff) + "(%rbp), %rax");
    st = emit(st, "    cmp %rcx, %rax");
    st = emit(st, "    jge " + r2.lbl);
    st = emit(st, "    test %rax, %rax");
    st = emit(st, "    jz " + r3.lbl);
    st = gen_acc_cat_slot(st, aoff, ", ");
    st = emit(st, r3.lbl + ":");
    // the key, quoted when it is a str (map_key_repr's rule)
    st = emit(st, "    mov " + tostring(moff) + "(%rbp), %rdx");
    st = emit(st, "    mov 8(%rdx), %rdx");
    st = emit(st, "    mov " + tostring(ioff) + "(%rbp), %rcx");
    st = emit(st, elem_load(elem_bytes(map.key), "%rdx", "%rcx", "%rax"));
    if (map.key.k == K.tstr) {
        // The key goes to a slot first: appending the opening quote is a call
        // that leaves its result in %rax, so a key still living there would be
        // appended twice over instead.
        st = emit(st, "    mov %rax, " + tostring(koff) + "(%rbp)");
        st = gen_acc_cat_slot(st, aoff, "\"");
        st = emit(st, "    mov " + tostring(koff) + "(%rbp), %rax");
        st = gen_acc_cat_rax(st, aoff);
        st = gen_acc_cat_slot(st, aoff, "\"");
    } else {
        st = gen_val_tostr_rax(st, map.key, path + t);
        st = gen_acc_cat_rax(st, aoff);
    };
    st = gen_acc_cat_slot(st, aoff, ": ");
    // the value
    st = emit(st, "    mov " + tostring(moff) + "(%rbp), %rdx");
    st = emit(st, "    mov 16(%rdx), %rdx");
    st = emit(st, "    mov " + tostring(ioff) + "(%rbp), %rcx");
    st = emit(st, elem_load(elem_bytes(map.of), "%rdx", "%rcx", "%rax"));
    st = gen_val_tostr_rax(st, map.of, path + t);
    st = gen_acc_cat_rax(st, aoff);
    // the counter in place: one instruction, not a load, an inc and a store
    st = emit(st, "    inc " + tostring(ioff) + "(%rbp)");
    st = emit(st, "    jmp " + r1.lbl);
    st = emit(st, r2.lbl + ":");
    st = gen_acc_cat_slot(st, aoff, "}");
    emit(st, "    mov " + tostring(aoff) + "(%rbp), %rax")
};

// Array header in %rax -> "[e0, e1, ...]" in %rax, the same form tostring()
// gives. Slots: [src][acc][i].
def gen_arr_tostr_rax(st: EmitSt, elty: Type, path: [Type]) -> EmitSt {
    let soff = (st.slots + 1) * -8;
    let aoff = (st.slots + 2) * -8;
    let ioff = (st.slots + 3) * -8;
    st = { out: st.out, rodata: st.rodata, uid: st.uid,
      fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots + 3,
      self_label: st.self_label, end_label: st.end_label, fns: st.fns,
      bodies: st.bodies };
    st = emit(st, "    mov %rax, " + tostring(soff) + "(%rbp)");
    st = gen_str_const(st, "[");
    st = emit(st, "    mov %rax, " + tostring(aoff) + "(%rbp)");
    st = emit(st, "    xor %eax, %eax");
    st = emit(st, "    mov %rax, " + tostring(ioff) + "(%rbp)");
    let r1 = next_loc(st);
    st = r1.st;
    let r2 = next_loc(st);
    st = r2.st;
    let r3 = next_loc(st);
    st = r3.st;
    st = emit(st, r1.lbl + ":");
    st = emit(st, "    mov " + tostring(soff) + "(%rbp), %rdx");
    st = emit(st, "    mov (%rdx), %rcx");
    st = emit(st, "    mov " + tostring(ioff) + "(%rbp), %rax");
    st = emit(st, "    cmp %rcx, %rax");
    st = emit(st, "    jge " + r2.lbl);
    st = emit(st, "    test %rax, %rax");
    st = emit(st, "    jz " + r3.lbl);
    st = gen_acc_cat_slot(st, aoff, ", ");
    st = emit(st, r3.lbl + ":");
    st = emit(st, "    mov " + tostring(soff) + "(%rbp), %rdx");
    st = emit(st, "    mov " + tostring(ioff) + "(%rbp), %rcx");
    st = emit(st, elem_load(elem_bytes(elty), "%rdx", "%rcx", "%rax"));
    st = gen_val_tostr_rax(st, elty, path);
    st = emit(st, "    mov %rax, %rdx");
    st = emit(st, "    mov " + tostring(aoff) + "(%rbp), %rax");
    st = emit(st, "    push %rax");
    st = emit(st, "    push %rdx");
    st = emit(st, "    call y_str_cat");
    st = emit(st, "    add $16, %rsp");
    st = emit(st, "    mov %rax, " + tostring(aoff) + "(%rbp)");
    // the counter in place: one instruction, not a load, an inc and a store
    st = emit(st, "    inc " + tostring(ioff) + "(%rbp)");
    st = emit(st, "    jmp " + r1.lbl);
    st = emit(st, r2.lbl + ":");
    st = gen_acc_cat_slot(st, aoff, "]");
    emit(st, "    mov " + tostring(aoff) + "(%rbp), %rax")
};

// slot(%rbp) = slot(%rbp) + <constant>.
def gen_acc_cat_slot(st: EmitSt, off: long, s: str) -> EmitSt {
    st = emit(st, "    mov " + tostring(off) + "(%rbp), %rax");
    st = emit(st, "    push %rax");
    st = gen_str_const(st, s);
    st = emit(st, "    push %rax");
    st = emit(st, "    call y_str_cat");
    st = emit(st, "    add $16, %rsp");
    emit(st, "    mov %rax, " + tostring(off) + "(%rbp)")
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
// the index register, `dst` the result. Headers are {len, cap, data} with
// the elements in a separate block, so the data pointer rides through %dst.
def elem_load(esz: long, base: str, idx: str, dst: str) -> str {
    if (esz == 1) {
        "    mov 16(" + base + "), " + dst + "\n"
            + "    movzbq (" + dst + "," + idx + ",1), " + dst
    } else {
        "    mov 16(" + base + "), " + dst + "\n"
            + "    mov (" + dst + "," + idx + ",8), " + dst
    }
};

// Store %rdx into element [idx] of the array based at `base`. The value
// always arrives in %rdx so the byte form can name %dl without a register
// table; a packed store truncates to 8 bits, which is the narrowing.
// %r11 is the scratch that carries the data pointer: no generated value
// lives in it across a store (the syscall instruction clobbers it).
def elem_store_rdx(esz: long, base: str, idx: str) -> str {
    if (esz == 1) {
        "    mov 16(" + base + "), %r11\n    movb %dl, (%r11," + idx + ",1)"
    } else {
        "    mov 16(" + base + "), %r11\n    mov %rdx, (%r11," + idx + ",8)"
    }
};

// Same, for a compile-time-constant index (array literals): fold the
// offset into the displacement instead of using an index register.
def elem_store_rdx_const(esz: long, base: str, k: long) -> str {
    if (esz == 1) {
        "    mov 16(" + base + "), %r11\n    movb %dl, " + tostring(k) + "(%r11)"
    } else {
        "    mov 16(" + base + "), %r11\n    mov %rdx, " + tostring(k * 8) + "(%r11)"
    }
};

// The array header is {len, cap, data, front} and NEVER moves: elements
// live in a separate block, so growth keeps every alias valid (that is
// what makes `arr += v` in-place). front, the free slots before data, is
// the header's fourth word: y_alloc(arr_header_size()) hands out 32
// zeroed bytes (NATIVE.md). This is the block size for n elements.
def arr_alloc_size(esz: long, n: long) -> long {
    let b = n * esz;
    if (b < 8) { 8 } else { b }
};

// Bytes to allocate for the header itself.
def arr_header_size() -> long {
    24
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
        emit(st, "    xor %eax, %eax")
    } else if (len(ds) == 1) {
        gen_slot_move(st, ds[0], false)
    } else {
        let done = next_loc(st);
        st = done.st;
        st = emit(st, "    mov -8(%rax), %rcx");
        let lbls: [str] = [];
        let d = 0;
        while (d < len(ds) - 1) {
            let l = next_loc(st);
            st = l.st;
            lbls += l.lbl;
            let j = 0;
            while (j < len(ms)) {
                if (slots[j] == ds[d]) {
                    let dr = ty_desc_in(st, ms[j], s);
                    st = dr.st;
                    st = emit(st, "    lea " + dr.lbl + "(%rip), %rsi");
                    st = emit(st, "    cmp %rsi, %rcx");
                    st = emit(st, "    je " + l.lbl);
                };
                j = j + 1;
            };
            d = d + 1;
        };
        st = gen_slot_move(st, ds[len(ds) - 1], false);
        st = emit(st, "    jmp " + done.lbl);
        let e = 0;
        while (e < len(lbls)) {
            st = emit(st, lbls[e] + ":");
            st = gen_slot_move(st, ds[e], false);
            // not on the last arm: that one falls through into `done:`
            if (e < len(lbls) - 1) { st = emit(st, "    jmp " + done.lbl); };
            e = e + 1;
        };
        emit(st, done.lbl + ":")
    }
};

// gen_union_slot's move: slot sl of the record in %rax into %rax, or
// (store) %rax into slot sl of the record in %rdx.
def gen_slot_move(st: EmitSt, sl: long, store: bool) -> EmitSt {
    if (store) {
        emit(st, "    mov %rax, " + tostring(8 * sl) + "(%rdx)")
    } else {
        emit(st, "    mov " + tostring(8 * sl) + "(%rax), %rax")
    }
};

// Built-in properties (types.y typeof_prop): `.length` is len(x); `.ptr`
// is the array header's data word — the element block's address.
def gen_prop(st: EmitSt, obj: Node, key: str, line: long, col: long) -> EmitSt {
    if (key == "length") {
        gen_len(st, n_call1("len", obj, line, col))
    } else {
        st = gen(st, obj);
        emit(st, "    mov 16(%rax), %rax")
    }
};

// Record field read; `t` is the record's static type.
def gen_dot_rec(st: EmitSt, dobj: Node, dkey: str, t: Type) -> EmitSt {
    let idx = rec_field_idx(t, dkey);
    st = gen(st, dobj);
    emit(st, "    mov " + tostring(idx * 8) + "(%rax), %rax")
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
        let i = 0;
        while (i < len(fs)) {
            let f = fs[i];
            if (f.name == key) {
                ft = f.typ;
            }
            i = i + 1;
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
    let gi = 0;
    while (gi < len(elems)) {
        st = gen_as(st, elems[gi], ety);
        st = emit(st, "    push %rax");
        gi = gi + 1;
    };
    let n = len(elems);
    st = emit(st, "    mov $" + tostring(arr_alloc_size(esz, n)) + ", %rdi");
    st = emit(st, "    call y_alloc");
    st = emit(st, "    push %rax");
    st = emit(st, "    mov $" + tostring(arr_header_size()) + ", %rdi");
    st = emit(st, "    call y_alloc");
    st = emit(st, "    mov %rax, %r10");
    st = emit(st, "    pop %rdx");
    st = emit(st, "    mov $" + tostring(n) + ", (%r10)");
    st = emit(st, "    mov $" + tostring(n) + ", 8(%r10)");
    st = emit(st, "    mov %rdx, 16(%r10)");
    let k = n - 1;
    while (k >= 0) {
        st = emit(st, "    pop %rdx");
        st = emit(st, elem_store_rdx_const(esz, "%r10", k));
        k = k - 1;
    };
    emit(st, "    mov %r10, %rax")
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
        emit(st, "    mov (%rax), %rax")
    } else {
        st = gen(st, args[0]);
        emit(st, "    mov (%rax), %rax")
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
    st = emit(st, "    mov $" + tostring(pesz) + ", %rax");
    st = emit(st, "    push %rax");
    st = emit(st, "    call y_arr_push");
    let nbytes = len(node.args) * 8 + 8;
    emit(st, "    add $" + tostring(nbytes) + ", %rsp")
};

// `arr += other` with one element type (gen_opassign_arr makes the call,
// a name no program can write): y_arr_extend appends other's elements in
// bulk.
def gen_push_all(st: EmitSt, node: Call) -> EmitSt {
    let pargs: [Node] = node.args;
    let pesz = arr_elem_bytes(infer(st, pargs[0]));
    st = gen_push_args_as(st, node.args, []);
    st = emit(st, "    mov $" + tostring(pesz) + ", %rax");
    st = emit(st, "    push %rax");
    st = emit(st, "    call y_arr_extend");
    emit(st, "    add $24, %rsp")
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
    st = emit(st, "    push %rax");
    st = emit(st, "    mov $8, %rdi");
    st = emit(st, "    call y_alloc");
    st = emit(st, "    pop %rcx");
    emit(st, "    mov %rcx, (%rax)")
};

def gen_is_some(st: EmitSt, node: Call) -> EmitSt {
    let args: [Node] = node.args;
    if (is_map_read(st, args[0])) {
        // is_some(m[k]): the key scan decides, nothing is boxed
        gen_map_get(st, args[0], "has")
    } else {
        st = gen(st, args[0]);
        st = emit(st, "    test %rax, %rax");
        st = emit(st, "    setne %al");
        emit(st, "    movzbq %al, %rax")
    }
};

def gen_unwrap(st: EmitSt, node: Call) -> EmitSt {
    let args: [Node] = node.args;
    if (is_map_read(st, args[0])) {
        // m[k]!: the entry's value itself, nothing is boxed
        gen_map_get(st, args[0], "val")
    } else {
        st = gen(st, args[0]);
        st = emit(st, "    test %rax, %rax");
        st = emit(st, "    jz y_opt_unwrap");
        emit(st, "    mov (%rax), %rax")
    }
};

// ── string builtins (all on {len, data} header objects) ────────────────
// Every helper takes header addresses via the Y calling convention
// (args pushed left-to-right, first arg deepest) and returns a header
// address (or long) in %rax. Caller cleans the stack.

def gen_trim(st: EmitSt, node: Call) -> EmitSt {
    st = gen_push_args(st, node.args);
    st = emit(st, "    call y_str_trim");
    emit(st, "    add $8, %rsp")
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
    st = emit(st, "    mov $" + tostring(pesz) + ", %rax");
    st = emit(st, "    push %rax");
    st = emit(st, "    call y_arr_prepend");
    let nbytes = len(node.args) * 8 + 8;
    emit(st, "    add $" + tostring(nbytes) + ", %rsp")
};

// byte_at(s, i): byte i of string s, trapped when out of bounds. This is
// the primitive every string helper is built on — reading one byte must
// not copy the string the way bytes() does. Inline, four instructions,
// because scanning loops call it per character.
def gen_byte_at(st: EmitSt, node: Call) -> EmitSt {
    let args: [Node] = node.args;
    st = gen(st, args[0]);
    st = emit(st, "    push %rax");
    st = gen(st, args[1]);
    st = emit(st, "    pop %rcx");
    st = emit(st, "    mov (%rcx), %rdx");
    st = emit(st, "    test %rax, %rax");
    st = emit(st, "    js y_oob");
    st = emit(st, "    cmp %rdx, %rax");
    st = emit(st, "    jge y_oob");
    emit(st, "    movzbq 8(%rcx,%rax,1), %rax")
};

def gen_ord(st: EmitSt, node: Call) -> EmitSt {
    st = gen_push_args(st, node.args);
    st = emit(st, "    call y_str_ord");
    emit(st, "    add $8, %rsp")
};

def gen_chr(st: EmitSt, node: Call) -> EmitSt {
    st = gen_push_args(st, node.args);
    st = emit(st, "    call y_str_chr");
    emit(st, "    add $8, %rsp")
};

def gen_tonum(st: EmitSt, node: Call) -> EmitSt {
    st = gen_push_args(st, node.args);
    st = emit(st, "    call y_str_tonum");
    emit(st, "    add $8, %rsp")
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
        st = emit(st, "    call y_bool_tostr");
        emit(st, "    add $8, %rsp")
    } else if (t.k == K.tfloat) {
        st = gen_push_args(st, node.args);
        st = emit(st, "    call y_float_tostr");
        emit(st, "    add $8, %rsp")
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
    } else {
        st = gen_push_args(st, node.args);
        st = emit(st, "    call y_long_tostr");
        emit(st, "    add $8, %rsp")
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
    let spec: str = if (sp == none) { "" } else { sp!.v };
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
        if (ty == c's') {
            st = gen_tostring(st, ts);
            st = emit(st, "    push %rax");
            st = fmt_push(st, code);
            st = fmt_push(st, f.width);
            st = fmt_push(st, f.prec);
            st = emit(st, "    call y_fmt_s");
            emit(st, "    add $32, %rsp")
        } else if (ty == c'd' || ty == c'x' || ty == c'X' || ty == c'o' || ty == c'b' || ty == c'c') {
            st = gen(st, a0);
            st = emit(st, "    push %rax");
            st = fmt_push(st, code);
            st = fmt_push(st, f.width);
            st = emit(st, "    call y_fmt_i");
            emit(st, "    add $24, %rsp")
        } else {
            st = gen(st, a0);
            if (kind == 1) {
                st = emit(st, "    cvtsi2sd %rax, %xmm0");
                st = emit(st, "    movq %xmm0, %rax");
            }
            if (ty == c'%') {
                st = emit(st, "    movq %rax, %xmm0");
                st = emit(st, "    mov $100, %rax");
                st = emit(st, "    cvtsi2sd %rax, %xmm1");
                st = emit(st, "    mulsd %xmm1, %xmm0");
                st = emit(st, "    movq %xmm0, %rax");
            }
            let prec = f.prec;
            if (prec < 0) { prec = 6; }
            st = emit(st, "    push %rax");
            st = fmt_push(st, code);
            st = fmt_push(st, f.width);
            st = fmt_push(st, prec);
            st = emit(st, "    call y_fmt_f");
            emit(st, "    add $32, %rsp")
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
        if (kind != 0) { align = 62; } else { align = 60; };
    }
    let sg = 0;
    if (f.sign == c'+') { sg = 1; } else if (f.sign == c' ') { sg = 2; }
    if (f.alt) { sg = sg + 4; }
    if (f.grp == c',') { sg = sg + 8; } else if (f.grp == c'_') { sg = sg + 16; }
    ty + 256 * fill + 65536 * align + 16777216 * sg
};

// Push the number v (an argument of a helper call).
def fmt_push(st: EmitSt, v: long) -> EmitSt {
    st = emit(st, "    mov $" + tostring(v) + ", %rax");
    emit(st, "    push %rax")
};

def gen_index_of(st: EmitSt, node: Call, last: bool) -> EmitSt {
    st = gen_push_args(st, node.args);
    if (last) {
        st = emit(st, "    call y_str_lastidx");
        emit(st, "    add $16, %rsp")
    } else {
        st = emit(st, "    call y_str_index");
        emit(st, "    add $16, %rsp")
    }
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
        st = emit(st, "    call y_str_join");
        emit(st, "    add $16, %rsp")
    }
};

// Slots: [src][dst][i]. Builds dst = [tostr(src[0]), ...] then joins it.
def gen_join_conv(st: EmitSt, node: Call, tostr_fn: str, esz: long) -> EmitSt {
    let soff = (st.slots + 1) * -8;
    let doff = (st.slots + 2) * -8;
    let ioff = (st.slots + 3) * -8;
    st = { out: st.out, rodata: st.rodata, uid: st.uid,
      fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots + 3,
      self_label: st.self_label, end_label: st.end_label, fns: st.fns,
      bodies: st.bodies };
    let jargs: [Node] = node.args;
    st = gen(st, jargs[0]);
    st = emit(st, "    mov %rax, " + tostring(soff) + "(%rbp)");
    st = emit(st, "    mov (%rax), %rdi");
    st = emit(st, "    shl $3, %rdi");
    st = emit(st, "    call y_alloc");
    st = emit(st, "    push %rax");
    st = emit(st, "    mov $24, %rdi");
    st = emit(st, "    call y_alloc");
    st = emit(st, "    pop %rdx");
    st = emit(st, "    mov %rax, " + tostring(doff) + "(%rbp)");
    st = emit(st, "    mov " + tostring(soff) + "(%rbp), %rcx");
    st = emit(st, "    mov (%rcx), %rcx");
    st = emit(st, "    mov %rcx, (%rax)");
    st = emit(st, "    mov %rcx, 8(%rax)");
    st = emit(st, "    mov %rdx, 16(%rax)");
    st = emit(st, "    xor %eax, %eax");
    st = emit(st, "    mov %rax, " + tostring(ioff) + "(%rbp)");
    let r1 = next_loc(st);
    st = r1.st;
    let r2 = next_loc(st);
    st = r2.st;
    st = emit(st, r1.lbl + ":");
    st = emit(st, "    mov " + tostring(soff) + "(%rbp), %rdx");
    st = emit(st, "    mov (%rdx), %rcx");
    st = emit(st, "    mov " + tostring(ioff) + "(%rbp), %rax");
    st = emit(st, "    cmp %rcx, %rax");
    st = emit(st, "    jge " + r2.lbl);
    st = emit(st, elem_load(esz, "%rdx", "%rax", "%rcx"));
    st = emit(st, "    push %rcx");
    st = emit(st, "    call " + tostr_fn);
    st = emit(st, "    add $8, %rsp");
    st = emit(st, "    mov " + tostring(ioff) + "(%rbp), %rcx");
    st = emit(st, "    mov " + tostring(doff) + "(%rbp), %rdx");
    st = emit(st, "    mov 16(%rdx), %rdx");
    st = emit(st, "    mov %rax, (%rdx,%rcx,8)");
    st = emit(st, "    inc %rcx");
    st = emit(st, "    mov %rcx, " + tostring(ioff) + "(%rbp)");
    st = emit(st, "    jmp " + r1.lbl);
    st = emit(st, r2.lbl + ":");
    st = emit(st, "    mov " + tostring(doff) + "(%rbp), %rax");
    st = emit(st, "    push %rax");
    st = gen(st, jargs[1]);
    st = emit(st, "    push %rax");
    st = emit(st, "    call y_str_join");
    emit(st, "    add $16, %rsp")
};

def gen_split(st: EmitSt, node: Call) -> EmitSt {
    st = gen_push_args(st, node.args);
    st = emit(st, "    call y_str_split");
    emit(st, "    add $16, %rsp")
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
        emit(st, "    xor %eax, %eax")
    } else if (t.k == K.tstr) {
        st = gen_helper1(st, "y_put_hstr");
        emit(st, "    xor %eax, %eax")
    } else {
        st = gen_helper1(st, "y_put_long");
        emit(st, "    xor %eax, %eax")
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
        emit(st, "    xor %eax, %eax")
    } else if (t.k == K.tstr) {
        st = gen_helper1(st, "y_eput_hstr");
        emit(st, "    xor %eax, %eax")
    } else {
        st = gen_helper1(st, "y_eput_long");
        emit(st, "    xor %eax, %eax")
    }
};

def gen_clock_us(st: EmitSt, node: Call) -> EmitSt {
    // clock_us() -> long (monotonic microseconds, via clock_gettime).
    emit(st, "    call y_clock_us")
};

def gen_heap_used(st: EmitSt, node: Call) -> EmitSt {
    // heap_used() -> long (bytes the allocator has handed out so far).
    emit(st, "    call y_heap_used")
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
    st = emit(st, "    push %rax");
    st = gen(st, largs[1]);
    st = emit(st, "    push %rax");
    if (!attempt) {
        st = emit(st, "    mov 8(%rsp), %rax");
        st = emit(st, "    call y_mutex_lock");
        st = gen_call_top(st);
        st = emit(st, "    push %rax");
        st = emit(st, "    mov 16(%rsp), %rax");
        st = emit(st, "    call y_mutex_unlock");
        st = emit(st, "    pop %rax");
        emit(st, "    add $16, %rsp")
    } else {
        let skip = next_loc(st);
        st = skip.st;
        let done = next_loc(st);
        st = done.st;
        st = emit(st, "    mov 8(%rsp), %rax");
        st = emit(st, "    call y_mutex_trylock");
        st = emit(st, "    test %rax, %rax");
        st = emit(st, "    je " + skip.lbl);
        st = gen_call_top(st);
        st = emit(st, "    mov 8(%rsp), %rax");
        st = emit(st, "    call y_mutex_unlock");
        st = emit(st, "    mov $1, %rax");
        st = emit(st, "    jmp " + done.lbl);
        st = emit(st, skip.lbl + ":");
        st = emit(st, "    xor %eax, %eax");
        st = emit(st, done.lbl + ":");
        emit(st, "    add $16, %rsp")
    }
};

// Call the closure on top of the stack with no arguments (it stays there).
def gen_call_top(st: EmitSt) -> EmitSt {
    st = emit(st, "    mov 0(%rsp), %rax");
    st = emit(st, "    push %rax");
    st = emit(st, "    mov 0(%rax), %rax");
    st = emit(st, "    call *%rax");
    emit(st, "    add $8, %rsp")
};

def gen_sleep(st: EmitSt, node: Call) -> EmitSt {
    // sleep(ms): suspend the caller for ms milliseconds (nanosleep, EINTR
    // cannot happen in single-threaded code, so one syscall is enough).
    let sargs: [Node] = node.args;
    let sa = sargs[0];
    st = gen(st, sa);
    gen_helper1(st, "y_sleep")
};


def gen_exit(st: EmitSt, node: Call) -> EmitSt {
    // exit(code): terminate the process with the exit-code syscall.
    let eargs: [Node] = node.args;
    let ea = eargs[0];
    st = gen(st, ea);
    st = emit(st, "    mov %rax, %rdi");
    st = emit(st, "    mov $231, %rax");
    st = emit(st, "    syscall");
    // exit() terminates the process; the epilogue (ret / exit(0)) is
    // unreachable. Emit a jump to the function end so the backend never
    // falls through into dead code (and exit codes are never masked).
    emit(st, "    jmp " + st.end_label)
};

// ── process I/O (argv) ──────────────────────────────────────────────
// argv MAY only appear as `main(argv())`'s argument feed: ycc.y's entry is
// `let result = main(argv())`. The _start prologue (below) builds the argv
// array and stashes it in r15; gen_argv emits the call that materializes it.
// (Files are std/fs.y: `import fs;`.)

def gen_argv(st: EmitSt, node: Call) -> EmitSt {
    emit(st, "    call y_argv")
};

def gen_store(st: EmitSt, node: Store) -> EmitSt {
    let spt = infer(st, node.p);
    let sw = ptr_width(spt);
    let sto: Type = type_node({ k: K.tnone });
    if (sw == 8 && spt.k == K.tptr) { let ptr: TPtr = spt; sto = ptr.to; }
    st = gen(st, node.p);
    st = emit(st, "    push %rax");
    st = gen_as(st, node.v, sto);
    st = emit(st, "    pop %rcx");
    if (sw == 1) { emit(st, "    movb %al, (%rcx)") } else { emit(st, "    mov %rax, (%rcx)") }
};

// ── functions ──────────────────────────────────────────────────────────
// Frame: locals at rbp-8, rbp-16, ...; params at rbp+16, rbp+24, ....
// Every emitted function gets: prologue, body, end_label, epilogue.

def emit_one_fn(st: EmitSt, label: str, fuid: long, func: EmitFunc, is_main: bool, want_argv: bool, captypes: [Type], selfname: str) -> EmitSt {
    // fresh per-function state; uid/rodata/fns flow through and back.
    // Bodies see every hoisted function and global through st.fns
    // (env_find), like the checker's fresh_func_scope.
    let f: EmitSt = { out: [], rodata: st.rodata, uid: st.uid,
      fuid: fuid, loc: 1, env: [], slots: 0,
      self_label: label, end_label: arch.arch_loc_label(fuid, 0),
      fns: st.fns, bodies: st.bodies };
    // The names nested functions capture (see box_names / box_bound).
    f = env_define(f, "", "frame", 0, "", type_node({ k: K.tnone }));
    // This function's type, for the conversions at its returns and its
    // self calls (cur_fn_type).
    let ftype: Type = type_node({ k: K.tfunc, args: func.ptypes, ret: fn_ret(func) });
    f = env_define(f, "", "fnty", 0, "", ftype);
    let bnames = box_names(func);
    let bi = 0;
    while (bi < len(bnames)) {
        let bnm: str = bnames[bi];
        f = env_define(f, "", "boxmark", 0, bnm, type_node({ k: K.tnone }));
        bi = bi + 1;
    };
    // The names this body appends to (see own_wanted), the same way.
    let anames = app_names(func.body, false, bnames);
    let ai = 0;
    while (ai < len(anames)) {
        let anm: str = anames[ai];
        f = env_define(f, "", "appmark", 0, anm, type_node({ k: K.tnone }));
        ai = ai + 1;
    };
    // A capturing named function is not in that table (see
    // capturing_defs): bind its own name to this body, so a call by name
    // passes the record along (gen_direct) and a value is the record.
    if (selfname != "") {
        let func_node: Func = func;
        f = env_define(f, selfname, "func", 0, label, func_type_in(st, func_node));
    }
    // bind params. Caller pushes args left-to-right, so the LAST arg sits
    // at rbp+16 and param k lives at rbp+16+8*(n-1-k) (arity-dependent).
    let params: [str] = func.params;
    let ptypes: [Type] = func.ptypes;
    let nargs = len(params);
    let i = 0;
    while (i < nargs) {
        f = env_define(f, params[i], "param", 16 + (nargs - 1 - i) * 8, "", ptypes[i]);
        i = i + 1;
    };
    // Captures: the caller pushed the closure record BEFORE the args, so it
    // lives just past them at rbp+16+8*nargs. Each capture reads slot idx+1
    // of that record (slot 0 is the code pointer). A capture-free function
    // binds nothing here and never touches the slot, which is what lets one
    // body serve both direct and closure calls. `_start` has no enclosing
    // frame, so it never captures.
    if (is_main) { } else {
        let mycaps = fn_captures(func, st.fns.ix, selfname);
        let cloff = 16 + nargs * 8;
        let c = 0;
        while (c < len(mycaps)) {
            let cn: str = mycaps[c];
            // Capture types come from the creation site (the enclosing env
            // knows them); without one the emitter would pick long for a
            // captured string in print/puts and in `+`.
            let ct: Type = type_node({ k: K.tnone });
            if (c < len(captypes)) {
                ct = captypes[c];
            }
            f = env_define(f, cn, "capture", cloff, tostring(c), ct);
            c = c + 1;
        };
    };
    // Captured parameters (and the own name) move into their cells
    // before the body; a tail call re-enters above this, so every
    // recycled frame gets fresh cells.
    if (selfname != "") {
        f = box_bound(f, selfname);
    }
    let pbi = 0;
    while (pbi < nargs) {
        let pbn: str = params[pbi];
        f = box_bound(f, pbn);
        pbi = pbi + 1;
    };
    // An appended-to str parameter moves into an own pair (bind_own).
    let opi = 0;
    while (opi < nargs) {
        let opn: str = params[opi];
        let opt = ptypes[opi];
        if (opt.k == K.tstr && own_wanted(f, opn)) {
            let ope = env_find(f, opn);
            f = emit(f, "    mov " + tostring(ope.off) + "(%rbp), %rax");
            f = bind_own(f, opn, opt);
        }
        opi = opi + 1;
    };
    f = gen_tail(f, func.body);
    let frame = arch.arch_frame(f.slots);
    let code: [str] = [];
    code += label + ":";
    // -g: the prologue is the def's line; `_start` has none (line 0)
    if (dbg_lines) {
        if (is_main) { code += loc_dir(0); } else { code += loc_dir(func.line); };
    }
    if (is_main) {
        if (want_argv) {
            // _start prologue: at process entry %rsp -> [argc][argv0ptr]....
            // argv (char**) is the ADDRESS rsp+8 (lea, not a load!); argc is
            // [rsp]. y_argv_init copies every arg into a header string and
            // stashes the [str] array in r15 for y_argv. Skipped entirely
            // when the program never calls argv() (saves ~14s of startup:
            // y_cstr_to_str walks every byte of every arg).
            // NOTE: no bare (%rsp)/(%r12) — the encoder rejects rsp/r12 bases.
            code += "    mov %rsp, %rax";
            code += "    mov (%rax), %r15";
            code += "    mov %rax, %r14";
            code += "    add $8, %r14";
            code += "    push %r14";
            code += "    push %r15";
            code += "    call y_argv_init";
            code += "    add $16, %rsp";
        }
    }
    code += "    push %rbp";
    code += "    mov %rsp, %rbp";
    if (frame > 0) {
        code += "    sub $" + tostring(frame) + ", %rsp";
    }
    let fout: [str] = f.out;
    let j = 0;
    while (j < len(fout)) {
        code += fout[j];
        j = j + 1;
    };
    code += f.end_label + ":";
    if (is_main) {
        code += "    mov $231, %rax";
        code += "    xor %edi, %edi";
        code += "    syscall";
    } else {
        code += "    mov %rbp, %rsp";
        code += "    pop %rbp";
        code += "    ret";
    };
    // NOTE: append to f.bodies, NOT st.bodies. Emitting this body can add
    // bodies of its own (a nested capturing def is emitted at its creation
    // site), and those land in f.bodies. Using st.bodies dropped them
    // whenever push had to GROW the array: the C copy's value model shares
    // the grown buffer between the two record copies, the native backend
    // rebinds only f.bodies (see NATIVE.md "rebind: a = push(a, v)"), so the
    // two compilers disagreed and ycc emitted calls to labels it never
    // defined.
    f.bodies += join(code, "\n");
    let bodies = f.bodies;
    { out: st.out, rodata: f.rodata, uid: f.uid,
      fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots,
      self_label: st.self_label, end_label: st.end_label, fns: st.fns,
      bodies: bodies }
};

// Build a tfunc type from a func node (params have annotations — checked).
// Return type of a function whose `-> T` was omitted and which the checker
// could not type either (types.y records every other inferred return type
// in the node: set_inferred_ret): the type of its body's tail, inferred in
// a scope holding every known def plus the params. The emitter needs one,
// because a call's result type decides e.g. whether `+` must stringify.
def infer_fn_ret(st: EmitSt, func: Func) -> Type {
    let f: EmitSt = { out: [], rodata: st.rodata, uid: st.uid,
      fuid: 0, loc: 1, env: [], slots: 0,
      self_label: "", end_label: "", fns: st.fns, bodies: st.bodies };
    let params: [str] = func.params;
    let ptypes: [Type] = func.ptypes;
    let n = len(params);
    let i = 0;
    while (i < n) {
        f = env_define(f, params[i], "param", 16 + (n - 1 - i) * 8, "", ptypes[i]);
        i = i + 1;
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
    let i = 0;
    while (i < len(stmts)) {
        let s: Node = stmts[i];
        let nm = top_name_in(s, origin);
        if (len(nm) > 0) {
            let ln: long = s.line;
            names += nm;
            fids += origin_file(origin, ln);
            lines += ln;
            cols += s.col;
        }
        i = i + 1;
    };
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
    let j = 0;
    while (j < len(names)) {
        let nj = names[j];
        let fj = fids[j];
        let slot = -1;
        let g = asm.labmap_get(ix, nj);
        if (g.sec >= 0) { slot = g.sec; };
        if (slot < 0) {
            top += -1;
            slot = len(top) - 1;
            let r = asm.labmap_put(ix, nj, slot, 0);
            ix = r.map;
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
        j = j + 1;
    };
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
    let i = 0;
    while (i < len(stmts)) {
        let s: Node = stmts[i];
        if (s.k == K.decl) {
            let decl: Decl = s;
            if (decl.kind == "def") { }
            else if (decl.v.k == K.func) { }
            else { out += decl; };
        }
        i = i + 1;
    };
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
    let f: EmitSt = { out: [], rodata: st.rodata, uid: st.uid,
      fuid: 0, loc: 1, env: [], slots: 0,
      self_label: "", end_label: "", fns: st.fns, bodies: st.bodies };
    let out: [Sym] = [];
    let i = 0;
    while (i < len(gdecls)) {
        let d: Decl = gdecls[i];
        let gn = decl_name(d);
        let t: Type = decl_type(d);
        if (t.k == K.tnone) {
            t = infer(f, decl_value(d));
        }
        let lbl = arch.arch_global_label(gbase + i, gn);
        out += { name: gn, label: lbl, typ: t };
        f = env_define(f, gn, "global", 0, lbl, t);
        i = i + 1;
    };
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
        let d = defs[i];
        fnames += d.name;
        i = i + 1;
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
            if (namemap_get(fnm, cn) >= 0) { } else { reads_var = true; };
            j = j + 1;
        };
        if (reads_var) { out += d.name; }
        i = i + 1;
    };
    let changed = true;
    while (changed) {
        changed = false;
        i = 0;
        while (i < len(defs)) {
            let d = defs[i];
            if (name_in(out, d.name)) { } else {
                let cs = caps[i];
                let j = 0;
                let hit = false;
                while (j < len(cs)) {
                    let cn: str = cs[j];
                    if (name_in(out, cn)) { hit = true; }
                    j = j + 1;
                };
                if (hit) {
                    out += d.name;
                    changed = true;
                }
            };
            i = i + 1;
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
    let fx = 0;
    while (fx < len(hdefs)) {
        let d = hdefs[fx];
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
        fx = fx + 1;
    };
    out
};

def ret_omitted(func: Func) -> bool {
    let r = fn_ret(func);
    r.k == K.tnone
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
        i = i + 1;
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
type Unit = { name: str, files: [str], exports: [Sym], init: str, bodies: [str], labels: [str], refs: [[str]], rodata: [[str]], globals: [str], dfl: [DflCode] };
// What compile_unit binds besides the unit's own names: the externs
// (`ext`) and their parameter defaults (`dfl`, as rename.y takes them),
// the package namespaces the unit imports (`pkgs`, see pkg_ns), the
// init labels `_start` calls first (`inits`), and whether a linked unit
// reads argv() (`argv`: `_start` must materialize it then).
type Externs = { ext: [Sym], dfl: [Dfl], pkgs: [str], inits: [str], argv: bool };

def unit_empty(name: str) -> Unit {
    let fs: [str] = [];
    let xs: [Sym] = [];
    let bs: [str] = [];
    let ls: [str] = [];
    let fr: [[str]] = [];
    let rs: [[str]] = [];
    let gs: [str] = [];
    let ds: [DflCode] = [];
    { name: name, files: fs, exports: xs, init: "", bodies: bs, labels: ls, refs: fr, rodata: rs, globals: gs, dfl: ds }
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
        let i = 0;
        while (i < len(names)) {
            let nm: str = names[i];
            let ext: [Sym] = [];
            if (nm == "exec") {
                let j = 0;
                while (j < len(out)) {
                    let u = out[j];
                    if (u.name == "prelude") { ext += u.exports; }
                    j = j + 1;
                };
            }
            out += std_compile(nm, ext);
            i = i + 1;
        };
    }
    out
};

// One std unit, from its embedded source. It always carries its `.loc`
// markers (link_units strips them unless -g), so it compiles the same
// for every program. A failure here is the compiler's own bug: reported
// as one, and the run ends.
def std_compile(name: str, ext: [Sym]) -> Unit {
    let path = "std/" + name + ".y";
    let toks = lexer.tokenize(std_text(std_unit_src(name)));
    let ast = parser.parse_program(toks);
    let noimports: [str] = [];
    let nolines: [long] = [];
    let xt = externs_none();
    xt.ext = ext;
    let r = compile_unit(ast, noimports, { files: [path], nuser: 1, file: nolines, line: nolines, mods: [""] }, true, 0, name, std_unit_base(name), xt);
    if (!r.ok) {
        let errs = r.errors;
        let k = 0;
        while (k < len(errs)) {
            let e = errs[k];
            puts("ycc: internal error: " + path + ":" + tostring(e.line) + ":" + tostring(e.col) + ": " + e.msg + "\n");
            k = k + 1;
        };
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
    let i = 0;
    while (i < len(stmts)) {
        let nm = top_def_name(stmts[i]);
        if (len(nm) > 0) {
            let h0 = h;
            let found = false;
            while (!found && h < len(hdefs)) {
                let hd = hdefs[h];
                if (hd.name == nm) { found = true; } else { h = h + 1; };
            };
            if (found) {
                let xn = export_name(nm);
                if (len(xn) > 0) {
                    let fe = fns[h];
                    out += { name: xn, label: fe.label, typ: fe.typ };
                }
                h = h + 1;
            } else {
                h = h0;
            };
        }
        i = i + 1;
    };
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
def compile_unit(ast: Block, imports: [str], origin: Origin, debug: bool, wlevel: long, name: str, base: long, xt: Externs) -> UnitRes {
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
            warnings = lint.lint_unit(ast, ast3, origin.file, origin.mods, wlevel);
            pr = phase_end(times, "lint", pt, ph);
            times = pr.times; pt = pr.t; ph = pr.h;
        };
        let gdecls = global_decls(ast3.stmts);
        let gnames: [str] = [];
        let gi = 0;
        while (gi < len(gdecls)) {
            let gdecl: Decl = gdecls[gi];
            gnames += decl_name(gdecl);
            gi = gi + 1;
        };
        // The externs, and the init functions `_start` calls (by their
        // labels: no Y name has that shape, and the checker never sees
        // these).
        let xfns: [Sym] = [];
        xfns += ext;
        let ii = 0;
        while (ii < len(inits)) {
            let il: str = inits[ii];
            xfns += { name: il, label: il, typ: { k: K.tfunc, args: [], ret: { k: K.tvoid } } };
            ii = ii + 1;
        };
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
        st = { out: st.out, rodata: st.rodata, uid: base + 1,
          fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots,
          self_label: st.self_label, end_label: st.end_label, fns: st.fns,
          bodies: st.bodies };
        let r = next_uid(st);
        st = r.st;
        let hsyms: [Sym] = [];
        let i = 0;
        while (i < len(defs)) {
            let d = defs[i];
            if (name_in(capdefs, d.name)) { } else {
                hdefs += d;
                let rl = next_uid(st);
                st = rl.st;
                // A native def's label is the one it named -- the assembly it
                // calls into. Everything else gets a generated label.
                let label = "";
                if (len(d.func.label) > 0) { label = d.func.label; } else { label = fn_label_of(rl.uid, d.name); };
                hsyms += { name: d.name, label: label, typ: func_type(d.func) };
                st = env_define(st, d.name, "func", 0, label, func_type(d.func));
            };
            i = i + 1;
        };
        // The externs go after the hoisted defs (fix_fn_types and the
        // emission loop read those by position), the globals after both
        // (see fns_kind).
        let fns0: [Sym] = [];
        fns0 += hsyms;
        fns0 += xfns;
        st = { out: st.out, rodata: st.rodata, uid: st.uid,
          fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots,
          self_label: st.self_label, end_label: st.end_label, fns: fntab_of(fns0),
          bodies: st.bodies };
        // Fill in the return type of every unannotated def, so call sites
        // know what a call yields; then type the globals with those, and
        // redo the defs that read a global (they now know its type).
        let fixed1 = fix_fn_types(st, hdefs, []);
        let fns1: [Sym] = [];
        fns1 += fixed1;
        fns1 += xfns;
        st = { out: st.out, rodata: st.rodata, uid: st.uid,
          fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots,
          self_label: st.self_label, end_label: st.end_label, fns: fntab_of(fns1),
          bodies: st.bodies };
        let gl = app_cells(global_entries(st, gdecls, base), ast3.stmts);
        let fixedfns: [Sym] = [];
        fixedfns += fixed1;
        fixedfns += xfns;
        fixedfns += gl;
        if (len(gl) > 0) {
            st = { out: st.out, rodata: st.rodata, uid: st.uid,
              fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots,
              self_label: st.self_label, end_label: st.end_label, fns: fntab_of(fixedfns),
              bodies: st.bodies };
            let fixed2 = fix_fn_types(st, hdefs, gnames);
            fixedfns = [];
            fixedfns += fixed2;
            fixedfns += xfns;
            fixedfns += gl;
        }
        st = { out: st.out, rodata: st.rodata, uid: st.uid,
          fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots,
          self_label: st.self_label, end_label: st.end_label, fns: fntab_of(fixedfns),
          bodies: st.bodies };
        // emit each hoisted body. A native def has none: its label names
        // assembly that is already in the output, so emitting anything under
        // that label would duplicate it.
        i = 0;
        while (i < len(hdefs)) {
            let d = hdefs[i];
            let fns = st.fns.syms;
            let f = fns[i];
            if (len(d.func.label) == 0) {
                let rf = next_uid(st);
                st = rf.st;
                st = emit_one_fn(st, f.label, rf.uid, d.func, false, false, [], "");
            };
            i = i + 1;
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
        let ci = 0;
        while (ci < len(inits)) {
            let cl: str = inits[ci];
            let call: Call = { k: K.call, callee: { k: K.id, v: cl, line: 0, col: 0 }, args: noargs, line: 0, col: 0 };
            main_stmts += call;
            ci = ci + 1;
        };
        let pstmts: [Node] = ast3.stmts;
        let i = 0;
        while (i < len(pstmts)) {
            let s: Node = pstmts[i];
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
            i = i + 1;
        };
        let rm = next_uid(st);
        st = rm.st;
        let init = "";
        if (len(name) == 0) {
            // Only pay for argv materialization when the program uses it
            // (or a package it links does).
            let want = uses_scan_block(ast3.stmts, { argv: false });
            let main_body: Block = { k: K.block, stmts: main_stmts, line: 0, col: 0 };
            let start_fn: EmitMain = { params: [], ptypes: [], ret: type_node({ k: K.tvoid }), body: main_body, line: 0, col: 0 };
            st = emit_one_fn(st, "_start", rm.uid, start_fn, true, want.argv || xt.argv, [], "");
        } else if (len(main_stmts) > 0) {
            init = arch.arch_fn_label(rm.uid, "init");
            let init_body: Block = { k: K.block, stmts: main_stmts, line: 0, col: 0 };
            let init_fn: EmitMain = { params: [], ptypes: [], ret: type_node({ k: K.tvoid }), body: init_body, line: 0, col: 0 };
            st = emit_one_fn(st, init, rm.uid, init_fn, false, false, [], "");
        }
        pr = phase_end(times, "emit_start", pt, ph);
        times = pr.times; pt = pr.t; ph = pr.h;
        let glabels: [str] = [];
        let gk = 0;
        while (gk < len(gl)) {
            let ge = gl[gk];
            glabels += ge.label;
            gk = gk + 1;
        };
        // Each body's label and the labels it references: what linking
        // shakes by (prune_bodies), worked out once here.
        let ubodies = st.bodies;
        let blabels: [str] = [];
        let brefs: [[str]] = [];
        let bk = 0;
        while (bk < len(ubodies)) {
            let ub: str = ubodies[bk];
            blabels += body_label(ub);
            brefs += [text_refs(ub, true)];
            bk = bk + 1;
        };
        let unit = { name: name, files: origin.files, exports: exports, init: init,
          bodies: ubodies, labels: blabels, refs: brefs, rodata: st.rodata,
          globals: glabels, dfl: udfl };
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
    let i = 0;
    while (i < len(gl)) {
        let ge = gl[i];
        let gn: str = ge.name;
        let xn = "";
        if (gn[len(gn) - 2:] == "#o") {
            let bn = export_name(gn[:len(gn) - 2]);
            if (len(bn) > 0) { xn = bn + "#o"; }
        } else {
            xn = export_name(gn);
        };
        if (len(xn) > 0) { all += { name: xn, label: ge.label, typ: ge.typ }; }
        i = i + 1;
    };
    let out: [Sym] = [];
    let j = 0;
    while (j < len(all)) {
        let e = all[j];
        let later = false;
        let m = j + 1;
        while (!later && m < len(all)) {
            let e2 = all[m];
            if (e2.name == e.name) { later = true; }
            m = m + 1;
        };
        if (!later) { out += e; }
        j = j + 1;
    };
    out
};

// The parameter defaults of a unit's top-level defs, by the names they
// were written with (see Unit): a later def of a name replaces an
// earlier one's.
def unit_dfl(stmts: [Node], origin: Origin) -> [DflCode] {
    let out: [DflCode] = [];
    let i = 0;
    while (i < len(stmts)) {
        let s: Node = stmts[i];
        let nm = top_name_in(s, origin);
        // (not an imported module's: see export_name)
        if (len(nm) > 0 && index_of(nm, ".") < 0) {
            let keep: [DflCode] = [];
            let j = 0;
            while (j < len(out)) {
                let d = out[j];
                if (d.name != nm) { keep += d; }
                j = j + 1;
            };
            let decl: Decl = s;
            let func: Func = decl.v;
            let vals = dfl_codes(func);
            if (len(vals) > 0) { keep += { name: nm, vals: vals }; }
            out = keep;
        }
        i = i + 1;
    };
    out
};

// A def's parameter defaults (rename.y rn_note_defaults) as lit_codes,
// or [] when it has none.
def dfl_codes(func: Func) -> [str] {
    let dv: [Node] = func.defs;
    let out: [str] = [];
    let any = false;
    let i = 0;
    while (i < len(dv)) {
        let d = dv[i];
        let dk: long = d.k;
        if (dk != K.void) { any = true; }
        out += lit_code(d);
        i = i + 1;
    };
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
        let i = 1;
        while (i < len(parts)) {
            let p: str = parts[i];
            if (dbg_lines) {
                let sp = index_of(p, " ");
                out += "\n.loc " + tostring(tonum(p[:sp]) + off) + p[sp:];
            } else {
                let nl = index_of(p, "\n");
                if (nl >= 0) { out += p[nl:]; }
            };
            i = i + 1;
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
    let ri = 0;
    while (ri < len(refs)) {
        let r = asm.labmap_put(m, refs[ri], 1, 0);
        m = r.map;
        ri = ri + 1;
    };
    let nall = len(allrod);
    // text -> the index of the winner in `win`, plus loser pairs
    let texts = asm.labmap_new(nall * 2 + 64);
    let win: [str] = [];
    let dup_old: [str] = [];
    let dup_new: [str] = [];
    let s2 = 0;
    while (s2 < nall) {
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
                    let ti = asm.labmap_put(texts, text, 1, len(win));
                    texts = ti.map;
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
        s2 = s2 + 1;
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
    let i = 0;
    while (i < len(lines)) {
        let ln: str = lines[i];
        let at = index_of(ln, "lea ");
        if (at >= 0) {
            let rest = ln[at + 4:len(ln)];
            let e = index_of(rest, "(%rip)");
            if (e >= 0) {
                let lbl = rest[0:e];
                let g = asm.labmap_get(m, lbl);
                if (g.sec > 0) {
                    // the label's own length is what is cut out: the winner's
                    // label is what gets longer or shorter
                    lines[i] = ln[0:at + 4] + dup_new[g.off] + rest[e:len(rest)];
                };
            };
        };
        i = i + 1;
    };
    join(lines, "\n")
};

// The program's assembly text: the bodies of the std units and of the
// packages (`deps`, link order: each after those it imports) and then
// the program's, shaken together; the arch prelude and constants the
// kept bodies reach; every unit's rodata; the .bss cells.
// Two units defining the same `y_`-prefixed name: say so, or return.
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
def dup_y_label(deps: [Unit], prog: Unit) -> long {
    let nu = len(deps);
    if (nu > 0) {
        let m = asm.labmap_new((nu + 1) * 2 + 16);
        let i = 0;
        while (i <= nu) {
            let u: Unit = if (i < nu) { deps[i] } else { prog };
            let labs = u.labels;
            let k = 0;
            while (k < len(labs)) {
                let lb: str = labs[k];
                if (lb[:2] == "y_") {
                    let g = asm.labmap_get(m, lb);
                    if (g.sec > 0) {
                        let f = g.sec - 1;
                        let first: str = if (f < nu) { deps[f].name } else { prog.name };
                        puts("error: duplicate y_ name '" + lb + "': '" + first + "' and '" + u.name + "' both define it -- a y_ name is a fixed label generated code calls by, not a name in a namespace, so only one body could be linked; rename one\n");
                        exit(1);
                    } else {
                        let r = asm.labmap_put(m, lb, i + 1, 0);
                        m = r.map;
                    };
                };
                k = k + 1;
            };
            i = i + 1;
        };
    };
    0
};

def link_units(std: [Unit], deps: [Unit], prog: Unit) -> str {
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
        k = k + 1;
    };
    k = nu - 1;
    while (k >= 0) {
        let uk = units[k];
        offs[k] = len(files);
        files += uk.files;
        k = k - 1;
    };
    // The runtime labels the program and the packages define (every
    // runtime label starts `y_`): they replace the std units' own.
    let plabels: [str] = [];
    let ou = len(std);
    while (ou <= nu) {
        let olab: [str] = [];
        if (ou < nu) { let du = units[ou]; olab = du.labels; } else { olab = prog.labels; };
        let pi = 0;
        while (pi < len(olab)) {
            let pl: str = olab[pi];
            if (pl[:2] == "y_") { plabels += pl; }
            pi = pi + 1;
        };
        ou = ou + 1;
    };
    // Every body, with its label, its references, and the `.loc` offset
    // of its unit (-1: the program's own, numbered as they are).
    let all: [str] = [];
    let labels: [str] = [];
    let refs: [[str]] = [];
    let fno: [long] = [];
    let j = 0;
    while (j < nu) {
        let u = units[j];
        let f = offs[j];
        let ub = u.bodies;
        let ul = u.labels;
        let ur = u.refs;
        let b = 0;
        while (b < len(ub)) {
            let lb: str = ul[b];
            let drop = false;
            if (j < len(std) && len(plabels) > 0) {
                if (lb[:2] == "y_") { drop = name_in(plabels, lb); }
            }
            if (!drop) {
                all += ub[b];
                labels += lb;
                refs += [ur[b]];
                fno += f;
            }
            b = b + 1;
        };
        j = j + 1;
    };
    let plab = prog.labels;
    let pbodies = prog.bodies;
    let prefs = prog.refs;
    let pb2 = 0;
    while (pb2 < len(pbodies)) {
        all += pbodies[pb2];
        labels += plab[pb2];
        refs += [prefs[pb2]];
        fno += -1;
        pb2 = pb2 + 1;
    };
    // Body-level tree shaking comes first: its output is also the root
    // set for shaking the arch prelude, and the kept prelude's references
    // shake the rodata constants.
    let extra: [str] = [];
    let shaken = prune_bodies(labels, refs, extra);
    let keep = shaken.keep;
    let body_refs = shaken.refs;
    let core_lines = arch.arch_prelude_lines();
    let thr = uses_threads(body_refs);
    let mth = uses_math(body_refs);
    let pb = prelude_blocks(prelude_with(core_lines, thr, mth));
    let ps = shake_prelude(pb, body_refs);
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
    // Everything the kept code can reach: the kept bodies' own references
    // plus the kept prelude's. Computed before the rodata, which uses it as
    // its reachability set.
    let const_refs: [str] = [];
    const_refs += ps.refs;
    let ci = 0;
    while (ci < len(body_refs)) {
        const_refs += [body_refs[ci]];
        ci = ci + 1;
    };
    // The rodata first, because it decides the labels the bodies use: one
    // block per distinct literal text, the losers recorded.
    tyset_reset();
    let allrod: [[str]] = [];
    let gls: [str] = [];
    let ju = 0;
    while (ju < nu) {
        let u = units[ju];
        allrod += u.rodata;
        gls += u.globals;
        ju = ju + 1;
    };
    allrod += prog.rodata;
    gls += prog.globals;
    let interned = rodata_intern([], allrod, const_refs);
    let dup_old = interned.dup_old;
    let rodpieces = interned.pieces;
    // loser label -> index into dup_new, so a body's refs can be relabelled
    // in one probe each.
    let dupmap = asm.labmap_new(len(dup_old) * 2 + 64);
    let di = 0;
    while (di < len(dup_old)) {
        let dr = asm.labmap_put(dupmap, dup_old[di], 1, di);
        dupmap = dr.map;
        di = di + 1;
    };
    // Piece-list + single join: `asm = asm + piece` per iteration is
    // quadratic (each concat re-copies the whole 1.4MB+ accumulator —
    // the arena never frees), which OOMs on self-compilation.
    let pieces: [str] = [];
    let ab = 0;
    while (ab < len(all)) {
        if (keep[ab]) {
            let kb: str = all[ab];
            let kf = fno[ab];
            if (kf >= 0) { kb = link_locs(kb, kf); };
            if (len(dup_old) > 0) { kb = relabel_dups(kb, dupmap, interned.dup_new); };
            pieces += kb;
            pieces += "\n";
        }
        ab = ab + 1;
    };
    let body_text = join(pieces, "");
    let asm = arch.arch_header();
    if (dbg_lines) {
        asm = file_dirs(files) + asm;
    }
    asm = asm + arch.arch_text() + ps.text;
    asm = asm + body_text;
    let consts_text = shake_refs(arch.arch_consts(), const_refs);
    asm = asm + arch.arch_rodata() + consts_text;
    asm = asm + join(rodpieces, "");
    // .bss: the allocator's cells when the kept prelude still uses
    // them, then one cell per global.
    let heap_text = shake_refs(arch.arch_heap_cells(), const_refs);
    if (len(gls) > 0 || len(heap_text) > 0) {
        let gpieces: [str] = [];
        gpieces += arch.arch_bss();
        gpieces += heap_text;
        let gk = 0;
        while (gk < len(gls)) {
            gpieces += arch.arch_global_cell(gls[gk]);
            gk = gk + 1;
        };
        asm = asm + join(gpieces, "");
    }
    asm
};

// ── the std pack and package objects ──────────────────────────────────
// The std units, compiled ahead of time and carried by the ycc binary
// itself (`ycc --std-pack FILE` writes them; the build appends that file
// to the ycc that wrote it, see ycc.y self_pack): a program then links
// them as they are instead of compiling the runtime from source every
// time. A pack is text: a version line, the number of units, then each
// unit as its name and its fields -- every field a netstring
// (`<len>:<bytes>`), every list its count followed by its items, and a
// unit's fields one netstring together, so a reader steps over a unit it
// does not want. An export's type travels as its tcode, decoded only for
// the units a program binds (std_unit_bound): nobody reads the types of
// rt's or str's. A package's object (`ycc build`, unit_obj) holds one
// unit's fields the same way.

def pack_version() -> str {
    "ycc-std-pack 5\n"
};

def pack_put(out: [str], s: str) -> [str] {
    out += tostring(len(s));
    out += ":";
    out += s;
    out
};

def pack_strs(out: [str], xs: [str]) -> [str] {
    out = pack_put(out, tostring(len(xs)));
    let i = 0;
    while (i < len(xs)) {
        out = pack_put(out, xs[i]);
        i = i + 1;
    };
    out
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
        let i = 0;
        while (i < len(fs)) {
            // NOTE: bound once (see types.y tstr_go).
            let f = fs[i];
            // an optional field is `name?` (tdecode_go)
            let fname: str = f.name;
            if (f.opt) { fname = fname + "?"; };
            out = pack_put(out, fname);
            out = tcode_go(out, f.typ);
            i = i + 1;
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
    let i = 0;
    while (i < len(ts)) {
        out = tcode_go(out, ts[i]);
        i = i + 1;
    };
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
        let n = pack_num(cur);
        normtype({ k: K.tarrfix, of: tdecode_go(cur), n: n })
    }
    else if (c == "M") {
        let kt = tdecode_go(cur);
        normtype({ k: K.tmap, key: kt, of: tdecode_go(cur) })
    }
    else if (c == ">") {
        let args = tdecode_list(cur);
        normtype({ k: K.tfunc, args: args, ret: tdecode_go(cur) })
    }
    else if (c == "U") { normtype({ k: K.tunion, ts: tdecode_list(cur) }) }
    else if (c == "T") { normtype({ k: K.tparams, ts: tdecode_list(cur) }) }
    else if (c == "P") { normtype({ k: K.tpat, names: pack_get_strs(cur) }) }
    else if (c == "Q") {
        // a tref (tcode): a fresh unit id, `to` read with the "q"s inside
        // it pointing back at it (tdec_encs/tdec_refs)
        let name = pack_get(cur);
        let enc = pack_get(cur);
        tdec_n = tdec_n + 1;
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
        let n = pack_num(cur);
        let i = 0;
        while (i < n) {
            let fname = pack_get(cur);
            // `name?`: an optional field (tcode_go)
            let fopt = len(fname) > 0 && fname[len(fname) - 1] == c'?';
            if (fopt) { fname = fname[0:len(fname) - 1]; };
            fields += { name: fname, opt: fopt, typ: tdecode_go(cur) };
            i = i + 1;
        };
        normtype({ k: K.trec, fields: fields })
    }
};

def tdecode_list(cur: Cursor) -> [Type] {
    let out: [Type] = [];
    let n = pack_num(cur);
    let i = 0;
    while (i < n) {
        out += tdecode_go(cur);
        i = i + 1;
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
        j = j + 1;
    };
    let ds = u.dfl;
    out = pack_put(out, tostring(len(ds)));
    j = 0;
    while (j < len(ds)) {
        let d = ds[j];
        out = pack_put(out, d.name);
        out = pack_strs(out, d.vals);
        j = j + 1;
    };
    out
};

// One unit's fields.
def pack_unit_fields(u: Unit) -> str {
    let out: [str] = [];
    out = pack_strs(out, u.files);
    out = pack_iface(out, u);
    out = pack_put(out, u.init);
    out = pack_strs(out, u.bodies);
    out = pack_strs(out, u.labels);
    let rf = u.refs;
    out = pack_put(out, tostring(len(rf)));
    let j = 0;
    while (j < len(rf)) {
        out = pack_strs(out, rf[j]);
        j = j + 1;
    };
    let rd = u.rodata;
    out = pack_put(out, tostring(len(rd)));
    j = 0;
    while (j < len(rd)) {
        out = pack_strs(out, rd[j]);
        j = j + 1;
    };
    out = pack_strs(out, u.globals);
    join(out, "")
};

// The pack of `units`.
def std_pack(units: [Unit]) -> str {
    let out: [str] = [];
    out += pack_version();
    out = pack_put(out, tostring(len(units)));
    let i = 0;
    while (i < len(units)) {
        let u = units[i];
        out = pack_put(out, u.name);
        out = pack_put(out, pack_unit_fields(u));
        i = i + 1;
    };
    join(out, "")
};

// Reading a pack: `cur` is the text and the position in it. pack_len
// reads a netstring's length, leaving the cursor at its text.
def pack_len(cur: Cursor) -> long {
    let s = cur.s;
    let p = cur.p;
    let n = 0;
    let c = byte_at(s, p);
    while (c != c':' && p < len(s)) {
        n = n * 10 + c - c'0';
        p = p + 1;
        c = byte_at(s, p);
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
    tonum(pack_get(cur))
};

def pack_get_strs(cur: Cursor) -> [str] {
    let n = pack_num(cur);
    let out: [str] = [];
    let i = 0;
    while (i < n) {
        out += pack_get(cur);
        i = i + 1;
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
        j = j + 1;
    };
    let dfl: [DflCode] = [];
    let nf = pack_num(cur);
    j = 0;
    while (j < nf) {
        let dn = pack_get(cur);
        dfl += { name: dn, vals: pack_get_strs(cur) };
        j = j + 1;
    };
    let init = pack_get(cur);
    let bodies = pack_get_strs(cur);
    let labels = pack_get_strs(cur);
    let refs: [[str]] = [];
    let nr = pack_num(cur);
    j = 0;
    while (j < nr) {
        refs += [pack_get_strs(cur)];
        j = j + 1;
    };
    let rodata: [[str]] = [];
    let nd = pack_num(cur);
    j = 0;
    while (j < nd) {
        rodata += [pack_get_strs(cur)];
        j = j + 1;
    };
    let globals = pack_get_strs(cur);
    { name: name, files: files, exports: xs, init: init, bodies: bodies,
      labels: labels, refs: refs, rodata: rodata, globals: globals, dfl: dfl }
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
        let i = 0;
        while (i < n) {
            let nm = pack_get(cur);
            let ul = pack_len(cur);
            let at = cur.p;
            if (name_in(names, nm)) { got += unit_read(cur, nm, std_unit_bound(nm)); }
            cur.p = at + ul;
            i = i + 1;
        };
        let k = 0;
        while (k < len(names)) {
            let want: str = names[k];
            let a = 0;
            while (a < len(got)) {
                let u = got[a];
                if (u.name == want) { out += u; }
                a = a + 1;
            };
            k = k + 1;
        };
        if (len(out) != len(names)) { out = []; }
    }
    out
};

// A package's object (`ycc build` keeps one per package): its unit's
// fields, after a version line and the key it was compiled under (ycc.y
// build_key) -- an object of another key, or a cut-off one, is no hit.
def obj_version() -> str {
    "ycc-unit 4\n"
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
        i = i + 1;
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
                j = j + 1;
            };
            let ds = u.dfl;
            j = 0;
            while (j < len(ds)) {
                let d = ds[j];
                let dv = d.vals;
                let vals: [Node] = [];
                let m = 0;
                while (m < len(dv)) {
                    vals += lit_decode(dv[m]);
                    m = m + 1;
                };
                dfl += { name: u.name + "." + d.name, vals: vals };
                j = j + 1;
            };
        }
        i = i + 1;
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
    compile_unit(ast, nr.imports, nr.origin, true, wlevel, name, base, unit_externs(std, nr.std, deps, nr.pkgs))
};

// The program's unit, compiled against the std units `std` (std_units)
// and the packages `deps` (`ycc build`: every package it links, each
// after those it imports) and linked with them. `nr` is the program's
// resolution: the std units it binds itself, the packages it imports.
def emit_program(ast: Block, nr: Resolved, debug: bool, wlevel: long, std: [Unit], deps: [Unit]) -> { ok: bool, asm: str, errors: [Diag], warnings: [Diag], times: [Timing] } {
    let xt = unit_externs(std, nr.std, deps, nr.pkgs);
    let inits: [str] = [];
    let units: [Unit] = [];
    units += std;
    units += deps;
    let i = 0;
    while (i < len(units)) {
        let u = units[i];
        if (len(u.init) > 0) { inits += u.init; }
        i = i + 1;
    };
    xt.inits = inits;
    // a package reading argv() needs `_start` to materialize it
    let wargv = false;
    i = 0;
    while (i < len(deps)) {
        let u = deps[i];
        let rf = u.refs;
        let b = 0;
        while (!wargv && b < len(rf)) {
            wargv = name_in(rf[b], "y_argv");
            b = b + 1;
        };
        i = i + 1;
    };
    xt.argv = wargv;
    let r = compile_unit(ast, nr.imports, nr.origin, debug, wlevel, "", 0, xt);
    let times = r.times;
    if (r.ok) {
        dup_y_label(deps, r.unit);
        let pt = clock_us();
        let ph = heap_used();
        let asm = link_units(std, deps, r.unit);
        let pr = phase_end(times, "asm_text", pt, ph);
        { ok: true, asm: asm, errors: r.errors, warnings: r.warnings, times: pr.times }
    } else {
        { ok: false, asm: "", errors: r.errors, warnings: r.warnings, times: times }
    }
};

export { emit_program, compile_package, std_units, std_unit_names, std_pack, unit_obj, unit_unobj, unit_iface, native_resolve, native_resolve_x, native_resolve_pk, origin_at, strip_ns, strip_list, strip_decl, phase_end };

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
    { k: K.dot, obj: obj, key: key, line: line, col: col }
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
    { k: K.decl, kind: "let", typ: type_node({ k: K.tnone }), name: name, v: v, line: ln, col: cl }
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
    let mi = 0;
    while (mi < len(mkeys)) {
        let mk: str = mkeys[mi];
        let mv = mvals[mi];
        let found = false;
        let fi = 0;
        while (fi < len(keys)) {
            let kk: str = keys[fi];
            if (kk == mk) {
                vals[fi] = mv;
                found = true;
            }
            fi = fi + 1;
        };
        if (found) {
        } else {
            keys += mk;
            vals += mv;
        };
        mi = mi + 1;
    };
    let knodes: [Node] = [];
    let bnodes: [Node] = [];
    let ki = 0;
    while (ki < len(keys)) {
        let ks: str = keys[ki];
        knodes += n_str(ks, ln, cl);
        bnodes += n_id("none", ln, cl);
        ki = ki + 1;
    };
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
    if (e.k == K.index) { let index: Index = e; infer(st, index.arr).k == K.tmap } else { false }
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
    let sts: [Node] = [];
    sts += n_decl(t + "m", node.arr, ln, cl);
    sts += n_decl(t + "k", node.idx, ln, cl);
    sts += n_decl(t + "v", node.v, ln, cl);
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
