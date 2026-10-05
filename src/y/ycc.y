// ycc — the Y compiler. Compiles Y source straight to a native
// executable (Linux x86_64) with no toolchain: no cc, no as, no ld,
// no libc. Usage: ycc [-o OUTPUT] [-S] [-t] [-g] [-w] [--no-exec] [-h] FILE
//   (no flags)   compile FILE to a native executable (default output: a.out)
//   -o OUTPUT    output path (executable, or .s file with -S)
//   -S           emit assembly only (stdout, or the -o file)
//   -t, --time   print per-phase time and heap use to stderr
//   -g           add a symbol table and DWARF line info (for perf, gdb,
//                valgrind, addr2line; see -h)
//   -w           do not print warnings (lint.y)
//   --std-src    compile the std units from source, not the attached pack
//   --std-pack FILE  write the compiled std units to FILE, no program
//   -h, --help   show this text and exit
// A project (a directory with a y.toml manifest, see pkg.y):
//   ycc build [-g] [-w] [--no-exec] [--std-src] [DIR]   build its programs
//   ycc vendor [DIR]   copy its git dependencies into DIR/vendor

import tags from "./tags.y";
import lexer from "./lexer.y";
import parser from "./parser.y";
import nasm from "./asm.y";
import nativelib from "./native.y";
import pkg from "./pkg.y";
import fs;

// ── argument parsing ─────────────────────────────────────────────────────

def parse_cli_args(argv: [str]) -> { out: str, files: [str], asm_only: bool, timing: bool, allow_exec: bool, debug: bool, nowarn: bool, wlevel: long, std_src: bool, std_pack: str } {
    let out = "";
    let files: [str] = [];
    let asm_only = false;
    let timing = false;
    let allow_exec = true;
    let debug = false;
    let nowarn = false;
    let wlevel = 0;
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
                if (len(out) == 0) {
                    // an empty path used to be taken for "no -o", and the
                    // binary landed in ./a.out -- a silent write to the
                    // wrong place, which `make` scripts get wrong in turn
                    puts("ycc: -o needs a path, got ''\n");
                    exit(1);
                };
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
        } else if (a == "-w") {
            nowarn = true;
        } else if (a == "-W") {
            wlevel = wlevel_arg(argv, i, n);
            i = i + 1;
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
            puts("Usage: ycc [-o OUTPUT] [-S] [-t] [-g] [-w] [-W N] [--no-exec] [-h] FILE\n");
            puts("       ycc build [-g] [-w] [-W N] [--no-exec] [--std-src] [DIR]\n");
            puts("       ycc vendor [DIR]\n");
            puts("  (no flags)   compile FILE to a native executable (default: a.out)\n");
            puts("  -o OUTPUT    output path (executable, or .s file with -S)\n");
            puts("  -S           emit assembly only (stdout, or the -o file)\n");
            puts("  -t, --time   print per-phase time and heap use to stderr\n");
            puts("  -g           add section headers, a symbol table (functions,\n");
            puts("               globals) and DWARF line info, so perf, gdb,\n");
            puts("               valgrind and addr2line show names and source\n");
            puts("               lines; the loaded code and data are unchanged\n");
            puts("  -w           do not print warnings (they go to stderr and\n");
            puts("               never change the output)\n");
            puts("  -W N         warning level N; 0 (the default) is the usual\n");
            puts("               set, 1 adds the optional checks for a value\n");
            puts("               computed and dropped -- a call result nobody\n");
            puts("               reads, a bare a[i] or x.f as a statement,\n");
            puts("               an else branch that does nothing\n");
            puts("  --no-exec    omit exec() -- the binary cannot reach a shell\n");
            puts("  --std-src    compile the std units (the runtime and std library)\n");
            puts("               from source instead of using the precompiled ones\n");
            puts("               attached to ycc; the output is the same\n");
            puts("  --std-pack FILE  compile the std units and write them to FILE,\n");
            puts("               to attach to a ycc binary (the build does)\n");
            puts("  -h, --help   show this text and exit\n");
            puts("  build [DIR]  build the project in DIR (default .) as its y.toml\n");
            puts("               says: each [bin] into DIR/build, every package it\n");
            puts("               depends on compiled once (DIR/build/obj keeps them)\n");
            puts("  vendor [DIR] copy the project's git dependencies into DIR/vendor\n");
            exit(0);
        } else if (a[0:1] == "-") {
            puts("ycc: unknown flag '" + a + "' (see ycc -h)\n");
            exit(1);
        } else {
            files += a;
        };
        i = i + 1;
    };
    { out: out, files: files, asm_only: asm_only, timing: timing, allow_exec: allow_exec, debug: debug, nowarn: nowarn, wlevel: wlevel, std_src: std_src, std_pack: std_pack }
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
                        if (want > 65536) { want = 65536; }
                        let got = syscall(0, fd, &buf[0], want);
                        if (got <= 0) {
                            left = -1;
                        } else {
                            // (a slice copies byte by byte: only a part chunk pays it)
                            if (got == 65536) { pieces += from_bytes(buf); } else { pieces += from_bytes(buf[0:got]); };
                            left = left - got;
                        };
                    };
                    if (left == 0) { pack = join(pieces, ""); }
                }
            }
        }
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
    }
    if (!fs.write_file(path, pack + nd + pack_magic())) {
        puts("error: writing '" + path + "' failed\n");
        exit(1);
    }
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

