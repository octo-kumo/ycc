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
import xref from "./xref.y";

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
    // ":" and LAST, not first: origin_at renders `path:line`, and a Windows path
    // has a colon of its own (`C:\src\asm.y:12`), so the first one is the drive.
    let cut = last_index_of(at, ":");
    if (cut < 0) { at } else { at[0:cut] }
}

// The line a SPLICED line has IN THE FILE IT CAME FROM, which is not the spliced
// line and never was.
//
// `origin_at` already computes exactly this -- it renders "path:line" and every
// caller wanted only the path -- and `file_of` threw the line away. So a finding
// carried a spliced line and published it against the buffer's URI, and every
// diagnostic in a file with imports landed past the end of it: `src/y/asm.y` is
// 1888 lines, its six imports splice to 6426, and every error the user saw was on
// line 3356 and up. The editor cannot show a squiggle there, so the finding was
// invisible AND the message looked wrong, which together read as "the errors are
// nonsense".
//
// The arithmetic is origin_at's own, done directly rather than by rendering a
// string and taking it apart again: `o.line[k-1]` is where this file's first
// contribution sat in the splice, and `ln - k` is how far into the run we are.
def line_in_file(o: Origin, ln: long) -> long {
    let f = o.file;
    let l = o.line;
    let n = len(f);
    if (ln < 1 || n == 0) {
        return ln;
    };
    let k = ln;
    if (k > n) { k = n; };
    l[k - 1] + ln - k
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
    let warnings = lint.lint_unit(ast, ast3, nr.origin.file, nr.origin.mods, wlevel);

    // The checker's and the linter's lines are SPLICED lines; a Finding's are the
    // line in the file it names. See line_in_file.
    let o = nr.origin;
    foreach (e in errors) {
        out += { msg: e.msg, line: line_in_file(o, e.line), col: e.col, kind: SEV_ERROR, file: file_of(o, e.line) };
    }
    foreach (w in warnings) {
        out += { msg: w.msg, line: line_in_file(o, w.line), col: w.col, kind: SEV_WARNING, file: file_of(o, w.line) };
    }
    out
}

// ── cross-file navigation (LSP.md 11.4) ──────────────────────────────────
//
// The top-level declarations of the SPLICED program, resolved to a file and a
// line in THAT file.
//
// `diagnose` throws the spliced program and the renamed AST away once it has the
// findings, and both are exactly what go-to-definition needs (§11.4 has the
// measurement): the renamer gives a binding a name of the form `orig$N` shared
// by its definition and its uses, and a splice inlines a module at top level so
// `origin.file` sends each of those lines back to the file it came from.
//
// It lives here rather than in xref.y because this file already has `file_of`,
// and duplicating it would be a second answer to "which file is this line".
//
// `check_program` is NOT run: navigation needs no types, and the checker is the
// expensive half of a compile. The trade is that a buffer with a type error
// still navigates, which is what an editor wants -- the error is already in the
// diagnostics channel.
// `mine` is the buffer's own line -> the SPLICED line, which is what every
// position in the compiler's tables is keyed by. It is built from the origin map
// rather than guessed from the splice order, because a program can import the
// same module twice, nest imports, or have an import whose own source declares
// things -- the order is an implementation detail and the map is the truth.
// `self_path` is the buffer's own path, so "which of these names came from
// somewhere else" is answerable: `files` maps every spliced top-level name to its
// origin file, and a module's members are the ones that are not this file's.
//
// `units` is every linked unit the buffer asked for, with each one's `exports`
// (`Sym` = name, label, type) already compiled. It is here because a module's
// members are the ONLY complete answer to "what can follow this `.`", and the LSP
// had no way to get them: `names`/`files` cover the buffer's own path imports and
// nothing else, so `math.` fell through to the string methods.
//
// The units come from the SAME `std_units(nr.std, pack)` call the checker needs,
// so this is the list that was loaded anyway rather than a second load.
type Prepared = { names: [str], lines: { str => long }, files: { str => str }, mine: [long], units: [Unit], self_path: str };

