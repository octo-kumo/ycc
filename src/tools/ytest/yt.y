// yt.y -- the core of ytest: processes, scratch space, cases, reports.
//
// A suite is a list of CASES, each a closure that runs commands with `run`
// and reports with `pass`/`fail`/`skip`. The scheduler (`run_cases`) forks a
// child per case, up to `jobs` at once: a case that crashes or hangs is one
// failed case, never a dead runner, and the output is printed per suite in
// case order however the cases finished.
//
// Linux only, over raw syscalls: the suites drive compilers and the static
// ELFs they write, which is a Linux job.
import fs;

// ── scratch space ───────────────────────────────────────────────────────

// The run's scratch directory, under $TMPDIR (else /tmp); `cleanup` removes it.
let SCR = "";
let tmp_n = 0;

def getpid() -> long { syscall(39) };

def scratch() -> str {
    if (SCR == "") {
        let base = env("TMPDIR", "/tmp");
        SCR = base + "/ytest." + tostring(getpid()) + "." + tostring(clock_us() % 1000000);
        fs.make_dirs(SCR, 0o700);
    };
    SCR
};

/** A fresh path in the scratch directory, unique across forked cases. */
def tmp(tag: str) -> str {
    tmp_n += 1;
    scratch() + "/" + tag + "." + tostring(getpid()) + "." + tostring(tmp_n)
};

/** A fresh directory in the scratch directory. */
def tmp_dir(tag: str) -> str {
    let d = tmp(tag);
    fs.make_dirs(d);
    d
};

/** This program's own path (/proc/self/exe), to run a subcommand of it. */
def self_exe() -> str {
    let buf: [byte; 4096] = [0; 4096];
    let p = cz("/proc/self/exe");
    let n = syscall(89, &p[0], &buf[0], 4096);
    if (n <= 0) { "" } else { from_bytes(buf[0:n]) }
};

def cleanup() {
    if (SCR != "") { fs.remove_all(SCR); };
};

// ── the environment ─────────────────────────────────────────────────────

let ENV: [str] = [];
let env_read = false;

def environ() -> [str] {
    if (!env_read) {
        env_read = true;
        let all = read("/proc/self/environ");
        foreach (e in all.split(chr(0))) {
            if (e != "") { ENV += e; };
        };
    };
    ENV
};

/** $name, or `dflt` when it is unset or empty. */
def env(name: str, dflt: str) -> str {
    let pre = name + "=";
    foreach (e in environ()) {
        if (e.starts_with(pre) && e.length > pre.length) { return e[pre.length:]; };
    };
    dflt
};

// The environment with each "K=V" of `over` replacing K (or added).
def env_with(over: [str]) -> [str] {
    if (over.length == 0) { return environ(); };
    let r: [str] = [];
    foreach (e in environ()) {
        let k = e[0:e.index_of("=") + 1];
        let keep = true;
        foreach (o in over) {
            if (o.starts_with(k)) { keep = false; };
        };
        if (keep) { r += e; };
    };
    r + over
};

// argv[0] as a path: as given when it holds a '/', else the first match on $PATH.
def which(prog: str, path: str) -> str {
    if (prog.contains("/")) { return prog; };
    foreach (d in path.split(":")) {
        let p = (if (d == "") { "." } else { d }) + "/" + prog;
        if (fs.is_file(p) && (fs.path_mode(p) & 0o111) != 0) { return p; };
    };
    ""
};

// ── processes ───────────────────────────────────────────────────────────

/** What to run and how. `cmd(argv)` fills the defaults; change fields after. */
type Cmd = {
    argv: [str],
    cwd: str,
    stdin: str,     // a file to read; "" is /dev/null
    input: str,     // ... or this text, when stdin is ""
    timeout: long,  // seconds; 0 is none
    mem_kb: long,   // RLIMIT_AS soft limit; 0 leaves the inherited one
    env: [str],     // "K=V" overrides
    merge: bool,    // stderr into stdout (2>&1)
    out: str,       // write stdout to this file instead of capturing it
    nofile: long,   // RLIMIT_NOFILE (ulimit -n); 0 leaves the inherited one
    tty: bool,      // keep this process's stdin, stdout and stderr (interactive)
};

