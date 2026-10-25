// su_webb.y -- suite web-browser: the W5 page in a headless browser.
//
// The browser half of W5 is src/web/test/browser.test.mjs: it builds sites
// with the compiler under test, serves them over HTTP, drives Chromium over
// DevTools and checks ?ytest=1, stdin, IndexedDB persistence, pause_hidden,
// the start overlay, files.bin and the feature check.
//
// The browser cannot run under ytest's 3.5 GiB address-space cap (Chromium
// reserves far more virtual memory than it uses) unless a systemd-run --user
// memory scope is available.  When it is not, each case is
// skipped with that reason; make web-browser is a by-hand target.
import fs;
import yt;
import yc;

let DIR = "";
let BROWSER = "";
let WHY = "";
let NODE = "";
let DRIVER = "";
let INITED = false;

def init() {
    if (INITED) { return; };
    INITED = true;
    DIR = yc.ROOT + "/test/web";
    DRIVER = yc.ROOT + "/src/web/test/browser.test.mjs";
    let path = yt.env("PATH", "/usr/bin:/bin");
    NODE = yt.which(yt.env("NODE", "node"), path);
    if (NODE == "") { NODE = "node"; };
    BROWSER = yt.env("WEB_BROWSER", "");
    if (BROWSER == "") {
        let home = yt.env("HOME", "");
        let cands = [home + "/.cache/ms-playwright/chromium-1248/chrome-linux64/chrome",
            home + "/.cache/ms-playwright/chromium_headless_shell-1248/chrome-headless-shell-linux64/chrome-headless-shell"];
        foreach (c in cands) {
            if (BROWSER == "" && fs.is_file(c)) { BROWSER = c; };
        };
    };
    if (BROWSER == "") {
        let ff = yt.which("firefox", path);
        if (ff != "") {
            BROWSER = ff;
            WHY = "Firefox is installed but the browser driver speaks Chromium's DevTools protocol (set WEB_BROWSER=/path/to/chrome)";
        };
    };
    if (BROWSER == "") {
        WHY = "no browser: set WEB_BROWSER, or install Playwright chromium-1248 in ~/.cache/ms-playwright";
    } else if (WHY == "") {
        let ud = yt.tmp_dir("chrome-probe");
        let c = yt.cmd([BROWSER, "--headless=new", "--no-sandbox", "--disable-gpu",
            "--disable-dev-shm-usage", "--user-data-dir=" + ud,
            "--virtual-time-budget=300", "--dump-dom", "data:text/html,<title>ytest</title>"]);
        c.cwd = yc.ROOT;
        c.merge = true;
        c.timeout = 60 * yt.SCALE;
        // A browser reserves far more ADDRESS SPACE than it uses; it runs
        // it under a MemoryMax cgroup, not RLIMIT_AS.  No virtual cap here.
        c.mem_kb = 0;
        let r = yt.run(c);
        fs.remove_all(ud);
        if (r.code != 0 || !r.out.contains("<title>ytest</title>")) {
            WHY = "headless Chromium cannot start here (set WEB_BROWSER, or install Playwright chromium-1248)";
        };
    };
    if (WHY == "" && !fs.is_file(DRIVER)) {
        WHY = "src/web/test/browser.test.mjs is missing (the browser host is W5's other half)";
    };
    if (WHY == "" && !fs.is_file(yc.ROOT + "/src/web/page.html")) {
        WHY = "src/web/page.html is missing (the page is W5's other half)";
    };
};

def webcc() -> str { yt.env("YWEB", yc.YCC) };

// One fixture's share of the driver's report: its check names are fixed.
def driver_case(name: str, wants: [str]) -> yt.Case {
    yt.case_of("web-browser", name, () => {
        init();
        if (WHY != "") { yt.skip(name, WHY); return; };
        let c = yt.cmd([NODE, DRIVER]);
        c.cwd = yc.ROOT;
        c.merge = true;
        c.timeout = 240 * yt.SCALE;
        c.mem_kb = 0;
        c.env = ["YCC=" + webcc(), "WEB_BROWSER=" + BROWSER, "PATH=" + yt.env("PATH", "/usr/bin:/bin")];
        let r = yt.run(c);
        let bad: [str] = [];
        foreach (w in wants) {
            if (!r.out.contains("ok - " + w)) { bad += w; };
        };
        yt.check(name, r.code == 0 && bad.length == 0,
            "exit=" + tostring(r.code) + " missing: " + join(bad, "; ") + " " + yt.clip(r.out, 500));
    })
};

