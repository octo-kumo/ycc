// su_coverage.y -- "every feature has a test", as a checkable claim
// (test/COVERAGE.md). Static: it reads the sources, the manual and the tests,
// and compiles nothing. Four checks, each a list of things that must be tested:
//
//  1. diagnostics: every message a diagnostic site in the compiler can print has
//     its text in a test expectation -- an e*.y `// expect-error:` or t*.y
//     `// expect-warning:` marker, an inline case of a ytest suite, or a
//     *.expected file. A site's message is a TEMPLATE: its constant text with a
//     hole where a name or a type goes (`"cannot read field '" + k + "' of " +
//     tstr(t)` is "cannot read field '*' of"), and a test covers the site when
//     one of its lines holds the whole template, the holes matching anything.
//     Sites with no constant text, and messages no test can reach, are excused
//     by a row of COVERAGE.md's "Untested diagnostics"; an excuse that excuses
//     nothing is stale and fails.
//  2. builtins: every builtin and string method in docs/src/09-builtins.tex is
//     called by a test whose output is checked.
//  3. keywords: every keyword the lexer knows appears in a t*.y program.
//  4. matrix: COVERAGE.md has a row for every (sub)section of the manual, and
//     every test a row names exists and checks its output.
//
//   ytest coverage-list    every diagnostic site and its status (tested,
//                          excused, untested, dynamic, stale)
import fs;
import yt;
import yc;
import vocabulary from "../../y/language_schema.y";

let HOLE = "\x01";

def is_alpha(c: long) -> bool { (c >= 97 && c <= 122) || (c >= 65 && c <= 90) };

def is_word(c: long) -> bool { is_alpha(c) || (c >= 48 && c <= 57) || c == 95 };

// The text after `marker` on each line holding it.
def marked(files: [str], marker: str) -> [str] {
    let r: [str] = [];
    foreach (f in files) {
        foreach (l in yt.read(f).split("\n")) {
            let i = l.index_of(marker);
            if (i >= 0) { r += l[i + marker.length:]; };
        };
    };
    r
};

// The rows of COVERAGE.md's table under "## heading", as trimmed cells.
def matrix_rows(heading: str) -> [[str]] {
    let rows: [[str]] = [];
    let on = false;
    let header = true;
    foreach (l in yt.read(yc.ROOT + "/test/COVERAGE.md").split("\n")) {
        if (l.starts_with("## ")) {
            on = l == "## " + heading;
            header = true;
        } else if (on && l.starts_with("|")) {
            let rule = true;
            foreach (c in bytes(l)) {
                if (c != 124 && c != 45 && c != 32) { rule = false; };
            };
            if (!rule) {
                // the cells between the first and the last bar (split drops the
                // empty field after a final bar)
                let cells = l.split("|");
                let last = if (l.ends_with("|")) { cells.length } else { cells.length - 1 };
                let r: [str] = [];
                for i in 1..last { r += cells[i].trim(); };
                if (header) { header = false; } else { rows += [r]; };
            };
        };
    };
    rows
};

// ── 1. diagnostics ──────────────────────────────────────────────────────

// The template of the Y expression starting at s[i]: its top-level string
// literal operands (unescaped) with every other operand a HOLE. It ends at a
// top-level , ; ) ] } or a comment.
def tmpl(s: str, start: long) -> str {
    let n = s.length;
    let i = start;
    let depth = 0;
    let out = "";
    let lit = "";
    let havelit = false;
    let other = false;
    let go = true;
    while (go && i < n) {
        let c = s[i];
        if (c == 34) {
            let here: [byte] = [];
            i += 1;
            let inlit = true;
            while (inlit && i < n) {
                let d = s[i];
                if (d == 92) {
                    let e = if (i + 1 < n) { s.byte_at(i + 1) } else { 0 };
                    here += if (e == 110) { 10 } else if (e == 116) { 9 } else { e };
                    i += 2;
                } else if (d == 34) {
                    i += 1;
                    inlit = false;
                } else {
                    here += d;
                    i += 1;
                };
            };
            if (depth == 0 && !havelit && !other) {
                lit = from_bytes(here);
                havelit = true;
            } else {
                other = true;
            };
        } else if (c == 47 && i + 1 < n && s[i + 1] == 47) {
            go = false;
        } else if (depth == 0 && (c == 44 || c == 59 || c == 41 || c == 93 || c == 125)) {
            go = false;
        } else {
            if (c == 40 || c == 91 || c == 123) { depth += 1; }
            else if (c == 41 || c == 93 || c == 125) { depth -= 1; };
            if (depth == 0 && c == 43) {
                let piece = if (havelit && !other) { lit } else { HOLE };
                out += piece;
                lit = "";
                havelit = false;
                other = false;
            } else if (c != 32 && c != 9) {
                other = true;
            };
            i += 1;
        };
    };
    out + (if (havelit && !other) { lit } else { HOLE })
};

