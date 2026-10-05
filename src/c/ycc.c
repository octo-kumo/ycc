/* ycc.c — the driver (1:1 copy of src/y/ycc.y).
 *
 * ycc — the Y compiler. Compiles Y source straight to a native
 * executable (Linux x86-64) with no toolchain: no cc, no as, no ld,
 * no libc. Usage: ycc [-o OUTPUT] [-S] [-t] [-g] [-w] [--no-exec]
 * [--std-src] [--std-pack FILE] [-h] FILE
 *   (no flags)   compile FILE to a native executable (default output: a.out)
 *   -o OUTPUT    output path (executable, or .s file with -S)
 *   -S           emit assembly only (stdout, or the -o file)
 *   -t, --time   print per-phase time and heap use to stderr
 *   -g           add a symbol table and DWARF line info (for perf, gdb,
 *                valgrind, addr2line; see -h)
 *   -w           do not print warnings (lint.c)
 *   --std-src    compile the std units from source, not the attached pack
 *   --std-pack FILE  write the compiled std units to FILE, no program
 *   -h, --help   show this text and exit
 * A project (a directory with a y.toml manifest, see pkg.y):
 *   ycc build [-g] [-w] [--no-exec] [--std-src] [DIR]   build its programs
 *   ycc vendor [DIR]   copy its git dependencies into vendor/
 */
#include "ycc.h"
#include "tags.h"

#include "asm.h"
#include "lexer.h"
#include "meta.h"
#include "native.h"
#include "parser.h"
#include "pkg.h"
#include "yv.h"

#include <fcntl.h>
#include <stdio.h>
#include <sys/types.h>
#include <unistd.h>

/* ── argument parsing ────────────────────────────────────────────────── */

static long wlevel_arg(Yv *argv, long i, long n);

Yv *parse_cli_args(Yv *argv) {
    Yv *out = ys("");
    Yv *files = yav(0);
    int asm_only = 0;
    int timing = 0;
    int allow_exec = 1;
    int debug = 0;
    int nowarn = 0;
    long wlevel = 0;
    int std_src = 0;
    Yv *std_pack_path = ys("");
    int run = 0;
    int dump = 0;
    long i = 1; /* skip argv[0] */
    long n = yv_len(argv);
    while (i < n) {
        Yv *a = ya_get(argv, i);
        if (ys_eq_lit(a, "-o")) {
            if (i + 1 < n) {
                i = i + 1;
                out = ya_get(argv, i);
                /* An empty path used to be taken for "no -o", and the binary
                 * landed in ./a.out -- a silent write to the wrong place,
                 * which `make` scripts get wrong in turn (ycc.y). */
                if (yv_len(out) == 0) {
                    puts_(ys("ycc: -o needs a path, got ''\n"));
                    exit_(1);
                }
                ;
            } else {
                puts_(ys("ycc: -o needs an argument\n"));
                exit_(1);
                ;
            }
        } else if (ys_eq_lit(a, "-S")) {
            asm_only = 1;
            ;
        } else if (ys_eq_lit(a, "-E")) {
            /* dump the source the lexer would see, with origin markers, and
             * stop: no tokens, no check, no output file. */
            dump = 1;
            ;
        } else if (ys_eq_lit(a, "run")) {
            run = 1;
            ;
        } else if (ys_eq_lit(a, "--time") || ys_eq_lit(a, "-t")) {
            timing = 1;
            ;
        } else if (ys_eq_lit(a, "--no-exec")) {
            allow_exec = 0;
            ;
        } else if (ys_eq_lit(a, "-g")) {
            debug = 1;
            ;
        } else if (ys_eq_lit(a, "-w")) {
            nowarn = 1;
            ;
        } else if (ys_eq_lit(a, "-W")) {
            wlevel = wlevel_arg(argv, i, n);
            i = i + 1;
            ;
        } else if (ys_eq_lit(a, "--std-src")) {
            std_src = 1;
            ;
        } else if (ys_eq_lit(a, "--std-pack")) {
            if (i + 1 < n) {
                i = i + 1;
                std_pack_path = ya_get(argv, i);
                ;
            } else {
                puts_(ys("ycc: --std-pack needs an argument\n"));
                exit_(1);
                ;
            }
        } else if (ys_eq_lit(a, "--help") || ys_eq_lit(a, "-h")) {
            puts_(ys("Usage: ycc [-o OUTPUT] [-S] [-E] [-t] [-g] [-w] [-W N] [--no-exec] [-h] FILE\n"));
            puts_(ys("       ycc run [-g] [--no-exec] FILE     compile FILE and run it in a\n"));
            puts_(ys("                                           child; ycc's exit status is\n"));
            puts_(ys("                                           the program's\n"));
            puts_(ys("       ycc build [-g] [-w] [-W N] [--no-exec] [--std-src] [DIR]\n"));
            puts_(ys("       ycc vendor [DIR]\n"));
            puts_(ys("  (no flags)   compile FILE to a native executable (default: "
                     "a.out)\n"));
            puts_(ys("  -o OUTPUT    output path (executable, or .s file with -S)\n"));
            puts_(ys("  -S           emit assembly only (stdout, or the -o file)\n"));
            puts_(ys("  -E           dump the source the lexer sees, each line tagged with\n"));
            puts_(ys("               the file and line it came from, and stop\n"));
            puts_(ys("  run FILE     compile FILE and run it in a forked child: no output\n"));
            puts_(ys("               file, and ycc exits with the program's status\n"));
            puts_(ys("  -t, --time   print per-phase time and heap use to stderr\n"));
            puts_(ys("  -g           add section headers, a symbol table (functions,\n"));
            puts_(ys("               globals) and DWARF line info, so perf, gdb,\n"));
            puts_(ys("               valgrind and addr2line show names and source\n"));
            puts_(ys("               lines; the loaded code and data are unchanged\n"));
            puts_(ys("  -w           do not print warnings (they go to stderr and\n"));
            puts_(ys("               never change the output)\n"));
            puts_(ys("  -W N         warning level N; 0 (the default) is the usual\n"));
            puts_(ys("               set, 1 adds the optional checks for a value\n"));
            puts_(ys("               computed and dropped -- a call result nobody\n"));
            puts_(ys("               reads, a bare a[i] or x.f as a statement,\n"));
            puts_(ys("               an else branch that does nothing\n"));
            puts_(ys("  --no-exec    omit exec() -- the binary cannot reach a shell\n"));
            puts_(ys("  --std-src    compile the std units (the runtime and std library)\n"));
            puts_(ys("               from source instead of using the precompiled ones\n"));
            puts_(ys("               attached to ycc; the output is the same\n"));
            puts_(ys("  --std-pack FILE  compile the std units and write them to FILE,\n"));
            puts_(ys("               to attach to a ycc binary (the build does)\n"));
            puts_(ys("  -h, --help   show this text and exit\n"));
            puts_(ys("  build [DIR]  build the project in DIR (default .) as its y.toml\n"));
            puts_(ys("               says: each [bin] into DIR/build, every package it\n"));
            puts_(ys("               depends on compiled once (DIR/build/obj keeps them)\n"));
            puts_(ys("  vendor [DIR] copy the project's git dependencies into DIR/vendor\n"));
            exit_(0);
            ;
        } else if (ys_eq_lit(ys_slice(a, 0, 1), "-")) {
            puts_(ys_cat(ys_cat(ys("ycc: unknown flag '"), a),
                         ys("' (see ycc -h)\n")));
            exit_(1);
            ;
        } else {
            files = ya_push(files, a);
            ;
        }
        i = i + 1;
    }
    return yr(12, "out", out, "files", files, "asm_only", yv_bool(asm_only),
              "timing", yv_bool(timing), "allow_exec", yv_bool(allow_exec),
              "debug", yv_bool(debug), "nowarn", yv_bool(nowarn), "wlevel",
              yv_long(wlevel), "std_src", yv_bool(std_src), "std_pack",
              std_pack_path, "run", yv_bool(run), "dump", yv_bool(dump));
}

