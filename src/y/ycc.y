// ycc — the Y compiler. Compiles Y source straight to a native
// executable (Linux x86_64) with no toolchain: no cc, no as, no ld,
// no libc. Usage: ycc [-o OUTPUT] [-S] [-t] [--no-exec] [-h] FILE
//   (no flags)   compile FILE to a native executable (default output: a.out)
//   -o OUTPUT    output path (executable, or .s file with -S)
//   -S           emit assembly only (stdout, or the -o file)
//   -t, --time   print per-phase time and heap use to stderr
//   -h, --help   show this text and exit

import lexer from "./lexer.y";
import parser from "./parser.y";
import nasm from "./asm.y";
import nativelib from "./native.y";

// ── argument parsing ─────────────────────────────────────────────────────

def parse_cli_args(argv: [str]) -> { out: str, files: [str], asm_only: bool, timing: bool, allow_exec: bool, prof: bool } {
    let out = "";
    let files = [];
    let asm_only = false;
    let timing = false;
    let allow_exec = true;
    let prof = false;
    let i = 1;  // skip argv[0]
    let n = len(argv);
    while (i < n) {
        let a = argv[i];
        if (a == "-o") {
            if (i + 1 < n) {
                i = i + 1;
                out = argv[i];
                0
            } else {
                puts("ycc: -o needs an argument\n");
                exit(1);
                0
            };
        } else if (a == "-S") {
            asm_only = true;
            0
        } else if (a == "--time" || a == "-t") {
            timing = true;
            0
        } else if (a == "--no-exec") {
            allow_exec = false;
            0
        } else if (a == "--prof") {
            prof = true;
            0
        } else if (a == "--help" || a == "-h") {
            puts("Usage: ycc [-o OUTPUT] [-S] [-t] [--no-exec] [-h] FILE\n");
            puts("  (no flags)   compile FILE to a native executable (default: a.out)\n");
            puts("  -o OUTPUT    output path (executable, or .s file with -S)\n");
            puts("  -S           emit assembly only (stdout, or the -o file)\n");
            puts("  -t, --time   print per-phase time and heap use to stderr\n");
            puts("  --no-exec    omit exec() -- the binary cannot reach a shell\n");
            puts("  --prof       instrument the output: per-function call counts and\n");
            puts("               cpu times printed on stderr when the program exits\n");
            puts("  -h, --help   show this text and exit\n");
            exit(0);
            0
        } else if (substr(a, 0, 1) == "-") {
            puts("ycc: unknown flag '" + a + "' (see ycc -h)\n");
            exit(1);
            0
        } else {
            files += a;
            0
        };
        i = i + 1;
    };
    { out: out, files: files, asm_only: asm_only, timing: timing, allow_exec: allow_exec, prof: prof }
};

// ── phase reporting (--time) ─────────────────────────────────────────────
// Everything goes to stderr via eputs: stdout carries program output and
// `-S` assembly, and must stay clean enough to diff.

def padr(s: str, w: long) -> str {
    let r = s;
    while (len(r) < w) { r = r + " "; };
    r
};

def padl(s: str, w: long) -> str {
    let r = s;
    while (len(r) < w) { r = " " + r; };
    r
};

// Microseconds as fixed-point milliseconds (native mode has no floats).
def fmt_ms(us: long) -> str {
    let ms = us / 1000;
    let fr = us % 1000;
    let fs = tostring(fr);
    while (len(fs) < 3) { fs = "0" + fs; };
    tostring(ms) + "." + fs
};

def fmt_kb(b: long) -> str {
    tostring(b / 1024)
};

def print_phase_rows(times: [{ name: str, us: long, heap: long }]) -> long {
    // NOTE: bound once — `times[i]` inline misparses on the CVM backend.
    let all = times;
    let i = 0;
    while (i < len(all)) {
        let e = all[i];
        eputs("  " + padr(e.name, 12) + padl(fmt_ms(e.us), 12) + " ms" + padl(fmt_kb(e.heap), 12) + " KB\n");
        i = i + 1;
    };
    0
};

def print_counter(name: str, v: long) -> long {
    eputs("  " + padr(name, 12) + padl(tostring(v), 12) + "\n");
    0
};

// ── main ─────────────────────────────────────────────────────────────────

def print_native_errors(errors: [{ msg: str, line: long, col: long }], pre: long) -> long {
    // NOTE: bound once — `errors[i]` inline misparses on the CVM backend.
    // `pre` is the number of prelude lines spliced in front of the user's
    // source: subtract it so positions refer to the file the user wrote.
    // A position INSIDE the prelude (line <= pre) would be a compiler bug,
    // so it is reported as-is rather than silently going negative.
    let all = errors;
    let i = 0;
    while (i < len(all)) {
        let e = all[i];
        let ln = e.line;
        if (ln > pre) { ln = ln - pre; 0; } else { 0; };
        puts(tostring(ln) + ":" + tostring(e.col) + ": error: " + e.msg + "\n");
        i = i + 1;
    };
    0
};

