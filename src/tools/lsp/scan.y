// scan.y -- a tolerant span scanner: one byte-level pass over a buffer that
// says what every region of it is.
//
// WHY THIS EXISTS AND WHY IT IS NOT tokenize(). The lexer answers the parser's
// question -- "what are my tokens" -- and throws away everything the parser
// does not need: comments, the gap between tokens, and the distinction between
// "this string is fine" and "this string runs off the end of the file". Two
// other things rule it out as a highlighter's source:
//
//   - f-strings are desugared DURING lexing. `f"a{x}b"` comes out as
//     `(" " + #fmt(x, "") + "b")`, with positions rebased onto the original
//     text but no token of its own having any extent, so the stream cannot
//     yield a source span for the literal.
//   - it calls exit(1) on an unterminated string or block comment, which in a
//     server kills the process on the first `"` the user types.
//
// So this is a second, deliberately independent classifier. It must agree with
// tokenize() about where every token BEGINS -- that is a test, not a shared
// dependency (see test-agree.sh) -- and it is tolerant where the lexer is not.
//
// The two agree by construction only if both are changed together; the agreement
// test is what catches it when they are not.

// ── span kinds ──────────────────────────────────────────────────────────
// Numeric so the map to an LSP semantic-token type is one table. These are
// syntactic classes only: variable / parameter / function / method / type /
// builtin need the checker's index (LSP.md §9.2) and are layered on later.
const K_comment = 1;      // // and /* */ both
const K_string = 2;       // "..."
const K_bstring = 3;      // b"..." b'...'
const K_char = 4;         // c'x'
const K_fstring = 5;      // f"...{expr}..."
const K_number = 6;       // 12, 1.5, 1e10, 0x1f, 0b1010, with _ grouping
const K_ident = 7;        // anything not in the keyword list
const K_keyword = 8;      // the twelve reserved words
const K_contextual = 9;   // match, type, spawn, ...: words, not keywords
const K_operator = 10;
const K_punct = 11;       // ( ) { } [ ] , ; :
const K_error = 12;       // a literal that is not closed, or a stray byte
const K_none = 0;         // whitespace and comments-of-no-account: not a span

type Span = { off: long, end: long, kind: long, line: long, col: long };

// The lexer appends one of these to every token stream, and never a span.
def sp(off: long, end: long, kind: long, line: long, col: long) -> Span {
    { off: off, end: end, kind: kind, line: line, col: col }
}

// ── byte classes ────────────────────────────────────────────────────────

def is_dig(c: byte) -> bool { c >= c'0' && c <= c'9' }
def is_hexd(c: byte) -> bool {
    is_dig(c) || (c >= c'a' && c <= c'f') || (c >= c'A' && c <= c'F')
}
def is_alpha(c: byte) -> bool {
    (c >= c'a' && c <= c'z') || (c >= c'A' && c <= c'Z') || c == c'_'
}
def is_alphanum(c: byte) -> bool { is_alpha(c) || is_dig(c) }
def is_space(c: byte) -> bool { c == c' ' || c == c'\t' || c == c'\n' || c == c'\r' }

// The nine punctuation characters, per the lexer's ispunct.
def is_punct_byte(c: byte) -> bool {
    c == c'(' || c == c')' || c == c'{' || c == c'}' || c == c'[' ||
    c == c']' || c == c',' || c == c';' || c == c':'
}

// The lexer's issingleop.
def is_single_op(c: byte) -> bool {
    c == c'+' || c == c'-' || c == c'*' || c == c'/' || c == c'%' ||
    c == c'<' || c == c'>' || c == c'=' || c == c'.' || c == c'!' ||
    c == c'&' || c == c'?' || c == c'|' || c == c'^' || c == c'~'
}

// ── the twelve reserved words (lexer.y's chain) ──────────────────────────
// A fifteenth would have to be added here too, or it highlights as a name.
// test_coverage.sh greps the lexer's own chain, which is the authority.

def is_keyword(w: str) -> bool {
    w == "let" || w == "const" || w == "def" || w == "if" || w == "else" ||
    w == "while" || w == "for" || w == "foreach" || w == "in" || w == "return" ||
    w == "break" || w == "continue" || w == "native" || w == "true" || w == "false"
}

// Words the parser gives a meaning to in a particular shape. Not reserved: a
// def or a variable with one of these names wins (09-builtins.tex).
def is_contextual(w: str) -> bool {
    w == "match" || w == "type" || w == "spawn" || w == "fork" ||
    w == "lock" || w == "try_lock" || w == "join" || w == "post" ||
    w == "wait" || w == "mutex" || w == "sem" || w == "self" ||
    w == "none" || w == "import" || w == "export"
}

