// scope.y -- what is declared where, and what is visible from where.
//
// The name matters and is not decorative. An `import` binds the module's
// BASENAME as a name in the shared namespace, and strip_ns then rewrites any
// `name.field` in the whole program as a qualified module reference. So a
// module called `index` silently rewrote the compiler's own `index.idx` and
// `index.arr` -- 42 such reads in src/y -- into module-qualified names that
// do not exist, and every one became "undefined variable".
// check-names.py now tests each module's basename for this (LSP.md section 5).
//
// The foundation for go-to-definition, hover and completion (M4, R4/R5/R6). All
// three are the same question asked three ways: *at this position, what does this
// name mean?* So the answer is built once, here.
//
// ── what this is honest about ──
//
// It is built from `scan.y`'s spans, not from the renamer, so it knows NAMES and
// POSITIONS and nothing else. It does not know types, and R4.3 is right that a
// type must come from the checker's own inference rather than from anything
// re-derived here. So:
//
//   * a hover shows a DECLARED type -- an annotation, a parameter list, a return
//     type written out, or `inferred_ret` for a def whose return type was left
//     off. Where a `let` has no annotation there is nothing to show, and it says
//     so rather than guessing;
//   * a `detail` is the declaration AS WRITTEN, which is what a person reading
//     the source would quote.
//
// R5.2 says cross-file resolution should come from the renamer's unique names
// (LSP.md 9.2, C2). That is the right way and it is not implemented; this is the
// substitute, and it is exact for Y's lexical scoping: walk outward from the
// cursor through enclosing blocks, then the file's top level, then its imports.
// The renamer would be faster and would settle shadowing exactly. What this does
// settle exactly is every case where the innermost declaration wins, which is
// every case that is not deliberate shadowing.

import scan from "./scan.y";
import pos from "./pos.y";

// ── what a declaration is ───────────────────────────────────────────────

const D_DEF = 1;
const D_LET = 2;
const D_CONST = 3;
const D_PARAM = 4;
const D_TYPE = 5;
const D_IMPORT = 6;
const D_SELF = 7;

type IdxDecl = {
    name: str,
    kind: long,
    file: str,            // the path this declaration is in
    line: long,           // 0-based, of the NAME
    ch: long,
    end_line: long,       // the whole construct, for "reveal range"
    end_ch: long,
    detail: str,          // as written: "(x: long) -> long", or ": long"
    doc: str,             // the comment lines immediately above, joined
    depth: long,          // brace depth at the declaration; 0 is top level
    // A packed LSP (line, character) where this scope begins, or -1 at top
    // level. Packed in the SAME 0-based convention as `line`/`ch` above -- see
    // index_src's `opens` for why that is worth saying.
    scope_start: long,
    // The packed position at which that scope CLOSES, or -1 while it is still
    // open. Resolved once per index in a post-pass rather than looked up per
    // question: `nav.in_scope` asked `scope_end` for every candidate of every
    // lookup, and the highlighter asks about EVERY identifier, so the cost was
    // proportional to (identifiers x declarations of that name) -- 2.0 s on
    // `src/y/native.y`, where `st` alone has hundreds.
    //
    // It cannot be filled in while the index is built, because a scope's end is
    // only known when its `}` is reached and declarations are recorded on the way
    // in. The post-pass walks `decls` once, which is linear in the file.
    scope_end: long,
    order: long           // source order, for "declared before this use"
};

