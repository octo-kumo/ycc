// gcov coverage of the generated C seed and its value runtime.
import fs;

// ── running a shell command and reading its answer ──────────────────────

// What one command answered: its exit status and its stdout.
type Res = { status: long, out: str };

// sh runs cmd through /bin/sh -c and answers its stdout. The read happens
// before the wait, which is what pread does; nothing is written to the child,
// so no pipe can fill under us.
def sh(cmd: str) -> Res {
    // exec() forks with envp NULL (std/exec.y), so the child gets NO
    // environment -- which is deliberate there and means a PATH has to be
    // named here or gcc cannot find its own cc1. It also makes every command
    // this runner starts independent of whoever's shell invoked it.
    let p = popen("export PATH=/usr/bin:/bin; " + cmd);
    if (len(p) < 3) {
        return { status: -1, out: "" };
    };
    pclose_in(p);
    let out = pread(p);
    let st = pclose(p);
    return { status: st, out: out };
};

// ms_since is a microsecond clock reading in milliseconds, which is the unit
// the tables print.
def ms_since(t0: long) -> long {
    (clock_us() - t0) / 1000
};

// ── gcov line coverage ─────────────────────────────────────────────────

type Cov = { name: str, pct: float, executed: long, total: long };

// The corpus `coverage` runs when it is not given one. Each entry is the
// compiler's ARGUMENTS, not just a file, because the phases worth covering are
// reached by a flag: `-g` is dwarf.y, `--target=win` is pe.y, `--emit=asm` and
// `--emit=source` are two other exits from the driver, and an error fixture is the
// diagnostic path. The self-compile is the single heaviest workload, first.
// The coverage run's scratch directory, made by coverage() and removed at its end.
let COV = "";

def cov_default() -> [str] {
    ["src/y/ycc.y -o " + COV + "/out",
     "-g test/y/examples/helloworld.y -o " + COV + "/outg",
     "--target=win test/y/examples/helloworld.y -o " + COV + "/out.exe",
     "--emit=asm test/y/native/t204_std_json.y > /dev/null",
     "--emit=source src/tools/lsp/serve.y > /dev/null",
     "--warnings=none test/y/native/t328_split_unrolled.y -o " + COV + "/out2",
     "test/y/native/t307_math_trap.y -o " + COV + "/out3",
     "test/y/native/t199_std_tui.y -o " + COV + "/out4",
     "test/y/native/t20_files_argv.y -o " + COV + "/out5",
     "test/y/native/t198_meta_basic.y -o " + COV + "/out7",
     "test/y/native/e110_lex_unterminated_string.y -o " + COV + "/out8",
     "test/y/native/e114_parse_expr_char.y -o " + COV + "/out9",
     "test/y/native/e01_badarith.y -o " + COV + "/out6",
     "--std=source test/y/native/t204_std_json.y -o " + COV + "/out10",
     "build " + COV + "/proj"]
};

// The one-package project the `build` entry compiles, written before the
// corpus runs. It is what reaches pkg.y and ycc.y's build path, which no
// single-file compile does.
def make_proj() -> long {
    fs.make_dirs(COV + "/proj");
    fs.write_file(COV + "/proj/y.toml",
                        "[package]\nname = \"proj\"\nbin = \"main.y\"\n");
    fs.write_file(COV + "/proj/main.y", "print(\"cov\");\n");
    0
};

// The commands coverage will run: the arguments given on the command line,
// each as a plain `-o` compile, or cov_default.
def cov_corpus(argv: [str]) -> [str] {
    if (len(argv) > 0) {
        let out: [str] = [];
        let i = 0;
        while (i < len(argv)) {
            // Validate the path before adding compiler arguments.
            if (!fs.exists(argv[i])) {
                eputs("ytest: no such program: " + argv[i]);
            } else {
                out += argv[i] + " -o " + COV + "/out";
            };
            i = i + 1;
        };
        return out;
    };
    return cov_default();
};

// gcov object names for the seed and value runtime.
def c_sources() -> [str] { ["ycc", "yv"] };
// The number after `prefix` and before `%` in ONE line, or -1.
def pct_in(line: str, prefix: str) -> float {
    let i = index_of(line, prefix);
    if (i < 0) { return 0.0 - 1.0; };
    let rest = line[i + len(prefix):];
    let j = index_of(rest, "%");
    if (j < 0) { return 0.0 - 1.0; };
    tofloat(rest[0:j])!
};

// The number after `marker` (to the end of the line), or 0.
def num_after(line: str, marker: str) -> long {
    let i = index_of(line, marker);
    if (i < 0) { return 0; };
    let rest = trim(line[i + len(marker):]);
    let j = index_of(rest, " ");
    if (j < 0) { return tolong(rest)!; };
    tolong(rest[0:j])!
};

