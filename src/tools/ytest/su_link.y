// su_link.y -- std units and the std pack (native.y "compilation units", "the
// std pack"; ycc.y self_pack).
//
// A program is linked from units: its own and the std units it needs, each
// compiled separately. The built ycc carries every std unit precompiled (the
// Makefile's PACK appends `ycc --std-pack`), and `--std-src` compiles them from
// src/y/std instead. Checks: the pack is there and well framed; it is exactly
// what --std-pack writes, and what the C copy writes; linking from it gives the
// same bytes as compiling from source, plain and -g; a pack this ycc cannot
// read, or none, falls back to source; a program's own y_ helper or readline
// replaces std's; --no-exec leaves exec out; std's line markers appear only
// under -g; a lone compiler still resolves a library import from its pack,
// while --std-src there says it has no source.
import fs;
import yt;
import yc;
import pack;

let D = "";

def ycc_bin() -> str { yc.abs_path(yt.env("YSELF", yc.YCC)) };

def cc(argv: [str]) -> yt.Res {
    let c = yt.cmd(argv);
    c.merge = true;
    c.timeout = 120 * yt.SCALE;
    yt.run(c)
};

def in_dir(dir: str, argv: [str]) -> yt.Res {
    let c = yt.cmd(argv);
    c.merge = true;
    c.cwd = dir;
    c.timeout = 120 * yt.SCALE;
    yt.run(c)
};

// 1-2. the pack: [pack][8-digit length][YCCPACK1] at the end of ycc, exactly
// what --std-pack writes, and what the C copy writes
def framing() {
    let y = yt.bytes_of(ycc_bin());
    let n = y.length;
    let tr = if (n >= 16) { y[n - 16:] } else { [] };
    let plen = if (n >= 16 && pack.dec(y[n - 16:n - 8]) >= 0) { pack.dec(y[n - 16:n - 8]) } else { 0 };
    let digits = true;
    if (n >= 16) {
        foreach (c in y[n - 16:n - 8]) {
            if (c < 48 || c > 57) { digits = false; };
        };
    };
    let att: [byte] = [];
    if (n >= 16 && from_bytes(y[n - 8:]) == "YCCPACK1" && digits && plen > 0 && plen + 16 < n) {
        yt.pass("ycc carries a std pack (" + tostring(plen) + " bytes)");
        att = y[n - plen - 16:];
        // pack 9: a plain frame whose units are each stored compressed (method
        // byte 1), so a compile decodes only what it links
        let z = pack.units_compressed(att);
        let parts = z.split(" of ");
        yt.check("the attached pack's units are each stored compressed (" + z + ")", z != "" && parts[0] == parts[1],
            "got '" + z + "'");
    } else {
        yt.fail("ycc carries a std pack", "trailer: " + yt.clip(from_bytes(tr), 16));
    };
    let w = cc([ycc_bin(), "--std-pack", D + "/y.pack"]);
    if (w.code == 0) {
        yt.check("--std-pack writes the attached pack", att.length > 0 && yt.bytes_of(D + "/y.pack") == att,
            "sizes: " + tostring(yt.size(D + "/y.pack")) + " vs " + tostring(att.length));
        let c = cc([yc.CYCC, "--std-pack", D + "/c.pack"]);
        yt.check("the C copy writes the same pack", c.code == 0 && yt.same_file(D + "/y.pack", D + "/c.pack"), yt.clip(c.out, 200));
    } else {
        yt.fail("--std-pack writes the attached pack", yt.clip(w.out, 200));
    };
    // The framing stays walkable field by field: pack.stats knows every field's
    // shape and fails unless each unit consumes its fields exactly.
    let ok = [false];
    let st = pack.stats(D + "/y.pack", ok);
    let nfields = 0;
    foreach (l in st.split("\n")) {
        if (l.contains("=")) { nfields += 1; };
    };
    yt.check("the pack decodes and parses field by field, 24 units (" + tostring(nfields) + " field totals)",
        ok[0] && st.contains("version ycc-std-pack 10") && st.contains("24 units, 6 arch sets"), yt.clip(st, 160));
};

