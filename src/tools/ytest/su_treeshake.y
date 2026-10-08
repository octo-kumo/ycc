// su_treeshake.y -- what a program does not use must not be in its binary.
//
// A RATCHET over test/treeshake: costs.txt is what an unused `import <unit>;`
// adds (the emitter brackets each global's initializer with ygiS_/ygiE_ marks
// and the link drops a pure range nothing reads; what is left is the purity
// rule keeping what has an effect), deadcode.txt the instructions a listing
// cannot execute (deadcode.y), shapes.txt the sizes a runtime addition moves
// first. Growth fails; shrinkage passes and says so, so the file can be lowered
// deliberately. Plus feature absence: a program that allocates nothing links
// no allocator, no collector and no string helper, and --gc=auto/always/never
// keep the collector exactly when they say.
import fs;
import yt;
import yc;
import deadcode;
import sort;

let TS = "";

def compile(cc: str, src: str, out: str) -> yt.Res {
    let c = yt.cmd([cc, src, "-o", out]);
    c.cwd = yc.ROOT;
    c.mem_kb = yc.PROG_MEM_KB;
    c.timeout = 30 * yt.SCALE;
    yt.run(c)
};

// The shaken -S text.
def listing(cc: str, src: str, flags: [str]) -> str {
    let c = yt.cmd([cc, "-S"] + flags + [src]);
    c.cwd = yc.ROOT;
    c.mem_kb = yc.PROG_MEM_KB;
    c.timeout = 30 * yt.SCALE;
    yt.run(c).out
};

// The function labels (`y_...:`) of a listing, sorted and unique.
def labels(s: str) -> [str] {
    let m: {str => bool} = {};
    foreach (l in s.split("\n")) {
        if (l.starts_with("y_")) {
            let i = 2;
            while (i < l.length && (deadcode.is_cont(l[i]) && l[i] != 46)) { i += 1; };
            if (i > 2 && i < l.length && l[i] == 58) { m[l[0:i + 1]] = true; };
        };
    };
    sort.sort_str(keys(m))
};

// `name number` lines of a ratchet file, comments skipped.
def table(file: str) -> [[str]] {
    let r: [[str]] = [];
    foreach (l in yt.lines(yt.read(TS + "/" + file))) {
        let w = yt.words(l);
        if (w.length == 2 && !l.starts_with("#")) { r += [w]; };
    };
    r
};

def ratchet(name: str, got: long, known: long, what: str, file: str) {
    if (got > known) {
        yt.fail(name + " " + tostring(got) + what + " (was " + tostring(known) + ")", "");
    } else if (got < known) {
        yt.pass(name + " " + tostring(got) + what + ", DOWN from " + tostring(known) + " (update " + file + ")");
    } else {
        yt.pass(name + " " + tostring(got) + what);
    };
};

// Lines of s holding any of `pats`.
def matching(s: str, pats: [str]) -> [str] {
    let r: [str] = [];
    foreach (l in s.split("\n")) {
        foreach (p in pats) {
            if (l.contains(p)) { r += l; };
        };
    };
    r
};

