// lexer.y — tokenize a Y source string into a list of token maps.

import tags from "./tags.y";
import vocabulary from "./lex_words.y";



type Tok = { t: long, v: str, line: long, col: long, off: long, end: long };
type Cursor = { s: str, p: long };

// NOTE: short underscore-free names (isdigit/isalpha/...) — see below.
def isdigit(c: byte) -> bool {
    c >= '0' && c <= '9'
};

def isalpha(c: byte) -> bool {
    (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || (c >= '0' && c <= '9')
};

def isalnum(c: byte) -> bool {
    isalpha(c)
};

def radix_of(s: str) -> long {
    if (len(s) > 1 && s[0:1] == "0") {
        let p = s[1:2];
        if (p == "x" || p == "X") { 16 }
        else if (p == "o" || p == "O") { 8 }
        else if (p == "b" || p == "B") { 2 }
        else { 0 }
    } else { 0 }
};

// Digit of a radix literal (0x.. / 0o.. / 0b..), including `_` separators.
def is_radix_ch(c: byte, radix: long) -> bool {
    if ( c == '_') { true }
    else if (radix == 2) { c == '0' || c == '1' }
    else if (radix == 8) { c >= '0' && c <= '7' }
    else { isdigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') }
};

// A decimal literal's text without its `_` digit separators: its num token
// carries this, so whatever reads the literal (tolong, norm_num, the float
// helpers) sees plain digits. A radix literal keeps them (norm_num skips
// them).
def strip_seps(s: str) -> str {
    if (index_of(s, "_") < 0) { s } else { join(split(s, "_"), "") }
};

// Is the slice one identifier byte (a letter, a digit or `_`)? The empty
// slice -- one past the end of the source -- is not, so `1b` at EOF is a byte
// literal and `1bx` is not.
def lex_word_slice(s: str) -> bool {
    len(s) == 1 && (isalnum(s[0]) || s[0] == '_')
};

// The value of one digit byte in a radix literal (0-9a-fA-F).
def lex_digit_val(c: byte) -> long {
    if (c >= '0' && c <= '9') { c - '0' }
    else if (c >= 'a' && c <= 'f') { c - 'a' + 10 }
    else { c - 'A' + 10 }
};

// The value of an integer literal's text, `_` separators skipped and the
// radix's two-byte prefix skipped when there is one. This is the byte
// literal's range test; it is lexer-local because the one in native.y
// (norm_num) is on the other side of the dependency.
def lex_int_value(txt: str, radix: long) -> long {
    // radix 0 means DECIMAL, the convention radix_of uses; a literal with a
    // prefix carries it in its first two bytes, which are skipped. (The first
    // cut skipped two bytes for any radix > 0 and was called with 10 for
    // decimal: `65b` then read only the `5` after the skip and became 5.)
    let v = 0;
    let r = radix;
    let i = 0;
    if (r == 0) { r = 10; } else { i = 2; };
    while (i < len(txt)) {
        let c = txt[i];
        if (c != '_') { v = v * r + lex_digit_val(c); };
        i++;
    };
    v
};

// A space, tab, newline or carriage return.
def isspace(c: byte) -> bool {
    c == ' ' || c == '\t' || c == '\n' || c == '\r'
};

// is c one of the single-char punctuation symbols?
// One of the nine punctuation characters Y uses.
def ispunct(c: byte) -> bool {
    c == '(' || c == ')' || c == '{' || c == '}' || c == '[' || c == ']' || c == ',' || c == ';' || c == ':'
};

def lex_quoted(src: str, i: long, line: long, col: long, what: str) -> LitScan {
    let q = src[i:i + 1];
    let n = len(src);
    i++;
    col++;
    let start = i;
    let open = true;
    let closed = false;
    let hasesc = false;
    while (open) {
        if (i < n) {
            let ch = src[i:i + 1];
            if (ch == "\\") { hasesc = true; i += 2; col += 2; }
            else if (ch == q) { open = false; closed = true; }
            else {
                if (ch == "\n") { line++; col = 1; }
                else { col++; };
                i++;
            };
        } else { open = false; };
    };
    if (closed) {
    } else {
        // ran off the end with the quote still open: said in `err` below
    };
    let raw = src[start:i];
    i++;  // skip closing quote
    col++;
    let buf = hasesc ? unescape(raw, false) : raw;
    let err = "";
    // An UNCLOSED literal has no closing quote to skip: its end is the end of
    // the buffer. (The `i++` above still runs -- the position the compiler's
    // next token would start at is unchanged, which is what the diagnostics
    // are pinned to -- but the SPAN must not point past the text.)
    let e = i;
    if (!closed) { e = n; err = "unterminated " + what; };
    { text: buf, end: e, line: line, col: col, err: err }
};

// What lex_quoted and lex_triple both report: the decoded text, the position
// just past the literal, and "" or the message. Named because it is written
// out twice (lint.y's rule).
type LitScan = { text: str, end: long, line: long, col: long, err: str };

// """...""" -- a multiline string. Everything between the triple quotes is
// the text, newlines and single `"` included; a backslash escape still means
// what it means in a one-line string (`\n`, `\"`, `\\`), so the only thing
// this spelling adds is a terminator a `"` cannot be confused with.
def lex_triple(src: str, i: long, line: long, col: long, what: str) -> LitScan {
    let n = len(src);
    i += 3;
    col += 3;
    let start = i;
    let open = true;
    let closed = false;
    let hasesc = false;
    while (open) {
        if (i + 3 > n) {
            open = false;
        } else {
            let ch = src[i:i + 1];
            if (ch == "\\") { hasesc = true; i += 2; col += 2; }
            else if (src[i:i + 3] == "\"\"\"") { open = false; closed = true; }
            else {
                if (ch == "\n") { line++; col = 1; }
                else { col++; };
                i++;
            };
        };
    };
    let raw = src[start:i];
    i += 3;
    col += 3;
    let buf = hasesc ? unescape(raw, false) : raw;
    let err = "";
    // as in lex_quoted: an unclosed literal ends at the buffer, not three
    // bytes past it
    let e = i;
    if (!closed) { e = n; err = "unterminated " + what; };
    { text: buf, end: e, line: line, col: col, err: err }
};

// A literal's text from its raw source: \n \t \r, \xHH, and `\<c>` drops
// the backslash (the Y literal rules). In an f-string (`braces`) `{{` and
// `}}` are one brace each -- fstr_walk lets no single brace through.
def unescape(raw: str, braces: bool) -> str {
    // a chunk list + join (O(n))
    let chunks: [str] = [];
    let k = 0;
    while (k < len(raw)) {
        let rc = raw[k:k + 1];
        if (rc == "\\") {
            let esc = raw[k + 1:k + 2];
            if (esc == "n") { chunks += "\n"; k += 2; }
            else if (esc == "t") { chunks += "\t"; k += 2; }
            else if (esc == "r") { chunks += "\r"; k += 2; }
            else if (esc == "x") {
                // \xHH -- two hex digits
                let h1 = hexvalx(raw[k + 2:k + 3]);
                let h2 = hexvalx(raw[k + 3:k + 4]);
                if (h1 >= 0 && h2 >= 0) {
                    chunks += chr(h1 * 16 + h2);
                    k += 4;
                } else {
                    chunks += esc;
                    k += 2;
                };
            }
            else { chunks += esc; k += 2; };
        } else if (braces && (rc == "{" || rc == "}")) {
            chunks += rc;
            k += 2;
        } else {
            chunks += rc;
            k++;
        };
    };
    join(chunks, "")
};

// ── f-strings ────────────────────────────────────────────────────────────

// A byte of an identifier-shaped word (isalnum, on a byte).
def wordbyte(c: long) -> bool {
    isalpha(c)
};

def lit_end(src: str, q: long, closed: [long]) -> long {
    let n = len(src);
    let qc = src[q];
    let i = q + 1;
    let end = n;
    let open = true;
    let was = false;
    while (open && i < n) {
        let c = src[i];
        if (c == '\\') { i = i + 2; }
        else if (c == qc) { end = i + 1; open = false; was = true; }
        else { i = i + 1; };
    };
    closed[0] = if (was) { 1 } else { 0 };
    end
};

// Where the expression of the f-string field starting at src[lo] ends: the
// first `}` or `:` outside brackets and literals (but a `:` that closes a
// `?`), or a `,` `;` or unmatched `)` `]` there, which fstr_walk rejects;
// len(src) when the source runs out first.
def fstr_expr_end(src: str, lo: long) -> long {
    let n = len(src);
    let depth = 0;
    let tern = 0;
    let i = lo;
    let stop = n;
    let go = true;
    while (go && i < n) {
        let c = src[i];
        if (c == '"' || c == '\'') {
            i = c == '"' && i > lo && src[i - 1] == 102 && (i - 1 == lo || !wordbyte(src[i - 2])) ? fstr_walk(src, i).end : lit_end(src, i, [0]);
        } else if (c == '(' || c == '[' || c == '{') {
            depth++;
            i = i + 1;
        } else if (depth > 0) {
            if (c == ')' || c == ']' || c == '}') { depth--; }
            i = i + 1;
        } else if (c == '?' && i + 1 < n && src[i + 1] == 46) {
            // `?.` (option propagation) is one token and opens no ternary,
            // so a format spec's `:` after it is the spec's own -- without
            // this, `f"{o?.p:x}"` reads as the ternary `o ? .p : x`.
            i = i + 2;
        } else if (c == '?') {
            tern++;
            i = i + 1;
        } else if (c == ':' && tern > 0) {
            tern--;
            i = i + 1;
        } else if (c == '}' || c == ':' || c == ',' || c == ';' || c == ')' || c == ']') {
            stop = i;
            go = false;
        } else {
            i = i + 1;
        };
    };
    stop
};

// Whether src[lo:hi] is all blanks.
def fstr_blank(src: str, lo: long, hi: long) -> bool {
    let i = lo;
    let blank = true;
    while (blank && i < hi) {
        blank = isspace(src[i]);
        i = i + 1;
    };
    blank
};

def fstr_walk(src: str, q: long) -> { end: long, err: str, at: long, fields: [long], qlen: long } {
    let n = len(src);
    // The opening delimiter is one quote or three, and the closing one has to
    // match: inside f""" a lone `"` does not end the string.
    let qlen = 1;
    if (src[q:q + 3] == "\"\"\"") { qlen = 3; };
    let fields: [long] = [];
    let err = "";
    let at = q;
    let i = q + 1;
    while (true) {
        if (i >= n) {
            err = "unterminated f-string";
            break;
        } else {
            let c = src[i];
            if (c == '\\') {
                i = i + 2;
            } else if (c == '\x22') {
                // the closing delimiter is as long as the opening one: a
                // single `"` inside a `"""` f-string does not end it
                if (qlen == 3 && src[i:i + 3] != "\"\"\"") { i = i + 1; }
                else { i = i + qlen; break; };
            } else if ((c == '{' || c == '}') && i + 1 < n && src[i + 1] == c) {
                i = i + 2;
            } else if (c == '}') {
                err = "single '}' in an f-string (a literal brace is '}}')";
                at = i;
                break;
            } else if (c == '{') {
                let lo = i + 1;
                let hi = fstr_expr_end(src, lo);
                let hc = 0;
                if (hi < n) { hc = src[hi]; }
                if (hc != '}' && hc != ':') {
                    if (hi >= n) {
                        err = "unterminated f-string field";
                        at = i;
                    } else {
                        err = "an f-string field is one expression, got '" + src[hi:hi + 1] + "'";
                        at = hi;
                    };
                    break;
                } else if (fstr_blank(src, lo, hi)) {
                    err = "empty f-string field";
                    at = i;
                    break;
                } else if (hc == '}') {
                    fields += lo;
                    fields += hi;
                    fields += -1;
                    fields += -1;
                    i = hi + 1;
                } else {
                    // the spec: up to the closing brace
                    let e = hi + 1;
                    while (e < n && src[e] != 125 && src[e] != 123 && src[e] != 34) {
                        e = e + 1;
                    };
                    if (e < n && src[e] == 125) {
                        fields += lo;
                        fields += hi;
                        fields += hi + 1;
                        fields += e;
                        i = e + 1;
                    } else {
                        if (e < n && src[e] == 123) {
                            err = "a format spec cannot hold '{'";
                            at = e;
                        } else {
                            err = "unterminated f-string field";
                            at = i;
                        };
                        break;
                    };
                };
            } else {
                i = i + 1;
            };
        };
    };
    let end = i;
    if (err != "") { end = lit_end(src, q, [0]); }
    { end: end, err: err, at: at, fields: fields, qlen: qlen }
};

// The position (line, col) moves to over src[a:b].
def fstr_adv(src: str, a: long, b: long, line: long, col: long) -> { line: long, col: long } {
    let ln = line;
    let cl = col;
    for i in a..b {
        if (src[i] == 10) { ln = ln + 1; cl = 1; } else { cl = cl + 1; };
    };
    { line: ln, col: cl }
};

def lex_fstring(src: str, q: long, line: long, col: long, toks: [Tok], lsp: bool) -> { end: long, line: long, col: long } {
    let w = fstr_walk(src, q);
    let qlen = w.qlen;
    let fs = w.fields;
    if (lsp) {
        let ty0 = K.fstr;
        if (w.err != "") { ty0 = K.ferr; };
        toks += mktok(ty0, src[q - 1:w.end], line, col, q - 1, w.end);
        let e0 = fstr_adv(src, q - 1, w.end, line, col);
        return { end: w.end, line: e0.line, col: e0.col };
    };
    if (w.err != "") {
        let ep = fstr_adv(src, q - 1, w.at, line, col);
        toks += mktok(K.ferr, w.err, ep.line, ep.col, 0, 0);
    } else if (len(fs) == 0) {
        toks += mktok(K.str, unescape(src[q + qlen:w.end - qlen], true), line, col, 0, 0);
    } else {
        toks += mktok(K.punct, "(", line, col, 0, 0);
        let from = q + qlen;
        let at = q - 1;
        let bl = line;
        let bc = col;
        let k = 0;
        while (k < len(fs)) {
            let lo = fs[k];
            let hi = fs[k + 1];
            let slo = fs[k + 2];
            let bp = fstr_adv(src, at, lo - 1, bl, bc);
            at = lo - 1;
            bl = bp.line;
            bc = bp.col;
            if (k > 0) { toks += mktok(K.op, "+", bl, bc, 0, 0); }
            if (lo - 1 > from) {
                toks += mktok(K.str, unescape(src[from:lo - 1], true), bl, bc, 0, 0);
                toks += mktok(K.op, "+", bl, bc, 0, 0);
            }
            toks += mktok(K.id, "#fmt", bl, bc, 0, 0);
            toks += mktok(K.punct, "(", bl, bc, 0, 0);
            let sub = tokenize(src[lo:hi]);
            let j = 0;
            while (j + 1 < len(sub)) {
                let tk = sub[j];
                if (tk.line == 1) {
                    toks += mktok(tk.t, tk.v, bl, bc + tk.col, 0, 0);
                } else {
                    toks += mktok(tk.t, tk.v, bl + tk.line - 1, tk.col, 0, 0);
                };
                j++;
            };
            toks += mktok(K.punct, ",", bl, bc, 0, 0);
            if (slo >= 0) {
                toks += mktok(K.str, src[slo:fs[k + 3]], bl, bc, 0, 0);
                from = fs[k + 3] + 1;
            } else {
                toks += mktok(K.str, "", bl, bc, 0, 0);
                from = hi + 1;
            };
            toks += mktok(K.punct, ")", bl, bc, 0, 0);
            k += 4;
        };
        if (w.end - qlen > from) {
            toks += mktok(K.op, "+", bl, bc, 0, 0);
            toks += mktok(K.str, unescape(src[from:w.end - qlen], true), bl, bc, 0, 0);
        }
        toks += mktok(K.punct, ")", bl, bc, 0, 0);
    };
    let e = fstr_adv(src, q - 1, w.end, line, col);
    { end: w.end, line: e.line, col: e.col }
};

def mktok(t: long, v: str, line: long, col: long, off: long, end: long) -> Tok {
    { t: t, v: v, line: line, col: col, off: off, end: end }
};

// Value of a single hex digit char (0-15), or -1 if not a hex digit.
def hexvalx(c: str) -> long {
    let o = ord(c);
    if (o >= '0' && o <= '9') { o - '0' }
    else if (o >= 'A' && o <= 'F') { o - 'A' + 10 }
    else if (o >= 'a' && o <= 'f') { o - 'a' + 10 }
    else { -1 }
};

def multicharop(src: str, i: long, c: str) -> str {
    if (c == "<" || c == ">") {
        let a = src[i];
        let b = peek(src, i + 1);
        let d = peek(src, i + 2);
        if (a == '>' && b == '>' && d == '>' && peek(src, i + 3) == '=') { ">>>=" }
        else if (a == '>' && b == '>' && d == '>') { ">>>" }
        else if (a == '>' && b == '>' && d == '=') { ">>=" }
        else if (a == '<' && b == '<' && d == '=') { "<<=" }
        else { twocharop(src, i) }
    } else {
        twocharop(src, i)
    }
};

// The byte at i, or -1 past the end.
def peek(src: str, i: long) -> long {
    let v = -1;
    if (i < len(src)) { v = src[i]; };
    v
};

// Try to read a two-char operator at position i. Returns the operator or "".
// The set: == != <= >= && || :: .. -> => ++ -- ?. += -= *= /= %= &= |= ^= << >>
def twocharop(src: str, i: long) -> str {
    let a = peek(src, i);
    let b = peek(src, i + 1);
    let ok = false;
    if (b == '=') {
        ok = a == '=' || a == '!' || a == '<' || a == '>' || a == '+' || a == '-' || a == '*' || a == '/' || a == '%' || a == '&' || a == '|' || a == '^';
    } else if (a == b) {
        ok = a == '&' || a == '|' || a == ':' || a == '.' || a == '+' || a == '-' || a == '<' || a == '>';
    } else if (b == '>') {
        ok = a == '-' || a == '=';
    } else if (b == '.') {
        ok = a == '?';
    };
    if (ok) { src[i:i + 2] } else { "" }
};

// A one-character operator.
def issingleop(c: byte) -> bool {
    c == '+' || c == '-' || c == '*' || c == '/' || c == '%' || c == '<' || c == '>' || c == '=' || c == '.' || c == '!' || c == '&' || c == '?' || c == '|' || c == '^' || c == '~'
};

// The slash character, in one place: this file's own source contains no bare
// "/" outside this literal and the "/=" test in twocharop, so the comment
// dispatch in tokenize (line comment / block comment / division) is the only
// place a slash in the source being lexed is ever interpreted.
def slash() -> str { "/" };

def isdigitch(c: byte) -> bool {
    // single-char predicate on a 1-char string (native-safe: no ord()).
    c >= '0' && c <= '8'
};

// The compiler's entry point: comments dropped, f-strings desugared, a
// malformed literal fatal.
def tokenize(src: str) -> [Tok] {
    tokenize_go(src, false)
};

// The language server's entry point: comments kept as tokens, an f-string
// whole, a malformed literal a token rather than an exit, and every token
// carrying its byte span. ONE scanner serves both -- the span fields are
// meaningful here and only here.
def tokenize_lsp(src: str) -> [Tok] {
    tokenize_go(src, true)
};

def tokenize_go(src: str, lsp: bool) -> [Tok] {
    let toks: [Tok] = [];
    let i = 0;
    let n = len(src);
    let line = 1;
    let col = 1;
    while (i < n) {
        let c = src[i];
        if (isspace(c)) {
            if (c == '\n') { line++; col = 1; }
            else { col++; };
            i++;
        } else if (isdigit(c)) {
            let start = i;
            let startcol = col;
            // 0x../0X.. (hex), 0o../0O.. (octal) and 0b../0B.. (binary)
            // integer literals. radix_of is the one prefix test.
            let radix = 0;
            if (c == '0') { radix = radix_of(src[i:i + 2]); };
            // the message of a malformed literal (an ferr token), or ""
            let err = "";
            // >= 0: this literal carries the `b` suffix and its value, and the
            // token tail below is what emits it (emitting it HERE as well put
            // two tokens in the stream for one literal: `expected ';', got
            // '0b10001b'`)
            let bval = -1;
            // the decimal/radix literal ended in `n`: a bigint literal
            let big = false;
            if (radix > 0) {
                i += 2;
                col += 2;
                let digits = false;
                while (true) {
                    if (i < n) {
                        let rc = src[i];
                        if (is_radix_ch(rc, radix)) {
                            if (rc != '_') { digits = true; };
                            i++;
                            col++;
                        } else { break; };
                    } else { break; };
                };
                if (!digits) {
                    // A prefix without a digit (`0x`, `0b_`, `0b2`) is no
                    // number: the word characters after it are taken into
                    // the bad literal, reported once, where it starts.
                    while (i < n && isalnum(src[i])) { i++; col++; };
                    let what = "binary";
                    if (radix == 16) { what = "hex"; }
                    else if (radix == 8) { what = "octal"; };
                    err = what + " literal '" + src[start:i] + "' has no digits";
                } else if (src[i:i + 1] == "n" && !lex_word_slice(src[i + 1:i + 2])) {
                    // `0b10001n` / `0o17n` / `0x1Fn`: a BIGINT literal.
                    // `n` is not a digit of any radix, so the digits end
                    // where it starts; the token tail emits it as a bignum.
                    i++;
                    col++;
                    big = true;
                } else if (src[i:i + 1] == "b" && !lex_word_slice(src[i + 1:i + 2])) {
                    i++;
                    col++;
                    let bv = lex_int_value(src[start:i - 1], radix);
                    if (bv > 255) {
                        err = "byte literal '" + src[start:i] + "' does not fit in a byte";
                    } else {
                        bval = bv;
                    };
                };
            } else {
                // The first digit is already known from the branch condition.
                // After the first digit of each part (whole, fraction,
                // exponent) `_` may separate digits: 1_000_000, 0.000_1.
                i++;
                col++;
                while (true) {
                    if (i < n) {
                        let dc = src[i];
                        if (isdigit(dc) || dc == '_') { i++; col++; }
                        else { break; };
                    } else { break; };
                };
                // optional fractional part (but not '..' range).
                if (src[i:i + 1] == "." && src[i + 1:i + 2] != ".") {
                    i++;
                    col++;
                    let fs = i;
                    while (true) {
                        if (i < n) {
                            let fc = src[i];
                            if (isdigit(fc) || (fc == '_' && i > fs)) { i++; col++; }
                            else { break; };
                        } else { break; };
                    };
                };
                // optional exponent: e / E, an optional sign, then digits. Only
                // consumed when at least one digit follows, so `1e` stays a
                // number followed by an identifier rather than a bad literal.
                let ec = src[i:i + 1];
                if (ec == "e" || ec == "E") {
                    let esign = 0;
                    let sc = src[i + 1:i + 2];
                    if (sc == "+" || sc == "-") { esign = 1; };
                    // one past the digits can be the end of the source (`1e`):
                    // a guarded read, so it is an identifier next, not a trap
                    if (i + 1 + esign < n && isdigit(src[i + 1 + esign])) {
                        i = i + 1 + esign;
                        col = col + 1 + esign;
                        while (true) {
                            if (i < n) {
                                let xc = src[i];
                                if (isdigit(xc) || xc == '_') { i++; col++; }
                                else { break; };
                            } else { break; };
                        };
                    };
                };
                if (src[i:i + 1] == "n" && !lex_word_slice(src[i + 1:i + 2])) {
                    if (index_of(src[start:i], ".") >= 0 || index_of(src[start:i], "e") >= 0 || index_of(src[start:i], "E") >= 0) {
                        err = "bigint literal '" + src[start:i + 1] + "' is a float; a bigint is a whole number";
                        i++;
                        col++;
                    } else {
                        i++;
                        col++;
                        big = true;
                    };
                };
            };
            let txt = src[start:i];
            if (err != "") {
                toks += mktok(K.ferr, err, line, startcol, start, i);
            } else if (big) {
                toks += mktok(K.bigint, strip_seps(src[start:i - 1]), line, startcol, start, i);
            } else if (bval >= 0) {
                toks += mktok(K.char, chr(bval), line, startcol, start, i);
            } else if (src[i:i + 1] == "b" && !lex_word_slice(src[i + 1:i + 2])) {
                // `129b`: a BYTE literal, and the same node `'a'` builds.
                // A hex literal cannot take this suffix (`0x1Fb` is the hex
                // number 507, because `b` is a hex digit) and a float cannot
                // either, which is the two errors below.
                i++;
                col++;
                if (index_of(txt, ".") >= 0 || index_of(txt, "e") >= 0 || index_of(txt, "E") >= 0) {
                    toks += mktok(K.ferr, "byte literal '" + src[start:i] + "' is a float; a byte is a whole number", line, startcol, start, i);
                } else {
                    let bv = lex_int_value(txt, radix);
                    if (bv > 255) {
                        toks += mktok(K.ferr, "byte literal '" + src[start:i] + "' does not fit in a byte", line, startcol, start, i);
                    } else {
                        toks += mktok(K.char, chr(bv), line, startcol, start, i);
                    };
                };
            } else {
                if (radix == 0) { txt = strip_seps(txt); };
                toks += mktok(K.num, txt, line, startcol, start, i);
            };
        } else if (isalpha(c)) {
            let start = i;
            let startcol = col;
            // The first character is already known to be a word character.
            i++;
            col++;
            while (true) {
                if (i < n) {
                    if (isalnum(src[i])) { i++; col++; }
                    else { break; };
                } else { break; };
            };
            let word = src[start:i];
            let ty = K.id;
            if (lex_reserved(word)) { ty = K.kw; };
            if (word == "b") {
                // b"..." / b'...' -- a byte-string literal: the same type
                // as [byte], spelled like a Python bytes literal.
                let bline = line;
                let qch = src[i:i + 1];
                if (qch == "\"" || qch == "'") {
                    let bq = lex_quoted(src, i, line, col, "byte string");
                    i = bq.end;
                    line = bq.line;
                    col = bq.col;
                    if (bq.err != "") {
                        toks += mktok(K.ferr, bq.err, bline, startcol, start, i);
                    } else {
                        toks += mktok(K.bstr, bq.text, bline, startcol, start, i);
                    };
                } else {
                    toks += mktok(ty, word, line, startcol, start, i);
                };
            } else if (word == "c" && src[i:i + 1] == "'") {
                // 'a' is no longer a spelling: a character literal is 'a'.
                // The run is consumed whole so the message is one token, and
                // so the closing quote cannot become a name the parser
                // charges a second message to.
                let cline = line;
                let cq = lex_quoted(src, i, line, col, "character literal");
                i = cq.end;
                line = cq.line;
                col = cq.col;
                let cmsg = "a character literal is written '" + cq.text + "'; the c'" + cq.text + "' form is gone";
                if (cq.err != "") {
                    cmsg = cmsg + " (and the quote is never closed)";
                };
                toks += mktok(K.ferr, cmsg, cline, startcol, start, i);
            } else if (word == "f" && src[i:i + 1] == "\"") {
                // f"..." / f"""...""" -- an f-string (lex_fstring). The
                // triple form spans lines and may hold a `"`.
                let fq = lex_fstring(src, i, line, startcol, toks, lsp);
                i = fq.end;
                line = fq.line;
                col = fq.col;
            } else {
                toks += mktok(ty, word, line, startcol, start, i);
            };
        } else if (c == '\x22' && src[i:i + 3] == "\"\"\"") {
            // """...""" -- a string that spans lines and may hold a `"`.
            // Escapes mean what they always mean, so a `\n` is still a
            // newline and the raw text between the delimiters is the value.
            let startline = line;
            let startcol = col;
            let startoff = i;
            let tq = lex_triple(src, i, line, col, "string literal");
            i = tq.end;
            line = tq.line;
            col = tq.col;
            if (tq.err != "") {
                toks += mktok(K.ferr, tq.err, startline, startcol, startoff, i);
            } else {
                toks += mktok(K.str, tq.text, startline, startcol, startoff, i);
            };
        } else if (c == '\x22') {
            // string literal with escapes. NOTE: this arm precedes the slash
            // arms below: every slash inside quotes is consumed here, so the
            // slash arms only ever see real comment openers or operators.
            let startline = line;
            let startcol = col;
            let startoff = i;
            let q = lex_quoted(src, i, line, col, "string literal");
            i = q.end;
            line = q.line;
            col = q.col;
            if (q.err != "") {
                toks += mktok(K.ferr, q.err, startline, startcol, startoff, i);
            } else {
                toks += mktok(K.str, q.text, startline, startcol, startoff, i);
            };

        } else if (c == '/') {
            if (src[i + 1:i + 2] == slash()) {
                // line comment
                let cstart = i;
                let ccol = col;
                i += 2;
                col += 2;
                while (true) {
                    if (i < n) {
                        if (src[i:i + 1] != "\n") { i++; col++; }
                        else { break; };
                    } else { break; };
                };
                // the server keeps it: the formatter and the highlighter both
                // need the comment positions, which the compiler throws away
                if (lsp) { toks += mktok(K.comment, src[cstart:i], line, ccol, cstart, i); };
            } else if (src[i + 1:i + 2] == "*") {
                let cstart = i;
                let ccol = col;
                let cline = line;    // the comment's FIRST line: the scan below
                // walks `line` to its last one
                i += 2;
                col += 2;
                // `/** ... */` is a DOC comment: the server paints it as
                // documentation and hover shows it. `/**/` is just empty.
                let isdoc = src[i:i + 1] == "*" && src[i + 1:i + 2] != "/";
                let open = true;
                let closed = false;
                while (open) {
                    if (i + 1 < n) {
                        if (src[i:i + 2] == "*/") {
                            i += 2;
                            col += 2;
                            open = false;
                            closed = true;
                        } else {
                            if ((src[i:i + 1]) == "\n") { line++; col = 1; }
                            else { col++; };
                            i++;
                        };
                    } else { open = false; };
                };
                if (!closed) { i = n; };
                if (!closed && !lsp) {
                    // ran off the end with the comment still open: fatal,
                    // like an unterminated string (the rest of the file
                    // was silently swallowed). The server never exits on a
                    // buffer being edited -- it paints it.
                    puts("error: unterminated block comment\n");
                    exit(1);
                };
                // An unterminated block comment is an ERROR to the server: it
                // has no end, so nothing can be painted or formatted around it.
                if (lsp) {
                    let ty = K.comment;
                    if (isdoc) { ty = K.doc; };
                    if (!closed) { ty = K.ferr; };
                    toks += mktok(ty, src[cstart:i], cline, ccol, cstart, i);
                };
            } else {
                // division operator or `/=` (not a comment opener). The
                // comment dispatch above owns the `/` branch, so `/=` has
                // to be recognized HERE — the generic twocharop dispatch
                // below never sees it.
                let two = twocharop(src, i);
                if (two == "/=") {
                    toks += mktok(K.op, two, line, col, i, i + 2);
                    i += 2;
                    col += 2;
                } else {
                    toks += mktok(K.op, slash(), line, col, i, i + 1);
                    i++;
                    col++;
                };
            };
        } else {
            // operator / punct / unknown-char dispatch.
            let op = multicharop(src, i, src[i:i + 1]);
            if (op != "") {
                toks += mktok(K.op, op, line, col, i, i + len(op));
                i += len(op);
                col += len(op);
            } else if (c == '\x27') {
                // 'a' -- a CHARACTER literal: one byte, typed `byte`. It is
                // not a string (a byte string is b'a'), so the 'a' prefix
                // this used to need bought nothing and is gone. The parser
                // rejects a run that is not exactly one byte.
                let aline = line;
                let acol = col;
                let astart = i;
                let aq = lex_quoted(src, i, line, col, "character literal");
                i = aq.end;
                line = aq.line;
                col = aq.col;
                if (aq.err != "") {
                    toks += mktok(K.ferr, aq.err, aline, acol, astart, i);
                } else {
                    toks += mktok(K.char, aq.text, aline, acol, astart, i);
                };
            } else if (issingleop(c)) {
                toks += mktok(K.op, src[i:i + 1], line, col, i, i + 1);
                i++;
                col++;
            } else if (ispunct(c)) {
                toks += mktok(K.punct, src[i:i + 1], line, col, i, i + 1);
                i++;
                col++;
            } else {
                if (lsp) { toks += mktok(K.stray, src[i:i + 1], line, col, i, i + 1); }
                else { toks += mktok(K.op, src[i:i + 1], line, col, i, i + 1); };
                i++;
                col++;
            };
        };
    };
    toks += mktok(K.eof, "", line, col, i, i);
    toks
};

export { lex_reserved, lex_contextual, tokenize, tokenize_lsp, fstr_walk, lit_end };
