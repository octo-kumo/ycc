// ycc — the Y compiler. Compiles Y source straight to a native
// executable (Linux x86_64) with no toolchain: no cc, no as, no ld,
// no libc. Usage: ycc [-o OUTPUT] [-S] [-h] FILE
//   (no flags)   compile FILE to a native executable (default output: a.out)
//   -o OUTPUT    output path (executable, or .s file with -S)
//   -S           emit assembly only (stdout, or the -o file)
//   -h, --help   show this text and exit

import lexer from "./lexer.y";
import parser from "./parser.y";
import nasm from "./asm.y";
import nativelib from "./native.y";

// ── argument parsing ─────────────────────────────────────────────────────

def parse_cli_args(argv: [str]) -> { out: str, files: [str], asm_only: bool } {
    let out = "";
    let files = [];
    let asm_only = false;
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
        } else if (a == "--help" || a == "-h") {
            puts("Usage: ycc [-o OUTPUT] [-S] [-h] FILE\n");
            puts("  (no flags)   compile FILE to a native executable (default: a.out)\n");
            puts("  -o OUTPUT    output path (executable, or .s file with -S)\n");
            puts("  -S           emit assembly only (stdout, or the -o file)\n");
            puts("  -h, --help   show this text and exit\n");
            exit(0);
            0
        } else if (substr(a, 0, 1) == "-") {
            puts("ycc: unknown flag '" + a + "' (see ycc -h)\n");
            exit(1);
            0
        } else {
            files = push(files, a);
            0
        };
        i = i + 1;
    };
    { out: out, files: files, asm_only: asm_only }
};

// ── main ─────────────────────────────────────────────────────────────────

def print_native_errors(errors: [{ msg: str, line: long, col: long }]) -> long {
    // NOTE: bound once — `errors[i]` inline misparses on the CVM backend.
    let all = errors;
    let i = 0;
    while (i < len(all)) {
        let e = all[i];
        puts(tostring(e.line) + ":" + tostring(e.col) + ": error: " + e.msg + "\n");
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
        if (src == null) {
            puts("error: cannot read file '" + file + "'\n");
            exit(1);
            1
        } else {
            // src is str? (read_file returns null on missing file); the
            // null case exited above, so unwrap here (loud on null).
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
            let nr = nativelib.native_resolve(src2, base_dir, 0);
            let nrsrc = nr.src;
            let nrimports = nr.imports;
            let toks = lexer.tokenize(nrsrc);
            let ast = parser.parse_program(toks);
            let r = nativelib.emit_program(ast, nrimports);
            // NOTE: `!(r.ok)` with parens — the C parser reads `!r.ok`
            // as `(!r).ok`.
            let rok = r.ok;
            if (!(rok)) {
                print_native_errors(r.errors);
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
