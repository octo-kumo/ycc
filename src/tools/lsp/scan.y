// scan.y -- the server's NAME for what the compiler's lexer found.
//
// This used to be a second byte-level scanner, written because the lexer's own
// output was not usable here: it discards comments, it desugars f-strings into
// `#fmt(...)` calls with no source extent, and it calls exit(1) on an
// unterminated string or block comment -- which in a server is a process death
// on the first `"` the user types.
//
// Those are all modes of ONE scanner rather than reasons for two. lexer.y now
// has `tokenize_lsp`, the compiler's own loop with comments kept, an f-string
// whole, byte spans on every token, and an error token where the compiler
// would exit. So this file holds no lexing rules at all: it maps a token to a
// span KIND (the numeric constants below, which the semantic-token legend and
// the formatter index by) and hands the compiler's byte span through.
//
// WHY THIS IS NOT JUST `lexer.tokenize`: the compiler's entry point stays
// exactly what it was -- comments dropped, f-strings desugared, a malformed
// literal fatal -- because the parser and the port gate are defined on that
// stream. `tokenize_lsp` is the same code with those three things turned
// around.
//
// There IS a second consumer of the compiler's tokenizer here (diag.y, for
// diagnostics, and xref.y, for references); both run the real pipeline. This
// file is what the token-level features read: highlighting, hover ranges,
// the formatter.

import lexer from "../../y/lexer.y";

// ── span kinds ──────────────────────────────────────────────────────────
// Numeric so the map to an LSP semantic-token type is one table. These are
// syntactic classes only: variable / parameter / function / method / type /
// builtin need the checker's index (LSP.md §9.2) and are layered on later.
const K_comment = 1;      // // and /* */ both
const K_string = 2;       // "..."
const K_bstring = 3;      // b"..." b'...'
const K_char = 4;         // 'x'
const K_fstring = 5;      // f"...{expr}..."
const K_number = 6;       // 12, 1.5, 1e10, 0x1f, 0b1010, 0o755, 12n, 129b
const K_ident = 7;        // anything not in the keyword list
const K_keyword = 8;      // the twelve reserved words
const K_contextual = 9;   // match, type, spawn, ...: words, not keywords
const K_operator = 10;
const K_punct = 11;       // ( ) { } [ ] , ; :
const K_error = 12;       // a literal that is not closed, or a stray byte
const K_doc = 13;         // /** ... */ -- a doc comment (docs/src/02-lexical.tex)
const K_none = 0;         // whitespace and comments-of-no-account: not a span

type Span = { off: long, end: long, kind: long, line: long, col: long };

// The lexer appends one of these to every token stream, and never a span.
def sp(off: long, end: long, kind: long, line: long, col: long) -> Span {
    { off: off, end: end, kind: kind, line: line, col: col }
}

// ── the adapter ─────────────────────────────────────────────────────────
//
// ONE classifier, and it is the compiler's: lexer.tokenize_lsp, the same
// scanner that feeds the parser, in server mode -- comments kept, an f-string
// whole, a malformed literal a token instead of an exit, and a byte span on
// every token. This file only NAMES what the lexer found; it decides nothing.
//
// There is no second scanner here any more. There used to be, and it drifted:
// it lexed `0o755` as `0` then `o755` (the compiler's lexer had learned octal
// and this had not), which the formatter then wrote back to disk as `0 o755`.
// A test (test-agree.sh) compared the two, and a comparison is a weaker
// guarantee than not having two things to compare (LSP.md section 5.1).

// The twelve reserved words, and the words the parser gives a meaning to in
// one shape. The lexer says which is which; these are the two tables the
// server needs to name a span.
def is_keyword(w: str) -> bool {
    w == "let" || w == "const" || w == "def" || w == "if" || w == "else" ||
    w == "while" || w == "for" || w == "foreach" || w == "in" || w == "return" ||
    w == "break" || w == "continue" || w == "ndef" || w == "true" || w == "false"
}

def is_contextual(w: str) -> bool {
    w == "match" || w == "type" || w == "spawn" || w == "fork" ||
    w == "lock" || w == "try_lock" || w == "join" || w == "post" ||
    w == "wait" || w == "mutex" || w == "sem" || w == "self" ||
    w == "none" || w == "import" || w == "export"
}

