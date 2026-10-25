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
    yt.check("ysh eval compiles with --exec=off", bad.contains("undefined function 'exec'") && bad.contains("compile failed"),
        "got: " + yt.clip(bad, 300));
};

// Warnings (lint.y): on stderr, an import's as its path from the main file's
// directory, the main file's own bare; the build goes on. --warnings=none drops
// them without changing a byte, and --emit=asm keeps them out of the listing.
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
    let w = in_dir(d, [cc, "--warnings=none", "-o", "w.out", "main.y"], 120);
    yt.check("-w: no warnings, the same bytes (" + tag + ")", w.code == 0 && w.out == "" && yt.same_file(d + "/a.out", d + "/w.out"),
        "exit=" + tostring(w.code) + ", output '" + yt.clip(w.out, 300) + "'");
    c.argv = [cc, "--emit=asm", "main.y"];
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
    [["optimization missing value", "ycc: --optimize needs a value", "--optimize"],
     ["optimization invalid value", "ycc: --optimize wants speed or size, got '2'", "--optimize=2"],
     ["optimization conflicting goals", "ycc: size and speed optimizations are mutually exclusive", "--optimize=size", "--optimize=speed"],
     ["optimization reversed goals", "ycc: size and speed optimizations are mutually exclusive", "--optimize=speed", "--optimize=size"],
     ["build optimization conflicting goals", "ycc: size and speed optimizations are mutually exclusive", "build", "--optimize=size", "--optimize=speed"],
     ["bad output kind", "ycc: --emit wants asm, source or wat, got 'bad'", "--emit=bad"],
     ["conflicting output kinds", "ycc: choose one output kind: asm, source or wat", "--emit=asm", "--emit=source"],
     ["run needs executable", "ycc: run needs executable output", "run", "--emit=asm"],
     ["bad warnings", "ycc: --warnings wants none, default, extra, all or fix, got '3'", "--warnings=3"],
     ["bad regions", "ycc: --regions wants auto or off, got 'bad'", "--regions=bad"],
     ["bad exec", "ycc: --exec wants on or off, got 'bad'", "--exec=bad"],
     ["bad std", "ycc: --std wants pack or source, got 'bad'", "--std=bad"],
     ["empty named output", "ycc: --output needs a path", "--output="],
     ["build refuses assembly", "ycc: build accepts executable build options only (see ycc --help)", "build", "--emit=asm"],
     ["unknown flag", "ycc: unknown flag '--bad' (see ycc -h)", "--bad"],
     ["-o with an empty path", "ycc: -o needs a path, got ''", "-o", "", t01],
     ["-o last, with no path", "ycc: -o needs an argument", t01, "-o"],
     ["-W is gone", "ycc: -W is now --warnings=extra or --warnings=all", "-W", "1", "-o", w, t01],
     ["-t is gone", "ycc: -t is now --time", "-t", "-o", w, t01],
     ["--no-gc is gone", "ycc: --no-gc is now --gc=never", "--no-gc", "-o", w, t01],
     ["--gc-stress is gone", "ycc: --gc-stress is now --gc=stress", "--gc-stress", "-o", w, t01],
     ["--no-auto-regions is gone", "ycc: --no-auto-regions is now --regions=off", "--no-auto-regions", "-o", w, t01],
     ["--no-exec is gone", "ycc: --no-exec is now --exec=off", "--no-exec", "-o", w, t01],
     ["--std-src is gone", "ycc: --std-src is now --std=source", "--std-src", "-o", w, t01],
     ["--fix is gone", "ycc: --fix is now --warnings=fix", "--fix", "-o", w, t01],
     ["--web-stack is gone", "ycc: --web-stack is now --web=stack=SIZE", "--web-stack=1M", "-o", w, t01],
     ["--subsystem=windows is gone", "ycc: --subsystem=windows is now --subsystem=gui", "--subsystem=windows", "-o", w, t01],
     ["--emit=page is gone", "ycc: --emit=page is now --web-page", "--emit=page", "-o", w, t01],
     ["--emit=exe is the default", "ycc: --emit wants asm, source or wat (the executable is the default)", "--emit=exe", "-o", w, t01],
     ["bad web page kind", "ycc: --web-page wants site or html, got 'bogus'", "--target=web", "--web-page=bogus", "-o", w, t01],
     ["conflicting page and emit", "ycc: choose one output kind: asm, source, wat or --web-page", "--emit=asm", "--web-page", "-o", w, t01],
     ["--one outside build", "ycc: --one is only for ycc build", "--one=x", t01],
     ["--arch without an arch", "ycc: --arch needs an arch (x64, aarch64)", "-o", tg, t01, "--arch"],
     ["-w is gone", "ycc: -w is now --warnings=none", "-w", "-o", w, t01],
     ["-S is gone", "ycc: -S is now --emit=asm", "-S", "-o", w, t01],
     ["-E is gone", "ycc: -E is now --emit=source", "-E", "-o", w, t01],
     ["--kernel is gone", "ycc: --kernel is now --target=kernel", "--kernel", "-o", w, t01],
     // --target: both spellings; anything after --target is its name, so only
     // the flag LAST reaches "needs a name"
     ["--target without a name", "ycc: --target needs an OS (linux, win, kernel, web)", "-o", tg, t01, "--target"],
     ["--target with an unknown name", "ycc: unknown target 'plan9' (linux, win, kernel, web)", "--target=plan9", "-o", tg, t01],
     ["--target names the old spelling", "ycc: --target=windows is now --target=win", "--target=windows", "-o", tg, t01],
     ["--target names the old arch", "ycc: --target=aarch64 is now --target=linux --arch=aarch64", "--target=aarch64", "-o", tg, t01],
     ["--arch with an unknown name", "ycc: unknown arch 'x86' (x64, aarch64)", "--arch=x86", "-o", tg, t01],
     ["--arch conflicts", "ycc: conflicting --arch values (x64, aarch64)", "--arch=x64", "--arch=aarch64", "-o", tg, t01],
     ["--arch does not fit win", "ycc: --target=win is x64 only", "--target=win", "--arch=aarch64", "-o", tg, t01],
     ["--arch does not fit web", "ycc: --target=web is wasm32 (--arch does not apply)", "--target=web", "--arch=x64", "-o", tg, t01],
     ["--subsystem with an unknown name", "ycc: unknown subsystem 'bogus' (console, gui)", "--subsystem=bogus", "-o", tg, t01],
     // the web target's own flags and refusals (S1); su_web runs the programs
     ["emit page on linux", "ycc: --web-page is only for --target=web", "--web-page", "-o", tg, t01],
     ["emit html on linux", "ycc: --web-page is only for --target=web", "--web-page=html", "-o", tg, t01],
     ["emit wat on linux", "ycc: --emit=wat is only for --target=web", "--emit=wat", "-o", tg, t01],
     ["web stack not a size", "ycc: --web: 'stack' wants a byte size from 64K to 256M (a K or M suffix is allowed), got 'big'", "--target=web", "--web=stack=big", "-o", tg, t01],
     ["web stack out of range", "ycc: --web: 'stack' wants a byte size from 64K to 256M (a K or M suffix is allowed), got '1K'", "--target=web", "--web=stack=1K", "-o", tg, t01],
     ["web key without =", "ycc: --web wants KEY=VALUE, got 'nope'", "--target=web", "--web=nope", "-o", tg, t01],
     ["pack on web", "ycc: --pack is Linux ELF only (--target=web writes a wasm module)", "--target=web", "--pack", "-o", tg, t01],
     ["obfuscate on web", "ycc: --obfuscate is not available for --target=web", "--target=web", "--obfuscate", "-o", tg, t01],
     ["target conflicts", "ycc: conflicting --target values (web, kernel)", "--target=web", "--target=kernel", "-o", tg, t01],
     ["subsystem on web", "ycc: --subsystem=gui is not available for --target=web", "--target=web", "--subsystem=gui", "-o", tg, t01],
     ["page directory failure", "ycc: cannot make the page directory '/nonexistent/yweb'", "--target=web", "--web-page", "-o", "/nonexistent/yweb", yc.ROOT + "/test/web/w001_hello.y"],
     ["no input file", "error: no input file (see ycc -h)"],
     ["multiple input files", "error: ycc compiles one program; use imports to combine files", t01,
      yc.ROOT + "/test/y/native/t02_recursion.y"],
     ["cannot read input", "error: cannot read file '/no-such-cov-ycc-input.y'", "/no-such-cov-ycc-input.y"],
     // a directory opens for reading but read(2) refuses it; it once compiled
     // into an empty executable
     ["input is a directory", "error: cannot read file '" + yt.scratch() + "'", yt.scratch()],
     ["assembly write failure", "error: writing '/nonexistent/dir/out' failed", "--emit=asm", "-o", "/nonexistent/dir/out", t01],
     ["executable write failure", "error: writing '/nonexistent/dir/out' failed", "-o", "/nonexistent/dir/out", t01],
     // /dev/full takes the bytes and fails at the flush: the C twin buffers and
     // once ignored fclose's answer, exiting 0 with nothing written
     ["assembly write failure at the flush", "error: writing '/dev/full' failed", "--emit=asm", "-o", "/dev/full", t01],
     ["executable write failure at the flush", "error: writing '/dev/full' failed", "-o", "/dev/full", t01]]
};

