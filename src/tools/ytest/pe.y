// pe.y -- the Windows gates for `ycc --target=win`.
//
// A PE is only ever RUN on a real Windows machine (wine is not used anywhere:
// it is more lenient than the kernel about alignment, import tables and
// syscall numbers, so a program could pass under it and not start on Windows).
// The runs are therefore not part of `make test`; they go to a Windows machine
// named in the git-ignored file `.pe-vm.conf` (see `pe-vm.conf.example`):
//
//   ytest pe-gate [YCC]             static, needs no Windows: a PE has well-formed
//                                   headers (objdump), the import table and its
//                                   IAT (prefilled in the file), a -g PE's debug
//                                   bytes, and the C copy's -g PE byte for byte
//                                   (default ./ynew)
//   ytest pe-packinv [YCC] [F...]   the std pack carries no target: a PE linked
//                                   from the pack equals one from --std=source
//   ytest pe-fixtures YCC [NAME...] every native fixture and every test/pe program
//                                   compiled to a PE, run on the Windows machine,
//                                   against its NAME.expected. A fixture with
//                                   NAME.skip.win (its text is the reason) is
//                                   skipped; NAME.expected.win is held to instead
//                                   of NAME.expected; NAME.args / NAME.env (test/pe)
//                                   give the raw command line and the environment
//   ytest cycc-win [F...]           cycc.exe (make cycc.exe) run on the Windows
//                                   machine compiles exactly what the Linux cycc
//                                   compiles
//   ytest w-sysno [NAME...]         the NT syscall number of each Nt* export of an
//                                   ntdll.dll (NTDLL=path, copied from a Windows
//                                   machine), read out of its stub
//
// The machine is reached over ssh (backend = ssh) and shares a directory with
// this one, or is this one (backend = local, on a Windows host). Everything the
// run needs is written under <share_local>/ytest-pe-N and run by test/pe/vm/*.ps1.
import fs;
import yt;
import yc;

def say(s: str) { print("pe: " + s); };

def bad(s: str) -> long {
    print("pe-gate: FAIL (" + s + ")");
    1
};

def objdump(args: [str]) -> str { yt.exe(["objdump"] + args).out };

def pe_compile(ycc: str, flags: [str], src: str, out: str) -> yt.Res {
    // PE fixtures are layout/runtime tests, not lifetime tests: check them with
    // the collector enabled unless the fixture chose a gc mode itself.
    let has_gc = false;
    foreach (f in flags) { if (f.starts_with("--gc")) { has_gc = true; }; };
    let fl = if (has_gc) { flags } else { flags + ["--gc=auto"] };
    let c = yt.cmd([ycc, "--target=win"] + fl + [src, "-o", out]);
    c.cwd = yc.ROOT;
    c.merge = true;
    c.timeout = 300;
    yt.run(c)
};

// ── the static gate ──────────────────────────────────────────────────────

