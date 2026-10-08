// ydev.y -- the development loop's tools (AGENTS.md "Changing the compiler"):
//
//   ytest check BASE NEW [ROUNDS]   everything a compiler change needs before it
//                                   is blessed: cycc builds NEW byte for byte,
//                                   every suite passes with NEW as the reference,
//                                   then NEW against BASE -- programs that compile
//                                   or behave differently, instructions executed
//                                   compiling and running, and the timed SCORE
//   ytest corpus-diff BASE NEW [F...] what a compiler change changes, per program
//   ytest bench BASE NEW [ROUNDS]   paired timings, sizes and the SCORE
//   ytest bench-run YCC [ROUNDS]    one build's numbers, one metric a line
//   ytest bench-ir BASE NEW         exact instruction counts of the compiles
//   ytest profile BASE NEW          instructions per function, running each benchmark
//   ytest fuzz [ITER] [SEED]        mutated programs against both compilers
//   ytest fmt / fmt-check           the formatter over src/y, std and the server
//   ytest run-parity YCC [N]        `ycc run` == compile and execute (native t*.y)
//   ytest meta-identity YCC [N]     -E is the identity on a file with no block
//   ytest mem YCC FILE...           peak RSS of a compile, a `ycc run` and the program
//
// Every compiler and program runs under the memory cap (yt.MEM_KB).
import fs;
import math;
import sort;
import yt;
import yc;

def jobs() -> long { yt.num(yt.env("YJOBS", tostring(cpus())), cpus()) };

def cpus() -> long {
    let n = 0;
    foreach (l in yt.lines(yt.read("/proc/cpuinfo"))) {
        if (l.starts_with("processor")) { n += 1; };
    };
    if (n < 1) { 1 } else { n }
};

def secs_since(t0: long) -> str {
    let s = (clock_us() - t0) / 1000000;
    tostring(s / 60) + "m" + (if (s % 60 < 10) { "0" } else { "" }) + tostring(s % 60) + "s"
};

def median(xs: [long]) -> long {
    if (xs.length == 0) { return 0; };
    let s = sort.sort(xs);
    if (s.length % 2 == 1) { s[s.length / 2] } else { (s[s.length / 2 - 1] + s[s.length / 2]) / 2 }
};

def fmt1(v: float) -> str {
    let t = tolong(math.round(v * 10.0))!;
    let neg = t < 0;
    if (neg) { t = 0 - t; };
    (if (neg) { "-" } else { "" }) + tostring(t / 10) + "." + tostring(t % 10)
};

def fmt2(v: float) -> str {
    let t = tolong(math.round(v * 100.0))!;
    let neg = t < 0;
    if (neg) { t = 0 - t; };
    (if (neg) { "-" } else { "" }) + tostring(t / 100) + "." + (if (t % 100 < 10) { "0" } else { "" }) + tostring(t % 100)
};

def pct(base: long, new: long) -> str {
    if (base == 0) { return "?"; };
    let d = 100.0 * (tofloat(new)! - tofloat(base)!) / tofloat(base)!;
    (if (d >= 0.0) { "+" } else { "" }) + fmt2(d) + "%"
};

// Copies of BASE and NEW in a scratch directory under names of one length (a
// count includes the instructions spent on paths), with std/ and arch/ beside
// them so a program outside the checkout still resolves its imports.
def stage(base: str, new: str) -> [str] {
    let d = yt.tmp_dir("stage");
    fs.copy_file(yc.abs_path(base), d + "/ycc_b");
    fs.copy_file(yc.abs_path(new), d + "/ycc_n");
    fs.set_mode(d + "/ycc_b", 0o755);
    fs.set_mode(d + "/ycc_n", 0o755);
    [d + "/ycc_b", d + "/ycc_n"]
};

def bench_progs(self_too: bool) -> [str] {
    let r = yt.files(yc.ROOT + "/bench/y", "", ".y");
    if (self_too) { r += yc.ROOT + "/src/y/ycc.y"; };
    r
};

def name_of(src: str) -> str { if (src.ends_with("/src/y/ycc.y")) { "self" } else { fs.path_stem(src) } };

// ── corpus-diff ─────────────────────────────────────────────────────────
//
// Every program compiled by BASE and by NEW; each whose exit, messages or
// binary differ is listed, and each binary that differs is run under both
// builds to tell a change of code from a change of behavior.

def diff_one(base: str, new: str, f: str) -> str {
    let name = yc.rel(f);
    let d = yt.tmp_dir("cd");
    let to = if (name == "src/y/ycc.y") { 300 } else { 60 };
    let eb = yc.compile(base, [], f, d + "/base", to);
    let en = yc.compile(new, [], f, d + "/new", to);
    let out = "";
    if (eb.code != en.code || eb.out != en.out) {
        out = "B DIFF compile   " + name + " (exit " + tostring(eb.code) + " -> " + tostring(en.code) + ")\n    -"
            + yt.clip(eb.out, 300) + "\n    +" + yt.clip(en.out, 300);
    } else if (eb.code == 0 && !yt.same_file(d + "/base", d + "/new")) {
        if (name == "src/y/ycc.y") {
            out = "C DIFF code      " + name + " (the compiler's own code)";
        } else {
            let stdin = f[0:f.length - 2] + ".stdin";
            let inp = if (fs.is_file(stdin)) { stdin } else { "" };
            // run where a file the program writes cannot land in the repository
            def go(bin: str) -> str {
                let c = yt.cmd([bin]);
                c.cwd = d;
                c.stdin = inp;
                c.merge = true;
                c.timeout = 10;
                c.mem_kb = yc.PROG_MEM_KB;
                let r = yt.run(c);
                r.out + "exit " + tostring(r.code)
            };
            let ob = go(d + "/base");
            let on = go(d + "/new");
            out = if (ob == on) { "C DIFF code      " + name + " (same behavior)" }
                else { "X DIFF behavior  " + name + "\n    " + yt.first_diff(ob, on) };
        };
    };
    fs.remove_all(d);
    out
};

