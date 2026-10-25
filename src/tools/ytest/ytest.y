// ytest.y -- this repo's test runner: every suite, written in Y.
//
//   ytest [-j N] [SUITE...]   run the suites (fast by default), N cases at once
//   ytest list                the suite names
//   ytest check|corpus-diff|bench|bench-run|bench-ir|profile|fuzz|fmt|fmt-check|
//         run-parity|meta-identity|mem     the development loop's tools (ydev.y)
//   ytest gcov [FILE...]      gcov coverage of the C seed and runtime (cov.y)
//   ytest deadcode [-v] F.s   unreachable instructions in a listing (deadcode.y)
//   ytest os-build|os-run|os-session   Y-OS: build, boot, script a session (yos.y)
//   ytest math-pairs [N] | math-repeats | math-thresholds | math-coverage | math-unroll
//                             the std/math.y audits (mpairs.y, mstatic.y)
//   ytest pe-gate|pe-packinv|pe-fixtures|cycc-win|w-sysno   the Windows gates (pe.y; runs go to a Windows machine, .pe-vm.conf)
//   ytest coverage-list       every diagnostic site and whether a test expects it
//   ytest lsp-e2e             the language server as a process (lsp_e2e.y)
//   ytest check-refs|check-names   the language server's static checks (su_lsp.y)
//   ytest pty-test PROG       test/std/term_test.y on a real pty (pty.y)
//   ytest pack-stats PACK     a std pack's bytes by unit and field (pack.y)
//
// A suite is a module (su_*.y) whose `cases` lists closures; yt.y runs each in
// a child of its own, so the cases of every suite share one pool of workers
// and a crash is one failed case. The output is printed suite by suite, in
// case order, as soon as it is complete. Knobs from the environment: CYCC,
// YREF, YCC (the compilers), YQUIET=1 (failures only), YMEM_KB,
// YTIMEOUT_SCALE, YPORT_SELF=0 (leave src/y/ycc.y out of the port gate).
import fs;
import yt;
import yc;
import cov;
import su_native;
import su_aarch64;
import su_port;
import su_corpus;
import su_inline;
import su_ycc;
import su_fixpoint;
import su_debug;
import su_link;
import su_gc;
import su_lifetime;
import su_eof;
import su_treeshake;
import su_std;
import su_net;
import su_gui;
import su_pkg;
import su_pack;
import su_kernel;
import yos;
import su_lsp;
import lsp_e2e;
import mpairs;
import mstatic;
import mgen;
import gexp;
import glog;
import gsin;
import gpow;
import mtable;
import maudit;
import mfit;
import ytools;
import su_math;
import su_coverage;
import su_obf;
import su_web;
import su_webb;
import pe;
import ydev;
import pack;
import packbench;
import deadcode;
import pty;

// The default run is the fast suites.
// The slow ones -- the compiler-against-reference sweeps, the self-compile, the kernel and
// Y-OS under qemu, the language server's scanner, the collector's thread stress, the pack and
// package builds -- run with `ytest slow` (or `make test-slow`); `ytest all` runs both.
let FAST = ["native", "lifetime", "native-examples", "examples", "audit", "ycc-units", "loops", "ycc", "debug", "stdin-eof", "net", "gui", "coverage", "math", "web-smoke"];
let SLOW = ["port", "pe-port", "comprehensive", "fixpoint", "link", "gc", "treeshake", "std-suites", "pkg", "pack", "kernel", "os", "lsp", "obf", "aarch64", "web"];
let ALL = FAST + SLOW;
// By-hand suites (like `make pe-test`): listed and runnable by name, never in `all`.
let BY_HAND = ["web-browser"];

// Suites that drive the built ./ycc; skipped without it.
def needs_ycc(name: str) -> bool {
    name == "native" || name == "aarch64" || name == "native-examples" || name == "ycc" || name == "fixpoint" || name == "debug" || name == "link" || name == "pkg" || name == "pack" || name == "kernel" || name == "os" || name == "math" || name == "obf" || name == "web-smoke" || name == "web" || name == "web-browser"
};

