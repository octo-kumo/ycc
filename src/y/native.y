// native.y — typed AST -> x86_64 assembly (AT&T/GAS) for the native backend.

import hostos from "./host_linux.y";
import tags from "./tags.y";
import dispatch from "./native_dispatch.y";
import arch from "./arch_x64.y";
// For its aliases AsmLabel and AsmNum.
import asm from "./asm.y";
// nasm: ycc_assemble, for the generator's own image (meta_compile_gen).
import nasm from "./asm.y";
import insn from "./ir.y";
import optim from "./optimize.y";
import obf from "./obfuscate.y";
import seal from "./seal.y";
import obfvm from "./obf_vm.y";
import recipes from "./emit_recipes.y";
import arlower from "./array_lower.y";
import builtins from "./builtin_native.y";
import codec from "./type_codec.y";
import unitwire from "./unit_codec.y";
import labels from "./labels.y";
import wordspec from "./language_schema.y";
import types from "./types.y";
import rename from "./rename.y";
import lexer from "./lexer.y";
import parser from "./parser.y";
import tov from "./target_overlay.y";
import lint from "./lint.y";
import escape from "./escape.y";
import lifetime from "./lifetime.y";
import meta from "./meta.y";
import fs;

// Collection is opt in; never is checked by lifetime.y.
let gc_mode: long = 2;
let gc_stress: bool = false;

// What an environment entry (Slot) is. A number, so a test is an integer compare
// and a misspelt kind is an undefined name, not a silently different kind.
const SK = { none: 0, local: 1, param: 2, global: 3, func: 4, capture: 5, box: 6, own: 7,
    frame: 8, boxmark: 10, appmark: 11, fnty: 12, env: 13, temp: 14, closure: 15 };

let dbg_lines = false;
let dbg_file: [long] = [];
let dbg_line: [long] = [];

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
let ty_sig_keys: [str] = [];
let ty_sig_ids: [long] = [];
let ty_sig_bkts: [[long]] = [];
// union_shared's answers in this unit, by the union's node.
let ush_nodes: [Type] = [];
let ush_vals: [[str]] = [];
let brk_label: long = 0 - 1;
let cont_label: long = 0 - 1;
// One entry per enclosing loop while a body is emitted: the loop variable's
// name ("" for `while`/C-style `for`), and the jump targets `break` and
// `continue` name. A labelled break searches this from the innermost outward;
// an unknown label falls back to the outermost loop.
let loop_names: [str] = [];
let loop_brks: [long] = [];
let loop_conts: [long] = [];
// The regions and heap blocks open where a body is emitted (gen_region),
// innermost last: the kind (0 region, 1 automatic region, 2 heap block), the
// record's frame offset, and how many loops enclosed the block -- a jump to a
// loop outside it leaves it first (gen_rg_leave_to).
let rg_kinds: [long] = [];
let rg_offs: [long] = [];
let rg_loops: [long] = [];

// ── native import resolution ───────────────────────────────────────────