// -o to a device: the bytes go out and there is no mode to set, so it succeeds.
def output_to_device() {
    let t01 = yc.ROOT + "/test/y/native/t01_arith.y";
    foreach (cc in [yc.YCC, yc.CYCC]) {
        let c = yt.cmd([cc, "-o", "/dev/null", t01]);
        c.merge = true;
        c.timeout = 120 * yt.SCALE;
        let r = yt.run(c);
        yt.check("-o /dev/null (" + base(cc) + ")", r.code == 0, "exit=" + tostring(r.code) + ": " + yt.clip(r.out, 300));
    };
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
    cli_error("gc mode", "ycc: --gc wants never, auto, always or stress, got 'bogus'", ["--gc=bogus", "-o", d + "/a.out", g]);
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
    let c = yt.cmd([cc, "--emit=asm", d + "/in.y", "-o", out]);
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
        if (ec == 0) { ok += 1; } else { yt.fail("read a fifo (" + base(cc) + ")", "exit " + tostring(ec) + " from --emit=asm on a fifo"); };
    };
    if (ok == 2 && yt.same_file(yt.scratch() + "/fifo_" + base(yc.YCC) + ".s", yt.scratch() + "/fifo_" + base(yc.CYCC) + ".s")) {
        yt.pass("fifo read identical from both copies");
    };
};