def suite_cases(name: str) -> [yt.Case] {
    if (name == "port") { return su_port.port(); };
    if (name == "pe-port") { return su_port.pe_port(); };
    if (name == "native") { return su_native.cases(); };
    if (name == "aarch64") { return su_aarch64.cases(); };
    if (name == "native-examples") { return su_corpus.native_examples(); };
    if (name == "examples") { return su_corpus.examples(); };
    if (name == "audit") { return su_corpus.audit(); };
    if (name == "ycc-units") { return su_corpus.ycc_units(); };
    if (name == "ycc") { return su_ycc.cases(); };
    if (name == "fixpoint") { return su_fixpoint.cases(); };
    if (name == "debug") { return su_debug.cases(); };
    if (name == "link") { return su_link.cases(); };
    if (name == "gc") { return su_gc.cases(); };
    if (name == "lifetime") { return su_lifetime.cases(); };
    if (name == "stdin-eof") { return su_eof.cases(); };
    if (name == "treeshake") { return su_treeshake.cases(); };
    if (name == "std-suites") { return su_std.cases(); };
    if (name == "net") { return su_net.cases(); };
    if (name == "gui") { return su_gui.cases(); };
    if (name == "pkg") { return su_pkg.cases(); };
    if (name == "pack") { return su_pack.cases(); };
    if (name == "kernel") { return su_kernel.cases(); };
    if (name == "os") { return yos.cases(); };
    if (name == "lsp") { return su_lsp.cases(); };
    if (name == "math") { return su_math.cases(); };
    if (name == "obf") { return su_obf.cases(); };
    if (name == "web-smoke") { return su_web.cases(); };
    if (name == "web") { return su_web.web_cases(); };
    if (name == "web-browser") { return su_webb.cases(); };
    if (name == "coverage") { return su_coverage.cases(); };
    if (name == "loops") { return su_inline.loops(); };
    if (name == "comprehensive") { return su_inline.comprehensive(); };
    []
};

def known(name: str) -> bool {
    foreach (s in ALL) {
        if (s == name) { return true; };
    };
    foreach (s in BY_HAND) {
        if (s == name) { return true; };
    };
    false
};

def banner(s: str) {
    print("");
    print("################################################################");
    print("# suite: " + s);
    print("################################################################");
};

// The run's state, for on_done: the cases, which are done, and the print cursor.
let CS: [yt.Case] = [];
let DONE: [yt.Done] = [];
let FIN: [bool] = [];
let SHOWN = 0;
let FAILED: [str] = [];
let T0: [long] = [];

def fmt_secs(us: long) -> str {
    tostring(us / 1000000) + "." + tostring(us / 100000 % 10) + "s"
};

def on_done(k: long, d: yt.Done) {
    FIN[k] = true;
    DONE[k] = d;
    while (SHOWN < CS.length && FIN[SHOWN]) {
        let s = CS[SHOWN].suite;
        if (SHOWN == 0 || CS[SHOWN - 1].suite != s) {
            banner(s);
            T0 += clock_us();
        };
        if (DONE[SHOWN].text != "") { puts(DONE[SHOWN].text); };
        if (SHOWN + 1 == CS.length || CS[SHOWN + 1].suite != s) {
            summary(s, SHOWN);
        };
        SHOWN += 1;
    };
};

// The suite ending at case `last`: its totals.
def summary(s: str, last: long) -> void {
    let p = 0;
    let f = 0;
    let k = 0;
    let i = last;
    while (i >= 0 && CS[i].suite == s) {
        p += DONE[i].npass;
        f += DONE[i].nfail;
        k += DONE[i].nskip;
        i -= 1;
    };
    if (f > 0) { FAILED += s; };
    print("");
    print("═══════════════════════════════════════════");
    print("  [" + s + "] " + yt.paint("0;32", tostring(p) + " passed") + ", " + yt.paint("0;31", tostring(f) + " failed")
        + " / " + tostring(p + f) + " total (plus " + tostring(k) + " skipped)");
    print("═══════════════════════════════════════════");
};

