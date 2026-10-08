// su_ycc.y -- the built compiler as a program: what it prints, where, and with
// which exit, compared between ./ycc and the C copy wherever both can run.
import fs;
import yt;
import yc;

def base(p: str) -> str { fs.path_basename(p) };

// A compile/run in `dir` (`cwd`), stdout and stderr together.
def in_dir(dir: str, argv: [str], secs: long) -> yt.Res {
    let c = yt.cmd(argv);
    c.cwd = dir;
    c.merge = true;
    c.timeout = secs * yt.SCALE;
    yt.run(c)
};

// Each program compiled by the reference prints what the ycc-built binary prints.
let SELF_HOSTED = [
    "def f(n: long) -> long { if (n < 2) { n } else { self(n-1) + self(n-2) } }; print(f(10));",
    "let m = 0; let i = 1; while (i <= 10) { m = m + i; i = i + 1; }; print(m);",
    "def add(a: long, b: long) -> long { a + b }; print(add(20, 22));",
    "def outer() -> long { def h(x: long) -> long { x * 2 }; h(21) }; print(outer());",
];

def self_hosted(prog: str) {
    let f = yt.tmp("sh") + ".y";
    yt.write(f, prog + "\n");
    let r = yc.ref_run(f, "", 10 * yt.SCALE);
    let b = yt.tmp("bin");
    let c = yc.compile(yc.YCC, [], f, b, 120);
    let y = if (c.code == 0) { yc.run_bin(b, [], "", 10).out } else { "(ycc failed)" };
    yt.check("self-hosted: " + prog[0:40] + "...", r.out == y, "reference: " + r.out + " / self-built ycc: " + y);
};

// test/y/examples/ysh.y's `eval` shells out to the `ycc` beside the ysh binary;
// the examples suite runs ysh at EOF, so this is the only place it is driven.
def ysh() {
    let d = yt.tmp_dir("ysh");
    let ln = yt.cz(yc.YCC);
    let to = yt.cz(d + "/ycc");
    syscall(88, &ln[0], &to[0]);
    let c = yc.compile(yc.YCC, [], yc.ROOT + "/test/y/examples/ysh.y", d + "/ysh", 120);
    let ok = "(ycc failed on ysh.y)";
    let bad = "";
    if (c.code == 0) {
        ok = in_dir(d, [d + "/ysh", "-c", "eval print(6 * 7)"], 60).out;
        bad = in_dir(d, [d + "/ysh", "-c", "eval exec(\"true\")"], 60).out;
    };
    fs.remove_all(d);
    yt.check("ysh eval compiles and runs through ycc", ok.trim() == "42", "got: " + yt.clip(ok, 300));
    yt.check("ysh eval compiles with --no-exec", bad.contains("undefined function 'exec'") && bad.contains("compile failed"),
        "got: " + yt.clip(bad, 300));
};

// Warnings (lint.y): on stderr, an import's as its path from the main file's
// directory, the main file's own bare; the build goes on. -w drops them without
// changing a byte, and -S keeps them out of the listing.
def warnings(cc: str) {
    let tag = base(cc);
    let d = yt.tmp_dir("warn");
    fs.make_dirs(d + "/sub");
    yt.write(d + "/sub/lib.y", "def f(x: long) -> long {\n    let u = 1;\n    x\n};\nexport { f };\n");
    yt.write(d + "/main.y", "import lib from \"./sub/lib.y\";\ndef g() -> long {\n    let v = 2;\n    lib.f(3)\n};\nprint(g());\n");
    let want = "sub/lib.y:2:5: warning: unused variable 'u'\n3:5: warning: unused variable 'v'\n";
    let c = yt.cmd([cc, "-o", "a.out", "main.y"]);
    c.cwd = d;
    c.timeout = 120 * yt.SCALE;
    let r = yt.run(c);
    let run = yc.run_bin(d + "/a.out", [], "", 10).out;
    yt.check("warnings on stderr, the build goes on (" + tag + ")", r.code == 0 && r.out == "" && r.err == want && run == "3\n",
        "exit=" + tostring(r.code) + ", stdout '" + r.out + "', stderr '" + yt.clip(r.err, 300) + "', run '" + run + "'");
    let w = in_dir(d, [cc, "-w", "-o", "w.out", "main.y"], 120);
    yt.check("-w: no warnings, the same bytes (" + tag + ")", w.code == 0 && w.out == "" && yt.same_file(d + "/a.out", d + "/w.out"),
        "exit=" + tostring(w.code) + ", output '" + yt.clip(w.out, 300) + "'");
    c.argv = [cc, "-S", "main.y"];
    let s = yt.run(c);
    yt.check("-S: the listing on stdout, warnings on stderr (" + tag + ")",
        s.code == 0 && s.out != "" && !s.out.contains("warning") && s.err == want,
        "exit=" + tostring(s.code) + ", stderr '" + yt.clip(s.err, 300) + "'");
    fs.remove_all(d);
};