// `ycc --emit=source` dumps the source the lexer sees; re-compiling the dump gives the
// same binary, and a meta file's dump holds the GENERATED text.
def meta_dump(prog: str, tag: str) {
    let d = yt.tmp_dir("meta");
    let a = yc.compile(yc.YCC, [], prog, d + "/a", 120);
    if (a.code != 0) {
        yt.fail(tag + " compile", yt.clip(a.out, 200));
        return;
    };
    let c = yt.cmd([yc.YCC, "--emit=source", prog]);
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
    yt.check(tag + ": recompiling the --emit=source dump gives the same bytes", yt.same_file(d + "/a", d + "/b"),
        "the binary from the dump differs");
    fs.remove_all(d);
};

// ── the build a meta generator sees (S15) ───────────────────────────────
// --emit=source renders the target fields, the command line reaches -D/-U/--meta-arg,
// escaping survives both quotes, and a project's manifest defines lose to the
// command line in every child package.

def meta_targets() -> void {
    let f = yc.ROOT + "/test/meta/targets.y";
    let rows = [
        { flags: ["--target=linux"], t: "linux", os: "linux", arch: "x64" },
        { flags: ["--target=win"], t: "win", os: "windows", arch: "x64" },
        { flags: ["--target=linux", "--arch=aarch64"], t: "linux", os: "linux", arch: "aarch64" },
        { flags: ["--target=kernel"], t: "kernel", os: "none", arch: "x64" },
        { flags: ["--target=web"], t: "web", os: "web", arch: "wasm32" }];
    foreach (r in rows) {
        let c = yt.cmd([yc.YCC, "--emit=source"] + r.flags + [f]);
        c.merge = true;
        c.timeout = 120 * yt.SCALE;
        let e = yt.run(c);
        let q = chr(34);
        let w1 = "const YCC_TARGET = " + q + r.t + q + ";";
        let w2 = "const YCC_OS = " + q + r.os + q + ";";
        let w3 = "const YCC_ARCH = " + q + r.arch + q + ";";
        yt.check("meta --emit=source " + r.t + " " + r.arch,
            e.code == 0 && e.out.contains(w1) && e.out.contains(w2) && e.out.contains(w3),
            "exit=" + tostring(e.code) + ": " + yt.clip(e.out, 300));
    };
};