def gate(av: [str]) -> long {
    let ycc = yc.abs_path(if (av.length > 0) { av[0] } else { "ynew" });
    let out = yt.tmp_dir("pe-gate");
    let src = yt.env("PE_GATE_SRC", yc.ROOT + "/test/y/examples/helloworld.y");
    say(ycc + " --target=win " + src);
    if (pe_compile(ycc, [], src, out + "/g.exe").code != 0) { return bad("the compiler refused"); };
    say(tostring(yt.size(out + "/g.exe")) + " bytes");
    if (!objdump(["-x", out + "/g.exe"]).contains("pei-x86-64")) { return bad("not a pei-x86-64 image"); };
    let h = objdump(["-h", out + "/g.exe"]);
    foreach (sec in [".text", ".pdata", ".xdata"]) {
        if (!h.contains(" " + sec + " ")) { return bad("no " + sec + " section"); };
        say("section " + sec + " present");
    };
    if (!objdump(["-x", out + "/g.exe"]).contains("Exception Directory")) { return bad("no exception data directory"); };
    say("exception directory (.pdata) present");
    // every program of test/pe compiles (these are PE layout fixtures, not
    // lifetime tests; the gc=auto opt-in keeps them focused)
    foreach (f in yt.files(yc.ROOT + "/test/pe", "", ".y")) {
        let r = pe_compile(ycc, ["--gc=auto"], f, out + "/p.exe");
        if (r.code != 0) { return bad("the compiler refused " + f + ": " + yt.first_line(r.out)); };
    };
    say("test/pe compiles");
    // the import table: the DLL and the function by name, and a second DLL so
    // the descriptor chain is proven
    let fssrc = yc.ROOT + "/test/pe/pathfs.y";
    if (pe_compile(ycc, ["--gc=auto"], fssrc, out + "/imp.exe").code != 0) { return bad("the compiler refused the import program"); };
    let p = objdump(["-p", out + "/imp.exe"]);
    foreach (w in ["DLL Name: KERNEL32.dll", "GetCurrentProcessId", "LoadLibraryA", "GetProcAddress", "DLL Name: advapi32.dll", "SystemFunction036"]) {
        if (!p.contains(w)) { return bad("the PE does not import " + w); };
    };
    say("import table ok (KERNEL32.dll!GetCurrentProcessId LoadLibraryA GetProcAddress, advapi32.dll!SystemFunction036)");
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
    // a Windows loader measures an IAT by walking it to its zero terminator and
    // snaps nothing for an all-zero one: the cells must start as the hint/name
    // RVAs, in file bytes
    let first = "";
    let seen = false;
    foreach (l in yt.lines(objdump(["-s", "-j", ".bss", out + "/imp.exe"]))) {
        let w = yt.words(l);
        if (seen && first == "" && w.length > 1) { first = w[1]; };
        if (l.contains("Contents of section .bss")) { seen = true; };
    };
    if (first == "" || first == "00000000") { return bad("the IAT cells start as zeros -- a Windows loader would skip every import"); };
    say("IAT cells prefilled in the file ok");
    // a -g PE carries its debug sections WITH their bytes
    if (pe_compile(ycc, ["-g", "--gc=auto"], fssrc, out + "/gimp.exe").code != 0) { return bad("the compiler refused the -g program"); };
    if (!objdump(["-h", out + "/gimp.exe"]).contains(".debug_l")) { return bad("a -g PE has no .debug_l section"); };
    if (!objdump(["-s", "-j", ".debug_l", out + "/gimp.exe"]).contains("Contents of section")) {
        return bad("a -g PE's .debug_l has no bytes in the file");
    };
    say("-g sections ok (.debug_l has its bytes)");
    // and the C copy builds THE SAME -g PE (a -g line marker once trapped every
    // cycc PE build, and only a PE walker could see it)
    if (fs.is_file(yc.CYCC)) {
        if (pe_compile(yc.CYCC, ["-g", "--gc=auto"], fssrc, out + "/cgimp.exe").code != 0) { return bad("the C copy refused the -g program"); };
        if (!yt.same_file(out + "/gimp.exe", out + "/cgimp.exe")) { return bad("the C copy's -g PE differs from the Y compiler's"); };
        say("the C copy's -g PE is byte-identical");
    };
    // --subsystem=gui makes a GUI image (no console), changing the one header word and
    // nothing else; the C copy writes the same bytes
    if (!objdump(["-x", out + "/gimp.exe"]).contains("(Windows CUI)")) { return bad("a default PE is not a console image"); };
    if (pe_compile(ycc, ["--subsystem=gui", "--gc=auto"], fssrc, out + "/gui.exe").code != 0) { return bad("the compiler refused --subsystem=gui"); };
    if (!objdump(["-x", out + "/gui.exe"]).contains("(Windows GUI)")) { return bad("--subsystem=gui did not make a GUI image"); };
    if (fs.is_file(yc.CYCC)) {
        if (pe_compile(yc.CYCC, ["--subsystem=gui", "--gc=auto"], fssrc, out + "/cgui.exe").code != 0) { return bad("the C copy refused --subsystem=gui"); };
        if (!yt.same_file(out + "/gui.exe", out + "/cgui.exe")) { return bad("the C copy's GUI PE differs from the Y compiler's"); };
    };
    if (pe_compile(ycc, ["--subsystem=bogus"], fssrc, out + "/bad.exe").code == 0) { return bad("--subsystem=bogus was accepted"); };
    say("--subsystem=gui: a GUI image, byte-identical in the C copy, a bad name refused");
    // A sealed PE: writable .text, entry inside it, no plaintext marker, the
    // same seed reproduces the image and another seed does not.
    let seal_src = yc.ROOT + "/test/pe/obfseal.y";
    let seal = pe_compile(ycc, ["--obfuscate", "--obfuscate-seed=9"], seal_src, out + "/seal.exe");
    if (seal.code != 0) { return bad("the compiler refused a sealed PE: " + yt.first_line(seal.out)); };
    let v = pe_view(out + "/seal.exe");
    if (!v.ok) { return bad("no .text in a sealed PE"); };
    if ((v.chars & 0x80000000) == 0 || (v.chars & 0x20000000) == 0 || (v.chars & 0x20) == 0) {
        return bad("a sealed PE's .text is not CNT_CODE|MEM_EXECUTE|MEM_READ|MEM_WRITE");
    };
    if (v.entry < v.trva || v.entry >= v.trva + v.tvsz) { return bad("the sealed entry is outside .text"); };
    let sbytes = fs.read_bytes(out + "/seal.exe");
    if (sbytes == none || has_bytes(sbytes!, "PE SEAL OK")) { return bad("a sealed PE still holds its literal"); };
    let seal2 = pe_compile(ycc, ["--obfuscate", "--obfuscate-seed=9"], seal_src, out + "/seal2.exe");
    let seal3 = pe_compile(ycc, ["--obfuscate", "--obfuscate-seed=10"], seal_src, out + "/seal3.exe");
    if (seal2.code != 0 || seal3.code != 0 || !yt.same_file(out + "/seal.exe", out + "/seal2.exe")
        || yt.same_file(out + "/seal.exe", out + "/seal3.exe")) {
        return bad("a sealed PE is not seed-reproducible");
    };
    say("sealed PE: writable .text, entry inside it, literal absent, seed-reproducible");
    fs.remove_all(out);
    0
};

