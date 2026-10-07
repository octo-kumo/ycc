// ycc — the Y compiler. Compiles Y source straight to a native
// executable (Linux x86_64) with no toolchain: no cc, no as, no ld,
// no libc. Usage: ycc [-o OUTPUT] [-S] [-t] [-g] [-w] [--no-exec] [-h] FILE
//   (no flags)   compile FILE to a native executable (default output: a.out)
//   -o OUTPUT    output path (executable, or .s file with -S)
//   -S           emit assembly only (stdout, or the -o file)
//   -t, --time   print per-phase time and heap use to stderr
//   --target=NAME  object format and OS: linux (the default) or windows
//   -g           add a symbol table and DWARF line info (for perf, gdb,
//                valgrind, addr2line; see -h)
//   -w           do not print warnings (lint.y)
//   --std-src    compile the std units from source, not the attached pack
//   --std-pack FILE  write the compiled std units to FILE, no program
//   -h, --help   show this text and exit
// A project (a directory with a y.toml manifest, see pkg.y):
//   ycc build [-g] [-w] [--no-exec] [--std-src] [DIR]   build its programs
//                (a ready level of packages compiles in parallel: build_dispatch)
//   ycc vendor [DIR]   copy its git dependencies into DIR/vendor

import tags from "./tags.y";
import wintgt from "./target.y";
import lexer from "./lexer.y";
import parser from "./parser.y";
import nasm from "./asm.y";
import nativelib from "./native.y";
import meta from "./meta.y";
import pkg from "./pkg.y";
import lint from "./lint.y";
import fs;

// ── argument parsing ─────────────────────────────────────────────────────