/** The report and the counts: [programs, code, behavior]. */
def corpus_diff(base: str, new: str, files: [str], n: [long]) -> str {
    let fl = files;
    if (fl.length == 0) { fl = yt.tree(yc.ROOT + "/test/y", ".y") + [yc.ROOT + "/src/y/ycc.y"]; };
    let res = yt.par_map(fl.length, jobs(), (i: long) => diff_one(yc.abs_path(base), yc.abs_path(new), yc.abs_path(fl[i])));
    let out: [str] = [];
    let code = 0;
    let behavior = 0;
    foreach (r in res) {
        if (r != "") {
            if (r[0] == 67 || r[0] == 88) { code += 1; };
            if (r[0] == 66 || r[0] == 88) { behavior += 1; };
            out += r[2:];
        };
    };
    n[0] = fl.length;
    n[1] = code;
    n[2] = behavior;
    out += tostring(fl.length) + " programs: " + tostring(code) + " compile to different code, " + tostring(behavior)
        + " compile or behave differently";
    join(out, "\n")
};

def main_corpus_diff(av: [str]) -> long {
    if (av.length < 2) {
        eputs("usage: ytest corpus-diff BASE NEW [FILE...]");
        return 2;
    };
    let n = [0, 0, 0];
    print(corpus_diff(av[0], av[1], av[2:], n));
    if (n[2] == 0) { 0 } else { 1 }
};

// ── bench: paired timings ──────────────────────────────────────────────
//
// Every time row is sampled in PAIRS -- base and new back to back, the order
// flipping every pair -- because load on a shared machine comes in bursts, and
// measured in separate passes two runs of the SAME binary once differed by 37%
// per row. ROUNDS pairs at least, and more (10 at most) while base's runs add
// up to under 0.2 s; an even number, so each side goes first equally often.
// The SCORE is 100 x the geometric mean of base/new over compile time, run
// time and binary size: 100 = no change, >100 = the new build is better.

def timed(argv: [str], cwd: str) -> long {
    let c = yt.cmd(argv);
    c.cwd = cwd;
    c.timeout = 0;
    let r = yt.run(c);
    if (r.code != 0) { -1 } else { r.us }
};

// [base, new] medians of one row
def pair_row(rounds: long, b: [str], n: [str], cwd: str) -> [long] {
    let sb: [long] = [];
    let sn: [long] = [];
    let total = 0;
    let k = 0;
    while (k < rounds || (total < 200000 && k < 10) || k % 2 == 1) {
        let tb = 0;
        let tn = 0;
        if (k % 2 == 0) {
            tb = timed(b, cwd);
            tn = timed(n, cwd);
        } else {
            tn = timed(n, cwd);
            tb = timed(b, cwd);
        };
        if (tb < 0 || tn < 0) { return [-1, -1]; };
        sb += tb;
        sn += tn;
        total += tb;
        k += 1;
    };
    [median(sb), median(sn)]
};

/** The joined rows "bench:metric base new" and the score. */
def bench(base: str, new: str, rounds: long, self_too: bool) -> str {
    let st = stage(base, new);
    let t = fs.path_dirname(st[0]);
    let rows: [str] = [];
    let ratios: [float] = [];
    let notes: [str] = [];
    def add(key: str, b: long, n: long, scored: bool) {
        rows += key + "\t" + tostring(b) + "\t" + tostring(n);
        if (scored) { ratios += if (n > 0) { tofloat(b)! / tofloat(n)! } else { 1.0 }; };
    };
    foreach (src in bench_progs(self_too)) {
        let nm = name_of(src);
        let c = pair_row(rounds, [st[0], "-o", t + "/b." + nm, src], [st[1], "-o", t + "/n." + nm, src], yc.ROOT);
        if (c[0] < 0) {
            if (yc.compile(st[1], [], src, t + "/probe", 300).code == 0) {
                notes += "bench: " + nm + ": no rows, the base cannot build it (the new build can)";
            } else {
                return "bench: the new build fails on " + src;
            };
        } else {
            add(nm + ":compile_us", c[0], c[1], true);
            add(nm + ":binary_bytes", yt.size(t + "/b." + nm), yt.size(t + "/n." + nm), true);
            let sb = yt.exe([st[0], "-S", src]).out;
            let sn = yt.exe([st[1], "-S", src]).out;
            add(nm + ":asm_bytes", sb.length, sn.length, false);
            if (nm == "self") {
                add("self:asm_lines", yt.lines(sb).length, yt.lines(sn).length, false);
                add("self:heap_kb", heap_kb(st[0], src, t + "/hb"), heap_kb(st[1], src, t + "/hn"), false);
            } else {
                let r = pair_row(rounds, [t + "/b." + nm], [t + "/n." + nm], t);
                if (r[0] < 0) { return "bench: " + nm + " exited nonzero"; };
                add(nm + ":run_us", r[0], r[1], true);
            };
        };
    };
    fs.remove_all(t);
    let out: [str] = [];
    foreach (r in sort.sort_str(rows)) {
        let w = r.split("\t");
        let km = w[0].split(":");
        let b = yt.num(w[1], 0);
        let n = yt.num(w[2], 0);
        let better = if (b > 0) { 100.0 * tofloat(b - n)! / tofloat(b)! } else { 0.0 };
        out += km[0].pad_right(10) + " " + km[1].pad_right(12) + " " + tostring(b).pad_left(14) + " " + tostring(n).pad_left(14)
            + "   " + (if (better >= 0.0) { "+" } else { "" }) + fmt1(better) + "%";
    };
    let s = 0.0;
    foreach (r in ratios) { s = s + math.log(r); };
    let score = if (ratios.length > 0) { 100.0 * math.exp(s / tofloat(ratios.length)!) } else { 100.0 };
    out += "";
    out += "SCORE: " + fmt2(score) + "   (100 = base, >100 = the new build is better overall)";
    join(notes + out, "\n")
};

