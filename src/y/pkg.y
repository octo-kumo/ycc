// pkg.y -- packages: what `ycc build` builds (ycc.y build_project). A
// project is a directory with a manifest, y.toml:
//
//   [package]
//   name = "app"                  # required: an identifier
//   lib = "src/lib.y"             # optional: what importers of app get
//   src = ["src"]                 # optional: where bare imports also look
//
//   [bin]                         # the programs: build/app from
//   app = "src/main.y"            # src/main.y
//
//   [dependencies]
//   json = { path = "../json" }                            # on disk
//   http = { git = "https://host/http.git", rev = "v1" }   # in git
//
// A dependency is a package whose own y.toml names it (`name = "json"`)
// and has a lib. `import json;` -- in a bin, or in a package's lib --
// imports it, and its names read `json.parse(s)`. Every package compiles
// on its own, once: build/obj keeps its object until its text, the
// interfaces it was compiled against, or the compiler change. Git
// dependencies are cloned into build/git and pinned, in y.lock, to the
// commit they resolved to; `ycc vendor` copies them into vendor/, which
// then wins.
//
// Every failure here is the user's: reported as `error: ...` (pk_die),
// and the run ends.

// For its alias Cursor.
import tags from "./tags.y";
import lexer from "./lexer.y";
import fs;

type PkEnt = { tab: str, n: long, key: str, line: long, k: long, s: str, keys: [str], items: [str] };
type PkDep = { name: str, path: str, git: str, rev: str };
type PkBin = { name: str, path: str };
type PkMan = { file: str, name: str, lib: str, roots: [str], bins: [PkBin], deps: [PkDep] };
type PkLock = { name: str, git: str, rev: str, commit: str };
type PkNode = { name: str, dir: str, lib: str, roots: [str], deps: [str], git: str, rev: str, commit: str };
type PkDecl = { name: str, src: str, by: str, dep: PkDep, fdir: str };
type PkSt = { root: str, rdir: str, decls: [PkDecl], done: [str], stack: [str], nodes: [PkNode], lock: [PkLock] };
type PkGraph = { dir: str, name: str, lib: str, roots: [str], bins: [PkBin], deps: [str], pkgs: [PkNode] };
// A git dependency's checkout and the commit it holds (pk_git_dir); a
// hash being computed (pk_hash_new).
type PkGit = { dir: str, commit: str };
type PkHash = { a: long, b: long };

def pk_die(msg: str) -> void {
    puts("error: " + msg + "\n");
    exit(1);
    1
};

def pk_has(xs: [str], s: str) -> bool {
    let found = false;
    let i = 0;
    while (!found && i < len(xs)) {
        let x: str = xs[i];
        found = x == s;
        i++;
    };
    found
};

def pk_nostrs() -> [str] {
    let xs: [str] = [];
    xs
};

// ── paths and files ─────────────────────────────────────────────────────

// `path` without `.` segments, and with each `..` taking the segment
// before it away (lexically: a symlink is not followed).
def pk_clean(path: str) -> str {
    let abs = path[:1] == "/";
    let parts = split(path, "/");
    let out: [str] = [];
    parts.foreach((e) => {
        let s: str = e;
        if (s == "" || s == ".") {
        } else if (s == "..") {
            let n = len(out);
            if (n > 0 && out[n - 1] != "..") {
                out = out[:n - 1];
            } else if (!abs) {
                out += s;
            }
        } else {
            out += s;
        };
    });
    let r = join(out, "/");
    if (abs) { "/" + r } else if (len(r) == 0) { "." } else { r }
};

// `p` (a manifest's path) as seen from the manifest's directory `dir`.
def pk_join(dir: str, p: str) -> str {
    if (p[:1] == "/") { pk_clean(p) } else { pk_clean(dir + "/" + p) }
};

def pk_dir_of(path: str) -> str {
    let i = last_index_of(path, "/");
    if (i < 0) { "." } else if (i == 0) { "/" } else { path[:i] }
};

def pk_is_dir(path: str) -> bool {
    // openat(AT_FDCWD, path, O_DIRECTORY)
    let fd = syscall(257, -100, path, 65536, 0);
    if (fd >= 0) { syscall(3, fd); true } else { false }
};

