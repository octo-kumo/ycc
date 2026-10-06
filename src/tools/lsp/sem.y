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
// The SEMANTIC classes are here too, and they are the point of R2.3: an editor
// paints `n` in `let n = 1` and `n` in `def n(...)` differently, and only the
// second is what a reader needs to see. This file used to say they "need to know
// what a name DENOTES, which is the renamer's and the checker's answer rather than
// the lexer's -- so they are §9.2 / Stage B, and NOT M4", which was true of the
// lexer and wrong about the consequence: what a name denotes is `scope`'s answer
// about DECLARATIONS and a dot's own text, and neither needs the type index.
//
// So `type_of` still answers from the span alone -- it must, because a lexer-class
// is all a span knows -- and the semantic classes arrive as an OVERRIDE table from
// the caller (`serve.semantic_overrides`), one entry per span index, 0 meaning "no opinion".
// That keeps `sem.y` importing only `scan` and `pos`: it cannot import `scope` or
// `serve` without a cycle, and Y has no function values to hand it a predicate.
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
// The semantic classes, appended so the eight above keep their wire indices -- an
// editor's theme is keyed on them and a renumbering repaints every file.
const T_parameter = 9;
const T_function = 10;
const T_property = 11;
const T_type = 12;
const T_builtin = 13;

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
    out += "parameter";
    out += "function";
    out += "property";
    out += "type";
    out += "builtin";
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
    tokens_in(doc_of(src), [])
}

// The same, over a document whose line starts are already known. One table for
// the whole document instead of one per line -- see pos.line_bytes_from.
// The byte offset line `ln` starts at, clamped: line 1 is 0 and a line past the
// end is the end of the text, so a range that overshoots the document costs
// nothing and cannot read out of bounds.
def byte_of_line(d: SrcDoc, ln: long) -> long {
    let st = d.starts;
    if (ln < 1) {
        0
    } else if (ln > len(st)) {
        len(d.src)
    } else {
        st[ln - 1]
    }
}

// The tokens whose span intersects the byte range [lo, hi).
//
// Every token in a Y document comes from one scanner span and `split_lines` breaks
// it per line, so a line range IS a byte range and the only change needed is to
// skip spans outside it. A multi-line comment straddling the edge is emitted whole
// rather than clipped: the lines above the range come along and VS Code discards
// tokens it did not ask for. Clipping would be tidier and would cost a pass over
// the token list to achieve.
def tokens_in_range(d: SrcDoc, over: [long], lo: long, hi: long) -> [SemTok] {
    let src = d.src;
    let out: [SemTok] = [];
    let r = scan.scan_full(src);
    let sps = r.spans;
    let i = 0;
    while (i < len(sps)) {
        let s = sps[i];
        if (s.end > s.off && s.end <= len(src) && s.end > lo && s.off < hi) {
            let t = type_of(src, s);
            // An override only ever REPLACES a name's class, never a comment's or
            // a number's: `semantic_overrides` is handed the identifier spans and has no
            // opinion about anything else, and the guard makes that structural
            // rather than a promise.
            if (i < len(over) && over[i] != 0) { t = over[i]; };
            if (s.kind == scan.K_fstring) {
                // An f-string is not one token. `f"{name:<14}: {us * 2.0:7.2f}"`
                // is code with string literals around it, and painting the whole
                // span as `string` made every name inside it part of one green
                // blob -- worse than not highlighting the interpolation at all,
                // because the interpolation is the part a reader is looking at.
                let parts = fstring_parts(src, s, d, over, i);
                if (len(parts) > 0) { out += parts; }
                else { out += split_lines(d, s, t); };
            } else {
                out += split_lines(d, s, t);
            };
        }
        i = i + 1;
    }
    out
}

// The whole document, kept named: "the whole thing" is the common case and should
// read as such at the call site.
def tokens_in(d: SrcDoc, over: [long]) -> [SemTok] {
    tokens_in_range(d, over, 0, len(d.src))
}