// the arena high water of a whole compile, from --time's TOTAL line
def heap_kb(cc: str, src: str, out: str) -> long {
    let r = yt.exe2([cc, "--time", "-o", out, src]);
    foreach (l in yt.lines(r.out)) {
        let w = yt.words(l);
        if (w.length >= 4 && w[0] == "TOTAL") { return yt.num(w[3], 0); };
    };
    0
};

def main_bench(av: [str]) -> long {
    if (av.length < 2) {
        eputs("usage: ytest bench BASE NEW [ROUNDS]");
        return 2;
    };
    let rounds = if (av.length > 2) { yt.num(av[2], 5) } else { 5 };
    print("base:  " + yc.abs_path(av[0]));
    print("new:   " + yc.abs_path(av[1]));
    print("runs:  every time from " + tostring(rounds) + " or more pairs of runs, base and new back to back (median per side); all metrics lower-is-better\n");
    let r = bench(av[0], av[1], rounds, yt.env("BENCH_SELF", "1") != "0");
    print(r);
    if (yt.env("BENCH_PROFILE", "1") != "0") {
        print("");
        print(profile(av[0], av[1]));
    };
    if (r.contains("SCORE:")) { 0 } else { 1 }
};

// One build's numbers: "bench<TAB>metric<TAB>value", medians of ROUNDS runs.
def main_bench_run(av: [str]) -> long {
    if (av.length < 1) {
        eputs("usage: ytest bench-run YCC [ROUNDS]");
        return 2;
    };
    let ycc = yc.abs_path(av[0]);
    let rounds = if (av.length > 1) { yt.num(av[1], 5) } else { 5 };
    let t = yt.tmp_dir("brun");
    def samples(argv: [str], cwd: str) -> long {
        let xs: [long] = [];
        let total = 0;
        while (xs.length < rounds || (total < 200000 && xs.length < 10)) {
            let v = timed(argv, cwd);
            if (v < 0) { return -1; };
            xs += v;
            total += v;
        };
        median(xs)
    };
    foreach (src in bench_progs(yt.env("BENCH_SELF", "1") != "0")) {
        let nm = name_of(src);
        let bin = t + "/" + nm;
        let c = samples([ycc, "-o", bin, src], yc.ROOT);
        if (c < 0) {
            eputs("bench: ycc failed on " + src);
            return 1;
        };
        print(nm + "\tcompile_us\t" + tostring(c));
        print(nm + "\tbinary_bytes\t" + tostring(yt.size(bin)));
        let asm = yt.exe([ycc, "-S", src]).out;
        print(nm + "\tasm_bytes\t" + tostring(asm.length));
        if (nm == "self") {
            print("self\tasm_lines\t" + tostring(yt.lines(asm).length));
            print("self\theap_kb\t" + tostring(heap_kb(ycc, src, bin)));
        } else {
            let r = samples([bin], t);
            if (r < 0) {
                eputs("bench: " + bin + " exited nonzero");
                return 1;
            };
            print(nm + "\trun_us\t" + tostring(r));
        };
    };
    fs.remove_all(t);
    0
};

// ── instruction counts ──────────────────────────────────────────────────

// Instructions `cc` executes compiling `src` (cachegrind's I refs), or -1.
def ir_count(cc: str, src: str) -> long {
    // one path length for every count: a count includes the work on the path
    let dir = yt.scratch() + "/ir" + tostring(10000000 + yt.getpid() % 10000000);
    fs.make_dirs(dir);
    let out = dir + "/bin";
    let c = yt.cmd(["valgrind", "--tool=cachegrind", "--cache-sim=no", "--cachegrind-out-file=/dev/null", cc, "-o", out, src]);
    c.cwd = yc.ROOT;
    // the collector scans the stack conservatively, so where the stack lands
    // moves what it keeps: without randomization the count repeats exactly
    c.fixed = true;
    c.merge = true;
    c.timeout = 900;
    let r = yt.run(c);
    fs.remove_all(fs.path_dirname(out));
    if (r.code != 0) { return -1; };
    foreach (l in yt.lines(r.out)) {
        let i = l.index_of("I   refs:");
        if (i < 0) { i = l.index_of("I refs:"); };
        if (i >= 0) {
            let w = yt.words(l);
            return yt.num(w[w.length - 1].replace(",", ""), -1);
        };
    };
    -1
};

