// su_pkg.y -- packages: `ycc build` and `ycc vendor` (pkg.y; ycc.y
// build_project; native.y compile_package and the package objects).
//
// A project is a directory with a y.toml; `ycc build` compiles each package it
// depends on once (DIR/build/obj keeps the objects) and links every [bin] into
// DIR/build. Checks: a diamond of path dependencies builds and runs, each
// package's top level once and dependencies first; names stay qualified;
// records, closures, optionals, defaults, string globals, recursive types and
// optional record fields cross the boundary, and a package's globals are
// read-only; a rebuild compiles nothing and gives the same bytes; a body change
// recompiles that package only, an interface change its importers too; a
// damaged object, or one another compiler wrote, is rebuilt; a fresh build
// gives the same bytes as a cached one, and the C copy the same as ycc; inside
// a package, std modules, relative imports, its src roots, argv and exec work;
// --no-exec and -g reach the packages; errors and warnings name their file;
// every manifest, graph and command-line error; git dependencies are fetched,
// pinned in y.lock, and vendored. Each numbered section is a case of its own.
import fs;
import yt;
import yc;

let D = "";

def ycc_bin() -> str { yc.abs_path(yt.env("YSELF", yc.YCC)) };

def mk(path: str, text: str) {
    fs.make_dirs(fs.path_dirname(path));
    yt.write(path, text);
};

def append(path: str, text: str) { fs.append_file(path, text); };

def edit(path: str, from: str, to: str) { yt.write(path, yt.read(path).replace(from, to)); };

// s without its trailing newlines (what $(cat f) compares)
def chomp(s: str) -> str {
    let n = s.length;
    while (n > 0 && s[n - 1] == 10) { n -= 1; };
    s[0:n]
};

def last_line(s: str) -> str {
    let l = yt.lines(s);
    if (l.length == 0) { "" } else { l[l.length - 1] }
};

def in_dir(cc: str, dir: str, args: [str]) -> yt.Res {
    let c = yt.cmd([cc] + args);
    c.cwd = dir;
    c.merge = true;
    c.timeout = 120 * yt.SCALE;
    yt.run(c)
};

// `cc build args...` in dir
def yb(cc: str, dir: str, args: [str]) -> yt.Res { in_dir(cc, dir, ["build"] + args) };

def same_text(name: str, want: str, got: str) {
    yt.check(name, chomp(got) == want, "want: " + yt.clip(want, 300) + "  got: " + yt.clip(got, 300));
};

def runs(name: str, want: str, bin: str, args: [str]) {
    same_text(name, want, yc.run_bin(bin, args, "", 10).out);
};

// The output lines that are not "compiling ...".
def built_lines(s: str) -> str {
    let r: [str] = [];
    foreach (l in yt.lines(s)) {
        if (!l.starts_with("compiling ")) { r += l; };
    };
    join(r, "\n")
};

// A package object without its key (the compiler's own hash differs between
// ycc and the C copy; the rest must not).
def obj_body(path: str) -> [byte] {
    let b = yt.bytes_of(path);
    if (b.length <= 11) { return []; };
    let t = b[11:];
    let i = 0;
    while (i < t.length && t[i] >= 48 && t[i] <= 57) { i += 1; };
    if (i < t.length && t[i] == 58) {
        let j = i + 1;
        while (j < t.length && t[j] >= 48 && t[j] <= 57) { j += 1; };
        if (j < t.length && t[j] == 45) {
            let k = j + 1;
            while (k < t.length && t[k] >= 48 && t[k] <= 57) { k += 1; };
            return t[k:];
        };
    };
    t
};

// A fresh build by ycc and one by the C copy print the same and write the
// same programs and objects.
def agree(name: str, dir: str, args: [str]) {
    let save = yt.tmp_dir("agree");
    fs.remove_all(dir + "/build");
    let a = yb(ycc_bin(), dir, args);
    if (a.code != 0) {
        yt.fail("C copy agrees: " + name, "ycc: " + yt.clip(a.out, 300));
        return;
    };
    yt.sh("cp -R " + yt.q(dir + "/build/.") + " " + yt.q(save));
    fs.remove_all(dir + "/build");
    let b = yb(yc.CYCC, dir, args);
    if (b.code != 0) {
        yt.fail("C copy agrees: " + name, "cycc: " + yt.clip(b.out, 300));
        return;
    };
    let bad = if (a.out != b.out) { "messages differ;" } else { "" };
    foreach (f in yt.ls(save)) {
        if (fs.is_file(save + "/" + f) && !yt.same_file(save + "/" + f, dir + "/build/" + f)) { bad += " " + f + " differs;"; };
    };
    foreach (f in yt.files(save + "/obj", "", ".yo")) {
        let n = fs.path_basename(f);
        if (obj_body(f) != obj_body(dir + "/build/obj/" + n)) { bad += " obj/" + n + " differs;"; };
    };
    fs.remove_all(save);
    yt.check("C copy agrees: " + name, bad == "", bad);
};

// `ycc CMD args...` in dir exits 1, its last line `want`, and the C copy says
// the same.
def fails_cmd(cmd: str, name: str, want: str, dir: str, args: [str]) {
    foreach (cc in [ycc_bin(), yc.CYCC]) {
        let r = in_dir(cc, dir, [cmd] + args);
        let lines = yt.lines(r.out);
        let tail3 = join(lines[if (lines.length > 3) { lines.length - 3 } else { 0 }:], "|");
        yt.check(name + " (" + fs.path_basename(cc) + ")", r.code == 1 && last_line(r.out) == want,
            "exit " + tostring(r.code) + ", want: " + want + "  got: " + tail3);
    };
};