// The PE header facts the seal depends on: .text's RVA/virtual size/chars and
// the entry RVA.
type PeView = { ok: bool, entry: long, trva: long, tvsz: long, chars: long };
def pe_u16(b: [byte], o: long) -> long { b[o] | (b[o + 1] << 8) };
def pe_u32(b: [byte], o: long) -> long {
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)
};
def pe_view(path: str) -> PeView {
    let b = fs.read_bytes(path);
    if (b == none || len(b!) < 512) { return { ok: false, entry: 0, trva: 0, tvsz: 0, chars: 0 }; };
    let x = b!;
    let pe = pe_u32(x, 60);
    let nsec = pe_u16(x, pe + 6);
    let opt = pe_u16(x, pe + 20);
    let entry = pe_u32(x, pe + 24 + 16);
    let so = pe + 24 + opt;
    let i = 0;
    while (i < nsec) {
        let o = so + 40 * i;
        if (x[o] == 46 && x[o + 1] == 116 && x[o + 2] == 101 && x[o + 3] == 120
            && x[o + 4] == 116) {
            return { ok: true, entry: entry, trva: pe_u32(x, o + 12),
                tvsz: pe_u32(x, o + 8), chars: pe_u32(x, o + 36) };
        };
        i += 1;
    };
    { ok: false, entry: entry, trva: 0, tvsz: 0, chars: 0 }
};
def has_bytes(hay: [byte], needle: str) -> bool {
    let nb = bytes(needle);
    let found = false;
    let i = 0;
    while (i + len(nb) <= len(hay) && !found) {
        let j = 0;
        let same = true;
        while (j < len(nb) && same) {
            if (hay[i + j] != nb[j]) { same = false; };
            j += 1;
        };
        if (same) { found = true; };
        i += 1;
    };
    found
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
// from the attached pack must equal one from --std=source.
def packinv(av: [str]) -> long {
    let ycc = yc.abs_path(if (av.length > 0) { av[0] } else { "ynew" });
    let files = if (av.length > 1) { av[1:] } else { yt.files(yc.ROOT + "/test/y/native", "t", ".y") + yt.files(yc.ROOT + "/test/y/examples", "", ".y") };
    let ok = 0;
    let differ = 0;
    let skipped = 0;
    foreach (f in files) {
        let a = yt.tmp("pa") + ".exe";
        let b = yt.tmp("pb") + ".exe";
        if (pe_compile(ycc, [], f, a).code != 0 || pe_compile(ycc, ["--std=source"], f, b).code != 0) {
            skipped += 1;
        } else if (yt.same_file(a, b)) {
            ok += 1;
        } else {
            differ += 1;
            print("DIFF  " + f);
        };
        fs.remove_file(a);
        fs.remove_file(b);
    };
    print("pe-packinv: " + tostring(ok) + " same, " + tostring(differ) + " different, " + tostring(skipped) + " not compiled by both");
    if (differ == 0) { 0 } else { 1 }
};

// ── the Windows machine ──────────────────────────────────────────────────

type Vm = {
    ssh: [str],          // the ssh command and its options, up to the destination
    local: bool,         // this machine is the Windows machine
    share_local: str,    // a directory both machines see, as this one names it
    share_remote: str,   // ... as Windows names it (a UNC path, or a local path when `local`)
    user: str,           // credentials for `net use` of the share ("" for none)
    pass: str,
    drive: str,          // the drive letter the share is mapped to on Windows
    timeout: long,       // seconds a fixture may run
};

// `key = value` lines of the git-ignored .pe-vm.conf (or $PE_VM_CONF); '#' starts
// a comment. Returns none, after saying how to set one up, when there is none.
def vm_conf() -> Vm? {
    let path = yt.env("PE_VM_CONF", yc.ROOT + "/.pe-vm.conf");
    if (!fs.is_file(path)) {
        eputs("no " + path + ": copy pe-vm.conf.example there and describe the Windows machine");
        return none;
    };
    let vm: Vm = { ssh: [], local: false, share_local: "", share_remote: "", user: "", pass: "", drive: "Z", timeout: 30 };
    if (yt.env("OS", "") == "Windows_NT") { vm.local = true; };
    foreach (raw in yt.lines(yt.read(path))) {
        let l = raw;
        let hash = index_of(l, "#");
        if (hash >= 0) { l = l[0:hash]; };
        let eq = index_of(l, "=");
        if (eq < 0) { continue; };
        let k = l[0:eq].trim();
        let v = l[eq + 1:].trim();
        if (k == "backend") { vm.local = v == "local"; }
        else if (k == "ssh") { vm.ssh = yt.words(v); }
        else if (k == "share_local") { vm.share_local = v; }
        else if (k == "share_remote") { vm.share_remote = v; }
        else if (k == "share_user") { vm.user = v; }
        else if (k == "share_pass") { vm.pass = v; }
        else if (k == "drive") { vm.drive = v; }
        else if (k == "timeout") { vm.timeout = yt.num(v, 30); };
    };
    if (vm.share_local == "") {
        eputs(path + ": share_local is not set");
        return none;
    };
    if (!vm.local && (vm.ssh.length == 0 || vm.share_remote == "")) {
        eputs(path + ": backend ssh needs `ssh` and `share_remote`");
        return none;
    };
    some(vm)
};

// Run `script` (a .ps1 under the run directory `d`) on the Windows machine with
// `args`; its stdout and stderr come back.
def vm_run(vm: Vm, d: str, script: str, args: str) -> yt.Res {
    if (vm.local) {
        let c = yt.cmd(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", d + "/" + script, "-Share", d] + yt.words(args));
        c.merge = true;
        c.timeout = 7200;
        return yt.run(c);
    };
    let share = vm.drive + ":\\" + fs.path_basename(d);
    let line = "net use " + vm.drive + ": /delete /y >nul 2>&1 & net use " + vm.drive + ": " + vm.share_remote;
    if (vm.user != "") { line += " /user:" + vm.user + " " + vm.pass; };
    line += " >nul & powershell -NoProfile -ExecutionPolicy Bypass -File " + share + "\\" + script + " -Share " + share + " " + args;
    let c = yt.cmd(vm.ssh + [line]);
    c.merge = true;
    c.timeout = 7200;
    yt.run(c)
};

// Copy the tree `from` into `to` (files only; names as they are).
def copy_tree(from: str, to: str) {
    fs.make_dirs(to);
    foreach (n in yt.ls(from)) {
        let p = from + "/" + n;
        if (fs.is_dir_itself(p)) { copy_tree(p, to + "/" + n); }
        else { fs.copy_file(p, to + "/" + n); };
    };
};

// What a fixture's file asks for beside it: its `// flags:` and `// scratch`.
type Probe = { flags: [str], scratch: bool };

def probe(src: str) -> Probe {
    let flags: [str] = [];
    let scratch = false;
    foreach (line in yt.read(src).split("\n")) {
        if (line.starts_with("// flags: ") && flags.length == 0) {
            foreach (f in line[10:].split(" ")) {
                if (f != "") { flags += f; };
            };
        };
        if (line.starts_with("// scratch")) { scratch = true; };
    };
    { flags: flags, scratch: scratch }
};

// A fresh <share_local>/ytest-pe-<time> holding the runner scripts and the repo's
// test tree (a fixture reads test/data and src/y/std/fs.y from the repo root). A
// new name every run: a Windows SMB client caches directory listings for seconds,
// and a reused name showed it the last run's files.
def vm_prepare(vm: Vm) -> str {
    let d = vm.share_local + "/ytest-pe-" + tostring(clock_us());
    foreach (old in yt.ls(vm.share_local)) {
        if (old.starts_with("ytest-pe-")) { fs.remove_all(vm.share_local + "/" + old); };
    };
    fs.make_dirs(d + "/out");
    foreach (s in ["run.ps1", "cycc.ps1"]) { fs.copy_file(yc.ROOT + "/test/pe/vm/" + s, d + "/" + s); };
    copy_tree(yc.ROOT + "/test", d + "/root/test");
    fs.make_dirs(d + "/root/src/y");
    copy_tree(yc.ROOT + "/src/y/std", d + "/root/src/y/std");
    copy_tree(yc.ROOT + "/src/y/arch", d + "/root/src/y/arch");
    // the compiler's own modules, which test/y/ycc imports
    foreach (n in yt.ls(yc.ROOT + "/src/y")) {
        if (n.ends_with(".y")) { fs.copy_file(yc.ROOT + "/src/y/" + n, d + "/root/src/y/" + n); };
    };
    d
};

// ── every fixture, run on Windows ────────────────────────────────────────
// Each fixture is compiled as a PE here, run there (stdout and stderr merged,
// stdin from NAME.stdin, a `// scratch` fixture in a directory of its own, any
// other in the repo-root copy), and its bytes and exit status come back to be
// held to NAME.expected and NAME.exit. A run has a timeout: one hung fixture
// must not wedge the rest.
def fixtures(av: [str]) -> long {
    if (av.length == 0) {
        eputs("usage: ytest pe-fixtures YCC [fixture...]");
        return 2;
    };
    let vmo = vm_conf();
    if (vmo == none) { return 2; };
    let vm = vmo!;
    let ycc = yc.abs_path(av[0]);
    let nat = yc.ROOT + "/test/y/native";
    let pdir = yc.ROOT + "/test/pe";
    let files: [str] = [];
    if (av.length > 1) {
        foreach (n in av[1:]) {
            foreach (f in yt.files(nat, n, ".y") + yt.files(pdir, n, ".y")) {
                if (!(f in files)) { files += f; };
            };
        };
    } else {
        files = yt.files(nat, "t", ".y") + yt.files(pdir, "", ".y");
    };
    let d = vm_prepare(vm);
    let manifest: [str] = [];
    let rows: [str] = [];
    let skipped = 0;
    let names: [str] = [];
    foreach (src in files) {
        let base = fs.path_stem(src);
        let dir = fs.path_dirname(src);
        if (fs.is_file(dir + "/" + base + ".skip.win")) {
            skipped += 1;
            print("SKIP " + base.pad_right(34) + " " + yt.first_line(yt.read(dir + "/" + base + ".skip.win")));
            continue;
        };
        let pr = probe(src);
        let r = pe_compile(ycc, pr.flags, src, d + "/out/" + base + ".exe");
        if (r.code != 0) {
            rows += base.pad_right(34) + " PE-COMPILE-FAIL " + yt.first_line(r.out);
            continue;
        };
        names += src;
        manifest += base + " " + (if (pr.scratch || dir == pdir) { "1" } else { "0" }) + " " + (if (dir == pdir) { "pe" } else { "y/native" });
    };
    fs.write_file(d + "/manifest.txt", join(manifest, "\n") + "\n");
    say("running " + tostring(names.length) + " fixtures on the Windows machine");
    let run = vm_run(vm, d, "run.ps1", "-Timeout " + tostring(vm.timeout));
    if (!fs.is_file(d + "/res/DONE")) {
        print("the run on the Windows machine did not finish:\n" + yt.clip(run.out, 1500));
        return 1;
    };
    let pass = 0;
    foreach (src in names) {
        let base = fs.path_stem(src);
        let dir = fs.path_dirname(src);
        let ec = yt.num(yt.read(dir + "/" + base + ".exit").trim(), 0);
        let ef = if (fs.is_file(dir + "/" + base + ".expected.win")) { dir + "/" + base + ".expected.win" } else { dir + "/" + base + ".expected" };
        let got_code = yt.read(d + "/res/" + base + ".exit").trim();
        let got = yt.read(d + "/res/" + base + ".out");
        let why = "";
        // the startup self-test (arch/wselftest.s) runs before the program's first
        // instruction; a drifted w_sysno ends the run with this whole line:
        // runtime error: NT syscall self-test failed (a w_sysno number does not match this Windows build)
        if (got.contains("runtime error: NT syscall self-test failed (a w_sysno number does not match this Windows build)")) {
            why = "the Windows syscall self-test failed: a w_sysno number does not match this build";
        } else if (got_code == "HUNG") { why = "no exit within " + tostring(vm.timeout) + "s (HUNG)"; }
        else if (fs.is_file(ef) && yt.read(ef) != got) { why = "output differs: " + yt.first_diff(yt.read(ef), got); }
        else if (yt.num(got_code, -999) != ec) { why = "exit " + got_code + ", want " + tostring(ec); };
        if (why == "") { pass += 1; } else {
            rows += base.pad_right(34) + " " + why;
            print("FAIL " + base.pad_right(34) + " " + why);
        };
    };
    print("\n=== " + tostring(files.length) + " fixtures: " + tostring(pass) + " PASS on Windows, " + tostring(skipped) + " skipped (Windows has no counterpart), " + tostring(rows.length) + " failures ===");
    foreach (r in rows) { print("  " + r); };
    if (yt.env("PE_KEEP", "") == "") { fs.remove_all(d); };
    if (rows.length == 0) { 0 } else { 1 }
};

// ── cycc.exe on Windows ──────────────────────────────────────────────────
// The generated C seed built for Windows (make cycc.exe) compiles what the
// Linux cycc compiles: the same exit, the same diagnostics, the same ELF bytes,
// and --emit=asm over a handful (stdout's text mode is the one host difference the ELF
// path cannot see). -g is not compared: DWARF holds the source's absolute path.
def cycc_win(av: [str]) -> long {
    let lin = yc.abs_path(yt.env("LIN", "cycc"));
    let win = yc.abs_path(yt.env("WIN", "cycc.exe"));
    if (!fs.is_file(win)) {
        eputs("no cycc.exe at " + win + " -- run make cycc.exe");
        return 2;
    };
    let vmo = vm_conf();
    if (vmo == none) { return 2; };
    let vm = vmo!;
    let files: [str] = [];
    if (av.length > 0) { files = av; } else {
        foreach (dn in ["examples", "audit", "native", "ycc", "net"]) { files += yt.files(yc.ROOT + "/test/y/" + dn, "", ".y"); };
    };
    // The Windows C host shim has no fork; exclude compile-time execution.
    let nometa: [str] = [];
    foreach (f in files) {
        if (!yt.read(f).contains("#{")) { nometa += f; };
    };
    let nmeta = files.length - nometa.length;
    files = nometa;
    let sfiles = yt.files(yc.ROOT + "/test/y/examples", "", ".y") + yt.files(yc.ROOT + "/test/y/audit", "t4", ".y");
    if (sfiles.length > 8) { sfiles = sfiles[0:8]; };
    let d = vm_prepare(vm);
    fs.copy_file(win, d + "/cycc.exe");
    // one line a job: "elf|S", the path relative to the repo root
    let jobs: [str] = [];
    foreach (f in files) { jobs += "elf " + f[len(yc.ROOT) + 1:]; };
    foreach (f in sfiles) { jobs += "S " + f[len(yc.ROOT) + 1:]; };
    fs.write_file(d + "/jobs.txt", join(jobs, "\n") + "\n");
    say("compiling " + tostring(files.length) + " programs with cycc.exe on the Windows machine");
    let run = vm_run(vm, d, "cycc.ps1", "-Timeout 180");
    if (!fs.is_file(d + "/res/DONE")) {
        print("the run on the Windows machine did not finish:\n" + yt.clip(run.out, 1500));
        return 1;
    };
    let t = yt.tmp_dir("cyccwin");
    let same = 0;
    let differ = 0;
    let n = 0;
    foreach (f in files) {
        let lc = yt.cmd([lin, f[len(yc.ROOT) + 1:], "-o", t + "/lin"]);
        lc.cwd = yc.ROOT;
        lc.timeout = 120;
        let l = yt.run(lc);
        let wcode = yt.num(yt.read(d + "/res/" + tostring(n) + ".exit").trim(), -999);
        let werr = yt.read(d + "/res/" + tostring(n) + ".err").replace("\r\n", "\n");
        let why = if (l.code != wcode) { "exit " + tostring(l.code) + " vs " + tostring(wcode) }
            else if (l.err != werr) { "diagnostics differ" }
            else if (l.code == 0 && !yt.same_file(t + "/lin", d + "/res/" + tostring(n) + ".out")) { "ELF bytes differ" }
            else { "" };
        if (why == "") { same += 1; } else {
            differ += 1;
            print("DIFF  " + f + " (" + why + ")");
        };
        n += 1;
    };
    foreach (f in sfiles) {
        let lcs = yt.cmd([lin, "--emit=asm", f[len(yc.ROOT) + 1:]]);
        lcs.cwd = yc.ROOT;
        let l = yt.run(lcs);
        let w = yt.read(d + "/res/" + tostring(n) + ".out").replace("\r\n", "\n");
        if (l.out == w) { same += 1; } else {
            differ += 1;
            print("DIFF  " + f + " (-S listing)");
        };
        n += 1;
    };
    fs.remove_all(t);
    if (yt.env("PE_KEEP", "") == "") { fs.remove_all(d); };
    print("\ncycc-win: " + tostring(same) + " same, " + tostring(differ) + " different, over " + tostring(files.length)
        + " files (+ " + tostring(sfiles.length) + " -S), " + tostring(nmeta) + " with meta blocks left out");
    if (differ == 0) { 0 } else { 1 }
};

// The NT syscall number each named Nt* function's stub loads, out of an
// ntdll.dll (NTDLL=path; copy System32\ntdll.dll from the Windows machine): the
// only authority for what that build calls. The stub is `mov %rcx,%r10`
// (4c 8b d1), `mov $imm32,%eax` (b8), `syscall` (0f 05). Low numbers are the
// same from Windows 10 1607 on; a high one (NtQueryFullAttributesFile is 327
// on 19045) is not, which is why the runtime reads that one out of the running
// ntdll (arch/wsys.s y_w_sn_attrs).
def w_sysno(av: [str]) -> long {
    let d = yt.bytes_of(yt.env("NTDLL", ""));
    if (d.length < 64) {
        eputs("w-sysno: set NTDLL to a copy of a Windows machine's ntdll.dll");
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
