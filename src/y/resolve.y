// resolve.y — source overlays, import splicing and the program's std units.
//
// This is the first phase of native compilation: one expanded source string,
// its import set, its origin map, and the std units it links. It used to open
// native.y; it is separate so that the backend file starts with the emitter
// instead of a thousand lines of file lookup.

import ktgt from "./target.y";
import meta from "./meta.y";
import tov from "./target_overlay.y";
import lexer from "./lexer.y";
import fs;

let res_pkgs: [str] = [];
let res_roots: [str] = [];
let res_used: [str] = [];
// std library units the resolver saw imported BY NAME (math, args, ...):
// they are linked units now, not spliced text, so native_resolve_x appends
// them to the program's `std` (see std_lib_names).
let res_std_lib: [str] = [];
// True while std_compile resolves a std unit's own imports: those always
// bind units, so the project-local lookup (res_local_mod) is skipped.
let res_in_std = false;
// The bare `import name;` lines of the unit's own file that nothing uses
// (`name.` appears nowhere else in it), as warnings at the import's line:
// native_resolve_seen fills it at depth 0, compile_unit hands it to lint.
let res_unused: [Diag] = [];
// An editor buffer can replace one imported source without writing it to disk.
let res_overlay_path = "";
let res_overlay_text = "";
// The root file itself may be an overlay (NAME.TARGET.y, which the language
// server analyses directly): its base is read and this buffer is the overlay.
let tov_root_ov = "";
let tov_root_ov_path = "";

def source_path(path: str) -> str {
    norm_path(if (path[:1] == "/") { path } else { fs.cwd() + "/" + path })
};

def set_source_overlay(path: str, text: str) {
    res_overlay_path = if (path == "") { "" } else { source_path(path) };
    res_overlay_text = text;
};

def source_read(path: str) -> str? {
    if (res_overlay_path != "" && source_path(path) == res_overlay_path) {
        some(res_overlay_text)
    } else { fs.read_file(path) }
};
// ── native import resolution ───────────────────────────────────────────

type Origin = { files: [str], nuser: long, file: [long], line: [long], mods: [str] };
type Resolved = { src: str, imports: [str], origin: Origin, std: [str], pkgs: [str], ogen: [bool] };

def native_resolve(src: str, base_dir: str, depth: long) -> Resolved {
    native_resolve_x(src, base_dir, depth, "")
};

def native_resolve_x(src: str, base_dir: str, depth: long, root: str) -> Resolved {
    res_pkgs = [];
    res_roots = [];
    resolve_unit(src, base_dir, depth, root)
};

// One unit of a project (`ycc build`): a bare `import name;` with
// `name` in `pkgs` (the package's dependencies) imports that package
// instead of splicing a file -- see res_pkgs -- and one naming a module
// looks in the package's source roots `roots` too (std_resolve).
def native_resolve_pk(src: str, base_dir: str, root: str, pkgs: [str], roots: [str]) -> Resolved {
    res_pkgs = pkgs;
    res_roots = roots;
    resolve_unit(src, base_dir, 0, root)
};