def fails(name: str, want: str, dir: str, args: [str]) { fails_cmd("build", name, want, dir, args); };

// ── 1. a diamond: app -> a, b, c; a -> c; b -> c ─────────────────────────

let APP_OUT = "init c\ninit a\ninit b\nmain\n42\n3 1\nhello world/hello b\nhello 3\nsome 5\n8 4 6\n-3q\"x\ttrue122-1.500000-|1sfalse1212.5000009";

def diamond() {
    let p = D + "/p1";
    mk(p + "/c/y.toml", "[package]\nname = \"c\"\nlib = \"lib.y\"\n");
    mk(p + "/c/lib.y", "puts(\"init c\\n\");\nlet greeting = \"hello\";\nlet count = 3;\ntype Pt = { x: long, y: long };\n"
        + "def mkpt(x: long, y: long) -> Pt { { x: x, y: y } };\ndef norm1(p: Pt) -> long { p.x + p.y };\n"
        + "def adder(n: long) -> (long) -> long { def(x: long) -> long { x + n } };\n"
        + "def greet(who: str = \"world\") -> str { greeting + \" \" + who };\n"
        + "def maybe(n: long) -> long? { if (n > 0) { some(n) } else { none } };\n"
        + "def shout(s: str) -> str { s.upper() };\ndef sq(x: long) -> long { x * x };\n"
        + "def dfl(a: long = -3, s: str = \"q\\\"x\\t\", b: bool = true, ch: byte = 'z', fl: float = -1.5, o?: long) -> str {\n"
        + "    let os = \"-\";\n    if (o != none) { os = tostring(unwrap(o)); 0; } else { 0; };\n"
        + "    tostring(a) + s + tostring(b) + tostring(ch) + tostring(fl) + os\n};\n");
    mk(p + "/a/y.toml", "[package]\nname = \"a\"\nlib = \"a.y\"   # a comment\n\n[dependencies]\nc = { path = \"../c\" }\n");
    mk(p + "/a/a.y", "import c;\nputs(\"init a\\n\");\nlet doubled = c.count * 2;\n"
        + "def twice(n: long) -> long { c.adder(n)(n) };\ndef pt() -> { x: long, y: long } { c.mkpt(1, 2) };\n");
    mk(p + "/b/y.toml", "[package]\nname = 'b'\nlib = \"b.y\"\n[dependencies]\nc = { path = \"../c/\" }\n");
    mk(p + "/b/b.y", "import c;\nputs(\"init b\\n\");\ndef hi() -> str { c.greet() + \"/\" + c.greet(\"b\") };\n");
    mk(p + "/app/y.toml", "# the app\n[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[bin]\napp = \"main.y\"\ntool = \"tool.y\"\n\n"
        + "[dependencies]\na = { path = \"../a\" }\nb = { path = \"../b\" }\nc = { path = \"../c\" }\n");
    mk(p + "/app/main.y", "import a;\nimport b;\nimport c;\nputs(\"main\\n\");\nputs(tostring(a.twice(21)) + \"\\n\");\n"
        + "let p = a.pt();\nputs(tostring(c.norm1(p)) + \" \" + tostring(p.x) + \"\\n\");\nputs(b.hi() + \"\\n\");\n"
        + "puts(c.greeting + \" \" + tostring(c.count) + \"\\n\");\nlet m = c.maybe(5);\n"
        + "if (m != none) { puts(\"some \" + tostring(unwrap(m)) + \"\\n\"); } else { puts(\"none\\n\"); };\n"
        + "def sq(x: long) -> long { x * x * x };\n"
        + "puts(tostring(sq(2)) + \" \" + tostring(c.sq(2)) + \" \" + tostring(a.doubled) + \"\\n\");\n"
        + "puts(c.dfl() + \"|\" + c.dfl(1, \"s\", false, 'y', 2.5, 9) + \"\\n\");\n");
    mk(p + "/app/tool.y", "import c;\nputs(\"tool \" + c.shout(c.greet(\"t\")) + \"\\n\");\n");
    let app = p + "/app";
    let all = "compiling c\ncompiling a\ncompiling b\nbuilt build/app\nbuilt build/tool";
    let r = yb(ycc_bin(), app, []);
    if (r.code == 0) {
        same_text("build compiles each package once, dependencies first", all, r.out);
    } else {
        yt.fail("a diamond builds", yt.clip(r.out, 300));
    };
    runs("the program runs: each package's top level once, in order", APP_OUT, app + "/build/app", []);
    runs("a bin that needs only c links only c (and its std unit)", "init c\ntool HELLO T", app + "/build/tool", []);
    // 2. the object cache
    let app1 = yt.bytes_of(app + "/build/app");
    same_text("a rebuild compiles nothing", "built build/app\nbuilt build/tool", yb(ycc_bin(), app, []).out);
    yt.check("a rebuild gives the same bytes", yt.bytes_of(app + "/build/app") == app1, "");
    edit(p + "/c/lib.y", "{ x + n }", "{ n + x }");
    same_text("a body change recompiles that package only", "compiling c\nbuilt build/app\nbuilt build/tool",
        yb(ycc_bin(), app, []).out);
    append(p + "/c/lib.y", "def extra() -> long { 1 };\n");
    same_text("an interface change recompiles the importers too", all, yb(ycc_bin(), app, []).out);
    runs("and the program still runs", APP_OUT, app + "/build/app", []);
    let app2 = yt.bytes_of(app + "/build/app");
    let cyo = yt.bytes_of(app + "/build/obj/c.yo");
    fs.write_bytes(app + "/build/obj/c.yo", cyo[0:30]);
    yt.write(app + "/build/obj/a.yo", "garbage\n");
    same_text("a damaged object is rebuilt", "compiling c\ncompiling a\nbuilt build/app\nbuilt build/tool", yb(ycc_bin(), app, []).out);
    fs.remove_all(app + "/build");
    yb(ycc_bin(), app, []);
    yt.check("a fresh build gives the same bytes as a cached one", yt.bytes_of(app + "/build/app") == app2, "");
    // A byte flipped inside the object -- in a string constant, where the key
    // and the length both stay right -- once rode through the cache: the object
    // carries a checksum over its own bytes now.
    let yo = app + "/build/obj/c.yo";
    let ob = yt.bytes_of(yo);
    let off = from_bytes(ob).index_of("hello");
    if (off >= 0) {
        ob[off + 1] = 72;
        fs.write_bytes(yo, ob);
        same_text("a flipped byte inside an object is rebuilt", "compiling c\nbuilt build/app\nbuilt build/tool",
            yb(ycc_bin(), app, []).out);
        runs("and the program still prints what it should", APP_OUT, app + "/build/app", []);
    } else {
        yt.skip("a flipped byte inside an object is rebuilt", "no string constant in the object");
    };
    agree("the diamond", app, []);
    if (yc.CYCC == ycc_bin()) {
        yt.skip("an object another compiler wrote is rebuilt", "$CYCC is $YSELF");
    } else {
        same_text("an object another compiler wrote is rebuilt", all, yb(ycc_bin(), app, []).out);
    };
    // an object knows its files by the paths the build saw: from elsewhere they
    // are other paths, and the packages compile again
    let el = yt.tmp_dir("elsewhere");
    let e = in_dir(ycc_bin(), el, ["build", app]);
    same_text("build DIR: paths start at DIR", "built " + app + "/build/app\nbuilt " + app + "/build/tool", built_lines(e.out));
    // 3. what a bin may not do with a package
    mk(app + "/bad.y", "import c;\nc.count = 5;\nc.greeting += \"x\";\nc.count++;\nc.nope();\nc.greet(1, 2);\n");
    yt.write(app + "/y.toml", "[package]\nname = \"app\"\n[bin]\nbad = \"bad.y\"\n[dependencies]\nc = { path = \"../c\" }\n");
    same_text("a package's globals are read-only, its names checked",
        "bad.y:2:1: error: cannot assign to constant 'c.count'\nbad.y:3:12: error: cannot assign to constant 'c.greeting' ('+=')\n"
        + "bad.y:4:8: error: cannot assign to constant 'c.count' ('++')\nbad.y:5:7: error: undefined function 'c.nope'\n"
        + "bad.y:6:8: error: 'c.greet' takes 1 args, got 2", built_lines(yb(ycc_bin(), app, []).out));
    let saved = yt.read(p + "/c/lib.y");
    append(p + "/c/lib.y", "def broken() -> long { \"s\" + 1 };\n");
    same_text("an error in a package names its file", "compiling c\n../c/lib.y:18:1: error: 'broken' body: expected long, got str",
        yb(ycc_bin(), app, []).out);
    yt.write(p + "/c/lib.y", saved);
};

