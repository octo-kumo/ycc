// su_debug.y -- `ycc -g`: symbols, section headers and DWARF line info.
//
// -g must not change what runs: the code, rodata and every address match the
// plain build; it only appends .symtab/.strtab/.shstrtab, the line table and
// section headers past the loaded image, and backs the head of the .bss with
// file zeros (valgrind needs a file-backed read+write mapping). Both compilers
// agree byte for byte, and the standard tools (readelf, nm, addr2line, as; gdb
// and valgrind when installed) see the functions and map code to file:line,
// an imported module's included.
import fs;
import yt;
import yc;

let D = "";

def build(cc: str, flags: [str], out: str, src: str) -> yt.Res {
    yc.compile(cc, flags, D + "/" + src, D + "/" + out, 120)
};

def tool(argv: [str]) -> yt.Res {
    let c = yt.cmd(argv);
    c.timeout = 120;
    yt.run(c)
};

// The .bss section lies inside the R+W PT_LOAD segment: the .bss begins
// code_off bytes into that segment's page (elf.y elf_build), and a segment of
// only bss_len bytes once left its tail unmapped; -g's .bss header once added
// the load base twice. "" when it holds, else what is wrong.
def bss_check(path: str) -> str {
    let b = yt.bytes_of(path);
    let phoff = yt.le(b, 32, 8);
    let shoff = yt.le(b, 40, 8);
    let phsz = yt.le(b, 54, 2);
    let phn = yt.le(b, 56, 2);
    let shsz = yt.le(b, 58, 2);
    let shn = yt.le(b, 60, 2);
    let stri = yt.le(b, 62, 2);
    let rw0 = -1;
    let rw1 = -1;
    for i in 0..phn {
        let o = phoff + i * phsz;
        if (yt.le(b, o, 4) == 1 && (yt.le(b, o + 4, 4) & 2) != 0) {
            rw0 = yt.le(b, o + 16, 8);
            rw1 = rw0 + yt.le(b, o + 40, 8);
        };
    };
    let stroff = yt.le(b, shoff + stri * shsz + 24, 8);
    let s0 = -1;
    let s1 = -1;
    for i in 0..shn {
        let o = shoff + i * shsz;
        let n = stroff + yt.le(b, o, 4);
        if (n + 5 <= b.length && from_bytes(b[n:n + 5]) == ".bss" + chr(0)) {
            s0 = yt.le(b, o + 16, 8);
            s1 = s0 + yt.le(b, o + 32, 8);
        };
    };
    if (rw0 < 0 || s0 < 0) { return "no R+W segment or no .bss section"; };
    let rng = "segment " + yt.hex(rw0) + "-" + yt.hex(rw1) + ", .bss " + yt.hex(s0) + "-" + yt.hex(s1);
    if (rw0 <= s0 && s1 <= rw1) { "" } else { rng }
};

// gdb's frame line `#N [0x... in ]fn () [at file:line]`: the function, or "".
def frame(out: str, n: long) -> str {
    let pre = "#" + tostring(n) + " ";
    foreach (l in out.split("\n")) {
        if (l.starts_with(pre)) {
            let t = l[pre.length:].trim();
            let i = t.index_of(" in ");
            if (t.starts_with("0x") && i >= 0) { t = t[i + 4:]; };
            return t;
        };
    };
    ""
};

def gdb_at(bin: str, where: str) -> str {
    tool(["gdb", "-batch", "-nx", "-ex", "set debuginfod enabled off", "-ex", "break " + where, "-ex", "run", "-ex", "bt", bin]).out
};

def gdb_frames(out: str) -> str {
    let r: [str] = [];
    foreach (l in out.split("\n")) {
        if (l.starts_with("#") || l.starts_with("Breakpoint")) { r += l; };
    };
    yt.clip(join(r[0:if (r.length > 4) { 4 } else { r.length }], "\n"), 400)
};

