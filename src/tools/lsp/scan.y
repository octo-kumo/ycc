// Span adapter over the compiler lexer, retaining comments and lexical errors.
import lexer from "../../y/lexer.y";

// ── span kinds ──────────────────────────────────────────────────────────
// Numeric so the formatter and outline can compare kinds without string
// comparisons. These are syntactic classes only.
const K_comment = 1;      // // and /* */ both
const K_string = 2;       // "..."
const K_bstring = 3;      // b"..." b'...'
const K_char = 4;         // 'x'
const K_fstring = 5;      // f"...{expr}..."
const K_number = 6;       // 12, 1.5, 1e10, 0x1f, 0b1010, 0o755, 12n, 129b
const K_ident = 7;        // anything not in the keyword list
const K_keyword = 8;      // reserved words
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

def is_keyword(w: str) -> bool { lexer.lex_reserved(w) }
def is_contextual(w: str) -> bool { lexer.lex_contextual(w) }

// The span kind of one lexer token; K_none for one with no span (eof).
def kind_of(src: str, tk: Tok) -> long {
    let t = tk.t;
    let k = K_none;
    if (t == K.comment) { k = K_comment; }
    if (t == K.doc) { k = K_doc; }
    if (t == K.str) { k = K_string; }
    if (t == K.fstr) { k = K_fstring; }
    if (t == K.bstr) { k = K_bstring; }
    if (t == K.char) {
        // `'a'` is a char; `129b` is the SAME token type in the lexer (both
        // build the byte node) and is a number to every reader
        if (tk.off < len(src) && byte_at(src, tk.off) == '\'') { k = K_char; } else { k = K_number; }
    }
    if (t == K.num || t == K.bigint) { k = K_number; }
    if (t == K.id) { if (is_contextual(tk.v)) { k = K_contextual; } else { k = K_ident; } }
    if (t == K.kw) { k = K_keyword; }
    if (t == K.op) { k = K_operator; }
    if (t == K.punct) { k = K_punct; }
    if (t == K.ferr || t == K.stray) { k = K_error; }
    // The ordinary lexer runs after meta expansion; editor spans see the source.
    if (t == K.stray && tk.v == "#") {
        if ((tk.end < len(src) && src[tk.end] == '{') ||
            (tk.off > 0 && src[tk.off - 1] == '}')) { k = K_operator; };
    };
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
    if (line < 1 || line > len(starts)) { return -1; }
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