// 3b. recursive types cross a package: an exported function's type names them
// (tcode spells a tref out once), and the bin's own structurally equal union is
// the same type, its records the same tags
def recursive() {
    let r = D + "/rec";
    mk(r + "/ast/y.toml", "[package]\nname = \"ast\"\nlib = \"lib.y\"\n");
    mk(r + "/ast/lib.y", "type Expr = Num | Add;\ntype Num = { n: long };\ntype Add = { l: Expr, r: Expr };\n"
        + "def num(n: long) -> Expr { { n: n } };\ndef add(l: Expr, r: Expr) -> Expr { { l: l, r: r } };\n"
        + "def ev(e: Expr) -> long {\n    match e { Num x => x.n, Add a => ev(a.l) + ev(a.r) }\n};\n");
    mk(r + "/app/y.toml", "[package]\nname = \"app\"\n[bin]\napp = \"main.y\"\n[dependencies]\nast = { path = \"../ast\" }\n");
    mk(r + "/app/main.y", "import ast;\ntype E = N | A;\ntype N = { n: long };\ntype A = { l: E, r: E };\n"
        + "def depth(e: E) -> long {\n    match e { N => 1, A a => 1 + depth(a.l) }\n};\n"
        + "let e = ast.add(ast.num(1), ast.add(ast.num(2), ast.num(3)));\n"
        + "puts(tostring(ast.ev(e)) + \" \" + tostring(depth(e)) + \"\\n\");\n"
        + "let mine: E = { l: { n: 4 }, r: { n: 5 } };\nputs(tostring(ast.ev(mine)) + \"\\n\");\n");
    let b = yb(ycc_bin(), r + "/app", []);
    yt.check("a package's recursive types build", b.code == 0, yt.clip(b.out, 300));
    runs("recursive types cross a package: one type, one tag", "6 2\n9", r + "/app/build/app", []);
    agree("recursive types", r + "/app", []);
};