/** The instructions each build executes compiling every benchmark and ycc.y. */
def bench_ir(base: str, new: str) -> str {
    if (!yt.have("valgrind")) { return "bench: valgrind not found"; };
    let st = stage(base, new);
    let progs = [yc.ROOT + "/src/y/ycc.y"] + bench_progs(false);
    let res = yt.par_map(progs.length * 2, jobs(), (i: long) => tostring(ir_count(st[i % 2], progs[i / 2])));
    fs.remove_all(fs.path_dirname(st[0]));
    let out = ["program".pad_right(14) + " " + "Ir_base".pad_left(15) + " " + "Ir_new".pad_left(15) + " " + "delta".pad_left(8)];
    let order: [long] = [];
    for i in 1..progs.length { order += i; };
    order += 0;
    foreach (i in order) {
        let a = yt.num(res[2 * i], -1);
        let b = yt.num(res[2 * i + 1], -1);
        let p = fs.path_basename(progs[i]);
        out += p.pad_right(14) + " " + (if (a < 0) { "-" } else { tostring(a) }).pad_left(15) + " "
            + (if (b < 0) { "-" } else { tostring(b) }).pad_left(15) + " " + (if (a > 0 && b >= 0) { pct(a, b) } else { "?" }).pad_left(8);
    };
    join(out, "\n")
};

def main_bench_ir(av: [str]) -> long {
    if (av.length < 2) {
        eputs("usage: ytest bench-ir BASE NEW");
        return 2;
    };
    let r = bench_ir(av[0], av[1]);
    print(r);
    if (r.starts_with("bench:")) { 2 } else { 0 }
};

// "function<TAB>Ir" of a callgrind profile, recursion levels folded, plus TOTAL.
def ir_table(cg: str) -> {str => long} {
    let t: {str => long} = {};
    let a = yt.exe(["callgrind_annotate", "--threshold=100", "--auto=no", cg]).out;
    foreach (l in yt.lines(a)) {
        let s = l.trim_start();
        let i = 0;
        while (i < s.length && ((s[i] >= 48 && s[i] <= 57) || s[i] == 44)) { i += 1; };
        let rest = s[i:].trim_start();
        if (i > 0 && rest.starts_with("(")) {
            let close = rest.index_of(")");
            if (close > 0 && rest[0:close].contains("%")) {
                let ir = yt.num(s[0:i].replace(",", ""), 0);
                let fname = rest[close + 1:].trim();
                let br = fname.index_of(" [");
                if (br >= 0) { fname = fname[0:br]; };
                if (fname == "PROGRAM TOTALS") {
                    fname = "TOTAL";
                } else {
                    let c = fname.index_of(":");
                    if (c >= 0) { fname = fname[c + 1:]; };
                    let q = fname.last_index_of("'");
                    if (q > 0 && yt.num(fname[q + 1:], -1) >= 0) { fname = fname[0:q]; };
                    fname = fname.replace(" ", "_");
                };
                t[fname] = (if (fname in t) { t[fname]! } else { 0 }) + ir;
            };
        };
    };
    t
};

def prof_one(cc: str, src: str) -> str {
    let d = yt.tmp_dir("prof");
    let r = yc.compile(cc, ["-g"], src, d + "/bin", 300);
    let out = "";
    if (r.code == 0) {
        let c = yt.cmd(["valgrind", "--tool=callgrind", "--show-below-main=yes", "--callgrind-out-file=cg.out", "./bin"]);
        c.cwd = d;
        c.fixed = true;
        c.timeout = 900;
        yt.run(c);
        let t = ir_table(d + "/cg.out");
        let rows: [str] = [];
        foreach (k in keys(t)) { rows += k + "\t" + tostring(t[k]!); };
        out = join(rows, "\n");
    };
    fs.remove_all(d);
    out
};

/** Instructions per function, running each benchmark built by each side. */
def profile(base: str, new: str) -> str {
    if (!yt.have("valgrind") || !yt.have("callgrind_annotate")) {
        return "per-function profile: skipped (needs valgrind and callgrind_annotate)";
    };
    let progs = bench_progs(false);
    let res = yt.par_map(progs.length * 2, jobs(), (i: long) => prof_one(yc.abs_path(if (i % 2 == 0) { base } else { new }), progs[i / 2]));
    let out = ["per-function profile (instructions executed, self; callgrind on -g builds):"];
    for p in 0..progs.length {
        let b: {str => long} = {};
        let n: {str => long} = {};
        foreach (l in yt.lines(res[2 * p])) {
            let w = l.split("\t");
            if (w.length == 2) { b[w[0]] = yt.num(w[1], 0); };
        };
        foreach (l in yt.lines(res[2 * p + 1])) {
            let w = l.split("\t");
            if (w.length == 2) { n[w[0]] = yt.num(w[1], 0); };
        };
        let bt = if ("TOTAL" in b) { tostring(b["TOTAL"]!) } else { "-" };
        let nt = if ("TOTAL" in n) { tostring(n["TOTAL"]!) } else { "-" };
        let d = if ("TOTAL" in b && "TOTAL" in n && b["TOTAL"]! > 0) { "  " + pct(b["TOTAL"]!, n["TOTAL"]!) } else { "" };
        out += "";
        out += "--- " + name_of(progs[p]) + "   total Ir: base " + bt + ", new " + nt + d;
        out += "  " + "function".pad_right(20) + " " + "Ir_base".pad_left(14) + " " + "Ir_new".pad_left(14) + " " + "delta".pad_left(10);
        // the eight biggest, by the base's count (the new one's when absent)
        let fns: [str] = [];
        foreach (k in keys(b)) {
            if (k != "TOTAL") { fns += k; };
        };
        foreach (k in keys(n)) {
            if (k != "TOTAL" && !(k in b)) { fns += k; };
        };
        def weight(k: str) -> long { if (k in b) { b[k]! } else { n[k]! } };
        let ranked = fns.sorted((x: str, y: str) => weight(y) - weight(x));
        for i in 0..(if (ranked.length > 8) { 8 } else { ranked.length }) {
            let k = ranked[i];
            out += "  " + k.pad_right(20) + " " + (if (k in b) { tostring(b[k]!) } else { "-" }).pad_left(14) + " "
                + (if (k in n) { tostring(n[k]!) } else { "-" }).pad_left(14) + " "
                + (if (k in b && k in n && b[k]! > 0) { pct(b[k]!, n[k]!) } else { "n/a" }).pad_left(10);
        };
    };
    join(out, "\n")
};

