// native.y — typed AST -> x86_64 assembly (AT&T/GAS) for the native backend.
// Usage:
//   import types from "./types.y";
//   import native from "./native.y";
//   let r = native.emit_program(ast);  // { ok, asm, errors }
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

import arch from "./arch_x64.y";
import types from "./types.y";
import rename from "./rename.y";
import lexer from "./lexer.y";

// The runtime text native_resolve_x splices into programs. `embed` (see
// embed_decl) makes each file a str const when the compiler is BUILT: the
// shipped ycc is a standalone static ELF and cannot read support files at
// run time. The C copy embeds the same files (Y_EMBED in src/c/yv.h).
embed RT_SRC from "./std/rt.y";
embed PRELUDE_SRC from "./std/prelude.y";
embed EXEC_SRC from "./std/exec.y";
embed STR_SRC from "./std/str.y";

// ── native import resolution ───────────────────────────────────────────
// An import is a COMPILE-TIME text splice, and the C copy splices the same
// way: `import io from "path"` inlines the module's source in place and drops
// its `export` line. References `io.x` are rewritten to plain `x` by
// strip_namespaces (AST-level, so strings are untouched). Module top-levels
// must be defs; duplicate def names across the splice are a loud error.

def native_resolve(src: str, base_dir: str, depth: long) -> { src: str, imports: [str], pre: long } {
    native_resolve_x(src, base_dir, depth, true)
};

// allow_exec = false is `ycc --no-exec`: the exec chunk is not spliced, so
// `exec(...)` fails with "undefined function" and the binary has no path
// to a shell at all.
//
// `pre` is how many lines the prelude added in FRONT of the user's text.
// Prepending (rather than appending) is deliberate: defs hoist either way,
// but a later def shadows an earlier one, so a user's own `readline` must
// come after ours to win. The cost is that every position downstream is
// shifted, which the driver undoes when it prints an error.
def native_resolve_x(src: str, base_dir: str, depth: long, allow_exec: bool) -> { src: str, imports: [str], pre: long } {
    // NOTE: seen-threading wrapper (see native_resolve_seen): asm.y imports
    // enc64 as `enc` AND elf.y imports enc64 as `elfenc`; without dedup the
    // encoder splices twice and every enc64 def collides (find_dup is fatal).
    let r = native_resolve_seen(src, base_dir, depth, []);
    let rsrc = r.src;
    let rimports = r.imports;
    let pre = 0;
    // The runtime library (std/rt.y) is spliced in front of EVERY program:
    // generated code calls into it by fixed label (`call y_print_long`), so
    // there is no name to test for. Unused helpers cost nothing in the
    // output — prune_bodies drops them at emit time.
    let rt = std_text(RT_SRC);
    // What the name checks below search: the program's own text, in one
    // pass for all three name lists (words_seen). No std chunk is
    // searched: rt and str.y call none of the trigger names, and exec.y's
    // one call into another chunk (y_stdin_sync, a prelude def) is why
    // splicing exec also splices the prelude.
    let pn = prelude_names();
    let xn = exec_names();
    let seen = words_seen(rsrc, pn + xn + str_names());
    let px = len(pn) + len(xn);
    rsrc = rt + rsrc;
    pre = pre + count_nl(rt);
    // std/str.y, std/exec.y and std/prelude.y go in front of the resolved
    // text, but only when the program actually mentions one of their
    // names — otherwise every binary would carry code it never calls.
    // str.y's names count only in method-call form, `.name(`: a helper-
    // backed string method cannot be reached any other way, so a variable
    // called `lines` or a field `r.count` splices nothing. The last slot
    // of seen stands for the y_fmt_* helpers: an f-string field with a
    // format spec sets it to 2 (words_scan).
    if (seen_any(seen, px, len(seen), 2)) {
        let tt = std_text(STR_SRC);
        rsrc = tt + rsrc;
        pre = pre + count_nl(tt);
        0
    } else { 0; };
    let want_prelude = seen_any(seen, 0, len(pn), 1);
    if (allow_exec) {
        if (seen_any(seen, len(pn), px, 1)) {
            let xt = std_text(EXEC_SRC);
            rsrc = xt + rsrc;
            pre = pre + count_nl(xt);
            want_prelude = true;
            0
        } else { 0; };
        0
    } else { 0; };
    if (want_prelude) {
        let pt = std_text(PRELUDE_SRC);
        rsrc = pt + rsrc;
        pre = pre + count_nl(pt);
        0
    } else { 0; };
    { src: rsrc, imports: rimports, pre: pre }
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

// An embedded std file, ready to go in front of the program: newline-
// terminated, so the program's own first line still starts a line.
def std_text(s: str) -> str {
    if (s[len(s) - 1:] == "\n") { s } else { s + "\n" }
};

// How many lines a newline-terminated text holds (what `pre` counts).
def count_nl(s: str) -> long {
    let b = bytes(s);
    let n = len(b);
    let c = 0;
    let i = 0;
    while (i < n) {
        if (b[i] == 10) { c = c + 1; 0; } else { 0; };
        i = i + 1;
        0
    };
    c
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
        0
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
            0
        } else if (c == 47 && i + 1 < n && byte_at(code, i + 1) == 47) {
            // `//`: up to the newline
            i = i + 2;
            while (i < n && byte_at(code, i) != 10) {
                i = i + 1;
                0
            };
            0
        } else if (c == 47 && i + 1 < n && byte_at(code, i + 1) == 42) {
            // `/*`: past the first `*/`
            i = i + 2;
            let open = true;
            while (open && i < n) {
                if (byte_at(code, i) == 42 && i + 1 < n && byte_at(code, i + 1) == 47) {
                    open = false;
                    i = i + 1;
                    0
                } else { 0; };
                i = i + 1;
                0
            };
            0
        } else {
            if (pend >= 0) {
                if (c == 40) { seen[pend] = 2; 0; } else { 0; };
                pend = 0 - 1;
                0
            } else { 0; };
            if (c == 34 || c == 39) {
                // a string literal: past its closing quote
                i = i + 1;
                let open = true;
                while (open && i < n) {
                    let d = byte_at(code, i);
                    if (d == 92) { i = i + 2; 0; }
                    else if (d == c) { open = false; i = i + 1; 0; }
                    else { i = i + 1; 0; };
                    0
                };
                0
            } else if (word_byte(c)) {
                let j = i + 1;
                while (j < n && word_byte(byte_at(code, j))) {
                    j = j + 1;
                    0
                };
                if (j == i + 1 && c == 102 && j < n && byte_at(code, j) == 34) {
                    // f"...": the fields, and whether one has a spec
                    let w = lexer.fstr_walk(code, j);
                    let fs = w.fields;
                    let f = 0;
                    while (f < len(fs)) {
                        words_scan(code, fs[f], fs[f + 1], names, seen);
                        if (fs[f + 3] > fs[f + 2]) { seen[len(names)] = 2; 0; } else { 0; };
                        f = f + 4;
                        0
                    };
                    i = w.end;
                    0
                } else {
                    let m = 0;
                    while (m < len(names)) {
                        let nm: str = names[m];
                        if (len(nm) == j - i && word_at(code, i, nm)) {
                            if (seen[m] == 0) { seen[m] = 1; 0; } else { 0; };
                            if (prev == 46) { pend = m; 0; } else { 0; };
                            0
                        } else { 0; };
                        m = m + 1;
                        0
                    };
                    i = j;
                    0
                };
                0
            } else {
                i = i + 1;
                0
            };
            prev = c;
            0
        };
        0
    };
    0
};

// A byte of an identifier-shaped word (the lexer's isalnum: letters,
// digits, `_`).
def word_byte(c: long) -> bool {
    (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || c == 95
};

// A blank as the lexer skips it (its isspace: space, tab, LF, CR).
def blank_byte(c: long) -> bool {
    c == 32 || c == 9 || c == 10 || c == 13
};

// Whether code[i:i + len(nm)] is nm (the caller checked the length).
def word_at(code: str, i: long, nm: str) -> bool {
    let ok = true;
    let k = 0;
    while (ok && k < len(nm)) {
        if (byte_at(code, i + k) != byte_at(nm, k)) { ok = false; 0; } else { 0; };
        k = k + 1;
        0
    };
    ok
};

// Whether any of seen[lo..hi) reaches `level` (see words_seen).
def seen_any(seen: [long], lo: long, hi: long, level: long) -> bool {
    let r = false;
    let i = lo;
    while (i < hi) {
        if (seen[i] >= level) { r = true; 0; } else { 0; };
        i = i + 1;
        0
    };
    r
};

// Collapse "/./" segments so the same file resolves to one key no matter
// how deep the import nesting is (base dirs accumulate "/." per level:
// "ycc/././enc64.y" vs "ycc/./././enc64.y"). Deterministic, so same-file
// inputs always yield the same key (sufficient for seen-dedup).
def norm_path(p: str) -> str {
    let parts = split(p, "/");
    let out = [];
    let i = 0;
    while (i < len(parts)) {
        let seg = parts[i];
        if (seg == ".") {
            0
        } else {
            out += seg;
            0
        };
        i = i + 1;
        0
    };
    join(out, "/")
};

def seen_has(seen: [str], full: str) -> bool {
    let i = 0;
    let found = false;
    while (i < len(seen)) {
        let e = seen[i];
        if (e == full) {
            found = true;
            0
        };
        i = i + 1;
        0
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
// The file found is spliced exactly like `import x from "path"` and its
// defs are called through the namespace: `net.listen_tcp(...)` and friends.

def dir_of(p: str) -> str {
    let s = last_index_of(p, "/");
    if (s < 0) { "" } else { p[:s] }
};

def std_resolve(name: str, base_dir: str) -> str {
    let cands = [];
    cands += base_dir + "/" + name + ".y";
    cands += base_dir + "/std/" + name + ".y";
    cands += "std/" + name + ".y";
    cands += "src/y/std/" + name + ".y";
    let av = argv();
    if (len(av) > 0) {
        let exe: str = av[0];
        let d = dir_of(exe);
        if (len(d) > 0) {
            cands += d + "/std/" + name + ".y";
            cands += d + "/src/y/std/" + name + ".y";
            cands += d + "/../src/y/std/" + name + ".y";
            0
        } else { 0; };
        0
    } else { 0; };
    let found = "";
    let i = 0;
    while (i < len(cands)) {
        if (len(found) == 0) {
            let c: str = cands[i];
            if (read_file(c) == none) {
                0
            } else {
                found = norm_path(c);
                0
            };
            0
        } else { 0; };
        i = i + 1;
        0
    };
    found
};

def native_resolve_seen(src: str, base_dir: str, depth: long, seen: [str]) -> { src: str, imports: [str], seen: [str] } {
    if (depth > 32) {
        // Fatal, like a missing module: carrying on compiled the program
        // without the rest of the chain and exited 0.
        puts("error: native import depth exceeded (cycle?)\n");
        exit(1);
        { src: "", imports: [], seen: seen }
    } else {
        let lines = split(src, "\n");
        let out_lines = [];
        let imports = [];
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
                if (from_idx >= 0) {
                    name = trim(rest[:from_idx]);
                    let path_part = trim(rest[from_idx + 6:]);
                    if (path_part[len(path_part) - 1:] == ";") {
                        path_part = path_part[:len(path_part) - 1];
                        0
                    };
                    path = path_part[1:len(path_part) - 1];
                    // NOTE: normalized (see norm_path): nested base dirs
                    // accumulate "/." segments, so raw joins of the same file
                    // differ per depth and seen-dedup would never hit.
                    full = norm_path(base_dir + "/" + path);
                    if (path[:1] == "/") { full = norm_path(path); 0; };
                    0
                } else {
                    // bare `import name;`: an optional std module (net, ui,
                    // ...) or a project-local one — see std_resolve above.
                    name = trim(rest);
                    if (name[len(name) - 1:] == ";") {
                        name = trim(name[:len(name) - 1]);
                        0
                    };
                    path = name;
                    full = std_resolve(name, base_dir);
                    0
                };
                if (len(name) == 0) {
                    out_lines += line;
                    0
                } else if (len(full) == 0) {
                    // Fatal: carrying on only reported the module's names as
                    // undefined further down, after this message scrolled by.
                    puts("error: cannot find module '" + name + "' (import name; looks next to the importer and in std/)\n");
                    exit(1);
                    0
                } else {
                    let mod_src = read_file(full);
                    if (mod_src == none) {
                        puts("error: cannot open import '" + path + "' (resolved to '" + full + "')\n");
                        exit(1);
                        0
                    } else if (seen_has(seen, full)) {
                        // NOTE: already spliced (see native_resolve note):
                        // record the namespace name (strip_ns needs it) but
                        // do NOT splice the text a second time.
                        imports += name;
                        0
                    } else {
                        seen += full;
                        let last_slash = last_index_of(full, "/");
                        let mod_dir = base_dir;
                        if (last_slash >= 0) {
                            mod_dir = full[:last_slash];
                            0
                        };
                        // mod_src is str? (read_file returns none on missing
                        // file); the none case exited above, so unwrap here.
                        let mod_src2 = unwrap(mod_src);
                        let sub = native_resolve_seen(mod_src2, mod_dir, depth + 1, seen);
                        let subsrc = sub.src;
                        let subns = sub.imports;
                        let subseen = sub.seen;
                        seen = subseen;
                        // splice the module text inline (its own imports first)
                        let sub_lines = split(subsrc, "\n");
                        let k = 0;
                        while (k < len(sub_lines)) {
                            out_lines += sub_lines[k];
                            k = k + 1;
                            0
                        };
                        let m = 0;
                        while (m < len(subns)) {
                            imports += subns[m];
                            m = m + 1;
                            0
                        };
                        imports += name;
                        0
                    };
                    0
                };
                0
            } else if (is_embed_decl(trimmed)) {
                out_lines += embed_decl(trimmed, base_dir);
                0
            } else {
                // NOTE: no empty if-arms here — keep the `0;` filler.
                // Export lines are dropped (defs are spliced; uses are
                // rewritten by strip_namespaces).
                if (trimmed[:7] != "export ") {
                    out_lines += line;
                    0
                } else {
                    // `export { a, b,` may run on over several lines: drop
                    // them through the one that closes the list.
                    if (index_of(line, "{") >= 0) {
                        while (index_of(lines[i], "}") < 0 && i + 1 < n) {
                            i = i + 1;
                            0
                        };
                        0
                    };
                    0
                };
                0
            };
            i = i + 1;
            0
        };
        { src: join(out_lines, "\n"), imports: imports, seen: seen }
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
        0
    } else { 0; };
    if (len(path_part) < 2 || path_part[len(path_part) - 1:] != "\"") {
        puts("error: malformed embed (embed NAME from \"path\";): " + trimmed + "\n");
        exit(1);
        0
    } else { 0; };
    let path = path_part[1:len(path_part) - 1];
    let full = norm_path(base_dir + "/" + path);
    if (path[:1] == "/") { full = norm_path(path); 0; } else { 0; };
    let data = read_file(full);
    if (data == none) {
        puts("error: cannot embed '" + path + "' (resolved to '" + full + "')\n");
        exit(1);
        0
    } else { 0; };
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
        if (c == 92) {
            esc = "\\\\";
            0
        } else if (c == 34) {
            esc = "\\\"";
            0
        } else if (c == 10) {
            esc = "\\n";
            0
        } else if (c == 13) {
            esc = "\\r";
            0
        } else if (c < 32 && c != 9) {
            esc = "\\x" + hex[c / 16:c / 16 + 1] + hex[c % 16:c % 16 + 1];
            0
        } else { 0; };
        if (len(esc) > 0) {
            out += s[run:i];
            out += esc;
            run = i + 1;
            0
        } else { 0; };
        i = i + 1;
        0
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
    let ok = false;
    if (c >= 48) {
        if (c <= 57) { ok = true; 0; } else { 0; };
        0
    } else { 0; };
    if (c >= 97) {
        if (c <= 122) { ok = true; 0; } else { 0; };
        0
    } else { 0; };
    if (c >= 65) {
        if (c <= 90) { ok = true; 0; } else { 0; };
        0
    } else { 0; };
    if (c == 95) { ok = true; 0; } else { 0; };
    if (c == 36) { ok = true; 0; } else { 0; };
    ok
};

// First non-blank offset in [i, hi); blank means space (the asm dialect
// indents with spaces) or end of range.
def skip_sp(b: [byte], i: long, hi: long) -> long {
    let p = i;
    let go = true;
    while (go) {
        if (p >= hi) {
            go = false;
            0
        } else {
            if (b[p] == 32) {
                p = p + 1;
                0
            } else {
                go = false;
                0
            };
            0
        };
        0
    };
    p
};

// End of the identifier at offset `i` (a leading `$` — an assembly
// immediate like `$ystr_end-ystr` — is not part of the name).
def tok_end_b(b: [byte], i: long, hi: long) -> long {
    let p = i;
    if (p < hi) {
        if (b[p] == 36) { p = p + 1; 0; } else { 0; };
        0
    } else { 0; };
    let go = true;
    while (go) {
        if (p >= hi) {
            go = false;
            0
        } else {
            if (is_id_b(b[p])) {
                p = p + 1;
                0
            } else {
                go = false;
                0
            };
            0
        };
        0
    };
    p
};

// The identifier at offset `i`, or "".
def tok_at_b(text: str, b: [byte], i: long, hi: long) -> str {
    let s = i;
    if (s < hi) {
        if (b[s] == 36) { s = s + 1; 0; } else { 0; };
        0
    } else { 0; };
    let e = tok_end_b(b, i, hi);
    if (e > s) { text[s:e] } else { "" }
};

def tok_push(out: [str], t: str) -> [str] {
    if (len(t) == 0) { out } else { out += t }
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
            0
        } else if (w == "lea") {
            out = tok_push(out, tok_at_b(text, b, op, hi));
            0
        } else if (w == "mov") {
            let q = p;
            let go = true;
            while (go) {
                if (q >= hi) {
                    go = false;
                    0
                } else {
                    if (b[q] == 36) {
                        go = false;
                        0
                    } else {
                        q = q + 1;
                        0
                    };
                    0
                };
                0
            };
            if (q < hi) {
                let t = tok_at_b(text, b, q, hi);
                out = tok_push(out, t);
                let after = tok_end_b(b, q, hi);
                if (after < hi) {
                    if (b[after] == 45) {
                        out = tok_push(out, tok_at_b(text, b, after + 1, hi));
                        0
                    } else { 0; };
                    0
                } else { 0; };
                0
            } else { 0; };
            0
        } else {
            if (want_jumps) {
                if (w[:1] == "j") {
                    out = tok_push(out, tok_at_b(text, b, op, hi));
                    0
                } else { 0; };
                0
            } else { 0; };
            0
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
        if (b[i] == 10) {
            res = line_refs_b(text, b, ls, i, res, want_jumps);
            ls = i + 1;
            0
        } else { 0; };
        i = i + 1;
        0
    };
    if (ls < hi) {
        res = line_refs_b(text, b, ls, hi, res, want_jumps);
        0
    } else { 0; };
    res
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
            if (b[e] == 58) {
                let s = p;
                if (b[s] == 36) { s = s + 1; 0; } else { 0; };
                lab = text[s:e];
                0
            } else { 0; };
            0
        } else { 0; };
        0
    } else { 0; };
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
        0
    } else { 0; };
    if (p >= hi) {
        true
    } else {
        b[p] == 46
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
            if (b[i] == 10) {
                p = i + 1;
                0
            } else { 0; };
            i = i + 1;
            0
        };
        let s = skip_sp(b, p, end);
        if (s >= end) {
            // blank line: drop it and look at the line before
            if (p > lo) {
                end = p - 1;
                0
            } else {
                go = false;
                0
            };
            0
        } else {
            go = false;
            let w = tok_at_b(text, b, s, end);
            if (w == "ret") { falls = false; 0; }
            else if (w == "jmp") { falls = false; 0; }
            else if (w == "syscall") { falls = false; 0; }
            else { 0; };
            0
        };
        0
    };
    falls
};

// Index of `tok` in `names`, or -1 (length first: most misses are free).
def name_index(names: [str], tok: str) -> long {
    let tl = len(tok);
    let i = 0;
    let found = -1;
    while (i < len(names)) {
        if (found < 0) {
            let nm: str = names[i];
            if (len(nm) == tl) {
                if (nm == tok) { found = i; 0; } else { 0; };
                0
            } else { 0; };
            0
        } else { 0; };
        i = i + 1;
        0
    };
    found
};

// Mark every names[i] some entry of `roots` points at, then close over kept
// blocks: their own references and (for code that runs into the next block)
// their successor. `falls[i]` says block i falls through to block i+1.
def shake_keep(names: [str], refs: [[str]], falls: [bool], keep: [bool], roots: [str]) -> [bool] {
    let n = len(names);
    let r = 0;
    while (r < len(roots)) {
        let idx = name_index(names, roots[r]);
        if (idx >= 0) { keep[idx] = true; 0; } else { 0; };
        r = r + 1;
        0
    };
    let scanned = [];
    let i = 0;
    while (i < n) {
        scanned += false;
        i = i + 1;
        0
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
                            if (!(keep[b + 1])) { keep[b + 1] = true; 0; } else { 0; };
                            0
                        } else { 0; };
                        0
                    } else { 0; };
                    let rs = refs[b];
                    let j = 0;
                    while (j < len(rs)) {
                        let idx = name_index(names, rs[j]);
                        if (idx >= 0) {
                            if (!(keep[idx])) { keep[idx] = true; 0; } else { 0; };
                            0
                        } else { 0; };
                        j = j + 1;
                        0
                    };
                    0
                } else { 0; };
                0
            } else { 0; };
            b = b + 1;
            0
        };
        0
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
    let names = [];
    let starts = [];
    let i = 0;
    let ls = 0;
    while (i < n) {
        if (b[i] == 10) {
            let lab = label_at(text, b, ls, i);
            if (len(lab) > 0) {
                names += lab;
                starts += ls;
                0
            } else {
                if (len(starts) == 0) {
                    names += "";
                    starts += 0;
                    0
                } else { 0; };
                0
            };
            ls = i + 1;
            0
        } else { 0; };
        i = i + 1;
        0
    };
    if (ls < n) {
        let lab = label_at(text, b, ls, n);
        if (len(lab) > 0) {
            names += lab;
            starts += ls;
            0
        } else {
            if (len(starts) == 0) {
                names += "";
                starts += 0;
                0
            } else { 0; };
            0
        };
        0
    } else { 0; };
    let nb = len(starts);
    if (nb == 0) {
        text
    } else {
        // per-block references + fall-through flags
        let refs = [];
        let falls = [];
        let k = 0;
        while (k < nb) {
            let lo = starts[k];
            let hi = n;
            if (k + 1 < nb) { hi = starts[k + 1]; 0; } else { 0; };
            refs += [refs_range(text, b, lo, hi, [], true)];
            if (block_falls_b(text, b, lo, hi)) {
                if (is_data_line_b(text, b, lo, hi)) {
                    falls += false;
                    0
                } else {
                    falls += true;
                    0
                };
                0
            } else {
                falls += false;
                0
            };
            k = k + 1;
            0
        };
        let keep = [];
        k = 0;
        while (k < nb) {
            if (len(names[k]) == 0) {
                keep += true;
                0
            } else {
                keep += false;
                0
            };
            k = k + 1;
            0
        };
        keep = shake_keep(names, refs, falls, keep, root_refs);
        // reassemble kept blocks (their byte ranges), in order
        let pieces = [];
        k = 0;
        while (k < nb) {
            if (keep[k]) {
                let lo = starts[k];
                let hi = n;
                if (k + 1 < nb) { hi = starts[k + 1]; 0; } else { 0; };
                pieces += text[lo:hi];
                0
            } else { 0; };
            k = k + 1;
            0
        };
        join(pieces, "")
    }
};