def readelf_checks() {
    let dbg = D + "/dbg";
    let re = tool(["readelf", "-a", "-W", "--debug-dump=info,abbrev,line", dbg]);
    yt.check("readelf accepts the -g binary", re.code == 0 && re.err == "", yt.clip(re.err, 300));
    let secs: [str] = [];
    let dsecs: [str] = [];
    foreach (w in yt.words(tool(["readelf", "-S", "-W", dbg]).out)) {
        foreach (n in [".text", ".rodata", ".bss", ".symtab", ".strtab", ".shstrtab"]) {
            if (w == n) { secs += w; };
        };
        if (w.starts_with(".debug_")) { dsecs += w; };
    };
    yt.check("sections .text .rodata .bss .symtab .strtab .shstrtab",
        join(secs, " ") == ".text .rodata .bss .symtab .strtab .shstrtab", "got: " + join(secs, " "));
    let bad = bss_check(dbg);
    yt.check("the .bss lies inside the R+W segment", bad == "", bad);
    yt.check("sections .debug_info .debug_abbrev .debug_line", join(dsecs, " ") == ".debug_info .debug_abbrev .debug_line",
        "got: " + join(dsecs, " "));
    // a row per statement and per function entry (line 0: _start's entry)
    let seen: [bool] = [];
    for i in 0..64 { seen += false; };
    foreach (l in tool(["readelf", "--debug-dump=decodedline", dbg]).out.split("\n")) {
        let w = yt.words(l);
        if (w.length > 1 && w[0] == "p.y") {
            let n = yt.num(w[1], -1);
            if (n >= 0 && n < 64) { seen[n] = true; };
        };
    };
    let rows: [str] = [];
    for i in 0..64 {
        if (seen[i]) { rows += tostring(i); };
    };
    yt.check("line table rows for p.y lines 1 3 4 5 8 9 12 13 14", join(rows, " ") == "0 1 3 4 5 8 9 12 13 14",
        "got: " + join(rows, " "));
    // Num: Value Size Type Bind Vis Ndx Name
    let syms = tool(["readelf", "-s", "-W", dbg]).out;
    foreach (spec in [["leaf", "FUNC LOCAL sized"], ["mid", "FUNC LOCAL sized"], ["_start", "FUNC GLOBAL sized"],
                      ["calls", "OBJECT LOCAL sized"]]) {
        let got = "<absent>";
        foreach (l in syms.split("\n")) {
            let w = yt.words(l);
            if (w.length >= 8 && w[7] == spec[0] && got == "<absent>") {
                got = w[3] + " " + w[4] + " " + (if (yt.num(w[2], 0) > 0) { "sized" } else { "empty" });
            };
        };
        yt.check("symbol " + spec[0] + ": " + spec[1], got == spec[1], "got '" + got + "'");
    };
    let leak = false;
    foreach (l in syms.split("\n")) {
        let w = yt.words(l);
        if (w.length >= 8 && (w[7].contains("yfn_") || w[7].contains("yg_") || w[7].contains("$"))) { leak = true; };
    };
    yt.check("symbol names are the source names", !leak, "raw labels leaked into .symtab");
};

// nm's address of `name` in bin ("" when absent).
def nm_addr(bin: str, name: str) -> str {
    foreach (l in tool(["nm", bin]).out.split("\n")) {
        let w = yt.words(l);
        if (w.length == 3 && w[2] == name) { return w[0]; };
    };
    ""
};

def addr2line_checks() {
    let dbg = D + "/dbg";
    let addr = nm_addr(dbg, "leaf");
    let got = yt.first_line(tool(["addr2line", "-f", "-e", dbg, "0x" + addr]).out);
    yt.check("nm/addr2line resolve leaf", addr != "" && got == "leaf", "addr '" + addr + "' -> '" + got + "'");
    got = yt.first_line(tool(["addr2line", "-e", dbg, "0x" + addr]).out);
    yt.check("addr2line puts leaf at p.y:3", addr != "" && got == D + "/p.y:3", "addr '" + addr + "' -> '" + got + "'");
    let ta = nm_addr(D + "/m", "twice");
    got = yt.first_line(tool(["addr2line", "-e", D + "/m", "0x" + ta]).out);
    yt.check("addr2line puts the imported twice at lib.y:1", ta != "" && got == D + "/lib.y:1",
        "addr '" + ta + "' -> '" + got + "'");
};

