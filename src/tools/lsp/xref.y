// xref.y -- cross-file navigation, from the splice the server already does.
//
// WHY THIS EXISTS. The measurement in LSP.md 11.4: 84% of what the single-file
// index cannot resolve is a name declared in ANOTHER file, and for a long time
// that was recorded as needing the compiler change of §9.2. It does not.
// `diag.diagnose` already resolves the buffer's imports, splices them in, runs
// `strip_ns` and runs `rename.rename_program_x` -- and rename gives every
// binding a name of the form `orig$N` that is SHARED by its definition and all
// its uses. So the pairing go-to-definition needs already exists, in an AST the
// server builds and throws away.
//
// Measured on main.y importing mod.y, after the rename alone:
//
//   line 1 kind decl   decl name helper$1     <- mod.y
//   line 4 kind decl   decl name TOP$3        <- mod.y
//   line 6 kind decl   decl name v$4          <- main.y
//   line 7 kind call   callee print @7 args v$4 @7 + TOP$3 @7
//   origin map: lines 1-4 -> file 1 (mod.y),  lines 5-7 -> file 0 (main.y)
//
// TOP$3 is DECLARED on spliced line 4 and READ on spliced line 7. One name, two
// files, and `origin.file` says which file each line came from. That is the
// whole mechanism.
//
// WHY IT IS SMALL. Splicing inlines a module's source in place, so every
// declaration an imported file contributes is a TOP-LEVEL statement of the
// spliced program. Cross-file navigation is therefore about top-level
// declarations, and those are a flat list -- `ast3.stmts`, looped. It does NOT
// need a walker over the Node union, which is the thing that would have made
// this large and would silently lose whichever member nobody remembered.
//
// The declaration's position in the AST is the KEYWORD (`let`, `def`), not the
// name -- `parser.y` sets `Decl.line/col` from the keyword token. So this module
// records the spliced LINE of each top-level declaration and nothing more; the
// exact name position comes from `scope.index_src` over the TARGET FILE, read
// on its own. Positions therefore come from the same place they always did, and
// this file never has to know where in a line a name starts.
//
// WHAT IT REFUSES. Two modules exporting the same name is ambiguous, and this
// answers nothing rather than picking one. A name used without a qualifier that
// resolves to a top-level declaration is answered, because that is what the
// splicer did to it; but nothing here infers which module the user meant when
// the text does not say.
import tags from "../../y/tags.y";
import parser from "../../y/parser.y";

// A top-level declaration, as the renamer left it. `line` is a line of the
// SPLICED program, which `diag.file_of` turns into a file and a line in it.
type Top = { orig: str, uniq: str, line: long, kind: str };

type XRef = { tops: { str => Top }, ambiguous: [str] };

// Is `w` in `xs`? `index_of` is the string one; there is no array equivalent, and
// these lists are a handful of names.
def in_list(xs: [str], w: str) -> bool {
    let out = false;
    let i = 0;
    while (i < len(xs)) {
        if (xs[i] == w) { out = true; };
        i = i + 1;
    };
    out
}

def is_ambiguous(x: XRef, name: str) -> bool { in_list(x.ambiguous, name) }

// `orig$N` -> `orig`. `$` cannot appear in a Y identifier (the lexer stops a
// name at it), so the first one is the seam. A name with no `$` comes back
// unchanged, which is what a builtin or a std name looks like.
def strip_uniq(uniq: str) -> str {
    let cut = index_of(uniq, "$");
    if (cut < 0) { uniq } else { uniq[0:cut] }
}

// The top-level declarations of a RENAMED, SPLICED program, keyed by original
// name.
//
// A name two modules both export lands in `ambiguous` rather than in `tops`, and
// resolves to nothing. Picking one would put a jump on a definition the user did
// not choose, which is the same mistake as guessing a type: worse than nothing,
// because it cannot be told apart from a real answer.
def tops_of(ast: Block) -> XRef {
    let tops: { str => Top } = {};
    let ambiguous: [str] = [];
    let i = 0;
    while (i < len(ast.stmts)) {
        let n = ast.stmts[i];
        if (n.k == K.typedef) {
            // `type Pair = { ... }` is a typedef node, not a Decl -- it has no
            // body and no value -- so it is missed by the Decl arm entirely, and
            // a program that names its own type gets no navigation to it.
            let td: TypeDef = n;
            let orig = strip_uniq(td.name);
            if (orig != "" && !in_list(ambiguous, orig)) {
                if is_some(tops[orig]) { ambiguous += orig; }
                else { tops[orig] = { orig: orig, uniq: td.name, line: td.line, kind: "type" }; };
            };
        };
        if (n.k == K.decl) {
            let d: Decl = n;
            // An `import` binds a module basename and has no body to jump into;
            // `ndef` is a declaration with no body at all, and both are
            // still things a program can name, so neither is filtered here.
            let orig = strip_uniq(d.name);
            // A map's value type is pinned by its first entry and cannot hold a
            // none without widening to `Top?` at every read (serve.y's Doc map
            // says so at its own definition), so a collision does NOT clear the
            // entry -- it records the name and `lookup` checks that list FIRST.
            // The first binding stays as a placeholder nobody will return.
            if (orig != "" && !in_list(ambiguous, orig)) {
                if is_some(tops[orig]) { ambiguous += orig; }
                else { tops[orig] = { orig: orig, uniq: d.name, line: d.line, kind: d.kind }; };
            };
        };
        i = i + 1;
    };
    { tops: tops, ambiguous: ambiguous }
}