def main(cmdline: [str]) -> long {
    let args = parse_cli_args(cmdline);
    // NOTE: bound once — `args.out` inline misparses on the C backend.
    let pargs = args;
    let out = pargs.out;
    let files = pargs.files;

    if (len(files) == 0) {
        puts("error: no input file (see ycc -h)\n");
        exit(1);
        1
    } else if (len(files) > 1) {
        puts("error: ycc compiles one program; use imports to combine files\n");
        exit(1);
        1
    } else {
        let file = files[0];
        let src = read_file(file);
        if (src == none) {
            puts("error: cannot read file '" + file + "'\n");
            exit(1);
            1
        } else {
            // src is str? (read_file returns none on missing file); the
            // none case exited above, so unwrap here (loud on none).
            let src2 = unwrap(src);
            // get base dir from file path (use last slash, like C compiler's strrchr)
            let last_slash = last_index_of(file, "/");
            let base_dir = ".";
            if (last_slash >= 0) {
                base_dir = substr(file, 0, last_slash);
                0
            } else { 0; };

            // splice imports, tokenize, parse, compile to assembly
            // NOTE: each bound once — `x.y` on a call result misparses on
            // the C backend (it reads `f().y` as `f(.y)`).
            let t0 = clock_us();
            let h0 = heap_used();
            let tstart = t0;
            let hstart = h0;
            let dt: [{ name: str, us: long, heap: long }] = [];
            let nr = nativelib.native_resolve_x(src2, base_dir, 0, pargs.allow_exec, pargs.prof);
            let ph = nativelib.phase_end(dt, "resolve", t0, h0);
            dt = ph.times; t0 = ph.t; h0 = ph.h;
            let nrsrc = nr.src;
            let nrimports = nr.imports;
            let nrpre = nr.pre;
            let toks = lexer.tokenize(nrsrc);
            ph = nativelib.phase_end(dt, "tokenize", t0, h0);
            dt = ph.times; t0 = ph.t; h0 = ph.h;
            let ast = parser.parse_program(toks);
            ph = nativelib.phase_end(dt, "parse", t0, h0);
            dt = ph.times; t0 = ph.t; h0 = ph.h;
            let r = nativelib.emit_program(ast, nrimports);
            // emit_program reports its own sub-phases (strip_ns, rename,
            // typecheck, emit_fns, emit_start, asm_text); splice them in.
            let sub = r.times;
            let si = 0;
            while (si < len(sub)) {
                let se = sub[si];
                dt += se;
                si = si + 1;
            };
            t0 = clock_us();
            h0 = heap_used();
            // NOTE: `!(r.ok)` with parens — the C parser reads `!r.ok`
            // as `(!r).ok`.
            let rok = r.ok;
            if (!(rok)) {
                print_native_errors(r.errors, nrpre);
                exit(1);
                1
            } else if (pargs.asm_only) {
                let rasm = r.asm;
                if (len(out) == 0) {
                    puts(rasm);
                    0
                } else {
                    write_file(out, rasm);
                    0
                };
                ph = nativelib.phase_end(dt, "write", t0, h0);
                dt = ph.times;
                if (pargs.timing) {
                    eputs("ycc --time: " + file + "\n");
                    print_phase_rows(dt);
                    eputs("  " + padr("TOTAL", 12) + padl(fmt_ms(clock_us() - tstart), 12) + " ms" + padl(fmt_kb(heap_used() - hstart), 12) + " KB\n");
                    print_counter("src_bytes", len(nrsrc));
                    print_counter("tokens", len(toks));
                    print_counter("asm_bytes", len(rasm));
                    0
                } else { 0; };
                0
            } else {
                // Assemble to bytes in-process (no as/ld/cc) and write the
                // executable DIRECTLY with the write_bytes builtin
                // (binary-safe open/write/chmod, tinycc-style — NULs pass
                // through as array elements, no shell, no exec/printf).
                // No `&x`, no `*T`, no `syscall` here: the C bootstrap
                // parser cannot parse any of them (see lexer OPERATORS).
                let rasm2 = r.asm;
                let ab = nasm.ycc_assemble(rasm2);
                ph = nativelib.phase_end(dt, "assemble", t0, h0);
                dt = ph.times; t0 = ph.t; h0 = ph.h;
                // ycc_assemble reports its own sub-phases (split/encode/link).
                let asub = ab.times;
                let ai = 0;
                while (ai < len(asub)) {
                    let ae = asub[ai];
                    dt += ae;
                    ai = ai + 1;
                };
                let abok = ab.ok;
                if (!(abok)) {
                    puts("error: assemble: " + ab.error + "\n");
                    exit(1);
                    1
                } else {
                    let out_path = out;
                    if (len(out_path) == 0) { out_path = "a.out"; 0; } else { 0; };
                    // NOTE: bound once — `x.y` on a call result
                    // misparses on the C backend.
                    let abbytes = ab.bytes;
                    // 493 = 0755 executable (chmod applied by write_bytes).
                    let ok = write_bytes(out_path, abbytes, 493);
                    ph = nativelib.phase_end(dt, "write", t0, h0);
                    dt = ph.times;
                    if (pargs.timing) {
                        eputs("ycc --time: " + file + "\n");
                        print_phase_rows(dt);
                        eputs("  " + padr("TOTAL", 12) + padl(fmt_ms(clock_us() - tstart), 12) + " ms" + padl(fmt_kb(heap_used() - hstart), 12) + " KB\n");
                        print_counter("src_bytes", len(nrsrc));
                        print_counter("tokens", len(toks));
                        print_counter("asm_bytes", len(rasm2));
                        print_counter("out_bytes", len(abbytes));
                        0
                    } else { 0; };
                    if (!(ok)) {
                        puts("error: writing '" + out_path + "' failed\n");
                        exit(1);
                        1
                    } else {
                        0
                    }
                }
            }
        }
    }
};

// entry point — use real command-line arguments
let result = main(argv());