def main_profile(av: [str]) -> long {
    if (av.length < 2) {
        eputs("usage: ytest profile BASE NEW");
        return 2;
    };
    print(profile(av[0], av[1]));
    0
};

// ── check ───────────────────────────────────────────────────────────────

def indent(s: str) -> str {
    let out: [str] = [];
    foreach (l in yt.lines(s)) { out += "    " + l; };
    join(out, "\n")
};

def main_check(av: [str]) -> long {
    if (av.length < 2) {
        eputs("usage: ytest check BASE NEW [ROUNDS]");
        return 2;
    };
    let base_name = av[0];
    let new_name = av[1];
    let rounds = if (av.length > 2) { yt.num(av[2], 3) } else { 3 };
    let log = yc.ROOT + "/_check";
    fs.remove_all(log);
    fs.make_dirs(log);
    let st = stage(base_name, new_name);
    let t = fs.path_dirname(st[0]);
    fs.copy_file(yc.CYCC, t + "/cycc");
    fs.set_mode(t + "/cycc", 0o755);
    // a pack-less copy finds std/ and arch/ beside itself
    foreach (d in ["std", "arch"]) {
        let from = yt.cz(yc.ROOT + "/src/y/" + d);
        let to = yt.cz(t + "/" + d);
        syscall(88, &from[0], &to[0]);
    };
    let start = clock_us();
    let j = jobs();
    // the counted jobs take a fifth of the CPUs each, the suites the rest
    let cj = if (j / 5 >= 1) { j / 5 } else { 1 };
    let sj = if (j - 2 * cj >= 1) { j - 2 * cj } else { 1 };
    print("check: new " + new_name + ", base " + base_name + " (full output: _check/)");
    print("\n== 1/3 verify");
    let t0 = clock_us();
    let c = yt.cmd([t + "/cycc", "-o", t + "/self", yc.ROOT + "/src/y/ycc.y"]);
    c.merge = true;
    c.timeout = 900;
    let r = yt.run(c);
    let p = if (r.code == 0) { yt.exe2([t + "/self", "--std-pack", t + "/self.pack"]) } else { r };
    yt.write(log + "/self.log", r.out + p.out);
    if (r.code != 0 || p.code != 0 || !yt.concat(t + "/selfp", [t + "/self", t + "/self.pack"]) || !yt.same_file(t + "/selfp", st[1])) {
        print("  FAILED  cycc does not build " + new_name + " from src/y/ycc.y (_check/self.log)");
        return 1;
    };
    print("  ok      cycc builds " + new_name + " from src/y/ycc.y, byte for byte (" + secs_since(t0) + ")");
    // the counts run beside the suites: they do not depend on machine load
    def bg(args: [str], file: str) -> yt.Proc {
        let b = yt.cmd([yt.self_exe()] + args);
        b.merge = true;
        b.timeout = 0;
        b.out = log + "/" + file;
        b.env = ["YJOBS=" + tostring(cj)];
        yt.start(b)
    };
    let ir = bg(["bench-ir", st[0], st[1]], "compile_ir.log");
    let prof = bg(["profile", st[0], st[1]], "profile.log");
    t0 = clock_us();
    let s = yt.cmd([yt.self_exe(), "-j", tostring(sj)]);
    s.merge = true;
    s.timeout = 0;
    s.out = log + "/tests.log";
    s.env = ["YREF=" + st[1], "YCC=" + st[1], "YSELF=" + st[1], "CYCC=" + t + "/cycc", "YQUIET=1", "YPORT_SELF=0", "NO_COLOR=1"];
    if (yt.run(s).code == 0) {
        print("  ok      every suite passes with " + new_name + " as the reference and the built compiler (" + secs_since(t0) + ")");
    } else {
        let fails: [str] = [];
        foreach (l in yt.lines(yt.read(log + "/tests.log"))) {
            if (l.contains("FAIL") && !l.starts_with("#") && fails.length < 30) { fails += l; };
        };
        print("  FAILED  a suite (" + secs_since(t0) + ", _check/tests.log):");
        print(indent(join(fails, "\n")));
        yt.kill(ir);
        yt.kill(prof);
        return 1;
    };
    print("\n== 2/3 compare with " + base_name);
    t0 = clock_us();
    let n = [0, 0, 0];
    let cd = corpus_diff(st[0], st[1], [], n);
    yt.write(log + "/corpus.log", cd);
    let cls = yt.lines(cd);
    print("  " + cls[cls.length - 1] + " (" + secs_since(t0) + ", _check/corpus.log)");
    let shown = 0;
    foreach (l in cls) {
        if (l.starts_with("DIFF") && shown < 30) {
            print("    " + l);
            shown += 1;
        };
    };
    yt.wait(ir);
    yt.wait(prof);
    print("\n  instructions executed compiling (ytest bench-ir; + = more):");
    print(indent(yt.read(log + "/compile_ir.log")));
    print("\n  instructions executed running (ytest profile; per function: _check/profile.log):");
    foreach (l in yt.lines(yt.read(log + "/profile.log"))) {
        if (l.starts_with("--- ")) { print("    " + l[4:]); };
    };
    print("\n== 3/3 time (ytest bench: " + tostring(rounds) + " or more pairs of runs per row)");
    t0 = clock_us();
    let b = bench(st[0], st[1], rounds, true);
    yt.write(log + "/timing.log", b);
    if (!b.contains("SCORE:")) {
        print("  FAILED  a benchmark does not build or run (_check/timing.log):");
        print(indent(b));
        return 1;
    };
    // Sizes are exact. A time is wall clock on a shared machine: the score
    // holds to about +-2.5, a row of 40 ms or more to under 10%, a shorter one
    // swings by 20% between two runs of one build, so only a long row that
    // moved 10% is shown (its instruction count is step 2's).
    let moved = 0;
    foreach (l in yt.lines(b)) {
        if (l.starts_with("SCORE")) { print("  " + l); };
        let w = yt.words(l);
        if (w.length == 5 && w[4].ends_with("%")) {
            let bv = yt.num(w[2], 0);
            let nv = yt.num(w[3], 0);
            let timed_ = w[1].ends_with("_us");
            let d = if (bv > 0) { 100 * (nv - bv) / bv } else { 0 };
            if (if (timed_) { bv >= 40000 && (d >= 10 || d <= -10) } else { bv != nv }) {
                if (moved == 0) { print("  rows that moved (sizes: any change, times of 40 ms or more: 10% or more):"); };
                moved += 1;
                print("    " + l);
            };
        };
    };
    if (moved == 0) { print("  no size changed, no time of 40 ms or more moved by 10% or more"); };
    fs.remove_all(t);
    print("\ncheck passed in " + secs_since(start) + ". `make rebless` makes " + new_name + " the reference.");
    0
};