// An f-string's tokens: the literal runs as `string`, and each `{...}` is scanned
// as CODE by the same scanner over the same text, so a name inside it comes out as
// a name and a format spec as its punctuation and number.
//
// The scan of the interior is a whole `scan.scan_full` over a substring, which is
// the point: reusing the real scanner is why the inside of an interpolation is
// classified the same way as the same code written outside a string. A hand-rolled
// split would have to re-implement it and would be wrong the first time a construct
// appeared that it had not heard of.
//
// `over`/`idx` are the caller's classification table, offset by the span's own
// index, so a name in an interpolation is classified as that name is everywhere
// else. An offset table entry that does not exist simply reads as "no opinion".
def fstring_parts(src: str, s: Span, d: SrcDoc, over: [long], idx: long) -> [SemTok] {
    let out: [SemTok] = [];
    let text = src[s.off:s.end];
    // The `f"` and the closing quote are string; the span starts at the `f`.
    let q = index_of(text, "\"");
    if (q < 0) { return out; };
    let lit_start = s.off;
    let lit_end = s.off + q + 1;
    let i = lit_end;
    while (i < s.end) {
        let c = byte_at(src, i);
        if (c == 92) {
            // A backslash escapes the next byte, so `\{` is not an interpolation.
            i = i + 2;
        } else if (c == 123) {
            // `{{` is a literal brace, not the start of one.
            if (i + 1 < s.end && byte_at(src, i + 1) == 123) {
                i = i + 2;
            } else {
                let depth = brace_depth(src, i, s.end);
                if (lit_end > lit_start) { out += run_lines(d, lit_start, lit_end, T_string); };
                if (depth > i) {
                    out += code_tokens(src, i, depth + 1, d, over, idx);
                };
                i = depth + 1;
                lit_start = i;
                lit_end = i;
            };
        } else if (c == 125) {
            // A `}` with no `{` before it: the literal continues.
            i = i + 1;
        } else {
            i = i + 1;
        };
    };
    if (s.end > lit_start) { out += run_lines(d, lit_start, s.end, T_string); };
    out
}

// The offset of the `}` closing the `{` at `from`, or `from` when the brace is
// never closed -- which is what a half-typed interpolation looks like, and the
// answer is "no tokens for it" rather than a span running off the end.
def brace_depth(src: str, from: long, limit: long) -> long {
    let depth = 0;
    let i = from;
    while (i < limit) {
        let c = byte_at(src, i);
        if (c == 92) { i = i + 2; }
        else {
            if (c == 123) { depth = depth + 1; }
            else if (c == 125) {
                depth = depth - 1;
                if (depth == 0) { return i; };
            };
            i = i + 1;
        };
    };
    from
}

// [from, to) scanned as code, its spans classified as they would be outside a
// string.
def code_tokens(src: str, from: long, to: long, d: SrcDoc, over: [long], idx: long) -> [SemTok] {
    let out: [SemTok] = [];
    let inner = src[from:to];
    let r = scan.scan_full(inner);
    let isps = r.spans;
    let i = 0;
    while (i < len(isps)) {
        let sp = isps[i];
        if (sp.end > sp.off && sp.end <= len(inner)) {
            let t = type_of(inner, sp);
            // The classification table is indexed by the OUTER span index, and an
            // interpolation's identifiers are not in it -- they were never spans of
            // the outer scan. So the inner scan classifies them lexically, which is
            // `variable` for a name; the caller cannot do better without a second
            // pass, and `variable` is the honest answer rather than a wrong class.
            out += run_lines(d, from + sp.off, from + sp.end, t);
        };
        i = i + 1;
    };
    out
}

// One token per line for [from, to), which is `split_lines` without a Span.
def run_lines(d: SrcDoc, from: long, to: long, t: long) -> [SemTok] {
    let out: [SemTok] = [];
    if (to <= from) { return out; };
    let starts = d.starts;
    let last_line = 0;
    if (len(starts) > 0) { last_line = len(starts) - 1; };
    let k = 1;
    while (k < len(starts)) {
        if (starts[k] > to - 1) { last_line = k; k = len(starts); } else { k = k + 1; };
    };
    let ln = line_of_byte(d, from);
    let go = true;
    while (go && ln <= last_line) {
        let lo = starts[ln - 1];
        let hi = doc_end(d, ln);
        let a = from;
        if (lo > a) { a = lo; };
        let b = to;
        if (hi < b) { b = hi; };
        if (b > a) {
            let ch = doc_u16_at(d, ln, a - lo);
            let end = doc_u16_at(d, ln, b - lo);
            if (end > ch) { out += { line: ln - 1, ch: ch, len: end - ch, typ: t }; };
        };
        ln = ln + 1;
        if (ln > last_line) { go = false; };
    };
    out
}