// 3c. optional record fields cross a package: an exported function's parameter
// type keeps them optional (tcode writes `name?`)
def optional_fields() {
    let o = D + "/optf";
    mk(o + "/http/y.toml", "[package]\nname = \"http\"\nlib = \"lib.y\"\n");
    mk(o + "/http/lib.y", "type Opts = { url: str, timeout?: long, tag?: str };\ndef get(path: str, opts?: Opts) -> str {\n"
        + "    if (is_some(opts)) {\n        let o = opts!;\n"
        + "        path + \" \" + o.url + \" \" + tostring(o.timeout) + \" \" + tostring(o.tag)\n    } else { path }\n};\n"
        + "def show(o: Opts) -> str { o.url + \" \" + tostring(o.timeout) };\n");
    mk(o + "/app/y.toml", "[package]\nname = \"app\"\n[bin]\napp = \"main.y\"\n[dependencies]\nhttp = { path = \"../http\" }\n");
    mk(o + "/app/main.y", "import http;\nputs(http.get(\"a\") + \"\\n\");\nputs(http.get(\"b\", { url: \"u\", timeout: 5 }) + \"\\n\");\n"
        + "puts(http.show({ url: \"v\" }) + \" | \" + http.show({ url: \"w\", timeout: none, tag: \"t\" }) + \"\\n\");\n");
    let b = yb(ycc_bin(), o + "/app", []);
    yt.check("a package's optional fields build", b.code == 0, yt.clip(b.out, 300));
    runs("optional record fields cross a package", "a\nb u 5 none\nv none | w none", o + "/app/build/app", []);
    agree("optional fields", o + "/app", []);
};

// ── 4. inside a package: std, relative and root imports; argv, exec ─────
def inside() {
    let q = D + "/p2";
    mk(q + "/u/y.toml", "[package]\nname = \"u\"\nlib = \"src/u.y\"\nsrc = [\"src\", \"more\"]\ndescription = \"utilities\"\n");
    mk(q + "/u/src/u.y", "import struct;\nimport helper from \"./helper.y\";\nimport extra;\n"
        + "def first_arg() -> str { let a = argv(); if (len(a) > 1) { a[1] } else { \"none\" } };\n"
        + "def run(cmd: str) -> long { exec(cmd) };\ndef h() -> long { helper.hval() + extra.xval() };\n"
        + "def packed() -> long { len(struct.u32be(7)) };\n");
    mk(q + "/u/src/helper.y", "def hval() -> long { 40 };\n");
    mk(q + "/u/more/extra.y", "def xval() -> long { 2 };\n");
    mk(q + "/app/y.toml", "[package]\nname = \"app\"\nlib = \"lib/app.y\"\n[bin]\napp = \"main.y\"\n[dependencies]\nu = { path = \"../u\" }\n");
    mk(q + "/app/lib/app.y", "import u;\ndef total() -> long { u.h() + 1 };\n");
    mk(q + "/app/main.y", "import u;\nimport app;\n"
        + "puts(u.first_arg() + \" \" + tostring(u.h()) + \" \" + tostring(app.total()) + \" \" + tostring(u.packed()) + \"\\n\");\n"
        + "u.run(\"echo ran\");\n");
    let app = q + "/app";
    let b = yb(ycc_bin(), app, []);
    if (b.code == 0) {
        same_text("a project's own lib is a package too", "compiling u\ncompiling app\nbuilt build/app", b.out);
    } else {
        yt.fail("a project with imports inside its packages builds", yt.clip(b.out, 300));
    };
    runs("std, relative and root imports, argv and exec inside a package", "xyz 42 43 4\nran", app + "/build/app", ["xyz"]);
    same_text("--no-exec reaches the packages", "compiling u\n../u/src/u.y:5:33: error: undefined function 'exec'",
        yb(ycc_bin(), app, ["--no-exec"]).out);
    agree("imports inside packages", app, []);
    agree("imports inside packages, -g", app, ["-g"]);
    if (yt.have("addr2line") && yt.have("nm")) {
        let a = "";
        foreach (l in yt.exe(["nm", app + "/build/app"]).out.split("\n")) {
            let w = yt.words(l);
            if (w.length == 3 && w[2] == "hval") { a = w[0]; };
        };
        let loc = chomp(yt.exe(["addr2line", "-e", app + "/build/app", "0x" + a]).out);
        yt.check("-g: a package's code maps to its file (" + loc + ")", loc.ends_with("/u/src/helper.y:1"),
            "hval at 0x" + a + ": " + loc);
    } else {
        yt.skip("-g: a package's code maps to its file", "no addr2line");
    };
    // warnings: a package's when it compiles (one built from its object prints
    // none), naming its file; a bin's on every build; -w drops them
    append(q + "/u/src/helper.y", "def warned() -> long { let w = 1; 2 };\n");
    append(app + "/main.y", "def main_w() -> long { let z = 3; 0 };\n");
    same_text("warnings name their files, and the build goes on",
        "compiling u\n../u/src/helper.y:2:24: warning: unused variable 'w'\ncompiling app\nmain.y:5:24: warning: unused variable 'z'\nbuilt build/app",
        yb(ycc_bin(), app, []).out);
    same_text("a package built from its object warns no more, a bin still does",
        "main.y:5:24: warning: unused variable 'z'\nbuilt build/app", yb(ycc_bin(), app, []).out);
    fs.remove_all(app + "/build");
    same_text("-w drops the warnings", "compiling u\ncompiling app\nbuilt build/app", yb(ycc_bin(), app, ["-w"]).out);
    agree("warnings", app, []);
};