type Origin = { files: [str], nuser: long, file: [long], line: [long], mods: [str] };
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
// `ycc --exec=off`: exec is left out, so `exec(...)` fails with
// "undefined function" and the binary has no path to a shell at all.
def resolve_unit(src: str, base_dir: str, depth: long, allow_exec: bool, root: str) -> Resolved {
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
    let r = meta_prepare(src, base_dir, depth, allow_exec, root, self_path);
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
    if (allow_exec) {
        if (seen_any(seen, len(pn), px, 1)) {
            want_exec = true;
            want_prelude = true;
        }
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
def meta_prepare(src: str, base_dir: str, depth: long, allow_exec: bool, root: str, self_path: str) -> SrcLines {
    if (!meta.mg_on) {
        return native_resolve_seen(src, base_dir, depth, [], [], 0, self_path, self_path);
    };
    // step 1: find the blocks. The result is thrown away; only the scanner's
    // accumulators survive.
    let first = native_resolve_seen(src, base_dir, depth, [], [], 0, self_path, self_path);
    if (meta.mg_n == 0) {
        // no blocks: the collecting pass's own result is the real one, and it
        // is byte for byte what the pass-off path returns
        first
    } else {
        meta_resolve(src, base_dir, depth, allow_exec, root, first, self_path)
    }
};

def meta_resolve(src: str, base_dir: str, depth: long, allow_exec: bool,
    root: str, first: SrcLines, self_path: str) -> SrcLines {
    if (meta.mg_nest > 0) {
        // A round in which a block cannot produce its text leaves a stand-in
        // where its call goes, so a statement naming something that block was
        // going to define would not compile. The reduction leaves those
        // statements out of G, and they declare nothing, so no name is lost.
        meta.mg_reduce_on();
    };
    meta.mg_pass();
    native_resolve_seen(src, base_dir, depth, [], [], 0, self_path, self_path);
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
            native_resolve_seen(src, base_dir, depth, [], [], 0, self_path, self_path)
        };
    };
    // step 3: the ordinary resolve, with every piece known. Its G is built and
    // not run -- nothing is pending, so there is nothing left to compute.
    meta.mg_pass();
    native_resolve_seen(src, base_dir, depth, [], [], 0, self_path, self_path)
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
    let av: [str] = [root + ".meta"];
    // Compiling the generator is the single largest transient allocation of a
    // meta compile (a whole second program: parse, check, emit, assemble).
    // Doing it in a child frees all of it at once, which is what keeps the
    // compiler's own build under its memory cap as the source grows.
    let rr = mgw_run(av);
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

// ── running a generator in a child ─────────────────────────────────────
// The child compiles G, runs it, and writes one RunRes back through a pipe;
// everything it allocated goes with it. The protocol is fixed-width little
// endian so the generator's own output can be arbitrary bytes.
const MGW_CLOSE = 3;
const MGW_FORK = 57;
const MGW_FCNTL = 72;
const MGW_F_SETFD = 2;
const MGW_FD_CLOEXEC = 1;

def mgw_u64(b: [byte], v: long) -> [byte] {
    let i = 0;
    while (i < 8) {
        b += (v >> (i * 8)) & 255;
        i++;
    };
    b
};

def mgw_rd64(b: [byte], off: long) -> long {
    let v = 0;
    let i = 0;
    while (i < 8) {
        v = v | ((b[off + i] & 255) << (i * 8));
        i++;
    };
    v
};

def mgw_encode(r: RunRes) -> [byte] {
    let b: [byte] = [];
    b = mgw_u64(b, if (r.ok) { 1 } else { 0 });
    b = mgw_u64(b, r.status);
    b = mgw_u64(b, r.sig);
    b = mgw_u64(b, len(r.out));
    b += r.out;
    let e = bytes(r.err);
    b = mgw_u64(b, len(e));
    b += e;
    b
};

def mgw_decode(b: [byte]) -> RunRes {
    let ok = mgw_rd64(b, 0) != 0;
    let status = mgw_rd64(b, 8);
    let sig = mgw_rd64(b, 16);
    let n = mgw_rd64(b, 24);
    let out = b[32:32 + n];
    let eoff = 32 + n;
    let en = mgw_rd64(b, eoff);
    { ok: ok, status: status, sig: sig, out: out, err: from_bytes(b[eoff + 8:eoff + 8 + en]) }
};

// The child's own exit status says its diagnostics stand (it already printed
// them); a successful child sends exactly one frame.
def mgw_run(av: [str]) -> RunRes {
    let pp = meta.pipe_fds();
    if (!pp.ok) {
        return { ok: false, status: 0, sig: 0, out: [], err: "cannot create a pipe for the generator" };
    };
    // AArch64 has no fork(2): clone(2) with SIGCHLD and a zero stack is the
    // same process copy. x86-64's fork ignores the extra registers.
    let pid = if (hostos.is_arm()) { syscall(hostos.nr(MGW_FORK), 17, 0, 0, 0, 0) }
        else { syscall(hostos.nr(MGW_FORK)) };
    if (pid == 0) {
        syscall(hostos.nr(MGW_CLOSE), pp.rfd);
        // the generator's own exec must not keep this pipe open
        syscall(hostos.nr(MGW_FCNTL), pp.wfd, MGW_F_SETFD, MGW_FD_CLOEXEC);
        let img = meta_compile_gen();
        let rr = meta.run_image(img, av, true);
        fs.write_data(pp.wfd, mgw_encode(rr));
        syscall(hostos.nr(MGW_CLOSE), pp.wfd);
        exit(0);
    };
    syscall(hostos.nr(MGW_CLOSE), pp.wfd);
    if (pid < 0) { meta.mg_report("cannot fork the meta generator"); };
    let raw = fs.read_all_bytes(pp.rfd);
    syscall(hostos.nr(MGW_CLOSE), pp.rfd);
    let st = wait_pid(pid);
    if (st != 0 || len(raw) < 40) {
        exit(1);
    };
    mgw_decode(raw)
};

// The pack the driver read from its own binary (ycc.y self_pack), or "" under
// --std=source: what a meta generator's std units come from.
let meta_pack = "";

def set_meta_pack(p: str) -> void {
    meta_pack = p;
};

// Compile G the way ycc compiles a program, with the pass OFF, and hand back
// its image. G's errors are reported with G's own origin map, so they read
// `<file>.meta:<source line>` -- visibly about the synthesized text and not
// about the user's file, and still carrying a line through the line map.
def meta_compile_gen() -> [byte] {
    let saved_gc = gc_mode;
    gc_mode = 0;
    // A tool (the language server) resolves without a driver: give the
    // generator the host build rather than no YCC at all.
    if (meta.mg_build_unset()) {
        meta.mg_build(meta.mg_build_text(res_target, meta.mg_target_os(res_target),
            meta.mg_target_arch(res_target, res_arch), target_info(res_target).format,
            hostos.name(), false, "never", "", "", [], [], []));
    };
    let gt = meta.meta_gtext();
    let go = meta_gorigin(meta.mg_glines());
    meta.mg_set(false);
    let nr = native_resolve_pk(gt, meta.mg_gbase, meta.mg_gexec,
        meta.mg_root + ".meta", meta.mg_pkgs, meta.mg_roots);
    if (meta.mg_probe(nr.src, meta.mg_gbase)) {
        meta.mg_report("a meta block cannot appear in a module imported into the meta generator: the generator's text is compiled with the pass off, so nothing in it is scanned");
    };
    // the std units from the compiler's own pack, as the program's are: no std
    // or arch source is embedded, so "" here (from source) failed in any ycc
    // without src/y beside it
    let su = std_units(nr.std, meta_pack);
    // nr.src, not gt: the hoisted imports were spliced in by the resolve above,
    // and tokenizing gt would hand the parser a literal `import` line
    let ast = parser.parse_program(lexer.tokenize(nr.src));
    let saved_target = res_target;
    let saved_arch = res_arch;
    res_target = hostos.name();
    res_arch = hostos.arch();
    obf.suspend();
    let r = emit_program(ast, nr, false, 0, su, []);
    gc_mode = saved_gc;
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
    obf.resume();
    res_target = saved_target;
    res_arch = saved_arch;
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

def dir_of(p: str) -> str {
    let s = last_index_of(p, "/");
    if (s < 0) { "" } else { p[:s] }
};

def self_dir() -> str {
    let by_argv = "";
    let av = argv();
    if (len(av) > 0) { by_argv = dir_of(av[0]); };
    let buf: [byte; 4096] = [0; 4096];
    let n = hostos.readlink("/proc/self/exe", &buf[0], len(buf));
    if (n > 0) {
        let d = dir_of(from_bytes(buf[0:n]));
        if (len(d) > 0) { d } else { by_argv }
    } else { by_argv }
};

// A project-local module `name` -- next to the importer or in a package's
// source root, never a std directory -- shadows the std library unit of that
// name, as it did when every std module was spliced from source.
def res_local_mod(name: str, base_dir: str) -> bool {
    let found = !res_in_std && !(fs.read_file(base_dir + "/" + name + ".y") == none);
    let ri = 0;
    while (!found && !res_in_std && ri < len(res_roots)) {
        found = !(fs.read_file(res_roots[ri] + "/" + name + ".y") == none);
        ri = ri + 1;
    };
    found
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

type SrcLines = { lines: [str], imports: [str], seen: [str], smods: [str], ofile: [long], oline: [long], ogen: [bool] };

// ── what a kernel cannot import ─────────────────────────────────────────
def kernel_is_std_path(full: str, name: str) -> bool {
    let want = "std/" + name + ".y";
    if (len(full) >= len(want) && full[len(full) - len(want):] == want) { true } else { false }
};

def kernel_std_denied() -> [str] {
    ["fs", "net", "exec", "prelude", "crypto", "x509", "tls", "http", "tui",
        "args", "random", "test", "img", "audio", "ipc", "snd", "gui"]
};

// Why, for the diagnostic.  One line each, because "not available in kernel
// mode" without a reason reads like a compiler limitation rather than a fact
// about the module.
def kernel_std_why(name: str) -> str {
    if (name == "fs") { "it is openat/read/write/stat on a Linux descriptor" }
    else if (name == "net") { "it is raw socket syscalls" }
    else if (name == "exec") { "it is fork/execve/pipe/dup2" }
    else if (name == "prelude") { "it is readline and the stdin sync" }
    else if (name == "crypto") { "it takes its randomness from getrandom" }
    else if (name == "random") { "it takes its randomness from getrandom" }
    else if (name == "x509") { "it is built on crypto and tls" }
    else if (name == "tls") { "it is a socket client" }
    else if (name == "http") { "it is a socket client" }
    else if (name == "tui") { "it is termios ioctls" }
    else if (name == "args") { "it reads the process's argv from the OS" }
    else if (name == "test") { "it is a test harness, which is a process" }
    else if (name == "img") { "it loads and saves files through fs" }
    else if (name == "audio") { "it loads and saves files through fs" }
    else if (name == "ipc") { "it is raw socket syscalls" }
    else if (name == "snd") { "it talks to the desktop audio server over a socket" }
    else if (name == "gui") { "it is a window on a desktop (user32, or the X server's socket)" }
    else { "it uses the OS" }
};

// The unused bare imports of the unit last resolved (see res_unused).
def unused_imports() -> [Diag] { res_unused };

// Whether the bare import `name` is used by a line other than line `skip`: the
// text `name.` outside a `//` comment, not the tail of a longer name or of a
// field (`xfs.read`, `a.fs.read`). Blunt on purpose -- a use inside a string
// counts -- because the one thing it must never do is call a used import unused.
def import_used(lines: [str], skip: long, name: str) -> bool {
    let pat = name + ".";
    for j in 0..len(lines) {
        if (j != skip) {
            let t = trim(lines[j]);
            if (t[:2] != "//" && t[:7] != "import ") {
                let ln = lines[j];
                let at = index_of(ln, pat);
                let off = 0;
                while (at >= 0) {
                    let p = off + at;
                    if (p == 0) { return true; };
                    let c = ln[p - 1];
                    if (!(c == 46 || c == 95 || (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122))) { return true; };
                    off = p + 1;
                    at = index_of(ln[off:], pat);
                };
            };
        };
    };
    false
};

def native_resolve_seen(src: str, base_dir: str, depth: long, seen: [str], smods: [str], fid: long, self_path: str, fpath: str) -> SrcLines {
    if (depth > 32) {
        // Fatal, like a missing module: carrying on compiled the program
        // without the rest of the chain and exited 0.
        puts("error: native import depth exceeded (cycle?)\n");
        exit(1);
        { lines: [], imports: [], seen: seen, smods: smods, ofile: [], oline: [], ogen: [] }
    } else {
        if (depth == 0 && !res_in_std) { res_unused = []; };
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
        // The scan's OWN origins, read by input line number (a block's piece
        // may add lines, so they are not the output's).
        let lines: [str] = sc.p;
        let mfid: [long] = sc.pf;
        let mline: [long] = sc.pol;
        let mgen: [bool] = sc.gen;
        // A target overlay: NAME.TARGET.y beside NAME.y. An
        // overlay is a sibling file, so it is read here, after the base's own
        // scan, and its file id joins the origin table right after the base.
        // The line records are built only when there is one: a compiler with
        // no overlays in sight must not pay for them on every file.
        let ovp = "";
        let ovtext: str? = none;
        if (fpath != "" && res_target != "") {
            if (depth == 0 && fid == 0 && tov_root_ov != "") {
                ovp = tov_root_ov_path;
                ovtext = some(tov_root_ov);
            } else {
                let cand = tov.tov_path(fpath, res_target);
                if (cand != "") {
                    ovp = cand;
                    ovtext = source_read(cand);
                };
            };
        };
        if (ovtext != none) {
            let ovfid = len(seen) + 1;
            seen += ovp;
            // The overlay lives in the module its base is in: a by-name
            // import's scope comes from origin.mods, so the overlay's file id
            // must carry the same module name (the root's is "").
            smods += if (fid > 0 && fid - 1 < len(smods)) { smods[fid - 1] } else { "" };
            let osc = meta_meta_scan(unwrap(ovtext), base_dir, ovfid);
            if (!osc.ok) {
                let where = tostring(osc.eline) + ":" + tostring(osc.ecol);
                puts(ovp + ":" + where + ": error: " + osc.err + "\n");
                exit(1);
            };
            let blines: [TovLine] = [];
            let bi = 0;
            while (bi < len(sc.p)) {
                let bf = fid;
                if (bi < len(sc.pf)) { bf = sc.pf[bi]; };
                let bl = bi + 1;
                if (bi < len(sc.pol)) { bl = sc.pol[bi]; };
                blines += { text: sc.p[bi], fid: bf, line: bl, gen: gen_at(sc.gen, bi) };
                bi++;
            };
            let olines: [TovLine] = [];
            let oi = 0;
            while (oi < len(osc.p)) {
                let of = ovfid;
                if (oi < len(osc.pf)) { of = osc.pf[oi]; };
                let ol = oi + 1;
                if (oi < len(osc.pol)) { ol = osc.pol[oi]; };
                olines += { text: osc.p[oi], fid: of, line: ol, gen: gen_at(osc.gen, oi) };
                oi++;
            };
            let mo = tov.tov_merge(blines, olines, fpath, ovp);
            if (!mo.ok) {
                puts(mo.err + "\n");
                exit(1);
            };
            lines = [];
            mfid = [];
            mline = [];
            mgen = [];
            mo.lines.foreach((el) => {
                lines += el.text;
                mfid += el.fid;
                mline += el.line;
                mgen += el.gen;
            });
        };
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
            if (i < len(mfid)) { lf = mfid[i]; };
            let ln = 0;
            if (i < len(mline)) { ln = mline[i]; };
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
                    // through the closing quote: a `;` and a comment after it
                    // are not the path
                    let endq = index_of(path_part[1:], "\"");
                    if (path_part[:1] == "\"" && endq >= 0) {
                        path_part = path_part[:endq + 2];
                    } else if (path_part[len(path_part) - 1:] == ";") {
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
                    // up to the `;`: a `// comment` after it is not the name
                    let semi = index_of(rest, ";");
                    name = trim(rest);
                    if (semi >= 0) { name = trim(rest[:semi]); };
                    path = name;
                    let is_lib = !name_in(res_pkgs, name) && std_lib_index(name) >= 0 && !res_local_mod(name, base_dir);
                    if (name_in(res_pkgs, name) || is_lib) {
                        is_pkg = true;
                        // a hosted compile refuses std/kernel: `ndef`s into
                        // assembly that only a kernel image has
                        if (is_lib && name == "kernel" && !target_is_kernel()) {
                            puts("error: std/kernel is only available in kernel mode (ycc --target=kernel)\n");
                            exit(1);
                        };
                        // kernel mode refuses a std library unit that is a
                        // Linux syscall away from working (the same rule
                        // as for a spliced std source, below)
                        if (is_lib && target_is_kernel() && name_in(kernel_std_denied(), name)) {
                            puts("error: std/" + name + " is not available in kernel mode: " + kernel_std_why(name) + "\n");
                            exit(1);
                        };
                        if (!name_in(res_used, name)) { res_used += name; }
                        if (is_lib && !name_in(res_std_lib, name)) {
                            res_std_lib += name;
                        }
                    } else {
                        full = std_resolve(name, base_dir);
                        if (kernel_is_std_path(full, name)) {
                            if (target_is_kernel()) {
                                if (name_in(kernel_std_denied(), name)) {
                                    puts("error: std/" + name + " is not available in kernel mode: " + kernel_std_why(name) + "\n");
                                    exit(1);
                                };
                            } else if (name == "kernel") {
                                puts("error: std/kernel is only available in kernel mode (ycc --target=kernel)\n");
                                exit(1);
                            };
                        };
                    };
                };
                if (is_pkg) {
                } else if (len(name) == 0) {
                    out_lines += line;
                    ofile += lf;
                    oline += ln;
                    ogen += gen_at(mgen, i);
                } else if (len(full) == 0) {
                    // Fatal: carrying on only reported the module's names as
                    // undefined further down, after this message scrolled by.
                    puts("error: cannot find module '" + name + "' (import name; looks next to the importer and in std/)\n");
                    exit(1);
                } else {
                    let mod_src = source_read(full);
                    if (mod_src == none) {
                        puts("error: cannot open import '" + path + "' (resolved to '" + full + "')\n");
                        exit(1);
                    } else if (seen_has(seen, full) || (self_path != "" && full == self_path)) {
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
                        let sub = native_resolve_seen(unwrap(mod_src), mod_dir, depth + 1, seen, smods, len(seen), self_path, full);
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
                // The unit's own file: a placeholder line stands where the
                // import was (its text went into the splice, or nowhere for a
                // library), so a warning has a line of the file to point at.
                if (depth == 0 && !res_in_std && from_idx < 0 && len(name) > 0) {
                    out_lines += "";
                    ofile += lf;
                    oline += ln;
                    ogen += gen_at(mgen, i);
                    if (!import_used(lines, i, name)) {
                        res_unused += { msg: "unused import '" + name + "'", line: len(out_lines), col: 1 };
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
                    ogen += gen_at(mgen, i);
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

def directive_line_b(b: [byte], ls: long) -> bool {
    if (ls < len(b)) { b[ls] == '.' } else { false }
};

// `text_refs` (the text scan that answered this over a body's text) is gone:
// the items say all of it, and asking twice was the same answer twice. The
// text scans below stay, because arch_consts and the arch asm are still text.

// ── the same three questions, asked of a body's ITEMS ────────────────────

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
    let wire = insn.ir_layout(ir[at]);
    for w in 0..len(wire) {
        if (wire[w] == 'l') { out = ir_refs_push(out, lname(ir[at + 1 + w])); };
    };
    out
};

// ── dead global initializers ────────────────────────────────────────────
def cell_reads(ir: [long], out: [str]) -> [str] {
    let at = 0;
    while (at < len(ir)) {
        let f = ir[at];
        if (f < insn.IR_LABEL) {
            let form = insn.ir_form(f);
            let kinds = form.kinds;
            let wp = at + 1;
            for i in 0..len(kinds) {
                let k = kinds[i];
                if (k == insn.O_MEM || k == insn.O_MEM0) {
                    if (!((i == len(kinds) - 1) && form.mn == "mov")) {
                        let nm = lname(ir[wp + 4]);
                        if (len(nm) > 0) { out += nm; };
                    };
                } else if (k == insn.O_LBL) {
                    if (!((i == len(kinds) - 1) && form.mn == "mov")) {
                        let nm = lname(ir[wp]);
                        if (len(nm) > 0) { out += nm; };
                    };
                };
                wp = wp + insn.ir_kind_words(k);
            };
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
    if (target_is_kernel()) { return ir; };

    let out: [long] = [];
    let at = 0;
    let keep_from = 0;
    let skipping = "";
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
    if (!dropped) { return ir; };
    if (len(skipping) == 0) { out += ir[keep_from:len(ir)]; };
    out
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
            for ki in 0..len(kinds) {
                let k = kinds[ki];
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
            };
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

// ── the arch prelude, shaken by blocks ──────────────────────────────────
type PBlk = { name: str, falls: bool, refs: [str], ir: [long], blob: str, txt: [str] };
type PBlocks = { blks: [PBlk], ix: [AsmLabel] };
// The kept prelude: its items (and the raw lines their IR_TEXT items index),
// every reference the kept blocks make, and the per-block [name, direct refs]
// the --gc analysis closes over.
type PShake = { ir: [long], txt: [str], refs: [str], bnames: [str], brefs: [[str]] };

def check_os_call_names(blks: [PBlk], which: str) -> [PBlk] {
    let labels: [str] = [];
    blks.foreach((e) => {
        let bk: PBlk = e;
        if (bk.name != "") { labels += bk.name; };
    });
    types.os_call_names().foreach((e) => {
        let found = false;
        for k in 0..len(labels) {
            if (labels[k] == e) { found = true; };
        };
        if (!found) {
            puts("error: os_call_names lists '" + e
            + "', which the arch lines do not define ("
            + (if (which == "win") { "src/y/arch/wsys.s, wproc.s, wnet.s, wcon.s" } else if (which == "kernel") { "src/y/arch/prelude.s, kernel.s" } else { "src/y/arch/prelude.s" })
            + ")\n");
            exit(1);
        };
    });
    blks
};

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

// `lines` (one per element, labels at column 0) as blocks.
def arch_blocks(lines: [str]) -> [PBlk] {
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
    let out: [PBlk] = [];
    let nb = len(starts);
    for b in 0..nb {
        let lo = starts[b];
        let hi = len(lines);
        if (b + 1 < nb) { hi = starts[b + 1]; };
        let nm: str = names[b];
        let ir: [long] = [];
        let txt: [str] = [];
        for i in lo..hi {
            let l: str = lines[i];
            if (i == lo && nm != "" && arch_label_name(l) == nm) {
                ir = insn.ir_push(ir, insn.IR_LABEL, labels.lbl_new(nm), 0, 0, 0, 0, 0, 0);
            } else {
                let it = asm.ir_parse_line(l);
                if (len(it) > 0) {
                    ir += it;
                } else {
                    txt += l;
                    ir = insn.ir_push(ir, insn.IR_TEXT, len(txt) - 1, 0, 0, 0, 0, 0, 0);
                };
            };
        };
        out += { name: nm, falls: lines_fall(lines, lo, hi), refs: lines_refs(lines, lo, hi), ir: ir, blob: "", txt: txt };
    };
    out
};

def arch_index(blks: [PBlk]) -> PBlocks {
    let names: [str] = [];
    blks.foreach((e) => {
        let bk: PBlk = e;
        names += bk.name;
    });
    { blks: blks, ix: namemap_build(names) }
};

// `blks` with each block a substitution names replaced by the blocks of its
// lines (`subs`: [name, line, line, ...] each) -- the --gc stubs and the
// --gc=stress cycle (arch_x64.y).
def arch_blocks_sub(blks: [PBlk], subs: [[str]]) -> [PBlk] {
    let out: [PBlk] = [];
    blks.foreach((e) => {
        let bk: PBlk = e;
        let at = -1;
        subs.foreach((sb, si) => {
            if (sb[0] == bk.name) { at = si; };
        });
        if (at < 0) {
            out += bk;
        } else {
            let sl = subs[at];
            out += arch_blocks(sl[1:len(sl)]);
        };
    });
    out
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
            let tk = tok_at_b(l, lb, s, len(lb));
            if (tk == "ret" || tk == "jmp" || tk == "syscall") { falls = false; };
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
    let blks = pb.blks;
    let nb = len(blks);
    let keep: [bool] = [];
    let scanned: [bool] = [];
    let k = 0;
    while (k < nb) {
        let bk: PBlk = blks[k];
        keep += len(bk.name) == 0;
        scanned += false;
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
                let bk: PBlk = blks[b];
                if (b + 1 < nb && bk.falls) { keep[b + 1] = true; };
                bk.refs.foreach((e) => {
                    let idx = namemap_get(pb.ix, e);
                    if (idx >= 0) { keep[idx] = true; };
                });
            };
        };
    };
    let ir: [long] = [];
    let txt: [str] = [];
    let out: [str] = [];
    let knames: [str] = [];
    let krefs: [[str]] = [];
    k = 0;
    while (k < nb) {
        if (keep[k]) {
            let bk: PBlk = blks[k];
            // the block's IR_TEXT items index its own lines: moved past the
            // lines already taken
            let base = len(txt);
            txt += bk.txt;
            let bir = bk.ir;
            if (len(bir) == 0 && len(bk.blob) > 0) { bir = unpack_body(bk.blob); };
            let at = 0;
            while (at < len(bir)) {
                let f = bir[at];
                if (f == insn.IR_TEXT) {
                    ir = insn.ir_push(ir, f, bir[at + 1] + base, 0, 0, 0, 0, 0, 0);
                } else {
                    ir = insn.ir_push(ir, f, bir[at + 1], bir[at + 2], bir[at + 3], bir[at + 4], bir[at + 5], bir[at + 6], bir[at + 7]);
                };
                at += insn.IR_W;
            };
            out += bk.refs;
            knames += bk.name;
            krefs += [bk.refs];
        };
        k++;
    };
    { ir: ir, txt: txt, refs: out, bnames: knames, brefs: krefs }
};

def prelude_with(core: [PBlk], threads: bool, mathasm: bool, regions: bool) -> PBlocks {
    let out: [PBlk] = core;
    if (threads) { out = out + arch_set(target_info(res_target).threads); };
    if (mathasm) { out = out + arch_set("math"); };
    if (regions) {
        let rs = arch_set("regions");
        // Without a collector automatic arenas must keep reclaiming even
        // after their usual 32 MiB spill threshold.
        if (gc_mode == 2 && !gc_stress) {
            rs = arch_blocks_sub(rs, [["y_region_spill", "y_region_spill:", "    xor %eax, %eax", "    ret"],
                ["y_region_roots", "y_region_roots:", "    ret"]]);
        };
        out = out + rs;
    };
    arch_index(out)
};

// The block set `which` -- "linux", "win" or "kernel" (the prelude for that
// target), "wselftest", "threads" ("wthreads" on Windows), "math", "regions" -- from the std pack when this
// compile read one (arch_pack), else built from the assembly text. Built once
// per process either way.
let arch_pack = "";
let arch_cache_names: [str] = [];
let arch_cache_sets: [[PBlk]] = [];

def arch_set(which: str) -> [PBlk] {
    let at = -1;
    let i = 0;
    while (i < len(arch_cache_names)) {
        if (arch_cache_names[i] == which) { at = i; };
        i++;
    };
    if (at >= 0) {
        arch_cache_sets[at]
    } else {
        let got = arch_unpack(arch_pack, "arch." + which);
        let blks: [PBlk] = [];
        if (got.ok) {
            blks = got.blks;
        } else {
            blks = arch_blocks(arch_lines_of(which));
            // the names are checked where a prelude is built from text, once: the
            // pack writer checks the ones the pack carries, so a compile that reads
            // the pack does not pay for it (it was names x labels on every compile)
            if (which == "linux" || which == "win" || which == "kernel" || which == "web") { blks = check_os_call_names(blks, which); };
        };
        arch_cache_names += which;
        arch_cache_sets += [blks];
        blks
    }
};

// The lines of block set `which`, from its files on disk (arch_src): only a
// compile with no std pack, or the one writing the pack, reads them.
def arch_lines_of(which: str) -> [str] {
    let texts: [str] = [];
    arch.arch_set_files(which).foreach((f) => {
        texts += arch_src(f);
    });
    arch.arch_set_lines(which, texts)
};

// src/y/arch/<name>.s, searched like a std source (std_lib_path): in the
// working directory's checkout, then beside the compiler. None is a hard
// error: no program links without the runtime.
def arch_src(name: str) -> str {
    let cands: [str] = [];
    cands += "src/y/arch/" + name + ".s";
    let d = self_dir();
    if (len(d) > 0) {
        cands += d + "/arch/" + name + ".s";
        cands += d + "/src/y/arch/" + name + ".s";
        cands += d + "/../src/y/arch/" + name + ".s";
    };
    let out = "";
    let found = false;
    let i = 0;
    while (!found && i < len(cands)) {
        let t = fs.read_file(cands[i]);
        if (!(t == none)) {
            out = unwrap(t);
            found = true;
        };
        i = i + 1;
    };
    if (!found) {
        puts("error: the arch runtime '" + name + ".s': not in this compiler's std pack, and no src/y/arch/" + name + ".s beside it or in the working directory\n");
        exit(1);
    };
    out
};

// This target's prelude (its os_call names were checked when it was built, arch_set).
def arch_core() -> [PBlk] {
    let core: [PBlk] = [];
    if (target_is_windows()) {
        core = arch_set("win");
        // the NT syscall self-test (arch/wselftest.s), which _start calls
        core = core + arch_set("wselftest");
    } else if (target_is_web()) {
        core = arch_set("web");
    } else if (target_is_kernel()) {
        core = arch_set("kernel");
    } else {
        core = arch_set("linux");
    };
    if (target_is_aarch64()) {
        core = arch_blocks_sub(core, [["y_host_machine", "y_host_machine:", "    mov $183, %rax", "    ret"]]);
        core = a64_raw_gc_blocks(core);
    };
    core
};

// Raw AArch64 syscall numbers need the same collector parking protocol as
// named runtime calls. Derive that wrapper from the shared runtime IR so its
// register saves and stop-the-world transitions cannot drift apart.
def a64_raw_gc_blocks(core: [PBlk]) -> [PBlk] {
    let names = ["y_gc_syscall", "ygsc_threaded", "ygsc_check", "ygsc_go", "ygsc_out"];
    let renamed: [str] = [];
    let m = asm.labmap_new(16);
    for i in 0..len(names) {
        renamed += "y_a64_raw_" + names[i];
        m = asm.labmap_put(m, names[i], 1, i).map;
    };
    let extra: [PBlk] = [];
    foreach (b in core) {
        let ent = asm.labmap_get(m, b.name);
        if (ent.sec < 0) { continue; };
        let body = b.ir;
        if (len(body) == 0) { body = unpack_body(b.blob); };
        let ir: [long] = [];
        ir += body;
        ir = ir_relabel(ir, m, renamed);
        let at = 0;
        while (at < len(ir)) {
            if (ir[at] == insn.IR_LABEL) {
                ir[at + 1] = ir_relabel_one(ir[at + 1], m, renamed);
            } else if (ir[at] == insn.F_SYSCALL) {
                ir[at] = insn.F_CALL_L;
                ir[at + 1] = lbl_new("y_a64_raw_syscall");
            };
            at += insn.IR_W;
        };
        let refs: [str] = [];
        foreach (r in b.refs) {
            let v = asm.labmap_get(m, r);
            refs += if (v.sec > 0) { renamed[v.off] } else { r };
        };
        refs += "y_a64_raw_syscall";
        extra += { name: renamed[ent.off], falls: b.falls, refs: refs, ir: ir, blob: "", txt: b.txt };
    };
    core + extra
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
    // A kernel image has no `_start` among the program's bodies: that name
    // belongs to the 32-bit trampoline in the header, and the program's top
    // level is `y_kernel_main`, which the trampoline calls.
    if ((namemap_get(namemap_build(labels), "y_kernel_main")) >= 0) {
        roots += "y_kernel_main";
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

def strip_type(t: Type, imports: [str]) -> Type {
    if (t.k == K.tname) {
        let name: TName = t;
        let out: Type = { k: K.tname, name: strip_ns_name(name.name, imports) };
        out
    } else if (t.k == K.tpack || t.k == K.tref || t.k == K.tinfer) {
        t
    } else {
        type_map_children(t, (child: Type) => strip_type(child, imports))
    }
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
    } else if (k == K.decl) {
        let decl: Decl = node;
        strip_decl(decl, imports)
    } else if (k == K.func) {
        let func: Func = node;
        // `ppos` through: stripping a namespace rewrites names and types, never
        // positions, and a parameter's position is where an editor points at it.
        normnode({ k: K.func, params: func.params, ptypes: strip_type_list(func.ptypes, imports), ret: strip_type(func.ret, imports), body: strip_ns(func.body, imports), line: func.line, col: func.col, defs: func.defs, label: func.label, ppos: func.ppos })
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
    } else if (k == K.rectest || k == K.narrow || k == K.matchend) {
        node
    } else {
        node_map_children(node, (child: Node) => strip_ns(child, imports))
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
type Slot = { name: str, kind: long, off: long, label: long, mark: str, typ: Type };
type ArrTy = TOf | TFix;
type EmitMain = { params: [str], ptypes: [Type], ret: Type, body: Node, line: long, col: long };
type EmitFunc = Func | EmitMain;
type EmitSt = { ir: [long], txt: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [Slot], slots: long, temp: long, self_label: long, end_label: long, fns: FnTab, bodies: [[long]], btext: [[str]], blabels: [str] };
// The state after making a label (next_loc, ty_desc), and the label's id.
type StLbl = { st: EmitSt, label: long };

def st_new() -> EmitSt {
    { ir: [], txt: [], rodata: [], uid: 1, fuid: 0, loc: 1, env: [],
        slots: 0, temp: 0, self_label: -1, end_label: -1, fns: fntab_of([], []), bodies: [], btext: [],
        blabels: [] }
};

let frame_max = 0;
def st_with(st: EmitSt, b: [long], txt: [str]) -> EmitSt {
    { ...st, ir: b, txt: txt }
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
        { ...st, slots: n }
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
        { ...st, temp: n }
    }
};

// One instruction: form `f` and its seven field words (see ir.y). The shapes
// are written out at the call sites, so a site reads as the instruction it
// emits -- `emit_insn(st, insn.F_MOV_0_R, insn.R_RBP, -1, 1, -24, -1, insn.R_RAX, 64)`
// is `mov -24(%rbp), %rax`.
// Apply local IR folds before appending an instruction.
def emit_insn(st: EmitSt, f: long, a: long, b: long, c: long, d: long, e: long, g: long, h: long) -> EmitSt {
    if (f == insn.F_MOV_D_R && is_reload(st.ir, a, b, c, d, e, g, h)) {
        st
    } else if (f == insn.F_POP_R && a == insn.R_RAX && b == 64 && pop_fold(st.ir)) {
        st
    } else if (f == insn.F_PUSH_R && a == insn.R_RCX && b == 64 && repush_fold(st.ir)) {
        st
    } else if (f == insn.F_JGE_L && lname(a) == "y_oob" && oob_fold(st.ir)) {
        insn.ir_push(st.ir, insn.F_JAE_L, a, b, c, d, e, g, h);
        st
    } else {
        insn.ir_push(st.ir, f, a, b, c, d, e, g, h);
        st
    }
};

def push_fold(ir: [long]) -> [long] {
    let w = insn.IR_W;
    let n = len(ir);
    let wp = 0;
    let at = 0;
    while (at < n) {
        let next = at + w;
        let folded = false;
        if (pushable(ir, at)) {
            let j = at + w;
            while (j < n && ir[j] == insn.IR_LOC) { j = j + w; };
            if (j < n && ir[j] == insn.F_PUSH_R && ir[j + 1] == insn.R_RAX && ir[j + 2] == 64) {
                let k = j + w;
                while (k < n && ir[k] == insn.IR_LOC) { k = k + w; };
                if (k < n && rax_dead_at(ir, k)) {
                    // the push, with the load's operand; then the markers
                    let f = ir[at];
                    let item: [long] = [];
                    if (f == insn.F_MOV_I_R) {
                        item = [insn.F_PUSH_I, ir[at + 1], 0, 0, 0, 0, 0, 0];
                    } else {
                        // `(%base)` keeps -1 in its displacement ("none
                        // written"); the push's operand writes one, so 0
                        let d = if (f == insn.F_MOV_0_R) { 0 } else { ir[at + 4] };
                        item = [insn.F_PUSH_M, ir[at + 1], ir[at + 2], ir[at + 3], d, ir[at + 5], 0, 0];
                    };
                    let locs: [long] = [];
                    let q = at + w;
                    while (q < k) {
                        if (ir[q] == insn.IR_LOC) { for i in 0..w { locs += ir[q + i]; }; };
                        q = q + w;
                    };
                    for i in 0..w { ir[wp + i] = item[i]; };
                    wp = wp + w;
                    for i in 0..len(locs) { ir[wp + i] = locs[i]; };
                    wp = wp + len(locs);
                    next = k;
                    folded = true;
                };
            };
        };
        if (!folded) {
            if (wp != at) { for i in 0..w { ir[wp + i] = ir[at + i]; }; };
            wp = wp + w;
        };
        at = next;
    };
    while (len(ir) > wp) { ir.pop(); };
    ir
};

// A load into %rax a push can take instead: `mov $imm32, %rax` or a 64-bit
// `mov mem, %rax` whose address is not %rsp-relative.
def pushable(ir: [long], p: long) -> bool {
    let f = ir[p];
    if (f == insn.F_MOV_I_R) {
        ir[p + 2] == insn.R_RAX && ir[p + 3] == 64 && ir[p + 1] >= -2147483648 && ir[p + 1] <= 2147483647
    } else if (f == insn.F_MOV_D_R || f == insn.F_MOV_P_R || f == insn.F_MOV_0_R) {
        ir[p + 6] == insn.R_RAX && ir[p + 7] == 64 && ir[p + 1] != insn.R_RSP && ir[p + 2] != insn.R_RSP
    } else {
        false
    }
};

// The runtime helpers the emitter calls most that take every argument on the
// stack and do not read %rax before writing it (each begins `push %rbp`, or
// loads %rax from the stack). Others are not assumed: some take arguments in
// registers. A helper on this list must keep that entry.
let STACK_ARGS: [str] = ["y_str_cat", "y_str_eq", "y_arr_push", "y_str_slice", "y_long_tostr",
    "y_arr_extend", "y_put_hstr", "y_arr_slice", "y_str_index", "y_str_join", "y_arr_cat",
    "y_str_app", "y_str_trim"];

// Does the instruction at p overwrite %rax without reading it first? A load
// into %rax that does not read it, or a direct call to a Y function or a
// STACK_ARGS helper: a callee takes its arguments (and a closure its record)
// on the stack, so %rax is dead at the call and holds the result after it.
def rax_dead_at(ir: [long], p: long) -> bool {
    if (ir[p] == insn.F_CALL_L) {
        let nm = lname(ir[p + 1]);
        nm.starts_with("yfn_") || nm in STACK_ARGS
    } else {
        rax_load(ir, p, true)
    }
};

def oob_fold(ir: [long]) -> bool {
    let w = insn.IR_W;
    let pos: [long] = [];
    let p = len(ir) - w;
    while (p >= 0 && len(pos) < 5) {
        if (ir[p] != insn.IR_LOC) { pos += p; };
        p = p - w;
    };
    if (len(pos) < 3) { return false; };
    let c = pos[0];
    let x = if (ir[c] == insn.F_CMP_R_R && ir[c + 4] == 64) { ir[c + 3] } else if (ir[c] == insn.F_CMP_I_R && ir[c + 3] == 64) { ir[c + 2] }
        else if (ir[c] == insn.F_CMP_M_R && ir[c + 7] == 64) { ir[c + 6] } else { -1 };
    if (x < 0) { return false; };
    // pos[1..k] the loads between (k = 0..2), pos[k + 1] the js, pos[k + 2] the test
    let k = 0;
    let found = false;
    let go = true;
    while (go && !found && k <= 2 && k + 2 < len(pos)) {
        let j = pos[k + 1];
        let t = pos[k + 2];
        if (ir[j] == insn.F_JS_L && lname(ir[j + 1]) == "y_oob" && ir[t] == insn.F_TEST_R_R && ir[t + 1] == x
            && ir[t + 2] == 64 && ir[t + 3] == x && ir[t + 4] == 64) {
            found = true;
        } else if (k < 2) {
            let q = pos[k + 1];
            let f = ir[q];
            let between = f == insn.F_PUSH_R || ((f == insn.F_MOV_0_R || f == insn.F_MOV_D_R) && ir[q + 6] != x);
            if (between) { k = k + 1; } else { go = false; };
        } else {
            go = false;
        };
    };
    if (!found) { return false; };
    let start = pos[k + 2];
    let jsp = pos[k + 1];
    let tail = ir[start:len(ir)];
    while (len(ir) > start) { ir.pop(); };
    let at = 0;
    while (at < len(tail)) {
        if (start + at != start && start + at != jsp) {
            for i in 0..w { ir += tail[at + i]; };
        };
        at = at + w;
    };
    true
};

def repush_fold(ir: [long]) -> bool {
    let w = insn.IR_W;
    let s = len(ir) - w;
    while (s >= 0 && ir[s] == insn.IR_LOC) { s = s - w; };
    let p = s - w;
    while (p >= 0 && ir[p] == insn.IR_LOC) { p = p - w; };
    if (p < 0) { return false; };
    let f = ir[s];
    let store = f == insn.F_MOV_R_D || f == insn.F_MOV_R_0 || f == insn.F_MOVB_R_D || f == insn.F_MOVB_R_0;
    if (store && ir[s + 3] == insn.R_RCX && ir[s + 4] != insn.R_RSP && ir[p] == insn.F_POP_R && ir[p + 1] == insn.R_RCX
        && ir[p + 2] == 64) {
        ir[p] = insn.F_MOV_0_R;
        ir[p + 1] = insn.R_RSP;
        ir[p + 2] = -1;
        ir[p + 3] = 1;
        ir[p + 4] = 0;
        ir[p + 5] = -1;
        ir[p + 6] = insn.R_RCX;
        ir[p + 7] = 64;
        true
    } else {
        false
    }
};

// A load into %rax: `mov` from memory or an immediate, `lea`, `movzbq` --
// one instruction that writes %rax and reads nothing but memory. `first`: it
// must not read %rax either (the value the push saved is still in it), and no
// operand may be %rsp-relative (the push moved %rsp).
def rax_load(ir: [long], p: long, first: bool) -> bool {
    let f = ir[p];
    if (f == insn.F_MOV_I_R) {
        ir[p + 2] == insn.R_RAX && ir[p + 3] == 64
    } else if (f == insn.F_MOV_D_R || f == insn.F_MOV_0_R || f == insn.F_MOV_P_R || f == insn.F_MOV_M_R
            || f == insn.F_LEA_D_R || f == insn.F_LEA_M_R || f == insn.F_LEA_P_R
            || f == insn.F_MOVZBQ_D_R || f == insn.F_MOVZBQ_0_R || f == insn.F_MOVZBQ_M_R) {
        let bs = ir[p + 1];
        let ix = ir[p + 2];
        ir[p + 6] == insn.R_RAX && ir[p + 7] == 64 && bs != insn.R_RSP && ix != insn.R_RSP
            && !(first && (bs == insn.R_RAX || ix == insn.R_RAX))
    } else {
        false
    }
};

def pop_fold(ir: [long]) -> bool {
    let w = insn.IR_W;
    let pos: [long] = [];
    let p = len(ir) - w;
    while (p >= 0 && len(pos) < 5) {
        if (ir[p] != insn.IR_LOC) { pos += p; };
        p = p - w;
    };
    let m = if (len(pos) >= 3) { pos[0] } else { -1 };
    if (m < 0 || ir[m] != insn.F_MOV_R_R || ir[m + 1] != insn.R_RAX || ir[m + 2] != 64 || ir[m + 3] != insn.R_RCX
        || ir[m + 4] != 64) {
        return false;
    };
    // pos[1..k] the loads, pos[k] the first of them; pos[k + 1] the push
    let k = 0;
    let n = 1;
    let go = true;
    while (go && n <= 3 && n + 1 < len(pos)) {
        let q = pos[n + 1];
        if (!rax_load(ir, pos[n], false)) {
            go = false;
        } else if (ir[q] == insn.F_PUSH_R && ir[q + 1] == insn.R_RAX && ir[q + 2] == 64) {
            if (rax_load(ir, pos[n], true)) { k = n; };
            go = false;
        } else {
            n = n + 1;
        };
    };
    if (k == 0) { return false; };
    let start = pos[k + 1];
    let tail = ir[start:len(ir)];
    while (len(ir) > start) { ir.pop(); };
    let at = w;
    while (at < len(tail)) {
        if (start + at != m) {
            let f = tail[at];
            if (f != insn.IR_LOC) {
                // the load, into %rcx; a %rax it reads is the one the load
                // before it wrote, now in %rcx too
                if (f == insn.F_MOV_I_R) {
                    tail[at + 2] = insn.R_RCX;
                } else {
                    if (tail[at + 1] == insn.R_RAX) { tail[at + 1] = insn.R_RCX; };
                    if (tail[at + 2] == insn.R_RAX) { tail[at + 2] = insn.R_RCX; };
                    tail[at + 6] = insn.R_RCX;
                };
            };
            for i in 0..w { ir += tail[at + i]; };
        };
        at = at + w;
    };
    true
};

def rax_into_rcx(st: EmitSt) -> EmitSt {
    let ir = st.ir;
    let p = len(ir) - insn.IR_W;
    while (p >= 0 && ir[p] == insn.IR_LOC) { p = p - insn.IR_W; };
    if (p >= 0 && rax_load(ir, p, false)) {
        if (ir[p] == insn.F_MOV_I_R) { ir[p + 2] = insn.R_RCX; } else { ir[p + 6] = insn.R_RCX; };
        st
    } else {
        emit_insn(st, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_RCX, 64, 0, 0, 0)
    }
};

def is_reload(ir: [long], a: long, b: long, c: long, d: long, e: long, g: long, h: long) -> bool {
    if (g != insn.R_RAX || h != 64) { false } else {
        let p = len(ir) - insn.IR_W;
        while (p >= 0 && ir[p] == insn.IR_LOC) { p = p - insn.IR_W; };
        p >= 0 && ir[p] == insn.F_MOV_R_D && ir[p + 1] == insn.R_RAX && ir[p + 2] == 64
            && ir[p + 3] == a && ir[p + 4] == b && ir[p + 5] == c && ir[p + 6] == d && ir[p + 7] == e
    }
};

// A label definition (`yfn_3_foo:`), as an item carrying the label's id: the
// assembler takes the name from the table, and tree shaking compares ids.
def emit_label(st: EmitSt, id: long) -> EmitSt {
    emit_insn(st, insn.IR_LABEL, id, 0, 0, 0, 0, 0, 0)
};

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

// Does the function at this label pop its own arguments? A Y def's body does
// (`ret $8n`, emit_one_fn), so a call to one is not followed by the `add $8n,
// %rsp` it would otherwise need. A runtime y_ def and an asm label do not:
// assembly and the emitter's helper calls reach them and clean up after them.
def pops_args(label: long) -> bool {
    lname(label).starts_with("yfn_")
};

// The code of a function value made from a def that does not pop its n
// arguments: a closure call leaves them to the callee, so this pushes a copy,
// calls the def, and pops the originals itself.
def pop_thunk(st: EmitSt, label: long, n: long) -> StLbl {
    let ru = next_uid(st);
    st = ru.st;
    let tl = lbl_new(arch.arch_fn_label(ru.uid, "thunk"));
    let body: [long] = [];
    body = insn.ir_push(body, insn.IR_LABEL, tl, 0, 0, 0, 0, 0, 0);
    body = insn.ir_push(body, insn.F_PUSH_R, insn.R_RBP, 64, 0, 0, 0, 0, 0);
    body = insn.ir_push(body, insn.F_MOV_R_R, insn.R_RSP, 64, insn.R_RBP, 64, 0, 0, 0);
    for k in 0..n {
        body = insn.ir_push(body, insn.F_PUSH_M, insn.R_RBP, -1, 1, 16 + 8 * (n - 1 - k), -1, 0, 0);
    };
    body = insn.ir_push(body, insn.F_CALL_L, label, 0, 0, 0, 0, 0, 0);
    body = insn.ir_push(body, insn.F_MOV_R_R, insn.R_RBP, 64, insn.R_RSP, 64, 0, 0, 0);
    body = insn.ir_push(body, insn.F_POP_R, insn.R_RBP, 64, 0, 0, 0, 0, 0);
    body = insn.ir_push(body, insn.F_RET_I, 8 * n, 0, 0, 0, 0, 0, 0);
    let notxt: [str] = [];
    let bodies = st.bodies;
    bodies += [body];
    let btext = st.btext;
    btext += [notxt];
    let blabels = st.blabels;
    blabels += lname(tl);
    st = { ...st, bodies: bodies, btext: btext, blabels: blabels };
    { st: st, label: tl }
};

def next_uid(st: EmitSt) -> { st: EmitSt, uid: long } {
    let u = st.uid;
    st = { ...st, uid: st.uid + 1 };
    { st: st, uid: u }
};

// Only label allocation mutates the counter; emitted bodies still thread
// their buffers and frame state through EmitSt.
def next_loc(st: EmitSt) -> long {
    let id = lbl_fresh(arch.arch_loc_label(st.fuid, st.loc));
    st.loc++;
    id
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
const ENV_SCAN_MAX = 64;
const ENV_SCAN_BACK = 8;

// The index (a labmap: name -> slot), and the env id it describes.
let env_ix: [AsmLabel] = [];
let env_ix_id = 0;
let env_id = 0;

// Open a fresh env: the sentinel that carries its id (its off field).
def env_open(env: [Slot]) -> [Slot] {
    env_id++;
    env += { name: "", kind: SK.env, off: env_id, label: -1, mark: "", typ: normtype({ k: K.tnone }) };
    env
};

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
        let found: Slot = { name: "", kind: SK.none, off: 0, label: -1, mark: "", typ: normtype({ k: K.tnone }) };
        let fns = st.fns;
        let j = namemap_get(fns.ix, name);
        if (j >= 0) {
            let fe = fns.syms[j];
            found = { name: fe.name, kind: fns_kind(fe.label), off: 0, label: fns.ids[j], mark: "", typ: fe.typ };
        };
        found
    }
};

def env_define(st: EmitSt, name: str, kind: long, off: long, label: long, mark: str, typ: Type) -> EmitSt {
    let env = st.env;
    if (len(env) == 0) { env = env_open(env); };
    st.env += { name: name, kind: kind, off: off, label: label, mark: mark, typ: typ };
    env_index_add(env);
    let env = st.env;
    { ...st, env: env }
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
            if (e.kind == SK.none) {
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
        types.binary_result(bin.op, infer(st, bin.l), infer(st, bin.r))
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
            types.pointee_value(ptr.to)
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
        let dpk = types.pack_of(dt);
        if (dpk.k == K.tpack) {
            let dpf = types.pack_ftype(dpk, dot.key);
            if (dpf.k == K.tnone) { normtype({ k: K.tunk }) } else { types.pack_value_type(dpk, dpf) }
        } else if (dt.k == K.trec) {
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
            // `m.k` is the entry (types.y typeof_dot);
            // `m.length` is the count, as for an array or a string. The map's
            // own three fields are NOT reachable by dot -- `map$field` reads
            // those (see map_field).
            if (dot.key == "length") { normtype({ k: K.tlong }) }
            else { normtype(map.of) }
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

def infer_func_ret(t: Type) -> Type {
    if (t.k == K.tfunc) {
        let fn: TFunc = t;
        if (fn.ret.k != K.tnone) { return fn.ret; };
    };
    type_node({ k: K.tunk })
};

def infer_call(st: EmitSt, node: Call) -> Type {
    let callee = node.callee;
    if (callee.k == K.id) {
        let id: Leaf = callee;
        return infer_builtin(st, node, id.v);
    };
    if (callee.k == K.dot) {
        let dot: Dot = callee;
        let rt = infer(st, dot.obj);
        if (rt.k == K.tstr) { return types.str_method(dot.key).ret; };
        if (rt.k == K.tarr || rt.k == K.tarrfix) { return infer_arr_method(st, node, dot.key, rt); };
    };
    infer_func_ret(infer(st, callee))
};

def infer_option(st: EmitSt, node: Call, name: str) -> Type {
    let t = len(node.args) == 1 ? infer(st, node.args[0]) : type_node({k: K.tunk});
    if (name == "unwrap") {
        if (t.k == K.topt) { let opt: TOf = t; return opt.of; };
        return type_node({k: K.tunk});
    };
    if (name == "opt$val" && (t.k == K.tvoid || t.k == K.tunk || t.k == K.topt)) { return t; };
    type_node({k: K.topt, of: t})
};

def infer_map_part(st: EmitSt, node: Call, name: str) -> Type {
    let t = infer(st, node.args[0]);
    let element = type_node({k: K.tunk});
    if (t.k == K.tmap) {
        let map: TMap = t;
        element = map.of;
        if (name == "keys" || name == "map$keys") { element = map.key; };
        if (name == "map$boxes") { element = type_node({k: K.topt, of: element}); };
        if (name == "map$zidx") { element = type_node({k: K.tlong}); };
    } else if (name != "keys") { return element; };
    type_node({k: K.tarr, of: element})
};

def infer_block(st: EmitSt, node: Block) -> Type {
    let stmts: [Node] = node.stmts;
    if (len(stmts) == 0) {
        normtype({ k: K.tvoid })
    } else {
        stmts.foreach((s) => {
            if (s.k == K.decl) {
                let d: Decl = s;
                if (d.kind == "let" && env_find(st, d.name).kind == SK.none) {
                    if (len(st.env) == 0) { st.env = env_open(st.env); };
                    st.env += { name: d.name, kind: SK.temp, off: 0, label: -1, mark: "", typ: infer(st, d.v) };
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
def uses_argv(stmts: [Node]) -> bool {
    let reads: [str] = [];
    stmts.foreach((e) => {
        reads = fv_walk(e, reads, true);
    });
    name_in(reads, "argv")
};

// ── def collection (incl. hoisting) ────────────────────────────────────
type FnDef = { name: str, func: Func };

// One preorder traversal; callers choose what to collect and whether to enter functions.
const SCAN_DEFS = 0;
const SCAN_READS = 1;
const SCAN_BINDS = 2;
const SCAN_APPENDS = 3;
let fv_note = false;
let fv_funcs: [Node] = [];

def native_scan(node: Node, names: [str], defs: [FnDef], mode: long, deep: bool) -> void {
    let k = node.k;
    if (k == K.id) {
        let leaf: Leaf = node;
        if (mode == SCAN_READS && deep) { names += leaf.v; };
        return;
    };
    if (mode == SCAN_DEFS && k == K.decl) {
        let decl: Decl = node;
        if (decl.v.k == K.func) { let func: Func = decl.v; defs += {name: decl.name, func: func}; };
    } else if (mode == SCAN_READS && k == K.assign && deep) {
        let assign: Assign = node;
        names += assign.name;
    } else if (mode == SCAN_BINDS) {
        if (k == K.decl) { let decl: Decl = node; names += decl.name; }
        else if (k == K.func) { let func: Func = node; fv_bind_params(func.params, names); }
        else if (k == K.kw_foreach) { let loop: Foreach = node; names += loop.name; }
        else if (k == K.forrange) { let loop: ForRange = node; names += loop.name; };
    } else if (mode == SCAN_APPENDS) {
        if (k == K.func && !deep) { return; };
        if (k == K.opassign) {
            let assign: OpAssign = node;
            if (assign.op == "+" && assign.tgt.k == K.id) { let leaf: Leaf = assign.tgt; names += leaf.v; };
        } else if (k == K.addr) {
            let addr: Wrap = node;
            if (addr.e.k == K.id) { let leaf: Leaf = addr.e; names += "&" + leaf.v; };
        };
    };
    if (k == K.func) {
        if (mode == SCAN_READS) { if (fv_note) { fv_funcs += node; }; deep = true; };
        let func: Func = node;
        native_scan(func.body, names, defs, mode, deep);
    } else {
        node_each_child(node, (child: Node) => native_scan(child, names, defs, mode, deep));
    };
};

def native_scan_list(nodes: [Node], names: [str], defs: [FnDef], mode: long, deep: bool) -> void {
    foreach (node in nodes) { native_scan(node, names, defs, mode, deep); };
};

def collect_from_block(stmts: [Node], out: [FnDef]) -> [FnDef] {
    native_scan_list(stmts, [], out, SCAN_DEFS, true);
    out
};

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

// The region runtime (src/y/arch/regions.s), by the same rule: gen_region
// calls one of the two entry points, and nothing else reaches it.
def uses_regions(refs: [str]) -> bool {
    let i = 0;
    let found = false;
    while ((i < len(refs)) && (!found)) {
        let r: str = refs[i];
        let n = len(r);
        found = (n == 14 && r == "y_region_enter") || (n == 19 && r == "y_region_auto_enter");
        i++;
    };
    found
};

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
// The nested functions fv_walk passes, noted while fv_note is set (box_names).

def fv_walk(node: Node, out: [str], collect: bool) -> [str] {
    native_scan(node, out, [], SCAN_READS, collect);
    out
};

def fv_ids(node: Node, out: [str]) -> [str] {
    fv_walk(node, out, true)
};

def fv_binds(node: Node, out: [str]) -> [str] {
    native_scan(node, out, [], SCAN_BINDS, true);
    out
};

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
def fns_kind(label: str) -> long {
    // starts_with, not label[:3] == "yg_": the slice allocated a throwaway
    // string on every call, and this runs once per identifier emitted.
    if (label.starts_with("yg_")) { SK.global } else { SK.func }
};

// ── expression emission (value in %rax) ────────────────────────────────

let fold_ix: NameIx = parser.nameix_new(8);
let fold_lits: [Node] = [];

def fold_consts(stmts: [Node]) -> void {
    fold_ix = parser.nameix_new(8);
    fold_lits = [];
    let esc = types.escaped();
    foreach (s in stmts) {
        if (s.k == K.decl) {
            let decl: Decl = s;
            let v = decl.v;
            if (decl.kind == "const" && decl.typ.k == K.tnone && !(decl.name in esc)) {
                if (v.k == K.num) {
                    parser.nameix_put(fold_ix, decl.name, len(fold_lits));
                    fold_lits += v;
                } else if (v.k == K.rec) {
                    let rec: RecLit = v;
                    parser.nameix_put(fold_ix, decl.name, -2);
                    for i in 0..len(rec.keys) {
                        if (rec.vals[i].k == K.num) {
                            parser.nameix_put(fold_ix, decl.name + "." + rec.keys[i], len(fold_lits));
                            fold_lits += rec.vals[i];
                        };
                    };
                };
            };
        };
    };
};

// n, or the literal a folded const read stands for (fold_consts).
def as_num(n: Node) -> Node {
    if (len(fold_lits) == 0) { return n; };
    let k = n.k;
    let i = -1;
    if (k == K.id) {
        let id: Leaf = n;
        i = parser.nameix_get(fold_ix, id.v);
    } else if (k == K.dot) {
        let dot: Dot = n;
        let o = dot.obj;
        if (o.k == K.id) {
            let oid: Leaf = o;
            if (parser.nameix_get(fold_ix, oid.v) == -2) { i = parser.nameix_get(fold_ix, oid.v + "." + dot.key); };
        };
    };
    if (i >= 0) { fold_lits[i] } else { n }
};

def gen(st: EmitSt, node: Node) -> EmitSt {
    nest++;
    if (nest > MAX_NEST) { too_deep("an expression", node.line, node.col); };
    let r = gen_go(st, node);
    nest--;
    r
};

def gen_special_node(st: EmitSt, node: Node) -> EmitSt {
    let k = node.k;
    if (k == K.bool) {
        let lit: Leaf = node;
        if (lit.v == "true") {
            emit_insn(st, insn.F_MOV_I_R, 1, insn.R_RAX, 64, 0, 0, 0, 0)
        } else {
            emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0)
        }
    } else if (k == K.void) {
        emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0)
    } else if (k == K.id) {
        let f = as_num(node);
        if (f.k == K.num) {
            let lit: Leaf = f;
            gen_lit(st, lit)
        } else {
            let id: Leaf = node;
            gen_id(st, id)
        }
    } else if (k == K.deref) {
        let deref: Wrap = node;
        let dpt = infer(st, deref.e);
        st = gen(st, deref.e);
        gen_ptr_load(st, dpt)
    } else if (k == K.index) {
        let index: Index = node;
        // maps scan their keys; strings read a byte; arrays index directly
        let kbt = infer(st, index.arr);
        if (unfold(kbt).k == K.tmap) { gen_map_get(st, index, "opt") }
        else if (unfold(kbt).k == K.tstr) { gen_byte_at(st, n_call2("byte_at", index.arr, index.idx, index.line, index.col)) }
        else { gen_index(st, index) }
    } else if (k == K.narrow) {
        // the value, converted into the narrowed type's layout (a match
        // arm's binding: rectest checked its tag)
        let narrow: Narrow = node;
        let src = infer(st, narrow.e);
        st = gen(st, narrow.e);
        let dst = types.narrow_type(types.pat_subject(src, narrow.typ), narrow.typ);
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
    } else if (k == K.idxassign) {
        let assign: IdxAssign = node;
        if (unfold((infer(st, assign.arr))).k == K.tmap) { gen_map_set(st, assign) } else { gen_idxassign(st, assign) }
    } else if (k == K.dot) {
        let f = as_num(node);
        if (f.k == K.num) {
            let lit: Leaf = f;
            gen_lit(st, lit)
        } else {
            let dot: Dot = node;
            gen_dot(st, dot)
        }
    } else if (k == K.rec) {
        // record literal anywhere (let/call-arg): heap address in %rax.
        let rec: RecLit = node;
        gen_reclit(st, rec, { k: K.tnone })
    } else if (k == K.map) {
        // map literal: the {keys, vals, boxes} record, heap address in %rax.
        let map: RecLit = node;
        gen_maplit(st, map, true)
    } else if (k == K.arrrep) {
        // [v; n] anywhere (let/assign/call-arg): heap address in %rax.
        let rep: ArrRep = node;
        gen_arrrep(st, rep)
    } else if (k == K.func) {
        // Anonymous function literal in expression position.
        let func: Func = node;
        gen_func_literal(st, func)
    } else if (k == K.kw_break || k == K.kw_continue) {
        let leaf: Leaf = node;
        let label: str = leaf.v;
        let target = cont_label;
        if (k == K.kw_break) { target = brk_label; };
        let tdepth = len(loop_brks) - 1;
        if (label != "") {
            // The parser resolved the label to a loop depth (outermost is 0)
            // before rename.y could change the variable's name. A malformed
            // label only reaches here in a program the checker rejects.
            let depth = tolong(label) !;
            if (depth >= 0 && depth < len(loop_brks)) {
                if (k == K.kw_break) { target = loop_brks[depth]; }
                else { target = loop_conts[depth]; };
                tdepth = depth;
            };
        };
        st = gen_rg_leave_to(st, tdepth);
        emit_insn(st, insn.F_JMP_L, target, 0, 0, 0, 0, 0, 0)
    } else if (k == K.ret) {
        let ret: Wrap = node;
        st = gen_as(st, ret.e, cur_fn_ret(st));
        st = gen_rg_leave_to(st, -1);
        emit_insn(st, insn.F_JMP_L, st.end_label, 0, 0, 0, 0, 0, 0)
    } else {
        // Unreachable: the checker rejects everything else.
        emit(st, "    # INTERNAL: unhandled " + ktag(k) + " (checker drift)")
    }
};

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
    st = { ...st };
    st = emit_insn(st, insn.F_LEA_P_R, -1, -1, 1, 0, id, insn.R_RAX, 64);
    if (obf.lazy_on() && len(s) > 0) {
        // The literal lives in the lazy data pages. Touch one byte per page it
        // spans so the page is decrypted before a syscall reads it (the kernel
        // answers a protected user page with EFAULT, not a signal).
        let k = 0;
        while (k < len(s)) {
            st = emit_insn(st, insn.F_MOVZBQ_D_R, insn.R_RAX, -1, 1, k, -1,
                insn.R_R11, 64);
            k += 4096;
        };
    };
    st
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
        if (e.kind == SK.none) {
            emit(st, "    # INTERNAL: undefined " + node.v)
        } else if (e.kind == SK.func) {
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
                let cl = e.label;
                let na = len(fn_args_of(e.typ));
                if (na > 0 && !pops_args(cl)) {
                    let th = pop_thunk(st, cl, na);
                    st = th.st;
                    cl = th.label;
                };
                gen_make_closure(st, cl, [])
            }
        } else if (e.kind == SK.global) {
            // An appendable global gives up its buffer on every read
            // (see gen_sappend).
            if (e.typ.k == K.tstr) {
                let oe = env_find(st, node.v + "#o");
                if (oe.kind == SK.none) { } else {
                    st = emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
                    st = emit_insn(st, insn.F_MOV_R_P, insn.R_RAX, 64, -1, -1, 1, 0, oe.label);
                };
            }
            emit_insn(st, insn.F_MOV_P_R, -1, -1, 1, 0, e.label, insn.R_RAX, 64)
        } else if (e.kind == SK.own) {
            // an appendable string: a read may let its buffer escape, so
            // the companion is cleared (see gen_sappend)
            st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, e.off, -1, insn.R_RAX, 64);
            emit_insn(st, insn.F_MOV_I_D, 0, insn.R_RBP, -1, 1, e.off - 8, -1, 0)
        } else if (e.kind == SK.capture) {
            let idx = leading_long(e.mark);
            st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, e.off, -1, insn.R_RCX, 64);
            st = emit_insn(st, insn.F_MOV_D_R, insn.R_RCX, -1, 1, 8 * (idx + 1), -1, insn.R_RAX, 64);
            emit_insn(st, insn.F_MOV_0_R, insn.R_RAX, -1, 1, -1, -1, insn.R_RAX, 64)
        } else if (e.kind == SK.box) {
            // A captured variable's shared cell; the slot holds its pointer.
            st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, e.off, -1, insn.R_RAX, 64);
            emit_insn(st, insn.F_MOV_0_R, insn.R_RAX, -1, 1, -1, -1, insn.R_RAX, 64)
        } else {
            emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, e.off, -1, insn.R_RAX, 64)
        }
    }
};

// ── closures ───────────────────────────────────────────────────────────

// The cell pointer for a capture, in %rax. Every capture slot holds a
// heap BOX pointer (see box_capture) — through a closure record or through
// a "box" binding alike.
def gen_cap_ptr(st: EmitSt, name: str) -> EmitSt {
    let e = env_find(st, name);
    if (e.kind == SK.capture) {
        // NOTE: the index rides in `label` (see gen_id's capture arm).
        let pidx = leading_long(e.mark);
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, e.off, -1, insn.R_RCX, 64);
        emit_insn(st, insn.F_MOV_D_R, insn.R_RCX, -1, 1, 8 * (pidx + 1), -1, insn.R_RAX, 64)
    } else {
        emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, e.off, -1, insn.R_RAX, 64)
    }
};

def box_capture(st: EmitSt, name: str) -> EmitSt {
    let e = env_find(st, name);
    if (e.kind == SK.box || e.kind == SK.capture) {
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
        let st2 = { ...st, slots: st.slots + 1 };
        env_define(st2, name, SK.box, boff, -1, "", e.typ)
    }
};

def box_names(func: EmitFunc) -> [str] {
    let none: [Node] = [];
    fv_funcs = none;
    fv_note = true;
    let reads = fv_walk(func.body, [], false);
    fv_note = false;
    let out: [str] = [];
    if (len(reads) == 0) { return out; };
    let funcs = fv_funcs;
    foreach (f in funcs) {
        let fnode: Func = f;
        let binds = fv_binds(f, []);
        foreach (n in fv_walk(fnode.body, [], true)) {
            if (!name_in(binds, n) && !name_in(out, n)) { out += n; };
        };
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
        if (e.kind == SK.frame) {
            more = false;
        } else if (e.kind == SK.boxmark && e.mark == name) {
            want = true;
            more = false;
        }
        i = i - 1;
    };
    if (want) { box_capture(st, name) } else { st }
};

// ── owned strings: `s += x` in place ──────────────────────────────────

// Every `+=` id target in a subtree, plus "&" + each name whose address
// is taken. With `deep` false nested functions are skipped: each gets its
// own walk, and a variable one of them touches is captured (boxed).
def app_walk(node: Node, out: [str], deep: bool) -> [str] {
    native_scan(node, out, [], SCAN_APPENDS, deep);
    out
};

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
        if (e.kind == SK.frame) {
            more = false;
        } else if (e.kind == SK.appmark && e.mark == name) {
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
    let st2 = { ...st, slots: st.slots + 2 };
    env_define(st2, name, SK.own, off, -1, "", t)
};

// A statement nobody takes the value of. `s += x` on an appendable string
// (an "own" local, or a global with a companion cell) goes through
// gen_sappend (the checker made x a str or a byte); anything else is plain gen.
def gen_stmt(st: EmitSt, node: Node) -> EmitSt {
    if (node.k == K.id) {
        let id: Leaf = node;
        if ((env_find(st, id.v)).kind == SK.local) { st } else { gen(st, node) }
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
            if (e.kind == SK.own) {
                gen_sappend(st, assign.v, -1, e.off, -1, e.off - 8)
            } else if (e.kind == SK.global && e.typ.k == K.tstr) {
                let oe = env_find(st, id.v + "#o");
                if (oe.kind == SK.none) {
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
    if (infer(st, v).k == K.tbyte) {
        // `s += b` appends the character, as `s + b` does (gen_cat)
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = gen_runtime_call(st, "y_str_chr", 8);
    };
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_P_R, ca[0], ca[1], ca[2], ca[3], ca[4],
        insn.R_RAX, 64);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen_runtime_call(st, "y_str_app", 24);
    st = emit_insn(st, insn.F_MOV_R_P, insn.R_RAX, 64, va[0], va[1], va[2],
        va[3], va[4]);
    emit_insn(st, insn.F_MOV_R_P, insn.R_RAX, 64, ca[0], ca[1], ca[2], ca[3],
        ca[4])
};

def gen_region(st: EmitSt, node: Call, name: str) -> EmitSt {
    let args: [Node] = node.args;
    let kind = if (name == "heap$") { 2 } else if (name == "region$auto") { 1 } else { 0 };
    let n = if (kind == 2) { 4 } else { 8 };
    let s0 = st.slots;
    let off = (s0 + n) * -8;
    st = { ...st, slots: s0 + n };
    if (kind == 2) {
        st = emit_insn(st, insn.F_MOV_I_D, 0, insn.R_RBP, -1, 1, off, -1, 0);
        st = emit_insn(st, insn.F_LEA_D_R, insn.R_RBP, -1, 1, off, -1, insn.R_RDI, 64);
        st = emit_insn(st, insn.F_MOV_P_R, -1, -1, 1, 0, lbl_new("y_rg_henter"), insn.R_RAX, 64);
        let r = next_loc(st);
        st = emit_jz(st, r);
        st = emit_insn(st, insn.F_CALL_IND, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_label(st, r);
    } else {
        st = emit_insn(st, insn.F_LEA_D_R, insn.R_RBP, -1, 1, off, -1, insn.R_RDI, 64);
        st = emit_insn(st, insn.F_CALL_L, lbl_new(if (kind == 1) { "y_region_auto_enter" } else { "y_region_enter" }), 0, 0, 0, 0, 0, 0);
    };
    rg_kinds += kind;
    rg_offs += off;
    rg_loops += len(loop_brks);
    st = gen_discard(st, args[0]);
    rg_kinds = rg_kinds[0:len(rg_kinds) - 1];
    rg_offs = rg_offs[0:len(rg_offs) - 1];
    rg_loops = rg_loops[0:len(rg_loops) - 1];
    st = gen_rg_leave(st, kind, off);
    st_slots(st, s0)
};

// Leave one region (kind 0, 1) or heap block (2) whose record is at off(%rbp).
def gen_rg_leave(st: EmitSt, kind: long, off: long) -> EmitSt {
    if (kind == 2) {
        let r = next_loc(st);
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, off, -1, insn.R_RAX, 64);
        st = emit_jz(st, r);
        st = emit_insn(st, insn.F_LEA_D_R, insn.R_RBP, -1, 1, off, -1, insn.R_RDI, 64);
        st = emit_insn(st, insn.F_MOV_P_R, -1, -1, 1, 0, lbl_new("y_rg_hleave"), insn.R_RAX, 64);
        st = emit_insn(st, insn.F_CALL_IND, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        emit_label(st, r)
    } else {
        st = emit_insn(st, insn.F_LEA_D_R, insn.R_RBP, -1, 1, off, -1, insn.R_RDI, 64);
        emit_insn(st, insn.F_CALL_L, lbl_new("y_region_leave"), 0, 0, 0, 0, 0, 0)
    }
};

// A jump to the loop at depth `depth` (an index into loop_brks; -1 for a
// `return`) leaves every region and heap block opened inside that loop's body,
// innermost first. %rax is kept: it holds a `return`'s value.
def gen_rg_leave_to(st: EmitSt, depth: long) -> EmitSt {
    let i = len(rg_kinds) - 1;
    let saved = false;
    while (i >= 0 && rg_loops[i] > depth) {
        if (!saved) {
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            saved = true;
        };
        st = gen_rg_leave(st, rg_kinds[i], rg_offs[i]);
        i--;
    };
    if (saved) { st = emit_insn(st, insn.F_POP_R, insn.R_RAX, 64, 0, 0, 0, 0, 0); };
    st
};

def auto_is(body: Node) -> bool {
    if (body.k == K.block) {
        let b: Block = body;
        if (len(b.stmts) > 0 && b.stmts[0].k == K.call) {
            let c: Call = b.stmts[0];
            if (c.callee.k == K.id) {
                let leaf: Leaf = c.callee;
                leaf.v == "region$auto"
            } else { false }
        } else { false }
    } else { false }
};

// The body a loop runs: the block inside `region$auto` when it has one.
def auto_inner(body: Node) -> Node {
    if (auto_is(body)) {
        let b: Block = body;
        let c: Call = b.stmts[0];
        c.args[0]
    } else { body }
};

def gen_rg_loop_enter(st: EmitSt, body: Node) -> EmitSt {
    if (auto_is(body)) {
        let s0 = st.slots;
        let off = (s0 + 8) * -8;
        st = { ...st, slots: s0 + 8 };
        st = emit_insn(st, insn.F_LEA_D_R, insn.R_RBP, -1, 1, off, -1, insn.R_RDI, 64);
        st = emit_insn(st, insn.F_CALL_L, lbl_new("y_region_auto_enter"), 0, 0, 0, 0, 0, 0);
        rg_kinds += 1;
        rg_offs += off;
        rg_loops += len(loop_brks);
        st
    } else { st }
};

def gen_rg_tick(st: EmitSt, body: Node) -> EmitSt {
    if (auto_is(body)) {
        st = emit_insn(st, insn.F_LEA_D_R, insn.R_RBP, -1, 1, rg_offs[len(rg_offs) - 1], -1, insn.R_RDI, 64);
        emit_insn(st, insn.F_CALL_L, lbl_new("y_region_tick"), 0, 0, 0, 0, 0, 0)
    } else { st }
};

def gen_rg_loop_leave(st: EmitSt, body: Node) -> EmitSt {
    if (auto_is(body)) {
        let off = rg_offs[len(rg_offs) - 1];
        rg_kinds = rg_kinds[0:len(rg_kinds) - 1];
        rg_offs = rg_offs[0:len(rg_offs) - 1];
        rg_loops = rg_loops[0:len(rg_loops) - 1];
        gen_rg_leave(st, 1, off)
    } else { st }
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
    st = gen_runtime_call(st, "y_range", 8);
    // range() is [long]: one mark per array, which pays for itself the first
    // time a cycle walks past it (unlike marking per PUSH, which costs five
    // instructions per element).
    mark_pf_arr(st, type_node({ k: K.tlong }))
};

// Push a slice's source, lower bound and upper bound in evaluation order.
// Missing bounds are zero and the source length (array and string headers agree).
def gen_slice_bounds(st: EmitSt, arr: Node, lo: Node, hi: Node) -> EmitSt {
    st = gen_push_value(st, arr);
    st = lo.k == K.void ? emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0) : gen(st, lo);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    if (hi.k == K.void) {
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RSP, -1, 1, 8, -1, insn.R_RAX, 64);
        st = emit_insn(st, insn.F_MOV_0_R, insn.R_RAX, -1, 1, -1, -1, insn.R_RAX, 64);
    } else { st = gen(st, hi); };
    emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0)
};

// Half-open, clamped slices allocate a new array or substring.
def gen_slice(st: EmitSt, node: Slice) -> EmitSt {
    let typ = infer(st, node.arr);
    let string = typ.k == K.tstr;
    st = gen_slice_bounds(st, node.arr, node.lo, node.hi);
    if (!string) {
        st = emit_push_imm(st, arr_elem_bytes(typ));
    };
    st = gen_runtime_call(st, string ? "y_str_slice" : "y_arr_slice", string ? 24 : 32);
    if (string) { st } else { mark_pf_arr(st, arr_elem_of(typ)) }
};

// a[lo:hi] = src: y_arr_setslice{1,8} (rt.y) check the range and the
// length, then copy src's elements in. Evaluation order: a, lo, hi, src.
def gen_sliceassign(st: EmitSt, node: SliceAssign) -> EmitSt {
    let esz = arr_elem_bytes(infer(st, node.arr));
    st = gen_slice_bounds(st, node.arr, node.lo, node.hi);
    st = gen_push_value(st, node.v);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_arr_setslice" + tostring(esz)),
        0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_ADD_I_R, 32, insn.R_RSP, 64, 0, 0, 0, 0);
    emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0)
};

def gen_rectest(st: EmitSt, node: Narrow) -> EmitSt {
    let s = infer(st, node.e);
    let sk: long = s.k;
    st = gen(st, node.e);
    if (sk == K.tunion) {
        gen_tag_in(st, rectest_members(s, node.typ), s)
    } else if (sk == K.topt) {
        // `if let long n = v` where v is an option (`some(m)`
        // lowers to exactly this). The checker only lets a scalar pattern
        // reach here, so the test is the option's own: %rax is 0 for none.
        emit_bool(st)
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
    let rdone = next_loc(st);
    st = emit_jz(st, rno);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RAX, -1, 1, -8, -1, insn.R_RCX, 64);
    let yes = next_loc(st);
    ts.foreach((e) => {
        let dr = ty_desc_in(st, e, inu);
        st = dr.st;
        st = emit_insn(st, insn.F_LEA_P_R, -1, -1, 1, 0, dr.label, insn.R_RDX, 64);
        st = emit_insn(st, insn.F_CMP_R_R, insn.R_RDX, 64, insn.R_RCX, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_JE_L, yes, 0, 0, 0, 0, 0, 0);
    });
    st = emit_label(st, rno);
    st = emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
    st = emit_insn(st, insn.F_JMP_L, rdone, 0, 0, 0, 0, 0, 0);
    st = emit_label(st, yes);
    st = emit_insn(st, insn.F_MOV_I_R, 1, insn.R_RAX, 64, 0, 0, 0, 0);
    emit_label(st, rdone)
};

// Union value in %rax -> its string form: the member its descriptor names
// ("<union>" for none).
def gen_union_str_rax(st: EmitSt, t: Type, path: [Type]) -> EmitSt {
    let ms = types.union_parts(t);
    let rdone = next_loc(st);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    ms.foreach((e) => {
        let rnext = next_loc(st);
        let mt = e;
        let one: [Type] = [];
        one += mt;
        st = emit_insn(st, insn.F_MOV_0_R, insn.R_RSP, -1, 1, -1, -1, insn.R_RAX, 64);
        st = gen_tag_in(st, one, t);
        st = emit_jz(st, rnext);
        st = emit_insn(st, insn.F_POP_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        let mu = types.unfold(mt);
        if (types.is_boxable_type(mu)) {
            st = gen_slot_move(st, (mfield_idx((union_lay(mu, t)), types.box_field_name(mu))), false);
            st = gen_val_tostr_rax(st, mu, path + t);
        } else {
            st = gen_rec_str_rax(st, mu, union_lay(mu, t), path + t);
        };
        st = emit_insn(st, insn.F_JMP_L, rdone, 0, 0, 0, 0, 0, 0);
        st = emit_label(st, rnext);
    });
    st = emit_insn(st, insn.F_POP_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen_str_const(st, "<union>");
    emit_label(st, rdone)
};

// Indirect call through a closure value produced by `callee`.
def gen_indirect(st: EmitSt, node: Call, callee: Node) -> EmitSt {
    let args: [Node] = node.args;
    let n = len(args);
    let iptypes = fn_args_of(infer(st, callee));
    st = gen_push_value(st, callee);
    st = gen_push_args_as(st, args, iptypes);
    // Reload the closure (it sits just below the n pushed args) and call
    // through its code pointer.
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RSP, -1, 1, 8 * n, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RAX, -1, 1, -1, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_CALL_IND, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    // the callee popped the arguments (pops_args); the closure is left
    emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RSP, 64, 0, 0, 0, 0)
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
        if (e.kind == SK.box) {
            // the shared cell IS the variable's address
            emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, e.off, -1, insn.R_RAX, 64)
        } else if (e.kind == SK.global) {
            emit_insn(st, insn.F_LEA_P_R, -1, -1, 1, 0, e.label, insn.R_RAX, 64)
        } else if (e.kind == SK.capture) {
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
    st = gen_push_value(st, earr);
    st = gen(st, node.idx);
    st = emit_pop_left(st);
    st = emit_insn(st, insn.F_TEST_R_R, insn.R_RCX, 64, insn.R_RCX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JS_L, lbl_new("y_oob"), 0, 0, 0, 0, 0, 0);
    if (bt.k == K.tarrfix) {
        let arr: TFix = bt;
        st = emit_insn(st, insn.F_CMP_I_R, arr.n, insn.R_RCX, 64, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_JGE_L, lbl_new("y_oob"), 0, 0, 0, 0, 0, 0);
    } else {
        st = emit_insn(st, insn.F_CMP_M_R, insn.R_RAX, -1, 1, 0, -1, insn.R_RCX, 64);
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

// `x in [c1, c2, ...]` (types.in_compares) as `x == c1 || x == c2 || ...`:
// no array is built, and a condition jumps on each compare (gen_branch).
def in_chain(node: Bin) -> Node {
    let a: ArrLit = node.r;
    let es = a.elems;
    let ln = node.line;
    let cl = node.col;
    let out: Node = { k: K.bin, op: "==", l: node.l, r: es[0], line: ln, col: cl };
    for i in 1..len(es) {
        let eq: Node = { k: K.bin, op: "==", l: node.l, r: es[i], line: ln, col: cl };
        out = { k: K.bin, op: "||", l: out, r: eq, line: ln, col: cl };
    };
    out
};

// `x in s` / `e in a`: one pass, no short-circuit.
def gen_in(st: EmitSt, node: Bin) -> EmitSt {
    if (types.in_compares(node.l, node.r)) { return gen(st, in_chain(node)); };
    let ln = node.line;
    let cl = node.col;
    let zero = n_num("0", ln, cl);
    let rt = unfold(infer(st, node.r));
    if (rt.k == K.tmap) {
        // `"k" in m` is the map read's own scan, in its "has" mode): the key is on the left, so the Index node carries them
        // swapped from what gen_map_get expects.
        let ix: Index = { k: K.index, arr: node.r, idx: node.l, line: ln, col: cl };
        gen_map_get(st, ix, "has")
    } else if (rt.k == K.tstr) {
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

// A condition the emitter can branch on without building its bool: `&&`,
// `||`, and `!` of a bool (gen_branch walks them).
def is_logic(st: EmitSt, n: Node) -> bool {
    if (n.k == K.bin) {
        let b: Bin = n;
        b.op == "&&" || b.op == "||" || (b.op == "in" && types.in_compares(b.l, b.r))
    } else if (n.k == K.un) {
        let u: Un = n;
        u.op == "!" && unfold(infer(st, u.e)).k == K.tbool
    } else {
        false
    }
};

// The jump taken on the other outcome of the same flags.
def jcc_flip(j: long) -> long {
    if (j == insn.F_JGE_L) { insn.F_JL_L } else if (j == insn.F_JL_L) { insn.F_JGE_L }
    else if (j == insn.F_JLE_L) { insn.F_JG_L } else if (j == insn.F_JG_L) { insn.F_JLE_L }
    else if (j == insn.F_JNE_L) { insn.F_JE_L } else { insn.F_JNE_L }
};

// Jump to `label` when `cond` is true (`on_true`) or false, and fall through
// otherwise: a comparison jumps on its own flags, `&&`, `||` and a bool's `!`
// on their operands', so no condition builds the bool it only tests. Anything
// else is evaluated and tested, as it always was.
def gen_branch(st: EmitSt, cond: Node, label: long, on_true: bool) -> EmitSt {
    if (cond.k == K.un && is_logic(st, cond)) {
        let u: Un = cond;
        return gen_branch(st, u.e, label, !on_true);
    };
    if (cond.k == K.bin) {
        let bi: Bin = cond;
        if (bi.op == "in" && types.in_compares(bi.l, bi.r)) { cond = in_chain(bi); };
    };
    if (cond.k == K.bin) {
        let b: Bin = cond;
        if (b.op == "&&" || b.op == "||") {
            if ((b.op == "||") == on_true) {
                // either operand decides it: `a || b` true, `a && b` false
                st = gen_branch(st, b.l, label, on_true);
                return gen_branch(st, b.r, label, on_true);
            };
            // the left operand decides it the other way and skips the right
            let r = next_loc(st);
            st = gen_branch(st, b.l, r, !on_true);
            st = gen_branch(st, b.r, label, on_true);
            return emit_label(st, r);
        };
    };
    let jcc = int_cmp_jcc(st, cond);
    if (jcc != 0) {
        let cbin: Bin = cond;
        st = gen_cmp_flags(st, cbin);
        emit_insn(st, if (on_true) { jcc_flip(jcc) } else { jcc }, label, 0, 0, 0, 0, 0, 0)
    } else {
        st = gen(st, cond);
        st = emit_insn(st, insn.F_TEST_R_R, insn.R_RAX, 64, insn.R_RAX, 64, 0, 0, 0);
        emit_insn(st, if (on_true) { insn.F_JNZ_L } else { insn.F_JZ_L }, label, 0, 0, 0, 0, 0, 0)
    }
};

def gen_logic(st: EmitSt, node: Bin, is_or: bool) -> EmitSt {
    let rT = next_loc(st);
    let rF = next_loc(st);
    let rE = next_loc(st);
    let jl = if (is_or) { rT } else { rF };
    st = gen_branch(st, node.l, jl, is_or);
    st = gen_branch(st, node.r, jl, is_or);
    if (!(is_or)) {
        st = emit_insn(st, insn.F_MOV_I_R, 1, insn.R_RAX, 64, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_JMP_L, rE, 0, 0, 0, 0, 0, 0);
    };
    if (is_or) {
        st = emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
        st = emit_insn(st, insn.F_JMP_L, rE, 0, 0, 0, 0, 0, 0);
        st = emit_label(st, rT);
        st = emit_insn(st, insn.F_MOV_I_R, 1, insn.R_RAX, 64, 0, 0, 0, 0);
    }
    if (!(is_or)) {
        st = emit_label(st, rF);
        st = emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
    };
    st = emit_label(st, rE)
};

def gen_cat(st: EmitSt, node: Bin, lt: Type, rt: Type) -> EmitSt {
    if (lt.k == K.tarr || lt.k == K.tarrfix || rt.k == K.tarr || rt.k == K.tarrfix) {
        return gen_cat_arr(st, node, lt, rt);
    };
    st = gen_cat_operand(st, node.l, lt);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen_cat_operand(st, node.r, rt);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    gen_runtime_call(st, "y_str_cat", 16)
};

// Concatenation treats bytes as characters; tostring treats them as numbers.
// Unknown operands retain the historical string-pointer interpretation.
def gen_cat_operand(st: EmitSt, node: Node, t: Type) -> EmitSt {
    st = gen(st, node);
    if (t.k == K.tbyte) { gen_helper1(st, "y_str_chr") }
    else if (t.k == K.tlong || t.k == K.tbool || t.k == K.tfloat || t.k == K.tbigint) {
        gen_helper1(st, scalar_string_helper(t.k))
    } else { st }
};

def scalar_string_helper(k: long) -> str {
    if (k == K.tbool) { "y_bool_tostr" }
    else if (k == K.tfloat) { "y_float_tostr" }
    else if (k == K.tbigint) { "y_bigint_tostr" }
    else { "y_long_tostr" }
};
def leaf_expr(n: Node) -> bool {
    if (n.k == K.num || n.k == K.id) {
        true
    } else if (n.k == K.dot) {
        as_num(n).k == K.num
    } else if (n.k == K.un) {
        let un: Un = n;
        leaf_expr(un.e)
    } else {
        false
    }
};

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
    st = gen_runtime_call(st, "y_str_cmp", 16);
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
            gen_runtime_call(st, "y_arr_eq_str", 16)
        } else {
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_push_imm(st, elem_bytes(arr.of));
            gen_runtime_call(st, "y_arr_eq", 24)
        }
    } else if (t.k == K.tbigint) {
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = gen_runtime_call(st, "y_bigint_cmp", 16);
        st = emit_insn(st, insn.F_CMP_I_R, 0, insn.R_RAX, 64, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_SETE_R, insn.R_RAX, 8, 0, 0, 0, 0, 0);
        emit_insn(st, insn.F_MOVZBQ_R_R, insn.R_RAX, 8, insn.R_RAX, 64, 0, 0, 0)
    } else if (t.k == K.tstr) {
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        gen_runtime_call(st, "y_str_eq", 16)
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
    let lne = next_loc(st);
    let ldone = next_loc(st);
    st = emit_insn(st, insn.F_POP_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_TEST_R_R, insn.R_RCX, 64, insn.R_RCX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JZ_L, lnone, 0, 0, 0, 0, 0, 0);
    st = emit_jz(st, lne);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RCX, -1, 1, -1, -1, insn.R_RCX, 64);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RAX, -1, 1, -1, -1, insn.R_RAX, 64);
    st = gen_eq_vals(st, pt);
    st = emit_insn(st, insn.F_JMP_L, ldone, 0, 0, 0, 0, 0, 0);
    st = emit_label(st, lnone);
    st = emit_insn(st, insn.F_TEST_R_R, insn.R_RAX, 64, insn.R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_SETE_R, insn.R_RAX, 8, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOVZBQ_R_R, insn.R_RAX, 8, insn.R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JMP_L, ldone, 0, 0, 0, 0, 0, 0);
    st = emit_label(st, lne);
    st = emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
    emit_label(st, ldone)
};

def gen_eq_arr_deep(st: EmitSt, et: Type) -> EmitSt {
    let lloop = next_loc(st);
    let lsame = next_loc(st);
    let ldiff = next_loc(st);
    let lne = next_loc(st);
    let ldone = next_loc(st);
    st = emit_insn(st, insn.F_POP_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RCX, -1, 1, -1, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RAX, -1, 1, -1, -1, insn.R_RSI, 64);
    st = emit_insn(st, insn.F_CMP_R_R, insn.R_RSI, 64, insn.R_RDX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JNE_L, lne, 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_XOR_R_R, insn.R_RDX, 32, insn.R_RDX, 32, 0, 0, 0);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RDX, 64, 0, 0, 0, 0, 0);
    st = emit_label(st, lloop);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RSP, -1, 1, -1, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RSP, -1, 1, 16, -1, insn.R_RCX, 64);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RCX, -1, 1, -1, -1, insn.R_RSI, 64);
    st = emit_insn(st, insn.F_CMP_R_R, insn.R_RSI, 64, insn.R_RDX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JGE_L, lsame, 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RCX, -1, 1, 16, -1, insn.R_RCX, 64);
    st = emit_insn(st, insn.F_MOV_M_R, insn.R_RCX, insn.R_RDX, 8, 0, -1, insn.R_RCX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RSP, -1, 1, 8, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RAX, -1, 1, 16, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_MOV_M_R, insn.R_RAX, insn.R_RDX, 8, 0, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
    st = gen_eq_vals(st, et);
    st = emit_jz(st, ldiff);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RSP, -1, 1, -1, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_INC_R, insn.R_RDX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_R_0, insn.R_RDX, 64, insn.R_RSP, -1, 1, -1, -1);
    st = emit_insn(st, insn.F_JMP_L, lloop, 0, 0, 0, 0, 0, 0);
    st = emit_label(st, lsame);
    st = emit_insn(st, insn.F_ADD_I_R, 24, insn.R_RSP, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_I_R, 1, insn.R_RAX, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_JMP_L, ldone, 0, 0, 0, 0, 0, 0);
    st = emit_label(st, ldiff);
    st = emit_insn(st, insn.F_ADD_I_R, 24, insn.R_RSP, 64, 0, 0, 0, 0);
    st = emit_label(st, lne);
    st = emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
    emit_label(st, ldone)
};

// Pointer arithmetic emission (types.y is the law). A pointer moves by
// whole elements: `p + n` scales n by the pointee width, and `p - q`
// subtracts the addresses and divides by that width. byte pointers scale by
// one; every other pointee is an 8-byte slot, which is elem_bytes' rule.


def ptr_elem_width(t: Type) -> long {
    let p: TPtr = unfold(t);
    pointee_bytes(p.to)
};

// log2 of an element width: the shift that scales an index by it.
def width_shift(esz: long) -> long {
    if (esz == 8) { 3 } else if (esz == 4) { 2 } else if (esz == 2) { 1 } else { 0 }
};

def ptr_scale_rax(st: EmitSt, esz: long) -> EmitSt {
    if (esz > 1) {
        emit_insn(st, insn.F_SHL_I_R, width_shift(esz), insn.R_RAX, 64, 0, 0, 0, 0)
    } else {
        st
    }
};

def gen_ptr_arith(st: EmitSt, node: Bin, lt: Type, rt: Type) -> EmitSt {
    let op = node.op;
    let kind = ptr_math_kind(op, lt, rt);
    if (kind == "ptr_int") {
        let esz = ptr_elem_width(lt);
        st = gen_push_value(st, node.l);
        st = gen(st, node.r);
        st = ptr_scale_rax(st, esz);
        st = emit_pop_left(st);
        if (op == "+") {
            emit_insn(st, insn.F_ADD_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0)
        } else {
            emit_insn(st, insn.F_SUB_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0)
        }
    } else if (kind == "int_ptr") {
        let esz = ptr_elem_width(rt);
        st = gen_push_value(st, node.l);
        st = gen(st, node.r);
        st = emit_pop_left(st);
        st = ptr_scale_rax(st, esz);
        emit_insn(st, insn.F_ADD_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0)
    } else {
        let esz = ptr_elem_width(lt);
        st = gen_push_value(st, node.l);
        st = gen(st, node.r);
        st = emit_pop_left(st);
        st = emit_insn(st, insn.F_SUB_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0);
        if (esz > 1) {
            emit_insn(st, insn.F_SAR_I_R, width_shift(esz), insn.R_RAX, 64, 0, 0, 0, 0)
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
        st = gen_push_args(st, [node.l, node.r]);
        st = gen_runtime_call(st, "y_str_eq", 16);
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
            st = gen_push_value(st, node.l);
            st = gen(st, node.r);
            st = gen_eq_arr_deep(st, elt);
        } else {
            st = gen_push_args(st, [node.l, node.r]);
            if (elt.k == K.tstr) {
                st = gen_runtime_call(st, "y_arr_eq_str", 16);
            } else {
                st = emit_push_imm(st, elem_bytes(elt));
                st = gen_runtime_call(st, "y_arr_eq", 24);
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
        st = gen_push_value(st, node.l);
        st = gen(st, node.r);
        st = gen_eq_opt(st, pt);
        if (op == "!=") {
            emit_insn(st, insn.F_XOR_I_R, 1, insn.R_RAX, 64, 0, 0, 0, 0)
        } else {
            st
        }
    } else if (int_fast_op(op, lt, rt, node.r, st)) {
        gen_int_fast(st, node, op)
    } else {
        st = gen_push_value(st, node.l);
        st = gen(st, node.r);
        st = emit_pop_left(st);
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
            let d2 = next_loc(st);
            st = emit_insn(st, insn.F_CMP_I_R, -1, insn.R_RCX, 64, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_JNE_L, d1, 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_NEG_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_JMP_L, d2, 0, 0, 0, 0, 0, 0);
            st = emit_label(st, d1);
            st = emit_insn(st, insn.F_CQO, 0, 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_IDIV_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
            emit_label(st, d2)
        } else if (op == "%") {
            // Same #DE: x % -1 is 0 for every x (see the `/` note).
            st = emit_insn(st, insn.F_TEST_R_R, insn.R_RCX, 64, insn.R_RCX, 64, 0, 0, 0);
            st = emit_insn(st, insn.F_JZ_L, lbl_new("y_div_zero"), 0, 0, 0, 0, 0, 0);
            let m1 = next_loc(st);
            let m2 = next_loc(st);
            st = emit_insn(st, insn.F_CMP_I_R, -1, insn.R_RCX, 64, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_JNE_L, m1, 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
            st = emit_insn(st, insn.F_JMP_L, m2, 0, 0, 0, 0, 0, 0);
            st = emit_label(st, m1);
            st = emit_insn(st, insn.F_CQO, 0, 0, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_IDIV_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_MOV_R_R, insn.R_RDX, 64, insn.R_RAX, 64, 0, 0, 0);
            emit_label(st, m2)
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

// Whether `l op r` can skip the stack: integer operands, an operator that has
// a register or immediate form here, and a right operand that is a literal or a
// leaf whose load leaves %rcx alone (rcx_free_leaf), so the left can wait there.
def int_fast_op(op: str, lt: Type, rt: Type, r: Node, st: EmitSt) -> bool {
    let lk: long = lt.k;
    let rk: long = rt.k;
    if ((lk == K.tlong || lk == K.tbyte) && (rk == K.tlong || rk == K.tbyte)) {
        if (op == "+" || op == "-" || op == "*" || op == "&" || op == "|" || op == "^" || op == "==" || op == "!="
            || op == "<" || op == ">" || op == "<=" || op == ">=") {
            imm_lit(r) >= 0 || rcx_free_leaf(st, r)
        } else { false }
    } else { false }
};

def gen_int_fast(st: EmitSt, node: Bin, op: str) -> EmitSt {
    st = gen(st, node.l);
    let imm = imm_lit(node.r);
    if (imm >= 0 && op != "*") {
        if (op == "+") { emit_insn(st, insn.F_ADD_I_R, imm, insn.R_RAX, 64, 0, 0, 0, 0) }
        else if (op == "-") { emit_insn(st, insn.F_SUB_I_R, imm, insn.R_RAX, 64, 0, 0, 0, 0) }
        else if (op == "&") { emit_insn(st, insn.F_AND_I_R, imm, insn.R_RAX, 64, 0, 0, 0, 0) }
        else if (op == "|") { emit_insn(st, insn.F_OR_I_R, imm, insn.R_RAX, 64, 0, 0, 0, 0) }
        else if (op == "^") { emit_insn(st, insn.F_XOR_I_R, imm, insn.R_RAX, 64, 0, 0, 0, 0) }
        else {
            st = emit_insn(st, insn.F_CMP_I_R, imm, insn.R_RAX, 64, 0, 0, 0, 0);
            gen_setcc(st, op)
        }
    } else {
        st = rax_into_rcx(st);
        st = gen(st, node.r);
        if (op == "+") { emit_insn(st, insn.F_ADD_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0) }
        else if (op == "*") { emit_insn(st, insn.F_IMUL_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0) }
        else if (op == "&") { emit_insn(st, insn.F_AND_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0) }
        else if (op == "|") { emit_insn(st, insn.F_OR_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0) }
        else if (op == "^") { emit_insn(st, insn.F_XOR_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0) }
        else if (op == "-") {
            st = emit_insn(st, insn.F_SUB_R_R, insn.R_RAX, 64, insn.R_RCX, 64, 0, 0, 0);
            emit_insn(st, insn.F_MOV_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0)
        } else {
            // left in %rcx, right in %rax: rcx - rax is left - right
            st = emit_insn(st, insn.F_CMP_R_R, insn.R_RAX, 64, insn.R_RCX, 64, 0, 0, 0);
            gen_setcc(st, op)
        }
    }
};

// The 0/1 of the comparison the flags hold (left - right).
def gen_setcc(st: EmitSt, op: str) -> EmitSt {
    let f = insn.F_SETE_R;
    if (op == "!=") { f = insn.F_SETNE_R; }
    else if (op == "<") { f = insn.F_SETL_R; }
    else if (op == ">") { f = insn.F_SETG_R; }
    else if (op == "<=") { f = insn.F_SETLE_R; }
    else if (op == ">=") { f = insn.F_SETGE_R; };
    st = emit_insn(st, f, insn.R_RAX, 8, 0, 0, 0, 0, 0);
    emit_insn(st, insn.F_MOVZBQ_R_R, insn.R_RAX, 8, insn.R_RAX, 64, 0, 0, 0)
};

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
        st = emit_pop_left(st);
        st = emit_insn(st, insn.F_TEST_R_R, insn.R_RCX, 64, insn.R_RCX, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_JS_L, lbl_new("y_shift_neg"), 0, 0, 0, 0, 0, 0);
        let ok = next_loc(st);
        st = emit_insn(st, insn.F_CMP_I_R, 64, insn.R_RCX, 64, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_JB_L, ok, 0, 0, 0, 0, 0, 0);
        st = mn == "sar" ? emit_insn(st, insn.F_MOV_I_R, 63, insn.R_RCX, 64, 0, 0, 0, 0) : emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
        st = emit_label(st, ok);
        emit_insn(st, fr, insn.R_RCX, 8, insn.R_RAX, 64, 0, 0, 0)
    }
};

// The count of a shift when it is a literal from 0 to 63 (gen_shift), else
// -1. A radix literal may wrap negative (0xFFFF_FFFF_FFFF_FFFF is -1).
def shift_imm(r: Node) -> long {
    r = as_num(r);
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

// Syscall register order and stack slots come from the target ABI descriptor.
def syscall_reg(i: long) -> long {
    let regs = target_info(res_target).sysregs;
    regs[i >= 0 && i < len(regs) ? i : len(regs) - 1]
};

// How many arguments the Windows target passes in registers.  The rest go on
// the stack (gen_syscall).
def w_syscall_regargs() -> long { len(target_info("win").sysregs) };

// The same, for `_start`'s tail, which is built straight into the body's IR
// (emit_one_fn) rather than through an EmitSt. The status is 0: the Linux
// side zeroed %edi and the Windows side zeroes %rax before this.
def ir_terminate(body: [long]) -> [long] {
    if (target_is_kernel()) {
        // There is nothing to exit to: the kernel's top level falls into the
        // halt loop kernel.s defines (`cli; hlt; jmp`), which is also where
        // an explicit exit(N) lands, via y_os_exit.
        body = insn.ir_push(body, insn.F_CALL_L, lbl_new("y_kernel_halt"), 0, 0, 0, 0, 0, 0);
    } else if (target_is_windows()) {
        body = insn.ir_push(body, insn.F_MOV_I_R, 0 - 1, insn.R_R10, 64, 0, 0, 0, 0);
        body = insn.ir_push(body, insn.F_XOR_R_R, insn.R_RDX, 32, insn.R_RDX, 32, 0, 0, 0);
        body = insn.ir_push(body, insn.F_MOV_I_R, 44, 0, 64, 0, 0, 0, 0);
        body = insn.ir_push(body, insn.F_SYSCALL, 0, 0, 0, 0, 0, 0, 0);
    } else {
        body = insn.ir_push(body, insn.F_MOV_I_R, 231, 0, 64, 0, 0, 0, 0);
        body = insn.ir_push(body, insn.F_XOR_R_R, insn.R_RDI, 32, insn.R_RDI, 32, 0, 0, 0);
        body = insn.ir_push(body, insn.F_SYSCALL, 0, 0, 0, 0, 0, 0, 0);
    };
    body
};

def gen_push_args(st: EmitSt, args: [Node]) -> EmitSt {
    for i in 0..len(args) {
        st = gen_push_value(st, args[i]);
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

// The declared kinds gen_conv converts a value into.
def conv_kind(wk: long) -> bool {
    wk == K.tfloat || wk == K.tbyte || wk == K.tbigint || wk == K.tptr
};

// A value of static type `got` stored where `want` is declared needs code
// (gen_conv emits some): the one rule gen_as, rec_leaf_field and the
// pointer-argument sites share.
def needs_conv(got: Type, want: Type) -> bool {
    let gk: long = got.k;
    let wk: long = want.k;
    if (gk == wk) { false }
    else if (wk == K.tfloat) { gk == K.tlong || gk == K.tbyte }
    else if (wk == K.tbyte) { gk == K.tlong }
    else if (wk == K.tbigint) { true }
    else if (wk == K.tptr) { gk == K.tstr }
    else { false }
};

// A pointer argument (os_call, ptr_addr): a str flows in as its header and
// the callee wants the data bytes.
def gen_conv_ptr(st: EmitSt, got: Type) -> EmitSt {
    gen_conv(st, got, type_node({ k: K.tptr, to: type_node({ k: K.tlong }) }))
};

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
    } else if (wk == K.tptr && gk == K.tstr) {
        // a str flows in as its header; a *T wants the data bytes
        emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RAX, 64, 0, 0, 0, 0)
    } else {
        st
    }
};

def gen_as(st: EmitSt, node: Node, want0: Type) -> EmitSt {
    let want = types.unfold(want0);
    let nk: long = node.k;
    let wk: long = want.k;
    if (nk == K.rec && wk == K.tpack) {
        let plit: RecLit = node;
        st = gen_packlit(st, plit, want);
    } else if (nk == K.rec && (wk == K.trec || wk == K.tunion)) {
        // want0 as declared: a recursive alias names the descriptor
        let rec: RecLit = node;
        st = gen_reclit(st, rec, want0);
    } else if (nk == K.rec && wk == K.tmap && is_empty_rec(node)) {
        // `{}` where a map is declared (an argument, a store, a return) IS
        // the map, as under a `let` annotation (gen_decl): made as a record
        // it crashed every reader (json.jobj({}))
        let ml: RecLit = node;
        st = gen_maplit(st, ml, map_hashed(map_key_of(want)));
    } else if (nk == K.array && types.lit_elems_take(node, want0)) {
        // [{...}, ...] where [T] is declared: each element made as T (types.y
        // typeof_want)
        let arr: ArrLit = node;
        let asz = arr_elem_bytes(want);
        st = gen_array_esz(st, arr, asz, store_elem_type(want, asz));
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
    if (conv_kind(wk)) {
        gen_conv(st, infer(st, node), want)
    } else if ((wk == K.trec || wk == K.tunion) && nk != K.rec) {
        // a record literal is made in the declared layout (gen_reclit)
        gen_convert(st, infer(st, node), want0, true)
    } else {
        st
    }
};

// node is a record literal with no fields.
def is_empty_rec(node: Node) -> bool {
    let rec: RecLit = node;
    len(rec.keys) == 0
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
// is one of its members ts, or the program stops (y_cast_trap). The last
// member's compare jumps to the trap when it fails.
def gen_cast_check(st: EmitSt, ts: [Type], u: Type) -> EmitSt {
    let ok = next_loc(st);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RAX, -1, 1, -8, -1, insn.R_RCX, 64);
    let last = len(ts) - 1;
    ts.foreach((e, ti) => {
        let dr = ty_desc_in(st, e, u);
        st = dr.st;
        st = emit_insn(st, insn.F_LEA_P_R, -1, -1, 1, 0, dr.label, insn.R_RDX, 64);
        st = emit_insn(st, insn.F_CMP_R_R, insn.R_RDX, 64, insn.R_RCX, 64, 0, 0, 0);
        if (ti == last) {
            st = emit_insn(st, insn.F_JNE_L, lbl_new("y_cast_trap"), 0, 0, 0, 0, 0, 0);
        } else {
            st = emit_insn(st, insn.F_JE_L, ok, 0, 0, 0, 0, 0, 0);
        };
    });
    if (last < 0) { st = emit_insn(st, insn.F_JMP_L, lbl_new("y_cast_trap"), 0, 0, 0, 0, 0, 0); };
    emit_label(st, ok)
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
        if (e.kind == SK.fnty) {
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

// Call a runtime label with arguments already pushed, then release them.
def gen_runtime_call(st: EmitSt, name: str, bytes: long) -> EmitSt {
    st = emit_insn(st, insn.F_CALL_L, lbl_new(name), 0, 0, 0, 0, 0, 0);
    emit_insn(st, insn.F_ADD_I_R, bytes, insn.R_RSP, 64, 0, 0, 0, 0)
};

def gen_push_value(st: EmitSt, node: Node) -> EmitSt {
    st = gen(st, node);
    emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0)
};

def gen_save_value(st: EmitSt, node: Node, off: long) -> EmitSt {
    st = gen(st, node);
    emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, off, -1)
};

def gen_helper1(st: EmitSt, name: str) -> EmitSt {
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    gen_runtime_call(st, name, 8)
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
        gen_named_call(st, node, name)
    }
};

def gen_named_special(st: EmitSt, node: Call, name: str) -> EmitSt {
    if (name == "join" && len(node.args) == 1) {
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
    } else if (name == "time_us") {
        emit_insn(st, insn.F_CALL_L, lbl_new("y_time_us"), 0, 0, 0, 0, 0, 0)
    } else if (name == "keys") {
        // a copy of the map's keys array (gen_maplit's {keys, vals, boxes})
        let kargs: [Node] = node.args;
        let ln = node.line;
        let cl = node.col;
        let whole: Slice = { k: K.slice, arr: map_field(kargs[0], "keys", ln, cl), lo: { k: K.void, line: ln, col: cl }, hi: { k: K.void, line: ln, col: cl }, line: ln, col: cl };
        gen_slice(st, whole)
    } else if (name == "values") {
        // a copy of the map's values array, in the same order as keys(m)
        let vargs: [Node] = node.args;
        let ln = node.line;
        let cl = node.col;
        let whole: Slice = { k: K.slice, arr: map_field(vargs[0], "vals", ln, cl), lo: { k: K.void, line: ln, col: cl }, hi: { k: K.void, line: ln, col: cl }, line: ln, col: cl };
        gen_slice(st, whole)
    } else if (name == "bytes") {
        let args: [Node] = node.args;
        st = gen_push_args(st, args);
        gen_runtime_call(st, "y_str_to_bytes", 8)
    } else if (name == "from_bytes") {
        let args: [Node] = node.args;
        st = gen_push_args(st, args);
        gen_runtime_call(st, "y_bytes_to_str", 8)
    } else if (name == "ptr_from") {
        // ... and so is an integer: the inverse of ptr_addr, the operand
        // evaluated and left in %rax as the pointer.
        let pfargs: [Node] = node.args;
        gen(st, pfargs[0])
    } else if (name == "ptr_addr") {
        // A pointer IS its numeric value at run time: nothing to emit
        // beyond evaluating the operand. This exists only so the type
        // system lets the value cross into long territory. A str is its
        // header, so it gets the same +8 as a str coerced to a *T.
        let paargs: [Node] = node.args;
        st = gen(st, paargs[0]);
        gen_conv_ptr(st, infer(st, paargs[0]))
    } else if (name == "os_call") {
        let oa: [Node] = node.args;
        let n = len(oa) - 1;
        for k in 1..n + 1 {
            st = gen(st, oa[k]);
            st = gen_conv_ptr(st, infer(st, oa[k]));
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        };
        // The name is a str literal: the checker required one (a variable
        // holding a name would put the choice back in the program's hands,
        // and the arch module's list is the whole point of naming it).
        let onm: Leaf = oa[0];
        gen_runtime_call(st, onm.v, 8 * n)
    } else { gen_direct(st, node, name) }
};


// Whether an array of this element type can hold a reference. A long, int,
// bool or float element cannot, and neither can a packed [byte], so the
// collector may skip the data block's payload (y_alloc_pf's bit 2).
def elem_pf(t: Type) -> bool {
    t.k == K.tlong || t.k == K.tbool || t.k == K.tfloat || t.k == K.tbyte
};

// The array header is in %rax: mark the block its data pointer names as
// pointer-free. The header keeps the data pointer in word 2, and that block's
// own header word (the one before its payload) carries the flags, so bit 2 is
// where y_gc_drain looks. Only for element types that cannot hold a reference.
def mark_pf_arr(st: EmitSt, t: Type) -> EmitSt {
    if (elem_pf(t)) {
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RAX, -1, 1, 16, -1, insn.R_RDX, 64);
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RDX, -1, 1, -8, -1, insn.R_RCX, 64);
        st = emit_insn(st, insn.F_MOV_I_R, 4, insn.R_R8, 64, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_OR_R_R, insn.R_R8, 64, insn.R_RCX, 64, 0, 0, 0);
        emit_insn(st, insn.F_MOV_R_D, insn.R_RCX, 64, insn.R_RDX, -1, 1, -8, -1)
    } else {
        st
    }
};

def gen_arr_insert_method(st: EmitSt, node: Call) -> EmitSt {
    let dot: Dot = node.callee;
    let esz = arr_elem_bytes((infer(st, dot.obj)));
    let args: [Node] = node.args;
    st = gen_push_value(st, dot.obj);
    st = gen_push_value(st, args[0]);
    st = gen_push_value(st, args[1]);
    st = emit_push_imm(st, esz);
    st = gen_runtime_call(st, "y_arr_insert", 32);
    st = emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
    st
};

def gen_arr_method(st: EmitSt, node: Call) -> EmitSt {
    let dot: Dot = node.callee;
    let key = dot.key;
    if (key == "insert") { return gen_arr_insert_method(st, node); };
    let at = infer(st, dot.obj);
    let ft = normtype({ k: K.tnone });
    if (key in ["foreach", "map", "filter", "all", "some", "find", "reduce", "sort", "sorted"]) { ft = infer(st, node.args[0]); };
    let nargs = 0;
    if (ft.k == K.tfunc) { let f: TFunc = ft; nargs = len(f.args); };
    let elem = arr_elem_type(at);
    let arr = normtype({ k: K.tarr, of: elem });
    let result = key == "filter" ? arr : infer_arr_method(st, node, key, at);
    let fresh = next_uid(st);
    st = fresh.st;
    let q: ArrayLowerCtx = { prefix: "~arr" + tostring(fresh.uid) + "_", line: node.line, col: node.col,
        obj: dot.obj, args: node.args, arr: arr, ft: ft, result: result, elem: elem };
    gen(st, array_lower(key, nargs, q))
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
        gen_runtime_call(st, fname, len(args) * 8)
    } else {
        gen_call(st, { k: K.call, callee: { k: K.id, v: fname, line: node.line, col: node.col }, args: args, line: node.line, col: node.col })
    }
};

def gen_print(st: EmitSt, node: Call) -> EmitSt {
    let args: [Node] = node.args;
    let t = infer(st, args[0]);
    if (t.k == K.trec || t.k == K.tfunc || t.k == K.tarr || t.k == K.tarrfix ||
        t.k == K.topt || t.k == K.tmap || t.k == K.tunion) {
        st = gen(st, args[0]);
        st = t.k == K.tfunc ? gen_str_const(st, "<function " + types.tstr(t) + ">") :
            gen_root_tostr_rax(st, t);
        st = gen_helper1(st, "y_print_hstr");
        emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0)
    } else { gen_print_scalar(st, args[0], t) }
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
            st = emit_push_imm(st, len(lit.v));
            st = gen_runtime_call(st, "y_print_lit", 16);
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
    let rnul = next_loc(st);
    st = emit_jz(st, rnul);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RAX, -1, 1, -1, -1, insn.R_RAX, 64);
    let opt: TOf = t;
    st = gen_val_tostr_rax(st, opt.of, path + t);
    st = emit_insn(st, insn.F_JMP_L, rdone, 0, 0, 0, 0, 0, 0);
    st = emit_label(st, rnul);
    st = gen_str_const(st, "none");
    emit_label(st, rdone)
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
    st = gen_push_value(st, node.r);
    st = emit_push_imm(st, cesz);
    st = gen_runtime_call(st, "y_arr_cat", 24);
    mark_pf_arr(st, crt)
};

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
        st = gen_push_value(st, node.l);
        st = how == "cat" ? gen(st, node.r) : gen_array_esz(st, one, esz, ety);
    } else {
        st = gen_array_esz(st, one, esz, ety);
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = gen(st, node.r);
    };
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_push_imm(st, esz);
    st = gen_runtime_call(st, "y_arr_cat", 24);
    mark_pf_arr(st, ety)
};

// acc = acc + <constant>, with the layout above still in place.
def gen_acc_cat_const(st: EmitSt, s: str) -> EmitSt {
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RSP, -1, 1, -1, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen_str_const(st, s);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen_runtime_call(st, "y_str_cat", 16);
    emit_insn(st, insn.F_MOV_R_0, insn.R_RAX, 64, insn.R_RSP, -1, 1, -1, -1)
};

// Slot idx of the record in %rcx into %rax (every caller wants it there).
def gen_slot_load(st: EmitSt, idx: long) -> EmitSt {
    emit_insn(st, insn.F_MOV_D_R, insn.R_RCX, -1, 1, 8 * idx, -1, insn.R_RAX, 64)
};

def gen_rec_field_str(st: EmitSt, idx: long, ft: Type, path: [Type]) -> EmitSt {
    if (ft.k == K.tfunc) {
        st = gen_str_const(st, "<function " + types.tstr(ft) + ">");
    } else {
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RSP, -1, 1, 8, -1, insn.R_RCX, 64);
        st = gen_slot_load(st, idx);
        st = gen_val_tostr_rax(st, ft, path);
    };
    st = emit_insn(st, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_RDX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RSP, -1, 1, -1, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RDX, 64, 0, 0, 0, 0, 0);
    st = gen_runtime_call(st, "y_str_cat", 16);
    emit_insn(st, insn.F_MOV_R_0, insn.R_RAX, 64, insn.R_RSP, -1, 1, -1, -1)
};