// --web-page=html and --web-page: the placeholders are gone, the host and the
// config are where page.js looks for them, and no relative file is missing.
def emit_case() {
    init();
    if (!fs.is_file(yc.ROOT + "/src/web/page.html")) {
        yt.skip("the emitter writes the site and the single file", "src/web/page.html is missing");
        return;
    };
    let d = yt.tmp_dir("webb");
    let src = DIR + "/w100_console.y";
    let site = d + "/site";
    let c1 = yt.cmd([webcc(), "--target=web", "--web=title=Site Title", "--web-page", "-o", site, src]);
    c1.cwd = yc.ROOT; c1.merge = true; c1.timeout = 180 * yt.SCALE; c1.mem_kb = yc.PROG_MEM_KB;
    let r1 = yt.run(c1);
    let ok = r1.code == 0;
    let why = "page exit=" + tostring(r1.code) + " " + yt.clip(r1.out, 300);
    if (ok) {
        foreach (f in ["index.html", "w100_console.wasm"]) {
            if (!fs.is_file(site + "/" + f)) { ok = false; why = "missing " + f; };
        };
        foreach (f in ["page.js", "core.js", "page.css", "package.json"]) {
            if (fs.is_file(site + "/" + f)) { ok = false; why = "unnecessary " + f; };
        };
        let html = yt.read(site + "/index.html");
        if (html.contains("{{TITLE}}") || html.contains("{{CONFIG}}") || html.contains("{{HOST}}") || html.contains("{{MODULE}}")) {
            ok = false; why = "a placeholder survived";
        };
        if (!html.contains("Site Title") || !html.contains("yweb:page.js") || !html.contains("<style>")) {
            ok = false; why = "title or inline host wrong";
        };
    };
    yt.check("--web-page writes the site", ok, why);

    let one = d + "/one.html";
    let c2 = yt.cmd([webcc(), "--target=web", "--web-page=html", "-o", one, src]);
    c2.cwd = yc.ROOT; c2.merge = true; c2.timeout = 180 * yt.SCALE; c2.mem_kb = yc.PROG_MEM_KB;
    let r2 = yt.run(c2);
    let ok2 = r2.code == 0 && fs.is_file(one);
    let why2 = "html exit=" + tostring(r2.code) + " " + yt.clip(r2.out, 300);
    if (ok2) {
        let h = yt.read(one);
        if (!h.contains("\"module_base64\":\"")) { ok2 = false; why2 = "no module_base64"; };
        if (!h.contains("importmap") || !h.contains("yweb:page.js")) { ok2 = false; why2 = "no inline host"; };
        if (h.contains("src=\"page.js\"")) { ok2 = false; why2 = "the single file still loads page.js"; };
        if (!h.contains("<style>")) { ok2 = false; why2 = "page.css was not inlined"; };
    };
    yt.check("--web-page=html writes one self-contained file", ok2, why2);
    fs.remove_all(d);
};