// Start of the k-th top-level argument of the first call name(...) in s.
def callarg(s: str, name: str, k: long) -> long {
    let i = s.index_of(name + "(") + name.length + 1;
    let n = s.length;
    let depth = 0;
    let ins = false;
    let left = k;
    while (i < n && left > 1) {
        let c = s[i];
        if (ins) {
            if (c == 92) { i += 1; } else if (c == 34) { ins = false; };
        } else if (c == 34) { ins = true; }
        else if (c == 40 || c == 91 || c == 123) { depth += 1; }
        else if (c == 41 || c == 93 || c == 125) { depth -= 1; }
        else if (c == 44 && depth == 0) { left -= 1; };
        i += 1;
    };
    i
};

def is_blankish(c: long) -> bool { c == 32 || c == 9 || c == 1 };

// No "error: "/"ycc: " lead, newlines as holes, no outer holes or blanks, no
// doubled holes.
def norm(t0: str) -> str {
    let t = t0;
    if (t.starts_with("error: ")) { t = t[7:]; } else if (t.starts_with("ycc: ")) { t = t[5:]; };
    t = t.replace("\n", HOLE);
    let o: [byte] = [];
    let i = 0;
    while (i < t.length) {
        if (t[i] == 1) {
            let j = i;
            let last = i;
            while (j < t.length && is_blankish(t[j])) {
                if (t[j] == 1) { last = j; };
                j += 1;
            };
            o += 1;
            if (last > i) {
                i = last + 1;
            } else {
                i += 1;
            };
        } else {
            o += t[i];
            i += 1;
        };
    };
    let r = from_bytes(o);
    let a = 0;
    let b = r.length;
    while (a < b && is_blankish(r[a])) { a += 1; };
    while (b > a && is_blankish(r[b - 1])) { b -= 1; };
    r[a:b]
};

// Do the parts appear in the line, in order?
def in_order(line: str, parts: [str]) -> bool {
    let at = 0;
    foreach (p in parts) {
        let i = line.index_of(p, at);
        if (i < 0) { return false; };
        at = i + p.length;
    };
    true
};

/** The scan's state: the expectation corpus, the excuses and which are used. */
type Diag = { corp: [str], exf: [str], exc: [str], used: [bool], out: [str] };

def site(d: Diag, f: str, ln: long, line: str, t0: str) {
    if (t0 == "") { return; };
    let code = line.trim_start();
    let t = norm(t0);
    let txt = t.replace(HOLE, "*");
    let letters = 0;
    foreach (c in bytes(t)) {
        if (is_alpha(c)) { letters += 1; };
    };
    let where = f + ":" + tostring(ln);
    if (letters < 6) {
        for k in 0..d.exf.length {
            if (d.exf[k] == f && code.contains(d.exc[k])) {
                d.used[k] = true;
                d.out += "excused\t" + where + "\t" + code;
                return;
            };
        };
        d.out += "dynamic\t" + where + "\t" + code;
        return;
    };
    let parts = t.split(HOLE);
    let longest = "";
    foreach (p in parts) {
        if (p.length > longest.length) { longest = p; };
    };
    foreach (c in d.corp) {
        if (c.contains(longest) && in_order(c, parts)) {
            d.out += "tested\t" + where + "\t" + txt;
            return;
        };
    };
    for k in 0..d.exf.length {
        if (d.exf[k] == f && code.contains(d.exc[k])) {
            d.used[k] = true;
            d.out += "excused\t" + where + "\t" + txt;
            return;
        };
    };
    d.out += "untested\t" + where + "\t" + txt;
};

