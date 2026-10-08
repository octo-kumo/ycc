// su_math.y -- std/math.y against the checked-in reference table, in ulps,
// and the audits that keep the module's own structure honest.
//
// test/math/ulp_table.txt holds one case per line -- the function, its
// argument(s) and the correctly-rounded answer, as IEEE-754 bit patterns (the
// platform libm's) -- and test/math/ulp_check.y prints every case more than one
// ulp off. "Within 1 ulp" is the whole promise. Both compilers run it and must
// say the same, and every name in the table must be one the harness dispatches
// on, or a function nobody tested would pass silently.
//
// Then: the four assembly kernels in arch/math.s are what their generators
// write from math.y's own constants (`ytest math-gen`); the eight unrolled
// kernels are what the generator writes (mstatic.y math-unroll) and agree with poly_split to the bit (t328, both compilers); no
// new repeated computation (math-repeats); every seam a comparison branches on
// has a table case beside it (math-thresholds); every def is reachable from a
// checked root (math-coverage); each detector finds a planted defect; and
// hypot and atan2 are within 1 ulp of an independent reference over YPAIRS
// pairs (mpairs.y, under the built compiler).
import fs;
import yt;
import yc;
import mstatic;
import mpairs;

def ulp_run(label: str, cc: str) -> str {
    let b = yt.tmp("ulp");
    let c = yc.compile(cc, [], yc.ROOT + "/test/math/ulp_check.y", b, 600);
    if (c.code != 0) {
        yt.fail("the " + label + " does not compile test/math/ulp_check.y", yt.clip(c.out, 300));
        return "";
    };
    let r = yc.run_bin(b, [yc.ROOT + "/test/math/ulp_table.txt"], "", 300);
    fs.remove_file(b);
    let ls = yt.lines(r.out);
    let last = if (ls.length > 0) { ls[ls.length - 1] } else { "" };
    if (r.code == 0) {
        yt.pass("the " + label + ": " + last);
    } else {
        let over: [str] = [];
        foreach (l in ls) {
            if (l.starts_with("OVER") && over.length < 20) { over += l; };
        };
        yt.fail("the " + label + ": " + last, join(over, "\n"));
    };
    r.out
};

def ulp() {
    let a = ulp_run("C copy", yc.CYCC);
    let b = ulp_run("built compiler", yc.YCC);
    if (a != "" && b != "" && a != b) { yt.fail("the two compilers disagree about the table", yt.first_diff(a, b)); };
    // a function in the table the harness cannot dispatch would pass silently
    let prog = yt.read(yc.ROOT + "/test/math/ulp_check.y");
    let missing: [str] = [];
    foreach (l in yt.lines(yt.read(yc.ROOT + "/test/math/ulp_table.txt"))) {
        let w = yt.words(l);
        if (w.length > 0 && !l.starts_with("#") && !prog.contains("\"" + w[0] + "\"") && !(w[0] in missing)) { missing += w[0]; };
    };
    if (missing.length > 0) { yt.fail("the harness does not dispatch: " + join(missing, " "), ""); };
};

def t328(cc: str) {
    let name = fs.path_basename(cc);
    let b = yt.tmp("t328");
    let c = yc.compile(cc, [], yc.ROOT + "/test/y/native/t328_split_unrolled.y", b, 600);
    let o = if (c.code == 0) { yc.run_bin(b, [], "", 300).out } else { c.out };
    yt.check(name + ": the 8 unrolled kernels match poly_split to the bit",
        c.code == 0 && o == yt.read(yc.ROOT + "/test/y/native/t328_split_unrolled.expected"), "t328_split_unrolled: " + yt.clip(o, 300));
};


def static_(pass_msg: str, fail_msg: str, f: ([bool]) -> str) {
    let ok = [false];
    let out = f(ok);
    if (ok[0]) {
        foreach (l in yt.lines(out)) { yt.say("  " + l); };
        yt.pass(pass_msg);
    } else {
        yt.fail(fail_msg, "");
        foreach (l in yt.lines(out)) { yt.say("  " + l); };
    };
};

def cases() -> [yt.Case] {
    let s = "math";
    let m = mstatic.math_y();
    [yt.case_of(s, "ulp", ulp),
     yt.case_of(s, "unroll", () => {
         let ok = [false];
         let out = mstatic.unroll_report(m, ok);
         if (!ok[0]) { yt.fail("the generated kernels have drifted from the generator", out); };
     }),
     yt.case_of(s, "math-gen", () => {
         let c = yt.cmd([yt.self_exe(), "math-gen"]);
         c.merge = true;
         let r = yt.run(c);
         yt.check("y_exp, y_log, y_sin/y_cos and y_pow in math.s are what the generators write", r.code == 0,
             yt.clip(r.out, 400));
     }),
     yt.case_of(s, "t328 cycc", () => t328(yc.CYCC)),
     yt.case_of(s, "t328 ycc", () => t328(yc.YCC)),
     yt.case_of(s, "repeats", () => static_("no new repeated computation in src/y/std/math.y",
         "a new repeated computation in src/y/std/math.y (above); it is a defect, or it needs a reason in KNOWN_REPEATS",
         (ok: [bool]) => mstatic.repeats_report(m, ok))),
     yt.case_of(s, "pairs", () => {
         let c = yt.cmd([yt.self_exe(), "math-pairs", yt.env("YPAIRS", "4000")]);
         c.merge = true;
         c.timeout = 1200;
         let r = yt.run(c);
         foreach (l in yt.lines(r.out)) { yt.say("  " + l); };
         yt.check("hypot and atan2 within 1 ulp over independently drawn decade pairs", r.code == 0,
             "hypot or atan2 over 1 ulp on a pair (above)");
     }),
     yt.case_of(s, "thresholds", () => static_("every seam a comparison in std/math.y branches on has a case beside it",
         "a threshold in std/math.y has no case within 1e6 ulps of it", (ok: [bool]) => mstatic.thresholds_report(m, ok))),
     yt.case_of(s, "thresholds selftest", () => static_("the seam extractor finds a planted comparison",
         "the seam extractor stopped finding a planted comparison", mstatic.thresholds_selftest)),
     yt.case_of(s, "coverage", () => static_("every def in std/math.y is reachable from a checked root",
         "a def in std/math.y is reachable from nothing checked", (ok: [bool]) => mstatic.coverage_report(m, ok))),
     yt.case_of(s, "repeats selftest", () => static_("each repeated-computation detector finds its plant",
         "a repeated-computation detector stopped finding its plant", mstatic.repeats_selftest))]
};

export { cases };