// ycc build --target=web: build/web/NAME/ is the site, bin/NAME the launcher,
// NAME.html the single file, and files.bin is Appendix C over the [web] files.
def build_case() {
    init();
    if (!fs.is_file(yc.ROOT + "/src/web/page.html")) {
        yt.skip("build --target=web writes the site", "src/web/page.html is missing");
        return;
    };
    let d = yt.tmp_dir("webbuild");
    let p = d + "/proj";
    fs.make_dirs(p);
    yt.write(p + "/y.toml", yt.read(DIR + "/w150_project/y.toml"));
    yt.write(p + "/main.y", yt.read(DIR + "/w150_project/main.y"));
    fs.make_dirs(p + "/www/sub");
    yt.write(p + "/www/a.txt", "alpha\n");
    yt.write(p + "/www/sub/b.txt", "beta\n");
    let c = yt.cmd([webcc(), "build", "--target=web", p]);
    c.cwd = yc.ROOT; c.merge = true; c.timeout = 240 * yt.SCALE; c.mem_kb = yc.PROG_MEM_KB;
    let r = yt.run(c);
    let site = p + "/build/web/w150";
    let ok = r.code == 0;
    let why = "exit=" + tostring(r.code) + " " + yt.clip(r.out, 400);
    if (ok) {
        foreach (f in ["index.html", "w150.wasm", "files.bin"]) {
            if (!fs.is_file(site + "/" + f)) { ok = false; why = "missing " + f; };
        };
        foreach (f in ["page.js", "core.js", "page.css", "package.json"]) {
            if (fs.is_file(site + "/" + f)) { ok = false; why = "unnecessary " + f; };
        };
        if (!fs.is_file(p + "/build/web/bin/w150")) { ok = false; why = "missing the launcher"; };
        if (!fs.is_file(p + "/build/web/w150.html")) { ok = false; why = "missing the single file"; };
    };
    if (ok) {
        // the launcher is a working Node entry: it runs the built module
        let lr = yt.cmd([p + "/build/web/bin/w150"]);
        lr.cwd = p;
        lr.merge = true;
        lr.timeout = 120 * yt.SCALE;
        lr.mem_kb = yc.PROG_MEM_KB;
        let viewed = yt.run(lr);
        if (viewed.code != 0 || viewed.out != "project\n") {
            ok = false;
            why = "launcher exit=" + tostring(viewed.code) + " out='" + yt.clip(viewed.out, 120) + "'";
        };
    };
    if (ok) {
        let html = yt.read(site + "/index.html");
        if (!html.contains("Bundled") || !html.contains("yweb:page.js")) { ok = false; why = "site title/host wrong"; };
        let b = yt.bytes_of(site + "/files.bin");
        let magic = from_bytes(b[0:6]);
        if (magic != "YWFS1\n") { ok = false; why = "files.bin magic is " + magic; }
        else if (len(b) < 10) { ok = false; why = "files.bin short"; }
        else {
            let n = b[6] | (b[7] << 8) | (b[8] << 16) | (b[9] << 24);
            if (n != 2) { ok = false; why = "files.bin count " + tostring(n); }
            else {
                let names: [str] = [];
                let at = 10;
                for z in 0..n {
                    let plen = b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (b[at + 3] << 24);
                    at += 4;
                    names += from_bytes(b[at:at + plen]);
                    at += plen;
                    at += 4; // mode
                    let size = 0;
                    for k in 0..8 { size += b[at + k] << (k * 8); };
                    at += 8;
                    at += size;
                };
                if (names.length != 2 || names[0] != "www/a.txt" || names[1] != "www/sub/b.txt") {
                    ok = false; why = "files.bin paths " + join(names, ",");
                };
            };
        };
    };
    if (ok) {
        let cfg = yt.read(site + "/index.html");
        if (!cfg.contains("\"env\":{\"GREETING\":\"hi\"}")) { ok = false; why = "env missing from config"; };
        if (!cfg.contains("\"files_bin\":\"files.bin\"")) { ok = false; why = "files_bin missing"; };
    };
    yt.check("build --target=web writes the site, launcher and single file", ok, why);
    fs.remove_all(d);
};

