/* pkg.c — packages, the 1:1 port of src/y/pkg.y (see PORTING.md). */
#include "pkg.h"

#include <fcntl.h>
#include <stdarg.h>
#include <sys/syscall.h>
#include <unistd.h>

typedef Yv *PkEnt;
typedef Yv *PkDep;
typedef Yv *PkBin;
typedef Yv *PkMan;
typedef Yv *PkLock;
typedef Yv *PkNode;
typedef Yv *PkDecl;
typedef Yv *PkSt;
typedef Yv *PkGraph;
typedef Yv *PkGit;
typedef Yv *PkHash;
/* lexer.y's alias (pkg.y imports it for that) */
typedef Yv *Cursor;

/* ── module-local defs (forward) ─────────────────────────────────────── */
static Yv *pk_cat(size_t n, ...);
static long pk_die(Yv *msg);
static Yv *pk_nostrs(void);
static Yv *pk_clean(Yv *path);
static int pk_is_dir(Yv *path);
static int pk_is_file(Yv *path);
static Yv *pk_peek(Cursor cur);
static long pk_skip(Cursor cur);
static int pk_keych(long c);
static int pk_is_key(Yv *s);
static int pk_is_ident(Yv *s);
static int pk_is_kw(Yv *s);
static Yv *pk_uncomment(Yv *line);
static Yv *pk_qstr(Cursor cur, Yv *at);
static Yv *pk_array(Cursor cur, Yv *at);
static Yv *pk_bare(Cursor cur, Yv *at);
static Yv *pk_itable(Cursor cur, Yv *at);
static long pk_count(Yv *xs, Yv *s);
static Yv *pk_toml(Yv *text, Yv *path);
static Yv *pk_tq(Yv *s);
static Yv *pk_want_str(Yv *e, Yv *at);
static PkMan pk_manifest(Yv *dir);
static long pk_man_package(PkMan m, PkEnt e, Yv *at);
static PkDep pk_man_dep(PkEnt e, Yv *at);
static Yv *pk_src(PkDep d, Yv *fdir);
static Yv *pk_dep_names(Yv *ds);
static Yv *pk_roots(Yv *dir, Yv *roots);
static long pk_visit(PkSt st, PkDep d0, Yv *by, Yv *fdir0);
static Yv *pk_decl_name(PkDecl e);
static PkGit pk_git_dir(PkSt st, PkDep d);
static Yv *pk_q(Yv *s);
static Yv *pk_env(void);
static Yv *pk_read_environ(void);
static long pk_exec(Yv *cmd);
static long pk_exit_status(long raw);
static PkGit pk_fetch(PkDep d, Yv *base, Yv *pin);
static Yv *pk_lock_read(Yv *dir);
static Yv *pk_lock_find(Yv *locks, PkDep d);
static long pk_lock_write(Yv *dir, Yv *nodes);
static long pk_mix(PkHash h, long x);

static Yv *pk_cat(size_t n, ...) {
    va_list ap;
    va_start(ap, n);
    if (n == 0) {
        va_end(ap);
        return ys("");
    }
    Yv *out = va_arg(ap, Yv *);
    for (size_t i = 1; i < n; i++) {
        out = ys_cat(out, va_arg(ap, Yv *));
    }
    va_end(ap);
    return out;
}

static long pk_die(Yv *msg) {
    puts_(pk_cat(3, ys("error: "), msg, ys("\n")));
    exit_(1);
    return 1;
}

int pk_has(Yv *xs, Yv *s) {
    int found = 0;
    long i = 0;
    while (!found && i < yv_len(xs)) {
        Yv *x = ya_get(xs, i);
        found = ys_eq(x, s);
        i = i + 1;
    }
    return found;
}

static Yv *pk_nostrs(void) {
    return yav(0);
}

/* ── paths and files ─────────────────────────────────────────────────── */

static Yv *pk_clean(Yv *path) {
    int abs = ys_eq_lit(ys_slice(path, 0, 1), "/");
    Yv *parts = ys_split(path, ys("/"));
    Yv *out = yav(0);
    long i = 0;
    while (i < yv_len(parts)) {
        Yv *s = ya_get(parts, i);
        if (ys_eq_lit(s, "") || ys_eq_lit(s, ".")) {
            ;
        } else if (ys_eq_lit(s, "..")) {
            long n = yv_len(out);
            if (n > 0 && !ys_eq_lit(ya_get(out, n - 1), "..")) {
                out = ya_slice(out, 0, n - 1);
                ;
            } else if (!abs) {
                out = ya_push(out, s);
                ;
            } else {
                ;
            }
            ;
        } else {
            out = ya_push(out, s);
            ;
        }
        i = i + 1;
    }
    Yv *r = ys_join(out, ys("/"));
    if (abs) {
        return ys_cat(ys("/"), r);
    } else if (yv_len(r) == 0) {
        return ys(".");
    } else {
        return r;
    }
}

Yv *pk_join(Yv *dir, Yv *p) {
    if (ys_eq_lit(ys_slice(p, 0, 1), "/")) {
        return pk_clean(p);
    } else {
        return pk_clean(ys_cat(ys_cat(dir, ys("/")), p));
    }
}

Yv *pk_dir_of(Yv *path) {
    long i = ys_last_index_of(path, ys("/"));
    if (i < 0) {
        return ys(".");
    } else if (i == 0) {
        return ys("/");
    } else {
        return ys_slice(path, 0, i);
    }
}

static int pk_is_dir(Yv *path) {
    long fd = syscall(SYS_openat, AT_FDCWD, path->u.s.p, O_DIRECTORY, 0);
    if (fd >= 0) {
        (void)syscall(SYS_close, fd);
        return 1;
    } else {
        return 0;
    }
}

static int pk_is_file(Yv *path) {
    long fd = syscall(SYS_openat, AT_FDCWD, path->u.s.p, 0, 0);
    if (fd >= 0) {
        (void)syscall(SYS_close, fd);
        return !pk_is_dir(path);
    } else {
        return 0;
    }
}