// A compiler found through PATH resolves its std units from /proc/self/exe, not
// from argv()[0] (then just "ycc"): a checkout reached by bare name and an
// installed copy with std/ beside it both find fs. From a neutral cwd, so
// nothing is picked up out of the source tree by accident.
def via_path(cc: str) {
    let tag = base(cc);
    let d = yt.tmp_dir("path");
    fs.make_dirs(d + "/work");
    yt.write(d + "/work/prog.y", "import fs;\nprint(fs.exists(\"/\"));\n");
    let bindir = fs.path_dirname(cc);
    let path = yt.env("PATH", "/usr/bin:/bin");
    def try_(name: str, dirs: str, what: str) {
        fs.remove_file(d + "/work/out");
        let c = yt.cmd([name, "prog.y", "-o", "out"]);
        c.cwd = d + "/work";
        c.merge = true;
        c.timeout = 120 * yt.SCALE;
        c.env = ["PATH=" + dirs + ":" + path];
        let r = yt.run(c);
        let run = yc.run_bin(d + "/work/out", [], "", 10).out;
        yt.check(what + " (" + tag + ")", r.code == 0 && r.out == "" && run == "true\n",
            "exit=" + tostring(r.code) + ", output '" + yt.clip(r.out, 300) + "', run '" + run + "'");
    };
    // (a) the compiler's own directory on PATH: std/ is src/y/std beside it
    try_(tag, bindir, "std units found through PATH in a checkout");
    // (b) an installed copy with std/ (and arch/, for a pack-less cycc) beside it
    let inst = d + "/install";
    fs.make_dirs(inst);
    fs.copy_file(cc, inst + "/ycc-installed");
    fs.set_mode(inst + "/ycc-installed", 0o755);
    yt.sh("cp -r " + yt.q(yc.ROOT + "/src/y/std") + " " + yt.q(inst + "/std") + " && cp -r "
        + yt.q(yc.ROOT + "/src/y/arch") + " " + yt.q(inst + "/arch"));
    try_("ycc-installed", inst, "std units found through PATH beside the binary");
    // the checkout's directory behind it on PATH: the module beside it wins
    try_("ycc-installed", inst + ":" + bindir, "an installed copy prefers its own std");
    fs.remove_all(d);
};

// Driver failures: the same line from both copies, and exit 1.
def cli_error(name: str, want: str, args: [str]) {
    foreach (cc in [yc.YCC, yc.CYCC]) {
        let c = yt.cmd([cc] + args);
        c.merge = true;
        c.timeout = 120 * yt.SCALE;
        let r = yt.run(c);
        let found = false;
        foreach (l in yt.lines(r.out)) {
            if (l == want) { found = true; };
        };
        yt.check("CLI error " + name + " (" + base(cc) + ")", r.code == 1 && found,
            "exit=" + tostring(r.code) + ", expected '" + want + "', got: " + yt.clip(r.out, 300));
    };
};