def one(cc: str) {
    let tag = "treeshake [" + fs.path_basename(cc) + "]";
    let w = yt.tmp_dir("ts");
    let min = TS + "/minimal.y";
    let m = compile(cc, min, w + "/min");
    if (m.code != 0) {
        yt.fail(tag + " minimal compiles", yt.clip(m.out, 200));
        return;
    };
    let base = yt.size(w + "/min");
    let min_labels = labels(listing(cc, min, []));
    // 1. an import whose functions are never called adds no FUNCTION
    yt.write(w + "/imports.y", "import math;\nimport regex;\nimport fs;\nprint(7);\n");
    if (compile(cc, w + "/imports.y", w + "/imports").code != 0) {
        yt.fail(tag + " imports compiles", "");
    } else {
        let il = labels(listing(cc, w + "/imports.y", []));
        let extra: [str] = [];
        foreach (l in il) {
            if (!(l in min_labels)) { extra += l; };
        };
        yt.check(tag + " unused imports keep no function", il == min_labels, join(extra, " "));
    };
    // 2. each unit's recorded cost
    foreach (row in table("costs.txt")) {
        yt.write(w + "/one.y", "import " + row[0] + ";\nprint(7);\n");
        let r = compile(cc, w + "/one.y", w + "/one");
        if (r.code != 0) {
            yt.fail(tag + " import " + row[0] + " compiles", yt.clip(r.out, 200));
        } else {
            ratchet(tag + " unused import " + row[0] + " costs", yt.size(w + "/one") - base, yt.num(row[1], 0), " bytes", "costs.txt");
        };
    };
    // 3. reported, not gated: what the program's own dead code costs
    let dead = TS + "/dead.y";
    if (compile(cc, dead, w + "/dead").code == 0) {
        let noimp: [str] = [];
        foreach (l in yt.read(dead).split("\n")) {
            if (!l.starts_with("import ")) { noimp += l; };
        };
        yt.write(w + "/dead_noimp.y", join(noimp, "\n"));
        compile(cc, w + "/dead_noimp.y", w + "/dead_noimp");
        yt.say("  [" + fs.path_basename(cc) + "] dead.y " + tostring(yt.size(w + "/dead")) + " bytes (+"
            + tostring(yt.size(w + "/dead") - base) + ", of which " + tostring(yt.size(w + "/dead_noimp") - base)
            + " is its OWN dead code)");
    } else {
        yt.fail(tag + " dead.y compiles", "");
    };
    // 4. feature absence: hello.y allocates nothing, so no allocator call and no
    // collector block; print("literal") needs no string helper
    let hello = listing(cc, TS + "/hello.y", []);
    let gcs = matching(hello, ["call y_alloc", "jmp y_alloc", "y_gc_collect:", "y_gc_maybe:", "collector:"]);
    yt.check(tag + " hello.y carries no allocator and no collector", gcs.length == 0, yt.clip(join(gcs, " "), 300));
    let hs = matching(hello, ["y_put_hstr", "y_print_hstr"]);
    yt.check(tag + " hello.y prints a literal without the string helpers", hs.length == 0, yt.clip(join(hs, " "), 300));
    // 4c. the inlining guards: capturing and nested literals take the record path
    let fc = compile(cc, TS + "/foreach_capture.y", w + "/fc");
    let fco = if (fc.code == 0) { yc.run_bin(w + "/fc", [], "", 10).out } else { "" };
    yt.check(tag + " capturing and nested literal closures still work", fco == "5\n6\n9\n", yt.clip(fco, 200));
    // a captured local accumulator is inlined too: no indirect call
    yt.check(tag + " foreach_local.y inlines its captured literal",
        !listing(cc, TS + "/foreach_local.y", []).contains("call *%r10"), "still calls through the record");
    yt.check(tag + " print(variable) still links the string helper",
        listing(cc, TS + "/print_var.y", []).contains("y_print_hstr"), "");
    // 4b. --gc: one allocation outside any loop needs no collector under auto
    let once = TS + "/alloc_once.y";
    yt.check(tag + " --gc=auto omits the collector for a one-shot allocation",
        !listing(cc, once, []).contains("y_gc_collect:"), "");
    yt.check(tag + " --gc=always keeps the collector", listing(cc, once, ["--gc=always"]).contains("y_gc_collect:"), "");
    yt.check(tag + " --gc=never drops the collector",
        !listing(cc, TS + "/forloop.y", ["--gc=never"]).contains("y_gc_collect:"), "");
    let o1 = compile(cc, once, w + "/once");
    let c2 = yt.cmd([cc, "--gc=always", once, "-o", w + "/onceal"]);
    c2.cwd = yc.ROOT;
    let o2 = yt.run(c2);
    if (o1.code == 0 && o2.code == 0) {
        let a = yc.run_bin(w + "/once", [], "", 10);
        let b = yc.run_bin(w + "/onceal", [], "", 10);
        yt.check(tag + " --gc builds print the same thing", a.out == b.out, yt.clip(a.out, 200));
    } else {
        yt.fail(tag + " --gc builds run", "");
    };
    // 5. dead-code ratchet
    foreach (row in table("deadcode.txt")) {
        let d = deadcode.scan(listing(cc, TS + "/" + row[0], []), false);
        ratchet(tag + " " + row[0], d.n, yt.num(row[1], 0), " unreachable instructions", "deadcode.txt");
    };
    // 6. size ratchet
    foreach (row in table("shapes.txt")) {
        let src = TS + "/" + row[0];
        if (fs.is_file(src)) {
            let r = compile(cc, src, w + "/shape");
            if (r.code != 0) {
                yt.fail(tag + " " + row[0] + " compiles", yt.clip(r.out, 200));
            } else {
                ratchet(tag + " " + row[0], yt.size(w + "/shape"), yt.num(row[1], 0), " bytes", "shapes.txt");
            };
        };
    };
    // 7. loop parity, static half: the inline array methods cost no
    // instructions over the raw loop they replace (bench/ measures the rest)
    let nfor = insns(listing(cc, TS + "/forloop.y", []));
    let nfe = insns(listing(cc, TS + "/foreach.y", []));
    yt.check(tag + " foreach " + tostring(nfe) + " instructions vs " + tostring(nfor) + " raw-loop", nfe <= nfor + 20,
        "foreach is " + tostring(nfe) + " instructions vs " + tostring(nfor) + " for the raw loop");
    fs.remove_all(w);
};

// Instruction lines: indented, starting with a lower-case letter.
def insns(s: str) -> long {
    let n = 0;
    foreach (l in s.split("\n")) {
        let t = l.trim_start();
        if (t.length < l.length && t.length > 0 && t[0] >= 97 && t[0] <= 122) { n += 1; };
    };
    n
};

def cases() -> [yt.Case] {
    TS = yc.ROOT + "/test/treeshake";
    [yt.case_of("treeshake", "cycc", () => one(yc.CYCC)), yt.case_of("treeshake", "ref", () => one(yc.YREF))]
};

export { cases };
