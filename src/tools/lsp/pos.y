// pos.y -- the compiler's positions to the protocol's.
//
// The compiler reports 1-based line and 1-based BYTE column (stated in the
// manual under Integers; the lexer walks bytes). LSP wants 0-based line and
// 0-based UTF-16 code-unit character. So every position crosses twice: the line
// loses one, and the column is re-measured.
//
// Why the column is re-measured rather than adjusted: the byte column is only
// an offset if you know the line's bytes, and `é` is two of them and one UTF-16
// unit. A file with non-ASCII in it is not an edge case -- it is the normal case
// for a source tree with a `─` in a comment.

import scan from "./scan.y";

// LSP position. Named so the shape is written once.
type Pos = { line: long, character: long };

// A 0-based (line, utf16 character) pair, handed on separately, because the
// compiler's OWN 1-based position record is {line, col} and naming that shape
// here would be a mistake with a wide blast radius: lint.y's type-alias
// registry is global across the whole spliced program, so declaring an alias
// for {line, col} makes every other inline occurrence of it warn -- including
// src/y/lexer.y:335, which this module must not edit. The same fires for the
// second inline occurrence ("written out 2 times"). So a byte column travels as
// a plain long, and the line with it as a plain long; see to_src and
// from_src below.

// A document, with its line starts computed once.
type SrcDoc = { src: str, starts: [long] };

def doc_of(text: str) -> SrcDoc {
    let d: SrcDoc = { src: text, starts: scan.line_starts(text) };
    d
}

def doc_line(d: SrcDoc, ln: long) -> str {
    line_bytes_from(d.src, d.starts, ln)
}

// The UTF-16 length of the first `upto` BYTES of line `ln`, without building
// the line's string at all.
//
// doc_line() slices, and a slice copies: asking for every token's column
// materialized the same line once per token, which on src/y/native.y was most of
// the cost of highlighting a 484 KB file. This walks the bytes in place instead.
def doc_u16(d: SrcDoc, ln: long, upto: long) -> long {
    if (ln < 1 || ln > len(d.starts)) { return 0; }
    let src = d.src;
    let base = d.starts[ln - 1];
    let end = base + upto;
    if (end > len(src)) { end = len(src); }
    let i = base;
    let u = 0;
    while (i < end) {
        let c = byte_at(src, i);
        if (c < 128) { i = i + 1; u = u + 1; }
        else if ((c & 224) == 192) { i = i + 2; u = u + 1; }
        else if ((c & 240) == 224) { i = i + 3; u = u + 1; }
        else if ((c & 248) == 240) { i = i + 4; u = u + 2; }
        else { i = i + 1; u = u + 1; }
    }
    u
}

// The end byte offset of line `ln`, or the document's length for the last one.
def doc_line_end(d: SrcDoc, ln: long) -> long {
    if (ln < 1 || ln > len(d.starts)) { return 0; }
    if (ln < len(d.starts)) { return d.starts[ln]; }
    len(d.src)
}

// How many lines a document has, counting a trailing newline as ending the last
// one rather than starting an empty new one -- so "a\n" is 1 line, which is
// what an editor's line count says.
def doc_lines(d: SrcDoc) -> long {
    let n = len(d.starts);
    if (n > 1 && d.starts[n - 1] == len(d.src)) { return n - 1; }
    n
}

// ── one-off helpers ─────────────────────────────────────────────────────
//
// STOPS AT THE FIRST newline. The first version did not -- it kept scanning and
// overwrote `to` with every newline it met, so it returned the line's start to
// the LAST newline in the text. That is correct for exactly one line of a file
// (the last one with content), which is why t008 passed: every check it made
// happened to land there. The bug surfaced as soon as something asked for line 1
// of a multi-line document -- a hover range or outline span reaches from its
// start to the end of the FILE when the first line's length is wrong.
//
// The lesson is in the test rather than the code: a fixture that only checks
// the last line cannot tell "correct" from "correct by accident". t010 checks
// line 1 of a four-line string.
def line_bytes(text: str, ln: long) -> str {
    line_bytes_from(text, scan.line_starts(text), ln)
}