// Drop function bodies nothing reaches: dead stdlib code the program never
// calls. Bodies are referenced by label from other bodies AND from the arch
// prelude (a prelude block may call a Y-side helper), so
// `asm_roots` is the prelude text. Returns the kept bodies plus everything
// they reference — the roots for shaking the arch prelude itself.
def prune_bodies(bodies: [str], asm_roots: str) -> { bodies: [str], refs: [str] } {
    let nb = len(bodies);
    let labels = [];
    let refs = [];
    let i = 0;
    while (i < nb) {
        let b = bodies[i];
        labels += body_label(b);
        refs += [text_refs(b, true)];
        i = i + 1;
        0
    };
    let keep = [];
    let falls = [];
    i = 0;
    while (i < nb) {
        keep += false;
        falls += false;
        i = i + 1;
        0
    };
    let roots = text_refs(asm_roots, true);
    let root = name_index(labels, "_start");
    if (root >= 0) {
        roots += "_start";
        0
    } else { 0; };
    keep = shake_keep(labels, refs, falls, keep, roots);
    let out = [];
    let outrefs = [];
    i = 0;
    while (i < nb) {
        if (keep[i]) {
            let b = bodies[i];
            out += b;
            let rs = refs[i];
            let j = 0;
            while (j < len(rs)) {
                outrefs += rs[j];
                j = j + 1;
                0
            };
            0
        } else { 0; };
        i = i + 1;
        0
    };
    { bodies: out, refs: outrefs }
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
            if (index_of("0123456789", s[i:i + 1]) < 0) { ok = false; 0; } else { 0; };
            i = i + 1;
            0
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
        if (imports[i] == name) { found = true; 0; } else { 0; };
        i = i + 1;
        0
    };
    found
};

// Identity with a declared {k: str} return: normalizes multi-shape
// expression arms (strip_*/infer rebuilds a different node kind per arm,
// which strict branch-teq rejects) into unknown-shaped flows. Callers read
// .k/.line/.col directly; deeper reads unify quietly (tcompat law). The
// RUNTIME value passes through untouched (same node object).
def normnode(anode) -> { k: str } { anode };

// strip_namespaces: dot(NAME, key) with NAME an import namespace -> id(key).
// Full AST rebuild (only dot nodes change, but uniform rebuild is simplest).

def strip_list(nodes: [{ k: str }], imports: [str]) -> [{ k: str }] {
    let out = [];
    let i = 0;
    while (i < len(nodes)) {
        out += strip_ns(nodes[i], imports);
        i = i + 1;
    };
    out
};

def strip_ns(node, imports: [str]) -> { k: str } {
    let k = node.k;
    if (k == "dot") {
        let dobj = node.obj;
        let obj = strip_ns(dobj, imports);
        let okey = node.key;
        let oline = node.line;
        let ocol = node.col;
        if (obj.k == "id") {
            let ov = obj.v;
            if (is_ns(ov, imports)) {
                normnode({ k: "id", v: okey, line: oline, col: ocol })
            } else {
                normnode({ k: "dot", obj: obj, key: okey, line: oline, col: ocol })
            }
        } else {
            normnode({ k: "dot", obj: obj, key: okey, line: oline, col: ocol })
        }
    } else if (k == "un") {
        normnode({ k: "un", op: node.op, e: strip_ns(node.e, imports), line: node.line, col: node.col })
    } else if (k == "addr" || k == "deref") {
        normnode({ k: k, e: strip_ns(node.e, imports), line: node.line, col: node.col })
    } else if (k == "bin") {
        normnode({ k: "bin", op: node.op, l: strip_ns(node.l, imports), r: strip_ns(node.r, imports), line: node.line, col: node.col })
    } else if (k == "call") {
        normnode({ k: "call", callee: strip_ns(node.callee, imports), args: strip_list(node.args, imports), line: node.line, col: node.col })
    } else if (k == "if") {
        normnode({ k: "if", cond: strip_ns(node.cond, imports), then: strip_ns(node.then, imports), els: strip_ns(node.els, imports), has_else: node.has_else, line: node.line, col: node.col })
    } else if (k == "while") {
        normnode({ k: "while", cond: strip_ns(node.cond, imports), body: strip_ns(node.body, imports), line: node.line, col: node.col })
    } else if (k == "block") {
        normnode({ k: "block", stmts: strip_list(node.stmts, imports), line: node.line, col: node.col })
    } else if (k == "decl") {
        strip_decl(node, imports)
    } else if (k == "func") {
        normnode({ k: "func", params: node.params, ptypes: node.ptypes, ret: node.ret, body: strip_ns(node.body, imports), line: node.line, col: node.col, defs: node.defs })
    } else if (k == "assign") {
        normnode({ k: "assign", name: node.name, v: strip_ns(node.v, imports), line: node.line, col: node.col })
    } else if (k == "incdec") {
        normnode({ k: "incdec", op: node.op, pre: node.pre, tgt: strip_ns(node.tgt, imports), line: node.line, col: node.col })
    } else if (k == "opassign") {
        normnode({ k: "opassign", op: node.op, tgt: strip_ns(node.tgt, imports), v: strip_ns(node.v, imports), line: node.line, col: node.col })
    } else if (k == "store") {
        normnode({ k: "store", p: strip_ns(node.p, imports), v: strip_ns(node.v, imports), line: node.line, col: node.col })
    } else if (k == "ret") {
        normnode({ k: "ret", e: strip_ns(node.e, imports), line: node.line, col: node.col })
    } else if (k == "array") {
        normnode({ k: "array", elems: strip_list(node.elems, imports), line: node.line, col: node.col })
    } else if (k == "arrrep") {
        normnode({ k: "arrrep", v: strip_ns(node.v, imports), n: node.n, line: node.line, col: node.col })
    } else if (k == "rec") {
        normnode({ k: "rec", keys: node.keys, vals: strip_list(node.vals, imports), line: node.line, col: node.col })
    } else if (k == "map") {
        normnode({ k: "map", keys: node.keys, vals: strip_list(node.vals, imports), line: node.line, col: node.col })
    } else if (k == "index") {
        normnode({ k: "index", arr: strip_ns(node.arr, imports), idx: strip_ns(node.idx, imports), line: node.line, col: node.col })
    } else if (k == "slice") {
        normnode({ k: "slice", arr: strip_ns(node.arr, imports), lo: strip_ns(node.lo, imports), hi: strip_ns(node.hi, imports), line: node.line, col: node.col })
    } else if (k == "idxassign") {
        normnode({ k: "idxassign", arr: strip_ns(node.arr, imports), idx: strip_ns(node.idx, imports), v: strip_ns(node.v, imports), line: node.line, col: node.col })
    } else if (k == "dotassign") {
        normnode({ k: "dotassign", obj: strip_ns(node.obj, imports), key: node.key, v: strip_ns(node.v, imports), line: node.line, col: node.col })
    } else if (k == "foreach") {
        normnode({ k: "foreach", name: node.name, iter: strip_ns(node.iter, imports), body: strip_ns(node.body, imports), line: node.line, col: node.col })
    } else if (k == "forrange") {
        normnode({ k: "forrange", name: node.name, lo: strip_ns(node.lo, imports), hi: strip_ns(node.hi, imports), body: strip_ns(node.body, imports), line: node.line, col: node.col })
    } else if (k == "for") {
        normnode({ k: "for", init: strip_ns(node.init, imports), cond: strip_ns(node.cond, imports), step: strip_ns(node.step, imports), body: strip_ns(node.body, imports), line: node.line, col: node.col })
    } else if (k == "sliceassign") {
        normnode({ k: "sliceassign", arr: strip_ns(node.arr, imports), lo: strip_ns(node.lo, imports), hi: strip_ns(node.hi, imports), v: strip_ns(node.v, imports), line: node.line, col: node.col })
    } else {
        normnode(node)
    }
};

def strip_decl(node, imports: [str]) -> { k: str } {
    if (node.kind == "def") {
        normnode({ k: "decl", kind: "def", name: node.name, v: strip_ns(node.v, imports), line: node.line, col: node.col })
    } else {
        normnode({ k: "decl", kind: node.kind, name: node.name, typ: node.typ, v: strip_ns(node.v, imports), line: node.line, col: node.col })
    }
};

// ── emit state ─────────────────────────────────────────────────────────
// st = { out, rodata, uid, fuid, loc, env, slots,
//        self_label, end_label, fns, bodies }
// env: FLAT list of {name, kind, off, label, typ} — names are unique
// post-rename, so no scopes or shadowing. kind: "local"|"param" (frame
// slot at off), "func" (label), "global" (.bss cell at label),
// "closure" (slot holding a record), "box"/"capture" (shared cells).

def st_new() -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    { out: [], rodata: [], uid: 1, fuid: 0, loc: 1, env: [],
      slots: 0, self_label: "", end_label: "", fns: [], bodies: [] }
};

def emit(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, line: str) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    st.out += line;
    { out: st.out, rodata: st.rodata, uid: st.uid,
      fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots,
      self_label: st.self_label, end_label: st.end_label, fns: st.fns,
      bodies: st.bodies }
};

def next_uid(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }) -> { st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, uid: long } {
    let u = st.uid;
    st = { out: st.out, rodata: st.rodata, uid: st.uid + 1,
      fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots,
      self_label: st.self_label, end_label: st.end_label, fns: st.fns,
      bodies: st.bodies };
    { st: st, uid: u }
};

def next_loc(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }) -> { st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, lbl: str } {
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
        if (o == 92) {
            esc = "\\\\";
            0
        } else if (o == 34) {
            esc = "\\\"";
            0
        } else if (o == 10) {
            esc = "\\n";
            0
        } else if (o == 9) {
            esc = "\\t";
            0
        } else if (o < 32 || o > 126) {
            esc = "\\" + tostring(o / 64) + tostring((o / 8) % 8) + tostring(o % 8);
            0
        } else { 0; };
        if (len(esc) > 0) {
            out += s[run:i];
            out += esc;
            run = i + 1;
            0
        } else { 0; };
        i = i + 1;
        0
    };
    out += s[run:];
    join(out, "")
};

// ── flat environment ───────────────────────────────────────────────────

def env_find(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, name: str) -> { name: str, kind: str, off: long, label: str, typ: { k: str } } {
    // Miss marker: kind "none". Real entries have name/kind/off/label/typ
    // but NO k field — never test e.k.
    let env = st.env;
    let i = 0;
    let found = { name: "", kind: "none", off: 0, label: "", typ: { k: "tnone" } };
    while (i < len(env)) {
        let e = env[i];
        if (e.name == name) {
            found = e;
            0
        } else { 0; };
        i = i + 1;
        0
    };
    found
};

def env_define(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, name: str, kind: str, off: long, label: str, typ) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    st.env += { name: name, kind: kind, off: off, label: label, typ: typ };
    let env = st.env;
    { out: st.out, rodata: st.rodata, uid: st.uid,
      fuid: st.fuid, loc: st.loc, env: env, slots: st.slots,
      self_label: st.self_label, end_label: st.end_label, fns: st.fns,
      bodies: st.bodies }
};

// ── mini type inference (for print dispatch) ───────────────────────────
// The checker already validated everything; this mirrors it just enough to
// pick y_print_long / y_print_bool / y_print_cstr.