/** How it went: the exit code (128 + signal; 124 on a timeout), the output. */
type Res = { code: long, out: str, err: str, timed_out: bool, ms: long };

// YMEM_KB caps every command (the machine goes down past 4 GB); a sanitized
// compiler reserves terabytes, so YTIMEOUT_SCALE > 1 drops the cap.
let MEM_KB = 3670016;
let SCALE = 1;

def cmd(argv: [str]) -> Cmd {
    { argv: argv, cwd: "", stdin: "", input: "", timeout: 60 * SCALE, mem_kb: MEM_KB,
      env: [], merge: false, out: "", nofile: 0, tty: false }
};

def cz(s: str) -> [byte] {
    let b = bytes(s);
    b += 0;
    b
};

// Child side: open `path` with `flags` onto fd `to`, or die.
def ch_redirect(path: str, flags: long, to: long) {
    let p = cz(path);
    let fd = syscall(2, &p[0], flags, 0o644);
    if (fd < 0) {
        ch_die("ytest: cannot open " + path);
    };
    if (fd != to) {
        syscall(33, fd, to);
        syscall(3, fd);
    };
};

def ch_die(msg: str) -> void {
    let m = msg + "\n";
    syscall(1, 2, m, m.length);
    syscall(231, 127);
};

/** A started command: its pid, files, and once reaped its exit code. */
type Proc = { pid: long, t0: long, deadline: long, outp: str, errp: str, inp: str, keep_out: bool,
              done: bool, code: long, timed_out: bool };

/** Start `c` and return at once; `wait` or `kill` it later. */
def start(c: Cmd) -> Proc {
    let t0 = clock_us();
    let search = env("PATH", "/usr/bin:/bin");
    foreach (e in c.env) {
        if (e.starts_with("PATH=")) { search = e[5:]; };
    };
    let path = which(c.argv[0], search);
    let outp = if (c.out != "") { c.out } else { tmp("o") };
    let errp = tmp("e");
    let inp = c.stdin;
    if (inp == "") {
        if (c.input != "") {
            inp = tmp("i");
            fs.write_file(inp, c.input);
        } else {
            inp = "/dev/null";
        };
    };
    // every C string the child needs, built before the fork
    let keep: [[byte]] = [];
    let av: [long] = [];
    foreach (a in c.argv) {
        keep += [cz(a)];
        av += ptr_addr(&keep[keep.length - 1][0]);
    };
    av += 0;
    let ev: [long] = [];
    foreach (e in env_with(c.env)) {
        keep += [cz(e)];
        ev += ptr_addr(&keep[keep.length - 1][0]);
    };
    ev += 0;
    let pz = cz(path);
    let cwdz = cz(c.cwd);
    let rl: [long; 2] = [0; 2];
    syscall(97, 9, &rl[0]);
    if (c.mem_kb > 0) {
        let want = c.mem_kb * 1024;
        if (rl[1] < 0 || want < rl[1]) { rl[0] = want; } else { rl[0] = rl[1]; };
    };
    let nf: [long; 2] = [0; 2];
    nf[0] = c.nofile;
    nf[1] = c.nofile;
    let pid = syscall(57);
    if (pid == 0) {
        syscall(109, 0, 0);
        if (c.mem_kb > 0) { syscall(160, 9, &rl[0]); };
        if (c.nofile > 0) { syscall(160, 7, &nf[0]); };
        if (!c.tty) {
            ch_redirect(inp, 0, 0);
            ch_redirect(outp, 577, 1);
            if (c.merge) { syscall(33, 1, 2); } else { ch_redirect(errp, 577, 2); };
        };
        if (c.cwd != "" && syscall(80, &cwdz[0]) != 0) { ch_die("ytest: cannot cd to " + c.cwd); };
        if (path != "") { syscall(59, &pz[0], ptr_addr(&av[0]), ptr_addr(&ev[0])); };
        ch_die("ytest: cannot run " + c.argv[0]);
    };
    let deadline = if (c.timeout > 0) { t0 + c.timeout * 1000000 } else { 0 };
    { pid: pid, t0: t0, deadline: deadline, outp: outp, errp: errp, inp: if (inp != c.stdin && inp != "/dev/null") { inp } else { "" },
      keep_out: c.out != "", done: pid < 0, code: if (pid < 0) { -1 } else { 0 }, timed_out: false }
};

