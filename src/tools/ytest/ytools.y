// ytools.y -- two developer commands that are not tests.
//
//   ytest oom [PROG [N]]               test/oom's programs, each built with ./ycc
//                                      and run under the 3.5 GiB cap (AGENTS.md),
//                                      printing the line each reports
//   ytest install-vscode [--dry-run] [--force]
//                                      build yserve and the VS Code extension,
//                                      install the .vsix, put yserve beside it
import fs;
import yt;
import yc;

// ── oom ──────────────────────────────────────────────────────────────────

def main_oom(av: [str]) -> long {
    let prog = if (av.length > 0) { av[0] } else { "" };
    let n = if (av.length > 1) { av[1] } else { "" };
    let dir = yc.ROOT + "/test/oom";
    let d = yt.tmp_dir("oom");
    foreach (f in yt.ls(dir)) {
        let name = if (f.ends_with(".y")) { f[:f.length - 2] } else { "" };
        if (name.starts_with("s") && (prog == "" || prog == name)) {
            let c = yc.compile(yc.YCC, [], dir + "/" + f, d + "/" + name, 300);
            if (c.code != 0) {
                print(name + ": COMPILE FAILED");
                foreach (l in yt.lines(c.out)) { print("    " + l); };
            } else {
                if (c.out != "") {
                    print(name + ": compiler diagnostics:");
                    foreach (l in yt.lines(c.out)) { print("    " + l); };
                };
                let r = yc.run_bin(d + "/" + name, if (n != "") { [n] } else { [] }, "", 120);
                foreach (l in yt.lines(r.out)) { if (l != "") { print(name + ": " + l); }; };
                if (r.code != 0) { print(name + ": exit " + tostring(r.code) + " (heap cap " + tostring(yc.PROG_MEM_KB) + " KB)"); };
            };
        };
    };
    fs.remove_all(d);
    0
};

// ── install-vscode ───────────────────────────────────────────────────────
//
// The two halves are separate products with one build path each, so this only
// orders them; every build step is the Makefile's own target. `make lsp-vsix`
// deliberately does NOT ship yserve inside the .vsix (that would bake in the
// machine that built it), which is why the last step is a COPY: the extension
// looks for the server in y.lsp.serverPath, then beside itself, then in the
// workspace -- and an installed extension lives in ~/.vscode/extensions, which
// reaches neither the repository nor whatever project is open.
//
// Two caveats, printed at the end: an extension UPDATE replaces that directory
// and the copy with it, and a rebuild of ./yserve does not reach the copy. Set
// y.lsp.serverPath for an install that survives both.
//
// Not under an address-space cap: the `code` CLI is Electron, which reserves far
// more virtual address space than it uses and dies under one with a trap that
// reads as "the install failed". (The make recipes cap their own compiles.)

let DRY = false;

def say(s: str) { print(s); };

def step(s: str) { print("\n== " + s); };

// one command, shown; under --dry-run only shown
def run(argv: [str]) -> bool {
    if (DRY) {
        print("   would run: " + join(argv, " "));
        return true;
    };
    print("   $ " + join(argv, " "));
    let c = yt.cmd(argv);
    c.mem_kb = 0;
    c.timeout = 1800;
    c.merge = true;
    let r = yt.run(c);
    foreach (l in yt.lines(r.out)) { if (l != "") { print("     " + l); }; };
    r.code == 0
};

// a "key": "value" field of package.json
def field(doc: str, key: str) -> str {
    let k = "\"" + key + "\"";
    let i = doc.index_of(k);
    if (i < 0) { return ""; };
    let q = doc.index_of("\"", doc.index_of(":", i) + 1);
    let e = doc.index_of("\"", q + 1);
    doc[q + 1:e]
};

// a process's own name: /proc/PID/cmdline up to its first NUL
def argv0(cmdline: str) -> str {
    let i = 0;
    while (i < cmdline.length && cmdline.byte_at(i) != 0) { i += 1; };
    fs.path_basename(cmdline[:i])
};

// a file's modification time, seconds (stat(2): st_mtime at offset 88)
def mtime(path: str) -> long {
    let p = yt.cz(path);
    let buf: [byte; 144] = [0; 144];
    if (syscall(4, &p[0], &buf[0]) != 0) { return 0; };
    let t = 0;
    let i = 7;
    while (i >= 0) {
        t = (t << 8) | buf[88 + i];
        i -= 1;
    };
    t
};