def cli_errors() -> [[str]] {
    let t01 = yc.ROOT + "/test/y/native/t01_arith.y";
    let w = yt.scratch() + "/wlevel.out";
    let tg = yt.scratch() + "/target.out";
    [["unknown flag", "ycc: unknown flag '--bad' (see ycc -h)", "--bad"],
     ["-o with an empty path", "ycc: -o needs a path, got ''", "-o", "", t01],
     ["-o last, with no path", "ycc: -o needs an argument", t01, "-o"],
     ["-W without a level", "ycc: -W needs a warning level (0, 1 or 2)", "-o", w, t01, "-W"],
     ["-W with a bad level", "ycc: -W needs a warning level (0, 1 or 2), got 'x'", "-W", "x", "-o", w, t01],
     ["-W above 2", "ycc: -W needs a warning level (0, 1 or 2), got '3'", "-W", "3", "-o", w, t01],
     ["-W that would wrap the scan", "ycc: -W needs a warning level (0, 1 or 2), got '99999999999999999999'", "-W",
      "99999999999999999999", "-o", w, t01],
     // --target: both spellings; anything after --target is its name, so only
     // the flag LAST reaches "needs a name"
     ["--target without a name", "ycc: --target needs a name (linux, windows)", "-o", tg, t01, "--target"],
     ["--target with an unknown name", "ycc: unknown target 'plan9' (linux, windows, kernel)", "--target=plan9", "-o", tg, t01],
     ["no input file", "error: no input file (see ycc -h)"],
     ["multiple input files", "error: ycc compiles one program; use imports to combine files", t01,
      yc.ROOT + "/test/y/native/t02_recursion.y"],
     ["cannot read input", "error: cannot read file '/no-such-cov-ycc-input.y'", "/no-such-cov-ycc-input.y"],
     // a directory opens for reading but read(2) refuses it; it once compiled
     // into an empty executable
     ["input is a directory", "error: cannot read file '" + yt.scratch() + "'", yt.scratch()],
     ["assembly write failure", "error: writing '/nonexistent/dir/out' failed", "-S", "-o", "/nonexistent/dir/out", t01],
     ["executable write failure", "error: writing '/nonexistent/dir/out' failed", "-o", "/nonexistent/dir/out", t01],
     // /dev/full takes the bytes and fails at the flush: the C twin buffers and
     // once ignored fclose's answer, exiting 0 with nothing written
     ["assembly write failure at the flush", "error: writing '/dev/full' failed", "-S", "-o", "/dev/full", t01],
     ["executable write failure at the flush", "error: writing '/dev/full' failed", "-o", "/dev/full", t01]]
};

// A chain of 33 nested imports is fatal (a cycle stops at `seen` first).
def import_depth() {
    let d = yt.tmp_dir("depth");
    for i in 0..32 {
        yt.write(d + "/d" + tostring(i) + ".y", "import d" + tostring(i + 1) + ";\n");
    };
    yt.write(d + "/d32.y", "");
    yt.write(d + "/main.y", "import d0;\nprint(\"unreachable\");\n");
    cli_error("import depth", "error: native import depth exceeded (cycle?)", ["-o", d + "/a.out", d + "/main.y"]);
    let g = d + "/p.y";
    yt.write(g, "print(1);\n");
    cli_error("gc mode", "ycc: --gc wants auto, always or never, got 'bogus'", ["--gc=bogus", "-o", d + "/a.out", g]);
    fs.remove_all(d);
};

// Running out of memory looks the same from both copies: the same text, on the
// same stream, with the same status. 120 000 tiny functions need well over the
// 400 MB cap, which still leaves a dynamically linked cycc room to load.
def oom() {
    let d = yt.tmp_dir("oom");
    let src: [str] = [];
    for i in 0..120000 {
        src += "def f" + tostring(i) + "(a: long) -> long { let s = 0; s += a; s * 2; }\n";
    };
    src += "print(f0(1));\n";
    yt.write(d + "/big.y", join(src, ""));
    let seen = 0;
    foreach (cc in [yc.YCC, yc.CYCC]) {
        let c = yt.cmd([cc, "-o", d + "/big.bin", d + "/big.y"]);
        c.mem_kb = 409600;
        c.timeout = 120 * yt.SCALE;
        let r = yt.run(c);
        if (r.code == 1 && r.out == "runtime error: out of memory\n" && r.err == "") {
            seen += 1;
        } else {
            yt.fail("OOM report (" + base(cc) + ")", "exit=" + tostring(r.code) + ", out='" + yt.clip(r.out, 200) + "', err='"
                + yt.clip(r.err, 200) + "'");
        };
    };
    if (seen == 2) { yt.pass("OOM report identical from both copies"); };
    fs.remove_all(d);
};

