// su_web.y -- suite web-smoke: the W3 web skeleton under Node.
import fs;
import yt;
import yc;

let DIR = "";
let HOST = "";
let NODE = "";
let INITED = false;

def init() {
    if (INITED) { return; };
    INITED = true;
    DIR = yc.ROOT + "/test/web";
    HOST = yc.ROOT + "/src/web/yhost.js";
    let path = yt.env("PATH", "/usr/bin:/bin");
    NODE = yt.which(yt.env("NODE", "node"), path);
    if (NODE == "") { NODE = "node"; };
};

def webcc() -> str { yt.env("YWEB", yc.YCC) };

def compile(flags: [str], src: str, out: str) -> yt.Res {
    init();
    let has_emit = false;
    foreach (f in flags) { if (f.starts_with("--emit=")) { has_emit = true; }; };
    let fl = if (has_emit) { flags } else { ["--emit=wasm"] + flags };
    let c = yt.cmd([webcc(), "--target=web"] + fl + ["-o", out, src]);
    c.cwd = yc.ROOT;
    c.merge = true;
    c.timeout = 300 * yt.SCALE;
    c.mem_kb = yc.PROG_MEM_KB;
    yt.run(c)
};

// A web compile that writes the site (the default output).
def compile_page(flags: [str], src: str, out: str) -> yt.Res {
    init();
    let c = yt.cmd([webcc(), "--target=web"] + flags + ["-o", out, src]);
    c.cwd = yc.ROOT;
    c.merge = true;
    c.timeout = 300 * yt.SCALE;
    c.mem_kb = yc.PROG_MEM_KB;
    yt.run(c)
};

def node_run(wasm: str, args: [str], env: [str]) -> yt.Res {
    init();
    let c = yt.cmd([NODE, "--disable-wasm-trap-handler", HOST, "run", wasm] + args);
    c.cwd = yc.ROOT;
    c.merge = true;
    c.timeout = 120 * yt.SCALE;
    c.mem_kb = yc.PROG_MEM_KB;
    if (env.length > 0) { c.env = env; };
    yt.run(c)
};

def validate(wasm: str) -> yt.Res {
    init();
    let c = yt.cmd([NODE, "--disable-wasm-trap-handler", HOST, "validate", wasm]);
    c.cwd = yc.ROOT;
    c.merge = true;
    c.timeout = 60 * yt.SCALE;
    c.mem_kb = yc.PROG_MEM_KB;
    yt.run(c)
};

def expected(name: str) -> str {
    let p = DIR + "/" + name + ".expected";
    if (fs.exists(p)) { yt.read(p) } else { "" }
};

def read_words(name: str, ext: str) -> [str] {
    let p = DIR + "/" + name + ext;
    if (!fs.exists(p)) { return []; };
    let out: [str] = [];
    foreach (w in yt.read(p).split("\n")) {
        if (w != "") { out += w; };
    };
    out
};

def fixture_env(name: str) -> [str] { read_words(name, ".env") };


def driver_case() {
    let wasm = yt.tmp("w001");
    let c = compile([], DIR + "/w001_hello.y", wasm);
    if (c.code != 0) {
        yt.fail("driver writes a module", "compile exit " + tostring(c.code) + ": " + yt.clip(c.out, 300));
        return;
    };
    yt.check("driver writes a module", fs.is_file(wasm) && yt.size(wasm) > 8,
        "no module at " + wasm);
    let text = from_bytes(yt.bytes_of(wasm));
    yt.check("the yweb section is present", text.contains("yweb") && text.contains("abi=1"),
        "the module does not carry the yweb section");
    let v = validate(wasm);
    yt.check("node yhost.js validate accepts the module", v.code == 0 && v.out.contains("ok abi=1"),
        "exit=" + tostring(v.code) + " " + yt.clip(v.out, 300));
};

def hello_case() {
    let wasm = yt.tmp("w001z");
    let c = compile([], DIR + "/w001_hello.y", wasm);
    if (c.code != 0) {
        yt.fail("w001_hello runs", "compile exit " + tostring(c.code) + ": " + yt.clip(c.out, 300));
        return;
    };
    let r = node_run(wasm, [], []);
    yt.check("w001_hello runs", r.code == 0 && r.out == expected("w001_hello"),
        "exit=" + tostring(r.code) + " out='" + yt.clip(r.out, 200) + "' want='" + expected("w001_hello") + "'");
};

