// su_lsp.y -- the language server's own checks (LSP.md, src/tools/lsp/).
//
//   refs       every symbol LSP.md cites (`types.check_program`) is defined
//              where it says, and every file:line citation lands on a line
//              that exists and is not blank. LSP.md names symbols rather than
//              line numbers because src/y moves by hundreds of lines an edit.
//   names      no two path-imported modules define one name: a path import
//              FLATTENS into one namespace, so a shared name is a duplicate
//              definition reported against the wrong file or, worse, one
//              definition silently shadowing the other (`type Tok` once
//              shadowed lexer.y's and made 60 errors inside the compiler). And
//              no module BASENAME is dot-accessed in the compiler: strip_ns
//              rewrites every `x.field` as a module reference (`index.y` once
//              broke 42 reads in types.y).
//   fixtures   tNNN_*.y, compiled by both compilers without a warning, run, and
//              compared with its .expected (minus yserve's own lifecycle lines).
//   format     the formatter is idempotent over every .y in the tree, and how
//              near src/y is to its fixed point (a signal, not a gate).
//
//   ytest check-refs [-v]    ytest check-names    run one of the two by hand
import fs;
import yt;
import yc;

let LSP = "";

// ── refs ────────────────────────────────────────────────────────────────

let MODULES = ["lexer", "parser", "types", "rename", "lint", "native", "asm", "elf", "arch_x64", "enc64", "dwarf", "pkg", "tags"];
// `lexer.y` is a filename, not `lexer` + a symbol called `y`
let NOT_A_SYMBOL = ["y", "c", "h", "s", "md", "sh", "tex", "pack", "ref"];