// The same, with the line starts already computed.
//
// This exists because line_bytes is O(n) -- it builds the whole start table --
// and callers that walk a document line by line turn that into O(n^2). Asking
// for a per-line request on src/y/parser.y took 4.8 SECONDS per call that way:
// it would have frozen the editor on every keystroke. Anything per-line must
// build the table once (doc_of)
// and pass it here.
def line_bytes_from(text: str, starts: [long], ln: long) -> str {
    if (ln < 1 || ln > len(starts)) { return ""; }
    let from = starts[ln - 1];
    let to = from;
    let i = from;
    let stop = len(text);
    while (i < stop) {
        if (byte_at(text, i) == '\n') { to = i; i = stop; } else { i = i + 1; to = i; }
    }
    if (to < from) { to = from; }
    text[from:to]
}

// UTF-16 code units in `line` before its byte offset `n`.
def u16_len(line: str, n: long) -> long {
    let i = 0;
    let u = 0;
    let lim = len(line);
    if (n < lim) { lim = n; }
    while (i < lim) {
        let c = byte_at(line, i);
        if (c < 128) {
            i = i + 1;
            u = u + 1;
        } else if ((c & 224) == 192) {
            i = i + 2;                          // 110xxxxx 10xxxxxx
            u = u + 1;
        } else if ((c & 240) == 224) {
            i = i + 3;                          // 1110xxxx ...
            u = u + 1;
        } else if ((c & 248) == 240) {
            i = i + 4;                          // 11110xxx ... -> a surrogate PAIR
            u = u + 2;
        } else {
            // A stray continuation byte: not valid UTF-8, but it must still
            // advance, or this never terminates on a broken file.
            i = i + 1;
            u = u + 1;
        }
    }
    u
}

// A 1-based (line, byte column) to LSP's 0-based (line, utf16 character).
//
// TWO forms, and the second is the one to use in a loop. `to_lsp` builds the
// line-start table every call -- it has to, it only has the text -- and
// `scope.index_src` calls it once per DECLARATION, so indexing src/y/native.y
// rebuilt an 11,000-entry table 3,576 times: measured at 694 MB of allocation
// and 2.6 GB for the file, which is out of memory against the 3.5 GB cap and so
// no definition, hover or completion on a file that size. This is the same trap
// `line_bytes_from` documents above, one layer up: fix it once here rather than
// at each of a dozen call sites.
//
// `doc_to_lsp` is that form. It reads the starts out of the caller's SrcDoc.
def to_lsp(text: str, ln: long, col: long) -> Pos {
    doc_to_lsp({ src: text, starts: scan.line_starts(text) }, ln, col)
}

// The same, from a SrcDoc whose starts are already built.
def doc_to_lsp(d: SrcDoc, ln: long, col: long) -> Pos {
    let line = ln - 1;
    if (line < 0) { line = 0; }
    let c = col - 1;
    if (c < 0) { c = 0; }
    let lb = line_bytes_from(d.src, d.starts, ln);
    let ch = u16_len(lb, c);
    { line: line, character: ch }
}

// A 0-based line number to the compiler's 1-based one.
def src_line(ln: long) -> long {
    if (ln < 0) { 1 } else { ln + 1 }
}

// A 0-based (line, utf16 character) back to a 1-based byte COLUMN, for the other
// direction: a position arriving in a request. The line needs no document text,
// so src_line is its whole conversion and only the column has to be walked.
def from_lsp(text: str, ln: long, character: long) -> long {
    let lb = line_bytes(text, src_line(ln));
    let u = 0;
    let i = 0;
    let want = character;
    if (want < 0) { want = 0; }
    while (i < len(lb) && u < want) {
        let c = byte_at(lb, i);
        if (c < 128) { i = i + 1; u = u + 1; }
        else if ((c & 224) == 192) { i = i + 2; u = u + 1; }
        else if ((c & 240) == 224) { i = i + 3; u = u + 1; }
        else if ((c & 248) == 240) { i = i + 4; u = u + 2; }
        else { i = i + 1; u = u + 1; }
    }
    i + 1
}

export { Pos, SrcDoc, doc_of, doc_line, doc_u16, doc_line_end, doc_lines, line_bytes, line_bytes_from, u16_len, to_lsp, src_line, from_lsp };
