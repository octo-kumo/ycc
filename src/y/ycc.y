// ycc — the Y compiler. Compiles Y source straight to a native
// executable (Linux x86_64) with no toolchain: no cc, no as, no ld,
// no libc. Usage: ycc [-o OUTPUT] [-S] [-t] [-g] [--no-exec] [-h] FILE
//   (no flags)   compile FILE to a native executable (default output: a.out)
//   -o OUTPUT    output path (executable, or .s file with -S)
//   -S           emit assembly only (stdout, or the -o file)
//   -t, --time   print per-phase time and heap use to stderr
//   -g           add a symbol table and DWARF line info (for perf, gdb,
//                valgrind, addr2line; see -h)
//   --std-src    compile the std units from source, not the attached pack
//   --std-pack FILE  write the compiled std units to FILE, no program
//   -h, --help   show this text and exit

import lexer from "./lexer.y";
import parser from "./parser.y";
import nasm from "./asm.y";
import nativelib from "./native.y";

// ── argument parsing ─────────────────────────────────────────────────────

def parse_cli_args(argv: [str]) -> { out: str, files: [str], asm_only: bool, timing: bool, allow_exec: bool, debug: bool, std_src: bool, std_pack: str } {
    let out = "";
    let files = [];
    let asm_only = false;
    let timing = false;
    let allow_exec = true;
    let debug = false;
    let std_src = false;
    let std_pack = "";
    let i = 1;  // skip argv[0]
    let n = len(argv);
    while (i < n) {
        let a = argv[i];
        if (a == "-o") {
            if (i + 1 < n) {
                i = i + 1;
                out = argv[i];
            } else {
                puts("ycc: -o needs an argument\n");
                exit(1);
            };
        } else if (a == "-S") {
            asm_only = true;
        } else if (a == "--time" || a == "-t") {
            timing = true;
        } else if (a == "--no-exec") {
            allow_exec = false;
        } else if (a == "-g") {
            debug = true;
        } else if (a == "--std-src") {
            std_src = true;
        } else if (a == "--std-pack") {
            if (i + 1 < n) {
                i = i + 1;
                std_pack = argv[i];
            } else {
                puts("ycc: --std-pack needs an argument\n");
                exit(1);
            };
        } else if (a == "--help" || a == "-h") {
            puts("Usage: ycc [-o OUTPUT] [-S] [-t] [-g] [--no-exec] [-h] FILE\n");
            puts("  (no flags)   compile FILE to a native executable (default: a.out)\n");
            puts("  -o OUTPUT    output path (executable, or .s file with -S)\n");
            puts("  -S           emit assembly only (stdout, or the -o file)\n");
            puts("  -t, --time   print per-phase time and heap use to stderr\n");
            puts("  -g           add section headers, a symbol table (functions,\n");
            puts("               globals) and DWARF line info, so perf, gdb,\n");
            puts("               valgrind and addr2line show names and source\n");
            puts("               lines; the loaded code and data are unchanged\n");
            puts("  --no-exec    omit exec() -- the binary cannot reach a shell\n");
            puts("  --std-src    compile the std units (the runtime and std library)\n");
            puts("               from source instead of using the precompiled ones\n");
            puts("               attached to ycc; the output is the same\n");
            puts("  --std-pack FILE  compile the std units and write them to FILE,\n");
            puts("               to attach to a ycc binary (the build does)\n");
            puts("  -h, --help   show this text and exit\n");
            exit(0);
        } else if (a[0:1] == "-") {
            puts("ycc: unknown flag '" + a + "' (see ycc -h)\n");
            exit(1);
        } else {
            files += a;
        };
        i = i + 1;
    };
    { out: out, files: files, asm_only: asm_only, timing: timing, allow_exec: allow_exec, debug: debug, std_src: std_src, std_pack: std_pack }
};

// ── the std pack ─────────────────────────────────────────────────────────
// The build attaches to ycc its std units, compiled (native.y std_pack):
// the binary ends with [pack][the pack's length, 8 digits][YCCPACK1].

def pack_magic() -> str {
    "YCCPACK1"
};

// The pack attached to this binary, or "" when there is none.
def self_pack() -> str {
    let fd = syscall(257, -100, "/proc/self/exe", 0, 0);
    if (fd < 0) {
        ""
    } else {
        let pack = "";
        let size = syscall(8, fd, 0, 2);
        if (size >= 16) {
            let buf: [byte; 65536] = [0; 65536];
            syscall(8, fd, size - 16, 0);
            let k = syscall(0, fd, &buf[0], 16);
            if (k == 16) {
                let tail = from_bytes(buf[0:16]);
                let n = tonum(tail[:8]);
                if (tail[8:] == pack_magic() && n > 0 && n <= size - 16) {
                    syscall(8, fd, size - 16 - n, 0);
                    let pieces: [str] = [];
                    let left = n;
                    while (left > 0) {
                        let want = left;
                        if (want > 65536) { want = 65536; 0; } else { 0; };
                        let got = syscall(0, fd, &buf[0], want);
                        if (got <= 0) {
                            left = -1;
                            0
                        } else {
                            // (a slice copies byte by byte: only a part chunk pays it)
                            if (got == 65536) { pieces += from_bytes(buf); 0; } else { pieces += from_bytes(buf[0:got]); 0; };
                            left = left - got;
                            0
                        };
                    };
                    if (left == 0) { pack = join(pieces, ""); 0; } else { 0; };
                    0
                } else { 0; };
                0
            } else { 0; };
            0
        } else { 0; };
        syscall(3, fd);
        pack
    }
};