// ── 4b. a wide level: its packages compile in parallel ──────────────────
// One wide level exercises the wave cap (BUILD_JOBS), the child mode a wave
// spawns (`ycc build --one`), and the sidecar a dispatched package's warnings
// ride back in -- none of which the bytes may depend on.
def wide() {
    let w = D + "/wide";
    mk(w + "/p0/y.toml", "[package]\nname = \"p0\"\nlib = \"lib.y\"\n");
    mk(w + "/p0/lib.y", "let base = 1;\ndef b0(a: long) -> long { a + base };\ndef w0() -> long { b0(0) };\n");
    let toml = "[package]\nname = \"app\"\n\n[bin]\napp = \"main.y\"\n\n[dependencies]\np0 = { path = \"../p0\" }\n";
    let main = "import p0;\n";
    let sum = "p0.w0()";
    for i in 1..6 {
        let n = "p" + tostring(i);
        let k = tostring(i);
        mk(w + "/" + n + "/y.toml", "[package]\nname = \"" + n + "\"\nlib = \"lib.y\"\n\n[dependencies]\np0 = { path = \"../p0\" }\n");
        mk(w + "/" + n + "/lib.y", "import p0;\ndef v" + k + "(a: long) -> long { let x = a + " + k + "; x * 2 };\n"
            + "def w" + k + "() -> long { v" + k + "(" + k + ") + p0.b0(0) };\n");
        toml += n + " = { path = \"../" + n + "\" }\n";
        main += "import " + n + ";\n";
        sum += " + " + n + ".w" + k + "()";
    };
    mk(w + "/app/y.toml", toml);
    mk(w + "/app/main.y", main + "puts(tostring(" + sum + ") + \"\\n\");\n");
    let app = w + "/app";
    let all = "compiling p0\ncompiling p1\ncompiling p2\ncompiling p3\ncompiling p4\ncompiling p5\nbuilt build/app";
    same_text("a wide level compiles, in waves of four", all, yb(ycc_bin(), app, []).out);
    // w0() is 0 + base = 1, and wi() is (i + i) * 2 + b0(0) = 4i + 1
    runs("and the program is right", "66", app + "/build/app", []);
    same_text("its rebuild spawns nothing", "built build/app", yb(ycc_bin(), app, []).out);
    fs.remove_file(app + "/build/obj/p3.yo");
    same_text("ycc build --one compiles one package and says nothing", "", yb(ycc_bin(), app, ["--one", "p3"]).out);
    same_text("and the object it wrote is current", "built build/app", yb(ycc_bin(), app, []).out);
    fails("ycc build --one with no such package", "error: no package 'zz' in .", app, ["--one", "zz"]);
    // a dispatched package's warnings come back in a sidecar and print where
    // the serial loop would have printed them: in package order, once
    append(w + "/p2/lib.y", "def extra2() -> long { let w = 9; 2 };\n");
    fs.remove_all(app + "/build");
    let six = "compiling p0\ncompiling p1\ncompiling p2\ncompiling p3\ncompiling p4\ncompiling p5\n";
    same_text("a dispatched package's warnings print in package order",
        six + "../p2/lib.y:4:24: warning: unused variable 'w'\nbuilt build/app", yb(ycc_bin(), app, []).out);
    fs.remove_all(app + "/build");
    same_text("-w reaches the children too", all, yb(ycc_bin(), app, ["-w"]).out);
    // --std-src has no pack, so the level goes out to nobody and the loop does
    // it, one package at a time
    fs.remove_all(app + "/build");
    same_text("--std-src builds the level in one process",
        "compiling p0\ncompiling p1\ncompiling p2\n../p2/lib.y:4:24: warning: unused variable 'w'\ncompiling p3\ncompiling p4\ncompiling p5\nbuilt build/app",
        yb(ycc_bin(), app, ["--std-src"]).out);
    runs("and the program is still right", "66", app + "/build/app", []);
    agree("a wide level", app, []);
    fails("ycc build --one with no name", "ycc: --one needs a package name", app, ["--one"]);
    // the child's own failures: before its dependencies are objects, and with a
    // dependency's object another compiler wrote
    fs.remove_all(app + "/build");
    fails("ycc build --one before its dependency", "error: package 'p0' was not compiled first", app, ["--one", "p3"]);
    yb(ycc_bin(), app, []);
    if (yc.CYCC == ycc_bin()) {
        yt.skip("ycc build --one with a dependency's foreign object", "$CYCC is $YSELF");
    } else {
        same_text("ycc build --one with a dependency's foreign object", "error: package 'p0' has no current object",
            yb(yc.CYCC, app, ["--one", "p3"]).out);
    };
};