def meta_inputs() -> void {
    let d = yt.tmp_dir("minput");
    let f = yc.ROOT + "/test/meta/inputs.y";
    let val = "a" + chr(34) + "b" + chr(92) + "c" + chr(10) + "d é";
    let bin = d + "/in";
    let c = yc.compile(yc.YCC, ["-D", "TEXT=" + val, "-DDEFAULT", "--define", "EQ=a=b",
        "-D", "GONE", "-U", "GONE", "--meta-arg", "one", "--meta-arg", "two words"], f, bin, 120);
    if (c.code != 0) {
        yt.fail("meta inputs compile", yt.clip(c.out, 300));
        fs.remove_all(d);
        return;
    };
    let want = val + chr(10) + "1" + chr(10) + "a=b" + chr(10) + "DEFAULT,EQ,TEXT" + chr(10)
        + "no" + chr(10) + "2" + chr(10) + "one" + chr(10) + "two words" + chr(10);
    let r = yc.run_bin(bin, [], "", 10);
    yt.check("meta -D/-U/--meta-arg/escaping", r.code == 0 && r.out == want,
        "got: " + yt.clip(r.out, 300));
    fs.remove_all(d);
};

// The new flags are the built compiler's: the C copy learns them when its seed
// is refreshed, so this check does not run both.
def meta_cli_errors() -> void {
    let t01 = yc.ROOT + "/test/y/native/t01_arith.y";
    let w = yt.scratch() + "/meta-cli.out";
    let cases = [
        ["-D bad name", "ycc: -D wants NAME or NAME=VALUE, got '1BAD'", "-D", "1BAD", "-o", w, t01],
        ["--define bad name", "ycc: -D wants NAME or NAME=VALUE, got 'A-B'", "--define", "A-B", "-o", w, t01],
        ["-U bad name", "ycc: -U wants NAME, got 'A=B'", "-U", "A=B", "-o", w, t01],
        ["-D without a name", "ycc: -D wants NAME or NAME=VALUE", "-o", w, t01, "-D"],
        ["--meta-arg without a value", "ycc: --meta-arg needs a value", "-o", w, t01, "--meta-arg"]];
    foreach (e in cases) {
        let c = yt.cmd([yc.YCC] + e[2:]);
        c.merge = true;
        c.timeout = 120 * yt.SCALE;
        let r = yt.run(c);
        let found = false;
        foreach (l in yt.lines(r.out)) {
            if (l == e[1]) { found = true; };
        };
        yt.check("meta CLI error " + e[0], r.code == 1 && found,
            "exit=" + tostring(r.code) + ", expected '" + e[1] + "', got: " + yt.clip(r.out, 300));
    };
};

// The injected names may be called from a block, never defined. One case per
// family: the build record and const, and a helper.
def meta_reserved() -> void {
    let d = yt.tmp_dir("mres");
    let cases = [["def YCC(a: long) -> long { a };", "YCC"],
        ["type YccBuild = { a: long };", "YccBuild"],
        ["def ycc_quote(s: str) -> str { s };", "ycc_quote"]];
    foreach (e in cases) {
        yt.write(d + "/r.y", e[0] + chr(10) + "let x = #{ \"1\" }#;" + chr(10));
        let c = yc.compile(yc.YCC, [], d + "/r.y", d + "/r", 120);
        yt.check("meta reserved " + e[1],
            c.code == 1 && c.out.contains("'" + e[1] + "' is reserved: the meta pass injects it into the generator"),
            yt.clip(c.out, 240));
    };
    fs.remove_all(d);
};

def meta_line_count(s: str, want: str) -> long {
    let n = 0;
    foreach (l in s.split("\n")) {
        if (l.trim() == want) { n += 1; };
    };
    n
};