def infer(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { k: str } {
    let k = node.k;
    if (k == "num") {
        if (lit_is_float(node.v)) { { k: "tfloat" } } else { { k: "tlong" } }
    }
    else if (k == "str") { { k: "tstr" } }
    else if (k == "bstr") { { k: "tarr", of: { k: "tbyte" } } }
    else if (k == "bool") { { k: "tbool" } }
    else if (k == "void") { { k: "tvoid" } }
    else if (k == "id") {
        if (node.v == "self") { cur_fn_type(st) } else {
            let e = env_find(st, node.v);
            if (e.kind == "none") {
                if (node.v == "none") { normnode({ k: "topt", of: { k: "tunk" } }) } else { { k: "tunk" } }
            } else { e.typ }
        }
    } else if (k == "un") {
        if (node.op == "-") {
            // negating a byte is long arithmetic (types.y): -b leaves 0..255
            let ut = infer(st, node.e);
            if (ut.k == "tbyte") { { k: "tlong" } } else { ut }
        } else { { k: "tbool" } }
    } else if (k == "bin") {
        let op = node.op;
        if (op == "+" || op == "-" || op == "*" || op == "/" || op == "%" || op == "::") {
            let bl = infer(st, node.l);
            let br = infer(st, node.r);
            if (op == "+" && (bl.k == "tarr" || bl.k == "tarrfix")) {
                // array `+` builds a NEW heap array (types.y
                // typeof_arith_arr) -- the element type survives, except
                // that `[T] + [[T]]` prepends the left one as an element.
                if ((br.k == "tarr" || br.k == "tarrfix") && types.arr_plus_kind(bl, br) == "prepend") {
                    { k: "tarr", of: br.of }
                } else {
                    { k: "tarr", of: bl.of }
                }
            } else if (op == "+" && (br.k == "tarr" || br.k == "tarrfix")) {
                { k: "tarr", of: br.of }
            } else if (op == "::") {
                // cons: one element prepended to the right's array
                { k: "tarr", of: br.of }
            } else if (op == "+" && (bl.k == "tstr" || br.k == "tstr")) {
                { k: "tstr" }
            } else if (bl.k == "tfloat") {
                { k: "tfloat" }
            } else if (br.k == "tfloat") {
                { k: "tfloat" }
            } else {
                { k: "tlong" }
            }
        } else {
            { k: "tbool" }
        }
    } else if (k == "func") {
        normnode(func_type_in(st, node))
    } else if (k == "addr") {
        normnode({ k: "tptr", to: infer(st, node.e) })
    } else if (k == "arrrep") {
        normnode({ k: "tarrfix", of: infer(st, node.v), n: node.n })
    } else if (k == "array") {
        let elems = node.elems;
        if (len(elems) == 0) {
            normnode({ k: "tarr", of: { k: "tunk" } })
        } else {
            normnode({ k: "tarr", of: infer(st, elems[0]) })
        }
    } else if (k == "index") {
        // checker guarantees an array base (any expression); the element
        // type is the base type's `of`.
        let iarr = node.arr;
        let bt = infer(st, iarr);
        if (bt.k == "tarrfix" || bt.k == "tarr") {
            bt.of
        } else if (bt.k == "tmap") {
            // m[k] is always optional: V? for any V
            normnode({ k: "topt", of: bt.of })
        } else if (bt.k == "tstr") {
            { k: "tbyte" }
        } else {
            { k: "tunk" }
        }
    } else if (k == "slice") {
        // arr[lo:hi] keeps the element type but is always a heap [T].
        let ts = infer(st, node.arr);
        if (ts.k == "tarr") { { k: "tarr", of: ts.of } }
        else if (ts.k == "tarrfix") { { k: "tarr", of: ts.of } }
        else if (ts.k == "tstr") { { k: "tstr" } }
        else { { k: "tunk" } }
    } else if (k == "char") {
        { k: "tbyte" }
    } else if (k == "rectest") {
        { k: "tbool" }
    } else if (k == "narrow") {
        types.narrow_type(infer(st, node.e), node.typ)
    } else if (k == "sliceassign") {
        { k: "tvoid" }
    } else if (k == "deref") {
        let t = infer(st, node.e);
        if (t.k == "tptr") { t.to } else { { k: "tunk" } }
    } else if (k == "call") {
        infer_call(st, node)
    } else if (k == "if") {
        infer(st, node.then)
    } else if (k == "block") {
        infer_block(st, node)
    } else if (k == "decl") {
        infer_decl(st, node)
    } else if (k == "assign") {
        infer(st, node.v)
    } else if (k == "incdec") {
        infer(st, node.tgt)
    } else if (k == "opassign") {
        infer(st, node.tgt)
    } else if (k == "rec") {
        // record literal: field types from the values (checker validated).
        let melems = node.vals;
        let mkeys = node.keys;
        if (len(melems) == 0) {
            normnode({ k: "trec", fields: [] })
        } else {
            // `...` spread entries merge the source's fields (static
            // union: first appearance keeps the position, later wins the
            // value) -- the same rule as types.y's rec arm.
            let mfields = [];
            let mi = 0;
            while (mi < len(melems)) {
                let mf = infer(st, melems[mi]);
                // mk is read twice: the `...` test, then the merge.
                let mk = mkeys[mi];
                if (mk == "...") {
                    if (mf.k == "trec") {
                        let msfs = mf.fields;
                        let msi = 0;
                        while (msi < len(msfs)) {
                            let msf = msfs[msi];
                            mfields = types.field_merge(mfields, msf.name, msf.typ);
                            msi = msi + 1;
                        };
                        0
                    } else {
                        0
                    };
                    0
                } else {
                    mfields = types.field_merge(mfields, mk, mf);
                    0
                };
                mi = mi + 1;
            };
            normnode({ k: "trec", fields: mfields })
        }
    } else if (k == "map") {
        // map literal: {keys, vals} record at runtime; the static type is
        // tmap (quoted keys are strings; the values share one type).
        let glvals = node.vals;
        if (len(glvals) == 0) {
            normnode({ k: "tmap", key: { k: "tstr" }, of: { k: "tunk" } })
        } else {
            normnode({ k: "tmap", key: { k: "tstr" }, of: infer(st, glvals[0]) })
        }
    } else if (k == "dot") {
        // field read: static index into the trec (checker validated).
        let dobj = node.obj;
        let dt = infer(st, dobj);
        if (dt.k == "trec") {
            let found = false;
            let ftyp = { k: "tunk" };
            let dfs = dt.fields;
            let di = 0;
            while (di < len(dfs)) {
                let df = dfs[di];
                // NOTE: :str binding (see teq note in types.y): df flows
                // from bare values (tunk), so a direct `==` would compare
                // string POINTERS; annotated let forces content compare.
                let dfn: str = df.name;
                if (dfn == node.key) {
                    found = true;
                    ftyp = df.typ;
                    0
                } else { 0; };
                di = di + 1;
            };
            if (found) { ftyp } else { { k: "tunk" } }
        } else if (dt.k == "tmap") {
            // the map lowering reads its {keys, vals} shape directly
            if (node.key == "keys") { normnode({ k: "tarr", of: dt.key }) }
            else if (node.key == "vals") { normnode({ k: "tarr", of: dt.of }) }
            else { { k: "tunk" } }
        } else if (dt.k == "tarr" || dt.k == "tarrfix" || dt.k == "tstr") {
            // built-in properties (types.y typeof_prop; gen_prop)
            if (node.key == "length") { { k: "tlong" } } else { normnode({ k: "tptr", to: dt.of }) }
        } else {
            { k: "tunk" }
        }
    } else if (k == "store") {
        infer(st, node.v)
    } else if (k == "while") {
        { k: "tvoid" }
    } else if (k == "ret") {
        infer(st, node.e)
    } else {
        { k: "tunk" }
    }
};

def infer_call(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { k: str } {
    if (node.callee.k != "id") {
        // Calling an expression (immediately-invoked literal, fs[0](x), ...),
        // or `s.m(...)` with s a str: a string method (types.str_method).
        let ical = node.callee;
        if (ical.k == "dot" && infer(st, ical.obj).k == "tstr") {
            let ism = types.str_method(ical.key);
            ism.ret
        } else {
            let cft = infer(st, ical);
            if (cft.k == "tfunc") { cft.ret } else { { k: "tunk" } }
        }
    } else {
        let name = node.callee.v;
        if (name == "print") {
            { k: "tvoid" }
        } else if (name == "syscall") {
            { k: "tlong" }
        } else if (name == "len") {
            { k: "tlong" }
        } else if (name == "is_some") {
            { k: "tbool" }
        } else if (name == "unwrap") {
            // unwrap(x): payload type when x is statically an option.
            let uargs = node.args;
            if (len(uargs) != 1) { { k: "tunk" } } else {
                let ut = infer(st, uargs[0]);
                if (ut.k == "topt") { ut.of } else { { k: "tunk" } }
            }
        } else if (name == "some") {
            // some(x): option of x's type.
            let sargs = node.args;
            if (len(sargs) != 1) { { k: "topt", of: { k: "tunk" } } } else {
                { k: "topt", of: infer(st, sargs[0]) }
            }
        } else if (name == "trim" || name == "chr" || name == "join" || name == "tostring" || name == "typeof" || name == "#fmt") {
            { k: "tstr" }
        } else if (name == "read_file") {
            // str? (option): a missing file yields none at runtime
            // (callers none-check with `== none`, then unwrap).
            // Matches types.y (read_file -> str?).
            { k: "topt", of: { k: "tstr" } }
        } else if (name == "bytes") {
            { k: "tarr", of: { k: "tbyte" } }
        } else if (name == "from_bytes") {
            { k: "tstr" }
        } else if (name == "ptr_addr") {
            { k: "tlong" }
        } else if (name == "tonum" || name == "ord" || name == "byte_at" || name == "index_of" || name == "last_index_of") {
            { k: "tlong" }
        } else if (name == "clock_us" || name == "heap_used") {
            { k: "tlong" }
        } else if (name == "sleep") {
            { k: "tvoid" }
        } else if (name == "split" || name == "argv") {
            { k: "tarr", of: { k: "tstr" } }
        } else if (name == "range") {
            { k: "tarr", of: { k: "tlong" } }
        } else if (name == "write_file") {
            { k: "tbool" }
        } else if (name == "write_bytes") {
            { k: "tbool" }
        } else if (name == "push" || name == "prepend") {
            // both yield the array they take (the header never moves, and
            // the type is the array's either way)
            let gargs = node.args;
            infer(st, gargs[0])
        } else if (name == "puts" || name == "exit") {
            { k: "tvoid" }
        } else if (name == "eputs") {
            { k: "tvoid" }
        } else if (name == "self") {
            // the function's return type; one the checker could not infer
            // stays unknown here
            let sft = cur_fn_type(st);
            let sret = sft.ret;
            if (sret.k == "tnone") { { k: "tunk" } } else { sret }
        } else {
            let e = env_find(st, name);
            if (e.kind == "none") {
                { k: "tunk" }
            } else if (e.typ.k == "tfunc") {
                e.typ.ret
            } else {
                { k: "tunk" }
            }
        }
    }
};

def infer_block(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { k: str } {
    let stmts = node.stmts;
    if (len(stmts) == 0) {
        { k: "tvoid" }
    } else {
        infer(st, stmts[len(stmts) - 1])
    }
};

def infer_decl(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { k: str } {
    if (node.kind == "def") {
        { k: "tfunc", args: [], ret: { k: "tvoid" } }
    } else {
        // an annotated `let` takes the declared type; otherwise infer the
        // initializer's
        if (node.typ.k == "tnone") {
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

def uses_scan_block(stmts: [{ k: str }], out: { argv: bool }) -> { argv: bool } {
    let i = 0;
    while (i < len(stmts)) {
        out = uses_scan_node(stmts[i], out);
        i = i + 1;
    };
    out
};

def uses_scan_node(node, out: { argv: bool }) -> { argv: bool } {
    let k = node.k;
    if (k == "call") {
        // scan callee + args (argv() could nest inside an argument).
        // ncallee is read three times: the argv test, the id test, the walk.
        let ncallee = node.callee;
        let nargs = node.args;
        let found = out;
        if (ncallee.k == "id") {
            if (ncallee.v == "argv") {
                found = { argv: true };
                0
            } else { 0; };
            0
        } else { 0; };
        let o2 = uses_scan_node(ncallee, found);
        uses_scan_block(nargs, o2)
    } else if (k == "un") {
        uses_scan_node(node.e, out)
    } else if (k == "bin") {
        uses_scan_node(node.r, uses_scan_node(node.l, out))
    } else if (k == "addr" || k == "deref") {
        uses_scan_node(node.e, out)
    } else if (k == "if") {
        uses_scan_node(node.els, uses_scan_node(node.then, uses_scan_node(node.cond, out)))
    } else if (k == "while") {
        uses_scan_node(node.body, uses_scan_node(node.cond, out))
    } else if (k == "block") {
        uses_scan_block(node.stmts, out)
    } else if (k == "decl") {
        uses_scan_node(node.v, out)
    } else if (k == "func") {
        uses_scan_node(node.body, out)
    } else if (k == "assign") {
        uses_scan_node(node.v, out)
    } else if (k == "incdec") {
        uses_scan_node(node.tgt, out)
    } else if (k == "opassign") {
        uses_scan_node(node.v, uses_scan_node(node.tgt, out))
    } else if (k == "store") {
        uses_scan_node(node.v, uses_scan_node(node.p, out))
    } else if (k == "ret") {
        uses_scan_node(node.e, out)
    } else if (k == "array") {
        uses_scan_block(node.elems, out)
    } else if (k == "arrrep") {
        uses_scan_node(node.v, out)
    } else if (k == "rec") {
        uses_scan_block(node.vals, out)
    } else if (k == "map") {
        uses_scan_block(node.vals, out)
    } else if (k == "index") {
        uses_scan_node(node.idx, uses_scan_node(node.arr, out))
    } else if (k == "slice") {
        uses_scan_node(node.hi, uses_scan_node(node.lo, uses_scan_node(node.arr, out)))
    } else if (k == "idxassign") {
        uses_scan_node(node.v, uses_scan_node(node.idx, uses_scan_node(node.arr, out)))
    } else if (k == "dotassign") {
        uses_scan_node(node.v, uses_scan_node(node.obj, out))
    } else if (k == "foreach") {
        uses_scan_node(node.body, uses_scan_node(node.iter, out))
    } else if (k == "forrange") {
        uses_scan_node(node.body, uses_scan_node(node.hi, uses_scan_node(node.lo, out)))
    } else if (k == "for") {
        uses_scan_node(node.body, uses_scan_node(node.step, uses_scan_node(node.cond, uses_scan_node(node.init, out))))
    } else if (k == "sliceassign") {
        uses_scan_node(node.v, uses_scan_node(node.hi, uses_scan_node(node.lo, uses_scan_node(node.arr, out))))
    } else if (k == "rectest" || k == "narrow" || k == "matchend") {
        uses_scan_node(node.e, out)
    } else {
        out
    }
};

// ── def collection (incl. hoisting) ────────────────────────────────────
// Walk blocks/ifs/whiles/func-bodies; every named def and every let-bound
// anonymous def becomes a top-level function (they capture nothing — the
// checker proved it). Returns [{name, func}].

def collect_from_block(stmts: [{ k: str }], out: [{ name: str, func: { k: str } }]) -> [{ name: str, func: { k: str } }] {
    let i = 0;
    while (i < len(stmts)) {
        out = collect_from_node(stmts[i], out);
        i = i + 1;
    };
    out
};

def collect_from_node(node, out: [{ name: str, func: { k: str } }]) -> [{ name: str, func: { k: str } }] {
    let k = node.k;
    if (k == "decl") {
        if (node.kind == "def") {
            out += { name: node.name, func: node.v };
            out = collect_from_node(node.v, out);
            0
        } else {
            if (node.v.k == "func") {
                out += { name: node.name, func: node.v };
                0
            } else { 0; };
            out = collect_from_node(node.v, out);
            0
        }
    } else if (k == "func") {
        out = collect_from_block(node.body.stmts, out);
        0
    } else if (k == "if") {
        out = collect_from_node(node.then, out);
        if (node.has_else) {
            out = collect_from_node(node.els, out);
            0
        } else { 0; };
        0
    } else if (k == "while") {
        out = collect_from_node(node.body, out);
        0
    } else if (k == "for") {
        out = collect_from_node(node.init, out);
        out = collect_from_node(node.body, out);
        out = collect_from_node(node.step, out);
        0
    } else if (k == "foreach") {
        out = collect_from_node(node.body, out);
        0
    } else if (k == "forrange") {
        out = collect_from_node(node.body, out);
        0
    } else if (k == "block") {
        out = collect_from_block(node.stmts, out);
        0
    } else { 0; };
    out
};

// ── free variables (closure conversion) ────────────────────────────────
// A function that reads a name bound by an ENCLOSING function captures it.
// The capture list is computed purely syntactically (rename.y has already
// made every binding unique), so the creation site and the body emitter
// derive the same ordered list independently.

def name_in(xs: [str], n: str) -> bool {
    let i = 0;
    let found = false;
    while (i < len(xs)) {
        let x: str = xs[i];
        if (x == n) { found = true; 0; } else { 0; };
        i = i + 1;
    };
    found
};

// Builtins are resolved by name at the call site, never captured.
def is_intrinsic_name(n: str) -> bool {
    name_in(["print", "syscall", "len", "push", "some", "is_some", "unwrap",
             "trim", "ord", "byte_at", "chr", "tonum", "tostring", "index_of",
             "prepend",
             "last_index_of", "join", "split", "puts", "eputs", "clock_us",
             "sleep", "heap_used", "exit", "argv", "read_file", "write_file",
             "write_bytes", "range", "typeof", "bytes",
             "from_bytes", "ptr_addr", "self", "none", "#fmt"], n)
};

// Every identifier READ in a subtree (callee names included: calling a
// captured closure needs the name captured too). With `collect` false,
// only the reads inside nested functions count (see box_names).
def fv_walk(node, out: [str], collect: bool) -> [str] {
    let k = node.k;
    if (k == "id") {
        if (collect) { out += node.v; 0; } else { 0; };
        0
    } else if (k == "un") {
        out = fv_walk(node.e, out, collect);
        0
    } else if (k == "addr") {
        out = fv_walk(node.e, out, collect);
        0
    } else if (k == "deref") {
        out = fv_walk(node.e, out, collect);
        0
    } else if (k == "ret") {
        out = fv_walk(node.e, out, collect);
        0
    } else if (k == "bin") {
        out = fv_walk(node.l, out, collect);
        out = fv_walk(node.r, out, collect);
        0
    } else if (k == "array") {
        out = fv_walk_list(node.elems, out, collect);
        0
    } else if (k == "rec") {
        out = fv_walk_list(node.vals, out, collect);
        0
    } else if (k == "map") {
        out = fv_walk_list(node.vals, out, collect);
        0
    } else if (k == "arrrep") {
        out = fv_walk(node.v, out, collect);
        0
    } else if (k == "call") {
        out = fv_walk(node.callee, out, collect);
        out = fv_walk_list(node.args, out, collect);
        0
    } else if (k == "index") {
        out = fv_walk(node.arr, out, collect);
        out = fv_walk(node.idx, out, collect);
        0
    } else if (k == "slice") {
        out = fv_walk(node.arr, out, collect);
        out = fv_walk(node.lo, out, collect);
        out = fv_walk(node.hi, out, collect);
        0
    } else if (k == "idxassign") {
        out = fv_walk(node.arr, out, collect);
        out = fv_walk(node.idx, out, collect);
        out = fv_walk(node.v, out, collect);
        0
    } else if (k == "dot") {
        out = fv_walk(node.obj, out, collect);
        0
    } else if (k == "dotassign") {
        out = fv_walk(node.obj, out, collect);
        out = fv_walk(node.v, out, collect);
        0
    } else if (k == "store") {
        out = fv_walk(node.p, out, collect);
        out = fv_walk(node.v, out, collect);
        0
    } else if (k == "assign") {
        if (collect) { out += node.name; 0; } else { 0; };
        out = fv_walk(node.v, out, collect);
        0
    } else if (k == "incdec") {
        out = fv_walk(node.tgt, out, collect);
        0
    } else if (k == "opassign") {
        out = fv_walk(node.tgt, out, collect);
        out = fv_walk(node.v, out, collect);
        0
    } else if (k == "decl") {
        out = fv_walk(node.v, out, collect);
        0
    } else if (k == "if") {
        out = fv_walk(node.cond, out, collect);
        out = fv_walk(node.then, out, collect);
        if (node.has_else) {
            out = fv_walk(node.els, out, collect);
            0
        } else { 0; };
        0
    } else if (k == "while") {
        out = fv_walk(node.cond, out, collect);
        out = fv_walk(node.body, out, collect);
        0
    } else if (k == "for") {
        out = fv_walk(node.init, out, collect);
        out = fv_walk(node.cond, out, collect);
        out = fv_walk(node.step, out, collect);
        out = fv_walk(node.body, out, collect);
        0
    } else if (k == "foreach") {
        out = fv_walk(node.iter, out, collect);
        out = fv_walk(node.body, out, collect);
        0
    } else if (k == "forrange") {
        out = fv_walk(node.lo, out, collect);
        out = fv_walk(node.hi, out, collect);
        out = fv_walk(node.body, out, collect);
        0
    } else if (k == "block") {
        out = fv_walk_list(node.stmts, out, collect);
        0
    } else if (k == "func") {
        out = fv_walk(node.body, out, true);
        0
    } else if (k == "sliceassign") {
        out = fv_walk(node.arr, out, collect);
        out = fv_walk(node.lo, out, collect);
        out = fv_walk(node.hi, out, collect);
        out = fv_walk(node.v, out, collect);
        0
    } else if (k == "rectest" || k == "narrow" || k == "matchend") {
        out = fv_walk(node.e, out, collect);
        0
    } else { 0; };
    out
};

def fv_walk_list(nodes: [{ k: str }], out: [str], collect: bool) -> [str] {
    let i = 0;
    while (i < len(nodes)) {
        out = fv_walk(nodes[i], out, collect);
        i = i + 1;
    };
    out
};

def fv_ids(node, out: [str]) -> [str] {
    fv_walk(node, out, true)
};

// Every name BOUND anywhere in a subtree (params of nested funcs included:
// they are not free in the enclosing function either). Must traverse the
// same positions as fv_ids — a function literal can appear in any
// expression, e.g. `apply(def(x: long) -> long { ... }, 1)`, and its
// params must not leak out as captures of the enclosing function.
def fv_binds(node, out: [str]) -> [str] {
    let k = node.k;
    if (k == "decl") {
        out += node.name;
        out = fv_binds(node.v, out);
        0
    } else if (k == "func") {
        out = fv_bind_params(node.params, out);
        out = fv_binds(node.body, out);
        0
    } else if (k == "block") {
        out = fv_binds_list(node.stmts, out);
        0
    } else if (k == "if") {
        out = fv_binds(node.cond, out);
        out = fv_binds(node.then, out);
        if (node.has_else) {
            out = fv_binds(node.els, out);
            0
        } else { 0; };
        0
    } else if (k == "while") {
        out = fv_binds(node.cond, out);
        out = fv_binds(node.body, out);
        0
    } else if (k == "for") {
        out = fv_binds(node.init, out);
        out = fv_binds(node.cond, out);
        out = fv_binds(node.step, out);
        out = fv_binds(node.body, out);
        0
    } else if (k == "foreach") {
        out += node.name;
        out = fv_binds(node.iter, out);
        out = fv_binds(node.body, out);
        0
    } else if (k == "forrange") {
        out += node.name;
        out = fv_binds(node.lo, out);
        out = fv_binds(node.hi, out);
        out = fv_binds(node.body, out);
        0
    } else if (k == "ret") {
        out = fv_binds(node.e, out);
        0
    } else if (k == "un") {
        out = fv_binds(node.e, out);
        0
    } else if (k == "addr") {
        out = fv_binds(node.e, out);
        0
    } else if (k == "deref") {
        out = fv_binds(node.e, out);
        0
    } else if (k == "bin") {
        out = fv_binds(node.l, out);
        out = fv_binds(node.r, out);
        0
    } else if (k == "array") {
        out = fv_binds_list(node.elems, out);
        0
    } else if (k == "rec") {
        out = fv_binds_list(node.vals, out);
        0
    } else if (k == "map") {
        out = fv_binds_list(node.vals, out);
        0
    } else if (k == "arrrep") {
        out = fv_binds(node.v, out);
        0
    } else if (k == "call") {
        out = fv_binds(node.callee, out);
        out = fv_binds_list(node.args, out);
        0
    } else if (k == "index") {
        out = fv_binds(node.arr, out);
        out = fv_binds(node.idx, out);
        0
    } else if (k == "slice") {
        out = fv_binds(node.arr, out);
        out = fv_binds(node.lo, out);
        out = fv_binds(node.hi, out);
        0
    } else if (k == "idxassign") {
        out = fv_binds(node.arr, out);
        out = fv_binds(node.idx, out);
        out = fv_binds(node.v, out);
        0
    } else if (k == "dot") {
        out = fv_binds(node.obj, out);
        0
    } else if (k == "dotassign") {
        out = fv_binds(node.obj, out);
        out = fv_binds(node.v, out);
        0
    } else if (k == "store") {
        out = fv_binds(node.p, out);
        out = fv_binds(node.v, out);
        0
    } else if (k == "assign") {
        out = fv_binds(node.v, out);
        0
    } else if (k == "incdec") {
        out = fv_binds(node.tgt, out);
        0
    } else if (k == "opassign") {
        out = fv_binds(node.tgt, out);
        out = fv_binds(node.v, out);
        0
    } else if (k == "sliceassign") {
        out = fv_binds(node.arr, out);
        out = fv_binds(node.lo, out);
        out = fv_binds(node.hi, out);
        out = fv_binds(node.v, out);
        0
    } else { 0; };
    out
};

def fv_binds_list(nodes: [{ k: str }], out: [str]) -> [str] {
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
def fn_captures(func, fnnames: [str]) -> [str] {
    let bound = fv_bind_params(func.params, fv_binds(func.body, []));
    let reads = fv_ids(func.body, []);
    let caps: [str] = [];
    let i = 0;
    while (i < len(reads)) {
        let n: str = reads[i];
        if (name_in(bound, n)) { 0; }
        else if (name_in(fnnames, n)) { 0; }
        else if (is_intrinsic_name(n)) { 0; }
        else if (name_in(caps, n)) { 0; }
        else {
            caps += n;
            0
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

def fn_names_of(fns: [{ name: str, label: str, typ: { k: str } }]) -> [str] {
    let out: [str] = [];
    let i = 0;
    while (i < len(fns)) {
        let e = fns[i];
        out += e.name;
        i = i + 1;
    };
    out
};

// st.fns holds the hoisted defs and, after them, the globals (see
// emit_program); a global's label is its .bss cell.
def fns_kind(label: str) -> str {
    if (label[:3] == "yg_") { "global" } else { "func" }
};

// ── expression emission (value in %rax) ────────────────────────────────

def gen(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }],     bodies: [str] } {
    let k = node.k;
    if (k == "num") {
        gen_lit(st, node)
    } else if (k == "bool") {
        if (node.v == "true") {
            emit(st, "    mov $1, %rax")
        } else {
            emit(st, "    xor %eax, %eax")
        }
    } else if (k == "str") {
        gen_str_const(st, node.v)
    } else if (k == "bstr") {
        gen_bstr(st, node)
    } else if (k == "void") {
        emit(st, "    xor %eax, %eax")
    } else if (k == "id") {
        gen_id(st, node)
    } else if (k == "un") {
        gen_un(st, node)
    } else if (k == "addr") {
        gen_addr(st, node)
    } else if (k == "array") {
        gen_array(st, node)
    } else if (k == "deref") {
        let dw = ptr_width(infer(st, node.e));
        st = gen(st, node.e);
        if (dw == 1) { emit(st, "    movzbq (%rax), %rax") } else { emit(st, "    mov (%rax), %rax") }
    } else if (k == "bin") {
        gen_bin(st, node)
    } else if (k == "call") {
        gen_call(st, node)
    } else if (k == "if") {
        gen_if(st, node)
    } else if (k == "while") {
        gen_while(st, node)
    } else if (k == "for") {
        gen_for(st, node)
    } else if (k == "forrange") {
        gen_forrange(st, node)
    } else if (k == "foreach") {
        gen_foreach(st, node)
    } else if (k == "block") {
        gen_block(st, node)
    } else if (k == "decl") {
        gen_decl(st, node)
    } else if (k == "assign") {
        gen_assign(st, node)
    } else if (k == "incdec") {
        gen_incdec(st, node)
    } else if (k == "opassign") {
        gen_opassign(st, node)
    } else if (k == "index") {
        // maps scan their keys; strings read a byte; arrays index directly
        let kbt = infer(st, node.arr);
        if (kbt.k == "tmap") { gen_map_get(st, node) }
        else if (kbt.k == "tstr") { gen_byte_at(st, n_call2("byte_at", node.arr, node.idx, node.line, node.col)) }
        else { gen_index(st, node) }
    } else if (k == "slice") {
        let sbt = infer(st, node.arr);
        if (sbt.k == "tstr") { gen_str_slice(st, node) } else { gen_slice(st, node) }
    } else if (k == "char") {
        gen_lit(st, { k: "num", v: node.v, line: node.line, col: node.col })
    } else if (k == "rectest") {
        st = gen(st, node.e);
        gen_rectest_rax(st, types.type_names(node.typ))
    } else if (k == "narrow") {
        // the value itself; only its static type changes
        gen(st, node.e)
    } else if (k == "matchend") {
        // unreachable when the checker accepted the match
        st = emit(st, "    call y_match_fail");
        emit(st, "    xor %eax, %eax")
    } else if (k == "sliceassign") {
        gen_sliceassign(st, node)
    } else if (k == "idxassign") {
        let kbt = infer(st, node.arr);
        if (kbt.k == "tmap") { gen_map_set(st, node) } else { gen_idxassign(st, node) }
    } else if (k == "dotassign") {
        gen_dotassign(st, node)
    } else if (k == "dot") {
        gen_dot(st, node)
    } else if (k == "rec") {
        // record literal anywhere (let/call-arg): heap address in %rax.
        gen_reclit(st, node)
    } else if (k == "map") {
        // map literal: the {keys, vals} record, heap address in %rax.
        gen_maplit(st, node)
    } else if (k == "arrrep") {
        // [v; n] anywhere (let/assign/call-arg): heap address in %rax.
        gen_arrrep(st, node)
    } else if (k == "func") {
        // Anonymous function literal in expression position.
        gen_func_literal(st, node)
    } else if (k == "store") {
        gen_store(st, node)
    } else if (k == "ret") {
        st = gen_as(st, node.e, cur_fn_ret(st));
        emit(st, "    jmp " + st.end_label)
    } else {
        // Unreachable: the checker rejects everything else.
        emit(st, "    # INTERNAL: unhandled " + k + " (checker drift)")
    }
};

// A string literal in .rodata: header object [len, data..., NUL]; the value
// is the header's address. Used by `str` nodes and by every synthesised
// constant (typeof, function/record formatting).
// b"..." / b'...' -- a packed [byte] literal: desugar to a
// one-byte-per-element array literal and let gen_array_esz do the packing.
def gen_bstr(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let bv: str = node.v;
    let elems: [{k: str}] = [];
    let bi = 0;
    let bn = len(bv);
    while (bi < bn) {
        let bnum = { k: "num", v: tostring(ord(bv[bi:bi + 1])), line: node.line, col: node.col };
        elems += bnum;
        bi = bi + 1;
    };
    let barr = { k: "array", elems: elems, line: node.line, col: node.col };
    gen_array_esz(st, barr, 1, { k: "tnone" })
};

def gen_str_const(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, s: str) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let r = next_uid(st);
    st = r.st;
    let lbl = arch.arch_str_label(r.uid);
    // NOTE: push-chain over a let-bound [] (not a literal). The checker
    // rejects heterogeneous array literals ([str, long, str]); these three
    // parts are all str, so a literal would check too — the push-chain is
    // just the shape the other node-list builders use.
    let rod0 = [];
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

def gen_id(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
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
                0
            } else { 0; };
            if (soff >= 0) {
                emit(st, "    mov " + tostring(soff) + "(%rbp), %rax")
            } else {
                gen_make_closure(st, e.label, [])
            }
        } else if (e.kind == "global") {
            emit(st, "    mov " + e.label + "(%rip), %rax")
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
def gen_cap_ptr(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, name: str) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
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
def box_capture(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, name: str) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let e = env_find(st, name);
    if (e.kind == "box" || e.kind == "capture") {
        st
    } else {
        st = gen_id(st, { k: "id", v: name, line: 0, col: 0 });
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
def box_names(func) -> [str] {
    let reads = fv_walk(func.body, [], false);
    let out: [str] = [];
    let i = 0;
    while (i < len(reads)) {
        let n: str = reads[i];
        if (name_in(out, n)) { 0; } else {
            out += n;
            0
        };
        i = i + 1;
    };
    out
};

// Called right after `name` is bound: a captured name moves into its
// cell now (see box_capture). Scans back to this function's "frame".
def box_bound(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, name: str) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let env = st.env;
    let i = len(env) - 1;
    let want = false;
    let more = true;
    while (more && i >= 0) {
        let e = env[i];
        if (e.kind == "frame") {
            more = false;
            0
        } else if (e.kind == "boxmark" && e.label == name) {
            want = true;
            more = false;
            0
        } else { 0; };
        i = i - 1;
        0
    };
    if (want) { box_capture(st, name) } else { st }
};

def gen_make_closure(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, label: str, caps: [str]) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
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
def gen_range(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    st = gen_push_args(st, node.args);
    st = emit(st, "    call y_range");
    emit(st, "    add $8, %rsp")
};

// arr[lo:hi] — half-open, clamped, always a NEW heap array (the operands
// are untouched, like `+` on arrays). A missing bound means 0 / len.
def gen_slice(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let lo = node.lo;
    let hi = node.hi;
    let slesz = arr_elem_bytes(infer(st, node.arr));
    st = gen(st, node.arr);
    st = emit(st, "    push %rax");
    if (lo.k == "void") {
        st = emit(st, "    xor %eax, %eax");
        0
    } else {
        st = gen(st, lo);
        0
    };
    st = emit(st, "    push %rax");
    if (hi.k == "void") {
        // default: the array's length (the header keeps it in slot 0);
        // the array pointer sits one slot below the pushed lo.
        st = emit(st, "    mov 8(%rsp), %rax");
        st = emit(st, "    mov (%rax), %rax");
        0
    } else {
        st = gen(st, hi);
        0
    };
    st = emit(st, "    push %rax");
    st = emit(st, "    mov $" + tostring(slesz) + ", %rax");
    st = emit(st, "    push %rax");
    st = emit(st, "    call y_arr_slice");
    emit(st, "    add $32, %rsp")
};

// s[lo:hi] -- the substring, half-open and clamped like an array slice;
// a missing bound means 0 / len (the asm primitive y_str_slice).
def gen_str_slice(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let lo = node.lo;
    let hi = node.hi;
    st = gen(st, node.arr);
    st = emit(st, "    push %rax");
    if (lo.k == "void") {
        st = emit(st, "    xor %eax, %eax");
        0
    } else {
        st = gen(st, lo);
        0
    };
    st = emit(st, "    push %rax");
    if (hi.k == "void") {
        st = emit(st, "    mov 8(%rsp), %rax");
        st = emit(st, "    mov (%rax), %rax");
        0
    } else {
        st = gen(st, hi);
        0
    };
    st = emit(st, "    push %rax");
    st = emit(st, "    call y_str_slice");
    emit(st, "    add $24, %rsp")
};

// a[lo:hi] = src: y_arr_setslice{1,8} (rt.y) check the range and the
// length, then copy src's elements in. Evaluation order: a, lo, hi, src.
def gen_sliceassign(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let lo = node.lo;
    let hi = node.hi;
    let esz = arr_elem_bytes(infer(st, node.arr));
    st = gen(st, node.arr);
    st = emit(st, "    push %rax");
    if (lo.k == "void") {
        st = emit(st, "    xor %eax, %eax");
        0
    } else {
        st = gen(st, lo);
        0
    };
    st = emit(st, "    push %rax");
    if (hi.k == "void") {
        st = emit(st, "    mov 8(%rsp), %rax");
        st = emit(st, "    mov (%rax), %rax");
        0
    } else {
        st = gen(st, hi);
        0
    };
    st = emit(st, "    push %rax");
    st = gen(st, node.v);
    st = emit(st, "    push %rax");
    st = emit(st, "    call y_arr_setslice" + tostring(esz));
    st = emit(st, "    add $32, %rsp");
    emit(st, "    xor %eax, %eax")
};

// Record in %rax -> 1 when it has every field in names, else 0 (the
// record's own field table answers, through y_rec_has).
def gen_rectest_rax(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, names: [str]) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    if (len(names) == 0) {
        emit(st, "    mov $1, %rax")
    } else {
        let rfail = next_loc(st);
        st = rfail.st;
        let rdone = next_loc(st);
        st = rdone.st;
        st = emit(st, "    push %rax");
        let i = 0;
        while (i < len(names)) {
            st = emit(st, "    mov (%rsp), %rax");
            st = emit(st, "    push %rax");
            st = gen_str_const(st, names[i]);
            st = emit(st, "    push %rax");
            st = emit(st, "    call y_rec_has");
            st = emit(st, "    add $16, %rsp");
            st = emit(st, "    test %rax, %rax");
            st = emit(st, "    jz " + rfail.lbl);
            i = i + 1;
        };
        st = emit(st, "    add $8, %rsp");
        st = emit(st, "    mov $1, %rax");
        st = emit(st, "    jmp " + rdone.lbl);
        st = emit(st, rfail.lbl + ":");
        st = emit(st, "    add $8, %rsp");
        st = emit(st, "    xor %eax, %eax");
        emit(st, rdone.lbl + ":")
    }
};

// Union value in %rax -> its string form: the member it matches, tried
// from the one with the most fields down (the most specific shape wins).
def gen_union_str_rax(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, t) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let ms: [{k: str}] = t.ts;
    let order: [{k: str}] = [];
    let most = 0;
    let i = 0;
    while (i < len(ms)) {
        let n = len(types.type_names(ms[i]));
        if (n > most) { most = n; 0 } else { 0 };
        i = i + 1;
    };
    let want = most;
    while (want >= 0) {
        let j = 0;
        while (j < len(ms)) {
            if (len(types.type_names(ms[j])) == want) { order += ms[j]; 0 } else { 0 };
            j = j + 1;
        };
        want = want - 1;
    };
    let rdone = next_loc(st);
    st = rdone.st;
    st = emit(st, "    push %rax");
    let m = 0;
    while (m < len(order)) {
        let rnext = next_loc(st);
        st = rnext.st;
        let mt = order[m];
        st = emit(st, "    mov (%rsp), %rax");
        st = gen_rectest_rax(st, types.type_names(mt));
        st = emit(st, "    test %rax, %rax");
        st = emit(st, "    jz " + rnext.lbl);
        st = emit(st, "    pop %rax");
        st = gen_rec_str_rax(st, mt);
        st = emit(st, "    jmp " + rdone.lbl);
        st = emit(st, rnext.lbl + ":");
        m = m + 1;
    };
    st = emit(st, "    pop %rax");
    st = gen_str_const(st, "<union>");
    emit(st, rdone.lbl + ":")
};

// Indirect call through a closure value produced by `callee`.
def gen_indirect(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node, callee) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let args = node.args;
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

def gen_un(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let ut = infer(st, node.e);
    st = gen(st, node.e);
    if (node.op == "-") {
        if (ut.k == "tfloat") {
            // 0.0 - x (no SSE negate form emitted by this backend)
            st = emit(st, "    movq %rax, %xmm1");
            st = emit(st, "    xor %ecx, %ecx");
            st = emit(st, "    movq %rcx, %xmm0");
            st = emit(st, "    subsd %xmm1, %xmm0");
            emit(st, "    movq %xmm0, %rax")
        } else {
            emit(st, "    neg %rax")
        }
    } else {
        emit(st, "    xor $1, %rax")
    }
};

def gen_addr(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    // Checker guarantees plain ids, or id-rooted index into an array.
    if (node.e.k == "index") {
        gen_elem_addr(st, node.e)
    } else {
        let e = env_find(st, node.e.v);
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
def gen_elem_addr(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    // &a[i] — an element's address. The base is any array expression
    // (`&grid[0][i]` too) and runs once, before the index (the same order
    // gen_index and the VM use).
    let earr = node.arr;
    let bt = infer(st, earr);
    let eaesz = arr_elem_bytes(bt);
    let eascale = "8";
    if (eaesz == 1) { eascale = "1"; 0; } else { 0; };
    st = gen(st, earr);
    st = emit(st, "    push %rax");
    st = gen(st, node.idx);
    st = emit(st, "    mov %rax, %rcx");
    st = emit(st, "    pop %rax");
    st = emit(st, "    test %rcx, %rcx");
    st = emit(st, "    js y_oob");
    if (bt.k == "tarrfix") {
        st = emit(st, "    cmp $" + tostring(bt.n) + ", %rcx");
        st = emit(st, "    jge y_oob");
        0
    } else {
        st = emit(st, "    mov (%rax), %rdx");
        st = emit(st, "    cmp %rdx, %rcx");
        st = emit(st, "    jge y_oob");
        0
    };
    st = emit(st, "    mov 16(%rax), %rax");
    emit(st, "    lea (%rax,%rcx," + eascale + "), %rax")
};

def gen_bin(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let op = node.op;
    // Lazy &&/||: short-circuit jumps, not eager and/or (the right operand
    // must not run when the left already decides).
    if (op == "&&") {
        gen_logic(st, node, false)
    } else if (op == "||") {
        gen_logic(st, node, true)
    } else {
        gen_bin_rest(st, node)
    }
};

// Short-circuit logic: value is 0/1; the right operand only evaluates when
// the left operand does not already decide the result.
//   a && b : test a -> jz F; test b -> jz F; 1; jmp E; F: 0; E:
//   a || b : test a -> jnz T; test b -> jnz T; 0; jmp E; T: 1; E:
def gen_logic(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node, is_or: bool) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
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
        0
    } else { 0; };
    if (is_or) {
        0
    } else {
        st = emit(st, "    jz " + rF.lbl);
        0
    };
    st = gen(st, node.r);
    st = emit(st, "    test %rax, %rax");
    if (is_or) {
        st = emit(st, "    jnz " + rT.lbl);
        0
    } else { 0; };
    if (is_or) {
        0
    } else {
        st = emit(st, "    jz " + rF.lbl);
        0
    };
    if (is_or) {
        0
    } else {
        st = emit(st, "    mov $1, %rax");
        st = emit(st, "    jmp " + rE.lbl);
        0
    };
    if (is_or) {
        st = emit(st, "    xor %eax, %eax");
        st = emit(st, "    jmp " + rE.lbl);
        st = emit(st, rT.lbl + ":");
        st = emit(st, "    mov $1, %rax");
        0
    } else { 0; };
    if (is_or) {
        0
    } else {
        st = emit(st, rF.lbl + ":");
        st = emit(st, "    xor %eax, %eax");
        0
    };
    st = emit(st, rE.lbl + ":")
};

// AUTO-STRINGIFY `+`: when a string meets a non-string, stringify the other
// side (y_long_tostr / y_bool_tostr) and concatenate — the same semantics
// types.y's typeof_arith gives. tstr+tstr is a plain concat; tstr+tunk falls
// back to the raw pointer concat (the old behavior) since the runtime type
// is unknown statically.
def gen_cat(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node, lt: { k: str }, rt: { k: str }) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    // NOTE: y_long_tostr / y_bool_tostr take ONE STACK ARG (push; call;
    // add $8) — gen_tostring's pattern. y_str_cat takes two stack args.
    if (lt.k == "tarr" || lt.k == "tarrfix" || rt.k == "tarr" || rt.k == "tarrfix") {
        return gen_cat_arr(st, node, lt, rt);
    };
    if (lt.k == "tstr") {
        if (rt.k == "tstr") {
            st = gen_push_args(st, [node.l, node.r]);
            st = emit(st, "    call y_str_cat");
            st = emit(st, "    add $16, %rsp")
        } else if (rt.k == "tlong") {
            st = gen(st, node.l);
            st = emit(st, "    push %rax");
            st = gen(st, node.r);
            st = emit(st, "    push %rax");
            st = emit(st, "    call y_long_tostr");
            st = emit(st, "    add $8, %rsp");
            st = emit(st, "    push %rax");
            st = emit(st, "    call y_str_cat");
            st = emit(st, "    add $16, %rsp")
        } else if (rt.k == "tbool") {
            st = gen(st, node.l);
            st = emit(st, "    push %rax");
            st = gen(st, node.r);
            st = emit(st, "    push %rax");
            st = emit(st, "    call y_bool_tostr");
            st = emit(st, "    add $8, %rsp");
            st = emit(st, "    push %rax");
            st = emit(st, "    call y_str_cat");
            st = emit(st, "    add $16, %rsp")
        } else if (rt.k == "tfloat") {
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
        0
    } else { 0; };
    if (!(lt.k == "tstr")) {
        if (lt.k == "tlong") {
            st = gen(st, node.l);
            st = emit(st, "    push %rax");
            st = emit(st, "    call y_long_tostr");
            st = emit(st, "    add $8, %rsp");
            st = emit(st, "    push %rax");
            st = gen(st, node.r);
            st = emit(st, "    push %rax");
            st = emit(st, "    call y_str_cat");
            st = emit(st, "    add $16, %rsp")
        } else if (lt.k == "tbool") {
            st = gen(st, node.l);
            st = emit(st, "    push %rax");
            st = emit(st, "    call y_bool_tostr");
            st = emit(st, "    add $8, %rsp");
            st = emit(st, "    push %rax");
            st = gen(st, node.r);
            st = emit(st, "    push %rax");
            st = emit(st, "    call y_str_cat");
            st = emit(st, "    add $16, %rsp")
        } else if (lt.k == "tfloat") {
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
        0
    } else { 0; };
    st
};

// Float arithmetic and comparison. Operands arrive in %rax as raw bits;
// a long operand is widened with cvtsi2sd first (the only coercion).
def gen_float_bin(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node, lt: { k: str }, rt: { k: str }) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let op = node.op;
    st = gen(st, node.l);
    if (lt.k == "tfloat") { 0; } else {
        st = emit(st, "    cvtsi2sd %rax, %xmm0");
        st = emit(st, "    movq %xmm0, %rax");
        0
    };
    st = emit(st, "    push %rax");
    st = gen(st, node.r);
    if (rt.k == "tfloat") { 0; } else {
        st = emit(st, "    cvtsi2sd %rax, %xmm0");
        st = emit(st, "    movq %xmm0, %rax");
        0
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
    } else {
        // Comparisons: ucomisd sets CF/ZF, so the UNSIGNED conditions are
        // the right ones (a/ae/b/be), not the signed g/ge/l/le.
        st = emit(st, "    ucomisd %xmm1, %xmm0");
        if (op == "<") {
            st = emit(st, "    setb %al");
            0
        } else if (op == "<=") {
            st = emit(st, "    setbe %al");
            0
        } else if (op == ">") {
            st = emit(st, "    seta %al");
            0
        } else if (op == ">=") {
            st = emit(st, "    setae %al");
            0
        } else if (op == "==") {
            st = emit(st, "    sete %al");
            0
        } else {
            st = emit(st, "    setne %al");
            0
        };
        emit(st, "    movzbq %al, %rax")
    }
};

def gen_str_cmp(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node, op: str) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    st = gen_push_args(st, [node.l, node.r]);
    st = emit(st, "    call y_str_cmp");
    st = emit(st, "    add $16, %rsp");
    st = emit(st, "    cmp $0, %rax");
    if (op == "<") {
        st = emit(st, "    setl %al");
        0
    } else if (op == ">") {
        st = emit(st, "    setg %al");
        0
    } else if (op == "<=") {
        st = emit(st, "    setle %al");
        0
    } else {
        st = emit(st, "    setge %al");
        0
    };
    emit(st, "    movzbq %al, %rax")
};

def gen_bin_rest(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let op = node.op;
    let lt = infer(st, node.l);
    let rt = infer(st, node.r);
    if (op == "+" && (lt.k == "tstr" || rt.k == "tstr")) {
        gen_cat(st, node, lt, rt)
    } else if (op == "+" && (lt.k == "tarr" || rt.k == "tarr" || lt.k == "tarrfix" || rt.k == "tarrfix")) {
        // array `+` is the copy-concat form (gen_cat splits off the array
        // case first), not numeric add on the header pointers.
        gen_cat(st, node, lt, rt)
    } else if (op == "::") {
        gen_cons(st, node)
    } else if (lt.k == "tfloat" || rt.k == "tfloat") {
        gen_float_bin(st, node, lt, rt)
    } else if ((op == "==" || op == "!=") && (lt.k == "tstr" || rt.k == "tstr")) {
        st = gen_push_args(st, [node.l, node.r]);
        st = emit(st, "    call y_str_eq");
        st = emit(st, "    add $16, %rsp");
        if (op == "!=") {
            emit(st, "    xor $1, %rax")
        } else {
            st
        }
    } else if ((op == "<" || op == ">" || op == "<=" || op == ">=") && lt.k == "tstr") {
        // Lexicographic ordering: y_str_cmp returns the SIGN, so the normal
        // signed setcc forms work on its result against 0.
        gen_str_cmp(st, node, op)
    } else if ((op == "==" || op == "!=") && (lt.k == "tarr" || rt.k == "tarr")) {
        // Arrays compare STRUCTURALLY (length then elements), matching
        // yv.c's yv_eq for Y_ARR — `arr == []` is an emptiness test, not a
        // pointer comparison. String elements compare by value.
        let elt = { k: "tunk" };
        if (lt.k == "tarr") { elt = lt.of; 0; } else { 0; };
        if (elt.k == "tunk") {
            if (rt.k == "tarr") { elt = rt.of; 0; } else { 0; };
            0
        } else { 0; };
        st = gen_push_args(st, [node.l, node.r]);
        if (elt.k == "tstr") {
            st = emit(st, "    call y_arr_eq_str");
            st = emit(st, "    add $16, %rsp");
            0
        } else {
            st = emit(st, "    mov $" + tostring(elem_bytes(elt)) + ", %rax");
            st = emit(st, "    push %rax");
            st = emit(st, "    call y_arr_eq");
            st = emit(st, "    add $24, %rsp");
            0
        };
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
    }
    // No &&/|| arms here: gen_bin routes those to gen_logic (lazy jumps)
    // BEFORE calling this, so an eager and/or would be dead code.
    }
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

def gen_push_args(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, args: [{ k: str }]) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
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
def gen_push_args_as(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, args: [{ k: str }], ptypes: [{ k: str }]) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let i = 0;
    while (i < len(args)) {
        if (i < len(ptypes)) {
            st = gen_as(st, args[i], ptypes[i]);
            0
        } else {
            st = gen(st, args[i]);
            0
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
def gen_conv(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, got, want) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let gk: str = got.k;
    let wk: str = want.k;
    if (wk == "tfloat" && (gk == "tlong" || gk == "tbyte")) {
        st = emit(st, "    cvtsi2sd %rax, %xmm0");
        emit(st, "    movq %xmm0, %rax")
    } else if (wk == "tbyte" && gk == "tlong") {
        emit(st, "    movzbq %al, %rax")
    } else {
        st
    }
};

// gen, then gen_conv to `want`: every place a value is stored under a
// declared type (variable, parameter, return value, element, field,
// pointee) goes through here.
def gen_as(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node, want) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    st = gen(st, node);
    let wk: str = want.k;
    if (wk == "tfloat" || wk == "tbyte") {
        gen_conv(st, infer(st, node), want)
    } else {
        st
    }
};

// The type of the function being emitted: emit_one_fn records it as a
// nameless "fnty" entry (declared parameter types; the return type as
// declared or as the checker inferred it, tnone when it could not --
// see types.y set_inferred_ret). infer_fn_ret's scope has none.
def cur_fn_type(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }) -> { k: str } {
    let env = st.env;
    let i = len(env) - 1;
    let ft: { k: str } = { k: "tfunc", args: [], ret: { k: "tunk" } };
    let looking = true;
    while (looking && i >= 0) {
        let e = env[i];
        if (e.kind == "fnty") {
            ft = e.typ;
            looking = false;
            0
        } else { 0; };
        i = i - 1;
    };
    ft
};

def cur_fn_ret(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }) -> { k: str } {
    let ft = cur_fn_type(st);
    ft.ret
};

// Parameter types of a function type (none for anything else).
def fn_args_of(t) -> [{ k: str }] {
    let none: [{ k: str }] = [];
    if (t.k == "tfunc") { t.args } else { none }
};

// Element type of an array type (tnone for anything else).
def arr_elem_type(t) -> { k: str } {
    if (t.k == "tarr") { t.of }
    else if (t.k == "tarrfix") { t.of }
    else { { k: "tnone" } }
};

// The element type a store converts to: none for a packed [byte] (esz 1),
// whose movb store truncates by itself.
def store_elem_type(t, esz: long) -> { k: str } {
    if (esz == 1) { { k: "tnone" } } else { arr_elem_type(t) }
};

// Call a one-argument runtime helper. The argument is in %rax and goes on
// the stack — the Y convention every helper written in Y (std/rt.y) and
// every asm helper shares; the caller cleans up. (Runtime helpers used to
// take it in %rdi, which only hand-written asm could honour.)
def gen_helper1(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, label: str) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    st = emit(st, "    push %rax");
    st = emit(st, "    call " + label);
    emit(st, "    add $8, %rsp")
};

def gen_call(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let callee = node.callee;
    if (callee.k != "id") {
        if (callee.k == "dot" && infer(st, callee.obj).k == "tstr") {
            gen_method(st, node)
        } else {
            // Calling the result of an expression (e.g. `fs[0](x)`): it is a
            // closure value, so go through its code pointer.
            gen_indirect(st, node, callee)
        }
    } else {
        let name = callee.v;
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
        } else if (name == "some") {
            gen_some(st, node)
        } else if (name == "is_some") {
            gen_is_some(st, node)
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
        } else if (name == "sleep") {
            gen_sleep(st, node)
        } else if (name == "heap_used") {
            gen_heap_used(st, node)
        } else if (name == "exit") {
            gen_exit(st, node)
        } else if (name == "argv") {
            gen_argv(st, node)
        } else if (name == "read_file") {
            gen_read_file(st, node)
        } else if (name == "bytes") {
            st = gen_push_args(st, node.args);
            st = emit(st, "    call y_str_to_bytes");
            emit(st, "    add $8, %rsp")
        } else if (name == "from_bytes") {
            st = gen_push_args(st, node.args);
            st = emit(st, "    call y_bytes_to_str");
            emit(st, "    add $8, %rsp")
        } else if (name == "ptr_addr") {
            // A pointer IS its numeric value at run time: nothing to emit
            // beyond evaluating the operand. This exists only so the type
            // system lets the value cross into long territory.
            let paargs = node.args;
            gen(st, paargs[0])
        } else if (name == "write_file") {
            gen_write_file(st, node)
        } else if (name == "write_bytes") {
            gen_write_bytes(st, node)
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
def gen_method(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let mcal = node.callee;
    let mobj = mcal.obj;
    let sm = types.str_method(mcal.key);
    let margs = node.args;
    let args: [{ k: str }] = [];
    if (!sm.last) { args += mobj; 0; };
    let i = 0;
    while (i < len(margs)) {
        args += margs[i];
        i = i + 1;
    };
    if (len(margs) < len(sm.params)) {
        args += n_str(sm.dflt, node.line, node.col);
        0
    };
    if (sm.last) { args += mobj; 0; };
    let fname = sm.fn;
    if (len(runtime_base(fname)) > 0) {
        st = gen_push_args(st, args);
        st = emit(st, "    call " + fname);
        emit(st, "    add $" + tostring(len(args) * 8) + ", %rsp")
    } else {
        gen_call(st, { k: "call", callee: { k: "id", v: fname, line: node.line, col: node.col }, args: args, line: node.line, col: node.col })
    }
};

def gen_print(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let args = node.args;
    let pa0 = args[0];
    let t = infer(st, pa0);
    if (t.k == "trec") {
        // Records are formatted field by field from their static shape.
        st = gen_rec_str(st, pa0, t);
        st = gen_helper1(st, "y_print_hstr");
        emit(st, "    xor %eax, %eax")
    } else if (t.k == "tfunc") {
        // A function value has no printable contents; show its signature
        // (`<function (params)->(ret)>`, types.y tdisp_fnval).
        st = gen(st, pa0);
        st = gen_str_const(st, "<function " + types.tdisp_fnval(t) + ">");
        st = gen_helper1(st, "y_print_hstr");
        emit(st, "    xor %eax, %eax")
    } else if (t.k == "tarr" || t.k == "tarrfix") {
        // Arrays print like tostring: "[e0, e1, ...]", or b'...' for
        // [byte] (Python-style byte strings).
        st = gen(st, pa0);
        if (t.of.k == "tbyte") {
            st = gen_helper1(st, "y_bytes_repr");
            0
        } else {
            st = gen_arr_tostr_rax(st, t.of);
            0
        };
        st = gen_helper1(st, "y_print_hstr");
        emit(st, "    xor %eax, %eax")
    } else if (t.k == "topt") {
        st = gen(st, pa0);
        st = gen_opt_str_rax(st, t);
        st = gen_helper1(st, "y_print_hstr");
        emit(st, "    xor %eax, %eax")
    } else if (t.k == "tmap") {
        // Maps format entry by entry: {"k": v, ...} (quoted keys).
        st = gen_map_repr(st, pa0, t);
        st = gen_helper1(st, "y_print_hstr");
        emit(st, "    xor %eax, %eax")
    } else if (t.k == "tunion") {
        st = gen(st, pa0);
        st = gen_union_str_rax(st, t);
        st = gen_helper1(st, "y_print_hstr");
        emit(st, "    xor %eax, %eax")
    } else {
        gen_print_scalar(st, pa0, t)
    }
};

def gen_print_scalar(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, arg, t) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    st = gen(st, arg);
    if (t.k == "tbool") {
        st = gen_helper1(st, "y_print_bool");
        emit(st, "    xor %eax, %eax")
    } else if (t.k == "tstr") {
        st = gen_helper1(st, "y_print_hstr");
        emit(st, "    xor %eax, %eax")
    } else if (t.k == "tfloat") {
        st = gen_helper1(st, "y_print_float");
        emit(st, "    xor %eax, %eax")
    } else {
        st = gen_helper1(st, "y_print_long");
        emit(st, "    xor %eax, %eax")
    }
};

// `typeof(e)` is resolved statically: the checker has already pinned e's
// type, so this is a plain string constant.
def gen_typeof(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let targs = node.args;
    gen_str_const(st, types.tdisp(infer(st, targs[0])))
};

// ── record formatting ──────────────────────────────────────────────────
// `{a: 1, b: "x"}` — the shape is static, so the walk is unrolled at
// compile time. Stack layout while building: [record][accumulator], the
// record pushed first (8(%rsp)), the accumulator on top (0(%rsp)).

// Option value in %rax (0 = none, else the box address): leave "none" or
// the payload's string form in %rax. Options are 0-or-box (NATIVE.md).
def gen_opt_str_rax(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, t) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let rdone = next_loc(st);
    st = rdone.st;
    let rnul = next_loc(st);
    st = rnul.st;
    st = emit(st, "    test %rax, %rax");
    st = emit(st, "    jz " + rnul.lbl);
    st = emit(st, "    mov (%rax), %rax");
    st = gen_val_tostr_rax(st, t.of);
    st = emit(st, "    jmp " + rdone.lbl);
    st = emit(st, rnul.lbl + ":");
    st = gen_str_const(st, "none");
    emit(st, rdone.lbl + ":")
};

def gen_rec_str(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, arg, t) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    st = gen(st, arg);
    gen_rec_str_rax(st, t)
};

// The record's address sits in %rax; leave "{a: 1, b: ...}" in %rax.
// Values are formatted from the static shape (the walk is unrolled at
// compile time). Stack layout while building: [record][accumulator], the
// record pushed first (8(%rsp)), the accumulator on top (0(%rsp)).
def gen_rec_str_rax(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, t) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    st = emit(st, "    push %rax");
    st = gen_str_const(st, "{");
    st = emit(st, "    push %rax");
    let fs = t.fields;
    let i = 0;
    while (i < len(fs)) {
        let f = fs[i];
        let sep = "";
        if (i > 0) { sep = ", "; 0; } else { 0; };
        st = gen_acc_cat_const(st, sep + f.name + ": ");
        st = gen_rec_field_str(st, i, f.typ);
        i = i + 1;
        0
    };
    st = gen_acc_cat_const(st, "}");
    st = emit(st, "    mov (%rsp), %rax");
    emit(st, "    add $16, %rsp")
};

// `x :: a` -- cons: a NEW array with x prepended as exactly ONE element
// (types.y typeof_cons keeps even array-typed elements whole).
def gen_cons(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let ln = node.line;
    let cl = node.col;
    let crt = infer(st, node.r);
    let cesz = arr_elem_bytes(crt);
    let one = { k: "array", elems: args1(node.l), line: ln, col: cl };
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
def gen_cat_conv(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node, lt: { k: str }) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let ln = node.line;
    let cl = node.col;
    let r = next_uid(st);
    st = r.st;
    let t1 = "y_t" + tostring(r.uid);
    let noelems: [{ k: str }] = [];
    let da = { k: "decl", kind: "let", typ: { k: "tnone" }, name: t1 + "l", v: node.l, line: ln, col: cl };
    let db = { k: "decl", kind: "let", typ: { k: "tnone" }, name: t1 + "r", v: node.r, line: ln, col: cl };
    let dc = { k: "decl", kind: "let", typ: { k: "tarr", of: lt.of }, name: t1 + "c", v: { k: "array", elems: noelems, line: ln, col: cl }, line: ln, col: cl };
    let pa = { k: "opassign", tgt: n_id(t1 + "c", ln, cl), op: "+", v: n_id(t1 + "l", ln, cl), line: ln, col: cl };
    let pb = { k: "opassign", tgt: n_id(t1 + "c", ln, cl), op: "+", v: n_id(t1 + "r", ln, cl), line: ln, col: cl };
    gen(st, block6(da, db, dc, pa, pb, n_id(t1 + "c", ln, cl), ln, cl))
};

// Array `+`: always a NEW array (arr + arr, arr + elem, elem + arr).
// y_arr_cat copies both sides; the one-element side is built with the
// ordinary array literal emitter, so `arr + v` evaluates v exactly once.
// Two array operands concatenate unless types.arr_plus_kind says one of
// them is an element of the other ([[T]] + [T], [T] + [[T]]).
def gen_cat_arr(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node, lt: { k: str }, rt: { k: str }) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let ln = node.line;
    let cl = node.col;
    let lk: str = lt.k;
    let rk: str = rt.k;
    let lisarr = lk == "tarr" || lk == "tarrfix";
    let risarr = rk == "tarr" || rk == "tarrfix";
    let how = "elem";
    if (lisarr && risarr) { how = types.arr_plus_kind(lt, rt); 0; };
    if (how == "cat" && !types.teq(lt.of, rt.of)) {
        return gen_cat_conv(st, node, lt);
    };
    let larr = lisarr && how != "prepend";
    let esz = 8;
    let ety = { k: "tnone" };
    if (larr) {
        esz = arr_elem_bytes(lt);
        ety = store_elem_type(lt, esz);
        0;
    } else {
        esz = arr_elem_bytes(rt);
        ety = store_elem_type(rt, esz);
        0;
    };
    let one = { k: "array", elems: args1(node.r), line: ln, col: cl };
    if (larr) {
        0
    } else {
        one = { k: "array", elems: args1(node.l), line: ln, col: cl };
        0
    };
    if (larr) {
        st = gen(st, node.l);
        st = emit(st, "    push %rax");
        if (how == "cat") {
            st = gen(st, node.r);
            0
        } else {
            st = gen_array_esz(st, one, esz, ety);
            0
        };
        0
    } else {
        st = gen_array_esz(st, one, esz, ety);
        st = emit(st, "    push %rax");
        st = gen(st, node.r);
        0
    };
    st = emit(st, "    push %rax");
    st = emit(st, "    mov $" + tostring(esz) + ", %rax");
    st = emit(st, "    push %rax");
    st = emit(st, "    call y_arr_cat");
    emit(st, "    add $24, %rsp")
};

