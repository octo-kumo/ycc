// pe.y -- the Windows gates for `ycc --target=windows`, run by hand (they need
// wine, and a ycc whose w_sysno matches that wine's ntdll):
//
//   ytest pe-gate [YCC]             a PE that loads AND RUNS: well-formed
//                                   headers (objdump), the run under wine, the
//                                   file round trip and path programs of test/pe
//                                   against their Linux output, the import table
//                                   and its IAT, a -g PE's debug bytes, and the
//                                   C copy's -g PE byte for byte (default ./ynew)
//   ytest pe-packinv [YCC] [F...]   the std pack carries no target: a PE linked
//                                   from the pack equals one from --std-src
//   ytest pe-fixtures YCC [NAME...] every native fixture as a PE under wine
//                                   against its ELF run (the reference)
//   ytest cycc-win [F...]           cycc.exe under wine compiles exactly what
//                                   the Linux cycc compiles (make cycc.exe)
//   ytest w-sysno [NAME...]         the NT syscall number of each Nt* export of
//                                   the installed wine's ntdll.dll, read out of
//                                   its stub (`mov $imm,%eax; syscall`)
import fs;
import yt;
import yc;

def wine(argv: [str], cwd: str, stdin: str, secs: long) -> yt.Res {
    let c = yt.cmd(["wine"] + argv);
    c.cwd = cwd;
    c.stdin = stdin;
    c.timeout = secs;
    c.env = ["WINEARCH=win64", "WINEDEBUG=-all"];
    yt.run(c)
};

def say(s: str) { print("pe-gate: " + s); };

def bad(s: str) -> long {
    print("pe-gate: FAIL (" + s + ")");
    1
};

def objdump(args: [str]) -> str { yt.exe(["objdump"] + args).out };

def pe_compile(ycc: str, flags: [str], src: str, out: str) -> yt.Res {
    let c = yt.cmd([ycc, "--target=windows"] + flags + [src, "-o", out]);
    c.cwd = yc.ROOT;
    c.merge = true;
    c.timeout = 300;
    yt.run(c)
};