/* ── the std pack ───────────────────────────────────────────────────────
 * The build attaches to ycc its std units, compiled (native.y std_pack):
 * the binary ends with [pack][the pack's length, 8 digits][YCCPACK1]. */

Yv *pack_magic(void) {
    return ys("YCCPACK1");
}

/* The pack attached to this binary, or "" when there is none. */
Yv *self_pack(void) {
    int fd = open("/proc/self/exe", O_RDONLY);
    if (fd < 0) {
        return ys("");
    }
    Yv *pack = ys("");
    long size = (long)lseek(fd, 0, SEEK_END);
    if (size >= 16) {
        char buf[65536];
        char tailbuf[16];
        lseek(fd, (off_t)(size - 16), SEEK_SET);
        ssize_t k = read(fd, tailbuf, 16);
        if (k == 16) {
            Yv *tail = ys_n(tailbuf, 16);
            long n = ys_tonum(ys_slice(tail, 0, 8));
            if (ys_eq(ys_slice(tail, 8, 16), pack_magic()) &&
                n > 0 && n <= size - 16) {
                lseek(fd, (off_t)(size - 16 - n), SEEK_SET);
                Yv *pieces = yav(0);
                long left = n;
                while (left > 0) {
                    long want = left;
                    if (want > 65536) {
                        want = 65536;
                        ;
                    }
                    ssize_t got = read(fd, buf, (size_t)want);
                    if (got <= 0) {
                        left = -1;
                        ;
                    } else {
                        pieces = ya_push(pieces, ys_n(buf, (size_t)got));
                        left = left - got;
                        ;
                    }
                }
                if (left == 0) {
                    pack = ys_join(pieces, ys(""));
                    ;
                }
                ;
            }
            ;
        }
        ;
    }
    close(fd);
    return pack;
}

/* --std-pack FILE: every std unit, compiled from source, framed for
 * attaching (see self_pack). */
long write_std_pack(Yv *path) {
    Yv *pack = std_pack(std_units(std_unit_names(), ys("")));
    Yv *nd = ys_long(yv_len(pack));
    while (yv_len(nd) < 8) {
        nd = ys_cat(ys("0"), nd);
        ;
    }
    if (yv_len(nd) > 8) {
        puts_(ys_cat(ys_cat(ys("error: the std pack is too large ("), nd),
                      ys(" bytes)\n")));
        exit_(1);
        return 0;
    }
    if (!write_file(path, ys_cat(ys_cat(pack, nd), pack_magic()))) {
        puts_(ys_cat(ys_cat(ys("error: writing '"), path), ys("' failed\n")));
        exit_(1);
        return 0;
    }
    return 0;
}

/* ── phase reporting (--time) ────────────────────────────────────────────
 * Everything goes to stderr via eputs: stdout carries program output and
 * `-S` assembly, and must stay clean enough to diff. */

Yv *padr(Yv *s, long w) {
    Yv *r = s;
    while (yv_len(r) < w) {
        r = ys_cat(r, ys(" "));
    }
    return r;
}

Yv *padl(Yv *s, long w) {
    Yv *r = s;
    while (yv_len(r) < w) {
        r = ys_cat(ys(" "), r);
    }
    return r;
}

/* Microseconds as fixed-point milliseconds, integer arithmetic only: the C
 * twin formats the same way, so both copies print the same string. */
Yv *fmt_ms(long us) {
    long ms = us / 1000;
    long fr = us % 1000;
    Yv *fs = ys_long(fr);
    while (yv_len(fs) < 3) {
        fs = ys_cat(ys("0"), fs);
    }
    return ys_cat(ys_cat(ys_long(ms), ys(".")), fs);
}

Yv *fmt_kb(long b) { return ys_long(b / 1024); }

long print_phase_rows(Yv *times) {
    /* NOTE: vestigial alias — `times[i]` parses and typechecks in both
     * copies today; the binding stays only because the compiled compiler
     * is byte-gated against refs/ycc.ref. */
    Yv *all = times;
    long i = 0;
    while (i < yv_len(all)) {
        Yv *e = ya_get(all, i);
        eputs_(ys_cat(
            ys_cat(ys_cat(ys_cat(ys("  "), padr(yr_get(e, "name"), 12)),
                           padl(fmt_ms(yv_l(yr_get(e, "us"))), 12)),
                   ys(" ms")),
            ys_cat(ys_cat(padl(fmt_kb(yv_l(yr_get(e, "heap"))), 12), ys(" KB")),
                   ys("\n"))));
        i = i + 1;
    }
    return 0;
}

long print_counter(Yv *name, long v) {
    eputs_(ys_cat(ys_cat(ys_cat(ys("  "), padr(name, 12)), padl(ys_long(v), 12)),
                  ys("\n")));
    return 0;
}

/* ── main ──────────────────────────────────────────────────────────────── */