def w_arg_space() -> long { target_info("win").stack_room };

// Win64 stack arguments start at offset 40, after the return address and shadow space.
def w_stack_arg_off(i: long) -> long {
    target_info("win").stack_base + target_word() * (i - w_syscall_regargs() - 1)
};

def syscall_may_block(num: Node) -> bool {
    if (target_is_windows() || target_is_kernel() || target_is_aarch64()) { return false; };
    if (num.k != K.num) { return false; };
    let lit: Leaf = num;
    // read write poll pread readv writev select pause nanosleep connect accept
    // sendto recvfrom sendmsg recvmsg wait4 futex clock_nanosleep epoll_wait
    // waitid pselect6 ppoll epoll_pwait accept4
    let blocking = "|0|1|7|17|19|20|23|34|35|42|43|44|45|46|47|61|202|230|232|247|270|271|281|288|";
    blocking.contains("|" + lit.v + "|")
};

def gen_syscall(st: EmitSt, node: Call) -> EmitSt {
    let args: [Node] = node.args;
    // args[0] is the number; the rest are the call's arguments.
    let n = len(args) - 1;
    let regs = len(target_info(res_target).sysregs);
    let room = (target_is_windows() && n > regs) ? w_arg_space() : 0;
    let nreg = if (n < regs) { n } else { regs };
    if (room > 0) {
        st = emit_insn(st, insn.F_SUB_I_R, room, insn.R_RSP, 64, 0, 0, 0, 0);
        let i = n;
        while (i > regs) {
            st = gen(st, args[i]);
            st = gen_conv_ptr(st, infer(st, args[i]));
            st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RSP, -1, 1, w_stack_arg_off(i), -1);
            i = i - 1;
        };
    };
    // The number and the register arguments: push them all, pop them off the
    // top in reverse.
    st = gen_push_value(st, args[0]);
    for k in 1..nreg + 1 {
        st = gen_push_value(st, args[k]);
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
    if (syscall_may_block(args[0])) {
        st = emit_insn(st, insn.F_CALL_L, lbl_new("y_gc_syscall"), 0, 0, 0, 0, 0, 0);
    } else {
        if (target_is_aarch64()) {
            st = emit_insn(st, insn.F_CALL_L, lbl_new("y_a64_raw_y_gc_syscall"), 0, 0, 0, 0, 0, 0);
        } else {
            st = emit_insn(st, insn.F_SYSCALL, 0, 0, 0, 0, 0, 0, 0);
        };
    };
    if (room > 0) {
        st = emit_insn(st, insn.F_ADD_I_R, room, insn.R_RSP, 64, 0, 0, 0, 0);
    };
    st
};

