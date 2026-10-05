// diag.y -- the diagnostics pipeline: errors and warnings TOGETHER.
//
// The point of this fixture is the difference from the command line.
// native.compile_unit returns before lint when the checker found anything, so
// `ycc` never prints an error and a warning from the same file; an editor must.
// Every case below therefore checks that both kinds come back when both exist.

import diag from "../diag.y";

// Imports in the fixture resolve against this directory, where mod.y lives.
const HERE = "src/tools/lsp/test";

let clean = "let x = 1;\nprint(x);\n";
let d0 = diag.diagnose(clean, ".", "main.y", "", 0);
print("clean: " + tostring(len(d0)));

// ── a type error, and a warning in the same file ────────────────────────
let both = "def f() -> long {\n    let unused = 1;\n    2 + \"s\"\n}\n";
let d1 = diag.diagnose(both, ".", "main.y", "", 0);
print("errors+warnings file: " + tostring(len(d1)));
foreach (d in d1) {
    print("  " + tostring(d.kind) + " " + tostring(d.line) + ":" + tostring(d.col) + " " + d.msg);
}

// ── several errors at once: the checker reports all of them ─────────────
let many = "def f() -> long {\n    let a: str = 1;\n    let b: str = 2;\n    let c: bool = 3;\n    0\n}\n";
let d2 = diag.diagnose(many, ".", "main.y", "", 0);
print("several errors: " + tostring(len(d2)));

// ── every parser error family, all reported ─────────────────────────────
let syn = "def f( {\nlet = ;\n}\n";
let d3 = diag.diagnose(syn, ".", "main.y", "", 0);
print("syntactic: " + tostring(len(d3)));
foreach (d in d3) {
    print("  " + tostring(d.line) + ":" + tostring(d.col) + " " + d.msg);
}

// ── warnings only ───────────────────────────────────────────────────────
let warn = "def f() -> long {\n    let unused = 1;\n    2\n}\n";
let d4 = diag.diagnose(warn, ".", "main.y", "", 0);
print("warnings only: " + tostring(len(d4)));
foreach (d in d4) {
    print("  " + tostring(d.kind) + " " + tostring(d.line) + ":" + tostring(d.col) + " " + d.msg);
}

// ── wlevel 1 turns on the optional checks ───────────────────────────────
let dropped = "def g() -> long { 1 }\ndef f() -> long {\n    g();\n    2\n}\n";
let d5 = diag.diagnose(dropped, ".", "main.y", "", 0);
let d6 = diag.diagnose(dropped, ".", "main.y", "", 1);
print("wlevel 0: " + tostring(len(d5)) + "   wlevel 1: " + tostring(len(d6)));

// ── an unterminated literal: a diagnostic, not a dead server ────────────
let unterm = "let s = \"oops\nlet t = 1;\n";
let d7 = diag.diagnose(unterm, ".", "main.y", "", 0);
print("unterminated string: " + tostring(len(d7)));
foreach (d in d7) {
    print("  " + tostring(d.kind) + " " + tostring(d.line) + ":" + tostring(d.col) + " " + d.msg);
}
print("still alive");

let uncomment = "/* never closed\nlet x = 1;\n";
let d8 = diag.diagnose(uncomment, ".", "main.y", "", 0);
print("unterminated comment: " + tostring(len(d8)));

// ── a diagnostic in an IMPORTED file is labelled with that file ─────────
let main = "import helper from \"./mod.y\";\nprint(helper.f());\n";
let d9 = diag.diagnose(main, HERE, "src/tools/lsp/test/main.y", "", 0);
print("with an import: " + tostring(len(d9)));
foreach (d in d9) {
    print("  " + d.file + ":" + tostring(d.line) + " " + d.msg);
}

// ── an import that does not exist ───────────────────────────────────────
// native_resolve_x handles this by printing to stdout and exit(1). In a server
// that is a dead request handler, so diag.check finds it first and answers with
// a diagnostic instead -- and answers ONLY with that, because with a file
// missing there is no program to check and everything else would be a cascade.
let gone = "import nope from \"./no_such_file.y\";\nlet a: str = 1;\nprint(a);\n";
let dgo = diag.diagnose(gone, HERE, HERE + "/main.y", "", 0);
print("missing import: " + tostring(len(dgo)));
foreach (d in dgo) {
    print("  " + tostring(d.line) + ":" + tostring(d.col) + " " + d.msg);
}
print("and it does not take the server down");

// An import that DOES exist still resolves, and the module's own warning is
// still found -- the pre-check must not stop the pipeline for a good import.
let okimp = diag.diagnose(main, HERE, HERE + "/main.y", "", 0);
print("good import still checks: " + tostring(len(okimp)) + " (" + okimp[0].msg + ")");

// A by-name import (a std module) is never treated as missing, even though
// there is no such file next to the document.
let byname = diag.diagnose("import fs;\nprint(fs.cwd().length);\n", HERE, HERE + "/main.y", "", 0);
print("by-name import: " + tostring(len(byname)));

// The prelude's readline must not read as undefined ────────────────────
// diag.y reconstructs native.unit_externs because it is not exported; if the
// reconstruction were wrong this is where it shows.
let rd = "let l = readline();\nprint(is_some(l));\n";
let d10 = diag.diagnose(rd, ".", "main.y", "", 0);
print("readline: " + tostring(len(d10)));
foreach (d in d10) { print("  " + d.msg); }

// ── an empty buffer is not an error ─────────────────────────────────────
print("empty: " + tostring(len(diag.diagnose("", ".", "main.y", "", 0))));
print("blank: " + tostring(len(diag.diagnose("\n\n  \n", ".", "main.y", "", 0))));