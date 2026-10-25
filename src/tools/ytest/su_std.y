// su_std.y -- the self-test suites of the std units that have one (test/std):
//
//   fx_test, fb_test     full-output golden (byte-deterministic: two runs agree)
//   time_test, args_test exit status + the PASS marker (they print measured
//                        clock values, so a golden would be a coin flip)
//   term_test            on a real pty (pty.y): TCGETS and TIOCGWINSZ answer
//                        ENOTTY on a pipe, so headless it declines to run
//
// Both compilers build every suite without a diagnostic (a suite that trains
// the reader to ignore warnings is how the no-warning rule erodes), and each
// build passes.
import fs;
import yt;
import yc;
import pty;
import fzdata;

let STD = "";

// Measured from a real run of each, not assumed: a marker guessed wrong is a
// gate that never fires.
def marker(s: str) -> str {
    if (s == "args_test") { "all 61 checks passed" } else if (s == "term_test") { "term_test: OK" } else { "RESULT: PASS" }
};

// The binary, or "" after reporting why there is none.
def build(suite: str, cc: str) -> str {
    let bin = yt.tmp(suite);
    let c = yt.cmd([cc, "-o", bin, STD + "/" + suite + ".y"]);
    c.merge = true;
    c.timeout = 600 * yt.SCALE;
    let r = yt.run(c);
    if (r.code != 0 || !fs.is_file(bin)) {
        yt.fail(suite + ": " + fs.path_basename(cc) + " did not build it", yt.clip(r.out, 300));
        return "";
    };
    if (r.out != "") {
        yt.fail(suite + ": " + fs.path_basename(cc) + " compiled it with a diagnostic", yt.clip(r.out, 300));
        return "";
    };
    bin
};

def tail(s: str, n: long) -> str { yt.clip(if (s.length > n) { s[s.length - n:] } else { s }, n) };

def run_suite(suite: str, cc: str) -> bool {
    let label = fs.path_basename(cc);
    let bin = build(suite, cc);
    if (bin == "") { return false; };
    let c = yt.cmd([bin]);
    c.merge = true;
    c.timeout = 300;
    let o = yt.run(c);
    if (o.code != 0) {
        yt.fail(suite + ": " + label + " exited " + tostring(o.code), tail(o.out, 300));
        return false;
    };
    if (!o.out.contains(marker(suite))) {
        yt.fail(suite + ": " + label + " printed no PASS marker", tail(o.out, 300));
        return false;
    };
    if (suite == "fx_test" || suite == "fb_test") {
        let want = yt.read(STD + "/golden/" + suite + ".out");
        if (o.out != want) {
            yt.fail(suite + ": " + label + " output differs from the golden", "");
            return false;
        };
    };
    true
};

def headless(suite: str) {
    let a = run_suite(suite, yc.CYCC);
    let b = run_suite(suite, yc.YREF);
    if (a && b) { yt.pass(suite + ": builds clean and passes under both compilers"); };
};

// --skip-crash drops the two SIGKILL-watchdog cases because they are FLAKY: a
// watchdog child racing its parent's death failed one run in six, and a gate
// that fails one run in six teaches its reader to re-run it. Run
// `ytest pty-test` by hand without the flag to exercise the watchdog.
def term() {
    let ok = true;
    foreach (cc in [yc.CYCC, yc.YREF]) {
        let bin = build("term_test", cc);
        if (bin == "") {
            ok = false;
        } else {
            let c = yt.cmd([yt.self_exe(), "pty-test", "--skip-crash", bin]);
            c.merge = true;
            c.timeout = 300;
            let r = yt.run(c);
            if (r.code != 0) {
                yt.fail("term_test: " + fs.path_basename(cc) + " on a pty exited " + tostring(r.code), tail(r.out, 400));
                ok = false;
            } else if (!r.out.contains(marker("term_test"))) {
                yt.fail("term_test: " + fs.path_basename(cc) + " on a pty printed no PASS marker", tail(r.out, 400));
                ok = false;
            };
        };
    };
    if (ok) { yt.pass("term_test: builds clean and passes on a real pty, both compilers"); };
};

// 500 mutated inputs per decoder that parses outside bytes (ytest fuzz --data
// runs the long version): a trap, a timeout or the cap is a regression.
def data_fuzz() {
    let work = yt.tmp_dir("fzdata-suite");
    let bin = fzdata.build(work);
    if (bin == "") { yt.fail("data fuzz: cannot build test/fuzz/data.y", ""); return; };
    foreach (t in fzdata.TARGETS) {
        let ok = fzdata.run_target(bin, work, t, 500, 20261009, yc.abs_path(yt.env("FUZZ_OUT", "_check/fuzz")));
        if (ok) { yt.pass("data fuzz " + t + ": 500 mutated inputs, no trap"); } else { yt.fail("data fuzz " + t + ": a mutated input stopped the decoder", "see _check/fuzz"); };
    };
    fs.remove_all(work);
};

def cases() -> [yt.Case] {
    STD = yc.ROOT + "/test/std";
    let cs: [yt.Case] = [];
    foreach (s in ["fx_test", "fb_test", "time_test", "args_test"]) {
        // time_test holds a sustained 30 and 60 fps to within 3% and args_test
        // checks a pacer's lag against the clock: both fail on a busy machine
        // (the gc suite's thread storms are enough), so they run alone.
        if (s == "time_test" || s == "args_test") {
            cs += yt.case_excl("std-suites", s, () => headless(s));
        } else {
            cs += yt.case_of("std-suites", s, () => headless(s));
        };
    };
    cs += yt.case_of("std-suites", "term_test", term);
    cs += yt.case_of("std-suites", "data fuzz", data_fuzz);
    cs
};

export { cases };