def capture_off(st: EmitSt) -> long {
    let env = st.env;
    let i = 0;
    let res = -1;
    while (i < len(env)) {
        let e = env[i];
        if (e.kind == SK.capture) {
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
        if (e.kind == SK.none) {
            label = lbl_new("y_missing_" + name);
        } else if (e.kind == SK.func) {
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
            st = emit_push_slot(st, soff);
        }
        st = gen_push_args_as(st, node.args, dptypes);
        st = emit_insn(st, insn.F_CALL_L, label, 0, 0, 0, 0, 0, 0);
        let nbytes = pops_args(label) ? 0 : len(node.args) * 8;
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

def cmp_word(t: Type) -> bool {
    t.k == K.tlong || t.k == K.tbyte || t.k == K.tbool || t.k == K.tptr
};

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

// The value of a plain decimal literal that fits an instruction's 32-bit
// immediate (at most nine digits), else -1: `x + 1`, `i < 8`.
def imm_lit(n: Node) -> long {
    n = as_num(n);
    if (n.k == K.num) {
        let num: Leaf = n;
        let s = norm_num(num.v);
        let ok = len(s) > 0 && len(s) < 10 && !lit_is_float(s);
        for i in 0..len(s) {
            let c = ord(s[i:i + 1]);
            if (c < 48 || c > 57) { ok = false; }
        };
        if (ok) { leading_long(s) } else { -1 }
    } else { -1 }
};

// leaf_expr, and also one whose load leaves %rcx alone. A captured id is a
// leaf by shape but reads through the closure record in %rcx (gen_id), and a
// hoisted def used as a value builds a closure; a left operand parked in %rcx
// would be compared against that instead.
def rcx_free_leaf(st: EmitSt, n: Node) -> bool {
    if (n.k == K.id) {
        let id: Leaf = n;
        let e = env_find(st, id.v);
        e.kind != SK.capture && e.kind != SK.func
    } else if (n.k == K.un) {
        let un: Un = n;
        rcx_free_leaf(st, un.e)
    } else {
        leaf_expr(n)
    }
};

// The operands the way the numeric path emits them -- left into %rax, right
// into %rcx -- so the `cmp %rcx, %rax` that follows reads left - right and the
// same setcc/jcc forms apply.
def gen_cmp_flags(st: EmitSt, node: Bin) -> EmitSt {
    st = gen(st, node.l);
    let imm = imm_lit(node.r);
    if (imm >= 0) {
        emit_insn(st, insn.F_CMP_I_R, imm, insn.R_RAX, 64, 0, 0, 0, 0)
    } else if (rcx_free_leaf(st, node.r)) {
        st = rax_into_rcx(st);
        st = gen(st, node.r);
        emit_insn(st, insn.F_CMP_R_R, insn.R_RAX, 64, insn.R_RCX, 64, 0, 0, 0)
    } else {
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = gen(st, node.r);
        st = emit_pop_left(st);
        emit_insn(st, insn.F_CMP_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0)
    }
};

def gen_if(st: EmitSt, node: If) -> EmitSt {
    gen_if_go(st, node)
};

def gen_if_go(st: EmitSt, node: If) -> EmitSt {
    let r1 = next_loc(st);
    let r2 = next_loc(st);
    let jcc = int_cmp_jcc(st, node.cond);
    if (jcc != 0) {
        // A comparison branches on the flags it has just set: the bool is
        // never built. `setcc; movzbq; test; jcc` (four instructions) becomes
        // `cmp; jcc` (two) -- 3,049 such sites in ycc's own output.
        let cbin: Bin = node.cond;
        st = gen_cmp_flags(st, cbin);
        st = emit_insn(st, jcc, r1, 0, 0, 0, 0, 0, 0);
    } else if (is_logic(st, node.cond)) {
        st = gen_branch(st, node.cond, r1, false);
    } else {
        st = gen(st, node.cond);
        st = emit_jz(st, r1);
    };
    st = gen(st, node.then);
    if (node.has_else) {
        st = emit_insn(st, insn.F_JMP_L, r2, 0, 0, 0, 0, 0, 0);
        st = emit_label(st, r1);
        st = gen_loc_elif(st, node.els);
        st = gen(st, node.els);
        emit_label(st, r2)
    } else {
        emit_label(st, r1)
    }
};

def gen_while(st: EmitSt, node: While) -> EmitSt {
    let r1 = next_loc(st);
    let r2 = next_loc(st);
    st = gen_rg_loop_enter(st, node.body);
    st = emit_label(st, r1);
    let jcc = int_cmp_jcc(st, node.cond);
    if (jcc != 0) {
        let cbin: Bin = node.cond;
        st = gen_cmp_flags(st, cbin);
        st = emit_insn(st, jcc, r2, 0, 0, 0, 0, 0, 0);
    } else if (is_logic(st, node.cond)) {
        st = gen_branch(st, node.cond, r2, false);
    } else {
        st = gen(st, node.cond);
        st = emit_jz(st, r2);
    };
    // A `while` has no step, so "the next turn" IS the head: continue goes to
    // r1 and nothing else is needed.
    let saved_brk = brk_label;
    let saved_cont = cont_label;
    brk_label = r2;
    cont_label = r1;
    loop_names += "";
    loop_brks += brk_label;
    loop_conts += cont_label;
    st = gen_rg_tick(st, node.body);
    st = gen_discard(st, auto_inner(node.body));
    loop_names = loop_names[0:len(loop_names) - 1];
    loop_brks = loop_brks[0:len(loop_brks) - 1];
    loop_conts = loop_conts[0:len(loop_conts) - 1];
    brk_label = saved_brk;
    cont_label = saved_cont;
    st = gen_loc_loop(st, node);
    st = emit_insn(st, insn.F_JMP_L, r1, 0, 0, 0, 0, 0, 0);
    st = emit_label(st, r2);
    gen_rg_loop_leave(st, node.body)
};

// ── counted loops ──────────────────────────────────────────────────────
// All three lower to the same shape as `while`: a head label, a test, the
// body, a step, and a jump back. The loop variable is a normal local slot,
// so nothing new is needed at runtime.

def gen_for(st: EmitSt, node: For) -> EmitSt {
    // for (init; cond; step) body
    st = gen(st, node.init);
    let r1 = next_loc(st);
    let r2 = next_loc(st);
    st = gen_rg_loop_enter(st, node.body);
    st = emit_label(st, r1);
    let jcc = int_cmp_jcc(st, node.cond);
    if (jcc != 0) {
        let cbin: Bin = node.cond;
        st = gen_cmp_flags(st, cbin);
        st = emit_insn(st, jcc, r2, 0, 0, 0, 0, 0, 0);
    } else if (is_logic(st, node.cond)) {
        st = gen_branch(st, node.cond, r2, false);
    } else {
        st = gen(st, node.cond);
        st = emit_jz(st, r2);
    };
    // `for` is the one loop where `continue` cannot go to the head: the step is
    // between the body and the head, and skipping it would leave the loop
    // variable where it was -- `for (i = 0; i < n; i++) { continue; }` would
    // never end. So a third label sits between the body and the step.
    let r3 = next_loc(st);
    let saved_brk = brk_label;
    let saved_cont = cont_label;
    brk_label = r2;
    cont_label = r3;
    loop_names += "";
    loop_brks += brk_label;
    loop_conts += cont_label;
    st = gen_rg_tick(st, node.body);
    st = gen_discard(st, auto_inner(node.body));
    loop_names = loop_names[0:len(loop_names) - 1];
    loop_brks = loop_brks[0:len(loop_brks) - 1];
    loop_conts = loop_conts[0:len(loop_conts) - 1];
    brk_label = saved_brk;
    cont_label = saved_cont;
    st = emit_label(st, r3);
    st = gen_loc_loop(st, node);
    st = gen(st, node.step);
    st = emit_insn(st, insn.F_JMP_L, r1, 0, 0, 0, 0, 0, 0);
    st = emit_label(st, r2);
    gen_rg_loop_leave(st, node.body)
};

def gen_forrange(st: EmitSt, node: ForRange) -> EmitSt {
    // for (x in lo..hi) body — half-open: lo inclusive, hi exclusive.
    // Slot layout: [var][limit]; the limit is evaluated once.
    let voff = (st.slots + 1) * -8;
    let loff = (st.slots + 2) * -8;
    st = { ...st, slots: st.slots + 2 };
    st = gen_save_value(st, node.hi, loff);
    st = gen_save_value(st, node.lo, voff);
    st = env_define(st, node.name, SK.local, voff, -1, "", normtype({ k: K.tlong }));
    let r1 = next_loc(st);
    let r2 = next_loc(st);
    st = gen_rg_loop_enter(st, node.body);
    st = emit_label(st, r1);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, voff, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, loff, -1, insn.R_RCX, 64);
    st = emit_insn(st, insn.F_CMP_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JGE_L, r2, 0, 0, 0, 0, 0, 0);
    let r3 = next_loc(st);
    let saved_brk = brk_label;
    let saved_cont = cont_label;
    brk_label = r2;
    cont_label = r3;
    loop_names += node.name;
    loop_brks += brk_label;
    loop_conts += cont_label;
    st = gen_rg_tick(st, node.body);
    st = box_bound(st, node.name);
    st = gen_discard(st, auto_inner(node.body));
    loop_names = loop_names[0:len(loop_names) - 1];
    loop_brks = loop_brks[0:len(loop_brks) - 1];
    loop_conts = loop_conts[0:len(loop_conts) - 1];
    brk_label = saved_brk;
    cont_label = saved_cont;
    st = emit_label(st, r3);
    st = gen_loc_loop(st, node);
    // the counter in place: one instruction, not a load, an inc and a store
    st = emit_loop_next(st, voff, r1);
    st = emit_label(st, r2);
    gen_rg_loop_leave(st, node.body)
};

def gen_foreach(st: EmitSt, node: Foreach) -> EmitSt {
    // foreach (x in arr) body. Slots: [x][arr][i]. The array is evaluated
    // once; `x` is refreshed from arr[i] at the top of every iteration.
    let voff = (st.slots + 1) * -8;
    let aoff = (st.slots + 2) * -8;
    let ioff = (st.slots + 3) * -8;
    st = { ...st, slots: st.slots + 3 };
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
    if (elt.k == K.tmap) {
        // keys: the map record is {boxes@0, keys@8, vals@16} (gen_maplit),
        // and a key is a str -- one word, like every other unboxed value.
        let mp: TMap = elt;
        eltyp = mp.key;
    }
    if (elt.k == K.tstr) { eltyp = normtype({ k: K.tbyte }); }
    st = gen_save_value(st, node.iter, aoff);
    st = emit_zero_slot(st, ioff);
    st = env_define(st, node.name, SK.local, voff, -1, "", eltyp);
    let r1 = next_loc(st);
    let r2 = next_loc(st);
    st = gen_rg_loop_enter(st, node.body);
    st = emit_label(st, r1);
    let is_map = (elt.k == K.tmap);
    let is_str = (elt.k == K.tstr);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, aoff, -1, insn.R_RDX, 64);
    if (is_map) {
        // A map keeps no length of its own: %rdx is the record, and its keys
        // array (at +8) is the thing with the length in its first word.
        st = emit_insn(st, insn.F_MOV_M_R, insn.R_RDX, -1, 1, 8, -1, insn.R_R11, 64);
        st = emit_insn(st, insn.F_MOV_0_R, insn.R_R11, -1, 1, -1, -1, insn.R_RCX, 64);
    } else {
        // an array header and a string header both start with the length
        st = emit_insn(st, insn.F_MOV_0_R, insn.R_RDX, -1, 1, -1, -1, insn.R_RCX, 64);
    };
    st = emit_slot_bound(st, ioff, r2);
    // x = it[i]
    if (is_map) {
        // The key out of the keys array: %r11 is its header (still there from
        // the length's load -- %rax holds the counter by now), and its data
        // pointer is 16 bytes into it.
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_R11, -1, 1, 16, -1, insn.R_R11, 64);
        st = emit_insn(st, insn.F_MOV_M_R, insn.R_R11, insn.R_RAX, 8, 0, -1, insn.R_RCX, 64);
    } else if (is_str) {
        // A string's bytes follow its length, in place: 8(%rdx,%rax,1), with
        // no data pointer to load first (a heap array has one, a string does
        // not -- which is why an owned string can append into its own buffer).
        st = emit_insn(st, insn.F_MOVZBQ_M_R, insn.R_RDX, insn.R_RAX, 1, 8, -1, insn.R_RCX, 64);
    } else {
        st = elem_load(st, arr_elem_bytes(elt), insn.R_RDX, insn.R_RAX, insn.R_RCX);
    };
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RCX, 64, insn.R_RBP, -1, 1, voff, -1);
    // continue -> just before the increment, for the reason in gen_forrange
    let r3 = next_loc(st);
    let saved_brk = brk_label;
    let saved_cont = cont_label;
    brk_label = r2;
    cont_label = r3;
    loop_names += node.name;
    loop_brks += brk_label;
    loop_conts += cont_label;
    st = gen_rg_tick(st, node.body);
    st = box_bound(st, node.name);
    st = gen_discard(st, auto_inner(node.body));
    loop_names = loop_names[0:len(loop_names) - 1];
    loop_brks = loop_brks[0:len(loop_brks) - 1];
    loop_conts = loop_conts[0:len(loop_conts) - 1];
    brk_label = saved_brk;
    cont_label = saved_cont;
    st = emit_label(st, r3);
    st = gen_loc_loop(st, node);
    // the counter in place: one instruction, not a load, an inc and a store
    st = emit_loop_next(st, ioff, r1);
    st = emit_label(st, r2);
    gen_rg_loop_leave(st, node.body)
};