def args_case() {
    let wasm = yt.tmp("w002");
    let c = compile([], DIR + "/w002_args_env.y", wasm);
    if (c.code != 0) {
        yt.fail("w002 argv and env", "compile exit " + tostring(c.code) + ": " + yt.clip(c.out, 300));
        return;
    };
    let r = node_run(wasm, read_words("w002_args_env", ".args"), fixture_env("w002_args_env"));
    yt.check("w002 argv and env", r.code == 0 && r.out == expected("w002_args_env"),
        "exit=" + tostring(r.code) + " out='" + yt.clip(r.out, 200) + "'");
};

def exit_case() {
    let wasm = yt.tmp("w003");
    let c = compile([], DIR + "/w003_exit.y", wasm);
    if (c.code != 0) {
        yt.fail("exit(7) is status 7", "compile exit " + tostring(c.code) + ": " + yt.clip(c.out, 300));
        return;
    };
    let r = node_run(wasm, [], []);
    yt.check("exit(7) is status 7", r.code == 7 && r.out == expected("w003_exit"),
        "exit=" + tostring(r.code) + " out='" + yt.clip(r.out, 200) + "'");
};


def refuses(name: str, flags: [str], want: str) {
    let c = yt.cmd([webcc()] + flags + ["-o", yt.tmp("refused"), DIR + "/w001_hello.y"]);
    c.cwd = yc.ROOT;
    c.merge = true;
    c.timeout = 120 * yt.SCALE;
    c.mem_kb = yc.PROG_MEM_KB;
    let r = yt.run(c);
    yt.check("refusal: " + name, r.code != 0 && r.out.contains(want),
        "exit=" + tostring(r.code) + " out='" + yt.clip(r.out, 240) + "' want '" + want + "'");
};

def refusal_case() {
    refuses("--ob on web", ["--target=web", "--ob"], "--ob is not available for --target=web");
    refuses("--pack on web", ["--target=web", "--pack"], "--pack is Linux ELF only");
    refuses("conflicting targets", ["--target=web", "--target=kernel"], "conflicting --target values");
    refuses("--emit=wat on linux", ["--emit=wat"], "--emit=wat is only for --target=web");
    refuses("--emit=wasm on linux", ["--emit=wasm"], "--emit=wasm is only for --target=web");
    refuses("--web=stack out of range", ["--target=web", "--web=stack=1K"],
        "wants a byte size from 64K to 256M");
    refuses("--web=stack not a size", ["--target=web", "--web=stack=big"],
        "'stack' wants a byte size from 64K to 256M");
    refuses("--web= without =", ["--target=web", "--web=nope"], "--web wants KEY=VALUE");
};

def wat_case() {
    let out = yt.tmp("w001.wat");
    let c = compile(["--emit=wat"], DIR + "/w001_hello.y", out);
    let t = "";
    if (c.code == 0 && fs.exists(out)) { t = yt.read(out); };
    yt.check("--emit=wat writes a listing", c.code == 0 && t.contains("(module") && t.contains("yweb"),
        "exit=" + tostring(c.code) + " '" + yt.clip(t, 160) + "'");
};


def page_case() {
    let dir = yt.tmp_dir("site");
    let c = compile_page([], DIR + "/w001_hello.y", dir);
    let ok = c.code == 0;
    let why = "";
    foreach (f in ["index.html", "w001_hello.wasm"]) {
        if (!fs.exists(dir + "/" + f)) { ok = false; why += "missing " + f + " "; };
    };
    // A site is the page and the module; the host and stylesheet are inline.
    foreach (f in ["page.js", "core.js", "page.css", "package.json"]) {
        if (fs.exists(dir + "/" + f)) { ok = false; why += "extra " + f + " "; };
    };
    if (ok) {
        let html = yt.read(dir + "/index.html");
        if (!html.contains("importmap") || !html.contains("yweb:page.js")) { ok = false; why += "host not inline "; };
        if (html.contains("src=\"page.js\"")) { ok = false; why += "still loads page.js "; };
    };
    yt.check("a web compile writes the page and the module", ok,
        "exit=" + tostring(c.code) + " " + why + yt.clip(c.out, 200));
    let chk = yt.cmd([NODE, "--check", yc.ROOT + "/src/web/page.js"]);
    chk.cwd = yc.ROOT;
    chk.merge = true;
    chk.timeout = 60 * yt.SCALE;
    let r = yt.run(chk);
    yt.check("the page host is a valid ES module", r.code == 0, yt.clip(r.out, 200));
};