// The 0-based line a byte offset is on, by counting the line starts -- which is
// one linear walk per call and therefore only for the f-string path, where the
// number of calls is the number of interpolations.
def line_of_byte(d: SrcDoc, off: long) -> long {
    let starts = d.starts;
    let ln = 1;
    let i = 0;
    while (i < len(starts)) {
        if (starts[i] <= off) { ln = i + 1; i = i + 1; } else { i = len(starts); };
    };
    ln
}

def doc_end(d: SrcDoc, ln: long) -> long { pos.doc_line_end(d, ln) }
def doc_u16_at(d: SrcDoc, ln: long, off: long) -> long { pos.doc_u16(d, ln, off) }

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
    // The last line is the last one in the table, NOT 1, and the difference is
    // visible in an editor.
    //
    // A file that ends with a newline has one more line than it has text, and the
    // byte after the last token is past that extra line's start -- so the loop
    // below finds it and the answer comes out right by accident. A file that does
    // NOT end with a newline -- which is what an editor sends for the line being
    // typed right now -- has no start past the last byte, the loop finds nothing,
    // and `last_line` stayed 1: the `while` below never visited the last line and
    // EVERY token on it was dropped. A 17-line buffer yielded 115 spans and 110
    // tokens, and the 5 that went missing were exactly the last line's.
    //
    // So the default is the last line in the table and the loop only ever narrows
    // it.
    let last_line = 0;
    if (len(starts) > 0) { last_line = len(starts) - 1; };
    let k = 1;
    while (k < len(starts)) {
        if (starts[k] > last_byte) { last_line = k; k = len(starts); } else { k = k + 1; }
    }
    // `s.line` is the SCANNER's line, which is 1-based; `last_line` is an index
    // into `starts`, which is 0-based. Comparing them directly is an off-by-one
    // that only shows up on the LAST line of a buffer with no trailing newline --
    // there `last_line` is the last index and `s.line` is one past it, so the loop
    // never ran and the whole line was dropped. `ln - 1` is the 0-based line, and
    // the token is emitted as `ln - 1` below, so that is what is compared.
    let ln = s.line;
    let go = true;
    while (go && ln - 1 <= last_line) {
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
        if (ln - 1 > last_line) { go = false; }
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

// The whole result, as the reply value. `over` is the caller's semantic-class
// table, one entry per span index, 0 for "no opinion" -- see the header.
def sem_full_of(src: str, over: [long]) -> { data: [long] } {
    let r: { data: [long] } = { data: encode(tokens_in(doc_of(src), over)) };
    r
}

def sem_full_in(d: SrcDoc, over: [long]) -> { data: [long] } {
    let r: { data: [long] } = { data: encode(tokens_in(d, over)) };
    r
}

// The tokens for ONE range of lines, 1-based and inclusive.
//
// This is what `range: true` in the server's capabilities buys. The whole-document
// answer is not merely larger than it needs to be, it is large ENOUGH TO BE THE
// PROBLEM: src/y/types.y has 40,410 tokens, so a whole-file reply is 202,050
// integers -- around a megabyte of JSON -- and the client decodes and re-renders
// every one of them. A viewport of fifty lines is 1% of that.
//
// Measured, because the cost is not where a person would guess. The SERVER answers
// a whole-file request for types.y in 3 ms and then sits idle, which is what made
// this look like nothing was happening at all: the time was on the other side of
// the socket, in the client, decoding what had just been sent. So the fix is to send
// less, not to compute it faster -- and the standard feature for that is a range.
//
// The token stream is split per line, so a range is contiguous and the encoding's
// first delta is the line offset from zero, exactly as for a whole document.
def sem_range_in(d: SrcDoc, over: [long], from_line: long, to_line: long) -> { data: [long] } {
    let lo = byte_of_line(d, from_line);
    let hi = byte_of_line(d, to_line + 1);
    let r: { data: [long] } = { data: encode(tokens_in_range(d, over, lo, hi)) };
    r
}

export {
  SemTok, T_comment, T_string, T_number, T_keyword, T_selfnone,
  T_operator, T_punct, T_variable, T_error,
  T_parameter, T_function, T_property, T_type, T_builtin,
  token_types, type_of, word, tokens, tokens_in, tokens_in_range, byte_of_line,
  split_lines, encode, sem_full_of, sem_full_in, sem_range_in
};
