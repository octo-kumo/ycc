// diag.y -- document text in, diagnostics out.
//
// This is the substance of M1. It never calls emit_program, so it does no codegen
// at all: resolve imports, lex, parse, rename, check, lint, and stop. That also
// lets it do the one thing the command line cannot: report warnings and errors
// TOGETHER. native.compile_unit returns before lint when the checker found
// anything, because a program that does not check needs no warnings; an editor
// needs both, so the two passes are run here side by side.
//
// Two pieces of the compiler's own API are not exported (`unit_externs` and
// `origin_file`, LSP.md §9.1 C1), so they are reconstructed. Both are
// behavioural, and test-diag.sh checks them against real programs rather than
// taking the reconstruction on trust.

import tags from "../../y/tags.y";
import lexer from "../../y/lexer.y";
import parser from "../../y/parser.y";
import types from "../../y/types.y";
import rename from "../../y/rename.y";
import lint from "../../y/lint.y";
import native from "../../y/native.y";
import scan from "./scan.y";

// Named Finding, not Diag: a path import shares ONE namespace with everything
// else the program imports, so `type Diag` here would shadow `types.Diag` and
// break the checker's own err_at. (By-name std imports keep their namespace;
// path imports are flattened. That asymmetry is worth knowing.)
type Finding = { msg: str, line: long, col: long, kind: long, file: str };

const SEV_ERROR = 1;
const SEV_WARNING = 2;

// The checker binds a program's externs: the prelude's readline, exec's exec.
// native.unit_externs does this and is not exported, so it is repeated here --
// std_unit_bound is `name == "prelude" || name == "exec"`, and a unit counts
// only when the program actually named it.
def externs_for(su: [Unit], snames: [str]) -> [Sym] {
    let ext: [Sym] = [];
    foreach (u in su) {
        let bound = u.name == "prelude" || u.name == "exec";
        let named = false;
        foreach (s in snames) { if (s == u.name) { named = true; } };
        if (bound && named) { ext += u.exports; }
    }
    ext
}

// Which file a spliced line came from, as a path. native.origin_file would do
// this and is not exported; origin_at renders "path:line" and the line is
// already known, so the path is everything up to the last colon.
def file_of(o: Origin, ln: long) -> str {
    let at = origin_at(o, ln, false);
    let cut = last_index_of(at, ":");
    if (cut < 0) { at } else { at[0:cut] }
}

// One `import` the buffer asks for, found without parsing: the tolerant
// scanner already classifies `import` as a keyword and the module path as a
// string, so the two are adjacent spans and nothing has to parse to find them.
type Imp = { path: str, line: long, col: long };

// Every by-path import in the text. By-name imports (`import fs;`) are left out
// on purpose: those name std modules, which are always present (they travel in
// the pack or beside the compiler), and treating a missing one as an error
// would break a server with no std pack attached.
def imports_of(text: str) -> [Imp] {
    let out: [Imp] = [];
    let r = scan.scan_full(text);
    let sps = r.spans;
    let i = 0;
    while (i < len(sps)) {
        let s = sps[i];
        // `import` is a CONTEXTUAL word, not one of the twelve keywords -- it is
        // only a keyword at the head of a line -- so both kinds are accepted and
        // the text decides. Getting this wrong is silent: the scanner classifies
        // it fine, the pre-check just never fires.
        if ((s.kind == scan.K_keyword || s.kind == scan.K_contextual) && is_word(text, s) == "import") {
            // `import name from "path";` -- the path is the last string span
            // before the `;`. Taking the last one rather than the first handles
            // a by-name import that a later reader might mistake for a path.
            let want = "";
            let j = i + 1;
            while (j < len(sps) && sps[j].kind != scan.K_punct) { j = j + 1; }
            if (j > i + 1 && sps[j - 1].kind == scan.K_string) {
                let q = sps[j - 1];
                want = text[q.off + 1:q.end - 1];
                out += { path: want, line: q.line, col: q.col };
            }
        }
        i = i + 1;
    }
    out
}

def is_word(text: str, s: Span) -> str {
    text[s.off:s.end]
}