// The environment-only failures around running and emitting a site: each
// message is a diagnostic a user can meet (no node, no TMPDIR, no host file,
// an unwritable page path), so each is checked with its exact text.
def failure_case() {
    init();
    let base = [webcc(), "run", "--target=web", DIR + "/w001_hello.y"];
    let no_node = yt.cmd(base);
    no_node.cwd = yc.ROOT;
    no_node.merge = true;
    no_node.timeout = 60 * yt.SCALE;
    no_node.env = ["NODE=", "PATH=/usr/bin:/bin"];
    let r1 = yt.run(no_node);
    yt.check("no node is a clear message",
        r1.code == 1 && r1.out.contains("ycc: running a web program needs node ≥ 22 (set NODE=/path/to/node)"),
        "exit=" + tostring(r1.code) + ": " + yt.clip(r1.out, 240));
    let no_tmp = yt.cmd(base);
    no_tmp.cwd = yc.ROOT;
    no_tmp.merge = true;
    no_tmp.timeout = 60 * yt.SCALE;
    no_tmp.env = ["TMPDIR=/nonexistent/yweb", "PATH=/usr/bin:/bin"];
    let r2 = yt.run(no_tmp);
    yt.check("a missing TMPDIR is a clear message",
        r2.code == 1 && r2.out.contains("ycc: cannot make a temporary directory for the web run"),
        "exit=" + tostring(r2.code) + ": " + yt.clip(r2.out, 240));
    let dir = yt.tmp_dir("sitefail");
    let no_host = yt.cmd([webcc(), "--target=web", "-o", dir, DIR + "/w001_hello.y"]);
    no_host.cwd = yc.ROOT;
    no_host.merge = true;
    no_host.timeout = 120 * yt.SCALE;
    no_host.env = ["YHOST=", "PATH=/usr/bin:/bin"];
    let r3 = yt.run(no_host);
    yt.check("a missing page host is a clear message",
        r3.code == 1 && r3.out.contains("ycc: cannot find src/web/yhost.js to write the page"),
        "exit=" + tostring(r3.code) + ": " + yt.clip(r3.out, 240));
    // a directory where the module file must go makes the write fail
    fs.make_dirs(dir + "/w001_hello.wasm");
    let bad = compile_page([], DIR + "/w001_hello.y", dir);
    yt.check("a page write failure is a clear message",
        bad.code == 1 && bad.out.contains("ycc: writing the page under '" + dir + "' failed"),
        "exit=" + tostring(bad.code) + ": " + yt.clip(bad.out, 240));
    fs.remove_all(dir);
};

// The pack's entries as parallel name/data lists (pack_put's "len:text"
// stream after the version line). Used by pack-same below.
type PackView = { names: [str], data: [str] };

def pack_view(path: str) -> PackView {
    let t = yt.read(path);
    let p = index_of(t, "\n") + 1;
    // the count is itself a pack_put field: "len:digits"
    let a = p;
    while (p < len(t) && t[p] != 58) { p++; };
    let cl = t[a:p].tolong();
    p++;
    let n = t[p:p + (if (cl == none) { 0 } else { cl! })].tolong();
    p += (if (cl == none) { 0 } else { cl! });
    let names: [str] = [];
    let data: [str] = [];
    let i = 0;
    while (i < (if (n == none) { 0 } else { n! })) {
        a = p;
        while (p < len(t) && t[p] != 58) { p++; };
        let nl = t[a:p].tolong();
        p++;
        let name = t[p:p + (if (nl == none) { 0 } else { nl! })];
        p += (if (nl == none) { 0 } else { nl! });
        a = p;
        while (p < len(t) && t[p] != 58) { p++; };
        let dl = t[a:p].tolong();
        p++;
        let d = t[p:p + (if (dl == none) { 0 } else { dl! })];
        p += (if (dl == none) { 0 } else { dl! });
        names += name;
        data += d;
        i++;
    };
    { names: names, data: data }
};

