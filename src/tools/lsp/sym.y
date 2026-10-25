// sym.y -- document symbols for the outline (VS Code's breadcrumb bar).
//
// `textDocument/documentSymbol` is what an editor reads to fill its outline, and
// "no symbols found in document" is what it says when this returns nothing. It
// needs no compiler change and no type information: an outline is names and
// where they are, and the names are in the text.
//
// Built from scan.y spans, so it works on a buffer that does not lex and cannot
// disagree with the highlighter about where a token begins.
//
// ── the structure ──
//
// Hierarchical, because the protocol has two shapes and the hierarchical one is
// the one VS Code renders as a tree. A top-level `def` is a DocumentSymbol whose
// children are the `def`s, `let`s and `const`s inside its body. A flat list would
// render, but it would put a local next to a top-level function, which is worse
// than having no outline.
//
// What is deliberately NOT a symbol: a `let` inside a `for` or an `if`. An outline
// of every assignment is noise, and the breadcrumb bar is only useful while it
// stays short. `def`, `const`, `let`, `type`, `import` and `export` are.
//
// ── how the tree is built ──
//
// One left-to-right pass over the spans, with a stack of the `def`s whose bodies
// are currently open. Because a Y record is a REFERENCE, pushing a symbol onto
// the stack and the same value into its parent array share one object, so the
// `}` that closes a body can fill in the range of the symbol already sitting in
// the tree -- verified, not assumed: mutating through either path is visible
// through the other (t011 checks it, because the whole design rests on it).

import scan from "./scan.y";
import pos from "./pos.y";

// LSP SymbolKind. These numbers are a wire format, not ours to renumber.
const K_MODULE = 2;
const K_FUNCTION = 12;
const K_VARIABLE = 13;
const K_CONSTANT = 14;
const K_TYPE = 23;         // 'Class' in the protocol; Y's `type` is closest
const K_KEY = 20;

type SymEntry = {
    name: str,
    detail: str,          // the parameter list and return type, as written
    kind: long,
    line: long,           // 0-based, as the protocol wants
    ch: long,
    end_line: long,
    end_ch: long,
    sel_line: long,       // where the NAME is, for "go to symbol"
    sel_ch: long,
    children: [SymEntry]
};

// ── helpers over the span list ──────────────────────────────────────────

def is_punct_ch(s: Span, src: str, c: str) -> bool {
    let ok = false;
    if (s.kind == scan.K_punct && s.end == s.off + 1) {
        if (src[s.off:s.end] == c) { ok = true; }
    }
    ok
}

def is_word_ch(s: Span, src: str, w: str) -> bool {
    let ok = false;
    if (s.kind == scan.K_ident || s.kind == scan.K_keyword || s.kind == scan.K_contextual) {
        if (src[s.off:s.end] == w) { ok = true; }
    }
    ok
}

def sym_word(s: Span, src: str) -> str {
    let out = "";
    if (s.kind == scan.K_ident || s.kind == scan.K_keyword || s.kind == scan.K_contextual) {
        out = src[s.off:s.end];
    }
    out
}

// The `{` that opens the body of the `def` whose name ends at span index `i`.
// Bounded by the next `;`, a blank line or a few lines on: a `def` written as
// `def f() -> long` and then a `{` on the next line is found, and one whose
// parameter list spans pages does not swallow the file looking for it.
def body_open(sps: [Span], src: str, i: long) -> long {
    let out = -1;
    let base = sps[i].line;
    let j = i + 1;
    let go = true;
    while (go && j < len(sps)) {
        let s = sps[j];
        if (is_punct_ch(s, src, "{")) { out = j; go = false; }
        else if (is_punct_ch(s, src, ";")) { go = false; }
        else if (s.line - base > 8) { go = false; }
        else { j = j + 1; }
    }
    out
}

// The text of a `def`'s signature: from the `(` after its name to the `)` that
// closes the parameter list, plus the return type after it. Brace-matched, so a
// default value containing brackets does not confuse it.
def signature(sps: [Span], src: str, name_i: long, open_i: long) -> str {
    let out = "";
    if (open_i < 0) { return out; }
    // the `(` is the first punctuation span between the name and the `{`
    let open_paren = -1;
    let j = name_i + 1;
    while (j < open_i && j < len(sps)) {
        if (is_punct_ch(sps[j], src, "(")) { open_paren = j; j = open_i; } else { j = j + 1; }
    }
    if (open_paren < 0) { return out; }
    let close_paren = open_paren;
    let depth = 0;
    let k = open_paren;
    let stop = open_i;
    let go = true;
    while (go && k < stop) {
        if (is_punct_ch(sps[k], src, "(")) { depth = depth + 1; }
        else if (is_punct_ch(sps[k], src, ")")) {
            depth = depth - 1;
            if (depth == 0) { close_paren = k; go = false; }
        }
        k = k + 1;
    }
    // and the return type, up to the `{`
    out = src[sps[open_paren].off:sps[close_paren].end];
    let ret = "";
    let r = close_paren + 1;
    while (r < open_i && r < len(sps)) {
        if (is_word_ch(sps[r], src, "->")) {
            let t = src[sps[r].end:sps[open_i].off];
            ret = trim(t);
        }
        r = r + 1;
    }
    if (ret != "") { out += " -> " + ret; }
    out
}