// acc = acc + <constant>, with the layout above still in place.
def gen_acc_cat_const(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, s: str) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    st = emit(st, "    mov (%rsp), %rax");
    st = emit(st, "    push %rax");
    st = gen_str_const(st, s);
    st = emit(st, "    push %rax");
    st = emit(st, "    call y_str_cat");
    st = emit(st, "    add $16, %rsp");
    emit(st, "    mov %rax, (%rsp)")
};

// acc = acc + <field idx, rendered by its static type>.
def gen_rec_field_str(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, idx: long, ft) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let fk = ft.k;
    if (fk == "tstr") {
        st = emit(st, "    mov 8(%rsp), %rcx");
        st = emit(st, "    mov " + tostring(8 * idx) + "(%rcx), %rdx")
    } else if (fk == "tlong") {
        st = emit(st, "    mov 8(%rsp), %rcx");
        st = emit(st, "    mov " + tostring(8 * idx) + "(%rcx), %rax");
        st = emit(st, "    push %rax");
        st = emit(st, "    call y_long_tostr");
        st = emit(st, "    add $8, %rsp");
        st = emit(st, "    mov %rax, %rdx")
    } else if (fk == "tbool") {
        st = emit(st, "    mov 8(%rsp), %rcx");
        st = emit(st, "    mov " + tostring(8 * idx) + "(%rcx), %rax");
        st = emit(st, "    push %rax");
        st = emit(st, "    call y_bool_tostr");
        st = emit(st, "    add $8, %rsp");
        st = emit(st, "    mov %rax, %rdx")
    } else if (fk == "tfloat") {
        st = emit(st, "    mov 8(%rsp), %rcx");
        st = emit(st, "    mov " + tostring(8 * idx) + "(%rcx), %rax");
        st = emit(st, "    push %rax");
        st = emit(st, "    call y_float_tostr");
        st = emit(st, "    add $8, %rsp");
        st = emit(st, "    mov %rax, %rdx")
    } else if (fk == "tfunc") {
        st = gen_str_const(st, "<function " + types.tdisp_fnval(ft) + ">");
        st = emit(st, "    mov %rax, %rdx")
    } else {
        // Arrays, options, maps and records nested in a RECORD: printed as their
        // type name — only gen_val_tostr_rax (the value formatter) walks
        // them recursively.
        st = gen_str_const(st, "<" + types.tdisp(ft) + ">");
        st = emit(st, "    mov %rax, %rdx")
    };
    st = emit(st, "    mov (%rsp), %rax");
    st = emit(st, "    push %rax");
    st = emit(st, "    push %rdx");
    st = emit(st, "    call y_str_cat");
    st = emit(st, "    add $16, %rsp");
    emit(st, "    mov %rax, (%rsp)")
};