def gdb_checks() {
    let o = gdb_at(D + "/dbg", "leaf");
    // frame #0 shows no address when it stopped on the start of a line
    yt.check("gdb breaks in leaf, called from mid", frame(o, 0).starts_with("leaf ()") && frame(o, 1).starts_with("mid ()"),
        gdb_frames(o));
    o = gdb_at(D + "/dbg", "p.y:5");
    yt.check("gdb breaks at p.y:5, called from p.y:9",
        frame(o, 0).starts_with("leaf () at ") && frame(o, 0).ends_with("p.y:5")
        && frame(o, 1).starts_with("mid () at ") && frame(o, 1).ends_with("p.y:9"), gdb_frames(o));
    o = gdb_at(D + "/m", "lib.y:2");
    yt.check("gdb breaks at lib.y:2, called from m.y:2",
        frame(o, 0).starts_with("twice () at ") && frame(o, 0).ends_with("lib.y:2")
        && frame(o, 1).starts_with("_start () at ") && frame(o, 1).ends_with("m.y:2"), gdb_frames(o));
};

def callgrind() {
    let c = yt.cmd(["valgrind", "--tool=callgrind", "--callgrind-out-file=" + D + "/cg.out", D + "/dbg"]);
    c.timeout = 120;
    let v = yt.run(c);
    let a = tool(["callgrind_annotate", D + "/cg.out"]).out;
    yt.check("callgrind names leaf and mid", v.out == "22\n26\n4\n" && a.contains(":leaf ") && a.contains(":mid "),
        yt.clip(a, 300));
};