long pk_mkdir(Yv *path) {
    (void)syscall(SYS_mkdir, path->u.s.p, 493L);
    if (!pk_is_dir(path)) {
        (void)pk_die(pk_cat(3, ys("cannot create directory '"), path,
                            ys("'")));
    } else {
        ;
    }
    return 0;
}

/* ── the manifest: a TOML subset ─────────────────────────────────────── */

static Yv *pk_peek(Cursor cur) {
    Yv *s = yr_get(cur, "s");
    long p = yv_l(yr_get(cur, "p"));
    return ys_slice(s, p, p + 1);
}

static long pk_skip(Cursor cur) {
    Yv *s = yr_get(cur, "s");
    long p = yv_l(yr_get(cur, "p"));
    while (p < yv_len(s) &&
           (ys_byte_at(s, p) == 32 || ys_byte_at(s, p) == 9)) {
        p = p + 1;
    }
    (void)yr_set(cur, "p", yv_long(p));
    return p;
}

static int pk_keych(long c) {
    return (c >= 97 && c <= 122) || (c >= 65 && c <= 90) ||
           (c >= 48 && c <= 57) || c == 95 || c == 45;
}

static int pk_is_key(Yv *s) {
    int ok = yv_len(s) > 0;
    long i = 0;
    while (ok && i < yv_len(s)) {
        ok = pk_keych(ys_byte_at(s, i));
        i = i + 1;
    }
    return ok;
}

static int pk_is_ident(Yv *s) {
    int ok = pk_is_key(s) && ys_index_of(s, ys("-")) < 0;
    if (ok) {
        long c = ys_byte_at(s, 0);
        ok = c < 48 || c > 57;
        ;
    } else {
        ;
    }
    return ok;
}

static int pk_is_kw(Yv *s) {
    return ys_eq_lit(s, "let") || ys_eq_lit(s, "const") ||
           ys_eq_lit(s, "def") || ys_eq_lit(s, "if") ||
           ys_eq_lit(s, "else") || ys_eq_lit(s, "while") ||
           ys_eq_lit(s, "for") || ys_eq_lit(s, "foreach") ||
           ys_eq_lit(s, "in") || ys_eq_lit(s, "return") ||
           ys_eq_lit(s, "true") || ys_eq_lit(s, "false");
}

static Yv *pk_uncomment(Yv *line) {
    Yv *q = ys("");
    long end = yv_len(line);
    long i = 0;
    while (i < end) {
        Yv *c = ys_slice(line, i, i + 1);
        if (yv_len(q) > 0) {
            if (ys_eq_lit(c, "\\") && ys_eq_lit(q, "\"")) {
                i = i + 1;
                ;
            } else if (ys_eq(c, q)) {
                q = ys("");
                ;
            } else {
                ;
            }
            ;
        } else if (ys_eq_lit(c, "\"") || ys_eq_lit(c, "'")) {
            q = c;
            ;
        } else if (ys_eq_lit(c, "#")) {
            end = i;
            ;
        } else {
            ;
        }
        i = i + 1;
    }
    return ys_slice(line, 0, end);
}

static Yv *pk_qstr(Cursor cur, Yv *at) {
    (void)pk_skip(cur);
    Yv *s = yr_get(cur, "s");
    long p = yv_l(yr_get(cur, "p"));
    Yv *q = ys_slice(s, p, p + 1);
    Yv *out = yav(0);
    if (!ys_eq_lit(q, "\"") && !ys_eq_lit(q, "'")) {
        (void)pk_die(ys_cat(at, ys("expected a string")));
        ;
    } else {
        ;
    }
    p = p + 1;
    int go = 1;
    while (go) {
        if (p >= yv_len(s)) {
            (void)pk_die(ys_cat(at, ys("unterminated string")));
            go = 0;
            ;
        } else {
            Yv *c = ys_slice(s, p, p + 1);
            if (ys_eq(c, q)) {
                go = 0;
                ;
            } else if (ys_eq_lit(c, "\\") && ys_eq_lit(q, "\"")) {
                Yv *e = ys_slice(s, p + 1, p + 2);
                if (ys_eq_lit(e, "n")) {
                    out = ya_push(out, ys("\n"));
                    ;
                } else if (ys_eq_lit(e, "t")) {
                    out = ya_push(out, ys("\t"));
                    ;
                } else if (ys_eq_lit(e, "\\") || ys_eq_lit(e, "\"")) {
                    out = ya_push(out, e);
                    ;
                } else {
                    (void)pk_die(pk_cat(4, at, ys("unknown escape '\\"), e,
                                        ys("' in a string")));
                    ;
                }
                p = p + 1;
                ;
            } else {
                out = ya_push(out, c);
                ;
            }
            p = p + 1;
            ;
        }
    }
    (void)yr_set(cur, "p", yv_long(p));
    return ys_join(out, ys(""));
}

static Yv *pk_array(Cursor cur, Yv *at) {
    (void)yr_set(cur, "p", yv_long(yv_l(yr_get(cur, "p")) + 1));
    Yv *out = yav(0);
    int go = 1;
    while (go) {
        (void)pk_skip(cur);
        if (ys_eq_lit(pk_peek(cur), "]")) {
            (void)yr_set(cur, "p", yv_long(yv_l(yr_get(cur, "p")) + 1));
            go = 0;
            ;
        } else {
            out = ya_push(out, pk_qstr(cur, at));
            (void)pk_skip(cur);
            Yv *c = pk_peek(cur);
            if (ys_eq_lit(c, ",")) {
                (void)yr_set(cur, "p", yv_long(yv_l(yr_get(cur, "p")) + 1));
                ;
            } else if (ys_eq_lit(c, "]")) {
                (void)yr_set(cur, "p", yv_long(yv_l(yr_get(cur, "p")) + 1));
                go = 0;
                ;
            } else {
                (void)pk_die(ys_cat(at, ys("expected ',' or ']' in an array")));
                go = 0;
                ;
            }
            ;
        }
    }
    return out;
}

