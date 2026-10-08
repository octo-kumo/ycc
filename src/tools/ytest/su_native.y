// su_native.y -- test/y/native: the fixtures, compiled by the built ycc.
//
// t*.y: stdout must match t*.expected, the exit t*.exit (default 0); stdin is
//   t*.stdin when present. The compile's warnings must be exactly the file's
//   `// expect-warning: MSG` markers, each on its own line (a line drawing two
//   carries two). A `// flags: ...` line adds compiler flags; a `// scratch`
//   line runs the program in a scratch directory of its own.
// e*.y: ycc must FAIL, and its output must hold the text of EVERY
//   `// expect-error: ...` line. They compile from test/y/native itself, so a
//   message naming an imported file reads the same on every machine.
import fs;
import yt;
import yc;

let DIR = "";

// The texts after `marker` on each line, with their line numbers ("N:text").
def markers(src: str, marker: str) -> [str] {
    let r: [str] = [];
    let ln = 0;
    foreach (line in src.split("\n")) {
        ln += 1;
        let s = line;
        let i = s.index_of(marker);
        while (i >= 0) {
            s = s[i + marker.length:];
            let j = s.index_of(" " + marker);
            if (j >= 0) {
                r += tostring(ln) + ":" + s[0:j];
                s = s[j + 1:];
                i = 0;
            } else {
                r += tostring(ln) + ":" + s;
                i = -1;
            };
        };
    };
    r
};

def negative(file: str, base: str) {
    let wants: [str] = [];
    foreach (line in yt.read(file).split("\n")) {
        let i = line.index_of("// expect-error: ");
        if (i >= 0) { wants += line[i + 17:]; };
    };
    if (wants.length == 0) {
        yt.fail(base, "no // expect-error: marker");
        return;
    };
    let bin = yt.tmp("bin");
    let c = yt.cmd([yc.YCC, "-o", bin, base + ".y"]);
    c.cwd = DIR;
    c.merge = true;
    c.timeout = 120 * yt.SCALE;
    let r = yt.run(c);
    fs.remove_file(bin);
    if (r.code == 0) {
        yt.fail(base, "compilation succeeded, expected error: " + wants[0]);
        return;
    };
    foreach (w in wants) {
        if (!r.out.contains(w)) {
            yt.fail(base, "wrong error (want '" + w + "', got: " + yt.clip(r.out, 400) + ")");
            return;
        };
    };
    let more = if (wants.length > 1) { ", +" + tostring(wants.length - 1) + " more" } else { "" };
    yt.pass(base + " (rejected: " + wants[0] + more + ")");
};

def positive(file: str, base: str) {
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
    let bin = yt.tmp("bin");
    let r = yc.compile(yc.YCC, flags, file, bin, 120);
    if (r.code != 0) {
        yt.fail(base, "compile failed: " + yt.clip(r.out, 200));
        fs.remove_file(bin);
        return;
    };
    if (!fs.is_file(bin)) {
        yt.fail(base, "output is not executable");
        return;
    };
    // the warnings ("LINE:COL: warning: MSG") against the markers ("LINE:MSG")
    let warns: [str] = [];
    foreach (l in yt.lines(r.out)) {
        if (l.contains(": warning: ")) { warns += l; };
    };
    let marks = markers(src, "// expect-warning: ");
    foreach (m in marks) {
        let k = m.index_of(":");
        let at = m[0:k + 1];
        let msg = m[k + 1:];
        let found = false;
        foreach (w in warns) {
            if (w.contains(msg) && w.starts_with(at)) { found = true; };
        };
        if (!found) {
            yt.fail(base, "no warning '" + msg + "' on line " + m[0:k] + " (got: " + yt.clip(join(warns, "\n"), 300) + ")");
            fs.remove_file(bin);
            return;
        };
    };
    if (warns.length != marks.length) {
        yt.fail(base, "unmarked warnings (got: " + yt.clip(join(warns, "\n"), 300) + ")");
        fs.remove_file(bin);
        return;
    };
    let stdin = DIR + "/" + base + ".stdin";
    let c = yt.cmd([bin]);
    c.stdin = if (fs.is_file(stdin)) { stdin } else { "" };
    c.merge = true;
    c.timeout = 10;
    c.mem_kb = yc.PROG_MEM_KB;
    let rundir = if (scratch) { yt.tmp_dir("run") } else { "" };
    c.cwd = rundir;
    let o = yt.run(c);
    fs.remove_file(bin);
    let want_ec = yt.num(yt.read(DIR + "/" + base + ".exit").trim(), 0);
    let want = fs.read_file(DIR + "/" + base + ".expected");
    if (base == "t10_filewrite") {
        let got = yt.read(rundir + "/ynative_test.txt");
        let wf = yt.read(DIR + "/" + base + ".file");
        if (got != wf) {
            yt.fail(base, "output file mismatch (want '" + yt.clip(wf, 200) + "', got '" + yt.clip(got, 200) + "')");
            fs.remove_all(rundir);
            return;
        };
    };
    if (rundir != "") { fs.remove_all(rundir); };
    let same = want != none && want! == o.out;
    if (o.code == want_ec && same) {
        yt.pass(base);
    } else {
        yt.fail(base, "exit=" + tostring(o.code) + " (want " + tostring(want_ec) + "), diff: " + yt.first_diff(if (want == none) { "" } else { want! }, o.out));
    };
};

def cases() -> [yt.Case] {
    DIR = yc.ROOT + "/test/y/native";
    let cs: [yt.Case] = [];
    foreach (f in yt.files(DIR, "t", ".y") + yt.files(DIR, "e", ".y")) {
        let base = fs.path_stem(f);
        if (base.starts_with("e")) {
            cs += yt.case_of("native", base, () => negative(f, base));
        } else {
            cs += yt.case_of("native", base, () => positive(f, base));
        };
    };
    cs
};

export { cases, markers };