// The span kind of one lexer token; K_none for one with no span (eof).
def kind_of(src: str, tk: Tok) -> long {
    let t = tk.t;
    let k = K_none;
    if (t == "comment") { k = K_comment; }
    if (t == "doc") { k = K_doc; }
    if (t == "str") { k = K_string; }
    if (t == "fstr") { k = K_fstring; }
    if (t == "bstr") { k = K_bstring; }
    if (t == "char") {
        // `'a'` is a char; `129b` is the SAME token type in the lexer (both
        // build the byte node) and is a number to every reader
        if (tk.off < len(src) && byte_at(src, tk.off) == '\'') { k = K_char; } else { k = K_number; }
    }
    if (t == "num" || t == "bigint") { k = K_number; }
    if (t == "id") { if (is_contextual(tk.v)) { k = K_contextual; } else { k = K_ident; } }
    if (t == "kw") { k = K_keyword; }
    if (t == "op") { k = K_operator; }
    if (t == "punct") { k = K_punct; }
    if (t == "ferr" || t == "stray") { k = K_error; }
    k
}

def scan_full(src: str) -> { spans: [Span], bad: [Span] } {
    let toks = lexer.tokenize_lsp(src);
    let spans: [Span] = [];
    let bad: [Span] = [];
    let i = 0;
    while (i < len(toks)) {
        let tk = toks[i];
        let k = kind_of(src, tk);
        if (k != K_none) {
            let one = sp(tk.off, tk.end, k, tk.line, tk.col);
            spans += one;
            if (k == K_error) { bad += one; };
        };
        i = i + 1;
    };
    { spans: spans, bad: bad }
}

def scan(src: str) -> [Span] {
    scan_full(src).spans
}

// A name for a kind, for a diagnostic or a test.
def kind_name(k: long) -> str {
    let n = "?";
    if (k == K_comment) { n = "comment"; }
    if (k == K_doc) { n = "doc"; }
    if (k == K_string) { n = "string"; }
    if (k == K_bstring) { n = "bstring"; }
    if (k == K_char) { n = "char"; }
    if (k == K_fstring) { n = "fstring"; }
    if (k == K_number) { n = "number"; }
    if (k == K_ident) { n = "ident"; }
    if (k == K_keyword) { n = "keyword"; }
    if (k == K_contextual) { n = "contextual"; }
    if (k == K_operator) { n = "operator"; }
    if (k == K_punct) { n = "punct"; }
    if (k == K_error) { n = "error"; }
    n
}

// ── positions ───────────────────────────────────────────────────────────
//
// The compiler's positions are 1-based with the column counted in BYTES, and
// Tok carries no byte offset at all (lexer.y's `type Tok` is {t, v, line,
// col}). That is not a blocker: the splicer keeps whole lines, so the column is
// already a byte offset within the line, and one table of line-start offsets
// converts in both directions. This is why nothing in lexer.y has to change.

// Byte offset of the start of each 1-based line: out[0] is line 1, out[1] is
// line 2, and so on. One entry per line, including the last even when the text
// does not end in a newline.
def line_starts(src: str) -> [long] {
    let out: [long] = [];
    out += 0;
    let i = 0;
    let n = len(src);
    while (i < n) {
        if (byte_at(src, i) == '\n') { out += i + 1; }
        i = i + 1;
    }
    out
}

// Byte offset of a 1-based (line, byte-column), or -1 if the line is past the
// end.
def off_at(src: str, line: long, col: long) -> long {
    let starts = line_starts(src);
    if (line < 1 || line > len(starts)) { return 0 - 1; }
    starts[line - 1] + (col - 1)
}

// ── tolerance ───────────────────────────────────────────────────────────
//
// `repair` is what the server runs before the compiler does (LSP.md R1.10).
// The lexer calls exit(1) on an unterminated string or block comment, which in
// a server is fatal; instead we report the span as a diagnostic and return a
// buffer with the literal closed, so the rest of the document still checks.
// The editor's own buffer is never modified -- this is a copy.

def repair(src: str) -> { text: str, bad: [Span] } {
    let r = scan_full(src);
    let bad = r.bad;
    let text = src;
    let k = len(bad);
    while (k > 0) {
        k = k - 1;
        let b = bad[k];
        let ch = 0;
        if (b.off < len(src)) { ch = byte_at(src, b.off); }
        if (ch == 47) {
            text = text[0:b.end] + "*/" + text[b.end:];
        } else if (b.kind == K_fstring) {
            text = text[0:b.end] + "\"" + text[b.end:];
        } else if (ch == 34 || ch == 39) {
            text = text[0:b.end] + chr(ch) + text[b.end:];
        } else if (ch == 40) {
            text = text[0:b.end] + ")" + text[b.end:];
        }
    }
    { text: text, bad: bad }
}

export {
    Span, K_none, K_comment, K_string, K_bstring, K_char, K_fstring, K_number,
    K_ident, K_keyword, K_contextual, K_operator, K_punct, K_error,
    scan, scan_full, repair, kind_name, line_starts, off_at,
    is_keyword, is_contextual
};