static Yv *pk_bare(Cursor cur, Yv *at) {
    (void)pk_skip(cur);
    Yv *s = yr_get(cur, "s");
    long p = yv_l(yr_get(cur, "p"));
    while (p < yv_len(s) && pk_keych(ys_byte_at(s, p))) {
        p = p + 1;
    }
    Yv *key = ys_slice(s, yv_l(yr_get(cur, "p")), p);
    if (yv_len(key) == 0) {
        (void)pk_die(ys_cat(at, ys("expected a key")));
        ;
    } else {
        ;
    }
    (void)yr_set(cur, "p", yv_long(p));
    return key;
}

static Yv *pk_itable(Cursor cur, Yv *at) {
    (void)yr_set(cur, "p", yv_long(yv_l(yr_get(cur, "p")) + 1));
    Yv *keys = yav(0);
    Yv *vals = yav(0);
    (void)pk_skip(cur);
    int go = 1;
    if (ys_eq_lit(pk_peek(cur), "}")) {
        (void)yr_set(cur, "p", yv_long(yv_l(yr_get(cur, "p")) + 1));
        go = 0;
        ;
    } else {
        ;
    }
    while (go) {
        Yv *key = pk_bare(cur, at);
        (void)pk_skip(cur);
        if (!ys_eq_lit(pk_peek(cur), "=")) {
            (void)pk_die(pk_cat(4, at, ys("expected '=' after '"), key,
                                ys("'")));
            ;
        } else {
            ;
        }
        (void)yr_set(cur, "p", yv_long(yv_l(yr_get(cur, "p")) + 1));
        if (pk_has(keys, key)) {
            (void)pk_die(pk_cat(4, at, ys("duplicate key '"), key, ys("'")));
            ;
        } else {
            ;
        }
        keys = ya_push(keys, key);
        vals = ya_push(vals, pk_qstr(cur, at));
        (void)pk_skip(cur);
        Yv *c = pk_peek(cur);
        if (ys_eq_lit(c, ",")) {
            (void)yr_set(cur, "p", yv_long(yv_l(yr_get(cur, "p")) + 1));
            ;
        } else if (ys_eq_lit(c, "}")) {
            (void)yr_set(cur, "p", yv_long(yv_l(yr_get(cur, "p")) + 1));
            go = 0;
            ;
        } else {
            (void)pk_die(ys_cat(
                at, ys("expected ',' or '}' in an inline table")));
            go = 0;
            ;
        }
    }
    return yr(2, "keys", keys, "vals", vals);
}

static long pk_count(Yv *xs, Yv *s) {
    long n = 0;
    long i = 0;
    while (i < yv_len(xs)) {
        Yv *x = ya_get(xs, i);
        if (ys_eq(x, s)) {
            n = n + 1;
            ;
        } else {
            ;
        }
        i = i + 1;
    }
    return n;
}

/* The entries of TOML text `text` (from file `path`, for the messages). */
static Yv *pk_toml(Yv *text, Yv *path) {
    Yv *out = yav(0);
    Yv *lines = ys_split(text, ys("\n"));
    Yv *tab = ys("");
    long n = -1;
    Yv *arrs = yav(0);
    Yv *tabs = yav(0);
    Yv *seen = yav(0);
    long i = 0;
    while (i < yv_len(lines)) {
        long ln = i + 1;
        Yv *at = ys_cat(
            ys_cat(ys_cat(path, ys(":")), ys_tostring(yv_long(ln))),
            ys(": "));
        Yv *line = ys_trim(pk_uncomment(ya_get(lines, i)));
        Yv *e = yr(8, "tab", tab, "n", yv_long(n), "key", ys(""),
                   "line", yv_long(ln), "k", ys("h"), "s", ys(""),
                   "keys", pk_nostrs(), "items", pk_nostrs());
        if (yv_len(line) == 0) {
            ;
        } else if (ys_eq_lit(ys_slice(line, 0, 1), "[")) {
            long w = 1;
            if (ys_eq_lit(ys_slice(line, 0, 2), "[[")) {
                w = 2;
                ;
            } else {
                ;
            }
            Yv *close = ys("]");
            if (w == 2) {
                close = ys("]]");
                ;
            } else {
                ;
            }
            if (yv_len(line) < 2 * w ||
                !ys_eq(ys_slice_from(line, yv_len(line) - w), close)) {
                (void)pk_die(pk_cat(4, at, ys("expected '"), close,
                                    ys("' after the table name")));
                ;
            } else {
                ;
            }
            tab = ys_trim(ys_slice(line, w, yv_len(line) - w));
            if (!pk_is_key(tab)) {
                (void)pk_die(pk_cat(4, at, ys("bad table name '"), tab,
                                    ys("'")));
                ;
            } else {
                ;
            }
            if (w == 2) {
                n = pk_count(arrs, tab);
                arrs = ya_push(arrs, tab);
                ;
            } else {
                if (pk_has(tabs, tab)) {
                    (void)pk_die(pk_cat(4, at, ys("table ["), tab,
                                        ys("] appears twice")));
                    ;
                } else {
                    ;
                }
                tabs = ya_push(tabs, tab);
                n = -1;
                ;
            }
            (void)yr_set(e, "tab", tab);
            (void)yr_set(e, "n", yv_long(n));
            out = ya_push(out, e);
            ;
        } else {
            long eq = ys_index_of(line, ys("="));
            if (eq < 0) {
                (void)pk_die(ys_cat(at, ys("expected 'key = value'")));
                ;
            } else {
                ;
            }
            Yv *key = ys_trim(ys_slice(line, 0, eq));
            if (!pk_is_key(key)) {
                (void)pk_die(pk_cat(4, at, ys("bad key '"), key, ys("'")));
                ;
            } else {
                ;
            }
            Yv *id = ys_cat(
                ys_cat(ys_cat(ys_cat(tab, ys("\n")), ys_tostring(yv_long(n))),
                       ys("\n")),
                key);
            if (pk_has(seen, id)) {
                (void)pk_die(ys_cat(
                    ys_cat(ys_cat(at, ys("duplicate key '")), key), ys("'")));
                ;
            } else {
                ;
            }
            seen = ya_push(seen, id);
            Yv *cur = yr(2, "s",
                         ys_trim(ys_slice(line, eq + 1, yv_len(line))),
                         "p", yv_long(0));
            (void)yr_set(e, "key", key);
            Yv *c = pk_peek(cur);
            if (ys_eq_lit(c, "[")) {
                (void)yr_set(e, "k", ys("a"));
                (void)yr_set(e, "items", pk_array(cur, at));
                ;
            } else if (ys_eq_lit(c, "{")) {
                (void)yr_set(e, "k", ys("t"));
                Yv *t = pk_itable(cur, at);
                (void)yr_set(e, "keys", yr_get(t, "keys"));
                (void)yr_set(e, "items", yr_get(t, "vals"));
                ;
            } else if (ys_eq_lit(c, "\"") || ys_eq_lit(c, "'")) {
                (void)yr_set(e, "k", ys("s"));
                (void)yr_set(e, "s", pk_qstr(cur, at));
                ;
            } else {
                (void)pk_die(pk_cat(
                    2, at, ys("expected a string, an array or an inline table after '='")));
                ;
            }
            (void)pk_skip(cur);
            if (yv_l(yr_get(cur, "p")) < yv_len(yr_get(cur, "s"))) {
                (void)pk_die(ys_cat(at, ys("unexpected text after the value")));
                ;
            } else {
                ;
            }
            out = ya_push(out, e);
            ;
        }
        i = i + 1;
    }
    return out;
}