// ── 5. errors: the manifest ──────────────────────────────────────────────
let MANIFESTS = [
    ["unclosed table header", "error: y.toml:1: expected ']' after the table name", "[package"],
    ["an array of tables", "error: y.toml:1: [[package]] has no place in a manifest", "[[package]]"],
    ["a bad table name", "error: y.toml:1: bad table name 'pack age'", "[pack age]"],
    ["a table twice", "error: y.toml:2: table [package] appears twice", "[package]\n[package]"],
    ["a line that is no key = value", "error: y.toml:2: expected 'key = value'", "[package]\nname"],
    ["a bad key", "error: y.toml:2: bad key 'na me'", "[package]\nna me = \"x\""],
    ["a key twice", "error: y.toml:3: duplicate key 'name'", "[package]\nname = \"a\"\nname = \"b\""],
    ["a bare value", "error: y.toml:2: expected a string, an array or an inline table after '='", "[package]\nname = x"],
    ["text after the value", "error: y.toml:2: unexpected text after the value", "[package]\nname = \"a\" b"],
    ["an unterminated string", "error: y.toml:2: unterminated string", "[package]\nname = \"a"],
    ["an unknown escape", "error: y.toml:2: unknown escape '\\q' in a string", "[package]\nname = \"a\\q\""],
    ["an array without a comma", "error: y.toml:2: expected ',' or ']' in an array", "[package]\nsrc = [\"a\" \"b\"]"],
    ["an array of numbers", "error: y.toml:2: expected a string", "[package]\nsrc = [1]"],
    ["an inline table without a key", "error: y.toml:2: expected a key", "[dependencies]\nx = { = \"a\" }"],
    ["an inline table without '='", "error: y.toml:2: expected '=' after 'path'", "[dependencies]\nx = { path \"a\" }"],
    ["an inline table's key twice", "error: y.toml:2: duplicate key 'path'", "[dependencies]\nx = { path = \"a\", path = \"b\" }"],
    ["an inline table without a comma", "error: y.toml:2: expected ',' or '}' in an inline table",
     "[dependencies]\nx = { path = \"a\" git = \"b\" }"],
    ["an unknown table", "error: y.toml:1: unknown table [nope]", "[nope]"],
    ["a key outside any table", "error: y.toml:1: 'name' is outside any table", "name = \"x\""],
    ["a name that is no string", "error: y.toml:2: 'name' must be a string", "[package]\nname = [\"a\"]"],
    ["no name", "error: y.toml: [package] has no name", "[package]\nlib = \"l.y\""],
    ["a name that is no identifier", "error: y.toml:2: package name 'my-app' is not an identifier", "[package]\nname = \"my-app\""],
    ["a name that is a keyword", "error: y.toml:2: package name 'while' is a keyword", "[package]\nname = \"while\""],
    ["src that is no array", "error: y.toml:3: 'src' must be an array of strings", "[package]\nname = \"a\"\nsrc = \"src\""],
    ["an unknown [package] key", "error: y.toml:3: unknown key 'edition' in [package]", "[package]\nname = \"a\"\nedition = \"1\""],
    ["a bin named obj", "error: y.toml:4: 'obj' cannot name a bin: build/obj is ycc's own", "[package]\nname = \"a\"\n[bin]\nobj = \"m.y\""],
    ["a dependency name that is no identifier", "error: y.toml:4: dependency name 'my-dep' is not an identifier",
     "[package]\nname = \"a\"\n[dependencies]\nmy-dep = { path = \"x\" }"],
    ["a dependency name that is a keyword", "error: y.toml:4: dependency name 'let' is a keyword",
     "[package]\nname = \"a\"\n[dependencies]\nlet = { path = \"x\" }"],
    ["an unknown dependency key", "error: y.toml:2: unknown key 'tag' in dependency 'x'", "[dependencies]\nx = { path = \"a\", tag = \"b\" }"],
    ["a version requirement", "error: y.toml:2: dependency 'x' must be { path = \"...\" } or { git = \"...\", rev = \"...\" }",
     "[dependencies]\nx = \"1.0\""],
    ["a path and a git", "error: y.toml:2: dependency 'x' has both a path and a git", "[dependencies]\nx = { path = \"a\", git = \"b\" }"],
    ["a rev without a git", "error: y.toml:2: dependency 'x' has a rev but no git", "[dependencies]\nx = { path = \"a\", rev = \"b\" }"],
    ["nothing to build", "error: y.toml has no [bin] and no lib: nothing to build", "[package]\nname = \"a\""],
    ["a missing bin", "error: cannot read file 'nope.y'", "[package]\nname = \"a\"\n[bin]\nx = \"nope.y\""],
];

def manifests() {
    let m = yt.tmp_dir("m");
    fails("no manifest", "error: cannot read 'y.toml'", m, []);
    foreach (t in MANIFESTS) {
        yt.write(m + "/y.toml", t[2] + "\n");
        fails(t[0], t[1], m, []);
    };
    fails("an unknown flag", "ycc: unknown flag '--bogus' (see ycc -h)", m, ["--bogus"]);
    fails("two directories", "error: ycc build takes one project directory", m, ["a", "b"]);
    fails_cmd("vendor", "vendor: two directories", "error: ycc vendor takes one project directory", m, ["a", "b"]);
    yt.write(m + "/y.toml", "[nope]\n");
    fails_cmd("vendor", "vendor: a broken manifest", "error: y.toml:1: unknown table [nope]", m, []);
};