// W3's pack gate: the web target adds arch.web and the two host stubs in the
// Linux prelude, and nothing else in the pack may move.
def pack_same_case() {
    init();
    let d = yt.tmp_dir("packsame");
    let a = yt.cmd([webcc(), "--std-pack", d + "/new.pack"]);
    a.cwd = yc.ROOT;
    a.merge = true;
    a.timeout = 120 * yt.SCALE;
    let b = yt.cmd([yc.CYCC, "--std-pack", d + "/old.pack"]);
    b.cwd = yc.ROOT;
    b.merge = true;
    b.timeout = 120 * yt.SCALE;
    let ra = yt.run(a);
    let rb = yt.run(b);
    let ok = ra.code == 0 && rb.code == 0;
    let why = "new=" + tostring(ra.code) + " old=" + tostring(rb.code) + " " + yt.clip(ra.out + rb.out, 200);
    if (ok) {
        let np = pack_view(d + "/new.pack");
        let op = pack_view(d + "/old.pack");
        let changed: [str] = [];
        let oi = 0;
        while (oi < len(op.names)) {
            let nm = op.names[oi];
            let at = -1;
            let k = 0;
            while (k < len(np.names) && at < 0) {
                if (np.names[k] == nm) { at = k; };
                k++;
            };
            if (at < 0 || np.data[at] != op.data[oi]) { changed += nm; };
            oi++;
        };
        let extra = "";
        let unknown = "";
        foreach (nm in np.names) {
            if (!(nm in op.names)) {
                extra += " " + nm;
                unknown += " " + nm;
            };
        };
        // Both packs are built from the current prelude, so the two host
        // stubs are in both; what this pins is that a newer pack adds only
        // the known entries and moves no other one -- gui itself, in
        // particular, stays byte for byte (it is in changed[] if it moved).
        ok = changed.length == 0 && unknown == "";
        why = "changed=" + join(changed, ",") + " extra=" + extra + " unknown=" + unknown
            + " (want none changed and no addition beyond arch.web, gui@web, web)";
    };
    yt.check("pack-same: no old entry changed; the pack adds arch.web, gui@web and web", ok, why);
    fs.remove_all(d);
};

def host_case() {
    init();
    let c = yt.cmd([NODE, "--disable-wasm-trap-handler", HOST, "selftest"]);
    c.cwd = yc.ROOT;
    c.merge = true;
    c.timeout = 120 * yt.SCALE;
    c.mem_kb = yc.PROG_MEM_KB;
    let r = yt.run(c);
    yt.check("node yhost.js selftest", r.code == 0 && r.out.contains("selftest: ok"),
        "exit=" + tostring(r.code) + " " + yt.clip(r.out, 300));
};

def options_case() {
    let wasm = yt.tmp("w001checked");
    let c = compile(["--web=stack=1M"], DIR + "/w001_hello.y", wasm);
    let r = c;
    let out = "";
    if (c.code == 0) { r = node_run(wasm, [], []); out = r.out; };
    yt.check("--web=stack runs", c.code == 0 && r.code == 0 && out == expected("w001_hello"),
        "compile=" + tostring(c.code) + " run=" + tostring(r.code) + " out='" + yt.clip(out, 160) + "'");
    let text = "";
    if (fs.exists(wasm)) { text = from_bytes(yt.bytes_of(wasm)); };
    yt.check("--web=stack reaches the yweb section", text.contains("stack_hi=1048576"),
        "no stack_hi=1048576 in the module");
};

def parity_case() {
    let cc = yc.CYCC;
    let probe = yt.tmp("ccprobe");
    let p = yt.cmd([cc, "--target=web", "--emit=wasm", "-o", probe, DIR + "/w001_hello.y"]);
    p.cwd = yc.ROOT;
    p.merge = true;
    p.timeout = 300 * yt.SCALE;
    p.mem_kb = yc.PROG_MEM_KB;
    let pr = yt.run(p);
    if (pr.code != 0 || !fs.exists(probe)) {
        yt.fail("cycc and ycc emit identical modules", "cycc could not compile the probe: " + yt.clip(pr.out, 200));
        return;
    };
    let y = webcc();
    let names = ["w001_hello", "w002_args_env", "w003_exit"];
    let all = true;
    let why = "";
    foreach (n in names) {
        let a = yt.tmp("cy" + n);
        let b = yt.tmp("yy" + n);
        let ca = yt.cmd([cc, "--target=web", "--emit=wasm", "-o", a, DIR + "/" + n + ".y"]);
        ca.cwd = yc.ROOT;
        ca.merge = true;
        ca.timeout = 300 * yt.SCALE;
        ca.mem_kb = yc.PROG_MEM_KB;
        let cb = yt.cmd([y, "--target=web", "--emit=wasm", "-o", b, DIR + "/" + n + ".y"]);
        cb.cwd = yc.ROOT;
        cb.merge = true;
        cb.timeout = 300 * yt.SCALE;
        cb.mem_kb = yc.PROG_MEM_KB;
        let ra = yt.run(ca);
        let rb = yt.run(cb);
        if (ra.code != 0 || rb.code != 0) { all = false; why = n + ": exits " + tostring(ra.code) + "/" + tostring(rb.code); }
        else if (!yt.same_file(a, b)) { all = false; why = n + ": modules differ"; };
    };
    yt.check("cycc and ycc emit identical modules", all, why);
};