/* TOML text for the string `s`. */
static Yv *pk_tq(Yv *s) {
    Yv *t = ys_join(ys_split(s, ys("\\")), ys("\\\\"));
    t = ys_join(ys_split(t, ys("\"")), ys("\\\""));
    t = ys_join(ys_split(t, ys("\n")), ys("\\n"));
    return ys_cat(ys("\""),
                  ys_cat(ys_join(ys_split(t, ys("\t")), ys("\\t")), ys("\"")));
}

static Yv *pk_want_str(Yv *e, Yv *at) {
    if (!ys_eq_lit(yr_get(e, "k"), "s")) {
        (void)pk_die(pk_cat(4, at, ys("'"), yr_get(e, "key"),
                            ys("' must be a string")));
        ;
    } else {
        ;
    }
    return yr_get(e, "s");
}

/* The manifest in directory `dir`. */
static PkMan pk_manifest(Yv *dir) {
    Yv *file = pk_join(dir, ys("y.toml"));
    Yv *txt = read_file(file);
    if (yv_is_none(txt)) {
        (void)pk_die(pk_cat(3, ys("cannot read '"), file, ys("'")));
        ;
    } else {
        ;
    }
    Yv *ents = pk_toml(yv_unwrap(txt), file);
    Yv *bins = yav(0);
    Yv *deps = yav(0);
    Yv *m = yr(6, "file", file, "name", ys(""), "lib", ys(""),
               "roots", pk_nostrs(), "bins", bins, "deps", deps);
    long i = 0;
    while (i < yv_len(ents)) {
        Yv *e = ya_get(ents, i);
        Yv *at = ys_cat(
            ys_cat(ys_cat(file, ys(":")),
                   ys_tostring(yr_get(e, "line"))),
            ys(": "));
        Yv *tab = yr_get(e, "tab");
        if (yv_l(yr_get(e, "n")) >= 0) {
            (void)pk_die(pk_cat(4, at, ys("[["), tab,
                                ys("]] has no place in a manifest")));
            ;
        } else if (ys_eq_lit(yr_get(e, "k"), "h")) {
            if (!ys_eq_lit(tab, "package") && !ys_eq_lit(tab, "bin") &&
                !ys_eq_lit(tab, "dependencies")) {
                (void)pk_die(pk_cat(4, at, ys("unknown table ["), tab,
                                    ys("]")));
                ;
            } else {
                ;
            }
            ;
        } else if (ys_eq_lit(tab, "package")) {
            (void)pk_man_package(m, e, at);
            ;
        } else if (ys_eq_lit(tab, "bin")) {
            Yv *bn = yr_get(e, "key");
            if (ys_eq_lit(bn, "obj") || ys_eq_lit(bn, "git")) {
                (void)pk_die(pk_cat(6, at, ys("'"), bn,
                                    ys("' cannot name a bin: build/"), bn,
                                    ys(" is ycc's own")));
                ;
            } else {
                ;
            }
            Yv *bin = yr(2, "name", bn, "path", pk_want_str(e, at));
            (void)ya_push(yr_get(m, "bins"), bin);
            ;
        } else if (ys_eq_lit(tab, "dependencies")) {
            (void)ya_push(yr_get(m, "deps"), pk_man_dep(e, at));
            ;
        } else {
            (void)pk_die(pk_cat(4, at, ys("'"), yr_get(e, "key"),
                                ys("' is outside any table")));
            ;
        }
        i = i + 1;
    }
    if (yv_len(yr_get(m, "name")) == 0) {
        (void)pk_die(pk_cat(2, file, ys(": [package] has no name")));
        ;
    } else {
        ;
    }
    return m;
}

static long pk_man_package(PkMan m, PkEnt e, Yv *at) {
    Yv *key = yr_get(e, "key");
    if (ys_eq_lit(key, "name")) {
        Yv *nm = pk_want_str(e, at);
        if (!pk_is_ident(nm)) {
            (void)pk_die(pk_cat(4, at, ys("package name '"), nm,
                                ys("' is not an identifier")));
            ;
        } else {
            ;
        }
        if (pk_is_kw(nm)) {
            (void)pk_die(pk_cat(4, at, ys("package name '"), nm,
                                ys("' is a keyword")));
            ;
        } else {
            ;
        }
        (void)yr_set(m, "name", nm);
        ;
    } else if (ys_eq_lit(key, "lib")) {
        (void)yr_set(m, "lib", pk_want_str(e, at));
        ;
    } else if (ys_eq_lit(key, "src")) {
        if (!ys_eq_lit(yr_get(e, "k"), "a")) {
            (void)pk_die(pk_cat(2, at, ys("'src' must be an array of strings")));
            ;
        } else {
            ;
        }
        (void)yr_set(m, "roots", yr_get(e, "items"));
        ;
    } else if (ys_eq_lit(key, "version") || ys_eq_lit(key, "description") ||
               ys_eq_lit(key, "license") || ys_eq_lit(key, "authors")) {
        ;
    } else {
        (void)pk_die(pk_cat(4, at, ys("unknown key '"), key,
                            ys("' in [package]")));
        ;
    }
    return 0;
}