def lint_warn_at(l: str) -> bool {
    foreach (p in ["lint_warn(st, ", "lint_warn_at(st, ", "lint_warn_start(st, "]) {
        let i = l.index_of(p);
        if (i >= 0) {
            let rest = l[i + p.length:];
            let q = rest.index_of("\"");
            let c = rest.index_of(",");
            if (q >= 0 && (c < 0 || q < c)) { return true; };
        };
    };
    false
};

// `expect_err(toks, NAME, "` with NAME [a-z_]+
def expect_err_lit(l: str) -> bool {
    let i = l.index_of("expect_err(toks, ");
    if (i < 0) { return false; };
    let j = i + 17;
    let k = j;
    while (k < l.length && ((l[k] >= 97 && l[k] <= 122) || l[k] == 95)) { k += 1; };
    k > j && l[k:].starts_with(", \"")
};

def scan_file(d: Diag, path: str) {
    let f = path[(yc.ROOT + "/src/y/").length:];
    let infmt = false;
    let ln = 0;
    foreach (l in yt.read(path).split("\n")) {
        ln += 1;
        if (l.starts_with("def ")) { infmt = f == "types.y" && l.starts_with("def fmt_check("); };
        let lead = 0;
        while (lead < l.length && l[lead] == 32) { lead += 1; };
        if (!l[lead:].starts_with("//")) {
            let re = l.index_of("runtime error: ");
            let is_def = l.starts_with("def ");
            if (re >= 0) {
                let s = l[re:];
                let b = s.index_of("\\");
                if (b >= 0) { s = s[0:b]; };
                let q = s.index_of("\"");
                if (q >= 0) { s = s[0:q]; };
                site(d, f, ln, l, s);
            } else if (f == "lexer.y" && l.contains("puts(\"error: ")) { site(d, f, ln, l, tmpl(l, l.index_of("puts(") + 5)); }
            else if (f == "lexer.y" && l.contains("err = \"")) { site(d, f, ln, l, tmpl(l, l.index_of("err = ") + 6)); }
            else if (f == "parser.y" && (l.contains("k: K.err, msg: ") || l.contains("k: K.terr, msg: "))) {
                site(d, f, ln, l, tmpl(l, l.index_of("msg: ") + 5));
            } else if (f == "parser.y" && expect_err_lit(l) && !is_def) {
                site(d, f, ln, l, "expected " + tmpl(l, callarg(l, "expect_err", 3)) + ", got");
            } else if (f == "rename.y" && l.contains("k: K.err, msg: ")) { site(d, f, ln, l, tmpl(l, l.index_of("msg: ") + 5)); }
            else if (f == "types.y" && l.contains("fail(st, ") && !is_def) { site(d, f, ln, l, tmpl(l, l.index_of("fail(st, ") + 9)); }
            else if (f == "types.y" && l.contains("expect_type(") && !is_def) {
                site(d, f, ln, l, tmpl(l, callarg(l, "expect_type", 4)) + ": expected " + HOLE + ", got");
            } else if (f == "types.y" && l.contains("expect_arg(") && !is_def) {
                site(d, f, ln, l, tmpl(l, callarg(l, "expect_arg", 5)) + ": expected " + HOLE + ", got");
            } else if (f == "types.y" && l.contains("err = \"")) { site(d, f, ln, l, tmpl(l, l.index_of("= \"") + 2)); }
            else if (f == "types.y" && infmt && l.contains("{ \"")) { site(d, f, ln, l, tmpl(l, l.index_of("{ \"") + 2)); }
            else if (f == "types.y" && infmt && l[lead:].starts_with("\"")) { site(d, f, ln, l, tmpl(l, l.index_of("\""))); }
            else if (f == "native.y" && l.contains("puts(\"error: ")) { site(d, f, ln, l, tmpl(l, l.index_of("puts(") + 5)); }
            else if (f == "native.y" && l.contains("{ msg: \"") && !l.contains("{ msg: \"\"")) {
                site(d, f, ln, l, tmpl(l, l.index_of("msg: ") + 5));
            } else if (f == "ycc.y" && (l.contains("puts(\"error: ") || l.contains("puts(\"ycc: "))) {
                site(d, f, ln, l, tmpl(l, l.index_of("puts(") + 5));
            } else if (f == "pkg.y" && l.contains("pk_die(") && !is_def) { site(d, f, ln, l, tmpl(l, l.index_of("pk_die(") + 7)); }
            else if (f == "lint.y" && lint_warn_at(l)) { site(d, f, ln, l, tmpl(l, l.index_of("(st, ") + 5)); }
            else if (f == "lint.y" && l.contains("msg = ") && l[l.index_of("msg = "):].contains("\"")) {
                site(d, f, ln, l, tmpl(l, l.index_of("msg = ") + 6));
            } else if (f == "asm.y" && l.contains("state_err(") && l[l.index_of("state_err("):].contains("\"")) {
                site(d, f, ln, l, tmpl(l, l.index_of("\"")));
            } else if (f == "enc64.y" && l.contains("enc_err(at, \"")) { site(d, f, ln, l, tmpl(l, l.index_of("enc_err(at, \"") + 13)); };
        };
    };
};