long print_native_errors(Yv *errors, Yv *origin, int bare) {
    /* NOTE: vestigial alias (see print_phase_rows) — `errors[i]` works.
     * Positions are lines of the spliced program (std chunks and imported
     * modules included); the origin map turns each back into the file it
     * came from: `line:col` in the program's own file (unless not `bare`:
     * `ycc build` names every file), `path:line:col` in any other. */
    Yv *all = errors;
    /* One error per position: a malformed token can trip two checks (the
     * construct it broke, then the statement it ended), and the second
     * message only repeats the first. */
    Yv *seen = yav(0);
    long i = 0;
    while (i < yv_len(all)) {
        Yv *e = ya_get(all, i);
        Yv *at = ys_cat(ys_cat(origin_at(origin, yv_l(yr_get(e, "line")), bare),
                               ys(":")),
                        ys_long(yv_l(yr_get(e, "col"))));
        int dup = 0;
        long j = 0;
        while (j < yv_len(seen)) {
            if (ys_eq(ya_get(seen, j), at)) {
                dup = 1;
                ;
            }
            j = j + 1;
        }
        if (!dup) {
            seen = ya_push(seen, at);
            puts_(ys_cat(
                ys_cat(ys_cat(at, ys(": error: ")),
                       yr_get(e, "msg")),
                ys("\n")));
            ;
        }
        i = i + 1;
    }
    return 0;
}

/* The warnings as the one string print_native_warnings used to write in
 * pieces: a dispatched child carries it in a file and the parent prints it
 * where the serial loop would have, so the bytes on stderr do not depend on
 * which child finished first. Each position as print_native_errors gives it
 * (lint_unit sorted them and dropped repeats). */
Yv *warning_text(Yv *warnings, Yv *origin, int bare) {
    Yv *out = ys("");
    long i = 0;
    while (i < yv_len(warnings)) {
        Yv *w = ya_get(warnings, i);
        Yv *at = origin_at(origin, yv_l(yr_get(w, "line")), bare);
        Yv *one = ys_cat(ys_cat(at, ys(":")), ys_tostring(yr_get(w, "col")));
        one = ys_cat(one, ys(": warning: "));
        one = ys_cat(one, yr_get(w, "msg"));
        out = ys_cat(out, ys_cat(one, ys("\n")));
        i = i + 1;
    }
    return out;
}

/* What lint.c found in a unit that compiled, as `at: warning: msg` on
 * stderr (a -S listing on stdout stays clean). */
long print_native_warnings(Yv *warnings, Yv *origin, int bare) {
    eputs_(warning_text(warnings, origin, bare));
    return 0;
}

/* The decimal level after `-W`, or the flag's own complaint. `i` points at
 * "-W". Levels past 1 are the same as 1: the optional checks are a set. */
/* The decimal level after -W, or the flag's own complaint. Only 0 and 1 exist,
 * so anything else is rejected -- and the scan saturates, because a long enough
 * digit run wraps the accumulator and "-W 99999999999999999999" would come back
 * as an accepted level (ycc.y). */
static long wlevel_arg(Yv *argv, long i, long n) {
    if (i + 1 >= n) {
        puts_(ys("ycc: -W needs a warning level (0, or 1)\n"));
        exit_(1);
        return 0;
    } else {
        Yv *a = ya_get(argv, i + 1);
        int ok = yv_len(a) > 0 && !ys_eq_lit(ys_slice(a, 0, 1), "-");
        long v = 0;
        long d = 0;
        while (ok && d < yv_len(a)) {
            long c = ys_byte_at(a, d);
            ok = c >= '0' && c <= '9';
            if (ok && v <= 1) { v = v * 10 + (c - '0'); }
            d = d + 1;
        }
        if (!ok || v > 1) {
            puts_(ys_cat(ys_cat(ys_cat(ys("ycc: -W needs a warning level (0, or 1), got '"),
                                   a), ys("'")), ys("\n")));
            exit_(1);
            return 0;
        } else {
            return v;
        }
    }
}

Yv *build_args(Yv *cmdline) {
    Yv *dir = ys("");
    int debug = 0;
    int nowarn = 0;
    long wlevel = 0;
    int allow_exec = 1;
    int std_src = 0;
    Yv *one = ys("");
    long i = 2;
    while (i < yv_len(cmdline)) {
        Yv *a = ya_get(cmdline, i);
        if (ys_eq_lit(a, "-g")) {
            debug = 1;
        } else if (ys_eq_lit(a, "-w")) {
            nowarn = 1;
        } else if (ys_eq_lit(a, "-W")) {
            wlevel = wlevel_arg(cmdline, i, yv_len(cmdline));
            i = i + 1;
        } else if (ys_eq_lit(a, "--no-exec")) {
            allow_exec = 0;
        } else if (ys_eq_lit(a, "--std-src")) {
            std_src = 1;
        } else if (ys_eq_lit(a, "--one")) {
            /* build_dispatch's child: one package, then exit */
            if (i + 1 >= yv_len(cmdline)) {
                puts_(ys("ycc: --one needs a package name\n"));
                exit_(1);
                return 0;
            }
            one = ya_get(cmdline, i + 1);
            i = i + 1;
        } else if (ys_eq_lit(ys_slice(a, 0, 1), "-")) {
            puts_(ys_cat(ys_cat(ys("ycc: unknown flag '"), a),
                         ys("' (see ycc -h)\n")));
            exit_(1);
            return 0;
        } else if (yv_len(dir) > 0) {
            puts_(ys_cat(ys_cat(ys("error: ycc "), ya_get(cmdline, 1)),
                         ys(" takes one project directory\n")));
            exit_(1);
            return 0;
        } else {
            dir = a;
        }
        i = i + 1;
    }
    if (yv_len(dir) == 0) {
        dir = ys(".");
        ;
    }
    return yr(7, "dir", dir, "debug", yv_bool(debug), "nowarn",
              yv_bool(nowarn), "wlevel", yv_long(wlevel), "allow_exec",
              yv_bool(allow_exec), "std_src",
              yv_bool(std_src), "one", one);
}

Yv *build_resolve(Yv *path, int allow_exec, Yv *pkgs, Yv *roots) {
    Yv *src = read_file(path);
    if (yv_is_none(src)) {
        puts_(ys_cat(ys_cat(ys("error: cannot read file '"), path), ys("'\n")));
        exit_(1);
        return 0;
    }
    /* A meta pass per unit: a block in package A cannot see package B, so each
     * unit gets its own generator (ideas/meta.md, "The pass"). */
    (void)meta_begin();
    return native_resolve_pk(yv_unwrap(src), pk_dir_of(path), allow_exec,
                             path, pkgs, roots);
}

Yv *std_order(Yv *names) {
    Yv *all = std_unit_names();
    Yv *out = yav(0);
    long i = 0;
    while (i < yv_len(all)) {
        Yv *nm = ya_get(all, i);
        if (pk_has(names, nm)) {
            out = ya_push(out, nm);
            ;
        }
        i = i + 1;
    }
    return out;
}

Yv *longs_text(Yv *xs) {
    Yv *out = yav(0);
    long i = 0;
    while (i < yv_len(xs)) {
        out = ya_push(out, ys_long(yv_l(ya_get(xs, i))));
        i = i + 1;
    }
    return ys_join(out, ys(""));
}

