// ycc — command-line driver for the native Y compiler.

import hostos from "./host_linux.y";
import tags from "./tags.y";
import wintgt from "./target.y";
import lexer from "./lexer.y";
import parser from "./parser.y";
import nasm from "./asm.y";
import nativelib from "./native.y";
import optim from "./optimize.y";
import obf from "./obfuscate.y";
import seal from "./seal.y";
import meta from "./meta.y";
import pkg from "./pkg.y";
import lint from "./lint.y";
import wasmlink from "./wasm_link.y";
import fs;

// ── argument parsing ─────────────────────────────────────────────────────

let obf_report_flag = false;
let obf_vm_flag = false;
let obf_key_file_path = "";
let obf_anti_debug_flag = false;
let obf_no_anti_debug_flag = false;
let obf_key_fd_flag = -1;
let obf_map_path = "";
let obf_layout_flag = false;
let obf_std_flag = false;
let obf_diversity_flag = false;

// --target=web: the main stack's size (D6) and --web-checked (S8).
let web_stack_bytes = 8388608;
let web_checked_flag = false;
// --web-forms: a test hook that lowers one instance of every IR form.
let web_forms_flag = false;
// --web=KEY=VALUE, accepted by a single-file compile (S13).  The manifest keys
// are read by the page writer; the writer itself lives in W5.
let web_kv_list: [str] = [];
// The [web] config of the build being compiled: the manifest's, then --web.
// build_key hashes what changes the bundle; the page writer reads the rest.
let web_cfg: [str] = [];

def valid_obf_mode(m: str) -> bool {
    m in ["off", "full"]
};

def pick_obf_mode(m: str) -> void {
    if (!valid_obf_mode(m)) {
        puts("ycc: --obfuscate wants off or full, got '" + m + "'\n");
        exit(1);
    };
    if (obf.mode() != "off" && obf.mode() != m) {
        puts("ycc: conflicting --obfuscate modes\n");
        exit(1);
    };
    obf.set_mode(m)
};

def pick_optimize(mode: str, selected: str) -> str {
    if (mode != "size" && mode != "speed") {
        puts("ycc: --optimize wants speed or size, got '" + mode + "'\n");
        exit(1);
    };
    if (selected != "" && selected != mode) {
        puts("ycc: size and speed optimizations are mutually exclusive\n");
        exit(1);
    };
    optim.set_goal(mode);
    mode
};

def pack_method_ok(m: str) -> bool {
    m in ["dynamic", "store", "fixed", "lz"]
};

// --emit: an intermediate listing. The executable is the default, so `exe`
// is not a value; the web page kinds are --web-page.
def pick_emit(mode: str, emit: str) -> str {
    if (!(mode in ["asm", "source", "wat"])) {
        if (mode == "page" || mode == "html") {
            puts("ycc: --emit=" + mode + " is now --web-page" + (if (mode == "html") { "=html" } else { "" }) + "\n");
        } else if (mode == "exe") {
            puts("ycc: --emit wants asm, source or wat (the executable is the default)\n");
        } else {
            puts("ycc: --emit wants asm, source or wat, got '" + mode + "'\n");
        };
        exit(1);
    };
    if (emit != "" && emit != mode) {
        puts("ycc: choose one output kind: asm, source or wat\n");
        exit(1);
    };
    mode
};

def pick_web_page(mode: str, emit: str) -> str {
    if (!(mode in ["site", "html"])) {
        puts("ycc: --web-page wants site or html, got '" + mode + "'\n");
        exit(1);
    };
    let kind = if (mode == "html") { "html" } else { "page" };
    if (emit != "" && emit != kind) {
        puts("ycc: choose one output kind: asm, source, wat or --web-page\n");
        exit(1);
    };
    kind
};

def usage() -> void {
    puts("Usage: ycc [OPTIONS] FILE\n");
    puts("       ycc run [OPTIONS] FILE [-- ARG...]\n");
    puts("       ycc build [OPTIONS] [DIR]\n");
    puts("       ycc vendor [DIR]\n");
    puts("\n");
    puts("  -o, --output=PATH        write the output to PATH (default: a.out; a.wasm on web)\n");
    puts("  -O, --optimize=speed|size  optimize for speed (default) or size\n");
    puts("  -g, --debug              include symbols, DWARF and section headers\n");
    puts("  -p, --pack[=METHOD]      self-decompressing Linux ELF: dynamic (default),\n");
    puts("                           store, fixed or lz\n");
    puts("      --target=OS          linux (default), win, kernel or web\n");
    puts("      --arch=ARCH          x64 or aarch64 (default: the host's; linux only)\n");
    puts("      --obfuscate[=MODE]   off, or full (bare = full): sealed image, VM,\n");
    puts("                           anti-debug; Linux ELF and Windows PE\n");
    puts("      --emit=KIND          asm, source or wat (default: the executable)\n");
    puts("      --web-page[=MODE]    web output: site (default) or html\n");
    puts("      --warnings=LEVEL     none, default, extra, all or fix\n");
    puts("      --gc=MODE            never (default, checked), auto, always or stress\n");
    puts("      --regions=MODE       auto (default) or off\n");
    puts("      --exec=on|off        allow exec() (default: on)\n");
    puts("      --std=pack|source    bundled std units (default) or compile sources\n");
    puts("      --subsystem=NAME     console (default) or gui (Windows)\n");
    puts("  -D, --define NAME[=VALUE]  define a build input a meta block reads\n");
    puts("  -U, --undef NAME         remove a define, including one from y.toml\n");
    puts("      --meta-arg=VALUE     free-form argument a meta block reads (YCC.args)\n");
    puts("      --strict-heap        report each repeated allocation nothing frees\n");
    puts("      --time               print phase timings and heap use to stderr\n");
    puts("  -h, --help               show help\n");
    puts("\n");
    puts("Web page keys (--web=KEY=VALUE, repeatable):\n");
    puts("  title id start canvas zoom smooth console persist files args url_args\n");
    puts("  stack pause_hidden single template\n");
    puts("  --web-checked traps every out-of-range web address (a debugging switch).\n");
    puts("\n");
    puts("Obfuscation tuning (tests and bring-up):\n");
    puts("  --obfuscate-key=PATH    16-byte external key file (implies full)\n");
    puts("  --obfuscate-key-fd=N    read the key from descriptor N at runtime\n");
    puts("  --obfuscate-seed=N      reproducible seed; --obfuscate-report: counts\n");
    puts("  --obfuscate-map=PATH    write a label/address map outside the binary\n");
    puts("  --obfuscate-layout=MODE source or shuffle (default shuffle)\n");
    puts("  --obfuscate-std=MODE    off, auto or all (default all)\n");
    puts("  --obfuscate-diversity=MODE  standard or high (default high)\n");
    puts("  --obfuscate-vm=MODE     off, auto, all or bytecode (default bytecode)\n");
    puts("  --obfuscate-no-anti-debug  keep the dumpable/tracer checks off\n");
    puts("\n");
    puts("Value options accept --name=value or --name value.\n");
    puts("Compile, run and build share code-generation options; build writes to DIR/build.\n");
    puts("On --target=web, build writes DIR/build/web/NAME/ (the site),\n");
    puts("DIR/build/web/bin/NAME (a Node launcher) and, with [web] single = \"true\",\n");
    puts("DIR/build/web/NAME.html.\n");
    puts("Assembly and the wasm listing default to stdout; source output stops after\n");
    puts("meta expansion. --web-page writes a site directory, or one HTML file.\n");
    exit(0);
};

def parse_seed(v: str) -> long {
    let r = tolong(v);
    if (r == none) {
        puts("ycc: --obfuscate-seed wants a decimal number, got '" + v + "'\n");
        exit(1);
    };
    r!
};

// One -D or -U, in command-line order (S15 precedence: manifest, then these).
type Define = { name: str, value: str, on: bool };
// The final defines, sorted by name, with values aligned to it.
type Defs = { names: [str], values: [str] };
type DefinePair = { name: str, value: str };

type CliArgs = { out: str, files: [str], asm_only: bool, timing: bool, allow_exec: bool, debug: bool, nowarn: bool, wlevel: long, std_src: bool, std_pack: str, run: bool, dump: bool, prog: [str], fix: bool, pack: bool, pack_method: str, one: str, defines: [Define], margs: [str], emit: str };

// One parser for compile, run and build. Value options accept =VALUE or VALUE.
def cli_value_option(a: str) -> bool {
    a in ["--output", "--optimize", "--emit", "--warnings", "--target", "--arch",
        "--subsystem", "--gc", "--regions", "--exec", "--std", "--one",
        "--define", "--undef", "--std-pack",
        "--obfuscate-seed", "--obfuscate-vm", "--obfuscate-key-file",
        "--obfuscate-key", "--obfuscate-key-fd", "--web"]
};

// A -D name: [A-Za-z_][A-Za-z0-9_]*. The name is only a key in YCC.defines,
// so a keyword is a legal name.
def define_name_ok(s: str) -> bool {
    if (len(s) == 0) { return false; };
    let c = s[0];
    let ok = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95;
    let i = 1;
    while (ok && i < len(s)) {
        c = s[i];
        ok = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95;
        i++;
    };
    ok
};

// NAME or NAME=VALUE for -D (NAME alone is "1"); NAME for -U. `flag` is what
// the diagnostic calls the option, so the -D message is the plan's.
def parse_define(v: str, on: bool, flag: str) -> Define {
    let eq = index_of(v, "=");
    let nm = v;
    let val = "1";
    if (on) {
        if (eq >= 0) { nm = v[:eq]; val = v[eq + 1:]; };
    } else if (eq >= 0) {
        puts("ycc: " + flag + " wants NAME, got '" + v + "'\n");
        exit(1);
    };
    if (!define_name_ok(nm)) {
        if (on) { puts("ycc: " + flag + " wants NAME or NAME=VALUE, got '" + v + "'\n"); }
        else { puts("ycc: " + flag + " wants NAME, got '" + v + "'\n"); };
        exit(1);
    };
    { name: nm, value: val, on: on }
};