// ── fuzz ────────────────────────────────────────────────────────────────
//
// Mutated programs against both compilers, compiled (never run) under a cap
// and a timeout. A finding is a crash (a signal, a timeout, a trap of the
// compiler itself, an INTERNAL marker) or a divergence (exit, messages or
// binary differ: checked FIRST, since one side's trap where the other reports
// is a port bug). Each distinct finding is saved once, with its input and both
// outputs, under _check/fuzz; each input is reproducible from its seed line.

def fz_compile(cc: str, src: str, bin: str) -> yt.Res {
    let c = yt.cmd([cc, "--no-exec", "-o", bin, src]);
    c.merge = true;
    c.timeout = yt.num(yt.env("FUZZ_TIMEOUT", "10"), 10);
    c.mem_kb = yt.num(yt.env("FUZZ_MEM_KB", "2000000"), 2000000);
    let r = yt.run(c);
    if (r.out.length > 4000) { r.out = r.out[0:4000]; };
    r.out = r.out.replace(chr(0), "");
    r
};

def main_fuzz(av: [str]) -> long {
    let iter = if (av.length > 0) { yt.num(av[0], 500) } else { 500 };
    let seed = if (av.length > 1) { yt.num(av[1], 1) } else { clock_us() % 32768 };
    let out = yc.abs_path(yt.env("FUZZ_OUT", "_check/fuzz"));
    fs.make_dirs(out);
    // three levels down, like test/y/native: the corpus's relative imports resolve
    let w = yc.ROOT + "/test/fuzz/work." + tostring(yt.getpid());
    fs.make_dirs(w);
    if (yc.compile(yc.YCC, [], yc.ROOT + "/test/fuzz/mutate.y", w + "/mutate", 300).code != 0) {
        print("fuzz: cannot build mutate.y");
        return 2;
    };
    let corpus = yt.files(yc.ROOT + "/test/y/native", "", ".y") + yt.files(yc.ROOT + "/test/y/audit", "", ".y")
        + yt.files(yc.ROOT + "/test/y/examples", "", ".y");
    let n = corpus.length;
    let seen: {str => bool} = {};
    let found = 0;
    print("fuzz: " + tostring(iter) + " inputs, seed " + tostring(seed) + ", corpus " + tostring(n) + " files, findings in " + out);
    for i in 1..iter + 1 {
        let rng = seed * 1000003 + i;
        let a = corpus[((rng * 7919) % n + n) % n];
        let b = corpus[((rng * 104729 + 17) % n + n) % n];
        if (yt.exe([w + "/mutate", a, b, tostring(rng), w + "/in.y"]).code == 0) {
            let y = fz_compile(yc.YCC, w + "/in.y", w + "/y.bin");
            let c = fz_compile(yc.CYCC, w + "/in.y", w + "/c.bin");
            let kind = if (y.code >= 124 || c.code >= 124) { "crash" } else { "" };
            if (kind == "" && (y.code != c.code || y.out != c.out)) { kind = "diverge"; };
            if (kind == "" && ((y.out + c.out).contains("runtime error:") || (y.out + c.out).contains("INTERNAL"))) { kind = "crash"; };
            // a meta generator that traps is a diagnostic naming its block, when
            // both compilers say so alike
            if (kind == "crash" && y.out == c.out && y.code == c.code && y.out.contains("the meta generator exited")) { kind = ""; };
            if (kind == "" && y.code == 0 && !yt.same_file(w + "/y.bin", w + "/c.bin")) { kind = "diverge"; };
            fs.remove_file(w + "/y.bin");
            fs.remove_file(w + "/c.bin");
            if (kind != "") {
                // crashes dedupe on the trap line, divergences on the first message
                let key = "";
                foreach (l in yt.lines(y.out + "\n" + c.out)) {
                    let k = l.index_of("runtime error:");
                    if (k < 0) { k = l.index_of("INTERNAL"); };
                    if (key == "" && k >= 0) { key = l[k:]; };
                };
                if (key == "") {
                    key = yt.first_line(y.out);
                    let col = key.index_of(": ");
                    if (col > 0 && yt.num(key[0:key.index_of(":")], -1) >= 0) { key = key[col + 2:]; };
                };
                let sig = kind + ":" + tostring(y.code) + ":" + tostring(c.code) + ":" + key;
                if (!(sig in seen)) {
                    seen[sig] = true;
                    found += 1;
                    let f = out + "/" + kind + "-" + tostring(seed) + "-" + tostring(i);
                    fs.copy_file(w + "/in.y", f + ".y");
                    yt.write(f + ".txt", "seed: mutate " + a + " " + b + " " + tostring(rng) + "\nycc rc=" + tostring(y.code) + "\n" + y.out
                        + "\ncycc rc=" + tostring(c.code) + "\n" + c.out + "\n");
                    print(kind + ": " + f + ".y (ycc rc=" + tostring(y.code) + ", cycc rc=" + tostring(c.code) + ") " + yt.clip(key, 100));
                };
            };
        };
    };
    fs.remove_all(w);
    print("fuzz: " + tostring(found) + " distinct finding(s)");
    if (found == 0) { 0 } else { 1 }
};