Yv *build_key(Yv *cid, Yv *name, long base, int allow_exec, Yv *nr,
              Yv *units) {
    Yv *h = pk_hash_new();
    pk_hash_str(h, cid);
    pk_hash_str(h, name);
    pk_hash_str(h, ys_long(base));
    Yv *ex = ys("exec");
    if (!allow_exec) {
        ex = ys("no-exec");
        ;
    }
    pk_hash_str(h, ex);
    pk_hash_str(h, yr_get(nr, "src"));
    Yv *o = yr_get(nr, "origin");
    pk_hash_str(h, ys_join(yr_get(o, "files"), ys("\n")));
    pk_hash_str(h, longs_text(yr_get(o, "file")));
    pk_hash_str(h, longs_text(yr_get(o, "line")));
    pk_hash_str(h, ys_join(yr_get(nr, "std"), ys(",")));
    Yv *pkgs = yr_get(nr, "pkgs");
    pk_hash_str(h, ys_join(pkgs, ys(",")));
    long i = 0;
    while (i < yv_len(units)) {
        Yv *u = ya_get(units, i);
        if (pk_has(pkgs, yr_get(u, "name"))) {
            pk_hash_str(h, unit_iface(u));
            ;
        }
        i = i + 1;
    }
    return pk_hash_text(h);
}

Yv *build_reach(Yv *direct, Yv *pkgs, Yv *nrs) {
    Yv *want = yav(0);
    long i = 0;
    while (i < yv_len(direct)) {
        want = ya_push(want, ya_get(direct, i));
        i = i + 1;
    }
    Yv *reach = yav(0);
    long k = 0;
    while (k < yv_len(pkgs)) {
        reach = ya_push(reach, yv_bool(0));
        k = k + 1;
    }
    k = yv_len(pkgs) - 1;
    while (k >= 0) {
        Yv *p = ya_get(pkgs, k);
        if (pk_has(want, yr_get(p, "name"))) {
            ya_set(reach, k, yv_bool(1));
            Yv *nr = ya_get(nrs, k);
            Yv *imports = yr_get(nr, "pkgs");
            long j = 0;
            while (j < yv_len(imports)) {
                want = ya_push(want, ya_get(imports, j));
                j = j + 1;
            }
            ;
        }
        k = k - 1;
    }
    return reach;
}

/* ── `ycc build`: compiling a ready level of packages in parallel ─────────
 *
 * pk_load hands the packages back in topological order, so every dependency
 * has a lower index than its importer. The loop below walks them in that
 * order; a *level* is a run of packages that depend only on what is already
 * compiled (all of their dependencies sit before the run), and a level's
 * packages are independent of each other -- so it is where the time is.
 *
 * A level compiles out of process: one `ycc build --one NAME` child per
 * package, through a single shell (exec() takes one command string, and `&`
 * plus `wait` is all the parallelism that needs). Each child writes the
 * object the loop would have written, build/obj/NAME.yo, keyed by build_key
 * (this compiler, the package's place among the units, its text, and the
 * *interfaces* of the packages it imports), and the loop then reads it back
 * exactly as on a warm build. Nothing here is needed for a correct build: a
 * child that fails leaves no object, and the loop compiles that package
 * itself and reports the error as if nothing had been dispatched -- the
 * diagnostics and the bytes are the same either way. Warnings ride along in a
 * sidecar named for the object they belong to (the key), so they print in
 * package order and a sidecar left by another key is never read. What does
 * change is the order of the *lines*: a level's "compiling" lines all come
 * from the dispatch, before the loop prints the warnings it collected.
 *
 * Deliberately not spawn/join. A thread shares the address space (CLONE_VM)
 * and the compiler keeps 51 module-level lets -- the label table every
 * body's label ids index, rename.c's and types.c's name caches, native.c's
* dbg_file and pkg_ns -- so two packages compiling at once would race on all
 * of them, and every later allocation would take y_alloc's %fs detour (+14
 * instructions each, measured: +2.7% of a package's compile, since a 3.5k
 * line unit allocates 615,000 times). Two processes race on nothing, and
 * each one's arena holds one package instead of the whole project: 799 MB
 * for eight 3.5k-line packages compiled in one process, 106 MB for the same
 * build with children.
 *
 * The waves are capped so peak memory stays bounded: a package compile is
 * ~30 ms, so even a wide graph does not want twenty of them at once. And
 * nothing is dispatched for a level of one (a chain, or a project with a
 * single package), for a package whose object is already there (a rebuild
 * that compiles nothing spawns nothing), or under --std-src (a child would
 * compile the std units from source before its own package).
 */
#define BUILD_JOBS 4

/* `s` quoted for sh (pkg.c's pk_q, which is not exported, does the same). */
static Yv *build_q(Yv *s) {
    return ys_cat(ys_cat(ys("'"), ys_join(ys_split(s, ys("'")), ys("'\\''"))),
                  ys("'"));
}

/* Where a dispatched child's warnings wait: one file per object, so a
 * leftover from another key is never read. */
static Yv *warn_path(Yv *odir, Yv *name, Yv *key) {
    return ys_cat(ys_cat(ys_cat(ys_cat(odir, ys("/")), name), ys(".")),
                  ys_cat(key, ys(".warn")));
}

/* This compiler's own path, which is what the children run: /proc/self/exe is
 * absolute and resolved, where argv[0] need not be. readlink(2), not read:
 * opening that path gives the binary itself, a megabyte of it. */
static Yv *self_exe(void) {
    char buf[4096];
    long n = (long)readlink("/proc/self/exe", buf, sizeof(buf));
    if (n <= 0) {
        return ys("");
    } else {
        return ys_n(buf, (size_t)n);
    }
}

/* The flags a child needs to compile its package exactly as this run would. */
static Yv *build_child_flags(int debug, int nowarn, long wlevel, int allow_exec) {
    Yv *out = ys("");
    if (debug) { out = ys_cat(out, ys(" -g")); }
    if (nowarn) { out = ys_cat(out, ys(" -w")); }
    if (wlevel > 0) {
        out = ys_cat(ys_cat(out, ys(" -W ")), ys_long(wlevel));
        ;
    }
    if (!allow_exec) {
        out = ys_cat(out, ys(" --no-exec"));
        ;
    }
    return out;
}

/* Where `name` sits in the package order, or -1. */
static long pkg_index(Yv *pkgs, Yv *name) {
    long at = -1;
    long i = 0;
    while (i < yv_len(pkgs)) {
        if (ys_eq(yr_get(ya_get(pkgs, i), "name"), name)) { at = i; }
        i = i + 1;
    }
    return at;
}

/* `ycc build --one NAME`: compile exactly this one package of DIR and write
 * its object. Only its dependencies' objects are read -- the loop hands out a
 * package whose dependencies are all done, and this same compiler wrote them,
 * so those units are the ones the loop would have compiled. The unit order is
 * the topological one, so each dependency's own key hashes the same
 * interfaces the loop gave it. */