// ── web-forms: every IR form has a web lowering ─────────────────────────
// ycc --web-forms lowers one synthetic instance of each form; a form added to
// ir_schema.y without a web lowering is named here instead of in a compile.
def forms_case() {
    init();
    let c = yt.cmd([webcc(), "--web-forms"]);
    c.cwd = yc.ROOT;
    c.merge = true;
    c.timeout = 120 * yt.SCALE;
    c.mem_kb = yc.PROG_MEM_KB;
    let r = yt.run(c);
    let lines = yt.lines(r.out);
    let forms = 0;
    let texts = 0;
    let bad: [str] = [];
    let want = 0;
    foreach (l in lines) {
        if (l.starts_with("form ")) {
            forms += 1;
            let rest = l[5:];
            let sp = rest.index_of(" ");
            let n = rest[0:sp].tolong();
            if (n == none || n! != want) { bad += "form numbering at '" + l + "'"; };
            want += 1;
            if (l.contains(": error:")) { bad += l; };
        } else if (l.starts_with("text ")) {
            texts += 1;
            if (l.contains(": error:")) { bad += l; };
        };
    };
    yt.check("web-forms: every IR form lowers", r.code == 0 && forms > 100 && texts > 0 && bad.length == 0,
        "exit=" + tostring(r.code) + " forms=" + tostring(forms) + " texts=" + tostring(texts) + " " + yt.clip(join(bad, "; "), 400));
};

// ── web-census: the std pack and the compiler itself lower ──────────────
// Every std unit linked into one program, plus src/y/ycc.y: no "unsupported
// instruction", and the module validates.
def census_case() {
    init();
    let d = yt.tmp_dir("webcensus");
    yt.write(d + "/std.y", "import fs;\nimport net;\nimport struct;\nimport crypto;\nimport x509;\nimport tls;\n"
        + "import http;\nimport regex;\nimport json;\nputs(\"ok\\n\");\n");
    let bad = "";
    let mods = [d + "/std.y", yc.ROOT + "/src/y/ycc.y"];
    let i = 0;
    foreach (f in mods) {
        let wasm = d + "/c" + tostring(i) + ".wasm";
        let c = compile(["--gc=auto"], f, wasm);
        i += 1;
        if (c.code != 0 || c.out.contains("unsupported instruction")
            || c.out.contains("kernel/AArch64")) {
            bad += " " + fs.path_basename(f) + ": " + yt.clip(c.out, 300);
        } else {
            let v = validate(wasm);
            if (v.code != 0) { bad += " validate " + fs.path_basename(f) + ": " + yt.clip(v.out, 200); };
        };
    };
    // ... and every std unit on its own, so a unit the linked program does not
    // reach is still lowered (the kernel's units compile only under --target=kernel).
    foreach (f in yt.files(yc.ROOT + "/src/y/std", "", ".y")) {
        if (yt.is_variant(f)) { continue; };
        let b = fs.path_basename(f);
        if (b == "kernel.y" || b == "kmem.y" || b == "yfs.y" || b == "fd.y") { continue; };
        let c = compile(["--gc=auto"], f, d + "/u.wasm");
        if (c.code != 0 || c.out.contains("unsupported instruction")
            || c.out.contains("kernel/AArch64")) {
            bad += " " + b + ": " + yt.clip(c.out, 300);
        };
    };
    yt.check("web-census: the std pack, every std unit and ycc.y lower", bad == "", bad);
    fs.remove_all(d);
};

// ── web: every native fixture through the Node host ─────────────────────
// t*.y: compile for web, run under the Node host with a fixed fuel, compare
// the exit status and stdout (NAME.expected.web overrides NAME.expected).
// NAME.skip.web holds the reason a fixture cannot run there (a syscall the
// host answers with ENOSYS, or an asm probe the S6 rule refuses).
// e*.y: the rejection text must be exactly what the native run says.
let NDIR = "";

