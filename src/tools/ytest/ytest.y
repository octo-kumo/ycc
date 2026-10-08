// ytest.y -- this repo's test runner: every suite, written in Y.
//
//   ytest [-j N] [SUITE...]   run the suites (all by default), N cases at once
//   ytest list                the suite names
//   ytest coverage [FILE...]  gcov line coverage of src/c over a corpus (cov.y)
//   ytest deadcode [-v] F.s   unreachable instructions in a listing (deadcode.y)
//   ytest os-build|os-run|os-session   Y-OS: build, boot, script a session (yos.y)
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
import su_port;
import su_corpus;
import su_inline;
import su_ycc;
import su_fixpoint;
import su_debug;
import su_link;
import su_gc;
import su_eof;
import su_treeshake;
import su_std;
import su_net;
import su_pkg;
import su_kernel;
import yos;
import pack;
import deadcode;
import pty;

let ALL = ["port", "pe-port", "native", "native-examples", "examples", "audit", "ycc-units", "loops", "comprehensive", "ycc", "fixpoint", "debug", "link", "gc", "stdin-eof", "treeshake", "std-suites", "net", "pkg", "kernel", "os"];

// Suites that drive the built ./ycc; skipped without it.
def needs_ycc(name: str) -> bool {
    name == "native" || name == "native-examples" || name == "ycc" || name == "fixpoint" || name == "debug" || name == "link" || name == "pkg" || name == "kernel" || name == "os"
};

def suite_cases(name: str) -> [yt.Case] {
    if (name == "port") { return su_port.port(); };
    if (name == "pe-port") { return su_port.pe_port(); };
    if (name == "native") { return su_native.cases(); };
    if (name == "native-examples") { return su_corpus.native_examples(); };
    if (name == "examples") { return su_corpus.examples(); };
    if (name == "audit") { return su_corpus.audit(); };
    if (name == "ycc-units") { return su_corpus.ycc_units(); };
    if (name == "ycc") { return su_ycc.cases(); };
    if (name == "fixpoint") { return su_fixpoint.cases(); };
    if (name == "debug") { return su_debug.cases(); };
    if (name == "link") { return su_link.cases(); };
    if (name == "gc") { return su_gc.cases(); };
    if (name == "stdin-eof") { return su_eof.cases(); };
    if (name == "treeshake") { return su_treeshake.cases(); };
    if (name == "std-suites") { return su_std.cases(); };
    if (name == "net") { return su_net.cases(); };
    if (name == "pkg") { return su_pkg.cases(); };
    if (name == "kernel") { return su_kernel.cases(); };
    if (name == "os") { return yos.cases(); };
    if (name == "loops") { return su_inline.loops(); };
    if (name == "comprehensive") { return su_inline.comprehensive(); };
    []
};

def known(name: str) -> bool {
    foreach (s in ALL) {
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
    if (FAILED.length == 0) {
        print("# ALL SUITES PASSED (" + join(names, " ") + ") in " + fmt_secs(clock_us() - t0));
    } else {
        print("# SOME SUITES FAILED: " + join(FAILED, " ") + " (see above)");
    };
    print("################################################################");
    if (FAILED.length == 0) { 0 } else { 1 }
};

def main(av: [str]) -> long {
    yt.init();
    yc.init();
    let jobs = yt.num(yt.env("YJOBS", "1"), 1);
    let names: [str] = [];
    let i = 1;
    while (i < av.length) {
        let a = av[i];
        if (a == "-j" && i + 1 < av.length) {
            jobs = yt.num(av[i + 1], 1);
            i += 1;
        } else if (a.starts_with("-j")) {
            jobs = yt.num(a[2:], 1);
        } else if (a == "list") {
            print(join(ALL, "\n"));
            return 0;
        } else if (a == "deadcode") {
            return deadcode.main(av[i + 1:]);
        } else if (a == "os-build") {
            return yos.main_build(av[i + 1:]);
        } else if (a == "os-run") {
            return yos.main_run(av[i + 1:]);
        } else if (a == "os-session") {
            return yos.main_session(av[i + 1:]);
        } else if (a == "pty-test") {
            return pty.main(av[i + 1:]);
        } else if (a == "pack-stats") {
            return pack.main(av[i + 1:]);
        } else if (a == "coverage") {
            return cov.coverage(av[i + 1:]);
        } else {
            names += a;
        };
        i += 1;
    };
    if (names.length == 0) { names = ALL; };
    let rc = run_suites(names, jobs);
    yt.cleanup();
    rc
};

exit(main(argv()));