def gen_syscall(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let args = node.args;
    // args[0] is the number; rest are a1..a6. Push all, pop into regs.
    st = gen_push_args(st, args);
    let n = len(args) - 1;
    let i = n;
    while (i >= 1) {
        st = emit(st, "    pop " + syscall_reg(i - 1));
        // a str flows in as its header; the kernel wants the data bytes.
        let at = infer(st, args[i]);
        if (at.k == "tstr") {
            st = emit(st, "    add $8, " + syscall_reg(i - 1));
            0
        } else { 0; };
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
def capture_off(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }) -> long {
    let env = st.env;
    let i = 0;
    let res = -1;
    while (i < len(env)) {
        let e = env[i];
        if (e.kind == "capture") {
            res = e.off;
            0
        } else { 0; };
        i = i + 1;
    };
    res
};

def gen_direct(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node, name: str) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let label = "";
    let indirect = false;
    let dptypes: [{ k: str }] = [];
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
            0
        } else { 0; };
        if (soff >= 0) {
            st = emit(st, "    mov " + tostring(soff) + "(%rbp), %rax");
            st = emit(st, "    push %rax");
            0
        } else { 0; };
        st = gen_push_args_as(st, node.args, dptypes);
        st = emit(st, "    call " + label);
        let nbytes = len(node.args) * 8;
        if (soff >= 0) {
            nbytes = nbytes + 8;
            0
        } else { 0; };
        if (nbytes == 0) {
            st
        } else {
            emit(st, "    add $" + tostring(nbytes) + ", %rsp")
        }
    }
};

// ── control flow ───────────────────────────────────────────────────────

def gen_if(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let r1 = next_loc(st);
    st = r1.st;
    let r2 = next_loc(st);
    st = r2.st;
    st = gen(st, node.cond);
    st = emit(st, "    test %rax, %rax");
    st = emit(st, "    jz " + r1.lbl);
    st = gen(st, node.then);
    if (node.has_else) {
        st = emit(st, "    jmp " + r2.lbl);
        st = emit(st, r1.lbl + ":");
        st = gen(st, node.els);
        emit(st, r2.lbl + ":")
    } else {
        emit(st, r1.lbl + ":")
    }
};

def gen_while(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let r1 = next_loc(st);
    st = r1.st;
    let r2 = next_loc(st);
    st = r2.st;
    st = emit(st, r1.lbl + ":");
    st = gen(st, node.cond);
    st = emit(st, "    test %rax, %rax");
    st = emit(st, "    jz " + r2.lbl);
    st = gen(st, node.body);
    st = emit(st, "    jmp " + r1.lbl);
    st = emit(st, r2.lbl + ":");
    emit(st, "    xor %eax, %eax")
};

// ── counted loops ──────────────────────────────────────────────────────
// All three lower to the same shape as `while`: a head label, a test, the
// body, a step, and a jump back. The loop variable is a normal local slot,
// so nothing new is needed at runtime.

def gen_for(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    // for (init; cond; step) body
    st = gen(st, node.init);
    let r1 = next_loc(st);
    st = r1.st;
    let r2 = next_loc(st);
    st = r2.st;
    st = emit(st, r1.lbl + ":");
    st = gen(st, node.cond);
    st = emit(st, "    test %rax, %rax");
    st = emit(st, "    jz " + r2.lbl);
    st = gen(st, node.body);
    st = gen(st, node.step);
    st = emit(st, "    jmp " + r1.lbl);
    st = emit(st, r2.lbl + ":");
    emit(st, "    xor %eax, %eax")
};

def gen_forrange(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
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
    st = env_define(st, node.name, "local", voff, "", { k: "tlong" });
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
    st = gen(st, node.body);
    st = emit(st, "    mov " + tostring(voff) + "(%rbp), %rax");
    st = emit(st, "    inc %rax");
    st = emit(st, "    mov %rax, " + tostring(voff) + "(%rbp)");
    st = emit(st, "    jmp " + r1.lbl);
    st = emit(st, r2.lbl + ":");
    emit(st, "    xor %eax, %eax")
};

def gen_foreach(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    // foreach (x in arr) body. Slots: [x][arr][i]. The array is evaluated
    // once; `x` is refreshed from arr[i] at the top of every iteration.
    let voff = (st.slots + 1) * -8;
    let aoff = (st.slots + 2) * -8;
    let ioff = (st.slots + 3) * -8;
    st = { out: st.out, rodata: st.rodata, uid: st.uid,
      fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots + 3,
      self_label: st.self_label, end_label: st.end_label, fns: st.fns,
      bodies: st.bodies };
    let elt = infer(st, node.iter);
    let eltyp = { k: "tunk" };
    if (elt.k == "tarr") { eltyp = elt.of; 0; } else { 0; };
    if (elt.k == "tarrfix") { eltyp = elt.of; 0; } else { 0; };
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
    // i < len(arr) — the heap header keeps the length in slot 0.
    st = emit(st, "    mov " + tostring(aoff) + "(%rbp), %rdx");
    st = emit(st, "    mov (%rdx), %rcx");
    st = emit(st, "    mov " + tostring(ioff) + "(%rbp), %rax");
    st = emit(st, "    cmp %rcx, %rax");
    st = emit(st, "    jge " + r2.lbl);
    // x = arr[i]
    st = emit(st, elem_load(arr_elem_bytes(elt), "%rdx", "%rax", "%rcx"));
    st = emit(st, "    mov %rcx, " + tostring(voff) + "(%rbp)");
    st = box_bound(st, node.name);
    st = gen(st, node.body);
    st = emit(st, "    mov " + tostring(ioff) + "(%rbp), %rax");
    st = emit(st, "    inc %rax");
    st = emit(st, "    mov %rax, " + tostring(ioff) + "(%rbp)");
    st = emit(st, "    jmp " + r1.lbl);
    st = emit(st, r2.lbl + ":");
    emit(st, "    xor %eax, %eax")
};

// ── tail calls ─────────────────────────────────────────────────────────
// A self-call in tail position (the body's trailing value, a `return`'s
// value, an if-arm's trailing value) recycles the frame instead of
// growing the stack: every argument is evaluated into a fresh local
// first (arguments may read parameters the copy below overwrites), the
// locals are copied over the parameter slots, and the frame tears down
// into a `jmp` back to the prologue. Tail recursion is then constant
// space.