def nfixture(file: str, base: str) -> void {
    init();
    if (NDIR == "") { NDIR = yc.ROOT + "/test/y/native"; };
    let skip = NDIR + "/" + base + ".skip.web";
    if (fs.is_file(skip)) {
        yt.skip(base, yt.read(skip).trim());
        return;
    };
    let src = yt.read(file);
    let flags: [str] = [];
    let scratch = false;
    foreach (line in src.split("\n")) {
        if (line.starts_with("// flags: ") && flags.length == 0) {
            foreach (f in line[10:].split(" ")) {
                if (f != "") { flags += f; };
            };
        };
        if (line.starts_with("// scratch")) { scratch = true; };
    };
    let wasm = yt.tmp("wbin");
    let c = yt.cmd([webcc(), "--target=web", "--emit=wasm"] + flags + ["-o", wasm, file]);
    c.cwd = yc.ROOT;
    c.merge = true;
    c.timeout = 180 * yt.SCALE;
    c.mem_kb = yc.PROG_MEM_KB;
    let cr = yt.run(c);
    if (cr.code != 0) {
        yt.fail(base, "compile: " + yt.clip(cr.out, 300));
        fs.remove_file(wasm);
        return;
    };
    let stdin = NDIR + "/" + base + ".stdin";
    let r = yt.cmd([NODE, "--disable-wasm-trap-handler", HOST, "run", "--fuel=200000", wasm]);
    r.cwd = if (scratch) { yt.tmp_dir("wnat") } else { yc.ROOT };
    r.merge = true;
    r.timeout = 60 * yt.SCALE;
    r.mem_kb = yc.PROG_MEM_KB;
    if (fs.is_file(stdin)) { r.stdin = stdin; };
    let o = yt.run(r);
    if (scratch) { fs.remove_all(r.cwd); };
    fs.remove_file(wasm);
    let want_ec = yt.num(yt.read(NDIR + "/" + base + ".exit").trim(), 0);
    let wf = fs.read_file(NDIR + "/" + base + ".expected.web");
    if (wf == none) { wf = fs.read_file(NDIR + "/" + base + ".expected"); };
    let want = if (wf == none) { "" } else { wf! };
    if (o.code == want_ec && o.out == want) {
        yt.pass(base);
    } else {
        yt.fail(base, "exit=" + tostring(o.code) + " (want " + tostring(want_ec) + "), diff: " + yt.first_diff(want, o.out));
    };
};

def nreject(file: str, base: str) -> void {
    init();
    let wants: [str] = [];
    let flags: [str] = [];
    foreach (line in yt.read(file).split("\n")) {
        if (line.starts_with("// flags: ")) { flags += line[10:].split(" "); };
        let i = line.index_of("// expect-error: ");
        if (i >= 0) { wants += line[i + 17:]; };
    };
    let skip = yc.ROOT + "/test/y/native/" + base + ".skip.web";
    if (fs.is_file(skip)) {
        yt.skip(base, yt.read(skip).trim());
        return;
    };
    let wasm = yt.tmp("wbin");
    // From the fixture's own directory with its bare name, so a message
    // naming an imported file reads the same as the native run's.
    let c = yt.cmd([webcc(), "--target=web", "--emit=wasm"] + flags + ["-o", wasm, base + ".y"]);
    c.cwd = yc.ROOT + "/test/y/native";
    c.merge = true;
    c.timeout = 120 * yt.SCALE;
    c.mem_kb = yc.PROG_MEM_KB;
    let r = yt.run(c);
    fs.remove_file(wasm);
    if (r.code == 0) {
        yt.fail(base, "compilation succeeded under --target=web, expected: " + (if (wants.length > 0) { wants[0] } else { "an error" }));
        return;
    };
    foreach (w in wants) {
        if (!r.out.contains(w)) {
            yt.fail(base, "wrong error (want '" + w + "', got: " + yt.clip(r.out, 400) + ")");
            return;
        };
    };
    yt.pass(base + " (rejected)");
};

// W4: the private numbers in the runtime blocks, the Node ABI table and the
// ABI chapter of docs/TARGETS.md are one table, not three copies that drift.
def web_abi_case() {
    init();
    let ws = yt.read(yc.ROOT + "/src/y/arch/web.s");
    let ab = yt.read(yc.ROOT + "/src/web/abi.js");
    let tg = yt.read(yc.ROOT + "/docs/TARGETS.md");
    let cases = [["y_os_host_sym", "HOST_SYM", "22785"], ["y_os_host_call", "HOST_CALL", "22786"],
        ["y_os_audio_devs", "AUDIO_DEVS", "22787"], ["y_os_audio_open", "AUDIO_OPEN", "22788"],
        ["y_os_audio_write", "AUDIO_WRITE", "22789"], ["y_os_audio_close", "AUDIO_CLOSE", "22790"]];
    let bad = "";
    foreach (c in cases) {
        if (!(ws.contains(c[0] + ":") && ws.contains("$" + c[2]))) { bad += " web.s:" + c[0]; };
        if (!ab.contains(c[1] + ": " + c[2])) { bad += " abi.js:" + c[1]; };
        if (!tg.contains("| " + c[2] + " | `" + c[1] + "`")) { bad += " TARGETS.md:" + c[1]; };
    };
    yt.check("web-abi: web.s, abi.js and docs/TARGETS.md agree", bad == "", bad);
};