// 3. linking from the pack == compiling std from source
def same_both_ways(f: str, flags: [str]) {
    let a = cc([ycc_bin()] + flags + ["-o", D + "/p" + tostring(yt.getpid()), f]);
    let b = cc([ycc_bin(), "--std-src"] + flags + ["-o", D + "/s" + tostring(yt.getpid()), f]);
    yt.check("pack == source: " + fs.path_basename(f) + " " + join(flags, " "),
        a.code == 0 && b.code == 0 && yt.same_file(D + "/p" + tostring(yt.getpid()), D + "/s" + tostring(yt.getpid())),
        yt.clip(a.out + b.out, 200));
};

// 4. a pack ycc cannot read, or none: the std units compile from source
def fallback() {
    let d = yt.bytes_of(ycc_bin());
    let n = d.length;
    let plen = pack.dec(d[n - 16:n - 8]);
    let i = n - 16 - plen;
    let j = i;
    while (j < n && d[j] != 10) { j += 1; };
    let ver = d[i:j + 1];
    let tail = d[n - 8:];
    // stale: the frame says a length that is not there
    fs.write_bytes(D + "/stale", d[0:i] + bytes("99999999") + tail);
    // junk: a pack of this version whose one unit, rt (every program links it),
    // is a stream the decoder must refuse
    let junk = ver + bytes("1:12:rt2:") + [1, 255];
    let jl = tostring(junk.length);
    fs.write_bytes(D + "/junk", d[0:i] + junk + bytes("0".repeat(8 - jl.length) + jl) + tail);
    // bare: no pack at all
    fs.write_bytes(D + "/bare", d[0:i]);
    let want = cc([ycc_bin(), "-o", D + "/all", D + "/all.y"]);
    foreach (alt in ["stale", "junk", "bare"]) {
        fs.set_mode(D + "/" + alt, 0o755);
        let r = cc([D + "/" + alt, "-o", D + "/alt.bin", D + "/all.y"]);
        yt.check("a " + alt + " ycc compiles std from source, same bytes",
            r.code == 0 && want.code == 0 && yt.same_file(D + "/alt.bin", D + "/all"), yt.clip(r.out + want.out, 200));
    };
};

def runs_as(name: str, src: str, want: str) {
    let f = yt.tmp("p") + ".y";
    yt.write(f, src);
    let b = yt.tmp("bin");
    let r = cc([ycc_bin(), "-o", b, f]);
    let o = if (r.code == 0) { yc.run_bin(b, [], "", 10).out } else { "" };
    yt.check(name, r.code == 0 && o == want, yt.clip(r.out, 200) + " got '" + o + "'");
};

// 7. std's line markers: none in plain -S, renumbered into the program's .file
// table under -g (the program's files first, then the std units)
def markers() {
    let s = cc([ycc_bin(), "-S", D + "/all.y"]);
    let g = cc([ycc_bin(), "-g", "-S", D + "/all.y"]);
    let plain = false;
    foreach (l in s.out.split("\n")) {
        if (l.starts_with(".file ") || l.starts_with(".loc ")) { plain = true; };
    };
    let files: [str] = [];
    let l2 = false;
    let l5 = false;
    let hi = false;
    foreach (l in g.out.split("\n")) {
        if (l.starts_with(".file ")) { files += l; };
        if (l.starts_with(".loc 2 ")) { l2 = true; };
        if (l.starts_with(".loc 5 ")) { l5 = true; };
        if (l.starts_with(".loc ")) {
            let n = yt.num(yt.words(l)[1], 0);
            if (n >= 6) { hi = true; };
        };
    };
    let want = ".file 1 \"" + D + "/all.y\"|.file 2 \"std/rt.y\"|.file 3 \"std/str.y\"|.file 4 \"std/exec.y\"|.file 5 \"std/prelude.y\"";
    yt.check("std line markers: none plain, file 2..5 under -g",
        s.code == 0 && g.code == 0 && !plain && join(files, "|") == want && l2 && l5 && !hi, join(files, "|"));
};