def main_install(av: [str]) -> long {
    let force = false;
    foreach (a in av) {
        if (a == "--dry-run") { DRY = true; } else if (a == "--force") { force = true; } else if (a == "-h" || a == "--help") {
            say("usage: ytest install-vscode [--dry-run] [--force]\n\n  --dry-run   print the steps and the commands, build and install nothing.\n  --force     install even while VS Code is running (it replaces the live\n              extension's files, which has frozen VS Code here).");
            return 0;
        } else {
            say("install-vscode: unknown argument '" + a + "'");
            return 2;
        };
    };
    let root = yc.ROOT;
    let ext = root + "/src/tools/lsp/vscode-y-lang";
    if (!fs.is_dir(ext)) {
        say("install-vscode: " + ext + " is missing -- run this from the repository");
        return 1;
    };
    // npm builds the extension; the `code` CLI is optional (VS Code installs it
    // from the Command Palette and it is often absent), so its absence is a warning
    let missing: [str] = [];
    foreach (t in ["node", "npm"]) { if (yt.which(t, yt.env("PATH", "")) == "") { missing += t; }; };
    if (missing.length > 0) {
        say("install-vscode: missing " + join(missing, " ") + " -- both build the extension (npm ci && tsc).");
        return 1;
    };
    let code = "";
    foreach (c in ["code", "code-insiders", "codium"]) { if (code == "" && yt.which(c, yt.env("PATH", "")) != "") { code = c; }; };
    let pkg = yt.read(ext + "/package.json");
    let vsix = field(pkg, "name") + "-" + field(pkg, "version") + ".vsix";
    if (code == "") {
        say("install-vscode: no 'code' CLI on PATH, so the .vsix will not be installed for you. Everything");
        say("  is still built; finish with  Extensions: Install from VSIX...  in the Command Palette, or");
        say("    <path-to>/bin/code --install-extension '" + ext + "/" + vsix + "' --force");
    };
    say("install-vscode: " + vsix + ", into " + (if (code == "") { "VS Code, by hand" } else { code }));

    step("1/4  the language server");
    if (!run(["make", "-C", root, "yserve"])) {
        say("install-vscode: 'make yserve' failed");
        return 1;
    };
    step("2/4  the extension (npm install, tsc, vsce package)");
    if (!run(["make", "-C", root, "lsp-vsix"])) {
        say("install-vscode: 'make lsp-vsix' failed");
        return 1;
    };
    let vpath = ext + "/" + vsix;
    if (!DRY && !fs.is_file(vpath)) {
        say("install-vscode: " + vpath + " is missing after the build");
        return 1;
    };

    // REFUSED WHILE VS CODE IS RUNNING unless --force: installing the same
    // version replaces the live extension's directory underneath the extension
    // host, which has frozen VS Code for a minute here.
    step("3/4  install the extension");
    if (!force && !DRY && code != "") {
        let running = false;
        foreach (p in yt.ls("/proc")) {
            let cmdline = if (yt.num(p, -1) > 0) { yt.read("/proc/" + p + "/cmdline") } else { "" };
            if (cmdline.contains("resources/app/out/vs/code") || argv0(cmdline) == "code"
                || argv0(cmdline) == "code-insiders") { running = true; };
        };
        if (running) {
            say("install-vscode: VS Code is running. Installing over a live extension replaces its files");
            say("  underneath the extension host, and that has frozen VS Code here. Quit VS Code and run");
            say("  this again, or pass --force if you know the reload will be clean.");
            return 1;
        };
    };
    if (code != "") {
        // --force: re-installing the same id and version after a rebuild is the normal case
        if (!run([code, "--install-extension", vpath, "--force"])) {
            say("install-vscode: the install failed. Install it by hand:");
            say("  " + code + " --install-extension '" + vpath + "' --force");
            return 1;
        };
    } else {
        say("   skipped -- install it by hand as described above");
    };

    // <extensionDir>/yserve: the first place the extension looks after
    // y.lsp.serverPath. The newest matching directory, because after an update
    // the old version's is still there.
    step("4/4  put yserve next to the installed extension");
    let id = field(pkg, "publisher") + "." + field(pkg, "name");
    let dest = "";
    let home = yt.env("HOME", "");
    foreach (r in [yt.env("VSCODE_EXTENSIONS", ""), home + "/.vscode/extensions", home + "/.vscode-insiders/extensions"]) {
        if (dest == "" && r != "" && fs.is_dir(r)) {
            let best = 0;
            foreach (e in yt.ls(r)) {
                if (e.starts_with(id + "-") && fs.is_dir(r + "/" + e) && mtime(r + "/" + e) >= best) {
                    best = mtime(r + "/" + e);
                    dest = r + "/" + e;
                };
            };
        };
    };
    if (dest == "") {
        say("   could not find the installed extension directory for '" + id + "'.");
        say("   Set y.lsp.serverPath to " + root + "/yserve instead -- it survives an extension update:");
        say("     \"y.lsp.serverPath\": \"" + root + "/yserve\"");
    } else if (!run(["install", "-m", "755", root + "/yserve", dest + "/yserve"])) {
        say("install-vscode: could not write into " + dest + "; set y.lsp.serverPath to " + root + "/yserve instead.");
    };
    say("\nNext:\n  * Reload the window: Developer: Reload Window (or restart VS Code). The extension activates on");
    say("    a .y file, so an already-open editor has not started the server yet.");
    say("  * Open a .y file. Errors and warnings appear in Problems and in the gutter.\n");
    say("If VS Code says it cannot find yserve, set this in your settings -- it survives both an extension");
    say("update and a rebuild:\n\n    \"y.lsp.serverPath\": \"" + root + "/yserve\"\n");
    say("Then Developer: Reload Window. See src/tools/lsp/vscode-y-lang/README.md for the other settings.");
    0
};

export { main_oom, main_install };