// Reap p if it has ended (`block`: wait for it); true once it has.
def reap(p: Proc, block: bool) -> bool {
    if (p.done) { return true; };
    let st: [long; 1] = [0; 1];
    let r = syscall(61, p.pid, &st[0], if (block) { 0 } else { 1 }, 0);
    if (r == 0) { return false; };
    let s = st[0] & 65535;
    p.code = if (r < 0) { -1 } else if ((s & 127) == 0) { (s >> 8) & 255 } else { 128 + (s & 127) };
    p.done = true;
    true
};

/** Is p still running? */
def alive(p: Proc) -> bool { !reap(p, false) };

/** Kill p's whole process group and reap it. */
def kill(p: Proc) {
    if (!p.done) {
        syscall(62, 0 - p.pid, 9);
        syscall(62, p.pid, 9);
        reap(p, true);
    };
};

/** Wait for p (up to its deadline, then kill it: code 124) and collect its output. */
def wait(p: Proc) -> Res {
    let nap = 20;
    while (!reap(p, false)) {
        if (p.deadline > 0 && clock_us() > p.deadline) {
            kill(p);
            p.code = 124;
            p.timed_out = true;
        } else {
            sleep_us(nap);
            if (nap < 2000) { nap = nap * 2; };
        };
    };
    let out = if (p.keep_out) { "" } else { read(p.outp) };
    let err = read(p.errp);
    if (!p.keep_out) { fs.remove_file(p.outp); };
    fs.remove_file(p.errp);
    if (p.inp != "") { fs.remove_file(p.inp); };
    let res: Res = { code: p.code, out: out, err: err, timed_out: p.timed_out, ms: (clock_us() - p.t0) / 1000 };
    if (p.pid < 0) { res.err = "ytest: fork failed"; };
    res
};

def run(c: Cmd) -> Res { wait(start(c)) };

/** Run argv with the defaults, stderr kept apart. */
def exe(argv: [str]) -> Res { run(cmd(argv)) };

/** Run argv with stderr folded into stdout. */
def exe2(argv: [str]) -> Res {
    let c = cmd(argv);
    c.merge = true;
    run(c)
};

/** /bin/sh -c s, stderr folded into stdout: for a pipeline or a redirect. */
def sh(s: str) -> Res { exe2(["/bin/sh", "-c", s]) };

/** Quote s for /bin/sh. */
def q(s: str) -> str { "'" + s.replace("'", "'\\''") + "'" };

// ── files ───────────────────────────────────────────────────────────────

def read(path: str) -> str {
    let s = fs.read_file(path);
    if (s == none) { "" } else { s! }
};

def write(path: str, s: str) { fs.write_file(path, s); };

/** `out` = the files of `parts`, end to end (cat); false when one cannot be read. */
def concat(out: str, parts: [str]) -> bool {
    let all: [byte] = [];
    foreach (p in parts) {
        let b = fs.read_bytes(p);
        if (b == none) { return false; };
        all += b!;
    };
    fs.write_bytes(out, all)
};

def same_file(a: str, b: str) -> bool {
    let x = fs.read_bytes(a);
    let y = fs.read_bytes(b);
    x != none && y != none && x! == y!
};

def size(path: str) -> long {
    let n = fs.file_size(path);
    if (n == none) { -1 } else { n! }
};

/** The names in `dir`, sorted ([] when it cannot be read). */
def ls(dir: str) -> [str] {
    let r = fs.list_dir(dir);
    if (r == none) { [] } else { r! }
};

/** The files in `dir` whose names start with `pre` and end with `suf`, sorted, as paths. */
def files(dir: str, pre: str, suf: str) -> [str] {
    let r: [str] = [];
    foreach (n in ls(dir)) {
        if (n.starts_with(pre) && n.ends_with(suf)) { r += dir + "/" + n; };
    };
    r
};

