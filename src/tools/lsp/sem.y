// sem.y -- scan.y's spans as LSP semantic tokens (M2, R2).
//
// Why semantic tokens and not the TextMate grammar: the grammar is a hand-kept
// copy of the language's lexical rules, and it drifts. scan.y already agrees
// with lexer.tokenize byte for byte over the whole corpus (test-agree.sh), so
// highlighting from it is highlighting from the real lexer. It also means a
// buffer that does not lex still highlights -- scan is tolerant, and a stray `#`
// comes back as an error span the editor can paint instead of a blank file
// (R2.5).
//
// ── the wire format ──
//
// `textDocument/semanticTokens/full` returns `data`: a flat array of five
// numbers per token,
//
//     deltaLine, deltaStartChar, length, tokenType, tokenModifiers
//
// where deltaLine is measured from the previous token's LINE and deltaStartChar
// from the previous token's start WHEN THEY ARE ON THE SAME LINE (otherwise from
// column 0). Every position is 0-based and in UTF-16 code units, not bytes --
// pos.y's whole reason for existing.
//
// Three rules the format does not state but enforces, each of which will make an
// editor render nonsense if broken:
//
//   * tokens must be sorted, and must NOT overlap.
//   * a token may not span a line break, so a block comment is one token PER
//     LINE.
//   * `length` must be > 0; a zero-length token is dropped by some clients and
//     misaligns the whole stream in others.

import scan from "./scan.y";
import pos from "./pos.y";

// ── the legend ──────────────────────────────────────────────────────────
//
// The indices here are a wire format shared with the editor, so they are spelled
// out once and never renumbered. The client sends the same list back in its
// initialize; if the two ever disagree, every token after the first difference
// is painted as the wrong kind -- silently, because nothing errors.
//
// Only the SYNTACTIC classes are here. `parameter`, `function`, `method`, `type`
// and `builtin` need to know what a name DENOTES, which is the renamer's and the
// checker's answer rather than the lexer's -- so they are §9.2 / Stage B, and NOT
// M4.
//
// That correction matters because this comment used to say they "come with M4
// (R2.3)", and M4 is delivered. A reader who trusted it would go looking after
// M4 and find `variable` for every identifier, with this file having told them
// the classes were on the way. Until §9.2 lands, `variable` is the honest answer
// for every name: the lexer really does not know what one denotes.
//
// A `y.lsp.semantic` setting on the client turns the whole layer off for users
// who do not want two colours for the same identifier.
const T_comment = 0;
const T_string = 1;
const T_number = 2;
const T_keyword = 3;
const T_selfnone = 4;
const T_operator = 5;
const T_punct = 6;
const T_variable = 7;
const T_error = 8;

// The legend, in index order, for `semanticTokensProvider.legend.tokenTypes`.
//
// A NEW constant above needs an entry HERE, at the same index, or every token
// from it on is painted as whatever sits at that index -- silently, because
// nothing errors: a token type is just a number on the wire and the client
// resolves it against this list. t010_sem pins the length and the order, which
// catches a reorder; it cannot catch a constant added to neither list, because
// nothing reflects over the constants to find one.
def token_types() -> [str] {
    let out: [str] = [];
    out += "comment";
    out += "string";
    out += "number";
    out += "keyword";
    out += "selfNone";
    out += "operator";
    out += "punctuation";
    out += "variable";
    out += "error";
    out
}

// The token type for one scan span. `src` is needed because the CONTEXTUAL words
// -- self, none, true, false, match, type, spawn, fork, mutex, sem, ... -- all
// share one scan kind, so only the word itself says which one it is.
def type_of(src: str, s: Span) -> long {
    let t = T_variable;
    if (s.kind == scan.K_comment) { t = T_comment; }
    else if (s.kind == scan.K_string || s.kind == scan.K_bstring || s.kind == scan.K_char || s.kind == scan.K_fstring) { t = T_string; }
    else if (s.kind == scan.K_number) { t = T_number; }
    else if (s.kind == scan.K_keyword) { t = T_keyword; }
    else if (s.kind == scan.K_contextual) {
        let w = word(src, s);
        if (w == "self" || w == "none") { t = T_selfnone; } else { t = T_keyword; }
    }
    else if (s.kind == scan.K_operator) { t = T_operator; }
    else if (s.kind == scan.K_punct) { t = T_punct; }
    else if (s.kind == scan.K_error) { t = T_error; }
    t
}

// A span's own text, defensively: a zero-length span would index out of bounds,
// and a crash inside the highlighter blanks the whole file.
def word(src: str, s: Span) -> str {
    if (s.end > s.off && s.end <= len(src)) { src[s.off:s.end] } else { "" }
}