// ── 6. errors: the dependency graph ──────────────────────────────────────
def graph() {
    let g = D + "/g";
    mk(g + "/c1/y.toml", "[package]\nname = \"c\"\nlib = \"c.y\"\n");
    mk(g + "/c1/c.y", "def v() -> long { 1 };\n");
    mk(g + "/c2/y.toml", "[package]\nname = \"c\"\nlib = \"c.y\"\n");
    mk(g + "/c2/c.y", "def v() -> long { 2 };\n");
    mk(g + "/a/y.toml", "[package]\nname = \"a\"\nlib = \"a.y\"\n[dependencies]\nc = { path = \"../c1\" }\n");
    mk(g + "/a/a.y", "import c;\ndef av() -> long { c.v() };\n");
    mk(g + "/b/y.toml", "[package]\nname = \"b\"\nlib = \"b.y\"\n[dependencies]\nc = { path = \"../c2\" }\n");
    mk(g + "/b/b.y", "import c;\ndef bv() -> long { c.v() };\n");
    mk(g + "/nolib/y.toml", "[package]\nname = \"nolib\"\n[bin]\nx = \"x.y\"\n");
    mk(g + "/cy1/y.toml", "[package]\nname = \"cy1\"\nlib = \"l.y\"\n[dependencies]\ncy2 = { path = \"../cy2\" }\n");
    mk(g + "/cy2/y.toml", "[package]\nname = \"cy2\"\nlib = \"l.y\"\n[dependencies]\ncy1 = { path = \"../cy1\" }\n");
    mk(g + "/app/main.y", "import a;\nimport b;\nputs(tostring(a.av() * 10 + b.bv()) + \"\\n\");\n");
    let app = g + "/app";
    let head = "[package]\nname = \"app\"\n[bin]\napp = \"main.y\"\n[dependencies]\n";
    foreach (t in [["a missing dependency", "error: cannot read '../nowhere/y.toml'", "x = { path = \"../nowhere\" }"],
                   ["a dependency that is another package", "error: dependency 'x' (../c1) is package 'c'", "x = { path = \"../c1\" }"],
                   ["a dependency without a lib", "error: package 'nolib' (../nolib) has no lib to import", "nolib = { path = \"../nolib\" }"],
                   ["a cycle", "error: dependency cycle: app -> cy1 -> cy2 -> cy1", "cy1 = { path = \"../cy1\" }"],
                   ["one name from two places", "error: package 'c' comes from two places: ../c1 (for a) and ../c2 (for b)",
                    "a = { path = \"../a\" }\nb = { path = \"../b\" }"]]) {
        yt.write(app + "/y.toml", head + t[2] + "\n");
        fails(t[0], t[1], app, []);
    };
    yt.write(app + "/y.toml", head + "a = { path = \"../a\" }\nb = { path = \"../b\" }\nc = { path = \"../c2\" }\n");
    let b = yb(ycc_bin(), app, []);
    if (b.code == 0) {
        runs("the project's own dependency settles a name", "22", app + "/build/app", []);
    } else {
        yt.fail("the project's own dependency settles a name", yt.clip(b.out, 300));
    };
    fs.remove_all(app + "/build");
    yt.write(app + "/build", "");
    fails("a build directory that cannot be made", "error: cannot create directory 'build'", app, []);
    fs.remove_file(app + "/build");
    same_text("vendor: no git dependencies", "nothing to vendor: no git dependencies", in_dir(ycc_bin(), app, ["vendor"]).out);
};

// ── 6b. two packages defining one y_ name ────────────────────────────────
// `y_` is not a namespace: such a def is emitted under its bare name because
// generated code calls it by a fixed label. The linker once kept whichever body
// the compile order put last; both orders are refused now.
def y_names() {
    let p = D + "/p6b";
    foreach (n in ["aa", "bb"]) {
        mk(p + "/" + n + "/y.toml", "[package]\nname = \"" + n + "\"\nlib = \"" + n + ".y\"\n");
        mk(p + "/" + n + "/" + n + ".y", "export { who };\ndef who() -> str { y_who() };\ndef y_who() -> str { \"from " + n + "\" };\n");
    };
    mk(p + "/app/main.y", "import aa;\nimport bb;\nprint(aa.who(), \" \", bb.who());\n");
    foreach (o in [["aa", "bb"], ["bb", "aa"]]) {
        mk(p + "/app/y.toml", "[package]\nname = \"app\"\n\n[dependencies]\n" + o[0] + " = { path = \"../" + o[0] + "\" }\n"
            + o[1] + " = { path = \"../" + o[1] + "\" }\n\n[bin]\napp = \"main.y\"\n");
        let r = yb(ycc_bin(), p + "/app", ["."]);
        // the whole message, verbatim: what a user reads, and what the coverage
        // suite matches the diagnostic against
        let msg = "error: duplicate y_ name 'y_who': '" + o[0] + "' and '" + o[1] + "' both define it -- a y_ name is a fixed label generated code calls by, not a name in a namespace, so only one body could be linked; rename one";
        yt.check("two packages defining one y_ name is an error (" + o[0] + ", " + o[1] + ")",
            !fs.exists(p + "/app/build/app") && yt.has_line(r.out, msg), yt.clip(r.out, 200));
        fs.remove_all(p + "/app/build");
    };
    // a package's own y_ name -- one no std unit defines -- is no collision
    let s = D + "/p6c";
    mk(s + "/solo/y.toml", "[package]\nname = \"solo\"\nlib = \"solo.y\"\n");
    mk(s + "/solo/solo.y", "export { go };\ndef y_solo_marker() -> long { 9 };\ndef go() -> long { y_solo_marker() };\n");
    mk(s + "/soloapp/y.toml", "[package]\nname = \"soloapp\"\n\n[dependencies]\nsolo = { path = \"../solo\" }\n\n[bin]\nsoloapp = \"main.y\"\n");
    mk(s + "/soloapp/main.y", "import solo;\nprint(solo.go());\n");
    let r = yb(ycc_bin(), s + "/soloapp", ["."]);
    let o = yc.run_bin(s + "/soloapp/build/soloapp", [], "", 10).out;
    yt.check("a package's own y_ name is not a collision", o == "9\n", "built: " + yt.clip(r.out, 150) + " / run '" + o + "'");
};