// The prepared index for `text`, or none when it cannot be resolved -- a missing
// import, an unterminated literal, a path that does not exist. None is the
// honest answer in each case, and it is not an error: `diagnose` reports those
// separately and says so.
// `pack` is the std pack, or "" to compile the std units from source -- the same
// argument `diagnose` takes, and for the same reason it matters here too.
//
// It used to be `externs_none()`, i.e. the checker was asked about the spliced
// program with NO std units linked. Every std name therefore came back
// "undefined function", every expression that used one got `tunk` instead of a
// type, and the consequence reached the editor: hovering `math.exp` showed
// nothing, because there was no type to show. The diagnostics path was right all
// along -- `diagnose` has always passed the real `externs_for(su, nr.std)` -- so
// the two disagreed about the same buffer, which is worse than either being wrong.
def xref_for(text: str, dir: str, path: str, pack: str) -> Prepared? {
    let out: Prepared? = none;
    let rp = scan.repair(text);
    if (len(rp.bad) == 0) {
        // No unterminated literal in the user's own buffer, so the program lexes
        // and there is something to navigate. When there IS one, diagnose
        // reports it and this answers none -- a program that does not lex has no
        // scope to ask about.
        let nr = native_resolve_x(rp.text, dir, 0, true, path);
        if (len(nr.imports) > 0 || !missing_import_here(text, dir)) {
            // nr.src, the SPLICED text -- NOT rp.text. Parsing the buffer on its
            // own leaves every imported name undefined and yields a tree of one
            // file's declarations, while the origin map below indexes the spliced
            // program; the two then disagree and every name is attributed to
            // whichever module's lines happen to sit at that number. That is what
            // the first version of this did, and it produced exactly one name,
            // attributed to the wrong file.
            let ast = parser.parse_program(lexer.tokenize(nr.src));
            let ast2: Block = strip_ns(ast, nr.imports);
            // rename_program_x2, not rename_program_x, and only the tree is read
            // back. The second half of its answer -- the def site of every
            // binding, including the locals and parameters no LSP table has -- is
            // not consumed here, and LSP.md 9.2 says why with the measurement:
            // the cross-file definition path still re-reads the target file to get
            // its declaration's SIGNATURE and doc comment, which a position does
            // not carry, so a column the server already had is all the map would
            // save. Binding it to a name would only have made the compiler warn.
            let ast3: Block = rename.rename_program_x2(ast2, [], nr.origin.file, nr.origin.mods).ast;
            let x = xref.tops_of(ast3);
            let units = std_units(nr.std, pack);
            // From the origin map, not from a line count: a header comment before
            // the imports made the old shift wrong for every line after them.
            // xref.own_lines says which and by how much.
            let mine = xref.own_lines(nr.origin, xref.nlines(rp.text));
            let lines: { str => long } = {};
            let files: { str => str } = {};
            let names: [str] = [];
            foreach (pair in xref.tops_pairs(x)) {
                let tab = index_of(pair, "\t");
                let nm = pair[0:tab];
                let ln = tonum(pair[tab + 1:len(pair)]);
                lines[nm] = ln;
                files[nm] = file_of(nr.origin, ln);
                names += nm;
            };
            // check_program with the expression index ON. The table it leaves
            // behind lives in types.y's module globals, which is where
            // expr_type() reads it from -- so the LSP never copies a type, it
            // asks the checker for the one it already computed.
            type_index_on();
            let errs = check_program(ast3, externs_for(units, nr.std));
            type_index_off();
            // The errors themselves are diagnose()'s job; xref_for only wants the
            // side effect. A buffer that does not type-check still navigates and
            // still hovers: the errors are already in the diagnostics channel, and
            // refusing to answer because of them would make the editor feel broken
            // in exactly the situation where a person is trying to fix it.
            let _ = errs;
            out = some({ names: names, lines: lines, files: files, mine: mine, units: units, self_path: path });
        };
    };
    out
}

// Does the text name an import whose file is missing? A buffer with no imports
// at all needs no splice and no rename, which is the common case for a scratch
// file and worth not paying for.
def missing_import_here(text: str, dir: str) -> bool {
    let bad = false;
    foreach (f in missing_imports(text, dir, "")) {
        if (f.kind == SEV_ERROR) { bad = true; };
    };
    bad
}

export {
  Imp, Finding, SEV_ERROR, SEV_WARNING, check, imports_of,
  missing_imports, externs_for, file_of, line_in_file, Prepared, xref_for
};