// 300 undefined variables answer with 300 lines, one each, in position order:
// the dedup is keyed by position, so a dropped or repeated one shows.
def many_errors(cc: str) {
    let d = yt.tmp_dir("many");
    let src: [str] = [];
    for i in 0..300 {
        src += "def f" + tostring(i) + "() -> long { missing" + tostring(i) + " }\n";
    };
    yt.write(d + "/many.y", join(src, ""));
    let r = yc.compile(cc, [], d + "/many.y", d + "/many.bin", 120);
    let ls = yt.lines(r.out);
    let n = 0;
    foreach (l in ls) {
        if (l.contains("undefined variable 'missing")) { n += 1; };
    };
    let first = if (ls.length > 0) { ls[0] } else { "" };
    let last = if (ls.length > 0) { ls[ls.length - 1] } else { "" };
    yt.check("300 errors, one per position (" + base(cc) + ")",
        r.code == 1 && n == 300 && first == "1:20: error: undefined variable 'missing0'"
        && last == "300:22: error: undefined variable 'missing299'",
        "exit=" + tostring(r.code) + ", lines=" + tostring(n) + ", first='" + first + "', last='" + last + "'");
    fs.remove_all(d);
};

// A fifo has no size to ask for, so the whole-file path cannot be used and the
// stream is read to its end; the C copy once said "cannot read file". One fifo
// per compiler, and the two assemblies must match.
def fifo_asm(cc: str, out: str) -> long {
    let d = yt.tmp_dir("fifo");
    let p = yt.cz(d + "/in.y");
    syscall(259, -100, &p[0], 4480, 0);
    let text = yt.read(yc.ROOT + "/test/y/native/t01_arith.y");
    let w = fork { fs.write_file(d + "/in.y", text); };
    let c = yt.cmd([cc, "-S", d + "/in.y", "-o", out]);
    c.timeout = 60 * yt.SCALE;
    let r = yt.run(c);
    wait_pid(w);
    fs.remove_all(d);
    r.code
};

def fifo() {
    let ok = 0;
    foreach (cc in [yc.YCC, yc.CYCC]) {
        let ec = fifo_asm(cc, yt.scratch() + "/fifo_" + base(cc) + ".s");
        if (ec == 0) { ok += 1; } else { yt.fail("read a fifo (" + base(cc) + ")", "exit " + tostring(ec) + " from -S on a fifo"); };
    };
    if (ok == 2 && yt.same_file(yt.scratch() + "/fifo_" + base(yc.YCC) + ".s", yt.scratch() + "/fifo_" + base(yc.CYCC) + ".s")) {
        yt.pass("fifo read identical from both copies");
    };
};

// `ycc -E` dumps the source the lexer sees; re-compiling the dump gives the
// same binary, and a meta file's dump holds the GENERATED text.
def meta_dump(prog: str, tag: str) {
    let d = yt.tmp_dir("meta");
    let a = yc.compile(yc.YCC, [], prog, d + "/a", 120);
    if (a.code != 0) {
        yt.fail(tag + " compile", yt.clip(a.out, 200));
        return;
    };
    let c = yt.cmd([yc.YCC, "-E", prog]);
    c.out = d + "/dump.y";
    c.timeout = 120 * yt.SCALE;
    let e = yt.run(c);
    if (e.code != 0) {
        yt.fail(tag + " -E", "exit " + tostring(e.code));
        return;
    };
    let b = yc.compile(yc.YCC, [], d + "/dump.y", d + "/b", 120);
    if (b.code != 0) {
        yt.fail(tag + " recompile the dump", yt.clip(b.out, 200));
        return;
    };
    yt.check(tag + ": recompiling the -E dump gives the same bytes", yt.same_file(d + "/a", d + "/b"),
        "the binary from the dump differs");
    fs.remove_all(d);
};