// 8. A std module's tables are built on first use, so importing it costs only
// what the program uses: crypto's SHA-2 constants and AES S-box were top-level
// `let`s, inlined at _start (a shake root) into every importer. The ratchet is
// the gap between a program that never hashes and one that does.
def crypto_tables() {
    yt.write(D + "/cryi.y", "import crypto;\nprint(\"hi\");\n");
    yt.write(D + "/cry0.y", "import crypto;\nlet b = crypto.random_bytes(16);\nprint(len(b));\n");
    yt.write(D + "/hi.y", "print(\"hi\");\n");
    yt.write(D + "/cry1.y", "import crypto;\ndef u(s: str) -> [byte] { crypto.unhex(s) };\nprint(crypto.hex(crypto.sha256(bytes(\"abc\"))));\n");
    let err = "";
    foreach (n in ["cryi", "cry0", "hi", "cry1"]) {
        let r = cc([ycc_bin(), D + "/" + n + ".y", "-o", D + "/" + n]);
        if (r.code != 0) { err += r.out; };
    };
    if (err != "") {
        yt.fail("crypto's tables are built on first use", yt.clip(err, 200));
        return;
    };
    let si = yt.size(D + "/cryi");
    let s0 = yt.size(D + "/cry0");
    let shi = yt.size(D + "/hi");
    let s1 = yt.size(D + "/cry1");
    let r0 = yc.run_bin(D + "/cry0", [], "", 10).out;
    let r1 = yc.run_bin(D + "/cry1", [], "", 10).out;
    yt.check("crypto's tables are built on first use (import only " + tostring(si) + " B, CSPRNG " + tostring(s0)
        + " B, hashing " + tostring(s1) + " B)",
        r0 == "16\n" && r1 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\n"
        && si < shi + 3000 && s1 > si + 3000 && s1 > s0 + 3000,
        "sizes " + tostring(si) + "/" + tostring(shi) + "/" + tostring(s0) + "/" + tostring(s1) + ", runs '" + r0 + "' '" + r1 + "'");
};

// 9. --std-pack's own errors
def pack_errors() {
    let e1 = cc([ycc_bin(), "--std-pack"]);
    let e2 = cc([ycc_bin(), "--std-pack", D + "/no/such/dir/p"]);
    yt.check("--std-pack: missing argument, unwritable path",
        e1.code == 1 && e1.out.contains("--std-pack needs an argument")
        && e2.code == 1 && e2.out.contains("writing '" + D + "/no/such/dir/p' failed"),
        tostring(e1.code) + ": " + yt.clip(e1.out, 100) + " / " + tostring(e2.code) + ": " + yt.clip(e2.out, 100));
};

// A ycc with no std/ beside it still compiles std imports and meta blocks from
// its pack; --std-src there has nothing to compile from and says so.
def lone() {
    let bin = D + "/lone/bin";
    let run = D + "/lone/run";
    fs.make_dirs(bin);
    fs.make_dirs(run);
    fs.copy_file(ycc_bin(), bin + "/ycc");
    fs.set_mode(bin + "/ycc", 0o755);
    yt.write(run + "/m.y", "import math;\nprint(math.pi);\n");
    let a = in_dir(run, [bin + "/ycc", "m.y", "-o", "m"]);
    let o = if (a.code == 0) { in_dir(run, ["./m"]).out } else { a.out };
    yt.check("lone ycc: a std import resolves with no std/ on disk", o == "3.141593\n", yt.clip(o, 120));
    // a meta block's generator links the std from the compiler's own pack
    yt.write(run + "/mb.y", "let n = 6 * 7;\n#{ \"print(\\\"\" + tostring(n) + \" from a block\\\");\\n\" }#\n");
    let b = in_dir(run, [bin + "/ycc", "mb.y", "-o", "mb"]);
    let ob = if (b.code == 0) { in_dir(run, ["./mb"]).out } else { b.out };
    yt.check("lone ycc: a meta block's generator links the std from the pack", ob == "42 from a block\n", yt.clip(ob, 160));
    // the line, its unit the first one the program needs:
    // error: std module 'str': not in this compiler's std pack, and no src/y/std/str.y beside it or in the working directory
    let e = in_dir(run, [bin + "/ycc", "--std-src", "m.y", "-o", "m2"]);
    let l = yt.first_line(e.out);
    let pre = "error: std module '";
    let ok = e.code == 1 && l.starts_with(pre) && l.contains("': not in this compiler's std pack, and no src/y/std/")
        && l.ends_with(".y beside it or in the working directory");
    yt.check("lone ycc --std-src: a std unit with no source on disk is a diagnostic", ok,
        "exit " + tostring(e.code) + ": " + yt.clip(e.out, 160));
};