// Where the time went: suite totals (the sum of their cases' wall time: with -j N the run is
// shorter), then each suite's cases and its slowest checks, indented as a tree. The whole
// list, every check, goes to _check/ytest-times.txt.
def timing_report(t0: long) {
    let total = clock_us() - t0;
    let seen: [str] = [];
    foreach (c in CS) { if (!(c.suite in seen)) { seen += c.suite; }; };
    print("");
    print("time (wall " + fmt_secs(total) + ", cases summed " + fmt_secs(sum_us(-1, "")) + "):");
    foreach (s in seen) {
        print("  " + s.pad_right(18) + fmt_secs(sum_us(0, s)));
        // the cases of this suite, slowest first (top 5)
        let idx: [long] = [];
        for i in 0..CS.length { if (CS[i].suite == s) { idx += i; }; };
        let shown = 0;
        while (shown < 5 && shown < idx.length) {
            let best = -1;
            foreach (i in idx) {
                if (yt.CASE_US[i] >= 0 && (best < 0 || yt.CASE_US[i] > yt.CASE_US[best])) { best = i; };
            };
            if (best < 0) { break; };
            print("    " + fmt_secs(yt.CASE_US[best]).pad_right(9) + CS[best].name);
            // its slowest checks
            let lines = yt.lines(yt.CASE_T[best]);
            let used: [long] = [];
            let n = 0;
            while (n < 3) {
                let bi = -1;
                let bv = 0;
                for j in 0..lines.length {
                    let sp = lines[j].index_of(" ");
                    if (sp > 0 && !(j in used)) {
                        let v = yt.num(lines[j][0:sp], 0);
                        if (v > bv) { bv = v; bi = j; };
                    };
                };
                if (bi < 0 || bv < 200000) { break; };
                used += bi;
                print("        " + fmt_secs(bv).pad_right(9) + yt.clip(lines[bi][lines[bi].index_of(" ") + 1:], 100));
                n += 1;
            };
            // mark as shown by making it negative
            yt.CASE_US[best] = -1 - yt.CASE_US[best];
            shown += 1;
        };
        foreach (i in idx) { if (yt.CASE_US[i] < 0) { yt.CASE_US[i] = -1 - yt.CASE_US[i]; }; };
    };
    // every case and every check, for grepping
    let out: [str] = [];
    for i in 0..CS.length {
        out += fmt_secs(yt.CASE_US[i]) + "\t" + CS[i].suite + " / " + CS[i].name;
        foreach (l in yt.lines(yt.CASE_T[i])) {
            let sp = l.index_of(" ");
            if (sp > 0) { out += "\t" + fmt_secs(yt.num(l[0:sp], 0)) + "\t" + l[sp + 1:]; };
        };
    };
    fs.make_dirs(yc.ROOT + "/_check");
    fs.write_file(yc.ROOT + "/_check/ytest-times.txt", join(out, "\n") + "\n");
    print("  (every case and check: _check/ytest-times.txt)");
};

def sum_us(mode: long, s: str) -> long {
    let t = 0;
    for i in 0..CS.length {
        if (mode < 0 || CS[i].suite == s) { t += yt.CASE_US[i]; };
    };
    t
};