// ── operators, longest match first (the lexer's multicharop) ─────────────
// Longest-first matters: `>>=` is one operator and `>>` then `=` is two, and
// the formatter's spacing depends on which.

def op2(src: str, i: long) -> bool {
    let t = src[i:i + 2];
    t == "==" || t == "!=" || t == "<=" || t == ">=" || t == "&&" || t == "||" ||
    t == "::" || t == ".." || t == "->" || t == "=>" || t == "++" || t == "--" ||
    t == "?." || t == "+=" || t == "-=" || t == "*=" || t == "/=" || t == "%=" ||
    t == "&=" || t == "|=" || t == "^=" || t == "<<" || t == ">>"
}

// 4 or 3 characters, and only after `<` or `>`.
def op_long(src: str, i: long) -> long {
    let c = byte_at(src, i);
    let n = 0;
    if (c == c'<' || c == c'>') {
        if (src[i:i + 4] == ">>>=") { n = 4; }
        else if (src[i:i + 3] == ">>>" || src[i:i + 3] == ">>=" || src[i:i + 3] == "<<=") { n = 3; }
    };
    n
}

def op_len(src: str, i: long) -> long {
    let n = op_long(src, i);
    if (n > 0) { return n; }
    if (op2(src, i)) { return 2; }
    1
}

export { Span, scan, scan_full, repair, kind_name, line_starts, off_at,
         is_keyword, is_contextual, is_punct_byte, is_single_op, op_len };
// ── the pass ────────────────────────────────────────────────────────────
//
// The cursor is a record and records are references, so `c.i` advances in the
// caller's copy. Every `take_*` leaves the cursor just past what it consumed
// and returns the span; the caller appends it.

type Cur = { s: str, i: long, line: long, col: long };

// Advance over `n` bytes, counting lines.
def bump(c: Cur, n: long) -> long {
    let k = 0;
    while (k < n) {
        if (c.i < len(c.s)) {
            if (byte_at(c.s, c.i) == c'\n') {
                c.line = c.line + 1;
                c.col = 1;
            } else { c.col = c.col + 1; }
            c.i = c.i + 1;
        };
        k = k + 1;
    };
    c.i
}

// A quoted run starting at the opening quote (c.i is ON the quote). Tolerates
// an unterminated one: the span then runs to the end of the buffer and is
// marked K_error rather than dropped.
def take_quoted(c: Cur, quote: long) -> Span {
    let start = c.i;
    let sline = c.line;
    let scol = c.col;
    let closed = false;
    bump(c, 1);
    while (!closed) {
        if (c.i >= len(c.s)) {
            closed = true;
        } else {
            let ch = byte_at(c.s, c.i);
            if (ch == quote) {
                bump(c, 1);
                closed = true;
            } else if (ch == 92) {
                // a backslash escapes whatever follows, including a quote
                if (c.i + 1 >= len(c.s)) { bump(c, 1); } else { bump(c, 2); }
            } else {
                bump(c, 1);
            }
        }
    };
    let kind = K_string;
    if (c.i >= len(c.s) && byte_at(c.s, c.i - 1) != quote) { kind = K_error; }
    sp(start, c.i, kind, sline, scol)
}

// f"..." -- find the closing quote, stepping over the {...} fields. A field may
// hold a nested string with braces in it, as in f"{d["k"]}" and
// f"{n == 1 ? "" : "s"}", so braces are counted and quoted runs inside a field
// are skipped whole.
def take_fstring(c: Cur) -> Span {
    let start = c.i;
    let sline = c.line;
    let scol = c.col;
    let closed = false;
    bump(c, 2);                      // f"
    while (!closed) {
        if (c.i >= len(c.s)) {
            closed = true;
        } else {
            let ch = byte_at(c.s, c.i);
            if (ch == 34) {
                bump(c, 1);
                closed = true;
            } else if (ch == 92) {
                if (c.i + 1 >= len(c.s)) { bump(c, 1); } else { bump(c, 2); }
            } else if (ch == 123) {
                bump(c, 1);
                let depth = 1;
                let done = false;
                while (!done && depth > 0) {
                    if (c.i >= len(c.s)) {
                        done = true;
                    } else {
                        let f = byte_at(c.s, c.i);
                        if (f == 123) { depth = depth + 1; bump(c, 1); }
                        else if (f == 125) { depth = depth - 1; bump(c, 1); }
                        else if (f == 34 || f == 39) {
                            // a nested quoted run: step over it whole
                            let q = f;
                            bump(c, 1);
                            let inner = true;
                            while (inner) {
                                if (c.i >= len(c.s)) { inner = false; }
                                else if (byte_at(c.s, c.i) == 92) { bump(c, 2); }
                                else if (byte_at(c.s, c.i) == q) { bump(c, 1); inner = false; }
                                else { bump(c, 1); }
                            }
                        } else { bump(c, 1); }
                    }
                }
            } else {
                bump(c, 1);
            }
        }
    };
    let kind = K_fstring;
    if (c.i >= len(c.s) && byte_at(c.s, c.i - 1) != 34) { kind = K_error; }
    sp(start, c.i, kind, sline, scol)
}