// ── tail calls ─────────────────────────────────────────────────────────

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
                ee.kind == SK.func && ee.label == st.self_label
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
        let logic = jcc == 0 && is_logic(st, branch.cond);
        if (jcc == 0 && !logic) { st = gen(st, branch.cond); }
        let rl1 = next_loc(st);
        let lelse = rl1;
        let rl2 = next_loc(st);
        let lend = rl2;
        if (jcc != 0) {
            // the flags come from the comparison itself (see int_cmp_jcc)
            let cbin: Bin = branch.cond;
            st = gen_cmp_flags(st, cbin);
            st = emit_insn(st, jcc, lelse, 0, 0, 0, 0, 0, 0);
        } else if (logic) {
            st = gen_branch(st, branch.cond, lelse, false);
        } else {
            st = emit_jz(st, lelse);
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

// Convert values between static layouts, including union boxing and narrowing.
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
            st = emit_insn(st, insn.F_MOV_D_R, insn.R_RAX, -1, 1, -8, -1, insn.R_RCX, 64);
            let lbls: [long] = [];
            let i = 0;
            while (i < len(ms)) {
                let l = next_loc(st);
                lbls += l;
                let dr = ty_desc_in(st, ms[i], s);
                st = dr.st;
                st = emit_insn(st, insn.F_LEA_P_R, -1, -1, 1, 0, dr.label, insn.R_RDX, 64);
                st = emit_insn(st, insn.F_CMP_R_R, insn.R_RDX, 64, insn.R_RCX, 64, 0, 0, 0);
                st = emit_insn(st, insn.F_JE_L, l, 0, 0, 0, 0, 0, 0);
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
                if (i < len(ms) - 1) { st = emit_insn(st, insn.F_JMP_L, done, 0, 0, 0, 0, 0, 0); };
                i++;
            };
            emit_label(st, done)
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
    // %rcx holds the new record after every field's store. A field whose value
    // loads without touching %rcx (rec_leaf_field) is stored through it as it
    // stands; any other runs with the record parked on the stack and reloads
    // %rcx from there. When every field is the first kind nothing is parked.
    let leafs: [bool] = [];
    let parked = false;
    for li in 0..nent {
        let lf = mkeys[li] != "..." && rec_leaf_field(st, mvals[li], rtu, mkeys[li]);
        leafs += lf;
        if (!lf) { parked = true; };
    };
    st = emit_insn(st, insn.F_MOV_I_R, 8 * n + 16, insn.R_RDI, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_alloc"), 0, 0, 0, 0, 0, 0);
    if (parked) { st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0); };
    st = emit_insn(st, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_RCX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_LEA_P_R, -1, -1, 1, 0, dr.label, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RCX, -1, 1, 0, -1);
    for i in 0..nent {
        // mv is walked twice (gen, then infer), so bind it once.
        let mv = mvals[i];
        let mk = mkeys[i];
        if (leafs[i]) {
            let off = 8 + (mfield_idx(slots, mk)) * 8;
            let im = rec_leaf_imm(mv);
            if (im >= 0) {
                st = emit_insn(st, insn.F_MOV_I_D, im, insn.R_RCX, -1, 1, off, -1, 0);
            } else {
                st = gen(st, mv);
                st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RCX, -1, 1, off, -1);
            };
        } else if (mk == "...") {
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
            };
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
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
            st = emit_insn(st, insn.F_MOV_0_R, insn.R_RSP, -1, 1, 0, -1, insn.R_RCX, 64);
            st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RCX, -1, 1, 8 + (mfield_idx(slots, mk)) * 8, -1);
        };
    };
    if (parked) {
        st = emit_insn(st, insn.F_POP_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        emit_insn(st, insn.F_ADD_I_R, 8, insn.R_RAX, 64, 0, 0, 0, 0)
    } else {
        emit_insn(st, insn.F_LEA_D_R, insn.R_RCX, -1, 1, 8, -1, insn.R_RAX, 64)
    }
};

// Field mk of a literal made as rtu takes mv with no code but mv's own load,
// and that load leaves %rcx alone (gen_reclit keeps the record there): a leaf
// that is not captured, not wrapped as some(v), and of the field's own type,
// so gen_as would convert nothing.
def rec_leaf_field(st: EmitSt, mv: Node, rtu: Type, mk: str) -> bool {
    if (!rcx_free_leaf(st, mv) && rec_leaf_imm(mv) < 0) { return false; };
    let ft = rec_field_type(rtu, mk);
    if (lit_wraps(st, mv, rtu, mk, ft)) { return false; };
    let w = types.unfold(ft);
    let wk = w.k;
    // (a float, byte or bigint field keeps its gen_as store even when the value
    // is already of that type: the leaf load is not the shortcut there)
    if (conv_kind(wk)) { wk == K.tptr && !needs_conv(infer(st, mv), w) }
    else if (wk == K.trec) { types.unfold(infer(st, mv)).k == K.trec }
    else if (wk == K.tunion) { types.teq(types.unfold(infer(st, mv)), w) }
    else { true }
};

// The 32-bit immediate a leaf field stores directly, else -1: a small integer
// literal (or a folded const), true and false, none.
def rec_leaf_imm(mv: Node) -> long {
    let k = mv.k;
    if (k == K.bool) {
        let b: Leaf = mv;
        if (b.v == "true") { 1 } else { 0 }
    } else if (k == K.id) {
        let id: Leaf = mv;
        if (id.v == "none") { 0 } else { imm_lit(mv) }
    } else { imm_lit(mv) }
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
    caps.foreach((e) => {
        let bcn: str = e;
        st = box_capture(st, bcn);
    });
    gen_make_closure(st, lbl, caps)
};

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
    let st3 = { ...st, slots: st.slots + 1 };
    st3 = env_define(st3, name, SK.closure, coff, -1, "", func_type_in(st3, func));
    box_bound(st3, name)
};

// ── a global's initializer, delimited ───────────────────────────────────
def gen_decl_marked(st: EmitSt, node: Decl) -> EmitSt {
    let ge = env_find(st, node.name);
    if (ge.kind != SK.global) {
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
            st = unfold(node.typ).k == K.tmap && len(rec.keys) == 0 ? gen_maplit(st, rec, map_hashed(map_key_of(node.typ))) : gen_as(st, rec, node.typ);
            let t: Type = node.typ;
            if (t.k == K.tnone) {
                t = infer(st, rec);
            };
            bind_decl(st, node.name, t)
        } else {
            st = gen_as(st, node.v, node.typ);
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
    if (ge.kind == SK.global) {
        st = emit_insn(st, insn.F_MOV_R_P, insn.R_RAX, 64, -1, -1, 1, 0, ge.label);
        env_define(st, name, SK.global, 0, ge.label, "", t)
    } else if (t.k == K.tstr && own_wanted(st, name)) {
        bind_own(st, name, t)
    } else {
        let off = (st.slots + 1) * -8;
        st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, off, -1);
        let st2 = { ...st, slots: st.slots + 1 };
        st2 = env_define(st2, name, SK.local, off, -1, "", t);
        box_bound(st2, name)
    }
};

def gen_assign(st: EmitSt, node: Assign) -> EmitSt {
    let e = env_find(st, node.name);
    st = gen_as(st, node.v, e.typ);
    if (e.kind == SK.capture) {
        let idx = leading_long(e.mark);
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, e.off, -1, insn.R_RCX, 64);
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RCX, -1, 1, 8 * (idx + 1), -1, insn.R_RDX, 64);
        st = emit_insn(st, insn.F_MOV_R_0, insn.R_RAX, 64, insn.R_RDX, -1, 1, -1, -1);
        st
    } else if (e.kind == SK.box) {
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, e.off, -1, insn.R_RDX, 64);
        st = emit_insn(st, insn.F_MOV_R_0, insn.R_RAX, 64, insn.R_RDX, -1, 1, -1, -1);
        st
    } else if (e.kind == SK.global) {
        emit_insn(st, insn.F_MOV_R_P, insn.R_RAX, 64, -1, -1, 1, 0, e.label)
    } else {
        emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, e.off, -1)
    }
};

// Fill n frame slots (base = lowest address) with the value in %rax.

// Heap-array fill: the header is in %rdx, the fill value in %rax. Writes
// data[i] for i = n-1 .. 0 (data starts at header+16).
def gen_fill_heap(st: EmitSt, n: long, esz: long) -> EmitSt {
    if (n == 0) {
        st
    } else {
        let r = next_loc(st);
        st = emit_insn(st, insn.F_MOV_R_R, insn.R_RDX, 64, insn.R_R10, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_RDX, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_I_R, n, insn.R_RCX, 64, 0, 0, 0, 0);
        st = emit_label(st, r);
        st = emit_insn(st, insn.F_DEC_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
        st = elem_store_rdx(st, esz, insn.R_R10, insn.R_RCX);
        st = emit_insn(st, insn.F_JNZ_L, r, 0, 0, 0, 0, 0, 0);
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
    let t = 62 - ((ndig + dp) * 33219 / 10000) + 4;
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
        let p53 = flit_dfrom(9007199254740992, n);               // 2^53
        let p54 = flit_dfrom(18014398509481984, n);              // 2^54
        while (flit_dlt(a, p53, n)) {
            flit_dmul(a, 2, n);
        };
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
    st = gen_runtime_call(st, helper, 16);
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
    let garr = node.arr;
    let bt = infer(st, garr);
    let ixesz = arr_elem_bytes(bt);
    st = gen_push_value(st, garr);
    st = gen(st, node.idx);
    st = emit_pop_left(st);
    st = emit_insn(st, insn.F_TEST_R_R, insn.R_RCX, 64, insn.R_RCX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JS_L, lbl_new("y_oob"), 0, 0, 0, 0, 0, 0);
    if (bt.k == K.tarrfix) {
        let fixed: TFix = bt;
        st = emit_insn(st, insn.F_CMP_I_R, fixed.n, insn.R_RCX, 64, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_JGE_L, lbl_new("y_oob"), 0, 0, 0, 0, 0, 0);
        elem_load(st, ixesz, insn.R_RAX, insn.R_RCX, insn.R_RAX)
    } else {
        st = emit_insn(st, insn.F_CMP_M_R, insn.R_RAX, -1, 1, 0, -1, insn.R_RCX, 64);
        st = emit_insn(st, insn.F_JGE_L, lbl_new("y_oob"), 0, 0, 0, 0, 0, 0);
        elem_load(st, ixesz, insn.R_RAX, insn.R_RCX, insn.R_RAX)
    }
};

def gen_sizeof(st: EmitSt, node: Call, name: str) -> EmitSt {
    let args: [Node] = node.args;
    let nar: Narrow = args[0];
    let pk = types.unfold(nar.typ);
    let v = types.pack_size(pk);
    if (name == "offsetof") {
        let kn: Leaf = args[1];
        v = types.pack_offset(pk, kn.v);
    };
    emit_insn(st, insn.F_MOV_I_R, v, insn.R_RAX, 64, 0, 0, 0, 0)
};

// ── packed records ─────────────────────────────────────────────────────────

// The type a field of type t has in memory, as gen_ptr_load/gen_ptr_store see a
// pointee: a bool is a byte, a long, float or pointer a full word.
def pack_mem_type(t: Type) -> Type {
    let u = types.unfold(t);
    if (u.k == K.tint || u.k == K.tbyte) { u }
    else if (u.k == K.tbool) { normtype({ k: K.tbyte }) }
    else { normtype({ k: K.tlong }) }
};

def pack_ptr(t: Type) -> Type {
    normtype({ k: K.tptr, to: pack_mem_type(t) })
};

// The pointer type of a bitmap's backing integer (unsigned, native order).
def pack_bits_ptr(bk: long) -> Type {
    let mt: Type = normtype({ k: K.tlong });
    if (bk == 1) { mt = normtype({ k: K.tbyte }); }
    else if (bk < 8) {
        let ti: TInt = { k: K.tint, w: bk, sg: false, be: false };
        mt = ti;
    };
    normtype({ k: K.tptr, to: mt })
};

// Field `key` of the packed value whose address is in %rax: its value in %rax (a
// nested pack or an array stays an address).
def gen_pack_load(st: EmitSt, pk: Type, key: str) -> EmitSt {
    let pkt: TPack = pk;
    let off = types.pack_offset(pk, key);
    let ft = types.pack_ftype(pk, key);
    if (pkt.bk > 0) {
        let bi: TInt = ft;
        st = gen_ptr_load(st, pack_bits_ptr(pkt.bk));
        let up = 64 - off - bi.w;
        if (up > 0) { st = emit_insn(st, insn.F_SHL_I_R, up, insn.R_RAX, 64, 0, 0, 0, 0); };
        if (bi.w < 64) { st = emit_insn(st, insn.F_SHR_I_R, 64 - bi.w, insn.R_RAX, 64, 0, 0, 0, 0); };
        st
    } else {
        if (off > 0) { st = emit_insn(st, insn.F_ADD_I_R, off, insn.R_RAX, 64, 0, 0, 0, 0); };
        let u = types.unfold(ft);
        if (u.k == K.tpack || u.k == K.tarrfix) { st } else { gen_ptr_load(st, pack_ptr(u)) }
    }
};

// Store the value in %rax to field `key` of the packed value whose address is in %rcx.
def gen_pack_store(st: EmitSt, pk: Type, key: str) -> EmitSt {
    let pkt: TPack = pk;
    let off = types.pack_offset(pk, key);
    let ft = types.pack_ftype(pk, key);
    if (pkt.bk > 0) {
        let bi: TInt = ft;
        // the new bits, cut to the width and moved into place
        if (bi.w < 64) {
            st = emit_insn(st, insn.F_SHL_I_R, 64 - bi.w, insn.R_RAX, 64, 0, 0, 0, 0);
            st = emit_insn(st, insn.F_SHR_I_R, 64 - bi.w, insn.R_RAX, 64, 0, 0, 0, 0);
        };
        if (off > 0) { st = emit_insn(st, insn.F_SHL_I_R, off, insn.R_RAX, 64, 0, 0, 0, 0); };
        st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0);
        st = gen_ptr_load(st, pack_bits_ptr(pkt.bk));
        let fieldmask = ((1 << bi.w) - 1) << off;
        st = emit_insn(st, insn.F_MOV_I_R, ~fieldmask, insn.R_RDX, 64, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_AND_R_R, insn.R_RDX, 64, insn.R_RAX, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_POP_R, insn.R_RDX, 64, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_OR_R_R, insn.R_RDX, 64, insn.R_RAX, 64, 0, 0, 0);
        gen_ptr_store(st, pack_bits_ptr(pkt.bk))
    } else {
        if (off > 0) { st = emit_insn(st, insn.F_ADD_I_R, off, insn.R_RCX, 64, 0, 0, 0, 0); };
        gen_ptr_store(st, pack_ptr(ft))
    }
};

// A packed literal: a zeroed block, then each field stored at its place. The
// block's address waits on the stack while the values are computed.
def gen_packlit(st: EmitSt, node: RecLit, pk: Type) -> EmitSt {
    let size = types.pack_size(pk);
    if (size < 8) { size = 8; };
    st = emit_insn(st, insn.F_MOV_I_R, size, insn.R_RDI, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_alloc"), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen_pack_init(st, node, pk, 0);
    emit_insn(st, insn.F_POP_R, insn.R_RAX, 64, 0, 0, 0, 0, 0)
};

// The fields of literal `node` stored into the block at (%rsp), `at` bytes in.
def gen_pack_init(st: EmitSt, node: RecLit, pk: Type, at: long) -> EmitSt {
    let keys: [str] = node.keys;
    let vals: [Node] = node.vals;
    for i in 0..len(keys) {
        let key: str = keys[i];
        let val: Node = vals[i];
        let ft = types.pack_ftype(pk, key);
        let vt = types.pack_value_type(pk, ft);
        let off = types.pack_offset(pk, key);
        if (vt.k == K.tpack) {
            let inner: RecLit = val;
            st = gen_pack_init(st, inner, vt, at + off);
        } else {
            st = gen_as(st, val, vt);
            st = emit_insn(st, insn.F_MOV_0_R, insn.R_RSP, -1, 1, 0, -1, insn.R_RCX, 64);
            // (a bit field: the backing integer sits at the literal's own offset)
            if (at > 0) { st = emit_insn(st, insn.F_ADD_I_R, at, insn.R_RCX, 64, 0, 0, 0, 0); };
            st = gen_pack_store(st, pk, key);
        };
    };
    st
};

def gen_dotassign(st: EmitSt, node: DotAssign) -> EmitSt {
    let dobj = node.obj;
    let dkey = node.key;
    let dt = infer(st, dobj);
    let dpk = types.pack_of(dt);
    if (dpk.k == K.tpack) {
        // a packed field: the object is the address of the bytes
        let dpf = types.pack_ftype(dpk, dkey);
        st = gen_push_value(st, dobj);
        st = gen_as(st, node.v, types.pack_value_type(dpk, dpf));
        st = emit_insn(st, insn.F_POP_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
        return gen_pack_store(st, dpk, dkey)
    };
    if (dt.k == K.tmap) {
        // `m.k = v` is the entry, exactly as `m["k"] = v` (types.y
        // dotassign_map) -- the store creates or replaces it
        // and never traps.
        if (dkey == "length" || dkey == "ptr") {
            // the checker has already said this is not a place; trap rather
            // than emit a store somewhere wrong
            st = emit_insn(st, insn.F_CALL_L, lbl_new("y_match_fail"), 0, 0, 0, 0, 0, 0);
            return emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0)
        };
        let asg: IdxAssign = { k: K.idxassign, arr: dobj, idx: n_str(dkey, node.line, node.col), v: node.v, line: node.line, col: node.col };
        return gen_map_set(st, asg)
    };
    let idx = rec_field_idx(dt, dkey);
    st = gen_push_value(st, dobj);
    st = gen_as(st, node.v, rec_field_type(dt, dkey));
    st = emit_insn(st, insn.F_POP_R, insn.R_RDX, 64, 0, 0, 0, 0, 0);
    if (dt.k == K.tunion) {
        gen_union_slot(st, dt, dkey, true)
    } else {
        emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RDX, -1, 1, 8 * idx, -1)
    }
};

// ── ++/-- and op= ──────────────────────────────────────────────────────

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

def inplace_slot(st: EmitSt, node: Node) -> long {
    let off = 0;
    if (node.k == K.id) {
        let id: Leaf = node;
        let e = env_find(st, id.v);
        if (e.kind == SK.local && e.typ.k == K.tlong) { off = e.off; };
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
    r = as_num(r);
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
        st = emit_push_slot(st, slot);
        st = gen(st, node.v);
        st = emit_pop_left(st);
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

// Read and store through the bindings captured by gen_place_bind. A plain
// array variable can be reread; other bases and every index run exactly once.
def place_arr(tgt: Index, name: str, ln: long, cl: long) -> Leaf {
    if (tgt.arr.k == K.id) {
        let id: Leaf = tgt.arr;
        n_id(id.v, ln, cl)
    } else { n_id(name + "a", ln, cl) }
};

def gen_place_read(tgt: Node, name: str, ln: long, cl: long) -> Node {
    if (tgt.k == K.id) {
        let id: Leaf = tgt;
        return n_id(id.v, ln, cl);
    } else if (tgt.k == K.index) {
        let index: Index = tgt;
        return {k: K.index, arr: place_arr(index, name, ln, cl), idx: n_id(name, ln, cl), line: ln, col: cl};
    };
    let dot: Dot = tgt;
    {k: K.dot, obj: n_id(name, ln, cl), key: dot.key, line: ln, col: cl, nline: ln, ncol: cl}
};

def gen_place_assign(tgt: Node, value: Node, name: str, ln: long, cl: long) -> Node {
    if (tgt.k == K.id) {
        let id: Leaf = tgt;
        return {k: K.assign, name: id.v, v: value, line: ln, col: cl};
    } else if (tgt.k == K.index) {
        let index: Index = tgt;
        return {k: K.idxassign, arr: place_arr(index, name, ln, cl), idx: n_id(name, ln, cl), v: value, line: ln, col: cl};
    };
    let dot: Dot = tgt;
    {k: K.dotassign, obj: n_id(name, ln, cl), key: dot.key, v: value, line: ln, col: cl, nline: dot.nline, ncol: dot.ncol}
};

// Capture a target's evaluated base/index; an id needs no synthetic binding.
def gen_place_bind(tgt: Node, name: str, ln: long, cl: long) -> Node {
    if (tgt.k == K.id) { return {k: K.block, stmts: [], line: ln, col: cl}; };
    if (tgt.k == K.index) {
        let index: Index = tgt;
        let idx = n_decl(name, index.idx, ln, cl);
        if (index.arr.k == K.id) { return idx; };
        return block2(n_decl(name + "a", index.arr, ln, cl), idx, ln, cl);
    };
    let dot: Dot = tgt;
    n_decl(name, dot.obj, ln, cl)
};

def gen_opassign_arr(st: EmitSt, node: OpAssign, dropped: bool) -> EmitSt {
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
    let garr = node.arr;
    let bt: Type = infer(st, garr);
    let iaesz = arr_elem_bytes(bt);
    st = gen_push_value(st, garr);
    st = gen_push_value(st, node.idx);
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
        st = emit_insn(st, insn.F_CMP_M_R, insn.R_RDX, -1, 1, 0, -1, insn.R_RCX, 64);
        st = emit_insn(st, insn.F_JGE_L, lbl_new("y_oob"), 0, 0, 0, 0, 0, 0);
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

// Stop recursive type formatting when a type is already on this path.
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

// Root formatting starts a fresh recursion path, as the original public
// tostring/print entry points did; nested values extend it in the shared walk.
def gen_root_tostr_rax(st: EmitSt, t: Type) -> EmitSt {
    if (t.k == K.trec) { gen_rec_str_rax(st, t, lay_of(t, t), []) }
    else if (t.k == K.topt) { gen_opt_str_rax(st, t, []) }
    else if (t.k == K.tunion) { gen_union_str_rax(st, t, []) }
    else { gen_val_tostr_rax(st, t, []) }
};

// Format the value in rax; recursive aggregates extend the type path.
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
    } else if (tk == K.tarr || tk == K.tarrfix) {
        let arr: ArrTy = t;
        if (arr.of.k == K.tbyte) { gen_helper1(st, "y_bytes_repr") }
        else { gen_arr_tostr_rax(st, arr.of, path + t) }
    } else if (tk == K.topt) {
        gen_opt_str_rax(st, t, path + t)
    } else if (tk == K.trec) {
        gen_rec_str_rax(st, t, lay_of(t, t), path + t)
    } else if (tk == K.tunion) {
        gen_union_str_rax(st, t, path + t)
    } else if (tk == K.tmap) {
        gen_map_repr_rax(st, t, path + t)
    } else {
        gen_helper1(st, scalar_string_helper(tk))
    }
};
// acc = acc + <the string in %rax>.
def gen_acc_cat_rax(st: EmitSt, aoff: long) -> EmitSt {
    st = emit_insn(st, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_RDX, 64, 0, 0, 0);
    st = emit_push_slot(st, aoff);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RDX, 64, 0, 0, 0, 0, 0);
    st = gen_runtime_call(st, "y_str_cat", 16);
    emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, aoff, -1)
};

def gen_map_repr_rax(st: EmitSt, t: Type, path: [Type]) -> EmitSt {
    let moff = (st.slots + st.temp + 1) * -8;
    let aoff = (st.slots + st.temp + 2) * -8;
    let ioff = (st.slots + st.temp + 3) * -8;
    let koff = (st.slots + st.temp + 4) * -8;
    st = st_temp(st, st.temp + 4);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, moff, -1);
    st = gen_str_const(st, "{");
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, aoff, -1);
    st = emit_zero_slot(st, ioff);
    let r1 = next_loc(st);
    let r2 = next_loc(st);
    let r3 = next_loc(st);
    let map: TMap = t;
    st = emit_label(st, r1);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, moff, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RDX, -1, 1, 8, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RDX, -1, 1, -1, -1, insn.R_RCX, 64);
    st = emit_slot_bound(st, ioff, r2);
    st = emit_jz(st, r3);
    st = gen_acc_cat_slot(st, aoff, ", ");
    st = emit_label(st, r3);
    // the key, quoted when it is a str
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
    st = emit_loop_next(st, ioff, r1);
    st = emit_label(st, r2);
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
    st = emit_zero_slot(st, ioff);
    let r1 = next_loc(st);
    let r2 = next_loc(st);
    let r3 = next_loc(st);
    st = emit_label(st, r1);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, soff, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RDX, -1, 1, -1, -1, insn.R_RCX, 64);
    st = emit_slot_bound(st, ioff, r2);
    st = emit_jz(st, r3);
    st = gen_acc_cat_slot(st, aoff, ", ");
    st = emit_label(st, r3);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, soff, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, ioff, -1, insn.R_RCX, 64);
    st = elem_load(st, elem_bytes(elty), insn.R_RDX, insn.R_RCX, insn.R_RAX);
    st = gen_val_tostr_rax(st, elty, path);
    st = emit_insn(st, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_RDX, 64, 0, 0, 0);
    st = emit_push_slot(st, aoff);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RDX, 64, 0, 0, 0, 0, 0);
    st = gen_runtime_call(st, "y_str_cat", 16);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, aoff, -1);
    // the counter in place: one instruction, not a load, an inc and a store
    st = emit_loop_next(st, ioff, r1);
    st = emit_label(st, r2);
    st = gen_acc_cat_slot(st, aoff, "]");
    emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, aoff, -1, insn.R_RAX, 64)
};

// slot(%rbp) = slot(%rbp) + <constant>.
def gen_acc_cat_slot(st: EmitSt, off: long, s: str) -> EmitSt {
    st = emit_push_slot(st, off);
    st = gen_str_const(st, s);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = gen_runtime_call(st, "y_str_cat", 16);
    emit_insn(st, insn.F_MOV_R_D, insn.R_RAX, 64, insn.R_RBP, -1, 1, off, -1)
};

// ── element size ───────────────────────────────────────────────────────

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
        pointee_bytes(ptr.to)
    } else { 8 }
};

// Bytes a pointer's target occupies: a sized integer its width, a byte 1,
// anything else a full slot. Unlike elem_bytes this is not an array element
// width: [u16] is not a type, so no runtime helper ever sees a 2- or 4-byte one.
def pointee_bytes(t: Type) -> long {
    if (t.k == K.tint) { let ti: TInt = t; ti.w } else { elem_bytes(t) }
};

// `*p` where p is a pointer (its value in %rax): the load into %rax. A sized
// integer widens by its sign; a big-endian one is loaded zero-extended, byte
// swapped, and shifted back down (arithmetic when signed).
def gen_ptr_load(st: EmitSt, pt: Type) -> EmitSt {
    let to: Type = { k: K.tlong };
    if (pt.k == K.tptr) { let ptr: TPtr = pt; to = ptr.to; };
    if (to.k == K.tint) {
        let ti: TInt = to;
        let signed_load = ti.sg && !ti.be;
        let w = ti.w;
        if (w == 8) {
            st = emit_insn(st, insn.F_MOV_0_R, insn.R_RAX, -1, 1, -1, -1, insn.R_RAX, 64);
        } else if (w == 4) {
            if (signed_load) {
                st = emit_insn(st, insn.F_MOVSLQ_M_R, insn.R_RAX, -1, 1, 0, -1, insn.R_RAX, 64);
            } else {
                st = emit_insn(st, insn.F_MOVL_M_R, insn.R_RAX, -1, 1, 0, -1, insn.R_RAX, 32);
            }
        } else if (w == 2) {
            if (signed_load) {
                st = emit_insn(st, insn.F_MOVSWQ_M_R, insn.R_RAX, -1, 1, 0, -1, insn.R_RAX, 64);
            } else {
                st = emit_insn(st, insn.F_MOVZWQ_M_R, insn.R_RAX, -1, 1, 0, -1, insn.R_RAX, 64);
            }
        } else {
            st = emit_insn(st, insn.F_MOVSBQ_M_R, insn.R_RAX, -1, 1, 0, -1, insn.R_RAX, 64);
        };
        if (ti.be) {
            st = emit_insn(st, insn.F_BSWAPQ_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
            if (w < 8) {
                let sh = insn.F_SHR_I_R;
                if (ti.sg) { sh = insn.F_SAR_I_R; };
                st = emit_insn(st, sh, 64 - w * 8, insn.R_RAX, 64, 0, 0, 0, 0);
            };
        };
        st
    } else if (ptr_width(pt) == 1) {
        emit_insn(st, insn.F_MOVZBQ_0_R, insn.R_RAX, -1, 1, -1, -1, insn.R_RAX, 64)
    } else {
        emit_insn(st, insn.F_MOV_0_R, insn.R_RAX, -1, 1, -1, -1, insn.R_RAX, 64)
    }
};

// `*p = v`, v in %rax and p in %rcx. A big-endian target is swapped in %rdx
// so %rax still holds v.
def gen_ptr_store(st: EmitSt, pt: Type) -> EmitSt {
    let sw = ptr_width(pt);
    let to: Type = { k: K.tlong };
    if (pt.k == K.tptr) { let ptr: TPtr = pt; to = ptr.to; };
    let src = insn.R_RAX;
    if (to.k == K.tint) {
        let ti: TInt = to;
        if (ti.be) {
            src = insn.R_RDX;
            st = emit_insn(st, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_RDX, 64, 0, 0, 0);
            st = emit_insn(st, insn.F_BSWAPQ_R, insn.R_RDX, 64, 0, 0, 0, 0, 0);
            if (sw < 8) { st = emit_insn(st, insn.F_SHR_I_R, 64 - sw * 8, insn.R_RDX, 64, 0, 0, 0, 0); };
        };
    };
    if (sw == 1) { emit_insn(st, insn.F_MOVB_R_0, src, 8, insn.R_RCX, -1, 1, -1, -1) }
    else if (sw == 2) { emit_insn(st, insn.F_MOVW_R_M, src, 16, insn.R_RCX, -1, 1, 0, -1) }
    else if (sw == 4) { emit_insn(st, insn.F_MOVL_R_M, src, 32, insn.R_RCX, -1, 1, 0, -1) }
    else { emit_insn(st, insn.F_MOV_R_0, src, 64, insn.R_RCX, -1, 1, -1, -1) }
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
    let tpk = types.pack_of(t);
    if (tpk.k == K.tpack) {
        st = gen(st, dobj);
        gen_pack_load(st, tpk, dkey)
    } else if (tk == K.tarr || tk == K.tarrfix || tk == K.tstr) {
        gen_prop(st, dobj, dkey, node.line, node.col)
    } else if (tk == K.tunion) {
        st = gen(st, dobj);
        gen_union_slot(st, t, dkey, false)
    } else if (tk == K.tmap) {
        // `m.k` is the entry (types.y typeof_dot): `m.length`
        // is the property, any other name is the entry, the program stops
        // when it is not there. The emitter's own three fields come through
        // map$keys/map$vals/map$boxes (map_field), never by dot.
        if (dkey == "length") {
            gen_prop(st, dobj, dkey, node.line, node.col)
        } else {
            st = gen_dot_map(st, dobj, dkey, node.line, node.col)
        }
    } else {
        gen_dot_rec(st, dobj, dkey, t)
    }
};

// `m.k`: the entry named "k", or the program stops with the key in the
// message (a typo must not read as a missing entry). The checker typed the
// value; the scan code is gen_map_get's.
def gen_dot_map(st: EmitSt, obj: Node, dkey: str, ln: long, cl: long) -> EmitSt {
    let idx: Node = { k: K.index, arr: obj, idx: n_str(dkey, ln, cl), line: ln, col: cl };
    gen_map_get(st, idx, "dot")
};

// Field `dkey` of a union value (types.y union_field: every member has
// it, with one type): read into %rax from the record in %rax, or (store)
// %rax written to the record in %rdx. A field every member shares sits at
// one slot in every member held in the union (union_lay): one move.
def gen_union_slot(st: EmitSt, t: Type, dkey: str, store: bool) -> EmitSt {
    gen_slot_move(st, mfield_idx(union_shared(types.unfold(t)), dkey), store)
};

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
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RAX, -1, 1, -8, -1, insn.R_RCX, 64);
        let lbls: [long] = [];
        for d in 0..len(ds) - 1 {
            let l = next_loc(st);
            lbls += l;
            ms.foreach((e, j) => {
                if (slots[j] == ds[d]) {
                    let dr = ty_desc_in(st, e, s);
                    st = dr.st;
                    st = emit_insn(st, insn.F_LEA_P_R, -1, -1, 1, 0, dr.label, insn.R_RSI, 64);
                    st = emit_insn(st, insn.F_CMP_R_R, insn.R_RSI, 64, insn.R_RCX, 64, 0, 0, 0);
                    st = emit_insn(st, insn.F_JE_L, l, 0, 0, 0, 0, 0, 0);
                };
            });
        };
        st = gen_slot_move(st, ds[len(ds) - 1], false);
        st = emit_insn(st, insn.F_JMP_L, done, 0, 0, 0, 0, 0, 0);
        lbls.foreach((el, e) => {
            st = emit_label(st, el);
            st = gen_slot_move(st, ds[e], false);
            // not on the last arm: that one falls through into `done:`
            if (e < len(lbls) - 1) { st = emit_insn(st, insn.F_JMP_L, done, 0, 0, 0, 0, 0, 0); };
        });
        emit_label(st, done)
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
        if (key == "boxes") { idx = 0; } else if (key == "keys") { idx = 1; } else if (key == "vals") { idx = 2; } else if (key == "zidx") { idx = 3; };
    };
    idx
};

// map$keys / map$vals / map$boxes: the slot read `m.keys` used to be, now
// that a dot on a map is an entry (see map_field). The map is a record of
// boxes, keys, vals in that order.
def gen_map_field(st: EmitSt, node: Call, name: str) -> EmitSt {
    let args: [Node] = node.args;
    st = gen(st, args[0]);
    let slot = 0;
    if (name == "map$keys") { slot = 1 } else if (name == "map$vals") { slot = 2 } else if (name == "map$zidx") { slot = 3 };
    gen_slot_move(st, slot, false)
};

// Whether a map keyed by kt carries the hash index (zidx): str, long and float
// keys. A byte or bool key has at most 256 or 2 distinct values, which the
// inline scan covers in a few compares; those maps stay on it.
def map_key_of(t: Type) -> Type {
    let mt: TMap = unfold(t);
    mt.key
};

def map_hashed(kt: Type) -> bool {
    let k: long = unfold(kt).k;
    k == K.tstr || k == K.tlong || k == K.tfloat
};

// The runtime probe/index helpers for a hashed key type.
def map_helper(kt: Type, what: str) -> str {
    let k: long = unfold(kt).k;
    if (k == K.tstr) { "y_map_" + what + "_str" }
    else if (k == K.tfloat) { "y_map_" + what + "_float" }
    else { "y_map_" + what + "_long" }
};