def is_word(c: long) -> bool {
    (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || c == 95
};

def is_lw(c: long) -> bool { (c >= 97 && c <= 122) || c == 95 };

def is_lwd(c: long) -> bool { is_lw(c) || (c >= 48 && c <= 57) };

// The names a module defines at the start of a line (def/type/let/const NAME).
def definitions(file: str) -> [str] {
    let r: [str] = [];
    foreach (l in yt.read(file).split("\n")) {
        foreach (k in ["def ", "type ", "let ", "const "]) {
            if (l.starts_with(k)) {
                let i = k.length;
                let j = i;
                while (j < l.length && is_lwd(l[j])) { j += 1; };
                if (j > i && is_lw(l[i])) { r += l[i:j]; };
            };
        };
    };
    r
};

// The text without ``` fences.
def unfence(s: str) -> str {
    let out = "";
    let i = 0;
    while (i < s.length) {
        let a = s.index_of("```", i);
        if (a < 0) {
            out += s[i:];
            i = s.length;
        } else {
            let b = s.index_of("```", a + 3);
            out += s[i:a];
            i = if (b < 0) { s.length } else { b + 3 };
            if (b < 0) { out += s[a:]; };
        };
    };
    out
};

// A citation at s[i] (path, line, last line): [path, lo, hi] or [] when none.
// The path is `(src/|docs/|test/|bench/|tools/)?name(/seg)*.ext`, ext the
// first of y c h s tex md sh that the text starts with.
def cite_at(s: str, i: long) -> [str] {
    let j = i;
    foreach (p in ["src/", "docs/", "test/", "bench/", "tools/"]) {
        if (j == i && at(s, i, p)) { j = i + p.length; };
    };
    let r = cite_rest(s, i, j);
    if (r.length == 0 && j != i) { r = cite_rest(s, i, i); };
    r
};

def cite_rest(s: str, i: long, from: long) -> [str] {
    let j = from;
    if (j >= s.length || !is_lw(s[j])) { return []; };
    while (j < s.length && is_lwd(s[j])) { j += 1; };
    while (j + 1 < s.length && s[j] == 47 && is_lwd(s[j + 1])) {
        j += 1;
        while (j < s.length && is_lwd(s[j])) { j += 1; };
    };
    if (j >= s.length || s[j] != 46) { return []; };
    let ext = "";
    foreach (e in ["y", "c", "h", "s", "tex", "md", "sh"]) {
        if (ext == "" && at(s, j + 1, e)) { ext = e; };
    };
    if (ext == "") { return []; };
    let end = j + 1 + ext.length;
    let path = s[i:end];
    let lo = "";
    let hi = "";
    if (end < s.length && s[end] == 58) {
        let k = end + 1;
        while (k < s.length && s[k] >= 48 && s[k] <= 57) { k += 1; };
        if (k > end + 1) {
            lo = s[end + 1:k];
            end = k;
            if (end < s.length && s[end] == 45) {
                let m = end + 1;
                while (m < s.length && s[m] >= 48 && s[m] <= 57) { m += 1; };
                if (m > end + 1) {
                    hi = s[end + 1:m];
                    end = m;
                };
            };
        };
    };
    [path, lo, hi, tostring(end)]
};

// Does s hold p at i?
def at(s: str, i: long, p: str) -> bool { i + p.length <= s.length && s[i:i + p.length] == p };

def has(xs: [str], x: str) -> bool {
    foreach (e in xs) {
        if (e == x) { return true; };
    };
    false
};

/** check-refs: the report, and in ok[0] whether everything resolved. */
def refs(verbose: bool, ok: [bool]) -> str {
    let out: [str] = [];
    let text = unfence(yt.read(LSP + "/LSP.md"));
    let fails: [str] = [];
    let defs: {str => [str]} = {};
    foreach (m in MODULES) {
        let f = yc.ROOT + "/src/y/" + m + ".y";
        if (fs.is_file(f)) { defs[m] = definitions(f); };
    };
    let total = 0;
    let good = 0;
    let seen: [str] = [];
    let i = 0;
    while (i < text.length) {
        let next = i + 1;
        if (is_lw(text[i]) && (i == 0 || !is_word(text[i - 1]))) {
            foreach (m in MODULES) {
                let k = i + m.length;
                if (next == i + 1 && at(text, i, m) && k + 1 < text.length && text[k] == 46 && is_lw(text[k + 1])) {
                    let e = k + 1;
                    while (e < text.length && is_lwd(text[e])) { e += 1; };
                    next = e;
                    let sym = text[k + 1:e];
                    let key = m + "." + sym;
                    if (!has(NOT_A_SYMBOL, sym) && !has(seen, key) && m in defs) {
                        seen += key;
                        total += 1;
                        if (has(defs[m]!, sym)) {
                            good += 1;
                            if (verbose) { out += "  sym   " + key; };
                        } else {
                            fails += key + ": no `def`/`type`/`let` '" + sym + "' in src/y/" + m + ".y";
                        };
                    };
                };
            };
        };
        i = next;
    };
    out += "symbol references : " + tostring(good) + "/" + tostring(total) + " resolved";
    total = 0;
    good = 0;
    i = 0;
    while (i < text.length) {
        let c = if (i == 0 || !(is_word(text[i - 1]) || text[i - 1] == 47)) { cite_at(text, i) } else { [] };
        if (c.length == 0) {
            i += 1;
        } else {
            i = yt.num(c[3], i + 1);
            let real = "";
            foreach (cand in [c[0], "src/y/" + c[0], "src/c/" + c[0]]) {
                if (real == "" && fs.is_file(yc.ROOT + "/" + cand)) { real = cand; };
            };
            if (real != "" && c[1] != "") {
                total += 1;
                let lines = yt.read(yc.ROOT + "/" + real).split("\n");
                if (lines.length > 0 && lines[lines.length - 1] == "") { lines = lines[0:lines.length - 1]; };
                let n = lines.length;
                let lo = yt.num(c[1], 0);
                let hi = yt.num(c[2], 0);
                let where = c[0] + ":" + c[1] + (if (c[2] != "") { "-" + c[2] } else { "" });
                if (lo > n || hi > n) {
                    fails += where + ": out of range (" + real + " has " + tostring(n) + " lines)";
                } else if (lo < 1 || lines[lo - 1].trim() == "") {
                    fails += where + ": blank line";
                } else {
                    good += 1;
                    if (verbose) { out += "  line  " + where; };
                };
            };
        };
    };
    out += "file:line citations: " + tostring(good) + "/" + tostring(total) + " resolved";
    if (fails.length > 0) {
        out += "\nSTALE (" + tostring(fails.length) + "):";
        foreach (f in fails) { out += "  " + f; };
        out += "\nA stale reference is worse than none: it reads as authoritative and points at";
        out += "unrelated code. Prefer the symbol form; see the note at the top of LSP.md.";
    } else {
        out += "\nall references resolve";
    };
    ok[0] = fails.length == 0;
    join(out, "\n")
};

// ── names ───────────────────────────────────────────────────────────────

// The text with // and /* */ comments blanked (newlines kept).
def strip_comments(t: str) -> str {
    let out: [byte] = [];
    let i = 0;
    let n = t.length;
    while (i < n) {
        let c = t[i];
        if (c == 47 && i + 1 < n && t[i + 1] == 47) {
            while (i < n && t[i] != 10) { i += 1; };
        } else if (c == 47 && i + 1 < n && t[i + 1] == 42) {
            i += 2;
            while (i + 1 < n && !(t[i] == 42 && t[i + 1] == 47)) {
                if (t[i] == 10) { out += 10; };
                i += 1;
            };
            i += 2;
        } else {
            out += c;
            i += 1;
        };
    };
    from_bytes(out)
};

/** One definition: name, kind, file basename, line. */
type Def = { name: str, kind: str, file: str, line: long };

def collect(files: [str]) -> {str => [Def]} {
    let found: {str => [Def]} = {};
    foreach (f in files) {
        let ln = 0;
        foreach (l in strip_comments(yt.read(f)).split("\n")) {
            ln += 1;
            foreach (k in ["def", "type", "const"]) {
                if (l.starts_with(k) && l.length > k.length && (l[k.length] == 32 || l[k.length] == 9)) {
                    let i = k.length;
                    while (i < l.length && (l[i] == 32 || l[i] == 9)) { i += 1; };
                    let j = i;
                    while (j < l.length && is_word(l[j])) { j += 1; };
                    if (j > i && !(l[i] >= 48 && l[i] <= 57)) {
                        let d: Def = { name: l[i:j], kind: k, file: fs.path_basename(f), line: ln };
                        if (l[i:j] in found) { found[l[i:j]] = found[l[i:j]]! + [d]; } else { found[l[i:j]] = [d]; };
                    };
                };
            };
        };
    };
    found
};

/** check-names: the report, and in ok[0] whether nothing collided. */
def names(ok: [bool]) -> str {
    let out: [str] = [];
    let lsp_files = yt.files(LSP, "", ".y");
    let compiler: [str] = [];
    foreach (f in yt.files(yc.ROOT + "/src/y", "", ".y") + yt.files(yc.ROOT + "/src/y/std", "", ".y")) {
        // std/json.y is imported BY NAME, so it keeps its namespace; an overlay
        // (NAME.TARGET.y) is a variant of its base, not a module of its own
        if (!yt.is_variant(f) && !f.ends_with("/std/json.y")) { compiler += f; };
    };
    let lsp = collect(lsp_files);
    let comp = collect(compiler);
    out += "LSP modules: " + tostring(lsp_files.length) + " files, " + tostring(lsp.length) + " distinct names";
    out += "compiler:    " + tostring(compiler.length) + " files, " + tostring(comp.length) + " distinct names";
    let bad = 0;
    foreach (n in keys(lsp)) {
        if (n in comp) {
            bad += 1;
            out += "\nCOLLISION  " + n;
            foreach (d in comp[n]!) { out += "  compiler  " + d.kind + " " + d.file + ":" + tostring(d.line); };
            foreach (d in lsp[n]!) { out += "  lsp       " + d.kind + " " + d.file + ":" + tostring(d.line); };
        };
    };
    foreach (n in keys(lsp)) {
        let ds = lsp[n]!;
        if (ds.length > 1) {
            bad += 1;
            out += "\nCOLLISION (lsp-internal)  " + n;
            foreach (d in ds) { out += "  lsp  " + d.kind + " " + d.file + ":" + tostring(d.line); };
        };
    };
    // a module basename dot-accessed in the compiler (`base.` after a non-word)
    let bases: [str] = [];
    foreach (f in lsp_files) { bases += fs.path_stem(f); };
    let hazards = 0;
    foreach (f in compiler) {
        let ln = 0;
        foreach (t in yt.read(f).split("\n")) {
            ln += 1;
            let st = t.trim_start();
            if (!(st.starts_with("//") || st.starts_with("*") || st.starts_with("/*"))) {
                foreach (b in bases) {
                    let i = t.index_of(b);
                    while (i >= 0) {
                        let j = i + b.length;
                        while (j < t.length && (t[j] == 32 || t[j] == 9)) { j += 1; };
                        if ((i == 0 || !is_word(t[i - 1])) && (i + b.length >= t.length || !is_word(t[i + b.length]))
                            && j < t.length && t[j] == 46) {
                            hazards += 1;
                            out += "\nBASENAME HAZARD  `" + b + ".` in " + f + ":" + tostring(ln);
                            out += "  the module " + b + ".y binds `" + b + "`, and strip_ns rewrites every `" + b
                                + ".something` as a qualified module reference: rename the module.";
                            i = -1;
                        } else {
                            i = t.index_of(b, i + 1);
                        };
                    };
                };
            };
        };
    };
    out += "\nmodule basenames: " + tostring(bases.length) + " checked, " + tostring(hazards) + " dot-accessed by the compiler";
    bad += hazards;
    if (bad > 0) {
        out += "\n" + tostring(bad) + " collision(s). A path import flattens, so rename one of each (LSP.md section 5).";
    } else {
        out += "\nno collisions: every LSP name is unique among the LSPs and the compiler,";
        out += "and no module basename is dot-accessed by the compiler";
    };
    ok[0] = bad == 0;
    join(out, "\n")
};

// ── fixtures ────────────────────────────────────────────────────────────

// yserve's lifecycle lines (`HH:MM:SS.mmm  yserve: ...`): t009_proto imports
// yserve.y, which starts (and stops) a server with a timestamp and a pid.
def lifecycle(l: str) -> bool {
    if (l.length < 22) { return false; };
    let d = [0, 1, 3, 4, 6, 7, 9, 10, 11];
    foreach (k in d) {
        if (l[k] < 48 || l[k] > 57) { return false; };
    };
    l[2] == 58 && l[5] == 58 && l[8] == 46 && l[12:22] == "  yserve: "
};

def fixture(src: str, cc: str) {
    let base = fs.path_stem(src);
    let tag = base + " [" + fs.path_basename(cc) + "]";
    let bin = yt.tmp("lsp");
    let r = yc.compile(cc, [], src, bin, 600);
    if (r.code != 0) {
        yt.fail(tag + " compile", yt.clip(r.out, 400));
        return;
    };
    // a warning on a std module or a fixture is itself a failure
    if (r.out.contains(": warning: ")) {
        yt.fail(tag + " compiled with a warning", yt.clip(r.out, 300));
        return;
    };
    let c = yt.cmd([bin]);
    c.cwd = yc.ROOT;
    c.merge = true;
    c.timeout = 300;
    let o = yt.run(c);
    fs.remove_file(bin);
    if (o.code != 0) {
        yt.fail(tag + " exit " + tostring(o.code), yt.clip(o.out, 300));
        return;
    };
    let kept: [str] = [];
    foreach (l in o.out.split("\n")) {
        if (!lifecycle(l)) { kept += l; };
    };
    let got = join(kept, "\n") + (if (o.out.ends_with("\n")) { "\n" } else { "" });
    let want = yt.read(LSP + "/test/" + base + ".expected");
    yt.check(tag, got == want, "output differs: " + yt.first_diff(want, got));
};

// ── the formatter ───────────────────────────────────────────────────────

def fmt_files() -> [str] {
    let r: [str] = [];
    foreach (d in ["src/y", "src/tools", "bench", "test/y"]) { r += yt.tree(yc.ROOT + "/" + d, ".y"); };
    r
};

def idempotence() {
    let drv = yt.tmp("idem");
    let b = yc.compile(yc.YREF, [], LSP + "/test/drv_fmt_idempotent.y", drv, 600);
    if (b.code != 0) {
        yt.fail("build the idempotence driver", yt.clip(b.out, 300));
        return;
    };
    let c = yt.cmd([drv] + fmt_files());
    c.merge = true;
    c.timeout = 1200;
    c.cwd = yc.ROOT;
    let r = yt.run(c);
    let bad: [str] = [];
    let sum = "";
    foreach (l in r.out.split("\n")) {
        if (l.starts_with("NOT-IDEMPOTENT")) { bad += l; };
        if (l.starts_with("checked ")) { sum = l; };
    };
    yt.check("formatter idempotence -- " + sum, r.code == 0 && bad.length == 0 && sum != "",
        tostring(bad.length) + " files: " + yt.clip(join(bad, "\n"), 300));
};

// The src/y fixed point: a signal, so it reports and does not gate.
def fixed_point() {
    let drv = yt.tmp("one");
    let b = yc.compile(yc.YREF, [], LSP + "/test/drv_fmt_fixedpoint.y", drv, 600);
    if (b.code != 0) {
        yt.fail("build the fixed-point driver", yt.clip(b.out, 300));
        return;
    };
    let same = 0;
    let n = 0;
    let diffs = 0;
    foreach (f in yt.files(yc.ROOT + "/src/y", "", ".y") + yt.files(yc.ROOT + "/src/y/std", "", ".y")) {
        if (!yt.is_variant(f)) {
        n += 1;
        let x = yt.tmp("x");
        let r = yt.exe([drv, f, x]);
        if (r.out.trim() == "SAME") {
            same += 1;
        } else {
            foreach (l in yt.exe(["diff", f, x]).out.split("\n")) {
                if (l.starts_with("<") || l.starts_with(">")) { diffs += 1; };
            };
        };
        fs.remove_file(x);
        };
    };
    yt.pass("src/y fixed point -- " + tostring(same) + "/" + tostring(n) + " byte-identical, " + tostring(diffs) + " lines differ");
};

// scan.y's spans are the compiler's own tokens (LSP.md §5.1), over every .y in
// the tree: for text the lexer accepts, every token at the same offset with a
// compatible kind; for text it cannot lex, a report and a repair that lexes.
// `compared` must be the whole corpus bar the unlexable files.
def agreement() {
    let drv = yt.tmp("agree");
    let b = yc.compile(yc.YREF, [], LSP + "/test/drv_scan_agree.y", drv, 600);
    if (b.code != 0) {
        yt.fail("build the scanner-agreement driver", yt.clip(b.out, 300));
        return;
    };
    let files = fmt_files();
    let c = yt.cmd([drv] + files);
    c.merge = true;
    c.timeout = 1200;
    c.cwd = yc.ROOT;
    let r = yt.run(c);
    let bad: [str] = [];
    let compared = -1;
    let unlex = -1;
    let failed = -1;
    foreach (l in r.out.split("\n")) {
        if (l.starts_with("MISMATCH") || l.starts_with("REPAIR-FAILED") || l.starts_with("SKIP (unreadable)")) { bad += l; };
        let w = yt.words(l);
        if (w.length > 1 && w[0] == "compared") { compared = yt.num(w[1], -1); };
        if (w.length > 1 && w[0] == "unlexable") { unlex = yt.num(w[1], -1); };
        let k = 0;
        while (k + 1 < w.length) {
            if (w[k] == "repair-failed") { failed = yt.num(w[k + 1], -1); };
            k += 1;
        };
    };
    yt.check("scanner agreement over " + tostring(files.length) + " files (compared " + tostring(compared) + ", unlexable "
        + tostring(unlex) + ")", bad.length == 0 && compared >= 0 && compared == files.length - unlex && failed == 0,
        yt.clip(join(bad, "\n"), 300) + " failed=" + tostring(failed) + " " + yt.clip(r.out, 200));
};

// A schema edit must reach both editor features without editing LSP source.
def schema_evolution() {
    let dir = yt.tmp_dir("language-schema");
    fs.make_dirs(dir + "/src/y");
    fs.make_dirs(dir + "/src/tools/lsp/test");
    foreach (name in ["tags", "lexer", "lex_words", "language_schema", "builtin_codegen"]) {
        let text = yt.read(yc.ROOT + "/src/y/" + name + ".y");
        if (name == "language_schema") {
            text = text.replace("trim strip", "trim strip schema_trim");
            text = text.replace("[\"let\",", "[\"schema_word\", \"let\",");
        };
        fs.write_file(dir + "/src/y/" + name + ".y", text);
    };
    foreach (name in ["strm", "string_help", "scan"]) {
        fs.write_file(dir + "/src/tools/lsp/" + name + ".y", yt.read(LSP + "/" + name + ".y"));
    };
    let probe = dir + "/src/tools/lsp/test/probe.y";
    fs.write_file(probe, "import scan from \"../scan.y\";\nimport strm from \"../strm.y\";\n"
        + "print(scan.scan(\"schema_word\")[0].kind == scan.K_keyword);\n"
        + "print(strm.sig(\"schema_trim\"));\n");
    foreach (cc in [yc.CYCC, yc.YREF]) {
        let bin = dir + "/probe";
        let built = yc.compile(cc, [], probe, bin, 120);
        if (built.code != 0) { yt.fail("schema evolution [" + fs.path_basename(cc) + "]", built.out); }
        else {
            let c = yt.cmd([bin]);
            let result = yt.run(c);
            yt.check("schema evolution [" + fs.path_basename(cc) + "]", result.code == 0 && result.out == "true\nschema_trim() -> str\n", result.out);
        };
    };
};

def cases() -> [yt.Case] {
    LSP = yc.ROOT + "/src/tools/lsp";
    let s = "lsp";
    let cs = [yt.case_of(s, "refs", () => {
                  let ok = [false];
                  let r = refs(false, ok);
                  yt.check("LSP.md references resolve", ok[0], r);
              }),
              yt.case_of(s, "names", () => {
                  let ok = [false];
                  let r = names(ok);
                  yt.check("no name collisions among the path-imported modules", ok[0], r);
              })];
    foreach (f in yt.files(LSP + "/test", "t", ".y")) {
        let base = fs.path_stem(f);
        if (base.length > 4 && base[1] >= 48 && base[1] <= 57 && base[4] == 95) {
            foreach (cc in [yc.CYCC, yc.YREF]) {
                cs += yt.case_of(s, base, () => fixture(f, cc));
            };
        };
    };
    cs += yt.case_of(s, "schema evolution", schema_evolution);
    cs += yt.case_of(s, "agreement", agreement);
    cs += yt.case_of(s, "idempotence", idempotence);
    cs += yt.case_of(s, "fixed point", fixed_point);
    cs
};

def main_refs(av: [str]) -> long {
    LSP = yc.ROOT + "/src/tools/lsp";
    let ok = [false];
    print(refs(av.length > 0 && av[0] == "-v", ok));
    if (ok[0]) { 0 } else { 1 }
};

def main_names(av: [str]) -> long {
    LSP = yc.ROOT + "/src/tools/lsp";
    let ok = [false];
    print(names(ok));
    if (ok[0]) { 0 } else { 1 }
};

export { cases, main_refs, main_names };