def run_suites(names: [str], jobs: long) -> long {
    foreach (n in names) {
        if (!known(n)) {
            eputs("error: unknown suite '" + n + "' (pick from: " + join(ALL, " ") + ")");
            return 2;
        };
    };
    if (!fs.is_file(yc.CYCC)) {
        eputs("error: " + yc.CYCC + " not found -- run 'make' first");
        return 1;
    };
    if (!fs.is_file(yc.YREF)) {
        eputs("error: " + yc.YREF + " not found -- the reference binary is the port's ground truth (see refs/)");
        return 1;
    };
    let skipped: [str] = [];
    foreach (n in names) {
        if (needs_ycc(n) && !yc.have_ycc()) {
            skipped += n;
        } else {
            CS += suite_cases(n);
        };
    };
    foreach (c in CS) {
        DONE += { npass: 0, nfail: 0, nskip: 0, text: "" };
        FIN += false;
    };
    let t0 = clock_us();
    yt.run_cases(CS, jobs, on_done);
    foreach (n in skipped) { banner(n + " (SKIPPED: run 'make ycc' first)"); };
    print("");
    print("################################################################");
    timing_report(t0);
    if (FAILED.length == 0) {
        print("# ALL SUITES PASSED (" + join(names, " ") + ") in " + fmt_secs(clock_us() - t0));
    } else {
        print("# SOME SUITES FAILED: " + join(FAILED, " ") + " (see above)");
    };
    print("################################################################");
    if (FAILED.length == 0) { 0 } else { 1 }
};

let GENS = ["exp", "log", "sin", "pow"];

def gen_one(name: str, stage: str) -> str {
    if (name == "exp") { gexp.gen(stage) } else if (name == "log") { glog.gen(stage) } else if (name == "sin") { gsin.gen(stage) } else if (name == "pow") { gpow.gen(stage) } else { mgen.die("math-gen: no generator " + name); "" }
};

// `ytest math-gen` checks that math.s holds what every generator writes;
// `ytest math-gen NAME [STAGE]` prints one routine (or one intermediate).
def math_gen(av: [str]) -> long {
    if (av.length > 0) {
        puts(gen_one(av[0], if (av.length > 1) { av[1] } else { "full" }));
        return 0;
    };
    let maths = yt.read(yc.ROOT + "/src/y/arch/math.s");
    let bad: [str] = [];
    foreach (n in GENS) {
        if (!maths.contains(gen_one(n, "full").trim())) { bad += n; };
    };
    if (bad.length == 0) {
        print("  math.s matches the generators (" + join(GENS, ", ") + ")");
        0
    } else {
        print("math.s has drifted from the generator: " + join(bad, ", ") + "\n  regenerate (ytest math-gen NAME) and write it over the block");
        1
    }
};

let USAGE = "usage: ytest [-j N] [SUITE...]     run the suites (fast by default; all/slow selects more)
       ytest list                     the suite names
suites' tools:  deadcode pack-stats pack-bench pty-test check-refs check-names lsp-e2e coverage-list
                os-build os-run os-session
math:           math-gen math-fit math-table math-exact math-float math-edges math-pairs math-repeats math-thresholds math-coverage math-unroll
windows:        pe-gate pe-packinv pe-fixtures cycc-win w-sysno
browser:        web-browser (make web-browser)
development:    check corpus-diff bench bench-run bench-ir profile fuzz fmt fmt-check
                run-parity meta-identity mem gcov oom install-vscode
environment:    CYCC YREF YCC (the compilers), YJOBS, YQUIET, YMEM_KB, YTIMEOUT_SCALE, NO_COLOR
";

def cpus() -> long {
    let n = 0;
    foreach (l in yt.lines(yt.read("/proc/cpuinfo"))) { if (l.starts_with("processor")) { n += 1; }; };
    if (n < 1) { 1 } else if (n > 16) { 16 } else { n }
};