// Every line a test asserts.
def expectations() -> [str] {
    let nat = yc.ROOT + "/test/y/native";
    let corp = marked(yt.files(nat, "e", ".y"), "// expect-error: ");
    corp += marked(yt.files(nat, "t", ".y"), "// expect-warning: ");
    // the kernel suite's rejections: the only tests some kernel diagnostics have
    corp += marked(yt.files(yc.ROOT + "/test/kernel", "e", ".y") + yt.files(yc.ROOT + "/test/kernel", "h", ".y"), "// expect-error: ");
    // the suites' own inline cases, as written and with their escapes undone
    foreach (f in yt.files(yc.ROOT + "/src/tools/ytest", "", ".y")) {
        if (!f.ends_with("/su_coverage.y")) {
            foreach (l in yt.read(f).split("\n")) {
                corp += l;
                if (l.contains("\\")) { corp += l.replace("\\\"", "\"").replace("\\\\", "\\"); };
            };
        };
    };
    foreach (f in yt.tree(yc.ROOT + "/test/y", ".expected")) { corp += yt.read(f).split("\n"); };
    corp
};

def diagnostics() -> Diag {
    let d: Diag = { corp: expectations(), exf: [], exc: [], used: [], out: [] };
    foreach (r in matrix_rows("Untested diagnostics")) {
        if (r.length >= 2 && r[1] != "") {
            let src = r[0].replace("`", "");
            if (src.starts_with("src/y/")) { src = src[6:]; };
            d.exf += src;
            d.exc += r[1].replace("`", "");
            d.used += false;
        };
    };
    let y = yc.ROOT + "/src/y/";
    foreach (n in ["lexer", "parser", "rename", "types", "native", "ycc", "pkg", "lint", "meta", "arch_x64", "tags", "labels",
                   "ir", "elf", "pe", "target", "asm", "enc64", "dwarf", "obfuscate", "seal", "obf_vm"]) {
        scan_file(d, y + n + ".y");
    };
    foreach (f in yt.files(y + "std", "", ".y")) { scan_file(d, f); };
    for k in 0..d.exf.length {
        if (!d.used[k]) { d.out += "stale\t" + d.exf[k] + "\t" + d.exc[k]; };
    };
    d
};