long build_one(Yv *dir, Yv *one, int debug, int nowarn, long wlevel,
               int allow_exec, int std_src) {
    Yv *g = pk_load(dir);
    Yv *pkgs = yr_get(g, "pkgs");
    Yv *odir = ys_cat(pk_join(dir, ys("build")), ys("/obj"));
    long target = pkg_index(pkgs, one);
    if (target < 0) {
        puts_(ys_cat(ys_cat(ys_cat(ys("error: no package '"), one),
                           ys("' in ")),
                     ys_cat(dir, ys("\n"))));
        exit_(1);
        return 0;
    }
    Yv *cid = pk_self_id();
    Yv *pack = ys("");
    if (!std_src) {
        pack = self_pack();
        ;
    }
    Yv *want = yr_get(ya_get(pkgs, target), "deps");
    Yv *units = yav(0);
    long k = 0;
    while (k < target) {
        Yv *p = ya_get(pkgs, k);
        if (pk_has(want, yr_get(p, "name"))) {
            Yv *nr = build_resolve(yr_get(p, "lib"), allow_exec,
                                   yr_get(p, "deps"), yr_get(p, "roots"));
            long base = 5000000000L + k * 1000000000L;
            Yv *key = build_key(cid, yr_get(p, "name"), base, allow_exec, nr,
                                units);
            Yv *ot = read_file(ys_cat(ys_cat(ys_cat(odir, ys("/")),
                                               yr_get(p, "name")),
                                      ys(".yo")));
            if (yv_is_none(ot)) {
                puts_(ys_cat(ys_cat(ys("error: package '"), yr_get(p, "name")),
                             ys("' was not compiled first\n")));
                exit_(1);
                return 0;
            }
            Yv *uo = unit_unobj(yv_unwrap(ot), key);
            if (!yv_b(yr_get(uo, "ok"))) {
                puts_(ys_cat(ys_cat(ys("error: package '"), yr_get(p, "name")),
                             ys("' has no current object\n")));
                exit_(1);
                return 0;
            }
            units = ya_push(units, yr_get(uo, "unit"));
            want = ya_push(want, yr_get(p, "deps"));
        }
        k = k + 1;
    }
    Yv *p = ya_get(pkgs, target);
    Yv *nr = build_resolve(yr_get(p, "lib"), allow_exec, yr_get(p, "deps"),
                           yr_get(p, "roots"));
    long base = 5000000000L + target * 1000000000L;
    Yv *key = build_key(cid, yr_get(p, "name"), base, allow_exec, nr, units);
    Yv *su = std_units(std_order(yr_get(nr, "std")), pack);
    Yv *ast = parse_program(tokenize(yr_get(nr, "src")));
    Yv *r = compile_package(ast, nr, yr_get(p, "name"), base, wlevel, su, units);
    if (!yv_b(yr_get(r, "ok"))) {
        print_native_errors(yr_get(r, "errors"), yr_get(nr, "origin"), 0);
        exit_(1);
        return 0;
    }
    Yv *wp = warn_path(odir, yr_get(p, "name"), key);
    if (!write_file(wp, warning_text(yr_get(r, "warnings"), yr_get(nr, "origin"),
                                     0))) {
        exit_(1);
        return 0;
    }
    Yv *op = ys_cat(ys_cat(odir, ys("/")), yr_get(p, "name"));
    op = ys_cat(op, ys(".yo"));
    if (!write_file(op, unit_obj(yr_get(r, "unit"), key))) {
        puts_(ys_cat(ys_cat(ys("error: writing '"), op), ys("' failed\n")));
        exit_(1);
        return 0;
    }
    return 0;
}

/* Hand the level pkgs[lo..hi) out to child compilers, in waves of at most
 * BUILD_JOBS; how many went out comes back (the callers here want the objects
 * more than the count). A
 * package whose object file is already there is left to the loop, so a
 * rebuild that compiles nothing spawns nothing either. */