// A compiler with no pack (cycc) builds the arch runtime from src/y/arch, so one
// that finds the std sources but no arch files must name the file it lacks.
def no_arch() {
    let d = D + "/noarch";
    fs.make_dirs(d + "/src/y");
    fs.make_dirs(d + "/bin");
    yt.sh("cp -R " + yt.q(yc.ROOT + "/src/y/std") + " " + yt.q(d + "/src/y/std"));
    fs.copy_file(yc.CYCC, d + "/bin/cycc");
    fs.set_mode(d + "/bin/cycc", 0o755);
    yt.write(d + "/p.y", "print(1);\n");
    let r = in_dir(d, [d + "/bin/cycc", "-o", "p", "p.y"]);
    yt.check("a pack-less compiler with no src/y/arch names the missing runtime file",
        r.code == 1 && r.out.contains("error: the arch runtime 'prelude.s': not in this compiler's std pack, and no src/y/arch/prelude.s beside it or in the working directory"),
        "exit " + tostring(r.code) + ": " + yt.clip(r.out, 160));
};

def body() {
    D = yt.tmp_dir("link");
    // a program linking every std unit: readline (prelude), exec, a
    // helper-backed string method (str), and the runtime
    yt.write(D + "/all.y", "let line = readline();\nlet r = exec(\"echo hi\");\nlet s = \"a,b,c\";\nputs(s.upper() + \"\\n\");\n"
        + "print(len(s.split(\",\")));\nif (line == none) { puts(\"eof\\n\"); } else { puts(\"line\\n\"); };\n");
    framing();
    // programs that use a library module link it as a pack unit: math (no
    // imports), sort (math's importer), crypto (whose Hash type tls names)
    foreach (f in ["test/y/examples/helloworld.y", "test/y/native/t35_readline.y", "test/y/native/t38_exec.y",
                   "test/y/native/t300_math_int.y", "test/y/native/t217_sort.y", "test/y/native/t158_crypto.y",
                   "test/y/examples/ysh.y", D + "/all.y"]) {
        same_both_ways(yc.abs_path(f), []);
        same_both_ways(yc.abs_path(f), ["-g"]);
    };
    let a = cc([ycc_bin(), "-o", D + "/all", D + "/all.y"]);
    let o = yc.run_bin(D + "/all", [], "", 10);
    yt.check("a program linking all four std units runs", a.code == 0 && o.out == "hi\nA,B,C\n3\neof\n", yt.clip(a.out + o.out, 200));
    fallback();
    // 5. a program's own y_ helper replaces the runtime's -- for every caller
    runs_as("a program's y_print_long replaces the runtime's",
        "def y_print_long(n: long) -> long { puts(\"<\" + tostring(n) + \">\\n\"); 0 };\nprint(42);\n", "<42>\n");
    runs_as("a program's readline replaces the prelude's",
        "def readline() -> str? { some(\"mine\") };\nputs(unwrap(readline()) + \"\\n\");\n", "mine\n");
    // 6. --no-exec: exec is not linked, so a call to it does not compile
    yt.write(D + "/ex.y", "let r = exec(\"echo hi\");\n");
    let ex = cc([ycc_bin(), "--no-exec", "-o", D + "/ex", D + "/ex.y"]);
    yt.check("--no-exec leaves exec out", ex.code == 1 && ex.out.contains("undefined function 'exec'"),
        "exit " + tostring(ex.code) + ": " + yt.clip(ex.out, 200));
    markers();
    crypto_tables();
    pack_errors();
    lone();
    no_arch();
    fs.remove_all(D);
};

def cases() -> [yt.Case] { [yt.case_of("link", "link", body)] };

export { cases };