static PkDep pk_man_dep(PkEnt e, Yv *at) {
    Yv *nm = yr_get(e, "key");
    if (!pk_is_ident(nm)) {
        (void)pk_die(pk_cat(4, at, ys("dependency name '"), nm,
                            ys("' is not an identifier")));
        ;
    } else {
        ;
    }
    if (pk_is_kw(nm)) {
        (void)pk_die(pk_cat(4, at, ys("dependency name '"), nm,
                            ys("' is a keyword")));
        ;
    } else {
        ;
    }
    Yv *d = yr(4, "name", nm, "path", ys(""), "git", ys(""), "rev", ys(""));
    Yv *ks = yr_get(e, "keys");
    Yv *vs = yr_get(e, "items");
    long i = 0;
    while (i < yv_len(ks)) {
        Yv *k = ya_get(ks, i);
        Yv *v = ya_get(vs, i);
        if (ys_eq_lit(k, "path")) {
            (void)yr_set(d, "path", v);
            ;
        } else if (ys_eq_lit(k, "git")) {
            (void)yr_set(d, "git", v);
            ;
        } else if (ys_eq_lit(k, "rev")) {
            (void)yr_set(d, "rev", v);
            ;
        } else {
            (void)pk_die(pk_cat(6, at, ys("unknown key '"), k,
                                ys("' in dependency '"), nm, ys("'")));
            ;
        }
        i = i + 1;
    }
    if (!ys_eq_lit(yr_get(e, "k"), "t") ||
        (yv_len(yr_get(d, "path")) == 0 && yv_len(yr_get(d, "git")) == 0)) {
        (void)pk_die(pk_cat(
            4, at, ys("dependency '"), nm,
            ys("' must be { path = \"...\" } or { git = \"...\", rev = \"...\" }")));
        ;
    } else if (yv_len(yr_get(d, "path")) > 0 &&
               yv_len(yr_get(d, "git")) > 0) {
        (void)pk_die(pk_cat(4, at, ys("dependency '"), nm,
                            ys("' has both a path and a git")));
        ;
    } else if (yv_len(yr_get(d, "rev")) > 0 &&
               yv_len(yr_get(d, "git")) == 0) {
        (void)pk_die(pk_cat(4, at, ys("dependency '"), nm,
                            ys("' has a rev but no git")));
        ;
    } else {
        ;
    }
    return d;
}

/* ── the dependency graph ────────────────────────────────────────────── */

static Yv *pk_src(PkDep d, Yv *fdir) {
    if (yv_len(yr_get(d, "git")) > 0) {
        if (yv_len(yr_get(d, "rev")) > 0) {
            return ys_cat(ys_cat(yr_get(d, "git"), ys(" ")), yr_get(d, "rev"));
        } else {
            return yr_get(d, "git");
        }
    } else {
        return pk_join(fdir, yr_get(d, "path"));
    }
}

static Yv *pk_dep_names(Yv *ds) {
    Yv *out = yav(0);
    long i = 0;
    while (i < yv_len(ds)) {
        Yv *d = ya_get(ds, i);
        out = ya_push(out, yr_get(d, "name"));
        i = i + 1;
    }
    return out;
}

static Yv *pk_roots(Yv *dir, Yv *roots) {
    Yv *out = yav(0);
    long i = 0;
    while (i < yv_len(roots)) {
        out = ya_push(out, pk_join(dir, ya_get(roots, i)));
        i = i + 1;
    }
    return out;
}

/* The project in directory `dir`; git dependencies are fetched as needed. */
Yv *pk_load(Yv *dir) {
    PkMan m = pk_manifest(dir);
    Yv *decls = yav(0);
    Yv *nodes = yav(0);
    PkSt st = yr(7, "root", yr_get(m, "name"), "rdir", dir,
                 "decls", decls, "done", pk_nostrs(),
                 "stack", yav(1, yr_get(m, "name")), "nodes", nodes,
                 "lock", pk_lock_read(dir));
    Yv *ds = yr_get(m, "deps");
    long i = 0;
    while (i < yv_len(ds)) {
        Yv *d = ya_get(ds, i);
        PkDecl decl = yr(5, "name", yr_get(d, "name"),
                         "src", pk_src(d, dir), "by", yr_get(m, "name"),
                         "dep", d, "fdir", dir);
        (void)ya_push(yr_get(st, "decls"), decl);
        i = i + 1;
    }
    i = 0;
    while (i < yv_len(ds)) {
        (void)pk_visit(st, ya_get(ds, i), yr_get(m, "name"), dir);
        i = i + 1;
    }
    Yv *roots = pk_roots(dir, yr_get(m, "roots"));
    Yv *lib = ys("");
    if (yv_len(yr_get(m, "lib")) > 0) {
        lib = pk_join(dir, yr_get(m, "lib"));
        PkNode node = yr(8, "name", yr_get(m, "name"), "dir", dir, "lib", lib,
                         "roots", roots, "deps", pk_dep_names(ds), "git",
                         ys(""), "rev", ys(""), "commit", ys(""));
        (void)ya_push(yr_get(st, "nodes"), node);
        ;
    } else {
        ;
    }
    (void)pk_lock_write(dir, yr_get(st, "nodes"));
    Yv *bins = yav(0);
    Yv *mb = yr_get(m, "bins");
    i = 0;
    while (i < yv_len(mb)) {
        Yv *b = ya_get(mb, i);
        (void)ya_push(
            bins, yr(2, "name", yr_get(b, "name"),
                     "path", pk_join(dir, yr_get(b, "path"))));
        i = i + 1;
    }
    return yr(7, "dir", dir, "name", yr_get(m, "name"), "lib", lib,
              "roots", roots, "bins", bins, "deps", pk_dep_names(ds),
              "pkgs", yr_get(st, "nodes"));
}