// Digits with `_` between them, never leading. Returns how many digits.
// A `_` must have a digit after it, so `1_` and `1._5` split where the lexer
// splits them rather than swallowing the separator.
def take_digits(c: Cur) -> long {
    let n = 0;
    let more = true;
    while (more) {
        if (c.i >= len(c.s)) {
            more = false;
        } else {
            let d = byte_at(c.s, c.i);
            if (is_dig(d)) {
                bump(c, 1);
                n = n + 1;
            } else if (d == c'_' && n > 0 && c.i + 1 < len(c.s) && is_dig(byte_at(c.s, c.i + 1))) {
                bump(c, 1);
            } else {
                more = false;
            }
        }
    }
    n
}

// 12, 1.5, 1e10, 0x1f, 0b1010_1010.
//
// A `.` joins the number only when a digit follows it. That is the whole
// reason `in 0..1000` is three tokens and not two: without it `0.` swallows the
// first dot of `..` and the range operator loses its start. The exponent is the
// same: `1e` is the number 1 then the name `e`.
def take_number(c: Cur) -> Span {
    let start = c.i;
    let sline = c.line;
    let scol = c.col;
    let radix = 0;
    if (byte_at(c.s, c.i) == c'0' && c.i + 1 < len(c.s)) {
        let n = byte_at(c.s, c.i + 1);
        if (n == c'x' || n == c'X') { radix = 16; }
        if (n == c'b' || n == c'B') { radix = 2; }
    }
    let bad = false;
    if (radix > 0) {
        bump(c, 2);
        let got = 0;
        let more = true;
        while (more) {
            if (c.i >= len(c.s)) {
                more = false;
            } else {
                let d = byte_at(c.s, c.i);
                let ok = is_hexd(d);
                if (radix == 2) { ok = d == c'0' || d == c'1'; }
                // `_` groups digits without being one: `0b1010_1010` is a
                // single literal, while `0b_` has no digit and is an error.
                if (ok) { bump(c, 1); got = got + 1; }
                else if (d == c'_') { bump(c, 1); }
                else { more = false; }
            }
        }
        if (got == 0) {
            // `0x`, `0x_`, `0b2`: a prefix with no digit of its radix is not a
            // number. The lexer takes the following word characters into the
            // bad literal and reports it once, where it starts; so do the same,
            // and mark the span K_error.
            bad = true;
            while (c.i < len(c.s) && is_alphanum(byte_at(c.s, c.i))) { bump(c, 1); }
        }
    } else {
        take_digits(c);
        if (c.i + 1 < len(c.s) && byte_at(c.s, c.i) == c'.') {
            if (is_dig(byte_at(c.s, c.i + 1))) {
                bump(c, 1);
                take_digits(c);
            }
        }
        if (c.i < len(c.s)) {
            let e = byte_at(c.s, c.i);
            if (e == c'e' || e == c'E') {
                let save = c.i;
                bump(c, 1);
                if (c.i < len(c.s)) {
                    let sg = byte_at(c.s, c.i);
                    if (sg == c'+' || sg == c'-') { bump(c, 1); }
                }
                if (c.i < len(c.s) && is_dig(byte_at(c.s, c.i))) {
                    take_digits(c);
                } else { c.i = save; }
            }
        }
    }
    let kind = K_number;
    if (bad) { kind = K_error; }
    sp(start, c.i, kind, sline, scol)
}

def take_word(c: Cur) -> Span {
    let start = c.i;
    let sline = c.line;
    let scol = c.col;
    while (c.i < len(c.s) && is_alphanum(byte_at(c.s, c.i))) { bump(c, 1); }
    let w = c.s[start:c.i];
    let kind = K_ident;
    if (is_keyword(w)) { kind = K_keyword; }
    if (is_contextual(w)) { kind = K_contextual; }
    sp(start, c.i, kind, sline, scol)
}

// `// ...` up to but not including the newline.
def take_line_comment(c: Cur) -> Span {
    let start = c.i;
    let sline = c.line;
    let scol = c.col;
    bump(c, 2);
    while (c.i < len(c.s) && byte_at(c.s, c.i) != c'\n') { bump(c, 1); }
    sp(start, c.i, K_comment, sline, scol)
}