def gate(av: [str]) -> long {
    let ycc = yc.abs_path(if (av.length > 0) { av[0] } else { "ynew" });
    let out = yt.tmp_dir("pe-gate");
    let src = yt.env("PE_GATE_SRC", yc.ROOT + "/test/y/examples/helloworld.y");
    say(ycc + " --target=windows " + src);
    if (pe_compile(ycc, [], src, out + "/g.exe").code != 0) { return bad("the compiler refused"); };
    say(tostring(yt.size(out + "/g.exe")) + " bytes");
    // 1. the headers: necessary, not sufficient -- the run below is the gate
    if (!objdump(["-x", out + "/g.exe"]).contains("pei-x86-64")) { return bad("not a pei-x86-64 image"); };
    let h = objdump(["-h", out + "/g.exe"]);
    foreach (sec in [".text", ".pdata", ".xdata"]) {
        if (!h.contains(" " + sec + " ")) { return bad("no " + sec + " section"); };
        say("section " + sec + " present");
    };
    if (!objdump(["-x", out + "/g.exe"]).contains("Exception Directory")) { return bad("no exception data directory"); };
    say("exception directory (.pdata) present");
    // 2. run it
    let r = wine(["./g.exe"], out, "", 60);
    say("wine exit status " + tostring(r.code));
    foreach (l in yt.lines(r.out)) { print("    | " + l); };
    if (r.code != 0) {
        foreach (l in yt.lines(r.err)) {
            if (l != "") { print("    ! " + l); };
        };
        // the W3 startup self-test (arch/wselftest.s) runs before the program's
        // first instruction; a drifted w_sysno ends the run with this whole line:
        // runtime error: NT syscall self-test failed (a w_sysno number does not match this Windows build)
        if (r.err.contains("runtime error: NT syscall self-test failed (a w_sysno number does not match this Windows build)")) {
            return bad("the Windows syscall self-test failed; a w_sysno number does not match this build");
        };
        return bad("the program did not run to completion");
    };
    say("ok");
    // 3. the file round trip, and the file path, against the Linux output
    foreach (p in [["fsrt", "file round trip ok (create/write/read/append/size/mkdir/unlink/seek/rename/cwd/chdir/list, PE == Linux)"],
                   ["fs", "file path ok (PE == the Linux output)"]]) {
        if (pe_compile(ycc, [], yc.ROOT + "/test/pe/" + p[0] + ".y", out + "/" + p[0] + ".exe").code != 0) {
            return bad("the compiler refused test/pe/" + p[0] + ".y");
        };
        // a fresh directory: the path program lists "."
        let d = yt.tmp_dir("pe-" + p[0]);
        let o = wine([out + "/" + p[0] + ".exe"], d, "", 60);
        if (o.code != 0) { return bad("test/pe/" + p[0] + ".y exited " + tostring(o.code)); };
        if (o.out != yt.read(yc.ROOT + "/test/pe/" + p[0] + ".expected")) {
            print("    " + yt.first_diff(yt.read(yc.ROOT + "/test/pe/" + p[0] + ".expected"), o.out));
            return bad("the PE's " + p[0] + " output differs from the Linux output");
        };
        say(p[1]);
    };
    // the import table: the DLL and the function by name, and a second DLL so
    // the descriptor chain is proven
    say("checking the import table and -g sections");
    let fssrc = yc.ROOT + "/test/pe/fs.y";
    if (pe_compile(ycc, [], fssrc, out + "/imp.exe").code != 0) { return bad("the compiler refused the import program"); };
    let p = objdump(["-p", out + "/imp.exe"]);
    foreach (w in ["DLL Name: KERNEL32.dll", "GetCurrentProcessId", "DLL Name: advapi32.dll", "SystemFunction036"]) {
        if (!p.contains(w)) { return bad("the PE does not import " + w); };
    };
    say("import table ok (KERNEL32.dll!GetCurrentProcessId, advapi32.dll!SystemFunction036)");
    // the IAT is the .bss block the CODE calls through (the loader fills it),
    // not the copy inside .idata: FirstThunk is exactly .bss's RVA
    let fts = "";
    let pl = yt.lines(p);
    for i in 0..pl.length {
        if (fts == "" && pl[i].contains("Thunk") && i + 1 < pl.length) {
            let w = yt.words(pl[i + 1]);
            if (w.length > 0) { fts = w[w.length - 1]; };
        };
    };
    let bssva = "";
    foreach (l in yt.lines(objdump(["-h", out + "/imp.exe"]))) {
        let w = yt.words(l);
        if (w.length > 3 && w[1] == ".bss" && bssva == "") { bssva = w[3]; };
    };
    if (fts == "" || bssva == "") { return bad("no FirstThunk or no .bss to compare"); };
    let bss = hexval(bssva) - 5368709120;
    if (hexval(fts) != bss) { return bad("FirstThunk " + fts + " is not .bss " + yt.hex(bss) + " -- the IAT is not the cell block"); };
    say("IAT at .bss " + yt.hex(bss) + " ok");
    // a -g PE carries its debug sections WITH their bytes
    if (pe_compile(ycc, ["-g"], fssrc, out + "/gimp.exe").code != 0) { return bad("the compiler refused the -g program"); };
    if (!objdump(["-h", out + "/gimp.exe"]).contains(".debug_l")) { return bad("a -g PE has no .debug_l section"); };
    if (!objdump(["-s", "-j", ".debug_l", out + "/gimp.exe"]).contains("Contents of section")) {
        return bad("a -g PE's .debug_l has no bytes in the file");
    };
    say("-g sections ok (.debug_l has its bytes)");
    // and the C copy builds THE SAME -g PE (a -g line marker once trapped every
    // cycc PE build, and only a PE walker could see it)
    if (fs.is_file(yc.CYCC)) {
        if (pe_compile(yc.CYCC, ["-g"], fssrc, out + "/cgimp.exe").code != 0) { return bad("the C copy refused the -g program"); };
        if (!yt.same_file(out + "/gimp.exe", out + "/cgimp.exe")) { return bad("the C copy's -g PE differs from the Y compiler's"); };
        say("the C copy's -g PE is byte-identical");
    };
    0
};

def hexval(s: str) -> long {
    let v = 0;
    foreach (c in bytes(s.lower())) {
        let d = if (c >= 48 && c <= 57) { c - 48 } else if (c >= 97 && c <= 102) { c - 87 } else { -1 };
        if (d >= 0) { v = v * 16 + d; };
    };
    v
};

// The std pack must carry no target: anything a std unit resolves while it is
// compiled (a syscall number, a layout, a branch on the target) is baked into
// the pack and served to every program, whatever its --target. So a PE linked
// from the attached pack must equal one from --std-src.
def packinv(av: [str]) -> long {
    let ycc = yc.abs_path(if (av.length > 0) { av[0] } else { "ynew" });
    let files = if (av.length > 1) { av[1:] } else { yt.files(yc.ROOT + "/test/y/native", "t", ".y") + yt.files(yc.ROOT + "/test/y/examples", "", ".y") };
    let ok = 0;
    let differ = 0;
    let skipped = 0;
    foreach (f in files) {
        let a = yt.tmp("pa") + ".exe";
        let b = yt.tmp("pb") + ".exe";
        if (pe_compile(ycc, [], f, a).code != 0 || pe_compile(ycc, ["--std-src"], f, b).code != 0) {
            skipped += 1;
        } else if (yt.same_file(a, b)) {
            ok += 1;
        } else {
            differ += 1;
            print("PACK!=SRC  " + f);
        };
        fs.remove_file(a);
        fs.remove_file(b);
    };
    print("=== pe-packinv: " + tostring(ok) + " identical, " + tostring(differ) + " differ, " + tostring(skipped) + " skipped (of "
        + tostring(files.length) + ")");
    if (differ == 0) { 0 } else { 1 }
};