// ── 7. git dependencies ──────────────────────────────────────────────────
// -c user.*, commit.gpgsign and tag.gpgsign so the throwaway repo needs no
// identity and a developer whose global config signs gets neither a pinentry
// prompt nor, with no tty, an empty repo that blames the compiler.
def gitc(repo: str, args: [str]) -> yt.Res {
    yt.exe2(["git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false",
        "-c", "tag.gpgsign=false"] + args)
};

def git() {
    if (!yt.have("git")) {
        yt.skip("git dependencies", "no git");
        return;
    };
    let r = D + "/repo";
    let w = D + "/gp";
    fs.make_dirs(r);
    yt.exe2(["git", "-C", r, "init", "--quiet"]);
    yt.write(r + "/y.toml", "[package]\nname = \"gl\"\nlib = \"gl.y\"\n");
    yt.write(r + "/gl.y", "def v() -> long { 1 };\n");
    gitc(r, ["add", "-A"]);
    gitc(r, ["commit", "--quiet", "-m", "one"]);
    gitc(r, ["tag", "v1"]);
    yt.write(r + "/gl.y", "def v() -> long { 2 };\n");
    gitc(r, ["commit", "--quiet", "-am", "two"]);
    let c2 = chomp(yt.exe(["git", "-C", r, "rev-parse", "HEAD"]).out);
    mk(w + "/y.toml", "[package]\nname = \"gp\"\n[bin]\ngp = \"main.y\"\n[dependencies]\ngl = { git = \"" + r + "\" }\n");
    mk(w + "/main.y", "import gl;\nputs(tostring(gl.v()) + \"\\n\");\n");
    let fetched = "fetching gl (" + r + ")\ncompiling gl\nbuilt build/gp";
    let b = yb(ycc_bin(), w, []);
    if (b.code == 0) {
        same_text("git: fetched, then compiled", fetched, b.out);
        runs("git: the default branch", "2", w + "/build/gp", []);
    } else {
        yt.fail("git: a git dependency builds", yt.clip(b.out, 300));
    };
    let lock = yt.read(w + "/y.lock");
    yt.check("git: y.lock pins the commit", yt.has_line(lock, "commit = \"" + c2 + "\"") && yt.has_line(lock, "rev = \"\""),
        yt.clip(lock, 300));
    yt.write(r + "/gl.y", "def v() -> long { 3 };\n");
    gitc(r, ["commit", "--quiet", "-am", "three"]);
    same_text("git: a pinned dependency is not fetched again", "built build/gp", yb(ycc_bin(), w, []).out);
    runs("git: ... and stays at its commit", "2", w + "/build/gp", []);
    fs.remove_file(w + "/y.lock");
    same_text("git: without y.lock it moves to the branch's head", fetched, yb(ycc_bin(), w, []).out);
    runs("git: ... the new commit", "3", w + "/build/gp", []);
    edit(w + "/y.toml", "gl = { git = \"" + r + "\" }", "gl = { git = \"" + r + "\", rev = \"v1\" }");
    yb(ycc_bin(), w, []);
    runs("git: a rev", "1", w + "/build/gp", []);
    yt.check("git: y.lock records the rev", yt.has_line(yt.read(w + "/y.lock"), "rev = \"v1\""), yt.clip(yt.read(w + "/y.lock"), 300));
    agree("a git dependency", w, []);
    same_text("vendor: copies the git dependencies", "vendored gl (vendor/gl)", in_dir(ycc_bin(), w, ["vendor"]).out);
    yt.check("vendor: the package without its .git", fs.is_file(w + "/vendor/gl/y.toml") && !fs.exists(w + "/vendor/gl/.git"),
        join(yt.ls(w + "/vendor/gl"), " "));
    fs.remove_all(w + "/build");
    same_text("vendor: a vendored dependency is not fetched", "compiling gl\nbuilt build/gp", yb(ycc_bin(), w, []).out);
    runs("vendor: ... and is the one built", "1", w + "/build/gp", []);
    agree("a vendored dependency", w, []);
    fs.remove_all(w + "/vendor");
    yt.write(w + "/vendor", "");
    fails_cmd("vendor", "vendor: a copy that fails", "error: vendoring 'gl' failed", w, []);
    fs.remove_file(w + "/vendor");
    mk(D + "/gq/y.toml", "[package]\nname = \"gp\"\n[bin]\ngp = \"main.y\"\n[dependencies]\ngl = { git = \"" + D + "/nope\" }\n");
    fails("git: a fetch that fails", "error: fetching 'gl' from " + D + "/nope failed", D + "/gq", []);
};

def in_work(body: () -> void) -> () -> void {
    () => {
        D = yt.tmp_dir("pkg");
        body();
        fs.remove_all(D);
    }
};

def cases() -> [yt.Case] {
    let s = "pkg";
    [yt.case_of(s, "diamond", in_work(diamond)), yt.case_of(s, "recursive", in_work(recursive)),
     yt.case_of(s, "optional", in_work(optional_fields)), yt.case_of(s, "inside", in_work(inside)),
     yt.case_of(s, "wide", in_work(wide)), yt.case_of(s, "manifest", in_work(manifests)),
     yt.case_of(s, "graph", in_work(graph)), yt.case_of(s, "y_ names", in_work(y_names)),
     yt.case_of(s, "git", in_work(git))]
};

export { cases };