// An import that cannot be found on disk. Reported HERE rather than left to the
// resolver, because native_resolve_x handles it by printing to stdout and
// exit(1) -- which in a server is a dead request handler and a line of
// unframed text in the client's stream. Getting the import wrong is an everyday
// thing to do (a typo, or a file not created yet), so it has to be a squiggle.
def missing_imports(text: str, dir: str, path: str) -> [Finding] {
    let out: [Finding] = [];
    foreach (im in imports_of(text)) {
        // The resolver's own search list, in the part that matters here: the
        // importing file's directory, then the document's own directory.
        let found = fs.exists(dir + "/" + im.path);
        if (!found && path != "") {
            let cut = last_index_of(path, "/");
            if (cut >= 0) { found = fs.exists(path[0:cut] + "/" + im.path); }
        }
        if (!found) {
            out += { msg: "cannot open import '" + im.path + "'", line: im.line, col: im.col, kind: SEV_ERROR, file: path };
        }
    }
    out
}

// Diagnostics for one document. Named `diagnose`, not `check`, because src/y/std/regex.y
// already defines `check` and a path import flattens both into one namespace
// (check-names.py).
//
//   text      the buffer as the editor holds it, unsaved edits included
//   dir       the directory imports resolve against
//   path      the document's own path, used to label its diagnostics and to
//             resolve its imports
//   pack      the std pack, or "" to compile the std units from source
//   wlevel    0 or 1, as `ycc -W`
def diagnose(text: str, dir: str, path: str, pack: str, wlevel: long) -> [Finding] {
    let out: [Finding] = [];

    // The buffer is scanned and its imports resolved BEFORE the compiler sees
    // it. Repair comes first: tokenize calls exit(1) on an unterminated string
    // or block comment, which in a server is fatal on the first `"` a user
    // types (LSP.md R1.10). The repair is a copy; the editor's buffer is
    // untouched.
    let rp = scan.repair(text);
    let src = rp.text;
    foreach (b in rp.bad) {
        let why = "unterminated " + scan.kind_name(b.kind);
        out += { msg: why, line: b.line, col: b.col, kind: SEV_ERROR, file: path };
    }

    let gone = missing_imports(src, dir, path);
    if (len(gone) > 0) {
        // The resolver would exit(1) on one of these, taking the whole request
        // with it. Stopping here instead means the user gets the message they
        // need, as a diagnostic on the right line.
        //
        // And only those: with a file missing there is no program to check, so
        // every other finding would be a cascade off the same cause -- a wall of
        // red for one typo, which is how a user learns to ignore the panel. The
        // errors come back as soon as the import resolves, because the editor
        // re-checks on every keystroke.
        return out + gone
    }

    let nr = native_resolve_x(src, dir, 0, true, path);
    let su = std_units(nr.std, pack);

    // nr.src is the SPLICED text: this document with every import inlined ahead
    // of it. That is what has to be parsed -- parsing the buffer on its own
    // would make every imported name undefined and attribute the whole program
    // to the wrong file. It is repaired a second time because an IMPORTED file
    // can hold an unterminated literal of its own, and tokenize would exit(1)
    // on it just the same. Only the first repair's findings are reported: those
    // are in the user's buffer, at positions they can see.
    let rp2 = scan.repair(nr.src);
    let toks = lexer.tokenize(rp2.text);
    let ast = parser.parse_program(toks);

    // strip_ns + rename are the two passes compile_unit runs before the
    // checker; both are exported, so the pipeline can be driven directly.
    let ast2: Block = strip_ns(ast, nr.imports);
    let ast3 = rename.rename_program_x(ast2, [], nr.origin.file, nr.origin.mods);

    let ext = externs_for(su, nr.std);
    let errors = types.check_program(ast3, ext);
    // `ogen` says which lines a meta block generated, and it is EMPTY unless
    // the meta pass ran: the pass is switched on by meta.meta_begin(), which
    // the DRIVER calls before its own resolve and nothing else does -- so a
    // buffer checked here never has generated lines. Passing nr.ogen rather
    // than a literal [] is what keeps this honest if the server is ever taught
    // to run the pass: it is exactly what native.compile_unit does with it.
    let warnings = lint.lint_unit(ast, ast3, nr.origin.file, nr.origin.mods, wlevel, nr.ogen);

    let o = nr.origin;
    foreach (e in errors) {
        out += { msg: e.msg, line: e.line, col: e.col, kind: SEV_ERROR, file: file_of(o, e.line) };
    }
    foreach (w in warnings) {
        out += { msg: w.msg, line: w.line, col: w.col, kind: SEV_WARNING, file: file_of(o, w.line) };
    }
    out
}

export {
  Imp, Finding, SEV_ERROR, SEV_WARNING, check, imports_of,
  missing_imports, externs_for, file_of
};