// Every native t*.y fixture compiled and run both ways. ELF is the reference:
// the fixture's own .expected/.exit is the truth, and a fixture whose ELF run
// fails is a baseline failure, not a Windows one. stderr is not compared (wine
// writes noise there on a good run). Every run has a timeout: one hung fixture
// once wedged the whole run for 40 minutes with an empty table.
def fixtures(av: [str]) -> long {
    if (av.length == 0) {
        eputs("usage: ytest pe-fixtures YCC [fixture...]");
        return 2;
    };
    let ycc = yc.abs_path(av[0]);
    let nat = yc.ROOT + "/test/y/native";
    let files: [str] = [];
    if (av.length > 1) {
        foreach (n in av[1:]) {
            foreach (f in yt.files(nat, n, ".y")) {
                if (!(f in files)) { files += f; };
            };
        };
    } else {
        files = yt.files(nat, "t", ".y");
    };
    let eto = yt.num(yt.env("YTIMEOUT", "20"), 20) * yt.SCALE;
    let pto = yt.num(yt.env("YTIMEOUT_PE", "20"), 20) * yt.SCALE;
    let pass = 0;
    let pe_rows: [str] = [];
    let base_rows: [str] = [];
    let d = yt.tmp_dir("pefix");
    foreach (src in files) {
        let base = fs.path_stem(src);
        let exp = fs.read_file(nat + "/" + base + ".expected");
        let ec = yt.num(yt.read(nat + "/" + base + ".exit").trim(), 0);
        let inf = if (fs.is_file(nat + "/" + base + ".stdin")) { nat + "/" + base + ".stdin" } else { "" };
        let ce = yc.compile(ycc, [], src, d + "/e", 300);
        if (ce.code != 0) {
            base_rows += base.pad_right(34) + " ELF-COMPILE-FAIL " + yt.first_line(ce.out);
        } else {
            let c = yt.cmd([d + "/e"]);
            c.cwd = d;
            c.stdin = inf;
            c.timeout = eto;
            let e = yt.run(c);
            if (e.timed_out) { base_rows += base.pad_right(34) + " ELF-TIMEOUT"; }
            else if (exp != none && exp! != e.out) { base_rows += base.pad_right(34) + " ELF-OUTPUT-DIFF"; }
            else if (e.code != ec) { base_rows += base.pad_right(34) + " ELF-EXIT-DIFF got " + tostring(e.code) + " want " + tostring(ec); }
            else {
                let cp = pe_compile(ycc, [], src, d + "/p.exe");
                if (cp.code != 0) {
                    pe_rows += base.pad_right(34) + " PE-COMPILE-FAIL " + yt.first_line(cp.out);
                } else {
                    let p = wine(["./p.exe"], d, inf, pto);
                    let why = if (p.timed_out) { "no exit within " + tostring(pto) + "s (HUNG)" }
                        else if (exp != none && exp! != p.out) { "output differs: " + yt.first_diff(exp!, p.out) }
                        else if (p.code != ec) { "exit " + tostring(p.code) + ", want " + tostring(ec) }
                        else { "" };
                    if (why == "") {
                        pass += 1;
                    } else {
                        pe_rows += base.pad_right(34) + " " + why;
                        print("FAIL " + base.pad_right(34) + " " + why);
                    };
                };
            };
        };
    };
    fs.remove_all(d);
    print("\n=== " + tostring(files.length) + " fixtures: " + tostring(pass) + " PASS both targets, " + tostring(pe_rows.length)
        + " PE-only failures, " + tostring(base_rows.length) + " baseline failures ===\n");
    print("--- PE failures ---");
    foreach (r in pe_rows) { print("  " + r); };
    print("\n--- baseline failures (NOT a Windows problem; ELF itself disagrees) ---");
    foreach (r in base_rows) { print("  " + r); };
    if (pe_rows.length == 0 && base_rows.length == 0) { 0 } else { 1 }
};

