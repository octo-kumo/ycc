// ycc.y — driver for the Y-lang to C compiler.
// Usage: ycc [--compile OUTPUT] [--emit-c OUTPUT] FILE
//   (no flags)        run in the built-in VM (not yet supported by ycc)
//   --compile OUT     compile FILE to a native binary OUT (default: a.out)
//   --emit-c OUT      emit C source to OUT (default: stdout)

import lexer from "./lexer.y";
import parser from "./parser.y";
import codegen from "./codegen.y";

// ── argument parsing ─────────────────────────────────────────────────────

def parse_args(argv: [str]) -> { mode: str, out: str, file: str } {
    let mode = "vm";
    let out = "";
    let file = "";
    let i = 1;  // skip argv[0]
    let n = len(argv);
    while (i < n) {
        let a = argv[i];
        if (a == "--compile" || a == "-c") {
            mode = "compile";
        } else if (a == "--emit-c" || a == "-S") {
            mode = "emit-c";
        } else if (a == "-o") {
            if (i + 1 < n) {
                i = i + 1;
                out = argv[i];
            };
        } else if (a == "--help" || a == "-h") {
            puts("Usage: ycc [--compile|-c] [--emit-c|-S] [-o OUTPUT] FILE\n");
            puts("  -c, --compile   compile FILE to a native binary\n");
            puts("  -S, --emit-c    emit C source only\n");
            puts("  -o OUTPUT       output path (default: a.out, or stdout for -S)\n");
            puts("  (no flags)      run FILE in the built-in VM\n");
        } else {
            file = a;
        };
        i = i + 1;
    };
    { mode: mode, out: out, file: file }
};

// ── import resolution (source-to-source, like the C compiler's module.c) ─

def resolve_imports(src: str, base_dir: str, depth: long) -> str {
    if (depth > 32) {
        puts("error: import depth exceeded (cycle?)\n");
        ""
    } else {
        let lines = split(src, "\n");
        let out_lines = [];
        let i = 0;
        let n = len(lines);
        while (i < n) {
            let line = lines[i];
            let trimmed = trim(line);
            if (substr(trimmed, 0, 7) == "import ") {
                // import NAME from "PATH";
                let rest = substr(trimmed, 7, len(trimmed) - 7);
                let from_idx = index_of(rest, " from ");
                if (from_idx >= 0) {
                    let name = trim(substr(rest, 0, from_idx));
                    let path_part = trim(substr(rest, from_idx + 6, len(rest) - from_idx - 6));
                    // strip trailing ;
                    if (substr(path_part, len(path_part) - 1, 1) == ";") {
                        path_part = substr(path_part, 0, len(path_part) - 1);
                    };
                    // strip quotes
                    let path = substr(path_part, 1, len(path_part) - 2);
                    // resolve relative to base_dir
                    let full = base_dir + "/" + path;
                    let mod_src = read_file(full);
                    if (mod_src == null) {
                        puts("error: cannot open import '" + path + "' (resolved to '" + full + "')\n");
                        out_lines = push(out_lines, line);
                    } else {
                        // get module dir
                        let last_slash = index_of(path, "/");
                        let mod_dir = base_dir;
                        if (last_slash >= 0) {
                            mod_dir = base_dir + "/" + substr(path, 0, last_slash);
                        };
                        let processed = resolve_imports(mod_src, mod_dir, depth + 1);
                        // Wrap module in an IIFE so defs live in a scope and the
                        // export map is the returned value: let mod = (def(){ ... })();
                        out_lines = push(out_lines, "let " + name + " = (def() {");
                        out_lines = push(out_lines, processed);
                        out_lines = push(out_lines, "})();");
                    };
                } else {
                    out_lines = push(out_lines, line);
                };
            } else if (substr(trimmed, 0, 7) == "export ") {
                // export { a, b };  ->  { a: a, b: b }
                let rest = substr(trimmed, 7, len(trimmed) - 7);
                let brace_start = index_of(rest, "{");
                let brace_end = index_of(rest, "}");
                if (brace_start >= 0 && brace_end >= 0) {
                    let names_str = substr(rest, brace_start + 1, brace_end - brace_start - 1);
                    let names = split(names_str, ",");
                    let pairs = [];
                    let j = 0;
                    let nn = len(names);
                    while (j < nn) {
                        let nm = trim(names[j]);
                        if (len(nm) > 0) {
                            pairs = push(pairs, nm + ": " + nm);
                        };
                        j = j + 1;
                    };
                    out_lines = push(out_lines, "{ " + join(pairs, ", ") + " }");
                } else {
                    out_lines = push(out_lines, line);
                };
            } else {
                out_lines = push(out_lines, line);
            };
            i = i + 1;
        };
        join(out_lines, "\n")
    }
};

// ── main ─────────────────────────────────────────────────────────────────

def main(cmdline: [str]) -> long {
    let args = parse_args(cmdline);
    let mode = args.mode;
    let out = args.out;
    let file = args.file;

    if (len(file) == 0) {
        puts("error: no input file\n");
        1
    } else {
        let src = read_file(file);
        if (src == null) {
            puts("error: cannot read file '" + file + "'\n");
            1
        } else {
            // get base dir from file path (use last slash, like C compiler's strrchr)
            let last_slash = last_index_of(file, "/");
            let base_dir = ".";
            if (last_slash >= 0) {
                base_dir = substr(file, 0, last_slash);
            };

            // resolve imports
            let resolved = resolve_imports(src, base_dir, 0);

            // tokenize
            let toks = lexer.tokenize(resolved);

            // parse
            let ast = parser.parse_program(toks);

            if (mode == "emit-c") {
                let c_src = codegen.emit_program(ast);
                if (len(out) == 0) {
                    puts(c_src);
                } else {
                    write_file(out, c_src);
                };
                0
            } else if (mode == "compile") {
                let out_path = out;
                if (len(out_path) == 0) { out_path = "a.out"; };
                // emit C to a temp file
                let c_path = "/tmp/ycc_tmp.c";
                let c_src = codegen.emit_program(ast);
                write_file(c_path, c_src);
                // compile with cc, linking runtime.c directly (like the C compiler)
                let runtime_dir = getenv("YCC_RUNTIME_DIR");
                if (runtime_dir == null) {
                    runtime_dir = base_dir + "/..";
                };
                let cmd = "cc -O2 -std=gnu99 -I" + runtime_dir + " -o " + out_path + " " + c_path + " " + runtime_dir + "/runtime.c -lm";
                let ret = exec(cmd);
                if (ret != 0) {
                    puts("error: cc failed with exit code " + tostring(ret) + "\n");
                    ret
                } else {
                    0
                }
            } else {
                puts("error: VM mode not yet supported by ycc\n");
                1
            }
        }
    }
};

// entry point — use real command-line arguments
let result = main(argv());