def body() {
    D = yt.tmp_dir("debug");
    yt.write(D + "/p.y", "let calls = 0;\n\ndef leaf(n: long) -> long {\n    calls = calls + 1;\n    n * 2\n};\n\n"
        + "def mid(n: long) -> long {\n    leaf(n) + leaf(n + 1)\n};\n\nprint(mid(5));\nprint(mid(6));\nprint(calls);\n");
    // m.y calls into an imported module: the line table names both files
    yt.write(D + "/lib.y", "def twice(n: long) -> long {\n    let r = n * 2;\n    r\n};\nexport { twice };\n");
    yt.write(D + "/m.y", "import lib from \"./lib.y\";\nprint(lib.twice(21));\n");
    let p = build(yc.YCC, [], "plain", "p.y");
    if (p.code != 0) {
        yt.fail("compile", "ycc: " + yt.clip(p.out, 300));
        return;
    };
    let g = build(yc.YCC, ["-g"], "dbg", "p.y");
    if (g.code != 0) {
        yt.fail("compile -g", "ycc -g: " + yt.clip(g.out, 300));
        return;
    };
    // 1. the two compilers agree on -g output, byte for byte
    let gc = build(yc.CYCC, ["-g"], "dbg_c", "p.y");
    yt.check("cycc -g and ycc -g emit identical binaries", gc.code == 0 && yt.same_file(D + "/dbg", D + "/dbg_c"), yt.clip(gc.out, 300));
    let m1 = build(yc.YCC, ["-g"], "m", "m.y");
    let m2 = build(yc.CYCC, ["-g"], "m_c", "m.y");
    yt.check("-g with an import: both compilers agree, it runs",
        m1.code == 0 && m2.code == 0 && yt.same_file(D + "/m", D + "/m_c") && yc.run_bin(D + "/m", [], "", 10).out == "42\n",
        yt.clip(m1.out + m2.out, 300));
    // 2. -g changes nothing that runs
    let r = yc.run_bin(D + "/dbg", [], "", 10);
    yt.check("-g build runs the same", r.code == 0 && r.out == "22\n26\n4\n", "exit " + tostring(r.code) + ": " + yt.clip(r.out, 200));
    // e_phnum (2 bytes at 56) gives the header size: code starts at 64 + 56 * phnum
    let a = yt.bytes_of(D + "/plain");
    let b = yt.bytes_of(D + "/dbg");
    let off = 64 + 56 * yt.le(a, 56, 2);
    yt.check("code and rodata identical to the plain build",
        b.length >= a.length && a[0:40] == b[0:40] && a[off:] == b[off:a.length], "the loaded bytes differ");
    yt.check("plain build has no section headers", yt.le(a, 60, 2) == 0, "e_shnum=" + tostring(yt.le(a, 60, 2)));
    // 3. the symbol table and the line table, as the binutils see them
    if (yt.have("readelf")) { readelf_checks(); } else { yt.skip("readelf checks", "readelf not installed"); };
    if (yt.have("nm") && yt.have("addr2line")) { addr2line_checks(); } else { yt.skip("nm/addr2line", "binutils not installed"); };
    // 4. debuggers and profilers name the functions and lines
    if (yt.have("gdb")) { gdb_checks(); } else { yt.skip("gdb", "gdb not installed"); };
    if (yt.have("valgrind") && yt.have("callgrind_annotate")) { callgrind(); } else { yt.skip("callgrind", "valgrind not installed"); };
    // 5. a program with no .bss still gets a valid symbol table and line table
    yt.write(D + "/q.y", "exit(3);\n");
    if (build(yc.YCC, ["-g"], "q", "q.y").code == 0) {
        let q = yc.run_bin(D + "/q", [], "", 10);
        let re = if (yt.have("readelf")) { tool(["readelf", "-a", "-W", "--debug-dump=info,abbrev,line", D + "/q"]) }
            else { { code: 0, out: "", err: "", timed_out: false, ms: 0, us: 0 } };
        yt.check("-g on a minimal program", q.code == 3 && re.code == 0 && re.err == "",
            "exit " + tostring(q.code) + " " + yt.clip(re.err, 200));
    } else {
        yt.fail("-g on a minimal program", "ycc -g failed");
    };
    // 6. --emit=asm -g: the line markers are GNU as's own .file/.loc directives
    let sg = tool([yc.YCC, "-g", "--emit=asm", D + "/p.y"]);
    let s0 = tool([yc.YCC, "--emit=asm", D + "/p.y"]);
    let plain_marks = false;
    foreach (l in s0.out.split("\n")) {
        if (l.starts_with(".file ") || l.starts_with(".loc ")) { plain_marks = true; };
    };
    yt.check("--emit=asm -g carries .file/.loc, plain --emit=asm none",
        sg.code == 0 && yt.has_line(sg.out, ".file 1 \"" + D + "/p.y\"") && yt.has_line(sg.out, ".loc 1 4")
        && s0.code == 0 && !plain_marks, yt.clip(sg.err + s0.err, 300));
    if (yt.have("as") && yt.have("readelf")) {
        yt.write(D + "/p.s", sg.out);
        let as_ = tool(["as", "-o", D + "/p.o", D + "/p.s"]);
        let ok = false;
        foreach (l in tool(["readelf", "--debug-dump=decodedline", D + "/p.o"]).out.split("\n")) {
            let w = yt.words(l);
            if (w.length > 1 && w[0] == "p.y" && w[1] == "4") { ok = true; };
        };
        yt.check("GNU as reads the --emit=asm -g line markers", as_.code == 0 && ok, "as or its line table failed");
    } else {
        yt.skip("GNU as on --emit=asm -g", "binutils not installed");
    };
    // An integer literal is emitted as its value, so an --emit=asm listing says what the
    // program runs: one wider than 64 bits (which runs as its low 64 bits) was
    // once written out as itself, which GNU as cannot read. Hex and binary keep
    // their value, including one that wraps (0xFFFFFFFFFFFFFFFF runs as -1).
    if (yt.have("as")) {
        yt.write(D + "/lit.y", "print(0xff, 0b1010, 255, -7, 4294967296, 0xFFFFFFFFFFFFFFFF, 18446744073709551616, 99999999999999999999999);\n");
        let ls = tool([yc.YCC, "--emit=asm", D + "/lit.y"]);
        let wide = false;
        foreach (l in ls.out.split("\n")) {
            let i = l.index_of("mov $");
            if (i >= 0) {
                let n = 0;
                let k = i + 5;
                while (k < l.length && l[k] >= 48 && l[k] <= 57) { n += 1; k += 1; };
                if (n >= 19) { wide = true; };
            };
        };
        yt.write(D + "/lit.s", ls.out);
        let as_ = tool(["as", "-o", D + "/lit.o", D + "/lit.s"]);
        let lb = build(yc.YCC, [], "lit.bin", "lit.y");
        // 255 10 255 -7 4294967296 -1 0 200376420520689663, with no separator
        let run = if (lb.code == 0) { yc.run_bin(D + "/lit.bin", [], "", 10).out } else { "" };
        yt.check("-S emits a literal as its value, and GNU as assembles it",
            ls.code == 0 && !wide && as_.code == 0 && run == "25510255-74294967296-10200376420520689663\n",
            "run '" + run + "' " + yt.clip(ls.err + as_.err, 300));
    } else {
        yt.skip("-S emits a literal as its value", "binutils not installed");
    };
    fs.remove_all(D);
};

def cases() -> [yt.Case] { [yt.case_of("debug", "debug", body)] };

export { cases, bss_check };