def main(av: [str]) -> long {
    yt.init();
    yc.init();
    // cases are separate processes: run as many at once as there are processors (YJOBS, -j N)
    let jobs = yt.num(yt.env("YJOBS", tostring(cpus())), 1);
    let names: [str] = [];
    let i = 1;
    while (i < av.length) {
        let a = av[i];
        if (a == "-j" && i + 1 < av.length) {
            jobs = yt.num(av[i + 1], 1);
            i += 1;
        } else if (a.starts_with("-j")) {
            jobs = yt.num(a[2:], 1);
        } else if (a == "slow") {
            names += SLOW;
        } else if (a == "all") {
            names += ALL;
        } else if (a == "list") {
            print(join(ALL + BY_HAND, "\n"));
            return 0;
        } else if (a == "help" || a == "-h" || a == "--help") {
            puts(USAGE);
            return 0;
        } else if (a == "deadcode") {
            return deadcode.main(av[i + 1:]);
        } else if (a == "os-build") {
            return yos.main_build(av[i + 1:]);
        } else if (a == "os-run") {
            return yos.main_run(av[i + 1:]);
        } else if (a == "os-session") {
            return yos.main_session(av[i + 1:]);
        } else if (a == "math-exact") {
            return maudit.main_exact(av[i + 1:]);
        } else if (a == "math-float") {
            return maudit.main_float(av[i + 1:]);
        } else if (a == "math-edges") {
            return maudit.main_edges(av[i + 1:]);
        } else if (a == "oom") {
            return ytools.main_oom(av[i + 1:]);
        } else if (a == "install-vscode") {
            return ytools.main_install(av[i + 1:]);
        } else if (a == "math-fit") {
            return mfit.main(av[i + 1:]);
        } else if (a == "math-table") {
            return mtable.main(av[i + 1:]);
        } else if (a == "math-gen") {
            return math_gen(av[i + 1:]);
        } else if (a.starts_with("math-") && a != "math-pairs") {
            return mstatic.main(a[5:], av[i + 1:]);
        } else if (a == "check") {
            return ydev.main_check(av[i + 1:]);
        } else if (a == "corpus-diff") {
            return ydev.main_corpus_diff(av[i + 1:]);
        } else if (a == "bench") {
            return ydev.main_bench(av[i + 1:]);
        } else if (a == "bench-run") {
            return ydev.main_bench_run(av[i + 1:]);
        } else if (a == "bench-ir") {
            return ydev.main_bench_ir(av[i + 1:]);
        } else if (a == "profile") {
            return ydev.main_profile(av[i + 1:]);
        } else if (a == "fuzz") {
            return ydev.main_fuzz(av[i + 1:]);
        } else if (a == "fmt") {
            return ydev.main_fmt(av[i + 1:]);
        } else if (a == "fmt-check") {
            return ydev.main_fmt_check(av[i + 1:]);
        } else if (a == "run-parity") {
            return ydev.main_run_parity(av[i + 1:]);
        } else if (a == "meta-identity") {
            return ydev.main_meta_identity(av[i + 1:]);
        } else if (a == "mem") {
            return ydev.main_mem(av[i + 1:]);
        } else if (a == "pe-gate") {
            return pe.gate(av[i + 1:]);
        } else if (a == "pe-packinv") {
            return pe.packinv(av[i + 1:]);
        } else if (a == "pe-fixtures") {
            return pe.fixtures(av[i + 1:]);
        } else if (a == "cycc-win") {
            return pe.cycc_win(av[i + 1:]);
        } else if (a == "w-sysno") {
            return pe.w_sysno(av[i + 1:]);
        } else if (a == "coverage-list") {
            return su_coverage.main_list(av[i + 1:]);
        } else if (a == "math-pairs") {
            return mpairs.main(av[i + 1:]);
        } else if (a == "lsp-e2e") {
            return lsp_e2e.main(av[i + 1:]);
        } else if (a == "check-refs") {
            return su_lsp.main_refs(av[i + 1:]);
        } else if (a == "check-names") {
            return su_lsp.main_names(av[i + 1:]);
        } else if (a == "pty-test") {
            return pty.main(av[i + 1:]);
        } else if (a == "pack-stats") {
            return pack.main(av[i + 1:]);
        } else if (a == "pack-bench") {
            return packbench.main(av[i + 1:]);
        } else if (a == "gcov") {
            return cov.coverage(av[i + 1:]);
        } else {
            names += a;
        };
        i += 1;
    };
    if (names.length == 0) { names = FAST; };
    let rc = run_suites(names, jobs);
    yt.cleanup();
    rc
};

exit(main(argv()));