// `/* ... */`. Block comments do NOT nest, matching the lexer. An unclosed one
// runs to the end of the buffer and is K_error -- the case the lexer answers
// with exit(1).
def take_block_comment(c: Cur) -> Span {
    let start = c.i;
    let sline = c.line;
    let scol = c.col;
    let found = false;
    let ran_out = false;
    bump(c, 2);
    while (!found && !ran_out) {
        if (c.i + 1 >= len(c.s)) {
            // The cursor is at the last byte at most, so `bump` would take it
            // to the end and then take nothing: leaving this to a condition
            // alone is an infinite loop, so running out is a state of its own.
            bump(c, len(c.s) - c.i);
            ran_out = true;
        } else if (c.s[c.i:c.i + 2] == "*/") {
            bump(c, 2);
            found = true;
        } else {
            bump(c, 1);
        }
    };
    let kind = K_comment;
    if (!found) { kind = K_error; }
    sp(start, c.i, kind, sline, scol)
}

// The whole buffer. `full` also returns the spans whose kind is K_error, in
// order, so a caller can turn them into diagnostics.
def scan_full(src: str) -> { spans: [Span], bad: [Span] } {
    let spans: [Span] = [];
    let bad: [Span] = [];
    let c = { s: src, i: 0, line: 1, col: 1 };
    let n = len(src);
    let go = true;
    while (go) {
        if (c.i >= n) {
            go = false;
        } else {
            let ch = byte_at(src, c.i);
            let nx = 0;
            if (c.i + 1 < n) { nx = byte_at(src, c.i + 1); }
            let one = sp(c.i, c.i + 1, K_error, c.line, c.col);
            let done = false;

            if (is_space(ch)) {
                // whitespace is not a span: a highlighter has nothing to paint
                // and a formatter wants the gap, not a token
                bump(c, 1);
                one.kind = K_none;
                done = true;
            }
            if (!done && ch == c'/' && nx == c'/') {
                one = take_line_comment(c);
                done = true;
            }
            if (!done && ch == c'/' && nx == c'*') {
                one = take_block_comment(c);
                done = true;
            }
            if (!done && (ch == c'"' || ch == c'\'')) {
                one = take_quoted(c, ch);
                done = true;
            }
            // b"..." / b'...' and c'a' and f"...": a letter followed by a quote
            if (!done && is_alpha(ch)) {
                if ((ch == c'b' || ch == c'f') && (nx == c'"' || nx == c'\'')) {
                    let st = c.i;
                    let sl = c.line;
                    let sc = c.col;
                    bump(c, 1);
                    let q = take_quoted(c, nx);
                    let kind = K_bstring;
                    if (ch == c'f') {
                        // an f-string's fields make take_quoted the wrong scan
                        c.i = st; c.line = sl; c.col = sc;
                        one = take_fstring(c);
                    } else {
                        one = sp(st, c.i, kind, sl, sc);
                        if (q.kind == K_error) { one.kind = K_error; }
                    }
                    done = true;
                }
                if (!done && ch == c'c' && nx == c'\'') {
                    let st = c.i;
                    let sl = c.line;
                    let sc = c.col;
                    bump(c, 1);
                    let q = take_quoted(c, 39);
                    let kind = K_char;
                    if (q.kind == K_error) { kind = K_error; }
                    one = sp(st, c.i, kind, sl, sc);
                    done = true;
                }
            }
            if (!done && is_dig(ch)) {
                one = take_number(c);
                done = true;
            }
            if (!done && is_alpha(ch)) {
                one = take_word(c);
                done = true;
            }
            // Operators before punctuation, as the lexer does it: `::` and
            // `..` are operators even though `:` and `.` are punctuation, so
            // checking punct first would split `m::x` into three tokens.
            if (!done && op_len(src, c.i) > 1) {
                let w = op_len(src, c.i);
                bump(c, w);
                one.end = c.i;
                one.kind = K_operator;
                done = true;
            }
            if (!done && is_single_op(ch)) {
                bump(c, 1);
                one.kind = K_operator;
                done = true;
            }
            if (!done && is_punct_byte(ch)) {
                bump(c, 1);
                one.kind = K_punct;
                done = true;
            }
            if (!done) {
                // A byte no token starts with: one byte, K_error, so the
                // highlighter can show it and the formatter can refuse.
                bump(c, 1);
                one.kind = K_error;
            }
            if (one.kind != K_none) {
                spans += one;
                if (one.kind == K_error) { bad += one; }
            }
        }
    }
    { spans: spans, bad: bad }
}

def scan(src: str) -> [Span] {
    scan_full(src).spans
}

// A name for a kind, for a diagnostic or a test.
def kind_name(k: long) -> str {
    let n = "?";
    if (k == K_comment) { n = "comment"; }
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
        if (byte_at(src, i) == c'\n') { out += i + 1; }
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
  is_keyword, is_contextual, is_punct_byte, is_single_op, op_len, op2, op_long,
  is_dig, is_hexd, is_alpha, is_alphanum, is_space
};