// The whole index for one file.
type FileIdx = {
    path: str,
    decls: [IdxDecl],
    // Every scope in the file, innermost last: the stack of open braces with
    // the position each block opened at. Packed like `scope_start`, and in the
    // same 0-based LSP convention -- a packed position is only comparable with
    // another packed position, and this one is compared against IdxDecl.line
    // and .ch by nav.in_scope.
    opens: [long],
    // Every scope that has CLOSED, as packed LSP positions in pairs:
    // start, end, start, end, ... in the order the braces closed. Kept because
    // `opens` alone cannot answer "is this use still inside that scope" -- the
    // stack is popped at the `}` and the information is gone. Without it a name
    // declared inside one function stayed visible for the rest of the file, and
    // `print(shared)` after a function that had its own `shared` resolved to
    // the wrong declaration (scope.y's in_params comment has the other half).
    closed: [long],
    // The same pairs as a start -> end map, because `closed` cannot be searched:
    // it is in the order the braces CLOSED, so the starts are not ascending and a
    // binary search over them would be wrong. `scope_end` therefore walked all
    // ~7,000 entries per call, and `nav.in_scope` calls it once per candidate per
    // lookup -- invisible when a completion asked once, and 2.3 s for the
    // highlighter's pass over every identifier in `src/y/native.y`.
    //
    // Built here rather than in the caller so every consumer gets it: completion,
    // go-to-definition and hover all call `in_scope` too.
    scope_ends: { long => long }
};

// The packed end of the scope that begins at `start`, or -1 if it has not
// closed (or `start` is -1, meaning top level, which never ends).
def scope_end(ends: { long => long }, start: long) -> long {
    let out = -1;
    if (start >= 0) {
        let got = ends[start];
        if is_some(got) { out = got !; };
    };
    out
}

// The start -> end map for a `closed` pair list. A scope that has not closed has
// no entry, which is the -1 `scope_end` returns and `in_scope` reads as "still
// open".
def scope_end_map(closed: [long]) -> { long => long } {
    let out: { long => long } = {};
    let i = 0;
    while (i + 1 < len(closed)) {
        out[closed[i]] = closed[i + 1];
        i = i + 2;
    };
    out
};

// ── the documentation comment above a declaration ───────────────────────
//
// The lines immediately above it that are all comments, blank lines skipped once
// at most. It is what makes a completion item's `documentation` worth showing,
// and it is worth getting right in the common case (a doc comment directly above)
// rather than the general one.
// `d` is the caller's SrcDoc, passed in rather than rebuilt here: doc_above
// walks upward one line at a time and pos.doc_of re-reads the whole buffer, so
// deriving it from `src` inside the loop rebuilt the index once per line of
// doc comment above every declaration in the file.
def doc_above(src: str, line: long, d: SrcDoc) -> str {
    let out: [str] = [];
    // `line` is 0-based; the comment lines are at line-1, line-2, ...
    let k = line - 1;
    let blanks = 0;
    // Walking up through a block comment. The test for a continuation line has
    // to run on the RAW line: `trim_both` eats the leading space, so ` * foo`
    // becomes `* foo` and can never match ` *` -- which is why a multi-line
    // `/** ... */` contributed an empty doc until this walked the raw text.
    let inblock = false;
    let go = true;
    while (go && k >= 0) {
        let text = pos.doc_line(d, k + 1);
        let t = trim_both(text);
        let star = first_is_star(text);
        let closes = t[:2] == "/*" || t[:len(t)] == "*/" ||
            (len(t) >= 2 && t[len(t) - 2:len(t)] == "*/");
        if (t == "") {
            blanks = blanks + 1;
            if (blanks > 1) { go = false; }
        } else if (t[:2] == "//") {
            let body = trim_both(t[2:]);
            // drop a leading "Name:" or "Name --" so the tooltip is not
            // "f -- does a thing" when the signature already says `f`
            let cut = 0;
            let colon = index_of(body, ":");
            let dash = index_of(body, " --");
            if (colon > 0 && colon < 24 && is_nameish(body[:colon])) { cut = colon + 1; }
            else if (dash > 0 && dash < 24 && is_nameish(body[:dash])) { cut = dash + 3; }
            let piece = trim_both(body[cut:]);
            out += piece;
        } else if (inblock || t[:2] == "/*" || (star && closes)) {
            // a block comment: the opus line, a continuation, or the closer. The
            // FIRST line above the declaration has to look like the end of one
            // (`*/`), so a `*p = 1;` statement above a def is not mistaken for a
            // doc line.
            let opens = t[:2] == "/*";
            let body = t;
            if (body[:2] == "/*") { body = body[2:]; }
            if (body[:1] == "*") { body = body[1:]; }
            if (body[:1] == " ") { body = body[1:]; }
            out += trim_both(trim_end_star(body));
            if (opens) { go = false; } else { inblock = true; };
        } else {
            go = false;
        }
        k = k - 1;
    }
    // the lines came out bottom-up
    let rev: [str] = [];
    let i = len(out) - 1;
    while (i >= 0) { rev += out[i]; i = i - 1; }
    let text = join(rev, "\n");
    trim_both(text)
}