// ── the formatter ───────────────────────────────────────────────────────

def fmt_files() -> [str] {
    yt.files(yc.ROOT + "/src/y", "", ".y") + yt.files(yc.ROOT + "/src/y/std", "", ".y") + yt.files(yc.ROOT + "/src/tools/lsp", "", ".y")
};

// The fixed-point driver, built by the C copy (or YCC=...).
def fmt_driver(drv: str) -> str {
    let cc = yc.abs_path(yt.env("FMT_CC", yc.CYCC));
    let out = yt.tmp("fmt");
    let r = yc.compile(cc, [], yc.ROOT + "/src/tools/lsp/test/" + drv, out, 900);
    if (r.code != 0) {
        eputs("cannot build " + drv + ": " + r.out);
        return "";
    };
    out
};

/** `ytest fmt`: format src/y, std and the server in place. */
def main_fmt(av: [str]) -> long {
    let one = fmt_driver("drv_fmt_fixedpoint.y");
    if (one == "") { return 1; };
    let n = 0;
    foreach (f in fmt_files()) {
        let r = yt.exe([one, f, f + ".fmt"]);
        if (r.out.trim() == "DIFFERS") {
            fs.rename(f + ".fmt", f);
            print("  formatted " + yc.rel(f));
            n += 1;
        } else {
            fs.remove_file(f + ".fmt");
        };
    };
    print("fmt: " + tostring(n) + " file(s) rewritten");
    0
};

/** `ytest fmt-check`: idempotence over the tree (the gate), and the src/y fixed point. */
def main_fmt_check(av: [str]) -> long {
    let idem = fmt_driver("drv_fmt_idempotent.y");
    if (idem == "") { return 1; };
    let files: [str] = [];
    foreach (d in ["src/y", "src/tools", "bench", "test/y"]) { files += yt.tree(yc.ROOT + "/" + d, ".y"); };
    let r = yt.exe2([idem] + files);
    let bad: [str] = [];
    let sum = "";
    foreach (l in yt.lines(r.out)) {
        if (l.starts_with("NOT-IDEMPOTENT")) { bad += l; };
        if (l.starts_with("checked ")) { sum = l; };
    };
    if (bad.length > 0) {
        print("FAIL     idempotence: " + tostring(bad.length) + " files");
        foreach (l in bad) { print("            " + l); };
    } else {
        print("ok       idempotence -- " + sum);
    };
    let one = fmt_driver("drv_fmt_fixedpoint.y");
    let same = 0;
    let total = 0;
    let diffs = 0;
    foreach (f in yt.files(yc.ROOT + "/src/y", "", ".y") + yt.files(yc.ROOT + "/src/y/std", "", ".y")) {
        total += 1;
        let x = yt.tmp("x");
        if (yt.exe([one, f, x]).out.trim() == "SAME") {
            same += 1;
        } else {
            foreach (l in yt.lines(yt.exe(["diff", f, x]).out)) {
                if (l.starts_with("<") || l.starts_with(">")) { diffs += 1; };
            };
        };
        fs.remove_file(x);
    };
    print("ok       src/y fixed point -- " + tostring(same) + "/" + tostring(total) + " byte-identical, " + tostring(diffs) + " lines differ");
    print("");
    print(if (bad.length == 0) { "formatter: OK" } else { "formatter: FAILED" });
    if (bad.length == 0 && r.code == 0) { 0 } else { 1 }
};

// ── parity tools, run by hand ───────────────────────────────────────────