// map$find(m, k): the entry index of key k in map m, or len(m) when absent.
// The runtime helper (rt.y) probes the hash index once the map has one and
// scans the keys before that.
def gen_map_find(st: EmitSt, node: Call) -> EmitSt {
    let args: [Node] = node.args;
    let m = args[0];
    let ln = node.line;
    let cl = node.col;
    let mt: TMap = unfold(infer(st, m));
    let pushed: [Node] = [];
    pushed += map_field(m, "keys", ln, cl);
    pushed += map_field(m, "zidx", ln, cl);
    pushed += args[1];
    st = gen_push_args(st, pushed);
    gen_runtime_call(st, map_helper(mt.key, "find"), 24)
};

// map$note(m): keep the hash index in step after a key was pushed.
def gen_map_note(st: EmitSt, node: Call) -> EmitSt {
    let args: [Node] = node.args;
    let m = args[0];
    let ln = node.line;
    let cl = node.col;
    let mt: TMap = unfold(infer(st, m));
    let pushed: [Node] = [];
    pushed += map_field(m, "keys", ln, cl);
    pushed += map_field(m, "zidx", ln, cl);
    st = gen_push_args(st, pushed);
    gen_runtime_call(st, map_helper(mt.key, "note"), 16)
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

def gen_array_esz(st: EmitSt, node: ArrLit, esz: long, ety: Type) -> EmitSt {
    let elems: [Node] = node.elems;
    let ek = ety.k;
    let imms: [long] = [];
    foreach (e in elems) {
        let im = if (ek == K.tlong || ek == K.tbyte || ek == K.tbool) { rec_leaf_imm(e) } else { -1 };
        imms += im;
        if (im < 0) {
            st = gen_as(st, e, ety);
            st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
        };
    };
    let n = len(elems);
    st = emit_insn(st, insn.F_MOV_I_R, arr_alloc_size(esz, n), insn.R_RDI, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_alloc"), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RAX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_I_R, arr_header_size(), insn.R_RDI, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CALL_L, lbl_new("y_alloc"), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_R10, 64, 0, 0, 0);
    // %rdx when nothing is popped after it (no REX byte), else %r11
    let dr = if (n > 0) { insn.R_R11 } else { insn.R_RDX };
    st = emit_insn(st, insn.F_POP_R, dr, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_I_0, n, insn.R_R10, -1, 1, -1, -1, 0);
    st = emit_insn(st, insn.F_MOV_I_D, n, insn.R_R10, -1, 1, 8, -1, 0);
    st = emit_insn(st, insn.F_MOV_R_D, dr, 64, insn.R_R10, -1, 1, 16, -1);
    let k = n - 1;
    while (k >= 0) {
        let im = imms[k];
        if (im >= 0) {
            st = esz == 1 ? emit_insn(st, insn.F_MOVB_I_D, im, insn.R_R11, -1, 1, k, -1, 0)
                : emit_insn(st, insn.F_MOV_I_D, im, insn.R_R11, -1, 1, k * 8, -1, 0);
        } else {
            st = emit_insn(st, insn.F_POP_R, insn.R_RDX, 64, 0, 0, 0, 0, 0);
            st = esz == 1 ? emit_insn(st, insn.F_MOVB_R_D, insn.R_RDX, 8, insn.R_R11, -1, 1, k, -1)
                : emit_insn(st, insn.F_MOV_R_D, insn.R_RDX, 64, insn.R_R11, -1, 1, k * 8, -1);
        };
        k = k - 1;
    };
    // pointer-free data: the block's own header word, bit 2 (mark_pf_arr)
    if (elem_pf(ety)) { st = emit_insn(st, insn.F_OR_I_D, 4, dr, -1, 1, -8, -1, 0); };
    emit_insn(st, insn.F_MOV_R_R, insn.R_R10, 64, insn.R_RAX, 64, 0, 0, 0)
};

def gen_len(st: EmitSt, node: Call) -> EmitSt {
    let args = node.args;
    let at = infer(st, args[0]);
    if (at.k == K.tmap) {
        // len(m) = len(m.keys): the entry count
        gen(st, n_call1("len", map_field(args[0], "keys", node.line, node.col), node.line, node.col))
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
    st = emit_push_imm(st, pesz);
    gen_runtime_call(st, "y_arr_push", (len(node.args) * 8 + 8))
};

// `arr += other` with one element type (gen_opassign_arr makes the call,
// a name no program can write): y_arr_extend appends other's elements in
// bulk.
def gen_push_all(st: EmitSt, node: Call) -> EmitSt {
    let pargs: [Node] = node.args;
    let pesz = arr_elem_bytes(infer(st, pargs[0]));
    st = gen_push_args_as(st, node.args, []);
    st = emit_push_imm(st, pesz);
    st = gen_runtime_call(st, "y_arr_extend", 24);
    mark_pf_arr(st, arr_elem_of(infer(st, pargs[0])))
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
        emit_bool(st)
    }
};

def gen_unwrap(st: EmitSt, node: Call) -> EmitSt {
    let args: [Node] = node.args;
    if (is_map_read(st, args[0])) {
        // m[k]!: the entry's value itself, nothing is boxed
        gen_map_get(st, args[0], "val")
    } else {
        st = gen(st, args[0]);
        st = emit_jz(st, lbl_new("y_opt_unwrap"));
        emit_insn(st, insn.F_MOV_0_R, insn.R_RAX, -1, 1, -1, -1, insn.R_RAX, 64)
    }
};

// ── string builtins (all on {len, data} header objects) ────────────────
// Every helper takes header addresses via the Y calling convention
// (args pushed left-to-right, first arg deepest) and returns a header
// address (or long) in %rax. Caller cleans the stack.

def gen_trim(st: EmitSt, node: Call) -> EmitSt {
    st = gen_push_args(st, node.args);
    gen_runtime_call(st, "y_str_trim", 8)
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
    st = emit_push_imm(st, pesz);
    gen_runtime_call(st, "y_arr_prepend", (len(node.args) * 8 + 8))
};

// byte_at(s, i): byte i of string s, trapped when out of bounds. This is
// the primitive every string helper is built on — reading one byte must
// not copy the string the way bytes() does. Inline, four instructions,
// because scanning loops call it per character.
def gen_byte_at(st: EmitSt, node: Call) -> EmitSt {
    let args: [Node] = node.args;
    st = gen_push_value(st, args[0]);
    st = gen(st, args[1]);
    st = emit_insn(st, insn.F_POP_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_TEST_R_R, insn.R_RAX, 64, insn.R_RAX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JS_L, lbl_new("y_oob"), 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_CMP_M_R, insn.R_RCX, -1, 1, 0, -1, insn.R_RAX, 64);
    st = emit_insn(st, insn.F_JGE_L, lbl_new("y_oob"), 0, 0, 0, 0, 0, 0);
    emit_insn(st, insn.F_MOVZBQ_M_R, insn.R_RCX, insn.R_RAX, 1, 8, -1, insn.R_RAX, 64)
};

def gen_mod(st: EmitSt, node: Call) -> EmitSt {
    let args: [Node] = node.args;
    st = gen_push_value(st, args[0]);
    st = gen(st, args[1]);
    st = emit_pop_left(st);
    st = emit_insn(st, insn.F_TEST_R_R, insn.R_RCX, 64, insn.R_RCX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JZ_L, lbl_new("y_div_zero"), 0, 0, 0, 0, 0, 0);
    let m1 = next_loc(st);
    let m2 = next_loc(st);
    st = emit_insn(st, insn.F_CMP_I_R, -1, insn.R_RCX, 64, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_JNE_L, m1, 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
    st = emit_insn(st, insn.F_JMP_L, m2, 0, 0, 0, 0, 0, 0);
    st = emit_label(st, m1);
    st = emit_insn(st, insn.F_CQO, 0, 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_IDIV_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_R_R, insn.R_RDX, 64, insn.R_RAX, 64, 0, 0, 0);
    st = emit_label(st, m2);
    let m3 = next_loc(st);
    st = emit_jz(st, m3);
    st = emit_insn(st, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_RDX, 64, 0, 0, 0);
    // xor %rcx, %rdx: the divisor is in RCX and the adjustment below still
    // needs it, so the SIGN TEST goes into RDX (written the other way round
    // RCX was overwritten by the test itself, and mod(-949, 100) came out
    // -134 instead of 51)
    st = emit_insn(st, insn.F_XOR_R_R, insn.R_RCX, 64, insn.R_RDX, 64, 0, 0, 0);
    st = emit_insn(st, insn.F_JNS_L, m3, 0, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_ADD_R_R, insn.R_RCX, 64, insn.R_RAX, 64, 0, 0, 0);
    emit_label(st, m3)
};

def gen_ord(st: EmitSt, node: Call) -> EmitSt {
    st = gen_push_args(st, node.args);
    gen_runtime_call(st, "y_str_ord", 8)
};

def gen_chr(st: EmitSt, node: Call) -> EmitSt {
    st = gen_push_args(st, node.args);
    gen_runtime_call(st, "y_str_chr", 8)
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
    gen_runtime_call(st, lbl, 8)
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
        gen_runtime_call(st, "y_bigint_to_float", 8)
    } else {
        st = gen_push_args(st, node.args);
        gen_runtime_call(st, "y_str_tofloat", 8)
    }
};

def gen_tostring(st: EmitSt, node: Call) -> EmitSt {
    let args: [Node] = node.args;
    let t = infer(st, args[0]);
    st = gen(st, args[0]);
    gen_root_tostr_rax(st, t)
};
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
            gen_runtime_call(st, "y_fmt_s", 32)
        } else if (['d', 'x', 'X', 'o', 'b', 'c'].index(ty) >= 0) {
            st = gen_push_value(st, a0);
            st = fmt_push(st, code);
            st = fmt_push(st, f.width);
            gen_runtime_call(st, "y_fmt_i", 24)
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
            gen_runtime_call(st, "y_fmt_f", 32)
        }
    }
};

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
    emit_push_imm(st, v)
};

def gen_index_of(st: EmitSt, node: Call, last: bool) -> EmitSt {
    st = gen_push_args(st, node.args);
    if (len(node.args) < 3) {
        st = gen_push_value(st, n_num(default_offset(last), node.line, node.col));
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
        gen_runtime_call(st, "y_str_join", 16)
    }
};

// Slots: [src][dst][i]. Builds dst = [tostr(src[0]), ...] then joins it.
def gen_join_conv(st: EmitSt, node: Call, tostr_fn: str, esz: long) -> EmitSt {
    let soff = (st.slots + st.temp + 1) * -8;
    let doff = (st.slots + st.temp + 2) * -8;
    let ioff = (st.slots + st.temp + 3) * -8;
    st = st_temp(st, st.temp + 3);
    let jargs: [Node] = node.args;
    st = gen_save_value(st, jargs[0], soff);
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
    st = emit_zero_slot(st, ioff);
    let r1 = next_loc(st);
    let r2 = next_loc(st);
    st = emit_label(st, r1);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, soff, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_MOV_0_R, insn.R_RDX, -1, 1, -1, -1, insn.R_RCX, 64);
    st = emit_slot_bound(st, ioff, r2);
    st = elem_load(st, esz, insn.R_RDX, insn.R_RAX, insn.R_RCX);
    st = emit_insn(st, insn.F_PUSH_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
    st = gen_runtime_call(st, tostr_fn, 8);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, ioff, -1, insn.R_RCX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RBP, -1, 1, doff, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_MOV_D_R, insn.R_RDX, -1, 1, 16, -1, insn.R_RDX, 64);
    st = emit_insn(st, insn.F_MOV_R_M, insn.R_RAX, 64, insn.R_RDX, insn.R_RCX, 8, 0, -1);
    st = emit_insn(st, insn.F_INC_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
    st = emit_insn(st, insn.F_MOV_R_D, insn.R_RCX, 64, insn.R_RBP, -1, 1, ioff, -1);
    st = emit_insn(st, insn.F_JMP_L, r1, 0, 0, 0, 0, 0, 0);
    st = emit_label(st, r2);
    st = emit_push_slot(st, doff);
    st = gen_push_value(st, jargs[1]);
    gen_runtime_call(st, "y_str_join", 16)
};

def gen_split(st: EmitSt, node: Call) -> EmitSt {
    st = gen_push_args(st, node.args);
    gen_runtime_call(st, "y_str_split", 16)
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
    st = gen_push_value(st, largs[0]);
    st = gen_push_value(st, largs[1]);
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
        let done = next_loc(st);
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RSP, -1, 1, 8, -1, insn.R_RAX, 64);
        st = emit_insn(st, insn.F_CALL_L, lbl_new("y_mutex_trylock"), 0, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_TEST_R_R, insn.R_RAX, 64, insn.R_RAX, 64, 0, 0, 0);
        st = emit_insn(st, insn.F_JE_L, skip, 0, 0, 0, 0, 0, 0);
        st = gen_call_top(st);
        st = emit_insn(st, insn.F_MOV_D_R, insn.R_RSP, -1, 1, 8, -1, insn.R_RAX, 64);
        st = emit_insn(st, insn.F_CALL_L, lbl_new("y_mutex_unlock"), 0, 0, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_MOV_I_R, 1, insn.R_RAX, 64, 0, 0, 0, 0);
        st = emit_insn(st, insn.F_JMP_L, done, 0, 0, 0, 0, 0, 0);
        st = emit_label(st, skip);
        st = emit_insn(st, insn.F_XOR_R_R, insn.R_RAX, 32, insn.R_RAX, 32, 0, 0, 0);
        st = emit_label(st, done);
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
    let eargs: [Node] = node.args;
    st = gen_push_value(st, eargs[0]);
    st = gen_runtime_call(st, "y_os_exit", 8);
    // exit() terminates the process; the epilogue (ret / exit(0)) is
    // unreachable. Emit a jump to the function end so the backend never
    // falls through into dead code (and exit codes are never masked).
    emit_insn(st, insn.F_JMP_L, st.end_label, 0, 0, 0, 0, 0, 0)
};

// ── process I/O (argv) ──────────────────────────────────────────────

def gen_argv(st: EmitSt, node: Call) -> EmitSt {
    emit_insn(st, insn.F_CALL_L, lbl_new("y_argv"), 0, 0, 0, 0, 0, 0)
};

def gen_store(st: EmitSt, node: Store) -> EmitSt {
    let spt = infer(st, node.p);
    let sw = ptr_width(spt);
    let sto: Type = type_node({ k: K.tnone });
    if (sw == 8 && spt.k == K.tptr) { let ptr: TPtr = spt; sto = types.pointee_value(ptr.to); }
    st = gen_push_value(st, node.p);
    st = gen_as(st, node.v, sto);
    st = emit_insn(st, insn.F_POP_R, insn.R_RCX, 64, 0, 0, 0, 0, 0);
    gen_ptr_store(st, spt)
};

// ── functions ──────────────────────────────────────────────────────────
// Frame: locals at rbp-8, rbp-16, ...; params at rbp+16, rbp+24, ....
// Every emitted function gets: prologue, body, end_label, epilogue.

def emit_one_fn(st: EmitSt, label: long, fuid: long, func: EmitFunc, is_main: bool, want_argv: bool, captypes: [Type], selfname: str) -> EmitSt {
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
    let prev_rg_kinds = rg_kinds;
    let prev_rg_offs = rg_offs;
    let prev_rg_loops = rg_loops;
    rg_kinds = [];
    rg_offs = [];
    rg_loops = [];
    let f: EmitSt = { ir: [], txt: [], rodata: st.rodata, uid: st.uid,
        fuid: fuid, loc: 1, env: [], slots: 0, temp: 0,
        self_label: label, end_label: lbl_new(arch.arch_loc_label(fuid, 0)),
        fns: st.fns, bodies: st.bodies, btext: st.btext, blabels: st.blabels };
    // The names nested functions capture (see box_names / box_bound).
    f = env_define(f, "", SK.frame, 0, -1, "", type_node({ k: K.tnone }));
    // This function's type, for the conversions at its returns and its
    // self calls (cur_fn_type).
    let ftype: Type = type_node({ k: K.tfunc, args: func.ptypes, ret: fn_ret(func) });
    f = env_define(f, "", SK.fnty, 0, -1, "", ftype);
    let bnames = box_names(func);
    bnames.foreach((e) => {
        let bnm: str = e;
        f = env_define(f, "", SK.boxmark, 0, -1, bnm, type_node({ k: K.tnone }));
    });
    // The names this body appends to (see own_wanted), the same way.
    (app_names(func.body, false, bnames)).foreach((e) => {
        let anm: str = e;
        f = env_define(f, "", SK.appmark, 0, -1, anm, type_node({ k: K.tnone }));
    });
    // A capturing named function is not in that table (see
    // capturing_defs): bind its own name to this body, so a call by name
    // passes the record along (gen_direct) and a value is the record.
    if (selfname != "") {
        let func_node: Func = func;
        f = env_define(f, selfname, SK.func, 0, label, "", func_type_in(st, func_node));
    }
    // bind params. Caller pushes args left-to-right, so the LAST arg sits
    // at rbp+16 and param k lives at rbp+16+8*(n-1-k) (arity-dependent).
    let params: [str] = func.params;
    let ptypes: [Type] = func.ptypes;
    let nargs = len(params);
    for i in 0..nargs {
        f = env_define(f, params[i], SK.param, 16 + (nargs - 1 - i) * 8, -1, "", ptypes[i]);
    };
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
            f = env_define(f, cn, SK.capture, cloff, -1, tostring(c), ct);
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
    rg_kinds = prev_rg_kinds;
    rg_offs = prev_rg_offs;
    rg_loops = prev_rg_loops;
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
            body = insn.ir_push(body, insn.F_MOV_R_R, insn.R_RSP, 64, insn.R_RAX, 64, 0, 0, 0);
            body = insn.ir_push(body, insn.F_MOV_0_R, insn.R_RAX, -1, 1, 0, -1, insn.R_R15, 64);
            body = insn.ir_push(body, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_R14, 64, 0, 0, 0);
            body = insn.ir_push(body, insn.F_ADD_I_R, 8, insn.R_R14, 64, 0, 0, 0, 0);
            body = insn.ir_push(body, insn.F_PUSH_R, insn.R_R14, 64, 0, 0, 0, 0, 0);
            body = insn.ir_push(body, insn.F_PUSH_R, insn.R_R15, 64, 0, 0, 0, 0, 0);
            if (target_is_windows()) {
                // no argv on the stack: y_argv_win cuts the command line, and
                // the array it returns is what y_argv hands out (%r15)
                body = insn.ir_push(body, insn.F_CALL_L, lbl_new("y_argv_win"), 0, 0, 0, 0, 0, 0);
                body = insn.ir_push(body, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_R15, 64, 0, 0, 0);
            } else {
                body = insn.ir_push(body, insn.F_CALL_L, lbl_new("y_argv_init"), 0, 0, 0, 0, 0, 0);
            };
            // The arena baseline is taken AFTER the argument vector is copied
            // (and only when the vector was wanted at all): heap_used()
            // subtracts it, so an absolute figure stops moving with the length
            // of the command line.
            body = insn.ir_push(body, insn.F_CALL_L, lbl_new("y_heap_base_set"), 0, 0, 0, 0, 0, 0);
            body = insn.ir_push(body, insn.F_ADD_I_R, 16, insn.R_RSP, 64, 0, 0, 0, 0);
        }
    }
    body = insn.ir_push(body, insn.F_PUSH_R, insn.R_RBP, 64, 0, 0, 0, 0, 0);
    body = insn.ir_push(body, insn.F_MOV_R_R, insn.R_RSP, 64, insn.R_RBP, 64, 0, 0, 0);
    if (frame > 0) {
        body = insn.ir_push(body, insn.F_SUB_I_R, frame, insn.R_RSP, 64, 0, 0, 0, 0);
    }
    body = body + push_fold(f.ir);
    body = insn.ir_push(body, insn.IR_LABEL, f.end_label, 0, 0, 0, 0, 0, 0);
    if (is_main) {
        body = ir_terminate(body);
    } else {
        body = insn.ir_push(body, insn.F_MOV_R_R, insn.R_RBP, 64, insn.R_RSP, 64, 0, 0, 0);
        body = insn.ir_push(body, insn.F_POP_R, insn.R_RBP, 64, 0, 0, 0, 0, 0);
        if (nargs > 0 && pops_args(label)) {
            body = insn.ir_push(body, insn.F_RET_I, 8 * nargs, 0, 0, 0, 0, 0, 0);
        } else {
            body = insn.ir_push(body, insn.F_RET, 0, 0, 0, 0, 0, 0, 0);
        };
    };
    f.bodies += body;
    // The raw lines this body's IR_TEXT items index are this function's own
    // (f.txt is fresh per function), so they go with the body.
    f.btext += f.txt;
    let bodies = f.bodies;
    let btext = f.btext;
    f.blabels += lname(label);
    let blabels = f.blabels;
    { ...st, rodata: f.rodata, uid: f.uid, bodies: bodies, btext: btext, blabels: blabels }
};

def infer_fn_ret(st: EmitSt, func: Func) -> Type {
    let f: EmitSt = { ...st, ir: [], txt: [], fuid: 0, loc: 1, env: [], slots: 0, temp: 0, self_label: -1, end_label: -1 };
    let params: [str] = func.params;
    let ptypes: [Type] = func.ptypes;
    let n = len(params);
    for i in 0..n {
        f = env_define(f, params[i], SK.param, 16 + (n - 1 - i) * 8, -1, "", ptypes[i]);
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

def global_entries(st: EmitSt, gdecls: [Node], gbase: long) -> [Sym] {
    let f: EmitSt = { ...st, ir: [], txt: [], fuid: 0, loc: 1, env: [], slots: 0, temp: 0, self_label: -1, end_label: -1 };
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
        f = env_define(f, gn, SK.global, 0, lbl_new(lbl), "", t);
    });
    out
};

def decl_type(d: Decl) -> Type {
    d.typ
};

def decl_value(d: Decl) -> Node {
    d.v
};

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
type DflCode = { name: str, vals: [str] };
type Externs = { ext: [Sym], dfl: [Dfl], pkgs: [str], inits: [str], argv: bool, tys: [str], fx: [str] };

// No externs at all (a std unit compiled on its own).
def externs_none() -> Externs {
    let xs: [Sym] = [];
    let ds: [Dfl] = [];
    let ps: [str] = [];
    let ins: [str] = [];
    { ext: xs, dfl: ds, pkgs: ps, inits: ins, argv: false, tys: [], fx: [] }
};

// A std unit's source, from disk (std_lib_src): only a ycc without the unit
// in its pack, or --std=source, gets here.
def std_unit_src(name: str) -> str {
    let src = std_lib_src(name);
    if (len(src) == 0) {
        puts("error: std module '" + name + "': not in this compiler's std pack, and no src/y/std/" + name + ".y beside it or in the working directory\n");
        exit(1);
    };
    src
};

// Blank the `export { ... };` lines a std module carries for the splicer (which
// drops them before the lexer sees the text, see the splice); a unit compiled
// straight from the same text has no splicer in the way. They are blanked, not
// removed, so every line number below -- and so every `.loc` marker -- stays.
def std_drop_exports(src: str) -> str {
    let out: [str] = [];
    let n = len(src);
    let i = 0;
    let start = 0;
    let dropping = false;
    while (i <= n) {
        if (i == n || src[i] == '\n') {
            let line = src[start:i];
            let t = trim(line);
            if (dropping) {
                out += "";
                if (index_of(line, "}") >= 0) { dropping = false; };
            } else if (t[:7] == "export ") {
                out += "";
                if (index_of(line, "{") >= 0 && index_of(line, "}") < 0) { dropping = true; };
            } else {
                out += line;
            };
            start = i + 1;
        };
        i = i + 1;
    };
    join(out, "\n")
};

// A library std unit's place in the order below: its uids and global cells
// start in a range of their own, past the packages' 5e9 + k*1e9 (ycc.y), so a
// program linking both cannot collide. -1 is not a library unit.
def std_lib_index(name: str) -> long {
    let xs = std_lib_names();
    let i = 0;
    let found = -1;
    while (i < len(xs)) {
        if (xs[i] == name) { found = i; };
        i = i + 1;
    };
    found
};

def std_lib_deps(name: str) -> [str] {
    if (name == "fs") {
        ["sort"]
    } else if (name == "json") {
        ["sort"]
    } else if (name == "img") {
        ["zlib", "fs"]
    } else if (name == "audio") {
        ["math", "fs"]
    } else if (name == "snd") {
        ["fs", "ipc", "math", "audio"]
    } else if (name == "gui") {
        ["fs", "ipc"]
    } else if (name == "net") {
        ["fs"]
    } else if (name == "x509") {
        ["crypto", "fs", "struct"]
    } else if (name == "tls") {
        ["crypto", "x509", "net"]
    } else if (name == "http") {
        ["net", "tls"]
    } else if (name == "yfs") {
        ["kmem"]
    } else if (name == "fd") {
        ["yfs"]
    } else if (name == "kernel") {
        ["kmem", "yfs", "fd"]
    } else {
        []
    }
};

// Every std library unit, in the order std_unit_names appends them. A module
// that imports another must come after it (fs after sort, tls after crypto/
// x509/net): a unit's imports bind units, never splices.
def std_lib_names() -> [str] {
    // Dependency first: a unit is compiled against the ones before it
    // (std_compile's `prev`), so an importer must come after what it imports --
    // fs and json after sort, net after fs, x509 after crypto/fs/struct, tls
    // after crypto/x509/net, http after net/tls.
    //
    // W8's web is APPENDED after gui, never inserted: the index into this list
    // is part of every unit's uid and global base (std_unit_base), so an entry
    // added in the middle would move every pack entry after it. web imports
    // no unit, so its position costs nothing.
    ["math", "sort", "algo", "zlib", "fs", "json", "img", "audio", "ipc", "snd", "struct", "crypto", "x509", "net", "tls",
     "http", "regex", "random", "utf8", "args", "test", "tui", "kmem", "yfs",
     "fd", "kernel", "memstat", "gui", "web"]
};

// Std units that have a NAME.TARGET.y variant (S14), as [unit, target]
// pairs. The pack, and std_units' NAME@TARGET lookup, are driven by this
// list; a unit with no variant keeps its pack entry byte for byte.
def std_variant_names() -> [[str]] {
    [["gui", "web"]]
};

// The entry std_units asks for: NAME@TARGET when `name` has a variant for
// `target`, else NAME.
def std_variant_name(name: str, target: str) -> str {
    let out = name;
    std_variant_names().foreach((el) => {
        let pair: [str] = el;
        if (pair[0] == name && pair[1] == target) { out = name + "@" + target; };
    });
    out
};

// The unit a variant entry stands for: "gui@web" -> "gui".
def std_base_name(name: str) -> str {
    let at = index_of(name, "@");
    if (at < 0) { name } else { name[:at] }
};

def std_lib_src(name: str) -> str {
    let path = std_lib_path(name);
    let out = "";
    if (len(path) > 0) {
        let t = fs.read_file(path);
        if (!(t == none)) {
            let text = std_text(unwrap(t));
            // A std unit's target overlay (gui -> gui.web.y) is merged here:
            // a std unit compiled from disk has no splicer in the way.
            let ovp = tov.tov_path(path, res_target);
            if (ovp != "") {
                let ot = fs.read_file(ovp);
                if (!(ot == none)) { text = tov.tov_merge_text(text, unwrap(ot), path, ovp); };
            };
            out = std_embeds(text, dir_of(path));
        };
    };
    out
};

// The `embed NAME from "file";` lines of a std unit, expanded here because the unit is
// compiled from its text, not through the resolver that expands them for a program: the
// file is read relative to the unit's own directory, and the line stays one line.
def std_embeds(text: str, dir: str) -> str {
    if (index_of(text, "embed ") < 0) { return text; };
    let lines = split(text, "\n");
    let out: [str] = [];
    lines.foreach((l) => {
        let t = trim(l);
        if (is_embed_decl(t)) { out += embed_decl(t, dir); } else { out += l; };
    });
    join(out, "\n")
};

// Where std_lib_src reads library unit `name` from, or "" when no candidate
// exists. Exported: the language server opens the same file to show a unit
// member's signature and doc comment, which the pack does not carry.
def std_lib_path(name: str) -> str {
    let cands: [str] = [];
    cands += "src/y/std/" + name + ".y";
    let d = self_dir();
    if (len(d) > 0) {
        cands += d + "/std/" + name + ".y";
        cands += d + "/src/y/std/" + name + ".y";
        cands += d + "/../src/y/std/" + name + ".y";
    };
    let out = "";
    let i = 0;
    while (len(out) == 0 && i < len(cands)) {
        if (!(fs.read_file(cands[i]) == none)) { out = cands[i]; };
        i = i + 1;
    };
    out
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
    } else if (name == "rt") {
        4000000000
    } else {
        let i = std_lib_index(name);
        if (i < 0) { 0 } else { 1000000000000 + i * 1000000000 }
    }
};

// A library unit: the program sees its exports (see the section note).
def std_unit_bound(name: str) -> bool {
    // the two units a program calls by bare name, and every library unit: those
    // are referenced qualified (math.pi), see unit_externs
    name == "prelude" || name == "exec" || std_lib_index(name) >= 0
};

// Every std unit, in link order (see native_resolve_x).
def std_unit_names() -> [str] {
    let out = ["prelude", "exec", "str", "rt"];
    std_lib_names().foreach((n) => {
        out += n;
    });
    out
};

// The std units `names` (link order, see native_resolve_x): from `pack`
// (std_pack) when it has them, else compiled from their sources on disk.
// exec calls into the prelude (y_stdin_sync), so it sees the prelude's
// exports -- linked, and so compiled, before it.
def std_units(names: [str], pack: str) -> [Unit] {
    let out: [Unit] = [];
    if (len(pack) > 0) {
        // S14: the target's variant (gui@web) comes first; a pack without it
        // still has the base unit, which is what an older compiler carries.
        let want: [str] = [];
        names.foreach((el) => {
            let nm: str = el;
            want += std_variant_name(nm, res_target);
        });
        out = std_unpack(pack, want);
        if (len(out) == 0) { out = std_unpack(pack, names); };
    }
    // the arch blocks come from the same pack when it was read (arch_set)
    if (len(out) > 0) { arch_pack = pack; } else { arch_pack = ""; };
    if (len(out) == 0) {
        names.foreach((el) => {
            let nm: str = el;
            let ext: [Sym] = [];
            let exfx: [str] = [];
            if (nm == "exec") {
                out.foreach((u) => {
                    if (u.name == "prelude") {
                        ext += u.exports;
                        exfx += unit_fx_of(u);
                    }
                });
            }
            // A source-built std unit must match the one in the attached pack:
            // the pack is built with the pass suspended, so compiling these
            // bodies with it active would bake extra literal touches (and a
            // different image) into a pack-less compiler.
            obf.suspend();
            out += std_compile(nm, ext, exfx, out);
            obf.resume();
        });
    }
    out
};