def check_diagnostics() {
    let d = diagnostics();
    let nsites = 0;
    let miss = 0;
    foreach (l in d.out) {
        let w = l.split("\t");
        if (w[0] != "stale") { nsites += 1; };
        if (w[0] == "untested") {
            miss += 1;
            yt.fail("diagnostic " + w[1] + " untested", w[2]);
        } else if (w[0] == "dynamic") {
            miss += 1;
            yt.fail("diagnostic " + w[1] + " has no constant text (excuse it in COVERAGE.md by a fragment of its code)", w[2]);
        } else if (w[0] == "stale") {
            miss += 1;
            yt.fail("COVERAGE.md excuses '" + w[2] + "' in " + w[1] + ", but no untested site has it", "");
        };
    };
    if (miss == 0) { yt.pass("diagnostics: all " + tostring(nsites) + " sites tested or excused"); };
};

// ── 2. builtins ─────────────────────────────────────────────────────────

// \ic{NAME( and \ic{X.NAME( in the description lists of 09-builtins.tex;
// a method as ".NAME".
def builtins() -> [str] {
    let r: [str] = [];
    let on = false;
    foreach (l in yt.read(yc.ROOT + "/docs/src/09-builtins.tex").split("\n")) {
        if (l.contains("\\begin{description}")) { on = true; };
        if (on) {
            let i = l.index_of("\\ic{");
            while (i >= 0) {
                let j = i + 4;
                let a = j;
                while (j < l.length && l[j] >= 97 && l[j] <= 122) { j += 1; };
                let pre = l[a:j];
                let dot = j < l.length && l[j] == 46;
                if (dot) { j += 1; };
                let b = j;
                while (j < l.length && ((l[j] >= 97 && l[j] <= 122) || l[j] == 92 || l[j] == 95)) { j += 1; };
                if (j < l.length && l[j] == 40) {
                    let name = ((if (dot) { "." } else { pre }) + l[b:j]).replace("\\_", "_");
                    if (name != "" && !(name in r)) { r += name; };
                };
                i = l.index_of("\\ic{", i + 4);
            };
        };
        if (l.contains("\\end{description}")) { on = false; };
    };
    r
};

def called(text: [str], b: str) -> bool {
    foreach (l in text) {
        let i = l.index_of(b + "(");
        while (i >= 0) {
            if (b.starts_with(".") || i == 0 || !(is_word(l[i - 1]) || l[i - 1] == 46)) { return true; };
            i = l.index_of(b + "(", i + 1);
        };
    };
    false
};

def check_builtins() {
    let text: [str] = [];
    foreach (f in yt.files(yc.ROOT + "/test/y/native", "t", ".y") + yt.files(yc.ROOT + "/test/math", "", ".y")
                  + yt.files(yc.ROOT + "/src/tools/ytest", "su_", ".y")) {
        if (!f.ends_with("/su_coverage.y")) { text += yt.read(f).split("\n"); };
    };
    let bs = builtins();
    let miss = 0;
    foreach (b in bs) {
        if (!called(text, b)) {
            miss += 1;
            yt.fail("builtin " + b + " is never called by a checked test", "");
        };
    };
    if (miss == 0) { yt.pass("builtins: all " + tostring(bs.length) + " documented builtins and methods called"); };
};

// ── 3. keywords ─────────────────────────────────────────────────────────

def check_keywords() {
    let kws = vocabulary.RESERVED_WORDS;
    let all = "";
    foreach (f in yt.files(yc.ROOT + "/test/y/native", "t", ".y")) { all += yt.read(f) + "\n"; };
    let miss = 0;
    foreach (k in kws) {
        let found = false;
        let i = all.index_of(k);
        while (!found && i >= 0) {
            let e = i + k.length;
            if ((i == 0 || !is_word(all[i - 1])) && (e >= all.length || !is_word(all[e]))) { found = true; };
            i = all.index_of(k, i + 1);
        };
        if (!found) {
            miss += 1;
            yt.fail("keyword '" + k + "' appears in no t*.y program", "");
        };
    };
    if (miss == 0) { yt.pass("keywords: all " + tostring(kws.length) + " used"); };
};

// ── 4. the matrix ───────────────────────────────────────────────────────