// The top-level declaration of `name`, or none -- and none means BOTH "no such
// name" and "two modules export it", which is the honest answer for both.
def top_decl(x: XRef, name: str) -> Top? {
    if (is_ambiguous(x, name)) { return none; };
    let got = x.tops[name];
    if is_some(got) { got } else { none }
}

// Every top-level name, as completion wants them. Ambiguous ones are left out:
// offering a name whose go-to-definition is `null` is a list item that cannot be
// taken up.
def tops_names(x: XRef) -> [str] {
    let out: [str] = [];
    foreach (k in keys(x.tops)) {
        let got = x.tops[k];
        if (is_some(got)) {
            let t: Top = got !;
            if (!in_list(x.ambiguous, t.orig) && !in_list(out, t.orig)) { out += t.orig; };
        };
    };
    out
}

// The spliced line a top-level name was declared on, or 0. 0 rather than none
// because every use of this is `if (line > 0)`, and a name nobody declares has
// no line to have.
def top_line(x: XRef, name: str) -> long {
    let out = 0;
    if (!is_ambiguous(x, name)) {
        let got = x.tops[name];
        if is_some(got) { out = got !.line; };
    };
    out
}

// Every top-level declaration that has a line, as "name\tline" pairs, for a
// caller that has to resolve the file itself. The tab is the seam because a
// Y name cannot contain one.
def tops_pairs(x: XRef) -> [str] {
    let out: [str] = [];
    foreach (k in keys(x.tops)) {
        let got = x.tops[k];
        if (is_some(got)) {
            let t: Top = got !;
            if (!is_ambiguous(x, t.orig) && !in_list(out, t.orig)) {
                out += t.orig + "\t" + tostring(t.line);
            };
        };
    };
    out
}

// The SPLICED line for each of the buffer's own lines, 1-based at both ends and
// 0 where the buffer has no line there.
//
// Built by INVERTING the origin map, which is the only source that knows. It used
// to be a constant shift -- `spliced_lines - buffer_lines` added to every line from
// the first non-import line on -- on the reasoning that a file's own text is
// spliced as one contiguous SUFFIX. That holds only when the imports are the very
// FIRST lines. A header comment before them makes "first non-import line" line 1
// (a comment is not an import), the shift is then applied from line 1, and every
// line after the imports maps to the wrong spliced line. Measured on
// src/y/asm.y, which opens with a 16-line header before its six imports:
//
//   mine[1623]   4283      what the shift answered
//   the truth    4365      the program's own text starts at spliced line 2743
//
// so expr_type was asked about a line 82 above the right one and hover on `it.fix`
// there answered from some other expression's type -- string methods, for a
// record. Nothing else in the file looked wrong: a declaration site is answered
// from the buffer's own single-file index, not from this map, which is why it
// survived. The failure needs a file whose header precedes its imports -- the
// normal way to write one -- and it shows in the TYPE, not the navigation.
//
// The origin map has no such assumption: per spliced line it records the file the
// line came from and the line it was in that file. File id 0 is the entry point;
// a module checked through .ycontext supplies its own file id instead. The
// whole map is one walk. It also gets the two off-by-ones the shift could not: the
// origin map still has an entry for an import statement's own replaced line (whose
// recorded buffer line is real), and a file whose last line has no trailing newline
// is counted the same way on both sides because both sides index the same text.
def own_lines(o: Origin, buffer_lines: long, fid: long = 0) -> [long] {
    let out: [long] = [0];
    let k = 0;
    while (k < buffer_lines) { out += 0; k = k + 1; };
    let i = 1;
    let n = len(o.file);
    while (i <= n) {
        if (o.file[i - 1] == fid) {
            let ln = o.line[i - 1];
            if (ln >= 1 && ln <= buffer_lines) { out[ln] = i; };
        };
        i = i + 1;
    };
    out
}

// How many lines `text` has, counting a trailing newline as ending the last line
// rather than starting an empty one -- which is what `split` gives, so this is
// `len(split(text, "\n"))` written out. Both counts in `own_lines` are taken this
// way, and the trailing empty element CANCELS in their difference, so the map does
// not depend on the convention either way.
def nlines(text: str) -> long { len(split(text, "\n")) }

// One 1-based line of `text` without its newline, which is all this needs.
def line_text(text: str, n: long) -> str {
    let line = 1;
    let i = 0;
    while (i < len(text) && line < n) {
        if (text[i] == 10) { line = line + 1; };
        i = i + 1;
    };
    let stop = i;
    while (stop < len(text) && text[stop] != 10) { stop = stop + 1; };
    text[i:stop]
}

// Is this position one the checker indexed? tunk is the "nothing here" sentinel
// (types.expr_type), and a consumer must test it rather than print it -- tunk
// renders as `<error>`, which would read as a diagnostic about the user's code.
def indexed_line(mine: [long], line: long) -> long {
    let out = 0;
    if (line >= 1 && line < len(mine)) { out = mine[line]; };
    out
}

export { Top, XRef, strip_uniq, tops_of, top_decl, top_line, tops_names, tops_pairs, is_ambiguous, own_lines, indexed_line, nlines };