def print_phase_rows(times: [Timing]) -> long {
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

def print_native_errors(errors: [Diag], origin: Origin, bare: bool) -> long {
    // NOTE: vestigial alias (see print_phase_rows) — `errors[i]` works.
    // Positions are lines of the spliced program (std chunks and imported
    // modules included); the origin map turns each back into the file it
    // came from: `line:col` in the program's own file (unless not `bare`:
    // `ycc build` names every file), `path:line:col` in any other.
    let all = errors;
    // One error per position: a malformed token can trip two checks (the
    // construct it broke, then the statement it ended), and the second
    // message only repeats the first.
    let seen: [str] = [];
    let i = 0;
    while (i < len(all)) {
        let e = all[i];
        let at = nativelib.origin_at(origin, e.line, bare) + ":" + tostring(e.col);
        let dup = false;
        foreach (s in seen) {
            if (s == at) { dup = true; }
        };
        if (!dup) {
            seen += at;
            puts(at + ": error: " + e.msg + "\n");
        }
        i = i + 1;
    };
    0
};

// What lint.y found in a unit that compiled, as `at: warning: msg` on
// stderr (a -S listing on stdout stays clean), each position as
// print_native_errors gives it. lint_unit sorted them and dropped repeats.
def print_native_warnings(warnings: [Diag], origin: Origin, bare: bool) -> long {
    let i = 0;
    while (i < len(warnings)) {
        let w = warnings[i];
        eputs(nativelib.origin_at(origin, w.line, bare) + ":" + tostring(w.col) + ": warning: " + w.msg + "\n");
        i = i + 1;
    };
    0
};

// ── ycc build / ycc vendor (see pkg.y) ───────────────────────────────────

def build_args(cl: [str]) -> { dir: str, debug: bool, nowarn: bool, wlevel: long, allow_exec: bool, std_src: bool } {
    let dir = "";
    let debug = false;
    let nowarn = false;
    let wlevel = 0;
    let allow_exec = true;
    let std_src = false;
    let i = 2;  // skip the program and the command
    while (i < len(cl)) {
        let a = cl[i];
        if (a == "-g") {
            debug = true;
        } else if (a == "-w") {
            nowarn = true;
        } else if (a == "-W") {
            wlevel = wlevel_arg(cl, i, len(cl));
            i = i + 1;
        } else if (a == "--no-exec") {
            allow_exec = false;
        } else if (a == "--std-src") {
            std_src = true;
        } else if (a[0:1] == "-") {
            puts("ycc: unknown flag '" + a + "' (see ycc -h)\n");
            exit(1);
        } else if (len(dir) > 0) {
            puts("error: ycc " + cl[1] + " takes one project directory\n");
            exit(1);
        } else {
            dir = a;
        };
        i = i + 1;
    };
    if (len(dir) == 0) { dir = "."; }
    { dir: dir, debug: debug, nowarn: nowarn, wlevel: wlevel, allow_exec: allow_exec, std_src: std_src }
};

// One unit's text, resolved: its bare imports may name the packages
// `pkgs` and look in the source roots `roots` (native_resolve_pk).
def build_resolve(path: str, allow_exec: bool, pkgs: [str], roots: [str]) -> Resolved {
    let src = fs.read_file(path);
    if (src == none) {
        puts("error: cannot read file '" + path + "'\n");
        exit(1);
    }
    nativelib.native_resolve_pk(unwrap(src), pkg.pk_dir_of(path), allow_exec, path, pkgs, roots)
};

// The std units among `names`, in link order.
def std_order(names: [str]) -> [str] {
    let all = nativelib.std_unit_names();
    let out: [str] = [];
    let i = 0;
    while (i < len(all)) {
        let nm: str = all[i];
        if (pkg.pk_has(names, nm)) { out += nm; }
        i = i + 1;
    };
    out
};

def longs_text(xs: [long]) -> str {
    let out: [str] = [];
    let i = 0;
    while (i < len(xs)) {
        out += tostring(xs[i]);
        i = i + 1;
    };
    join(out, ",")
};

// What a package's object is valid for: this compiler, the package's
// place among the units (its labels count from `base`), its resolved
// text and where each line came from, and the interfaces of the
// packages it imports (among `units`, unit_iface).
def build_key(cid: str, name: str, base: long, allow_exec: bool, nr: Resolved, units: [Unit]) -> str {
    let h = pkg.pk_hash_new();
    pkg.pk_hash_str(h, cid);
    pkg.pk_hash_str(h, name);
    pkg.pk_hash_str(h, tostring(base));
    let ex = "exec";
    if (!allow_exec) { ex = "no-exec"; }
    pkg.pk_hash_str(h, ex);
    pkg.pk_hash_str(h, nr.src);
    let o = nr.origin;
    pkg.pk_hash_str(h, join(o.files, "\n"));
    pkg.pk_hash_str(h, longs_text(o.file));
    pkg.pk_hash_str(h, longs_text(o.line));
    pkg.pk_hash_str(h, join(nr.std, ","));
    let ps = nr.pkgs;
    pkg.pk_hash_str(h, join(ps, ","));
    let i = 0;
    while (i < len(units)) {
        let u = units[i];
        if (pkg.pk_has(ps, u.name)) { pkg.pk_hash_str(h, nativelib.unit_iface(u)); }
        i = i + 1;
    };
    pkg.pk_hash_text(h)
};

// Which of the packages `pkgs` (each after its dependencies) a unit
// importing `direct` links: those, and every package they import.
def build_reach(direct: [str], pkgs: [PkNode], nrs: [Resolved]) -> [bool] {
    let want: [str] = [];
    want += direct;
    let reach: [bool] = [];
    let k = 0;
    while (k < len(pkgs)) {
        reach += false;
        k = k + 1;
    };
    k = len(pkgs) - 1;
    while (k >= 0) {
        let p = pkgs[k];
        if (pkg.pk_has(want, p.name)) {
            reach[k] = true;
            let nr = nrs[k];
            want += nr.pkgs;
        }
        k = k - 1;
    };
    reach
};

// The decimal level after `-W`, or the flag's own complaint. `i` points at
// "-W". Only 0 and 1 exist, so anything else is rejected -- and the scan
// saturates, because a long enough digit run wraps the accumulator and
// "-W 99999999999999999999" would come back as an accepted level.
def wlevel_arg(argv: [str], i: long, n: long) -> long {
    if (i + 1 >= n) {
        puts("ycc: -W needs a warning level (0, or 1)\n");
        exit(1);
        0
    } else {
        let a = argv[i + 1];
        let ok = len(a) > 0 && a[0:1] != "-";
        let v = 0;
        let d = 0;
        while (ok && d < len(a)) {
            let c = byte_at(a, d);
            ok = c >= c'0' && c <= c'9';
            if (ok && v <= 1) { v = v * 10 + (c - c'0'); 0; };
            d = d + 1;
        };
        if (!ok || v > 1) {
            puts("ycc: -W needs a warning level (0, or 1), got '" + a + "'\n");
            exit(1);
            0
        } else {
            v
        }
    }
};

// `ycc build`: every package the project depends on (and its own lib),
// each from its object in DIR/build/obj when that is current, else
// compiled and its object written; then each [bin], linked with the
// packages it reaches, to DIR/build/NAME. A unit's warnings show when it
// is compiled (unless `nowarn`), not when its object is reused.
def build_project(dir: str, debug: bool, nowarn: bool, wlevel: long, allow_exec: bool, std_src: bool) -> long {
    let g = pkg.pk_load(dir);
    let bins = g.bins;
    let pkgs = g.pkgs;
    if (len(bins) == 0 && len(g.lib) == 0) {
        puts("error: " + pkg.pk_join(dir, "y.toml") + " has no [bin] and no lib: nothing to build\n");
        exit(1);
    }
    let bdir = pkg.pk_join(dir, "build");
    let odir = bdir + "/obj";
    pkg.pk_mkdir(bdir);
    pkg.pk_mkdir(odir);
    // every unit's text: the packages' (each importing its own
    // dependencies), then the bins' (the project's, and its lib)
    let nrs: [Resolved] = [];
    let k = 0;
    while (k < len(pkgs)) {
        let p = pkgs[k];
        nrs += build_resolve(p.lib, allow_exec, p.deps, p.roots);
        k = k + 1;
    };
    let bdeps: [str] = [];
    bdeps += g.deps;
    if (len(g.lib) > 0) { bdeps += g.name; }
    let b = 0;
    while (b < len(bins)) {
        let bn = bins[b];
        nrs += build_resolve(bn.path, allow_exec, bdeps, g.roots);
        b = b + 1;
    };
    let needs: [str] = [];
    k = 0;
    while (k < len(nrs)) {
        let nr = nrs[k];
        needs += nr.std;
        k = k + 1;
    };
    let pack = "";
    if (!std_src) { pack = self_pack(); }
    let su = nativelib.std_units(std_order(needs), pack);
    let cid = pkg.pk_self_id();
    let units: [Unit] = [];
    k = 0;
    while (k < len(pkgs)) {
        let p = pkgs[k];
        let nr = nrs[k];
        let base = 5000000000 + k * 1000000000;
        let key = build_key(cid, p.name, base, allow_exec, nr, units);
        let opath = odir + "/" + p.name + ".yo";
        let hit = false;
        let ot = fs.read_file(opath);
        if (ot != none) {
            let uo = nativelib.unit_unobj(unwrap(ot), key);
            if (uo.ok) { units += uo.unit; hit = true; }
        }
        if (!hit) {
            eputs("compiling " + p.name + "\n");
            let ast = parser.parse_program(lexer.tokenize(nr.src));
            let r = nativelib.compile_package(ast, nr, p.name, base, wlevel, su, units);
            if (!r.ok) {
                print_native_errors(r.errors, nr.origin, false);
                exit(1);
            }
            if (!nowarn) {
                print_native_warnings(r.warnings, nr.origin, false);
            };
            if (!fs.write_file(opath, nativelib.unit_obj(r.unit, key))) {
                puts("error: writing '" + opath + "' failed\n");
                exit(1);
            }
            units += r.unit;
        }
        k = k + 1;
    };
    b = 0;
    while (b < len(bins)) {
        let bn = bins[b];
        let nr = nrs[len(pkgs) + b];
        let reach = build_reach(nr.pkgs, pkgs, nrs);
        let linked: [Unit] = [];
        let lneeds: [str] = [];
        lneeds += nr.std;
        k = 0;
        while (k < len(pkgs)) {
            if (reach[k]) {
                linked += units[k];
                let pn = nrs[k];
                lneeds += pn.std;
            }
            k = k + 1;
        };
        let lstd = std_order(lneeds);
        let bstd: [Unit] = [];
        k = 0;
        while (k < len(su)) {
            let su1 = su[k];
            if (pkg.pk_has(lstd, su1.name)) { bstd += su1; }
            k = k + 1;
        };
        let ast = parser.parse_program(lexer.tokenize(nr.src));
        let r = nativelib.emit_program(ast, nr, debug, wlevel, bstd, linked);
        if (!r.ok) {
            print_native_errors(r.errors, nr.origin, false);
            exit(1);
        }
        if (!nowarn) {
            print_native_warnings(r.warnings, nr.origin, false);
        };
        let ab = nasm.ycc_assemble(r.asm, debug);
        if (!ab.ok) {
            puts("error: assemble: " + ab.error + "\n");
            exit(1);
        }
        let outp = bdir + "/" + bn.name;
        if (!fs.write_bytes(outp, ab.bytes, 493)) {
            puts("error: writing '" + outp + "' failed\n");
            exit(1);
        }
        eputs("built " + outp + "\n");
        b = b + 1;
    };
    0
};

def main(cmdline: [str]) -> long {
    // tags.y writes its tag numbers out twice (K for the code, KTAGS for
    // diagnostics); ~4k instructions to prove the two still agree, once.
    if (!tags.tags_agree()) {
        puts("ycc: internal error: the tag tables disagree (src/y/tags.y)\n");
        exit(1);
        0
    }
    // ... and the nesting limit, which the two copies must also hold the same.
    if (!tags.max_nest_agree()) {
        puts("ycc: internal error: the nesting limit disagrees (src/y/tags.y)\n");
        exit(1);
        0
    }
    if (len(cmdline) > 1 && (cmdline[1] == "build" || cmdline[1] == "vendor")) {
        let ba = build_args(cmdline);
        if (cmdline[1] == "build") {
            build_project(ba.dir, ba.debug, ba.nowarn, ba.wlevel, ba.allow_exec, ba.std_src);
            0
        } else {
            pkg.pk_vendor(ba.dir);
            0
        };
        exit(0);
        0
    }
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
        let src = fs.read_file(file);
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
            }

            // splice imports, tokenize, parse, compile to assembly
            let t0 = clock_us();
            let h0 = heap_used();
            let tstart = t0;
            let hstart = h0;
            let dt: [Timing] = [];
            let nr = nativelib.native_resolve_x(src2, base_dir, 0, pargs.allow_exec, file);
            let ph = nativelib.phase_end(dt, "resolve", t0, h0);
            dt = ph.times; t0 = ph.t; h0 = ph.h;
            let nrsrc = nr.src;
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
            if (!pargs.std_src) { pack = self_pack(); 0; }
            let su = nativelib.std_units(nrstd, pack);
            ph = nativelib.phase_end(dt, "std", t0, h0);
            dt = ph.times; t0 = ph.t; h0 = ph.h;
            let r = nativelib.emit_program(ast, nr, pargs.debug, pargs.wlevel, su, []);
            // emit_program reports its own sub-phases (strip_ns, rename,
            // typecheck, lint, emit_fns, emit_start, asm_text); splice them in.
            let sub = r.times;
            let si = 0;
            while (si < len(sub)) {
                let se = sub[si];
                dt += se;
                si = si + 1;
            };
            if (r.ok && !pargs.nowarn) {
                print_native_warnings(r.warnings, nrorigin, true);
            };
            t0 = clock_us();
            h0 = heap_used();
            let rok = r.ok;
            if (!rok) {
                print_native_errors(r.errors, nrorigin, true);
                exit(1);
                1
            } else if (pargs.asm_only) {
                let rasm = nativelib.link_text(r.asm);
                let wrote = true;
                if (len(out) == 0) {
                    puts(rasm);
                    0
                } else {
                    // Checked, like the executable path below: silently
                    // exiting 0 after a failed write hid bad -o paths.
                    wrote = fs.write_file(out, rasm);
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
                }
                if (!(wrote)) {
                    puts("error: writing '" + out + "' failed\n");
                    exit(1);
                    1
                } else {
                    0
                }
            } else {
                // Assemble to a [byte] buffer in-process (no as/ld/cc) and write the
                // executable DIRECTLY with fs.write_bytes
                // (binary-safe open/write/chmod, tinycc-style — NULs pass
                // through as array elements, no shell, no exec/printf).
                let ab = nasm.ycc_assemble(r.asm, pargs.debug);
                // The assembly text itself is not built on this path any more
                // (the assembler reads the emitter's items), so the size
                // counter here is the item count; -S still reports asm_bytes.
                let abitems = ab.items;
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
                    if (len(out_path) == 0) { out_path = "a.out"; 0; }
                    let abbytes = ab.bytes;
                    // 493 = 0755 executable (chmod applied by write_bytes).
                    let ok = fs.write_bytes(out_path, abbytes, 493);
                    ph = nativelib.phase_end(dt, "write", t0, h0);
                    dt = ph.times;
                    if (pargs.timing) {
                        eputs("ycc --time: " + file + "\n");
                        print_phase_rows(dt);
                        eputs("  " + padr("TOTAL", 12) + padl(fmt_ms(clock_us() - tstart), 12) + " ms" + padl(fmt_kb(heap_used() - hstart), 12) + " KB\n");
                        print_counter("src_bytes", len(nrsrc));
                        print_counter("tokens", len(toks));
                        print_counter("asm_items", abitems);
                        print_counter("out_bytes", len(abbytes));
                        0
                    }
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