def parse_cli_args(argv: [str]) -> { out: str, files: [str], asm_only: bool, timing: bool, allow_exec: bool, debug: bool, nowarn: bool, wlevel: long, std_src: bool, std_pack: str, run: bool, dump: bool, prog: [str], fix: bool } {
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
    let run = false;
    let dump = false;
    let prog: [str] = [];
    let fix = false;
    let i = 1;  // skip argv[0]
    let n = len(argv);
    while (i < n) {
        let a = argv[i];
        if (a == "-o") {
            if (i + 1 < n) {
                i++;
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
        } else if (a[0:9] == "--target=") {
            parse_target(a[9:]);
        } else if (a == "--target") {
            if (i + 1 < n) {
                i++;
                parse_target(argv[i]);
            } else {
                puts("ycc: --target needs a name (linux, windows)\n");
                exit(1);
            };
        } else if (a == "-E") {
            // dump the source the lexer would see, with origin markers, and
            // stop: no tokens, no check, no output file.
            dump = true;
        } else if (a == "run") {
            run = true;
        } else if (a == "--time" || a == "-t") {
            timing = true;
        } else if (a == "--no-exec") {
            allow_exec = false;
        } else if (a == "-g") {
            debug = true;
        } else if (a == "-w") {
            nowarn = true;
        } else if (a == "--fix") {
            // Apply the level-2 shortenings to the source in place. Warning
            // level 2 is what names them, so --fix implies it.
            fix = true;
            if (wlevel < 2) { wlevel = 2; };
        } else if (a == "-W") {
            wlevel = wlevel_arg(argv, i, n);
            i++;
        } else if (a == "--gc-stress") {
            // A cycle at every allocating slow path: the collector's strongest
            // test (native.y set_gc_stress). It implies the collector.
            nativelib.set_gc_stress(true);
        } else if (a == "--no-gc") {
            nativelib.set_gc_mode(2);
        } else if (a[0:5] == "--gc=") {
            // Whether the collector is linked: auto (the default) decides from
            // the program, always and never say so outright. The decision lives
            // in native.y's link_units; this only records the wish.
            let m: str = a[5:];
            if (m == "auto") { nativelib.set_gc_mode(0) }
            else if (m == "always") { nativelib.set_gc_mode(1) }
            else if (m == "never") { nativelib.set_gc_mode(2) }
            else {
                puts("ycc: --gc wants auto, always or never, got '" + m + "'\n");
                exit(1);
            };
        } else if (a == "--std-src") {
            std_src = true;
        } else if (a == "--std-pack") {
            if (i + 1 < n) {
                i++;
                std_pack = argv[i];
            } else {
                puts("ycc: --std-pack needs an argument\n");
                exit(1);
            };
        } else if (a == "--help" || a == "-h") {
            puts("Usage: ycc [-o OUTPUT] [-S] [-E] [-t] [-g] [-w] [-W N] [--fix] [--no-exec] [-h] FILE\n");
            puts("       ycc run [-g] [--no-exec] FILE [-- ARG...]\n");
            puts("                                       compile FILE and run it in a\n");
            puts("                                       child; ycc's exit status is\n");
            puts("                                       the program's, and ARG... is\n");
            puts("                                       the program's own argv\n");
            puts("       ycc build [-g] [-w] [-W N] [--no-exec] [--std-src] [DIR]\n");
            puts("       ycc vendor [DIR]\n");
            puts("  (no flags)   compile FILE to a native executable (default: a.out)\n");
            puts("  -o OUTPUT    output path (executable, or .s file with -S)\n");
            puts("  -S           emit assembly only (stdout, or the -o file)\n");
            puts("  --target=NAME  emit for NAME: linux (the default, an ELF)\n");
            puts("               or windows (a PE32+ executable, x64)\n");
            puts("  -E           dump the source the lexer sees, each line tagged with\n");
            puts("               the file and line it came from, and stop\n");
            puts("  run FILE [-- ARG...]  compile FILE and run it in a forked child:\n");
            puts("               no output file, and ycc exits with the program's\n");
            puts("               status; everything after `--` is the program's argv\n");
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
            puts("               an else branch that does nothing; 2 adds the\n");
            puts("               shortening suggestions of LINT_RULES.md\n");
            puts("  --fix        apply the level-2 shortenings of LINT_RULES.md to\n");
            puts("               the source files in place (implies -W 2), then\n");
            puts("               stop; the emitted bytes never depend on this\n");
            puts("  --no-exec    omit exec() -- the binary cannot reach a shell\n");
            puts("  --gc-stress  run a collection at every allocating slow path: the\n");
            puts("               collector's own test, and a very slow build. It\n");
            puts("               implies the collector. --no-gc is --gc=never.\n");
            puts("  --gc=MODE    the collector: auto (the default) links it only\n");
            puts("               when an allocation can happen in a loop or a\n");
            puts("               recursion; always and never force it. Without the\n");
            puts("               collector a program is smaller but its heap never\n");
            puts("               reclaims.\n");
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
        } else if (a == "--" && run) {
            // Everything after `--` is the program's own argv, verbatim:
            // `ycc run p.y -- -x foo` hands the program ["-x", "foo"], so a
            // test can drive argv without the driver reading the program's
            // flags as its own. Without `run`, `--` stays an unknown flag.
            i++;
            while (i < n) {
                prog += argv[i];
                i++;
            };
        } else if (a[0:1] == "-") {
            puts("ycc: unknown flag '" + a + "' (see ycc -h)\n");
            exit(1);
        } else {
            files += a;
        };
        i++;
    };
    { out: out, files: files, asm_only: asm_only, timing: timing, allow_exec: allow_exec, debug: debug, nowarn: nowarn, wlevel: wlevel, std_src: std_src, std_pack: std_pack, run: run, dump: dump, prog: prog, fix: fix }
};

// --target NAME: the one place a target name becomes the global every other
// place reads (src/y/target.y).  A bad name is a driver failure with the
// accepted spellings, not a silently-defaulted build: a program compiled for
// the wrong OS is worse than one that did not compile.
def parse_target(name: str) -> void {
    if (name == "linux") {
        res_target = "linux";
    } else if (name == "windows") {
        res_target = "windows";
    } else {
        puts("ycc: unknown target '" + name + "' (linux, windows)\n");
        exit(1);
    };
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
            if ((syscall(0, fd, &buf[0], 16)) == 16) {
                let tail = from_bytes(buf[0:16]);
                // tolong answers an OPTION now, and this is the site that
                // shows why that is the right shape: a binary with no pack has
                // whatever the linker left in its last 16 bytes, so the size
                // field is not a number at all (measured: eight spaces). The
                // old tolong read that as 0 and the `n > 0` below rejected it,
                // which worked by accident; with `!` it would TRAP instead.
                let nopt = tolong(tail[:8]);
                if (nopt != none && tail[8:] == pack_magic() && nopt ! > 0 && nopt ! <= size - 16) {
                    let n = nopt !;
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
def write_std_pack(path: str) -> void {
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
    let fs = tostring((us % 1000));
    while (len(fs) < 3) { fs = "0" + fs; };
    tostring(ms) + "." + fs
};

def fmt_kb(b: long) -> str {
    tostring(b / 1024)
};

def print_phase_rows(all: [Timing]) -> void {
    // NOTE: vestigial alias — `times[i]` parses and typechecks in both
    // copies today; the binding stays only because the compiled compiler
    // is byte-gated against refs/ycc.ref.
    all.foreach((e) => {
        eputs("  " + padr(e.name, 12) + padl(fmt_ms(e.us), 12) + " ms" + padl(fmt_kb(e.heap), 12) + " KB\n");
    });
};

def print_counter(name: str, v: long) -> void {
    eputs("  " + padr(name, 12) + padl(tostring(v), 12) + "\n");
};

// ── main ─────────────────────────────────────────────────────────────────

def print_native_errors(all: [Diag], origin: Origin, bare: bool) -> void {
    // NOTE: vestigial alias (see print_phase_rows) — `errors[i]` works.
    // Positions are lines of the spliced program (std chunks and imported
    // modules included); the origin map turns each back into the file it
    // came from: `line:col` in the program's own file (unless not `bare`:
    // `ycc build` names every file), `path:line:col` in any other.
    // One error per position: a malformed token can trip two checks (the
    // construct it broke, then the statement it ended), and the second
    // message only repeats the first. The positions go in a name index, not
    // an array: a linear scan of what has been printed makes printing n
    // errors O(n^2), and a file with a mistake on every line is exactly when
    // the messages matter most (measured: 2000 errors 10 ms, 4000 20, 8000
    // 80, 16000 250 -- a name index makes each one a hash probe).
    let seen = parser.nameix_new(64);
    all.foreach((e) => {
        let at = nativelib.origin_at(origin, e.line, bare) + ":" + tostring(e.col);
        if (parser.nameix_get(seen, at) < 0) {
            parser.nameix_put(seen, at, 1);
            puts(at + ": error: " + e.msg + "\n");
        }
    });
};

// What lint.y found in a unit that compiled, as `at: warning: msg` on
// stderr (a -S listing on stdout stays clean), each position as
// print_native_errors gives it. lint_unit sorted them and dropped repeats.
// The warnings as the one string print_native_warnings used to write in
// pieces: a dispatched child carries it in a file and the parent prints it
// where the serial loop would have, so the bytes on stderr do not depend on
// which child finished first.
def warning_text(warnings: [Diag], origin: Origin, bare: bool) -> str {
    let out = "";
    warnings.foreach((w) => {
        out = out + nativelib.origin_at(origin, w.line, bare) + ":" + tostring(w.col) + ": warning: " + w.msg + "\n";
    });
    out
};

def print_native_warnings(warnings: [Diag], origin: Origin, bare: bool) -> void {
    eputs(warning_text(warnings, origin, bare));
};

// ── ycc build / ycc vendor (see pkg.y) ───────────────────────────────────

def build_args(cl: [str]) -> { dir: str, debug: bool, nowarn: bool, wlevel: long, allow_exec: bool, std_src: bool, one: str } {
    let dir = "";
    let debug = false;
    let nowarn = false;
    let wlevel = 0;
    let allow_exec = true;
    let std_src = false;
    let one = "";
    for i in 2..len(cl) {
        let a = cl[i];
        if (a == "-g") {
            debug = true;
        } else if (a == "-w") {
            nowarn = true;
        } else if (a == "-W") {
            wlevel = wlevel_arg(cl, i, len(cl));
            i++;
        } else if (a == "--no-exec") {
            allow_exec = false;
        } else if (a == "--std-src") {
            std_src = true;
        } else if (a == "--one") {
            // build_dispatch's child: one package, then exit
            if (i + 1 >= len(cl)) {
                puts("ycc: --one needs a package name\n");
                exit(1);
            };
            one = cl[i + 1];
            i++;
        } else if (a[0:1] == "-") {
            puts("ycc: unknown flag '" + a + "' (see ycc -h)\n");
            exit(1);
        } else if (len(dir) > 0) {
            puts("error: ycc " + cl[1] + " takes one project directory\n");
            exit(1);
        } else {
            dir = a;
        };
    };
    if (len(dir) == 0) { dir = "."; }
    { dir: dir, debug: debug, nowarn: nowarn, wlevel: wlevel, allow_exec: allow_exec, std_src: std_src, one: one }
};

// One unit's text, resolved: its bare imports may name the packages
// `pkgs` and look in the source roots `roots` (native_resolve_pk).
def build_resolve(path: str, allow_exec: bool, pkgs: [str], roots: [str]) -> Resolved {
    let src = fs.read_file(path);
    if (src == none) {
        puts("error: cannot read file '" + path + "'\n");
        exit(1);
    }
    // A meta pass per unit: a block in package A cannot see package B, so each
    // unit gets its own generator (ideas/meta.md, "The pass").
    meta.meta_begin();
    nativelib.native_resolve_pk(unwrap(src), pkg.pk_dir_of(path), allow_exec, path, pkgs, roots)
};

// The std units among `names`, in link order.
def std_order(names: [str]) -> [str] {
    let all = nativelib.std_unit_names();
    let out: [str] = [];
    all.foreach((e) => {
        let nm: str = e;
        if (pkg.pk_has(names, nm)) { out += nm; }
    });
    out
};

def longs_text(xs: [long]) -> str {
    let out: [str] = [];
    xs.foreach((e) => {
        out += tostring(e);
    });
    join(out, ",")
};

// What a package's object is valid for: this compiler, the package's
// place among the units (its labels count from `base`), its resolved
// text and where each line came from, and the interfaces of the
// packages it imports (among `units`, unit_iface).
// The cache key for one unit's object in build/obj. It hashes the resolved
// text, the compiler id and the target: WITHOUT the target, `ycc build` reuses
// an object compiled for the other target, and the "rebuild" that should have
// happened silently does not -- a PE's cache entry served to an ELF build (or
// the reverse), which no test catches because the bytes are only compared
// within a run. `cid` is the compiler id, which a rebless changes, so this is
// the same kind of input: anything that changes the OUTPUT belongs in the key.
def build_key(cid: str, name: str, base: long, allow_exec: bool, nr: Resolved, units: [Unit]) -> str {
    let h = pkg.pk_hash_new();
    pkg.pk_hash_str(h, cid);
    pkg.pk_hash_str(h, name);
    pkg.pk_hash_str(h, tostring(base));
    pkg.pk_hash_str(h, wintgt.target_os());
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
    units.foreach((u) => {
        if (pkg.pk_has(ps, u.name)) { pkg.pk_hash_str(h, nativelib.unit_iface(u)); }
    });
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
        k++;
    };
    k = len(pkgs) - 1;
    while (k >= 0) {
        if (pkg.pk_has(want, pkgs[k].name)) {
            reach[k] = true;
            want += nrs[k].pkgs;
        }
        k--;
    };
    reach
};

// The decimal level after `-W`, or the flag's own complaint. `i` points at
// "-W". Only 0, 1 and 2 exist, so anything else is rejected -- and the scan
// saturates, because a long enough digit run wraps the accumulator and
// "-W 99999999999999999999" would come back as an accepted level.
def wlevel_arg(argv: [str], i: long, n: long) -> long {
    if (i + 1 >= n) {
        puts("ycc: -W needs a warning level (0, 1 or 2)\n");
        exit(1);
        0
    } else {
        let a = argv[i + 1];
        let ok = len(a) > 0 && a[0:1] != "-";
        let v = 0;
        let d = 0;
        while (ok && d < len(a)) {
            let c = a[d];
            ok = c >= '0' && c <= '9';
            if (ok && v <= 2) { v = v * 10 + (c - '0'); 0; };
            d++;
        };
        if (!ok || v > 2) {
            puts("ycc: -W needs a warning level (0, 1 or 2), got '" + a + "'\n");
            exit(1);
            0
        } else {
            v
        }
    }
};

// ── `ycc build`: compiling a ready level of packages in parallel ─────────
//
// pk_load hands the packages back in topological order, so every dependency
// has a lower index than its importer. The loop below walks them in that
// order; a *level* is a run of packages that depend only on what is already
// compiled (all of their dependencies sit before the run), and a level's
// packages are independent of each other -- so it is where the time is.
//
// A level compiles out of process: one `ycc build --one NAME` child per
// package, through a single shell (exec() takes one command string, and `&`
// plus `wait` is all the parallelism that needs). Each child writes the
// object the loop would have written, build/obj/NAME.yo, keyed by build_key
// (this compiler, the package's place among the units, its text, and the
// *interfaces* of the packages it imports), and the loop then reads it back
// exactly as on a warm build. Nothing here is needed for a correct build: a
// child that fails leaves no object, and the loop compiles that package
// itself and reports the error as if nothing had been dispatched -- the
// diagnostics and the bytes are the same either way. Warnings ride along in a
// sidecar named for the object they belong to (the key), so they print in
// package order and a sidecar left by another key is never read. What does
// change is the order of the *lines*: a level's "compiling" lines all come
// from the dispatch, before the loop prints the warnings it collected.
//
// Deliberately not spawn/join. A thread shares the address space (CLONE_VM)
// and the compiler keeps 51 module-level lets -- the label table every
// body's label ids index, rename.y's and types.y's name caches, native.y's
// dbg_file and pkg_ns -- so two packages compiling at once would race on all
// of them, and every later allocation would take y_alloc's %fs detour (+14
// instructions each, measured: +2.7% of a package's compile, since a 3.5k
// line unit allocates 615,000 times). Two processes race on nothing, and
// each one's arena holds one package instead of the whole project: 799 MB
// for eight 3.5k-line packages compiled in one process, 106 MB for the same
// build with children.
//
// The waves are capped so peak memory stays bounded: a package compile is
// ~30 ms, so even a wide graph does not want twenty of them at once. And
// nothing is dispatched for a level of one (a chain, or a project with a
// single package), for a package whose object is already there (a rebuild
// that compiles nothing spawns nothing), or under --std-src (a child would
// compile the std units from source before its own package).
let BUILD_JOBS = 4;
// `s` quoted for sh (pkg.y's pk_q, which is not exported, does the same).
def build_q(s: str) -> str {
    "'" + join(split(s, "'"), "'\\''") + "'"
};

// Where a dispatched child's warnings wait: one file per object, so a
// leftover from another key is never read.
def warn_path(odir: str, name: str, key: str) -> str {
    odir + "/" + name + "." + key + ".warn"
};

// This compiler's own path, which is what the children run: /proc/self/exe is
// absolute and resolved, where argv[0] need not be. readlink(2), not read:
// opening that path gives the binary itself, a megabyte of it.
def self_exe() -> str {
    let buf: [byte; 4096] = [0; 4096];
    let n = syscall(89, "/proc/self/exe", &buf[0], 4096);
    if (n <= 0) { "" } else { from_bytes(buf[0:n]) }
};

// The flags a child needs to compile its package exactly as this run would.
def build_child_flags(debug: bool, nowarn: bool, wlevel: long, allow_exec: bool) -> str {
    let out = "";
    if (debug) { out += " -g"; };
    if (nowarn) { out += " -w"; };
    if (wlevel > 0) { out = out + " -W " + tostring(wlevel); };
    if (!allow_exec) { out += " --no-exec"; };
    out
};

// Where `name` sits in the package order, or -1.
def pkg_index(pkgs: [PkNode], name: str) -> long {
    let at = -1;
    pkgs.foreach((e, i) => {
        if (e.name == name) { at = i; };
    });
    at
};

// `ycc build --one NAME`: compile exactly this one package of DIR and write
// its object. Only its dependencies' objects are read -- the loop hands out a
// package whose dependencies are all done, and this same compiler wrote them,
// so those units are the ones the loop would have compiled. The unit order is
// the topological one, so each dependency's own key hashes the same
// interfaces the loop gave it.
def build_one(dir: str, one: str, debug: bool, nowarn: bool, wlevel: long, allow_exec: bool, std_src: bool) -> void {
    let pkgs = pkg.pk_load(dir).pkgs;
    let odir = pkg.pk_join(pkg.pk_join(dir, "build"), "obj");
    let target = pkg_index(pkgs, one);
    if (target < 0) {
        puts("error: no package '" + one + "' in " + dir + "\n");
        exit(1);
    };
    let cid = pkg.pk_self_id();
    let pack = "";
    if (!std_src) { pack = self_pack(); };
    let want: [str] = [];
    want += pkgs[target].deps;
    let units: [Unit] = [];
    for k in 0..target {
        let p = pkgs[k];
        if (pkg.pk_has(want, p.name)) {
            let key = build_key(cid, p.name, (5000000000 + k * 1000000000), allow_exec, (build_resolve(p.lib, allow_exec, p.deps, p.roots)), units);
            let ot = fs.read_file(odir + "/" + p.name + ".yo");
            if (ot == none) {
                puts("error: package '" + p.name + "' was not compiled first\n");
                exit(1);
            };
            let uo = nativelib.unit_unobj(unwrap(ot), key);
            if (!uo.ok) {
                puts("error: package '" + p.name + "' has no current object\n");
                exit(1);
            };
            units += uo.unit;
            want += p.deps;
        };
    };
    let p = pkgs[target];
    let nr = build_resolve(p.lib, allow_exec, p.deps, p.roots);
    let base = 5000000000 + target * 1000000000;
    let key = build_key(cid, p.name, base, allow_exec, nr, units);
    let r = nativelib.compile_package(parser.parse_program(lexer.tokenize(nr.src)), nr, p.name, base, wlevel, (nativelib.std_units(std_order(nr.std), pack)), units);
    if (!r.ok) {
        print_native_errors(r.errors, nr.origin, false);
        exit(1);
    };
    if (!fs.write_file((warn_path(odir, p.name, key)), warning_text(r.warnings, nr.origin, false))) { exit(1); };
    let op = odir + "/" + p.name + ".yo";
    if (!fs.write_file(op, nativelib.unit_obj(r.unit, key))) {
        puts("error: writing '" + op + "' failed\n");
        exit(1);
    };
};

// Hand the level pkgs[lo..hi) out to child compilers, in waves of at most
// BUILD_JOBS; how many went out comes back (the callers here want the objects
// more than the count).
// A package whose object file is already there is left to the loop, so a
// rebuild that compiles nothing spawns nothing either.
def build_dispatch_level(dir: str, pkgs: [PkNode], odir: str, lo: long, hi: long, debug: bool, nowarn: bool, wlevel: long, allow_exec: bool, std_src: bool) -> void {
    let n = 0;
    // --std-src has no pack, so a child would compile the std units from
    // source before its own package: far more than the package costs.
    if (!std_src && hi - lo > 1) {
        let exe = self_exe();
        if (len(exe) > 0) {
            let flags = build_child_flags(debug, nowarn, wlevel, allow_exec);
            let dirarg = "";
            if (dir != ".") { dirarg = " " + build_q(dir); };
            let wave: [str] = [];
            for k in lo..hi {
                let name = pkgs[k].name;
                if (!fs.exists(odir + "/" + name + ".yo")) { wave += name; };
            };
            let w = 0;
            while (w < len(wave)) {
                let take = len(wave) - w;
                if (take > BUILD_JOBS) { take = BUILD_JOBS; };
                let cmd = "";
                for c in 0..take {
                    let nm = wave[w + c];
                    eputs("compiling " + nm + "\n");
                    // quote the two paths, not the whole command: the flags and
                    // the directory are already quoted
                    cmd = cmd + build_q(exe) + " build --one " + build_q(nm) + flags + dirarg + " & ";
                    n++;
                };
                exec(cmd + "wait");
                w += take;
            };
        };
    };
    n
};
// `ycc build`: every package the project depends on (and its own lib),
// each from its object in DIR/build/obj when that is current, else
// compiled and its object written; then each [bin], linked with the
// packages it reaches, to DIR/build/NAME. A unit's warnings show when it
// is compiled (unless `nowarn`), not when its object is reused.
def build_project(dir: str, debug: bool, nowarn: bool, wlevel: long, allow_exec: bool, std_src: bool) -> void {
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
        k++;
    };
    let bdeps: [str] = [];
    bdeps += g.deps;
    if (len(g.lib) > 0) { bdeps += g.name; }
    let b = 0;
    while (b < len(bins)) {
        nrs += build_resolve(bins[b].path, allow_exec, bdeps, g.roots);
        b++;
    };
    let needs: [str] = [];
    k = 0;
    while (k < len(nrs)) {
        needs += nrs[k].std;
        k++;
    };
    let pack = "";
    if (!std_src) { pack = self_pack(); }
    let su = nativelib.std_units(std_order(needs), pack);
    let cid = pkg.pk_self_id();
    let units: [Unit] = [];
    k = 0;
    while (k < len(pkgs)) {
        // A level: the longest run of packages from k that depend only on what
        // is already compiled (every dependency has the lower index). A level
        // wider than one package goes out to child compilers, and the loop
        // below then reads their objects (build_dispatch_level).
        let hi = k;
        let scanning = true;
        while (scanning && hi < len(pkgs)) {
            let deps = pkgs[hi].deps;
            let d = 0;
            let ready = true;
            while (d < len(deps)) {
                if (pkg_index(pkgs, deps[d]) >= k) { ready = false; };
                d++;
            };
            if (ready) { hi = hi + 1; } else { scanning = false; };
        };
        build_dispatch_level(dir, pkgs, odir, k, hi, debug, nowarn, wlevel, allow_exec, std_src);
        while (k < hi) {
            let p = pkgs[k];
            let nr = nrs[k];
            let base = 5000000000 + k * 1000000000;
            let key = build_key(cid, p.name, base, allow_exec, nr, units);
            let opath = odir + "/" + p.name + ".yo";
            let hit = false;
            let ot = fs.read_file(opath);
            if (ot != none) {
                let uo = nativelib.unit_unobj(unwrap(ot), key);
                if (uo.ok) { units += uo.unit; hit = true; };
            };
            if (hit) {
                // a dispatched child's warnings, in package order like the rest
                let wp = warn_path(odir, p.name, key);
                let wt = fs.read_file(wp);
                if (wt != none) {
                    if (!nowarn) { eputs(unwrap(wt)); };
                    fs.remove_file(wp);
                };
            } else {
                eputs("compiling " + p.name + "\n");
                let r = nativelib.compile_package(parser.parse_program(lexer.tokenize(nr.src)), nr, p.name, base, wlevel, su, units);
                if (!r.ok) {
                    print_native_errors(r.errors, nr.origin, false);
                    exit(1);
                };
                if (!nowarn) {
                    print_native_warnings(r.warnings, nr.origin, false);
                };
                if (!fs.write_file(opath, nativelib.unit_obj(r.unit, key))) {
                    puts("error: writing '" + opath + "' failed\n");
                    exit(1);
                };
                units += r.unit;
            };
            k++;
        };
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
                lneeds += nrs[k].std;
            }
            k++;
        };
        let lstd = std_order(lneeds);
        let bstd: [Unit] = [];
        k = 0;
        while (k < len(su)) {
            let su1 = su[k];
            if (pkg.pk_has(lstd, su1.name)) { bstd += su1; }
            k++;
        };
        let r = nativelib.emit_program(parser.parse_program(lexer.tokenize(nr.src)), nr, debug, wlevel, bstd, linked);
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
        b++;
    };
};

