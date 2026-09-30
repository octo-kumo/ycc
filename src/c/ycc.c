/* ycc.c — the driver (1:1 copy of src/y/ycc.y).
 *
 * ycc — the Y compiler. Compiles Y source straight to a native
 * executable (Linux x86_64) with no toolchain: no cc, no as, no ld,
 * no libc. Usage: ycc [-o OUTPUT] [-S] [-t] [--no-exec] [-h] FILE
 *   (no flags)   compile FILE to a native executable (default output: a.out)
 *   -o OUTPUT    output path (executable, or .s file with -S)
 *   -S           emit assembly only (stdout, or the -o file)
 *   -t, --time   print per-phase time and heap use to stderr
 *   -h, --help   show this text and exit
 */
#include "ycc.h"

#include "asm.h"
#include "lexer.h"
#include "native.h"
#include "parser.h"
#include "yv.h"

#include <stdio.h>

/* ── argument parsing ────────────────────────────────────────────────── */

Yv *parse_cli_args(Yv *argv) {
    Yv *out = ys("");
    Yv *files = yav(0);
    int asm_only = 0;
    int timing = 0;
    int allow_exec = 1;
    int prof = 0;
    long i = 1; /* skip argv[0] */
    long n = yv_len(argv);
    while (i < n) {
        Yv *a = ya_get(argv, i);
        if (ys_eq_lit(a, "-o")) {
            if (i + 1 < n) {
                i = i + 1;
                out = ya_get(argv, i);
                ;
            } else {
                puts_(ys("ycc: -o needs an argument\n"));
                exit_(1);
                ;
            }
        } else if (ys_eq_lit(a, "-S")) {
            asm_only = 1;
            ;
        } else if (ys_eq_lit(a, "--time") || ys_eq_lit(a, "-t")) {
            timing = 1;
            ;
        } else if (ys_eq_lit(a, "--no-exec")) {
            allow_exec = 0;
            ;
        } else if (ys_eq_lit(a, "--prof")) {
            prof = 1;
            ;
        } else if (ys_eq_lit(a, "--help") || ys_eq_lit(a, "-h")) {
            puts_(ys("Usage: ycc [-o OUTPUT] [-S] [-t] [--no-exec] [-h] FILE\n"));
            puts_(ys("  (no flags)   compile FILE to a native executable (default: "
                     "a.out)\n"));
            puts_(ys("  -o OUTPUT    output path (executable, or .s file with -S)\n"));
            puts_(ys("  -S           emit assembly only (stdout, or the -o file)\n"));
            puts_(ys("  -t, --time   print per-phase time and heap use to stderr\n"));
            puts_(ys("  --no-exec    omit exec() -- the binary cannot reach a shell\n"));
            puts_(ys("  --prof       instrument the output: per-function call counts "
                     "and\n               cpu times printed on stderr when the program "
                     "exits\n"));
            puts_(ys("  -h, --help   show this text and exit\n"));
            exit_(0);
            ;
        } else if (ys_eq_lit(ys_substr(a, 0, 1), "-")) {
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
    return yr(6, "out", out, "files", files, "asm_only", yv_bool(asm_only),
              "timing", yv_bool(timing), "allow_exec", yv_bool(allow_exec),
              "prof", yv_bool(prof));
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

/* Microseconds as fixed-point milliseconds (native mode has no floats). */
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
    /* NOTE: bound once — `times[i]` inline misparses on the CVM backend. */
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

long print_native_errors(Yv *errors, long pre) {
    /* NOTE: bound once — `errors[i]` inline misparses on the CVM backend.
     * `pre` is the number of prelude lines spliced in front of the user's
     * source: subtract it so positions refer to the file the user wrote.
     * A position INSIDE the prelude (line <= pre) would be a compiler bug,
     * so it is reported as-is rather than silently going negative. */
    Yv *all = errors;
    long i = 0;
    while (i < yv_len(all)) {
        Yv *e = ya_get(all, i);
        long ln = yv_l(yr_get(e, "line"));
        if (ln > pre) {
            ln = ln - pre;
            ;
        } else {
            ;
        }
        puts_(ys_cat(
            ys_cat(ys_cat(ys_cat(ys_long(ln), ys(":")),
                          ys_long(yv_l(yr_get(e, "col")))),
                   ys(": error: ")),
            ys_cat(yr_get(e, "msg"), ys("\n"))));
        i = i + 1;
    }
    return 0;
}

long y_main(Yv *cmdline) {
    Yv *args = parse_cli_args(cmdline);
    /* NOTE: bound once — `args.out` inline misparses on the C backend. */
    Yv *pargs = args;
    Yv *out = yr_get(pargs, "out");
    Yv *files = yr_get(pargs, "files");

    if (yv_len(files) == 0) {
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
            /* get base dir from file path (use last slash, like C compiler's
             * strrchr) */
            long last_slash = ys_last_index_of(file, ys("/"));
            Yv *base_dir = ys(".");
            if (last_slash >= 0) {
                base_dir = ys_substr(file, 0, last_slash);
                ;
            } else {
                ;
            }

            /* splice imports, tokenize, parse, compile to assembly
             * NOTE: each bound once — `x.y` on a call result misparses on
             * the C backend (it reads `f().y` as `f(.y)`). */
            long t0 = clock_us();
            long h0 = heap_used();
            long tstart = t0;
            long hstart = h0;
            Yv *dt = yav(0);
            Yv *nr = native_resolve_x(src2, base_dir, 0,
                                      yv_b(yr_get(pargs, "allow_exec")),
                                      yv_b(yr_get(pargs, "prof")));
            Yv *ph = phase_end(dt, ys("resolve"), t0, h0);
            dt = yr_get(ph, "times");
            t0 = yv_l(yr_get(ph, "t"));
            h0 = yv_l(yr_get(ph, "h"));
            Yv *nrsrc = yr_get(nr, "src");
            Yv *nrimports = yr_get(nr, "imports");
            long nrpre = yv_l(yr_get(nr, "pre"));
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
            Yv *r = emit_program(ast, nrimports);
            /* emit_program reports its own sub-phases (strip_ns, rename,
             * typecheck, emit_fns, emit_start, asm_text); splice them in. */
            Yv *sub = yr_get(r, "times");
            long si = 0;
            while (si < yv_len(sub)) {
                Yv *se = ya_get(sub, si);
                dt = ya_push(dt, se);
                si = si + 1;
            }
            t0 = clock_us();
            h0 = heap_used();
            /* NOTE: `!(r.ok)` with parens — the C parser reads `!r.ok`
             * as `(!r).ok`. */
            long rok = yv_b(yr_get(r, "ok"));
            if (!(rok)) {
                print_native_errors(yr_get(r, "errors"), nrpre);
                exit_(1);
                return 1;
            } else if (yv_b(yr_get(pargs, "asm_only"))) {
                Yv *rasm = yr_get(r, "asm");
                if (yv_len(out) == 0) {
                    puts_(rasm);
                    ;
                } else {
                    write_file(out, rasm);
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
                } else {
                    ;
                }
                return 0;
            } else {
                /* Assemble to bytes in process (no as/ld/cc) and write the
                 * executable DIRECTLY with the write_bytes builtin
                 * (binary-safe open/write/chmod, tinycc-style — NULs pass
                 * through as array elements, no shell, no exec/printf). */
                Yv *rasm2 = yr_get(r, "asm");
                Yv *ab = ycc_assemble(rasm2);
                ph = phase_end(dt, ys("assemble"), t0, h0);
                dt = yr_get(ph, "times");
                t0 = yv_l(yr_get(ph, "t"));
                h0 = yv_l(yr_get(ph, "h"));
                /* ycc_assemble reports its own sub-phases (split/encode/link). */
                Yv *asub = yr_get(ab, "times");
                long ai = 0;
                while (ai < yv_len(asub)) {
                    Yv *ae = ya_get(asub, ai);
                    dt = ya_push(dt, ae);
                    ai = ai + 1;
                }
                long abok = yv_b(yr_get(ab, "ok"));
                if (!(abok)) {
                    puts_(ys_cat(ys("error: assemble: "),
                                 ys_cat(yr_get(ab, "error"), ys("\n"))));
                    exit_(1);
                    return 1;
                } else {
                    Yv *out_path = out;
                    if (yv_len(out_path) == 0) {
                        out_path = ys("a.out");
                        ;
                    } else {
                        ;
                    }
                    /* NOTE: bound once — `x.y` on a call result
                     * misparses on the C backend. */
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
                        print_counter(ys("asm_bytes"), yv_len(rasm2));
                        print_counter(ys("out_bytes"), yv_len(abbytes));
                        ;
                    } else {
                        ;
                    }
                    if (!(ok)) {
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