def parse_cli_args(argv: [str], project: bool = false) -> CliArgs {
    let selected_goal = "";
    let one = "";
    let emit = "";
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
    let pack = false;
    let pack_method = "dynamic";
    let defines: [Define] = [];
    let margs: [str] = [];
    let target_set = false;
    let arch_set = false;
    let i = 1;  // skip argv[0]
    let n = len(argv);
    while (i < n) {
        let a = argv[i];
        if (cli_value_option(a)) {
            if (i + 1 >= n || argv[i + 1].starts_with("-")) {
                if (a == "--target") { puts("ycc: --target needs an OS (linux, win, kernel, web)\n"); }
                else if (a == "--arch") { puts("ycc: --arch needs an arch (x64, aarch64)\n"); }
                else if (a == "--one") { puts("ycc: --one needs a package name\n"); }
                else if (a == "--std-pack") { puts("ycc: --std-pack needs a path\n"); }
                else { puts("ycc: " + a + " needs a value\n"); };
                exit(1);
            };
            i++;
            a += "=" + argv[i];
        };
        if (a.starts_with("--output=")) {
            out = a[9:];
            if (out == "") { puts("ycc: --output needs a path\n"); exit(1); };
        } else if (a.starts_with("--optimize=")) {
            selected_goal = pick_optimize(a[11:], selected_goal);
        } else if (a == "--obfuscate") {
            pick_obf_mode("full");
        } else if (a.starts_with("--obfuscate=")) {
            pick_obf_mode(a[12:]);
        } else if (a.starts_with("--obfuscate-seed=")) {
            obf.set_seed(parse_seed(a[17:]));
        } else if (a.starts_with("--obfuscate-vm=")) {
            let vm = a[15:];
            if (!(vm in ["off", "auto", "all", "bytecode"])) {
                puts("ycc: --obfuscate-vm wants off, auto, all or bytecode, got '" + vm + "'\n");
                exit(1);
            };
            obf.set_vm_mode(vm);
            obf_vm_flag = true;
        } else if (a == "--obfuscate-report") {
            obf_report_flag = true;
        } else if (a == "--obfuscate-anti-debug") {
            obf_anti_debug_flag = true;
        } else if (a == "--obfuscate-no-anti-debug") {
            obf_no_anti_debug_flag = true;
        } else if (a.starts_with("--obfuscate-key-file=")) {
            obf_key_file_path = a[21:];
            if (len(obf_key_file_path) == 0) {
                puts("ycc: --obfuscate-key-file needs a path\n");
                exit(1);
            };
        } else if (a.starts_with("--obfuscate-key-fd=")) {
            let fd = tolong(a[19:]);
            if (fd == none || fd! < 0) {
                puts("ycc: --obfuscate-key-fd wants a non-negative descriptor\n");
                exit(1);
            };
            obf_key_fd_flag = fd!;
        } else if (a.starts_with("--obfuscate-key=")) {
            obf_key_file_path = a[16:];
            if (len(obf_key_file_path) == 0) {
                puts("ycc: --obfuscate-key needs a path\n");
                exit(1);
            };
            if (obf.mode() == "off") { pick_obf_mode("full"); };
        } else if (a.starts_with("--obfuscate-layout=")) {
            let lay = a[19:];
            if (!(lay in ["source", "shuffle"])) {
                puts("ycc: --obfuscate-layout wants source or shuffle, got '" + lay + "'\n");
                exit(1);
            };
            obf.set_layout(lay);
            obf_layout_flag = true;
        } else if (a.starts_with("--obfuscate-std=")) {
            let sm = a[16:];
            if (!(sm in ["off", "auto", "all"])) {
                puts("ycc: --obfuscate-std wants off, auto or all, got '" + sm + "'\n");
                exit(1);
            };
            obf.set_std_mode(sm);
            obf_std_flag = true;
        } else if (a.starts_with("--obfuscate-diversity=")) {
            let dv = a[22:];
            if (!(dv in ["standard", "high"])) {
                puts("ycc: --obfuscate-diversity wants standard or high, got '" + dv + "'\n");
                exit(1);
            };
            obf.set_diversity(dv);
            obf_diversity_flag = true;
        } else if (a.starts_with("--obfuscate-map=")) {
            obf_map_path = a[16:];
            if (len(obf_map_path) == 0) {
                puts("ycc: --obfuscate-map needs a path\n");
                exit(1);
            };
        } else if (a.starts_with("--emit=")) {
            emit = pick_emit(a[7:], emit);
        } else if (a == "--web-page") {
            emit = pick_web_page("site", emit);
        } else if (a.starts_with("--web-page=")) {
            emit = pick_web_page(a[11:], emit);
        } else if (a.starts_with("--warnings=")) {
            let mode = a[11:];
            if (mode == "fix") {
                fix = true;
                nowarn = false;
                wlevel = 2;
            } else {
                fix = false;
                nowarn = mode == "none";
                if (mode == "none" || mode == "default") { wlevel = 0; }
                else if (mode == "extra") { wlevel = 1; }
                else if (mode == "all") { wlevel = 2; }
                else { puts("ycc: --warnings wants none, default, extra, all or fix, got '" + mode + "'\n"); exit(1); };
            };
        } else if (a.starts_with("--exec=")) {
            let mode = a[7:];
            if (mode != "on" && mode != "off") { puts("ycc: --exec wants on or off, got '" + mode + "'\n"); exit(1); };
            allow_exec = mode == "on";
        } else if (a.starts_with("--regions=")) {
            let mode = a[10:];
            if (mode != "auto" && mode != "off") { puts("ycc: --regions wants auto or off, got '" + mode + "'\n"); exit(1); };
            nativelib.set_auto_regions(mode == "auto");
        } else if (a.starts_with("--std=")) {
            let mode = a[6:];
            if (mode != "pack" && mode != "source") { puts("ycc: --std wants pack or source, got '" + mode + "'\n"); exit(1); };
            std_src = mode == "source";
        } else if (a == "--pack") {
            pack = true;
        } else if (a.starts_with("--pack=")) {
            let m = a[7:];
            if (!pack_method_ok(m)) { puts("ycc: --pack wants dynamic, store, fixed or lz, got '" + m + "'\n"); exit(1); };
            pack = true;
            pack_method = m;
        } else if (a == "-o") {
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
        } else if (a.starts_with("-o=")) {
            out = a[3:];
            if (len(out) == 0) { puts("ycc: -o needs a path, got ''\n"); exit(1); };
        } else if (a.starts_with("-o") && len(a) > 2) {
            out = a[2:];
        } else if (a == "-O") {
            // Bare -O means speed, like the default; a following speed/size is
            // the goal, anything else is the next argument.
            if (i + 1 < n && (argv[i + 1] == "speed" || argv[i + 1] == "size")) {
                i++;
                selected_goal = pick_optimize(argv[i], selected_goal);
            } else {
                selected_goal = pick_optimize("speed", selected_goal);
            };
        } else if (a.starts_with("-O=")) {
            selected_goal = pick_optimize(a[3:], selected_goal);
        } else if (a.starts_with("-O") && len(a) > 2) {
            selected_goal = pick_optimize(a[2:], selected_goal);
        } else if (a == "-p") {
            pack = true;
        } else if (a.starts_with("-p=")) {
            let m = a[3:];
            if (!pack_method_ok(m)) { puts("ycc: --pack wants dynamic, store, fixed or lz, got '" + m + "'\n"); exit(1); };
            pack = true;
            pack_method = m;
        } else if (a.starts_with("-p") && len(a) > 2) {
            let m = a[2:];
            if (!pack_method_ok(m)) { puts("ycc: --pack wants dynamic, store, fixed or lz, got '" + m + "'\n"); exit(1); };
            pack = true;
            pack_method = m;
        } else if (a[0:5] == "--gc=") {
            // Whether the collector is linked: auto or always link it, never
            // (the default, checked) does not, and stress runs a cycle at every
            // allocating slow path.
            let m: str = a[5:];
            if (m == "stress") {
                nativelib.set_gc_stress(true);
                nativelib.set_gc_mode(2);
            } else if (m == "auto" || m == "always" || m == "never") {
                nativelib.set_gc_stress(false);
                if (m == "auto") { nativelib.set_gc_mode(0) }
                else if (m == "always") { nativelib.set_gc_mode(1) }
                else { nativelib.set_gc_mode(2) };
            } else {
                puts("ycc: --gc wants never, auto, always or stress, got '" + m + "'\n");
                exit(1);
            };
        } else if (a[0:9] == "--target=") {
            let name = a[9:];
            if (target_set && res_target != name) {
                puts("ycc: conflicting --target values (" + res_target + ", " + name + ")\n");
                exit(1);
            };
            parse_target(name);
            target_set = true;
        } else if (a[0:7] == "--arch=") {
            let ar = a[7:];
            if (arch_set && res_arch != ar) {
                puts("ycc: conflicting --arch values (" + res_arch + ", " + ar + ")\n");
                exit(1);
            };
            parse_arch(ar);
            arch_set = true;
        } else if (a == "--web-checked") {
            web_checked_flag = true;
        } else if (a == "--web-forms") {
            web_forms_flag = true;
        } else if (a[0:6] == "--web=") {
            let wkv = a[6:];
            let eq = index_of(wkv, "=");
            if (eq < 1) {
                puts("ycc: --web wants KEY=VALUE, got '" + wkv + "'\n");
                exit(1);
            };
            // S13: one rule for the manifest and the command line.  env and
            // defines are inline tables, so they only exist in y.toml.
            let wkey = wkv[:eq];
            let wval = wkv[eq + 1:];
            let why = pkg.pk_web_problem(wkey, wval);
            if (why == "" && (wkey == "env" || wkey == "defines")) {
                why = "'" + wkey + "' is an inline table in y.toml";
            };
            if (why != "") {
                puts("ycc: --web: " + why + "\n");
                exit(1);
            };
            // the list outlives this compile's region (build_key reads it)
            heap { web_kv_list = pkg.pk_web_set(web_kv_list, wkey, wval); };
        } else if (a[0:12] == "--subsystem=") {
            parse_subsystem(a[12:]);
        } else if (a == "run" && !project) {
            run = true;
        } else if (a == "--time") {
            timing = true;
        } else if (a == "-g" || a == "--debug") {
            debug = true;
        } else if (a == "--strict-heap") {
            // Warn at each allocation the program repeats with nothing to free
            // it (lint.y lint_heap). A report: the bytes do not change.
            nativelib.set_strict_heap(true);
        } else if (a.starts_with("--std-pack=")) {
            std_pack = a[11:];
            if (len(std_pack) == 0) { puts("ycc: --std-pack needs a path\n"); exit(1); };
        } else if (a == "--help" || a == "-h") {
            usage();
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
        } else if (a == "-D" || a == "--define") {
            if (i + 1 >= n) {
                puts("ycc: " + a + " wants NAME or NAME=VALUE\n");
                exit(1);
            };
            i++;
            defines += parse_define(argv[i], true, "-D");
        } else if (a.starts_with("-D") && len(a) > 2) {
            defines += parse_define(a[2:], true, "-D");
        } else if (a.starts_with("--define=")) {
            defines += parse_define(a[9:], true, "-D");
        } else if (a == "-U" || a == "--undef") {
            if (i + 1 >= n) {
                puts("ycc: " + a + " wants NAME\n");
                exit(1);
            };
            i++;
            defines += parse_define(argv[i], false, "-U");
        } else if (a.starts_with("-U") && len(a) > 2) {
            defines += parse_define(a[2:], false, "-U");
        } else if (a.starts_with("--undef=")) {
            defines += parse_define(a[8:], false, "-U");
        } else if (a == "--meta-arg") {
            if (i + 1 >= n) {
                puts("ycc: --meta-arg needs a value\n");
                exit(1);
            };
            i++;
            margs += argv[i];
        } else if (a.starts_with("--meta-arg=")) {
            margs += a[11:];
        } else if (a.starts_with("--one=")) {
            if (!project) { puts("ycc: --one is only for ycc build\n"); exit(1); };
            one = a[6:];
            if (len(one) == 0) { puts("ycc: --one needs a package name\n"); exit(1); };
        } else if (a == "--kernel") {
            puts("ycc: --kernel is now --target=kernel\n");
            exit(1);
        } else if (a == "-S") {
            puts("ycc: -S is now --emit=asm\n");
            exit(1);
        } else if (a == "-E") {
            puts("ycc: -E is now --emit=source\n");
            exit(1);
        } else if (a == "-t") {
            puts("ycc: -t is now --time\n");
            exit(1);
        } else if (a == "-w") {
            puts("ycc: -w is now --warnings=none\n");
            exit(1);
        } else if (a == "-W" || a.starts_with("-W")) {
            puts("ycc: -W is now --warnings=extra or --warnings=all\n");
            exit(1);
        } else if (a == "--no-gc") {
            puts("ycc: --no-gc is now --gc=never\n");
            exit(1);
        } else if (a == "--gc-stress") {
            puts("ycc: --gc-stress is now --gc=stress\n");
            exit(1);
        } else if (a == "--no-auto-regions") {
            puts("ycc: --no-auto-regions is now --regions=off\n");
            exit(1);
        } else if (a == "--no-exec") {
            puts("ycc: --no-exec is now --exec=off\n");
            exit(1);
        } else if (a == "--std-src") {
            puts("ycc: --std-src is now --std=source\n");
            exit(1);
        } else if (a == "--fix") {
            puts("ycc: --fix is now --warnings=fix\n");
            exit(1);
        } else if (a == "--web-stack" || a.starts_with("--web-stack=")) {
            puts("ycc: --web-stack is now --web=stack=SIZE\n");
            exit(1);
        } else if (a[0:1] == "-") {
            puts("ycc: unknown flag '" + a + "' (see ycc -h)\n");
            exit(1);
        } else {
            files += a;
        };
        i++;
    };
    asm_only = emit == "asm";
    dump = emit == "source";
    if (fix) { nowarn = false; if (wlevel < 2) { wlevel = 2; }; };
    // The default arch follows the target: linux is the host's arch, win and
    // kernel are x64, web is wasm32. An explicit --arch must fit the target.
    if (!arch_set) {
        if (res_target == "web") { res_arch = "wasm32"; }
        else if (res_target == "win" || res_target == "kernel") { res_arch = "x64"; }
        else { res_arch = hostos.arch(); };
    };
    if (res_target == "web") {
        if (arch_set) { puts("ycc: --target=web is wasm32 (--arch does not apply)\n"); exit(1); };
    } else if (res_target == "win" || res_target == "kernel") {
        if (res_arch != "x64") {
            puts("ycc: --target=" + res_target + " is x64 only\n");
            exit(1);
        };
    };
    if (emit == "page" || emit == "html") {
        if (!target_is_web()) {
            puts("ycc: --web-page is only for --target=web\n");
            exit(1);
        };
    } else if (emit == "wat") {
        if (!target_is_web()) {
            puts("ycc: --emit=wat is only for --target=web\n");
            exit(1);
        };
    };
    if (target_is_web()) {
        if (obf.mode() != "off") {
            puts("ycc: --obfuscate is not available for --target=web\n");
            exit(1);
        };
        if (pack) {
            puts("ycc: --pack is Linux ELF only (--target=web writes a wasm module)\n");
            exit(1);
        };
        if (res_subsystem == 2) {
            puts("ycc: --subsystem=gui is not available for --target=web\n");
            exit(1);
        };
    };
    { out: out, files: files, asm_only: asm_only, timing: timing, allow_exec: allow_exec, debug: debug, nowarn: nowarn, wlevel: wlevel, std_src: std_src, std_pack: std_pack, run: run, dump: dump, prog: prog, fix: fix, pack: pack, pack_method: pack_method, one: one, defines: defines, margs: margs, emit: emit }
};