def meta_project() -> void {
    let d = yt.tmp_dir("mproj");
    yt.sh("cp -r " + yt.q(yc.ROOT + "/test/meta/app") + " " + yt.q(d + "/app"));
    let bin = d + "/app/build/app";
    let b1 = in_dir(d, [yc.YCC, "build", "app"], 240);
    let r1 = if (fs.is_file(bin)) { yc.run_bin(bin, [], "", 10).out } else { "" };
    yt.check("meta build: manifest defines", b1.code == 0 && r1 == "1" + chr(10) + "yes" + chr(10) + chr(10),
        "exit=" + tostring(b1.code) + " got: " + yt.clip(b1.out + " / " + r1, 300));
    let args = [yc.YCC, "build", "app", "-D", "LEVEL=2", "-U", "GONE",
        "--meta-arg", "x", "--meta-arg", "y z"];
    let b2 = in_dir(d, args, 240);
    let r2 = if (fs.is_file(bin)) { yc.run_bin(bin, [], "", 10).out } else { "" };
    yt.check("meta build: command line wins in every package", b2.code == 0 && r2 == "2" + chr(10) + "no" + chr(10) + "x,y z" + chr(10),
        "exit=" + tostring(b2.code) + " got: " + yt.clip(b2.out + " / " + r2, 300));
    // A child that did not read the -D would key its object differently and the
    // parent would compile the package a second time.
    yt.check("meta build: the children saw the defines",
        meta_line_count(b2.out, "compiling liba") == 1 && meta_line_count(b2.out, "compiling libb") == 1,
        yt.clip(b2.out, 300));
    let b3 = in_dir(d, [yc.YCC, "build", "app", "-D", "LEVEL=3", "-U", "GONE",
        "--meta-arg", "x", "--meta-arg", "y z"], 240);
    yt.check("meta build: a define change rebuilds", b3.code == 0 && b3.out.contains("compiling libb"),
        yt.clip(b3.out, 300));
    // A [defines] key is the -D spelling.
    yt.sh("mkdir -p " + yt.q(d + "/bad"));
    yt.write(d + "/bad/y.toml", "[package]\nname = \"bad\"\n[defines]\nA-B = \"1\"\n");
    let eb = in_dir(d, [yc.YCC, "build", "bad"], 120);
    yt.check("meta build: a bad define name", eb.code == 1 && eb.out.contains("define name 'A-B' is not an identifier"),
        "exit=" + tostring(eb.code) + ": " + yt.clip(eb.out, 300));
    fs.remove_all(d);
};