// --std-pack FILE: every std unit, compiled from source, framed for
// attaching (see self_pack).
def write_std_pack(path: str) -> long {
    let pack = nativelib.std_pack(nativelib.std_units(nativelib.std_unit_names(), ""));
    let nd = tostring(len(pack));
    while (len(nd) < 8) { nd = "0" + nd; };
    if (len(nd) > 8) {
        puts("error: the std pack is too large (" + nd + " bytes)\n");
        exit(1);
        0
    } else { 0; };
    if (!write_file(path, pack + nd + pack_magic())) {
        puts("error: writing '" + path + "' failed\n");
        exit(1);
        0
    } else { 0; };
    0
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

// Microseconds as fixed-point milliseconds, integer arithmetic only: the C
// twin formats the same way, so both copies print the same string.
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
    // NOTE: vestigial alias — `times[i]` parses and typechecks in both
    // copies today; the binding stays only because the compiled compiler
    // is byte-gated against refs/ycc.ref.
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

def print_native_errors(errors: [{ msg: str, line: long, col: long }], origin: { files: [str], nuser: long, file: [long], line: [long] }) -> long {
    // NOTE: vestigial alias (see print_phase_rows) — `errors[i]` works.
    // Positions are lines of the spliced program (std chunks and imported
    // modules included); the origin map turns each back into the file it
    // came from: `line:col` in the program's own file, `path:line:col` in
    // any other.
    let all = errors;
    // One error per position: a malformed token can trip two checks (the
    // construct it broke, then the statement it ended), and the second
    // message only repeats the first.
    let seen: [str] = [];
    let i = 0;
    while (i < len(all)) {
        let e = all[i];
        let at = nativelib.origin_at(origin, e.line, true) + ":" + tostring(e.col);
        let dup = false;
        foreach (s in seen) {
            if (s == at) { dup = true; 0; } else { 0; };
        };
        if (!dup) {
            seen += at;
            puts(at + ": error: " + e.msg + "\n");
            0
        } else { 0; };
        i = i + 1;
    };
    0
};

def main(cmdline: [str]) -> long {
    let args = parse_cli_args(cmdline);
    // NOTE: vestigial alias (see print_phase_rows) — `args.out` works.
    let pargs = args;
    let out = pargs.out;
    let files = pargs.files;

    if (len(pargs.std_pack) > 0) {
        write_std_pack(pargs.std_pack);
        exit(0);
        0
    } else if (len(files) == 0) {
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
                base_dir = file[0:last_slash];
                0
            } else { 0; };

            // splice imports, tokenize, parse, compile to assembly
            let t0 = clock_us();
            let h0 = heap_used();
            let tstart = t0;
            let hstart = h0;
            let dt: [{ name: str, us: long, heap: long }] = [];
            let nr = nativelib.native_resolve_x(src2, base_dir, 0, pargs.allow_exec, file);
            let ph = nativelib.phase_end(dt, "resolve", t0, h0);
            dt = ph.times; t0 = ph.t; h0 = ph.h;
            let nrsrc = nr.src;
            let nrimports = nr.imports;
            let nrorigin = nr.origin;
            let toks = lexer.tokenize(nrsrc);
            ph = nativelib.phase_end(dt, "tokenize", t0, h0);
            dt = ph.times; t0 = ph.t; h0 = ph.h;
            let ast = parser.parse_program(toks);
            ph = nativelib.phase_end(dt, "parse", t0, h0);
            dt = ph.times; t0 = ph.t; h0 = ph.h;
            // The std units the program links (native_resolve_x picked
            // them): the ones attached to ycc, compiled when it was built,
            // or (--std-src, or a ycc with none) compiled from the sources
            // embedded in it.
            let nrstd = nr.std;
            let pack = "";
            if (!pargs.std_src) { pack = self_pack(); 0; } else { 0; };
            let su = nativelib.std_units(nrstd, pack);
            ph = nativelib.phase_end(dt, "std", t0, h0);
            dt = ph.times; t0 = ph.t; h0 = ph.h;
            let r = nativelib.emit_program(ast, nrimports, nrorigin, pargs.debug, su);
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
            let rok = r.ok;
            if (!rok) {
                print_native_errors(r.errors, nrorigin);
                exit(1);
                1
            } else if (pargs.asm_only) {
                let rasm = r.asm;
                let wrote = true;
                if (len(out) == 0) {
                    puts(rasm);
                    0
                } else {
                    // Checked, like the executable path below: silently
                    // exiting 0 after a failed write hid bad -o paths.
                    wrote = write_file(out, rasm);
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
                if (!(wrote)) {
                    puts("error: writing '" + out + "' failed\n");
                    exit(1);
                    1
                } else {
                    0
                }
            } else {
                // Assemble to a [byte] buffer in-process (no as/ld/cc) and write the
                // executable DIRECTLY with the write_bytes builtin
                // (binary-safe open/write/chmod, tinycc-style — NULs pass
                // through as array elements, no shell, no exec/printf).
                let rasm2 = r.asm;
                let ab = nasm.ycc_assemble(rasm2, pargs.debug);
                ph = nativelib.phase_end(dt, "assemble", t0, h0);
                dt = ph.times; t0 = ph.t; h0 = ph.h;
                // ycc_assemble reports its own sub-phases: a:split,
                // a:encode, a:link, then l:labmap, l:patch, l:elf.
                let asub = ab.times;
                let ai = 0;
                while (ai < len(asub)) {
                    let ae = asub[ai];
                    dt += ae;
                    ai = ai + 1;
                };
                let abok = ab.ok;
                if (!abok) {
                    puts("error: assemble: " + ab.error + "\n");
                    exit(1);
                    1
                } else {
                    let out_path = out;
                    if (len(out_path) == 0) { out_path = "a.out"; 0; } else { 0; };
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
                    if (!ok) {
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