// W4's end-to-end oracle: ycc compiled for web compiles a program under the
// Node host, and the ELF is byte-identical to the native compiler's.
def compiler_case() {
    init();
    let d = yt.tmp_dir("oracle");
    let wasm = d + "/ycc.wasm";
    let c = yt.cmd([webcc(), "--target=web", "--emit=wasm", "--gc=auto", "--std=source", "-o", wasm, yc.ROOT + "/src/y/ycc.y"]);
    c.cwd = yc.ROOT;
    c.merge = true;
    c.timeout = 600 * yt.SCALE;
    c.mem_kb = yc.PROG_MEM_KB;
    let cr = yt.run(c);
    if (cr.code != 0) {
        yt.fail("the compiler under Node", "compile: " + yt.clip(cr.out, 300));
        fs.remove_all(d);
        return;
    };
    let q = chr(34);
    yt.write(d + "/hello.y", "puts(" + q + "hello from wasm ycc" + chr(92) + "n" + q + ");" + chr(10));
    let hr = yt.cmd([NODE, "--disable-wasm-trap-handler", HOST, "run", wasm, "--std=source", "-o", d + "/hello", d + "/hello.y"]);
    hr.cwd = yc.ROOT;
    hr.merge = true;
    hr.timeout = 300 * yt.SCALE;
    let r = yt.run(hr);
    let n = yt.cmd([yc.YCC, "--std=source", "-o", d + "/hello.native", d + "/hello.y"]);
    n.cwd = yc.ROOT;
    n.merge = true;
    n.timeout = 120 * yt.SCALE;
    let nr = yt.run(n);
    let same = r.code == 0 && nr.code == 0 && fs.exists(d + "/hello") && yt.same_file(d + "/hello", d + "/hello.native");
    let out = if (same) { yc.run_bin(d + "/hello", [], "", 10).out } else { "" };
    yt.check("the compiler under Node emits the native ELF byte for byte",
        same && out == "hello from wasm ycc\n",
        "wasm=" + tostring(r.code) + " native=" + tostring(nr.code) + " same=" + tostring(same)
            + " out='" + yt.clip(out, 120) + "' " + yt.clip(r.out + nr.out, 200));
    fs.remove_all(d);
};

def web_cases() -> [yt.Case] {
    init();
    NDIR = yc.ROOT + "/test/y/native";
    let cs: [yt.Case] = [];
    foreach (f in yt.files(NDIR, "t", ".y") + yt.files(NDIR, "e", ".y")) {
        let base = fs.path_stem(f);
        if (base.starts_with("e")) {
            cs += yt.case_of("web", base, () => nreject(f, base));
        } else {
            cs += yt.case_of("web", base, () => nfixture(f, base));
        };
    };
    cs += yt.case_of("web", "web-abi", web_abi_case);
    cs += yt.case_of("web", "the compiler under Node", compiler_case);
    cs
};