def is_self_call(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> bool {
    // `self(...)`, or a call naming the function being emitted (after
    // rename every def has a unique name, so the label decides).
    if (node.k == "call") {
        let cal = node.callee;
        if (cal.k == "id") {
            let cv: str = cal.v;
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

def gen_tail_call(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let targs = node.args;
    let n = len(targs);
    let tptypes = fn_args_of(cur_fn_type(st));
    // evaluate each argument into a fresh local
    let offs: [long] = [];
    let i = 0;
    while (i < n) {
        if (i < len(tptypes)) {
            st = gen_as(st, targs[i], tptypes[i]);
            0
        } else {
            st = gen(st, targs[i]);
            0
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

def gen_tail(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let k = node.k;
    if (k == "ret") {
        let e = node.e;
        if (is_self_call(st, e)) {
            gen_tail_call(st, e)
        } else {
            st = gen_as(st, e, cur_fn_ret(st));
            emit(st, "    jmp " + st.end_label)
        }
    } else if (k == "call") {
        if (is_self_call(st, node)) {
            gen_tail_call(st, node)
        } else {
            gen_as(st, node, cur_fn_ret(st))
        }
    } else if (k == "block") {
        let tl = node.stmts;
        let m = len(tl);
        // a trailing `;` (void) leaves the statement before it in tail
        // position: the block's value is void either way
        if (m > 1 && is_void_node(tl[m - 1])) { m = m - 1; 0 } else { 0 };
        let ti = 0;
        while (ti < m - 1) {
            st = gen(st, tl[ti]);
            ti = ti + 1;
        };
        if (m > 0) {
            let lastn = tl[m - 1];
            st = gen_tail(st, lastn);
            0
        } else {
            0
        };
        st
    } else if (k == "if") {
        st = gen(st, node.cond);
        st = emit(st, "    test %rax, %rax");
        let rl1 = next_loc(st);
        st = rl1.st;
        let lelse = rl1.lbl;
        let rl2 = next_loc(st);
        st = rl2.st;
        let lend = rl2.lbl;
        st = emit(st, "    jz " + lelse);
        st = gen_tail(st, node.then);
        if (node.has_else) {
            st = emit(st, "    jmp " + lend);
            st = emit(st, lelse + ":");
            st = gen_tail(st, node.els);
            emit(st, lend + ":")
        } else {
            st = emit(st, lelse + ":")
        }
    } else {
        gen_as(st, node, cur_fn_ret(st))
    }
};

def gen_block(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {    // No scope push: names are unique post-rename, blocks share the frame.
    let stmts = node.stmts;
    if (len(stmts) == 0) {
        emit(st, "    xor %eax, %eax")
    } else {
        // A trailing `;` (void) computes nothing: nothing to emit.
        let m = len(stmts);
        if (m > 1 && is_void_node(stmts[m - 1])) { m = m - 1; 0 } else { 0 };
        let i = 0;
        while (i < m) {
            st = gen(st, stmts[i]);
            i = i + 1;
        };
        st
    }
};

def is_void_node(n) -> bool {
    let k: str = n.k;
    k == "void"
};

// Position of `name` in a record literal's merged field list, or -1.
def mfield_idx(names: [str], name: str) -> long {
    let i = 0;
    let out = -1;
    while (i < len(names)) {
        let nm: str = names[i];
        if (nm == name) {
            out = i;
            0
        } else { 0; };
        i = i + 1;
    };
    out
};

// Record literal { k: v, ... }: heap-allocate a block for the values + the
// shape table, then store each value. The VALUE is the record address
// (8 bytes, first-class: locals, params, returns all just copy it). Field k
// lives at record+8k; the table pointer sits at record-8, which is what
// y_dot_lookup reads (`mov -8(%rbx), %r14`).
// (y_alloc(0) is fine — bump allocators return a valid, if empty, block;
// empty maps are rejected by the checker anyway.)
def gen_reclit(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let mvals = node.vals;
    let mkeys = node.keys;
    let nent = len(mvals);
    // Static merge for `...` spread entries (the types.y field_merge
    // rule): first appearance keeps the position, a later entry wins the
    // value. The value loop below stores into merged slots in entry
    // order, so a later store simply overwrites -- no dynamic shape.
    let names: [str] = [];
    let ni = 0;
    while (ni < nent) {
        let nk = mkeys[ni];
        if (nk == "...") {
            let srec = infer(st, mvals[ni]);
            if (srec.k == "trec") {
                let sfs = srec.fields;
                let si = 0;
                while (si < len(sfs)) {
                    let sf = sfs[si];
                    if (mfield_idx(names, sf.name) < 0) {
                        names += sf.name;
                        0
                    } else { 0; };
                    si = si + 1;
                };
                0
            } else { 0; };
            0
        } else {
            if (mfield_idx(names, nk) < 0) {
                names += nk;
                0
            } else { 0; };
            0
        };
        ni = ni + 1;
    };
    let n = len(names);
    // Shape tag for dynamic field reads (y_dot_lookup in arch_x64.y reads it):
    // every record carries its field table; field i lives
    // at tag_base+8+i*8 and the value (base+8) keeps today's offsets,
    // so statically-precise reads are bit-identical. Table label per
    // site (uid); table rows are decimal quads (both assemblers take
    // `.quad N`; no pointers, so no fixup-kind gaps).
    let ru = next_uid(st);
    st = ru.st;
    let tlbl = "ytd_" + tostring(ru.uid);
    let te = [];
    te += tlbl;
    te += "TABLE";
    te += "1498307412";
    te += tostring(n);
    let j = 0;
    while (j < n) {
        let nm: str = names[j];
        te += tostring(8 * j);
        let nl = len(nm);
        te += tostring(nl);
        let c = 0;
        while (c < nl) {
            let ch = nm[c:c + 1];
            let co = ord(ch);
            te += tostring(co);
            c = c + 1;
        };
        j = j + 1;
    };
    st.rodata += [te];
    let trod = st.rodata;
    st = { out: st.out, rodata: trod, uid: st.uid,
      fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots,
      self_label: st.self_label, end_label: st.end_label, fns: st.fns,
      bodies: st.bodies };
    st = emit(st, "    mov $" + tostring(8 * n + 16) + ", %rdi");
    st = emit(st, "    call y_alloc");
    st = emit(st, "    push %rax");
    st = emit(st, "    lea " + tlbl + "(%rip), %rax");
    st = emit(st, "    pop %rcx");
    st = emit(st, "    mov %rax, 0(%rcx)");
    st = emit(st, "    push %rcx");
    let i = 0;
    while (i < nent) {
        // mv is walked twice (gen, then infer), so bind it once.
        let mv = mvals[i];
        let mk = mkeys[i];
        st = gen(st, mv);
        st = emit(st, "    pop %rcx");
        if (mk == "...") {
            // Spread: the source ran ONCE (just above); copy its fields
            // into their merged slots. A later entry's store overwrites.
            st = emit(st, "    mov %rax, %rdx");
            let srec2 = infer(st, mv);
            if (srec2.k == "trec") {
                let sfs2 = srec2.fields;
                let sj = 0;
                while (sj < len(sfs2)) {
                    let sf2 = sfs2[sj];
                    let mi2 = mfield_idx(names, sf2.name);
                    // %rdx is the source's record VALUE (field 0 at +0);
                    // %rcx is the fresh record's ALLOC base (fields at +8).
                    st = emit(st, "    mov " + tostring(sj * 8) + "(%rdx), %rsi");
                    st = emit(st, "    mov %rsi, " + tostring(8 + mi2 * 8) + "(%rcx)");
                    sj = sj + 1;
                };
                0
            } else { 0; };
            0
        } else {
            let mi = mfield_idx(names, mk);
            st = emit(st, "    mov %rax, " + tostring(8 + mi * 8) + "(%rcx)");
            0
        };
        st = emit(st, "    push %rcx");
        i = i + 1;
    };
    st = emit(st, "    pop %rax");
    emit(st, "    add $8, %rax")
};

// An anonymous `def(...) {...}` used as a value: it has no entry in the
// hoisted table, so give it a fresh label, emit the body here (where the
// capture types are known) and hand back the closure record.
def gen_func_literal(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let caps = fn_captures(node, fn_names_of(st.fns));
    let captypes: [{ k: str }] = [];
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
def gen_closure_binding(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, name: str, func, caps: [str]) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let captypes: [{ k: str }] = [];
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

def gen_decl(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    if (node.kind == "def") {
        // A nested `def` that captures is a closure just like a let-bound
        // literal; a capture-free one stays hoisted (emitted by
        // emit_program, env pre-bound, calls go direct). Its own name is
        // no capture: the body reaches itself through its own record.
        let dex = fn_names_of(st.fns);
        dex += node.name;
        let dcaps = fn_captures(node.v, dex);
        if (len(dcaps) == 0) {
            st
        } else {
            gen_closure_binding(st, node.name, node.v, dcaps)
        }
    } else {
        if (node.v.k == "func") {
            // let-bound function. Capture-free ones stay pure labels (the
            // env already binds them, calls go direct). One that captures
            // becomes a closure record built HERE, where the captured
            // values are live, and the binding holds that record.
            let lex = fn_names_of(st.fns);
            lex += node.name;
            let caps = fn_captures(node.v, lex);
            if (len(caps) == 0) {
                st
            } else {
                gen_closure_binding(st, node.name, node.v, caps)
            }
        } else if (node.v.k == "arrrep") {
            // heap array: [v; n] allocates a header {len, cap, data}.
            // Reference value like every other array: the binding holds
            // the header address.
            let t = node.typ;
            if (t.k == "tnone") {
                t = infer(st, node.v);
            };
            let rsz = arr_elem_bytes(t);
            st = gen_arrrep_esz(st, node.v, rsz, store_elem_type(t, rsz));
            bind_decl(st, node.name, t)
        } else if (node.v.k == "array") {
            // Heap array literal. The DECLARED element type decides the
            // element width: `let b: [byte] = [104, 105]` packs, and the
            // literal's own elements only ever infer as long.
            let t = node.typ;
            if (t.k == "tnone") {
                t = infer(st, node.v);
            };
            let asz = arr_elem_bytes(t);
            st = gen_array_esz(st, node.v, asz, store_elem_type(t, asz));
            bind_decl(st, node.name, t)
        } else if (node.v.k == "rec") {
            // record literal: heap address (first-class value, plain slot).
            // An empty literal under a map annotation is the map itself
            // (the {keys, vals} shape the map ops expect).
            if (node.typ.k == "tmap" && len(node.v.keys) == 0) {
                st = gen_maplit(st, node.v)
            } else {
                st = gen(st, node.v)
            };
            let t = node.typ;
            if (t.k == "tnone") {
                t = infer(st, node.v);
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
            let t = node.typ;
            if (t.k == "tnone") {
                t = infer(st, node.v);
            };
            bind_decl(st, node.name, t)
        }
    }
};

// Bind a declared name to the value in %rax: a top-level variable stores
// to its global cell (see emit_program), any other takes a fresh slot.
def bind_decl(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, name: str, t) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let ge = env_find(st, name);
    if (ge.kind == "global") {
        st = emit(st, "    mov %rax, " + ge.label + "(%rip)");
        env_define(st, name, "global", 0, ge.label, t)
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

def gen_assign(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
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
def gen_fill(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, base: long, n: long) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
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
def gen_fill_heap(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, n: long, esz: long) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
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
def gen_arrrep(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    gen_arrrep_esz(st, node, elem_bytes(infer(st, node.v)), { k: "tnone" })
};

// Same, with the element width supplied by the declaration (`let b:
// [byte; 4] = [0; 4]` — the literal's own elements infer as long), and
// `ety` the element type the fill value converts to (store_elem_type).
def gen_arrrep_esz(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node, esz: long, ety) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
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
    if (o >= 48) {
        if (o <= 57) { v = o - 48; 0; } else { 0; };
        0
    } else { 0; };
    if (o >= 97) {
        if (o <= 102) { v = o - 87; 0; } else { 0; };
        0
    } else { 0; };
    if (o >= 65) {
        if (o <= 70) { v = o - 55; 0; } else { 0; };
        0
    } else { 0; };
    v
};

// A numeric literal denotes a float when it has a fraction or an exponent.
// Radix literals are checked first: 0xE1 and 0xbeef contain 'e'/'E'/'b'.
def lit_is_float(s: str) -> bool {
    let radix = false;
    if (len(s) > 2) {
        let p = s[:2];
        if (p == "0x") { radix = true; 0; } else { 0; };
        if (p == "0X") { radix = true; 0; } else { 0; };
        if (p == "0b") { radix = true; 0; } else { 0; };
        if (p == "0B") { radix = true; 0; } else { 0; };
        0
    } else { 0; };
    if (radix) { false } else {
        let f = false;
        if (index_of(s, ".") >= 0) { f = true; 0; } else { 0; };
        if (index_of(s, "e") >= 0) { f = true; 0; } else { 0; };
        if (index_of(s, "E") >= 0) { f = true; 0; } else { 0; };
        f
    }
};

def norm_num(s: str) -> str {
    let radix = 0;
    if (len(s) > 2) {
        let p = s[:2];
        if (p == "0x") { radix = 16; 0; } else { 0; };
        if (p == "0X") { radix = 16; 0; } else { 0; };
        if (p == "0b") { radix = 2; 0; } else { 0; };
        if (p == "0B") { radix = 2; 0; } else { 0; };
        0
    } else { 0; };
    if (radix == 0) {
        s
    } else {
        let v = 0;
        let i = 2;
        while (i < len(s)) {
            let c = s[i:i + 1];
            if (c == "_") { 0; } else {
                v = v * radix + hexval_ch(c);
                0
            };
            i = i + 1;
        };
        tostring(v)
    }
};

// Digits of a float literal with the dot and exponent removed
// (e.g. "3.25" -> 325, "1.5e-2" -> 15) and the matching net power of ten
// (-> -2 and -3). Building the double at runtime as mantissa * 10^n lets
// IEEE arithmetic do the rounding, which is exactly the value the literal
// denotes — no float parser needed in the compiler.
def flit_mant(s: str) -> long {
    let v = 0;
    let i = 0;
    let n = flit_ebase(s);
    while (i < n) {
        let c = s[i:i + 1];
        if (c == ".") { 0; } else {
            v = v * 10 + hexval_ch(c);
            0
        };
        i = i + 1;
    };
    v
};

// Index of the 'e'/'E' that starts the exponent, or len(s) when absent.
def flit_ebase(s: str) -> long {
    let e = index_of(s, "e");
    if (e < 0) { e = index_of(s, "E"); 0; } else { 0; };
    if (e < 0) { len(s) } else { e }
};

// Net power of ten: the explicit exponent minus the fraction digit count.
def flit_exp(s: str) -> long {
    let eb = flit_ebase(s);
    let dot = index_of(s, ".");
    let frac = 0;
    if (dot >= 0) { frac = eb - dot - 1; 0; } else { 0; };
    let ex = 0;
    if (eb < len(s)) {
        let i = eb + 1;
        let neg = false;
        let sc = s[i:i + 1];
        if (sc == "-") { neg = true; i = i + 1; 0; } else { 0; };
        if (sc == "+") { i = i + 1; 0; } else { 0; };
        while (i < len(s)) {
            ex = ex * 10 + hexval_ch(s[i:i + 1]);
            i = i + 1;
        };
        if (neg) { ex = 0 - ex; 0; } else { 0; };
        0
    } else { 0; };
    ex - frac
};



// 10^k for 0 <= k <= 18 (the largest power of ten a long holds exactly).
def pow10(k: long) -> long {
    let d = 1;
    let i = 0;
    while (i < k) {
        d = d * 10;
        i = i + 1;
    };
    d
};

def gen_lit(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    if (lit_is_float(node.v)) {
        // Float literal: mantissa scaled by 10^n, where n folds together the
        // fraction length and any explicit exponent. Floats live in %rax as
        // raw IEEE754 bits; only arithmetic and comparison use %xmm.
        st = emit(st, "    mov $" + tostring(flit_mant(node.v)) + ", %rax");
        st = emit(st, "    cvtsi2sd %rax, %xmm0");
        gen_scale10(st, flit_exp(node.v))
    } else {
        emit(st, "    mov $" + norm_num(node.v) + ", %rax")
    }
};

// %xmm0 *= 10^n (n may be negative). Applied in chunks of 18 so every
// factor fits a long exactly; |n| <= 18 is therefore one correctly-rounded
// operation, which is every literal anyone writes.
def gen_scale10(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, n: long) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let up = n > 0;
    let left = n;
    if (!(up)) { left = 0 - n; 0; } else { 0; };
    while (left > 0) {
        let chunk = left;
        if (chunk > 18) { chunk = 18; 0; } else { 0; };
        st = emit(st, "    mov $" + tostring(pow10(chunk)) + ", %rax");
        st = emit(st, "    cvtsi2sd %rax, %xmm1");
        if (up) {
            st = emit(st, "    mulsd %xmm1, %xmm0");
            0
        } else {
            st = emit(st, "    divsd %xmm1, %xmm0");
            0
        };
        left = left - chunk;
    };
    emit(st, "    movq %xmm0, %rax")
};

def gen_index(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
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
    if (bt.k == "tarrfix") {
        st = emit(st, "    cmp $" + tostring(bt.n) + ", %rcx");
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
// are heap addresses; field i lives at addr+8i (same layout the static
// gen_dot read uses), so the write is: value -> (rec + 8*idx). The object
// runs first, then the value. Reference semantics: a field write is
// observable through every binding (the C copy's value model shares records
// the same way).
def gen_dotassign(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let dobj = node.obj;
    let dkey = node.key;
    let dt = infer(st, dobj);
    let idx = rec_field_idx(dt, dkey);
    st = gen(st, dobj);
    st = emit(st, "    push %rax");
    st = gen_as(st, node.v, rec_field_type(dt, dkey));
    st = emit(st, "    pop %rdx");
    st = emit(st, "    mov %rax, " + tostring(8 * idx) + "(%rdx)")
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
def place_value_type(t) -> {k: str} {
    if (t.k == "tbyte") { t } else { { k: "tnone" } }
};

def n_num(v: str, line: long, col: long) -> {k: str} {
    { k: "num", v: v, line: line, col: col }
};

def n_id(v: str, line: long, col: long) -> {k: str} {
    { k: "id", v: v, line: line, col: col }
};

def args1(a) -> [{k: str}] {
    let out: [{k: str}] = [];
    out += a;
    out
};

def args2(a, b) -> [{k: str}] {
    let out: [{k: str}] = [];
    out += a;
    out += b;
    out
};

def n_call1(name: str, a0, line: long, col: long) -> {k: str} {
    { k: "call", callee: n_id(name, line, col), args: args1(a0), line: line, col: col }
};

def n_call2(name: str, a0, a1, line: long, col: long) -> {k: str} {
    { k: "call", callee: n_id(name, line, col), args: args2(a0, a1), line: line, col: col }
};

def block2(a, b, ln: long, cl: long) -> {k: str} {
    let st: [{k: str}] = [];
    st += a;
    st += b;
    { k: "block", stmts: st, line: ln, col: cl }
};

def block3(a, b, c, ln: long, cl: long) -> {k: str} {
    let st: [{k: str}] = [];
    st += a;
    st += b;
    st += c;
    { k: "block", stmts: st, line: ln, col: cl }
};

def block4(a, b, c, d, ln: long, cl: long) -> {k: str} {
    let st: [{k: str}] = [];
    st += a;
    st += b;
    st += c;
    st += d;
    { k: "block", stmts: st, line: ln, col: cl }
};

def block5(a, b, c, d, e, ln: long, cl: long) -> {k: str} {
    let st: [{k: str}] = [];
    st += a;
    st += b;
    st += c;
    st += d;
    st += e;
    { k: "block", stmts: st, line: ln, col: cl }
};

def block6(a, b, c, d, e, f, ln: long, cl: long) -> {k: str} {
    let st: [{k: str}] = [];
    st += a;
    st += b;
    st += c;
    st += d;
    st += e;
    st += f;
    { k: "block", stmts: st, line: ln, col: cl }
};

def gen_incdec(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let op = node.op;
    let binop = "+";
    if (op == "--") { binop = "-"; 0; } else { 0; };
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
    let bind = gen_place_bind(tgt, t1, ln, cl);
    let place = gen_place_read(tgt, t1, ln, cl);
    if (node.pre) {
        // ++x -> { bind; let v = x + 1; x = v; v }
        let nv = { k: "bin", op: binop, l: place, r: one, line: ln, col: cl };
        let d2 = { k: "decl", kind: "let", typ: place_value_type(infer(st, tgt)), name: t1 + "v", v: nv, line: ln, col: cl };
        let asg = gen_place_assign(tgt, n_id(t1 + "v", ln, cl), t1, ln, cl);
        gen(st, block4(bind, d2, asg, n_id(t1 + "v", ln, cl), ln, cl))
    } else {
        // x++ -> { bind; let v = x; x = v + 1; v }
        let d2 = { k: "decl", kind: "let", typ: { k: "tnone" }, name: t1 + "v", v: place, line: ln, col: cl };
        let nv = { k: "bin", op: binop, l: n_id(t1 + "v", ln, cl), r: one, line: ln, col: cl };
        let asg = gen_place_assign(tgt, nv, t1, ln, cl);
        gen(st, block4(bind, d2, asg, n_id(t1 + "v", ln, cl), ln, cl))
    }
};

// `x op= v`: arrays take the in-place forms (`+=` push/append, `*=`
// prepend), everything else
// the arithmetic desugar. Arrays are homogeneous by design, so `+=` on an
// array is either a same-typed element (push) or a same-typed array
// (append) — never a mix.
def gen_opassign(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let t = infer(st, node.tgt);
    if (t.k == "tarr" || t.k == "tarrfix") {
        gen_opassign_arr(st, node)
    } else {
        gen_opassign_arith(st, node)
    }
};

def gen_opassign_arith(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    // `x op= v` for numbers and strings -> `x = x op v`, with the target's
    // index/base evaluated once through a synthetic let.
    let tgt = node.tgt;
    let op = node.op;
    let ln = node.line;
    let cl = node.col;
    let r = next_uid(st);
    st = r.st;
    let t1 = "y_t" + tostring(r.uid);
    let bind = gen_place_bind(tgt, t1, ln, cl);
    let rd = gen_place_read(tgt, t1, ln, cl);
    let bin = { k: "bin", op: op, l: rd, r: node.v, line: ln, col: cl };
    let d2 = { k: "decl", kind: "let", typ: place_value_type(infer(st, tgt)), name: t1 + "v", v: bin, line: ln, col: cl };
    let asg = gen_place_assign(tgt, n_id(t1 + "v", ln, cl), t1, ln, cl);
    gen(st, block4(bind, d2, asg, n_id(t1 + "v", ln, cl), ln, cl))
};

// The place an opassign target names. `t1` is the synthetic name that
// captured the target's index (a[i]) or base (o.f) — an id target needs
// no capture (re-reading a variable has no side effects). Each target
// shape gets its own arm (single-call dispatch, see normnode note).
def place_read_id(tgt, t1: str, ln: long, cl: long) -> {k: str} {
    n_id(tgt.v, ln, cl)
};

// The base array node for an index place: a plain variable is used
// directly (re-reading it has no side effects); any other base expression
// was captured in `t1 + "a"` (see place_bind_idx), so the desugared forms
// read and write it through a plain variable and evaluate it exactly once.
def place_arr(tgt, t1: str, ln: long, cl: long) -> {k: str} {
    let ba = tgt.arr;
    if (ba.k == "id") { n_id(ba.v, ln, cl) } else { n_id(t1 + "a", ln, cl) }
};

def place_read_idx(tgt, t1: str, ln: long, cl: long) -> {k: str} {
    { k: "index", arr: place_arr(tgt, t1, ln, cl), idx: n_id(t1, ln, cl), line: ln, col: cl }
};

def place_read_dot(tgt, t1: str, ln: long, cl: long) -> {k: str} {
    { k: "dot", obj: n_id(t1, ln, cl), key: tgt.key, line: ln, col: cl }
};

def gen_place_read(tgt, t1: str, ln: long, cl: long) -> {k: str} {
    if (tgt.k == "id") { place_read_id(tgt, t1, ln, cl) }
    else if (tgt.k == "index") { place_read_idx(tgt, t1, ln, cl) }
    else { place_read_dot(tgt, t1, ln, cl) }
};

def place_asg_id(tgt, valnode, t1: str, ln: long, cl: long) -> {k: str} {
    { k: "assign", name: tgt.v, v: valnode, line: ln, col: cl }
};

def place_asg_idx(tgt, valnode, t1: str, ln: long, cl: long) -> {k: str} {
    { k: "idxassign", arr: place_arr(tgt, t1, ln, cl), idx: n_id(t1, ln, cl), v: valnode, line: ln, col: cl }
};

def place_asg_dot(tgt, valnode, t1: str, ln: long, cl: long) -> {k: str} {
    { k: "dotassign", obj: n_id(t1, ln, cl), key: tgt.key, v: valnode, line: ln, col: cl }
};

def gen_place_assign(tgt, valnode, t1: str, ln: long, cl: long) -> {k: str} {
    if (tgt.k == "id") { place_asg_id(tgt, valnode, t1, ln, cl) }
    else if (tgt.k == "index") { place_asg_idx(tgt, valnode, t1, ln, cl) }
    else { place_asg_dot(tgt, valnode, t1, ln, cl) }
};

def place_bind_id(tgt, t1: str, ln: long, cl: long) -> {k: str} {
    { k: "block", stmts: [], line: ln, col: cl }
};

def place_bind_idx_id(tgt, t1: str, ln: long, cl: long) -> {k: str} {
    { k: "decl", kind: "let", typ: { k: "tnone" }, name: t1, v: tgt.idx, line: ln, col: cl }
};

def place_bind_idx_nest(tgt, t1: str, ln: long, cl: long) -> {k: str} {
    // nested base (`grid[0][1]`, `x.y[i]`, `f()[i]`): capture it in
    // `t1 + "a"` as well, so the place evaluates it exactly once.
    let tba = { k: "decl", kind: "let", typ: { k: "tnone" }, name: t1 + "a", v: tgt.arr, line: ln, col: cl };
    let tib = { k: "decl", kind: "let", typ: { k: "tnone" }, name: t1, v: tgt.idx, line: ln, col: cl };
    block2(tba, tib, ln, cl)
};

def place_bind_idx(tgt, t1: str, ln: long, cl: long) -> {k: str} {
    let ba = tgt.arr;
    if (ba.k == "id") { place_bind_idx_id(tgt, t1, ln, cl) }
    else { place_bind_idx_nest(tgt, t1, ln, cl) }
};

def place_bind_dot(tgt, t1: str, ln: long, cl: long) -> {k: str} {
    { k: "decl", kind: "let", typ: { k: "tnone" }, name: t1, v: tgt.obj, line: ln, col: cl }
};

// The synthetic `let` that runs the target's index/base exactly once (a
// no-op statement for id targets).
def gen_place_bind(tgt, t1: str, ln: long, cl: long) -> {k: str} {
    if (tgt.k == "id") { place_bind_id(tgt, t1, ln, cl) }
    else if (tgt.k == "index") { place_bind_idx(tgt, t1, ln, cl) }
    else { place_bind_dot(tgt, t1, ln, cl) }
};

def gen_opassign_arr(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    // In-place array forms. `*=` prepends one element. `+=` pushes one
    // element — or, when the VALUE is an array of the same element type
    // (types.arr_plus_kind "cat"), appends its elements one by one (its
    // length is captured first, so `a += a` is safe); `[[T]] += [T]`
    // pushes the [T] whole. The checker enforces matching element types
    // (types.y opassign_check).
    let tgt = node.tgt;
    let op = node.op;
    let v = node.v;
    let ln = node.line;
    let cl = node.col;
    let r = next_uid(st);
    st = r.st;
    let t1 = "y_t" + tostring(r.uid);
    let tt = infer(st, tgt);
    let et = tt.of;
    let mode = "push";
    if (op == "*") {
        mode = "prepend";
        0
    } else {
        let vt = infer(st, v);
        if ((vt.k == "tarr" || vt.k == "tarrfix") && types.arr_plus_kind(tt, vt) == "cat") {
            mode = "append";
            0
        } else {
            0
        };
        0
    };
    if (mode == "append") {
        // { let tv = v; let ti = 0; let tn = len(tv);
        //   while (ti < tn) { place += tv[ti]; ti = ti + 1 }
        //   place }
        let tv = { k: "decl", kind: "let", typ: { k: "tnone" }, name: t1 + "v", v: v, line: ln, col: cl };
        let ti = { k: "decl", kind: "let", typ: { k: "tnone" }, name: t1 + "i", v: n_num("0", ln, cl), line: ln, col: cl };
        let tn = { k: "decl", kind: "let", typ: { k: "tnone" }, name: t1 + "n", v: n_call1("len", n_id(t1 + "v", ln, cl), ln, cl), line: ln, col: cl };
        let elem = { k: "index", arr: n_id(t1 + "v", ln, cl), idx: n_id(t1 + "i", ln, cl), line: ln, col: cl };
        let put = gen_place_assign(tgt, n_call2("push", gen_place_read(tgt, t1, ln, cl), elem, ln, cl), t1, ln, cl);
        let step = { k: "assign", name: t1 + "i", v: { k: "bin", op: "+", l: n_id(t1 + "i", ln, cl), r: n_num("1", ln, cl), line: ln, col: cl }, line: ln, col: cl };
        let loop = { k: "while", cond: { k: "bin", op: "<", l: n_id(t1 + "i", ln, cl), r: n_id(t1 + "n", ln, cl), line: ln, col: cl }, body: block2(put, step, ln, cl), line: ln, col: cl };
        gen(st, block6(gen_place_bind(tgt, t1, ln, cl), tv, ti, tn, loop, gen_place_read(tgt, t1, ln, cl), ln, cl))
    } else {
        let fname = "push";
        if (mode == "prepend") { fname = "prepend"; 0; } else { 0; };
        let call = n_call2(fname, gen_place_read(tgt, t1, ln, cl), v, ln, cl);
        gen(st, block3(gen_place_bind(tgt, t1, ln, cl), gen_place_assign(tgt, call, t1, ln, cl), gen_place_read(tgt, t1, ln, cl), ln, cl))
    }
};

def gen_idxassign(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    // Fixed arrays are heap headers now: one layout for both kinds.
    // Fixed uses the static bound n; heap uses the runtime len.
    // Reference semantics: `x[i] = v` writes through to the array every
    // binding shares — params included (the C copy's value model aliases
    // the same way). The base is any array expression and runs once, in
    // base/index/value order. No write-back to the base:
    // the header pointer never moves, so the store through it is already
    // visible through every binding.
    let garr = node.arr;
    let bt = infer(st, garr);
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
    if (bt.k == "tarrfix") {
        st = emit(st, "    cmp $" + tostring(bt.n) + ", %rcx");
        st = emit(st, "    jge y_oob");
        st = emit(st, "    mov %rdx, %r10");
        st = emit(st, "    mov %rax, %rdx");
        st = emit(st, elem_store_rdx(iaesz, "%r10", "%rcx"));
        st = emit(st, "    mov %r10, %rdx");
        0
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
        0
    };
    st
};

// ── value formatting ───────────────────────────────────────────────────
// A value of static type `t` sits in %rax; leave its string form in %rax.
// The walk is unrolled at compile time (the type is static), so nested
// arrays emit nested loops rather than needing a runtime type tag.

def gen_val_tostr_rax(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, t) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let tk = t.k;
    if (tk == "tstr") {
        st
    } else if (tk == "tbool") {
        st = emit(st, "    push %rax");
        st = emit(st, "    call y_bool_tostr");
        emit(st, "    add $8, %rsp")
    } else if (tk == "tfloat") {
        st = emit(st, "    push %rax");
        st = emit(st, "    call y_float_tostr");
        emit(st, "    add $8, %rsp")
    } else if (tk == "tarr") {
        if (t.of.k == "tbyte") {
            // [byte] stringifies Python-style: b'...' with escapes
            gen_helper1(st, "y_bytes_repr")
        } else {
            gen_arr_tostr_rax(st, t.of)
        }
    } else if (tk == "tarrfix") {
        if (t.of.k == "tbyte") {
            gen_helper1(st, "y_bytes_repr")
        } else {
            gen_arr_tostr_rax(st, t.of)
        }
    } else if (tk == "topt") {
        gen_opt_str_rax(st, t)
    } else if (tk == "trec") {
        gen_rec_str_rax(st, t)
    } else if (tk == "tunion") {
        gen_union_str_rax(st, t)
    } else {
        st = emit(st, "    push %rax");
        st = emit(st, "    call y_long_tostr");
        emit(st, "    add $8, %rsp")
    }
};

// Array header in %rax -> "[e0, e1, ...]" in %rax, the same form tostring()
// gives. Slots: [src][acc][i].
def gen_arr_tostr_rax(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, elty) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
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
    st = gen_val_tostr_rax(st, elty);
    st = emit(st, "    mov %rax, %rdx");
    st = emit(st, "    mov " + tostring(aoff) + "(%rbp), %rax");
    st = emit(st, "    push %rax");
    st = emit(st, "    push %rdx");
    st = emit(st, "    call y_str_cat");
    st = emit(st, "    add $16, %rsp");
    st = emit(st, "    mov %rax, " + tostring(aoff) + "(%rbp)");
    st = emit(st, "    mov " + tostring(ioff) + "(%rbp), %rax");
    st = emit(st, "    inc %rax");
    st = emit(st, "    mov %rax, " + tostring(ioff) + "(%rbp)");
    st = emit(st, "    jmp " + r1.lbl);
    st = emit(st, r2.lbl + ":");
    st = gen_acc_cat_slot(st, aoff, "]");
    emit(st, "    mov " + tostring(aoff) + "(%rbp), %rax")
};

// slot(%rbp) = slot(%rbp) + <constant>.
def gen_acc_cat_slot(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, off: long, s: str) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
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

def elem_bytes(t) -> long {
    if (t.k == "tbyte") { 1 } else { 8 }
};

def arr_elem_bytes(t) -> long {
    if (t.k == "tarr") { elem_bytes(t.of) }
    else if (t.k == "tarrfix") { elem_bytes(t.of) }
    else { 8 }
};

// Width of what a pointer of static type `t` addresses: a *byte points into
// a packed [byte] block (or at a byte local), so `*p` and `*p = v` move one
// byte; every other pointee is a full 8-byte slot.
def ptr_width(t) -> long {
    if (t.k == "tptr") { elem_bytes(t.to) } else { 8 }
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

// The array header is {len, cap, data} and NEVER moves: elements live in a
// separate block, so growth keeps every alias valid (that is what makes
// `arr += v` in-place). This is the block size for n elements.
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
def gen_dot(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    // dobj is read twice (infer, then gen).
    let dobj = node.obj;
    let dkey = node.key;
    let t = infer(st, dobj);
    let tk = t.k;
    if (tk == "tarr" || tk == "tarrfix" || tk == "tstr") {
        gen_prop(st, dobj, dkey, node.line, node.col)
    } else {
        gen_dot_rec(st, dobj, dkey, t)
    }
};

// Built-in properties (types.y typeof_prop): `.length` is len(x); `.ptr`
// is the array header's data word — the element block's address.
def gen_prop(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, obj, key: str, line: long, col: long) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    if (key == "length") {
        gen_len(st, n_call1("len", obj, line, col))
    } else {
        st = gen(st, obj);
        emit(st, "    mov 16(%rax), %rax")
    }
};

// Record field read; `t` is the record's static type.
def gen_dot_rec(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, dobj, dkey: str, t) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let idx = rec_field_idx(t, dkey);
    if (idx < 0) {
        // unknown static shape ({k}-holes, bare params): dynamic field
        // lookup. The record carries its shape table (see gen_reclit note);
        // the key goes through the regular string rodata channel.
        let r = next_uid(st);
        st = r.st;
        let klbl = arch.arch_str_label(r.uid);
        let krod = [];
        krod += klbl;
        krod += tostring(len(dkey));
        krod += esc_asm(dkey);
        st.rodata += [krod];
        let rod = st.rodata;
        st = { out: st.out, rodata: rod, uid: st.uid,
          fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots,
          self_label: st.self_label, end_label: st.end_label, fns: st.fns,
          bodies: st.bodies };
        st = gen(st, dobj);
        st = emit(st, "    push %rax");
        st = emit(st, "    lea " + klbl + "(%rip), %rax");
        st = emit(st, "    push %rax");
        st = emit(st, "    call y_dot_lookup");
        st = emit(st, "    add $16, %rsp");
        0
    } else {
        st = gen(st, dobj);
        st = emit(st, "    mov " + tostring(idx * 8) + "(%rax), %rax");
        0
    };
    st
};

// Static field index of `key` in trec type t (-1 = checker drift;
// the checker rejects unknown fields, so this is unreachable).
def rec_field_idx(t, key: str) -> long {
    let idx = -1;
    if (t.k == "trec") {
        let fs = t.fields;
        let i = 0;
        while (i < len(fs)) {
            // f is read twice: the name compare, then the field's type.
            let f = fs[i];
            if (f.name == key) {
                idx = i;
                0
            } else { 0; };
            i = i + 1;
        };
    } else if (t.k == "tmap") {
        // a map is lowered to the fixed {keys, vals} record (see "maps")
        if (key == "keys") { idx = 0; 0 } else if (key == "vals") { idx = 1; 0 };
    };
    idx
};

// Static type of field `key` in trec type t (tnone when there is none).
def rec_field_type(t, key: str) -> { k: str } {
    let ft = { k: "tnone" };
    if (t.k == "trec") {
        let fs = t.fields;
        let i = 0;
        while (i < len(fs)) {
            let f = fs[i];
            if (f.name == key) {
                ft = f.typ;
                0
            } else { 0; };
            i = i + 1;
        };
        0
    } else { 0; };
    ft
};

// Heap array literal [v, ...]: a data block of arr_alloc_size(esz, n) and a
// separate arr_header_size() header {len, cap, data}; the values are stored
// into the data block through the header's pointer. The header address (an
// 8-byte value like any other) is the expression value.
def gen_array(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let at = infer(st, node);
    let gsz = arr_elem_bytes(at);
    gen_array_esz(st, node, gsz, store_elem_type(at, gsz))
};

// Same, with the element width supplied by the declaration (`let b:
// [byte] = [104, 105]` — the literal's own elements infer as long), and
// `ety` the element type each value converts to (store_elem_type).
def gen_array_esz(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node, esz: long, ety) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let elems = node.elems;
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

def gen_len(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    // Checker: single array or string argument. Fixed size is immediate
    // (from the inferred type itself); heap length (array header or string
    // header) loads from address+0. NOTE: the argument is any array-typed
    // expression (id, dot like `a.args`, call result) — never assume a
    // plain id (no `.v` reads here); infer gives the static type.
    let args = node.args;
    let at = infer(st, args[0]);
    if (at.k == "tmap") {
        // len(m) = len(m.keys): the entry count
        gen(st, n_call1("len", n_dot(args[0], "keys", node.line, node.col), node.line, node.col))
    } else if (at.k == "tstr") {
        st = gen(st, args[0]);
        emit(st, "    mov (%rax), %rax")
    } else {
        st = gen(st, args[0]);
        emit(st, "    mov (%rax), %rax")
    }
};

// arr += v: Y calling convention straight into the prelude helper.
// Returns the (possibly reallocated) header — rebind it: `a += v`.
def gen_push(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let pargs = node.args;
    let pat = infer(st, pargs[0]);
    let pesz = arr_elem_bytes(pat);
    st = gen_push_args_as(st, node.args, args2({ k: "tnone" }, store_elem_type(pat, pesz)));
    st = emit(st, "    mov $" + tostring(pesz) + ", %rax");
    st = emit(st, "    push %rax");
    st = emit(st, "    call y_arr_push");
    let nbytes = len(node.args) * 8 + 8;
    emit(st, "    add $" + tostring(nbytes) + ", %rsp")
};

// some(v): box v in 8 heap bytes; the box address (nonzero) is the value.
def gen_some(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let args = node.args;
    st = gen(st, args[0]);
    st = emit(st, "    push %rax");
    st = emit(st, "    mov $8, %rdi");
    st = emit(st, "    call y_alloc");
    st = emit(st, "    pop %rcx");
    st = emit(st, "    mov %rcx, (%rax)");
    st
};

def gen_is_some(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let args = node.args;
    st = gen(st, args[0]);
    st = emit(st, "    test %rax, %rax");
    st = emit(st, "    setne %al");
    emit(st, "    movzbq %al, %rax")
};

def gen_unwrap(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let args = node.args;
    st = gen(st, args[0]);
    st = emit(st, "    test %rax, %rax");
    st = emit(st, "    jz y_opt_unwrap");
    emit(st, "    mov (%rax), %rax")
};

// ── string builtins (all on {len, data} header objects) ────────────────
// Every helper takes header addresses via the Y calling convention
// (args pushed left-to-right, first arg deepest) and returns a header
// address (or long) in %rax. Caller cleans the stack.

def gen_trim(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    st = gen_push_args(st, node.args);
    st = emit(st, "    call y_str_trim");
    emit(st, "    add $8, %rsp")
};

// arr *= v -> arr: in-place insert at the front (the header never
// moves, so every alias sees it). The `*=` operator desugars to this.
def gen_prepend(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let pargs = node.args;
    let pat = infer(st, pargs[0]);
    let pesz = arr_elem_bytes(pat);
    st = gen_push_args_as(st, node.args, args2({ k: "tnone" }, store_elem_type(pat, pesz)));
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
def gen_byte_at(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let args = node.args;
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

def gen_ord(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    st = gen_push_args(st, node.args);
    st = emit(st, "    call y_str_ord");
    emit(st, "    add $8, %rsp")
};

def gen_chr(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    st = gen_push_args(st, node.args);
    st = emit(st, "    call y_str_chr");
    emit(st, "    add $8, %rsp")
};

def gen_tonum(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    st = gen_push_args(st, node.args);
    st = emit(st, "    call y_str_tonum");
    emit(st, "    add $8, %rsp")
};

def gen_tostring(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    // dispatch on the static type: long/bool need conversion, str is identity
    let targs = node.args;
    let a0 = targs[0];
    let t = infer(st, a0);
    if (t.k == "tstr") {
        gen(st, a0)
    } else if (t.k == "tbool") {
        st = gen_push_args(st, node.args);
        st = emit(st, "    call y_bool_tostr");
        emit(st, "    add $8, %rsp")
    } else if (t.k == "tfloat") {
        st = gen_push_args(st, node.args);
        st = emit(st, "    call y_float_tostr");
        emit(st, "    add $8, %rsp")
    } else if (t.k == "tarr") {
        st = gen(st, a0);
        if (t.of.k == "tbyte") { gen_helper1(st, "y_bytes_repr") } else { gen_arr_tostr_rax(st, t.of) }
    } else if (t.k == "tarrfix") {
        st = gen(st, a0);
        if (t.of.k == "tbyte") { gen_helper1(st, "y_bytes_repr") } else { gen_arr_tostr_rax(st, t.of) }
    } else if (t.k == "topt") {
        st = gen(st, a0);
        gen_opt_str_rax(st, t)
    } else if (t.k == "trec") {
        st = gen(st, a0);
        gen_rec_str_rax(st, t)
    } else if (t.k == "tunion") {
        st = gen(st, a0);
        gen_union_str_rax(st, t)
    } else if (t.k == "tmap") {
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
def gen_fmt(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let fargs = node.args;
    let a0 = fargs[0];
    let spec: str = fargs[1].v;
    let ts = n_call1("tostring", a0, node.line, node.col);
    if (spec == "") {
        gen_tostring(st, ts)
    } else {
        let t = infer(st, a0);
        let f = types.fmt_spec(spec);
        let kind = types.fmt_kind(t);
        let ty = f.ty;
        if (ty == 0) {
            if (kind == 1) { ty = 100; 0; } else if (kind == 2) { ty = 102; 0; } else { ty = 115; 0; };
            0
        } else { 0; };
        let code = fmt_code(f, kind, ty);
        if (ty == 115) {
            st = gen_tostring(st, ts);
            st = emit(st, "    push %rax");
            st = fmt_push(st, code);
            st = fmt_push(st, f.width);
            st = fmt_push(st, f.prec);
            st = emit(st, "    call y_fmt_s");
            emit(st, "    add $32, %rsp")
        } else if (ty == 100 || ty == 120 || ty == 88 || ty == 111 || ty == 98 || ty == 99) {
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
                0
            } else { 0; };
            if (ty == 37) {
                st = emit(st, "    movq %rax, %xmm0");
                st = emit(st, "    mov $100, %rax");
                st = emit(st, "    cvtsi2sd %rax, %xmm1");
                st = emit(st, "    mulsd %xmm1, %xmm0");
                st = emit(st, "    movq %xmm0, %rax");
                0
            } else { 0; };
            let prec = f.prec;
            if (prec < 0) { prec = 6; 0; } else { 0; };
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
def fmt_code(f: { err: str, fill: long, align: long, sign: long, alt: bool, zero: bool, width: long, grp: long, prec: long, ty: long }, kind: long, ty: long) -> long {
    let fill = f.fill;
    let align = f.align;
    if (f.zero && fill == 0) { fill = 48; 0; } else { 0; };
    if (f.zero && align == 0 && kind != 0) { align = 61; 0; } else { 0; };
    if (fill == 0) { fill = 32; 0; } else { 0; };
    if (align == 0) {
        if (kind != 0) { align = 62; 0; } else { align = 60; 0; };
        0
    } else { 0; };
    let sg = 0;
    if (f.sign == 43) { sg = 1; 0; } else if (f.sign == 32) { sg = 2; 0; } else { 0; };
    if (f.alt) { sg = sg + 4; 0; } else { 0; };
    if (f.grp == 44) { sg = sg + 8; 0; } else if (f.grp == 95) { sg = sg + 16; 0; } else { 0; };
    ty + 256 * fill + 65536 * align + 16777216 * sg
};

// Push the number v (an argument of a helper call).
def fmt_push(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, v: long) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    st = emit(st, "    mov $" + tostring(v) + ", %rax");
    emit(st, "    push %rax")
};

def gen_index_of(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node, last: bool) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
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
def gen_join(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let jargs = node.args;
    let at = infer(st, jargs[0]);
    let eltyp = { k: "tunk" };
    if (at.k == "tarr") { eltyp = at.of; 0; } else { 0; };
    if (at.k == "tarrfix") { eltyp = at.of; 0; } else { 0; };
    let ek = eltyp.k;
    if (ek == "tlong") {
        gen_join_conv(st, node, "y_long_tostr", 8)
    } else if (ek == "tbyte") {
        gen_join_conv(st, node, "y_long_tostr", 1)
    } else if (ek == "tbool") {
        gen_join_conv(st, node, "y_bool_tostr", 8)
    } else if (ek == "tfloat") {
        gen_join_conv(st, node, "y_float_tostr", 8)
    } else {
        st = gen_push_args(st, node.args);
        st = emit(st, "    call y_str_join");
        emit(st, "    add $16, %rsp")
    }
};

// Slots: [src][dst][i]. Builds dst = [tostr(src[0]), ...] then joins it.
def gen_join_conv(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node, tostr_fn: str, esz: long) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let soff = (st.slots + 1) * -8;
    let doff = (st.slots + 2) * -8;
    let ioff = (st.slots + 3) * -8;
    st = { out: st.out, rodata: st.rodata, uid: st.uid,
      fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots + 3,
      self_label: st.self_label, end_label: st.end_label, fns: st.fns,
      bodies: st.bodies };
    let jargs = node.args;
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

def gen_split(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    st = gen_push_args(st, node.args);
    st = emit(st, "    call y_str_split");
    emit(st, "    add $16, %rsp")
};

def gen_puts(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    // puts(v): write the value WITHOUT trailing newline (C semantics:
    // fputs + flush). Like print but no newline; returns nothing (void).
    let pargs = node.args;
    let pa = pargs[0];
    st = gen(st, pa);
    let t = infer(st, pa);
    if (t.k == "tbool") {
        st = gen_helper1(st, "y_put_bool");
        emit(st, "    xor %eax, %eax")
    } else if (t.k == "tstr") {
        st = gen_helper1(st, "y_put_hstr");
        emit(st, "    xor %eax, %eax")
    } else {
        st = gen_helper1(st, "y_put_long");
        emit(st, "    xor %eax, %eax")
    }
};

def gen_eputs(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    // eputs(v): like puts, but on fd 2. Diagnostic output (`--time`) must
    // never land in stdout (where `-S` assembly and program output live).
    let pargs = node.args;
    let pa = pargs[0];
    st = gen(st, pa);
    let t = infer(st, pa);
    if (t.k == "tbool") {
        st = gen_helper1(st, "y_eput_bool");
        emit(st, "    xor %eax, %eax")
    } else if (t.k == "tstr") {
        st = gen_helper1(st, "y_eput_hstr");
        emit(st, "    xor %eax, %eax")
    } else {
        st = gen_helper1(st, "y_eput_long");
        emit(st, "    xor %eax, %eax")
    }
};

def gen_clock_us(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    // clock_us() -> long (monotonic microseconds, via clock_gettime).
    let unused = node;
    emit(st, "    call y_clock_us")
};

def gen_heap_used(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    // heap_used() -> long (bytes the allocator has handed out so far).
    let unused = node;
    emit(st, "    call y_heap_used")
};

def gen_sleep(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    // sleep(ms): suspend the caller for ms milliseconds (nanosleep, EINTR
    // cannot happen in single-threaded code, so one syscall is enough).
    let sargs = node.args;
    let sa = sargs[0];
    st = gen(st, sa);
    gen_helper1(st, "y_sleep")
};


def gen_exit(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    // exit(code): terminate the process with the exit-code syscall.
    let eargs = node.args;
    let ea = eargs[0];
    st = gen(st, ea);
    st = emit(st, "    mov %rax, %rdi");
    st = emit(st, "    mov $60, %rax");
    st = emit(st, "    syscall");
    // exit() terminates the process; the epilogue (ret / exit(0)) is
    // unreachable. Emit a jump to the function end so the backend never
    // falls through into dead code (and exit codes are never masked).
    emit(st, "    jmp " + st.end_label)
};

// ── process I/O + files (argv, read_file, write_file) ───────────────
// argv MAY only appear as `main(argv())`'s argument feed: ycc.y's entry is
// `let result = main(argv())`. The _start prologue (below) builds the argv
// array and stashes it in r15; gen_argv emits the call that materializes it.
// read_file(path): openat+read loop into a heap string; none (0) on error,
// else a some()-style heap box holding the string header (options are
// 0-or-box per NATIVE.md, so unwrap() derefs uniformly).
// write_file(path, content): openat(O_WRONLY|O_CREAT|O_TRUNC, 0644)+write;
// returns bool. Both are straight-line syscalls, no libc.

def gen_argv(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    emit(st, "    call y_argv")
};

def gen_read_file(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    st = gen_push_args(st, node.args);
    st = emit(st, "    call y_read_file");
    emit(st, "    add $8, %rsp")
};

def gen_write_file(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    st = gen_push_args(st, node.args);
    st = emit(st, "    call y_write_file");
    emit(st, "    add $16, %rsp")
};

// write_bytes(path, bytes, mode): binary-safe emit (tinycc's
// tcc_write_elf_file output step, minus buffering): openat + write loop
// over the packed byte array's data + close + chmod. Args arrive left-to-right
// (path deepest); the helper takes the same Y convention.
def gen_write_bytes(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    st = gen_push_args(st, node.args);
    st = emit(st, "    call y_write_bytes");
    emit(st, "    add $24, %rsp")
};

def gen_store(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let spt = infer(st, node.p);
    let sw = ptr_width(spt);
    let sto = { k: "tnone" };
    if (sw == 8 && spt.k == "tptr") { sto = spt.to; 0 } else { 0; };
    st = gen(st, node.p);
    st = emit(st, "    push %rax");
    st = gen_as(st, node.v, sto);
    st = emit(st, "    pop %rcx");
    if (sw == 1) { emit(st, "    movb %al, (%rcx)") } else { emit(st, "    mov %rax, (%rcx)") }
};

// ── functions ──────────────────────────────────────────────────────────
// Frame: locals at rbp-8, rbp-16, ...; params at rbp+16, rbp+24, ....
// Every emitted function gets: prologue, body, end_label, epilogue.

def emit_one_fn(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, label: str, fuid: long, func, is_main: bool, want_argv: bool, captypes: [{ k: str }], selfname: str) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    // fresh per-function state; uid/rodata/fns flow through and back.
    // The scope is pre-loaded with every known def (like the checker's
    // fresh_func_scope): bodies see all hoisted functions and globals.
    let f = { out: [], rodata: st.rodata, uid: st.uid,
      fuid: fuid, loc: 1, env: [], slots: 0,
      self_label: label, end_label: arch.arch_loc_label(fuid, 0),
      fns: st.fns, bodies: st.bodies };
    let fnsall = st.fns;
    let g = 0;
    while (g < len(fnsall)) {
        let fe = fnsall[g];
        f = env_define(f, fe.name, fns_kind(fe.label), 0, fe.label, fe.typ);
        g = g + 1;
    };
    // The names nested functions capture (see box_names / box_bound).
    f = env_define(f, "", "frame", 0, "", { k: "tnone" });
    // This function's type, for the conversions at its returns and its
    // self calls (cur_fn_type).
    f = env_define(f, "", "fnty", 0, "", { k: "tfunc", args: func.ptypes, ret: func.ret });
    let bnames = box_names(func);
    let bi = 0;
    while (bi < len(bnames)) {
        let bnm: str = bnames[bi];
        f = env_define(f, "", "boxmark", 0, bnm, { k: "tnone" });
        bi = bi + 1;
    };
    // A capturing named function is not in that table (see
    // capturing_defs): bind its own name to this body, so a call by name
    // passes the record along (gen_direct) and a value is the record.
    if (selfname != "") {
        f = env_define(f, selfname, "func", 0, label, func_type_in(st, func));
        0
    } else { 0; };
    // bind params. Caller pushes args left-to-right, so the LAST arg sits
    // at rbp+16 and param k lives at rbp+16+8*(n-1-k) (arity-dependent).
    let params = func.params;
    let ptypes = func.ptypes;
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
    if (is_main) { 0; } else {
        let excl = fn_names_of(st.fns);
        if (selfname != "") { excl += selfname; 0; } else { 0; };
        let mycaps = fn_captures(func, excl);
        let cloff = 16 + nargs * 8;
        let c = 0;
        while (c < len(mycaps)) {
            let cn: str = mycaps[c];
            // Capture types come from the creation site (the enclosing env
            // knows them); without one the emitter would pick long for a
            // captured string in print/puts and in `+`.
            let ct = { k: "tnone" };
            if (c < len(captypes)) {
                ct = captypes[c];
                0
            } else { 0; };
            f = env_define(f, cn, "capture", cloff, tostring(c), ct);
            c = c + 1;
        };
        0
    };
    // Captured parameters (and the own name) move into their cells
    // before the body; a tail call re-enters above this, so every
    // recycled frame gets fresh cells.
    if (selfname != "") {
        f = box_bound(f, selfname);
        0
    } else { 0; };
    let pbi = 0;
    while (pbi < nargs) {
        let pbn: str = params[pbi];
        f = box_bound(f, pbn);
        pbi = pbi + 1;
    };
    f = gen_tail(f, func.body);
    let frame = arch.arch_frame(f.slots);
    let code = [];
    code += label + ":";
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
            0
        } else { 0; };
        0
    } else { 0; };
    code += "    push %rbp";
    code += "    mov %rsp, %rbp";
    if (frame > 0) {
        code += "    sub $" + tostring(frame) + ", %rsp";
        0
    } else { 0; };
    let fout = f.out;
    let j = 0;
    while (j < len(fout)) {
        code += fout[j];
        j = j + 1;
    };
    code += f.end_label + ":";
    if (is_main) {
        code += "    mov $60, %rax";
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
def infer_fn_ret(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, func) -> { k: str } {
    let f = { out: [], rodata: st.rodata, uid: st.uid,
      fuid: 0, loc: 1, env: [], slots: 0,
      self_label: "", end_label: "", fns: st.fns, bodies: st.bodies };
    let fnsall = st.fns;
    let g = 0;
    while (g < len(fnsall)) {
        let fe = fnsall[g];
        f = env_define(f, fe.name, fns_kind(fe.label), 0, fe.label, fe.typ);
        g = g + 1;
    };
    let params = func.params;
    let ptypes = func.ptypes;
    let n = len(params);
    let i = 0;
    while (i < n) {
        f = env_define(f, params[i], "param", 16 + (n - 1 - i) * 8, "", ptypes[i]);
        i = i + 1;
    };
    infer(f, func.body)
};

def func_type(func) -> { k: str, args: [{ k: str }], ret: { k: str } } {
    { k: "tfunc", args: func.ptypes, ret: func.ret }
};

// Same, but with an unannotated return type resolved from the body — the
// checker infers it too, so a literal's call sites must agree (whether `+`
// stringifies, which print arm runs, ...).
def func_type_in(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, func) -> { k: str, args: [{ k: str }], ret: { k: str } } {
    let r = func.ret;
    if (r.k == "tnone") {
        r = infer_fn_ret(st, func);
        0
    } else { 0; };
    { k: "tfunc", args: func.ptypes, ret: r }
};

// Display name: strip rename's `$N` suffix (see types.y disp).
def ndisp(name: str) -> str {
    let i = index_of(name, "$");
    if (i < 0) { name } else { name[:i] }
};

// Two spliced modules may define the same name: shadowing would silently
// pick one, so duplicates are a loud error (at the second def's position).
def find_dup(defs: [{ name: str, func: { k: str } }]) -> { found: bool, err: { msg: str, line: long, col: long } } {
    let seen = [];
    let i = 0;
    let out = { found: false, err: { msg: "", line: 1, col: 1 } };
    while (i < len(defs)) {
        let d = defs[i];
        let j = 0;
        while (j < len(seen)) {
            // NOTE: :str binding (see teq note in types.y): seen elements
            // infer tunk (pushed into bare []), so compare via annotated
            // let to force content (not pointer) comparison.
            let sn: str = seen[j];
            if (sn == d.name) {
                out = { found: true, err: { msg: "duplicate definition '" + ndisp(d.name) + "' (native imports splice; rename one)", line: d.func.line, col: d.func.col } };
                0
            } else { 0; };
            j = j + 1;
        };
        seen += d.name;
        i = i + 1;
    };
    out
};

// ── globals and hoisting ───────────────────────────────────────────────
// Every variable bound directly in the program is a GLOBAL: one 8-byte
// .bss cell, read and written by label from any function. So a def that
// names one captures nothing, and every top-level def is hoisted: emitted
// once, called directly by label, from anywhere (forward calls too).

// The program's top-level variable declarations, in order (function
// bindings are defs, not variables).
def global_decls(stmts) -> [{ k: str }] {
    let out: [{ k: str }] = [];
    let i = 0;
    while (i < len(stmts)) {
        let s = stmts[i];
        if (s.k == "decl") {
            if (s.kind == "def") { 0; }
            else if (s.v.k == "func") { 0; }
            else { out += s; 0; };
            0
        } else { 0; };
        i = i + 1;
    };
    out
};

def decl_name(d) -> str {
    d.name
};

// Each global's cell label and type, in program order. A declared type
// wins; otherwise the initializer is inferred in a scope holding the
// hoisted defs and the globals before it (what main sees when it runs
// the declaration).
def global_entries(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, gdecls: [{ k: str }]) -> [{ name: str, label: str, typ: { k: str } }] {
    let f = { out: [], rodata: st.rodata, uid: st.uid,
      fuid: 0, loc: 1, env: [], slots: 0,
      self_label: "", end_label: "", fns: st.fns, bodies: st.bodies };
    let fnsall = st.fns;
    let g = 0;
    while (g < len(fnsall)) {
        let fe = fnsall[g];
        f = env_define(f, fe.name, fns_kind(fe.label), 0, fe.label, fe.typ);
        g = g + 1;
    };
    let out: [{ name: str, label: str, typ: { k: str } }] = [];
    let i = 0;
    while (i < len(gdecls)) {
        let d = gdecls[i];
        let gn = decl_name(d);
        let t = decl_type(d);
        if (t.k == "tnone") {
            t = infer(f, decl_value(d));
            0
        } else { 0; };
        let lbl = arch.arch_global_label(i, gn);
        out += { name: gn, label: lbl, typ: t };
        f = env_define(f, gn, "global", 0, lbl, t);
        i = i + 1;
    };
    out
};

def decl_type(d) -> { k: str } {
    d.typ
};

def decl_value(d) -> { k: str } {
    d.v
};

// Named functions that need a closure record: a def reading a variable
// that is neither a global nor a function, or naming a function that
// needs one itself (a direct call could not hand that one its record).
// Iterated to a fixpoint. A function's own name is no capture (its body
// reaches itself through its own record, see emit_one_fn).
def capturing_defs(defs: [{ name: str, func: { k: str } }], gnames: [str]) -> [str] {
    let fnames: [str] = [];
    let i = 0;
    while (i < len(defs)) {
        let d = defs[i];
        fnames += d.name;
        i = i + 1;
    };
    let caps: [[str]] = [];
    let out: [str] = [];
    i = 0;
    while (i < len(defs)) {
        let d = defs[i];
        let excl: [str] = [];
        excl += gnames;
        excl += d.name;
        let cs = fn_captures(d.func, excl);
        caps += [cs];
        let j = 0;
        let reads_var = false;
        while (j < len(cs)) {
            let cn: str = cs[j];
            if (name_in(fnames, cn)) { 0; } else { reads_var = true; 0; };
            j = j + 1;
        };
        if (reads_var) { out += d.name; 0; } else { 0; };
        i = i + 1;
    };
    let changed = true;
    while (changed) {
        changed = false;
        i = 0;
        while (i < len(defs)) {
            let d = defs[i];
            if (name_in(out, d.name)) { 0; } else {
                let cs = caps[i];
                let j = 0;
                let hit = false;
                while (j < len(cs)) {
                    let cn: str = cs[j];
                    if (name_in(out, cn)) { hit = true; 0; } else { 0; };
                    j = j + 1;
                };
                if (hit) {
                    out += d.name;
                    changed = true;
                    0
                } else { 0; };
                0
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
def fix_fn_types(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, hdefs: [{ name: str, func: { k: str } }], only: [str]) -> [{ name: str, label: str, typ: { k: str } }] {
    let out: [{ name: str, label: str, typ: { k: str } }] = [];
    let ftab = st.fns;
    let fx = 0;
    while (fx < len(hdefs)) {
        let d = hdefs[fx];
        let fe0 = ftab[fx];
        let redo = ret_omitted(d.func);
        if (redo && len(only) > 0) {
            redo = reads_any(d.func, only);
            0
        } else { 0; };
        if (redo) {
            out += { name: fe0.name, label: fe0.label,
              typ: { k: "tfunc", args: fn_ptypes(d.func), ret: infer_fn_ret(st, d.func) } };
            0
        } else {
            out += fe0;
            0
        };
        fx = fx + 1;
    };
    out
};

def ret_omitted(func) -> bool {
    let r = func.ret;
    r.k == "tnone"
};

def fn_ptypes(func) -> [{ k: str }] {
    func.ptypes
};

def reads_any(func, names: [str]) -> bool {
    let reads = fv_ids(func.body, []);
    let i = 0;
    let found = false;
    while (i < len(reads)) {
        let n: str = reads[i];
        if (name_in(names, n)) { found = true; 0; } else { 0; };
        i = i + 1;
    };
    found
};

// ── phase timing ───────────────────────────────────────────────────────
// Every phase records elapsed microseconds and heap bytes consumed, so
// `ycc --time` can show where wall time AND memory go (the arena never
// frees, so allocation volume is as interesting as elapsed time).

def phase_end(times: [{ name: str, us: long, heap: long }], name: str, t0: long, h0: long) -> { times: [{ name: str, us: long, heap: long }], t: long, h: long } {
    let t1 = clock_us();
    let h1 = heap_used();
    times += { name: name, us: t1 - t0, heap: h1 - h0 };
    { times: times, t: t1, h: h1 }
};

// ── entry point ────────────────────────────────────────────────────────

def emit_program(ast, imports: [str]) -> { ok: bool, asm: str, errors: [{ msg: str, line: long, col: long }], times: [{ name: str, us: long, heap: long }] } {
    let times: [{ name: str, us: long, heap: long }] = [];
    let pt = clock_us();
    let ph = heap_used();
    let ast2 = strip_ns(ast, imports);
    let pr = phase_end(times, "strip_ns", pt, ph);
    times = pr.times; pt = pr.t; ph = pr.h;
    // Static name resolution: every binding gets a unique name, so neither
    // the checker nor the emitter deals with scopes or shadowing.
    let ast3 = rename.rename_program(ast2);
    pr = phase_end(times, "rename", pt, ph);
    times = pr.times; pt = pr.t; ph = pr.h;
    let errors = types.check_program(ast3);
    pr = phase_end(times, "typecheck", pt, ph);
    times = pr.times; pt = pr.t; ph = pr.h;
    // collect every named def (top-level, nested, let-bound)
    let defs = collect_from_block(ast3.stmts, []);
    let dup = find_dup(defs);
    if (dup.found) {
        errors += dup.err;
        0
    } else { 0; };
    if (len(errors) > 0) {
        { ok: false, asm: "", errors: errors, times: times }
    } else {
        let gdecls = global_decls(ast3.stmts);
        let gnames: [str] = [];
        let gi = 0;
        while (gi < len(gdecls)) {
            gnames += decl_name(gdecls[gi]);
            gi = gi + 1;
        };
        // A def needing a closure record is emitted where it is created
        // (gen_decl); every other one is hoisted: a label in st.fns.
        let capdefs = capturing_defs(defs, gnames);
        let hdefs: [{ name: str, func: { k: str } }] = [];
        // assign labels + env entries (also pre-binds for calls)
        let st = st_new();
        let r = next_uid(st);
        st = r.st;
        let i = 0;
        while (i < len(defs)) {
            let d = defs[i];
            if (name_in(capdefs, d.name)) { 0; } else {
                hdefs += d;
                let rl = next_uid(st);
                st = rl.st;
                let label = fn_label_of(rl.uid, d.name);
                st.fns += { name: d.name, label: label, typ: func_type(d.func) };
                let fns = st.fns;
                st = { out: st.out, rodata: st.rodata, uid: st.uid,
                  fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots,
                  self_label: st.self_label, end_label: st.end_label, fns: fns,
                  bodies: st.bodies };
                st = env_define(st, d.name, "func", 0, label, func_type(d.func));
                0
            };
            i = i + 1;
        };
        // Fill in the return type of every unannotated def, so call sites
        // know what a call yields; then type the globals with those, and
        // redo the defs that read a global (they now know its type). The
        // globals sit after the defs in st.fns (see fns_kind).
        let fixed1 = fix_fn_types(st, hdefs, []);
        st = { out: st.out, rodata: st.rodata, uid: st.uid,
          fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots,
          self_label: st.self_label, end_label: st.end_label, fns: fixed1,
          bodies: st.bodies };
        let gl = global_entries(st, gdecls);
        let fixedfns: [{ name: str, label: str, typ: { k: str } }] = [];
        fixedfns += fixed1;
        fixedfns += gl;
        if (len(gl) > 0) {
            st = { out: st.out, rodata: st.rodata, uid: st.uid,
              fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots,
              self_label: st.self_label, end_label: st.end_label, fns: fixedfns,
              bodies: st.bodies };
            let fixed2 = fix_fn_types(st, hdefs, gnames);
            fixedfns = [];
            fixedfns += fixed2;
            fixedfns += gl;
            0
        } else { 0; };
        st = { out: st.out, rodata: st.rodata, uid: st.uid,
          fuid: st.fuid, loc: st.loc, env: st.env, slots: st.slots,
          self_label: st.self_label, end_label: st.end_label, fns: fixedfns,
          bodies: st.bodies };
        // emit each hoisted body
        i = 0;
        while (i < len(hdefs)) {
            let d = hdefs[i];
            let fns = st.fns;
            let f = fns[i];
            let rf = next_uid(st);
            st = rf.st;
            st = emit_one_fn(st, f.label, rf.uid, d.func, false, false, [], "");
            i = i + 1;
        };
        pr = phase_end(times, "emit_fns", pt, ph);
        times = pr.times; pt = pr.t; ph = pr.h;
        // main = program with hoisted defs skipped (emitted above, calls go
        // direct to their labels). Variable declarations store to their
        // globals (bind_decl). A def needing a record would be created
        // here like a nested one — but a top-level def can only read
        // globals and functions, so none does.
        let main_stmts = [];
        let pstmts = ast3.stmts;
        let i = 0;
        while (i < len(pstmts)) {
            let s = pstmts[i];
            if (s.k == "decl") {
                if (s.kind == "def") {
                    if (name_in(capdefs, s.name)) {
                        main_stmts += s;
                        0;
                    } else { 0; };
                    0
                } else if (s.v.k == "func") {
                    if (name_in(capdefs, s.name)) {
                        main_stmts += s;
                        0;
                    } else { 0; };
                    0
                } else {
                    main_stmts += s;
                    0;
                };
                0
            } else {
                main_stmts += s;
                0;
            };
            i = i + 1;
        };
        let rm = next_uid(st);
        st = rm.st;
        // Only pay for argv materialization when the program uses it.
        let want = uses_scan_block(ast3.stmts, { argv: false });
        st = emit_one_fn(st, "_start", rm.uid, { params: [], ptypes: [], ret: { k: "tvoid" }, body: { k: "block", stmts: main_stmts } }, true, want.argv, [], "");
        pr = phase_end(times, "emit_start", pt, ph);
        times = pr.times; pt = pr.t; ph = pr.h;
        // assemble the file. Body-level tree shaking comes first: its
        // output is also the root set for shaking the arch prelude, and
        // the kept prelude's references shake the rodata constants.
        let allbodies = st.bodies;
        let shaken = prune_bodies(allbodies, arch.arch_prelude());
        let bodies = shaken.bodies;
        let body_refs = shaken.refs;
        // Piece-list + single join: `asm = asm + piece` per iteration is
        // quadratic (each concat re-copies the whole 1.4MB+ accumulator —
        // the arena never frees), which OOMs on self-compilation.
        let pieces: [str] = [];
        let b = 0;
        while (b < len(bodies)) {
            pieces += bodies[b];
            pieces += "\n";
            b = b + 1;
        };
        let body_text = join(pieces, "");
        let asm = arch.arch_header();
        let prelude_text = shake_refs(arch.arch_prelude(), body_refs);
        asm = asm + arch.arch_text() + prelude_text;
        asm = asm + body_text;
        let const_refs = text_refs(prelude_text, true);
        let ci = 0;
        while (ci < len(body_refs)) {
            const_refs += [body_refs[ci]];
            ci = ci + 1;
        };
        let consts_text = shake_refs(arch.arch_consts(), const_refs);
        asm = asm + arch.arch_rodata() + consts_text;
        let allrod = st.rodata;
        let s2 = 0;
        let rodpieces: [str] = [];
        while (s2 < len(allrod)) {
            let pair = allrod[s2];
            // String entries are exactly [label, len, escaped]; shape
            // tables (see gen_reclit note) are longer and all-strings.
            if (len(pair) == 3) {
                rodpieces += pair[0] + ":\n.quad " + tostring(pair[1]) + "\n.string \"" + pair[2] + "\"\n";
                0
            } else {
                rodpieces += pair[0] + ":\n";
                let q = 2;
                while (q < len(pair)) {
                    rodpieces += ".quad " + pair[q] + "\n";
                    q = q + 1;
                };
                0
            };
            s2 = s2 + 1;
        };
        asm = asm + join(rodpieces, "");
        // .bss: the allocator's cells when the kept prelude still uses
        // them, then one cell per global.
        let heap_text = shake_refs(arch.arch_heap_cells(), const_refs);
        if (len(gl) > 0 || len(heap_text) > 0) {
            let gpieces: [str] = [];
            gpieces += arch.arch_bss();
            gpieces += heap_text;
            let gk = 0;
            while (gk < len(gl)) {
                let ge = gl[gk];
                gpieces += arch.arch_global_cell(ge.label);
                gk = gk + 1;
            };
            asm = asm + join(gpieces, "");
            0
        } else { 0; };
        pr = phase_end(times, "asm_text", pt, ph);
        times = pr.times; pt = pr.t; ph = pr.h;
        { ok: true, asm: asm, errors: errors, times: times }
    }
};

export { emit_program, native_resolve, native_resolve_x, strip_ns, strip_list, strip_decl, phase_end };

// ── maps: dynamic {K => V} ────────────────────────────────────────────
// A map value is a two-field record -- {keys: [K], vals: [V]} -- and
// every map operation lowers to synthetic AST over those arrays (the
// emitter knows the static key and value types for comparison and
// formatting), so maps need no runtime assembly of their own. Reads are
// always optional: a hit boxes the value (some(v)), a miss leaves none.

def n_str(v: str, line: long, col: long) -> {k: str} {
    { k: "str", v: v, line: line, col: col }
};

def n_bool(v: str, line: long, col: long) -> {k: str} {
    { k: "bool", v: v, line: line, col: col }
};

def n_dot(obj, key: str, line: long, col: long) -> {k: str} {
    { k: "dot", obj: obj, key: key, line: line, col: col }
};

def n_idx(arr, idx, line: long, col: long) -> {k: str} {
    { k: "index", arr: arr, idx: idx, line: line, col: col }
};

def n_bin(op: str, l, r, line: long, col: long) -> {k: str} {
    { k: "bin", op: op, l: l, r: r, line: line, col: col }
};

def n_not(e, line: long, col: long) -> {k: str} {
    { k: "un", op: "!", e: e, line: line, col: col }
};

def n_if(c, t, e, ln: long, cl: long) -> {k: str} {
    { k: "if", cond: c, then: t, els: e, has_else: true, line: ln, col: cl }
};

def n_while(c, b, ln: long, cl: long) -> {k: str} {
    { k: "while", cond: c, body: b, line: ln, col: cl }
};

def n_decl(name: str, v, ln: long, cl: long) -> {k: str} {
    { k: "decl", kind: "let", typ: { k: "tnone" }, name: name, v: v, line: ln, col: cl }
};

def n_assign(name: str, v, ln: long, cl: long) -> {k: str} {
    { k: "assign", name: name, v: v, line: ln, col: cl }
};

def block_of(sts: [{k: str}], ln: long, cl: long) -> {k: str} {
    { k: "block", stmts: sts, line: ln, col: cl }
};

// {"a": 1, "a": 2}: duplicate keys collapse at emit time -- the last
// entry wins the value, the first appearance keeps the position (the
// record spread rule). The result is the {keys, vals} record literal.
def gen_maplit(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let ln = node.line;
    let cl = node.col;
    let mkeys = node.keys;
    let mvals = node.vals;
    let keys: [str] = [];
    let vals: [{k: str}] = [];
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
                0
            } else {
                0
            };
            fi = fi + 1;
        };
        if (found) {
            0
        } else {
            keys += mk;
            vals += mv;
            0
        };
        mi = mi + 1;
    };
    let knodes: [{k: str}] = [];
    let ki = 0;
    while (ki < len(keys)) {
        let ks: str = keys[ki];
        knodes += n_str(ks, ln, cl);
        ki = ki + 1;
    };
    let keysarr = { k: "array", elems: knodes, line: ln, col: cl };
    let valsarr = { k: "array", elems: vals, line: ln, col: cl };
    let rkeys: [str] = [];
    rkeys += "keys";
    rkeys += "vals";
    let rvals: [{k: str}] = [];
    rvals += keysarr;
    rvals += valsarr;
    gen(st, { k: "rec", keys: rkeys, vals: rvals, line: ln, col: cl })
};

// m[k] read: scan the keys; a hit boxes the value (some(vals[i]) -- the
// read's V? type), a miss leaves the starting 0 (none).
def gen_map_get(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let ln = node.line;
    let cl = node.col;
    let r = next_uid(st);
    st = r.st;
    let t = "y_t" + tostring(r.uid);
    let m = n_id(t + "m", ln, cl);
    let k = n_id(t + "k", ln, cl);
    let i = n_id(t + "i", ln, cl);
    let n = n_id(t + "n", ln, cl);
    let sts: [{k: str}] = [];
    sts += n_decl(t + "m", node.arr, ln, cl);
    sts += n_decl(t + "k", node.idx, ln, cl);
    sts += n_decl(t + "i", n_num("0", ln, cl), ln, cl);
    sts += n_decl(t + "n", n_call1("len", n_dot(m, "keys", ln, cl), ln, cl), ln, cl);
    sts += n_decl(t + "r", n_num("0", ln, cl), ln, cl);
    let cmp = n_bin("==", n_idx(n_dot(m, "keys", ln, cl), i, ln, cl), k, ln, cl);
    let hit: [{k: str}] = [];
    hit += n_assign(t + "r", n_call1("some", n_idx(n_dot(m, "vals", ln, cl), i, ln, cl), ln, cl), ln, cl);
    hit += n_assign(t + "i", n, ln, cl);
    hit += n_num("0", ln, cl);
    let miss: [{k: str}] = [];
    miss += n_num("0", ln, cl);
    let step = n_assign(t + "i", n_bin("+", i, n_num("1", ln, cl), ln, cl), ln, cl);
    let body: [{k: str}] = [];
    body += n_if(cmp, block_of(hit, ln, cl), block_of(miss, ln, cl), ln, cl);
    body += step;
    sts += n_while(n_bin("<", i, n, ln, cl), block_of(body, ln, cl), ln, cl);
    sts += n_id(t + "r", ln, cl);
    gen(st, block_of(sts, ln, cl))
};

// m[k] = v: scan for the key; a hit overwrites vals[i], a miss appends to
// both arrays (in place -- every alias of the map sees the write).
def gen_map_set(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, node) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let ln = node.line;
    let cl = node.col;
    let r = next_uid(st);
    st = r.st;
    let t = "y_t" + tostring(r.uid);
    let m = n_id(t + "m", ln, cl);
    let k = n_id(t + "k", ln, cl);
    let i = n_id(t + "i", ln, cl);
    let n = n_id(t + "n", ln, cl);
    let sts: [{k: str}] = [];
    sts += n_decl(t + "m", node.arr, ln, cl);
    sts += n_decl(t + "k", node.idx, ln, cl);
    sts += n_decl(t + "v", node.v, ln, cl);
    sts += n_decl(t + "i", n_num("0", ln, cl), ln, cl);
    sts += n_decl(t + "n", n_call1("len", n_dot(m, "keys", ln, cl), ln, cl), ln, cl);
    sts += n_decl(t + "f", n_bool("false", ln, cl), ln, cl);
    let cmp = n_bin("==", n_idx(n_dot(m, "keys", ln, cl), i, ln, cl), k, ln, cl);
    let hit: [{k: str}] = [];
    hit += { k: "idxassign", arr: n_dot(m, "vals", ln, cl), idx: i, v: n_id(t + "v", ln, cl), line: ln, col: cl };
    hit += n_assign(t + "f", n_bool("true", ln, cl), ln, cl);
    hit += n_assign(t + "i", n, ln, cl);
    hit += n_num("0", ln, cl);
    let miss: [{k: str}] = [];
    miss += n_num("0", ln, cl);
    let step = n_assign(t + "i", n_bin("+", i, n_num("1", ln, cl), ln, cl), ln, cl);
    let body: [{k: str}] = [];
    body += n_if(cmp, block_of(hit, ln, cl), block_of(miss, ln, cl), ln, cl);
    body += step;
    sts += n_while(n_bin("<", i, n, ln, cl), block_of(body, ln, cl), ln, cl);
    let grow: [{k: str}] = [];
    grow += { k: "opassign", tgt: n_dot(m, "keys", ln, cl), op: "+", v: k, line: ln, col: cl };
    grow += { k: "opassign", tgt: n_dot(m, "vals", ln, cl), op: "+", v: n_id(t + "v", ln, cl), line: ln, col: cl };
    grow += n_num("0", ln, cl);
    let nogrow: [{k: str}] = [];
    nogrow += n_num("0", ln, cl);
    sts += n_if(n_not(n_id(t + "f", ln, cl), ln, cl), block_of(grow, ln, cl), block_of(nogrow, ln, cl), ln, cl);
    sts += n_id(t + "v", ln, cl);
    gen(st, block_of(sts, ln, cl))
};

// One key's repr inside a map: string keys quote (Python-style), the
// other hashable keys stringify bare.
def map_key_repr(node, kt: {k: str}, ln: long, cl: long) -> {k: str} {
    if (kt.k == "tstr") {
        n_bin("+", n_bin("+", n_str("\"", ln, cl), node, ln, cl), n_str("\"", ln, cl), ln, cl)
    } else {
        n_call1("tostring", node, ln, cl)
    }
};

// {"k": v, ...}: a synthetic string-building loop -- the entry count is
// dynamic, but every format decision (keys, values) is static.
def gen_map_repr(st: { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] }, arg, t) -> { out: [str], rodata: [[str]], uid: long, fuid: long, loc: long, env: [{ name: str, kind: str, off: long, label: str, typ: { k: str } }], slots: long, self_label: str, end_label: str, fns: [{ name: str, label: str, typ: { k: str } }], bodies: [str] } {
    let ln = 0;
    let cl = 0;
    let r = next_uid(st);
    st = r.st;
    let g = "y_t" + tostring(r.uid);
    let m = n_id(g + "m", ln, cl);
    let i = n_id(g + "i", ln, cl);
    let n = n_id(g + "n", ln, cl);
    let s = n_id(g + "s", ln, cl);
    let sts: [{k: str}] = [];
    sts += n_decl(g + "m", arg, ln, cl);
    sts += n_decl(g + "s", n_str("{", ln, cl), ln, cl);
    sts += n_decl(g + "i", n_num("0", ln, cl), ln, cl);
    sts += n_decl(g + "n", n_call1("len", n_dot(m, "keys", ln, cl), ln, cl), ln, cl);
    let sep: [{k: str}] = [];
    sep += n_assign(g + "s", n_bin("+", s, n_str(", ", ln, cl), ln, cl), ln, cl);
    sep += n_num("0", ln, cl);
    let nosep: [{k: str}] = [];
    nosep += n_num("0", ln, cl);
    let kpart = map_key_repr(n_idx(n_dot(m, "keys", ln, cl), i, ln, cl), t.key, ln, cl);
    let vpart = n_call1("tostring", n_idx(n_dot(m, "vals", ln, cl), i, ln, cl), ln, cl);
    let put = n_assign(g + "s", n_bin("+", n_bin("+", n_bin("+", s, kpart, ln, cl), n_str(": ", ln, cl), ln, cl), vpart, ln, cl), ln, cl);
    let step = n_assign(g + "i", n_bin("+", i, n_num("1", ln, cl), ln, cl), ln, cl);
    let body: [{k: str}] = [];
    body += n_if(n_bin(">", i, n_num("0", ln, cl), ln, cl), block_of(sep, ln, cl), block_of(nosep, ln, cl), ln, cl);
    body += put;
    body += step;
    sts += n_while(n_bin("<", i, n, ln, cl), block_of(body, ln, cl), ln, cl);
    sts += n_bin("+", s, n_str("}", ln, cl), ln, cl);
    gen(st, block_of(sts, ln, cl))
};