/** Every file under `dir` ending in `suf`, recursively, sorted by path. */
def tree(dir: str, suf: str) -> [str] {
    let r: [str] = [];
    foreach (n in ls(dir)) {
        let p = dir + "/" + n;
        if (fs.is_dir_itself(p)) {
            r += self(p, suf);
        } else if (n.ends_with(suf)) {
            r += p;
        };
    };
    r
};

/** s as a number, or `dflt`. */
def num(s: str, dflt: long) -> long {
    let n = s.tolong();
    if (n == none) { dflt } else { n! }
};

def sleep_us(us: long) -> void {
    let ts: [long; 2] = [0; 2];
    ts[1] = us * 1000;
    syscall(35, &ts[0], 0);
};

/** The little-endian unsigned number of `n` bytes at `off` in b (0 past the end). */
def le(b: [byte], off: long, n: long) -> long {
    let v = 0;
    let i = n - 1;
    while (i >= 0) {
        v = v * 256;
        if (off + i < b.length) { v += b[off + i]; };
        i -= 1;
    };
    v
};

/** The bytes of a file ([] when it cannot be read). */
def bytes_of(path: str) -> [byte] {
    let b = fs.read_bytes(path);
    if (b == none) { [] } else { b! }
};

/** Is `prog` on $PATH? */
def have(prog: str) -> bool { which(prog, env("PATH", "/usr/bin:/bin")) != "" };

/** n in hex, with a 0x. */
def hex(n: long) -> str {
    let d = "0123456789abcdef";
    let s = "";
    let v = n;
    if (v == 0) { return "0x0"; };
    while (v != 0) {
        s = d[v & 15:(v & 15) + 1] + s;
        v = v >>> 4;
    };
    "0x" + s
};

// ── text helpers for reports ────────────────────────────────────────────

/** At most n bytes of s, newlines as '|': a detail that fits on one line. */
def clip(s: str, n: long) -> str {
    let t = if (s.length > n) { s[0:n] } else { s };
    t.replace("\n", "|")
};

/** The lines of s (split already drops the one empty field a final newline leaves). */
def lines(s: str) -> [str] { s.split("\n") };

/** The whitespace-separated words of s. */
def words(s: str) -> [str] {
    let r: [str] = [];
    foreach (w in s.replace("\t", " ").split(" ")) {
        if (w != "") { r += w; };
    };
    r
};

/** Is there a line of s equal to `l`? */
def has_line(s: str, l: str) -> bool {
    foreach (x in s.split("\n")) {
        if (x == l) { return true; };
    };
    false
};

// The first line where `want` and `got` part, as "-want|+got".
def first_diff(want: str, got: str) -> str {
    let a = want.split("\n");
    let b = got.split("\n");
    let i = 0;
    while (i < a.length && i < b.length && a[i] == b[i]) { i += 1; };
    let wa = if (i < a.length) { a[i] } else { "(end)" };
    let gb = if (i < b.length) { b[i] } else { "(end)" };
    clip("line " + tostring(i + 1) + ": -" + wa + " +" + gb, 300)
};

def first_line(s: str) -> str {
    let i = s.index_of("\n");
    if (i < 0) { s } else { s[0:i] }
};

// ── reporting ───────────────────────────────────────────────────────────

let N_PASS = 0;
let N_FAIL = 0;
let N_SKIP = 0;
let REPORT = "";
let QUIET = false;
let COLOR = false;

def paint(code: str, s: str) -> str {
    if (COLOR) { "\x1b[" + code + "m" + s + "\x1b[0m" } else { s }
};

/** A line of the case's report. */
def say(s: str) { REPORT += s + "\n"; };

def pass(name: str) {
    N_PASS += 1;
    if (!QUIET) { say(paint("0;32", "PASS") + " " + name); };
};

def fail(name: str, detail: str) {
    N_FAIL += 1;
    say(paint("0;31", "FAIL") + " " + name);
    if (detail != "") { say("  " + detail); };
};

def skip(name: str, why: str) {
    N_SKIP += 1;
    say(paint("0;33", "SKIP") + " " + name + (if (why != "") { " (" + why + ")" } else { "" }));
};

/** pass or fail on `ok`. */
def check(name: str, ok: bool, detail: str) -> bool {
    if (ok) { pass(name); } else { fail(name, detail); };
    ok
};