// --target=OS: the one place a target name becomes the global every other
// place reads (src/y/target.y).  A bad name is a driver failure with the
// accepted spellings, not a silently-defaulted build: a program compiled for
// the wrong OS is worse than one that did not compile.
def parse_target(name: str) -> void {
    if (name == "windows") {
        puts("ycc: --target=windows is now --target=win\n");
        exit(1);
    } else if (name == "aarch64") {
        puts("ycc: --target=aarch64 is now --target=linux --arch=aarch64\n");
        exit(1);
    };
    if (target_known(name)) {
        res_target = name;
        if (name == "kernel") { nativelib.set_gc_mode(2); };
    }
    else {
        puts("ycc: unknown target '" + name + "' (linux, win, kernel, web)\n");
        exit(1);
    };
};

// --arch=ARCH: the instruction set, independent of the target.
def parse_arch(name: str) -> void {
    if (name != "x64" && name != "aarch64") {
        puts("ycc: unknown arch '" + name + "' (x64, aarch64)\n");
        exit(1);
    };
    res_arch = name;
};
// The final defines: the manifest's NAME=VALUE pairs, then the command line in
// order (a later -D wins; -U removes), sorted by name (S15).
def defs_pair(p: str) -> DefinePair {
    let eq = index_of(p, "=");
    if (eq < 0) { { name: p, value: "" } }
    else { { name: p[:eq], value: p[eq + 1:] } }
};

def defs_put(names: [str], values: [str], n: str, v: str) -> void {
    let i = 0;
    let hit = false;
    while (i < len(names)) {
        if (names[i] == n) { values[i] = v; hit = true; };
        i++;
    };
    if (!hit) { names += n; values += v; };
};

def defs_drop(names: [str], values: [str], n: str) -> Defs {
    let on: [str] = [];
    let ov: [str] = [];
    for i in 0..len(names) {
        if (names[i] != n) { on += names[i]; ov += values[i]; };
    };
    { names: on, values: ov }
};

def defs_resolve(base: [str], ops: [Define]) -> Defs {
    let names: [str] = [];
    let vals: [str] = [];
    base.foreach((p) => {
        let q = defs_pair(p);
        defs_put(names, vals, q.name, q.value);
    });
    ops.foreach((d) => {
        if (d.on) {
            defs_put(names, vals, d.name, d.value);
        } else {
            let r = defs_drop(names, vals, d.name);
            names = r.names;
            vals = r.values;
        };
    });
    let sn: [str] = [];
    let sv: [str] = [];
    for i in 0..len(names) {
        let j = len(sn);
        sn += "";
        sv += "";
        while (j > 0 && names[i] < sn[j - 1]) {
            sn[j] = sn[j - 1];
            sv[j] = sv[j - 1];
            j--;
        };
        sn[j] = names[i];
        sv[j] = vals[i];
    };
    { names: sn, values: sv }
};

// Hand the meta pass the build a generator sees. Called before every resolve
// (the driver, or a build child); the text itself is meta.y's, so the escaping
// lives in one place.
def set_meta_build(root: str, out: str, ds: Defs, margs: [str], debug: bool) -> void {
    let gcv = "never";
    if (nativelib.gc_mode == 0) { gcv = "auto"; }
    else if (nativelib.gc_mode == 1) { gcv = "always"; };
    meta.mg_build(meta.mg_build_text(res_target, meta.mg_target_os(res_target),
        meta.mg_target_arch(res_target, res_arch), wintgt.target_info(res_target).format,
        hostos.name(), debug, gcv, root, out, ds.names, ds.values, margs));
};

// --subsystem=NAME: what a Windows image declares itself to be. `console` (the
// default) gets a console from the system; `gui` has none (stdout and stderr go
// nowhere unless the program redirects them). It changes one header word, so on
// any other target it is accepted and ignored.
def parse_subsystem(name: str) -> void {
    if (name == "console") {
        res_subsystem = 3;
    } else if (name == "gui") {
        res_subsystem = 2;
    } else if (name == "windows") {
        puts("ycc: --subsystem=windows is now --subsystem=gui\n");
        exit(1);
    } else {
        puts("ycc: unknown subsystem '" + name + "' (console, gui)\n");
        exit(1);
    };
};

// ── the std pack ─────────────────────────────────────────────────────────
// The build attaches to ycc its std units, compiled (native.y std_pack):
// the binary ends with [pack][the pack's length, 8 digits][YCCPACK1].

def pack_magic() -> str {
    "YCCPACK1"
};

// The pack attached to this binary, or "" when there is none. Read once: the
// driver hands it to the meta pass before the resolve and to std_units after.
let self_pack_text = "";
let self_pack_done = false;

def self_pack() -> str {
    if (!self_pack_done) {
        self_pack_text = self_pack_read();
        self_pack_done = true;
    };
    self_pack_text
};