def pk_is_file(path: str) -> bool {
    let fd = syscall(257, -100, path, 0, 0);
    if (fd >= 0) { syscall(3, fd); !pk_is_dir(path) } else { false }
};

def pk_mkdir(path: str) -> void {
    syscall(83, path, 493);
    if (!pk_is_dir(path)) { pk_die("cannot create directory '" + path + "'"); }
    0
};

// ── the manifest: a TOML subset ─────────────────────────────────────────
// One construct per line: `[table]`, `[[table]]` (y.lock's), `key =
// value`, `#` comments. A value is a string ("..." with \\ \" \n \t
// escapes, or '...' as written), an array of strings, or an inline
// table of strings (`{ path = "../json" }`). Each line becomes a PkEnt:
// a header (k "h"), or a key with its value (k "s", "a" or "t"), under
// the table it is in (`n`: which [[table]] element, -1 for a plain one).

def pk_peek(cur: Cursor) -> str {
    let s = cur.s;
    let p = cur.p;
    s[p:p + 1]
};

def pk_skip(cur: Cursor) -> void {
    let s = cur.s;
    let p = cur.p;
    while (p < len(s) && (s[p] == 32 || s[p] == 9)) {
        p = p + 1;
    };
    cur.p = p;
    p
};

def pk_keych(c: long) -> bool {
    (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_' || c == '-'
};

// A bare key: letters, digits, `_` and `-`.
def pk_is_key(s: str) -> bool {
    let ok = len(s) > 0;
    let i = 0;
    while (ok && i < len(s)) {
        ok = pk_keych(s[i]);
        i++;
    };
    ok
};

// A Y identifier: what a package's name must be (`import name;`).
def pk_is_ident(s: str) -> bool {
    let ok = pk_is_key(s) && index_of(s, "-") < 0;
    if (ok) {
        let c = s[0];
        ok = c < '0' || c > '9';
    }
    ok
};

// The lexer's keywords: a package so named could not be used, as `let.f()`
// does not parse.
def pk_is_kw(s: str) -> bool {
    s in ["let", "const", "def", "if", "else", "while"]
        || s == "for" || s == "foreach" || s == "in" || s == "return" || s == "true" || s == "false"
};

// The line up to its comment (a `#` outside a string).
def pk_uncomment(line: str) -> str {
    let q = "";
    let end = len(line);
    for i in 0..end {
        let c = line[i:i + 1];
        if (len(q) > 0) {
            if (c == "\\" && q == "\"") {
                i++;
            } else if (c == q) {
                q = "";
            }
        } else if (c == "\"" || c == "'") {
            q = c;
        } else if (c == "#") {
            end = i;
        }
    };
    line[:end]
};

def pk_qstr(cur: Cursor, at: str) -> str {
    pk_skip(cur);
    let s = cur.s;
    let p = cur.p;
    let q = s[p:p + 1];
    let out: [str] = [];
    if (q != "\"" && q != "'") {
        pk_die(at + "expected a string");
    }
    p = p + 1;
    let go = true;
    while (go) {
        if (p >= len(s)) {
            pk_die(at + "unterminated string");
            go = false;
        } else {
            let c = s[p:p + 1];
            if (c == q) {
                go = false;
            } else if (c == "\\" && q == "\"") {
                let e = s[p + 1:p + 2];
                if (e == "n") {
                    out += "\n";
                } else if (e == "t") {
                    out += "\t";
                } else if (e == "\\" || e == "\"") {
                    out += e;
                } else {
                    pk_die(at + "unknown escape '\\" + e + "' in a string");
                };
                p = p + 1;
            } else {
                out += c;
            };
            p = p + 1;
        };
    };
    cur.p = p;
    join(out, "")
};

def pk_array(cur: Cursor, at: str) -> [str] {
    cur.p = cur.p + 1;
    let out: [str] = [];
    while (true) {
        pk_skip(cur);
        if (pk_peek(cur) == "]") {
            cur.p = cur.p + 1;
            break;
        } else {
            out += pk_qstr(cur, at);
            pk_skip(cur);
            let c = pk_peek(cur);
            if (c == ",") {
                cur.p = cur.p + 1;
            } else if (c == "]") {
                cur.p = cur.p + 1;
                break;
            } else {
                pk_die(at + "expected ',' or ']' in an array");
                break;
            };
        };
    };
    out
};

def pk_bare(cur: Cursor, at: str) -> str {
    pk_skip(cur);
    let s = cur.s;
    let p = cur.p;
    while (p < len(s) && pk_keych(s[p])) {
        p = p + 1;
    };
    let key = s[cur.p:p];
    if (len(key) == 0) { pk_die(at + "expected a key"); }
    cur.p = p;
    key
};

def pk_itable(cur: Cursor, at: str) -> { keys: [str], vals: [str] } {
    cur.p = cur.p + 1;
    let keys: [str] = [];
    let vals: [str] = [];
    pk_skip(cur);
    let go = true;
    if (pk_peek(cur) == "}") {
        cur.p = cur.p + 1;
        go = false;
    }
    while (go) {
        let key = pk_bare(cur, at);
        pk_skip(cur);
        if (pk_peek(cur) != "=") { pk_die(at + "expected '=' after '" + key + "'"); }
        cur.p = cur.p + 1;
        if (pk_has(keys, key)) { pk_die(at + "duplicate key '" + key + "'"); }
        keys += key;
        vals += pk_qstr(cur, at);
        pk_skip(cur);
        let c = pk_peek(cur);
        if (c == ",") {
            cur.p = cur.p + 1;
        } else if (c == "}") {
            cur.p = cur.p + 1;
            go = false;
        } else {
            pk_die(at + "expected ',' or '}' in an inline table");
            go = false;
        };
    };
    { keys: keys, vals: vals }
};

def pk_count(xs: [str], s: str) -> long {
    let n = 0;
    xs.foreach((e) => {
        let x: str = e;
        if (x == s) { n++; }
    });
    n
};

// The entries of TOML text `text` (from file `path`, for the messages).
def pk_toml(text: str, path: str) -> [PkEnt] {
    let out: [PkEnt] = [];
    let lines = split(text, "\n");
    let tab = "";
    let n = -1;
    let arrs: [str] = [];
    let tabs: [str] = [];
    let seen: [str] = [];
    lines.foreach((el, i) => {
        let ln = i + 1;
        let at = path + ":" + tostring(ln) + ": ";
        let line = trim(pk_uncomment(el));
        let e = { tab: tab, n: n, key: "", line: ln, k: K.h, s: "", keys: pk_nostrs(), items: pk_nostrs() };
        if (len(line) == 0) {
        } else if (line[:1] == "[") {
            let w = 1;
            if (line[:2] == "[[") { w = 2; }
            let close = "]";
            if (w == 2) { close = "]]"; }
            if (len(line) < 2 * w || line[len(line) - w:] != close) {
                pk_die(at + "expected '" + close + "' after the table name");
            }
            tab = trim(line[w:len(line) - w]);
            if (!pk_is_key(tab)) { pk_die(at + "bad table name '" + tab + "'"); }
            if (w == 2) {
                n = pk_count(arrs, tab);
                arrs += tab;
            } else {
                if (pk_has(tabs, tab)) { pk_die(at + "table [" + tab + "] appears twice"); }
                tabs += tab;
                n = -1;
            };
            e.tab = tab;
            e.n = n;
            out += e;
        } else {
            let eq = index_of(line, "=");
            if (eq < 0) { pk_die(at + "expected 'key = value'"); }
            let key = trim(line[:eq]);
            if (!pk_is_key(key)) { pk_die(at + "bad key '" + key + "'"); }
            let id = tab + "\n" + tostring(n) + "\n" + key;
            if (pk_has(seen, id)) { pk_die(at + "duplicate key '" + key + "'"); }
            seen += id;
            let cur = { s: trim(line[eq + 1:]), p: 0 };
            e.key = key;
            let c = pk_peek(cur);
            if (c == "[") {
                e.k = K.a;
                e.items = pk_array(cur, at);
            } else if (c == "{") {
                e.k = K.t;
                let t = pk_itable(cur, at);
                e.keys = t.keys;
                e.items = t.vals;
            } else if (c == "\"" || c == "'") {
                e.k = K.s;
                e.s = pk_qstr(cur, at);
            } else {
                pk_die(at + "expected a string, an array or an inline table after '='");
            };
            pk_skip(cur);
            if (cur.p < len(cur.s)) { pk_die(at + "unexpected text after the value"); }
            out += e;
        };
    });
    out
};

// TOML text for the string `s`.
def pk_tq(s: str) -> str {
    let t = join(split(s, "\\"), "\\\\");
    t = join(split(t, "\""), "\\\"");
    t = join(split(t, "\n"), "\\n");
    "\"" + join(split(t, "\t"), "\\t") + "\""
};

def pk_want_str(e: PkEnt, at: str) -> str {
    if (e.k != K.s) { pk_die(at + "'" + e.key + "' must be a string"); }
    e.s
};

// The manifest in directory `dir`.
def pk_manifest(dir: str) -> PkMan {
    let file = pk_join(dir, "y.toml");
    let txt = fs.read_file(file);
    if (txt == none) { pk_die("cannot read '" + file + "'"); }
    let ents = pk_toml(unwrap(txt), file);
    let bins: [PkBin] = [];
    let deps: [PkDep] = [];
    let m = { file: file, name: "", lib: "", roots: pk_nostrs(), bins: bins, deps: deps };
    ents.foreach((el) => {
        let e = el;
        let at = file + ":" + tostring(e.line) + ": ";
        let tab = e.tab;
        if (e.n >= 0) {
            pk_die(at + "[[" + tab + "]] has no place in a manifest");
        } else if (e.k == K.h) {
            if (tab != "package" && tab != "bin" && tab != "dependencies") {
                pk_die(at + "unknown table [" + tab + "]");
            }
        } else if (tab == "package") {
            pk_man_package(m, e, at);
        } else if (tab == "bin") {
            let bn = e.key;
            if (bn == "obj" || bn == "git") {
                pk_die(at + "'" + bn + "' cannot name a bin: build/" + bn + " is ycc's own");
            }
            m.bins += { name: bn, path: pk_want_str(e, at) };
        } else if (tab == "dependencies") {
            m.deps += pk_man_dep(e, at);
        } else {
            pk_die(at + "'" + e.key + "' is outside any table");
        };
    });
    if (len(m.name) == 0) { pk_die(file + ": [package] has no name"); }
    m
};

def pk_man_package(m: PkMan, e: PkEnt, at: str) -> void {
    let key = e.key;
    if (key == "name") {
        let nm = pk_want_str(e, at);
        if (!pk_is_ident(nm)) { pk_die(at + "package name '" + nm + "' is not an identifier"); }
        if (pk_is_kw(nm)) { pk_die(at + "package name '" + nm + "' is a keyword"); }
        m.name = nm;
    } else if (key == "lib") {
        m.lib = pk_want_str(e, at);
    } else if (key == "src") {
        if (e.k != K.a) { pk_die(at + "'src' must be an array of strings"); }
        m.roots = e.items;
    } else if (key in ["version", "description", "license", "authors"]) {
    } else {
        pk_die(at + "unknown key '" + key + "' in [package]");
    };
    0
};

def pk_man_dep(e: PkEnt, at: str) -> PkDep {
    let nm = e.key;
    if (!pk_is_ident(nm)) { pk_die(at + "dependency name '" + nm + "' is not an identifier"); }
    if (pk_is_kw(nm)) { pk_die(at + "dependency name '" + nm + "' is a keyword"); }
    let d = { name: nm, path: "", git: "", rev: "" };
    let ks = e.keys;
    let vs = e.items;
    ks.foreach((e, i) => {
        let k: str = e;
        let v: str = vs[i];
        if (k == "path") {
            d.path = v;
        } else if (k == "git") {
            d.git = v;
        } else if (k == "rev") {
            d.rev = v;
        } else {
            pk_die(at + "unknown key '" + k + "' in dependency '" + nm + "'");
        };
    });
    if (e.k != K.t || (len(d.path) == 0 && len(d.git) == 0)) {
        pk_die(at + "dependency '" + nm + "' must be { path = \"...\" } or { git = \"...\", rev = \"...\" }");
    } else if (len(d.path) > 0 && len(d.git) > 0) {
        pk_die(at + "dependency '" + nm + "' has both a path and a git");
    } else if (len(d.rev) > 0 && len(d.git) == 0) {
        pk_die(at + "dependency '" + nm + "' has a rev but no git");
    }
    d
};

// ── the dependency graph ────────────────────────────────────────────────
// Every package the project depends on, directly or not, each after the
// packages it depends on, and then the project's own lib (if any). A
// name stands for one package: two different sources of one name are an
// error -- unless the project itself names it, which settles it.

// Where a dependency comes from, as the messages show it.
def pk_src(d: PkDep, fdir: str) -> str {
    if (len(d.git) > 0) {
        if (len(d.rev) > 0) { d.git + " " + d.rev } else { d.git }
    } else {
        pk_join(fdir, d.path)
    }
};

def pk_dep_names(ds: [PkDep]) -> [str] {
    let out: [str] = [];
    ds.foreach((e) => {
        let d = e;
        out += d.name;
    });
    out
};

def pk_roots(dir: str, roots: [str]) -> [str] {
    let out: [str] = [];
    roots.foreach((e) => {
        out += pk_join(dir, e);
    });
    out
};

// The project in directory `dir`: its manifest, and every package it
// depends on (fetched when they are git ones; y.lock updated).
def pk_load(dir: str) -> PkGraph {
    let m = pk_manifest(dir);
    let decls: [PkDecl] = [];
    let nodes: [PkNode] = [];
    let st = { root: m.name, rdir: dir, decls: decls, done: pk_nostrs(), stack: [m.name], nodes: nodes, lock: pk_lock_read(dir) };
    let ds = m.deps;
    let i = 0;
    while (i < len(ds)) {
        let d = ds[i];
        st.decls += { name: d.name, src: pk_src(d, dir), by: m.name, dep: d, fdir: dir };
        i++;
    };
    i = 0;
    while (i < len(ds)) {
        pk_visit(st, ds[i], m.name, dir);
        i++;
    };
    let roots = pk_roots(dir, m.roots);
    let lib = "";
    if (len(m.lib) > 0) {
        lib = pk_join(dir, m.lib);
        st.nodes += { name: m.name, dir: dir, lib: lib, roots: roots, deps: pk_dep_names(ds), git: "", rev: "", commit: "" };
    }
    pk_lock_write(dir, st.nodes);
    let bins: [PkBin] = [];
    let mb = m.bins;
    i = 0;
    while (i < len(mb)) {
        let b = mb[i];
        bins += { name: b.name, path: pk_join(dir, b.path) };
        i++;
    };
    { dir: dir, name: m.name, lib: lib, roots: roots, bins: bins, deps: pk_dep_names(ds), pkgs: st.nodes }
};

// Dependency `d0` of package `by` (whose manifest is in `fdir0`), and
// then the packages it depends on.
def pk_visit(st: PkSt, d0: PkDep, by: str, fdir0: str) -> void {
    let d = d0;
    let fdir = fdir0;
    let src = pk_src(d, fdir);
    let ds = st.decls;
    let k = 0;
    while (k < len(ds) && pk_decl_name(ds[k]) != d.name) {
        k++;
    };
    if (k < len(ds)) {
        let e = ds[k];
        if (e.src != src) {
            if (e.by == st.root) {
                d = e.dep;
                fdir = e.fdir;
            } else {
                pk_die("package '" + d.name + "' comes from two places: " + e.src + " (for " + e.by + ") and " + src + " (for " + by + ")");
            };
        }
    } else {
        st.decls += { name: d.name, src: src, by: by, dep: d, fdir: fdir };
    };
    if (pk_has(st.stack, d.name)) {
        pk_die("dependency cycle: " + join(st.stack, " -> ") + " -> " + d.name);
    } else if (!pk_has(st.done, d.name)) {
        let at = { dir: "", commit: "" };
        at = len(d.git) > 0 ? pk_git_dir(st, d) : { dir: pk_join(fdir, d.path), commit: "" };
        let m = pk_manifest(at.dir);
        if (m.name != d.name) {
            pk_die("dependency '" + d.name + "' (" + pk_src(d, fdir) + ") is package '" + m.name + "'");
        } else if (len(m.lib) == 0) {
            pk_die("package '" + m.name + "' (" + pk_src(d, fdir) + ") has no lib to import");
        }
        st.stack += d.name;
        let mds = m.deps;
        mds.foreach((e) => {
            pk_visit(st, e, m.name, at.dir);
        });
        let stk = st.stack;
        st.stack = stk[:len(stk) - 1];
        st.done += d.name;
        st.nodes += { name: m.name, dir: at.dir, lib: pk_join(at.dir, m.lib), roots: pk_roots(at.dir, m.roots), deps: pk_dep_names(mds), git: d.git, rev: d.rev, commit: at.commit };
    }
    0
};

def pk_decl_name(e: PkDecl) -> str {
    e.name
};

// ── git dependencies ────────────────────────────────────────────────────
// vendor/NAME when it holds the package; else the clone of the commit
// y.lock pins (build/git/NAME-COMMIT), cloned when it is not there yet;
// else a fresh clone of `rev` (the default branch without one), which
// y.lock then pins.

def pk_git_dir(st: PkSt, d: PkDep) -> PkGit {
    let pin = pk_lock_find(st.lock, d);
    let vdir = pk_join(st.rdir, "vendor/" + d.name);
    if (pk_is_file(vdir + "/y.toml")) {
        { dir: vdir, commit: pin }
    } else {
        let base = pk_join(st.rdir, "build/git");
        let cdir = base + "/" + d.name + "-" + pin;
        if (len(pin) > 0 && pk_is_file(cdir + "/y.toml")) {
            { dir: cdir, commit: pin }
        } else {
            pk_fetch(d, base, pin)
        }
    }
};

// `s` quoted for sh.
def pk_q(s: str) -> str {
    "'" + join(split(s, "'"), "'\\''") + "'"
};

// exec() runs sh with no environment at all: git wants this one's (HOME,
// proxies, credentials), so a command starts by exporting it.
def pk_env() -> str {
    if let some(t) = fs.read_file("/proc/self/environ") {

        let s = t;
        let out: [str] = [];
        let start = 0;
        for i in 0..len(s) + 1 {
        if (i == len(s) || s[i] == 0) {
        let kv = s[start:i];
        let eq = index_of(kv, "=");
        if (eq > 0 && pk_is_ident(kv[:eq])) {
        out += "export " + kv[:eq] + "=" + pk_q(kv[eq + 1:]) + "; ";
        }
        start = i + 1;
        }
        };
        join(out, "")

    } else {

        ""

    }
};

def pk_fetch(d: PkDep, base: str, pin: str) -> PkGit {
    let tmp = base + "/" + d.name + ".tmp";
    let want = pin;
    if (len(want) == 0) { want = d.rev; }
    let cmd = pk_env() + "mkdir -p " + pk_q(base) + " && rm -rf " + pk_q(tmp) + " && git clone --quiet " + pk_q(d.git) + " " + pk_q(tmp) + " && cd " + pk_q(tmp);
    if (len(want) > 0) { cmd = cmd + " && git -c advice.detachedHead=false checkout --quiet " + pk_q(want); }
    cmd = cmd + " && git rev-parse HEAD > .git/ycc-commit";
    eputs("fetching " + d.name + " (" + d.git + ")\n");
    if (exec(cmd) != 0) { pk_die("fetching '" + d.name + "' from " + d.git + " failed"); }
    let ct = fs.read_file(tmp + "/.git/ycc-commit");
    let commit = "";
    if (ct != none) { commit = trim(unwrap(ct)); }
    let dest = base + "/" + d.name + "-" + commit;
    let mv = "rm -rf " + pk_q(tmp);
    if (!pk_is_file(dest + "/y.toml")) { mv = "rm -rf " + pk_q(dest) + " && mv " + pk_q(tmp) + " " + pk_q(dest); }
    if (len(commit) == 0 || exec(pk_env() + mv) != 0) { pk_die("fetching '" + d.name + "' from " + d.git + " failed"); }
    { dir: dest, commit: commit }
};

// ── y.lock ──────────────────────────────────────────────────────────────

def pk_lock_read(dir: str) -> [PkLock] {
    let out: [PkLock] = [];
    let file = pk_join(dir, "y.lock");
    let txt = fs.read_file(file);
    if (txt != none) {
        let ents = pk_toml(unwrap(txt), file);
        ents.foreach((el) => {
            let e = el;
            if (e.tab == "package" && e.n >= 0) {
                while (len(out) <= e.n) {
                    out += { name: "", git: "", rev: "", commit: "" };
                };
                let lk = out[e.n];
                let key = e.key;
                if (e.k != K.s) {
                } else if (key == "name") {
                    lk.name = e.s;
                } else if (key == "git") {
                    lk.git = e.s;
                } else if (key == "rev") {
                    lk.rev = e.s;
                } else if (key == "commit") {
                    lk.commit = e.s;
                }
            }
        });
    }
    out
};

// The commit y.lock pins `d` to ("" when it pins none: the entry must
// match its git and rev too).
def pk_lock_find(locks: [PkLock], d: PkDep) -> str {
    let out = "";
    locks.foreach((e) => {
        let lk = e;
        if (lk.name == d.name && lk.git == d.git && lk.rev == d.rev) { out = lk.commit; }
    });
    out
};

// y.lock for the git packages among `nodes` (written only when that
// changes it; never for a project without any).
def pk_lock_write(dir: str, nodes: [PkNode]) -> void {
    let out: [str] = [];
    out += "# y.lock -- written by `ycc build`: the commit each git dependency\n";
    out += "# resolved to. Delete an entry to move it to its rev again.\n";
    let any = false;
    nodes.foreach((e) => {
        let p = e;
        if (len(p.git) > 0 && len(p.commit) > 0) {
            out += "\n[[package]]\nname = " + pk_tq(p.name) + "\ngit = " + pk_tq(p.git) + "\nrev = " + pk_tq(p.rev) + "\ncommit = " + pk_tq(p.commit) + "\n";
            any = true;
        }
    });
    if (any) {
        let text = join(out, "");
        let file = pk_join(dir, "y.lock");
        let old = fs.read_file(file);
        let same = false;
        if (old != none) { same = unwrap(old) == text; }
        if (!same && !fs.write_file(file, text)) { pk_die("writing '" + file + "' failed"); }
    }
    0
};

// ── ycc vendor ──────────────────────────────────────────────────────────

def pk_vendor(dir: str) -> void {
    let g = pk_load(dir);
    let ps = g.pkgs;
    let n = 0;
    ps.foreach((e) => {
        let p = e;
        if (len(p.git) > 0) {
            let vd = pk_join(dir, "vendor/" + p.name);
            if (p.dir != vd) {
                let cmd = pk_env() + "mkdir -p " + pk_q(pk_join(dir, "vendor")) + " && rm -rf " + pk_q(vd) + " && cp -R " + pk_q(p.dir) + " " + pk_q(vd) + " && rm -rf " + pk_q(vd + "/.git");
                if (exec(cmd) != 0) { pk_die("vendoring '" + p.name + "' failed"); }
            }
            eputs("vendored " + p.name + " (" + vd + ")\n");
            n++;
        }
    });
    if (n == 0) { eputs("nothing to vendor: no git dependencies\n"); }
    0
};

// ── hashing (the object cache's keys) ───────────────────────────────────
// Two lanes, each a polynomial hash of the input's 4-byte words modulo a
// prime near 2^31 (so a lane times 2^32 plus a word stays below 2^63).

def pk_hash_new() -> PkHash {
    { a: 1, b: 7 }
};

def pk_mix(h: PkHash, x: long) -> void {
    h.a = (h.a * 4294967296 + x) % 2147483647;
    h.b = (h.b * 4294967296 + x) % 2147483629;
    0
};

def pk_hash_str(h: PkHash, s: str) -> void {
    let n = len(s);
    pk_mix(h, n);
    let i = 0;
    while (i + 4 <= n) {
        pk_mix(h, s[i] + s[i + 1] * 256 + s[i + 2] * 65536 + s[i + 3] * 16777216);
        i += 4;
    };
    let x = 0;
    let m = 1;
    while (i < n) {
        x += s[i] * m;
        m *= 256;
        i++;
    };
    pk_mix(h, x);
    0
};

def pk_hash_text(h: PkHash) -> str {
    tostring(h.a) + "-" + tostring(h.b)
};

// This compiler, as a hash of its own binary: an object another ycc
// wrote is no hit.
def pk_self_id() -> str {
    let t = fs.read_file("/proc/self/exe");
    if (t == none) { pk_die("cannot read the compiler's own binary (/proc/self/exe)"); }
    let h = pk_hash_new();
    pk_hash_str(h, unwrap(t));
    pk_hash_text(h)
};

export { pk_load, pk_vendor, pk_join, pk_dir_of, pk_mkdir, pk_has, pk_hash_new, pk_hash_str, pk_hash_text, pk_self_id };