// The C copy cross-built for Windows (make cycc.exe) compiles exactly what the
// Linux cycc compiles: the same exit, the same diagnostics, the same ELF bytes,
// and -S over a handful (stdout's text mode is the one host difference the ELF
// path cannot see). -g is not compared: DWARF holds the source's absolute path.
def cycc_win(av: [str]) -> long {
    let lin = yc.abs_path(yt.env("LIN", "cycc"));
    let win = yc.abs_path(yt.env("WIN", "cycc.exe"));
    if (!fs.is_file(win)) {
        eputs("no cycc.exe at " + win + " -- run make cycc.exe");
        return 2;
    };
    if (!yt.have("wine")) {
        print("skipped: no wine");
        return 0;
    };
    let files: [str] = [];
    if (av.length > 0) { files = av; } else {
        foreach (d in ["examples", "audit", "native", "ycc", "net"]) { files += yt.files(yc.ROOT + "/test/y/" + d, "", ".y"); };
    };
    let t = yt.tmp_dir("cyccwin");
    let same = 0;
    let differ = 0;
    foreach (f in files) {
        let lc = yt.cmd([lin, f, "-o", t + "/lin"]);
        lc.cwd = yc.ROOT;
        lc.timeout = 120;
        let l = yt.run(lc);
        let w = wine([win, f, "-o", t + "/win"], yc.ROOT, "", 180);
        let why = if (l.code != w.code) { "exit " + tostring(l.code) + " vs " + tostring(w.code) }
            else if (l.err != w.err) { "diagnostics differ" }
            else if (l.code == 0 && !yt.same_file(t + "/lin", t + "/win")) { "ELF bytes differ" }
            else { "" };
        if (why == "") { same += 1; } else {
            differ += 1;
            print("DIFF  " + f + " (" + why + ")");
        };
    };
    let sfiles = yt.files(yc.ROOT + "/test/y/examples", "", ".y") + yt.files(yc.ROOT + "/test/y/audit", "t4", ".y");
    if (sfiles.length > 8) { sfiles = sfiles[0:8]; };
    foreach (f in sfiles) {
        let l = yt.exe([lin, "-S", f]);
        let w = wine([win, "-S", f], yc.ROOT, "", 180);
        if (l.out == w.out) { same += 1; } else {
            differ += 1;
            print("DIFF  " + f + " (-S listing)");
        };
    };
    fs.remove_all(t);
    print("\ncycc-win: " + tostring(same) + " same, " + tostring(differ) + " different, over " + tostring(files.length)
        + " files (+ " + tostring(sfiles.length) + " -S)");
    if (differ == 0) { 0 } else { 1 }
};

// The NT syscall number each named Nt* function's stub loads, out of the
// installed wine's ntdll.dll: the only authority for what a probe under this
// wine calls. The stub is `mov %rcx,%r10` (4c 8b d1), `mov $imm32,%eax` (b8),
// `syscall` (0f 05).
def w_sysno(av: [str]) -> long {
    let prefix = yt.env("WINEPREFIX", yt.env("HOME", "/root") + "/.wine");
    let d = yt.bytes_of(yt.env("NTDLL", prefix + "/drive_c/windows/system32/ntdll.dll"));
    if (d.length < 64) {
        eputs("w-sysno: no ntdll.dll (set NTDLL or WINEPREFIX)");
        return 2;
    };
    let pe = yt.le(d, 60, 4);
    let nsec = yt.le(d, pe + 6, 2);
    let optsz = yt.le(d, pe + 20, 2);
    let opt = pe + 24;
    let dd = opt + (if (yt.le(d, opt, 2) == 523) { 112 } else { 96 });
    let erva = yt.le(d, dd, 4);
    let secs: [[long]] = [];
    for i in 0..nsec {
        let b = opt + optsz + 40 * i;
        let vsz = yt.le(d, b + 8, 4);
        let rsz = yt.le(d, b + 16, 4);
        secs += [[yt.le(d, b + 12, 4), if (vsz > rsz) { vsz } else { rsz }, yt.le(d, b + 20, 4)]];
    };
    def off(rva: long) -> long {
        foreach (s in secs) {
            if (s[0] <= rva && rva < s[0] + s[1]) { return s[2] + rva - s[0]; };
        };
        -1
    };
    let e = off(erva);
    let nnames = yt.le(d, e + 24, 4);
    let anames = yt.le(d, e + 32, 4);
    let aord = yt.le(d, e + 36, 4);
    let aaddr = yt.le(d, e + 28, 4);
    let want = if (av.length > 0) { av } else { ["NtClose"] };
    for i in 0..nnames {
        let o = off(yt.le(d, off(anames) + 4 * i, 4));
        let j = o;
        while (j < d.length && d[j] != 0) { j += 1; };
        let nm = from_bytes(d[o:j]);
        if (nm in want) {
            let oi = yt.le(d, off(aord) + 2 * i, 2);
            let fr = yt.le(d, off(aaddr) + 4 * oi, 4);
            let s = off(fr);
            let num = if (d[s + 3] == 184) { tostring(yt.le(d, s + 4, 4)) } else { "not a syscall stub" };
            print(nm.pad_right(32) + " num=" + num + "   rva=" + yt.hex(fr));
        };
    };
    0
};

export { gate, packinv, fixtures, cycc_win, w_sysno };