static long build_dispatch_level(Yv *dir, Yv *pkgs, Yv *odir, long lo, long hi,
                                 int debug, int nowarn, long wlevel,
                                 int allow_exec, int std_src) {
    long n = 0;
    /* --std-src has no pack, so a child would compile the std units from
     * source before its own package: far more than the package costs. */
    if (!std_src && hi - lo > 1) {
        Yv *exe = self_exe();
        if (yv_len(exe) > 0) {
            Yv *flags = build_child_flags(debug, nowarn, wlevel, allow_exec);
            Yv *dirarg = ys("");
            Yv *wave = yav(0);
            long k = lo;
            long w;
            if (!ys_eq_lit(dir, ".")) {
                dirarg = ys_cat(ys(" "), build_q(dir));
            }
            while (k < hi) {
                Yv *name = yr_get(ya_get(pkgs, k), "name");
                if (!pk_exists(ys_cat(ys_cat(ys_cat(odir, ys("/")), name),
                                      ys(".yo")))) {
                    wave = ya_push(wave, name);
                }
                k = k + 1;
            }
            w = 0;
            while (w < yv_len(wave)) {
                long take = yv_len(wave) - w;
                long c = 0;
                Yv *cmd = ys("");
                if (take > BUILD_JOBS) { take = BUILD_JOBS; }
                while (c < take) {
                    Yv *nm = ya_get(wave, w + c);
                    eputs_(ys_cat(ys_cat(ys("compiling "), nm), ys("\n")));
                    /* quote the two paths, not the whole command: the flags
                     * and the directory are already quoted */
                    cmd = ys_cat(ys_cat(cmd, build_q(exe)), ys(" build --one "));
                    cmd = ys_cat(cmd, build_q(nm));
                    cmd = ys_cat(ys_cat(ys_cat(cmd, flags), dirarg), ys(" & "));
                    n = n + 1;
                    c = c + 1;
                }
                pk_exec(ys_cat(cmd, ys("wait")));
                w = w + take;
            }
        }
    }
    return n;
}
long build_project(Yv *dir, int debug, int nowarn, long wlevel,
                   int allow_exec, int std_src) {
    Yv *g = pk_load(dir);
    Yv *bins = yr_get(g, "bins");
    Yv *pkgs = yr_get(g, "pkgs");
    if (yv_len(bins) == 0 && yv_len(yr_get(g, "lib")) == 0) {
        puts_(ys_cat(ys_cat(ys("error: "), pk_join(dir, ys("y.toml"))),
                     ys(" has no [bin] and no lib: nothing to build\n")));
        exit_(1);
        return 0;
    }
    Yv *bdir = pk_join(dir, ys("build"));
    Yv *odir = ys_cat(bdir, ys("/obj"));
    pk_mkdir(bdir);
    pk_mkdir(odir);

    Yv *nrs = yav(0);
    long k = 0;
    while (k < yv_len(pkgs)) {
        Yv *p = ya_get(pkgs, k);
        nrs = ya_push(nrs, build_resolve(yr_get(p, "lib"), allow_exec,
                                         yr_get(p, "deps"), yr_get(p, "roots")));
        k = k + 1;
    }
    Yv *bdeps = yav(0);
    Yv *gdeps = yr_get(g, "deps");
    long i = 0;
    while (i < yv_len(gdeps)) {
        bdeps = ya_push(bdeps, ya_get(gdeps, i));
        i = i + 1;
    }
    if (yv_len(yr_get(g, "lib")) > 0) {
        bdeps = ya_push(bdeps, yr_get(g, "name"));
        ;
    }
    i = 0;
    while (i < yv_len(bins)) {
        Yv *bn = ya_get(bins, i);
        nrs = ya_push(nrs, build_resolve(yr_get(bn, "path"), allow_exec,
                                         bdeps, yr_get(g, "roots")));
        i = i + 1;
    }

    Yv *needs = yav(0);
    k = 0;
    while (k < yv_len(nrs)) {
        Yv *nr = ya_get(nrs, k);
        Yv *std = yr_get(nr, "std");
        i = 0;
        while (i < yv_len(std)) {
            needs = ya_push(needs, ya_get(std, i));
            i = i + 1;
        }
        k = k + 1;
    }
    Yv *pack = ys("");
    if (!std_src) {
        pack = self_pack();
        ;
    }
    Yv *su = std_units(std_order(needs), pack);
    Yv *cid = pk_self_id();
    Yv *units = yav(0);
    k = 0;
    while (k < yv_len(pkgs)) {
        /* A level: the longest run of packages from k that depend only on
         * what is already compiled (every dependency has the lower index). A
         * level wider than one package goes out to child compilers, and the
         * loop below then reads their objects (build_dispatch_level). */
        long hi = k;
        int scanning = 1;
        while (scanning && hi < yv_len(pkgs)) {
            Yv *deps = yr_get(ya_get(pkgs, hi), "deps");
            long d = 0;
            int ready = 1;
            while (d < yv_len(deps)) {
                if (pkg_index(pkgs, ya_get(deps, d)) >= k) { ready = 0; }
                d = d + 1;
            }
            if (ready) {
                hi = hi + 1;
            } else {
                scanning = 0;
            }
        }
        build_dispatch_level(dir, pkgs, odir, k, hi, debug, nowarn, wlevel,
                             allow_exec, std_src);
        while (k < hi) {
        Yv *p = ya_get(pkgs, k);
        Yv *nr = ya_get(nrs, k);
        long base = 5000000000L + k * 1000000000L;
        Yv *key = build_key(cid, yr_get(p, "name"), base, allow_exec, nr, units);
        Yv *opath = ys_cat(ys_cat(odir, ys("/")),
                           ys_cat(yr_get(p, "name"), ys(".yo")));
        int hit = 0;
        Yv *ot = read_file(opath);
        if (!yv_is_none(ot)) {
            Yv *uo = unit_unobj(yv_unwrap(ot), key);
            if (yv_b(yr_get(uo, "ok"))) {
                units = ya_push(units, yr_get(uo, "unit"));
                hit = 1;
                ;
            }
            ;
        }
        if (hit) {
            /* a dispatched child's warnings, in package order like the rest */
            Yv *wp = warn_path(odir, yr_get(p, "name"), key);
            Yv *wt = read_file(wp);
            if (!yv_is_none(wt)) {
                if (!nowarn) { eputs_(yv_unwrap(wt)); }
                remove_file(wp);
            }
        } else {
            eputs_(ys_cat(ys_cat(ys("compiling "), yr_get(p, "name")), ys("\n")));
            Yv *ast = parse_program(tokenize(yr_get(nr, "src")));
            Yv *r = compile_package(ast, nr, yr_get(p, "name"), base, wlevel,
                                   su, units);
            if (!yv_b(yr_get(r, "ok"))) {
                print_native_errors(yr_get(r, "errors"), yr_get(nr, "origin"), 0);
                exit_(1);
                return 0;
            }
            if (!nowarn) {
                print_native_warnings(yr_get(r, "warnings"),
                                      yr_get(nr, "origin"), 0);
            }
            if (!write_file(opath, unit_obj(yr_get(r, "unit"), key))) {
                puts_(ys_cat(ys_cat(ys("error: writing '"), opath), ys("' failed\n")));
                exit_(1);
                return 0;
            }
            units = ya_push(units, yr_get(r, "unit"));
            ;
        }
        k = k + 1;
        }
    }

    i = 0;
    while (i < yv_len(bins)) {
        Yv *bn = ya_get(bins, i);
        Yv *nr = ya_get(nrs, yv_len(pkgs) + i);
        Yv *reach = build_reach(yr_get(nr, "pkgs"), pkgs, nrs);
        Yv *linked = yav(0);
        Yv *lneeds = yav(0);
        Yv *nrstd = yr_get(nr, "std");
        k = 0;
        while (k < yv_len(nrstd)) {
            lneeds = ya_push(lneeds, ya_get(nrstd, k));
            k = k + 1;
        }
        k = 0;
        while (k < yv_len(pkgs)) {
            if (yv_b(ya_get(reach, k))) {
                linked = ya_push(linked, ya_get(units, k));
                Yv *pn = ya_get(nrs, k);
                Yv *pstd = yr_get(pn, "std");
                long j = 0;
                while (j < yv_len(pstd)) {
                    lneeds = ya_push(lneeds, ya_get(pstd, j));
                    j = j + 1;
                }
                ;
            }
            k = k + 1;
        }
        Yv *lstd = std_order(lneeds);
        Yv *bstd = yav(0);
        k = 0;
        while (k < yv_len(su)) {
            Yv *su1 = ya_get(su, k);
            if (pk_has(lstd, yr_get(su1, "name"))) {
                bstd = ya_push(bstd, su1);
                ;
            }
            k = k + 1;
        }
        Yv *ast = parse_program(tokenize(yr_get(nr, "src")));
        Yv *r = emit_program(ast, nr, debug, wlevel, bstd, linked);
        if (!yv_b(yr_get(r, "ok"))) {
            print_native_errors(yr_get(r, "errors"), yr_get(nr, "origin"), 0);
            exit_(1);
            return 0;
        }
        if (!nowarn) {
            print_native_warnings(yr_get(r, "warnings"), yr_get(nr, "origin"),
                                  0);
        }
        Yv *ab = ycc_assemble(yr_get(r, "asm"), debug);
        if (!yv_b(yr_get(ab, "ok"))) {
            puts_(ys_cat(ys_cat(ys("error: assemble: "), yr_get(ab, "error")),
                         ys("\n")));
            exit_(1);
            return 0;
        }
        Yv *outp = ys_cat(ys_cat(bdir, ys("/")), yr_get(bn, "name"));
        if (!write_bytes(outp, yr_get(ab, "bytes"), 493)) {
            puts_(ys_cat(ys_cat(ys("error: writing '"), outp), ys("' failed\n")));
            exit_(1);
            return 0;
        }
        eputs_(ys_cat(ys_cat(ys("built "), outp), ys("\n")));
        i = i + 1;
    }
    return 0;
}

