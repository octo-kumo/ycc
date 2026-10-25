// su_corpus.y -- the regression corpora: examples, audit, ycc-units,
// native-examples.
//
// examples: every test/y/examples/*.y, the same binary from both copies and the
//   same behaviour (yc.parity).
// audit: the adversarial edge cases in test/y/audit; parity, except the few
//   both copies must reject (REJECT, each with its reason).
// ycc-units: each test/y/ycc/test_*.y, compiled by the reference and run under
//   a 1.5 GB cap, must exit 0; the skiplist says why the others cannot.
// native-examples: the examples built by ./ycc print what the reference's build
//   prints.
import fs;
import yt;
import yc;

def examples() -> [yt.Case] {
    let cs: [yt.Case] = [];
    foreach (f in yt.files(yc.ROOT + "/test/y/examples", "", ".y")) {
        let name = fs.path_basename(f);
        cs += yt.case_of("examples", name, () => yc.parity_case(name, f, 200));
    };
    cs
};

// Inputs both copies must refuse; anything else in test/y/audit is parity.
let REJECT = [
    "t04_unterminated_str.y",
    "t22_map_missing_key.y",  // a missing dynamic key is a compile-time rejection
    "t50_cons_nonarr.y",      // '::' needs an array on the right (static)
    "t62_chained_idx.y",      // chained index into a non-array stays a static error
    "t28_push.y",             // `x += 4` is a statement, not a value
    "t06_div_by_zero.y",      // 'array / number' is a static error
];

def audit_reject(name: str, f: str) {
    let r = yc.ref_run(f, "", 10);
    let b = yt.tmp("bin");
    let c = yc.compile(yc.CYCC, [], f, b, 60);
    fs.remove_file(b);
    yt.check(name + " (both reject malformed input)", r.code == 1 && c.code != 0,
        "expected both compilers to reject (refec=" + tostring(r.code) + " copycompileec=" + tostring(c.code) + ")");
};

def audit() -> [yt.Case] {
    let cs: [yt.Case] = [];
    foreach (f in yt.files(yc.ROOT + "/test/y/audit", "t", ".y")) {
        let name = fs.path_basename(f);
        let rej = false;
        foreach (x in REJECT) {
            if (x == name) { rej = true; };
        };
        if (rej) {
            cs += yt.case_of("audit", name, () => audit_reject(name, f));
        } else {
            cs += yt.case_of("audit", name, () => yc.parity_case(name, f, 160));
        };
    };
    cs
};

// fixture -> why it cannot pass on the reference compiler
def unit_skip(name: str) -> str {
    if (name == "test_vm.y") {
        "legacy snapshot: drives the old tree-walking vm.y fixture, whose null and scope_*/map_* builtins no longer exist"
    } else if (name == "test_partial.y") {
        "debug fixture: imports partial.y, a truncated WIP snapshot that ends inside parse_postfix"
    } else { "" }
};

def unit(name: str, f: str) {
    let why = unit_skip(name);
    if (why != "") {
        yt.skip(name, why);
        return;
    };
    // the heaviest (test_all_imports.y, every std module) needs ~0.6 GB; a
    // quadratic copy once took it to tens of GB, which the cap turns into a
    // failure rather than a machine pushed into swap
    let b = yt.tmp("bin");
    let r = yc.compile(yc.YREF, [], f, b, 60);
    let o = r;
    if (r.code == 0) {
        let c = yt.cmd([b]);
        c.merge = true;
        c.timeout = 20 * yt.SCALE;
        c.mem_kb = yt.num(yt.env("UNIT_MEM_KB", "1572864"), 1572864);
        o = yt.run(c);
    };
    fs.remove_file(b);
    if (o.code == 0) {
        yt.pass(name);
    } else if (o.timed_out) {
        yt.fail(name, "hung (" + tostring(20 * yt.SCALE) + "s timeout) -- re-examine, do not skiplist");
    } else if (o.out.contains("out of memory")) {
        yt.fail(name, "out of memory under the cap -- a memory regression, do not raise the cap blindly");
    } else {
        let t = o.out;
        yt.fail(name, "exit=" + tostring(o.code) + ": " + yt.clip(if (t.length > 200) { t[t.length - 200:] } else { t }, 200));
    };
};

def ycc_units() -> [yt.Case] {
    let cs: [yt.Case] = [];
    foreach (f in yt.files(yc.ROOT + "/test/y/ycc", "test_", ".y")) {
        let name = fs.path_basename(f);
        cs += yt.case_of("ycc-units", name, () => unit(name, f));
    };
    cs
};

def native_example(name: str, f: str) {
    let b = yt.tmp("bin");
    let r = yc.compile(yc.YCC, [], f, b, 120);
    if (r.code != 0) {
        yt.fail(name, "ycc rejected it: " + yt.first_line(r.out));
        return;
    };
    let built = yc.run_bin(b, [], "", 10);
    fs.remove_file(b);
    let ref = yc.ref_run(f, "", 10);
    if (built.code > 1) {
        yt.fail(name, "ycc-built binary exited " + tostring(built.code) + " (crash?): " + yt.clip(built.out, 200));
    } else {
        yt.check(name, built.out == ref.out, "REF(ec=" + tostring(ref.code) + "): " + yt.clip(ref.out, 200)
            + " / BUILT(ec=" + tostring(built.code) + "): " + yt.clip(built.out, 200));
    };
};

def native_examples() -> [yt.Case] {
    let cs: [yt.Case] = [];
    foreach (f in yt.files(yc.ROOT + "/test/y/examples", "", ".y")) {
        let name = fs.path_basename(f);
        cs += yt.case_of("native-examples", name, () => native_example(name, f));
    };
    cs
};

export { examples, audit, ycc_units, native_examples };