/* Dependency `d0` of package `by`, then the packages it depends on. */
static long pk_visit(PkSt st, PkDep d0, Yv *by, Yv *fdir0) {
    PkDep d = d0;
    Yv *fdir = fdir0;
    Yv *src = pk_src(d, fdir);
    Yv *ds = yr_get(st, "decls");
    long k = 0;
    while (k < yv_len(ds) &&
           !ys_eq(pk_decl_name(ya_get(ds, k)), yr_get(d, "name"))) {
        k = k + 1;
    }
    if (k < yv_len(ds)) {
        PkDecl e = ya_get(ds, k);
        if (!ys_eq(yr_get(e, "src"), src)) {
            if (ys_eq(yr_get(e, "by"), yr_get(st, "root"))) {
                d = yr_get(e, "dep");
                fdir = yr_get(e, "fdir");
                ;
            } else {
                (void)pk_die(pk_cat(
                    11, ys("package '"), yr_get(d, "name"),
                    ys("' comes from two places: "), yr_get(e, "src"),
                    ys(" (for "), yr_get(e, "by"), ys(") and "), src,
                    ys(" (for "), by, ys(")")));
                ;
            }
            ;
        } else {
            ;
        }
        ;
    } else {
        PkDecl decl = yr(5, "name", yr_get(d, "name"), "src", src,
                         "by", by, "dep", d, "fdir", fdir);
        (void)ya_push(yr_get(st, "decls"), decl);
        ;
    }
    if (pk_has(yr_get(st, "stack"), yr_get(d, "name"))) {
        (void)pk_die(pk_cat(
            3, ys("dependency cycle: "),
            ys_join(yr_get(st, "stack"), ys(" -> ")),
            ys_cat(ys(" -> "), yr_get(d, "name"))));
        ;
    } else if (!pk_has(yr_get(st, "done"), yr_get(d, "name"))) {
        Yv *at = yr(2, "dir", ys(""), "commit", ys(""));
        if (yv_len(yr_get(d, "git")) > 0) {
            at = pk_git_dir(st, d);
            ;
        } else {
            at = yr(2, "dir", pk_join(fdir, yr_get(d, "path")),
                    "commit", ys(""));
            ;
        }
        PkMan m = pk_manifest(yr_get(at, "dir"));
        if (!ys_eq(yr_get(m, "name"), yr_get(d, "name"))) {
            (void)pk_die(pk_cat(
                7, ys("dependency '"), yr_get(d, "name"), ys("' ("),
                pk_src(d, fdir), ys(") is package '"), yr_get(m, "name"),
                ys("'")));
            ;
        } else if (yv_len(yr_get(m, "lib")) == 0) {
            (void)pk_die(pk_cat(
                5, ys("package '"), yr_get(m, "name"), ys("' ("),
                pk_src(d, fdir), ys(") has no lib to import")));
            ;
        } else {
            ;
        }
        (void)ya_push(yr_get(st, "stack"), yr_get(d, "name"));
        Yv *mds = yr_get(m, "deps");
        long i = 0;
        while (i < yv_len(mds)) {
            (void)pk_visit(st, ya_get(mds, i), yr_get(m, "name"),
                           yr_get(at, "dir"));
            i = i + 1;
        }
        Yv *stk = yr_get(st, "stack");
        (void)yr_set(st, "stack", ya_slice(stk, 0, yv_len(stk) - 1));
        (void)ya_push(yr_get(st, "done"), yr_get(d, "name"));
        PkNode node = yr(8, "name", yr_get(m, "name"), "dir",
                         yr_get(at, "dir"), "lib",
                         pk_join(yr_get(at, "dir"), yr_get(m, "lib")),
                         "roots", pk_roots(yr_get(at, "dir"), yr_get(m, "roots")),
                         "deps", pk_dep_names(mds), "git", yr_get(d, "git"),
                         "rev", yr_get(d, "rev"), "commit",
                         yr_get(at, "commit"));
        (void)ya_push(yr_get(st, "nodes"), node);
        ;
    } else {
        ;
    }
    return 0;
}

static Yv *pk_decl_name(PkDecl e) {
    return yr_get(e, "name");
}

/* ── git dependencies ────────────────────────────────────────────────── */

static PkGit pk_git_dir(PkSt st, PkDep d) {
    Yv *pin = pk_lock_find(yr_get(st, "lock"), d);
    Yv *vdir = pk_join(
        yr_get(st, "rdir"),
        ys_cat(ys("vendor/"), yr_get(d, "name")));
    if (pk_is_file(ys_cat(vdir, ys("/y.toml")))) {
        return yr(2, "dir", vdir, "commit", pin);
    } else {
        Yv *base = pk_join(yr_get(st, "rdir"), ys("build/git"));
        Yv *cdir = ys_cat(
            ys_cat(ys_cat(base, ys("/")), yr_get(d, "name")),
            ys_cat(ys("-"), pin));
        if (yv_len(pin) > 0 &&
            pk_is_file(ys_cat(cdir, ys("/y.toml")))) {
            return yr(2, "dir", cdir, "commit", pin);
        } else {
            return pk_fetch(d, base, pin);
        }
    }
}

/* `s` quoted for sh. */
static Yv *pk_q(Yv *s) {
    Yv *quoted = ys_join(ys_split(s, ys("'")), ys("'\\''"));
    return ys_cat(ys_cat(ys("'"), quoted), ys("'"));
}

/* /proc/self/environ has no useful st_size, so read it as a stream. */
static Yv *pk_read_environ(void) {
    long fd = syscall(SYS_openat, AT_FDCWD, "/proc/self/environ", 0, 0);
    if (fd < 0) {
        return yv_none();
    }
    Yv *chunks = yav(0);
    char buf[4096];
    long got = 0;
    int failed = 0;
    do {
        got = syscall(SYS_read, fd, buf, sizeof(buf));
        if (got > 0) {
            chunks = ya_push(chunks, ys_n(buf, (size_t)got));
        } else if (got < 0) {
            failed = 1;
        } else {
            ;
        }
    } while (got > 0);
    (void)syscall(SYS_close, fd);
    if (failed) {
        return yv_none();
    } else {
        return ys_join(chunks, ys(""));
    }
}