// `ycc run FILE -- ARG...`: everything after `--` is the program's argv.
def run_args(cc: str) {
    let d = yt.tmp_dir("run");
    yt.write(d + "/p.y", "let a = argv();\nprint(tostring(len(a)));\nlet i = 1;\nwhile (i < len(a)) { print(a[i]); i = i + 1; };\n");
    let r = in_dir(d, [cc, "run", "p.y", "--", "one", "two three"], 60);
    yt.check("run -- passes the program its argv (" + base(cc) + ")", r.out == "3\none\ntwo three\n", "got '" + yt.clip(r.out, 200) + "'");
    fs.remove_all(d);
};

// heap_used() does not move with how argv[0] is spelled: one binary, three
// spellings, one number.
def heap_paths(cc: str) {
    let tag = base(cc);
    let d = yt.tmp_dir("heap");
    yt.write(d + "/p.y", "print(heap_used());\n");
    in_dir(d, [cc, "p.y", "-o", "p"], 60);
    if (!fs.is_file(d + "/p")) {
        yt.fail("heap_used -- does not move with argv[0] (" + tag + ")", "no binary");
        return;
    };
    let a = in_dir(d, ["./p"], 10).out;
    let b = in_dir(d, ["./p"], 10).out;
    let c = yc.run_bin(d + "/p", [], "", 10).out;
    let long_ = d + "/" + "x".repeat(90);
    fs.copy_file(d + "/p", long_);
    fs.set_mode(long_, 0o755);
    let l = yc.run_bin(long_, [], "", 10).out;
    yt.check("heap_used -- same number as ./, by absolute path and a 90-char name (" + tag + "): " + a.trim(),
        a == b && a == c && a == l, "./=" + a + " abs=" + c + " long=" + l);
    fs.remove_all(d);
};

def cases() -> [yt.Case] {
    let s = "ycc";
    let cs: [yt.Case] = [];
    foreach (p in SELF_HOSTED) { cs += yt.case_of(s, p, () => self_hosted(p)); };
    cs += yt.case_of(s, "ysh", ysh);
    foreach (cc in [yc.YCC, yc.CYCC]) {
        cs += yt.case_of(s, "warnings", () => warnings(cc));
        cs += yt.case_of(s, "PATH", () => via_path(cc));
    };
    foreach (e in cli_errors()) { cs += yt.case_of(s, e[0], () => cli_error(e[0], e[1], e[2:])); };
    cs += yt.case_of(s, "import depth", import_depth);
    cs += yt.case_of(s, "oom", oom);
    foreach (cc in [yc.YCC, yc.CYCC]) { cs += yt.case_of(s, "many", () => many_errors(cc)); };
    cs += yt.case_of(s, "fifo", fifo);
    let nat = yc.ROOT + "/test/y/native/";
    cs += yt.case_of(s, "-E", () => meta_dump(nat + "t01_arith.y", "-E dump"));
    // a meta file whose top level prints nothing (it would print to ycc's stdout
    // before the dump), and one with a MID-TOKEN block
    cs += yt.case_of(s, "-E meta", () => meta_dump(nat + "t197_meta_field_name_ok.y", "-E dump of a meta file"));
    cs += yt.case_of(s, "-E mid", () => meta_dump(nat + "t200_meta_mid_token.y", "-E dump of a mid-token meta file"));
    foreach (cc in [yc.YCC, yc.CYCC]) {
        cs += yt.case_of(s, "run --", () => run_args(cc));
        cs += yt.case_of(s, "heap", () => heap_paths(cc));
    };
    cs
};

export { cases };