def trim(s: str) -> str {
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

// ── the pass ────────────────────────────────────────────────────────────
// Put a symbol inside the innermost open `def`, or at the top level.
//
// No `&`: a Y array is already a reference, so `out += s` inside this function
// appends to the caller's array. `&out` on a whole array is rejected, and would
// be wrong anyway -- the point is to mutate the binding the caller holds.
//
// The parent is not "whatever was pushed last": a `def` with no body braces is
// never pushed, so it correctly does not become a parent.
def add_child(out: [SymEntry], open: [SymEntry], s: SymEntry) -> long {
    if (len(open) > 0) {
        let parent = open[len(open) - 1];
        parent.children += s;
    } else {
        out += s;
    }
    0
}

// Whether the `{` at span index `j` opens a loop or a conditional body.
//
// The whole statement head is scanned, not just the nearest word, because the
// nearest word before a `for`'s brace is `in`: `for i in 0..3 {` is five spans
// back, and looking back one or two spans finds `3`, `..`, `0`, `in`. `in` is
// not a guard word, so the first version of this let every loop-local `let` into
// the outline -- which is precisely the noise the outline exists to avoid.
//
// Scanning back to the previous `;` or brace is safe against false positives: a
// record literal (`type P = { a: long }`) and a closure body (`spawn { }`) have no
// guard word in their head.
def opens_guard_block(sps: [Span], src: str, j: long) -> bool {
    let out = false;
    let k = j - 1;
    let steps = 0;
    let go = true;
    while (go && k >= 0 && steps < 16) {
        let s = sps[k];
        if (s.kind == scan.K_punct && s.end == s.off + 1) {
            let c = src[s.off:s.end];
            if (c == ";" || c == "{" || c == "}") { go = false; }
        }
        if (go) {
            let w = sym_word(s, src);
            if (w != "" && is_guard_word(w)) { out = true; go = false; }
        }
        k = k - 1;
        steps = steps + 1;
    }
    out
}

def is_guard_word(w: str) -> bool {
    w == "for" || w == "foreach" || w == "while" || w == "if" || w == "else" ||
    w == "match" || w == "lock" || w == "try_lock" || w == "in"
}

// The symbols of a document, outermost first.
def symbols(d: SrcDoc) -> [SymEntry] {
    let src = d.src;
    let out: [SymEntry] = [];
    let r = scan.scan_full(src);
    let sps = r.spans;

    // the `def`s whose body `{` has been seen and whose `}` has not
    let open: [SymEntry] = [];
    // how deep the brace was when each of those bodies opened, so the right `}`
    // is the one that closes it
    let body_depth: [long] = [];
    let depth = 0;
    // how many enclosing blocks are loops or conditionals. A `let` inside one of
    // those is not an outline entry: a breadcrumb bar that lists every
    // assignment is a breadcrumb bar nobody reads. Zero means "directly in a
    // def's body, or at the top level", which is exactly what an outline means.
    let guard = 0;

    let i = 0;
    while (i < len(sps)) {
        let s = sps[i];

        if (is_punct_ch(s, src, "{")) {
            if (opens_guard_block(sps, src, i)) { guard = guard + 1; }
            depth = depth + 1;
            i = i + 1;
        } else if (is_punct_ch(s, src, "}")) {
            depth = depth - 1;
            if (guard > 0) { guard = guard - 1; }
            if (len(open) > 0 && body_depth[len(body_depth) - 1] == depth) {
                let done = open[len(open) - 1];
                open = open[0:len(open) - 1];
                body_depth = body_depth[0:len(body_depth) - 1];
                let e = pos.doc_to_lsp(d, s.line, s.col);
                done.end_line = e.line;
                done.end_ch = e.character;
            }
            i = i + 1;
        } else {
            let w = sym_word(s, src);
            if (w == "def") {
                let nm = "";
                let name_i = i + 1;
                if (name_i < len(sps) && sps[name_i].kind == scan.K_ident) {
                    nm = src[sps[name_i].off:sps[name_i].end];
                }
                if (nm != "") {
                    let bo = body_open(sps, src, i);
                    let detail = signature(sps, src, name_i, bo);
                    let a = pos.doc_to_lsp(d, sps[name_i].line, sps[name_i].col);
                    let sym: SymEntry = {
                        name: nm, detail: detail, kind: K_FUNCTION,
                        line: a.line, ch: a.character,
                        end_line: a.line, end_ch: a.character,
                        sel_line: a.line, sel_ch: a.character,
                        children: []
                    };
                    add_child(out, open, sym);
                    if (bo >= 0) {
                        open += sym;
                        body_depth += depth;
                    }
                    i = i + 2;
                } else { i = i + 1; }
            } else if (w == "const" || w == "type" || w == "import" || w == "export"
                || (w == "let" && guard == 0)) {
                let name_i = i + 1;
                let nm = "";
                if (name_i < len(sps) && sps[name_i].kind == scan.K_ident) {
                    nm = src[sps[name_i].off:sps[name_i].end];
                }
                if (nm != "") {
                    let k = K_VARIABLE;
                    if (w == "const") { k = K_CONSTANT; }
                    if (w == "type") { k = K_TYPE; }
                    if (w == "import" || w == "export") { k = K_MODULE; }
                    let a = pos.doc_to_lsp(d, sps[name_i].line, sps[name_i].col);
                    let sym: SymEntry = {
                        name: nm, detail: "", kind: k,
                        line: a.line, ch: a.character,
                        end_line: a.line, end_ch: a.character + len(nm),
                        sel_line: a.line, sel_ch: a.character,
                        children: []
                    };
                    add_child(out, open, sym);
                    i = i + 2;
                } else { i = i + 1; }
            } else {
                i = i + 1;
            }
        }
    }
    out
}

export {
    SymEntry, K_MODULE, K_FUNCTION, K_VARIABLE, K_CONSTANT, K_TYPE, K_KEY,
    symbols, add_child, signature, body_open, trim, opens_guard_block, is_guard_word,
    is_punct_ch, is_word_ch, sym_word
};