/* exec() runs sh with no environment; pk_env exports the parent's values. */
static Yv *pk_env(void) {
    Yv *t = pk_read_environ();
    if (yv_is_none(t)) {
        return ys("");
    } else {
        Yv *s = yv_unwrap(t);
        Yv *out = yav(0);
        long start = 0;
        long i = 0;
        while (i <= yv_len(s)) {
            if (i == yv_len(s) || ys_byte_at(s, i) == 0) {
                Yv *kv = ys_slice(s, start, i);
                long eq = ys_index_of(kv, ys("="));
                if (eq > 0 && pk_is_ident(ys_slice(kv, 0, eq))) {
                    Yv *entry = ys_cat(
                        ys_cat(
                            ys_cat(
                                ys_cat(ys("export "),
                                       ys_slice(kv, 0, eq)),
                                ys("=")),
                            pk_q(ys_slice(kv, eq + 1, yv_len(kv)))),
                        ys("; "));
                    out = ya_push(out, entry);
                    ;
                } else {
                    ;
                }
                start = i + 1;
                ;
            } else {
                ;
            }
            i = i + 1;
        }
        return ys_join(out, ys(""));
    }
}

/* The twin of std/exec.y: fork, execve("/bin/sh", ..., NULL), wait4. */
static long pk_exec(Yv *cmd) {
    char shpath[] = "/bin/sh";
    char dashc[] = "-c";
    char *argv[] = {shpath, dashc, cmd->u.s.p, NULL};
    long pid = syscall(SYS_fork);
    if (pid == 0) {
        (void)syscall(SYS_execve, shpath, argv, NULL);
        (void)syscall(SYS_exit, 127);
        return 0;
    } else if (pid < 0) {
        return 0 - 1;
    } else {
        long status = 0;
        long w = syscall(SYS_wait4, pid, &status, 0, NULL);
        if (w < 0) {
            return 0 - 1;
        } else {
            return pk_exit_status(status);
        }
    }
}

static long pk_exit_status(long raw) {
    if (raw % 128 == 0) {
        return (raw / 256) % 256;
    } else {
        return 0 - 1;
    }
}

static PkGit pk_fetch(PkDep d, Yv *base, Yv *pin) {
    Yv *tmp = pk_cat(4, base, ys("/"), yr_get(d, "name"), ys(".tmp"));
    Yv *want = pin;
    if (yv_len(want) == 0) {
        want = yr_get(d, "rev");
        ;
    } else {
        ;
    }
    Yv *cmd = pk_cat(
        11, pk_env(), ys("mkdir -p "), pk_q(base), ys(" && rm -rf "),
        pk_q(tmp), ys(" && git clone --quiet "), pk_q(yr_get(d, "git")),
        ys(" "), pk_q(tmp), ys(" && cd "), pk_q(tmp));
    if (yv_len(want) > 0) {
        cmd = pk_cat(
            3, cmd, ys(" && git -c advice.detachedHead=false checkout --quiet "),
            pk_q(want));
        ;
    } else {
        ;
    }
    cmd = pk_cat(2, cmd, ys(" && git rev-parse HEAD > .git/ycc-commit"));
    eputs_(pk_cat(5, ys("fetching "), yr_get(d, "name"), ys(" ("),
                    yr_get(d, "git"), ys(")\n")));
    if (pk_exec(cmd) != 0) {
        (void)pk_die(pk_cat(5, ys("fetching '"), yr_get(d, "name"),
                            ys("' from "), yr_get(d, "git"), ys(" failed")));
        ;
    } else {
        ;
    }
    Yv *ct = read_file(pk_cat(2, tmp, ys("/.git/ycc-commit")));
    Yv *commit = ys("");
    if (!yv_is_none(ct)) {
        commit = ys_trim(yv_unwrap(ct));
        ;
    } else {
        ;
    }
    Yv *dest = pk_cat(5, base, ys("/"), yr_get(d, "name"), ys("-"), commit);
    Yv *mv = pk_cat(2, ys("rm -rf "), pk_q(tmp));
    if (!pk_is_file(ys_cat(dest, ys("/y.toml")))) {
        mv = pk_cat(5, ys("rm -rf "), pk_q(dest), ys(" && mv "), pk_q(tmp),
                    pk_cat(2, ys(" "), pk_q(dest)));
        ;
    } else {
        ;
    }
    if (yv_len(commit) == 0 ||
        pk_exec(pk_cat(2, pk_env(), mv)) != 0) {
        (void)pk_die(pk_cat(5, ys("fetching '"), yr_get(d, "name"),
                            ys("' from "), yr_get(d, "git"), ys(" failed")));
        ;
    } else {
        ;
    }
    return yr(2, "dir", dest, "commit", commit);
}

/* ── y.lock ──────────────────────────────────────────────────────────── */

static Yv *pk_lock_read(Yv *dir) {
    Yv *out = yav(0);
    Yv *file = pk_join(dir, ys("y.lock"));
    Yv *txt = read_file(file);
    if (!yv_is_none(txt)) {
        Yv *ents = pk_toml(yv_unwrap(txt), file);
        long i = 0;
        while (i < yv_len(ents)) {
            Yv *e = ya_get(ents, i);
            if (ys_eq_lit(yr_get(e, "tab"), "package") &&
                yv_l(yr_get(e, "n")) >= 0) {
                long n = yv_l(yr_get(e, "n"));
                while (yv_len(out) <= n) {
                    out = ya_push(
                        out, yr(4, "name", ys(""), "git", ys(""),
                                "rev", ys(""), "commit", ys("")));
                }
                Yv *lk = ya_get(out, n);
                Yv *key = yr_get(e, "key");
                if (!ys_eq_lit(yr_get(e, "k"), "s")) {
                    ;
                } else if (ys_eq_lit(key, "name")) {
                    (void)yr_set(lk, "name", yr_get(e, "s"));
                    ;
                } else if (ys_eq_lit(key, "git")) {
                    (void)yr_set(lk, "git", yr_get(e, "s"));
                    ;
                } else if (ys_eq_lit(key, "rev")) {
                    (void)yr_set(lk, "rev", yr_get(e, "s"));
                    ;
                } else if (ys_eq_lit(key, "commit")) {
                    (void)yr_set(lk, "commit", yr_get(e, "s"));
                    ;
                } else {
                    ;
                }
                ;
            } else {
                ;
            }
            i = i + 1;
        }
        ;
    } else {
        ;
    }
    return out;
}