/* `ycc -E`: the resolved text, each line tagged with the file and line it came
 * from. The tag is a trailing comment on the FIRST line of each run of lines
 * from one file, so line numbers survive the round trip and the markers do not
 * move anything: comments never reach the lexer, so compiling a dump gives the
 * same bytes as compiling the file it came from. */
static long dump_source(Yv *src, Yv *origin) {
    Yv *lines = ys_split(src, ys("\n"));
    Yv *prev = ys("\x01none");
    long i = 0;
    while (i < yv_len(lines)) {
        Yv *l = ya_get(lines, i);
        Yv *at = origin_at(origin, i + 1, 0);
        if (ys_eq(at, prev)) {
            puts_(ys_cat(l, ys("\n")));
        } else {
            puts_(ys_cat(ys_cat(ys_cat(l, ys("\t// ")), at), ys("\n")));
            prev = at;
        };
        i = i + 1;
    };
    return 0;
}

long y_main(Yv *cmdline) {
    /* tags.y writes its tag numbers out twice (K for the code, KTAGS for
     * diagnostics); ~4k instructions to prove the two still agree, once. */
    if (!tags_agree()) {
        eputs_(ys("ycc: internal error: the tag tables disagree "
               "(src/y/tags.y)\n"));
        exit_(1);
    }
    if (yv_len(cmdline) > 1 &&
        (ys_eq_lit(ya_get(cmdline, 1), "build") ||
         ys_eq_lit(ya_get(cmdline, 1), "vendor"))) {
        Yv *ba = build_args(cmdline);
        Yv *one = yr_get(ba, "one");
        if (ys_eq_lit(ya_get(cmdline, 1), "build") && yv_len(one) == 0) {
            build_project(yr_get(ba, "dir"), yv_b(yr_get(ba, "debug")),
                          yv_b(yr_get(ba, "nowarn")),
                          yv_l(yr_get(ba, "wlevel")),
                          yv_b(yr_get(ba, "allow_exec")),
                          yv_b(yr_get(ba, "std_src")));
            ;
        } else if (ys_eq_lit(ya_get(cmdline, 1), "build")) {
            build_one(yr_get(ba, "dir"), one, yv_b(yr_get(ba, "debug")),
                      yv_b(yr_get(ba, "nowarn")), yv_l(yr_get(ba, "wlevel")),
                      yv_b(yr_get(ba, "allow_exec")),
                      yv_b(yr_get(ba, "std_src")));
            ;
        } else {
            pk_vendor(yr_get(ba, "dir"));
            ;
        }
        exit_(0);
        return 0;
    }
    Yv *args = parse_cli_args(cmdline);
    /* NOTE: vestigial alias (see print_phase_rows) — `args.out` works. */
    Yv *pargs = args;
    Yv *out = yr_get(pargs, "out");
    Yv *files = yr_get(pargs, "files");

    if (yv_len(yr_get(pargs, "std_pack")) > 0) {
        write_std_pack(yr_get(pargs, "std_pack"));
        exit_(0);
        return 0;
    } else if (yv_len(files) == 0) {
        puts_(ys("error: no input file (see ycc -h)\n"));
        exit_(1);
        return 1;
    } else if (yv_len(files) > 1) {
        puts_(ys("error: ycc compiles one program; use imports to combine "
                 "files\n"));
        exit_(1);
        return 1;
    } else {
        Yv *file = ya_get(files, 0);
        Yv *src = read_file(file);
        if (yv_is_none(src)) {
            puts_(ys_cat(ys_cat(ys("error: cannot read file '"), file),
                         ys("'\n")));
            exit_(1);
            return 1;
        } else {
            /* src is str? (read_file returns none on missing file); the
             * none case exited above, so unwrap here (loud on none). */
            Yv *src2 = yv_unwrap(src);
            /* One meta pass per program: the pass is ON for the program's own
             * resolve and OFF for the generator's (meta_compile_gen), so
             * meta_begin here and nothing else -- resolve_unit's meta_prepare
             * is what runs the generator. */
            (void)meta_begin();
            /* get base dir from file path (use last slash, like C compiler's
             * strrchr) */
            long last_slash = ys_last_index_of(file, ys("/"));
            Yv *base_dir = ys(".");
            if (last_slash >= 0) {
                base_dir = ys_slice(file, 0, last_slash);
                ;
            }

            /* splice imports, tokenize, parse, compile to assembly */
            long t0 = clock_us();
            long h0 = heap_used();
            long tstart = t0;
            long hstart = h0;
            Yv *dt = yav(0);
            Yv *nr = native_resolve_x(src2, base_dir, 0,
                                      yv_b(yr_get(pargs, "allow_exec")), file);
            Yv *ph = phase_end(dt, ys("resolve"), t0, h0);
            dt = yr_get(ph, "times");
            t0 = yv_l(yr_get(ph, "t"));
            h0 = yv_l(yr_get(ph, "h"));
            Yv *nrsrc = yr_get(nr, "src");
            Yv *nrorigin = yr_get(nr, "origin");
            Yv *nrstd = yr_get(nr, "std");
            if (yv_b(yr_get(pargs, "dump"))) {
                dump_source(nrsrc, nrorigin);
                exit_(0);
                return 0;
            };
            Yv *toks = tokenize(nrsrc);
            ph = phase_end(dt, ys("tokenize"), t0, h0);
            dt = yr_get(ph, "times");
            t0 = yv_l(yr_get(ph, "t"));
            h0 = yv_l(yr_get(ph, "h"));
            Yv *ast = parse_program(toks);
            ph = phase_end(dt, ys("parse"), t0, h0);
            dt = yr_get(ph, "times");
            t0 = yv_l(yr_get(ph, "t"));
            h0 = yv_l(yr_get(ph, "h"));
            /* The std units the program links (native_resolve_x picked
             * them): the ones attached to ycc, compiled when it was built,
             * or (--std-src, or a ycc with none) compiled from the sources
             * embedded in it. */
            Yv *pack = ys("");
            if (!yv_b(yr_get(pargs, "std_src"))) {
                pack = self_pack();
                ;
            }
            Yv *su = std_units(nrstd, pack);
            ph = phase_end(dt, ys("std"), t0, h0);
            dt = yr_get(ph, "times");
            t0 = yv_l(yr_get(ph, "t"));
            h0 = yv_l(yr_get(ph, "h"));
            Yv *r = emit_program(ast, nr, yv_b(yr_get(pargs, "debug")),
                                 yv_l(yr_get(pargs, "wlevel")), su, yav(0));
            /* emit_program reports its own sub-phases (strip_ns, rename,
             * typecheck, lint, emit_fns, emit_start, asm_text); splice them
             * in. */
            Yv *sub = yr_get(r, "times");
            long si = 0;
            while (si < yv_len(sub)) {
                Yv *se = ya_get(sub, si);
                dt = ya_push(dt, se);
                si = si + 1;
            }
            if (yv_b(yr_get(r, "ok")) && !yv_b(yr_get(pargs, "nowarn"))) {
                print_native_warnings(yr_get(r, "warnings"), nrorigin, 1);
            }
            t0 = clock_us();
            h0 = heap_used();
            long rok = yv_b(yr_get(r, "ok"));
            if (!rok) {
                print_native_errors(yr_get(r, "errors"), nrorigin, 1);
                exit_(1);
                return 1;
            } else if (yv_b(yr_get(pargs, "asm_only"))) {
                Yv *rasm = link_text(yr_get(r, "asm"));
                int wrote = 1;
                if (yv_len(out) == 0) {
                    puts_(rasm);
                    ;
                } else {
                    /* Checked, like the executable path below: silently
                     * exiting 0 after a failed write hid bad -o paths. */
                    wrote = write_file(out, rasm);
                    ;
                }
                ph = phase_end(dt, ys("write"), t0, h0);
                dt = yr_get(ph, "times");
                if (yv_b(yr_get(pargs, "timing"))) {
                    eputs_(ys_cat(ys("ycc --time: "), ys_cat(file, ys("\n"))));
                    print_phase_rows(dt);
                    eputs_(ys_cat(
                        ys_cat(ys("  "), padr(ys("TOTAL"), 12)),
                        ys_cat(
                            padl(fmt_ms(clock_us() - tstart), 12),
                            ys_cat(ys(" ms"),
                                   ys_cat(padl(fmt_kb(heap_used() - hstart), 12),
                                          ys_cat(ys(" KB"), ys("\n")))))));
                    print_counter(ys("src_bytes"), yv_len(nrsrc));
                    print_counter(ys("tokens"), yv_len(toks));
                    print_counter(ys("asm_bytes"), yv_len(rasm));
                    ;
                }
                if (!(wrote)) {
                    puts_(ys_cat(ys("error: writing '"),
                                 ys_cat(out, ys("' failed\n"))));
                    exit_(1);
                    return 1;
                }
                return 0;
            } else {
                /* Assemble to a [byte] buffer in-process (no as/ld/cc) and write the
                 * executable DIRECTLY with the write_bytes builtin
                 * (binary-safe open/write/chmod, tinycc-style — NULs pass
                 * through as array elements, no shell, no exec/printf). */
                Yv *ab = ycc_assemble(yr_get(r, "asm"),
                                      yv_b(yr_get(pargs, "debug")));
                /* The assembly text itself is not built on this path any more
                 * (the assembler reads the emitter's items), so the size
                 * counter here is the item count; -S still reports asm_bytes. */
                Yv *abitems = yr_get(ab, "items");
                ph = phase_end(dt, ys("assemble"), t0, h0);
                dt = yr_get(ph, "times");
                t0 = yv_l(yr_get(ph, "t"));
                h0 = yv_l(yr_get(ph, "h"));
                /* ycc_assemble reports its own sub-phases: a:split,
                 * a:encode, a:link, then l:labmap, l:patch, l:elf. */
                Yv *asub = yr_get(ab, "times");
                long ai = 0;
                while (ai < yv_len(asub)) {
                    Yv *ae = ya_get(asub, ai);
                    dt = ya_push(dt, ae);
                    ai = ai + 1;
                }
                long abok = yv_b(yr_get(ab, "ok"));
                if (!abok) {
                    puts_(ys_cat(ys("error: assemble: "),
                                 ys_cat(yr_get(ab, "error"), ys("\n"))));
                    exit_(1);
                    return 1;
                } else {
                    if (yv_b(yr_get(pargs, "run"))) {
                        Yv *av = yav(1, file);
                        Yv *rr = run_image(yr_get(ab, "bytes"), av, 0);
                        if (!yv_truth(yr_get(rr, "ok"))) {
                            puts_(ys_cat(ys("error: "),
                                         ys_cat(yr_get(rr, "err"), ys("\n"))));
                            exit_(1);
                            return 1;
                        } else {
                            if (yv_l(yr_get(rr, "sig")) > 0) {
                                exit_(128 + yv_l(yr_get(rr, "sig")));
                            } else {
                                exit_(yv_l(yr_get(rr, "status")));
                            };
                            return 0;
                        }
                    };
                    Yv *out_path = out;
                    if (yv_len(out_path) == 0) {
                        out_path = ys("a.out");
                        ;
                    }
                    Yv *abbytes = yr_get(ab, "bytes");
                    /* 493 = 0755 executable (chmod applied by write_bytes). */
                    int ok = write_bytes(out_path, abbytes, 493);
                    ph = phase_end(dt, ys("write"), t0, h0);
                    dt = yr_get(ph, "times");
                    if (yv_b(yr_get(pargs, "timing"))) {
                        eputs_(ys_cat(ys("ycc --time: "), ys_cat(file, ys("\n"))));
                        print_phase_rows(dt);
                        eputs_(ys_cat(
                            ys_cat(ys("  "), padr(ys("TOTAL"), 12)),
                            ys_cat(padl(fmt_ms(clock_us() - tstart), 12),
                                   ys_cat(
                                       ys(" ms"),
                                       ys_cat(padl(fmt_kb(heap_used() - hstart), 12),
                                              ys_cat(ys(" KB"), ys("\n")))))));
                        print_counter(ys("src_bytes"), yv_len(nrsrc));
                        print_counter(ys("tokens"), yv_len(toks));
                        print_counter(ys("asm_items"), yv_l(abitems));
                        print_counter(ys("out_bytes"), yv_len(abbytes));
                        ;
                    }
                    if (!ok) {
                        puts_(ys_cat(ys_cat(ys("error: writing '"), out_path),
                                     ys("' failed\n")));
                        exit_(1);
                        return 1;
                    } else {
                        return 0;
                    }
                }
            }
        }
    }
}

/* entry point — use real command-line arguments */
int main(int argc, char **argv) {
    yv_set_argv(argc, argv);
    y_main(argv_());
    return 0;
}