def self_pack_read() -> str {
    let fd = syscall(hostos.nr(257), -100, "/proc/self/exe", 0, 0);
    if (fd < 0) {
        ""
    } else {
        let pack = "";
        let size = syscall(hostos.nr(8), fd, 0, 2);
        if (size >= 16) {
            let buf: [byte; 16] = [0; 16];
            syscall(hostos.nr(8), fd, size - 16, 0);
            if ((syscall(hostos.nr(0), fd, &buf[0], 16)) == 16) {
                let tail = from_bytes(buf[0:16]);
                let nopt = tolong(tail[:8]);
                if (nopt != none && tail[8:] == pack_magic() && nopt ! > 0 && nopt ! <= size - 16) {
                    let n = nopt !;
                    syscall(hostos.nr(8), fd, size - 16 - n, 0);
                    // straight into one buffer of the pack's size: no chunks
                    // to copy into strings and join
                    let data = nativelib.zero_bytes(n);
                    let got = 0;
                    while (got >= 0 && got < n) {
                        let r = syscall(hostos.nr(0), fd, &data[got], n - got);
                        if (r <= 0) { got = -1; } else { got += r; };
                    };
                    if (got == n) { pack = from_bytes(data); }
                }
            }
        }
        syscall(hostos.nr(3), fd);
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

// ── --pack: a self-decompressing binary ──────────────────────────────────

def pack2_magic() -> str {
    "YCCPACK2"
};

def stub_magic() -> str {
    "YCCSTUB1"
};

// n as eight decimal digits, zero padded (the pack trailer's shape).
def pad8(n: long) -> str {
    let s = tostring(n);
    while (len(s) < 8) { s = "0" + s; };
    s
};

// n as four bytes, least significant first.
def pack_le32(n: long) -> str {
    chr(n & 255) + chr((n >> 8) & 255) + chr((n >> 16) & 255) + chr((n >> 24) & 255)
};

// The method byte in the BODY frame; the stub's decode_payload switches on
// these values.
def method_code(name: str) -> long {
    if (name == "store") { 0 } else if (name == "dynamic") { 1 } else if (name == "fixed") { 2 } else { 3 }
};

// The attached stub, or "" when this compiler has none. Read once, like
// self_pack: it sits in the 16 bytes before the std pack's own frame.
let self_stub_text = "";
let self_stub_done = false;

def self_stub() -> str {
    if (!self_stub_done) {
        self_stub_text = self_stub_read();
        self_stub_done = true;
    };
    self_stub_text
};

def self_stub_read() -> str {
    let fd = syscall(hostos.nr(257), -100, "/proc/self/exe", 0, 0);
    if (fd < 0) {
        ""
    } else {
        let stub = "";
        let size = syscall(hostos.nr(8), fd, 0, 2);
        if (size >= 32) {
            let buf: [byte; 16] = [0; 16];
            syscall(hostos.nr(8), fd, size - 16, 0);
            if ((syscall(hostos.nr(0), fd, &buf[0], 16)) == 16) {
                let tail = from_bytes(buf[0:16]);
                let nopt = tolong(tail[:8]);
                if (nopt != none && tail[8:] == pack_magic() && nopt ! > 0 && nopt ! <= size - 32) {
                    // the std pack's start; the stub's frame ends just before it
                    let ps = size - 16 - nopt !;
                    let sb: [byte; 16] = [0; 16];
                    syscall(hostos.nr(8), fd, ps - 16, 0);
                    if ((syscall(hostos.nr(0), fd, &sb[0], 16)) == 16) {
                        let st = from_bytes(sb[0:16]);
                        let mopt = tolong(st[:8]);
                        if (mopt != none && st[8:] == stub_magic() && mopt ! > 0 && mopt ! <= ps - 16) {
                            let m = mopt !;
                            syscall(hostos.nr(8), fd, ps - 16 - m, 0);
                            let data = nativelib.zero_bytes(m);
                            let got = 0;
                            while (got >= 0 && got < m) {
                                let r = syscall(hostos.nr(0), fd, &data[got], m - got);
                                if (r <= 0) { got = -1; } else { got += r; };
                            };
                            if (got == m) { stub = from_bytes(data); }
                        }
                    }
                }
            }
        }
        syscall(hostos.nr(3), fd);
        stub
    }
};

// Where src/y/packstub.y is, when this compiler carries no stub: the working
// tree, then beside the binary (std_lib_path's candidate shape).
def stub_source_path() -> str {
    let cands: [str] = ["src/y/packstub.y", "packstub.y"];
    let buf: [byte; 4096] = [0; 4096];
    let n = hostos.readlink("/proc/self/exe", &buf[0], 4096);
    if (n > 0) {
        let exe = from_bytes(buf[0:n]);
        let sl = last_index_of(exe, "/");
        if (sl >= 0) {
            let d = exe[:sl];
            cands += d + "/packstub.y";
            cands += d + "/src/y/packstub.y";
            cands += d + "/../src/y/packstub.y";
        };
    };
    let out = "";
    let i = 0;
    while (len(out) == 0 && i < len(cands)) {
        if (fs.exists(cands[i])) { out = cands[i]; };
        i = i + 1;
    };
    out
};

// Compile the stub in this process, the way `ycc build` compiles package
// after package: resolve, tokenize, parse, link the std units, emit, assemble.
def compile_stub(path: str) -> [byte] {
    let src = fs.read_file(path);
    if (src == none) { return []; };
    obf.suspend();
    let saved_gc = nativelib.gc_mode;
    nativelib.set_gc_mode(2);
    meta.meta_begin();
    let nr = nativelib.native_resolve_x(unwrap(src), pkg.pk_dir_of(path), 0, true, path);
    let su = nativelib.std_units(std_order(nr.std), self_pack());
    let r = nativelib.emit_program(parser.parse_program(lexer.tokenize(nr.src)), nr, false, 0, su, []);
    nativelib.set_gc_mode(saved_gc);
    if (!r.ok) {
        print_native_errors(r.errors, nr.origin, true);
        return [];
    };
    let ab = nasm.ycc_assemble(r.asm, false);
    obf.resume();
    if (!ab.ok) {
        puts("error: assembling the pack stub: " + ab.error + "\n");
        return [];
    };
    ab.bytes
};

// The stub's bytes: the attached one, else compiled from source.
def pack_stub() -> [byte] {
    let s = self_stub();
    if (s[:8] == "YCCSTB2!") {
        let n = tolong(s[8:16]);
        if (n != none && n! > 0 && n! <= len(s) - 16) {
            s = if (target_is_aarch64()) { s[16 + n!:] } else { s[16:16 + n!] };
        } else { s = ""; };
    };
    if (len(s) >= 20 && s[18] == (if (target_is_aarch64()) { 183 } else { 62 }) && s[19] == 0) { return bytes(s); };
    let p = stub_source_path();
    if (len(p) == 0) { return []; };
    compile_stub(p)
};

def pack_plain_if_ycc(payload: str) -> str {
    if (len(payload) < 16) { return payload; };
    let tail = payload[len(payload) - 16:len(payload)];
    if (tail[8:] != pack_magic()) { return payload; };
    let nopt = tolong(tail[:8]);
    if (nopt == none || nopt ! <= 0 || nopt ! > len(payload) - 16) { return payload; };
    let n = nopt !;
    let at = len(payload) - 16 - n;
    let t = nativelib.pack_plain_frame(payload[at:at + n]);
    if (len(t) == 0) { return payload; };
    payload[:at] + t + pad8(len(t)) + pack_magic()
};

// The BODY frame for `raw`: the method byte, the decoded length and the data.
def pack_frame(method: str, raw: str) -> str {
    let n = len(raw);
    let data = "";
    if (method == "store") {
        data = raw;
    } else if (method == "fixed") {
        data = nativelib.deflate_pack(raw, 24);
    } else if (method == "lz") {
        data = nativelib.lz_encode(raw);
    } else {
        data = nativelib.deflate_dynamic(raw, 256);
    };
    chr(method_code(method)) + pack_le32(n) + data
};

// The packed file: the stub, the body and the trailer. 493 = 0755.
def write_packed(payload: str, method: str, out_path: str) -> bool {
    // An existing ELF chooses its own stub, even when the driver defaults to
    // the other architecture. Never wrap a foreign payload with a host stub.
    if (len(payload) < 20 || payload[4] != 2 || payload[5] != 1 || payload[19] != 0
        || (payload[18] != 62 && payload[18] != 183)) {
        puts("error: --pack needs a Linux x86-64 or AArch64 ELF64 executable\n");
        return false;
    };
    let saved_target = res_target;
    let saved_arch = res_arch;
    res_target = "linux";
    res_arch = if (payload[18] == 183) { "aarch64" } else { "x64" };
    let stub = pack_stub();
    res_target = saved_target;
    res_arch = saved_arch;
    if (len(stub) == 0) {
        puts("error: --pack: this compiler carries no pack stub and src/y/packstub.y is not beside it\n");
        exit(1);
    };
    let raw = pack_plain_if_ycc(payload);
    let body = pack_frame(method, raw);
    let outb: [byte] = [];
    outb += stub;
    outb += bytes(body + pad8(len(body)) + pack2_magic());
    fs.write_bytes(out_path, outb, 493)
};

// Whether `s` starts with the ELF magic: --pack treats such a file as the
// payload itself (how `ycc --pack ./ycc` works) rather than as Y source.
def is_elf(s: str) -> bool {
    len(s) >= 4 && s[0] == 127 && s[1] == 69 && s[2] == 76 && s[3] == 70
};

// ── phase reporting (--time) ─────────────────────────────────────────────
// Everything goes to stderr via eputs: stdout carries program output and
// `--emit=asm` assembly, and must stay clean enough to diff.

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
    let seen = parser.nameix_new(64);
    all.foreach((e) => {
        let at = nativelib.origin_at(origin, e.line, bare) + ":" + tostring(e.col);
        if (parser.nameix_get(seen, at) < 0) {
            parser.nameix_put(seen, at, 1);
            puts(at + ": error: " + e.msg + "\n");
        }
    });
};

def warning_text(warnings: [Diag], origin: Origin, bare: bool) -> str {
    // An append in place: a closure's capture would copy the text per warning,
    // which --strict-heap's thousands make quadratic.
    let out = "";
    foreach (w in warnings) {
        out += nativelib.origin_at(origin, w.line, bare) + ":" + tostring(w.col) + ": warning: " + w.msg + "\n";
    };
    out
};

def print_native_warnings(warnings: [Diag], origin: Origin, bare: bool) -> void {
    eputs(warning_text(warnings, origin, bare));
};

// ── ycc build / ycc vendor (see pkg.y) ───────────────────────────────────

// A random seed for a build that did not name one. It is deterministic only
// when --obfuscate-seed is given, which every test does.
def random_obf_seed() -> long {
    let pid = syscall(hostos.nr(39));
    (clock_us() ^ (pid << 32) ^ heap_used())
};

def validate_obf(debug: bool, pack: bool, asm_only: bool, dump: bool,
        fix: bool, std_pack: str) -> void {
    if (obf.mode() == "off") {
        if (obf_layout_flag) {
            puts("ycc: --obfuscate-layout needs --obfuscate\n");
            exit(1);
        };
        if (obf_std_flag) {
            puts("ycc: --obfuscate-std needs --obfuscate\n");
            exit(1);
        };
        if (obf_diversity_flag) {
            puts("ycc: --obfuscate-diversity needs --obfuscate\n");
            exit(1);
        };
        if (len(obf_map_path) > 0) {
            puts("ycc: --obfuscate-map needs --obfuscate\n");
            exit(1);
        };
        if (obf.seed_set()) {
            puts("ycc: --obfuscate-seed needs --obfuscate\n");
            exit(1);
        };
        if (obf_vm_flag) {
            puts("ycc: --obfuscate-vm needs --obfuscate\n");
            exit(1);
        };
        if (len(obf_key_file_path) > 0) {
            puts("ycc: --obfuscate-key-file needs --obfuscate\n");
            exit(1);
        };
        if (obf_key_fd_flag >= 0) {
            puts("ycc: --obfuscate-key-fd needs --obfuscate\n");
            exit(1);
        };
        if (obf_anti_debug_flag) {
            puts("ycc: --obfuscate-anti-debug needs --obfuscate\n");
            exit(1);
        };
        if (obf_no_anti_debug_flag) {
            puts("ycc: --obfuscate-no-anti-debug needs --obfuscate\n");
            exit(1);
        };
        return;
    };
    // There is one obfuscation level: full. The bare flag and =full both
    // choose the strongest settings; an explicit sub-flag may still tune a
    // layer for a test or a bring-up.
    if (!obf_std_flag) { obf.set_std_mode("all"); };
    if (!obf_diversity_flag) { obf.set_diversity("high"); };
    if (debug) {
        puts("ycc: -g cannot combine with --obfuscate (symbols and line tables expose the layout)\n");
        exit(1);
    };
    if (target_is_kernel()) {
        puts("ycc: --obfuscate is not supported with --target=kernel\n");
        exit(1);
    };
    if (obf.seal_on() && pack) {
        puts("ycc: --pack cannot combine with --obfuscate\n");
        exit(1);
    };
    if (obf.seal_on() && asm_only) {
        puts("ycc: --emit=asm cannot combine with --obfuscate (no plaintext listing)\n");
        exit(1);
    };
    if (obf.seal_on() && dump) {
        puts("ycc: --emit=source cannot combine with --obfuscate\n");
        exit(1);
    };
    if (dump || fix || len(std_pack) > 0) {
        puts("ycc: --obfuscate applies to executable generation only\n");
        exit(1);
    };
    if (target_is_windows() && (len(obf_key_file_path) > 0 || obf_key_fd_flag >= 0)) {
        puts("ycc: a PE seal uses the embedded key only (no --obfuscate-key on --target=win)\n");
        exit(1);
    };
    if (obf_key_fd_flag >= 0 && len(obf_key_file_path) == 0) {
        puts("ycc: --obfuscate-key-fd needs --obfuscate-key=PATH\n");
        exit(1);
    };
    if (len(obf_key_file_path) > 0) {
        let kt = fs.read_file(obf_key_file_path);
        let kb: [byte] = [];
        if (kt != none) { kb = bytes(kt!); };
        if (len(kb) < 16) {
            puts("ycc: --obfuscate-key-file: cannot read 16 bytes from '" + obf_key_file_path + "'\n");
            exit(1);
        };
        obf.set_external_key(seal.key_from_bytes(kb), obf_key_file_path);
    } else {
        obf.set_external_key(0, "");
    };
    obf.set_no_anti_debug(obf_no_anti_debug_flag);
    obf.set_key_fd(obf_key_fd_flag);
    obf.set_anti_debug(!obf_no_anti_debug_flag && obf.mode() == "full");
    if (!obf.seed_set()) { obf.set_seed(random_obf_seed()); };
};

def build_args(cl: [str]) -> { dir: str, debug: bool, nowarn: bool, wlevel: long, allow_exec: bool, std_src: bool, one: str, defines: [Define], margs: [str] } {
    let args = parse_cli_args([cl[0]] + cl[2:], true);
    validate_obf(args.debug, args.pack, args.asm_only, args.dump, args.fix,
        args.std_pack);
    nasm.asm_map_enable(len(obf_map_path) > 0);
    if (len(args.out) > 0 || args.asm_only || args.dump || args.run || args.fix
        || args.emit == "wat" || args.emit == "page" || args.emit == "html"
        || args.pack || len(args.std_pack) > 0 || args.timing) {
        puts("ycc: " + cl[1] + " accepts executable build options only (see ycc --help)\n");
        exit(1);
    };
    if (len(args.files) > 1) {
        puts("error: ycc " + cl[1] + " takes one project directory\n"); exit(1);
    };
    let dir = if (len(args.files) == 0) { "." } else { args.files[0] };
    { dir: dir, debug: args.debug, nowarn: args.nowarn, wlevel: args.wlevel,
        allow_exec: args.allow_exec, std_src: args.std_src, one: args.one,
        defines: args.defines, margs: args.margs }
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
    // unit gets its own generator.
    meta.meta_begin();
    nativelib.native_resolve_pk(unwrap(src), pkg.pk_dir_of(path), allow_exec, path, pkgs, roots)
};

// The std units among `names`, in link order.
def std_order(names: [str]) -> [str] {
    // A program that links a library unit links what that unit imports too: a
    // unit is compiled and linked against the units before it (std_lib_deps),
    // and std_unit_names is already dependency-first. `names` is copied first --
    // arrays are references, and `+=` would grow the caller's resolution.
    let want: [str] = [];
    names.foreach((e) => {
        want += e;
    });
    let i = 0;
    while (i < len(want)) {
        let ds = nativelib.std_lib_deps(want[i]);
        ds.foreach((d) => {
            if (!pkg.pk_has(want, d)) { want += d; };
        });
        i = i + 1;
    };
    let all = nativelib.std_unit_names();
    let out: [str] = [];
    all.foreach((e) => {
        let nm: str = e;
        if (pkg.pk_has(want, nm)) { out += nm; }
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

def build_key(cid: str, name: str, base: long, allow_exec: bool, nr: Resolved, units: [Unit], ds: Defs, margs: [str]) -> str {
    let h = pkg.pk_hash_new();
    pkg.pk_hash_str(h, cid);
    pkg.pk_hash_str(h, name);
    pkg.pk_hash_str(h, tostring(base));
    pkg.pk_hash_str(h, wintgt.target_os());
    pkg.pk_hash_str(h, wintgt.target_arch());
    pkg.pk_hash_str(h, tostring(nativelib.auto_regions));
    pkg.pk_hash_str(h, tostring(nativelib.strict_heap));
    pkg.pk_hash_str(h, tostring(nativelib.gc_mode));
    pkg.pk_hash_str(h, tostring(nativelib.gc_stress));
    let ex = "exec";
    if (!allow_exec) { ex = "no-exec"; }
    pkg.pk_hash_str(h, ex);
    // The build's inputs are part of the key: a define or a meta argument
    // that changes must recompile even when the source text is the same.
    ds.names.foreach((n) => {
        pkg.pk_hash_str(h, n);
    });
    ds.values.foreach((v) => {
        pkg.pk_hash_str(h, v);
    });
    margs.foreach((a) => {
        pkg.pk_hash_str(h, a);
    });
    // The web stack changes the module's layout; --web-checked changes every
    // access; the [web] files and defines change what the bundle carries.
    if (target_is_web()) {
        pkg.pk_hash_str(h, "web-stack=" + tostring(web_stack_bytes));
        pkg.pk_hash_str(h, "web-checked=" + tostring(web_checked_flag));
        pkg.pk_hash_str(h, "web-files=" + web_get(web_cfg, "files", ""));
        pkg.pk_hash_str(h, "web-defines=" + web_get(web_cfg, "defines", ""));
    };
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

// ── `ycc build`: compiling a ready level of packages in parallel ─────────
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
    let n = hostos.readlink("/proc/self/exe", &buf[0], 4096);
    if (n <= 0) { "" } else { from_bytes(buf[0:n]) }
};

// The flags a child needs to compile its package exactly as this run would.
def build_child_flags(debug: bool, nowarn: bool, wlevel: long, allow_exec: bool, defines: [Define], margs: [str]) -> str {
    let out = " --optimize=" + optim.goal();
    let gcm = if (nativelib.gc_stress) { "stress" }
        else if (nativelib.gc_mode == 0) { "auto" }
        else if (nativelib.gc_mode == 1) { "always" } else { "never" };
    out += " --gc=" + gcm;
    if (!nativelib.auto_regions) { out += " --regions=off"; };
    if (nativelib.strict_heap) { out += " --strict-heap"; };
    if (res_target != "linux") { out += " --target=" + res_target; };
    if (res_target == "linux" && res_arch != hostos.arch()) { out += " --arch=" + res_arch; };
    if (res_subsystem == 2) { out += " --subsystem=gui"; };
    // A child re-reads the manifest; the command line's --web (a stack
    // included) must travel with it.
    if (target_is_web()) {
        if (web_checked_flag) { out += " --web-checked"; };
        web_kv_list.foreach((kv) => {
            out += " --web " + build_q(kv);
        });
    };
    if (debug) { out += " -g"; };
    if (nowarn) { out += " --warnings=none"; }
    else if (wlevel > 0) { out = out + " --warnings=" + (if (wlevel == 1) { "extra" } else { "all" }); };
    if (!allow_exec) { out += " --exec=off"; };
    // The child re-reads the manifest's [defines]; forwarding the command
    // line in its own order makes its precedence the same as this run's.
    defines.foreach((d) => {
        if (d.on) { out += " -D " + build_q(d.name + "=" + d.value); }
        else { out += " -U " + build_q(d.name); };
    });
    margs.foreach((m) => {
        out += " --meta-arg " + build_q(m);
    });
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

// Where a project's build output goes: DIR/build for Linux x64, and a
// target/arch directory for every other build, whose package objects are not
// the Linux x64 ones.
def build_dir(dir: str) -> str {
    let b = pkg.pk_join(dir, "build");
    if (target_is_windows() || target_is_kernel() || target_is_web()) { b + "/" + res_target }
    else if (target_is_aarch64()) { b + "/linux-aarch64" }
    else { b }
};

def build_one(dir: str, one: str, debug: bool, nowarn: bool, wlevel: long, allow_exec: bool, std_src: bool, defines: [Define], margs: [str]) -> void {
    let g = pkg.pk_load(dir);
    heap { web_cfg = pkg.pk_web_merge(g.web, web_kv_list); };
    if (target_is_web()) { web_apply_stack(web_cfg); };
    let ds = defs_resolve(web_manifest_defines(g.defines, web_cfg), defines);
    set_meta_build("", "", ds, margs, debug);
    let pkgs = g.pkgs;
    let odir = build_dir(dir) + "/obj";
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
            let key = build_key(cid, p.name, (5000000000 + k * 1000000000), allow_exec, (build_resolve(p.lib, allow_exec, p.deps, p.roots)), units, ds, margs);
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
    let key = build_key(cid, p.name, base, allow_exec, nr, units, ds, margs);
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

def build_dispatch_level(dir: str, pkgs: [PkNode], odir: str, lo: long, hi: long, debug: bool, nowarn: bool, wlevel: long, allow_exec: bool, std_src: bool, defines: [Define], margs: [str]) -> void {
    let n = 0;
    // --std=source has no pack, so a child would compile the std units from
    // source before its own package: far more than the package costs.
    if (!std_src && hi - lo > 1) {
        let exe = self_exe();
        if (len(exe) > 0) {
            let flags = build_child_flags(debug, nowarn, wlevel, allow_exec, defines, margs);
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
def build_project(dir: str, debug: bool, nowarn: bool, wlevel: long, allow_exec: bool, std_src: bool, defines: [Define], margs: [str]) -> void {
    let g = pkg.pk_load(dir);
    heap { web_cfg = pkg.pk_web_merge(g.web, web_kv_list); };
    if (target_is_web()) { web_apply_stack(web_cfg); };
    let ds = defs_resolve(web_manifest_defines(g.defines, web_cfg), defines);
    // Every unit this run resolves sees the same build: the manifest's
    // defines, then the command line (S15).
    set_meta_build("", "", ds, margs, debug);
    // The manifest's obfuscation settings, unless the command line chose a
    // mode. `-g` would expose exactly the layout the mode hides.
    if (len(g.obf) > 0 && obf.mode() == "off") {
        if (debug) {
            puts("error: -g cannot combine with obfuscation (symbols and line tables expose the layout)\n");
            exit(1);
        };
        pick_obf_mode(g.obf);
        if (len(g.obf_seed) > 0 && !obf.seed_set()) {
            let sv = tolong(g.obf_seed);
            if (sv == none) {
                puts("error: y.toml: obfuscate_seed '" + g.obf_seed + "' is not a number\n");
                exit(1);
            };
            obf.set_seed(sv!);
        };
        if (len(g.obf_layout) > 0 && !obf_layout_flag) {
            if (!(g.obf_layout in ["source", "shuffle"])) {
                puts("error: y.toml: obfuscate_layout wants source or shuffle\n");
                exit(1);
            };
            obf.set_layout(g.obf_layout);
        };
        if (len(g.obf_std) > 0 && !obf_std_flag) {
            if (!(g.obf_std in ["off", "auto", "all"])) {
                puts("error: y.toml: obfuscate_std wants off, auto or all\n");
                exit(1);
            };
            obf.set_std_mode(g.obf_std);
        };
        if (len(g.obf_diversity) > 0 && !obf_diversity_flag) {
            if (!(g.obf_diversity in ["standard", "high"])) {
                puts("error: y.toml: obfuscate_diversity wants standard or high\n");
                exit(1);
            };
            obf.set_diversity(g.obf_diversity);
        };
        if (len(obf_map_path) == 0 && len(g.obf_map) > 0) {
            obf_map_path = pkg.pk_join(dir, g.obf_map);
        };
        nasm.asm_map_enable(len(obf_map_path) > 0);
    } else if (len(g.obf) == 0 && len(g.obf_map) > 0) {
        puts("error: y.toml: obfuscate_map needs obfuscate\n");
        exit(1);
    };
    // the manifest's `subsystem`, unless the command line said
    if (res_subsystem == 0 && g.subsystem == "gui") { res_subsystem = 2; }
    let bins = g.bins;
    let pkgs = g.pkgs;
    if (len(bins) == 0 && len(g.lib) == 0) {
        puts("error: " + pkg.pk_join(dir, "y.toml") + " has no [bin] and no lib: nothing to build\n");
        exit(1);
    }
    let bdir = build_dir(dir);
    let odir = bdir + "/obj";
    pkg.pk_mkdir(pkg.pk_join(dir, "build"));
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
        build_dispatch_level(dir, pkgs, odir, k, hi, debug, nowarn, wlevel, allow_exec, std_src, defines, margs);
        while (k < hi) {
            let p = pkgs[k];
            let nr = nrs[k];
            let base = 5000000000 + k * 1000000000;
            let key = build_key(cid, p.name, base, allow_exec, nr, units, ds, margs);
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
        print_obf_report();
        let ab = assemble_for_target(r.asm, debug, r.seal);
        if (!ab.ok) {
            puts("error: assemble: " + ab.error + "\n");
            exit(1);
        }
        write_obf_map();
        let outp = bdir + "/" + bn.name;
        if (target_is_web()) {
            // D10: build/web/NAME/ is the site, build/web/bin/NAME the Node
            // launcher, and [web] single = "true" adds build/web/NAME.html.
            let site = outp;
            if (!write_web_page(site, bn.name, g.name, ab.bytes, web_cfg, dir)) { exit(1); };
            if (!write_web_launcher(bdir + "/bin/" + bn.name, bn.name)) {
                puts("error: writing '" + bdir + "/bin/" + bn.name + "' failed\n");
                exit(1);
            };
            if (web_get(web_cfg, "single", "false") == "true") {
                let hp = bdir + "/" + bn.name + ".html";
                if (!write_web_html(hp, bn.name, g.name, ab.bytes, web_cfg, dir)) { exit(1); };
            };
            eputs("built " + site + "\n");
        } else {
            if (target_is_windows()) { outp += ".exe"; };
            if (!fs.write_bytes(outp, ab.bytes, 493)) {
                puts("error: writing '" + outp + "' failed\n");
                exit(1);
            };
            eputs("built " + outp + "\n");
        };
        b++;
    };
};

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

def write_obf_map() -> void {
    if (len(obf_map_path) == 0) { return; };
    let h = "# ycc obfuscation map\n" +
        "build=" + tostring(obf.build_id()) + "\n" +
        "mode=" + obf.mode() + "\n" +
        "seed=" + tostring(obf.seed_value()) + "\n" +
        nasm.asm_map_text();
    if (!fs.write_file(obf_map_path, h)) {
        puts("error: writing '" + obf_map_path + "' failed\n");
        exit(1);
    };
};

def print_obf_report() -> void {
    if (obf_report_flag) {
        obf.report().foreach((l) => {
            eputs(l + "\n");
        });
    };
};


// ── the writer seam (S1) ─────────────────────────────────────────────────
// Every ycc_assemble call site in this driver goes through here; only the
// meta generator keeps calling asm.ycc_assemble, because it is always host.
def assemble_for_target(parts: [nasm.LinkPart], debug: bool, seal_key: long) -> AsmOutI {
    if (target_is_web()) {
        // The writer's tables live for the compile (module-level state), so
        // its allocations are process-lifetime, not an arena's.
        let wr: AsmOutI = { ok: false, bytes: [], error: "web writer did not run", times: [], items: 0 };
        heap {
            wr = wasmlink.wasm_assemble(parts, debug, web_stack_bytes, web_checked_flag);
        };
        wr
    } else {
        let r = nasm.ycc_assemble(parts, debug, seal_key);
        { ok: r.ok, bytes: r.bytes, error: r.error, times: r.times, items: r.items }
    }
};

// The web host is a pack asset in a packed binary (D11); a W3 compiler reads
// it from the checkout or from beside itself, and $YHOST overrides both.
def web_host_path() -> str {
    let env = fs.getenv("YHOST");
    if (env != none) { return unwrap(env); };
    if (fs.exists("src/web/yhost.js")) { return "src/web/yhost.js"; };
    let buf: [byte; 4096] = [0; 4096];
    let n = hostos.readlink("/proc/self/exe", &buf[0], 4096);
    if (n > 0) {
        let exe = from_bytes(buf[0:n]);
        let sl = last_index_of(exe, "/");
        if (sl > 0) {
            let dir = exe[0:sl];
            let a = dir + "/src/web/yhost.js";
            if (fs.exists(a)) { return a; };
            let b = dir + "/yhost.js";
            if (fs.exists(b)) { return b; };
        };
    };
    ""
};

def web_node_path() -> str {
    let env = fs.getenv("NODE");
    if (env != none) { return unwrap(env); };
    let cands = ["/usr/bin/node", "/usr/local/bin/node", "/bin/node"];
    let i = 0;
    while (i < len(cands)) {
        if (fs.exists(cands[i])) { return cands[i]; };
        i++;
    };
    ""
};

// The current environment, as the NUL-separated strings execve takes.
def web_environ() -> [[byte]] {
    let out: [[byte]] = [];
    let text = fs.read_file("/proc/self/environ");
    if (text != none) {
        let t = unwrap(text);
        let parts = split(t, "\x00");
        let i = 0;
        while (i < len(parts)) {
            let p = parts[i];
            if (len(p) > 0) {
                let b = bytes(p);
                b += 0;
                out += [b];
            };
            i++;
        };
    };
    out
};

def web_cstrs(items: [[byte]]) -> [long] {
    let ps: [long] = [];
    let i = 0;
    while (i < len(items)) {
        let it = items[i];
        ps += ptr_addr(&it[0]);
        i++;
    };
    ps += 0;
    ps
};

// ycc run --target=web: write the module into a temporary directory and run
// node on the host (D10); the child inherits our stdio and environment.
def run_web_module(module: [byte], prog: [str]) -> long {
    let node = web_node_path();
    let host = web_host_path();
    if (node == "" || host == "") {
        puts("ycc: running a web program needs node ≥ 22 (set NODE=/path/to/node)\n");
        return 1;
    };
    let code = 0;
    region {
    let tmp = "/tmp";
    let te = fs.getenv("TMPDIR");
    if (te != none) { if (len(unwrap(te)) > 0) { tmp = unwrap(te); }; };
    let pid = syscall(hostos.nr(39));
    let dir = tmp + "/yccweb-" + tostring(pid);
    if (!fs.make_dir(dir, 448)) {
        puts("ycc: cannot make a temporary directory for the web run ('" + dir + "')\n");
        return 1;
    };
    let wpath = dir + "/prog.wasm";
    if (!fs.write_bytes(wpath, module, 420)) {
        puts("ycc: writing '" + wpath + "' failed\n");
        fs.remove_dir(dir);
        return 1;
    };
    let av: [[byte]] = [];
    let args: [str] = [node, "--disable-wasm-trap-handler", host, "run", wpath];
    args += prog;
    let i = 0;
    while (i < len(args)) {
        let b: [byte] = [];
        let k = 0;
        while (k < len(args[i])) { b += args[i][k]; k++; };
        b += 0;
        av += [b];
        i++;
    };
    let envs = web_environ();
    let pid2 = syscall(hostos.nr(57), 17, 0, 0, 0, 0);
    if (pid2 == 0) {
        let ap = web_cstrs(av);
        let ep = web_cstrs(envs);
        let nb: [byte] = [];
        let nk = 0;
        while (nk < len(node)) { nb += node[nk]; nk++; };
        nb += 0;
        syscall(hostos.nr(59), &nb[0], &ap[0], &ep[0]);
        exit(127);
    };
    let ws: [byte; 8] = [0; 8];
    syscall(hostos.nr(61), pid2, &ws[0], 0, 0, 0);
    let status = ws[0] | (ws[1] << 8);
    let low = status % 128;
    if (low == 0) { code = (status / 256) % 256; } else { code = 128 + low; };
    fs.remove_file(wpath);
    fs.remove_dir(dir);
    };
    code
};

// ── the web site (D10, S13, W5) ─────────────────────────────────────────
// One module plus the host files, a config JSON the page reads, the [web]
// files as files.bin (Appendix C), and either index.html from src/web/page.html
// or one self-contained .html.  The template's four placeholders are
// {{TITLE}}, {{CONFIG}}, {{HOST}} and {{MODULE}}.

type WebJs = { names: [str], texts: [str] };

def web_get(cfg: [str], key: str, dflt: str) -> str {
    let v = pkg.pk_web_get(cfg, key);
    if (v == none) { dflt } else { unwrap(v) }
};

// [web] stack and --web=stack: the command line wins over the manifest.
// [defines], then [web] defines when the target is web (S15's middle rung).
def web_manifest_defines(base: [str], cfg: [str]) -> [str] {
    let out: [str] = [];
    foreach (d in base) { out += d; };
    if (target_is_web()) {
        let wd = pkg.pk_web_get(cfg, "defines");
        if (wd != none) {
            foreach (p in pkg.pk_web_items(unwrap(wd))) { out += p; };
        };
    };
    out
};

def web_apply_stack(cfg: [str]) -> void {
    let v = pkg.pk_web_get(cfg, "stack");
    if (v == none) { return; };
    let n = pkg.pk_web_size(unwrap(v));
    if (n > 0) { web_stack_bytes = n; };
};

def web_hex4(c: long) -> str {
    let d = "0123456789abcdef";
    chr(d[(c >> 12) & 15]) + chr(d[(c >> 8) & 15]) + chr(d[(c >> 4) & 15]) + chr(d[c & 15])
};

// A JSON string literal.  <, > and & are escaped too, so a value can never
// close the page's <script type="application/json"> element.
def web_json_str(s: str) -> str {
    let parts: [str] = [];
    for i in 0..len(s) {
        let c = s[i];
        if (c == 34) { parts += "\\\""; }
        else if (c == 92) { parts += "\\\\"; }
        else if (c == 10) { parts += "\\n"; }
        else if (c == 9) { parts += "\\t"; }
        else if (c == 13) { parts += "\\r"; }
        else if (c < 32 || c == 60 || c == 62 || c == 38) { parts += "\\u" + web_hex4(c); }
        else { parts += chr(c); };
    };
    "\"" + join(parts, "") + "\""
};

def web_json_arr(xs: [str]) -> str {
    let parts: [str] = [];
    foreach (x in xs) { parts += web_json_str(x); };
    "[" + join(parts, ",") + "]"
};

// "K=V" pairs (env, defines) as a JSON object.
def web_json_obj(pairs: [str]) -> str {
    let parts: [str] = [];
    foreach (p in pairs) {
        let eq = index_of(p, "=");
        if (eq > 0) { parts += web_json_str(p[:eq]) + ":" + web_json_str(p[eq + 1:]); };
    };
    "{" + join(parts, ",") + "}"
};

// The page's config: every S13 key with its default, then the three the
// writer supplies (the module URL, the bundle URL and the program's name).
def web_config_json(cfg: [str], name: str, id: str, module_url: str, files_bin: str, module_b64: str, files_b64: str) -> str {
    let files = pkg.pk_web_items(web_get(cfg, "files", ""));
    let args = pkg.pk_web_items(web_get(cfg, "args", ""));
    let envs = pkg.pk_web_items(web_get(cfg, "env", ""));
    let defs = pkg.pk_web_items(web_get(cfg, "defines", ""));
    "{\"title\":" + web_json_str(web_get(cfg, "title", name))
        + ",\"id\":" + web_json_str(web_get(cfg, "id", id))
        + ",\"start\":" + web_json_str(web_get(cfg, "start", "auto"))
        + ",\"canvas\":" + web_json_str(web_get(cfg, "canvas", "fixed"))
        + ",\"zoom\":" + web_json_str(web_get(cfg, "zoom", "1"))
        + ",\"smooth\":" + web_json_str(web_get(cfg, "smooth", "false"))
        + ",\"console\":" + web_json_str(web_get(cfg, "console", "auto"))
        + ",\"persist\":" + web_json_str(web_get(cfg, "persist", "home"))
        + ",\"files\":" + web_json_arr(files)
        + ",\"args\":" + web_json_arr(args)
        + ",\"url_args\":" + web_json_str(web_get(cfg, "url_args", "true"))
        + ",\"env\":" + web_json_obj(envs)
        + ",\"stack\":" + web_json_str(web_get(cfg, "stack", tostring(web_stack_bytes)))
        + ",\"pause_hidden\":" + web_json_str(web_get(cfg, "pause_hidden", "true"))
        + ",\"single\":" + web_json_str(web_get(cfg, "single", "false"))
        + ",\"template\":" + web_json_str(web_get(cfg, "template", ""))
        + ",\"defines\":" + web_json_obj(defs)
        + ",\"name\":" + web_json_str(name)
        + ",\"module\":" + web_json_str(module_url)
        + ",\"files_bin\":" + web_json_str(files_bin)
        + ",\"module_base64\":" + web_json_str(module_b64)
        + ",\"files_base64\":" + web_json_str(files_b64)
        + "}"
};

// The page template: [web] template first, then $YWEB_PAGE, then the
// checkout's src/web/page.html, then one beside the compiler.
def web_page_path() -> str {
    let env = fs.getenv("YWEB_PAGE");
    if (env != none) { return unwrap(env); };
    if (fs.exists("src/web/page.html")) { return "src/web/page.html"; };
    let buf: [byte; 4096] = [0; 4096];
    let n = hostos.readlink("/proc/self/exe", &buf[0], 4096);
    if (n > 0) {
        let exe = from_bytes(buf[0:n]);
        let sl = last_index_of(exe, "/");
        if (sl > 0) {
            let dir = exe[0:sl];
            let a = dir + "/src/web/page.html";
            if (fs.exists(a)) { return a; };
            let b = dir + "/page.html";
            if (fs.exists(b)) { return b; };
        };
    };
    ""
};

def web_template_text(cfg: [str], base: str) -> str? {
    let t = web_get(cfg, "template", "");
    let p = t;
    if (len(t) > 0 && t[:1] != "/") { p = pkg.pk_join(base, t); };
    if (len(t) == 0) { p = web_page_path(); };
    if (len(p) == 0) {
        puts("ycc: cannot find src/web/page.html to write the page\n");
        return none;
    };
    let text = fs.read_file(p);
    if (text == none) {
        puts("ycc: cannot read the page template '" + p + "'\n");
        return none;
    };
    text
};

// The directory holding the host's JS: beside the host web_host_path found.
def web_asset_dir() -> str {
    let host = web_host_path();
    if (host == "") { return ""; };
    let sl = last_index_of(host, "/");
    if (sl >= 0) { host[0:sl] } else { "." }
};

// The browser entry the page loads.  page.js is the browser's own entry
// (W5); yhost.js is the Node CLI, and older checkouts have only that.
def web_entry(asset: str) -> str {
    let e = fs.getenv("YWEB_ENTRY");
    if (e != none && len(unwrap(e)) > 0) { return unwrap(e); };
    if (fs.exists(asset + "/page.js")) { return "page.js"; };
    "yhost.js"
};

// The compiler is built with checked lifetimes, and the pack gives
// fs.list_dir/read_bytes/path_extension no reclaimable summary: a call to any
// of them from main is an error even inside a region.  These four local
// versions use only primitives the pack proves (openat/getdents64/fstatat and
// the open/read/write wrappers), so the site writer is buildable.
def web_ext(p: str) -> str {
    let b = p;
    let cut = last_index_of(b, "/");
    if (cut >= 0) { b = b[cut + 1:]; };
    let dot = last_index_of(b, ".");
    if (dot <= 0) { "" } else { b[dot + 1:] }
};

def web_mode(path: str) -> long {
    let st: [byte; 160] = [0; 160];
    let r = syscall(hostos.nr(262), -100, path, &st[0], 0);
    if (r != 0) { -1 } else {
        let at = if (hostos.is_arm()) { 16 } else { 24 };
        st[at] | (st[at + 1] << 8) | (st[at + 2] << 16) | (st[at + 3] << 24)
    }
};

def web_read_bytes(path: str) -> [byte]? {
    let fd = fs.open_file(path, "r");
    if (fd < 0) { return none; };
    let out: [byte] = [];
    let go = true;
    while (go) {
        let b = fs.read_some(fd, 65536);
        if (len(b) == 0) { go = false; } else { out += b; };
    };
    fs.close_file(fd);
    some(out)
};

// The names in a directory, sorted, or none.  Linux's struct linux_dirent64:
// u64 ino, u64 off, u16 reclen, u8 type, name at 19.
def web_list_dir(path: str) -> [str]? {
    let fd = syscall(hostos.nr(257), -100, path, 65536, 0);
    if (fd < 0) { return none; };
    let buf: [byte; 32768] = [0; 32768];
    let names: [str] = [];
    let go = true;
    while (go) {
        let n = syscall(hostos.nr(217), fd, &buf[0], 32768);
        if (n <= 0) { go = false; } else {
            let off = 0;
            while (off + 19 <= n) {
                let reclen = buf[off + 16] | (buf[off + 17] << 8);
                if (reclen <= 0) { off = n; } else {
                    let e = off + 19;
                    while (e < off + reclen && buf[e] != 0) { e++; };
                    let nm = from_bytes(buf[off + 19:e]);
                    if (nm != "." && nm != "..") { names += nm; };
                    off += reclen;
                };
            };
        };
    };
    syscall(hostos.nr(3), fd);
    some(web_sort(names))
};

def web_sort(xs: [str]) -> [str] {
    let out: [str] = [];
    foreach (x in xs) {
        let j = len(out);
        out += "";
        while (j > 0 && x < out[j - 1]) {
            out[j] = out[j - 1];
            j--;
        };
        out[j] = x;
    };
    out
};

// Every regular file under one [web] files entry, as a path relative to the
// package directory.  Directories are recursive; symlinks are followed.
def web_walk(abs: str, rel: str, out: [str]) -> void {
    if (fs.is_dir(abs)) {
        let names = web_list_dir(abs);
        if (names == none) {
            puts("ycc: [web] files: cannot read the directory '" + abs + "'\n");
            exit(1);
        };
        foreach (n in unwrap(names)) { web_walk(abs + "/" + n, rel + "/" + n, out); };
    } else if (fs.is_file(abs)) {
        out += rel;
    } else {
        puts("ycc: [web] files: '" + abs + "' is not a file or a directory\n");
        exit(1);
    };
};

def web_collect_files(cfg: [str], base: str) -> [str] {
    let out: [str] = [];
    foreach (p in pkg.pk_web_items(web_get(cfg, "files", ""))) {
        let rel = pkg.pk_clean(p);
        web_walk(pkg.pk_join(base, rel), rel, out);
    };
    web_sort(out)
};

def web_put_u32(b: [byte], v: long) -> [byte] {
    let out = b;
    for i in 0..4 { out += (v >> (i * 8)) & 255; };
    out
};

def web_put_u64(b: [byte], v: long) -> [byte] {
    let out = b;
    for i in 0..8 { out += (v >> (i * 8)) & 255; };
    out
};

// Appendix C: "YWFS1\n", count u32, then path_len u32, path, mode u32,
// size u64, bytes.  Sorted by path, so the archive is deterministic.
def web_bundle_bytes(files: [str], base: str) -> [byte] {
    let out: [byte] = bytes("YWFS1\n");
    out = web_put_u32(out, len(files));
    foreach (rel in files) {
        let path = pkg.pk_join(base, rel);
        let data = web_read_bytes(path);
        if (data == none) {
            puts("ycc: [web] files: cannot read '" + path + "'\n");
            exit(1);
        };
        let d = unwrap(data);
        let pb = bytes(rel);
        out = web_put_u32(out, len(pb));
        out += pb;
        let m = web_mode(path);
        if (m < 0) { m = 420; };
        out = web_put_u32(out, m & 4095);
        out = web_put_u64(out, len(d));
        out += d;
    };
    out
};

// RFC 4648 base64 with padding: a single-file page embeds the module and the
// bundle as data: URLs.
def web_b64(b: [byte]) -> str {
    let tab = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let parts: [str] = [];
    let chunk = "";
    let i = 0;
    while (i + 2 < len(b)) {
        let n = b[i] * 65536 + b[i + 1] * 256 + b[i + 2];
        chunk += chr(tab[(n >> 18) & 63]) + chr(tab[(n >> 12) & 63])
            + chr(tab[(n >> 6) & 63]) + chr(tab[n & 63]);
        if (len(chunk) >= 4096) { parts += chunk; chunk = ""; };
        i += 3;
    };
    let r = len(b) - i;
    if (r == 1) {
        let n = b[i] * 65536;
        chunk += chr(tab[(n >> 18) & 63]) + chr(tab[(n >> 12) & 63]) + "==";
    } else if (r == 2) {
        let n = b[i] * 65536 + b[i + 1] * 256;
        chunk += chr(tab[(n >> 18) & 63]) + chr(tab[(n >> 12) & 63])
            + chr(tab[(n >> 6) & 63]) + "=";
    };
    parts += chunk;
    join(parts, "")
};

// The host's ES modules, each with its sibling imports rewritten to the
// import-map names the inline page creates (yweb:NAME).
def web_host_js(asset: str) -> WebJs {
    let names: [str] = [];
    let texts: [str] = [];
    let ls = web_list_dir(asset);
    if (ls != none) {
        foreach (n in unwrap(ls)) {
            if (web_ext(n) == "js") { names += n; };
        };
    };
    names = web_sort(names);
    foreach (n in names) {
        let t = fs.read_file(asset + "/" + n);
        let text = if (t == none) { "" } else { unwrap(t) };
        foreach (dep in names) {
            text = text.replace("\"./" + dep + "\"", "\"yweb:" + dep + "\"");
            text = text.replace("'./" + dep + "'", "'yweb:" + dep + "'");
        };
        texts += text;
    };
    { names: names, texts: texts }
};

// The inline host: a classic script makes one Blob URL per module and adds
// the import map, then a module script imports the entry.  Blob URLs keep one
// instance per module, so the host's state is shared as in the site.
def web_inline_host(asset: str, entry: str) -> str {
    let js = web_host_js(asset);
    let parts: [str] = [];
    parts += "<script>\nconst YWEB_SRC = {";
    for i in 0..len(js.names) {
        parts += web_json_str(js.names[i]) + ":" + web_json_str(web_b64(bytes(js.texts[i]))) + ",";
    };
    parts += "};\n";
    parts += "const YWEB_URLS = {};\n";
    parts += "for (const name in YWEB_SRC) {\n";
    parts += "  const bin = atob(YWEB_SRC[name]);\n";
    parts += "  const bytes = new Uint8Array(bin.length);\n";
    parts += "  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);\n";
    parts += "  YWEB_URLS['yweb:' + name] = URL.createObjectURL(new Blob([bytes], {type: 'text/javascript'}));\n";
    parts += "}\n";
    parts += "const im = document.createElement('script');\n";
    parts += "im.type = 'importmap';\n";
    parts += "im.textContent = JSON.stringify({imports: YWEB_URLS});\n";
    parts += "document.head.appendChild(im);\n";
    parts += "</script>\n";
    parts += "<script type=\"module\">import \"yweb:" + entry + "\";</script>";
    join(parts, "")
};

def web_html_escape(s: str) -> str {
    let t = s;
    t = t.replace("&", "&amp;");
    t = t.replace("<", "&lt;");
    t = t.replace(">", "&gt;");
    t = t.replace("\"", "&quot;");
    t
};

// The four placeholders.  HOST and MODULE go first, so a user value that
// happens to contain a placeholder is never rescanned.
def web_fill(t: str, title: str, cfg: str, host: str, module_url: str) -> str {
    let h = t;
    h = h.replace("{{HOST}}", host);
    h = h.replace("{{MODULE}}", web_html_escape(module_url));
    h = h.replace("{{TITLE}}", title);
    h = h.replace("{{CONFIG}}", cfg);
    h
};

// A single-file page has no sibling page.css: put it in a <style> where the
// template links it.
def web_inline_css(html: str, asset: str) -> str {
    let css = fs.read_file(asset + "/page.css");
    let pos = last_index_of(html, "page.css");
    if (css == none || pos < 0) { return html; };
    let s = pos;
    while (s > 0 && html[s:s + 5] != "<link") { s--; };
    if (html[s:s + 5] != "<link") { return html; };
    let e = index_of(html[pos:], ">");
    if (e < 0) { return html; };
    e += pos;
    html[:s] + "<style>\n" + unwrap(css) + "\n</style>" + html[e + 1:]
};

// The Node launcher's host: yhost.js and the modules it imports, in one
// private directory.  The browser site no longer needs them; they are here
// only so build/web/bin/NAME is self-contained.
def web_copy_node_host(dir: str, asset: str) -> bool {
    if (!fs.make_dirs(dir) && !fs.is_dir(dir)) { return false; };
    let ls = web_list_dir(asset);
    if (ls == none) { return false; };
    let ok = true;
    foreach (n in unwrap(ls)) {
        if (web_ext(n) == "js") {
            let b = web_read_bytes(asset + "/" + n);
            if (b == none) { ok = false; }
            else { ok = ok && fs.write_bytes(dir + "/" + n, unwrap(b), 420); };
        };
    };
    ok = ok && fs.write_file(dir + "/package.json", "{\"type\":\"module\"}\n");
    ok
};

// Remove the files an earlier site writer left beside the page (the host
// modules were siblings before they became one inline module, and page.css
// used to be a sibling too).  A rebuild must not leave them looking live.
def web_clean_site(dir: str) -> void {
    foreach (n in ["abi.js", "audio.js", "bytes.js", "core.js", "gui.js", "memfs.js",
            "page.js", "sched.js", "store.js", "vfs.js", "web.js", "yhost.js",
            "package.json", "page.css", "files.bin"]) {
        fs.remove_file(dir + "/" + n);
    };
};

// --web-page: the site is the page and the module.  The host is inline in
// index.html (one file, no eleven sibling modules) and the page's stylesheet
// is inline too; NAME.wasm and an optional files.bin are the only siblings.
def write_web_page(dir: str, name: str, id: str, module: [byte], cfg: [str], base: str) -> bool {
    let asset = web_asset_dir();
    if (asset == "") {
        puts("ycc: cannot find src/web/yhost.js to write the page\n");
        return false;
    };
    let tmpl = web_template_text(cfg, base);
    if (tmpl == none) { return false; };
    if (!fs.make_dirs(dir) && !fs.is_dir(dir)) {
        puts("ycc: cannot make the page directory '" + dir + "'\n");
        return false;
    };
    web_clean_site(dir);
    let ok = fs.write_bytes(dir + "/" + name + ".wasm", module, 420);
    let files = web_collect_files(cfg, base);
    let bundle_url = "";
    if (files.length > 0) {
        ok = ok && fs.write_bytes(dir + "/files.bin", web_bundle_bytes(files, base), 420);
        bundle_url = "files.bin";
    };
    let module_url = name + ".wasm";
    let entry = web_entry(asset);
    let cfgj = web_config_json(cfg, name, id, module_url, bundle_url, "", "");
    let html = web_fill(unwrap(tmpl), web_html_escape(web_get(cfg, "title", name)), cfgj, entry, module_url);
    let tag = "<script type=\"module\" src=\"" + entry + "\"></script>";
    let host = web_inline_host(asset, entry);
    if (html.contains(tag)) {
        html = html.replace(tag, host);
    } else {
        html = html.replace("</body>", host + "</body>");
    };
    html = web_inline_css(html, asset);
    ok = ok && fs.write_file(dir + "/index.html", html);
    if (!ok) { puts("ycc: writing the page under '" + dir + "' failed\n"); };
    ok
};

// --web-page=html: one self-contained file.  The module and the bundle are
// data: URLs; the host is inline as in the site.
def write_web_html(path: str, name: str, id: str, module: [byte], cfg: [str], base: str) -> bool {
    let asset = web_asset_dir();
    if (asset == "") {
        puts("ycc: cannot find src/web/yhost.js to write the page\n");
        return false;
    };
    let tmpl = web_template_text(cfg, base);
    if (tmpl == none) { return false; };
    let files = web_collect_files(cfg, base);
    let files_b64 = "";
    if (files.length > 0) {
        files_b64 = web_b64(web_bundle_bytes(files, base));
    };
    let module_url = name + ".wasm";
    let module_b64 = web_b64(module);
    let entry = web_entry(asset);
    let cfgj = web_config_json(cfg, name, id, module_url, "", module_b64, files_b64);
    let html = web_fill(unwrap(tmpl), web_html_escape(web_get(cfg, "title", name)), cfgj, entry, module_url);
    let tag = "<script type=\"module\" src=\"" + entry + "\"></script>";
    let host = web_inline_host(asset, entry);
    if (html.contains(tag)) {
        html = html.replace(tag, host);
    } else {
        html = html.replace("</body>", host + "</body>");
    };
    html = web_inline_css(html, asset);
    if (!fs.write_file(path, html)) {
        puts("ycc: writing '" + path + "' failed\n");
        return false;
    };
    true
};

// build/web/bin/NAME: W5's plain Node launcher for the site beside it.
def write_web_launcher(path: str, name: str) -> bool {
    let d = pkg.pk_dir_of(path);
    if (!fs.make_dirs(d) && !fs.is_dir(d)) { return false; };
    let asset = web_asset_dir();
    if (asset == "" || !web_copy_node_host(d + "/host", asset)) { return false; };
    let js = "#!/usr/bin/env -S node --disable-wasm-trap-handler\n" +
        "import(\"node:path\").then(async (path) => {\n" +
        "  const url = await import(\"node:url\");\n" +
        "  const dir = path.dirname(process.argv[1]);\n" +
        "  const host = await import(url.pathToFileURL(path.join(dir, \"host\", \"yhost.js\")).href);\n" +
        "  const wasm = path.join(dir, \"../" + name + "/" + name + ".wasm\");\n" +
        "  const args = process.argv.slice(2);\n" +
        "  const status = host.runNode ? await host.runNode(wasm, args)\n" +
        "    : await host.runFileAsync(wasm, { argv: [\"" + name + "\"].concat(args) });\n" +
        "  process.exitCode = status & 255;\n" +
        "});\n";
    fs.write_file(path, js, 493)
};

def main(cmdline: [str]) -> long {
    if (len(cmdline) > 1 && (cmdline[1] == "build" || cmdline[1] == "vendor")) {
        let ba = build_args(cmdline);
        // a meta block's generator links the std units too (meta_compile_gen)
        if (!ba.std_src) { nativelib.set_meta_pack(self_pack()); };
        if (cmdline[1] == "build" && len(ba.one) == 0) {
            build_project(ba.dir, ba.debug, ba.nowarn, ba.wlevel, ba.allow_exec, ba.std_src, ba.defines, ba.margs);
        } else if (cmdline[1] == "build") {
            build_one(ba.dir, ba.one, ba.debug, ba.nowarn, ba.wlevel, ba.allow_exec, ba.std_src, ba.defines, ba.margs);
        } else {
            pkg.pk_vendor(ba.dir);
        };
        exit(0);
    }
    let args = parse_cli_args(cmdline);
    // A single-file web compile's page config is its --web list; a build
    // merges the manifest in build_project/build_one instead.
    if (target_is_web()) { heap { web_cfg = web_kv_list; }; web_apply_stack(web_cfg); };
    validate_obf(args.debug, args.pack, args.asm_only, args.dump, args.fix,
        args.std_pack);
    if (web_forms_flag) {
        // A test hook (ytest's web-forms): lower one instance of every IR
        // form and print the verdict, so a form with no web lowering is
        // named here rather than in a user's compile.
        puts(wasmlink.wasm_form_probe());
        exit(0);
    };
    nasm.asm_map_enable(len(obf_map_path) > 0);
    if (args.run && (args.asm_only || args.dump || args.fix)) {
        puts("ycc: run needs executable output\n"); exit(1);
    };
    // --pack writes a self-decompressing binary: a stub, a codec and a
    // trailer around the finished image. The flags that write no image, or
    // another format, are refused by name rather than silently ignored.
    if (args.pack) {
        if (args.asm_only) { puts("ycc: --pack does not combine with --emit=asm\n"); exit(1); };
        if (args.dump) { puts("ycc: --pack does not combine with --emit=source\n"); exit(1); };
        if (args.run) { puts("ycc: --pack does not combine with run\n"); exit(1); };
        if (len(args.std_pack) > 0) { puts("ycc: --pack does not combine with --std-pack\n"); exit(1); };
        if (target_is_windows() || target_is_kernel()) {
            puts("ycc: --pack is Linux ELF only (--target=" + res_target + " is not packed)\n");
            exit(1);
        };
    };
    if (target_is_kernel() && args.debug) {
        // -g is ELF64/DWARF64 and the kernel image is an ELF32 Multiboot
        // payload: a line table there is a feature nobody has needed yet,
        // and half of one would be worse than none.
        puts("ycc: -g is not supported with --target=kernel\n");
        exit(1);
    };
    if (target_is_kernel() && args.run) {
        // `ycc run` forks and execs the image it just wrote; an ELF32
        // Multiboot payload is entered by a boot loader in 32-bit protected
        // mode, which execve cannot do.  qemu -kernel is the way to run one.
        puts("ycc: --target=kernel cannot run its image (boot it with 'qemu-system-x86_64 -kernel')\n");
        exit(1);
    };
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
        if (pargs.pack) {
            // A file that starts with the ELF magic is the payload itself, not
            // Y source: that is how `ycc --pack ./ycc` wraps an already-built
            // executable (which for ycc carries the std pack this driver
            // transcodes to plain). A source file cannot start with it.
            let rb = fs.read_file(file);
            if (rb != none && is_elf(unwrap(rb))) {
                let op = out;
                if (len(op) == 0) { op = "a.out"; };
                if (!write_packed(unwrap(rb), pargs.pack_method, op)) {
                    puts("error: writing '" + op + "' failed\n");
                    exit(1);
                };
                exit(0);
            };
        };
        if let some(src) = fs.read_file(file) {

            // src is str? (read_file returns none on missing file); the
            // none case exited above, so unwrap here (loud on none).
            let src2 = src;
            // The build a generator sees (YCC): the command line, the target
            // and the defines, fixed before anything resolves.
            set_meta_build(file, out, defs_resolve([], pargs.defines), pargs.margs, pargs.debug);
            // One meta pass per program: the pass is ON for the program's own
            // resolve and OFF for the generator's (meta_compile_gen), so
            // meta_begin here and nothing else -- resolve_unit's meta_prepare
            // is what runs the generator.
            meta.meta_begin();
            // A meta block's generator is compiled during the resolve below and
            // links the std units as the program does: from this binary's pack
            // (none under --std=source, so from source).
            if (!pargs.std_src) { nativelib.set_meta_pack(self_pack()); 0; }
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
            // or (--std=source, or a ycc with none) compiled from their sources
            // on disk.
            let nrstd = nr.std;
            let pack = "";
            if (!pargs.std_src) { pack = self_pack(); 0; }
            let su = nativelib.std_units(std_order(nrstd), pack);
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
            // --warnings=fix: the linter named the shortenings; write each one's file
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
            print_obf_report();
            t0 = clock_us();
            h0 = heap_used();
            if (!r.ok) {
                print_native_errors(r.errors, nrorigin, true);
                exit(1);
                1
            } else if (pargs.asm_only) {
                let rasm = "";
                if (target_is_aarch64()) {
                    let listing = nasm.a64_listing(r.asm, pargs.debug);
                    if (!listing.ok) { puts("error: assemble: " + listing.error + "\n"); exit(1); };
                    rasm = listing.text;
                } else { rasm = nativelib.link_text(r.asm); };
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
                let ab = assemble_for_target(r.asm, pargs.debug, r.seal);
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
                    write_obf_map();
                    if (pargs.run) {
                        if (target_is_web()) { exit(run_web_module(ab.bytes, pargs.prog)); };
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
                    if (len(out_path) == 0) {
                        if (target_is_web()) { out_path = "a.wasm"; } else { out_path = "a.out"; };
                    };
                    let abbytes = ab.bytes;
                    // 493 = 0755 executable (chmod applied by write_bytes).
                    // --pack wraps the assembled image instead of writing it.
                    // The web kinds are the module itself, a debugging
                    // listing, or D10's page stub.
                    let ok = false;
                    if (pargs.emit == "wat") {
                        let wt = wasmlink.wasm_wat(abbytes);
                        if (len(out) == 0) {
                            puts(wt);
                            ok = true;
                        } else {
                            ok = fs.write_file(out_path, wt);
                        };
                    } else if (pargs.emit == "page") {
                        let dir = out;
                        if (len(dir) == 0) { dir = "."; };
                        let nm = file;
                        let sl = last_index_of(nm, "/");
                        if (sl >= 0) { nm = nm[sl + 1:]; };
                        let dot = last_index_of(nm, ".");
                        if (dot > 0) { nm = nm[0:dot]; };
                        ok = write_web_page(dir, nm, nm, abbytes, web_cfg, ".");
                    } else if (pargs.emit == "html") {
                        let nm = file;
                        let sl = last_index_of(nm, "/");
                        if (sl >= 0) { nm = nm[sl + 1:]; };
                        let dot = last_index_of(nm, ".");
                        if (dot > 0) { nm = nm[0:dot]; };
                        if (len(out) > 0) { out_path = out; } else { out_path = nm + ".html"; };
                        ok = write_web_html(out_path, nm, nm, abbytes, web_cfg, ".");
                    } else if (pargs.pack) {
                        ok = write_packed(from_bytes(abbytes), pargs.pack_method, out_path);
                    } else {
                        ok = fs.write_bytes(out_path, abbytes, if (target_is_web()) { 420 } else { 493 });
                    };
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

// One compilation owns the process arena, including the pass state kept in
// globals. Exit ends that lifetime; no compiler state survives this command.
region { exit(main(argv())); }