// `ycc -E`: the resolved text, each line tagged with the file and line it came
// from. The tag is a trailing comment on the FIRST line of each run of lines
// from one file, so line numbers survive the round trip and the markers do not
// move anything: comments never reach the lexer, so compiling a dump gives the
// same bytes as compiling the file it came from.
def dump_source(src: str, origin: Origin) -> void {
    let lines = split(src, "\n");
    let prev = "\x01none";
    lines.foreach((l, i) => {
        let at = nativelib.origin_at(origin, i + 1, false);
        if (at == prev) {
            puts(l + "\n");
        } else {
            puts(l + "\t// " + at + "\n");
            prev = at;
        };
    });
};

def main(cmdline: [str]) -> long {
    // tags.y writes its tag numbers out twice (K for the code, KTAGS for
    // diagnostics); ~4k instructions to prove the two still agree, once.
    if (!tags.tags_agree()) {
        puts("ycc: internal error: the tag tables disagree (src/y/tags.y)\n");
        exit(1);
    }
    // ... and the nesting limit, which the two copies must also hold the same.
    if (!tags.max_nest_agree()) {
        puts("ycc: internal error: the nesting limit disagrees (src/y/tags.y)\n");
        exit(1);
    }
    if (len(cmdline) > 1 && (cmdline[1] == "build" || cmdline[1] == "vendor")) {
        let ba = build_args(cmdline);
        if (cmdline[1] == "build" && len(ba.one) == 0) {
            build_project(ba.dir, ba.debug, ba.nowarn, ba.wlevel, ba.allow_exec, ba.std_src);
        } else if (cmdline[1] == "build") {
            build_one(ba.dir, ba.one, ba.debug, ba.nowarn, ba.wlevel, ba.allow_exec, ba.std_src);
        } else {
            pkg.pk_vendor(ba.dir);
        };
        exit(0);
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
        if let some(src) = fs.read_file(file) {

            // src is str? (read_file returns none on missing file); the
            // none case exited above, so unwrap here (loud on none).
            let src2 = src;
            // One meta pass per program: the pass is ON for the program's own
            // resolve and OFF for the generator's (meta_compile_gen), so
            // meta_begin here and nothing else -- resolve_unit's meta_prepare
            // is what runs the generator.
            meta.meta_begin();
            // get base dir from file path (use last slash, like C compiler's strrchr)
            let last_slash = last_index_of(file, "/");
            let base_dir = ".";
            if (last_slash >= 0) {
                base_dir = file[0:last_slash];
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
            if (pargs.dump) {
                dump_source(nrsrc, nrorigin);
                exit(0);
            };
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
            r.times.foreach((se) => {
                dt += se;
            });
            if (r.ok && !pargs.nowarn) {
                print_native_warnings(r.warnings, nrorigin, true);
            };
            // --fix: the linter named the shortenings; write each one's file
            // back with them applied, then stop (nothing downstream reads a
            // source file, and the caller wants the tree, not a binary).
            if (r.ok && pargs.fix) {
                let fixes = lint.lint_fixes_get();
                let fids = lint.lint_fix_ids(fixes, nrorigin.file);
                for fi in 0..len(fids) {
                    let fid = fids[fi];
                    if (fid >= 0 && fid < len(nrorigin.files)) {
                        let rd = fs.read_file(nrorigin.files[fid]);
                        if (rd != none) {
                            fs.write_file(nrorigin.files[fid], lint.lint_fix_text(fid, fixes, nrorigin.file, nrorigin.line, unwrap(rd)));
                        };
                    };
                };
                exit(0);
            };
            t0 = clock_us();
            h0 = heap_used();
            if (!r.ok) {
                print_native_errors(r.errors, nrorigin, true);
                exit(1);
                1
            } else if (pargs.asm_only) {
                let rasm = nativelib.link_text(r.asm);
                let wrote = true;
                if (len(out) == 0) {
                    puts(rasm);
                } else {
                    // Checked, like the executable path below: silently
                    // exiting 0 after a failed write hid bad -o paths.
                    wrote = fs.write_file(out, rasm);
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
                ab.times.foreach((ae) => {
                    dt += ae;
                });
                if (!ab.ok) {
                    puts("error: assemble: " + ab.error + "\n");
                    exit(1);
                    1
                } else {
                    if (pargs.run) {
                        let av: [str] = [file];
                        av += pargs.prog;
                        let rr = meta.run_image(ab.bytes, av, false);
                        if (!rr.ok) {
                            puts("error: " + rr.err + "\n");
                            exit(1);
                        } else {
                            if (rr.sig > 0) { exit(128 + rr.sig); } else { exit(rr.status); };
                        }
                    };
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

        } else {

            puts("error: cannot read file '" + file + "'\n");
            exit(1);
            1

        }
    }
};

// entry point — use real command-line arguments
let result = main(argv());