// Is the first non-blank byte of a raw line `*`? A block comment's continuation
// lines have one, and `trim_both` would have removed the space that says so.
def first_is_star(text: str) -> bool {
    let i = 0;
    while (i < len(text) && (byte_at(text, i) == 32 || byte_at(text, i) == 9)) { i = i + 1; };
    i < len(text) && byte_at(text, i) == 42
};

// Whether `s` looks like a bare name, so "f --" is a label and "the thing --" is
// prose.
def is_nameish(s: str) -> bool {
    let ok = s != "" && len(s) <= 24;
    let i = 0;
    while (ok && i < len(s)) {
        let c = byte_at(s, i);
        if (!((c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || c == 95)) {
            ok = false;
        }
        i = i + 1;
    }
    ok
}

def trim_both(s: str) -> str {
    let a = 0;
    let b = len(s);
    let go = true;
    while (go && a < b) {
        let c = byte_at(s, a);
        if (c == 32 || c == 9 || c == 10 || c == 13) { a = a + 1; } else { go = false; }
    }
    go = true;
    while (go && b > a) {
        let c = byte_at(s, b - 1);
        if (c == 32 || c == 9 || c == 10 || c == 13) { b = b - 1; } else { go = false; }
    }
    s[a:b]
}

// Drop the `*/` (or a lone `/`) a block comment's last line ends with, then a
// trailing `*` left by a ` */` line: a one-line `/** doc */` must read as
// `doc`, not `doc *`.
def trim_end_star(s: str) -> str {
    let t = s;
    let n = len(t);
    if (n >= 2 && byte_at(t, n - 2) == 42 && byte_at(t, n - 1) == 47) {
        t = t[0:n - 2];
    } else if (n > 0 && byte_at(t, n - 1) == 47) {
        t = t[0:n - 1];
    };
    t = trim_both(t);
    let m = len(t);
    if (m > 0 && byte_at(t, m - 1) == 42) { t = trim_both(t[0:m - 1]); };
    t
}

// ── the pass ────────────────────────────────────────────────────────────

// Index one file's source.
// Is this span the single punctuation character `c`?
//
// Compared by BYTE, not by `src[s.off:s.end] == "("`. The slice allocates, and
// in_params walks up to 80 spans back for every identifier it is asked about:
// over src/y that is millions of one-character allocations, and nothing in this
// program frees.
def is_char(s: Span, src: str, c: byte) -> bool {
    let out = false;
    if (s.end - s.off == 1) {
        if (byte_at(src, s.off) == c) { out = true; };
    };
    out
}

// The punctuations the walks below look for, as bytes. Written as numbers
// because a '(' literal reads as a character and these are compared as bytes,
// and a reader should not have to work out which.
const CH_COMMA = 44;
const CH_LP = 40;
const CH_RP = 41;
const CH_LB = 91;
const CH_RB = 93;
const CH_LC = 123;
const CH_RC = 125;
const CH_SEMI = 59;

// Could span `i` be a parameter NAME? One step back: a parameter is always
// immediately after a `(` or a `,`.
//
// The guard is not an optimisation, it is what makes the pass finish. Called for
// every identifier in a file, `in_params` is ~2.2M calls over src/y, and it is
// the runtime's FRAMES that exhaust the heap (nothing here frees): with no
// guard at all, `index_src` reported "out of memory" on parser.y having indexed
// eight parameters. One step back rejects all but the identifiers that really
// can be parameters, so `in_params` runs a few hundred times per file.
def maybe_param(sps: [Span], src: str, i: long) -> bool {
    let out = false;
    if (i > 0) {
        let p = sps[i - 1];
        if (is_char(p, src, CH_LP) || is_char(p, src, CH_COMMA)) { out = true; };
    };
    out
}

def index_src(src: str, path: str) -> FileIdx {
    let d = pos.doc_of(src);
    let r = scan.scan_full(src);
    let sps = r.spans;
    let decls: [IdxDecl] = [];
    // the stack of open scopes, each a packed position
    let opens: [long] = [];
    // and, as each one closes, where it closed: see FileIdx.closed
    let closed: [long] = [];
    let depth = 0;

    // the pending `def`, so its `}` can close it
    let open_def: [IdxDecl] = [];

    // The parameters of the `def` being read, which have no scope yet.
    //
    // A parameter's scope is its function's BODY, and the body's `{` comes after
    // the parameter list closes -- so when the parameter is recorded the brace
    // stack is empty and there is nothing to record, and `scope_start` stays -1,
    // which would make the parameter visible for the rest of the file.
    //
    // Resolving it in a second pass, one backward walk per parameter to find the
    // list's `(` and then the brace after it, is ~5.4M calls over src/y and ran
    // the heap out on types.y. So it is done here instead: collect the parameters
    // as they are read, and the `{` that opens the body IS their scope. One
    // assignment each, no walk.
    let pending_params: [IdxDecl] = [];

    let i = 0;
    while (i < len(sps)) {
        let s = sps[i];

        if (s.kind == scan.K_punct && src[s.off:s.end] == "{") {
            depth = depth + 1;
            // pos.to_lsp, NOT pos_key(s.line, s.col): a span's line and column are
            // the compiler's 1-based ones, and packing them raw put every
            // `scope_start` one line BELOW the declaration it belongs to -- so
            // `let` inside a block looked as though it were declared after the
            // block's first line, and a use on the `{` line was judged to be
            // before the scope it is in.
            let op = pos.doc_to_lsp(d, s.line, s.col);
            let pk = pos_key(op.line, op.character);
            opens += pk;
            if (len(pending_params) > 0) {
                let q = 0;
                while (q < len(pending_params)) {
                    pending_params[q].scope_start = pk;
                    q = q + 1;
                };
                pending_params = [];
            };
            i = i + 1;
        } else if (s.kind == scan.K_punct && src[s.off:s.end] == "}") {
            depth = depth - 1;
            if (len(opens) > 0) {
                let started = opens[len(opens) - 1];
                opens = opens[0:len(opens) - 1];
                let cl = pos.doc_to_lsp(d, s.line, s.col);
                closed += started;
                closed += pos_key(cl.line, cl.character);
            };
            if (len(open_def) > 0) {
                let fin = open_def[len(open_def) - 1];
                open_def = open_def[0:len(open_def) - 1];
                let e = pos.doc_to_lsp(d, s.line, s.col);
                fin.end_line = e.line;
                fin.end_ch = e.character;
            }
            i = i + 1;
        } else {
            let w = scan_word(src, s);
            if (w == "def") {
                pending_params = [];
                let dd = decl_after(sps, src, i, path, D_DEF, depth, opens, d);
                if (is_some(dd)) {
                    let one = dd !;
                    one.doc = doc_above(src, s.line - 1, d);
                    decls += one;
                    open_def += one;
                    i = i + 2;
                } else { i = i + 1; }
            } else if (w == "let" || w == "const") {
                let k = D_LET;
                if (w == "const") { k = D_CONST; }
                let dd = decl_after(sps, src, i, path, k, depth, opens, d);
                if is_some(dd) {
                    let one = dd !;
                    one.doc = doc_above(src, s.line - 1, d);
                    decls += one;
                    i = i + 2;
                } else { i = i + 1; }
            } else if (w == "type") {
                let dd = decl_after(sps, src, i, path, D_TYPE, depth, opens, d);
                if is_some(dd) {
                    let one = dd !;
                    one.doc = doc_above(src, s.line - 1, d);
                    decls += one;
                    i = i + 2;
                } else { i = i + 1; }
            } else if (w == "import") {
                let dd = decl_after(sps, src, i, path, D_IMPORT, depth, opens, d);
                if is_some(dd) {
                    let one = dd !;
                    one.detail = import_target(sps, src, i);
                    decls += one;
                    i = i + 2;
                } else { i = i + 1; }
            } else if (w == "def" || w == "fn") {
                i = i + 1;
            } else {
                // A parameter: an identifier inside a `def`'s parameter list,
                // found by looking BACKWARD to the `(` of the def's own header --
                // in_params checks for `def` and the name before it, which is
                // what separates `def f(a: long)` from `a` in the body.
                //
                // NO `depth > 0`, and dropping it was worth 40% of every file. A
                // parameter list opens BEFORE the body's `{`, so the brace depth
                // at a parameter is the depth of the def's own surroundings --
                // zero at the top level -- and the test threw away exactly the
                // parameters it was after. Measured over src/y, the most frequent
                // name the whole index could not resolve was `st`, 5,451 times,
                // then `node`, `k`, `line`, `col`: every parameter use in the
                // compiler.
                if (s.kind == scan.K_ident && maybe_param(sps, src, i) && in_params(sps, src, i)) {
                    let p = pos.doc_to_lsp(d, s.line, s.col);
                    let one: IdxDecl = {
                        name: src[s.off:s.end], kind: D_PARAM, file: path,
                        line: p.line, ch: p.character,
                        end_line: p.line, end_ch: p.character + len(src[s.off:s.end]),
                        detail: param_detail(sps, src, i), doc: "",
                        depth: depth, scope_start: -1, scope_end: -1, order: i
                    };
                    decls += one;
                    pending_params += one;
                }
                i = i + 1;
            }
        }
    }
    // Fill in each declaration's scope end, now that every `}` has been seen.
    //
    // One linear pass, done once per index, so that `nav.in_scope` -- which asks
    // this of every candidate of every lookup -- is two comparisons and an integer
    // test. It used to ask `scope_end` per candidate, and the highlighter's pass
    // over every identifier in `src/y/native.y` cost 2.0 s for that alone.
    let ends = scope_end_map(closed);
    let di = 0;
    while (di < len(decls)) {
        let dcl = decls[di];
        if (dcl.scope_start >= 0) {
            let got = ends[dcl.scope_start];
            let e = -1;
            if is_some(got) { e = got !; };
            dcl.scope_end = e;
            decls[di] = dcl;
        };
        di = di + 1;
    };
    let f: FileIdx = { path: path, decls: decls, opens: opens, closed: closed, scope_ends: ends };
    f
}

def scan_word(src: str, s: Span) -> str {
    let out = "";
    if (s.kind == scan.K_ident || s.kind == scan.K_keyword || s.kind == scan.K_contextual) {
        out = src[s.off:s.end];
    }
    out
}

def pos_key(line: long, col: long) -> long { line * 1000000 + col }

// The declaration introduced by the keyword at span index `i`, if the next span
// is a name.
def decl_after(sps: [Span], src: str, i: long, path: str, kind: long, depth: long, opens: [long], d: SrcDoc) -> IdxDecl? {
    let out: IdxDecl? = none;
    let ni = i + 1;
    if (ni < len(sps) && sps[ni].kind == scan.K_ident) {
        let nm = src[sps[ni].off:sps[ni].end];
        let a = pos.doc_to_lsp(d, sps[ni].line, sps[ni].col);
        let scope = -1;
        if (len(opens) > 0) { scope = opens[len(opens) - 1]; }
        let det = "";
        if (kind == D_DEF) { det = header_text(sps, src, ni); }
        else if (kind == D_LET || kind == D_CONST) { det = annotation_text(sps, src, ni); }
        let one: IdxDecl = {
            name: nm, kind: kind, file: path,
            line: a.line, ch: a.character,
            end_line: a.line, end_ch: a.character + len(nm),
            detail: det, doc: "",
            depth: depth, scope_start: scope, scope_end: -1, order: ni
        };
        out = some(one);
    }
    out
}

// A `def`'s header as written: "(x: long) -> long".
def header_text(sps: [Span], src: str, name_i: long) -> str {
    let open_i = -1;
    let j = name_i + 1;
    let go = true;
    while (go && j < len(sps) && open_i < 0 && j - name_i < 60) {
        let s = sps[j];
        if (s.kind == scan.K_punct && src[s.off:s.end] == "(") { open_i = j; go = false; }
        else if (s.kind == scan.K_punct && src[s.off:s.end] == "{") { go = false; }
        else if (s.line - sps[name_i].line > 4) { go = false; }
        else { j = j + 1; }
    }
    if (open_i < 0) { return ""; }
    let close_i = open_i;
    let depth2 = 0;
    let k = open_i;
    let paren = true;
    while (paren && k < len(sps)) {
        let s = sps[k];
        // `k` advances on EVERY branch. Leaving it off the `(` one made this
        // an infinite loop: k starts AT open_i, which is a `(`, so depth2 grew
        // without k ever moving, and the `src[s.off:s.end]` in the test
        // allocated a fresh one-character string every pass until the heap ran
        // out. Any def with a parameter list -- `def f() -> long { 1 }` -- hit
        // it, so `index_src` reported "out of memory" on almost every input.
        if (s.kind == scan.K_punct && src[s.off:s.end] == "(") { depth2 = depth2 + 1; k = k + 1; }
        else if (s.kind == scan.K_punct && src[s.off:s.end] == ")") {
            depth2 = depth2 - 1;
            if (depth2 == 0) { close_i = k; paren = false; } else { k = k + 1; }
        } else { k = k + 1; }
    }
    let out = src[sps[open_i].off:sps[close_i].end];
    // and the return type, if one was written
    let r = close_i + 1;
    let found_arrow = false;
    while (r < len(sps) && r < close_i + 12) {
        let s = sps[r];
        if (s.kind == scan.K_punct && (src[s.off:s.end] == "{" || src[s.off:s.end] == ";")) {
            break;
        } else if (s.kind == scan.K_operator && src[s.off:s.end] == "->") {
            found_arrow = true;
            break;
        } else {
            r = r + 1;
        }
    }
    if (found_arrow) {
        // The return type runs from just after the `->` to the `{` or the `;`
        // that ends the header. Collected as a span range and tested with
        // `last > first`, which means "at least one span was taken".
        //
        // The test used to be `last > r + 2`, which is off by one and dropped the
        // return type whenever it was a SINGLE word -- `def f() -> long {` --
        // which is most defs. The type was there the whole time, at `r + 1`; the
        // comparison just never admitted it. So every hover in this server showed
        // a signature with no return type, and it read as though the language had
        // none.
        let first = r + 1;
        let last = first;
        while (last < len(sps)) {
            let t = sps[last];
            if (t.kind == scan.K_punct && (src[t.off:t.end] == "{" || src[t.off:t.end] == ";")) { break; }
            last = last + 1;
        }
        if (last > first) {
            out += " -> " + trim_both(src[sps[first].off:sps[last - 1].end]);
        }
    }
    out
}

// A binding's annotation as written: ": long". Empty when there is none, which
// is the honest answer -- a bare `let x = 1` has nothing written to show.
def annotation_text(sps: [Span], src: str, name_i: long) -> str {
    colon_tail(sps, src, name_i, "=", 2)
}

// A parameter's own annotation: ": long" after the name.
def param_detail(sps: [Span], src: str, i: long) -> str {
    colon_tail(sps, src, i, ",", 3)
}

// The text from a `:` after the name at span index `name_i` up to `stopper` (a
// punctuation token) or `max_lines` lines, whichever comes first. Shared by a
// binding's annotation and a parameter's, which differ only in what ends them.
def colon_tail(sps: [Span], src: str, name_i: long, stopper: str, max_lines: long) -> str {
    let out = "";
    let j = name_i + 1;
    let has_colon = false;
    if (j < len(sps) && sps[j].kind == scan.K_punct && src[sps[j].off:sps[j].end] == ":") { has_colon = true; }
    if (has_colon) {
        let last = j + 1;
        let go = true;
        while (go && last < len(sps)) {
            let t = sps[last];
            if (t.kind == scan.K_punct) {
                let c = src[t.off:t.end];
                if (c == stopper || c == ")" || c == ";" || c == "{" || c == "=") { go = false; }
                else { last = last + 1; }
            } else if (t.line - sps[name_i].line > max_lines) { go = false; }
            else { last = last + 1; }
        }
        if (last > j + 1) { out = trim_both(src[sps[j].off:sps[last - 1].end]); }
    }
    out
}

// `import m from "./m.y"` -> "./m.y"; `import fs;` -> "" (a std module).
def import_target(sps: [Span], src: str, i: long) -> str {
    let out = "";
    let j = i + 2;
    let go = true;
    while (go && j < len(sps) && j < i + 8) {
        let s = sps[j];
        if (s.kind == scan.K_punct && src[s.off:s.end] == ";") { go = false; }
        else if (s.kind == scan.K_string) { out = src[s.off + 1:s.end - 1]; go = false; }
        else { j = j + 1; }
    }
    out
}

// Whether the identifier at span index `i` sits inside a parameter list.
//
// Backward scan: the nearest enclosing bracket must be `(` and it must be part of
// a header -- no `;` and no `}` between them. A `(` in a call is preceded by an
// identifier, so "no identifier between the `(` and here" separates the two.
// Is the `(` at span index k the parameter list of a `def`?
//
// The test that was here first -- "the token after the `(` is an identifier" --
// is true of every call in the program: walking back from an argument reaches
// the call's own `(`, and the argument is an identifier right after it. So
// `print(shared)` indexed `shared` as a PARAMETER of the enclosing def, and a
// jump on it landed on the use instead of on `let shared` a line away.
//
// What tells a parameter list apart is what comes BEFORE the `(`: `def`, then
// the def's name. Comments may sit between them (scan_full keeps comments as
// spans), so they are stepped over.
def def_params_at(sps: [Span], src: str, k: long) -> bool {
    let out = false;
    let j = k - 1;
    while (j >= 0 && sps[j].kind == scan.K_comment) { j = j - 1; };
    // `def (`: an ANONYMOUS def -- a function literal, `let mul = def (a: long)
    // -> long { ... }`. `def` on its own cannot be anything else, because a
    // `ndef` must be named and a named def has a name here.
    //
    // Without this the parameters of every closure in a file were unindexed, and
    // that is not a rare shape: it is how a lambda is written in Y, and the first
    // thing to break is the semantic token painting `a` in `(a: long)` as an
    // ordinary variable while the same `a` in a `def f(a: long)` is a parameter.
    if (j >= 0 && sps[j].kind == scan.K_keyword) {
        let w0 = src[sps[j].off:sps[j].end];
        if (w0 == "def") { out = true; };
    };
    // the def's name
    if (j >= 0 && sps[j].kind == scan.K_ident) {
        j = j - 1;
        while (j >= 0 && sps[j].kind == scan.K_comment) { j = j - 1; };
        if (j >= 0 && sps[j].kind == scan.K_keyword) {
            let w = src[sps[j].off:sps[j].end];
            if (w == "def" || w == "fn") { out = true; };
        };
    };
    out
}

def in_params(sps: [Span], src: str, i: long) -> bool {
    let out = false;
    let level = 0;
    let k = i - 1;
    let steps = 0;
    while (k >= 0 && steps < 80) {
        let s = sps[k];
        if (is_char(s, src, CH_RP) || is_char(s, src, CH_RB) || is_char(s, src, CH_RC)) {
            level = level + 1;
        } else if (is_char(s, src, CH_LP)) {
            if (level == 0) {
                out = def_params_at(sps, src, k);
                k = -1;
            } else { level = level - 1; }
        } else if (is_char(s, src, CH_SEMI)) {
            k = -1;
        } else if (is_char(s, src, CH_LB) || is_char(s, src, CH_LC)) {
            if (level == 0) { k = -1; }
        };
        k = k - 1;
        steps = steps + 1;
    }
    out
}

export {
    D_DEF, D_LET, D_CONST, D_PARAM, D_TYPE, D_IMPORT, D_SELF,
    IdxDecl, FileIdx, index_src, doc_above, trim_both, is_nameish,
    header_text, annotation_text, param_detail, colon_tail, import_target, scope_end, scope_end_map,
    in_params, scan_word, pos_key
};