// One source's executed/total lines, from `gcov`'s own summary. `-o` is the
// build directory and the argument is the .gcno, so gcov never writes its
// `.gcov` file into the tree.
def one_cov(name: str) -> Cov {
    let cmd = "cd " + COV + " && gcov -o " + COV + " " + COV + "/cycc-cov-"
            + name + ".gcno 2>/dev/null";
    let r = sh(cmd);
    let lines = split(r.out, "\n");
    let pct = 0.0 - 1.0;
    let total = 0;
    let own = false;
    let i = 0;
    while (i < len(lines)) {
        if (lines[i].starts_with("File ")) { own = lines[i].contains("/" + name + ".c'"); };
        let p = own ? pct_in(lines[i], "Lines executed:") : -1.0;
        if (p >= 0.0) {
            pct = p;
            total = num_after(lines[i], "% of ");
        };
        i = i + 1;
    };
    let hit = total;
    if (pct >= 0.0) {
        hit = tolong(0.5 + (pct / 100.0) * tofloat(total)!)!;
    };
    return { name: name, pct: pct, executed: hit, total: total };
};

// coverage builds the instrumented C seed, runs the corpus, and answers every
// file's line coverage (a file gcov did not see comes back -1 / 0).
def coverage(argv: [str]) -> long {
    let corpus = cov_corpus(argv);
    // a directory of its own (mktemp -t honours $TMPDIR), removed at the end
    COV = trim(sh("mktemp -d -t ytest-cov.XXXXXX").out);
    if (COV == "") {
        eputs("ytest: cannot make a scratch directory");
        return 1;
    };
    let build = "gcc --coverage -std=gnu99 -O1 -DYV_GC -include tools/bootstrap/gc.h -Itools/bootstrap -Isrc/c -o " + COV + "/cycc-cov bootstrap/ycc.c src/c/yv.c src/c/host.c -l:libgc.so.1 -lm";
    print("== coverage: building the instrumented C seed ==");
    let b = sh(build);
    if (b.status != 0) {
        print("build failed:");
        print(b.out);
        sh("rm -rf " + COV);
        return 1;
    };
    make_proj();
    print("== coverage: running " + tostring(len(corpus)) + " program(s) ==");
    // Reject an empty corpus rather than reporting a misleading percentage.
    let c = 0;
    while (c < len(corpus)) {
        sh("(ulimit -v 3670016; " + COV + "/cycc-cov " + corpus[c]
         + ") >/dev/null 2>&1");
        c = c + 1;
    };
    if (len(corpus) == 0) {
        eputs("ytest: nothing to measure -- every corpus path was missing");
        sh("rm -rf " + COV);
        return 1;
    };
    let names = c_sources();
    print("== coverage: gcov over " + tostring(len(names)) + " source files ==");
    let seen = 0;
    let sum_e = 0;
    let sum_t = 0;
    let i = 0;
    while (i < len(names)) {
        let cv = one_cov(names[i]);
        if (cv.total > 0) {
            seen = seen + 1;
            sum_e = sum_e + cv.executed;
            sum_t = sum_t + cv.total;
            print(pad_right(cv.name, 14) + pad_left(fmt_pct(cv.pct), 7)
                + "  " + tostring(cv.executed) + "/" + tostring(cv.total));
        } else {
            print(pad_right(cv.name, 14) + "   (no data)");
        };
        i = i + 1;
    };
    let whole = 0.0;
    if (sum_t > 0) { whole = 100.0 * tofloat(sum_e)! / tofloat(sum_t)!; };
    print("coverage: " + tostring(sum_e) + "/" + tostring(sum_t) + " lines = "
        + fmt_pct(whole) + " over " + tostring(seen) + " files");
    sh("rm -rf " + COV);
    0
};

// ── small text helpers (Y has no printf) ────────────────────────────────

// pad_right pads s with spaces to n columns (never truncates).
def pad_right(s: str, n: long) -> str {
    let out = s;
    while (len(out) < n) { out = out + " "; };
    out
};

def pad_left(s: str, n: long) -> str {
    let out = s;
    while (len(out) < n) { out = " " + out; };
    out
};

// fmt_pct prints a percentage with one decimal, because tostring's float form
// is not what a table wants. Rounded to the nearest tenth.
def fmt_pct(p: float) -> str {
    let tenths = tolong(p * 10.0 + 0.5)!;
    tostring(tenths / 10) + "." + tostring(tenths % 10) + "%"
};

export { coverage };