// ── target overlays ────────────────────────────────────────
// test/y/ycc/overlay holds one pair per behaviour; the suite copies it and
// compiles from inside the copy, so the messages name the same relative paths
// a user would see.
def overlays() -> void {
    let d = yt.tmp_dir("ovl");
    yt.sh("cp -r " + yt.q(yc.ROOT + "/test/y/ycc/overlay") + " " + yt.q(d + "/o"));
    let o = d + "/o";
    let c = in_dir(o, [yc.YCC, "--target=linux", "-o", "main", "main.y"], 120);
    let got = if (c.code == 0) { yc.run_bin(o + "/main", [], "", 10).out } else { "" };
    yt.check("overlay: replaces a def and a const, widens a record, appends a def and an export",
        c.code == 0 && got == "linux" + chr(10) + "keep" + chr(10) + "2" + chr(10) + "new" + chr(10),
        "exit=" + tostring(c.code) + " got: " + yt.clip(c.out + " / " + got, 300));
    let w = in_dir(o, [yc.YCC, "--emit=source", "--target=win", "win.y"], 120);
    yt.check("overlay: only the current target's file is merged",
        w.code == 0 && w.out.contains("\"base\"") && !w.out.contains("\"linux\"") && !w.out.contains("\"new\""),
        yt.clip(w.out, 300));
    let e = in_dir(o, [yc.YCC, "--emit=source", "--target=linux", "main.y"], 120);
    yt.check("overlay: --emit=source keeps each file's own origins",
        e.code == 0 && e.out.contains("m.linux.y:3") && e.out.contains("m.y:4"),
        yt.clip(e.out, 400));
    // a root file that is itself the overlay
    let r = in_dir(o, [yc.YCC, "--target=linux", "-o", "root", "root.linux.y"], 120);
    let rg = if (r.code == 0) { yc.run_bin(o + "/root", [], "", 10).out } else { "" };
    yt.check("overlay: a root file can be the overlay", r.code == 0 && rg == "root-linux" + chr(10),
        "exit=" + tostring(r.code) + " got: " + yt.clip(r.out + " / " + rg, 300));
    // its own meta block, its own import, a new const
    let m = in_dir(o, [yc.YCC, "--target=linux", "-o", "meta", "meta_main.y"], 120);
    let mg = if (m.code == 0) { yc.run_bin(o + "/meta", [], "", 10).out } else { "" };
    yt.check("overlay: a meta block and imports work, and a new const is visible",
        m.code == 0 && mg == "linux" + chr(10) + "linux" + chr(10) + "7" + chr(10),
        "exit=" + tostring(m.code) + " got: " + yt.clip(m.out + " / " + mg, 300));
    // a multi-line export statement gains the overlay's names, and the rest of
    // the statement is not parsed twice
    let x = in_dir(o, [yc.YCC, "--target=linux", "-o", "multi", "main2.y"], 120);
    let xg = if (x.code == 0) { yc.run_bin(o + "/multi", [], "", 10).out } else { "" };
    yt.check("overlay: a multi-line export statement gains the overlay's names",
        x.code == 0 && xg == "linux" + chr(10) + "6" + chr(10),
        "exit=" + tostring(x.code) + " got: " + yt.clip(x.out + " / " + xg, 300));
    // every S14 diagnostic
    let cases = [
        ["signature", "e_sig.y", "overlay e_sig.linux.y:1: 'f' changes the signature of e_sig.y:1"],
        ["field", "e_field.y", "overlay e_field.linux.y:1: type 'T' must keep every field of e_field.y's (it may add fields)"],
        ["union", "e_union.y", "overlay e_union.linux.y:1: a union type cannot be replaced"],
        ["statement", "e_stmt.y", "overlay e_stmt.linux.y:1: an overlay holds only declarations"],
        ["two on a line", "e_two.y", "overlay: e_two.y:1 declares more than one name on a line; split it to replace 'f'"],
        ["no base", "e_nobase.linux.y", "overlay e_nobase.linux.y has no base e_nobase.y"]];
    foreach (cs in cases) {
        let x = in_dir(o, [yc.YCC, "--target=linux", "-o", "e_" + cs[0], cs[1]], 60);
        yt.check("overlay error: " + cs[0], x.code == 1 && x.out.contains(cs[2]),
            "exit=" + tostring(x.code) + ": " + yt.clip(x.out, 300));
    };
    // a diagnostic in replaced text points into the overlay file
    let b = in_dir(o, [yc.YCC, "--target=linux", "-o", "bad", "bad.y"], 60);
    yt.check("overlay: a diagnostic points into the overlay",
        b.code == 1 && b.out.contains("bad.linux.y:1:1: error:"), yt.clip(b.out, 300));
    // mutated overlays: a diagnostic or a build, never a crash or a hang
    let orig = yt.read(o + "/m.linux.y");
    let muts = [orig[:40], orig.replace("def f", "x f"), orig + "garbage\n", "",
        orig.replace("def g", "def g\ndef g"), orig.replace("const N", "const N = =")];
    let bad = "";
    let i = 0;
    while (i < len(muts)) {
        yt.write(o + "/m.linux.y", muts[i]);
        let x = in_dir(o, [yc.YCC, "--target=linux", "-o", "fz", "main.y"], 30);
        if (x.timed_out || !(x.code == 0 || x.code == 1)) {
            bad += " mutation " + tostring(i) + ": exit " + tostring(x.code) + " " + yt.clip(x.out, 120);
        };
        i++;
    };
    yt.write(o + "/m.linux.y", orig);
    yt.check("overlay: mutated overlays are a diagnostic or a build, never a crash", bad == "", bad);
    // A by-name module inside a package keeps its scope through the merge: the
    // overlay's file id must carry the module name (origin.mods), or the
    // base's globals read as undefined.
    let pb = in_dir(o + "/pkg", [yc.YCC, "build", "--target=linux"], 240);
    let pout = if (pb.code == 0) { yc.run_bin(o + "/pkg/build/p", [], "", 10).out } else { "" };
    yt.check("overlay: a package module keeps its scope through the merge",
        pb.code == 0 && pout == "2" + chr(10),
        "exit=" + tostring(pb.code) + " got: " + yt.clip(pb.out + " / " + pout, 300));
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

// The source fixer is exposed by the Y driver. Run it on copies only: unsafe
// if-chain advice used to remove a side-effecting else, and same-line chains
// could revisit the first else until they exhausted the compiler's heap.
def lint_fix_safety() -> void {
    let d = yt.tmp_dir("lint-fix");
    let file = d + "/chain.y";
    let original = yt.read(yc.ROOT + "/test/y/native/t440_lint_chain_safety.y");
    yt.write(file, original);
    let before = yc.compile(yc.YCC, [], file, d + "/before", 120);
    let want = if (before.code == 0) { yc.run_bin(d + "/before", [], "", 10).out } else { "compile failed" };
    let fixed = in_dir(d, [yc.YCC, "--warnings=fix", file], 10);
    let text = yt.read(file);
    yt.check("--warnings=fix declines ambiguous same-line chains and retains side effects",
        fixed.code == 0 && text.contains("else { print(\"SIDE\"); }")
        && text.contains("if (n == 1) { false } else if (n == 2)")
        && text.contains("else if (n == 2) { true } else { false }"),
        "exit=" + tostring(fixed.code) + ", output '" + yt.clip(fixed.out, 300) + "'");
    yt.check("--warnings=fix still applies safe ordered-range and multiline membership fixes",
        text != original && text.contains("n >= 1 && n <= 3") && text.contains("n in [1, 2]"),
        "safe fixes were not applied");
    let after = yc.compile(yc.YCC, [], file, d + "/after", 120);
    let got = if (after.code == 0) { yc.run_bin(d + "/after", [], "", 10).out } else { "compile failed" };
    yt.check("--warnings=fix preserves chain behavior", before.code == 0 && after.code == 0 && want == got && got.starts_with("SIDE\n"),
        "before '" + want + "', after '" + got + "', compile '" + yt.clip(after.out, 300) + "'");
    let again = in_dir(d, [yc.YCC, "--warnings=fix", file], 10);
    yt.check("--warnings=fix chain edits are idempotent", again.code == 0 && yt.read(file) == text,
        "exit=" + tostring(again.code) + ", output '" + yt.clip(again.out, 300) + "'");
    foreach (stem in ["t438_lint_refactor_control", "t439_lint_refactor_folds"]) {
        let path = d + "/" + stem + ".y";
        let source = yt.read(yc.ROOT + "/test/y/native/" + stem + ".y");
        yt.write(path, source);
        let advice = in_dir(d, [yc.YCC, "--warnings=fix", path], 10);
        yt.check("new refactoring advice does not auto-edit " + stem,
            advice.code == 0 && yt.read(path) == source,
            "exit=" + tostring(advice.code) + ", output '" + yt.clip(advice.out, 300) + "'");
    };
    fs.remove_all(d);
};


// The two goals preserve behavior, apply to packed and source std units, and
// produce identical code through the generated seed and the native compiler.
def optimization_modes() -> void {
    let d = yt.tmp_dir("optimize");
    let source = d + "/modes.y";
    yt.write(source, "import math;\n" +
        "def f(x: long) -> long { if (x < 0) { return -128; }; if (x == 0) { return 127; }; x * 9 };\n" +
        "def sum(n: long, s: long) -> long { if (n == 0) { s } else { self(n - 1, s + n) } };\n" +
        "foreach (x in [-1, 0, 3]) { print(f(x)); }; print(sum(100, 0));\n" +
        "print(math.sqrt(4.0)); print(argv().length);\n");
    foreach (mode in ["speed", "size"]) {
        let flags = ["--optimize=" + mode];
        let native = d + "/" + mode;
        let seed = native + ".seed";
        let a = yc.compile(yc.YCC, flags, source, native, 120);
        let b = yc.compile(yc.CYCC, flags, source, seed, 120);
        yt.check(mode + " generated seed/native byte parity", a.code == 0 && b.code == 0 && yt.same_file(native, seed),
            yt.clip(a.out + b.out, 500));
        let r = yc.run_bin(native, [], "", 10);
        yt.check(mode + " arithmetic, early returns, recursion and packed std", r.code == 0 && r.out == "-128\n127\n27\n5050\n2.000000\n1\n",
            "exit=" + tostring(r.code) + ": " + yt.clip(r.out, 300));
        let disk = yc.compile(yc.YCC, flags + ["--std=source"], source, native + ".source", 120);
        yt.check(mode + " bundled/source std byte parity", disk.code == 0 && yt.same_file(native, native + ".source"), yt.clip(disk.out, 500));
        let run = in_dir(d, [yc.YCC, "run", "--optimize", mode, source, "--", "one"], 120);
        yt.check(mode + " run with program arguments", run.code == 0 && run.out == "-128\n127\n27\n5050\n2.000000\n2\n", yt.clip(run.out, 300));
    };
    let plain = yc.compile(yc.YCC, [], source, d + "/default", 120);
    yt.check("default optimization is speed", plain.code == 0 && yt.same_file(d + "/default", d + "/speed"), yt.clip(plain.out, 300));
    yt.check("size goal reduces executable bytes", yt.bytes_of(d + "/size").length < yt.bytes_of(d + "/speed").length, "size did not decrease");
    let legacy = yc.compile(yc.YCC, ["--emit=asm", "-g", "--warnings=none"], source, d + "/legacy.s", 120);
    let named = in_dir(d, [yc.YCC, "--emit", "asm", "--debug", "--warnings", "none", "--output", d + "/named.s", source], 120);
    yt.check("named options preserve legacy assembly/debug/warnings", legacy.code == 0 && named.code == 0 && yt.same_file(d + "/legacy.s", d + "/named.s"),
        yt.clip(legacy.out + named.out, 300));
    fs.remove_all(d);
};

def cases() -> [yt.Case] {
    let s = "ycc";
    let cs: [yt.Case] = [];
    foreach (p in SELF_HOSTED) { cs += yt.case_of(s, p, () => self_hosted(p)); };
    cs += yt.case_of(s, "ysh", ysh);
    cs += yt.case_of(s, "lint fix safety", lint_fix_safety);
    cs += yt.case_of(s, "optimization modes", optimization_modes);
    foreach (cc in [yc.YCC, yc.CYCC]) {
        cs += yt.case_of(s, "warnings", () => warnings(cc));
        cs += yt.case_of(s, "PATH", () => via_path(cc));
    };
    foreach (e in cli_errors()) { cs += yt.case_of(s, e[0], () => cli_error(e[0], e[1], e[2:])); };
    cs += yt.case_of(s, "import depth", import_depth);
    cs += yt.case_of(s, "output to a device", output_to_device);
    cs += yt.case_of(s, "oom", oom);
    foreach (cc in [yc.YCC, yc.CYCC]) { cs += yt.case_of(s, "many", () => many_errors(cc)); };
    cs += yt.case_of(s, "fifo", fifo);
    let nat = yc.ROOT + "/test/y/native/";
    cs += yt.case_of(s, "--emit=source", () => meta_dump(nat + "t01_arith.y", "-E dump"));
    // a meta file whose top level prints nothing (it would print to ycc's stdout
    // before the dump), and one with a MID-TOKEN block
    cs += yt.case_of(s, "-E meta", () => meta_dump(nat + "t197_meta_field_name_ok.y", "-E dump of a meta file"));
    cs += yt.case_of(s, "-E mid", () => meta_dump(nat + "t200_meta_mid_token.y", "-E dump of a mid-token meta file"));
    cs += yt.case_of(s, "meta targets", meta_targets);
    cs += yt.case_of(s, "meta inputs", meta_inputs);
    cs += yt.case_of(s, "meta CLI", meta_cli_errors);
    cs += yt.case_of(s, "meta reserved", meta_reserved);
    cs += yt.case_of(s, "meta build", meta_project);
    cs += yt.case_of(s, "overlays", overlays);
    foreach (cc in [yc.YCC, yc.CYCC]) {
        cs += yt.case_of(s, "run --", () => run_args(cc));
        cs += yt.case_of(s, "heap", () => heap_paths(cc));
    };
    cs
};

export { cases };