/* The commit y.lock pins `d` to, matching its git and rev too. */
static Yv *pk_lock_find(Yv *locks, PkDep d) {
    Yv *out = ys("");
    long i = 0;
    while (i < yv_len(locks)) {
        Yv *lk = ya_get(locks, i);
        if (ys_eq(yr_get(lk, "name"), yr_get(d, "name")) &&
            ys_eq(yr_get(lk, "git"), yr_get(d, "git")) &&
            ys_eq(yr_get(lk, "rev"), yr_get(d, "rev"))) {
            out = yr_get(lk, "commit");
            ;
        } else {
            ;
        }
        i = i + 1;
    }
    return out;
}

/* Write y.lock only when a git dependency resolved to a new commit. */
static long pk_lock_write(Yv *dir, Yv *nodes) {
    Yv *out = yav(0);
    out = ya_push(out,
                  ys("# y.lock -- written by `ycc build`: the commit each git dependency\n"));
    out = ya_push(out,
                  ys("# resolved to. Delete an entry to move it to its rev again.\n"));
    int any = 0;
    long i = 0;
    while (i < yv_len(nodes)) {
        Yv *p = ya_get(nodes, i);
        if (yv_len(yr_get(p, "git")) > 0 &&
            yv_len(yr_get(p, "commit")) > 0) {
            Yv *entry = pk_cat(
                9, ys("\n[[package]]\nname = "), pk_tq(yr_get(p, "name")),
                ys("\ngit = "), pk_tq(yr_get(p, "git")), ys("\nrev = "),
                pk_tq(yr_get(p, "rev")), ys("\ncommit = "),
                pk_tq(yr_get(p, "commit")), ys("\n"));
            out = ya_push(out, entry);
            any = 1;
            ;
        } else {
            ;
        }
        i = i + 1;
    }
    if (any) {
        Yv *text = ys_join(out, ys(""));
        Yv *file = pk_join(dir, ys("y.lock"));
        Yv *old = read_file(file);
        int same = 0;
        if (!yv_is_none(old)) {
            same = ys_eq(yv_unwrap(old), text);
            ;
        } else {
            ;
        }
        if (!same && !write_file(file, text)) {
            (void)pk_die(pk_cat(3, ys("writing '"), file, ys("' failed")));
            ;
        } else {
            ;
        }
        ;
    } else {
        ;
    }
    return 0;
}

/* ── ycc vendor ──────────────────────────────────────────────────────── */

long pk_vendor(Yv *dir) {
    Yv *g = pk_load(dir);
    Yv *ps = yr_get(g, "pkgs");
    long n = 0;
    long i = 0;
    while (i < yv_len(ps)) {
        Yv *p = ya_get(ps, i);
        if (yv_len(yr_get(p, "git")) > 0) {
            Yv *vd = pk_join(
                dir, ys_cat(ys("vendor/"), yr_get(p, "name")));
            if (!ys_eq(yr_get(p, "dir"), vd)) {
                Yv *cmd = pk_cat(
                    11, pk_env(), ys("mkdir -p "),
                    pk_q(pk_join(dir, ys("vendor"))), ys(" && rm -rf "),
                    pk_q(vd), ys(" && cp -R "), pk_q(yr_get(p, "dir")),
                    ys(" "), pk_q(vd), ys(" && rm -rf "),
                    pk_q(pk_cat(2, vd, ys("/.git"))));
                if (pk_exec(cmd) != 0) {
                    (void)pk_die(pk_cat(3, ys("vendoring '"),
                                        yr_get(p, "name"), ys("' failed")));
                    ;
                } else {
                    ;
                }
                ;
            } else {
                ;
            }
            eputs_(pk_cat(5, ys("vendored "), yr_get(p, "name"), ys(" ("),
                          vd, ys(")\n")));
            n = n + 1;
            ;
        } else {
            ;
        }
        i = i + 1;
    }
    if (n == 0) {
        eputs_(ys("nothing to vendor: no git dependencies\n"));
        ;
    } else {
        ;
    }
    return 0;
}

/* ── hashing (the object cache's keys) ───────────────────────────────── */

PkHash pk_hash_new(void) {
    return yr(2, "a", yv_long(1), "b", yv_long(7));
}

static long pk_mix(PkHash h, long x) {
    long a = yv_l(yr_get(h, "a"));
    long b = yv_l(yr_get(h, "b"));
    a = (a * 4294967296L + x) % 2147483647L;
    (void)yr_set(h, "a", yv_long(a));
    b = (b * 4294967296L + x) % 2147483629L;
    (void)yr_set(h, "b", yv_long(b));
    return 0;
}

long pk_hash_str(PkHash h, Yv *s) {
    long n = yv_len(s);
    (void)pk_mix(h, n);
    long i = 0;
    while (i + 4 <= n) {
        long x = ys_byte_at(s, i) +
                 ys_byte_at(s, i + 1) * 256L +
                 ys_byte_at(s, i + 2) * 65536L +
                 ys_byte_at(s, i + 3) * 16777216L;
        (void)pk_mix(h, x);
        i = i + 4;
    }
    long x = 0;
    long m = 1;
    while (i < n) {
        x = x + ys_byte_at(s, i) * m;
        m = m * 256;
        i = i + 1;
    }
    (void)pk_mix(h, x);
    return 0;
}

Yv *pk_hash_text(PkHash h) {
    return ys_cat(
        ys_cat(ys_tostring(yr_get(h, "a")), ys("-")),
        ys_tostring(yr_get(h, "b")));
}

/* Hash this compiler's own binary so another ycc's object is not a hit. */
Yv *pk_self_id(void) {
    Yv *t = read_file(ys("/proc/self/exe"));
    if (yv_is_none(t)) {
        (void)pk_die(
            ys("cannot read the compiler's own binary (/proc/self/exe)"));
        ;
    } else {
        ;
    }
    Yv *h = pk_hash_new();
    (void)pk_hash_str(h, yv_unwrap(t));
    return pk_hash_text(h);
}