// `std` lists the std units the program links, in link order: prelude,
// exec, str, rt (std_units compiles them).
def resolve_unit(src: str, base_dir: str, depth: long, root: str) -> Resolved {
    res_used = [];
    res_std_lib = [];
    let self_path = "";
    if (root != "") { self_path = norm_path(root); };
    // A root that is itself NAME.TARGET.y (the language server opens one)
    // compiles as its base with this buffer as the overlay.
    tov_root_ov = "";
    tov_root_ov_path = "";
    if (root != "") {
        let ob = tov.tov_base_of(self_path, res_target);
        if (ob != "") {
            let bs = source_read(ob);
            if (bs == none) {
                puts("overlay " + root + " has no base " + ob + "\n");
                exit(1);
            };
            tov_root_ov = src;
            tov_root_ov_path = self_path;
            src = unwrap(bs);
            self_path = norm_path(ob);
            root = ob;
        };
    };
    // NOTE: seen-threading wrapper (see native_resolve_seen): asm.y imports
    // enc64 as `enc` AND elf.y imports enc64 as `elfenc`; without dedup the
    // encoder splices twice and every enc64 def collides (find_dup).
    let r = meta_prepare(src, base_dir, depth, root, self_path);
    tov_root_ov = "";
    tov_root_ov_path = "";
    let rsrc = join(r.lines, "\n");
    let rimports = r.imports;
    let files: [str] = [root];
    files += r.seen;
    let mods: [str] = [""];
    mods += r.smods;
    let origin = { files: files, nuser: len(files), file: r.ofile, line: r.oline, mods: mods };
    let pn = prelude_names();
    let xn = exec_names();
    let seen = words_seen(rsrc, pn + xn + str_names());
    let px = len(pn) + len(xn);
    let want_prelude = seen_any(seen, 0, len(pn), 1);
    let want_exec = false;
    if (seen_any(seen, len(pn), px, 1)) {
        want_exec = true;
        want_prelude = true;
    }
    let std: [str] = [];
    if (!target_is_kernel()) {
        if (want_prelude) { std += "prelude"; }
        if (want_exec) { std += "exec"; }
    };
    std += "str";
    // The runtime library (std/rt.y) is linked into EVERY program:
    // generated code calls into it by fixed label (`call y_print_long`),
    // so there is no name to test for. Unused helpers cost nothing in the
    // output -- prune_bodies drops them at link time.
    std += "rt";
    let want: [str] = [];
    let li = 0;
    while (li < len(res_std_lib)) {
        if (index_of(rsrc, res_std_lib[li] + ".") >= 0 && !name_in(want, res_std_lib[li])) {
            want += res_std_lib[li];
        };
        li = li + 1;
    };
    // ...and the units those import (std_lib_deps), all in std_lib_names order,
    // dependency first: every caller of std_units -- ycc, the language server's
    // diagnostics, native_compile -- compiles a unit against the ones before it,
    // so `std` must be closed and ordered here, not by each caller.
    let wi = 0;
    while (wi < len(want)) {
        let ds = std_lib_deps(want[wi]);
        let di = 0;
        while (di < len(ds)) {
            if (!name_in(want, ds[di])) { want += ds[di]; };
            di = di + 1;
        };
        wi = wi + 1;
    };
    let libs = std_lib_names();
    let lj = 0;
    while (lj < len(libs)) {
        if (name_in(want, libs[lj])) { std += libs[lj]; };
        lj = lj + 1;
    };
    // ogen is EMPTY for a unit with no blocks, which is what tells lint there is
    // no generator whose top level is this one (see lint_meta_top): a file with
    // blocks whose pieces happen to add no lines is still such a file.
    let og: [bool] = [];
    if (meta.mg_n > 0) {
        let generators = meta.mg_generator_files();
        for i in 0..len(r.ogen) {
            // Runtime-only files cannot run a top-level statement twice.
            og += r.ogen[i] || !(r.ofile[i] in generators);
        };
    };
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

// A std source, newline-terminated (as every source file the
// compiler reads should be).
def std_text(s: str) -> str {
    if (s[len(s) - 1:] == "\n") { s } else { s + "\n" }
};

// How many buckets words_seen's name table has (word_hash).
const WORD_BUCKETS = 512;

def words_seen(code: str, names: [str]) -> [long] {
    let seen: [long] = [];
    for k in 0..len(names) + 1 {
        seen += 0;
    };
    // the names by hash of their bytes (word_hash), so a word of the code is
    // compared with the few names that share its bucket, not with all of them
    let tab: [[long]] = [];
    for b in 0..WORD_BUCKETS {
        let one: [long] = [];
        tab += one;
    };
    for k in 0..len(names) {
        tab[word_hash(names[k], 0, len(names[k]))] += k;
    };
    words_scan(code, 0, len(code), names, tab, seen);
    seen
};

// A bucket of the table words_seen builds: the bytes of s[lo:hi) folded
// together. No slice is made.
def word_hash(s: str, lo: long, hi: long) -> long {
    let h = hi - lo;
    for i in lo..hi {
        h = (h * 31 + s[i]) & 0x7fffffff;
    };
    h % WORD_BUCKETS
};

// words_seen's pass over code[lo:n], marking seen in place. The fields of
// an f-string are code: lexer.y fstr_walk finds them as the lexer does,
// and each is scanned on its own.
def words_scan(code: str, lo: long, n: long, names: [str], tab: [[long]], seen: [long]) -> void {
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
                        words_scan(code, fs[f], fs[f + 1], names, tab, seen);
                        if (fs[f + 3] > fs[f + 2]) { seen[len(names)] = 2; }
                        f += 4;
                    };
                    i = w.end;
                } else {
                    let bucket = tab[word_hash(code, i, j)];
                    for b in 0..len(bucket) {
                        let m = bucket[b];
                        let nm = names[m];
                        if (len(nm) == j - i && word_at(code, i, nm)) {
                            if (seen[m] == 0) { seen[m] = 1; }
                            if (prev == '.') { pend = m; }
                        }
                    };
                    i = j;
                };
            } else {
                i = i + 1;
            };
            prev = c;
        };
    };
};

// A byte of an identifier-shaped word (the lexer's is_ident_continue:
// letters, digits, `_`).
def word_byte(c: long) -> bool {
    is_ident_continue(c)
};

// A blank as the lexer skips it (its is_blank_byte: space, tab, LF, CR).
def blank_byte(c: long) -> bool {
    is_blank_byte(c)
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