// One absolute token, before delta encoding.
//
// Named SemTok, not Tok: a path import FLATTENS the module into the caller's
// namespace, and src/y/lexer.y already defines `type Tok = {t, v, line, col}`.
// Shadowing it makes lexer.y's own `mktok` return the wrong record -- 60 errors
// inside the compiler, none of them in the file that caused them.
type SemTok = { line: long, ch: long, len: long, typ: long };

// ── spans to absolute tokens ────────────────────────────────────────────

// The absolute tokens for a buffer: sorted, one per line, no overlaps.
def tokens(src: str) -> [SemTok] {
    tokens_in(doc_of(src))
}

// The same, over a document whose line starts are already known. One table for
// the whole document instead of one per line -- see pos.line_bytes_from.
def tokens_in(d: SrcDoc) -> [SemTok] {
    let src = d.src;
    let out: [SemTok] = [];
    let r = scan.scan_full(src);
    let sps = r.spans;
    let i = 0;
    while (i < len(sps)) {
        let s = sps[i];
        if (s.end > s.off && s.end <= len(src)) {
            let t = type_of(src, s);
            out += split_lines(d, s, t);
        }
        i = i + 1;
    }
    out
}

// One span, as one token per line it covers.
//
// A token may not span a line break, so a block comment or a multi-line string
// becomes several. Getting this wrong paints a comment from its start to the end
// of the FILE, which looks like a broken theme rather than a broken server.
//
// Each line's token is the INTERSECTION of the span with that line's byte range,
// taken from scan.line_starts. The obvious alternative -- walk `at` forward by
// the length taken on each line -- is off by one per line, because `at` lands ON
// the newline rather than past it; two lines happen to cancel out and three do
// not, which is a bug that passes a small test and fails on a real file.
def split_lines(d: SrcDoc, s: Span, t: long) -> [SemTok] {
    let out: [SemTok] = [];
    if (s.end <= s.off) { return out; }
    let starts = d.starts;
    let last_byte = s.end - 1;                    // the span's last byte
    // The line holding that byte: starts[last_byte] is the first start past it.
    let last_line = 1;
    let k = 1;
    while (k < len(starts)) {
        if (starts[k] > last_byte) { last_line = k; k = len(starts); } else { k = k + 1; }
    }
    let ln = s.line;
    let go = true;
    while (go && ln <= last_line) {
        let lo = starts[ln - 1];
        let hi = pos.doc_line_end(d, ln);
        // the overlap of [s.off, s.end) with this line
        let a = s.off;
        if (lo > a) { a = lo; }
        let b = s.end;
        if (hi < b) { b = hi; }
        if (b > a) {
            // no line slice here: doc_u16 walks the bytes in place, which is the
            // difference between 600 ms and 30 ms on a large file
            let from = a - lo;
            let upto = b - lo;
            let ch = pos.doc_u16(d, ln, from);
            let end = pos.doc_u16(d, ln, upto);
            if (end > ch) {
                let tok: SemTok = { line: ln - 1, ch: ch, len: end - ch, typ: t };
                out += tok;
            }
        }
        ln = ln + 1;
        if (ln > last_line) { go = false; }
    }
    out
}

// ── delta encoding ──────────────────────────────────────────────────────

// The flat `data` array. R2.4: re-deriving absolute positions from this must
// reproduce the absolute token list exactly, which is what test-sem checks.
def encode(toks: [SemTok]) -> [long] {
    let out: [long] = [];
    let pl = 0;
    let pc = 0;
    // The end of the previous token, so an overlap can be dropped rather than
    // emitted -- the format forbids overlap and an editor will render garbage.
    let pend = -1;
    foreach (t in toks) {
        if (t.line >= 0 && t.len > 0) {
            let start = t.line * 1000000 + t.ch;
            let finish = t.line * 1000000 + t.ch + t.len;
            let overlaps = pend >= 0 && start < pend;
            if (!overlaps) {
                let dl = t.line - pl;
                let dc = t.ch;
                if (dl == 0) { dc = t.ch - pc; }
                out += dl;
                out += dc;
                out += t.len;
                out += t.typ;
                out += 0;              // no modifiers yet
                pl = t.line;
                pc = t.ch;
                pend = finish;
            }
        }
    }
    out
}

// The whole result, as the reply value.
def sem_full_of(src: str) -> { data: [long] } {
    let r: { data: [long] } = { data: encode(tokens(src)) };
    r
}

def sem_full_in(d: SrcDoc) -> { data: [long] } {
    let r: { data: [long] } = { data: encode(tokens_in(d)) };
    r
}

export {
  SemTok, T_comment, T_string, T_number, T_keyword, T_selfnone,
  T_operator, T_punct, T_variable, T_error,
  token_types, type_of, word, tokens, tokens_in, split_lines, encode,
  sem_full_of, sem_full_in
};