// [web] and --web use one rule: an unknown key or a bad value is fatal with
// the manifest's line, and --web overrides a single compile's page.
def manifest_case() {
    init();
    let d = yt.tmp_dir("webman");
    let p = d + "/bad";
    fs.make_dirs(p);
    yt.write(p + "/main.y", "puts(\"x\\n\");\n");
    yt.write(p + "/y.toml", "[package]\nname = \"bad\"\n[bin]\nbad = \"main.y\"\n[web]\nstart = \"maybe\"\n");
    let c1 = yt.cmd([webcc(), "build", "--target=web", p]);
    c1.cwd = yc.ROOT; c1.merge = true; c1.timeout = 120 * yt.SCALE; c1.mem_kb = yc.PROG_MEM_KB;
    let r1 = yt.run(c1);
    yt.check("[web] bad value names its line", r1.code != 0 && r1.out.contains("y.toml:6: 'start' wants"),
        "exit=" + tostring(r1.code) + " " + yt.clip(r1.out, 300));

    yt.write(p + "/y.toml", "[package]\nname = \"bad\"\n[bin]\nbad = \"main.y\"\n[web]\nnope = \"x\"\n");
    let c2 = yt.cmd([webcc(), "build", "--target=web", p]);
    c2.cwd = yc.ROOT; c2.merge = true; c2.timeout = 120 * yt.SCALE; c2.mem_kb = yc.PROG_MEM_KB;
    let r2 = yt.run(c2);
    yt.check("[web] unknown key names its line", r2.code != 0 && r2.out.contains("y.toml:6: unknown key 'nope' in [web]"),
        "exit=" + tostring(r2.code) + " " + yt.clip(r2.out, 300));

    let src = DIR + "/w100_console.y";
    let c3 = yt.cmd([webcc(), "--target=web", "--web=start=maybe", "-o", d + "/x.wasm", src]);
    c3.cwd = yc.ROOT; c3.merge = true; c3.timeout = 120 * yt.SCALE; c3.mem_kb = yc.PROG_MEM_KB;
    let r3 = yt.run(c3);
    yt.check("--web bad value is refused", r3.code != 0 && r3.out.contains("ycc: --web: 'start' wants"),
        "exit=" + tostring(r3.code) + " " + yt.clip(r3.out, 300));

    let c4 = yt.cmd([webcc(), "--target=web", "--web=nope=1", "-o", d + "/x.wasm", src]);
    c4.cwd = yc.ROOT; c4.merge = true; c4.timeout = 120 * yt.SCALE; c4.mem_kb = yc.PROG_MEM_KB;
    let r4 = yt.run(c4);
    yt.check("--web unknown key is refused", r4.code != 0 && r4.out.contains("ycc: --web: unknown key 'nope'"),
        "exit=" + tostring(r4.code) + " " + yt.clip(r4.out, 300));

    if (fs.is_file(yc.ROOT + "/src/web/page.html")) {
        let site = d + "/site";
        let c5 = yt.cmd([webcc(), "--target=web", "--web=title=Override", "--web=stack=1M",
            "--web-page", "-o", site, src]);
        c5.cwd = yc.ROOT; c5.merge = true; c5.timeout = 180 * yt.SCALE; c5.mem_kb = yc.PROG_MEM_KB;
        let r5 = yt.run(c5);
        let h = if (fs.is_file(site + "/index.html")) { yt.read(site + "/index.html") } else { "" };
        yt.check("--web overrides the page config",
            r5.code == 0 && h.contains("Override") && h.contains("\"stack\":\"1M\""),
            "exit=" + tostring(r5.code) + " " + yt.clip(r5.out + h, 300));
    } else {
        yt.skip("--web overrides the page config", "src/web/page.html is missing");
    };
    fs.remove_all(d);
};

// The [web] and page-writer messages COVERAGE.md asks a test to reach: a
// malformed table value, a missing template, an unreadable file or directory,
// and a launcher that cannot be written.
def coverage_case() {
    init();
    let d = yt.tmp_dir("webcov");
    let p = d + "/p";
    fs.make_dirs(p);
    yt.write(p + "/main.y", "puts(\"x\\n\");\n");
    let head = "[package]\nname = \"cov\"\n[bin]\ncov = \"main.y\"\n[web]\n";
    let cases = [
        ["title = { a = \"b\" }\n", "'title' must be a string or an array of strings"],
        ["env = \"x\"\n", "'env' must be an inline table of strings"],
        ["env = { A = \"x\\n\" }\n", "bad env entry 'A'"],
        ["files = [\"\"]\n", "'files' has an empty item"],
        ["template = \"nope.html\"\n", "cannot read the page template '" + p + "/nope.html'"],
        ["files = [\"missing\"]\n", "[web] files: '" + p + "/missing' is not a file or a directory"],
    ];
    let bad: [str] = [];
    foreach (c in cases) {
        yt.write(p + "/y.toml", head + c[0]);
        let r = yt.cmd([webcc(), "build", "--target=web", p]);
        r.cwd = yc.ROOT; r.merge = true; r.timeout = 120 * yt.SCALE; r.mem_kb = yc.PROG_MEM_KB;
        let o = yt.run(r);
        if (o.code == 0 || !o.out.contains(c[1])) { bad += c[0] + " -> " + yt.clip(o.out, 160); };
    };
    // a directory that cannot be opened, and a file that cannot be read
    fs.make_dirs(p + "/locked");
    fs.set_mode(p + "/locked", 0);
    yt.write(p + "/secret.txt", "s\n");
    fs.set_mode(p + "/secret.txt", 0);
    foreach (pair in [["locked", "[web] files: cannot read the directory '" + p + "/locked'"],
            ["secret.txt", "[web] files: cannot read '" + p + "/secret.txt'"]]) {
        yt.write(p + "/y.toml", head + "files = [\"" + pair[0] + "\"]\n");
        let r = yt.cmd([webcc(), "build", "--target=web", p]);
        r.cwd = yc.ROOT; r.merge = true; r.timeout = 120 * yt.SCALE; r.mem_kb = yc.PROG_MEM_KB;
        let o = yt.run(r);
        if (o.code == 0 || !o.out.contains(pair[1])) { bad += pair[0] + " -> " + yt.clip(o.out, 160); };
    };
    fs.set_mode(p + "/locked", 493);
    fs.set_mode(p + "/secret.txt", 420);
    // the launcher's directory is a file
    yt.write(p + "/y.toml", "[package]\nname = \"cov\"\n[bin]\ncov = \"main.y\"\n");
    fs.make_dirs(p + "/build/web");
    yt.write(p + "/build/web/bin", "not a directory\n");
    let r = yt.cmd([webcc(), "build", "--target=web", p]);
    r.cwd = yc.ROOT; r.merge = true; r.timeout = 120 * yt.SCALE; r.mem_kb = yc.PROG_MEM_KB;
    let o = yt.run(r);
    if (o.code == 0 || !o.out.contains("writing '" + p + "/build/web/bin/cov' failed")) {
        bad += "launcher: " + yt.clip(o.out, 160);
    };
    // no page.html from the environment
    let n = yt.cmd([webcc(), "--target=web", "--web-page", "-o", d + "/site", DIR + "/w100_console.y"]);
    n.cwd = yc.ROOT; n.merge = true; n.timeout = 120 * yt.SCALE; n.mem_kb = yc.PROG_MEM_KB;
    n.env = ["YWEB_PAGE=", "PATH=" + yt.env("PATH", "/usr/bin:/bin")];
    let no = yt.run(n);
    if (no.code == 0 || !no.out.contains("cannot find src/web/page.html to write the page")) {
        bad += "page: " + yt.clip(no.out, 160);
    };
    yt.check("the [web] and page diagnostics name their input", bad.length == 0, join(bad, " | "));
    fs.remove_all(d);
};