// ── test/web: the W4 fixtures ──────────────────────────────────────────
// A fixture's inputs sit beside it: NAME.expected (stdout), NAME.exit (the
// status, 0 when absent), NAME.stdin, NAME.args, NAME.env, NAME.cflags (compile
// flags) and NAME.runflags (host flags, before the module).  NAME.skip holds
// the reason it cannot run here, and the case is skipped with that text.
def web_fixture(name: str) {
    init();
    let skip = DIR + "/" + name + ".skip";
    if (fs.is_file(skip)) {
        yt.skip(name, yt.read(skip).trim());
        return;
    };
    let cflags = read_words(name, ".cflags");
    let wasm = yt.tmp("wfx");
    let c = yt.cmd([webcc(), "--target=web", "--emit=wasm"] + cflags + ["-o", wasm, DIR + "/" + name + ".y"]);
    c.cwd = yc.ROOT;
    c.merge = true;
    c.timeout = 300 * yt.SCALE;
    c.mem_kb = yc.PROG_MEM_KB;
    let cr = yt.run(c);
    if (cr.code != 0) {
        yt.fail(name, "compile: " + yt.clip(cr.out, 300));
        fs.remove_file(wasm);
        return;
    };
    let runflags = read_words(name, ".runflags");
    let args = read_words(name, ".args");
    let env = fixture_env(name);
    let r = yt.cmd([NODE, "--disable-wasm-trap-handler", HOST, "run"] + runflags + [wasm] + args);
    r.cwd = yc.ROOT;
    r.merge = true;
    r.timeout = 120 * yt.SCALE;
    r.mem_kb = yc.PROG_MEM_KB;
    if (env.length > 0) { r.env = env; };
    let stdin = DIR + "/" + name + ".stdin";
    if (fs.is_file(stdin)) { r.stdin = stdin; };
    let o = yt.run(r);
    fs.remove_file(wasm);
    let want_ec = yt.num(yt.read(DIR + "/" + name + ".exit").trim(), 0);
    let want = expected(name);
    if (o.code == want_ec && o.out == want) {
        yt.pass(name);
    } else {
        yt.fail(name, "exit=" + tostring(o.code) + " (want " + tostring(want_ec) + "), diff: " + yt.first_diff(want, o.out));
    };
};

def web_fixture_cases() -> [yt.Case] {
    init();
    let cs: [yt.Case] = [];
    foreach (f in yt.files(DIR, "w", ".y")) {
        let base = fs.path_stem(f);
        if (base == "w001_hello" || base == "w002_args_env" || base == "w003_exit") { continue; };
        // the browser fixtures are assertions of ?ytest=1, not Node stdout: the
        // web-browser suite owns them (su_webb.y)
        if (base in ["w100_console", "w101_persist", "w102_feature_check", "w103_pause_hidden"]) { continue; };
        cs += yt.case_of("web-smoke", base, () => web_fixture(base));
    };
    cs
};

// W4/S3: -g adds the name section and the ysrc map the host turns a wasm
// frame into file:line with.  Without -g neither is in the module.
def debug_case() {
    init();
    let plain = yt.tmp("wdbg0");
    let dbg = yt.tmp("wdbg1");
    let c0 = compile([], DIR + "/w001_hello.y", plain);
    let c1 = compile(["-g"], DIR + "/w001_hello.y", dbg);
    let t0 = "";
    let t1 = "";
    if (c0.code == 0 && fs.exists(plain)) { t0 = from_bytes(yt.bytes_of(plain)); };
    if (c1.code == 0 && fs.exists(dbg)) { t1 = from_bytes(yt.bytes_of(dbg)); };
    yt.check("-g adds the name section and ysrc",
        c1.code == 0 && t0.contains("yweb") && !t0.contains("ysrc=1")
            && t1.contains("ysrc=1") && t1.contains("w001_hello.y:")
            && t1.contains("name"),
        "exit=" + tostring(c1.code) + " plain has ysrc=" + tostring(t0.contains("ysrc=1"))
            + " debug has ysrc=" + tostring(t1.contains("ysrc=1"))
            + " file=" + tostring(t1.contains("w001_hello.y:")));
    let v = validate(dbg);
    yt.check("-g module validates", v.code == 0 && v.out.contains("ok abi=1"), yt.clip(v.out, 200));
};

def cases() -> [yt.Case] {
    init();
    [
        yt.case_of("web-smoke", "driver writes a module", driver_case),
        yt.case_of("web-smoke", "w001_hello runs", hello_case),
        yt.case_of("web-smoke", "w002 argv and env", args_case),
        yt.case_of("web-smoke", "exit(7) is status 7", exit_case),
        yt.case_of("web-smoke", "refusals", refusal_case),
        yt.case_of("web-smoke", "--emit=wat", wat_case),
        yt.case_of("web-smoke", "web site", page_case),
        yt.case_of("web-smoke", "host selftest", host_case),
        yt.case_of("web-smoke", "environment failures", failure_case),
        yt.case_of("web-smoke", "pack-same", pack_same_case),
        yt.case_of("web-smoke", "--web=stack", options_case),
        yt.case_of("web-smoke", "C/Y parity", parity_case),
        yt.case_of("web-smoke", "web-forms", forms_case),
        yt.case_of("web-smoke", "web-census", census_case),
        yt.case_of("web-smoke", "-g sections", debug_case),
    ] + web_fixture_cases()
};