// Every \section/\subsection title of docs/src/NN-*.tex, as [doc, title].
def sections() -> [[str]] {
    let r: [[str]] = [];
    foreach (t in yt.files(yc.ROOT + "/docs/src", "", ".tex")) {
        let doc = fs.path_stem(t);
        if (doc[0] >= 48 && doc[0] <= 57) {
            foreach (l in yt.read(t).split("\n")) {
                let s = "";
                foreach (p in ["\\section{", "\\section*{", "\\subsection{", "\\subsection*{"]) {
                    if (s == "" && l.starts_with(p)) { s = l[p.length:]; };
                };
                if (s != "") {
                    let e = s.last_index_of("}");
                    if (e >= 0) { s = s[0:e]; };
                    r += [[doc, s.replace("\\ic{", "").replace("}", "").replace("\\", "")]];
                };
            };
        };
    };
    r
};

// Is `ref` a test that checks its output?
def checked_ref(ref: str) -> bool {
    let root = yc.ROOT;
    if (ref.starts_with("comprehensive: ") || ref.starts_with("loops: ")) {
        let name = ref[ref.index_of(": ") + 2:];
        return yt.read(root + "/src/tools/ytest/su_inline.y").contains("[\"" + name);
    };
    if (ref.starts_with("ytest/") && ref.ends_with(".y")) { return fs.is_file(root + "/src/tools/" + ref); };
    if (ref.starts_with("native/t") && ref.ends_with(".y")) {
        return fs.is_file(root + "/test/y/" + ref) && fs.is_file(root + "/test/y/" + ref[0:ref.length - 2] + ".expected");
    };
    if (ref.starts_with("native/e") && ref.ends_with(".y")) { return fs.is_file(root + "/test/y/" + ref); };
    // the language server's fixtures are checked like a native one (su_lsp.y)
    if (ref.starts_with("lsp/test/t") && ref.ends_with(".y")) {
        return fs.is_file(root + "/src/tools/" + ref) && fs.is_file(root + "/src/tools/" + ref[0:ref.length - 2] + ".expected");
    };
    // the node drivers run under ytest lsp-e2e, against the built server
    if (ref.starts_with("lsp/test/") && ref.ends_with("-check.js")) {
        return fs.is_file(root + "/src/tools/" + ref) && yt.read(root + "/src/tools/ytest/lsp_e2e.y").contains(fs.path_basename(ref));
    };
    false
};

def check_matrix() {
    let rows = matrix_rows("Features");
    let secs = sections();
    let miss = 0;
    foreach (s in secs) {
        let found = false;
        foreach (r in rows) {
            if (r.length >= 2 && r[0] == s[0] && r[1] == s[1]) { found = true; };
        };
        if (!found) {
            miss += 1;
            yt.fail("manual section " + s[0] + " '" + s[1] + "' has no row in test/COVERAGE.md", "");
        };
    };
    if (miss == 0) { yt.pass("matrix: all " + tostring(secs.length) + " manual sections have rows"); };
    let nref = 0;
    miss = 0;
    foreach (r in rows) {
        let tests = if (r.length >= 4) { r[3] } else { "" };
        if (tests == "") {
            miss += 1;
            yt.fail("matrix row " + r[0] + " '" + r[1] + "' / '" + (if (r.length > 2) { r[2] } else { "" }) + "' names no test", "");
        } else if (!(tests.starts_with("none: ") && tests.length >= 16)) {
            let parts = tests.split("`");
            let k = 1;
            while (k < parts.length) {
                nref += 1;
                if (!checked_ref(parts[k])) {
                    miss += 1;
                    yt.fail("matrix row " + r[0] + " '" + r[1] + "' / '" + r[2] + "': '" + parts[k] + "' is not a checked test", "");
                };
                k += 2;
            };
        };
    };
    if (miss == 0) { yt.pass("matrix: all " + tostring(nref) + " test references exist"); };
};

def cases() -> [yt.Case] {
    let s = "coverage";
    [yt.case_of(s, "diagnostics", check_diagnostics), yt.case_of(s, "builtins", check_builtins),
     yt.case_of(s, "keywords", check_keywords), yt.case_of(s, "matrix", check_matrix)]
};

def main_list(av: [str]) -> long {
    foreach (l in diagnostics().out) { print(l.replace(HOLE, "*")); };
    0
};

export { cases, main_list };
