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
            // `native def` is a declaration with no body at all, and both are
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
            let t: Top = got!;
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
        if is_some(got) { out = got!.line; };
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
            let t: Top = got!;
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
// The program's own lines are a verbatim SUFFIX of the spliced text: the resolver
// inlines each imported module and the buffer's own lines follow, unchanged, in
// order. So the whole map is arithmetic on two line counts --
//
//     mine[k] = spliced_lines - buffer_lines + k
//
// for every k at or after the buffer's first non-import line, and 0 before it.
//
// Three things this gets wrong if you do it the obvious way instead, all measured
// on `client-check.js`'s buffer (which imports) and all of them invisible on a
// buffer that does not (the first fixture had no imports, and passed):
//
// - The import STATEMENT's own line is REPLACED by the module's lines, so it has
//   no spliced line of its own. `t015_xref` shows it: mod.y's 10 lines are spliced
//   1..10 and main.y's four lines are 10..13, overlapping at 10 -- main line 1 (the
//   import) is not there at all. It gets 0, and `mine[0]` is the array's own
//   sentinel.
// - Filtering `origin.file == 0` and counting is off by ONE, because the origin
//   map still has an entry for the replaced line. The failure mode is the nasty
//   one: a hover asked about the line ABOVE the one under the cursor and got that
//   line's type, so hovering a blank line between an `import` and a `def` returned
//   the function's own signature.
// - Using `origin.line[i]` as the buffer line has the same off-by-one for the
//   same reason, which is why it is not used here: the two counts are facts about
//   two texts, and `diag.xref_for` holds both.
//
// 0 is the honest answer where there is no spliced line: no type is indexed at
// line 0, so expr_type returns tunk and the server says nothing rather than
// something wrong.
// `out` is indexed by the BUFFER's own 1-based line, so every line before
// `first_own` needs a slot of its own even though its value is 0. Appending only
// from `first_own` on leaves `out[1]` holding line 2's answer, which is an
// off-by-one that reads as "the map is one line late" and is invisible on a buffer
// whose first line is already its own (no import, so first_own == 1).
def own_lines(spliced_lines: long, buffer_lines: long, first_own: long) -> [long] {
    let out: [long] = [0];
    let shift = spliced_lines - buffer_lines;
    let k = 1;
    while (k < first_own) {
        out += 0;
        k = k + 1;
    };
    while (k <= buffer_lines) {
        out += shift + k;
        k = k + 1;
    };
    out
}

// The 1-based buffer line of the first line that is not an import statement, or
// buffer_lines + 1 when every line is one.
//
// Y requires imports at the top of a file, so the first line that does not begin
// with the keyword is where the program's own statements start -- and that is
// exactly the first line the splice keeps under its own name.
def first_own_line(text: str, buffer_lines: long) -> long {
    let out = buffer_lines + 1;
    let k = 1;
    while (k <= buffer_lines) {
        let lb = line_text(text, k);
        let i = 0;
        while (i < len(lb) && (lb[i] == 32 || lb[i] == 9)) { i = i + 1; };
        if (i >= len(lb) || lb[i:i + 7] != "import ") { out = k; k = buffer_lines + 1; } else { k = k + 1; };
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

export { Top, XRef, strip_uniq, tops_of, top_decl, top_line, tops_names, tops_pairs, is_ambiguous, own_lines, indexed_line, nlines, first_own_line };