// ── cases and the scheduler ─────────────────────────────────────────────

/** One unit of work: `body` runs in a child of its own and reports. */
type Case = { suite: str, name: str, body: () -> void };

def case_of(suite: str, name: str, body: () -> void) -> Case {
    { suite: suite, name: name, body: body }
};

/** A finished case: its counts and its report text. */
type Done = { npass: long, nfail: long, nskip: long, text: str };

// Child side: run the case, write "P F S\n" + report to `path`.
def run_case(c: Case, path: str) {
    let ez = cz(path + ".err");
    let fd = syscall(2, &ez[0], 577, 0o644);
    if (fd >= 0) {
        syscall(33, fd, 2);
        syscall(3, fd);
    };
    N_PASS = 0;
    N_FAIL = 0;
    N_SKIP = 0;
    REPORT = "";
    c.body();
    fs.write_file(path, tostring(N_PASS) + " " + tostring(N_FAIL) + " " + tostring(N_SKIP) + "\n" + REPORT);
};

def read_done(c: Case, path: str, code: long) -> Done {
    let s = fs.read_file(path);
    let err = read(path + ".err");
    fs.remove_file(path + ".err");
    if (s == none) {
        return { npass: 0, nfail: 1, nskip: 0,
                 text: paint("0;31", "FAIL") + " " + c.name + "\n  the case died (exit " + tostring(code) + "): "
                     + clip(err, 300) + "\n" };
    };
    let t = s!;
    let nl = t.index_of("\n");
    let ns = t[0:nl].split(" ");
    fs.remove_file(path);
    { npass: num(ns[0], 0), nfail: num(ns[1], 0), nskip: num(ns[2], 0), text: t[nl + 1:] }
};

/** Run every case, `jobs` at once; the results in case order. */
def run_cases(cs: [Case], jobs: long, on_done: (long, Done) -> void) -> [Done] {
    let res: [Done] = [];
    let pids: [long] = [];
    for i in 0..cs.length {
        res += { npass: 0, nfail: 0, nskip: 0, text: "" };
        pids += 0;
    };
    let dir = tmp_dir("cases");
    let next = 0;
    let running = 0;
    let st: [long; 1] = [0; 1];
    while (next < cs.length || running > 0) {
        if (next < cs.length && running < jobs) {
            let k = next;
            next += 1;
            let pid = syscall(57);
            if (pid == 0) {
                run_case(cs[k], dir + "/" + tostring(k));
                syscall(231, 0);
            };
            pids[k] = pid;
            running += 1;
        } else {
            let pid = syscall(61, -1, &st[0], 0, 0);
            if (pid > 0) {
                let s = st[0] & 65535;
                let code = if ((s & 127) == 0) { (s >> 8) & 255 } else { 128 + (s & 127) };
                for k in 0..cs.length {
                    if (pids[k] == pid) {
                        pids[k] = 0;
                        running -= 1;
                        res[k] = read_done(cs[k], dir + "/" + tostring(k), code);
                        on_done(k, res[k]);
                    };
                };
            } else {
                running = 0;
            };
        };
    };
    res
};

/** Set the knobs from the environment: YQUIET, YMEM_KB, YTIMEOUT_SCALE, colors. */
def init() {
    QUIET = env("YQUIET", "") != "";
    MEM_KB = num(env("YMEM_KB", "3670016"), 3670016);
    SCALE = num(env("YTIMEOUT_SCALE", "1"), 1);
    let tio: [long; 8] = [0; 8];
    COLOR = syscall(16, 1, 21505, &tio[0]) == 0 && env("NO_COLOR", "") == "";
};

export { Cmd, Res, Proc, start, reap, alive, kill, wait, Case, Done, self_exe, scratch, tmp, tmp_dir, cleanup, environ, env, which,
    cmd, run, exe, exe2, sh, q, read, write, concat, same_file, size, ls, files, num, le, bytes_of, have, hex, sleep_us, tree, clip, lines,
    first_line, first_diff, words, has_line, cz, sleep_us, say, pass, fail, skip, check, case_of, run_cases, init, paint, getpid,
    MEM_KB, SCALE, QUIET };