// `ycc run` must behave exactly like compiling then executing, over the native
// t*.y fixtures, both from the tree root (module resolution sees the same
// roots). Pass the compiler IN TREE: a copy elsewhere has no std/ beside it.
def main_run_parity(av: [str]) -> long {
    if (av.length < 1) {
        eputs("usage: ytest run-parity YCC [N]");
        return 2;
    };
    let ycc = yc.abs_path(av[0]);
    let limit = if (av.length > 1) { yt.num(av[1], 0) } else { 0 };
    let nat = yc.ROOT + "/test/y/native";
    let same = 0;
    let differ = 0;
    let b = yt.tmp("rp");
    foreach (src in yt.files(nat, "t", ".y")) {
        if (limit == 0 || same + differ < limit) {
            let base = fs.path_stem(src);
            let inp = if (fs.is_file(nat + "/" + base + ".stdin")) { nat + "/" + base + ".stdin" } else { "" };
            if (yc.compile(ycc, [], src, b, 120).code == 0) {
                def go(argv: [str]) -> yt.Res {
                    let c = yt.cmd(argv);
                    c.cwd = yc.ROOT;
                    c.stdin = inp;
                    c.timeout = 60;
                    yt.run(c)
                };
                let x = go([b]);
                let y = go([ycc, "run", src]);
                if (x.out == y.out && x.code == y.code) { same += 1; } else {
                    differ += 1;
                    print("  DIFFERS " + base + "  exit " + tostring(x.code) + " vs " + tostring(y.code) + "  "
                        + (if (x.out == y.out) { "stdout same" } else { "STDOUT DIFFERS" }));
                };
            };
        };
    };
    print("\n=== ycc run vs compile-and-execute: " + tostring(same) + " identical, " + tostring(differ) + " differ ===");
    if (differ == 0) { 0 } else { 1 }
};

// The meta pass must be the IDENTITY on a file with no block: `-E` dumps the
// source the lexer sees, so a block-free, directive-free file's dump is its own
// text (origin markers, comment-only lines and blanks dropped).
def strip_dump(text: str) -> [str] {
    let out: [str] = [];
    foreach (l in yt.lines(text)) {
        let i = l.index_of("\t//");
        let t = (if (i >= 0) { l[0:i] } else { l }).trim();
        if (t != "" && !t.starts_with("//")) { out += t; };
    };
    out
};

def directive(src: str) -> bool {
    foreach (l in yt.lines(src)) {
        let t = l.trim_start();
        foreach (d in ["import", "export", "embed"]) {
            if (t.starts_with(d) && (t.length == d.length || !(t[d.length] >= 97 && t[d.length] <= 122) && t[d.length] != 95)) { return true; };
        };
    };
    false
};

def main_meta_identity(av: [str]) -> long {
    if (av.length < 1) {
        eputs("usage: ytest meta-identity YCC [N]");
        return 2;
    };
    let ycc = yc.abs_path(av[0]);
    let limit = if (av.length > 1) { yt.num(av[1], 0) } else { 0 };
    let checked = 0;
    let same = 0;
    let skipped = 0;
    let diffs: [str] = [];
    foreach (d in ["src/y", "test/y", "examples", "bench"]) {
        foreach (f in yt.tree(yc.ROOT + "/" + d, ".y")) {
            let raw = yt.read(f);
            if (!raw.contains("#{") && (limit == 0 || checked < limit)) {
                if (directive(raw)) {
                    skipped += 1;
                } else {
                    let c = yt.cmd([ycc, "-E", f]);
                    c.cwd = yc.ROOT;
                    let r = yt.run(c);
                    if (r.code == 0) {
                        checked += 1;
                        let a = strip_dump(raw);
                        let b = strip_dump(r.out);
                        if (a == b) { same += 1; } else { diffs += yc.rel(f) + ": " + yt.first_diff(join(a, "\n"), join(b, "\n")); };
                    };
                };
            };
        };
    };
    print("\n=== meta identity: " + tostring(checked) + " block-free, import-free files; " + tostring(same) + " identical, "
        + tostring(diffs.length) + " differing (" + tostring(skipped) + " skipped: has import/export/embed, so the dump differs) ===");
    foreach (d in diffs[0:if (diffs.length > 10) { 10 } else { diffs.length }]) { print("  DIFFERS " + d); };
    if (diffs.length == 0) { 0 } else { 1 }
};

// Peak RSS (VmHWM, KB) of a command, read from /proc while it runs (the
// children's rusage would need a wait4 with rusage; the high-water mark is
// what /proc keeps).
def peak_kb(argv: [str]) -> long {
    let c = yt.cmd(argv);
    c.cwd = yc.ROOT;
    c.timeout = 0;
    let p = yt.start(c);
    let peak = 0;
    while (yt.alive(p)) {
        foreach (l in yt.lines(yt.read("/proc/" + tostring(p.pid) + "/status"))) {
            if (l.starts_with("VmHWM:")) {
                let v = yt.num(yt.words(l)[1], 0);
                if (v > peak) { peak = v; };
            };
        };
        yt.sleep_us(1000);
    };
    yt.wait(p);
    peak
};

def main_mem(av: [str]) -> long {
    if (av.length < 2) {
        eputs("usage: ytest mem YCC FILE...");
        return 2;
    };
    let ycc = yc.abs_path(av[0]);
    let b = yt.tmp("mem");
    foreach (f in av[1:]) {
        print("== " + f);
        print("compile " + tostring(peak_kb([ycc, f, "-o", b])) + " KB");
        print("run     " + tostring(peak_kb([ycc, "run", f])) + " KB");
        print("native  " + tostring(peak_kb([b])) + " KB");
    };
    0
};

export { main_check, main_corpus_diff, main_bench, main_bench_run, main_bench_ir, main_profile, main_fuzz, main_fmt,
    main_fmt_check, main_run_parity, main_meta_identity, main_mem };