// The Node host and the gui virtual display have their own node:test files.
// They need no browser, so they run in this suite too.
def unit_case() {
    init();
    let bad = "";
    foreach (f in ["host.test.js", "gui.test.js"]) {
        let c = yt.cmd([NODE, "--disable-wasm-trap-handler", "--test", yc.ROOT + "/src/web/test/" + f]);
        c.cwd = yc.ROOT;
        c.merge = true;
        c.timeout = 120 * yt.SCALE;
        c.mem_kb = yc.PROG_MEM_KB;
        let r = yt.run(c);
        if (r.code != 0 || !r.out.contains("# fail 0")) { bad += f + ": " + yt.clip(r.out, 200); };
    };
    yt.check("host and gui unit tests", bad == "", bad);
};

def cases() -> [yt.Case] {
    init();
    [
        yt.case_of("web-browser", "the emitter writes the site and the single file", emit_case),
        yt.case_of("web-browser", "build --target=web writes the site", build_case),
        yt.case_of("web-browser", "the [web] and page diagnostics", coverage_case),
        yt.case_of("web-browser", "host and gui unit tests", unit_case),
        driver_case("w100_console", ["ytest title/pre are written", "stdout reaches the console and the test output", "the console panel shows stdout"]),
        driver_case("w101_persist", ["persistence: the second run reads the file"]),
        driver_case("w102_feature_check", ["the feature check names the tail-call requirement"]),
        driver_case("w103_pause_hidden", ["pause_hidden: CLOCK_MONOTONIC excludes the hidden 700 ms", "pause_hidden: the page really was paused for most of a second"]),
        driver_case("w110_canvas", ["w110_canvas: the canvas matches the program's read_back checksum", "w110_canvas: every presented pixel is opaque", "w110_canvas: red, green and blue reach the right channels", "w110_canvas: the program reports verify_present", "w110_canvas: fixed zoom scales the CSS size", "w110_canvas: fit mode sizes the canvas from the stage"]),
        driver_case("w111_input", ["w111_input: the program opened its canvas window", "w111_input: synthetic events match the native golden", "w111_input: the preventDefault list and the context menu"]),
        driver_case("w112_resize", ["w112_resize: fit mode delivers EV_RESIZE"]),
        driver_case("w112_audio", ["w112_audio: the browser sink is available and the program wrote to it", "w112_audio: the AudioContext reaches running", "w112_audio: consumed-frame reports arrive", "w112_audio: the page audio is non-silent", "w112_audio: the first gesture hook runs and resumes", "w112_audio: the page can mute the gain"]),
        driver_case("w113_fetch", ["w113_fetch: fetch of a sibling file crosses the page", "w113_fetch: param, eval and open_url"])
    ]
};