// One std unit, from its source on disk (std_unit_src). It always carries its `.loc`
// markers (link_units strips them unless -g), so it compiles the same
// for every program. A failure here is the compiler's own bug: reported
// as one, and the run ends.
def std_compile(name: str, ext: [Sym], exfx: [str], prev: [Unit]) -> Unit {
    let path = "std/" + name + ".y";
    let raw = std_drop_exports(std_text(std_unit_src(name)));
    if (meta.mg_on && index_of(raw, "#{") >= 0) {
        puts("error: " + path + ": a meta block cannot appear in a std source: std units are compiled from their own text after the program's own pass, so a block there has no generator to run in\n");
        exit(1);
    };
    let nolines: [long] = [];
    let ssrc = raw;
    let imports: [str] = [];
    let pkgs: [str] = [];
    let sstd: [str] = [];
    let ogen: [bool] = [];
    if (index_of(raw, "import ") >= 0) {
        res_in_std = true;
        let nr = native_resolve_x(raw, "std", 0, true, path);
        res_in_std = false;
        ssrc = nr.src;
        imports = nr.imports;
        pkgs = nr.pkgs;
        sstd = nr.std;
        ogen = nr.ogen;
    };
    let ast = parser.parse_program(lexer.tokenize(ssrc));
    let xt = externs_none();
    if (len(sstd) > 0) { xt = unit_externs(prev, sstd, [], pkgs); };
    // The caller's `ext` (exec sees the prelude's exports) ADDS to what the
    // imports bound -- an assignment here would wipe them, which is what made
    // every `sort.` call in fs undefined while the ext list looked right.
    let ei = 0;
    while (ei < len(ext)) {
        xt.ext += ext[ei];
        xt.fx += exfx[ei];
        ei = ei + 1;
    };
    let mods: [str] = [""];
    if (std_lib_index(name) >= 0) { mods = [name]; };
    let r = compile_unit(ast, imports, { files: [path], nuser: 1, file: nolines, line: nolines, mods: mods }, true, 0, name, std_unit_base(name), xt, ogen);
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

def unit_prep(xt: Externs) {
    pkg_ns = xt.pkgs;
    if (len(xt.tys) > 0) {
        let seeds: [Field] = [];
        let si = 0;
        while (si < len(xt.tys)) {
            let item = xt.tys[si];
            let nl = index_of(item, "\n");
            seeds += { name: item[:nl], opt: false, typ: tdecode(item[nl + 1:]) };
            si = si + 1;
        };
        rename.rn_types_seed_set(seeds);
    };
};

// --strict-heap: report each allocation the program repeats with nothing to
// free it (lint.y lint_heap). Warnings only; the
// emitted bytes never depend on it.
let strict_heap: bool = false;

def set_strict_heap(v: bool) -> void { strict_heap = v; };

// Whether loop bodies are made regions where escape.y proves they can be
// (on unless --regions=off).
let auto_regions: bool = true;

def set_auto_regions(v: bool) -> void { auto_regions = v; };

def compile_unit(ast: Block, imports: [str], origin: Origin, debug: bool, wlevel: long, name: str, base: long, xt: Externs, ogen: [bool]) -> UnitRes {
    tyset_reset();
    dbg_lines = debug;
    dbg_file = origin.file;
    dbg_line = origin.line;
    let ext = xt.ext;
    let inits = xt.inits;
    unit_prep(xt);
    let times: [Timing] = [];
    let pt = clock_us();
    let ph = heap_used();
    let ast2: Block = strip_ns(ast, imports);
    let pr = phase_end(times, "strip_ns", pt, ph);
    times = pr.times; pt = pr.t; ph = pr.h;
    // Static name resolution: every binding gets a unique name, so neither
    // the checker nor the emitter deals with scopes or shadowing.
    let ast3: Block = rename.rename_program_x(ast2, xt.dfl, origin.file, origin.mods);
    // What this unit's aliases resolved to (the seeds included), as `name\ntcode`
    // for the pack: what makes the unit's own types nameable by its importers.
    let out_types: [str] = [];
    let ots = rename.rn_types_out_get();
    let oi = 0;
    while (oi < len(ots)) {
        // A unit's own aliases come back bare when it has no module namespace of
        // its own (the four core units, whose defs must stay bare): qualify them
        // here, so rt's `YBig` publishes as `rt.YBig`, which is how a dependent
        // module's source refers to it.
        let tn = ots[oi].name;
        if (index_of(tn, ".") < 0) { tn = name + "." + tn; };
        out_types += tn + "\n" + tcode(ots[oi].typ);
        oi = oi + 1;
    };
    pr = phase_end(times, "rename", pt, ph);
    times = pr.times; pt = pr.t; ph = pr.h;
    let heap = strict_heap && (len(name) == 0 || pkg_base(base));
    let process_region = false;
    foreach (n in ast3.stmts) { if (escape.esc_process_region(n, false)) { process_region = true; }; };
    let lifetimes = len(name) > 0 || process_region || (gc_mode == 2 && !gc_stress && !target_is_kernel());
    if (heap || lifetimes) { types.heap_index_on(); };
    let errors = types.check_program(ast3, ext);
    if (heap || lifetimes) { types.heap_index_off(); };
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
    if (len(errors) == 0) {
        errors = escape_unit(ast3, defs, ext, xt.fx, auto_regions && (len(name) == 0 || (pkg_base(base) && std_unit_base(name) != base)) && !target_is_kernel());
        if (len(errors) == 0 && lifetimes) {
            let xnames: [str] = [];
            let xfx: [str] = [];
            for xi in 0..len(ext) {
                xnames += ext[xi].name;
                xfx += if (xi < len(xt.fx)) { xt.fx[xi] } else { "" };
            };
            if (gc_mode == 2 && !gc_stress && auto_regions && !target_is_kernel()
                && (len(name) == 0 || (pkg_base(base) && std_unit_base(name) != base))) {
                // A whole-call arena must not conceal an unplaced allocating
                // loop inside the callee. Prove those effects before wrapping.
                lifetime.life_analyze(ast3.stmts, xnames, xfx, false, false, len(name) == 0);
                escape.esc_functions(lifetime.life_scratch());
            };
            errors = lifetime.life_analyze(ast3.stmts, xnames, xfx, gc_mode == 2 && !gc_stress && !target_is_kernel()
                && (len(name) == 0 || (pkg_base(base) && std_unit_base(name) != base)),
                len(name) == 0 || (pkg_base(base) && std_unit_base(name) != base), len(name) == 0);
        };
        pr = phase_end(times, "escape", pt, ph);
        times = pr.times; pt = pr.t; ph = pr.h;
    };
    if (len(errors) > 0) {
        { ok: false, errors: errors, warnings: warnings, times: times, unit: unit_empty(name) }
    } else {
        // The warnings (lint.y): the program's unit's and a package's,
        // never a std unit's.
        if (len(name) == 0 || pkg_base(base)) {
            warnings = lint.lint_unit(ast, ast3, origin.file, origin.mods, wlevel, ogen, res_unused, heap);
            pr = phase_end(times, "lint", pt, ph);
            times = pr.times; pt = pr.t; ph = pr.h;
        };
        fold_consts(ast3.stmts);
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
        st = { ...st, uid: base + 1 };
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
                // An `irq N def`'s label is what the generated interrupt stub
                // calls (arch_x64.y's kernel_irq_text), so it is recorded the
                // moment it exists.  `disp` strips rename's `$N`.
                if (target_is_kernel()) {
                    let il = kernel_irq_line(disp(d.name));
                    if (il >= 0) { kernel_irq_stub(il, label); };
                };
                let lid = lbl_new(label);
                hsyms += { name: d.name, label: label, typ: func_type(d.func) };
                hids += lid;
                st = env_define(st, d.name, SK.func, 0, lid, "", func_type(d.func));
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
            // A kernel has no argv and its `_start` name belongs to the
            // 32-bit trampoline in the image header, so the program's top
            // level is a plain function the trampoline calls.
            let mlab = "_start";
            if (target_is_kernel()) {
                want_argv = false;
                mlab = "y_kernel_main";
            };
            let main_body: Block = { k: K.block, stmts: main_stmts, line: 0, col: 0 };
            let start_fn: EmitMain = { params: [], ptypes: [], ret: type_node({ k: K.tvoid }), body: main_body, line: 0, col: 0 };
            st = emit_one_fn(st, lbl_new(mlab), rm.uid, start_fn, true, want_argv, [], "");
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
        let ubodies = st.bodies;
        let ubtext: [[str]] = st.btext;
        let blabels: [str] = st.blabels;
        let brefs: [[str]] = [];
        ubodies.foreach((e) => {
            let ub: [long] = e;
            brefs += [ir_refs(ub)];
        });
        // what an importer's region check reads; nothing imports the program
        let ufx: [str] = [];
        if (len(name) > 0) { ufx = unit_fx(ast3.stmts, st.fns.syms, exports); };
        let unit: Unit = { name: name, files: origin.files, exports: exports,
            init: init, bodies: ubodies, btext: ubtext, blob: [],
            labels: blabels, refs: brefs, rodata: st.rodata, globals: glabels,
            dfl: udfl, tys: out_types, fx: ufx };
        { ok: true, errors: errors, warnings: warnings, times: times, unit: unit }
    }
};

// The escape pass over a checked unit (escape.y): `fx` holds the externs'
// summaries in `ext`'s order (Externs.fx).
def escape_unit(ast3: Block, defs: [FnDef], ext: [Sym], fx: [str], auto: bool) -> [Diag] {
    let xnames: [str] = [];
    let xfx: [str] = [];
    let i = 0;
    while (i < len(ext) && i < len(fx)) {
        if (len(fx[i]) > 0 && ext[i].typ.k == K.tfunc) {
            xnames += ext[i].name;
            xfx += fx[i];
        };
        i++;
    };
    let dnames: [str] = [];
    let dfuncs: [Func] = [];
    i = 0;
    while (i < len(defs)) {
        dnames += defs[i].name;
        dfuncs += defs[i].func;
        i++;
    };
    escape.esc_unit(ast3.stmts, dnames, dfuncs, types.saw_region(), xnames, xfx, auto)
};

// The region summaries of a unit's exports, in their order ("" for one that
// is no def): what the pack stores (Unit.fx).
def unit_fx(stmts: [Node], fns: [Sym], exports: [Sym]) -> [str] {
    let byn = parser.nameix_new(256);
    let i = 0;
    while (i < len(fns)) {
        parser.nameix_put(byn, fns[i].name, i);
        i++;
    };
    // the label of each top-level def, to its summary
    let byl = parser.nameix_new(256);
    let sums: [str] = [];
    i = 0;
    while (i < len(stmts)) {
        let nm = top_def_name(stmts[i]);
        if (len(nm) > 0) {
            let j = parser.nameix_get(byn, nm);
            if (j >= 0) {
                parser.nameix_put(byl, fns[j].label, len(sums));
                sums += escape.esc_export(nm) + lifetime.life_export(nm);
            };
        };
        i++;
    };
    let out: [str] = [];
    i = 0;
    while (i < len(exports)) {
        let k = parser.nameix_get(byl, exports[i].label);
        out += if (k >= 0) { sums[k] } else { escape.fx_encode(escape.fx_decode("")) + lifetime.life_export("") };
        i++;
    };
    out
};

// A unit's summaries in its exports' order, or as many empty ones.
def unit_fx_of(u: Unit) -> [str] {
    if (len(u.fx) == len(u.exports)) { u.fx } else {
        let out: [str] = [];
        let i = 0;
        while (i < len(u.exports)) {
            out += "";
            i++;
        };
        out
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
        // A library unit is compiled with its own namespace (see std_compile),
        // so a def of its own comes back qualified (`fs.write_file`) while the
        // export -- and so the default's key -- is the bare name. Strip our own
        // namespaces; a name of an IMPORTED module stays skipped below.
        let mi = 0;
        while (mi < len(origin.mods)) {
            let om = origin.mods[mi];
            if (len(om) > 0 && nm[:len(om) + 1] == om + ".") { nm = nm[len(om) + 1:]; };
            mi = mi + 1;
        };
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

def set_gc_mode(m: long) -> void { gc_mode = m; };

// --gc=stress: link the collector and run a cycle at every allocating slow
// path (arch_gc_stress_lines). A debugging switch, not a mode to ship.

def set_gc_stress(v: bool) -> void { gc_stress = v; };

// ── the --gc decision ───────────────────────────────────────────────────
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
    // A breadth-first walk up the reverse edges from y_alloc, in the order it
    // reaches them. `seen` is by the name's index, and `out` doubles as the
    // queue (`wi` its head): a name list searched per edge was quadratic, 3.7%
    // of a self-compile.
    let out: [str] = [];
    let a0 = namemap_get(ix, "y_alloc");
    if (a0 >= 0) {
        let seen: [bool] = [];
        i = 0;
        while (i < len(names)) {
            seen += false;
            i++;
        };
        seen[a0] = true;
        out += "y_alloc";
        let wi = 0;
        while (wi < len(out)) {
            let j = namemap_get(ix, out[wi]);
            wi++;
            if (j >= 0) {
                let rs = rev[j];
                let k = 0;
                while (k < len(rs)) {
                    let m = namemap_get(ix, rs[k]);
                    if (!(seen[m])) {
                        seen[m] = true;
                        out += rs[k];
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
    if (gc_stress) { true }
    else if (mode == 1) { true }
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

def link_units(std: [Unit], deps: [Unit], prog: Unit, gcmode: long, seal_key: long) -> [LinkPart] {
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
    let all_user: [bool] = [];
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
                all_user += (j >= len(std));
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
        all_user += true;
        labels += plab[pb2];
        refs += [prefs[pb2]];
        fno += -1;
    });
    // Body-level tree shaking comes first: its output is also the root
    // set for shaking the arch prelude, and the kept prelude's references
    // shake the rodata constants.
    let extra: [str] = [];
    // An `irq N def` handler has no caller in the program: the generated
    // stub (a text part the shaker never sees) is what calls it, so it is a
    // root here or its body is shaken away and the stub names nothing.
    if (target_is_kernel()) {
        res_irq_stubs.foreach((e) => {
            extra += e.label;
        });
        extra += "y_kernel_trap";
        extra += "y_kernel_pf";
        extra += "y_kernel_user_fault";
    };
    let shaken = prune_bodies(labels, refs, extra);
    let keep = shaken.keep;
    let body_refs = shaken.refs;
    // The target's prelude (on Windows with the NT syscall self-test, which
    // the _start prologue calls: it goes through the prelude so the shaker sees
    // what it references).
    let core_lines = arch_core();
    let thr = uses_threads(body_refs);
    let mth = uses_math(body_refs);
    let rgn = uses_regions(body_refs);
    let pb = prelude_with(core_lines, thr, mth, rgn);
    let ps = shake_prelude(pb, body_refs);
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
    // Every cell against every read was 3.5% of a self-compile: past a
    // million comparisons the CELLS are indexed (there are far fewer of them
    // than reads, and an index costs a record a name) and each read marks
    // its cell. Below that the scan is cheaper than any hashing.
    if (len(cells) * len(reads) > 1000000) {
        let cix = namemap_build(cells);
        let read: [bool] = [];
        cells.foreach((cell) => { read += false; });
        reads.foreach((r) => {
            let k = namemap_get(cix, r);
            if (k >= 0) { read[k] = true; };
        });
        cells.foreach((cell) => {
            let k = namemap_get(cix, cell);
            if (k < 0 || !read[k]) { dead_cells += [cell]; };
        });
    } else {
        cells.foreach((cell) => {
            if (!name_in(reads, cell)) { dead_cells += [cell]; };
        });
    };
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
        pb = prelude_with(core_lines, thr, mth, rgn);
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
        if ((!thr && uses_threads(body_refs)) || (!mth && uses_math(body_refs)) || (!rgn && uses_regions(body_refs))) {
            if (uses_threads(body_refs)) { thr = true; };
            if (uses_math(body_refs)) { mth = true; };
            if (uses_regions(body_refs)) { rgn = true; };
            pb = prelude_with(core_lines, thr, mth, rgn);
        };
        ps = shake_prelude(pb, body_refs);
        more = unkept_refs(ps.refs, bmap, keep);
    };
    // --gc: when the collector cannot be needed, its three entry points become
    // stubs, so the registry, metadata arena, marker, sweeper and free lists go
    // unreachable and shake out. The allocator and heap_used() are untouched.
    if (!(gc_decide(gcmode, labels, refs, keep, all, allblob, ps, thr))) {
        core_lines = arch_blocks_sub(core_lines, arch.arch_nogc_subs());
        pb = prelude_with(core_lines, thr, mth, rgn);
        ps = shake_prelude(pb, body_refs);
    };
    // --gc=stress: every slow-path allocation runs a cycle.
    if (gc_stress) {
        core_lines = arch_blocks_sub(core_lines, arch.arch_gc_stress_subs());
        pb = prelude_with(core_lines, thr, mth, rgn);
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
    let rodpieces = interned.pieces;
    if (obf.on() && len(rodpieces) > 1) {
        // Literals are addressed by label, so their order is free; shuffling
        // removes the source-order signature a reader would otherwise see.
        let ro = obf.shuffle_order(len(rodpieces));
        let sh: [str] = [];
        foreach (i in ro) { sh += rodpieces[i]; };
        rodpieces = sh;
    };
    let dup_old = interned.dup_old;
    // loser label -> index into dup_new, so a body's refs can be relabelled
    // in one probe each.
    let dupmap = asm.labmap_new(len(dup_old) * 2 + 64);
    dup_old.foreach((e, di) => {
        dupmap = (asm.labmap_put(dupmap, e, 1, di)).map;
    });
    let parts: [LinkPart] = [];
    let vm_bc = obf.vm_on() && obf.vm_mode() == "bytecode" && !target_is_windows();
    if (vm_bc) { obfvm.vm_begin(obf.program_seed(), obf.diversity_high()); };
    let vm_ros: [str] = [];
    let head = arch.arch_header();
    if (dbg_lines) {
        head = file_dirs(files) + head;
    }
    parts += [part_text(head + arch.arch_text())];
    if (seal_key != 0) {
        if (target_is_windows()) {
            parts += [part_text(seal.pe_stub_text(seal_key, obf.anti_debug()))];
        } else {
            parts += [part_text(seal.stub_text(seal_key, obf.lazy_on(),
                obf.key_file(), obf.anti_debug(), obf.key_fd(),
                obf.path_key()))];
        };
    };
    // the kept prelude blocks, as items
    parts += [part_ir(ps.ir, ps.txt, 0, false)];
    if (target_is_kernel()) {
        // Whether some unit defines the trap handler decides whether the
        // generated stubs call it or fall back to a halt.
        let has_trap = namemap_get(namemap_build(labels), "y_kernel_trap") >= 0;
        let has_pf = namemap_get(namemap_build(labels), "y_kernel_pf") >= 0;
        let has_uf = namemap_get(namemap_build(labels), "y_kernel_user_fault") >= 0;
        parts += [part_text(arch.kernel_irq_text(has_trap, has_pf, has_uf))];
    };
    // The bodies, kept, as parts: their items, with the `.loc` markers moved
    // to the unit's place in the program's file table. Every body is items
    // now -- a unit read from a pack came with them (pack_body).
    let bparts: [LinkPart] = [];
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
            let opt = optim.optimize(kb, optim.goal());
            if (obf.on() && (all_user[ab] || obf.std_on()) && !dbg_lines) {
                let done = false;
                // The bytecode VM is for the program's own helpers; a std
                // body keeps the native static pass so the runtime keeps its
                // own shape and the VM's leaf subset does not change it.
                if (vm_bc && all_user[ab]) {
                    let vf = obfvm.compile(opt, alltxt[ab], labels[ab]);
                    if (vf.ok) {
                        bparts += [part_ir(vf.ir, [], off, false)];
                        vm_ros += [vf.ro];
                        done = true;
                    };
                };
                if (!done) {
                    let ob = obf.transform(opt, alltxt[ab], labels[ab]);
                    bparts += [part_ir(ob.ir, ob.txt, off, false)];
                };
            } else {
                bparts += [part_ir(opt, alltxt[ab], off, dbg_lines)];
            };
        }
    });
    if (obf.layout_shuffle()) {
        let order = obf.shuffle_order(len(bparts));
        let k = 0;
        while (k < len(order)) { parts += [bparts[order[k]]]; k += 1; };
    } else {
        parts += bparts;
    };
    if (obf.on()) {
        let seqs = obf.junk_bodies();
        seqs.foreach((sq) => {
            parts += [part_ir(sq.ir, sq.txt, 0, false)];
        });
        parts += [part_text(obf.junk_bytes())];
    };
    if (vm_bc) {
        let it = obfvm.interp_text();
        if (len(it) > 0) { parts += [part_text((if (target_is_aarch64()) { ".align 4\n" } else { "" }) + it)]; };
    };
    if (seal_key != 0 && !target_is_windows()) {
        // A page-aligned marker between code and its contiguous .rodata: the
        // lazy stub decrypts the data side eagerly (a syscall reading a
        // PROT_NONE page gets EFAULT, never SIGSEGV) and leaves only code lazy.
        parts += [part_text(if (target_is_aarch64()) { ".align 65536\ny_obf_code_end:\n" } else { ".align 4096\ny_obf_code_end:\n" })];
        parts += [part_text(seal.magic_text(seal_key))];
    };
    // The rodata, then the .bss cells: text.
    parts += [part_text(arch.arch_rodata() + (shake_refs(arch.arch_consts(), const_refs)))];
    if (seal_key != 0 && obf.lazy_on()) {
        // The runtime messages above stay eager; literals from here on are
        // decrypted a page at a time on first use.
        parts += [part_text(if (target_is_aarch64()) { ".align 65536\ny_obf_data_start:\n" } else { ".align 4096\ny_obf_data_start:\n" })];
    };
    if (obf.on() && len(gls) > 1) {
        let go = obf.shuffle_order(len(gls));
        let sg: [str] = [];
        foreach (i in go) { sg += gls[i]; };
        gls = sg;
    };
    parts += [part_text(join(rodpieces, ""))];
    if (len(vm_ros) > 0) { parts += [part_text(join(vm_ros, ""))]; };
    // .bss: the allocator's cells when the kept prelude still uses
    // them, then one cell per global.
    let heap_text = shake_refs(arch.arch_heap_cells(), const_refs);
    let lazy = seal_key != 0 && obf.lazy_on();
    let keyfile = seal_key != 0 && len(obf.key_file()) > 0;
    if (len(gls) > 0 || len(heap_text) > 0 || target_is_windows() || target_is_kernel() || lazy || keyfile) {
        let gpieces: [str] = [];
        gpieces += arch.arch_bss();
        if (lazy) { gpieces += seal.bss_text(); }
        else if (keyfile) { gpieces += seal.key_bss_text(); };
        // The kernel's own cells -- the IDT, the stack, the heap arena --
        // come first, then the allocator's and the globals'.
        if (target_is_kernel()) {
            gpieces += arch.arch_kernel_bss();
        };
        if (target_is_windows()) {
            let wl = arch.w_iat_bss_lines();
            for wj in 0..len(wl) { gpieces += wl[wj]; };
        };
        gpieces += heap_text;
        gls.foreach((e) => {
            gpieces += arch.arch_global_cell(e);
        });
        parts += [part_text(join(gpieces, ""))];
    };
    if (seal_key != 0 && !target_is_windows()) {
        // The label is the end of the sealed range. Switching back to .rodata
        // emits no bytes; .align 8 pads the last literal block to a word.
        parts += [part_text(".section .rodata\n.align 8\ny_obf_image_end:\n")];
    };
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

def pack_version() -> str {
    "ycc-std-pack 12\n"
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
def pack_word(out: [str], v: long) -> [str] {
    if (v >= 0 && v < 126) {
        out += chr(v);
    } else if (v < 0 && v > -65536) {
        let u = 65536 + v;
        out += chr(127);
        out += chr(u & 255);
        out += chr((u >> 8) & 255);
    } else if (v >= 0 && v <= 65535) {
        // v >= 0 matters: without it every value below -65535 landed here (it is
        // <= 65535 too), was written as two bytes, and read back as a small
        // POSITIVE number -- a silent corruption of every large negative
        // immediate. A packed crypto unit is what finally exercised it.
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
    pack_ir(u.bodies[b])
};

// Wire layouts come from the operand schema; unused IR fields remain zero.
def pack_ir(ir: [long]) -> str {
    let out: [str] = [];
    let at = 0;
    while (at < len(ir)) {
        let f = ir[at];
        out += chr(f & 255);
        let wire = insn.ir_layout(f);
        for w in 0..len(wire) {
            let v = ir[at + 1 + w];
            out = wire[w] == 'l' ? pack_lbl(out, v) : pack_word(out, v);
        };
        at += insn.IR_W;
    };
    join(out, "")
};

type IrCursor = { data: [byte], at: long };

def ir_read(cur: IrCursor, label: bool) -> long {
    let at = cur.at;
    cur.at += label ? lbl_w(cur.data, at) : word_w(cur.data, at);
    label ? unpack_lbl(cur.data, at) : unpack_word(cur.data, at)
};

// Decode kept bodies only; the cursor owns the byte position for both field kinds.
def unpack_body(blob: str) -> [long] {
    let cur: IrCursor = { data: bytes(blob), at: 0 };
    let ir: [long] = [];
    while (cur.at < len(cur.data)) {
        let f = cur.data[cur.at];
        cur.at++;
        ir += f;
        let wire = insn.ir_layout(f);
        for w in 0..insn.IR_W - 1 {
            ir += w < len(wire) ? ir_read(cur, wire[w] == 'l') : 0;
        };
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

def blob_refs(blob: str) -> [str] {
    let b = bytes(blob);
    let out: [str] = [];
    let at = 0;
    while (at < len(b)) {
        let f = b[at];
        at++;
        let wire = insn.ir_layout(f);
        for w in 0..len(wire) {
            if (wire[w] == 'l') {
                at = blob_ref(blob, b, at, out, f != insn.IR_LABEL);
            } else {
                at += word_w(b, at);
            };
        };
    };
    out
};

// The label field at `at` of a packed body (b is blob's bytes): its name
// appended to out when it has one and `keep`, sliced once out of the blob; the
// position after the field.
def blob_ref(blob: str, b: [byte], at: long, out: [str], keep: bool) -> long {
    if (b[at] == 0) { at + 1 } else {
        let s = at + 1 + word_w(b, at + 1);
        let e = s + unpack_word(b, at + 1);
        if (keep && e > s) { out += blob[s:e]; };
        e
    }
};

// A type as text (for a pack or an object): a letter per kind, then its
// parts -- names as netstrings, lists as a count and their items. Unlike
// types.tstr it spells every type a unit may export (none, unknown and
// the like too) and reads back exactly (tdecode).
def tcode(t: Type) -> str {
    tcode_refs = [];
    let out: [str] = [];
    out = tcode_go(out, t);
    join(out, "")
};

def tcode_go(out: [str], t: Type) -> [str] {
    let k: long = t.k;
    if (tcode_simple(out, t)) { out }
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
            let f = fs[i];
            // an optional field is `name?` (tdecode_go)
            let fname: str = f.name;
            if (f.opt) { fname += "?"; };
            out = pack_put(out, fname);
            out = tcode_go(out, f.typ);
        };
        out
    }
    else if (k == K.tpack) {
        // K, the backing bytes, the field count, then each field: its name and
        // its type (a bitmap's field: its width in bits)
        let pk: TPack = t;
        out += "K";
        out = pack_put(out, tostring(pk.bk));
        let pfs: [Field] = pk.fields;
        out = pack_put(out, tostring(len(pfs)));
        for i in 0..len(pfs) {
            let pf = pfs[i];
            let pfname: str = pf.name;
            out = pack_put(out, pfname);
            if (pk.bk > 0) {
                let pw: TInt = pf.typ;
                out = pack_put(out, tostring(pw.w));
            } else {
                out = tcode_go(out, pf.typ);
            };
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

def tdecode_special(cur: Cursor, c: str) -> Type {
    if (c == "Q") {
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
    else if (c == "K") {
        let pbk = pack_num(cur);
        let pfields: [Field] = [];
        for i in 0..pack_num(cur) {
            let pfname = pack_get(cur);
            if (pbk > 0) {
                let bw: TInt = { k: K.tint, w: pack_num(cur), sg: false, be: false };
                let bt: Type = bw;
                pfields += { name: pfname, opt: false, typ: bt };
            } else {
                pfields += { name: pfname, opt: false, typ: tdecode_go(cur) };
            };
        };
        let pk: TPack = { k: K.tpack, fields: pfields, bk: pbk };
        let pr: Type = pk;
        pr
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

def pack_exports(out: [str], xs: [Sym]) -> [str] {
    out = pack_put(out, tostring(len(xs)));
    foreach (x in xs) {
        out = pack_put(out, x.name);
        out = pack_put(out, x.label);
        out = pack_put(out, tcode(x.typ));
    };
    out
};

def pack_get_exports(cur: Cursor, bound: bool) -> [Sym] {
    let xs: [Sym] = [];
    for i in 0..pack_num(cur) {
        let name = pack_get(cur);
        let label = pack_get(cur);
        let tc = pack_get(cur);
        xs += { name: name, label: label, typ: bound ? tdecode(tc) : normtype({ k: K.tnone }) };
    };
    xs
};

def pack_defaults(out: [str], ds: [DflCode]) -> [str] {
    out = pack_put(out, tostring(len(ds)));
    foreach (d in ds) { out = pack_put(out, d.name); out = pack_strs(out, d.vals); };
    out
};

def pack_get_defaults(cur: Cursor) -> [DflCode] {
    let ds: [DflCode] = [];
    for i in 0..pack_num(cur) { ds += { name: pack_get(cur), vals: pack_get_strs(cur) }; };
    ds
};

// ── the pack's LZ codec ─────────────────────────────────────────────────
def pack_plain(raw: str) -> str {
    if (len(raw) == 0 || raw[0] >= 48) { raw } else if (raw[0] == 2) { lz_decode(raw) } else { "" }
};

// Method 2: lz, the decoded length in the four bytes after this one.
def lz_method() -> str {
    chr(2)
};

// n as four bytes, least significant first.
def le32_str(n: long) -> str {
    chr(n & 255) + chr((n >> 8) & 255) + chr((n >> 16) & 255) + chr((n >> 24) & 255)
};

// 12 bits of a Knuth multiplier over four bytes: 4096 slots, first match wins,
// the table always holds the most recent position.
def lz_hash(b: [byte], at: long) -> long {
    let v = b[at] + b[at + 1] * 256 + b[at + 2] * 65536 + b[at + 3] * 16777216;
    ((v * 2654435761) >> 12) & 4095
};

// The 15+ extension of a length: 255s while it lasts, then the remainder.
def lz_more(out: [str], v: long) -> [str] {
    let left = v;
    while (left >= 255) {
        out += chr(255);
        left = left - 255;
    };
    out += chr(left);
    out
};

def lz_encode(s: str) -> str {
    let b = bytes(s);
    let n = len(b);
    let out: [str] = [];
    let tab: [long] = [];
    let i = 0;
    while (i < 4096) {
        tab += -1;
        i = i + 1;
    };
    let at = 0;
    let lit = 0;
    while (at < n) {
        let hit = false;
        let mlen = 0;
        let moff = 0;
        if (at + 4 <= n) {
            let h = lz_hash(b, at);
            let cand = tab[h];
            tab[h] = at;
            if (cand >= 0 && at - cand <= 65535) {
                let k = 0;
                while (at + k < n && b[cand + k] == b[at + k]) {
                    k = k + 1;
                };
                if (k >= 4) {
                    hit = true;
                    mlen = k;
                    moff = at - cand;
                };
            };
        };
        if (hit) {
            let ll = at - lit;
            let lh = ll;
            if (lh > 15) { lh = 15; };
            let mh = mlen - 4;
            if (mh > 15) { mh = 15; };
            out += chr(lh * 16 + mh);
            if (ll >= 15) { out = lz_more(out, ll - 15); };
            let q = lit;
            while (q < at) {
                out += chr(b[q]);
                q = q + 1;
            };
            out += chr(moff & 255);
            out += chr((moff >> 8) & 255);
            if (mh == 15) { out = lz_more(out, mlen - 4 - 15); };
            at = at + mlen;
            lit = at;
        } else {
            at = at + 1;
        };
    };
    // The last run is literals only, which is how the reader knows to stop.
    let ll = n - lit;
    let lh = ll;
    if (lh > 15) { lh = 15; };
    out += chr(lh * 16);
    if (ll >= 15) { out = lz_more(out, ll - 15); };
    let q = lit;
    while (q < n) {
        out += chr(b[q]);
        q = q + 1;
    };
    join(out, "")
};

def lz_decode(s: str) -> str {
    let b = bytes(s);
    let n = len(b);
    if (n < 5) { return ""; };
    let tot = b[1] + b[2] * 256 + b[3] * 65536 + b[4] * 16777216;
    if (tot > 16777216) { return ""; };
    let out = zero_bytes(tot);
    let sp = b.ptr;
    let dp = out.ptr;
    let at = 5;
    let w = 0;
    let ok = true;
    while (ok && at < n) {
        let t = b[at];
        at = at + 1;
        let ll = t >> 4;
        let mh = t & 15;
        if (ll == 15) {
            let more = true;
            while (more && ok) {
                if (at >= n) {
                    ok = false;
                } else {
                    let x = b[at];
                    at = at + 1;
                    ll = ll + x;
                    if (x != 255) { more = false; };
                };
            };
        };
        if (ok && (at + ll > n || w + ll > tot)) { ok = false; };
        if (ok) {
            y_copy_fwd(dp + w, sp + at, ll);
            at = at + ll;
            w = w + ll;
        };
        // A match follows unless this was the final literal run.
        if (ok && at < n) {
            if (at + 2 > n) {
                ok = false;
            } else {
                let moff = b[at] + b[at + 1] * 256;
                at = at + 2;
                let mlen = mh + 4;
                if (mh == 15) {
                    let more = true;
                    while (more && ok) {
                        if (at >= n) {
                            ok = false;
                        } else {
                            let x = b[at];
                            at = at + 1;
                            mlen = mlen + x;
                            if (x != 255) { more = false; };
                        };
                    };
                };
                if (ok && (moff == 0 || moff > w || w + mlen > tot)) { ok = false; };
                if (ok) {
                    y_copy_fwd(dp + w, dp + (w - moff), mlen);
                    w = w + mlen;
                };
            };
        };
    };
    if (ok && w == tot) { from_bytes(out) } else { "" }
};

// n zero bytes: one allocation and one word loop (prelude.s). Doubling a
// block by slices copied every byte about three times.
ndef y_bytes_zero(n: long) -> [byte] = "y_bytes_zero";

def zero_bytes(n: long) -> [byte] {
    y_bytes_zero(n)
};

// n bytes front to back (prelude.s): a source that starts less than n bytes
// before the destination repeats what was just written, which is what an lz
// match with an offset shorter than its length means.
ndef y_copy_fwd(dst: *byte, src: *byte, n: long) -> long = "y_copy_fwd";

// The payload as it is stored: compressed when that is smaller, method byte
// first. A plain pack starts with the version line's `y`, so the two cannot be
// confused and an older reader sees a pack it does not know (and falls back).
def pack_store(s: str) -> str {
    let z = lz_encode(s);
    if (len(z) + 5 < len(s)) { lz_method() + le32_str(len(s)) + z } else { s }
};

def pack_plain_frame(raw: str) -> str {
    let ver = pack_version();
    if (len(raw) <= len(ver) || raw[:len(ver)] != ver) { return ""; };
    let cur: Cursor = { s: raw, p: len(ver) };
    let n = pack_num(cur);
    let out: [str] = [ver];
    out = pack_put(out, tostring(n));
    let i = 0;
    let bad = false;
    while (!bad && i < n) {
        let nm = pack_get(cur);
        let body = pack_get(cur);
        let plain = pack_plain(body);
        if (len(body) > 0 && len(plain) == 0) { bad = true; } else {
            out = pack_put(out, nm);
            out = pack_put(out, plain);
        };
        i = i + 1;
    };
    if (bad) { "" } else { join(out, "") }
};

// ── the pack's deflate encoders ─────────────────────────────────────────

// The bit writer (zlib.y Out/put/put_code).
type DzOut = { b: [byte], acc: long, n: long };

// `bits` low bits of `v`, least significant first.
def dz_put(o: DzOut, v: long, bits: long) -> long {
    if (bits > 0) {
        o.acc = o.acc | (v << o.n);
        o.n = o.n + bits;
    };
    while (o.n >= 8) {
        o.b += o.acc & 255;
        o.acc = o.acc >>> 8;
        o.n = o.n - 8;
    };
    0
};

// A Huffman code travels most significant bit first.
def dz_put_code(o: DzOut, code: long, bits: long) -> long {
    let r = 0;
    let i = 0;
    while (i < bits) {
        r = (r << 1) | ((code >> i) & 1);
        i = i + 1;
    };
    dz_put(o, r, bits)
};

// The fixed literal/length code (RFC 1951 3.2.6).
def dz_put_lit(o: DzOut, sym: long) -> long {
    if (sym < 144) { dz_put_code(o, 48 + sym, 8) }
    else if (sym < 256) { dz_put_code(o, 400 + sym - 144, 9) }
    else if (sym < 280) { dz_put_code(o, sym - 256, 7) }
    else { dz_put_code(o, 192 + sym - 280, 8) }
};

let DZ_LBASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
let DZ_LEXT = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
let DZ_DBASE = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577];
let DZ_DEXT = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];

def dz_len_sym(len: long) -> long {
    let s = 28;
    while (DZ_LBASE[s] > len) { s = s - 1; };
    s
};

def dz_dist_sym(d: long) -> long {
    let s = 29;
    while (DZ_DBASE[s] > d) { s = s - 1; };
    s
};

// The data as deflate's "no compression" blocks: 5 bytes each 65535, five
// for an empty stream.
def dz_stored(data: [byte]) -> [byte] {
    let out: [byte] = [];
    let n = data.length;
    let p = 0;
    if (n == 0) {
        out += 1;
        out += 0;
        out += 0;
        out += 255;
        out += 255;
        return out;
    };
    while (p < n) {
        let m = if (n - p > 65535) { 65535 } else { n - p };
        out += if (p + m >= n) { 1 } else { 0 };
        out += m & 255;
        out += m >> 8;
        out += (m ^ 65535) & 255;
        out += (m ^ 65535) >> 8;
        let k = 0;
        while (k < m) {
            out += data[p + k];
            k = k + 1;
        };
        p = p + m;
    };
    out
};

// The LZ77 parse as two parallel arrays: `len[i]` is 0 for a literal (its
// value in `other[i]`) or the match length, `other[i]` the match distance.
type DzTokens = { len: [long], other: [long] };

// One position's best match: `len` 0 means none.
type DzMatch = { len: long, other: long };

// A match at least this long ends the chain search: chasing further
// candidates to lengthen an already good match costs time and buys almost
// nothing. It is zlib's `nice_match`; 258 (the maximum length) means never
// stop early.
let DZ_NICE = 64;

// A match at least this long makes the lazy lookahead's chain search short:
// the current match is already good, so only a much longer one at the next
// position would change the choice. zlib cuts the chain the same way.
let DZ_GOOD = 32;

// The lazy lookahead searches at most this fraction of the main chain: it only
// has to find a strictly longer match one byte on, and that search is the
// single biggest cost of the parse (measured: uncapped it is 120 ms of a
// 256 ms pack of ycc's 3 MB payload, for 36 KB of output).
let DZ_LAZY_DIV = 4;

def dz_find(data: [byte], head: [long], prev: [long], p: long, effort: long, floor: long) -> DzMatch {
    let n = data.length;
    let best = floor;
    let bestd = 0;
    if (p + 2 < n) {
        let h = ((data[p] << 8) ^ (data[p + 1] << 4) ^ data[p + 2]) & 65535;
        let cand = head[h];
        let tries = 0;
        while (cand >= 0 && p - cand <= 32768 && tries < effort && best < DZ_NICE) {
            if (p + best >= n) {
                // no match from here can beat `best`: the chain is over
                cand = -1;
            } else {
                if (data[cand + best] == data[p + best]) {
                    let l = 0;
                    while (l < 258 && p + l < n && data[cand + l] == data[p + l]) { l = l + 1; };
                    if (l > best) {
                        best = l;
                        bestd = p - cand;
                    };
                };
                cand = prev[cand];
                tries = tries + 1;
            };
        };
    };
    { len: best, other: bestd }
};

// `p` joins its hash chain (the most recent position first).
def dz_insert(data: [byte], head: [long], prev: [long], p: long) -> long {
    let n = data.length;
    if (p + 2 < n) {
        let h = ((data[p] << 8) ^ (data[p + 1] << 4) ^ data[p + 2]) & 65535;
        prev[p] = head[h];
        head[h] = p;
    };
    0
};

def dz_tokens(data: [byte], effort: long) -> DzTokens {
    let n = data.length;
    let len: [long] = [];
    let other: [long] = [];
    let head: [long] = [];
    let i = 0;
    while (i < 65536) {
        head += -1;
        i = i + 1;
    };
    let prev: [long] = [];
    i = 0;
    while (i < n) {
        prev += -1;
        i = i + 1;
    };
    let p = 0;
    let have = false;   // `best` was found for this `p` by the lookahead
    let best = 0;
    let bestd = 0;
    while (p < n) {
        if (!have) {
            let m = dz_find(data, head, prev, p, effort, 0);
            best = m.len;
            bestd = m.other;
        };
        if (best >= 3 && best < DZ_NICE && p + 1 < n) {
            dz_insert(data, head, prev, p);
            let le = effort / DZ_LAZY_DIV;
            if (best >= DZ_GOOD && le > 4) { le = le / 2; };
            if (le < 4) { le = 4; };
            let m1 = dz_find(data, head, prev, p + 1, le, best);
            if (m1.len > best) {
                len += 0;
                other += data[p];
                p = p + 1;
                best = m1.len;
                bestd = m1.other;
                have = true;
                continue;
            };
            let q = p + 1;
            while (q < p + best) {
                dz_insert(data, head, prev, q);
                q = q + 1;
            };
            len += best;
            other += bestd;
            p = p + best;
            have = false;
            best = 0;
        } else if (best >= 3) {
            let q = p;
            while (q < p + best) {
                dz_insert(data, head, prev, q);
                q = q + 1;
            };
            len += best;
            other += bestd;
            p = p + best;
            have = false;
            best = 0;
        } else {
            dz_insert(data, head, prev, p);
            len += 0;
            other += data[p];
            p = p + 1;
            have = false;
            best = 0;
        };
    };
    { len: len, other: other }
};

/** `data` as a raw deflate stream: one fixed-Huffman block over LZ77 matches
found along hash chains (`effort` candidates per position), or stored blocks
when those are not smaller. */
def deflate_pack(data: str, effort: long) -> str {
    let d = bytes(data);
    let n = d.length;
    let tk = dz_tokens(d, effort);
    let o: DzOut = { b: [], acc: 0, n: 0 };
    dz_put(o, 1, 1);
    dz_put(o, 1, 2);
    let i = 0;
    while (i < tk.len.length) {
        if (tk.len[i] == 0) {
            dz_put_lit(o, tk.other[i]);
        } else {
            let ls = dz_len_sym(tk.len[i]);
            dz_put_lit(o, 257 + ls);
            dz_put(o, tk.len[i] - DZ_LBASE[ls], DZ_LEXT[ls]);
            let ds = dz_dist_sym(tk.other[i]);
            dz_put_code(o, ds, 5);
            dz_put(o, tk.other[i] - DZ_DBASE[ds], DZ_DEXT[ds]);
        };
        i = i + 1;
    };
    dz_put_lit(o, 256);
    if (o.n > 0) { dz_put(o, 0, 8 - o.n); };
    if (o.b.length >= n + 5 + 5 * (n / 65535)) { return from_bytes(dz_stored(d)); };
    from_bytes(o.b)
};

def dz_heap_less(weight: [long], a: long, b: long) -> bool {
    weight[a] < weight[b] || (weight[a] == weight[b] && a < b)
};

def dz_heap_push(h: [long], hs: long, weight: [long], v: long) -> long {
    let i = hs;
    h[i] = v;
    while (i > 0) {
        let par = (i - 1) / 2;
        if (!dz_heap_less(weight, h[i], h[par])) { break; };
        let t = h[par];
        h[par] = h[i];
        h[i] = t;
        i = par;
    };
    hs + 1
};

// The root goes into `top[0]`; the new size is the answer.
def dz_heap_pop(h: [long], hs: long, weight: [long], top: [long]) -> long {
    top[0] = h[0];
    let size = hs - 1;
    h[0] = h[size];
    let i = 0;
    while (true) {
        let l = 2 * i + 1;
        let r = l + 1;
        let m = i;
        if (l < size && dz_heap_less(weight, h[l], h[m])) { m = l; };
        if (r < size && dz_heap_less(weight, h[r], h[m])) { m = r; };
        if (m == i) { break; };
        let t = h[m];
        h[m] = h[i];
        h[i] = t;
        i = m;
    };
    size
};

// One unrestricted Huffman build over `n` symbols whose weights are `w`
// (0 = absent). Two or more present symbols give a complete tree; one present
// symbol gets length 1, which inflate accepts as its one-code case.
def dz_huff_once(w: [long], n: long) -> [long] {
    let weight: [long] = [];
    let parent: [long] = [];
    let live = 0;
    let i = 0;
    while (i < n) {
        weight += w[i];
        parent += -1;
        if (w[i] > 0) { live = live + 1; };
        i = i + 1;
    };
    let lens: [long] = [];
    i = 0;
    while (i < n) {
        lens += 0;
        i = i + 1;
    };
    if (live == 0) { return lens; };
    if (live == 1) {
        i = 0;
        while (i < n) {
            if (w[i] > 0) { lens[i] = 1; };
            i = i + 1;
        };
        return lens;
    };
    let h: [long] = [];
    i = 0;
    while (i < live) {
        h += 0;
        i = i + 1;
    };
    let hs = 0;
    i = 0;
    while (i < n) {
        if (w[i] > 0) { hs = dz_heap_push(h, hs, weight, i); };
        i = i + 1;
    };
    let top: [long] = [0];
    let total = n;
    while (hs > 1) {
        let a = h[0];
        hs = dz_heap_pop(h, hs, weight, top);
        let b = h[0];
        hs = dz_heap_pop(h, hs, weight, top);
        weight += weight[a] + weight[b];
        parent += -1;
        parent[a] = total;
        parent[b] = total;
        hs = dz_heap_push(h, hs, weight, total);
        total = total + 1;
    };
    i = 0;
    while (i < n) {
        if (w[i] > 0) {
            let dep = 0;
            let q = i;
            while (parent[q] >= 0) {
                q = parent[q];
                dep = dep + 1;
            };
            lens[i] = dep;
        };
        i = i + 1;
    };
    lens
};

// Lengths capped at `maxbits`: halve every weight and rebuild, which keeps
// every present symbol present and converges because all-equal weights give a
// balanced tree under 15 for these alphabets.
def dz_huff_lengths(w: [long], n: long, maxbits: long) -> [long] {
    let t: [long] = [];
    let i = 0;
    while (i < n) {
        t += w[i];
        i = i + 1;
    };
    let lens: [long] = [];
    let go = true;
    while (go) {
        lens = dz_huff_once(t, n);
        let mx = 0;
        i = 0;
        while (i < n) {
            if (lens[i] > mx) { mx = lens[i]; };
            i = i + 1;
        };
        if (mx <= maxbits) { go = false; } else {
            i = 0;
            while (i < n) {
                t[i] = (t[i] + 1) / 2;
                i = i + 1;
            };
        };
    };
    lens
};

// The canonical code of every symbol with a length: the decoder builds the
// same table (zlib.y build), so the codes agree by construction.
def dz_huff_codes(lens: [long], n: long) -> [long] {
    let bl: [long] = [];
    let i = 0;
    while (i <= 15) {
        bl += 0;
        i = i + 1;
    };
    i = 0;
    while (i < n) {
        if (lens[i] > 0) { bl[lens[i]] = bl[lens[i]] + 1; };
        i = i + 1;
    };
    let next: [long] = [];
    i = 0;
    while (i <= 15) {
        next += 0;
        i = i + 1;
    };
    let code = 0;
    i = 1;
    while (i <= 15) {
        code = (code + bl[i - 1]) << 1;
        next[i] = code;
        i = i + 1;
    };
    let out: [long] = [];
    i = 0;
    while (i < n) {
        if (lens[i] > 0) {
            out += next[lens[i]];
            next[lens[i]] = next[lens[i]] + 1;
        } else {
            out += 0;
        };
        i = i + 1;
    };
    out
};

// 286 literal/length frequencies (256 is end-of-block) and 30 distance ones,
// over the tokens `[lo, hi)` -- one deflate block's worth.
def dz_freqs(tk: DzTokens, lo: long, hi: long) -> { lit: [long], dist: [long] } {
    let lit: [long] = [];
    let i = 0;
    while (i < 286) {
        lit += 0;
        i = i + 1;
    };
    let dist: [long] = [];
    i = 0;
    while (i < 30) {
        dist += 0;
        i = i + 1;
    };
    i = lo;
    while (i < hi) {
        if (tk.len[i] == 0) {
            lit[tk.other[i]] = lit[tk.other[i]] + 1;
        } else {
            let ls = dz_len_sym(tk.len[i]);
            lit[257 + ls] = lit[257 + ls] + 1;
            let ds = dz_dist_sym(tk.other[i]);
            dist[ds] = dist[ds] + 1;
        };
        i = i + 1;
    };
    lit[256] = lit[256] + 1;
    { lit: lit, dist: dist }
};

// The code lengths of one tree as the 19-symbol code-length alphabet: 16
// repeats the previous length 3..6 times (2 bits), 17 sends 3..10 zeros
// (3 bits), 18 sends 11..138 zeros (7 bits).
def dz_cl_encode(lens: [long]) -> { csym: [long], extra: [long], bits: [long] } {
    let sym: [long] = [];
    let extra: [long] = [];
    let bits: [long] = [];
    let i = 0;
    while (i < lens.length) {
        let l = lens[i];
        let run = 1;
        while (i + run < lens.length && lens[i + run] == l) { run = run + 1; };
        if (l == 0) {
            let left = run;
            while (left >= 11) {
                let take = if (left > 138) { 138 } else { left };
                sym += 18;
                extra += take - 11;
                bits += 7;
                left = left - take;
            };
            while (left >= 3) {
                let take = if (left > 10) { 10 } else { left };
                sym += 17;
                extra += take - 3;
                bits += 3;
                left = left - take;
            };
            while (left > 0) {
                sym += 0;
                extra += 0;
                bits += 0;
                left = left - 1;
            };
        } else {
            sym += l;
            extra += 0;
            bits += 0;
            let left = run - 1;
            while (left >= 3) {
                let take = if (left > 6) { 6 } else { left };
                sym += 16;
                extra += take - 3;
                bits += 2;
                left = left - take;
            };
            while (left > 0) {
                sym += l;
                extra += 0;
                bits += 0;
                left = left - 1;
            };
        };
        i = i + run;
    };
    { csym: sym, extra: extra, bits: bits }
};

// The order the code-length code lengths travel in (RFC 1951).
let DZ_CL_ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

// How many input bytes one dynamic block covers before the next block builds
// its own trees. A whole 3 MB binary in ONE block pays for one global symbol
// distribution and loses wherever the data changes character (code, rodata,
// the pack); 64 KiB blocks win a few per cent, at ~60 bytes of header each.
let DZ_BLOCK = 65536;

// One dynamic-Huffman block: its own trees over tokens `[lo, hi)`, the header
// that carries them, then the symbols. `last` is BFINAL.
def dz_block(o: DzOut, tk: DzTokens, lo: long, hi: long, last: bool) -> long {
    let fq = dz_freqs(tk, lo, hi);
    let ll = dz_huff_lengths(fq.lit, 286, 15);
    let dl = dz_huff_lengths(fq.dist, 30, 15);
    // HLIT/HDIST: the last symbol with a code, and at least 257 + 1 entries.
    // A block with no matches at all still needs one distance code, and the
    // decoder accepts a single one-bit code (its incomplete-tree case).
    let nlen = 286;
    while (nlen > 257 && ll[nlen - 1] == 0) { nlen = nlen - 1; };
    let ndist = 30;
    while (ndist > 1 && dl[ndist - 1] == 0) { ndist = ndist - 1; };
    let dused = false;
    let du = 0;
    while (du < 30) {
        if (fq.dist[du] > 0) { dused = true; };
        du = du + 1;
    };
    if (!dused) { dl[0] = 1; };
    let all: [long] = [];
    let i = 0;
    while (i < nlen) {
        all += ll[i];
        i = i + 1;
    };
    i = 0;
    while (i < ndist) {
        all += dl[i];
        i = i + 1;
    };
    let cl = dz_cl_encode(all);
    let clfreq: [long] = [];
    i = 0;
    while (i < 19) {
        clfreq += 0;
        i = i + 1;
    };
    i = 0;
    while (i < cl.csym.length) {
        clfreq[cl.csym[i]] = clfreq[cl.csym[i]] + 1;
        i = i + 1;
    };
    // the code-length tree must be complete (inflate refuses an incomplete one
    // here), so a single distinct symbol gets a second, unused one
    let cllive = 0;
    i = 0;
    while (i < 19) {
        if (clfreq[i] > 0) { cllive = cllive + 1; };
        i = i + 1;
    };
    if (cllive < 2) {
        i = 0;
        while (i < 19 && clfreq[i] > 0) { i = i + 1; };
        clfreq[i] = 1;
    };
    let cll = dz_huff_lengths(clfreq, 19, 7);
    let clc = dz_huff_codes(cll, 19);
    let lc = dz_huff_codes(ll, 286);
    let dc = dz_huff_codes(dl, 30);
    dz_put(o, if (last) { 1 } else { 0 }, 1);
    dz_put(o, 2, 2);
    dz_put(o, nlen - 257, 5);
    dz_put(o, ndist - 1, 5);
    let hclen = 19;
    while (hclen > 4 && cll[DZ_CL_ORDER[hclen - 1]] == 0) { hclen = hclen - 1; };
    dz_put(o, hclen - 4, 4);
    i = 0;
    while (i < hclen) {
        dz_put(o, cll[DZ_CL_ORDER[i]], 3);
        i = i + 1;
    };
    i = 0;
    while (i < cl.csym.length) {
        dz_put_code(o, clc[cl.csym[i]], cll[cl.csym[i]]);
        if (cl.bits[i] > 0) { dz_put(o, cl.extra[i], cl.bits[i]); };
        i = i + 1;
    };
    i = lo;
    while (i < hi) {
        if (tk.len[i] == 0) {
            let s = tk.other[i];
            dz_put_code(o, lc[s], ll[s]);
        } else {
            let l = tk.len[i];
            let ls = dz_len_sym(l);
            dz_put_code(o, lc[257 + ls], ll[257 + ls]);
            if (DZ_LEXT[ls] > 0) { dz_put(o, l - DZ_LBASE[ls], DZ_LEXT[ls]); };
            let dd = tk.other[i];
            let ds = dz_dist_sym(dd);
            dz_put_code(o, dc[ds], dl[ds]);
            if (DZ_DEXT[ds] > 0) { dz_put(o, dd - DZ_DBASE[ds], DZ_DEXT[ds]); };
        };
        i = i + 1;
    };
    dz_put_code(o, lc[256], ll[256]);
    0
};

/** `data` as a raw deflate stream of dynamic-Huffman blocks (DZ_BLOCK input
bytes each) over the LZ77 parse of deflate_pack, or stored blocks when that
is not smaller. */
def deflate_dynamic(data: str, effort: long) -> str {
    let d = bytes(data);
    let n = d.length;
    let tk = dz_tokens(d, effort);
    let nt = tk.len.length;
    // the token index each block starts at, ending with nt; an empty stream is
    // one empty block, so the fallback below still sees a valid stream
    let bs: [long] = [0];
    let i = 0;
    let span = 0;
    while (i < nt) {
        span += if (tk.len[i] == 0) { 1 } else { tk.len[i] };
        i = i + 1;
        if (span >= DZ_BLOCK) {
            bs += i;
            span = 0;
        };
    };
    if (bs[bs.length - 1] != nt) { bs += nt; };
    let o: DzOut = { b: [], acc: 0, n: 0 };
    let k = 0;
    while (k + 1 < bs.length) {
        dz_block(o, tk, bs[k], bs[k + 1], bs[k + 1] == nt);
        k = k + 1;
    };
    if (o.n > 0) { dz_put(o, 0, 8 - o.n); };
    // stored blocks are the data itself plus 5 bytes each 65535, five for an
    // empty stream
    let sl = 5;
    if (n > 0) { sl = n + 5 * ((n + 65534) / 65535); };
    if (o.b.length >= sl) { return from_bytes(dz_stored(d)); };
    from_bytes(o.b)
};

// The pack's NAME@T entries (S14): NAME.y together with NAME.T.y, compiled
// for T after every base unit. Stored under NAME@T; std_unpack links it as
// NAME. A compiler without the base unit in its list skips the variant.
def std_pack_variants(units: [Unit]) -> [Unit] {
    let all: [Unit] = units;
    std_variant_names().foreach((el) => {
        let pair: [str] = el;
        let nm: str = pair[0];
        let t: str = pair[1];
        let have = false;
        units.foreach((u) => {
            if (u.name == nm) { have = true; };
        });
        if (have) {
            let saved = res_target;
            res_target = t;
            obf.suspend();
            let u = std_compile(nm, [], [], all);
            obf.resume();
            res_target = saved;
            u.name = nm + "@" + t;
            all += u;
        };
    });
    all
};

def std_pack(units: [Unit]) -> str {
    let out: [str] = [];
    out += pack_version();
    let sets = arch_set_names();
    let us = std_pack_variants(units);
    out = pack_put(out, tostring(len(us) + len(sets)));
    us.foreach((u) => {
        out = pack_put(out, u.name);
        out = pack_put(out, pack_store(pack_unit_fields(u)));
    });
    let linux = arch_blocks(arch_lines_of("linux"));
    let none: [PBlk] = [];
    sets.foreach((w) => {
        out = pack_put(out, "arch." + w);
        if (w == "linux") {
            out = pack_put(out, pack_store(arch_pack_set(check_os_call_names(linux, w), none)));
        } else if (w == "win" || w == "kernel" || w == "web") {
            out = pack_put(out, pack_store(arch_pack_set(check_os_call_names(arch_blocks(arch_lines_of(w)), w), linux)));
        } else {
            out = pack_put(out, pack_store(arch_pack_set(arch_blocks(arch_lines_of(w)), none)));
        };
    });
    join(out, "")
};

// Every arch block set the pack carries (arch_set).
def arch_set_names() -> [str] {
    ["linux", "win", "web", "kernel", "wselftest", "threads", "wthreads", "math", "regions"]
};

// A block set's fields: the count, then per block a tag and the block. Tag
// "b": the block -- its name, whether it falls through, its references, its
// items and the raw lines their IR_TEXT items index. Tag "r": block N of
// `base` (the Linux prelude, for the Windows one), given by N alone.
def arch_pack_set(blks: [PBlk], base: [PBlk]) -> str {
    let bkeys: [str] = [];
    base.foreach((e) => {
        let bb: PBlk = e;
        bkeys += arch_block_key(bb);
    });
    let out: [str] = [];
    out = pack_put(out, tostring(len(blks)));
    blks.foreach((e) => {
        let bk: PBlk = e;
        let key = arch_block_key(bk);
        let at = -1;
        let i = 0;
        while (at < 0 && i < len(bkeys)) {
            if (bkeys[i] == key) { at = i; };
            i++;
        };
        if (at >= 0) {
            out = pack_put(out, "r");
            out = pack_put(out, tostring(at));
        } else {
            out = pack_put(out, "b");
            out = pack_put(out, bk.name);
            out = pack_put(out, bk.falls ? "1" : "0");
            out = pack_strs(out, bk.refs);
            out = pack_put(out, arch_block_items(bk));
            out = pack_strs(out, bk.txt);
        };
    });
    join(out, "")
};

// A block's items as the pack carries them, whether it holds them decoded or
// still packed.
def arch_block_items(bk: PBlk) -> str {
    if (len(bk.ir) == 0 && len(bk.blob) > 0) { bk.blob } else { pack_ir(bk.ir) }
};

// Everything a block is, as one string: two blocks with the same key are the
// same block.
def arch_block_key(bk: PBlk) -> str {
    let out: [str] = [];
    out = pack_put(out, bk.name);
    out = pack_put(out, bk.falls ? "1" : "0");
    out = pack_strs(out, bk.refs);
    out = pack_put(out, arch_block_items(bk));
    out = pack_strs(out, bk.txt);
    join(out, "")
};

type ArchGot = { ok: bool, blks: [PBlk] };

// Entry `entry` of `pack` as blocks; ok is false when the pack is not this
// version's, lacks the entry, or does not decode (the caller builds the
// blocks from the text).
def arch_unpack(pack: str, entry: str) -> ArchGot {
    let blks: [PBlk] = [];
    let ok = false;
    let ver = pack_version();
    if (len(pack) > 0 && pack[:len(ver)] == ver) {
        let cur = { s: pack, p: len(ver) };
        let n = pack_num(cur);
        let i = 0;
        while (!ok && i < n) {
            let nm = pack_get(cur);
            let ul = pack_len(cur);
            let at = cur.p;
            if (nm == entry) {
                let raw = pack[at:at + ul];
                raw = pack_plain(raw);
                if (len(raw) > 0) {
                    let c = { s: raw, p: 0 };
                    let nb = pack_num(c);
                    // a Windows block shared with the Linux prelude is a
                    // reference to it (arch_pack_set)
                    let base: [PBlk] = [];
                    if (entry == "arch.win" || entry == "arch.kernel") { base = arch_set("linux"); };
                    ok = true;
                    for b in 0..nb {
                        if (pack_get(c) == "r") {
                            let k = pack_num(c);
                            if (k >= 0 && k < len(base)) { blks += base[k]; } else { ok = false; };
                        } else {
                            let bn = pack_get(c);
                            let bf = pack_get(c) == "1";
                            let br = pack_get_strs(c);
                            let bb = pack_get(c);
                            let bt = pack_get_strs(c);
                            let noir: [long] = [];
                            blks += { name: bn, falls: bf, refs: br, ir: noir, blob: bb, txt: bt };
                        };
                    };
                };
            };
            cur.p = at + ul;
            i++;
        };
    };
    { ok: ok, blks: blks }
};

// Reading a pack: `cur` is the text and the position in it. pack_len
// reads a netstring's length, leaving the cursor at its text.
def pack_len(cur: Cursor) -> long {
    let s = cur.s;
    let p = cur.p;
    let n = 0;
    // The bound FIRST: a cut-off object (ycc build's cache) can end right
    // after a complete field, and reading the next byte was past the end. With
    // no ':' the cursor stops at the end, where every later read is empty.
    let end = len(s);
    let c = if (p < end) { s[p] } else { ':' };
    while (c != ':') {
        n = n * 10 + c - '0';
        p = p + 1;
        c = if (p < end) { s[p] } else { ':' };
    };
    cur.p = if (p < end) { p + 1 } else { p };
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

def pack_get_strss(cur: Cursor) -> [[str]] {
    let out: [[str]] = [];
    for i in 0..pack_num(cur) { out += [pack_get_strs(cur)]; };
    out
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
        let bad = false;
        for i in 0..n {
            let nm = pack_get(cur);
            let ul = pack_len(cur);
            let at = cur.p;
            if (name_in(names, nm)) {
                // Stored compressed? The method byte says so (a unit's plain
                // fields start with a digit); a failed decode leaves "", and
                // the pack is then not used -- the caller compiles from source
                // rather than reading a corrupt stream.
                let raw = pack[at:at + ul];
                raw = pack_plain(raw);
                if (len(raw) == 0) {
                    bad = true;
                } else {
                    // A NAME@T entry is the base unit compiled for T: it is
                    // linked (and named) as NAME.
                    let bn = std_base_name(nm);
                    got += unit_read({ s: raw, p: 0 }, bn, std_unit_bound(bn));
                };
            };
            cur.p = at + ul;
        };
        if (bad) { got = []; };
        names.foreach((el) => {
            let want: str = std_base_name(el);
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
    "ycc-unit 8\n"
};

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
    let dfl: [Dfl] = [];
    let tys: [str] = [];
    let fx: [str] = [];
    let i = 0;
    while (i < len(std)) {
        let u = std[i];
        let ut = 0;
        while (ut < len(u.tys)) {
            tys += u.tys[ut];
            ut = ut + 1;
        };
        if (std_unit_bound(u.name) && name_in(snames, u.name)) {
            let ufx = unit_fx_of(u);
            if (std_lib_index(u.name) < 0) {
                ext += u.exports;
                fx += ufx;
            } else {
                // a library unit is referenced through its namespace, exactly
                // as a package is (see pkg_ns): math.pi, and strip_ns keeps the
                // dot because the name is in xt.pkgs
                let xs = u.exports;
                let j = 0;
                while (j < len(xs)) {
                    let x = xs[j];
                    ext += { name: u.name + "." + x.name, label: x.label, typ: x.typ };
                    fx += ufx[j];
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
            };
        };
        i++;
    };
    i = 0;
    while (i < len(deps)) {
        let u = deps[i];
        if (name_in(pkgs, u.name)) {
            let ufx = unit_fx_of(u);
            let xs = u.exports;
            let j = 0;
            while (j < len(xs)) {
                let x = xs[j];
                ext += { name: u.name + "." + x.name, label: x.label, typ: x.typ };
                fx += ufx[j];
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
    xt.tys = tys;
    xt.fx = fx;
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
def emit_program(ast: Block, nr: Resolved, debug: bool, wlevel: long, std: [Unit], deps: [Unit]) -> { ok: bool, asm: [LinkPart], errors: [Diag], warnings: [Diag], times: [Timing], seal: long } {
    let seal_key = obf.begin(nr.src);
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
        let parts = link_units(std, deps, r.unit, gc_mode, seal_key);
        let pr = phase_end(times, "asm_parts", pt, ph);
        { ok: true, asm: parts, errors: r.errors, warnings: r.warnings,
            times: pr.times, seal: seal_key }
    } else {
        { ok: false, asm: [], errors: r.errors, warnings: r.warnings,
            times: times, seal: 0 }
    }
};

// is_intrinsic_name is exported for the language server's completion list: it
// needs to KNOW whether a word is a builtin, and the list it keeps of them is
// the one this predicate tests. Inert like the rest of the names here -- the
// splicer deletes the export line, so nothing reaches codegen (LSP.md 9.1).
export { emit_program, set_strict_heap, set_auto_regions, zero_bytes, compile_package, set_meta_pack, set_source_overlay, source_path, unit_externs, unit_prep, std_lib_path, std_units, std_unit_names, std_lib_deps, std_pack, pack_store, pack_plain_frame, lz_encode, deflate_pack, deflate_dynamic, unit_obj, unit_unobj, unit_iface, native_resolve, native_resolve_x, native_resolve_pk, origin_at, unused_imports, strip_ns, strip_list, strip_decl, phase_end, link_text, is_intrinsic_name, intrinsic_names };

// ── maps: dynamic {K => V} ────────────────────────────────────────────

def n_str(v: str, line: long, col: long) -> Leaf {
    { k: K.str, v: v, line: line, col: col }
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

def gen_maplit(st: EmitSt, node: RecLit, hashed: bool) -> EmitSt {
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
    if (hashed) {
        // the hash index (rt.y y_map_note_*): empty until the map outgrows the scan
        let zarr: ArrLit = { k: K.array, elems: [], line: ln, col: cl };
        rkeys += "zidx";
        rvals += zarr;
    };
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

// The statements that find key t+"k" in map t+"m" (both bound by the caller):
// t+"i" is its entry index, t+"n" the entry count, and t+"i" == t+"n" a miss.
// A str, long or float key goes through the runtime probe (map$find), which uses the
// hash index once the map has one; any other key scans inline (map_scan).
def map_locate(st: EmitSt, marr: Node, t: str, sts: [Node], ln: long, cl: long) -> [Node] {
    let m: Node = n_id(t + "m", ln, cl);
    if (map_hashed(map_key_of(infer(st, marr)))) {
        sts += n_decl(t + "n", n_call1("len", map_field(m, "keys", ln, cl), ln, cl), ln, cl);
        sts += n_decl(t + "i", n_call2("map$find", m, n_id(t + "k", ln, cl), ln, cl), ln, cl);
    } else {
        sts += n_decl(t + "ks", map_field(m, "keys", ln, cl), ln, cl);
        sts += n_decl(t + "i", n_num("0", ln, cl), ln, cl);
        sts += n_decl(t + "n", n_call1("len", n_id(t + "ks", ln, cl), ln, cl), ln, cl);
        sts += n_decl(t + "j", n_id(t + "n", ln, cl), ln, cl);
        sts += map_scan(t, ln, cl);
    };
    sts
};

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
    sts = map_locate(st, node.arr, t, sts, ln, cl);
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
        sts += n_idx(map_field(m, "vals", ln, cl), i, ln, cl);
    } else if (mode == "dot") {
        // `m.k`: the entry, or stop with the key in the
        // message -- the checker has already said this read is V, not V?.
        let msg: Node = n_bin("+", n_bin("+", n_str("runtime error: no entry '", ln, cl), n_id(t + "k", ln, cl), ln, cl), n_str("' in this map\n", ln, cl), ln, cl);
        let miss: [Node] = [];
        miss += n_call1("eputs", msg, ln, cl);
        miss += n_call1("exit", n_num("1", ln, cl), ln, cl);
        let hit: [Node] = [];
        hit += n_num("0", ln, cl);
        sts += n_if(n_bin("==", i, n, ln, cl), block_of(miss, ln, cl), block_of(hit, ln, cl), ln, cl);
        sts += n_idx(map_field(m, "vals", ln, cl), i, ln, cl);
    } else {
        let b: Node = n_id(t + "b", ln, cl);
        let fill: [Node] = [];
        fill += n_assign(t + "b", n_call1("some", n_idx(map_field(m, "vals", ln, cl), i, ln, cl), ln, cl), ln, cl);
        fill += { k: K.idxassign, arr: map_field(m, "boxes", ln, cl), idx: i, v: b, line: ln, col: cl };
        fill += n_num("0", ln, cl);
        let kept: [Node] = [];
        kept += n_num("0", ln, cl);
        let hit: [Node] = [];
        hit += n_decl(t + "b", n_idx(map_field(m, "boxes", ln, cl), i, ln, cl), ln, cl);
        hit += n_if(n_call1("is_some", b, ln, cl), block_of(kept, ln, cl), block_of(fill, ln, cl), ln, cl);
        hit += b;
        let miss: [Node] = [];
        miss += n_id("none", ln, cl);
        sts += n_if(n_bin("<", i, n, ln, cl), block_of(hit, ln, cl), block_of(miss, ln, cl), ln, cl);
    };
    gen(st, block_of(sts, ln, cl))
};

def map_field(m: Node, field: str, ln: long, cl: long) -> Node {
    let name = "map$" + field;
    n_call1(name, m, ln, cl)
};

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
    let mt = unfold(infer(st, node.arr));
    let vt: Type = type_node({ k: K.tunk });
    if (mt.k == K.tmap) { let mm: TMap = mt; vt = mm.of; };
    let sts: [Node] = [];
    sts += n_decl(t + "m", node.arr, ln, cl);
    sts += n_decl(t + "k", node.idx, ln, cl);
    sts += n_decl_typ(t + "v", node.v, vt, ln, cl);
    sts = map_locate(st, node.arr, t, sts, ln, cl);
    let hit: [Node] = [];
    hit += { k: K.idxassign, arr: map_field(m, "vals", ln, cl), idx: i, v: v, line: ln, col: cl };
    hit += { k: K.idxassign, arr: map_field(m, "boxes", ln, cl), idx: i, v: n_id("none", ln, cl), line: ln, col: cl };
    hit += n_num("0", ln, cl);
    let grow: [Node] = [];
    grow += n_call2("push", map_field(m, "keys", ln, cl), k, ln, cl);
    grow += n_call2("push", map_field(m, "vals", ln, cl), v, ln, cl);
    grow += n_call2("push", map_field(m, "boxes", ln, cl), n_id("none", ln, cl), ln, cl);
    if (map_hashed(map_key_of(mt))) { grow += n_call1("map$note", m, ln, cl); };
    grow += n_num("0", ln, cl);
    sts += n_if(n_bin("<", i, n, ln, cl), block_of(hit, ln, cl), block_of(grow, ln, cl), ln, cl);
    sts += v;
    gen(st, block_of(sts, ln, cl))
};
